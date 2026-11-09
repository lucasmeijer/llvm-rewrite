// ScalarEvolution: howManyLessThans / howManyGreaterThans / computeMaxBECountForLT, willNotOverflow,
// SCEV predicates (compare and wrap predicates, uniqued) and SCEVPredicateRewriter /
// convertSCEVToAddRecWithPredicates. Port of the corresponding parts of llvm/lib/Analysis/ScalarEvolution.cpp.
import std;
import scev_guards;
import implied;
import ir;
import irutil;
import flags;
import pm;
import apint;
import constrange;
import loopinfo;
import domtree;
import scev;
import scev_create;
import scev_range;
import scev_btc;
import scev_pred;
import scev_eval;

// ---------------------------------------------------------------------------------------------
// Predicates (UniquePreds)

let PK_COMPARE = 0;
let PK_WRAP = 1;
let IW_NUSW: i64 = 1;
let IW_NSSW: i64 = 2;
struct SPred { kind: u8, pred: i32, lhs: i32, rhs: i32 }   // wrap: lhs = AddRec, pred = flags
var sc_preds: SPred[>..];

recursive fn sc_get_compare_predicate(p: i64, l: i32, r: i32) -> i32 {
    for k in sc_preds.len { let x = sc_preds[k]; if x.kind as i64 == PK_COMPARE && x.pred as i64 == p && x.lhs == l && x.rhs == r { return k as i32; } }
    sc_preds.push(SPred { kind: PK_COMPARE as u8, pred: p as i32, lhs: l, rhs: r });
    return (sc_preds.len - 1) as i32;
}
recursive fn sc_get_wrap_predicate(ar: i32, f: i64) -> i32 {
    for k in sc_preds.len { let x = sc_preds[k]; if x.kind as i64 == PK_WRAP && x.lhs == ar && x.pred as i64 == f { return k as i32; } }
    sc_preds.push(SPred { kind: PK_WRAP as u8, pred: f as i32, lhs: ar, rhs: -1 });
    return (sc_preds.len - 1) as i32;
}

fn sc_pred_name(p: i64) -> const u8[:] {
    match p {
        P_EQ => { return "eq"; }, P_NE => { return "ne"; }, P_UGT => { return "ugt"; }, P_UGE => { return "uge"; },
        P_ULT => { return "ult"; }, P_ULE => { return "ule"; }, P_SGT => { return "sgt"; }, P_SGE => { return "sge"; },
        P_SLT => { return "slt"; }, P_SLE => { return "sle"; }, _ => { return "?"; },
    }
}

// SCEVPredicate::print(OS, Depth)
recursive fn sc_print_predicate(p: i32, depth: i64) {
    let x = sc_preds[p];
    for k in depth { errs(" "); }
    if x.kind as i64 == PK_COMPARE {
        if x.pred as i64 == P_EQ { errs("Equal predicate: "); sc_print(x.lhs); errs(" == "); sc_print(x.rhs); errs("\n"); }
        else { errs("Compare predicate: "); sc_print(x.lhs); errs(" "); errs(sc_pred_name(x.pred as i64)); errs(") "); sc_print(x.rhs); errs("\n"); }
        return;
    }
    sc_print(x.lhs);
    errs(" Added Flags: ");
    if ((x.pred as i64) & IW_NUSW) != 0 { errs("<nusw>"); }
    if ((x.pred as i64) & IW_NSSW) != 0 { errs("<nssw>"); }
    errs("\n");
}

recursive fn scev_reset_lt() { sc_preds.resize(0); }

// PredicatedSCEVRewrites is only filled by createAddRecFromPHIWithCasts (not ported past its matching)
recursive fn sc_forget_predicated_rewrites() { }

// ---------------------------------------------------------------------------------------------
// SCEVPredicateRewriter (NewPreds on sc_tpreds, no Pred) / convertSCEVToAddRecWithPredicates

var sc_tpreds: i32[>..<];

recursive fn sc_rw_visit_unknown_ext(rw: RW&, s: i32) -> i32 {
    if rw.kind as i64 == RW_PREDICATE { return sc_convert_to_addrec_with_preds_unknown(rw, s); }
    if rw.kind as i64 == RW_GUARDS { return sc_guards_rewrite_unknown(rw, s); }
    fatal("internal: rewriter kind");
    return s;
}

recursive fn sc_convert_to_addrec_with_preds_unknown(rw: RW&, s: i32) -> i32 {
    // With a Pred (a union predicate, rw.becond >= 0): an `Equal predicate: s == X` rewrites s to X
    if rw.becond >= 0 {
        let u = rw.becond;
        for k in su_n(u) {
            let p = su_get(u, k);
            let x = sc_preds[p];
            if x.kind as i64 == PK_COMPARE && x.lhs == s && x.pred as i64 == P_EQ { return x.rhs; }
        }
    }
    let v = sc_value(s);
    if !sc_is_phi_value(v) { return s; }
    let r = sc_create_addrec_from_phi_with_casts(s);
    if r < 0 { return s; }
    fatal("ScalarEvolution: predicated rewrites of casted PHIs are not ported");
    return s;
}

// The zext/sext visitors of SCEVPredicateRewriter
recursive fn sc_rw_predicate_ext(rw: RW&, s: i32) -> i32 {
    let o = sc_rw_visit(rw, sc_op(s, 0));
    let k = sc_kind(s);
    if sc_is_addrec(o) && sc_loop(o) == rw.l && sc_is_affine(o) {
        let step = sc_get_step_recurrence(o);
        let ty = sc_ty(s);
        let f = if k == SC_ZEXT { IW_NUSW } else { IW_NSSW };
        // addOverflowAssumption: NewPreds collects it; with only a Pred it must already be implied
        let wp = sc_get_wrap_predicate(o, f);
        var ok = true;
        if rw.becond >= 0 { ok = su_implies(rw.becond, wp); } else { sc_tpreds.push(wp); }
        if ok {
            if k == SC_ZEXT { return sc_addrec2(sc_get_zero_extend(sc_op(o, 0), ty, 0), sc_get_sign_extend(step, ty, 0), rw.l, sc_flags(o)); }
            return sc_addrec2(sc_get_sign_extend(sc_op(o, 0), ty, 0), sc_get_sign_extend(step, ty, 0), rw.l, sc_flags(o));
        }
    }
    if k == SC_ZEXT { return sc_get_zero_extend(o, sc_ty(s), 0); }
    return sc_get_sign_extend(o, sc_ty(s), 0);
}

// convertSCEVToAddRecWithPredicates: the AddRec or -1; its predicates are pushed on sc_lin_preds
recursive fn sc_convert_to_addrec_with_predicates(s: i32, l: i32) -> i32 {
    let tm = sc_tpreds.len;
    var rw = rw_new(RW_PREDICATE, l);
    let r = sc_rw_visit(rw, s);
    if !sc_is_addrec(r) { sc_tpreds.resize(tm); return -1; }
    for k in tm..sc_tpreds.len {
        let p = sc_preds[sc_tpreds[k]];
        if p.kind as i64 != PK_WRAP || p.pred as i64 != IW_NSSW { continue; }
        let ar = p.lhs;
        var ec = sc_get_backedge_taken_count(sc_loop(ar), BTC_EXACT);
        if sc_is_cnc(ec) { continue; }
        let step = sc_get_step_recurrence(ar);
        if !sc_is_one(step) { continue; }
        ec = sc_get_truncate_or_sign_extend(ec, sc_ty(step), 0);
        let add = sc_add(sc_op(ar, 0), ec);
        if sc_is_known_predicate(P_SLT, add, sc_op(ar, 0)) { sc_tpreds.resize(tm); return -1; }
    }
    for k in tm..sc_tpreds.len { sc_lin_preds.push(sc_tpreds[k]); }
    sc_tpreds.resize(tm);
    return r;
}

// createAddRecFromPHIWithCasts: -1 = std::nullopt (the predicated rewrite itself is not ported)
recursive fn sc_create_addrec_from_phi_with_casts(sym: i32) -> i32 {
    let pn = sc_value(sym);
    if !ty_is_int(vals[pn].ty) { return -1; }
    let l = li_loop_for(inst_parent(pn));
    if l < 0 || loop_header(l) != inst_parent(pn) { return -1; }
    let bev, stv = sc_phi_be_and_start(pn, l);
    if bev < 0 || stv < 0 { return -1; }
    let be = sc_get_scev(bev);
    if sc_kind(be) != SC_ADD { return -1; }
    for i in sc_nops(be) {
        let o = sc_op(be, i);
        if o == sym { continue; }
        if sc_bits(sym) != sc_bits(o) { continue; }
        let k = sc_kind(o);
        if (k == SC_SEXT || k == SC_ZEXT) && sc_kind(sc_op(o, 0)) == SC_TRUNC && sc_op(sc_op(o, 0), 0) == sym {
            fatal("ScalarEvolution: createAddRecFromPHIWithCasts is not ported");
        }
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// willNotOverflow

recursive fn sc_will_not_overflow(opc: i64, signed: bool, lhs: i32, rhs: i32, cx: i32) -> bool {
    let nt = sc_ty(lhs);
    let wt = ty_int(ty_bits(nt) * 2);
    fn operation(a: i32, b: i32) -> i32 {
        if opc == OP_ADD { return sc_add2(a, b, SF_ANY, 0); }
        if opc == OP_SUB { return sc_get_minus(a, b, SF_ANY, 0); }
        return sc_mul2(a, b, SF_ANY, 0);
    }
    fn ext(a: i32) -> i32 { if signed { sc_get_sign_extend(a, wt, 0) } else { sc_get_zero_extend(a, wt, 0) } }
    let a = ext(operation(lhs, rhs));
    let lb = ext(lhs);
    let rb = ext(rhs);
    let b = operation(lb, rb);
    if a == b { return true; }
    if cx < 0 { return false; }
    if opc == OP_MUL { return false; }
    if !sc_is_const(rhs) { return false; }
    let c = sc_ap(rhs);
    let nb = c.w as i64;
    let is_sub = opc == OP_SUB;
    let neg_c = signed && ap_is_neg(c);
    let down = is_sub != neg_c;
    var mag = c;
    if neg_c {
        if ap_eq(c, ap_smin_val(nb)) { return false; }
        mag = ap_neg(c);
    }
    let pred = if signed { P_SLE } else { P_ULE };
    if down {
        let mn = if signed { ap_smin_val(nb) } else { ap_zero(nb) };
        return sc_is_known_predicate_at(pred, sc_get_constant(ap_add(mn, mag)), lhs, cx);
    }
    let mx = if signed { ap_smax_val(nb) } else { ap_ones(nb) };
    return sc_is_known_predicate_at(pred, lhs, sc_get_constant(ap_sub(mx, mag)), cx);
}

// ---------------------------------------------------------------------------------------------
// howManyLessThans / howManyGreaterThans

recursive fn sc_compute_max_bec_for_lt(start: i32, stride: i32, end: i32, bw: i64, signed: bool) -> i32 {
    if signed && bw == 1 { return sc_get_zero(sc_ty(stride)); }
    if signed && sc_is_known_negative(stride) { return SCEV_CNC; }
    let mstart = if signed { sc_get_signed_range_min(start) } else { sc_get_unsigned_range_min(start) };
    let mstride = if signed { sc_get_signed_range_min(stride) } else { sc_get_unsigned_range_min(stride) };
    let one = ap_u64(1, bw);
    let sfm = if signed { ap_smax(one, mstride) } else { ap_umax(one, mstride) };
    let mv = if signed { ap_smax_val(bw) } else { ap_ones(bw) };
    let lim = ap_sub(mv, ap_dec(sfm));
    var mend = if signed { ap_smin(sc_get_signed_range_max(end), lim) } else { ap_umin(sc_get_unsigned_range_max(end), lim) };
    mend = if signed { ap_smax(mend, mstart) } else { ap_umax(mend, mstart) };
    return sc_get_udiv_ceil(sc_get_constant(ap_sub(mend, mstart)), sc_get_constant(sfm));
}

recursive fn sc_how_many_less_thans(lhs: i32, rhs0: i32, l: i32, signed: bool, only: bool, allow_preds: bool) -> EL {
    var rhs = rhs0;
    let pm = sc_lin_preds.len;
    var iv = if sc_is_addrec(lhs) { lhs } else { -1 };
    var pred_iv = false;
    if iv < 0 && sc_kind(lhs) == SC_ZEXT {
        let ar = sc_op(lhs, 0);
        if sc_is_addrec(ar) && sc_loop(ar) == l && sc_is_affine(ar) {
            fn can_prove_nuw() -> bool {
                if !only { return false; }
                if !sc_is_loop_invariant(rhs, l) { return false; }
                if !sc_is_known_non_zero(sc_get_step_recurrence(ar)) { return false; }
                let ib = sc_bits(ar);
                let ob = sc_bits(rhs);
                let smax = sc_get_unsigned_range_max(sc_get_step_recurrence(ar));
                let lim = ap_zext(ap_sub(ap_ones(ib), ap_dec(smax)), ob);
                return ap_ule(sc_get_unsigned_range_max(sc_apply_loop_guards(rhs, l)), lim);
            }
            var f = sc_flags(ar);
            if (f & SF_NUW) == 0 && can_prove_nuw() { f |= SF_NUW; }
            sc_set_nowrap_flags(ar, f);
            if sc_has_nuw(ar) {
                let step = sc_get_step_recurrence(ar);
                let ty = sc_ty(lhs);
                let s = sc_addrec2(sc_get_extend_addrec_start(ar, ty, 0, false), sc_get_zero_extend(step, ty, 0), l, sc_flags(ar));
                iv = if sc_is_addrec(s) { s } else { -1 };
            }
        }
    }
    if iv < 0 && allow_preds {
        iv = sc_convert_to_addrec_with_predicates(lhs, l);
        pred_iv = true;
    }
    if iv < 0 || sc_loop(iv) != l || !sc_is_affine(iv) { sc_lin_preds.resize(pm); return el_cnc(); }
    let wt = if signed { SF_NSW } else { SF_NUW };
    let nowrap = only && (sc_flags(iv) & wt) != 0;
    let cond = if signed { P_SLT } else { P_ULT };
    var stride = sc_get_step_recurrence(iv);
    let pos = sc_is_known_positive(stride);
    if !pos {
        if pred_iv || !nowrap || !sc_loop_is_finite_by_assumption(l) || !sc_loop_has_no_abnormal_exits(l) { sc_lin_preds.resize(pm); return el_cnc(); }
        if !sc_is_known_non_zero(stride) {
            if !sc_is_loop_invariant(rhs, l) { sc_lin_preds.resize(pm); return el_cnc(); }
            let siz = sc_minus(sc_op(iv, 0), stride);
            if !sc_is_loop_entry_guarded_by_cond(l, cond, siz, rhs) { stride = sc_umax(stride, sc_get_one(sc_ty(stride))); }
        }
    } else if !nowrap {
        if sc_can_iv_overflow_on_lt(rhs, stride, signed) { sc_lin_preds.resize(pm); return el_cnc(); }
    }
    var start = sc_op(iv, 0);
    let ostart = start;
    let orhs = rhs;
    if sc_is_ptr(start) { start = sc_get_lossless_ptr_to_int(start); if sc_is_cnc(start) { sc_lin_preds.resize(pm); return el_one(start); } }
    if sc_is_ptr(rhs) { rhs = sc_get_lossless_ptr_to_int(rhs); if sc_is_cnc(rhs) { sc_lin_preds.resize(pm); return el_one(rhs); } }
    var end: i32 = -1;
    var bec: i32 = -1;
    var becbt: i32 = -1;
    if !sc_is_loop_invariant(rhs, l) {
        if pos && sc_is_addrec(rhs) && sc_loop(rhs) == l && sc_flags(rhs) != 0 {
            let rs = sc_op(rhs, 0);
            let rst = sc_get_step_recurrence(rhs);
            if sc_is_known_negative(rst) && sc_will_not_overflow(OP_SUB, true, stride, rst, -1) {
                let den = sc_minus(stride, rst);
                if sc_is_known_positive(den) {
                    end = if signed { sc_smax(rs, start) } else { sc_umax(rs, start) };
                    let delta = sc_minus(end, start);
                    bec = sc_get_udiv_ceil(delta, den);
                    becbt = sc_get_udiv_ceil(sc_minus(rs, start), den);
                }
            }
        }
        if bec < 0 {
            let mbc = sc_compute_max_bec_for_lt(start, stride, rhs, sc_bits(lhs), signed);
            let pat, np = sc_preds_from_lin(pm);
            return el_make(SCEV_CNC, mbc, mbc, false, pat, np);
        }
    } else {
        let osms = sc_minus(ostart, stride);
        if sc_is_loop_entry_guarded_by_cond(l, cond, osms, ostart) && sc_is_loop_entry_guarded_by_cond(l, cond, osms, orhs) {
            let m1 = sc_get_minus_one(sc_ty(stride));
            let num = sc_minus(sc_add(rhs, m1), sc_minus(start, stride));
            bec = sc_get_udiv(num, stride);
        }
        if bec < 0 {
            fn can_prove_rhs_ge_start() -> bool {
                let cge = if signed { P_SGE } else { P_UGE };
                let grhs = sc_apply_loop_guards(orhs, l);
                let gstart = sc_apply_loop_guards(ostart, l);
                if sc_is_loop_entry_guarded_by_cond(l, cge, orhs, ostart) || sc_is_known_predicate(cge, grhs, gstart) { return true; }
                let cgt = if signed { P_SGT } else { P_UGT };
                let sm1 = sc_add(ostart, sc_get_minus_one(sc_ty(ostart)));
                return sc_is_loop_entry_guarded_by_cond(l, cgt, orhs, sm1);
            }
            if can_prove_rhs_ge_start() { end = rhs; }
            else {
                end = if signed { sc_smax(rhs, start) } else { sc_umax(rhs, start) };
                becbt = sc_get_udiv_ceil(sc_minus(rhs, start), stride);
            }
            let one = sc_get_one(sc_ty(stride));
            var may_overflow = true;
            if sc_is_known_to_be_power_of_two(stride, false, false) { may_overflow = false; }
            else if start == stride || start == sc_minus(stride, one) { may_overflow = false; }
            let delta = sc_minus(end, start);
            if !may_overflow { bec = sc_get_udiv(sc_add(delta, sc_minus(stride, one)), stride); }
            else { bec = sc_get_udiv_ceil(delta, stride); }
        }
    }
    var cmax = SCEV_CNC;
    var moz = false;
    if sc_is_const(bec) { cmax = bec; }
    else if becbt >= 0 && sc_is_const(becbt) { cmax = becbt; moz = true; }
    else { cmax = sc_compute_max_bec_for_lt(start, stride, rhs, sc_bits(lhs), signed); }
    if sc_is_cnc(cmax) && !sc_is_cnc(bec) { cmax = sc_get_constant(sc_get_unsigned_range_max(bec)); }
    let smax = if sc_is_cnc(bec) { cmax } else { bec };
    let pat, np = sc_preds_from_lin(pm);
    return el_make(bec, cmax, smax, moz, pat, np);
}

recursive fn sc_how_many_greater_thans(lhs: i32, rhs: i32, l: i32, signed: bool, only: bool, allow_preds: bool) -> EL {
    let pm = sc_lin_preds.len;
    if !sc_is_loop_invariant(rhs, l) { return el_cnc(); }
    var iv = if sc_is_addrec(lhs) { lhs } else { -1 };
    if iv < 0 && allow_preds { iv = sc_convert_to_addrec_with_predicates(lhs, l); }
    if iv < 0 || sc_loop(iv) != l || !sc_is_affine(iv) { sc_lin_preds.resize(pm); return el_cnc(); }
    let wt = if signed { SF_NSW } else { SF_NUW };
    let nowrap = only && (sc_flags(iv) & wt) != 0;
    let cond = if signed { P_SGT } else { P_UGT };
    let stride = sc_get_negative(sc_get_step_recurrence(iv), SF_ANY);
    if !sc_is_known_positive(stride) { sc_lin_preds.resize(pm); return el_cnc(); }
    if !sc_is_one(stride) && !nowrap {
        if sc_can_iv_overflow_on_gt(rhs, stride, signed) { sc_lin_preds.resize(pm); return el_cnc(); }
    }
    var start = sc_op(iv, 0);
    var end = rhs;
    if !sc_is_loop_entry_guarded_by_cond(l, cond, sc_add(start, stride), rhs) {
        if sc_is_loop_entry_guarded_by_cond(l, if signed { P_SGE } else { P_UGE }, start, rhs) { end = rhs; }
        else { end = if signed { sc_smin(rhs, start) } else { sc_umin(rhs, start) }; }
    }
    if sc_is_ptr(start) { start = sc_get_lossless_ptr_to_int(start); if sc_is_cnc(start) { sc_lin_preds.resize(pm); return el_one(start); } }
    if sc_is_ptr(end) { end = sc_get_lossless_ptr_to_int(end); if sc_is_cnc(end) { sc_lin_preds.resize(pm); return el_one(end); } }
    let one = sc_get_one(sc_ty(stride));
    let bec = sc_get_udiv(sc_add(sc_minus(start, end), sc_minus(stride, one)), stride);
    let mstart = if signed { sc_get_signed_range_max(start) } else { sc_get_unsigned_range_max(start) };
    let mstride = if signed { sc_get_signed_range_min(stride) } else { sc_get_unsigned_range_min(stride) };
    let bw = sc_bits(lhs);
    let lim = if signed { ap_add(ap_smin_val(bw), ap_dec(mstride)) } else { ap_add(ap_zero(bw), ap_dec(mstride)) };
    let mend = if signed { ap_smax(sc_get_signed_range_min(rhs), lim) } else { ap_umax(sc_get_unsigned_range_min(rhs), lim) };
    var cmax = if sc_is_const(bec) { bec } else { sc_get_udiv_ceil(sc_get_constant(ap_sub(mstart, mend)), sc_get_constant(mstride)) };
    if sc_is_cnc(cmax) { cmax = bec; }
    let smax = if sc_is_cnc(bec) { cmax } else { bec };
    let pat, np = sc_preds_from_lin(pm);
    return el_make(bec, cmax, smax, false, pat, np);
}

// ---------------------------------------------------------------------------------------------
// SCEVUnionPredicate (immutable runs of predicate ids in su_pool; id 0 is the empty union),
// SCEVComparePredicate / SCEVWrapPredicate implies and isAlwaysTrue, getImpliedFlags, rewriteUsingPredicate.

struct SURun { at: i32, n: i32 }
var su_runs: SURun[>..];
var su_pool: i32[>..];

recursive fn su_n(u: i32) -> i64 { su_runs[u].n as i64 }
recursive fn su_get(u: i32, k: i64) -> i32 { su_pool[(su_runs[u].at as i64) + k] }
// a new union from the run on su_tmp[from..]
var su_tmp: i32[>..<];
recursive fn su_make(from: i64) -> i32 {
    let at = su_pool.len as i32;
    for k in from..su_tmp.len { su_pool.push(su_tmp[k]); }
    su_runs.push(SURun { at: at, n: (su_tmp.len - from) as i32 });
    return (su_runs.len - 1) as i32;
}
recursive fn su_empty() -> i32 {
    if su_runs.len == 0 { su_runs.push(SURun { at: 0, n: 0 }); }
    return 0;
}

// SCEVWrapPredicate::getImpliedFlags(AR, SE)
recursive fn sc_wrap_implied_flags(ar: i32) -> i64 {
    var f: i64 = 0;
    let sf = sc_flags(ar);
    if (sf & SF_NSW) == SF_NSW { f = IW_NSSW; }
    if (sf & SF_NUW) == SF_NUW {
        let st = sc_get_step_recurrence(ar);
        if sc_is_const(st) && !ap_is_neg(sc_ap(st)) { f |= IW_NUSW; }
    }
    return f;
}

// SCEVPredicate::isAlwaysTrue
recursive fn sc_pred_always_true(p: i32) -> bool {
    let x = sc_preds[p];
    if x.kind as i64 == PK_COMPARE { return false; }
    var f = x.pred as i64;
    if (sc_flags(x.lhs) & SF_NSW) == SF_NSW { f &= ~IW_NSSW; }
    return f == 0;
}
recursive fn su_always_true(u: i32) -> bool {
    for k in su_n(u) { if !sc_pred_always_true(su_get(u, k)) { return false; } }
    return true;
}

// SCEVPredicate::implies(N) for a compare or wrap predicate a
recursive fn sc_pred_implies(a: i32, n: i32) -> bool {
    let x = sc_preds[a];
    let y = sc_preds[n];
    if x.kind as i64 == PK_COMPARE {
        if y.kind as i64 != PK_COMPARE { return false; }
        if x.pred as i64 != P_EQ { return false; }
        return y.lhs == x.lhs && y.rhs == x.rhs;
    }
    if y.kind as i64 != PK_WRAP { return false; }
    let flags = x.pred as i64;
    if (flags | (y.pred as i64)) != flags { return false; }
    if y.lhs == x.lhs { return true; }
    if flags != IW_NSSW && flags != IW_NUSW { return false; }
    let ar = x.lhs;
    let oar = y.lhs;
    var start = sc_op(ar, 0);
    var ostart = sc_op(oar, 0);
    let sp = sc_is_ptr_ty(sc_ty(start));
    if sp != sc_is_ptr_ty(sc_ty(ostart)) { return false; }
    if sp && sc_ty(start) != sc_ty(ostart) { return false; }
    if sc_type_bits(sc_ty(ar)) > sc_type_bits(sc_ty(oar)) { return false; }
    var step = sc_get_step_recurrence(ar);
    var ostep = sc_get_step_recurrence(oar);
    if !sc_is_known_positive(step) || !sc_is_known_positive(ostep) { return false; }
    let wt = if sc_type_bits(sc_ty(step)) >= sc_type_bits(sc_ty(ostep)) { sc_ty(step) } else { sc_ty(ostep) };
    step = sc_get_noop_or_zero_extend(step, wt);
    ostep = sc_get_noop_or_zero_extend(ostep, wt);
    let nuw = flags == IW_NUSW;
    ostart = if nuw { sc_get_noop_or_zero_extend(ostart, wt) } else { sc_get_noop_or_sign_extend(ostart, wt) };
    start = if nuw { sc_get_noop_or_zero_extend(start, wt) } else { sc_get_noop_or_sign_extend(start, wt) };
    let pr = if nuw { P_ULE } else { P_SLE };
    return sc_is_known_predicate(pr, ostep, step) && sc_is_known_predicate(pr, ostart, start);
}

// SCEVUnionPredicate::implies(N) for a single predicate N
recursive fn su_implies(u: i32, n: i32) -> bool {
    for k in su_n(u) { if sc_pred_implies(su_get(u, k), n) { return true; } }
    let y = sc_preds[n];
    if y.kind as i64 != PK_WRAP { return false; }
    let l = sc_loop(y.lhs);
    for k in su_n(u) {
        let p = su_get(u, k);
        let x = sc_preds[p];
        if x.kind as i64 != PK_WRAP { continue; }
        let r = sc_rewrite_using_predicate(x.lhs, l, u);
        if !sc_is_addrec(r) { continue; }
        if sc_pred_implies(sc_get_wrap_predicate(r, x.pred as i64), n) { return true; }
    }
    return false;
}

// SCEVUnionPredicate::add(N): the new union (on top of the run of u)
recursive fn su_add(u: i32, n: i32) -> i32 {
    let check = su_n(u) < 16;
    if check && su_implies(u, n) { return u; }
    let b = su_tmp.len;
    for k in su_n(u) {
        let p = su_get(u, k);
        if check && sc_pred_implies(n, p) { continue; }
        su_tmp.push(p);
    }
    su_tmp.push(n);
    let r = su_make(b);
    su_tmp.resize(b);
    return r;
}

// ScalarEvolution::rewriteUsingPredicate(S, L, Preds) with a union predicate
recursive fn sc_rewrite_using_predicate(s: i32, l: i32, u: i32) -> i32 {
    var rw = rw_new(RW_PREDICATE, l);
    rw.becond = u;
    return sc_rw_visit(rw, s);
}

// SCEVUnionPredicate::print
recursive fn su_print(u: i32, depth: i64) { for k in su_n(u) { sc_print_predicate(su_get(u, k), depth); } }
