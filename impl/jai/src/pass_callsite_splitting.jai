// CallSiteSplitting: port of llvm/lib/Transforms/Scalar/CallSiteSplitting.cpp (addNonNullAttribute,
// setConstantInArgument, isCondRelevantToAnyCallArgument, recordCondition(s), addConditions, canSplitCallSite,
// copyMustTailReturn, splitCallSite, isPredicatedOnPHI, shouldSplitOn*, tryToSplitCallSite,
// doCallSiteSplitting). DuplicateInstructionsInSplitBetween is in pass_jump_threading.jai.

css_cl: struct {
    duplication_threshold: s64 = 5;   // -callsite-splitting-duplication-threshold
};

Css_Cond :: struct { cmp: Value_Id; pred: u8; }
Css_Pred :: struct { bb: Value_Id; conds: [..] Css_Cond; }

css_add_non_null :: (cb: Value_Id, v: Value_Id) {
    for k: 0..cast(s64) call_num_args(cb) - 1 if op(cb, cast(u32) k) == v call_add_param_attr_kind(cb, cast(u32) k, .NonNull);
}
css_set_constant_in_argument :: (cb: Value_Id, v: Value_Id, c: Value_Id) {
    for k: 0..cast(s64) call_num_args(cb) - 1 {
        if op(cb, cast(u32) k) == v {
            call_remove_param_attr(cb, cast(u32) k, .NonNull);
            set_op(cb, cast(u32) k, c);
        }
    }
}
css_is_cond_relevant :: (cmp: Value_Id, cb: Value_Id) -> bool {
    op0 := op(cmp, 0);
    for k: 0..cast(s64) call_num_args(cb) - 1 {
        a := op(cb, cast(u32) k);
        if is_constant_kind(vkind(a)) || call_param_has_attr(cb, cast(u32) k, .NonNull) continue;
        if a == op0 return true;
    }
    return false;
}
css_record_condition :: (cb: Value_Id, from: Value_Id, to: Value_Id, conds: *[..] Css_Cond) {
    bi := block_terminator(from);
    if bi == NONE || inst_op(bi) != .CONDBR return;
    c := op(bi, 0);
    if !is_inst(c) || inst_op(c) != .ICMP || !is_constant_kind(vkind(op(c, 1))) return;
    p := inst_pred(c);
    if p == ICMP_EQ || p == ICMP_NE {
        if css_is_cond_relevant(c, cb)
            array_add(conds, .{c, ifx get_successor(bi, 0) == to then p else icmp_inverse(p)});
    }
}
css_record_conditions :: (cb: Value_Id, pred: Value_Id, conds: *[..] Css_Cond, stop_at: Value_Id) {
    from := pred; to := pred;
    visited: [..] Value_Id; visited.allocator = temp;
    contains :: (s: [] Value_Id, b: Value_Id) -> bool { for s if it == b return true; return false; }
    while to != stop_at {
        sp := block_single_predecessor(from);
        if sp != NONE && contains(visited, sp) break;
        if sp == NONE break;
        from = sp;
        css_record_condition(cb, from, to, conds);
        array_add(*visited, from);
        to = from;
    }
}
css_add_conditions :: (cb: Value_Id, conds: [] Css_Cond) {
    for conds {
        arg := op(it.cmp, 0);
        c := op(it.cmp, 1);
        if it.pred == ICMP_EQ css_set_constant_in_argument(cb, arg, c);
        else if is_ptr_type(vtype(c)) && is_null_value(c) css_add_non_null(cb, arg);
    }
}

css_can_split_call_site :: (cb: Value_Id, tti: *Tti) -> bool {
    if call_is_convergent(cb) || call_has_fn_attr(cb, .NoDuplicate) return false;
    if inst_op(cb) != .CALL return false;
    bb := inst_block(cb);
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    if preds.count != 2 || inst_op(block_terminator(preds[0])) == .INDIRECTBR || inst_op(block_terminator(preds[1])) == .INDIRECTBR return false;
    if !block_can_split_predecessors(bb) || block_is_eh_pad(bb) return false;
    cost: Cost = 0;
    x := block_first(bb);
    while x != cb {
        cost = cost_add(cost, tti_instruction_cost(tti, x, TCK_CODE_SIZE));
        if cost >= css_cl.duplication_threshold return false;
        x = inst_next(x);
    }
    return true;
}

css_clone_for_must_tail :: (i: Value_Id, before: Value_Id, v: Value_Id) -> Value_Id {
    c := ic_clone_inst(i);
    insert_at_position(c, inst_block(before), before, false);
    if vname(i).count set_name(c, vname(i));
    if v != NONE set_op(c, 0, v);
    return c;
}
css_copy_must_tail_return :: (split_bb: Value_Id, ci: Value_Id, new_ci: Value_Id) {
    is_void := func_ret(glob(block_fn(split_bb)).value_type) == ir.t_void;
    ii := inst_next(ci);
    bci: Value_Id = NONE;
    if inst_op(ii) == .BITCAST { bci = ii; ii = inst_next(ii); }
    ri := ii;
    assert(inst_op(ri) == .RET, "`musttail` call must be followed by `ret` instruction");
    ti := block_terminator(split_bb);
    v := new_ci;
    if bci != NONE v = css_clone_for_must_tail(bci, ti, v);
    css_clone_for_must_tail(ri, ti, ifx is_void then NONE else v);
}

css_split_call_site :: (cb: Value_Id, preds: [] Css_Pred, dtu: *Dtu) {
    tail := inst_block(cb);
    is_must_tail := call_is_must_tail(cb);
    call_pn: Value_Id = NONE;
    if !is_must_tail && has_uses(cb) {
        call_pn = create_phi(vtype(cb), cast(u32) preds.count);
        copy_debug_loc(call_pn, cb);
    }
    maps: [2] Table(Value_Id, Value_Id);
    maps[0].allocator = temp; maps[1].allocator = temp;
    for i: 0..preds.count - 1 {
        pred_bb := preds[i].bb;
        split := duplicate_instructions_in_split_between(tail, pred_bb, inst_next(cb), *maps[i], dtu);
        new_ci := inst_prev(block_terminator(split));
        css_add_conditions(new_ci, preds[i].conds);
        for pn: block_insts(tail) {
            if inst_op(pn) != .PHI break;
            for k: 0..cast(s64) call_num_args(cb) - 1 if op(cb, cast(u32) k) == pn set_op(new_ci, cast(u32) k, phi_incoming_value_for_block(pn, split));
        }
        if call_pn != NONE phi_add_incoming(call_pn, new_ci, split);
        if is_must_tail css_copy_must_tail_return(split, cb, new_ci);
    }
    if is_must_tail {
        splits: [..] Value_Id; splits.allocator = temp;
        block_predecessors(tail, *splits);
        for b: splits {
            erase_inst_with_metadata(block_terminator(b));
            dtu_apply_permissive(dtu, .[.{false, b, tail}]);
        }
        dtu_delete_bb(dtu, tail);
        return;
    }
    original_begin := block_first(tail);
    if call_pn != NONE {
        insert_at_position(call_pn, tail, original_begin, true);
        set_name(call_pn, "phi.call");
        rauw_with_metadata(cb, call_pn);
    }
    cur := cb;
    while cur != NONE {
        current := cur;
        cur = inst_prev(cur);
        if has_uses(current) {
            if inst_op(current) == .PHI continue;
            pn := create_phi(vtype(current), cast(u32) preds.count);
            copy_debug_loc(pn, current);
            for * m: maps {
                _, v := table_find(m, current);
                phi_add_incoming(pn, v, inst_block(v));
            }
            insert_at_position(pn, tail, block_first(tail), true);
            rauw_with_metadata(current, pn);
        }
        drop_dbg_records(current);
        erase_inst_with_metadata(current);
        if current == original_begin break;
    }
}

css_is_predicated_on_phi :: (cb: Value_Id) -> bool {
    parent := inst_block(cb);
    if cb != block_first_non_phi_or_dbg(parent) return false;
    for pn: block_insts(parent) {
        if inst_op(pn) != .PHI break;
        for k: 0..cast(s64) call_num_args(cb) - 1 {
            if op(cb, cast(u32) k) != pn continue;
            assert(phi_num_incoming(pn) == 2, "Unexpected number of incoming values");
            if phi_block(pn, 0) == phi_block(pn, 1) return false;
            if phi_value(pn, 0) == phi_value(pn, 1) continue;
            if is_constant_kind(vkind(phi_value(pn, 0))) && is_constant_kind(vkind(phi_value(pn, 1))) return true;
        }
    }
    return false;
}

css_try_to_split_call_site :: (cb: Value_Id, tti: *Tti, dtu: *Dtu) -> bool {
    if call_num_args(cb) == 0 || !css_can_split_call_site(cb, tti) return false;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(inst_block(cb), *preds);
    with_conds: [..] Css_Pred; with_conds.allocator = temp;
    // shouldSplitOnPredicatedArgument
    if preds[0] != preds[1] {
        dt := dtu_get_dom_tree(dtu);
        stop_at: Value_Id = NONE;
        if dt_node(dt, inst_block(cb)) >= 0 stop_at = dt_idom_block(dt, inst_block(cb));
        k := preds.count;
        any := false;
        while k > 0 {
            k -= 1;
            p: Css_Pred; p.bb = preds[k]; p.conds.allocator = temp;
            css_record_condition(cb, preds[k], inst_block(cb), *p.conds);
            css_record_conditions(cb, preds[k], *p.conds, stop_at);
            if p.conds.count any = true;
            array_add(*with_conds, p);
        }
        if !any with_conds.count = 0;
    }
    if with_conds.count == 0 && css_is_predicated_on_phi(cb) {
        p0: Css_Pred; p0.bb = preds[0];
        p1: Css_Pred; p1.bb = preds[1];
        array_add(*with_conds, p0); array_add(*with_conds, p1);
    }
    if with_conds.count == 0 return false;
    css_split_call_site(cb, with_conds, dtu);
    return true;
}

callsite_splitting_run :: (f: Value_Id) -> Preserved {
    tti := tti_get(f);
    dt := get_domtree(f);
    dtu: Dtu; dtu.dt = dt; dtu.lazy = true;
    dtu.pending.allocator = temp; dtu.deleted.allocator = temp; dtu.deleted_set.allocator = temp;
    changed := false;
    bb := fn_entry(f);
    while bb != NONE {
        nb := block(bb).next;   // make_early_inc_range
        defer bb = nb;
        ii := block_first_non_phi_or_dbg(bb);
        ie := block_terminator(bb);
        while ii != NONE && ii != ie && ii != block_terminator(bb) {
            cb := ii;
            ii = inst_next(ii);
            if !is_call_base(cb) continue;
            cf := call_called_function(cb);
            if (cf != NONE && glob(cf).intrinsic) || is_instruction_trivially_dead(cb) continue;   // isa<IntrinsicInst>
            callee := call_called_function(cb);
            if callee == NONE || is_declaration(callee) continue;
            is_must_tail := call_is_must_tail(cb);
            if css_try_to_split_call_site(cb, tti, *dtu) changed = true;
            if is_must_tail break;
        }
    }
    dtu_flush(*dtu);
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    return pa;
}
