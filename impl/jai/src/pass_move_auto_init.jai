// MoveAutoInit: port of llvm/lib/Transforms/Utils/MoveAutoInit.cpp (hasAutoInitMetadata, writeToAlloca,
// usersDominator, runMoveAutoInit, MoveAutoInitPass::run). BatchAAResults(MSSA.getAA()) is one Aa_Query over the
// MemorySSA's AA per usersDominator call.

mai_cl: struct { threshold: s64 = 128; };   // -move-auto-init-threshold

mai_has_auto_init_metadata :: (i: Value_Id) -> bool {
    m := get_metadata(i, md_fixed("annotation"));
    if m == NONE return false;
    for k: 0..cast(s64) md_nops(m) - 1 {
        o := md_op(m, cast(u32) k);
        if o != NONE && ir.mds[o].kind == .STRING && ir.mds[o].str == "auto-init" return true;
    }
    return false;
}

// writeToAlloca: (ok, location)
mai_write_to_alloca :: (i: Value_Id) -> (bool, Mem_Loc) {
    ml: Mem_Loc;
    if is_call_base(i) && is_mem_intrinsic_call(i) ml = mloc_for_dest(i);
    else if inst_op(i) == .STORE ml = mloc_get(i);
    else return false, ml;
    u := get_underlying_object(ml.ptr);
    if is_inst(u) && inst_op(u) == .ALLOCA return true, ml;
    return false, ml;
}

mai_users_dominator :: (ml: Mem_Loc, i: Value_Id, dt: *Dom_Tree, m: *Memory_SSA) -> Value_Id {
    current: Value_Id = NONE;
    ima := mssa_access_of(m, i);
    q := aa_query_new(*m.aar);
    visited: Table(s32, bool); visited.allocator = temp;
    wl: [..] s32; wl.allocator = temp;
    users: [..] s32; users.allocator = temp;
    ma_users(m, ima, *users);
    for users array_add(*wl, it);
    while wl.count {
        ma := pop(*wl);
        if table_contains(*visited, ma) continue;
        table_set(*visited, ma, true);
        if visited.count > mai_cl.threshold return NONE;
        found := false;
        if !ma_is_phi(m, ma) {
            mi := ma_inst(m, ma);
            if aa_mod_ref_inst_loc(q, mi, ml) != MR_NO && !is_lifetime_start_or_end(mi) && mi != i {
                found = true;
                current = ifx current != NONE then dt_find_nca(dt, current, inst_block(mi)) else inst_block(mi);
            }
        }
        if !found {
            ma_users(m, ma, *users);
            for users array_add(*wl, it);
        }
    }
    return current;
}

move_auto_init_run :: (f: Value_Id) -> Preserved {
    dt := get_domtree(f);
    m := get_memoryssa(f);
    entry := fn_entry(f);
    Job :: struct { i: Value_Id; bb: Value_Id; }
    jobs: [..] Job; jobs.allocator = temp;
    for i: block_insts(entry) {
        if !mai_has_auto_init_metadata(i) continue;
        ok, ml := mai_write_to_alloca(i);
        if !ok continue;
        if is_volatile(i) continue;
        ud := mai_users_dominator(ml, i, dt, m);
        if ud == NONE || ud == entry continue;
        trans: Table(Value_Id, bool); trans.allocator = temp;
        wl: [..] Value_Id; wl.allocator = temp;
        block_successors(ud, *wl);
        has_cycle := false;
        while wl.count {
            cur := pop(*wl);
            if cur == ud has_cycle = true;
            succs: [..] Value_Id; succs.allocator = temp;
            block_successors(cur, *succs);
            for s: succs {
                if table_contains(*trans, s) continue;
                table_set(*trans, s, true);
                array_add(*wl, s);
            }
        }
        if has_cycle {
            head := ud;
            while true { up := block_unique_predecessor(head); if up == NONE break; head = up; }
            if head == entry continue;
            dom_pred: Value_Id = NONE;
            preds: [..] Value_Id; preds.allocator = temp;
            block_predecessors(head, *preds);
            for p: preds {
                if table_contains(*trans, p) continue;
                if !dt_is_reachable_from_entry(dt, p) continue;
                if !dt_dominates(dt, p, head) continue;
                dom_pred = ifx dom_pred != NONE then dt_find_nca(dt, dom_pred, p) else p;
            }
            if dom_pred == NONE || dom_pred == entry continue;
            ud = dom_pred;
        }
        while inst_op(block_first_non_phi(ud)) == .CATCHSWITCH {
            preds: [..] Value_Id; preds.allocator = temp;
            block_predecessors(ud, *preds);
            for p: preds if dt_is_reachable_from_entry(dt, p) ud = dt_find_nca(dt, ud, p);
        }
        if ud != entry array_add(*jobs, .{i, ud});
    }
    if jobs.count == 0 return PRESERVE_ALL;
    mssau: Mssa_Updater;
    mssau.mssa = m;
    k := jobs.count;
    while k > 0 {
        k -= 1;
        j := jobs[k];
        iv_move_before_head(j.i, block_first_insertion_pt(j.bb), j.bb);   // moveBefore(BB, getFirstInsertionPt())
        mssau_move_to_place(*mssau, mssa_access_of(m, j.i), inst_block(j.i), .BEGINNING);
    }
    if mssa_opts.verify mssa_verify(m);
    pa := preserved_cfg();
    preserve(*pa, .DOMTREE);
    preserve(*pa, .MEMORYSSA);
    return pa;
}
