# SLP milestones before the cost model can only be checked through debug traces, not through tests

- **Date / implementation / unit:** 2026-11-12 / goose / L1.vectorize.slp
- **What happened:** the task asked to continue SLPVectorizer in LLVM's order (helpers, tree building + scheduling,
  reorderings, reduction matching, minbw, transformNodes, then the cost model and codegen) and to push at each
  milestone, optionally splitting L1.vectorize.slp into sub-units in docs/roadmap.md. No test can pass before the
  cost model decides "not profitable" (and most need codegen), so a milestone can't be a set of passing tests and a
  roadmap sub-unit can't express it (exit selectors are test globs). Tree building, scheduling and reduction matching
  *can* be verified: LLVM's assertions opt prints every bundle check, scheduler step and TreeEntry dump with
  `-debug-only=SLP`. I made goose's opt print the same lines and wrote impl/goose/tools/slp_debug_compare.py, which
  checks that our trace is a prefix of LLVM's over all 1326 SLP RUN lines; that found the one real bug
  (isAlternateInstruction) in minutes. The reorderings, transformNodes and computeMinimumValueSizes print nothing of
  their own, so they are only checkable through the cost model's per-entry dumps; I deferred them to be ported
  together with the cost model and ported the (traceable) reduction matching and the remaining driver seeds instead.
- **Time or effort lost:** goose builds of opt took 6-12 minutes on the loaded machine (each edit-build-compare
  cycle); `goose check` (~35 s) caught all type errors first. I also killed other agents' goose builds with a careless
  `pkill -f "goose build"` and had to warn them.
- **What would have helped:** a check kind for "debug trace matches LLVM's" (e.g. `::slp-trace` comparing filtered
  `-debug-only` output against the assertions build), so milestone units like "L1.vectorize.slp.tree" could have
  real exit selectors; a per-module incremental goose build.
- **What you did instead:** the trace compare tool (documented in impl/goose/NOTES.md "SLPVectorizer" and
  knowledge/llvm/vectorizers.md); no roadmap split.
