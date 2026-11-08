"""Compile-time performance: our tools vs LLVM on tests/perf (report only; nothing here fails a check).

For every `@perf: <tool> <args>` line of every selected file it measures, for LLVM and for each implementation:

  instr  instructions executed (valgrind --tool=cachegrind). Exact and repeatable on this VM, which exposes no
         hardware counters. Cached by (tool binary, args, input), so LLVM's numbers and unchanged binaries cost
         nothing on later runs.
  wall   median wall time of --reps runs, LLVM and implementations interleaved. Noisy on a shared machine.
  rss    peak resident memory (max over the timed runs).

`opt` commands read the file itself; `llc` commands read LLVM's `opt <first @opt>` output of it (like ::isel-ir).
Scaling files (tests/perf/scaling/<shape>/, with @perf-size) also get a fitted exponent: cost ~ n^k, after
subtracting the cost of the same command on an empty module (process startup).

Results go to .harness-out/perf/<impl>.json, and each run is appended to the history
(/persistent/llvm-rewrite/perf-history/<impl>.jsonl) so the next report can show the change since last time.
"""

import datetime
import json
import math
import os
import re
import shlex
import statistics
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from . import checks, config, corpus, proc

VALGRIND_TIMEOUT = 3600
EMPTY_MODULE = 'target triple = "x86_64-unknown-linux-gnu"\n\ndefine void @f() {\n  ret void\n}\n'
IREFS = re.compile(r"I\s+refs:\s+([\d,]+)")

TTY = sys.stdout.isatty()


def c(code, s):
    return f"\033[{code}m{s}\033[0m" if TTY else s


def history_dir() -> Path:
    p = config.PERSISTENT_CACHE.parent
    if p.parent.is_dir() and os.access(p.parent, os.W_OK):
        return p / "perf-history"
    return config.REPO / ".cache" / "perf-history"


# ---------------------------------------------------------------- one measurement

def command(impl: str, perf_line: str, inp: Path, out: Path) -> list[str]:
    tool, *args = shlex.split(perf_line)
    if tool not in ("opt", "llc"):
        raise SystemExit(f"@perf: unsupported tool {tool!r} (expected opt or llc)")
    b = config.impl_bin(impl, tool)
    return [b, *args, "-S", str(inp), "-o", str(out)] if tool == "opt" else [b, *args, str(inp), "-o", str(out)]


def bin_key(impl: str, perf_line: str) -> str:
    """What the cached instruction count depends on besides the input: the tool binary."""
    if impl == config.REFERENCE_IMPL:
        return f"llvm-{config.LLVM_VERSION}"
    b = Path(config.impl_bin(impl, shlex.split(perf_line)[0]))
    return proc.sha(b.read_bytes()) if b.exists() else "missing"


def count_instr(impl: str, perf_line: str, input_text: str) -> dict:
    def compute():
        with proc.Workdir() as wd:
            (wd / "in.ll").write_text(input_text)
            cmd = command(impl, perf_line, wd / "in.ll", wd / "out")
            r = proc.run(["valgrind", "--tool=cachegrind", "--cache-sim=no", "--trace-children=yes", "--cachegrind-out-file=/dev/null", *cmd],
                         cwd=wd, timeout=VALGRIND_TIMEOUT)
            counts = IREFS.findall(r.err.decode(errors="replace"))  # one summary per traced process
            if not r.ok or not counts:
                tail = "\n".join(l for l in r.err.decode(errors="replace").splitlines() if not l.startswith("=="))
                return {"ok": False, "msg": f"exit {r.rc}: {tail[-600:]}"}
            return {"ok": True, "instr": sum(int(n.replace(",", "")) for n in counts)}

    key = ["perf-instr-v2", bin_key(impl, perf_line), perf_line, input_text]
    if bin_key(impl, perf_line) == "missing":
        return {"ok": False, "msg": "binary missing"}
    res = proc.cached(key, compute)
    return res


def timed(cmd: list[str], cwd: Path) -> tuple[float, int, int]:
    """(seconds, peak RSS in KiB, exit code)"""
    with tempfile.TemporaryFile() as err:
        t0 = time.perf_counter()
        p = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=err)
        try:
            _, status, ru = os.wait4(p.pid, 0)
        except ChildProcessError:
            return 0.0, 0, 127
        dt = time.perf_counter() - t0
    return dt, ru.ru_maxrss, os.waitstatus_to_exitcode(status)


# ---------------------------------------------------------------- the run

def benchmarks(globs) -> list[tuple[corpus.TestFile, str]]:
    files = [corpus.parse(p) for p in (config.TESTS / "perf").rglob("*.ll")]
    files.sort(key=lambda t: (str(Path(t.path).parent), t.perf_size or 0, t.path))
    if globs:
        files = [t for t in files if corpus.match(t.path, globs)]
    return [(t, line) for t in files for line in t.perf]


def input_for(t: corpus.TestFile, perf_line: str) -> str:
    if shlex.split(perf_line)[0] == "llc" and t.opt:
        o = checks.oracle_opt(t, t.opt[0])
        if not o["ok"]:
            raise SystemExit(f"{t.path}: LLVM opt {t.opt[0]} fails:\n{o['text']}")
        return o["text"]
    return checks.read(t.path)


def correctness(t: corpus.TestFile, perf_line: str, passing: set[str]) -> str:
    """Is the output this benchmark times checked, and does the impl pass that check?"""
    tool, *args = shlex.split(perf_line)
    if tool == "opt" and not args:
        tid = f"{t.path}::roundtrip"
    elif tool == "opt" and " ".join(args) in t.opt:
        tid = f"{t.path}::opt"
    else:
        return "-"
    return "yes" if tid in passing else "no"


def git_state(impl: str) -> dict:
    def g(*a):
        r = proc.run(["git", *a], cwd=config.REPO)
        return r.out.decode().strip() if r.ok else ""
    return {"commit": g("rev-parse", "HEAD"), "dirty": bool(g("status", "--porcelain", "--", f"impl/{impl}", "harness", "tests/perf"))}


def last_history(impl: str) -> dict:
    f = history_dir() / f"{impl}.jsonl"
    if not f.exists():
        return {}
    lines = f.read_text().splitlines()
    return json.loads(lines[-1]) if lines else {}


def fit_exponent(points: list[tuple[int, float]]) -> float | None:
    pts = [(math.log(n), math.log(v)) for n, v in points if v > 0]
    if len(pts) < 2:
        return None
    mx = sum(x for x, _ in pts) / len(pts)
    my = sum(y for _, y in pts) / len(pts)
    den = sum((x - mx) ** 2 for x, _ in pts)
    return sum((x - mx) * (y - my) for x, y in pts) / den if den else None


def cmd_perf(a):
    from .cli import build, check_llvm_version, read_passing  # avoid an import cycle

    check_llvm_version()
    impls = [i.strip() for i in a.impl.split(",") if i.strip()]
    if not a.no_build:
        for i in impls:
            build(i)
    use_instr = not a.no_instr
    if use_instr and proc.run(["valgrind", "--version"]).rc != 0:
        raise SystemExit("valgrind is not installed (it's in the workspace image); use --no-instr to measure wall time only")
    benches = benchmarks(a.globs)
    if not benches:
        raise SystemExit("no @perf benchmarks match; generate the corpus with ./harness/run gen-perf")
    whos = [config.REFERENCE_IMPL] + [i for i in impls if i != config.REFERENCE_IMPL]
    inputs = {(t.path, line): input_for(t, line) for t, line in benches}
    print(c("1", f"perf: {len(benches)} benchmarks x {len(whos)} tools ({', '.join(whos)})"
                 + ("" if use_instr else ", instruction counts off")))

    # Phase 1: instruction counts (parallel; counts don't depend on load). Includes the empty-module baselines.
    lines = sorted({line for _, line in benches})
    instr = {}
    if use_instr:
        jobs = [(w, t.path, line) for t, line in benches for w in whos] + [(w, "<empty>", line) for line in lines for w in whos]
        done = [0]

        def one(job):
            w, path, line = job
            r = count_instr(w, line, EMPTY_MODULE if path == "<empty>" else inputs[(path, line)])
            done[0] += 1
            if TTY:
                print(f"\r\033[2minstruction counts {done[0]}/{len(jobs)}\033[0m", end="", flush=True)
            return job, r

        with ThreadPoolExecutor(max_workers=a.jobs) as ex:
            for job, r in ex.map(one, jobs):
                instr[job] = r
        if TTY:
            print("\r" + " " * 40 + "\r", end="")

    # Phase 2: wall time and memory, sequential, tools interleaved so load changes hit everyone alike.
    wall = {}
    with proc.Workdir() as wd:
        for t, line in benches:
            (wd / "in.ll").write_text(inputs[(t.path, line)])
            for _ in range(max(1, a.reps)):
                for w in whos:
                    k = (w, t.path, line)
                    if k in instr and not instr[k]["ok"]:
                        continue  # already known to fail
                    if wall.get(k, {}).get("rc", 0) != 0:
                        continue
                    dt, rss, rc = timed(command(w, line, wd / "in.ll", wd / "out"), wd)
                    e = wall.setdefault(k, {"times": [], "rss": 0, "rc": 0})
                    e["times"].append(dt)
                    e["rss"] = max(e["rss"], rss)
                    e["rc"] = rc

    # Assemble rows.
    passing = {i: read_passing(i) for i in impls}
    rows = []
    for t, line in benches:
        row = {"bench": t.path.removeprefix("tests/perf/"), "cmd": line, "size": t.perf_size, "tools": {}}
        for w in whos:
            k = (w, t.path, line)
            ir = instr.get(k)
            wl = wall.get(k, {})
            ok = (ir is None or ir["ok"]) and wl.get("rc", 0) == 0 and bool(wl.get("times"))
            row["tools"][w] = {
                "ok": ok,
                "msg": (ir or {}).get("msg") or (f"exit {wl.get('rc')}" if wl.get("rc") else ""),
                "instr": ir["instr"] if ir and ir["ok"] else None,
                "wall": statistics.median(wl["times"]) if ok else None,
                "rss_kib": wl.get("rss") if ok else None,
                "correct": correctness(t, line, passing[w]) if w != config.REFERENCE_IMPL else "-",
            }
        rows.append(row)
    baselines = {w: {line: instr[(w, "<empty>", line)].get("instr") for line in lines} for w in whos} if use_instr else {}

    report(rows, impls, baselines, {i: last_history(i) for i in impls}, use_instr)

    # Save.
    out = config.OUT / "perf"
    out.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    for i in impls:
        rec = {"time": stamp, **git_state(i), "cpus": os.cpu_count(), "reps": a.reps, "globs": a.globs,
               "rows": [{"bench": r["bench"], "cmd": r["cmd"], "size": r["size"], "llvm": r["tools"][config.REFERENCE_IMPL],
                         "impl": r["tools"][i]} for r in rows],
               "baseline": {"llvm": baselines.get(config.REFERENCE_IMPL), "impl": baselines.get(i)}}
        (out / f"{i}.json").write_text(json.dumps(rec, indent=1))
        if not a.no_history and i != config.REFERENCE_IMPL:
            h = history_dir()
            h.mkdir(parents=True, exist_ok=True)
            with open(h / f"{i}.jsonl", "a") as f:
                f.write(json.dumps(rec) + "\n")
    print(c("2", f"\nresults: {(out).relative_to(config.REPO)}/<impl>.json; history: {history_dir()}/<impl>.jsonl"))


# ---------------------------------------------------------------- report

def ratio(x, y):
    return x / y if x is not None and y else None


def fmt_ratio(r):
    if r is None:
        return "-"
    s = f"{r:.2f}x" if r < 100 else f"{r:.0f}x"
    return c("32", s) if r <= 1.05 else c("33", s) if r <= 3 else c("31", s)


def fmt_delta(now, prev):
    if now is None or not prev:
        return ""
    d = (now - prev) / prev * 100
    if abs(d) < 0.05:
        return c("2", "=")
    return c("31" if d > 0 else "32", f"{d:+.1f}%")


def pad(s, w, right=True):
    n = len(re.sub(r"\033\[[0-9;]*m", "", s))
    return (" " * (w - n) + s) if right else (s + " " * (w - n))


def report(rows, impls, baselines, prev, use_instr):
    llvm = config.REFERENCE_IMPL
    prev_instr = {i: {(r["bench"], r["cmd"]): r["impl"].get("instr") for r in p.get("rows", [])} for i, p in prev.items()}
    bw = max(len(f"{r['bench']}  {r['cmd']}") for r in rows) + 2
    head = pad("benchmark", bw, False) + pad("llvm Minstr", 12) + pad("llvm s", 8)
    for i in impls:
        head += "  │ " + pad(f"{i}: instr", 12) + pad("wall", 8) + pad("rss", 7) + pad("Δprev", 8) + pad("ok", 4)
    print("\n" + c("1", head))
    for r in rows:
        L = r["tools"][llvm]
        line = pad(f"{r['bench']}  {c('2', r['cmd'])}", bw, False)
        line += pad(f"{L['instr'] / 1e6:.1f}" if L["instr"] else "-", 12) + pad(f"{L['wall']:.3f}" if L["wall"] else "-", 8)
        for i in impls:
            T = r["tools"][i]
            if not T["ok"]:
                line += "  │ " + pad(c("31", "error: " + (T["msg"].splitlines() or [""])[-1][:40]), 39, False)
                continue
            line += "  │ " + pad(fmt_ratio(ratio(T["instr"], L["instr"])), 12) + pad(fmt_ratio(ratio(T["wall"], L["wall"])), 8)
            line += pad(fmt_ratio(ratio(T["rss_kib"], L["rss_kib"])), 7)
            line += pad(fmt_delta(T["instr"], prev_instr[i].get((r["bench"], r["cmd"]))), 8) + pad(T["correct"], 4)
        print(line)

    # Geometric means over benchmarks every tool completed.
    print()
    for i in impls:
        for metric in (["instr"] if use_instr else []) + ["wall"]:
            rs = [ratio(r["tools"][i][metric], r["tools"][llvm][metric]) for r in rows if r["tools"][i]["ok"]]
            rs = [x for x in rs if x]
            if rs:
                g = math.exp(sum(map(math.log, rs)) / len(rs))
                print(f"{i}: geomean {metric} ratio {fmt_ratio(g)} over {len(rs)}/{len(rows)} benchmarks")
            else:
                print(f"{i}: no benchmark completed ({metric})")

    # Scaling exponents.
    groups = {}
    for r in rows:
        if r["size"] is not None:
            groups.setdefault((str(Path(r["bench"]).parent), r["cmd"]), []).append(r)
    if not groups:
        return
    metric = "instr" if use_instr else "wall"
    print(c("1", f"\nscaling: cost ~ n^k ({'instructions minus empty-module baseline' if use_instr else 'wall time'})"))
    gw = max(len(f"{g}  {cmd}") for g, cmd in groups) + 2
    print(c("1", pad("shape", gw, False) + pad("llvm k", 8) + "".join(pad(f"{i} k", 12) for i in impls)))
    for (g, cmd), rs in sorted(groups.items()):
        def k_of(w):
            pts = []
            for r in rs:
                v = r["tools"][w][metric]
                if v is None:
                    return None
                base = (baselines.get(w) or {}).get(cmd) or 0 if use_instr else 0
                pts.append((r["size"], v - base))
            return fit_exponent(pts)
        kl = k_of(llvm)
        line = pad(f"{g}  {c('2', cmd)}", gw, False) + pad(f"{kl:.2f}" if kl is not None else "-", 8)
        for i in impls:
            ki = k_of(i)
            if ki is None:
                line += pad("-", 12)
            else:
                col = "32" if kl is None or ki <= kl + 0.15 else "33" if ki <= kl + 0.5 else "31"
                line += pad(c(col, f"{ki:.2f}"), 12)
        print(line)
