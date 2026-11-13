// KnownBits (llvm/lib/Support/KnownBits.cpp) and computeKnownBits (llvm/lib/Analysis/ValueTracking.cpp),
// for integers of any width (apint.goose) and vectors of any length (demanded-elements masks are APs).
//
// Coverage policy: every case of LLVM's computeKnownBits is either ported, or detected and reported with
// fatal() ("not ported"), so a less precise answer can never silently produce different IR. Cases LLVM
// itself answers with "unknown" (unlisted opcodes/intrinsics) are unknown here too. Not ported: bitcasts
// between vector shapes, vscale, target intrinsics. Assumptions: assume.goose.
import std;
import domcond;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import intrinsics;
import implied;
import datalayout;
import pm;
import vt;
import poison;
import constrange;
import constfold;
import cfold;
import instsimplify;
import assume;
import fpclass;
import apfloat;
import apint;

let MAX_ANALYSIS_DEPTH = 6;   // MaxAnalysisRecursionDepth

// KnownBits: Zero and One masks of the same width (an AP each: no memory for widths <= 64)
struct KB { z: AP, o: AP }

fn kb_bw(k: KB) -> i64 { k.z.w as i64 }
fn sbit(w: i64) -> u64 { (1 as u64) << (w - 1) }
fn wmask(w: i64) -> u64 { if w >= 64 { 0xFFFFFFFFFFFFFFFF } else { ((1 as u64) << w) - 1 } }
fn sext_w(x: u64, w: i64) -> i64 { if w >= 64 { x as! i64 } else { ((x << (64 - w)) as! i64) >> (64 - w) } }
// u64 helpers for quantities that are 64-bit by nature (offsets, demanded-element masks, index widths)
fn low_bits(n: i64) -> u64 { if n <= 0 { 0 } else { wmask(n) } }
fn bits_range(lo: i64, hi: i64) -> u64 { if hi <= lo { 0 } else { low_bits(hi) & ~low_bits(lo) } }
fn high_bits(w: i64, n: i64) -> u64 { if n <= 0 { 0 } else { bits_range(w - n, w) } }
fn ctz_w(x: u64, w: i64) -> i64 { let c = ctz(x); if c > w { w } else { c } }
fn clz_w(x: u64, w: i64) -> i64 { let v = x & wmask(w); if v == 0 { w } else { clz(v) - (64 - w) } }
fn cto_w(x: u64, w: i64) -> i64 { ctz_w(~x, w) }
fn clo_w(x: u64, w: i64) -> i64 { clz_w(~x & wmask(w), w) }
// masks of width w: low n bits, high n bits, bits [lo, hi) (APInt::setLowBits/setHighBits/setBits)
fn lowb(w: i64, n: i64) -> AP { ap_low_bits(w, n) }
fn highb(w: i64, n: i64) -> AP { if n <= 0 { ap_zero(w) } else { ap_high_bits(w, n) } }
fn bitsr(w: i64, lo: i64, hi: i64) -> AP { ap_bits_set(w, lo, hi) }
fn onebit(w: i64, k: i64) -> AP { ap_one_bit(w, k) }
// Zero |= m / One |= m, and the &= ~m forms
fn kb_or_z(k: KB, m: AP) -> KB { KB { z: ap_or(k.z, m), o: k.o } }
fn kb_or_o(k: KB, m: AP) -> KB { KB { z: k.z, o: ap_or(k.o, m) } }
fn kb_clr_z(k: KB, m: AP) -> KB { KB { z: ap_and(k.z, ap_not(m)), o: k.o } }
fn kb_clr_o(k: KB, m: AP) -> KB { KB { z: k.z, o: ap_and(k.o, ap_not(m)) } }

fn kb_unknown(w: i64) -> KB { let z = ap_zero(w); KB { z: z, o: z } }
fn kb_const_ap(c: AP) -> KB { KB { z: ap_not(c), o: c } }
fn kb_const(c: u64, w: i64) -> KB { kb_const_ap(ap_u64(c, w)) }
fn kb_all_zero(w: i64) -> KB { KB { z: ap_ones(w), o: ap_zero(w) } }
fn kb_all_conflict(w: i64) -> KB { let m = ap_ones(w); KB { z: m, o: m } }
fn kb_is_unknown(k: KB) -> bool { ap_is_zero(k.z) && ap_is_zero(k.o) }
fn kb_has_conflict(k: KB) -> bool { ap_intersects(k.z, k.o) }
fn kb_is_constant(k: KB) -> bool { ap_popcount(k.z) + ap_popcount(k.o) == kb_bw(k) && !kb_has_conflict(k) }
fn kb_const_val(k: KB) -> AP { k.o }
fn kb_and(a: KB, b: KB) -> KB { KB { z: ap_or(a.z, b.z), o: ap_and(a.o, b.o) } }
fn kb_or(a: KB, b: KB) -> KB { KB { z: ap_and(a.z, b.z), o: ap_or(a.o, b.o) } }
fn kb_xor(a: KB, b: KB) -> KB {
    KB { z: ap_or(ap_and(a.z, b.z), ap_and(a.o, b.o)), o: ap_or(ap_and(a.z, b.o), ap_and(a.o, b.z)) }
}
fn kb_intersect(a: KB, b: KB) -> KB { KB { z: ap_and(a.z, b.z), o: ap_and(a.o, b.o) } }
fn kb_union(a: KB, b: KB) -> KB { KB { z: ap_or(a.z, b.z), o: ap_or(a.o, b.o) } }
fn kb_eq_kb(a: KB, b: KB) -> bool { ap_eq(a.z, b.z) && ap_eq(a.o, b.o) }
fn kb_max(k: KB) -> AP { ap_not(k.z) }
fn kb_min(k: KB) -> AP { k.o }
fn kb_is_nonneg(k: KB) -> bool { ap_is_neg(k.z) }
fn kb_is_neg(k: KB) -> bool { ap_is_neg(k.o) }
fn kb_is_nonzero(k: KB) -> bool { !ap_is_zero(k.o) }
fn kb_is_zero_known(k: KB) -> bool { ap_is_all_ones(k.z) }
fn kb_make_nonneg(k: KB) -> KB { KB { z: ap_set_bit(k.z, kb_bw(k) - 1), o: k.o } }
fn kb_make_neg(k: KB) -> KB { KB { z: k.z, o: ap_set_bit(k.o, kb_bw(k) - 1) } }
fn kb_flip(k: KB) -> KB { KB { z: k.o, o: k.z } }

fn kb_min_tz(k: KB) -> i64 { ap_countr_one(k.z) }
fn kb_max_tz(k: KB) -> i64 { ap_countr_zero(k.o) }
fn kb_min_lz(k: KB) -> i64 { ap_countl_one(k.z) }
fn kb_max_lz(k: KB) -> i64 { ap_countl_zero(k.o) }
fn kb_min_lo(k: KB) -> i64 { ap_countl_one(k.o) }
fn kb_max_lo(k: KB) -> i64 { ap_countl_zero(k.z) }
fn kb_min_pop(k: KB) -> i64 { ap_popcount(k.o) }
fn kb_max_pop(k: KB) -> i64 { kb_bw(k) - ap_popcount(k.z) }
// countMinSignBits
fn kb_min_sign_bits_k(k: KB) -> i64 {
    if kb_is_nonneg(k) { return kb_min_lz(k); }
    if kb_is_neg(k) { return kb_min_lo(k); }
    return 1;
}
// countMaxActiveBits / countMaxSignificantBits
fn kb_max_active_bits(k: KB) -> i64 { kb_bw(k) - kb_min_lz(k) }
fn kb_max_sig_bits(k: KB) -> i64 { kb_bw(k) - max(kb_min_lz(k), kb_min_lo(k)) + 1 }

// getSignedMinValue / getSignedMaxValue
fn kb_smin(k: KB) -> AP {
    let w = kb_bw(k);
    if ap_is_neg(k.z) { return k.o; }
    return ap_set_bit(k.o, w - 1);
}
fn kb_smax(k: KB) -> AP {
    let w = kb_bw(k);
    let mx = kb_max(k);
    if ap_is_neg(k.o) { return mx; }
    return ap_clear_bit(mx, w - 1);
}

fn kb_trunc(k: KB, w: i64) -> KB { KB { z: ap_trunc(k.z, w), o: ap_trunc(k.o, w) } }
fn kb_zext(k: KB, w: i64) -> KB {
    let ow = kb_bw(k);
    return KB { z: ap_or(ap_zext(k.z, w), bitsr(w, ow, w)), o: ap_zext(k.o, w) };
}
fn kb_anyext(k: KB, w: i64) -> KB { KB { z: ap_zext(k.z, w), o: ap_zext(k.o, w) } }
fn kb_zext_or_trunc(k: KB, w: i64) -> KB { if w > kb_bw(k) { kb_zext(k, w) } else { kb_trunc(k, w) } }
fn kb_anyext_or_trunc(k: KB, w: i64) -> KB { if w > kb_bw(k) { kb_anyext(k, w) } else { kb_trunc(k, w) } }
fn kb_sext(k: KB, w: i64) -> KB { KB { z: ap_sext(k.z, w), o: ap_sext(k.o, w) } }
fn kb_sext_or_trunc(k: KB, w: i64) -> KB { if w > kb_bw(k) { kb_sext(k, w) } else { kb_trunc(k, w) } }
fn kb_byte_swap(k: KB) -> KB { KB { z: ap_byte_swap(k.z), o: ap_byte_swap(k.o) } }
fn kb_reverse_bits(k: KB) -> KB { KB { z: ap_reverse_bits(k.z), o: ap_reverse_bits(k.o) } }
// extractBits(n, lo)
fn kb_extract_bits(k: KB, n: i64, lo: i64) -> KB { KB { z: ap_extract_bits(k.z, n, lo), o: ap_extract_bits(k.o, n, lo) } }
// insertBits(sub, lo)
fn kb_insert_bits(k: KB, sub: KB, lo: i64) -> KB { KB { z: ap_insert_bits(k.z, sub.z, lo), o: ap_insert_bits(k.o, sub.o, lo) } }

// computeForAddCarry
fn kb_add_carry(l: KB, r: KB, carry_zero: bool, carry_one: bool) -> KB {
    let w = kb_bw(l);
    var psz = ap_add(kb_max(l), kb_max(r));
    if !carry_zero { psz = ap_inc(psz); }
    var pso = ap_add(kb_min(l), kb_min(r));
    if carry_one { pso = ap_inc(pso); }
    let ckz = ap_not(ap_xor(ap_xor(psz, l.z), r.z));
    let cko = ap_xor(ap_xor(pso, l.o), r.o);
    let known = ap_and(ap_and(ap_or(l.z, l.o), ap_or(r.z, r.o)), ap_or(ckz, cko));
    return KB { z: ap_and(ap_not(psz), known), o: ap_and(pso, known) };
}

// KnownBits::computeForAddSub
fn kb_add_sub(add: bool, nsw: bool, nuw: bool, l: KB, r: KB) -> KB {
    let w = kb_bw(l);
    var out = kb_unknown(w);
    if kb_is_unknown(l) && kb_is_unknown(r) { return out; }
    if !kb_is_unknown(l) && !kb_is_unknown(r) {
        if add { out = kb_add_carry(l, r, true, false); }
        else { out = kb_add_carry(l, kb_flip(r), false, true); }
    }
    if nuw {
        if add {
            let minv = ap_uadd_sat(kb_min(l), kb_min(r));
            if nsw {
                let nb = ap_countl_one(ap_trunc(minv, w - 1));
                out = kb_or_o(out, bitsr(w, w - 1 - nb, w - 1));
            }
            out = kb_or_o(out, highb(w, ap_countl_one(minv)));
        } else {
            let maxv = ap_usub_sat(kb_max(l), kb_min(r));
            if nsw {
                let nb = ap_countl_zero(ap_trunc(maxv, w - 1));
                out = kb_or_z(out, bitsr(w, w - 1 - nb, w - 1));
            }
            out = kb_or_z(out, highb(w, ap_countl_zero(maxv)));
        }
    }
    if nsw {
        var minv = ap_zero(w);
        var maxv = ap_zero(w);
        if add {
            minv = ap_sadd_sat(kb_smin(l), kb_smin(r));
            maxv = ap_sadd_sat(kb_smax(l), kb_smax(r));
        } else {
            minv = ap_ssub_sat(kb_smin(l), kb_smax(r));
            maxv = ap_ssub_sat(kb_smax(l), kb_smin(r));
        }
        if !ap_is_neg(minv) {
            let nb = ap_countl_one(ap_trunc(minv, w - 1));
            out = kb_or_o(out, bitsr(w, w - 1 - nb, w - 1));
            out = kb_or_z(out, onebit(w, w - 1));
        }
        if ap_is_neg(maxv) {
            let nb = ap_countl_zero(ap_trunc(maxv, w - 1));
            out = kb_or_z(out, bitsr(w, w - 1 - nb, w - 1));
            out = kb_or_o(out, onebit(w, w - 1));
        }
    }
    if kb_has_conflict(out) { out = kb_all_zero(w); }
    return out;
}

// KnownBits::mul
fn kb_mul(l: KB, r: KB, self_mul: bool) -> KB {
    let w = kb_bw(l);
    let prod, ovf = ap_umul_ov(kb_max(l), kb_max(r));
    let lead_z = if ovf { 0 } else { ap_countl_zero(prod) };
    let tbl = ap_countr_one(ap_or(l.z, l.o));
    let tbr = ap_countr_one(ap_or(r.z, r.o));
    let tzl = kb_min_tz(l);
    let tzr = kb_min_tz(r);
    let tz = tzl + tzr;
    let smallest = min(tbl - tzl, tbr - tzr);
    let rbk = min(smallest + tz, w);
    let bottom = ap_mul(l.o, r.o);
    var res = kb_unknown(w);
    res.z = ap_or(highb(w, lead_z), ap_and(ap_not(bottom), lowb(w, rbk)));
    res.o = ap_and(bottom, lowb(w, rbk));
    if self_mul {
        let t1 = 2 * tzl + 1;
        if t1 < w { res.z = ap_set_bit(res.z, t1); }
        if tzl < w && ap_get_bit(l.o, tzl) {
            let t2 = t1 + 1;
            if t2 < w { res.z = ap_set_bit(res.z, t2); }
        }
    }
    return res;
}

fn is_pow2_w(w: i64) -> bool { w > 0 && (w & (w - 1)) == 0 }
fn limited(v: AP, lim: i64) -> i64 { ap_limited(v, lim as u64) as i64 }

// getMaxShiftAmount
fn max_shift_amount(maxv: AP, w: i64) -> i64 {
    if is_pow2_w(w) {
        let lg = ilog2(w);
        let nb = min(lg, maxv.w as i64);
        return ap_lo64(ap_trunc(maxv, nb)) as i64;
    }
    return limited(maxv, w - 1);
}

fn kb_shl_const(l: KB, sa: i64, nuw: bool, nsw: bool) -> KB {
    let w = kb_bw(l);
    let hb = highb(w, sa);
    let zo = if sa == 0 { false } else { ap_intersects(l.z, hb) };
    let oo = if sa == 0 { false } else { ap_intersects(l.o, hb) };
    var k = KB { z: ap_or(ap_shl(l.z, sa), lowb(w, sa)), o: ap_shl(l.o, sa) };
    if nsw {
        var szo = zo;
        if nuw && sa != 0 { szo = true; }
        if szo { k = kb_make_nonneg(k); } else if oo { k = kb_make_neg(k); }
    }
    return k;
}

// the shift amounts compatible with the shift's known bits (Amt.Zero.zextOrTrunc(32) & ShiftAmt == 0, ...)
fn shift_amt_ok(r: KB, sa: i64) -> bool {
    let zm = ap_lo64(ap_zext_or_trunc(r.z, 32));
    let om = ap_lo64(ap_zext_or_trunc(r.o, 32));
    let s = sa as u64;
    return (zm & s) == 0 && (om | s) == s;
}

// KnownBits::shl
fn kb_shl(l: KB, r: KB, nuw: bool, nsw: bool, sa_nonzero: bool) -> KB {
    let w = kb_bw(l);
    var known = kb_unknown(w);
    var min_sa = limited(kb_min(r), w);
    if min_sa == 0 && sa_nonzero { min_sa = 1; }
    if kb_is_unknown(l) {
        known = kb_or_z(known, lowb(w, min_sa));
        if nuw && nsw && min_sa != 0 { known = kb_make_nonneg(known); }
        return known;
    }
    var max_sa = max_shift_amount(kb_max(r), w);
    // countMaxLeadingZeros() - 1 is unsigned in LLVM: 0 - 1 wraps and doesn't limit the amount
    if nuw && nsw && kb_max_lz(l) > 0 { max_sa = min(max_sa, kb_max_lz(l) - 1); }
    if nuw { max_sa = min(max_sa, kb_max_lz(l)); }
    if nsw { max_sa = min(max_sa, max(kb_max_lz(l), kb_max_lo(l)) - 1); }
    if min_sa == 0 && max_sa == w - 1 && is_pow2_w(w) {
        known = kb_or_z(known, lowb(w, kb_min_tz(l)));
        if kb_is_constant(l) && ap_is_all_ones(l.o) { known = kb_or_o(known, onebit(w, w - 1)); }
        if nsw {
            if kb_is_nonneg(l) { known = kb_make_nonneg(known); }
            if kb_is_neg(l) { known = kb_make_neg(known); }
        }
        return known;
    }
    known = kb_all_conflict(w);
    var sa = min_sa;
    while sa <= max_sa {
        if shift_amt_ok(r, sa) {
            known = kb_intersect(known, kb_shl_const(l, sa, nuw, nsw));
            if kb_is_unknown(known) { break; }
        }
        sa++;
    }
    if kb_has_conflict(known) { known = kb_all_zero(w); }
    return known;
}

// KnownBits::lshr / ashr
fn kb_shr(l: KB, r: KB, sa_nonzero: bool, exact: bool, arith: bool) -> KB {
    let w = kb_bw(l);
    var known = kb_unknown(w);
    var min_sa = limited(kb_min(r), w);
    if min_sa == 0 && sa_nonzero { min_sa = 1; }
    if kb_is_unknown(l) {
        if arith {
            if min_sa == w { return kb_all_zero(w); }
            return known;
        }
        return kb_or_z(known, highb(w, min_sa));
    }
    var max_sa = max_shift_amount(kb_max(r), w);
    if exact {
        let first_one = kb_max_tz(l);
        if first_one < min_sa { return kb_all_zero(w); }
        max_sa = min(max_sa, first_one);
    }
    known = kb_all_conflict(w);
    var sa = min_sa;
    while sa <= max_sa {
        if shift_amt_ok(r, sa) {
            var k = l;
            if arith { k = KB { z: ap_ashr(l.z, sa), o: ap_ashr(l.o, sa) }; }
            else { k = KB { z: ap_or(ap_lshr(l.z, sa), highb(w, sa)), o: ap_lshr(l.o, sa) }; }
            known = kb_intersect(known, k);
            if kb_is_unknown(known) { break; }
        }
        sa++;
    }
    if kb_has_conflict(known) { known = kb_all_zero(w); }
    return known;
}

// KnownBits::makeGE / umax / umin / smax / smin
fn kb_make_ge(k: KB, v: AP) -> KB {
    let w = kb_bw(k);
    let n = ap_countl_one(ap_or(k.z, v));
    let mv = ap_and(v, ap_not(lowb(w, w - n)));
    return KB { z: k.z, o: ap_or(k.o, mv) };
}
fn kb_umax(l: KB, r: KB) -> KB {
    if ap_uge(kb_min(l), kb_max(r)) { return l; }
    if ap_uge(kb_min(r), kb_max(l)) { return r; }
    return kb_intersect(kb_make_ge(l, kb_min(r)), kb_make_ge(r, kb_min(l)));
}
fn kb_umin(l: KB, r: KB) -> KB { kb_flip(kb_umax(kb_flip(l), kb_flip(r))) }
fn kb_flip_sign(k: KB) -> KB {
    let w = kb_bw(k);
    let zs = ap_get_bit(k.z, w - 1);
    let os = ap_get_bit(k.o, w - 1);
    return KB { z: ap_set_bit_to(k.z, w - 1, os), o: ap_set_bit_to(k.o, w - 1, zs) };
}
fn kb_smax_op(l: KB, r: KB) -> KB { kb_flip_sign(kb_umax(kb_flip_sign(l), kb_flip_sign(r))) }
// smin: Flip = swap Zero/One except the sign bit
fn kb_smin_flip(k: KB) -> KB {
    let w = kb_bw(k);
    let zs = ap_get_bit(k.z, w - 1);
    let os = ap_get_bit(k.o, w - 1);
    return KB { z: ap_set_bit_to(k.o, w - 1, zs), o: ap_set_bit_to(k.z, w - 1, os) };
}
fn kb_smin_op(l: KB, r: KB) -> KB { kb_smin_flip(kb_umax(kb_smin_flip(l), kb_smin_flip(r))) }

// KnownBits::fshl(LHS, RHS, Amt) / fshr: funnel shifts by a constant amount
fn kb_fsh(l: KB, r: KB, amt: AP, left: bool) -> KB {
    let w = kb_bw(l);
    var sa = ap_rot_amount(l.z, amt);
    // a zero shift returns the first operand for fshl and the second for fshr
    if sa == 0 { return if left { l } else { r }; }
    if !left { sa = (w - sa) % w; }
    // fshl(a, b, s) = (a << s) | (b >> (w - s))
    return KB { z: ap_fshl(l.z, r.z, sa), o: ap_fshl(l.o, r.o, sa) };
}

fn clmul_or_ap(a: AP, b: AP) -> AP {
    let w = a.w as i64;
    var r = ap_zero(w);
    let n = min(ap_active_bits(b), w - ap_countr_zero(a));
    for i in n { if ap_get_bit(b, i) { r = ap_or(r, ap_shl(a, i)); } }
    return r;
}
// KnownBits::clmul
fn kb_clmul(l: KB, r: KB) -> KB {
    var res = kb_const_ap(ap_clmul(kb_min(l), kb_min(r)));
    let lu = ap_not(ap_or(l.z, l.o));
    let ru = ap_not(ap_or(r.z, r.o));
    let known = ap_not(ap_or(clmul_or_ap(lu, ap_not(r.z)), clmul_or_ap(ap_not(l.z), ru)));
    res.z = ap_and(res.z, known);
    res.o = ap_and(res.o, known);
    return res;
}

// KnownBits comparisons: 1 true, 0 false, -1 unknown
fn kb_ugt(l: KB, r: KB) -> i64 {
    if ap_ule(kb_max(l), kb_min(r)) { return 0; }
    if ap_ugt(kb_min(l), kb_max(r)) { return 1; }
    return -1;
}
fn kb_uge(l: KB, r: KB) -> i64 { let x = kb_ugt(r, l); if x < 0 { -1 } else { 1 - x } }
fn kb_ult(l: KB, r: KB) -> i64 { kb_ugt(r, l) }
fn kb_ule(l: KB, r: KB) -> i64 { kb_uge(r, l) }
fn kb_sgt(l: KB, r: KB) -> i64 {
    if ap_sle(kb_smax(l), kb_smin(r)) { return 0; }
    if ap_sgt(kb_smin(l), kb_smax(r)) { return 1; }
    return -1;
}
fn kb_sge(l: KB, r: KB) -> i64 { let x = kb_sgt(r, l); if x < 0 { -1 } else { 1 - x } }
fn kb_slt(l: KB, r: KB) -> i64 { kb_sgt(r, l) }
fn kb_sle(l: KB, r: KB) -> i64 { kb_sge(r, l) }
fn kb_eq(l: KB, r: KB) -> i64 {
    if kb_is_constant(l) && kb_is_constant(r) { return if ap_eq(l.o, r.o) { 1 } else { 0 }; }
    if ap_intersects(l.o, r.z) || ap_intersects(r.o, l.z) { return 0; }
    return -1;
}
// KnownBits::abs
fn kb_abs(k: KB, int_min_is_poison: bool) -> KB {
    let w = kb_bw(k);
    if kb_is_nonneg(k) { return k; }
    var ka = kb_unknown(w);
    if kb_is_neg(k) {
        var t = k;
        if int_min_is_poison && ap_popcount(k.z) + 2 == w { t.o = ap_set_bit(t.o, kb_min_tz(k)); }
        ka = kb_add_sub(false, int_min_is_poison, false, kb_const(0, w), t);
        if int_min_is_poison && kb_min_pop(t) == 1 && kb_max_pop(t) != 1 {
            t.o = ap_clear_bit(t.o, w - 1);
            t.z = ap_set_bit(t.z, w - 1);
            ka = kb_or_o(ka, bitsr(w, w - kb_min_lz(t), w - 1));
        }
    } else {
        let maxtz = kb_max_tz(k);
        let mintz = kb_min_tz(k);
        ka = kb_or_z(ka, lowb(w, mintz));
        if maxtz == mintz && maxtz < w { ka = kb_or_o(ka, onebit(w, maxtz)); }
        if int_min_is_poison || (!ap_is_zero(k.o) && !ap_is_min_signed(k.o)) {
            ka.o = ap_clear_bit(ka.o, w - 1);
            ka.z = ap_set_bit(ka.z, w - 1);
        }
    }
    return ka;
}

// ---------------------------------------------------------------------------------------------
// More KnownBits operations (KnownBits.cpp)

fn kb_blsi(k: KB) -> KB {
    let w = kb_bw(k);
    var r = KB { z: k.z, o: ap_zero(w) };
    let mx = kb_max_tz(k);
    r = kb_or_z(r, ap_not(lowb(w, min(mx + 1, w))));
    let mn = kb_min_tz(k);
    if mx == mn && mx < w { r = kb_or_o(r, onebit(w, mx)); }
    return r;
}
fn kb_blsmsk(k: KB) -> KB {
    let w = kb_bw(k);
    var r = kb_unknown(w);
    let mx = kb_max_tz(k);
    r = kb_or_z(r, ap_not(lowb(w, min(mx + 1, w))));
    let mn = kb_min_tz(k);
    r = kb_or_o(r, lowb(w, min(mn + 1, w)));
    return r;
}
fn kb_div_low_bit(k0: KB, l: KB, r: KB, exact: bool) -> KB {
    if !exact { return k0; }
    let w = kb_bw(k0);
    var k = k0;
    if ap_get_bit(l.o, 0) { k.o = ap_set_bit(k.o, 0); }
    let mintz = kb_min_tz(l) - kb_max_tz(r);
    let maxtz = kb_max_tz(l) - kb_min_tz(r);
    if mintz >= 0 {
        k = kb_or_z(k, lowb(w, mintz));
        if mintz == maxtz && mintz < w { k = kb_or_o(k, onebit(w, mintz)); }
    } else if maxtz < 0 {
        k = kb_all_zero(w);
    }
    if kb_has_conflict(k) { k = kb_all_zero(w); }
    return k;
}
fn kb_udiv(l: KB, r: KB, exact: bool) -> KB {
    let w = kb_bw(l);
    if kb_is_zero_known(l) || kb_is_zero_known(r) { return kb_all_zero(w); }
    let mind = kb_min(r);
    let maxn = kb_max(l);
    let maxres = if ap_is_zero(mind) { maxn } else { ap_udiv(maxn, mind) };
    var k = kb_unknown(w);
    k = kb_or_z(k, highb(w, ap_countl_zero(maxres)));
    return kb_div_low_bit(k, l, r, exact);
}
fn kb_sdiv(l: KB, r: KB, exact: bool) -> KB {
    if kb_is_nonneg(l) && kb_is_nonneg(r) { return kb_udiv(l, r, exact); }
    let w = kb_bw(l);
    var k = kb_unknown(w);
    if kb_is_zero_known(l) || kb_is_zero_known(r) { return kb_all_zero(w); }
    var have = false;
    var res = ap_zero(w);
    if kb_is_neg(l) && kb_is_neg(r) {
        let denom = kb_smax(r);
        let num = kb_smin(l);
        res = if ap_is_min_signed(num) && ap_is_all_ones(denom) { ap_smax_val(w) } else { ap_sdiv(num, denom) };
        have = true;
    } else if kb_is_neg(l) && kb_is_nonneg(r) {
        if exact || ap_uge(ap_neg(kb_smax(l)), kb_smax(r)) {
            let denom = kb_smin(r);
            let num = kb_smin(l);
            res = if ap_is_zero(denom) { num } else { ap_sdiv(num, denom) };
            have = true;
        }
    } else if kb_is_nonneg(l) && kb_is_nonzero_strict(l) && kb_is_neg(r) {
        if exact || ap_uge(kb_smin(l), ap_neg(kb_smin(r))) {
            let denom = kb_smax(r);
            let num = kb_smax(l);
            res = ap_sdiv(num, denom);
            have = true;
        }
    }
    if have {
        if !ap_is_neg(res) { k = kb_or_z(k, highb(w, ap_countl_zero(res))); }
        else { k = kb_or_o(k, highb(w, ap_countl_one(res))); }
    }
    return kb_div_low_bit(k, l, r, exact);
}
// isStrictlyPositive: non-negative and non-zero
fn kb_is_nonzero_strict(k: KB) -> bool { kb_is_nonneg(k) && !ap_is_zero(k.o) }
fn kb_rem_low_bits(l: KB, r: KB) -> KB {
    let w = kb_bw(l);
    if !kb_is_zero_known(r) && ap_get_bit(r.z, 0) {
        let rz = kb_min_tz(r);
        let mask = lowb(w, rz);
        return KB { z: ap_and(l.z, mask), o: ap_and(l.o, mask) };
    }
    return kb_unknown(w);
}
fn kb_urem(l: KB, r: KB) -> KB {
    let w = kb_bw(l);
    var k = kb_rem_low_bits(l, r);
    if kb_is_constant(r) && ap_is_pow2(r.o) {
        k = kb_or_z(k, ap_not(ap_dec(r.o)));
        return k;
    }
    let leaders = max(kb_min_lz(l), kb_min_lz(r));
    return kb_or_z(k, highb(w, leaders));
}
fn kb_srem(l: KB, r: KB) -> KB {
    let w = kb_bw(l);
    var k = kb_rem_low_bits(l, r);
    if kb_is_constant(r) && ap_is_pow2(r.o) {
        let lowb2 = ap_dec(r.o);
        if kb_is_nonneg(l) || ap_is_subset_of(lowb2, l.z) { k = kb_or_z(k, ap_not(lowb2)); }
        if kb_is_neg(l) && ap_intersects(lowb2, l.o) { k = kb_or_o(k, ap_not(lowb2)); }
        return k;
    }
    if kb_is_neg(l) && kb_is_nonzero(k) { k = kb_or_o(k, highb(w, max(kb_min_lo(l), kb_min_sign_bits_k(r)))); }
    else if kb_is_nonneg(l) { k = kb_or_z(k, highb(w, max(kb_min_lz(l), kb_min_sign_bits_k(r)))); }
    return k;
}
// computeForSatAddSub
fn kb_sat_add_sub(add: bool, signed: bool, l: KB, r: KB) -> KB {
    let w = kb_bw(l);
    var ovf: i64 = -1;
    var may_neg = true;
    var may_pos = true;
    if signed {
        if add && ((kb_is_neg(l) && kb_is_nonneg(r)) || (kb_is_nonneg(l) && kb_is_neg(r))) { ovf = 0; }
        else if !add && ((kb_is_neg(l) && kb_is_neg(r)) || (kb_is_nonneg(l) && kb_is_nonneg(r))) { ovf = 0; }
        else {
            let ul = KB { z: ap_set_bit(l.z, w - 1), o: ap_clear_bit(l.o, w - 1) };
            let ur = KB { z: ap_set_bit(r.z, w - 1), o: ap_clear_bit(r.o, w - 1) };
            let res = kb_add_sub(add, false, false, ul, ur);
            if add {
                if kb_is_neg(res) { may_neg = false; if kb_is_nonneg(l) && kb_is_nonneg(r) { ovf = 1; } }
                else if kb_is_nonneg(res) { may_pos = false; if kb_is_neg(l) && kb_is_neg(r) { ovf = 1; } }
                if kb_is_neg(l) || kb_is_neg(r) { may_pos = false; }
                if kb_is_nonneg(l) || kb_is_nonneg(r) { may_neg = false; }
            } else {
                if kb_is_neg(res) { may_pos = false; if kb_is_neg(l) && kb_is_nonneg(r) { ovf = 1; } }
                else if kb_is_nonneg(res) { may_neg = false; if kb_is_nonneg(l) && kb_is_neg(r) { ovf = 1; } }
                if kb_is_neg(l) || kb_is_nonneg(r) { may_pos = false; }
                if kb_is_nonneg(l) || kb_is_neg(r) { may_neg = false; }
            }
        }
        if !may_neg && !may_pos { ovf = 0; }
    } else if add {
        let s1, of1 = ap_uadd_ov(kb_max(l), kb_max(r));
        if !of1 { ovf = 0; }
        else {
            let s2, of2 = ap_uadd_ov(kb_min(l), kb_min(r));
            if of2 { ovf = 1; }
        }
    } else {
        if ap_uge(kb_min(l), kb_max(r)) { ovf = 0; }
        else if ap_ult(kb_max(l), kb_min(r)) { ovf = 1; }
    }
    var res = kb_add_sub(add, signed, !signed, l, r);
    if ovf == 0 { return res; }
    if ovf == 1 {
        var c = ap_zero(w);
        if signed { c = if kb_is_neg(l) { ap_smin_val(w) } else { ap_smax_val(w) }; }
        else if add { c = ap_ones(w); }
        return kb_const_ap(c);
    }
    if signed {
        if may_pos { res = kb_clr_z(res, lowb(w, w - 1)); }
        if may_neg { res = kb_clr_o(res, lowb(w, w - 1)); }
    } else if add { res.z = ap_zero(w); }
    else { res.o = ap_zero(w); }
    return res;
}
fn kb_reduce_add(k: KB, n: i64) -> KB {
    let w = kb_bw(k);
    if n == 0 { return kb_unknown(w); }
    if kb_is_constant(k) { return kb_const_ap(ap_mul(ap_u64(n as u64, w), k.o)); }
    let lost = if n <= 1 { 0 } else { 64 - clz((n - 1) as u64) };
    var r = kb_unknown(w);
    if kb_is_nonneg(k) { let lz = kb_min_lz(k); r = kb_or_z(r, highb(w, if lz > lost { lz - lost } else { 0 })); }
    else if kb_is_neg(k) { let lo = kb_min_lo(k); r = kb_or_o(r, highb(w, if lo > lost { lo - lost } else { 0 })); }
    return r;
}


// ---------------------------------------------------------------------------------------------
// computeKnownBits (llvm/lib/Analysis/ValueTracking.cpp)

// SimplifyQuery::CxtI: the context instruction (DemandedBits passes the user of the operand).
var kb_cxt: i32 = -1;
// SimplifyQuery::CC (CondContext): the injected condition (-1 = none), its Invert flag and AffectedValues.
// Set by InstCombine's visitSelectInst; every phi recursion runs without it (getWithoutCondContext).
var kb_cc_cond: i32 = -1;
var kb_cc_invert: bool = false;
var kb_cc_aff: i32[>..<];
fn kb_cc_has(v: i32) -> bool { for a in kb_cc_aff { if a == v { return true; } } return false; }

fn not_ported(what: const u8[:]) { fatal(str("computeKnownBits: ", what, " is not ported yet")); }

// The bit width of a value's scalar type (pointers: the DataLayout pointer size).
fn kb_width(v: i32) -> i64 {
    let t = ty_scalar(vals[v].ty);
    var w: i64 = 0;
    if ty_is_int(t) { w = ty_bits(t); }
    else if ty_kind(t) == TK_PTR { w = dl_ptr(types[t].n as i64).bits; }
    else { fatal("internal: computeKnownBits of a non-integer value"); }
    return w;
}
fn kb_width_ty(t0: i32) -> i64 {
    let t = ty_scalar(t0);
    if ty_kind(t) == TK_PTR { return dl_ptr(types[t].n as i64).bits; }
    return ty_bits(t);
}

// APInt::getAllOnes(NumElts) for a fixed vector, APInt(1, 1) otherwise
fn all_elts(v: i32) -> AP {
    let t = vals[v].ty;
    if ty_kind(t) == TK_FVEC { return ap_ones(ty_count(t)); }
    return de_scalar();
}

recursive fn kb_compute_all(v: i32, depth: i64) -> KB { kb_compute(v, all_elts(v), depth) }


recursive fn kb_compute(v: i32, de: AP, depth: i64) -> KB {
    let w = kb_width(v);
    if ap_is_zero(de) { return kb_unknown(w); }
    let k = vals[v].kind;
    let c = m_apint(v);
    if c >= 0 { return kb_const_ap(ci_ap(c)); }
    if k == VK_CNULL || k == VK_AGGZERO { return kb_all_zero(w); }
    if k == VK_CDVECTOR {
        var r = kb_all_conflict(w);
        for i in nops(v) {
            if !de_get(de, i) { continue; }
            let x = ci_ap(op(v, i));
            r.z = ap_and(r.z, ap_not(x));
            r.o = ap_and(r.o, x);
        }
        if kb_has_conflict(r) { return kb_unknown(w); }
        return r;
    }
    if k == VK_CVECTOR {
        var r = kb_all_conflict(w);
        for i in nops(v) {
            if !de_get(de, i) { continue; }
            let e = op(v, i);
            if vals[e].kind == VK_POISON { continue; }
            if vals[e].kind != VK_CINT { return kb_unknown(w); }
            let x = ci_ap(e);
            r.z = ap_and(r.z, ap_not(x));
            r.o = ap_and(r.o, x);
        }
        if kb_has_conflict(r) { return kb_unknown(w); }
        return r;
    }
    var known = kb_unknown(w);
    if k == VK_UNDEF || k == VK_POISON { return known; }
    if is_constant_data(v) { fatal("internal: unhandled constant data in computeKnownBits"); }
    if k == VK_ARG && arg_range(v) { known = rg_to_kb(vt_cr); }
    if depth == MAX_ANALYSIS_DEPTH { return known; }
    if k == VK_ALIAS {
        let l = globs[glob_of(v)].linkage as i64;
        if !(l == LK_LINKONCE_ANY || l == LK_WEAK_ANY || l == LK_COMMON || l == LK_EXTERN_WEAK) {
            return kb_compute_all(op(v, 0), depth + 1);
        }
        return known;
    }
    if k == VK_INST || k == VK_CEXPR { known = kb_from_operator(v, de, known, depth); }
    else if is_global(v) {
        if glob_has_absolute_symbol(v) { not_ported("absolute_symbol ranges"); }
    }
    if ty_kind(vals[v].ty) == TK_PTR {
        let al = pointer_alignment(v);
        known = kb_or_z(known, lowb(w, log2_exact(al)));
    }
    known = kb_from_context(v, known, depth);
    return known;
}

// Value::getPointerAlignment
fn pointer_alignment(v: i32) -> i64 {
    let k = vals[v].kind;
    if k == VK_FUNC { return 1; }
    if k == VK_GVAR {
        let g = globs[glob_of(v)];
        if g.align == 0 {
            let ot = g.vty;
            if cf_ty_is_sized(ot) {
                if gv_is_strong_definition(v) { return gv_preferred_align(v); }
                return dl_align(ot, true);
            }
        }
        return if g.align == 0 { 1 } else { 1 << (g.align - 1) };
    }
    if k == VK_ARG {
        let at = aset_find(arg_attrs(v), AK_Alignment);
        if at >= 0 { return attrs[at].i1 as i64; }
        let sr = aset_find(arg_attrs(v), AK_StructRet);
        if sr >= 0 {
            let et = attrs[sr].ty;
            if et >= 0 && cf_ty_is_sized(et) { return dl_align(et, true); }
        }
        return 1;
    }
    if is_inst_op(v, OP_ALLOCA) {
        let a = insts[inst_of(v)].align;
        return if a == 0 { 1 } else { 1 << (a - 1) };
    }
    if is_callbase(v) {
        let at = aset_find(alist_ret(insts[inst_of(v)].attrs), AK_Alignment);
        if at >= 0 { return attrs[at].i1 as i64; }
        let f = called_function(v);
        if f >= 0 {
            let at2 = aset_find(alist_ret(globs[glob_of(f)].attrs), AK_Alignment);
            if at2 >= 0 { return attrs[at2].i1 as i64; }
        }
        return 1;
    }
    if is_inst_op(v, OP_LOAD) {
        let md = inst_get_md(v, md_kind_id("align"));
        if md >= 0 { return ap_limited(ci_ap(mds[md_op(md, 0)].extra), 0x7FFFFFFFFFFFFFFF) as i64; }
        return 1;
    }
    if k == VK_CEXPR && csts[vals[v].sub].op as i64 == OP_INTTOPTR && vals[op(v, 0)].kind == VK_CINT {
        let x = op(v, 0);
        let tz = ap_countr_zero(ci_ap(x));
        return if tz < 32 { 1 << tz } else { 1 << 32 };
    }
    return 1;
}
fn gv_is_strong_definition(v: i32) -> bool {
    let g = globs[glob_of(v)];
    let l = g.linkage as i64;
    if nops(v) == 0 || l == LK_AVAILABLE_EXTERNALLY { return false; }
    if l == LK_LINKONCE_ANY || l == LK_LINKONCE_ODR || l == LK_WEAK_ANY || l == LK_WEAK_ODR || l == LK_COMMON || l == LK_EXTERN_WEAK { return false; }
    return true;
}
// DataLayout::getPreferredAlign(GV)
fn gv_preferred_align(v: i32) -> i64 {
    let g = globs[glob_of(v)];
    let gva = if g.align == 0 { 0 } else { 1 << (g.align - 1) };
    if gva != 0 && g.section >= 0 { return gva; }
    let et = g.vty;
    var al = dl_align(et, false);
    if gva != 0 {
        if gva >= al { al = gva; } else { al = max(gva, dl_align(et, true)); }
    }
    if nops(v) > 0 && gva == 0 {
        if al < 16 && dl_size_bits(et) > 128 { al = 16; }
    }
    return al;
}

// m_APInt for known bits (constant scalar or splat)
fn match_apint(v: i32) -> bool { m_apint(v) >= 0 }
fn apint_value(v: i32) -> AP { ci_ap(m_apint(v)) }

// getKnownBitsFromAndXorOr
recursive fn kb_and_xor_or(iv: i32, de: AP, kl: KB, kr: KB, depth: i64) -> KB {
    let w = kb_bw(kl);
    let o = opcode_of(iv);
    var out = kb_unknown(w);
    let a = op(iv, 0);
    let b = op(iv, 1);
    let has_one = !ap_is_zero(kl.o) || !ap_is_zero(kr.o);
    var is_and = false;
    if o == OP_AND {
        out = kb_and(kl, kr);
        is_and = true;
        // m_c_And(m_Value(X), m_Neg(m_Deferred(X)))
        if has_one && (m_neg(b) == a || m_neg(a) == b) {
            if kb_max_tz(kl) <= kb_max_tz(kr) { out = kb_blsi(kl); } else { out = kb_blsi(kr); }
        }
    } else if o == OP_OR {
        out = kb_or(kl, kr);
    } else {
        out = kb_xor(kl, kr);
        if has_one {
            fn is_dec(y: i32, x: i32) -> bool { is_op(y, OP_ADD) && op(y, 0) == x && m_all_ones(op(y, 1)) }
            var x: i32 = -1;
            if is_dec(b, a) { x = a; } else if is_dec(a, b) { x = b; }
            if x >= 0 { out = kb_blsmsk(if a == x { kl } else { kr }); }
        }
    }
    if !ap_get_bit(out.z, 0) && !ap_get_bit(out.o, 0) {
        fn pat(x: i32, y: i32) -> i32 {
            if is_op(y, OP_ADD) { if op(y, 0) == x { return op(y, 1); } if op(y, 1) == x { return op(y, 0); } }
            if is_op(y, OP_SUB) { if op(y, 0) == x { return op(y, 1); } if op(y, 1) == x { return op(y, 0); } }
            return -1;
        }
        var other = pat(a, b);
        if other < 0 { other = pat(b, a); }
        if other >= 0 {
            let ky = kb_compute(other, de, depth + 1);
            if ap_get_bit(ky.o, 0) {
                if is_and { out.z = ap_set_bit(out.z, 0); } else { out.o = ap_set_bit(out.o, 0); }
            }
        }
    }
    return out;
}

// computeKnownBitsFromRangeMetadata
fn kb_from_range_md(md: i32, w: i64) -> KB {
    var known = kb_all_conflict(w);
    let n = mds[md].nops as i64 / 2;
    for i in n {
        let lo = ci_ap(mds[md_op(md, 2 * i)].extra);
        let hi = ci_ap(mds[md_op(md, 2 * i + 1)].extra);
        let umax = if ap_ugt(lo, hi) { ap_ones(w) } else { ap_dec(hi) };
        let umin = if ap_ugt(lo, hi) && !ap_is_zero(hi) { ap_zero(w) } else { lo };
        let cp = ap_countl_zero(ap_xor(umax, umin));
        let mask = highb(w, cp);
        known.o = ap_and(known.o, ap_and(umax, mask));
        known.z = ap_and(known.z, ap_and(ap_not(umax), mask));
    }
    return known;
}

// computeKnownBitsAddSub
recursive fn kb_add_sub_ops(add: bool, a: i32, b: i32, nsw: bool, nuw: bool, de: AP, depth: i64) -> KB {
    let kr = kb_compute(b, de, depth + 1);
    if kb_is_unknown(kr) && !nsw && !nuw { return kr; }
    let kl = kb_compute(a, de, depth + 1);
    var out = kb_add_sub(add, nsw, nuw, kl, kr);
    if !add && nsw && !kb_is_nonneg(out) {
        if implied_by_dom_condition(P_SLE, b, a, kb_cxt) == 1 || m_c_smin_with(b, a) { out = kb_make_nonneg(out); }
    }
    if add { out = kb_from_lerp(a, b, de, out, depth); }
    return out;
}
fn m_c_smin_with(v: i32, x: i32) -> bool { m_minmax(v, 1) && (mm_a == x || mm_b == x) }

// computeKnownBitsMul
recursive fn kb_mul_ops(a: i32, b: i32, nsw: bool, nuw: bool, de: AP, depth: i64) -> KB {
    let k1 = kb_compute(b, de, depth + 1);
    let k2 = kb_compute(a, de, depth + 1);
    var is_nonneg = false;
    var is_negr = false;
    if nsw {
        if a == b { is_nonneg = true; }
        else {
            let nn1 = kb_is_nonneg(k1);
            let nn0 = kb_is_nonneg(k2);
            let ng1 = kb_is_neg(k1);
            let ng0 = kb_is_neg(k2);
            is_nonneg = (ng1 && ng0) || (nn1 && nn0);
            if !is_nonneg && nuw {
                let one = kb_const(1, kb_bw(k1));
                is_nonneg = kb_sgt(k1, one) == 1 || kb_sgt(k2, one) == 1;
            }
            if !is_nonneg { is_negr = (ng1 && nn0 && kb_is_nonzero(k2)) || (ng0 && nn1 && kb_is_nonzero(k1)); }
        }
    }
    var self_mul = a == b;
    if self_mul { self_mul = is_guaranteed_not_to_be_undef(a, kb_cxt, depth + 1); }
    var known = kb_mul(k1, k2, self_mul);
    if self_mul {
        let sb = ncsb(a, de, depth + 1);
        let tb = ty_bits(ty_scalar(vals[a].ty));
        let ovb = 2 * (tb - sb + 1);
        if ovb < tb { known = kb_or_z(known, highb(tb, tb - ovb + 1)); }
    }
    if is_nonneg && !kb_is_neg(known) { known = kb_make_nonneg(known); }
    else if is_negr && !kb_is_nonneg(known) { known = kb_make_neg(known); }
    return known;
}

// computeKnownBitsFromLerpPattern
recursive fn kb_from_lerp(op0: i32, op1: i32, de: AP, known0: KB, depth: i64) -> KB {
    var known = known0;
    if ty_is_vector(vals[op0].ty) { return known; }
    let w = ty_bits(vals[op0].ty);
    var ok = false;
    var a: i32 = -1;
    var b: i32 = -1;
    var c: i32 = -1;
    var d: i32 = -1;
    var sub_is_xor = false;
    for side in 2 {
        let lhs = if side == 0 { op0 } else { op1 };
        let rhs = if side == 0 { op1 } else { op0 };
        // MatchASubBC: m_c_Mul(m_Value(A), SubBC) or SubBC
        a = -1; b = -1; c = -1; d = -1;
        var sub: i32 = -1;
        fn match_sub_bc(v: i32) -> bool { is_inst(v) && ((iop(v) == OP_SUB && op_nuw(v)) || iop(v) == OP_XOR) }
        if is_op(lhs, OP_MUL) {
            if match_sub_bc(op(lhs, 1)) { a = op(lhs, 0); sub = op(lhs, 1); }
            else if match_sub_bc(op(lhs, 0)) { a = op(lhs, 1); sub = op(lhs, 0); }
        }
        if sub < 0 && match_sub_bc(lhs) { sub = lhs; }
        if sub < 0 { continue; }
        if iop(sub) == OP_SUB { b = op(sub, 0); c = op(sub, 1); sub_is_xor = false; }
        else { c = op(sub, 0); b = op(sub, 1); sub_is_xor = true; }
        // MatchCD: m_c_Mul(m_Value(D), m_Specific(C)) or m_Specific(C)
        if is_op(rhs, OP_MUL) && (op(rhs, 0) == c || op(rhs, 1) == c) { d = if op(rhs, 1) == c { op(rhs, 0) } else { op(rhs, 1) }; ok = true; }
        else if rhs == c { ok = true; }
        if ok { break; }
    }
    if !ok { return known; }
    let ka = if a >= 0 { kb_compute(a, de, depth + 1) } else { kb_const(1, w) };
    if !kb_is_nonneg(ka) { return known; }
    let kd = if d >= 0 { kb_compute(d, de, depth + 1) } else { kb_const(1, w) };
    if !kb_is_nonneg(kd) { return known; }
    let kbb = kb_compute(b, de, depth + 1);
    if !kb_is_nonneg(kbb) { return known; }
    let kc = kb_compute(c, de, depth + 1);
    if !kb_is_nonneg(kc) { return known; }
    if sub_is_xor && !ap_is_subset_of(kb_max(kc), kb_min(kbb)) { return known; }
    let mad = ap_umax(kb_max(ka), kb_max(kd));
    let mb = kb_max(kbb);
    let p, ov = ap_umul_ov(mad, mb);
    if ov { return known; }
    known = kb_or_z(known, highb(w, ap_countl_zero(p)));
    return known;
}

// computeKnownBitsFromCmp
recursive fn kb_from_cmp(v: i32, p: i64, l: i32, r: i32, known0: KB) -> KB {
    var known = known0;
    let w = kb_bw(known);
    if ty_kind(vals[r].ty) == TK_PTR {
        if l == v && m_zero(r) {
            if p == P_EQ { known = kb_all_zero(w); }
            else if p == P_SGE || p == P_SGT { known = kb_make_nonneg(known); }
            else if p == P_SLT { known = kb_make_neg(known); }
        }
        return known;
    }
    fn m_v(x: i32, v: i32) -> bool {
        if x == v { return true; }
        return is_op(x, OP_PTRTOINT) && op(x, 0) == v && dl_size_bits(vals[x].ty) == dl_size_bits(vals[v].ty);
    }
    let cc = m_apint(r);
    if cc < 0 { return known; }
    let c = ci_ap(cc);
    if p == P_EQ {
        if m_v(l, v) { known = kb_union(known, kb_const_ap(c)); }
        else if is_op(l, OP_AND) && (m_v(op(l, 0), v) || m_v(op(l, 1), v)) {
            let y = if m_v(op(l, 0), v) { op(l, 1) } else { op(l, 0) };
            known = kb_or_o(known, c);
            let mk = m_apint(y);
            if mk >= 0 { known = kb_or_z(known, ap_and(ap_not(c), ci_ap(mk))); }
        } else if is_op(l, OP_OR) && (m_v(op(l, 0), v) || m_v(op(l, 1), v)) {
            let y = if m_v(op(l, 0), v) { op(l, 1) } else { op(l, 0) };
            known = kb_or_z(known, ap_not(c));
            let mk = m_apint(y);
            if mk >= 0 { known = kb_or_o(known, ap_and(c, ap_not(ci_ap(mk)))); }
        } else if is_op(l, OP_SHL) && m_v(op(l, 0), v) && m_constant_int(op(l, 1)) >= 0 && ap_ult_u64(ci_ap(op(l, 1)), w as u64) {
            let s = ap_lo64(ci_ap(op(l, 1))) as i64;
            let rk = kb_const_ap(c);
            // KnownBits >>= sets no new knowledge for the vacated high bits
            known = kb_union(known, KB { z: ap_lshr(rk.z, s), o: ap_lshr(rk.o, s) });
        } else if (is_op(l, OP_LSHR) || is_op(l, OP_ASHR)) && m_v(op(l, 0), v) && m_constant_int(op(l, 1)) >= 0 && ap_ult_u64(ci_ap(op(l, 1)), w as u64) {
            let s = ap_lo64(ci_ap(op(l, 1))) as i64;
            let rk = kb_const_ap(c);
            known = kb_union(known, KB { z: ap_shl(rk.z, s), o: ap_shl(rk.o, s) });
        }
        return known;
    }
    if p == P_NE {
        if ap_is_zero(c) && is_op(l, OP_AND) && m_v(op(l, 0), v) && m_power2(op(l, 1)) { known = kb_or_o(known, ci_ap(m_apint(op(l, 1)))); }
        return known;
    }
    var matched = false;
    var has_off = false;
    var off = ap_zero(w);
    if m_v(l, v) { matched = true; }
    else if (is_op(l, OP_ADD) || (is_op(l, OP_OR) && op_disjoint(l))) && m_v(op(l, 0), v) && m_apint(op(l, 1)) >= 0 {
        matched = true;
        has_off = true;
        off = ci_ap(m_apint(op(l, 1)));
    }
    if matched {
        var lr = rg_allowed_icmp(p, rg_single(c));
        if has_off { lr = rg_sub(lr, rg_single(off)); }
        known = kb_union(known, rg_to_kb(lr));
    }
    if p == P_UGT || p == P_UGE {
        if (is_op(l, OP_AND) && (m_v(op(l, 0), v) || m_v(op(l, 1), v))) || (is_op(l, OP_SUB) && op_nuw(l) && m_v(op(l, 0), v)) {
            let x = if p == P_UGT { ap_inc(c) } else { c };
            known = kb_or_o(known, highb(w, ap_countl_one(x)));
        }
    }
    if p == P_ULT || p == P_ULE {
        if (is_op(l, OP_OR) && (m_v(op(l, 0), v) || m_v(op(l, 1), v))) || (is_op(l, OP_ADD) && op_nuw(l) && (m_v(op(l, 0), v) || m_v(op(l, 1), v))) {
            let x = if p == P_ULT { ap_dec(c) } else { c };
            known = kb_or_z(known, highb(w, ap_countl_zero(x)));
        }
    }
    return known;
}

recursive fn kb_from_icmp_cond(v: i32, cmp: i32, known: KB, invert: bool) -> KB {
    var p = inst_pred(cmp);
    if invert { p = pred_inverse(p); }
    let l = op(cmp, 0);
    let r = op(cmp, 1);
    if is_op(l, OP_TRUNC) && op(l, 0) == v {
        let dw = ty_bits(ty_scalar(vals[l].ty));
        let dk = kb_from_cmp(l, p, l, r, kb_unknown(dw));
        let kw = kb_bw(known);
        if is_inst(l) && op_nuw(l) { return kb_union(known, kb_zext(dk, kw)); }
        return kb_union(known, kb_anyext(dk, kw));
    }
    return kb_from_cmp(v, p, l, r, known);
}

// computeKnownBitsFromCond
recursive fn kb_from_cond(v: i32, cond: i32, known: KB, invert: bool, depth: i64) -> KB {
    let w = kb_bw(known);
    if depth < MAX_ANALYSIS_DEPTH && (m_logical(cond, true) || m_logical(cond, false)) {
        let is_or = m_logical(cond, false);
        let is_and = m_logical(cond, true);
        if is_and { } else { let x = m_logical(cond, false); }
        let a = lg_a;
        let b = lg_b;
        let k2 = kb_from_cond(v, a, kb_unknown(w), invert, depth + 1);
        let k3 = kb_from_cond(v, b, kb_unknown(w), invert, depth + 1);
        var kk = k2;
        if (if invert { is_or } else { is_and }) { kk = kb_union(k2, k3); } else { kk = kb_intersect(k2, k3); }
        return kb_union(known, kk);
    }
    if is_inst_op(cond, OP_ICMP) { return kb_from_icmp_cond(v, cond, known, invert); }
    if is_op(cond, OP_TRUNC) && op(cond, 0) == v {
        let dk = if invert { kb_all_zero(1) } else { kb_const(1, 1) };
        if is_inst(cond) && op_nuw(cond) { return kb_union(known, kb_zext(dk, w)); }
        return kb_union(known, kb_anyext(dk, w));
    }
    if depth < MAX_ANALYSIS_DEPTH {
        let a = m_not(cond);
        if a >= 0 { return kb_from_cond(v, a, known, !invert, depth + 1); }
    }
    return known;
}

// adjustKnownBitsForSelectArm
recursive fn kb_adjust_for_select_arm(known: KB, cond: i32, arm: i32, invert: bool, depth: i64) -> KB {
    if kb_is_constant(known) { return known; }
    var cr = kb_from_cond(arm, cond, kb_unknown(kb_bw(known)), invert, depth + 1);
    if kb_is_unknown(cr) { return known; }
    cr = kb_union(cr, known);
    if kb_has_conflict(cr) { return known; }
    if !is_guaranteed_not_to_be_undef(arm, kb_cxt, depth + 1) { return known; }
    return cr;
}

// computeKnownBitsFromContext: dominating conditions (domcond.goose, InstCombine's DomConditionCache) and
// assumptions (assume.goose)
recursive fn kb_from_context(v: i32, known0: KB, depth: i64) -> KB {
    var known = known0;
    if kb_cc_cond >= 0 && kb_cc_has(v) { known = kb_from_cond(v, kb_cc_cond, known, kb_cc_invert, depth); }
    if kb_cxt < 0 { return known; }
    let k = kb_from_dom_conditions(v, known, depth);
    return kb_from_assumptions(v, k, depth);
}

// breakSelfRecursivePHI: (value, context instruction, phi)
fn break_self_recursive_phi(p: i32, k: i64) -> i32, i32, i32 {
    var val = op(p, k);
    var cxt: i32 = -1;
    var phi = p;
    if val == p { return val, cxt, phi; }
    cxt = block_terminator(phi_block(p, k));
    if is_inst_op(val, OP_SELECT) {
        if op(val, 1) == p { val = op(val, 2); }
        else if op(val, 2) == p { val = op(val, 1); }
    }
    if is_inst_op(val, OP_PHI) && nops(val) == 2 {
        for idx in 2 {
            if op(val, idx) == p {
                let inc = val;
                val = op(inc, 1 - idx);
                phi = inc;
                cxt = block_terminator(phi_block(inc, 1 - idx));
                break;
            }
        }
    }
    return val, cxt, phi;
}

recursive fn kb_from_operator(iv: i32, de: AP, known0: KB, depth: i64) -> KB {
    let w = kb_bw(known0);
    var known = known0;
    let o = opcode_of(iv);
    let is_i = vals[iv].kind == VK_INST;
    if o == OP_LOAD {
        let rm = iiq_md(iv, md_kind_id("range"));
        if rm >= 0 { known = kb_from_range_md(rm, w); }
        return known;
    }
    if o == OP_AND || o == OP_OR || o == OP_XOR {
        let kr = kb_compute(op(iv, 1), de, depth + 1);
        let kl = kb_compute(op(iv, 0), de, depth + 1);
        return kb_and_xor_or(iv, de, kl, kr, depth);
    }
    if o == OP_MUL { return kb_mul_ops(op(iv, 0), op(iv, 1), iiq_nsw(iv), iiq_nuw(iv), de, depth); }
    if o == OP_UDIV {
        let a = kb_compute(op(iv, 0), de, depth + 1);
        let b = kb_compute(op(iv, 1), de, depth + 1);
        return kb_udiv(a, b, iiq_exact(iv));
    }
    if o == OP_SDIV {
        let a = kb_compute(op(iv, 0), de, depth + 1);
        let b = kb_compute(op(iv, 1), de, depth + 1);
        return kb_sdiv(a, b, iiq_exact(iv));
    }
    if o == OP_SELECT {
        let c = op(iv, 0);
        var k1 = kb_compute(op(iv, 1), de, depth + 1);
        k1 = kb_adjust_for_select_arm(k1, c, op(iv, 1), false, depth);
        var k2 = kb_compute(op(iv, 2), de, depth + 1);
        k2 = kb_adjust_for_select_arm(k2, c, op(iv, 2), true, depth);
        return kb_intersect(k1, k2);
    }
    if o == OP_FPTRUNC || o == OP_FPEXT || o == OP_FPTOUI || o == OP_FPTOSI || o == OP_SITOFP || o == OP_UITOFP { return known; }
    if o == OP_PTRTOINT || o == OP_PTRTOADDR || o == OP_INTTOPTR || o == OP_ZEXT || o == OP_TRUNC {
        let src = op(iv, 0);
        let sw = kb_width(src);
        var k = kb_compute(src, de, depth + 1);
        if (o == OP_ZEXT || o == OP_UITOFP) && is_i && has_flag(iv, FL_NNEG) && !kb_is_neg(k) { k = kb_make_nonneg(k); }
        return kb_zext_or_trunc(k, w);
    }
    if o == OP_BITCAST {
        let src = op(iv, 0);
        let st = vals[src].ty;
        if (ty_is_int(st) || ty_kind(st) == TK_PTR) && !ty_is_vector(vals[iv].ty) { return kb_compute_all(src, depth + 1); }
        if is_fp_or_fp_vec(st) && elementwise_bitcast_v(iv) {
            let fk = known_fp_class_de(src, de, FCL_ALL, depth + 1);
            let cls = fk.known;
            if cls == 0 { return known; }
            if kfc_never(fk, FCL_NORMAL | FCL_SUBNORMAL | FCL_NAN) {
                known = kb_all_conflict(w);
                let fkind = types[ty_scalar(st)].kind as i64;
                if (cls & FCL_INF) != 0 {
                    let f = fp_fmt(fkind);
                    let infb = ap_shl(ap_low_bits(w, f.ebits), f.p - 1);
                    known = kb_intersect(known, kb_const_ap(infb));
                }
                if (cls & FCL_ZERO) != 0 { known = kb_intersect(known, kb_const(0, w)); }
                known.z = ap_clear_bit(known.z, w - 1);
                known.o = ap_clear_bit(known.o, w - 1);
            }
            if fk.sign == 1 { known = kb_make_neg(known); }
            else if fk.sign == 0 { known = kb_make_nonneg(known); }
            return known;
        }
        if ty_kind(st) != TK_FVEC || !ty_is_int(types[st].a) || !is_int_or_int_vec(vals[iv].ty) || ty_kind(vals[iv].ty) == TK_SVEC { return known; }
        let nelts = if ty_kind(vals[iv].ty) == TK_FVEC { ty_count(vals[iv].ty) } else { 1 };
        let subw = ty_bits(types[st].a);
        // Look through a cast from narrow vector elements to wider type (v4i32 -> v2i64, v3i8 -> i24)
        if w % subw == 0 {
            let scale = w / subw;
            var sub_de = ap_zero(nelts * scale);
            for i in nelts { if de_get(de, i) { sub_de = ap_set_bit(sub_de, i * scale); } }
            for i in scale {
                let ks = kb_compute(src, ap_shl(sub_de, i), depth + 1);
                let se = if dl_big_endian { scale - 1 - i } else { i };
                known = kb_insert_bits(known, ks, se * subw);
            }
        }
        // Look through a cast from wider vector elements to narrow type (v2i64 -> v4i32)
        if subw % w == 0 {
            let scale = subw / w;
            // APIntOps::ScaleBitMask(DemandedElts, NumElts / SubScale)
            var sub_de = ap_zero(nelts / scale);
            for j in nelts / scale {
                var any = false;
                for t in scale { if de_get(de, j * scale + t) { any = true; } }
                if any { sub_de = ap_set_bit(sub_de, j); }
            }
            let ks = kb_compute(src, sub_de, depth + 1);
            known = kb_all_conflict(w);
            for i in nelts {
                if de_get(de, i) {
                    let sh = if dl_big_endian { nelts - 1 - i } else { i };
                    let off = (sh % scale) * w;
                    known = kb_intersect(known, kb_extract_bits(ks, w, off));
                    if kb_is_unknown(known) { break; }
                }
            }
        }
        return known;
    }
    if o == OP_SEXT {
        let k = kb_compute(op(iv, 0), de, depth + 1);
        return kb_sext(k, w);
    }
    if o == OP_SHL || o == OP_LSHR || o == OP_ASHR {
        let a = op(iv, 0);
        let b = op(iv, 1);
        let k2 = kb_compute(a, de, depth + 1);
        let k1 = kb_compute(b, de, depth + 1);
        let sa_nonzero = kb_is_nonzero(k1) || (ap_ult_u64(kb_max(k1), kb_bw(k1) as u64) && ikz(b, de, depth + 1));
        if o == OP_SHL {
            known = kb_shl(k2, k1, iiq_nuw(iv), iiq_nsw(iv), sa_nonzero);
            if match_apint(a) { known = kb_or_z(known, lowb(w, ap_countr_zero(apint_value(a)))); }
            // shl X, sub(Y, xor(ctlz(X, true), BitWidth-1))
            if is_pow2_w(w) && is_op(b, OP_SUB) && m_apint(op(b, 0)) >= 0 {
                let xo = op(b, 1);
                if is_op(xo, OP_XOR) && m_specific_int(op(xo, 1), (w - 1) as u64) {
                    let ct = op(xo, 0);
                    if m_intrinsic(ct, IID_ctlz) && op(ct, 0) == a && m_one(op(ct, 1)) {
                        let yc = ci_ap(m_apint(op(b, 0)));
                        if ap_ult_u64(yc, (w - 1) as u64) {
                            let y = ap_lo64(yc) as i64;
                            known = kb_or_o(known, onebit(w, y));
                            known = kb_or_z(known, ap_not(lowb(w, y + 1)));
                        }
                    }
                }
            }
            return known;
        }
        known = kb_shr(k2, k1, sa_nonzero, iiq_exact(iv), o == OP_ASHR);
        if o == OP_LSHR && match_apint(a) { known = kb_or_z(known, highb(w, ap_countl_zero(apint_value(a)))); }
        return known;
    }
    if o == OP_SUB { return kb_add_sub_ops(false, op(iv, 0), op(iv, 1), iiq_nsw(iv), iiq_nuw(iv), de, depth); }
    if o == OP_ADD { return kb_add_sub_ops(true, op(iv, 0), op(iv, 1), iiq_nsw(iv), iiq_nuw(iv), de, depth); }
    if o == OP_SREM {
        let a = kb_compute(op(iv, 0), de, depth + 1);
        let b = kb_compute(op(iv, 1), de, depth + 1);
        return kb_srem(a, b);
    }
    if o == OP_UREM {
        let a = kb_compute(op(iv, 0), de, depth + 1);
        let b = kb_compute(op(iv, 1), de, depth + 1);
        return kb_urem(a, b);
    }
    if o == OP_ALLOCA {
        let al = insts[inst_of(iv)].align;
        known = kb_or_z(known, lowb(w, if al == 0 { 0 } else { (al - 1) as i64 }));
        return known;
    }
    if o == OP_GEP { return kb_gep(iv, known, depth); }
    if o == OP_PHI {
        let scc = kb_cc_cond;
        kb_cc_cond = -1;
        let r = kb_phi(iv, de, known, depth);
        kb_cc_cond = scc;
        return r;
    }
    if o == OP_CALL || o == OP_INVOKE { return kb_call(iv, de, known, depth); }
    if o == OP_SHUFFLEVECTOR {
        if is_i {
            let sv = shuffle_splat_value(iv);
            if sv >= 0 { return kb_compute_all(sv, depth + 1); }
        } else { return kb_unknown(w); }
        let ok, dl, dr = shuffle_demanded(iv, de);
        if !ok { return kb_unknown(w); }
        known = kb_all_conflict(w);
        if !ap_is_zero(dl) {
            known = kb_compute(op(iv, 0), dl, depth + 1);
            if kb_is_unknown(known) { return known; }
        }
        if !ap_is_zero(dr) {
            let k2 = kb_compute(op(iv, 1), dr, depth + 1);
            known = kb_intersect(known, k2);
        }
        return known;
    }
    if o == OP_INSERTELEMENT {
        if ty_kind(vals[iv].ty) == TK_SVEC { return kb_unknown(w); }
        let vec = op(iv, 0);
        let elt = op(iv, 1);
        let idx = op(iv, 2);
        let n = ty_count(vals[iv].ty);
        var dv = de;
        var needs = true;
        let ci = m_constant_int(idx);
        if ci >= 0 && ap_ult_u64(ci_ap(ci), n as u64) {
            let x = ap_lo64(ci_ap(ci)) as i64;
            dv = ap_clear_bit(dv, x);
            needs = de_get(de, x);
        }
        known = kb_all_conflict(w);
        if needs {
            known = kb_compute_all(elt, depth + 1);
            if kb_is_unknown(known) { return known; }
        }
        if !ap_is_zero(dv) {
            let k2 = kb_compute(vec, dv, depth + 1);
            known = kb_intersect(known, k2);
        }
        return known;
    }
    if o == OP_EXTRACTELEMENT {
        let vec = op(iv, 0);
        let idx = op(iv, 1);
        if ty_kind(vals[vec].ty) == TK_SVEC { return kb_unknown(w); }
        let n = ty_count(vals[vec].ty);
        var dv = ap_ones(n);
        let ci = m_constant_int(idx);
        if ci >= 0 && ap_ult_u64(ci_ap(ci), n as u64) { dv = ap_one_bit(n, ap_lo64(ci_ap(ci)) as i64); }
        return kb_compute(vec, dv, depth + 1);
    }
    if o == OP_EXTRACTVALUE {
        let agg = op(iv, 0);
        let id = inst_iid(agg);
        let x = insts[inst_of(iv)];
        if id != 0 && x.naux == 1 && ints[x.aux] == 0 {
            if id == IID_uadd_with_overflow || id == IID_sadd_with_overflow { return kb_add_sub_ops(true, cb_arg(agg, 0), cb_arg(agg, 1), false, false, de, depth); }
            if id == IID_usub_with_overflow || id == IID_ssub_with_overflow { return kb_add_sub_ops(false, cb_arg(agg, 0), cb_arg(agg, 1), false, false, de, depth); }
            if id == IID_umul_with_overflow || id == IID_smul_with_overflow { return kb_mul_ops(cb_arg(agg, 0), cb_arg(agg, 1), false, false, de, depth); }
        }
        return known;
    }
    if o == OP_FREEZE {
        if is_guaranteed_not_to_be_poison(op(iv, 0), kb_cxt, depth + 1) { return kb_compute_all(op(iv, 0), depth + 1); }
        return known;
    }
    return known;
}
fn elementwise_bitcast_v(v: i32) -> bool {
    let st = vals[op(v, 0)].ty;
    let dt = vals[v].ty;
    if ty_is_vector(st) != ty_is_vector(dt) { return false; }
    if ty_is_vector(st) { return ty_count(st) == ty_count(dt) && ty_kind(st) == ty_kind(dt); }
    return true;
}

recursive fn kb_gep(iv: i32, known0: KB, depth: i64) -> KB {
    var known = kb_compute_all(op(iv, 0), depth + 1);
    let w = kb_bw(known);
    let iw = dl_ptr(ptr_as(vals[iv].ty)).idx;
    if iw != w { not_ported("GEP known bits with an index width different from the pointer width"); }
    var acc = ap_zero(iw);
    var t = gep_src_ty(iv);
    for i in 1..nops(iv) {
        if kb_is_unknown(known) { break; }
        let ix = op(iv, i);
        let is_struct = i > 1 && ty_is_struct(t);
        let cur = t;
        if i > 1 { t = if ty_is_struct(t) { ty_field(t, ap_lo64(ci_ap(m_apint(ix))) as i64) } else { types[t].a }; }
        if is_constant(ix) && is_null_value(ix) { continue; }
        if is_struct {
            let fi = ap_lo64(ci_ap(m_apint(ix))) as i64;
            acc = ap_add(acc, ap_u64(dl_struct_offset(cur, fi) as u64, iw));
            continue;
        }
        let it = if i == 1 { cur } else { t };
        if !cf_ty_is_sized(it) { return kb_unknown(w); }
        if ty_kind(it) == TK_SVEC || ty_contains_scalable(it) { not_ported("known bits of GEPs over scalable types"); }
        let stride = ap_u64(dl_alloc_size(it) as u64, iw);
        let ci = m_constant_int(ix);
        if ci >= 0 {
            acc = ap_add(acc, ap_mul(ap_sext_or_trunc(ci_ap(ci), iw), stride));
            continue;
        }
        var ib = kb_compute_all(ix, depth + 1);
        ib = kb_sext_or_trunc(ib, iw);
        let sf = kb_const_ap(stride);
        known = kb_add_sub(true, false, false, known, kb_mul(ib, sf, false));
    }
    if !kb_is_unknown(known) && !ap_is_zero(acc) { known = kb_add_sub(true, false, false, known, kb_const_ap(acc)); }
    return known;
}

recursive fn kb_phi(p: i32, de: AP, known0: KB, depth: i64) -> KB {
    var known = known0;
    let w = kb_bw(known);
    let save = kb_cxt;
    if match_simple_recurrence(p) {
        let bo = rec_bo;
        let r = rec_start;
        let l = rec_step;
        let o = iop(bo);
        if (o == OP_LSHR || o == OP_ASHR || o == OP_SHL || o == OP_UDIV) && op(bo, 0) != p {
        } else if o == OP_LSHR || o == OP_ASHR || o == OP_SHL || o == OP_UDIV || o == OP_UREM {
            kb_cxt = p;
            let k2 = kb_compute(r, de, depth + 1);
            kb_cxt = save;
            if o == OP_SHL { known = kb_or_z(known, lowb(w, kb_min_tz(k2))); }
            else if o == OP_LSHR || o == OP_UDIV || o == OP_UREM { known = kb_or_z(known, highb(w, kb_min_lz(k2))); }
            else { known = kb_or_z(known, highb(w, kb_min_lz(k2))); known = kb_or_o(known, highb(w, kb_min_lo(k2))); }
        } else if o == OP_ADD || o == OP_SUB || o == OP_AND || o == OP_OR || o == OP_MUL {
            let opnum = if op(p, 0) == r { 0 } else { 1 };
            let rinst = block_terminator(phi_block(p, opnum));
            let linst = block_terminator(phi_block(p, 1 - opnum));
            kb_cxt = rinst;
            let k2 = kb_compute(r, de, depth + 1);
            kb_cxt = linst;
            let k3 = kb_compute(l, de, depth + 1);
            kb_cxt = save;
            known = kb_or_z(known, lowb(w, min(kb_min_tz(k2), kb_min_tz(k3))));
            let is_ovf_op = o == OP_ADD || o == OP_SUB || o == OP_MUL;
            if is_ovf_op && iiq_nsw(bo) {
                if o == OP_ADD {
                    if kb_is_nonneg(k2) && kb_is_nonneg(k3) { known = kb_make_nonneg(known); }
                    else if kb_is_neg(k2) && kb_is_neg(k3) { known = kb_make_neg(known); }
                } else if o == OP_SUB {
                    if op(bo, 0) == p {
                        if kb_is_nonneg(k2) && kb_is_neg(k3) { known = kb_make_nonneg(known); }
                        else if kb_is_neg(k2) && kb_is_nonneg(k3) { known = kb_make_neg(known); }
                    }
                } else if o == OP_MUL {
                    if kb_is_nonneg(k2) && kb_is_nonneg(k3) { known = kb_make_nonneg(known); }
                }
            }
        }
    }
    if nops(p) == 0 { return known; }
    if depth < MAX_ANALYSIS_DEPTH - 1 && kb_is_unknown(known) {
        let hc = phi_has_constant_value(p);
        if hc >= 0 && is_undef_or_poison(hc) { return known; }
        known = kb_all_conflict(w);
        for k in nops(p) {
            let inc, cxt, cphi = break_self_recursive_phi(p, k);
            if inc == p { continue; }
            kb_cxt = cxt;
            var k2 = kb_compute(inc, de, MAX_ANALYSIS_DEPTH - 1);
            if !kb_is_constant(k2) && cxt >= 0 && iop(cxt) == OP_CONDBR && is_inst_op(op(cxt, 0), OP_ICMP) {
                let c = op(cxt, 0);
                var pr = inst_pred(c);
                var rc: i32 = -1;
                if op(c, 0) == inc { rc = m_apint(op(c, 1)); }
                else if op(c, 1) == inc { rc = m_apint(op(c, 0)); pr = pred_swapped(pr); }
                if rc >= 0 {
                    let ts = op(cxt, 1);
                    let fs = op(cxt, 2);
                    let pb = inst_parent(cphi);
                    if (ts == pb) != (fs == pb) {
                        if fs == pb { pr = pred_inverse(pr); }
                        let cr = rg_exact_icmp(pr, ci_ap(rc));
                        let ku = kb_union(k2, rg_to_kb(cr));
                        if kb_has_conflict(ku) { known = kb_unknown(w); kb_cxt = save; break; }
                        k2 = ku;
                    }
                }
            }
            kb_cxt = save;
            known = kb_intersect(known, k2);
            if kb_is_unknown(known) { break; }
        }
    }
    kb_cxt = save;
    return known;
}

recursive fn kb_call(iv: i32, de: AP, known0: KB, depth: i64) -> KB {
    var known = known0;
    let w = kb_bw(known);
    let rm = iiq_md(iv, md_kind_id("range"));
    if rm >= 0 { known = kb_from_range_md(rm, w); }
    if call_range(iv) { known = kb_union(known, rg_to_kb(vt_cr)); }
    let rv = returned_arg_operand(iv);
    if rv >= 0 && vals[rv].ty == vals[iv].ty {
        let k2 = kb_compute_all(rv, depth + 1);
        known = kb_union(known, k2);
        if kb_has_conflict(known) { known = kb_unknown(w); }
    }
    let id = call_iid(iv);
    if id == 0 { return known; }
    if id == IID_abs {
        let k2 = kb_compute(op(iv, 0), de, depth + 1);
        return kb_union(known, kb_abs(k2, m_one(op(iv, 1))));
    }
    if id == IID_bitreverse {
        let k2 = kb_compute(op(iv, 0), de, depth + 1);
        return kb_union(known, kb_reverse_bits(k2));
    }
    if id == IID_bswap {
        let k2 = kb_compute(op(iv, 0), de, depth + 1);
        return kb_union(known, kb_byte_swap(k2));
    }
    if id == IID_ctlz || id == IID_cttz {
        let k2 = kb_compute(op(iv, 0), de, depth + 1);
        var p = if id == IID_ctlz { kb_max_lz(k2) } else { kb_max_tz(k2) };
        if op(iv, 1) == c_true() { p = min(p, w - 1); }
        let lb = 64 - clz(p as u64);
        return kb_or_z(known, ap_not(lowb(w, lb)));
    }
    if id == IID_ctpop {
        let k2 = kb_compute(op(iv, 0), de, depth + 1);
        let lb = 64 - clz(kb_max_pop(k2) as u64);
        return kb_or_z(known, ap_not(lowb(w, lb)));
    }
    if id == IID_fshl || id == IID_fshr {
        let sa = m_apint(op(iv, 2));
        if sa < 0 { return known; }
        let k2 = kb_compute(op(iv, 0), de, depth + 1);
        let k3 = kb_compute(op(iv, 1), de, depth + 1);
        return kb_fsh(k2, k3, ci_ap(sa), id == IID_fshl);
    }
    if id == IID_clmul {
        let k1 = kb_compute(op(iv, 0), de, depth + 1);
        let k2 = kb_compute(op(iv, 1), de, depth + 1);
        return kb_clmul(k1, k2);
    }
    if id == IID_pext || id == IID_pdep {
        let k1 = kb_compute(op(iv, 0), de, depth + 1);
        let k2 = kb_compute(op(iv, 1), de, depth + 1);
        return if id == IID_pext { kb_pext(k1, k2) } else { kb_pdep(k1, k2) };
    }
    if id == IID_uadd_sat || id == IID_usub_sat || id == IID_sadd_sat || id == IID_ssub_sat {
        let k1 = kb_compute(op(iv, 0), de, depth + 1);
        let k2 = kb_compute(op(iv, 1), de, depth + 1);
        return kb_sat_add_sub(id == IID_uadd_sat || id == IID_sadd_sat, id == IID_sadd_sat || id == IID_ssub_sat, k1, k2);
    }
    if id == IID_vector_reverse {
        return kb_compute(op(iv, 0), ap_reverse_bits(de), depth + 1);
    }
    if id == IID_vector_reduce_and || id == IID_vector_reduce_or || id == IID_vector_reduce_umax || id == IID_vector_reduce_umin ||
       id == IID_vector_reduce_smax || id == IID_vector_reduce_smin {
        return kb_compute_all(op(iv, 0), depth + 1);
    }
    if id == IID_vector_reduce_xor {
        known = kb_compute_all(op(iv, 0), depth + 1);
        let vt0 = vals[op(iv, 0)].ty;
        let even = (ty_count(vt0) % 2) == 0;
        if even { known.z = ap_or(known.z, known.o); }
        if ty_kind(vt0) == TK_SVEC || even { known.o = ap_zero(w); }
        return known;
    }
    if id == IID_vector_reduce_add {
        let vt0 = vals[op(iv, 0)].ty;
        if ty_kind(vt0) != TK_FVEC { return known; }
        known = kb_compute_all(op(iv, 0), depth + 1);
        return kb_reduce_add(known, ty_count(vt0));
    }
    if id == IID_umin || id == IID_umax || id == IID_smin || id == IID_smax {
        let k1 = kb_compute(op(iv, 0), de, depth + 1);
        let k2 = kb_compute(op(iv, 1), de, depth + 1);
        if id == IID_umin { return kb_umin(k1, k2); }
        if id == IID_umax { return kb_umax(k1, k2); }
        var r = if id == IID_smin { kb_smin_op(k1, k2) } else { kb_smax_op(k1, k2) };
        // unionWithMinMaxIntrinsicClamp
        let inner = op(iv, 0);
        let inv = if id == IID_smin { IID_smax } else { IID_smin };
        if inst_iid(inner) == inv && m_apint(op(iv, 1)) >= 0 && m_apint(op(inner, 1)) >= 0 {
            var lo = ci_ap(m_apint(op(iv, 1)));
            var hi = ci_ap(m_apint(op(inner, 1)));
            if id == IID_smin { let t = lo; lo = hi; hi = t; }
            if ap_sle(lo, hi) {
                r = kb_union(r, rg_to_kb(rg_nonempty(lo, ap_inc(hi))));
            }
        }
        return r;
    }
    if id == IID_ptrmask {
        known = kb_compute(op(iv, 0), de, depth + 1);
        let mk = kb_compute(op(iv, 1), de, depth + 1);
        return kb_and(known, kb_anyext_or_trunc(mk, w));
    }
    if id == IID_vscale { return kb_vscale(inst_func(iv), w); }
    // the target intrinsics computeKnownBitsFromOperator handles; any other intrinsic gives no known bits
    if id == IID_x86_sse2_pmulh_w || id == IID_x86_avx2_pmulh_w || id == IID_x86_avx512_pmulh_w_512 ||
       id == IID_x86_sse2_pmulhu_w || id == IID_x86_avx2_pmulhu_w || id == IID_x86_avx512_pmulhu_w_512 {
        let k1 = kb_compute(op(iv, 0), de, depth + 1);
        let k2 = kb_compute(op(iv, 1), de, depth + 1);
        let signed = id == IID_x86_sse2_pmulh_w || id == IID_x86_avx2_pmulh_w || id == IID_x86_avx512_pmulh_w_512;
        // KnownBits::mulhs / mulhu
        let bw = kb_bw(k1);
        let wl = if signed { kb_sext(k1, 2 * bw) } else { kb_zext(k1, 2 * bw) };
        let wr = if signed { kb_sext(k2, 2 * bw) } else { kb_zext(k2, 2 * bw) };
        return kb_extract_bits(kb_mul(wl, wr, false), bw, bw);
    }
    if id == IID_x86_sse42_crc32_64_64 { return KB { z: ap_or(known.z, ap_bits_from(w, 32)), o: known.o }; }
    if id == IID_x86_ssse3_phadd_d_128 || id == IID_x86_ssse3_phadd_w_128 || id == IID_x86_avx2_phadd_d ||
       id == IID_x86_avx2_phadd_w || id == IID_x86_ssse3_phadd_sw_128 || id == IID_x86_avx2_phadd_sw ||
       id == IID_x86_ssse3_phsub_d_128 || id == IID_x86_ssse3_phsub_w_128 || id == IID_x86_avx2_phsub_d ||
       id == IID_x86_avx2_phsub_w || id == IID_x86_ssse3_phsub_sw_128 || id == IID_x86_avx2_phsub_sw {
        // computeKnownBitsForHorizontalOperation
        var kind = 0;   // 0 add, 1 sadd_sat, 2 sub, 3 ssub_sat
        if id == IID_x86_ssse3_phadd_sw_128 || id == IID_x86_avx2_phadd_sw { kind = 1; }
        else if id == IID_x86_ssse3_phsub_d_128 || id == IID_x86_ssse3_phsub_w_128 || id == IID_x86_avx2_phsub_d || id == IID_x86_avx2_phsub_w { kind = 2; }
        else if id == IID_x86_ssse3_phsub_sw_128 || id == IID_x86_avx2_phsub_sw { kind = 3; }
        let vt = vals[iv].ty;
        let ne = ty_count(vt);
        let nl = ty_count(vt) * ty_scalar_bits(vt) / 128;
        let nepl = ne / nl;
        let half = nepl / 2;
        var dl = ap_zero(ne);
        var dr = ap_zero(ne);
        for idx in ne {
            if !de_get(de, idx) { continue; }
            let li = (idx / nepl) * nepl;
            var lo = idx % nepl;
            if lo < half { dl = ap_set_bit(dl, li + 2 * lo); }
            else { lo -= half; dr = ap_set_bit(dr, li + 2 * lo); }
        }
        if ap_is_zero(dr) { return kb_horiz_single(op(iv, 0), dl, kind, depth); }
        if ap_is_zero(dl) { return kb_horiz_single(op(iv, 1), dr, kind, depth); }
        return kb_intersect(kb_horiz_single(op(iv, 0), dl, kind, depth), kb_horiz_single(op(iv, 1), dr, kind, depth));
    }
    if id == IID_riscv_vsetvli || id == IID_riscv_vsetvlimax ||
       id == IID_amdgcn_mbcnt_hi || id == IID_amdgcn_mbcnt_lo {
        not_ported(str("known bits of ", intr_name(id as i64)));
    }
    return known;
}

// getVScaleRange(F, BitWidth).toKnownBits() (ValueTracking.cpp; ConstantRange::toKnownBits)
fn kb_vscale(fv: i32, w: i64) -> KB { rg_to_kb(vt_vscale_range(fv, w)) }

// computeKnownBitsForHorizontalOperation's ComputeForSingleOpFunc: f(known(Op, D), known(Op, D << 1))
recursive fn kb_horiz_single(o: i32, d: AP, kind: i64, depth: i64) -> KB {
    let a = kb_compute(o, d, depth + 1);
    let b = kb_compute(o, ap_shl(d, 1), depth + 1);
    if kind == 0 { return kb_add_sub(true, false, false, a, b); }
    if kind == 1 { return kb_sat_add_sub(true, true, a, b); }
    if kind == 2 { return kb_add_sub(false, false, false, a, b); }
    return kb_sat_add_sub(false, true, a, b);
}
// KnownBits::pext(Val, Mask)
fn kb_pext(v: KB, m: KB) -> KB {
    let bw = kb_bw(v);
    var rz = ap_ones(bw);
    var ro = ap_ones(bw);
    var m0: i64 = 0;
    var m1: i64 = 0;
    for i in bw {
        if !ap_get_bit(m.z, i) {
            if !ap_get_bit(v.z, i) { for j in m0..min(m1 + 1, bw) { rz = ap_clear_bit(rz, j); } }
            if !ap_get_bit(v.o, i) { for j in m0..min(m1 + 1, bw) { ro = ap_clear_bit(ro, j); } }
        }
        if ap_get_bit(m.o, i) { m0++; m1++; } else if !ap_get_bit(m.z, i) { m1++; }
    }
    for j in m0..bw { ro = ap_clear_bit(ro, j); }
    return KB { z: rz, o: ro };
}
// KnownBits::pdep(Val, Mask)
fn kb_pdep(v: KB, m: KB) -> KB {
    let bw = kb_bw(v);
    var rz = ap_ones(bw);
    var ro = ap_ones(bw);
    var m0: i64 = 0;
    var m1: i64 = 0;
    for i in bw {
        if !ap_get_bit(m.o, i) { ro = ap_clear_bit(ro, i); }
        if !ap_get_bit(m.z, i) {
            var all_one = true;
            var all_zero = true;
            for j in m0..min(m1 + 1, bw) {
                if !ap_get_bit(v.o, j) { all_one = false; }
                if !ap_get_bit(v.z, j) { all_zero = false; }
            }
            if !all_one { ro = ap_clear_bit(ro, i); }
            if !all_zero { rz = ap_clear_bit(rz, i); }
        }
        if ap_get_bit(m.o, i) { m0++; m1++; } else if !ap_get_bit(m.z, i) { m1++; }
    }
    return KB { z: rz, o: ro };
}
