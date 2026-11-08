"""Generates the compile-time performance corpus, tests/perf/ (see docs/testing.md, "Performance").

  tests/perf/compile/<program>.ll     whole llvm-test-suite programs: each C file compiled the way clang feeds the
                                      -O2 pipeline (clang -O2 -Xclang -disable-llvm-passes), then llvm-linked into
                                      one module.
  tests/perf/scaling/<shape>/n<N>.ll  synthetic IR of one shape at several sizes, to measure how cost grows with N.

Every file has `@perf:` lines (what to time) and an `@opt:` line for each pass pipeline it times, so the same files
are also correctness tests (`::roundtrip`, `::opt`). Regenerate with `./harness/run gen-perf`; never edit by hand.
"""

import shlex
import shutil
import sys
from concurrent.futures import ThreadPoolExecutor

from . import checks, config, corpus, proc

PERF = config.TESTS / "perf"
PIPELINE_FLAGS = ["-O2", "-Xclang", "-disable-llvm-passes"]

# name -> (llvm-test-suite dir, source files (None = every *.c in the dir), extra clang flags from its CMakeLists.txt)
PROGRAMS = {
    "sqlite3": ("MultiSource/Applications/sqlite3", ["sqlite3.c", "shell.c"],
                "-DSTDC_HEADERS=1 -DHAVE_SYS_TYPES_H=1 -DHAVE_SYS_STAT_H=1 -DHAVE_STDLIB_H=1 -DHAVE_STRING_H=1 "
                "-DHAVE_MEMORY_H=1 -DHAVE_STRINGS_H=1 -DHAVE_INTTYPES_H=1 -DHAVE_STDINT_H=1 -DHAVE_UNISTD_H=1 "
                "-DSQLITE_OMIT_LOAD_EXTENSION=1 -DSQLITE_THREADSAFE=0"),
    "lua": ("MultiSource/Applications/lua", "exclude:luac.c,print.c", "-DLUA_USE_POSIX"),
    "SPASS": ("MultiSource/Applications/SPASS", None, "-DCLOCK_NO_TIMING -fno-strict-aliasing"),
    "oggenc": ("MultiSource/Applications/oggenc", ["oggenc.c"], "-fno-strict-aliasing -ffp-contract=off -DFMA_DISABLED=1"),
}
PROGRAM_PERF = ["opt", "opt -O2", "llc -O2"]  # `opt` alone = parse + print
PROGRAM_OPT = ["-O2"]

SIZES = [500, 2000, 8000]
# Shapes that are too cheap at SIZES to rise above process startup get scaled up.
SIZE_FACTOR = {"straightline": 8, "switch": 4}


# ---------------------------------------------------------------- whole programs

def gen_program(name: str) -> str | None:
    d, srcs, flags = PROGRAMS[name]
    src_dir = config.TEST_SUITE_SRC / d
    if srcs is None or isinstance(srcs, str):
        excl = set(srcs.split(":", 1)[1].split(",")) if srcs else set()
        srcs = sorted(p.name for p in src_dir.glob("*.c") if p.name not in excl)
    with proc.Workdir() as wd:
        parts = []
        for s in srcs:
            out = wd / (s.replace("/", "_") + ".ll")
            r = proc.run([config.llvm("clang"), "-w", *PIPELINE_FLAGS, *shlex.split(flags), f"-I{src_dir}",
                          "-S", "-emit-llvm", str(src_dir / s), "-o", str(out)], cwd=src_dir)
            if not r.ok:
                return f"{s}: {r.err_tail(1500)}"
            parts.append(str(out))
        r = proc.run([config.llvm("llvm-link"), "-S", *parts, "-o", str(wd / "linked.ll")])
        if not r.ok:
            return f"llvm-link: {r.err_tail()}"
        body = (wd / "linked.ll").read_text()
    head = [f"; @source: llvm-test-suite {d} ({', '.join(srcs) if len(srcs) <= 4 else f'{len(srcs)} C files'})"]
    head += [f"; @opt: {o}" for o in PROGRAM_OPT] + [f"; @perf: {p}" for p in PROGRAM_PERF]
    head.append(f"; @generated: clang {' '.join(PIPELINE_FLAGS)} {flags} per file, then llvm-link (LLVM {config.LLVM_VERSION}) "
                "by harness/run gen-perf")
    write(PERF / "compile" / f"{name}.ll", head, body)
    return None


# ---------------------------------------------------------------- synthetic scaling shapes
# Each returns IR text for size n. Keep them simple, valid, and free of anything opt folds away trivially before
# the pass under test gets to work (values come from function arguments).

def shape_straightline(n):
    """One block, n integer ops in a DAG (each uses the previous value and one from halfway back)."""
    ops = ["add", "xor", "mul", "sub", "or", "and", "shl", "lshr"]
    L = ["define i64 @f(i64 %a, i64 %b) {", "entry:", "  %v0 = add i64 %a, %b"]
    for i in range(1, n):
        op = ops[i % len(ops)]
        rhs = str(i % 7 + 1) if op in ("shl", "lshr", "mul") else f"%v{i // 2}" if i % 3 else "%b"
        L.append(f"  %v{i} = {op} i64 %v{i - 1}, {rhs}")
    L += [f"  ret i64 %v{n - 1}", "}"]
    return L


def shape_diamonds(n):
    """A chain of n if/else diamonds joined by phis."""
    L = ["define i32 @f(i32 %x0, i32 %k) {", "entry:", "  br label %b0"]
    for i in range(n):
        L += [f"b{i}:", f"  %c{i} = icmp slt i32 %x{i}, %k", f"  br i1 %c{i}, label %t{i}, label %e{i}",
              f"t{i}:", f"  %y{i} = add i32 %x{i}, {i + 1}", f"  br label %m{i}",
              f"e{i}:", f"  %z{i} = sub i32 %x{i}, {i + 3}", f"  br label %m{i}",
              f"m{i}:", f"  %x{i + 1} = phi i32 [ %y{i}, %t{i} ], [ %z{i}, %e{i} ]",
              f"  br label %b{i + 1}" if i + 1 < n else f"  ret i32 %x{i + 1}"]
    L.append("}")
    return L


def shape_allocas(n):
    """32 stack slots updated inside a chain of n diamonds, so promotion needs phis everywhere.

    (A slot count proportional to n would make the output, and LLVM's time, quadratic by construction.)"""
    k = 32
    L = ["define i32 @f(i32 %a, i32 %k) {", "entry:"]
    L += [f"  %s{j} = alloca i32, align 4" for j in range(k)]
    L += [f"  store i32 %a, ptr %s{j}, align 4" for j in range(k)]
    L.append("  br label %b0")
    for i in range(n):
        s, u = i % k, (i * 7 + 1) % k
        L += [f"b{i}:", f"  %l{i} = load i32, ptr %s{s}, align 4", f"  %c{i} = icmp slt i32 %l{i}, %k",
              f"  br i1 %c{i}, label %t{i}, label %m{i}",
              f"t{i}:", f"  %y{i} = add i32 %l{i}, {i + 1}", f"  store i32 %y{i}, ptr %s{u}, align 4", f"  br label %m{i}",
              f"m{i}:", f"  br label %b{i + 1}" if i + 1 < n else f"  %r = load i32, ptr %s{u}, align 4"]
    L += ["  ret i32 %r", "}"]
    return L


def shape_switch(n):
    """One switch with n cases, each computing a value, merged by an n-way phi."""
    L = ["define i32 @f(i32 %x, i32 %y) {", "entry:", "  switch i32 %x, label %def ["]
    L += [f"    i32 {i * 3}, label %c{i}" for i in range(n)]
    L += ["  ]"]
    for i in range(n):
        L += [f"c{i}:", f"  %v{i} = mul i32 %y, {i + 2}", "  br label %join"]
    L += ["def:", "  br label %join", "join:",
          "  %r = phi i32 " + ", ".join([f"[ %v{i}, %c{i} ]" for i in range(n)] + ["[ 0, %def ]"]), "  ret i32 %r", "}"]
    return L


def shape_calls(n):
    """n internal functions forming a call DAG (f_i calls f_{i-1} and f_{i/2}), plus one exported entry."""
    L = ["define internal i32 @f0(i32 %x) {", "  %r = add i32 %x, 1", "  ret i32 %r", "}"]
    for i in range(1, n):
        L += [f"define internal i32 @f{i}(i32 %x) {{", f"  %a = call i32 @f{i - 1}(i32 %x)",
              f"  %b = call i32 @f{i // 2}(i32 %a)", f"  %r = xor i32 %b, {i}", "  ret i32 %r", "}"]
    L += ["define i32 @entry(i32 %x) {", f"  %r = call i32 @f{n - 1}(i32 %x)", "  ret i32 %r", "}"]
    return L


def shape_loops(n, per=50):
    """n/50 sequential counted loops over an array argument. (LLVM's -O2 takes minutes at 800 loops.)"""
    k = max(1, n // per)
    L = ["define i64 @f(ptr %p, i64 %len) {", "entry:", "  br label %h0"]
    for i in range(k):
        prev_acc = "0" if i == 0 else f"%acc{i - 1}.out"
        pred = "entry" if i == 0 else f"x{i - 1}"
        L += [f"h{i}:", f"  %i{i} = phi i64 [ 0, %{pred} ], [ %i{i}.n, %h{i} ]",
              f"  %acc{i} = phi i64 [ {prev_acc}, %{pred} ], [ %acc{i}.n, %h{i} ]",
              f"  %g{i} = getelementptr inbounds i64, ptr %p, i64 %i{i}", f"  %v{i} = load i64, ptr %g{i}, align 8",
              f"  %w{i} = mul i64 %v{i}, {i + 3}", f"  %acc{i}.n = add i64 %acc{i}, %w{i}",
              f"  %i{i}.n = add nuw nsw i64 %i{i}, 1", f"  %c{i} = icmp ult i64 %i{i}.n, %len",
              f"  br i1 %c{i}, label %h{i}, label %x{i}",
              f"x{i}:", f"  %acc{i}.out = phi i64 [ %acc{i}.n, %h{i} ]",
              f"  br label %h{i + 1}" if i + 1 < k else f"  ret i64 %acc{i}.out"]
    L.append("}")
    return L


def shape_globals(n):
    """n internal globals, each written by a setter and read by a getter."""
    L = [f"@g{i} = internal global i32 {i}, align 4" for i in range(n)]
    for i in range(n):
        L += [f"define void @set{i}(i32 %v) {{", f"  store i32 %v, ptr @g{i}, align 4", "  ret void", "}",
              f"define i32 @get{i}() {{", f"  %v = load i32, ptr @g{i}, align 4", "  ret i32 %v", "}"]
    return L


# shape -> (generator, pass pipelines it times besides parse+print)
SHAPES = {
    "straightline": (shape_straightline, ["-passes=instcombine", "-passes=early-cse", "-O2"]),
    "diamonds": (shape_diamonds, ["-passes=simplifycfg", "-O2"]),
    "allocas": (shape_allocas, ["-passes=mem2reg", "-passes=sroa", "-O2"]),
    "switch": (shape_switch, ["-passes=simplifycfg", "-O2"]),
    "calls": (shape_calls, ["-passes=inline", "-O2"]),
    "loops": (shape_loops, ["-O2"]),
    # Same shape with 10x the loops, for the loop passes: at /50 they cost too little to measure.
    "loops-many": (lambda n: shape_loops(n, 5), ["-passes=loop-rotate", "-passes=licm"]),
    "globals": (shape_globals, ["-passes=globalopt", "-O2"]),
}


def gen_shape(shape: str, n: int):
    fn, pipelines = SHAPES[shape]
    head = [f"; @perf-size: {n}"] + [f"; @opt: {p}" for p in pipelines] + ["; @perf: opt"] + [f"; @perf: opt {p}" for p in pipelines]
    head.append(f"; @generated: harness/run gen-perf, shape {shape!r}, n={n}")
    write(PERF / "scaling" / shape / f"n{n}.ll", head, "\n".join(fn(n)) + "\n")


# ---------------------------------------------------------------- driver

def write(path, head, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(head) + "\n" + body)


def cmd_gen_perf(a):
    if a.clean:
        shutil.rmtree(PERF, ignore_errors=True)
    for shape in SHAPES:
        for n in SIZES:
            gen_shape(shape, n * SIZE_FACTOR.get(shape, 1))
    print(f"scaling: {len(SHAPES)} shapes x {len(SIZES)} sizes")
    with ThreadPoolExecutor(max_workers=8) as ex:
        errs = dict(zip(PROGRAMS, ex.map(gen_program, PROGRAMS)))
    for name, e in errs.items():
        print(f"  {'ok' if not e else 'FAILED'} compile/{name}.ll" + (f"\n{e}" if e else ""))
    # The oracle must accept every generated check, like everywhere else in the corpus.
    tests = [corpus.parse(p) for p in sorted(PERF.rglob("*.ll"))]
    pairs = [(t, ch) for t in tests for ch in t.checks()]
    with ThreadPoolExecutor(max_workers=16) as ex:
        bad = [o for o in ex.map(lambda p: checks.CHECK_FNS[p[1]](config.REFERENCE_IMPL, p[0]), pairs) if o.status != checks.PASS]
    for o in bad:
        print(f"  oracle rejects {o.test_id}:\n{o.message[:1500]}")
    print(f"{len(tests)} files, {len(pairs)} checks, {len(bad)} rejected by the oracle")
    if bad or any(errs.values()):
        sys.exit(1)
