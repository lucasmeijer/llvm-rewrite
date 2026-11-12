# One session cannot hold both a VectorCombine port and a real start on SLP in goose

- **Date / implementation / unit:** 2026-11-12 / goose / L1.vectorize.vector-combine, L1.vectorize.slp
- **What happened:** the task asked for VectorCombine (6.6k lines of C++) and then SLPVectorizer "in the same
  milestone order" (driver/tree building/scheduling/reorder, then the cost model, then codegen). VectorCombine went
  well (130/130, all sweeps 0 differs, ~4 hours including the TTI layer). For SLP (33k lines) the driver alone touches
  BoUpSLP, HorizontalReduction and getSameOpcode within a few hundred lines of control flow, so the first milestone
  that can be tested in isolation is "driver that fails loudly at every entry into BoUpSLP": it passes 6 more SLP
  tests and gives 0-differ sweeps, but no vectorization. Tree building + scheduling + reordering (~8k lines) did not
  fit after VectorCombine.
- **Time or effort lost:** goose builds of opt take 5-6 minutes (opt is now ~200k lines of goose), so every
  edit-build-test cycle costs that much; `goose check` (13 s) catches type errors first, which helped a lot.
- **What would have helped:** splitting L1.vectorize.slp into units with their own exit selectors (driver + tree
  dump via `-debug-only=SLP`-style output, cost model verified tree by tree, codegen), the way LoopVectorize was split
  into .interleave / .tail-folding / ...; and a faster incremental goose build (per-module object caching).
- **What you did instead:** ported the driver faithfully with conservative loud boundaries, recorded the failure
  counts per boundary and a next-steps list in impl/goose/NOTES.md "SLPVectorizer".
