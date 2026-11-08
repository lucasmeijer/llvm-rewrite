// ScalarEvolution: backedge-taken counts. BackedgeTakenInfo / ExitLimit, computeBackedgeTakenCount,
// computeExitLimit*, the exit-count helpers (trip counts, multiples), computeShiftCompareExitLimit,
// forgetting. Port of the corresponding parts of llvm/lib/Analysis/ScalarEvolution.cpp.
import std;
import scev_lt;
import scev_guards;
import implied;
import ir;
import irutil;
import instinfo;
import calls;
import pm;
import vt;
import knownbits;
import gen_iids;
import apint;
import constrange;
import loopinfo;
import domtree;
import scev;
import scev_create;
import scev_range;
import scev_pred;
import scev_eval;

let BTC_EXACT = 0;
let BTC_CONSTANT_MAX = 1;
let BTC_SYMBOLIC_MAX = 2;

// ExitLimit; predicates are a run [pat, pat+np) in sc_predl
struct EL { exact: i32, cmax: i32, smax: i32, moz: bool, pat: i32, np: i32 }
var sc_predl: i32[>..];

recursive fn el_cnc() -> EL { EL { exact: SCEV_CNC, cmax: SCEV_CNC, smax: SCEV_CNC, moz: false, pat: 0, np: 0 } }
recursive fn el_one(e: i32) -> EL { el_make(e, e, e, false, 0, 0) }
// ExitLimit(E, ConstantMax, SymbolicMax, MaxOrZero, Predicates)
recursive fn el_make(e0: i32, cmax: i32, smax0: i32, moz: bool, pat: i32, np: i32) -> EL {
    var e = e0;
    var smax = smax0;
    if sc_is_zero(cmax) { e = cmax; smax = cmax; }
    return EL { exact: e, cmax: cmax, smax: smax, moz: moz, pat: pat, np: np };
}
recursive fn el_has_any_info(x: EL) -> bool { !sc_is_cnc(x.exact) || !sc_is_cnc(x.cmax) }
recursive fn el_has_full_info(x: EL) -> bool { !sc_is_cnc(x.exact) }
// ExitLimit(..., {PredList0, PredList1}): the union of two predicate lists without duplicates
recursive fn sc_pred_union(a: EL, b: EL) -> i32, i32 {
    if a.np == 0 && b.np == 0 { return 0, 0; }
    let at = sc_predl.len as i32;
    for k in a.np { let p = sc_predl[a.pat + k]; if !sc_predl_has(at, p) { sc_predl.push(p); } }
    for k in b.np { let p = sc_predl[b.pat + k]; if !sc_predl_has(at, p) { sc_predl.push(p); } }
    return at, (sc_predl.len as i32) - at;
}
recursive fn sc_predl_has(at: i32, p: i32) -> bool { var k = at as i64; while k < sc_predl.len { if sc_predl[k] == p { return true; } k++; } return false; }

// ExitNotTakenInfo
struct ENT { bb: i32, exact: i32, cmax: i32, smax: i32, pat: i32, np: i32 }
var sc_ents: ENT[>..];
// BackedgeTakenInfo
struct BTI { at: i32, n: i32, complete: bool, cmax: i32, moz: bool, symmax: i32 }
var sc_btis: BTI[>..];
var sc_bti_map = hm_new();      // (loop << 1 | predicated) -> index in sc_btis
var sc_cevl_exit = hm_new();    // ConstantEvolutionLoopExitValue: phi -> constant value id

recursive fn scev_reset_btc() {
    sc_predl.resize(0);
    sc_predl.push(0);
    sc_ents.resize(0);
    sc_btis.resize(0);
    hm_clear(sc_bti_map);
    hm_clear(sc_cevl_exit);
    sc_elc.resize(0);
    scev_reset_pred();
    scev_reset_eval();
    scev_reset_lt();
}

recursive fn bti_empty() -> BTI { BTI { at: 0, n: 0, complete: false, cmax: -1, moz: false, symmax: -1 } }

// getBackedgeTakenInfo / getPredicatedBackedgeTakenInfo: index into sc_btis
recursive fn sc_get_bti(l: i32, pred: bool) -> i64 {
    if pred {
        let b = sc_get_bti(l, false);
        if sc_btis[b].complete { return b; }
    }
    let key = ((l as i64) << 1 | (if pred { 1 } else { 0 })) as u64;
    let f = hm_get(sc_bti_map, key, -1);
    if f >= 0 { return f; }
    let idx = sc_btis.len;
    sc_btis.push(bti_empty());
    hm_put(sc_bti_map, key, idx);
    let r = sc_compute_backedge_taken_count(l, pred);
    if !pred && (r.n > 0 || !sc_is_cnc(if r.cmax < 0 { SCEV_CNC } else { r.cmax })) {
        // forgetMemoizedResults(LoopUsers[L]); ConstantEvolutionLoopExitValue.erase(header phis)
        var u = hm_get(sc_loop_users, l as u64, -1) as i32;
        // forgetMemoizedResults takes the whole list at once
        let mark = sc_seen.len;
        while u >= 0 { sc_forget_memoized_push(sc_lpool[u].val, mark); u = sc_lpool[u].next; }
        sc_forget_memoized_run(mark);
        var p = block_first(loop_header(l));
        while p >= 0 && is_phi(p) { hm_del(sc_cevl_exit, p as u64); p = inst_next(p); }
    }
    let cur = hm_get(sc_bti_map, key, -1);
    if cur >= 0 { sc_btis[cur] = r; return cur; }
    // forgotten while computing: LLVM's find(L)->second = Result re-inserts it
    let i2 = sc_btis.len;
    sc_btis.push(r);
    hm_put(sc_bti_map, key, i2);
    return i2;
}

// forgetMemoizedResults over a list: ToForget seeded with every element, then the transitive users
recursive fn sc_forget_memoized_push(s: i32, mark: i64) {
    for k in mark..sc_seen.len { if sc_seen[k] == s { return; } }
    sc_seen.push(s);
}
recursive fn sc_forget_memoized_run(mark: i64) {
    sc_side2_grow();
    let wl0 = sc_newops.len;
    for k in mark..sc_seen.len { sc_newops.push(sc_seen[k]); }
    while sc_newops.len > wl0 {
        let c = sc_newops.pop();
        var u = sc_users_head[c];
        while u >= 0 {
            let us = sc_lpool[u].val;
            var seen = false;
            for k in mark..sc_seen.len { if sc_seen[k] == us { seen = true; break; } }
            if !seen { sc_seen.push(us); sc_newops.push(us); }
            u = sc_lpool[u].next;
        }
    }
    let n = sc_seen.len;
    for k in mark..n { sc_forget_memoized_impl(sc_seen[k]); }
    sc_seen.resize(mark);
    sc_forget_predicated_rewrites();
}

// forgetBackedgeTakenCounts(L, Predicated)
recursive fn sc_forget_backedge_taken_counts(l: i32, pred: bool) {
    let key = ((l as i64) << 1 | (if pred { 1 } else { 0 })) as u64;
    hm_del(sc_bti_map, key);
}

// BackedgeTakenInfo::getExact(L, SE, Preds)
recursive fn sc_bti_get_exact(b: i64, l: i32, preds: bool) -> i32 {
    let x = sc_btis[b];
    if !x.complete || x.n == 0 { return SCEV_CNC; }
    let latch = loop_latch(l);
    if latch < 0 { return SCEV_CNC; }
    let sb = ss.len;
    for k in x.n {
        let e = sc_ents[x.at + k];
        ss.push(e.exact);
        if preds { for j in e.np { sc_out_preds.push(sc_predl[e.pat + j]); } }
    }
    return sc_get_umin_from_mismatched_n(sb, true);
}
// getConstantMax(SE, Predicates)
recursive fn sc_bti_get_constant_max(b: i64, preds: bool) -> i32 {
    let x = sc_btis[b];
    if x.cmax < 0 { return SCEV_CNC; }
    for k in x.n {
        let e = sc_ents[x.at + k];
        if e.np != 0 {
            if !preds { return SCEV_CNC; }
            for j in e.np { sc_out_preds.push(sc_predl[e.pat + j]); }
        }
    }
    return x.cmax;
}
// getSymbolicMax(L, SE, Predicates)
recursive fn sc_bti_get_symbolic_max(b: i64, l: i32, preds: bool) -> i32 {
    if sc_btis[b].symmax < 0 {
        let x = sc_btis[b];
        let sb = ss.len;
        for k in x.n {
            let e = sc_ents[x.at + k];
            if !sc_is_cnc(e.smax) {
                ss.push(e.smax);
                if preds { for j in e.np { sc_out_preds.push(sc_predl[e.pat + j]); } }
            }
        }
        var r = SCEV_CNC;
        if ss.len == sb { ss.resize(sb); } else { r = sc_get_umin_from_mismatched_n(sb, true); }
        sc_btis[b].symmax = r;
    }
    return sc_btis[b].symmax;
}
recursive fn sc_bti_is_constant_max_or_zero(b: i64) -> bool {
    let x = sc_btis[b];
    if !x.moz { return false; }
    for k in x.n { if sc_ents[x.at + k].np != 0 { return false; } }
    return true;
}
// getExitNotTaken(ExitingBlock, Predicates): index into sc_ents or -1
recursive fn sc_bti_exit_not_taken(b: i64, bb: i32, preds: bool) -> i64 {
    let x = sc_btis[b];
    for k in x.n {
        let e = sc_ents[x.at + k];
        if e.bb == bb {
            if e.np == 0 { return (x.at as i64) + k; }
            if preds { for j in e.np { sc_out_preds.push(sc_predl[e.pat + j]); } return (x.at as i64) + k; }
        }
    }
    return -1;
}

var sc_out_preds: i32[>..<];    // the Predicates out-parameter of the getPredicated* queries

recursive fn sc_get_backedge_taken_count(l: i32, kind: i64) -> i32 {
    let b = sc_get_bti(l, false);
    if kind == BTC_EXACT { return sc_bti_get_exact(b, l, false); }
    if kind == BTC_CONSTANT_MAX { return sc_bti_get_constant_max(b, false); }
    return sc_bti_get_symbolic_max(b, l, false);
}
recursive fn sc_get_constant_max_backedge_taken_count(l: i32) -> i32 { sc_get_backedge_taken_count(l, BTC_CONSTANT_MAX) }
recursive fn sc_get_symbolic_max_backedge_taken_count(l: i32) -> i32 { sc_get_backedge_taken_count(l, BTC_SYMBOLIC_MAX) }
recursive fn sc_is_backedge_taken_count_max_or_zero(l: i32) -> bool { sc_bti_is_constant_max_or_zero(sc_get_bti(l, false)) }
// getPredicated*BackedgeTakenCount: the predicates are appended to sc_out_preds
recursive fn sc_get_predicated_btc(l: i32, kind: i64) -> i32 {
    let b = sc_get_bti(l, true);
    if kind == BTC_EXACT { return sc_bti_get_exact(b, l, true); }
    if kind == BTC_CONSTANT_MAX { return sc_bti_get_constant_max(b, true); }
    return sc_bti_get_symbolic_max(b, l, true);
}

// getExitCount(L, ExitingBlock, Kind) / getPredicatedExitCount
recursive fn sc_get_exit_count(l: i32, bb: i32, kind: i64, pred: bool) -> i32 {
    let b = sc_get_bti(l, pred);
    let e = sc_bti_exit_not_taken(b, bb, pred);
    if e < 0 { return SCEV_CNC; }
    if kind == BTC_EXACT { return sc_ents[e].exact; }
    if kind == BTC_SYMBOLIC_MAX { return sc_ents[e].smax; }
    return sc_ents[e].cmax;
}

// getTripCountFromExitCount(ExitCount, EvalTy, L)
recursive fn sc_trip_count_from_exit_count_ty(ec: i32, eval_ty: i32, l: i32) -> i32 {
    if sc_is_cnc(ec) { return SCEV_CNC; }
    let ecs = sc_bits(ec);
    let es = ty_bits(eval_ty);
    var can = false;
    if es > ecs {
        let r = sc_get_range_ref(ec, HINT_UNSIGNED, 0);
        if !rg_contains_ap(r, ap_ones(ecs)) { can = true; }
        else if l >= 0 { can = sc_is_loop_entry_guarded_by_cond(l, P_NE, ec, sc_get_minus_one(sc_ty(ec))); }
    }
    if es > ecs && can { return sc_get_zero_extend(sc_add(ec, sc_get_one(sc_ty(ec))), eval_ty, 0); }
    return sc_add(sc_get_truncate_or_zero_extend(ec, eval_ty, 0), sc_get_one(eval_ty));
}
recursive fn sc_trip_count_from_exit_count(ec: i32) -> i32 {
    if sc_is_cnc(ec) { return SCEV_CNC; }
    return sc_trip_count_from_exit_count_ty(ec, ty_int(1 + sc_bits(ec)), -1);
}

recursive fn sc_constant_trip_count(ec: i32) -> i64 {
    if ec < 0 || !sc_is_const(ec) { return 0; }
    let a = sc_ap(ec);
    if ap_active_bits(a) > 32 { return 0; }
    return ((ap_lo64(a) as i64) + 1) & 0xFFFFFFFF;
}
recursive fn sc_get_small_constant_trip_count(l: i32) -> i64 { sc_constant_trip_count(sc_get_backedge_taken_count(l, BTC_EXACT)) }
recursive fn sc_get_small_constant_max_trip_count(l: i32) -> i64 { sc_constant_trip_count(sc_get_constant_max_backedge_taken_count(l)) }

recursive fn sc_gcd_u(a: i64, b: i64) -> i64 { var x = a; var y = b; while y != 0 { let t = x % y; x = y; y = t; } return x; }

// getSmallConstantTripMultiple(L)
recursive fn sc_get_small_constant_trip_multiple(l: i32) -> i64 {
    var res: i64 = -1;
    let em = sc_tmp.len;
    sc_push_exiting_blocks(l);
    let ee = sc_tmp.len;
    for k in em..ee {
        let bb = sc_tmp[k];
        let m = sc_trip_multiple_of_exit_count(l, sc_get_exit_count(l, bb, BTC_EXACT, false));
        if res < 0 { res = m; }
        res = sc_gcd_u(res, m);
    }
    sc_tmp.resize(em);
    return if res < 0 { 1 } else { res };
}
recursive fn sc_trip_multiple_of_exit_count(l: i32, ec: i32) -> i64 {
    if sc_is_cnc(ec) { return 1; }
    let tc = sc_trip_count_from_exit_count(sc_apply_loop_guards(ec, l));
    let m = sc_get_non_zero_constant_multiple(tc);
    if ap_active_bits(m) > 32 {
        let tz = ap_countr_zero(m);
        return (1 as i64) << (if tz < 31 { tz } else { 31 });
    }
    return ap_lo64(m) as i64;
}

// ---------------------------------------------------------------------------------------------
// computeBackedgeTakenCount

recursive fn sc_compute_backedge_taken_count(l: i32, allow_preds: bool) -> BTI {
    let xm = sc_tmp.len;
    sc_push_exiting_blocks(l);
    let xe = sc_tmp.len;
    // results go to a scratch run of ENTs (copied into sc_ents at the end)
    let em = sc_ent_tmp.len;
    var could = true;
    let latch = loop_latch(l);
    var must_max: i32 = -1;
    var may_max: i32 = -1;
    var must_moz = false;
    let only = xe - xm == 1;
    let nexit = xe - xm;
    for xk in xm..xe {
        let bb = sc_tmp[xk];
        let t = block_last(bb);
        if iop(t) == OP_CONDBR && vals[op(t, 0)].kind as i64 == VK_CINT {
            let exit_if_true = !loop_contains(l, term_succ(t, 0));
            if exit_if_true == ap_is_zero(ap_from_cint(op(t, 0))) { continue; }
        }
        let e = sc_compute_exit_limit(l, bb, only, allow_preds);
        if sc_is_cnc(e.exact) { could = false; }
        if !sc_is_cnc(e.smax) {
            sc_ent_tmp.push(ENT { bb: bb, exact: e.exact, cmax: e.cmax, smax: e.smax, pat: e.pat, np: e.np });
        }
        if !sc_is_cnc(e.cmax) && latch >= 0 && dt_dominates_block(DT_DOM, bb, latch) {
            if must_max < 0 { must_max = e.cmax; must_moz = e.moz; }
            else { must_max = sc_get_umin_from_mismatched(must_max, e.cmax, false); }
        } else if may_max != SCEV_CNC {
            if may_max < 0 || sc_is_cnc(e.cmax) { may_max = e.cmax; }
            else { may_max = sc_get_umax_from_mismatched(may_max, e.cmax); }
        }
    }
    sc_tmp.resize(xm);
    let maxbe = if must_max >= 0 { must_max } else if may_max >= 0 { may_max } else { SCEV_CNC };
    let moz = must_moz && nexit == 1;
    let at = sc_ents.len as i32;
    for k in em..sc_ent_tmp.len {
        let e = sc_ent_tmp[k];
        sc_ents.push(e);
        sc_side2_grow();
        let tag = (l << 1) | (if allow_preds { 1 } else { 0 });
        if !sc_is_const(e.exact) { sc_becusers_head[e.exact] = sc_list_push(sc_becusers_head[e.exact], tag); }
        if !sc_is_const(e.smax) { sc_becusers_head[e.smax] = sc_list_push(sc_becusers_head[e.smax], tag); }
    }
    let n = (sc_ent_tmp.len - em) as i32;
    sc_ent_tmp.resize(em);
    return BTI { at: at, n: n, complete: could, cmax: maxbe, moz: moz, symmax: -1 };
}
var sc_ent_tmp: ENT[>..<];
var sc_tmp: i32[>..<];          // scratch lists (mark-based)
// getExitingBlocks, appended to sc_tmp
recursive fn sc_push_exiting_blocks(l: i32) {
    for i in loop_nblocks(l) {
        let bb = loop_block(l, i);
        if loop_is_exiting(l, bb) { sc_tmp.push(bb); }
    }
}

// computeExitLimit
recursive fn sc_compute_exit_limit(l: i32, bb: i32, only: bool, allow_preds: bool) -> EL {
    let latch = loop_latch(l);
    if latch < 0 || !dt_dominates_block(DT_DOM, bb, latch) { return el_cnc(); }
    let t = block_last(bb);
    if iop(t) == OP_CONDBR {
        let exit_if_true = !loop_contains(l, term_succ(t, 0));
        return sc_compute_exit_limit_from_cond(l, op(t, 0), exit_if_true, only, allow_preds);
    }
    if iop(t) == OP_SWITCH {
        var exit: i32 = -1;
        for k in term_nsucc(t) {
            let s = term_succ(t, k);
            if !loop_contains(l, s) {
                if exit >= 0 { return el_cnc(); }
                exit = s;
            }
        }
        return sc_compute_exit_limit_from_single_exit_switch(l, t, exit, only);
    }
    return el_cnc();
}

// ExitLimitCache: entries (cond, controls-only-exit) -> EL on a stack; each computeExitLimitFromCond owns a mark
struct ELC { cond: i32, only: bool, el: EL }
var sc_elc: ELC[>..<];

recursive fn sc_compute_exit_limit_from_cond(l: i32, cond: i32, exit_if_true: bool, only: bool, allow_preds: bool) -> EL {
    let mark = sc_elc.len;
    let r = sc_exit_limit_from_cond_cached(mark, l, cond, exit_if_true, only, allow_preds);
    sc_elc.resize(mark);
    return r;
}

recursive fn sc_exit_limit_from_cond_cached(mark: i64, l: i32, cond: i32, exit_if_true: bool, only: bool, allow_preds: bool) -> EL {
    var k = mark;
    while k < sc_elc.len { if sc_elc[k].cond == cond && sc_elc[k].only == only { return sc_elc[k].el; } k++; }
    let e = sc_exit_limit_from_cond_impl(mark, l, cond, exit_if_true, only, allow_preds);
    sc_elc.push(ELC { cond: cond, only: only, el: e });
    return e;
}

// m_LogicalAnd / m_LogicalOr: (kind 1 = and, 2 = or, 0 = none, op0, op1)
recursive fn sc_match_logical(v: i32) -> i64, i32, i32 {
    if !is_inst(v) { return 0, -1, -1; }
    let o = iop(v);
    if o == OP_AND && ty_is_int(ty_scalar(vals[v].ty)) && ty_bits(ty_scalar(vals[v].ty)) == 1 { return 1, op(v, 0), op(v, 1); }
    if o == OP_OR && ty_is_int(ty_scalar(vals[v].ty)) && ty_bits(ty_scalar(vals[v].ty)) == 1 { return 2, op(v, 0), op(v, 1); }
    if o == OP_SELECT && vals[op(v, 0)].ty == vals[v].ty && ty_bits(ty_scalar(vals[v].ty)) == 1 && ty_is_int(ty_scalar(vals[v].ty)) {
        let t = op(v, 1);
        let f = op(v, 2);
        // select C, X, false  /  select C, true, X
        if sc_is_bool_const(f, false) { return 1, op(v, 0), t; }
        if sc_is_bool_const(t, true) { return 2, op(v, 0), f; }
    }
    return 0, -1, -1;
}
recursive fn sc_is_bool_const(v: i32, x: bool) -> bool {
    if vals[v].kind as i64 != VK_CINT && !(vals[v].kind as i64 == VK_AGGZERO) && !(vals[v].kind as i64 == VK_CNULL) { return false; }
    if vals[v].kind as i64 != VK_CINT { return !x; }
    let a = ap_from_cint(v);
    return if x { ap_is_one(a) } else { ap_is_zero(a) };
}

recursive fn sc_exit_limit_from_cond_impl(mark: i64, l: i32, cond: i32, exit_if_true: bool, only: bool, allow_preds: bool) -> EL {
    {
        let lk, o0, o1 = sc_match_logical(cond);
        if lk != 0 {
            let is_and = lk == 1;
            let e0 = sc_exit_limit_from_cond_cached(mark, l, o0, exit_if_true, false, allow_preds);
            let e1 = sc_exit_limit_from_cond_cached(mark, l, o1, exit_if_true, false, allow_preds);
            let either = is_and != exit_if_true;
            var bec = SCEV_CNC;
            var cmax = SCEV_CNC;
            var smax = SCEV_CNC;
            if either {
                let seq = !(is_inst(cond) && iop(cond) != OP_SELECT);
                if !sc_is_cnc(e0.exact) && !sc_is_cnc(e1.exact) { bec = sc_get_umin_from_mismatched(e0.exact, e1.exact, seq); }
                if sc_is_cnc(e0.cmax) { cmax = e1.cmax; }
                else if sc_is_cnc(e1.cmax) { cmax = e0.cmax; }
                else { cmax = sc_get_umin_from_mismatched(e0.cmax, e1.cmax, false); }
                if sc_is_cnc(e0.smax) { smax = e1.smax; }
                else if sc_is_cnc(e1.smax) { smax = e0.smax; }
                else { smax = sc_get_umin_from_mismatched(e0.smax, e1.smax, seq); }
            } else {
                if e0.exact == e1.exact { bec = e0.exact; }
            }
            if sc_is_cnc(cmax) && !sc_is_cnc(bec) { cmax = sc_get_constant(sc_get_unsigned_range_max(bec)); }
            if sc_is_cnc(smax) { smax = if sc_is_cnc(bec) { cmax } else { bec }; }
            let pat, np = sc_pred_union(e0, e1);
            return el_make(bec, cmax, smax, false, pat, np);
        }
    }
    if sc_is_icmp(cond) {
        let e = sc_exit_limit_from_icmp_inst(l, cond, exit_if_true, only, false);
        if el_has_full_info(e) || !allow_preds { return e; }
        return sc_exit_limit_from_icmp_inst(l, cond, exit_if_true, only, true);
    }
    if vals[cond].kind as i64 == VK_CINT {
        if exit_if_true == ap_is_zero(ap_from_cint(cond)) { return el_cnc(); }
        return el_one(sc_get_zero(vals[cond].ty));
    }
    // extractvalue(with.overflow, 1) with a constant RHS
    if is_inst(cond) && iop(cond) == OP_EXTRACTVALUE {
        let x = insts[inst_of(cond)];
        let wo = op(cond, 0);
        if x.naux == 1 && ints[x.aux] == 1 && sc_with_overflow_binop(wo) >= 0 && vals[cb_arg(wo, 1)].kind as i64 == VK_CINT {
            fatal("ScalarEvolution: exit conditions on with.overflow intrinsics are not ported");
        }
    }
    return el_one(sc_compute_exit_count_exhaustively(l, cond, exit_if_true));
}

recursive fn sc_with_overflow_binop(wo: i32) -> i64 {
    if !is_inst(wo) { return -1; }
    let id = inst_iid(wo);
    if id == IID_sadd_with_overflow || id == IID_uadd_with_overflow { return OP_ADD; }
    if id == IID_ssub_with_overflow || id == IID_usub_with_overflow { return OP_SUB; }
    if id == IID_smul_with_overflow || id == IID_umul_with_overflow { return OP_MUL; }
    return -1;
}

recursive fn sc_inverse_pred(p: i64) -> i64 {
    match p {
        P_EQ => { return P_NE; }, P_NE => { return P_EQ; },
        P_UGT => { return P_ULE; }, P_ULE => { return P_UGT; },
        P_UGE => { return P_ULT; }, P_ULT => { return P_UGE; },
        P_SGT => { return P_SLE; }, P_SLE => { return P_SGT; },
        P_SGE => { return P_SLT; }, P_SLT => { return P_SGE; },
        _ => { return p; },
    }
}
recursive fn sc_swapped_pred(p: i64) -> i64 {
    match p {
        P_UGT => { return P_ULT; }, P_ULT => { return P_UGT; },
        P_UGE => { return P_ULE; }, P_ULE => { return P_UGE; },
        P_SGT => { return P_SLT; }, P_SLT => { return P_SGT; },
        P_SGE => { return P_SLE; }, P_SLE => { return P_SGE; },
        _ => { return p; },
    }
}
recursive fn sc_pred_is_signed(p: i64) -> bool { p == P_SGT || p == P_SGE || p == P_SLT || p == P_SLE }
recursive fn sc_pred_is_unsigned(p: i64) -> bool { p == P_UGT || p == P_UGE || p == P_ULT || p == P_ULE }
recursive fn sc_pred_is_equality(p: i64) -> bool { p == P_EQ || p == P_NE }
recursive fn sc_pred_is_relational(p: i64) -> bool { !sc_pred_is_equality(p) }
recursive fn sc_pred_is_strict(p: i64) -> bool { p == P_UGT || p == P_ULT || p == P_SGT || p == P_SLT }
recursive fn sc_pred_is_non_strict(p: i64) -> bool { p == P_UGE || p == P_ULE || p == P_SGE || p == P_SLE }
recursive fn sc_pred_signed(p: i64) -> i64 {
    match p { P_UGT => { return P_SGT; }, P_UGE => { return P_SGE; }, P_ULT => { return P_SLT; }, P_ULE => { return P_SLE; }, _ => { return p; } }
}
recursive fn sc_pred_unsigned(p: i64) -> i64 {
    match p { P_SGT => { return P_UGT; }, P_SGE => { return P_UGE; }, P_SLT => { return P_ULT; }, P_SLE => { return P_ULE; }, _ => { return p; } }
}
recursive fn sc_pred_flip_strictness(p: i64) -> i64 {
    match p {
        P_SGT => { return P_SGE; }, P_SGE => { return P_SGT; }, P_SLT => { return P_SLE; }, P_SLE => { return P_SLT; },
        P_UGT => { return P_UGE; }, P_UGE => { return P_UGT; }, P_ULT => { return P_ULE; }, P_ULE => { return P_ULT; },
        _ => { return p; },
    }
}
recursive fn sc_pred_non_strict(p: i64) -> i64 { if sc_pred_is_strict(p) { sc_pred_flip_strictness(p) } else { p } }
recursive fn sc_pred_strict(p: i64) -> i64 { if sc_pred_is_non_strict(p) { sc_pred_flip_strictness(p) } else { p } }
recursive fn sc_pred_is_gt(p: i64) -> bool { p == P_SGT || p == P_UGT }
recursive fn sc_pred_is_lt(p: i64) -> bool { p == P_SLT || p == P_ULT }
recursive fn sc_pred_is_ge(p: i64) -> bool { p == P_SGE || p == P_UGE }
recursive fn sc_pred_is_le(p: i64) -> bool { p == P_SLE || p == P_ULE }

// computeExitLimitFromICmp(L, ExitCond, ExitIfTrue, ControlsOnlyExit, AllowPredicates)
recursive fn sc_exit_limit_from_icmp_inst(l: i32, ec: i32, exit_if_true: bool, only: bool, allow_preds: bool) -> EL {
    let p0 = inst_pred(ec);
    let samesign = (insts[inst_of(ec)].flags & FL_SAMESIGN) != 0;
    let pred = if !exit_if_true { p0 } else { sc_inverse_pred(p0) };
    let lhs = sc_get_scev(op(ec, 0));
    let rhs = sc_get_scev(op(ec, 1));
    let e = sc_exit_limit_from_icmp(l, pred, samesign, lhs, rhs, only, allow_preds);
    if el_has_any_info(e) { return e; }
    let ex = sc_compute_exit_count_exhaustively(l, ec, exit_if_true);
    if !sc_is_cnc(ex) { return el_one(ex); }
    return sc_compute_shift_compare_exit_limit(op(ec, 0), op(ec, 1), l, pred);
}

// computeExitLimitFromICmp(L, Pred, LHS, RHS, ControlsOnlyExit, AllowPredicates)
recursive fn sc_exit_limit_from_icmp(l: i32, pred0: i64, samesign0: bool, lhs0: i32, rhs0: i32, only: bool, allow_preds: bool) -> EL {
    var pred = pred0;
    var samesign = samesign0;
    var lhs = sc_get_scev_at_scope(lhs0, l);
    var rhs = sc_get_scev_at_scope(rhs0, l);
    if sc_is_loop_invariant(lhs, l) && !sc_is_loop_invariant(rhs, l) {
        let t = lhs; lhs = rhs; rhs = t;
        pred = sc_swapped_pred(pred);
    }
    let controlling = only && sc_loop_has_no_abnormal_exits(l) && sc_loop_is_finite_by_assumption(l);
    {
        let cp0 = pred | (if samesign { CP_SAMESIGN } else { 0 });
        let ch, p2, l2, r2 = sc_simplify_icmp_operands(cp0, lhs, rhs, 0);
        pred = cpp(p2);
        lhs = l2;
        rhs = r2;
    }
    if sc_is_const(rhs) && sc_is_addrec(lhs) && sc_loop(lhs) == l {
        let cr = rg_exact_icmp(pred, sc_ap(rhs));
        let ret = sc_get_num_iterations_in_range(lhs, cr);
        if !sc_is_cnc(ret) { return el_one(ret); }
    }
    if controlling && sc_is_loop_invariant(rhs, l) {
        var inner = lhs;
        if sc_kind(lhs) == SC_ZEXT { inner = sc_op(lhs, 0); }
        if sc_is_addrec(inner) && !sc_has_nw(inner) && sc_loop(inner) == l && sc_is_affine(inner) &&
           sc_is_known_to_be_power_of_two(sc_get_step_recurrence(inner), true, true) {
            let b = ss.len;
            ss_push_ops(inner);
            let f = sc_strengthen_flags(SC_ADDREC, b, ss_n(b), sc_flags(inner) | SF_NW);
            ss.resize(b);
            sc_set_nowrap_flags(inner, f);
        }
        if pred == P_SLT || pred == P_ULT {
            let wt = if pred == P_SLT { SF_NSW } else { SF_NUW };
            if sc_is_addrec(lhs) && sc_loop(lhs) == l && sc_is_affine(lhs) && (sc_flags(lhs) & wt) == 0 && sc_has_nw(lhs) &&
               sc_is_known_positive(sc_get_step_recurrence(lhs)) {
                let b = ss.len;
                ss_push_ops(lhs);
                let f = sc_strengthen_flags(SC_ADDREC, b, ss_n(b), sc_flags(lhs) | wt);
                ss.resize(b);
                sc_set_nowrap_flags(lhs, f);
            }
        }
    }
    if pred == P_NE || pred == P_EQ {
        if sc_is_ptr(lhs) { lhs = sc_get_lossless_ptr_to_int(lhs); if sc_is_cnc(lhs) { return el_one(lhs); } }
        if sc_is_ptr(rhs) { rhs = sc_get_lossless_ptr_to_int(rhs); if sc_is_cnc(rhs) { return el_one(rhs); } }
        if pred == P_NE {
            let e = sc_how_far_to_zero(sc_minus(lhs, rhs), l, only, allow_preds);
            if el_has_any_info(e) { return e; }
        } else {
            let e = sc_how_far_to_non_zero(sc_minus(lhs, rhs), l);
            if el_has_any_info(e) { return e; }
        }
        return el_cnc();
    }
    if pred == P_SLE || pred == P_ULE || pred == P_SLT || pred == P_ULT {
        if pred == P_SLE || pred == P_ULE {
            if !controlling || !sc_is_loop_invariant(rhs, l) {
                if !ty_is_int(sc_ty(lhs)) { return el_cnc(); }
                let nt = ty_int(ty_bits(sc_ty(lhs)) * 2);
                if sc_pred_is_signed(pred) { lhs = sc_get_sign_extend(lhs, nt, 0); rhs = sc_get_sign_extend(rhs, nt, 0); }
                else { lhs = sc_get_zero_extend(lhs, nt, 0); rhs = sc_get_zero_extend(rhs, nt, 0); }
            }
            rhs = sc_add(sc_get_one(sc_ty(rhs)), rhs);
        }
        let e = sc_how_many_less_thans(lhs, rhs, l, sc_pred_is_signed(pred), only, allow_preds);
        if el_has_any_info(e) { return e; }
        return el_cnc();
    }
    if pred == P_SGE || pred == P_UGE || pred == P_SGT || pred == P_UGT {
        if pred == P_SGE || pred == P_UGE {
            if !controlling || !sc_is_loop_invariant(rhs, l) { return el_cnc(); }
            rhs = sc_add(sc_get_minus_one(sc_ty(rhs)), rhs);
        }
        let e = sc_how_many_greater_thans(lhs, rhs, l, sc_pred_is_signed(pred), only, allow_preds);
        if el_has_any_info(e) { return e; }
    }
    return el_cnc();
}

// SwitchInst::findCaseDest(BB): the case value if exactly one case leads there, else -1
recursive fn sc_switch_find_case_dest(sw: i32, bb: i32) -> i32 {
    if term_succ(sw, 0) == bb { return -1; }
    var cv: i32 = -1;
    let nc = (nops(sw) - 2) / 2;
    for k in nc {
        if op(sw, 2 + 2 * k + 1) == bb {
            if cv >= 0 { return -1; }
            cv = op(sw, 2 + 2 * k);
        }
    }
    return cv;
}

// computeExitLimitFromSingleExitSwitch
recursive fn sc_compute_exit_limit_from_single_exit_switch(l: i32, sw: i32, exit: i32, only: bool) -> EL {
    if term_succ(sw, 0) == exit { return el_cnc(); }
    let lhs = sc_get_scev_at_scope(sc_get_scev(op(sw, 0)), l);
    let cv = sc_switch_find_case_dest(sw, exit);
    if cv < 0 { fatal("ScalarEvolution: switch exit reached through several cases is not ported"); }
    let rhs = sc_get_constant_v(cv);
    let e = sc_how_far_to_zero(sc_minus(lhs, rhs), l, only, false);
    if el_has_any_info(e) { return e; }
    return el_cnc();
}

// computeShiftCompareExitLimit
recursive fn sc_compute_shift_compare_exit_limit(lhs0: i32, rhsv: i32, l: i32, pred: i64) -> EL {
    if vals[rhsv].kind as i64 != VK_CINT { return el_cnc(); }
    let latch = loop_latch(l);
    if latch < 0 { return el_cnc(); }
    let predb = loop_predecessor(l);
    if predb < 0 { return el_cnc(); }
    // MatchPositiveShift: (ok, lhs, opcode, amount)
    fn match_shift(v: i32) -> bool, i32, i64, i64 {
        if !sc_is_operator(v) { return false, -1, 0, 0; }
        let o = opcode_of(v);
        if o != OP_LSHR && o != OP_ASHR && o != OP_SHL { return false, -1, 0, 0; }
        let sa = op(v, 1);
        if vals[sa].kind as i64 != VK_CINT { return false, -1, 0, 0; }
        let amt = ap_limited(ap_from_cint(sa), 0xFFFFFFFFFFFFFFFF) as i64;
        let x = op(v, 0);
        if amt == 0 || amt >= ty_bits(ty_scalar(vals[x].ty)) { return false, -1, 0, 0; }
        return true, x, o, amt;
    }
    var lhs = lhs0;
    var post: i64 = -1;
    {
        let ok, x, o, a = match_shift(lhs);
        if ok { post = o; lhs = x; }
    }
    if !(is_inst(lhs) && iop(lhs) == OP_PHI && inst_parent(lhs) == loop_header(l)) { return el_cnc(); }
    let pn = lhs;
    let bev = phi_value(pn, phi_block_index(pn, latch));
    let ok, oplhs, opc, amt = match_shift(bev);
    if !(ok && oplhs == pn && (post < 0 || post == opc)) { return el_cnc(); }
    let rty = vals[rhsv].ty;
    var stable: i32 = -1;
    if opc == OP_ASHR {
        let first = phi_value(pn, phi_block_index(pn, predb));
        let kn = sc_compute_known_bits_cx(first, block_last(predb));
        if ap_get_bit(kn.z, ty_bits(rty) - 1) { stable = ap_to_cint(rty, ap_zero(ty_bits(rty))); }
        else if ap_get_bit(kn.o, ty_bits(rty) - 1) { stable = ap_to_cint(rty, ap_ones(ty_bits(rty))); }
        else { return el_cnc(); }
    } else { stable = ap_to_cint(rty, ap_zero(ty_bits(rty))); }
    let res = sc_icmp_const_fold(pred, ap_from_cint(stable), ap_from_cint(rhsv));
    if !res {
        let bw = sc_type_bits(rty);
        var maxbtc = bw;
        if opc == OP_LSHR || opc == OP_ASHR {
            let sv = phi_value(pn, phi_block_index(pn, predb));
            let ss2 = sc_get_scev(sv);
            let ms = sc_get_unsigned_range_max(ss2);
            if ap_is_strictly_pos(ms) {
                let ab = ap_active_bits(ms);
                let rb = (ab + amt - 1) / amt;
                if rb < maxbtc { maxbtc = rb; }
            }
        }
        let ub = sc_get_constant_ty(sc_effective_ty(rty), maxbtc as u64, false);
        return el_make(SCEV_CNC, ub, ub, false, 0, 0);
    }
    return el_cnc();
}

// ICmpInst::compare on constants
recursive fn sc_icmp_const_fold(p: i64, a: AP, b: AP) -> bool {
    match p {
        P_EQ => { return ap_eq(a, b); }, P_NE => { return !ap_eq(a, b); },
        P_UGT => { return ap_ugt(a, b); }, P_UGE => { return ap_uge(a, b); },
        P_ULT => { return ap_ult(a, b); }, P_ULE => { return ap_ule(a, b); },
        P_SGT => { return ap_sgt(a, b); }, P_SGE => { return ap_sge(a, b); },
        P_SLT => { return ap_slt(a, b); }, P_SLE => { return ap_sle(a, b); },
        _ => { fatal("bad predicate"); return false; },
    }
}

// loopIsFiniteByAssumption
recursive fn sc_loop_is_finite_by_assumption(l: i32) -> bool { sc_is_finite_loop(l) || (sc_is_must_progress(l) && sc_loop_has_no_side_effects(l)) }
// llvm::isFinite(L): the function is willreturn
recursive fn sc_is_finite_loop(l: i32) -> bool { func_has_fn_attr(sc_fv, AK_WillReturn) }
recursive fn sc_is_must_progress(l: i32) -> bool {
    if func_has_fn_attr(sc_fv, AK_MustProgress) { return true; }
    let lid = loop_id(l);
    let m = find_option_md_for_loop_id(lid, "llvm.loop.mustprogress");
    if m >= 0 {
        if mds[m].nops == 1 { return true; }
        fatal("ScalarEvolution: llvm.loop.mustprogress with a value is not ported");
    }
    return false;
}
