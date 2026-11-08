// KnownFPClass and computeKnownFPClass: llvm/include/llvm/Support/KnownFPClass.h, llvm/lib/Support/KnownFPClass.cpp,
// llvm/lib/Analysis/ValueTracking.cpp (computeKnownFPClass*, fcmpToClassTest) and ConstantFPRange
// (llvm/lib/IR/ConstantFPRange.cpp).
//
// TEMPORARY: only the interface; every query answers "unknown" (fails loudly where a caller would need a real
// answer is not possible: unknown is always correct, but less precise than LLVM). Being replaced by the full port.

// FPClassTest bits (llvm/ADT/FloatingPointMode.h)
FC_NONE :: 0;
FC_SNAN :: 0x1; FC_QNAN :: 0x2; FC_NEG_INF :: 0x4; FC_NEG_NORMAL :: 0x8; FC_NEG_SUBNORMAL :: 0x10; FC_NEG_ZERO :: 0x20;
FC_POS_ZERO :: 0x40; FC_POS_SUBNORMAL :: 0x80; FC_POS_NORMAL :: 0x100; FC_POS_INF :: 0x200;
FC_NAN :: FC_SNAN | FC_QNAN;
FC_INF :: FC_POS_INF | FC_NEG_INF;
FC_NORMAL :: FC_POS_NORMAL | FC_NEG_NORMAL;
FC_SUBNORMAL :: FC_POS_SUBNORMAL | FC_NEG_SUBNORMAL;
FC_ZERO :: FC_POS_ZERO | FC_NEG_ZERO;
FC_POS_FINITE :: FC_POS_NORMAL | FC_POS_SUBNORMAL | FC_POS_ZERO;
FC_NEG_FINITE :: FC_NEG_NORMAL | FC_NEG_SUBNORMAL | FC_NEG_ZERO;
FC_FINITE :: FC_POS_FINITE | FC_NEG_FINITE;
FC_POSITIVE :: FC_POS_FINITE | FC_POS_INF;
FC_NEGATIVE :: FC_NEG_FINITE | FC_NEG_INF;
FC_ALL_FLAGS :: FC_NAN | FC_INF | FC_FINITE;

// KnownFPClass::OrderedLessThanZeroMask = fcNegSubnormal | fcNegNormal | fcNegInf
KFPC_ORDERED_LESS_THAN_ZERO_MASK :: FC_NEG_SUBNORMAL | FC_NEG_NORMAL | FC_NEG_INF;

Known_FP_Class :: struct {
    known_fp_classes: u32 = FC_ALL_FLAGS;
    sign_bit: s8 = -1;   // std::optional<bool>: -1 unknown, 0 false, 1 true
}
kfpc_is_known_never :: (k: Known_FP_Class, mask: u32) -> bool { return (k.known_fp_classes & mask) == FC_NONE; }
kfpc_is_known_always :: (k: Known_FP_Class, mask: u32) -> bool { return kfpc_is_known_never(k, ~mask & FC_ALL_FLAGS); }
kfpc_is_known_never_nan :: (k: Known_FP_Class) -> bool { return kfpc_is_known_never(k, FC_NAN); }
kfpc_is_known_always_nan :: (k: Known_FP_Class) -> bool { return kfpc_is_known_always(k, FC_NAN); }
// cannotBeOrderedLessThanZero
kfpc_cannot_be_ordered_less_than_zero :: (k: Known_FP_Class) -> bool { return kfpc_is_known_never(k, KFPC_ORDERED_LESS_THAN_ZERO_MASK); }

compute_known_fp_class_de :: (v: Value_Id, de: APInt, interested: u32, q: Simplify_Query, depth: u32) -> Known_FP_Class {
    k: Known_FP_Class;
    return k;
}
compute_known_fp_class :: (v: Value_Id, interested: u32, q: Simplify_Query, depth: u32 = 0) -> Known_FP_Class {
    return compute_known_fp_class_de(v, dem_all(vtype(v)), interested, q, depth);
}
compute_known_fp_class_fmf :: (v: Value_Id, fmf: u32, interested: u32, q: Simplify_Query, depth: u32 = 0) -> Known_FP_Class {
    return compute_known_fp_class(v, interested, q, depth);
}
cannot_be_negative_zero :: (v: Value_Id, q: Simplify_Query, depth: u32 = 0) -> bool {
    k := compute_known_fp_class(v, FC_NEG_ZERO, q, depth);
    return kfpc_is_known_never(k, FC_NEG_ZERO);
}
// fcmpToClassTest: (class value or NONE, class test)
fcmp_to_class_test :: (pred: u8, f: Value_Id, lhs: Value_Id, c: APFloat) -> (Value_Id, u32) {
    return NONE, 0;
}

Const_FP_Range :: struct { lo: APFloat; hi: APFloat; may_be_qnan: bool; may_be_snan: bool; empty: bool; }
cfr_make_exact_fcmp_region :: (pred: u8, c: APFloat) -> (bool, Const_FP_Range) { r: Const_FP_Range; return false, r; }
cfr_contains_range :: (a: Const_FP_Range, b: Const_FP_Range) -> bool { return false; }
cfr_intersect :: (a: Const_FP_Range, b: Const_FP_Range) -> Const_FP_Range { return a; }
cfr_is_empty_set :: (a: Const_FP_Range) -> bool { return false; }

