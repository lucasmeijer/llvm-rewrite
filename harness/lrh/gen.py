"""Test generation: C -> IR tests (with UB validation) and importers for LLVM's own tests and llvm-test-suite."""

import re
import shlex
import shutil
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from . import checks, config, corpus, proc

# IR configurations generated for every C source. Directory -> (clang flags, directives)
CONFIGS = {
    "O0": (["-O0", "-Xclang", "-disable-O0-optnone"], {"llc": "-O0"}),
    "O2": (["-O2"], {"llc": "-O2"}),
    # What clang itself feeds into the -O2 pipeline: unoptimized, but without -O0's noinline/optnone.
    "pipeline": (["-O2", "-Xclang", "-disable-llvm-passes"], {"opt": "-O2", "llc": "-O2"}),
}

# Old-style C (implicit int, K&R) still appears in llvm-test-suite; accept it instead of rejecting.
CFLAGS = ["-w", "-Wno-error=implicit-int", "-Wno-error=implicit-function-declaration", "-Wno-error=int-conversion",
          "-Wno-error=incompatible-pointer-types", "-Wno-error=return-type"]

NATIVE_VARIANTS = [
    ["-O0"],
    ["-O2"],
    ["-O1", "-fsanitize=address,undefined", "-fno-sanitize-recover=all", "-fno-omit-frame-pointer"],
]


def native_run(src: Path | list[Path], driver: Path | None, flags: list[str], wd: Path, tag: str):
    exe = wd / f"prog-{tag}"
    srcs = [str(x) for x in src] if isinstance(src, list) else [str(src)]
    cmd = [config.llvm("clang"), *CFLAGS, *flags, *srcs] + ([str(driver)] if driver else []) + ["-lm", "-o", str(exe)]
    r = proc.run(cmd)
    if not r.ok:
        return None, f"compile {' '.join(flags)} failed:\n{r.err_tail(1500)}"
    r = proc.run([str(exe)], cwd=wd, timeout=config.RUN_TIMEOUT)
    if r.timed_out:
        return None, f"{' '.join(flags)}: timed out (limit {config.RUN_TIMEOUT}s)"
    return (r.rc, r.out), (r.err_tail(1500) if r.rc else "")


def validate_c(src: Path | list[Path], driver: Path | None, extra: list[str] = []) -> str | None:
    """Returns None if the program is deterministic and UB-free as far as we can tell, else a reason."""
    with proc.Workdir() as wd:
        results = []
        for i, flags in enumerate(NATIVE_VARIANTS):
            res, err = native_run(src, driver, flags + extra, wd, str(i))
            if res is None:
                return err
            results.append((flags, res, err))
        again, err = native_run(src, driver, NATIVE_VARIANTS[0], wd, "again")
        if again is None:
            return err
    base = results[0][1]
    if again != base:
        return "nondeterministic: two -O0 runs differ"
    for flags, res, err in results[1:]:
        if res != base:
            return f"behaviour differs between -O0 and {' '.join(flags)} (likely UB):\n{err}"
    return None


def emit_ll(src_rel: str, flags: list[str], directives: dict, driver_rel: str | None, out: Path) -> str | None:
    r = proc.run([config.llvm("clang"), *CFLAGS, *flags, "-S", "-emit-llvm", src_rel, "-o", "-"], cwd=config.REPO)
    if not r.ok:
        return r.err_tail()
    head = [f"; @source: {src_rel}"]
    if "opt" in directives:
        head.append(f"; @opt: {directives['opt']}")
    head.append(f"; @llc: {directives['llc']}")
    if driver_rel:
        head.append(f"; @driver: {driver_rel}")
    head.append(f"; @generated: clang {' '.join(flags)} -S -emit-llvm (LLVM {config.LLVM_VERSION}) by harness/run from-c")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(head) + "\n" + r.out.decode())
    return None


# Multi-module (LTO) tests: each translation unit as clang -flto hands it to its pre-link pipeline (the pre-link
# pipeline itself, lto-pre-link<O2>, is the module's own @opt line), and a test.lto manifest whose post-link pipeline
# is what a linker's full LTO does for an executable: everything but main internalized, then lto<O2>.
LTO_TU_FLAGS = ["-O2", "-flto", "-Xclang", "-disable-llvm-passes"]
LTO_PRELINK = "-passes='lto-pre-link<O2>'"
LTO_POSTLINK = "-passes='internalize,lto<O2>' -internalize-public-api-list=main"


def from_c_lto(d: Path, force: bool) -> tuple[str, str | None]:
    rel = d.relative_to(config.REPO)
    out = config.TESTS / "lto" / Path(*rel.parts[3:])
    srcs = sorted(d.glob("*.c"))
    if len(srcs) < 2:
        return str(rel), "an LTO test directory needs at least two .c translation units"
    if not force and (out / corpus.LTO_MANIFEST).exists():
        return str(rel), "exists"
    # optional `cflags` file: extra clang flags for every TU (e.g. -g), also used for validation
    extra = shlex.split((d / "cflags").read_text()) if (d / "cflags").exists() else []
    tu_flags = LTO_TU_FLAGS + extra
    why = validate_c(srcs, None, extra)
    if why:
        return str(rel), why
    if out.exists():
        shutil.rmtree(out)
    names = []
    for src in srcs:
        src_rel = str(src.relative_to(config.REPO))
        r = proc.run([config.llvm("clang"), *CFLAGS, *tu_flags, "-S", "-emit-llvm", src_rel, "-o", "-"], cwd=config.REPO)
        if not r.ok:
            return str(rel), f"emitting IR for {src_rel} failed:\n{r.err_tail()}"
        name = src.with_suffix(".ll").name
        names.append(name)
        out.mkdir(parents=True, exist_ok=True)
        (out / name).write_text(f"; @source: {src_rel}\n; @opt: {LTO_PRELINK}\n; @generated: clang {' '.join(tu_flags)} "
                                f"-S -emit-llvm (LLVM {config.LLVM_VERSION}) by harness/run from-c\n" + r.out.decode())
    (out / corpus.LTO_MANIFEST).write_text(
        f"; @modules: {' '.join(names)}\n; @opt: {LTO_POSTLINK}\n; @llc: -O2\n; @source: {rel}/\n"
        f"; @generated: harness/run from-c (LLVM {config.LLVM_VERSION})\n")
    tests = [corpus.parse(out / n) for n in names] + [corpus.parse(out)]
    for t in tests:
        for ch in t.checks():
            res = checks.CHECK_FNS[ch](config.REFERENCE_IMPL, t)
            if res.status != checks.PASS:
                shutil.rmtree(out)
                return str(rel), f"oracle rejects {res.test_id}:\n{res.message}"
    return str(rel), None


def from_c_one(src: Path, force: bool) -> tuple[str, str | None]:
    src = src.resolve()
    rel = src.relative_to(config.REPO)
    parts = rel.parts
    if src.is_dir():
        if len(parts) < 5 or parts[:3] != ("tests", "lto", "src"):
            return str(rel), "a directory source must be tests/lto/src/<area>/<name>/"
        return from_c_lto(src, force)
    if len(parts) < 4 or parts[0] != "tests" or parts[1] not in ("e2e", "function") or parts[2] != "src":
        return str(rel), "sources must live under tests/e2e/src/ or tests/function/src/"
    family = parts[1]
    sub = Path(*parts[3:]).with_suffix(".ll")
    driver = None
    if family == "function":
        driver = src.with_name(src.stem + ".driver.c")
        if not driver.exists():
            return str(rel), f"function tests need a driver: {driver.relative_to(config.REPO)}"
    outs = {cfg: config.TESTS / family / cfg / sub for cfg in CONFIGS}
    if not force and all(o.exists() for o in outs.values()):
        return str(rel), "exists"
    why = validate_c(src, driver)
    if why:
        return str(rel), why
    driver_rel = str(driver.relative_to(config.REPO)) if driver else None
    for cfg, (flags, directives) in CONFIGS.items():
        err = emit_ll(str(rel), flags, directives, driver_rel, outs[cfg])
        if err:
            return str(rel), f"emitting IR ({cfg}) failed:\n{err}"
    # Make sure the oracle accepts every generated check.
    for o in outs.values():
        t = corpus.parse(o)
        for ch in t.checks():
            res = checks.CHECK_FNS[ch](config.REFERENCE_IMPL, t)
            if res.status != checks.PASS:
                for p in outs.values():
                    p.unlink(missing_ok=True)
                return str(rel), f"oracle rejects {res.test_id}:\n{res.message}"
    return str(rel), None


def cmd_from_c(a):
    srcs = [Path(s) for s in a.sources if not s.endswith(".driver.c")]
    ok = bad = 0
    with ThreadPoolExecutor(max_workers=8) as ex:
        for rel, why in ex.map(lambda s: from_c_one(s, a.force), srcs):
            if why is None:
                ok += 1
                print(f"  ok       {rel}")
            elif why == "exists":
                print(f"  exists   {rel}")
            else:
                bad += 1
                print(f"  REJECTED {rel}\n" + "\n".join("           " + l for l in why.splitlines()[:12]))
    print(f"{ok} generated, {bad} rejected")
    if bad:
        sys.exit(1)


# ---------------------------------------------------------------- import LLVM's regression tests

OTHER_TARGET_DIRS = {"AArch64", "ARM", "AMDGPU", "RISCV", "SystemZ", "PowerPC", "NVPTX", "Hexagon", "WebAssembly",
                     "Mips", "LoongArch", "SPIRV", "BPF", "VE", "Lanai", "Sparc", "MSP430", "AVR", "XCore", "CSKY",
                     "Xtensa", "M68k", "DirectX", "ARC"}
OTHER_TARGET_INTRINSIC = re.compile(r"@llvm\.(aarch64|arm|amdgcn|r600|nvvm|ppc|riscv|s390|wasm|hexagon|mips|loongarch|spv|dx|bpf|ve)\.")
ALLOWED_REQUIRES = {"x86-registered-target", "x86_64-linux", "x86"}


def run_lines(text: str) -> list[str]:
    runs, cur = [], None
    for line in text.splitlines():
        s = line.strip()
        if "RUN:" not in s or not s.startswith(";"):
            if cur is not None:
                runs.append(cur)
                cur = None
            continue
        body = s.split("RUN:", 1)[1].strip()
        cur = (cur + " " if cur is not None else "") + body.rstrip("\\").strip()
        if not body.endswith("\\"):
            runs.append(cur)
            cur = None
    if cur is not None:
        runs.append(cur)
    return runs


# A pass in -passes=… that prints an analysis (to stderr): print<domtree>, print-alias-sets, aa-eval, …
PRINTER_PASS = re.compile(r"(^|[=,(\"'])(print[<-]|print$|print[,)]|aa-eval)")
# cl::opt flags that only control what an analysis printer prints (aa-eval's report); allowed in @analysis lines.
PRINTER_FLAG = re.compile(r"^--?print-(all-alias-modref-info|no-aliases|may-aliases|partial-aliases|must-aliases|"
                          r"no-modref|ref|mod|modref|must|mustref|mustmod|mustmodref)$")


# Legacy-PM pass flags (`opt -safe-stack`) still used by some RUN lines, mostly for llc's IR passes; when a RUN line
# has no -passes, they become `-passes=<new-PM name>,…` in their order.
LEGACY_PASS_FLAGS = {"safe-stack": "safe-stack", "global-merge": "global-merge", "expand-ir-insts": "expand-ir-insts",
                     "fix-irreducible": "fix-irreducible", "structurizecfg": "structurizecfg",
                     "interleaved-access": "interleaved-access", "unify-loop-exits": "unify-loop-exits",
                     "lowerswitch": "lower-switch", "indirectbr-expand": "indirectbr-expand"}
# A read-only input file of an opt flag, `-sample-profile-file=%S/Inputs/x.prof`: copied next to the test.
INPUT_FILE_ARG = re.compile(r"^(--?[\w.-]+=)%[pS]/(Inputs/[\w.+-]+)$")


def convert_run(run: str, inputs: dict | None = None, inputs_rel: str = "") -> tuple[str | None, str, str]:
    """Returns (kind, opt args, '') with kind "opt" or "analysis", or (None, '', reason).

    "analysis" (an @analysis line): the pipeline contains an analysis printer, or the RUN line has both
    -disable-output and 2>&1 (so FileCheck reads stderr). Everything else is an @opt line, which may not redirect
    (except `2>&1`, which is dropped: the check compares the IR, stderr is ignored).

    With `inputs` (a dict), `-flag=%S/Inputs/x` becomes `-flag=<inputs_rel>/Inputs/x` (a path relative to the repo,
    the tools' working directory) and `inputs` gets `Inputs/x` -> the same; the caller copies the files.
    """
    first = run.split("|", 1)[0].strip()
    try:
        toks = shlex.split(first)
    except ValueError as e:
        return None, "", f"cannot tokenize: {e}"
    if not toks or toks[0] != "opt":
        return None, "", "not an opt invocation"
    # `-p X` / `-p=X` is opt's short alias of -passes=X: write it in the long form
    norm, k = [toks[0]], 1
    while k < len(toks):
        if toks[k] in ("-p", "--p") and k + 1 < len(toks):
            norm.append("-passes=" + toks[k + 1])
            k += 2
            continue
        if toks[k].startswith(("-p=", "--p=")):
            norm.append("-passes=" + toks[k].split("=", 1)[1])
        else:
            norm.append(toks[k])
        k += 1
    toks = norm
    if not any(t.startswith(("-passes", "--passes", "-O")) for t in toks):
        legacy = [LEGACY_PASS_FLAGS[t.lstrip("-")] for t in toks if t.startswith("-") and t.lstrip("-") in LEGACY_PASS_FLAGS]
        if legacy:
            toks = [t for t in toks if not (t.startswith("-") and t.lstrip("-") in LEGACY_PASS_FLAGS)]
            toks.insert(1, "-passes=" + ",".join(legacy))
    passes = [t.split("=", 1)[1] for t in toks if t.startswith(("-passes=", "--passes="))]
    if any(re.search(r"(^|[,(])(dot|view)-", p) for p in passes) or any(t.startswith(("-dot-", "--dot-")) for t in toks):
        return None, "", "writes .dot files"
    disable_output = any(t in ("-disable-output", "--disable-output") for t in toks)
    analysis = any(PRINTER_PASS.search(p) for p in passes) or (disable_output and "2>&1" in toks)
    out, i = [], 1
    while i < len(toks):
        t = toks[i]
        nxt = toks[i + 1] if i + 1 < len(toks) else None
        if t in ("<", "-o") and nxt in ("%s", "-"):
            i += 2
            continue
        if analysis and t == "-o" and nxt == "/dev/null":
            i += 2
            continue
        if t in ("%s", "<%s", "-S", "-disable-output", "--disable-output") or t == "2>&1":
            i += 1
            continue
        m = INPUT_FILE_ARG.match(t)
        if m and inputs is not None:
            inputs[m.group(2)] = f"{inputs_rel}/{m.group(2)}"
            out.append(m.group(1) + f"{inputs_rel}/{m.group(2)}")
            i += 1
            continue
        if t == "-o":
            return None, "", "writes to a file"
        if "%" in t:
            return None, "", f"uses lit substitution {t}"
        if t.startswith((">", "2>")) or t in ("&&", ";"):
            return None, "", "redirects or chains commands"
        if t.startswith(("-mtriple", "--mtriple")):
            triple = t.split("=", 1)[1] if "=" in t else (nxt or "")
            if not triple.startswith("x86_64"):
                return None, "", f"non-x86_64 target {triple}"
        if analysis and PRINTER_FLAG.match(t):
            out.append(t)
            i += 1
            continue
        if t.startswith(("-debug", "--debug", "-stats", "-print", "--print", "-time-passes", "-pass-remarks", "-view-")):
            return None, "", f"diagnostic output flag {t}"
        out.append(t)
        i += 1
    if not any(t.startswith(("-passes", "--passes", "-O")) for t in out):
        return None, "", "no -passes / -O pipeline"
    return ("analysis" if analysis else "opt"), shlex.join(out), ""


def file_skip_reason(text: str) -> str | None:
    for line in text.splitlines():
        s = line.strip().lstrip(";").strip()
        if s.startswith("REQUIRES:"):
            items = {x.strip() for x in s[len("REQUIRES:"):].replace("&&", ",").split(",") if x.strip()}
            bad = items - ALLOWED_REQUIRES
            if bad:
                return f"REQUIRES {', '.join(sorted(bad))}"
        if s.startswith("XFAIL:"):
            return "XFAIL in LLVM"
        if "split-file" in s:
            return "uses split-file"
    m = OTHER_TARGET_INTRINSIC.search(text)
    if m:
        return f"uses non-x86 target intrinsic {m.group(0)}"
    m = re.search(r'^target triple = "([^"]*)"', text, re.M)
    if m and not m.group(1).startswith("x86_64"):
        return f"target triple {m.group(1)}"
    return None


DETERMINISM_RUNS = 6


def printer_order(t: corpus.TestFile, args: str) -> str | None:
    """'ordered', 'unordered' (only the line order varies between runs: a printer iterating in pointer order), or
    None (the content varies, e.g. printed addresses). The check itself only compares two runs, which can agree by
    chance, so the importer looks harder."""
    outs = set()
    for _ in range(DETERMINISM_RUNS):
        r = checks.tool_analysis(config.llvm("opt"), args, Path(t.path), config.REPO)
        outs.add((r.rc, r.out, r.err))
    if len(outs) == 1:
        return "ordered"
    texts = {(rc, checks.sort_lines(o.decode(errors="replace")), checks.sort_lines(e.decode(errors="replace"))) for rc, o, e in outs}
    return "unordered" if len(texts) == 1 else None


def writes_files(t: corpus.TestFile, args: str) -> bool:
    """Does LLVM's opt create files in its working directory (GCOVProfiling's a.gcno)? The checks run the tools in
    the repository, in parallel, so such a line would litter the tree."""
    with proc.Workdir() as wd:
        run = wd / "cwd"
        run.mkdir()
        checks.tool_opt(config.llvm("opt"), args, Path(t.path).resolve(), wd / "out.ll", run)
        return any(run.iterdir())


def import_one(src: Path, dst: Path) -> list[str]:
    """Writes dst if anything is importable. Returns skip notes."""
    name = src.name
    other = OTHER_TARGET_DIRS.intersection(src.parts)
    if other:
        return [f"- `{name}`: in a {other.pop()} target directory"]
    text = src.read_text(errors="replace")
    reason = file_skip_reason(text)
    if reason:
        return [f"- `{name}`: {reason}"]
    notes, lines = [], {"opt": [], "analysis": []}
    inputs: dict[str, str] = {}
    for run in run_lines(text):
        kind, args, why = convert_run(run, inputs, str(dst.parent.relative_to(config.REPO)))
        if kind is None:
            notes.append(f"- `{name}` RUN `{run}`: {why}")
        elif args not in lines[kind]:
            lines[kind].append(args)
    if not lines["opt"] and not lines["analysis"]:
        return notes or [f"- `{name}`: no RUN lines"]
    origin = src.relative_to(config.LLVM_SRC)
    dst.parent.mkdir(parents=True, exist_ok=True)
    for rel in inputs:
        if not (src.parent / rel).is_file():
            return notes + [f"- `{name}`: input file {rel} does not exist"]
        if rel.endswith(".ll"):
            return notes + [f"- `{name}`: input file {rel} is IR (would become a test itself)"]
        (dst.parent / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src.parent / rel, dst.parent / rel)

    def write(ls):
        head = ([f"; @origin: {origin} (llvmorg-{config.LLVM_VERSION})"] + [f"; @opt: {x}" for x in ls["opt"]]
                + [f"; @analysis: {x}" for x in ls["analysis"]] + [f"; @analysis-unordered: {x}" for x in ls["analysis-unordered"]])
        dst.write_text("\n".join(head) + "\n" + text)

    lines["analysis-unordered"] = []
    write(lines)
    t = corpus.parse(dst)
    rt = checks.check_roundtrip(config.REFERENCE_IMPL, t)
    if rt.status != checks.PASS:
        dst.unlink()
        return notes + [f"- `{name}`: llvm opt rejects the file"]
    good = {"opt": [], "analysis": [], "analysis-unordered": []}
    for x in lines["opt"]:
        t.opt, t.analysis = [x], []
        if writes_files(t, x):
            notes.append(f"- `{name}` @opt `{x}`: writes files into the working directory")
        elif checks.check_opt(config.REFERENCE_IMPL, t).status == checks.PASS:
            good["opt"].append(x)
        else:
            notes.append(f"- `{name}` @opt `{x}`: oracle fails")
    for x in lines["analysis"]:
        order = printer_order(t, x)
        if order is None:
            notes.append(f"- `{name}` @analysis `{x}`: nondeterministic output")
            continue
        t.opt, t.analysis = [], [(x, order == "unordered")]
        if checks.check_analysis(config.REFERENCE_IMPL, t).status == checks.PASS:
            good["analysis" if order == "ordered" else "analysis-unordered"].append(x)
        else:
            notes.append(f"- `{name}` @analysis `{x}`: oracle fails")
    if not any(good.values()):
        dst.unlink()
        return notes + [f"- `{name}`: no working RUN lines"]
    if good != lines:
        write(good)
    return notes


# ---------------------------------------------------------------- import LLVM's linker tests (multi-module)

LINK_FLAGS = {"-internalize", "-only-needed"}  # llvm-link flags the importer keeps (no arguments)
LINK_INPUT = re.compile(r"^%[pS]/((?:Inputs/)?[\w.+-]+\.ll)$")
ECHO_AS = re.compile(r"^echo\s+(\"[^\"]*\"|'[^']*'|)\s*\|\s*(?:not\s+)?llvm-as\s*(?:-o\s+|>\s*)(%t[\w.-]*)\s*$")


def link_assignments(runs: list[str]) -> dict[str, str]:
    """%t files made from sources by other RUN lines: `llvm-as <src> -o %t.x` / `llvm-as < <src> > %t.x` -> source
    (`%s`, `Inputs/x.ll`), `echo "..." | llvm-as > %t.x` -> `echo:<text>`, `llvm-as < /dev/null > %t.x` -> `echo:`."""
    out = {}
    for run in runs:
        r = run.strip()
        m = ECHO_AS.match(r)
        if m:
            body = m.group(1)[1:-1] if m.group(1) else ""
            out[m.group(2)] = "echo:" + body.replace("%%", "%")
            continue
        try:
            toks = shlex.split(r)
        except ValueError:
            continue
        if not toks or toks[0] != "llvm-as" or len(toks) > 6:
            continue
        src = dst = None
        i = 1
        while i < len(toks):
            t = toks[i]
            if t in ("-o", ">") and i + 1 < len(toks):
                dst = toks[i + 1]; i += 2; continue
            if t == "<" and i + 1 < len(toks):
                src = toks[i + 1]; i += 2; continue
            if t.startswith(">"):
                dst = t[1:]
            elif not t.startswith("-"):
                src = t
            i += 1
        if dst and dst.startswith("%t") and src:
            if src == "%s":
                out[dst] = "%s"
            elif src == "/dev/null":
                out[dst] = "echo:"
            elif LINK_INPUT.match(src):
                out[dst] = LINK_INPUT.match(src).group(1)
    return out


def convert_link_run(run: str, assigned: dict[str, str]) -> tuple[list[str] | None, list[str], str]:
    """A RUN line `llvm-link [flags] <inputs>... [-S] [-o x] | FileCheck` -> (module sources, flags, ''). Inputs are
    %s, %p/[Inputs/]x.ll, or %t files made by an earlier llvm-as line (see link_assignments)."""
    first = run.split("|", 1)[0].strip()
    try:
        toks = shlex.split(first)
    except ValueError as e:
        return None, [], f"cannot tokenize: {e}"
    if not toks or toks[0] != "llvm-link":
        return None, [], "not an llvm-link invocation"
    mods, flags = [], []
    i = 1
    while i < len(toks):
        t = toks[i]
        if t in ("-S", "2>&1", "-disable-lazy-loading"):
            pass
        elif t == "-o" and i + 1 < len(toks):
            i += 1
        elif t == "%s":
            mods.append("%s")
        elif LINK_INPUT.match(t):
            mods.append(LINK_INPUT.match(t).group(1))
        elif t in assigned:
            mods.append(assigned[t])
        elif t in LINK_FLAGS:
            flags.append(t)
        else:
            return None, [], f"unsupported llvm-link argument `{t}`"
        i += 1
    if not mods:
        return None, [], "no input files"
    return mods, flags, ""


def import_link_one(src: Path, dst_dir: Path) -> tuple[list[str], int]:
    """One LLVM Linker test -> one multi-module test directory per usable llvm-link RUN line."""
    name = src.name
    text = src.read_text(errors="replace")
    reason = file_skip_reason(text)
    if reason:
        return [f"- `{name}`: {reason}"], 0
    notes, runs = [], []
    all_runs = run_lines(text)
    assigned = link_assignments(all_runs)
    for run in all_runs:
        mods, flags, why = convert_link_run(run, assigned)
        if mods is None:
            if "llvm-link" in run:
                notes.append(f"- `{name}` RUN `{run}`: {why}")
            continue
        if (mods, flags) not in runs:
            runs.append((mods, flags))
    if not runs:
        return notes or [f"- `{name}`: no llvm-link RUN lines"], 0
    origin = src.relative_to(config.LLVM_SRC)
    made = 0
    for k, (mods, flags) in enumerate(runs):
        d = dst_dir / (src.stem if k == 0 else f"{src.stem}.run{k + 1}")
        if d.exists():
            shutil.rmtree(d)
        names = []
        n_echo = 0
        for m in mods:
            if m.startswith("echo:"):
                n_echo += 1
                n = f"echo{n_echo}.ll"
                (d / n).parent.mkdir(parents=True, exist_ok=True)
                (d / n).write_text(f"; @origin: `echo ... | llvm-as` in a RUN line of {origin}\n" + m[5:] + "\n")
                names.append(n)
                continue
            n = name if m == "%s" else m
            f = src if m == "%s" else src.parent / m
            if not f.is_file():
                notes.append(f"- `{name}`: input {m} missing")
                break
            if n in names:  # the same file twice (llvm-link x.ll x.ll)
                n = f"{Path(n).stem}.copy{names.count(n) + 1}.ll"
            (d / n).parent.mkdir(parents=True, exist_ok=True)
            body = f.read_text(errors="replace")
            (d / n).write_text(f"; @origin: {f.relative_to(config.LLVM_SRC)} (llvmorg-{config.LLVM_VERSION})\n" + body)
            names.append(n)
        else:
            (d / corpus.LTO_MANIFEST).write_text(
                f"; @origin: {origin} (llvmorg-{config.LLVM_VERSION})\n; @modules: {' '.join(names)}\n"
                + (f"; @link: {' '.join(flags)}\n" if flags else ""))
            res = checks.check_link(config.REFERENCE_IMPL, corpus.parse(d))
            if res.status == checks.PASS:
                made += 1
                continue
            notes.append(f"- `{name}` RUN {k + 1}: oracle fails: {res.message.splitlines()[1] if len(res.message.splitlines()) > 1 else res.message}")
        shutil.rmtree(d, ignore_errors=True)
    return notes, made


def cmd_import_llvm_linker(d: str):
    src_dir = config.LLVM_SRC / "llvm" / "test" / d
    dst_dir = config.TESTS / "imported" / "llvm" / d
    files = sorted(f for f in src_dir.glob("*.ll"))
    if dst_dir.exists():
        shutil.rmtree(dst_dir)
    dst_dir.mkdir(parents=True)
    with ThreadPoolExecutor(max_workers=16) as ex:
        res = list(ex.map(lambda f: import_link_one(f, dst_dir), files))
    flat = [n for ns, _ in res for n in ns]
    made = sum(m for _, m in res)
    (dst_dir / "SKIPPED.md").write_text(
        f"# Skipped while importing llvm/test/{d} (llvmorg-{config.LLVM_VERSION})\n\n"
        f"{made} multi-module tests (one per usable llvm-link RUN line) from {len(files)} files. "
        f"Regenerate with `./harness/run import-llvm {d}`.\n\n" + "\n".join(flat) + "\n")
    print(f"{d}: {made} link tests from {len(files)} files, {len(flat)} skip notes -> {(dst_dir / 'SKIPPED.md').relative_to(config.REPO)}")


def prune_inputs(dst_dir: Path):
    """Removes copied input files (see INPUT_FILE_ARG) that no imported test references any more."""
    if not dst_dir.exists():
        return
    copies = [p for p in dst_dir.rglob("*") if p.is_file() and p.parent.name == "Inputs" and p.suffix != ".ll"]
    if not copies:
        return
    text = "\n".join(p.read_text(errors="replace") for p in dst_dir.rglob("*.ll") if "Inputs" not in p.parts)
    for p in copies:
        if str(p.relative_to(config.REPO)) not in text:
            p.unlink()


def cmd_import_llvm(a):
    for d in a.dirs:
        if d.rstrip("/") == "Linker":
            cmd_import_llvm_linker("Linker")
            continue
        src_dir = config.LLVM_SRC / "llvm" / "test" / d
        if not src_dir.is_dir():
            raise SystemExit(f"{src_dir} does not exist")
        dst_dir = config.TESTS / "imported" / "llvm" / d
        files = sorted(src_dir.rglob("*.ll"))
        with ThreadPoolExecutor(max_workers=16) as ex:
            notes = list(ex.map(lambda f: import_one(f, dst_dir / f.relative_to(src_dir)), files))
        flat = [n for ns in notes for n in ns]
        prune_inputs(dst_dir)
        imported = len(list(dst_dir.rglob("*.ll"))) if dst_dir.exists() else 0
        dst_dir.mkdir(parents=True, exist_ok=True)
        (dst_dir / "SKIPPED.md").write_text(
            f"# Skipped while importing llvm/test/{d} (llvmorg-{config.LLVM_VERSION})\n\n"
            f"{imported} of {len(files)} files imported. Regenerate with `./harness/run import-llvm {d}`.\n\n"
            + "\n".join(flat) + "\n")
        print(f"{d}: imported {imported}/{len(files)} files, {len(flat)} skip notes -> {(dst_dir / 'SKIPPED.md').relative_to(config.REPO)}")


# ---------------------------------------------------------------- import llvm-test-suite programs

def cmd_import_test_suite(a):
    srcs = []
    for d in a.dirs:
        src_dir = config.TEST_SUITE_SRC / d
        for h in src_dir.glob("*.h"):
            dst = config.TESTS / "e2e" / "src" / "test-suite" / d / h.name
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(h, dst)
        for f in sorted(src_dir.glob("*.c")):
            dst = config.TESTS / "e2e" / "src" / "test-suite" / d / f.name
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(f, dst)
            srcs.append(dst)
    ok = bad = 0
    with ThreadPoolExecutor(max_workers=8) as ex:
        for src, (rel, why) in zip(srcs, ex.map(lambda s: from_c_one(s, False), srcs)):
            if why is None or why == "exists":
                ok += 1
            else:
                bad += 1
                src.unlink()
                print(f"  rejected {rel}: {why.splitlines()[0][:150]}")
    print(f"{ok} programs imported, {bad} rejected")
