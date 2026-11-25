// Contextual PGO lowering (`ctx-instr-lower`, PGOCtxProfLoweringPass) and `noinline-nonprevailing`
// (NoinlineNonPrevailing). Ported from llvm/lib/Transforms/Instrumentation/PGOCtxProfLowering.cpp (the whole file
// but the optimization remarks); the cur_ctx node layout is CTXPROF_FUNCTION_DATA of
// llvm/include/llvm/ProfileData/CtxInstrContextNode.h. The instrumentation side (`ctx-instr-gen`) is in
// pass_pgo_instr_gen.jai.

ctx_prof_cl: struct {
    context_roots: [..] string;            // -profile-context-root (cl::list)
    skip_callsite_instr: [..] string;      // -ctx-prof-skip-callsite-instr (cl::list, PGOInstrumentation.cpp)
}

ctx_prof_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == {
        case "profile-context-root"; array_add(*ctx_prof_cl.context_roots, copy_string(prof_str(name, value, has_value)));
        case "ctx-prof-skip-callsite-instr"; array_add(*ctx_prof_cl.skip_callsite_instr, copy_string(prof_str(name, value, has_value)));
        case; return false;
    }
    return true;
}
ctx_prof_takes_value :: (n: string) -> bool { return n == "profile-context-root" || n == "ctx-prof-skip-callsite-instr"; }

// InstrProfCntrInstBase / InstrProfIncrementInst / InstrProfCallsite classification
ctx_instrprof_iid :: (i: Value_Id) -> string {
    if inst_op(i) != .CALL return "";
    cf := call_called_function(i);
    if cf == NONE || !glob(cf).intrinsic return "";
    n := vname(cf);
    if n == "llvm.instrprof.increment" || n == "llvm.instrprof.increment.step" || n == "llvm.instrprof.callsite" ||
       n == "llvm.instrprof.cover" || n == "llvm.instrprof.timestamp" return n;
    return "";
}
ctx_is_increment :: (n: string) -> bool { return n == "llvm.instrprof.increment" || n == "llvm.instrprof.increment.step"; }

// getNumCountersAndCallsites
ctx_num_counters_and_callsites :: (f: Value_Id) -> (u32, u32) {
    nc: u32 = 0; ncs: u32 = 0;
    for bb: fn_blocks(f) for i: block_insts(bb) {
        n := ctx_instrprof_iid(i);
        if ctx_is_increment(n) nc = cast(u32) const_int_zext(op(i, 2));
        else if n == "llvm.instrprof.callsite" ncs = cast(u32) const_int_zext(op(i, 2));
        if nc && ncs return nc, ncs;
    }
    return nc, ncs;
}

Ctx_Lowerer :: struct {
    function_data_ty: Type_Id;
    context_node_ty: Type_Id;
    root_set: Table(Value_Id, bool);
    start_ctx: Value_Id;
    get_ctx: Value_Id;
    release_ctx: Value_Id;
    expected_callee_tls: Value_Id;
    callsite_info_tls: Value_Id;
    cannot_be_root_initializer: Value_Id;
}

ctx_emit_unsupported_root_error :: (f: Value_Id, reason: string) {
    ctx_emit_error(tprint("[ctxprof] The function % was indicated as context root but %, which is not supported.", vname(f), reason));
}

ctx_has_musttail :: (f: Value_Id) -> bool {
    for bb: fn_blocks(f) for i: block_insts(bb) if inst_op(i) == .CALL && call_is_must_tail(i) return true;
    return false;
}

// CtxInstrumentationLowerer::CtxInstrumentationLowerer
ctx_lowerer_init :: (l: *Ctx_Lowerer) {
    l.root_set.allocator = temp;
    ptr := type_ptr(0);
    i8 := type_int(8);
    l.function_data_ty = type_literal_struct(.[ptr, ptr, ptr, ptr, i8], false);
    one := ce_cast(.INTTOPTR, const_int(type_int(cast(u32) dl_ptr_size_bits_as(0)), 1), ptr);
    l.cannot_be_root_initializer = const_aggregate(.C_STRUCT, l.function_data_ty,
        .[const_null_value(ptr), const_null_value(ptr), one, const_null_value(ptr), const_null_value(i8)]);
    l.context_node_ty = type_literal_struct(.[ir.t_i64, ptr, ir.t_i32, ir.t_i32], false);
    for name: ctx_prof_cl.context_roots {
        f := module_get_function(name);
        if f == NONE || is_declaration(f) continue;
        table_set(*l.root_set, f, true);
        for bb: fn_blocks(f) for i: block_insts(bb)
            if is_call_base(i) && inst_op(i) == .CALL && call_is_must_tail(i) ctx_emit_unsupported_root_error(f, "it features musttail calls");
    }
    l.start_ctx = module_get_or_insert_function("__llvm_ctx_profile_start_context", type_func(ptr, .[ptr, ir.t_i64, ir.t_i32, ir.t_i32], false));
    l.get_ctx = module_get_or_insert_function("__llvm_ctx_profile_get_context", type_func(ptr, .[ptr, ptr, ir.t_i64, ir.t_i32, ir.t_i32], false));
    l.release_ctx = module_get_or_insert_function("__llvm_ctx_profile_release_context", type_func(ir.t_void, .[ptr], false));
    if vkind(l.start_ctx) != .FUNCTION || vkind(l.get_ctx) != .FUNCTION || vkind(l.release_ctx) != .FUNCTION
        fatal("ctx-instr-lower: a compiler-rt ctx profiling symbol exists with another type (cast<Function> fails in LLVM)");
    l.callsite_info_tls = gv_create(ptr, false, .EXTERNAL, NONE, "__llvm_ctx_profile_callsite", NONE, 1, dl.globals_as);
    gv_set_visibility(l.callsite_info_tls, 1);
    l.expected_callee_tls = gv_create(ptr, false, .EXTERNAL, NONE, "__llvm_ctx_profile_expected_callee", NONE, 1, dl.globals_as);
    gv_set_visibility(l.expected_callee_tls, 1);
}

// GlobalValue::getGUID (the GUID must have been assigned, e.g. by assign-guid)
ctx_get_guid :: (f: Value_Id) -> u64 {
    m := get_metadata(f, MDK_UNIQUE_ID);
    if m != NONE return const_int_zext(strip_pointer_casts(md_const_int_op_value(m, 0)));
    if is_declaration(f) || begins_with(vname(f), "llvm.") return md5_hash_u64(gv_global_identifier(f));
    fatal(tprint("ctx-instr-lower: the GUID of @% was not assigned (run assign-guid first; LLVM reads an empty optional)", vname(f)));
    return 0;
}
md_const_int_op_value :: (m: Md_Id, k: u32) -> Value_Id {
    o := md_op(m, k);
    if o == NONE || ir.mds[o].kind != .VALUE fatal("ctx-instr-lower: malformed !guid metadata");
    return ir.mds[o].value;
}

// CtxInstrumentationLowerer::lowerFunction
ctx_lower_function :: (l: *Ctx_Lowerer, f: Value_Id) -> bool {
    if is_declaration(f) return false;
    if !fn_can_return(f) {
        for bb: fn_blocks(f) for :early_inc i: block_insts(bb) if ctx_instrprof_iid(i).count erase_inst(i);
        if table_contains(*l.root_set, f) ctx_emit_unsupported_root_error(f, "it does not return");
        return true;
    }
    guid: Value_Id = NONE;
    num_counters, num_callsites := ctx_num_counters_and_callsites(f);
    cur_ctx: Value_Id = NONE;
    real_context: Value_Id = NONE;
    this_context_ty: Type_Id;
    root_function_data: Value_Id = NONE;
    expected_callee_tls_addr: Value_Id = NONE;
    callsite_info_tls_addr: Value_Id = NONE;
    has_musttail := ctx_has_musttail(f);
    if has_musttail && table_contains(*l.root_set, f) {
        ctx_emit_error(tprint("[ctx_prof] A function with musttail calls was explicitly requested as root. That is not supported because we cannot instrument a return instruction to release the context: %", vname(f)));
        return false;
    }
    ptr := type_ptr(0);
    head := fn_entry(f);
    for i: block_insts(head) {
        if !ctx_is_increment(ctx_instrprof_iid(i)) continue;
        b: Irb; irb_set_before(*b, i);
        nv := strip_pointer_casts(op(i, 0));
        if vkind(nv) != .FUNCTION fatal("ctx-instr-lower: the counter's name operand is not a function (cast<Function> fails in LLVM)");
        guid = const_int(ir.t_i64, ctx_get_guid(nv));
        this_context_ty = type_literal_struct(.[l.context_node_ty, type_array(num_counters, ir.t_i64), type_array(num_callsites, ptr)], false);
        root_function_data = gv_create(l.function_data_ty, false, .INTERNAL,
            ifx has_musttail then l.cannot_be_root_initializer else const_null_value(l.function_data_ty), "", NONE, 0, dl.globals_as);
        if table_contains(*l.root_set, f) {
            cur_ctx = irb_call(*b, l.start_ctx, .[root_function_data, guid, const_int(ir.t_i32, num_counters), const_int(ir.t_i32, num_callsites)]);
        } else {
            cur_ctx = irb_call(*b, l.get_ctx, .[root_function_data, f, guid, const_int(ir.t_i32, num_counters), const_int(ir.t_i32, num_callsites)]);
        }
        ctx_as_int := irb_cast(*b, .PTRTOINT, cur_ctx, ir.t_i64);
        if num_callsites > 0 {
            index := irb_binop(*b, .AND, ctx_as_int, const_int(ir.t_i64, 1));
            expected_callee_tls_addr = irb_gep(*b, ptr, cgp_create_thread_local_address(*b, l.expected_callee_tls), .[index]);
            callsite_info_tls_addr = irb_gep(*b, ir.t_i32, cgp_create_thread_local_address(*b, l.callsite_info_tls), .[index]);
        }
        real_context = irb_cast(*b, .INTTOPTR, irb_binop(*b, .AND, ctx_as_int, const_int(ir.t_i64, 0xFFFF_FFFF_FFFF_FFFE)), ptr);
        erase_inst(i);
        break;
    }
    if cur_ctx == NONE return false;

    released := false;
    for bb: fn_blocks(f) for :early_inc i: block_insts(bb) {
        n := ctx_instrprof_iid(i);
        if n.count {
            b: Irb; irb_set_before(*b, i);
            if ctx_is_increment(n) {
                step := ifx n == "llvm.instrprof.increment.step" then op(i, 4) else const_int(ir.t_i64, 1);
                gep := irb_gep(*b, this_context_ty, real_context, .[const_int(ir.t_i32, 0), const_int(ir.t_i32, 1), op(i, 3)]);
                ld := irb_load(*b, ir.t_i64, gep, dl_alignment(ir.t_i64, true));
                irb_store(*b, irb_binop(*b, .ADD, ld, step), gep, dl_alignment(ir.t_i64, true));
            } else if n == "llvm.instrprof.callsite" {
                callee := op(i, 4);
                irb_store(*b, callee, expected_callee_tls_addr, dl_alignment(vtype(callee), true), true);
                g := irb_gep(*b, this_context_ty, cur_ctx, .[const_int(ir.t_i32, 0), const_int(ir.t_i32, 2), op(i, 3)]);
                irb_store(*b, g, callsite_info_tls_addr, dl_alignment(vtype(g), true), true);
            }
            erase_inst(i);
        } else if !has_musttail && inst_op(i) == .RET {
            b: Irb; irb_set_before(*b, i);
            irb_call(*b, l.release_ctx, .[root_function_data]);
            released = true;
        }
    }
    if !has_musttail && !released
        ctx_emit_error(tprint("[ctx_prof] A function that doesn't have musttail calls was instrumented but it has no `ret` instructions above which to release the context: %", vname(f)));
    return true;
}

// PGOCtxProfLoweringPass::run
ctx_instr_lower_run :: () -> Preserved {
    l: Ctx_Lowerer;
    ctx_lowerer_init(*l);
    fns: [..] Value_Id; fns.allocator = temp;
    for ir.m_functions array_add(*fns, it);
    changed := false;
    for f: fns if ctx_lower_function(*l, f) changed = true;
    printer_note_ir_changed();   // the TLS declarations are added in any case
    if !changed return PRESERVE_ALL;
    return PRESERVE_NONE;
}

// NoinlineNonPrevailing::run
noinline_nonprevailing_run :: () -> Preserved {
    changed := false;
    for f: ir.m_functions {
        if is_declaration(f) continue;
        if fn_has_fn_attr(f, .NoInline) continue;
        if !gv_is_weak_for_linker(f) continue;
        if fn_has_fn_attr(f, .AlwaysInline) coro_fn_remove_fn_attr(f, .AlwaysInline);
        fn_add_fn_attr_kind(f, .NoInline);
        changed = true;
    }
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    return PRESERVE_NONE;
}
