"""The five checks. Each compares an implementation against LLVM (the oracle).

  roundtrip  `opt -S in.ll` with no passes; the printed text must be byte-identical (printer fidelity).
  opt        `opt <args> -S`; both outputs are canonicalized via `llvm-as | llvm-dis` and must be identical.
  analysis   `opt <args> -disable-output` (analysis printers such as `print<domtree>`); exit status, stdout and
             stderr must be identical (for @analysis-unordered: identical after sorting their lines). LLVM is run
             twice; output that differs between the two runs (after sorting, if unordered) is `invalid`.
  isel-ir    the IR that reaches instruction selection: `llc <args> -stop-before=x86-isel`. The input is
             LLVM's opt output (if the test has @opt), so this check is isolated from the opt check.
             Canonicalized and compared exactly.
  run        the full pipeline with the implementation's own tools (opt if @opt, then llc), linked by clang,
             executed; stdout and exit code must match the LLVM-built program.
"""

import difflib
import shlex
from dataclasses import dataclass, field
from pathlib import Path

from . import config, proc
from .corpus import TestFile

PASS, FAIL, INVALID = "pass", "fail", "invalid"


@dataclass
class Outcome:
    test_id: str
    status: str
    message: str = ""
    artifacts: dict = field(default_factory=dict)  # filename -> text, written for failures


def diff(expected: str, actual: str, limit: int = 60) -> str:
    lines = list(difflib.unified_diff(expected.splitlines(), actual.splitlines(), "expected (llvm)", "actual", lineterm="", n=2))
    if len(lines) > limit:
        lines = lines[:limit] + [f"... ({len(lines) - limit} more diff lines, see diff.txt)"]
    return "\n".join(lines)


def full_diff(expected: str, actual: str) -> str:
    return "\n".join(difflib.unified_diff(expected.splitlines(), actual.splitlines(), "expected (llvm)", "actual", lineterm="", n=3))


def read(path: str) -> str:
    return (config.REPO / path).read_text(encoding="utf-8", errors="replace")


# ---------------------------------------------------------------- LLVM helpers (pure functions of content, cached)

def canon(text: str) -> tuple[bool, str]:
    """Round-trip IR through LLVM's assembler/disassembler; also runs the verifier."""

    def compute():
        a = proc.run([config.llvm("llvm-as"), "-", "-o", "-"], stdin=text.encode())
        if not a.ok:
            return {"ok": False, "text": a.err_tail()}
        d = proc.run([config.llvm("llvm-dis"), "-", "-o", "-"], stdin=a.out)
        if not d.ok:
            return {"ok": False, "text": d.err_tail()}
        return {"ok": True, "text": d.out.decode(errors="replace")}

    r = proc.cached(["canon", text], compute)
    return r["ok"], r["text"]


def extract_ir(text: str) -> str:
    """llc -stop-before writes MIR; the IR module is the YAML block between `--- |` and `...`."""
    if not text.startswith("--- |"):
        return text
    out = []
    for line in text.splitlines()[1:]:
        if line == "..." or line.startswith("---"):
            break
        out.append(line[2:] if line.startswith("  ") else line.lstrip())
    return "\n".join(out) + "\n"


def tool_opt(opt_bin: str, args: str, in_path: Path, out_path: Path, cwd) -> proc.Res:
    return proc.run([opt_bin, *shlex.split(args), "-S", str(in_path), "-o", str(out_path)], cwd=cwd)


def tool_analysis(opt_bin: str, args: str, in_path: Path, cwd) -> proc.Res:
    return proc.run([opt_bin, *shlex.split(args), "-disable-output", str(in_path)], cwd=cwd)


def tool_isel(llc_bin: str, args: str, in_path: Path, out_path: Path) -> proc.Res:
    return proc.run([llc_bin, *shlex.split(args), f"-stop-before={config.ISEL_PASS}", str(in_path), "-o", str(out_path)])


def build_and_run(opt_bin, llc_bin, t: TestFile, wd: Path) -> dict:
    """opt (if any) -> llc -> clang link -> run. Returns {stage, ok, rc, stdout, msg}."""
    ir = config.REPO / t.path
    if t.opt:
        r = tool_opt(opt_bin, t.opt[0], ir, wd / "opt.ll", config.REPO)
        if not r.ok:
            return {"ok": False, "stage": "opt", "msg": r.err_tail()}
        ir = wd / "opt.ll"
    r = proc.run([llc_bin, *shlex.split(t.llc), str(ir), "-o", str(wd / "out.s")])
    if not r.ok:
        return {"ok": False, "stage": "llc", "msg": r.err_tail()}
    link = [config.llvm("clang"), "-no-pie", "-w", "-O1", str(wd / "out.s")]
    if t.driver:
        link.append(str(config.REPO / t.driver))
    r = proc.run(link + ["-lm", "-o", str(wd / "prog")])
    if not r.ok:
        return {"ok": False, "stage": "link", "msg": r.err_tail()}
    r = proc.run([str(wd / "prog")], cwd=wd, timeout=config.RUN_TIMEOUT)
    if r.timed_out:
        return {"ok": False, "stage": "run", "msg": f"timed out after {config.RUN_TIMEOUT}s"}
    return {"ok": True, "stage": "run", "rc": r.rc, "stdout": r.out.decode(errors="replace"), "msg": ""}


def oracle_opt(t: TestFile, args: str) -> dict:
    def compute():
        with proc.Workdir() as wd:
            r = tool_opt(config.llvm("opt"), args, Path(t.path), wd / "out.ll", config.REPO)
            if not r.ok:
                return {"ok": False, "text": r.err_tail()}
            return {"ok": True, "text": (wd / "out.ll").read_text(errors="replace")}

    return proc.cached(["opt", t.path, read(t.path), args], compute)


def sort_lines(text: str) -> str:
    return "".join(sorted(text.splitlines(keepends=True)))


def analysis_canon(text: str, unordered: bool) -> str:
    """The only canonicalization of printer output: line order, and only for @analysis-unordered."""
    if not unordered:
        return text
    return sort_lines(text if text.endswith("\n") or not text else text + "\n")


def oracle_analysis(t: TestFile, args: str, unordered: bool) -> dict:
    """LLVM's analysis-printer output, canonicalized. Runs twice to catch printers that iterate in pointer order."""

    def compute():
        runs = [tool_analysis(config.llvm("opt"), args, Path(t.path), config.REPO) for _ in range(2)]
        r = runs[0]
        if not r.ok:
            return {"ok": False, "text": r.err_tail()}
        outs = [(analysis_canon(x.out.decode(errors="replace"), unordered), analysis_canon(x.err.decode(errors="replace"), unordered))
                for x in runs]
        if outs[0] != outs[1]:
            return {"ok": False, "text": "output is nondeterministic (differs between two runs of LLVM's opt"
                    + (")" if unordered else "; if only the line order changes, use @analysis-unordered)")
                    + ":\n" + diff(outs[0][1], outs[1][1], 20)}
        return {"ok": True, "stdout": outs[0][0], "stderr": outs[0][1]}

    return proc.cached(["analysis", t.path, read(t.path), args, unordered], compute)


def oracle_isel(input_text: str, llc_args: str) -> dict:
    def compute():
        with proc.Workdir() as wd:
            (wd / "input.ll").write_text(input_text)
            r = tool_isel(config.llvm("llc"), llc_args, wd / "input.ll", wd / "out.mir")
            if not r.ok:
                return {"ok": False, "text": r.err_tail()}
            return {"ok": True, "text": extract_ir((wd / "out.mir").read_text(errors="replace"))}

    return proc.cached(["isel", input_text, llc_args], compute)


def oracle_run(t: TestFile) -> dict:
    def compute():
        with proc.Workdir() as wd:
            return build_and_run(config.llvm("opt"), config.llvm("llc"), t, wd)

    driver = read(t.driver) if t.driver else ""
    return proc.cached(["run", t.path, read(t.path), t.opt[:1], t.llc, driver], compute)


# ---------------------------------------------------------------- the checks

def check_roundtrip(impl: str, t: TestFile) -> Outcome:
    tid = f"{t.path}::roundtrip"
    exp = oracle_opt(t, "")
    if not exp["ok"]:
        return Outcome(tid, INVALID, "llvm opt rejects this file:\n" + exp["text"])
    if impl == config.REFERENCE_IMPL:
        return Outcome(tid, PASS)
    with proc.Workdir() as wd:
        r = tool_opt(config.impl_bin(impl, "opt"), "", Path(t.path), wd / "out.ll", config.REPO)
        if not r.ok:
            return Outcome(tid, FAIL, f"opt exited with {r.rc}:\n{r.err_tail()}", {"stderr.txt": r.err_tail(20000)})
        act = (wd / "out.ll").read_text(errors="replace")
    if act == exp["text"]:
        return Outcome(tid, PASS)
    return Outcome(tid, FAIL, "printed IR differs:\n" + diff(exp["text"], act),
                   {"expected.ll": exp["text"], "actual.ll": act, "diff.txt": full_diff(exp["text"], act)})


def check_opt(impl: str, t: TestFile) -> Outcome:
    tid = f"{t.path}::opt"
    for args in t.opt:
        exp = oracle_opt(t, args)
        if not exp["ok"]:
            return Outcome(tid, INVALID, f"llvm opt {args} fails:\n" + exp["text"])
        ok, exp_c = canon(exp["text"])
        if not ok:
            return Outcome(tid, INVALID, f"llvm opt {args} output does not re-assemble:\n" + exp_c)
        if impl == config.REFERENCE_IMPL:
            continue
        with proc.Workdir() as wd:
            r = tool_opt(config.impl_bin(impl, "opt"), args, Path(t.path), wd / "out.ll", config.REPO)
            if not r.ok:
                return Outcome(tid, FAIL, f"[{args}] opt exited with {r.rc}:\n{r.err_tail()}", {"stderr.txt": r.err_tail(20000)})
            act = (wd / "out.ll").read_text(errors="replace")
        ok, act_c = canon(act)
        if not ok:
            return Outcome(tid, FAIL, f"[{args}] output is not valid IR according to llvm-as:\n{act_c}", {"actual.ll": act})
        if act_c != exp_c:
            return Outcome(tid, FAIL, f"[{args}] canonicalized IR differs:\n" + diff(exp_c, act_c),
                           {"args.txt": args, "expected.ll": exp_c, "actual.ll": act_c, "diff.txt": full_diff(exp_c, act_c)})
    return Outcome(tid, PASS)


def check_analysis(impl: str, t: TestFile) -> Outcome:
    tid = f"{t.path}::analysis"
    for args, unordered in t.analysis:
        exp = oracle_analysis(t, args, unordered)
        if not exp["ok"]:
            return Outcome(tid, INVALID, f"llvm opt {args} -disable-output fails:\n" + exp["text"])
        if impl == config.REFERENCE_IMPL:
            continue
        r = tool_analysis(config.impl_bin(impl, "opt"), args, Path(t.path), config.REPO)
        act_out = analysis_canon(r.out.decode(errors="replace"), unordered)
        act_err = analysis_canon(r.err.decode(errors="replace"), unordered)
        if not r.ok:
            return Outcome(tid, FAIL, f"[{args}] opt exited with {r.rc}:\n{r.err_tail()}", {"args.txt": args, "stderr.txt": r.err_tail(20000)})
        problems, arts = [], {"args.txt": args + (" (unordered: lines sorted)" if unordered else "")}
        for stream, e, a in (("stderr", exp["stderr"], act_err), ("stdout", exp["stdout"], act_out)):
            if e != a:
                problems.append(f"[{args}] {stream} differs:\n" + diff(e, a))
                arts.update({f"expected.{stream}": e, f"actual.{stream}": a, f"diff.{stream}.txt": full_diff(e, a)})
        if problems:
            return Outcome(tid, FAIL, "\n".join(problems), arts)
    return Outcome(tid, PASS)


def check_isel_ir(impl: str, t: TestFile) -> Outcome:
    tid = f"{t.path}::isel-ir"
    if t.opt:
        o = oracle_opt(t, t.opt[0])
        if not o["ok"]:
            return Outcome(tid, INVALID, "llvm opt fails:\n" + o["text"])
        input_text = o["text"]
    else:
        input_text = read(t.path)
    exp = oracle_isel(input_text, t.llc)
    if not exp["ok"]:
        return Outcome(tid, INVALID, "llvm llc fails:\n" + exp["text"])
    ok, exp_c = canon(exp["text"])
    if not ok:
        return Outcome(tid, INVALID, "llc's pre-isel IR does not re-assemble:\n" + exp_c)
    if impl == config.REFERENCE_IMPL:
        return Outcome(tid, PASS)
    with proc.Workdir() as wd:
        (wd / "input.ll").write_text(input_text)
        r = tool_isel(config.impl_bin(impl, "llc"), t.llc, wd / "input.ll", wd / "out.ll")
        if not r.ok:
            return Outcome(tid, FAIL, f"llc exited with {r.rc}:\n{r.err_tail()}", {"input.ll": input_text, "stderr.txt": r.err_tail(20000)})
        act = extract_ir((wd / "out.ll").read_text(errors="replace"))
    ok, act_c = canon(act)
    if not ok:
        return Outcome(tid, FAIL, f"output is not valid IR according to llvm-as:\n{act_c}", {"input.ll": input_text, "actual.ll": act})
    if act_c != exp_c:
        return Outcome(tid, FAIL, "pre-isel IR differs:\n" + diff(exp_c, act_c),
                       {"input.ll": input_text, "expected.ll": exp_c, "actual.ll": act_c, "diff.txt": full_diff(exp_c, act_c)})
    return Outcome(tid, PASS)


def check_run(impl: str, t: TestFile) -> Outcome:
    tid = f"{t.path}::run"
    exp = oracle_run(t)
    if not exp["ok"]:
        return Outcome(tid, INVALID, f"LLVM-built program failed at {exp['stage']}:\n{exp['msg']}")
    if impl == config.REFERENCE_IMPL:
        return Outcome(tid, PASS)
    with proc.Workdir() as wd:
        act = build_and_run(config.impl_bin(impl, "opt"), config.impl_bin(impl, "llc"), t, wd)
        asm = (wd / "out.s").read_text(errors="replace") if (wd / "out.s").exists() else ""
    if not act["ok"]:
        return Outcome(tid, FAIL, f"{act['stage']} failed:\n{act['msg']}", {"out.s": asm, "error.txt": act["msg"]})
    problems = []
    if act["rc"] != exp["rc"]:
        problems.append(f"exit code {act['rc']}, expected {exp['rc']}")
    if act["stdout"] != exp["stdout"]:
        problems.append("stdout differs:\n" + diff(exp["stdout"], act["stdout"]))
    if not problems:
        return Outcome(tid, PASS)
    return Outcome(tid, FAIL, "\n".join(problems),
                   {"out.s": asm, "expected.stdout": exp["stdout"], "actual.stdout": act["stdout"],
                    "exit-codes.txt": f"expected {exp['rc']}\nactual {act['rc']}\n"})


CHECK_FNS = {"roundtrip": check_roundtrip, "opt": check_opt, "analysis": check_analysis, "isel-ir": check_isel_ir, "run": check_run}
