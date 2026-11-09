// EliminateAvailableExternally: turn available_externally definitions into declarations.
// Ported from llvm/lib/Transforms/IPO/ElimAvailExtern.cpp.

eae_opts: struct {
    convert_to_local := false;            // -avail-extern-to-local
    gv_in_addrspace_to_local: s64 = -1;   // -avail-extern-gv-in-addrspace-to-local (-1 = not given)
};

// getUniqueModuleId (ModuleUtils.cpp)
get_unique_module_id :: () -> string {
    m: Md5;
    usfi := module_flag("Unique Source File Identifier");
    if usfi != NONE && ir.mds[usfi].kind == .TUPLE {
        md5_update_str(*m, ir.mds[md_op(usfi, 0)].str);
    } else {
        exports := false;
        // global_values(): functions, globals, aliases, ifuncs
        lists: [4] *[..] Value_Id;
        lists[0] = *ir.m_functions; lists[1] = *ir.m_globals; lists[2] = *ir.m_aliases; lists[3] = *ir.m_ifuncs;
        for list: lists for gv: list.* {
            if is_declaration(gv) || begins_with(vname(gv), "llvm.") || glob(gv).linkage != .EXTERNAL || gv_comdat(gv) >= 0 continue;
            exports = true;
            md5_update_str(*m, vname(gv));
            zero: [1] u8;
            z: [] u8; z.data = zero.data; z.count = 1;
            md5_update(*m, z);
        }
        if !exports return "";
    }
    r := md5_final(*m);
    return tconcat(".", md5_hex(r));
}

elim_avail_extern_run :: () -> Preserved {
    changed := false;
    for gv: ir.m_globals {
        if glob(gv).linkage != .AVAILABLE_EXTERNALLY continue;
        if eae_opts.gv_in_addrspace_to_local >= 0 && glob(gv).addrspace == cast(u32) eae_opts.gv_in_addrspace_to_local && has_uses(gv) {
            // convertToLocalCopy(M, GV)
            set_name(gv, tconcat(vname(gv), ".__uniq", get_unique_module_id()));
            gv_set_linkage(gv, .INTERNAL);
            changed = true;
            continue;
        }
        if glob(gv).has_init {
            init := gv_initializer(gv);
            gv_set_initializer(gv, NONE);
            if is_safe_to_destroy_constant(init) constant_destroy(init);
        }
        remove_dead_constant_users(gv);
        gv_set_linkage(gv, .EXTERNAL);
        changed = true;
    }
    i := 0;
    while i < ir.m_functions.count {
        f := ir.m_functions[i];
        i += 1;
        if is_declaration(f) || glob(f).linkage != .AVAILABLE_EXTERNALLY continue;
        if eae_opts.convert_to_local fatal("elim-avail-extern: -avail-extern-to-local is not supported yet");
        fn_delete_body(f);
        remove_dead_constant_users(f);
        changed = true;
    }
    if changed { printer_note_ir_changed(); return PRESERVE_NONE; }
    return PRESERVE_ALL;
}
