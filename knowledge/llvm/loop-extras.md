# The Layer-1b loop passes: IRCE, guards, loop fusion / flatten, loop-misc extras, strength reduction

Facts that decide output, verified by the Jai port (`impl/jai/src/pass_irce.jai`, ...) against the imported tests and
whole-corpus sweeps.

## IRCE (`irce`, InductiveRangeCheckElimination.cpp + Utils/LoopConstrainer.cpp)

- A function pass. Before the worklist it runs `simplifyLoop(L, ..., PreserveLCSSA=false)` and
  `formLCSSARecursively(*L)` on every top-level loop with `for (const auto &L : LI)`: `L` is a *reference to the
  TopLevelLoops slot*, so when simplifyLoop separates a nested loop (separateNestedLoop → changeTopLevelLoop) LCSSA is
  formed for the new outer loop, not for the loop simplifyLoop was called on. Visible as extra `.lcssa` phis in the
  outer loop (sweep: IndVarSimplify/lcssa-preservation.ll, ValueTracking/phi-self.ll).
- The new pass manager always gives IRCE a GetBFI, so `estimatedTripCount` is header freq / preheader freq from BFI,
  never the latch-probability formula. The BPI it holds is computed once and survives every `AM.invalidate` (PA =
  all minus BFI), so after simplifyLoop it is stale: new blocks get the uniform 1/n probability; BFI recomputed later
  uses that stale BPI. `InvertBranch` of a range check also swaps the BPI edge probabilities.
- `LPMAddNewLoop(NL, false)` calls `appendLoopsToWorklist(*NL, ...)` with the *Loop* as the range, i.e. its subloops,
  and the new loop has none yet (createClonedLoopStructure adds them afterwards): the pre/post loops are never
  revisited. They also get `!loop_constrainer.loop.clone !{}` on the latch terminator and a distinct loop ID
  `!{self, !{"llvm.loop.unroll.disable"}, !{"llvm.loop.vectorize.enable", i1 false},
  !{"llvm.loop.licm_versioning.disable"}, !{"llvm.loop.distribute.enable", i1 false}}`.
- `setName("indvar.start")`, `"exit.preloop.at"`, `"exit.mainloop.at"` rename whatever SCEVExpander returned, which
  may be an existing argument or instruction; on a constant it does nothing.
- Cloned blocks are RemapInstruction'ed only: their debug records keep referring to the original loop's values (as
  in LLVM, RemapInstruction does not touch DbgRecords).
- `-irce-print-*` output goes to stderr and is not part of the `::opt` check.

## Guards (`loop-predication`, `guard-widening`, `lower-guard-intrinsic`, `lower-widenable-condition`, `make-guards-explicit`)

- `IRBuilder::CreateAnd(LHS, RHS)` only constant-folds when both operands are constants: `and %x, true` is *not*
  folded (IRBuilder.h:1570). LoopPredication's `CreateAnd(FirstIterationCheck, LimitCheck)` with a `LimitCheck` that
  `expandCheck` proved `true` keeps the `and ..., true` (sweep: IndVarSimplify/post-inc-range.ll).
- LoopPredication's profitability threshold is `LatchExitProbability * ScaleFactor` with a `float` ScaleFactor: there
  is no `BranchProbability * float`, so the float converts to `uint32_t` (`operator*(uint32_t)`, saturating at 1):
  `-loop-predication-latch-probability-scale=1.9` scales by 1, the default 2.0 by 2.
- `guard-widening` is both a FUNCTION_PASS and a LOOP_PASS (PassRegistry.def); inside `loop(...)`/`loop-mssa(...)`
  the loop version runs (root = loop predecessor or header, blocks filtered to root + loop, no post-dominator tree).
- None of these passes (nor IRCE / LoopConstrainer / SCEVExpander) call `salvageKnowledge`, so
  `-enable-knowledge-retention` changes nothing for them.

## LoopFlatten (`loop-flatten`, a LoopNest pass) and LoopFusion (`loop-fusion`)

- A loop pipeline made only of loop-nest passes (`loop(loop-flatten)`, `lnicm`, ...) runs in LoopNestMode: the
  worklist gets the top-level loops in LoopInfo order and pops from the back, so the *last* top-level loop is
  processed first (LoopPassManager.cpp:247). Otherwise loop-nest passes only run on outermost loops.
- LoopFlatten computes `LAIM.getInfo(*OuterLoop)` for every (outer, inner) pair; the outer loop is never innermost,
  so LoopAccessInfo stops at canAnalyzeLoop and the versioning has no SCEV predicates: the check block's condition is
  `false` until LoopFlatten replaces it with the `umul.with.overflow` overflow bit. `versionLoop()` still adds the
  LCSSA-style phis for `findDefsUsedOutsideOfLoop`.
- LoopFlatten's `LinearIVUses` is a `SmallPtrSet<Value *, 4>` that is *not* cleared between the first
  `CanFlattenLoopPair` and the one after IV widening, and DoFlattenLoopPair creates `flatten.trunciv` / GEPs in its
  iteration order (insertion order up to 4 elements, pointer order beyond). The IV widening leaves its dead
  instructions in place (DeadInsts is never cleaned).
- LoopFuse's `moveInstructionsToTheEnd` loops forever if the front instruction of the block cannot be moved
  (`while (FromBB.size() > 1)` with no progress); the Jai port fails loudly there.
- LoopFuse's `LoopDepthTree::size()` is `LoopsOnLevel.size() - RemovedLoops.size()`; RemovedLoops is cleared on
  `descend()`, so the `while (!LDT.empty())` test is just "is there a loop vector on this level".
- CodeMoverUtils' `collectInstructionsInBetween` uses a SmallPtrSet worklist, but the resulting set (everything
  reachable from the start without passing the end) does not depend on the visiting order.

## Loop-misc extras (`loop-versioning`, `loop-bound-split`, `loop-versioning-licm`, `hardware-loops`, `loop-unroll-and-jam`)

- `BasicBlock::getSingleSuccessor` counts successor *edges*: `br i1 %c, label %a, label %a` has none single
  (getUniqueSuccessor gives `%a`). MergeBlockSuccessorsIntoGivenBlocks (unroll-and-jam) therefore stops at such a
  block (sweep: Analysis/LoopNestAnalysis/duplicate-successors.ll with `-allow-unroll-and-jam -unroll-and-jam-count=4`).
- UnrollAndJamLoop calls `UnrollRuntimeLoopRemainder(..., true, SCEVCheapExpansionBudget, EpilogueLoop)`: the
  `Loop **EpilogueLoop` lands on the `bool RuntimeUnrollMultiExit` parameter (true) and `ResultLoop` keeps its
  nullptr default, so the pass never sees the epilogue loop and never gives it the
  `llvm.loop.unroll_and_jam.followup_remainder_outer` loop ID (LoopUnrollAndJam.cpp:241, UnrollLoop.h:94).
- The unroll-and-jam BasicBlockSets (SmallPtrSet<BasicBlock *, 4>) and the MergeBlocks set (SmallPtrSet<..., 16>)
  are pointer-ordered once they grow, but the output does not depend on it: the dependence pairs inside one set are
  checked with Sequentialized = true (accepts a pair iff it accepts the reversed pair) and merging block chains is
  confluent.
- LoopVersioningLICM's LoopAccessInfoManager has no TTI and no TLI: MaxTargetVectorWidthInBits is UINT_MAX and only
  intrinsics count as vectorizable calls. It asks for the info with AllowPartial = true.
- HardwareLoops: the `-force-hardware-loops`, `-hardware-loop-decrement`, ... cl::opts only configure the legacy
  pass; with the new PM only the `hardware-loops<...>` parameters count. Its `std::optional<bool>` options are tested
  for presence (`if (Opts.ForcePhi)`). With the function `strictfp`, every intrinsic call it creates gets the
  `strictfp` call-site attribute (IRBuilder::setIsFPConstrained -> setConstrainedFPCallAttr).
- LoopBoundSplit adds the post-loop as a sibling loop (U.addSiblingLoops), so it is visited by the rest of the
  loop pipeline.
