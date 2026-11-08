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


def native_run(src: Path, driver: Path | None, flags: list[str], wd: Path, tag: str):
    exe = wd / f"prog-{tag}"
    cmd = [config.llvm("clang"), *CFLAGS, *flags, str(src)] + ([str(driver)] if driver else []) + ["-lm", "-o", str(exe)]
    r = proc.run(cmd)
    if not r.ok:
        return None, f"compile {' '.join(flags)} failed:\n{r.err_tail(1500)}"
    r = proc.run([str(exe)], cwd=wd, timeout=config.RUN_TIMEOUT)
    if r.timed_out:
        return None, f"{' '.join(flags)}: timed out (limit {config.RUN_TIMEOUT}s)"
    return (r.rc, r.out), (r.err_tail(1500) if r.rc else "")


def validate_c(src: Path, driver: Path | None) -> str | None:
    """Returns None if the program is deterministic and UB-free as far as we can tell, else a reason."""
    with proc.Workdir() as wd:
        results = []
        for i, flags in enumerate(NATIVE_VARIANTS):
            res, err = native_run(src, driver, flags, wd, str(i))
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


def from_c_one(src: Path, force: bool) -> tuple[str, str | None]:
    src = src.resolve()
    rel = src.relative_to(config.REPO)
    parts = rel.parts
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


def convert_run(run: str) -> tuple[str | None, str]:
    """Returns (opt args, '') or (None, reason)."""
    first = run.split("|", 1)[0].strip()
    try:
        toks = shlex.split(first)
    except ValueError as e:
        return None, f"cannot tokenize: {e}"
    if not toks or toks[0] != "opt":
        return None, "not an opt invocation"
    out, i = [], 1
    while i < len(toks):
        t = toks[i]
        nxt = toks[i + 1] if i + 1 < len(toks) else None
        if t in ("<", "-o") and nxt in ("%s", "-"):
            i += 2
            continue
        if t in ("%s", "<%s", "-S", "-disable-output", "--disable-output"):
            i += 1
            continue
        if t == "-o":
            return None, "writes to a file"
        if "%" in t:
            return None, f"uses lit substitution {t}"
        if t.startswith((">", "2>")) or t in ("&&", ";"):
            return None, "redirects or chains commands"
        if t.startswith(("-mtriple", "--mtriple")):
            triple = t.split("=", 1)[1] if "=" in t else (nxt or "")
            if not triple.startswith("x86_64"):
                return None, f"non-x86_64 target {triple}"
        if t.startswith(("-debug", "--debug", "-stats", "-print", "--print", "-time-passes", "-pass-remarks", "-view-")):
            return None, f"diagnostic output flag {t}"
        if t.startswith(("-passes=", "--passes=")) and "print" in t:
            return None, "analysis printer (stderr output) not supported yet"
        out.append(t)
        i += 1
    if not any(t.startswith(("-passes", "--passes", "-O")) for t in out):
        return None, "no -passes / -O pipeline"
    return shlex.join(out), ""


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
    notes, args_list = [], []
    for run in run_lines(text):
        args, why = convert_run(run)
        if args is None:
            notes.append(f"- `{name}` RUN `{run}`: {why}")
        elif args not in args_list:
            args_list.append(args)
    if not args_list:
        return notes or [f"- `{name}`: no RUN lines"]
    origin = src.relative_to(config.LLVM_SRC)
    dst.parent.mkdir(parents=True, exist_ok=True)

    def write(al):
        head = [f"; @origin: {origin} (llvmorg-{config.LLVM_VERSION})"] + [f"; @opt: {x}" for x in al]
        dst.write_text("\n".join(head) + "\n" + text)

    write(args_list)
    t = corpus.parse(dst)
    rt = checks.check_roundtrip(config.REFERENCE_IMPL, t)
    if rt.status != checks.PASS:
        dst.unlink()
        return notes + [f"- `{name}`: llvm opt rejects the file"]
    good = []
    for x in args_list:
        t.opt = [x]
        if checks.check_opt(config.REFERENCE_IMPL, t).status == checks.PASS:
            good.append(x)
        else:
            notes.append(f"- `{name}` @opt `{x}`: oracle fails")
    if not good:
        dst.unlink()
        return notes + [f"- `{name}`: no working RUN lines"]
    if good != args_list:
        write(good)
    return notes


def cmd_import_llvm(a):
    for d in a.dirs:
        src_dir = config.LLVM_SRC / "llvm" / "test" / d
        if not src_dir.is_dir():
            raise SystemExit(f"{src_dir} does not exist")
        dst_dir = config.TESTS / "imported" / "llvm" / d
        files = sorted(src_dir.rglob("*.ll"))
        with ThreadPoolExecutor(max_workers=16) as ex:
            notes = list(ex.map(lambda f: import_one(f, dst_dir / f.relative_to(src_dir)), files))
        flat = [n for ns in notes for n in ns]
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
