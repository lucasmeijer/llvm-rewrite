# CGSCC pipeline, FunctionAttrs and the inliner: behaviour that decides output

Verified with the Jai port (impl/jai/src/lazy_call_graph.jai, cgscc_pm.jai, pass_function_attrs.jai, inline_cost.jai,
inline_function.jai, pass_inliner.jai, psi.jai): the sweeps `cgscc(function-attrs)`, `inline`, `always-inline`,
`module-inline`, `require<profile-summary>,cgscc(inline)` and `cgscc(devirt<4>(inline,function(sroa,instcombine)))`
are identical to opt 23.1.5 on every round-tripping corpus file (also with each test's own flags), and 205/233
`::opt` checks of Transforms/Inline pass (the rest are `-O<n>` pipelines or fail loudly).

## Pass structure and analyses

- `-passes=inline` is ModuleInlinerWrapperPass: `cgscc(devirt<4>(inline))` with an InlineAdvisorAnalysis around it;
  `cgscc(inline)` is the bare InlinerPass. Neither *computes* ProfileSummaryInfo: the inliner, the advisor, the
  module inliner and InlineOrder all use `getCachedResult<ProfileSummaryAnalysis>`, so without
  `require<profile-summary>` earlier in the pipeline there is no PSI (no hot/cold call-site thresholds from the
  module summary, no function-entry-count updates). AlwaysInlinerPass uses `getResult`, so it always has a PSI and
  caches it for later passes. (Inliner.cpp:209, InlineAdvisor.cpp:147, AlwaysInliner.cpp:289.)
- With a PSI (even without a module summary) InlineCostCallAnalyzer::updateThreshold treats a callee with the `cold`
  attribute as a cold callee (isFunctionEntryCold), which disables all bonuses and caps the threshold at
  `-inlinecold-threshold`. With PSI null this branch is skipped.
- The cost-benefit analysis only runs with a PSI whose summary is an *instrumentation* profile (or with
  `-inline-enable-cost-benefit-analysis`), a caller with an entry count, a hot call site and a callee with a nonzero
  entry count. The X86 TTI does not override the savings multipliers: both are 8 (the cl::opt default of
  `-inline-savings-profitable-multiplier`, 4, applies only when the option is given).
- `Function::getEntryCount()` ignores `synthetic_function_entry_count` and treats `-1` as no count.

## Profile updates when inlining

- updateCallProfile runs for every inline with a callee entry count. The call-site count is
  `PSI->getProfileCount(CB, CallerBFI)` (the `!prof` total for a sample profile, else BFI's block count = entry count *
  block freq / entry freq, rounded, 128-bit). With no PSI or no BFI (always-inline passes no BFI) the count is 0, so
  the callee's count is unchanged but the *cloned* calls are still scaled by 0/CalleeCount
  (Inline/prof-update-sample-alwaysinline.ll).
- scaleProfData only rewrites "count type" profiles: `VP` value profiles, and a call's `branch_weights` only when it
  is *not* isBranchWeightMD, i.e. has a single weight (MinBWOps = 3 operands counts as branch weights). The rewritten
  node keeps just the name and the first weight (an `expected` origin is dropped); VP counts equal to
  NOMORE_ICP_MAGICNUM (-1) are kept. The vtable load of an indirect call (tryGetVTableInstruction) is scaled too.
- setEntryCount keeps the import GUIDs of the old `function_entry_count` node, deduplicated and sorted.

## Cost analysis details

- CallAnalyzer constant-folds calls with `ConstantFoldCall(&Call, F, Args)` but without a TargetLibraryInfo, so a
  library function (`fabsf(2.0)`) is *not* folded; only intrinsics are. A recursive call to such a function stays a
  recursive call (TailCallElim/inf-recursion.ll with `-passes=inline`).
- A `blockaddress` is not a user of its function in LLVM 23 (it has no operands), so it does not count as a live use
  for isSoleCallToLocalFunction / the dead-function check.
- AddAlignmentAssumptions (`-preserve-alignment-assumptions-during-inlining`) emits
  `call void @llvm.assume(i1 true) [ "align"(ptr %p, i64 A) ]`: the alignment is always i64.

## CGSCC update details

- DevirtSCCRepeatedPass counts direct and indirect calls through WeakVHs on the call instructions. InstCombine's
  transformConstExprCastCall replaces a call whose result is unused with `ValueHandleBase::ValueIsRAUWd(Caller, NC)`
  (InstCombineCalls.cpp), so the handle follows the new call: no "devirtualized" call appears, and the SCC is not
  re-run. Without that, `devirt<4>` repeats the pipeline and inlines more (Inline/inline-indirect-chain.ll).

## InlineFunction details (verified by the Goose port, impl/goose/src/inline_function.goose)

- BlockFrequencyInfo is cached per function and goes *stale*: the CGSCC inliner invalidates a caller's analyses only
  after all of its calls are processed (Inliner.cpp:547), the module inliner never does. Later cost queries in the
  same caller read the stale BFI; a block it does not know has frequency 0, which makes its call sites *cold*
  (threshold 45). InlineFunction keeps the stale BFI usable: `updateCallerBFI` runs on every inline (IFI.UpdateProfile
  defaults to true, not only with entry counts) and gives each cloned block its callee frequency (the max when
  several callee blocks fold into one clone), scaled so the entry clone gets the call site block's frequency; the
  split-off AfterCallBB gets OrigBB's frequency. The IFI constructor computes the caller's and the callee's BFI
  before inlining. (Inline/nested-inline.ll under both `inline` and `module-inline`.)
- `CallBase::isIndirectCall` is false for any Constant callee, so `call void undef()` is not "originally indirect"
  and gets no `!inline_history` (Inline/pr28298.ll).
- `Function::isIntrinsic()` is name based: a declaration `@llvm.unknown` (no intrinsic ID) is an intrinsic, so its
  calls are not InlinedCallSites and get no `!inline_history` (GVN/intrinsics_in_cg.ll with `module-inline`).
- AddParamAndFnBasicAttributes finds the argument behind an inner call's pointer operand with getUnderlyingObject's
  default MaxLookup = 10 (through launder/strip.invariant.group); with 6 the deeper calls lose `readnone`
  (Inline/launder.invariant.group.ll under `cgscc(devirt<4>(inline,function-attrs))`).
- The lifetime.start markers and llvm.stacksave are built at `FirstNewBlock->begin()`, an iterator with the head
  bit: they go *before* the debug records of the first instruction, and get its debug location
  (Inline/inline-skip-use-empty-alloca.ll).
- PruningFunctionCloner names a cloned terminator before inserting it, so the name is uniqued on insertion with the
  function's symbol table counter; re-creating a call with merged deopt bundles (`CallBase::Create(CB, Bundles)`)
  takes the old name while it is still live, so the new call is `%v.i1` and later uniqued names shift
  (Inline/deopt-bundles.ll).
- Deleting a function runs ~GlobalValue's removeDeadConstantUsers (e.g. `ptrtoint (ptr @f to i64)` left by an
  inlined call's argument), and the blockaddresses of its blocks die with the body (Inline/last-callsite.ll,
  GlobalOpt/2012-05-11-blockaddress.ll with `inline`).
- X86TTIImpl::areInlineCompatible with different features checks every non-intrinsic call of the callee whose
  argument/return types are vectors or aggregates: each ComputeValueVTs leaf must get the same
  `getRegisterTypeForCallingConv(callee CC)` under the caller's and the callee's subtargets
  (Inline/X86/call-abi-compatibility.ll).
