# L1.instcombine.arith cannot be completed by porting the arith files: every test file needs most of InstCombine

- **Date / implementation / unit:** 2026-11-08 / jai / L1.instcombine.arith (plus the InstCombine framework)
- **What happened:** the unit's exit tests are whole imported files (`add*.ll`, `sub*.ll`, `*div*.ll`, ...) checked
  with an exact `::opt` diff. Almost every function in them also contains compares, selects, shifts, casts or
  bitwise ops, and InstCombine rewrites those too (an `icmp ugt X, -2` must become `icmp eq X, -1`, a
  `shl (zext i1)` must become a select, `trunc` needs `canEvaluateTruncated`, ...). After porting
  InstructionCombining.cpp's driver, InstCombineAddSub.cpp, InstCombineNegator.cpp, InstCombineMulDivRem.cpp and the
  integer half of InstCombineSimplifyDemanded.cpp completely and in order, 48 of 115 files pass; nearly all of
  the remaining diffs are in code that belongs to the cmp/select/bitwise/cast units (and LibCallSimplifier,
  SimplifyDemandedFPClass, LowerDbgDeclare). The "arith" unit is really "arith + the cmp/select/shift/cast
  canonicalizations it touches", i.e. a large fraction of InstCombine's 56k lines.
- **Time or effort lost:** no circles, but the unit's progress number stalls well below COMPLETE no matter how
  faithfully its own files are ported; deciding which folds of other files to pull in early (icmp predicate
  canonicalization, zext/trunc/shift flag inference were worth it; FoldShiftByConstant and the select/icmp
  constant folds were too big to do here) was guesswork.
- **What would have helped:** exit tests that isolate one file's folds (or a selector of functions within a test
  file), or ordering the InstCombine units so the framework + cmp + select land before the arithmetic units are
  judged. A per-function pass count in `check` output would also show real progress inside a big file.
- **What you did instead:** ported the framework and the arith files completely, gave every other visitor a
  documented partial prologue (ic_misc.jai) that later agents extend in place, and made unported subroutines that
  are reached fail loudly. DESIGN.md §11 describes how to add a fold.
