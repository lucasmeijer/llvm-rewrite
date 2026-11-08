// KnownBits (llvm/lib/Support/KnownBits.cpp) and computeKnownBits (llvm/lib/Analysis/ValueTracking.cpp),
// for integers of at most 64 bits and fixed vectors of at most 64 elements.
//
// Coverage policy: every case of LLVM's computeKnownBits is either ported, or detected and reported with
// fatal() ("not ported"), so a less precise answer can never silently produce different IR. Cases LLVM
// itself answers with "unknown" (unlisted opcodes/intrinsics) are unknown here too. See NOTES.md for what
// is still missing (PHI recurrences, select-arm conditions, assumptions, pointers, division, ...).
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import intrinsics;
import implied;

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

// ---------------------------------------------------------------------------------------------
// computeKnownBits

// SimplifyQuery::CxtI: the context instruction (DemandedBits passes the user of the operand).
var kb_cxt: i32 = -1;

fn not_ported(what: const u8[:]) { fatal(str("computeKnownBits: ", what, " is not ported yet")); }

// The bit width of a value's scalar type (pointers: not supported).
fn kb_width(v: i32) -> i64 {
    let t = ty_scalar(vals[v].ty);
    if ty_is_int(t) {
        let w = ty_bits(t);
        if w > 64 { not_ported("an integer wider than 64 bits"); }
        return w;
    }
    if ty_kind(t) == TK_PTR { not_ported("known bits of a pointer"); }
    fatal("internal: computeKnownBits of a non-integer value");
    return 0;
}

fn all_elts(v: i32) -> u64 {
    let t = vals[v].ty;
    if ty_kind(t) == TK_FVEC {
        let n = ty_count(t);
        if n > 64 { not_ported("a vector of more than 64 elements"); }
        return low_bits(n);
    }
    if ty_kind(t) == TK_SVEC { not_ported("scalable vectors"); }
    return 1;
}

var kb_assume_checked_fn: i32 = -1;
// computeKnownBitsFromContext: assumptions are not ported; refuse functions that have any.
fn kb_check_context(fv: i32) {
    if kb_assume_checked_fn == fv { return; }
    each_inst(fv) { i => if inst_iid(i) == IID_assume { not_ported("known bits from llvm.assume"); } };
    kb_assume_checked_fn = fv;
}

recursive fn kb_compute_all(v: i32, depth: i64) -> KB { kb_compute(v, all_elts(v), depth) }

fn const_int_bits(c: i32) -> u64 { cint_lo(c) }

recursive fn kb_compute(v: i32, de: u64, depth: i64) -> KB {
    let w = kb_width(v);
    if de == 0 { return kb_unknown(w); }
    let k = vals[v].kind;
    if k == VK_CINT { return kb_const(const_int_bits(v), w); }
    if k == VK_CNULL || k == VK_AGGZERO { return kb_all_zero(w); }
    if k == VK_CDVECTOR || k == VK_CVECTOR {
        var r = kb_all_conflict(w);
        for i in nops(v) {
            if ((de >> i) & 1) == 0 { continue; }
            let e = op(v, i);
            if vals[e].kind == VK_POISON { continue; }
            if vals[e].kind != VK_CINT { return kb_unknown(w); }
            let x = const_int_bits(e);
            r.z &= ~x;
            r.o &= x;
        }
        if kb_has_conflict(r) { return kb_unknown(w); }
        return r;
    }
    if k == VK_UNDEF || k == VK_POISON { return kb_unknown(w); }
    if is_constant_data(v) { fatal("internal: unhandled constant data in computeKnownBits"); }
    var known = kb_unknown(w);
    if k == VK_ARG {
        let f = args_parent[vals[v].sub];
        let l = globs[glob_of(f)].attrs;
        if aset_has(alist_param(l, args_no[vals[v].sub] as i64), AK_Range) { not_ported("known bits from an argument range attribute"); }
    }
    if depth == MAX_ANALYSIS_DEPTH { return known; }
    if k == VK_ALIAS { not_ported("global aliases"); }
    if k == VK_CEXPR { not_ported("constant expressions"); }
    if k == VK_INST { known = kb_from_operator(v, de, known, depth); }
    return known;
}

// m_APInt: a ConstantInt or a splat vector of one.
fn match_apint(v: i32) -> bool {
    let k = vals[v].kind;
    if k == VK_CINT { return true; }
    if k == VK_CDVECTOR || k == VK_CVECTOR {
        if nops(v) == 0 { return false; }
        let e0 = op(v, 0);
        if vals[e0].kind != VK_CINT { return false; }
        for i in nops(v) { if op(v, i) != e0 { return false; } }
        return true;
    }
    return false;
}
fn apint_value(v: i32) -> u64 { if vals[v].kind == VK_CINT { cint_lo(v) } else { cint_lo(op(v, 0)) } }

fn is_neg_of(n: i32, x: i32) -> bool {
    // m_Neg(X): sub 0, X
    return is_inst(n) && iop(n) == OP_SUB && op(n, 1) == x && is_constant(op(n, 0)) && is_null_value(op(n, 0));
}
fn is_all_ones(v: i32) -> bool {
    if !match_apint(v) { return false; }
    let w = ty_bits(ty_scalar(vals[v].ty));
    return apint_value(v) == wmask(w);
}

recursive fn kb_and_xor_or(iv: i32, de: u64, kl: KB, kr: KB, depth: i64) -> KB {
    let w = kl.w as i64;
    let o = iop(iv);
    var out = kb_unknown(w);
    let a = op(iv, 0);
    let b = op(iv, 1);
    let has_one = kl.o != 0 || kr.o != 0;
    var is_and = false;
    if o == OP_AND {
        out = kb_and(kl, kr);
        is_and = true;
        if has_one && (is_neg_of(b, a) || is_neg_of(a, b)) { not_ported("and(x, -x)"); }
    } else if o == OP_OR {
        out = kb_or(kl, kr);
    } else {
        out = kb_xor(kl, kr);
        if has_one {
            fn is_dec(y: i32, x: i32) -> bool { is_inst(y) && iop(y) == OP_ADD && op(y, 0) == x && is_all_ones(op(y, 1)) }
            if is_dec(b, a) || is_dec(a, b) { not_ported("xor(x, x - 1)"); }
        }
    }
    if ((out.z | out.o) & 1) == 0 {
        // and/xor/or(x, add(x, y)) / (x, sub(x, y)) / (x, sub(y, x))
        fn pat(x: i32, y: i32) -> i32 {
            if !is_inst(y) { return -1; }
            let yo = iop(y);
            if yo == OP_ADD { if op(y, 0) == x { return op(y, 1); } if op(y, 1) == x { return op(y, 0); } }
            if yo == OP_SUB { if op(y, 0) == x { return op(y, 1); } if op(y, 1) == x { return op(y, 0); } }
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

recursive fn kb_from_operator(iv: i32, de: u64, known0: KB, depth: i64) -> KB {
    let w = known0.w as i64;
    var known = known0;
    let o = iop(iv);
    let ii = inst_of(iv);
    kb_check_context(inst_func(iv));
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
    if o == OP_MUL {
        let nsw = (insts[ii].flags & FL_NSW) != 0;
        let nuw = (insts[ii].flags & FL_NUW) != 0;
        let a = op(iv, 0);
        let b = op(iv, 1);
        let k1 = kb_compute(b, de, depth + 1);
        let k2 = kb_compute(a, de, depth + 1);
        if a == b { not_ported("self multiplication"); }
        var is_nonneg = false;
        var is_negr = false;
        if nsw {
            let nn1 = kb_is_nonneg(k1);
            let nn0 = kb_is_nonneg(k2);
            let ng1 = kb_is_neg(k1);
            let ng0 = kb_is_neg(k2);
            is_nonneg = (ng1 && ng0) || (nn1 && nn0);
            if !is_nonneg && nuw { not_ported("mul nuw nsw sign reasoning"); }
            if !is_nonneg { is_negr = (ng1 && nn0 && kb_is_nonzero(k2)) || (ng0 && nn1 && kb_is_nonzero(k1)); }
        }
        known = kb_mul(k1, k2, false);
        if is_nonneg && !kb_is_neg(known) { known = kb_make_nonneg(known); }
        else if is_negr && !kb_is_nonneg(known) { known = kb_make_neg(known); }
        return known;
    }
    if o == OP_UDIV || o == OP_SDIV || o == OP_UREM || o == OP_SREM { not_ported("division/remainder"); }
    if o == OP_SELECT {
        let c = op(iv, 0);
        let k1 = kb_compute(op(iv, 1), de, depth + 1);
        let k2 = kb_compute(op(iv, 2), de, depth + 1);
        // adjustKnownBitsForSelectArm: a condition can refine a non-constant arm
        if (!kb_is_constant(k1) || !kb_is_constant(k2)) && is_inst(c) {
            let co = iop(c);
            if co == OP_ICMP || co == OP_AND || co == OP_OR || co == OP_XOR || co == OP_TRUNC || co == OP_FCMP {
                not_ported("select arms refined by the condition");
            }
        }
        return kb_intersect(k1, k2);
    }
    if o == OP_FPTRUNC || o == OP_FPEXT || o == OP_FPTOUI || o == OP_FPTOSI || o == OP_SITOFP || o == OP_UITOFP { return known; }
    if o == OP_PTRTOINT || o == OP_PTRTOADDR || o == OP_INTTOPTR { not_ported("ptrtoint/inttoptr"); }
    if o == OP_ZEXT || o == OP_TRUNC {
        let src = op(iv, 0);
        let sw = kb_width(src);
        var k = kb_compute(src, de, depth + 1);
        if o == OP_ZEXT && (insts[ii].flags & FL_NNEG) != 0 && !kb_is_neg(k) { k = kb_make_nonneg(k); }
        return kb_zext_or_trunc(k, w);
    }
    if o == OP_BITCAST {
        let src = op(iv, 0);
        let st = vals[src].ty;
        if ty_is_int(st) && !ty_is_vector(vals[iv].ty) { return kb_compute_all(src, depth + 1); }
        not_ported("bitcast of vectors or floating point");
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
        var sa_nonzero = kb_is_nonzero(k1);
        if !sa_nonzero && kb_max(k1) < (k1.w as u64) {
            // isKnownNonZero(shift amount)
            if !is_constant(b) { not_ported("isKnownNonZero of a bounded shift amount"); }
            sa_nonzero = !is_null_value(b);
        }
        if o == OP_SHL {
            let nuw = (insts[ii].flags & FL_NUW) != 0;
            let nsw = (insts[ii].flags & FL_NSW) != 0;
            known = kb_shl(k2, k1, nuw, nsw, sa_nonzero);
            if match_apint(a) { known.z |= low_bits(ctz_w(apint_value(a), w)); }
            // shl X, sub(C, xor(ctlz(X, true), BW-1))
            if is_inst(b) && iop(b) == OP_SUB && match_apint(op(b, 0)) { let x = op(b, 1); if is_inst(x) && iop(x) == OP_XOR { not_ported("shl msb pattern"); } }
            return known;
        }
        let exact = (insts[ii].flags & FL_EXACT) != 0;
        known = kb_shr(k2, k1, sa_nonzero, exact, o == OP_ASHR);
        if o == OP_LSHR && match_apint(a) { known.z |= high_bits(w, clz_w(apint_value(a), w)); }
        return known;
    }
    if o == OP_ADD || o == OP_SUB {
        let add = o == OP_ADD;
        let nsw = (insts[ii].flags & FL_NSW) != 0;
        let nuw = (insts[ii].flags & FL_NUW) != 0;
        let a = op(iv, 0);
        let b = op(iv, 1);
        let kr = kb_compute(b, de, depth + 1);
        if kb_is_unknown(kr) && !nsw && !nuw {
            if add { kb_check_lerp(a, b); }
            return kr;
        }
        let kl = kb_compute(a, de, depth + 1);
        var out = kb_add_sub(add, nsw, nuw, kl, kr);
        if !add && nsw && !kb_is_nonneg(out) {
            if implied_by_dom_condition(P_SLE, b, a, kb_cxt) == 1 || (inst_iid(b) == IID_smin && (op(b, 0) == a || op(b, 1) == a)) {
                out = kb_make_nonneg(out);
            }
        }
        if add { kb_check_lerp(a, b); }
        return out;
    }
    if o == OP_ALLOCA || o == OP_GEP { not_ported("known bits of a pointer"); }
    if o == OP_PHI { not_ported("known bits of a PHI"); }
    if o == OP_CALL || o == OP_INVOKE {
        let rm = inst_get_md(iv, md_kind_id("range"));
        if rm >= 0 { known = kb_from_range_md(rm, w); }
        if aset_has(alist_ret(insts[ii].attrs), AK_Range) { not_ported("a call's range attribute"); }
        let c = cb_callee(iv);
        if c >= 0 && vals[c].kind == VK_FUNC && aset_has(alist_ret(globs[glob_of(c)].attrs), AK_Range) { not_ported("a callee's range attribute"); }
        for k in cb_nargs(iv) {
            if aset_has(alist_param(insts[ii].attrs, k), AK_Returned) { not_ported("returned arguments"); }
            if c >= 0 && vals[c].kind == VK_FUNC && aset_has(alist_param(globs[glob_of(c)].attrs, k), AK_Returned) { not_ported("returned arguments"); }
        }
        let id = call_iid(iv);
        if id == 0 { return known; }
        if id == IID_bitreverse || id == IID_bswap {
            let k2 = kb_compute(op(iv, 0), de, depth + 1);
            let t = if id == IID_bswap { KB { z: byte_swap_w(k2.z, w), o: byte_swap_w(k2.o, w), w: k2.w } }
                    else { KB { z: reverse_bits_w(k2.z, w), o: reverse_bits_w(k2.o, w), w: k2.w } };
            return kb_union(known, t);
        }
        if id == IID_ctlz || id == IID_cttz {
            let k2 = kb_compute(op(iv, 0), de, depth + 1);
            var p = if id == IID_ctlz { kb_max_lz(k2) } else { kb_max_tz(k2) };
            let flag = op(iv, 1);
            if is_cint(flag) && cint_lo(flag) == 1 { p = min(p, w - 1); }
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
            let sa = op(iv, 2);
            if !match_apint(sa) { return known; }
            let k2 = kb_compute(op(iv, 0), de, depth + 1);
            let k3 = kb_compute(op(iv, 1), de, depth + 1);
            return kb_fsh(k2, k3, apint_value(sa), id == IID_fshl);
        }
        if id == IID_umin || id == IID_umax || id == IID_smin || id == IID_smax {
            let k1 = kb_compute(op(iv, 0), de, depth + 1);
            let k2 = kb_compute(op(iv, 1), de, depth + 1);
            if id == IID_umin { return kb_umin(k1, k2); }
            if id == IID_umax { return kb_umax(k1, k2); }
            // unionWithMinMaxIntrinsicClamp
            let inner = op(iv, 0);
            let inv = if id == IID_smin { IID_smax } else { IID_smin };
            if inst_iid(inner) == inv && match_apint(op(iv, 1)) && match_apint(op(inner, 1)) { not_ported("smin/smax clamp"); }
            if id == IID_smin { return kb_smin_op(k1, k2); }
            return kb_smax_op(k1, k2);
        }
        if id == IID_clmul {
            let k1 = kb_compute(op(iv, 0), de, depth + 1);
            let k2 = kb_compute(op(iv, 1), de, depth + 1);
            return kb_clmul(k1, k2);
        }
        if id == IID_abs || id == IID_uadd_sat || id == IID_usub_sat || id == IID_sadd_sat ||
           id == IID_ssub_sat || id == IID_vector_reverse || id == IID_vector_reduce_and || id == IID_vector_reduce_or ||
           id == IID_vector_reduce_umax || id == IID_vector_reduce_umin || id == IID_vector_reduce_smax ||
           id == IID_vector_reduce_smin || id == IID_vector_reduce_xor || id == IID_vector_reduce_add ||
           id == IID_ptrmask || id == IID_vscale {
            not_ported(str("known bits of ", intr_name(id as i64)));
        }
        return known;
    }
    if o == OP_SHUFFLEVECTOR {
        // getSplatValue / getShuffleDemandedElts
        let a = op(iv, 0);
        let b = op(iv, 1);
        let nin = ty_count(vals[a].ty);
        var dl: u64 = 0;
        var dr: u64 = 0;
        let x = insts[ii];
        var splat_src: i64 = -2;
        for i in x.naux {
            let mv = ints[x.aux + i] as i64;
            if mv != splat_src { splat_src = if splat_src == -2 { mv } else { -3 }; }
            if ((de >> i) & 1) == 0 { continue; }
            if mv < 0 { return kb_unknown(w); }
            if mv < nin { dl |= (1 as u64) << mv; } else { dr |= (1 as u64) << (mv - nin); }
        }
        if splat_src >= 0 && x.naux > 0 { not_ported("shufflevector splats (getSplatValue)"); }
        known = kb_all_conflict(w);
        if dl != 0 {
            known = kb_compute(a, dl, depth + 1);
            if kb_is_unknown(known) { return known; }
        }
        if dr != 0 {
            let k2 = kb_compute(b, dr, depth + 1);
            known = kb_intersect(known, k2);
        }
        return known;
    }
    if o == OP_INSERTELEMENT {
        let vec = op(iv, 0);
        let elt = op(iv, 1);
        let idx = op(iv, 2);
        let n = ty_count(vals[iv].ty);
        var dv = de;
        var needs = true;
        if is_cint(idx) && cint_lo(idx) < n as u64 {
            let ci = cint_lo(idx) as i64;
            dv &= ~((1 as u64) << ci);
            needs = ((de >> ci) & 1) != 0;
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
        if is_cint(idx) && cint_lo(idx) < n as u64 { dv = (1 as u64) << cint_lo(idx); }
        return kb_compute(vec, dv, depth + 1);
    }
    if o == OP_EXTRACTVALUE {
        let agg = op(iv, 0);
        let id = inst_iid(agg);
        if id != 0 && insts[ii].naux == 1 && ints[insts[ii].aux] == 0 {
            if id == IID_uadd_with_overflow || id == IID_sadd_with_overflow || id == IID_usub_with_overflow ||
               id == IID_ssub_with_overflow || id == IID_umul_with_overflow || id == IID_smul_with_overflow {
                not_ported("extractvalue of an overflow intrinsic");
            }
        }
        return known;
    }
    if o == OP_FREEZE { not_ported("freeze (isGuaranteedNotToBePoison)"); }
    return known;
}

// computeKnownBitsFromLerpPattern: detect a * (b - c) + c * d (scalar only) and refuse.
fn lerp_c(x: i32) -> i32 {
    if !is_inst(x) { return -1; }
    let o = iop(x);
    if o == OP_SUB && (insts[inst_of(x)].flags & FL_NUW) != 0 { return op(x, 1); }
    if o == OP_XOR { return op(x, 0); }
    return -1;
}
fn lerp_lhs_c(x: i32) -> i32 {
    if is_inst(x) && iop(x) == OP_MUL {
        let c1 = lerp_c(op(x, 1));
        if c1 >= 0 { return c1; }
        let c0 = lerp_c(op(x, 0));
        if c0 >= 0 { return c0; }
    }
    return lerp_c(x);
}
fn lerp_match(l: i32, r: i32) -> bool {
    let c = lerp_lhs_c(l);
    if c < 0 { return false; }
    if r == c { return true; }
    return is_inst(r) && iop(r) == OP_MUL && (op(r, 0) == c || op(r, 1) == c);
}
fn kb_check_lerp(a: i32, b: i32) {
    if ty_is_vector(vals[a].ty) { return; }
    if lerp_match(a, b) || lerp_match(b, a) { not_ported("the lerp pattern a * (b - c) + c * d"); }
}
