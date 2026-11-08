# Reassociate

Facts about `Transforms/Scalar/Reassociate.cpp` (LLVM 23.1.5) that decide output. Verified by porting it
(impl/jai/src/pass_reassociate.jai) and sweeping `-passes=reassociate` over the whole corpus (whole-file and
`--per-function`, also `debugify,reassociate` and `-reassociate-use-cse-local=false`): 0 differences.

- **Ranks.** Arguments get 3, 4, ...; each block in RPO gets `(++Rank) << 16`; instructions with
  `mayHaveNonDefUseDependency` (memory, not speculatable, or not guaranteed to transfer execution) get consecutive
  ranks inside their block's range at the start. Other instructions get `1 + max(operand ranks)` lazily (capped at
  the block rank); `not`/`neg`/`fneg` don't add 1, so `X` and `~X` share a rank.
- `ValueRankMap[I]` and `RankMap[BB]` are `DenseMap::operator[]`: a lookup inserts a 0 entry. `EraseInst` only
  re-queues an operand's expression root if `ValueRankMap.contains(root)`, and a root counts as contained once its
  rank was *queried*, not only computed. Instructions in unreachable blocks get rank `0 (+1)` immediately, because
  `RankMap[unreachable BB]` is 0.
- Dead-instruction tests use `isInstructionTriviallyDead(I)` **without TLI**: a dead `call double @log(double 1.0)`
  is kept (isMathLibCallNoop needs a TLI). InstSimplify/InstCombine pass a TLI and remove it.
- `isa<ConstantInt>` is false for a scalable `splat (i32 1)` (a shufflevector ConstantExpr unless
  `-use-constant-int-for-scalable-splat`), so `shl <vscale x 1 x i32> %x, splat (i32 1)` is *not* turned into a
  multiply (InstCombine/add.ll `@add_to_or_scalable`). Fixed-length int splats are ConstantDataVector (not
  ConstantInt) unless `-use-constant-int-for-fixed-length-splat`; FP splats are always ConstantFP.
- `hasOneUse()` is false for ConstantData (Value::addUse skips values without a use list, Value.h), which matters in LinearizeExprTree's leaf
  logic if an implementation keeps use lists on constants.
- PairMap keys are canonicalised with `std::less<Value*>`, but only membership and counts are read, so pointer order
  does not leak into the output. Its scores are computed once per function, before any rewriting.
- `opt -run-twice` only acts in optdriver.cpp's legacy-PM path; with `-passes=`/`-O#` (NewPMDriver) it is silently
  ignored (Reassociate/pointer-collision-non-determinism.ll).
