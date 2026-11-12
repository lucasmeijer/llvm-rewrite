// CanonicalizeFreezeInLoops (canon-freeze): port of llvm/lib/Transforms/Utils/CanonicalizeFreezeInLoops.cpp.
// Freezes of an induction PHI or its step instruction are pushed out of the loop: the start value and the step
// get frozen in the preheader, and the freeze in the loop is removed.

canon_freeze_insert_freeze_and_forget :: (l: Loop_Id, li: *Loop_Info, dt: *Dom_Tree, user: Value_Id, idx: u32) {
    ph := li_loop_preheader(li, l);
    v := op(user, idx);
    if is_guaranteed_not_to_be_undef_or_poison(v, null, user, dt) return;
    fr := new_inst(.FREEZE, vtype(v), 1);
    set_op(fr, 0, v);
    t := block_terminator(ph);
    insert_at_position(fr, ph, t, false);
    set_name(fr, tconcat(vname(v), ".frozen"));
    set_op(user, idx, fr);
    sc_forget_value(user);
}

// CanonicalizeFreezeInLoopsImpl::run
canon_freeze_impl :: (l: Loop_Id, li: *Loop_Info, dt: *Dom_Tree) -> bool {
    if !li_is_loop_simplify_form(li, l) return false;
    Info :: struct { fi: Value_Id; phi: Value_Id; step_inst: Value_Id; step_val_idx: u32; }
    candidates: [..] Info; candidates.allocator = temp;
    header := li_header(li, l);
    for phi: block_insts(header) {
        if inst_op(phi) != .PHI break;
        ok, start, step, bo := is_induction_phi(phi, l);
        if !ok continue;
        if !sc_is_const(step) && !sc_is_loop_invariant(step, l) continue;
        if phi_num_incoming(phi) != 2 continue;
        if bo == NONE continue;
        o := inst_op(bo);
        if o != .ADD && o != .SUB && o != .MUL continue;
        info := Info.{NONE, phi, bo, ifx op(bo, 0) == phi then cast(u32) 1 else 0};
        step_v := op(bo, info.step_val_idx);
        if is_inst(step_v) && li_contains(li, l, inst_block(step_v)) continue;
        visit :: (u: Value_Id, info: *Info, c: *[..] Info) {
            if !is_inst(u) || inst_op(u) != .FREEZE return;
            info.fi = u;
            for c.* if it.fi == u return;
            array_add(c, info.*);
        }
        for sx_users(phi) visit(it, *info, *candidates);
        for sx_users(bo) visit(it, *info, *candidates);
    }
    if candidates.count == 0 return false;
    processed: [..] Value_Id; processed.allocator = temp;
    for info: candidates {
        dup := false;
        for processed if it == info.phi dup = true;
        if dup continue;
        array_add(*processed, info.phi);
        step_i := info.step_inst;
        if !is_guaranteed_not_to_be_undef_or_poison(step_i, null, step_i, dt) {
            drop_poison_generating_flags(step_i);
            sc_forget_value(step_i);
        }
        canon_freeze_insert_freeze_and_forget(l, li, dt, step_i, info.step_val_idx);
        // PHI->getOperandNumForIncomingValue(PHI->getIncomingValue(0) == StepI)
        idx: u32 = ifx phi_value(info.phi, 0) == step_i then cast(u32) 1 else 0;
        canon_freeze_insert_freeze_and_forget(l, li, dt, info.phi, idx);
    }
    for info: candidates {
        fi := info.fi;
        sc_forget_value(fi);
        rauw_with_metadata(fi, op(fi, 0));
        erase_inst_with_metadata(fi);
    }
    return true;
}

// CanonicalizeFreezeInLoopsPass::run
canon_freeze_run :: (node: *Pass_Node, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved {
    se = lar.se;
    if !canon_freeze_impl(l, lar.li, lar.dt) return PRESERVE_ALL;
    return loop_pass_preserved();
}
