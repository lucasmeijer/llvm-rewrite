# Alias analysis, capture tracking and MemorySSA (LLVM 23.1.5)

Verified facts that a port needs; each says how it was checked. Sources are under
`/opt/llvm-project-23.1.5/llvm/lib/Analysis/`.

## AA pipeline and aa-eval

- **Default `-aa-pipeline`** (opt's `-aa-pipeline` defaults to `"default"`): `basic-aa`, `scoped-noalias-aa`,
  `tbaa`, then `globals-aa` *only if it is cached* (it is a module analysis registered with
  `registerModuleAnalysis`, so the function-level AAManager only sees a cached result; `require<globals-aa>`
  caches it). Order matters: the aggregator stops at the first result that is not MayAlias
  (`AAResults::alias`), and ANDs mod/ref results (`PassBuilderPipelines.cpp` `buildDefaultAAPipeline`).
- **BasicAA requires the DominatorTree**: `BasicAA::run` calls `AM.getResult<DominatorTreeAnalysis>`, so the
  first AA query of a function computes the DT (visible to later `print<domtree>`).
- **aa-eval prints its summary in the pass destructor**, i.e. after the whole pipeline ran, with counters summed
  over all functions; per-function lines only with one of the `-print-*` flags. Pointer pairs are sorted by the
  operand text (`o2 < o1` string compare swaps them, and `AR.swap()` negates a PartialAlias offset). Every query
  gets a fresh `SimpleAAQueryInfo`, so nothing is cached across pairs (`AliasAnalysisEvaluator.cpp`).
- **Unnamed (numbered) struct types print as `%"type 0x…"`** in the pointer lines (`Type::print(.., NoDetails)`
  without a TypePrinter), so such outputs are nondeterministic; the instruction lines (`*I`) print `%0`.
- Checked by `tests/imported/llvm/Analysis/{BasicAA,TypeBasedAliasAnalysis,ScopedNoAliasAA,GlobalsModRef}` and a
  sweep of aa-eval (`-print-all-alias-modref-info -evaluate-aa-metadata`, default pipeline) over all 5007
  `tests/imported/llvm/Transforms/*/*.ll`: Goose and LLVM agree on every file except printer issues.

## BasicAA details that change answers

- **`MaxLookupSearchDepth` is 10** (`include/llvm/Analysis/ValueTracking.h:51`), and it is the default
  `MaxLookup` of `getUnderlyingObject`/`getUnderlyingObjects`. DecomposeGEPExpression walks at most 10 steps
  (`BasicAA/gep-decomposition-limit.ll` only matches with 10).
- **Constant GEP indices are sign-extended (`sextOrTrunc`) to the index width**; a zero-extended `i32 -1` gives
  wrong offsets (`BasicAA/recphi.ll`).
- **The alias cache is per AAQueryInfo and order-dependent**: a PHI query may record "assumption-based" NoAlias
  results that are later discarded (`aliasCheck`, `AssumptionBasedResults`). A BatchAAResults (MemorySSA build,
  the walker printer, DSE) reuses one cache, so answers can differ from fresh queries. Port the cache exactly
  (Definitive = -2, AssumptionBased = -1, use counts) and reuse/recreate query infos where LLVM does.
- The cache key orders the two locations by pointer value (`V1 > V2`); any total order gives the same results,
  because results are stored swapped and swapped back.
- **`isMallocOrCallocLikeFn` does not match `malloc`** in LLVM 23: the AllocationFnData table only has the
  `operator new` variants and strdup-likes (malloc is recognised through `allockind`) (`MemoryBuiltins.cpp`).
- **`captures(...)`**: `CallBase::getCaptureInfo` ANDs call-site and callee attributes; `byval` arguments
  capture nothing; a read-only call returning void can only capture the address (`DetermineUseCaptureKind`).
  `read_provenance` captures make BasicAA answer Ref instead of NoModRef for calls (`BasicAA/captures.ll`).

## GlobalsAA

- **`UnknownFunctionsWithLocalLinkage` is always false in the cached new-PM result**: `GlobalsAA::run` returns the
  result by value into the analysis manager, and `GlobalsAAResult`'s move constructor does not move that field.
  So an address-taken internal function does *not* disable `getModRefInfo`'s per-global refinement (verified:
  `store ptr @internal_fn, ptr @x` in a module still gives "Just Ref" for a readonly-ish call against an internal
  global with `-aa-pipeline=globals-aa`). `recompute-globalsaa` recomputes in place and would keep it.
- The SCC order is the Tarjan `scc_iterator` order starting at the CallGraph's external calling node; only
  functions reachable from it get a FunctionInfo, and `AnalyzeCallGraph` uses `SCC[0]`'s function for the
  declaration / optnone test of every member (`GlobalsModRef.cpp`).

## MemorySSA

- `print<memoryssa>` calls `ensureOptimizedUses()` first (unless `<no-ensure-optimized-uses>`); the walker
  printer doesn't. The walker printer computes clobbers lazily in printing order (block annotation, then each
  instruction) with one BatchAAResults for the whole function; `getClobberingMemoryAccess` sets the access's
  optimized operand, so a MemoryDef prints `->N` once it has been walked.
- IDs: liveOnEntry is ID 0 (printed `liveOnEntry`); MemoryDefs get IDs in instruction order during the build,
  then MemoryPhis in IDF order (the IDF priority queue is keyed on (dom-tree level, DFS-in number), so it is
  deterministic). MemoryUses have no ID.
- The upward walk translates the location through the MemoryPhi's block with PHITransAddr (MustDominate = true,
  SimplifyQuery without TLI/AC); if translation fails the *original* pointer is kept, and the size becomes
  `beforeOrAfterPointer` unless the pointer is guaranteed loop-invariant.
- Checked by `tests/imported/llvm/Analysis/MemorySSA` and by sweeps of `print<memoryssa>` and
  `print<memoryssa-walker>` over all `tests/imported/llvm/Transforms/*/*.ll` (identical except parser warnings)
  and `tests/perf/compile/sqlite3.ll` (byte-identical).
- LLVM's `print<memoryssa-walker>` is quadratic on modules with many functions (it rebuilds a module SlotTracker
  and TypeFinder per function print): 6 s on `tests/perf/scaling/globals/n8000.ll`.
