# No `@perf` line times CVP / JumpThreading / BPI / BFI, and the quadratic costs were in shared helpers

- **Date / implementation / unit:** 2026-11-24 / goose / L1.analysis.lvi, L1.cvp, L1.analysis.bfi, L1.jump-threading
- **What happened:** all four units went COMPLETE and every sweep was clean, but `./harness/run perf` has no
  benchmark for `correlated-propagation`, `jump-threading`, `print<branch-prob>` or `print<block-freq>`, so the
  "run perf for your pass" step reported nothing. Timing by hand (a small rusage script over tests/perf/compile and
  tests/perf/scaling) found three quadratic costs, none of them in the ported pass logic itself: a per-function scan
  of the module for the guard intrinsic declaration (SPASS: CVP 0.5 s vs LLVM 0.35 s for the whole pipeline), a
  linear membership test in the shared DomTreeUpdater's DeletedBBs (JT on scaling/diamonds n8000: 0.25 s vs 0.05 s),
  and a linear SuccessorsCount map in processSwitch (scaling/switch n32000: 0.2 s vs 0.04 s). The DTU one affects
  every pass that deletes blocks through a lazy DTU, and nobody had seen it.
- **Time or effort lost:** about half an hour writing the timing script and profiling with callgrind (which needs a
  separate `GOOSE_STACK_RESERVE=128M` build).
- **What would have helped:** `@perf: opt -passes=correlated-propagation` / `jump-threading` /
  `require<block-freq>` lines on the scaling shapes (diamonds, switch, allocas, calls) and the compile programs, so
  `perf` reports exponents for them; a harness option to time an arbitrary pipeline over tests/perf the way `perf`
  does.
- **What you did instead:** fixed the three hot spots (now linear everywhere and at or below LLVM's time on the
  compile programs) and wrote the numbers into impl/goose/NOTES.md. Also: every rebase conflicted on the import list
  of passmgr.goose with the concurrent goose agents (one-line conflicts, but each needs a manual resolve and a full
  ratchet rerun); keeping imports one per line next to a related import (`import cvp; import jt;`) reduced it.
