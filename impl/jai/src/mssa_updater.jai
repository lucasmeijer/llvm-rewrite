// MemorySSAUpdater: port of llvm/lib/Analysis/MemorySSAUpdater.cpp (the marker-based SSA updater: getPreviousDef*,
// tryRemoveTrivialPhi(s), insertUse, insertDef, fixupDefs; edge and block updates: removeEdge,
// removeDuplicatePhiEdgesBetween, applyUpdates / applyInsertUpdates, wireOldPredecessorsToNewImmediatePredecessor,
// updatePhisWhenInsertingUniqueBackedgeBlock, removeBlocks, changeToUnreachable; moving: moveTo / moveBefore /
// moveAfter / moveToPlace, moveAllAfterSpliceBlocks / moveAllAfterMergeBlocks; cloning: cloneUsesAndDefs,
// updateForClonedBlockIntoPred, updateForClonedLoop, updateExitBlocksForClonedLoop; removeMemoryAccess;
// createMemoryAccessInBB / Before / After). The whole file is ported.
//
// Value handles: LLVM keeps TrackingVH / WeakVH on accesses across operations that may RAUW or delete phis. They are
// rows of `mssa.vh` (memoryssa.jai). Every public entry point brackets itself with mssau_enter / mssau_leave; when the
// outermost one returns, all handles are released (none outlives an updater call; InsertedPHIs is cleared at the start
// of insertUse / insertDef, which are the only readers).
//
// Iteration order: applyInsertUpdates' PredMap is a pointer-keyed SmallDenseMap in LLVM; here it is iterated in
// first-insertion order (the blocks' entries are independent of each other except through BlocksWithDefsToReplace).

Mssa_Updater :: struct {
    mssa: *Memory_SSA;
    inserted_phis: [..] s32;            // SmallVector<WeakVH> InsertedPHIs (handles)
    visited_blocks: Table(Value_Id, bool);
    non_opt_phis: [..] s32;             // SmallSetVector<MemoryPhi *> NonOptPhis
    depth: s32;
    initialized: bool;
}

mssau_enter :: (u: *Mssa_Updater) {
    if !u.initialized {
        u.inserted_phis.allocator = temp; u.visited_blocks.allocator = temp; u.non_opt_phis.allocator = temp;
        u.initialized = true;
    }
    u.depth += 1;
}
mssau_leave :: (u: *Mssa_Updater) {
    u.depth -= 1;
    if u.depth == 0 { u.mssa.vh.count = 0; u.inserted_phis.count = 0; }
}

// a phi access of a block (MSSA->getMemoryAccess(BB)), -1 if none
mssau_phi_of :: (m: *Memory_SSA, b: Value_Id) -> s32 { return mssa_access_of(m, b); }

non_opt_contains :: (u: *Mssa_Updater, p: s32) -> bool { for u.non_opt_phis if it == p return true; return false; }
non_opt_insert :: (u: *Mssa_Updater, p: s32) { if !non_opt_contains(u, p) array_add(*u.non_opt_phis, p); }
non_opt_erase :: (u: *Mssa_Updater, p: s32) {
    for u.non_opt_phis if it == p { array_ordered_remove_by_index(*u.non_opt_phis, it_index); return; }
}

// CachedPreviousDef.insert({BB, Result}) (DenseMap<BasicBlock *, TrackingVH<MemoryAccess>>: no overwrite)
cache_insert :: (m: *Memory_SSA, cache: *Table(Value_Id, s32), b: Value_Id, a: s32) {
    if table_contains(cache, b) return;
    table_set(cache, b, vh_new(m, a, true));
}

// getPreviousDefRecursive
mssau_get_previous_def_recursive :: (u: *Mssa_Updater, bb: Value_Id, cache: *Table(Value_Id, s32)) -> s32 {
    m := u.mssa;
    found, h := table_find(cache, bb);
    if found return vh_get(m, h);
    if !dt_is_reachable_from_entry(m.dt, bb) return MSSA_LIVE_ON_ENTRY;
    pred := block_unique_predecessor(bb);
    if pred != NONE {
        table_set(*u.visited_blocks, bb, true);
        result := mssau_get_previous_def_from_end(u, pred, cache);
        cache_insert(m, cache, bb, result);
        return result;
    }
    if table_contains(*u.visited_blocks, bb) {
        result := mssa_create_phi(m, bb);
        cache_insert(m, cache, bb, result);
        return result;
    }
    table_set(*u.visited_blocks, bb, true);
    phi_ops: [..] s32; phi_ops.allocator = temp;     // TrackingVH handles
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    unique := true;
    single: s32 = -1;
    for p: preds {
        if dt_is_reachable_from_entry(m.dt, p) {
            inc := mssau_get_previous_def_from_end(u, p, cache);
            if single < 0 single = inc;
            else if inc != single unique = false;
            array_add(*phi_ops, vh_new(m, inc, true));
        } else array_add(*phi_ops, vh_new(m, MSSA_LIVE_ON_ENTRY, true));
    }
    phi := mssau_phi_of(m, bb);
    ops: [..] s32; ops.allocator = temp;
    for phi_ops array_add(*ops, vh_get(m, it));
    result := mssau_try_remove_trivial_phi_ops(u, phi, ops);
    if result == phi && unique && single >= 0 {
        if phi >= 0 {
            assert(ma_nops(m, phi) == 0, "Expected empty Phi");
            ma_rauw(m, phi, single);
            mssau_remove_memory_access(u, phi);
        }
        result = single;
    } else if result == phi && !(unique && single >= 0) {
        if phi < 0 phi = mssa_create_phi(m, bb);
        if ma_nops(m, phi) != 0 {
            same := true;
            for k: 0..cast(s64) ma_nops(m, phi) - 1 if mphi_value(m, phi, cast(u32) k) != vh_get(m, phi_ops[k]) { same = false; break; }
            if !same {
                for k: 0..cast(s64) ma_nops(m, phi) - 1 mphi_set_value(m, phi, cast(u32) k, vh_get(m, phi_ops[k]));
                for k: 0..cast(s64) ma_nops(m, phi) - 1 mphi_set_block(m, phi, cast(u32) k, preds[k]);
            }
        } else {
            for p, i: preds mphi_add_incoming(m, phi, vh_get(m, phi_ops[i]), p);
            array_add(*u.inserted_phis, vh_new(m, phi, false));
        }
        result = phi;
    }
    table_remove(*u.visited_blocks, bb);
    cache_insert(m, cache, bb, result);
    return result;
}

// getPreviousDef
mssau_get_previous_def :: (u: *Mssa_Updater, a: s32) -> s32 {
    local := mssau_get_previous_def_in_block(u, a);
    if local >= 0 return local;
    cache: Table(Value_Id, s32); cache.allocator = temp;
    return mssau_get_previous_def_recursive(u, u.mssa.acc[a].block, *cache);
}

// getPreviousDefInBlock
mssau_get_previous_def_in_block :: (u: *Mssa_Updater, a: s32) -> s32 {
    m := u.mssa;
    if mssa_first_block_def(m, m.acc[a].block) < 0 return -1;
    if !ma_is_use(m, a) return m.acc[a].dprev;
    x := m.acc[a].prev;
    while x >= 0 {
        if !ma_is_use(m, x) return x;
        x = m.acc[x].prev;
    }
    return -1;
}

// getPreviousDefFromEnd
mssau_get_previous_def_from_end :: (u: *Mssa_Updater, bb: Value_Id, cache: *Table(Value_Id, s32)) -> s32 {
    m := u.mssa;
    d := mssa_last_block_def(m, bb);
    if d >= 0 {
        cache_insert(m, cache, bb, d);
        return d;
    }
    return mssau_get_previous_def_recursive(u, bb, cache);
}

// recursePhi
mssau_recurse_phi :: (u: *Mssa_Updater, phi: s32) -> s32 {
    if phi < 0 return -1;
    m := u.mssa;
    res := vh_new(m, phi, true);
    users: [..] s32; users.allocator = temp;
    ma_users(m, phi, *users);
    hs: [..] s32; hs.allocator = temp;
    for users array_add(*hs, vh_new(m, it, true));
    for hs {
        x := vh_get(m, it);
        if x >= 0 && !m.acc[x].dead && ma_is_phi(m, x) mssau_try_remove_trivial_phi(u, x);
    }
    return vh_get(m, res);
}

// tryRemoveTrivialPhi(Phi)
mssau_try_remove_trivial_phi :: (u: *Mssa_Updater, phi: s32) -> s32 {
    m := u.mssa;
    ops: [..] s32; ops.allocator = temp;
    for k: 0..cast(s64) ma_nops(m, phi) - 1 array_add(*ops, mphi_value(m, phi, cast(u32) k));
    return mssau_try_remove_trivial_phi_ops(u, phi, ops);
}
// tryRemoveTrivialPhi(Phi, Operands); phi may be -1 (nullptr)
mssau_try_remove_trivial_phi_ops :: (u: *Mssa_Updater, phi: s32, ops: [] s32) -> s32 {
    m := u.mssa;
    if phi >= 0 && non_opt_contains(u, phi) return phi;
    same: s32 = -1;
    for op: ops {
        if op == phi || op == same continue;
        if same >= 0 return phi;
        same = op;
    }
    if same < 0 return MSSA_LIVE_ON_ENTRY;
    if phi >= 0 {
        ma_rauw(m, phi, same);
        mssau_remove_memory_access(u, phi);
    }
    return mssau_recurse_phi(u, same);
}

// tryRemoveTrivialPhis(ArrayRef<WeakVH>)
mssau_try_remove_trivial_phis :: (u: *Mssa_Updater, handles: [] s32) {
    m := u.mssa;
    for handles {
        p := vh_get(m, it);
        if p >= 0 && ma_is_phi(m, p) mssau_try_remove_trivial_phi(u, p);
    }
}

// insertUse
mssau_insert_use :: (u: *Mssa_Updater, mu: s32, rename_uses: bool) {
    mssau_enter(u); defer mssau_leave(u);
    m := u.mssa;
    table_reset(*u.visited_blocks);
    u.inserted_phis.count = 0;
    ma_set_defining(m, mu, mssau_get_previous_def(u, mu));
    if rename_uses && u.inserted_phis.count {
        visited: Table(Value_Id, bool); visited.allocator = temp;
        start := m.acc[mu].block;
        fd := mssa_first_block_def(m, start);
        if fd >= 0 {
            if ma_is_def(m, fd) fd = ma_defining(m, fd);
            mssa_rename_pass_from_block(m, start, fd, *visited);
        }
        for u.inserted_phis {
            p := vh_get(m, it);
            if p >= 0 mssa_rename_pass_from_block(m, m.acc[p].block, -1, *visited);
        }
    }
}

// setMemoryPhiValueForBlock
set_memory_phi_value_for_block :: (m: *Memory_SSA, mp: s32, bb: Value_Id, new_def: s32) {
    i := mphi_block_index(m, mp, bb);
    assert(i != -1, "Should have found the basic block in the phi");
    while i < ma_nops(m, mp) {
        if mphi_block(m, mp, cast(u32) i) != bb break;
        mphi_set_value(m, mp, cast(u32) i, new_def);
        i += 1;
    }
}

// insertDef
mssau_insert_def :: (u: *Mssa_Updater, md: s32, rename_uses: bool) {
    mssau_enter(u); defer mssau_leave(u);
    m := u.mssa;
    if !dt_is_reachable_from_entry(m.dt, m.acc[md].block) {
        ma_set_defining(m, md, MSSA_LIVE_ON_ENTRY);
        return;
    }
    table_reset(*u.visited_blocks);
    u.inserted_phis.count = 0;
    def_before := mssau_get_previous_def(u, md);
    def_before_same_block := false;
    if m.acc[def_before].block == m.acc[md].block {
        in_inserted := false;
        if ma_is_phi(m, def_before) for u.inserted_phis if vh_get(m, it) == def_before { in_inserted = true; break; }
        if !in_inserted def_before_same_block = true;
    }
    if def_before_same_block {
        // replaceUsesWithIf(MD, [](Use &U) { !isa<MemoryUse>(U.getUser()) && U.getUser() != MD })
        x := m.acc[def_before].first_use;
        while x >= 0 {
            nx := m.uses[x].next;
            usr := m.uses[x].user;
            if !ma_is_use(m, usr) && usr != md mu_set(m, x, md);
            x = nx;
        }
    }
    ma_set_defining(m, md, def_before);
    fixup: [..] s32; fixup.allocator = temp;     // WeakVH
    for u.inserted_phis array_add(*fixup, vh_new(m, vh_get(m, it), false));
    existing: [..] s32; existing.allocator = temp;   // SmallSet<WeakVH>
    new_phi_index := u.inserted_phis.count;
    if !def_before_same_block {
        def_set: Table(Value_Id, bool); def_set.allocator = temp;
        def_blocks: [..] Value_Id; def_blocks.allocator = temp;
        add_def_block :: (s: *Table(Value_Id, bool), l: *[..] Value_Id, b: Value_Id) { if !table_contains(s, b) { table_set(s, b, true); array_add(l, b); } }
        add_def_block(*def_set, *def_blocks, m.acc[md].block);
        for u.inserted_phis { p := vh_get(m, it); if p >= 0 && ma_is_phi(m, p) add_def_block(*def_set, *def_blocks, m.acc[p].block); }
        idf: [..] Value_Id; idf.allocator = temp;
        idf_calculate(m.dt, def_blocks, *def_set, null, *idf);
        new_inserted: [..] s32; new_inserted.allocator = temp;
        for bb: idf {
            mp := mssau_phi_of(m, bb);
            if mp < 0 {
                mp = mssa_create_phi(m, bb);
                array_add(*new_inserted, mp);
            } else {
                dup := false;
                for existing if vh_get(m, it) == mp { dup = true; break; }
                if !dup array_add(*existing, vh_new(m, mp, false));
            }
            non_opt_insert(u, mp);
        }
        preds: [..] Value_Id; preds.allocator = temp;
        for mp: new_inserted {
            block_predecessors(m.acc[mp].block, *preds);
            for p: preds {
                cache: Table(Value_Id, s32); cache.allocator = temp;
                mphi_add_incoming(m, mp, mssau_get_previous_def_from_end(u, p, *cache), p);
            }
        }
        new_phi_index = u.inserted_phis.count;
        for mp: new_inserted {
            array_add(*u.inserted_phis, vh_new(m, mp, false));
            array_add(*fixup, vh_new(m, mp, false));
        }
        array_add(*fixup, vh_new(m, md, false));
    }
    new_phi_index_end := u.inserted_phis.count;
    mssau_fixup_defs(u, fixup);
    assert(new_phi_index_end == u.inserted_phis.count, "Should not insert new phis during fixupDefs()");
    if new_phi_index_end - new_phi_index > 0 {
        sl: [] s32; sl.data = u.inserted_phis.data + new_phi_index; sl.count = new_phi_index_end - new_phi_index;
        copy: [..] s32; copy.allocator = temp;
        for sl array_add(*copy, it);
        mssau_try_remove_trivial_phis(u, copy);
    }
    if rename_uses {
        visited: Table(Value_Id, bool); visited.allocator = temp;
        start := m.acc[md].block;
        fd := mssa_first_block_def(m, start);
        if ma_is_def(m, fd) fd = ma_defining(m, fd);
        mssa_rename_pass_from_block(m, start, fd, *visited);
        for u.inserted_phis {
            p := vh_get(m, it);
            if p >= 0 && ma_is_phi(m, p) mssa_rename_pass_from_block(m, m.acc[p].block, -1, *visited);
        }
        for existing {
            p := vh_get(m, it);
            if p >= 0 && ma_is_phi(m, p) mssa_rename_pass_from_block(m, m.acc[p].block, -1, *visited);
        }
    }
}

// fixupDefs(const SmallVectorImpl<WeakVH> &Vars)
mssau_fixup_defs :: (u: *Mssa_Updater, vars: [] s32) {
    m := u.mssa;
    seen: Table(Value_Id, bool); seen.allocator = temp;
    worklist: [..] Value_Id; worklist.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    for var: vars {
        new_def := vh_get(m, var);
        if new_def < 0 continue;
        if ma_is_phi(m, new_def) non_opt_erase(u, new_def);
        nx := m.acc[new_def].dnext;
        if nx >= 0 {
            assert(ma_is_def(m, nx));
            ma_set_defining(m, nx, new_def);
            continue;
        }
        nb := m.acc[new_def].block;
        block_successors(nb, *succs);
        for s: succs {
            mp := mssau_phi_of(m, s);
            if mp >= 0 set_memory_phi_value_for_block(m, mp, nb, new_def);
            else array_add(*worklist, s);
        }
        while worklist.count {
            fb := pop(*worklist);
            fd := mssa_first_block_def(m, fb);
            if fd >= 0 {
                assert(!ma_is_phi(m, fd), "Should have already handled phi nodes!");
                ma_set_defining(m, fd, new_def);
                continue;
            }
            fsuccs: [..] Value_Id; fsuccs.allocator = temp;
            block_successors(fb, *fsuccs);
            for s: fsuccs {
                mp := mssau_phi_of(m, s);
                if mp >= 0 set_memory_phi_value_for_block(m, mp, fb, new_def);
                else {
                    if table_contains(*seen, s) continue;
                    table_set(*seen, s, true);
                    array_add(*worklist, s);
                }
            }
        }
    }
}

// removeEdge
mssau_remove_edge :: (u: *Mssa_Updater, from: Value_Id, to: Value_Id) {
    mssau_enter(u); defer mssau_leave(u);
    m := u.mssa;
    mp := mssau_phi_of(m, to);
    if mp >= 0 {
        mphi_unordered_delete_incoming_block(m, mp, from);
        mssau_try_remove_trivial_phi(u, mp);
    }
}

// removeDuplicatePhiEdgesBetween
mssau_remove_duplicate_phi_edges_between :: (u: *Mssa_Updater, from: Value_Id, to: Value_Id) {
    mssau_enter(u); defer mssau_leave(u);
    m := u.mssa;
    mp := mssau_phi_of(m, to);
    if mp < 0 return;
    found := false;
    i: s64 = 0;
    while i < ma_nops(m, mp) {
        b := mphi_block(m, mp, cast(u32) i);
        if b == from {
            if found { mphi_unordered_delete_incoming(m, mp, cast(u32) i); continue; }
            found = true;
        }
        i += 1;
    }
    mssau_try_remove_trivial_phi(u, mp);
}

// onlySingleValue
only_single_value :: (m: *Memory_SSA, mp: s32) -> s32 {
    r: s32 = -1;
    for k: 0..cast(s64) ma_nops(m, mp) - 1 {
        v := mphi_value(m, mp, cast(u32) k);
        if r < 0 r = v;
        else if r != v return -1;
    }
    return r;
}

// a PhiToDefMap and the IsInClonedRegion predicate of the cloning functions
Mssa_Clone_Ctx :: struct {
    vmap: *Table(Value_Id, Value_Id);
    phi_map: Table(s32, s32);
    region: Value_Id = NONE;                // updateForClonedBlockIntoPred: BB == CheckBB
    region_set: *Table(Value_Id, bool);     // updateForClonedLoop: Blocks.contains(BB)
}
mssa_clone_in_region :: (c: *Mssa_Clone_Ctx, bb: Value_Id) -> bool {
    if c.region_set return table_contains(c.region_set, bb);
    return bb == c.region;
}

// getNewDefiningAccessForClone
get_new_defining_access_for_clone :: (m: *Memory_SSA, a: s32, c: *Mssa_Clone_Ctx) -> s32 {
    insn_defining := a;
    if ma_is_def(m, a) {
        if is_live_on_entry(a) return a;
        di := m.acc[a].inst;
        if !mssa_clone_in_region(c, inst_block(di)) return a;
        found, nd := table_find(c.vmap, di);
        insn_defining = -1;
        if found && nd != NONE && is_inst(nd) insn_defining = mssa_access_of(m, nd);
        if insn_defining < 0 || ma_is_use(m, insn_defining)
            insn_defining = get_new_defining_access_for_clone(m, ma_defining(m, a), c);
    } else {
        found, np := table_find(*c.phi_map, a);
        if found insn_defining = np;
    }
    assert(insn_defining >= 0, "Defining instruction cannot be nullptr.");
    return insn_defining;
}

// cloneUsesAndDefs
mssau_clone_uses_and_defs :: (u: *Mssa_Updater, bb: Value_Id, new_bb: Value_Id, c: *Mssa_Clone_Ctx, clone_was_simplified: bool) {
    m := u.mssa;
    a := mssa_first_access(m, bb);
    while a >= 0 {
        nx := m.acc[a].next;
        if !ma_is_phi(m, a) {
            insn := m.acc[a].inst;
            found, ni := table_find(c.vmap, insn);
            if found && ni != NONE && is_inst(ni) {
                tk: s32 = ifx clone_was_simplified then -1 else cast(s32) m.acc[a].kind;
                na := mssa_create_defined_access(m, ni, get_new_defining_access_for_clone(m, ma_defining(m, a), c), tk, false);
                if na >= 0 mssa_insert_into_lists_for_block(m, na, new_bb, .END);
            }
        }
        a = nx;
    }
}

// updatePhisWhenInsertingUniqueBackedgeBlock
mssau_update_phis_when_inserting_unique_backedge_block :: (u: *Mssa_Updater, header: Value_Id, preheader: Value_Id, be: Value_Id) {
    mssau_enter(u); defer mssau_leave(u);
    m := u.mssa;
    mp := mssau_phi_of(m, header);
    if mp < 0 return;
    np := mssa_create_phi(m, be);
    for i: 0..cast(s64) ma_nops(m, mp) - 1 {
        ibb := mphi_block(m, mp, cast(u32) i);
        iv := mphi_value(m, mp, cast(u32) i);
        if ibb != preheader mphi_add_incoming(m, np, iv, ibb);
    }
    acc_from_ph := mphi_value_for_block(m, mp, preheader);
    mphi_set_value(m, mp, 0, acc_from_ph);
    mphi_set_block(m, mp, 0, preheader);
    i := cast(s64) ma_nops(m, mp) - 1;
    while i >= 1 { mphi_unordered_delete_incoming(m, mp, cast(u32) i); i -= 1; }
    mphi_add_incoming(m, mp, np, be);
    mssau_try_remove_trivial_phi(u, np);
}

// updateForClonedBlockIntoPred
mssau_update_for_cloned_block_into_pred :: (u: *Mssa_Updater, bb: Value_Id, p1: Value_Id, vm: *Table(Value_Id, Value_Id)) {
    mssau_enter(u); defer mssau_leave(u);
    m := u.mssa;
    c: Mssa_Clone_Ctx;
    c.vmap = vm; c.region = bb; c.phi_map.allocator = temp;
    mp := mssau_phi_of(m, bb);
    if mp >= 0 table_set(*c.phi_map, mp, mphi_value_for_block(m, mp, p1));
    mssau_clone_uses_and_defs(u, bb, p1, *c, true);
}

// updateForClonedLoop(LoopBlocks, ExitBlocks, VMap, IgnoreIncomingWithNoClones). `loop_blocks` is the LoopBlocksRPO
// order. VMap values that were erased since (WeakTrackingVH = null) read as absent.
mssau_update_for_cloned_loop :: (u: *Mssa_Updater, loop_blocks: [] Value_Id, exit_blocks: [] Value_Id, vm: *Table(Value_Id, Value_Id),
                                 ignore_incoming_with_no_clones: bool) {
    mssau_enter(u); defer mssau_leave(u);
    m := u.mssa;
    blocks: [..] Value_Id; blocks.allocator = temp;           // SmallSetVector
    in_set: Table(Value_Id, bool); in_set.allocator = temp;
    for loop_blocks if !table_contains(*in_set, it) { table_set(*in_set, it, true); array_add(*blocks, it); }
    for exit_blocks if !table_contains(*in_set, it) { table_set(*in_set, it, true); array_add(*blocks, it); }
    c: Mssa_Clone_Ctx;
    c.vmap = vm; c.region_set = *in_set; c.phi_map.allocator = temp;
    lookup_block :: (vm: *Table(Value_Id, Value_Id), b: Value_Id) -> Value_Id {
        found, nb := table_find(vm, b);
        if !found || nb == NONE || vkind(nb) != .BLOCK return NONE;
        return nb;
    }
    // ProcessBlock
    for bb: blocks {
        nb := lookup_block(vm, bb);
        if nb == NONE continue;
        assert(mssa_first_access(m, nb) < 0, "Cloned block should have no accesses");
        mp := mssau_phi_of(m, bb);
        if mp >= 0 {
            np := mssa_create_phi(m, nb);
            table_set(*c.phi_map, mp, np);
        }
        mssau_clone_uses_and_defs(u, bb, nb, *c, false);
    }
    preds: [..] Value_Id; preds.allocator = temp;
    for bb: blocks {
        mp := mssau_phi_of(m, bb);
        if mp < 0 continue;
        found, np := table_find(*c.phi_map, mp);
        if !found || np < 0 continue;
        // FixPhiIncomingValues(MPhi, NewPhi)
        new_bb := m.acc[np].block;
        block_predecessors(new_bb, *preds);
        n := ma_nops(m, mp);
        for k: 0..cast(s64) n - 1 {
            inc := mphi_value(m, mp, cast(u32) k);
            inc_bb := mphi_block(m, mp, cast(u32) k);
            nib := lookup_block(vm, inc_bb);
            if nib != NONE inc_bb = nib;
            else if ignore_incoming_with_no_clones continue;
            is_pred := false;
            for preds if it == inc_bb { is_pred = true; break; }
            if !is_pred continue;
            mphi_add_incoming(m, np, get_new_defining_access_for_clone(m, inc, *c), inc_bb);
        }
        single := only_single_value(m, np);
        if single >= 0 {
            table_set(*c.phi_map, mp, single);
            mssau_remove_memory_access(u, np);
        }
    }
}

// updateExitBlocksForClonedLoop(ExitBlocks, VMaps, DT)
mssau_update_exit_blocks_for_cloned_loop :: (u: *Mssa_Updater, exit_blocks: [] Value_Id, vms: [] *Table(Value_Id, Value_Id), dt: *Dom_Tree) {
    mssau_enter(u); defer mssau_leave(u);
    updates: [..] Dom_Update; updates.allocator = temp;
    for e: exit_blocks for vm: vms {
        found, ne := table_find(vm, e);
        if !found || ne == NONE || vkind(ne) != .BLOCK continue;
        array_add(*updates, .{true, ne, get_successor(block_terminator(ne), 0)});
    }
    gd: Graph_Diff;
    empty: [] Dom_Update;
    gd_init(*gd, empty, false, false);
    mssau_apply_insert_updates(u, updates, dt, *gd);
}

// applyUpdates(Updates, DT, UpdateDT)
mssau_apply_updates :: (u: *Mssa_Updater, updates: [] Dom_Update, dt: *Dom_Tree, update_dt: bool) {
    mssau_enter(u); defer mssau_leave(u);
    dels: [..] Dom_Update; dels.allocator = temp;
    rev_dels: [..] Dom_Update; rev_dels.allocator = temp;
    ins: [..] Dom_Update; ins.allocator = temp;
    for updates {
        if it.insert array_add(*ins, .{true, it.from, it.to});
        else { array_add(*dels, .{false, it.from, it.to}); array_add(*rev_dels, .{true, it.from, it.to}); }
    }
    if dels.count {
        if ins.count {
            empty: [] Dom_Update;
            if !update_dt dt_apply_updates_post_view(dt, empty, rev_dels);
            else dt_apply_updates_post_view(dt, updates, rev_dels);
            gd: Graph_Diff;
            gd_init(*gd, rev_dels, false, false);
            mssau_apply_insert_updates(u, ins, dt, *gd);
            dt_apply_updates(dt, dels);
        } else {
            if update_dt dt_apply_updates(dt, dels);
        }
    } else {
        if update_dt dt_apply_updates(dt, updates);
        gd: Graph_Diff;
        empty: [] Dom_Update;
        gd_init(*gd, empty, false, false);
        mssau_apply_insert_updates(u, ins, dt, *gd);
    }
    for dels mssau_remove_edge(u, it.from, it.to);
}

// applyInsertUpdates(Updates, DT, GD)
mssau_apply_insert_updates :: (u: *Mssa_Updater, updates: [] Dom_Update, dt: *Dom_Tree, gd: *Graph_Diff) {
    mssau_enter(u); defer mssau_leave(u);
    m := u.mssa;
    get_last_def :: (m: *Memory_SSA, dt: *Dom_Tree, gd: *Graph_Diff, bb_in: Value_Id) -> s32 {
        bb := bb_in;
        ch: [..] Value_Id; ch.allocator = temp;
        while true {
            d := mssa_last_block_def(m, bb);
            if d >= 0 return d;
            gd_children(gd, bb, true, *ch);
            count := min(ch.count, 2);
            if count != 1 {
                n := dt_node(dt, bb);
                if n < 0 return MSSA_LIVE_ON_ENTRY;
                idom := dt_idom(dt, n);
                if idom >= 0 && dt.nodes[idom].block != bb { bb = dt.nodes[idom].block; continue; }
                return MSSA_LIVE_ON_ENTRY;
            } else {
                if dt_node(dt, bb) < 0 return MSSA_LIVE_ON_ENTRY;
                bb = ch[0];
            }
        }
        return MSSA_LIVE_ON_ENTRY;
    }
    Pred_Info :: struct { bb: Value_Id; added: [..] Value_Id; prev: [..] Value_Id; removed: bool; }
    pred_map: [..] Pred_Info; pred_map.allocator = temp;
    find_pi :: (pm: *[..] Pred_Info, b: Value_Id) -> s64 { for pm.* if it.bb == b && !it.removed return it_index; return -1; }
    set_add :: (l: *[..] Value_Id, b: Value_Id) { for l.* if it == b return; array_add(l, b); }
    set_has :: (l: [] Value_Id, b: Value_Id) -> bool { for l if it == b return true; return false; }
    for e: updates {
        k := find_pi(*pred_map, e.to);
        if k < 0 {
            pi: Pred_Info; pi.bb = e.to; pi.added.allocator = temp; pi.prev.allocator = temp;
            array_add(*pred_map, pi);
            k = pred_map.count - 1;
        }
        set_add(*pred_map[k].added, e.from);
    }
    edge_count: Table(u64, s64); edge_count.allocator = temp;
    ek :: (a: Value_Id, b: Value_Id) -> u64 { return ((cast(u64) a) << 32) | cast(u64) b; }
    ch: [..] Value_Id; ch.allocator = temp;
    new_blocks: [..] Value_Id; new_blocks.allocator = temp;
    for * pi: pred_map {
        gd_children(gd, pi.bb, true, *ch);
        for p: ch {
            if !set_has(pi.added, p) set_add(*pi.prev, p);
            _, c := table_find(*edge_count, ek(p, pi.bb));
            table_set(*edge_count, ek(p, pi.bb), c + 1);
        }
        if pi.prev.count == 0 {
            assert(pi.added.count == 1, "Can only handle adding one predecessor to a new block.");
            array_add(*new_blocks, pi.bb);
        }
    }
    for nb: new_blocks for * pred_map if it.bb == nb it.removed = true;
    blocks_with_defs_to_replace: [..] Value_Id; blocks_with_defs_to_replace.allocator = temp;
    inserted: [..] s32; inserted.allocator = temp;   // WeakVH
    for e: updates {
        if find_pi(*pred_map, e.to) >= 0 && mssau_phi_of(m, e.to) < 0 array_add(*inserted, vh_new(m, mssa_create_phi(m, e.to), false));
    }
    for * pi: pred_map {
        if pi.removed continue;
        bb := pi.bb;
        assert(pi.prev.count > 0, "At least one previous predecessor must exist.");
        last_def_added: [..] s32; last_def_added.allocator = temp;   // parallel to pi.added
        for ap: pi.added array_add(*last_def_added, get_last_def(m, dt, gd, ap));
        np := mssau_phi_of(m, bb);
        if ma_nops(m, np) {
            for p, i: pi.added {
                _, c := table_find(*edge_count, ek(p, bb));
                for 0..c-1 mphi_add_incoming(m, np, last_def_added[i], p);
            }
        } else {
            p1 := pi.prev[0];
            def_p1 := get_last_def(m, dt, gd, p1);
            insert_phi := false;
            for last_def_added if def_p1 != it { insert_phi = true; break; }
            if !insert_phi {
                ma_rauw(m, np, def_p1);
                mssau_remove_memory_access(u, np);
                continue;
            }
            for p, i: pi.added {
                _, c := table_find(*edge_count, ek(p, bb));
                for 0..c-1 mphi_add_incoming(m, np, last_def_added[i], p);
            }
            for p: pi.prev {
                _, c := table_find(*edge_count, ek(p, bb));
                for 0..c-1 mphi_add_incoming(m, np, def_p1, p);
            }
        }
        // FindNearestCommonDominator(PrevBlockSet)
        prev_idom := pi.prev[0];
        for pi.prev prev_idom = dt_find_nca(dt, prev_idom, it);
        new_idom := dt.nodes[dt_idom(dt, dt_node(dt, bb))].block;
        // GetNoLongerDomBlocks
        if prev_idom != new_idom {
            array_add(*blocks_with_defs_to_replace, prev_idom);
            next := prev_idom;
            while true {
                upn := dt_idom(dt, dt_node(dt, next));
                if upn < 0 break;
                up := dt.nodes[upn].block;
                if up == NONE || up == new_idom break;
                array_add(*blocks_with_defs_to_replace, up);
                next = up;
            }
        }
    }
    mssau_try_remove_trivial_phis(u, inserted);
    to_process: [..] Value_Id; to_process.allocator = temp;
    for inserted { p := vh_get(m, it); if p >= 0 && ma_is_phi(m, p) array_add(*to_process, m.acc[p].block); }
    if to_process.count {
        def_set: Table(Value_Id, bool); def_set.allocator = temp;
        def_blocks: [..] Value_Id; def_blocks.allocator = temp;
        for to_process if !table_contains(*def_set, it) { table_set(*def_set, it, true); array_add(*def_blocks, it); }
        idf: [..] Value_Id; idf.allocator = temp;
        idf_calculate(dt, def_blocks, *def_set, null, *idf, gd);
        to_fill: [..] s32; to_fill.allocator = temp;
        for bb: idf {
            if mssau_phi_of(m, bb) < 0 {
                p := mssa_create_phi(m, bb);
                array_add(*inserted, vh_new(m, p, false));
                array_add(*to_fill, p);
            }
        }
        for bb: idf {
            p := mssau_phi_of(m, bb);
            assert(p >= 0, "Phi must exist");
            filling := false;
            for to_fill if it == p { filling = true; break; }
            if !filling {
                for i: 0..cast(s64) ma_nops(m, p) - 1 mphi_set_value(m, p, cast(u32) i, get_last_def(m, dt, gd, mphi_block(m, p, cast(u32) i)));
            } else {
                gd_children(gd, bb, true, *ch);
                for pi: ch mphi_add_incoming(m, p, get_last_def(m, dt, gd, pi), pi);
            }
        }
    }
    for bw: blocks_with_defs_to_replace {
        d := mssa_first_block_def(m, bw);
        while d >= 0 {
            dominating := m.acc[d].block;
            reset_opt: [..] s32; reset_opt.allocator = temp;
            x := m.acc[d].first_use;
            while x >= 0 {
                nx := m.uses[x].next;
                usr := m.uses[x].user;
                if ma_is_phi(m, usr) {
                    dominated := m.uses[x].blk;
                    if !dt_dominates(dt, dominating, dominated) mu_set(m, x, get_last_def(m, dt, gd, dominated));
                } else {
                    dominated := m.acc[usr].block;
                    if !dt_dominates(dt, dominating, dominated) {
                        dp := mssau_phi_of(m, dominated);
                        if dp >= 0 mu_set(m, x, dp);
                        else {
                            idn := dt_idom(dt, dt_node(dt, dominated));
                            assert(idn >= 0, "Block must have a valid IDom.");
                            mu_set(m, x, get_last_def(m, dt, gd, dt.nodes[idn].block));
                        }
                        array_add(*reset_opt, usr);
                    }
                }
                x = nx;
            }
            for reset_opt ma_reset_optimized(m, it);
            d = m.acc[d].dnext;
        }
    }
    mssau_try_remove_trivial_phis(u, inserted);
}

// moveTo(What, BB, Where): where >= 0 = before that access (or -1 = end of the list) when !use_place; else Point
mssau_move_to :: (u: *Mssa_Updater, what: s32, bb: Value_Id, where: s32, use_place := false, place := Mssa_Insertion_Place.END) {
    mssau_enter(u); defer mssau_leave(u);
    m := u.mssa;
    users: [..] s32; users.allocator = temp;
    ma_users(m, what, *users);
    for users if ma_is_phi(m, it) non_opt_insert(u, it);
    ma_rauw(m, what, ma_defining(m, what));
    if use_place mssa_move_to_place(m, what, bb, place);
    else mssa_move_to_before(m, what, bb, where);
    if ma_is_def(m, what) mssau_insert_def(u, what, true);
    else mssau_insert_use(u, what, true);
    u.non_opt_phis.count = 0;
}
// moveBefore(What, Where)
mssau_move_before :: (u: *Mssa_Updater, what: s32, where: s32) { mssau_move_to(u, what, u.mssa.acc[where].block, where); }
// moveAfter(What, Where)
mssau_move_after :: (u: *Mssa_Updater, what: s32, where: s32) { mssau_move_to(u, what, u.mssa.acc[where].block, u.mssa.acc[where].next); }
// moveToPlace(What, BB, Where)
mssau_move_to_place :: (u: *Mssa_Updater, what: s32, bb: Value_Id, place: Mssa_Insertion_Place) {
    if place != .BEFORE_TERMINATOR { mssau_move_to(u, what, bb, -1, true, place); return; }
    t := mssa_access_of(u.mssa, block_terminator(bb));
    if t >= 0 mssau_move_before(u, what, t);
    else mssau_move_to(u, what, bb, -1, true, .END);
}
// MSSAU->moveToPlace(MUD of PredBB's terminator, PredBB, End) after MergeBlockIntoPredecessor moved the terminator
mssau_move_terminator_to_end :: (u: *Mssa_Updater, b: Value_Id) {
    a := mssa_access_of(u.mssa, block_terminator(b));
    if a >= 0 mssau_move_to_place(u, a, b, .END);
}

// moveAllAccesses(From, To, Start)
mssau_move_all_accesses :: (u: *Mssa_Updater, from: Value_Id, to: Value_Id, start: Value_Id) {
    m := u.mssa;
    if mssa_first_access(m, from) < 0 return;
    assert(inst_block(start) == to, "Incorrect Start instruction");
    first: s32 = -1;
    i := start;
    while i != NONE {
        first = mssa_access_of(m, i);
        if first >= 0 break;
        i = inst_next(i);
    }
    if first >= 0 {
        mud := first;
        while mud >= 0 {
            nx := m.acc[mud].next;
            mssa_move_to_place(m, mud, to, .END);
            mud = nx;
        }
    }
    d := mssa_first_block_def(m, from);
    if d >= 0 && ma_is_phi(m, d) mssau_try_remove_trivial_phi(u, d);
}
// moveAllAfterSpliceBlocks
mssau_move_all_after_splice_blocks :: (u: *Mssa_Updater, from: Value_Id, to: Value_Id, start: Value_Id) {
    mssau_enter(u); defer mssau_leave(u);
    m := u.mssa;
    assert(mssa_first_access(m, to) < 0, "To block is expected to be free of MemoryAccesses.");
    mssau_move_all_accesses(u, from, to, start);
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(to, *succs);
    for s: succs {
        mp := mssau_phi_of(m, s);
        if mp >= 0 mphi_set_block(m, mp, cast(u32) mphi_block_index(m, mp, from), to);
    }
}
// moveAllAfterMergeBlocks
mssau_move_all_after_merge_blocks :: (u: *Mssa_Updater, from: Value_Id, to: Value_Id, start: Value_Id) {
    mssau_enter(u); defer mssau_leave(u);
    m := u.mssa;
    mssau_move_all_accesses(u, from, to, start);
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(from, *succs);
    for s: succs {
        mp := mssau_phi_of(m, s);
        if mp >= 0 mphi_set_block(m, mp, cast(u32) mphi_block_index(m, mp, from), to);
    }
}

// wireOldPredecessorsToNewImmediatePredecessor(Old, New, Preds, IdenticalEdgesWereMerged = true)
mssau_wire_old_predecessors_to_new_immediate_predecessor :: (u: *Mssa_Updater, old: Value_Id, new: Value_Id, preds: [] Value_Id, identical_edges := true) {
    mssau_enter(u); defer mssau_leave(u);
    m := u.mssa;
    assert(mssa_first_access(m, new) < 0, "Access list should be null for a new block.");
    phi := mssau_phi_of(m, old);
    if phi < 0 return;
    op: [..] Value_Id; op.allocator = temp;
    block_predecessors(old, *op);
    if op.count == 1 {
        mssa_move_to_place(m, phi, new, .BEGINNING);
    } else {
        np := mssa_create_phi(m, new);
        set: [..] Value_Id; set.allocator = temp;
        for preds { dup := false; for x: set if x == it { dup = true; break; } if !dup array_add(*set, it); }
        // unorderedDeleteIncomingIf
        i: s64 = 0;
        while i < ma_nops(m, phi) {
            b := mphi_block(m, phi, cast(u32) i);
            k := -1;
            for set if it == b { k = it_index; break; }
            if k >= 0 {
                mphi_add_incoming(m, np, mphi_value(m, phi, cast(u32) i), b);
                if !identical_edges array_ordered_remove_by_index(*set, k);
                mphi_unordered_delete_incoming(m, phi, cast(u32) i);
                continue;
            }
            i += 1;
        }
        mphi_add_incoming(m, phi, np, new);
        mssau_try_remove_trivial_phi(u, np);
    }
}

// removeMemoryAccess(MA, OptimizePhis)
mssau_remove_memory_access :: (u: *Mssa_Updater, a: s32, optimize_phis := false) {
    mssau_enter(u); defer mssau_leave(u);
    m := u.mssa;
    assert(!is_live_on_entry(a), "Trying to remove the live on entry def");
    new_def: s32;
    if ma_is_phi(m, a) {
        new_def = only_single_value(m, a);
        assert(new_def >= 0 || !ma_has_uses(m, a), "We can't delete this memory phi");
    } else new_def = ma_defining(m, a);
    phis_to_check: [..] s32; phis_to_check.allocator = temp;
    if !ma_is_use(m, a) && ma_has_uses(m, a) {
        vh_rauw(m, a, new_def);
        assert(new_def != a, "Going into an infinite loop");
        while ma_has_uses(m, a) {
            x := m.acc[a].first_use;
            usr := m.uses[x].user;
            if !ma_is_phi(m, usr) ma_reset_optimized(m, usr);
            if optimize_phis && ma_is_phi(m, usr) {
                dup := false;
                for phis_to_check if it == usr { dup = true; break; }
                if !dup array_add(*phis_to_check, usr);
            }
            mu_set(m, x, new_def);
        }
    }
    mssa_remove_from_lookups(m, a);
    mssa_remove_from_lists(m, a);
    if phis_to_check.count {
        hs: [..] s32; hs.allocator = temp;
        for phis_to_check array_add(*hs, vh_new(m, it, false));
        n := hs.count;
        while n > 0 {
            n -= 1;
            p := vh_get(m, pop(*hs));
            if p >= 0 mssau_try_remove_trivial_phi(u, p);
        }
    }
}
// removeMemoryAccess(const Instruction *I, OptimizePhis)
mssau_remove_memory_access_inst :: (u: *Mssa_Updater, i: Value_Id, optimize_phis := false) {
    a := mssa_access_of(u.mssa, i);
    if a >= 0 mssau_remove_memory_access(u, a, optimize_phis);
}

// removeBlocks(DeadBlocks)
mssau_remove_blocks :: (u: *Mssa_Updater, dead: [] Value_Id) {
    mssau_enter(u); defer mssau_leave(u);
    m := u.mssa;
    is_dead :: (dead: [] Value_Id, b: Value_Id) -> bool { for dead if it == b return true; return false; }
    succs: [..] Value_Id; succs.allocator = temp;
    for bb: dead {
        block_successors(bb, *succs);
        for s: succs {
            if is_dead(dead, s) continue;
            mp := mssau_phi_of(m, s);
            if mp >= 0 {
                mphi_unordered_delete_incoming_block(m, mp, bb);
                mssau_try_remove_trivial_phi(u, mp);
            }
        }
        a := mssa_first_access(m, bb);
        while a >= 0 { ma_drop_all_references(m, a); a = m.acc[a].next; }
    }
    for bb: dead {
        a := mssa_first_access(m, bb);
        while a >= 0 {
            nx := m.acc[a].next;
            mssa_remove_from_lookups(m, a);
            mssa_remove_from_lists(m, a);
            a = nx;
        }
    }
}

// changeToUnreachable(I)
mssau_change_to_unreachable :: (u: *Mssa_Updater, i: Value_Id) {
    mssau_enter(u); defer mssau_leave(u);
    m := u.mssa;
    bb := inst_block(i);
    x := i;
    while x != NONE { nx := inst_next(x); mssau_remove_memory_access_inst(u, x); x = nx; }
    updated: [..] s32; updated.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb, *succs);
    for s: succs {
        mssau_remove_duplicate_phi_edges_between(u, bb, s);
        mp := mssau_phi_of(m, s);
        if mp >= 0 {
            mphi_unordered_delete_incoming_block(m, mp, bb);
            array_add(*updated, vh_new(m, mp, false));
        }
    }
    mssau_try_remove_trivial_phis(u, updated);
}

// createMemoryAccessInBB(I, Definition, BB, Point, CreationMustSucceed)
mssau_create_memory_access_in_bb :: (u: *Mssa_Updater, i: Value_Id, definition: s32, bb: Value_Id, point: Mssa_Insertion_Place, must_succeed := true) -> s32 {
    m := u.mssa;
    a := mssa_create_defined_access(m, i, definition, -1, must_succeed);
    if a >= 0 mssa_insert_into_lists_for_block(m, a, bb, point);
    return a;
}
// createMemoryAccessBefore(I, Definition, InsertPt)
mssau_create_memory_access_before :: (u: *Mssa_Updater, i: Value_Id, definition: s32, insert_pt: s32) -> s32 {
    m := u.mssa;
    a := mssa_create_defined_access(m, i, definition);
    mssa_insert_into_lists_before(m, a, m.acc[insert_pt].block, insert_pt);
    return a;
}
// createMemoryAccessAfter(I, Definition, InsertPt)
mssau_create_memory_access_after :: (u: *Mssa_Updater, i: Value_Id, definition: s32, insert_pt: s32) -> s32 {
    m := u.mssa;
    a := mssa_create_defined_access(m, i, definition);
    mssa_insert_into_lists_before(m, a, m.acc[insert_pt].block, m.acc[insert_pt].next);
    return a;
}
