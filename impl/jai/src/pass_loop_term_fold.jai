// LoopTermFold (loop-term-fold): port of llvm/lib/Transforms/Scalar/LoopTermFold.cpp (canFoldTermCondOfLoop,
// RunTermFold, LoopTermFoldPass::run). An almost-dead IV that only feeds the latch condition is replaced by a
// comparison of another affine IV against its value after the last iteration.

Term_Fold :: struct { to_fold: Value_Id; to_help_fold: Value_Id; term_value_s: Scev_Id; must_drop_poison: bool; }

// canFoldTermCondOfLoop
can_fold_term_cond_of_loop :: (l: Loop_Id, li: *Loop_Info, dt: *Dom_Tree, tti: *Tti) -> (bool, Term_Fold) {
    r: Term_Fold;
    if !li_is_innermost(li, l) return false, r;
    if !li_is_loop_simplify_form(li, l) return false, r;
    if !sc_has_loop_invariant_backedge_taken_count(l) return false, r;
    latch := li_loop_latch(li, l);
    bi := block_terminator(latch);
    if inst_op(bi) != .CONDBR return false, r;
    term_cond := op(bi, 0);
    if !is_inst(term_cond) || inst_op(term_cond) != .ICMP return false, r;
    if !has_one_use(term_cond) return false, r;
    lhs := op(term_cond, 0);
    rhs := op(term_cond, 1);
    if !is_binary_operator(lhs) || !li_is_loop_invariant(li, l, rhs) return false, r;
    // matchSimpleRecurrence(BinaryOperator *I, PHINode *&P, Value *&Start, Value *&Step)
    to_fold := op(lhs, 0);
    if !is_phi(to_fold) to_fold = op(lhs, 1);
    if !is_phi(to_fold) return false, r;
    {
        ok, bo, start, step := match_simple_recurrence(to_fold);
        if !ok || bo != lhs return false, r;
    }
    if inst_block(to_fold) != li_header(li, l) return false, r;
    if !is_almost_dead_iv(to_fold, latch, term_cond) return false, r;
    expansion_budget: u32;
    {
        budget := cast(u32) (2 * scev_cheap_expansion_budget);
        small_tc := sc_get_small_constant_max_trip_count(l);
        if small_tc expansion_budget = min(budget, small_tc);
        else {
            has, etc := li_loop_estimated_trip_count(li, l);
            expansion_budget = ifx has then min(budget, etc) else budget;
        }
    }
    be_count := sc_get_backedge_taken_count(l);
    expander: Scev_Expander;
    sx_init(*expander, "lsr_fold_term_cond");
    to_help_fold: Value_Id = NONE;
    term_value_s: Scev_Id = SCEV_NULL;
    must_drop_poison := false;
    insert_pt := block_terminator(li_loop_preheader(li, l));
    for pn: block_insts(li_header(li, l)) {
        if inst_op(pn) != .PHI break;
        if pn == to_fold continue;
        if !sc_is_scevable(vtype(pn)) continue;
        ar := sc_get_scev(pn);
        if sc_kind(ar) != .ADDREC || !sc_is_affine(ar) continue;
        if !sc_has_nw(ar) || !sc_is_known_non_zero(sc_step_recurrence(ar)) continue;
        post_inc := sc_get_post_inc_expr(ar);
        term_value_s_local := evaluate_at_iteration(post_inc, be_count);
        if !sx_is_safe_to_expand(*expander, term_value_s_local) continue;
        if sx_is_high_cost_expansion(*expander, .[term_value_s_local], l, cast(s64) expansion_budget, tti, insert_pt) continue;
        if !must_execute_ub_if_poison_on_path_to(pn, block_terminator(latch), dt) continue;
        must_drop_poison_local := false;
        post_inc_v := phi_incoming_value_for_block(pn, latch);
        if !must_execute_ub_if_poison_on_path_to(post_inc_v, block_terminator(latch), dt) {
            if op(post_inc_v, 0) != pn continue;
            must_drop_poison_local = has_poison_generating_flags(post_inc_v);
        }
        to_help_fold = pn;
        term_value_s = term_value_s_local;
        must_drop_poison = must_drop_poison_local;
    }
    sx_clear(*expander);
    if to_help_fold == NONE return false, r;
    r = .{to_fold, to_help_fold, term_value_s, must_drop_poison};
    return true, r;
}

// RunTermFold
run_term_fold :: (l: Loop_Id, li: *Loop_Info, dt: *Dom_Tree, tti: *Tti, mssau: *Mssa_Updater) -> bool {
    ok, t := can_fold_term_cond_of_loop(l, li, dt, tti);
    if !ok return false;
    preheader := li_loop_preheader(li, l);
    latch := li_loop_latch(li, l);
    loop_value := phi_incoming_value_for_block(t.to_help_fold, latch);
    if t.must_drop_poison drop_poison_generating_flags(loop_value);
    expander: Scev_Expander;
    sx_init(*expander, "lsr_fold_term_cond");
    term_value := sx_expand_code_for_at(*expander, t.term_value_s, vtype(t.to_help_fold), block_terminator(preheader));
    bi := block_terminator(latch);
    old_term_cond := op(bi, 0);
    b: Irb; irb_set_before(*b, bi);
    new_term_cond := irb_icmp(*b, ICMP_EQ, loop_value, term_value, "lsr_fold_term_cond.replaced_term_cond");
    if get_successor(bi, 0) == li_header(li, l) swap_successors(bi);
    set_op(bi, 0, new_term_cond);
    sx_clear(*expander);
    erase_inst_with_metadata(old_term_cond);
    ivs_delete_dead_phis(li_header(li, l), mssau);
    return true;
}

// LoopTermFoldPass::run
loop_term_fold_run :: (node: *Pass_Node, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved {
    se = lar.se;
    mssau_storage: Mssa_Updater;
    mssau: *Mssa_Updater = null;
    if lar.mssa { mssau_storage.mssa = lar.mssa; mssau = *mssau_storage; }
    changed := run_term_fold(l, lar.li, lar.dt, tti_get(lar.fn), mssau);
    vh_release_all();
    if !changed return PRESERVE_ALL;
    pa := loop_pass_preserved();
    if lar.mssa preserve(*pa, .MEMORYSSA);
    return pa;
}
