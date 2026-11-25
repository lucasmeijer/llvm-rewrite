// DataFlowSanitizer: a port of llvm/lib/Transforms/Instrumentation/DataFlowSanitizer.cpp (DataFlowSanitizerPass
// "dfsan", all cl::opts; the ABI list is a SpecialCaseList, special_case_list.jai).
//
// One `Dfs` per run (DataFlowSanitizer) and one `Dfsf` per instrumented function (DFSanFunction); the DFSanVisitor
// is the switch in dfsv_visit. DFSanFunction's DominatorTree is kept exact during the visit (LLVM updates it through
// SplitEdge and a DomTreeUpdater; only its answers matter, so it is recalculated after each CFG change) and is left
// stale during the -dfsan-debug-nonzero-labels post-pass, as in LLVM (new blocks count as unreachable).

DFS_SHADOW_TLS_ALIGNMENT :: 2;
DFS_MIN_ORIGIN_ALIGNMENT :: 4;
DFS_ARG_TLS_SIZE :: 800;
DFS_RETVAL_TLS_SIZE :: 800;
DFS_SHADOW_WIDTH_BITS :: 8;
DFS_SHADOW_WIDTH_BYTES :: 1;
DFS_ORIGIN_WIDTH_BITS :: 32;
DFS_ORIGIN_WIDTH_BYTES :: 4;
DFS_NUM_ELEMENTS_IN_ARG_ORIGIN_TLS :: DFS_ARG_TLS_SIZE / DFS_ORIGIN_WIDTH_BYTES;

dfsan_cl: struct {
    preserve_alignment: bool;
    abilist_files: [..] string;
    combine_pointer_labels_on_load := true;
    combine_pointer_labels_on_store: bool;
    combine_offset_labels_on_gep := true;
    combine_taint_lookup_tables: [..] string;
    debug_nonzero_labels: bool;
    event_callbacks: bool;
    conditional_callbacks: bool;
    reaches_function_callbacks: bool;
    track_select_control_flow := true;
    instrument_with_call_threshold: s64 = 3500;
    track_origins: s64;
    ignore_personality_routine: bool;
    add_global_name_suffix := true;
};

dfsan_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if !begins_with(name, "dfsan-") return false;
    pb :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("opt: for the --% option: '%' is invalid value for boolean argument! Try 0 or 1", name, value);
        return false;
    }
    pi :: (name: string, value: string, has_value: bool) -> s64 {
        if !has_value fatal("opt: for the --% option: requires a value!", name);
        v, ok, rest := string_to_int(value);
        if !ok || rest.count fatal("opt: for the --% option: '%' value invalid for integer argument!", name, value);
        return v;
    }
    o := *dfsan_cl;
    if name == {
        case "dfsan-preserve-alignment"; o.preserve_alignment = pb(name, value, has_value);
        case "dfsan-abilist";
            if !has_value fatal("opt: for the --% option: requires a value!", name);
            array_add(*o.abilist_files, copy_string(value));
        case "dfsan-combine-pointer-labels-on-load"; o.combine_pointer_labels_on_load = pb(name, value, has_value);
        case "dfsan-combine-pointer-labels-on-store"; o.combine_pointer_labels_on_store = pb(name, value, has_value);
        case "dfsan-combine-offset-labels-on-gep"; o.combine_offset_labels_on_gep = pb(name, value, has_value);
        case "dfsan-combine-taint-lookup-table";
            if !has_value fatal("opt: for the --% option: requires a value!", name);
            array_add(*o.combine_taint_lookup_tables, copy_string(value));
        case "dfsan-debug-nonzero-labels"; o.debug_nonzero_labels = pb(name, value, has_value);
        case "dfsan-event-callbacks"; o.event_callbacks = pb(name, value, has_value);
        case "dfsan-conditional-callbacks"; o.conditional_callbacks = pb(name, value, has_value);
        case "dfsan-reaches-function-callbacks"; o.reaches_function_callbacks = pb(name, value, has_value);
        case "dfsan-track-select-control-flow"; o.track_select_control_flow = pb(name, value, has_value);
        case "dfsan-instrument-with-call-threshold"; o.instrument_with_call_threshold = pi(name, value, has_value);
        case "dfsan-track-origins"; o.track_origins = pi(name, value, has_value);
        case "dfsan-ignore-personality-routine"; o.ignore_personality_routine = pb(name, value, has_value);
        case "dfsan-add-global-name-suffix"; o.add_global_name_suffix = pb(name, value, has_value);
        case; return false;
    }
    return true;
}

Dfs_Wrapper_Kind :: enum u8 { WARNING; DISCARD; FUNCTIONAL; CUSTOM; }

Dfs :: struct {
    int8_ptr, origin_ty, origin_ptr_ty, prim_shadow_ty, prim_shadow_ptr_ty, intptr: Type_Id;
    zero_origin, zero_prim_shadow: Value_Id;
    arg_tls, arg_origin_tls, retval_tls, retval_origin_tls: Value_Id;
    arg_origin_tls_ty: Type_Id;
    union_load, load_label_and_origin, unimplemented, wrapper_extern_weak_null, set_label, nonzero_label: San_Callee;
    vararg_wrapper, load_callback, store_callback, mem_transfer_callback: San_Callee;
    conditional_callback, conditional_callback_origin, reaches_function_callback, reaches_function_callback_origin: San_Callee;
    cmp_callback, chain_origin, chain_origin_if_tainted, mem_origin_transfer, mem_shadow_origin_transfer: San_Callee;
    mem_shadow_origin_conditional_exchange, maybe_store_origin: San_Callee;
    runtime_fns: [..] Value_Id;
    cold_call_weights, origin_store_weights: Md_Id;
    abilist: *Special_Case_List;
    unwrapped_fn_map: Table(Value_Id, Value_Id);
    and_mask, xor_mask, shadow_base, origin_base: u64;
    track_origins: bool;
}

Dfs_Phi_Fixup :: struct { phi: Value_Id; shadow_phi: Value_Id; origin_phi: Value_Id; }
Dfs_Cached_Shadow :: struct { block: Value_Id = NONE; shadow: Value_Id = NONE; }

Dfsf :: struct {
    dfs: *Dfs;
    f: Value_Id;
    dt: *Dom_Tree;
    native_abi: bool;
    force_zero: bool;
    tli: *Tli;
    label_return_alloca: Value_Id = NONE;
    origin_return_alloca: Value_Id = NONE;
    val_shadow: Table(Value_Id, Value_Id);
    val_origin: Table(Value_Id, Value_Id);
    alloca_shadow: Table(Value_Id, Value_Id);
    alloca_origin: Table(Value_Id, Value_Id);
    phi_fixups: [..] Dfs_Phi_Fixup;
    skip: Table(Value_Id, bool);
    nonzero_checks: [..] Value_Id;
    cached_shadows: Table(u64, Dfs_Cached_Shadow);
    cached_collapsed: Table(Value_Id, Value_Id);
    shadow_elements: Table(Value_Id, [..] Value_Id);   // std::set<Value *>: sorted by id (only set operations)
    num_origin_stores: s64;
}

// ---------------------------------------------------------------- DFSanABIList

// getGlobalTypeString
dfs_global_type_string :: (g: Value_Id) -> string {
    t := glob(g).value_type;
    if type_kind(t) == .STRUCT && (ir.types[t].flags & TYF_LITERAL) == 0 return ir.types[t].name;
    return "<unknown type>";
}
dfs_abi_in_module :: (d: *Dfs, cat: string) -> bool { return scl_in_section(d.abilist, "dataflow", "src", ir.module_id, cat); }
dfs_abi_in_fn :: (d: *Dfs, f: Value_Id, cat: string) -> bool {
    return dfs_abi_in_module(d, cat) || scl_in_section(d.abilist, "dataflow", "fun", vname(f), cat);
}
dfs_abi_in_alias :: (d: *Dfs, ga: Value_Id, cat: string) -> bool {
    if dfs_abi_in_module(d, cat) return true;
    if type_kind(glob(ga).value_type) == .FUNC return scl_in_section(d.abilist, "dataflow", "fun", vname(ga), cat);
    return scl_in_section(d.abilist, "dataflow", "global", vname(ga), cat) ||
           scl_in_section(d.abilist, "dataflow", "type", dfs_global_type_string(ga), cat);
}
dfs_is_instrumented :: (d: *Dfs, f: Value_Id) -> bool {
    if vkind(f) == .ALIAS return !dfs_abi_in_alias(d, f, "uninstrumented");
    return !dfs_abi_in_fn(d, f, "uninstrumented");
}
dfs_is_force_zero_labels :: (d: *Dfs, f: Value_Id) -> bool { return dfs_abi_in_fn(d, f, "force_zero_labels"); }
dfs_get_wrapper_kind :: (d: *Dfs, f: Value_Id) -> Dfs_Wrapper_Kind {
    if dfs_abi_in_fn(d, f, "functional") return .FUNCTIONAL;
    if dfs_abi_in_fn(d, f, "discard") return .DISCARD;
    if dfs_abi_in_fn(d, f, "custom") return .CUSTOM;
    return .WARNING;
}

// ---------------------------------------------------------------- types and zero shadows

dfs_shadow_ty :: (d: *Dfs, t: Type_Id) -> Type_Id {
    if !type_is_sized(t) return d.prim_shadow_ty;
    k := type_kind(t);
    if k == .INT || is_vector_type(t) return d.prim_shadow_ty;
    if k == .ARRAY return type_array(type_count(t), dfs_shadow_ty(d, type_elem(t)));
    if k == .STRUCT {
        elts: [..] Type_Id; elts.allocator = temp;
        n := type_nsub(t);
        for i: 0..cast(s64) n - 1 array_add(*elts, dfs_shadow_ty(d, type_sub(t, cast(u32) i)));
        return type_literal_struct(elts, false);
    }
    return d.prim_shadow_ty;
}
dfs_zero_shadow_ty :: (d: *Dfs, t: Type_Id) -> Value_Id {
    if !is_aggregate(t) return d.zero_prim_shadow;
    return const_zero(dfs_shadow_ty(d, t));
}
dfs_zero_shadow :: (d: *Dfs, v: Value_Id) -> Value_Id { return dfs_zero_shadow_ty(d, vtype(v)); }
dfs_is_zero_shadow :: (v: Value_Id) -> bool {
    t := vtype(v);
    if !is_aggregate(t) return vkind(v) == .C_INT && is_null_value(v);
    return vkind(v) == .C_ZERO;
}
dfs_has_load_size_for_fast_path :: (size: u64) -> bool {
    s := size * DFS_SHADOW_WIDTH_BYTES;
    return s % 8 == 0 || s == 4;
}

// ---------------------------------------------------------------- module setup

// DataFlowSanitizer::initializeModule
dfs_initialize_module :: (d: *Dfs) {
    t := san_triple();
    if t.os != .Linux fatal("unsupported operating system");
    if t.arch == {
        case .aarch64; d.and_mask = 0; d.xor_mask = 0x0B00000000000; d.shadow_base = 0; d.origin_base = 0x0200000000000;
        case .x86_64; d.and_mask = 0; d.xor_mask = 0x500000000000; d.shadow_base = 0; d.origin_base = 0x100000000000;
        case .loongarch64; d.and_mask = 0; d.xor_mask = 0x500000000000; d.shadow_base = 0; d.origin_base = 0x100000000000;
        case .systemz; d.and_mask = 0xC00000000000; d.xor_mask = 0; d.shadow_base = 0x080000000000; d.origin_base = 0x1C0000000000;
        case; fatal("unsupported architecture");
    }
    d.int8_ptr = type_ptr(0);
    d.origin_ty = ir.t_i32;
    d.origin_ptr_ty = type_ptr(0);
    d.prim_shadow_ty = ir.t_i8;
    d.prim_shadow_ptr_ty = type_ptr(0);
    d.intptr = type_int(dl_ptr_spec(0).bits);
    d.zero_prim_shadow = const_int(d.prim_shadow_ty, 0);
    d.zero_origin = const_int(d.origin_ty, 0);
    d.cold_call_weights = create_unlikely_branch_weights();
    d.origin_store_weights = create_unlikely_branch_weights();
}

// AttributeList built from fn nounwind + memory(read), a zeroext return and zeroext parameters
dfs_attrs :: (nounwind_readonly: bool, ret_zext: bool, zext_params: [] u32) -> u32 {
    fs: u32 = 0; rs: u32 = 0;
    if nounwind_readonly {
        a: Attr; a.kind = .NoUnwind; a.ty = NONE; fs = attr_set_with(fs, a);
        m: Attr; m.kind = .Memory; m.ty = NONE; m.ival = mem_all(1); fs = attr_set_with(fs, m);
    }
    if ret_zext { a: Attr; a.kind = .ZExt; a.ty = NONE; rs = attr_set_with(rs, a); }
    params: [..] u32; params.allocator = temp;
    for k: zext_params {
        while params.count <= cast(s64) k array_add(*params, 0);
        a: Attr; a.kind = .ZExt; a.ty = NONE;
        params[k] = attr_set_with(params[k], a);
    }
    return attr_list_get(fs, rs, params);
}

// initializeCallbackFunctions
dfs_initialize_callback_functions :: (d: *Dfs) {
    v := ir.t_void; i8 := d.prim_shadow_ty; p := d.int8_ptr; ip := d.intptr; o := d.origin_ty;
    d.load_callback = san_callee("__dfsan_load_callback", v, .[i8, p], dfs_attrs(false, false, .[0]));
    d.store_callback = san_callee("__dfsan_store_callback", v, .[i8, p], dfs_attrs(false, false, .[0]));
    d.mem_transfer_callback = san_callee("__dfsan_mem_transfer_callback", v, .[d.prim_shadow_ptr_ty, ip]);
    d.cmp_callback = san_callee("__dfsan_cmp_callback", v, .[i8], dfs_attrs(false, false, .[0]));
    d.conditional_callback = san_callee("__dfsan_conditional_callback", v, .[i8], dfs_attrs(false, false, .[0]));
    d.conditional_callback_origin = san_callee("__dfsan_conditional_callback_origin", v, .[i8, o], dfs_attrs(false, false, .[0]));
    d.reaches_function_callback = san_callee("__dfsan_reaches_function_callback", v, .[i8, p, o, p], dfs_attrs(false, false, .[0]));
    d.reaches_function_callback_origin = san_callee("__dfsan_reaches_function_callback_origin", v, .[i8, o, p, o, p], dfs_attrs(false, false, .[0]));
}

// initializeRuntimeFunctions
dfs_initialize_runtime_functions :: (d: *Dfs) {
    v := ir.t_void; i8 := d.prim_shadow_ty; p := d.int8_ptr; ip := d.intptr; o := d.origin_ty;
    d.union_load = san_callee("__dfsan_union_load", i8, .[d.prim_shadow_ptr_ty, ip], dfs_attrs(true, true, .[]));
    d.load_label_and_origin = san_callee("__dfsan_load_label_and_origin", type_int(64), .[p, ip], dfs_attrs(true, true, .[]));
    d.unimplemented = san_callee("__dfsan_unimplemented", v, .[p]);
    d.wrapper_extern_weak_null = san_callee("__dfsan_wrapper_extern_weak_null", v, .[p, p]);
    d.set_label = san_callee("__dfsan_set_label", v, .[i8, o, p, ip], dfs_attrs(false, false, .[0, 1]));
    d.nonzero_label = san_callee("__dfsan_nonzero_label", v, .[]);
    d.vararg_wrapper = san_callee("__dfsan_vararg_wrapper", v, .[p]);
    d.chain_origin = san_callee("__dfsan_chain_origin", o, .[o], dfs_attrs(false, true, .[0]));
    d.chain_origin_if_tainted = san_callee("__dfsan_chain_origin_if_tainted", o, .[i8, o], dfs_attrs(false, true, .[0, 1]));
    d.mem_origin_transfer = san_callee("__dfsan_mem_origin_transfer", v, .[p, p, ip]);
    d.mem_shadow_origin_transfer = san_callee("__dfsan_mem_shadow_origin_transfer", v, .[p, p, ip]);
    d.mem_shadow_origin_conditional_exchange = san_callee("__dfsan_mem_shadow_origin_conditional_exchange", v, .[ir.t_i8, p, p, p, ip]);
    d.maybe_store_origin = san_callee("__dfsan_maybe_store_origin", v, .[i8, p, ip, o], dfs_attrs(false, false, .[0, 3]));
    for c: San_Callee.[d.union_load, d.load_label_and_origin, d.unimplemented, d.wrapper_extern_weak_null, d.set_label,
                      d.nonzero_label, d.vararg_wrapper, d.load_callback, d.store_callback, d.mem_transfer_callback,
                      d.conditional_callback, d.conditional_callback_origin, d.reaches_function_callback,
                      d.reaches_function_callback_origin, d.cmp_callback, d.chain_origin, d.chain_origin_if_tainted,
                      d.mem_origin_transfer, d.mem_shadow_origin_transfer, d.mem_shadow_origin_conditional_exchange,
                      d.maybe_store_origin]
        array_add(*d.runtime_fns, strip_pointer_casts(c.callee));
}

dfs_is_runtime_fn :: (d: *Dfs, f: Value_Id) -> bool { for d.runtime_fns if it == f return true; return false; }

// LibAtomicFunction
dfs_lib_atomic_function :: (f: Value_Id) -> bool {
    n := vname(f);
    if n.count == 0 || func_vararg(glob(f).value_type) return false;
    if glob(f).nargs == {
        case 4; return n == "__atomic_load" || n == "__atomic_store";
        case 5; return n == "__atomic_exchange";
        case 6; return n == "__atomic_compare_exchange";
    }
    return false;
}

// addGlobalNameSuffix
dfs_add_global_name_suffix :: (gv: Value_Id) {
    if !dfsan_cl.add_global_name_suffix return;
    name := copy_string(vname(gv),, temp);
    suffix :: ".dfsan";
    set_name(gv, tconcat(name, suffix));
    for *frag: ir.module_asm {
        search := tconcat(".symver ", name, ",");
        pos := find_index_from_left(frag.*, search);
        if pos >= 0 {
            s := frag.*;
            s = sprint("%1%2%3", slice(s, 0, pos), tconcat(".symver ", name, suffix, ","), advance(s, pos + search.count));
            at := find_index_from_left(s, #char "@");
            if at < 0 fatal("unsupported .symver: %", s);
            s = sprint("%1%2%3", slice(s, 0, at), tconcat(suffix, "@"), advance(s, at + 1));
            frag.* = s;
        }
    }
}

// buildExternWeakCheckIfNeeded
dfs_build_extern_weak_check_if_needed :: (d: *Dfs, b: *Irb, f: Value_Id) {
    if glob(f).linkage != .EXTERN_WEAK return;
    s := irb_create_global_string(vname(f));
    san_call(b, d.wrapper_extern_weak_null, .[f, s]);
}

// buildWrapperFunction(F, NewFName, NewFLink, NewFT)
dfs_build_wrapper_function :: (d: *Dfs, f: Value_Id, name: string, linkage: Linkage, nft: Type_Id) -> Value_Id {
    ft := glob(f).value_type;
    nf := new_function(nft, "", glob(f).addrspace);
    gv_set_linkage(nf, linkage);
    array_add(*ir.m_functions, nf);
    if name.count set_name(nf, name);
    ipo_fn_copy_attributes_from(nf, f);
    // removeRetAttrs(typeIncompatible(RetTy, RetAttrs))
    {
        l := glob(nf).attrs;
        rs := attr_list_ret(l);
        kinds: [..] Attr_Kind; kinds.allocator = temp;
        type_incompatible_kinds(func_ret(nft), rs, *kinds);
        for kinds rs = attr_set_remove(rs, it);
        if rs != attr_list_ret(l) glob(nf).attrs = attr_list_get(attr_list_fn(l), rs, ifx l == 0 then .[] else ir.attr_lists[l].params);
    }
    bb := create_block(nf, "entry");
    if func_vararg(ft) {
        l := glob(nf).attrs;
        glob(nf).attrs = attr_list_with_fn(l, attr_set_remove_str(attr_list_fn(l), "split-stack"));
        b: Irb; irb_set_end(*b, bb);
        s := irb_create_global_string(vname(f));
        c := new_inst(.CALL, ir.t_void, 2);
        inst(c).ty2 = d.vararg_wrapper.fty;
        set_op(c, 0, s); set_op(c, 1, d.vararg_wrapper.callee);
        block_append_inst(bb, c);
        block_append_inst(bb, new_inst(.UNREACHABLE, ir.t_void, 0));
    } else {
        np := func_nparams(ft);
        c := new_inst(.CALL, func_ret(ft), np + 1);
        inst(c).ty2 = ft;
        for k: 0..cast(s64) np - 1 set_op(c, cast(u32) k, fn_arg(nf, cast(u32) k));
        set_op(c, np, f);
        block_append_inst(bb, c);
        if func_ret(ft) == ir.t_void block_append_inst(bb, new_inst(.RET, ir.t_void, 0));
        else { r := new_inst(.RET, ir.t_void, 1); set_op(r, 0, c); block_append_inst(bb, r); }
    }
    return nf;
}

// Value::replaceUsesWithIf(New, IsNotCmpUse): instruction users other than icmp; constant users are rebuilt
dfs_replace_uses_not_cmp :: (old: Value_Id, new: Value_Id) {
    consts: [..] Value_Id; consts.allocator = temp;
    u := ir.v_first_use[old];
    while u != NONE {
        nx := ir.u_next[u];
        user := ir.u_user[u];
        k := vkind(user);
        if k == .INST && inst_op(user) == .ICMP { u = nx; continue; }
        if k == .C_EXPR && cexpr(user).op == .ICMP { u = nx; continue; }
        // LLVM 23's BlockAddress has the block as its only operand: it is not a use of the function
        if k == .C_BLOCKADDR { u = nx; continue; }
        if is_constant_kind(k) && !is_global_value(k) {
            seen := false;
            for consts if it == user { seen = true; break; }
            if !seen array_add(*consts, user);
            u = nx;
            continue;
        }
        use_set(u, new);
        u = nx;
    }
    while consts.count {
        c := pop(*consts);
        if vkind(c) == .DEAD continue;
        constant_handle_operand_change(c, old, new);
    }
}

// ---------------------------------------------------------------- DataFlowSanitizer::runImpl

dfsan_run :: () -> Preserved {
    if check_if_already_instrumented("nosanitize_dataflow") return PRESERVE_ALL;
    d: Dfs;
    d.runtime_fns.allocator = temp;
    d.unwrapped_fn_map.allocator = temp;
    d.abilist = scl_create_or_die(dfsan_cl.abilist_files);
    d.track_origins = dfsan_cl.track_origins != 0;
    if !dfs_run_impl(*d) return PRESERVE_ALL;
    printer_note_ir_changed();
    pa: Preserved; pa.abandon_globals_aa = true;
    return pa;
}

dfs_run_impl :: (d: *Dfs) -> bool {
    dfs_initialize_module(d);
    if dfs_abi_in_module(d, "skip") return false;
    initial_global_size := ir.m_globals.count;
    initial_module_size := ir.m_functions.count;
    changed := false;
    get_or_insert_tls :: (name: string, ty: Type_Id, changed: *bool) -> Value_Id {
        g := module_get_or_insert_global(name, ty);
        changed.* |= glob(g).tls != 3;
        glob(g).tls = 3;
        return g;
    }
    d.arg_tls = get_or_insert_tls("__dfsan_arg_tls", type_array(DFS_ARG_TLS_SIZE / 8, type_int(64)), *changed);
    d.retval_tls = get_or_insert_tls("__dfsan_retval_tls", type_array(DFS_RETVAL_TLS_SIZE / 8, type_int(64)), *changed);
    d.arg_origin_tls_ty = type_array(DFS_NUM_ELEMENTS_IN_ARG_ORIGIN_TLS, d.origin_ty);
    d.arg_origin_tls = get_or_insert_tls("__dfsan_arg_origin_tls", d.arg_origin_tls_ty, *changed);
    d.retval_origin_tls = get_or_insert_tls("__dfsan_retval_origin_tls", d.origin_ty, *changed);
    {
        g := lookup_global("__dfsan_track_origins");
        if g == NONE || vkind(g) != .GLOBAL_VAR {
            changed = true;
            v := ifx d.track_origins then dfsan_cl.track_origins else 0;
            gv_create(d.origin_ty, true, .WEAK_ODR, const_int_signed(d.origin_ty, v), "__dfsan_track_origins", NONE, 0, dl.globals_as);
        }
    }
    dfs_initialize_callback_functions(d);
    dfs_initialize_runtime_functions(d);

    fns: [..] Value_Id; fns.allocator = temp;       // FnsToInstrument (NONE = nullptr)
    native: [..] Value_Id; native.allocator = temp;   // FnsWithNativeABI
    force_zero: [..] Value_Id; force_zero.allocator = temp;
    personality_fns: [..] Value_Id; personality_fns.allocator = temp;
    snapshot: [..] Value_Id; snapshot.allocator = temp;
    for ir.m_functions array_add(*snapshot, it);
    for f: snapshot {
        if glob(f).intrinsic || dfs_is_runtime_fn(d, f) || dfs_lib_atomic_function(f) || fn_has_fn_attr(f, .DisableSanitizerInstrumentation) continue;
        array_add(*fns, f);
        if glob(f).has_personality {
            p := strip_pointer_casts(fn_personality(f));
            seen := false;
            for personality_fns if it == p { seen = true; break; }
            if !seen array_add(*personality_fns, p);
        }
    }
    if dfsan_cl.ignore_personality_routine {
        for c: personality_fns {
            if vkind(c) != .FUNCTION fatal("dfsan: a personality routine that is not a function");
            if !dfs_is_instrumented(d, c) {
                k := 0;
                while k < fns.count { if fns[k] == c array_ordered_remove_by_index(*fns, k); else k += 1; }
            }
        }
    }

    // aliases
    aliases: [..] Value_Id; aliases.allocator = temp;
    for ir.m_aliases array_add(*aliases, it);
    for ga: aliases {
        f := gv_aliasee_object(op(ga, 0));
        if f == NONE || vkind(f) != .FUNCTION continue;
        ga_inst := dfs_is_instrumented(d, ga);
        f_inst := dfs_is_instrumented(d, f);
        if ga_inst && f_inst {
            dfs_add_global_name_suffix(ga);
        } else if ga_inst != f_inst {
            nf := dfs_build_wrapper_function(d, f, "", glob(ga).linkage, glob(f).value_type);
            ipo_rauw(ga, nf);
            gv_take_name(nf, ga);
            gv_erase_from_parent(ga);
            array_add(*fns, nf);
        }
    }

    // First, change the ABI of every function in the module.
    fi := 0;
    fe := fns.count;
    while fi != fe {
        f := fns[fi];
        ft := glob(f).value_type;
        zero_args_void_ret := func_nparams(ft) == 0 && !func_vararg(ft) && func_ret(ft) == ir.t_void;
        if dfs_is_instrumented(d, f) {
            if dfs_is_force_zero_labels(d, f) array_add(*force_zero, f);
            dfs_add_global_name_suffix(f);
        } else if !zero_args_void_ret || dfs_get_wrapper_kind(d, f) == .CUSTOM {
            l := glob(f).linkage;
            wl: Linkage = ifx l == .INTERNAL || l == .PRIVATE then l else .LINKONCE_ODR;
            nf := dfs_build_wrapper_function(d, f, tconcat(ifx d.track_origins then "dfso$" else "dfsw$", vname(f)), wl, ft);
            {
                nl := glob(nf).attrs;
                glob(nf).attrs = attr_list_with_fn(nl, attr_set_remove(attr_list_fn(nl), .Memory));
            }
            dfs_replace_uses_not_cmp(f, nf);
            table_set(*d.unwrapped_fn_map, nf, f);
            fns[fi] = nf;
            if !is_declaration(f) {
                array_add(*native, f);
                array_add(*fns, f);
            }
        } else if func_vararg(ft) {
            table_set(*d.unwrapped_fn_map, f, f);
            fns[fi] = NONE;
        }
        fi += 1;
    }

    for f: fns {
        if f == NONE || is_declaration(f) continue;
        remove_unreachable_blocks(f, null);
        s: Dfsf;
        s.dfs = d; s.f = f;
        s.native_abi = array_find(native, f);
        s.force_zero = array_find(force_zero, f);
        s.tli = tli_for(f);
        s.val_shadow.allocator = temp; s.val_origin.allocator = temp;
        s.alloca_shadow.allocator = temp; s.alloca_origin.allocator = temp;
        s.phi_fixups.allocator = temp; s.skip.allocator = temp; s.nonzero_checks.allocator = temp;
        s.cached_shadows.allocator = temp; s.cached_collapsed.allocator = temp; s.shadow_elements.allocator = temp;
        s.dt = dt_new(false);
        dt_recalculate(s.dt, f);
        dfs_instrument_function(*s);
    }
    return changed || fns.count != 0 || ir.m_globals.count != initial_global_size || ir.m_functions.count != initial_module_size;
}

// the body of runImpl's per-function loop
dfs_instrument_function :: (s: *Dfsf) {
    d := s.dfs;
    f := s.f;
    if dfsan_cl.reaches_function_callbacks {
        for k: 0..cast(s64) glob(f).nargs - 1 {
            farg := fn_arg(f, cast(u32) k);
            next := block_first(fn_entry(f));
            fsh := dfsf_get_shadow(s, farg);
            if dfs_is_zero_shadow(fsh) continue;
            if vkind(fsh) == .INST next = inst_next(fsh);
            if d.track_origins {
                o := dfsf_get_origin(s, farg);
                if vkind(o) == .INST {
                    on := inst_next(o);
                    if comes_before(next, on) next = on;
                }
            }
            b: Irb; irb_set_before(*b, next);
            dfsf_add_reaches_function_callbacks(s, *b, next, farg);
        }
    }

    // depth_first(&F->getEntryBlock())
    bbs: [..] Value_Id; bbs.allocator = temp;
    {
        visited: Table(Value_Id, bool); visited.allocator = temp;
        Frame :: struct { bb: Value_Id; succs: [..] Value_Id; next: s64; }
        stack: [..] Frame; stack.allocator = temp;
        entry := fn_entry(f);
        table_set(*visited, entry, true);
        array_add(*bbs, entry);
        fr: Frame; fr.bb = entry; fr.succs.allocator = temp; block_successors(entry, *fr.succs);
        array_add(*stack, fr);
        while stack.count {
            top := *stack[stack.count - 1];
            if top.next < top.succs.count {
                sb := top.succs[top.next];
                top.next += 1;
                if table_contains(*visited, sb) continue;
                table_set(*visited, sb, true);
                array_add(*bbs, sb);
                nf: Frame; nf.bb = sb; nf.succs.allocator = temp; block_successors(sb, *nf.succs);
                array_add(*stack, nf);
            } else {
                pop(*stack);
            }
        }
    }
    for bb: bbs {
        i := block_first(bb);
        while true {
            nx := inst_next(i);
            is_term := is_terminator(inst_op(i));
            if !table_contains(*s.skip, i) dfsv_visit(s, i);
            if is_term break;
            i = nx;
        }
    }

    for p: s.phi_fixups {
        n := nops(p.phi);
        for k: 0..cast(s64) n - 1 {
            iv := phi_value(p.phi, cast(u32) k);
            phi_set_value(p.shadow_phi, cast(u32) k, dfsf_get_shadow(s, iv));
            if p.origin_phi != NONE phi_set_value(p.origin_phi, cast(u32) k, dfsf_get_origin(s, iv));
        }
    }

    if dfsan_cl.debug_nonzero_labels {
        for v: s.nonzero_checks {
            pos: Value_Id;
            if vkind(v) == .INST pos = inst_next(v);
            else pos = block_first(fn_entry(f));
            while inst_op(pos) == .PHI || inst_op(pos) == .ALLOCA pos = inst_next(pos);
            b: Irb; irb_set_before(*b, pos);
            ps := dfsf_collapse_to_primitive_shadow_at(s, v, pos);
            ne := irb_icmp(*b, ICMP_NE, ps, d.zero_prim_shadow);
            bi := sbi_if_then(ne, pos, false, d.cold_call_weights);
            tb: Irb; irb_set_before(*tb, bi);
            san_call(*tb, d.nonzero_label, .[]);
        }
    }
}

// ---------------------------------------------------------------- DFSanFunction: shadows and origins

dfsf_get_arg_tls :: (s: *Dfsf, off: u64, b: *Irb) -> Value_Id {
    return irb_gep(b, ir.t_i8, s.dfs.arg_tls, .[const_int(s.dfs.intptr, off)], "_dfsarg");
}
dfsf_get_retval_tls :: (s: *Dfsf, b: *Irb) -> Value_Id { return irb_pointer_cast(b, s.dfs.retval_tls, type_ptr(0), "_dfsret"); }
dfsf_get_arg_origin_tls :: (s: *Dfsf, argno: u64, b: *Irb) -> Value_Id {
    return irb_gep(b, s.dfs.arg_origin_tls_ty, s.dfs.arg_origin_tls, .[const_int(type_int(64), 0), const_int(type_int(64), argno)], "_dfsarg_o", F_INBOUNDS);
}

dfsf_get_origin :: (s: *Dfsf, v: Value_Id) -> Value_Id {
    d := s.dfs;
    k := vkind(v);
    if k != .ARGUMENT && k != .INST return d.zero_origin;
    found, o := table_find(*s.val_origin, v);
    if found && o != NONE return o;
    if k == .ARGUMENT {
        if s.native_abi return d.zero_origin;
        argno := arg_numbers[ir.v_aux[v]];
        if argno < DFS_NUM_ELEMENTS_IN_ARG_ORIGIN_TLS {
            b: Irb; irb_set_before(*b, block_first(fn_entry(s.f)));
            ptr := dfsf_get_arg_origin_tls(s, argno, *b);
            o = irb_load(*b, d.origin_ty, ptr, dl_abi_align(d.origin_ty));
        } else o = d.zero_origin;
    } else o = d.zero_origin;
    table_set(*s.val_origin, v, o);
    return o;
}
dfsf_set_origin :: (s: *Dfsf, i: Value_Id, o: Value_Id) {
    if !s.dfs.track_origins return;
    table_set(*s.val_origin, i, o);
}

// getShadowForTLSArgument
dfsf_get_shadow_for_tls_argument :: (s: *Dfsf, a: Value_Id) -> Value_Id {
    d := s.dfs;
    off: u64 = 0;
    for k: 0..cast(s64) glob(s.f).nargs - 1 {
        farg := fn_arg(s.f, cast(u32) k);
        if !type_is_sized(vtype(farg)) {
            if a == farg break;
            continue;
        }
        size := dl_type_alloc_size(dfs_shadow_ty(d, vtype(farg)));
        if a != farg {
            off += align_to(size, DFS_SHADOW_TLS_ALIGNMENT);
            if off > DFS_ARG_TLS_SIZE break;
            continue;
        }
        if off + size > DFS_ARG_TLS_SIZE break;
        b: Irb; irb_set_before(*b, block_first(fn_entry(s.f)));
        ptr := dfsf_get_arg_tls(s, off, *b);
        return irb_load(*b, dfs_shadow_ty(d, vtype(farg)), ptr, DFS_SHADOW_TLS_ALIGNMENT);
    }
    return dfs_zero_shadow(d, a);
}

dfsf_get_shadow :: (s: *Dfsf, v: Value_Id) -> Value_Id {
    d := s.dfs;
    k := vkind(v);
    if k != .ARGUMENT && k != .INST return dfs_zero_shadow(d, v);
    if s.force_zero return dfs_zero_shadow(d, v);
    found, sh := table_find(*s.val_shadow, v);
    if found && sh != NONE return sh;
    if k == .ARGUMENT {
        if s.native_abi return dfs_zero_shadow(d, v);
        sh = dfsf_get_shadow_for_tls_argument(s, v);
        table_set(*s.val_shadow, v, sh);
        array_add(*s.nonzero_checks, sh);
    } else {
        sh = dfs_zero_shadow(d, v);
        table_set(*s.val_shadow, v, sh);
    }
    return sh;
}
dfsf_set_shadow :: (s: *Dfsf, i: Value_Id, sh: Value_Id) { table_set(*s.val_shadow, i, sh); }

// expandFromPrimitiveShadowRecursive
dfs_expand_rec :: (b: *Irb, shadow_in: Value_Id, idxs: *[..] u32, sub_ty: Type_Id, ps: Value_Id) -> Value_Id {
    shadow := shadow_in;
    k := type_kind(sub_ty);
    if k == .ARRAY {
        for i: 0..cast(s64) type_count(sub_ty) - 1 {
            array_add(idxs, cast(u32) i);
            shadow = dfs_expand_rec(b, shadow, idxs, type_elem(sub_ty), ps);
            pop(idxs);
        }
        return shadow;
    }
    if k == .STRUCT {
        for i: 0..cast(s64) type_nsub(sub_ty) - 1 {
            array_add(idxs, cast(u32) i);
            shadow = dfs_expand_rec(b, shadow, idxs, type_sub(sub_ty, cast(u32) i), ps);
            pop(idxs);
        }
        return shadow;
    }
    return irb_insert_value(b, shadow, ps, idxs.*);
}

// expandFromPrimitiveShadow(T, PrimitiveShadow, Pos)
dfsf_expand_from_primitive_shadow :: (s: *Dfsf, t: Type_Id, ps: Value_Id, pos: Value_Id) -> Value_Id {
    d := s.dfs;
    sty := dfs_shadow_ty(d, t);
    if !is_aggregate(sty) return ps;
    if dfs_is_zero_shadow(ps) return dfs_zero_shadow_ty(d, sty);
    b: Irb; irb_set_before(*b, pos);
    idxs: [..] u32; idxs.allocator = temp;
    sh := dfs_expand_rec(*b, const_undef(sty), *idxs, sty, ps);
    table_set(*s.cached_collapsed, sh, ps);
    return sh;
}

// collapseAggregateShadow / collapseToPrimitiveShadow(Shadow, IRB)
dfsf_collapse_irb :: (s: *Dfsf, sh: Value_Id, b: *Irb) -> Value_Id {
    t := vtype(sh);
    if !is_aggregate(t) return sh;
    n := ifx type_kind(t) == .ARRAY then type_count(t) else cast(u64) type_nsub(t);
    if n == 0 return s.dfs.zero_prim_shadow;
    first := irb_extract_value(b, sh, .[0]);
    agg := dfsf_collapse_irb(s, first, b);
    for i: 1..cast(s64) n - 1 {
        item := irb_extract_value(b, sh, .[cast(u32) i]);
        inner := dfsf_collapse_irb(s, item, b);
        agg = irb_binop(b, .OR, agg, inner);
    }
    return agg;
}

// collapseToPrimitiveShadow(Shadow, Pos)
dfsf_collapse_to_primitive_shadow_at :: (s: *Dfsf, sh: Value_Id, pos: Value_Id) -> Value_Id {
    if !is_aggregate(vtype(sh)) return sh;
    found, cs := table_find(*s.cached_collapsed, sh);
    if found && cs != NONE && dt_dominates_inst(s.dt, cs, pos) return cs;
    b: Irb; irb_set_before(*b, pos);
    ps := dfsf_collapse_irb(s, sh, *b);
    table_set(*s.cached_collapsed, sh, ps);
    return ps;
}

// addConditionalCallbacksIfEnabled
dfsf_add_conditional_callbacks :: (s: *Dfsf, i: Value_Id, cond: Value_Id) {
    if !dfsan_cl.conditional_callbacks return;
    d := s.dfs;
    b: Irb; irb_set_before(*b, i);
    csh := dfsf_get_shadow(s, cond);
    ci: Value_Id;
    if d.track_origins {
        co := dfsf_get_origin(s, cond);
        ci = san_call(*b, d.conditional_callback_origin, .[csh, co]);
    } else ci = san_call(*b, d.conditional_callback, .[csh]);
    call_add_param_attr_kind(ci, 0, .ZExt);
}

// addReachesFunctionCallbacksIfEnabled
dfsf_add_reaches_function_callbacks :: (s: *Dfsf, b: *Irb, i: Value_Id, data: Value_Id) {
    if !dfsan_cl.reaches_function_callbacks return;
    d := s.dfs;
    dbgloc := get_metadata(i, 0);
    dsh := dfsf_collapse_irb(s, dfsf_get_shadow(s, data), b);
    line: Value_Id; path: Value_Id;
    if dbgloc == NONE {
        line = const_int(ir.t_i32, 0);
        path = irb_create_global_string(ir.source_filename);
    } else {
        line = const_int(ir.t_i32, diloc_line(dbgloc));
        path = irb_create_global_string(diloc_filename(dbgloc));
    }
    fname := irb_create_global_string(vname(block_fn(inst_block(i))));
    cb: Value_Id;
    if d.track_origins {
        o := dfsf_get_origin(s, data);
        cb = san_call(b, d.reaches_function_callback_origin, .[dsh, o, path, line, fname]);
    } else {
        cb = san_call(b, d.reaches_function_callback, .[dsh, path, line, fname]);
    }
    call_add_param_attr_kind(cb, 0, .ZExt);
    set_metadata(cb, 0, dbgloc);
}

// ConstantInt::get(IntptrTy, uint64_t C): zero-extended above 64 bits. Below 64 bits a C that does not fit keeps
// its high bits in a release build and LLVM prints it as an unparsable `i32 ` operand: fail loudly.
dfs_intptr_const :: (d: *Dfs, c: u64) -> Value_Id {
    w := type_int_width(d.intptr);
    if w > 64 return const_int_words(d.intptr, .[c, 0]);
    if w < 64 && (c >> w) != 0 fatal("dfsan: the shadow mapping constant % does not fit the % bit pointer type (LLVM keeps the high bits and prints an unparsable constant)", c, w);
    return const_int(d.intptr, c);
}

// getShadowOffset
dfs_get_shadow_offset :: (d: *Dfs, addr: Value_Id, b: *Irb) -> Value_Id {
    off := irb_pointer_cast(b, addr, d.intptr);
    if d.and_mask off = irb_binop(b, .AND, off, dfs_intptr_const(d, ~d.and_mask));
    if d.xor_mask off = irb_binop(b, .XOR, off, dfs_intptr_const(d, d.xor_mask));
    return off;
}

// getShadowOriginAddress
dfs_get_shadow_origin_address :: (d: *Dfs, addr: Value_Id, align: u64, pos: Value_Id) -> (Value_Id, Value_Id) {
    b: Irb; irb_set_before(*b, pos);
    soff := dfs_get_shadow_offset(d, addr, *b);
    sl := soff;
    if d.shadow_base != 0 sl = irb_binop(*b, .ADD, sl, dfs_intptr_const(d, d.shadow_base));
    sptr := irb_cast(*b, .INTTOPTR, sl, type_ptr(0));
    optr: Value_Id = NONE;
    if d.track_origins {
        ol := soff;
        if d.origin_base != 0 ol = irb_binop(*b, .ADD, ol, dfs_intptr_const(d, d.origin_base));
        a := ifx align == 0 then cast(u64) 1 else align;
        if a < DFS_MIN_ORIGIN_ALIGNMENT {
            mask: u64 = DFS_MIN_ORIGIN_ALIGNMENT - 1;
            ol = irb_binop(*b, .AND, ol, dfs_intptr_const(d, ~mask));
        }
        optr = irb_cast(*b, .INTTOPTR, ol, d.origin_ptr_ty);
    }
    return sptr, optr;
}

// getShadowAddress(Addr, Pos)
dfs_get_shadow_address :: (d: *Dfs, addr: Value_Id, pos: Value_Id) -> Value_Id {
    b: Irb; irb_set_before(*b, pos);
    sa := dfs_get_shadow_offset(d, addr, *b);
    if d.shadow_base != 0 sa = irb_binop(*b, .ADD, sa, dfs_intptr_const(d, d.shadow_base));
    b2: Irb; irb_set_before(*b2, pos);
    return irb_cast(*b2, .INTTOPTR, sa, d.prim_shadow_ptr_ty);
}

dfsf_combine_shadows_then_convert :: (s: *Dfsf, t: Type_Id, v1: Value_Id, v2: Value_Id, pos: Value_Id) -> Value_Id {
    pv := dfsf_combine_shadows(s, v1, v2, pos);
    return dfsf_expand_from_primitive_shadow(s, t, pv, pos);
}

dfs_set_contains :: (set: [] Value_Id, v: Value_Id) -> bool { for set if it == v return true; return false; }
dfs_set_includes :: (a: [] Value_Id, b: [] Value_Id) -> bool { for b if !dfs_set_contains(a, it) return false; return true; }
dfs_set_insert :: (set: *[..] Value_Id, v: Value_Id) { if !dfs_set_contains(set.*, v) array_add(set, v); }

// combineShadows(V1, V2, Pos)
dfsf_combine_shadows :: (s: *Dfsf, v1: Value_Id, v2: Value_Id, pos: Value_Id) -> Value_Id {
    if dfs_is_zero_shadow(v1) return dfsf_collapse_to_primitive_shadow_at(s, v2, pos);
    if dfs_is_zero_shadow(v2) return dfsf_collapse_to_primitive_shadow_at(s, v1, pos);
    if v1 == v2 return dfsf_collapse_to_primitive_shadow_at(s, v1, pos);
    e1 := table_find_pointer(*s.shadow_elements, v1);
    e2 := table_find_pointer(*s.shadow_elements, v2);
    if e1 && e2 {
        if dfs_set_includes(e1.*, e2.*) return dfsf_collapse_to_primitive_shadow_at(s, v1, pos);
        if dfs_set_includes(e2.*, e1.*) return dfsf_collapse_to_primitive_shadow_at(s, v2, pos);
    } else if e1 {
        if dfs_set_contains(e1.*, v2) return dfsf_collapse_to_primitive_shadow_at(s, v1, pos);
    } else if e2 {
        if dfs_set_contains(e2.*, v1) return dfsf_collapse_to_primitive_shadow_at(s, v2, pos);
    }
    lo := min(v1, v2); hi := max(v1, v2);
    key := ((cast(u64) lo) << 32) | cast(u64) hi;
    ccs := table_find_pointer(*s.cached_shadows, key);
    if ccs && ccs.block != NONE && dt_dominates(s.dt, ccs.block, inst_block(pos)) return ccs.shadow;
    union_elems: [..] Value_Id; union_elems.allocator = temp;
    if e1 for e1.* array_add(*union_elems, it); else array_add(*union_elems, v1);
    if e2 { for e2.* dfs_set_insert(*union_elems, it); } else dfs_set_insert(*union_elems, v2);
    pv1 := dfsf_collapse_to_primitive_shadow_at(s, v1, pos);
    pv2 := dfsf_collapse_to_primitive_shadow_at(s, v2, pos);
    b: Irb; irb_set_before(*b, pos);
    c: Dfs_Cached_Shadow;
    c.block = inst_block(pos);
    c.shadow = irb_binop(*b, .OR, pv1, pv2);
    table_set(*s.cached_shadows, key, c);
    table_set(*s.shadow_elements, c.shadow, union_elems);
    return c.shadow;
}

// combineOperandShadows
dfsf_combine_operand_shadows :: (s: *Dfsf, i: Value_Id) -> Value_Id {
    n := nops(i);
    if n == 0 return dfs_zero_shadow(s.dfs, i);
    sh := dfsf_get_shadow(s, op(i, 0));
    for k: 1..cast(s64) n - 1 {
        o := dfsf_get_shadow(s, op(i, cast(u32) k));
        sh = dfsf_combine_shadows(s, sh, o, i);
    }
    return dfsf_expand_from_primitive_shadow(s, vtype(i), sh, i);
}

// combineOrigins(Shadows, Origins, Pos, Zero)
dfsf_combine_origins :: (s: *Dfsf, shadows: [] Value_Id, origins: [] Value_Id, pos: Value_Id, zero_in: Value_Id = NONE) -> Value_Id {
    d := s.dfs;
    if origins.count == 0 return d.zero_origin;
    origin: Value_Id = NONE;
    zero := ifx zero_in == NONE then d.zero_prim_shadow else zero_in;
    for k: 0..origins.count - 1 {
        oo := origins[k];
        if is_constant_kind(vkind(oo)) && is_null_value(oo) continue;
        if origin == NONE { origin = oo; continue; }
        ps := dfsf_collapse_to_primitive_shadow_at(s, shadows[k], pos);
        b: Irb; irb_set_before(*b, pos);
        cond := irb_icmp(*b, ICMP_NE, ps, zero);
        origin = irb_select(*b, cond, oo, origin);
    }
    return ifx origin != NONE then origin else d.zero_origin;
}

dfsf_combine_operand_origins :: (s: *Dfsf, i: Value_Id) -> Value_Id {
    n := nops(i);
    shadows := NewArray(n, Value_Id,, temp);
    origins := NewArray(n, Value_Id,, temp);
    for k: 0..cast(s64) n - 1 {
        shadows[k] = dfsf_get_shadow(s, op(i, cast(u32) k));
        origins[k] = dfsf_get_origin(s, op(i, cast(u32) k));
    }
    return dfsf_combine_origins(s, shadows, origins, i);
}

dfsf_shadow_align :: (inst_align: u64) -> u64 {
    a := ifx dfsan_cl.preserve_alignment then inst_align else 1;
    return a * DFS_SHADOW_WIDTH_BYTES;
}
dfsf_origin_align :: (inst_align: u64) -> u64 {
    a := ifx inst_align == 0 then cast(u64) 1 else inst_align;
    return max(cast(u64) DFS_MIN_ORIGIN_ALIGNMENT, a);
}

// isLookupTableConstant
dfsf_is_lookup_table_constant :: (s: *Dfsf, p: Value_Id) -> bool {
    gv := strip_pointer_casts(p);
    if vkind(gv) == .GLOBAL_VAR && glob(gv).is_const && vname(gv).count {
        for dfsan_cl.combine_taint_lookup_tables if it == vname(gv) return true;
    }
    return false;
}

// useCallbackLoadLabelAndOrigin
dfsf_use_callback_load_label_and_origin :: (size: u64, align: u64) -> bool {
    if dfsan_cl.track_origins == 2 return true;
    if size <= 2 return false;
    a := ifx align == 0 then cast(u64) 1 else align;
    return a < DFS_MIN_ORIGIN_ALIGNMENT || !dfs_has_load_size_for_fast_path(size);
}

// loadNextOrigin
dfs_load_next_origin :: (d: *Dfs, pos: Value_Id, oalign: u64, oaddr: *Value_Id) -> Value_Id {
    b: Irb; irb_set_before(*b, pos);
    oaddr.* = irb_gep(*b, d.origin_ty, oaddr.*, .[const_int(d.intptr, 1)]);
    return irb_load(*b, d.origin_ty, oaddr.*, oalign);
}

// loadShadowFast
dfsf_load_shadow_fast :: (s: *Dfsf, saddr_in: Value_Id, oaddr_in: Value_Id, size: u64, salign: u64, oalign: u64, first_origin: Value_Id, pos: Value_Id) -> (Value_Id, Value_Id) {
    d := s.dfs;
    track := d.track_origins;
    shadow_size := size * DFS_SHADOW_WIDTH_BYTES;
    saddr := saddr_in; oaddr := oaddr_in;
    shadows: [..] Value_Id; shadows.allocator = temp;
    origins: [..] Value_Id; origins.allocator = temp;
    wide_ty := ifx shadow_size == 4 then ir.t_i32 else type_int(64);
    b: Irb; irb_set_before(*b, pos);
    combined := irb_load(*b, wide_ty, saddr, salign);
    wbits := cast(u64) type_bits(wide_ty);
    bytes_per_wide := wbits / DFS_SHADOW_WIDTH_BITS;
    append :: (s: *Dfsf, b: *Irb, wide: Value_Id, origin: Value_Id, bytes_per_wide: u64, wbits: u64, wide_ty: Type_Id,
               shadows: *[..] Value_Id, origins: *[..] Value_Id, pos: Value_Id, oalign: u64, oaddr: *Value_Id) {
        if bytes_per_wide > 4 {
            lo: Value_Id;
            if dl.big_endian fatal("dfsan: origin tracking on a big-endian target (loadShadowFast shifts a 32-bit int by 32: UB)");
            lo = irb_binop(b, .SHL, wide, const_int(wide_ty, wbits / 2));
            array_add(shadows, wide);
            array_add(origins, dfs_load_next_origin(s.dfs, pos, oalign, oaddr));
            array_add(shadows, lo);
            array_add(origins, origin);
        } else {
            array_add(shadows, wide);
            array_add(origins, origin);
        }
    }
    if track append(s, *b, combined, first_origin, bytes_per_wide, wbits, wide_ty, *shadows, *origins, pos, oalign, *oaddr);
    ofs := bytes_per_wide;
    while ofs < size {
        saddr = irb_gep(*b, wide_ty, saddr, .[const_int(d.intptr, 1)]);
        nw := irb_load(*b, wide_ty, saddr, salign);
        combined = irb_binop(*b, .OR, combined, nw);
        if track {
            no := dfs_load_next_origin(d, pos, oalign, *oaddr);
            append(s, *b, nw, no, bytes_per_wide, wbits, wide_ty, *shadows, *origins, pos, oalign, *oaddr);
        }
        ofs += bytes_per_wide;
    }
    width := wbits / 2;
    while width >= DFS_SHADOW_WIDTH_BITS {
        shr := irb_binop(*b, .LSHR, combined, const_int(wide_ty, width));
        combined = irb_binop(*b, .OR, combined, shr);
        width >>= 1;
    }
    res := irb_cast(*b, .TRUNC, combined, d.prim_shadow_ty);
    o := ifx track then dfsf_combine_origins(s, shadows, origins, pos, const_int(type_int(64), 0)) else d.zero_origin;
    return res, o;
}

// loadShadowOriginSansLoadTracking
dfsf_load_shadow_origin_sans_load_tracking :: (s: *Dfsf, addr: Value_Id, size: u64, align: u64, pos: Value_Id) -> (Value_Id, Value_Id) {
    d := s.dfs;
    track := d.track_origins;
    if vkind(addr) == .INST && inst_op(addr) == .ALLOCA {
        found, sa := table_find(*s.alloca_shadow, addr);
        if found {
            b: Irb; irb_set_before(*b, pos);
            sli := irb_load(*b, d.prim_shadow_ty, sa, dl_abi_align(d.prim_shadow_ty));
            o: Value_Id = NONE;
            if track {
                _, oa := table_find(*s.alloca_origin, addr);
                o = irb_load(*b, d.origin_ty, oa, dl_abi_align(d.origin_ty));
            }
            return sli, o;
        }
    }
    objs: [..] Value_Id; objs.allocator = temp;
    get_underlying_objects(addr, *objs);
    all_constants := true;
    for obj: objs {
        k := vkind(obj);
        if k == .FUNCTION || k == .C_BLOCKADDR continue;
        if k == .GLOBAL_VAR && glob(obj).is_const continue;
        all_constants = false;
        break;
    }
    if all_constants return d.zero_prim_shadow, ifx track then d.zero_origin else NONE;
    if size == 0 return d.zero_prim_shadow, ifx track then d.zero_origin else NONE;
    if track && dfsf_use_callback_load_label_and_origin(size, align) {
        b: Irb; irb_set_before(*b, pos);
        call := san_call(*b, d.load_label_and_origin, .[addr, const_int(d.intptr, size)]);
        call_add_ret_attr_kind(call, .ZExt);
        sh := irb_cast(*b, .TRUNC, irb_binop(*b, .LSHR, call, const_int(vtype(call), DFS_ORIGIN_WIDTH_BITS)), d.prim_shadow_ty);
        o := irb_cast(*b, .TRUNC, call, d.origin_ty);
        return sh, o;
    }
    saddr, oaddr := dfs_get_shadow_origin_address(d, addr, align, pos);
    salign := dfsf_shadow_align(align);
    oalign := dfsf_origin_align(align);
    origin: Value_Id = NONE;
    if track {
        b: Irb; irb_set_before(*b, pos);
        origin = irb_load(*b, d.origin_ty, oaddr, oalign);
    }
    if size == 1 {
        li := new_inst(.LOAD, d.prim_shadow_ty, 1);
        set_op(li, 0, saddr);
        inst(li).align = salign;
        insert_at_position(li, inst_block(pos), pos, false);
        return li, origin;
    }
    if size == 2 {
        b: Irb; irb_set_before(*b, pos);
        sa1 := irb_gep(*b, d.prim_shadow_ty, saddr, .[const_int(d.intptr, 1)]);
        l0 := irb_load(*b, d.prim_shadow_ty, saddr, salign);
        l1 := irb_load(*b, d.prim_shadow_ty, sa1, salign);
        return dfsf_combine_shadows(s, l0, l1, pos), origin;
    }
    if dfs_has_load_size_for_fast_path(size) {
        fs, fo := dfsf_load_shadow_fast(s, saddr, oaddr, size, salign, oalign, origin, pos);
        return fs, fo;
    }
    b: Irb; irb_set_before(*b, pos);
    fc := san_call(*b, d.union_load, .[saddr, const_int(d.intptr, size)]);
    call_add_ret_attr_kind(fc, .ZExt);
    return fc, origin;
}

// loadShadowOrigin
dfsf_load_shadow_origin :: (s: *Dfsf, addr: Value_Id, size: u64, align: u64, pos: Value_Id) -> (Value_Id, Value_Id) {
    ps, o := dfsf_load_shadow_origin_sans_load_tracking(s, addr, size, align, pos);
    if s.dfs.track_origins && dfsan_cl.track_origins == 2 {
        b: Irb; irb_set_before(*b, pos);
        if !(is_constant_kind(vkind(ps)) && is_null_value(ps)) o = dfsf_update_origin_if_tainted(s, ps, o, *b);
    }
    return ps, o;
}

dfsf_update_origin_if_tainted :: (s: *Dfsf, sh: Value_Id, o: Value_Id, b: *Irb) -> Value_Id {
    return san_call(b, s.dfs.chain_origin_if_tainted, .[sh, o]);
}
dfsf_update_origin :: (s: *Dfsf, v: Value_Id, b: *Irb) -> Value_Id {
    if !s.dfs.track_origins return v;
    return san_call(b, s.dfs.chain_origin, .[v]);
}

// originToIntptr
dfsf_origin_to_intptr :: (s: *Dfsf, b: *Irb, origin_in: Value_Id) -> Value_Id {
    isz := dl_type_store_size(s.dfs.intptr);
    if isz == DFS_ORIGIN_WIDTH_BYTES return origin_in;
    o := irb_int_cast(b, origin_in, s.dfs.intptr, false);
    return irb_binop(b, .OR, o, irb_binop(b, .SHL, o, const_int(s.dfs.intptr, DFS_ORIGIN_WIDTH_BYTES * 8)));
}

// paintOrigin
dfsf_paint_origin :: (s: *Dfsf, b: *Irb, origin: Value_Id, store_origin_addr: Value_Id, store_origin_size: u64, alignment: u64) {
    d := s.dfs;
    intptr_align := dl_abi_align(d.intptr);
    isz := dl_type_store_size(d.intptr);
    ofs: u64 = 0;
    cur := alignment;
    if alignment >= intptr_align && isz > DFS_ORIGIN_WIDTH_BYTES {
        io := dfsf_origin_to_intptr(s, b, origin);
        iptr := irb_pointer_cast(b, store_origin_addr, type_ptr(0));
        for k: 0..cast(s64)(store_origin_size / isz) - 1 {
            ptr := ifx k != 0 then irb_const_gep1_32(b, d.intptr, iptr, cast(u64) k) else iptr;
            irb_store(b, io, ptr, cur);
            ofs += isz / DFS_ORIGIN_WIDTH_BYTES;
            cur = intptr_align;
        }
    }
    k := ofs;
    while k < (store_origin_size + DFS_ORIGIN_WIDTH_BYTES - 1) / DFS_ORIGIN_WIDTH_BYTES {
        gep := ifx k != 0 then irb_const_gep1_32(b, d.origin_ty, store_origin_addr, k) else store_origin_addr;
        irb_store(b, origin, gep, cur);
        cur = DFS_MIN_ORIGIN_ALIGNMENT;
        k += 1;
    }
}

// convertToBool
dfsf_convert_to_bool :: (v: Value_Id, b: *Irb, name := "") -> Value_Id {
    t := vtype(v);
    if type_bits(t) == 1 return v;
    return irb_icmp(b, ICMP_NE, v, const_int(t, 0), name);
}

dfsf_should_instrument_with_call :: (s: *Dfsf) -> bool {
    return dfsan_cl.instrument_with_call_threshold >= 0 && s.num_origin_stores >= dfsan_cl.instrument_with_call_threshold;
}

// storeOrigin
dfsf_store_origin :: (s: *Dfsf, pos: Value_Id, addr: Value_Id, size: u64, sh: Value_Id, origin: Value_Id, store_origin_addr: Value_Id, align: u64) {
    d := s.dfs;
    oalign := dfsf_origin_align(align);
    collapsed := dfsf_collapse_to_primitive_shadow_at(s, sh, pos);
    b: Irb; irb_set_before(*b, pos);
    if is_constant_kind(vkind(collapsed)) {
        if !is_null_value(collapsed) dfsf_paint_origin(s, *b, dfsf_update_origin(s, origin, *b), store_origin_addr, size, oalign);
        return;
    }
    if dfsf_should_instrument_with_call(s) {
        san_call(*b, d.maybe_store_origin, .[collapsed, addr, const_int(d.intptr, size), origin]);
    } else {
        cmp := dfsf_convert_to_bool(collapsed, *b, "_dfscmp");
        check_term := sbi_if_then(cmp, pos, false, d.origin_store_weights);
        dt_recalculate(s.dt, s.f);   // ~DomTreeUpdater flushes the SplitBlockAndInsertIfThen updates
        nb: Irb; irb_set_before(*nb, check_term);
        dfsf_paint_origin(s, *nb, dfsf_update_origin(s, origin, *nb), store_origin_addr, size, oalign);
        s.num_origin_stores += 1;
    }
}

// storeZeroPrimitiveShadow
dfsf_store_zero_primitive_shadow :: (s: *Dfsf, addr: Value_Id, size: u64, salign: u64, pos: Value_Id) {
    d := s.dfs;
    b: Irb; irb_set_before(*b, pos);
    sty := type_int(size * DFS_SHADOW_WIDTH_BITS);
    z := const_int(sty, 0);
    sa := dfs_get_shadow_address(d, addr, pos);
    irb_store(*b, z, sa, salign);
}

// storePrimitiveShadowOrigin
dfsf_store_primitive_shadow_origin :: (s: *Dfsf, addr: Value_Id, size: u64, align: u64, ps: Value_Id, origin: Value_Id, pos: Value_Id) {
    d := s.dfs;
    track := d.track_origins && origin != NONE;
    if vkind(addr) == .INST && inst_op(addr) == .ALLOCA {
        found, sa := table_find(*s.alloca_shadow, addr);
        if found {
            b: Irb; irb_set_before(*b, pos);
            irb_store(*b, ps, sa, dl_abi_align(vtype(ps)));
            if track && !dfs_is_zero_shadow(ps) {
                _, oa := table_find(*s.alloca_origin, addr);
                irb_store(*b, origin, oa, dl_abi_align(vtype(origin)));
            }
            return;
        }
    }
    salign := dfsf_shadow_align(align);
    if dfs_is_zero_shadow(ps) {
        dfsf_store_zero_primitive_shadow(s, addr, size, salign, pos);
        return;
    }
    b: Irb; irb_set_before(*b, pos);
    saddr, oaddr := dfs_get_shadow_origin_address(d, addr, align, pos);
    SHADOW_VEC_SIZE :: 8;
    offset: u64 = 0;
    left := size;
    if left >= SHADOW_VEC_SIZE {
        vty := type_vector(SHADOW_VEC_SIZE, d.prim_shadow_ty, false);
        vec := const_poison(vty);
        for k: 0..SHADOW_VEC_SIZE - 1 {
            vec = irb_insert_element_v(*b, vec, ps, const_int(ir.t_i32, cast(u64) k));
        }
        while true {
            cur := irb_const_gep1_32(*b, vty, saddr, offset);
            irb_store(*b, vec, cur, salign);
            left -= SHADOW_VEC_SIZE;
            offset += 1;
            if left < SHADOW_VEC_SIZE break;
        }
        offset *= SHADOW_VEC_SIZE;
    }
    while left > 0 {
        cur := irb_const_gep1_32(*b, d.prim_shadow_ty, saddr, offset);
        irb_store(*b, ps, cur, salign);
        left -= 1;
        offset += 1;
    }
    if track dfsf_store_origin(s, pos, addr, size, ps, origin, oaddr, align);
}

// StripPointerGEPsAndCasts
dfs_strip_pointer_geps_and_casts :: (v_in: Value_Id) -> Value_Id {
    v := v_in;
    if !is_ptr_type(vtype(v)) return v;
    visited: [..] Value_Id; visited.allocator = temp;
    array_add(*visited, v);
    while true {
        k := vkind(v);
        if (k == .INST && inst_op(v) == .GEP) || (k == .C_EXPR && cexpr(v).op == .GEP) {
            v = op(v, 0);
        } else if (k == .INST && inst_op(v) == .BITCAST) || (k == .C_EXPR && cexpr(v).op == .BITCAST) {
            v = op(v, 0);
            if !is_ptr_type(vtype(v)) return v;
        } else if k == .ALIAS {
            v = op(v, 0);
        }
        if dfs_set_contains(visited, v) break;
        array_add(*visited, v);
    }
    return v;
}

// ---------------------------------------------------------------- DFSanVisitor

dfsv_visit_inst_operands :: (s: *Dfsf, i: Value_Id) {
    sh := dfsf_combine_operand_shadows(s, i);
    dfsf_set_shadow(s, i, sh);
    dfsv_visit_inst_operand_origins(s, i);
}
dfsv_visit_inst_operand_origins :: (s: *Dfsf, i: Value_Id) {
    if !s.dfs.track_origins return;
    o := dfsf_combine_operand_origins(s, i);
    dfsf_set_origin(s, i, o);
}

dfsv_visit :: (s: *Dfsf, i: Value_Id) {
    opc := inst_op(i);
    if opc == {
        case .FNEG; dfsv_visit_inst_operands(s, i);
        case .ADD; #through; case .FADD; #through; case .SUB; #through; case .FSUB; #through; case .MUL; #through;
        case .FMUL; #through; case .UDIV; #through; case .SDIV; #through; case .FDIV; #through; case .UREM; #through;
        case .SREM; #through; case .FREM; #through; case .SHL; #through; case .LSHR; #through; case .ASHR; #through;
        case .AND; #through; case .OR; #through; case .XOR;
            dfsv_visit_inst_operands(s, i);
        case .BITCAST;
            src := op(i, 0);
            if vkind(src) == .INST && call_is_must_tail(src) return;
            dfsv_visit_inst_operands(s, i);
        case .TRUNC; #through; case .ZEXT; #through; case .SEXT; #through; case .FPTOUI; #through; case .FPTOSI; #through;
        case .UITOFP; #through; case .SITOFP; #through; case .FPTRUNC; #through; case .FPEXT; #through;
        case .PTRTOINT; #through; case .PTRTOADDR; #through; case .INTTOPTR; #through; case .ADDRSPACECAST;
            dfsv_visit_inst_operands(s, i);
        case .ICMP; #through; case .FCMP; dfsv_visit_cmp(s, i);
        case .LANDINGPAD;
            dfsf_set_shadow(s, i, dfs_zero_shadow(s.dfs, i));
            dfsf_set_origin(s, i, s.dfs.zero_origin);
        case .GEP; dfsv_visit_gep(s, i);
        case .LOAD; dfsv_visit_load(s, i);
        case .STORE; dfsv_visit_store(s, i);
        case .ATOMICRMW;
            dfsv_visit_cas_or_rmw(s, inst(i).align, i);
            inst(i).ord1 = msan_add_release_ordering(inst(i).ord1);
        case .CMPXCHG;
            dfsv_visit_cas_or_rmw(s, inst(i).align, i);
            inst(i).ord1 = msan_add_release_ordering(inst(i).ord1);
        case .RET; dfsv_visit_return(s, i);
        case .PHI; dfsv_visit_phi(s, i);
        case .EXTRACTELEMENT; #through; case .INSERTELEMENT; #through; case .SHUFFLEVECTOR;
            dfsv_visit_inst_operands(s, i);
        case .EXTRACTVALUE;
            b: Irb; irb_set_before(*b, i);
            agg_sh := dfsf_get_shadow(s, op(i, 0));
            idxs := dfs_inst_indices(i);
            dfs_check_aggregate_shadow(agg_sh);
            dfsf_set_shadow(s, i, irb_extract_value(*b, agg_sh, idxs));
            dfsv_visit_inst_operand_origins(s, i);
        case .INSERTVALUE;
            b: Irb; irb_set_before(*b, i);
            agg_sh := dfsf_get_shadow(s, op(i, 0));
            ins_sh := dfsf_get_shadow(s, op(i, 1));
            idxs := dfs_inst_indices(i);
            dfs_check_aggregate_shadow(agg_sh);
            dfsf_set_shadow(s, i, irb_insert_value(*b, agg_sh, ins_sh, idxs));
            dfsv_visit_inst_operand_origins(s, i);
        case .ALLOCA; dfsv_visit_alloca(s, i);
        case .SELECT; dfsv_visit_select(s, i);
        case .CALL;
            f := call_called_function(i);
            if f != NONE {
                iid := function_intrinsic_id(f);
                if iid == IID_MEMCPY || iid == IID_MEMCPY_INLINE || iid == IID_MEMMOVE { dfsv_visit_mem_transfer(s, i); return; }
                if iid == IID_MEMSET || iid == IID_MEMSET_INLINE { dfsv_visit_memset(s, i); return; }
            }
            dfsv_visit_call_base(s, i);
        case .INVOKE; #through; case .CALLBR; dfsv_visit_call_base(s, i);
        case .CONDBR; dfsf_add_conditional_callbacks(s, i, op(i, 0));
        case .SWITCH; dfsf_add_conditional_callbacks(s, i, op(i, 0));
    }
}

// An unsized aggregate (a struct with scalable vectors of different types) has the primitive shadow i8; LLVM then
// folds `extractvalue i8 0, ...` through ConstantInt::getAggregateElement's cast<VectorType> (UB in a release build)
// or builds an invalid extractvalue / insertvalue.
dfs_check_aggregate_shadow :: (sh: Value_Id) {
    if !is_aggregate(vtype(sh)) fatal("dfsan: extractvalue / insertvalue of an unsized aggregate (its shadow is i8; LLVM's result is undefined behaviour)");
}

// the index list of an extractvalue / insertvalue (copied: new instructions grow ir.u32_pool)
dfs_inst_indices :: (i: Value_Id) -> [] u32 {
    r := inst(i);
    out := NewArray(r.nidx, u32,, temp);
    for k: 0..cast(s64) r.nidx - 1 out[k] = ir.u32_pool[r.idx + cast(u32) k];
    return out;
}

dfsv_visit_cmp :: (s: *Dfsf, i: Value_Id) {
    dfsv_visit_inst_operands(s, i);
    if dfsan_cl.event_callbacks {
        b: Irb; irb_set_before(*b, i);
        sh := dfsf_get_shadow(s, i);
        c := san_call(*b, s.dfs.cmp_callback, .[sh]);
        call_add_param_attr_kind(c, 0, .ZExt);
    }
}

dfsv_visit_gep :: (s: *Dfsf, i: Value_Id) {
    if dfsan_cl.combine_offset_labels_on_gep || dfsf_is_lookup_table_constant(s, dfs_strip_pointer_geps_and_casts(op(i, 0))) {
        dfsv_visit_inst_operands(s, i);
        return;
    }
    base := op(i, 0);
    dfsf_set_shadow(s, i, dfsf_get_shadow(s, base));
    if s.dfs.track_origins dfsf_set_origin(s, i, dfsf_get_origin(s, base));
}

dfsv_visit_load :: (s: *Dfsf, i: Value_Id) {
    d := s.dfs;
    size := dl_type_store_size(vtype(i));
    if size == 0 {
        dfsf_set_shadow(s, i, dfs_zero_shadow(d, i));
        dfsf_set_origin(s, i, d.zero_origin);
        return;
    }
    atomic := inst(i).ord1 != 0;
    if atomic inst(i).ord1 = msan_add_acquire_ordering(inst(i).ord1);
    after_li := inst_next(i);
    pos := i;
    if atomic pos = inst_next(pos);
    shadows: [..] Value_Id; shadows.allocator = temp;
    origins: [..] Value_Id; origins.allocator = temp;
    ps, origin := dfsf_load_shadow_origin(s, op(i, 0), size, inst(i).align, pos);
    track := d.track_origins;
    if track { array_add(*shadows, ps); array_add(*origins, origin); }
    if dfsan_cl.combine_pointer_labels_on_load || dfsf_is_lookup_table_constant(s, dfs_strip_pointer_geps_and_casts(op(i, 0))) {
        psh := dfsf_get_shadow(s, op(i, 0));
        ps = dfsf_combine_shadows(s, ps, psh, pos);
        if track { array_add(*shadows, psh); array_add(*origins, dfsf_get_origin(s, op(i, 0))); }
    }
    if !dfs_is_zero_shadow(ps) array_add(*s.nonzero_checks, ps);
    sh := dfsf_expand_from_primitive_shadow(s, vtype(i), ps, pos);
    dfsf_set_shadow(s, i, sh);
    if track dfsf_set_origin(s, i, dfsf_combine_origins(s, shadows, origins, pos));
    if dfsan_cl.event_callbacks {
        b: Irb; irb_set_before(*b, pos);
        c := san_call(*b, d.load_callback, .[ps, op(i, 0)]);
        call_add_param_attr_kind(c, 0, .ZExt);
    }
    b: Irb; irb_set_before(*b, after_li);
    dfsf_add_reaches_function_callbacks(s, *b, i, i);
}

dfsv_visit_store :: (s: *Dfsf, i: Value_Id) {
    d := s.dfs;
    val := op(i, 0);
    size := dl_type_store_size(vtype(val));
    if size == 0 return;
    atomic := inst(i).ord1 != 0;
    if atomic inst(i).ord1 = msan_add_release_ordering(inst(i).ord1);
    track := d.track_origins && !atomic;
    shadows: [..] Value_Id; shadows.allocator = temp;
    origins: [..] Value_Id; origins.allocator = temp;
    sh := ifx atomic then dfs_zero_shadow(d, val) else dfsf_get_shadow(s, val);
    if track { array_add(*shadows, sh); array_add(*origins, dfsf_get_origin(s, val)); }
    ps: Value_Id;
    if dfsan_cl.combine_pointer_labels_on_store {
        psh := dfsf_get_shadow(s, op(i, 1));
        if track { array_add(*shadows, psh); array_add(*origins, dfsf_get_origin(s, op(i, 1))); }
        ps = dfsf_combine_shadows(s, sh, psh, i);
    } else {
        ps = dfsf_collapse_to_primitive_shadow_at(s, sh, i);
    }
    origin: Value_Id = NONE;
    if track origin = dfsf_combine_origins(s, shadows, origins, i);
    dfsf_store_primitive_shadow_origin(s, op(i, 1), size, inst(i).align, ps, origin, i);
    if dfsan_cl.event_callbacks {
        b: Irb; irb_set_before(*b, i);
        c := san_call(*b, d.store_callback, .[ps, op(i, 1)]);
        call_add_param_attr_kind(c, 0, .ZExt);
    }
}

dfsv_visit_cas_or_rmw :: (s: *Dfsf, align: u64, i: Value_Id) {
    val := op(i, 1);
    size := dl_type_store_size(vtype(val));
    if size == 0 return;
    addr := op(i, 0);
    salign := dfsf_shadow_align(align);
    dfsf_store_zero_primitive_shadow(s, addr, size, salign, i);
    dfsf_set_shadow(s, i, dfs_zero_shadow(s.dfs, i));
    dfsf_set_origin(s, i, s.dfs.zero_origin);
}

dfsv_visit_alloca :: (s: *Dfsf, i: Value_Id) {
    d := s.dfs;
    all_loads_stores := true;
    u := ir.v_first_use[i];
    while u != NONE {
        user := ir.u_user[u];
        u = ir.u_next[u];
        if vkind(user) == .INST && inst_op(user) == .LOAD continue;
        if vkind(user) == .INST && inst_op(user) == .STORE && op(user, 1) == i continue;
        all_loads_stores = false;
        break;
    }
    if all_loads_stores {
        b: Irb; irb_set_before(*b, i);
        table_set(*s.alloca_shadow, i, irb_alloca(*b, d.prim_shadow_ty, NONE));
        if d.track_origins table_set(*s.alloca_origin, i, irb_alloca(*b, d.origin_ty, NONE, "_dfsa"));
    }
    dfsf_set_shadow(s, i, d.zero_prim_shadow);
    dfsf_set_origin(s, i, d.zero_origin);
}

// SelectInst::Create(C, T, F, "", InsertBefore): no folding, no debug location
dfs_new_select_before :: (c: Value_Id, t: Value_Id, f: Value_Id, before: Value_Id) -> Value_Id {
    i := new_inst(.SELECT, vtype(t), 3);
    set_op(i, 0, c); set_op(i, 1, t); set_op(i, 2, f);
    insert_at_position(i, inst_block(before), before, false);
    return i;
}

dfsv_visit_select :: (s: *Dfsf, i: Value_Id) {
    d := s.dfs;
    cond := op(i, 0); tv := op(i, 1); fv := op(i, 2);
    csh := dfsf_get_shadow(s, cond);
    tsh := dfsf_get_shadow(s, tv);
    fsh := dfsf_get_shadow(s, fv);
    sel: Value_Id = NONE;
    track := d.track_origins;
    shadows: [..] Value_Id; shadows.allocator = temp;
    origins: [..] Value_Id; origins.allocator = temp;
    to: Value_Id = NONE; fo: Value_Id = NONE;
    if track { to = dfsf_get_origin(s, tv); fo = dfsf_get_origin(s, fv); }
    dfsf_add_conditional_callbacks(s, i, cond);
    if is_vector_type(vtype(cond)) {
        sel = dfsf_combine_shadows_then_convert(s, vtype(i), tsh, fsh, i);
        if track { array_add(*shadows, tsh); array_add(*shadows, fsh); array_add(*origins, to); array_add(*origins, fo); }
    } else {
        if tsh == fsh {
            sel = tsh;
            if track { array_add(*shadows, tsh); array_add(*origins, to); }
        } else {
            sel = dfs_new_select_before(cond, tsh, fsh, i);
            if track {
                array_add(*shadows, sel);
                array_add(*origins, dfs_new_select_before(cond, to, fo, i));
            }
        }
    }
    dfsf_set_shadow(s, i, ifx dfsan_cl.track_select_control_flow then dfsf_combine_shadows_then_convert(s, vtype(i), csh, sel, i) else sel);
    if track {
        if dfsan_cl.track_select_control_flow { array_add(*shadows, csh); array_add(*origins, dfsf_get_origin(s, cond)); }
        dfsf_set_origin(s, i, dfsf_combine_origins(s, shadows, origins, i));
    }
}

dfsv_visit_memset :: (s: *Dfsf, i: Value_Id) {
    d := s.dfs;
    b: Irb; irb_set_before(*b, i);
    vsh := dfsf_get_shadow(s, call_arg(i, 1));
    vo := ifx d.track_origins then dfsf_get_origin(s, call_arg(i, 1)) else d.zero_origin;
    dest := strip_pointer_casts(call_arg(i, 0));
    san_call(*b, d.set_label, .[vsh, vo, dest, irb_zext_or_trunc(*b, call_arg(i, 2), d.intptr)]);
}

dfsv_visit_mem_transfer :: (s: *Dfsf, i: Value_Id) {
    d := s.dfs;
    b: Irb; irb_set_before(*b, i);
    if d.track_origins {
        san_call(*b, d.mem_origin_transfer, .[call_arg(i, 0), call_arg(i, 1), irb_int_cast(*b, call_arg(i, 2), d.intptr, false)]);
    }
    dest := strip_pointer_casts(call_arg(i, 0));
    src := strip_pointer_casts(call_arg(i, 1));
    dsh := dfs_get_shadow_address(d, dest, i);
    ssh := dfs_get_shadow_address(d, src, i);
    len := call_arg(i, 2);
    lsh := irb_binop(*b, .MUL, len, const_int(vtype(len), DFS_SHADOW_WIDTH_BYTES));
    c := new_inst(.CALL, ir.t_void, 5);
    inst(c).ty2 = inst(i).ty2;
    set_op(c, 0, dsh); set_op(c, 1, ssh); set_op(c, 2, lsh); set_op(c, 3, call_arg(i, 3)); set_op(c, 4, call_callee(i));
    irb_insert(*b, c);
    da := call_param_align(i, 0); sa := call_param_align(i, 1);
    dfs_call_set_param_align(c, 0, dfsf_shadow_align(ifx da == 0 then cast(u64) 1 else da));
    dfs_call_set_param_align(c, 1, dfsf_shadow_align(ifx sa == 0 then cast(u64) 1 else sa));
    if dfsan_cl.event_callbacks {
        san_call(*b, d.mem_transfer_callback, .[dsh, irb_zext_or_trunc(*b, len, d.intptr)]);
    }
}

// MemIntrinsic::setDestAlignment / setSourceAlignment(MaybeAlign)
dfs_call_set_param_align :: (c: Value_Id, k: u32, align: u64) {
    call_remove_param_attr(c, k, .Alignment);
    a: Attr; a.kind = .Alignment; a.ty = NONE; a.ival = align;
    call_add_param_attr(c, k, a);
}

// isAMustTailRetVal
dfs_is_must_tail_ret_val :: (rv_in: Value_Id) -> bool {
    rv := rv_in;
    if vkind(rv) == .INST && inst_op(rv) == .BITCAST rv = op(rv, 0);
    if vkind(rv) == .INST return call_is_must_tail(rv);
    return false;
}

dfsv_visit_return :: (s: *Dfsf, i: Value_Id) {
    d := s.dfs;
    if s.native_abi || nops(i) == 0 return;
    rv := op(i, 0);
    if dfs_is_must_tail_ret_val(rv) return;
    sh := dfsf_get_shadow(s, rv);
    b: Irb; irb_set_before(*b, i);
    rt := func_ret(glob(s.f).value_type);
    size := dl_type_alloc_size(dfs_shadow_ty(d, rt));
    if size <= DFS_RETVAL_TLS_SIZE irb_store(*b, sh, dfsf_get_retval_tls(s, *b), DFS_SHADOW_TLS_ALIGNMENT);
    if d.track_origins {
        o := dfsf_get_origin(s, rv);
        irb_store(*b, o, d.retval_origin_tls, dl_abi_align(vtype(o)));
    }
}

// new AllocaInst(Ty, AllocaAS, Name, F->getEntryBlock().begin())
dfs_new_entry_alloca :: (s: *Dfsf, ty: Type_Id, name: string) -> Value_Id {
    a := new_inst(.ALLOCA, type_ptr(dl.alloca_as), 1);
    set_op(a, 0, const_int(ir.t_i32, 1));
    inst(a).ty2 = ty;
    inst(a).addrspace = dl.alloca_as;
    inst(a).align = dl_pref_align(ty);
    entry := fn_entry(s.f);
    insert_at_position(a, entry, block_first(entry), true);
    set_name(a, name);
    return a;
}

// IRBuilder::CreateStructGEP(Ty, Ptr, Idx): getelementptr inbounds nuw Ty, ptr, i32 0, i32 Idx
irb_struct_gep :: (b: *Irb, ty: Type_Id, ptr: Value_Id, idx: u64, name := "") -> Value_Id {
    return irb_gep(b, ty, ptr, .[const_int(ir.t_i32, 0), const_int(ir.t_i32, idx)], name, F_INBOUNDS | F_GEP_NUW);
}

dfsv_add_shadow_arguments :: (s: *Dfsf, f: Value_Id, cb: Value_Id, args: *[..] Value_Id, b: *Irb) {
    d := s.dfs;
    ft := glob(f).value_type;
    np := func_nparams(ft);
    na := call_num_args(cb);
    for k: 0..cast(s64) np - 1
        array_add(args, dfsf_collapse_to_primitive_shadow_at(s, dfsf_get_shadow(s, call_arg(cb, cast(u32) k)), cb));
    if func_vararg(ft) {
        vty := type_array(na - np, d.prim_shadow_ty);
        va := dfs_new_entry_alloca(s, vty, "labelva");
        for k: cast(s64) np..cast(s64) na - 1 {
            p := irb_struct_gep(b, vty, va, cast(u64)(k - np));
            irb_store(b, dfsf_collapse_to_primitive_shadow_at(s, dfsf_get_shadow(s, call_arg(cb, cast(u32) k)), cb), p, dl_abi_align(d.prim_shadow_ty));
        }
        array_add(args, irb_struct_gep(b, vty, va, 0));
    }
    if func_ret(ft) != ir.t_void {
        if s.label_return_alloca == NONE s.label_return_alloca = dfs_new_entry_alloca(s, d.prim_shadow_ty, "labelreturn");
        array_add(args, s.label_return_alloca);
    }
}

dfsv_add_origin_arguments :: (s: *Dfsf, f: Value_Id, cb: Value_Id, args: *[..] Value_Id, b: *Irb) {
    d := s.dfs;
    ft := glob(f).value_type;
    np := func_nparams(ft);
    na := call_num_args(cb);
    for k: 0..cast(s64) np - 1 array_add(args, dfsf_get_origin(s, call_arg(cb, cast(u32) k)));
    if func_vararg(ft) {
        vty := type_array(na - np, d.origin_ty);
        va := dfs_new_entry_alloca(s, vty, "originva");
        for k: cast(s64) np..cast(s64) na - 1 {
            p := irb_struct_gep(b, vty, va, cast(u64)(k - np));
            irb_store(b, dfsf_get_origin(s, call_arg(cb, cast(u32) k)), p, dl_abi_align(d.origin_ty));
        }
        array_add(args, irb_struct_gep(b, vty, va, 0));
    }
    if func_ret(ft) != ir.t_void {
        if s.origin_return_alloca == NONE s.origin_return_alloca = dfs_new_entry_alloca(s, d.origin_ty, "originreturn");
        array_add(args, s.origin_return_alloca);
    }
}

// transformFunctionAttributes
dfs_transform_function_attributes :: (new_ft: Type_Id, orig_ft: Type_Id, mapping: [] u32, call_attrs: u32) -> u32 {
    params: [..] u32; params.allocator = temp;
    for k: 0..cast(s64) func_nparams(new_ft) - 1 array_add(*params, 0);
    for m, k: mapping params[m] = attr_list_param(call_attrs, cast(u32) k);
    nsets: u32 = ifx call_attrs == 0 then 0 else cast(u32) ir.attr_lists[call_attrs].params.count;
    for k: func_nparams(orig_ft)..cast(s64) nsets - 1 array_add(*params, attr_list_param(call_attrs, cast(u32) k));
    return attr_list_get(attr_list_fn(call_attrs), attr_list_ret(call_attrs), params);
}

// visitWrappedCallBase: false when this is an invoke of a custom function
dfsv_visit_wrapped_call_base :: (s: *Dfsf, f: Value_Id, cb: Value_Id) -> bool {
    d := s.dfs;
    // The wrapped call is rebuilt with F's function type (setCalledFunction(&F) or the custom call): its first
    // FT->getNumParams() arguments are taken as F's parameters. When they are fewer or of other types (or there are
    // extra arguments and F is not variadic) LLVM reads past the arguments or makes invalid IR.
    {
        ft := glob(f).value_type;
        np := func_nparams(ft);
        na := call_num_args(cb);
        ok := na >= np && (func_vararg(ft) || na == np);
        if ok for k: 0..cast(s64) np - 1 if vtype(call_arg(cb, cast(u32) k)) != func_param(ft, cast(u32) k) { ok = false; break; }
        if !ok fatal("dfsan: a call of the wrapper of '%' whose arguments do not fit its function type (LLVM reads past the call's arguments or makes invalid IR)", vname(f));
    }
    b: Irb; irb_set_before(*b, cb);
    wk := dfs_get_wrapper_kind(d, f);
    if wk == {
        case .WARNING;
            call_set_called_function(cb, f);
            san_call(*b, d.unimplemented, .[irb_create_global_string(vname(f))]);
            dfs_build_extern_weak_check_if_needed(d, *b, f);
            dfsf_set_shadow(s, cb, dfs_zero_shadow(d, cb));
            dfsf_set_origin(s, cb, d.zero_origin);
            return true;
        case .DISCARD;
            call_set_called_function(cb, f);
            dfs_build_extern_weak_check_if_needed(d, *b, f);
            dfsf_set_shadow(s, cb, dfs_zero_shadow(d, cb));
            dfsf_set_origin(s, cb, d.zero_origin);
            return true;
        case .FUNCTIONAL;
            call_set_called_function(cb, f);
            dfs_build_extern_weak_check_if_needed(d, *b, f);
            dfsv_visit_inst_operands(s, cb);
            return true;
        case .CUSTOM;
            if inst_op(cb) != .CALL return false;
            track := d.track_origins;
            ft := glob(f).value_type;
            np := func_nparams(ft);
            // getCustomFunctionType
            arg_tys: [..] Type_Id; arg_tys.allocator = temp;
            mapping: [..] u32; mapping.allocator = temp;
            for k: 0..cast(s64) np - 1 { array_add(*mapping, cast(u32) arg_tys.count); array_add(*arg_tys, func_param(ft, cast(u32) k)); }
            for k: 0..cast(s64) np - 1 array_add(*arg_tys, d.prim_shadow_ty);
            if func_vararg(ft) array_add(*arg_tys, d.prim_shadow_ptr_ty);
            rt := func_ret(ft);
            if rt != ir.t_void array_add(*arg_tys, d.prim_shadow_ptr_ty);
            if track {
                for k: 0..cast(s64) np - 1 array_add(*arg_tys, d.origin_ty);
                if func_vararg(ft) array_add(*arg_tys, d.origin_ptr_ty);
                if rt != ir.t_void array_add(*arg_tys, d.origin_ptr_ty);
            }
            cft := type_func(rt, arg_tys, func_vararg(ft));
            cname := tconcat(ifx track then "__dfso_" else "__dfsw_", vname(f));
            existing := lookup_global(cname);
            custom: San_Callee;
            custom.fty = cft;
            custom.callee = san_get_or_insert_function(cname, cft);
            if existing == NONE || vkind(custom.callee) == .FUNCTION {
                cf := custom.callee;
                if vkind(cf) == .FUNCTION {
                    ipo_fn_copy_attributes_from(cf, f);
                    if rt != ir.t_void {
                        l := glob(cf).attrs;
                        glob(cf).attrs = attr_list_with_fn(l, attr_set_remove(attr_list_fn(l), .Memory));
                    }
                }
            }
            args: [..] Value_Id; args.allocator = temp;
            for k: 0..cast(s64) np - 1 array_add(*args, call_arg(cb, cast(u32) k));
            shadow_arg_start := cast(u32) args.count;
            dfsv_add_shadow_arguments(s, f, cb, *args, *b);
            origin_arg_start := cast(u32) args.count;
            if track dfsv_add_origin_arguments(s, f, cb, *args, *b);
            na := call_num_args(cb);
            for k: cast(s64) np..cast(s64) na - 1 array_add(*args, call_arg(cb, cast(u32) k));
            cci := san_call(*b, custom, args);
            inst(cci).cc = inst(cb).cc;
            inst(cci).attrs = dfs_transform_function_attributes(cft, ft, mapping, inst(cb).attrs);
            for n: 0..cast(s64) np - 1 {
                argno := shadow_arg_start + cast(u32) n;
                if vtype(call_arg(cci, argno)) == d.prim_shadow_ty call_add_param_attr_kind(cci, argno, .ZExt);
                if track {
                    oargno := origin_arg_start + cast(u32) n;
                    if vtype(call_arg(cci, oargno)) == d.origin_ty call_add_param_attr_kind(cci, oargno, .ZExt);
                }
            }
            if rt != ir.t_void {
                ll := irb_load(*b, d.prim_shadow_ty, s.label_return_alloca, dl_abi_align(d.prim_shadow_ty));
                dfsf_set_shadow(s, cci, dfsf_expand_from_primitive_shadow(s, rt, ll, cb));
                if track {
                    ol := irb_load(*b, d.origin_ty, s.origin_return_alloca, dl_abi_align(d.origin_ty));
                    dfsf_set_origin(s, cci, ol);
                }
            }
            rauw_with_metadata(cb, cci);
            erase_inst_with_metadata(cb);
            return true;
    }
    return false;
}

dfsv_visit_lib_atomic_load :: (s: *Dfsf, cb: Value_Id) {
    d := s.dfs;
    b: Irb; irb_set_before(*b, cb);
    size := call_arg(cb, 0); src := call_arg(cb, 1); dst := call_arg(cb, 2); ord := call_arg(cb, 3);
    no := irb_extract_element_v(*b, msan_add_acquire_ordering_table(), ord);
    set_op(cb, 3, no);
    nb: Irb; irb_set_before(*nb, inst_next(cb));
    nb.dbg = get_metadata(cb, 0);
    san_call(*nb, d.mem_shadow_origin_transfer, .[dst, src, irb_int_cast(*nb, size, d.intptr, false)]);
}
dfsv_visit_lib_atomic_store :: (s: *Dfsf, cb: Value_Id) {
    d := s.dfs;
    b: Irb; irb_set_before(*b, cb);
    size := call_arg(cb, 0); src := call_arg(cb, 1); dst := call_arg(cb, 2); ord := call_arg(cb, 3);
    no := irb_extract_element_v(*b, msan_add_release_ordering_table(), ord);
    set_op(cb, 3, no);
    san_call(*b, d.mem_shadow_origin_transfer, .[dst, src, irb_int_cast(*b, size, d.intptr, false)]);
}
dfsv_visit_lib_atomic_exchange :: (s: *Dfsf, cb: Value_Id) {
    d := s.dfs;
    b: Irb; irb_set_before(*b, cb);
    size := call_arg(cb, 0); target := call_arg(cb, 1); src := call_arg(cb, 2); dst := call_arg(cb, 3);
    san_call(*b, d.mem_shadow_origin_transfer, .[dst, target, irb_int_cast(*b, size, d.intptr, false)]);
    san_call(*b, d.mem_shadow_origin_transfer, .[target, src, irb_int_cast(*b, size, d.intptr, false)]);
}
dfsv_visit_lib_atomic_compare_exchange :: (s: *Dfsf, cb: Value_Id) {
    d := s.dfs;
    size := call_arg(cb, 0); target := call_arg(cb, 1); expected := call_arg(cb, 2); desired := call_arg(cb, 3);
    nb: Irb; irb_set_before(*nb, inst_next(cb));
    nb.dbg = get_metadata(cb, 0);
    dfsf_set_shadow(s, cb, dfs_zero_shadow(d, cb));
    c8 := irb_int_cast(*nb, cb, ir.t_i8, false);
    san_call(*nb, d.mem_shadow_origin_conditional_exchange, .[c8, target, expected, desired, irb_int_cast(*nb, size, d.intptr, false)]);
}

dfsv_visit_call_base :: (s: *Dfsf, cb: Value_Id) {
    d := s.dfs;
    f := call_called_function(cb);
    if (f != NONE && glob(f).intrinsic) || vkind(call_callee(cb)) == .INLINE_ASM {
        dfsv_visit_inst_operands(s, cb);
        return;
    }
    if f == strip_pointer_casts(d.vararg_wrapper.callee) return;
    ok, lf := tli_lookup_call(cb);
    if ok {
        if lf == .atomic_load {
            if inst_op(cb) != .CALL {
                print_to_stderr("DFSAN -- cannot instrument invoke of libatomic load. Ignoring!\n");
            } else {
                dfsv_visit_lib_atomic_load(s, cb);
                return;
            }
        } else if lf == .atomic_store {
            dfsv_visit_lib_atomic_store(s, cb);
            return;
        }
    }
    if f != NONE && vname(f).count && !func_vararg(glob(f).value_type) {
        if vname(f) == "__atomic_exchange" { dfsv_visit_lib_atomic_exchange(s, cb); return; }
        if vname(f) == "__atomic_compare_exchange" { dfsv_visit_lib_atomic_compare_exchange(s, cb); return; }
    }
    found, unwrapped := table_find(*d.unwrapped_fn_map, call_callee(cb));
    if found && dfsv_visit_wrapped_call_base(s, unwrapped, cb) return;

    b: Irb; irb_set_before(*b, cb);
    track := d.track_origins;
    ft := inst(cb).ty2;
    off: u64 = 0;
    for k: 0..cast(s64) func_nparams(ft) - 1 {
        a := call_arg(cb, cast(u32) k);
        if track {
            ash := dfsf_get_shadow(s, a);
            if k < DFS_NUM_ELEMENTS_IN_ARG_ORIGIN_TLS && !dfs_is_zero_shadow(ash) {
                o := dfsf_get_origin(s, a);
                irb_store(*b, o, dfsf_get_arg_origin_tls(s, cast(u64) k, *b), dl_abi_align(vtype(o)));
            }
        }
        size := dl_type_alloc_size(dfs_shadow_ty(d, func_param(ft, cast(u32) k)));
        if off + size > DFS_ARG_TLS_SIZE break;
        irb_store(*b, dfsf_get_shadow(s, a), dfsf_get_arg_tls(s, off, *b), DFS_SHADOW_TLS_ALIGNMENT);
        off += align_to(size, DFS_SHADOW_TLS_ALIGNMENT);
    }
    if vtype(cb) != ir.t_void {
        next: Value_Id;
        if inst_op(cb) == .INVOKE {
            nd := get_successor(cb, 0);
            if block_single_predecessor(nd) != NONE {
                next = block_first(nd);
            } else {
                nbb := split_edge(inst_block(cb), nd, null, null);
                dt_recalculate(s.dt, s.f);   // SplitEdge(..., &DT) keeps the tree updated
                next = block_first(nbb);
            }
        } else {
            next = inst_next(cb);
        }
        if inst_op(cb) == .CALL && call_is_must_tail(cb) return;
        nb: Irb; irb_set_before(*nb, next);
        size := dl_type_alloc_size(dfs_shadow_ty(d, vtype(cb)));
        if size > DFS_RETVAL_TLS_SIZE {
            dfsf_set_shadow(s, cb, dfs_zero_shadow(d, cb));
        } else {
            li := irb_load(*nb, dfs_shadow_ty(d, vtype(cb)), dfsf_get_retval_tls(s, *nb), DFS_SHADOW_TLS_ALIGNMENT, false, "_dfsret");
            table_set(*s.skip, li, true);
            dfsf_set_shadow(s, cb, li);
            array_add(*s.nonzero_checks, li);
        }
        if track {
            li := irb_load(*nb, d.origin_ty, d.retval_origin_tls, dl_abi_align(d.origin_ty), false, "_dfsret_o");
            table_set(*s.skip, li, true);
            dfsf_set_origin(s, cb, li);
        }
        dfsf_add_reaches_function_callbacks(s, *nb, cb, cb);
    }
}

dfsv_visit_phi :: (s: *Dfsf, pn: Value_Id) {
    d := s.dfs;
    sty := dfs_shadow_ty(d, vtype(pn));
    n := nops(pn);
    spn := create_phi(sty, n);
    insert_at_position(spn, inst_block(pn), pn, false);
    ps := const_poison(sty);
    for k: 0..cast(s64) n - 1 phi_add_incoming(spn, ps, phi_block(pn, cast(u32) k));
    dfsf_set_shadow(s, pn, spn);
    opn: Value_Id = NONE;
    if d.track_origins {
        opn = create_phi(d.origin_ty, n);
        insert_at_position(opn, inst_block(pn), pn, false);
        po := const_poison(d.origin_ty);
        for k: 0..cast(s64) n - 1 phi_add_incoming(opn, po, phi_block(pn, cast(u32) k));
        dfsf_set_origin(s, pn, opn);
    }
    array_add(*s.phi_fixups, .{pn, spn, opn});
}
