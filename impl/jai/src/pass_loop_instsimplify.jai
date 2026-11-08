// LoopInstSimplify: llvm/lib/Transforms/Scalar/LoopInstSimplify.cpp (complete), with
// RecursivelyDeleteTriviallyDeadInstructions(DeadInsts, TLI, MSSAU) (llvm/lib/Transforms/Utils/Local.cpp).

// RecursivelyDeleteTriviallyDeadInstructions(SmallVectorImpl<WeakTrackingVH> &, TLI, MSSAU): entries are popped from
// the back; deleted entries (WeakTrackingVH = null) are skipped. Every entry must be trivially dead.
recursively_delete_trivially_dead_list :: (dead: *[..] Value_Id, mssau: *Mssa_Updater) {
    while dead.count {
        i := pop(dead);
        if i == NONE || vkind(i) == .DEAD continue;
        salvage_debug_info(i);
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            o := op(i, cast(u32) k);
            set_op(i, cast(u32) k, NONE);
            if o == NONE || has_uses(o) continue;
            if is_inst(o) && is_instruction_trivially_dead_tli(o, true) array_add(dead, o);
        }
        if mssau mssau_remove_memory_access_inst(mssau, i);
        erase_inst_with_metadata(i);
    }
}

// simplifyLoopInst
simplify_loop_inst :: (l: Loop_Id, dt: *Dom_Tree, li: *Loop_Info, ac: *Assumption_Cache, mssau: *Mssa_Updater) -> bool {
    sq: Simplify_Query;   // SimplifyQuery(DL, &TLI, &DT, &AC)
    sq.dt = dt; sq.ac = ac;
    s1: Table(Value_Id, bool); s1.allocator = temp;
    s2: Table(Value_Id, bool); s2.allocator = temp;
    to_simplify := *s1; next := *s2;
    visited_phis: Table(Value_Id, bool); visited_phis.allocator = temp;
    dead: [..] Value_Id; dead.allocator = temp;
    rpo: [..] Value_Id; rpo.allocator = temp;
    loop_blocks_rpo(li, l, *rpo);
    mssa := ifx mssau then mssau.mssa else null;
    changed := false;
    while true {
        if mssau && mssa_opts.verify mssa_verify(mssa);
        for bb: rpo for i: block_insts(bb) {
            if inst_op(i) == .PHI table_set(*visited_phis, i, true);
            if !has_uses(i) {
                if is_instruction_trivially_dead_tli(i, true) array_add(*dead, i);
                continue;
            }
            is_first_iteration := to_simplify.count == 0;
            if !is_first_iteration && !table_contains(to_simplify, i) continue;
            v := simplify_instruction(i, sq_with_instruction(sq, i));
            if v == NONE || !li_replacement_preserves_lcssa_form(li, i, v) continue;
            u := ir.v_first_use[i];
            while u != NONE {
                nx := ir.u_next[u];
                user := ir.u_user[u];
                use_set(u, v);
                u = nx;
                if !dt_is_reachable_from_entry(dt, inst_block(user)) continue;
                if inst_op(user) == .PHI && table_contains(*visited_phis, user) {
                    table_set(next, user, true);
                    continue;
                }
                if !is_first_iteration && li_contains(li, l, inst_block(user)) table_set(to_simplify, user, true);
            }
            if mssau && is_inst(v) {
                ma := mssa_access_of(mssa, i);
                if ma >= 0 {
                    rma := mssa_access_of(mssa, v);
                    if rma >= 0 ma_rauw(mssa, ma, rma);
                }
            }
            if is_instruction_trivially_dead_tli(i, true) array_add(*dead, i);
            changed = true;
        }
        if dead.count {
            changed = true;
            recursively_delete_trivially_dead_list(*dead, mssau);
        }
        if mssau && mssa_opts.verify mssa_verify(mssa);
        if next.count == 0 break;
        x := next; next = to_simplify; to_simplify = x;
        table_reset(next);
        table_reset(*visited_phis);
        dead.count = 0;
    }
    return changed;
}

// LoopInstSimplifyPass::run
loop_instsimplify_run :: (node: *Pass_Node, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved {
    mssau_storage: Mssa_Updater;
    mssau: *Mssa_Updater;
    if lar.mssa {
        mssau_storage.mssa = lar.mssa; mssau = *mssau_storage;
        if mssa_opts.verify mssa_verify(lar.mssa);
    }
    if !simplify_loop_inst(l, lar.dt, lar.li, lar.ac, mssau) return PRESERVE_ALL;
    pa := loop_pass_preserved();
    pa.cfg = true;
    if lar.mssa preserve(*pa, .MEMORYSSA);
    return pa;
}
