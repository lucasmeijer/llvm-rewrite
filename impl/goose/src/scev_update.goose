// ScalarEvolution: keeping a cached ScalarEvolution valid while passes change the IR, and the queries that only
// transforms make. Port of the corresponding parts of llvm/lib/Analysis/ScalarEvolution.cpp (LLVM 23.1.5):
// the value-handle callbacks (SCEVCallbackVH::deleted / allUsesReplacedWith, SCEVUnknown::deleted /
// allUsesReplacedWith), visitAndClearUsers / PushDefUseChildren / PushLoopPHIs, forgetLoop, forgetTopmostLoop,
// forgetValue, forgetLcssaPhiWithNewPredecessor, forgetMemoizedResults (over a list), getSCEVValues,
// canReuseInstruction, getStrengthenedNoWrapFlagsFromBinOp, getWiderType, evaluatePredicate(At),
// getMonotonicPredicateType(Impl), getLoopInvariantPredicate, getLoopInvariantExitCondDuringFirstIterations(Impl).
//
// The callbacks run from ir.goose (val_set_dead, rauw) while a ScalarEvolution is cached (sc_valid). LLVM only has
// a SCEVCallbackVH for values in ValueExprMap and a CallbackVH per SCEVUnknown, so a value without either costs a
// hash lookup.
import std;
import ir;
import irutil;
import instinfo;
import pm;
import calls;
import gen_iids;
import flags;
import poison;
import loopinfo;
import scev;
import scev_create;
import scev_range;
import scev_btc;
import scev_pred;
import scev_eval;
import scev_lt;

// ---------------------------------------------------------------------------------------------
// Value handles

recursive fn sc_find_unknown(v: i32) -> i32 { sc_find(SC_UNKNOWN, ss.len, 0, v, -1, -1) }

// SCEVCallbackVH::deleted and SCEVUnknown::deleted
fn scev_note_erase(v: i32) {
    if hm_has(sc_vmap, v as u64) {
        if is_phi(v) { hm_del(sc_cevl_exit, v as u64); }
        sc_erase_value_from_map(v);
    }
    let u = sc_find_unknown(v);
    if u >= 0 {
        su_forget_memoized([u]);
        sc_remove_node(u);
        scevs[u].v = -1;        // setValPtr(nullptr)
    }
}

// SCEVCallbackVH::allUsesReplacedWith and SCEVUnknown::allUsesReplacedWith (before the uses change)
fn scev_note_rauw(old: i32, nv: i32) {
    if sc_trace { errs(str("[scev] rauw ", val_name(old), "\n")); }
    if hm_has(sc_vmap, old as u64) { sc_forget_value(old); }
    let u = sc_find_unknown(old);
    if u >= 0 {
        su_forget_memoized([u]);
        sc_remove_node(u);
        scevs[u].v = nv;        // setValPtr(New)
    }
}

// ---------------------------------------------------------------------------------------------
// Forgetting

// forgetMemoizedResults(SCEVs): ToForget = the SCEVs and their transitive SCEVUsers, then forgetMemoizedResultsImpl
// on each (order-independent: each one only erases cache entries).
fn su_forget_memoized(list: const i32[:]) {
    if list.len == 0 { return; }
    if sc_trace {
        errs("[scev] forget");
        for x in list { errs(" "); sc_print(x); }
        errs("\n");
    }
    sc_side2_grow();
    var seen = hm_new();
    var all: i32[>..<] = [];
    var wl: i32[>..<] = [];
    for s in list { if !hm_has(seen, s as u64) { hm_put(seen, s as u64, 1); all.push(s); wl.push(s); } }
    while wl.len > 0 {
        let c = wl.pop();
        var u = sc_users_head[c];
        while u >= 0 {
            let us = sc_lpool[u].val;
            if !hm_has(seen, us as u64) { hm_put(seen, us as u64, 1); all.push(us); wl.push(us); }
            u = sc_lpool[u].next;
        }
    }
    for s in all { sc_forget_memoized_impl(s); }
    sc_forget_predicated_rewrites();
}

// PushDefUseChildren
fn su_push_def_use_children(i: i32, wl: i32[>..<]&, visited: HMap&) {
    var u = vals[i].first_use;
    while u >= 0 {
        let user = uses[u].user;
        if !hm_has(visited, user as u64) { hm_put(visited, user as u64, 1); wl.push(user); }
        u = uses[u].next;
    }
}

// isa<WithOverflowInst>
fn su_is_with_overflow(i: i32) -> bool {
    let id = inst_iid(i);
    return id == IID_sadd_with_overflow || id == IID_uadd_with_overflow || id == IID_ssub_with_overflow ||
           id == IID_usub_with_overflow || id == IID_smul_with_overflow || id == IID_umul_with_overflow;
}

// visitAndClearUsers
fn su_visit_and_clear_users(wl: i32[>..<]&, visited: HMap&, to_forget: i32[>..<]&) {
    while wl.len > 0 {
        let i = wl.pop();
        if !sc_is_scevable(vals[i].ty) && !su_is_with_overflow(i) { continue; }
        let s = sc_get_existing(i);
        if s >= 0 {
            to_forget.push(s);
            sc_erase_value_from_map(i);
            if is_phi(i) { hm_del(sc_cevl_exit, i as u64); }
        }
        su_push_def_use_children(i, wl, visited);
    }
}

// forgetLoop
fn sc_forget_loop(l: i32) {
    var lwl: i32[>..<] = [];
    lwl.push(l);
    var wl: i32[>..<] = [];
    var visited = hm_new();
    var to_forget: i32[>..<] = [];
    while lwl.len > 0 {
        let cur = lwl.pop();
        sc_forget_backedge_taken_counts(cur, false);
        sc_forget_backedge_taken_counts(cur, true);
        // PredicatedSCEVRewrites.remove_if(loop == CurrL): not cached (sc_forget_predicated_rewrites)
        // LoopUsers[CurrL], in insertion order (the list is pushed at the head)
        var lu: i32[>..<] = [];
        var x = hm_get(sc_loop_users, cur as u64, -1) as i32;
        while x >= 0 { lu.push(sc_lpool[x].val); x = sc_lpool[x].next; }
        var k = lu.len - 1;
        while k >= 0 { to_forget.push(lu[k]); k--; }
        // PushLoopPHIs
        var p = block_first(loop_header(cur));
        while p >= 0 && is_phi(p) {
            if !hm_has(visited, p as u64) { hm_put(visited, p as u64, 1); wl.push(p); }
            p = inst_next(p);
        }
        su_visit_and_clear_users(wl, visited, to_forget);
        hm_del(sc_loop_props, cur as u64);
        for j in loop_nsubs(cur) { lwl.push(loop_sub(cur, j)); }
    }
    su_forget_memoized(to_forget);
}

// forgetTopmostLoop
fn sc_forget_topmost_loop(l: i32) { sc_forget_loop(loop_outermost(l)); }

// forgetValue
fn sc_forget_value(v: i32) {
    if !is_inst(v) { return; }
    var wl: i32[>..<] = [];
    var visited = hm_new();
    var to_forget: i32[>..<] = [];
    wl.push(v);
    hm_put(visited, v as u64, 1);
    su_visit_and_clear_users(wl, visited, to_forget);
    su_forget_memoized(to_forget);
}

// forgetLcssaPhiWithNewPredecessor: InvalidationRootCollector (visitAll, each node once)
fn sc_forget_lcssa_phi_with_new_predecessor(l: i32, v: i32) {
    if !sc_is_scevable(vals[v].ty) { return; }
    let s = sc_get_existing(v);
    if s >= 0 {
        var roots: i32[>..<] = [];
        var seen = hm_new();
        var wl: i32[>..<] = [];
        wl.push(s);
        hm_put(seen, s as u64, 1);
        while wl.len > 0 {
            let c = wl.pop();
            if sc_is_unknown(c) {
                let i = sc_value(c);
                if is_inst(i) && loop_contains(l, inst_parent(i)) { roots.push(c); }
            } else if sc_is_addrec(c) {
                if loop_contains_loop(l, sc_loop(c)) { roots.push(c); }
            }
            let kd = sc_kind(c);
            if kd == SC_CONST || kd == SC_VSCALE || kd == SC_UNKNOWN || kd == SC_CNC { continue; }
            for k in sc_nops(c) {
                let o = sc_op(c, k);
                if !hm_has(seen, o as u64) { hm_put(seen, o as u64, 1); wl.push(o); }
            }
        }
        su_forget_memoized(roots);
    }
    sc_forget_value(v);
}

// ---------------------------------------------------------------------------------------------
// Queries for transforms

// getSCEVValues(S): ExprValueMap[S], a SetVector in insertion order. Our list is pushed at the head and keeps
// entries of values erased from ValueExprMap: the live ones are those still mapped to S, at their latest insertion.
fn sc_get_scev_values(s: i32, out: i32[>..<]&) {
    out.clear();
    sc_side2_grow();
    var seen = hm_new();
    var rev: i32[>..<] = [];
    var x = sc_values_head[s];
    while x >= 0 {
        let v = sc_lpool[x].val;
        if sc_get_existing(v) == s && !hm_has(seen, v as u64) { hm_put(seen, v as u64, 1); rev.push(v); }
        x = sc_lpool[x].next;
    }
    var k = rev.len - 1;
    while k >= 0 { out.push(rev[k]); k--; }
}

// getPoisonGeneratingValues(Result, S): SCEVPoisonCollector without looking through poison-blocking nodes
fn su_poison_generating_values(s: i32, out: HMap&) {
    let sm = sc_seen.len;
    let p = sc_newops.len;
    sc_poison_collect(s, false, sm);
    sc_seen.resize(sm);
    for k in p..sc_newops.len { hm_put(out, sc_value(sc_newops[k]) as u64, 1); }
    sc_newops.resize(p);
}

// canReuseInstruction(S, I, DropPoisonGeneratingInsts)
fn sc_can_reuse_instruction(s: i32, i: i32, drop: i32[>..<]&) -> bool {
    if program_undefined_if_undef_or_poison(i, true) { return true; }
    var pvals = hm_new();
    su_poison_generating_values(s, pvals);
    var wl: i32[>..<] = [];
    var visited = hm_new();
    var nvisited: i64 = 0;
    wl.push(i);
    while wl.len > 0 {
        let v = wl.pop();
        if hm_has(visited, v as u64) { continue; }
        hm_put(visited, v as u64, 1);
        nvisited++;
        if nvisited > 16 { return false; }
        if hm_has(pvals, v as u64) || is_guaranteed_not_to_be_poison(v, -1, 0) { continue; }
        if !is_inst(v) { return false; }
        if iop(v) == OP_OR && op_disjoint(v) { return false; }
        if inst_iid(v) == IID_vscale { continue; }
        if can_create_poison(v, false) { return false; }
        if has_poison_generating_annotations(v) { drop.push(v); }
        for k in nops(v) { wl.push(op(v, k)); }
    }
    return true;
}

// getStrengthenedNoWrapFlagsFromBinOp(OBO): (deduced, flags)
fn sc_get_strengthened_no_wrap_flags_from_binop(i: i32) -> bool, u32 {
    let nuw = op_nuw(i);
    let nsw = op_nsw(i);
    if nuw && nsw { return false, SF_ANY; }
    var f = SF_ANY;
    if nuw { f |= SF_NUW; }
    if nsw { f |= SF_NSW; }
    var deduced = false;
    let o = iop(i);
    if o != OP_ADD && o != OP_SUB && o != OP_MUL { return false, SF_ANY; }
    let lhs = sc_get_scev(op(i, 0));
    let rhs = sc_get_scev(op(i, 1));
    // -scalar-evolution-use-context-for-no-wrap-flag-inference (default true)
    let cx = if flag_bool("scalar-evolution-use-context-for-no-wrap-flag-inference", true) { i } else { -1 };
    if !nuw && sc_will_not_overflow(o, false, lhs, rhs, cx) { f |= SF_NUW; deduced = true; }
    if !nsw && sc_will_not_overflow(o, true, lhs, rhs, cx) { f |= SF_NSW; deduced = true; }
    if deduced { return true, f; }
    return false, SF_ANY;
}

// getWiderType
fn sc_get_wider_type(a: i32, b: i32) -> i32 { if sc_type_bits(a) >= sc_type_bits(b) { a } else { b } }

// evaluatePredicate / evaluatePredicateAt: 1 true, 0 false, -1 unknown
fn sc_evaluate_predicate(p: i64, l: i32, r: i32) -> i64 {
    if sc_is_known_predicate(p, l, r) { return 1; }
    if sc_is_known_predicate(cp_inverse(p), l, r) { return 0; }
    return -1;
}
fn sc_evaluate_predicate_at(p: i64, l: i32, r: i32, cx: i32) -> i64 {
    let k = sc_evaluate_predicate(p, l, r);
    if k >= 0 { return k; }
    let bb = inst_parent(cx);
    if sc_is_bb_entry_guarded_by_cond(bb, p, l, r) { return 1; }
    if sc_is_bb_entry_guarded_by_cond(bb, cp_inverse(p), l, r) { return 0; }
    return -1;
}

let SC_MONO_INC: i64 = 0;
let SC_MONO_DEC: i64 = 1;
let SC_MONO_NONE: i64 = -1;

// getMonotonicPredicateTypeImpl (getMonotonicPredicateType only adds an assertion)
fn sc_get_monotonic_predicate_type(ar: i32, p: i64) -> i64 {
    if !sc_pred_is_relational(p) { return SC_MONO_NONE; }
    let greater = sc_pred_is_ge(p) || sc_pred_is_gt(p);
    if sc_pred_is_unsigned(p) {
        if !sc_has_nuw(ar) { return SC_MONO_NONE; }
        return if greater { SC_MONO_INC } else { SC_MONO_DEC };
    }
    if !sc_has_nsw(ar) { return SC_MONO_NONE; }
    let step = sc_get_step_recurrence(ar);
    if sc_is_known_non_negative(step) { return if greater { SC_MONO_INC } else { SC_MONO_DEC }; }
    if sc_is_known_non_positive(step) { return if !greater { SC_MONO_INC } else { SC_MONO_DEC }; }
    return SC_MONO_NONE;
}

// LoopInvariantPredicate (ok = false: std::nullopt)
struct LIP { ok: bool, pred: i64, lhs: i32, rhs: i32 }
fn lip_none() -> LIP { LIP { ok: false, pred: 0, lhs: -1, rhs: -1 } }

// getLoopInvariantPredicate(Pred, LHS, RHS, L, CtxI)
fn sc_get_loop_invariant_predicate(p0: i64, lhs0: i32, rhs0: i32, l: i32, cx: i32) -> LIP {
    var p = p0;
    var lhs = lhs0;
    var rhs = rhs0;
    if !sc_is_loop_invariant(rhs, l) {
        if !sc_is_loop_invariant(lhs, l) { return lip_none(); }
        let t = lhs; lhs = rhs; rhs = t;
        p = cp_swapped(p);
    }
    if !sc_is_addrec(lhs) || sc_loop(lhs) != l { return lip_none(); }
    let mt = sc_get_monotonic_predicate_type(lhs, cpp(p));
    if mt == SC_MONO_NONE { return lip_none(); }
    let pp = if mt == SC_MONO_INC { p } else { cp_inverse(p) };
    if sc_is_loop_backedge_guarded_by_cond(l, pp, lhs, rhs) { return LIP { ok: true, pred: cpp(p), lhs: sc_op(lhs, 0), rhs: rhs }; }
    if cx < 0 { return lip_none(); }
    let q = cpp(p);
    if q == P_ULE || q == P_ULT {
        let flipped = sc_flipped_signedness(q);
        if sc_has_nsw(lhs) && sc_is_affine(lhs) && sc_is_known_positive(sc_get_step_recurrence(lhs)) &&
           sc_is_known_non_negative(rhs) && sc_is_known_predicate_at(flipped, lhs, rhs, cx) {
            return LIP { ok: true, pred: q, lhs: sc_op(lhs, 0), rhs: rhs };
        }
    }
    return lip_none();
}

// getLoopInvariantExitCondDuringFirstIterations
fn sc_get_loop_invariant_exit_cond_during_first_iterations(p: i64, lhs: i32, rhs: i32, l: i32, cx: i32, max_iter: i32) -> LIP {
    let r = sc_lip_first_iterations_impl(p, lhs, rhs, l, cx, max_iter);
    if r.ok { return r; }
    if sc_kind(max_iter) == SC_UMIN {
        for k in sc_nops(max_iter) {
            let r2 = sc_lip_first_iterations_impl(p, lhs, rhs, l, cx, sc_op(max_iter, k));
            if r2.ok { return r2; }
        }
    }
    return lip_none();
}

// getLoopInvariantExitCondDuringFirstIterationsImpl
fn sc_lip_first_iterations_impl(p0: i64, lhs0: i32, rhs0: i32, l: i32, cx: i32, max_iter: i32) -> LIP {
    var p = p0;
    var lhs = lhs0;
    var rhs = rhs0;
    if !sc_is_loop_invariant(rhs, l) {
        if !sc_is_loop_invariant(lhs, l) { return lip_none(); }
        let t = lhs; lhs = rhs; rhs = t;
        p = cp_swapped(p);
    }
    if !sc_is_addrec(lhs) || sc_loop(lhs) != l { return lip_none(); }
    let q = cpp(p);         // dropSameSign
    if !sc_pred_is_relational(q) { return lip_none(); }
    let step = sc_get_step_recurrence(lhs);
    let one = sc_get_one(sc_ty(step));
    let minus_one = sc_get_negative(one, SF_ANY);
    if step != one && step != minus_one { return lip_none(); }
    if sc_ty(lhs) != sc_ty(max_iter) { return lip_none(); }
    let last = sc_evaluate_at_iteration(lhs, max_iter);
    if !sc_is_loop_backedge_guarded_by_cond(l, q, last, rhs) { return lip_none(); }
    var nop = if sc_pred_is_signed(q) { P_SLE } else { P_ULE };
    if step == minus_one { nop = sc_swapped_pred(nop); }
    let start = sc_op(lhs, 0);
    if !sc_is_known_predicate_at(nop, start, last, cx) { return lip_none(); }
    return LIP { ok: true, pred: q, lhs: start, rhs: rhs };
}
