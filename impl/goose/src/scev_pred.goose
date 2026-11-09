// ScalarEvolution: predicates and implication. SimplifyICmpOperands, isKnownPredicate and friends,
// isLoopBackedgeGuardedByCond / isBasicBlockEntryGuardedByCond / isLoopEntryGuardedByCond, isImpliedCond*,
// computeConstantDifference, canIVOverflowOn*, getUDivCeilSCEV.
// Port of the corresponding parts of llvm/lib/Analysis/ScalarEvolution.cpp.
//
// Predicates are CmpPredicate values: the ICmpInst predicate (P_* from implied.goose) | CP_SAMESIGN.
import std;
import scev_lt;
import scev_guards;
import ir;
import irutil;
import instinfo;
import calls;
import pm;
import implied;
import gen_iids;
import intrinsics;
import vt;
import apint;
import constrange;
import loopinfo;
import domtree;
import scev;
import scev_create;
import scev_range;
import scev_btc;
import scev_eval;

let CP_SAMESIGN: i64 = 256;
recursive fn cpp(p: i64) -> i64 { p & 0xFF }
recursive fn cp_keep(p: i64, np: i64) -> i64 { np | (p & CP_SAMESIGN) }
recursive fn cp_swapped(p: i64) -> i64 { cp_keep(p, sc_swapped_pred(cpp(p))) }
recursive fn cp_inverse(p: i64) -> i64 { cp_keep(p, sc_inverse_pred(cpp(p))) }
recursive fn cp_non_strict(p: i64) -> i64 { cp_keep(p, sc_pred_non_strict(cpp(p))) }
recursive fn sc_flipped_signedness(p: i64) -> i64 { if sc_pred_is_signed(p) { sc_pred_unsigned(p) } else { sc_pred_signed(p) } }
recursive fn cp_preferred_signed(p: i64) -> i64 { if cp_ss(p) { sc_pred_signed(cpp(p)) } else { cpp(p) } }
recursive fn sc_true_when_equal(p: i64) -> bool { let x = cpp(p); x == P_EQ || x == P_UGE || x == P_ULE || x == P_SGE || x == P_SLE }
recursive fn sc_false_when_equal(p: i64) -> bool { let x = cpp(p); x == P_NE || x == P_UGT || x == P_ULT || x == P_SGT || x == P_SLT }

var sc_has_guards: bool = false;
var sc_proving_split: bool = false;
var sc_walking_be_dom: bool = false;

recursive fn scev_reset_pred() { sc_proving_split = false; sc_walking_be_dom = false; scev_reset_guards(); }

// HasGuards: llvm.experimental.guard is declared and used
// (a module symbol-table lookup, as Intrinsic::getDeclarationIfExists is: a scan of the module's functions made
// every ScalarEvolution instance cost O(functions))
recursive fn sc_init_has_guards(fv: i32) {
    let f = sc_guard_decl_in(fv);
    sc_has_guards = f >= 0 && vals[f].first_use >= 0;
}
recursive fn sc_guard_decl_in(fv: i32) -> i32 {
    let st = modules[globs[glob_of(fv)].module].symtab;
    let f = symtab_lookup(st, intern("llvm.experimental.guard"));
    if f >= 0 && is_func(f) && func_iid(f) == IID_experimental_guard { return f; }
    return -1;
}
recursive // Intrinsic::getDeclarationIfExists(M, experimental_guard)
fn sc_guard_decl() -> i32 { sc_guard_decl_in(sc_fv) }
fn sc_has_assumptions() -> bool { vt_fn_has_assumes(sc_fv) }

// AC.assumptions(): llvm.assume calls of the function in instruction order
fn sc_collect_assumes(out: i32[>..<]&) {
    each_inst(sc_fv) { i => if inst_iid(i) == IID_assume { out.push(i); } };
}

// Instruction::isIdenticalTo (for HasSameValue: binary operators and GEPs)
recursive fn sc_inst_identical(a: i32, b: i32) -> bool {
    if iop(a) != iop(b) || vals[a].ty != vals[b].ty || nops(a) != nops(b) { return false; }
    for k in nops(a) { if op(a, k) != op(b, k) { return false; } }
    let x = insts[inst_of(a)];
    let y = insts[inst_of(b)];
    if x.flags != y.flags { return false; }
    if iop(a) == OP_GEP && x.ty2 != y.ty2 { return false; }
    return true;
}

// HasSameValue
recursive fn sc_has_same_value(a: i32, b: i32) -> bool {
    if a == b { return true; }
    if sc_is_unknown(a) && sc_is_unknown(b) {
        let ai = sc_value(a);
        let bi = sc_value(b);
        if is_inst(ai) && is_inst(bi) {
            let o = iop(ai);
            if sc_inst_identical(ai, bi) && ((o >= OP_ADD && o <= OP_XOR) || o == OP_GEP) { return true; }
        }
    }
    return false;
}

// MatchBinarySub: (ok, lhs, rhs)
recursive fn sc_match_binary_sub(s: i32) -> bool, i32, i32 {
    if sc_kind(s) != SC_ADD || sc_nops(s) != 2 { return false, -1, -1; }
    let o0 = sc_op(s, 0);
    let o1 = sc_op(s, 1);
    if sc_kind(o0) == SC_MUL && sc_nops(o0) == 2 && sc_is_all_ones(sc_op(o0, 0)) { return true, o1, sc_op(o0, 1); }
    if sc_kind(o1) == SC_MUL && sc_nops(o1) == 2 && sc_is_all_ones(sc_op(o1, 0)) { return true, o0, sc_op(o1, 1); }
    return false, -1, -1;
}

// m_scev_c_Mul(m_SCEV(X), m_SCEVVScale())
recursive fn sc_match_mul_vscale(s: i32) -> i32 {
    if sc_kind(s) != SC_MUL || sc_nops(s) != 2 { return -1; }
    if sc_kind(sc_op(s, 1)) == SC_VSCALE { return sc_op(s, 0); }
    if sc_kind(sc_op(s, 0)) == SC_VSCALE { return sc_op(s, 1); }
    return -1;
}

// SimplifyICmpOperands: (changed, pred, lhs, rhs)
recursive fn sc_simplify_icmp_operands(pred0: i64, lhs0: i32, rhs0: i32, depth: i64) -> bool, i64, i32, i32 {
    var pred = pred0;
    var lhs = lhs0;
    var rhs = rhs0;
    var changed = false;
    if depth >= 3 { return false, pred, lhs, rhs; }
    let fal = sc_get_constant(ap_zero(1));
    {
        let nl = sc_match_mul_vscale(lhs);
        let nr = sc_match_mul_vscale(rhs);
        if nl >= 0 && nr >= 0 {
            if (sc_has_nsw(lhs) && sc_has_nsw(rhs)) || (sc_has_nuw(lhs) && sc_has_nuw(rhs) && !sc_pred_is_signed(cpp(pred))) {
                lhs = nl;
                rhs = nr;
                changed = true;
            }
        }
    }
    if sc_is_const(lhs) {
        if sc_is_const(rhs) {
            if !sc_icmp_const_fold(cpp(pred), sc_ap(lhs), sc_ap(rhs)) { return true, P_NE, fal, fal; }
            return true, P_EQ, fal, fal;
        }
        let t = lhs; lhs = rhs; rhs = t;
        pred = cp_swapped(pred);
        changed = true;
    }
    // (C + X) vs (C + Y)
    if sc_kind(lhs) == SC_ADD && sc_nops(lhs) == 2 && sc_is_const(sc_op(lhs, 0)) &&
       sc_kind(rhs) == SC_ADD && sc_nops(rhs) == 2 && sc_op(rhs, 0) == sc_op(lhs, 0) {
        let p = cpp(pred);
        if sc_pred_is_equality(p) || (sc_pred_is_signed(p) && sc_has_nsw(lhs) && sc_has_nsw(rhs)) ||
           (sc_pred_is_unsigned(p) && sc_has_nuw(lhs) && sc_has_nuw(rhs)) {
            lhs = sc_op(lhs, 1);
            rhs = sc_op(rhs, 1);
            changed = true;
        }
    }
    // (C * X) vs (C * Y)
    if sc_kind(lhs) == SC_MUL && sc_nops(lhs) == 2 && sc_is_const(sc_op(lhs, 0)) &&
       sc_kind(rhs) == SC_MUL && sc_nops(rhs) == 2 && sc_op(rhs, 0) == sc_op(lhs, 0) {
        let p = cpp(pred);
        let bnuw = sc_has_nuw(lhs) && sc_has_nuw(rhs);
        let bnsw = sc_has_nsw(lhs) && sc_has_nsw(rhs);
        if (sc_pred_is_equality(p) && (bnuw || bnsw)) || (sc_pred_is_signed(p) && bnsw && ap_is_strictly_pos(sc_ap(sc_op(lhs, 0)))) ||
           (sc_pred_is_unsigned(p) && bnuw) {
            lhs = sc_op(lhs, 1);
            rhs = sc_op(rhs, 1);
            changed = true;
        }
    }
    if sc_is_addrec(rhs) {
        let l = sc_loop(rhs);
        if sc_is_loop_invariant(lhs, l) && sc_properly_dominates(lhs, loop_header(l)) {
            let t = lhs; lhs = rhs; rhs = t;
            pred = cp_swapped(pred);
            changed = true;
        }
    }
    if sc_is_const(rhs) {
        let ra = sc_ap(rhs);
        var by_range = false;
        if !sc_pred_is_equality(cpp(pred)) {
            let ecr = rg_exact_icmp(cpp(pred), ra);
            if rg_is_full(ecr) { return true, P_EQ, fal, fal; }
            if rg_is_empty(ecr) { return true, P_NE, fal, fal; }
            let ok, np, nr = rg_equivalent_icmp(ecr);
            if ok && sc_pred_is_equality(np) {
                pred = np;
                rhs = sc_get_constant(nr);
                changed = true;
                by_range = true;
            }
        }
        if !by_range {
            let p = cpp(pred);
            let w = ra.w as i64;
            if p == P_EQ || p == P_NE {
                if ap_is_zero(ra) {
                    let ok, l2, r2 = sc_match_binary_sub(lhs);
                    if ok { lhs = l2; rhs = r2; changed = true; }
                }
            } else if p == P_UGE { pred = P_UGT; rhs = sc_get_constant(ap_dec(ra)); changed = true; }
            else if p == P_ULE { pred = P_ULT; rhs = sc_get_constant(ap_inc(ra)); changed = true; }
            else if p == P_SGE { pred = P_SGT; rhs = sc_get_constant(ap_dec(ra)); changed = true; }
            else if p == P_SLE { pred = P_SLT; rhs = sc_get_constant(ap_inc(ra)); changed = true; }
        }
    }
    if sc_has_same_value(lhs, rhs) {
        if sc_true_when_equal(pred) { return true, P_EQ, fal, fal; }
        if sc_false_when_equal(pred) { return true, P_NE, fal, fal; }
    }
    let p = cpp(pred);
    let rt = sc_ty(rhs);
    if p == P_SLE {
        if !ap_is_max_signed(sc_get_signed_range_max(rhs)) {
            rhs = sc_add2(sc_get_constant_ty(rt, 1, true), rhs, SF_NSW, 0);
            pred = P_SLT;
            changed = true;
        } else if !ap_is_min_signed(sc_get_signed_range_min(lhs)) {
            lhs = sc_add2(sc_get_constant_ty(rt, 0xFFFFFFFFFFFFFFFF, true), lhs, SF_NSW, 0);
            pred = P_SLT;
            changed = true;
        }
    } else if p == P_SGE {
        if !ap_is_min_signed(sc_get_signed_range_min(rhs)) {
            rhs = sc_add2(sc_get_constant_ty(rt, 0xFFFFFFFFFFFFFFFF, true), rhs, SF_NSW, 0);
            pred = P_SGT;
            changed = true;
        } else if !ap_is_max_signed(sc_get_signed_range_max(lhs)) {
            lhs = sc_add2(sc_get_constant_ty(rt, 1, true), lhs, SF_NSW, 0);
            pred = P_SGT;
            changed = true;
        }
    } else if p == P_ULE {
        if !ap_is_all_ones(sc_get_unsigned_range_max(rhs)) {
            rhs = sc_add2(sc_get_constant_ty(rt, 1, true), rhs, SF_NUW, 0);
            pred = P_ULT;
            changed = true;
        } else if !ap_is_zero(sc_get_unsigned_range_min(lhs)) {
            lhs = sc_add(sc_get_constant_ty(rt, 0xFFFFFFFFFFFFFFFF, true), lhs);
            pred = P_ULT;
            changed = true;
        }
    } else if p == P_UGE {
        let k = sc_kind(rhs);
        if (sc_is_const(rhs) || ((k == SC_ADD || k == SC_ADDREC) && sc_is_const(sc_op(rhs, 0)))) && !ap_is_zero(sc_get_unsigned_range_min(rhs)) {
            rhs = sc_add(sc_get_constant_ty(rt, 0xFFFFFFFFFFFFFFFF, true), rhs);
            pred = P_UGT;
            changed = true;
        } else if !ap_is_all_ones(sc_get_unsigned_range_max(lhs)) {
            lhs = sc_add2(sc_get_constant_ty(rt, 1, true), lhs, SF_NUW, 0);
            pred = P_UGT;
            changed = true;
        } else if !ap_is_zero(sc_get_unsigned_range_min(rhs)) {
            rhs = sc_add(sc_get_constant_ty(rt, 0xFFFFFFFFFFFFFFFF, true), rhs);
            pred = P_UGT;
            changed = true;
        }
    }
    if changed {
        let c2, p2, l2, r2 = sc_simplify_icmp_operands(pred, lhs, rhs, depth + 1);
        return true, p2, l2, r2;
    }
    return changed, pred, lhs, rhs;
}

// getUsedLoops (as a list on sc_newops from mark)
recursive fn sc_used_loops(s: i32, mark: i64, smark: i64) {
    for k in smark..sc_seen.len { if sc_seen[k] == s { return; } }
    sc_seen.push(s);
    if sc_is_addrec(s) {
        var seen = false;
        for k in mark..sc_newops.len { if sc_newops[k] == sc_loop(s) { seen = true; break; } }
        if !seen { sc_newops.push(sc_loop(s)); }
    }
    let k = sc_kind(s);
    if k == SC_CONST || k == SC_VSCALE || k == SC_UNKNOWN { return; }
    for i in sc_nops(s) { sc_used_loops(sc_op(s, i), mark, smark); }
}

// isKnownViaInduction
recursive fn sc_is_known_via_induction(pred: i64, lhs: i32, rhs: i32) -> bool {
    let mark = sc_newops.len;
    let sm = sc_seen.len;
    sc_used_loops(lhs, mark, sm);
    sc_used_loops(rhs, mark, sm);
    sc_seen.resize(sm);
    if sc_newops.len == mark { return false; }
    var mdl = sc_newops[mark];
    for k in mark + 1..sc_newops.len {
        let x = sc_newops[k];
        // max_element with "properly dominates" as the less-than
        if dt_properly_dominates_block(DT_DOM, loop_header(mdl), loop_header(x)) { mdl = x; }
    }
    sc_newops.resize(mark);
    let ls = sc_rewrite_init(lhs, mdl, true);
    if sc_is_cnc(ls) { return false; }
    let lp = sc_rewrite_post_inc(lhs, mdl);
    let rs = sc_rewrite_init(rhs, mdl, true);
    if sc_is_cnc(rs) { return false; }
    let rp = sc_rewrite_post_inc(rhs, mdl);
    if !sc_is_available_at_loop_entry(ls, mdl) || !sc_is_available_at_loop_entry(rs, mdl) { return false; }
    return sc_is_loop_backedge_guarded_by_cond(mdl, pred, lp, rp) && sc_is_loop_entry_guarded_by_cond(mdl, pred, ls, rs);
}

recursive fn sc_is_known_predicate(pred0: i64, lhs0: i32, rhs0: i32) -> bool {
    let c, pred, lhs, rhs = sc_simplify_icmp_operands(pred0, lhs0, rhs0, 0);
    if sc_is_known_via_induction(pred, lhs, rhs) { return true; }
    if sc_is_known_predicate_via_splitting(pred, lhs, rhs) { return true; }
    return sc_known_via_non_recursive_reasoning(pred, lhs, rhs);
}

recursive fn sc_is_known_predicate_at(pred: i64, lhs: i32, rhs: i32, cx: i32) -> bool {
    return sc_is_known_predicate(pred, lhs, rhs) || sc_is_bb_entry_guarded_by_cond(inst_parent(cx), pred, lhs, rhs);
}

recursive fn sc_is_known_on_every_iteration(pred: i64, lhs: i32, rhs: i32) -> bool {
    let l = sc_loop(lhs);
    return sc_is_loop_entry_guarded_by_cond(l, pred, sc_op(lhs, 0), rhs) &&
           sc_is_loop_backedge_guarded_by_cond(l, pred, sc_get_post_inc(lhs), rhs);
}

recursive fn sc_is_known_predicate_via_constant_ranges(pred: i64, lhs: i32, rhs: i32) -> bool {
    if sc_has_same_value(lhs, rhs) { return sc_true_when_equal(pred); }
    let p = cpp(pred);
    if p == P_EQ { return false; }
    if p == P_NE {
        if rg_icmp(p, sc_get_signed_range(lhs), sc_get_signed_range(rhs)) || rg_icmp(p, sc_get_unsigned_range(lhs), sc_get_unsigned_range(rhs)) { return true; }
        let d = sc_minus(lhs, rhs);
        return !sc_is_cnc(d) && sc_is_known_non_zero(d);
    }
    if sc_pred_is_signed(p) { return rg_icmp(p, sc_get_signed_range(lhs), sc_get_signed_range(rhs)); }
    return rg_icmp(p, sc_get_unsigned_range(lhs), sc_get_unsigned_range(rhs));
}

// splitBinaryAdd: (ok, l, r, flags)
recursive fn sc_split_binary_add(e: i32) -> bool, i32, i32, u32 {
    if sc_kind(e) != SC_ADD || sc_nops(e) != 2 { return false, -1, -1, 0; }
    return true, sc_op(e, 0), sc_op(e, 1), sc_flags(e);
}

// isKnownPredicateViaNoOverflow's MatchBinaryAddToConst: (ok, c1, c2)
recursive fn sc_match_binary_add_to_const(x: i32, y: i32, ef: u32) -> bool, AP, AP {
    var xc: i32 = -1; var xn: i32 = -1; var xf: u32 = 0;
    {
        let ok, a, b, f = sc_split_binary_add(x);
        if ok { xc = a; xn = b; xf = f; } else { xc = sc_get_zero(sc_ty(x)); xn = x; xf = ef; }
    }
    let z = ap_zero(1);
    if !sc_is_const(xc) { return false, z, z; }
    var yc: i32 = -1; var yn: i32 = -1; var yf: u32 = 0;
    {
        let ok, a, b, f = sc_split_binary_add(y);
        if ok { yc = a; yn = b; yf = f; } else { yc = sc_get_zero(sc_ty(y)); yn = y; yf = ef; }
    }
    if yn != xn { return false, z, z; }
    if !sc_is_const(yc) { return false, z, z; }
    if (yf & ef) != ef { return false, z, z; }
    if ef != SF_NUW && (xf & ef) != ef { return false, z, z; }
    return true, sc_ap(xc), sc_ap(yc);
}

recursive fn sc_is_known_predicate_via_no_overflow(pred: i64, lhs0: i32, rhs0: i32) -> bool {
    var lhs = lhs0;
    var rhs = rhs0;
    var p = cpp(pred);
    if p == P_SGE || p == P_SGT || p == P_UGE || p == P_UGT { let t = lhs; lhs = rhs; rhs = t; p = sc_swapped_pred(p); }
    if p == P_SLE { let ok, c1, c2 = sc_match_binary_add_to_const(lhs, rhs, SF_NSW); return ok && ap_sle(c1, c2); }
    if p == P_SLT { let ok, c1, c2 = sc_match_binary_add_to_const(lhs, rhs, SF_NSW); return ok && ap_slt(c1, c2); }
    if p == P_ULE { let ok, c1, c2 = sc_match_binary_add_to_const(lhs, rhs, SF_NUW); return ok && ap_ule(c1, c2); }
    if p == P_ULT { let ok, c1, c2 = sc_match_binary_add_to_const(lhs, rhs, SF_NUW); return ok && ap_ult(c1, c2); }
    return false;
}

recursive fn sc_is_known_predicate_via_splitting(pred: i64, lhs: i32, rhs: i32) -> bool {
    if cpp(pred) != P_ULT || sc_proving_split { return false; }
    sc_proving_split = true;
    let r = sc_is_known_non_negative(rhs) && sc_is_known_predicate(P_SGE, lhs, sc_get_zero(sc_ty(lhs))) && sc_is_known_predicate(P_SLT, lhs, rhs);
    sc_proving_split = false;
    return r;
}

// isImpliedViaGuard
recursive fn sc_is_implied_via_guard(bb: i32, pred: i64, lhs: i32, rhs: i32) -> bool {
    if !sc_has_guards { return false; }
    var i = block_first(bb);
    while i >= 0 {
        if inst_iid(i) == IID_experimental_guard && sc_is_implied_cond(pred, lhs, rhs, cb_arg(i, 0), false, -1) { return true; }
        i = inst_next(i);
    }
    return false;
}

recursive fn sc_is_loop_backedge_guarded_by_cond(l: i32, pred: i64, lhs: i32, rhs: i32) -> bool {
    if l < 0 || !dt_has_node(DT_DOM, loop_header(l)) { return true; }
    if sc_known_via_non_recursive_reasoning(pred, lhs, rhs) { return true; }
    let latch = loop_latch(l);
    if latch < 0 { return false; }
    let t = block_last(latch);
    if iop(t) == OP_CONDBR && sc_is_implied_cond(pred, lhs, rhs, op(t, 0), term_succ(t, 0) != loop_header(l), -1) { return true; }
    if sc_walking_be_dom { return false; }
    sc_walking_be_dom = true;
    let r = sc_backedge_guarded_rest(l, latch, pred, lhs, rhs);
    sc_walking_be_dom = false;
    return r;
}

recursive fn sc_backedge_guarded_rest(l: i32, latch: i32, pred: i64, lhs: i32, rhs: i32) -> bool {
    let b = sc_get_bti(l, false);
    let e = sc_bti_exit_not_taken(b, latch, false);
    let lbc = if e < 0 { SCEV_CNC } else { sc_ents[e].exact };
    if !sc_is_cnc(lbc) {
        let ty = sc_ty(lbc);
        let lc = sc_addrec2(sc_get_zero(ty), sc_get_one(ty), l, SF_NUW | SF_NW);
        if sc_is_implied_cond_ops(pred, lhs, rhs, P_ULT, lc, lbc, -1) { return true; }
    }
    if sc_has_assumptions() {
        let am = sc_tmp.len;
        sc_collect_assumes(sc_tmp);
        let ae = sc_tmp.len;
        for ak in am..ae {
            let ci = sc_tmp[ak];
            if !dt_value_dominates_inst(ci, block_last(latch)) { continue; }
            if sc_is_implied_cond(pred, lhs, rhs, cb_arg(ci, 0), false, -1) { return true; }
        }
    }
    if sc_is_implied_via_guard(latch, pred, lhs, rhs) { return true; }
    var bb = latch;
    let hdr = loop_header(l);
    while bb != hdr {
        if sc_is_implied_via_guard(bb, pred, lhs, rhs) { return true; }
        let pbb = single_pred(bb);
        if pbb >= 0 {
            let cb = block_last(pbb);
            if iop(cb) == OP_CONDBR && term_succ(cb, 0) != term_succ(cb, 1) {
                if sc_is_implied_cond(pred, lhs, rhs, op(cb, 0), bb != term_succ(cb, 0), -1) { return true; }
            }
        }
        bb = dt_idom(DT_DOM, bb);
    }
    return false;
}

// getPredecessorWithUniqueSuccessorForBB: (pred, bb)
recursive fn sc_pred_with_unique_succ(bb: i32) -> i32, i32 {
    let p = single_pred(bb);
    if p >= 0 { return p, bb; }
    let l = li_loop_for(bb);
    if l >= 0 { return loop_predecessor(l), loop_header(l); }
    return -1, bb;
}

recursive fn sc_is_bb_entry_guarded_by_cond(bb: i32, pred: i64, lhs: i32, rhs: i32) -> bool {
    if !dt_has_node(DT_DOM, bb) { return true; }
    let nsp = cp_non_strict(pred);
    let strict = cpp(pred) != cpp(nsp);
    var proved_ns = false;
    var proved_ne = false;
    if strict {
        if !proved_ns { proved_ns = sc_known_via_non_recursive_reasoning(nsp, lhs, rhs); }
        if !proved_ne { proved_ne = sc_known_via_non_recursive_reasoning(P_NE, lhs, rhs); }
        if proved_ns && proved_ne { return true; }
    }
    let cx = block_first(bb);
    fn prove_via_cond(c: i32, inv: bool) -> bool {
        if sc_is_implied_cond(pred, lhs, rhs, c, inv, cx) { return true; }
        if strict {
            if !proved_ns { proved_ns = sc_is_implied_cond(nsp, lhs, rhs, c, inv, cx); }
            if !proved_ne { proved_ne = sc_is_implied_cond(P_NE, lhs, rhs, c, inv, cx); }
            if proved_ns && proved_ne { return true; }
        }
        return false;
    }
    let cl = li_loop_for(bb);
    var pbb: i32 = -1;
    if cl >= 0 && loop_header(cl) == bb { pbb = loop_predecessor(cl); } else { pbb = single_pred(bb); }
    var p1 = pbb;
    var p2 = bb;
    while p1 >= 0 {
        let t = block_last(p1);
        if iop(t) == OP_CONDBR {
            if prove_via_cond(op(t, 0), term_succ(t, 0) != p2) { return true; }
        }
        let a, b = sc_pred_with_unique_succ(p1);
        p1 = a;
        p2 = b;
    }
    if sc_has_assumptions() {
        let am = sc_tmp.len;
        sc_collect_assumes(sc_tmp);
        let ae = sc_tmp.len;
        for ak in am..ae {
            let ci = sc_tmp[ak];
            if !sc_inst_dominates_block(ci, bb) { continue; }
            if prove_via_cond(cb_arg(ci, 0), false) { return true; }
        }
    }
    // the users of llvm.experimental.guard (use-list order) in this function that dominate BB
    let gd = sc_guard_decl();
    if gd >= 0 {
        var u = vals[gd].first_use;
        while u >= 0 {
            let g = uses[u].user;
            let nu = uses[u].next;
            if is_inst(g) && inst_iid(g) == IID_experimental_guard && inst_func(g) == sc_fv && dt_inst_dominates_block(g, bb) {
                if prove_via_cond(cb_arg(g, 0), false) { return true; }
            }
            u = nu;
        }
    }
    return false;
}

// DominatorTree::dominates(const Instruction *Def, const BasicBlock *BB)
recursive fn sc_inst_dominates_block(i: i32, bb: i32) -> bool { dt_inst_dominates_block(i, bb) }

recursive fn sc_is_loop_entry_guarded_by_cond(l: i32, pred: i64, lhs: i32, rhs: i32) -> bool {
    if l < 0 { return false; }
    if sc_known_via_non_recursive_reasoning(pred, lhs, rhs) { return true; }
    return sc_is_bb_entry_guarded_by_cond(loop_header(l), pred, lhs, rhs);
}

// isImpliedCond(Pred, LHS, RHS, FoundCondValue, Inverse, CtxI)
recursive fn sc_is_implied_cond(pred: i64, lhs: i32, rhs: i32, fc: i32, inv: bool, cx: i32) -> bool {
    if vals[fc].kind as i64 == VK_CINT && ty_bits(vals[fc].ty) == 1 && ap_is_one(ap_from_cint(fc)) == inv { return true; }
    if hm_has(sc_pending_loop_preds, fc as u64) { return false; }
    hm_put(sc_pending_loop_preds, fc as u64, 1);
    let r = sc_is_implied_cond_body(pred, lhs, rhs, fc, inv, cx);
    hm_del(sc_pending_loop_preds, fc as u64);
    return r;
}

recursive fn sc_is_implied_cond_body(pred: i64, lhs: i32, rhs: i32, fc: i32, inv: bool, cx: i32) -> bool {
    let lk, o0, o1 = sc_match_logical(fc);
    if lk == 1 {
        if !inv { return sc_is_implied_cond(pred, lhs, rhs, o0, inv, cx) || sc_is_implied_cond(pred, lhs, rhs, o1, inv, cx); }
    } else if lk == 2 {
        if inv { return sc_is_implied_cond(pred, lhs, rhs, o0, inv, cx) || sc_is_implied_cond(pred, lhs, rhs, o1, inv, cx); }
    }
    if !sc_is_icmp(fc) { return false; }
    let ss2 = if (insts[inst_of(fc)].flags & FL_SAMESIGN) != 0 { CP_SAMESIGN } else { 0 };
    let cp = inst_pred(fc) | ss2;
    let fp = if inv { cp_inverse(cp) } else { cp };
    let fl = sc_get_scev(op(fc, 0));
    let fr = sc_get_scev(op(fc, 1));
    return sc_is_implied_cond_ops(pred, lhs, rhs, fp, fl, fr, cx);
}

// isImpliedCond(Pred, LHS, RHS, FoundPred, FoundLHS, FoundRHS, CtxI)
recursive fn sc_is_implied_cond_ops(pred: i64, lhs0: i32, rhs0: i32, fp: i64, fl0: i32, fr0: i32, cx: i32) -> bool {
    var lhs = lhs0;
    var rhs = rhs0;
    var fl = fl0;
    var fr = fr0;
    if sc_bits(lhs) < sc_bits(fl) {
        if !sc_pred_is_signed(cpp(fp)) && !sc_is_ptr(fl) && !sc_is_ptr(fr) {
            let nt = sc_ty(lhs);
            let wt = sc_ty(fl);
            let bw = sc_type_bits(nt);
            let mv = sc_get_zero_extend(sc_get_constant(ap_ones(bw)), wt, 0);
            if sc_known_via_non_recursive_reasoning(P_ULE, fl, mv) && sc_known_via_non_recursive_reasoning(P_ULE, fr, mv) {
                let tl = sc_get_truncate(fl, nt, 0);
                let tr = sc_get_truncate(fr, nt, 0);
                if sc_is_implied_cond_balanced(pred, lhs, rhs, cpp(fp), tl, tr, cx) { return true; }
            }
        }
        if sc_is_ptr(lhs) || sc_is_ptr(rhs) { return false; }
        if sc_pred_is_signed(cpp(pred)) { lhs = sc_get_sign_extend(lhs, sc_ty(fl), 0); rhs = sc_get_sign_extend(rhs, sc_ty(fl), 0); }
        else { lhs = sc_get_zero_extend(lhs, sc_ty(fl), 0); rhs = sc_get_zero_extend(rhs, sc_ty(fl), 0); }
    } else if sc_bits(lhs) > sc_bits(fl) {
        if sc_is_ptr(fl) || sc_is_ptr(fr) { return false; }
        if sc_pred_is_signed(cpp(fp)) { fl = sc_get_sign_extend(fl, sc_ty(lhs), 0); fr = sc_get_sign_extend(fr, sc_ty(lhs), 0); }
        else { fl = sc_get_zero_extend(fl, sc_ty(lhs), 0); fr = sc_get_zero_extend(fr, sc_ty(lhs), 0); }
    }
    return sc_is_implied_cond_balanced(pred, lhs, rhs, fp, fl, fr, cx);
}

recursive fn sc_is_implied_cond_balanced(pred0: i64, lhs0: i32, rhs0: i32, fp0: i64, fl0: i32, fr0: i32, cx: i32) -> bool {
    var pred = pred0; var lhs = lhs0; var rhs = rhs0;
    var fp = fp0; var fl = fl0; var fr = fr0;
    {
        let c, p, l, r = sc_simplify_icmp_operands(pred, lhs, rhs, 0);
        pred = p; lhs = l; rhs = r;
        if c && lhs == rhs { return sc_true_when_equal(pred); }
    }
    {
        let c, p, l, r = sc_simplify_icmp_operands(fp, fl, fr, 0);
        fp = p; fl = l; fr = r;
        if c && fl == fr { return sc_false_when_equal(fp); }
    }
    if lhs == fr || rhs == fl {
        if sc_is_const(rhs) { let t = fl; fl = fr; fr = t; fp = cp_swapped(fp); }
        else { let t = lhs; lhs = rhs; rhs = t; pred = cp_swapped(pred); }
    }
    {
        let p = cp_get_matching(fp, pred);
        if p >= 0 { return sc_is_implied_cond_operands(p, lhs, rhs, fl, fr, cx); }
    }
    {
        let p = cp_get_matching(cp_swapped(fp), pred);
        if p >= 0 {
            if !sc_is_const(rhs) && !sc_is_addrec(lhs) { return sc_is_implied_cond_operands(cp_swapped(p), rhs, lhs, fl, fr, cx); }
            if !sc_is_const(fr) && !sc_is_addrec(fl) { return sc_is_implied_cond_operands(p, lhs, rhs, fr, fl, cx); }
            if !sc_is_ptr(lhs) && !sc_is_ptr(rhs) && sc_is_implied_cond_operands(cp_swapped(p), sc_get_not(lhs), sc_get_not(rhs), fl, fr, cx) { return true; }
            if !sc_is_ptr(fl) && !sc_is_ptr(fr) && sc_is_implied_cond_operands(p, lhs, rhs, sc_get_not(fl), sc_get_not(fr), cx) { return true; }
            return false;
        }
    }
    if sc_pred_is_relational(cpp(fp)) && cpp(pred) == sc_flipped_signedness(cpp(fp)) {
        if sc_have_same_sign(fl, fr) { return sc_is_implied_cond_operands(pred, lhs, rhs, fl, fr, cx); }
        var cpd = pred; var cfp = fp;
        var cl = lhs; var cr = rhs; var cfl = fl; var cfr = fr;
        if sc_pred_is_gt(cpp(cpd)) || sc_pred_is_ge(cpp(cpd)) {
            cpd = cp_swapped(cpd);
            cfp = cp_swapped(cfp);
            let t = cl; cl = cr; cr = t;
            let t2 = cfl; cfl = cfr; cfr = t2;
        }
        if sc_pred_is_signed(cpp(cpd)) && sc_is_known_non_negative(cr) { return sc_is_implied_cond_operands(cfp, cl, cr, cfl, cfr, -1); }
        if sc_pred_is_unsigned(cpp(cpd)) && sc_is_known_negative(cr) { return sc_is_implied_cond_operands(cfp, cl, cr, cfl, cfr, -1); }
    }
    if cpp(fp) == P_NE && (sc_is_const(fl) || sc_is_const(fr)) {
        var c: i32 = -1; var v: i32 = -1;
        if sc_is_const(fl) { c = fl; v = fr; } else { c = fr; v = fl; }
        let mn = if sc_pred_is_signed(cpp(pred)) { sc_get_signed_range_min(v) } else { sc_get_unsigned_range_min(v) };
        if ap_eq(mn, sc_ap(c)) {
            let sharper = ap_inc(mn);
            let p = cpp(pred);
            if p == P_SGE || p == P_UGE || p == P_SGT || p == P_UGT {
                if (p == P_SGE || p == P_UGE) && sc_is_implied_cond_operands(pred, lhs, rhs, v, sc_get_constant(sharper), cx) { return true; }
                if sc_is_implied_cond_operands(pred, lhs, rhs, v, sc_get_constant(mn), cx) { return true; }
            } else if p == P_SLE || p == P_ULE || p == P_SLT || p == P_ULT {
                if (p == P_SLE || p == P_ULE) && sc_is_implied_cond_operands(cp_swapped(pred), rhs, lhs, v, sc_get_constant(sharper), cx) { return true; }
                if sc_is_implied_cond_operands(cp_swapped(pred), rhs, lhs, v, sc_get_constant(mn), cx) { return true; }
            }
        }
    }
    if cpp(fp) == P_EQ && sc_true_when_equal(pred) && sc_is_implied_cond_operands(pred, lhs, rhs, fl, fr, cx) { return true; }
    if cpp(pred) == P_NE && !sc_true_when_equal(fp) && sc_is_implied_cond_operands(fp, lhs, rhs, fl, fr, cx) { return true; }
    if sc_is_implied_cond_operands_via_ranges(pred, lhs, rhs, fp, fl, fr) { return true; }
    return false;
}

recursive fn sc_have_same_sign(a: i32, b: i32) -> bool {
    return (sc_is_known_non_negative(a) && sc_is_known_non_negative(b)) || (sc_is_known_negative(a) && sc_is_known_negative(b));
}

// computeConstantDifference: (ok, diff)
recursive fn sc_compute_constant_difference(more0: i32, less0: i32) -> bool, AP {
    var more = more0;
    var less = less0;
    let bw = sc_bits(more);
    var diff = ap_zero(bw);
    var dm = ap_u64(1, bw);
    for it in 8 {
        if more == less { return true, diff; }
        if sc_is_addrec(less) && sc_is_addrec(more) {
            if sc_loop(less) != sc_loop(more) { return false, diff; }
            if !sc_is_affine(less) || !sc_is_affine(more) { return false, diff; }
            if sc_get_step_recurrence(less) != sc_get_step_recurrence(more) { return false, diff; }
            less = sc_op(less, 0);
            more = sc_op(more, 0);
            continue;
        }
        if sc_kind(more) == SC_MUL && sc_nops(more) == 2 && sc_is_const(sc_op(more, 0)) &&
           sc_kind(less) == SC_MUL && sc_nops(less) == 2 && sc_is_const(sc_op(less, 0)) &&
           ap_eq(sc_ap(sc_op(more, 0)), sc_ap(sc_op(less, 0))) {
            dm = ap_mul(dm, sc_ap(sc_op(more, 0)));
            more = sc_op(more, 1);
            less = sc_op(less, 1);
            continue;
        }
        // Multiplicity (on sc_newops: pairs (scev, count))
        let mm = sc_newops.len;
        fn add_term(s: i32, mul: i32) {
            if sc_is_const(s) {
                if mul == 1 { diff = ap_add(diff, ap_mul(sc_ap(s), dm)); } else { diff = ap_sub(diff, ap_mul(sc_ap(s), dm)); }
                return;
            }
            var k = mm;
            while k < sc_newops.len { if sc_newops[k] == s { sc_newops[k + 1] += mul; return; } k += 2; }
            sc_newops.push(s);
            sc_newops.push(mul);
        }
        fn decompose(s: i32, mul: i32) {
            if sc_kind(s) == SC_ADD { for i in sc_nops(s) { add_term(sc_op(s, i), mul); } } else { add_term(s, mul); }
        }
        decompose(more, 1);
        decompose(less, -1);
        var nm: i32 = -1;
        var nl: i32 = -1;
        var bad = false;
        var k = mm;
        while k < sc_newops.len {
            let s = sc_newops[k];
            let m = sc_newops[k + 1];
            if m == 1 { if nm >= 0 { bad = true; break; } nm = s; }
            else if m == -1 { if nl >= 0 { bad = true; break; } nl = s; }
            else if m != 0 { bad = true; break; }
            k += 2;
        }
        sc_newops.resize(mm);
        if bad { return false, diff; }
        if nm == more || nl == less { return false, diff; }
        more = nm;
        less = nl;
        if more < 0 && less < 0 { return true, diff; }
        if more < 0 || less < 0 { return false, diff; }
    }
    return false, diff;
}

recursive fn sc_is_implied_cond_operands_via_addrec_start(pred: i64, lhs: i32, rhs: i32, fl: i32, fr: i32, cx: i32) -> bool {
    if cx < 0 { return false; }
    let cbb = inst_parent(cx);
    if sc_is_addrec(fl) {
        let l = sc_loop(fl);
        let latch = loop_latch(l);
        if !loop_contains(l, cbb) || latch < 0 || !dt_dominates_block(DT_DOM, cbb, latch) { return false; }
        if !sc_is_available_at_loop_entry(fr, l) { return false; }
        return sc_is_implied_cond_operands(pred, lhs, rhs, sc_op(fl, 0), fr, -1);
    }
    if sc_is_addrec(fr) {
        let l = sc_loop(fr);
        let latch = loop_latch(l);
        if !loop_contains(l, cbb) || latch < 0 || !dt_dominates_block(DT_DOM, cbb, latch) { return false; }
        if !sc_is_available_at_loop_entry(fl, l) { return false; }
        return sc_is_implied_cond_operands(pred, lhs, rhs, fl, sc_op(fr, 0), -1);
    }
    return false;
}

recursive fn sc_is_implied_cond_operands_via_no_overflow(pred: i64, lhs: i32, rhs: i32, fl: i32, fr: i32) -> bool {
    let p = cpp(pred);
    if p != P_SLT && p != P_ULT { return false; }
    if !sc_is_addrec(lhs) || !sc_is_addrec(fl) { return false; }
    let l = sc_loop(fl);
    if l != sc_loop(lhs) { return false; }
    let okl, ld = sc_compute_constant_difference(lhs, fl);
    if !okl { return false; }
    let okr, rd = sc_compute_constant_difference(rhs, fr);
    if !okr || !ap_eq(ld, rd) { return false; }
    if ap_is_zero(ld) { return true; }
    var lim = ap_zero(1);
    if p == P_ULT { lim = ap_neg(rd); } else { lim = ap_sub(ap_smin_val(sc_bits(rhs)), rd); }
    return sc_is_available_at_loop_entry(fr, l) && sc_is_loop_entry_guarded_by_cond(l, pred, fr, sc_get_constant(lim));
}

// isImpliedViaMerge (PendingMerges on sc_pending_merges)
recursive fn sc_is_implied_via_merge(pred0: i64, lhs0: i32, rhs0: i32, fl0: i32, fr0: i32, depth: i64) -> bool {
    var lphi: i32 = -1;
    var rphi: i32 = -1;
    if sc_is_unknown(lhs0) && sc_is_phi_value(sc_value(lhs0)) {
        let p = sc_value(lhs0);
        if hm_has(sc_pending_merges, p as u64) { return false; }
        hm_put(sc_pending_merges, p as u64, 1);
        lphi = p;
    }
    if sc_is_unknown(rhs0) && sc_is_phi_value(sc_value(rhs0)) {
        let p = sc_value(rhs0);
        if hm_has(sc_pending_merges, p as u64) {
            if lphi >= 0 { hm_del(sc_pending_merges, lphi as u64); }
            return false;
        }
        hm_put(sc_pending_merges, p as u64, 1);
        rphi = p;
    }
    let r = sc_implied_via_merge_body(pred0, lhs0, rhs0, fl0, fr0, depth, lphi, rphi);
    if lphi >= 0 { hm_del(sc_pending_merges, lphi as u64); }
    if rphi >= 0 { hm_del(sc_pending_merges, rphi as u64); }
    return r;
}

recursive fn sc_implied_via_merge_body(pred0: i64, lhs0: i32, rhs0: i32, fl0: i32, fr0: i32, depth: i64, lphi0: i32, rphi0: i32) -> bool {
    var pred = pred0; var lhs = lhs0; var rhs = rhs0; var fl = fl0; var fr = fr0;
    var lphi = lphi0; var rphi = rphi0;
    if lphi < 0 && rphi < 0 { return false; }
    if lphi < 0 {
        let t = lhs; lhs = rhs; rhs = t;
        let t2 = fl; fl = fr; fr = t2;
        let t3 = lphi; lphi = rphi; rphi = t3;
        pred = cp_swapped(pred);
    }
    let lbb = inst_parent(lphi);
    fn proved_easily(s1: i32, s2: i32) -> bool {
        return sc_known_via_non_recursive_reasoning(pred, s1, s2) || sc_is_implied_cond_operands_via_ranges(pred, s1, s2, pred, fl, fr) ||
               sc_is_implied_via_operations(pred, s1, s2, fl, fr, depth);
    }
    if rphi >= 0 && inst_parent(rphi) == lbb {
        var ok = true;
        each_pred(lbb) { ib =>
            if ok {
                let l = sc_get_scev(phi_value(lphi, phi_block_index(lphi, ib)));
                let r = sc_get_scev(phi_value(rphi, phi_block_index(rphi, ib)));
                if !proved_easily(l, r) { ok = false; }
            }
        };
        return ok;
    }
    if sc_is_addrec(rhs) && loop_header(sc_loop(rhs)) == lbb {
        if phi_nincoming(lphi) != 2 { return false; }
        let rl = sc_loop(rhs);
        let pr = loop_predecessor(rl);
        let l1 = sc_get_scev(phi_value(lphi, phi_block_index(lphi, pr)));
        if !proved_easily(l1, sc_op(rhs, 0)) { return false; }
        let latch = loop_latch(rl);
        let l2 = sc_get_scev(phi_value(lphi, phi_block_index(lphi, latch)));
        if !proved_easily(l2, sc_get_post_inc(rhs)) { return false; }
        return true;
    }
    var ok = true;
    each_pred(lbb) { ib =>
        if ok {
            if !sc_dominates(rhs, ib) { ok = false; }
            else {
                let l = sc_get_scev(phi_value(lphi, phi_block_index(lphi, ib)));
                if !sc_properly_dominates(l, lbb) { ok = false; }
                else {
                    let lp = li_loop_for(lbb);
                    if lp >= 0 && sc_has_computable_loop_evolution(l, lp) { ok = false; }
                    else if !proved_easily(l, rhs) { ok = false; }
                }
            }
        }
    };
    return ok;
}

recursive fn sc_is_implied_cond_operands_via_shift(pred0: i64, lhs0: i32, rhs0: i32, fl0: i32, fr0: i32) -> bool {
    var pred = pred0; var lhs = lhs0; var rhs = rhs0; var fl = fl0; var fr = fr0;
    if rhs == fr {
        let t = lhs; lhs = rhs; rhs = t;
        let t2 = fl; fl = fr; fr = t2;
        pred = cp_swapped(pred);
    }
    if lhs != fl { return false; }
    if !sc_is_unknown(fr) { return false; }
    let v = sc_value(fr);
    if sc_is_operator(v) && opcode_of(v) == OP_LSHR {
        let se = sc_get_scev(op(v, 0));
        let p = cpp(pred);
        if p == P_ULT || p == P_ULE { return sc_is_known_predicate(P_ULE, se, rhs); }
        if p == P_SLT || p == P_SLE {
            if sc_is_known_non_negative(se) { return sc_is_known_predicate(P_SLE, se, rhs); }
        }
    }
    return false;
}

recursive fn sc_is_implied_cond_operands_via_matching_diff(pred: i64, lhs: i32, rhs: i32, fl: i32, fr: i32) -> bool {
    if !sc_pred_is_equality(cpp(pred)) { return false; }
    if (!sc_is_addrec(lhs) && !sc_is_addrec(rhs)) || (!sc_is_addrec(fl) && !sc_is_addrec(fr)) { return false; }
    let q = if sc_is_addrec(lhs) { lhs } else { rhs };
    let f = if sc_is_addrec(fl) { fl } else { fr };
    if sc_loop(q) != sc_loop(f) { return false; }
    if sc_get_step_recurrence(q) != sc_get_step_recurrence(f) { return false; }
    let fd = sc_minus(fl, fr);
    if sc_is_cnc(fd) { return false; }
    let d = sc_minus(lhs, rhs);
    if sc_is_cnc(d) { return false; }
    return d == fd;
}

recursive fn sc_is_implied_cond_operands(pred: i64, lhs: i32, rhs: i32, fl: i32, fr: i32, cx: i32) -> bool {
    return sc_is_implied_cond_operands_via_ranges(pred, lhs, rhs, pred, fl, fr) ||
           sc_is_implied_cond_operands_via_no_overflow(pred, lhs, rhs, fl, fr) ||
           sc_is_implied_cond_operands_via_shift(pred, lhs, rhs, fl, fr) ||
           sc_is_implied_cond_operands_via_addrec_start(pred, lhs, rhs, fl, fr, cx) ||
           sc_is_implied_cond_operands_via_matching_diff(pred, lhs, rhs, fl, fr) ||
           sc_is_implied_cond_operands_helper(pred, lhs, rhs, fl, fr);
}

recursive fn sc_is_minmax_consisting_of(kind: i64, m: i32, c: i32) -> bool {
    if sc_kind(m) != kind { return false; }
    for i in sc_nops(m) { if sc_op(m, i) == c { return true; } }
    return false;
}

recursive fn sc_is_known_predicate_via_addrec_start(pred: i64, lhs: i32, rhs: i32) -> bool {
    if !sc_pred_is_relational(cpp(pred)) { return false; }
    if !sc_is_addrec(lhs) || !sc_is_affine(lhs) || !sc_is_addrec(rhs) || !sc_is_affine(rhs) { return false; }
    if sc_op(lhs, 1) != sc_op(rhs, 1) || sc_loop(lhs) != sc_loop(rhs) { return false; }
    let nw = if sc_pred_is_signed(cpp(pred)) { SF_NSW } else { SF_NUW };
    if (sc_flags(lhs) & nw) == 0 || (sc_flags(rhs) & nw) == 0 { return false; }
    return sc_is_known_predicate(pred, sc_op(lhs, 0), sc_op(rhs, 0));
}

recursive fn sc_is_known_predicate_via_min_or_max(pred: i64, lhs0: i32, rhs0: i32) -> bool {
    var lhs = lhs0;
    var rhs = rhs0;
    var p = cpp(pred);
    if p == P_SGE || p == P_UGE || p == P_UGT { let t = lhs; lhs = rhs; rhs = t; p = sc_swapped_pred(p); }
    if p == P_SLE { return sc_is_minmax_consisting_of(SC_SMIN, lhs, rhs) || sc_is_minmax_consisting_of(SC_SMAX, rhs, lhs); }
    if p == P_ULE { return sc_is_minmax_consisting_of(SC_UMIN, lhs, rhs) || sc_is_minmax_consisting_of(SC_UMAX, rhs, lhs); }
    if p == P_ULT {
        if sc_kind(lhs) == SC_UMIN {
            for i in sc_nops(lhs) {
                let ok, d = sc_compute_constant_difference(rhs, sc_op(lhs, i));
                if ok && !ap_is_zero(d) && ap_uge(sc_get_unsigned_range_min(rhs), d) { return true; }
            }
        }
    }
    return false;
}

recursive fn sc_is_implied_via_operations(pred0: i64, lhs0: i32, rhs0: i32, fl0: i32, fr0: i32, depth: i64) -> bool {
    var pred = pred0; var lhs = lhs0; var rhs = rhs0; var fl = fl0; var fr = fr0;
    if depth > sc_max_scev_operations_implication_depth { return false; }
    if sc_pred_is_lt(cpp(pred)) {
        pred = cp_swapped(pred);
        let t = lhs; lhs = rhs; rhs = t;
        let t2 = fl; fl = fr; fr = t2;
    }
    var p = cp_preferred_signed(pred);
    if p == P_UGT {
        if sc_is_known_non_negative(fl) && sc_is_known_non_negative(fr) {
            let m1 = sc_get_minus_one(sc_ty(lhs));
            if sc_is_implied_cond_operands(P_SGT, lhs, m1, fl, fr, -1) && sc_is_implied_cond_operands(P_SGT, rhs, m1, fl, fr, -1) { p = P_SGT; }
        }
    }
    if p != P_SGT { return false; }
    let orig_lhs = lhs;
    let orig_fl = fl;
    if sc_kind(lhs) == SC_SEXT { lhs = sc_op(lhs, 0); }
    if sc_kind(fl) == SC_SEXT { fl = sc_op(fl, 0); }
    fn sgt_ctx(s1: i32, s2: i32) -> bool {
        return sc_known_via_non_recursive_reasoning(P_SGT, s1, s2) || sc_is_implied_via_operations(P_SGT, s1, s2, orig_fl, fr, depth + 1);
    }
    if sc_kind(lhs) == SC_ADD {
        if sc_bits(lhs) != sc_bits(rhs) { return false; }
        if !sc_has_nsw(lhs) { return false; }
        let ll = sc_op(lhs, 0);
        let lr = sc_op(lhs, 1);
        let m1 = sc_get_minus_one(sc_ty(rhs));
        if (sgt_ctx(ll, m1) && sgt_ctx(lr, rhs)) || (sgt_ctx(lr, m1) && sgt_ctx(ll, rhs)) { return true; }
    } else if sc_is_unknown(lhs) {
        let v = sc_value(lhs);
        if sc_is_operator(v) && opcode_of(v) == OP_SDIV {
            let lr = op(v, 1);
            if !sc_is_cint(lr) { return false; }
            let den = sc_get_scev(lr);
            let num = sc_get_existing(op(v, 0));
            if num < 0 || sc_ty(num) != sc_ty(fl) { return false; }
            if !sc_has_same_value(num, fl) || !sc_is_known_positive(den) { return false; }
            let dty = sc_ty(den);
            let fty = sc_ty(fr);
            if sc_is_ptr_ty(dty) != sc_is_ptr_ty(fty) { return false; }
            let wty = sc_wider_ty(dty, fty);
            let de = sc_get_noop_or_sign_extend(den, wty);
            let fre = sc_get_noop_or_sign_extend(fr, wty);
            let dm2 = sc_minus(de, sc_get_constant_ty(wty, 2, false));
            if sc_is_known_non_positive(rhs) && sgt_ctx(fre, dm2) { return true; }
            let m1 = sc_get_minus_one(wty);
            let ndm1 = sc_minus(m1, de);
            if sc_is_known_negative(rhs) && sgt_ctx(fre, ndm1) { return true; }
        }
    }
    if sc_is_implied_via_merge(pred, orig_lhs, rhs, orig_fl, fr, depth + 1) { return true; }
    return false;
}

recursive fn sc_is_known_predicate_extend_idiom(pred: i64, lhs0: i32, rhs0: i32) -> bool {
    var lhs = lhs0;
    var rhs = rhs0;
    var p = cpp(pred);
    if p == P_SGE || p == P_UGE { let t = lhs; lhs = rhs; rhs = t; p = sc_swapped_pred(p); }
    if p == P_SLE { return sc_kind(lhs) == SC_SEXT && sc_kind(rhs) == SC_ZEXT && sc_op(rhs, 0) == sc_op(lhs, 0); }
    if p == P_ULE { return sc_kind(lhs) == SC_ZEXT && sc_kind(rhs) == SC_SEXT && sc_op(rhs, 0) == sc_op(lhs, 0); }
    return false;
}

recursive fn sc_known_via_non_recursive_reasoning(pred: i64, lhs: i32, rhs: i32) -> bool {
    return sc_is_known_predicate_extend_idiom(pred, lhs, rhs) || sc_is_known_predicate_via_constant_ranges(pred, lhs, rhs) ||
           sc_is_known_predicate_via_min_or_max(pred, lhs, rhs) || sc_is_known_predicate_via_addrec_start(pred, lhs, rhs) ||
           sc_is_known_predicate_via_no_overflow(pred, lhs, rhs);
}

recursive fn sc_is_implied_cond_operands_helper(pred: i64, lhs: i32, rhs: i32, fl: i32, fr: i32) -> bool {
    let p = cpp(pred);
    if p == P_EQ || p == P_NE {
        if sc_has_same_value(lhs, fl) && sc_has_same_value(rhs, fr) { return true; }
    } else if p == P_SLT || p == P_SLE {
        if sc_known_via_non_recursive_reasoning(P_SLE, lhs, fl) && sc_known_via_non_recursive_reasoning(P_SGE, rhs, fr) { return true; }
    } else if p == P_SGT || p == P_SGE {
        if sc_known_via_non_recursive_reasoning(P_SGE, lhs, fl) && sc_known_via_non_recursive_reasoning(P_SLE, rhs, fr) { return true; }
    } else if p == P_ULT || p == P_ULE {
        if sc_known_via_non_recursive_reasoning(P_ULE, lhs, fl) && sc_known_via_non_recursive_reasoning(P_UGE, rhs, fr) { return true; }
    } else if p == P_UGT || p == P_UGE {
        if sc_known_via_non_recursive_reasoning(P_UGE, lhs, fl) && sc_known_via_non_recursive_reasoning(P_ULE, rhs, fr) { return true; }
    }
    return sc_is_implied_via_operations(pred, lhs, rhs, fl, fr, 0);
}

recursive fn sc_is_implied_cond_operands_via_ranges(pred: i64, lhs: i32, rhs: i32, fp: i64, fl: i32, fr: i32) -> bool {
    if !sc_is_const(rhs) || !sc_is_const(fr) { return false; }
    let ok, addend = sc_compute_constant_difference(lhs, fl);
    if !ok { return false; }
    let flr = rg_exact_icmp(cpp(fp), sc_ap(fr));
    let lr = rg_add(flr, rg_single(addend));
    return rg_icmp(cpp(pred), lr, rg_single(sc_ap(rhs)));
}

recursive fn sc_can_iv_overflow_on_lt(rhs: i32, stride: i32, signed: bool) -> bool {
    let bw = sc_bits(rhs);
    let one = sc_get_one(sc_ty(stride));
    if signed {
        let mr = sc_get_signed_range_max(rhs);
        let mv = ap_smax_val(bw);
        let msm1 = sc_get_signed_range_max(sc_minus(stride, one));
        return ap_slt(ap_sub(mv, msm1), mr);
    }
    let mr = sc_get_unsigned_range_max(rhs);
    let mv = ap_ones(bw);
    let msm1 = sc_get_unsigned_range_max(sc_minus(stride, one));
    return ap_ult(ap_sub(mv, msm1), mr);
}

recursive fn sc_can_iv_overflow_on_gt(rhs: i32, stride: i32, signed: bool) -> bool {
    let bw = sc_bits(rhs);
    let one = sc_get_one(sc_ty(stride));
    if signed {
        let mr = sc_get_signed_range_min(rhs);
        let mv = ap_smin_val(bw);
        let msm1 = sc_get_signed_range_max(sc_minus(stride, one));
        return ap_sgt(ap_add(mv, msm1), mr);
    }
    let mr = sc_get_unsigned_range_min(rhs);
    let mv = ap_zero(bw);
    let msm1 = sc_get_unsigned_range_max(sc_minus(stride, one));
    return ap_ugt(ap_add(mv, msm1), mr);
}

recursive fn sc_get_udiv_ceil(n: i32, d: i32) -> i32 {
    let mn1 = sc_umin(n, sc_get_one(sc_ty(n)));
    let nm1 = sc_minus(n, mn1);
    return sc_add(mn1, sc_get_udiv(nm1, d));
}
