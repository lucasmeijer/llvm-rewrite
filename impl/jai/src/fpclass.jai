// Floating-point class analysis:
//   - FPClassTest helpers (llvm/lib/Support/FloatingPointMode.cpp: fneg, inverse_fabs, unknown_sign,
//     cannotOrderStrictly*, orderedStrictlyLess/Greater)
//   - KnownFPClass (llvm/include/llvm/Support/KnownFPClass.h, llvm/lib/Support/KnownFPClass.cpp)
//   - computeKnownFPClass and its context helpers (llvm/lib/Analysis/ValueTracking.cpp)
//   - fcmpImpliesClass / fcmpToClassTest (llvm/include/llvm/IR/GenericFloatingPointPredicateUtils.h,
//     llvm/lib/Analysis/FloatingPointPredicateUtils.cpp)
//   - ConstantFPRange (llvm/lib/IR/ConstantFPRange.cpp; the parts InstSimplify / ValueTracking use)
// SimplifyQuery has no DomConditionCache / CondContext here (InstSimplify passes neither), so the dominating
// branch part of computeKnownFPClassFromContext and computeKnownExponentRangeFromContext are not reachable.

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

// ~Mask on the bitmask enum
fc_not :: inline (m: u32) -> u32 { return ~m & FC_ALL_FLAGS; }

KFPC_ORDERED_LESS_THAN_ZERO_MASK :: FC_NEG_SUBNORMAL | FC_NEG_NORMAL | FC_NEG_INF;
KFPC_ORDERED_GREATER_THAN_ZERO_MASK :: FC_POS_SUBNORMAL | FC_POS_NORMAL | FC_POS_INF;

// ---------------------------------------------------------------- FloatingPointMode.cpp

fc_fneg :: (mask: u32) -> u32 {
    r := mask & FC_NAN;
    if mask & FC_NEG_INF r |= FC_POS_INF;
    if mask & FC_NEG_NORMAL r |= FC_POS_NORMAL;
    if mask & FC_NEG_SUBNORMAL r |= FC_POS_SUBNORMAL;
    if mask & FC_NEG_ZERO r |= FC_POS_ZERO;
    if mask & FC_POS_ZERO r |= FC_NEG_ZERO;
    if mask & FC_POS_SUBNORMAL r |= FC_NEG_SUBNORMAL;
    if mask & FC_POS_NORMAL r |= FC_NEG_NORMAL;
    if mask & FC_POS_INF r |= FC_NEG_INF;
    return r;
}
fc_inverse_fabs :: (mask: u32) -> u32 {
    r := mask & FC_NAN;
    if mask & FC_POS_ZERO r |= FC_ZERO;
    if mask & FC_POS_SUBNORMAL r |= FC_SUBNORMAL;
    if mask & FC_POS_NORMAL r |= FC_NORMAL;
    if mask & FC_POS_INF r |= FC_INF;
    return r;
}
fc_unknown_sign :: (mask: u32) -> u32 {
    r := mask & FC_NAN;
    if mask & FC_ZERO r |= FC_ZERO;
    if mask & FC_SUBNORMAL r |= FC_SUBNORMAL;
    if mask & FC_NORMAL r |= FC_NORMAL;
    if mask & FC_INF r |= FC_INF;
    return r;
}
fc_cannot_order_strictly_greater_impl :: (lhs_in: u32, rhs_in: u32, or_equal: bool, ordered_zero: bool) -> bool {
    lhs := lhs_in & ~cast(u32) FC_NAN; rhs := rhs_in & ~cast(u32) FC_NAN;
    if lhs == 0 || rhs == 0 return true;
    lowest_rhs := rhs & (~rhs + 1);
    highest_lhs := (cast(u32) 1) << cast(u32)(31 - fc_clz32(lhs));
    if !ordered_zero {
        if lowest_rhs == FC_NEG_ZERO lowest_rhs = FC_POS_ZERO;
        if highest_lhs == FC_NEG_ZERO highest_lhs = FC_POS_ZERO;
    }
    if lowest_rhs > highest_lhs return true;
    if lowest_rhs < highest_lhs return false;
    return !or_equal && (lowest_rhs & (FC_ZERO | FC_INF)) != 0;
}
fc_clz32 :: (x: u32) -> u32 { n: u32 = 0; b: u32 = 0x8000_0000; while b != 0 && (x & b) == 0 { n += 1; b >>= 1; } return n; }
fc_ctz32 :: (x: u32) -> u32 { if x == 0 return 32; n: u32 = 0; while (x & ((cast(u32) 1) << n)) == 0 n += 1; return n; }
cannot_order_strictly_greater :: (l: u32, r: u32, ozs := false) -> bool { return fc_cannot_order_strictly_greater_impl(l, r, false, ozs); }
cannot_order_strictly_greater_eq :: (l: u32, r: u32, ozs := false) -> bool { return fc_cannot_order_strictly_greater_impl(l, r, true, ozs); }
cannot_order_strictly_less :: (l: u32, r: u32, ozs := false) -> bool { return fc_cannot_order_strictly_greater_impl(r, l, false, ozs); }
cannot_order_strictly_less_eq :: (l: u32, r: u32, ozs := false) -> bool { return fc_cannot_order_strictly_greater_impl(r, l, true, ozs); }
ordered_strictly_less :: (mask_in: u32, ordered_zero_sign := false) -> u32 {
    mask := mask_in & ~cast(u32) FC_NAN;
    tz := fc_ctz32(mask);
    m: u32 = ifx tz >= 32 then 0xFFFF_FFFF else ((cast(u32) 1) << tz) - 1;
    r := m & FC_ALL_FLAGS & ~cast(u32) FC_NAN;
    if !ordered_zero_sign && (r & FC_ZERO) != FC_ZERO r &= ~cast(u32) FC_ZERO;
    return r;
}
ordered_strictly_greater :: (mask: u32, ordered_zero_sign := false) -> u32 {
    lz := fc_clz32(mask);
    m: u32 = ifx lz >= 32 then 0xFFFF_FFFF else ~((cast(u32) 0xFFFF_FFFF) >> lz);   // maskLeadingOnes(lz)
    r := m & FC_ALL_FLAGS & ~cast(u32) FC_NAN;
    if !ordered_zero_sign && (r & FC_ZERO) != FC_ZERO r &= ~cast(u32) FC_ZERO;
    return r;
}

// APFloat::classify
apf_classify :: (f: APFloat) -> u32 {
    g := f;
    d := fp_decode(g.k, apf_words(*g));
    if d.cat == .NAN return ifx fp_is_signaling(g.k, d) then cast(u32) FC_SNAN else FC_QNAN;
    if d.cat == .INF return ifx d.neg then cast(u32) FC_NEG_INF else FC_POS_INF;
    if d.cat == .ZERO return ifx d.neg then cast(u32) FC_NEG_ZERO else FC_POS_ZERO;
    if apf_is_denormal(f) return ifx d.neg then cast(u32) FC_NEG_SUBNORMAL else FC_POS_SUBNORMAL;
    return ifx d.neg then cast(u32) FC_NEG_NORMAL else FC_POS_NORMAL;
}

// ---------------------------------------------------------------- DenormalMode

Denorm_Mode :: struct { output: u8; input: u8; }
DM_IEEE :: Denorm_Mode.{DENORMAL_IEEE, DENORMAL_IEEE};
DM_PRESERVE_SIGN :: Denorm_Mode.{DENORMAL_PRESERVE_SIGN, DENORMAL_PRESERVE_SIGN};
DM_POSITIVE_ZERO :: Denorm_Mode.{DENORMAL_POSITIVE_ZERO, DENORMAL_POSITIVE_ZERO};
DM_DYNAMIC :: Denorm_Mode.{DENORMAL_DYNAMIC, DENORMAL_DYNAMIC};
dm_eq :: (a: Denorm_Mode, b: Denorm_Mode) -> bool { return a.output == b.output && a.input == b.input; }
dm_inputs_are_zero :: (m: Denorm_Mode) -> bool { return m.input == DENORMAL_PRESERVE_SIGN || m.input == DENORMAL_POSITIVE_ZERO; }
dm_outputs_are_zero :: (m: Denorm_Mode) -> bool { return m.output == DENORMAL_PRESERVE_SIGN || m.output == DENORMAL_POSITIVE_ZERO; }
// F->getDenormalMode(FltSem) of the function containing instruction `i` (Dynamic without a function)
dm_of_inst :: (i: Value_Id, t: Type_Id) -> Denorm_Mode {
    o, inp := inst_denormal_mode(i, t);
    return .{o, inp};
}
dm_of_fn :: (f: Value_Id, t: Type_Id) -> Denorm_Mode {
    if f == NONE return DM_DYNAMIC;
    o, inp := fn_denormal_mode(f, t);
    return .{o, inp};
}

// ---------------------------------------------------------------- KnownFPClass

Known_FP_Class :: struct {
    known_fp_classes: u32 = FC_ALL_FLAGS;
    sign_bit: s8 = -1;   // std::optional<bool>: -1 unknown, 0 false, 1 true
}
kfpc_make :: (known: u32, sign: s8 = -1) -> Known_FP_Class { r: Known_FP_Class; r.known_fp_classes = known; r.sign_bit = sign; return r; }
kfpc_from_apfloat :: (c: APFloat) -> Known_FP_Class { return kfpc_make(apf_classify(c), ifx apf_is_negative(c) then cast(s8) 1 else 0); }
kfpc_is_known_never :: (k: Known_FP_Class, mask: u32) -> bool { return (k.known_fp_classes & mask) == FC_NONE; }
kfpc_is_known_always :: (k: Known_FP_Class, mask: u32) -> bool { return kfpc_is_known_never(k, fc_not(mask)); }
kfpc_is_unknown :: (k: Known_FP_Class) -> bool { return k.known_fp_classes == FC_ALL_FLAGS && k.sign_bit < 0; }
kfpc_is_known_never_nan :: (k: Known_FP_Class) -> bool { return kfpc_is_known_never(k, FC_NAN); }
kfpc_is_known_always_nan :: (k: Known_FP_Class) -> bool { return kfpc_is_known_always(k, FC_NAN); }
kfpc_is_known_never_infinity :: (k: Known_FP_Class) -> bool { return kfpc_is_known_never(k, FC_INF); }
kfpc_is_known_never_inf_or_nan :: (k: Known_FP_Class) -> bool { return kfpc_is_known_never(k, FC_INF | FC_NAN); }
kfpc_is_known_never_pos_infinity :: (k: Known_FP_Class) -> bool { return kfpc_is_known_never(k, FC_POS_INF); }
kfpc_is_known_never_neg_infinity :: (k: Known_FP_Class) -> bool { return kfpc_is_known_never(k, FC_NEG_INF); }
kfpc_is_known_never_subnormal :: (k: Known_FP_Class) -> bool { return kfpc_is_known_never(k, FC_SUBNORMAL); }
kfpc_is_known_never_pos_subnormal :: (k: Known_FP_Class) -> bool { return kfpc_is_known_never(k, FC_POS_SUBNORMAL); }
kfpc_is_known_never_neg_subnormal :: (k: Known_FP_Class) -> bool { return kfpc_is_known_never(k, FC_NEG_SUBNORMAL); }
kfpc_is_known_never_zero :: (k: Known_FP_Class) -> bool { return kfpc_is_known_never(k, FC_ZERO); }
kfpc_is_known_never_pos_zero :: (k: Known_FP_Class) -> bool { return kfpc_is_known_never(k, FC_POS_ZERO); }
kfpc_is_known_never_neg_zero :: (k: Known_FP_Class) -> bool { return kfpc_is_known_never(k, FC_NEG_ZERO); }
kfpc_is_known_never_logical_zero :: (k: Known_FP_Class, m: Denorm_Mode) -> bool {
    return kfpc_is_known_never_zero(k) && (kfpc_is_known_never_subnormal(k) || m.input == DENORMAL_IEEE);
}
kfpc_is_known_never_logical_neg_zero :: (k: Known_FP_Class, m: Denorm_Mode) -> bool {
    return kfpc_is_known_never_neg_zero(k) && (kfpc_is_known_never_neg_subnormal(k) || m.input == DENORMAL_IEEE || m.input == DENORMAL_POSITIVE_ZERO);
}
kfpc_is_known_never_logical_pos_zero :: (k: Known_FP_Class, m: Denorm_Mode) -> bool {
    if !kfpc_is_known_never_pos_zero(k) return false;
    if kfpc_is_known_never_subnormal(k) return true;
    if m.input == DENORMAL_IEEE return true;
    if m.input == DENORMAL_PRESERVE_SIGN return kfpc_is_known_never_pos_subnormal(k);
    return false;
}
kfpc_cannot_be_ordered_less_than_zero :: (k: Known_FP_Class) -> bool { return kfpc_is_known_never(k, KFPC_ORDERED_LESS_THAN_ZERO_MASK); }
kfpc_cannot_be_ordered_greater_than_zero :: (k: Known_FP_Class) -> bool { return kfpc_is_known_never(k, KFPC_ORDERED_GREATER_THAN_ZERO_MASK); }
kfpc_cannot_be_ordered_less_eq_zero :: (k: Known_FP_Class, m: Denorm_Mode) -> bool { return kfpc_is_known_never(k, FC_NEGATIVE) && kfpc_is_known_never_logical_pos_zero(k, m); }
kfpc_cannot_be_ordered_greater_eq_zero :: (k: Known_FP_Class, m: Denorm_Mode) -> bool { return kfpc_is_known_never(k, FC_POSITIVE) && kfpc_is_known_never_logical_neg_zero(k, m); }
kfpc_intersect_with :: (a: Known_FP_Class, b: Known_FP_Class) -> Known_FP_Class {
    return kfpc_make(a.known_fp_classes | b.known_fp_classes, ifx a.sign_bit == b.sign_bit then a.sign_bit else -1);
}
kfpc_union_with :: (a: Known_FP_Class, b: Known_FP_Class) -> Known_FP_Class {
    s: s8 = -1;
    if a.sign_bit >= 0 && b.sign_bit < 0 s = a.sign_bit;
    else if a.sign_bit < 0 && b.sign_bit >= 0 s = b.sign_bit;
    return kfpc_make(a.known_fp_classes & b.known_fp_classes, s);
}
// operator|=
kfpc_or :: (a: Known_FP_Class, b: Known_FP_Class) -> Known_FP_Class {
    r := a;
    r.known_fp_classes |= b.known_fp_classes;
    if r.sign_bit != b.sign_bit r.sign_bit = -1;
    return r;
}
kfpc_known_not :: (k: *Known_FP_Class, rule_out: u32) {
    k.known_fp_classes &= ~rule_out;
    if kfpc_is_known_never(k.*, FC_NAN) && k.sign_bit < 0 {
        if kfpc_is_known_never(k.*, FC_NEGATIVE) k.sign_bit = 0;
        else if kfpc_is_known_never(k.*, FC_POSITIVE) k.sign_bit = 1;
    }
}
kfpc_fneg :: (k: Known_FP_Class) -> Known_FP_Class {
    r := k;
    r.known_fp_classes = fc_fneg(k.known_fp_classes);
    if r.sign_bit >= 0 r.sign_bit = 1 - r.sign_bit;
    return r;
}
kfpc_sign_bit_must_be_zero :: (k: *Known_FP_Class) { k.known_fp_classes &= (FC_POSITIVE | FC_NAN); k.sign_bit = 0; }
kfpc_sign_bit_must_be_one :: (k: *Known_FP_Class) { k.known_fp_classes &= (FC_NEGATIVE | FC_NAN); k.sign_bit = 1; }
kfpc_fabs :: (k: Known_FP_Class) -> Known_FP_Class {
    r := k;
    if r.known_fp_classes & FC_NEG_ZERO r.known_fp_classes |= FC_POS_ZERO;
    if r.known_fp_classes & FC_NEG_INF r.known_fp_classes |= FC_POS_INF;
    if r.known_fp_classes & FC_NEG_SUBNORMAL r.known_fp_classes |= FC_POS_SUBNORMAL;
    if r.known_fp_classes & FC_NEG_NORMAL r.known_fp_classes |= FC_POS_NORMAL;
    kfpc_sign_bit_must_be_zero(*r);
    return r;
}
kfpc_copysign :: (mag: Known_FP_Class, sign: Known_FP_Class) -> Known_FP_Class {
    r := mag;
    if r.known_fp_classes & FC_ZERO r.known_fp_classes |= FC_ZERO;
    if r.known_fp_classes & FC_SUBNORMAL r.known_fp_classes |= FC_SUBNORMAL;
    if r.known_fp_classes & FC_NORMAL r.known_fp_classes |= FC_NORMAL;
    if r.known_fp_classes & FC_INF r.known_fp_classes |= FC_INF;
    r.sign_bit = sign.sign_bit;
    if kfpc_is_known_never(sign, FC_POSITIVE | FC_NAN) || r.sign_bit == 1 r.known_fp_classes &= (FC_NEGATIVE | FC_NAN);
    if kfpc_is_known_never(sign, FC_NEGATIVE | FC_NAN) || r.sign_bit == 0 r.known_fp_classes &= (FC_POSITIVE | FC_NAN);
    return r;
}
kfpc_propagate_nan :: (k: *Known_FP_Class, src: Known_FP_Class, preserve_sign := false) {
    if kfpc_is_known_never(src, FC_NAN) {
        kfpc_known_not(k, FC_NAN);
        if preserve_sign k.sign_bit = src.sign_bit;
    } else if kfpc_is_known_never(src, FC_SNAN) kfpc_known_not(k, FC_SNAN);
}
kfpc_propagate_xor_sign :: (k: *Known_FP_Class, l: Known_FP_Class, r: Known_FP_Class) {
    if (kfpc_is_known_never(l, FC_NEGATIVE) && kfpc_is_known_never(r, FC_NEGATIVE)) || (kfpc_is_known_never(l, FC_POSITIVE) && kfpc_is_known_never(r, FC_POSITIVE))
        kfpc_known_not(k, FC_NEGATIVE);
    if (kfpc_is_known_never(l, FC_POSITIVE) && kfpc_is_known_never(r, FC_NEGATIVE)) || (kfpc_is_known_never(l, FC_NEGATIVE) && kfpc_is_known_never(r, FC_POSITIVE))
        kfpc_known_not(k, FC_POSITIVE);
}
kfpc_propagate_denormal :: (k: *Known_FP_Class, src: Known_FP_Class, m: Denorm_Mode) {
    k.known_fp_classes = src.known_fp_classes;
    if !kfpc_is_known_never_pos_zero(src) && !kfpc_is_known_never_neg_zero(src) return;
    if kfpc_is_known_never_subnormal(src) return;
    if !kfpc_is_known_never_pos_subnormal(src) && !dm_eq(m, DM_IEEE) k.known_fp_classes |= FC_POS_ZERO;
    if !kfpc_is_known_never_neg_subnormal(src) && !dm_eq(m, DM_IEEE) {
        if !dm_eq(m, DM_POSITIVE_ZERO) k.known_fp_classes |= FC_NEG_ZERO;
        if m.input == DENORMAL_POSITIVE_ZERO || m.output == DENORMAL_POSITIVE_ZERO || m.input == DENORMAL_DYNAMIC || m.output == DENORMAL_DYNAMIC
            k.known_fp_classes |= FC_POS_ZERO;
    }
}
kfpc_propagate_canonicalizing_src :: (k: *Known_FP_Class, src: Known_FP_Class, m: Denorm_Mode) {
    kfpc_propagate_denormal(k, src, m);
    kfpc_propagate_nan(k, src, true);
}

MM_MINIMUM :: 0; MM_MAXIMUM :: 1; MM_MINIMUMNUM :: 2; MM_MAXIMUMNUM :: 3; MM_MINNUM :: 4; MM_MAXNUM :: 5;
kfpc_min_max_like :: (l_in: Known_FP_Class, r_in: Known_FP_Class, kind: u8, m: Denorm_Mode = DM_DYNAMIC) -> Known_FP_Class {
    l := l_in; r := r_in;
    never_nan := kfpc_is_known_never_nan(l) || kfpc_is_known_never_nan(r);
    known := kfpc_or(l, r);
    if never_nan && (kind == MM_MINNUM || kind == MM_MAXNUM || kind == MM_MINIMUMNUM || kind == MM_MAXIMUMNUM) kfpc_known_not(*known, FC_NAN);
    if kind == MM_MAXNUM || kind == MM_MAXIMUMNUM {
        if kfpc_is_known_never_nan(l) kfpc_known_not(*known, ordered_strictly_less(l.known_fp_classes));
        if kfpc_is_known_never_nan(r) kfpc_known_not(*known, ordered_strictly_less(r.known_fp_classes));
    } else if kind == MM_MAXIMUM {
        kfpc_known_not(*known, ordered_strictly_less(l.known_fp_classes) | ordered_strictly_less(r.known_fp_classes));
    } else if kind == MM_MINNUM || kind == MM_MINIMUMNUM {
        if kfpc_is_known_never_nan(l) kfpc_known_not(*known, ordered_strictly_greater(l.known_fp_classes));
        if kfpc_is_known_never_nan(r) kfpc_known_not(*known, ordered_strictly_greater(r.known_fp_classes));
    } else {
        kfpc_known_not(*known, ordered_strictly_greater(l.known_fp_classes) | ordered_strictly_greater(r.known_fp_classes));
    }
    if (known.known_fp_classes & FC_ZERO) != FC_NONE && !kfpc_is_known_never_subnormal(known) {
        if !dm_eq(m, DM_IEEE) known.known_fp_classes |= FC_ZERO;
    }
    if kfpc_is_known_never_nan(known) {
        if l.sign_bit >= 0 && r.sign_bit >= 0 && l.sign_bit == r.sign_bit {
            if l.sign_bit == 1 kfpc_sign_bit_must_be_one(*known); else kfpc_sign_bit_must_be_zero(*known);
        } else if (kind == MM_MAXIMUM || kind == MM_MINIMUM || kind == MM_MAXIMUMNUM || kind == MM_MINIMUMNUM) ||
                  ((kfpc_is_known_never_neg_zero(l) || kfpc_is_known_never_pos_zero(r)) && (kfpc_is_known_never_pos_zero(l) || kfpc_is_known_never_neg_zero(r))) {
            if !kfpc_is_known_never_nan(l) l.sign_bit = -1;
            if !kfpc_is_known_never_nan(r) r.sign_bit = -1;
            if (kind == MM_MAXIMUM || kind == MM_MAXIMUMNUM || kind == MM_MAXNUM) && (l.sign_bit == 0 || r.sign_bit == 0)
                kfpc_sign_bit_must_be_zero(*known);
            else if (kind == MM_MINIMUM || kind == MM_MINIMUMNUM || kind == MM_MINNUM) && (l.sign_bit == 1 || r.sign_bit == 1)
                kfpc_sign_bit_must_be_one(*known);
        }
    }
    return known;
}
kfpc_canonicalize :: (src: Known_FP_Class, m: Denorm_Mode = DM_DYNAMIC) -> Known_FP_Class {
    k: Known_FP_Class;
    k.known_fp_classes = src.known_fp_classes | FC_ZERO | FC_QNAN;
    if kfpc_is_known_never_nan(src) kfpc_known_not(*k, FC_NAN); else kfpc_known_not(*k, FC_SNAN);
    if dm_eq(m, DM_IEEE) {
        if kfpc_is_known_never(src, FC_POS_ZERO) kfpc_known_not(*k, FC_POS_ZERO);
        if kfpc_is_known_never(src, FC_NEG_ZERO) kfpc_known_not(*k, FC_NEG_ZERO);
        return k;
    }
    if dm_inputs_are_zero(m) || dm_outputs_are_zero(m) kfpc_known_not(*k, FC_SUBNORMAL);
    if dm_eq(m, DM_PRESERVE_SIGN) {
        if kfpc_is_known_never(src, FC_POS_ZERO | FC_POS_SUBNORMAL) kfpc_known_not(*k, FC_POS_ZERO);
        if kfpc_is_known_never(src, FC_NEG_ZERO | FC_NEG_SUBNORMAL) kfpc_known_not(*k, FC_NEG_ZERO);
        return k;
    }
    if m.input == DENORMAL_POSITIVE_ZERO || (m.output == DENORMAL_POSITIVE_ZERO && m.input == DENORMAL_IEEE) {
        if kfpc_is_known_never(src, FC_NEG_ZERO) kfpc_known_not(*k, FC_NEG_ZERO);
        if kfpc_is_known_never(src, FC_POS_ZERO | FC_SUBNORMAL) kfpc_known_not(*k, FC_POS_ZERO);
    }
    return k;
}
// KnownFPClass::bitcast
kfpc_bitcast :: (fk: Type_Kind, bits: Known_Bits) -> Known_FP_Class {
    k: Known_FP_Class;
    if kb_is_non_negative(bits) kfpc_sign_bit_must_be_zero(*k);
    else if kb_is_negative(bits) kfpc_sign_bit_must_be_one(*k);
    if fk == .HALF || fk == .BFLOAT || fk == .FLOAT || fk == .DOUBLE || fk == .FP128 {   // isIEEELikeFP
        n := bits.zero.bits;
        one_w := ap_words(bits.one);
        notz := ap_not(bits.zero);
        if fp_decode(fk, one_w).cat == .NAN k.known_fp_classes = FC_NAN;
        else if fp_decode(fk, ap_words(notz)).cat != .NAN kfpc_known_not(*k, FC_NAN);
        inf_kb := kb_from_const(ap_from_words(n, fp_inf(fk, false)));
        ap_clear_bit(*inf_kb.zero, n - 1);
        if kb_cmp_eq(bits, inf_kb) >= 0 kfpc_known_not(*k, FC_INF);
        else if kb_eq_kb(bits, inf_kb) k.known_fp_classes = FC_INF;
        zero_kb := kb_from_const(ap_from_words(n, fp_zero(fk, false)));
        ap_clear_bit(*zero_kb.zero, n - 1);
        if kb_cmp_eq(bits, zero_kb) >= 0 kfpc_known_not(*k, FC_ZERO);
        else if kb_eq_kb(bits, zero_kb) k.known_fp_classes = FC_ZERO;
    }
    return k;
}
kfpc_fadd_impl :: (l: Known_FP_Class, r: Known_FP_Class, m: Denorm_Mode) -> Known_FP_Class {
    k: Known_FP_Class;
    if kfpc_is_known_never_nan(l) && kfpc_is_known_never_nan(r) &&
       (kfpc_is_known_never(l, FC_POS_INF) || kfpc_is_known_never(r, FC_NEG_INF)) &&
       (kfpc_is_known_never(l, FC_NEG_INF) || kfpc_is_known_never(r, FC_POS_INF))
        kfpc_known_not(*k, FC_NAN);
    if kfpc_cannot_be_ordered_less_than_zero(l) && kfpc_cannot_be_ordered_less_than_zero(r) {
        kfpc_known_not(*k, KFPC_ORDERED_LESS_THAN_ZERO_MASK);
        if kfpc_is_known_never(l, FC_ZERO | FC_POS_SUBNORMAL) || kfpc_is_known_never(r, FC_ZERO | FC_POS_SUBNORMAL)
            kfpc_known_not(*k, FC_ZERO | FC_POS_SUBNORMAL);
    }
    if kfpc_cannot_be_ordered_greater_than_zero(l) && kfpc_cannot_be_ordered_greater_than_zero(r) {
        kfpc_known_not(*k, KFPC_ORDERED_GREATER_THAN_ZERO_MASK);
        if kfpc_is_known_never(l, FC_ZERO | FC_NEG_SUBNORMAL) || kfpc_is_known_never(r, FC_ZERO | FC_NEG_SUBNORMAL)
            kfpc_known_not(*k, FC_ZERO | FC_NEG_SUBNORMAL);
    }
    return k;
}
kfpc_fadd :: (l: Known_FP_Class, r: Known_FP_Class, m: Denorm_Mode = DM_DYNAMIC) -> Known_FP_Class {
    k := kfpc_fadd_impl(l, r, m);
    if (kfpc_is_known_never_logical_neg_zero(l, m) || kfpc_is_known_never_logical_neg_zero(r, m)) &&
       (m.output == DENORMAL_IEEE || m.output == DENORMAL_POSITIVE_ZERO)
        kfpc_known_not(*k, FC_NEG_ZERO);
    return k;
}
kfpc_fadd_self :: (src: Known_FP_Class, m: Denorm_Mode = DM_DYNAMIC) -> Known_FP_Class {
    k := kfpc_fadd(src, src, m);
    if kfpc_is_known_never_logical_pos_zero(src, m) &&
       (m.output == DENORMAL_IEEE || (m.output == DENORMAL_PRESERVE_SIGN && kfpc_is_known_never_pos_subnormal(src)) ||
        (m.output == DENORMAL_POSITIVE_ZERO && kfpc_is_known_never_subnormal(src)))
        kfpc_known_not(*k, FC_POS_ZERO);
    return k;
}
kfpc_fsub :: (l: Known_FP_Class, r: Known_FP_Class, m: Denorm_Mode = DM_DYNAMIC) -> Known_FP_Class { return kfpc_fadd(l, kfpc_fneg(r), m); }
kfpc_fmul :: (l: Known_FP_Class, r: Known_FP_Class, m: Denorm_Mode = DM_DYNAMIC) -> Known_FP_Class {
    k: Known_FP_Class;
    kfpc_propagate_xor_sign(*k, l, r);
    if kfpc_is_known_always(l, FC_INF | FC_NAN) || kfpc_is_known_always(r, FC_INF | FC_NAN) kfpc_known_not(*k, FC_NORMAL | FC_SUBNORMAL | FC_ZERO);
    if kfpc_is_known_always(r, FC_ZERO | FC_NAN) || kfpc_is_known_always(l, FC_ZERO | FC_NAN) kfpc_known_not(*k, FC_NORMAL | FC_SUBNORMAL | FC_INF);
    if !kfpc_is_known_never_nan(l) || !kfpc_is_known_never_nan(r) return k;
    if (kfpc_is_known_never_infinity(r) || kfpc_is_known_never_logical_zero(l, m)) &&
       (kfpc_is_known_never_infinity(l) || kfpc_is_known_never_logical_zero(r, m))
        kfpc_known_not(*k, FC_NAN);
    return k;
}
kfpc_square :: (src: Known_FP_Class, m: Denorm_Mode = DM_DYNAMIC) -> Known_FP_Class {
    k := kfpc_fmul(src, src, m);
    kfpc_known_not(*k, FC_NEGATIVE);
    kfpc_propagate_nan(*k, src);
    return k;
}
kfpc_fmul_const :: (l: Known_FP_Class, c: APFloat, m: Denorm_Mode = DM_DYNAMIC) -> Known_FP_Class {
    p, mx, mn, b := fp_semantics(c.k);
    mantissa_bits := cast(s64) p - 1;
    g := c;
    min_known_exp := fp_ilogb(c.k, apf_words(*g));
    cannot_be_subnormal := min_known_exp >= mantissa_bits;
    k := kfpc_fmul(l, kfpc_from_apfloat(c), m);
    if cannot_be_subnormal kfpc_known_not(*k, FC_SUBNORMAL);
    if kfpc_is_known_never(l, FC_INF) {
        if min_known_exp < 0 kfpc_known_not(*k, FC_INF);
        else if min_known_exp == 0 && apf_is_exactly_one(apf_from_words(c.k, fp_with_sign(c.k, apf_words(*g), false))) kfpc_known_not(*k, FC_INF);
    }
    return k;
}
kfpc_fdiv :: (l: Known_FP_Class, r: Known_FP_Class, m: Denorm_Mode = DM_DYNAMIC) -> Known_FP_Class {
    k: Known_FP_Class;
    if kfpc_is_known_never_nan(l) && kfpc_is_known_never_nan(r) && (kfpc_is_known_never_infinity(l) || kfpc_is_known_never_infinity(r)) &&
       (kfpc_is_known_never_logical_zero(l, m) || kfpc_is_known_never_logical_zero(r, m))
        kfpc_known_not(*k, FC_NAN);
    kfpc_propagate_xor_sign(*k, l, r);
    if kfpc_is_known_always(l, FC_ZERO) kfpc_known_not(*k, FC_SUBNORMAL | FC_NORMAL | FC_INF);
    if kfpc_is_known_always(r, FC_ZERO) kfpc_known_not(*k, FC_FINITE);
    return k;
}
kfpc_fdiv_self :: (src: Known_FP_Class, m: Denorm_Mode = DM_DYNAMIC) -> Known_FP_Class {
    k := kfpc_make(FC_NAN | FC_POS_NORMAL);
    if kfpc_is_known_never_inf_or_nan(src) && kfpc_is_known_never_logical_zero(src, m) kfpc_known_not(*k, FC_NAN);
    else if kfpc_is_known_never(src, FC_SNAN) kfpc_known_not(*k, FC_SNAN);
    return k;
}
kfpc_frem_self :: (src: Known_FP_Class, m: Denorm_Mode = DM_DYNAMIC) -> Known_FP_Class {
    k := kfpc_make(FC_NAN | FC_ZERO);
    if kfpc_is_known_never_inf_or_nan(src) && kfpc_is_known_never_logical_zero(src, m) kfpc_known_not(*k, FC_NAN);
    else if kfpc_is_known_never(src, FC_SNAN) kfpc_known_not(*k, FC_SNAN);
    return k;
}
kfpc_fma :: (l: Known_FP_Class, r: Known_FP_Class, a: Known_FP_Class, m: Denorm_Mode = DM_DYNAMIC) -> Known_FP_Class {
    return kfpc_fadd_impl(kfpc_fmul(l, r, m), a, m);
}
kfpc_fma_square :: (sq: Known_FP_Class, a: Known_FP_Class, m: Denorm_Mode = DM_DYNAMIC) -> Known_FP_Class {
    s := kfpc_square(sq, m);
    k := kfpc_fadd_impl(s, a, m);
    if kfpc_is_known_never(a, FC_NEG_INF | FC_NAN) && kfpc_is_known_never(s, FC_NAN) kfpc_known_not(*k, FC_NAN);
    return k;
}
kfpc_exp :: (src: Known_FP_Class) -> Known_FP_Class {
    k: Known_FP_Class;
    kfpc_known_not(*k, FC_NEGATIVE);
    kfpc_propagate_nan(*k, src);
    if kfpc_cannot_be_ordered_less_than_zero(src) { kfpc_known_not(*k, FC_POS_ZERO); kfpc_known_not(*k, FC_POS_SUBNORMAL); }
    if kfpc_cannot_be_ordered_greater_than_zero(src) kfpc_known_not(*k, FC_POS_INF);
    return k;
}
kfpc_log :: (src: Known_FP_Class, m: Denorm_Mode = DM_DYNAMIC) -> Known_FP_Class {
    k: Known_FP_Class;
    kfpc_known_not(*k, FC_NEG_ZERO | FC_SUBNORMAL);
    if kfpc_is_known_never_pos_infinity(src) kfpc_known_not(*k, FC_POS_INF);
    if kfpc_is_known_never_nan(src) && kfpc_cannot_be_ordered_less_than_zero(src) kfpc_known_not(*k, FC_NAN);
    if kfpc_is_known_never_logical_zero(src, m) kfpc_known_not(*k, FC_NEG_INF);
    return k;
}
kfpc_sqrt :: (src: Known_FP_Class, m: Denorm_Mode = DM_DYNAMIC) -> Known_FP_Class {
    k: Known_FP_Class;
    kfpc_known_not(*k, FC_POS_SUBNORMAL);
    if kfpc_is_known_never_pos_infinity(src) kfpc_known_not(*k, FC_POS_INF);
    if kfpc_is_known_never(src, FC_SNAN) kfpc_known_not(*k, FC_SNAN);
    if kfpc_is_known_never_nan(src) && kfpc_cannot_be_ordered_less_than_zero(src) kfpc_known_not(*k, FC_NAN);
    kfpc_known_not(*k, FC_NEG_INF | FC_NEG_SUBNORMAL | FC_NEG_NORMAL);
    if kfpc_is_known_never_logical_neg_zero(src, m) kfpc_known_not(*k, FC_NEG_ZERO);
    return k;
}
kfpc_sin :: (src: Known_FP_Class) -> Known_FP_Class {
    k: Known_FP_Class;
    kfpc_known_not(*k, FC_INF);
    if kfpc_is_known_never_nan(src) && kfpc_is_known_never_infinity(src) kfpc_known_not(*k, FC_NAN);
    return k;
}
kfpc_sinh :: (src: Known_FP_Class) -> Known_FP_Class {
    k: Known_FP_Class;
    if kfpc_is_known_never(src, FC_NEGATIVE) kfpc_known_not(*k, FC_NEGATIVE);
    kfpc_propagate_nan(*k, src);
    return k;
}
kfpc_cosh :: (src: Known_FP_Class) -> Known_FP_Class {
    k: Known_FP_Class;
    kfpc_known_not(*k, FC_NEGATIVE);
    kfpc_propagate_nan(*k, src);
    return k;
}
kfpc_tanh :: (src: Known_FP_Class) -> Known_FP_Class {
    k: Known_FP_Class;
    kfpc_known_not(*k, FC_INF);
    if kfpc_is_known_never(src, FC_NEGATIVE) kfpc_known_not(*k, FC_NEGATIVE);
    kfpc_propagate_nan(*k, src);
    return k;
}
kfpc_asin :: (src: Known_FP_Class) -> Known_FP_Class {
    k: Known_FP_Class;
    kfpc_known_not(*k, FC_INF);
    if kfpc_is_known_never(src, FC_NEGATIVE) kfpc_known_not(*k, FC_NEGATIVE);
    return k;
}
kfpc_acos :: (src: Known_FP_Class) -> Known_FP_Class {
    k: Known_FP_Class;
    kfpc_known_not(*k, FC_INF);
    kfpc_known_not(*k, FC_NEGATIVE);
    return k;
}
kfpc_atan :: (src: Known_FP_Class) -> Known_FP_Class { return kfpc_tanh(src); }
kfpc_atan2 :: (l: Known_FP_Class, r: Known_FP_Class) -> Known_FP_Class {
    k: Known_FP_Class;
    kfpc_known_not(*k, FC_INF);
    if kfpc_is_known_never_nan(l) && kfpc_is_known_never_nan(r) kfpc_known_not(*k, FC_NAN);
    return k;
}
// APFloat::isRepresentableAsNormalIn
apf_is_representable_as_normal_in :: (src: Type_Kind, dst: Type_Kind) -> bool {
    ps, emaxs, emins, bs := fp_semantics(src);
    pd, emaxd, emind, bd := fp_semantics(dst);
    // every finite value of Src (including its denormals) must be a normal in Dst
    min_src := cast(s64) emins - (ps - 1);
    return cast(s64) emaxs <= emaxd && min_src >= emind && ps <= pd;
}
kfpc_fpext :: (src: Known_FP_Class, dst: Type_Kind, srck: Type_Kind) -> Known_FP_Class {
    k := src;
    if apf_is_representable_as_normal_in(srck, dst) {
        if k.known_fp_classes & FC_POS_SUBNORMAL k.known_fp_classes |= FC_POS_NORMAL;
        if k.known_fp_classes & FC_NEG_SUBNORMAL k.known_fp_classes |= FC_NEG_NORMAL;
        kfpc_known_not(*k, FC_SUBNORMAL);
    }
    if !kfpc_is_known_never_nan(k) k.sign_bit = -1;
    return k;
}
kfpc_fptrunc :: (src: Known_FP_Class) -> Known_FP_Class {
    k: Known_FP_Class;
    if kfpc_cannot_be_ordered_less_than_zero(src) kfpc_known_not(*k, KFPC_ORDERED_LESS_THAN_ZERO_MASK);
    kfpc_propagate_nan(*k, src, true);
    return k;
}
kfpc_round_to_integral :: (src: Known_FP_Class, is_trunc: bool, is_multi_unit: bool) -> Known_FP_Class {
    k: Known_FP_Class;
    kfpc_known_not(*k, FC_SUBNORMAL);
    kfpc_propagate_nan(*k, src, true);
    if is_trunc || !is_multi_unit {
        if kfpc_is_known_never_pos_infinity(src) kfpc_known_not(*k, FC_POS_INF);
        if kfpc_is_known_never_neg_infinity(src) kfpc_known_not(*k, FC_NEG_INF);
    }
    if kfpc_is_known_never(src, FC_POS_FINITE) kfpc_known_not(*k, FC_POS_FINITE);
    if kfpc_is_known_never(src, FC_NEG_FINITE) kfpc_known_not(*k, FC_NEG_FINITE);
    return k;
}
kfpc_frexp_mant :: (src: Known_FP_Class, m: Denorm_Mode = DM_DYNAMIC) -> Known_FP_Class {
    k: Known_FP_Class;
    kfpc_known_not(*k, FC_SUBNORMAL);
    if kfpc_is_known_never(src, FC_NEGATIVE) kfpc_known_not(*k, FC_NEGATIVE);
    else {
        if kfpc_is_known_never_logical_neg_zero(src, m) kfpc_known_not(*k, FC_NEG_ZERO);
        if kfpc_is_known_never(src, FC_NEG_INF) kfpc_known_not(*k, FC_NEG_INF);
    }
    if kfpc_is_known_never(src, FC_POSITIVE) kfpc_known_not(*k, FC_POSITIVE);
    else {
        if kfpc_is_known_never_logical_pos_zero(src, m) kfpc_known_not(*k, FC_POS_ZERO);
        if kfpc_is_known_never(src, FC_POS_INF) kfpc_known_not(*k, FC_POS_INF);
    }
    kfpc_propagate_nan(*k, src);
    return k;
}
kfpc_ldexp :: (src: Known_FP_Class, exp_min: APInt, exp_max: APInt, fk: Type_Kind, m: Denorm_Mode = DM_DYNAMIC) -> Known_FP_Class {
    k: Known_FP_Class;
    kfpc_propagate_nan(*k, src, true);
    if kfpc_is_known_never(src, FC_NEGATIVE) kfpc_known_not(*k, FC_NEGATIVE);
    else if kfpc_cannot_be_ordered_less_than_zero(src) kfpc_known_not(*k, KFPC_ORDERED_LESS_THAN_ZERO_MASK);
    if kfpc_is_known_never(src, FC_POSITIVE) kfpc_known_not(*k, FC_POSITIVE);
    else if kfpc_cannot_be_ordered_greater_than_zero(src) kfpc_known_not(*k, KFPC_ORDERED_GREATER_THAN_ZERO_MASK);
    p, mx, mn, b := fp_semantics(fk);
    mantissa_bits := cast(s64) p - 1;
    if ap_sext_value(exp_min) >= mantissa_bits kfpc_known_not(*k, FC_SUBNORMAL);
    if ap_is_zero(exp_min) && ap_is_zero(exp_max) kfpc_propagate_canonicalizing_src(*k, src, m);
    else if ap_is_non_positive(exp_max) {
        if kfpc_is_known_never_pos_infinity(src) kfpc_known_not(*k, FC_POS_INF);
        if kfpc_is_known_never_neg_infinity(src) kfpc_known_not(*k, FC_NEG_INF);
    } else if ap_is_non_negative(exp_min) {
        if kfpc_is_known_never_pos_subnormal(src) kfpc_known_not(*k, FC_POS_SUBNORMAL);
        if kfpc_is_known_never_neg_subnormal(src) kfpc_known_not(*k, FC_NEG_SUBNORMAL);
        if kfpc_is_known_never_logical_pos_zero(src, m) kfpc_known_not(*k, FC_POS_ZERO);
        if kfpc_is_known_never_logical_neg_zero(src, m) kfpc_known_not(*k, FC_NEG_ZERO);
    }
    return k;
}
kfpc_powi :: (src: Known_FP_Class, e: Known_Bits) -> Known_FP_Class {
    k: Known_FP_Class;
    kfpc_propagate_nan(*k, src);
    if kb_is_zero(e) {
        if kfpc_is_known_never(src, FC_SNAN) { kfpc_known_not(*k, fc_not(FC_POS_NORMAL)); return k; }
        kfpc_known_not(*k, fc_not(FC_POS_NORMAL | FC_NAN));
        return k;
    }
    {
        min_e := kb_signed_min_value(e); max_e := kb_signed_max_value(e);
        w := min_e.bits;
        may_inf_src := !kfpc_is_known_never(src, FC_INF) && ap_is_strictly_positive(max_e);
        may_div_by_zero := !kfpc_is_known_never(src, FC_ZERO) && ap_is_negative(min_e);
        may_finite := !kfpc_is_known_never(src, FC_NORMAL | FC_SUBNORMAL);
        may_abs_gt1 := ap_sext_value(min_e) < -1 || ap_sext_value(max_e) > 1;
        may_finite_overflow := may_finite && may_abs_gt1;
        may_be_neg_one := ap_is_zero(e.zero);
        may_subnorm_inv := !kfpc_is_known_never(src, FC_SUBNORMAL) && may_be_neg_one;
        if !may_inf_src && !may_div_by_zero && !may_finite_overflow && !may_subnorm_inv kfpc_known_not(*k, FC_INF);
    }
    if kb_is_even(e) { kfpc_known_not(*k, FC_NEGATIVE); return k; }
    if kfpc_is_known_never(src, FC_NEGATIVE) kfpc_known_not(*k, FC_NEGATIVE);
    return k;
}

// ---------------------------------------------------------------- fcmpImpliesClass / fcmpToClassTest

// (value or NONE, class if true, class if false)
fcmp_implies_class_mask :: (pred: u8, f: Value_Id, lhs: Value_Id, rhs_class_in: u32, look_through_src := true) -> (Value_Id, u32, u32) {
    exact :: (v: Value_Id, m: u32) -> (Value_Id, u32, u32) { return v, m, fc_not(m); }
    rhs_class := rhs_class_in;
    src := lhs;
    if pred == FCMP_TRUE { a, b, c := exact(src, FC_ALL_FLAGS); return a, b, c; }
    if pred == FCMP_FALSE { a, b, c := exact(src, FC_NONE); return a, b, c; }
    orig := rhs_class;
    is_neg_rhs := (rhs_class & FC_NEGATIVE) == rhs_class;
    is_pos_rhs := (rhs_class & FC_POSITIVE) == rhs_class;
    is_nan := (rhs_class & ~cast(u32) FC_NAN) == FC_NONE;
    if is_nan { a, b, c := exact(src, ifx cmp_is_ordered(pred) then cast(u32) FC_NONE else FC_ALL_FLAGS); return a, b, c; }
    if pred == FCMP_ORD { a, b, c := exact(src, fc_not(FC_NAN)); return a, b, c; }
    if pred == FCMP_UNO { a, b, c := exact(src, FC_NAN); return a, b, c; }
    is_fabs := false;
    if look_through_src && call_iid(lhs) == IID_FABS { src = op(lhs, 0); is_fabs = true; }
    if is_fabs rhs_class = fc_inverse_fabs(rhs_class);
    is_zero := (orig & FC_ZERO) == orig;
    if is_zero {
        m := dm_of_fn(f, vtype(lhs));
        if m.input != DENORMAL_IEEE return NONE, FC_ALL_FLAGS, FC_ALL_FLAGS;
        ec :: (v: Value_Id, m: u32, is_fabs: bool) -> (Value_Id, u32, u32) { mm := m; if is_fabs mm = fc_inverse_fabs(mm); return v, mm, fc_not(mm); }
        if pred == {
            case FCMP_OEQ; a, b, c := exact(src, FC_ZERO); return a, b, c;
            case FCMP_UEQ; a, b, c := exact(src, FC_ZERO | FC_NAN); return a, b, c;
            case FCMP_UNE; a, b, c := exact(src, fc_not(FC_ZERO)); return a, b, c;
            case FCMP_ONE; a, b, c := exact(src, fc_not(FC_NAN) & fc_not(FC_ZERO)); return a, b, c;
            case FCMP_OGT; a, b, c := ec(src, FC_POS_SUBNORMAL | FC_POS_NORMAL | FC_POS_INF, is_fabs); return a, b, c;
            case FCMP_UGT; a, b, c := ec(src, FC_POS_SUBNORMAL | FC_POS_NORMAL | FC_POS_INF | FC_NAN, is_fabs); return a, b, c;
            case FCMP_OGE; a, b, c := ec(src, FC_POSITIVE | FC_NEG_ZERO, is_fabs); return a, b, c;
            case FCMP_UGE; a, b, c := ec(src, FC_POSITIVE | FC_NEG_ZERO | FC_NAN, is_fabs); return a, b, c;
            case FCMP_OLT; a, b, c := ec(src, FC_NEG_SUBNORMAL | FC_NEG_NORMAL | FC_NEG_INF, is_fabs); return a, b, c;
            case FCMP_ULT; a, b, c := ec(src, FC_NEG_SUBNORMAL | FC_NEG_NORMAL | FC_NEG_INF | FC_NAN, is_fabs); return a, b, c;
            case FCMP_OLE; a, b, c := ec(src, FC_NEGATIVE | FC_POS_ZERO, is_fabs); return a, b, c;
            case FCMP_ULE; a, b, c := ec(src, FC_NEGATIVE | FC_POS_ZERO | FC_NAN, is_fabs); return a, b, c;
        }
        fatal("internal: fcmpImpliesClass: unexpected predicate");
    }
    is_denormal_rhs := (orig & FC_SUBNORMAL) == orig;
    is_inf := (orig & FC_INF) == orig;
    if is_inf {
        mask: u32 = FC_ALL_FLAGS;
        if pred == {
            case FCMP_OEQ; #through; case FCMP_UNE;
                if is_neg_rhs { mask = FC_NEG_INF; if is_fabs mask = FC_NONE; }
                else { mask = FC_POS_INF; if is_fabs mask |= FC_NEG_INF; }
            case FCMP_ONE; #through; case FCMP_UEQ;
                if is_neg_rhs { mask = fc_not(FC_NEG_INF) & fc_not(FC_NAN); if is_fabs mask = fc_not(FC_NAN); }
                else { mask = fc_not(FC_POS_INF) & fc_not(FC_NAN); if is_fabs mask &= fc_not(FC_NEG_INF); }
            case FCMP_OLT; #through; case FCMP_UGE;
                if is_neg_rhs mask = FC_NONE;
                else { mask = FC_FINITE; if !is_fabs mask |= FC_NEG_INF; }
            case FCMP_OGE; #through; case FCMP_ULT;
                if is_neg_rhs mask = fc_not(FC_NAN);
                else { mask = FC_POS_INF; if is_fabs mask |= FC_NEG_INF; }
            case FCMP_OGT; #through; case FCMP_ULE;
                if is_neg_rhs mask = ifx is_fabs then fc_not(FC_NAN) else fc_not(FC_NEG_INF | FC_NAN);
                else mask = FC_NONE;
            case FCMP_OLE; #through; case FCMP_UGT;
                if is_neg_rhs mask = ifx is_fabs then cast(u32) FC_NONE else FC_NEG_INF;
                else mask = fc_not(FC_NAN);
            case; fatal("internal: fcmpImpliesClass: unexpected predicate");
        }
        if cmp_is_unordered(pred) mask = fc_not(mask);
        a, b, c := exact(src, mask); return a, b, c;
    }
    if pred == FCMP_OEQ return src, rhs_class, FC_ALL_FLAGS;
    if pred == FCMP_UEQ return src, rhs_class | FC_NAN, fc_not(FC_NAN);
    if pred == FCMP_ONE return src, fc_not(FC_NAN), rhs_class | FC_NAN;
    if pred == FCMP_UNE return src, FC_ALL_FLAGS, rhs_class;
    if is_neg_rhs {
        if is_fabs {
            if pred == {
                case FCMP_OGT; #through; case FCMP_OGE; return src, fc_not(FC_NAN), FC_NAN;
                case FCMP_UGT; #through; case FCMP_UGE; return src, FC_ALL_FLAGS, FC_NONE;
                case FCMP_OLT; #through; case FCMP_OLE; return src, FC_NONE, FC_ALL_FLAGS;
                case FCMP_ULT; #through; case FCMP_ULE; return src, FC_NAN, fc_not(FC_NAN);
            }
            return NONE, FC_ALL_FLAGS, FC_ALL_FLAGS;
        }
        le: u32 = FC_NEG_INF | FC_NEG_NORMAL;
        ge: u32 = FC_POSITIVE | FC_NEG_ZERO | FC_NEG_SUBNORMAL;
        if is_denormal_rhs le |= FC_NEG_SUBNORMAL; else ge |= FC_NEG_NORMAL;
        if pred == {
            case FCMP_OGT; #through; case FCMP_OGE; return src, ge, fc_not(ge) | rhs_class;
            case FCMP_UGT; #through; case FCMP_UGE; return src, ge | FC_NAN, fc_not(ge | FC_NAN) | rhs_class;
            case FCMP_OLT; #through; case FCMP_OLE; return src, le, fc_not(le) | rhs_class;
            case FCMP_ULT; #through; case FCMP_ULE; return src, le | FC_NAN, fc_not(le | FC_NAN) | rhs_class;
        }
    } else if is_pos_rhs {
        ge: u32 = FC_POS_NORMAL | FC_POS_INF;
        le: u32 = FC_NEGATIVE | FC_POS_ZERO | FC_POS_SUBNORMAL;
        if is_denormal_rhs ge |= FC_POS_SUBNORMAL; else le |= FC_POS_NORMAL;
        if is_fabs { ge = fc_inverse_fabs(ge); le = fc_inverse_fabs(le); }
        if pred == {
            case FCMP_OGT; #through; case FCMP_OGE; return src, ge, fc_not(ge) | rhs_class;
            case FCMP_UGT; #through; case FCMP_UGE; return src, ge | FC_NAN, fc_not(ge | FC_NAN) | rhs_class;
            case FCMP_OLT; #through; case FCMP_OLE; return src, le, fc_not(le) | rhs_class;
            case FCMP_ULT; #through; case FCMP_ULE; return src, le | FC_NAN, fc_not(le | FC_NAN) | rhs_class;
        }
    }
    return NONE, FC_ALL_FLAGS, FC_ALL_FLAGS;
}
// APFloat::isSmallestNormalized
apf_is_smallest_normalized :: (c: APFloat) -> bool {
    g := c;
    if g.k == .PPC_FP128 return dd_is_smallest_normalized(apf_words(*g));
    d := fp_decode(c.k, apf_words(*g));
    if d.cat != .NORMAL || apf_is_denormal(c) return false;
    p, emax, emin, b := fp_semantics(c.k);
    return d.exp == emin && !big_any_below(d.sig, p - 1);
}
fcmp_implies_class :: (pred: u8, f: Value_Id, lhs: Value_Id, c: APFloat, look_through_src := true) -> (Value_Id, u32, u32) {
    if !apf_is_negative(c) && apf_is_smallest_normalized(c) {
        src := lhs;
        is_fabs := false;
        if look_through_src && call_iid(lhs) == IID_FABS { src = op(lhs, 0); is_fabs = true; }
        mask: u32;
        if pred == FCMP_OLT || pred == FCMP_UGE {
            mask = FC_ZERO | FC_SUBNORMAL;
            if !is_fabs mask |= FC_NEG_NORMAL | FC_NEG_INF;
        } else if pred == FCMP_OGE || pred == FCMP_ULT {
            mask = FC_POS_INF | FC_POS_NORMAL;
            if is_fabs mask |= FC_NEG_INF | FC_NEG_NORMAL;
        } else {
            a, b, cc := fcmp_implies_class_mask(pred, f, lhs, apf_classify(c), look_through_src);
            return a, b, cc;
        }
        if cmp_is_unordered(pred) mask = fc_not(mask);
        return src, mask, fc_not(mask);
    }
    a, b, cc := fcmp_implies_class_mask(pred, f, lhs, apf_classify(c), look_through_src);
    return a, b, cc;
}
// fcmpToClassTest: (class value or NONE, class test)
fcmp_to_class_test :: (pred: u8, f: Value_Id, lhs: Value_Id, c: APFloat, look_through_src := true) -> (Value_Id, u32) {
    src, if_true, if_false := fcmp_implies_class(pred, f, lhs, c, look_through_src);
    if src != NONE && if_true == fc_not(if_false) return src, if_true;
    return NONE, FC_ALL_FLAGS;
}

// ---------------------------------------------------------------- computeKnownFPClass

// computeKnownFPClassFromCond
compute_known_fp_class_from_cond :: (v: Value_Id, cond: Value_Id, cond_is_true: bool, cxt: Value_Id, known: *Known_FP_Class, depth: u32 = 0) {
    if depth < MAX_ANALYSIS_RECURSION_DEPTH {
        ok: bool; a, b: Value_Id;
        if cond_is_true { ok, a, b = pm_logical_and(cond); } else { ok, a, b = pm_logical_or(cond); }
        if ok {
            compute_known_fp_class_from_cond(v, a, cond_is_true, cxt, known, depth + 1);
            compute_known_fp_class_from_cond(v, b, cond_is_true, cxt, known, depth + 1);
            return;
        }
        okn, x := pm_not(cond);
        if okn { compute_known_fp_class_from_cond(v, x, !cond_is_true, cxt, known, depth + 1); return; }
    }
    okf, pred, lhs, rhs := pm_fcmp(cond);
    if okf {
        okc, c := pm_apfloat(rhs);
        if okc {
            cmp_val, if_true, if_false := fcmp_implies_class(pred, inst_fn(cond), lhs, c, lhs != v);
            if cmp_val == v kfpc_known_not(known, fc_not(ifx cond_is_true then if_true else if_false));
            return;
        }
    }
    if call_iid(cond) == IID_IS_FPCLASS && op(cond, 0) == v && vkind(op(cond, 1)) == .C_INT && !is_vector_type(vtype(op(cond, 1))) {
        mask := cast(u32) ap_zext_value(cf_ap(op(cond, 1)));
        kfpc_known_not(known, ifx cond_is_true then fc_not(mask) else mask);
        return;
    }
    oki, ipred, sb, il, ir := pm_icmp(cond);
    if oki {
        okb, src := fpc_elementwise_bitcast_inst(il);
        if okb && src == v {
            oka, rc := pm_apint(ir);
            if oka {
                is_check, true_if_signed := is_sign_bit_check(ipred, rc);
                if !is_check return;
                if true_if_signed == cond_is_true kfpc_sign_bit_must_be_one(known);
                else kfpc_sign_bit_must_be_zero(known);
            }
        }
    }
}
// m_ElementWiseBitCast (a BitCastInst only, same scalar/vector shape and element count)
fpc_elementwise_bitcast_inst :: (v: Value_Id) -> (bool, Value_Id) {
    if !is_inst(v) || inst_op(v) != .BITCAST return false, NONE;
    st := vtype(op(v, 0)); dt := vtype(v);
    if is_vector_type(st) != is_vector_type(dt) return false, NONE;
    if is_vector_type(st) && (type_count(st) != type_count(dt) || type_kind(st) != type_kind(dt)) return false, NONE;
    return true, op(v, 0);
}
// computeKnownFPClassFromContext (no CondContext)
compute_known_fp_class_from_context :: (v: Value_Id, q: Simplify_Query) -> Known_FP_Class {
    known: Known_FP_Class;
    if q.cc && cc_affects(q.cc, v) compute_known_fp_class_from_cond(v, q.cc.cond, !q.cc.invert, q.cxt, *known);
    if q.cxt == NONE return known;
    if q.dc && q.dt {
        cb := inst_block(q.cxt);
        for br: dc_conditions_for(q.dc, v) {
            if vkind(br) == .DEAD continue;
            c := op(br, 0); bb := inst_block(br);
            if dt_dominates_edge_block(q.dt, bb, get_successor(br, 0), cb) compute_known_fp_class_from_cond(v, c, true, q.cxt, *known);
            if dt_dominates_edge_block(q.dt, bb, get_successor(br, 1), cb) compute_known_fp_class_from_cond(v, c, false, q.cxt, *known);
        }
    }
    if q.ac == null return known;
    for ac_assumptions_for(q.ac, v) {
        a := it.assume;
        if a == NONE || vkind(a) != .INST continue;
        if !is_valid_assume_for_context(a, q.cxt, q.dt, q.allow_ephemerals) continue;
        compute_known_fp_class_from_cond(v, op(a, 0), true, q.cxt, *known);
    }
    return known;
}
// adjustKnownFPClassForSelectArm
adjust_known_fp_class_for_select_arm :: (known: *Known_FP_Class, cond: Value_Id, arm: Value_Id, invert: bool, q: Simplify_Query, depth: u32) {
    src: Known_FP_Class;
    compute_known_fp_class_from_cond(arm, cond, !invert, q.cxt, *src, depth + 1);
    src = kfpc_union_with(src, known.*);
    if kfpc_is_unknown(src) return;
    if is_guaranteed_not_to_be_undef(arm, q.ac, q.cxt, q.dt, depth + 1) known.* = src;
}

// CallBase::getRetNoFPClass / Argument::getNoFPClass
fpc_ret_no_fp_class :: (c: Value_Id) -> u32 {
    m: u32 = 0;
    a := attr_set_find(attr_list_ret(inst(c).attrs), .NoFPClass);
    if a m |= cast(u32) a.ival;
    f := call_called_function(c);
    if f != NONE { b := attr_set_find(attr_list_ret(glob(f).attrs), .NoFPClass); if b m |= cast(u32) b.ival; }
    return m;
}
fpc_arg_no_fp_class :: (a: Value_Id) -> u32 {
    at := attr_set_find(arg_attrs(a), .NoFPClass);
    if at return cast(u32) at.ival;
    return 0;
}
fpc_min_max_kind :: (id: Intrinsic_Id) -> u8 {
    if id == {
        case IID_MINIMUM; return MM_MINIMUM;
        case IID_MAXIMUM; return MM_MAXIMUM;
        case IID_MINIMUMNUM; return MM_MINIMUMNUM;
        case IID_MAXIMUMNUM; return MM_MAXIMUMNUM;
        case IID_MINNUM; return MM_MINNUM;
        case IID_MAXNUM; return MM_MAXNUM;
    }
    fatal("internal: not a floating-point min-max intrinsic");
    return 0;
}
// isAbsoluteValueULEOne (the amdgcn intrinsics never appear on x86 IR)
fpc_is_absolute_value_ule_one :: (v: Value_Id) -> bool {
    if opr_code(v) != .FSUB return false;
    x := op(v, 0);
    f := op(v, 1);
    return call_iid(f) == IID_FLOOR && op(f, 0) == x;
}
// m_c_MaxOrMin(m_BitCast(m_Value(A)), m_BitCast(m_Value(B))): in LLVM 23 m_SMax & co. match only the intrinsics
fpc_max_or_min_of_bitcasts :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
    id := call_iid(v);
    if !(id == IID_SMAX || id == IID_SMIN || id == IID_UMAX || id == IID_UMIN) return false, NONE, NONE;
    l := op(v, 0); r := op(v, 1);
    bc :: (x: Value_Id) -> (bool, Value_Id) { if opr_code(x) != .BITCAST return false, NONE; return true, op(x, 0); }
    ok1, a := bc(l); ok2, b := bc(r);
    if ok1 && ok2 return true, a, b;
    return false, NONE, NONE;
}
// matchSimpleTernaryIntrinsicRecurrence: (ok, phi, init, other0, other1)
match_simple_ternary_intrinsic_recurrence :: (ii: Value_Id) -> (bool, Value_Id, Value_Id, Value_Id, Value_Id) {
    if call_num_args(ii) != 3 return false, NONE, NONE, NONE, NONE;
    t := vtype(ii);
    for i: 0..2 if vtype(op(ii, cast(u32) i)) != t return false, NONE, NONE, NONE, NONE;
    p := op(ii, 0);
    if !is_phi(p) { p = op(ii, 1); if !is_phi(p) p = op(ii, 2); }
    if !is_phi(p) || nops(p) != 2 return false, NONE, NONE, NONE, NONE;
    for i: 0..1 {
        operation := phi_value(p, cast(u32) i);
        if !is_inst(operation) || call_iid(operation) == NOT_INTRINSIC || call_num_args(operation) + 1 < 3 continue;
        o0 := op(operation, 0); o1 := op(operation, 1); o2 := op(operation, 2);
        if o0 != p && o1 != p && o2 != p continue;
        if operation != ii return false, NONE, NONE, NONE, NONE;
        init := phi_value(p, cast(u32)(1 - i));
        if o0 == p return true, p, init, o1, o2;
        if o1 == p return true, p, init, o0, o2;
        return true, p, init, o0, o1;
    }
    return false, NONE, NONE, NONE, NONE;
}

compute_known_fp_class_de :: (v: Value_Id, de: APInt, interested_in: u32, q: Simplify_Query, depth: u32) -> Known_FP_Class {
    known: Known_FP_Class;
    fpc_compute(v, de, interested_in, *known, q, depth);
    return known;
}
compute_known_fp_class :: (v: Value_Id, interested: u32, q: Simplify_Query, depth: u32 = 0) -> Known_FP_Class {
    return compute_known_fp_class_de(v, dem_all(vtype(v)), interested, q, depth);
}
// computeKnownFPClass(V, DemandedElts, FMF, ...)
compute_known_fp_class_de_fmf :: (v: Value_Id, de: APInt, fmf: u32, interested_in: u32, q: Simplify_Query, depth: u32 = 0) -> Known_FP_Class {
    interested := interested_in;
    if fmf & FMF_NNAN interested &= ~cast(u32) FC_NAN;
    if fmf & FMF_NINF interested &= ~cast(u32) FC_INF;
    r := compute_known_fp_class_de(v, de, interested, q, depth);
    if fmf & FMF_NNAN r.known_fp_classes &= ~cast(u32) FC_NAN;
    if fmf & FMF_NINF r.known_fp_classes &= ~cast(u32) FC_INF;
    return r;
}
compute_known_fp_class_fmf :: (v: Value_Id, fmf: u32, interested: u32, q: Simplify_Query, depth: u32 = 0) -> Known_FP_Class {
    return compute_known_fp_class_de_fmf(v, dem_all(vtype(v)), fmf, interested, q, depth);
}
// cannotBeNegativeZero
cannot_be_negative_zero :: (v: Value_Id, q: Simplify_Query, depth: u32 = 0) -> bool {
    k := compute_known_fp_class(v, FC_NEG_ZERO, q, depth);
    return kfpc_is_known_never_neg_zero(k);
}

// static computeKnownFPClass(V, DemandedElts, InterestedClasses, Known, Q, Depth)
fpc_compute :: (v: Value_Id, de: APInt, interested_in: u32, known: *Known_FP_Class, q: Simplify_Query, depth: u32) {
    if ap_is_zero(de) { known.* = .{}; return; }
    k := vkind(v);
    t := vtype(v);
    if k == .C_FP && !is_vector_type(t) { known.* = kfpc_from_apfloat(apf_from_const(v)); return; }
    if k == .C_FP {
        // a ConstantFP splat vector
        known.* = kfpc_from_apfloat(apf_from_const(v));
        if type_kind(t) == .VECTOR {
            // the fixed-vector constant path below: same answer for a splat
        }
        return;
    }
    if k == .C_ZERO { known.known_fp_classes = FC_POS_ZERO; known.sign_bit = 0; return; }
    if k == .C_POISON { known.known_fp_classes = FC_NONE; known.sign_bit = 0; return; }
    if type_kind(t) == .VECTOR && is_constant_kind(k) {
        known.known_fp_classes = FC_NONE;
        all_zero := true; all_one := true;
        n := type_count(t);
        for i: 0..cast(s64) n - 1 {
            if !ap_get_bit(de, cast(u32) i) continue;
            e := cf_elt(v, cast(u64) i);
            if e == NONE { known.* = .{}; return; }
            if vkind(e) == .C_POISON continue;
            if vkind(e) != .C_FP { known.* = .{}; return; }
            c := apf_from_const(e);
            known.known_fp_classes |= apf_classify(c);
            if apf_is_negative(c) all_zero = false; else all_one = false;
        }
        if all_one != all_zero known.sign_bit = ifx all_one then cast(s8) 1 else 0;
        return;
    }
    if k == .C_DATA {
        known.known_fp_classes = FC_NONE;
        n := const_data_count(v);
        for i: 0..cast(s64) n - 1 {
            e := cf_elt(v, cast(u64) i);
            if e == NONE || vkind(e) != .C_FP { known.* = .{}; return; }
            known.* = kfpc_or(known.*, kfpc_make(apf_classify(apf_from_const(e))));
        }
        return;
    }
    if k == .C_ARRAY || k == .C_STRUCT || k == .C_VECTOR {
        known.known_fp_classes = FC_NONE;
        n := nops(v);
        for i: 0..cast(s64) n - 1 {
            e := op(v, cast(u32) i);
            if vkind(e) != .C_FP { known.* = .{}; return; }
            known.* = kfpc_or(known.*, kfpc_make(apf_classify(apf_from_const(e))));
        }
        return;
    }

    known_not_from_flags: u32 = FC_NONE;
    if is_inst(v) && is_call_base(v) known_not_from_flags |= fpc_ret_no_fp_class(v);
    else if k == .ARGUMENT known_not_from_flags |= fpc_arg_no_fp_class(v);
    is_op := is_inst(v) || k == .C_EXPR;
    if is_op && is_fp_math_operator(v) {
        fmf := opr_fmf(v);
        if fmf & FMF_NNAN known_not_from_flags |= FC_NAN;
        if fmf & FMF_NINF known_not_from_flags |= FC_INF;
    }
    assumed := compute_known_fp_class_from_context(v, q);
    known_not_from_flags |= fc_not(assumed.known_fp_classes);
    interested := interested_in & ~known_not_from_flags;

    fpc_compute_op(v, de, interested, known, q, depth, known_not_from_flags, is_op);

    // scope_exit ClearClassesFromFlags
    kfpc_known_not(known, known_not_from_flags);
    if known.sign_bit < 0 && assumed.sign_bit >= 0 {
        if assumed.sign_bit == 1 kfpc_sign_bit_must_be_one(known); else kfpc_sign_bit_must_be_zero(known);
    }
}
// FPMathOperator fast-math flags of an instruction or constant expression
opr_fmf :: (v: Value_Id) -> u32 { if is_inst(v) return inst_fmf(v); return 0; }

fpc_compute_op :: (v: Value_Id, de: APInt, interested: u32, known: *Known_FP_Class, q: Simplify_Query, depth: u32, known_not_from_flags: u32, is_op: bool) {
    if !is_op return;
    if depth == MAX_ANALYSIS_RECURSION_DEPTH return;
    opc := opr_code(v);
    st := scalar_type(vtype(v));
    if opc == {
        case .FNEG;
            fpc_compute(op(v, 0), de, interested, known, q, depth + 1);
            known.* = kfpc_fneg(known.*);
        case .SELECT;
            arm :: (v: Value_Id, a: Value_Id, invert: bool, de: APInt, interested: u32, q: Simplify_Query, depth: u32) -> Known_FP_Class {
                res: Known_FP_Class;
                fpc_compute(a, de, interested, *res, q, depth + 1);
                adjust_known_fp_class_for_select_arm(*res, op(v, 0), a, invert, q, depth);
                return res;
            }
            known.* = kfpc_intersect_with(arm(v, op(v, 1), false, de, interested, q, depth), arm(v, op(v, 2), true, de, interested, q, depth));
        case .LOAD;
            if !is_inst(v) return;
            md := get_metadata(v, md_fixed("nofpclass"));
            if md == NONE return;
            mv := ir.mds[md_op(md, 0)].value;
            kfpc_known_not(known, cast(u32) ap_zext_value(cf_ap(mv)));
        case .CALL;
            if !is_inst(v) return;
            fpc_compute_call(v, de, interested, known, q, depth, known_not_from_flags);
        case .FADD; #through;
        case .FSUB;
            want_negative := opc == .FADD && (interested & KFPC_ORDERED_LESS_THAN_ZERO_MASK) != FC_NONE;
            want_nan := (interested & FC_NAN) != FC_NONE;
            want_neg_zero := (interested & FC_NEG_ZERO) != FC_NONE;
            if !want_nan && !want_negative && !want_neg_zero return;
            srcs := interested;
            if want_negative srcs |= KFPC_ORDERED_LESS_THAN_ZERO_MASK;
            if interested & FC_NAN srcs |= FC_INF;
            kl, kr: Known_FP_Class;
            fpc_compute(op(v, 1), de, srcs, *kr, q, depth + 1);
            self := op(v, 0) == op(v, 1) && is_guaranteed_not_to_be_undef(op(v, 0), q.ac, q.cxt, q.dt, depth + 1);
            if self kl = kr;
            if (want_nan && kfpc_is_known_never_nan(kr)) || (want_negative && kfpc_cannot_be_ordered_less_than_zero(kr)) || want_neg_zero || opc == .FSUB {
                m := fpc_mode(v, st);
                if self && opc == .FADD known.* = kfpc_fadd_self(kl, m);
                else {
                    if !self fpc_compute(op(v, 0), de, srcs, *kl, q, depth + 1);
                    known.* = ifx opc == .FADD then kfpc_fadd(kl, kr, m) else kfpc_fsub(kl, kr, m);
                }
            }
        case .FMUL;
            m := fpc_mode(v, st);
            lhs := op(v, 0); rhs := op(v, 1);
            if lhs == rhs {
                src: Known_FP_Class;
                fpc_compute(lhs, de, FC_ALL_FLAGS, *src, q, depth + 1);
                known.* = kfpc_square(src, m);
                return;
            }
            kl, kr: Known_FP_Class;
            okc, c := pm_apfloat(rhs);
            if okc {
                fpc_compute(lhs, de, FC_ALL_FLAGS, *kl, q, depth + 1);
                known.* = kfpc_fmul_const(kl, c, m);
            } else {
                fpc_compute(rhs, de, FC_ALL_FLAGS, *kr, q, depth + 1);
                fpc_compute(lhs, de, FC_ALL_FLAGS, *kl, q, depth + 1);
                known.* = kfpc_fmul(kl, kr, m);
            }
            if kfpc_is_known_never(kl, FC_INF) && fpc_is_absolute_value_ule_one(rhs) kfpc_known_not(known, FC_INF);
            else if kfpc_is_known_never(kr, FC_INF) && fpc_is_absolute_value_ule_one(lhs) kfpc_known_not(known, FC_INF);
        case .FDIV; #through;
        case .FREM;
            want_nan := (interested & FC_NAN) != FC_NONE;
            if opc == .FREM kfpc_known_not(known, FC_INF);
            if op(v, 0) == op(v, 1) && is_guaranteed_not_to_be_undef(op(v, 0), q.ac, q.cxt, q.dt) {
                known.known_fp_classes = ifx opc == .FDIV then cast(u32)(FC_NAN | FC_POS_NORMAL) else FC_NAN | FC_ZERO;
                if !want_nan return;
                src: Known_FP_Class;
                fpc_compute(op(v, 0), de, FC_NAN | FC_INF | FC_ZERO | FC_SUBNORMAL, *src, q, depth + 1);
                m := fpc_mode(v, st);
                known.* = ifx opc == .FDIV then kfpc_fdiv_self(src, m) else kfpc_frem_self(src, m);
                return;
            }
            want_negative := (interested & FC_NEGATIVE) != FC_NONE;
            want_positive := opc == .FREM && (interested & FC_POSITIVE) != FC_NONE;
            if !want_nan && !want_negative && !want_positive return;
            kl, kr: Known_FP_Class;
            fpc_compute(op(v, 1), de, FC_NAN | FC_INF | FC_ZERO | FC_NEGATIVE, *kr, q, depth + 1);
            useful := kfpc_is_known_never_nan(kr) || kfpc_is_known_never(kr, FC_NEGATIVE) || kfpc_is_known_never(kr, FC_POSITIVE);
            if useful || want_positive fpc_compute(op(v, 0), de, FC_ALL_FLAGS, *kl, q, depth + 1);
            fn := ifx is_inst(v) && inst(v).parent != NONE then inst_fn(v) else NONE;
            if opc == .FDIV {
                known.* = kfpc_fdiv(kl, kr, fpc_mode(v, st));
            } else {
                if kfpc_is_known_never_nan(kl) && kfpc_is_known_never_nan(kr) && kfpc_is_known_never_infinity(kl) && fn != NONE &&
                   kfpc_is_known_never_logical_zero(kr, dm_of_fn(fn, st))
                    kfpc_known_not(known, FC_NAN);
                if kfpc_cannot_be_ordered_less_than_zero(kl) kfpc_known_not(known, KFPC_ORDERED_LESS_THAN_ZERO_MASK);
                if kfpc_cannot_be_ordered_greater_than_zero(kl) kfpc_known_not(known, KFPC_ORDERED_GREATER_THAN_ZERO_MASK);
                if kfpc_is_known_never(kl, FC_NEGATIVE) kfpc_known_not(known, FC_NEGATIVE);
                if kfpc_is_known_never(kl, FC_POSITIVE) kfpc_known_not(known, FC_POSITIVE);
            }
        case .FPEXT;
            src: Known_FP_Class;
            fpc_compute(op(v, 0), de, interested, *src, q, depth + 1);
            known.* = kfpc_fpext(src, type_kind(st), type_kind(scalar_type(vtype(op(v, 0)))));
        case .FPTRUNC;
            fpc_fptrunc(v, de, interested, known, q, depth);
        case .SITOFP; #through;
        case .UITOFP;
            kfpc_known_not(known, FC_NAN);
            kfpc_known_not(known, FC_SUBNORMAL);
            kfpc_known_not(known, FC_NEG_ZERO);
            if opc == .UITOFP kfpc_sign_bit_must_be_zero(known);
            if !(interested & (FC_POS_ZERO | FC_NORMAL | FC_INF)) return;
            ik := known_bits_de(op(v, 0), de, q, depth + 1);
            if kb_is_non_zero(ik) kfpc_known_not(known, FC_POS_ZERO);
            if opc == .SITOFP {
                if kb_is_non_negative(ik) kfpc_sign_bit_must_be_zero(known);
                else if kb_is_negative(ik) kfpc_sign_bit_must_be_one(known);
            }
            if interested & FC_INF {
                int_size := cast(s64) ik.zero.bits;
                if opc == .UITOFP int_size -= kb_count_min_leading_zeros(ik);
                else int_size -= kb_count_min_sign_bits(ik);
                fk := type_kind(st);
                if fp_ilogb(fk, fp_largest(fk, false)) >= int_size kfpc_known_not(known, FC_INF);
            }
        case .EXTRACTELEMENT;
            vec := op(v, 0);
            vt := vtype(vec);
            dv: APInt;
            if type_kind(vt) == .VECTOR {
                n := cast(u32) type_count(vt);
                dv = ap_all_ones(n);
                ci := op(v, 1);
                if vkind(ci) == .C_INT && !is_vector_type(vtype(ci)) {
                    c := cf_ap(ci);
                    if ap_active_bits(c) <= 64 && ap_zext_value(c) < cast(u64) n {
                        dv = ap_zero(n); ap_set_bit(*dv, cast(u32) ap_zext_value(c));
                    }
                }
            } else dv = ap_one(1);
            fpc_compute(vec, dv, interested, known, q, depth + 1);
        case .INSERTELEMENT;
            if type_kind(vtype(v)) == .SVECTOR return;
            vec := op(v, 0); elt := op(v, 1); ci := op(v, 2);
            n := de.bits;
            dv := de;
            needs_elt := true;
            if vkind(ci) == .C_INT && !is_vector_type(vtype(ci)) {
                c := cf_ap(ci);
                if ap_active_bits(c) <= 64 && ap_zext_value(c) < cast(u64) n {
                    idx := cast(u32) ap_zext_value(c);
                    ap_clear_bit(*dv, idx);
                    needs_elt = ap_get_bit(de, idx);
                }
            }
            if needs_elt {
                fpc_compute(elt, dem_all(vtype(elt)), interested, known, q, depth + 1);
                if kfpc_is_unknown(known.*) return;
            } else known.known_fp_classes = FC_NONE;
            if !ap_is_zero(dv) {
                k2: Known_FP_Class;
                fpc_compute(vec, dv, interested, *k2, q, depth + 1);
                known.* = kfpc_or(known.*, k2);
            }
        case .SHUFFLEVECTOR;
            splat := vt_get_splat_value(v);
            if splat != NONE {
                fpc_compute(splat, dem_all(vtype(splat)), interested, known, q, depth + 1);
                return;
            }
            if !is_inst(v) return;
            ok, dl, dr := shuffle_demanded_elts(v, de);
            if !ok return;
            if !ap_is_zero(dl) {
                fpc_compute(op(v, 0), dl, interested, known, q, depth + 1);
                if kfpc_is_unknown(known.*) return;
            } else known.known_fp_classes = FC_NONE;
            if !ap_is_zero(dr) {
                k2: Known_FP_Class;
                fpc_compute(op(v, 1), dr, interested, *k2, q, depth + 1);
                known.* = kfpc_or(known.*, k2);
            }
        case .EXTRACTVALUE;
            if !is_inst(v) return;
            src := op(v, 0);
            idxs := inst_indices(v);
            if type_kind(vtype(src)) == .STRUCT && idxs.count == 1 && idxs[0] == 0 {
                if call_iid(src) == IID_FREXP {
                    kfpc_known_not(known, FC_SUBNORMAL);
                    ks: Known_FP_Class;
                    fpc_compute(op(src, 0), de, interested, *ks, q, depth + 1);
                    known.* = kfpc_frexp_mant(ks, fpc_mode(v, st));
                    return;
                }
            }
            fpc_compute(src, de, interested, known, q, depth + 1);
        case .PHI;
            if !is_inst(v) return;
            n := nops(v);
            if n == 0 return;
            phi_limit: u32 = MAX_ANALYSIS_RECURSION_DEPTH - 2;
            if depth < phi_limit {
                cv := phi_has_constant_value(v);
                if cv != NONE && (vkind(cv) == .C_UNDEF || vkind(cv) == .C_POISON) return;
                first := true;
                for i: 0..n-1 {
                    inc, cxt, phi_out := break_self_recursive_phi(v, i);
                    if inc == v continue;
                    ks: Known_FP_Class;
                    rq := sq_with_instruction(q, cxt); rq.cc = null;
                    fpc_compute(inc, de, interested, *ks, rq, phi_limit);
                    if first { known.* = ks; first = false; }
                    else known.* = kfpc_or(known.*, ks);
                    if known.known_fp_classes == FC_ALL_FLAGS break;
                }
            }
            if n != 2 || kfpc_cannot_be_ordered_less_than_zero(known.*) return;
            for i: 0..1 {
                rv := phi_value(v, cast(u32)(1 - i));
                if !is_inst(rv) || call_iid(rv) == NOT_INTRINSIC continue;
                okr, pn, init, l, r := match_simple_ternary_intrinsic_recurrence(rv);
                if okr && pn == v {
                    iid := call_iid(rv);
                    if iid == IID_FMA || iid == IID_FMULADD {
                        ks: Known_FP_Class;
                        fpc_compute(init, de, interested, *ks, q, depth + 1);
                        if kfpc_cannot_be_ordered_less_than_zero(ks) && l == r && is_guaranteed_not_to_be_undef(l, q.ac, q.cxt, q.dt, depth + 1)
                            kfpc_known_not(known, KFPC_ORDERED_LESS_THAN_ZERO_MASK);
                    }
                }
            }
        case .BITCAST;
            if !is_inst(v) return;
            okb, src := fpc_elementwise_bitcast_inst(v);
            if !okb || type_kind(scalar_type(vtype(src))) != .INT return;
            ty := vtype(v);
            okm, cl, cr := fpc_max_or_min_of_bitcasts(src);
            if okm && vtype(cl) == ty && vtype(cr) == ty {
                kl, kr: Known_FP_Class;
                fpc_compute(cr, de, interested, *kr, q, depth + 1);
                if !kfpc_is_unknown(kr) {
                    fpc_compute(cl, de, interested, *kl, q, depth + 1);
                    known.* = kfpc_or(kl, kr);
                }
                return;
            }
            bits := known_bits_de(src, de, q, depth + 1);
            known.* = kfpc_bitcast(type_kind(st), bits);
    }
}
fpc_mode :: (i: Value_Id, st: Type_Id) -> Denorm_Mode {
    if !is_inst(i) || inst(i).parent == NONE return DM_DYNAMIC;
    return dm_of_fn(inst_fn(i), st);
}
// computeKnownFPClassForFPTrunc
fpc_fptrunc :: (v: Value_Id, de: APInt, interested: u32, known: *Known_FP_Class, q: Simplify_Query, depth: u32) {
    if (interested & (KFPC_ORDERED_LESS_THAN_ZERO_MASK | FC_NAN)) == FC_NONE return;
    src: Known_FP_Class;
    fpc_compute(op(v, 0), de, interested, *src, q, depth + 1);
    known.* = kfpc_fptrunc(src);
}
fpc_compute_call :: (ii: Value_Id, de: APInt, interested: u32, known: *Known_FP_Class, q: Simplify_Query, depth: u32, known_not_from_flags: u32) {
    id := call_iid(ii);
    st := scalar_type(vtype(ii));
    a0 := ifx call_num_args(ii) > 0 then op(ii, 0) else NONE;
    one :: (a0: Value_Id, de: APInt, interested: u32, q: Simplify_Query, depth: u32) -> Known_FP_Class {
        s: Known_FP_Class; fpc_compute(a0, de, interested, *s, q, depth + 1); return s;
    }
    if id == {
        case IID_FABS;
            if (interested & (FC_NAN | FC_POSITIVE)) != FC_NONE fpc_compute(a0, de, interested, known, q, depth + 1);
            known.* = kfpc_fabs(known.*);
        case IID_COPYSIGN;
            fpc_compute(a0, de, interested, known, q, depth + 1);
            ks := one(op(ii, 1), de, interested, q, depth);
            known.* = kfpc_copysign(known.*, ks);
        case IID_FMA; #through;
        case IID_FMULADD;
            if (interested & FC_NEGATIVE) == FC_NONE return;
            if op(ii, 0) == op(ii, 1) {
                ka := one(op(ii, 2), de, interested, q, depth);
                ks := one(op(ii, 0), de, interested, q, depth);
                m := fpc_mode(ii, st);
                if known_not_from_flags & FC_NAN { kfpc_known_not(*ks, FC_NAN); kfpc_known_not(*ka, FC_NAN); }
                if known_not_from_flags & FC_INF { kfpc_known_not(*ks, FC_INF); kfpc_known_not(*ka, FC_INF); }
                known.* = kfpc_fma_square(ks, ka, m);
                return;
            }
            ks: [3] Known_FP_Class;
            for i: 0..2 {
                ks[i] = one(op(ii, cast(u32) i), de, interested, q, depth);
                if kfpc_is_unknown(ks[i]) return;
                if known_not_from_flags & FC_NAN kfpc_known_not(*ks[i], FC_NAN);
                if known_not_from_flags & FC_INF kfpc_known_not(*ks[i], FC_INF);
            }
            known.* = kfpc_fma(ks[0], ks[1], ks[2], fpc_mode(ii, st));
        case IID_SQRT; #through;
        case IID_EXPERIMENTAL_CONSTRAINED_SQRT;
            srcs := interested;
            if interested & FC_NAN srcs |= KFPC_ORDERED_LESS_THAN_ZERO_MASK;
            ks := one(a0, de, srcs, q, depth);
            m := DM_DYNAMIC;
            has_nsz := q.use_instr_info && (inst_fmf(ii) & FMF_NSZ) != 0;
            if !has_nsz m = fpc_mode(ii, st);
            known.* = kfpc_sqrt(ks, m);
            if has_nsz kfpc_known_not(known, FC_NEG_ZERO);
        case IID_SIN; known.* = kfpc_sin(one(a0, de, interested, q, depth));
        case IID_COS; known.* = kfpc_sin(one(a0, de, interested, q, depth));
        case IID_TAN; known.* = kfpc_sin(one(a0, de, interested, q, depth));
        case IID_SINH; known.* = kfpc_sinh(one(a0, de, interested, q, depth));
        case IID_COSH; known.* = kfpc_cosh(one(a0, de, interested, q, depth));
        case IID_TANH; known.* = kfpc_tanh(one(a0, de, interested, q, depth));
        case IID_ASIN; known.* = kfpc_asin(one(a0, de, interested, q, depth));
        case IID_ACOS; known.* = kfpc_acos(one(a0, de, interested, q, depth));
        case IID_ATAN; known.* = kfpc_atan(one(a0, de, interested, q, depth));
        case IID_ATAN2;
            kl := one(a0, de, interested, q, depth);
            kr := one(op(ii, 1), de, interested, q, depth);
            known.* = kfpc_atan2(kl, kr);
        case IID_MAXNUM; #through; case IID_MINNUM; #through; case IID_MINIMUM; #through;
        case IID_MAXIMUM; #through; case IID_MINIMUMNUM; #through; case IID_MAXIMUMNUM;
            kl := one(a0, de, interested, q, depth);
            kr := one(op(ii, 1), de, interested, q, depth);
            known.* = kfpc_min_max_like(kl, kr, fpc_min_max_kind(id), fpc_mode(ii, st));
        case IID_CANONICALIZE;
            ks := one(a0, de, interested, q, depth);
            known.* = kfpc_canonicalize(ks, fpc_mode(ii, st));
        case IID_VECTOR_REDUCE_FMAX; #through; case IID_VECTOR_REDUCE_FMIN; #through;
        case IID_VECTOR_REDUCE_FMAXIMUM; #through; case IID_VECTOR_REDUCE_FMINIMUM;
            known.* = compute_known_fp_class_fmf(a0, inst_fmf(ii), interested, q, depth + 1);
            if !kfpc_is_known_never_nan(known.*) known.sign_bit = -1;
        case IID_VECTOR_REVERSE;
            known.* = compute_known_fp_class_de_fmf(a0, ap_reverse_bits(de), inst_fmf(ii), interested, q, depth + 1);
        case IID_TRUNC; #through; case IID_FLOOR; #through; case IID_CEIL; #through; case IID_RINT; #through;
        case IID_NEARBYINT; #through; case IID_ROUND; #through; case IID_ROUNDEVEN;
            srcs := interested;
            if srcs & FC_POS_FINITE srcs |= FC_POS_FINITE;
            if srcs & FC_NEG_FINITE srcs |= FC_NEG_FINITE;
            ks := one(a0, de, srcs, q, depth);
            known.* = kfpc_round_to_integral(ks, id == IID_TRUNC, type_kind(st) == .PPC_FP128);
        case IID_EXP; #through; case IID_EXP2; #through; case IID_EXP10;
            known.* = kfpc_exp(one(a0, de, interested, q, depth));
        case IID_FPTRUNC_ROUND;
            fpc_fptrunc(ii, de, interested, known, q, depth);
        case IID_LOG; #through; case IID_LOG10; #through; case IID_LOG2; #through;
        case IID_EXPERIMENTAL_CONSTRAINED_LOG; #through; case IID_EXPERIMENTAL_CONSTRAINED_LOG10; #through;
        case IID_EXPERIMENTAL_CONSTRAINED_LOG2;
            if (interested & (FC_NAN | FC_INF)) != FC_NONE {
                srcs := interested;
                if (interested & FC_NEG_INF) != FC_NONE srcs |= FC_ZERO | FC_SUBNORMAL;
                if (interested & FC_NAN) != FC_NONE srcs |= FC_NAN | FC_NEGATIVE;
                ks := one(a0, de, srcs, q, depth);
                known.* = kfpc_log(ks, fpc_mode(ii, st));
            }
        case IID_POWI;
            if (interested & (FC_NAN | FC_INF | FC_NEGATIVE)) == FC_NONE return;
            e := op(ii, 1);
            et := vtype(e);
            ekb := known_bits_de(e, ifx is_vector_type(et) then de else ap_one(1), q, depth + 1);
            srcs: u32 = FC_NONE;
            if interested & FC_NAN srcs |= FC_NAN;
            if !kb_is_zero(ekb) {
                if interested & FC_INF srcs |= FC_FINITE | FC_INF;
                if (interested & FC_NEGATIVE) && !kb_is_even(ekb) srcs |= FC_NEGATIVE;
            }
            ks: Known_FP_Class;
            if srcs != FC_NONE fpc_compute(a0, de, srcs, *ks, q, depth + 1);
            known.* = kfpc_powi(ks, ekb);
        case IID_LDEXP;
            ks := one(a0, de, interested, q, depth);
            exp_info_mask: u32 = FC_ZERO | FC_SUBNORMAL | FC_INF;
            ea := op(ii, 1);
            r: Const_Range;
            if (ks.known_fp_classes & exp_info_mask) != FC_NONE r = compute_constant_range(ea, true, q, depth + 1);
            else r = cr_full(type_bits(scalar_type(vtype(ea))));
            known.* = kfpc_ldexp(ks, cr_smin(r), cr_smax(r), type_kind(st), fpc_mode(ii, st));
        case IID_ARITHMETIC_FENCE;
            fpc_compute(a0, de, interested, known, q, depth + 1);
        case IID_EXPERIMENTAL_CONSTRAINED_SITOFP; #through;
        case IID_EXPERIMENTAL_CONSTRAINED_UITOFP;
            kfpc_known_not(known, FC_NAN);
            kfpc_known_not(known, FC_NEG_ZERO);
            kfpc_known_not(known, FC_SUBNORMAL);
            if id == IID_EXPERIMENTAL_CONSTRAINED_UITOFP kfpc_sign_bit_must_be_zero(known);
    }
}

// ---------------------------------------------------------------- ConstantFPRange

Const_FP_Range :: struct { lo: APFloat; hi: APFloat; may_be_qnan: bool; may_be_snan: bool; }
cfr_inf :: (k: Type_Kind, neg: bool) -> APFloat { return apf_from_words(k, fp_inf(k, neg)); }
cfr_make :: (lo: APFloat, hi: APFloat, q: bool, s: bool) -> Const_FP_Range { r: Const_FP_Range; r.lo = lo; r.hi = hi; r.may_be_qnan = q; r.may_be_snan = s; return r; }
cfr_empty :: (k: Type_Kind) -> Const_FP_Range { return cfr_make(cfr_inf(k, false), cfr_inf(k, true), false, false); }
cfr_full :: (k: Type_Kind) -> Const_FP_Range { return cfr_make(cfr_inf(k, true), cfr_inf(k, false), true, true); }
cfr_non_nan :: (k: Type_Kind) -> Const_FP_Range { return cfr_make(cfr_inf(k, true), cfr_inf(k, false), false, false); }
cfr_nan_only :: (k: Type_Kind, q: bool, s: bool) -> Const_FP_Range { return cfr_make(cfr_inf(k, false), cfr_inf(k, true), q, s); }
cfr_from_value :: (v: APFloat) -> Const_FP_Range {
    if apf_is_nan(v) { r := cfr_empty(v.k); sn := apf_is_signaling(v); r.may_be_qnan = !sn; r.may_be_snan = sn; return r; }
    return cfr_make(v, v, false, false);
}
apf_is_pos_inf :: (f: APFloat) -> bool { return apf_is_inf(f) && !apf_is_negative(f); }
apf_is_neg_inf :: (f: APFloat) -> bool { return apf_is_inf(f) && apf_is_negative(f); }
apf_bitwise_eq :: (a: APFloat, b: APFloat) -> bool { x := a; y := b; wx := apf_words(*x); wy := apf_words(*y); for wx if it != wy[it_index] return false; return true; }
cfr_strict_compare :: (a: APFloat, b: APFloat) -> Fp_Cmp {
    if apf_is_zero(a) && apf_is_zero(b) {
        if apf_is_negative(a) == apf_is_negative(b) return .EQUAL;
        return ifx apf_is_negative(a) then Fp_Cmp.LESS else .GREATER;
    }
    return apf_compare(a, b);
}
cfr_is_nan_only :: (r: Const_FP_Range) -> bool { return apf_is_pos_inf(r.lo) && apf_is_neg_inf(r.hi); }
cfr_is_empty_set :: (r: Const_FP_Range) -> bool { return apf_is_pos_inf(r.lo) && apf_is_neg_inf(r.hi) && !r.may_be_qnan && !r.may_be_snan; }
cfr_contains_range :: (a: Const_FP_Range, b: Const_FP_Range) -> bool {
    if b.may_be_qnan && !a.may_be_qnan return false;
    if b.may_be_snan && !a.may_be_snan return false;
    return cfr_strict_compare(a.lo, b.lo) != .GREATER && cfr_strict_compare(b.hi, a.hi) != .GREATER;
}
cfr_single_element :: (r: Const_FP_Range, excludes_nan: bool) -> bool {
    if !excludes_nan && (r.may_be_snan || r.may_be_qnan) return false;
    return apf_bitwise_eq(r.lo, r.hi);
}
cfr_classify :: (r: Const_FP_Range) -> u32 {
    m: u32 = 0;
    if r.may_be_snan m |= FC_SNAN;
    if r.may_be_qnan m |= FC_QNAN;
    if !cfr_is_nan_only(r) m |= (apf_classify(r.hi) << 1) - apf_classify(r.lo);
    return m;
}
cfr_intersect :: (a: Const_FP_Range, b: Const_FP_Range) -> Const_FP_Range {
    lo := apf_maxnum(a.lo, b.lo);
    hi := apf_minnum(a.hi, b.hi);
    if cfr_strict_compare(lo, hi) == .GREATER && !(apf_is_inf(lo) && apf_is_inf(hi)) { lo = cfr_inf(lo.k, false); hi = cfr_inf(hi.k, true); }
    return cfr_make(lo, hi, a.may_be_qnan && b.may_be_qnan, a.may_be_snan && b.may_be_snan);
}
cfr_pred_excludes_equal :: (pred: u8) -> bool { return (pred & FCMP_OEQ) == 0; }
cfr_make_less_than :: (v_in: APFloat, pred: u8) -> Const_FP_Range {
    v := v_in;
    if cfr_pred_excludes_equal(pred) {
        if apf_is_neg_inf(v) return cfr_empty(v.k);
        w, st := fp_next(v.k, apf_words(*v), true);
        v = apf_from_words(v.k, w);
    }
    return cfr_make(cfr_inf(v.k, true), v, false, false);
}
cfr_make_greater_than :: (v_in: APFloat, pred: u8) -> Const_FP_Range {
    v := v_in;
    if cfr_pred_excludes_equal(pred) {
        if apf_is_pos_inf(v) return cfr_empty(v.k);
        w, st := fp_next(v.k, apf_words(*v), false);
        v = apf_from_words(v.k, w);
    }
    return cfr_make(v, cfr_inf(v.k, false), false, false);
}
cfr_extend_zero_if_equal :: (r: Const_FP_Range, pred: u8) -> Const_FP_Range {
    if cfr_pred_excludes_equal(pred) return r;
    lo := r.lo; hi := r.hi;
    if apf_is_pos_zero(lo) lo = apf_from_words(lo.k, fp_zero(lo.k, true));
    if apf_is_neg_zero(hi) hi = apf_from_words(hi.k, fp_zero(hi.k, false));
    return cfr_make(lo, hi, r.may_be_qnan, r.may_be_snan);
}
cfr_set_nan_field :: (r: Const_FP_Range, pred: u8) -> Const_FP_Range {
    n := cmp_is_unordered(pred);
    return cfr_make(r.lo, r.hi, n, n);
}
// makeSatisfyingFCmpRegion
cfr_make_satisfying_fcmp_region :: (pred: u8, other: Const_FP_Range) -> Const_FP_Range {
    k := other.lo.k;
    if cfr_is_empty_set(other) return cfr_full(k);
    if (other.may_be_qnan || other.may_be_snan) && cmp_is_ordered(pred) return cfr_empty(k);
    if cfr_is_nan_only(other) && cmp_is_unordered(pred) return cfr_full(k);
    if pred == {
        case FCMP_TRUE; return cfr_full(k);
        case FCMP_FALSE; return cfr_empty(k);
        case FCMP_ORD; return cfr_non_nan(k);
        case FCMP_UNO; return cfr_nan_only(k, true, true);
        case FCMP_OEQ; #through; case FCMP_UEQ;
            r: Const_FP_Range;
            if cfr_single_element(other, true) || (cfr_classify(other) & ~cast(u32) FC_NAN) == FC_ZERO r = cfr_extend_zero_if_equal(other, pred);
            else r = cfr_empty(k);
            return cfr_set_nan_field(r, pred);
        case FCMP_ONE; #through; case FCMP_UNE; return cfr_empty(k);
        case FCMP_OLT; #through; case FCMP_OLE; #through; case FCMP_ULT; #through; case FCMP_ULE;
            return cfr_set_nan_field(cfr_extend_zero_if_equal(cfr_make_less_than(other.lo, pred), pred), pred);
        case FCMP_OGT; #through; case FCMP_OGE; #through; case FCMP_UGT; #through; case FCMP_UGE;
            return cfr_set_nan_field(cfr_extend_zero_if_equal(cfr_make_greater_than(other.hi, pred), pred), pred);
    }
    fatal("internal: ConstantFPRange: unexpected predicate");
    return other;
}
// makeExactFCmpRegion: (has value, range)
cfr_make_exact_fcmp_region :: (pred: u8, c: APFloat) -> (bool, Const_FP_Range) {
    if (pred == FCMP_UNE || pred == FCMP_ONE) && !apf_is_nan(c) { r: Const_FP_Range; return false, r; }
    return true, cfr_make_satisfying_fcmp_region(pred, cfr_from_value(c));
}
