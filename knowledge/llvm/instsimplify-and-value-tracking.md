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
