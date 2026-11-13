// Module passes of the LTO pipelines (pass_builder_pipelines.jai). Most of them only act on constructs the C corpus
// never has (CFI type tests, devirtualization intrinsics, value profiles, variadic lowering for GPU targets); they
// are ported up to their early exit and fail loudly when the input has what they would transform.
// - CrossDSOCFIPass (llvm/lib/Transforms/IPO/CrossDSOCFI.cpp): only with the "Cross-DSO CFI" module flag.
// - GlobalSplitPass (llvm/lib/Transforms/IPO/GlobalSplit.cpp): only with used llvm.type.test / type.checked.load.
// - WholeProgramDevirtPass (llvm/lib/Transforms/IPO/WholeProgramDevirt.cpp, DevirtModule::run without summaries).
// - LowerTypeTestsPass (llvm/lib/Transforms/IPO/LowerTypeTests.cpp, LowerTypeTestsModule::lower without summaries).
// - DropTypeTestsPass (LowerTypeTests.cpp dropTypeTests): ported.
// - SimplifyTypeTestsPass (LowerTypeTests.cpp): only with __typeid_*_global_addr globals.
// - ExpandVariadicsPass (llvm/lib/Transforms/IPO/ExpandVariadics.cpp): no VariadicABIInfo for x86.
// - PGOIndirectCallPromotion (llvm/lib/Transforms/Instrumentation/IndirectCallPromotion.cpp): only with value
//   profile (!prof "VP") metadata.
// - CanonicalizeAliasesPass (llvm/lib/Transforms/Utils/CanonicalizeAliases.cpp): ported.
// - NameAnonGlobalPass (llvm/lib/Transforms/Utils/NameAnonGlobals.cpp): ported.

lto_used_decl :: (name: string) -> bool {
    f := lookup_global(name);
    return f != NONE && vkind(f) == .FUNCTION && has_uses(f);
}

cross_dso_cfi_run :: () -> Preserved {
    if module_flag("Cross-DSO CFI") != NONE fatal("cross-dso-cfi: modules with the \"Cross-DSO CFI\" flag are not supported yet");
    return PRESERVE_ALL;
}

global_split_run :: () -> Preserved {
    if !lto_used_decl("llvm.type.test") && !lto_used_decl("llvm.type.checked.load") && !lto_used_decl("llvm.type.checked.load.relative")
        return PRESERVE_ALL;
    fatal("globalsplit: splitting globals used by type tests is not supported yet");
    return PRESERVE_NONE;
}

whole_program_devirt_run :: () -> Preserved {
    // DevirtModule::run without an export summary (DevirtSpeculatively off: public type tests are not looked at)
    no_tests := !lto_used_decl("llvm.type.test") || !lto_used_decl("llvm.assume");
    if no_tests && !lto_used_decl("llvm.type.checked.load") && !lto_used_decl("llvm.type.checked.load.relative") return PRESERVE_ALL;
    fatal("wholeprogramdevirt: devirtualization (type tests / type.checked.load) is not supported yet");
    return PRESERVE_NONE;
}

lower_type_tests_run :: () -> Preserved {
    if !lto_used_decl("llvm.type.test") && !lto_used_decl("llvm.icall.branch.funnel") return PRESERVE_ALL;
    fatal("lowertypetests: lowering type tests (CFI) is not supported yet");
    return PRESERVE_NONE;
}

// dropTypeTests(M, ShouldDropAll)
drop_type_tests_run :: () -> Preserved {
    drop :: (f: Value_Id) {
        // make_early_inc_range(TypeTestFunc.uses())
        users: [..] Value_Id; users.allocator = temp;
        u := ir.v_first_use[f];
        while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
        for ci: users {
            if vkind(ci) != .INST continue;
            cu: [..] Value_Id; cu.allocator = temp;
            x := ir.v_first_use[ci];
            while x != NONE { array_add(*cu, ir.u_user[x]); x = ir.u_next[x]; }
            for a: cu {
                if vkind(a) == .INST && inst_op(a) == .CALL {
                    callee := call_called_function(a);
                    if callee != NONE && vname(callee) == "llvm.assume" { erase_inst(a); }
                }
            }
            if has_uses(ci) replace_all_uses_with(ci, const_int(ir.t_i1, 1));
            erase_inst(ci);
        }
    }
    tt := lookup_global("llvm.type.test");
    if tt != NONE && vkind(tt) != .FUNCTION tt = NONE;
    if tt != NONE drop(tt);
    ptt := lookup_global("llvm.public.type.test");
    if ptt != NONE && vkind(ptt) != .FUNCTION ptt = NONE;
    if ptt != NONE drop(ptt);
    if tt == NONE && ptt == NONE return PRESERVE_ALL;
    vk := md_fixed("vcall_visibility");
    for g: ir.m_globals while get_metadata(g, vk) != NONE set_metadata(g, vk, NONE);
    printer_note_ir_changed();
    return PRESERVE_NONE;
}

simplify_type_tests_run :: () -> Preserved {
    for g: ir.m_globals {
        n := vname(g);
        if begins_with(n, "__typeid_") && ends_with(n, "_global_addr") fatal("simplify-type-tests: lowered type tests (__typeid_*_global_addr) are not supported yet");
    }
    return PRESERVE_ALL;
}

expand_variadics_run :: () -> Preserved {
    a := triple_parse(ir.triple).arch;
    if a == .amdgpu || a == .r600 || a == .wasm32 || a == .nvptx || a == .nvptx64 || a == .spirv || a == .spirv32 || a == .spirv64
        fatal("expand-variadics: targets with a VariadicABIInfo are not supported");
    return PRESERVE_ALL;
}

pgo_icall_prom_run :: () -> Preserved {
    prof := md_fixed("prof");
    for f: ir.m_functions {
        if is_declaration(f) || fn_has_fn_attr(f, .OptimizeNone) continue;
        for i: fn_insts(f) {
            if !is_call_base(i) continue;
            m := get_metadata(i, prof);
            if m == NONE || ir.mds[m].nops == 0 continue;
            k := md_op(m, 0);
            if k != NONE && ir.mds[k].kind == .STRING && ir.mds[k].str == "VP"
                fatal("pgo-icall-prom: indirect call promotion from value profiles is not supported yet");
        }
    }
    return PRESERVE_ALL;
}

// canonicalizeAlias
canonicalize_alias :: (c: Value_Id, changed: *bool) -> Value_Id {
    if vkind(c) == .ALIAS {
        aliasee := op(c, 0);
        na := canonicalize_alias(aliasee, changed);
        if na != aliasee { set_op(c, 0, na); changed.* = true; }
        return na;
    }
    if vkind(c) != .C_EXPR return c;
    n := nops(c);
    ops := NewArray(n, Value_Id,, allocator = temp);
    same := true;
    for k: 0..cast(s64) n - 1 {
        ops[k] = canonicalize_alias(op(c, cast(u32) k), changed);
        if ops[k] != op(c, cast(u32) k) same = false;
    }
    if same return c;   // ConstantExpr::getWithOperands returns the same constant
    ce := cexpr(c);
    extra: [..] u32; extra.allocator = temp;
    if ce.nidx > 0 for j: 0..ce.nidx - 1 array_add(*extra, ir.u32_pool[ce.idx + j]);
    return const_expr(ce.op, vtype(c), ce.flags, ce.ty2, ops, extra);
}
canonicalize_aliases_run :: () -> Preserved {
    changed := false;
    for ir.m_aliases canonicalize_alias(it, *changed);
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    return PRESERVE_NONE;
}

// nameUnamedGlobals: anon.<MD5 of the defined external function and variable names>.<n>
name_anon_globals_run :: () -> Preserved {
    hash := "";
    get_hash :: (hash: *string) -> string {
        if hash.count return hash.*;
        m: Md5;
        for ir.m_functions if !is_declaration(it) && !gv_has_local_linkage(it) && vname(it).count md5_update_str(*m, vname(it));
        for ir.m_globals if !is_declaration(it) && !gv_has_local_linkage(it) && vname(it).count md5_update_str(*m, vname(it));
        hash.* = copy_string(md5_hex(md5_final(*m)));
        return hash.*;
    }
    count := 0;
    changed := false;
    rename :: (g: Value_Id, hash: *string, count: *int, changed: *bool) {
        if vname(g).count return;
        set_name(g, tconcat("anon.", get_hash(hash), ".", tdec(cast(u64) count.*)));
        count.* += 1;
        changed.* = true;
    }
    // Module::global_objects(): functions, then global variables; then the aliases
    for ir.m_functions rename(it, *hash, *count, *changed);
    for ir.m_globals rename(it, *hash, *count, *changed);
    for ir.m_aliases rename(it, *hash, *count, *changed);
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    return PRESERVE_NONE;
}

// PGOForceFunctionAttrsPass (llvm/lib/Transforms/Instrumentation/PGOForceFunctionAttrs.cpp), with opt's PGO options
// (llvm/tools/opt/NewPMDriver.cpp: -pgo-kind creates the PGOOptions, -pgo-cold-func-opt its ColdOptType)
Pgo_Kind :: enum u8 { NO_PGO; INSTR_GEN; INSTR_USE; SAMPLE_USE; }
Cold_Func_Opt :: enum u8 { DEFAULT; OPT_SIZE; MIN_SIZE; OPT_NONE; }
pgo_opts: struct {
    kind: Pgo_Kind;
    cold_opt: Cold_Func_Opt;
};
pgo_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == "pgo-kind" {
        if value == {
            case "nopgo"; pgo_opts.kind = .NO_PGO;
            case "pgo-instr-gen-pipeline"; pgo_opts.kind = .INSTR_GEN;
            case "pgo-instr-use-pipeline"; pgo_opts.kind = .INSTR_USE;
            case "pgo-sample-use-pipeline"; pgo_opts.kind = .SAMPLE_USE;
            case; fatal("invalid value '%' for option -pgo-kind", value);
        }
        return true;
    }
    if name == "pgo-cold-func-opt" {
        if value == {
            case "default"; pgo_opts.cold_opt = .DEFAULT;
            case "optsize"; pgo_opts.cold_opt = .OPT_SIZE;
            case "minsize"; pgo_opts.cold_opt = .MIN_SIZE;
            case "optnone"; pgo_opts.cold_opt = .OPT_NONE;
            case; fatal("invalid value '%' for option -pgo-cold-func-opt", value);
        }
        return true;
    }
    if name == "profile-file" || name == "cspgo-kind" || name == "memory-profile-file" || name == "profile-remapping-file"
        fatal("unsupported option '-%'", name);
    return false;
}
// Is there a PGOOptions? (only -pgo-kind creates one here; -debug-info-for-profiling and the like are rejected)
pgo_options_present :: () -> bool { return pgo_opts.kind != .NO_PGO; }

pgo_force_function_attrs_run :: () -> Preserved {
    cold := ifx pgo_options_present() then pgo_opts.cold_opt else .DEFAULT;
    if cold == .DEFAULT return PRESERVE_ALL;
    psi := psi_require();
    changed := false;
    for f: ir.m_functions {
        if is_declaration(f) continue;
        if fn_has_fn_attr(f, .OptimizeNone) || fn_has_opt_size(f) continue;
        if !fn_has_fn_attr(f, .Cold) {
            if !psi.has_summary continue;
            if !psi_is_function_cold_in_call_graph(psi, f, get_bfi(f)) continue;
        }
        if cold == {
            case .OPT_SIZE; fn_add_fn_attr_kind(f, .OptimizeForSize);
            case .MIN_SIZE; fn_add_fn_attr_kind(f, .MinSize);
            case .OPT_NONE;
                if fn_has_fn_attr(f, .AlwaysInline) continue;
                fn_add_fn_attr_kind(f, .OptimizeNone);
                fn_add_fn_attr_kind(f, .NoInline);
        }
        changed = true;
    }
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    return PRESERVE_NONE;
}
