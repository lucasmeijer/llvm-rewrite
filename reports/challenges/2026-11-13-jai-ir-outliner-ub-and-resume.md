# IROutliner: the oracle's output depends on undefined behaviour and on pointer order; resuming a crashed agent

- **Date / implementation / unit:** 2026-11-13 / jai / L1.extra.code-extraction, L1.extra.ir-outliner
- **What happened:** (1) I resumed a crashed agent's worktree with two unpushed commits. The rebase hit a conflict in
  `passes.jai` (a neighbouring `msan<` line from another agent); `main` moved twice more while the ratchet ran, so
  the push needed three fetch/rebase/check rounds. (2) The whole-corpus `print-ir-similarity` sweep was the only thing
  that exposed two behaviours no unit test covers: a GEP without indices makes LLVM's `isClose` read past the end of
  an empty `zip` (undefined behaviour: it compares memory behind the operand list, so such GEPs never match), and a
  call of an unknown `llvm.*` function is an `IntrinsicInst` named "not_intrinsic". Both were found only by bisecting
  sweep diffs with `llvm-extract`. (3) LLVM picks "larger candidates" from `DenseSet<IRSimilarityCandidate *>` in
  address order; 60 corpus files reached that, so failing loudly (the address-order policy) would have cost them.
  Instead I compute the result for every choice LLVM could make and fail only when they differ (they never do).
- **Time or effort lost:** about 20 minutes on the rebase/push loop, about 30 minutes on the two sweep findings,
  20 minutes on making the all-choices check fast enough for tests/perf (354k choices on SPASS.ll).
- **What would have helped:** a note in the address-order policy that "compute every possible order and require
  agreement" is an accepted alternative to failing loudly when the set of choices is small; the sweep's per-file
  diff naming the first differing function (I split files by hand with `llvm-extract` to find it).
- **What you did instead:** described both in impl/jai/NOTES.md and knowledge/llvm/ir-outliner.md. The
  "enumerate the choices, require agreement" approach seems worth making the standard where it is cheap.
