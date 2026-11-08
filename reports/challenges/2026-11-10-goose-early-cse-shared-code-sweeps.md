# EarlyCSE was easy; the silent bugs were in shared code that only a whole-corpus sweep exposed

- **Date / implementation / unit:** 2026-11-10 / goose / L1.early-cse (+ task-0 fixes in shared value tracking)
- **What happened:** The EarlyCSE port itself passed 39/48 tests on the first build. Before calling it done I
  compared `opt -passes=early-cse` with LLVM on all 5007 imported Transforms files and found 15 silent
  differences. 14 were not in EarlyCSE but in InstSimplify/ConstantFolding code that a previous agent had marked
  done (unit at 438/498): `isEliminableCastPair` without the DataLayout, PatternMatch helpers matching
  ConstantExprs (`BinaryOp_match` doesn't in LLVM 23; the jai agent had already written this fact into
  knowledge/llvm, but the goose code was never checked against it), a guessed `findScalarElement`,
  `m_FPOne` allowing poison lanes, `isAssumeWithEmptyBundle`, a missing `paramHasNonNullAttr` case, and a
  libcall-deadness check that only became wrong when another agent ported libm folding the same day. One more
  silent mismatch was my own (x86 cvt folding of FP splats, which LLVM keeps as vector ConstantFPs); no corpus
  file had that input, I found it only by writing a test for the LLVM rule.
- **Task 0 was partly stale:** `call_range` had already been fixed by goose_apint and the avx512 case already
  failed loudly; checking that took a little time, porting the folding properly took more.
- **The flag question:** 31 tests pass `-earlycse-debug-hash`. It only does something in assertion builds;
  I had to check `opt --version` ("Optimized build") to decide it is a no-op for us. Nothing in the docs says
  whether the oracle has assertions.
- **Time or effort lost:** about a third of the session on shared-code bugs and on keeping rebases safe while
  three other goose agents pushed. Once I pushed right after a rebase onto a new goose commit before rerunning
  the ratchet (it passed when I ran it right after; still a process slip, caused by the push race).
- **What would have helped:** (1) a sweep as a standard step of finishing any unit that touches shared analyses
  (a `harness sweep` command appeared during the session; making it part of the finishing checklist in
  AGENTS.md would catch these early); (2) a note in tools-and-flags.md that the oracle is a release build
  (so `cl::opt`s guarded by `#ifndef NDEBUG` are inert); (3) when a fact lands in knowledge/llvm, a hint to grep
  the other implementations for code that contradicts it.
- **What you did instead:** a 20-second script that runs LLVM and our opt on every corpus file in parallel and
  diffs the canonicalized outputs; ran it for instsimplify, early-cse, early-cse<memssa>, dce (with and without
  `--enable-knowledge-retention`) and for `sroa,early-cse*` on all e2e inputs and perf programs until there
  were zero silent differences. I recommend it as the standard "done" check for any pass or analysis unit.
