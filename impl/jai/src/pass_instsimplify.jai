// InstSimplify pass: a port of llvm/lib/Transforms/Scalar/InstSimplifyPass.cpp (runImpl, InstSimplifyPass::run).
// The simplification itself is inst_simplify.jai.

instsimplify_run :: (f: Value_Id) -> Preserved {
    dt := get_domtree(f);
    ac := get_assumption_cache(f);
    q: Simplify_Query;
    q.dt = dt; q.ac = ac;
    changed := false;
    to_simplify: Table(Value_Id, bool); to_simplify.allocator = temp;
    next: Table(Value_Id, bool); next.allocator = temp;
    first := true;
    while true {
        for bb: fn_blocks(f) {
            if !dt_is_reachable_from_entry(dt, bb) continue;
            dead: [..] Value_Id; dead.allocator = temp;
            for i: block_insts(bb) {
                if !first && !table_contains(*to_simplify, i) continue;
                if !has_uses(i) && would_instruction_be_trivially_dead(i, false) {   // isInstructionTriviallyDead(&I) (no TLI)
                    array_add(*dead, i);
                    changed = true;
                } else if has_uses(i) {
                    v := simplify_instruction(i, sq_with_instruction(q, i));
                    if v != NONE {
                        u := ir.v_first_use[i];
                        while u != NONE { table_set(*next, ir.u_user[u], true); u = ir.u_next[u]; }
                        rauw_with_metadata(i, v);
                        changed = true;
                        if !has_uses(i) && would_instruction_be_trivially_dead(i, false) array_add(*dead, i);
                    }
                }
            }
            recursively_delete_trivially_dead_instructions(dead);
        }
        // swap(ToSimplify, Next); Next->clear()
        t := to_simplify; to_simplify = next; next = t;
        table_reset(*next);
        first = false;
        if to_simplify.count == 0 break;
    }
    if !changed return PRESERVE_ALL;
    return preserved_cfg();
}

// RecursivelyDeleteTriviallyDeadInstructions(DeadInsts, TLI) (llvm/lib/Transforms/Utils/Local.cpp): the list holds
// WeakTrackingVHs, so entries deleted meanwhile (DEAD rows) or no longer trivially dead are skipped.
recursively_delete_trivially_dead_instructions :: (dead_in: [..] Value_Id) {
    dead: [..] Value_Id; dead.allocator = temp;
    for dead_in if vkind(it) != .DEAD && is_instruction_trivially_dead(it) array_add(*dead, it);
    if dead.count == 0 return;
    // RecursivelyDeleteTriviallyDeadInstructionsPermissive's loop
    while dead.count {
        i := pop(*dead);
        if vkind(i) == .DEAD continue;
        salvage_debug_info(i);
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            o := op(i, cast(u32) k);
            set_op(i, cast(u32) k, NONE);
            if o != NONE && is_inst(o) && !has_uses(o) && is_instruction_trivially_dead(o) array_add(*dead, o);
        }
        erase_inst_with_metadata(i);
    }
}
// salvageDebugInfo (llvm/lib/Transforms/Utils/Local.cpp). Instructions salvageDebugInfoImpl can't describe (calls,
// loads, phis, ...) get their debug users' locations killed (poison), which erase_inst_with_metadata does.
// Rewriting the DIExpression for casts / GEPs / binary operators / icmps (appendOpsToArg, foldConstantMath) is
// not ported: fail loudly when one of those has debug users.
salvage_debug_info :: (i: Value_Id) {
    users: [..] u32; users.allocator = temp;
    find_dbg_users(inst_fn(i), i, *users);
    if users.count == 0 return;
    o := inst_op(i);
    salvageable := is_cast_op(o) || o == .GEP || o == .ICMP ||
                   o == .ADD || o == .SUB || o == .MUL || o == .SDIV || o == .SREM || o == .OR || o == .AND || o == .XOR ||
                   o == .SHL || o == .LSHR || o == .ASHR;
    if salvageable fatal("salvageDebugInfo for a deleted '%' with debug users is not supported yet", opcode_name(o));
    for users {
        r := dbgr(it);
        if r.loc != NONE && ir.mds[r.loc].kind != .VALUE fatal("killing a DIArgList debug location (salvageDebugInfo) is not supported yet");
    }
}
