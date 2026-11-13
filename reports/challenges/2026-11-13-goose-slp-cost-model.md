# SLP: a 30k-line pass ported in data-flow order, verified only through debug traces

- **Date / implementation / unit:** 2026-11-13 / goose / L1.vectorize.slp
- **What happened:** the task listed copyable scheduling, reorderings + transformNodes + minbw + the full cost model,
  then codegen. The first three are now ported (≈6000 lines of goose) and every vectorization decision of the 1326
  SLP RUN lines matches the assertions opt's `-debug-only=SLP` trace (0 differ, ~970k lines). Codegen was not
  reached: almost no test can pass before vectorizeTree, so the visible progress is +60 opt tests (trees the cost
  model rejects), while the real progress is invisible to the harness.
- **Time or effort lost:** the trace compare found the bugs fast (a stale hash-key range that silently dropped entries,
  a lookup into the wrong link pool, an enum collision between CombinedOpcode and Freeze, 64-bit arithmetic in
  checkTreeSizes, slot numbers not invalidated after moving instructions). Each cycle is a ~70 s build plus a ~60 s
  compare. Writing large untested ports first and only then debugging worked because the trace pinpoints the first
  divergence; goose type-checks only instantiated code, so new files compile clean until they are called.
- **What would have helped:** a harness check kind for "debug trace is a prefix of the assertions build's" so the
  milestones could be roadmap sub-units with exit selectors; a smaller unit split (L1.vectorize.slp.cost,
  .codegen) so that one session can finish one.
- **What you did instead:** extended impl/goose/tools/slp_debug_compare.py (cost lines, a skip for the DenseMap-ordered
  recalculation block), documented the state and the codegen plan in impl/goose/NOTES.md "SLPVectorizer".
