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

## SLPVectorizer (structure facts for porters; from reading SLPVectorizer.cpp of 23.1.5)

- Size and shape: 33.3k lines in one file (+ SLPVectorizer/SLPUtils.cpp). Roughly: helpers and
  `InstructionsState`/`getSameOpcode` (lines 100-1980), the `BoUpSLP` class body with `LookAheadHeuristics`,
  `VLOperands`, `TreeEntry`, the scheduler classes and `BlockScheduling` (1980-6540), then the out-of-line BoUpSLP
  methods: reordering (6600-9600), external uses and `buildTree`/`buildTreeRec`/`getScalarsVectorizationState`/
  `InstructionsCompatibilityAnalysis` (9600-13660), transforms (`transformNodes`, 15111), the cost model
  (`ShuffleCostEstimator` 15729, `getEntryCost` 17029, `getSpillCost`, `getTreeCost` 19859), code generation
  (`ShuffleInstructionBuilder` 22131, `vectorizeTree` 23272-25490), scheduling (25642-26866), minimum bit widths
  (26866-27780), and the pass driver (`SLPVectorizerPass`, 27779-end, with `HorizontalReduction` 29003-31460).
- The pass asks for TLI with `getCachedResult` (it is always cached in practice: ScalarEvolution and BasicAA, which
  are fetched first, require it).
- Defaults that make "simple" bundles complex: copyable elements are on (`-slp-copyable-elements`), loop-aware cost
  scaling by trip counts is on (`-slp-cost-loop-trip-count=2`, `-slp-per-lane-gather-scale`), masked stores are on,
  poor-throughput seeds (`fdiv`/`frem`/`sqrt`-like ops, `-slp-vectorize-poor-throughput`) are on.
- Seed collection: per block in post order (EH pads and blocks ending in `unreachable` skipped), stores grouped in
  a MapVector by `getUnderlyingObject` of the pointer, single-index non-constant-index GEPs by pointer operand; then
  store chains, `vectorizeChainsInBlock` (phis, reductions from phis and from roots without users, inserts,
  compares, non-vectorizable roots, FMA candidates last), GEP indices. Several sort comparators order by
  `Type::getTypeID()` and `Value::getValueID()` (the enum orders of Type.h / Value.def matter, e.g.
  UndefValue < PoisonValue < ConstantAggregateZero < ... < Argument < BasicBlock < ... < Instruction+opcode) and by
  dominator-tree DFS-in numbers (`DT->updateDFSNumbers()` is called first).
- `VLOperands::getBestLaneToStartReordering` keys a MapVector by a `hash_combine` of
  `(OpIdx + 1) * (ValueID + 1)` per operand; only equality of those hashes matters, so a port can key by the exact
  sequence instead of reproducing `hash_combine`.
- X86 target facts the SLP port relies on (X86TargetTransformInfo.h/.cpp): `preferAlternateOpcodeVectorization()`
  is **false** on X86 (true in the base), so split-vectorize nodes (canBuildSplitNode) are built for alternating
  bundles of more than 4 lanes; `isLegalStridedLoadStore` and `isLegalInterleavedAccessType` are the base `false`
  (no strided load/store nodes, no store interleave factor); `isLegalAltInstr` only accepts fsub/fadd alternation
  on float (SSE3, VF % 4 == 0) and double (SSE3, VF % 2 == 0).
- `getStoreMinimumVF` (BasicTTIImpl) uses `TLI->isOperationCustom(ISD::STORE, VT)`, which has **no** type-legality
  check (unlike isOperationLegal): X86 marks stores of v2i8/v4i8/v8i8/... Custom, so the VF halves down to 2 and
  4 x i8 store chains are tried.
- `getVectorCallCosts` retries an over-limit intrinsic cost with argument-aware IntrinsicCostAttributes; that query
  is not type-based, so BasicTTI recomputes the scalarization overhead from the arguments and ignores the
  ScalarLimit it was given (e.g. `powi(x, %n)` costs 10 for v4f32 instead of 10000 + 4).
- `HorizontalReduction::optimizeReducedVals` calls `buildInstructionsState(Ops, R, true, true)` with a
  "TryCopyableElementsVectorization" comment, but the two bools bind to WithProfitabilityCheck and
  SkipSameCodeCheck.
- `areAllUsersVectorized(I, VectorizedVals)`: with a non-null set, `hasOneUse()` only counts when `I` itself is in
  the set; the users are always checked with isVectorized / isVectorLikeInstWithConstOps / gathered extracts.
- Order-sensitive containers: `reorderBottomToTop`'s PriorityQueue (equal user indices: libstdc++ heap order decides
  OrdersUses' insertion order and so ties), `computeMinimumValueSizes`' `ExtraBitWidthNodes` (DenseSet<unsigned>:
  begin() is bucket order, hash = key * 37 in 64 buckets), `collectUserStores` (DenseMap keyed by pointers: hash
  order; the jai port fails loudly when it matters).
- VectorInstrContext hints only reach BasicTTI's getVectorInstrCost, which ignores them: on X86 they do not change
  any cost.

