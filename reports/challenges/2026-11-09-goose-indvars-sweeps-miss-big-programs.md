# Sweeps reported 0 differs while the big perf programs still differed (and no `@perf` line times indvars)

- **Date / implementation / unit:** 2026-11-09 / goose / L1.indvars
- **What happened:** after the port, `sweep --passes 'loop(indvars)'` whole-file and `--per-function` (69778
  functions), `--with-test-flags`, and `print<scalar-evolution>` all reported 0 differs. Timing indvars by hand on
  tests/perf/compile (because no `@perf` line runs indvars) showed two of the four programs failing loudly (X86
  TTI gaps for scalar `shl`/cast costs that no corpus file reaches) and, once those were fixed, a silent
  WidenIV mismatch in all four (an early return where LLVM falls through to widenWithVariantUse). The sweep
  excludes tests/perf by default, and the corpus' IndVarSimplify-relevant files are small, so this class of bug
  (needs a realistic `sext(sub nsw ...)` pattern with an x86 triple) was invisible to every required check.
- **Time or effort lost:** ~30 min to find and fix; it would have shipped silently if I had stopped at the
  required sweeps.
- **What would have helped:** a documented "big-program check" in the port-pass skill: run the pass (after
  `sroa,loop(loop-rotate)`-style canonicalization) over tests/perf/compile and compare canonicalized `-S` output
  with LLVM, or make `sweep` accept `--include-perf`. A `@perf` line (or a scaling shape) per loop pass would also
  have shown the loud TTI failures in `perf`.
- **What you did instead:** compared `opt -passes='sroa,loop(loop-rotate,indvars)' -S` on the four programs by
  hand (llvm-as | llvm-dis on both sides); 0 lines of diff after the fix. Recorded in impl/goose/NOTES.md.
