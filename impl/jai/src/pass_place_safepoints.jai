// PlaceSafepoints: a port of llvm/lib/Transforms/Scalar/PlaceSafepoints.cpp (backedge, entry and poll placement;
// the legacy PlaceBackedgeSafepointsLegacyPass the pass runs in its own legacy FunctionPassManager is the
// ps_run_on_loop walk over a fresh LoopInfo / ScalarEvolution).

ps_cl: struct {
    all_backedges := false;              // -spp-all-backedges
    counted_loop_trip_width: s64 = 32;   // -spp-counted-loop-trip-width
    split_backedge := false;             // -spp-split-backedge
    no_entry := false;                   // -spp-no-entry
    no_call := false;                    // -spp-no-call
    no_backedge := false;                // -spp-no-backedge
};
place_safepoints_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == {
        case "spp-all-backedges"; ps_cl.all_backedges = smisc_bool(name, value, has_value);
        case "spp-counted-loop-trip-width"; ps_cl.counted_loop_trip_width = smisc_int(name, value, has_value);
        case "spp-split-backedge"; ps_cl.split_backedge = smisc_bool(name, value, has_value);
        case "spp-no-entry"; ps_cl.no_entry = smisc_bool(name, value, has_value);
        case "spp-no-call"; ps_cl.no_call = smisc_bool(name, value, has_value);
        case "spp-no-backedge"; ps_cl.no_backedge = smisc_bool(name, value, has_value);
        case; return false;
    }
    return true;
}

// needsStatepoint
ps_needs_statepoint :: (call: Value_Id) -> bool {
    if calls_gc_leaf_function(call) return false;
    if inst_op(call) == .CALL && vkind(call_callee(call)) == .INLINE_ASM return false;
    id := call_iid(call);
    return !(id == IID_EXPERIMENTAL_GC_STATEPOINT || id == IID_GC_RELOCATE || id == IID_GC_RESULT);
}

// containsUnconditionalCallSafepoint
ps_contains_unconditional_call_safepoint :: (header: Value_Id, pred: Value_Id, dt: *Dom_Tree) -> bool {
    cur := pred;
    while true {
        for i: block_insts(cur) if is_call_base(i) && ps_needs_statepoint(i) return true;
        if cur == header break;
        cur = dt_idom_block(dt, cur);
    }
    return false;
}

// mustBeFiniteCountedLoop
ps_must_be_finite_counted_loop :: (l: Loop_Id, li: *Loop_Info, pred: Value_Id) -> bool {
    w := cast(u32) ps_cl.counted_loop_trip_width;
    max_trips := sc_get_constant_max_backedge_taken_count(l);
    if !sc_is_cnc(max_trips) && ap_active_bits(sc_unsigned_range_max(max_trips)) <= w return true;
    if li_is_loop_exiting(li, l, pred) {
        max_exec := sc_get_exit_count(l, pred);
        if !sc_is_cnc(max_exec) && ap_active_bits(sc_unsigned_range_max(max_exec)) <= w return true;
    }
    return false;
}

// PlaceBackedgeSafepointsLegacyPass::runOnLoop
ps_run_on_loop :: (l: Loop_Id, li: *Loop_Info, dt: *Dom_Tree, call_safepoints: bool, polls: *[..] Value_Id) {
    header := li_header(li, l);
    latches: [..] Value_Id; latches.allocator = temp;
    li_loop_latches(li, l, *latches);
    for pred: latches {
        if !ps_cl.all_backedges {
            if ps_must_be_finite_counted_loop(l, li, pred) continue;
            if call_safepoints && ps_contains_unconditional_call_safepoint(header, pred, dt) continue;
        }
        array_add(polls, block_terminator(pred));
    }
}
ps_run_on_loop_and_subloops :: (l: Loop_Id, li: *Loop_Info, dt: *Dom_Tree, call_safepoints: bool, polls: *[..] Value_Id) {
    for sub: li_subloops(li, l) ps_run_on_loop_and_subloops(sub, li, dt, call_safepoints, polls);
    ps_run_on_loop(l, li, dt, call_safepoints, polls);
}

// doesNotRequireEntrySafepointBefore
ps_does_not_require_entry_safepoint_before :: (call: Value_Id) -> bool {
    // dyn_cast<IntrinsicInst>: any callee with an "llvm." name (Function::isIntrinsic), even an unknown one
    f := call_called_function(call);
    if f != NONE && glob(f).intrinsic {
        id := fn_iid(f);
        return id != IID_EXPERIMENTAL_GC_STATEPOINT && id != IID_PATCHPOINT_VOID && id != IID_PATCHPOINT;
    }
    return false;
}

// findLocationForEntrySafepoint
ps_find_location_for_entry_safepoint :: (f: Value_Id) -> Value_Id {
    has_next :: (i: Value_Id) -> bool {
        if !is_terminator(inst_op(i)) return true;
        nb := block_unique_successor(inst_block(i));
        return nb != NONE && block_unique_predecessor(nb) != NONE;
    }
    next :: (i: Value_Id) -> Value_Id {
        if is_terminator(inst_op(i)) return block_first(block_unique_successor(inst_block(i)));
        return inst(i).next;
    }
    cursor := block_first(fn_entry(f));
    while has_next(cursor) {
        if is_call_base(cursor) {
            if !ps_does_not_require_entry_safepoint_before(cursor) break;
        }
        cursor = next(cursor);
    }
    return cursor;
}
// scanOneBB / scanInlinedCode
ps_scan_one_bb :: (start: Value_Id, end: Value_Id, calls: *[..] Value_Id, seen: *Table(Value_Id, bool), wl: *[..] Value_Id) {
    i := start;
    succs: [..] Value_Id; succs.allocator = temp;
    while i != NONE && i != end {
        if inst_op(i) == .CALL array_add(calls, i);
        if inst_op(i) == .INVOKE fatal("support for invokes in poll code needed");
        if is_terminator(inst_op(i)) {
            succs.count = 0;
            block_successors(inst_block(i), *succs);
            for s: succs if !table_contains(seen, s) { table_set(seen, s, true); array_add(wl, s); }
        }
        i = inst(i).next;
    }
}

// InsertSafepointPoll
ps_insert_safepoint_poll :: (before: Value_Id) {
    orig_bb := inst_block(before);
    f := lookup_global("gc.safepoint_poll");
    if f == NONE || vkind(f) != .FUNCTION fatal("gc.safepoint_poll function is missing");
    if glob(f).value_type != type_func(ir.t_void, .[], false) fatal("gc.safepoint_poll declared with wrong type");
    if is_declaration(f) fatal("gc.safepoint_poll must be a non-empty function");
    poll := arc_new_call_fn(f, .[]);
    insert_at_position(poll, orig_bb, before, false);
    is_begin := block_first(orig_bb) == poll;
    bef := inst(poll).prev;
    after := inst(poll).next;
    assert(after != NONE, "must have successor");
    ifi: Inline_Function_Info;
    ifi.static_allocas.allocator = temp;
    r := inline_function(poll, *ifi, false, null, true, false);
    if !r.ok fatal(tprint("place-safepoints: inlining gc.safepoint_poll failed: %", r.reason));
    if ifi.static_allocas.count fatal("can't have allocs");
    start := ifx is_begin then block_first(orig_bb) else inst(bef).next;
    calls: [..] Value_Id; calls.allocator = temp;
    seen: Table(Value_Id, bool); seen.allocator = temp;
    wl: [..] Value_Id; wl.allocator = temp;
    table_set(*seen, inst_block(start), true);
    ps_scan_one_bb(start, after, *calls, *seen, *wl);
    while wl.count {
        bb := pop(*wl);
        ps_scan_one_bb(block_first(bb), after, *calls, *seen, *wl);
    }
    if calls.count == 0 fatal("slow path not found for safepoint poll");
    // the parse points (calls that need a statepoint) are collected but unused, as in LLVM
}

// PlaceSafepointsPass::runImpl
place_safepoints_run :: (f: Value_Id) -> Preserved {
    if is_declaration(f) || glob(f).first_block == NONE return PRESERVE_ALL;
    if vname(f) == "gc.safepoint_poll" return PRESERVE_ALL;
    gc := glob(f).gc;
    if !(gc == "statepoint-example" || gc == "coreclr") return PRESERVE_ALL;
    modified := remove_unreachable_blocks(f, null);
    if modified fam_invalidate(f, PRESERVE_NONE);
    polls_needed: [..] Value_Id; polls_needed.allocator = temp;
    if !ps_cl.no_backedge {
        call_safepoints := !ps_cl.no_call;
        // the legacy FunctionPassManager computes its own DominatorTree, LoopInfo and ScalarEvolution
        fam_invalidate(f, PRESERVE_NONE);
        dt := get_domtree(f);
        li := get_loop_info(f);
        get_scev(f);
        locs: [..] Value_Id; locs.allocator = temp;
        for l: li.top_level ps_run_on_loop_and_subloops(l, li, dt, call_safepoints, *locs);
        fam_invalidate(f, PRESERVE_NONE);
        dt = get_domtree(f);
        // llvm::sort by parent block name (std::sort: insertion sort below 17 elements, so ties keep their order)
        if locs.count > 16 {
            for x: 1..locs.count-1 if vname(inst_block(locs[x])) == vname(inst_block(locs[x - 1]))
                fatal("place-safepoints: more than 16 poll locations with equal block names (std::sort order)");
        }
        for x: 1..locs.count-1 {
            v := locs[x];
            y := x;
            while y > 0 && compare(vname(inst_block(v)), vname(inst_block(locs[y - 1]))) < 0 { locs[y] = locs[y - 1]; y -= 1; }
            locs[y] = v;
        }
        uniq: [..] Value_Id; uniq.allocator = temp;
        for locs if uniq.count == 0 || uniq[uniq.count - 1] != it array_add(*uniq, it);
        for term: uniq {
            modified = true;
            if ps_cl.split_backedge {
                headers: [..] Value_Id; headers.allocator = temp;
                succs: [..] Value_Id; succs.allocator = temp;
                tb := inst_block(term);
                block_successors(tb, *succs);
                for s: succs if dt_dominates(dt, s, tb) {
                    dup := false; for headers if it == s dup = true;
                    if !dup array_add(*headers, s);
                }
                for h: headers {
                    nb := split_edge(inst_block(term), h, dt, null);
                    array_add(*polls_needed, block_terminator(nb));
                }
            } else array_add(*polls_needed, term);
        }
    }
    if !ps_cl.no_entry {
        loc := ps_find_location_for_entry_safepoint(f);
        if loc != NONE { array_add(*polls_needed, loc); modified = true; }
    }
    for polls_needed ps_insert_safepoint_poll(it);
    if !modified return PRESERVE_ALL;
    return PRESERVE_NONE;
}
