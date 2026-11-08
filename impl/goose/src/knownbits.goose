// KnownBits (llvm/lib/Support/KnownBits.cpp) and computeKnownBits (llvm/lib/Analysis/ValueTracking.cpp),
// for integers of at most 64 bits and fixed vectors of at most 64 elements.
//
// Coverage policy: every case of LLVM's computeKnownBits is either ported, or detected and reported with
// fatal() ("not ported"), so a less precise answer can never silently produce different IR. Cases LLVM
// itself answers with "unknown" (unlisted opcodes/intrinsics) are unknown here too. Not ported: integers
// wider than 64 bits, bitcasts between vector shapes, vscale,
// target intrinsics. Assumptions: assume.goose.
import std;
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
import crange;
import constfold;
import cfold;
import instsimplify;
import assume;
import fpclass;
import apfloat;

let MAX_ANALYSIS_DEPTH = 6;   // MaxAnalysisRecursionDepth

struct KB { z: u64, o: u64, w: i32 }

fn wmask(w: i64) -> u64 { if w >= 64 { 0xFFFFFFFFFFFFFFFF } else { ((1 as u64) << w) - 1 } }
fn sbit(w: i64) -> u64 { (1 as u64) << (w - 1) }
fn low_bits(n: i64) -> u64 { if n <= 0 { 0 } else { wmask(n) } }
// bits [lo, hi) set
fn bits_range(lo: i64, hi: i64) -> u64 { if hi <= lo { 0 } else { low_bits(hi) & ~low_bits(lo) } }
fn high_bits(w: i64, n: i64) -> u64 { if n <= 0 { 0 } else { bits_range(w - n, w) } }

fn kb_unknown(w: i64) -> KB { KB { z: 0, o: 0, w: w as i32 } }
fn kb_const(c: u64, w: i64) -> KB { let m = wmask(w); KB { z: ~c & m, o: c & m, w: w as i32 } }
fn kb_all_zero(w: i64) -> KB { KB { z: wmask(w), o: 0, w: w as i32 } }
fn kb_all_conflict(w: i64) -> KB { KB { z: wmask(w), o: wmask(w), w: w as i32 } }
fn kb_is_unknown(k: KB) -> bool { k.z == 0 && k.o == 0 }
fn kb_has_conflict(k: KB) -> bool { (k.z & k.o) != 0 }
fn kb_is_constant(k: KB) -> bool { (k.z | k.o) == wmask(k.w as i64) && !kb_has_conflict(k) }
fn kb_and(a: KB, b: KB) -> KB { KB { z: a.z | b.z, o: a.o & b.o, w: a.w } }
fn kb_or(a: KB, b: KB) -> KB { KB { z: a.z & b.z, o: a.o | b.o, w: a.w } }
fn kb_xor(a: KB, b: KB) -> KB { KB { z: (a.z & b.z) | (a.o & b.o), o: (a.z & b.o) | (a.o & b.z), w: a.w } }
fn kb_intersect(a: KB, b: KB) -> KB { KB { z: a.z & b.z, o: a.o & b.o, w: a.w } }
fn kb_union(a: KB, b: KB) -> KB { KB { z: a.z | b.z, o: a.o | b.o, w: a.w } }
fn kb_max(k: KB) -> u64 { ~k.z & wmask(k.w as i64) }
fn kb_min(k: KB) -> u64 { k.o }
fn kb_is_nonneg(k: KB) -> bool { (k.z & sbit(k.w as i64)) != 0 }
fn kb_is_neg(k: KB) -> bool { (k.o & sbit(k.w as i64)) != 0 }
fn kb_is_nonzero(k: KB) -> bool { k.o != 0 }
fn kb_make_nonneg(k: KB) -> KB { KB { z: k.z | sbit(k.w as i64), o: k.o, w: k.w } }
fn kb_make_neg(k: KB) -> KB { KB { z: k.z, o: k.o | sbit(k.w as i64), w: k.w } }

// countr_one / countl_one of a w-bit value
fn ctz_w(x: u64, w: i64) -> i64 { let c = ctz(x); if c > w { w } else { c } }
fn clz_w(x: u64, w: i64) -> i64 { let v = x & wmask(w); if v == 0 { w } else { clz(v) - (64 - w) } }
fn cto_w(x: u64, w: i64) -> i64 { ctz_w(~x, w) }
fn clo_w(x: u64, w: i64) -> i64 { clz_w(~x & wmask(w), w) }

fn kb_min_tz(k: KB) -> i64 { cto_w(k.z, k.w as i64) }
fn kb_max_tz(k: KB) -> i64 { ctz_w(k.o, k.w as i64) }
fn kb_min_lz(k: KB) -> i64 { clo_w(k.z, k.w as i64) }
fn kb_max_lz(k: KB) -> i64 { clz_w(k.o, k.w as i64) }
fn kb_min_lo(k: KB) -> i64 { clo_w(k.o, k.w as i64) }
fn kb_max_lo(k: KB) -> i64 { clz_w(k.z, k.w as i64) }
fn kb_max_pop(k: KB) -> i64 { popcount(kb_max(k)) }

// signed min/max values as w-bit patterns
fn kb_smin(k: KB) -> u64 { let s = sbit(k.w as i64); if (k.z & s) != 0 { k.o } else { k.o | s } }
fn kb_smax(k: KB) -> u64 { let s = sbit(k.w as i64); let mx = kb_max(k); if (k.o & s) != 0 { mx } else { mx & ~s } }
fn sext_w(x: u64, w: i64) -> i64 { if w >= 64 { x as! i64 } else { ((x << (64 - w)) as! i64) >> (64 - w) } }

fn kb_trunc(k: KB, w: i64) -> KB { let m = wmask(w); KB { z: k.z & m, o: k.o & m, w: w as i32 } }
fn kb_zext(k: KB, w: i64) -> KB { KB { z: k.z | bits_range(k.w as i64, w), o: k.o, w: w as i32 } }
fn kb_anyext(k: KB, w: i64) -> KB { KB { z: k.z, o: k.o, w: w as i32 } }
fn kb_zext_or_trunc(k: KB, w: i64) -> KB { if w > k.w as i64 { kb_zext(k, w) } else { kb_trunc(k, w) } }
fn kb_anyext_or_trunc(k: KB, w: i64) -> KB { if w > k.w as i64 { kb_anyext(k, w) } else { kb_trunc(k, w) } }
fn kb_sext(k: KB, w: i64) -> KB {
    let ow = k.w as i64;
    let ext = bits_range(ow, w);
    var r = KB { z: k.z, o: k.o, w: w as i32 };
    if (k.z & sbit(ow)) != 0 { r.z |= ext; }
    if (k.o & sbit(ow)) != 0 { r.o |= ext; }
    return r;
}

fn byte_swap_w(x: u64, w: i64) -> u64 {
    var r: u64 = 0;
    for b in w / 8 { r |= ((x >> (8 * b)) & 0xFF) << (8 * (w / 8 - 1 - b)); }
    return r;
}
fn reverse_bits_w(x: u64, w: i64) -> u64 {
    var r: u64 = 0;
    for b in w { if ((x >> b) & 1) != 0 { r |= (1 as u64) << (w - 1 - b); } }
    return r;
}

// computeForAddCarry
fn kb_add_carry(l: KB, r: KB, carry_zero: bool, carry_one: bool) -> KB {
    let w = l.w as i64;
    let m = wmask(w);
    let psz = (kb_max(l) + kb_max(r) + (if carry_zero { 0 } else { 1 })) & m;
    let pso = (kb_min(l) + kb_min(r) + (if carry_one { 1 } else { 0 })) & m;
    let ckz = ~(psz ^ l.z ^ r.z) & m;
    let cko = (pso ^ l.o ^ r.o) & m;
    let known = (l.z | l.o) & (r.z | r.o) & (ckz | cko);
    return KB { z: ~psz & known & m, o: pso & known, w: l.w };
}

fn uadd_sat_w(a: u64, b: u64, w: i64) -> u64 { let m = wmask(w); let s = (a + b) & m; if s < a { m } else { s } }
fn usub_sat_w(a: u64, b: u64) -> u64 { if a < b { 0 } else { a - b } }
fn sadd_sat_w(a: u64, b: u64, w: i64) -> u64 {
    let x = sext_w(a, w);
    let y = sext_w(b, w);
    let mx = sext_w(sbit(w) - 1, w);
    let mn = -mx - 1;
    var s: i64 = 0;
    if w == 64 {
        let r = (x as! u64) + (y as! u64);
        let rs = r as! i64;
        if x >= 0 && y >= 0 && rs < 0 { return sbit(w) - 1; }
        if x < 0 && y < 0 && rs >= 0 { return sbit(w); }
        return r;
    }
    s = x + y;
    if s > mx { s = mx; }
    if s < mn { s = mn; }
    return (s as! u64) & wmask(w);
}
fn ssub_sat_w(a: u64, b: u64, w: i64) -> u64 {
    let x = sext_w(a, w);
    let y = sext_w(b, w);
    if w == 64 {
        let r = (x as! u64) - (y as! u64);
        let rs = r as! i64;
        if x >= 0 && y < 0 && rs < 0 { return sbit(w) - 1; }
        if x < 0 && y >= 0 && rs >= 0 { return sbit(w); }
        return r;
    }
    let mx = sext_w(sbit(w) - 1, w);
    let mn = -mx - 1;
    var s = x - y;
    if s > mx { s = mx; }
    if s < mn { s = mn; }
    return (s as! u64) & wmask(w);
}

// KnownBits::computeForAddSub
fn kb_add_sub(add: bool, nsw: bool, nuw: bool, l: KB, r: KB) -> KB {
    let w = l.w as i64;
    var out = kb_unknown(w);
    if kb_is_unknown(l) && kb_is_unknown(r) { return out; }
    if !kb_is_unknown(l) && !kb_is_unknown(r) {
        if add { out = kb_add_carry(l, r, true, false); }
        else { out = kb_add_carry(l, KB { z: r.o, o: r.z, w: r.w }, false, true); }
    }
    if nuw {
        if add {
            let minv = uadd_sat_w(kb_min(l), kb_min(r), w);
            if nsw {
                let nb = clo_w(minv & wmask(w - 1), w - 1);
                out.o |= bits_range(w - 1 - nb, w - 1);
            }
            out.o |= high_bits(w, clo_w(minv, w));
        } else {
            let maxv = usub_sat_w(kb_max(l), kb_min(r));
            if nsw {
                let nb = clz_w(maxv & wmask(w - 1), w - 1);
                out.z |= bits_range(w - 1 - nb, w - 1);
            }
            out.z |= high_bits(w, clz_w(maxv, w));
        }
    }
    if nsw {
        var minv: u64 = 0;
        var maxv: u64 = 0;
        if add {
            minv = sadd_sat_w(kb_smin(l), kb_smin(r), w);
            maxv = sadd_sat_w(kb_smax(l), kb_smax(r), w);
        } else {
            minv = ssub_sat_w(kb_smin(l), kb_smax(r), w);
            maxv = ssub_sat_w(kb_smax(l), kb_smin(r), w);
        }
        if (minv & sbit(w)) == 0 {
            let nb = clo_w(minv & wmask(w - 1), w - 1);
            out.o |= bits_range(w - 1 - nb, w - 1);
            out.z |= sbit(w);
        }
        if (maxv & sbit(w)) != 0 {
            let nb = clz_w(maxv & wmask(w - 1), w - 1);
            out.z |= bits_range(w - 1 - nb, w - 1);
            out.o |= sbit(w);
        }
    }
    if kb_has_conflict(out) { out = kb_all_zero(w); }
    return out;
}

// KnownBits::mul
fn kb_mul(l: KB, r: KB, self_mul: bool) -> KB {
    let w = l.w as i64;
    let m = wmask(w);
    let ul = kb_max(l);
    let ur = kb_max(r);
    // umul_ov
    var ovf = false;
    var prod: u64 = 0;
    if ul != 0 && ur != 0 {
        let hi_bits = (64 - clz(ul)) + (64 - clz(ur));
        if hi_bits > 65 { ovf = true; }
        else {
            prod = ul * ur;
            if ul != 0 && prod / ul != ur { ovf = true; }
            if (prod & ~m) != 0 { ovf = true; }
        }
    }
    let lead_z = if ovf { 0 } else { clz_w(prod, w) };
    let tbl = cto_w(l.z | l.o, w);
    let tbr = cto_w(r.z | r.o, w);
    let tzl = kb_min_tz(l);
    let tzr = kb_min_tz(r);
    let tz = tzl + tzr;
    let smallest = min(tbl - tzl, tbr - tzr);
    let rbk = min(smallest + tz, w);
    let bottom = (l.o * r.o) & m;
    var res = kb_unknown(w);
    res.z = high_bits(w, lead_z);
    res.z |= ~bottom & low_bits(rbk);
    res.o = bottom & low_bits(rbk);
    if self_mul {
        let t1 = 2 * tzl + 1;
        if t1 < w { res.z |= (1 as u64) << t1; }
        if tzl < w && ((l.o >> tzl) & 1) != 0 {
            let t2 = t1 + 1;
            if t2 < w { res.z |= (1 as u64) << t2; }
        }
    }
    return res;
}

fn is_pow2_w(w: i64) -> bool { w > 0 && (w & (w - 1)) == 0 }
fn limited(v: u64, lim: i64) -> i64 { if v > lim as u64 { lim } else { v as i64 } }

// getMaxShiftAmount
fn max_shift_amount(maxv: u64, aw: i64, w: i64) -> i64 {
    if is_pow2_w(w) {
        let lg = ilog2(w);
        let nb = min(lg, aw);
        return (maxv & low_bits(nb)) as i64;
    }
    return limited(maxv, w - 1);
}

fn kb_shl_const(l: KB, sa: i64, nuw: bool, nsw: bool) -> KB {
    let w = l.w as i64;
    let m = wmask(w);
    let zo = if sa == 0 { false } else { (l.z & high_bits(w, sa)) != 0 };
    let oo = if sa == 0 { false } else { (l.o & high_bits(w, sa)) != 0 };
    var k = KB { z: ((l.z << sa) & m) | low_bits(sa), o: (l.o << sa) & m, w: l.w };
    if nsw {
        var szo = zo;
        if nuw && sa != 0 { szo = true; }
        if szo { k = kb_make_nonneg(k); } else if oo { k = kb_make_neg(k); }
    }
    return k;
}

// KnownBits::shl
fn kb_shl(l: KB, r: KB, nuw: bool, nsw: bool, sa_nonzero: bool) -> KB {
    let w = l.w as i64;
    var known = kb_unknown(w);
    var min_sa = limited(kb_min(r), w);
    if min_sa == 0 && sa_nonzero { min_sa = 1; }
    if kb_is_unknown(l) {
        known.z |= low_bits(min_sa);
        if nuw && nsw && min_sa != 0 { known = kb_make_nonneg(known); }
        return known;
    }
    var max_sa = max_shift_amount(kb_max(r), r.w as i64, w);
    if nuw && nsw { max_sa = min(max_sa, kb_max_lz(l) - 1); }
    if nuw { max_sa = min(max_sa, kb_max_lz(l)); }
    if nsw { max_sa = min(max_sa, max(kb_max_lz(l), kb_max_lo(l)) - 1); }
    if min_sa == 0 && max_sa == w - 1 && is_pow2_w(w) {
        known.z |= low_bits(kb_min_tz(l));
        if kb_is_constant(l) && l.o == wmask(w) { known.o |= sbit(w); }
        if nsw {
            if kb_is_nonneg(l) { known = kb_make_nonneg(known); }
            if kb_is_neg(l) { known = kb_make_neg(known); }
        }
        return known;
    }
    let zm = r.z & 0xFFFFFFFF;
    let om = r.o & 0xFFFFFFFF;
    known = kb_all_conflict(w);
    var sa = min_sa;
    while sa <= max_sa {
        let s = sa as u64;
        if (zm & s) == 0 && (om | s) == s {
            known = kb_intersect(known, kb_shl_const(l, sa, nuw, nsw));
            if kb_is_unknown(known) { break; }
        }
        sa++;
    }
    if kb_has_conflict(known) { known = kb_all_zero(w); }
    return known;
}

fn ashr_w(x: u64, sa: i64, w: i64) -> u64 { ((sext_w(x, w) >> sa) as! u64) & wmask(w) }

// KnownBits::lshr / ashr
fn kb_shr(l: KB, r: KB, sa_nonzero: bool, exact: bool, arith: bool) -> KB {
    let w = l.w as i64;
    var known = kb_unknown(w);
    var min_sa = limited(kb_min(r), w);
    if min_sa == 0 && sa_nonzero { min_sa = 1; }
    if kb_is_unknown(l) {
        if arith {
            if min_sa == w { return kb_all_zero(w); }
            return known;
        }
        known.z |= high_bits(w, min_sa);
        return known;
    }
    var max_sa = max_shift_amount(kb_max(r), r.w as i64, w);
    if exact {
        let first_one = kb_max_tz(l);
        if first_one < min_sa { return kb_all_zero(w); }
        max_sa = min(max_sa, first_one);
    }
    let zm = r.z & 0xFFFFFFFF;
    let om = r.o & 0xFFFFFFFF;
    known = kb_all_conflict(w);
    var sa = min_sa;
    while sa <= max_sa {
        let s = sa as u64;
        if (zm & s) == 0 && (om | s) == s {
            var k = l;
            if arith { k.z = ashr_w(l.z, sa, w); k.o = ashr_w(l.o, sa, w); }
            else { k.z = (l.z >> sa) | high_bits(w, sa); k.o = l.o >> sa; }
            known = kb_intersect(known, k);
            if kb_is_unknown(known) { break; }
        }
        sa++;
    }
    if kb_has_conflict(known) { known = kb_all_zero(w); }
    return known;
}

// KnownBits::makeGE / umax / umin / smax / smin
fn kb_make_ge(k: KB, v: u64) -> KB {
    let w = k.w as i64;
    let n = clo_w(k.z | v, w);
    let mv = v & ~low_bits(w - n);
    return KB { z: k.z, o: k.o | mv, w: k.w };
}
fn kb_umax(l: KB, r: KB) -> KB {
    if kb_min(l) >= kb_max(r) { return l; }
    if kb_min(r) >= kb_max(l) { return r; }
    return kb_intersect(kb_make_ge(l, kb_min(r)), kb_make_ge(r, kb_min(l)));
}
fn kb_flip(k: KB) -> KB { KB { z: k.o, o: k.z, w: k.w } }
fn kb_umin(l: KB, r: KB) -> KB { kb_flip(kb_umax(kb_flip(l), kb_flip(r))) }
fn kb_flip_sign(k: KB) -> KB {
    let s = sbit(k.w as i64);
    return KB { z: (k.z & ~s) | (k.o & s), o: (k.o & ~s) | (k.z & s), w: k.w };
}
fn kb_smax_op(l: KB, r: KB) -> KB { kb_flip_sign(kb_umax(kb_flip_sign(l), kb_flip_sign(r))) }
fn kb_smin_flip(k: KB) -> KB {
    let s = sbit(k.w as i64);
    return KB { z: (k.o & ~s) | (k.z & s), o: (k.z & ~s) | (k.o & s), w: k.w };
}
fn kb_smin_op(l: KB, r: KB) -> KB { kb_smin_flip(kb_umax(kb_smin_flip(l), kb_smin_flip(r))) }

fn rotl_w(x: u64, s: i64, w: i64) -> u64 { if s == 0 { x } else { ((x << s) | (x >> (w - s))) & wmask(w) } }
// KnownBits::fshl(LHS, RHS, Amt) / fshr: funnel shifts by a constant amount
fn kb_fsh(l: KB, r: KB, amt: u64, left: bool) -> KB {
    let w = l.w as i64;
    var sa = (amt % (w as u64)) as i64;
    if !left { sa = (w - sa) % w; }
    if sa == 0 { return l; }
    let m = wmask(w);
    // fshl(a, b, s) = (a << s) | (b >> (w - s))
    return KB { z: ((l.z << sa) | (r.z >> (w - sa))) & m, o: ((l.o << sa) | (r.o >> (w - sa))) & m, w: l.w };
}

fn clmul_w(a: u64, b: u64, w: i64) -> u64 {
    var r: u64 = 0;
    for i in w { if ((b >> i) & 1) != 0 { r ^= a << i; } }
    return r & wmask(w);
}
fn clmul_or_w(a: u64, b: u64, w: i64) -> u64 {
    var r: u64 = 0;
    let n = min(64 - clz(b), w - ctz_w(a, w));
    for i in n { if ((b >> i) & 1) != 0 { r |= a << i; } }
    return r & wmask(w);
}
// KnownBits::clmul
fn kb_clmul(l: KB, r: KB) -> KB {
    let w = l.w as i64;
    let m = wmask(w);
    var res = kb_const(clmul_w(kb_min(l), kb_min(r), w), w);
    let known = ~(clmul_or_w(~l.z & ~l.o & m, ~r.z & m, w) | clmul_or_w(~l.z & m, ~r.z & ~r.o & m, w)) & m;
    res.z &= known;
    res.o &= known;
    return res;
}

// KnownBits comparisons: 1 true, 0 false, -1 unknown
fn kb_ugt(l: KB, r: KB) -> i64 {
    if kb_max(l) <= kb_min(r) { return 0; }
    if kb_min(l) > kb_max(r) { return 1; }
    return -1;
}
fn kb_uge(l: KB, r: KB) -> i64 { let x = kb_ugt(r, l); if x < 0 { -1 } else { 1 - x } }
fn kb_ult(l: KB, r: KB) -> i64 { kb_ugt(r, l) }
fn kb_ule(l: KB, r: KB) -> i64 { kb_uge(r, l) }
fn kb_sgt(l: KB, r: KB) -> i64 {
    let w = l.w as i64;
    if sext_w(kb_smax(l), w) <= sext_w(kb_smin(r), w) { return 0; }
    if sext_w(kb_smin(l), w) > sext_w(kb_smax(r), w) { return 1; }
    return -1;
}
fn kb_sge(l: KB, r: KB) -> i64 { let x = kb_sgt(r, l); if x < 0 { -1 } else { 1 - x } }
fn kb_slt(l: KB, r: KB) -> i64 { kb_sgt(r, l) }
fn kb_sle(l: KB, r: KB) -> i64 { kb_sge(r, l) }
fn kb_eq(l: KB, r: KB) -> i64 {
    if kb_is_constant(l) && kb_is_constant(r) { return if l.o == r.o { 1 } else { 0 }; }
    if (l.o & r.z) != 0 || (r.o & l.z) != 0 { return 0; }
    return -1;
}
fn kb_min_pop(k: KB) -> i64 { popcount(k.o) }
// KnownBits::abs
fn kb_abs(k: KB, int_min_is_poison: bool) -> KB {
    let w = k.w as i64;
    if kb_is_nonneg(k) { return k; }
    var ka = kb_unknown(w);
    if kb_is_neg(k) {
        var t = k;
        if int_min_is_poison && popcount(k.z) + 2 == w { t.o |= (1 as u64) << kb_min_tz(k); }
        ka = kb_add_sub(false, int_min_is_poison, false, kb_const(0, w), t);
        if int_min_is_poison && kb_min_pop(t) == 1 && kb_max_pop(t) != 1 {
            t.o &= ~sbit(w);
            t.z |= sbit(w);
            ka.o |= bits_range(w - kb_min_lz(t), w - 1);
        }
    } else {
        let maxtz = kb_max_tz(k);
        let mintz = kb_min_tz(k);
        ka.z |= low_bits(mintz);
        if maxtz == mintz && maxtz < w { ka.o |= (1 as u64) << maxtz; }
        if int_min_is_poison || (k.o != 0 && k.o != sbit(w)) {
            ka.o &= ~sbit(w);
            ka.z |= sbit(w);
        }
    }
    return ka;
}

// ---------------------------------------------------------------------------------------------
// More KnownBits operations (KnownBits.cpp)

fn kb_blsi(k: KB) -> KB {
    let w = k.w as i64;
    var r = KB { z: k.z, o: 0, w: k.w };
    let mx = kb_max_tz(k);
    r.z |= wmask(w) & ~low_bits(min(mx + 1, w));
    let mn = kb_min_tz(k);
    if mx == mn && mx < w { r.o |= (1 as u64) << mx; }
    return r;
}
fn kb_blsmsk(k: KB) -> KB {
    let w = k.w as i64;
    var r = kb_unknown(w);
    let mx = kb_max_tz(k);
    r.z |= wmask(w) & ~low_bits(min(mx + 1, w));
    let mn = kb_min_tz(k);
    r.o |= low_bits(min(mn + 1, w));
    return r;
}
fn kb_div_low_bit(k0: KB, l: KB, r: KB, exact: bool) -> KB {
    if !exact { return k0; }
    let w = k0.w as i64;
    var k = k0;
    if (l.o & 1) != 0 { k.o |= 1; }
    let mintz = kb_min_tz(l) - kb_max_tz(r);
    let maxtz = kb_max_tz(l) - kb_min_tz(r);
    if mintz >= 0 {
        k.z |= low_bits(mintz);
        if mintz == maxtz { k.o |= if mintz < w { (1 as u64) << mintz } else { 0 }; }
    } else if maxtz < 0 {
        k = kb_all_zero(w);
    }
    if kb_has_conflict(k) { k = kb_all_zero(w); }
    return k;
}
fn kb_is_zero_known(k: KB) -> bool { k.z == wmask(k.w as i64) && k.o == 0 }
fn kb_udiv(l: KB, r: KB, exact: bool) -> KB {
    let w = l.w as i64;
    if kb_is_zero_known(l) || kb_is_zero_known(r) { return kb_all_zero(w); }
    let mind = kb_min(r);
    let maxn = kb_max(l);
    let maxres = if mind == 0 { maxn } else { maxn / mind };
    var k = kb_unknown(w);
    k.z |= high_bits(w, clz_w(maxres, w));
    return kb_div_low_bit(k, l, r, exact);
}
fn sdiv_val(a: u64, b: u64, w: i64) -> u64 {
    let sa = sext_w(a, w);
    let sb = sext_w(b, w);
    if sb == -1 { return ((0 as u64) - a) & wmask(w); }
    return ((sa / sb) as! u64) & wmask(w);
}
fn kb_sdiv(l: KB, r: KB, exact: bool) -> KB {
    if kb_is_nonneg(l) && kb_is_nonneg(r) { return kb_udiv(l, r, exact); }
    let w = l.w as i64;
    var k = kb_unknown(w);
    if kb_is_zero_known(l) || kb_is_zero_known(r) { return kb_all_zero(w); }
    var have = false;
    var res: u64 = 0;
    let m = wmask(w);
    if kb_is_neg(l) && kb_is_neg(r) {
        let denom = kb_smax(r);
        let num = kb_smin(l);
        res = if num == sbit(w) && denom == m { sbit(w) - 1 } else { sdiv_val(num, denom, w) };
        have = true;
    } else if kb_is_neg(l) && kb_is_nonneg(r) {
        if exact || ((((0 as u64) - kb_smax(l)) & m) >= kb_smax(r)) {
            let denom = kb_smin(r);
            let num = kb_smin(l);
            res = if denom == 0 { num } else { sdiv_val(num, denom, w) };
            have = true;
        }
    } else if kb_is_nonneg(l) && kb_is_nonzero_strict(l) && kb_is_neg(r) {
        if exact || kb_smin(l) >= (((0 as u64) - kb_smin(r)) & m) {
            let denom = kb_smax(r);
            let num = kb_smax(l);
            res = sdiv_val(num, denom, w);
            have = true;
        }
    }
    if have {
        if (res & sbit(w)) == 0 { k.z |= high_bits(w, clz_w(res, w)); }
        else { k.o |= high_bits(w, clo_w(res, w)); }
    }
    return kb_div_low_bit(k, l, r, exact);
}
// isStrictlyPositive: non-negative and non-zero
fn kb_is_nonzero_strict(k: KB) -> bool { kb_is_nonneg(k) && k.o != 0 }
fn kb_rem_low_bits(l: KB, r: KB) -> KB {
    let w = l.w as i64;
    if !kb_is_zero_known(r) && (r.z & 1) != 0 {
        let rz = kb_min_tz(r);
        let mask = low_bits(rz);
        return KB { z: l.z & mask, o: l.o & mask, w: l.w };
    }
    return kb_unknown(w);
}
fn kb_urem(l: KB, r: KB) -> KB {
    let w = l.w as i64;
    var k = kb_rem_low_bits(l, r);
    if kb_is_constant(r) && r.o != 0 && (r.o & (r.o - 1)) == 0 {
        k.z |= ~(r.o - 1) & wmask(w);
        return k;
    }
    let leaders = max(kb_min_lz(l), kb_min_lz(r));
    k.z |= high_bits(w, leaders);
    return k;
}
fn kb_min_sign_bits_k(k: KB) -> i64 {
    if kb_is_nonneg(k) { return kb_min_lz(k); }
    if kb_is_neg(k) { return kb_min_lo(k); }
    return 1;
}
fn kb_srem(l: KB, r: KB) -> KB {
    let w = l.w as i64;
    var k = kb_rem_low_bits(l, r);
    if kb_is_constant(r) && r.o != 0 && (r.o & (r.o - 1)) == 0 {
        let lowb = r.o - 1;
        if kb_is_nonneg(l) || (lowb & ~l.z) == 0 { k.z |= ~lowb & wmask(w); }
        if kb_is_neg(l) && (lowb & l.o) != 0 { k.o |= ~lowb & wmask(w); }
        return k;
    }
    if kb_is_neg(l) && kb_is_nonzero(k) { k.o |= high_bits(w, max(kb_min_lo(l), kb_min_sign_bits_k(r))); }
    else if kb_is_nonneg(l) { k.z |= high_bits(w, max(kb_min_lz(l), kb_min_sign_bits_k(r))); }
    return k;
}
// computeForSatAddSub
fn kb_sat_add_sub(add: bool, signed: bool, l: KB, r: KB) -> KB {
    let w = l.w as i64;
    let m = wmask(w);
    var ovf: i64 = -1;
    var may_neg = true;
    var may_pos = true;
    if signed {
        if add && ((kb_is_neg(l) && kb_is_nonneg(r)) || (kb_is_nonneg(l) && kb_is_neg(r))) { ovf = 0; }
        else if !add && ((kb_is_neg(l) && kb_is_neg(r)) || (kb_is_nonneg(l) && kb_is_nonneg(r))) { ovf = 0; }
        else {
            let ul = KB { z: l.z | sbit(w), o: l.o & ~sbit(w), w: l.w };
            let ur = KB { z: r.z | sbit(w), o: r.o & ~sbit(w), w: r.w };
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
        let s = kb_max(l) + kb_max(r);
        let of1 = (s & m) < kb_max(l) || (w < 64 && s > m);
        if !of1 { ovf = 0; }
        else {
            let s2 = kb_min(l) + kb_min(r);
            if (s2 & m) < kb_min(l) || (w < 64 && s2 > m) { ovf = 1; }
        }
    } else {
        if kb_min(l) >= kb_max(r) { ovf = 0; }
        else if kb_max(l) < kb_min(r) { ovf = 1; }
    }
    var res = kb_add_sub(add, signed, !signed, l, r);
    if ovf == 0 { return res; }
    if ovf == 1 {
        var c: u64 = 0;
        if signed { c = if kb_is_neg(l) { sbit(w) } else { sbit(w) - 1 }; }
        else if add { c = m; }
        else { c = 0; }
        return kb_const(c, w);
    }
    if signed {
        if may_pos { res.z &= ~low_bits(w - 1); }
        if may_neg { res.o &= ~low_bits(w - 1); }
    } else if add { res.z = 0; }
    else { res.o = 0; }
    return res;
}
fn kb_reduce_add(k: KB, n: i64) -> KB {
    let w = k.w as i64;
    if n == 0 { return kb_unknown(w); }
    if kb_is_constant(k) { return kb_const((n as u64) * k.o, w); }
    let lost = if n <= 1 { 0 } else { 64 - clz((n - 1) as u64) };
    var r = kb_unknown(w);
    if kb_is_nonneg(k) { let lz = kb_min_lz(k); r.z |= high_bits(w, if lz > lost { lz - lost } else { 0 }); }
    else if kb_is_neg(k) { let lo = kb_min_lo(k); r.o |= high_bits(w, if lo > lost { lo - lost } else { 0 }); }
    return r;
}

// ---------------------------------------------------------------------------------------------
// computeKnownBits (llvm/lib/Analysis/ValueTracking.cpp)

// SimplifyQuery::CxtI: the context instruction (DemandedBits passes the user of the operand).
var kb_cxt: i32 = -1;

fn not_ported(what: const u8[:]) { fatal(str("computeKnownBits: ", what, " is not ported yet")); }

// The bit width of a value's scalar type (pointers: the DataLayout pointer size).
fn kb_width(v: i32) -> i64 {
    let t = ty_scalar(vals[v].ty);
    var w: i64 = 0;
    if ty_is_int(t) { w = ty_bits(t); }
    else if ty_kind(t) == TK_PTR { w = dl_ptr(types[t].n as i64).bits; }
    else { fatal("internal: computeKnownBits of a non-integer value"); }
    if w > 64 { not_ported("an integer wider than 64 bits"); }
    return w;
}
fn kb_width_ty(t0: i32) -> i64 {
    let t = ty_scalar(t0);
    if ty_kind(t) == TK_PTR { return dl_ptr(types[t].n as i64).bits; }
    return ty_bits(t);
}

fn all_elts(v: i32) -> u64 {
    let t = vals[v].ty;
    if ty_kind(t) == TK_FVEC {
        let n = ty_count(t);
        if n > 64 { not_ported("a vector of more than 64 elements"); }
        return low_bits(n);
    }
    return 1;
}

recursive fn kb_compute_all(v: i32, depth: i64) -> KB { kb_compute(v, all_elts(v), depth) }

fn const_int_bits(c: i32) -> u64 { cint_lo(c) }

recursive fn kb_compute(v: i32, de: u64, depth: i64) -> KB {
    let w = kb_width(v);
    if de == 0 { return kb_unknown(w); }
    let k = vals[v].kind;
    let c = m_apint(v);
    if c >= 0 { return kb_const(ci_val(c), w); }
    if k == VK_CNULL || k == VK_AGGZERO { return kb_all_zero(w); }
    if k == VK_CDVECTOR {
        var r = kb_all_conflict(w);
        for i in nops(v) {
            if ((de >> i) & 1) == 0 { continue; }
            let x = cint_lo(op(v, i));
            r.z &= ~x;
            r.o &= x;
        }
        if kb_has_conflict(r) { return kb_unknown(w); }
        return r;
    }
    if k == VK_CVECTOR {
        var r = kb_all_conflict(w);
        for i in nops(v) {
            if ((de >> i) & 1) == 0 { continue; }
            let e = op(v, i);
            if vals[e].kind == VK_POISON { continue; }
            if vals[e].kind != VK_CINT { return kb_unknown(w); }
            let x = cint_lo(e);
            r.z &= ~x;
            r.o &= x;
        }
        if kb_has_conflict(r) { return kb_unknown(w); }
        return r;
    }
    var known = kb_unknown(w);
    if k == VK_UNDEF || k == VK_POISON { return known; }
    if is_constant_data(v) { fatal("internal: unhandled constant data in computeKnownBits"); }
    if k == VK_ARG && arg_range(v) { known = cr_to_kb(vt_cr); }
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
        known.z |= low_bits(log2_exact(al));
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
        if md >= 0 { return ci_val(mds[md_op(md, 0)].extra) as i64; }
        return 1;
    }
    if k == VK_CEXPR && csts[vals[v].sub].op as i64 == OP_INTTOPTR && vals[op(v, 0)].kind == VK_CINT {
        let x = op(v, 0);
        let tz = if cint_is_zero(x) { ty_bits(vals[x].ty) } else { ctz(cint_lo(x)) };
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
fn apint_value(v: i32) -> u64 { ci_val(m_apint(v)) }

// getKnownBitsFromAndXorOr
recursive fn kb_and_xor_or(iv: i32, de: u64, kl: KB, kr: KB, depth: i64) -> KB {
    let w = kl.w as i64;
    let o = opcode_of(iv);
    var out = kb_unknown(w);
    let a = op(iv, 0);
    let b = op(iv, 1);
    let has_one = kl.o != 0 || kr.o != 0;
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
    if ((out.z | out.o) & 1) == 0 {
        fn pat(x: i32, y: i32) -> i32 {
            if is_op(y, OP_ADD) { if op(y, 0) == x { return op(y, 1); } if op(y, 1) == x { return op(y, 0); } }
            if is_op(y, OP_SUB) { if op(y, 0) == x { return op(y, 1); } if op(y, 1) == x { return op(y, 0); } }
            return -1;
        }
        var other = pat(a, b);
        if other < 0 { other = pat(b, a); }
        if other >= 0 {
            let ky = kb_compute(other, de, depth + 1);
            if cto_w(ky.o, ky.w as i64) > 0 {
                if is_and { out.z |= 1; } else { out.o |= 1; }
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
        let lo = cint_lo(mds[md_op(md, 2 * i)].extra);
        let hi = cint_lo(mds[md_op(md, 2 * i + 1)].extra);
        let m = wmask(w);
        let umax = if lo > hi { m } else { (hi - 1) & m };
        let umin = if lo > hi && hi != 0 { 0 } else { lo };
        let cp = clz_w(umax ^ umin, w);
        let mask = high_bits(w, cp);
        known.o &= umax & mask;
        known.z &= ~umax & mask;
    }
    return known;
}

// computeKnownBitsAddSub
recursive fn kb_add_sub_ops(add: bool, a: i32, b: i32, nsw: bool, nuw: bool, de: u64, depth: i64) -> KB {
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
recursive fn kb_mul_ops(a: i32, b: i32, nsw: bool, nuw: bool, de: u64, depth: i64) -> KB {
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
                let one = kb_const(1, k1.w as i64);
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
        if ovb < tb { known.z |= high_bits(tb, tb - ovb + 1); }
    }
    if is_nonneg && !kb_is_neg(known) { known = kb_make_nonneg(known); }
    else if is_negr && !kb_is_nonneg(known) { known = kb_make_neg(known); }
    return known;
}

// computeKnownBitsFromLerpPattern
recursive fn kb_from_lerp(op0: i32, op1: i32, de: u64, known0: KB, depth: i64) -> KB {
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
    if sub_is_xor && (kb_max(kc) & ~kb_min(kbb)) != 0 { return known; }
    let mad = max(kb_max(ka), kb_max(kd));
    let mb = kb_max(kbb);
    if mad != 0 && mb != 0 {
        if (64 - clz(mad)) + (64 - clz(mb)) > 64 { return known; }
        let p = mad * mb;
        if p / mad != mb || (p & ~wmask(w)) != 0 { return known; }
        known.z |= high_bits(w, clz_w(p, w));
    } else {
        known.z |= high_bits(w, w);
    }
    return known;
}

// computeKnownBitsFromCmp
recursive fn kb_from_cmp(v: i32, p: i64, l: i32, r: i32, known0: KB) -> KB {
    var known = known0;
    let w = known.w as i64;
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
    let c = ci_val(cc);
    let m = wmask(w);
    if p == P_EQ {
        if m_v(l, v) { known = kb_union(known, kb_const(c, w)); }
        else if is_op(l, OP_AND) && (m_v(op(l, 0), v) || m_v(op(l, 1), v)) {
            let y = if m_v(op(l, 0), v) { op(l, 1) } else { op(l, 0) };
            known.o |= c;
            let mk = m_apint(y);
            if mk >= 0 { known.z |= ~c & ci_val(mk); }
        } else if is_op(l, OP_OR) && (m_v(op(l, 0), v) || m_v(op(l, 1), v)) {
            let y = if m_v(op(l, 0), v) { op(l, 1) } else { op(l, 0) };
            known.z |= ~c & m;
            let mk = m_apint(y);
            if mk >= 0 { known.o |= c & ~ci_val(mk); }
        } else if is_op(l, OP_SHL) && m_v(op(l, 0), v) && m_constant_int(op(l, 1)) >= 0 && ci_val(op(l, 1)) < w as u64 {
            let s = ci_val(op(l, 1)) as i64;
            let rk = kb_const(c, w);
            known = kb_union(known, KB { z: (rk.z >> s) | 0, o: rk.o >> s, w: rk.w });
            // KnownBits >>= sets no new knowledge for the vacated high bits
        } else if (is_op(l, OP_LSHR) || is_op(l, OP_ASHR)) && m_v(op(l, 0), v) && m_constant_int(op(l, 1)) >= 0 && ci_val(op(l, 1)) < w as u64 {
            let s = ci_val(op(l, 1)) as i64;
            let rk = kb_const(c, w);
            known = kb_union(known, KB { z: (rk.z << s) & m, o: (rk.o << s) & m, w: rk.w });
        }
        return known;
    }
    if p == P_NE {
        if c == 0 && is_op(l, OP_AND) && m_v(op(l, 0), v) && m_power2(op(l, 1)) { known.o |= ci_val(m_apint(op(l, 1))); }
        return known;
    }
    var off: i64 = -1;
    var matched = false;
    if m_v(l, v) { matched = true; }
    else if (is_op(l, OP_ADD) || (is_op(l, OP_OR) && op_disjoint(l))) && m_v(op(l, 0), v) && m_apint(op(l, 1)) >= 0 {
        matched = true;
        off = ci_val(m_apint(op(l, 1))) as! i64;
    }
    if matched {
        var lr = cr_allowed_icmp(p, cr_single(c, w));
        if off != -1 || (m_v(l, v) == false) {
            if !m_v(l, v) {
                let o2 = (off as! u64) & m;
                lr = cr_sub(lr, cr_single(o2, w));
            }
        }
        known = kb_union(known, cr_to_kb(lr));
    }
    if p == P_UGT || p == P_UGE {
        if (is_op(l, OP_AND) && (m_v(op(l, 0), v) || m_v(op(l, 1), v))) || (is_op(l, OP_SUB) && op_nuw(l) && m_v(op(l, 0), v)) {
            let x = (c + (if p == P_UGT { 1 } else { 0 })) & m;
            known.o |= high_bits(w, clo_w(x, w));
        }
    }
    if p == P_ULT || p == P_ULE {
        if (is_op(l, OP_OR) && (m_v(op(l, 0), v) || m_v(op(l, 1), v))) || (is_op(l, OP_ADD) && op_nuw(l) && (m_v(op(l, 0), v) || m_v(op(l, 1), v))) {
            let x = (c - (if p == P_ULT { 1 } else { 0 })) & m;
            known.z |= high_bits(w, clz_w(x, w));
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
        let kw = known.w as i64;
        if is_inst(l) && op_nuw(l) { return kb_union(known, kb_zext(dk, kw)); }
        return kb_union(known, kb_anyext(dk, kw));
    }
    return kb_from_cmp(v, p, l, r, known);
}

// computeKnownBitsFromCond
recursive fn kb_from_cond(v: i32, cond: i32, known: KB, invert: bool, depth: i64) -> KB {
    let w = known.w as i64;
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
    var cr = kb_from_cond(arm, cond, kb_unknown(known.w as i64), invert, depth + 1);
    if kb_is_unknown(cr) { return known; }
    cr = kb_union(cr, known);
    if kb_has_conflict(cr) { return known; }
    if !is_guaranteed_not_to_be_undef(arm, kb_cxt, depth + 1) { return known; }
    return cr;
}

// computeKnownBitsFromContext (Q.DC == nullptr; assumptions: assume.goose)
recursive fn kb_from_context(v: i32, known: KB, depth: i64) -> KB {
    if kb_cxt < 0 { return known; }
    return kb_from_assumptions(v, known, depth);
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

recursive fn kb_from_operator(iv: i32, de: u64, known0: KB, depth: i64) -> KB {
    let w = known0.w as i64;
    var known = known0;
    let o = opcode_of(iv);
    let is_i = vals[iv].kind == VK_INST;
    if o == OP_LOAD {
        let rm = inst_get_md(iv, md_kind_id("range"));
        if rm >= 0 { known = kb_from_range_md(rm, w); }
        return known;
    }
    if o == OP_AND || o == OP_OR || o == OP_XOR {
        let kr = kb_compute(op(iv, 1), de, depth + 1);
        let kl = kb_compute(op(iv, 0), de, depth + 1);
        return kb_and_xor_or(iv, de, kl, kr, depth);
    }
    if o == OP_MUL { return kb_mul_ops(op(iv, 0), op(iv, 1), op_nsw(iv), op_nuw(iv), de, depth); }
    if o == OP_UDIV {
        let a = kb_compute(op(iv, 0), de, depth + 1);
        let b = kb_compute(op(iv, 1), de, depth + 1);
        return kb_udiv(a, b, op_exact(iv));
    }
    if o == OP_SDIV {
        let a = kb_compute(op(iv, 0), de, depth + 1);
        let b = kb_compute(op(iv, 1), de, depth + 1);
        return kb_sdiv(a, b, op_exact(iv));
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
                    let infb: u64 = (((1 as u64) << f.ebits) - 1) << (f.p - 1);
                    known = kb_intersect(known, kb_const(infb, w));
                }
                if (cls & FCL_ZERO) != 0 { known = kb_intersect(known, kb_const(0, w)); }
                known.z &= ~sbit(w);
                known.o &= ~sbit(w);
            }
            if fk.sign == 1 { known = kb_make_neg(known); }
            else if fk.sign == 0 { known = kb_make_nonneg(known); }
            return known;
        }
        if ty_kind(st) != TK_FVEC || !ty_is_int(types[st].a) || !is_int_or_int_vec(vals[iv].ty) || ty_kind(vals[iv].ty) == TK_SVEC { return known; }
        not_ported("known bits of a bitcast between integer vector shapes");
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
        let sa_nonzero = kb_is_nonzero(k1) || (kb_max(k1) < (k1.w as u64) && ikz(b, de, depth + 1));
        if o == OP_SHL {
            known = kb_shl(k2, k1, op_nuw(iv), op_nsw(iv), sa_nonzero);
            if match_apint(a) { known.z |= low_bits(ctz_w(apint_value(a), w)); }
            // shl X, sub(Y, xor(ctlz(X, true), BitWidth-1))
            if is_pow2_w(w) && is_op(b, OP_SUB) && m_apint(op(b, 0)) >= 0 {
                let xo = op(b, 1);
                if is_op(xo, OP_XOR) && m_specific_int(op(xo, 1), (w - 1) as u64) {
                    let ct = op(xo, 0);
                    if m_intrinsic(ct, IID_ctlz) && op(ct, 0) == a && m_one(op(ct, 1)) {
                        let yc = ci_val(m_apint(op(b, 0)));
                        if yc < (w - 1) as u64 {
                            let y = yc as i64;
                            known.o |= (1 as u64) << y;
                            known.z |= wmask(w) & ~low_bits(y + 1);
                        }
                    }
                }
            }
            return known;
        }
        known = kb_shr(k2, k1, sa_nonzero, op_exact(iv), o == OP_ASHR);
        if o == OP_LSHR && match_apint(a) { known.z |= high_bits(w, clz_w(apint_value(a), w)); }
        return known;
    }
    if o == OP_SUB { return kb_add_sub_ops(false, op(iv, 0), op(iv, 1), op_nsw(iv), op_nuw(iv), de, depth); }
    if o == OP_ADD { return kb_add_sub_ops(true, op(iv, 0), op(iv, 1), op_nsw(iv), op_nuw(iv), de, depth); }
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
        known.z |= low_bits(if al == 0 { 0 } else { (al - 1) as i64 });
        return known;
    }
    if o == OP_GEP { return kb_gep(iv, known, depth); }
    if o == OP_PHI { return kb_phi(iv, de, known, depth); }
    if o == OP_CALL || o == OP_INVOKE { return kb_call(iv, de, known, depth); }
    if o == OP_SHUFFLEVECTOR {
        if is_i {
            let sv = shuffle_splat_value(iv);
            if sv >= 0 { return kb_compute_all(sv, depth + 1); }
        } else { return kb_unknown(w); }
        let ok, dl, dr = shuffle_demanded(iv, de);
        if !ok { return kb_unknown(w); }
        known = kb_all_conflict(w);
        if dl != 0 {
            known = kb_compute(op(iv, 0), dl, depth + 1);
            if kb_is_unknown(known) { return known; }
        }
        if dr != 0 {
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
        if ci >= 0 && ci_val(ci) < n as u64 {
            let x = ci_val(ci) as i64;
            dv &= ~((1 as u64) << x);
            needs = ((de >> x) & 1) != 0;
        }
        known = kb_all_conflict(w);
        if needs {
            known = kb_compute_all(elt, depth + 1);
            if kb_is_unknown(known) { return known; }
        }
        if dv != 0 {
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
        var dv = low_bits(n);
        let ci = m_constant_int(idx);
        if ci >= 0 && ci_val(ci) < n as u64 { dv = (1 as u64) << ci_val(ci); }
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
    let w = known.w as i64;
    let iw = dl_ptr(ptr_as(vals[iv].ty)).idx;
    if iw != w { not_ported("GEP known bits with an index width different from the pointer width"); }
    var acc: u64 = 0;
    var t = gep_src_ty(iv);
    for i in 1..nops(iv) {
        if kb_is_unknown(known) { break; }
        let ix = op(iv, i);
        let is_struct = i > 1 && ty_is_struct(t);
        let cur = t;
        if i > 1 { t = if ty_is_struct(t) { ty_field(t, ci_val(m_apint(ix)) as i64) } else { types[t].a }; }
        if is_constant(ix) && is_null_value(ix) { continue; }
        if is_struct {
            let fi = ci_val(m_apint(ix)) as i64;
            acc += dl_struct_offset(cur, fi) as u64;
            continue;
        }
        let it = if i == 1 { cur } else { t };
        if !cf_ty_is_sized(it) { return kb_unknown(w); }
        if ty_kind(it) == TK_SVEC || ty_contains_scalable(it) { not_ported("known bits of GEPs over scalable types"); }
        let stride = dl_alloc_size(it) as u64;
        let ci = m_constant_int(ix);
        if ci >= 0 {
            let ivw = ty_bits(vals[ci].ty);
            let sx = (sext_w(ci_val(ci), ivw) as! u64) & wmask(iw);
            acc += sx * stride;
            continue;
        }
        var ib = kb_compute_all(ix, depth + 1);
        let ibw = ib.w as i64;
        if ibw > iw { ib = kb_trunc(ib, iw); } else if ibw < iw { ib = kb_sext(ib, iw); }
        let sf = kb_const(stride & wmask(iw), iw);
        known = kb_add_sub(true, false, false, known, kb_mul(ib, sf, false));
    }
    acc &= wmask(iw);
    if !kb_is_unknown(known) && acc != 0 { known = kb_add_sub(true, false, false, known, kb_const(acc, iw)); }
    return known;
}

recursive fn kb_phi(p: i32, de: u64, known0: KB, depth: i64) -> KB {
    var known = known0;
    let w = known.w as i64;
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
            if o == OP_SHL { known.z |= low_bits(kb_min_tz(k2)); }
            else if o == OP_LSHR || o == OP_UDIV || o == OP_UREM { known.z |= high_bits(w, kb_min_lz(k2)); }
            else { known.z |= high_bits(w, kb_min_lz(k2)); known.o |= high_bits(w, kb_min_lo(k2)); }
        } else if o == OP_ADD || o == OP_SUB || o == OP_AND || o == OP_OR || o == OP_MUL {
            let opnum = if op(p, 0) == r { 0 } else { 1 };
            let rinst = block_terminator(phi_block(p, opnum));
            let linst = block_terminator(phi_block(p, 1 - opnum));
            kb_cxt = rinst;
            let k2 = kb_compute(r, de, depth + 1);
            kb_cxt = linst;
            let k3 = kb_compute(l, de, depth + 1);
            kb_cxt = save;
            known.z |= low_bits(min(kb_min_tz(k2), kb_min_tz(k3)));
            let is_ovf_op = o == OP_ADD || o == OP_SUB || o == OP_MUL;
            if is_ovf_op && op_nsw(bo) {
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
                        let cr = cr_exact_icmp(pr, ci_val(rc), w);
                        let ku = kb_union(k2, cr_to_kb(cr));
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

recursive fn kb_call(iv: i32, de: u64, known0: KB, depth: i64) -> KB {
    var known = known0;
    let w = known.w as i64;
    let rm = inst_get_md(iv, md_kind_id("range"));
    if rm >= 0 { known = kb_from_range_md(rm, w); }
    if call_range(iv) { known = kb_union(known, cr_to_kb(vt_cr)); }
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
        return kb_union(known, KB { z: reverse_bits_w(k2.z, w), o: reverse_bits_w(k2.o, w), w: k2.w });
    }
    if id == IID_bswap {
        let k2 = kb_compute(op(iv, 0), de, depth + 1);
        return kb_union(known, KB { z: byte_swap_w(k2.z, w), o: byte_swap_w(k2.o, w), w: k2.w });
    }
    if id == IID_ctlz || id == IID_cttz {
        let k2 = kb_compute(op(iv, 0), de, depth + 1);
        var p = if id == IID_ctlz { kb_max_lz(k2) } else { kb_max_tz(k2) };
        if op(iv, 1) == c_true() { p = min(p, w - 1); }
        let lb = 64 - clz(p as u64);
        known.z |= wmask(w) & ~low_bits(lb);
        return known;
    }
    if id == IID_ctpop {
        let k2 = kb_compute(op(iv, 0), de, depth + 1);
        let lb = 64 - clz(kb_max_pop(k2) as u64);
        known.z |= wmask(w) & ~low_bits(lb);
        return known;
    }
    if id == IID_fshl || id == IID_fshr {
        let sa = m_apint(op(iv, 2));
        if sa < 0 { return known; }
        let k2 = kb_compute(op(iv, 0), de, depth + 1);
        let k3 = kb_compute(op(iv, 1), de, depth + 1);
        return kb_fsh(k2, k3, ci_val(sa), id == IID_fshl);
    }
    if id == IID_clmul {
        let k1 = kb_compute(op(iv, 0), de, depth + 1);
        let k2 = kb_compute(op(iv, 1), de, depth + 1);
        return kb_clmul(k1, k2);
    }
    if id == IID_pext || id == IID_pdep { not_ported("known bits of pext/pdep"); }
    if id == IID_uadd_sat || id == IID_usub_sat || id == IID_sadd_sat || id == IID_ssub_sat {
        let k1 = kb_compute(op(iv, 0), de, depth + 1);
        let k2 = kb_compute(op(iv, 1), de, depth + 1);
        return kb_sat_add_sub(id == IID_uadd_sat || id == IID_sadd_sat, id == IID_sadd_sat || id == IID_ssub_sat, k1, k2);
    }
    if id == IID_vector_reverse {
        let n = ty_count(vals[iv].ty);
        return kb_compute(op(iv, 0), reverse_bits_w(de, n), depth + 1);
    }
    if id == IID_vector_reduce_and || id == IID_vector_reduce_or || id == IID_vector_reduce_umax || id == IID_vector_reduce_umin ||
       id == IID_vector_reduce_smax || id == IID_vector_reduce_smin {
        return kb_compute_all(op(iv, 0), depth + 1);
    }
    if id == IID_vector_reduce_xor {
        known = kb_compute_all(op(iv, 0), depth + 1);
        let vt0 = vals[op(iv, 0)].ty;
        let even = (ty_count(vt0) % 2) == 0;
        if even { known.z |= known.o; }
        if ty_kind(vt0) == TK_SVEC || even { known.o = 0; }
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
            var lo = ci_val(m_apint(op(iv, 1)));
            var hi = ci_val(m_apint(op(inner, 1)));
            if id == IID_smin { let t = lo; lo = hi; hi = t; }
            if sext_w(lo, w) <= sext_w(hi, w) {
                r = kb_union(r, cr_to_kb(cr_nonempty(lo, hi + 1, w)));
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
    let nm = intr_name(id as i64);
    if starts_with(nm, "llvm.x86.") || starts_with(nm, "llvm.riscv.") || starts_with(nm, "llvm.amdgcn.") {
        not_ported(str("known bits of ", nm));
    }
    return known;
}

// getVScaleRange(F, BitWidth).toKnownBits() (ValueTracking.cpp; ConstantRange::toKnownBits)
fn kb_vscale(fv: i32, w: i64) -> KB {
    var lo: u64 = 1;
    var hi_max: u64 = wmask(w);      // unsigned max of the range
    let a = aset_find(alist_fn(globs[glob_of(fv)].attrs), AK_VScaleRange);
    if a >= 0 {
        let mn = attrs[a].i1 >> 32;
        let mx = attrs[a].i1 & 0xFFFFFFFF;
        fn bitw(x: u64) -> i64 { if x == 0 { 0 } else { 64 - clz(x) } }
        if bitw(mn) > w { return kb_unknown(w); }
        lo = mn;
        if mx != 0 && bitw(mx) <= w { hi_max = mx; }
    }
    var k = kb_const(lo, w);
    let d = lo ^ hi_max;
    if d != 0 {
        let keep = ~low_bits(64 - clz(d));
        k.z &= keep;
        k.o &= keep;
    }
    return k;
}
