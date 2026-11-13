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
  Every getUnderlyingObject call without an explicit MaxLookup uses it: InlineFunction's
  AddParamAndFnBasicAttributes (a chain of 7 launder/strip.invariant.group calls back to the argument still gets the
  callee's `readnone`, Inline/launder.invariant.group.ll with `inline,function-attrs`), InstCombine's icmp/alloca
  and call folds, AggressiveInstCombine, LoopIdiomRecognize's store grouping, getConstantDataArrayInfo,
  FunctionSpecialization. (Goose had 6, LLVM 22's value, at 10 call sites.)
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
  (SLPVectorizer/X86/multi-incoming-blocks-in-phi.ll), nor is it with any FP splat such as `splat (float 2.0)`;
  an explicit `<float 0.0, float 0.0, …>` *is* folded, because ConstantVector::get makes all-null elements a
  ConstantAggregateZero, not a ConstantFP (both print `zeroinitializer`). The AVX-512 variants need
  `isa<ConstantVector/ConstantDataVector>`, so they never fold a splat or zero vector. And `frexp` of a scalable splat yields
  `{ <vscale x N x float> splat (...), i32 E }` (sic; checked with opt).
- **Vector-typed ConstantInt splats** (`-use-constant-int-for-fixed-length-splat`, `-use-constant-int-for-scalable-splat`,
  Constants.cpp:39; both default false). LLVM 23 has *no* `-use-constant-fp-for-*-splat` options: FP splats are
  always vector-typed ConstantFP and `opt` rejects those flags as unknown. With the int flags, ConstantVector::getImpl
  and getSplat return `ConstantInt::get(Ctx, EC, V)` (a ConstantInt whose type is the vector) for a splat of one
  non-zero ConstantInt of any width (i1, i128 too); zero stays ConstantAggregateZero ("maintain special handling of
  zero"), ConstantDataVector::get is never called directly by the middle end, so no integer CDV splat exists in that
  mode. Printing is unchanged (`splat (i32 1)` either way, AsmWriter.cpp:1766). Every `isa<ConstantInt>`,
  `dyn_cast<ConstantInt>`, `m_ConstantInt` then also matches vector splats, and getAggregateElement/getSplatValue
  give the scalar ConstantInt. LLVM's output differs between the two modes in only a few corpus tests, and those
  are exactly such sites: InstCombine/or.ll `test30vec` (visitOr's `(X|C) | V --> (X|V) | C` uses m_ConstantInt),
  exact.ll, SCCP/overdefined-ext.ll (getConstantInt of a select condition), Reassociate/fast-ReassociateVector.ll
  (`shl X, C` -> `mul` needs isa<ConstantInt>), load-store-forward.ll (scalable). Checked by sweeping the whole
  corpus with both flags through instsimplify/instcombine/sccp/gvn/reassociate against opt (goose, 2026-11-09).
  Not every site follows: GEPOperator::accumulateConstantOffset tests `getType()->isIntegerTy()` and so rejects a
  vector ConstantInt index.
- **ConstantFoldFixedVectorCall `vector.insert` folds only at index 0**: elements below the index are read with
  `SubVec->getAggregateElement(I - IdxN)` in `unsigned`, which wraps to a huge index (null), so any non-zero index
  returns null (ConstantFolding.cpp:4396). ConstantFoldScalableVectorCall folds trivially-vectorizable intrinsics
  only when every vector operand has a getSplatValue, and returns a splat.
- **ppc_fp128 is a DoubleAPFloat** (APFloat.cpp:4657 on): two doubles (Hi = the APInt's low word, Lo = the high
  word), `semPPCDoubleDouble = {-1, 0, 0, 128}` (no IEEE parameters). Category and sign are Hi's; `isDenormal` is
  `normal && (Hi.isDenormal() || Lo.isDenormal() || Hi != Hi + Lo)`; `isInteger` needs both parts integral;
  `getExactLog2Abs` needs Lo == 0; `compare` compares Hi then Lo; `scalbn` scales both parts; `ilogb` is Hi's, minus
  one for `2^a - 2^b` shapes. add/multiply are custom double-double algorithms, while divide, remainder, mod,
  fusedMultiplyAdd, toString and convertToHexString go through `semPPCDoubleDoubleLegacy = {1023, -969, 106, 128}`
  (an IEEE-like 106-bit format: Hi+Lo rounded). So a port needs both a double-double and a 106-bit IEEE path; a
  "decompose as one IEEE number" shortcut gets denormals, isInteger and next() wrong. More traps: `APFloat::convert`
  from ppc_fp128 to another format converts only Hi; to ppc_fp128 it rounds to the legacy format and splits
  (convertPPCDoubleDoubleLegacyAPFloatToAPInt, renormalizing against double's minExponent first); add with a zero
  operand returns the *other* operand unchanged (so +0 + -0 = -0), and multiply by zero/inf returns that operand
  without combining signs; convertFromAPInt is its own Hi/Error algorithm, not legacy rounding. Goose fails loudly;
  Jai ports all of it (impl/jai/src/apfloat_dd.jai).
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
- **`findScalarElement(V, unsigned)`** gets `getZExtValue()` truncated to 32 bits. Through an `add` it needs only
  the *demanded element* of the constant operand to be null (`m_Add(m_Value(Val), m_Constant(C))`,
  `C->getAggregateElement(EltNo)->isNullValue()`), so `extractelement (add (splat %x), <0, 1, 2, 3>), 0` is `%x`
  (InstCombine/extractelement.ll); out-of-range elements are poison, not undef (VectorUtils.cpp:306).
- **InstSimplify's cast-pair fold uses the DataLayout** (`isEliminableCastPair(..., &Q.DL)`, as does
  ConstantFoldCastOperand): `inttoptr (ptrtoint P)` folds to P when the integer is at least pointer-sized
  (case 7), `ptrtoint (inttoptr X)` to a trunc/zext/bitcast of X (case 11). ConstantFold.cpp (no DL) passes
  nullptr and keeps them (InstCombine/IntPtrCast.ll, phi-int2ptr-fold.ll under instsimplify).
- **InstSimplifyPass tests deadness without a TLI** (`isInstructionTriviallyDead(&I)`), so an unused
  `call double @exp(double 100.0)` is kept; only RecursivelyDeleteTriviallyDeadInstructions (with TLI) erases
  operands that become dead (EarlyCSE/math-1.ll under instsimplify). DCE and EarlyCSE pass the TLI.
- **`isAssumeWithEmptyBundle`**: an `llvm.assume(i1 true)` whose bundles are all `"ignore"` is trivially dead
  (Local.cpp:498, AssumeBundleQueries.cpp:113).
- **`CallBase::paramHasNonNullAttr(ArgNo, AllowUndefOrPoison=false)`** also holds for `dereferenceable(N)` when null
  is not defined (Instructions.cpp:442), so `call @f(ptr dereferenceable(1) %p)` makes a later `icmp eq %p, null`
  false (CorrelatedValuePropagation/non-null.ll under instsimplify).

## Constant folding of FP calls (ConstantFolding.cpp)

- **Transcendental folds use the host's *double* libm, for every type.** `ConstantFoldFP(sin, V, Ty)` converts a
  half/float argument to double, calls `sin` (not `sinf`), and rounds the double result to the type
  (`GetConstantFoldFPValue`). `exp2`/`exp10` are folded as `pow(2, x)` / `pow(10, x)`. A fold is dropped when the
  call sets errno to EDOM/ERANGE or raises any FP exception except inexact (`llvm_fenv_testexcept`), e.g. an
  underflowing `sin` of a subnormal. LLVM's opt links glibc's libm, so calling the same libm reproduces it
  bit for bit (verified on random sin/cos/exp/log/pow/... folds in half/float/double: identical output).
- Only **half, float and double** results are folded in ConstantFoldScalarCall1, *including* floor/ceil/round/
  rint/trunc/fabs: the type check comes before them (bfloat, x86_fp80, fp128 are left alone, except fp128 `log`
  when LLVM was built with logf128). Math functions additionally require a finite argument.
- `powi` folds as `(float)pow((double)x, (double)n)` for half/float (C++ `std::pow(float, int)` promotes) with no
  fenv check; `ldexp` uses `scalbn` with the exponent `sext`ed or `truncSSat`ed to 32 bits.
- `frexp` of inf/NaN gives exponent 0 (and a quieted NaN); `sincos` folds iff both sin and cos fold.

## Other ValueTracking facts found while making the analyses arbitrary-width

- **`ComputeMaxSignificantBits(V, DL, AC, CxtI, DT, Depth)` runs with UseInstrInfo = false**: it calls
  `ComputeNumSignBits(V, DL, AC, CxtI, DT, Depth)`, whose sixth parameter is `bool UseInstrInfo` (Depth is the
  seventh, defaulted), so Depth 0 becomes UseInstrInfo=false (ValueTracking.cpp:380). The whole query then ignores
  nsw/nuw/exact, nsz and instruction metadata (`Q.IIQ`). It is not just less precise: without nsw a simple
  recurrence `phi [0], [add nsw %iv, 1]` has no known sign bit, so computeKnownBits falls through to the per-edge
  union, which uses the backedge branch `icmp ult %iv.next, 12` and finds 28 leading zeros. visitTrunc's nsw
  inference (`ComputeMaxSignificantBits(Src) <= DestWidth`) therefore sets `trunc nsw` where computeKnownBits
  alone (the nuw check, UseInstrInfo=true) does not (`trunc nsw i32 %iv to i8`, verified by porting: goose's
  iiq_off). Every InstCombine ComputeMaxSignificantBits call and SimplifyCFG's eliminateDeadSwitchCases have it.
- **`isGuaranteedNotToBeUndefOrPoison` without a context instruction has no DominatorTree either**: all callers
  that pass `CtxI = nullptr` (impliesPoison, createLogicalOp in SimplifyCFG/LoopSimplify, ...) also pass
  `DT = nullptr` except NewGVN. The PHI case recurses with the incoming block's terminator as CtxI, but `!DT` still
  skips the dominating-branch walk, so `icmp eq %iv, 0` with `%iv` a loop phi is *not* known non-poison and
  FoldBranchToCommonDest makes a `select` (IndVarSimplify/eliminate-backedge.ll after instcombine,loop-simplify).
  JumpThreading:3027 and SimplifyCFG:5345 pass a CtxI but no DT.
- **`CallBase::paramHasAttr` / `getArgOperandWithAttribute` read the callee's attributes only through
  `getCalledFunction()`**, which is null when the callee's function type differs from the call's: a `returned`
  parameter of `define i64 @f(i64 returned)` called as `call float @f(float)` does not make InstCombine replace the
  call (InstCombine/bitcast-function.ll after function-attrs).
- **computeKnownBitsFromContext resets conflicting known bits whenever the query has an AssumptionCache**, even
  when there are no assumptions: `call range(i32 0, 32) ... !range !{i32 32, i32 64}` has conflicting bits, and
  InstSimplify (which has an AC) does not fold `shl %a, %b` to poison (InstSimplify/shift-knownbits.ll).
- **`CallBase::getRange()` intersects** the call-site and the callee's `range` return attributes.
- **`m_SpecificInt(uint64_t)` compares `APInt == uint64_t`**: no truncation of the constant to the type
  (`m_SpecificInt(-1)` never matches an i8 255). `m_SpecificInt(const APInt &)` uses `APInt::isSameValue`
  (zero-extends the narrower one); so does ConstantFoldExtractElement's insertelement index comparison.
- **`m_FNeg(X)` matches `fneg X` and `fsub -0.0, X`** (`fsub nsz` with any zero). Not to be confused with
  `m_FNegNSZ`, which matches only the fsub form.
- `computeKnownFPClass` takes `nofpclass` from the return attributes of any CallBase, invokes included.
- KnownFPClass::bitcast uses NaN/inf/zero bit patterns only for IEEE-like types (half, bfloat, float, double,
  fp128); for x86_fp80 and ppc_fp128 it transfers only the sign bit.
- **`assumeBundleImpliesNonNull`** (BundleAttributes.cpp) also knows `"align"(ptr %p, i64 A, i64 Off)`: non-null
  when A is a power of two and `Off % A != 0` (constant A and Off; without an offset it is 0). `"nonnull"` and a
  non-zero constant `"dereferenceable"` (where null isn't defined) are the other cases
  (Analysis/ValueTracking/assume.ll `@align_with_non_zero_offset_is_nonnull`).

- **`GEPOperator::accumulateConstantOffset` accepts scalable types as long as their indices are zero**
  (Operator.cpp: a zero `ConstantInt` index is skipped before the `isScalableTy()` check, and the check is on
  `GTI.getIndexedType()`, i.e. the vector's *element* type for the index into a scalable vector). So
  `stripAndAccumulateConstantOffsets(gep <vscale x 4 x i32>, ptr %p, i64 0, i64 1)` is `%p` + 4, which lets DSE's
  isOverwrite see it does not overlap a store to `%p` (verified with goose: `dse,print<memoryssa>` on
  `Transforms/GVN/vscale.ll` prints `MemoryDef(1)->liveOnEntry` only with this).

- **Constant folding `llvm.masked.load`** (ConstantFolding.cpp ConstantFoldFixedVectorCall): an `undef`/`poison`
  mask lane appends the passthru (or loaded) element and then falls through to the null/one tests, which fail, so
  any undef mask lane makes the whole fold fail. Only all-`i1 0`/`i1 1` masks fold.
- **`simplifyCall` never simplifies a `musttail` call** (it would break the call-ret chain), not even `call undef`
  to poison (InstSimplify/call.ll `call_undef_musttail`, seen through `gvn --per-function`).
- `Value::getPointerDereferenceableBytes` of a non-array alloca is the *known minimum* alloc size, so scalable
  allocas count (InstSimplify/compare.ll `scalar_vectors_are_non_empty`); globals use the *store* size.
- `GEPOperator::accumulateConstantOffset` takes only scalar `ConstantInt` indices (a vector zero index fails), skips
  zero indices before looking at scalability, and has an `i8` fast path that reads only the first index.

- ConstantFPRange works for every IEEE semantics, x86_fp80 included: keyed by sign-magnitude bit patterns, its
  +infinity is exponent 0x7FFF *with the explicit integer bit set* (bits 64..78 and 63), and `next()` across a binade
  changes the exponent (mantissa 0xFFFF... -> exponent + 1, mantissa 0x8000...; the smallest normal steps down to
  exponent 0, mantissa 0x7FFF...). tests/pass/instsimplify/fcmp-ranges-fp80-fp128.ll (impl/goose).
- Every phi recursion in isKnownNonZero, isKnownToBeAPowerOfTwo, isKnownNonEqual (PHIs) and ComputeNumSignBits uses
  `Q.getWithoutCondContext()`; isSignedMinMaxIntrinsicClamp requires CLow <= CHigh (signed) and ComputeNumSignBits of
  a clamp is min(numSignBits(CLow), numSignBits(CHigh)).
- stripAndAccumulateConstantOffsets(LookThroughIntToPtr) accumulates `inttoptr (add (ptrtoint p), C)` only with
  AllowNonInbounds, a ConstantInt C and an add of exactly the index width.
