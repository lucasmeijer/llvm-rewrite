// APInt for bit widths up to 256: a port of the parts of llvm/include/llvm/ADT/APInt.h and
// llvm/lib/Support/APInt.cpp that ConstantRange (constrange.goose) and the lattice analyses need.
// The value is kept truncated to `w` bits in four little-endian u64 words; unused words are zero.
// Widths above 256 fail loudly (AP_MAXW). Everything wraps like APInt (u64 arithmetic wraps by definition).
//
// Reusable API (prefix ap_): constructors ap_zero/ap_u64/ap_i64/ap_ones/ap_smin_val/ap_smax_val/ap_one_bit/
// ap_low_bits/ap_high_bits/ap_bits_from/ap_bits_set; arithmetic add/sub/neg/not/and/or/xor/inc/dec/mul/
// shl/lshr/ashr (by i64 or by AP)/udiv/urem/sdiv/srem/rounding divisions; overflow and saturating ops;
// comparisons; counts (clz/clo/ctz/cto/popcount/active_bits/sig_bits); zext/sext/trunc;
// ap_from_cint (ConstantInt -> AP) and ap_to_cint (AP -> ConstantInt of a type).
import std;
import ir;
import constfold;

let AP_MAXW = 256;

struct AP { v: u64[4], w: i32 }

fn ap_fail_width(w: i64) { fatal(str("APInt: integers wider than 256 bits are not supported yet (i", w, ")")); }
fn ap_nw(w: i64) -> i64 { (w + 63) / 64 }

fn ap_norm(a: AP) -> AP {
    var r = a;
    let w = r.w as i64;
    var k: i64 = 0;
    while k < 4 {
        let lo = k * 64;
        if lo >= w { r.v[k] = 0; }
        else if w - lo < 64 { r.v[k] = r.v[k] & (((1 as u64) << (w - lo)) - 1); }
        k++;
    }
    return r;
}

fn ap_zero(w: i64) -> AP {
    if w > AP_MAXW || w <= 0 { ap_fail_width(w); }
    return AP { v: [0, 0, 0, 0], w: w as i32 };
}
fn ap_u64(x: u64, w: i64) -> AP { var r = ap_zero(w); r.v[0] = x; return ap_norm(r); }
fn ap_i64(x: i64, w: i64) -> AP {
    var r = ap_zero(w);
    let s: u64 = if x < 0 { 0xFFFFFFFFFFFFFFFF } else { 0 };
    r.v[0] = x as! u64; r.v[1] = s; r.v[2] = s; r.v[3] = s;
    return ap_norm(r);
}
fn ap_ones(w: i64) -> AP {
    var r = ap_zero(w);
    r.v[0] = 0xFFFFFFFFFFFFFFFF; r.v[1] = 0xFFFFFFFFFFFFFFFF; r.v[2] = 0xFFFFFFFFFFFFFFFF; r.v[3] = 0xFFFFFFFFFFFFFFFF;
    return ap_norm(r);
}
fn ap_get_bit(a: AP, k: i64) -> bool { ((a.v[k / 64] >> (k % 64)) & 1) != 0 }
fn ap_set_bit(a: AP, k: i64) -> AP { var r = a; r.v[k / 64] = r.v[k / 64] | ((1 as u64) << (k % 64)); return r; }
fn ap_clear_bit(a: AP, k: i64) -> AP { var r = a; r.v[k / 64] = r.v[k / 64] & ~((1 as u64) << (k % 64)); return r; }
fn ap_one_bit(w: i64, k: i64) -> AP { ap_set_bit(ap_zero(w), k) }
fn ap_smin_val(w: i64) -> AP { ap_one_bit(w, w - 1) }
fn ap_smax_val(w: i64) -> AP { ap_clear_bit(ap_ones(w), w - 1) }
// getLowBitsSet(w, n)
fn ap_low_bits(w: i64, n: i64) -> AP {
    if n <= 0 { return ap_zero(w); }
    if n >= w { return ap_ones(w); }
    var r = ap_ones(n);
    r.w = w as i32;
    return r;
}
// getHighBitsSet(w, n)
fn ap_high_bits(w: i64, n: i64) -> AP { ap_not(ap_low_bits(w, w - n)) }
// getBitsSetFrom(w, lo): bits [lo, w)
fn ap_bits_from(w: i64, lo: i64) -> AP { ap_not(ap_low_bits(w, lo)) }
// getBitsSet(w, lo, hi): bits [lo, hi) (no wrap)
fn ap_bits_set(w: i64, lo: i64, hi: i64) -> AP { ap_and(ap_low_bits(w, hi), ap_bits_from(w, lo)) }

fn ap_lo64(a: AP) -> u64 { a.v[0] }
fn ap_fits_u64(a: AP) -> bool { a.v[1] == 0 && a.v[2] == 0 && a.v[3] == 0 }
// getLimitedValue(lim)
fn ap_limited(a: AP, lim: u64) -> u64 { if !ap_fits_u64(a) || a.v[0] > lim { lim } else { a.v[0] } }
// getSExtValue for values whose significant bits fit in 64
fn ap_sext64(a: AP) -> i64 { ap_sext(a, 256).v[0] as! i64 }

fn ap_eq(a: AP, b: AP) -> bool { a.v[0] == b.v[0] && a.v[1] == b.v[1] && a.v[2] == b.v[2] && a.v[3] == b.v[3] }
fn ap_ne(a: AP, b: AP) -> bool { !ap_eq(a, b) }
fn ap_eq_u64(a: AP, x: u64) -> bool { ap_fits_u64(a) && a.v[0] == x }
fn ap_is_zero(a: AP) -> bool { a.v[0] == 0 && a.v[1] == 0 && a.v[2] == 0 && a.v[3] == 0 }
fn ap_is_one(a: AP) -> bool { ap_eq_u64(a, 1) }
fn ap_is_all_ones(a: AP) -> bool { ap_eq(a, ap_ones(a.w as i64)) }
fn ap_is_neg(a: AP) -> bool { ap_get_bit(a, (a.w as i64) - 1) }
fn ap_is_nonneg(a: AP) -> bool { !ap_is_neg(a) }
fn ap_is_strictly_pos(a: AP) -> bool { !ap_is_neg(a) && !ap_is_zero(a) }
fn ap_is_min_signed(a: AP) -> bool { ap_eq(a, ap_smin_val(a.w as i64)) }
fn ap_is_max_signed(a: AP) -> bool { ap_eq(a, ap_smax_val(a.w as i64)) }
fn ap_is_pow2(a: AP) -> bool { ap_popcount(a) == 1 }

fn ap_ult(a: AP, b: AP) -> bool {
    var k: i64 = 3;
    while k >= 0 {
        if a.v[k] != b.v[k] { return a.v[k] < b.v[k]; }
        k--;
    }
    return false;
}
fn ap_ule(a: AP, b: AP) -> bool { !ap_ult(b, a) }
fn ap_ugt(a: AP, b: AP) -> bool { ap_ult(b, a) }
fn ap_uge(a: AP, b: AP) -> bool { !ap_ult(a, b) }
fn ap_slt(a: AP, b: AP) -> bool {
    let na = ap_is_neg(a);
    let nb = ap_is_neg(b);
    if na != nb { return na; }
    return ap_ult(a, b);
}
fn ap_sle(a: AP, b: AP) -> bool { !ap_slt(b, a) }
fn ap_sgt(a: AP, b: AP) -> bool { ap_slt(b, a) }
fn ap_sge(a: AP, b: AP) -> bool { !ap_slt(a, b) }
fn ap_ult_u64(a: AP, x: u64) -> bool { ap_fits_u64(a) && a.v[0] < x }
fn ap_ugt_u64(a: AP, x: u64) -> bool { !ap_fits_u64(a) || a.v[0] > x }
fn ap_ule_u64(a: AP, x: u64) -> bool { ap_fits_u64(a) && a.v[0] <= x }
fn ap_uge_u64(a: AP, x: u64) -> bool { !ap_fits_u64(a) || a.v[0] >= x }
fn ap_sgt_i64(a: AP, x: i64) -> bool { ap_sgt(a, ap_i64(x, a.w as i64)) }

fn ap_umin(a: AP, b: AP) -> AP { if ap_ult(b, a) { b } else { a } }
fn ap_umax(a: AP, b: AP) -> AP { if ap_ugt(b, a) { b } else { a } }
fn ap_smin(a: AP, b: AP) -> AP { if ap_slt(b, a) { b } else { a } }
fn ap_smax(a: AP, b: AP) -> AP { if ap_sgt(b, a) { b } else { a } }

fn ap_add(a: AP, b: AP) -> AP {
    var r = a;
    var carry: u64 = 0;
    var k: i64 = 0;
    while k < 4 {
        let s = a.v[k] + b.v[k];
        let c1: u64 = if s < a.v[k] { 1 } else { 0 };
        let s2 = s + carry;
        let c2: u64 = if s2 < s { 1 } else { 0 };
        r.v[k] = s2;
        carry = c1 + c2;
        k++;
    }
    return ap_norm(r);
}
fn ap_not(a: AP) -> AP {
    var r = a;
    r.v[0] = ~a.v[0]; r.v[1] = ~a.v[1]; r.v[2] = ~a.v[2]; r.v[3] = ~a.v[3];
    return ap_norm(r);
}
fn ap_neg(a: AP) -> AP { ap_inc(ap_not(a)) }
fn ap_sub(a: AP, b: AP) -> AP { ap_add(a, ap_neg(b)) }
fn ap_inc(a: AP) -> AP { ap_add(a, ap_u64(1, a.w as i64)) }
fn ap_dec(a: AP) -> AP { ap_sub(a, ap_u64(1, a.w as i64)) }
fn ap_add_u64(a: AP, x: u64) -> AP { ap_add(a, ap_u64(x, a.w as i64)) }
fn ap_sub_u64(a: AP, x: u64) -> AP { ap_sub(a, ap_u64(x, a.w as i64)) }
fn ap_and(a: AP, b: AP) -> AP {
    var r = a;
    r.v[0] = a.v[0] & b.v[0]; r.v[1] = a.v[1] & b.v[1]; r.v[2] = a.v[2] & b.v[2]; r.v[3] = a.v[3] & b.v[3];
    return r;
}
fn ap_or(a: AP, b: AP) -> AP {
    var r = a;
    r.v[0] = a.v[0] | b.v[0]; r.v[1] = a.v[1] | b.v[1]; r.v[2] = a.v[2] | b.v[2]; r.v[3] = a.v[3] | b.v[3];
    return r;
}
fn ap_xor(a: AP, b: AP) -> AP {
    var r = a;
    r.v[0] = a.v[0] ^ b.v[0]; r.v[1] = a.v[1] ^ b.v[1]; r.v[2] = a.v[2] ^ b.v[2]; r.v[3] = a.v[3] ^ b.v[3];
    return r;
}
// isSubsetOf: a & ~b == 0
fn ap_is_subset_of(a: AP, b: AP) -> bool { ap_is_zero(ap_and(a, ap_not(b))) }

fn ap_shl(a: AP, k: i64) -> AP {
    if k <= 0 { return a; }
    if k >= (a.w as i64) { return ap_zero(a.w as i64); }
    var r = ap_zero(a.w as i64);
    let ws = k / 64;
    let bs = k % 64;
    var i: i64 = 3;
    while i >= ws {
        var x = a.v[i - ws] << bs;
        if bs > 0 && i - ws - 1 >= 0 { x = x | (a.v[i - ws - 1] >> (64 - bs)); }
        r.v[i] = x;
        i--;
    }
    return ap_norm(r);
}
fn ap_lshr(a: AP, k: i64) -> AP {
    if k <= 0 { return a; }
    if k >= (a.w as i64) { return ap_zero(a.w as i64); }
    var r = ap_zero(a.w as i64);
    let ws = k / 64;
    let bs = k % 64;
    var i: i64 = 0;
    while i + ws < 4 {
        var x = a.v[i + ws] >> bs;
        if bs > 0 && i + ws + 1 < 4 { x = x | (a.v[i + ws + 1] << (64 - bs)); }
        r.v[i] = x;
        i++;
    }
    return r;
}
fn ap_ashr(a: AP, k: i64) -> AP {
    let w = a.w as i64;
    if !ap_is_neg(a) { return ap_lshr(a, k); }
    if k >= w { return ap_ones(w); }
    if k <= 0 { return a; }
    return ap_or(ap_lshr(a, k), ap_high_bits(w, k));
}
// shifts by an APInt amount (getLimitedValue(BitWidth))
fn ap_shl_ap(a: AP, s: AP) -> AP { ap_shl(a, ap_limited(s, a.w as u64) as i64) }
fn ap_lshr_ap(a: AP, s: AP) -> AP { ap_lshr(a, ap_limited(s, a.w as u64) as i64) }
fn ap_ashr_ap(a: AP, s: AP) -> AP { ap_ashr(a, ap_limited(s, a.w as u64) as i64) }

fn ap_mul64(a: u64, b: u64) -> u64, u64 {
    let a0 = a & 0xFFFFFFFF;
    let a1 = a >> 32;
    let b0 = b & 0xFFFFFFFF;
    let b1 = b >> 32;
    let p00 = a0 * b0;
    let p01 = a0 * b1;
    let p10 = a1 * b0;
    let p11 = a1 * b1;
    let mid = (p00 >> 32) + (p01 & 0xFFFFFFFF) + (p10 & 0xFFFFFFFF);
    let lo = (p00 & 0xFFFFFFFF) | (mid << 32);
    let hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
    return lo, hi;
}
fn ap_mul(a: AP, b: AP) -> AP {
    if a.w <= 64 { return ap_u64(a.v[0] * b.v[0], a.w as i64); }
    var r = ap_zero(a.w as i64);
    var i: i64 = 0;
    while i < 4 {
        if a.v[i] != 0 {
            var carry: u64 = 0;
            var j: i64 = 0;
            while i + j < 4 {
                let lo, hi = ap_mul64(a.v[i], b.v[j]);
                let s = r.v[i + j] + lo;
                let c1: u64 = if s < lo { 1 } else { 0 };
                let s2 = s + carry;
                let c2: u64 = if s2 < s { 1 } else { 0 };
                r.v[i + j] = s2;
                carry = hi + c1 + c2;
                j++;
            }
        }
        i++;
    }
    return ap_norm(r);
}

// unsigned division (b != 0)
fn ap_udivrem(a: AP, b: AP) -> AP, AP {
    let w = a.w as i64;
    if ap_is_zero(b) { fatal("APInt: division by zero"); }
    if w <= 64 { return ap_u64(a.v[0] / b.v[0], w), ap_u64(a.v[0] % b.v[0], w); }
    if ap_fits_u64(a) && ap_fits_u64(b) { return ap_u64(a.v[0] / b.v[0], w), ap_u64(a.v[0] % b.v[0], w); }
    var q = ap_zero(w);
    var r = ap_zero(w);
    var k = w - 1;
    while k >= 0 {
        // r = (r << 1) | bit; r may exceed w bits only if b's top bit is set: track the carry out
        let top = ap_is_neg(r);
        r = ap_shl(r, 1);
        if ap_get_bit(a, k) { r.v[0] = r.v[0] | 1; }
        if top || ap_uge(r, b) {
            r = ap_sub(r, b);
            q = ap_set_bit(q, k);
        }
        k--;
    }
    return q, r;
}
fn ap_udiv(a: AP, b: AP) -> AP { let q, r = ap_udivrem(a, b); return q; }
fn ap_urem(a: AP, b: AP) -> AP { let q, r = ap_udivrem(a, b); return r; }
fn ap_sdiv(a: AP, b: AP) -> AP {
    let na = ap_is_neg(a);
    let nb = ap_is_neg(b);
    let q = ap_udiv(if na { ap_neg(a) } else { a }, if nb { ap_neg(b) } else { b });
    return if na != nb { ap_neg(q) } else { q };
}
fn ap_srem(a: AP, b: AP) -> AP {
    let na = ap_is_neg(a);
    let nb = ap_is_neg(b);
    let r = ap_urem(if na { ap_neg(a) } else { a }, if nb { ap_neg(b) } else { b });
    return if na { ap_neg(r) } else { r };
}
// APIntOps::RoundingUDiv
fn ap_rounding_udiv(a: AP, b: AP, up: bool) -> AP {
    let q, r = ap_udivrem(a, b);
    if up && !ap_is_zero(r) { return ap_inc(q); }
    return q;
}
// APIntOps::RoundingSDiv (UP / DOWN)
fn ap_rounding_sdiv(a: AP, b: AP, up: bool) -> AP {
    // sdivrem
    let q = ap_sdiv(a, b);
    let r = ap_srem(a, b);
    if ap_is_zero(r) { return q; }
    // a and b have the same sign iff the quotient is non-negative (when r != 0)
    let pos = ap_is_neg(a) == ap_is_neg(b);
    if up { return if pos { ap_inc(q) } else { q }; }
    return if pos { q } else { ap_dec(q) };
}

fn ap_countl_zero(a: AP) -> i64 {
    let w = a.w as i64;
    var k: i64 = 3;
    var n: i64 = 0;
    while k >= 0 {
        if a.v[k] != 0 { n = n + clz(a.v[k]); break; }
        n = n + 64;
        k--;
    }
    return n - (256 - w);
}
fn ap_countl_one(a: AP) -> i64 { ap_countl_zero(ap_not(a)) }
fn ap_countr_zero(a: AP) -> i64 {
    var k: i64 = 0;
    var n: i64 = 0;
    while k < 4 {
        if a.v[k] != 0 { n = n + ctz(a.v[k]); return if n > (a.w as i64) { a.w as i64 } else { n }; }
        n = n + 64;
        k++;
    }
    return a.w as i64;
}
fn ap_countr_one(a: AP) -> i64 { ap_countr_zero(ap_not(a)) }
fn ap_popcount(a: AP) -> i64 { popcount(a.v[0]) + popcount(a.v[1]) + popcount(a.v[2]) + popcount(a.v[3]) }
fn ap_active_bits(a: AP) -> i64 { (a.w as i64) - ap_countl_zero(a) }
fn ap_num_sign_bits(a: AP) -> i64 { if ap_is_neg(a) { ap_countl_one(a) } else { ap_countl_zero(a) } }
// getSignificantBits
fn ap_sig_bits(a: AP) -> i64 { (a.w as i64) - ap_num_sign_bits(a) + 1 }

fn ap_zext(a: AP, w: i64) -> AP { if w > AP_MAXW { ap_fail_width(w); } var r = a; r.w = w as i32; return r; }
fn ap_trunc(a: AP, w: i64) -> AP { var r = a; r.w = w as i32; return ap_norm(r); }
fn ap_sext(a: AP, w: i64) -> AP {
    if w > AP_MAXW { ap_fail_width(w); }
    let ow = a.w as i64;
    var r = a;
    r.w = w as i32;
    if w > ow && ap_is_neg(a) { r = ap_or(r, ap_high_bits(w, w - ow)); }
    return r;
}
fn ap_zext_or_trunc(a: AP, w: i64) -> AP { if w < (a.w as i64) { ap_trunc(a, w) } else { ap_zext(a, w) } }
fn ap_sext_or_trunc(a: AP, w: i64) -> AP { if w < (a.w as i64) { ap_trunc(a, w) } else { ap_sext(a, w) } }
// getHiBits(n): the top n bits, shifted down
fn ap_hi_bits(a: AP, n: i64) -> AP { ap_lshr(a, (a.w as i64) - n) }
fn ap_clear_low_bits(a: AP, n: i64) -> AP { ap_and(a, ap_bits_from(a.w as i64, n)) }

// overflow-detecting and saturating operations
fn ap_uadd_ov(a: AP, b: AP) -> AP, bool { let r = ap_add(a, b); return r, ap_ult(r, b); }
fn ap_sadd_ov(a: AP, b: AP) -> AP, bool {
    let r = ap_add(a, b);
    let ov = ap_is_neg(a) == ap_is_neg(b) && ap_is_neg(r) != ap_is_neg(a);
    return r, ov;
}
fn ap_usub_ov(a: AP, b: AP) -> AP, bool { return ap_sub(a, b), ap_ult(a, b); }
fn ap_ssub_ov(a: AP, b: AP) -> AP, bool {
    let r = ap_sub(a, b);
    let ov = ap_is_neg(a) != ap_is_neg(b) && ap_is_neg(r) != ap_is_neg(a);
    return r, ov;
}
fn ap_umul_ov(a: AP, b: AP) -> AP, bool {
    let w = a.w as i64;
    let r = ap_mul(a, b);
    if ap_is_zero(a) || ap_is_zero(b) { return r, false; }
    // overflow iff (a * b mod 2^w) / b != a
    if w <= 32 {
        let full = a.v[0] * b.v[0];
        return r, (full >> w) != 0;
    }
    return r, !ap_eq(ap_udiv(r, b), a);
}
fn ap_smul_ov(a: AP, b: AP) -> AP, bool {
    let r = ap_mul(a, b);
    if ap_is_zero(a) || ap_is_zero(b) { return r, false; }
    // APInt::smul_ov: Overflow = Res.sdiv(RHS) != *this || (isMinSignedValue() && RHS.isAllOnes())
    let ov = !ap_eq(ap_sdiv(r, b), a) || (ap_is_min_signed(a) && ap_is_all_ones(b));
    return r, ov;
}
fn ap_uadd_sat(a: AP, b: AP) -> AP { let r, ov = ap_uadd_ov(a, b); return if ov { ap_ones(a.w as i64) } else { r }; }
fn ap_sadd_sat(a: AP, b: AP) -> AP {
    let r, ov = ap_sadd_ov(a, b);
    if !ov { return r; }
    return if ap_is_neg(a) { ap_smin_val(a.w as i64) } else { ap_smax_val(a.w as i64) };
}
fn ap_usub_sat(a: AP, b: AP) -> AP { let r, ov = ap_usub_ov(a, b); return if ov { ap_zero(a.w as i64) } else { r }; }
fn ap_ssub_sat(a: AP, b: AP) -> AP {
    let r, ov = ap_ssub_ov(a, b);
    if !ov { return r; }
    return if ap_is_neg(a) { ap_smin_val(a.w as i64) } else { ap_smax_val(a.w as i64) };
}
fn ap_umul_sat(a: AP, b: AP) -> AP { let r, ov = ap_umul_ov(a, b); return if ov { ap_ones(a.w as i64) } else { r }; }
fn ap_smul_sat(a: AP, b: AP) -> AP {
    let r, ov = ap_smul_ov(a, b);
    if !ov { return r; }
    let resneg = ap_is_neg(a) != ap_is_neg(b);
    return if resneg { ap_smin_val(a.w as i64) } else { ap_smax_val(a.w as i64) };
}
// ushl_ov(ShAmt): Overflow = ShAmt.uge(getBitWidth()) || ShAmt.ugt(countl_zero())
fn ap_ushl_ov(a: AP, s: i64) -> AP, bool {
    let w = a.w as i64;
    if s >= w { return ap_zero(w), true; }
    return ap_shl(a, s), s > ap_countl_zero(a);
}
// sshl_ov(ShAmt): Overflow = ShAmt.uge(BW) || ShAmt.uge(isNegative() ? countl_one() : countl_zero())
fn ap_sshl_ov(a: AP, s: i64) -> AP, bool {
    let w = a.w as i64;
    if s >= w { return ap_zero(w), true; }
    let lim = if ap_is_neg(a) { ap_countl_one(a) } else { ap_countl_zero(a) };
    return ap_shl(a, s), s >= lim;
}
fn ap_ushl_sat(a: AP, s: AP) -> AP {
    let r, ov = ap_ushl_ov(a, ap_limited(s, a.w as u64) as i64);
    return if ov { ap_ones(a.w as i64) } else { r };
}
fn ap_sshl_sat(a: AP, s: AP) -> AP {
    let r, ov = ap_sshl_ov(a, ap_limited(s, a.w as u64) as i64);
    if !ov { return r; }
    return if ap_is_neg(a) { ap_smin_val(a.w as i64) } else { ap_smax_val(a.w as i64) };
}

// APIntOps::GetMostSignificantDifferentBit: -1 if equal
fn ap_most_sig_diff_bit(a: AP, b: AP) -> i64 {
    if ap_eq(a, b) { return -1; }
    return (a.w as i64) - ap_countl_zero(ap_xor(a, b)) - 1;
}

// ---------------------------------------------------------------------------------------------
// Conversions

fn ap_from_cint(v: i32) -> AP {
    let w = ty_bits(ty_scalar(vals[v].ty));
    if w > AP_MAXW { ap_fail_width(w); }
    var r = ap_zero(w);
    if w <= 128 { r.v[0] = cint_lo(v); r.v[1] = cint_hi(v); return r; }
    let c = csts[vals[v].sub];
    for k in ap_nw(w) { r.v[k] = words[c.ext + k]; }
    return r;
}
// ConstantInt::get(Ty, APInt) (a splat for vector types)
fn ap_to_cint(ty: i32, a: AP) -> i32 {
    let st = ty_scalar(ty);
    var c: i32 = -1;
    if (a.w as i64) <= 128 { c = c_int_words(st, a.v[0], a.v[1]); }
    else { c = c_int_wide(st, a.v[0..ap_nw(a.w as i64)]); }
    if ty_is_vector(ty) { return c_splat(ty, c); }
    return c;
}
fn ap_from_ai(a: AI) -> AP { var r = ap_zero(a.w); r.v[0] = a.lo; r.v[1] = a.hi; return r; }
fn ap_to_ai(a: AP) -> AI {
    if a.w > 128 { fatal("APInt: conversion of a >128-bit value to the 128-bit AI type"); }
    return ai_new(a.v[0], a.v[1], a.w as i64);
}

// decimal printing (for debug / printers)
fn ap_format_dec(out: u8[>..]&, a0: AP) {
    var a = a0;
    var digs: u8[..80] = [];
    if ap_is_zero(a) { out.push('0'); return; }
    if a.w < 8 { a = ap_zext(a, 8); }
    let t = ap_u64(10, a.w as i64);
    while !ap_is_zero(a) {
        let q, r = ap_udivrem(a, t);
        digs.push((48 + r.v[0]) as! u8);
        a = q;
    }
    var k = digs.len - 1;
    while k >= 0 { out.push(digs[k]); k--; }
}
