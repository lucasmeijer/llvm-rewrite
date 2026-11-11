# SLP cost model: a release-only opt made every cost mismatch a guessing game; an assertions build fixed it

- **Date / implementation / unit:** 2026-11-11 / jai / L1.vectorize.slp
- **What happened:** the task was to port SLPVectorizer's cost model (getEntryCost, ShuffleCostEstimator,
  calculateTreeCostAndTrimNonProfitable, getTreeCost, ...) so that functions LLVM rejects as unprofitable match.
  The first port compiled and moved ~500 files from loud to identical, but a few hundred trees still decided
  differently, and with /opt/llvm-23.1.5 being a release build there was no way to see LLVM's per-node costs
  (`-debug-only=SLP` is rejected). `-pass-remarks` only gives the final cost of vectorized trees. Each mismatch had
  to be reverse-engineered from IR and source reading (one took ~30 min to find that LLVM 23's `m_UMin` no longer
  matches selects).
- **Time or effort lost:** about an hour of guessing before building an assertions opt; afterwards every remaining
  mismatch took minutes: diff "SLP: Adding cost C for bundle Idx: N" lines, find the node, and when LLVM's debug
  output does not show the internals (ShuffleCostEstimator, isGatherShuffledSingleRegisterEntry,
  matchAssociativeReduction), add a temporary `LLVM_DEBUG(dbgs() << "TRACE ...")` to a copy of SLPVectorizer.cpp and
  rebuild opt incrementally (~1 minute). That found five bugs that had been invisible since the previous sessions
  (a broken (entry, edge) map, a stale-lane cache LLVM keeps, a loop-exit difference, getNumberOfParts for
  non-power-of-2 vectors, a `defer` loop step).
- **What would have helped:** an assertions build of opt next to the release one from the start (it is now at
  /persistent/llvm-rewrite/llvm-23.1.5-assert/bin/opt; impl/jai/tools/build_llvm_assert.sh rebuilds it from the
  /opt sources plus a sparse clone of the tag's cmake/, third-party/ and libc/: 12 minutes on 16 cores). A harness
  option `--oracle-debug=<type>` that runs it and stores the trace next to `expected.ll` would make this the default
  workflow for every port, not just SLP.
- **What you did instead:** `impl/jai/tools/slp_cost_compare.py` compares the sequence of getTreeCost decisions of
  both opts over a file list (whole corpus, with test flags, and every per-function piece that fails loudly); a
  second check confirms that no function that fails loudly at "vectorizeTree" is left unchanged by LLVM. Both now
  report 0 mismatches. This "decision-sequence oracle" is worth having for any pass whose output only changes after a
  long analysis (it validates the analysis before the transform exists).
- **Also:** a Jai precedence trap cost a lot and silently: `(cast(u64) x << 32)` parses as `cast(u64) (x << 32)`, so
  for 32-bit `x` the high half of a 64-bit key is lost. It was in three tables written by three different sessions
  (SLP operand-entry map, SLP alias cache, X86 load-ext actions). A lint for `cast(...) <ident> <<` in impl/jai would
  catch it; it is now documented in impl/jai/NOTES.md. The unit is still too large for one session: codegen
  (vectorizeTree + scheduleBlock + optimizeGatherSequence + reduction emission, ~4000 C++ lines) has not been
  started, and nothing vectorizes until all of it is exact.
