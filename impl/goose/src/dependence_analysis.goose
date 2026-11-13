// DependenceAnalysis: port of llvm/lib/Analysis/DependenceAnalysis.cpp (DependenceInfo::depends with every test it
// runs: ZIV, strong / weak-crossing / exact / weak-zero SIV, exact RDIV, GCD MIV, Banerjee MIV, delinearization via
// Delinearization.cpp; Dependence / FullDependence (dump, normalize, negate); the print<da> printer) and
// ScalarEvolution::isKnownMultipleOf (ScalarEvolution.cpp).
//
// One query at a time: depends() leaves its result in the da_res_* globals (LLVM's unique_ptr<Dependence>):
// da_res_kind 0 = nullptr (no dependence), 1 = a confused Dependence, 2 = a FullDependence. The DV entries of
// the common levels are followed by the SameSD entries (DV then DVSameSD). SmallBitVectors of loop levels are u64
// masks (a nest deeper than 63 levels fails loudly). OverflowSafeSignedAPInt is (AP, valid).
import std;
import ir;
import irutil;
import flags;
import apint;
import constrange;
import instinfo;
import loopinfo;
import memloc;
import aa;
import vt;
import scev;
import scev_create;
import scev_range;
import scev_lt;
import scev_pred;
import scev_eval;
import scev_btc;
import implied;
import delinearization;
import subtarget;

let DV_NONE: u8 = 0;
let DV_LT: u8 = 1;
let DV_EQ: u8 = 2;
let DV_LE: u8 = 3;
let DV_GT: u8 = 4;
let DV_NE: u8 = 5;
let DV_GE: u8 = 6;
let DV_ALL: u8 = 7;

let DT_DEFAULT = 0;
let DT_ALL = 1;
let DT_STRONG_SIV = 2;
let DT_WEAK_CROSSING_SIV = 3;
let DT_EXACT_SIV = 4;
let DT_WEAK_ZERO_SIV = 5;
let DT_EXACT_RDIV = 6;
let DT_GCD_MIV = 7;
let DT_BANERJEE_MIV = 8;

let SUB_ZIV = 0;
let SUB_SIV = 1;
let SUB_RDIV = 2;
let SUB_MIV = 3;
let SUB_NONLINEAR = 4;

// The result of the last depends()
var da_res_kind: i64 = 0;
var da_res_src: i32 = -1;
var da_res_dst: i32 = -1;
var da_res_assume: i32 = 0;      // SCEVUnionPredicate (su id)
var da_res_levels: i64 = 0;
var da_res_samesd: i64 = 0;
var da_res_li: bool = false;     // LoopIndependent
var da_dir: u8[>..<];
var da_scalar: bool[>..<];
var da_dist: i32[>..<];          // -1 = no distance

// DependenceInfo state
var da_common: i64 = 0;          // CommonLevels
var da_src_levels: i64 = 0;      // SrcLevels
var da_max: i64 = 0;             // MaxLevels
var da_samesd_levels: i64 = 0;   // SameSDLevels
var da_test: i64 = 0;            // -da-enable-dependence-test

fn da_popcount(m: u64) -> i64 { var n: i64 = 0; var x = m; while x != 0 { x = x & (x - 1); n++; } return n; }
fn da_bit(k: i64) -> u64 { if k > 63 { fatal("DependenceAnalysis: a loop nest deeper than 63 levels is not supported"); } return (1 as u64) << (k as u64); }

fn da_test_enabled(t: i64) -> bool {
    if da_test == DT_ALL { return true; }
    if da_test == DT_DEFAULT { return t != DT_BANERJEE_MIV; }
    return da_test == t;
}
fn da_read_options() {
    da_test = DT_DEFAULT;
    if flag_given("da-enable-dependence-test") {
        let s = flag_str("da-enable-dependence-test");
        if s == "default" { da_test = DT_DEFAULT; }
        else if s == "all" { da_test = DT_ALL; }
        else if s == "strong-siv" { da_test = DT_STRONG_SIV; }
        else if s == "weak-crossing-siv" { da_test = DT_WEAK_CROSSING_SIV; }
        else if s == "exact-siv" { da_test = DT_EXACT_SIV; }
        else if s == "weak-zero-siv" { da_test = DT_WEAK_ZERO_SIV; }
        else if s == "exact-rdiv" { da_test = DT_EXACT_RDIV; }
        else if s == "gcd-miv" { da_test = DT_GCD_MIV; }
        else if s == "banerjee-miv" { da_test = DT_BANERJEE_MIV; }
        else { fatal(str("opt: Cannot find option named '", s, "'!")); }
    }
}

// ---------------------------------------------------------------------------------------------
// OverflowSafeSignedAPInt

struct OSA { v: AP, ok: bool }
fn osa(a: AP) -> OSA { OSA { v: a, ok: true } }
fn osa_none() -> OSA { OSA { v: ap_zero(1), ok: false } }
fn osa_add(a: OSA, b: OSA) -> OSA { if !a.ok || !b.ok { return osa_none(); } let r, o = ap_sadd_ov(a.v, b.v); return if o { osa_none() } else { osa(r) }; }
fn osa_sub(a: OSA, b: OSA) -> OSA { if !a.ok || !b.ok { return osa_none(); } let r, o = ap_ssub_ov(a.v, b.v); return if o { osa_none() } else { osa(r) }; }
fn osa_mul(a: OSA, b: OSA) -> OSA { if !a.ok || !b.ok { return osa_none(); } let r, o = ap_smul_ov(a.v, b.v); return if o { osa_none() } else { osa(r) }; }
fn osa_neg(a: OSA) -> OSA { if !a.ok || ap_is_min_signed(a.v) { return osa_none(); } return osa(ap_neg(a.v)); }
fn osa_add_int(a: OSA, x: i64) -> OSA { if !a.ok { return osa_none(); } return osa_add(a, osa(ap_i64(x, a.v.w as i64))); }

// floorOfQuotient / ceilingOfQuotient
fn da_floor_of_quotient(oa: OSA, ob: OSA) -> OSA {
    if !oa.ok || !ob.ok { return osa_none(); }
    let a = oa.v;
    let b = ob.v;
    let q, r = ap_sdivrem(a, b);
    if ap_is_zero(r) { return osa(q); }
    if (ap_sgt_i64(a, 0) && ap_sgt_i64(b, 0)) || (ap_slt_i64(a, 0) && ap_slt_i64(b, 0)) { return osa(q); }
    return osa_add_int(osa(q), -1);
}
fn da_ceiling_of_quotient(oa: OSA, ob: OSA) -> OSA {
    if !oa.ok || !ob.ok { return osa_none(); }
    let a = oa.v;
    let b = ob.v;
    let q, r = ap_sdivrem(a, b);
    if ap_is_zero(r) { return osa(q); }
    if (ap_sgt_i64(a, 0) && ap_sgt_i64(b, 0)) || (ap_slt_i64(a, 0) && ap_slt_i64(b, 0)) { return osa_add_int(osa(q), 1); }
    return osa(q);
}
// inferDomainOfAffine(A, B, UB) -> (TL, TU)
fn da_infer_domain_of_affine(a: OSA, b: OSA, ub: OSA) -> OSA, OSA {
    if ap_sgt_i64(a.v, 0) {
        let tl = da_ceiling_of_quotient(osa_neg(b), a);
        let tu = da_floor_of_quotient(osa_sub(ub, b), a);
        return tl, tu;
    }
    let tu = da_floor_of_quotient(osa_neg(b), a);
    let tl = da_ceiling_of_quotient(osa_sub(ub, b), a);
    return tl, tu;
}

// ---------------------------------------------------------------------------------------------
// FullDependence helpers

fn da_is_flow() -> bool { inst_may_write_memory(da_res_src) && inst_may_read_memory(da_res_dst) }
fn da_is_output() -> bool { inst_may_write_memory(da_res_src) && inst_may_write_memory(da_res_dst) }
fn da_is_anti() -> bool { inst_may_read_memory(da_res_src) && inst_may_write_memory(da_res_dst) }
fn da_is_input() -> bool { inst_may_read_memory(da_res_src) && inst_may_read_memory(da_res_dst) }

// getDirection / getDistance / isScalar of level (1-based; SameSD levels follow the common ones)
fn da_direction(level: i64) -> u8 { da_dir[level - 1] }
fn da_distance(level: i64) -> i32 { da_dist[level - 1] }
fn da_is_scalar(level: i64) -> bool { da_scalar[level - 1] }

// FullDependence::negate over the first `levels` entries
fn da_negate(levels: i64) {
    let t = da_res_src; da_res_src = da_res_dst; da_res_dst = t;
    for k in levels {
        let d = da_dir[k];
        var r = d & DV_EQ;
        if (d & DV_LT) != 0 { r = r | DV_GT; }
        if (d & DV_GT) != 0 { r = r | DV_LT; }
        da_dir[k] = r;
        if da_dist[k] >= 0 { da_dist[k] = sc_get_negative(da_dist[k], SF_ANY); }
    }
}
// FullDependence::isDirectionNegative
fn da_is_direction_negative() -> bool {
    for k in da_res_levels {
        let d = da_dir[k];
        if d == DV_EQ { continue; }
        return d == DV_GT || d == DV_GE;
    }
    return false;
}
// FullDependence::normalize
fn da_normalize() -> bool {
    if da_res_kind != 2 { return false; }
    if !da_is_direction_negative() { return false; }
    da_negate(da_res_levels);
    return true;
}

// Dependence::dumpImp
fn da_dump_imp(samesd: bool) {
    var n = da_res_levels;
    if samesd { n += da_res_samesd; }
    errs(" [");
    for ii in 1..n + 1 {
        let d = da_distance(ii);
        if d >= 0 { sc_print(d); }
        else if da_is_scalar(ii) { errs("S"); }
        else {
            let dir = da_direction(ii);
            if dir == DV_ALL { errs("*"); }
            else {
                if (dir & DV_LT) != 0 { errs("<"); }
                if (dir & DV_EQ) != 0 { errs("="); }
                if (dir & DV_GT) != 0 { errs(">"); }
            }
        }
        if ii < n { errs(" "); }
    }
    if da_res_li { errs("|<"); }
    errs("]");
}
// Dependence::dump
fn da_dump() {
    if da_res_kind == 1 { errs("confused"); }
    else {
        if da_is_flow() { errs("flow"); }
        else if da_is_output() { errs("output"); }
        else if da_is_anti() { errs("anti"); }
        else if da_is_input() { errs("input"); }
        da_dump_imp(false);
        if da_res_samesd > 0 {
            errs(" / assuming ");
            errs_int(da_res_samesd);
            errs(" loop level(s) fused: ");
            da_dump_imp(true);
        }
    }
    errs("!\n");
    if !su_always_true(da_res_assume) {
        errs("  Runtime Assumptions:\n");
        su_print(da_res_assume, 2);
    }
}

// ---------------------------------------------------------------------------------------------
// DependenceInfo basics

fn da_loop_depth_of(bb: i32) -> i64 { let l = li_loop_for(bb); if l < 0 { 0 } else { loop_depth(l) } }
fn da_is_load_or_store(i: i32) -> bool {
    let o = iop(i);
    return (o == OP_LOAD || o == OP_STORE) && ldst_is_unordered(i);
}
fn da_ptr_operand(i: i32) -> i32 { if iop(i) == OP_STORE { op(i, 1) } else { op(i, 0) } }

// underlyingObjectsAlias: 0 = NoAlias, 1 = MayAlias, 3 = MustAlias (PartialAlias is treated as MayAlias)
fn da_underlying_objects_alias(la: ML, lb: ML) -> i64 {
    let a = ml_with_tags(la.ptr, LS_BEFORE_OR_AFTER, la);
    let b = ml_with_tags(lb.ptr, LS_BEFORE_OR_AFTER, lb);
    let q = aq_push(CA_SIMPLE);
    aq_set_cross(q, true);
    let r = aa_alias(a, b, q, -1);
    aq_pop(q);
    if r.k == AR_NO as u8 { return 0; }
    let ao = get_underlying_object(la.ptr, 10);
    let bo = get_underlying_object(lb.ptr, 10);
    if ao == bo { return 3; }
    if !aa_is_identified_object(ao) || !aa_is_identified_object(bo) { return 1; }
    return 0;
}

// haveSameSD
fn da_have_same_sd(sl: i32, dl: i32) -> bool {
    if sl == dl { return true; }
    if loop_depth(sl) != loop_depth(dl) { return false; }
    if loop_latch(sl) < 0 || loop_latch(dl) < 0 { return false; }
    var su = sc_get_backedge_taken_count(sl, BTC_EXACT);
    var du = sc_get_backedge_taken_count(dl, BTC_EXACT);
    if sc_is_cnc(su) || sc_is_cnc(du) { return false; }
    let wt = sc_get_wider_type(sc_ty(su), sc_ty(du));
    su = sc_get_noop_or_zero_extend(su, wt);
    du = sc_get_noop_or_zero_extend(du, wt);
    return su == du;
}

// establishNestingLevels
fn da_establish_nesting_levels(src: i32, dst: i32) {
    let sb = inst_parent(src);
    let db = inst_parent(dst);
    var slev = da_loop_depth_of(sb);
    var dlev = da_loop_depth_of(db);
    var sl = li_loop_for(sb);
    var dl = li_loop_for(db);
    da_src_levels = slev;
    da_max = slev + dlev;
    da_samesd_levels = 0;
    while slev > dlev { sl = loop_parent(sl); slev--; }
    while dlev > slev { dl = loop_parent(dl); dlev--; }
    var sf: i32 = -1;
    var df: i32 = -1;
    while sl != dl {
        sf = sl;
        df = dl;
        sl = loop_parent(sl);
        dl = loop_parent(dl);
        slev--;
    }
    if sf >= 0 && df >= 0 && da_have_same_sd(sf, df) { da_samesd_levels = 1; }
    da_common = slev;
    da_max -= da_common;
}

fn da_map_src_loop(l: i32) -> i64 { loop_depth(l) }
fn da_map_dst_loop(l: i32) -> i64 {
    let d = loop_depth(l);
    if d > da_common { return d - da_common + da_src_levels; }
    return d;
}

// isLoopInvariant(Expression, LoopNest)
fn da_is_loop_invariant(e: i32, nest: i32) -> bool {
    if nest < 0 { return true; }
    return sc_is_loop_invariant(e, loop_outermost(nest));
}

// collectCommonLoops
fn da_collect_common_loops(e: i32, nest0: i32, loops: u64) -> u64 {
    var m = loops;
    var nest = nest0;
    while nest >= 0 {
        let level = loop_depth(nest);
        if level <= da_common && !sc_is_loop_invariant(e, nest) { m = m | da_bit(level); }
        nest = loop_parent(nest);
    }
    return m;
}

// checkSubscript(Expr, LoopNest, Loops, IsSrc) -> (affine, Loops)
fn da_check_subscript(e0: i32, nest: i32, loops0: u64, is_src: bool) -> bool, u64 {
    var e = e0;
    var loops = loops0;
    loop {
        if sc_kind(e) != SC_ADDREC { return da_is_loop_invariant(e, nest), loops; }
        var l = nest;
        while l >= 0 && sc_loop(e) != l { l = loop_parent(l); }
        if l < 0 { return false, loops; }
        if !sc_has_nsw(e) { return false, loops; }
        let start = sc_op(e, 0);
        let step = sc_get_step_recurrence(e);
        if !da_is_loop_invariant(step, nest) { return false, loops; }
        if is_src { loops = loops | da_bit(da_map_src_loop(sc_loop(e))); }
        else { loops = loops | da_bit(da_map_dst_loop(sc_loop(e))); }
        e = start;
    }
    return false, loops;
}

// classifyPair -> (class, Loops)
fn da_classify_pair(src: i32, snest: i32, dst: i32, dnest: i32) -> i64, u64 {
    let ok1, sloops = da_check_subscript(src, snest, 0, true);
    if !ok1 { return SUB_NONLINEAR, 0; }
    let ok2, dloops = da_check_subscript(dst, dnest, 0, false);
    if !ok2 { return SUB_NONLINEAR, 0; }
    let loops = sloops | dloops;
    let n = da_popcount(loops);
    if n == 0 { return SUB_ZIV, loops; }
    if n == 1 { return SUB_SIV, loops; }
    if n == 2 && da_popcount(sloops) == 1 && da_popcount(dloops) == 1 { return SUB_RDIV, loops; }
    return SUB_MIV, loops;
}

// collectUpperBound(L, T): -1 = none
fn da_collect_upper_bound(l: i32, t: i32) -> i32 {
    let ub = sc_get_backedge_taken_count(l, BTC_EXACT);
    if sc_is_cnc(ub) { return -1; }
    return sc_get_truncate_or_zero_extend(ub, t, 0);
}
// collectNonNegativeConstantUpperBound
fn da_collect_nonneg_const_ub(l: i32, t: i32) -> OSA {
    let ub = da_collect_upper_bound(l, t);
    if ub >= 0 && sc_kind(ub) == SC_CONST {
        let r = sc_ap(ub);
        if ap_is_nonneg(r) { return osa(r); }
    }
    return osa_none();
}

// minusSCEVNoSignedOverflow: -1 if it may wrap
fn da_minus_no_signed_overflow(a: i32, b: i32) -> i32 {
    if sc_will_not_overflow(OP_SUB, true, a, b, -1) { return sc_minus(a, b); }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// The tests (Level arguments are 0-based DV indices where LLVM has done Level--)

fn da_test_ziv(src: i32, dst: i32) -> bool {
    if sc_is_known_predicate(P_EQ, src, dst) { return false; }
    if sc_is_known_predicate(P_NE, src, dst) { return true; }
    return false;
}

fn da_strong_siv(src: i32, dst: i32, level1: i64, under_rt: bool) -> bool {
    if !da_test_enabled(DT_STRONG_SIV) { return false; }
    let coeff = sc_get_step_recurrence(src);
    let sconst = sc_op(src, 0);
    let dconst = sc_op(dst, 0);
    let level = level1 - 1;
    let delta = da_minus_no_signed_overflow(sconst, dconst);
    if delta < 0 { return false; }
    if sc_kind(delta) == SC_CONST && sc_kind(coeff) == SC_CONST {
        let dist, rem = ap_sdivrem(sc_ap(delta), sc_ap(coeff));
        if !ap_is_zero(rem) { return true; }
        da_dist[level] = sc_get_constant(dist);
        if ap_sgt_i64(dist, 0) { da_dir[level] = da_dir[level] & DV_LT; }
        else if ap_slt_i64(dist, 0) { da_dir[level] = da_dir[level] & DV_GT; }
        else { da_dir[level] = da_dir[level] & DV_EQ; }
    } else if sc_is_zero(delta) {
        if !sc_is_known_non_zero(coeff) {
            if under_rt {
                let p = sc_get_compare_predicate(P_NE, coeff, sc_get_zero(sc_ty(coeff)));
                da_res_assume = su_add(da_res_assume, p);
            } else {
                return false;
            }
        }
        da_dist[level] = delta;
        da_dir[level] = da_dir[level] & DV_EQ;
    } else {
        if sc_is_one(coeff) { da_dist[level] = delta; }
        let dmz = !sc_is_known_non_zero(delta);
        let dmp = !sc_is_known_non_positive(delta);
        let dmn = !sc_is_known_non_negative(delta);
        let cmp = !sc_is_known_non_positive(coeff);
        let cmn = !sc_is_known_non_negative(coeff);
        var nd = DV_NONE;
        if (dmp && cmp) || (dmn && cmn) { nd = DV_LT; }
        if dmz { nd = nd | DV_EQ; }
        if (dmn && cmp) || (dmp && cmn) { nd = nd | DV_GT; }
        da_dir[level] = da_dir[level] & nd;
    }
    return false;
}

fn da_weak_crossing_siv(src: i32, dst: i32, level1: i64) -> bool {
    if !da_test_enabled(DT_WEAK_CROSSING_SIV) { return false; }
    let coeff = sc_get_step_recurrence(src);
    let sconst = sc_op(src, 0);
    let dconst = sc_op(dst, 0);
    let level = level1 - 1;
    let delta = da_minus_no_signed_overflow(dconst, sconst);
    if delta < 0 { return false; }
    if sc_kind(coeff) != SC_CONST { return false; }
    if sc_kind(delta) != SC_CONST { return false; }
    let sr = sc_get_signed_range(src);
    let dr = sc_get_signed_range(dst);
    if rg_is_single(rg_intersect(sr, dr)) {
        da_dir[level] = da_dir[level] & ~DV_LT;
        da_dir[level] = da_dir[level] & ~DV_GT;
        if da_dir[level] == DV_NONE { return true; }
        da_dist[level] = sc_get_zero(sc_ty(delta));
        return false;
    }
    let dist, rem = ap_sdivrem(sc_ap(delta), sc_ap(coeff));
    if !ap_is_zero(rem) { return true; }
    if ap_get_bit(dist, 0) { da_dir[level] = da_dir[level] & ~DV_EQ; }
    return false;
}

// findGCD(Bits, AM, BM, Delta) -> (ok, disproved, G, X, Y)
fn da_find_gcd(bits: i64, am: AP, bm: AP, delta: AP) -> bool, bool, AP, AP, AP {
    var a0 = ap_i64(1, bits);
    var a1 = ap_i64(0, bits);
    var b0 = ap_i64(0, bits);
    var b1 = ap_i64(1, bits);
    if ap_is_min_signed(am) || ap_is_min_signed(bm) { return false, false, a0, a0, a0; }
    var g0 = ap_abs(am);
    var g1 = ap_abs(bm);
    var q, r = ap_sdivrem(g0, g1);
    while !ap_is_zero(r) {
        let a2 = ap_sub(a0, ap_mul(q, a1)); a0 = a1; a1 = a2;
        let b2 = ap_sub(b0, ap_mul(q, b1)); b0 = b1; b1 = b2;
        g0 = g1; g1 = r;
        let q2, r2 = ap_sdivrem(g0, g1);
        q = q2; r = r2;
    }
    let g = g1;
    let x = if ap_slt_i64(am, 0) { ap_neg(a1) } else { a1 };
    let y = if ap_slt_i64(bm, 0) { b1 } else { ap_neg(b1) };
    let rr = ap_srem(delta, g);
    if !ap_is_zero(rr) { return true, true, g, x, y; }
    return true, false, g, x, y;
}

// exactTestImpl(Src, Dst, Result, Level): level < 0 = std::nullopt
fn da_exact_test_impl(src: i32, dst: i32, level: i64) -> bool {
    let scoeff = sc_get_step_recurrence(src);
    let sconst = sc_op(src, 0);
    let dcoeff = sc_get_step_recurrence(dst);
    let dconst = sc_op(dst, 0);
    let delta = da_minus_no_signed_overflow(dconst, sconst);
    if delta < 0 { return false; }
    if sc_kind(delta) != SC_CONST || sc_kind(scoeff) != SC_CONST || sc_kind(dcoeff) != SC_CONST { return false; }
    let am = sc_ap(scoeff);
    let bm = sc_ap(dcoeff);
    let cm = sc_ap(delta);
    let bits = am.w as i64;
    let ok, disproved, g, x, y = da_find_gcd(bits, am, bm, cm);
    if !ok { return false; }
    if disproved { return true; }
    let src_um = da_collect_nonneg_const_ub(sc_loop(src), sc_ty(delta));
    let dst_um = da_collect_nonneg_const_ub(sc_loop(dst), sc_ty(delta));
    let tc = osa(ap_sdiv(cm, g));
    let tx = osa_mul(osa(x), tc);
    let ty = osa_mul(osa(y), tc);
    if !tc.ok || !tx.ok || !ty.ok { return false; }
    let tb = ap_sdiv(bm, g);
    let ta = ap_sdiv(am, g);
    let tl0, tu0 = da_infer_domain_of_affine(osa(tb), tx, src_um);
    let tl1, tu1 = da_infer_domain_of_affine(osa(ta), ty, dst_um);
    fn max_or_min(v0: OSA, v1: OSA, is_min: bool) -> OSA {
        if v0.ok && v1.ok { return osa(if is_min { ap_smin(v0.v, v1.v) } else { ap_smax(v0.v, v1.v) }); }
        if v0.ok { return v0; }
        if v1.ok { return v1; }
        return osa_none();
    }
    let otl = max_or_min(tl0, tl1, false);
    let otu = max_or_min(tu0, tu1, true);
    if !otl.ok || !otu.ok { return false; }
    let tl = otl.v;
    let tu = otu.v;
    if ap_sgt(tl, tu) { return true; }
    if level < 0 { return false; }
    var nd = DV_NONE;
    var lower = osa_none();
    var upper = osa_none();
    let dyx = osa_sub(ty, tx);
    let dab = osa_sub(osa(ta), osa(tb));
    if ap_sgt(ta, tb) {
        lower = osa_add(dyx, osa_mul(dab, osa(tl)));
        upper = osa_add(dyx, osa_mul(dab, osa(tu)));
    } else {
        lower = osa_add(dyx, osa_mul(dab, osa(tu)));
        upper = osa_add(dyx, osa_mul(dab, osa(tl)));
    }
    if !lower.ok || !upper.ok { return false; }
    if !ap_sgt_i64(lower.v, 0) && !ap_slt_i64(upper.v, 0) { nd = nd | DV_EQ; }
    if ap_slt_i64(lower.v, 0) { nd = nd | DV_GT; }
    if ap_sgt_i64(upper.v, 0) { nd = nd | DV_LT; }
    da_dir[level] = da_dir[level] & nd;
    return da_dir[level] == DV_NONE;
}

fn da_exact_siv(src: i32, dst: i32, level1: i64) -> bool {
    if !da_test_enabled(DT_EXACT_SIV) { return false; }
    return da_exact_test_impl(src, dst, level1 - 1);
}

// weakZeroSIVtestImpl(AR, Const, Level (0-based))
fn da_weak_zero_siv_impl(ar: i32, cst: i32, level: i64) -> bool {
    let arcoeff = sc_get_step_recurrence(ar);
    let arconst = sc_op(ar, 0);
    if cst == arconst && sc_is_known_non_zero(arcoeff) {
        if level < da_common { da_dir[level] = da_dir[level] & DV_LE; }
        return false;
    }
    let delta = da_minus_no_signed_overflow(cst, arconst);
    if delta < 0 { return false; }
    if sc_kind(arcoeff) != SC_CONST { return false; }
    let ub = da_collect_upper_bound(sc_loop(ar), sc_ty(delta));
    if ub >= 0 {
        var overlap = false;
        if sc_is_known_non_zero(arcoeff) {
            let last = sc_evaluate_at_iteration(ar, ub);
            overlap = last == cst;
        }
        if overlap {
            if level < da_common { da_dir[level] = da_dir[level] & DV_GE; }
            return false;
        }
    }
    if sc_kind(delta) == SC_CONST && !ap_is_zero(ap_srem(sc_ap(delta), sc_ap(arcoeff))) { return true; }
    return false;
}
fn da_weak_zero_src_siv(sconst: i32, dst: i32, level1: i64) -> bool {
    if !da_test_enabled(DT_WEAK_ZERO_SIV) { return false; }
    let level = level1 - 1;
    da_negate(da_res_levels);
    let r = da_weak_zero_siv_impl(dst, sconst, level);
    da_negate(da_res_levels);
    return r;
}
fn da_weak_zero_dst_siv(src: i32, dconst: i32, level1: i64) -> bool {
    if !da_test_enabled(DT_WEAK_ZERO_SIV) { return false; }
    return da_weak_zero_siv_impl(src, dconst, level1 - 1);
}

fn da_exact_rdiv(src: i32, dst: i32) -> bool {
    if !da_test_enabled(DT_EXACT_RDIV) { return false; }
    return da_exact_test_impl(src, dst, -1);
}

fn da_test_siv(src: i32, dst: i32, under_rt: bool) -> bool {
    let sa = sc_kind(src) == SC_ADDREC;
    let dd = sc_kind(dst) == SC_ADDREC;
    if sa && dd {
        let sco = sc_get_step_recurrence(src);
        let dco = sc_get_step_recurrence(dst);
        let level = da_map_src_loop(sc_loop(src));
        var disproven = false;
        if sco == dco { disproven = da_strong_siv(src, dst, level, under_rt); }
        else if sco == sc_get_negative(dco, SF_ANY) { disproven = da_weak_crossing_siv(src, dst, level); }
        return disproven || da_exact_siv(src, dst, level);
    }
    if sa { return da_weak_zero_dst_siv(src, dst, da_map_src_loop(sc_loop(src))); }
    if dd { return da_weak_zero_src_siv(src, dst, da_map_dst_loop(sc_loop(dst))); }
    fatal("internal: SIV test expected at least one AddRec");
    return false;
}

fn da_test_rdiv(src: i32, dst: i32) -> bool { da_exact_rdiv(src, dst) || da_gcd_miv(src, dst) }
fn da_test_miv(src: i32, dst: i32, loops: u64) -> bool { da_gcd_miv(src, dst) || da_banerjee_miv(src, dst, loops) }

// getConstantCoefficient -> (ok, value)
fn da_constant_coefficient(e: i32) -> bool, AP {
    if sc_kind(e) == SC_CONST { return true, sc_ap(e); }
    if sc_kind(e) == SC_MUL {
        let c = sc_op(e, 0);
        if sc_kind(c) == SC_CONST && sc_has_nsw(e) { return true, sc_ap(c); }
    }
    return false, ap_zero(1);
}

// accumulateCoefficientsGCD(Expr, CurLoop, CurLoopCoeff, RunningGCD) -> (result or -1, CurLoopCoeff, RunningGCD)
fn da_accumulate_coefficients_gcd(e0: i32, cur: i32, coeff0: i32, gcd0: AP) -> i32, i32, AP {
    var e = e0;
    var coeff = coeff0;
    var gcd = gcd0;
    loop {
        if sc_kind(e) != SC_ADDREC { return e, coeff, gcd; }
        let start = sc_op(e, 0);
        let step = sc_get_step_recurrence(e);
        if cur >= 0 && sc_loop(e) == cur { coeff = step; }
        else {
            let ok, c = da_constant_coefficient(step);
            if !ok { return -1, coeff, gcd; }
            gcd = ap_gcd(gcd, ap_abs(c));
        }
        e = start;
    }
    return e, coeff, gcd;
}

fn da_gcd_miv(src: i32, dst: i32) -> bool {
    if !da_test_enabled(DT_GCD_MIV) { return false; }
    let bw = sc_type_bits(sc_ty(src));
    var rg = ap_zero(bw);
    let sconst, d1, g1 = da_accumulate_coefficients_gcd(src, -1, -1, rg);
    rg = g1;
    if sconst < 0 { return false; }
    let dconst, d2, g2 = da_accumulate_coefficients_gcd(dst, -1, -1, rg);
    rg = g2;
    if dconst < 0 { return false; }
    var delta = da_minus_no_signed_overflow(dconst, sconst);
    if delta < 0 { return false; }
    if sc_kind(delta) != SC_CONST { return false; }
    let cdelta = sc_ap(delta);
    if ap_is_zero(cdelta) { return false; }
    if !ap_is_zero(ap_srem(cdelta, rg)) { return true; }
    var coeffs = src;
    while sc_kind(coeffs) == SC_ADDREC {
        let ar = coeffs;
        coeffs = sc_op(ar, 0);
        let cur = sc_loop(ar);
        rg = ap_zero(bw);
        let sco0 = sc_get_step_recurrence(ar);
        let dco0 = sc_minus(sco0, sco0);
        let r1, sco, ga = da_accumulate_coefficients_gcd(src, cur, sco0, rg);
        rg = ga;
        if r1 < 0 { return false; }
        let r2, dco, gb = da_accumulate_coefficients_gcd(dst, cur, dco0, rg);
        rg = gb;
        if r2 < 0 { return false; }
        delta = da_minus_no_signed_overflow(dco, sco);
        if delta < 0 { continue; }
        let ok, cc = da_constant_coefficient(delta);
        if !ok { continue; }
        rg = ap_gcd(rg, ap_abs(cc));
        if !ap_is_zero(rg) {
            if !ap_is_zero(ap_srem(cdelta, rg)) {
                let level = da_map_src_loop(cur);
                if level > da_res_levels { fatal("DependenceAnalysis: gcdMIVtest writes past the direction vector (LLVM's heap overflow)"); }
                da_dir[level - 1] = da_dir[level - 1] & ~DV_EQ;
            }
        }
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// Banerjee MIV. CoefficientInfo rows: [0, MaxLevels]; BoundInfo: Lower/Upper indexed by direction (8 each).

var bj_a_coeff: i32[>..<];
var bj_a_pos: i32[>..<];
var bj_a_neg: i32[>..<];
var bj_a_iter: i32[>..<];
var bj_b_coeff: i32[>..<];
var bj_b_pos: i32[>..<];
var bj_b_neg: i32[>..<];
var bj_b_iter: i32[>..<];
var bj_iter: i32[>..<];
var bj_dir: u8[>..<];
var bj_dirset: u8[>..<];
var bj_lower: i32[>..<];         // 8 per level
var bj_upper: i32[>..<];
var bj_delta: i32 = -1;
var bj_loops: u64 = 0;
var bj_depth_expanded: i64 = 0;

fn da_positive_part(x: i32) -> i32 { sc_smax(x, sc_get_zero(sc_ty(x))) }
fn da_negative_part(x: i32) -> i32 { sc_smin(x, sc_get_zero(sc_ty(x))) }

// collectCoeffInfo -> Constant
fn da_collect_coeff_info(sub0: i32, is_src: bool) -> i32 {
    var sub = sub0;
    let zero = sc_get_zero(sc_ty(sub));
    let n = da_max + 1;
    var coeff: i32[>..<] = [];
    var pos: i32[>..<] = [];
    var neg: i32[>..<] = [];
    var iter: i32[>..<] = [];
    for k in n { coeff.push(zero); pos.push(zero); neg.push(zero); iter.push(-1); }
    while sc_kind(sub) == SC_ADDREC {
        let l = sc_loop(sub);
        let k = if is_src { da_map_src_loop(l) } else { da_map_dst_loop(l) };
        coeff[k] = sc_get_step_recurrence(sub);
        pos[k] = da_positive_part(coeff[k]);
        neg[k] = da_negative_part(coeff[k]);
        iter[k] = da_collect_upper_bound(l, sc_ty(sub));
        sub = sc_op(sub, 0);
    }
    if is_src {
        bj_a_coeff.clear(); bj_a_pos.clear(); bj_a_neg.clear(); bj_a_iter.clear();
        for k in n { bj_a_coeff.push(coeff[k]); bj_a_pos.push(pos[k]); bj_a_neg.push(neg[k]); bj_a_iter.push(iter[k]); }
    } else {
        bj_b_coeff.clear(); bj_b_pos.clear(); bj_b_neg.clear(); bj_b_iter.clear();
        for k in n { bj_b_coeff.push(coeff[k]); bj_b_pos.push(pos[k]); bj_b_neg.push(neg[k]); bj_b_iter.push(iter[k]); }
    }
    return sub;
}

fn bj_set_lower(k: i64, d: u8, v: i32) { bj_lower[k * 8 + (d as i64)] = v; }
fn bj_set_upper(k: i64, d: u8, v: i32) { bj_upper[k * 8 + (d as i64)] = v; }

fn da_find_bounds_all(k: i64) {
    bj_set_lower(k, DV_ALL, -1);
    bj_set_upper(k, DV_ALL, -1);
    if bj_iter[k] >= 0 {
        bj_set_lower(k, DV_ALL, sc_mul(sc_minus(bj_a_neg[k], bj_b_pos[k]), bj_iter[k]));
        bj_set_upper(k, DV_ALL, sc_mul(sc_minus(bj_a_pos[k], bj_b_neg[k]), bj_iter[k]));
    } else {
        if sc_is_known_predicate(P_EQ, bj_a_neg[k], bj_b_pos[k]) { bj_set_lower(k, DV_ALL, sc_get_zero(sc_ty(bj_a_coeff[k]))); }
        if sc_is_known_predicate(P_EQ, bj_a_pos[k], bj_b_neg[k]) { bj_set_upper(k, DV_ALL, sc_get_zero(sc_ty(bj_a_coeff[k]))); }
    }
}
fn da_find_bounds_eq(k: i64) {
    bj_set_lower(k, DV_EQ, -1);
    bj_set_upper(k, DV_EQ, -1);
    if bj_iter[k] >= 0 {
        let delta = sc_minus(bj_a_coeff[k], bj_b_coeff[k]);
        let np = da_negative_part(delta);
        bj_set_lower(k, DV_EQ, sc_mul(np, bj_iter[k]));
        let pp = da_positive_part(delta);
        bj_set_upper(k, DV_EQ, sc_mul(pp, bj_iter[k]));
    } else {
        let delta = sc_minus(bj_a_coeff[k], bj_b_coeff[k]);
        let np = da_negative_part(delta);
        if sc_is_zero(np) { bj_set_lower(k, DV_EQ, np); }
        let pp = da_positive_part(delta);
        if sc_is_zero(pp) { bj_set_upper(k, DV_EQ, pp); }
    }
}
fn da_find_bounds_lt(k: i64) {
    bj_set_lower(k, DV_LT, -1);
    bj_set_upper(k, DV_LT, -1);
    if bj_iter[k] >= 0 {
        let it1 = sc_minus(bj_iter[k], sc_get_one(sc_ty(bj_iter[k])));
        let np = da_negative_part(sc_minus(bj_a_neg[k], bj_b_coeff[k]));
        bj_set_lower(k, DV_LT, sc_minus(sc_mul(np, it1), bj_b_coeff[k]));
        let pp = da_positive_part(sc_minus(bj_a_pos[k], bj_b_coeff[k]));
        bj_set_upper(k, DV_LT, sc_minus(sc_mul(pp, it1), bj_b_coeff[k]));
    } else {
        let np = da_negative_part(sc_minus(bj_a_neg[k], bj_b_coeff[k]));
        if sc_is_zero(np) { bj_set_lower(k, DV_LT, sc_get_negative(bj_b_coeff[k], SF_ANY)); }
        let pp = da_positive_part(sc_minus(bj_a_pos[k], bj_b_coeff[k]));
        if sc_is_zero(pp) { bj_set_upper(k, DV_LT, sc_get_negative(bj_b_coeff[k], SF_ANY)); }
    }
}
fn da_find_bounds_gt(k: i64) {
    bj_set_lower(k, DV_GT, -1);
    bj_set_upper(k, DV_GT, -1);
    if bj_iter[k] >= 0 {
        let it1 = sc_minus(bj_iter[k], sc_get_one(sc_ty(bj_iter[k])));
        let np = da_negative_part(sc_minus(bj_a_coeff[k], bj_b_pos[k]));
        bj_set_lower(k, DV_GT, sc_add(sc_mul(np, it1), bj_a_coeff[k]));
        let pp = da_positive_part(sc_minus(bj_a_coeff[k], bj_b_neg[k]));
        bj_set_upper(k, DV_GT, sc_add(sc_mul(pp, it1), bj_a_coeff[k]));
    } else {
        let np = da_negative_part(sc_minus(bj_a_coeff[k], bj_b_pos[k]));
        if sc_is_zero(np) { bj_set_lower(k, DV_GT, bj_a_coeff[k]); }
        let pp = da_positive_part(sc_minus(bj_a_coeff[k], bj_b_neg[k]));
        if sc_is_zero(pp) { bj_set_upper(k, DV_GT, bj_a_coeff[k]); }
    }
}

fn da_get_lower_bound() -> i32 {
    var sum = bj_lower[8 + (bj_dir[1] as i64)];
    var k: i64 = 2;
    while sum >= 0 && k <= da_max {
        let x = bj_lower[k * 8 + (bj_dir[k] as i64)];
        if x >= 0 { sum = sc_add(sum, x); } else { sum = -1; }
        k++;
    }
    return sum;
}
fn da_get_upper_bound() -> i32 {
    var sum = bj_upper[8 + (bj_dir[1] as i64)];
    var k: i64 = 2;
    while sum >= 0 && k <= da_max {
        let x = bj_upper[k * 8 + (bj_dir[k] as i64)];
        if x >= 0 { sum = sc_add(sum, x); } else { sum = -1; }
        k++;
    }
    return sum;
}

// testBounds(DirKind, Level, Bound, Delta)
fn da_test_bounds(dk: u8, level: i64) -> bool {
    bj_dir[level] = dk;
    let lb = da_get_lower_bound();
    if lb >= 0 && sc_is_known_predicate(P_SGT, lb, bj_delta) { return false; }
    let ub = da_get_upper_bound();
    if ub >= 0 && sc_is_known_predicate(P_SGT, bj_delta, ub) { return false; }
    return true;
}

// exploreDirections(Level, ...)
recursive fn da_explore_directions(level: i64) -> i64 {
    if da_common > flag_int("da-miv-max-level-threshold", 7) {
        for k in 1..da_common + 1 { if (bj_loops & da_bit(k)) != 0 { bj_dirset[k] = DV_ALL; } }
        return 1;
    }
    if level > da_common {
        for k in 1..da_common + 1 { if (bj_loops & da_bit(k)) != 0 { bj_dirset[k] = bj_dirset[k] | bj_dir[k]; } }
        return 1;
    }
    if (bj_loops & da_bit(level)) != 0 {
        if level > bj_depth_expanded {
            bj_depth_expanded = level;
            da_find_bounds_lt(level);
            da_find_bounds_gt(level);
            da_find_bounds_eq(level);
        }
        var nd: i64 = 0;
        if da_test_bounds(DV_LT, level) { nd += da_explore_directions(level + 1); }
        if da_test_bounds(DV_EQ, level) { nd += da_explore_directions(level + 1); }
        if da_test_bounds(DV_GT, level) { nd += da_explore_directions(level + 1); }
        bj_dir[level] = DV_ALL;
        return nd;
    }
    return da_explore_directions(level + 1);
}

fn da_banerjee_miv(src: i32, dst: i32, loops: u64) -> bool {
    if !da_test_enabled(DT_BANERJEE_MIV) { return false; }
    let a0 = da_collect_coeff_info(src, true);
    let b0 = da_collect_coeff_info(dst, false);
    let n = da_max + 1;
    bj_iter.clear(); bj_dir.clear(); bj_dirset.clear(); bj_lower.clear(); bj_upper.clear();
    for k in n {
        bj_iter.push(-1); bj_dir.push(DV_ALL); bj_dirset.push(DV_NONE);
        for j in 8 { bj_lower.push(-1); bj_upper.push(-1); }
    }
    let delta = da_minus_no_signed_overflow(b0, a0);
    if delta < 0 { return false; }
    bj_delta = delta;
    bj_loops = loops;
    for k in 1..da_max + 1 {
        bj_iter[k] = if bj_a_iter[k] >= 0 { bj_a_iter[k] } else { bj_b_iter[k] };
        bj_dir[k] = DV_ALL;
        bj_dirset[k] = DV_NONE;
        da_find_bounds_all(k);
    }
    var disproved = false;
    if da_test_bounds(DV_ALL, 0) {
        bj_depth_expanded = 0;
        let nd = da_explore_directions(1);
        if nd > 0 {
            for k in 1..da_common + 1 {
                if (loops & da_bit(k)) != 0 {
                    let old = da_dir[k - 1];
                    da_dir[k - 1] = old & bj_dirset[k];
                    if da_dir[k - 1] == DV_NONE { disproved = true; break; }
                }
            }
        } else {
            disproved = true;
        }
    } else {
        disproved = true;
    }
    return disproved;
}

// ---------------------------------------------------------------------------------------------
// Delinearization of the subscripts

var da_pair_src: i32[>..<];
var da_pair_dst: i32[>..<];
var da_pair_class: i64[>..<];
var da_pair_loops: u64[>..<];

fn da_try_delinearize_fixed_size(src: i32, dst: i32, safn: i32, dafn: i32, ssubs: i32[>..<]&, dsubs: i32[>..<]&) -> bool {
    let es = sc_get_element_size(src);
    var ssizes: i32[>..<] = [];
    var dsizes: i32[>..<] = [];
    if !dl_delinearize_fixed_size_array(sc_remove_pointer_base(safn), ssubs, ssizes, es) { return false; }
    if !dl_delinearize_fixed_size_array(sc_remove_pointer_base(dafn), dsubs, dsizes, es) { return false; }
    var same = ssizes.len == dsizes.len;
    if same { for k in ssizes.len { if ssizes[k] != dsizes[k] { same = false; } } }
    if !same { ssubs.clear(); dsubs.clear(); return false; }
    if !flag_bool("da-disable-delinearization-checks", false) {
        if !dl_validate(ssizes, ssubs) || !dl_validate(dsizes, dsubs) { ssubs.clear(); dsubs.clear(); return false; }
    }
    return true;
}

fn da_try_delinearize_parametric_size(src: i32, dst: i32, safn: i32, dafn: i32, ssubs: i32[>..<]&, dsubs: i32[>..<]&) -> bool {
    let sbase = sc_get_pointer_base(safn);
    let dbase = sc_get_pointer_base(dafn);
    let es = sc_get_element_size(src);
    if es != sc_get_element_size(dst) { return false; }
    let sscev = sc_minus(safn, sbase);
    let dscev = sc_minus(dafn, dbase);
    if sc_kind(sscev) != SC_ADDREC || sc_kind(dscev) != SC_ADDREC || !sc_is_affine(sscev) || !sc_is_affine(dscev) { return false; }
    var terms: i32[>..<] = [];
    dl_collect_parametric_terms(sscev, terms);
    dl_collect_parametric_terms(dscev, terms);
    var sizes: i32[>..<] = [];
    dl_find_array_dimensions(terms, sizes, es);
    dl_compute_access_functions(sscev, ssubs, sizes);
    dl_compute_access_functions(dscev, dsubs, sizes);
    if ssubs.len < 2 || dsubs.len < 2 || ssubs.len != dsubs.len { return false; }
    if !flag_bool("da-disable-delinearization-checks", false) {
        if !dl_validate(sizes, ssubs) || !dl_validate(sizes, dsubs) { return false; }
    }
    return true;
}

// tryDelinearize: on success the pairs are the subscripts
fn da_try_delinearize(src: i32, dst: i32) -> bool {
    let sptr = da_ptr_operand(src);
    let dptr = da_ptr_operand(dst);
    let sl = li_loop_for(inst_parent(src));
    let dl = li_loop_for(inst_parent(dst));
    let safn = sc_get_scev_at_scope(sc_get_scev(sptr), sl);
    let dafn = sc_get_scev_at_scope(sc_get_scev(dptr), dl);
    let sbase = sc_get_pointer_base(safn);
    let dbase = sc_get_pointer_base(dafn);
    if sc_kind(sbase) != SC_UNKNOWN || sc_kind(dbase) != SC_UNKNOWN || sbase != dbase { return false; }
    var ssubs: i32[>..<] = [];
    var dsubs: i32[>..<] = [];
    if !da_try_delinearize_fixed_size(src, dst, safn, dafn, ssubs, dsubs) {
        // (a failed fixed-size attempt may leave SrcSubscripts behind; computeAccessFunctions keeps them when it
        // has no sizes, as in LLVM)
        if !da_try_delinearize_parametric_size(src, dst, safn, dafn, ssubs, dsubs) { return false; }
    }
    da_pair_src.clear(); da_pair_dst.clear();
    for k in ssubs.len { da_pair_src.push(ssubs[k]); da_pair_dst.push(dsubs[k]); }
    return true;
}

// ---------------------------------------------------------------------------------------------
// ScalarEvolution::isKnownMultipleOf(S, M, Assumptions): the assumptions are a run on da_assume
var da_assume: i32[>..<];

fn sc_is_known_multiple_of(s0: i32, m: u64) -> bool {
    if m == 0 { return false; }
    if m == 1 { return true; }
    var wl: i32[>..<] = [];
    wl.push(s0);
    // the AddRec recursion (start, then step), depth first: an `&&` chain
    while wl.len > 0 {
        let s = wl.pop();
        if sc_kind(s) == SC_ADDREC {
            wl.push(sc_get_step_recurrence(s));
            wl.push(sc_op(s, 0));
            continue;
        }
        if sc_kind(s) == SC_CONST {
            let c = sc_ap(s);
            if !ap_is_zero(ap_urem(c, ap_u64(m, c.w as i64))) { return false; }
            continue;
        }
        let ty = sc_ty(s);
        let smodm = sc_get_urem(s, sc_get_constant(ap_u64(m, ty_bits(ty))));
        let zero = sc_get_zero(ty);
        if sc_is_known_predicate(P_EQ, smodm, zero) { continue; }
        if sc_is_known_predicate(P_NE, smodm, zero) { return false; }
        let p = sc_get_compare_predicate(P_EQ, smodm, zero);
        var redundant = false;
        for a in da_assume { if sc_pred_implies(a, p) { redundant = true; break; } }
        if !redundant { da_assume.push(p); }
    }
    return true;
}

// SCEVUnionPredicate(Assume, SE)
fn da_union_of_assume() -> i32 {
    var u = su_empty();
    for p in da_assume { u = su_add(u, p); }
    return u;
}
fn da_confused(src: i32, dst: i32) {
    da_res_kind = 1;
    da_res_src = src;
    da_res_dst = dst;
    da_res_assume = da_union_of_assume();
    da_res_levels = 0;
    da_res_samesd = 0;
    da_res_li = true;
}

// ---------------------------------------------------------------------------------------------
// DependenceInfo::depends(Src, Dst, UnderRuntimeAssumptions): the result in da_res_*

fn da_depends(src: i32, dst: i32, under_rt: bool) {
    da_assume.clear();
    da_res_kind = 0;
    var possibly_li = true;
    if src == dst { possibly_li = false; }
    if !(inst_may_read_or_write_memory(src) && inst_may_read_or_write_memory(dst)) { return; }
    if !da_is_load_or_store(src) || !da_is_load_or_store(dst) { da_confused(src, dst); return; }
    let dloc = ml_get(dst);
    let sloc = ml_get(src);
    let al = da_underlying_objects_alias(dloc, sloc);
    if al == 1 { da_confused(src, dst); return; }
    if al == 0 { return; }
    if dloc.size != sloc.size || !ls_is_precise(dloc.size) || !ls_is_precise(sloc.size) || !ls_has_value(dloc.size) { da_confused(src, dst); return; }
    let sptr = da_ptr_operand(src);
    let dptr = da_ptr_operand(dst);
    let sscev = sc_get_scev(sptr);
    let dscev = sc_get_scev(dptr);
    let sbase = sc_get_pointer_base(sscev);
    let dbase = sc_get_pointer_base(dscev);
    if sbase != dbase { da_confused(src, dst); return; }
    let sl = li_loop_for(inst_parent(src));
    let dl = li_loop_for(inst_parent(dst));
    if !da_is_loop_invariant(sbase, sl) || !da_is_loop_invariant(dbase, dl) { da_confused(src, dst); return; }
    let elt = sloc.size;           // LocationSize::toRaw (keeps the scalable bit)
    let sev = sc_minus(sscev, sbase);
    let dev = sc_minus(dscev, dbase);
    if !sc_is_known_multiple_of(sev, elt) || !sc_is_known_multiple_of(dev, elt) { da_confused(src, dst); return; }
    if da_assume.len > 0 && !under_rt { da_confused(src, dst); return; }
    da_pair_src.clear(); da_pair_dst.clear();
    da_pair_src.push(sev);
    da_pair_dst.push(dev);
    if flag_bool("da-delinearize", true) {
        if !da_try_delinearize(src, dst) {
            da_pair_src.clear(); da_pair_dst.clear();
            da_pair_src.push(sev);
            da_pair_dst.push(dev);
        }
    }
    let pairs = da_pair_src.len;
    da_establish_nesting_levels(src, dst);
    da_common += da_samesd_levels;
    da_max -= da_samesd_levels;
    if da_samesd_levels > 0 {
        for p in pairs {
            let c, lp = da_classify_pair(da_pair_src[p], sl, da_pair_dst[p], dl);
            if c != SUB_ZIV && c != SUB_SIV && c != SUB_RDIV {
                da_common -= da_samesd_levels;
                da_max += da_samesd_levels;
                da_samesd_levels = 0;
                break;
            }
        }
    }
    // FullDependence Result(Src, Dst, SCEVUnionPredicate(Assume), PossiblyLoopIndependent, CommonLevels)
    da_res_kind = 2;
    da_res_src = src;
    da_res_dst = dst;
    da_res_assume = da_union_of_assume();
    da_res_levels = da_common;
    da_res_samesd = 0;
    da_res_li = possibly_li;
    da_dir.clear(); da_scalar.clear(); da_dist.clear();
    for k in da_common { da_dir.push(DV_ALL); da_scalar.push(true); da_dist.push(-1); }
    da_pair_class.clear(); da_pair_loops.clear();
    for p in pairs {
        let c, lp = da_classify_pair(da_pair_src[p], sl, da_pair_dst[p], dl);
        da_pair_class.push(c);
        da_pair_loops.push(lp);
    }
    for si in pairs {
        let sr = sc_get_signed_range(da_pair_src[si]);
        let dr = sc_get_signed_range(da_pair_dst[si]);
        if rg_is_empty(rg_intersect(sr, dr)) { da_res_kind = 0; return; }
        let c = da_pair_class[si];
        if c == SUB_NONLINEAR {
            da_pair_loops[si] = da_collect_common_loops(da_pair_src[si], sl, da_pair_loops[si]);
            da_pair_loops[si] = da_collect_common_loops(da_pair_dst[si], dl, da_pair_loops[si]);
        } else if c == SUB_ZIV {
            if da_test_ziv(da_pair_src[si], da_pair_dst[si]) { da_res_kind = 0; return; }
        } else if c == SUB_SIV {
            if da_test_siv(da_pair_src[si], da_pair_dst[si], under_rt) { da_res_kind = 0; return; }
        } else if c == SUB_RDIV {
            if da_test_rdiv(da_pair_src[si], da_pair_dst[si]) { da_res_kind = 0; return; }
        } else {
            if da_test_miv(da_pair_src[si], da_pair_dst[si], da_pair_loops[si]) { da_res_kind = 0; return; }
        }
    }
    var complete: u64 = 0;
    for si in pairs { complete = complete | da_pair_loops[si]; }
    for ii in 1..da_common + 1 { if (complete & da_bit(ii)) != 0 { da_scalar[ii - 1] = false; } }
    for ii in 1..da_res_levels + 1 {
        if da_dir[ii - 1] == DV_EQ && da_dist[ii - 1] < 0 { da_dist[ii - 1] = sc_get_zero(sc_ty(sscev)); }
    }
    if da_samesd_levels > 0 {
        da_common -= da_samesd_levels;
        da_max += da_samesd_levels;
        da_res_levels = da_common;
        da_res_samesd = da_samesd_levels;
    }
    if possibly_li {
        for ii in 1..da_common + 1 {
            if (da_dir[ii - 1] & DV_EQ) == 0 { da_res_li = false; break; }
        }
    } else {
        var all_eq = true;
        for ii in 1..da_common + 1 { if da_dir[ii - 1] != DV_EQ { all_eq = false; break; } }
        if all_eq && su_n(da_res_assume) == 0 { da_res_kind = 0; return; }
    }
}

// ---------------------------------------------------------------------------------------------
// print<da> (dumpExampleDependence)

fn print_da(fv: i32, normalize: bool) {
    // DependenceAnalysis::run: AAManager, ScalarEvolution, LoopInfo; then the printer's SE and LI
    aa_begin(fv);
    scev_get(fv);
    li_get(fv);
    da_read_options();
    errs("Printing analysis 'Dependence Analysis' for function '");
    errs(val_name(fv));
    errs("':\n");
    st_touch(fv);
    var memi: i32[>..<] = [];
    var bb = func_first_block(fv);
    while bb >= 0 {
        var i = block_first(bb);
        while i >= 0 { if inst_may_read_or_write_memory(i) { memi.push(i); } i = inst_next(i); }
        bb = block_next(bb);
    }
    for a in memi.len {
        for b in a..memi.len {
            let s = memi[a];
            let d = memi[b];
            errs("Src:");
            errs_inst(s, fv);
            errs(" --> Dst:");
            errs_inst(d, fv);
            errs("\n  da analyze - ");
            da_depends(s, d, true);
            if da_res_kind != 0 {
                if normalize && da_normalize() { errs("normalized - "); }
                da_dump();
            } else {
                errs("none!\n");
            }
        }
    }
}
