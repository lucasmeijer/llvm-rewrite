// LowerConstantIntrinsics: port of llvm/lib/Transforms/Scalar/LowerConstantIntrinsics.cpp
// (lowerIsConstantIntrinsic, replaceConditionalBranchesOnConstant, lowerConstantIntrinsics) and of
// replaceAndRecursivelySimplify (llvm/lib/Analysis/InstructionSimplify.cpp, replaceAndRecursivelySimplifyImpl).

// replaceAndRecursivelySimplify(I, SimpleV, TLI, DT, AC, UnsimplifiedUsers). `q` carries TLI/DT/AC.
replace_and_recursively_simplify :: (i_in: Value_Id, simple_v: Value_Id, q: Simplify_Query, unsimplified: *[..] Value_Id = null) -> bool {
    simplified := false;
    worklist: [..] Value_Id; worklist.allocator = temp;
    in_wl: Table(Value_Id, bool); in_wl.allocator = temp;
    wl_insert :: (v: Value_Id) #expand {
        if !table_contains(*in_wl, v) { table_set(*in_wl, v, true); array_add(*worklist, v); }
    }
    uns_set: Table(Value_Id, bool); uns_set.allocator = temp;
    i := i_in;
    u := ir.v_first_use[i];
    while u != NONE { usr := ir.u_user[u]; if usr != i wl_insert(usr); u = ir.u_next[u]; }
    rauw_with_metadata(i, simple_v);
    if !is_eh_pad(i) && !is_terminator(inst_op(i)) && !may_have_side_effects(i) erase_inst_with_metadata(i);
    idx := 0;
    while idx < worklist.count {
        i = worklist[idx];
        idx += 1;
        sv := simplify_instruction(i, sq_with_instruction(q, i));
        if sv == NONE {
            if unsimplified && !table_contains(*uns_set, i) { table_set(*uns_set, i, true); array_add(unsimplified, i); }
            continue;
        }
        simplified = true;
        u = ir.v_first_use[i];
        while u != NONE { wl_insert(ir.u_user[u]); u = ir.u_next[u]; }
        rauw_with_metadata(i, sv);
        if !is_eh_pad(i) && !is_terminator(inst_op(i)) && !may_have_side_effects(i) erase_inst_with_metadata(i);
    }
    return simplified;
}

lci_replace_conditional_branches_on_constant :: (ii: Value_Id, new_value: Value_Id, dtu: *Dtu) -> bool {
    has_dead_blocks := false;
    unsimplified: [..] Value_Id; unsimplified.allocator = temp;
    q: Simplify_Query;
    q.have_tli = false; q.no_tli_libcalls = true;   // TLI, DT and AC are nullptr
    replace_and_recursively_simplify(ii, new_value, q, *unsimplified);
    for bi: unsimplified {   // WeakVH: erased instructions are skipped
        if vkind(bi) != .INST || inst_op(bi) != .CONDBR continue;
        target, other: Value_Id = NONE;
        c := op(bi, 0);
        if pm_zero_int(c) { target = get_successor(bi, 1); other = get_successor(bi, 0); }
        else if pm_one(c) { target = get_successor(bi, 0); other = get_successor(bi, 1); }
        if target != NONE && target != other {
            source := inst_block(bi);
            block_remove_predecessor(other, source);
            nbi := create_br(target);
            block_append_inst(source, nbi);
            copy_debug_loc(nbi, bi);
            erase_inst_with_metadata(bi);
            dtu_apply(dtu, .[.{false, source, other}]);
            if !block_has_predecessors(other) has_dead_blocks = true;
        }
    }
    return has_dead_blocks;
}

lower_constant_intrinsics_run :: (f: Value_Id) -> Preserved {
    dt := cached_domtree(f);
    dtu: Dtu; dtu.dt = dt; dtu.lazy = true;
    dtu.pending.allocator = temp; dtu.deleted.allocator = temp; dtu.deleted_set.allocator = temp;
    pdtu := ifx dt then *dtu else null;   // std::optional<DomTreeUpdater>: only with a cached DominatorTree
    has_dead_blocks := false;
    po: [..] Value_Id; po.allocator = temp;
    cfg_post_order(fn_entry(f), *po);
    worklist: [..] Vh; worklist.allocator = temp;
    k := po.count;
    while k > 0 {
        k -= 1;
        for i: block_insts(po[k]) {
            id := call_iid(i);
            if id == IID_IS_CONSTANT || id == IID_OBJECTSIZE array_add(*worklist, vh_new(i));
        }
    }
    for h: worklist {
        ii := vh_get(h);
        if ii == NONE || vkind(ii) != .INST continue;
        id := call_iid(ii);
        new_value: Value_Id;
        if id == IID_IS_CONSTANT {
            o := op(ii, 0);
            if is_constant_kind(vkind(o)) && is_manifest_constant(o) new_value = const_int(vtype(ii), 1);
            else new_value = const_int(vtype(ii), 0);
        } else if id == IID_OBJECTSIZE {
            new_value = lower_object_size_call(ii, null, true);
        } else continue;
        if lci_replace_conditional_branches_on_constant(ii, new_value, pdtu) has_dead_blocks = true;
    }
    if has_dead_blocks remove_unreachable_blocks(f, pdtu);
    dtu_flush(pdtu);
    changed := worklist.count > 0;
    vh_release_all();
    if changed {
        pa: Preserved;
        preserve(*pa, .DOMTREE);
        return pa;
    }
    return PRESERVE_ALL;
}
