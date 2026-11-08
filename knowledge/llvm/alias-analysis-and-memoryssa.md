# Alias analysis and MemorySSA

Facts about LLVM 23.1.5's AA stack (`lib/Analysis/{AliasAnalysis,BasicAliasAnalysis,TypeBasedAliasAnalysis,
ScopedNoAliasAA,GlobalsModRef,MemoryLocation,CaptureTracking,MemorySSA,PHITransAddr}.cpp`) that an implementation
has to reproduce. Verified with the jai port against opt on every round-tripping file of the corpus (`aa-eval
-print-all-alias-modref-info [-evaluate-aa-metadata]`, `print<memoryssa>`, `print<memoryssa-walker>`,
`-memssa-check-limit=3`, with and without `require<globals-aa>`): identical except for files where LLVM prints
diagnostics or struct-type addresses.

## AA pipeline

- **`-aa-pipeline` defaults to `default`** (`tools/opt/NewPMDriver.cpp`), i.e. `buildDefaultAAPipeline`
  (`PassBuilderPipelines.cpp`): BasicAA, ScopedNoAliasAA, TypeBasedAA, then GlobalsAA. X86 registers no extra AAs.
  Analyses are queried in that order; `alias` stops at the first non-MayAlias, mod/ref results are intersected.
- **GlobalsAA is a module analysis that AAManager only uses when it is already cached**
  (`AAManager::getModuleAAResultImpl`): without `require<globals-aa>` earlier in the pipeline it is never consulted,
  even when `-aa-pipeline=globals-aa,...` names it.
- **BasicAA always requests the DominatorTree** (`BasicAA::run`), so any AA query computes and caches it.
- **`GlobalsAAResult`'s move constructor doesn't move `UnknownFunctionsWithLocalLinkage`**, and the new pass manager
  moves the result into its cache, so in `opt` that flag is always false: an address-taken internal function does
  not disable GlobalsAA's per-function mod/ref answers (`tests/imported/llvm/Analysis/GlobalsModRef/
  intrinsic_addresstaken.ll`: `Just Ref` for `@llvm.stacksave` vs. a non-address-taken internal global).
- GlobalsAA's CallGraph SCCs come from `scc_iterator` starting at the external calling node only; internal functions
  not reachable from it get no FunctionInfo.
- `AnalyzeCallGraph` tests "declaration or optnone" on `SCC[0]`'s function for *every* member of an SCC (it
  uses `F`, not `SCC[i]`), and copies the SCC's FunctionInfo to the other members (`GlobalsModRef.cpp`).

## Query details

- **Constant GEP indices are sign-extended (`sextOrTrunc`) to the index width** in `DecomposeGEPExpression`; a
  zero-extended `i32 -1` gives wrong offsets (`BasicAA/recphi.ll`).
- **The alias cache is order-dependent**: aliasPHI can record "assumption-based" NoAlias results that are later
  dropped when the assumption is disproven (`aliasCheck`, `AssumptionBasedResults`, Definitive = -2,
  AssumptionBased = -1), so a reused BatchAAResults can answer differently from fresh queries. The cache key
  orders the two locations by pointer value; any total order (e.g. value ids) gives the same answers, since
  entries are stored swapped and swapped back.
- **`isMallocOrCallocLikeFn` does not match `malloc`**: the AllocationFnData table only has the `operator new`
  variants and strdup-likes (`MemoryBuiltins.cpp`; malloc is known through `allockind`).
- `captures(address, read_provenance)` on a call argument makes BasicAA answer `Just Ref` (not NoModRef) for calls
  against the object (`BasicAA/captures.ll`); `CallBase::getCaptureInfo` ANDs call-site and callee attributes and
  `byval` arguments capture nothing.
- Unnamed (numbered) struct types print as `%"type 0x…"` in aa-eval's pointer lines (`Type::print(.., NoDetails)`
  without a TypePrinter), so those outputs are nondeterministic; the `*I` instruction lines print `%0`.

- **`getUnderlyingObject`'s default MaxLookup is `MaxLookupSearchDepth` = 10** in LLVM 23 (ValueTracking.h), not 6;
  `DecomposeGEPExpression` uses the same limit (`BasicAA/gep-decomposition-limit.ll`).
- **aa-eval builds a fresh `SimpleAAQueryInfo` for every top-level query** (`AAResults::alias(LocA, LocB)`), so the
  alias cache and capture cache never carry over between pairs. MemorySSA uses one `BatchAAResults` per
  construction, one per `ensureOptimizedUses`, and one per walker-printer run; results can differ from fresh queries
  only through the cache's assumption handling, so a port must keep that state per query object.
- `AAResults::getModRefInfo(Call, Loc)` finishes with `& getModRefInfoMask(Loc)` using a *fresh* query info
  (no AAQI argument); so do the store case of `getModRefInfo(Store, Loc)` and `getSyncEffects`.
- The aa-eval report (`===== Alias Analysis Evaluator Report =====`) is printed by `~AAEvaluator`, i.e. when the pass
  pipeline is destroyed, after the output module was written; nothing is printed if it ran on no function.
- PrintResults orders a pair by the *string* of the operands (`o2 < o1` swaps them) and then flips the sign of a
  `PartialAlias (off N)` offset.
- `memset_pattern4/8/16` are only available on Darwin (TLI), so on x86_64-linux `MemoryLocation::getForArgument` falls
  back to `beforeOrAfterPointer` for them.
- `GlobalValue::isInterposable()` is true for `noipa` function *definitions* and, without `dso_local`, when the
  module flag `SemanticInterposition` is set (`Transforms/Inline/inline-semantic-interposition.ll` changes
  GlobalsAA's answers through `isDefinitionExact`).

## MemorySSA

- **IDs**: liveOnEntry is 0; MemoryDefs get 1, 2, … while instructions are scanned in block order; MemoryPhis are
  created afterwards, in the order the IDF calculator returns their blocks. MemoryUses have no ID and print the ID of
  their defining access (`liveOnEntry` for 0).
- **Construction does not optimize uses.** `print<memoryssa>` calls `ensureOptimizedUses()` first (the
  `<no-ensure-optimized-uses>` variant doesn't); `print<memoryssa-walker>` doesn't, but each walker query optimizes
  the access it is asked about *before* the access is printed, so a use shows its clobber (`MemoryUse(1) - clobbered
  by 1 = ...`) and a def shows `->N` when it has been optimized.
- `MemoryUse::isOptimized` is "OptimizedID == defining access's ID"; a load that is trivially optimizable to
  liveOnEntry (`!invariant.load`, or `getModRefInfoMask` without Mod) is created optimized.
- Annotations: `; <access>` lines come after the block label/preds line (block's MemoryPhi) and before each
  instruction (after its debug records), printed with `Function::print` (no leading blank line, metadata numbered like
  a single-function print).
- `instructionClobbersQuery` ignores defs of `allow.runtime.check`, `allow.ubsan.check`, `invariant.start/end`,
  `assume`, `noalias.scope.decl`, `pseudoprobe`; assumes and noalias-scope decls get no access at all.
- `upward_defs` phi-translates the location's pointer into each predecessor (`PHITransAddr`, with
  `MustDominate = true`) and widens the size to `beforeOrAfterPointer` unless the pointer is loop invariant
  (entry-block instruction, non-instruction, alloca, or constant-index GEP of those).
- If PHITransAddr fails (returns null), the walker keeps the *original* pointer for that predecessor (only the
  size is widened when the pointer isn't loop invariant).
- LLVM's `print<memoryssa-walker>` is quadratic on modules with many functions (a module SlotTracker and
  TypeFinder per function print): ~6 s on `tests/perf/scaling/globals/n8000.ll`.
- Also verified with the goose port: all 5007 `tests/imported/llvm/Transforms/*/*.ll` (aa-eval default pipeline +
  `-evaluate-aa-metadata`, both MemorySSA printers, globals-aa on GlobalsModRef/GVN/LICM/DSE) and
  `print<memoryssa>` on `tests/perf/compile/sqlite3.ll` (byte-identical).

## MemorySSA updates (MemorySSAUpdater)

Verified with the jai port (impl/jai/src/mssa_updater.jai): `loop-mssa(loop-rotate)` and `loop-mssa(licm)` followed by
`print<memoryssa>` / `print<memoryssa-walker>` identical to opt on every round-tripping corpus file.

- **Use-list order of accesses is observable.** RAUW and removeMemoryAccess re-point uses head first (push-front
  lists, like IR values), and `tryRemoveTrivialPhi` recurses over `users()` in that order, which decides which phis
  disappear and so the printed ids. A MemoryDef has two operands (defining, optimized), a MemoryUse one; a MemoryPhi is
  created with no reserved operands and grows like a hung-off list (`max(n + n/2, 2)`), each growth moving the copied
  uses to the front of their values' lists.
- **Value handles matter**: getPreviousDefRecursive's cache and phi operand vectors are TrackingVH (follow RAUW),
  InsertedPHIs / fixup lists are WeakVH (nulled on deletion, do not follow RAUW).
- `MemoryDef::resetOptimized` clears operand 1 (unlinking the use); `MemoryUse::resetOptimized` only forgets the id.
  `removeFromLookups` drops the defining operand and then (walker invalidateInfo) resets the def's optimized operand.
- `applyUpdates` with deletes and inserts updates the DominatorTree with `DT.applyUpdates(Updates, RevDeleteUpdates)`
  (pre/post-view GraphDiffs) before the MemorySSA insert updates, then applies the deletes again.
- `applyInsertUpdates` computes IDFs through a GraphDiff, whose forward children are the successors in **reverse**
  order (also for an empty GraphDiff), unlike insertDef's plain IDF (successors in order).
- `verifyMemorySSA` is compiled out of release builds (`#ifndef NDEBUG`): `-verify-memoryssa` and `verify<memoryssa>`
  never change opt's output.
- `MemorySSA::dominates(MA, const Use &)` for a phi use in the same block calls `locallyDominates(MA, cast(Use))`,
  and casting a Use yields its *value* (MA itself), so it is always true.

## DSE / MemCpyOpt facts

Verified with the jai port (`sweep --passes dse|memcpyopt`, whole-file and per-function: identical to opt).

- **`isMustAlias(const Value *, const Value *)` queries `LocationSize::precise(1)`** on both sides (AliasAnalysis.h,
  AAResults and BatchAAResults), not `beforeOrAfter`. With two unknown sizes BasicAA's aliasGEP returns MayAlias early,
  so `%g1 = gep %p, 16` vs an identical `%g2` is MustAlias only with the precise(1) form
  (`MemCpyOpt/memset-memcpy-redundant-memset.ll`, `pr102994.ll`).
- DSE's EarliestEscapeAnalysis is `EA(DT, /*LI=*/nullptr, &CI)`: "captured before" uses CycleInfo-based
  `isPotentiallyReachable` (same-block: reachable iff the block is in a cycle; cycles are skipped to their exit
  blocks) and `isNotInCycle` = `!CI->getCycle(BB)`. MemCpyOpt's EEA has neither (plain CFG walk) and lives for the
  whole pass run while each `BatchAAResults` is fresh.
- `DominatorTree::findNearestCommonDominator(Instruction *, Instruction *)` returns the other instruction when one
  block is unreachable (FindEarliestCapture reaches it with captures in unreachable code,
  `DeadStoreElimination/captures-before-load.ll`).
- `MemIntrinsic::getDest()` / `getSource()` strip pointer casts (including all-zero-index GEPs and addrspacecasts);
  MemCpyOpt builds its new memcpy/memmove from those, so `memmove(gep %b, 0, 0)` becomes `memmove(%b)`
  (`SROA/alignment.ll`), while `getRawDest()` is used for memsets created from memcpys.
- DSE calls `salvageKnowledge(I)` with no AssumptionCache: with `-enable-knowledge-retention` every deleted store/load
  leaves an `llvm.assume` with dereferenceable/nonnull/align bundles. `isKnowledgeWorthPreserving` calls
  `wouldInstructionBeTriviallyDead(Inst)` with TLI = null, so a `new`-like call without allockind attributes is not
  dead and its knowledge is kept (`BasicAA/2008-11-23-NoaliasRet.ll`).
- `CallBase::getParamAttr(ArgNo, Kind)` falls back to the callee's attributes: DSE's `initializes` handling sees
  attributes written only on the declaration.
