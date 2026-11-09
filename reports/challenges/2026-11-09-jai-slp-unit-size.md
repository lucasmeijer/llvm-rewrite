# L1.vectorize.slp is one 33k-line file: a single agent session cannot reach the first "not profitable" match

- **Date / implementation / unit:** 2026-11-09 / jai / L1.vectorize.slp
- **What happened:** the task asked for milestones "first whole functions where LLVM rejects (tree too small / not
  profitable), then simple store chains". "Tree too small" needs the driver, HorizontalReduction matching,
  InstructionsCompatibilityAnalysis, buildTreeRec with all opcode cases and BlockScheduling (~10k C++ lines); that
  milestone landed (sweep 5036 -> 6184 identical). But "not profitable" sits behind reorderTopToBottom /
  BottomToTop, transformNodes, computeMinimumValueSizes *and* the whole cost model (ShuffleCostEstimator,
  getEntryCost, getSpillCost, calculateTreeCostAndTrimNonProfitable, getTreeCost: another ~6k lines), because LLVM
  only decides profitability after all of them. One session ported ~30% of the file; the cost model is still open.
- **Time or effort lost:** most of the session went into reading the C++ (the file is far too large to read in one
  go, so it was read function by function in data-flow order, which costs context each time).
- **What would have helped:** splitting the unit into sub-units with their own exit criteria, e.g.
  L1.vectorize.slp.tree (sweep: every seed reaches buildTree/isTreeTiny without differs), .cost (functions LLVM
  leaves unvectorized match), .codegen (store chains), .reductions, .gathered-loads/copyables. A per-function
  sweep filter on "LLVM output == input" would also let a cost-model port be validated before codegen exists.
- **What you did instead:** ported in data-flow order with `slp_fail` at the frontier, so each stage is exercised by
  the corpus sweep (0 silent mismatches, all sweeps) even though nothing is vectorized yet; NOTES.md lists the
  remaining stages with their line numbers in SLPVectorizer.cpp.
