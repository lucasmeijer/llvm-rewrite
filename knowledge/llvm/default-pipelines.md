# The default pipelines (`-O#`, `default<O#>`): structure and state that decide output

Verified while porting llvm/lib/Passes/PassBuilderPipelines.cpp for impl/goose (pipelines.goose): the built pipeline
prints byte-identically to `opt -passes='default<O#>' -print-pipeline-passes` for O0..O3 (also with the cl::opts
below), and the corpus sweeps `-O0`/`-O1`/`-O2`/`-O3` give 0 differences. impl/jai found several of these first
(impl/jai/NOTES.md "Default pipelines").

## Structure

- `opt -O2` is `-passes=default<O2>`; `-O#` together with `-passes` is an error ("Cannot specify -O# and
  --passes=/--foo-pass, use -passes='default<O#>,other-pass'"). `default<Os>`/`default<Oz>`/`-Os`/`-Oz` are
  `LLVM ERROR: The optimization level "Os" is no longer supported. Use O2 in conjunction with the optsize attribute
  instead.` (`minsize` for Oz). setupOptionsForPipelineAlias turns loop and SLP vectorization on for O2/O3 only.
- The printed pipeline is not runnable as text (scalar-misc.md: `extra-simple-loop-unswitch-passes` loses its inner
  pass), and several constructor arguments are invisible in the text: LoopFullUnrollPass gets the opt level (text:
  O2), TailCallElimPass gets UpdateFunctionEntryCount = false (text: true), the simplification VectorCombinePass gets
  TryEarlyFoldsOnly = true (text: false), the O0 AlwaysInlinerPass gets InsertLifetimeIntrinsics = false, and the
  inliner's InlineAdvisor uses getInlineParamsFromOptLevel(Level) (differs from `-passes=inline` only at O3: 250).
  `drop-unnecessary-assumes<drop-deref>` prints as `drop-unnecessary-assumes`.
- ModuleInlinerWrapperPass is itself counted by -opt-bisect-limit, as `inliner-ml-advisor-release`; skipping it skips
  the whole inliner pipeline. It runs, in order: `require<globals-aa>`, `function(invalidate<aa>)`,
  `require<profile-summary>`, `cgscc(devirt<4>(inline, function-attrs<skip-non-recursive-function-attrs>,
  [argpromotion at O3], openmp-opt-cgscc, function<eager-inv;no-rerun>(<simplification>), function-attrs,
  function(require<should-not-run-function-passes>), coro-split, coro-annotation-elide))`, then the late
  `function(invalidate<should-not-run-function-passes>)`, which printPipeline does not show. It returns
  PreservedAnalyses::all() (the inner passes invalidate as they go).
- Required (never counted by bisect): every pass manager and adaptor, ee-instrument, coro-early/split/cleanup/elide,
  alloc-token, lower-comment-string, annotation-remarks, the ExtraLoopPassManager, verify. Loop adaptors count their
  loop-simplify and lcssa runs.
- O0 is `function(ee-instrument<>), always-inline, coro-cond(coro-early, cgscc(coro-split), coro-cleanup, globaldce),
  alloc-token, lower-comment-string, function(annotation-remarks)`; CoroConditionalWrapper runs its passes only when
  the module declares one of the non-overloaded coroutine intrinsics (Coroutines.cpp NonOverloadedCoroIntrinsics).

## Analysis state across the pipeline

- **GlobalsAA stays cached** after IR-changing module and CGSCC passes: GlobalsAAResult::invalidate returns true only
  for an explicit `invalidate<globals-aa>` (preservedWhenStateless). The CGSCC walk and everything after it query the
  result computed before inlining; RecomputeGlobalsAAPass (module optimization) recomputes it in place, and since
  that doesn't go through the result's move constructor, UnknownFunctionsWithLocalLinkage keeps its computed value
  there (alias-analysis-and-memoryssa.md: the freshly computed result always has it false).
- GlobalsAA's AnalyzeCallGraph skips functions without `isDefinitionExact()` = `!mayBeDerefined()`, and
  isInterposable() counts `noipa` definitions: a noipa function gets no FunctionInfo, so FunctionAttrs (which asks
  AA for the memory effects of non-exact definitions) infers nothing for it (Transforms/*/noipa.ll at -O2).
- CGSCCToFunctionPassAdaptor checks LazyCallGraphAnalysis on the *accumulated* PreservedAnalyses: once one function's
  pipeline didn't preserve the call graph, every later function of the SCC triggers
  updateCGAndAnalysisManagerForFunctionPass. With NoRerun it skips functions whose ShouldNotRunFunctionPassesAnalysis
  result is cached; that marker has the default invalidate(), so any PreservedAnalyses that doesn't preserve it (or
  AllAnalysesOn<Function>) drops it; with EagerlyInvalidate the adaptor invalidates each function with none().
- The ShouldRunExtraSimpleLoopUnswitch marker is created by IndVarSimplify only when it changed the loop and
  `runUnswitching()` (simplifyUsersOfIV reported it, or an exit condition was replaced); the ExtraLoopPassManager
  right after it runs its simple-loop-unswitch and abandons the marker.
- ExpandMemCmpPass computes BFI only when the cached ProfileSummaryInfo has a summary and uses a lazy DomTreeUpdater
  only when a DominatorTree is cached; X86 enableMemCmpExpansion: MaxNumLoads 2 (X86TargetLowering
  MaxLoadsPerMemcmp[OptSize]), NumLoadsPerBlock 2, overlapping loads, load sizes 64/32/16 (zero-equality only,
  by prefer-vector-width and AVX512/AVX/SSE2), 8 (64-bit), 4, 2, 1. TLI::getLibFunc(CallBase) has no availability
  check.
- CGProfilePass caches BFI for every function with a (non-synthetic) entry count and appends one `!{i32 5,
  !"CG Profile", distinct !{...}}` module flag with (caller, callee, count) triples in first-seen order; counts are
  getBlockProfileCount of the call's block, saturating, only for callees with isLoweredToCall and not dllimport.
