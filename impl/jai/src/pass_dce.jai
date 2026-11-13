// DCE: port of llvm/lib/Transforms/Scalar/DCE.cpp (DCEPass: eliminateDeadCode / DCEInstruction).
// salvageKnowledge has nothing to do: --enable-knowledge-retention is off.

Small_Set_Vector :: struct {
    items: [..] Value_Id;
    set: Table(Value_Id, bool);
}
ssv_init :: (s: *Small_Set_Vector) { s.items.allocator = temp; s.set.allocator = temp; }
ssv_insert :: (s: *Small_Set_Vector, v: Value_Id) -> bool {
    if table_contains(*s.set, v) return false;
    table_set(*s.set, v, true);
    array_add(*s.items, v);
    return true;
}
ssv_contains :: (s: *Small_Set_Vector, v: Value_Id) -> bool { return table_contains(*s.set, v); }
ssv_pop :: (s: *Small_Set_Vector) -> Value_Id {
    v := pop(*s.items);
    table_remove(*s.set, v);
    return v;
}

dce_instruction :: (i: Value_Id, wl: *Small_Set_Vector) -> bool {
    if !is_instruction_trivially_dead(i) return false;
    salvage_debug_info(i);
    salvage_knowledge(i);
    n := nops(i);
    if n > 0 for k: 0..n-1 {
        opv := op(i, k);
        set_op(i, k, NONE);
        if opv == NONE || has_uses(opv) || opv == i continue;
        if is_inst(opv) && is_instruction_trivially_dead(opv) ssv_insert(wl, opv);
    }
    erase_inst_with_metadata(i);
    return true;
}

dce_run :: (f: Value_Id) -> Preserved {
    changed := false;
    wl: Small_Set_Vector; ssv_init(*wl);
    for :early_inc fn_insts(f) {
        if !ssv_contains(*wl, it) changed |= dce_instruction(it, *wl);
    }
    while wl.items.count {
        i := ssv_pop(*wl);
        changed |= dce_instruction(i, *wl);
    }
    if !changed return PRESERVE_ALL;
    return preserved_cfg();
}

// ---------------------------------------------------------------- break-crit-edges
// Port of llvm/lib/Transforms/Utils/BreakCriticalEdges.cpp (BreakCriticalEdgesPass, SplitCriticalEdge,
// SplitKnownCriticalEdge) and SplitAllCriticalEdges (BasicBlockUtils.cpp), with the LoopInfo/LCSSA updates.

// CriticalEdgeSplittingOptions
Crit_Edge_Options :: struct {
    dt: *Dom_Tree;
    pdt: *Dom_Tree;
    li: *Loop_Info;
    mssau: *Mssa_Updater;
    merge_identical_edges: bool;
    preserve_lcssa: bool;
    preserve_loop_simplify: bool;
    keep_one_input_phis: bool;
    ignore_unreachable_dests: bool;
}

split_critical_edge :: (t: Value_Id, succ: u32, o: *Crit_Edge_Options, name := "") -> Value_Id {
    if !is_critical_edge(t, succ, o.merge_identical_edges) return NONE;
    return split_known_critical_edge(t, succ, o, name);
}

split_known_critical_edge :: (t: Value_Id, succ: u32, o: *Crit_Edge_Options, name := "") -> Value_Id {
    tibb := inst_block(t);
    dest := get_successor(t, succ);
    if block_is_eh_pad(dest) || inst_op(t) == .INDIRECTBR return NONE;
    if o.ignore_unreachable_dests fatal("split_known_critical_edge: IgnoreUnreachableDests is not supported yet");
    li := o.li;
    loop_preds: [..] Value_Id; loop_preds.allocator = temp;
    if li {
        til := li_loop_for(li, tibb);
        if til != NONE {
            pl: [..] Value_Id; pl.allocator = temp;
            block_predecessors(dest, *pl);
            for p: pl {
                if p == tibb continue;
                if li_loop_for(li, p) != til { loop_preds.count = 0; break; }
                array_add(*loop_preds, p);
            }
            any_ibr := false;
            for loop_preds if inst_op(block_terminator(it)) == .INDIRECTBR any_ibr = true;
            if any_ibr {
                if o.preserve_loop_simplify return NONE;
                loop_preds.count = 0;
            }
        }
    }
    f := block_fn(tibb);
    bbname := name;
    if bbname.count == 0 bbname = tprint("%.%_crit_edge", vname(tibb), vname(dest));
    // BasicBlock::Create(Ctx, Name) then F.insert(++TIBB, NewBB): named on insertion
    nb := new_block(f);
    nbr := create_br(dest);
    block_append_inst(nb, nbr);
    copy_debug_loc(nbr, t);
    found, loop_kind := table_find(*ir.md_kind_map, "llvm.loop");
    if found {
        lmd := get_metadata(t, loop_kind);
        if lmd != NONE set_metadata(nbr, loop_kind, lmd);
    }
    fn_insert_block_after(f, tibb, nb);
    note_block_created(f, nb);
    set_name(nb, bbname);
    set_successor(t, succ, nb);
    {
        idx: u32 = 0;
        for block_insts(dest) {
            if inst_op(it) != .PHI break;
            if phi_block(it, idx) != tibb idx = cast(u32) phi_block_index(it, tibb);
            phi_set_block(it, idx, nb);
        }
    }
    num_split_identical := 1;
    if o.merge_identical_edges {
        n := num_successors(t);
        k := succ + 1;
        while k < n {
            if get_successor(t, k) == dest {
                block_remove_predecessor(dest, tibb, o.keep_one_input_phis);
                set_successor(t, k, nb);
                num_split_identical += 1;
            }
            k += 1;
        }
    }
    if o.mssau {
        tb := tibb;
        mssau_wire_old_predecessors_to_new_immediate_predecessor(o.mssau, dest, nb, .[tb], o.merge_identical_edges);
    }
    if !o.dt && !o.pdt && !li return nb;
    if o.dt || o.pdt {
        updates: [..] Dom_Update; updates.allocator = temp;
        array_add(*updates, .{true, tibb, nb});
        array_add(*updates, .{true, nb, dest});
        if !succ_contains(tibb, dest) array_add(*updates, .{false, tibb, dest});
        if o.dt dt_apply_updates(o.dt, updates);
        if o.pdt dt_apply_updates(o.pdt, updates);
    }
    if li {
        til := li_loop_for(li, tibb);
        if til != NONE {
            dl := li_loop_for(li, dest);
            if dl != NONE {
                if til == dl li_add_basic_block_to_loop(li, dl, nb);
                else if li_contains_loop(li, til, dl) li_add_basic_block_to_loop(li, til, nb);
                else if li_contains_loop(li, dl, til) li_add_basic_block_to_loop(li, dl, nb);
                else {
                    p := li_parent(li, dl);
                    if p != NONE li_add_basic_block_to_loop(li, p, nb);
                }
            }
            if !li_contains(li, til, dest) {
                if o.preserve_lcssa {
                    ps: [..] Value_Id; ps.allocator = temp;
                    for 1..num_split_identical array_add(*ps, tibb);
                    create_phis_for_split_loop_exit(ps, nb, dest);
                }
                if loop_preds.count {
                    neb := split_block_predecessors(dest, loop_preds, "split", o.dt, li, o.mssau, o.preserve_lcssa);
                    if o.preserve_lcssa create_phis_for_split_loop_exit(loop_preds, neb, dest);
                }
            }
        }
    }
    return nb;
}

split_all_critical_edges :: (f: Value_Id, o: *Crit_Edge_Options) -> u32 {
    n: u32 = 0;
    for b: fn_blocks(f) {
        t := block_terminator(b);
        if num_successors(t) > 1 && inst_op(t) != .INDIRECTBR {
            e := num_successors(t);
            for i: 0..e-1 if split_critical_edge(t, i, o) != NONE n += 1;
        }
    }
    return n;
}

break_crit_edges_run :: (f: Value_Id) -> Preserved {
    o: Crit_Edge_Options;
    o.dt = cached_domtree(f);
    o.li = cached_loop_info(f);
    n := split_all_critical_edges(f, *o);
    if n == 0 return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    preserve(*pa, .LOOPS);
    return pa;
}
