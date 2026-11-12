// InjectTLIMappings: port of llvm/lib/Transforms/Utils/InjectTLIMappings.cpp (addVariantDeclaration,
// addMappingsFromTLI, runImpl) with appendToCompilerUsed (llvm/lib/Transforms/Utils/ModuleUtils.cpp).
// The vector-library tables and VFABI helpers are vfabi.jai.

inject_tli_mappings_run :: (f: Value_Id) -> Preserved {
    for b: fn_blocks(f) for i: block_insts(b) if inst_op(i) == .CALL itm_add_mappings_from_tli(i);
    return PRESERVE_ALL;
}

#scope_file

// addVariantDeclaration(CI, VF, VD)
itm_add_variant_declaration :: (c: Value_Id, d: *Vec_Desc) {
    sfty := inst(c).ty2;
    if func_vararg(sfty) fatal("internal: inject-tli-mappings: vararg function");
    ok, info := vfabi_try_demangle(vec_desc_abi_variant_string(d), sfty);
    if !ok fatal("internal: inject-tli-mappings: cannot demangle %", vec_desc_abi_variant_string(d));
    vfty := vfabi_create_function_type(*info, sfty);
    // Function::Create(VectorFTy, ExternalLinkage, VFName, M)
    vf := new_function(vfty, d.vector, dl.program_as);
    array_add(*ir.m_functions, vf);
    ipo_fn_copy_attributes_from(vf, call_called_function(c));
    // removeRetAttrs / Arg.removeAttrs(typeIncompatible(...))
    l := glob(vf).attrs;
    ret := attr_set_type_incompatible(func_ret(vfty), attr_list_ret(l));
    np := cast(s64) func_nparams(vfty);
    params := NewArray(np, u32,, temp);
    for k: 0..np-1 params[k] = attr_set_type_incompatible(func_param(vfty, cast(u32) k), attr_list_param(l, cast(u32) k));
    glob(vf).attrs = attr_list_get(attr_list_fn(l), ret, params);
    if d.cc >= 0 glob(vf).cc = cast(u32) d.cc;
    itm_append_to_compiler_used(vf);
}

// appendToCompilerUsed(M, {V}) (appendToUsedList)
itm_append_to_compiler_used :: (v: Value_Id) {
    gv := module_get_global_variable("llvm.compiler.used");
    init: [..] Value_Id; init.allocator = temp;   // SmallSetVector<Constant *>
    if gv != NONE && glob(gv).has_init {
        ca := gv_initializer(gv);
        if vkind(ca) != .C_ARRAY fatal("llvm.compiler.used initializer that is not a ConstantArray is not supported");
        for k: 0..nops(ca)-1 { e := op(ca, k); if !array_find(init, e) array_add(*init, e); }
    }
    if gv != NONE gv_erase_from_parent(gv);
    pty := type_ptr(0);
    e := ce_pointer_bitcast_or_addrspacecast(v, pty);
    if !array_find(init, e) array_add(*init, e);
    aty := type_array(cast(u64) init.count, pty);
    nv := gv_create(aty, false, .APPENDING, const_aggregate(.C_ARRAY, aty, init), "llvm.compiler.used", NONE, 0, 0);
    glob(nv).section = "llvm.metadata";
}

// addMappingsFromTLI(TLI, CI)
itm_add_mappings_from_tli :: (c: Value_Id) {
    callee := call_called_function(c);
    if call_is_no_builtin(c) || callee == NONE return;
    scalar_name := vname(callee);
    if !tli_is_function_vectorizable(scalar_name) return;
    mappings := vfabi_get_vector_variant_names(c);
    original: [..] string; original.allocator = temp;
    for mappings if !array_find(original, it) array_add(*original, it);
    add_variant_decl :: (c: Value_Id, scalar_name: string, vf: u32, scalable: bool, pred: bool, mappings: *[..] string, original: [] string) {
        d := tli_get_vector_mapping_info(scalar_name, vf, scalable, pred);
        if d && d.vector.count {
            mangled := vec_desc_abi_variant_string(d);
            if !array_find(original, mangled) array_add(mappings, mangled);
            if module_get_function(d.vector) == NONE itm_add_variant_declaration(c, d);
        }
    }
    widest_fixed, widest_scalable := tli_get_widest_vf(scalar_name);
    for pred: bool.[false, true] {
        vf: u32 = 2;
        while vf <= widest_fixed { add_variant_decl(c, scalar_name, vf, false, pred, *mappings, original); vf *= 2; }
        vf = 2;
        while vf <= widest_scalable { add_variant_decl(c, scalar_name, vf, true, pred, *mappings, original); vf *= 2; }
    }
    vfabi_set_vector_variant_names(c, mappings);
}
