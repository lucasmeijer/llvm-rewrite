// ScalarEvolution, part 9: keeping a cached ScalarEvolution valid while passes change the IR.
// Port of llvm/lib/Analysis/ScalarEvolution.cpp (LLVM 23.1.5): forgetAllLoops, visitAndClearUsers /
// PushDefUseChildren, forgetLoop, forgetTopmostLoop, forgetValue, forgetLcssaPhiWithNewPredecessor,
// forgetLoopDispositions, forgetBlockAndLoopDispositions, and the value-handle callbacks
// (SCEVCallbackVH::deleted / allUsesReplacedWith, SCEVUnknown::deleted / allUsesReplacedWith).
//
// The value-handle callbacks are called from ir.jai (erase_inst, replace_all_uses_with) through
// scev_note_erase / scev_note_rauw; they only do work when the value's function has a cached ScalarEvolution.

// the cached ScalarEvolution of the function `v` belongs to, made current (null if there is none)
scev_for_value :: (v: Value_Id) -> *Scev_State {
    if fam.count == 0 return null;
    k := vkind(v);
    if k != .INST && k != .ARGUMENT return null;
    f := value_function(v);
    if f == NONE return null;
    e := table_find_pointer(*fam, f);
    if !e || !e.se return null;
    se = e.se;
    return e.se;
}

// SCEVCallbackVH::deleted and SCEVUnknown::deleted
scev_note_erase :: (v: Value_Id) {
    s := scev_for_value(v);
    if !s return;
    if is_inst(v) && inst_op(v) == .PHI table_remove(*se.const_evolution, v);
    sc_erase_value_from_map(v);
    u := sc_find(.UNKNOWN, .[], NONE, v);
    if u {
        sc_forget_memoized_results(.[u]);
        sc_unique_remove(u);
        se.nodes[u].val = NONE;   // setValPtr(nullptr)
    }
}
// SCEVCallbackVH::allUsesReplacedWith and SCEVUnknown::allUsesReplacedWith
scev_note_rauw :: (old: Value_Id, new: Value_Id) {
    s := scev_for_value(old);
    if !s return;
    if table_contains(*se.value_expr, old) sc_forget_value(old);
    u := sc_find(.UNKNOWN, .[], NONE, old);
    if u {
        sc_forget_memoized_results(.[u]);
        sc_unique_remove(u);
        se.nodes[u].val = new;   // setValPtr(New)
    }
}

// forgetAllLoops
sc_forget_all_loops :: () {
    table_reset(*se.btc); table_reset(*se.pred_btc); table_reset(*se.be_count_users); table_reset(*se.loop_props);
    table_reset(*se.const_evolution); table_reset(*se.value_expr); table_reset(*se.values_at_scopes);
    table_reset(*se.values_at_scopes_users); table_reset(*se.loop_disp); table_reset(*se.block_disp);
    table_reset(*se.unsigned_ranges); table_reset(*se.signed_ranges); table_reset(*se.expr_values);
    table_reset(*se.has_rec); table_reset(*se.const_multiple); table_reset(*se.predicated_rewrites);
    table_reset(*se.fold_cache); table_reset(*se.fold_cache_user);
}

// PushDefUseChildren
push_def_use_children :: (i: Value_Id, work: *[..] Value_Id, visited: *Table(Value_Id, bool)) {
    u := ir.v_first_use[i];
    while u != NONE {
        user := ir.u_user[u];
        if !table_contains(visited, user) { table_set(visited, user, true); array_add(work, user); }
        u = ir.u_next[u];
    }
}
// visitAndClearUsers
visit_and_clear_users :: (work: *[..] Value_Id, visited: *Table(Value_Id, bool), to_forget: *[..] Scev_Id) {
    while work.count > 0 {
        i := pop(work);
        if !sc_is_scevable(vtype(i)) && !is_with_overflow_inst(i) continue;
        found, s := table_find(*se.value_expr, i);
        if found {
            array_add(to_forget, s);
            sc_erase_value_from_map(i);
            if inst_op(i) == .PHI table_remove(*se.const_evolution, i);
        }
        push_def_use_children(i, work, visited);
    }
}

// forgetLoop
sc_forget_loop :: (l: Loop_Id) {
    loop_work: [..] Loop_Id; loop_work.allocator = temp;
    work: [..] Value_Id; work.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    to_forget: [..] Scev_Id; to_forget.allocator = temp;
    array_add(*loop_work, l);
    while loop_work.count > 0 {
        curr := pop(*loop_work);
        sc_forget_backedge_taken_counts(curr, false);
        sc_forget_backedge_taken_counts(curr, true);
        rm: [..] u64; rm.allocator = temp;
        for v, k: se.predicated_rewrites if cast(Loop_Id) (k & 0xFFFF_FFFF) == curr array_add(*rm, k);
        for rm table_remove(*se.predicated_rewrites, it);
        lu := table_find_pointer(*se.loop_users, curr);
        if lu for lu.* array_add(*to_forget, it);
        // PushLoopPHIs
        for phi: block_insts(li_header(se.li, curr)) {
            if inst_op(phi) != .PHI break;
            if !table_contains(*visited, phi) { table_set(*visited, phi, true); array_add(*work, phi); }
        }
        visit_and_clear_users(*work, *visited, *to_forget);
        table_remove(*se.loop_props, curr);
        for li_subloops(se.li, curr) array_add(*loop_work, it);
    }
    sc_forget_memoized_results(to_forget);
}
sc_forget_topmost_loop :: (l: Loop_Id) { sc_forget_loop(li_outermost(se.li, l)); }

// forgetValue
sc_forget_value :: (v: Value_Id) {
    if !is_inst(v) return;
    work: [..] Value_Id; work.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    to_forget: [..] Scev_Id; to_forget.allocator = temp;
    array_add(*work, v);
    table_set(*visited, v, true);
    visit_and_clear_users(*work, *visited, *to_forget);
    sc_forget_memoized_results(to_forget);
}

// forgetLcssaPhiWithNewPredecessor
sc_forget_lcssa_phi_with_new_predecessor :: (l: Loop_Id, v: Value_Id) {
    if !sc_is_scevable(vtype(v)) return;
    s := sc_get_existing(v);
    if s != SCEV_CNC {
        Ctx :: struct { l: Loop_Id; roots: [..] Scev_Id; }
        ctx: Ctx;
        ctx.l = l;
        ctx.roots.allocator = temp;
        vis: Sc_Visitor;
        vis.data = *ctx;
        vis.follow = (vis: *Sc_Visitor, s: Scev_Id) -> bool {
            c := cast(*Ctx) vis.data;
            if sc_is_unknown(s) {
                i := sc_value(s);
                if is_inst(i) && li_contains(se.li, c.l, inst_block(i)) array_add(*c.roots, s);
            } else if sc_is_addrec(s) {
                if li_contains_loop(se.li, c.l, sc_loop(s)) array_add(*c.roots, s);
            }
            return true;
        };
        sc_visit_all(s, *vis);
        sc_forget_memoized_results(ctx.roots);
    }
    sc_forget_value(v);
}

sc_forget_loop_dispositions :: () { table_reset(*se.loop_disp); }

// forgetBlockAndLoopDispositions(V = nullptr)
sc_forget_block_and_loop_dispositions :: (v: Value_Id = NONE) {
    if v == NONE {
        table_reset(*se.block_disp);
        table_reset(*se.loop_disp);
        return;
    }
    if !sc_is_scevable(vtype(v)) return;
    s := sc_get_existing(v);
    if s == SCEV_CNC return;
    work: [..] Scev_Id; work.allocator = temp;
    seen: Table(Scev_Id, bool); seen.allocator = temp;
    array_add(*work, s);
    table_set(*seen, s, true);
    while work.count > 0 {
        curr := pop(*work);
        a := table_remove(*se.loop_disp, curr);
        b := table_remove(*se.block_disp, curr);
        if !a && !b continue;
        users := table_find_pointer(*se.users, curr);
        if users for u: users.* {
            if !table_contains(*seen, u) { table_set(*seen, u, true); array_add(*work, u); }
        }
    }
}

// The ScalarEvolution a running pass has (LLVM passes it down as `ScalarEvolution *SE`, possibly null): set by
// loop_simplify_run / lcssa_run (getCachedResult) and run_loop_pass (LoopStandardAnalysisResults::SE).
scev_pass_se: *Scev_State;
pse_forget_value :: (v: Value_Id) { if scev_pass_se { se = scev_pass_se; sc_forget_value(v); } }
pse_forget_loop :: (l: Loop_Id) { if scev_pass_se { se = scev_pass_se; sc_forget_loop(l); } }
pse_forget_topmost_loop :: (l: Loop_Id) { if scev_pass_se { se = scev_pass_se; sc_forget_topmost_loop(l); } }
pse_forget_block_and_loop_dispositions :: (v: Value_Id = NONE) { if scev_pass_se { se = scev_pass_se; sc_forget_block_and_loop_dispositions(v); } }
