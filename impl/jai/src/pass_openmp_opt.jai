// OpenMPOpt: a port of llvm/lib/Transforms/IPO/OpenMPOpt.cpp: OpenMPOptPass::run (openmp-opt, openmp-opt-postlink),
// OpenMPOptCGSCCPass::run (openmp-opt-cgscc), OMPInformationCache (the runtime function table and its uses),
// OpenMPOpt::run with the host transformations (deduplicateRuntimeCalls, collectGlobalThreadIdArguments,
// deleteParallelRegions, hideMemTransfersLatency with OffloadArray, removeRuntimeSymbols, mergeParallelRegions in
// pass_openmp_opt_merge.jai), the device ones (internalization, rewriteDeviceCodeStateMachine, getUniqueKernelFor,
// registerAAs / registerAAsForFunction / registerFoldRuntimeCall) and isOpenMPKernel / getDeviceKernels /
// containsOpenMP / isOpenMPDevice. The abstract attributes (AAICVTracker, AAExecutionDomain, AAHeapToShared,
// AAKernelInfo, AAFoldRuntimeCall) are openmp_aas.jai; the OpenMPIRBuilder pieces omp_ir_builder.jai.
//
// Remarks are never enabled here (no -pass-remarks), so emitRemark and the remark-only paths (printICVs,
// printKernels, analysisGlobalization) do nothing, as in LLVM without a remark consumer.

// cl::opts
omp_opts: struct {
    disable := false;                     // -openmp-opt-disable
    enable_merging := false;              // -openmp-opt-enable-merging
    disable_internalization := false;     // -openmp-opt-disable-internalization
    deduce_icv_values := false;           // -openmp-deduce-icv-values
    print_icv_values := false;            // -openmp-print-icv-values (remarks only)
    print_gpu_kernels := false;           // -openmp-print-gpu-kernels (remarks only)
    hide_memory_transfer_latency := false;   // -openmp-hide-memory-transfer-latency
    disable_deglobalization := false;     // -openmp-opt-disable-deglobalization
    disable_spmdization := false;         // -openmp-opt-disable-spmdization
    disable_folding := false;             // -openmp-opt-disable-folding
    disable_state_machine_rewrite := false;  // -openmp-opt-disable-state-machine-rewrite
    disable_barrier_elimination := false; // -openmp-opt-disable-barrier-elimination
    inline_device := false;               // -openmp-opt-inline-device
    verbose_remarks := false;             // -openmp-opt-verbose-remarks (remarks only)
    max_iterations: s64 = 256;            // -openmp-opt-max-iterations
    shared_limit: u64 = 0xFFFF_FFFF;      // -openmp-opt-shared-limit
};

omp_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    bool_opt :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("invalid boolean value '%' for option -%", value, name);
        return false;
    }
    int_opt :: (name: string, value: string, has_value: bool) -> s64 {
        if !has_value fatal("option -% needs a value", name);
        v, ok, rest := string_to_int(value);
        if !ok || rest.count fatal("invalid integer value '%' for option -%", value, name);
        return v;
    }
    o := *omp_opts;
    if name == {
        case "openmp-opt-disable"; o.disable = bool_opt(name, value, has_value);
        case "openmp-opt-enable-merging"; o.enable_merging = bool_opt(name, value, has_value);
        case "openmp-opt-disable-internalization"; o.disable_internalization = bool_opt(name, value, has_value);
        case "openmp-deduce-icv-values"; o.deduce_icv_values = bool_opt(name, value, has_value);
        case "openmp-print-icv-values"; o.print_icv_values = bool_opt(name, value, has_value);
        case "openmp-print-gpu-kernels"; o.print_gpu_kernels = bool_opt(name, value, has_value);
        case "openmp-hide-memory-transfer-latency"; o.hide_memory_transfer_latency = bool_opt(name, value, has_value);
        case "openmp-opt-disable-deglobalization"; o.disable_deglobalization = bool_opt(name, value, has_value);
        case "openmp-opt-disable-spmdization"; o.disable_spmdization = bool_opt(name, value, has_value);
        case "openmp-opt-disable-folding"; o.disable_folding = bool_opt(name, value, has_value);
        case "openmp-opt-disable-state-machine-rewrite"; o.disable_state_machine_rewrite = bool_opt(name, value, has_value);
        case "openmp-opt-disable-barrier-elimination"; o.disable_barrier_elimination = bool_opt(name, value, has_value);
        case "openmp-opt-inline-device"; o.inline_device = bool_opt(name, value, has_value);
        case "openmp-opt-verbose-remarks"; o.verbose_remarks = bool_opt(name, value, has_value);
        case "openmp-opt-max-iterations"; o.max_iterations = int_opt(name, value, has_value);
        case "openmp-opt-shared-limit"; o.shared_limit = cast(u64) int_opt(name, value, has_value);
        case "openmp-ir-builder-optimistic-attributes"; omp_optimistic_attributes = bool_opt(name, value, has_value);
        case "openmp-opt-print-module-after"; #through;
        case "openmp-opt-print-module-before"; bool_opt(name, value, has_value);   // LLVM_DEBUG output only
        case; return false;
    }
    return true;
}

// ---------------------------------------------------------------- module queries

// llvm::omp::containsOpenMP / isOpenMPDevice / isOpenMPKernel
omp_contains_openmp :: () -> bool { return module_get_flag("openmp") != NONE; }
omp_is_device :: () -> bool { return module_get_flag("openmp-device") != NONE; }
omp_is_kernel :: (f: Value_Id) -> bool { return fn_has_str_attr(f, "kernel"); }
// Function::hasKernelCallingConv: amdgpu_kernel, ptx_kernel, spir_kernel
fn_has_kernel_calling_conv :: (f: Value_Id) -> bool { cc := glob(f).cc; return cc == 91 || cc == 71 || cc == 76; }
// llvm::omp::getDeviceKernels (a SetVector in module order)
omp_get_device_kernels :: () -> [..] Value_Id {
    out: [..] Value_Id; out.allocator = temp;
    for f: ir.m_functions if fn_has_kernel_calling_conv(f) && omp_is_kernel(f) array_add(*out, f);
    return out;
}
omp_contains :: (l: [] Value_Id, v: Value_Id) -> bool { for l if it == v return true; return false; }

// ---------------------------------------------------------------- OMPInformationCache

// RuntimeFunctionInfo; the UsesMap (DenseMap<Function *, std::shared_ptr<UseVector>>) is only looked up, never
// iterated. Key NONE: uses whose user is not an instruction.
Omp_Rfi :: struct {
    kind: Omp_Rtl;
    declaration: Value_Id = NONE;
    is_vararg: bool;
    nargs: s64;
    uses: Table(Value_Id, *[..] Use_Id);
}
Omp_Info_Cache :: struct {
    b: Omp_Builder;
    rfis: [OMP_RTL_COUNT] Omp_Rfi;
    rtf_id: Table(Value_Id, Omp_Rtl);   // RuntimeFunctionIDMap
    rtl_functions: Table(Value_Id, bool);   // RTLFunctions (M.getFunction results, nullptr included)
    cgscc: [..] Value_Id;               // the CGSCC set (empty for the module pass)
    cgscc_set: Table(Value_Id, bool);
    post_link: bool;                    // OpenMPPostLink
}
omp_ic: Omp_Info_Cache;

omp_rfi :: inline (r: Omp_Rtl) -> *Omp_Rfi { return *omp_ic.rfis[cast(s64) r]; }

// RuntimeFunctionInfo::getOrCreateUseVector
omp_get_or_create_use_vector :: (rfi: *Omp_Rfi, f: Value_Id) -> *[..] Use_Id {
    found, uv := table_find(*rfi.uses, f);
    if found return uv;
    uv = New([..] Use_Id);
    table_set(*rfi.uses, f, uv);
    return uv;
}
// RuntimeFunctionInfo::getUseVector (null if none)
omp_get_use_vector :: (rfi: *Omp_Rfi, f: Value_Id) -> *[..] Use_Id {
    found, uv := table_find(*rfi.uses, f);
    if found return uv;
    return null;
}

// RuntimeFunctionInfo::foreachUse(SCC, CB) / foreachUse(CB, F): the body runs with `it` the use and `use_fn` the
// function; setting `delete_use = true` forgets the use (UV[Idx] = UV.back(), pop_back, in reverse index order)
Omp_Rfi_Uses :: struct { rfi: *Omp_Rfi; fns: [] Value_Id; }
omp_rfi_uses :: (rfi: *Omp_Rfi, scc: [] Value_Id) -> Omp_Rfi_Uses { return .{rfi, scc}; }
omp_rfi_uses_in :: (rfi: *Omp_Rfi, f: *Value_Id) -> Omp_Rfi_Uses { r: Omp_Rfi_Uses; r.rfi = rfi; r.fns.data = f; r.fns.count = 1; return r; }
for_expansion :: (r: Omp_Rfi_Uses, body: Code, flags: For_Flags) #expand {
    `it_index := 0;
    for _f: r.fns {
        _uv := omp_get_or_create_use_vector(r.rfi, _f);
        _del: [..] s64; _del.allocator = temp;
        _n := _uv.count;
        for _k: 0.._n - 1 {
            `it := _uv.*[_k];
            `use_fn := _f;
            `delete_use := false;
            defer if delete_use array_add(*_del, _k);
            #insert body;
        }
        while _del.count {
            _idx := pop(*_del);
            _uv.*[_idx] = _uv.*[_uv.count - 1];
            _uv.count -= 1;
        }
    }
}

// declMatchesRTFTypes
omp_decl_matches_rtf_types :: (f: Value_Id, r: Omp_Rtl) -> bool {
    if f == NONE return false;
    if fn_ret_type(f) != omp_rtl_ret_type(r) return false;
    args := omp_rtl_arg_types(r);
    if cast(s64) fn_nargs(f) != args.count return false;
    for k: 0..args.count - 1 if vtype(fn_arg(f, cast(u32) k)) != args[k] return false;
    return true;
}

// collectUses
omp_collect_uses :: (rfi: *Omp_Rfi) -> s64 {
    n := 0;
    if rfi.declaration == NONE return n;
    omp_add_attributes(rfi.kind, rfi.declaration);
    u := ir.v_first_use[rfi.declaration];
    while u != NONE {
        usr := ir.u_user[u];
        if is_inst(usr) {
            uf := inst_fn(usr);
            if omp_ic.cgscc.count == 0 || table_contains(*omp_ic.cgscc_set, uf) {
                array_add(omp_get_or_create_use_vector(rfi, uf), u);
                n += 1;
            }
        } else {
            array_add(omp_get_or_create_use_vector(rfi, NONE), u);
            n += 1;
        }
        u = ir.u_next[u];
    }
    return n;
}
// recollectUsesForFunction / recollectUses
omp_recollect_uses_for_function :: (r: Omp_Rtl) {
    rfi := omp_rfi(r);
    table_reset(*rfi.uses);
    omp_collect_uses(rfi);
}
omp_recollect_uses :: () { for k: 0..OMP_RTL_COUNT - 1 omp_recollect_uses_for_function(cast(Omp_Rtl) k); }

// setCallingConvention: inherit the callee's calling convention
omp_set_calling_convention :: (callee: Value_Id, ci: Value_Id) {
    if vkind(callee) == .FUNCTION inst(ci).cc = glob(callee).cc;
}
// runtimeFnsAvailable
omp_runtime_fns_available :: (fns: [] Omp_Rtl) -> bool {
    if !omp_ic.post_link return true;
    for fns {
        d := omp_rfi(it).declaration;
        if d == NONE || is_declaration(d) return false;
    }
    return true;
}

// OMPInformationCache::OMPInformationCache (initializeRuntimeFunctions; initializeInternalControlVars is the
// constant OMP_ICVS table)
omp_info_cache_init :: (cgscc: [] Value_Id, post_link: bool) {
    for * omp_ic.rfis { table_reset(*it.uses); it.declaration = NONE; }
    table_reset(*omp_ic.rtf_id);
    table_reset(*omp_ic.rtl_functions);
    omp_ic.cgscc.count = 0;
    table_reset(*omp_ic.cgscc_set);
    for cgscc { array_add(*omp_ic.cgscc, it); table_set(*omp_ic.cgscc_set, it, true); }
    omp_ic.post_link = post_link;
    table_reset(*omp_ic.b.src_loc_str_map);
    omp_ic.b.ident_map.count = 0;
    omp_ic.b.is_target_device = omp_is_device();
    // Triple arch nvptx / nvptx64 / amdgpu: IsGPU
    omp_ic.b.is_gpu = false;
    if begins_with(ir.triple, "nvptx") || begins_with(ir.triple, "amdgcn") || begins_with(ir.triple, "r600")
        fatal("openmp-opt: GPU targets are not supported");
    // OMPBuilder.initialize(): initializeTypes creates the named struct types lazily here (omp_struct_type)
    for k: 0..OMP_RTL_COUNT - 1 {
        r := cast(Omp_Rtl) k;
        f := module_get_function(omp_rtl_name(r));
        table_set(*omp_ic.rtl_functions, f, true);
        if !omp_decl_matches_rtf_types(f, r) continue;
        table_set(*omp_ic.rtf_id, f, r);
        rfi := omp_rfi(r);
        rfi.kind = r;
        rfi.is_vararg = OMP_RTL_VARARG[k];
        rfi.nargs = omp_rtl_arg_types(r).count;
        rfi.declaration = f;
        omp_collect_uses(rfi);
    }
    // the final OMP_RTL entry `__last` is looked up too (an EnumeratedArray of OMPRTL___last entries has no slot)
    if module_get_function("__last") != NONE && omp_decl_matches_rtf_types(module_get_function("__last"), .__last)
        fatal("openmp-opt: a function named __last matches the OMPRTL___last entry");
    if omp_is_device() {
        for f: ir.m_functions {
            for prefix: string.["__kmpc", "_ZN4ompx", "omp_"] {
                if fn_has_fn_attr(f, .NoInline) && begins_with(vname(f), prefix) && !fn_has_fn_attr(f, .OptimizeNone)
                    fn_set_attr_list(f, attr_list_without_fn_attr(glob(f).attrs, .NoInline));
            }
        }
    }
}

// ---------------------------------------------------------------- OpenMPOpt

// OpenMPOpt::getCallIfRegularCall(Use &U, RFI) / (Value &V, RFI)
omp_call_if_regular_call_use :: (u: Use_Id, rfi: *Omp_Rfi = null) -> Value_Id {
    ci := ir.u_user[u];
    if !is_inst(ci) || inst_op(ci) != .CALL return NONE;
    if u != op_use(ci, nops(ci) - 1) || call_num_bundles(ci) != 0 return NONE;
    if rfi && (rfi.declaration == NONE || call_called_function(ci) != rfi.declaration) return NONE;
    return ci;
}
omp_call_if_regular_call :: (v: Value_Id, rfi: *Omp_Rfi = null) -> Value_Id {
    if !is_inst(v) || inst_op(v) != .CALL || call_num_bundles(v) != 0 return NONE;
    if rfi && (rfi.declaration == NONE || call_called_function(v) != rfi.declaration) return NONE;
    return v;
}

Omp_Opt :: struct {
    scc: [..] Value_Id;
    is_module_pass: bool;
    unique_kernel_map: Table(Value_Id, Value_Id);   // UniqueKernelMap (looked up only)
    cgscc_c: s32;                                   // the CGSCC pass's current SCC and update result (CGUpdater)
    cgscc_ur: *Cgscc_Ur;
}
oo: Omp_Opt;

// OpenMPOpt::run
omp_opt_run :: (is_module_pass: bool) -> bool {
    if oo.scc.count == 0 return false;
    changed := false;
    if is_module_pass {
        changed |= omp_run_attributor(true);
        omp_recollect_uses();
        changed |= omp_rewrite_device_code_state_machine();
    } else {
        changed |= omp_run_attributor(false);
        omp_recollect_uses();
        changed |= omp_delete_parallel_regions();
        if omp_opts.hide_memory_transfer_latency changed |= omp_hide_mem_transfers_latency();
        changed |= omp_deduplicate_runtime_calls();
        if omp_opts.enable_merging {
            if omp_merge_parallel_regions() {
                omp_deduplicate_runtime_calls();
                changed = true;
            }
        }
    }
    if omp_ic.post_link changed |= omp_remove_runtime_symbols();
    return changed;
}

// OpenMPOpt::runAttributor
omp_run_attributor :: (is_module_pass: bool) -> bool {
    if oo.scc.count == 0 return false;
    omp_register_aas(is_module_pass);
    changed := atr_run();
    // the CallGraphUpdater calls of cleanupIR (reanalyzeFunction) take effect now in the CGSCC pass
    if !is_module_pass oo.cgscc_c = atr_cgscc_reanalyze(oo.cgscc_c, oo.cgscc_ur);
    if changed {
        // OMPInfoCache.invalidateAnalyses(): FAM->clear()
        ac_virtual_clear_all();
        for f: ir.m_functions fam_invalidate(f, PRESERVE_NONE);
    }
    return changed;
}

// OpenMPOpt::deleteParallelRegions
omp_delete_parallel_regions :: () -> bool {
    callback_callee_operand :: 2;
    rfi := omp_rfi(.__kmpc_fork_call);
    if rfi.declaration == NONE return false;
    changed := false;
    for u: omp_rfi_uses(rfi, oo.scc) {
        ci := omp_call_if_regular_call_use(u);
        if ci == NONE continue;
        fnv := strip_pointer_casts(call_arg(ci, callback_callee_operand));
        if vkind(fnv) != .FUNCTION continue;
        if !fn_only_reads_memory(fnv) continue;
        if !fn_has_fn_attr(fnv, .WillReturn) continue;
        erase_inst(ci);
        changed = true;
        delete_use = true;
    }
    return changed;
}

// OpenMPOpt::deduplicateRuntimeCalls()
OMP_DEDUPLICABLE_RUNTIME_CALL_IDS :: Omp_Rtl.[
    .omp_get_num_threads, .omp_in_parallel, .omp_get_cancellation, .omp_get_supported_active_levels, .omp_get_level,
    .omp_get_ancestor_thread_num, .omp_get_team_size, .omp_get_active_level, .omp_in_final, .omp_get_proc_bind,
    .omp_get_num_places, .omp_get_num_procs, .omp_get_place_num, .omp_get_partition_num_places,
    .omp_get_partition_place_nums];
omp_deduplicate_runtime_calls :: () -> bool {
    changed := false;
    gtid_args: [..] Value_Id; gtid_args.allocator = temp;
    omp_collect_global_thread_id_arguments(*gtid_args);
    for f: oo.scc {
        for id: OMP_DEDUPLICABLE_RUNTIME_CALL_IDS changed |= omp_deduplicate_runtime_calls_in(f, omp_rfi(id), NONE);
        gtid_arg: Value_Id = NONE;
        for k: 0..cast(s64) fn_nargs(f) - 1 {
            a := fn_arg(f, cast(u32) k);
            if omp_contains(gtid_args, a) { gtid_arg = a; break; }
        }
        changed |= omp_deduplicate_runtime_calls_in(f, omp_rfi(.__kmpc_global_thread_num), gtid_arg);
    }
    return changed;
}

// combinedIdentStruct
omp_combined_ident_struct :: (cur: Value_Id, next: Value_Id, global_only: bool, single_choice: *bool) -> Value_Id {
    if cur == next return cur;
    if !global_only || is_global_value(vkind(next)) {
        single_choice.* = cur == NONE;
        return next;
    }
    return NONE;
}
// getCombinedIdentFromCallUsesIn
omp_get_combined_ident_from_call_uses_in :: (rfi: *Omp_Rfi, f: Value_Id, global_only: bool) -> Value_Id {
    single_choice := true;
    ident: Value_Id = NONE;
    for u: omp_rfi_uses(rfi, oo.scc) {
        ci := omp_call_if_regular_call_use(u, rfi);
        if ci == NONE || f != use_fn continue;
        ident = omp_combined_ident_struct(ident, call_arg(ci, 0), true, *single_choice);
    }
    if ident == NONE || !single_choice {
        loc, size := omp_get_or_create_default_src_loc_str(*omp_ic.b);
        ident = omp_get_or_create_ident(*omp_ic.b, loc, size);
    }
    return ident;
}

// deduplicateRuntimeCalls(F, RFI, ReplVal)
omp_deduplicate_runtime_calls_in :: (f: Value_Id, rfi: *Omp_Rfi, repl_in: Value_Id) -> bool {
    repl := repl_in;
    uv := omp_get_use_vector(rfi, f);
    if !uv || uv.count + (ifx repl != NONE then 1 else 0) < 2 return false;
    can_be_moved :: (cb: Value_Id) -> bool {
        n := call_num_args(cb);
        if n == 0 return true;
        if vtype(call_arg(cb, 0)) != ir.t_ptr return false;   // IdentPtr
        for k: 1..cast(s64) n - 1 if is_inst(call_arg(cb, cast(u32) k)) return false;
        return true;
    }
    if repl == NONE {
        dt := get_domtree(f);
        ip: Value_Id = NONE;
        for u: uv.* {
            ci := omp_call_if_regular_call_use(u, rfi);
            if ci == NONE continue;
            ip = ifx ip != NONE then dt_find_nearest_common_dominator_inst(dt, ip, ci) else ci;
            if !can_be_moved(ci) continue;
            if repl == NONE repl = ci;
        }
        if repl == NONE return false;
        if repl != ip inst_move_before(repl, ip);
    }
    if is_inst(repl) && is_call_base(repl) {
        if call_num_args(repl) != 0 && vtype(call_arg(repl, 0)) == ir.t_ptr {
            ident := omp_get_combined_ident_from_call_uses_in(rfi, f, true);
            set_op(repl, 0, ident);
        }
    }
    changed := false;
    for u: omp_rfi_uses(rfi, oo.scc) {
        ci := omp_call_if_regular_call_use(u, rfi);
        if ci == NONE || ci == repl || f != use_fn continue;
        replace_all_uses_with(ci, repl);
        erase_inst(ci);
        changed = true;
        delete_use = true;
    }
    return changed;
}

// collectGlobalThreadIdArguments
omp_collect_global_thread_id_arguments :: (gtid_args: *[..] Value_Id) {
    gtn := omp_rfi(.__kmpc_global_thread_num);
    // CallArgOpIsGTId
    call_arg_op_is_gtid :: (f: Value_Id, arg_no: u32, ref_ci: Value_Id, gtid_args: *[..] Value_Id, gtn: *Omp_Rfi) -> bool {
        if !gv_has_local_linkage(f) return false;
        u := ir.v_first_use[f];
        while u != NONE {
            defer u = ir.u_next[u];
            ci := omp_call_if_regular_call_use(u);
            if ci != NONE {
                if arg_no >= call_num_args(ci) fatal("openmp-opt: a global thread id argument beyond the arguments of a call");
                arg_op := call_arg(ci, arg_no);
                if ci == ref_ci || omp_contains(gtid_args.*, arg_op) || omp_call_if_regular_call(arg_op, gtn) != NONE continue;
            }
            return false;
        }
        return true;
    }
    // AddUserArgs
    add_user_args :: (gtid: Value_Id, gtid_args: *[..] Value_Id, gtn: *Omp_Rfi) {
        u := ir.v_first_use[gtid];
        while u != NONE {
            defer u = ir.u_next[u];
            ci := ir.u_user[u];
            if !is_inst(ci) || inst_op(ci) != .CALL continue;
            opno := use_arg_no(u);
            if opno >= call_num_args(ci) continue;   // isArgOperand
            callee := call_called_function(ci);
            if callee == NONE continue;
            if !call_arg_op_is_gtid(callee, opno, ci, gtid_args, gtn) continue;
            if opno >= fn_nargs(callee) fatal("openmp-opt: a global thread id passed as a variadic argument");
            a := fn_arg(callee, opno);
            if !omp_contains(gtid_args.*, a) array_add(gtid_args, a);
        }
    }
    for u: omp_rfi_uses(gtn, oo.scc) {
        ci := omp_call_if_regular_call_use(u, gtn);
        if ci != NONE add_user_args(ci, gtid_args, gtn);
    }
    k := 0;
    while k < gtid_args.count { add_user_args(gtid_args.*[k], gtid_args, gtn); k += 1; }
}

// removeRuntimeSymbols
omp_remove_runtime_symbols :: () -> bool {
    gv := module_get_global_variable("__llvm_rpc_client", true);   // Module::getNamedGlobal
    if gv == NONE return false;
    if has_uses(gv) return false;
    replace_all_uses_with(gv, const_poison(vtype(gv)));
    gv_erase_from_parent(gv);
    return true;
}

// ---------------------------------------------------------------- hideMemTransfersLatency

// OffloadArray
Omp_Offload_Array :: struct {
    array: Value_Id = NONE;
    stored_values: [..] Value_Id;
    last_accesses: [..] Value_Id;
}
OA_DEVICE_ID_ARG_NUM :: 1;
OA_BASE_PTRS_ARG_NUM :: 3;
OA_PTRS_ARG_NUM :: 4;
OA_SIZES_ARG_NUM :: 5;
// OffloadArray::initialize / getValues / isFilled
omp_offload_array_initialize :: (oa: *Omp_Offload_Array, array: Value_Id, before: Value_Id) -> bool {
    ok, size := alloca_allocation_size_bytes(array);
    if !ok return false;
    pointer_size := cast(u64) (dl_ptr_spec(0).bits / 8);
    num_values := size / pointer_size;
    oa.stored_values.allocator = temp; oa.last_accesses.allocator = temp;
    array_resize(*oa.stored_values, cast(s64) num_values);
    array_resize(*oa.last_accesses, cast(s64) num_values);
    for * oa.stored_values it.* = NONE;
    for * oa.last_accesses it.* = NONE;
    bb := inst_block(array);
    if bb != inst_block(before) return false;
    for x: block_insts(bb) {
        if x == before break;
        if inst_op(x) != .STORE continue;
        dst, offset := get_pointer_base_with_constant_offset(op(x, 1));
        if dst == array {
            idx := offset / cast(s64) pointer_size;
            if cast,no_check(u64) idx < num_values {
                oa.stored_values[idx] = get_underlying_object(op(x, 0), 6);
                oa.last_accesses[idx] = x;
            }
        }
    }
    for oa.stored_values if it == NONE || oa.last_accesses[it_index] == NONE return false;
    oa.array = array;
    return true;
}
// getValuesInOffloadArrays
omp_get_values_in_offload_arrays :: (rc: Value_Id, oas: *[3] Omp_Offload_Array) -> bool {
    base_ptrs := call_arg(rc, OA_BASE_PTRS_ARG_NUM);
    ptrs := call_arg(rc, OA_PTRS_ARG_NUM);
    sizes := call_arg(rc, OA_SIZES_ARG_NUM);
    v := get_underlying_object(base_ptrs, 6);
    if !is_inst(v) || inst_op(v) != .ALLOCA return false;
    if !omp_offload_array_initialize(*oas.*[0], v, rc) return false;
    v = get_underlying_object(ptrs, 6);
    if !is_inst(v) || inst_op(v) != .ALLOCA return false;
    if !omp_offload_array_initialize(*oas.*[1], v, rc) return false;
    v = get_underlying_object(sizes, 6);
    if is_global_value(vkind(v)) return is_constant_kind(vkind(v));
    if !is_inst(v) || inst_op(v) != .ALLOCA return false;
    if !omp_offload_array_initialize(*oas.*[2], v, rc) return false;
    return true;
}
// canBeMovedDownwards
omp_can_be_moved_downwards :: (rc: Value_Id) -> Value_Id {
    cur := rc;
    is_worth_it := false;
    while true {
        cur = inst_next(cur);
        if cur == NONE break;
        if may_have_side_effects(cur) || may_read_from_memory(cur) {
            if is_worth_it return cur;
            return NONE;
        }
        is_worth_it = true;
    }
    return block_terminator(inst_block(rc));
}
// splitTargetDataBeginRTC
omp_split_target_data_begin_rtc :: (rc: Value_Id, wait_point: Value_Id) -> bool {
    f := inst_fn(rc);
    entry := fn_entry(f);
    ip := block_first_non_phi_or_dbg_or_alloca(entry);
    aty := omp_async_info_type();
    handle := new_inst(.ALLOCA, type_ptr(dl.alloca_as), 1);
    inst(handle).ty2 = aty;
    inst(handle).align = dl_pref_align(aty);
    inst(handle).addrspace = dl.alloca_as;
    set_op(handle, 0, const_int(type_int(32), 1));
    b: Irb;
    if ip != NONE irb_set_at(*b, entry, ip, false); else irb_set_end(*b, entry);
    irb_insert(*b, handle, "handle");
    // Builder.CreateAddrSpaceCast(Handle, AsyncInfoPtr): a cast instruction unless the alloca is in address space 0
    handle = irb_cast(*b, .ADDRSPACECAST, handle, ir.t_ptr);
    issue := omp_get_or_create_runtime_function(.__tgt_target_data_begin_mapper_issue);
    args: [..] Value_Id; args.allocator = temp;
    for k: 0..cast(s64) call_num_args(rc) - 1 array_add(*args, call_arg(rc, cast(u32) k));
    array_add(*args, handle);
    issue_cs := create_call_fn(issue, args);
    insert_before_named(issue_cs, rc, "");
    omp_set_calling_convention(issue, issue_cs);
    erase_inst(rc);
    wait := omp_get_or_create_runtime_function(.__tgt_target_data_begin_mapper_wait);
    wait_cs := create_call_fn(wait, .[call_arg(issue_cs, OA_DEVICE_ID_ARG_NUM), handle]);
    insert_before_named(wait_cs, wait_point, "");
    omp_set_calling_convention(wait, wait_cs);
    return true;
}
// hideMemTransfersLatency
omp_hide_mem_transfers_latency :: () -> bool {
    rfi := omp_rfi(.__tgt_target_data_begin_mapper);
    changed := false;
    if omp_runtime_fns_available(.[.__tgt_target_data_begin_mapper_issue, .__tgt_target_data_begin_mapper_wait]) {
        for u: omp_rfi_uses(rfi, oo.scc) {
            rc := omp_call_if_regular_call_use(u, rfi);
            if rc == NONE continue;
            oas: [3] Omp_Offload_Array;
            if !omp_get_values_in_offload_arrays(rc, *oas) continue;
            was_split := false;
            wp := omp_can_be_moved_downwards(rc);
            if wp != NONE was_split = omp_split_target_data_begin_rtc(rc, wp);
            changed |= was_split;
            delete_use = was_split;
        }
    }
    return changed;
}

// ---------------------------------------------------------------- the passes

// OpenMPOptPass::run
openmp_opt_run :: (post_link := false) -> Preserved {
    if !omp_contains_openmp() return PRESERVE_ALL;
    if omp_opts.disable return PRESERVE_ALL;
    kernels := omp_get_device_kernels();
    is_called :: (f: Value_Id, kernels: [] Value_Id) -> bool { return omp_contains(kernels, f) || has_uses(f); }
    changed := false;
    internalized: Table(Value_Id, Value_Id); internalized.allocator = temp;
    if omp_is_device() {
        fns: [..] Value_Id; fns.allocator = temp;
        for f: ir.m_functions {
            if !is_declaration(f) && !omp_contains(kernels, f) && is_called(f, kernels) && !omp_opts.disable_internalization {
                if atr_is_internalizable(f) array_add(*fns, f);
                // else: the OMP140 remark
            }
        }
        changed |= atr_internalize_functions(fns, *internalized);
    }
    functions: [..] Value_Id; functions.allocator = temp;
    for f: ir.m_functions if !is_declaration(f) && !table_contains(*internalized, f) array_add(*functions, f);
    if functions.count == 0 {
        if changed { printer_note_ir_changed(); return PRESERVE_NONE; }
        return PRESERVE_ALL;
    }
    omp_info_cache_init(.[], post_link);
    max_iterations := ifx omp_is_device() then omp_opts.max_iterations else 32;
    atr_reset(functions, true, false, false);
    atr.default_init_live_internals = false;
    atr.rewrite_signatures = false;
    atr.max_fixpoint_iterations = max_iterations;
    atr.omp_init_callback = true;
    atr.omp_ipo_amendable_kernels = true;
    atr.delete_fns = true;
    atr_constructor();
    oo.scc.count = 0;
    for functions array_add(*oo.scc, it);
    oo.is_module_pass = true;
    table_reset(*oo.unique_kernel_map);
    changed |= omp_opt_run(true);
    if omp_opts.inline_device && omp_is_device() {
        for f: ir.m_functions {
            if !is_declaration(f) && !omp_contains(kernels, f) && !fn_has_fn_attr(f, .NoInline) fn_add_fn_attr_kind(f, .AlwaysInline);
        }
    }
    atr_finish_deleted_functions();   // the CallGraphUpdater's destructor
    if changed { printer_note_ir_changed(); return PRESERVE_NONE; }
    return PRESERVE_ALL;
}

// OpenMPOptCGSCCPass::run
openmp_opt_cgscc_run :: (c_in: s32, ur: *Cgscc_Ur, post_link := false) -> Preserved {
    if !omp_contains_openmp() return PRESERVE_ALL;
    if omp_opts.disable return PRESERVE_ALL;
    c := c_in;
    functions: [..] Value_Id; functions.allocator = temp;
    for lcg.sccs[c].nodes array_add(*functions, lcg_fn(it));
    if functions.count == 0 return PRESERVE_ALL;
    omp_info_cache_init(functions, post_link);
    max_iterations := ifx omp_is_device() then omp_opts.max_iterations else 32;
    atr_reset(functions, false, false, false);
    atr.default_init_live_internals = false;
    atr.rewrite_signatures = false;
    atr.max_fixpoint_iterations = max_iterations;
    atr.omp_init_callback = true;
    atr.delete_fns = true;
    atr_constructor();
    oo.scc.count = 0;
    for functions array_add(*oo.scc, it);
    oo.is_module_pass = false;
    table_reset(*oo.unique_kernel_map);
    oo.cgscc_c = c;
    oo.cgscc_ur = ur;
    changed := omp_opt_run(false);
    c = oo.cgscc_c;
    atr_cgscc_finalize();   // the CallGraphUpdater's destructor
    if c != c_in ur.updated_c = c;
    if changed { printer_note_ir_changed(); return PRESERVE_NONE; }
    return PRESERVE_ALL;
}
