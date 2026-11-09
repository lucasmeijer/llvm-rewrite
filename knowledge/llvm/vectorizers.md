# Vectorizers: VectorCombine, SLPVectorizer (and the TTI queries they share)

Facts about LLVM 23.1.5's vector passes that an implementation needs to match `opt` exactly. Verified against the
source (`llvm/lib/Transforms/Vectorize/*.cpp`) and the imported tests unless stated otherwise.

## VectorCombine

- **It runs without a target too.** `run()` bails only when `TTI.getNumberOfRegisters(getRegisterClassForType(true))`
  is 0. NoTTIImpl answers 8, so a module without a triple is combined with the base cost model
  (TargetTransformInfoImplBase: shuffles, insert/extract, memory ops and reductions cost 1, scalarization overhead 0,
  `getRegisterBitWidth` 32, `getMinVectorRegisterBitWidth` 128). On x86 only `-mattr=-sse` (no SSE1) disables it.
- **Driver order.** One pass over the reachable blocks in layout order (unreachable blocks are skipped, debug and
  pseudo-probe intrinsics too), then the InstructionWorklist (LIFO, `removeOne` may return a nulled slot) until empty;
  a trivially dead instruction taken from the worklist is erased instead of visited. `NextInst` is advanced when the
  recursive dead-instruction deletion erases it. Folds are tried in the fixed order of `FoldInst` (VectorCombine.cpp
  `run`): the first one that returns true wins.
- **`foldExtractedCmps` passes the cost kind as the preferred extract index**: `getShuffleExtract(Ext0, Ext1,
  CostKind)` binds `CostKind` (0 for throughput, 2 for `optsize`) to the `unsigned PreferredExtractIndex` parameter,
  so with equal extract costs an extract from lane 0 (or 2 under optsize) is the one kept. Reproduce it, it changes
  which lane is shuffled.
- **ConstantData has no use list in LLVM 23**: `hasOneUse()` of a `poison`/`undef`/`ConstantInt`/... is false. This
  matters in `foldShuffleOfShuffles` (the fake all-poison inner shuffle: `!OuterV1->hasOneUse()` is true for a poison
  operand, so its "inner cost" — `getInstructionCost` of the poison constant = TCC_Basic = 1 — is added to the new
  cost) and wherever an `m_OneUse` sees a constant.
- `getExtendedReductionCost(..., FastMathFlags(), ...)` passes an engaged `std::optional<FastMathFlags>` with no
  flags, so even integer reductions take `requiresOrderedReduction` = true inside X86's `getArithmeticReductionCost`
  (the ordered, scalarized cost). `getArithmeticReductionCost(..., std::nullopt, ...)` does not.
- `scalarizeOpOrCmp` renames whatever the scalar op folds to (`Scalar->setName(I.getName() + ".scalar")`), which
  can be an existing argument or instruction when InstSimplify returns an operand; `setName` on a constant is a no-op.
- New names: `foldBitOpOfCastops`/`foldBitOpOfCastConstant` name the inner op `<name>.inner` (`.inner` when the
  original is unnamed); scalarized loads are `<extract name>.scalar` and then take the extract's name via
  `replaceValue` (so they end up unnamed when the extract is unnamed: `takeName` drops the target's own name first).
- `foldSelectsFromBitcast` groups the selects in a `DenseMap<Value *, ...>` keyed by the condition and creates one
  vector select per group in map order (pointer hash); the jai port fails loudly when more than one group would be
  transformed.
- The pass's Builder is `IRBuilder<InstSimplifyFolder>` with `SimplifyQuery(DL)` (no TLI/DT/AC/context);
  `vectorizeLoadInsert`, `widenSubvectorLoad`, `foldInterleaveIntrinsics`, `foldDeinterleaveIntrinsics`,
  `shrinkLoadForShuffles` and `shrinkPhiOfShuffles` use a local `IRBuilder<>` (ConstantFolder) instead.
