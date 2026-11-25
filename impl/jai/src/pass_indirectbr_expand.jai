// IndirectBrExpand (`indirectbr-expand`): port of llvm/lib/CodeGen/IndirectBrExpandPass.cpp (IndirectBrExpandPass::run,
// runImpl) with X86Subtarget::enableIndirectBrExpand (useIndirectThunkBranches: retpoline-indirect-branches or
// lvi-cfi).

indirectbr_expand_run :: (f: Value_Id) -> Preserved {
    t := tti_get(f);
    if t.kind != .X86 fatal("indirectbr-expand needs a target machine (an x86 target triple)");
    st := *t.xl;
    if !xs_has(st, X86F_FeatureRetpolineIndirectBranches) && !xs_has(st, X86F_FeatureLVIControlFlowIntegrity) return PRESERVE_ALL;
    dt := cached_domtree(f);
    dtu: Dtu; dtu.dt = dt; dtu.lazy = true;
    dtu.pending.allocator = temp; dtu.deleted.allocator = temp; dtu.deleted_set.allocator = temp;
    changed := ibe_run_impl(f, ifx dt then *dtu else null);
    if !changed return PRESERVE_ALL;
    if dt dtu_flush(*dtu);
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    return pa;
}

ibe_run_impl :: (f: Value_Id, dtu: *Dtu) -> bool {
    ibrs: [..] Value_Id; ibrs.allocator = temp;
    succs: Table(Value_Id, bool); succs.allocator = temp;   // IndirectBrSuccs (membership only)
    nsuccs := 0;
    for bb: fn_blocks(f) {
        ibr := block_terminator(bb);
        if ibr == NONE || inst_op(ibr) != .INDIRECTBR continue;
        n := ibr_num_succs(ibr);
        if n == 0 {
            u := new_inst(.UNREACHABLE, ir.t_void, 0);
            inst_insert_before_adopt(u, ibr);
            erase_terminator(ibr);
            continue;
        }
        array_add(*ibrs, ibr);
        for k: 0..n - 1 {
            s := get_successor(ibr, k);
            if !table_contains(*succs, s) { table_set(*succs, s, true); nsuccs += 1; }
        }
    }
    if ibrs.count == 0 return false;

    bbs: [..] Value_Id; bbs.allocator = temp;
    for bb: fn_blocks(f) {
        if !table_contains(*succs, bb) continue;
        ba := vf_block_address_of(bb);
        if ba == NONE || !vf_constant_is_used(ba) continue;
        idx := bbs.count + 1;
        array_add(*bbs, bb);
        ity := dl_int_ptr_type(vtype(ba));
        c := const_int(ity, cast(u64) idx);
        replace_all_uses_with(ba, ce_cast(.INTTOPTR, c, vtype(ba)));
    }

    updates: [..] Dom_Update; updates.allocator = temp;
    if bbs.count == 0 {
        for ibr: ibrs {
            bb := inst_block(ibr);
            if dtu for k: 0..ibr_num_succs(ibr) - 1 array_add(*updates, .{false, bb, get_successor(ibr, k)});
            u := new_inst(.UNREACHABLE, ir.t_void, 0);
            inst_insert_before_adopt(u, ibr);
            erase_terminator(ibr);
        }
        if dtu dtu_apply(dtu, updates);
        return true;
    }

    common: Type_Id = NONE;
    for ibr: ibrs {
        ity := dl_int_ptr_type(vtype(op(ibr, 0)));
        if common == NONE || type_int_width(ity) > type_int_width(common) common = ity;
    }
    get_switch_value :: (ibr: Value_Id, common: Type_Id) -> Value_Id {
        a := op(ibr, 0);
        c := create_cast(ifx is_ptr_type(vtype(a)) then Opcode.PTRTOINT else .BITCAST, a, common);   // CastInst::CreatePointerCast
        inst_insert_before_adopt(c, ibr);
        set_name(c, tconcat(vname(a), ".switch_cast"));
        return c;
    }

    switch_bb, switch_value: Value_Id;
    if ibrs.count == 1 {
        ibr := ibrs[0];
        switch_bb = inst_block(ibr);
        switch_value = get_switch_value(ibr, common);
        if dtu for k: 0..ibr_num_succs(ibr) - 1 array_add(*updates, .{false, switch_bb, get_successor(ibr, k)});
        erase_terminator(ibr);
    } else {
        switch_bb = create_block(f, "switch_bb");
        pn := create_phi(common, cast(u32) ibrs.count);
        insert_at_end_named(pn, switch_bb, "switch_value_phi");
        switch_value = pn;
        for ibr: ibrs {
            bb := inst_block(ibr);
            phi_add_incoming(pn, get_switch_value(ibr, common), bb);
            br := create_br(switch_bb);
            inst_insert_before_adopt(br, ibr);
            if dtu {
                array_add(*updates, .{true, bb, switch_bb});
                for k: 0..ibr_num_succs(ibr) - 1 array_add(*updates, .{false, bb, get_successor(ibr, k)});
            }
            erase_terminator(ibr);
        }
    }
    si := create_switch(switch_value, bbs[0], cast(u32) bbs.count);
    block_append_inst(switch_bb, si);
    for i: 1..bbs.count - 1 sw_add_case(si, const_int(common, cast(u64) (i + 1)), bbs[i]);
    if dtu {
        for bb: bbs array_add(*updates, .{true, switch_bb, bb});   // bbs has no duplicates
        dtu_apply(dtu, updates);
    }
    return true;
}

ibr_num_succs :: (ibr: Value_Id) -> u32 { return nops(ibr) - 1; }
