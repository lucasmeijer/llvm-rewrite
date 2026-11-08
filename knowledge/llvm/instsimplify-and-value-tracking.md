# InstSimplify and ValueTracking: facts that matter for exact output

Verified against LLVM 23.1.5 source and the imported InstSimplify tests.

- **The InstSimplify pass's SimplifyQuery** has DT, AC and TLI but no DomConditionCache and no CondContext
  (`InstSimplifyPass::run`, `SimplifyQuery(DL, TLI, DT, AC)`). So computeKnownBits/computeKnownFPClass take
  context only from `llvm.assume`, and `isImpliedByDomCondition` looks only at the branch of the
  context block's *single predecessor* (`getDomPredecessorCondition`). It does not use DT at all.
  SCCP builds `SimplifyQuery(DL, &I)`, which has no DT/AC/TLI. Every `if (Q.DT)` / `if (!Q.AC)` check then takes
  its fallback.
- **`m_FNegNSZ(X)` is only `m_FSub(m_AnyZeroFP(), X)`** (PatternMatch.h:1234). An `fneg` instruction does not
  match. Check: InstSimplify/fast-math.ll `fdiv_neg_swapped2` folds `fdiv nnan %f, (fsub 0.0, %f)` to -1.0.
- **`canIgnoreSNaN(EB, FMF)` is `EB == ebIgnore || FMF.noNaNs()`** (IR/FPEnv.h:86). `fpexcept.maytrap` does *not*
  allow `fsub X, 0.0 → X`. Check: InstSimplify/strictfp-fsub.ll `*_ebmaytrap` functions keep the call.
- **`MaxLookupSearchDepth` is 10** (ValueTracking.h:51). It is the default `MaxLookup` of
  getUnderlyingObject(s), used by InstSimplify's load folding and pointer compares.
- **`m_SMax`/`m_UMin`/`m_MaxOrMin` match only the min/max intrinsics in LLVM 23**, not select+icmp patterns.
- **computeKnownFPClass of `poison`** is `fcNone` with `SignBit = false`. A `ConstantAggregateZero` is `fcPosZero`, sign
  false. Constant vectors use only the demanded, non-poison elements, and get a sign only if all of those agree.
- **`orderedStrictlyGreater(Mask)` counts leading zeros on the unmasked 32-bit value** (NaN bits included).
  `orderedStrictlyLess` strips the NaN bits first (Support/FloatingPointMode.cpp:177-213).
- **`Function::getDenormalMode(Sem)`** uses the `float:` part of `denormal_fpenv(...)` for IEEEsingle and the default
  part otherwise. Encoding of the attribute value: `default | float << 4`, each `input << 2 | output`
  (ieee 0, preservesign 1, positivezero 2, dynamic 3).
- **fcmpImpliesClass on a zero RHS** returns `{Invalid, fcAllFlags, fcAllFlags}` unless the input denormal mode is
  IEEE. With `denormal_fpenv(dynamic)` no class test is recognized (floating-point-compare.ll
  `is_olt_smallest_normal_*`).
- **ConstantFoldLoadFromConstPtr** first requires the *underlying object* to be a constant GlobalVariable with a
  definitive initializer. Only then does it strip constant offsets (non-inbounds allowed). If the stripped base
  is the global, it tries getConstantAtOffset + ConstantFoldLoadThroughBitcast, then poison for an offset past
  the alloc size, then the uniform-value fold, then FoldReinterpretLoadFromConst (byte-wise read,
  at most 32 bytes for integer loads and 128 bytes otherwise).
- **APFloat min/max family** (APFloat.h:1719-1804): minnum/maxnum quiet a signaling NaN and otherwise return
  the other operand. minimum/maximum return the quieted NaN. minimumnum/maximumnum return the non-NaN operand,
  and the quieted second operand when both are NaN. In all of them -0 < +0.

## Constants and matchers (found by the jai port's sweep: instsimplify on every round-tripping imported file)

- **`BinaryOp_match`, `BinOpPred_match`, `AnyBinaryOp_match` match only instructions** (PatternMatch.h:1157,
  1591, 1110): `m_Sub(m_Zero(), X)`, `m_Not`, `m_Shl` ... never match a constant expression. `OverflowingBinaryOp_match`
  (`m_NSWNeg`, `m_NUWAdd`, ...) and `CastOperator_match` (`m_PtrToInt`, `m_BitCast`) still do. Check:
  InstCombine/constant-fold-gep.ll `test2` keeps `gep (gep @X, 1000), sub (0, ptrtoint @X)` (the
  `gep (gep V, C), (sub 0, V) -> C` rule doesn't fire on constants).
- **`m_FPOne()` is `m_SpecificFP(1.0)`**, which uses `getSplatValue()` *without* poison (PatternMatch.h:982):
  `fmul X, <poison, 1.0>` is not simplified (InstCombine/binop-itofp.ll).
- **`Constant::isManifestConstant()` is false for undef/poison** (Constants.cpp:875): `llvm.is.constant(i32 undef)` is
  not folded (LowerConstantIntrinsics/constant-intrinsics.ll).
- **Null and splat representations** (Constants.cpp getNullValue, ConstantVector::getImpl/getSplat): the null of an FP
  vector is a vector-typed `ConstantFP`, of a pointer vector a vector `ConstantPointerNull`; `ConstantVector::get`
  of all-zero elements is `ConstantAggregateZero`. Without `-use-constant-int-for-fixed-length-splat`,
  `ConstantInt::get(<N x iK>, C)` is a ConstantDataVector (zero: CAZ); FP and byte splats are always vector-typed
  ConstantFP/ConstantByte. `dyn_cast<ConstantFP>` succeeds on a vector splat, and ConstantFoldScalarCall1 tests
  ConstantFP before its vector cases, so `llvm.x86.sse.cvttss2si(<4 x float> zeroinitializer)` is not folded
  (SLPVectorizer/X86/multi-incoming-blocks-in-phi.ll), and `frexp` of a scalable splat yields
  `{ <vscale x N x float> splat (...), i32 E }` (sic; checked with opt).
- **`Constant::getSplatValue` of a shufflevector expression** needs `shufflevector (insertelement undef|poison, X, 0),
  undef|poison, zeroinitializer` (Constants.cpp:1866); only that form prints as `splat (X)` (AsmWriter.cpp:1828).
- **ConstantFoldCompareInstruction with an undef operand** returns undef only for `icmp eq/ne` (or icmp of
  identical operands): `ICmpInst::isEquality`. `fcmp ueq undef, X` is `isUnordered` = true
  (InstSimplify/ConstProp/2008-07-07-VectorCompare.ll).
- **`Instruction::hasPoisonGeneratingAttributes`** looks only at the *call site's* return and parameter attributes
  (range, align, nonnull, nofpclass; Instruction.cpp:536); the `range(i32 -1, 2)` on the `llvm.ucmp` declaration
  doesn't count, so `x == y ? 0 : ucmp(x, y)` folds (InstCombine/select-cmp.ll).
- **`assumeBundleImpliesNonNull`** also accepts `"align"(p, A, Off)` with constant power-of-two A and `Off % A != 0`
  (BundleAttributes.cpp:84).
- **GEP strides into vectors use the element's store size** (gep_type_iterator::getSequentialElementStride):
  `gep <2 x half>, p, 0, 1` with `f16:32` is offset 2 (InstCombine/getelementptr.ll `test_overaligned_vec`).
- **`CastInst::castIsValid(BitCast)`** allows pointer <-> byte (vector) of any size and element-count-changing
  bitcasts between same-sized non-pointer vectors (Instructions.cpp), which ConstantFoldLoadThroughBitcast relies on.
- **ConstantFold of `and (ptrtoint @G), C`**: GV->getPointerAlignment; a Function counts as 4-aligned when the
  datalayout has no `F` spec (ConstantFold.cpp:803).
- **AllocaInst::getAllocationSize** is the known minimum for scalable types, so `getPointerDereferenceableBytes`
  of a scalable alloca is non-zero (InstSimplify/compare.ll alloca vscale compares).
- **Datalayout pointer specs take flags** `p[e][u][z|o]<as>:...` (DataLayout.cpp parsePointerSpec);
  isNonIntegralAddressSpace = size != index size || unstable || external state; mustNotIntroduceIntToPtr =
  unstable || external; mustNotIntroducePtrToInt = unstable.
- **The oracle has no `HAS_LOGF128`**: `log`/`logl` on fp128 are never folded. Math libcalls are folded with the
  host libm (the oracle links the system libm.so.6), rejected on errno ERANGE/EDOM or any fenv exception but
  FE_INEXACT.
- **`findScalarElement(V, unsigned)`** gets `getZExtValue()` truncated to 32 bits.
