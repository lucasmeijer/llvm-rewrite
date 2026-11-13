"""Command line: ./harness/run <command> ...   (see ./harness/run --help)"""

import argparse
import os
import shlex
import shutil
import sys
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor
from pathlib import Path

from . import checks, config, corpus, gen, perf, perfgen, proc, roadmap, sweep

TTY = sys.stdout.isatty()


def c(code: str, s: str) -> str:
    return f"\033[{code}m{s}\033[0m" if TTY else s


GREEN, RED, YELLOW, DIM, BOLD = "32", "31", "33", "2", "1"


def check_llvm_version():
    r = proc.run([config.llvm("opt"), "--version"])
    if f"LLVM version {config.LLVM_VERSION}" not in r.out.decode(errors="replace"):
        raise SystemExit(f"expected LLVM {config.LLVM_VERSION} at {config.LLVM_ROOT}; is this the llvm-rewrite workspace image?")


def passing_path(impl: str) -> Path:
    return config.IMPLS / impl / "passing.txt"


def read_passing(impl: str) -> set[str]:
    p = passing_path(impl)
    if impl == config.REFERENCE_IMPL or not p.exists():
        return set()
    return {l.strip() for l in p.read_text().splitlines() if l.strip() and not l.startswith("#")}


def write_passing(impl: str, ids: set[str]):
    passing_path(impl).write_text("".join(f"{i}\n" for i in sorted(ids)))


def build(impl: str, env: dict | None = None):
    if impl == config.REFERENCE_IMPL:
        return
    d = config.IMPLS / impl
    if not d.is_dir():
        raise SystemExit(f"no implementation at impl/{impl}")
    script = d / "build.sh"
    if not script.exists():
        raise SystemExit(f"impl/{impl}/build.sh is missing")
    extra = "".join(f" {k}={v}" for k, v in (env or {}).items())
    print(c(DIM, f"building impl/{impl}{extra} ..."), flush=True)
    r = proc.run(["bash", str(script)], cwd=d, timeout=3600, env=env)
    if not r.ok:
        sys.stdout.write(r.out.decode(errors="replace")[-5000:])
        sys.stdout.write(r.err_tail(5000))
        raise SystemExit(c(RED, f"impl/{impl}/build.sh failed"))


def all_ids(tests) -> list[tuple[corpus.TestFile, str]]:
    return [(t, ch) for t in tests for ch in t.checks()]


def select(tests, globs, unit_id, ratchet_only, passing):
    pairs = all_ids(tests)
    if ratchet_only:
        return [(t, ch) for t, ch in pairs if f"{t.path}::{ch}" in passing]
    sel = list(globs)
    if unit_id:
        sel += roadmap.get(unit_id).exit
    if not sel:
        return [] if unit_id else pairs
    return [(t, ch) for t, ch in pairs if corpus.match(f"{t.path}::{ch}", sel)]


def run_one_check(job) -> checks.Outcome:
    impl, t, ch = job
    try:
        return checks.run_check(ch, impl, t)
    except Exception as e:  # a harness bug; surface it loudly but keep going
        return checks.Outcome(f"{t.path}::{ch}", checks.FAIL, f"[harness exception] {type(e).__name__}: {e}")


def run_checks(impl, pairs, jobs, progress=True) -> list[checks.Outcome]:
    out = []
    n = len(pairs)
    # Each check is a few process spawns plus cache reads (hashing and JSON-decoding whole files): in threads that
    # Python work serializes on the GIL and was the bottleneck of a warm ratchet, so use worker processes. Small runs
    # stay in threads (a process pool costs ~0.1-0.2 s to start).
    pool = ProcessPoolExecutor if n >= 64 and jobs > 1 else ThreadPoolExecutor
    with pool(max_workers=jobs) as ex:
        kw = {"chunksize": max(1, min(16, n // (jobs * 8)))} if pool is ProcessPoolExecutor else {}
        for i, o in enumerate(ex.map(run_one_check, [(impl, t, ch) for t, ch in pairs], **kw), 1):
            out.append(o)
            if progress and TTY:
                print(f"\r{c(DIM, f'{i}/{n}')}", end="", flush=True)
    if progress and TTY:
        print("\r" + " " * 20 + "\r", end="")
    return out


def write_artifacts(impl, outcomes):
    for o in outcomes:
        path, ch = corpus.split_id(o.test_id)
        d = config.OUT / impl / path / ch
        shutil.rmtree(d, ignore_errors=True)
        if o.status == checks.PASS:
            continue
        d.mkdir(parents=True, exist_ok=True)
        (d / "message.txt").write_text(o.message + "\n")
        for name, text in o.artifacts.items():
            (d / name).write_text(text)


def summarize(outcomes):
    by = {}
    for o in outcomes:
        ch = corpus.split_id(o.test_id)[1]
        by.setdefault(ch, {checks.PASS: 0, checks.FAIL: 0, checks.INVALID: 0})[o.status] += 1
    for ch in corpus.CHECKS:
        if ch in by:
            s = by[ch]
            print(f"  {ch:10} {c(GREEN, str(s['pass']).rjust(6))} pass  {c(RED, str(s['fail']).rjust(6))} fail"
                  + (f"  {c(YELLOW, str(s['invalid']))} invalid" if s["invalid"] else ""))


def first_lines(msg, n):
    lines = msg.splitlines()
    return "\n".join("      " + l for l in lines[:n]) + ("\n      ..." if len(lines) > n else "")


def cmd_check(a):
    check_llvm_version()
    if not a.no_build:
        build(a.impl)
    tests = corpus.discover()
    passing = read_passing(a.impl)
    pairs = select(tests, a.globs, a.unit, a.ratchet_only, passing)
    print(c(BOLD, f"impl/{a.impl}: running {len(pairs)} checks"))
    outcomes = run_checks(a.impl, pairs, a.jobs)
    # A ratchet test that timed out gets one more try before it counts as a regression: CPU limits make timeouts
    # stable, but a test close to the limit (or a wall-clock backstop hit on a starved machine) can still flap.
    retry = [i for i, o in enumerate(outcomes) if o.test_id in passing and o.status != checks.PASS and checks.is_timeout(o)]
    if retry:
        print(c(YELLOW, f"retrying {len(retry)} timed-out ratchet test(s) once: "
                        + ", ".join(outcomes[i].test_id for i in retry[:5]) + (" ..." if len(retry) > 5 else "")))
        again = run_checks(a.impl, [pairs[i] for i in retry], a.jobs, progress=False)
        for i, o in zip(retry, again):
            if o.status == checks.PASS:
                print(c(DIM, f"  {o.test_id}: passed on retry"))
            outcomes[i] = o
    write_artifacts(a.impl, outcomes)
    summarize(outcomes)

    existing = {f"{t.path}::{ch}" for t, ch in all_ids(tests)}
    regress = [o for o in outcomes if o.test_id in passing and o.status != checks.PASS]
    new = sorted(o.test_id for o in outcomes if o.status == checks.PASS and o.test_id not in passing)
    invalid = [o for o in outcomes if o.status == checks.INVALID]
    fails = [o for o in outcomes if o.status == checks.FAIL]
    stale = sorted(passing - existing)

    if invalid:
        print(c(YELLOW, f"\n{len(invalid)} invalid tests (the oracle itself fails; fix or delete the test):"))
        for o in invalid[: a.max_shown]:
            print(f"  {o.test_id}\n{first_lines(o.message, 4)}")
    if a.verbose and fails:
        print(c(RED, f"\nfailures ({len(fails)}):"))
        for o in fails[: a.max_shown]:
            print(f"  {c(RED, o.test_id)}\n{first_lines(o.message, 30)}")
    if regress:
        print(c(RED, f"\n{len(regress)} REGRESSIONS (listed in impl/{a.impl}/passing.txt but not passing):"))
        for o in regress[: a.max_shown]:
            print(f"  {c(RED, o.test_id)}\n{first_lines(o.message, 8)}")
    if fails or invalid:
        print(c(DIM, f"\nartifacts for failures: {config.OUT.relative_to(config.REPO)}/{a.impl}/<test path>/<check>/"))
    if new and a.impl != config.REFERENCE_IMPL:
        print(c(GREEN, f"\n{len(new)} newly passing" + ("" if a.update else " (run with --update to record them)")))
        for i in new[: a.max_shown]:
            print(f"  {i}")
        if len(new) > a.max_shown:
            print(f"  ... and {len(new) - a.max_shown} more")
        slow = [o for o in outcomes if o.test_id in set(new) and o.cpu > config.TOOL_CPU_LIMIT / 2]
        if slow:
            print(c(YELLOW, f"\n{len(slow)} newly passing tests used more than half the CPU limit "
                            f"({config.TOOL_CPU_LIMIT:g}s) in one tool run; a slowdown could push them over:"))
            for o in slow[: a.max_shown]:
                print(f"  {o.test_id}  ({o.cpu:.0f}s)")
    if stale:
        print(c(YELLOW, f"\n{len(stale)} entries in passing.txt no longer exist" + (" (removed)" if a.update else " (--update removes them)")))

    if a.update and a.impl != config.REFERENCE_IMPL:
        if regress:
            print(c(RED, "\nnot updating passing.txt: fix the regressions first"))
        else:
            write_passing(a.impl, (passing - set(stale)) | set(new))
            print(c(GREEN, f"\nimpl/{a.impl}/passing.txt updated"))

    ok = not regress and not (a.impl == config.REFERENCE_IMPL and invalid)
    if a.unit:
        u = roadmap.get(a.unit)
        missing_files = [f for f in u.exit_files if not (config.IMPLS / a.impl / f).exists()]
        complete = bool(pairs or u.exit_files) and all(o.status == checks.PASS for o in outcomes) and not missing_files
        if not pairs and u.exit:
            print(c(YELLOW, f"\nunit {u.id}: its exit selector matches no tests yet; the corpus needs tests first"))
        for f in missing_files:
            print(c(RED, f"\nunit {u.id}: impl/{a.impl}/{f} does not exist"))
        print(c(GREEN if complete else RED, f"\nunit {u.id}: {'COMPLETE' if complete else 'not complete'} for impl/{a.impl}"))
        ok = ok and complete
    sys.exit(0 if ok else 1)


def cmd_status(a):
    tests = corpus.discover()
    ids = [f"{t.path}::{ch}" for t, ch in all_ids(tests)]
    impls = [i for i in config.impls()]
    passing = {i: read_passing(i) for i in impls}
    print(c(BOLD, f"{len(tests)} test files, {len(ids)} checks\n"))
    w = max([len(u.id) for u in roadmap.units()] + [10])
    print(f"{'unit':{w}}  " + "  ".join(f"{i:<12}" for i in impls))
    for u in roadmap.units():
        sel = [i for i in ids if corpus.match(i, u.exit)] if u.exit else []
        row = []
        for impl in impls:
            files_ok = all((config.IMPLS / impl / f).exists() for f in u.exit_files)
            if not u.exit:
                cell = c(GREEN, "done") if (u.exit_files and files_ok) else "todo"
            elif not sel:
                cell = c(YELLOW, "no tests")
            else:
                n = sum(1 for i in sel if i in passing[impl])
                cell = c(GREEN, "done") if n == len(sel) and files_ok else f"{n}/{len(sel)}"
            row.append(cell + " " * max(0, 12 - len(strip_ansi(cell))))
        print(f"{u.id:{w}}  " + "  ".join(row))
    print()
    for ch in corpus.CHECKS:
        tot = sum(1 for i in ids if i.endswith("::" + ch))
        print(f"{ch:10} {tot:6} checks   " + "  ".join(f"{impl}: {sum(1 for i in passing[impl] if i.endswith('::' + ch))}" for impl in impls))


def strip_ansi(s):
    import re
    return re.sub(r"\033\[[0-9;]*m", "", s)


def cmd_show(a):
    check_llvm_version()
    if not a.no_build:
        build(a.impl)
    tests = {t.path: t for t in corpus.discover()}
    path, ch = (a.test.rsplit("::", 1) + [None])[:2] if "::" in a.test else (a.test, None)
    t = tests.get(path)
    if not t:
        raise SystemExit(f"no test file {path}")
    for check in [ch] if ch else t.checks():
        o = checks.CHECK_FNS[check](a.impl, t)
        write_artifacts(a.impl, [o])
        col = GREEN if o.status == checks.PASS else RED
        print(c(col, f"{o.test_id}: {o.status}"))
        if o.message:
            print(o.message)
        if o.status != checks.PASS:
            print(c(DIM, f"artifacts: {(config.OUT / a.impl / path / check).relative_to(config.REPO)}/"))
        print()


def cmd_bisect(a):
    """Find the first pass in an @opt pipeline where the implementation's output diverges from LLVM's."""
    check_llvm_version()
    if not a.no_build:
        build(a.impl)
    path = a.test.split("::")[0]
    t = corpus.parse(config.REPO / path)
    if not t.opt:
        raise SystemExit("bisect needs a test with @opt")
    args = t.opt[a.index]
    if t.is_lto:  # bisect the post-link pipeline on LLVM's linked module
        link = checks.oracle_link(t)
        if not link["ok"]:
            raise SystemExit("llvm-link fails:\n" + link["text"])
        d = config.OUT / "bisect" / path
        d.mkdir(parents=True, exist_ok=True)
        (d / "linked.ll").write_text(link["text"])
        t = corpus.TestFile(str((d / "linked.ll").relative_to(config.REPO)), opt=t.opt)
        print(f"bisecting on LLVM's linked module {t.path}")

    def outputs(n):
        res = {}
        for who, b in (("llvm", config.llvm("opt")), ("impl", config.impl_bin(a.impl, "opt"))):
            with proc.Workdir() as wd:
                r = checks.tool_opt(b, f"{args} -opt-bisect-limit={n}", Path(t.path), wd / "o.ll", config.REPO)
                if not r.ok:
                    res[who] = (False, r.err_tail(), r.err.decode(errors="replace"))
                    continue
                ok, txt = checks.canon((wd / "o.ll").read_text(errors="replace"))
                res[who] = (ok, txt, r.err.decode(errors="replace"))
        return res

    log = outputs(10**9)["llvm"][2]
    names = [l.split(")", 1)[1].strip() for l in log.splitlines() if l.startswith("BISECT: running pass")]
    total = len(names)
    print(f"{total} bisectable passes in `{args}`")

    def same(n):
        r = outputs(n)
        return r["llvm"][0] and r["impl"][0] and r["llvm"][1] == r["impl"][1]

    if not same(0):
        print(c(RED, "outputs already differ with -opt-bisect-limit=0 (no optional passes run): the difference is in parsing/printing or a required pass"))
        return
    if same(total):
        print(c(GREEN, "outputs are identical with all passes enabled"))
        return
    lo, hi = 0, total  # same(lo), not same(hi)
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if same(mid):
            lo = mid
        else:
            hi = mid
    print(c(RED, f"first divergence at pass ({hi}): {names[hi - 1]}"))
    print(f"reproduce: opt {args} -opt-bisect-limit={hi} vs -opt-bisect-limit={lo}")


def main(argv=None):
    p = argparse.ArgumentParser(prog="harness/run", description="llvm-rewrite test harness (oracle: LLVM " + config.LLVM_VERSION + ")")
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp, impl_required=True):
        sp.add_argument("--impl", required=impl_required, help="implementation under impl/, or 'llvm' for LLVM itself")
        sp.add_argument("--no-build", action="store_true", help="skip impl/<lang>/build.sh")

    s = sub.add_parser("check", help="run checks against LLVM; enforces the ratchet")
    common(s)
    s.add_argument("globs", nargs="*", help="test ID / path globs, e.g. 'tests/e2e/O0/*::run'")
    s.add_argument("--unit", help="select the exit tests of a roadmap unit and report completion")
    s.add_argument("--update", action="store_true", help="record newly passing tests in passing.txt")
    s.add_argument("--ratchet-only", action="store_true", help="only run tests already in passing.txt")
    s.add_argument("-j", "--jobs", type=int, default=os.cpu_count())
    s.add_argument("-v", "--verbose", action="store_true", help="print failure details")
    s.add_argument("--max-shown", type=int, default=25)
    s.set_defaults(fn=cmd_check)

    s = sub.add_parser("status", help="unit x implementation scoreboard (from passing.txt files; runs nothing)")
    s.set_defaults(fn=cmd_status)

    s = sub.add_parser("show", help="run one test file (or one test ID) and print full details")
    common(s)
    s.add_argument("test")
    s.set_defaults(fn=cmd_show)

    s = sub.add_parser("bisect", help="find the first pass of an @opt pipeline whose output diverges")
    common(s)
    s.add_argument("test")
    s.add_argument("--index", type=int, default=0, help="which @opt line")
    s.set_defaults(fn=cmd_bisect)

    s = sub.add_parser("sweep", help="run one pipeline over every round-tripping corpus file, LLVM vs impl (report only)",
                       description="Run `opt -passes=<pipeline> -S` (or, with --analysis, `-disable-output`) with LLVM and the "
                       "implementation on every selected corpus file and compare like ::opt (or ::analysis). Default files: "
                       "every ::roundtrip in impl/<lang>/passing.txt, without tests/perf. Never touches passing.txt.")
    common(s)
    s.add_argument("globs", nargs="*", help="restrict to these path globs, e.g. 'tests/imported/*' (also selects tests/perf files)")
    s.add_argument("--passes", help="the pipeline, as for opt -passes=, e.g. 'sroa' or 'function(loop-mssa(licm))'")
    s.add_argument("--extra", default="", help="more opt arguments as one string; write it with '=': --extra='-aa-pipeline=basic-aa -O2'")
    s.add_argument("--analysis", action="store_true", help="analysis-printer mode: -disable-output, compare exit status, stdout and stderr")
    s.add_argument("--unordered", action="store_true", help="with --analysis: compare lines as sorted multisets (like @analysis-unordered)")
    s.add_argument("--all-files", action="store_true", help="every corpus file, not just the ones the impl round-trips")
    s.add_argument("--per-function", action="store_true", help="split every file into one module per defined function "
                   "(llvm-extract) and compare each piece separately")
    s.add_argument("--with-test-flags", action="store_true", help="run each file once per distinct set of extra flags in its "
                   "own @opt/@analysis directives (-mtriple, -mattr, -mcpu, -data-layout, pass cl::opts; not -passes/-O/-S/-o)")
    s.add_argument("--timeout", type=float, default=60, help="CPU seconds per run of the implementation's opt (default 60; "
                   f"wall-clock backstop {config.TOOL_WALL_FACTOR}x that)")
    s.add_argument("-j", "--jobs", type=int, default=os.cpu_count())
    s.add_argument("-v", "--verbose", action="store_true", help="print the diff of every silent mismatch shown")
    s.add_argument("--max-shown", type=int, default=25)
    s.set_defaults(fn=sweep.cmd_sweep)

    s = sub.add_parser("from-c", help="generate e2e/function/lto tests from C sources (with UB validation)")
    s.add_argument("sources", nargs="+", help="tests/e2e/src/<area>/x.c, tests/function/src/<area>/x.c, or a "
                   "directory tests/lto/src/<area>/<name>/ of translation units (one multi-module LTO test)")
    s.add_argument("--force", action="store_true", help="overwrite existing .ll files")
    s.set_defaults(fn=gen.cmd_from_c)

    s = sub.add_parser("import-llvm", help="import LLVM regression tests as @opt and @analysis tests")
    s.add_argument("dirs", nargs="+", help="directories relative to llvm/test, e.g. Transforms/Mem2Reg")
    s.set_defaults(fn=gen.cmd_import_llvm)

    s = sub.add_parser("import-test-suite", help="import llvm-test-suite SingleSource C programs as e2e tests")
    s.add_argument("dirs", nargs="+", help="directories relative to llvm-test-suite, e.g. SingleSource/UnitTests")
    s.set_defaults(fn=gen.cmd_import_test_suite)

    s = sub.add_parser("perf", help="compile-time benchmarks: our tools vs LLVM on tests/perf (report only)")
    s.add_argument("--impl", required=True, help="one implementation, or several separated by commas (e.g. goose,jai)")
    s.add_argument("--no-build", action="store_true", help="skip impl/<lang>/build.sh")
    s.add_argument("globs", nargs="*", help="path globs, default all of tests/perf (e.g. 'tests/perf/scaling/allocas/*')")
    s.add_argument("--instr", action="store_true", help="also count executed instructions with valgrind (exact, ~40x slower; cached)")
    s.add_argument("--reps", type=int, default=0, help="runs per tool and benchmark (default: until ~1s of samples, max 5)")
    s.add_argument("-j", "--jobs", type=int, default=0, help="parallel timed runs (default: half the cores)")
    s.add_argument("--no-history", action="store_true", help="don't append this run to the history")
    s.set_defaults(fn=perf.cmd_perf)

    s = sub.add_parser("gen-perf", help="regenerate tests/perf (llvm-test-suite programs and synthetic scaling shapes)")
    s.add_argument("--clean", action="store_true", help="delete tests/perf first")
    s.set_defaults(fn=perfgen.cmd_gen_perf)

    a = p.parse_args(argv)
    a.fn(a)
