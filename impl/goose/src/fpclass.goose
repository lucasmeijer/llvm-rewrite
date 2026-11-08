// KnownFPClass and computeKnownFPClass. Ported from llvm/lib/Support/KnownFPClass.cpp,
// llvm/lib/Analysis/ValueTracking.cpp (computeKnownFPClass, computeKnownFPClassFromCond/Context,
// adjustKnownFPClassForSelectArm, isSignBitCheck), llvm/include/llvm/IR/GenericFloatingPointPredicateUtils.h
// (fcmpImpliesClass / fcmpToClassTest), llvm/lib/Support/FloatingPointMode.cpp (fneg, inverse_fabs,
// unknown_sign, orderedStrictlyLess/Greater) and llvm/lib/IR/ConstantFPRange.cpp (the subset used by
// makeExactFCmpRegion / contains / intersectWith).
//
// Context: the SimplifyQuery context instruction is kb_cxt (as for computeKnownBits); there is no
// DomConditionCache and no CondContext (InstSimplify does not set them), assumptions come from assume.goose.
// Denormal modes come from the function's denormal_fpenv attribute (DenormalMode encoded input << 2 | output).
// ConstantFPRange is only implemented for IEEE formats of at most 64 bits (fails loudly otherwise).
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_attrs;
import gen_iids;
import apfloat;
import fpu;
import pm;
import crange;
import vt;
import poison;
import knownbits;
import assume;
import implied;
import constfold;

let FCL_SNAN: u64 = 1;
let FCL_QNAN: u64 = 2;
let FCL_NEG_INF: u64 = 4;
let FCL_NEG_NORMAL: u64 = 8;
let FCL_NEG_SUBNORMAL: u64 = 16;
let FCL_NEG_ZERO: u64 = 32;
let FCL_POS_ZERO: u64 = 64;
let FCL_POS_SUBNORMAL: u64 = 128;
let FCL_POS_NORMAL: u64 = 256;
let FCL_POS_INF: u64 = 512;
let FCL_NAN: u64 = 3;
let FCL_INF: u64 = 516;
let FCL_NORMAL: u64 = 264;
let FCL_SUBNORMAL: u64 = 144;
let FCL_ZERO: u64 = 96;
let FCL_POS_FINITE: u64 = 448;
let FCL_NEG_FINITE: u64 = 56;
let FCL_FINITE: u64 = 504;
let FCL_POSITIVE: u64 = 960;
let FCL_NEGATIVE: u64 = 60;
let FCL_ALL: u64 = 1023;
let FCL_ORDERED_LT_ZERO_MASK: u64 = 28;   // fcNegSubnormal | fcNegNormal | fcNegInf
let FCL_ORDERED_GT_ZERO_MASK: u64 = 896;  // fcPosSubnormal | fcPosNormal | fcPosInf

// DenormalMode: input << 2 | output; kinds IEEE 0, PreserveSign 1, PositiveZero 2, Dynamic 3
let DMK_IEEE = 0;
let DMK_PS = 1;
let DMK_PZ = 2;
let DMK_DYN = 3;
let DM_IEEE: i64 = 0;
let DM_PRESERVE_SIGN: i64 = 5;
let DM_POSITIVE_ZERO: i64 = 10;
let DM_DYNAMIC: i64 = 15;
fn dm_in(m: i64) -> i64 { m >> 2 }
fn dm_out(m: i64) -> i64 { m & 3 }
fn dm_inputs_are_zero(m: i64) -> bool { dm_in(m) == DMK_PS || dm_in(m) == DMK_PZ }
fn dm_outputs_are_zero(m: i64) -> bool { dm_out(m) == DMK_PS || dm_out(m) == DMK_PZ }

// Function::getDenormalMode(FltSem): the float mode for IEEEsingle, the default mode otherwise
fn fn_denormal_mode(fv: i32, ty: i32) -> i64 {
    if fv < 0 { return DM_DYNAMIC; }
    let at = aset_find(alist_fn(func_attrs(fv)), AK_DenormalFPEnv);
    if at < 0 { return DM_IEEE; }
    let x = attrs[at].i1 as i64;
    if types[ty_scalar(ty)].kind as i64 == TK_FLOAT { return (x >> 4) & 15; }
    return x & 15;
}
fn inst_denormal_mode(iv: i32) -> i64 {
    if !is_inst(iv) { return DM_DYNAMIC; }
    return fn_denormal_mode(inst_func(iv), vals[iv].ty);
}

// sign: -1 unknown, 0 known positive (sign bit clear), 1 known negative
struct KFC { known: u64, sign: i64 }

fn fp_not_ported(what: const u8[:]) { fatal(str("computeKnownFPClass: ", what, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// FPClassTest helpers (FloatingPointMode.cpp)

fn fcl_fneg(m: u64) -> u64 {
    var r = m & FCL_NAN;
    if (m & FCL_NEG_INF) != 0 { r |= FCL_POS_INF; }
    if (m & FCL_NEG_NORMAL) != 0 { r |= FCL_POS_NORMAL; }
    if (m & FCL_NEG_SUBNORMAL) != 0 { r |= FCL_POS_SUBNORMAL; }
    if (m & FCL_NEG_ZERO) != 0 { r |= FCL_POS_ZERO; }
    if (m & FCL_POS_ZERO) != 0 { r |= FCL_NEG_ZERO; }
    if (m & FCL_POS_SUBNORMAL) != 0 { r |= FCL_NEG_SUBNORMAL; }
    if (m & FCL_POS_NORMAL) != 0 { r |= FCL_NEG_NORMAL; }
    if (m & FCL_POS_INF) != 0 { r |= FCL_NEG_INF; }
    return r;
}
fn fcl_inverse_fabs(m: u64) -> u64 {
    var r = m & FCL_NAN;
    if (m & FCL_POS_ZERO) != 0 { r |= FCL_ZERO; }
    if (m & FCL_POS_SUBNORMAL) != 0 { r |= FCL_SUBNORMAL; }
    if (m & FCL_POS_NORMAL) != 0 { r |= FCL_NORMAL; }
    if (m & FCL_POS_INF) != 0 { r |= FCL_INF; }
    return r;
}
fn fcl_unknown_sign(m: u64) -> u64 {
    var r = m & FCL_NAN;
    if (m & FCL_ZERO) != 0 { r |= FCL_ZERO; }
    if (m & FCL_SUBNORMAL) != 0 { r |= FCL_SUBNORMAL; }
    if (m & FCL_NORMAL) != 0 { r |= FCL_NORMAL; }
    if (m & FCL_INF) != 0 { r |= FCL_INF; }
    return r;
}
fn fcl_not(m: u64) -> u64 { ~m & FCL_ALL }
// orderedStrictlyLess(Mask, OrderedZeroSign = false)
fn fcl_ordered_strictly_less(m0: u64) -> u64 {
    let m = m0 & ~FCL_NAN & FCL_ALL;
    var tz: i64 = 32;
    if m != 0 { tz = 0; while ((m >> tz) & 1) == 0 { tz++; } }
    var r: u64 = if tz >= 32 { 0xFFFFFFFF } else { ((1 as u64) << tz) - 1 };
    r &= FCL_ALL;
    r &= ~FCL_NAN;
    if (r & FCL_ZERO) != FCL_ZERO { r &= ~FCL_ZERO; }
    return r;
}
// orderedStrictlyGreater(Mask, OrderedZeroSign = false)
fn fcl_ordered_strictly_greater(m0: u64) -> u64 {
    let m = m0 & 0xFFFFFFFF;
    var lz: i64 = 32;
    if m != 0 { lz = 0; while ((m >> (31 - lz)) & 1) == 0 { lz++; } }
    var r: u64 = if lz == 0 { 0 } else { (0xFFFFFFFF << (32 - lz)) & 0xFFFFFFFF };
    r &= FCL_ALL;
    r &= ~FCL_NAN;
    if (r & FCL_ZERO) != FCL_ZERO { r &= ~FCL_ZERO; }
    return r;
}

// ---------------------------------------------------------------------------------------------
// KnownFPClass (KnownFPClass.h / KnownFPClass.cpp)

fn kfc_unknown() -> KFC { KFC { known: FCL_ALL, sign: -1 } }
fn kfc_mk(known: u64, sign: i64) -> KFC { KFC { known: known & FCL_ALL, sign: sign } }
fn kfc_never(k: KFC, m: u64) -> bool { (k.known & m) == 0 }
fn kfc_always(k: KFC, m: u64) -> bool { (k.known & ~m & FCL_ALL) == 0 }
fn kfc_is_unknown(k: KFC) -> bool { k.known == FCL_ALL && k.sign < 0 }
fn kfc_never_nan(k: KFC) -> bool { (k.known & FCL_NAN) == 0 }
fn kfc_always_nan(k: KFC) -> bool { (k.known & ~FCL_NAN & FCL_ALL) == 0 }
fn kfc_never_inf(k: KFC) -> bool { kfc_never(k, FCL_INF) }
fn kfc_never_inf_or_nan(k: KFC) -> bool { kfc_never(k, FCL_INF | FCL_NAN) }
fn kfc_cannot_be_ordered_lt_zero(k: KFC) -> bool { (k.known & FCL_ORDERED_LT_ZERO_MASK) == 0 }
fn kfc_cannot_be_ordered_gt_zero(k: KFC) -> bool { (k.known & FCL_ORDERED_GT_ZERO_MASK) == 0 }
fn kfc_never_logical_zero(k: KFC, m: i64) -> bool {
    return kfc_never(k, FCL_ZERO) && (kfc_never(k, FCL_SUBNORMAL) || dm_in(m) == DMK_IEEE);
}
fn kfc_never_logical_neg_zero(k: KFC, m: i64) -> bool {
    return kfc_never(k, FCL_NEG_ZERO) && (kfc_never(k, FCL_NEG_SUBNORMAL) || dm_in(m) == DMK_IEEE || dm_in(m) == DMK_PZ);
}
fn kfc_never_logical_pos_zero(k: KFC, m: i64) -> bool {
    if !kfc_never(k, FCL_POS_ZERO) { return false; }
    if kfc_never(k, FCL_SUBNORMAL) { return true; }
    let i = dm_in(m);
    if i == DMK_IEEE { return true; }
    if i == DMK_PS { return kfc_never(k, FCL_POS_SUBNORMAL); }
    return false;
}
fn kfc_cannot_be_ordered_le_zero(k: KFC, m: i64) -> bool { kfc_never(k, FCL_NEGATIVE) && kfc_never_logical_pos_zero(k, m) }
fn kfc_cannot_be_ordered_ge_zero(k: KFC, m: i64) -> bool { kfc_never(k, FCL_POSITIVE) && kfc_never_logical_neg_zero(k, m) }
fn kfc_intersect_with(a: KFC, b: KFC) -> KFC { KFC { known: a.known | b.known, sign: if a.sign == b.sign { a.sign } else { -1 } } }
fn kfc_union_with(a: KFC, b: KFC) -> KFC {
    var s: i64 = -1;
    if a.sign >= 0 && b.sign < 0 { s = a.sign; } else if a.sign < 0 && b.sign >= 0 { s = b.sign; }
    return KFC { known: a.known & b.known, sign: s };
}
// operator|=
fn kfc_or(a: KFC, b: KFC) -> KFC { KFC { known: a.known | b.known, sign: if a.sign != b.sign { -1 } else { a.sign } } }
fn kfc_known_not(k: KFC, rule_out: u64) -> KFC {
    var r = k;
    r.known = r.known & ~rule_out & FCL_ALL;
    if kfc_never(r, FCL_NAN) && r.sign < 0 {
        if kfc_never(r, FCL_NEGATIVE) { r.sign = 0; }
        else if kfc_never(r, FCL_POSITIVE) { r.sign = 1; }
    }
    return r;
}
fn kfc_fneg(k: KFC) -> KFC { KFC { known: fcl_fneg(k.known), sign: if k.sign < 0 { -1 } else { 1 - k.sign } } }
fn kfc_sign_bit_must_be_zero(k: KFC) -> KFC { KFC { known: k.known & (FCL_POSITIVE | FCL_NAN), sign: 0 } }
fn kfc_sign_bit_must_be_one(k: KFC) -> KFC { KFC { known: k.known & (FCL_NEGATIVE | FCL_NAN), sign: 1 } }
fn kfc_fabs(k: KFC) -> KFC {
    var r = k;
    if (r.known & FCL_NEG_ZERO) != 0 { r.known |= FCL_POS_ZERO; }
    if (r.known & FCL_NEG_INF) != 0 { r.known |= FCL_POS_INF; }
    if (r.known & FCL_NEG_SUBNORMAL) != 0 { r.known |= FCL_POS_SUBNORMAL; }
    if (r.known & FCL_NEG_NORMAL) != 0 { r.known |= FCL_POS_NORMAL; }
    return kfc_sign_bit_must_be_zero(r);
}
fn kfc_copysign(mag: KFC, sgn: KFC) -> KFC {
    var r = mag;
    if (r.known & FCL_ZERO) != 0 { r.known |= FCL_ZERO; }
    if (r.known & FCL_SUBNORMAL) != 0 { r.known |= FCL_SUBNORMAL; }
    if (r.known & FCL_NORMAL) != 0 { r.known |= FCL_NORMAL; }
    if (r.known & FCL_INF) != 0 { r.known |= FCL_INF; }
    r.sign = sgn.sign;
    if kfc_never(sgn, FCL_POSITIVE | FCL_NAN) || r.sign == 1 { r.known &= FCL_NEGATIVE | FCL_NAN; }
    if kfc_never(sgn, FCL_NEGATIVE | FCL_NAN) || r.sign == 0 { r.known &= FCL_POSITIVE | FCL_NAN; }
    return r;
}
fn kfc_propagate_nan(k: KFC, src: KFC, preserve_sign: bool) -> KFC {
    var r = k;
    if kfc_never(src, FCL_NAN) {
        r = kfc_known_not(r, FCL_NAN);
        if preserve_sign { r.sign = src.sign; }
    } else if kfc_never(src, FCL_SNAN) {
        r = kfc_known_not(r, FCL_SNAN);
    }
    return r;
}
fn kfc_propagate_xor_sign(k: KFC, l: KFC, r: KFC) -> KFC {
    var x = k;
    if (kfc_never(l, FCL_NEGATIVE) && kfc_never(r, FCL_NEGATIVE)) || (kfc_never(l, FCL_POSITIVE) && kfc_never(r, FCL_POSITIVE)) {
        x = kfc_known_not(x, FCL_NEGATIVE);
    }
    if (kfc_never(l, FCL_POSITIVE) && kfc_never(r, FCL_NEGATIVE)) || (kfc_never(l, FCL_NEGATIVE) && kfc_never(r, FCL_POSITIVE)) {
        x = kfc_known_not(x, FCL_POSITIVE);
    }
    return x;
}
fn kfc_propagate_denormal(k: KFC, src: KFC, mode: i64) -> KFC {
    var r = k;
    r.known = src.known;
    if !kfc_never(src, FCL_POS_ZERO) && !kfc_never(src, FCL_NEG_ZERO) { return r; }
    if kfc_never(src, FCL_SUBNORMAL) { return r; }
    if !kfc_never(src, FCL_POS_SUBNORMAL) && mode != DM_IEEE { r.known |= FCL_POS_ZERO; }
    if !kfc_never(src, FCL_NEG_SUBNORMAL) && mode != DM_IEEE {
        if mode != DM_POSITIVE_ZERO { r.known |= FCL_NEG_ZERO; }
        if dm_in(mode) == DMK_PZ || dm_out(mode) == DMK_PZ || dm_in(mode) == DMK_DYN || dm_out(mode) == DMK_DYN { r.known |= FCL_POS_ZERO; }
    }
    return r;
}
fn kfc_propagate_canonicalizing_src(k: KFC, src: KFC, mode: i64) -> KFC {
    return kfc_propagate_nan(kfc_propagate_denormal(k, src, mode), src, true);
}

// MinMaxKind: 0 minimum, 1 maximum, 2 minimumnum, 3 maximumnum, 4 minnum, 5 maxnum
let MMK_MINIMUM = 0;
let MMK_MAXIMUM = 1;
let MMK_MINIMUMNUM = 2;
let MMK_MAXIMUMNUM = 3;
let MMK_MINNUM = 4;
let MMK_MAXNUM = 5;
fn kfc_min_max_like(l0: KFC, r0: KFC, kind: i64, mode: i64) -> KFC {
    var kl = l0;
    var kr = r0;
    let never_nan = kfc_never_nan(kl) || kfc_never_nan(kr);
    var k = kfc_or(kl, kr);
    if never_nan && (kind == MMK_MINNUM || kind == MMK_MAXNUM || kind == MMK_MINIMUMNUM || kind == MMK_MAXIMUMNUM) {
        k = kfc_known_not(k, FCL_NAN);
    }
    if kind == MMK_MAXNUM || kind == MMK_MAXIMUMNUM {
        if kfc_never_nan(kl) { k = kfc_known_not(k, fcl_ordered_strictly_less(kl.known)); }
        if kfc_never_nan(kr) { k = kfc_known_not(k, fcl_ordered_strictly_less(kr.known)); }
    } else if kind == MMK_MAXIMUM {
        k = kfc_known_not(k, fcl_ordered_strictly_less(kl.known) | fcl_ordered_strictly_less(kr.known));
    } else if kind == MMK_MINNUM || kind == MMK_MINIMUMNUM {
        if kfc_never_nan(kl) { k = kfc_known_not(k, fcl_ordered_strictly_greater(kl.known)); }
        if kfc_never_nan(kr) { k = kfc_known_not(k, fcl_ordered_strictly_greater(kr.known)); }
    } else {
        k = kfc_known_not(k, fcl_ordered_strictly_greater(kl.known) | fcl_ordered_strictly_greater(kr.known));
    }
    if (k.known & FCL_ZERO) != 0 && !kfc_never(k, FCL_SUBNORMAL) {
        if mode != DM_IEEE { k.known |= FCL_ZERO; }
    }
    if kfc_never_nan(k) {
        if kl.sign >= 0 && kr.sign >= 0 && kl.sign == kr.sign {
            if kl.sign == 1 { k = kfc_sign_bit_must_be_one(k); } else { k = kfc_sign_bit_must_be_zero(k); }
        } else if (kind == MMK_MAXIMUM || kind == MMK_MINIMUM || kind == MMK_MAXIMUMNUM || kind == MMK_MINIMUMNUM) ||
                  ((kfc_never(kl, FCL_NEG_ZERO) || kfc_never(kr, FCL_POS_ZERO)) && (kfc_never(kl, FCL_POS_ZERO) || kfc_never(kr, FCL_NEG_ZERO))) {
            if !kfc_never_nan(kl) { kl.sign = -1; }
            if !kfc_never_nan(kr) { kr.sign = -1; }
            if (kind == MMK_MAXIMUM || kind == MMK_MAXIMUMNUM || kind == MMK_MAXNUM) && (kl.sign == 0 || kr.sign == 0) {
                k = kfc_sign_bit_must_be_zero(k);
            } else if (kind == MMK_MINIMUM || kind == MMK_MINIMUMNUM || kind == MMK_MINNUM) && (kl.sign == 1 || kr.sign == 1) {
                k = kfc_sign_bit_must_be_one(k);
            }
        }
    }
    return k;
}

fn kfc_canonicalize(src: KFC, mode: i64) -> KFC {
    var k = kfc_unknown();
    k.known = src.known | FCL_ZERO | FCL_QNAN;
    if kfc_never_nan(src) { k = kfc_known_not(k, FCL_NAN); } else { k = kfc_known_not(k, FCL_SNAN); }
    if mode == DM_IEEE {
        if kfc_never(src, FCL_POS_ZERO) { k = kfc_known_not(k, FCL_POS_ZERO); }
        if kfc_never(src, FCL_NEG_ZERO) { k = kfc_known_not(k, FCL_NEG_ZERO); }
        return k;
    }
    if dm_inputs_are_zero(mode) || dm_outputs_are_zero(mode) { k = kfc_known_not(k, FCL_SUBNORMAL); }
    if mode == DM_PRESERVE_SIGN {
        if kfc_never(src, FCL_POS_ZERO | FCL_POS_SUBNORMAL) { k = kfc_known_not(k, FCL_POS_ZERO); }
        if kfc_never(src, FCL_NEG_ZERO | FCL_NEG_SUBNORMAL) { k = kfc_known_not(k, FCL_NEG_ZERO); }
        return k;
    }
    if dm_in(mode) == DMK_PZ || (dm_out(mode) == DMK_PZ && dm_in(mode) == DMK_IEEE) {
        if kfc_never(src, FCL_NEG_ZERO) { k = kfc_known_not(k, FCL_NEG_ZERO); }
        if kfc_never(src, FCL_POS_ZERO | FCL_SUBNORMAL) { k = kfc_known_not(k, FCL_POS_ZERO); }
    }
    return k;
}

// KnownFPClass::bitcast(FltSemantics, Bits): kind is the FP type kind
fn kfc_bitcast(kind: i64, b: KB) -> KFC {
    var k = kfc_unknown();
    if kb_is_nonneg(b) { k = kfc_sign_bit_must_be_zero(k); }
    else if kb_is_neg(b) { k = kfc_sign_bit_must_be_one(k); }
    if kind == TK_HALF || kind == TK_BFLOAT || kind == TK_FLOAT || kind == TK_DOUBLE {
        let w = b.w as i64;
        let m = wmask(w);
        if fp_decompose(kind, b.o, 0).cat == FC_NAN { k.known = FCL_NAN; }
        else if fp_decompose(kind, ~b.z & m, 0).cat != FC_NAN { k = kfc_known_not(k, FCL_NAN); }
        let sb = sbit(w);
        let f = fp_fmt(kind);
        let infb: u64 = (((1 as u64) << f.ebits) - 1) << (f.p - 1);
        // InfKB: the constant inf with the sign bit unknown
        let iz = ~infb & m & ~sb;
        let io = infb;
        if ((b.z & io) | (b.o & iz)) != 0 { k = kfc_known_not(k, FCL_INF); }
        else if b.z == iz && b.o == io { k.known = FCL_INF; }
        let zz = m & ~sb;
        if (b.o & zz) != 0 { k = kfc_known_not(k, FCL_ZERO); }
        else if b.z == zz && b.o == 0 { k.known = FCL_ZERO; }
    } else {
        fp_not_ported("KnownFPClass::bitcast for this floating-point type");
    }
    return k;
}

fn kfc_fadd_impl(l: KFC, r: KFC, mode: i64) -> KFC {
    var k = kfc_unknown();
    if kfc_never_nan(l) && kfc_never_nan(r) && (kfc_never(l, FCL_POS_INF) || kfc_never(r, FCL_NEG_INF)) &&
       (kfc_never(l, FCL_NEG_INF) || kfc_never(r, FCL_POS_INF)) {
        k = kfc_known_not(k, FCL_NAN);
    }
    if kfc_cannot_be_ordered_lt_zero(l) && kfc_cannot_be_ordered_lt_zero(r) {
        k = kfc_known_not(k, FCL_ORDERED_LT_ZERO_MASK);
        if kfc_never(l, FCL_ZERO | FCL_POS_SUBNORMAL) || kfc_never(r, FCL_ZERO | FCL_POS_SUBNORMAL) {
            k = kfc_known_not(k, FCL_ZERO | FCL_POS_SUBNORMAL);
        }
    }
    if kfc_cannot_be_ordered_gt_zero(l) && kfc_cannot_be_ordered_gt_zero(r) {
        k = kfc_known_not(k, FCL_ORDERED_GT_ZERO_MASK);
        if kfc_never(l, FCL_ZERO | FCL_NEG_SUBNORMAL) || kfc_never(r, FCL_ZERO | FCL_NEG_SUBNORMAL) {
            k = kfc_known_not(k, FCL_ZERO | FCL_NEG_SUBNORMAL);
        }
    }
    return k;
}
fn kfc_fadd(l: KFC, r: KFC, mode: i64) -> KFC {
    var k = kfc_fadd_impl(l, r, mode);
    if (kfc_never_logical_neg_zero(l, mode) || kfc_never_logical_neg_zero(r, mode)) &&
       (dm_out(mode) == DMK_IEEE || dm_out(mode) == DMK_PZ) {
        k = kfc_known_not(k, FCL_NEG_ZERO);
    }
    return k;
}
fn kfc_fadd_self(src: KFC, mode: i64) -> KFC {
    var k = kfc_fadd(src, src, mode);
    let o = dm_out(mode);
    if kfc_never_logical_pos_zero(src, mode) &&
       (o == DMK_IEEE || (o == DMK_PS && kfc_never(src, FCL_POS_SUBNORMAL)) || (o == DMK_PZ && kfc_never(src, FCL_SUBNORMAL))) {
        k = kfc_known_not(k, FCL_POS_ZERO);
    }
    return k;
}
fn kfc_fsub(l: KFC, r: KFC, mode: i64) -> KFC { kfc_fadd(l, kfc_fneg(r), mode) }
fn kfc_fmul(l: KFC, r: KFC, mode: i64) -> KFC {
    var k = kfc_propagate_xor_sign(kfc_unknown(), l, r);
    if kfc_always(l, FCL_INF | FCL_NAN) || kfc_always(r, FCL_INF | FCL_NAN) { k = kfc_known_not(k, FCL_NORMAL | FCL_SUBNORMAL | FCL_ZERO); }
    if kfc_always(r, FCL_ZERO | FCL_NAN) || kfc_always(l, FCL_ZERO | FCL_NAN) { k = kfc_known_not(k, FCL_NORMAL | FCL_SUBNORMAL | FCL_INF); }
    if !kfc_never_nan(l) || !kfc_never_nan(r) { return k; }
    if (kfc_never_inf(r) || kfc_never_logical_zero(l, mode)) && (kfc_never_inf(l) || kfc_never_logical_zero(r, mode)) {
        k = kfc_known_not(k, FCL_NAN);
    }
    return k;
}
fn kfc_square(src: KFC, mode: i64) -> KFC {
    var k = kfc_fmul(src, src, mode);
    k = kfc_known_not(k, FCL_NEGATIVE);
    return kfc_propagate_nan(k, src, false);
}
// fmul(KnownLHS, const APFloat &CRHS)
fn kfc_fmul_const(l: KFC, c: i32, mode: i64) -> KFC {
    let kind = cfp_kind(c);
    let f = fp_fmt(kind);
    let mant_bits = f.p - 1;
    let min_exp = cfp_ilogb(c);
    let cannot_be_sub = min_exp >= mant_bits;
    var k = kfc_fmul(l, kfc_of_cfp(c), mode);
    if cannot_be_sub { k = kfc_known_not(k, FCL_SUBNORMAL); }
    if kfc_never(l, FCL_INF) {
        if min_exp < 0 { k = kfc_known_not(k, FCL_INF); }
        else if min_exp == 0 && cfp_abs_is_one(c) { k = kfc_known_not(k, FCL_INF); }
    }
    return k;
}
fn kfc_fdiv(l: KFC, r: KFC, mode: i64) -> KFC {
    var k = kfc_unknown();
    if kfc_never_nan(l) && kfc_never_nan(r) && (kfc_never_inf(l) || kfc_never_inf(r)) &&
       (kfc_never_logical_zero(l, mode) || kfc_never_logical_zero(r, mode)) {
        k = kfc_known_not(k, FCL_NAN);
    }
    k = kfc_propagate_xor_sign(k, l, r);
    if kfc_always(l, FCL_ZERO) { k = kfc_known_not(k, FCL_SUBNORMAL | FCL_NORMAL | FCL_INF); }
    if kfc_always(r, FCL_ZERO) { k = kfc_known_not(k, FCL_FINITE); }
    return k;
}
fn kfc_fdiv_self(src: KFC, mode: i64) -> KFC {
    var k = kfc_mk(FCL_NAN | FCL_POS_NORMAL, -1);
    if kfc_never_inf_or_nan(src) && kfc_never_logical_zero(src, mode) { k = kfc_known_not(k, FCL_NAN); }
    else if kfc_never(src, FCL_SNAN) { k = kfc_known_not(k, FCL_SNAN); }
    return k;
}
fn kfc_frem_self(src: KFC, mode: i64) -> KFC {
    var k = kfc_mk(FCL_NAN | FCL_ZERO, -1);
    if kfc_never_inf_or_nan(src) && kfc_never_logical_zero(src, mode) { k = kfc_known_not(k, FCL_NAN); }
    else if kfc_never(src, FCL_SNAN) { k = kfc_known_not(k, FCL_SNAN); }
    return k;
}
fn kfc_fma(a: KFC, b: KFC, c: KFC, mode: i64) -> KFC { kfc_fadd_impl(kfc_fmul(a, b, mode), c, mode) }
fn kfc_fma_square(sq: KFC, addend: KFC, mode: i64) -> KFC {
    let s = kfc_square(sq, mode);
    var k = kfc_fadd_impl(s, addend, mode);
    if kfc_never(addend, FCL_NEG_INF | FCL_NAN) && kfc_never(s, FCL_NAN) { k = kfc_known_not(k, FCL_NAN); }
    return k;
}
fn kfc_exp(src: KFC) -> KFC {
    var k = kfc_known_not(kfc_unknown(), FCL_NEGATIVE);
    k = kfc_propagate_nan(k, src, false);
    if kfc_cannot_be_ordered_lt_zero(src) {
        k = kfc_known_not(k, FCL_POS_ZERO);
        k = kfc_known_not(k, FCL_POS_SUBNORMAL);
    }
    if kfc_cannot_be_ordered_gt_zero(src) { k = kfc_known_not(k, FCL_POS_INF); }
    return k;
}
fn kfc_log(src: KFC, mode: i64) -> KFC {
    var k = kfc_known_not(kfc_unknown(), FCL_NEG_ZERO | FCL_SUBNORMAL);
    if kfc_never(src, FCL_POS_INF) { k = kfc_known_not(k, FCL_POS_INF); }
    if kfc_never_nan(src) && kfc_cannot_be_ordered_lt_zero(src) { k = kfc_known_not(k, FCL_NAN); }
    if kfc_never_logical_zero(src, mode) { k = kfc_known_not(k, FCL_NEG_INF); }
    return k;
}
fn kfc_sqrt(src: KFC, mode: i64) -> KFC {
    var k = kfc_known_not(kfc_unknown(), FCL_POS_SUBNORMAL);
    if kfc_never(src, FCL_POS_INF) { k = kfc_known_not(k, FCL_POS_INF); }
    if kfc_never(src, FCL_SNAN) { k = kfc_known_not(k, FCL_SNAN); }
    if kfc_never_nan(src) && kfc_cannot_be_ordered_lt_zero(src) { k = kfc_known_not(k, FCL_NAN); }
    k = kfc_known_not(k, FCL_NEG_INF | FCL_NEG_SUBNORMAL | FCL_NEG_NORMAL);
    if kfc_never_logical_neg_zero(src, mode) { k = kfc_known_not(k, FCL_NEG_ZERO); }
    return k;
}
fn kfc_sin(src: KFC) -> KFC {
    var k = kfc_known_not(kfc_unknown(), FCL_INF);
    if kfc_never_nan(src) && kfc_never_inf(src) { k = kfc_known_not(k, FCL_NAN); }
    return k;
}
fn kfc_sinh(src: KFC) -> KFC {
    var k = kfc_unknown();
    if kfc_never(src, FCL_NEGATIVE) { k = kfc_known_not(k, FCL_NEGATIVE); }
    return kfc_propagate_nan(k, src, false);
}
fn kfc_cosh(src: KFC) -> KFC { kfc_propagate_nan(kfc_known_not(kfc_unknown(), FCL_NEGATIVE), src, false) }
fn kfc_tanh(src: KFC) -> KFC {
    var k = kfc_known_not(kfc_unknown(), FCL_INF);
    if kfc_never(src, FCL_NEGATIVE) { k = kfc_known_not(k, FCL_NEGATIVE); }
    return kfc_propagate_nan(k, src, false);
}
fn kfc_asin(src: KFC) -> KFC {
    var k = kfc_known_not(kfc_unknown(), FCL_INF);
    if kfc_never(src, FCL_NEGATIVE) { k = kfc_known_not(k, FCL_NEGATIVE); }
    return k;
}
fn kfc_acos(src: KFC) -> KFC { kfc_known_not(kfc_known_not(kfc_unknown(), FCL_INF), FCL_NEGATIVE) }
fn kfc_atan(src: KFC) -> KFC {
    var k = kfc_known_not(kfc_unknown(), FCL_INF);
    if kfc_never(src, FCL_NEGATIVE) { k = kfc_known_not(k, FCL_NEGATIVE); }
    return kfc_propagate_nan(k, src, false);
}
fn kfc_atan2(l: KFC, r: KFC) -> KFC {
    var k = kfc_known_not(kfc_unknown(), FCL_INF);
    if kfc_never_nan(l) && kfc_never_nan(r) { k = kfc_known_not(k, FCL_NAN); }
    return k;
}
// APFloatBase::isRepresentableAsNormalIn
fn fp_representable_as_normal_in(src: i64, dst: i64) -> bool {
    let s = fp_fmt(src);
    let d = fp_fmt(dst);
    if s.bias >= d.bias || (1 - s.bias) <= (1 - d.bias) { return false; }
    return d.p >= s.p;
}
fn kfc_fpext(src: KFC, dst_kind: i64, src_kind: i64) -> KFC {
    var k = src;
    if fp_representable_as_normal_in(src_kind, dst_kind) {
        if (k.known & FCL_POS_SUBNORMAL) != 0 { k.known |= FCL_POS_NORMAL; }
        if (k.known & FCL_NEG_SUBNORMAL) != 0 { k.known |= FCL_NEG_NORMAL; }
        k = kfc_known_not(k, FCL_SUBNORMAL);
    }
    if !kfc_never_nan(k) { k.sign = -1; }
    return k;
}
fn kfc_fptrunc(src: KFC) -> KFC {
    var k = kfc_unknown();
    if kfc_cannot_be_ordered_lt_zero(src) { k = kfc_known_not(k, FCL_ORDERED_LT_ZERO_MASK); }
    return kfc_propagate_nan(k, src, true);
}
fn kfc_round_to_integral(src: KFC, is_trunc: bool, multi_unit: bool) -> KFC {
    var k = kfc_known_not(kfc_unknown(), FCL_SUBNORMAL);
    k = kfc_propagate_nan(k, src, true);
    if is_trunc || !multi_unit {
        if kfc_never(src, FCL_POS_INF) { k = kfc_known_not(k, FCL_POS_INF); }
        if kfc_never(src, FCL_NEG_INF) { k = kfc_known_not(k, FCL_NEG_INF); }
    }
    if kfc_never(src, FCL_POS_FINITE) { k = kfc_known_not(k, FCL_POS_FINITE); }
    if kfc_never(src, FCL_NEG_FINITE) { k = kfc_known_not(k, FCL_NEG_FINITE); }
    return k;
}
fn kfc_frexp_mant(src: KFC, mode: i64) -> KFC {
    var k = kfc_known_not(kfc_unknown(), FCL_SUBNORMAL);
    if kfc_never(src, FCL_NEGATIVE) { k = kfc_known_not(k, FCL_NEGATIVE); }
    else {
        if kfc_never_logical_neg_zero(src, mode) { k = kfc_known_not(k, FCL_NEG_ZERO); }
        if kfc_never(src, FCL_NEG_INF) { k = kfc_known_not(k, FCL_NEG_INF); }
    }
    if kfc_never(src, FCL_POSITIVE) { k = kfc_known_not(k, FCL_POSITIVE); }
    else {
        if kfc_never_logical_pos_zero(src, mode) { k = kfc_known_not(k, FCL_POS_ZERO); }
        if kfc_never(src, FCL_POS_INF) { k = kfc_known_not(k, FCL_POS_INF); }
    }
    return kfc_propagate_nan(k, src, false);
}
// ldexp(Src, ExpMin, ExpMax) with signed exponent bounds
fn kfc_ldexp(src: KFC, emin: i64, emax: i64, kind: i64, mode: i64) -> KFC {
    var k = kfc_propagate_nan(kfc_unknown(), src, true);
    if kfc_never(src, FCL_NEGATIVE) { k = kfc_known_not(k, FCL_NEGATIVE); }
    else if kfc_cannot_be_ordered_lt_zero(src) { k = kfc_known_not(k, FCL_ORDERED_LT_ZERO_MASK); }
    if kfc_never(src, FCL_POSITIVE) { k = kfc_known_not(k, FCL_POSITIVE); }
    else if kfc_cannot_be_ordered_gt_zero(src) { k = kfc_known_not(k, FCL_ORDERED_GT_ZERO_MASK); }
    let mant_bits = fp_fmt(kind).p - 1;
    if emin >= mant_bits { k = kfc_known_not(k, FCL_SUBNORMAL); }
    if emin == 0 && emax == 0 {
        k = kfc_propagate_canonicalizing_src(k, src, mode);
    } else if emax <= 0 {
        if kfc_never(src, FCL_POS_INF) { k = kfc_known_not(k, FCL_POS_INF); }
        if kfc_never(src, FCL_NEG_INF) { k = kfc_known_not(k, FCL_NEG_INF); }
    } else if emin >= 0 {
        if kfc_never(src, FCL_POS_SUBNORMAL) { k = kfc_known_not(k, FCL_POS_SUBNORMAL); }
        if kfc_never(src, FCL_NEG_SUBNORMAL) { k = kfc_known_not(k, FCL_NEG_SUBNORMAL); }
        if kfc_never_logical_pos_zero(src, mode) { k = kfc_known_not(k, FCL_POS_ZERO); }
        if kfc_never_logical_neg_zero(src, mode) { k = kfc_known_not(k, FCL_NEG_ZERO); }
    }
    return k;
}
fn kfc_powi(src: KFC, e: KB) -> KFC {
    var k = kfc_propagate_nan(kfc_unknown(), src, false);
    let w = e.w as i64;
    let is_zero = e.z == wmask(w);
    if is_zero {
        if kfc_never(src, FCL_SNAN) { return kfc_known_not(k, fcl_not(FCL_POS_NORMAL)); }
        return kfc_known_not(k, fcl_not(FCL_POS_NORMAL | FCL_NAN));
    }
    let min_exp = sext_w(kb_smin(e), w);
    let max_exp = sext_w(kb_smax(e), w);
    let may_inf_src = !kfc_never(src, FCL_INF) && max_exp > 0;
    let may_div_by_zero = !kfc_never(src, FCL_ZERO) && min_exp < 0;
    let may_finite = !kfc_never(src, FCL_NORMAL | FCL_SUBNORMAL);
    let may_abs_gt1 = min_exp < -1 || max_exp > 1;
    let may_finite_overflow = may_finite && may_abs_gt1;
    let may_be_neg_one = e.z == 0;
    let may_subnorm_inv = !kfc_never(src, FCL_SUBNORMAL) && may_be_neg_one;
    if !may_inf_src && !may_div_by_zero && !may_finite_overflow && !may_subnorm_inv { k = kfc_known_not(k, FCL_INF); }
    if (e.z & 1) != 0 { return kfc_known_not(k, FCL_NEGATIVE); }
    if kfc_never(src, FCL_NEGATIVE) { k = kfc_known_not(k, FCL_NEGATIVE); }
    return k;
}

// ---------------------------------------------------------------------------------------------
// Constants

// APFloat::classify of one ConstantFP
fn cfp_class(c: i32) -> u64 {
    let p = cfp_parts(c);
    if p.cat == FC_NAN { return if cfp_is_signaling(c) { FCL_SNAN } else { FCL_QNAN }; }
    if p.cat == FC_INF { return if p.neg { FCL_NEG_INF } else { FCL_POS_INF }; }
    if p.cat == FC_ZERO { return if p.neg { FCL_NEG_ZERO } else { FCL_POS_ZERO }; }
    if p.expf == 0 { return if p.neg { FCL_NEG_SUBNORMAL } else { FCL_POS_SUBNORMAL }; }
    return if p.neg { FCL_NEG_NORMAL } else { FCL_POS_NORMAL };
}
fn cfp_is_signaling(c: i32) -> bool {
    let p = cfp_parts(c);
    if p.cat != FC_NAN { return false; }
    let f = fp_fmt(cfp_kind(c));
    let qb = f.p - 2;
    if cfp_kind(c) == TK_X86_FP80 { return ((cint_lo(c) >> 62) & 1) == 0; }
    if qb < 64 { return ((p.sig0 >> qb) & 1) == 0; }
    return ((p.sig1 >> (qb - 64)) & 1) == 0;
}
fn kfc_of_cfp(c: i32) -> KFC { KFC { known: cfp_class(c), sign: if cfp_parts(c).neg { 1 } else { 0 } } }
// ilogb(APFloat): IEK_NaN = INT_MIN, IEK_Zero = INT_MIN + 1, IEK_Inf = INT_MAX
fn cfp_ilogb(c: i32) -> i64 {
    let p = cfp_parts(c);
    if p.cat == FC_NAN { return -2147483648; }
    if p.cat == FC_ZERO { return -2147483647; }
    if p.cat == FC_INF { return 2147483647; }
    let f = fp_fmt(cfp_kind(c));
    let fb = if f.explicit_int { 63 } else { f.p - 1 };
    var msb: i64 = -1;
    if p.sig1 != 0 { msb = 64; var x = p.sig1; while x > 1 { x >>= 1; msb++; } }
    else { msb = 0; var x = p.sig0; while x > 1 { x >>= 1; msb++; } }
    return p.exponent + (msb - fb);
}
// |C| == 1.0
fn cfp_abs_is_one(c: i32) -> bool {
    let p = cfp_parts(c);
    if p.cat != FC_NORMAL || p.exponent != 0 { return false; }
    let f = fp_fmt(cfp_kind(c));
    let fb = if f.explicit_int { 63 } else { f.p - 1 };
    if fb < 64 { return p.sig0 == ((1 as u64) << fb) && p.sig1 == 0; }
    return p.sig0 == 0 && p.sig1 == ((1 as u64) << (fb - 64));
}
// APFloat::isSmallestNormalized (either sign)
fn cfp_is_smallest_normalized(c: i32) -> bool {
    let p = cfp_parts(c);
    if p.cat != FC_NORMAL || p.expf != 1 { return false; }
    let f = fp_fmt(cfp_kind(c));
    let fb = if f.explicit_int { 63 } else { f.p - 1 };
    if fb < 64 { return p.sig0 == ((1 as u64) << fb) && p.sig1 == 0; }
    return p.sig0 == 0 && p.sig1 == ((1 as u64) << (fb - 64));
}

// ---------------------------------------------------------------------------------------------
// fcmpImpliesClass / fcmpToClassTest (GenericFloatingPointPredicateUtils.h)

fn fpred_is_ord(p: i64) -> bool { p >= 1 && p <= 7 }
fn fpred_is_unord(p: i64) -> bool { p >= 8 && p <= 14 }

// fcmpImpliesClass(Pred, F, LHS, RHSClass, LookThroughSrc): (Src or -1, ClassIfTrue, ClassIfFalse)
fn fcmp_implies_class_mask(p: i64, fv: i32, l: i32, rhs_class0: u64, look_through: bool) -> i32, u64, u64 {
    var rhs_class = rhs_class0;
    var src = l;
    if p == 15 { return src, FCL_ALL, 0; }
    if p == 0 { return src, 0, FCL_ALL; }
    let orig = rhs_class;
    let is_neg_rhs = (rhs_class & FCL_NEGATIVE) == rhs_class;
    let is_pos_rhs = (rhs_class & FCL_POSITIVE) == rhs_class;
    let is_nan = (rhs_class & ~FCL_NAN) == 0;
    if is_nan {
        let m = if fpred_is_ord(p) { 0 } else { FCL_ALL };
        return src, m, fcl_not(m);
    }
    if p == 7 { return src, fcl_not(FCL_NAN), FCL_NAN; }
    if p == 8 { return src, FCL_NAN, fcl_not(FCL_NAN); }
    var is_fabs = false;
    if look_through && m_intrinsic(l, IID_fabs) { src = op(l, 0); is_fabs = true; }
    if is_fabs { rhs_class = fcl_inverse_fabs(rhs_class); }
    let is_zero = (orig & FCL_ZERO) == orig;
    if is_zero {
        let mode = fn_denormal_mode(fv, vals[l].ty);
        if dm_in(mode) != DMK_IEEE { return -1, FCL_ALL, FCL_ALL; }
        var m: u64 = 0;
        var exact_fabs = false;
        if p == 1 { m = FCL_ZERO; }
        else if p == 9 { m = FCL_ZERO | FCL_NAN; }
        else if p == 14 { m = fcl_not(FCL_ZERO); }
        else if p == 6 { m = fcl_not(FCL_NAN) & fcl_not(FCL_ZERO); }
        else if p == 2 { m = FCL_POS_SUBNORMAL | FCL_POS_NORMAL | FCL_POS_INF; exact_fabs = true; }
        else if p == 10 { m = FCL_POS_SUBNORMAL | FCL_POS_NORMAL | FCL_POS_INF | FCL_NAN; exact_fabs = true; }
        else if p == 3 { m = FCL_POSITIVE | FCL_NEG_ZERO; exact_fabs = true; }
        else if p == 11 { m = FCL_POSITIVE | FCL_NEG_ZERO | FCL_NAN; exact_fabs = true; }
        else if p == 4 { m = FCL_NEG_SUBNORMAL | FCL_NEG_NORMAL | FCL_NEG_INF; exact_fabs = true; }
        else if p == 12 { m = FCL_NEG_SUBNORMAL | FCL_NEG_NORMAL | FCL_NEG_INF | FCL_NAN; exact_fabs = true; }
        else if p == 5 { m = FCL_NEGATIVE | FCL_POS_ZERO; exact_fabs = true; }
        else if p == 13 { m = FCL_NEGATIVE | FCL_POS_ZERO | FCL_NAN; exact_fabs = true; }
        if exact_fabs && is_fabs { m = fcl_inverse_fabs(m); }
        return src, m, fcl_not(m);
    }
    let is_denormal_rhs = (orig & FCL_SUBNORMAL) == orig;
    let is_inf = (orig & FCL_INF) == orig;
    if is_inf {
        var m: u64 = FCL_ALL;
        if p == 1 || p == 14 {
            if is_neg_rhs { m = FCL_NEG_INF; if is_fabs { m = 0; } }
            else { m = FCL_POS_INF; if is_fabs { m |= FCL_NEG_INF; } }
        } else if p == 6 || p == 9 {
            if is_neg_rhs { m = fcl_not(FCL_NEG_INF) & fcl_not(FCL_NAN); if is_fabs { m = fcl_not(FCL_NAN); } }
            else { m = fcl_not(FCL_POS_INF) & fcl_not(FCL_NAN); if is_fabs { m &= fcl_not(FCL_NEG_INF); } }
        } else if p == 4 || p == 11 {
            if is_neg_rhs { m = 0; }
            else { m = FCL_FINITE; if !is_fabs { m |= FCL_NEG_INF; } }
        } else if p == 3 || p == 12 {
            if is_neg_rhs { m = fcl_not(FCL_NAN); }
            else { m = FCL_POS_INF; if is_fabs { m |= FCL_NEG_INF; } }
        } else if p == 2 || p == 13 {
            if is_neg_rhs { m = if is_fabs { fcl_not(FCL_NAN) } else { fcl_not(FCL_NEG_INF | FCL_NAN) }; }
            else { m = 0; }
        } else if p == 5 || p == 10 {
            if is_neg_rhs { m = if is_fabs { 0 } else { FCL_NEG_INF }; }
            else { m = fcl_not(FCL_NAN); }
        }
        if fpred_is_unord(p) { m = fcl_not(m); }
        return src, m, fcl_not(m);
    }
    if p == 1 { return src, rhs_class, FCL_ALL; }
    if p == 9 { return src, rhs_class | FCL_NAN, fcl_not(FCL_NAN); }
    if p == 6 { return src, fcl_not(FCL_NAN), rhs_class | FCL_NAN; }
    if p == 14 { return src, FCL_ALL, rhs_class; }
    if is_neg_rhs {
        if is_fabs {
            if p == 2 || p == 3 { return src, fcl_not(FCL_NAN), FCL_NAN; }
            if p == 10 || p == 11 { return src, FCL_ALL, 0; }
            if p == 4 || p == 5 { return src, 0, FCL_ALL; }
            if p == 12 || p == 13 { return src, FCL_NAN, fcl_not(FCL_NAN); }
            return -1, FCL_ALL, FCL_ALL;
        }
        var cle = FCL_NEG_INF | FCL_NEG_NORMAL;
        var cge = FCL_POSITIVE | FCL_NEG_ZERO | FCL_NEG_SUBNORMAL;
        if is_denormal_rhs { cle |= FCL_NEG_SUBNORMAL; } else { cge |= FCL_NEG_NORMAL; }
        if p == 2 || p == 3 { return src, cge, fcl_not(cge) | rhs_class; }
        if p == 10 || p == 11 { return src, cge | FCL_NAN, fcl_not(cge | FCL_NAN) | rhs_class; }
        if p == 4 || p == 5 { return src, cle, fcl_not(cle) | rhs_class; }
        if p == 12 || p == 13 { return src, cle | FCL_NAN, fcl_not(cle | FCL_NAN) | rhs_class; }
    } else if is_pos_rhs {
        var cge = FCL_POS_NORMAL | FCL_POS_INF;
        var cle = FCL_NEGATIVE | FCL_POS_ZERO | FCL_POS_SUBNORMAL;
        if is_denormal_rhs { cge |= FCL_POS_SUBNORMAL; } else { cle |= FCL_POS_NORMAL; }
        if is_fabs { cge = fcl_inverse_fabs(cge); cle = fcl_inverse_fabs(cle); }
        if p == 2 || p == 3 { return src, cge, fcl_not(cge) | rhs_class; }
        if p == 10 || p == 11 { return src, cge | FCL_NAN, fcl_not(cge | FCL_NAN) | rhs_class; }
        if p == 4 || p == 5 { return src, cle, fcl_not(cle) | rhs_class; }
        if p == 12 || p == 13 { return src, cle | FCL_NAN, fcl_not(cle | FCL_NAN) | rhs_class; }
    }
    return -1, FCL_ALL, FCL_ALL;
}

// fcmpImpliesClass(Pred, F, LHS, const APFloat &ConstRHS, LookThroughSrc); c is a scalar ConstantFP
fn fcmp_implies_class(p: i64, fv: i32, l: i32, c: i32, look_through: bool) -> i32, u64, u64 {
    if !cfp_parts(c).neg && cfp_is_smallest_normalized(c) {
        var src = l;
        var is_fabs = false;
        if look_through && m_intrinsic(l, IID_fabs) { src = op(l, 0); is_fabs = true; }
        var m: u64 = 0;
        if p == 4 || p == 11 {
            m = FCL_ZERO | FCL_SUBNORMAL;
            if !is_fabs { m |= FCL_NEG_NORMAL | FCL_NEG_INF; }
        } else if p == 3 || p == 12 {
            m = FCL_POS_INF | FCL_POS_NORMAL;
            if is_fabs { m |= FCL_NEG_INF | FCL_NEG_NORMAL; }
        } else {
            return fcmp_implies_class_mask(p, fv, l, cfp_class(c), look_through);
        }
        if fpred_is_unord(p) { m = fcl_not(m); }
        return src, m, fcl_not(m);
    }
    return fcmp_implies_class_mask(p, fv, l, cfp_class(c), look_through);
}

// fcmpToClassTest(Pred, F, LHS, ConstRHS, LookThroughSrc = false): (class value or -1, test mask)
fn fcmp_to_class_test(p: i64, fv: i32, l: i32, c: i32) -> i32, u64 { let a, b = fcmp_to_class_test_lt(p, fv, l, c, false); return a, b; }
fn fcmp_to_class_test_lt(p: i64, fv: i32, l: i32, c: i32, look_through: bool) -> i32, u64 {
    let src, t, f = fcmp_implies_class(p, fv, l, c, look_through);
    if src >= 0 && t == fcl_not(f) { return src, t; }
    return -1, FCL_ALL;
}

// ---------------------------------------------------------------------------------------------
// computeKnownFPClass

// isSignBitCheck(Pred, RHS): (is a sign bit check, TrueIfSigned)
fn is_sign_bit_check(p: i64, rhs: u64, w: i64) -> bool, bool {
    let m = wmask(w);
    let smax = (sbit(w) - 1) & m;
    let smin = sbit(w);
    let r = rhs & m;
    if p == 40 { return r == 0, true; }
    if p == 41 { return r == m, true; }
    if p == 38 { return r == m, false; }
    if p == 39 { return r == 0, false; }
    if p == 34 { return r == smax, true; }
    if p == 35 { return r == smin, true; }
    if p == 36 { return r == smin, false; }
    if p == 37 { return r == smax, false; }
    return false, false;
}

// computeKnownFPClassFromCond(V, Cond, CondIsTrue, CxtI, KnownFromContext, Depth)
recursive fn kfc_from_cond(v: i32, cond: i32, cond_true: bool, known0: KFC, depth: i64) -> KFC {
    var known = known0;
    if depth < MAX_ANALYSIS_DEPTH {
        if (cond_true && m_logical(cond, true)) || (!cond_true && m_logical(cond, false)) {
            let a = lg_a;
            let b = lg_b;
            known = kfc_from_cond(v, a, cond_true, known, depth + 1);
            return kfc_from_cond(v, b, cond_true, known, depth + 1);
        }
        let na = m_not(cond);
        if na >= 0 { return kfc_from_cond(v, na, !cond_true, known, depth + 1); }
    }
    if is_inst_op(cond, OP_FCMP) {
        let c = m_apfloat(op(cond, 1));
        if c >= 0 {
            let l = op(cond, 0);
            let cv, mt, mf = fcmp_implies_class(inst_pred(cond), inst_func(cond), l, c, l != v);
            if cv == v { known = kfc_known_not(known, fcl_not(if cond_true { mt } else { mf })); }
        }
        return known;
    }
    if m_intrinsic(cond, IID_is_fpclass) && op(cond, 0) == v {
        let ci = m_constant_int(op(cond, 1));
        if ci >= 0 {
            let mask = ci_val(ci) & FCL_ALL;
            known = kfc_known_not(known, if cond_true { fcl_not(mask) } else { mask });
        }
        return known;
    }
    if is_inst_op(cond, OP_ICMP) {
        let a = op(cond, 0);
        if is_op(a, OP_BITCAST) && elementwise_bitcast_v(a) && op(a, 0) == v {
            let rc = m_apint(op(cond, 1));
            if rc >= 0 {
                let w = ci_w(rc);
                if w > 64 { pm_wide(); }
                let ok, tis = is_sign_bit_check(inst_pred(cond), ci_val(rc), w);
                if !ok { return known; }
                if tis == cond_true { known = kfc_sign_bit_must_be_one(known); }
                else { known = kfc_sign_bit_must_be_zero(known); }
            }
        }
    }
    return known;
}

// computeKnownFPClassFromContext(V, Q): no CondContext / DomConditionCache in this pipeline; assumptions only
recursive fn kfc_from_context(v: i32) -> KFC {
    var known = kfc_unknown();
    if kb_cxt < 0 { return known; }
    if !ac_ready() { return known; }
    let cx = kb_cxt;
    var k: i64 = 0;
    while k < ac_val.len {
        let ent = k;
        k++;
        if ac_val[ent] != v { continue; }
        let a = ac_asm[ent];
        if a < 0 || is_dead(a) { continue; }
        if !valid_assume_for_context(a, cx) { continue; }
        known = kfc_from_cond(v, op(a, 0), true, known, 0);
    }
    return known;
}

// adjustKnownFPClassForSelectArm
recursive fn kfc_adjust_for_select_arm(known: KFC, cond: i32, arm: i32, invert: bool, depth: i64) -> KFC {
    var src = kfc_from_cond(arm, cond, !invert, kfc_unknown(), depth + 1);
    src = kfc_union_with(src, known);
    if kfc_is_unknown(src) { return known; }
    if is_guaranteed_not_to_be_undef(arm, kb_cxt, depth + 1) { return src; }
    return known;
}

fn nofpclass_of(s: i32) -> u64 {
    let at = aset_find(s, AK_NoFPClass);
    if at < 0 { return 0; }
    return attrs[at].i1 & FCL_ALL;
}

fn fp_ty_kind(ty: i32) -> i64 { types[ty_scalar(ty)].kind as i64 }

fn reverse_bits_n(x: u64, n: i64) -> u64 {
    var r: u64 = 0;
    for i in n { if ((x >> i) & 1) != 0 { r |= (1 as u64) << (n - 1 - i); } }
    return r;
}

// isAbsoluteValueULEOne
fn is_abs_value_ule_one(v: i32) -> bool {
    if is_op(v, OP_FSUB) {
        let x = op(v, 0);
        let f = op(v, 1);
        if m_intrinsic(f, IID_floor) && op(f, 0) == x { return true; }
    }
    return m_intrinsic(v, IID_amdgcn_trig_preop) || m_intrinsic(v, IID_amdgcn_fract);
}

fn mmk_of(id: i32) -> i64 {
    if id == IID_minimum { return MMK_MINIMUM; }
    if id == IID_maximum { return MMK_MAXIMUM; }
    if id == IID_minimumnum { return MMK_MINIMUMNUM; }
    if id == IID_maximumnum { return MMK_MAXIMUMNUM; }
    if id == IID_minnum { return MMK_MINNUM; }
    return MMK_MAXNUM;
}

// computeKnownFPClass(V, DemandedElts, InterestedClasses, Known, Q, Depth)
recursive fn kfc_compute(v: i32, de: u64, interested0: u64, depth: i64) -> KFC {
    var interested = interested0;
    if de == 0 { return kfc_unknown(); }
    let k = vals[v].kind;
    let ty = vals[v].ty;
    if k == VK_CFP {
        let s = if ty_is_vector(ty) { splat_value(v, false) } else { v };
        if s >= 0 { return kfc_of_cfp(s); }
    }
    if k == VK_AGGZERO { return KFC { known: FCL_POS_ZERO, sign: 0 }; }
    if k == VK_POISON { return KFC { known: 0, sign: 0 }; }
    if ty_kind(ty) == TK_FVEC && is_constant(v) {
        var known: u64 = 0;
        var all_zero = true;
        var all_one = true;
        for i in ty_count(ty) {
            if ((de >> i) & 1) == 0 { continue; }
            let e = agg_elem(v, i);
            if e < 0 { return kfc_unknown(); }
            if vals[e].kind == VK_POISON { continue; }
            if vals[e].kind != VK_CFP { return kfc_unknown(); }
            known |= cfp_class(e);
            if cfp_parts(e).neg { all_zero = false; } else { all_one = false; }
        }
        return KFC { known: known, sign: if all_one != all_zero { if all_one { 1 } else { 0 } } else { -1 } };
    }
    if k == VK_CDVECTOR || k == VK_CDARRAY || k == VK_CARRAY || k == VK_CSTRUCT {
        fp_not_ported("known FP class of a constant aggregate");
    }
    var knot: u64 = 0;
    if k == VK_INST && iop(v) == OP_CALL {
        knot |= nofpclass_of(alist_ret(insts[inst_of(v)].attrs));
        let f = cb_callee(v);
        if is_func(f) { knot |= nofpclass_of(alist_ret(globs[glob_of(f)].attrs)); }
    } else if k == VK_ARG {
        knot |= nofpclass_of(arg_attrs(v));
    }
    let is_operator = k == VK_INST || k == VK_CEXPR;
    if is_operator {
        let fmf = inst_fmf(v);
        if (fmf & FMF_NNAN) != 0 { knot |= FCL_NAN; }
        if (fmf & FMF_NINF) != 0 { knot |= FCL_INF; }
    }
    let assumed = kfc_from_context(v);
    knot |= fcl_not(assumed.known);
    interested &= ~knot;
    var known = kfc_unknown();
    if is_operator && depth != MAX_ANALYSIS_DEPTH {
        known = kfc_from_operator(v, de, interested, knot, depth);
    }
    // scope_exit ClearClassesFromFlags
    known = kfc_known_not(known, knot);
    if known.sign < 0 && assumed.sign >= 0 {
        if assumed.sign == 1 { known = kfc_sign_bit_must_be_one(known); } else { known = kfc_sign_bit_must_be_zero(known); }
    }
    return known;
}

recursive fn kfc_compute_all(v: i32, interested: u64, depth: i64) -> KFC {
    let t = vals[v].ty;
    var de: u64 = 1;
    if ty_kind(t) == TK_FVEC { de = all_elts(v); }
    return kfc_compute(v, de, interested, depth);
}

// computeKnownFPClass(V, DemandedElts, FMF, InterestedClasses, SQ, Depth)
recursive fn kfc_compute_fmf(v: i32, de: u64, fmf: u8, interested0: u64, depth: i64) -> KFC {
    var interested = interested0;
    if (fmf & FMF_NNAN) != 0 { interested &= ~FCL_NAN; }
    if (fmf & FMF_NINF) != 0 { interested &= ~FCL_INF; }
    var r = kfc_compute(v, de, interested, depth);
    if (fmf & FMF_NNAN) != 0 { r.known &= ~FCL_NAN; }
    if (fmf & FMF_NINF) != 0 { r.known &= ~FCL_INF; }
    return r;
}

// The public entry point: computeKnownFPClass(V, FMF, InterestedClasses, Q, Depth), context in kb_cxt
recursive fn known_fp_class(v: i32, interested: u64, fmf: u8, depth: i64) -> KFC {
    let t = vals[v].ty;
    var de: u64 = 1;
    if ty_kind(t) == TK_FVEC { de = all_elts(v); }
    return kfc_compute_fmf(v, de, fmf, interested, depth);
}
recursive fn known_fp_class_de(v: i32, de: u64, interested: u64, depth: i64) -> KFC { kfc_compute(v, de, interested, depth) }

// cannotBeNegativeZero / cannotBeOrderedLessThanZero / isKnownNeverInfinity / isKnownNeverInfOrNaN / isKnownNeverNaN
recursive fn cannot_be_negative_zero(v: i32, depth: i64) -> bool { kfc_never(kfc_compute_all(v, FCL_NEG_ZERO, depth), FCL_NEG_ZERO) }
recursive fn cannot_be_ordered_less_than_zero(v: i32, depth: i64) -> bool { kfc_cannot_be_ordered_lt_zero(kfc_compute_all(v, FCL_ORDERED_LT_ZERO_MASK, depth)) }
recursive fn is_known_never_infinity(v: i32, depth: i64) -> bool { kfc_never_inf(kfc_compute_all(v, FCL_INF, depth)) }
recursive fn is_known_never_inf_or_nan(v: i32, depth: i64) -> bool { kfc_never_inf_or_nan(kfc_compute_all(v, FCL_INF | FCL_NAN, depth)) }
recursive fn is_known_never_nan(v: i32, depth: i64) -> bool { kfc_never_nan(kfc_compute_all(v, FCL_NAN, depth)) }
recursive fn compute_known_fp_sign_bit(v: i32, depth: i64) -> i64 { kfc_compute_all(v, FCL_ALL, depth).sign }

recursive fn kfc_one_src(v: i32, de: u64, interested: u64, depth: i64) -> KFC { kfc_compute(v, de, interested, depth + 1) }

// The Operator switch of computeKnownFPClass
recursive fn kfc_from_operator(v: i32, de: u64, interested: u64, knot: u64, depth: i64) -> KFC {
    var known = kfc_unknown();
    let o = opcode_of(v);
    let ty = vals[v].ty;
    if o == OP_FNEG {
        return kfc_fneg(kfc_compute(op(v, 0), de, interested, depth + 1));
    }
    if o == OP_SELECT {
        let c = op(v, 0);
        var r1 = kfc_compute(op(v, 1), de, interested, depth + 1);
        r1 = kfc_adjust_for_select_arm(r1, c, op(v, 1), false, depth);
        var r2 = kfc_compute(op(v, 2), de, interested, depth + 1);
        r2 = kfc_adjust_for_select_arm(r2, c, op(v, 2), true, depth);
        return kfc_intersect_with(r1, r2);
    }
    if o == OP_LOAD {
        let md = inst_get_md(v, md_kind_id("nofpclass"));
        if md < 0 { return known; }
        let mv = cint_lo(mds[md_op(md, 0)].extra);
        return kfc_known_not(known, mv & FCL_ALL);
    }
    if o == OP_CALL && is_inst(v) {
        return kfc_call(v, de, interested, knot, depth);
    }
    if o == OP_FADD || o == OP_FSUB {
        let want_negative = o == OP_FADD && (interested & FCL_ORDERED_LT_ZERO_MASK) != 0;
        let want_nan = (interested & FCL_NAN) != 0;
        let want_neg_zero = (interested & FCL_NEG_ZERO) != 0;
        if !want_nan && !want_negative && !want_neg_zero { return known; }
        var isrc = interested;
        if want_negative { isrc |= FCL_ORDERED_LT_ZERO_MASK; }
        if (interested & FCL_NAN) != 0 { isrc |= FCL_INF; }
        let kr = kfc_compute(op(v, 1), de, isrc, depth + 1);
        let is_self = op(v, 0) == op(v, 1) && is_guaranteed_not_to_be_undef(op(v, 0), kb_cxt, depth + 1);
        var kl = kfc_unknown();
        if is_self { kl = kr; }
        if (want_nan && kfc_never_nan(kr)) || (want_negative && kfc_cannot_be_ordered_lt_zero(kr)) || want_neg_zero || o == OP_FSUB {
            let mode = inst_denormal_mode(v);
            if is_self && o == OP_FADD {
                known = kfc_fadd_self(kl, mode);
            } else {
                if !is_self { kl = kfc_compute(op(v, 0), de, isrc, depth + 1); }
                known = if o == OP_FADD { kfc_fadd(kl, kr, mode) } else { kfc_fsub(kl, kr, mode) };
            }
        }
        return known;
    }
    if o == OP_FMUL {
        let mode = inst_denormal_mode(v);
        let l = op(v, 0);
        let r = op(v, 1);
        if l == r {
            let ks = kfc_compute(l, de, FCL_ALL, depth + 1);
            return kfc_square(ks, mode);
        }
        var kl = kfc_unknown();
        var kr = kfc_unknown();
        let cr = m_apfloat(r);
        if cr >= 0 {
            kl = kfc_compute(l, de, FCL_ALL, depth + 1);
            known = kfc_fmul_const(kl, cr, mode);
        } else {
            kr = kfc_compute(r, de, FCL_ALL, depth + 1);
            kl = kfc_compute(l, de, FCL_ALL, depth + 1);
            known = kfc_fmul(kl, kr, mode);
        }
        if kfc_never(kl, FCL_INF) && is_abs_value_ule_one(r) { known = kfc_known_not(known, FCL_INF); }
        else if kfc_never(kr, FCL_INF) && is_abs_value_ule_one(l) { known = kfc_known_not(known, FCL_INF); }
        return known;
    }
    if o == OP_FDIV || o == OP_FREM {
        let want_nan = (interested & FCL_NAN) != 0;
        if o == OP_FREM { known = kfc_known_not(known, FCL_INF); }
        if op(v, 0) == op(v, 1) && is_guaranteed_not_to_be_undef(op(v, 0), kb_cxt, 0) {
            if o == OP_FDIV { known.known = FCL_NAN | FCL_POS_NORMAL; } else { known.known = FCL_NAN | FCL_ZERO; }
            if !want_nan { return known; }
            let ks = kfc_compute(op(v, 0), de, FCL_NAN | FCL_INF | FCL_ZERO | FCL_SUBNORMAL, depth + 1);
            let mode = inst_denormal_mode(v);
            return if o == OP_FDIV { kfc_fdiv_self(ks, mode) } else { kfc_frem_self(ks, mode) };
        }
        let want_negative = (interested & FCL_NEGATIVE) != 0;
        let want_positive = o == OP_FREM && (interested & FCL_POSITIVE) != 0;
        if !want_nan && !want_negative && !want_positive { return known; }
        var kl = kfc_unknown();
        let kr = kfc_compute(op(v, 1), de, FCL_NAN | FCL_INF | FCL_ZERO | FCL_NEGATIVE, depth + 1);
        let useful = kfc_never_nan(kr) || kfc_never(kr, FCL_NEGATIVE) || kfc_never(kr, FCL_POSITIVE);
        if useful || want_positive { kl = kfc_compute(op(v, 0), de, FCL_ALL, depth + 1); }
        let fv = if is_inst(v) { inst_func(v) } else { -1 };
        if o == OP_FDIV {
            return kfc_fdiv(kl, kr, inst_denormal_mode(v));
        }
        if kfc_never_nan(kl) && kfc_never_nan(kr) && kfc_never_inf(kl) && fv >= 0 && kfc_never_logical_zero(kr, fn_denormal_mode(fv, ty)) {
            known = kfc_known_not(known, FCL_NAN);
        }
        if kfc_cannot_be_ordered_lt_zero(kl) { known = kfc_known_not(known, FCL_ORDERED_LT_ZERO_MASK); }
        if kfc_cannot_be_ordered_gt_zero(kl) { known = kfc_known_not(known, FCL_ORDERED_GT_ZERO_MASK); }
        if kfc_never(kl, FCL_NEGATIVE) { known = kfc_known_not(known, FCL_NEGATIVE); }
        if kfc_never(kl, FCL_POSITIVE) { known = kfc_known_not(known, FCL_POSITIVE); }
        return known;
    }
    if o == OP_FPEXT {
        let ks = kfc_compute(op(v, 0), de, interested, depth + 1);
        return kfc_fpext(ks, fp_ty_kind(ty), fp_ty_kind(vals[op(v, 0)].ty));
    }
    if o == OP_FPTRUNC {
        if (interested & (FCL_ORDERED_LT_ZERO_MASK | FCL_NAN)) == 0 { return known; }
        return kfc_fptrunc(kfc_compute(op(v, 0), de, interested, depth + 1));
    }
    if o == OP_SITOFP || o == OP_UITOFP {
        known = kfc_known_not(known, FCL_NAN);
        known = kfc_known_not(known, FCL_SUBNORMAL);
        known = kfc_known_not(known, FCL_NEG_ZERO);
        if o == OP_UITOFP { known = kfc_sign_bit_must_be_zero(known); }
        if (interested & (FCL_POS_ZERO | FCL_NORMAL | FCL_INF)) == 0 { return known; }
        let ik = kb_compute(op(v, 0), de, depth + 1);
        if kb_is_nonzero(ik) { known = kfc_known_not(known, FCL_POS_ZERO); }
        if o == OP_SITOFP {
            if kb_is_nonneg(ik) { known = kfc_sign_bit_must_be_zero(known); }
            else if kb_is_neg(ik) { known = kfc_sign_bit_must_be_one(known); }
        }
        if (interested & FCL_INF) != 0 {
            var isz = ik.w as i64;
            if o == OP_UITOFP { isz -= kb_min_lz(ik); } else { isz -= kb_min_sign_bits_k(ik); }
            // ilogb(getLargest(Sem)) == maxExponent == bias
            if fp_fmt(fp_ty_kind(ty)).bias >= isz { known = kfc_known_not(known, FCL_INF); }
        }
        return known;
    }
    if o == OP_EXTRACTELEMENT {
        let vec = op(v, 0);
        var dv: u64 = 1;
        if ty_kind(vals[vec].ty) == TK_FVEC {
            let n = ty_count(vals[vec].ty);
            dv = all_elts(vec);
            let ci = m_constant_int(op(v, 1));
            if ci >= 0 && ci_val(ci) < n as u64 { dv = (1 as u64) << ci_val(ci); }
        }
        return kfc_compute(vec, dv, interested, depth + 1);
    }
    if o == OP_INSERTELEMENT {
        if ty_kind(ty) == TK_SVEC { return known; }
        let vec = op(v, 0);
        let elt = op(v, 1);
        let ci = m_constant_int(op(v, 2));
        let n = ty_count(ty);
        var dv = de;
        var needs_elt = true;
        if ci >= 0 && ci_val(ci) < n as u64 {
            dv &= ~((1 as u64) << ci_val(ci));
            needs_elt = ((de >> ci_val(ci)) & 1) != 0;
        }
        if needs_elt {
            known = kfc_compute_all(elt, interested, depth + 1);
            if kfc_is_unknown(known) { return known; }
        } else {
            known.known = 0;
        }
        if dv != 0 {
            let k2 = kfc_compute(vec, dv, interested, depth + 1);
            known = kfc_or(known, k2);
        }
        return known;
    }
    if o == OP_SHUFFLEVECTOR {
        let sp = get_splat_value_v(v);
        if sp >= 0 { return kfc_compute_all(sp, interested, depth + 1); }
        if !is_inst(v) { return known; }
        let ok, dl, dr = shuffle_demanded(v, de);
        if !ok { return known; }
        if dl != 0 {
            known = kfc_compute(op(v, 0), dl, interested, depth + 1);
            if kfc_is_unknown(known) { return known; }
        } else {
            known.known = 0;
        }
        if dr != 0 {
            let k2 = kfc_compute(op(v, 1), dr, interested, depth + 1);
            known = kfc_or(known, k2);
        }
        return known;
    }
    if o == OP_EXTRACTVALUE {
        let src = op(v, 0);
        let x = insts[inst_of(v)];
        if ty_kind(vals[src].ty) == TK_STRUCT && x.naux == 1 && ints[x.aux] == 0 {
            if m_intrinsic(src, IID_frexp) {
                let ks = kfc_compute(op(src, 0), de, interested, depth + 1);
                return kfc_frexp_mant(ks, inst_denormal_mode(v));
            }
        }
        return kfc_compute(src, de, interested, depth + 1);
    }
    if o == OP_PHI {
        return kfc_phi(v, de, interested, depth);
    }
    if o == OP_BITCAST {
        let src = op(v, 0);
        if !elementwise_bitcast_v(v) || !is_int_or_int_vec(vals[src].ty) { return known; }
        if m_max_or_min(src) {
            let a = mm_a;
            let b = mm_b;
            if is_op(a, OP_BITCAST) && is_op(b, OP_BITCAST) {
                let cl = op(a, 0);
                let cr = op(b, 0);
                if vals[cl].ty == ty && vals[cr].ty == ty {
                    let kr = kfc_compute(cr, de, interested, depth + 1);
                    if !kfc_is_unknown(kr) {
                        let kl = kfc_compute(cl, de, interested, depth + 1);
                        known = kfc_or(kl, kr);
                    }
                    return known;
                }
            }
        }
        let bits = kb_compute(src, de, depth + 1);
        return kfc_bitcast(fp_ty_kind(ty), bits);
    }
    return known;
}

recursive fn kfc_phi(v: i32, de: u64, interested: u64, depth: i64) -> KFC {
    var known = kfc_unknown();
    let n = nops(v);
    if n == 0 { return known; }
    let limit = MAX_ANALYSIS_DEPTH - 2;
    if depth < limit {
        let hc = phi_has_constant_value(v);
        if hc >= 0 && (vals[hc].kind == VK_UNDEF || vals[hc].kind == VK_POISON) { return known; }
        var first = true;
        for i in n {
            let inc, cxt, _ph = break_self_recursive_phi(v, i);
            if inc == v { continue; }
            let save = kb_cxt;
            kb_cxt = cxt;
            let ks = kfc_compute(inc, de, interested, limit);
            kb_cxt = save;
            if first { known = ks; first = false; } else { known = kfc_or(known, ks); }
            if known.known == FCL_ALL { break; }
        }
    }
    if n != 2 || kfc_cannot_be_ordered_lt_zero(known) { return known; }
    for i in 2 {
        let rv = op(v, 1 - i);
        if inst_iid(rv) == 0 { continue; }
        // matchSimpleTernaryIntrinsicRecurrence(II, PN, Init, L, R) && PN == P
        if cb_nargs(rv) != 3 { continue; }
        let rty = vals[rv].ty;
        if vals[op(rv, 0)].ty != rty || vals[op(rv, 1)].ty != rty || vals[op(rv, 2)].ty != rty { continue; }
        var pn: i32 = -1;
        if is_inst_op(op(rv, 0), OP_PHI) { pn = op(rv, 0); }
        else if is_inst_op(op(rv, 1), OP_PHI) { pn = op(rv, 1); }
        else if is_inst_op(op(rv, 2), OP_PHI) { pn = op(rv, 2); }
        if pn != v { continue; }
        // matchThreeInputRecurrence(P, II, Init, L, R) && II == I
        var found = false;
        var init: i32 = -1;
        var l: i32 = -1;
        var r: i32 = -1;
        for j in 2 {
            let opn = op(pn, j);
            if !is_inst(opn) || inst_iid(opn) == 0 || nops(opn) < 3 { continue; }
            let o0 = op(opn, 0);
            let o1 = op(opn, 1);
            let o2 = op(opn, 2);
            if o0 != pn && o1 != pn && o2 != pn { continue; }
            if opn != rv { break; }
            init = op(pn, 1 - j);
            if o0 == pn { l = o1; r = o2; } else if o1 == pn { l = o0; r = o2; } else { l = o0; r = o1; }
            found = true;
            break;
        }
        if !found { continue; }
        let id = inst_iid(rv);
        if id == IID_fma || id == IID_fmuladd {
            let kst = kfc_compute(init, de, interested, depth + 1);
            if kfc_cannot_be_ordered_lt_zero(kst) && l == r && is_guaranteed_not_to_be_undef(l, kb_cxt, depth + 1) {
                known = kfc_known_not(known, FCL_ORDERED_LT_ZERO_MASK);
            }
        }
    }
    return known;
}

recursive fn kfc_call(v: i32, de: u64, interested: u64, knot: u64, depth: i64) -> KFC {
    var known = kfc_unknown();
    let id = inst_iid(v);
    if id == 0 { return known; }
    let ty = vals[v].ty;
    if id == IID_fabs {
        if (interested & (FCL_NAN | FCL_POSITIVE)) != 0 { known = kfc_compute(op(v, 0), de, interested, depth + 1); }
        return kfc_fabs(known);
    }
    if id == IID_copysign {
        known = kfc_compute(op(v, 0), de, interested, depth + 1);
        let ks = kfc_compute(op(v, 1), de, interested, depth + 1);
        return kfc_copysign(known, ks);
    }
    if id == IID_fma || id == IID_fmuladd {
        if (interested & FCL_NEGATIVE) == 0 { return known; }
        if op(v, 0) == op(v, 1) {
            var ka = kfc_compute(op(v, 2), de, interested, depth + 1);
            var ks = kfc_compute(op(v, 0), de, interested, depth + 1);
            let mode = inst_denormal_mode(v);
            if (knot & FCL_NAN) != 0 { ks = kfc_known_not(ks, FCL_NAN); ka = kfc_known_not(ka, FCL_NAN); }
            if (knot & FCL_INF) != 0 { ks = kfc_known_not(ks, FCL_INF); ka = kfc_known_not(ka, FCL_INF); }
            return kfc_fma_square(ks, ka, mode);
        }
        var k0 = kfc_compute(op(v, 0), de, interested, depth + 1);
        if kfc_is_unknown(k0) { return known; }
        if (knot & FCL_NAN) != 0 { k0 = kfc_known_not(k0, FCL_NAN); }
        if (knot & FCL_INF) != 0 { k0 = kfc_known_not(k0, FCL_INF); }
        var k1 = kfc_compute(op(v, 1), de, interested, depth + 1);
        if kfc_is_unknown(k1) { return known; }
        if (knot & FCL_NAN) != 0 { k1 = kfc_known_not(k1, FCL_NAN); }
        if (knot & FCL_INF) != 0 { k1 = kfc_known_not(k1, FCL_INF); }
        var k2 = kfc_compute(op(v, 2), de, interested, depth + 1);
        if kfc_is_unknown(k2) { return known; }
        if (knot & FCL_NAN) != 0 { k2 = kfc_known_not(k2, FCL_NAN); }
        if (knot & FCL_INF) != 0 { k2 = kfc_known_not(k2, FCL_INF); }
        return kfc_fma(k0, k1, k2, inst_denormal_mode(v));
    }
    if id == IID_sqrt || id == IID_experimental_constrained_sqrt {
        var isrc = interested;
        if (interested & FCL_NAN) != 0 { isrc |= FCL_ORDERED_LT_ZERO_MASK; }
        let ks = kfc_compute(op(v, 0), de, isrc, depth + 1);
        var mode = DM_DYNAMIC;
        let nsz = (inst_fmf(v) & FMF_NSZ) != 0;
        if !nsz { mode = inst_denormal_mode(v); }
        known = kfc_sqrt(ks, mode);
        if nsz { known = kfc_known_not(known, FCL_NEG_ZERO); }
        return known;
    }
    if id == IID_sin || id == IID_cos || id == IID_tan {
        return kfc_sin(kfc_compute(op(v, 0), de, interested, depth + 1));
    }
    if id == IID_sinh { return kfc_sinh(kfc_compute(op(v, 0), de, interested, depth + 1)); }
    if id == IID_cosh { return kfc_cosh(kfc_compute(op(v, 0), de, interested, depth + 1)); }
    if id == IID_tanh { return kfc_tanh(kfc_compute(op(v, 0), de, interested, depth + 1)); }
    if id == IID_asin { return kfc_asin(kfc_compute(op(v, 0), de, interested, depth + 1)); }
    if id == IID_acos { return kfc_acos(kfc_compute(op(v, 0), de, interested, depth + 1)); }
    if id == IID_atan { return kfc_atan(kfc_compute(op(v, 0), de, interested, depth + 1)); }
    if id == IID_atan2 {
        let kl = kfc_compute(op(v, 0), de, interested, depth + 1);
        let kr = kfc_compute(op(v, 1), de, interested, depth + 1);
        return kfc_atan2(kl, kr);
    }
    if id == IID_maxnum || id == IID_minnum || id == IID_minimum || id == IID_maximum || id == IID_minimumnum || id == IID_maximumnum {
        let kl = kfc_compute(op(v, 0), de, interested, depth + 1);
        let kr = kfc_compute(op(v, 1), de, interested, depth + 1);
        return kfc_min_max_like(kl, kr, mmk_of(id), inst_denormal_mode(v));
    }
    if id == IID_canonicalize {
        let ks = kfc_compute(op(v, 0), de, interested, depth + 1);
        return kfc_canonicalize(ks, inst_denormal_mode(v));
    }
    if id == IID_vector_reduce_fmax || id == IID_vector_reduce_fmin || id == IID_vector_reduce_fmaximum || id == IID_vector_reduce_fminimum {
        let a = op(v, 0);
        var dea: u64 = 1;
        if ty_kind(vals[a].ty) == TK_FVEC { dea = all_elts(a); }
        known = kfc_compute_fmf(a, dea, inst_fmf(v), interested, depth + 1);
        if !kfc_never_nan(known) { known.sign = -1; }
        return known;
    }
    if id == IID_vector_reverse {
        let a = op(v, 0);
        var der = de;
        if ty_kind(vals[a].ty) == TK_FVEC { der = reverse_bits_n(de, ty_count(vals[a].ty)); }
        return kfc_compute_fmf(a, der, inst_fmf(v), interested, depth + 1);
    }
    if id == IID_trunc || id == IID_floor || id == IID_ceil || id == IID_rint || id == IID_nearbyint || id == IID_round || id == IID_roundeven {
        var isrc = interested;
        if (isrc & FCL_POS_FINITE) != 0 { isrc |= FCL_POS_FINITE; }
        if (isrc & FCL_NEG_FINITE) != 0 { isrc |= FCL_NEG_FINITE; }
        let ks = kfc_compute(op(v, 0), de, isrc, depth + 1);
        return kfc_round_to_integral(ks, id == IID_trunc, fp_ty_kind(ty) == TK_PPC_FP128);
    }
    if id == IID_exp || id == IID_exp2 || id == IID_exp10 {
        return kfc_exp(kfc_compute(op(v, 0), de, interested, depth + 1));
    }
    if id == IID_fptrunc_round {
        if (interested & (FCL_ORDERED_LT_ZERO_MASK | FCL_NAN)) == 0 { return known; }
        return kfc_fptrunc(kfc_compute(op(v, 0), de, interested, depth + 1));
    }
    if id == IID_log || id == IID_log10 || id == IID_log2 || id == IID_experimental_constrained_log ||
       id == IID_experimental_constrained_log10 || id == IID_experimental_constrained_log2 {
        if (interested & (FCL_NAN | FCL_INF)) != 0 {
            var isrc = interested;
            if (interested & FCL_NEG_INF) != 0 { isrc |= FCL_ZERO | FCL_SUBNORMAL; }
            if (interested & FCL_NAN) != 0 { isrc |= FCL_NAN | FCL_NEGATIVE; }
            let ks = kfc_compute(op(v, 0), de, isrc, depth + 1);
            known = kfc_log(ks, inst_denormal_mode(v));
        }
        return known;
    }
    if id == IID_powi {
        if (interested & (FCL_NAN | FCL_INF | FCL_NEGATIVE)) == 0 { return known; }
        let e = op(v, 1);
        let et = vals[e].ty;
        let ek = kb_compute(e, if ty_is_vector(et) { de } else { 1 }, depth + 1);
        var isrc: u64 = 0;
        if (interested & FCL_NAN) != 0 { isrc |= FCL_NAN; }
        let ezero = ek.z == wmask(ek.w as i64);
        if !ezero {
            if (interested & FCL_INF) != 0 { isrc |= FCL_FINITE | FCL_INF; }
            if (interested & FCL_NEGATIVE) != 0 && (ek.z & 1) == 0 { isrc |= FCL_NEGATIVE; }
        }
        var ks = kfc_unknown();
        if isrc != 0 { ks = kfc_compute(op(v, 0), de, isrc, depth + 1); }
        return kfc_powi(ks, ek);
    }
    if id == IID_ldexp {
        let ks = kfc_compute(op(v, 0), de, interested, depth + 1);
        let ea = op(v, 1);
        let ew = ty_scalar_bits(vals[ea].ty);
        var cr = cr_full(ew);
        if (ks.known & (FCL_ZERO | FCL_SUBNORMAL | FCL_INF)) != 0 { cr = compute_constant_range(ea, true, true, depth + 1); }
        let emin = sext_w(cr_smin(cr), ew);
        let emax = sext_w(cr_smax(cr), ew);
        return kfc_ldexp(ks, emin, emax, fp_ty_kind(ty), inst_denormal_mode(v));
    }
    if id == IID_arithmetic_fence {
        return kfc_compute(op(v, 0), de, interested, depth + 1);
    }
    if id == IID_experimental_constrained_sitofp || id == IID_experimental_constrained_uitofp {
        known = kfc_known_not(known, FCL_NAN);
        known = kfc_known_not(known, FCL_NEG_ZERO);
        known = kfc_known_not(known, FCL_SUBNORMAL);
        if id == IID_experimental_constrained_uitofp { known = kfc_sign_bit_must_be_zero(known); }
        return known;
    }
    if id == IID_amdgcn_exp2 || id == IID_amdgcn_log || id == IID_amdgcn_fract || id == IID_amdgcn_rcp || id == IID_amdgcn_rsq || id == IID_amdgcn_trig_preop {
        fp_not_ported("known FP class of AMDGPU intrinsics");
    }
    return known;
}

// ---------------------------------------------------------------------------------------------
// ConstantFPRange (IEEE formats of at most 64 bits). Values are ordered keys: +x -> bits, -x -> -(magnitude bits) - 1,
// so -0 < +0 and the order matches strictCompare.

struct CFR { lo: i64, hi: i64, qnan: bool, snan: bool, kind: i64 }

fn fpr_check_kind(kind: i64) {
    if !(kind == TK_HALF || kind == TK_BFLOAT || kind == TK_FLOAT || kind == TK_DOUBLE) {
        fp_not_ported("ConstantFPRange for this floating-point type");
    }
}
fn fpr_inf_key(kind: i64) -> i64 {
    let f = fp_fmt(kind);
    return ((((1 as u64) << f.ebits) - 1) << (f.p - 1)) as! i64;
}
fn fpr_pos_inf(kind: i64) -> i64 { fpr_inf_key(kind) }
fn fpr_neg_inf(kind: i64) -> i64 { -fpr_inf_key(kind) - 1 }
fn fpr_key_of(c: i32) -> i64 {
    let kind = cfp_kind(c);
    let f = fp_fmt(kind);
    let b = cint_lo(c);
    let sb: u64 = (1 as u64) << (f.total - 1);
    let mag = (b & (sb - 1)) as! i64;
    if (b & sb) != 0 { return -mag - 1; }
    return mag;
}
fn fpr_empty(kind: i64) -> CFR { CFR { lo: fpr_pos_inf(kind), hi: fpr_neg_inf(kind), qnan: false, snan: false, kind: kind } }
fn fpr_full(kind: i64) -> CFR { CFR { lo: fpr_neg_inf(kind), hi: fpr_pos_inf(kind), qnan: true, snan: true, kind: kind } }
fn fpr_non_nan(kind: i64) -> CFR { CFR { lo: fpr_neg_inf(kind), hi: fpr_pos_inf(kind), qnan: false, snan: false, kind: kind } }
fn fpr_nan_only(kind: i64, q: bool, s: bool) -> CFR { CFR { lo: fpr_pos_inf(kind), hi: fpr_neg_inf(kind), qnan: q, snan: s, kind: kind } }
fn fpr_is_nan_only(a: CFR) -> bool { a.lo == fpr_pos_inf(a.kind) && a.hi == fpr_neg_inf(a.kind) }
fn fpr_contains_nan(a: CFR) -> bool { a.qnan || a.snan }
fn fpr_next(k: i64, down: bool) -> i64 {
    if down { return if k == 0 { -2 } else { k - 1 }; }
    return if k == -1 { 1 } else { k + 1 };
}
fn fpr_canonical(lo: i64, hi: i64, q: bool, s: bool, kind: i64) -> CFR {
    let pinf = fpr_pos_inf(kind);
    let ninf = fpr_neg_inf(kind);
    let lo_inf = lo == pinf || lo == ninf;
    let hi_inf = hi == pinf || hi == ninf;
    if lo > hi && !(lo_inf && hi_inf) { return CFR { lo: pinf, hi: ninf, qnan: q, snan: s, kind: kind }; }
    return CFR { lo: lo, hi: hi, qnan: q, snan: s, kind: kind };
}
// ConstantFPRange(const APFloat &)
fn fpr_of_const(c: i32) -> CFR {
    let kind = cfp_kind(c);
    fpr_check_kind(kind);
    if cfp_parts(c).cat == FC_NAN {
        let s = cfp_is_signaling(c);
        return fpr_nan_only(kind, !s, s);
    }
    let k = fpr_key_of(c);
    return CFR { lo: k, hi: k, qnan: false, snan: false, kind: kind };
}
fn fpr_make_less_than(v0: i64, p: i64, kind: i64) -> CFR {
    var v = v0;
    if (p & 1) == 0 {
        if v == fpr_neg_inf(kind) { return fpr_empty(kind); }
        v = fpr_next(v, true);
    }
    return fpr_canonical(fpr_neg_inf(kind), v, false, false, kind);
}
fn fpr_make_greater_than(v0: i64, p: i64, kind: i64) -> CFR {
    var v = v0;
    if (p & 1) == 0 {
        if v == fpr_pos_inf(kind) { return fpr_empty(kind); }
        v = fpr_next(v, false);
    }
    return fpr_canonical(v, fpr_pos_inf(kind), false, false, kind);
}
fn fpr_extend_zero_if_equal(a: CFR, p: i64) -> CFR {
    if (p & 1) == 0 { return a; }
    var r = a;
    if r.lo == 0 { r.lo = -1; }
    if r.hi == -1 { r.hi = 0; }
    return r;
}
fn fpr_set_nan_field(a: CFR, p: i64) -> CFR {
    var r = a;
    let u = fpred_is_unord(p);
    r.qnan = u;
    r.snan = u;
    return r;
}
// makeSatisfyingFCmpRegion(Pred, Other) for a single-constant Other
fn fpr_make_satisfying(p: i64, o: CFR) -> CFR {
    let kind = o.kind;
    if fpr_is_empty(o) { return fpr_full(kind); }
    if fpr_contains_nan(o) && fpred_is_ord(p) { return fpr_empty(kind); }
    if fpr_is_nan_only(o) && fpred_is_unord(p) { return fpr_full(kind); }
    if p == 15 { return fpr_full(kind); }
    if p == 0 { return fpr_empty(kind); }
    if p == 7 { return fpr_non_nan(kind); }
    if p == 8 { return fpr_nan_only(kind, true, true); }
    if p == 1 || p == 9 {
        let single = o.lo == o.hi;
        // (Other.classify() & ~fcNan) == fcZero: both bounds zeros
        let zeros = (o.lo == 0 || o.lo == -1) && (o.hi == 0 || o.hi == -1);
        return fpr_set_nan_field(if single || zeros { fpr_extend_zero_if_equal(o, p) } else { fpr_empty(kind) }, p);
    }
    if p == 6 || p == 14 { return fpr_empty(kind); }
    if p == 4 || p == 5 || p == 12 || p == 13 {
        return fpr_set_nan_field(fpr_extend_zero_if_equal(fpr_make_less_than(o.lo, p, kind), p), p);
    }
    return fpr_set_nan_field(fpr_extend_zero_if_equal(fpr_make_greater_than(o.hi, p, kind), p), p);
}
// ConstantFPRange::makeExactFCmpRegion(Pred, C): ok = false for std::nullopt
fn fpr_exact_fcmp_region(p: i64, c: i32) -> bool, CFR {
    if (p == 14 || p == 6) && cfp_parts(c).cat != FC_NAN { return false, fpr_empty(TK_FLOAT); }
    return true, fpr_make_satisfying(p, fpr_of_const(c));
}
fn fpr_intersect(a: CFR, b: CFR) -> CFR {
    let lo = if a.lo > b.lo { a.lo } else { b.lo };
    let hi = if a.hi < b.hi { a.hi } else { b.hi };
    return fpr_canonical(lo, hi, a.qnan && b.qnan, a.snan && b.snan, a.kind);
}
fn fpr_is_empty(a: CFR) -> bool { a.lo == fpr_pos_inf(a.kind) && a.hi == fpr_neg_inf(a.kind) && !a.qnan && !a.snan }
fn fpr_contains(a: CFR, b: CFR) -> bool {
    if b.qnan && !a.qnan { return false; }
    if b.snan && !a.snan { return false; }
    return a.lo <= b.lo && b.hi <= a.hi;
}

// isImpliedCondFCmps(LPred, L0, L1, RPred, R0, R1, LHSIsTrue): 1 true, 0 false, -1 unknown
fn implied_cond_fcmps(lp0: i64, l00: i32, l10: i32, rp0: i64, r00: i32, r10: i32, lhs_true: bool) -> i64 {
    var lp = lp0;
    var rp = rp0;
    var l0 = l00;
    var l1 = l10;
    var r0 = r00;
    var r1 = r10;
    if !lhs_true { lp = 15 - lp; }
    if l0 == r1 { let t = r0; r0 = r1; r1 = t; rp = fpred_swap(rp); }
    if r0 == l1 { let t = l0; l0 = l1; l1 = t; lp = fpred_swap(lp); }
    if l1 == r1 {
        if l0 != r0 || m_imm_constant(l0) {
            let t = l0; l0 = l1; l1 = t; lp = fpred_swap(lp);
            let t2 = r0; r0 = r1; r1 = t2; rp = fpred_swap(rp);
        }
    }
    if l0 == r0 && l1 == r1 {
        if (lp & rp) == lp { return 1; }
        if (lp & ~rp & 15) == lp { return 0; }
    }
    let lc = m_apfloat(l1);
    let rc = m_apfloat(r1);
    if l0 == r0 && lc >= 0 && rc >= 0 {
        let ok, dom = fpr_exact_fcmp_region(lp, lc);
        if ok {
            let ok2, imp = fpr_exact_fcmp_region(rp, rc);
            if ok2 && fpr_contains(imp, dom) { return 1; }
            let ok3, imp2 = fpr_exact_fcmp_region(15 - rp, rc);
            if ok3 && fpr_contains(imp2, dom) { return 0; }
        }
    }
    return -1;
}
fn fpred_swap(p: i64) -> i64 {
    match p { 2 => 4, 3 => 5, 4 => 2, 5 => 3, 10 => 12, 11 => 13, 12 => 10, 13 => 11, _ => p }
}

// isImpliedCondition(LHS, fcmp Pred, L, R, LHSIsTrue)
fn implied_condition_fcmp(cond: i32, p: i64, l: i32, r: i32, lhs_true: bool) -> i64 {
    return implied_condition(cond, p, l, r, lhs_true, 0);
}
