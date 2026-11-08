# Minimising a sweep mismatch needs llvm-reduce plus an ad-hoc script; the harness has no "reduce" command

- **Date / implementation / unit:** 2026-11-20 / jai / L1.gvn
- **What happened:** after the port, `sweep --passes gvn` showed one silent mismatch in a 250-line test-suite file
  (sumarraymalloc.ll). The cause (LLVM's EarliestEscapeAnalysis cache inside MemoryDependence is computed once, on
  the IR as it is at the first query, and capture tracking gives up after 100 uses) only shows with ~60 users of
  one pointer, so it was invisible in any hand-written test. I wrote an interestingness script comparing both
  canonicalized outputs, ran `llvm-reduce`, then a line-deletion loop; the 1-minimal case still had 130 lines, and
  the fact that deleting *any* line removed the difference is what pointed at a use-count limit.
- **Time or effort lost:** ~30 minutes, mostly writing the interestingness test and reading the reduced case.
- **What would have helped:** `./harness/run reduce <file> --impl jai --passes ...` that wraps llvm-reduce with the
  sweep's own comparison (canonicalize both outputs, "interesting" = differs and both exit 0). A note in the
  debug-mismatch skill that "every line matters" in a reduced case usually means a counting limit
  (capture-tracking 100 uses, memdep 100 instructions / 200 blocks, gvn-max-num-deps ...).
- **What you did instead:** /tmp scripts (test.sh for llvm-reduce, dd.py for line deletion). They should become a
  harness command; the fix itself is in knowledge/llvm/gvn.md.
- Also: no `@perf` benchmark runs GVN, so `harness/run perf` can't report on it; a quadratic sort in
  domtree.jai's legalize_updates (50 s on diamonds n8000) was only found by timing by hand.
