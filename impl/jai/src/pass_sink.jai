// Sink: port of llvm/lib/Transforms/Scalar/Sink.cpp (isSafeToMove, IsAcceptableTarget, SinkInstruction,
// ProcessBlock, iterativelySinkInstructions). Each AA->getModRefInfo call gets its own SimpleAAQueryInfo.

Sink_Stores :: struct { list: [..] Value_Id; set: Table(Value_Id, bool); }   // SmallPtrSet

sink_is_safe_to_move :: (i: Value_Id, aar: *Aa_Results, st: *Sink_Stores) -> bool {
    stores := *st.list;
    if may_write_to_memory(i) {
        if !table_contains(*st.set, i) { table_set(*st.set, i, true); array_add(stores, i); }
        return false;
    }
    if inst_op(i) == .ALLOCA && alloca_is_static(i) return false;
    if inst_op(i) == .LOAD {
        loc := mloc_get(i);
        for s: stores.* if aa_mod_ref_inst_loc(aa_query_new(aar), s, loc) & MR_MOD return false;
    }
    if is_terminator(inst_op(i)) || inst_op(i) == .PHI || is_eh_pad(i) || may_throw(i) || !will_return(i) return false;
    if is_call_base(i) {
        if call_is_convergent(i) return false;
        for s: stores.* if aa_mod_ref_inst_call(aa_query_new(aar), s, i) & MR_MOD return false;
    }
    return true;
}

sink_is_acceptable_target :: (i: Value_Id, succ: Value_Id, li: *Loop_Info) -> bool {
    if block_is_eh_pad(succ) return false;
    if block_unique_predecessor(succ) != inst_block(i) {
        if may_read_from_memory(i) && get_metadata(i, md_fixed("invariant.load")) == NONE return false;
        sl := li_loop_for(li, succ);
        cl := li_loop_for(li, inst_block(i));
        if sl != NONE && sl != cl return false;
    }
    return true;
}

sink_instruction :: (i: Value_Id, stores: *Sink_Stores, dt: *Dom_Tree, li: *Loop_Info, aar: *Aa_Results) -> bool {
    if !sink_is_safe_to_move(i, aar, stores) return false;
    succ: Value_Id = NONE;
    bb := inst_block(i);
    u := ir.v_first_use[i];
    while u != NONE {
        defer u = ir.u_next[u];
        usr := ir.u_user[u];
        use_block := inst_block(usr);
        if inst_op(usr) == .PHI use_block = ir.u_aux[u];   // the incoming block of this operand
        if !dt_is_reachable_from_entry(dt, use_block) continue;
        if succ != NONE succ = dt_find_nca(dt, succ, use_block);
        else succ = use_block;
    }
    if succ != NONE {
        while succ != bb && !sink_is_acceptable_target(i, succ, li) succ = dt_idom_block(dt, succ);
        if succ == bb succ = NONE;
    }
    if succ == NONE return false;
    iv_move_before_head(i, block_first_insertion_pt(succ), succ);   // moveBefore(getFirstInsertionPt())
    return true;
}

sink_process_block :: (bb: Value_Id, dt: *Dom_Tree, li: *Loop_Info, aar: *Aa_Results) -> bool {
    if !dt_is_reachable_from_entry(dt, bb) return false;
    made_change := false;
    stores: Sink_Stores; stores.list.allocator = temp; stores.set.allocator = temp;   // only membership matters
    it := block_last(bb);
    while it != NONE {
        i := it;
        it = inst_prev(i);
        if is_debug_or_pseudo_inst(i) continue;
        if sink_instruction(i, *stores, dt, li, aar) made_change = true;
    }
    return made_change;
}

sink_run :: (f: Value_Id) -> Preserved {
    dt := get_domtree(f);
    li := get_loop_info(f);
    aar := aa_results_for(f);
    ever := false;
    while true {
        made := false;
        for bb: fn_blocks(f) if sink_process_block(bb, dt, li, *aar) made = true;
        ever |= made;
        if !made break;
    }
    if !ever return PRESERVE_ALL;
    return preserved_cfg();
}
