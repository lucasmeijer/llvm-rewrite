// Block splitting utilities that keep DominatorTree and LoopInfo up to date.
// Port of llvm/lib/Transforms/Utils/BasicBlockUtils.cpp (SplitBlockPredecessors[Impl], UpdateAnalysisInformation,
// UpdatePHINodes, createPHIsForSplitLoopExit, SplitBlock[Impl], SplitEdge) and Instruction::replaceSuccessorWith,
// Loop::getLocRange/getStartLoc (llvm/lib/Analysis/LoopInfo.cpp).
//
// The MemorySSAUpdater argument of the LLVM functions is `mssau` (null = none); see mssa_updater.jai.

// Instruction::replaceSuccessorWith
replace_successor_with :: (t: Value_Id, old: Value_Id, new: Value_Id) {
    n := num_successors(t);
    if n > 0 for k: 0..n-1 if get_successor(t, k) == old set_successor(t, k, new);
}

// PHINode::removeIncomingValueIf(Pred, DeletePHIIfEmpty): backwards, last entry moved into each hole
phi_remove_incoming_if :: (p: Value_Id, pred: (p: Value_Id, idx: u32, data: *void) -> bool, data: *void, delete_if_empty := true) {
    n := nops(p);
    idx := n;
    while idx > 0 {
        idx -= 1;
        if pred(p, idx, data) {
            last := n - 1;
            if idx != last {
                phi_set_value(p, idx, phi_value(p, last));
                phi_set_block(p, idx, phi_block(p, last));
            }
            use_set(op_use(p, last), NONE);
            ir.u_aux[op_use(p, last)] = NONE;
            n -= 1;
        }
    }
    ir.v_nops[p] = n;
    if n == 0 && delete_if_empty {
        replace_all_uses_with(p, const_poison(vtype(p)));
        erase_inst(p);
    }
}

// getFirstNonPHIOrDbg (debug intrinsics and pseudo probes skipped)
block_first_non_phi_or_dbg :: (b: Value_Id) -> Value_Id {
    for block_insts(b) {
        if inst_op(it) == .PHI continue;
        if inst_op(it) == .CALL {
            nm := intrinsic_id_of_call(it);
            if nm == "llvm.dbg.value" || nm == "llvm.dbg.declare" || nm == "llvm.dbg.assign" || nm == "llvm.dbg.label" || nm == "llvm.pseudoprobe" continue;
        }
        return it;
    }
    return NONE;
}

// BasicBlock::canSplitPredecessors
block_can_split_predecessors :: (b: Value_Id) -> bool {
    f := block_first_non_phi(b);
    if f == NONE return true;
    if inst_op(f) == .LANDINGPAD return true;
    if is_eh_pad(f) return false;
    return true;
}
block_is_landing_pad :: (b: Value_Id) -> bool {
    f := block_first_non_phi(b);
    return f != NONE && inst_op(f) == .LANDINGPAD;
}

// Loop::getStartLoc (getLocRange().getStart()): a DILocation in the loop ID, else the preheader's or the header's
// terminator location. NONE = no location.
li_start_loc :: (li: *Loop_Info, l: Loop_Id) -> Md_Id {
    id := li_loop_id(li, l);
    if id != NONE {
        n := md_nops(id);
        if n > 1 for k: 1..n-1 if is_di(md_op(id, k), .LOCATION) return md_op(id, k);
    }
    ph := li_loop_preheader(li, l);
    if ph != NONE {
        dl := get_metadata(block_terminator(ph), 0);
        if dl != NONE return dl;
    }
    return get_metadata(block_terminator(li_header(li, l)), 0);
}

// hasReachableLoopEntryToHeader
li_has_reachable_loop_entry_to_header :: (li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree) -> bool {
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(li_header(li, l), *preds);
    for preds if !li_contains(li, l, it) && dt_is_reachable_from_entry(dt, it) return true;
    return false;
}

// UpdateAnalysisInformation (the DT path; no DomTreeUpdater). Returns HasLoopExit.
update_analysis_information :: (old_bb: Value_Id, new_bb: Value_Id, preds: [] Value_Id, dt: *Dom_Tree, li: *Loop_Info,
                                 mssau: *Mssa_Updater, preserve_lcssa: bool) -> bool {
    has_loop_exit := false;
    if dt {
        if old_bb == dt.nodes[dt.root_node].block fatal("SplitBlockPredecessors of the entry block (DT->setNewRoot) is not implemented yet");
        dt_split_block(dt, new_bb);
    }
    if mssau mssau_wire_old_predecessors_to_new_immediate_predecessor(mssau, old_bb, new_bb, preds);
    if !li return has_loop_exit;
    assert(dt != null, "DT should be available to update LoopInfo!");
    l := li_loop_for(li, old_bb);
    is_loop_entry := l != NONE;
    split_makes_new_loop_header := false;
    for p: preds {
        if !dt_is_reachable_from_entry(dt, p) continue;
        if preserve_lcssa {
            pl := li_loop_for(li, p);
            if pl != NONE && !li_contains(li, pl, old_bb) has_loop_exit = true;
        }
        if l == NONE continue;
        if li_contains(li, l, p) is_loop_entry = false;
        else split_makes_new_loop_header = true;
    }
    if l == NONE return has_loop_exit;
    if is_loop_entry {
        innermost: Loop_Id = NONE;
        for p: preds {
            pl := li_loop_for(li, p);
            if pl == NONE continue;
            while pl != NONE && !li_contains(li, pl, old_bb) pl = li_parent(li, pl);
            if pl != NONE && (innermost == NONE || li_depth(li, innermost) < li_depth(li, pl)) innermost = pl;
        }
        if innermost != NONE li_add_basic_block_to_loop(li, innermost, new_bb);
    } else {
        li_add_basic_block_to_loop(li, l, new_bb);
        if split_makes_new_loop_header {
            if li_has_reachable_loop_entry_to_header(li, l, dt) li_erase(li, l);
            else li_move_to_header(li, l, new_bb);
        }
    }
    return has_loop_exit;
}

// UpdatePHINodes
update_phi_nodes :: (orig_bb: Value_Id, new_bb: Value_Id, preds: [] Value_Id, bi: Value_Id, has_loop_exit: bool) {
    pred_set: Table(Value_Id, bool); pred_set.allocator = temp;
    for preds table_set(*pred_set, it, true);
    i := block_first(orig_bb);
    while i != NONE && inst_op(i) == .PHI {
        pn := i;
        i = inst_next(i);
        in_val: Value_Id = NONE;
        if !has_loop_exit {
            in_val = phi_value(pn, cast(u32) phi_block_index(pn, preds[0]));
            n := nops(pn);
            for k: 0..n-1 {
                if !table_contains(*pred_set, phi_block(pn, k)) continue;
                if in_val == NONE in_val = phi_value(pn, k);
                else if in_val != phi_value(pn, k) { in_val = NONE; break; }
            }
        }
        if in_val != NONE {
            Data :: struct { set: *Table(Value_Id, bool); }
            d := Data.{*pred_set};
            phi_remove_incoming_if(pn, (p: Value_Id, idx: u32, data: *void) -> bool {
                dd := cast(*Data) data;
                return table_contains(dd.set, phi_block(p, idx));
            }, *d, false);
            phi_add_incoming(pn, in_val, new_bb);
            continue;
        }
        np := create_phi(vtype(pn), cast(u32) preds.count);
        insert_before_named(np, bi, tprint("%.ph", vname(pn)));
        k := cast(s64) nops(pn) - 1;
        while k >= 0 {
            ib := phi_block(pn, cast(u32) k);
            if table_contains(*pred_set, ib) {
                v := phi_remove_incoming(pn, cast(u32) k, false);
                phi_add_incoming(np, v, ib);
            }
            k -= 1;
        }
        phi_add_incoming(pn, np, new_bb);
    }
}

// SplitBlockPredecessors(BB, Preds, Suffix, DT, LI, MSSAU, PreserveLCSSA)
split_block_predecessors :: (bb: Value_Id, preds: [] Value_Id, suffix: string, dt: *Dom_Tree, li: *Loop_Info,
                              mssau: *Mssa_Updater = null, preserve_lcssa := false) -> Value_Id {
    if !block_can_split_predecessors(bb) return NONE;
    if block_is_landing_pad(bb) {
        nbs: [..] Value_Id; nbs.allocator = temp;
        split_landing_pad_predecessors(bb, preds, suffix, tprint("%.split-lp", suffix), *nbs, dt, li, mssau, preserve_lcssa);
        return nbs[0];
    }
    f := block_fn(bb);
    // BasicBlock::Create(Ctx, Name, Parent, InsertBefore = BB)
    nb := create_block(f, tprint("%1%2", vname(bb), suffix), bb);
    bi := create_br(bb);
    block_append_inst(nb, bi);
    l: Loop_Id = NONE;
    old_latch: Value_Id = NONE;
    if li && li_is_loop_header(li, bb) {
        l = li_loop_for(li, bb);
        loc := li_start_loc(li, l);
        if loc != NONE set_metadata(bi, 0, loc);
        old_latch = li_loop_latch(li, l);
    } else {
        fi := block_first_non_phi_or_dbg(bb);
        if fi != NONE copy_debug_loc(bi, fi);
    }
    for p: preds {
        t := block_terminator(p);
        assert(inst_op(t) != .INDIRECTBR, "Cannot split an edge from an IndirectBrInst");
        replace_successor_with(t, bb, nb);
    }
    if preds.count == 0 {
        for block_insts(bb) {
            if inst_op(it) != .PHI break;
            phi_add_incoming(it, const_poison(vtype(it)), nb);
        }
    }
    has_loop_exit := update_analysis_information(bb, nb, preds, dt, li, mssau, preserve_lcssa);
    if preds.count update_phi_nodes(bb, nb, preds, bi, has_loop_exit);
    if old_latch != NONE {
        new_latch := li_loop_latch(li, l);
        if new_latch != old_latch {
            md := get_metadata(block_terminator(old_latch), MD_LOOP_KIND);
            set_metadata(block_terminator(new_latch), MD_LOOP_KIND, md);
            il := li_loop_for(li, old_latch);
            if il != NONE && li_loop_latch(li, il) != old_latch set_metadata(block_terminator(old_latch), MD_LOOP_KIND, NONE);
        }
    }
    return nb;
}

// createPHIsForSplitLoopExit
create_phis_for_split_loop_exit :: (preds: [] Value_Id, split_bb: Value_Id, dest_bb: Value_Id) {
    for pn: block_insts(dest_bb) {
        if inst_op(pn) != .PHI break;
        idx := phi_block_index(pn, split_bb);
        assert(idx >= 0, "Invalid Block Index");
        v := phi_value(pn, cast(u32) idx);
        if is_phi(v) && inst_block(v) == split_bb continue;
        np := create_phi(vtype(pn), cast(u32) preds.count);
        pos := ifx block_is_landing_pad(split_bb) then block_first(split_bb) else block_terminator(split_bb);
        insert_before_named(np, pos, "split");
        for preds phi_add_incoming(np, v, it);
        phi_set_value(pn, cast(u32) idx, np);
    }
}

// SplitBlock(Old, SplitPt, DT, LI, MSSAU, BBName) (the DT path, not DomTreeUpdater)
split_block :: (old: Value_Id, split_pt: Value_Id, dt: *Dom_Tree, li: *Loop_Info, mssau: *Mssa_Updater = null, name := "") -> Value_Id {
    it := split_pt;
    while inst_op(it) == .PHI || is_eh_pad(it) it = inst_next(it);
    nm := name;
    if nm.count == 0 nm = tprint("%.split", vname(old));
    nb := split_basic_block(old, it, nm);
    if li {
        l := li_loop_for(li, old);
        if l != NONE li_add_basic_block_to_loop(li, l, nb);
    }
    if dt {
        on := dt_node(dt, old);
        if on >= 0 {
            children: [..] s32; children.allocator = temp;
            c := dt.nodes[on].first_child;
            while c >= 0 { array_add(*children, c); c = dt.nodes[c].sibling; }
            nn := dt_add_new_block(dt, nb, old);
            for children { dt.dfs_valid = false; dt_set_idom(dt, it, nn); }
        }
    }
    if mssau mssau_move_all_after_splice_blocks(mssau, old, nb, block_first(nb));
    return nb;
}

// SplitLandingPadPredecessorsImpl (DT path)
split_landing_pad_predecessors :: (orig: Value_Id, preds: [] Value_Id, suffix1: string, suffix2: string, out: *[..] Value_Id,
                                   dt: *Dom_Tree, li: *Loop_Info, mssau: *Mssa_Updater, preserve_lcssa: bool) {
    f := block_fn(orig);
    nb1 := create_block(f, tprint("%1%2", vname(orig), suffix1), orig);
    array_add(out, nb1);
    bi1 := create_br(orig);
    block_append_inst(nb1, bi1);
    copy_debug_loc(bi1, block_first_non_phi(orig));
    for p: preds {
        t := block_terminator(p);
        assert(inst_op(t) != .INDIRECTBR, "Cannot split an edge from an IndirectBrInst");
        replace_uses_of_with(t, orig, nb1);
    }
    hle := update_analysis_information(orig, nb1, preds, dt, li, mssau, preserve_lcssa);
    update_phi_nodes(orig, nb1, preds, bi1, hle);
    rest: [..] Value_Id; rest.allocator = temp;
    {
        all: [..] Value_Id; all.allocator = temp;
        block_predecessors(orig, *all);
        for all if it != nb1 array_add(*rest, it);
    }
    nb2: Value_Id = NONE;
    if rest.count {
        nb2 = create_block(f, tprint("%1%2", vname(orig), suffix2), orig);
        array_add(out, nb2);
        bi2 := create_br(orig);
        block_append_inst(nb2, bi2);
        copy_debug_loc(bi2, block_first_non_phi(orig));
        for rest replace_uses_of_with(block_terminator(it), orig, nb2);
        hle2 := update_analysis_information(orig, nb2, rest, dt, li, mssau, preserve_lcssa);
        update_phi_nodes(orig, nb2, rest, bi2, hle2);
    }
    lpad := block_first_non_phi(orig);
    c1 := inst_clone(lpad);
    insert_at_position(c1, nb1, block_first(nb1), true);
    set_name(c1, tprint("lpad%", suffix1));
    if nb2 != NONE {
        c2 := inst_clone(lpad);
        insert_at_position(c2, nb2, block_first(nb2), true);
        set_name(c2, tprint("lpad%", suffix2));
        if has_uses(lpad) {
            assert(type_kind(vtype(lpad)) != .TOKEN);
            pn := create_phi(vtype(lpad), 2);
            insert_at_position(pn, orig, lpad, false);
            set_name(pn, "lpad.phi");
            phi_add_incoming(pn, c1, nb1);
            phi_add_incoming(pn, c2, nb2);
            rauw_with_metadata(lpad, pn);
        }
        erase_inst_with_metadata(lpad);
    } else {
        rauw_with_metadata(lpad, c1);
        erase_inst_with_metadata(lpad);
    }
}
