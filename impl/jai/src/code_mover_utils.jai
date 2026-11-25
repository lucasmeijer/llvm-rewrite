// CodeMoverUtils: port of llvm/lib/Transforms/Utils/CodeMoverUtils.cpp (isSafeToMoveBefore for an instruction and a
// block, moveInstructionsToTheBeginning / moveInstructionsToTheEnd, nonStrictlyPostDominate, isReachedBefore).
// Used by LoopFuse (pass_loop_fuse.jai).

// domTreeLevelBefore
cmu_dom_tree_level_before :: (dt: *Dom_Tree, a: Value_Id, b: Value_Id) -> bool {
    if inst_block(a) == inst_block(b) return comes_before(a, b);
    return dt_level(dt, dt_node(dt, inst_block(a))) < dt_level(dt, dt_node(dt, inst_block(b)));
}

// collectInstructionsInBetween: the instructions reachable from StartInst's successor without passing EndInst
// (the SmallPtrSet worklist's visiting order does not change the resulting set)
cmu_collect_instructions_in_between :: (start: Value_Id, end: Value_Id, out: *[..] Value_Id, seen: *Table(Value_Id, bool)) {
    work: [..] Value_Id; work.allocator = temp;
    next_insts :: (i: Value_Id, work: *[..] Value_Id) {
        nx := inst_next(i);
        if nx != NONE { array_add(work, nx); return; }
        t := i;
        n := num_successors(t);
        if n > 0 for k: 0..n - 1 array_add(work, block_first(get_successor(t, k)));
    }
    next_insts(start, *work);
    while work.count {
        cur := pop(*work);
        if cur == end continue;
        if table_contains(seen, cur) continue;
        table_set(seen, cur, true);
        array_add(out, cur);
        next_insts(cur, *work);
    }
}

// isSafeToMoveBefore(Instruction &I, Instruction &InsertPoint, DT, PDT, DI, CheckForEntireBlock)
cmu_is_safe_to_move_before :: (i: Value_Id, insert_point: Value_Id, dt: *Dom_Tree, pdt: *Dom_Tree, di: *Da_Info, check_for_entire_block := false) -> bool {
    if !pdt || !di return false;
    if i == insert_point return false;
    if inst_next(i) == insert_point return true;
    if inst_op(i) == .PHI || inst_op(insert_point) == .PHI return false;
    if is_terminator(inst_op(i)) return false;
    if cmu_is_reached_before(i, insert_point, dt, pdt) {
        u := ir.v_first_use[i];
        while u != NONE {
            user := ir.u_user[u];
            if is_inst(user) {
                if inst_block(i) == inst_block(insert_point) && user == block_terminator(inst_block(i)) return false;
                if user != insert_point && !dt_dominates_use(dt, insert_point, u) {
                    if !(check_for_entire_block && inst_block(i) == inst_block(user) && dt_dominates_inst(dt, i, user)) return false;
                }
            }
            u = ir.u_next[u];
        }
    }
    if cmu_is_reached_before(insert_point, i, dt, pdt) {
        for k: 0..cast(s64) nops(i) - 1 {
            o := op(i, cast(u32) k);
            if !is_inst(o) continue;
            if insert_point == o return false;
            if check_for_entire_block && inst_block(i) == inst_block(o) && dt_dominates_inst(dt, o, i) continue;
            if !dt_dominates_inst(dt, o, insert_point) return false;
        }
    }
    move_forward := cmu_dom_tree_level_before(dt, i, insert_point);
    start := ifx move_forward then i else insert_point;
    end := ifx move_forward then insert_point else i;
    to_check: [..] Value_Id; to_check.allocator = temp;
    seen: Table(Value_Id, bool); seen.allocator = temp;
    cmu_collect_instructions_in_between(start, end, *to_check, *seen);
    if !move_forward && !table_contains(*seen, insert_point) { table_set(*seen, insert_point, true); array_add(*to_check, insert_point); }
    if !is_safe_to_speculatively_execute_cx(i, NONE, null) {
        for c: to_check {
            if may_throw(c) return false;
            o := inst_op(c);
            if o != .CALL && o != .INVOKE && o != .CALLBR continue;
            if !call_has_fn_attr(c, .WillReturn) return false;
            if !call_has_fn_attr(c, .NoSync) return false;
        }
    }
    for c: to_check {
        d := da_depends(di, i, c);
        if d && (dep_is_output(d) || dep_is_flow(d) || dep_is_anti(d)) return false;
    }
    return true;
}

// isSafeToMoveBefore(BasicBlock &BB, Instruction &InsertPoint, ...)
cmu_is_safe_to_move_block_before :: (bb: Value_Id, insert_point: Value_Id, dt: *Dom_Tree, pdt: *Dom_Tree, di: *Da_Info) -> bool {
    t := block_terminator(bb);
    for i: block_insts(bb) {
        if i == t continue;
        if !cmu_is_safe_to_move_before(i, insert_point, dt, pdt, di, true) return false;
    }
    return true;
}

// moveInstructionsToTheBeginning(FromBB, ToBB, ...): reverse order, the terminator skipped; moveBeforePreserving
// at getFirstNonPHIOrDbg (head bit: the moved instruction keeps its own debug records)
cmu_move_instructions_to_the_beginning :: (from: Value_Id, to: Value_Id, dt: *Dom_Tree, pdt: *Dom_Tree, di: *Da_Info) {
    i := block_last(from);
    if i == NONE return;
    i = inst_prev(i);
    while i != NONE {
        prev := inst_prev(i);
        move_pos := block_first_non_phi_or_dbg(to);
        if cmu_is_safe_to_move_before(i, move_pos, dt, pdt, di) {
            sc_forget_value(i);
            inst_move_before(i, move_pos);
        }
        i = prev;
    }
}

// moveInstructionsToTheEnd(FromBB, ToBB, ...)
cmu_move_instructions_to_the_end :: (from: Value_Id, to: Value_Id, dt: *Dom_Tree, pdt: *Dom_Tree, di: *Da_Info) {
    move_pos := block_terminator(to);
    while block_size(from) > 1 {
        i := block_first(from);
        if !cmu_is_safe_to_move_before(i, move_pos, dt, pdt, di)
            fatal("moveInstructionsToTheEnd: an instruction of '%' cannot be moved (LLVM loops forever here)", vname(from));
        sc_forget_value(i);
        inst_move_before(i, move_pos);
    }
}

// nonStrictlyPostDominate
cmu_non_strictly_post_dominate :: (this_block: Value_Id, other_block: Value_Id, dt: *Dom_Tree, pdt: *Dom_Tree) -> bool {
    common := dt_find_nca(dt, this_block, other_block);
    if common == NONE return false;
    work: [..] Value_Id; work.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    array_add(*work, this_block);
    while work.count {
        cur := pop(*work);
        table_set(*visited, cur, true);
        if dt_dominates(pdt, cur, other_block) return true;
        preds: [..] Value_Id; preds.allocator = temp;
        block_predecessors(cur, *preds);
        for p: preds {
            if p == common || table_contains(*visited, p) continue;
            array_add(*work, p);
        }
    }
    return false;
}

// isReachedBefore
cmu_is_reached_before :: (i0: Value_Id, i1: Value_Id, dt: *Dom_Tree, pdt: *Dom_Tree) -> bool {
    bb0 := inst_block(i0); bb1 := inst_block(i1);
    if bb0 == bb1 return dt_dominates_inst(dt, i0, i1);
    return cmu_non_strictly_post_dominate(bb1, bb0, dt, pdt);
}
