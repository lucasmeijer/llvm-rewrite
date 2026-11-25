// LoopBoundSplit (loop-bound-split): port of llvm/lib/Transforms/Scalar/LoopBoundSplit.cpp. A loop with a branch on
// `iv < bound` (monotonic IV) is split into a first loop running up to min(exit bound, bound), where the branch is
// always true, and a cloned post-loop for the rest, where it is always false.

// ConditionInfo
Lbs_Cond :: struct {
    bi: Value_Id = NONE;
    icmp: Value_Id = NONE;
    pred: u8 = 0xFF;   // BAD_ICMP_PREDICATE
    add_rec_value: Value_Id = NONE;
    non_phi_add_rec_value: Value_Id = NONE;
    bound_value: Value_Id = NONE;
    add_rec_scev: Scev_Id = SCEV_NULL;   // SCEV_NULL: not an add recurrence
    bound_scev: Scev_Id = SCEV_NULL;
}

// analyzeICmp
lbs_analyze_icmp :: (li: *Loop_Info, l: Loop_Id, icmp: Value_Id, c: *Lbs_Cond) {
    c.icmp = icmp;
    c.pred = inst(icmp).pred;
    c.add_rec_value = op(icmp, 0);
    c.bound_value = op(icmp, 1);
    add_rec := sc_get_scev(c.add_rec_value);
    bound := sc_get_scev(c.bound_value);
    if !sc_is_addrec(add_rec) && sc_is_addrec(bound) {
        c.add_rec_value, c.bound_value = c.bound_value, c.add_rec_value;
        add_rec, bound = bound, add_rec;
        c.pred = cmp_swapped(c.pred);
    }
    c.add_rec_scev = ifx sc_is_addrec(add_rec) then add_rec else SCEV_NULL;
    c.bound_scev = bound;
    c.non_phi_add_rec_value = c.add_rec_value;
    if c.add_rec_scev != SCEV_NULL && is_inst(c.add_rec_value) && inst_op(c.add_rec_value) == .PHI
        c.non_phi_add_rec_value = phi_incoming_value_for_block(c.add_rec_value, li_loop_latch(li, l));
}

// calculateUpperBound
lbs_calculate_upper_bound :: (l: Loop_Id, c: *Lbs_Cond, is_exit_cond: bool) -> bool {
    if is_exit_cond {
        ec := sc_get_exit_count(l, inst_block(c.icmp));
        if sc_is_cnc(ec) return false;
        c.bound_scev = ec;
        return true;
    }
    if c.pred == ICMP_SLT || c.pred == ICMP_ULT return true;
    if c.pred != ICMP_ULE && c.pred != ICMP_SLE return false;
    ty := sc_type(c.bound_scev);
    if type_kind(ty) == .INT {
        bw := type_bits(ty);
        signed := icmp_is_signed(c.pred);
        mx := ifx signed then ap_signed_max(bw) else ap_all_ones(bw);
        pred: u8 = cast(u8) (ifx signed then ICMP_SLT else ICMP_ULT);
        if sc_is_known_predicate(pred, c.bound_scev, sc_get_constant(mx)) {
            c.bound_scev = sc_get_add2(c.bound_scev, sc_get_one(ty));
            c.pred = pred;
            return true;
        }
    }
    return false;
}

// hasProcessableCondition
lbs_has_processable_condition :: (li: *Loop_Info, l: Loop_Id, icmp: Value_Id, c: *Lbs_Cond, is_exit_cond: bool) -> bool {
    lbs_analyze_icmp(li, l, icmp, c);
    if !sc_is_available_at_loop_entry(c.bound_scev, l) return false;
    if c.add_rec_scev == SCEV_NULL return false;
    if !sc_is_affine(c.add_rec_scev) return false;
    step := sc_step_recurrence(c.add_rec_scev);
    if !sc_is_const(step) return false;
    sv := sc_ap(step);
    if ap_is_negative(sv) || ap_is_zero(sv) return false;
    if !lbs_calculate_upper_bound(l, c, is_exit_cond) return false;
    return true;
}

// isProcessableCondBI
lbs_is_processable_cond_bi :: (bi: Value_Id) -> bool {
    if inst_op(bi) != .CONDBR return false;
    cond := op(bi, 0);
    if !is_inst(cond) || inst_op(cond) != .ICMP return false;
    if !sc_is_scevable(vtype(op(cond, 0))) return false;
    if get_successor(bi, 0) == get_successor(bi, 1) return false;
    return true;
}

// canSplitLoopBound
lbs_can_split_loop_bound :: (li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree, c: *Lbs_Cond) -> bool {
    if fn_has_opt_size(li.fn) return false;
    if li_subloops(li, l).count != 0 return false;
    if !li_is_loop_simplify_form(li, l) return false;
    if !li_is_lcssa_form(li, l, dt) return false;
    if !li_is_safe_to_clone(li, l) return false;
    exiting := li_exiting_block(li, l);
    if exiting == NONE return false;
    bi := block_terminator(exiting);
    if inst_op(bi) != .CONDBR return false;
    if !lbs_is_processable_cond_bi(bi) return false;
    if !lbs_has_processable_condition(li, l, op(bi, 0), c, true) return false;
    c.bi = bi;
    return true;
}

// isProfitableToTransform
lbs_is_profitable_to_transform :: (bi: Value_Id) -> bool {
    s0 := block_single_successor(get_successor(bi, 0));
    s1 := block_single_successor(get_successor(bi, 1));
    if s0 == NONE || s1 == NONE || s0 != s1 return false;
    return true;
}

// findSplitCandidate
lbs_find_split_candidate :: (li: *Loop_Info, l: Loop_Id, exiting: *Lbs_Cond, split: *Lbs_Cond) -> Value_Id {
    for bb: li_blocks(li, l) {
        if li_loop_latch(li, l) == bb continue;
        bi := block_terminator(bb);
        if inst_op(bi) != .CONDBR continue;
        if !lbs_is_processable_cond_bi(bi) continue;
        if li_is_loop_invariant(li, l, op(bi, 0)) continue;
        if !lbs_has_processable_condition(li, l, op(bi, 0), split, false) continue;
        if sc_type(exiting.bound_scev) != sc_type(split.bound_scev) continue;
        if !sc_is_loop_entry_guarded_by_cond(l, split.pred, sc_start(split.add_rec_scev), split.bound_scev) continue;
        split.bi = bi;
        return bi;
    }
    return NONE;
}

// splitLoopBound
lbs_split_loop_bound :: (li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree, u: *Lpm_Updater) -> bool {
    split_cond: Lbs_Cond;
    exiting_cond: Lbs_Cond;
    if !lbs_can_split_loop_bound(li, l, dt, *exiting_cond) return false;
    if lbs_find_split_candidate(li, l, *exiting_cond, *split_cond) == NONE return false;
    if !lbs_is_profitable_to_transform(split_cond.bi) return false;

    post_blocks: [..] Value_Id; post_blocks.allocator = temp;
    vm: Value_Map; vmap_init(*vm);
    pre_header := li_loop_preheader(li, l);
    split_loop_ph := split_edge(pre_header, li_header(li, l), dt, li);
    post_loop := clone_loop_with_preheader(li_exit_block(li, l), split_loop_ph, l, *vm, ".split", li, dt, *post_blocks);
    remap_instructions_in_blocks(post_blocks, *vm);
    post_ph := li_loop_preheader(li, post_loop);
    b: Irb; irb_set_before(*b, block_first(post_ph));
    if li_exit_block(li, l) == get_successor(exiting_cond.bi, 0) set_successor(exiting_cond.bi, 0, post_ph);
    else set_successor(exiting_cond.bi, 1, post_ph);
    dt_change_idom(dt, post_ph, li_exiting_block(li, l));

    is_exiting_latch := li_exiting_block(li, l) == li_loop_latch(li, l);
    exiting_cond_lcssa_phi: Value_Id = NONE;
    for pn: block_insts(li_header(li, l)) {
        if inst_op(pn) != .PHI break;
        lp := irb_phi(*b, vtype(pn), 1, tconcat(vname(pn), ".lcssa"));
        set_metadata(lp, 0, get_metadata(pn, 0));
        phi_add_incoming(lp, ifx is_exiting_latch then phi_incoming_value_for_block(pn, li_loop_latch(li, l)) else pn, li_exiting_block(li, l));
        post_pn := vmap_get(*vm, pn);
        phi_set_incoming_value_for_block(post_pn, post_ph, lp);
        if !sc_is_scevable(vtype(pn)) continue;
        if sc_is_addrec(sc_get_scev(pn)) && exiting_cond.non_phi_add_rec_value == phi_incoming_value_for_block(pn, li_loop_latch(li, l))
            exiting_cond_lcssa_phi = lp;
    }
    orig_bi := block_terminator(post_ph);
    if exiting_cond_lcssa_phi == NONE fatal("loop-bound-split: no LCSSA phi for the exiting condition's IV (LLVM builds an icmp on a null value)");
    cond := irb_icmp(*b, ICMP_NE, exiting_cond_lcssa_phi, exiting_cond.bound_value);
    irb_cond_br(*b, cond, li_header(li, post_loop), li_exit_block(li, post_loop));
    erase_inst_with_metadata(orig_bi);
    dt_change_idom(dt, li_exit_block(li, post_loop), post_ph);

    new_bound := exiting_cond.bound_scev;
    split_bound := split_cond.bound_scev;
    new_bound = ifx icmp_is_signed(exiting_cond.pred) then sc_get_smin2(new_bound, split_bound) else sc_get_umin2(new_bound, split_bound);
    x: Scev_Expander; sx_init(*x, "split");
    nbv := sx_expand_code_for_at(*x, new_bound, sc_type(new_bound), block_terminator(split_loop_ph));
    set_name(nbv, "new.bound");
    set_op(exiting_cond.icmp, 1, nbv);
    set_op(split_cond.bi, 0, const_int(type_int(1), 1));
    cloned_split_bi := vmap_get(*vm, split_cond.bi);
    set_op(cloned_split_bi, 0, const_int(type_int(1), 0));

    irb_set_at(*b, post_ph, block_first(post_ph), true);
    exiting_block := li_exiting_block(li, l);
    for pn: block_insts(li_exit_block(li, post_loop)) {
        if inst_op(pn) != .PHI break;
        n := nops(pn);
        for i: 0..cast(s64) n - 1 {
            k := cast(u32) i;
            if phi_block(pn, k) != exiting_block continue;
            incoming := phi_value(pn, k);
            lp := irb_phi(*b, vtype(pn), 1, tconcat(vname(pn), ".lcssa"));
            set_metadata(lp, 0, get_metadata(pn, 0));
            phi_add_incoming(lp, incoming, phi_block(pn, k));
            phi_set_block(pn, k, post_ph);
            phi_set_value(pn, k, lp);
            mapped := vmap_get(*vm, incoming);
            if mapped == NONE fatal("loop-bound-split: an exit phi's incoming value has no clone (LLVM adds a null incoming value)");
            phi_add_incoming(pn, mapped, li_exiting_block(li, post_loop));
        }
    }
    sc_forget_loop(l);
    simplify_loop(li, l, dt, null, null, true);
    simplify_loop(li, post_loop, dt, null, null, true);
    if u lpm_add_sibling_loops(u, li, .[post_loop]);
    return true;
}

// LoopBoundSplitPass::run
loop_bound_split_run :: (node: *Pass_Node, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved {
    se = lar.se;
    if !lbs_split_loop_bound(lar.li, l, lar.dt, u) return PRESERVE_ALL;
    return loop_pass_preserved();
}
