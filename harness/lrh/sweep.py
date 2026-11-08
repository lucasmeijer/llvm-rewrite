"""`harness/run sweep`: run one pipeline over many corpus files with LLVM and an implementation, and compare.

The checks of a unit only look at the tests in its exit selector. A sweep runs the pass (or analysis printer) on every
file the implementation can already parse and print (every `::roundtrip` in its passing.txt), which finds many bugs
those tests miss. Report only: never touches passing.txt, always exits 0 unless the harness itself fails.

  IR mode (default)  `opt <args> -S`: both outputs canonicalized via `llvm-as | llvm-dis` (which also runs the
                     verifier), then compared, exactly like the ::opt check.
  --analysis         `opt <args> -disable-output`: exit status, stdout and stderr compared byte for byte, like the
                     ::analysis check (--unordered: after sorting lines, like @analysis-unordered).

Per file the outcome is one of
  identical    same output
  differs      our opt exited 0 but the output differs from LLVM's: a silent mismatch, the worst kind
  bad-ir       our opt exited 0 but its output does not assemble / verify: also silent
  failed       our opt exited nonzero (or timed out / crashed): a loud failure, grouped by its first error line
  llvm-failed  LLVM's opt fails on this file with these args (or is nondeterministic): skipped
"""

import hashlib
import json
import re
import shlex
import shutil
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from . import checks, config, corpus, proc

IDENTICAL, DIFFERS, BAD_IR, FAILED, LLVM_FAILED = "identical", "differs", "bad-ir", "failed", "llvm-failed"
ORDER = (IDENTICAL, DIFFERS, BAD_IR, FAILED, LLVM_FAILED)


def slug(args: str) -> str:
    s = re.sub(r"[^A-Za-z0-9_.,=+-]+", "_", args.replace("-passes=", "")).strip("_-") or "none"
    if len(s) > 80:
        s = s[:64] + "-" + hashlib.sha256(args.encode()).hexdigest()[:12]
    return s


def error_key(stderr: str, path: str, rc: int, timed_out: bool, timeout: float) -> str:
    """The first meaningful stderr line, with the file name and line/column numbers taken out, for grouping."""
    if timed_out:
        return f"[timed out after {timeout:g}s]"
    lines = [l.strip() for l in stderr.splitlines() if l.strip()]
    # Prefer the first line that says what went wrong over banners like "PLEASE submit a bug report".
    first = next((l for l in lines if re.search(r"error|not (yet )?(implemented|supported|ported)|unsupported|assert|panic|fatal", l, re.I)),
                 lines[0] if lines else "")
    first = first.replace(path, "<file>")
    first = re.sub(r"<file>:\d+(:\d+)?", "<file>:N", first)
    first = re.sub(r"0x[0-9a-fA-F]{6,}", "0x…", first)
    first = first[:200]
    sig = f"[signal {-rc}] " if rc < 0 else ""
    return sig + (first or f"[exit {rc}, no stderr]")


def run_impl(impl: str, args: str, path: str, wd: Path, analysis: bool, timeout: float) -> proc.Res:
    opt = config.impl_bin(impl, "opt")
    if analysis:
        cmd = [opt, *shlex.split(args), "-disable-output", path]
    else:
        cmd = [opt, *shlex.split(args), "-S", path, "-o", str(wd / "out.ll")]
    return proc.run(cmd, cwd=config.REPO, timeout=timeout)


def sweep_one(impl: str, path: str, args: str, analysis: bool, unordered: bool, timeout: float) -> dict:
    """-> {path, status, key (for failed), message, artifacts}"""
    t = corpus.TestFile(path)
    res = {"path": path, "status": IDENTICAL, "key": "", "message": "", "artifacts": {}}
    if analysis:
        exp = checks.oracle_analysis(t, args, unordered)
    else:
        exp = checks.oracle_opt(t, args)
        if exp["ok"]:
            ok, exp_c = checks.canon(exp["text"])
            if not ok:
                exp = {"ok": False, "text": "LLVM's output does not re-assemble:\n" + exp_c}
    if not exp["ok"]:
        res.update(status=LLVM_FAILED, message=exp["text"])
        return res
    with proc.Workdir() as wd:
        r = run_impl(impl, args, path, wd, analysis, timeout)
        err = r.err.decode(errors="replace")
        if not r.ok:
            res.update(status=FAILED, key=error_key(err, path, r.rc, r.timed_out, timeout),
                       message=f"opt exited with {r.rc}:\n{r.err_tail()}", artifacts={"stderr.txt": r.err_tail(20000)})
            return res
        if not analysis:
            act = (wd / "out.ll").read_text(errors="replace") if (wd / "out.ll").exists() else ""
    if analysis:
        problems, arts = [], {}
        for stream, e, a in (("stderr", exp["stderr"], checks.analysis_canon(err, unordered)),
                             ("stdout", exp["stdout"], checks.analysis_canon(r.out.decode(errors="replace"), unordered))):
            if e != a:
                problems.append(f"{stream} differs:\n" + checks.diff(e, a))
                arts.update({f"expected.{stream}": e, f"actual.{stream}": a, f"diff.{stream}.txt": checks.full_diff(e, a)})
        if problems:
            res.update(status=DIFFERS, message="\n".join(problems), artifacts=arts)
        return res
    ok, act_c = checks.canon(act)
    if not ok:
        res.update(status=BAD_IR, message="output is not valid IR according to llvm-as (assembler/verifier):\n" + act_c,
                   artifacts={"actual.ll": act, "llvm-as.txt": act_c, "stderr.txt": err})
    elif act_c != exp_c:
        res.update(status=DIFFERS, message="canonicalized IR differs:\n" + checks.diff(exp_c, act_c),
                   artifacts={"expected.ll": exp_c, "actual.ll": act_c, "diff.txt": checks.full_diff(exp_c, act_c)})
    return res


def select_files(a, tests, passing) -> tuple[list[str], int]:
    """Files to sweep, and how many tests/perf files were left out by default."""
    if a.all_files or a.impl == config.REFERENCE_IMPL:
        files = [t.path for t in tests]
    else:
        files = sorted({i.rsplit("::", 1)[0] for i in passing if i.endswith("::roundtrip")})
    if a.globs:
        return [f for f in files if corpus.match(f, a.globs)], 0
    kept = [f for f in files if not f.startswith("tests/perf/")]
    return kept, len(files) - len(kept)


def cmd_sweep(a):
    from .cli import BOLD, DIM, GREEN, RED, TTY, YELLOW, build, c, check_llvm_version, first_lines, read_passing

    parts = []
    if a.passes is not None:
        parts.append("-passes=" + a.passes)
    if a.extra:
        parts.append(a.extra)
    if not parts:
        raise SystemExit("sweep needs --passes '<pipeline>' (and/or --extra='<opt args>', e.g. --extra=-O2)")
    args = " ".join(shlex.quote(p) if p.startswith("-passes=") else p for p in parts)
    if a.unordered:
        a.analysis = True

    check_llvm_version()
    if not a.no_build:
        build(a.impl)
    tests = corpus.discover()
    files, perf_skipped = select_files(a, tests, read_passing(a.impl))
    mode = "analysis (stdout+stderr" + (", lines sorted" if a.unordered else "") + ")" if a.analysis else "IR (canonicalized)"
    print(c(BOLD, f"impl/{a.impl}: sweep `opt {args}` over {len(files)} files, {mode}"))
    if perf_skipped:
        print(c(DIM, f"  ({perf_skipped} tests/perf files left out; select them with a glob)"))
    if not files:
        print(c(YELLOW, "no files selected" + ("" if a.all_files else " (default: files listed as ::roundtrip in passing.txt; --all-files for every file)")))
        return

    def one(path):
        try:
            return sweep_one(a.impl, path, args, a.analysis, a.unordered, a.timeout)
        except Exception as e:  # a harness bug; surface it loudly but keep going
            return {"path": path, "status": FAILED, "key": f"[harness exception] {type(e).__name__}: {e}",
                    "message": f"[harness exception] {type(e).__name__}: {e}", "artifacts": {}}

    results = []
    with ThreadPoolExecutor(max_workers=a.jobs) as ex:
        for i, r in enumerate(ex.map(one, files), 1):
            results.append(r)
            if TTY:
                print(f"\r{c(DIM, f'{i}/{len(files)}')}", end="", flush=True)
    if TTY:
        print("\r" + " " * 20 + "\r", end="")

    # Artifacts: .harness-out/sweep/<impl>/<args slug>/<test path>/, plus results.tsv and summary.json.
    out = config.OUT / "sweep" / a.impl / slug(("analysis " if a.analysis else "") + args)
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True, exist_ok=True)
    (out / "args.txt").write_text(args + ("\n(analysis" + (", unordered" if a.unordered else "") + ")" if a.analysis else "") + "\n")
    for r in results:
        if r["status"] == IDENTICAL:
            continue
        d = out / r["path"]
        d.mkdir(parents=True, exist_ok=True)
        (d / "message.txt").write_text(r["message"] + "\n")
        for name, text in r["artifacts"].items():
            (d / name).write_text(text)
    (out / "results.tsv").write_text("".join(f"{r['status']}\t{r['path']}\t{r['key']}\n" for r in results))

    by = {s: [r for r in results if r["status"] == s] for s in ORDER}
    groups = {}
    for r in by[FAILED]:
        groups.setdefault(r["key"], []).append(r["path"])
    groups = sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[0]))
    (out / "summary.json").write_text(json.dumps({
        "impl": a.impl, "args": args, "analysis": a.analysis, "unordered": a.unordered,
        "counts": {s: len(by[s]) for s in ORDER},
        "silent": [r["path"] for r in by[DIFFERS] + by[BAD_IR]],
        "failed_groups": [{"error": k, "count": len(v), "files": v} for k, v in groups],
    }, indent=1) + "\n")

    n = len(results) - len(by[LLVM_FAILED])
    print(f"  {c(GREEN, str(len(by[IDENTICAL])).rjust(6))} identical"
          + (f" ({100 * len(by[IDENTICAL]) / n:.1f}% of {n} compared)" if n else ""))
    silent = by[DIFFERS] + by[BAD_IR]
    print(f"  {c(RED + ';1' if silent else DIM, str(len(by[DIFFERS])).rjust(6))} differs       (silent mismatch: exit 0, wrong output)")
    if by[BAD_IR] or not a.analysis:
        print(f"  {c(RED + ';1' if by[BAD_IR] else DIM, str(len(by[BAD_IR])).rjust(6))} bad-ir        (silent: exit 0, output fails llvm-as/verifier)")
    print(f"  {c(YELLOW, str(len(by[FAILED])).rjust(6))} failed        (loud: nonzero exit), {len(groups)} distinct errors")
    print(f"  {c(DIM, str(len(by[LLVM_FAILED])).rjust(6))} llvm-failed   (skipped: LLVM's opt fails or is nondeterministic)")

    if silent:
        print(c(RED + ";1", f"\nSILENT MISMATCHES ({len(silent)}): fix these first"))
        for r in silent[: a.max_shown]:
            print(f"  {c(RED, r['status'].ljust(7))} {r['path']}")
            if a.verbose:
                print(first_lines(r["message"], 30))
        if len(silent) > a.max_shown:
            print(f"  ... and {len(silent) - a.max_shown} more (results.tsv)")
    if groups:
        print(c(YELLOW, f"\nloud failures by first error line ({len(groups)} groups):"))
        for k, v in groups[: a.max_shown]:
            print(f"  {len(v):5}  {k}\n         {c(DIM, 'e.g. ' + v[0])}")
        if len(groups) > a.max_shown:
            print(f"  ... and {len(groups) - a.max_shown} more groups (summary.json)")
    if a.verbose and by[LLVM_FAILED]:
        print(c(DIM, f"\nllvm-failed ({len(by[LLVM_FAILED])}):"))
        for r in by[LLVM_FAILED][: a.max_shown]:
            print(f"  {r['path']}: {(r['message'].strip().splitlines() or [''])[0][:150]}")
    print(c(DIM, f"\nartifacts: {out.relative_to(config.REPO)}/  (results.tsv, summary.json, <test path>/ for every non-identical file)"))
    sys.exit(0)
