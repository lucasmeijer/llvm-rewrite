// LoopPredication (loop-predication): port of llvm/lib/Transforms/Scalar/LoopPredication.cpp. Guards (intrinsic
// or widenable branches to deoptimize blocks) inside a loop whose checks are range checks on the loop's IV are
// widened to loop-invariant checks; predicateLoopExits folds analyzeable deoptimizing exits into a widenable branch
// above the loop. Guard helpers: guard_utils.jai.

lp_cl: struct {
    enable_iv_truncation := true;                      // -loop-predication-enable-iv-truncation
    enable_count_down_loop := true;                    // -loop-predication-enable-count-down-loop
    skip_profitability_checks := false;                // -loop-predication-skip-profitability-checks
    latch_exit_probability_scale: float32 = 2.0;       // -loop-predication-latch-probability-scale
    predicate_widenable_branch_guards := true;         // -loop-predication-predicate-widenable-branches-to-deopt
    insert_assumes_of_predicated_guards_conditions := true;   // -loop-predication-insert-assumes-of-predicated-guards-conditions
};

lp_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    parse_b :: (dst: *bool, value: string, has_value: bool, name: string) {
        if !has_value { dst.* = true; return; }
        if value == "true" || value == "1" || value == "TRUE" || value == "True" dst.* = true;
        else if value == "false" || value == "0" || value == "FALSE" || value == "False" dst.* = false;
        else fatal("opt: for the --% option: '%' is invalid value for boolean argument! Try 0 or 1", name, value);
    }
    if name == {
        case "loop-predication-enable-iv-truncation"; parse_b(*lp_cl.enable_iv_truncation, value, has_value, name);
        case "loop-predication-enable-count-down-loop"; parse_b(*lp_cl.enable_count_down_loop, value, has_value, name);
        case "loop-predication-skip-profitability-checks"; parse_b(*lp_cl.skip_profitability_checks, value, has_value, name);
        case "loop-predication-predicate-widenable-branches-to-deopt"; parse_b(*lp_cl.predicate_widenable_branch_guards, value, has_value, name);
        case "loop-predication-insert-assumes-of-predicated-guards-conditions"; parse_b(*lp_cl.insert_assumes_of_predicated_guards_conditions, value, has_value, name);
        case "loop-predication-latch-probability-scale";
            if !has_value fatal("opt: for the --% option: requires a value!", name);
            v, ok := string_to_float64(value);
            if !ok fatal("opt: for the --% option: '%' value invalid for float argument!", name, value);
            lp_cl.latch_exit_probability_scale = cast(float32) v;
        case; return false;
    }
    return true;
}

// LoopICmp
Lp_Icmp :: struct { pred: u8; iv: Scev_Id; limit: Scev_Id; }

Loop_Pred :: struct {
    aar: Aa_Results;
    dt: *Dom_Tree;
    li: *Loop_Info;
    mssau: *Mssa_Updater;
    l: Loop_Id;
    preheader: Value_Id;
    latch_check: Lp_Icmp;
}

// parseLoopICmp
lp_parse_loop_icmp :: (c: *Loop_Pred, ici: Value_Id) -> (bool, Lp_Icmp) {
    r: Lp_Icmp;
    pred := inst(ici).pred;
    lhss := sc_get_scev(op(ici, 0));
    if sc_is_cnc(lhss) return false, r;
    rhss := sc_get_scev(op(ici, 1));
    if sc_is_cnc(rhss) return false, r;
    if sc_is_loop_invariant(lhss, c.l) {
        lhss, rhss = rhss, lhss;
        pred = cmp_swapped(pred);
    }
    if !sc_is_addrec(lhss) || sc_loop(lhss) != c.l return false, r;
    r.pred = pred; r.iv = lhss; r.limit = rhss;
    return true, r;
}

// expandCheck
lp_expand_check :: (c: *Loop_Pred, x: *Scev_Expander, guard: Value_Id, pred: u8, lhs: Scev_Id, rhs: Scev_Id) -> Value_Id {
    ty := sc_type(lhs);
    if sc_is_loop_invariant(lhs, c.l) && sc_is_loop_invariant(rhs, c.l) {
        if sc_is_loop_entry_guarded_by_cond(c.l, pred, lhs, rhs) return const_int(type_int(1), 1);
        if sc_is_loop_entry_guarded_by_cond(c.l, cmp_inverse(pred), lhs, rhs) return const_int(type_int(1), 0);
    }
    lhsv := sx_expand_code_for_at(x, lhs, ty, lp_find_insert_pt_scev(c, x, guard, lhs));
    rhsv := sx_expand_code_for_at(x, rhs, ty, lp_find_insert_pt_scev(c, x, guard, rhs));
    b: Irb; irb_set_before(*b, lp_find_insert_pt(c, guard, .[lhsv, rhsv]));
    return irb_icmp(*b, pred, lhsv, rhsv);
}

// isSafeToTruncateWideIVType
lp_is_safe_to_truncate_wide_iv_type :: (latch: Lp_Icmp, range_check_type: Type_Id) -> bool {
    if !lp_cl.enable_iv_truncation return false;
    if !sc_is_const(latch.limit) || !sc_is_const(sc_start(latch.iv)) return false;
    if sc_get_monotonic_predicate_type(latch.iv, latch.pred) == .NONE return false;
    bits := sc_type_bits(range_check_type);
    return ap_active_bits(sc_ap(sc_start(latch.iv))) < bits && ap_active_bits(sc_ap(latch.limit)) < bits;
}

// generateLoopLatchCheck
lp_generate_loop_latch_check :: (latch: Lp_Icmp, range_check_type: Type_Id) -> (bool, Lp_Icmp) {
    latch_type := sc_type(latch.iv);
    if range_check_type == latch_type return true, latch;
    if sc_type_bits(latch_type) < sc_type_bits(range_check_type) return false, latch;
    if !lp_is_safe_to_truncate_wide_iv_type(latch, range_check_type) return false, latch;
    n: Lp_Icmp;
    n.pred = latch.pred;
    t := sc_get_truncate(latch.iv, range_check_type);
    if !sc_is_addrec(t) return false, latch;
    n.iv = t;
    n.limit = sc_get_truncate(latch.limit, range_check_type);
    return true, n;
}

// isSupportedStep
lp_is_supported_step :: (step: Scev_Id) -> bool {
    return sc_is_one(step) || (sc_is_all_ones(step) && lp_cl.enable_count_down_loop);
}

// findInsertPt(Instruction *Use, ArrayRef<Value*> Ops)
lp_find_insert_pt :: (c: *Loop_Pred, use: Value_Id, ops: [] Value_Id) -> Value_Id {
    for ops if !li_is_loop_invariant(c.li, c.l, it) return use;
    return block_terminator(c.preheader);
}
// findInsertPt(const SCEVExpander &Expander, Instruction *Use, ArrayRef<const SCEV *> Ops)
lp_find_insert_pt_scev :: (c: *Loop_Pred, x: *Scev_Expander, use: Value_Id, s: Scev_Id) -> Value_Id {
    if !sc_is_loop_invariant(s, c.l) || !sx_is_safe_to_expand_at(x, s, block_terminator(c.preheader)) return use;
    return block_terminator(c.preheader);
}

// isLoopInvariantValue
lp_is_loop_invariant_value :: (c: *Loop_Pred, s: Scev_Id) -> bool {
    if sc_is_loop_invariant(s, c.l) return true;
    if sc_is_unknown(s) {
        v := sc_value(s);
        if is_inst(v) && inst_op(v) == .LOAD && is_unordered(v) && li_has_loop_invariant_operands(c.li, c.l, v) {
            q := aa_query_new(*c.aar);
            if (aa_mod_ref_mask(q, mloc_before_or_after(op(v, 0))) & MR_MOD) == 0 return true;
            if get_metadata(v, md_kind_id("invariant.load")) != NONE return true;
        }
    }
    return false;
}

// widenICmpRangeCheckIncrementingLoop / widenICmpRangeCheckDecrementingLoop
lp_widen_icmp_range_check_loop :: (c: *Loop_Pred, latch: Lp_Icmp, range: Lp_Icmp, x: *Scev_Expander, guard: Value_Id, decrementing: bool) -> Value_Id {
    ty := sc_type(range.iv);
    guard_start := sc_start(range.iv);
    guard_limit := range.limit;
    latch_start := sc_start(latch.iv);
    latch_limit := latch.limit;
    if !lp_is_loop_invariant_value(c, guard_start) || !lp_is_loop_invariant_value(c, guard_limit) ||
       !lp_is_loop_invariant_value(c, latch_start) || !lp_is_loop_invariant_value(c, latch_limit) return NONE;
    if !sx_is_safe_to_expand_at(x, latch_start, guard) || !sx_is_safe_to_expand_at(x, latch_limit, guard) return NONE;
    limit_check, first_iteration_check: Value_Id;
    limit_check_pred := cmp_flipped_strictness(latch.pred);
    if !decrementing {
        // guardLimit - guardStart + latchStart - 1
        rhs := sc_get_add2(sc_get_minus(guard_limit, guard_start), sc_get_minus(latch_start, sc_get_one(ty)));
        limit_check = lp_expand_check(c, x, guard, limit_check_pred, latch_limit, rhs);
        first_iteration_check = lp_expand_check(c, x, guard, range.pred, guard_start, guard_limit);
    } else {
        post_dec := sc_get_post_inc_expr(latch.iv);
        if range.iv != post_dec return NONE;
        first_iteration_check = lp_expand_check(c, x, guard, ICMP_ULT, guard_start, guard_limit);
        limit_check = lp_expand_check(c, x, guard, limit_check_pred, latch_limit, sc_get_one(ty));
    }
    b: Irb; irb_set_before(*b, lp_find_insert_pt(c, guard, .[first_iteration_check, limit_check]));
    return irb_freeze(*b, gu_irb_and(*b, first_iteration_check, limit_check));
}

// normalizePredicate
lp_normalize_predicate :: (rc: *Lp_Icmp) {
    if icmp_is_equality(rc.pred) && sc_is_one(sc_step_recurrence(rc.iv)) &&
       sc_is_known_predicate(ICMP_ULE, sc_start(rc.iv), rc.limit)
        rc.pred = cast(u8) (ifx rc.pred == ICMP_NE then ICMP_ULT else ICMP_UGE);
}

// widenICmpRangeCheck: NONE = std::nullopt
lp_widen_icmp_range_check :: (c: *Loop_Pred, ici: Value_Id, x: *Scev_Expander, guard: Value_Id) -> Value_Id {
    ok, range := lp_parse_loop_icmp(c, ici);
    if !ok return NONE;
    if range.pred != ICMP_ULT return NONE;
    if !sc_is_affine(range.iv) return NONE;
    step := sc_step_recurrence(range.iv);
    if !lp_is_supported_step(step) return NONE;
    ty := sc_type(range.iv);
    ok2, cur := lp_generate_loop_latch_check(c.latch_check, ty);
    if !ok2 return NONE;
    if step != sc_step_recurrence(cur.iv) return NONE;
    return lp_widen_icmp_range_check_loop(c, cur, range, x, guard, !sc_is_one(step));
}

// widenChecks
lp_widen_checks :: (c: *Loop_Pred, checks: *[..] Value_Id, widened: *[..] Value_Id, x: *Scev_Expander, guard: Value_Id) {
    for * check: checks.* {
        if !is_inst(check.*) || inst_op(check.*) != .ICMP continue;
        n := lp_widen_icmp_range_check(c, check.*, x, guard);
        if n != NONE {
            array_add(widened, check.*);
            check.* = n;
        }
    }
}

// widenGuardConditions
lp_widen_guard_conditions :: (c: *Loop_Pred, guard: Value_Id, x: *Scev_Expander) -> bool {
    checks: [..] Value_Id; checks.allocator = temp;
    widened: [..] Value_Id; widened.allocator = temp;
    gu_parse_widenable_guard(guard, *checks);
    lp_widen_checks(c, *checks, *widened, x, guard);
    if widened.count == 0 return false;
    b: Irb; irb_set_before(*b, lp_find_insert_pt(c, guard, checks));
    all := gu_irb_and_list(*b, checks);
    old_cond := op(guard, 0);
    set_op(guard, 0, all);
    if lp_cl.insert_assumes_of_predicated_guards_conditions {
        irb_set_before(*b, inst_next(guard));
        irb_assumption(*b, old_cond);
    }
    ivs_recursively_delete_trivially_dead(old_cond, c.mssau);
    return true;
}

// widenWidenableBranchGuardConditions
lp_widen_widenable_branch_guard_conditions :: (c: *Loop_Pred, bi: Value_Id, x: *Scev_Expander) -> bool {
    checks: [..] Value_Id; checks.allocator = temp;
    widened: [..] Value_Id; widened.allocator = temp;
    gu_parse_widenable_guard(bi, *checks);
    wc := gu_extract_widenable_condition(bi);
    array_add(*checks, wc);
    lp_widen_checks(c, *checks, *widened, x, bi);
    if widened.count == 0 return false;
    b: Irb; irb_set_before(*b, lp_find_insert_pt(c, bi, checks));
    all := gu_irb_and_list(*b, checks);
    old_cond := op(bi, 0);
    set_op(bi, 0, all);
    if lp_cl.insert_assumes_of_predicated_guards_conditions {
        if_true := get_successor(bi, 0);
        irb_set_at(*b, if_true, block_first_insertion_pt(if_true), true);
        assume_cond := gu_irb_and_list(*b, widened);
        if block_unique_predecessor(if_true) == NONE {
            guard_bb := inst_block(bi);
            preds: [..] Value_Id; preds.allocator = temp;
            block_predecessors(if_true, *preds);
            pn := irb_phi(*b, vtype(assume_cond), cast(u32) preds.count, "assume.cond");
            for p: preds phi_add_incoming(pn, ifx p == guard_bb then assume_cond else const_int(type_int(1), 1), p);
            assume_cond = pn;
        }
        irb_assumption(*b, assume_cond);
    }
    ivs_recursively_delete_trivially_dead(old_cond, c.mssau);
    return true;
}

// parseLoopLatchICmp
lp_parse_loop_latch_icmp :: (c: *Loop_Pred) -> (bool, Lp_Icmp) {
    r: Lp_Icmp;
    latch := li_loop_latch(c.li, c.l);
    if latch == NONE return false, r;
    bi := block_terminator(latch);
    if inst_op(bi) != .CONDBR return false, r;
    true_dest := get_successor(bi, 0);
    ici := op(bi, 0);
    if !is_inst(ici) || inst_op(ici) != .ICMP return false, r;
    ok: bool;
    ok, r = lp_parse_loop_icmp(c, ici);
    if !ok return false, r;
    if true_dest != li_header(c.li, c.l) r.pred = cmp_inverse(r.pred);
    if !sc_is_affine(r.iv) return false, r;
    step := sc_step_recurrence(r.iv);
    if !lp_is_supported_step(step) return false, r;
    lp_normalize_predicate(*r);
    p := r.pred;
    unsupported: bool;
    if sc_is_one(step) unsupported = p != ICMP_ULT && p != ICMP_SLT && p != ICMP_ULE && p != ICMP_SLE;
    else unsupported = p != ICMP_UGT && p != ICMP_SGT && p != ICMP_UGE && p != ICMP_SGE;
    if unsupported return false, r;
    return true, r;
}

// isLoopProfitableToPredicate
lp_is_loop_profitable_to_predicate :: (c: *Loop_Pred) -> bool {
    if lp_cl.skip_profitability_checks return true;
    // L->getExitEdges
    Edge :: struct { from: Value_Id; to: Value_Id; }
    exit_edges: [..] Edge; exit_edges.allocator = temp;
    for b: li_blocks(c.li, c.l) {
        t := block_terminator(b);
        n := num_successors(t);
        if n > 0 for k: 0..n - 1 {
            s := get_successor(t, k);
            if !li_contains(c.li, c.l, s) array_add(*exit_edges, .{b, s});
        }
    }
    if exit_edges.count == 1 return true;
    latch_block := li_loop_latch(c.li, c.l);
    latch_term := block_terminator(latch_block);
    latch_br_exit_idx: u32 = ifx get_successor(latch_term, 0) == li_header(c.li, c.l) then cast(u32) 1 else 0;
    latch_exit_block := get_successor(latch_term, latch_br_exit_idx);
    if inst_op(latch_term) == .UNREACHABLE || block_terminating_deoptimize_call(latch_exit_block) != NONE return false;
    if prof_valid_branch_weight_md(latch_term) == NONE return true;

    compute_branch_probability :: (exiting: Value_Id, exit_block: Value_Id) -> Bprob {
        term := block_terminator(exiting);
        num_succ := num_successors(term);
        md := prof_valid_branch_weight_md(term);
        if md != NONE {
            weights := prof_weights_of_md(md);
            numerator: u64 = 0; denominator: u64 = 0;
            for w, i: weights {
                w32 := cast(u64) cast,trunc(u32) w;   // SmallVector<uint32_t> Weights
                if get_successor(term, cast(u32) i) == exit_block numerator += w32;
                denominator += w32;
            }
            if denominator == 0 return bprob_get(1, num_succ);
            return bprob_get(numerator, denominator);
        }
        return bprob_get(1, num_succ);
    }
    latch_exit_probability := compute_branch_probability(latch_block, latch_exit_block);
    scale_factor := lp_cl.latch_exit_probability_scale;
    if scale_factor < 1 scale_factor = 1.0;
    // BranchProbability * float: the float converts to uint32_t (operator*(uint32_t)), so 1.9 scales by 1
    rhs := cast(u32) scale_factor;
    threshold: Bprob = ifx cast(u64) latch_exit_probability * rhs > BPROB_D then BPROB_D else latch_exit_probability * rhs;
    for e: exit_edges {
        p := compute_branch_probability(e.from, e.to);
        if p > threshold return false;
    }
    return true;
}

// FindWidenableTerminatorAboveLoop
lp_find_widenable_terminator_above_loop :: (c: *Loop_Pred, l: Loop_Id) -> Value_Id {
    bb := li_loop_preheader(c.li, l);
    if bb == NONE return NONE;
    while true {
        pred := block_single_predecessor(bb);
        if pred != NONE && bb == block_single_successor(pred) { bb = pred; continue; }
        break;
    }
    pred := block_single_predecessor(bb);
    if pred != NONE {
        bi := block_terminator(pred);
        if inst_op(bi) == .CONDBR && get_successor(bi, 0) == bb && gu_is_widenable_branch(bi) return bi;
    }
    return NONE;
}

// getMinAnalyzeableBackedgeTakenCount
lp_get_min_analyzeable_backedge_taken_count :: (c: *Loop_Pred, l: Loop_Id) -> Scev_Id {
    exiting: [..] Value_Id; exiting.allocator = temp;
    li_exiting_blocks(c.li, l, *exiting);
    counts: [..] Scev_Id; counts.allocator = temp;
    for exiting {
        ec := sc_get_exit_count(l, it);
        if sc_is_cnc(ec) continue;
        array_add(*counts, ec);
    }
    if counts.count < 2 return SCEV_CNC;
    return sc_get_umin_from_mismatched_types(*counts);
}

// predicateLoopExits
lp_predicate_loop_exits :: (c: *Loop_Pred, l: Loop_Id, x: *Scev_Expander) -> bool {
    exiting: [..] Value_Id; exiting.allocator = temp;
    li_exiting_blocks(c.li, l, *exiting);
    if exiting.count == 0 return false;
    latch := li_loop_latch(c.li, l);
    if latch == NONE return false;
    widenable_br := lp_find_widenable_terminator_above_loop(c, l);
    if widenable_br == NONE return false;
    latch_ec := sc_get_exit_count(l, latch);
    if sc_is_cnc(latch_ec) return false;
    changed_loop := false;
    for exiting_bb: exiting {
        if li_loop_for(c.li, exiting_bb) != l continue;
        bi := block_terminator(exiting_bb);
        if inst_op(bi) != .CONDBR continue;
        wc := gu_extract_widenable_condition(bi);
        if wc != NONE && li_contains(c.li, l, get_successor(bi, 0)) {
            user := ir.u_user[ir.v_first_use[wc]];   // WC->user_back()
            replace_uses_of_with(user, wc, const_int(type_int(1), 1));
            changed_loop = true;
        }
    }
    if changed_loop sc_forget_loop(l);
    ip := op(widenable_br, 0);
    min_ec := lp_get_min_analyzeable_backedge_taken_count(c, l);
    if sc_is_cnc(min_ec) || is_ptr_type(sc_type(min_ec)) || !sc_is_loop_invariant(min_ec, l) ||
       !sx_is_safe_to_expand_at(x, min_ec, ip) return changed_loop;
    sx_set_insert_point(x, ip);
    b: Irb; irb_set_before(*b, ip);
    invalidate_loop := false;
    min_ecv: Value_Id = NONE;
    for exiting_bb: exiting {
        if li_loop_for(c.li, exiting_bb) != l continue;
        bi := block_terminator(exiting_bb);
        if inst_op(bi) != .CONDBR continue;
        if is_constant_kind(vkind(op(bi, 0))) continue;
        ec := sc_get_exit_count(l, exiting_bb);
        if sc_is_cnc(ec) || is_ptr_type(sc_type(ec)) || !sx_is_safe_to_expand_at(x, ec, widenable_br) continue;
        exit_if_true := !li_contains(c.li, l, get_successor(bi, 0));
        exit_bb := get_successor(bi, ifx exit_if_true then cast(u32) 0 else 1);
        if block_postdominating_deoptimize_call(exit_bb) == NONE continue;
        ecv := sx_expand_code_for(x, ec);
        if min_ecv == NONE min_ecv = sx_expand_code_for(x, min_ec);
        rhs := min_ecv;
        if vtype(ecv) != vtype(rhs) {
            wider := sc_get_wider_type(vtype(ecv), vtype(rhs));
            ecv = irb_cast(*b, .ZEXT, ecv, wider);
            rhs = irb_cast(*b, .ZEXT, rhs, wider);
        }
        new_cond := irb_icmp(*b, ICMP_UGT, ecv, rhs);
        new_cond = irb_freeze(*b, new_cond);
        gu_widen_widenable_branch(widenable_br, new_cond);
        old_cond := op(bi, 0);
        set_op(bi, 0, const_int(vtype(old_cond), ifx exit_if_true then cast(u64) 0 else 1));
        invalidate_loop = true;
    }
    if invalidate_loop sc_forget_loop(l);
    return true;
}

// LoopPredication::runOnLoop
lp_run_on_loop :: (c: *Loop_Pred) -> bool {
    guard_decl := intrinsic_declaration_if_exists(IID_EXPERIMENTAL_GUARD);
    has_intrinsic_guards := guard_decl != NONE && has_uses(guard_decl);
    wc_decl := intrinsic_declaration_if_exists(IID_EXPERIMENTAL_WIDENABLE_CONDITION);
    has_widenable_conditions := lp_cl.predicate_widenable_branch_guards && wc_decl != NONE && has_uses(wc_decl);
    if !has_intrinsic_guards && !has_widenable_conditions return false;
    c.preheader = li_loop_preheader(c.li, c.l);
    if c.preheader == NONE return false;
    ok, lc := lp_parse_loop_latch_icmp(c);
    if !ok return false;
    c.latch_check = lc;
    if !lp_is_loop_profitable_to_predicate(c) return false;
    guards: [..] Value_Id; guards.allocator = temp;
    branches: [..] Value_Id; branches.allocator = temp;
    for bb: li_blocks(c.li, c.l) {
        for i: block_insts(bb) if gu_is_guard(i) array_add(*guards, i);
        t := block_terminator(bb);
        if lp_cl.predicate_widenable_branch_guards && gu_is_guard_as_widenable_branch(t) array_add(*branches, t);
    }
    x: Scev_Expander;
    sx_init(*x, "loop-predication");
    changed := false;
    for guards changed |= lp_widen_guard_conditions(c, it, *x);
    for branches changed |= lp_widen_widenable_branch_guard_conditions(c, it, *x);
    changed |= lp_predicate_loop_exits(c, c.l, *x);
    return changed;
}

// LoopPredicationPass::run
loop_predication_run :: (node: *Pass_Node, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved {
    se = lar.se;
    c: Loop_Pred;
    c.aar = aa_results_for(lar.fn);
    c.dt = lar.dt; c.li = lar.li; c.l = l;
    mssau_storage: Mssa_Updater;
    if lar.mssa { mssau_storage.mssa = lar.mssa; c.mssau = *mssau_storage; }
    if !lp_run_on_loop(*c) return PRESERVE_ALL;
    pa := loop_pass_preserved();
    if lar.mssa preserve(*pa, .MEMORYSSA);
    return pa;
}
