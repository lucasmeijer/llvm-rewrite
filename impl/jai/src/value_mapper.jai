// ValueMapper: remapping instructions, values, metadata and debug records through a value map.
// Port of llvm/lib/Transforms/Utils/ValueMapper.cpp (Mapper::mapValue, mapBlockAddress, remapInstruction,
// remapDbgRecord, mapSimpleMetadata/mapMetadata) and llvm/include/llvm/IR/ValueMap.h (ValueToValueMapTy).
//
// Reusable API (cloning, unrolling, peeling, inlining):
//   vm: Value_Map; vmap_init(*vm);           ValueToValueMapTy (temp storage)
//   vmap_set(*vm, k, v) / vmap_lookup(*vm, k) / vmap_find(*vm, k) -> (found, v) / vmap_erase(*vm, k)
//   map_value(*vm, v, flags) -> Value_Id     MapValue (NONE = no mapping, like nullptr)
//   remap_instruction(*vm, i, flags)         RemapInstruction
//   remap_dbg_record(*vm, r, flags)          RemapDbgRecord; remap_dbg_record_range(*vm, i, flags) for i's records
//   map_metadata(*vm, md, flags) -> Md_Id    MapMetadata
// Flags: RF_NO_MODULE_LEVEL_CHANGES, RF_IGNORE_MISSING_LOCALS, RF_NULL_MAP_MISSING_GLOBAL_VALUES, RF_DO_NOT_REMAP_ATOMS.
//
// Not ported (fail loudly when reached): the MDNodeMapper (mapping metadata *with* module-level changes: uniqued
// graph post-order traversal, distinct node cloning), TypeMapper / Materializer, global initializer / alias /
// appending-variable remapping (mapGlobalInitializer & co., used when cloning into another module), key-instruction
// atom remapping (RemapSourceAtom with a non-empty AtomMap).
//
// ValueToValueMapTy's values are WeakTrackingVHs and its keys follow RAUW: callers here (loop unrolling/peeling)
// never RAUW or erase a mapped value while the map is live, so the map is a plain table.

RF_NONE :: 0;
RF_NO_MODULE_LEVEL_CHANGES :: 1;
RF_IGNORE_MISSING_LOCALS :: 2;
RF_REUSE_AND_MUTATE_DISTINCT_MDS :: 4;
RF_NULL_MAP_MISSING_GLOBAL_VALUES :: 8;
RF_DO_NOT_REMAP_ATOMS :: 16;

Value_Map :: struct {
    map: Table(Value_Id, Value_Id);
    md: Table(Md_Id, Md_Id);       // ValueMap::MD()
    has_md: bool;
}
vmap_init :: (vm: *Value_Map) { vm.map.allocator = temp; vm.md.allocator = temp; }
vmap_set :: (vm: *Value_Map, k: Value_Id, v: Value_Id) { table_set(*vm.map, k, v); }
vmap_find :: (vm: *Value_Map, k: Value_Id) -> (bool, Value_Id) { found, v := table_find(*vm.map, k); return found, v; }
// ValueMap::lookup: NONE when absent
vmap_lookup :: (vm: *Value_Map, k: Value_Id) -> Value_Id { found, v := table_find(*vm.map, k); if found return v; return NONE; }
vmap_erase :: (vm: *Value_Map, k: Value_Id) { table_remove(*vm.map, k); }
vmap_contains :: (vm: *Value_Map, k: Value_Id) -> bool { return table_contains(*vm.map, k); }
// operator[] read for an existing key (asserts presence like cast<> on the result would)
vmap_get :: (vm: *Value_Map, k: Value_Id) -> Value_Id {
    found, v := table_find(*vm.map, k);
    if !found return NONE;
    return v;
}

// MetadataAsValue::get(Ctx, MD)
md_as_value :: (m: Md_Id) -> Value_Id {
    k := const_key_begin(.MD_VALUE, ir.t_metadata); key_u32(k, m);
    v := const_lookup_or_create(k, .MD_VALUE, ir.t_metadata, .[], m);
    return v;
}

// Mapper::mapValue
map_value :: (vm: *Value_Map, v: Value_Id, flags: u32) -> Value_Id {
    if v == NONE return NONE;
    found, m := table_find(*vm.map, v);
    if found return m;
    k := vkind(v);
    if is_global_value(k) {
        if flags & RF_NULL_MAP_MISSING_GLOBAL_VALUES return NONE;
        table_set(*vm.map, v, v);
        return v;
    }
    if k == .INLINE_ASM { table_set(*vm.map, v, v); return v; }
    if k == .MD_VALUE {
        md := cast(Md_Id) ir.v_aux[v];
        if md != NONE && ir.mds[md].kind == .VALUE && !is_constant_kind(vkind(ir.mds[md].value)) {
            // LocalAsMetadata: look through to the local value
            lv := map_value(vm, ir.mds[md].value, flags);
            if lv != NONE {
                if lv == ir.mds[md].value return v;
                return md_as_value(md_value(lv));
            }
            if flags & RF_IGNORE_MISSING_LOCALS return NONE;
            return md_as_value(md_tuple(.[], false));
        }
        if md != NONE && is_di(md, .ARG_LIST) {
            mapped: [..] Md_Id; mapped.allocator = temp;
            n := md_nops(md);
            if n > 0 for i: 0..n-1 {
                vam := md_op(md, i);
                val := ir.mds[vam].value;
                is_const := is_constant_kind(vkind(val));
                if (flags & RF_NO_MODULE_LEVEL_CHANGES) && is_const { array_add(*mapped, vam); continue; }
                lv := map_value(vm, val, flags);
                if lv != NONE { array_add(*mapped, ifx lv == val then vam else md_value(lv)); continue; }
                if (flags & RF_IGNORE_MISSING_LOCALS) && !is_const { array_add(*mapped, vam); continue; }
                array_add(*mapped, md_value(const_poison(vtype(val))));
            }
            return md_as_value(di_arg_list_get(mapped));
        }
        if flags & RF_NO_MODULE_LEVEL_CHANGES { table_set(*vm.map, v, v); return v; }
        mm := map_metadata(vm, md, flags);
        if mm == md { table_set(*vm.map, v, v); return v; }
        r := md_as_value(mm);
        table_set(*vm.map, v, r);
        return r;
    }
    if !is_constant_kind(k) return NONE;
    if k == .C_BLOCKADDR return map_block_address(vm, v, flags);
    if k == .C_DSO_EQUIV || k == .C_NO_CFI {
        gv := map_value(vm, op(v, 0), flags);
        if gv == op(v, 0) { table_set(*vm.map, v, v); return v; }
        fatal("ValueMapper: remapping a dso_local_equivalent / no_cfi constant to another global is not implemented yet");
    }
    // some other constant: check whether all operands have an identity remapping
    n := nops(v);
    opno: u32 = 0;
    mapped: Value_Id = NONE;
    while opno < n {
        o := op(v, opno);
        mapped = map_value(vm, o, flags);
        if mapped == NONE return NONE;
        if mapped != o break;
        opno += 1;
    }
    if opno == n { table_set(*vm.map, v, v); return v; }
    ops: [..] Value_Id; ops.allocator = temp;
    for j: 0..cast(s64) opno - 1 array_add(*ops, op(v, cast(u32) j));
    array_add(*ops, mapped);
    opno += 1;
    while opno < n {
        mm := map_value(vm, op(v, opno), flags);
        if mm == NONE return NONE;
        array_add(*ops, mm);
        opno += 1;
    }
    r: Value_Id = NONE;
    if k == {
        case .C_EXPR;
            ce := cexpr(v);
            extra: [..] u32; extra.allocator = temp;
            if ce.nidx > 0 for j: 0..cast(s64) ce.nidx - 1 array_add(*extra, ir.u32_pool[ce.idx + cast(u32) j]);
            r = const_expr(ce.op, vtype(v), ce.flags, ce.ty2, ops, extra);
        case .C_ARRAY; #through;
        case .C_STRUCT; #through;
        case .C_VECTOR;
            r = const_aggregate(k, vtype(v), ops);
        case;
            fatal("ValueMapper: remapping the operands of this constant kind is not implemented yet");
    }
    table_set(*vm.map, v, r);
    return r;
}

// Mapper::mapBlockAddress
map_block_address :: (vm: *Value_Map, ba: Value_Id, flags: u32) -> Value_Id {
    f := map_value(vm, op(ba, 0), flags);
    if glob(f).first_block == NONE fatal("ValueMapper: blockaddress of a function without a body (DelayedBBs) is not implemented yet");
    bb := map_value(vm, op(ba, 1), flags);
    if bb != NONE && vkind(bb) != .BLOCK bb = NONE;
    r := const_blockaddr(f, ifx bb != NONE then bb else op(ba, 1));
    table_set(*vm.map, ba, r);
    return r;
}

// Mapper::mapSimpleMetadata: (true, result) when the metadata maps without the MDNodeMapper
map_simple_metadata :: (vm: *Value_Map, md: Md_Id, flags: u32) -> (bool, Md_Id) {
    if vm.md.count {
        found, m := table_find(*vm.md, md);
        if found return true, m;
    }
    if ir.mds[md].kind == .STRING return true, md;
    if flags & RF_NO_MODULE_LEVEL_CHANGES return true, md;
    if ir.mds[md].kind == .VALUE {
        // ConstantAsMetadata (not memoized)
        cv := map_value(vm, ir.mds[md].value, flags);
        if cv == NONE return true, NONE;
        if cv == ir.mds[md].value return true, md;
        return true, md_value(cv);
    }
    return false, NONE;
}

// Mapper::mapMetadata
map_metadata :: (vm: *Value_Map, md: Md_Id, flags: u32) -> Md_Id {
    ok, r := map_simple_metadata(vm, md, flags);
    if ok return r;
    fatal("ValueMapper: mapping metadata with module-level changes (MDNodeMapper) is not implemented yet");
    return NONE;
}

// RemapSourceAtom: only an empty AtomMap is supported (CloneBasicBlock's mapAtomInstance fails loudly first)
remap_source_atom :: (vm: *Value_Map, i: Value_Id) {
    dl := get_metadata(i, 0);
    if dl != NONE && di_int(dl, 3) != 0 fatal("ValueMapper: key-instruction atom groups (RemapSourceAtom) are not implemented yet");
}

// Mapper::remapInstruction
remap_instruction :: (vm: *Value_Map, i: Value_Id, flags: u32) {
    n := nops(i);
    is_phi_i := inst_op(i) == .PHI;
    for k: 0..cast(s64) n - 1 {
        o := op(i, cast(u32) k);
        if o == NONE continue;
        v := map_value(vm, o, flags);
        if v != NONE set_op(i, cast(u32) k, v);   // `Op = V` is Use::set even when V is the old value (the use moves to the front)
        else if !(flags & RF_IGNORE_MISSING_LOCALS) fatal("ValueMapper: referenced value not in value map");
    }
    if is_call_base(i) {
        ct := md_kind_id("callee_type");
        if get_metadata(i, ct) != NONE && call_called_function(i) != NONE set_metadata(i, ct, NONE);
    }
    if is_phi_i {
        for k: 0..cast(s64) n - 1 {
            b := phi_block(i, cast(u32) k);
            v := map_value(vm, b, flags);
            if v != NONE phi_set_block(i, cast(u32) k, v);
            else if !(flags & RF_IGNORE_MISSING_LOCALS) fatal("ValueMapper: referenced block not in value map");
        }
    }
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(i, *all);
    for all {
        nw := map_metadata(vm, it.md, flags);
        if nw != it.md set_metadata(i, it.kind, nw);
    }
    if !(flags & RF_DO_NOT_REMAP_ATOMS) remap_source_atom(vm, i);
}

// Mapper::remapDbgRecord
remap_dbg_record :: (vm: *Value_Map, r: u32, flags: u32) {
    rec := dbgr(r);
    if rec.dbg != NONE rec.dbg = map_metadata(vm, rec.dbg, flags);
    if rec.kind == .LABEL {
        if rec.loc != NONE dbgr(r).loc = map_metadata(vm, dbgr(r).loc, flags);
        return;
    }
    if dbgr(r).var != NONE dbgr(r).var = map_metadata(vm, dbgr(r).var, flags);
    ignore_missing := (flags & RF_IGNORE_MISSING_LOCALS) != 0;
    if dbgr(r).kind == .ASSIGN fatal("ValueMapper: remapping #dbg_assign records is not implemented yet");
    vals: [..] Value_Id; vals.allocator = temp;
    dbgr_values_of_loc(dbgr(r).loc, *vals);
    new_vals: [..] Value_Id; new_vals.allocator = temp;
    for vals array_add(*new_vals, map_value(vm, it, flags));
    same := true;
    for vals if new_vals[it_index] != it { same = false; break; }
    if same return;
    has_null := false;
    for new_vals if it == NONE has_null = true;
    if !ignore_missing && has_null { dbgr_set_kill_location(r); return; }
    for k: 0..vals.count - 1 if new_vals[k] != NONE dbgr_replace_variable_location_op_idx(r, cast(u32) k, new_vals[k]);
}
// RemapDbgRecordRange(M, I->getDbgRecordRange(), VM, Flags)
remap_dbg_record_range :: (vm: *Value_Map, i: Value_Id, flags: u32) {
    r := inst(i).records;
    while r != 0 {
        nx := dbgr(r).next;
        remap_dbg_record(vm, r, flags);
        r = nx;
    }
}

// DbgVariableRecord::replaceVariableLocationOp(unsigned OpIdx, Value *NewValue)
dbgr_replace_variable_location_op_idx :: (r: u32, idx: u32, new: Value_Id) {
    loc := dbgr(r).loc;
    nm := ifx vkind(new) == .MD_VALUE then cast(Md_Id) ir.v_aux[new] else md_value(new);
    if !is_di(loc, .ARG_LIST) { dbgr_set_raw_location(r, nm); return; }
    vals: [..] Value_Id; vals.allocator = temp;
    dbgr_values_of_loc(loc, *vals);
    mds: [..] Md_Id; mds.allocator = temp;
    for vals array_add(*mds, ifx it_index == idx then nm else md_op(loc, cast(u32) it_index));
    dbgr_set_raw_location(r, di_arg_list_get(mds));
}
