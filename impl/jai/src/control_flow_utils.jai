// ControlFlowHub: a port of llvm/lib/Transforms/Utils/ControlFlowUtils.cpp (complete), plus the helpers it and its
// users (UnifyLoopExits, FixIrreducible) need: invertCondition (llvm/lib/Transforms/Utils/Local.cpp) and
// SplitCallBrEdge / updateCycleLoopInfo (llvm/lib/Transforms/Utils/BasicBlockUtils.cpp), and the CycleInfo update
// methods (llvm/include/llvm/ADT/GenericCycleImpl.h: addBlockToCycle, getSmallestCommonCycle).

// ControlFlowHub::BranchDescriptor
Cfh_Branch :: struct { bb: Value_Id; succ0: Value_Id; succ1: Value_Id; }
Cfh :: struct { branches: [..] Cfh_Branch; }

cfh_add_branch :: (h: *Cfh, bb: Value_Id, succ0: Value_Id, succ1: Value_Id = NONE) {
    if !h.branches.allocator.proc h.branches.allocator = temp;
    array_add(*h.branches, .{bb, succ0, succ1});
}

// invertCondition
invert_condition :: (cond: Value_Id) -> Value_Id {
    k := vkind(cond);
    if k != .INST && k != .ARGUMENT return ce_not(cond);
    ok, nc := pm_not(cond);
    if ok return nc;
    parent: Value_Id = NONE;
    if k == .INST parent = inst_block(cond);
    else parent = fn_entry(arg_parent(cond));
    u := ir.v_first_use[cond];
    while u != NONE {
        user := ir.u_user[u];
        if is_inst(user) && inst_block(user) == parent {
            ok2, x := pm_not(user);
            if ok2 && x == cond return user;
        }
        u = ir.u_next[u];
    }
    inv := create_not(cond);
    if k == .INST && inst_op(cond) != .PHI {
        inst_insert_after(inv, cond);
    } else {
        insert_at_position(inv, parent, block_first_insertion_pt(parent), true);
    }
    set_name(inv, tconcat(vname(cond), ".inv"));
    return inv;
}

// redirectToHub
cfh_redirect_to_hub :: (bb: Value_Id, succ0: Value_Id, succ1: Value_Id, first_guard_block: Value_Id) -> Value_Id {
    t := block_terminator(bb);
    if inst_op(t) == .BR {
        set_successor(t, 0, first_guard_block);
        return NONE;
    }
    if inst_op(t) != .CONDBR fatal("ControlFlowHub: unsupported terminator '%'", opcode_name(inst_op(t)));
    cond := op(t, 0);
    if succ0 != NONE && succ1 == NONE {
        set_successor(t, 0, first_guard_block);
    } else if succ1 != NONE && succ0 == NONE {
        set_successor(t, 1, first_guard_block);
    } else {
        drop_all_references(t);
        erase_inst(t);
        block_append_inst(bb, create_br(first_guard_block));
    }
    return cond;
}

// GuardPredicates: Outgoing[i] -> predicate (Outgoing is a SetVector, so the index identifies the block)
cfh_setup_branch_for_guard :: (guard_blocks: [] Value_Id, outgoing: [] Value_Id, preds: [] Value_Id) {
    i := 0;
    e := guard_blocks.count - 1;
    while i != e {
        block_append_inst(guard_blocks[i], create_cond_br(preds[i], outgoing[i], guard_blocks[i + 1]));
        i += 1;
    }
    block_append_inst(guard_blocks[i], create_cond_br(preds[i], outgoing[i], outgoing[i + 1]));
}

cfh_index_of :: (outgoing: [] Value_Id, b: Value_Id) -> s64 {
    for outgoing if it == b return it_index;
    return outgoing.count;
}

// calcPredicateUsingInteger
cfh_calc_predicate_using_integer :: (branches: [] Cfh_Branch, outgoing: [] Value_Id, guard_blocks: [] Value_Id, preds: [] Value_Id) {
    first_guard_block := guard_blocks[0];
    i32 := type_int(cast(u64) 32);
    phi := create_phi(i32, cast(u32) branches.count);
    insert_at_end_named(phi, first_guard_block, "merged.bb.idx");
    for br: branches {
        cond := cfh_redirect_to_hub(br.bb, br.succ0, br.succ1, first_guard_block);
        incoming_id: Value_Id;
        if br.succ0 != NONE && br.succ1 != NONE && br.succ0 != br.succ1 {
            id0 := const_int(i32, cast(u64) cfh_index_of(outgoing, br.succ0));
            id1 := const_int(i32, cast(u64) cfh_index_of(outgoing, br.succ1));
            sel := create_select(cond, id0, id1);
            insert_at_position(sel, br.bb, block_terminator(br.bb), false);
            set_name(sel, "target.bb.idx");
            incoming_id = sel;
        } else {
            s := ifx br.succ0 != NONE then br.succ0 else br.succ1;
            incoming_id = const_int(i32, cast(u64) cfh_index_of(outgoing, s));
        }
        phi_add_incoming(phi, incoming_id, br.bb);
    }
    for i: 0..outgoing.count - 2 {
        o := outgoing[i];
        cmp := create_icmp(ICMP_EQ, phi, const_int(i32, cast(u64) i));
        insert_at_end_named(cmp, guard_blocks[i], tconcat(vname(o), ".predicate"));
        preds[i] = cmp;
    }
}

// calcPredicateUsingBooleans
cfh_calc_predicate_using_booleans :: (branches: [] Cfh_Branch, outgoing: [] Value_Id, guard_blocks: [] Value_Id,
                                      preds: [] Value_Id, deletion_candidates: *[..] Value_Id) {
    bool_true := const_int(ir.t_i1, 1);
    bool_false := const_int(ir.t_i1, 0);
    first_guard_block := guard_blocks[0];
    for i: 0..outgoing.count - 2 {
        o := outgoing[i];
        phi := create_phi(ir.t_i1, cast(u32) branches.count);
        insert_at_end_named(phi, first_guard_block, tconcat("Guard.", vname(o)));
        preds[i] = phi;
    }
    for br: branches {
        cond := cfh_redirect_to_hub(br.bb, br.succ0, br.succ1, first_guard_block);
        one_successor_done := false;
        for i: 0..outgoing.count - 2 {
            o := outgoing[i];
            phi := preds[i];
            if o != br.succ0 && o != br.succ1 {
                phi_add_incoming(phi, bool_false, br.bb);
            } else if br.succ0 == NONE || br.succ1 == NONE || br.succ0 == br.succ1 || one_successor_done {
                phi_add_incoming(phi, bool_true, br.bb);
            } else {
                if o == br.succ0 {
                    phi_add_incoming(phi, cond, br.bb);
                } else {
                    inverted := invert_condition(cond);
                    array_add(deletion_candidates, cond);
                    phi_add_incoming(phi, inverted, br.bb);
                }
                one_successor_done = true;
            }
        }
    }
}

// reconnectPhis
cfh_reconnect_phis :: (out: Value_Id, guard_block: Value_Id, incoming: [] Cfh_Branch, first_guard_block: Value_Id) {
    i := block_first(out);
    while i != NONE && inst_op(i) == .PHI {
        phi := i;
        ty := vtype(phi);
        new_phi := create_phi(ty, cast(u32) incoming.count);
        insert_at_position(new_phi, first_guard_block, block_first(first_guard_block), true);
        set_name(new_phi, tconcat(vname(phi), ".moved"));
        all_undef := true;
        for br: incoming {
            v := const_poison(ty);
            if phi_block_index(phi, br.bb) != -1 {
                v = phi_remove_incoming_block(phi, br.bb, false);
                if br.succ0 != NONE && br.succ1 != NONE && br.succ0 == br.succ1 && phi_block_index(phi, br.bb) != -1
                    phi_remove_incoming_block(phi, br.bb, false);
                if br.bb == out v = new_phi;
                all_undef &= is_undef_value(v);
            }
            phi_add_incoming(new_phi, v, br.bb);
        }
        new_v := new_phi;
        if all_undef {
            erase_inst_with_metadata(new_phi);
            new_v = const_poison(ty);
        }
        if nops(phi) == 0 {
            nx := inst_next(phi);
            rauw_with_metadata(phi, new_v);
            erase_inst_with_metadata(phi);
            i = nx;
            continue;
        }
        phi_add_incoming(phi, new_v, guard_block);
        i = inst_next(i);
    }
}

// ControlFlowHub::finalize: returns (the first guard block, or the single outgoing block, and whether the CFG
// changed); `guard_blocks` receives the guard blocks. max_booleans < 0 = std::nullopt.
cfh_finalize :: (h: *Cfh, dt: *Dom_Tree, guard_blocks: *[..] Value_Id, prefix: string, max_booleans: s64 = -1) -> Value_Id, bool {
    outgoing: [..] Value_Id; outgoing.allocator = temp;
    add_unique :: (o: *[..] Value_Id, b: Value_Id) { for o.* if it == b return; array_add(o, b); }
    for h.branches {
        if it.succ0 != NONE add_unique(*outgoing, it.succ0);
        if it.succ1 != NONE add_unique(*outgoing, it.succ1);
    }
    assert(outgoing.count > 0, "No outgoing edges");
    if outgoing.count < 2 return outgoing[0], false;

    updates: [..] Dom_Update; updates.allocator = temp;
    if dt {
        for h.branches {
            if it.succ0 != NONE array_add(*updates, .{false, it.bb, it.succ0});
            if it.succ1 != NONE && it.succ1 != it.succ0 array_add(*updates, .{false, it.bb, it.succ1});
        }
    }
    deletion_candidates: [..] Value_Id; deletion_candidates.allocator = temp;

    // convertToGuardPredicates
    {
        f := block_fn(outgoing[0]);
        for 0..outgoing.count - 2 array_add(guard_blocks, create_block(f, tconcat(prefix, ".guard")));
        preds := NewArray(outgoing.count, Value_Id,, allocator = temp);
        if max_booleans < 0 || outgoing.count <= max_booleans
            cfh_calc_predicate_using_booleans(h.branches, outgoing, guard_blocks.*, preds, *deletion_candidates);
        else
            cfh_calc_predicate_using_integer(h.branches, outgoing, guard_blocks.*, preds);
        cfh_setup_branch_for_guard(guard_blocks.*, outgoing, preds);
    }

    first_guard_block := guard_blocks.*[0];
    for i: 0..guard_blocks.count - 1 cfh_reconnect_phis(outgoing[i], guard_blocks.*[i], h.branches, first_guard_block);
    cfh_reconnect_phis(outgoing[outgoing.count - 1], guard_blocks.*[guard_blocks.count - 1], h.branches, first_guard_block);

    if dt {
        num_guards := guard_blocks.count;
        for h.branches array_add(*updates, .{true, it.bb, first_guard_block});
        for i: 0..num_guards - 2 {
            array_add(*updates, .{true, guard_blocks.*[i], outgoing[i]});
            array_add(*updates, .{true, guard_blocks.*[i], guard_blocks.*[i + 1]});
        }
        array_add(*updates, .{true, guard_blocks.*[num_guards - 1], outgoing[num_guards - 1]});
        array_add(*updates, .{true, guard_blocks.*[num_guards - 1], outgoing[num_guards]});
        dt_apply_updates(dt, updates);
    }

    // WeakVH: a candidate erased by an earlier iteration is null
    for c: deletion_candidates {
        if vkind(c) != .INST continue;
        if has_uses(c) continue;
        erase_inst_with_metadata(c);
    }
    return first_guard_block, true;
}

// ---------------------------------------------------------------- CycleInfo updates (GenericCycleImpl.h)

// GenericCycleInfo::addBlockToCycle
ci_add_block_to_cycle :: (ci: *Cycle_Info, b: Value_Id, c: Cycle_Id) {
    add :: (r: *Cycle_Row, b: Value_Id) { for r.blocks if it == b return; array_add(*r.blocks, b); }   // SetVector::insert
    add(*ci.cycles[c], b);
    table_set(*ci.block_map, b, c);
    p := ci.cycles[c].parent;
    while p != NONE {
        add(*ci.cycles[p], b);
        p = ci.cycles[p].parent;
    }
}
// getSmallestCommonCycle(CycleT *A, CycleT *B)
ci_smallest_common_cycle :: (ci: *Cycle_Info, a_in: Cycle_Id, b_in: Cycle_Id) -> Cycle_Id {
    a := a_in; b := b_in;
    if a == NONE || b == NONE return NONE;
    while ci.cycles[a].depth > ci.cycles[b].depth a = ci.cycles[a].parent;
    while ci.cycles[b].depth > ci.cycles[a].depth b = ci.cycles[b].parent;
    while a != b { a = ci.cycles[a].parent; b = ci.cycles[b].parent; }
    return a;
}

// ---------------------------------------------------------------- SplitCallBrEdge (BasicBlockUtils.cpp)

// SplitCallBrEdge(CallBrBlock, Succ, SuccIdx, CallBrTarget, DTU (eager), CI, LI, UpdatedLI): returns the target
// block and *UpdatedLI
split_call_br_edge :: (callbr_block: Value_Id, succ: Value_Id, succ_idx: u32, callbr_target_in: Value_Id,
                       dt: *Dom_Tree, ci: *Cycle_Info, li: *Loop_Info) -> Value_Id, bool {
    callbr := block_terminator(callbr_block);
    assert(inst_op(callbr) == .CALLBR, "expected callbr terminator");
    updated_li := false;
    callbr_target := callbr_target_in;
    reuses := callbr_target != NONE;
    if !reuses {
        f := block_fn(callbr_block);
        callbr_target = create_block(f, tconcat(vname(callbr_block), ".target.", vname(succ)));
        block_append_inst(callbr_target, create_br(succ));
        for block_insts(succ) {
            if inst_op(it) != .PHI break;
            idx := phi_block_index(it, callbr_block);
            assert(idx != -1, "expected incoming value form callbr block");
            phi_set_block(it, cast(u32) idx, callbr_target);
        }
        // updateCycleLoopInfo<LoopInfo, Loop>
        if li {
            lc := li_smallest_common_loop(li, li_loop_for(li, callbr_block), li_loop_for(li, succ));
            if lc != NONE { li_add_basic_block_to_loop(li, lc, callbr_target); updated_li = true; }
        }
        // updateCycleLoopInfo<CycleInfo, Cycle>
        if ci {
            cc := ci_smallest_common_cycle(ci, ci_cycle_for(ci, callbr_block), ci_cycle_for(ci, succ));
            if cc != NONE ci_add_block_to_cycle(ci, callbr_target, cc);
        }
    } else {
        for :early_inc block_insts(succ) {
            if inst_op(it) != .PHI break;
            phi_remove_incoming_block(it, callbr_block, false);
        }
    }
    set_successor(callbr, succ_idx, callbr_target);
    if dt {
        if !reuses dt_apply_updates(dt, Dom_Update.[.{true, callbr_block, callbr_target}]);
        if dt_dominates(dt, callbr_block, succ) {
            if !succ_contains(callbr_block, succ) dt_apply_updates(dt, Dom_Update.[.{false, callbr_block, succ}]);
            if !reuses dt_apply_updates(dt, Dom_Update.[.{true, callbr_target, succ}]);
        }
    }
    return callbr_target, updated_li;
}
