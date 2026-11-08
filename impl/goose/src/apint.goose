// APInt of any bit width: a port of llvm/include/llvm/ADT/APInt.h and llvm/lib/Support/APInt.cpp
// (arithmetic, division, shifts, rotates, overflow and saturating helpers, bit counts, extension,
// byte swap / bit reverse, toString) plus the APIntOps helpers the analyses use.
//
// Representation (DESIGN.md §10): `AP { lo, w, ix }` is a 16-byte value.
//  - w <= 64: the value is `lo` (always truncated to w bits), ix = -1. Every operation has a fast path for
//    this case that never touches memory, so 64-bit analyses cost what they cost with raw u64s.
//  - w > 64: the ceil(w/64) little-endian words live in the global word pool `apw` at [ix, ix + nw); the
//    top word is kept truncated; `lo` caches word 0. Pooled words are immutable once an AP is returned:
//    every operation writes its result into freshly allocated words, so copying an AP (sharing ix) is safe.
//  - The pool is a bump arena. The pass manager calls ap_pool_reset() after every pass, so an AP must not
//    outlive the pass that made it (store results as IR constants: ap_to_cint). ap_mark()/ap_release(m)
//    free temporaries of a bounded computation early.
// Everything wraps like APInt (u64 arithmetic wraps by definition).
import std;
import ir;
import constfold;

struct AP { lo: u64, w: i32, ix: i32 }

var apw: u64[>..<];

fn ap_pool_reset() { apw.resize(0); }
fn ap_mark() -> i64 { apw.len }
fn ap_release(m: i64) { if m < apw.len { apw.resize(m); } }

fn ap_fail_width(w: i64) { fatal(str("APInt: invalid bit width ", w)); }
fn ap_nw(w: i64) -> i64 { (w + 63) / 64 }
fn ap_nwords(a: AP) -> i64 { ap_nw(a.w as i64) }
fn ap_m64(w: i64) -> u64 { if w >= 64 { 0xFFFFFFFFFFFFFFFF } else { ((1 as u64) << w) - 1 } }
// mask of the valid bits of the top word
fn ap_topmask(w: i64) -> u64 { let r = w % 64; if r == 0 { 0xFFFFFFFFFFFFFFFF } else { ((1 as u64) << r) - 1 } }

// allocate nw(w) zero words
fn ap_alloc(w: i64) -> i32 {
    let at = apw.len;
    apw.resize(at + ap_nw(w), 0);
    return at as i32;
}
// finish a freshly written wide value: truncate the top word, cache word 0
fn ap_fin(w: i64, ix: i32) -> AP {
    let n = ap_nw(w);
    let t = (ix as i64) + n - 1;
    apw[t] = apw[t] & ap_topmask(w);
    return AP { lo: apw[ix as i64], w: w as i32, ix: ix };
}
fn ap_small(x: u64, w: i64) -> AP { AP { lo: x & ap_m64(w), w: w as i32, ix: -1 } }

// word k (0 beyond the top)
fn ap_word(a: AP, k: i64) -> u64 {
    if a.ix < 0 { return if k == 0 { a.lo } else { 0 }; }
    if k >= ap_nw(a.w as i64) || k < 0 { return 0; }
    return apw[(a.ix as i64) + k];
}
// word k of the value sign-extended to infinite width
fn ap_word_sx(a: AP, k: i64) -> u64 {
    let w = a.w as i64;
    let n = ap_nw(w);
    let neg = ap_is_neg(a);
    if k >= n { return if neg { 0xFFFFFFFFFFFFFFFF } else { 0 }; }
    var x = ap_word(a, k);
    if k == n - 1 && neg && w % 64 != 0 { x = x | ~ap_topmask(w); }
    return x;
}

fn ap_zero(w: i64) -> AP {
    if w <= 0 || w > 8388608 { ap_fail_width(w); }
    if w <= 64 { return AP { lo: 0, w: w as i32, ix: -1 }; }
    let ix = ap_alloc(w);
    return AP { lo: 0, w: w as i32, ix: ix };
}
fn ap_u64(x: u64, w: i64) -> AP {
    if w <= 64 { if w <= 0 { ap_fail_width(w); } return ap_small(x, w); }
    let ix = ap_alloc(w);
    apw[ix as i64] = x;
    return AP { lo: x, w: w as i32, ix: ix };
}
fn ap_i64(x: i64, w: i64) -> AP {
    if w <= 64 { if w <= 0 { ap_fail_width(w); } return ap_small(x as! u64, w); }
    let ix = ap_alloc(w);
    let s: u64 = if x < 0 { 0xFFFFFFFFFFFFFFFF } else { 0 };
    apw[ix as i64] = x as! u64;
    for k in ap_nw(w) - 1 { apw[(ix as i64) + 1 + k] = s; }
    return ap_fin(w, ix);
}
// a value from little-endian words (missing words are zero)
fn ap_from_words(w: i64, ws: const u64[:]) -> AP {
    if w <= 64 { return ap_small(if ws.len > 0 { ws[0] } else { 0 }, w); }
    let ix = ap_alloc(w);
    let n = ap_nw(w);
    for k in n { if k < ws.len { apw[(ix as i64) + k] = ws[k]; } }
    return ap_fin(w, ix);
}
fn ap_ones(w: i64) -> AP {
    if w <= 64 { return ap_small(0xFFFFFFFFFFFFFFFF, w); }
    let ix = ap_alloc(w);
    for k in ap_nw(w) { apw[(ix as i64) + k] = 0xFFFFFFFFFFFFFFFF; }
    return ap_fin(w, ix);
}
// a fresh copy of a wide value's words (to modify before returning)
fn ap_copy_ix(a: AP) -> i32 {
    let w = a.w as i64;
    let ix = ap_alloc(w);
    for k in ap_nw(w) { apw[(ix as i64) + k] = apw[(a.ix as i64) + k]; }
    return ix;
}

fn ap_get_bit(a: AP, k: i64) -> bool { ((ap_word(a, k / 64) >> (k % 64)) & 1) != 0 }
fn ap_set_bit(a: AP, k: i64) -> AP {
    if a.ix < 0 { return AP { lo: a.lo | ((1 as u64) << k), w: a.w, ix: -1 }; }
    let ix = ap_copy_ix(a);
    let p = (ix as i64) + k / 64;
    apw[p] = apw[p] | ((1 as u64) << (k % 64));
    return ap_fin(a.w as i64, ix);
}
fn ap_clear_bit(a: AP, k: i64) -> AP {
    if a.ix < 0 { return AP { lo: a.lo & ~((1 as u64) << k), w: a.w, ix: -1 }; }
    let ix = ap_copy_ix(a);
    let p = (ix as i64) + k / 64;
    apw[p] = apw[p] & ~((1 as u64) << (k % 64));
    return ap_fin(a.w as i64, ix);
}
fn ap_set_bit_to(a: AP, k: i64, b: bool) -> AP { if b { ap_set_bit(a, k) } else { ap_clear_bit(a, k) } }
fn ap_flip_bit(a: AP, k: i64) -> AP { ap_set_bit_to(a, k, !ap_get_bit(a, k)) }
fn ap_one_bit(w: i64, k: i64) -> AP { ap_set_bit(ap_zero(w), k) }
fn ap_smin_val(w: i64) -> AP { ap_one_bit(w, w - 1) }
fn ap_smax_val(w: i64) -> AP { ap_clear_bit(ap_ones(w), w - 1) }
fn ap_umax_val(w: i64) -> AP { ap_ones(w) }
fn ap_umin_val(w: i64) -> AP { ap_zero(w) }
fn ap_sign_mask(w: i64) -> AP { ap_smin_val(w) }
// getLowBitsSet(w, n)
fn ap_low_bits(w: i64, n: i64) -> AP {
    if n <= 0 { return ap_zero(w); }
    if n >= w { return ap_ones(w); }
    if w <= 64 { return ap_small(ap_m64(n), w); }
    let ix = ap_alloc(w);
    for k in ap_nw(w) {
        let lo = k * 64;
        if lo + 64 <= n { apw[(ix as i64) + k] = 0xFFFFFFFFFFFFFFFF; }
        else if lo < n { apw[(ix as i64) + k] = ap_m64(n - lo); }
    }
    return ap_fin(w, ix);
}
// getHighBitsSet(w, n)
fn ap_high_bits(w: i64, n: i64) -> AP { ap_not(ap_low_bits(w, w - n)) }
// getBitsSetFrom(w, lo): bits [lo, w)
fn ap_bits_from(w: i64, lo: i64) -> AP { ap_not(ap_low_bits(w, lo)) }
// getBitsSet(w, lo, hi): bits [lo, hi); wraps (bits [lo, w) and [0, hi)) when lo > hi, like APInt::setBits
fn ap_bits_set(w: i64, lo: i64, hi: i64) -> AP {
    if lo > hi { return ap_or(ap_low_bits(w, hi), ap_bits_from(w, lo)); }
    return ap_and(ap_low_bits(w, hi), ap_bits_from(w, lo));
}
// getSplat(w, v): v repeated to fill w bits
fn ap_splat(w: i64, v: AP) -> AP {
    var r = ap_zext_or_trunc(v, w);
    var k = v.w as i64;
    while k < w { r = ap_or(r, ap_shl(ap_zext_or_trunc(v, w), k)); k = k + (v.w as i64); }
    return r;
}

fn ap_lo64(a: AP) -> u64 { a.lo }
fn ap_fits_u64(a: AP) -> bool {
    if a.ix < 0 { return true; }
    for k in ap_nw(a.w as i64) - 1 { if apw[(a.ix as i64) + 1 + k] != 0 { return false; } }
    return true;
}
// getZExtValue (the low word; callers check fits)
fn ap_zext64(a: AP) -> u64 { a.lo }
// getLimitedValue(lim)
fn ap_limited(a: AP, lim: u64) -> u64 { if !ap_fits_u64(a) || a.lo > lim { lim } else { a.lo } }
// getSExtValue for values whose significant bits fit in 64
fn ap_sext64(a: AP) -> i64 {
    let w = a.w as i64;
    if w >= 64 { return a.lo as! i64; }
    return ((a.lo << (64 - w)) as! i64) >> (64 - w);
}
// isIntN / isSignedIntN
fn ap_is_int_n(a: AP, n: i64) -> bool { ap_active_bits(a) <= n }
fn ap_is_signed_int_n(a: AP, n: i64) -> bool { ap_sig_bits(a) <= n }

fn ap_eq(a: AP, b: AP) -> bool {
    if a.ix < 0 { return a.lo == b.lo; }
    if a.lo != b.lo { return false; }
    for k in ap_nw(a.w as i64) { if apw[(a.ix as i64) + k] != apw[(b.ix as i64) + k] { return false; } }
    return true;
}
fn ap_ne(a: AP, b: AP) -> bool { !ap_eq(a, b) }
fn ap_eq_u64(a: AP, x: u64) -> bool { a.lo == x && ap_fits_u64(a) }
fn ap_is_zero(a: AP) -> bool { a.lo == 0 && ap_fits_u64(a) }
fn ap_is_one(a: AP) -> bool { ap_eq_u64(a, 1) }
fn ap_is_all_ones(a: AP) -> bool {
    let w = a.w as i64;
    if a.ix < 0 { return a.lo == ap_m64(w); }
    let n = ap_nw(w);
    for k in n - 1 { if apw[(a.ix as i64) + k] != 0xFFFFFFFFFFFFFFFF { return false; } }
    return apw[(a.ix as i64) + n - 1] == ap_topmask(w);
}
fn ap_is_neg(a: AP) -> bool { ap_get_bit(a, (a.w as i64) - 1) }
fn ap_is_nonneg(a: AP) -> bool { !ap_is_neg(a) }
fn ap_is_strictly_pos(a: AP) -> bool { !ap_is_neg(a) && !ap_is_zero(a) }
fn ap_is_min_signed(a: AP) -> bool { ap_is_neg(a) && ap_countr_zero(a) == (a.w as i64) - 1 }
fn ap_is_max_signed(a: AP) -> bool { !ap_is_neg(a) && ap_countr_one(a) == (a.w as i64) - 1 }
fn ap_is_pow2(a: AP) -> bool { ap_popcount(a) == 1 }
// isNegatedPowerOf2
fn ap_is_neg_pow2(a: AP) -> bool {
    if !ap_is_neg(a) { return false; }
    let lo = ap_countl_one(a);
    let tz = ap_countr_zero(a);
    return lo + tz == (a.w as i64);
}
// isMask(): 0..01..1 with at least one bit
fn ap_is_mask(a: AP) -> bool { !ap_is_zero(a) && ap_countl_zero(a) + ap_countr_one(a) == (a.w as i64) }
// isShiftedMask()
fn ap_is_shifted_mask(a: AP) -> bool {
    if ap_is_zero(a) { return false; }
    return ap_countl_zero(a) + ap_countr_zero(a) + ap_popcount(a) == (a.w as i64);
}
// isSignMask
fn ap_is_sign_mask(a: AP) -> bool { ap_is_min_signed(a) }

fn ap_ult(a: AP, b: AP) -> bool {
    if a.ix < 0 { return a.lo < b.lo; }
    var k = ap_nw(a.w as i64) - 1;
    while k >= 0 {
        let x = apw[(a.ix as i64) + k];
        let y = apw[(b.ix as i64) + k];
        if x != y { return x < y; }
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
fn ap_ult_u64(a: AP, x: u64) -> bool { a.lo < x && ap_fits_u64(a) }
fn ap_ugt_u64(a: AP, x: u64) -> bool { !ap_fits_u64(a) || a.lo > x }
fn ap_ule_u64(a: AP, x: u64) -> bool { a.lo <= x && ap_fits_u64(a) }
fn ap_uge_u64(a: AP, x: u64) -> bool { !ap_fits_u64(a) || a.lo >= x }
fn ap_sgt_i64(a: AP, x: i64) -> bool { ap_sgt(a, ap_i64(x, a.w as i64)) }
fn ap_slt_i64(a: AP, x: i64) -> bool { ap_slt(a, ap_i64(x, a.w as i64)) }
fn ap_eq_i64(a: AP, x: i64) -> bool { ap_eq(a, ap_i64(x, a.w as i64)) }
// compare (-1, 0, 1)
fn ap_ucmp(a: AP, b: AP) -> i64 { if ap_ult(a, b) { -1 } else if ap_eq(a, b) { 0 } else { 1 } }
fn ap_scmp(a: AP, b: AP) -> i64 { if ap_slt(a, b) { -1 } else if ap_eq(a, b) { 0 } else { 1 } }

fn ap_umin(a: AP, b: AP) -> AP { if ap_ult(b, a) { b } else { a } }
fn ap_umax(a: AP, b: AP) -> AP { if ap_ugt(b, a) { b } else { a } }
fn ap_smin(a: AP, b: AP) -> AP { if ap_slt(b, a) { b } else { a } }
fn ap_smax(a: AP, b: AP) -> AP { if ap_sgt(b, a) { b } else { a } }

fn ap_add(a: AP, b: AP) -> AP {
    let w = a.w as i64;
    if a.ix < 0 { return ap_small(a.lo + b.lo, w); }
    let ix = ap_alloc(w);
    var carry: u64 = 0;
    for k in ap_nw(w) {
        let x = apw[(a.ix as i64) + k];
        let s = x + apw[(b.ix as i64) + k];
        let c1: u64 = if s < x { 1 } else { 0 };
        let s2 = s + carry;
        let c2: u64 = if s2 < s { 1 } else { 0 };
        apw[(ix as i64) + k] = s2;
        carry = c1 + c2;
    }
    return ap_fin(w, ix);
}
fn ap_sub(a: AP, b: AP) -> AP {
    let w = a.w as i64;
    if a.ix < 0 { return ap_small(a.lo - b.lo, w); }
    let ix = ap_alloc(w);
    var borrow: u64 = 0;
    for k in ap_nw(w) {
        let x = apw[(a.ix as i64) + k];
        let y = apw[(b.ix as i64) + k];
        let d = x - y;
        let b1: u64 = if x < y { 1 } else { 0 };
        let d2 = d - borrow;
        let b2: u64 = if d < borrow { 1 } else { 0 };
        apw[(ix as i64) + k] = d2;
        borrow = b1 + b2;
    }
    return ap_fin(w, ix);
}
fn ap_not(a: AP) -> AP {
    let w = a.w as i64;
    if a.ix < 0 { return ap_small(~a.lo, w); }
    let ix = ap_alloc(w);
    for k in ap_nw(w) { apw[(ix as i64) + k] = ~apw[(a.ix as i64) + k]; }
    return ap_fin(w, ix);
}
fn ap_neg(a: AP) -> AP { ap_sub(ap_zero(a.w as i64), a) }
fn ap_inc(a: AP) -> AP { if a.ix < 0 { ap_small(a.lo + 1, a.w as i64) } else { ap_add(a, ap_u64(1, a.w as i64)) } }
fn ap_dec(a: AP) -> AP { if a.ix < 0 { ap_small(a.lo - 1, a.w as i64) } else { ap_sub(a, ap_u64(1, a.w as i64)) } }
fn ap_add_u64(a: AP, x: u64) -> AP { ap_add(a, ap_u64(x, a.w as i64)) }
fn ap_sub_u64(a: AP, x: u64) -> AP { ap_sub(a, ap_u64(x, a.w as i64)) }
fn ap_and(a: AP, b: AP) -> AP {
    let w = a.w as i64;
    if a.ix < 0 { return AP { lo: a.lo & b.lo, w: a.w, ix: -1 }; }
    let ix = ap_alloc(w);
    for k in ap_nw(w) { apw[(ix as i64) + k] = apw[(a.ix as i64) + k] & apw[(b.ix as i64) + k]; }
    return ap_fin(w, ix);
}
fn ap_or(a: AP, b: AP) -> AP {
    let w = a.w as i64;
    if a.ix < 0 { return AP { lo: a.lo | b.lo, w: a.w, ix: -1 }; }
    let ix = ap_alloc(w);
    for k in ap_nw(w) { apw[(ix as i64) + k] = apw[(a.ix as i64) + k] | apw[(b.ix as i64) + k]; }
    return ap_fin(w, ix);
}
fn ap_xor(a: AP, b: AP) -> AP {
    let w = a.w as i64;
    if a.ix < 0 { return AP { lo: a.lo ^ b.lo, w: a.w, ix: -1 }; }
    let ix = ap_alloc(w);
    for k in ap_nw(w) { apw[(ix as i64) + k] = apw[(a.ix as i64) + k] ^ apw[(b.ix as i64) + k]; }
    return ap_fin(w, ix);
}
// isSubsetOf: a & ~b == 0
fn ap_is_subset_of(a: AP, b: AP) -> bool {
    if a.ix < 0 { return (a.lo & ~b.lo) == 0; }
    for k in ap_nw(a.w as i64) { if (apw[(a.ix as i64) + k] & ~apw[(b.ix as i64) + k]) != 0 { return false; } }
    return true;
}
// intersects: a & b != 0
fn ap_intersects(a: AP, b: AP) -> bool {
    if a.ix < 0 { return (a.lo & b.lo) != 0; }
    for k in ap_nw(a.w as i64) { if (apw[(a.ix as i64) + k] & apw[(b.ix as i64) + k]) != 0 { return true; } }
    return false;
}

fn ap_shl(a: AP, k: i64) -> AP {
    let w = a.w as i64;
    if k <= 0 { return a; }
    if k >= w { return ap_zero(w); }
    if a.ix < 0 { return ap_small(a.lo << k, w); }
    let ix = ap_alloc(w);
    let n = ap_nw(w);
    let ws = k / 64;
    let bs = k % 64;
    var i = n - 1;
    while i >= ws {
        var x = apw[(a.ix as i64) + i - ws] << bs;
        if bs > 0 && i - ws - 1 >= 0 { x = x | (apw[(a.ix as i64) + i - ws - 1] >> (64 - bs)); }
        apw[(ix as i64) + i] = x;
        i--;
    }
    return ap_fin(w, ix);
}
fn ap_lshr(a: AP, k: i64) -> AP {
    let w = a.w as i64;
    if k <= 0 { return a; }
    if k >= w { return ap_zero(w); }
    if a.ix < 0 { return AP { lo: a.lo >> k, w: a.w, ix: -1 }; }
    let ix = ap_alloc(w);
    let n = ap_nw(w);
    let ws = k / 64;
    let bs = k % 64;
    var i: i64 = 0;
    while i + ws < n {
        var x = apw[(a.ix as i64) + i + ws] >> bs;
        if bs > 0 && i + ws + 1 < n { x = x | (apw[(a.ix as i64) + i + ws + 1] << (64 - bs)); }
        apw[(ix as i64) + i] = x;
        i++;
    }
    return ap_fin(w, ix);
}
fn ap_ashr(a: AP, k: i64) -> AP {
    let w = a.w as i64;
    if !ap_is_neg(a) { return ap_lshr(a, k); }
    if k >= w { return ap_ones(w); }
    if k <= 0 { return a; }
    if a.ix < 0 { return ap_small(((ap_sext64(a)) >> k) as! u64, w); }
    return ap_or(ap_lshr(a, k), ap_high_bits(w, k));
}
// shifts by an APInt amount (getLimitedValue(BitWidth))
fn ap_shl_ap(a: AP, s: AP) -> AP { ap_shl(a, ap_limited(s, a.w as u64) as i64) }
fn ap_lshr_ap(a: AP, s: AP) -> AP { ap_lshr(a, ap_limited(s, a.w as u64) as i64) }
fn ap_ashr_ap(a: AP, s: AP) -> AP { ap_ashr(a, ap_limited(s, a.w as u64) as i64) }
// rotl/rotr (amount taken modulo the width, like APInt::rotl(unsigned) after rotateModulo)
fn ap_rotl(a: AP, k0: i64) -> AP {
    let w = a.w as i64;
    let k = k0 % w;
    if k == 0 { return a; }
    return ap_or(ap_shl(a, k), ap_lshr(a, w - k));
}
fn ap_rotr(a: AP, k0: i64) -> AP {
    let w = a.w as i64;
    let k = k0 % w;
    if k == 0 { return a; }
    return ap_or(ap_lshr(a, k), ap_shl(a, w - k));
}
// rotateModulo: an APInt amount modulo the width
fn ap_rot_amount(a: AP, s: AP) -> i64 {
    let w = a.w as i64;
    if (s.w as i64) <= 64 { return (s.lo % (w as u64)) as i64; }
    return ap_urem(s, ap_u64(w as u64, s.w as i64)).lo as i64;
}
fn ap_rotl_ap(a: AP, s: AP) -> AP { ap_rotl(a, ap_rot_amount(a, s)) }
fn ap_rotr_ap(a: AP, s: AP) -> AP { ap_rotr(a, ap_rot_amount(a, s)) }

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
    let w = a.w as i64;
    if a.ix < 0 { return ap_small(a.lo * b.lo, w); }
    let n = ap_nw(w);
    let ix = ap_alloc(w);
    for i in n {
        let x = apw[(a.ix as i64) + i];
        if x == 0 { continue; }
        var carry: u64 = 0;
        var j: i64 = 0;
        while i + j < n {
            let lo, hi = ap_mul64(x, apw[(b.ix as i64) + j]);
            let p = (ix as i64) + i + j;
            let s = apw[p] + lo;
            let c1: u64 = if s < lo { 1 } else { 0 };
            let s2 = s + carry;
            let c2: u64 = if s2 < s { 1 } else { 0 };
            apw[p] = s2;
            carry = hi + c1 + c2;
            j++;
        }
    }
    return ap_fin(w, ix);
}

// unsigned division (b != 0), APInt::udivrem. Shift-subtract on scratch words in the pool: the quotient
// and remainder are unique, so the algorithm doesn't matter for the result.
fn ap_udivrem(a: AP, b: AP) -> AP, AP {
    let w = a.w as i64;
    if ap_is_zero(b) { fatal("APInt: division by zero"); }
    if a.ix < 0 { return ap_small(a.lo / b.lo, w), ap_small(a.lo % b.lo, w); }
    if ap_fits_u64(a) && ap_fits_u64(b) { return ap_u64(a.lo / b.lo, w), ap_u64(a.lo % b.lo, w); }
    if ap_ult(a, b) { return ap_zero(w), a; }
    let n = ap_nw(w);
    let qx = ap_alloc(w);
    let rx = apw.len;              // n + 1 scratch words for the running remainder
    apw.resize(rx + n + 1, 0);
    let ax = a.ix as i64;
    let bx = b.ix as i64;
    var k = ap_active_bits(a) - 1;
    while k >= 0 {
        // r = (r << 1) | bit k of a
        var carry: u64 = (apw[ax + k / 64] >> (k % 64)) & 1;
        for i in n + 1 {
            let x = apw[rx + i];
            apw[rx + i] = (x << 1) | carry;
            carry = x >> 63;
        }
        // r >= b ?
        var ge = apw[rx + n] != 0;
        if !ge {
            ge = true;
            var i = n - 1;
            while i >= 0 {
                let x = apw[rx + i];
                let y = apw[bx + i];
                if x != y { ge = x > y; break; }
                i--;
            }
        }
        if ge {
            var borrow: u64 = 0;
            for i in n + 1 {
                let x = apw[rx + i];
                let y = if i < n { apw[bx + i] } else { 0 };
                let d = x - y;
                let b1: u64 = if x < y { 1 } else { 0 };
                let d2 = d - borrow;
                let b2: u64 = if d < borrow { 1 } else { 0 };
                apw[rx + i] = d2;
                borrow = b1 + b2;
            }
            let qp = (qx as i64) + k / 64;
            apw[qp] = apw[qp] | ((1 as u64) << (k % 64));
        }
        k--;
    }
    let rix = ap_alloc(w);
    for i in n { apw[(rix as i64) + i] = apw[rx + i]; }
    return ap_fin(w, qx), ap_fin(w, rix);
}
fn ap_udiv(a: AP, b: AP) -> AP { let q, r = ap_udivrem(a, b); return q; }
fn ap_urem(a: AP, b: AP) -> AP { let q, r = ap_udivrem(a, b); return r; }
fn ap_abs(a: AP) -> AP { if ap_is_neg(a) { ap_neg(a) } else { a } }
// sdivrem: truncating quotient, remainder with the sign of the dividend
fn ap_sdivrem(a: AP, b: AP) -> AP, AP {
    let na = ap_is_neg(a);
    let nb = ap_is_neg(b);
    let q, r = ap_udivrem(ap_abs(a), ap_abs(b));
    return if na != nb { ap_neg(q) } else { q }, if na { ap_neg(r) } else { r };
}
fn ap_sdiv(a: AP, b: AP) -> AP { let q, r = ap_sdivrem(a, b); return q; }
fn ap_srem(a: AP, b: AP) -> AP { let q, r = ap_sdivrem(a, b); return r; }
// APIntOps::RoundingUDiv
fn ap_rounding_udiv(a: AP, b: AP, up: bool) -> AP {
    let q, r = ap_udivrem(a, b);
    if up && !ap_is_zero(r) { return ap_inc(q); }
    return q;
}
// APIntOps::RoundingSDiv (UP / DOWN)
fn ap_rounding_sdiv(a: AP, b: AP, up: bool) -> AP {
    let q, r = ap_sdivrem(a, b);
    if ap_is_zero(r) { return q; }
    // a and b have the same sign iff the quotient is non-negative (when r != 0)
    let pos = ap_is_neg(a) == ap_is_neg(b);
    if up { return if pos { ap_inc(q) } else { q }; }
    return if pos { q } else { ap_dec(q) };
}
// APIntOps::GreatestCommonDivisor (Stein's algorithm in LLVM; the gcd is unique)
fn ap_gcd(a0: AP, b0: AP) -> AP {
    var a = a0;
    var b = b0;
    while !ap_is_zero(b) { let r = ap_urem(a, b); a = b; b = r; }
    return a;
}
// APIntOps::abdu / abds
fn ap_abdu(a: AP, b: AP) -> AP { if ap_uge(a, b) { ap_sub(a, b) } else { ap_sub(b, a) } }
fn ap_abds(a: AP, b: AP) -> AP { if ap_sge(a, b) { ap_sub(a, b) } else { ap_sub(b, a) } }
// APIntOps::avgFloorU/S, avgCeilU/S
fn ap_avg_floor_u(a: AP, b: AP) -> AP { ap_add(ap_and(a, b), ap_lshr(ap_xor(a, b), 1)) }
fn ap_avg_floor_s(a: AP, b: AP) -> AP { ap_add(ap_and(a, b), ap_ashr(ap_xor(a, b), 1)) }
fn ap_avg_ceil_u(a: AP, b: AP) -> AP { ap_sub(ap_or(a, b), ap_lshr(ap_xor(a, b), 1)) }
fn ap_avg_ceil_s(a: AP, b: AP) -> AP { ap_sub(ap_or(a, b), ap_ashr(ap_xor(a, b), 1)) }
// APIntOps::mulhu / mulhs: the high half of the double-width product
fn ap_mulhu(a: AP, b: AP) -> AP {
    let w = a.w as i64;
    return ap_trunc(ap_lshr(ap_mul(ap_zext(a, 2 * w), ap_zext(b, 2 * w)), w), w);
}
fn ap_mulhs(a: AP, b: AP) -> AP {
    let w = a.w as i64;
    return ap_trunc(ap_lshr(ap_mul(ap_sext(a, 2 * w), ap_sext(b, 2 * w)), w), w);
}

fn ap_countl_zero(a: AP) -> i64 {
    let w = a.w as i64;
    if a.ix < 0 { return if a.lo == 0 { w } else { clz(a.lo) - (64 - w) }; }
    let n = ap_nw(w);
    var k = n - 1;
    var cnt: i64 = 0;
    while k >= 0 {
        let x = apw[(a.ix as i64) + k];
        if x != 0 { cnt = cnt + clz(x); break; }
        cnt = cnt + 64;
        k--;
    }
    return cnt - (64 * n - w);
}
fn ap_countl_one(a: AP) -> i64 {
    let w = a.w as i64;
    if a.ix < 0 { let x = ~(a.lo << (64 - w)); return if x == 0 { w } else { clz(x) }; }
    return ap_countl_zero(ap_not(a));
}
fn ap_countr_zero(a: AP) -> i64 {
    let w = a.w as i64;
    if a.ix < 0 { return if a.lo == 0 { w } else { ctz(a.lo) }; }
    for k in ap_nw(w) {
        let x = apw[(a.ix as i64) + k];
        if x != 0 { let c = k * 64 + ctz(x); return if c > w { w } else { c }; }
    }
    return w;
}
fn ap_countr_one(a: AP) -> i64 {
    let w = a.w as i64;
    if a.ix < 0 { let x = ~a.lo; let c = if x == 0 { 64 } else { ctz(x) }; return if c > w { w } else { c }; }
    for k in ap_nw(w) {
        let x = ~apw[(a.ix as i64) + k];
        if x != 0 { let c = k * 64 + ctz(x); return if c > w { w } else { c }; }
    }
    return w;
}
fn ap_popcount(a: AP) -> i64 {
    if a.ix < 0 { return popcount(a.lo); }
    var c: i64 = 0;
    for k in ap_nw(a.w as i64) { c = c + popcount(apw[(a.ix as i64) + k]); }
    return c;
}
fn ap_active_bits(a: AP) -> i64 { (a.w as i64) - ap_countl_zero(a) }
fn ap_num_sign_bits(a: AP) -> i64 { if ap_is_neg(a) { ap_countl_one(a) } else { ap_countl_zero(a) } }
// getSignificantBits
fn ap_sig_bits(a: AP) -> i64 { (a.w as i64) - ap_num_sign_bits(a) + 1 }
// logBase2 / exactLogBase2 (-1 when not a power of two) / ceilLogBase2
fn ap_log2(a: AP) -> i64 { ap_active_bits(a) - 1 }
fn ap_exact_log2(a: AP) -> i64 { if ap_is_pow2(a) { ap_log2(a) } else { -1 } }
fn ap_ceil_log2(a: AP) -> i64 { let t = ap_dec(a); return ap_active_bits(t); }

fn ap_zext(a: AP, w: i64) -> AP {
    let ow = a.w as i64;
    if w == ow { return a; }
    if w <= 64 { return AP { lo: a.lo, w: w as i32, ix: -1 }; }
    let ix = ap_alloc(w);
    for k in ap_nw(ow) { apw[(ix as i64) + k] = ap_word(a, k); }
    return ap_fin(w, ix);
}
fn ap_trunc(a: AP, w: i64) -> AP {
    if w == (a.w as i64) { return a; }
    if w <= 64 { return ap_small(a.lo, w); }
    let ix = ap_alloc(w);
    for k in ap_nw(w) { apw[(ix as i64) + k] = apw[(a.ix as i64) + k]; }
    return ap_fin(w, ix);
}
fn ap_sext(a: AP, w: i64) -> AP {
    let ow = a.w as i64;
    if w == ow { return a; }
    if w <= 64 { return ap_small(ap_sext64(a) as! u64, w); }
    let ix = ap_alloc(w);
    for k in ap_nw(w) { apw[(ix as i64) + k] = ap_word_sx(a, k); }
    return ap_fin(w, ix);
}
fn ap_zext_or_trunc(a: AP, w: i64) -> AP { if w < (a.w as i64) { ap_trunc(a, w) } else { ap_zext(a, w) } }
fn ap_sext_or_trunc(a: AP, w: i64) -> AP { if w < (a.w as i64) { ap_trunc(a, w) } else { ap_sext(a, w) } }
// getHiBits(n): the top n bits, shifted down
fn ap_hi_bits(a: AP, n: i64) -> AP { ap_lshr(a, (a.w as i64) - n) }
// getLoBits(n): the low n bits
fn ap_lo_bits(a: AP, n: i64) -> AP { ap_and(a, ap_low_bits(a.w as i64, n)) }
fn ap_clear_low_bits(a: AP, n: i64) -> AP { ap_and(a, ap_bits_from(a.w as i64, n)) }
fn ap_clear_high_bits(a: AP, n: i64) -> AP { ap_and(a, ap_low_bits(a.w as i64, (a.w as i64) - n)) }
// extractBits(n, lo)
fn ap_extract_bits(a: AP, n: i64, lo: i64) -> AP { ap_trunc(ap_lshr(a, lo), n) }
// insertBits(sub, lo)
fn ap_insert_bits(a: AP, sub: AP, lo: i64) -> AP {
    let w = a.w as i64;
    let n = sub.w as i64;
    let mask = ap_shl(ap_low_bits(w, n), lo);
    return ap_or(ap_and(a, ap_not(mask)), ap_shl(ap_zext(sub, w), lo));
}
// concat(lo): this in the high bits, lo in the low bits
fn ap_concat(hi: AP, lo: AP) -> AP {
    let w = (hi.w as i64) + (lo.w as i64);
    return ap_or(ap_shl(ap_zext(hi, w), lo.w as i64), ap_zext(lo, w));
}

fn ap_byte_swap(a: AP) -> AP {
    let w = a.w as i64;
    if w % 16 != 0 { fatal("APInt::byteSwap: width is not a multiple of 16"); }
    let nb = w / 8;
    if a.ix < 0 {
        var r: u64 = 0;
        for b in nb { r = r | (((a.lo >> (8 * b)) & 0xFF) << (8 * (nb - 1 - b))); }
        return ap_small(r, w);
    }
    let ix = ap_alloc(w);
    for b in nb {
        let byte = (apw[(a.ix as i64) + b / 8] >> (8 * (b % 8))) & 0xFF;
        let d = nb - 1 - b;
        let p = (ix as i64) + d / 8;
        apw[p] = apw[p] | (byte << (8 * (d % 8)));
    }
    return ap_fin(w, ix);
}
fn ap_reverse_bits(a: AP) -> AP {
    let w = a.w as i64;
    if a.ix < 0 {
        var r: u64 = 0;
        for b in w { if ((a.lo >> b) & 1) != 0 { r = r | ((1 as u64) << (w - 1 - b)); } }
        return ap_small(r, w);
    }
    let ix = ap_alloc(w);
    for b in w {
        if ((apw[(a.ix as i64) + b / 64] >> (b % 64)) & 1) != 0 {
            let d = w - 1 - b;
            let p = (ix as i64) + d / 64;
            apw[p] = apw[p] | ((1 as u64) << (d % 64));
        }
    }
    return ap_fin(w, ix);
}

// overflow-detecting and saturating operations (APInt.cpp *_ov, *_sat)
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
// APInt::umul_ov
fn ap_umul_ov(a: AP, b: AP) -> AP, bool {
    let w = a.w as i64;
    if w <= 64 {
        let lo, hi = ap_mul64(a.lo, b.lo);
        let r = ap_small(lo, w);
        let ov = if w == 64 { hi != 0 } else { hi != 0 || (lo >> w) != 0 };
        return r, ov;
    }
    if ap_countl_zero(a) + ap_countl_zero(b) + 2 <= w { return ap_mul(a, b), true; }
    var r = ap_mul(ap_lshr(a, 1), b);
    var ov = ap_is_neg(r);
    r = ap_shl(r, 1);
    if ap_get_bit(a, 0) {
        r = ap_add(r, b);
        if ap_ult(r, b) { ov = true; }
    }
    return r, ov;
}
fn ap_smul_ov(a: AP, b: AP) -> AP, bool {
    let r = ap_mul(a, b);
    if ap_is_zero(a) || ap_is_zero(b) { return r, false; }
    // APInt::smul_ov: Overflow = Res.sdiv(RHS) != *this || (isMinSignedValue() && RHS.isAllOnes())
    let ov = !ap_eq(ap_sdiv(r, b), a) || (ap_is_min_signed(a) && ap_is_all_ones(b));
    return r, ov;
}
// sdiv_ov: overflow iff MIN / -1
fn ap_sdiv_ov(a: AP, b: AP) -> AP, bool {
    let ov = ap_is_min_signed(a) && ap_is_all_ones(b);
    return ap_sdiv(a, b), ov;
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
    if w <= 64 { return ap_small(cint_lo(v), w); }
    if w <= 128 {
        let ix = ap_alloc(w);
        apw[ix as i64] = cint_lo(v);
        apw[(ix as i64) + 1] = cint_hi(v);
        return ap_fin(w, ix);
    }
    let c = csts[vals[v].sub];
    let ix = ap_alloc(w);
    for k in ap_nw(w) { apw[(ix as i64) + k] = words[(c.ext as i64) + k]; }
    return ap_fin(w, ix);
}
// ConstantInt::get(Ty, APInt) (a splat for vector types)
fn ap_to_cint(ty: i32, a: AP) -> i32 {
    let st = ty_scalar(ty);
    let w = a.w as i64;
    if ty_bits(st) != w { fatal(str("APInt: ConstantInt::get with an i", w, " value for i", ty_bits(st))); }
    var c: i32 = -1;
    if w <= 128 { c = c_int_words(st, ap_word(a, 0), ap_word(a, 1)); }
    else {
        var ws: u64[>..] = [];
        for k in ap_nw(w) { ws.push(ap_word(a, k)); }
        c = c_int_wide(st, ws);
    }
    if ty_is_vector(ty) { return c_splat(ty, c); }
    return c;
}

// APInt::toString(Radix 10, Signed)
fn ap_format(out: u8[>..]&, a0: AP, signed: bool) {
    var a = a0;
    if signed && ap_is_neg(a) { out.push('-'); a = ap_neg(a); }
    if ap_is_zero(a) { out.push('0'); return; }
    let m = ap_mark();
    let w = a.w as i64;
    var digs: u8[>..] = [];
    if w <= 64 {
        var x = a.lo;
        while x != 0 { digs.push((48 + x % 10) as! u8); x = x / 10; }
    } else {
        // divide by 10^19 at a time
        let big = ap_u64(10000000000000000000, w);
        while !ap_is_zero(a) {
            let q, r = ap_udivrem(a, big);
            var x = r.lo;
            if ap_is_zero(q) {
                while x != 0 { digs.push((48 + x % 10) as! u8); x = x / 10; }
            } else {
                for i in 19 { digs.push((48 + x % 10) as! u8); x = x / 10; }
            }
            a = q;
        }
    }
    ap_release(m);
    var k = digs.len - 1;
    while k >= 0 { out.push(digs[k]); k--; }
}
fn ap_format_dec(out: u8[>..]&, a: AP) { ap_format(out, a, false); }

// ICmpInst::compare(a, b, pred) for the integer predicates (32 eq .. 41 sle)
fn ap_icmp(a: AP, b: AP, p: i64) -> bool {
    return match p {
        32 => ap_eq(a, b), 33 => !ap_eq(a, b), 34 => ap_ugt(a, b), 35 => ap_uge(a, b), 36 => ap_ult(a, b), 37 => ap_ule(a, b),
        38 => ap_sgt(a, b), 39 => ap_sge(a, b), 40 => ap_slt(a, b), _ => ap_sle(a, b),
    };
}
// APIntOps::clmul: carry-less product, truncated
fn ap_clmul(a: AP, b: AP) -> AP {
    var r = ap_zero(a.w as i64);
    for i in a.w as i64 { if ap_get_bit(b, i) { r = ap_xor(r, ap_shl(a, i)); } }
    return r;
}
// fshl/fshr by a shift amount already reduced modulo the width
fn ap_fshl(a: AP, b: AP, sh: i64) -> AP {
    if sh == 0 { return a; }
    return ap_or(ap_shl(a, sh), ap_lshr(b, (a.w as i64) - sh));
}
fn ap_fshr(a: AP, b: AP, sh: i64) -> AP {
    if sh == 0 { return b; }
    return ap_or(ap_shl(a, (a.w as i64) - sh), ap_lshr(b, sh));
}
// APSInt::isSameValue for two unsigned values of possibly different widths
fn ap_same_value_u(a: AP, b: AP) -> bool {
    let w = if a.w > b.w { a.w as i64 } else { b.w as i64 };
    return ap_eq(ap_zext(a, w), ap_zext(b, w));
}
