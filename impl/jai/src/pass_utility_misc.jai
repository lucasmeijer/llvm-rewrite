// Small utility passes (L1.extra.utility):
//   instnamer                     llvm/lib/Transforms/Utils/InstructionNamer.cpp (complete)
//   strip-convergence-intrinsics  llvm/lib/Transforms/Utils/StripConvergenceIntrinsics.cpp (complete)
//   strip, strip-nondebug, strip-dead-cg-profile
//                                 llvm/lib/Transforms/IPO/StripSymbols.cpp (StripSymbolsPass,
//                                 StripNonDebugSymbolsPass, StripDeadCGProfilePass; strip-dead-debug-info is in
//                                 pass_strip_dead_debug_info.jai)
//   metarenamer                   llvm/lib/Transforms/Utils/MetaRenamer.cpp (complete)

// ---------------------------------------------------------------- instnamer

instnamer_run :: (f: Value_Id) -> Preserved {
    g := glob(f);
    if g.nargs > 0 for k: 0..g.nargs - 1 {
        a := fn_arg(f, k);
        if vname(a).count == 0 set_name(a, "arg");
    }
    for bb: fn_blocks(f) {
        if vname(bb).count == 0 set_name(bb, "bb");
        for i: block_insts(bb) if vname(i).count == 0 && vtype(i) != ir.t_void set_name(i, "i");
    }
    return PRESERVE_ALL;
}

// ---------------------------------------------------------------- strip-convergence-intrinsics

strip_convergence_intrinsics_run :: (f: Value_Id) -> Preserved {
    conv: [..] Value_Id; conv.allocator = temp;
    changed := false;
    for bb: fn_blocks(f) {
        for :early_inc block_insts(bb) {
            ci := it;
            if inst_op(ci) != .CALL continue;
            k := call_bundle_index(ci, "convergencectrl");
            if k >= 0 {
                // CallBase::removeOperandBundle(CI, OB_convergencectrl, CI->getIterator()): CallInst::Create(CI,
                // Bundles, InsertPt) named after CI (CI still has the name, so the new call's is uniqued)
                nc := ic_call_remove_bundle_at(ci, cast(u32) k);
                inst_insert_before(nc, ci);
                if vname(ci).count set_name(nc, vname(ci));
                copy_metadata(nc, ci);
                rauw_with_metadata(ci, nc);
                erase_inst_with_metadata(ci);
                ci = nc;
                changed = true;
            }
            id := call_iid(ci);
            if id == IID_EXPERIMENTAL_CONVERGENCE_ENTRY || id == IID_EXPERIMENTAL_CONVERGENCE_LOOP || id == IID_EXPERIMENTAL_CONVERGENCE_ANCHOR
                array_add(*conv, ci);
        }
    }
    for conv erase_inst_with_metadata(it);
    changed |= conv.count > 0;
    if !changed return PRESERVE_ALL;
    return preserved_cfg();
}

// ---------------------------------------------------------------- StripSymbols.cpp

strip_global_constants := false;   // -strip-global-constants (StripDeadDebugInfoPass)

// findUsedValues
ss_find_used_values :: (name: string, used: *Table(Value_Id, bool)) {
    gv := lookup_global(name);
    if gv == NONE || vkind(gv) != .GLOBAL_VAR return;
    table_set(used, gv, true);
    if !glob(gv).has_init return;
    init := op(gv, 0);
    n := nops(init);
    for k: 0..cast(s64) n - 1 {
        x := strip_pointer_casts(op(init, cast(u32) k));
        if is_global_value(vkind(x)) table_set(used, x, true);
    }
}

// TypeFinder::run(M, OnlyNamed): the struct types in TypeFinder order
ss_type_finder_structs :: () -> [..] Type_Id {
    W.tf_structs.count = 0;
    for * W.tf_visited_types it.* = false;
    type_finder_run();
    out: [..] Type_Id; out.allocator = temp;
    for W.tf_structs array_add(*out, it);
    W.tf_structs.count = 0;
    for * W.tf_visited_types it.* = false;
    printer_note_ir_changed();
    return out;
}

// StripSymtab: every local value (and local-linkage global) of the function's symbol table loses its name; the
// StringMap order does not matter (names are only removed)
ss_strip_symtab :: (f: Value_Id, preserve_dbg_info: bool) {
    strip :: (v: Value_Id, preserve_dbg_info: bool) {
        n := vname(v);
        if n.count == 0 return;
        if preserve_dbg_info && begins_with(n, "llvm.dbg") return;
        set_name(v, "");
    }
    g := glob(f);
    if g.nargs > 0 for k: 0..g.nargs - 1 strip(fn_arg(f, k), preserve_dbg_info);
    for bb: fn_blocks(f) {
        strip(bb, preserve_dbg_info);
        for i: block_insts(bb) strip(i, preserve_dbg_info);
    }
}

// StripSymbolNames
ss_strip_symbol_names :: (preserve_dbg_info: bool) {
    used: Table(Value_Id, bool); used.allocator = temp;
    ss_find_used_values("llvm.used", *used);
    ss_find_used_values("llvm.compiler.used", *used);
    for gv: ir.m_globals {
        if is_local_linkage(glob(gv).linkage) && !table_contains(*used, gv)
            if !preserve_dbg_info || !begins_with(vname(gv), "llvm.dbg") set_name(gv, "");
    }
    for f: ir.m_functions {
        if is_local_linkage(glob(f).linkage) && !table_contains(*used, f)
            if !preserve_dbg_info || !begins_with(vname(f), "llvm.dbg") set_name(f, "");
        if !is_declaration(f) ss_strip_symtab(f, preserve_dbg_info);
    }
    // StripTypeNames
    for t: ss_type_finder_structs() {
        r := ir.types[t];
        if (r.flags & TYF_LITERAL) || r.name.count == 0 continue;
        if preserve_dbg_info && begins_with(r.name, "llvm.dbg") continue;
        ctx_set_struct_name(t, "");
    }
    printer_note_ir_changed();
}

strip_symbols_run :: () -> Preserved {
    strip_debug_info();
    ss_strip_symbol_names(false);
    return preserved_cfg();
}
strip_nondebug_run :: () -> Preserved {
    ss_strip_symbol_names(true);
    return preserved_cfg();
}

// StripDeadCGProfilePass
strip_dead_cg_profile_run :: () -> Preserved {
    cg := module_flag("CG Profile");
    if cg == NONE || ir.mds[cg].kind != .TUPLE return PRESERVE_ALL;
    valid: [..] Md_Id; valid.allocator = temp;
    for k: 0..cast(s64) md_nops(cg) - 1 {
        e := md_op(cg, cast(u32) k);
        if e == NONE || !md_is_node(e) continue;
        has_null := false;
        for j: 0..cast(s64) md_nops(e) - 1 if md_op(e, cast(u32) j) == NONE has_null = true;
        if !has_null array_add(*valid, e);
    }
    set_module_flag(5, "CG Profile", md_tuple(valid, true));   // Module::Append
    printer_note_ir_changed();
    return PRESERVE_NONE;
}
// Module::setModuleFlag(Behavior, Key, Metadata *Val)
set_module_flag :: (behavior: u64, key: string, val: Md_Id) {
    k := named_md_get_or_insert("llvm.module.flags");
    flag := md_tuple(.[md_value(const_int(ir.t_i32, behavior)), md_string(key), val], false);
    ops := *ir.named_md[k].ops;
    for m: ops.* {
        if ir.mds[m].nops < 2 continue;
        s := md_op(m, 1);
        if s != NONE && ir.mds[s].kind == .STRING && ir.mds[s].str == key { ops.*[it_index] = flag; return; }
    }
    array_add(ops, flag);
}

// ---------------------------------------------------------------- metarenamer

mr_cl: struct {
    exclude_function_prefixes: string;   // -rename-exclude-function-prefixes
    exclude_alias_prefixes: string;      // -rename-exclude-alias-prefixes
    exclude_global_prefixes: string;     // -rename-exclude-global-prefixes
    exclude_struct_prefixes: string;     // -rename-exclude-struct-prefixes
    only_inst: bool;                     // -rename-only-inst
};
MR_META_NAMES :: string.["foo", "bar", "baz", "quux", "barney", "snork", "zot", "blam", "hoge", "wibble", "wobble",
                         "widget", "wombat", "ham", "eggs", "pluto", "spam"];

mr_parse_prefixes :: (s_in: string) -> [..] string {
    out: [..] string; out.allocator = temp;
    s := s_in;
    while true {
        k := find_index_from_left(s, #char ",");
        first := ifx k >= 0 then slice(s, 0, k) else s;
        if first.count == 0 break;
        array_add(*out, first);
        if k < 0 break;
        s = slice(s, k + 1, s.count - k - 1);
    }
    return out;
}
mr_excluded :: (name: string, prefixes: [] string) -> bool {
    for prefixes if begins_with(name, it) return true;
    return false;
}

metarenamer_run :: () -> Preserved {
    seed: u32 = 0;
    for c: cast([] u8) ir.module_id seed += cast(u32) c;
    next: u64 = seed;   // PRNG (unsigned long)
    new_name :: (next: *u64) -> string {
        next.* = next.* * 1103515245 + 12345;
        r := (cast,trunc(u32)(next.* / 65536)) % 32768;
        return MR_META_NAMES[cast(s64) r % MR_META_NAMES.count];
    }
    ex_alias := mr_parse_prefixes(mr_cl.exclude_alias_prefixes);
    ex_global := mr_parse_prefixes(mr_cl.exclude_global_prefixes);
    ex_struct := mr_parse_prefixes(mr_cl.exclude_struct_prefixes);
    ex_func := mr_parse_prefixes(mr_cl.exclude_function_prefixes);
    exclude_lib_funcs :: (f: Value_Id, ex_func: [] string) -> bool {
        name := vname(f);
        if glob(f).intrinsic || (name.count && name[0] == 1) return true;
        ok, _ := tli_lookup_fn(f);
        if ok return true;
        return mr_excluded(name, ex_func);
    }
    if mr_cl.only_inst {
        for f: ir.m_functions {
            if exclude_lib_funcs(f, ex_func) continue;
            for i: fn_insts(f) if vtype(i) != ir.t_void && vname(i).count == 0 set_name(i, opcode_name(inst_op(i)));
        }
        printer_note_ir_changed();
        return PRESERVE_ALL;
    }
    for ga: ir.m_aliases {
        name := vname(ga);
        if begins_with(name, "llvm.") || (name.count && name[0] == 1) || mr_excluded(name, ex_alias) continue;
        set_name(ga, "alias");
    }
    for gv: ir.m_globals {
        name := vname(gv);
        if begins_with(name, "llvm.") || (name.count && name[0] == 1) || mr_excluded(name, ex_global) continue;
        set_name(gv, "global");
    }
    for t: ss_type_finder_structs() {
        r := ir.types[t];
        if (r.flags & TYF_LITERAL) || r.name.count == 0 || mr_excluded(r.name, ex_struct) continue;
        ctx_set_struct_name(t, tconcat("struct.", new_name(*next)));
    }
    for f: ir.m_functions {
        if exclude_lib_funcs(f, ex_func) continue;
        if vname(f) != "main" set_name(f, new_name(*next));
        // MetaRename(F)
        g := glob(f);
        if g.nargs > 0 for k: 0..g.nargs - 1 set_name(fn_arg(f, k), "arg");
        for bb: fn_blocks(f) {
            set_name(bb, "bb");
            for i: block_insts(bb) if vtype(i) != ir.t_void set_name(i, opcode_name(inst_op(i)));
        }
    }
    printer_note_ir_changed();
    return PRESERVE_ALL;
}
