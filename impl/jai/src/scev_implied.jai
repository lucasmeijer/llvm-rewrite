// ScalarEvolution, part 5: proving predicates.
// Port of llvm/lib/Analysis/ScalarEvolution.cpp (LLVM 23.1.5): HasSameValue, MatchBinarySub, SimplifyICmpOperands,
// SplitIntoInitAndPostInc, isKnownViaInduction, isKnownPredicate(At), evaluatePredicate, isKnownOnEveryIteration,
// isKnownPredicateViaConstantRanges / ViaNoOverflow / ViaSplitting, isImpliedViaGuard, isLoopBackedgeGuardedByCond,
// isBasicBlockEntryGuardedByCond, isLoopEntryGuardedByCond, isImpliedCond (both overloads),
// isImpliedCondBalancedTypes, splitBinaryAdd, computeConstantDifference, isImpliedCondOperands and its helpers
// (ViaAddRecStart, ViaNoOverflow, ViaMerge, ViaShift, ViaMatchingDiff, ViaRanges, Helper), isImpliedViaOperations,
// IsKnownPredicateViaMinOrMax / ViaAddRecStart, isKnownPredicateExtendIdiom, isKnownViaNonRecursiveReasoning,
// getPredecessorWithUniqueSuccessorForBB.
//
// Predicates are u8 CmpInst predicates. LLVM's CmpPredicate also carries `samesign`; the predicates being proved
// never have it here (they come from SCEV code, not instructions), so only the found (condition) predicate keeps its
// samesign flag where LLVM consults it (CmpPredicate::getMatching, dropSameSign).

icmp_is_le :: (p: u8) -> bool { return p == ICMP_SLE || p == ICMP_ULE; }
icmp_is_ge :: (p: u8) -> bool { return p == ICMP_SGE || p == ICMP_UGE; }
icmp_is_true_when_equal :: (p: u8) -> bool { return p == ICMP_EQ || p == ICMP_UGE || p == ICMP_ULE || p == ICMP_SGE || p == ICMP_SLE; }
icmp_is_false_when_equal :: (p: u8) -> bool { return p == ICMP_NE || p == ICMP_UGT || p == ICMP_ULT || p == ICMP_SGT || p == ICMP_SLT; }
icmp_non_strict :: (p: u8) -> u8 {
    if p == {
        case ICMP_SGT; return ICMP_SGE;
        case ICMP_SLT; return ICMP_SLE;
        case ICMP_UGT; return ICMP_UGE;
        case ICMP_ULT; return ICMP_ULE;
    }
    return p;
}

// HasSameValue
has_same_value :: (a: Scev_Id, b: Scev_Id) -> bool {
    if a == b return true;
    if sc_is_unknown(a) && sc_is_unknown(b) {
        ai := sc_value(a); bi := sc_value(b);
        if is_inst(ai) && is_inst(bi) {
            if is_identical_to(ai, bi) && (is_binary_operator(ai) || inst_op(ai) == .GEP) return true;
        }
    }
    return false;
}

// MatchBinarySub
match_binary_sub :: (s: Scev_Id) -> (bool, Scev_Id, Scev_Id) {
    if !(sc_is_add(s) && sc_nops(s) == 2) return false, 0, 0;
    op0 := sc_op(s, 0); op1 := sc_op(s, 1);
    if sc_is_mul(op0) && sc_nops(op0) == 2 && sc_is_all_ones(sc_op(op0, 0)) return true, op1, sc_op(op0, 1);
    if sc_is_mul(op1) && sc_nops(op1) == 2 && sc_is_all_ones(sc_op(op1, 0)) return true, op0, sc_op(op1, 1);
    return false, 0, 0;
}

// SimplifyICmpOperands
sc_simplify_icmp_operands :: (pred: *u8, samesign: *bool, lhs: *Scev_Id, rhs: *Scev_Id, depth: u32 = 0) -> bool {
    changed := false;
    trivial_case :: (pred: *u8, samesign: *bool, lhs: *Scev_Id, rhs: *Scev_Id, trivially_true: bool) -> bool {
        f := sc_get_constant(ap_zero(1));
        lhs.* = f; rhs.* = f;
        pred.* = ifx trivially_true then cast(u8) ICMP_EQ else ICMP_NE;
        samesign.* = false;
        return true;
    }
    if depth >= 3 return false;

    {
        ok1, nl := match_c_mul_vscale(lhs.*);
        ok2, nr := match_c_mul_vscale(rhs.*);
        if ok1 && ok2 {
            if (sc_has_nsw(lhs.*) && sc_has_nsw(rhs.*)) || (sc_has_nuw(lhs.*) && sc_has_nuw(rhs.*) && !icmp_is_signed(pred.*)) {
                lhs.* = nl; rhs.* = nr; changed = true;
            }
        }
    }

    if sc_is_const(lhs.*) {
        if sc_is_const(rhs.*) {
            if !icmp_compare(sc_ap(lhs.*), sc_ap(rhs.*), pred.*) return trivial_case(pred, samesign, lhs, rhs, false);
            return trivial_case(pred, samesign, lhs, rhs, true);
        }
        t := lhs.*; lhs.* = rhs.*; rhs.* = t;
        pred.* = icmp_swapped(pred.*);
        changed = true;
    }

    // (C + X) pred (C + Y)
    if sc_is_add(lhs.*) && sc_nops(lhs.*) == 2 && sc_is_const(sc_op(lhs.*, 0)) &&
       sc_is_add(rhs.*) && sc_nops(rhs.*) == 2 && sc_op(rhs.*, 0) == sc_op(lhs.*, 0) {
        la := lhs.*; ra := rhs.*;
        p := pred.*;
        if icmp_is_equality(p) || (icmp_is_signed(p) && sc_has_nsw(la) && sc_has_nsw(ra)) || (icmp_is_unsigned(p) && sc_has_nuw(la) && sc_has_nuw(ra)) {
            lhs.* = sc_op(la, 1); rhs.* = sc_op(ra, 1); changed = true;
        }
    }
    // (C * X) pred (C * Y)
    if sc_is_mul(lhs.*) && sc_nops(lhs.*) == 2 && sc_is_const(sc_op(lhs.*, 0)) &&
       sc_is_mul(rhs.*) && sc_nops(rhs.*) == 2 && sc_op(rhs.*, 0) == sc_op(lhs.*, 0) {
        lm := lhs.*; rm := rhs.*;
        both_nuw := sc_has_nuw(lm) && sc_has_nuw(rm);
        both_nsw := sc_has_nsw(lm) && sc_has_nsw(rm);
        p := pred.*;
        c := sc_ap(sc_op(lm, 0));
        if (icmp_is_equality(p) && (both_nuw || both_nsw)) || (icmp_is_signed(p) && both_nsw && ap_is_strictly_positive(c)) ||
           (icmp_is_unsigned(p) && both_nuw) {
            lhs.* = sc_op(lm, 1); rhs.* = sc_op(rm, 1); changed = true;
        }
    }

    if sc_is_addrec(rhs.*) {
        l := sc_loop(rhs.*);
        if sc_is_loop_invariant(lhs.*, l) && sc_properly_dominates(lhs.*, li_header(se.li, l)) {
            t := lhs.*; lhs.* = rhs.*; rhs.* = t;
            pred.* = icmp_swapped(pred.*);
            changed = true;
        }
    }

    if sc_is_const(rhs.*) {
        ra := sc_ap(rhs.*);
        simplified_by_cr := false;
        if !icmp_is_equality(pred.*) {
            exact_cr := cr_exact_icmp_region(pred.*, ra);
            if cr_is_full_set(exact_cr) return trivial_case(pred, samesign, lhs, rhs, true);
            if cr_is_empty_set(exact_cr) return trivial_case(pred, samesign, lhs, rhs, false);
            ok, new_pred, new_rhs := cr_equivalent_icmp_no_offset(exact_cr);
            if ok && icmp_is_equality(new_pred) {
                pred.* = new_pred; samesign.* = false;
                rhs.* = sc_get_constant(new_rhs);
                changed = true; simplified_by_cr = true;
            }
        }
        if !simplified_by_cr {
            if pred.* == {
                case ICMP_EQ; #through;
                case ICMP_NE;
                    if ap_is_zero(ra) {
                        ok, l2, r2 := match_binary_sub(lhs.*);
                        if ok { lhs.* = l2; rhs.* = r2; changed = true; }
                    }
                case ICMP_UGE;
                    pred.* = ICMP_UGT; samesign.* = false; rhs.* = sc_get_constant(ap_sub_u64(ra, 1)); changed = true;
                case ICMP_ULE;
                    pred.* = ICMP_ULT; samesign.* = false; rhs.* = sc_get_constant(ap_add_u64(ra, 1)); changed = true;
                case ICMP_SGE;
                    pred.* = ICMP_SGT; samesign.* = false; rhs.* = sc_get_constant(ap_sub_u64(ra, 1)); changed = true;
                case ICMP_SLE;
                    pred.* = ICMP_SLT; samesign.* = false; rhs.* = sc_get_constant(ap_add_u64(ra, 1)); changed = true;
            }
        }
    }

    if has_same_value(lhs.*, rhs.*) {
        if icmp_is_true_when_equal(pred.*) return trivial_case(pred, samesign, lhs, rhs, true);
        if icmp_is_false_when_equal(pred.*) return trivial_case(pred, samesign, lhs, rhs, false);
    }

    if pred.* == {
        case ICMP_SLE;
            if !ap_is_max_signed(sc_signed_range_max(rhs.*)) {
                rhs.* = sc_get_add2(sc_get_constant_t(sc_type(rhs.*), 1, true), rhs.*, SF_NSW);
                pred.* = ICMP_SLT; samesign.* = false; changed = true;
            } else if !ap_is_min_signed(sc_signed_range_min(lhs.*)) {
                lhs.* = sc_get_add2(sc_get_constant_t(sc_type(rhs.*), 0xFFFF_FFFF_FFFF_FFFF, true), lhs.*, SF_NSW);
                pred.* = ICMP_SLT; samesign.* = false; changed = true;
            }
        case ICMP_SGE;
            if !ap_is_min_signed(sc_signed_range_min(rhs.*)) {
                rhs.* = sc_get_add2(sc_get_constant_t(sc_type(rhs.*), 0xFFFF_FFFF_FFFF_FFFF, true), rhs.*, SF_NSW);
                pred.* = ICMP_SGT; samesign.* = false; changed = true;
            } else if !ap_is_max_signed(sc_signed_range_max(lhs.*)) {
                lhs.* = sc_get_add2(sc_get_constant_t(sc_type(rhs.*), 1, true), lhs.*, SF_NSW);
                pred.* = ICMP_SGT; samesign.* = false; changed = true;
            }
        case ICMP_ULE;
            if !ap_is_all_ones(sc_unsigned_range_max(rhs.*)) {
                rhs.* = sc_get_add2(sc_get_constant_t(sc_type(rhs.*), 1, true), rhs.*, SF_NUW);
                pred.* = ICMP_ULT; samesign.* = false; changed = true;
            } else if !ap_is_zero(sc_unsigned_range_min(lhs.*)) {
                lhs.* = sc_get_add2(sc_get_constant_t(sc_type(rhs.*), 0xFFFF_FFFF_FFFF_FFFF, true), lhs.*);
                pred.* = ICMP_ULT; samesign.* = false; changed = true;
            }
        case ICMP_UGE;
            r := rhs.*;
            if (sc_is_const(r) || ((sc_is_add(r) || sc_is_addrec(r)) && sc_is_const(sc_op(r, 0)))) && !ap_is_zero(sc_unsigned_range_min(r)) {
                rhs.* = sc_get_add2(sc_get_constant_t(sc_type(rhs.*), 0xFFFF_FFFF_FFFF_FFFF, true), rhs.*);
                pred.* = ICMP_UGT; samesign.* = false; changed = true;
            } else if !ap_is_all_ones(sc_unsigned_range_max(lhs.*)) {
                lhs.* = sc_get_add2(sc_get_constant_t(sc_type(rhs.*), 1, true), lhs.*, SF_NUW);
                pred.* = ICMP_UGT; samesign.* = false; changed = true;
            } else if !ap_is_zero(sc_unsigned_range_min(rhs.*)) {
                rhs.* = sc_get_add2(sc_get_constant_t(sc_type(rhs.*), 0xFFFF_FFFF_FFFF_FFFF, true), rhs.*);
                pred.* = ICMP_UGT; samesign.* = false; changed = true;
            }
    }
    if changed sc_simplify_icmp_operands(pred, samesign, lhs, rhs, depth + 1);
    return changed;
}
// m_scev_c_Mul(m_SCEV(X), m_SCEVVScale())
match_c_mul_vscale :: (s: Scev_Id) -> (bool, Scev_Id) {
    if !sc_is_mul(s) || sc_nops(s) != 2 return false, 0;
    if sc_kind(sc_op(s, 1)) == .VSCALE return true, sc_op(s, 0);
    if sc_kind(sc_op(s, 0)) == .VSCALE return true, sc_op(s, 1);
    return false, 0;
}
// ConstantRange::getEquivalentICmp(Pred, RHS) (the variant without an offset)
cr_equivalent_icmp_no_offset :: (r: Const_Range) -> (bool, u8, APInt) {
    pred, rhs, offset := cr_equivalent_icmp(r);
    if ap_is_zero(offset) return true, pred, rhs;
    return false, pred, rhs;
}

// ---------------------------------------------------------------- isKnownPredicate

// getUsedLoops (FindUsedLoops)
sc_vis_used_loops_follow :: (v: *Sc_Visitor, s: Scev_Id) -> bool {
    if sc_is_addrec(s) {
        l := sc_loop(s);
        for v.loops.* if it == l return true;
        array_add(v.loops, l);
    }
    return true;
}
sc_get_used_loops :: (s: Scev_Id, out: *[..] Loop_Id) {
    v: Sc_Visitor;
    v.kind = .USED_LOOPS;
    v.loops = out;
    sc_visit_all(s, *v);
}

// SplitIntoInitAndPostInc
split_into_init_and_post_inc :: (l: Loop_Id, s: Scev_Id) -> (Scev_Id, Scev_Id) {
    start := scev_init_rewrite(s, l);
    if start == SCEV_CNC return start, start;
    post_inc := scev_post_inc_rewrite(s, l);
    return start, post_inc;
}

// isKnownViaInduction
sc_is_known_via_induction :: (pred: u8, lhs: Scev_Id, rhs: Scev_Id) -> bool {
    loops_used: [..] Loop_Id; loops_used.allocator = temp;
    sc_get_used_loops(lhs, *loops_used);
    sc_get_used_loops(rhs, *loops_used);
    if loops_used.count == 0 return false;
    // max_element with properlyDominates(header1, header2) as "less": the most dominated loop
    mdl := loops_used[0];
    for k: 1..loops_used.count-1 {
        if dt_properly_dominates(se.dt, li_header(se.li, mdl), li_header(se.li, loops_used[k])) mdl = loops_used[k];
    }
    ls, lp := split_into_init_and_post_inc(mdl, lhs);
    if ls == SCEV_CNC return false;
    rs, rp := split_into_init_and_post_inc(mdl, rhs);
    if rs == SCEV_CNC return false;
    if !sc_is_available_at_loop_entry(ls, mdl) || !sc_is_available_at_loop_entry(rs, mdl) return false;
    return sc_is_loop_backedge_guarded_by_cond(mdl, pred, lp, rp) && sc_is_loop_entry_guarded_by_cond(mdl, pred, ls, rs);
}

sc_is_known_predicate :: (pred_in: u8, lhs_in: Scev_Id, rhs_in: Scev_Id) -> bool {
    pred := pred_in; lhs := lhs_in; rhs := rhs_in;
    ss := false;
    sc_simplify_icmp_operands(*pred, *ss, *lhs, *rhs);
    if sc_is_known_via_induction(pred, lhs, rhs) return true;
    if sc_is_known_predicate_via_splitting(pred, lhs, rhs) return true;
    return sc_is_known_via_non_recursive_reasoning(pred, lhs, rhs);
}
// evaluatePredicate: (known, value)
sc_evaluate_predicate :: (pred: u8, lhs: Scev_Id, rhs: Scev_Id) -> (bool, bool) {
    if sc_is_known_predicate(pred, lhs, rhs) return true, true;
    if sc_is_known_predicate(icmp_inverse(pred), lhs, rhs) return true, false;
    return false, false;
}
sc_is_known_predicate_at :: (pred: u8, lhs: Scev_Id, rhs: Scev_Id, cxt: Value_Id) -> bool {
    return sc_is_known_predicate(pred, lhs, rhs) || sc_is_basic_block_entry_guarded_by_cond(inst_block(cxt), pred, lhs, rhs);
}
// isKnownOnEveryIteration
sc_is_known_on_every_iteration :: (pred: u8, lhs: Scev_Id, rhs: Scev_Id) -> bool {
    l := sc_loop(lhs);
    return sc_is_loop_entry_guarded_by_cond(l, pred, sc_start(lhs), rhs) &&
           sc_is_loop_backedge_guarded_by_cond(l, pred, sc_get_post_inc_expr(lhs), rhs);
}

// isKnownPredicateViaConstantRanges
sc_is_known_predicate_via_constant_ranges :: (pred: u8, lhs: Scev_Id, rhs: Scev_Id) -> bool {
    if has_same_value(lhs, rhs) return icmp_is_true_when_equal(pred);
    check_range :: (pred: u8, lhs: Scev_Id, rhs: Scev_Id, signed: bool) -> bool {
        rl := ifx signed then sc_signed_range(lhs) else sc_unsigned_range(lhs);
        rr := ifx signed then sc_signed_range(rhs) else sc_unsigned_range(rhs);
        return cr_icmp(rl, pred, rr);
    }
    if pred == ICMP_EQ return false;
    if pred == ICMP_NE {
        if check_range(pred, lhs, rhs, true) || check_range(pred, lhs, rhs, false) return true;
        diff := sc_get_minus(lhs, rhs);
        return diff != SCEV_CNC && sc_is_known_non_zero(diff);
    }
    return check_range(pred, lhs, rhs, icmp_is_signed(pred));
}

// splitBinaryAdd
split_binary_add :: (e: Scev_Id) -> (bool, Scev_Id, Scev_Id, u8) {
    if !(sc_is_add(e) && sc_nops(e) == 2) return false, 0, 0, 0;
    return true, sc_op(e, 0), sc_op(e, 1), sc_flags(e);
}

// isKnownPredicateViaNoOverflow
sc_is_known_predicate_via_no_overflow :: (pred: u8, lhs_in: Scev_Id, rhs_in: Scev_Id) -> bool {
    lhs := lhs_in; rhs := rhs_in;
    match_binary_add_to_const :: (x: Scev_Id, y: Scev_Id, expected: u8) -> (bool, APInt, APInt) {
        none := ap_zero(1);
        ok, xc, xn, xf := split_binary_add(x);
        if !ok { xc = sc_get_zero(sc_type(x)); xn = x; xf = expected; }
        if !sc_is_const(xc) return false, none, none;
        ok2, yc, yn, yf := split_binary_add(y);
        if !ok2 { yc = sc_get_zero(sc_type(y)); yn = y; yf = expected; }
        if yn != xn return false, none, none;
        if !sc_is_const(yc) return false, none, none;
        if (yf & expected) != expected return false, none, none;
        if expected != SF_NUW && (xf & expected) != expected return false, none, none;
        return true, sc_ap(xc), sc_ap(yc);
    }
    p := pred;
    if p == ICMP_SGE || p == ICMP_SGT || p == ICMP_UGE || p == ICMP_UGT { t := lhs; lhs = rhs; rhs = t; p = icmp_swapped(p); }
    if p == {
        case ICMP_SLE; ok, c1, c2 := match_binary_add_to_const(lhs, rhs, SF_NSW); if ok && ap_sle(c1, c2) return true;
        case ICMP_SLT; ok, c1, c2 := match_binary_add_to_const(lhs, rhs, SF_NSW); if ok && ap_slt(c1, c2) return true;
        case ICMP_ULE; ok, c1, c2 := match_binary_add_to_const(lhs, rhs, SF_NUW); if ok && ap_ule(c1, c2) return true;
        case ICMP_ULT; ok, c1, c2 := match_binary_add_to_const(lhs, rhs, SF_NUW); if ok && ap_ult(c1, c2) return true;
    }
    return false;
}

// isKnownPredicateViaSplitting
sc_is_known_predicate_via_splitting :: (pred: u8, lhs: Scev_Id, rhs: Scev_Id) -> bool {
    if pred != ICMP_ULT || se.proving_split_predicate return false;
    se.proving_split_predicate = true;
    defer se.proving_split_predicate = false;
    return sc_is_known_non_negative(rhs) && sc_is_known_predicate(ICMP_SGE, lhs, sc_get_zero(sc_type(lhs))) &&
           sc_is_known_predicate(ICMP_SLT, lhs, rhs);
}

// isImpliedViaGuard
sc_is_implied_via_guard :: (bb: Value_Id, pred: u8, lhs: Scev_Id, rhs: Scev_Id) -> bool {
    if !se.has_guards return false;
    for i: block_insts(bb) {
        if inst_op(i) == .CALL && call_iid(i) == IID_EXPERIMENTAL_GUARD {
            if sc_is_implied_cond_value(pred, lhs, rhs, op(i, 0), false) return true;
        }
    }
    return false;
}

// isLoopBackedgeGuardedByCond
sc_is_loop_backedge_guarded_by_cond :: (l: Loop_Id, pred: u8, lhs: Scev_Id, rhs: Scev_Id) -> bool {
    if l == NONE || !dt_is_reachable_from_entry(se.dt, li_header(se.li, l)) return true;
    if sc_is_known_via_non_recursive_reasoning(pred, lhs, rhs) return true;
    latch := li_loop_latch(se.li, l);
    if latch == NONE return false;
    lcp := block_terminator(latch);
    if inst_op(lcp) == .CONDBR && sc_is_implied_cond_value(pred, lhs, rhs, op(lcp, 0), get_successor(lcp, 0) != li_header(se.li, l))
        return true;
    if se.walking_be_dominating_conds return false;
    se.walking_be_dominating_conds = true;
    defer se.walking_be_dominating_conds = false;

    bti := sc_get_backedge_taken_info(l);
    latch_be_count := bti_get_exact_block(bti, latch);
    if latch_be_count != SCEV_CNC {
        ty := sc_type(latch_be_count);
        loop_counter := sc_get_add_rec(sc_get_zero(ty), sc_get_one(ty), l, SF_NUW | SF_NW);
        if sc_is_implied_cond(pred, lhs, rhs, ICMP_ULT, false, loop_counter, latch_be_count) return true;
    }
    if se.ac for ci: se.ac.assumes {
        if vkind(ci) == .DEAD continue;
        if !dt_dominates_inst(se.dt, ci, block_terminator(latch)) continue;
        if sc_is_implied_cond_value(pred, lhs, rhs, op(ci, 0), false) return true;
    }
    if sc_is_implied_via_guard(latch, pred, lhs, rhs) return true;
    bb := latch;
    header := li_header(se.li, l);
    while bb != header {
        if sc_is_implied_via_guard(bb, pred, lhs, rhs) return true;
        pbb := block_single_predecessor(bb);
        if pbb != NONE {
            cont_br := block_terminator(pbb);
            if inst_op(cont_br) == .CONDBR && get_successor(cont_br, 0) != get_successor(cont_br, 1) {
                if sc_is_implied_cond_value(pred, lhs, rhs, op(cont_br, 0), bb != get_successor(cont_br, 0)) return true;
            }
        }
        bb = dt_idom_block(se.dt, bb);
    }
    return false;
}

// getPredecessorWithUniqueSuccessorForBB
sc_get_predecessor_with_unique_successor :: (bb: Value_Id) -> (Value_Id, Value_Id) {
    pred := block_single_predecessor(bb);
    if pred != NONE return pred, bb;
    l := li_loop_for(se.li, bb);
    if l != NONE return li_loop_predecessor(se.li, l), li_header(se.li, l);
    return NONE, bb;
}

// isBasicBlockEntryGuardedByCond
sc_is_basic_block_entry_guarded_by_cond :: (bb: Value_Id, pred: u8, lhs: Scev_Id, rhs: Scev_Id) -> bool {
    if !dt_is_reachable_from_entry(se.dt, bb) return true;
    Ctx :: struct {
        pred: u8; non_strict: u8; lhs: Scev_Id; rhs: Scev_Id; bb: Value_Id;
        proving_strict: bool; proved_non_strict: bool; proved_non_equality: bool;
    }
    c: Ctx;
    c.pred = pred; c.lhs = lhs; c.rhs = rhs; c.bb = bb;
    c.non_strict = icmp_non_strict(pred);
    c.proving_strict = pred != c.non_strict;
    if c.proving_strict {
        if !c.proved_non_strict c.proved_non_strict = sc_is_known_via_non_recursive_reasoning(c.non_strict, lhs, rhs);
        if !c.proved_non_equality c.proved_non_equality = sc_is_known_via_non_recursive_reasoning(ICMP_NE, lhs, rhs);
        if c.proved_non_strict && c.proved_non_equality return true;
    }
    prove_via_cond :: (c: *Ctx, condition: Value_Id, inverse: bool) -> bool {
        cxt := block(c.bb).first;
        if sc_is_implied_cond_value(c.pred, c.lhs, c.rhs, condition, inverse, cxt) return true;
        if c.proving_strict {
            if !c.proved_non_strict c.proved_non_strict = sc_is_implied_cond_value(c.non_strict, c.lhs, c.rhs, condition, inverse, cxt);
            if !c.proved_non_equality c.proved_non_equality = sc_is_implied_cond_value(ICMP_NE, c.lhs, c.rhs, condition, inverse, cxt);
            if c.proved_non_strict && c.proved_non_equality return true;
        }
        return false;
    }
    containing := li_loop_for(se.li, bb);
    pred_bb: Value_Id;
    if containing != NONE && li_header(se.li, containing) == bb pred_bb = li_loop_predecessor(se.li, containing);
    else pred_bb = block_single_predecessor(bb);
    first := pred_bb; second := bb;
    while first != NONE {
        t := block_terminator(first);
        if inst_op(t) == .CONDBR {
            if prove_via_cond(*c, op(t, 0), get_successor(t, 0) != second) return true;
        }
        first, second = sc_get_predecessor_with_unique_successor(first);
    }
    if se.ac for ci: se.ac.assumes {
        if vkind(ci) == .DEAD continue;
        if !dt_dominates_inst_block(se.dt, ci, bb) continue;
        if prove_via_cond(*c, op(ci, 0), false) return true;
    }
    guard_decl := lookup_global("llvm.experimental.guard");
    if guard_decl != NONE {
        u := ir.v_first_use[guard_decl];
        while u != NONE {
            g := ir.u_user[u];
            if is_inst(g) && inst_op(g) == .CALL && call_iid(g) == IID_EXPERIMENTAL_GUARD && inst_fn(g) == block_fn(bb) &&
               dt_dominates_inst_block(se.dt, g, bb) {
                if prove_via_cond(*c, op(g, 0), false) return true;
            }
            u = ir.u_next[u];
        }
    }
    return false;
}

// isLoopEntryGuardedByCond
sc_is_loop_entry_guarded_by_cond :: (l: Loop_Id, pred: u8, lhs: Scev_Id, rhs: Scev_Id) -> bool {
    if l == NONE return false;
    if sc_is_known_via_non_recursive_reasoning(pred, lhs, rhs) return true;
    return sc_is_basic_block_entry_guarded_by_cond(li_header(se.li, l), pred, lhs, rhs);
}

// isImpliedCond(Pred, LHS, RHS, FoundCondValue, Inverse, CtxI)
sc_is_implied_cond_value :: (pred: u8, lhs: Scev_Id, rhs: Scev_Id, found_cond: Value_Id, inverse: bool, cxt: Value_Id = NONE) -> bool {
    if is_const_int(found_cond) && is_int_type_bits(vtype(found_cond), 1) && ap_is_one(const_ap(found_cond)) == inverse return true;
    if table_contains(*se.pending_loop_predicates, found_cond) return false;
    table_set(*se.pending_loop_predicates, found_cond, true);
    defer table_remove(*se.pending_loop_predicates, found_cond);
    ok, is_and, op0, op1 := match_logical_and_or(found_cond);
    if ok {
        if is_and {
            if !inverse return sc_is_implied_cond_value(pred, lhs, rhs, op0, inverse, cxt) || sc_is_implied_cond_value(pred, lhs, rhs, op1, inverse, cxt);
        } else {
            if inverse return sc_is_implied_cond_value(pred, lhs, rhs, op0, inverse, cxt) || sc_is_implied_cond_value(pred, lhs, rhs, op1, inverse, cxt);
        }
    }
    ici := found_cond;
    if !is_inst(ici) || inst_op(ici) != .ICMP return false;
    found_pred := inst_pred(ici);
    found_ss := (opr_flags(ici) & F_EXACT) != 0;
    if inverse found_pred = icmp_inverse(found_pred);
    found_lhs := sc_get_scev(op(ici, 0));
    found_rhs := sc_get_scev(op(ici, 1));
    return sc_is_implied_cond(pred, lhs, rhs, found_pred, found_ss, found_lhs, found_rhs, cxt);
}

// isImpliedCond(Pred, LHS, RHS, FoundPred, FoundLHS, FoundRHS, CtxI)
sc_is_implied_cond :: (pred: u8, lhs_in: Scev_Id, rhs_in: Scev_Id, found_pred: u8, found_ss: bool, found_lhs_in: Scev_Id, found_rhs_in: Scev_Id, cxt: Value_Id = NONE) -> bool {
    lhs := lhs_in; rhs := rhs_in; found_lhs := found_lhs_in; found_rhs := found_rhs_in;
    if sc_bits(lhs) < sc_bits(found_lhs) {
        if !icmp_is_signed(found_pred) && !sc_is_ptr(found_lhs) && !sc_is_ptr(found_rhs) {
            narrow_type := sc_type(lhs);
            wide_type := sc_type(found_lhs);
            bits := sc_type_bits(narrow_type);
            max_value := sc_get_zero_extend(sc_get_constant(ap_all_ones(bits)), wide_type);
            if sc_is_known_via_non_recursive_reasoning(ICMP_ULE, found_lhs, max_value) &&
               sc_is_known_via_non_recursive_reasoning(ICMP_ULE, found_rhs, max_value) {
                trunc_lhs := sc_get_truncate(found_lhs, narrow_type);
                trunc_rhs := sc_get_truncate(found_rhs, narrow_type);
                if sc_is_implied_cond_balanced_types(pred, lhs, rhs, found_pred, false, trunc_lhs, trunc_rhs, cxt) return true;
            }
        }
        if sc_is_ptr(lhs) || sc_is_ptr(rhs) return false;
        if icmp_is_signed(pred) {
            lhs = sc_get_sign_extend(lhs, sc_type(found_lhs));
            rhs = sc_get_sign_extend(rhs, sc_type(found_lhs));
        } else {
            lhs = sc_get_zero_extend(lhs, sc_type(found_lhs));
            rhs = sc_get_zero_extend(rhs, sc_type(found_lhs));
        }
    } else if sc_bits(lhs) > sc_bits(found_lhs) {
        if sc_is_ptr(found_lhs) || sc_is_ptr(found_rhs) return false;
        if icmp_is_signed(found_pred) {
            found_lhs = sc_get_sign_extend(found_lhs, sc_type(lhs));
            found_rhs = sc_get_sign_extend(found_rhs, sc_type(lhs));
        } else {
            found_lhs = sc_get_zero_extend(found_lhs, sc_type(lhs));
            found_rhs = sc_get_zero_extend(found_rhs, sc_type(lhs));
        }
    }
    return sc_is_implied_cond_balanced_types(pred, lhs, rhs, found_pred, found_ss, found_lhs, found_rhs, cxt);
}


// isImpliedCondBalancedTypes
sc_is_implied_cond_balanced_types :: (pred_in: u8, lhs_in: Scev_Id, rhs_in: Scev_Id, found_pred_in: u8, found_ss_in: bool, found_lhs_in: Scev_Id, found_rhs_in: Scev_Id, cxt: Value_Id) -> bool {
    pred := pred_in; lhs := lhs_in; rhs := rhs_in;
    found_pred := found_pred_in; found_ss := found_ss_in; found_lhs := found_lhs_in; found_rhs := found_rhs_in;
    pss := false;
    if sc_simplify_icmp_operands(*pred, *pss, *lhs, *rhs) {
        if lhs == rhs return icmp_is_true_when_equal(pred);
    }
    if sc_simplify_icmp_operands(*found_pred, *found_ss, *found_lhs, *found_rhs) {
        if found_lhs == found_rhs return icmp_is_false_when_equal(found_pred);
    }
    if lhs == found_rhs || rhs == found_lhs {
        if sc_is_const(rhs) {
            t := found_lhs; found_lhs = found_rhs; found_rhs = t;
            found_pred = icmp_swapped(found_pred);
        } else {
            t := lhs; lhs = rhs; rhs = t;
            pred = icmp_swapped(pred);
        }
    }
    {
        okm, p, pss2 := cmp_get_matching(found_pred, found_ss, pred, false);
        if okm return sc_is_implied_cond_operands(p, lhs, rhs, found_lhs, found_rhs, cxt);
    }
    {
        okm, p, pss2 := cmp_get_matching(icmp_swapped(found_pred), found_ss, pred, false);
        if okm {
            if !sc_is_const(rhs) && !sc_is_addrec(lhs) return sc_is_implied_cond_operands(icmp_swapped(p), rhs, lhs, found_lhs, found_rhs, cxt);
            if !sc_is_const(found_rhs) && !sc_is_addrec(found_lhs) return sc_is_implied_cond_operands(p, lhs, rhs, found_rhs, found_lhs, cxt);
            if !sc_is_ptr(lhs) && !sc_is_ptr(rhs) &&
               sc_is_implied_cond_operands(icmp_swapped(p), sc_get_not(lhs), sc_get_not(rhs), found_lhs, found_rhs, cxt) return true;
            if !sc_is_ptr(found_lhs) && !sc_is_ptr(found_rhs) &&
               sc_is_implied_cond_operands(p, lhs, rhs, sc_get_not(found_lhs), sc_get_not(found_rhs), cxt) return true;
            return false;
        }
    }
    // IsSignFlippedPredicate(Pred, FoundPred)
    if icmp_is_relational(found_pred) && pred == icmp_flipped_signedness(found_pred) {
        if sc_have_same_sign(found_lhs, found_rhs) return sc_is_implied_cond_operands(pred, lhs, rhs, found_lhs, found_rhs, cxt);
        cp := pred; cfp := found_pred;
        cl := lhs; cr := rhs; cfl := found_lhs; cfr := found_rhs;
        if icmp_is_gt(cp) || icmp_is_ge(cp) {
            cp = icmp_swapped(cp);
            cfp = icmp_swapped(cfp);
            t := cl; cl = cr; cr = t;
            t = cfl; cfl = cfr; cfr = t;
        }
        if icmp_is_signed(cp) && sc_is_known_non_negative(cr) return sc_is_implied_cond_operands(cfp, cl, cr, cfl, cfr);
        if icmp_is_unsigned(cp) && sc_is_known_negative(cr) return sc_is_implied_cond_operands(cfp, cl, cr, cfl, cfr);
    }
    if found_pred == ICMP_NE && (sc_is_const(found_lhs) || sc_is_const(found_rhs)) {
        c, v: Scev_Id;
        if sc_is_const(found_lhs) { c = found_lhs; v = found_rhs; }
        else { c = found_rhs; v = found_lhs; }
        mn := ifx icmp_is_signed(pred) then sc_signed_range_min(v) else sc_unsigned_range_min(v);
        if ap_eq(mn, sc_ap(c)) {
            sharper_min := ap_add_u64(mn, 1);
            if pred == ICMP_SGE || pred == ICMP_UGE || pred == ICMP_SGT || pred == ICMP_UGT {
                if pred == ICMP_SGE || pred == ICMP_UGE {
                    if sc_is_implied_cond_operands(pred, lhs, rhs, v, sc_get_constant(sharper_min), cxt) return true;
                }
                if sc_is_implied_cond_operands(pred, lhs, rhs, v, sc_get_constant(mn), cxt) return true;
            } else if pred == ICMP_SLE || pred == ICMP_ULE || pred == ICMP_SLT || pred == ICMP_ULT {
                if pred == ICMP_SLE || pred == ICMP_ULE {
                    if sc_is_implied_cond_operands(icmp_swapped(pred), rhs, lhs, v, sc_get_constant(sharper_min), cxt) return true;
                }
                if sc_is_implied_cond_operands(icmp_swapped(pred), rhs, lhs, v, sc_get_constant(mn), cxt) return true;
            }
        }
    }
    if found_pred == ICMP_EQ && icmp_is_true_when_equal(pred) {
        if sc_is_implied_cond_operands(pred, lhs, rhs, found_lhs, found_rhs, cxt) return true;
    }
    if pred == ICMP_NE && !icmp_is_true_when_equal(found_pred) {
        if sc_is_implied_cond_operands(found_pred, lhs, rhs, found_lhs, found_rhs, cxt) return true;
    }
    if sc_is_implied_cond_operands_via_ranges(pred, lhs, rhs, found_pred, found_lhs, found_rhs) return true;
    return false;
}

// computeConstantDifference (has = false is std::nullopt)
sc_compute_constant_difference :: (more_in: Scev_Id, less_in: Scev_Id) -> (bool, APInt) {
    more := more_in; less := less_in;
    bw := sc_bits(more);
    diff := ap_zero(bw);
    diff_mul := ap_one(bw);
    for iter: 0..7 {
        if more == less return true, diff;
        if sc_is_addrec(less) && sc_is_addrec(more) {
            if sc_loop(less) != sc_loop(more) return false, diff;
            if !sc_is_affine(less) || !sc_is_affine(more) return false, diff;
            if sc_step_recurrence(less) != sc_step_recurrence(more) return false, diff;
            less = sc_start(less); more = sc_start(more);
            continue;
        }
        match_const_mul :: (s: Scev_Id) -> (bool, Scev_Id, APInt) {
            if sc_is_mul(s) && sc_nops(s) == 2 && sc_is_const(sc_op(s, 0)) return true, sc_op(s, 1), sc_ap(sc_op(s, 0));
            return false, 0, ap_zero(1);
        }
        {
            okm, mo, mc := match_const_mul(more);
            if okm {
                okl, lo, lc := match_const_mul(less);
                if okl && ap_eq(mc, lc) {
                    more = mo; less = lo;
                    diff_mul = ap_mul(diff_mul, mc);
                    continue;
                }
            }
        }
        keys: [..] Scev_Id; keys.allocator = temp;
        muls: [..] s32; muls.allocator = temp;
        add :: (s: Scev_Id, mul: s32, diff: *APInt, diff_mul: APInt, keys: *[..] Scev_Id, muls: *[..] s32) {
            if sc_is_const(s) {
                if mul == 1 diff.* = ap_add(diff.*, ap_mul(sc_ap(s), diff_mul));
                else diff.* = ap_sub(diff.*, ap_mul(sc_ap(s), diff_mul));
            } else {
                for keys.* if it == s { muls.*[it_index] += mul; return; }
                array_add(keys, s); array_add(muls, mul);
            }
        }
        decompose :: (s: Scev_Id, mul: s32, diff: *APInt, diff_mul: APInt, keys: *[..] Scev_Id, muls: *[..] s32) {
            if sc_is_add(s) {
                for i: 0..cast(s64) sc_nops(s) - 1 add(sc_op(s, cast(u32) i), mul, diff, diff_mul, keys, muls);
            } else add(s, mul, diff, diff_mul, keys, muls);
        }
        decompose(more, 1, *diff, diff_mul, *keys, *muls);
        decompose(less, -1, *diff, diff_mul, *keys, *muls);
        new_more := SCEV_NULL; new_less := SCEV_NULL;
        for s, k: keys {
            m := muls[k];
            if m == 0 continue;
            if m == 1 { if new_more != SCEV_NULL return false, diff; new_more = s; }
            else if m == -1 { if new_less != SCEV_NULL return false, diff; new_less = s; }
            else return false, diff;
        }
        if new_more == more || new_less == less return false, diff;
        more = new_more; less = new_less;
        if more == SCEV_NULL && less == SCEV_NULL return true, diff;
        if more == SCEV_NULL || less == SCEV_NULL return false, diff;
    }
    return false, diff;
}

// isImpliedCondOperandsViaAddRecStart
sc_is_implied_cond_operands_via_add_rec_start :: (pred: u8, lhs: Scev_Id, rhs: Scev_Id, found_lhs: Scev_Id, found_rhs: Scev_Id, cxt: Value_Id) -> bool {
    if cxt == NONE return false;
    context_bb := inst_block(cxt);
    if sc_is_addrec(found_lhs) {
        l := sc_loop(found_lhs);
        latch := li_loop_latch(se.li, l);
        if !li_contains(se.li, l, context_bb) || latch == NONE || !dt_dominates(se.dt, context_bb, latch) return false;
        if !sc_is_available_at_loop_entry(found_rhs, l) return false;
        return sc_is_implied_cond_operands(pred, lhs, rhs, sc_start(found_lhs), found_rhs);
    }
    if sc_is_addrec(found_rhs) {
        l := sc_loop(found_rhs);
        latch := li_loop_latch(se.li, l);
        if !li_contains(se.li, l, context_bb) || latch == NONE || !dt_dominates(se.dt, context_bb, latch) return false;
        if !sc_is_available_at_loop_entry(found_lhs, l) return false;
        return sc_is_implied_cond_operands(pred, lhs, rhs, found_lhs, sc_start(found_rhs));
    }
    return false;
}

// isImpliedCondOperandsViaNoOverflow
sc_is_implied_cond_operands_via_no_overflow :: (pred: u8, lhs: Scev_Id, rhs: Scev_Id, found_lhs: Scev_Id, found_rhs: Scev_Id) -> bool {
    if pred != ICMP_SLT && pred != ICMP_ULT return false;
    if !sc_is_addrec(lhs) || !sc_is_addrec(found_lhs) return false;
    l := sc_loop(found_lhs);
    if l != sc_loop(lhs) return false;
    okl, ldiff := sc_compute_constant_difference(lhs, found_lhs);
    if !okl return false;
    okr, rdiff := sc_compute_constant_difference(rhs, found_rhs);
    if !okr || !ap_eq(ldiff, rdiff) return false;
    if ap_is_zero(ldiff) return true;
    limit: APInt;
    if pred == ICMP_ULT limit = ap_neg(rdiff);
    else limit = ap_sub(ap_signed_min(sc_bits(rhs)), rdiff);
    return sc_is_available_at_loop_entry(found_rhs, l) && sc_is_loop_entry_guarded_by_cond(l, pred, found_rhs, sc_get_constant(limit));
}

// isImpliedViaMerge
sc_is_implied_via_merge :: (pred_in: u8, lhs_in: Scev_Id, rhs_in: Scev_Id, found_lhs_in: Scev_Id, found_rhs_in: Scev_Id, depth: u32) -> bool {
    pred := pred_in; lhs := lhs_in; rhs := rhs_in; found_lhs := found_lhs_in; found_rhs := found_rhs_in;
    lphi: Value_Id = NONE; rphi: Value_Id = NONE;
    defer {
        if lphi != NONE table_remove(*se.pending_merges, lphi);
        if rphi != NONE table_remove(*se.pending_merges, rphi);
    }
    if sc_is_unknown(lhs) {
        p := sc_value(lhs);
        if is_inst(p) && inst_op(p) == .PHI {
            if table_contains(*se.pending_merges, p) return false;
            table_set(*se.pending_merges, p, true);
            lphi = p;
        }
    }
    if sc_is_unknown(rhs) {
        p := sc_value(rhs);
        if is_inst(p) && inst_op(p) == .PHI {
            if table_contains(*se.pending_merges, p) return false;
            table_set(*se.pending_merges, p, true);
            rphi = p;
        }
    }
    if lphi == NONE && rphi == NONE return false;
    if lphi == NONE {
        t := lhs; lhs = rhs; rhs = t;
        t = found_lhs; found_lhs = found_rhs; found_rhs = t;
        tp := lphi; lphi = rphi; rphi = tp;
        pred = icmp_swapped(pred);
    }
    lbb := inst_block(lphi);
    rar := ifx sc_is_addrec(rhs) then rhs else SCEV_CNC;
    proved_easily :: (pred: u8, s1: Scev_Id, s2: Scev_Id, found_lhs: Scev_Id, found_rhs: Scev_Id, depth: u32) -> bool {
        return sc_is_known_via_non_recursive_reasoning(pred, s1, s2) ||
               sc_is_implied_cond_operands_via_ranges(pred, s1, s2, pred, found_lhs, found_rhs) ||
               sc_is_implied_via_operations(pred, s1, s2, found_lhs, found_rhs, depth);
    }
    preds: [..] Value_Id; preds.allocator = temp;
    if rphi != NONE && inst_block(rphi) == lbb {
        block_predecessors(lbb, *preds);
        for inc_bb: preds {
            l := sc_get_scev(phi_incoming_value_for_block(lphi, inc_bb));
            r := sc_get_scev(phi_incoming_value_for_block(rphi, inc_bb));
            if !proved_easily(pred, l, r, found_lhs, found_rhs, depth) return false;
        }
    } else if rar != SCEV_CNC && li_header(se.li, sc_loop(rar)) == lbb {
        if nops(lphi) != 2 return false;
        rloop := sc_loop(rar);
        predecessor := li_loop_predecessor(se.li, rloop);
        l1 := sc_get_scev(phi_incoming_value_for_block(lphi, predecessor));
        if !proved_easily(pred, l1, sc_start(rar), found_lhs, found_rhs, depth) return false;
        latch := li_loop_latch(se.li, rloop);
        l2 := sc_get_scev(phi_incoming_value_for_block(lphi, latch));
        if !proved_easily(pred, l2, sc_get_post_inc_expr(rar), found_lhs, found_rhs, depth) return false;
    } else {
        block_predecessors(lbb, *preds);
        for inc_bb: preds {
            if !sc_dominates(rhs, inc_bb) return false;
            l := sc_get_scev(phi_incoming_value_for_block(lphi, inc_bb));
            if !sc_properly_dominates(l, lbb) return false;
            lp := li_loop_for(se.li, lbb);
            if lp != NONE && sc_has_computable_loop_evolution(l, lp) return false;
            if !proved_easily(pred, l, rhs, found_lhs, found_rhs, depth) return false;
        }
    }
    return true;
}

// isImpliedCondOperandsViaShift
sc_is_implied_cond_operands_via_shift :: (pred_in: u8, lhs_in: Scev_Id, rhs_in: Scev_Id, found_lhs_in: Scev_Id, found_rhs_in: Scev_Id) -> bool {
    pred := pred_in; lhs := lhs_in; rhs := rhs_in; found_lhs := found_lhs_in; found_rhs := found_rhs_in;
    if rhs == found_rhs {
        t := lhs; lhs = rhs; rhs = t;
        t = found_lhs; found_lhs = found_rhs; found_rhs = t;
        pred = icmp_swapped(pred);
    }
    if lhs != found_lhs return false;
    if !sc_is_unknown(found_rhs) return false;
    v := sc_value(found_rhs);
    if (vkind(v) == .INST || vkind(v) == .C_EXPR) && opr_code(v) == .LSHR {
        shiftee := sc_get_scev(op(v, 0));
        if pred == ICMP_ULT || pred == ICMP_ULE return sc_is_known_predicate(ICMP_ULE, shiftee, rhs);
        if pred == ICMP_SLT || pred == ICMP_SLE {
            if sc_is_known_non_negative(shiftee) return sc_is_known_predicate(ICMP_SLE, shiftee, rhs);
        }
    }
    return false;
}

// isImpliedCondOperandsViaMatchingDiff
sc_is_implied_cond_operands_via_matching_diff :: (pred: u8, lhs: Scev_Id, rhs: Scev_Id, found_lhs: Scev_Id, found_rhs: Scev_Id) -> bool {
    if !icmp_is_equality(pred) return false;
    if (!sc_is_addrec(lhs) && !sc_is_addrec(rhs)) || (!sc_is_addrec(found_lhs) && !sc_is_addrec(found_rhs)) return false;
    query := ifx sc_is_addrec(lhs) then lhs else rhs;
    found := ifx sc_is_addrec(found_lhs) then found_lhs else found_rhs;
    if sc_loop(query) != sc_loop(found) return false;
    if sc_step_recurrence(query) != sc_step_recurrence(found) return false;
    found_diff := sc_get_minus(found_lhs, found_rhs);
    if found_diff == SCEV_CNC return false;
    diff := sc_get_minus(lhs, rhs);
    if diff == SCEV_CNC return false;
    return diff == found_diff;
}

// isImpliedCondOperands
sc_is_implied_cond_operands :: (pred: u8, lhs: Scev_Id, rhs: Scev_Id, found_lhs: Scev_Id, found_rhs: Scev_Id, cxt: Value_Id = NONE) -> bool {
    return sc_is_implied_cond_operands_via_ranges(pred, lhs, rhs, pred, found_lhs, found_rhs) ||
           sc_is_implied_cond_operands_via_no_overflow(pred, lhs, rhs, found_lhs, found_rhs) ||
           sc_is_implied_cond_operands_via_shift(pred, lhs, rhs, found_lhs, found_rhs) ||
           sc_is_implied_cond_operands_via_add_rec_start(pred, lhs, rhs, found_lhs, found_rhs, cxt) ||
           sc_is_implied_cond_operands_via_matching_diff(pred, lhs, rhs, found_lhs, found_rhs) ||
           sc_is_implied_cond_operands_helper(pred, lhs, rhs, found_lhs, found_rhs);
}

// IsMinMaxConsistingOf
is_min_max_consisting_of :: (kind: Scev_Kind, e: Scev_Id, candidate: Scev_Id) -> bool {
    if sc_kind(e) != kind return false;
    for i: 0..cast(s64) sc_nops(e) - 1 if sc_op(e, cast(u32) i) == candidate return true;
    return false;
}
// IsKnownPredicateViaAddRecStart
is_known_predicate_via_add_rec_start :: (pred: u8, lhs: Scev_Id, rhs: Scev_Id) -> bool {
    if !icmp_is_relational(pred) return false;
    if !(sc_is_addrec(lhs) && sc_is_affine(lhs)) return false;
    if !(sc_is_addrec(rhs) && sc_is_affine(rhs)) return false;
    if sc_op(rhs, 1) != sc_op(lhs, 1) || sc_loop(rhs) != sc_loop(lhs) return false;
    nw := ifx icmp_is_signed(pred) then SF_NSW else SF_NUW;
    if sc_flags(lhs, nw) == 0 || sc_flags(rhs, nw) == 0 return false;
    return sc_is_known_predicate(pred, sc_start(lhs), sc_start(rhs));
}
// IsKnownPredicateViaMinOrMax
is_known_predicate_via_min_or_max :: (pred: u8, lhs_in: Scev_Id, rhs_in: Scev_Id) -> bool {
    lhs := lhs_in; rhs := rhs_in;
    p := pred;
    if p == ICMP_SGE || p == ICMP_UGE || p == ICMP_UGT { t := lhs; lhs = rhs; rhs = t; p = icmp_swapped(p); }
    if p == {
        case ICMP_SLE; return is_min_max_consisting_of(.SMIN, lhs, rhs) || is_min_max_consisting_of(.SMAX, rhs, lhs);
        case ICMP_ULE; return is_min_max_consisting_of(.UMIN, lhs, rhs) || is_min_max_consisting_of(.UMAX, rhs, lhs);
        case ICMP_ULT;
            if sc_kind(lhs) == .UMIN {
                for i: 0..cast(s64) sc_nops(lhs) - 1 {
                    ok, d := sc_compute_constant_difference(rhs, sc_op(lhs, cast(u32) i));
                    if ok && !ap_is_zero(d) && ap_uge(sc_unsigned_range_min(rhs), d) return true;
                }
            }
            return false;
    }
    return false;
}

// isImpliedViaOperations
sc_is_implied_via_operations :: (pred_in: u8, lhs_in: Scev_Id, rhs_in: Scev_Id, found_lhs_in: Scev_Id, found_rhs_in: Scev_Id, depth: u32 = 0) -> bool {
    pred := pred_in; lhs := lhs_in; rhs := rhs_in; found_lhs := found_lhs_in; found_rhs := found_rhs_in;
    if cast(u64) depth > scev_opts.max_scev_operations_implication_depth return false;
    if icmp_is_lt(pred) {
        pred = icmp_swapped(pred);
        t := lhs; lhs = rhs; rhs = t;
        t = found_lhs; found_lhs = found_rhs; found_rhs = t;
    }
    p := pred;
    if p == ICMP_UGT {
        if sc_is_known_non_negative(found_lhs) && sc_is_known_non_negative(found_rhs) {
            minus_one := sc_get_minus_one(sc_type(lhs));
            if sc_is_implied_cond_operands(ICMP_SGT, lhs, minus_one, found_lhs, found_rhs) &&
               sc_is_implied_cond_operands(ICMP_SGT, rhs, minus_one, found_lhs, found_rhs)
                p = ICMP_SGT;
        }
    }
    if p != ICMP_SGT return false;
    get_op_from_sext :: (s: Scev_Id) -> Scev_Id { if sc_is_sext(s) return sc_op(s, 0); return s; }
    orig_lhs := lhs;
    orig_found_lhs := found_lhs;
    lhs = get_op_from_sext(lhs);
    found_lhs = get_op_from_sext(found_lhs);
    is_sgt_via_context :: (s1: Scev_Id, s2: Scev_Id, orig_found_lhs: Scev_Id, found_rhs: Scev_Id, depth: u32) -> bool {
        return sc_is_known_via_non_recursive_reasoning(ICMP_SGT, s1, s2) ||
               sc_is_implied_via_operations(ICMP_SGT, s1, s2, orig_found_lhs, found_rhs, depth + 1);
    }
    if sc_is_add(lhs) {
        if sc_bits(lhs) != sc_bits(rhs) return false;
        if !sc_has_nsw(lhs) return false;
        ll := sc_op(lhs, 0);
        lr := sc_op(lhs, 1);
        minus_one := sc_get_minus_one(sc_type(rhs));
        sum_gt :: (s1: Scev_Id, s2: Scev_Id, minus_one: Scev_Id, rhs: Scev_Id, ofl: Scev_Id, frhs: Scev_Id, depth: u32) -> bool {
            return is_sgt_via_context(s1, minus_one, ofl, frhs, depth) && is_sgt_via_context(s2, rhs, ofl, frhs, depth);
        }
        if sum_gt(ll, lr, minus_one, rhs, orig_found_lhs, found_rhs, depth) || sum_gt(lr, ll, minus_one, rhs, orig_found_lhs, found_rhs, depth) return true;
    } else if sc_is_unknown(lhs) {
        v := sc_value(lhs);
        if is_binary_operator(v) && inst_op(v) == .SDIV {
            ll := op(v, 0); lr := op(v, 1);
            if !is_const_int(lr) return false;
            denominator := sc_get_scev(lr);
            numerator := sc_get_existing(ll);
            if numerator == SCEV_CNC || sc_type(numerator) != sc_type(found_lhs) return false;
            if !has_same_value(numerator, found_lhs) || !sc_is_known_positive(denominator) return false;
            dty := sc_type(denominator);
            frhs_ty := sc_type(found_rhs);
            if (type_kind(dty) == .PTR) != (type_kind(frhs_ty) == .PTR) return false;
            wty := sc_wider_type(dty, frhs_ty);
            denominator_ext := sc_get_noop_or_sign_extend(denominator, wty);
            found_rhs_ext := sc_get_noop_or_sign_extend(found_rhs, wty);
            denom_minus_two := sc_get_minus(denominator_ext, sc_get_constant_t(wty, 2));
            if sc_is_known_non_positive(rhs) && is_sgt_via_context(found_rhs_ext, denom_minus_two, orig_found_lhs, found_rhs, depth) return true;
            minus_one := sc_get_minus_one(wty);
            neg_denom_minus_one := sc_get_minus(minus_one, denominator_ext);
            if sc_is_known_negative(rhs) && is_sgt_via_context(found_rhs_ext, neg_denom_minus_one, orig_found_lhs, found_rhs, depth) return true;
        }
    }
    if sc_is_implied_via_merge(pred, orig_lhs, rhs, orig_found_lhs, found_rhs, depth + 1) return true;
    return false;
}

// isKnownPredicateExtendIdiom
is_known_predicate_extend_idiom :: (pred: u8, lhs_in: Scev_Id, rhs_in: Scev_Id) -> bool {
    lhs := lhs_in; rhs := rhs_in;
    p := pred;
    if p == ICMP_SGE || p == ICMP_UGE { t := lhs; lhs = rhs; rhs = t; p = icmp_swapped(p); }
    if p == ICMP_SLE return sc_is_sext(lhs) && sc_is_zext(rhs) && sc_op(rhs, 0) == sc_op(lhs, 0);
    if p == ICMP_ULE return sc_is_zext(lhs) && sc_is_sext(rhs) && sc_op(rhs, 0) == sc_op(lhs, 0);
    return false;
}

// isKnownViaNonRecursiveReasoning
sc_is_known_via_non_recursive_reasoning :: (pred: u8, lhs: Scev_Id, rhs: Scev_Id) -> bool {
    return is_known_predicate_extend_idiom(pred, lhs, rhs) || sc_is_known_predicate_via_constant_ranges(pred, lhs, rhs) ||
           is_known_predicate_via_min_or_max(pred, lhs, rhs) || is_known_predicate_via_add_rec_start(pred, lhs, rhs) ||
           sc_is_known_predicate_via_no_overflow(pred, lhs, rhs);
}

// isImpliedCondOperandsHelper
sc_is_implied_cond_operands_helper :: (pred: u8, lhs: Scev_Id, rhs: Scev_Id, found_lhs: Scev_Id, found_rhs: Scev_Id) -> bool {
    if pred == {
        case ICMP_EQ; #through;
        case ICMP_NE;
            if has_same_value(lhs, found_lhs) && has_same_value(rhs, found_rhs) return true;
        case ICMP_SLT; #through;
        case ICMP_SLE;
            if sc_is_known_via_non_recursive_reasoning(ICMP_SLE, lhs, found_lhs) && sc_is_known_via_non_recursive_reasoning(ICMP_SGE, rhs, found_rhs) return true;
        case ICMP_SGT; #through;
        case ICMP_SGE;
            if sc_is_known_via_non_recursive_reasoning(ICMP_SGE, lhs, found_lhs) && sc_is_known_via_non_recursive_reasoning(ICMP_SLE, rhs, found_rhs) return true;
        case ICMP_ULT; #through;
        case ICMP_ULE;
            if sc_is_known_via_non_recursive_reasoning(ICMP_ULE, lhs, found_lhs) && sc_is_known_via_non_recursive_reasoning(ICMP_UGE, rhs, found_rhs) return true;
        case ICMP_UGT; #through;
        case ICMP_UGE;
            if sc_is_known_via_non_recursive_reasoning(ICMP_UGE, lhs, found_lhs) && sc_is_known_via_non_recursive_reasoning(ICMP_ULE, rhs, found_rhs) return true;
        case;
            fatal("ScalarEvolution: unexpected predicate in isImpliedCondOperandsHelper");
    }
    if sc_is_implied_via_operations(pred, lhs, rhs, found_lhs, found_rhs) return true;
    return false;
}

// isImpliedCondOperandsViaRanges
sc_is_implied_cond_operands_via_ranges :: (pred: u8, lhs: Scev_Id, rhs: Scev_Id, found_pred: u8, found_lhs: Scev_Id, found_rhs: Scev_Id) -> bool {
    if !sc_is_const(rhs) || !sc_is_const(found_rhs) return false;
    ok, addend := sc_compute_constant_difference(lhs, found_lhs);
    if !ok return false;
    const_found_rhs := sc_ap(found_rhs);
    found_lhs_range := cr_exact_icmp_region(found_pred, const_found_rhs);
    lhs_range := cr_add(found_lhs_range, cr_single(addend));
    const_rhs := sc_ap(rhs);
    return cr_icmp(lhs_range, pred, cr_single(const_rhs));
}

// ---------------------------------------------------------------- loop-invariant predicates (IndVarSimplify)

// evaluatePredicateAt: (known, value)
sc_evaluate_predicate_at :: (pred: u8, lhs: Scev_Id, rhs: Scev_Id, cxt: Value_Id) -> (bool, bool) {
    known, v := sc_evaluate_predicate(pred, lhs, rhs);
    if known return true, v;
    if sc_is_basic_block_entry_guarded_by_cond(inst_block(cxt), pred, lhs, rhs) return true, true;
    if sc_is_basic_block_entry_guarded_by_cond(inst_block(cxt), icmp_inverse(pred), lhs, rhs) return true, false;
    return false, false;
}

Monotonic_Kind :: enum u8 { NONE; INCREASING; DECREASING; }
// getMonotonicPredicateType(Impl)
sc_get_monotonic_predicate_type :: (lhs: Scev_Id, pred: u8) -> Monotonic_Kind {
    if !icmp_is_relational(pred) return .NONE;
    is_greater := icmp_is_ge(pred) || icmp_is_gt(pred);
    if icmp_is_unsigned(pred) {
        if !sc_has_nuw(lhs) return .NONE;
        return ifx is_greater then Monotonic_Kind.INCREASING else .DECREASING;
    }
    if !sc_has_nsw(lhs) return .NONE;
    step := sc_step_recurrence(lhs);
    if sc_is_known_non_negative(step) return ifx is_greater then Monotonic_Kind.INCREASING else .DECREASING;
    if sc_is_known_non_positive(step) return ifx !is_greater then Monotonic_Kind.INCREASING else .DECREASING;
    return .NONE;
}

// LoopInvariantPredicate
Loop_Inv_Pred :: struct { ok: bool; pred: u8; lhs: Scev_Id; rhs: Scev_Id; }

// getLoopInvariantPredicate
sc_get_loop_invariant_predicate :: (pred_in: u8, lhs_in: Scev_Id, rhs_in: Scev_Id, l: Loop_Id, cxt: Value_Id) -> Loop_Inv_Pred {
    pred := pred_in; lhs := lhs_in; rhs := rhs_in;
    if !sc_is_loop_invariant(rhs, l) {
        if !sc_is_loop_invariant(lhs, l) return .{};
        lhs, rhs = rhs, lhs;
        pred = icmp_swapped(pred);
    }
    if !sc_is_addrec(lhs) || sc_loop(lhs) != l return .{};
    mono := sc_get_monotonic_predicate_type(lhs, pred);
    if mono == .NONE return .{};
    p := ifx mono == .INCREASING then pred else icmp_inverse(pred);
    if sc_is_loop_backedge_guarded_by_cond(l, p, lhs, rhs) return .{true, pred, sc_start(lhs), rhs};
    if cxt == NONE return .{};
    if pred == ICMP_ULE || pred == ICMP_ULT {
        sign_flipped := icmp_flipped_signedness(pred);
        if sc_has_nsw(lhs) && sc_is_affine(lhs) && sc_is_known_positive(sc_step_recurrence(lhs)) &&
           sc_is_known_non_negative(rhs) && sc_is_known_predicate_at(sign_flipped, lhs, rhs, cxt)
            return .{true, pred, sc_start(lhs), rhs};
    }
    return .{};
}

// getLoopInvariantExitCondDuringFirstIterations
sc_get_loop_invariant_exit_cond_during_first_iterations :: (pred: u8, lhs: Scev_Id, rhs: Scev_Id, l: Loop_Id, cxt: Value_Id, max_iter: Scev_Id) -> Loop_Inv_Pred {
    r := sc_get_loop_invariant_exit_cond_during_first_iterations_impl(pred, lhs, rhs, l, cxt, max_iter);
    if r.ok return r;
    if sc_kind(max_iter) == .UMIN {
        ops := sc_operands(max_iter);
        for o: ops {
            r = sc_get_loop_invariant_exit_cond_during_first_iterations_impl(pred, lhs, rhs, l, cxt, o);
            if r.ok return r;
        }
    }
    return .{};
}
sc_get_loop_invariant_exit_cond_during_first_iterations_impl :: (pred_in: u8, lhs_in: Scev_Id, rhs_in: Scev_Id, l: Loop_Id, cxt: Value_Id, max_iter: Scev_Id) -> Loop_Inv_Pred {
    pred := pred_in; lhs := lhs_in; rhs := rhs_in;
    if !sc_is_loop_invariant(rhs, l) {
        if !sc_is_loop_invariant(lhs, l) return .{};
        lhs, rhs = rhs, lhs;
        pred = icmp_swapped(pred);
    }
    if !sc_is_addrec(lhs) || sc_loop(lhs) != l return .{};
    ar := lhs;
    // Pred.dropSameSign(): predicates here carry no samesign bit
    if !icmp_is_relational(pred) return .{};
    step := sc_step_recurrence(ar);
    one := sc_get_one(sc_type(step));
    minus_one := sc_get_negative(one);
    if step != one && step != minus_one return .{};
    if sc_type(ar) != sc_type(max_iter) return .{};
    last := evaluate_at_iteration(ar, max_iter);
    if !sc_is_loop_backedge_guarded_by_cond(l, pred, last, rhs) return .{};
    no_overflow: u8 = ifx icmp_is_signed(pred) then cast(u8) ICMP_SLE else ICMP_ULE;
    if step == minus_one no_overflow = icmp_swapped(no_overflow);
    start := sc_start(ar);
    if !sc_is_known_predicate_at(no_overflow, start, last, cxt) return .{};
    return .{true, pred, start, rhs};
}
