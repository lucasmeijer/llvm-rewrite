# LoopVectorize execution: the first end-to-end test gates hundreds of lines, and the cost model gates the rest

- **Date / implementation / unit:** 2026-11-11 / jai / L1.vectorize.loop
- **What happened:** continuing the LoopVectorize port from "VPlans are built for forced VFs" to executing them.
  Nothing in executePlan can be validated alone: the first passing test (fneg.ll) needed unrollByUF, replicateByVF,
  packs/unpacks, broadcasts, ~12 executePlan transforms, region dissolution, the recipe executes, the skeleton and the
  loop metadata all at once (~2.2k lines of Jai written before the first run). Once it ran, 8 tests passed at once
  and every further feature (runtime checks, reductions, if-conversion, FORs, reverse accesses, minimal bitwidths)
  was a 50-300 line step with an immediate signal: 28 -> 173 of the unit's 468 `::opt` checks, 0 silent differences
  in the plain, `--with-test-flags` and `--per-function` sweeps throughout.
- **Time or effort lost:** little on the forced-VF path (the previous agent's data-flow-ordered next-steps list in
  NOTES.md was accurate and saved a lot of reading). The real limit is the cost model: almost every remaining X86
  test, all four tests/perf/compile programs, calls (decideCallWidening), predicated scalarization
  (computePredInstDiscount) and interleave groups need LoopVectorizationCostModel::getInstructionCost plus the VPlan
  recipe costs (several thousand lines across LoopVectorize.cpp / VPlanRecipes.cpp and the X86 TTI) before any of
  them can pass. That is another session on its own.
- **What would have helped:** sub-units with their own exit selectors (as the 2026-11-09 report suggested), e.g.
  "forced-VF / forced-IC on NoTTI" (now ~170 tests), "X86 cost model and VF selection", "interleave groups", "tail
  folding", "epilogue vectorization". An assertions-enabled LLVM build (`-vplan-print-after-all`,
  `-debug-only=loop-vectorize`) would still make silent plan differences far quicker to localise: twice a difference
  came from shared analyses (a SCEV wrap predicate's always-true check, InstSimplify's intrinsic folding) and was
  found by bisecting with hand-made dumps.
- **What you did instead:** a debug dump of the plan (`JAI_VPLAN_DEBUG=1`, vplan_print.jai) at the points executePlan
  changes it most, pushed after every feature, and a NOTES.md next-steps list ordered by how many tests each gap blocks.
