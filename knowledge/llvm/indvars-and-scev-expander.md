# IndVarSimplify and SCEVExpander: behaviour that decides output

Verified with the Jai port (impl/jai/src/scev_expander.jai, simplify_indvar.jai, pass_indvars.jai): 211/223
`::opt` checks of `Transforms/IndVarSimplify` (the rest need loop-deletion, simple-loop-unswitch, inline and
function-attrs), and `loop(indvars)` identical to opt 23.1.5 on every round-tripping corpus file, whole-file and
`--per-function` (69776 functions), and after `sroa,loop(loop-rotate,indvars)`.

## SCEVExpander

- The expander's IRBuilder is `IRBuilder<InstSimplifyFolder, IRBuilderCallbackInserter>`: every Create* first tries
  `simplifyBinOp` / `simplifyCastInst` / `simplifyCmpInst` / `simplifyGEPInst` / `simplifySelectInst` /
  `simplifyIntrinsic` with a bare `SimplifyQuery(DL)` (no DT, AC, TLI or context), and every inserted instruction is
  remembered (`InsertedValues`, or `InsertedPostIncValues` while PostIncLoops is non-empty).
- `CreateIntrinsic` computes the return type with `Intrinsic::getType` and only declares the intrinsic when the call
  is not folded: a folded `umax`/`smax` must not leave a declaration behind (IndVarSimplify/lcssa-preservation.ll).
- `expand` hoists the insertion point to the outermost loop preheader where the SCEV is invariant (only if no udiv by
  a non-constant or by zero), or to the header's first insertion point when the SCEV is computable in that loop, then
  skips instructions the expander inserted itself; the cache key is (SCEV, instruction at that point). Cached
  values are TrackingVHs: a later RAUW of the cached value (replaceCongruentIVs) changes what the cache returns.
- `visitAddExpr` / `visitMulExpr` sort (relevant loop, operand) pairs with `std::stable_sort` and a comparator that
  breaks ties arbitrarily (PickMostRelevantLoop), so the libstdc++ algorithm matters (same as GroupByComplexity).
- IndVarSimplify runs the expander in non-canonical mode: every AddRec is expanded literally
  (getAddRecExprPHILiterally), reusing a header phi whose SCEV matches and whose increment chain is "normal"
  (isNormalAddRecExprPHI), else creating `indvars.iv` / `indvars.iv.next` with nuw/nsw from IsIncrementNUW/NSW.
- `fixupLCSSAFormFor` inserts a temporary `tmp.lcssa.user` cast at the insertion point, runs
  formLCSSAForInstructions on the definition, and returns the cast's (rewritten) operand.

## IndVarSimplify order and side effects

- run(L): rewriteNonIntegerIVs (forgetLoop if anything changed), simplifyAndExtend (all header phis popped from the
  back, then the widest WideIVInfo first, new wide phis re-enter the worklist), rewriteLoopExitValues,
  replaceCongruentIVs, canonicalizeExitCondition, optimizeLoopExits (forgetTopmostLoop), predicateLoopExits
  (forgetLoop), LFTR per exiting block, `Rewriter.clear()`, the DeadInsts loop (popped from the back; phis through
  RecursivelyDeleteDeadPHINode), sinkUnusedInvariants, rewriteFirstIterationLoopExitValues, DeleteDeadPHIs(header).
- DeadInsts are `WeakTrackingVH`s: an entry RAUW'd later (a congruent phi already in the list) follows the new value,
  a deleted one becomes null. The Jai port keeps them in value-handle slots that replace_all_uses_with updates.
- `replaceFloatIVWithIntegerIV` returns the SimplifyIndvar object's *overall* Changed flag, not whether it replaced
  anything: once anything changed, every sitofp/uitofp user takes the "re-queue IV users and continue" path and
  skips the cast visitor and the isSimpleIVUser push (SimplifyIndVar.cpp).
- WidenIV clones (`BinaryOperator::Create(..., NarrowBO->getName())` followed by `IRBuilder::Insert(WideBO)`) end up
  unnamed: Insert calls `setName("")`. The name is first taken when the instruction is linked into the block, so a
  conflict bumps the function's unique-name counter (ValueSymbolTable::reinsertValue) before it is dropped.
- Loop::makeLoopInvariant is called *without* ScalarEvolution by LFTR's `wide.trip.count` and eliminateTrunc's
  ext, so it makes no forgetBlockAndLoopDispositions calls there (unlike LoopSimplify's use).
- Instructions created with an insert-before iterator (`BinaryOperator::Create(..., I->getIterator())`) adopt the
  debug records attached to I; inserting at `getFirstInsertionPt()` (head bit set) does not. sinkUnusedInvariants'
  `moveBefore(ExitBlock->getFirstInsertionPt())` leaves the moved instruction's records behind.
- `getStrengthenedNoWrapFlagsFromBinOp` passes the instruction as context to willNotOverflow
  (`-scalar-evolution-use-context-for-no-wrap-flag-inference`, default true).
- `getLoopInvariantExitCondDuringFirstIterations` drops samesign; with a umin max-iteration count it retries each
  umin operand.

## Neighbouring facts found on the way

- `CallBase::getRange()` intersects the call-site `range` return attribute with the callee's
  (Instructions.cpp:377): `call range(i8 -2, 3) i8 @llvm.ucmp` has range [-1,2) in print<scalar-evolution>
  (CorrelatedValuePropagation/uscmp.ll).
- `DominatorTree::dominates(const Instruction *Def, const BasicBlock *UseBB)` special-cases only invoke; a callbr
  result is treated like any instruction (IndVarSimplify/callbr.ll).
