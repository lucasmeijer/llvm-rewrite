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
  failed       our opt exited nonzero (or hit its CPU limit / crashed): a loud failure, grouped by its first error line
  llvm-failed  LLVM's opt fails on this file with these args (or is nondeterministic): skipped

--per-function: every defined function is cut into its own module (llvm-extract) and compared separately; the
outcomes above are then per function. See the section below and "--per-function" in docs/testing.md.

--with-test-flags: every file is run once per distinct set of extra flags its own @opt/@analysis directives carry
(-mtriple, -mattr, -mcpu, -data-layout, pass cl::opts, ...; never the pipeline or output flags), so that
target-specific code is exercised. See test_flag_sets() and "--with-test-flags" in docs/testing.md.
"""

import hashlib
import json
import os
import re
import shlex
import shutil
import sys
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor
from pathlib import Path

from . import checks, config, corpus, proc

IDENTICAL, DIFFERS, BAD_IR, FAILED, LLVM_FAILED = "identical", "differs", "bad-ir", "failed", "llvm-failed"
ORDER = (IDENTICAL, DIFFERS, BAD_IR, FAILED, LLVM_FAILED)


def slug(args: str) -> str:
    s = re.sub(r"[^A-Za-z0-9_.,=+-]+", "_", args.replace("-passes=", "")).strip("_-") or "none"
    if len(s) > 80:
        s = s[:64] + "-" + hashlib.sha256(args.encode()).hexdigest()[:12]
    return s


def error_key(stderr: str, path: str, rc: int, timeout_msg: str = "") -> str:
    """The first meaningful stderr line, with the file name and line/column numbers taken out, for grouping."""
    if timeout_msg:
        return f"[{timeout_msg.split(';')[0]}{')' if ';' in timeout_msg else ''}]"
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


# ---------------------------------------------------------------- --with-test-flags
#
# Flags of a directive that are NOT carried: the pipeline (the sweep supplies its own) and the I/O mode (the sweep
# supplies -S/-o or -disable-output). Also the ones that change which passes run rather than the context they run in.
DROP_FLAGS = {"passes", "p", "O0", "O1", "O2", "O3", "Os", "Oz", "S", "o", "disable-output", "f",
              "opt-bisect-limit", "run-twice", "debug-pass-manager", "print-after-all", "print-before-all",
              "print-changed", "time-passes"}
# Options whose value may be written as a separate token (`-passes loop-reduce`): for dropped options only; any
# other `-flag value` pair is kept as written (see split_flags).
WITH_VALUE = {"passes", "p", "o"}


def flag_name(tok: str) -> str:
    return tok.lstrip("-").split("=", 1)[0]


def split_flags(args: str) -> list[list[str]]:
    """opt arguments -> [[flag, (separate value)], ...]. A token not starting with '-' is the value of the flag before
    it (`-mtriple x86_64`, `-internalize-public-api-list main`); directives never name an input file."""
    out = []
    for tok in shlex.split(args):
        if tok.startswith("-") and tok != "-" or not out:
            out.append([tok])
        else:
            out[-1].append(tok)
    return out


def carried_flags(args: str, own: set[str]) -> str:
    """The flags of one directive that --with-test-flags adds to the sweep's arguments, as one string."""
    kept = []
    for grp in split_flags(args):
        name = flag_name(grp[0])
        if not grp[0].startswith("-") or name in DROP_FLAGS or name in own:
            continue
        kept += grp
    return shlex.join(kept)


def test_flag_sets(t, own_args: str) -> list[str]:
    """The distinct flag sets of a test file's @opt, @analysis and @analysis-unordered directives, in first-seen order
    (a file without directives gets none). Options the sweep's own arguments already set win (not repeated)."""
    own = {flag_name(g[0]) for g in split_flags(own_args)}
    sets = []
    for args in t.opt + [a for a, _ in t.analysis]:
        f = carried_flags(args, own)
        if f not in sets:
            sets.append(f)
    return sets


def join_args(args: str, flags: str) -> str:
    return f"{args} {flags}" if flags else args


def run_impl(impl: str, args: str, in_arg: str, cwd, wd: Path, analysis: bool, timeout: float) -> proc.Res:
    opt = config.impl_bin(impl, "opt")
    if analysis:
        cmd = [opt, *shlex.split(args), "-disable-output", in_arg]
    else:
        cmd = [opt, *shlex.split(args), "-S", in_arg, "-o", str(wd / "out.ll")]
    return proc.run_limited(cmd, cwd=cwd, cpu_limit=timeout)


def compare(impl: str, args: str, analysis: bool, unordered: bool, timeout: float, exp: dict,
            in_arg: str, cwd, res: dict) -> dict:
    """Run the implementation on `in_arg` (relative to `cwd`) and compare with LLVM's result `exp` (from the oracle,
    already canonicalized in IR mode). Fills in res: status, key, message, artifacts."""
    with proc.Workdir() as wd:
        r = run_impl(impl, args, in_arg, cwd, wd, analysis, timeout)
        err = r.err.decode(errors="replace")
        if not r.ok:
            res.update(status=FAILED, key=error_key(err, in_arg, r.rc, r.timeout_msg),
                       message=f"{r.fail_msg('opt')}:\n{r.err_tail()}", artifacts={**res["artifacts"], "stderr.txt": r.err_tail(20000)})
            return res
        if not analysis:
            act = (wd / "out.ll").read_text(errors="replace") if (wd / "out.ll").exists() else ""
    arts = dict(res["artifacts"])
    if analysis:
        problems = []
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
                   artifacts={**arts, "actual.ll": act, "llvm-as.txt": act_c, "stderr.txt": err})
    elif act_c != exp["canon"]:
        res.update(status=DIFFERS, message="canonicalized IR differs:\n" + checks.diff(exp["canon"], act_c),
                   artifacts={**arts, "expected.ll": exp["canon"], "actual.ll": act_c, "diff.txt": checks.full_diff(exp["canon"], act_c)})
    return res


def canon_expected(exp: dict) -> dict:
    """IR mode: canonicalize LLVM's output (adds "canon"); not ok if it does not re-assemble."""
    if exp["ok"]:
        ok, exp_c = checks.canon(exp["text"])
        if not ok:
            return {"ok": False, "text": "LLVM's output does not re-assemble:\n" + exp_c}
        return {**exp, "canon": exp_c}
    return exp


def new_res(path: str, **extra) -> dict:
    return {"path": path, "status": IDENTICAL, "key": "", "message": "", "artifacts": {}, **extra}


def sweep_one(impl: str, path: str, flags: str | None, args: str, analysis: bool, unordered: bool, timeout: float) -> dict:
    """-> {path, flags, status, key (for failed), message, artifacts}. flags: from --with-test-flags (None: off)."""
    t = corpus.TestFile(path)
    res = new_res(path, flags=flags)
    args = join_args(args, flags or "")
    exp = checks.oracle_analysis(t, args, unordered) if analysis else canon_expected(checks.oracle_opt(t, args))
    if not exp["ok"]:
        res.update(status=LLVM_FAILED, message=exp["text"])
        return res
    return compare(impl, args, analysis, unordered, timeout, exp, path, config.REPO, res)


# ---------------------------------------------------------------- --per-function: one module per defined function
#
# Every defined function is cut out of its file with `llvm-extract --keep-const-init --func=<name>` (other functions
# become declarations; unreferenced globals are dropped, referenced ones keep their initializer only if constant;
# local linkage becomes external hidden, linkonce becomes weak). Unnamed functions (@0) cannot be named on the
# llvm-extract command line, so for those the file first goes through `opt -passes=name-anon-globals`. Each piece is
# then an ordinary input: LLVM and the implementation both run on the same piece (written as input.ll in a temporary
# directory, so outputs do not depend on paths), compared as in whole-file mode. Splitting and LLVM's results are
# cached in the oracle cache.

DEFINE = re.compile(r'^define\b[^@\n]*@("[^"]*"|[-a-zA-Z$._0-9]+)\(', re.M)
PIECE = "input.ll"


def unescape_name(tok: str) -> str:
    """An LLVM global name token (without @) -> the raw name; quoted names use \\XX hex escapes."""
    if not tok.startswith('"'):
        return tok
    body, out, i = tok[1:-1].encode(), bytearray(), 0
    while i < len(body):
        if body[i] == 0x5C and i + 1 < len(body) and body[i + 1] == 0x5C:
            out.append(0x5C)
            i += 2
        elif body[i] == 0x5C and i + 2 < len(body):
            out.append(int(body[i + 1:i + 3], 16))
            i += 3
        else:
            out.append(body[i])
            i += 1
    return os.fsdecode(bytes(out))


def list_functions(path: str) -> tuple[bool, list[str] | str]:
    """The defined functions of a file in order, as LLVM prints their names (`foo`, `"a b"`, `0` for unnamed),
    or (False, error) if LLVM cannot parse the file."""
    ok, text = checks.canon(checks.read(path))
    if not ok:
        return False, text
    return True, DEFINE.findall(text)


def extract_piece(path: str, idx: int, tok: str) -> dict:
    """{ok, text} : the module holding just the idx-th defined function of `path` (token `tok`)."""
    src = checks.read(path)

    def compute():
        text, name = src, tok
        if tok.isdigit():  # unnamed: name everything anonymous first, then find the idx-th define again
            r = proc.run([config.llvm("opt"), "-passes=name-anon-globals", "-S", "-", "-o", "-"], stdin=src.encode())
            if not r.ok:
                return {"ok": False, "text": "opt -passes=name-anon-globals failed:\n" + r.err_tail()}
            text = r.out.decode(errors="replace")
            toks = DEFINE.findall(text)
            if idx >= len(toks) or toks[idx].isdigit():
                return {"ok": False, "text": f"could not name unnamed function @{tok}"}
            name = toks[idx]
        r = proc.run([config.llvm("llvm-extract"), "-S", "--keep-const-init", f"--func={unescape_name(name)}", "-", "-o", "-"],
                     stdin=text.encode())
        if not r.ok:
            return {"ok": False, "text": "llvm-extract failed:\n" + r.err_tail()}
        return {"ok": True, "text": r.out.decode(errors="replace")}

    piece = proc.cached(["extract-function", src, idx, tok], compute)
    if piece["ok"]:
        ok, err = checks.canon(piece["text"])
        if not ok:  # e.g. an alias whose type no longer fits, llvm.localrecover of a function that became a declaration
            return {"ok": False, "text": "llvm-extract produced a module that does not verify (a limit of per-function mode):\n" + err}
    return piece


def oracle_piece(text: str, args: str, analysis: bool, unordered: bool) -> dict:
    """LLVM's result on a piece, like checks.oracle_opt / oracle_analysis but on text (run as input.ll)."""

    def compute():
        with proc.Workdir() as wd:
            (wd / PIECE).write_text(text)
            if not analysis:
                r = checks.tool_opt(config.llvm("opt"), args, Path(PIECE), wd / "out.ll", wd)
                if not r.ok:
                    return {"ok": False, "text": r.err_tail()}
                return {"ok": True, "text": (wd / "out.ll").read_text(errors="replace")}
            runs = [checks.tool_analysis(config.llvm("opt"), args, Path(PIECE), wd) for _ in range(2)]
        if not runs[0].ok:
            return {"ok": False, "text": runs[0].err_tail()}
        outs = [(checks.analysis_canon(x.out.decode(errors="replace"), unordered),
                 checks.analysis_canon(x.err.decode(errors="replace"), unordered)) for x in runs]
        if outs[0] != outs[1]:
            return {"ok": False, "text": "output is nondeterministic (differs between two runs of LLVM's opt):\n"
                    + checks.diff(outs[0][1], outs[1][1], 20)}
        return {"ok": True, "stdout": outs[0][0], "stderr": outs[0][1]}

    exp = proc.cached(["piece-analysis" if analysis else "piece-opt", text, args, analysis and unordered], compute)
    return exp if analysis else canon_expected(exp)


def sweep_function(impl: str, path: str, idx: int, tok: str, flags: str | None, args: str, analysis: bool, unordered: bool,
                   timeout: float) -> dict:
    res = new_res(path, func="@" + tok, idx=idx, flags=flags)
    args = join_args(args, flags or "")
    piece = extract_piece(path, idx, tok)
    if not piece["ok"]:
        res.update(status=LLVM_FAILED, message=piece["text"])
        return res
    res["artifacts"] = {PIECE: piece["text"]}
    exp = oracle_piece(piece["text"], args, analysis, unordered)
    if not exp["ok"]:
        res.update(status=LLVM_FAILED, message=exp["text"])
        return res
    with proc.Workdir() as wd:
        (wd / PIECE).write_text(piece["text"])
        compare(impl, args, analysis, unordered, timeout, exp, PIECE, wd, res)
    if res["status"] != IDENTICAL:
        res["message"] = (f"function @{tok} of {path}; reproduce in this directory with "
                          f"`opt {args} {'-disable-output' if analysis else '-S'} {PIECE}`\n" + res["message"])
    return res


def file_job(job) -> dict:
    (path, flags), (impl, args, analysis, unordered, timeout) = job
    try:
        return sweep_one(impl, path, flags, args, analysis, unordered, timeout)
    except Exception as e:  # a harness bug; surface it loudly but keep going
        return new_res(path, flags=flags, status=FAILED, key=f"[harness exception] {type(e).__name__}: {e}",
                       message=f"[harness exception] {type(e).__name__}: {e}")


def function_job(job) -> dict:
    (path, i, tok, flags), (impl, args, analysis, unordered, timeout) = job
    try:
        return sweep_function(impl, path, i, tok, flags, args, analysis, unordered, timeout)
    except Exception as e:  # a harness bug; surface it loudly but keep going
        return new_res(path, func="@" + tok, idx=i, flags=flags, status=FAILED, key=f"[harness exception] {type(e).__name__}: {e}",
                       message=f"[harness exception] {type(e).__name__}: {e}")


def label(r: dict) -> str:
    s = f"{r['path']} {r['func']}" if r.get("func") else r["path"]
    return s + (f" [{r['flags']}]" if r.get("flags") else "")


def select_files(a, tests, passing) -> tuple[list[str], int]:
    """Files to sweep, and how many tests/perf files were left out by default."""
    if a.all_files or a.impl == config.REFERENCE_IMPL:
        files = [t.path for t in tests if not t.is_lto]
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
    # (file, flags) units; flags is None without --with-test-flags.
    if a.with_test_flags:
        by_path = {t.path: t for t in tests}
        units = [(f, fl) for f in files for fl in (test_flag_sets(by_path[f], args) or [""])]
    else:
        units = [(f, None) for f in files]
    mode = "analysis (stdout+stderr" + (", lines sorted" if a.unordered else "") + ")" if a.analysis else "IR (canonicalized)"
    print(c(BOLD, f"impl/{a.impl}: sweep `opt {args}` over {len(files)} files, {mode}"))
    if a.with_test_flags:
        print(c(DIM, f"  with test flags: {len(units)} (file, flag set) runs, {len({fl for _, fl in units})} distinct flag sets, "
                f"{sum(1 for _, fl in units if fl)} runs with flags"))
    if perf_skipped:
        print(c(DIM, f"  ({perf_skipped} tests/perf files left out; select them with a glob)"))
    if not files:
        print(c(YELLOW, "no files selected" + ("" if a.all_files else " (default: files listed as ::roundtrip in passing.txt; --all-files for every file)")))
        return

    def progress(i, n):
        if TTY:
            print(f"\r{c(DIM, f'{i}/{n}')}", end="", flush=True)

    results = []
    with ThreadPoolExecutor(max_workers=a.jobs) as ex:
        if not a.per_function:
            # Worker processes, as for --per-function below (the harness's own Python work is GIL-bound in threads).
            with ProcessPoolExecutor(max_workers=a.jobs) as pex:
                fixed = (a.impl, args, a.analysis, a.unordered, a.timeout)
                rs = pex.map(file_job, [(u, fixed) for u in units], chunksize=4)
                for i, r in enumerate(rs, 1):
                    results.append(r)
                    progress(i, len(units))
        else:
            jobs, no_defs, nfuncs = [], 0, 0
            flag_sets = {}
            for path, fl in units:
                flag_sets.setdefault(path, []).append(fl)
            for path, (ok, toks) in zip(files, ex.map(list_functions, files)):
                if not ok:
                    results.append(new_res(path, func="", idx=-1, status=LLVM_FAILED, message="LLVM cannot parse the file:\n" + toks))
                elif not toks:
                    no_defs += 1
                nfuncs += len(toks) if ok else 0
                jobs += [(path, i, tok, fl) for i, tok in enumerate(toks if ok else []) for fl in flag_sets[path]]
            print(c(DIM, f"  per function: {nfuncs} defined functions"
                    + (f" ({no_defs} files without any)" if no_defs else "")
                    + (f", {len(jobs)} (function, flag set) runs" if a.with_test_flags else "")))

            # Many small jobs, each mostly process spawns and cache reads: threads serialize on the GIL there, so
            # use worker processes.
            with ProcessPoolExecutor(max_workers=a.jobs) as pex:
                fixed = (a.impl, args, a.analysis, a.unordered, a.timeout)
                for i, r in enumerate(pex.map(function_job, [(j, fixed) for j in jobs], chunksize=8), 1):
                    results.append(r)
                    progress(i, len(jobs))
    if TTY:
        print("\r" + " " * 20 + "\r", end="")

    # Artifacts: .harness-out/sweep/<impl>/<args slug>/<test path>/[<index>-<function>/], plus results.tsv and summary.json.
    out = config.OUT / "sweep" / a.impl / slug(("per-function " if a.per_function else "") + ("analysis " if a.analysis else "")
                                               + ("with-test-flags " if a.with_test_flags else "") + args)
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True, exist_ok=True)
    (out / "args.txt").write_text(args + ("\n(analysis" + (", unordered" if a.unordered else "") + ")" if a.analysis else "")
                                  + ("\n(per function)" if a.per_function else "")
                                  + ("\n(with test flags)" if a.with_test_flags else "") + "\n")
    for r in results:
        if r["status"] == IDENTICAL:
            continue
        d = out / r["path"]
        if r.get("flags") is not None:
            d = d / ("with-" + slug(r["flags"]))
            r["message"] = f"with test flags: {r['flags'] or '(none)'}\n" + r["message"]
        if r.get("func"):
            r["dir"] = f"{r['idx']:04d}-" + re.sub(r"[^A-Za-z0-9_.$-]+", "_", r["func"][1:].strip('"'))[:60]
            d = d / r["dir"]
        d.mkdir(parents=True, exist_ok=True)
        (d / "message.txt").write_text(r["message"] + "\n")
        for name, text in r["artifacts"].items():
            (d / name).write_text(text)
    def row(r):
        cols = [r["status"], r["path"]] + ([r["flags"] or ""] if a.with_test_flags else []) + ([r.get("func", "")] if a.per_function else [])
        return "\t".join(cols + [r["key"]]) + "\n"
    (out / "results.tsv").write_text("".join(row(r) for r in results))

    by = {s: [r for r in results if r["status"] == s] for s in ORDER}
    groups = {}
    for r in by[FAILED]:
        groups.setdefault(r["key"], []).append(label(r))
    groups = sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[0]))
    (out / "summary.json").write_text(json.dumps({
        "impl": a.impl, "args": args, "analysis": a.analysis, "unordered": a.unordered, "per_function": a.per_function,
        "with_test_flags": a.with_test_flags,
        "counts": {s: len(by[s]) for s in ORDER},
        "silent": [label(r) for r in by[DIFFERS] + by[BAD_IR]],
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
            print(f"  {c(RED, r['status'].ljust(7))} {label(r)}" + (c(DIM, f"  ({r['dir']})") if r.get("dir") else ""))
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
            print(f"  {label(r)}: {(r['message'].strip().splitlines() or [''])[0][:150]}")
    what = "<test path>/" + ("with-<flags>/" if a.with_test_flags else "") + (
        "<n>-<function>/ for every non-identical function" if a.per_function else " for every non-identical file")
    print(c(DIM, f"\nartifacts: {out.relative_to(config.REPO)}/  (results.tsv, summary.json, {what})"))
    sys.exit(0)
