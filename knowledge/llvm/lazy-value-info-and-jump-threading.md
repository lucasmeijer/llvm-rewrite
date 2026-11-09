# LazyValueInfo, CorrelatedValuePropagation, JumpThreading, BranchProbabilityInfo, BlockFrequencyInfo (LLVM 23.1.5)

Facts needed to reproduce `-passes=correlated-propagation`, `-passes=jump-threading`, `print<lazy-value-info>`,
`print<branch-prob>` and `print<block-freq>` exactly. Sources: `lib/Analysis/LazyValueInfo.cpp`,
`lib/Transforms/Scalar/CorrelatedValuePropagation.cpp`, `lib/Transforms/Scalar/JumpThreading.cpp`,
`lib/Analysis/BranchProbabilityInfo.cpp`, `include/llvm/Analysis/BlockFrequencyInfoImpl.h`,
`lib/Analysis/BlockFrequencyInfoImpl.cpp`, `lib/Support/ScaledNumber.cpp`. "Verified" = a sweep or test difference
that only went away with the behaviour described (impl/jai, sweeps over every round-tripping file).

## LazyValueInfo
- The result is fully lazy: `print<lazy-value-info>` prints only the `LVI for function 'f':` header when nothing
  queried LVI before (e.g. `require<lazy-value-info>,print<...>`); the annotations are computed by the printer's
  own `getValueInBlock` queries, so the output depends on what JumpThreading cached before (stale entries included).
- The cache is never invalidated by Use::set (SSAUpdater rewrites, phi edits): only RAUW, deletion (value handles),
  `forgetValue`, `eraseBlock` and `threadEdge` (which drops *overdefined* entries only) remove entries.
- The AssumptionCache LVI holds is the never-invalidated one: after JumpThreading rewrites an assume's operand with
  SSAUpdater (Use::set) the cache still lists the old value as affected, so LVI does not see the assume for the new
  phi. Rebuilding the cache after the pass (which a fresh scan would do) changes `print<lazy-value-info>` results
  (verified: llvm-test-suite exptree.ll `getInput`, `constantrange<0, 8>` vs `<1, 8>`).
- The solver gives up after 500 processed stack items per query and marks only the *starting* stack entries
  overdefined; everything solved meanwhile stays cached.
- `CallBase::getRange()` intersects the call-site `range` return attribute with the callee's (intrinsics like
  ucmp/scmp get `range(i8 -1, 2)` declarations) — `call range(i8 -2, 3) @llvm.ucmp` gives `[-1, 2)`
  (verified: CorrelatedValuePropagation/uscmp.ll).
- Printer: `'<value>'` uses `Value::print` with its own SlotTracker. A global variable prints its whole definition
  (`constant<@g = internal global i8 0>`), a function its whole body or declaration followed by a newline (so the
  closing `>` lands on the next line), an instruction that references an MDNode numbers *all* module metadata
  (ShouldInitializeAllMetadata) — different `!N` from the surrounding function print (verified:
  JumpThreading/noalias-scope-decl.ll). Arguments print as `i32 %a`, blocks as operands.
- `isSafeToSpeculativelyExecuteWithVariableReplaced` in getValueAtUse is called with IgnoreUBImplyingAttrs=false.

## CorrelatedValuePropagation
- Blocks are visited with `depth_first(&F.getEntryBlock())`, a *lazy* iterator: a block's successors are read when
  the walk moves past it, so a switch case removed while visiting the block makes its target unreachable for the
  walk, and a later `ret` there does not contribute to the function's inferred `range` return attribute
  (verified: CorrelatedValuePropagation/basic.ll `switch_range`).
- processSwitch uses a Lazy DomTreeUpdater (flushed at the end of the call, also covering ConstantFoldTerminator).
- `PA.abandon<LazyValueAnalysis>()` always: the LVI cache never survives CVP, even when nothing changed.
- `isGuaranteedNotToBeUndef` of a constant vector: `containsUndefElement` is undef-but-not-poison, so
  `<i32 -3, i32 poison>` counts as not undef and is not frozen in expandUDivOrURem (verified:
  InstCombine/vector-urem.ll).

## JumpThreading
- The DomTreeUpdater is Lazy; deleted blocks stay in the function (with just `unreachable`) until a flush with no
  pending updates. `DTU->recalculate` (entry block replaced in MergeBasicBlockIntoOnlyPred) erases pending blocks
  *without* touching the tree (IsRecalculatingDomTree), then recalculates.
- BlockFrequencyInfo/BranchProbabilityInfo are only computed when a threaded block's terminator has branch weights
  (`doesBlockHaveProfileData`), through `runExternalAnalysis`: it invalidates everything except LVI, DT, BPI, BFI
  (the AssumptionCache survives anyway), flushes the DTU, then computes BFI/BPI on the current IR. Afterwards the
  pass keeps them up to date (new blocks get `setBlockFreq`, `updateBlockFreqAndEdgeWeight` rewrites the branch
  weights of the threaded block from the BFI frequencies).
- New blocks: `BB.thread` is created before BB then moved after PredBB; `select.unfold`, `thread-pre-split`,
  `.thr_comm`, `.split` (DuplicateInstructionsInSplitBetween) as in the source.
- cloneInstructions clones `llvm.experimental.noalias.scope.decl` scopes as anonymous distinct scopes
  `!{!self, domain, !"name:thread"}` and rewrites `!noalias`/`!alias.scope` of the copies.
- getJumpThreadDuplicationCost uses `TTI.getInstructionCost(TCK_SizeAndLatency)` (free instructions don't count).
- simplifyPartiallyRedundantLoad's BatchAAResults calls `disableDominatorTree()` (the DT is updated lazily): BasicAA's
  ValueTracking queries must then see no DT at all. Answering them with the stale tree made BasicAA call a store to
  `gep inbounds @f, %idx` NoModRef for a load of `@f` and PRE the load across the store (verified: impl/goose,
  JumpThreading/pr79175.ll).
- tryToUnfoldSelectInCurrBB's SplitBlockAndInsertIfThen gives the new conditional branch the debug location of the
  `br` that `splitBasicBlock` created, which is the split point's (`I->getStableDebugLoc()` without its atom group)
  (verified: JumpThreading/preserving-debugloc-fold-select.ll).
- MergeBasicBlockIntoOnlyPred of an address-taken block replaces the BlockAddress's uses with `inttoptr (i32 1)` and
  destroys it (reached by JT on SCCP/indirectbr.ll).

## BranchProbabilityInfo
- `calcZeroHeuristics` ignores the result of `TLI->getLibFunc(*CalledFn, Func)`: Func is set from the *name* before
  the prototype check, so `declare i32 @memcmp(ptr, ptr)` (wrong prototype) still counts as memcmp (verified:
  BranchProbabilityInfo/libfunc_call.ll).
- SccInfo numbers and classifies the blocks of an SCC one at a time, so a block classified early sees later blocks
  of its own SCC as "outside" (header/exiting bits). `SccBlocks` is a DenseMap iterated in pointer order in
  getSccEnterBlocks/ExitBlocks; impl/jai uses insertion order (no test depends on it so far).
- Printing: `0x%08x / 0x%08x = %.2f%%` with the percentage rounded by `rint` first.
- calcFloatingPointHeuristics: `CmpInst::isTrueWhenEqual` of an FP predicate is true only for `true`, `ueq`, `uge`,
  `ule`, so `fcmp oeq` gets the "unlikely equal" weights the wrong way round from what the comment suggests:
  `{FPTakenProb, FPUntakenProb}` = 62.5% for the true edge (verified: print<branch-prob> sweep, InstCombine/fmod.ll).

## BlockFrequencyInfo
- `print<block-freq>` prints every block in function order; a block unreachable from the entry has no node:
  `float = 0.0, int = 0`. `count = ` appears when the function has a `function_entry_count`.
- ScaledNumber printing (`toString(D, E, 64, 5)`) is LLVM's own digit loop, not printf.
- `combineWeights` uses a DenseMap (hash = key * 37, quadratic probing) above 128 weights, so the order of the
  successor weights of a huge switch is the bucket order; the DenseSet of irreducible headers without
  `irr_loop` weight likewise (64 buckets minimum after `reserve`).
