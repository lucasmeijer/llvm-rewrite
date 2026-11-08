// ConstantRange: a port of llvm/lib/IR/ConstantRange.cpp (and llvm/include/llvm/IR/ConstantRange.h) on the
// 256-bit APInt of apint.goose. Ranges are [lo, hi) modulo 2^w; lo == hi is the full set when lo is the max
// value and the empty set when lo is zero, exactly as in LLVM. Every operation that doubles the bit width
// (multiply) works for widths up to 128; everything else up to 256.
//
// Reusable API (prefix rg_): rg_full/rg_empty/rg_single/rg_new (asserting ctor)/rg_nonempty (getNonEmpty);
// queries rg_is_full/empty/wrapped/upper_wrapped/sign_wrapped/single/single_missing/contains/contains_ap,
// rg_umin/umax/smin/smax, rg_active_bits/min_signed_bits, rg_is_size_larger_than, rg_is_all_negative/
// nonneg/positive; set ops rg_intersect/rg_union (with rg_pref: RG_SMALLEST/RG_UNSIGNED/RG_SIGNED),
// rg_exact_intersect/rg_exact_union, rg_inverse, rg_difference; icmp regions rg_allowed_icmp/
// rg_satisfying_icmp/rg_exact_icmp/rg_icmp/rg_equivalent_icmp; rg_guaranteed_no_wrap; arithmetic rg_binop/
// rg_overflowing_binop/rg_cast/rg_truncate_nw/rg_zext/rg_sext/rg_add/rg_sub/rg_multiply/... and
// rg_intrinsic (rg_is_intrinsic_supported); KnownBits rg_from_kb/rg_to_kb; IR glue rg_of_const
// (Constant::toConstantRange), rg_from_range_md (getConstantRangeFromMetadata), rg_from_range_attr,
// rg_attr (a uniqued `range` attribute); conversion to the 64-bit crange.goose CR: rg_from_cr/rg_to_cr.
import std;
import ir;
import irutil;
import apint;
import constfold;
import crange;
import knownbits;
import gen_attrs;
import gen_iids;
import pm;
import implied;

struct CRange { lo: AP, hi: AP }

let RG_SMALLEST = 0;
let RG_UNSIGNED = 1;
let RG_SIGNED = 2;

// OverflowingBinaryOperator / TruncInst no-wrap kinds
let NW_NUW = 1;
let NW_NSW = 2;

fn rg_w(c: CRange) -> i64 { c.lo.w as i64 }
fn rg_full(w: i64) -> CRange { let m = ap_ones(w); return CRange { lo: m, hi: m }; }
fn rg_empty(w: i64) -> CRange { let z = ap_zero(w); return CRange { lo: z, hi: z }; }
fn rg_single(x: AP) -> CRange { CRange { lo: x, hi: ap_inc(x) } }
fn rg_new(lo: AP, hi: AP) -> CRange {
    if ap_eq(lo, hi) && !ap_is_zero(lo) && !ap_is_all_ones(lo) { fatal("ConstantRange: Lower == Upper, but they aren't min or max value"); }
    return CRange { lo: lo, hi: hi };
}
// getNonEmpty
fn rg_nonempty(lo: AP, hi: AP) -> CRange { if ap_eq(lo, hi) { rg_full(lo.w as i64) } else { CRange { lo: lo, hi: hi } } }
fn rg_eq(a: CRange, b: CRange) -> bool { ap_eq(a.lo, b.lo) && ap_eq(a.hi, b.hi) }

fn rg_is_full(c: CRange) -> bool { ap_eq(c.lo, c.hi) && ap_is_all_ones(c.lo) }
fn rg_is_empty(c: CRange) -> bool { ap_eq(c.lo, c.hi) && ap_is_zero(c.lo) }
fn rg_is_wrapped(c: CRange) -> bool { ap_ugt(c.lo, c.hi) && !ap_is_zero(c.hi) }
fn rg_is_upper_wrapped(c: CRange) -> bool { ap_ugt(c.lo, c.hi) }
fn rg_is_sign_wrapped(c: CRange) -> bool { ap_sgt(c.lo, c.hi) && !ap_is_min_signed(c.hi) }
fn rg_is_upper_sign_wrapped(c: CRange) -> bool { ap_sgt(c.lo, c.hi) }
fn rg_is_single(c: CRange) -> bool { ap_eq(c.hi, ap_inc(c.lo)) }
fn rg_is_single_missing(c: CRange) -> bool { ap_eq(c.lo, ap_inc(c.hi)) }
// getSingleElement / getSingleMissingElement values (valid only when the predicate holds)
fn rg_single_elt(c: CRange) -> AP { c.lo }
fn rg_single_missing_elt(c: CRange) -> AP { c.hi }

fn rg_size_strictly_smaller(a: CRange, b: CRange) -> bool {
    if rg_is_full(a) { return false; }
    if rg_is_full(b) { return true; }
    return ap_ult(ap_sub(a.hi, a.lo), ap_sub(b.hi, b.lo));
}
fn rg_is_size_larger_than(c: CRange, max: u64) -> bool {
    if rg_is_full(c) { return max == 0 || ap_ugt_u64(ap_ones(rg_w(c)), max - 1); }
    return ap_ugt_u64(ap_sub(c.hi, c.lo), max);
}
fn rg_is_all_negative(c: CRange) -> bool {
    if rg_is_empty(c) { return true; }
    if rg_is_full(c) { return false; }
    return !rg_is_upper_sign_wrapped(c) && !ap_is_strictly_pos(c.hi);
}
fn rg_is_all_nonneg(c: CRange) -> bool { !rg_is_sign_wrapped(c) && ap_is_nonneg(c.lo) }
fn rg_is_all_positive(c: CRange) -> bool {
    if rg_is_empty(c) { return true; }
    if rg_is_full(c) { return false; }
    return !rg_is_sign_wrapped(c) && ap_is_strictly_pos(c.lo);
}

fn rg_umax(c: CRange) -> AP { if rg_is_full(c) || rg_is_upper_wrapped(c) { ap_ones(rg_w(c)) } else { ap_dec(c.hi) } }
fn rg_umin(c: CRange) -> AP { if rg_is_full(c) || rg_is_wrapped(c) { ap_zero(rg_w(c)) } else { c.lo } }
fn rg_smax(c: CRange) -> AP { if rg_is_full(c) || rg_is_upper_sign_wrapped(c) { ap_smax_val(rg_w(c)) } else { ap_dec(c.hi) } }
fn rg_smin(c: CRange) -> AP { if rg_is_full(c) || rg_is_sign_wrapped(c) { ap_smin_val(rg_w(c)) } else { c.lo } }

fn rg_contains_ap(c: CRange, v: AP) -> bool {
    if ap_eq(c.lo, c.hi) { return rg_is_full(c); }
    if !rg_is_upper_wrapped(c) { return ap_ule(c.lo, v) && ap_ult(v, c.hi); }
    return ap_ule(c.lo, v) || ap_ult(v, c.hi);
}
fn rg_contains(a: CRange, b: CRange) -> bool {
    if rg_is_full(a) || rg_is_empty(b) { return true; }
    if rg_is_empty(a) || rg_is_full(b) { return false; }
    if !rg_is_upper_wrapped(a) {
        if rg_is_upper_wrapped(b) { return false; }
        return ap_ule(a.lo, b.lo) && ap_ule(b.hi, a.hi);
    }
    if !rg_is_upper_wrapped(b) { return ap_ule(b.hi, a.hi) || ap_ule(a.lo, b.lo); }
    return ap_ule(b.hi, a.hi) && ap_ule(a.lo, b.lo);
}
fn rg_active_bits(c: CRange) -> i64 { if rg_is_empty(c) { 0 } else { ap_active_bits(rg_umax(c)) } }
fn rg_min_signed_bits(c: CRange) -> i64 {
    if rg_is_empty(c) { return 0; }
    let a = ap_sig_bits(rg_smin(c));
    let b = ap_sig_bits(rg_smax(c));
    return if a > b { a } else { b };
}
fn rg_subtract(c: CRange, v: AP) -> CRange { if ap_eq(c.lo, c.hi) { c } else { rg_new(ap_sub(c.lo, v), ap_sub(c.hi, v)) } }
fn rg_inverse(c: CRange) -> CRange {
    if rg_is_full(c) { return rg_empty(rg_w(c)); }
    if rg_is_empty(c) { return rg_full(rg_w(c)); }
    return CRange { lo: c.hi, hi: c.lo };
}
fn rg_difference(a: CRange, b: CRange) -> CRange { rg_intersect(a, rg_inverse(b)) }

// ---------------------------------------------------------------------------------------------
// KnownBits at the range's width (only what fromKnownBits/toKnownBits and the bitwise ops need)

fn rg_from_kb(k: KB, signed: bool) -> CRange {
    let w = k.z.w as i64;
    if !ap_is_zero(ap_and(k.z, k.o)) { return rg_empty(w); }
    if ap_is_zero(k.z) && ap_is_zero(k.o) { return rg_full(w); }
    let minv = k.o;
    let maxv = ap_not(k.z);
    let neg = ap_get_bit(k.o, w - 1);
    let nonneg = ap_get_bit(k.z, w - 1);
    if !signed || neg || nonneg { return rg_new(minv, ap_inc(maxv)); }
    let lo = ap_set_bit(minv, w - 1);
    let hi = ap_clear_bit(maxv, w - 1);
    return rg_new(lo, ap_inc(hi));
}
fn rg_to_kb(c: CRange) -> KB {
    let w = rg_w(c);
    if rg_is_empty(c) { return KB { z: ap_zero(w), o: ap_zero(w) }; }
    let mn = rg_umin(c);
    let mx = rg_umax(c);
    var z = ap_not(mn);
    var o = mn;
    let d = ap_most_sig_diff_bit(mn, mx);
    if d >= 0 {
        z = ap_clear_low_bits(z, d + 1);
        o = ap_clear_low_bits(o, d + 1);
    }
    return KB { z: z, o: o };
}
fn rg_from_cr(c: CR) -> CRange { CRange { lo: ap_u64(c.lo, c.w as i64), hi: ap_u64(c.hi, c.w as i64) } }
fn rg_to_cr(c: CRange) -> CR {
    if rg_w(c) > 64 { fatal("ConstantRange: conversion of a range wider than 64 bits to CR"); }
    return cr_new(ap_lo64(c.lo), ap_lo64(c.hi), rg_w(c));
}

// ---------------------------------------------------------------------------------------------
// Set operations

fn rg_preferred(a: CRange, b: CRange, t: i64) -> CRange {
    if t == RG_UNSIGNED {
        if !rg_is_wrapped(a) && rg_is_wrapped(b) { return a; }
        if rg_is_wrapped(a) && !rg_is_wrapped(b) { return b; }
    } else if t == RG_SIGNED {
        if !rg_is_sign_wrapped(a) && rg_is_sign_wrapped(b) { return a; }
        if rg_is_sign_wrapped(a) && !rg_is_sign_wrapped(b) { return b; }
    }
    if rg_size_strictly_smaller(a, b) { return a; }
    return b;
}

fn rg_intersect_t(a: CRange, b: CRange, t: i64) -> CRange {
    if rg_is_empty(a) || rg_is_full(b) { return a; }
    if rg_is_empty(b) || rg_is_full(a) { return b; }
    let w = rg_w(a);
    if !rg_is_upper_wrapped(a) && rg_is_upper_wrapped(b) { return rg_intersect_t2(b, a, t); }
    return rg_intersect_t2(a, b, t);
}
// the body of intersectWith after the swap (a is upper-wrapped if b is)
fn rg_intersect_t2(a: CRange, b: CRange, t: i64) -> CRange {
    let w = rg_w(a);
    let lower = a.lo;
    let upper = a.hi;
    if !rg_is_upper_wrapped(a) && !rg_is_upper_wrapped(b) {
        if ap_ult(lower, b.lo) {
            if ap_ule(upper, b.lo) { return rg_empty(w); }
            if ap_ult(upper, b.hi) { return rg_new(b.lo, upper); }
            return b;
        }
        if ap_ult(upper, b.hi) { return a; }
        if ap_ult(lower, b.hi) { return rg_new(lower, b.hi); }
        return rg_empty(w);
    }
    if rg_is_upper_wrapped(a) && !rg_is_upper_wrapped(b) {
        if ap_ult(b.lo, upper) {
            if ap_ult(b.hi, upper) { return b; }
            if ap_ule(b.hi, lower) { return rg_new(b.lo, upper); }
            return rg_preferred(a, b, t);
        }
        if ap_ult(b.lo, lower) {
            if ap_ule(b.hi, lower) { return rg_empty(w); }
            return rg_new(lower, b.hi);
        }
        return b;
    }
    if ap_ult(b.hi, upper) {
        if ap_ult(b.lo, upper) { return rg_preferred(a, b, t); }
        if ap_ult(b.lo, lower) { return rg_new(lower, b.hi); }
        return b;
    }
    if ap_ule(b.hi, lower) {
        if ap_ult(b.lo, lower) { return a; }
        return rg_new(b.lo, upper);
    }
    return rg_preferred(a, b, t);
}
fn rg_intersect(a: CRange, b: CRange) -> CRange { rg_intersect_t(a, b, RG_SMALLEST) }

fn rg_union_t(a: CRange, b: CRange, t: i64) -> CRange {
    if rg_is_full(a) || rg_is_empty(b) { return a; }
    if rg_is_full(b) || rg_is_empty(a) { return b; }
    if !rg_is_upper_wrapped(a) && rg_is_upper_wrapped(b) { return rg_union_t2(b, a, t); }
    return rg_union_t2(a, b, t);
}
fn rg_union_t2(a: CRange, b: CRange, t: i64) -> CRange {
    let w = rg_w(a);
    let lower = a.lo;
    let upper = a.hi;
    if !rg_is_upper_wrapped(a) && !rg_is_upper_wrapped(b) {
        if ap_ult(b.hi, lower) || ap_ult(upper, b.lo) {
            return rg_preferred(rg_new(lower, b.hi), rg_new(b.lo, upper), t);
        }
        let l = if ap_ult(b.lo, lower) { b.lo } else { lower };
        let u = if ap_ugt(ap_dec(b.hi), ap_dec(upper)) { b.hi } else { upper };
        if ap_is_zero(l) && ap_is_zero(u) { return rg_full(w); }
        return rg_new(l, u);
    }
    if !rg_is_upper_wrapped(b) {
        if ap_ule(b.hi, upper) || ap_uge(b.lo, lower) { return a; }
        if ap_ule(b.lo, upper) && ap_ule(lower, b.hi) { return rg_full(w); }
        if ap_ult(upper, b.lo) && ap_ult(b.hi, lower) {
            return rg_preferred(rg_new(lower, b.hi), rg_new(b.lo, upper), t);
        }
        if ap_ult(upper, b.lo) && ap_ule(lower, b.hi) { return rg_new(b.lo, upper); }
        return rg_new(lower, b.hi);
    }
    if ap_ule(b.lo, upper) || ap_ule(lower, b.hi) { return rg_full(w); }
    let l = if ap_ult(b.lo, lower) { b.lo } else { lower };
    let u = if ap_ugt(b.hi, upper) { b.hi } else { upper };
    return rg_new(l, u);
}
fn rg_union(a: CRange, b: CRange) -> CRange { rg_union_t(a, b, RG_SMALLEST) }

// exactIntersectWith / exactUnionWith: (ok, result)
fn rg_exact_intersect(a: CRange, b: CRange) -> bool, CRange {
    let r = rg_intersect(a, b);
    return rg_eq(r, rg_inverse(rg_union(rg_inverse(a), rg_inverse(b)))), r;
}
fn rg_exact_union(a: CRange, b: CRange) -> bool, CRange {
    let r = rg_union(a, b);
    return rg_eq(r, rg_inverse(rg_intersect(rg_inverse(a), rg_inverse(b)))), r;
}

// ---------------------------------------------------------------------------------------------
// ICmp regions (predicates are pm.goose's P_*: CmpInst::Predicate values)

fn rg_allowed_icmp(p: i64, c: CRange) -> CRange {
    if rg_is_empty(c) { return c; }
    let w = rg_w(c);
    if p == P_EQ { return c; }
    if p == P_NE {
        if rg_is_single(c) { return rg_new(c.hi, c.lo); }
        return rg_full(w);
    }
    if p == P_ULT {
        let m = rg_umax(c);
        if ap_is_zero(m) { return rg_empty(w); }
        return rg_new(ap_zero(w), m);
    }
    if p == P_SLT {
        let m = rg_smax(c);
        if ap_is_min_signed(m) { return rg_empty(w); }
        return rg_new(ap_smin_val(w), m);
    }
    if p == P_ULE { return rg_nonempty(ap_zero(w), ap_inc(rg_umax(c))); }
    if p == P_SLE { return rg_nonempty(ap_smin_val(w), ap_inc(rg_smax(c))); }
    if p == P_UGT {
        let m = rg_umin(c);
        if ap_is_all_ones(m) { return rg_empty(w); }
        return rg_new(ap_inc(m), ap_zero(w));
    }
    if p == P_SGT {
        let m = rg_smin(c);
        if ap_is_max_signed(m) { return rg_empty(w); }
        return rg_new(ap_inc(m), ap_smin_val(w));
    }
    if p == P_UGE { return rg_nonempty(rg_umin(c), ap_zero(w)); }
    if p == P_SGE { return rg_nonempty(rg_smin(c), ap_smin_val(w)); }
    fatal("ConstantRange: invalid ICmp predicate to makeAllowedICmpRegion()");
    return c;
}
fn rg_icmp_inverse(p: i64) -> i64 {
    if p == P_EQ { return P_NE; } if p == P_NE { return P_EQ; }
    if p == P_UGT { return P_ULE; } if p == P_ULE { return P_UGT; }
    if p == P_UGE { return P_ULT; } if p == P_ULT { return P_UGE; }
    if p == P_SGT { return P_SLE; } if p == P_SLE { return P_SGT; }
    if p == P_SGE { return P_SLT; } if p == P_SLT { return P_SGE; }
    fatal("ConstantRange: not an icmp predicate");
    return p;
}
fn rg_satisfying_icmp(p: i64, c: CRange) -> CRange { rg_inverse(rg_allowed_icmp(rg_icmp_inverse(p), c)) }
fn rg_exact_icmp(p: i64, c: AP) -> CRange { rg_allowed_icmp(p, rg_single(c)) }

fn rg_icmp(p: i64, a: CRange, b: CRange) -> bool {
    if rg_is_empty(a) || rg_is_empty(b) { return true; }
    if p == P_EQ {
        if rg_is_single(a) && rg_is_single(b) { return ap_eq(a.lo, b.lo); }
        return false;
    }
    if p == P_NE { return rg_contains(rg_inverse(a), b); }
    if p == P_ULT { return ap_ult(rg_umax(a), rg_umin(b)); }
    if p == P_ULE { return ap_ule(rg_umax(a), rg_umin(b)); }
    if p == P_UGT { return ap_ugt(rg_umin(a), rg_umax(b)); }
    if p == P_UGE { return ap_uge(rg_umin(a), rg_umax(b)); }
    if p == P_SLT { return ap_slt(rg_smax(a), rg_smin(b)); }
    if p == P_SLE { return ap_sle(rg_smax(a), rg_smin(b)); }
    if p == P_SGT { return ap_sgt(rg_smin(a), rg_smax(b)); }
    if p == P_SGE { return ap_sge(rg_smin(a), rg_smax(b)); }
    fatal("ConstantRange: invalid ICmp predicate");
    return false;
}

// getEquivalentICmp(Pred, RHS, Offset): returns pred, rhs, offset
fn rg_equivalent_icmp_off(c: CRange) -> i64, AP, AP {
    let w = rg_w(c);
    let zero = ap_zero(w);
    if rg_is_full(c) || rg_is_empty(c) {
        return if rg_is_empty(c) { P_ULT } else { P_UGE }, zero, zero;
    }
    if rg_is_single(c) { return P_EQ, c.lo, zero; }
    if rg_is_single_missing(c) { return P_NE, c.hi, zero; }
    if ap_is_min_signed(c.lo) || ap_is_zero(c.lo) {
        return if ap_is_min_signed(c.lo) { P_SLT } else { P_ULT }, c.hi, zero;
    }
    if ap_is_min_signed(c.hi) || ap_is_zero(c.hi) {
        return if ap_is_min_signed(c.hi) { P_SGE } else { P_UGE }, c.lo, zero;
    }
    return P_ULT, ap_sub(c.hi, c.lo), ap_neg(c.lo);
}
// getEquivalentICmp(Pred, RHS) -> bool
fn rg_equivalent_icmp(c: CRange) -> bool, i64, AP {
    let p, rhs, off = rg_equivalent_icmp_off(c);
    return ap_is_zero(off), p, rhs;
}

// ---------------------------------------------------------------------------------------------
// No-wrap regions

fn rg_exact_mul_nuw_region(v: AP) -> CRange {
    let w = v.w as i64;
    if ap_is_zero(v) { return rg_full(w); }
    return rg_nonempty(ap_rounding_udiv(ap_zero(w), v, true), ap_inc(ap_rounding_udiv(ap_ones(w), v, false)));
}
fn rg_exact_mul_nsw_region(v: AP) -> CRange {
    let w = v.w as i64;
    if ap_is_zero(v) { return rg_full(w); }
    let minv = ap_smin_val(w);
    let maxv = ap_smax_val(w);
    if ap_is_all_ones(v) { return rg_new(ap_neg(maxv), minv); }
    var lower = ap_zero(w);
    var upper = ap_zero(w);
    if ap_is_neg(v) {
        lower = ap_rounding_sdiv(maxv, v, true);
        upper = ap_rounding_sdiv(minv, v, false);
    } else {
        lower = ap_rounding_sdiv(minv, v, true);
        upper = ap_rounding_sdiv(maxv, v, false);
    }
    return rg_nonempty(lower, ap_inc(upper));
}

// makeGuaranteedNoWrapRegion(BinOp, Other, NoWrapKind)
fn rg_guaranteed_no_wrap(o: i64, other: CRange, nwk: i64) -> CRange {
    let unsigned = nwk == NW_NUW;
    let w = rg_w(other);
    if o == OP_ADD {
        if unsigned { return rg_nonempty(ap_zero(w), ap_neg(rg_umax(other))); }
        let smv = ap_smin_val(w);
        let smin = rg_smin(other);
        let smax = rg_smax(other);
        return rg_nonempty(if ap_is_neg(smin) { ap_sub(smv, smin) } else { smv },
                           if ap_is_strictly_pos(smax) { ap_sub(smv, smax) } else { smv });
    }
    if o == OP_SUB {
        if unsigned { return rg_nonempty(rg_umax(other), ap_zero(w)); }
        let smv = ap_smin_val(w);
        let smin = rg_smin(other);
        let smax = rg_smax(other);
        return rg_nonempty(if ap_is_strictly_pos(smax) { ap_add(smv, smax) } else { smv },
                           if ap_is_neg(smin) { ap_add(smv, smin) } else { smv });
    }
    if o == OP_MUL {
        if unsigned { return rg_exact_mul_nuw_region(rg_umax(other)); }
        if rg_is_single(other) { return rg_exact_mul_nsw_region(other.lo); }
        return rg_intersect(rg_exact_mul_nsw_region(rg_smin(other)), rg_exact_mul_nsw_region(rg_smax(other)));
    }
    if o == OP_SHL {
        let sh = rg_intersect(other, rg_new(ap_zero(w), ap_u64((w - 1 + 1) as u64, w)));
        if rg_is_empty(sh) { return rg_full(w); }
        let shmax = rg_umax(sh);
        if unsigned { return rg_nonempty(ap_zero(w), ap_inc(ap_lshr_ap(ap_ones(w), shmax))); }
        return rg_nonempty(ap_ashr_ap(ap_smin_val(w), shmax), ap_inc(ap_ashr_ap(ap_smax_val(w), shmax)));
    }
    fatal("ConstantRange: unsupported binary op for makeGuaranteedNoWrapRegion");
    return other;
}
fn rg_exact_no_wrap(o: i64, c: AP, nwk: i64) -> CRange { rg_guaranteed_no_wrap(o, rg_single(c), nwk) }

// makeMaskNotEqualRange
fn rg_mask_not_equal(mask: AP, c: AP) -> CRange {
    let w = mask.w as i64;
    if !ap_eq(ap_and(mask, c), c) { return rg_full(w); }
    if ap_is_zero(mask) { return rg_empty(w); }
    return rg_nonempty(ap_add(ap_one_bit(w, ap_countr_zero(mask)), c), c);
}

// ---------------------------------------------------------------------------------------------
// Casts

fn rg_zext(c: CRange, dw: i64) -> CRange {
    if rg_is_empty(c) { return rg_empty(dw); }
    let sw = rg_w(c);
    if dw == sw { return c; }
    if rg_is_full(c) || rg_is_upper_wrapped(c) {
        var le = ap_zero(dw);
        if ap_is_zero(c.hi) { le = ap_zext(c.lo, dw); }
        return rg_new(le, ap_one_bit(dw, sw));
    }
    return rg_new(ap_zext(c.lo, dw), ap_zext(c.hi, dw));
}
fn rg_sext(c: CRange, dw: i64) -> CRange {
    if rg_is_empty(c) { return rg_empty(dw); }
    let sw = rg_w(c);
    if dw == sw { return c; }
    if ap_is_min_signed(c.hi) { return rg_new(ap_sext(c.lo, dw), ap_zext(c.hi, dw)); }
    if rg_is_full(c) || rg_is_sign_wrapped(c) {
        return rg_new(ap_high_bits(dw, dw - sw + 1), ap_inc(ap_low_bits(dw, sw - 1)));
    }
    return rg_new(ap_sext(c.lo, dw), ap_sext(c.hi, dw));
}
// truncate(DstTySize, NoWrapKind)
fn rg_truncate_nw(c: CRange, dw: i64, nwk: i64) -> CRange {
    let sw = rg_w(c);
    if dw == sw { return c; }
    if rg_is_empty(c) { return rg_empty(dw); }
    if rg_is_full(c) { return rg_full(dw); }
    var lowerdiv = c.lo;
    var upperdiv = c.hi;
    var un = rg_empty(dw);
    if rg_is_upper_wrapped(c) {
        if ap_active_bits(c.hi) > dw { return rg_full(dw); }
        if (nwk & NW_NUW) != 0 {
            un = rg_new(ap_zero(dw), ap_trunc(c.hi, dw));
            upperdiv = ap_one_bit(sw, dw);
        } else {
            if ap_countr_one(c.hi) == dw { return rg_full(dw); }
            un = rg_new(ap_ones(dw), ap_trunc(c.hi, dw));
            upperdiv = ap_ones(sw);
            if ap_eq(lowerdiv, upperdiv) { return un; }
        }
    }
    if ap_active_bits(lowerdiv) > dw {
        if (nwk & NW_NUW) != 0 { return un; }
        let adj = ap_and(lowerdiv, ap_bits_from(sw, dw));
        lowerdiv = ap_sub(lowerdiv, adj);
        upperdiv = ap_sub(upperdiv, adj);
    }
    let udw = ap_active_bits(upperdiv);
    if udw <= dw { return rg_union(rg_new(ap_trunc(lowerdiv, dw), ap_trunc(upperdiv, dw)), un); }
    if !ap_is_zero(lowerdiv) && (nwk & NW_NUW) != 0 {
        return rg_union(rg_new(ap_trunc(lowerdiv, dw), ap_zero(dw)), un);
    }
    if udw == dw + 1 {
        upperdiv = ap_clear_bit(upperdiv, dw);
        if ap_ult(upperdiv, lowerdiv) { return rg_union(rg_new(ap_trunc(lowerdiv, dw), ap_trunc(upperdiv, dw)), un); }
    }
    return rg_full(dw);
}
fn rg_truncate(c: CRange, dw: i64) -> CRange { rg_truncate_nw(c, dw, 0) }
fn rg_zext_or_trunc(c: CRange, dw: i64) -> CRange { if rg_w(c) > dw { rg_truncate(c, dw) } else if rg_w(c) < dw { rg_zext(c, dw) } else { c } }
fn rg_sext_or_trunc(c: CRange, dw: i64) -> CRange { if rg_w(c) > dw { rg_truncate(c, dw) } else if rg_w(c) < dw { rg_sext(c, dw) } else { c } }

// castOp(CastOp, ResultBitWidth)
fn rg_cast(o: i64, c: CRange, rw: i64) -> CRange {
    if o == OP_TRUNC { return rg_truncate(c, rw); }
    if o == OP_SEXT { return rg_sext(c, rw); }
    if o == OP_ZEXT { return rg_zext(c, rw); }
    if o == OP_BITCAST { return c; }
    if o == OP_FPTOUI || o == OP_FPTOSI { return if rg_w(c) == rw { c } else { rg_full(rw) }; }
    if o == OP_UITOFP {
        let bw = rg_w(c);
        var mn = ap_zero(bw);
        var mx = ap_ones(bw);
        if rw > bw { mn = ap_zext(mn, rw); mx = ap_zext(mx, rw); }
        return rg_nonempty(mn, ap_inc(mx));
    }
    if o == OP_SITOFP {
        let bw = rg_w(c);
        var mn = ap_smin_val(bw);
        var mx = ap_smax_val(bw);
        if rw > bw { mn = ap_sext(mn, rw); mx = ap_sext(mx, rw); }
        return rg_nonempty(mn, ap_inc(mx));
    }
    if o == OP_FPTRUNC || o == OP_FPEXT || o == OP_INTTOPTR || o == OP_PTRTOADDR || o == OP_PTRTOINT || o == OP_ADDRSPACECAST {
        return rg_full(rw);
    }
    fatal("ConstantRange: unsupported cast type");
    return c;
}

// ---------------------------------------------------------------------------------------------
// Binary operations

fn rg_binop(o: i64, a: CRange, b: CRange) -> CRange {
    if o == OP_ADD || o == OP_FADD { return rg_add(a, b); }
    if o == OP_SUB || o == OP_FSUB { return rg_sub(a, b); }
    if o == OP_MUL || o == OP_FMUL { return rg_multiply(a, b, 0); }
    if o == OP_UDIV { return rg_udiv(a, b); }
    if o == OP_SDIV { return rg_sdiv(a, b); }
    if o == OP_UREM { return rg_urem(a, b); }
    if o == OP_SREM { return rg_srem(a, b); }
    if o == OP_SHL { return rg_shl(a, b); }
    if o == OP_LSHR { return rg_lshr(a, b); }
    if o == OP_ASHR { return rg_ashr(a, b); }
    if o == OP_AND { return rg_and(a, b); }
    if o == OP_OR { return rg_or(a, b); }
    if o == OP_XOR { return rg_xor(a, b); }
    return rg_full(rg_w(a));
}
fn rg_overflowing_binop(o: i64, a: CRange, b: CRange, nwk: i64) -> CRange {
    if o == OP_ADD { return rg_add_nw(a, b, nwk, RG_SMALLEST); }
    if o == OP_SUB { return rg_sub_nw(a, b, nwk, RG_SMALLEST); }
    if o == OP_MUL { return rg_multiply(a, b, nwk); }
    if o == OP_SHL { return rg_shl_nw(a, b, nwk, RG_SMALLEST); }
    return rg_binop(o, a, b);
}

fn rg_add(a: CRange, b: CRange) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    if rg_is_full(a) || rg_is_full(b) { return rg_full(w); }
    let nl = ap_add(a.lo, b.lo);
    let nu = ap_dec(ap_add(a.hi, b.hi));
    if ap_eq(nl, nu) { return rg_full(w); }
    let x = rg_new(nl, nu);
    if rg_size_strictly_smaller(x, a) || rg_size_strictly_smaller(x, b) { return rg_full(w); }
    return x;
}
fn rg_add_nw(a: CRange, b: CRange, nwk: i64, t: i64) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    if rg_is_full(a) && rg_is_full(b) { return rg_full(w); }
    var r = rg_add(a, b);
    if (nwk & NW_NSW) != 0 { r = rg_intersect_t(r, rg_sadd_sat(a, b), t); }
    if (nwk & NW_NUW) != 0 { r = rg_intersect_t(r, rg_uadd_sat(a, b), t); }
    return r;
}
fn rg_sub(a: CRange, b: CRange) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    if rg_is_full(a) || rg_is_full(b) { return rg_full(w); }
    let nl = ap_inc(ap_sub(a.lo, b.hi));
    let nu = ap_sub(a.hi, b.lo);
    if ap_eq(nl, nu) { return rg_full(w); }
    let x = rg_new(nl, nu);
    if rg_size_strictly_smaller(x, a) || rg_size_strictly_smaller(x, b) { return rg_full(w); }
    return x;
}
fn rg_sub_nw(a: CRange, b: CRange, nwk: i64, t: i64) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    if rg_is_full(a) && rg_is_full(b) { return rg_full(w); }
    var r = rg_sub(a, b);
    if (nwk & NW_NSW) != 0 { r = rg_intersect_t(r, rg_ssub_sat(a, b), t); }
    if (nwk & NW_NUW) != 0 {
        if ap_ult(rg_umax(a), rg_umin(b)) { return rg_empty(w); }
        r = rg_intersect_t(r, rg_usub_sat(a, b), t);
    }
    return r;
}

fn rg_multiply(a: CRange, b: CRange, nwk: i64) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    if rg_is_single(a) {
        if ap_is_one(a.lo) { return b; }
        if ap_is_all_ones(a.lo) { return rg_sub(rg_single(ap_zero(w)), b); }
    }
    if rg_is_single(b) {
        if ap_is_one(b.lo) { return a; }
        if ap_is_all_ones(b.lo) { return rg_sub(rg_single(ap_zero(w)), a); }
    }
    var ur = rg_empty(w);
    if (nwk & NW_NUW) != 0 {
        let minmul, minov = ap_umul_ov(rg_umin(a), rg_umin(b));
        if minov { return rg_empty(w); }
        let maxmul = ap_umul_sat(rg_umax(a), rg_umax(b));
        ur = rg_nonempty(minmul, ap_inc(maxmul));
    } else {
        let tmin = ap_zext(rg_umin(a), 2 * w);
        let tmax = ap_zext(rg_umax(a), 2 * w);
        let omin = ap_zext(rg_umin(b), 2 * w);
        let omax = ap_zext(rg_umax(b), 2 * w);
        let rz = rg_new(ap_mul(tmin, omin), ap_inc(ap_mul(tmax, omax)));
        ur = rg_truncate(rz, w);
    }
    if (nwk & NW_NSW) == 0 && !rg_is_upper_wrapped(ur) && (ap_is_nonneg(ur.hi) || ap_is_min_signed(ur.hi)) { return ur; }
    let tmin = ap_sext(rg_smin(a), 2 * w);
    let tmax = ap_sext(rg_smax(a), 2 * w);
    let omin = ap_sext(rg_smin(b), 2 * w);
    let omax = ap_sext(rg_smax(b), 2 * w);
    let p1 = ap_mul(tmin, omin);
    let p2 = ap_mul(tmin, omax);
    let p3 = ap_mul(tmax, omin);
    let p4 = ap_mul(tmax, omax);
    let mn = ap_smin(ap_smin(p1, p2), ap_smin(p3, p4));
    let mx = ap_smax(ap_smax(p1, p2), ap_smax(p3, p4));
    var rs = rg_new(mn, ap_inc(mx));
    if (nwk & NW_NSW) != 0 {
        rs = rg_intersect(rs, rg_new(ap_sext(ap_smin_val(w), 2 * w), ap_inc(ap_sext(ap_smax_val(w), 2 * w))));
    }
    let sr = rg_truncate(rs, w);
    var res = if rg_size_strictly_smaller(ur, sr) { ur } else { sr };
    if nwk == (NW_NSW | NW_NUW) && !rg_is_all_nonneg(res) {
        if ap_sgt_i64(rg_smin(a), 1) || ap_sgt_i64(rg_smin(b), 1) {
            res = rg_intersect(res, rg_nonempty(ap_zero(w), ap_smin_val(w)));
        }
    }
    return res;
}

fn rg_smax_op(a: CRange, b: CRange) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    let res = rg_nonempty(ap_smax(rg_smin(a), rg_smin(b)), ap_inc(ap_smax(rg_smax(a), rg_smax(b))));
    if rg_is_sign_wrapped(a) || rg_is_sign_wrapped(b) { return rg_intersect_t(res, rg_union_t(a, b, RG_SIGNED), RG_SIGNED); }
    return res;
}
fn rg_umax_op(a: CRange, b: CRange) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    let res = rg_nonempty(ap_umax(rg_umin(a), rg_umin(b)), ap_inc(ap_umax(rg_umax(a), rg_umax(b))));
    if rg_is_wrapped(a) || rg_is_wrapped(b) { return rg_intersect_t(res, rg_union_t(a, b, RG_UNSIGNED), RG_UNSIGNED); }
    return res;
}
fn rg_smin_op(a: CRange, b: CRange) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    let res = rg_nonempty(ap_smin(rg_smin(a), rg_smin(b)), ap_inc(ap_smin(rg_smax(a), rg_smax(b))));
    if rg_is_sign_wrapped(a) || rg_is_sign_wrapped(b) { return rg_intersect_t(res, rg_union_t(a, b, RG_SIGNED), RG_SIGNED); }
    return res;
}
fn rg_umin_op(a: CRange, b: CRange) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    let res = rg_nonempty(ap_umin(rg_umin(a), rg_umin(b)), ap_inc(ap_umin(rg_umax(a), rg_umax(b))));
    if rg_is_wrapped(a) || rg_is_wrapped(b) { return rg_intersect_t(res, rg_union_t(a, b, RG_UNSIGNED), RG_UNSIGNED); }
    return res;
}

fn rg_udiv(a: CRange, b: CRange) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) || ap_is_zero(rg_umax(b)) { return rg_empty(w); }
    let lower = ap_udiv(rg_umin(a), rg_umax(b));
    var rmin = rg_umin(b);
    if ap_is_zero(rmin) {
        if ap_is_one(b.hi) { rmin = b.lo; } else { rmin = ap_u64(1, w); }
    }
    let upper = ap_inc(ap_udiv(rg_umax(a), rmin));
    return rg_nonempty(lower, upper);
}

// splitPosNeg
fn rg_split_pos_neg(c: CRange) -> CRange, CRange {
    let w = rg_w(c);
    let pf = if w == 1 { rg_empty(w) } else { rg_new(ap_u64(1, w), ap_smin_val(w)) };
    let nf = rg_new(ap_smin_val(w), ap_zero(w));
    return rg_intersect(c, pf), rg_intersect(c, nf);
}

fn rg_sdiv(a: CRange, b: CRange) -> CRange {
    let w = rg_w(a);
    let zero = ap_zero(w);
    let smin = ap_smin_val(w);
    let posl, negl = rg_split_pos_neg(a);
    let posr, negr = rg_split_pos_neg(b);
    var posres = rg_empty(w);
    if !rg_is_empty(posl) && !rg_is_empty(posr) {
        posres = rg_new(ap_sdiv(posl.lo, ap_dec(posr.hi)), ap_inc(ap_sdiv(ap_dec(posl.hi), posr.lo)));
    }
    if !rg_is_empty(negl) && !rg_is_empty(negr) {
        let lo = ap_sdiv(ap_dec(negl.hi), negr.lo);
        if ap_is_min_signed(negl.lo) && ap_is_zero(negr.hi) {
            if !ap_is_all_ones(negr.lo) {
                var adj_neg_r_upper = zero;
                if ap_is_all_ones(b.lo) { adj_neg_r_upper = b.hi; } else { adj_neg_r_upper = ap_dec(negr.hi); }
                posres = rg_union(posres, rg_new(lo, ap_inc(ap_sdiv(negl.lo, ap_dec(adj_neg_r_upper)))));
            }
            if !ap_eq(negl.hi, ap_inc(smin)) {
                var adj_neg_l_lower = zero;
                if ap_eq(a.hi, ap_inc(smin)) { adj_neg_l_lower = a.lo; } else { adj_neg_l_lower = ap_inc(negl.lo); }
                posres = rg_union(posres, rg_new(lo, ap_inc(ap_sdiv(adj_neg_l_lower, ap_dec(negr.hi)))));
            }
        } else {
            posres = rg_union(posres, rg_new(lo, ap_inc(ap_sdiv(negl.lo, ap_dec(negr.hi)))));
        }
    }
    var negres = rg_empty(w);
    if !rg_is_empty(posl) && !rg_is_empty(negr) {
        negres = rg_new(ap_sdiv(ap_dec(posl.hi), ap_dec(negr.hi)), ap_inc(ap_sdiv(posl.lo, negr.lo)));
    }
    if !rg_is_empty(negl) && !rg_is_empty(posr) {
        negres = rg_union(negres, rg_new(ap_sdiv(negl.lo, posr.lo), ap_inc(ap_sdiv(ap_dec(negl.hi), ap_dec(posr.hi)))));
    }
    var res = rg_union_t(negres, posres, RG_SIGNED);
    if rg_contains_ap(a, zero) && (!rg_is_empty(posr) || !rg_is_empty(negr)) { res = rg_union(res, rg_single(zero)); }
    return res;
}

fn rg_urem(a: CRange, b: CRange) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) || ap_is_zero(rg_umax(b)) { return rg_empty(w); }
    if rg_is_single(b) {
        if ap_is_zero(b.lo) { return rg_empty(w); }
        if rg_is_single(a) { return rg_single(ap_urem(a.lo, b.lo)); }
    }
    if ap_ult(rg_umax(a), rg_umin(b)) { return a; }
    let upper = ap_inc(ap_umin(rg_umax(a), ap_dec(rg_umax(b))));
    return rg_nonempty(ap_zero(w), upper);
}
fn rg_srem(a: CRange, b: CRange) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    if rg_is_single(b) {
        if ap_is_zero(b.lo) { return rg_empty(w); }
        if rg_is_single(a) { return rg_single(ap_srem(a.lo, b.lo)); }
    }
    let absr = rg_abs(b, false);
    var minabs = rg_umin(absr);
    let maxabs = rg_umax(absr);
    if ap_is_zero(maxabs) { return rg_empty(w); }
    if ap_is_zero(minabs) { minabs = ap_inc(minabs); }
    let minl = rg_smin(a);
    let maxl = rg_smax(a);
    if ap_is_nonneg(minl) {
        if ap_ult(maxl, minabs) { return a; }
        let upper = ap_inc(ap_umin(maxl, ap_dec(maxabs)));
        return rg_new(ap_zero(w), upper);
    }
    if ap_is_neg(maxl) {
        if ap_ugt(minl, ap_neg(minabs)) { return a; }
        let lower = ap_umax(minl, ap_inc(ap_neg(maxabs)));
        return rg_new(lower, ap_u64(1, w));
    }
    let lower = ap_umax(minl, ap_inc(ap_neg(maxabs)));
    let upper = ap_inc(ap_umin(maxl, ap_dec(maxabs)));
    return rg_new(lower, upper);
}

fn rg_not(c: CRange) -> CRange { rg_sub(rg_single(ap_ones(rg_w(c))), c) }

fn rg_est_and_lower(l: CRange, r: CRange) -> AP {
    let w = rg_w(l);
    if rg_is_full(l) || rg_is_full(r) || rg_is_wrapped(l) || rg_is_wrapped(r) { return ap_zero(w); }
    let llo = l.lo;
    let lhi = ap_dec(l.hi);
    let rlo = r.lo;
    let rhi = ap_dec(r.hi);
    var mask = ap_not(ap_or(ap_or(ap_xor(llo, lhi), ap_xor(rlo, rhi)), ap_xor(llo, rlo)));
    let lead = ap_countl_one(mask);
    mask = ap_clear_low_bits(mask, w - lead);
    let lead1 = ap_countl_one(ap_or(ap_and(rlo, rhi), mask));
    let b1 = ap_clear_low_bits(llo, w - lead1);
    let lead2 = ap_countl_one(ap_or(ap_and(llo, lhi), mask));
    let b2 = ap_clear_low_bits(rlo, w - lead2);
    return ap_umax(b1, b2);
}
fn rg_and(a: CRange, b: CRange) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    let kr = rg_from_kb(kb_and(rg_to_kb(a), rg_to_kb(b)), false);
    let lb = rg_est_and_lower(a, b);
    let um = rg_nonempty(lb, ap_inc(ap_umin(rg_umax(b), rg_umax(a))));
    return rg_intersect(kr, um);
}
fn rg_or(a: CRange, b: CRange) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    let kr = rg_from_kb(kb_or(rg_to_kb(a), rg_to_kb(b)), false);
    let ub = ap_neg(rg_est_and_lower(rg_not(a), rg_not(b)));
    let um = rg_nonempty(ap_umax(rg_umin(a), rg_umin(b)), ub);
    return rg_intersect(kr, um);
}
fn rg_xor(a: CRange, b: CRange) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    if rg_is_single(a) && rg_is_single(b) { return rg_single(ap_xor(a.lo, b.lo)); }
    if rg_is_single(b) && ap_is_all_ones(b.lo) { return rg_not(a); }
    if rg_is_single(a) && ap_is_all_ones(a.lo) { return rg_not(b); }
    let lk = rg_to_kb(a);
    let rk = rg_to_kb(b);
    var cr = rg_from_kb(kb_xor(lk, rk), false);
    if w == 1 { return cr; }
    if ap_is_subset_of(ap_not(lk.z), rk.o) { cr = rg_intersect_t(cr, rg_sub(b, a), RG_UNSIGNED); }
    else if ap_is_subset_of(ap_not(rk.z), lk.o) { cr = rg_intersect_t(cr, rg_sub(a, b), RG_UNSIGNED); }
    return cr;
}

fn rg_shl(a: CRange, b: CRange) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    var mn = rg_umin(a);
    var mx = rg_umax(a);
    if rg_is_single(b) {
        let rhs = b.lo;
        if ap_uge_u64(rhs, w as u64) { return rg_empty(w); }
        let eq = ap_countl_zero(ap_xor(mn, mx));
        if ap_ule_u64(rhs, eq as u64) { return rg_nonempty(ap_shl_ap(mn, rhs), ap_inc(ap_shl_ap(mx, rhs))); }
        return rg_nonempty(ap_zero(w), ap_inc(ap_bits_from(w, ap_lo64(rhs) as i64)));
    }
    let omax = rg_umax(b);
    if rg_is_all_negative(a) && ap_ule_u64(omax, ap_countl_one(mn) as u64) {
        mx = ap_shl_ap(mx, rg_umin(b));
        mn = ap_shl_ap(mn, omax);
        return rg_nonempty(mn, ap_inc(mx));
    }
    if ap_ugt_u64(omax, ap_countl_zero(mx) as u64) { return rg_full(w); }
    mn = ap_shl_ap(mn, rg_umin(b));
    mx = ap_shl_ap(mx, omax);
    return rg_nonempty(mn, ap_inc(mx));
}
fn rg_shl_nuw(l: CRange, r: CRange) -> CRange {
    let w = rg_w(l);
    let lmin = rg_umin(l);
    var rmin = ap_limited(rg_umin(r), w as u64) as i64;
    let minshl, ov = ap_ushl_ov(lmin, rmin);
    if ov { return rg_empty(w); }
    let lmax = rg_umax(l);
    var rmax = ap_limited(rg_umax(r), w as u64) as i64;
    var maxshl = minshl;
    let maxsh = ap_countl_zero(lmax);
    if rmin <= maxsh { maxshl = ap_shl(lmax, if rmax < maxsh { rmax } else { maxsh }); }
    rmin = if rmin > maxsh + 1 { rmin } else { maxsh + 1 };
    let lz = ap_countl_zero(lmin);
    rmax = if rmax < lz { rmax } else { lz };
    if rmin <= rmax { maxshl = ap_umax(maxshl, ap_high_bits(w, w - rmin)); }
    return rg_nonempty(minshl, ap_inc(maxshl));
}
fn rg_shl_nsw_nneg(lmin: AP, lmax: AP, rmin0: i64, rmax0: i64) -> CRange {
    let w = lmin.w as i64;
    var rmin = rmin0;
    var rmax = rmax0;
    let minshl, ov = ap_sshl_ov(lmin, rmin);
    if ov { return rg_empty(w); }
    var maxshl = minshl;
    let maxsh = ap_countl_zero(lmax) - 1;
    if rmin <= maxsh { maxshl = ap_shl(lmax, if rmax < maxsh { rmax } else { maxsh }); }
    rmin = if rmin > maxsh + 1 { rmin } else { maxsh + 1 };
    let lz = ap_countl_zero(lmin) - 1;
    rmax = if rmax < lz { rmax } else { lz };
    if rmin <= rmax { maxshl = ap_umax(maxshl, ap_bits_set(w, rmin, w - 1)); }
    return rg_nonempty(minshl, ap_inc(maxshl));
}
fn rg_shl_nsw_neg(lmin: AP, lmax: AP, rmin0: i64, rmax0: i64) -> CRange {
    let w = lmin.w as i64;
    var rmin = rmin0;
    var rmax = rmax0;
    let maxshl, ov = ap_sshl_ov(lmax, rmin);
    if ov { return rg_empty(w); }
    var minshl = maxshl;
    let maxsh = ap_countl_one(lmin) - 1;
    if rmin <= maxsh { minshl = ap_shl(lmin, if rmax < maxsh { rmax } else { maxsh }); }
    rmin = if rmin > maxsh + 1 { rmin } else { maxsh + 1 };
    let lo = ap_countl_one(lmax) - 1;
    rmax = if rmax < lo { rmax } else { lo };
    if rmin <= rmax { minshl = ap_smin_val(w); }
    return rg_nonempty(minshl, ap_inc(maxshl));
}
fn rg_shl_nsw(l: CRange, r: CRange) -> CRange {
    let w = rg_w(l);
    let rmin = ap_limited(rg_umin(r), w as u64) as i64;
    let rmax = ap_limited(rg_umax(r), w as u64) as i64;
    let lmin = rg_smin(l);
    let lmax = rg_smax(l);
    if ap_is_nonneg(lmin) { return rg_shl_nsw_nneg(lmin, lmax, rmin, rmax); }
    if ap_is_neg(lmax) { return rg_shl_nsw_neg(lmin, lmax, rmin, rmax); }
    return rg_union_t(rg_shl_nsw_nneg(ap_zero(w), lmax, rmin, rmax), rg_shl_nsw_neg(lmin, ap_ones(w), rmin, rmax), RG_SIGNED);
}
fn rg_shl_nw(a: CRange, b: CRange, nwk: i64, t: i64) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    if nwk == 0 { return rg_shl(a, b); }
    if nwk == NW_NSW { return rg_shl_nsw(a, b); }
    if nwk == NW_NUW { return rg_shl_nuw(a, b); }
    return rg_intersect_t(rg_shl_nsw(a, b), rg_shl_nuw(a, b), t);
}
fn rg_lshr(a: CRange, b: CRange) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    let mx = ap_inc(ap_lshr_ap(rg_umax(a), rg_umin(b)));
    let mn = ap_lshr_ap(rg_umin(a), rg_umax(b));
    return rg_nonempty(mn, mx);
}
fn rg_ashr(a: CRange, b: CRange) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    let posmax = ap_inc(ap_ashr_ap(rg_smax(a), rg_umin(b)));
    let posmin = ap_ashr_ap(rg_smin(a), rg_umax(b));
    let negmax = ap_inc(ap_ashr_ap(rg_smax(a), rg_umax(b)));
    let negmin = ap_ashr_ap(rg_smin(a), rg_umin(b));
    if ap_is_nonneg(rg_smin(a)) { return rg_nonempty(posmin, posmax); }
    if ap_is_neg(rg_smax(a)) { return rg_nonempty(negmin, negmax); }
    return rg_nonempty(negmin, posmax);
}

fn rg_uadd_sat(a: CRange, b: CRange) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    return rg_nonempty(ap_uadd_sat(rg_umin(a), rg_umin(b)), ap_inc(ap_uadd_sat(rg_umax(a), rg_umax(b))));
}
fn rg_sadd_sat(a: CRange, b: CRange) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    return rg_nonempty(ap_sadd_sat(rg_smin(a), rg_smin(b)), ap_inc(ap_sadd_sat(rg_smax(a), rg_smax(b))));
}
fn rg_usub_sat(a: CRange, b: CRange) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    return rg_nonempty(ap_usub_sat(rg_umin(a), rg_umax(b)), ap_inc(ap_usub_sat(rg_umax(a), rg_umin(b))));
}
fn rg_ssub_sat(a: CRange, b: CRange) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    return rg_nonempty(ap_ssub_sat(rg_smin(a), rg_smax(b)), ap_inc(ap_ssub_sat(rg_smax(a), rg_smin(b))));
}
fn rg_umul_sat(a: CRange, b: CRange) -> CRange {
    let w = rg_w(a);
    if rg_is_empty(a) || rg_is_empty(b) { return rg_empty(w); }
    return rg_nonempty(ap_umul_sat(rg_umin(a), rg_umin(b)), ap_inc(ap_umul_sat(rg_umax(a), rg_umax(b))));
}

fn rg_abs(c: CRange, int_min_is_poison: bool) -> CRange {
    let w = rg_w(c);
    if rg_is_empty(c) { return rg_empty(w); }
    if rg_is_sign_wrapped(c) {
        var lo = ap_zero(w);
        if ap_is_strictly_pos(c.hi) || !ap_is_strictly_pos(c.lo) { lo = ap_zero(w); }
        else { lo = ap_umin(c.lo, ap_inc(ap_neg(c.hi))); }
        if int_min_is_poison { return rg_new(lo, ap_smin_val(w)); }
        return rg_new(lo, ap_inc(ap_smin_val(w)));
    }
    var smin = rg_smin(c);
    let smax = rg_smax(c);
    if int_min_is_poison && ap_is_min_signed(smin) {
        if ap_is_min_signed(smax) { return rg_empty(w); }
        smin = ap_inc(smin);
    }
    if ap_is_nonneg(smin) { return rg_new(smin, ap_inc(smax)); }
    if ap_is_neg(smax) { return rg_new(ap_neg(smax), ap_inc(ap_neg(smin))); }
    return rg_nonempty(ap_zero(w), ap_inc(ap_umax(ap_neg(smin), smax)));
}
fn rg_ctlz(c: CRange, zero_is_poison: bool) -> CRange {
    let w = rg_w(c);
    if rg_is_empty(c) { return rg_empty(w); }
    let zero = ap_zero(w);
    if zero_is_poison && rg_contains_ap(c, zero) {
        if ap_is_zero(c.lo) {
            if ap_is_zero(ap_dec(c.hi)) { return rg_empty(w); }
            return rg_new(ap_u64(ap_countl_zero(ap_dec(c.hi)) as u64, w), ap_u64((ap_countl_zero(ap_inc(c.lo)) + 1) as u64, w));
        } else if ap_is_zero(ap_dec(c.hi)) {
            return rg_new(zero, ap_u64((ap_countl_zero(c.lo) + 1) as u64, w));
        } else {
            return rg_new(zero, ap_u64(w as u64, w));
        }
    }
    return rg_nonempty(ap_u64(ap_countl_zero(rg_umax(c)) as u64, w), ap_inc(ap_u64(ap_countl_zero(rg_umin(c)) as u64, w)));
}
fn rg_ctz_range(lower: AP, upper: AP) -> CRange {
    let w = lower.w as i64;
    if ap_eq(ap_inc(lower), upper) { return rg_single(ap_u64(ap_countr_zero(lower) as u64, w)); }
    if ap_is_zero(lower) { return rg_new(ap_zero(w), ap_u64((w + 1) as u64, w)); }
    let lcp = ap_countl_zero(ap_xor(lower, ap_dec(upper)));
    let a = w - lcp - 1;
    let b = ap_countr_zero(lower);
    let m = if a > b { a } else { b };
    return rg_new(ap_zero(w), ap_u64((m + 1) as u64, w));
}
fn rg_cttz(c: CRange, zero_is_poison: bool) -> CRange {
    let w = rg_w(c);
    if rg_is_empty(c) { return rg_empty(w); }
    let zero = ap_zero(w);
    if zero_is_poison && rg_contains_ap(c, zero) {
        if ap_is_zero(c.lo) {
            if ap_is_one(c.hi) { return rg_empty(w); }
            return rg_ctz_range(ap_u64(1, w), c.hi);
        } else if ap_is_one(c.hi) {
            return rg_ctz_range(c.lo, zero);
        } else {
            return rg_union(rg_ctz_range(c.lo, zero), rg_ctz_range(ap_u64(1, w), c.hi));
        }
    }
    if rg_is_full(c) { return rg_nonempty(zero, ap_inc(ap_u64(w as u64, w))); }
    if !rg_is_wrapped(c) { return rg_ctz_range(c.lo, c.hi); }
    return rg_union(rg_ctz_range(c.lo, zero), rg_ctz_range(zero, c.hi));
}
fn rg_popcount_range(lower: AP, upper: AP) -> CRange {
    let w = lower.w as i64;
    if ap_eq(ap_inc(lower), upper) { return rg_single(ap_u64(ap_popcount(lower) as u64, w)); }
    let mx = ap_dec(upper);
    let lcp = ap_countl_zero(ap_xor(lower, mx));
    let lcppop = ap_popcount(ap_hi_bits(lower, lcp));
    let minbits = lcppop + (if ap_countr_zero(lower) < w - lcp { 1 } else { 0 });
    let maxbits = lcppop + (w - lcp) - (if ap_countr_one(mx) < w - lcp { 1 } else { 0 });
    return rg_new(ap_u64(minbits as u64, w), ap_u64((maxbits + 1) as u64, w));
}
fn rg_ctpop(c: CRange) -> CRange {
    let w = rg_w(c);
    if rg_is_empty(c) { return rg_empty(w); }
    let zero = ap_zero(w);
    if rg_is_full(c) { return rg_nonempty(zero, ap_inc(ap_u64(w as u64, w))); }
    if !rg_is_wrapped(c) { return rg_popcount_range(c.lo, c.hi); }
    let cr1 = rg_new(ap_u64(ap_countl_one(c.lo) as u64, w), ap_u64((w + 1) as u64, w));
    let cr2 = rg_popcount_range(zero, c.hi);
    return rg_union(cr1, cr2);
}

fn rg_is_intrinsic_supported(id: i32) -> bool {
    return id == IID_uadd_sat || id == IID_usub_sat || id == IID_sadd_sat || id == IID_ssub_sat ||
           id == IID_umin || id == IID_umax || id == IID_smin || id == IID_smax || id == IID_abs ||
           id == IID_ctlz || id == IID_cttz || id == IID_ctpop;
}
// ConstantRange::intrinsic(ID, Ops); ops[1] of abs/ctlz/cttz must be a single i1 element
fn rg_intrinsic(id: i32, ops: const CRange[:]) -> CRange {
    if id == IID_uadd_sat { return rg_uadd_sat(ops[0], ops[1]); }
    if id == IID_usub_sat { return rg_usub_sat(ops[0], ops[1]); }
    if id == IID_sadd_sat { return rg_sadd_sat(ops[0], ops[1]); }
    if id == IID_ssub_sat { return rg_ssub_sat(ops[0], ops[1]); }
    if id == IID_umin { return rg_umin_op(ops[0], ops[1]); }
    if id == IID_umax { return rg_umax_op(ops[0], ops[1]); }
    if id == IID_smin { return rg_smin_op(ops[0], ops[1]); }
    if id == IID_smax { return rg_smax_op(ops[0], ops[1]); }
    if id == IID_abs || id == IID_ctlz || id == IID_cttz {
        if !rg_is_single(ops[1]) { fatal("ConstantRange::intrinsic: the i1 flag must be known (immarg)"); }
        let flag = !ap_is_zero(ops[1].lo);
        if id == IID_abs { return rg_abs(ops[0], flag); }
        if id == IID_ctlz { return rg_ctlz(ops[0], flag); }
        return rg_cttz(ops[0], flag);
    }
    if id == IID_ctpop { return rg_ctpop(ops[0]); }
    fatal("ConstantRange: unsupported intrinsic");
    return ops[0];
}

// ---------------------------------------------------------------------------------------------
// IR glue

fn rg_scalar_bits(t: i32) -> i64 { ty_bits(ty_scalar(t)) }

// Constant::toConstantRange
fn rg_of_const(c: i32) -> CRange {
    let t = vals[c].ty;
    let w = rg_scalar_bits(t);
    if vals[c].kind == VK_CINT { return rg_single(ap_from_cint(c)); }
    if !ty_is_vector(t) { return rg_full(w); }
    let s = splat_value(c, true);
    if s >= 0 && vals[s].kind == VK_CINT { return rg_single(ap_from_cint(s)); }
    if s >= 0 && ty_kind(vals[s].ty) == TK_BYTE { fatal("ConstantRange: byte constants are not ported"); }
    let k = vals[c].kind;
    if k == VK_CDVECTOR {
        var r = rg_empty(w);
        for i in nops(c) {
            let e = op(c, i);
            if vals[e].kind != VK_CINT { fatal("ConstantRange: non-integer ConstantDataVector element"); }
            r = rg_union(r, rg_single(ap_from_cint(e)));
        }
        return r;
    }
    if k == VK_CVECTOR {
        var r = rg_empty(w);
        for i in nops(c) {
            let e = op(c, i);
            if vals[e].kind == VK_POISON { continue; }
            if vals[e].kind != VK_CINT { return rg_full(w); }
            r = rg_union(r, rg_single(ap_from_cint(e)));
        }
        return r;
    }
    return rg_full(w);
}

// getConstantRangeFromMetadata
fn rg_from_range_md(md: i32) -> CRange {
    let n = mds[md].nops as i64 / 2;
    var cr = rg_new(ap_from_cint(mds[md_op(md, 0)].extra), ap_from_cint(mds[md_op(md, 1)].extra));
    for i in 1..n {
        cr = rg_union(cr, rg_new(ap_from_cint(mds[md_op(md, 2 * i)].extra), ap_from_cint(mds[md_op(md, 2 * i + 1)].extra)));
    }
    return cr;
}

// The range of a `range` attribute in attribute set s: (found, range)
fn rg_from_range_attr(s: i32) -> bool, CRange {
    let at = aset_find(s, AK_Range);
    if at < 0 { return false, rg_empty(1); }
    let wi = attrs[at].i1 as i64;
    let lo = words[wi + 1] as i32;
    let hi = words[wi + 2] as i32;
    return true, rg_new(ap_from_cint(lo), ap_from_cint(hi));
}

// Attribute::get(Ctx, Attribute::Range, CR): a uniqued range attribute (one `words` triple per distinct range)
var rg_attr_cache: i32[>..];
fn rg_attr(c: CRange) -> i32 {
    let w = rg_w(c);
    let it = ty_int(w);
    let lo = ap_to_cint(it, c.lo);
    let hi = ap_to_cint(it, c.hi);
    for a in rg_attr_cache {
        let wi = attrs[a].i1 as i64;
        if words[wi + 1] as i32 == lo && words[wi + 2] as i32 == hi { return a; }
    }
    // reuse an attribute the parser created with the same payload
    for x, i in attrs {
        if x.kind == (AK_Range as i32) {
            let wi = x.i1 as i64;
            if words[wi] == (w as u64) && words[wi + 1] as i32 == lo && words[wi + 2] as i32 == hi {
                rg_attr_cache.push(i as i32);
                return i as i32;
            }
        }
    }
    let at = words.len;
    words.push(w as u64);
    words.push(lo as u64);
    words.push(hi as u64);
    let a = attr_int(AK_Range, at as u64);
    rg_attr_cache.push(a);
    return a;
}
