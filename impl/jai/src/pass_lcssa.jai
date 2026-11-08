// LCSSA: loop-closed SSA form.
// Port of llvm/lib/Transforms/Utils/LCSSA.cpp (formLCSSAForInstructionsImpl, computeBlocksDominatingExits,
// formLCSSAImpl, formLCSSARecursively, formLCSSAOnAllLoops, LCSSAPass) and SSAUpdater::RewriteUse
// (SSAUpdater.cpp), DbgVariableRecord::replaceVariableLocationOp (DebugProgramInstruction.cpp).
//
// LoopExitBlocks (the per-run cache of Loop::getExitBlocks) is `Lcssa_Exit_Cache`; ScalarEvolution is never
// cached here, so the SE calls are omitted.

Lcssa_Exit_Cache :: struct {
    map: Table(Loop_Id, [..] Value_Id);
}
lcssa_exit_blocks :: (c: *Lcssa_Exit_Cache, li: *Loop_Info, l: Loop_Id) -> [] Value_Id {
    if !c.map.allocator.proc c.map.allocator = temp;
    e := table_find_pointer(*c.map, l);
    if e return e.*;
    blocks: [..] Value_Id; blocks.allocator = temp;
    li_exit_blocks(li, l, *blocks);
    table_set(*c.map, l, blocks);
    return blocks;
}

// SSAUpdater::RewriteUse
ssa_rewrite_use :: (s: *Ssa_Updater, u: Use_Id) {
    user := ir.u_user[u];
    v: Value_Id;
    if inst_op(user) == .PHI v = ssa_value_at_end(s, ir.u_aux[u]);
    else v = ssa_value_in_middle(s, inst_block(user));
    use_set(u, v);
}

// dbgr_replace_variable_location_op (DbgVariableRecord::replaceVariableLocationOp) is in salvage_debug.jai

// formLCSSAForInstructionsImpl (PHIsToRemove / InsertedPHIs may be null)
form_lcssa_for_instructions :: (worklist: *[..] Value_Id, dt: *Dom_Tree, li: *Loop_Info, cache: *Lcssa_Exit_Cache,
                                phis_to_remove: *[..] Value_Id = null, inserted_phis: *[..] Value_Id = null) -> bool {
    uses_to_rewrite: [..] Use_Id; uses_to_rewrite.allocator = temp;
    local_phis_to_remove: [..] Value_Id; local_phis_to_remove.allocator = temp;   // SmallSetVector
    changed := false;
    preds: [..] Value_Id; preds.allocator = temp;
    while worklist.count {
        uses_to_rewrite.count = 0;
        i := pop(worklist);
        inst_bb := inst_block(i);
        l := li_loop_for(li, inst_bb);
        exits := lcssa_exit_blocks(cache, li, l);
        if exits.count == 0 continue;

        u := ir.v_first_use[i];
        while u != NONE {
            nx := ir.u_next[u];
            user := ir.u_user[u];
            user_bb := inst_block(user);
            if !dt_is_reachable_from_entry(dt, user_bb) {
                use_set(u, const_poison(vtype(i)));
                u = nx;
                continue;
            }
            if inst_op(user) == .PHI user_bb = ir.u_aux[u];
            if inst_bb != user_bb && !li_contains(li, l, user_bb) array_add(*uses_to_rewrite, u);
            u = nx;
        }
        if uses_to_rewrite.count == 0 continue;

        dom_bb := inst_bb;
        if inst_op(i) == .INVOKE dom_bb = get_successor(i, 0);
        dom_node := dt_node(dt, dom_bb);

        added_phis: [..] Value_Id; added_phis.allocator = temp;
        post_process: [..] Value_Id; post_process.allocator = temp;
        local_inserted: [..] Value_Id; local_inserted.allocator = temp;
        ssa: Ssa_Updater;
        ssa_init(*ssa, vtype(i), vname(i));
        ssa.inserted_phis = *local_inserted;
        has_scev := false;
        if scev_pass_se { se = scev_pass_se; has_scev = sc_is_scevable(vtype(i)) && sc_get_existing(i) != SCEV_CNC; }

        for exit_bb: exits {
            if !dt_dominates_nodes(dt, dom_node, dt_node(dt, exit_bb)) continue;
            if ssa_has_value(*ssa, exit_bb) continue;
            block_predecessors(exit_bb, *preds);
            pn := create_phi(vtype(i), cast(u32) preds.count);
            insert_at_position(pn, exit_bb, block_first(exit_bb), true);
            set_name(pn, tprint("%.lcssa", vname(i)));
            if inserted_phis array_add(inserted_phis, pn);
            copy_debug_loc(pn, i);
            for p: preds {
                phi_add_incoming(pn, i, p);
                if !li_contains(li, l, p) array_add(*uses_to_rewrite, op_use(pn, nops(pn) - 1));
            }
            array_add(*added_phis, pn);
            ssa_add_available(*ssa, exit_bb, pn);
            ol := li_loop_for(li, exit_bb);
            if ol != NONE && !li_contains_loop(li, l, ol) array_add(*post_process, pn);
            if has_scev { se = scev_pass_se; sc_get_scev(pn); }   // if (HasSCEV) SE->getSCEV(PN)
        }

        for use: uses_to_rewrite {
            user := ir.u_user[use];
            user_bb := inst_block(user);
            if inst_op(user) == .PHI user_bb = ir.u_aux[use];
            first := block_first(user_bb);
            is_exit := false;
            for exits if it == user_bb { is_exit = true; break; }
            if first != NONE && inst_op(first) == .PHI && is_exit {
                use_set(use, first);
                continue;
            }
            if added_phis.count == 1 {
                use_set(use, added_phis[0]);
                continue;
            }
            ssa_rewrite_use(*ssa, use);
        }

        // findDbgValues(I): pre-existing debug values outside the loop
        dvrs: [..] u32; dvrs.allocator = temp;
        find_dbg_users(block_fn(inst_bb), i, *dvrs, true);
        for r: dvrs {
            rec := dbgr(r);
            user_bb := inst_block(rec.owner);
            if inst_bb == user_bb || li_contains(li, l, user_bb) continue;
            v := ifx added_phis.count == 1 then added_phis[0] else ssa_lookup(*ssa, user_bb);
            if v != NONE dbgr_replace_variable_location_op(r, i, v);
        }

        for ip: local_inserted {
            ol := li_loop_for(li, inst_block(ip));
            if ol != NONE && !li_contains_loop(li, l, ol) array_add(*post_process, ip);
            if inserted_phis array_add(inserted_phis, ip);
        }
        for post_process if has_uses(it) array_add(worklist, it);
        for pn: added_phis {
            if has_uses(pn) continue;
            dup := false;
            for local_phis_to_remove if it == pn { dup = true; break; }
            if !dup array_add(*local_phis_to_remove, pn);
        }
        changed = true;
    }
    if phis_to_remove { for local_phis_to_remove array_add(phis_to_remove, it); }
    else for local_phis_to_remove if !has_uses(it) erase_inst_with_metadata(it);
    return changed;
}

// computeBlocksDominatingExits
compute_blocks_dominating_exits :: (li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree, exits: [] Value_Id, out: *[..] Value_Id) {
    work: [..] Value_Id; work.allocator = temp;
    for exits array_add(*work, it);
    seen: Table(Value_Id, bool); seen.allocator = temp;
    for out.* table_set(*seen, it, true);
    while work.count {
        b := pop(*work);
        if li_header(li, l) == b continue;
        idom := dt_idom_block(dt, b);
        if !li_contains(li, l, idom) continue;
        if table_contains(*seen, idom) continue;
        table_set(*seen, idom, true);
        array_add(out, idom);
        array_add(*work, idom);
    }
}

// formLCSSAImpl
form_lcssa_impl :: (li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree, cache: *Lcssa_Exit_Cache) -> bool {
    exits := lcssa_exit_blocks(cache, li, l);
    if exits.count == 0 return false;
    doms: [..] Value_Id; doms.allocator = temp;
    compute_blocks_dominating_exits(li, l, dt, exits, *doms);
    worklist: [..] Value_Id; worklist.allocator = temp;
    for b: doms {
        if li_loop_for(li, b) != l continue;
        for i: block_insts(b) {
            u := ir.v_first_use[i];
            if u == NONE continue;
            if ir.u_next[u] == NONE {
                user := ir.u_user[u];
                if inst_block(user) == b && inst_op(user) != .PHI continue;
            }
            if type_kind(vtype(i)) == .TOKEN continue;
            array_add(*worklist, i);
        }
    }
    return form_lcssa_for_instructions(*worklist, dt, li, cache);
}

// formLCSSA(L, DT, LI, SE)
form_lcssa :: (li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree) -> bool {
    cache: Lcssa_Exit_Cache;
    return form_lcssa_impl(li, l, dt, *cache);
}

form_lcssa_recursively_impl :: (li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree, cache: *Lcssa_Exit_Cache) -> bool {
    changed := false;
    k := 0;
    while k < li.loops[l].subloops.count {
        changed |= form_lcssa_recursively_impl(li, li.loops[l].subloops[k], dt, cache);
        k += 1;
    }
    changed |= form_lcssa_impl(li, l, dt, cache);
    return changed;
}
// formLCSSARecursively
form_lcssa_recursively :: (li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree) -> bool {
    cache: Lcssa_Exit_Cache;
    return form_lcssa_recursively_impl(li, l, dt, *cache);
}

// LCSSAPass::run
lcssa_run :: (f: Value_Id) -> Preserved {
    li := get_loop_info(f);
    dt := get_domtree(f);
    saved_se := scev_pass_se;
    scev_pass_se = cached_scev(f);   // AM.getCachedResult<ScalarEvolutionAnalysis>(F)
    defer scev_pass_se = saved_se;
    changed := false;
    k := 0;
    while k < li.top_level.count {
        changed |= form_lcssa_recursively(li, li.top_level[k], dt);
        k += 1;
    }
    if !changed return PRESERVE_ALL;
    pa := preserved_cfg();
    preserve(*pa, .MEMORYSSA);
    preserve(*pa, .SCEV);
    return pa;
}
