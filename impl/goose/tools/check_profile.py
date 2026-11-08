#!/usr/bin/env python3
"""Bounds-check profile of bin/opt: how often each source line's bounds checks run, and what they cost.

  tools/check_profile.py build              # writes /tmp/goose-checkprof/{opt_prof,opt_nochk}
  /tmp/goose-checkprof/opt_prof -S x.ll -passes=... -o /dev/null   # writes $GS_PROF_OUT (default
                                            # /tmp/goose-checkprof/prof.txt): "<count> <file> <line>"
  sort -rn /tmp/goose-checkprof/prof.txt | head -30

opt_prof counts every executed GS_IDX (the runtime's bounds-check macro) by source line; opt_nochk has GS_IDX
defined away, an upper bound on what removing checks (index types, checkfree) can save: compare instruction
counts with valgrind --tool=cachegrind. Both are built with a 128M stack reservation so they run under valgrind.
DESIGN.md §2.5 has the numbers this gave.
"""
import os, subprocess, sys

OUT = "/tmp/goose-checkprof"
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "src")
CC = "/opt/llvm-23.1.5/bin/clang"
D = "-DGS_STACK_RESERVE=(128ull<<20)"

OLD = """#define GS_IDX(i, n, f, l) \\
    ((uint64_t)(i) < (uint64_t)(n) ? (i) \\"""
PROF = r'''
#include <stdio.h>
#include <stdlib.h>
typedef struct { const char *f; int l; unsigned long long n; } gs_prof_e;
static gs_prof_e gs_prof_tab[1<<20];
static void gs_prof_dump(void) {
  FILE *o = fopen(getenv("GS_PROF_OUT") ? getenv("GS_PROF_OUT") : "/tmp/goose-checkprof/prof.txt", "w");
  for (long k = 0; k < (1<<20); k++) if (gs_prof_tab[k].f) fprintf(o, "%llu %s %d\n", gs_prof_tab[k].n, gs_prof_tab[k].f, gs_prof_tab[k].l);
  fclose(o);
}
static int gs_prof_hit(const char *f, int l) {
  static int init; if (!init) { init = 1; atexit(gs_prof_dump); }
  unsigned long long h = ((unsigned long long)(uintptr_t)f * 0x9E3779B97F4A7C15ull) ^ ((unsigned long long)l * 0xC2B2AE3D27D4EB4Full);
  long k = (long)(h >> 44);
  for (;;) { if (gs_prof_tab[k].f == f && gs_prof_tab[k].l == l) { gs_prof_tab[k].n++; return 0; }
    if (!gs_prof_tab[k].f) { gs_prof_tab[k].f = f; gs_prof_tab[k].l = l; gs_prof_tab[k].n = 1; return 0; }
    k = (k + 1) & ((1<<20) - 1); }
}
#define GS_IDX(i, n, f, l) \
    (gs_prof_hit((f),(l)), (uint64_t)(i) < (uint64_t)(n) ? (i) \
'''.lstrip("\n").rstrip("\n").rstrip("\\").rstrip() + " \\"
NOCHK = "#define GS_IDX(i, n, f, l) ((void)(n), (i))\n#define GS_IDX_UNUSED(i, n, f, l) \\"


def sh(*a):
    subprocess.run(a, check=True)


def main():
    if sys.argv[1:] != ["build"]:
        sys.exit(__doc__)
    os.makedirs(OUT, exist_ok=True)
    sh("goose", "-o", f"{OUT}/opt.c", os.path.join(SRC, "opt.goose"))
    sh("goose", "--emit-runtime", f"{OUT}/rt.c")
    c = open(f"{OUT}/opt.c").read()
    assert OLD in c, "GS_IDX definition changed; update tools/check_profile.py"
    open(f"{OUT}/opt_prof.c", "w").write(c.replace(OLD, PROF, 1))
    open(f"{OUT}/opt_nochk.c", "w").write(c.replace(OLD.split("\n")[0], NOCHK, 1))
    sh(CC, "-O2", "-c", f"{OUT}/rt.c", "-o", f"{OUT}/rt.o", "-DGS_RUNTIME_OBJECT", D)
    sh(CC, "-O2", "-c", os.path.join(SRC, "hostmath.c"), "-o", f"{OUT}/hm.o")
    for v in ("prof", "nochk"):
        sh(CC, "-O2", "-w", D, "-c", f"{OUT}/opt_{v}.c", "-o", f"{OUT}/opt_{v}.o")
        sh(CC, f"{OUT}/opt_{v}.o", f"{OUT}/rt.o", f"{OUT}/hm.o", "-o", f"{OUT}/opt_{v}", "-lm", "-pthread")
    print(f"built {OUT}/opt_prof and {OUT}/opt_nochk")


main()
