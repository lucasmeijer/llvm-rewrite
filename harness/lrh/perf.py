"""Compile-time performance: our tools vs LLVM on tests/perf (report only; nothing here fails a check).

For every `@perf: <tool> <args>` line of every selected file it measures, for LLVM and for each implementation:

  cpu    user+system CPU time of the process, the minimum over a few runs. Runs go in parallel (half the cores by
         default; CPU time stays within a few percent of a solo run up to that point on this VM), with LLVM and the
         implementations in the same batch, so they see the same load. Each benchmark is repeated until it has
         about a second of samples (at most 5 runs); --reps fixes the count instead.
  rss    peak resident memory.
  instr  only with --instr: instructions executed (valgrind --tool=cachegrind). Exact and repeatable, but valgrind
         is ~40x slower; cached by (tool binary, args, input), so LLVM's numbers and unchanged binaries are free.

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
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from . import checks, config, corpus, proc

VALGRIND_TIMEOUT = 3600
EMPTY_MODULE = 'target triple = "x86_64-unknown-linux-gnu"\n\ndefine void @f() {\n  ret void\n}\n'
EMPTY = "<empty>"
IREFS = re.compile(r"I\s+refs:\s+([\d,]+)")
SAMPLE_TARGET = 1.0  # seconds of CPU samples to collect per benchmark and tool
MAX_REPS = 15
MIN_WORK = {"cpu": 0.03, "instr": 50e6}  # below this (minus startup) at the largest size, a scaling exponent is noise

TTY = sys.stdout.isatty()


def c(code, s):
    return f"\033[{code}m{s}\033[0m" if TTY else s


def progress(msg):
    if TTY:
        print(f"\r\033[2m{msg}\033[0m\033[K", end="", flush=True)


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
            r = proc.run(["valgrind", "--tool=cachegrind", "--cache-sim=no", "--trace-children=yes",
                          "--cachegrind-out-file=/dev/null", *cmd], cwd=wd, timeout=VALGRIND_TIMEOUT)
            counts = IREFS.findall(r.err.decode(errors="replace"))  # one summary per traced process
            if not r.ok or not counts:
                tail = "\n".join(l for l in r.err.decode(errors="replace").splitlines() if not l.startswith("=="))
                return {"ok": False, "msg": f"exit {r.rc}: {tail[-600:]}"}
            return {"ok": True, "instr": sum(int(n.replace(",", "")) for n in counts)}

    k = bin_key(impl, perf_line)
    if k == "missing":
        return {"ok": False, "msg": "binary missing"}
    return proc.cached(["perf-instr-v2", k, perf_line, input_text], compute)


def timed(cmd: list[str], cwd: Path) -> dict:
    """One run: CPU seconds (user+sys), wall seconds, peak RSS in KiB, exit code, stderr tail on failure."""
    with tempfile.TemporaryFile() as err:
        t0 = time.perf_counter()
        try:
            p = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=err)
        except OSError as e:
            return {"rc": 127, "msg": f"could not execute: {e}"}
        _, status, ru = os.wait4(p.pid, 0)
        wall = time.perf_counter() - t0
        rc = os.waitstatus_to_exitcode(status)
        msg = ""
        if rc:
            err.seek(0)
            msg = f"exit {rc}: " + err.read().decode(errors="replace").strip()[-600:]
    return {"rc": rc, "cpu": ru.ru_utime + ru.ru_stime, "wall": wall, "rss": ru.ru_maxrss, "msg": msg}


# ---------------------------------------------------------------- the run

def benchmarks(globs) -> list[tuple[corpus.TestFile, str]]:
    files = [corpus.parse(p) for p in (config.TESTS / "perf").rglob("*.ll")]
    if globs:
        files = [t for t in files if corpus.match(t.path, globs)]
    files.sort(key=lambda t: (str(Path(t.path).parent), t.perf_size or 0, t.path))
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


def measure_cpu(whos, keys, inputs, jobs, fixed_reps) -> dict:
    """{(who, key): {"cpu", "wall", "rss", "reps", "rc", "msg"}} for key = (path, perf line)."""
    samples: dict = {}
    with proc.Workdir() as wd:
        files = {}
        for i, k in enumerate(keys):
            files[k] = wd / f"in{i}.ll"
            files[k].write_text(inputs[k])
        counter = [0]

        def run(job):
            who, k = job
            counter[0] += 1
            out = wd / f"out{counter[0]}"
            r = timed(command(who, k[1], files[k], out), wd)
            out.unlink(missing_ok=True)
            return job, r

        def batch(job_list, label):
            done = 0
            with ThreadPoolExecutor(max_workers=jobs) as ex:
                for job, r in ex.map(run, job_list):
                    samples.setdefault(job, []).append(r)
                    done += 1
                    progress(f"{label} {done}/{len(job_list)}")

        # Round 1: every (tool, benchmark) once, biggest inputs first so the long ones don't straggle at the end.
        order = sorted(keys, key=lambda k: -len(inputs[k]))
        batch([(w, k) for k in order for w in whos], "timing")
        # Round 2: repeat the cheap ones until each has about SAMPLE_TARGET seconds of samples.
        extra = []
        for (w, k), rs in samples.items():
            if rs[0]["rc"]:
                continue
            n = fixed_reps if fixed_reps else min(MAX_REPS, max(1, math.ceil(SAMPLE_TARGET / max(rs[0]["cpu"], 1e-3))))
            extra += [(w, k)] * (n - 1)
        extra.sort(key=lambda j: -samples[j][0]["cpu"])
        if extra:
            batch(extra, "repeats")
    progress("")
    res = {}
    for job, rs in samples.items():
        bad = [r for r in rs if r["rc"]]
        if bad:
            res[job] = {"rc": bad[0]["rc"], "msg": bad[0]["msg"]}
        else:
            res[job] = {"rc": 0, "msg": "", "cpu": min(r["cpu"] for r in rs), "wall": min(r["wall"] for r in rs),
                        "rss": max(r["rss"] for r in rs), "reps": len(rs)}
    return res


def cmd_perf(a):
    from .cli import build, check_llvm_version, read_passing  # avoid an import cycle

    t_start = time.perf_counter()
    check_llvm_version()
    impls = [i.strip() for i in a.impl.split(",") if i.strip()]
    if not a.no_build:
        for i in impls:
            build(i)
    if a.instr and proc.run(["valgrind", "--version"]).rc != 0:
        raise SystemExit("valgrind is not installed (it's in the workspace image); --instr needs it")
    benches = benchmarks(a.globs)
    if not benches:
        raise SystemExit("no @perf benchmarks match; generate the corpus with ./harness/run gen-perf")
    whos = [config.REFERENCE_IMPL] + [i for i in impls if i != config.REFERENCE_IMPL]
    keys = [(t.path, line) for t, line in benches]
    lines = sorted({line for _, line in benches})
    inputs = {k: input_for(t, k[1]) for (t, _), k in zip(benches, keys)}
    has_scaling = any(t.perf_size is not None for t, _ in benches)
    base_keys = [(EMPTY, line) for line in lines] if has_scaling else []
    inputs.update({k: EMPTY_MODULE for k in base_keys})
    jobs = a.jobs or max(1, (os.cpu_count() or 2) // 2)
    print(c("1", f"perf: {len(benches)} benchmarks x {len(whos)} tools ({', '.join(whos)}), {jobs} parallel"
                 + (", with instruction counts" if a.instr else "")))

    cpu = measure_cpu(whos, keys + base_keys, inputs, jobs, a.reps)

    instr = {}
    if a.instr:
        ijobs = [(w, k) for k in keys + base_keys for w in whos if not cpu[(w, k)]["rc"]]
        done = [0]

        def one(job):
            r = count_instr(job[0], job[1][1], inputs[job[1]])
            done[0] += 1
            progress(f"instruction counts {done[0]}/{len(ijobs)}")
            return job, r

        with ThreadPoolExecutor(max_workers=os.cpu_count()) as ex:
            instr = dict(ex.map(one, ijobs))
        progress("")

    # Assemble rows.
    passing = {i: read_passing(i) for i in impls}
    rows = []
    for (t, line), k in zip(benches, keys):
        row = {"bench": t.path.removeprefix("tests/perf/"), "cmd": line, "size": t.perf_size, "tools": {}}
        for w in whos:
            m, ir = cpu[(w, k)], instr.get((w, k))
            ok = not m["rc"] and (ir is None or ir["ok"])
            row["tools"][w] = {
                "ok": ok, "msg": m["msg"] or (ir or {}).get("msg", ""),
                "cpu": m.get("cpu") if ok else None, "wall": m.get("wall") if ok else None,
                "rss_kib": m.get("rss") if ok else None, "reps": m.get("reps"),
                "instr": ir["instr"] if ok and ir else None,
                "correct": correctness(t, line, passing[w]) if w != config.REFERENCE_IMPL else "-",
            }
        rows.append(row)
    baselines = {w: {line: {"cpu": cpu[(w, (EMPTY, line))].get("cpu"),
                            "instr": (instr.get((w, (EMPTY, line))) or {}).get("instr")} for line in lines}
                 for w in whos} if has_scaling else {}

    report(rows, impls, baselines, {i: last_history(i) for i in impls}, a.instr)

    out = config.OUT / "perf"
    out.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    for i in impls:
        rec = {"time": stamp, **git_state(i), "cpus": os.cpu_count(), "jobs": jobs, "globs": a.globs,
               "rows": [{"bench": r["bench"], "cmd": r["cmd"], "size": r["size"], "llvm": r["tools"][config.REFERENCE_IMPL],
                         "impl": r["tools"][i]} for r in rows],
               "baseline": {"llvm": baselines.get(config.REFERENCE_IMPL), "impl": baselines.get(i)}}
        (out / f"{i}.json").write_text(json.dumps(rec, indent=1))
        if not a.no_history and i != config.REFERENCE_IMPL:
            h = history_dir()
            h.mkdir(parents=True, exist_ok=True)
            with open(h / f"{i}.jsonl", "a") as f:
                f.write(json.dumps(rec) + "\n")
    print(c("2", f"\nresults: {out.relative_to(config.REPO)}/<impl>.json; history: {history_dir()}/<impl>.jsonl; "
                 f"took {time.perf_counter() - t_start:.0f}s"))


# ---------------------------------------------------------------- report

def ratio(x, y):
    return x / y if x is not None and y else None


def fmt_ratio(r):
    if r is None:
        return "-"
    s = f"{r:.2f}x" if r < 100 else f"{r:.0f}x"
    return c("32", s) if r <= 1.05 else c("33", s) if r <= 3 else c("31", s)


def fmt_delta(now, prev, noise):
    """Change of a ratio-to-LLVM since the previous run. Within the noise band it's shown as `=`."""
    if now is None or not prev:
        return ""
    d = (now - prev) / prev * 100
    if abs(d) < noise:
        return c("2", "=")
    return c("31" if d > 0 else "32", f"{d:+.1f}%")


def pad(s, w, right=True):
    n = len(re.sub(r"\033\[[0-9;]*m", "", s))
    return (" " * (w - n) + s) if right else (s + " " * (w - n))


def report(rows, impls, baselines, prev, use_instr):
    llvm = config.REFERENCE_IMPL
    metric = "instr" if use_instr else "cpu"

    def prev_ratio(i):
        out = {}
        for r in prev[i].get("rows", []):
            for m in ("instr", "cpu"):
                out[(r["bench"], r["cmd"], m)] = ratio(r["impl"].get(m), r["llvm"].get(m))
        return out

    prevs = {i: prev_ratio(i) for i in impls}
    bw = max(len(f"{r['bench']}  {r['cmd']}") for r in rows) + 2
    head = pad("benchmark", bw, False) + pad("llvm cpu s", 11) + (pad("llvm Minstr", 12) if use_instr else "")
    for i in impls:
        head += "  │ " + pad(f"{i}: cpu", 11) + pad("rss", 7) + (pad("instr", 8) if use_instr else "") + pad("Δprev", 8) + pad("ok", 4)
    print("\n" + c("1", head))
    for r in rows:
        L = r["tools"][llvm]
        line = pad(f"{r['bench']}  {c('2', r['cmd'])}", bw, False)
        line += pad(f"{L['cpu']:.3f}" if L["cpu"] is not None else c("31", "error"), 11)
        if use_instr:
            line += pad(f"{L['instr'] / 1e6:.1f}" if L["instr"] else "-", 12)
        for i in impls:
            T = r["tools"][i]
            if not T["ok"]:
                w = 30 + (8 if use_instr else 0)
                msg = ((T["msg"].strip().splitlines() or [""])[-1])[:w - 1]
                line += "  │ " + pad(c("31", msg), w, False)
                continue
            line += "  │ " + pad(fmt_ratio(ratio(T["cpu"], L["cpu"])), 11) + pad(fmt_ratio(ratio(T["rss_kib"], L["rss_kib"])), 7)
            if use_instr:
                line += pad(fmt_ratio(ratio(T["instr"], L["instr"])), 8)
            now = ratio(T[metric], L[metric])
            line += pad(fmt_delta(now, prevs[i].get((r["bench"], r["cmd"], metric)), 0.05 if use_instr else 10), 8)
            line += pad(T["correct"], 4)
        print(line)

    print()
    for i in impls:
        for m in (["instr"] if use_instr else []) + ["cpu", "rss_kib"]:
            rs = [ratio(r["tools"][i][m], r["tools"][llvm][m]) for r in rows if r["tools"][i]["ok"]]
            rs = [x for x in rs if x]
            if rs:
                g = math.exp(sum(map(math.log, rs)) / len(rs))
                print(f"{i}: geomean {m.removesuffix('_kib')} ratio {fmt_ratio(g)} over {len(rs)}/{len(rows)} benchmarks")
            elif m == "cpu":
                print(f"{i}: no benchmark completed")

    groups = {}
    for r in rows:
        if r["size"] is not None:
            groups.setdefault((str(Path(r["bench"]).parent), r["cmd"]), []).append(r)
    if not groups:
        return
    print(c("1", f"\nscaling: cost ~ n^k ({'instructions' if use_instr else 'CPU time'} minus the empty-module cost)"))
    gw = max(len(f"{g}  {cmd}") for g, cmd in groups) + 2
    print(c("1", pad("shape", gw, False) + pad("llvm k", 8) + "".join(pad(f"{i} k", 12) for i in impls)))
    for (g, cmd), rs in sorted(groups.items()):
        def k_of(w):
            """(exponent, measurable): too little work above startup at the largest size makes k meaningless."""
            pts = []
            for r in rs:
                v = r["tools"][w][metric]
                if v is None:
                    return None, False
                base = ((baselines.get(w) or {}).get(cmd) or {}).get(metric) or 0
                pts.append((r["size"], v - base))
            return fit_exponent(pts), max(v for _, v in pts) >= MIN_WORK[metric]
        kl, ml = k_of(llvm)
        kl_s = "-" if kl is None else f"{kl:.2f}" if ml else c("2", f"({kl:.2f})")
        line = pad(f"{g}  {c('2', cmd)}", gw, False) + pad(kl_s, 8)
        for i in impls:
            ki, mi = k_of(i)
            if ki is None:
                line += pad("-", 12)
            elif not (ml and mi):
                line += pad(c("2", f"({ki:.2f})"), 12)
            else:
                col = "32" if kl is None or ki <= kl + 0.15 else "33" if ki <= kl + 0.5 else "31"
                line += pad(c(col, f"{ki:.2f}"), 12)
        print(line)
    print(c("2", "(k) in parentheses: too little work above process startup to measure growth"))
