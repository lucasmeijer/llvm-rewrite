// UnifyLoopExitsPass: a port of llvm/lib/Transforms/Utils/UnifyLoopExits.cpp (complete; the ControlFlowHub is in
// control_flow_utils.jai).

ule_max_booleans_in_control_flow_hub: s64 = 32;   // -max-booleans-in-control-flow-hub

// restoreSSA
ule_restore_ssa :: (dt: *Dom_Tree, li: *Loop_Info, l: Loop_Id, incoming: [] Value_Id, loop_exit_block: Value_Id) {
    // MapVector<Instruction *, SmallVector<Instruction *>>
    Ext :: struct { def: Value_Id; users: [..] Value_Id; }
    external: [..] Ext; external.allocator = temp;
    for bb: li_blocks(li, l) {
        for i: block_insts(bb) {
            u := ir.v_first_use[i];
            idx := -1;
            while u != NONE {
                user := ir.u_user[u];
                u = ir.u_next[u];
                assert(is_inst(user), "non-instruction user of an instruction");
                ub := inst_block(user);
                if ub == loop_exit_block continue;
                if li_contains(li, l, ub) continue;
                if idx < 0 {
                    for external if it.def == i { idx = it_index; break; }
                    if idx < 0 {
                        e: Ext; e.def = i; e.users.allocator = temp;
                        array_add(*external, e);
                        idx = external.count - 1;
                    }
                }
                array_add(*external[idx].users, user);
            }
        }
    }
    for * ii: external {
        def := ii.def;
        new_phi := create_phi(vtype(def), cast(u32) incoming.count);
        insert_at_position(new_phi, loop_exit_block, block_first(loop_exit_block), true);
        set_name(new_phi, tconcat(vname(def), ".moved"));
        for in: incoming {
            if inst_block(def) == in || dt_dominates_inst_block(dt, def, in) phi_add_incoming(new_phi, def, in);
            else phi_add_incoming(new_phi, const_poison(vtype(def)), in);
        }
        for u: ii.users replace_uses_of_with(u, def, new_phi);
    }
}

// unifyLoopExits
ule_unify_loop_exits :: (dt: *Dom_Tree, li: *Loop_Info, l: Loop_Id) -> bool {
    exiting: [..] Value_Id; exiting.allocator = temp;
    li_exiting_blocks(li, l, *exiting);
    if exiting.count == 0 return false;
    callbr_targets_to_fix: [..] Value_Id; callbr_targets_to_fix.allocator = temp;
    hub: Cfh;
    changed := false;
    num_exiting := exiting.count;
    for k: 0..num_exiting - 1 {
        bb := exiting[k];
        t := block_terminator(bb);
        if inst_op(t) == .BR {
            s0 := get_successor(t, 0);
            if li_contains(li, l, s0) s0 = NONE;
            cfh_add_branch(*hub, bb, s0);
        } else if inst_op(t) == .CONDBR {
            s0 := get_successor(t, 0);
            if li_contains(li, l, s0) s0 = NONE;
            s1 := get_successor(t, 1);
            if li_contains(li, l, s1) s1 = NONE;
            cfh_add_branch(*hub, bb, s0, s1);
        } else if inst_op(t) == .CALLBR {
            // SmallDenseMap<BasicBlock *, BasicBlock *> CallBrTargets: lookups only
            Pair :: struct { succ: Value_Id; target: Value_Id; }
            targets: [..] Pair; targets.allocator = temp;
            n := num_successors(t);
            for j: 0..n - 1 {
                succ := get_successor(t, j);
                if li_contains(li, l, succ) continue;
                existing: Value_Id = NONE;
                for targets if it.succ == succ { existing = it.target; break; }
                new_succ, updated_li := split_call_br_edge(bb, succ, j, existing, dt, null, li);
                if existing == NONE {
                    changed = true;
                    if !updated_li array_add(*callbr_targets_to_fix, new_succ);
                    if targets.count == 0 exiting[k] = new_succ;
                    else array_add(*exiting, new_succ);
                    cfh_add_branch(*hub, new_succ, succ);
                    array_add(*targets, .{succ, new_succ});
                }
            }
        } else {
            fatal("unify-loop-exits: unsupported block terminator");
        }
    }
    guard_blocks: [..] Value_Id; guard_blocks.allocator = temp;
    loop_exit_block, changed_cfg := cfh_finalize(*hub, dt, *guard_blocks, "loop.exit", ule_max_booleans_in_control_flow_hub);
    changed_cfg |= changed;
    if !changed_cfg return false;
    ule_restore_ssa(dt, li, l, exiting, loop_exit_block);
    parent := li_parent(li, l);
    if parent != NONE {
        for guard_blocks li_add_basic_block_to_loop(li, parent, it);
        for callbr_targets_to_fix li_add_basic_block_to_loop(li, parent, it);
    }
    return true;
}

unify_loop_exits_run :: (f: Value_Id) -> Preserved {
    li := get_loop_info(f);
    dt := get_domtree(f);
    loops: [..] Loop_Id; loops.allocator = temp;
    li_loops_in_preorder(li, *loops);
    changed := false;
    for loops changed |= ule_unify_loop_exits(dt, li, it);
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .LOOPS);
    preserve(*pa, .DOMTREE);
    return pa;
}
