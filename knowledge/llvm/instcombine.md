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
  **`InstCombiner::addToWorklist(I)` is `Worklist.push(I)`**, not `add`: addDeadEdge's phis, handleUnreachableFrom's
  poisoned terminator operands, the dominated-condition users in visitBranchInst, DCE'd old extracts and the like
  go straight onto the stack. Only `InsertNewInstBefore`, the IRBuilder inserter and explicit `Worklist.add` defer.
  Deferring changes which fold erases a phi first (a `#dbg_value(i8 0)` instead of `poison` after a store to
  poison; LoopVectorize/predicatedinst-loop-invariant.ll under debugify).
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
- **`m_ConstantInt(uint64_t &)` matches splats** (`bind_const_intval_ty` goes through `m_APInt`, no poison lanes,
  value must fit in 64 bits); `m_ConstantInt()` / `m_ConstantInt(ConstantInt *&)` match only a ConstantInt.
  Verified by shift-sub.ll `shl_sub_vec_splat` (`shl C, (sub nuw 4, X)` on `<2 x i8>` folds) (PatternMatch.h:1000).
- **`m_SpecificInt(V)` rejects splats with poison lanes** (`specific_intval<false>` uses `getSplatValue(false)`);
  only `m_SpecificIntAllowPoison` accepts them. shl-sub.ll `shl_sub_i64_vec_poison_bad2` must not fold.
- **`m_SMax`/`m_SMin`/`m_UMax`/`m_UMin` (MaxMin_match) also match `select (icmp pred A, B), A, B`** forms, not only
  the intrinsics (FoldOrOfSelectSmaxToAbs uses this).
- **Commuted matchers commit to the first operand order whose sub-pattern matches**: in
  `m_c_And(m_Value(A), m_Not(m_Value(B)))` the `not` is looked for in operand 1 first; once an order matched, a
  failing later matcher (`m_Specific`, `m_Deferred` in a sibling pattern) does not retry the other order. The
  `m_Not`-first forms (`m_c_And(m_Not(X), m_Value(Y))`) look in operand 0 first. Getting the order wrong changes
  which value is called `A`.
- **IRBuilder `CreateIsNeg`/`CreateIsNotNeg` name the icmp only when the caller passes a name** (`"isneg"` in
  visitAnd/foldNot/visitLShr, unnamed in foldAndOrOfICmps' and foldXorOfICmps' sign tests).
- **`Constant::mergeUndefsWith` produces `undef` lanes (not poison)**, so
  `or (shl X, <15,13>), (lshr Y, <poison,19>)` becomes `fshl(..., <i32 undef, i32 13>)` in visitOr; the `0` that
  LLVM finally prints comes from the call visitor (funnel.ll `fshr_v2i32_constant_nonsplat_poison0`).
- **`icmp ne (and (lshr X, C), 1), 0` becomes `trunc (lshr X, C) to i1` in visitICmp**, and visitTrunc then turns
  that into `icmp ne (and X, 1 << C), 0`; without the trunc visitor the result stays a trunc (shift.ll test16).
- **matchBSwapOrBitReverse** (visitOr) inserts the new trunc/bswap/and/zext before the `or` with the names
  `trunc`, `rev`, `mask`, `zext`, pushes all but the last onto the worklist and returns the last one unlinked
  (`removeFromParent`), which then takes the `or`'s name.

## Select

- `CondContext` (SimplifyQuery.h): visitSelectInst injects the select condition (inverted for the false arm) when
  computing known bits of the arms; every phi recursion in ValueTracking uses `Q.getWithoutCondContext()`
  (computeKnownBits, isKnownToBeAPowerOfTwo, isKnownNonZero, ComputeNumSignBits, computeKnownFPClass phis, isKnownNonEqual
  of phis). Keeping it at phis folds `select c, x, (shl ...)` wrongly (InstCombine/pr100298.ll).
- `ICmpInst::isLT/isGT` are the *strict* predicates only (foldSelectWithExtremeEqCond, foldSelectToCmp).
- `Operator::hasPoisonGeneratingFlags` is true for ctlz/cttz/abs with the `i1 true` flag, so foldSelectValueEquivalence
  (`x == 0 ? 16 : ctlz(x, true)`) clears the flag via DropFlags.
- `IRBuilder::CreateMaskedLoad` adds a call-site `align` parameter attribute to the pointer (from
  `getParamAlign(0).valueOrOne()` of the old call).
- `Constant::isElementWiseEqual(Y)` is false unless Y is a constant of the same *vector* type (scalars only match by
  identity).

- **`IRBuilder::Insert(I, Name = "")` renames I to the given name**: the Negator's `select c, -x, x` case clones the
  select, `setName(I.getName() + ".neg")`, then `Builder.Insert(NewSelect)` renames it to "", so the result is
  unnamed (sub-of-negatible.ll `negate_select_of_op_vs_negated_op`; IRBuilderDefaultInserter::InsertHelper).
- **`Constant::containsUndefElement` excludes poison** (Constants.cpp: `isa<UndefValue> && !isa<PoisonValue>`), so
  `isGuaranteedNotToBeUndef(<i8 2, i8 poison>)` is true and foldSelectValueEquivalence replaces the arm with
  `<i8 2, i8 poison>` (select.ll `select_replacement_add_eq_vec_poison`).
- `simplifyWithOpReplaced(..., AllowRefinement=false, &DropFlags)` (foldSelectValueEquivalence) folds constant
  operands even for instructions that can create poison (`canCreatePoison(I, !DropFlags)` ignores flags), clears the
  `i1` flag of abs/ctlz/cttz before folding, and the select fold then drops the poison-generating annotations of
  every instruction recorded; the vector keeps entries from the first (failed) substitution attempt.
- foldBinOpOfSelectAndCastOfSelectCondition: the true arm gets `CastTrueVal` (`NewFoldedConst(false, TrueVal)`
  picks `IsTrueArm ? CastFalseVal : CastTrueVal`); binop-select.ll `commonArgWithAdd0` → `select c, 22, 61`.
- matchSymmetricPhiNodesPair accepts any number of incoming values: every pair (Lk, Rk) must be (L0, R0) or
  (R0, L0) (commutative-operation-over-phis.ll `fold_phi_mul_three`).
- visitSelectInst's matchSelectPattern call passes a CastOp, so min/max through casts (lookThroughCast) are
  canonicalized; `SelectPatternResult::Ordered` decides `fcmp olt` vs `ult` of the new compare.
- visitPHINode's `PredOrder` (block order of the first PHI seen per block) lives in the InstCombinerImpl, i.e. it is
  rebuilt every iteration; later PHIs of the block are permuted to that order without returning "changed".
- SliceUpIllegalIntegerPHI creates its element PHIs with `PHINode::Create(..., InsertBefore)` (not
  InsertNewInstBefore), so they are not added to the worklist.

## Casts and calls

- **InstVisitor sends `llvm.va_end` to `visitVAEndInst`, not `visitCallInst`** (InstVisitor::visitCall delegates by
  intrinsic id; InstCombine only overrides visitVAEndInst), so a va_end never gets the nounwind inference or
  visitCallBase. Every other intrinsic reaches visitCallInst.
- **Target intrinsic folds depend on the module triple**: `TTI.instCombineIntrinsic`, `simplifyDemandedUseBits-
  Intrinsic` and `simplifyDemandedVectorEltsIntrinsic` are X86TTIImpl's only when the triple is x86; without a
  triple an `llvm.x86.*` call is left alone (InstCombine/X86 tests all set `target triple`).
- **`m_UMin/m_SMin/m_SMax` in visitTrunc match the select form too**, binding the select's true value to the first
  sub-pattern (MaxMin_match), so `trunc (select (icmp ult (add zext, zext), 255), add, 255)` becomes uadd.sat.
- **TypeEvaluationHelper (canEvaluateTruncated/SExtd) accepts multi-use values** if every user of each multi-use value
  was visited by the same query (the Pending list); a select *condition* use of a multi-use value rejects it.
  canEvaluateZExtd keeps the one-use rule.
- **`CallInst::Create(II->getCalledFunction(), Args)` drops call-site attributes, metadata and flags**: e.g.
  `ctlz(x, false)` → `ctlz(x, true)` loses a `range` return attribute and fast-math flags; foldCttzCtlz then adds a
  fresh `range` attribute on the next visit.
- **foldCtpop/foldCttzCtlz add a `range(iN lo, hi)` return attribute** computed from known bits (and isKnownNonZero
  for ctpop), so many ctpop/cttz/ctlz calls in `-passes=instcombine` output carry `range` attributes.

- **InstCombine's builder never folds a vector-typed intrinsic call**: TargetFolder::FoldIntrinsic is
  ConstantFoldIntrinsic = ConstantFoldScalarCall only (ConstantFolding.cpp, ConstantFoldIntrinsic), so
  `CreateIntrinsic(sadd.sat, <8 x i16> C1, C2)` makes a call that InstCombine folds when it visits it, leaving the
  `declare @llvm.sadd.sat.v8i16` behind (InstCombine/X86/x86-pmaddubsw.ll). Scalar calls fold in the builder.
- **IRBuilder::CreateCast gives FP-math casts the builder's fast-math flags** (`setFPAttrs` when
  `isa<FPMathOperator>`: fptrunc, fpext, uitofp, sitofp), so optimizeLog's `B.CreateSIToFP` under a
  FastMathFlagGuard prints `sitofp fast i32 %y to double` (InstCombine/log-pow.ll).
- X86 target-intrinsic folds (X86TTIImpl::instCombineIntrinsic) only run when the module has an x86 triple; most
  InstCombine/X86 tests get it from `-mtriple` on the RUN line, so a per-function sweep without that flag never
  reaches them.

## Compares (InstCombineCompares.cpp)

Verified by porting the file and diffing `opt -passes=instcombine` per function (llvm-extract) on the imported
icmp*/fcmp* tests.

- `new ICmpInst(CmpPredicate, ...)` keeps only the predicate: samesign is dropped (the constructor takes a
  `Predicate`). `new FCmpInst(P, L, R, "", &I)` copies `I`'s fast-math flags; the 3-argument form has none.
- `ICmpInst::swapOperands` (operand-complexity canonicalization at the top of visitICmp/visitFCmp) is
  `Op<0>().swap(Op<1>())`, i.e. `Use::swap`: the two uses trade values *and use-list positions*. Re-setting the
  operands instead pushes both uses to the heads of their lists and changes later user-iteration order.
  The same holds for `BinaryOperator::swapOperands` (SimplifyAssociativeOrCommutative, Reassociate's
  canonicalizeOperands) and `ShuffleVectorInst::commute`: use-list order is hidden state that a later pass in the
  same opt run sees (sieve.ll: reassociate then loop-rotate built an extra phi when the use order differed).
- `isSignTest(Pred, C)` takes `Pred` by reference and rewrites `slt 1` → `sle`, `sgt -1` → `sge` whenever it
  returns true, even if the caller's other condition then fails: in foldICmpMulConstant
  `isSignTest(Pred, C) && Mul->hasNoSignedWrap()` leaves the updated predicate for the folds below
  (icmp.ll `@icmp_mul_nsw_neg`: `mul nsw x, -12 sge 0` → `x slt 1`).
- Queries made *without* the DomConditionCache: foldICmpUsingKnownBits' SimplifyDemandedBits
  (`SQ.getWithoutDomCondCache()`), foldCtpopPow2Test's computeKnownBits(Op, DL, AC, CxtI, DT), and isMaskOrZero's
  isKnownToBeAPowerOfTwo(V, DL, ...). Everything else uses the InstCombiner's query, which has the cache.
- Several simplifyICmpInst calls use the InstCombiner's `SQ` without a context instruction (foldSelectICmp, the
  `icmp (select C, A, B), (select C, C', D)` fold); the top-level one uses `SQ.getWithInstruction(&I)`.
- SimplifyDemandedBits on a pointer-typed operand (foldICmpUsingKnownBits with pointer icmps) works on
  pointer-size bits, adds the pointer's known alignment as low zero bits, and never replaces a pointer by a
  constant in SimplifyDemandedUseBits (it does in the multiple-use path: `inttoptr` of the constant).
- The "used only by a min/max select" bail-outs call matchSelectPattern on the user select; for an fcmp
  condition that is the FP flavour logic (signed-zero and NaN checks, matchFastFloatClamp), not "unknown".

## And/Or/Xor and matcher facts (verified by the goose port's per-function sweep)

- **`m_ConstantInt(uint64_t &V)` matches splat vectors** (bind_const_intval_ty uses `ap_match`, then
  `tryZExtValue`), unlike `m_ConstantInt(ConstantInt *&)` and `m_ConstantInt()`, which are scalar-only. Example:
  `shl <2 x i8> splat (i8 3), (sub nuw splat (i8 4), %x)` becomes `lshr exact splat (i8 48), %x`
  (shift-sub.ll @shl_sub_vec_splat; PatternMatch.h bind_const_intval_ty).
- **`m_Power2(const APInt *&)`, `m_NegatedPower2`, `m_LowBitMask` (api_pred_ty) accept splats with poison lanes**
  (`getSplatValue(/*AllowPoison=*/true)`), while `m_APInt` does not (signed-truncation-check.ll
  @positive_vec_poison1).
- **`fcmpToClassTest` looks through fabs by default**: both overloads default `LookThroughSrc = true`, and the
  `Value *RHS` one even forces it (FloatingPointPredicateUtils.h:43-46); the `Value *` overload matches the RHS
  with `m_APFloatAllowPoison`.
- **`Constant::mergeUndefsWith(C, Other)` inserts `undef`, never poison**, in the lanes where Other is undef or
  poison (xor-of-or.ll @t8: `and <2 x i4> %x, <i4 3, i4 undef>`).
- **`Constant::isElementWiseEqual` is true when the elementwise `icmp eq` folds to poison** (and-sub-combine.ll
  @and_sub_vec_posion folds to `ret poison`).
- **`annotateAnyAllocSite` runs for every call** with a pointer result: an `allocalign` constant argument raises the
  call's return `align` even for functions that are not allocation functions (InferAlignAttribute.ll).
- matchBSwapOrBitReverse: recognizeBSwapOrBitReverseIdiom inserts `trunc`/`rev`/`mask`/`zext` (named so, uniqued
  while I still exists) before I; the last one is removed from the block and returned, so it takes I's name.
- foldAndOrOfICmpsWithPow2AndWithZero calls the `isKnownToBeAPowerOfTwo(V, DL, ...)` overload, which has no
  DomConditionCache; the other isKnownToBeAPowerOfTwo calls of the file use the SimplifyQuery (with it).

## Memory, GEPs, vector ops

- **LLVM 23's AllocationFnData has no malloc/calloc/realloc/aligned_alloc**: only operator new/new[] (Itanium and
  MSVC) and strdup/strndup. malloc-like functions are recognized only through `allockind(...)`/`allocsize`
  attributes (and `"alloc-family"` for getAllocationFamily); a bare `declare ptr @malloc(i64)` is not an allocation
  function for isAllocSiteRemovable (MemoryBuiltins.cpp AllocationFnData).
- `free` is still a TLI LibFunc: getFreedOperand returns its argument 0 when the declaration has `allockind("free")`
  even without `allocptr` (isLibFreeFunction falls back to checkFnAllocKind on the Function).
- TLI prototypes use size_t = DataLayout index width of address space 0: with `p:32:32:32`, `aligned_alloc(i32,
  i32)` is the libfunc and visitAllocSite keeps `icmp ne (aligned_alloc 3, 32), null` (invalid alignment) unfolded
  (InstCombine/malloc-free.ll).
- `Value::takeName` on a Constant does nothing (getSymTab fails) and the source keeps its name
  (OptimizeOverflowCheck's `Result->takeName(&OrigI)` when Result constant-folded; InstCombine/with_overflow.ll).
- `CommonPointerBase::LHSNW/RHSNW` start as `GEPNoWrapFlags::all()`: `p - gep inbounds p, A` becomes
  `sub nsw 0, A` (InstCombine/sub-gep.ll test24a).
- `Instruction::isAssociative()`: FMul needs only `reassoc`, FAdd needs `reassoc nsz` (foldVectorBinop's splat
  reassociation, InstCombine/vec_shuffle.ll splat_assoc_fmul).
- `m_ZeroMask` accepts poison lanes, including an all-poison mask (VectorUtils getSplatValue, simplifyBinOpSplats).
- `lowerObjectSizeCall`: only the instructions created by its own final builder (sub, icmp ult, zext/trunc,
  select, icmp ne + assume) are added to the worklist by visitCallInst/visitAllocSite; ObjectSizeOffsetEvaluator's
  own instructions are not (InstCombine/builtin-dynamic-object-size.ll phis_are_neat needs the former to reach a
  fixpoint).
- `Value::getPointerDereferenceableBytes` reports CanBeFreed only when `-use-dereferenceable-at-point-semantics`
  (default true in 23.1.5) and the value is not an alloca/global; isDereferenceableAndAlignedPointer then needs
  willNotFreeBetween(def, CxtI) (max 32 instructions, through single-predecessor chains).
- visitAllocSite of an `invoke` allocation creates `invoke void @llvm.donothing()` to the same destinations at the
  end of the block before erasing the original (InstCombine/invoke.ll).
- `combineLoadToOperationType` uses `CastUser->replaceAllUsesWith(NewLoad)` (no worklist push of the users), then
  erases the cast and returns the old load (which then dies as trivially dead).

- **LLVM 23 null vectors of FP elements are `ConstantFP`, null vectors of pointers `ConstantPointerNull`**
  (`Constant::getNullValue`, Constants.cpp:384), so `isa<ConstantAggregateZero>` is false for a parsed
  `<4 x float> zeroinitializer`: collectShuffleElements then takes the identity-mask fallback and
  `insertelement <4 x float> zeroinitializer, (extractelement <2 x float> %v, 0), 0` becomes
  `shufflevector %wide, <poison, 0.0, 0.0, 0.0>, <0, 5, 6, 7>` (InstCombine/insert-element-shuffle-vector-debugloc.ll).
- `FoldOpIntoSelect(Op, SI, FoldWithMultiUse = false, SimplifyBothArms = false)`: visitExtractValueInst,
  visitExtractElementInst and visitShuffleVectorInst fold through a select when only one arm simplifies
  (InstCombine/extract-select-agg.ll).
- **`InstCombiner::ComputeNumSignBits` / `ComputeMaxSignificantBits` build a query without the DomConditionCache**
  (InstCombiner.h:491), while computeKnownBits / MaskedValueIsZero use SQ with it: under `br (icmp ult %x, 8)` a
  `trunc i32 %x to i16` gets `nuw` but not `nsw`. ValueTracking's own computeOverflowForSigned* call
  `::ComputeNumSignBits(V, SQ)` and do see the DC (ValueTracking.cpp:7523).
- **TargetFolder::FoldGEP never folds a GEP whose source element type is scalable** (`isSupportedGetElementPtr`),
  even over a constant base: the GEP instruction is then canonicalized with `llvm.vscale` (the declaration stays
  in the module even when the code dies; GlobalOpt/2022-08-23-ScalableVectorArrayCrash.ll). EmitGEPOffset and
  unpackLoad/StoreToAggregate use `CreateTypeSize` = `mul nuw (vscale), MinSize`, which instcombine turns into
  `shl nuw`.
- **`ni:<AS>` address spaces get HasUnstableRepresentation** (DataLayout.cpp:705): mustNotIntroduceIntToPtr is
  true for them, so `gep i8, ptr addrspace(4) null, i64 50` is not folded to `inttoptr` and a store of `i64 5`
  is not forwarded to a `ptr addrspace(4)` load (isBitOrNoopPointerCastable / FoldReinterpretLoadFromConst refuse
  non-integral pointers).
- `MemoryLocation::getForDest(CallBase)` looks at `getMemoryEffects() & writeOnly()` only: a call with
  `memory(read, argmem: readwrite)` whose only written pointer is an unescaped alloca is a removable write, so
  visitAllocSite deletes both (DeadStoreElimination/trivial-dse-calls.ll).
- `handleUnreachableFrom(I)` erases `[I, terminator)`: started at the terminator (a `store ..., ptr undef` right
  before `ret`) it erases nothing and the store stays as the unreachable marker (InstCombine/store.ll).
- `Value::getPointerDereferenceableBytes` of a `dereferenceable(N)` argument reports CanBeNull = false even in a
  `null_pointer_is_valid` function, so computePointerICmp folds `icmp eq %p, %alloca` to false
  (InstSimplify/compare.ll icmp_eq_arg_derefable_null_valid_and_alloca).

## Facts found by the per-function sweep (jai, 2026-11)

- **canRewriteGEPAsOffset's "PHI node users" check never fires**: it iterates `Val->uses()` and converts each `Use`
  to `Value*`, which is the used value itself, so `PHI` is null or equal to `Inst` and the loop always `continue`s
  (InstCombineCompares.cpp:467). `icmp eq ptr %iv, (gep %start, 2)` with `%iv` a GEP/phi recurrence over `%start`
  is rewritten to an index compare even when the phi and its GEP are in the same block.
- `m_SpecificInt(const APInt &)` compares with `APInt::isSameValue` (different bit widths are fine), so
  `trunc(umin(zext a + zext b, 255))` matches an i16 255 against `APInt::getMaxValue(8)` (InstCombineCasts.cpp:1157).
- FindAvailableLoadedValue's memset case compares `(Len * 8).ult(LoadSize + Off * 8)` with the right side as a
  `uint64_t`, not truncated to Len's width (an `i8 127` memset: 127*8 wraps to 248 in i8, which is < 1024).
- `CallBase::getParamDereferenceableBytes` reads the call site's attributes only (unlike `paramHasAttr`, which
  falls back to the callee): visitCallBase infers `nonnull` on an argument of a call to a function whose parameter
  is `dereferenceable` but not `nonnull`.
- foldBinopWithRecurrence's OverflowTracking has AllKnownNonNegative = AllKnownNonZero = false: an `add` keeps
  `nuw` only if all three ops have it and `nsw` only together with `nuw`; a `mul` gets no flags.
- `dyn_cast<ConstantFP>` succeeds on a vector splat FP constant, so `powi(<4 x float> splat 2.0, i)` with `afn`
  becomes `ldexp(splat 1.0, splat i)` (visitCallInst powi).
- SimplifyDemandedFPClass runs from visitReturnInst (functions with a `nofpclass` return) and at the very end of
  visitFMul (SimplifyDemandedInstructionFPClass on every fmul): it infers `nnan`/`ninf` and folds fmuls whose
  operand classes are known.

## Floating point (InstCombineAddSub/MulDivRem FP halves, SimplifyDemandedFPClass)

Verified by the goose port (per-function sweep of the imported InstCombine tests and tools/fuzz_ic_fp.py).

- **visitFMul ends with `SimplifyDemandedInstructionFPClass(I)`** (all classes demanded), so every fmul that no
  other fold changed goes through SimplifyDemandedUseFPClass; the only other caller is visitReturnInst with
  `~nofpclass(...)` of the return. Results there can change fast-math flags (`inferFastMathValueFlags` adds
  nnan/ninf when the operands' known classes allow).
- `Instruction::isAssociative()` is FMF-dependent: fmul needs `reassoc`, fadd `reassoc nsz`; this gates
  SimplifyAssociativeOrCommutative's reassociation and foldBinopWithRecurrence for FP ops.
- `m_FNeg` matches `fneg X`, `fsub -0.0, X`, and `fsub nsz 0.0, X` (any zero with nsz); getComplexity uses it.
- `IRBuilder<> B(&I)` inside foldFDivConstantDivisor (nnan `X / 0.0` -> `copysign(inf, X)`) has a ConstantFolder,
  which never folds intrinsics, and its new call is not put on the worklist.
- FMaxMin_match (m_OrdOrUnordFMax/Min, select -> maxnum/minnum) binds the fcmp's operands (not the select arms)
  and, when the arms are reversed, tests the *inverse* predicate: `select (fcmp ole a, c), c, a` -> `maxnum(a, c)`
  (InstCombine/unordered-fcmp-select.ll, minmax-fp.ll).
- `Instruction::dropUBImplyingAttrsAndMetadata` keeps !annotation, !range, !nonnull, !align, !fpmath, !prof,
  !DIAssignID and the debug location; on calls it drops noundef/dereferenceable/dereferenceable_or_null from the
  return and every argument.
- computeKnownFPClass of a ConstantDataSequential / ConstantArray / ConstantStruct (not a vector) is the union of
  the element classes with unknown sign; any non-ConstantFP element makes it unknown (nofpclass returns of
  `{float, float}` constants, simplify-demanded-fpclass-aggregates.ll).
- FAddCombine (`reassoc nsz` fadd/fsub, scalars only) gives the instructions it creates the original instruction's
  fast-math flags and debug location after the Builder created them with its own (empty) flags.
- **visitCallInst order**: simplifyCall (only if used) → getFreedOperand/visitFree (returns its result, never
  reaches visitCallBase) → caller-nounwind inference (returns) → non-intrinsics go to visitCallBase; intrinsics:
  mem-intrinsic prologue, fixed-vector SimplifyDemandedVectorElts, commutative symmetric pairs /
  canonicalizeConstantArg0ToArg1, the switch, then fold into select/phi, shuffled/reversed operands, idempotent
  recurrences, and finally visitCallBase too.
- `IRBuilder::CreateUnaryIntrinsic/CreateBinaryIntrinsic` call getOrInsertDeclaration before trying to fold, so a
  folded call still leaves its `declare` behind; `CreateIntrinsic(ID, Types, ...)`/`(RetTy, ID, ...)` fold first.
- X86 intrinsics reach X86TTIImpl only with an x86 module triple; without a triple (NoTTIImpl) nothing happens.
  SimplifyDemandedVectorElts' x86 hook (scalar ss/sd ops, pack, pmadd, pshufb/vpermilvar operand 1, sse4a) covers far
  more sweep functions than instCombineIntrinsic itself.
- `IRBuilder::CreateUnaryIntrinsic` / `CreateBinaryIntrinsic` call `getOrInsertDeclaration` *before* trying to
  fold, so a folded call still leaves the declaration (`declare i32 @llvm.sadd.sat.i32` in
  InstCombine/ldexp.ll); `CreateIntrinsic` folds first and declares only if it emits a call.
- `MemIntrinsicBase::getDest()` strips pointer casts (including `addrspacecast`): memset->store stores through
  the stripped pointer (`store i64 0, ptr addrspace(1) @g8`), while memcpy->load/store uses the raw operands.
- `m_SplatMask` is `all_equal(Mask)`: a mask with poison elements (`<poison, 1, 1>`) is not a splat for
  shrinkSplatShuffle (InstCombine/trunc.ll wide_splat3). `AttributeSet::getVScaleRangeMin()` is 1 without a
  `vscale_range` attribute. `APFloat::hasSignBitInMSB` is true for ppc_fp128 too.
- `DataLayout::getTypeAllocSize` of an array is `N * getTypeAllocSize(elt)` in bytes; computing it through bits
  wraps for `[2^63 x i8]` (LowerConstantIntrinsics/objectsize_basic.ll large_alloca).

## Visitors InstCombine doesn't have (verified by impl/goose -O2 sweeps)

- InstCombinerImpl has no visitor for resume, catchswitch, catchpad, cleanuppad, catchret, cleanupret, indirectbr,
  cmpxchg or va_arg: InstVisitor falls back to visitInstruction, which returns nullptr (only the generic worklist
  DCE / constant folding applies). atomicrmw has visitAtomicRMWInst (InstCombineAtomicRMW.cpp).
- The prepare-worklist AliasScopeTracker erases an `llvm.experimental.noalias.scope.decl` whose scope is not used by
  both some `!alias.scope` and some `!noalias` list of the reachable instructions (walked in RPO before the reverse
  push).
- SoleWriteToDeadLocal lets tryToSinkInstruction sink a call that writes only to an alloca (getForDest) whose users
  are, through GEPs and addrspacecasts, only that call.

## Smaller facts (verified with impl/jai, InstCombine tests listed)

- `!annotation` is copied by the IRBuilder inserter onto every instruction created while visiting I
  (`copyMetadata(*AnnotationMetadataSource, MD_annotation)`) and onto the result that replaces I (annotations.ll,
  new-inst-dbgloc-overwrite.ll).
- PSI/BFI: InstCombinePass::run takes `PSI = getCachedResult<ProfileSummaryAnalysis>` and computes BFI *before* the
  combine loop when PSI has a summary; LibCallSimplifier's shouldOptimizeForSize(BB) uses them (fputs-opt-size.ll).
  LoopUnrollPass and LoopLoadElimination do the same before simplifying loops; unroll pragmas override PGSO
  (`hasUnrollTransformation(L) != TM_ForcedByUser && shouldOptimizeForSize(...)`), and a huge working set turns peeling
  off. LoopFullUnrollPass passes null PSI/BFI.
- transformCallThroughTrampoline: with a `nest` parameter the new call is `CallInst::Create(NewFTy, NestF, ...)`
  (tail kind, cc, attributes with the nest attribute spliced in, debug location only); without one the call's
  callee is just replaced (`setCalledFunction(FTy, NestF)`).
- gc.statepoint: the relocates are the statepoint's users then its landing pad's; dead relocates are erased,
  undef/null derived pointers fold, `nonnull` is added; the `gc-live` bundle is shrunk to the live values with
  `CallBase::Create(&Call, NewBundle)` (other bundles first, gc-live last) and the relocate indices rewritten.
- ptrauth: `auth(sign(p,k,d),k,d) -> p` and the resign combinations, `auth(ptrtoint(ptrauth const))` via
  `isKnownCompatibleWith`; a call through `inttoptr(ptrauth.sign/resign)` or a `ptrauth` constant with a matching
  `"ptrauth"` bundle becomes a direct call (`CallBase::Create(CI, Bundles)`: no metadata but the debug location).
  `load/store` through `llvm.protected.field.ptr` become `ptrauth.auth/sign` with key 2 (AArch64 DA) even on x86.
- `-instcombine-verify-known-bits` aborts on a mismatch only; `-instcombine-code-sinking=0` disables
  getOptionalSinkBlockForInst; `-disable-i2p-p2i-opt` is CastInst::isEliminableCastPair's case 7.
- foldPHIArgOpIntoPHI checks every incoming value with the full `Instruction::isSameOperationAs`
  (haveSameSpecialState: cmp predicates, GEP source types, load/store attributes, ...), so a phi of `icmp ne %x, 0`
  and `icmp eq %z, 0` is not folded (tests/pass/instcombine/phi-of-cmps-different-predicates.ll; ConstraintElimination/
  and-implied-by-operands.ll at -O2). foldSelectOpOp uses the same check.
- `Value::setName` on a constant is a no-op (getSymTab fails): unpackLoadToAggregate of a `[0 x T]`/`{}` load
  replaces it with `poison` and the `V->setName(Name)` does nothing.
- CastGEPIndices (ConstantFolding.cpp) keeps the GEP's inrange when it rewrites the indices, so
  `getelementptr inrange(0, 16) ({...}, ptr @g, i32 0, i32 0, i32 0)` folds to `getelementptr inbounds nuw
  inrange(0, 16) (i8, ptr @g, i64 0)`, not to `@g` (GlobalSplit/*.ll under instcombine).
