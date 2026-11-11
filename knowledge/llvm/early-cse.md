# EarlyCSE: facts that matter for exact output

Verified against LLVM 23.1.5 (`lib/Transforms/Scalar/EarlyCSE.cpp`) and the imported EarlyCSE tests; every
claim was checked by comparing a port's output with opt on all of `tests/imported/llvm/Transforms/*/*.ll`.

- **`-earlycse-debug-hash` does nothing in our oracle.** It makes every hash 0 only under `#ifndef NDEBUG`
  (EarlyCSE.cpp:341); `opt --version` says "Optimized build" (no assertions). The 31 tests that pass it check
  normal hashing. Hash values never show in the output as long as equal keys hash equally, except through stale
  entries (below).
- **The tables are DenseMaps keyed by the first inserted key.** `ScopedHashTable::insert` does
  `TopLevelMap[Key]`, so a bucket keeps the key of its first insertion, and the scope destructor finds the bucket
  again with `TopLevelMap[ThisEntry->getKey()]` / `erase(key)`. If an inserted instruction's operands change
  later (CVP's `replaceDominatedUsesWith` rewrites uses inside the dominated region), its hash changes and the
  bucket is no longer found: lookups miss it, and the scope exit leaves it stale.
- **Traversal**: an explicit DFS over the dominator tree with a stack of nodes; a node's scope is opened when the
  node is *pushed* (before it is processed) and closed when it is popped. Children see the parent's generation
  as of the end of the parent's processing (`childGeneration`). A block whose `getSinglePredecessor()` is null
  (several predecessor *edges*, even from one block) bumps the generation.
- **Branch conditions** of the single predecessor are inserted as `true`/`false` values for `CondInst` and, through
  `m_LogicalAnd`/`m_LogicalOr` (instructions only), its operands, and their dominated uses are replaced
  (`replaceDominatedUsesWith(..., BasicBlockEdge(Pred, BB))`, skipping `llvm.fake.use` users).
- **`simplifyInstruction` gets a SimplifyQuery without a context instruction**, like InstSimplifyPass; it is called
  on every instruction, used or not.
- **combineIRFlags**: `andIRFlags` only if the surviving instruction is an FPMathOperator or has poison-generating
  flags and is not `programUndefinedIfPoison`; calls intersect their attribute lists (`tryIntersectAttributes`,
  AttributeList::intersectWith with the Attributes.td `Intersect*` rules: `IntersectPreserve` attributes must be
  equal on both sides or the calls are not equal at all, `IntersectAnd` kept when on both, `IntersectMin` the
  minimum, custom: align min, memory/captures union, nofpclass and, range union).
- **Loads CSE'd to an earlier load** call `combineMetadataForCSE(Earlier, Later, DoesKMove=false)`: `!range`,
  `!nofpclass`, `!align` and `!nonnull` are merged only when the earlier load has no `!noundef`; tbaa, alias
  scopes, invariant and dereferenceable metadata are kept as they are; unknown kinds are dropped.
- **Dead store elimination quirk**: when `LastStore` is removed because a later store overwrites it,
  `salvageKnowledge` is called on the *later* store (EarlyCSE.cpp:1718), so `--enable-knowledge-retention` adds
  an assume built from the surviving store.
- **MemorySSA mode** only changes `isSameMemGeneration`: different generations still match when MemorySSA says
  the later access's clobber (a fresh `BatchAAResults` per query, at most `-earlycse-mssa-optimization-cap`=500
  walker calls, then the defining access) dominates the earlier access. Removed instructions go through
  `MemorySSAUpdater::removeMemoryAccess(I, OptimizePhis=true)`. The pass preserves MemorySSA but not AA, so the
  next pass needing MemorySSA rebuilds it anyway (AAManager is invalidated).
- **Target memory intrinsics**: `TTI.getTgtMemIntrinsic` is false for x86 and for the default target, so only
  `llvm.masked.load/store` and `llvm.memset(.inline)` are memory "intrinsics" here; every other intrinsic call is
  a non-load, non-store `ParseMemoryInst` (not valid).
- **`--enable-knowledge-retention`**: EarlyCSE calls `salvageKnowledge(&Inst, &AC)` (no DT). With an
  AssumptionCache, `tryToPreserveWithoutAddingAssume` first looks for an existing assume bundle on the same value
  and attribute (`getKnowledgeForValue` over `AC.assumptionsFor`, filtered by `isValidAssumeForContext(Assume,
  Inst, nullptr)`): a bundle with an argument >= the new one makes the new knowledge redundant; a weaker one that
  comes after `Inst` gets its argument raised in place. The new assume is registered in the AC, so later
  simplifications in the same pass see it (`EarlyCSE/invariant.start.ll`, `guards.ll`, `invariant-loads.ll`, verified
  by impl/jai).
