// LoopSimplifyCFG: llvm/lib/Transforms/Scalar/LoopSimplifyCFG.cpp (complete).
// ConstantTerminatorFoldingImpl is the `Ctf` struct; its methods are `ctf_*`.

lscfg_opts: struct {
    enable_term_folding := true;   // -enable-loop-simplifycfg-term-folding
};

// getOnlyLiveSuccessor
lscfg_only_live_successor :: (bb: Value_Id) -> Value_Id {
    ti := block_terminator(bb);
    if inst_op(ti) == .CONDBR {
        if get_successor(ti, 0) == get_successor(ti, 1) return get_successor(ti, 0);
        c := op(ti, 0);
        if vkind(c) != .C_INT return NONE;
        return ifx ap_is_zero(const_ap(c)) then get_successor(ti, 1) else get_successor(ti, 0);
    }
    if inst_op(ti) == .SWITCH {
        c := sw_cond(ti);
        if vkind(c) != .C_INT return NONE;
        n := sw_num_cases(ti);
        for k: 0..cast(s64) n - 1 if sw_case_value(ti, cast(u32) k) == c return sw_case_dest(ti, cast(u32) k);
        return sw_default(ti);
    }
    return NONE;
}

// removeBlockFromLoops(BB, FirstLoop, LastLoop)
lscfg_remove_block_from_loops :: (li: *Loop_Info, bb: Value_Id, first: Loop_Id, last: Loop_Id) {
    cur := first;
    while cur != last { li_remove_block_from_loop(li, cur, bb); cur = li_parent(li, cur); }
}

// getInnermostLoopFor(BBs, L, LI)
lscfg_innermost_loop_for :: (li: *Loop_Info, bbs: [] Value_Id, l: Loop_Id) -> Loop_Id {
    innermost: Loop_Id = NONE;
    h := li_header(li, l);
    for bb: bbs {
        bbl := li_loop_for(li, bb);
        while bbl != NONE && !li_contains(li, bbl, h) bbl = li_parent(li, bbl);
        if bbl == l bbl = li_parent(li, bbl);
        if bbl == NONE continue;
        if innermost == NONE || li_depth(li, bbl) > li_depth(li, innermost) innermost = bbl;
    }
    return innermost;
}

Ctf :: struct {
    l: Loop_Id;
    li: *Loop_Info;
    dt: *Dom_Tree;
    mssau: *Mssa_Updater;
    rpo: [..] Value_Id;                 // LoopBlocksDFS (RPO; the postorder is its reverse)
    dtu: Dtu;                           // eager
    dt_updates: [..] Dom_Update;
    has_irreducible_cfg: bool;
    delete_current_loop: bool;
    has_indirect_entry: bool;
    live_loop_blocks: Table(Value_Id, bool);
    dead_loop_blocks: [..] Value_Id;
    live_exit_blocks: [..] Value_Id;    // a set (insertion order)
    dead_exit_blocks: [..] Value_Id;
    blocks_in_loop_after_folding: Table(Value_Id, bool);
    fold_candidates: [..] Value_Id;
}

ctf_has_irreducible_cfg :: (c: *Ctf) -> bool {
    rpo_num: Table(Value_Id, s64); rpo_num.allocator = temp;
    for c.rpo table_set(*rpo_num, it, it_index);
    succs: [..] Value_Id; succs.allocator = temp;
    for bb: c.rpo {
        succs.count = 0;
        block_successors(bb, *succs);
        for s: succs {
            if !li_contains(c.li, c.l, s) || li_is_loop_header(c.li, s) continue;
            _, a := table_find(*rpo_num, bb);
            _, b := table_find(*rpo_num, s);   // RPO[Succ]: 0 when absent (DenseMap operator[])
            if a > b return true;
        }
    }
    return false;
}

ctf_is_edge_live :: (c: *Ctf, from: Value_Id, to: Value_Id) -> bool {
    if !table_contains(*c.live_loop_blocks, from) return false;
    only := lscfg_only_live_successor(from);
    return only == NONE || only == to || li_loop_for(c.li, from) != c.l;
}

ctf_analyze :: (c: *Ctf) {
    li := c.li; l := c.l;
    loop_blocks_rpo(li, l, *c.rpo);
    if ctf_has_irreducible_cfg(c) { c.has_irreducible_cfg = true; return; }
    if li_loop_preheader(li, l) == NONE { c.has_indirect_entry = true; return; }
    table_set(*c.live_loop_blocks, li_header(li, l), true);
    succs: [..] Value_Id; succs.allocator = temp;
    for bb: c.rpo {
        if !table_contains(*c.live_loop_blocks, bb) { array_add(*c.dead_loop_blocks, bb); continue; }
        only := lscfg_only_live_successor(bb);
        take := only != NONE && li_loop_for(li, bb) == l;
        if take array_add(*c.fold_candidates, bb);
        succs.count = 0;
        block_successors(bb, *succs);
        for s: succs {
            if take && only != s continue;
            if li_contains(li, l, s) table_set(*c.live_loop_blocks, s, true);
            else if !block_set_contains(c.live_exit_blocks, s) array_add(*c.live_exit_blocks, s);
        }
    }
    exits: [..] Value_Id; exits.allocator = temp;
    li_exit_blocks(li, l, *exits);
    unique_dead: [..] Value_Id; unique_dead.allocator = temp;
    preds: [..] Value_Id; preds.allocator = temp;
    for e: exits {
        if block_set_contains(c.live_exit_blocks, e) continue;
        if block_set_contains(unique_dead, e) continue;
        array_add(*unique_dead, e);
        preds.count = 0;
        block_predecessors(e, *preds);
        all_in := true;
        for preds if !li_contains(li, l, it) { all_in = false; break; }
        if all_in array_add(*c.dead_exit_blocks, e);
    }
    c.delete_current_loop = !ctf_is_edge_live(c, li_loop_latch(li, l), li_header(li, l));
    if c.delete_current_loop return;
    table_set(*c.blocks_in_loop_after_folding, li_loop_latch(li, l), true);
    for < bb: c.rpo {   // postorder
        succs.count = 0;
        block_successors(bb, *succs);
        in_loop := false;
        for s: succs if table_contains(*c.blocks_in_loop_after_folding, s) && ctf_is_edge_live(c, bb, s) { in_loop = true; break; }
        if in_loop table_set(*c.blocks_in_loop_after_folding, bb, true);
    }
}

ctf_handle_dead_exits :: (c: *Ctf) {
    if c.dead_exit_blocks.count == 0 return;
    li := c.li; l := c.l;
    preheader := li_loop_preheader(li, l);
    new_preheader := split_block(preheader, block_terminator(preheader), c.dt, li, c.mssau);
    b: Irb;
    irb_set_before(*b, block_terminator(preheader));
    i32 := type_int(32);
    dummy := irb_insert(*b, create_switch(const_int(i32, 0), new_preheader, 10));
    erase_inst(block_last(preheader));
    dummy_idx: u64 = 1;
    for bb: c.dead_exit_blocks {
        dead: [..] Value_Id; dead.allocator = temp;
        for i: block_insts(bb) { if inst_op(i) != .PHI break; array_add(*dead, i); }
        fnp := block_first_non_phi(bb);
        if fnp != NONE && inst_op(fnp) == .LANDINGPAD array_add(*dead, fnp);
        for i: dead {
            sc_forget_value(i);
            rauw_with_metadata(i, const_poison(vtype(i)));
            erase_inst_with_metadata(i);
        }
        sw_add_case(dummy, const_int(i32, dummy_idx), bb);
        dummy_idx += 1;
        array_add(*c.dt_updates, .{true, preheader, bb});
    }
    ok, ec := fn_entry_count(li.fn);
    if ok {
        w := NewArray(1 + sw_num_cases(dummy), u32,, allocator = temp);
        w[0] = 1;
        set_branch_weights(dummy, w);
    }
    outer := li_loop_for(li, preheader);
    if outer != NONE {
        still := lscfg_innermost_loop_for(li, c.live_exit_blocks, l);
        if still != outer {
            li_change_loop_for(li, new_preheader, still);
            lscfg_remove_block_from_loops(li, new_preheader, outer, still);
            blocks: [..] Value_Id; blocks.allocator = temp;
            for li_blocks(li, l) array_add(*blocks, it);
            for blocks lscfg_remove_block_from_loops(li, it, outer, still);
            li_remove_child_loop(li, outer, l);
            if still != NONE li_add_child_loop(li, still, l);
            else li_add_top_level_loop(li, l);
            fix := outer;
            while li_parent(li, fix) != still fix = li_parent(li, fix);
            if c.mssau mssau_apply_updates(c.mssau, c.dt_updates, c.dt, true);
            else dtu_apply(*c.dtu, c.dt_updates);
            c.dt_updates.count = 0;
            form_lcssa_recursively(li, fix, c.dt);
            sc_forget_block_and_loop_dispositions();
        }
    }
    if c.mssau {
        mssau_apply_updates(c.mssau, c.dt_updates, c.dt, true);
        c.dt_updates.count = 0;
        if mssa_opts.verify mssa_verify(c.mssau.mssa);
    }
}

ctf_delete_dead_loop_blocks :: (c: *Ctf) {
    li := c.li;
    if c.mssau mssau_remove_blocks(c.mssau, c.dead_loop_blocks);
    for bb: c.dead_loop_blocks {
        if !li_is_loop_header(li, bb) continue;
        dl := li_loop_for(li, bb);
        if li_parent(li, dl) != NONE {
            pl := li_parent(li, dl);
            while pl != NONE {
                blocks: [..] Value_Id; blocks.allocator = temp;
                for li_blocks(li, dl) array_add(*blocks, it);
                for blocks li_remove_block_from_loop(li, pl, it);
                pl = li_parent(li, pl);
            }
            li_remove_child_loop(li, li_parent(li, dl), dl);
            li_add_top_level_loop(li, dl);
        }
        li_erase(li, dl);
    }
    for bb: c.dead_loop_blocks li_remove_block(li, bb);
    detach_dead_blocks(c.dead_loop_blocks, *c.dt_updates, true);
    dtu_apply(*c.dtu, c.dt_updates);
    c.dt_updates.count = 0;
    for bb: c.dead_loop_blocks dtu_delete_bb(*c.dtu, bb);
}

ctf_fold_terminators :: (c: *Ctf) {
    li := c.li; l := c.l;
    succs: [..] Value_Id; succs.allocator = temp;
    for bb: c.fold_candidates {
        only := lscfg_only_live_successor(bb);
        dead_succs: [..] Value_Id; dead_succs.allocator = temp;   // SmallPtrSet<,2> (insertion order while small)
        dups: u32 = 0;
        succs.count = 0;
        block_successors(bb, *succs);
        for s: succs {
            if s != only {
                if !block_set_contains(dead_succs, s) array_add(*dead_succs, s);
                block_remove_predecessor(s, bb, !li_contains(li, l, s));
                if c.mssau mssau_remove_edge(c.mssau, bb, s);
            } else dups += 1;
        }
        preserve := !li_contains(li, l, only);
        for 1..cast(s64) dups - 1 block_remove_predecessor(only, bb, preserve);
        if c.mssau && dups > 1 mssau_remove_duplicate_phi_edges_between(c.mssau, bb, only);
        term := block_terminator(bb);
        b: Irb;
        irb_set_before(*b, term);
        irb_insert(*b, create_br(only));
        erase_inst(term);
        // LLVM iterates a SmallPtrSet<BasicBlock *, 2>: insertion order up to two entries, pointer-hash order beyond
        // (not reproducible); we keep insertion order. The DT result is the same tree, only child order can differ.
        for dead_succs array_add(*c.dt_updates, .{false, bb, it});
    }
}

ctf_run :: (c: *Ctf) -> bool {
    li := c.li; l := c.l;
    ctf_analyze(c);
    if c.has_irreducible_cfg || c.has_indirect_entry return false;
    if c.fold_candidates.count == 0 return false;
    if c.delete_current_loop return false;
    if c.blocks_in_loop_after_folding.count + c.dead_loop_blocks.count != li_blocks(li, l).count return false;
    if c.dead_exit_blocks.count && !li_is_lcssa_form(li, l, c.dt, false) return false;
    sc_forget_topmost_loop(l);
    if c.dead_loop_blocks.count sc_forget_block_and_loop_dispositions();
    ctf_handle_dead_exits(c);
    ctf_fold_terminators(c);
    if c.dead_loop_blocks.count ctf_delete_dead_loop_blocks(c);
    else {
        dtu_apply(*c.dtu, c.dt_updates);
        c.dt_updates.count = 0;
    }
    if c.mssau && mssa_opts.verify mssa_verify(c.mssau.mssa);
    return true;
}

// constantFoldTerminators
lscfg_constant_fold_terminators :: (l: Loop_Id, dt: *Dom_Tree, li: *Loop_Info, mssau: *Mssa_Updater, is_loop_deleted: *bool) -> bool {
    if !lscfg_opts.enable_term_folding return false;
    if li_loop_latch(li, l) == NONE return false;
    c: Ctf;
    c.l = l; c.li = li; c.dt = dt; c.mssau = mssau;
    c.dtu.dt = dt;
    c.rpo.allocator = temp; c.dt_updates.allocator = temp;
    c.live_loop_blocks.allocator = temp; c.dead_loop_blocks.allocator = temp;
    c.live_exit_blocks.allocator = temp; c.dead_exit_blocks.allocator = temp;
    c.blocks_in_loop_after_folding.allocator = temp; c.fold_candidates.allocator = temp;
    changed := ctf_run(*c);
    is_loop_deleted.* = changed && c.delete_current_loop;
    return changed;
}

// mergeBlocksIntoPredecessors
lscfg_merge_blocks_into_predecessors :: (l: Loop_Id, dt: *Dom_Tree, li: *Loop_Info, mssau: *Mssa_Updater) -> bool {
    changed := false;
    blocks: [..] Value_Id; blocks.allocator = temp;   // WeakTrackingVH: a merged (deleted) block is skipped
    for li_blocks(li, l) array_add(*blocks, it);
    for succ: blocks {
        if vkind(succ) != .BLOCK continue;
        pred := block_single_predecessor(succ);
        if pred == NONE || block_get_single_successor(pred) == NONE || li_loop_for(li, pred) != l continue;
        merge_block_into_predecessor(succ, dt, li, mssau);
        if mssau && mssa_opts.verify mssa_verify(mssau.mssa);
        changed = true;
    }
    if changed sc_forget_block_and_loop_dispositions();
    return changed;
}

// LoopSimplifyCFGPass::run
loop_simplifycfg_run :: (node: *Pass_Node, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved {
    se = lar.se;
    mssau_storage: Mssa_Updater;
    mssau: *Mssa_Updater;
    if lar.mssa { mssau_storage.mssa = lar.mssa; mssau = *mssau_storage; }
    deleted := false;
    // simplifyLoopCFG
    changed := lscfg_constant_fold_terminators(l, lar.dt, lar.li, mssau, *deleted);
    if !deleted {
        changed |= lscfg_merge_blocks_into_predecessors(l, lar.dt, lar.li, mssau);
        if changed sc_forget_topmost_loop(l);
    }
    if !changed return PRESERVE_ALL;
    if deleted lpm_mark_loop_as_deleted(u, l);
    pa := loop_pass_preserved();
    if lar.mssa preserve(*pa, .MEMORYSSA);
    return pa;
}
