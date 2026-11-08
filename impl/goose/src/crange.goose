// ConstantRange: port of llvm/lib/IR/ConstantRange.cpp (the parts the analyses use) for bit widths up to 64.
// A range is [lo, hi) modulo 2^w; lo == hi is the full set when lo is the max value, empty when lo is 0.
import std;
import ir;
import knownbits;
import constrange;

struct CR { lo: u64, hi: u64, w: i32 }

fn cr_m(w: i64) -> u64 { if w >= 64 { 0xFFFFFFFFFFFFFFFF } else { ((1 as u64) << w) - 1 } }
fn cr_sb(w: i64) -> u64 { (1 as u64) << (w - 1) }
fn cr_new(lo: u64, hi: u64, w: i64) -> CR { let m = cr_m(w); CR { lo: lo & m, hi: hi & m, w: w as i32 } }
fn cr_full(w: i64) -> CR { cr_new(cr_m(w), cr_m(w), w) }
fn cr_empty(w: i64) -> CR { cr_new(0, 0, w) }
fn cr_single(x: u64, w: i64) -> CR { cr_new(x, x + 1, w) }
fn cr_nonempty(lo: u64, hi: u64, w: i64) -> CR { let m = cr_m(w); if (lo & m) == (hi & m) { cr_full(w) } else { cr_new(lo, hi, w) } }
fn cr_is_full(c: CR) -> bool { c.lo == c.hi && c.lo == cr_m(c.w as i64) }
fn cr_is_empty(c: CR) -> bool { c.lo == c.hi && c.lo == 0 }
fn cr_eq(a: CR, b: CR) -> bool { a.lo == b.lo && a.hi == b.hi }

fn cr_slt(a: u64, b: u64, w: i64) -> bool { (a ^ cr_sb(w)) < (b ^ cr_sb(w)) }
fn cr_sle(a: u64, b: u64, w: i64) -> bool { (a ^ cr_sb(w)) <= (b ^ cr_sb(w)) }

fn cr_is_upper_wrapped(c: CR) -> bool { c.lo > c.hi }
fn cr_is_wrapped(c: CR) -> bool { c.lo > c.hi && c.hi != 0 }
fn cr_is_upper_sign_wrapped(c: CR) -> bool { cr_slt(c.hi, c.lo, c.w as i64) }
fn cr_is_sign_wrapped(c: CR) -> bool { cr_slt(c.hi, c.lo, c.w as i64) && c.hi != cr_sb(c.w as i64) }

fn cr_umax(c: CR) -> u64 { if cr_is_full(c) || cr_is_upper_wrapped(c) { cr_m(c.w as i64) } else { (c.hi - 1) & cr_m(c.w as i64) } }
fn cr_umin(c: CR) -> u64 { if cr_is_full(c) || cr_is_wrapped(c) { 0 } else { c.lo } }
fn cr_smax(c: CR) -> u64 { if cr_is_full(c) || cr_is_upper_sign_wrapped(c) { cr_sb(c.w as i64) - 1 } else { (c.hi - 1) & cr_m(c.w as i64) } }
fn cr_smin(c: CR) -> u64 { if cr_is_full(c) || cr_is_sign_wrapped(c) { cr_sb(c.w as i64) } else { c.lo } }

// getSingleElement: true + value
fn cr_is_single(c: CR) -> bool { c.hi == ((c.lo + 1) & cr_m(c.w as i64)) && !(c.lo == c.hi) }
fn cr_is_single_missing(c: CR) -> bool { c.lo == ((c.hi + 1) & cr_m(c.w as i64)) && !(c.lo == c.hi) }

fn cr_contains_val(c: CR, v: u64) -> bool {
    if c.lo == c.hi { return cr_is_full(c); }
    if !cr_is_upper_wrapped(c) { return c.lo <= v && v < c.hi; }
    return c.lo <= v || v < c.hi;
}

fn cr_contains(a: CR, b: CR) -> bool {
    if cr_is_full(a) || cr_is_empty(b) { return true; }
    if cr_is_empty(a) || cr_is_full(b) { return false; }
    if !cr_is_upper_wrapped(a) {
        if cr_is_upper_wrapped(b) { return false; }
        return a.lo <= b.lo && b.hi <= a.hi;
    }
    if !cr_is_upper_wrapped(b) { return b.hi <= a.hi || a.lo <= b.lo; }
    return b.hi <= a.hi && a.lo <= b.lo;
}

fn cr_inverse(c: CR) -> CR {
    if cr_is_full(c) { return cr_empty(c.w as i64); }
    if cr_is_empty(c) { return cr_full(c.w as i64); }
    return CR { lo: c.hi, hi: c.lo, w: c.w };
}

fn cr_size_strictly_smaller(a: CR, b: CR) -> bool {
    if cr_is_full(a) { return false; }
    if cr_is_full(b) { return true; }
    let m = cr_m(a.w as i64);
    return ((a.hi - a.lo) & m) < ((b.hi - b.lo) & m);
}

let CR_SMALLEST = 0;
let CR_UNSIGNED = 1;
let CR_SIGNED = 2;

fn cr_preferred(a: CR, b: CR, t: i64) -> CR {
    if t == CR_UNSIGNED {
        if !cr_is_wrapped(a) && cr_is_wrapped(b) { return a; }
        if cr_is_wrapped(a) && !cr_is_wrapped(b) { return b; }
    } else if t == CR_SIGNED {
        if !cr_is_sign_wrapped(a) && cr_is_sign_wrapped(b) { return a; }
        if cr_is_sign_wrapped(a) && !cr_is_sign_wrapped(b) { return b; }
    }
    if cr_size_strictly_smaller(a, b) { return a; }
    return b;
}

recursive fn cr_intersect_t(a: CR, b: CR, t: i64) -> CR {
    let w = a.w as i64;
    if cr_is_empty(a) || cr_is_full(b) { return a; }
    if cr_is_empty(b) || cr_is_full(a) { return b; }
    if !cr_is_upper_wrapped(a) && cr_is_upper_wrapped(b) { return cr_intersect_t(b, a, t); }
    if !cr_is_upper_wrapped(a) && !cr_is_upper_wrapped(b) {
        if a.lo < b.lo {
            if a.hi <= b.lo { return cr_empty(w); }
            if a.hi < b.hi { return cr_new(b.lo, a.hi, w); }
            return b;
        }
        if a.hi < b.hi { return a; }
        if a.lo < b.hi { return cr_new(a.lo, b.hi, w); }
        return cr_empty(w);
    }
    if cr_is_upper_wrapped(a) && !cr_is_upper_wrapped(b) {
        if b.lo < a.hi {
            if b.hi < a.hi { return b; }
            if b.hi <= a.lo { return cr_new(b.lo, a.hi, w); }
            return cr_preferred(a, b, t);
        }
        if b.lo < a.lo {
            if b.hi <= a.lo { return cr_empty(w); }
            return cr_new(a.lo, b.hi, w);
        }
        return b;
    }
    if b.hi < a.hi {
        if b.lo < a.hi { return cr_preferred(a, b, t); }
        if b.lo < a.lo { return cr_new(a.lo, b.hi, w); }
        return b;
    }
    if b.hi <= a.lo {
        if b.lo < a.lo { return a; }
        return cr_new(b.lo, a.hi, w);
    }
    return cr_preferred(a, b, t);
}
fn cr_intersect(a: CR, b: CR) -> CR { cr_intersect_t(a, b, CR_SMALLEST) }

recursive fn cr_union_t(a: CR, b: CR, t: i64) -> CR {
    let w = a.w as i64;
    let m = cr_m(w);
    if cr_is_full(a) || cr_is_empty(b) { return a; }
    if cr_is_full(b) || cr_is_empty(a) { return b; }
    if !cr_is_upper_wrapped(a) && cr_is_upper_wrapped(b) { return cr_union_t(b, a, t); }
    if !cr_is_upper_wrapped(a) && !cr_is_upper_wrapped(b) {
        if b.hi < a.lo || a.hi < b.lo { return cr_preferred(cr_new(a.lo, b.hi, w), cr_new(b.lo, a.hi, w), t); }
        let l = if b.lo < a.lo { b.lo } else { a.lo };
        let u = if ((b.hi - 1) & m) > ((a.hi - 1) & m) { b.hi } else { a.hi };
        if l == 0 && u == 0 { return cr_full(w); }
        return cr_new(l, u, w);
    }
    if !cr_is_upper_wrapped(b) {
        if b.hi <= a.hi || b.lo >= a.lo { return a; }
        if b.lo <= a.hi && a.lo <= b.hi { return cr_full(w); }
        if a.hi < b.lo && b.hi < a.lo { return cr_preferred(cr_new(a.lo, b.hi, w), cr_new(b.lo, a.hi, w), t); }
        if a.hi < b.lo && a.lo <= b.hi { return cr_new(b.lo, a.hi, w); }
        return cr_new(a.lo, b.hi, w);
    }
    if b.lo <= a.hi || a.lo <= b.hi { return cr_full(w); }
    let l = if b.lo < a.lo { b.lo } else { a.lo };
    let u = if b.hi > a.hi { b.hi } else { a.hi };
    return cr_new(l, u, w);
}
fn cr_union(a: CR, b: CR) -> CR { cr_union_t(a, b, CR_SMALLEST) }

let CRP_EQ = 32;
let CRP_NE = 33;
let CRP_UGT = 34;
let CRP_UGE = 35;
let CRP_ULT = 36;
let CRP_ULE = 37;
let CRP_SGT = 38;
let CRP_SGE = 39;
let CRP_SLT = 40;
let CRP_SLE = 41;

// makeAllowedICmpRegion(Pred, CR) for a plain predicate
fn cr_allowed_icmp(p: i64, c: CR) -> CR {
    let w = c.w as i64;
    let m = cr_m(w);
    if cr_is_empty(c) { return c; }
    if p == CRP_EQ { return c; }
    if p == CRP_NE { if cr_is_single(c) { return CR { lo: c.hi, hi: c.lo, w: c.w }; } return cr_full(w); }
    if p == CRP_ULT { let u = cr_umax(c); if u == 0 { return cr_empty(w); } return cr_new(0, u, w); }
    if p == CRP_SLT { let s = cr_smax(c); if s == cr_sb(w) { return cr_empty(w); } return cr_new(cr_sb(w), s, w); }
    if p == CRP_ULE { return cr_nonempty(0, cr_umax(c) + 1, w); }
    if p == CRP_SLE { return cr_nonempty(cr_sb(w), cr_smax(c) + 1, w); }
    if p == CRP_UGT { let u = cr_umin(c); if u == m { return cr_empty(w); } return cr_new(u + 1, 0, w); }
    if p == CRP_SGT { let s = cr_smin(c); if s == cr_sb(w) - 1 { return cr_empty(w); } return cr_new(s + 1, cr_sb(w), w); }
    if p == CRP_UGE { return cr_nonempty(cr_umin(c), 0, w); }
    if p == CRP_SGE { return cr_nonempty(cr_smin(c), cr_sb(w), w); }
    fatal("internal: makeAllowedICmpRegion predicate");
    return c;
}
fn cr_pred_inverse(p: i64) -> i64 {
    match p { 32 => 33, 33 => 32, 34 => 37, 35 => 36, 36 => 35, 37 => 34, 38 => 41, 39 => 40, 40 => 39, 41 => 38, _ => p }
}
fn cr_satisfying_icmp(p: i64, c: CR) -> CR { cr_inverse(cr_allowed_icmp(cr_pred_inverse(p), c)) }
fn cr_exact_icmp(p: i64, x: u64, w: i64) -> CR { cr_allowed_icmp(p, cr_single(x, w)) }

// ConstantRange::icmp
fn cr_icmp(p: i64, a: CR, b: CR) -> bool {
    let w = a.w as i64;
    if cr_is_empty(a) || cr_is_empty(b) { return true; }
    if p == CRP_EQ { return cr_is_single(a) && cr_is_single(b) && a.lo == b.lo; }
    if p == CRP_NE { return cr_contains(cr_inverse(a), b); }
    if p == CRP_ULT { return cr_umax(a) < cr_umin(b); }
    if p == CRP_ULE { return cr_umax(a) <= cr_umin(b); }
    if p == CRP_UGT { return cr_umin(a) > cr_umax(b); }
    if p == CRP_UGE { return cr_umin(a) >= cr_umax(b); }
    if p == CRP_SLT { return cr_slt(cr_smax(a), cr_smin(b), w); }
    if p == CRP_SLE { return cr_sle(cr_smax(a), cr_smin(b), w); }
    if p == CRP_SGT { return cr_slt(cr_smax(b), cr_smin(a), w); }
    if p == CRP_SGE { return cr_sle(cr_smax(b), cr_smin(a), w); }
    fatal("internal: ConstantRange::icmp predicate");
    return false;
}

fn cr_is_all_negative(c: CR) -> bool {
    if cr_is_empty(c) { return true; }
    if cr_is_full(c) { return false; }
    let w = c.w as i64;
    // !isUpperSignWrapped() && !Upper.isStrictlyPositive()
    let strictly_pos = c.hi != 0 && (c.hi & cr_sb(w)) == 0;
    return !cr_is_upper_sign_wrapped(c) && !strictly_pos;
}
fn cr_is_all_nonneg(c: CR) -> bool { !cr_is_sign_wrapped(c) && (c.lo & cr_sb(c.w as i64)) == 0 }

// fromKnownBits (through constrange.goose; fails loudly above 64 bits)
fn cr_from_kb(k: KB, signed: bool) -> CR { rg_to_cr(rg_from_kb(k, signed)) }

// add / sub (no wrap flags)
fn cr_add(a: CR, b: CR) -> CR {
    let w = a.w as i64;
    let m = cr_m(w);
    if cr_is_empty(a) || cr_is_empty(b) { return cr_empty(w); }
    if cr_is_full(a) || cr_is_full(b) { return cr_full(w); }
    let nl = (a.lo + b.lo) & m;
    let nu = (a.hi + b.hi - 1) & m;
    if nl == nu { return cr_full(w); }
    let x = cr_new(nl, nu, w);
    if cr_size_strictly_smaller(x, a) || cr_size_strictly_smaller(x, b) { return cr_full(w); }
    return x;
}
fn cr_sub(a: CR, b: CR) -> CR {
    let w = a.w as i64;
    let m = cr_m(w);
    if cr_is_empty(a) || cr_is_empty(b) { return cr_empty(w); }
    if cr_is_full(a) || cr_is_full(b) { return cr_full(w); }
    let nl = (a.lo - b.hi + 1) & m;
    let nu = (a.hi - b.lo) & m;
    if nl == nu { return cr_full(w); }
    let x = cr_new(nl, nu, w);
    if cr_size_strictly_smaller(x, a) || cr_size_strictly_smaller(x, b) { return cr_full(w); }
    return x;
}

fn cr_active_bits(x: u64) -> i64 { if x == 0 { 0 } else { 64 - clz(x) } }
fn cr_countr_one(x: u64) -> i64 { ctz(~x) }

// ConstantRange::truncate(DstTySize) (NoWrapKind = 0)
fn cr_truncate(c: CR, dw: i64) -> CR {
    let sw = c.w as i64;
    if dw == sw { return c; }
    if cr_is_empty(c) { return cr_empty(dw); }
    if cr_is_full(c) { return cr_full(dw); }
    var lo = c.lo;
    var up = c.hi;
    var uni = cr_empty(dw);
    if cr_is_upper_wrapped(c) {
        if cr_active_bits(c.hi) > dw { return cr_full(dw); }
        if cr_countr_one(c.hi) == dw { return cr_full(dw); }
        uni = cr_new(cr_m(dw), c.hi & cr_m(dw), dw);
        up = cr_m(sw);
        if lo == up { return uni; }
    }
    if cr_active_bits(lo) > dw {
        let adj = lo & ~cr_m(dw);
        lo = lo - adj;
        up = (up - adj) & cr_m(sw);
    }
    let udw = cr_active_bits(up);
    if udw <= dw { return cr_union(cr_new(lo, up, dw), uni); }
    if udw == dw + 1 {
        up = up & ~((1 as u64) << dw);
        if up < lo { return cr_union(cr_new(lo, up, dw), uni); }
    }
    return cr_full(dw);
}

// ---------------------------------------------------------------------------------------------
// Added for BasicAA (L1.analysis.aa): extensions, sextOrTrunc, smul_fast, smul_sat.

fn cr_sx(x: u64, w: i64) -> i64 { if w >= 64 { x as! i64 } else { ((x << (64 - w)) as! i64) >> (64 - w) } }

// ConstantRange::zeroExtend
fn cr_zext(c: CR, dw: i64) -> CR {
    let sw = c.w as i64;
    if cr_is_empty(c) { return cr_empty(dw); }
    if dw == sw { return c; }
    if dw > 64 { fatal("ConstantRange: widths over 64 bits are not supported"); }
    if cr_is_full(c) || cr_is_upper_wrapped(c) {
        var lo: u64 = 0;
        if c.hi == 0 { lo = c.lo; }
        return cr_new(lo, (1 as u64) << sw, dw);
    }
    return cr_new(c.lo, c.hi, dw);
}

// ConstantRange::signExtend
fn cr_sext(c: CR, dw: i64) -> CR {
    let sw = c.w as i64;
    if cr_is_empty(c) { return cr_empty(dw); }
    if dw == sw { return c; }
    if dw > 64 { fatal("ConstantRange: widths over 64 bits are not supported"); }
    let dm = cr_m(dw);
    if c.hi == cr_sb(sw) { return cr_new((cr_sx(c.lo, sw) as! u64) & dm, c.hi, dw); }
    if cr_is_full(c) || cr_is_sign_wrapped(c) {
        let lo = dm & ~cr_m(sw - 1);
        let hi = cr_m(sw - 1) + 1;
        return cr_new(lo, hi, dw);
    }
    return cr_new((cr_sx(c.lo, sw) as! u64) & dm, (cr_sx(c.hi, sw) as! u64) & dm, dw);
}

// ConstantRange::sextOrTrunc
fn cr_sext_or_trunc(c: CR, dw: i64) -> CR {
    let sw = c.w as i64;
    if sw > dw { return cr_truncate(c, dw); }
    if sw < dw { return cr_sext(c, dw); }
    return c;
}

// APInt::smul_ov at width w (values as w-bit patterns): (result, overflow)
fn cr_smul_ov(a: u64, b: u64, w: i64) -> u64, bool {
    let m = cr_m(w);
    let res = (a * b) & m;
    if (b & m) == 0 { return res, false; }
    let rs = cr_sx(res, w);
    let bs = cr_sx(b, w);
    let a_min = (a & m) == cr_sb(w);
    let b_all_ones = (b & m) == m;
    // Res.sdiv(RHS) != *this || (isMinSignedValue() && RHS.isAllOnes())
    var qbits: u64 = 0;
    if bs == -1 { qbits = ((0 as u64) - res) & m; } else { qbits = ((rs / bs) as! u64) & m; }
    return res, qbits != (a & m) || (a_min && b_all_ones);
}

// APInt::smul_sat
fn cr_smul_sat_val(a: u64, b: u64, w: i64) -> u64 {
    let r, ov = cr_smul_ov(a, b, w);
    if !ov { return r; }
    let neg = ((a & cr_sb(w)) != 0) != ((b & cr_sb(w)) != 0);
    return if neg { cr_sb(w) } else { cr_sb(w) - 1 };
}

fn cr_min_max4(x0: u64, x1: u64, x2: u64, x3: u64, w: i64) -> u64, u64 {
    var mn = x0;
    var mx = x0;
    for x in [x1, x2, x3] {
        if cr_slt(x, mn, w) { mn = x; }
        if cr_slt(mx, x, w) { mx = x; }
    }
    return mn, mx;
}

// ConstantRange::smul_fast
fn cr_smul_fast(a: CR, b: CR) -> CR {
    let w = a.w as i64;
    if cr_is_empty(a) || cr_is_empty(b) { return cr_empty(w); }
    let mn = cr_smin(a);
    let mx = cr_smax(a);
    let omn = cr_smin(b);
    let omx = cr_smax(b);
    let r1, o1 = cr_smul_ov(mn, omn, w);
    let r2, o2 = cr_smul_ov(mn, omx, w);
    let r3, o3 = cr_smul_ov(mx, omn, w);
    let r4, o4 = cr_smul_ov(mx, omx, w);
    if o1 || o2 || o3 || o4 { return cr_full(w); }
    let lo, hi = cr_min_max4(r1, r2, r3, r4, w);
    return cr_nonempty(lo, hi + 1, w);
}

// ConstantRange::smul_sat
fn cr_smul_sat(a: CR, b: CR) -> CR {
    let w = a.w as i64;
    if cr_is_empty(a) || cr_is_empty(b) { return cr_empty(w); }
    let mn = cr_smin(a);
    let mx = cr_smax(a);
    let omn = cr_smin(b);
    let omx = cr_smax(b);
    let lo, hi = cr_min_max4(cr_smul_sat_val(mn, omn, w), cr_smul_sat_val(mn, omx, w), cr_smul_sat_val(mx, omn, w), cr_smul_sat_val(mx, omx, w), w);
    return cr_nonempty(lo, hi + 1, w);
}
