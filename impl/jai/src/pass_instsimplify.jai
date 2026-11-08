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
                        replace_all_uses_with(i, v);
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
        erase_inst(i);
    }
}
salvage_debug_info :: (i: Value_Id) { }   // debug records aren't supported by the parser (DESIGN.md)
