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

## Query details

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
