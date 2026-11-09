# L1.vectorize.loop is far larger than one agent session; the first vectorized loop needs ~20k lines of LLVM

- **Date / implementation / unit:** 2026-11-25 / jai / L1.vectorize.loop
- **What happened:** LoopVectorize in LLVM 23 is LoopVectorize.cpp (8.5k lines) plus the VPlan infrastructure
  (VPlan.h 5.2k, VPlanRecipes 5k, VPlanTransforms 7.8k, VPlanConstruction 2.3k, VPlanUnroll, VPlanUtils, ...),
  ~38k lines in total. Even the simplest test (`-force-vector-width=4` on a single-block `a[i] = b[i] + c` loop, no
  target triple) goes through ~40 VPlan transforms in buildVPlans/tryToBuildVPlan plus ~25 more in executePlan before
  any IR is emitted, and every recipe's `execute`. 334 of the 364 top-level LoopVectorize tests force the VF on NoTTI,
  so almost no test passes until that whole pipeline exists; the unit's exit count stays at the 27 "not vectorized"
  tests in the meantime. Because LLVM's release build has no `-vplan-print-*`/`-debug-only`, there is no way to
  compare intermediate plans against the oracle: only the final IR can be checked.
- **Time or effort lost:** most of the session went into reading the sources and porting the plan-building half
  faithfully (with loud failures at every unported branch) without being able to validate any of it end to end.
- **What would have helped:** splitting the unit into sub-units with their own exit selectors, e.g.
  "LV legality + no-vectorize decisions" (the 44 files LLVM does not vectorize), "forced-VF straight-line loops on
  NoTTI", "reductions/inductions/recurrences", "if-conversion", "X86 cost model", "epilogue vectorization". An LLVM
  build with assertions (for `-vplan-print-after-all` / `-debug-only=loop-vectorize`) in the workspace would make the
  VPlan stages checkable one by one.
- **What you did instead:** milestones pushed separately (legality and no-vectorize decisions; the VPlan data model
  and plan construction for forced VFs), each with 0 silent differences in the `--passes loop-vectorize` sweeps
  (plain, `--with-test-flags`, `--per-function --with-test-flags`), and a data-flow-ordered next-steps list in
  impl/jai/NOTES.md for the execution half.
