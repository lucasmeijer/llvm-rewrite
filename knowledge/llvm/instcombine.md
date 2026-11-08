# InstCombine: behaviour an implementation must reproduce

Facts verified against LLVM 23.1.5 (source: `llvm/lib/Transforms/InstCombine/InstructionCombining.cpp` unless
noted, and by diffing `opt -passes=instcombine` output on the imported tests).

## Pass driver

- `-passes=instcombine` turns **verify-fixpoint on** (`parseInstCombineOptions` in PassBuilder.cpp); the
  `InstCombineOptions` default (used by `-O2` pipelines) is off. `MaxIterations` defaults to 1. With verification
  on, the iteration loop still runs until an iteration makes no change, and fails with "Instruction Combining on
  F did not reach a fixpoint after 1 iterations..." if iteration 2 changed anything. The function attribute
  `"instcombine-no-verify-fixpoint"` and `instcombine<no-verify-fixpoint>` turn it off.
- **LastRunTrackingAnalysis**: InstCombinePass::run returns early (no change, PreservedAnalyses::all) when the
  function's LRT says InstCombine already ran and nothing invalidated the analysis since. InstCombine's options
  are *not* compared (`shouldSkip(&ID)` without a compatibility callback). A changing InstCombine preserves LRT
  and CFG analyses only; any other pass that doesn't preserve LRT invalidates it (source:
  `InstCombinePass::run`, `LastRunTrackingInfo::updateImpl`).
- Each iteration builds a fresh InstCombinerImpl: fresh DeadEdges, fresh DomConditionCache, fresh BackEdges.
  The RPOT is computed once for the whole run (before the first iteration).
- `prepareWorklist`: walk blocks in RPO; a non-entry block all of whose predecessors are dead edges or
  dominated by the block itself is dead (its successors' phi inputs from it become poison). For each live block:
  constant-fold instructions that have uses and whose first operand is a constant (or no operands)
  (`ConstantFoldInstruction`; erase if trivially dead), fold `ConstantVector`/`ConstantExpr` operands with
  `ConstantFoldConstant`, collect non-debug instructions; a `br`/`switch` on a constant marks only the taken
  successor live. Then every non-live block is emptied (`removeAllNonTerminatorAndEHPadInstructions`, which also
  poisons the terminator's instruction operands). Finally the collected instructions are pushed **in reverse**
  (DCE'ing trivially dead ones on the way), so the first instruction is popped first.

## Worklist and visiting

- `InstructionWorklist`: `push` is a stack with a set (no duplicates); `add` goes to `Deferred` (a SetVector).
  Before every pop, all deferred instructions are moved to the stack in reverse order of addition (each DCE'd
  if trivially dead), so they are visited in the order they were added. Builder-created instructions are
  `add`ed (IRBuilderInstCombineInserter); `replaceOperand`/`eraseInstFromFunction` call
  `handleUseCountDecrement` on old operands (`add` the operand, and its sole user if it now has one use).
- After a visitor returns a new instruction R for I: R gets I's debug location if it has none, `I` is RAUW'd
  with R, **R takes I's name** (so a name passed to `BinaryOperator::Create` for a returned instruction never
  matters), R is inserted at I's position (first insertion point/first non-PHI when PHI-ness differs), R's users
  and R are pushed, I is erased. If the visitor returned I (modified in place): erase if trivially dead, else
  push its users and I.
- Before visiting, an instruction whose users are all in one other block, which is a successor with a unique
  predecessor (or ends without successors), is **sunk** to that block's first insertion point
  (`tryToSinkInstruction`), and its operands are pushed.
- Instructions created through the Builder are named on insertion and the function's symbol table uniques the
  name: `udiv %X, 4096` named `%Y` becomes `%Y1 = lshr %X, 12` because `Builder.CreateLShr(..., I.getName())`
  runs while `%Y` still exists. The Negator names values `I.getName() + ".neg"` (an unnamed I gives `%.neg`).

## Analyses inside InstCombine

- InstCombine's SimplifyQuery has a **DomConditionCache**: `visitCondBrInst` registers the branch (after its own
  folds) and later queries in the same iteration use it in computeKnownBits (`computeKnownBitsFromContext`),
  isKnownToBeAPowerOfTwo, isKnownNonEqual and computeKnownFPClass. InstSimplify's pass has no DC, so the same
  ValueTracking query can answer differently in the two passes. `getWithoutDomCondCache()` is used by visitSub's
  `C - X` → `xor` fold.
- `TargetLibraryInfo`'s size_t width is the DataLayout index size of address space 0
  (`TargetLibraryInfoImpl::getSizeTSize`), so `-data-layout=p:32:32` makes `bcopy(ptr, ptr, i32)` a valid
  libfunc prototype.

## PatternMatch details that change results

- `m_Add`/`m_Sub`/… (`BinaryOp_match`) and `m_ZExt`/`m_SExt`/`m_Trunc` (`CastInst_match`) match instructions
  only; `m_PtrToInt`, `m_IntToPtr`, `m_BitCast` (`CastOperator_match`) also match constant expressions.
- `m_SpecificInt_ICMP` (and every `cst_pred_ty` matcher) allows poison vector lanes (at least one lane must be a
  real constant).
- `m_LogicalAnd/Or` match `and/or i1` and `select C, X, false` / `select C, true, X` with C of the select's type.
- **`new ICmpInst(Pred, ...)` drops samesign**: the constructor takes a plain `Predicate`; only folds that call
  `setSameSign` keep it (foldGEPICmp's nusw case, foldICmpUsingKnownBits' signed→unsigned conversion).
- **`getComplexity`**: constants 0/1 (undef 0), casts and `neg`/`not`/`fneg` patterns 2, everything else 3, so
  `icmp ult (xor X, -1), Y` is swapped to `icmp ugt Y, (xor X, -1)` (InstCombiner.h:166).
- **`ICmpInst::isCommutative()` is `isEquality()`** (used by visitICmpInst's matchSymmetricPair step), while
  `Instruction::isCommutative()` (e.g. OptimizeOverflowCheck's operand swap) never includes compares.
- **`SelectInst::Create(..., MDFrom)` copies all metadata of MDFrom**, `IRBuilder::CreateSelect(..., MDFrom)` only
  `!prof` and `!unpredictable` (foldSelectICmp and the two-selects fold in visitICmpInst use the former).
- **foldICmpUsingKnownBits runs SimplifyDemandedBits without the DomConditionCache**
  (`SQ.getWithoutDomCondCache()`); foldICmpWithDominatingICmp is the place that uses dominating branches.
- **rewriteGEPAsOffset uses a local `IRBuilder<>`**: the offset arithmetic it creates is not added to the worklist.
