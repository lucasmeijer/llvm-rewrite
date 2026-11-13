// CoroElide: devirtualizes resume/destroy calls of a post-split coroutine whose ramp was inlined into the caller and,
// when the coroutine frame's lifetime is contained in the caller, replaces its heap allocation by an alloca.
// Ported from llvm/lib/Transforms/Coroutines/CoroElide.cpp (FunctionElideInfo, CoroIdElider). The optimization
// remarks are not emitted (no -pass-remarks support).

Coro_Elider :: struct {
    f: Value_Id;
    coro_id: Value_Id;
    suspend_switches: *[..] Value_Id;   // FunctionElideInfo::CoroSuspendSwitches
    coro_begins: [..] Value_Id;
    coro_allocs: [..] Value_Id;
    resume_addr: [..] Value_Id;
    destroy_addr: [..] Value_Id;
    // BeginDeadMap: the coro.begin -> coro.dead / destroy list, only for coro.begins with users (the C++ creates
    // the map entry inside the users loop)
    dead_keys: [..] Value_Id;
    dead_lists: [..] [..] Value_Id;
}

coro_elide_dead_list :: (e: *Coro_Elider, cb: Value_Id) -> *[..] Value_Id {
    for e.dead_keys if it == cb return *e.dead_lists[it_index];
    return null;
}

// getFirstNonAllocaInTheEntryBlock
coro_first_non_alloca_in_entry :: (f: Value_Id) -> Value_Id {
    for i: block_insts(fn_entry(f)) if inst_op(i) != .ALLOCA return i;
    fatal("internal: no terminator in the entry block");
    return NONE;
}

// CoroIdElider::CoroIdElider
coro_elider_init :: (e: *Coro_Elider, coro_id: Value_Id, f: Value_Id, switches: *[..] Value_Id) {
    e.f = f; e.coro_id = coro_id; e.suspend_switches = switches;
    e.coro_begins.allocator = temp; e.coro_allocs.allocator = temp; e.resume_addr.allocator = temp;
    e.destroy_addr.allocator = temp; e.dead_keys.allocator = temp; e.dead_lists.allocator = temp;
    u := ir.v_first_use[coro_id];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(usr) continue;
        if coro_is_begin(usr) array_add(*e.coro_begins, usr);
        else if call_iid(usr) == IID_CORO_ALLOC array_add(*e.coro_allocs, usr);
    }
    for cb: e.coro_begins {
        w := ir.v_first_use[cb];
        while w != NONE {
            usr := ir.u_user[w];
            w = ir.u_next[w];
            deads := coro_elide_dead_list(e, cb);
            if !deads {
                array_add(*e.dead_keys, cb);
                l: [..] Value_Id; l.allocator = temp;
                array_add(*e.dead_lists, l);
                deads = *e.dead_lists[e.dead_lists.count - 1];
            }
            if !is_inst(usr) continue;
            id := call_iid(usr);
            if id == IID_CORO_SUBFN_ADDR {
                idx := cast(s64) const_int_sext(call_arg(usr, 1));
                if idx == CORO_SUBFN_RESUME array_add(*e.resume_addr, usr);
                else if idx == CORO_SUBFN_DESTROY { array_add(deads, usr); array_add(*e.destroy_addr, usr); }
                else fatal("internal: unexpected coro.subfn.addr constant");
            } else if id == IID_CORO_DEAD array_add(deads, usr);
        }
    }
}

// replaceWithConstant
coro_elide_replace_with_constant :: (value: Value_Id, users: [] Value_Id) {
    q: Simplify_Query;
    q.have_tli = false; q.no_tli_libcalls = true;   // replaceAndRecursivelySimplify(I, Value): no TLI, DT, AC
    for users replace_and_recursively_simplify(it, value, q);
}

// operandReferences
coro_elide_operand_references :: (aar: *Aa_Results, ci: Value_Id, frame: Value_Id) -> bool {
    n := nops(ci);
    for k: 0..cast(s64) n - 1 {
        o := op(ci, cast(u32) k);
        if !is_ptr_type(vtype(o)) continue;
        aq := aa_query_new(aar);   // AAResults::isNoAlias: a fresh SimpleAAQueryInfo per query
        r := aa_alias(aq, mloc_before_or_after(o), mloc_before_or_after(frame));
        if r.kind != AR_NO return true;
    }
    return false;
}

// removeTailCallAttribute
coro_elide_remove_tail_call_attribute :: (frame: Value_Id) {
    f := inst_fn(frame);
    aar := aa_results_for(f);
    for i: fn_insts(f) {
        if inst_op(i) != .CALL continue;
        tk := call_tail_kind(i);
        if tk != TCK_TAIL && tk != TCK_MUSTTAIL continue;
        if coro_elide_operand_references(*aar, i, frame) && tk != TCK_MUSTTAIL call_set_tail_kind(i, TCK_NONE);
    }
}

// CoroIdElider::elideHeapAllocations
coro_elide_heap_allocations :: (e: *Coro_Elider, frame_size: u64, frame_align: u64) {
    insert_pt := coro_first_non_alloca_in_entry(e.f);
    fls := const_int(ir.t_i1, 0);
    for e.coro_allocs { coro_rauw(it, fls); coro_erase(it); }
    frame_ty := type_array(frame_size, ir.t_i8);
    frame := new_inst(.ALLOCA, ir.t_ptr, 1);
    inst(frame).ty2 = frame_ty;
    set_op(frame, 0, const_int(ir.t_i32, 1));
    inst(frame).align = frame_align;
    inst(frame).addrspace = dl_alloca_addrspace();
    insert_at_position(frame, inst_block(insert_pt), insert_pt, false);
    void_ptr := new_inst(.BITCAST, ir.t_ptr, 1);
    set_op(void_ptr, 0, frame);
    insert_at_position(void_ptr, inst_block(insert_pt), insert_pt, false);
    set_name(void_ptr, "vFrame");
    for cb: e.coro_begins {
        coro_elide_coro_free(cb);
        coro_rauw(cb, void_ptr);
        coro_erase(cb);
    }
    coro_elide_remove_tail_call_attribute(frame);
}

// CoroIdElider::canCoroBeginEscape
coro_elide_can_begin_escape :: (e: *Coro_Elider, cb: Value_Id, tis: *Table(Value_Id, bool)) -> bool {
    deads := coro_elide_dead_list(e, cb);
    limit := 32 * (1 + deads.count);
    worklist: [..] Value_Id; worklist.allocator = temp;
    array_add(*worklist, inst_block(cb));
    visited: Table(Value_Id, bool); visited.allocator = temp;
    for deads.* table_set(*visited, inst_block(it), true);
    escaping: Table(Value_Id, bool); escaping.allocator = temp;
    u := ir.v_first_use[cb];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        id := call_iid(usr);
        if id == IID_CORO_FREE || id == IID_CORO_SUBFN_ADDR || id == IID_CORO_SAVE continue;
        table_set(*escaping, inst_block(usr), true);
    }
    potentially_escaped := false;
    while true {
        bb := pop(*worklist);
        if !table_contains(*visited, bb) {
            table_set(*visited, bb, true);
            if table_contains(*escaping, bb) potentially_escaped = true;
            if table_contains(tis, bb) {
                if inst_op(block_terminator(bb)) == .RET || potentially_escaped return true;
            } else {
                limit -= 1;
                if limit == 0 return true;
                ti := block_terminator(bb);
                is_suspend_switch := false;
                if inst_op(ti) == .SWITCH for e.suspend_switches.* if it == ti { is_suspend_switch = true; break; }
                if is_suspend_switch {
                    array_add(*worklist, get_successor(ti, 1));
                    array_add(*worklist, get_successor(ti, 2));
                } else {
                    n := num_successors(ti);
                    for k: 0..cast(s64) n - 1 array_add(*worklist, get_successor(ti, cast(u32) k));
                }
            }
        }
        if worklist.count == 0 break;
    }
    return false;
}

// CoroIdElider::lifetimeEligibleForElide
coro_elide_lifetime_eligible :: (e: *Coro_Elider, dt: *Dom_Tree) -> bool {
    if e.coro_allocs.count == 0 return false;
    terminators: Table(Value_Id, bool); terminators.allocator = temp;
    term_list: [..] Value_Id; term_list.allocator = temp;
    for b: fn_blocks(e.f) {
        ti := block_terminator(b);
        if num_successors(ti) != 0 || inst_op(ti) == .UNREACHABLE continue;
        table_set(*terminators, b, true);
        array_add(*term_list, b);
    }
    for cb: e.coro_begins {
        deads := coro_elide_dead_list(e, cb);
        if !deads return false;
        all := true;
        for tb: term_list {
            any := false;
            for d: deads.* if dt_dominates_inst(dt, d, block_terminator(tb)) { any = true; break; }
            if !any { all = false; break; }
        }
        if all continue;
        if coro_elide_can_begin_escape(e, cb, *terminators) return false;
    }
    return true;
}

// CoroIdElider::attemptElide
coro_elide_attempt :: (e: *Coro_Elider, dt: *Dom_Tree) -> bool {
    _, resumers := coro_id_info(e.coro_id);
    if resumers == NONE fatal("internal: PostSplit coro.id Info argument must refer to an array of coroutine subfunctions");
    resume_const := op(resumers, CORO_SUBFN_RESUME);
    coro_elide_replace_with_constant(resume_const, e.resume_addr);
    eligible := coro_elide_lifetime_eligible(e, dt);
    destroy_const := op(resumers, ifx eligible then cast(u32) CORO_SUBFN_CLEANUP else cast(u32) CORO_SUBFN_DESTROY);
    coro_elide_replace_with_constant(destroy_const, e.destroy_addr);
    // getFrameLayout(cast<Function>(ResumeAddrConstant))
    resume_fn := resume_const;
    if vkind(resume_fn) != .FUNCTION fatal("internal: coro-elide: the resume function is not a Function");
    size := coro_fn_param_deref_bytes(resume_fn, 0);
    if eligible && size != 0 {
        al := fn_param_align(resume_fn, 0);
        coro_elide_heap_allocations(e, size, ifx al == 0 then cast(u64) 1 else al);
    }
    return true;
}

coro_fn_param_deref_bytes :: (f: Value_Id, k: u32) -> u64 {
    a := attr_set_find(attr_list_param(glob(f).attrs, k), .Dereferenceable);
    if a return a.ival;
    return 0;
}

// CoroElidePass::run
coro_elide_run :: (f: Value_Id) -> Preserved {
    if !coro_declares_any(.["llvm.coro.id"]) return PRESERVE_ALL;
    // FunctionElideInfo::collectPostSplitCoroIds
    ids: [..] Value_Id; ids.allocator = temp;
    switches: [..] Value_Id; switches.allocator = temp;
    for i: fn_insts(f) {
        id := call_iid(i);
        if id == IID_CORO_ID && inst_op(i) == .CALL && coro_id_is_post_split(i) && coro_id_coroutine(i) != f array_add(*ids, i);
        if id == IID_CORO_SUSPEND && inst_op(i) == .CALL && has_one_use(i) {
            usr := ir.u_user[ir.v_first_use[i]];
            if is_inst(usr) && inst_op(usr) == .SWITCH && switch_num_cases(usr) == 2 {
                found := false;
                for switches if it == usr { found = true; break; }
                if !found array_add(*switches, usr);
            }
        }
    }
    if ids.count == 0 return PRESERVE_ALL;
    dt := get_domtree(f);
    changed := false;
    for ids {
        e: Coro_Elider;
        coro_elider_init(*e, it, f, *switches);
        changed |= coro_elide_attempt(*e, dt);
    }
    return ifx changed then PRESERVE_NONE else PRESERVE_ALL;
}
