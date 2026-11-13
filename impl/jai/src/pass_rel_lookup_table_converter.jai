// RelLookupTableConverter: port of llvm/lib/Transforms/Utils/RelLookupTableConverter.cpp
// (shouldConvertToRelLookupTable, createRelLookupTable, convertToRelLookupTable, convertToRelativeLookupTables,
// RelLookupTableConverterPass::run). TTI::shouldBuildRelLookupTables is tti_should_build_rel_lookup_tables.

Rltc_Info :: struct { index: Value_Id; ptrs: [..] Value_Id; }

rltc_should_convert :: (info: *Rltc_Info, gv: Value_Id) -> bool {
    g := glob(gv);
    if !g.has_init || !g.is_const || !has_one_use(gv) || !gv_has_local_linkage(gv) || !g.dso_local || !gv_is_implicit_dso_local(gv) return false;
    gep := ir.u_user[ir.v_first_use[gv]];
    if !is_inst(gep) || inst_op(gep) != .GEP || !has_one_use(gep) return false;
    load := ir.u_user[ir.v_first_use[gep]];
    if !is_inst(load) || inst_op(load) != .LOAD || !has_one_use(load) return false;
    elem := vtype(load);
    if type_kind(elem) != .PTR || dl_pointer_type_size_bits(elem) != 64 return false;
    iw := dl_index_type_size_bits(vtype(op(load, 0)));
    ok, vars, const_off := gep_operator_collect_offset(gep, iw);
    if !ok || !ap_is_zero(const_off) || vars.count != 1 return false;
    info.index = vars[0].v;
    stride := vars[0].scale;
    if ap_active_bits(stride) <= 64 && ap_zext_value(stride) < dl_type_store_size(elem) return false;   // Stride.ult(...)
    t := ir.triple;
    should_drop_unnamed_addr := begins_with(t, "aarch64") || begins_with(t, "arm64") ||
        ((begins_with(t, "x86_64") || begins_with(t, "i386") || begins_with(t, "i686")) && (find_index_from_left(t, "darwin") >= 0 || find_index_from_left(t, "macos") >= 0 || find_index_from_left(t, "ios") >= 0));
    gv_ops: [..] Value_Id; gv_ops.allocator = temp;
    offset := ap_zero(iw);
    size := dl_type_alloc_size(g.value_type);   // getGlobalSize
    init := op(gv, 0);
    while ap_active_bits(offset) <= 64 && ap_zext_value(offset) < size {
        c := cfo_load_from_const(init, elem, offset);
        if c == NONE return false;
        okg, gvop, _ := is_constant_offset_from_global(c);
        if !okg return false;
        if vkind(gvop) != .GLOBAL_VAR || !glob(gvop).is_const return false;
        if !gv_has_local_linkage(gvop) || !glob(gvop).dso_local || !gv_is_implicit_dso_local(gvop) return false;
        if should_drop_unnamed_addr array_add(*gv_ops, gvop);
        array_add(*info.ptrs, c);
        offset = ap_add(offset, stride);
    }
    if should_drop_unnamed_addr for gv_ops glob(it).unnamed_addr = 0;   // UnnamedAddr::None
    return true;
}

rltc_create_rel_lookup_table :: (info: *Rltc_Info, table: Value_Id) -> Value_Id {
    i32 := ir.t_i32;
    arr := type_array(cast(u64) info.ptrs.count, i32);
    g := glob(table);
    rel := gv_create(arr, g.is_const, g.linkage, NONE, tconcat(vname(table), ".rel"), table, g.tls, g.addrspace);
    glob(rel).ext_init = g.ext_init;
    int_ptr := type_int(dl_ptr_spec(0).bits);
    contents := NewArray(info.ptrs.count, Value_Id,, allocator = temp);
    for e: info.ptrs {
        base := ce_cast(.PTRTOINT, rel, int_ptr);
        target := ce_cast(.PTRTOINT, e, int_ptr);
        sub := ce_binop(.SUB, target, base, 0);
        contents[it_index] = ce_cast(.TRUNC, sub, i32);
    }
    gv_set_initializer(rel, const_aggregate(.C_ARRAY, arr, contents));
    glob(rel).unnamed_addr = 2;
    glob(rel).align = 4;
    return rel;
}

rltc_convert :: (info: *Rltc_Info, table: Value_Id) {
    gep := ir.u_user[ir.v_first_use[table]];
    load := ir.u_user[ir.v_first_use[gep]];
    rel := rltc_create_rel_lookup_table(info, table);
    b: Irb;
    irb_set_before(*b, gep);
    int_ty := vtype(info.index);
    offset := irb_binop(*b, .SHL, info.index, const_int(int_ty, 2), "reltable.shift");
    irb_set_before(*b, load);
    lr := get_or_insert_intrinsic_declaration(intrinsic_id_by_name("llvm.load.relative"), .[int_ty]);
    result := irb_call(*b, lr, .[rel, offset], "reltable.intrinsic");
    rauw_with_metadata(load, result);
    erase_inst_with_metadata(load);
    erase_inst_with_metadata(gep);
}

rel_lookup_table_converter_run :: () -> Preserved {
    for f: ir.m_functions {
        if is_declaration(f) continue;
        if !tti_should_build_rel_lookup_tables(tti_get(f)) return PRESERVE_ALL;
        break;
    }
    changed := false;
    globals: [..] Value_Id; globals.allocator = temp;   // make_early_inc_range(M.globals())
    for ir.m_globals array_add(*globals, it);
    for gv: globals {
        if vkind(gv) != .GLOBAL_VAR continue;
        info: Rltc_Info; info.ptrs.allocator = temp;
        if !rltc_should_convert(*info, gv) continue;
        rltc_convert(*info, gv);
        gv_erase_from_parent(gv);
        changed = true;
    }
    if !changed return PRESERVE_ALL;
    return preserved_cfg();
}
