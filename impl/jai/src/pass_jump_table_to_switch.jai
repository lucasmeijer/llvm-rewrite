// JumpTableToSwitch: port of llvm/lib/Transforms/Scalar/JumpTableToSwitch.cpp (parseJumpTable, expandToSwitch,
// JumpTableToSwitchPass::run) and the DomTreeUpdater path of SplitBlock (SplitBlockImpl,
// llvm/lib/Transforms/Utils/BasicBlockUtils.cpp). The lazy DomTreeUpdater over the cached DT and PDT is two lazy
// Dtu rows. Calls with value-profile (!prof VP) metadata fail loudly (indirect-call target profiles are not
// ported).

jtts_cl: struct {
    size_threshold: s64 = 10;            // -jump-table-to-switch-size-threshold
    function_size_threshold: s64 = 50;   // -jump-table-to-switch-function-size-threshold
};

Jtts_Dtu :: struct { dt: Dtu; pdt: Dtu; }
jtts_apply :: (d: *Jtts_Dtu, ups: [] Dom_Update) { dtu_apply(*d.dt, ups); dtu_apply(*d.pdt, ups); }

// FuncToGuid: Fct.getGUIDIfAssigned() (the !guid attachment), else MD5 of getIRPGOFuncName(Fct, InLTO = false)
jtts_function_guid :: (f: Value_Id) -> u64 {
    m := get_metadata(f, MDK_UNIQUE_ID);
    if m != NONE {
        c := md_const_int_op(m, 0);
        if c != NONE return const_int_zext(c);
    }
    if jtts_in_lto {
        // getIRPGOFuncName(F, InLTO = true): the PGOFuncName metadata, else the name as if external
        if get_metadata(f, md_kind_id("PGOFuncName")) != NONE fatal("jump-table-to-switch: PGOFuncName metadata in LTO mode is not supported yet");
        n := vname(f);
        if n.count && n[0] == 1 n = slice(n, 1, n.count - 1);
        return md5_hash_u64(n);
    }
    return md5_hash_u64(gv_global_identifier(f));
}
jtts_in_lto := false;   // JumpTableToSwitchPass(InLTO), set per run from the pass node

fn_instruction_count :: (f: Value_Id) -> s64 { n := 0; for b: fn_blocks(f) n += block_size(b); return n; }

// parseJumpTable: (ok, index, funcs)
jtts_parse_jump_table :: (gep: Value_Id, ptr_ty: Type_Id, call_fty: Type_Id) -> (bool, Value_Id, [..] Value_Id) {
    funcs: [..] Value_Id; funcs.allocator = temp;
    p := op(gep, 0);
    if !is_constant_kind(vkind(p)) return false, NONE, funcs;
    gv := p;
    if vkind(gv) != .GLOBAL_VAR || !glob(gv).is_const || !gv_has_definitive_initializer(gv) return false, NONE, funcs;
    bw := dl_index_size_bits(ptr_addrspace(vtype(gep)));
    ok, vars, const_off := gep_operator_collect_offset(gep, bw);
    if !ok return false, NONE, funcs;
    if vars.count != 1 return false, NONE, funcs;
    if !ap_is_zero(const_off) return false, NONE, funcs;
    stride := ap_zext_value(vars[0].scale);
    size := dl_type_alloc_size(glob(gv).value_type);   // GlobalVariable::getGlobalSize
    if stride == 0 || size % stride != 0 return false, NONE, funcs;
    n := size / stride;
    if cast(s64) n > jtts_cl.size_threshold return false, NONE, funcs;
    init := op(gv, 0);
    for k: 0..cast(s64) n - 1 {
        off := ap_mul(ap_from_u64(bw, cast(u64) k), vars[0].scale);
        c := cfo_load_from_const(init, ptr_ty, off);
        if c == NONE || vkind(c) != .FUNCTION || is_declaration(c) || glob(c).value_type != call_fty ||
           fn_instruction_count(c) > jtts_cl.function_size_threshold return false, NONE, funcs;
        array_add(*funcs, c);
    }
    return true, vars[0].v, funcs;
}

// SplitBlock(Old, SplitPt, DTU, nullptr, nullptr, BBName)
jtts_split_block :: (old: Value_Id, split_pt: Value_Id, d: *Jtts_Dtu, name: string) -> Value_Id {
    it := split_pt;
    while inst_op(it) == .PHI || is_eh_pad(it) it = inst_next(it);
    nb := split_basic_block(old, it, ifx name.count then name else tprint("%.split", vname(old)));
    ups: [..] Dom_Update; ups.allocator = temp;
    array_add(*ups, .{true, old, nb});
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(nb, *succs);
    seen: [..] Value_Id; seen.allocator = temp;
    for s: succs {
        dup := false;
        for seen if it == s { dup = true; break; }
        if dup continue;
        array_add(*seen, s);
        array_add(*ups, .{true, nb, s});
        array_add(*ups, .{false, old, s});
    }
    jtts_apply(d, ups);
    return nb;
}

jtts_expand_to_switch :: (cb: Value_Id, index: Value_Id, funcs: [] Value_Id, d: *Jtts_Dtu) -> Value_Id {
    is_void := vtype(cb) == ir.t_void;
    ups: [..] Dom_Update; ups.allocator = temp;
    bb := inst_block(cb);
    tail := jtts_split_block(bb, cb, d, tconcat(vname(bb), ".tail"));
    array_add(*ups, .{false, bb, tail});
    erase_inst_with_metadata(block_terminator(bb));
    f := block_fn(bb);
    bb_unreachable := create_block(f, "default.switch.case.unreachable", tail);
    block_append_inst(bb_unreachable, new_inst(.UNREACHABLE, ir.t_void, 0));
    sw := create_switch(index, bb_unreachable, 10);   // IRBuilder::CreateSwitch(V, Dest, NumCases = 10)
    block_append_inst(bb, sw);
    array_add(*ups, .{true, bb, bb_unreachable});
    phi: Value_Id = NONE;
    if !is_void {
        b: Irb; irb_set_before(*b, cb);
        phi = irb_phi(*b, vtype(cb), cast(u32) funcs.count);
    }
    prof := get_metadata(cb, md_fixed("prof"));
    had_profile := false;   // isValueProfileMD
    if prof != NONE && md_nops(prof) > 0 {
        s := md_op(prof, 0);
        had_profile = s != NONE && ir.mds[s].kind == .STRING && ir.mds[s].str == "VP";
    }
    weights: [..] u64; weights.allocator = temp;
    guid_keys: [..] u64; guid_keys.allocator = temp;
    guid_vals: [..] u64; guid_vals.allocator = temp;
    if had_profile {
        array_add(*weights, 0);
        // getValueProfDataFromInst(*CB, IPVK_IndirectCallTarget, UINT32_MAX, TotalCount)
        n := md_nops(prof);
        kind := md_const_int_op(prof, 1);
        if n >= 3 && kind != NONE && const_int_zext(kind) == 0 && md_const_int_op(prof, 2) != NONE {
            k: u32 = 3;
            while k + 1 < n || k < n {
                v := md_const_int_op(prof, k);
                c := ifx k + 1 < n then md_const_int_op(prof, k + 1) else NONE;
                if v == NONE || c == NONE { guid_keys.count = 0; guid_vals.count = 0; break; }
                cnt := const_int_zext(c);
                if cnt != 0xFFFF_FFFF_FFFF_FFFF { array_add(*guid_keys, const_int_zext(v)); array_add(*guid_vals, cnt); }   // NOMORE_ICP_MAGICNUM
                k += 2;
            }
        }
    }
    for fn: funcs {
        b := create_block(f, tprint("call.%", it_index), tail);
        array_add(*ups, .{true, bb, b});
        array_add(*ups, .{true, b, tail});
        call := ic_clone_inst(cb);
        set_metadata(call, md_fixed("prof"), NONE);
        call_set_called_function(call, fn);
        block_append_inst(b, call);
        sw_add_case(sw, const_int(vtype(index), cast(u64) it_index), b);
        block_append_inst(b, create_br(tail));
        if phi != NONE phi_add_incoming(phi, call, b);
        if had_profile {
            id := jtts_function_guid(fn);
            w: u64 = 0;
            if id != 0 for g: guid_keys if g == id { w = guid_vals[it_index]; break; }
            array_add(*weights, w);
        }
    }
    jtts_apply(d, ups);
    any_nonzero := false;
    for weights if it != 0 any_nonzero = true;
    if had_profile && any_nonzero {
        // setBranchWeights(*Switch, downscaleWeights(BranchWeights), false)
        mx: u64 = 0;
        for weights if it > mx mx = it;
        scale: u64 = ifx mx < 0xFFFF_FFFF then cast(u64) 1 else mx / 0xFFFF_FFFF + 1;
        w32 := NewArray(weights.count, u32,, allocator = temp);
        for weights w32[it_index] = cast(u32) (it / scale);
        prof_set_branch_weights(sw, w32, false);
    } else aic_set_explicitly_unknown_branch_weights(sw, "jump-table-to-switch");
    if phi != NONE rauw_with_metadata(cb, phi);
    erase_inst_with_metadata(cb);
    return tail;
}

jump_table_to_switch_run :: (f: Value_Id) -> Preserved {
    dt := cached_domtree(f);
    pdt := cached_postdomtree(f);
    d: Jtts_Dtu;
    d.dt.dt = dt; d.dt.lazy = true; d.pdt.dt = pdt; d.pdt.lazy = true;
    d.dt.pending.allocator = temp; d.dt.deleted.allocator = temp; d.dt.deleted_set.allocator = temp;
    d.pdt.pending.allocator = temp; d.pdt.deleted.allocator = temp; d.pdt.deleted_set.allocator = temp;
    changed := false;
    bb := fn_entry(f);
    while bb != NONE {
        nb := block(bb).next;   // make_early_inc_range
        defer bb = nb;
        current := bb;
        while current != NONE {
            split_tail: Value_Id = NONE;
            for :early_inc i: block_insts(current) {
                if inst_op(i) != .CALL || call_called_function(i) != NONE || call_is_must_tail(i) continue;
                l := call_callee(i);
                if !is_inst(l) || inst_op(l) != .LOAD || !inst_is_simple(l) continue;
                gep := op(l, 0);
                if !is_inst(gep) || inst_op(gep) != .GEP continue;
                ok, index, funcs := jtts_parse_jump_table(gep, vtype(l), inst(i).ty2);
                if !ok continue;
                split_tail = jtts_expand_to_switch(i, index, funcs, *d);
                changed = true;
                break;
            }
            current = split_tail;
        }
    }
    dtu_flush(*d.dt);
    dtu_flush(*d.pdt);
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    if dt preserve(*pa, .DOMTREE);
    if pdt preserve(*pa, .POSTDOMTREE);
    return pa;
}
