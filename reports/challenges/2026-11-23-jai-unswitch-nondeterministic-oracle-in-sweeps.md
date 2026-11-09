# A sweep "differs" that was LLVM's own nondeterminism cost an investigation

- **Date / implementation / unit:** 2026-11-23 / jai / L1.unswitch
- **What happened:** `sweep --analysis --passes 'loop-mssa(simple-loop-unswitch<nontrivial>),print<domtree>'` reported
  3 silent mismatches. One was a "slow queries" count (21 vs 23) in `IndVarSimplify/X86/verify-scev.ll`, another the
  child order of two dominator-tree nodes in `JumpThreading/crash.ll`. I bisected with `-opt-bisect-limit`, added
  stack-trace logging to every slow DT query, and only then noticed that LLVM itself prints 21, 22 or 23 on repeated
  runs of the same command (pointer-keyed DenseMap/SmallPtrSet iteration in SimpleLoopUnswitch and the MemorySSA
  updater). For `crash.ll` 1 of 8 LLVM runs gave the other tree.
- **Time or effort lost:** about half an hour of instrumenting and bisecting before running the oracle twice.
- **What would have helped:** the check harness runs LLVM twice and marks such tests `invalid`; the sweep compares
  against one cached LLVM run. A `sweep --recheck-llvm` (rerun LLVM a few times on the files that differ and report
  them as `llvm-nondeterministic`) would have classified these immediately. Until then: when a sweep difference looks
  like an order or a counter, rerun LLVM's opt 5-10 times first.
- **What you did instead:** ran `/opt/llvm-23.1.5/bin/opt` 6-8 times per file, documented both cases in
  `knowledge/llvm/loops-and-cycles.md` (SimpleLoopUnswitch section) and `impl/jai/NOTES.md`.
