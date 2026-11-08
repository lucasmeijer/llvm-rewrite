// ValueLatticeElement: a port of llvm/include/llvm/Analysis/ValueLattice.h and llvm/lib/Analysis/ValueLattice.cpp.
// A plain value type (no ownership): tag, NumRangeExtensions, constant id (constant / notconstant) and range.
//
// Reusable API (prefix vl_): vl_unknown/vl_get(c)/vl_get_not(c)/vl_get_range(cr, may_include_undef)/vl_overdefined;
// predicates vl_is_*; vl_mark_* and vl_merge_in (take the element by reference and return "changed");
// vl_as_range(l, w, undef_allowed); vl_get_compare (getCompare); vl_intersect; vl_as_constant_integer.
// MergeOptions are VLOpts { may_include_undef, check_widen, max_widen_steps } (vl_opts() = defaults,
// vl_opts_widen(n) = setMaxWidenSteps(n)).
import std;
import ir;
import irutil;
import apint;
import constrange;
import constfold;
import cfold;
import implied;

let VL_UNKNOWN: u8 = 0;
let VL_UNDEF: u8 = 1;
let VL_CONSTANT: u8 = 2;
let VL_NOTCONSTANT: u8 = 3;
let VL_RANGE: u8 = 4;
let VL_RANGE_UNDEF: u8 = 5;      // constantrange_including_undef
let VL_OVERDEFINED: u8 = 6;

struct VL { tag: u8, nre: u8, c: i32, r: CRange }
struct VLOpts { may_include_undef: bool, check_widen: bool, max_widen_steps: i64 }

fn vl_opts() -> VLOpts { VLOpts { may_include_undef: false, check_widen: false, max_widen_steps: 1 } }
fn vl_opts_widen(n: i64) -> VLOpts { VLOpts { may_include_undef: false, check_widen: true, max_widen_steps: n } }

fn vl_unknown() -> VL { VL { tag: VL_UNKNOWN, nre: 0, c: -1, r: rg_empty(1) } }
fn vl_overdefined() -> VL { VL { tag: VL_OVERDEFINED, nre: 0, c: -1, r: rg_empty(1) } }
fn vl_get(c: i32) -> VL { var r = vl_unknown(); vl_mark_constant(r, c, false); return r; }
fn vl_get_not(c: i32) -> VL {
    if vals[c].kind == VK_UNDEF || vals[c].kind == VK_POISON { fatal("ValueLattice: != undef is not supported"); }
    var r = vl_unknown(); vl_mark_not_constant(r, c); return r;
}
fn vl_get_range(cr: CRange, may_include_undef: bool) -> VL {
    if rg_is_full(cr) { return vl_overdefined(); }
    var r = vl_unknown();
    if rg_is_empty(cr) {
        if may_include_undef { vl_mark_undef(r); }
        return r;
    }
    var o = vl_opts();
    o.may_include_undef = may_include_undef;
    vl_mark_constant_range(r, cr, o);
    return r;
}

fn vl_is_undef(l: VL) -> bool { l.tag == VL_UNDEF }
fn vl_is_unknown(l: VL) -> bool { l.tag == VL_UNKNOWN }
fn vl_is_unknown_or_undef(l: VL) -> bool { l.tag == VL_UNKNOWN || l.tag == VL_UNDEF }
fn vl_is_constant(l: VL) -> bool { l.tag == VL_CONSTANT }
fn vl_is_not_constant(l: VL) -> bool { l.tag == VL_NOTCONSTANT }
fn vl_is_range_including_undef(l: VL) -> bool { l.tag == VL_RANGE_UNDEF }
fn vl_is_range(l: VL, undef_allowed: bool) -> bool {
    return l.tag == VL_RANGE || (l.tag == VL_RANGE_UNDEF && (undef_allowed || rg_is_single(l.r)));
}
fn vl_is_overdefined(l: VL) -> bool { l.tag == VL_OVERDEFINED }

fn vl_is_undef_const(c: i32) -> bool { vals[c].kind == VK_UNDEF || vals[c].kind == VK_POISON }

// asConstantRange(BW, UndefAllowed)
fn vl_as_range(l: VL, w: i64, undef_allowed: bool) -> CRange {
    if vl_is_range(l, undef_allowed) { return l.r; }
    if vl_is_constant(l) { return rg_of_const(l.c); }
    if vl_is_unknown(l) { return rg_empty(w); }
    return rg_full(w);
}
fn vl_as_range_ty(l: VL, ty: i32, undef_allowed: bool) -> CRange { vl_as_range(l, ty_bits(ty_scalar(ty)), undef_allowed) }
// asConstantInteger: (ok, value)
fn vl_as_constant_integer(l: VL) -> bool, AP {
    if vl_is_constant(l) && vals[l.c].kind == VK_CINT { return true, ap_from_cint(l.c); }
    if vl_is_range(l, true) && rg_is_single(l.r) { return true, l.r.lo; }
    return false, ap_zero(1);
}

fn vl_mark_overdefined(l: VL&) -> bool {
    if l.tag == VL_OVERDEFINED { return false; }
    l.tag = VL_OVERDEFINED;
    return true;
}
fn vl_mark_undef(l: VL&) -> bool {
    if l.tag == VL_UNDEF { return false; }
    if l.tag != VL_UNKNOWN { fatal("ValueLattice: markUndef on a non-unknown element"); }
    l.tag = VL_UNDEF;
    return true;
}
fn vl_mark_constant(l: VL&, c: i32, may_include_undef: bool) -> bool {
    if vl_is_undef_const(c) { return vl_mark_undef(l); }
    if l.tag == VL_CONSTANT {
        if l.c != c { fatal("ValueLattice: marking constant with different value"); }
        return false;
    }
    if vals[c].kind == VK_CINT {
        var o = vl_opts();
        o.may_include_undef = may_include_undef;
        return vl_mark_constant_range(l, rg_single(ap_from_cint(c)), o);
    }
    l.tag = VL_CONSTANT;
    l.c = c;
    return true;
}
fn vl_mark_not_constant(l: VL&, c: i32) -> bool {
    if vals[c].kind == VK_CINT {
        let v = ap_from_cint(c);
        return vl_mark_constant_range(l, rg_new(ap_inc(v), v), vl_opts());
    }
    if vl_is_undef_const(c) { return false; }
    if l.tag == VL_NOTCONSTANT {
        if l.c != c { fatal("ValueLattice: marking !constant with different value"); }
        return false;
    }
    l.tag = VL_NOTCONSTANT;
    l.c = c;
    return true;
}
fn vl_mark_constant_range(l: VL&, nr: CRange, o: VLOpts) -> bool {
    if rg_is_full(nr) { return vl_mark_overdefined(l); }
    let old = l.tag;
    let nt = if l.tag == VL_UNDEF || l.tag == VL_RANGE_UNDEF || o.may_include_undef { VL_RANGE_UNDEF } else { VL_RANGE };
    if vl_is_range(l, true) {
        l.tag = nt;
        if rg_eq(l.r, nr) { return l.tag != old; }
        if o.check_widen {
            let n = (l.nre as i64) + 1;
            l.nre = if n > 255 { 255 as u8 } else { n as u8 };
            if n > o.max_widen_steps { return vl_mark_overdefined(l); }
        }
        l.r = nr;
        return true;
    }
    l.nre = 0;
    l.tag = nt;
    l.r = nr;
    return true;
}

fn vl_merge_in(l: VL&, rhs: VL, o0: VLOpts) -> bool {
    var o = o0;
    if rhs.tag == VL_UNKNOWN || l.tag == VL_OVERDEFINED { return false; }
    if rhs.tag == VL_OVERDEFINED { vl_mark_overdefined(l); return true; }
    if l.tag == VL_UNDEF {
        if rhs.tag == VL_UNDEF { return false; }
        if rhs.tag == VL_CONSTANT { return vl_mark_constant(l, rhs.c, true); }
        if vl_is_range(rhs, true) { o.may_include_undef = true; return vl_mark_constant_range(l, rhs.r, o); }
        return vl_mark_overdefined(l);
    }
    if l.tag == VL_UNKNOWN {
        // *this = RHS (the copy constructor keeps NumRangeExtensions only for ranges)
        l.tag = rhs.tag; l.c = rhs.c; l.r = rhs.r;
        l.nre = if vl_is_range(rhs, true) { rhs.nre } else { 0 as u8 };
        return true;
    }
    if l.tag == VL_CONSTANT {
        if rhs.tag == VL_CONSTANT && l.c == rhs.c { return false; }
        if rhs.tag == VL_UNDEF { return false; }
        let t = vals[l.c].ty;
        if ty_is_vector(t) && ty_is_int(ty_scalar(t)) {
            let lr = rg_of_const(l.c);
            let nr = rg_union(lr, vl_as_range(rhs, rg_w(lr), true));
            o.may_include_undef = rhs.tag == VL_RANGE_UNDEF;
            return vl_mark_constant_range(l, nr, o);
        }
        vl_mark_overdefined(l);
        return true;
    }
    if l.tag == VL_NOTCONSTANT {
        if rhs.tag == VL_NOTCONSTANT && l.c == rhs.c { return false; }
        vl_mark_overdefined(l);
        return true;
    }
    let old = l.tag;
    if rhs.tag == VL_UNDEF {
        l.tag = VL_RANGE_UNDEF;
        return old != l.tag;
    }
    let nr = rg_union(l.r, vl_as_range(rhs, rg_w(l.r), true));
    o.may_include_undef = rhs.tag == VL_RANGE_UNDEF;
    return vl_mark_constant_range(l, nr, o);
}

// getCompare(Pred, Ty, Other, DL): a constant id or -1
fn vl_get_compare(a: VL, p: i64, ty: i32, b: VL) -> i32 {
    if vl_is_unknown(a) || vl_is_unknown(b) { return -1; }
    if vl_is_undef(a) || vl_is_undef(b) { return -1; }
    if vl_is_constant(a) && vl_is_constant(b) { return cf_fold_cmp_operands(p, a.c, b.c, -1); }
    if p == P_EQ || p == P_NE {
        if (vl_is_not_constant(a) && vl_is_constant(b) && a.c == b.c) || (vl_is_constant(a) && vl_is_not_constant(b) && a.c == b.c) {
            return vl_bool_const(ty, p == P_NE);
        }
    }
    if !vl_is_range(a, true) || !vl_is_range(b, true) { return -1; }
    if p >= 32 && p <= 41 {
        if rg_icmp(p, a.r, b.r) { return vl_bool_const(ty, true); }
        if rg_icmp(rg_icmp_inverse(p), a.r, b.r) { return vl_bool_const(ty, false); }
        return -1;
    }
    // FCmp predicates on ranges: ConstantRange::icmp would hit llvm_unreachable; ranges of FP values do not occur
    fatal("ValueLattice: getCompare with an fcmp predicate on integer ranges");
    return -1;
}
fn vl_bool_const(ty: i32, b: bool) -> i32 {
    let c = if b { c_true() } else { c_false() };
    if ty_is_vector(ty) { return c_splat(ty, c); }
    return c;
}

fn vl_has_single_value(l: VL) -> bool {
    if vl_is_range(l, true) && rg_is_single(l.r) { return true; }
    return vl_is_constant(l);
}
fn vl_intersect(a: VL, b: VL) -> VL {
    if vl_is_unknown(a) { return a; }
    if vl_is_unknown(b) { return b; }
    if vl_is_overdefined(a) { return b; }
    if vl_is_overdefined(b) { return a; }
    if vl_has_single_value(a) { return a; }
    if vl_has_single_value(b) { return b; }
    if !vl_is_range(a, true) || !vl_is_range(b, true) { return a; }
    let r = rg_intersect(a.r, b.r);
    return vl_get_range(r, vl_is_range_including_undef(a) || vl_is_range_including_undef(b));
}
