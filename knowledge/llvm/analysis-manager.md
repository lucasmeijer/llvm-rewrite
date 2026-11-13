# The analysis managers: how long analysis results live

Facts about LLVM 23.1.5's FunctionAnalysisManager / ModuleAnalysisManager (llvm/include/llvm/IR/PassManager.h,
PassManagerImpl.h, lib/IR/PassManager.cpp) that change optimized output, for implementations that cache analyses.

## Results persist across adaptors

- A function analysis result lives until `invalidate(F, PA)` drops it, also across separate `function(...)`
  adaptors and across module passes that preserve FunctionAnalysisManagerModuleProxy. A later pass on F gets the
  cached result, which may be *stale but kept up to date* (and so differ from a recomputation):
  - ScalarEvolution kept by indvars: `function(loop(indvars,loop-deletion)),function(loop-unroll<O2>)` unrolls
    with the cached trip count (tests/pass/pass-manager/scev-cached-across-adaptors.ll; differs from
    `invalidate<scalar-evolution>` in between). See also scalar-evolution.md.
  - MemorySSA kept by early-cse<memssa>: `function(early-cse<memssa>),function(print<memoryssa>)` prints the
    access ids of the updated result, with gaps (tests/pass/pass-manager/mssa-cached-across-adaptors.ll).
  - BranchProbabilityInfo kept by instcombine, though it changed the branch condition (next section).
- ModuleToFunctionPassAdaptor returns `preserveSet<AllAnalysesOn<Function>>` + the proxy (PassManager.cpp:146):
  the per-function invalidation already happened after each pass.

## Who drops what (each analysis's `invalidate()`)

- DominatorTree, PostDominatorTree, LoopInfo, CycleInfo, BranchProbabilityInfo, BlockFrequencyInfo: kept if
  preserved, `AllAnalysesOn<Function>` or `CFGAnalyses` is (Dominators.cpp:114, LoopInfo.cpp:905,
  CycleAnalysis.cpp:25, BranchProbabilityInfo.cpp:1305, BlockFrequencyInfo.cpp:175). So BPI/BFI survive every
  CFG-preserving pass even when branch conditions change: `function(require<branch-prob>),function(instcombine),
  function(print<branch-prob>)` prints 50% for an `icmp sgt 0, %x` that instcombine turned into `icmp slt %x, 0`
  (37.5% when recomputed) (tests/pass/pass-manager/bpi-kept-with-cfg.ll).
- ScalarEvolution: dropped if not preserved, or if AssumptionCache, DominatorTree or LoopInfo is invalidated
  (ScalarEvolution.cpp:15156). MemorySSA: if not preserved, or AAManager or DominatorTree is (MemorySSA.cpp:2376).
  LazyValueInfo: only if not preserved. LoopAccessInfoManager: if not preserved, or AA, SCEV, LoopInfo or DT is.
- AAManager (AAResults::invalidate): stateless, so only `abandon<AAManager>` (`invalidate<aa>`) or an invalidated
  dependency drops it; BasicAA depends on the DominatorTree (and the AssumptionCache), so AA goes with the DT.
- **AssumptionCache::invalidate always returns false**: no PreservedAnalyses drops it. Only `FAM.clear(F)` does: a
  deleted function (GlobalOpt, the inliners, ArgumentPromotion call `FAM.clear(F, name)`), or a module pass whose PA
  doesn't preserve FunctionAnalysisManagerModuleProxy (`InnerAM->clear()`: every function). So the cache keeps its
  scan-then-registration order across passes, and an assume created by a pass that doesn't call
  `registerAssumption` (loop peeling, JumpThreading's cloning) is never seen by later passes. Passes that register:
  InstCombine (builder callback), SimplifyCFG (3 sites), PromoteMemToReg, InlineFunction, LoopRotate, LoopUnroll,
  UnrollRuntime, SimpleLoopUnswitch, AssumeBundleBuilder, VPlan.
- GlobalsAA (a module analysis) is stateless too: only an explicit abandon (`invalidate<globals-aa>`) drops it
  (GlobalsModRef.cpp:824).

## Module passes and the proxy

- Module passes that preserve FunctionAnalysisManagerModuleProxy (function analyses are then invalidated per
  function with the same PA): the function and CGSCC adaptors, IPSCCP (also DT, PDT), GlobalOpt (also CFG),
  Debugify only when applied to MachineFunctions. Everything returning `PreservedAnalyses::none()` (inferattrs,
  deadargelim, internalize, globaldce, constmerge, ModuleInlinerPass, ...) clears every function's results, the
  AssumptionCache included.
- AlwaysInlinerPass returns `preserveSet<AllAnalysesOn<Function>>` without the proxy (AlwaysInliner.cpp:298), so
  it clears every function too. ModuleInlinerWrapperPass returns `all()` minus InlineAdvisorAnalysis: its nested
  module pass manager already invalidated.
- CGSCC: FunctionAnalysisManagerCGSCCProxy never clears, it invalidates the SCC's functions with the PA
  (CGSCCPassManager.cpp:694).

## Outer-analysis proxies

- An AAManager result includes GlobalsAA only if GlobalsAA was cached when the result was created
  (AAManager::getModuleAAResultImpl), and then registers an outer invalidation: when GlobalsAA is invalidated, the
  module proxy abandons that function's AAManager (and so its MemorySSA). A function whose AA result was created
  before `require<globals-aa>` doesn't use GlobalsAA until its AA result is recomputed.

- GlobalsAA is stateless for the analysis manager: only `invalidate<globals-aa>` drops it, so the AAManager results
  that registered the outer invalidation stay valid through the whole -O2 pipeline (default-pipelines.md).
