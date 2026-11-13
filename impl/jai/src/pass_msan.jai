// MemorySanitizer: a port of llvm/lib/Transforms/Instrumentation/MemorySanitizer.cpp (MemorySanitizerPass::run,
// MemorySanitizer = the module-facing half of `Msan`, MemorySanitizerVisitor = the rest of `Msan`, one per function
// as in LLVM; VarArgAMD64Helper / VarArgNoOpHelper = `Msan_Va` with a kind; the intrinsic handlers are in
// msan_intrinsics.jai and msan_x86.jai). Linux/FreeBSD/NetBSD x86-64 memory maps; the other targets' vararg helpers
// (AArch64, PowerPC, SystemZ, i386, generic) fail loudly.

MSAN_K_ORIGIN_SIZE :: 4;
MSAN_K_MIN_ORIGIN_ALIGNMENT :: 4;
MSAN_K_SHADOW_TLS_ALIGNMENT :: 8;
MSAN_K_PARAM_TLS_SIZE :: 800;
MSAN_K_RETVAL_TLS_SIZE :: 800;
MSAN_K_NUMBER_OF_ACCESS_SIZES :: 4;

msan_cl: struct {
    track_origins: s64; track_origins_set: bool;
    keep_going: bool; keep_going_set: bool;
    poison_stack := true;
    poison_stack_with_call: bool;
    poison_stack_pattern: s64 = 0xff;
    print_stack_names := true;
    poison_undef := true;
    poison_undef_vectors: bool;
    precise_disjoint_or: bool;
    handle_icmp := true;
    handle_icmp_exact := true;
    switch_precision: s64 = 99;
    handle_lifetime_intrinsics := true;
    handle_asm_conservative := true;
    check_access_address := true;
    eager_checks: bool; eager_checks_set: bool;
    dump_strict_instructions: bool;
    dump_heuristic_instructions: bool;
    calls_threshold: s64 = 3500;
    enable_kmsan: bool; enable_kmsan_set: bool;
    disable_checks: bool;
    check_constant_shadow := true;
    with_comdat: bool;
    and_mask: u64; xor_mask: u64; shadow_base: u64; shadow_base_set: bool; origin_base: u64; origin_base_set: bool;
    disambiguate_warning: s64 = 3;
};

msan_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if !begins_with(name, "msan-") return false;
    pb :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("opt: for the --% option: '%' is invalid value for boolean argument! Try 0 or 1", name, value);
        return false;
    }
    pi :: (name: string, value: string, has_value: bool) -> s64 {
        if !has_value fatal("opt: for the --% option: requires a value!", name);
        v, ok, rest := string_to_int(value);
        if !ok || rest.count {
            if begins_with(value, "0x") { u := san_parse_u64(name, value); return cast,no_check(s64) u; }
            fatal("opt: for the --% option: '%' value invalid for integer argument!", name, value);
        }
        return v;
    }
    o := *msan_cl;
    if name == {
        case "msan-track-origins"; o.track_origins = pi(name, value, has_value); o.track_origins_set = true;
        case "msan-keep-going"; o.keep_going = pb(name, value, has_value); o.keep_going_set = true;
        case "msan-poison-stack"; o.poison_stack = pb(name, value, has_value);
        case "msan-poison-stack-with-call"; o.poison_stack_with_call = pb(name, value, has_value);
        case "msan-poison-stack-pattern"; o.poison_stack_pattern = pi(name, value, has_value);
        case "msan-print-stack-names"; o.print_stack_names = pb(name, value, has_value);
        case "msan-poison-undef"; o.poison_undef = pb(name, value, has_value);
        case "msan-poison-undef-vectors"; o.poison_undef_vectors = pb(name, value, has_value);
        case "msan-precise-disjoint-or"; o.precise_disjoint_or = pb(name, value, has_value);
        case "msan-handle-icmp"; o.handle_icmp = pb(name, value, has_value);
        case "msan-handle-icmp-exact"; o.handle_icmp_exact = pb(name, value, has_value);
        case "msan-switch-precision"; o.switch_precision = pi(name, value, has_value);
        case "msan-handle-lifetime-intrinsics"; o.handle_lifetime_intrinsics = pb(name, value, has_value);
        case "msan-handle-asm-conservative"; o.handle_asm_conservative = pb(name, value, has_value);
        case "msan-check-access-address"; o.check_access_address = pb(name, value, has_value);
        case "msan-eager-checks"; o.eager_checks = pb(name, value, has_value); o.eager_checks_set = true;
        case "msan-dump-strict-instructions"; o.dump_strict_instructions = pb(name, value, has_value);
        case "msan-dump-heuristic-instructions"; o.dump_heuristic_instructions = pb(name, value, has_value);
        case "msan-instrumentation-with-call-threshold"; o.calls_threshold = pi(name, value, has_value);
        case "msan-kernel"; o.enable_kmsan = pb(name, value, has_value); o.enable_kmsan_set = true;
        case "msan-disable-checks"; o.disable_checks = pb(name, value, has_value);
        case "msan-check-constant-shadow"; o.check_constant_shadow = pb(name, value, has_value);
        case "msan-with-comdat"; o.with_comdat = pb(name, value, has_value);
        case "msan-and-mask"; o.and_mask = san_parse_u64(name, value);
        case "msan-xor-mask"; o.xor_mask = san_parse_u64(name, value);
        case "msan-shadow-base"; o.shadow_base = san_parse_u64(name, value); o.shadow_base_set = true;
        case "msan-origin-base"; o.origin_base = san_parse_u64(name, value); o.origin_base_set = true;
        case "msan-disambiguate-warning-threshold"; o.disambiguate_warning = pi(name, value, has_value);
        case; return false;
    }
    return true;
}

// cl::opt<uint64_t> parsing (decimal or 0x hex)
san_parse_u64 :: (name: string, value: string) -> u64 {
    v: u64; base: u64 = 10; s := value;
    if begins_with(s, "0x") || begins_with(s, "0X") { base = 16; s = slice(s, 2, s.count - 2); }
    if s.count == 0 fatal("opt: for the --% option: '%' value invalid for uint argument!", name, value);
    for c: cast([] u8) s {
        d: u64;
        if c >= #char "0" && c <= #char "9" d = c - #char "0";
        else if base == 16 && c >= #char "a" && c <= #char "f" d = c - #char "a" + 10;
        else if base == 16 && c >= #char "A" && c <= #char "F" d = c - #char "A" + 10;
        else fatal("opt: for the --% option: '%' value invalid for uint argument!", name, value);
        v = v * base + d;
    }
    return v;
}

Msan_Map :: struct { and_mask: u64; xor_mask: u64; shadow_base: u64; origin_base: u64; }

Msan_Options :: struct { kernel: bool; track_origins: s64; recover: bool; eager_checks: bool; }

// MemorySanitizerOptions(TO, R, K, EagerChecks) with the cl::opt overrides
msan_options :: (to: s64, r: bool, k: bool, eager: bool) -> Msan_Options {
    o: Msan_Options;
    o.kernel = ifx msan_cl.enable_kmsan_set then msan_cl.enable_kmsan else k;
    o.track_origins = ifx msan_cl.track_origins_set then msan_cl.track_origins else (ifx o.kernel then 2 else to);
    o.recover = ifx msan_cl.keep_going_set then msan_cl.keep_going else (o.kernel || r);
    o.eager_checks = ifx msan_cl.eager_checks_set then msan_cl.eager_checks else eager;
    return o;
}

Msan_Check :: struct { shadow: Value_Id; origin: Value_Id; orig_ins: Value_Id; }

Msan_Va_Kind :: enum u8 { NOOP; AMD64; }

Msan :: struct {
    // MemorySanitizer
    compile_kernel: bool;
    track_origins: s64;
    recover: bool;
    eager_checks: bool;
    triple: Triple;
    intptr: Type_Id;
    origin_ty: Type_Id;
    ptr_ty: Type_Id;
    param_tls, param_origin_tls, retval_tls, retval_origin_tls: Value_Id = NONE;
    va_arg_tls, va_arg_origin_tls, va_arg_overflow_size_tls: Value_Id = NONE;
    callbacks_initialized: bool;
    warning_fn: San_Callee;
    maybe_warning_fn: [MSAN_K_NUMBER_OF_ACCESS_SIZES] San_Callee;
    maybe_warning_var_size_fn: San_Callee;
    maybe_store_origin_fn: [MSAN_K_NUMBER_OF_ACCESS_SIZES] San_Callee;
    set_alloca_origin_with_descr_fn, set_alloca_origin_no_descr_fn, poison_stack_fn: San_Callee;
    chain_origin_fn, set_origin_fn, memmove_fn, memcpy_fn, memset_fn: San_Callee;
    context_state_ty: Type_Id;
    get_context_state_fn: San_Callee;
    poison_alloca_fn, unpoison_alloca_fn: San_Callee;
    metadata_ty: Type_Id;
    metadata_ptr_for_load_n, metadata_ptr_for_store_n: San_Callee;
    metadata_ptr_for_load_1_8: [4] San_Callee;
    metadata_ptr_for_store_1_8: [4] San_Callee;
    instrument_asm_store_fn: San_Callee;
    metadata_alloca: Value_Id = NONE;
    map: Msan_Map;
    cold_call_weights: Md_Id;
    origin_store_weights: Md_Id;

    // MemorySanitizerVisitor
    f: Value_Id;
    tli: *Tli;
    fn_prologue_end: Value_Id;
    instructions: [..] Value_Id;
    insert_checks: bool;
    propagate_shadow: bool;
    poison_stack: bool;
    poison_undef: bool;
    poison_undef_vectors: bool;
    shadow_phis: [..] Value_Id;
    origin_phis: [..] Value_Id;
    shadow_map: Table(Value_Id, Value_Id);
    origin_map: Table(Value_Id, Value_Id);
    instrumentation_list: [..] Msan_Check;
    lazy_warning_count: Table(Md_Id, s64);
    lazy_warning_counted: bool;
    alloca_set: [..] Value_Id;   // SmallSetVector
    lifetime_start_list: [..] [2] Value_Id;   // (lifetime.start, alloca)
    store_list: [..] Value_Id;
    splittable_blocks_count: s64;
    va: Msan_Va;
}

// MemorySanitizer::initializeModule
msan_initialize_module :: (ms: *Msan) {
    ms.triple = san_triple();
    if msan_cl.shadow_base_set || msan_cl.origin_base_set {
        ms.map = .{msan_cl.and_mask, msan_cl.xor_mask, msan_cl.shadow_base, msan_cl.origin_base};
    } else {
        t := ms.triple;
        if t.os == {
            case .FreeBSD;
                if t.arch == .aarch64 ms.map = .{0x1800000000000, 0x0400000000000, 0x0200000000000, 0x0700000000000};
                else if t.arch == .x86_64 ms.map = .{0xc00000000000, 0x200000000000, 0x100000000000, 0x380000000000};
                else if t.arch == .x86 ms.map = .{0x000180000000, 0x000040000000, 0x000020000000, 0x000700000000};
                else fatal("unsupported architecture");
            case .NetBSD;
                if t.arch == .x86_64 ms.map = .{0, 0x500000000000, 0, 0x100000000000};
                else fatal("unsupported architecture");
            case .Linux;
                if t.arch == {
                    case .x86_64; ms.map = .{0, 0x500000000000, 0, 0x100000000000};
                    case .x86; ms.map = .{0x000080000000, 0, 0, 0x000040000000};
                    case .mips64; #through; case .mips64el; ms.map = .{0, 0x008000000000, 0, 0x002000000000};
                    case .ppc64; #through; case .ppc64le; ms.map = .{0xE00000000000, 0x100000000000, 0x080000000000, 0x1C0000000000};
                    case .systemz; ms.map = .{0xC00000000000, 0, 0x080000000000, 0x1C0000000000};
                    case .aarch64; #through; case .aarch64_be; ms.map = .{0, 0x0B00000000000, 0, 0x0200000000000};
                    case .loongarch64; ms.map = .{0, 0x500000000000, 0, 0x100000000000};
                    case .hexagon; ms.map = .{0, 0x20000000, 0, 0x50000000};
                    case; fatal("unsupported architecture");
                }
            case; fatal("unsupported operating system");
        }
    }
    if ms.triple.arch != .x86_64 fatal("msan: target '%' is not supported (x86-64 only)", ir.triple);
    ms.intptr = type_int(dl_ptr_spec(0).bits);
    ms.origin_ty = ir.t_i32;
    ms.ptr_ty = type_ptr(0);
    ms.cold_call_weights = create_unlikely_branch_weights();
    ms.origin_store_weights = create_unlikely_branch_weights();
    if !ms.compile_kernel {
        if ms.track_origins && lookup_global("__msan_track_origins") == NONE
            gv_create(ir.t_i32, true, .WEAK_ODR, const_int(ir.t_i32, cast(u64) ms.track_origins), "__msan_track_origins", NONE, 0, dl.globals_as);
        if ms.recover && lookup_global("__msan_keep_going") == NONE
            gv_create(ir.t_i32, true, .WEAK_ODR, const_int(ir.t_i32, 1), "__msan_keep_going", NONE, 0, dl.globals_as);
    }
}

// TLI.getAttrList(C, ArgNos, Signed, Ret)
msan_tli_attr_list :: (t: *Tli, arg_nos: [] u32, signed: bool, ret := false) -> u32 {
    l: u32 = 0;
    ext := tli_ext_attr_for_i32_param(signed);
    if ext != .NONE_ATTR for arg_nos l = san_attr_list_with_param_attr(l, it, ext);
    if ret {
        rext := tli_ext_attr_for_i32_return(signed);
        if rext != .NONE_ATTR { a: Attr; a.kind = rext; a.ty = NONE; l = attr_list_get(attr_list_fn(l), attr_set_with(attr_list_ret(l), a), ifx l == 0 then .[] else ir.attr_lists[l].params); }
    }
    return l;
}

// getOrInsertGlobal(M, Name, Ty): an initial-exec TLS external declaration
msan_get_or_insert_tls_global :: (name: string, ty: Type_Id) -> Value_Id {
    g := lookup_global(name);
    if g != NONE && vkind(g) == .GLOBAL_VAR return g;
    return gv_create(ty, false, .EXTERNAL, NONE, name, NONE, 3, dl.globals_as);
}

// MemorySanitizer::createKernelApi
msan_create_kernel_api :: (ms: *Msan, t: *Tli) {
    v := ir.t_void; ip := ms.intptr; pty := ms.ptr_ty;
    ms.retval_tls = NONE; ms.retval_origin_tls = NONE; ms.param_tls = NONE; ms.param_origin_tls = NONE;
    ms.va_arg_tls = NONE; ms.va_arg_origin_tls = NONE; ms.va_arg_overflow_size_tls = NONE;
    ms.warning_fn = san_callee("__msan_warning", v, .[ir.t_i32], msan_tli_attr_list(t, .[0], false));
    i64 := type_int(64);
    ms.context_state_ty = type_literal_struct(.[type_array(MSAN_K_PARAM_TLS_SIZE / 8, i64), type_array(MSAN_K_RETVAL_TLS_SIZE / 8, i64),
        type_array(MSAN_K_PARAM_TLS_SIZE / 8, i64), type_array(MSAN_K_PARAM_TLS_SIZE / 8, i64), i64,
        type_array(MSAN_K_PARAM_TLS_SIZE / 4, ms.origin_ty), ms.origin_ty, ms.origin_ty], false);
    ms.get_context_state_fn = san_callee("__msan_get_context_state", pty, .[]);
    ms.metadata_ty = type_literal_struct(.[pty, pty], false);
    size := 1;
    for ind: 0..3 {
        ms.metadata_ptr_for_load_1_8[ind] = san_callee(tprint("__msan_metadata_ptr_for_load_%", size), ms.metadata_ty, .[pty]);
        ms.metadata_ptr_for_store_1_8[ind] = san_callee(tprint("__msan_metadata_ptr_for_store_%", size), ms.metadata_ty, .[pty]);
        size <<= 1;
    }
    ms.metadata_ptr_for_load_n = san_callee("__msan_metadata_ptr_for_load_n", ms.metadata_ty, .[pty, ip]);
    ms.metadata_ptr_for_store_n = san_callee("__msan_metadata_ptr_for_store_n", ms.metadata_ty, .[pty, ip]);
    ms.poison_alloca_fn = san_callee("__msan_poison_alloca", v, .[pty, ip, pty]);
    ms.unpoison_alloca_fn = san_callee("__msan_unpoison_alloca", v, .[pty, ip]);
}

// MemorySanitizer::createUserspaceApi
msan_create_userspace_api :: (ms: *Msan, t: *Tli) {
    v := ir.t_void; ip := ms.intptr; pty := ms.ptr_ty; i64 := type_int(64);
    if ms.track_origins {
        n := ifx ms.recover then "__msan_warning_with_origin" else "__msan_warning_with_origin_noreturn";
        ms.warning_fn = san_callee(n, v, .[ir.t_i32], msan_tli_attr_list(t, .[0], false));
    } else {
        n := ifx ms.recover then "__msan_warning" else "__msan_warning_noreturn";
        ms.warning_fn = san_callee(n, v, .[]);
    }
    ms.retval_tls = msan_get_or_insert_tls_global("__msan_retval_tls", type_array(MSAN_K_RETVAL_TLS_SIZE / 8, i64));
    ms.retval_origin_tls = msan_get_or_insert_tls_global("__msan_retval_origin_tls", ms.origin_ty);
    ms.param_tls = msan_get_or_insert_tls_global("__msan_param_tls", type_array(MSAN_K_PARAM_TLS_SIZE / 8, i64));
    ms.param_origin_tls = msan_get_or_insert_tls_global("__msan_param_origin_tls", type_array(MSAN_K_PARAM_TLS_SIZE / 4, ms.origin_ty));
    ms.va_arg_tls = msan_get_or_insert_tls_global("__msan_va_arg_tls", type_array(MSAN_K_PARAM_TLS_SIZE / 8, i64));
    ms.va_arg_origin_tls = msan_get_or_insert_tls_global("__msan_va_arg_origin_tls", type_array(MSAN_K_PARAM_TLS_SIZE / 4, ms.origin_ty));
    ms.va_arg_overflow_size_tls = msan_get_or_insert_tls_global("__msan_va_arg_overflow_size_tls", ms.intptr);
    for k: 0..MSAN_K_NUMBER_OF_ACCESS_SIZES-1 {
        sz := 1 << k;
        ms.maybe_warning_fn[k] = san_callee(tprint("__msan_maybe_warning_%", sz), v, .[type_int(cast(u64) sz * 8), ir.t_i32], msan_tli_attr_list(t, .[0, 1], false));
        ms.maybe_warning_var_size_fn = san_callee("__msan_maybe_warning_N", v, .[pty, i64, ir.t_i32], msan_tli_attr_list(t, .[], false));
        ms.maybe_store_origin_fn[k] = san_callee(tprint("__msan_maybe_store_origin_%", sz), v, .[type_int(cast(u64) sz * 8), pty, ir.t_i32], msan_tli_attr_list(t, .[0, 2], false));
    }
    ms.set_alloca_origin_with_descr_fn = san_callee("__msan_set_alloca_origin_with_descr", v, .[pty, ip, pty, pty]);
    ms.set_alloca_origin_no_descr_fn = san_callee("__msan_set_alloca_origin_no_descr", v, .[pty, ip, pty]);
    ms.poison_stack_fn = san_callee("__msan_poison_stack", v, .[pty, ip]);
}

// MemorySanitizer::initializeCallbacks
msan_initialize_callbacks :: (ms: *Msan, t: *Tli) {
    if ms.callbacks_initialized return;
    v := ir.t_void; ip := ms.intptr; pty := ms.ptr_ty;
    ms.chain_origin_fn = san_callee("__msan_chain_origin", ir.t_i32, .[ir.t_i32], msan_tli_attr_list(t, .[0], false, true));
    ms.set_origin_fn = san_callee("__msan_set_origin", v, .[pty, ip, ir.t_i32], msan_tli_attr_list(t, .[2], false));
    ms.memmove_fn = san_callee("__msan_memmove", pty, .[pty, pty, ip]);
    ms.memcpy_fn = san_callee("__msan_memcpy", pty, .[pty, pty, ip]);
    ms.memset_fn = san_callee("__msan_memset", pty, .[pty, ir.t_i32, ip], msan_tli_attr_list(t, .[1], true));
    ms.instrument_asm_store_fn = san_callee("__msan_instrument_asm_store", v, .[pty, ip]);
    if ms.compile_kernel msan_create_kernel_api(ms, t);
    else msan_create_userspace_api(ms, t);
    ms.callbacks_initialized = true;
}

// MemorySanitizer::getKmsanShadowOriginAccessFn
msan_kmsan_shadow_origin_access_fn :: (ms: *Msan, is_store: bool, size: u64) -> San_Callee {
    fns := ifx is_store then ms.metadata_ptr_for_store_1_8 else ms.metadata_ptr_for_load_1_8;
    if size == {
        case 1; return fns[0];
        case 2; return fns[1];
        case 4; return fns[2];
        case 8; return fns[3];
    }
    return .{};
}

// insertModuleCtor
msan_insert_module_ctor :: () {
    ctor, init, created := get_or_create_sanitizer_ctor_and_init_functions("msan.module_ctor", "__msan_init", .[], .[], "");
    if !created return;
    if !msan_cl.with_comdat { append_to_global_ctors(ctor, 0); return; }
    glob(ctor).comdat = get_comdat("msan.module_ctor");
    append_to_global_ctors(ctor, 0, ctor);
}

// MemorySanitizerPass::run
msan_run :: (name: string) -> Preserved {
    to: s64 = 0; recover := false; kernel := false; eager := false;
    if name != "msan" {
        if !begins_with(name, "msan<") || name[name.count - 1] != #char ">" fatal("unknown pass name '%'", name);
        params := slice(name, 5, name.count - 6);
        for p: split(params, ";",, temp) {
            if p.count == 0 continue;
            if p == "recover" recover = true;
            else if p == "kernel" kernel = true;
            else if p == "eager-checks" eager = true;
            else if begins_with(p, "track-origins=") {
                v, ok := string_to_int(slice(p, 14, p.count - 14));
                if !ok fatal("invalid argument to MemorySanitizer pass track-origins parameter: '%'", slice(p, 14, p.count - 14));
                to = v;
            } else fatal("invalid MemorySanitizer pass parameter '%'", p);
        }
    }
    opts := msan_options(to, recover, kernel, eager);
    if check_if_already_instrumented("nosanitize_memory") return PRESERVE_ALL;
    modified := false;
    if !opts.kernel { msan_insert_module_ctor(); modified = true; }
    fns: [..] Value_Id; fns.allocator = temp;
    for ir.m_functions array_add(*fns, it);
    for f: fns {
        if is_declaration(f) continue;
        ms: Msan;
        ms.compile_kernel = opts.kernel; ms.track_origins = opts.track_origins; ms.recover = opts.recover; ms.eager_checks = opts.eager_checks;
        msan_initialize_module(*ms);
        if msan_sanitize_function(*ms, f, tli_for(f)) modified = true;
    }
    printer_note_ir_changed();
    if !modified return PRESERVE_ALL;
    pa: Preserved; pa.abandon_globals_aa = true;   // PreservedAnalyses::none() + abandon<GlobalsAA>()
    return pa;
}

// TypeSizeToSizeIndex
msan_type_size_to_size_index :: (bits: u64, scalable: bool) -> u64 {
    if scalable return MSAN_K_NUMBER_OF_ACCESS_SIZES;
    if bits <= 8 return 0;
    n := (bits + 7) / 8;
    r: u64 = 0; while ((cast(u64) 1) << r) < n r += 1;   // Log2_32_Ceil
    return r;
}

// NextNodeIRBuilder(IP)
irb_next_node :: (b: *Irb, ip: Value_Id) {
    irb_set_before(b, inst(ip).next);
    b.dbg = get_metadata(ip, 0);
}

// ---------------------------------------------------------------- MemorySanitizerVisitor

// MemorySanitizerVisitor::MemorySanitizerVisitor + MemorySanitizer::sanitizeFunction
msan_sanitize_function :: (ms: *Msan, f: Value_Id, t: *Tli) -> bool {
    if !ms.compile_kernel && vname(f) == "msan.module_ctor" return false;
    if fn_has_fn_attr(f, .DisableSanitizerInstrumentation) return false;
    ms.f = f; ms.tli = t;
    ms.instructions.allocator = temp; ms.shadow_phis.allocator = temp; ms.origin_phis.allocator = temp;
    ms.shadow_map.allocator = temp; ms.origin_map.allocator = temp; ms.instrumentation_list.allocator = temp;
    ms.lazy_warning_count.allocator = temp; ms.alloca_set.allocator = temp; ms.lifetime_start_list.allocator = temp;
    ms.store_list.allocator = temp;
    msan_create_vararg_helper(ms);
    sanitize := fn_has_fn_attr(f, .SanitizeMemory) && !msan_cl.disable_checks;
    ms.insert_checks = sanitize;
    ms.propagate_shadow = sanitize;
    ms.poison_stack = sanitize && msan_cl.poison_stack;
    ms.poison_undef = sanitize && msan_cl.poison_undef;
    ms.poison_undef_vectors = sanitize && msan_cl.poison_undef_vectors;
    remove_unreachable_blocks(f, null);
    msan_initialize_callbacks(ms, t);
    entry := fn_entry(f);
    b: Irb; irb_set_at(*b, entry, block_first_non_phi(entry), true);   // getFirstNonPHIIt: head bit
    ms.fn_prologue_end = irb_intrinsic(*b, "llvm.donothing", .[], .[]);
    if ms.compile_kernel {
        kb: Irb; irb_set_before(*kb, ms.fn_prologue_end);
        msan_insert_kmsan_prologue(ms, *kb);
    }
    // F.removeFnAttrs({Memory, Speculatable})
    l := glob(f).attrs;
    fs := attr_set_remove(attr_set_remove(attr_list_fn(l), .Memory), .Speculatable);
    glob(f).attrs = attr_list_with_fn(l, fs);
    return msan_run_on_function(ms);
}

// instrumentWithCalls(V)
msan_instrument_with_calls :: (ms: *Msan, v: Value_Id) -> bool {
    if is_constant_kind(vkind(v)) return false;
    ms.splittable_blocks_count += 1;
    return msan_cl.calls_threshold >= 0 && ms.splittable_blocks_count > msan_cl.calls_threshold;
}

msan_is_in_prologue :: (ms: *Msan, i: Value_Id) -> bool {
    pe := ms.fn_prologue_end;
    return inst(i).parent == inst(pe).parent && (i == pe || comes_before(i, pe));
}

msan_update_origin :: (ms: *Msan, v: Value_Id, b: *Irb) -> Value_Id {
    if ms.track_origins <= 1 return v;
    return san_call(b, ms.chain_origin_fn, .[v]);
}

msan_origin_to_intptr :: (ms: *Msan, b: *Irb, origin_in: Value_Id) -> Value_Id {
    sz := dl_type_store_size(ms.intptr);
    if sz == MSAN_K_ORIGIN_SIZE return origin_in;
    origin := irb_int_cast(b, origin_in, ms.intptr, false);
    return irb_binop(b, .OR, origin, irb_binop(b, .SHL, origin, const_int(ms.intptr, MSAN_K_ORIGIN_SIZE * 8)));
}

// IRBuilder::CreateConstGEP1_32(Ty, Ptr, Idx)
irb_const_gep1_32 :: (b: *Irb, ty: Type_Id, ptr: Value_Id, idx: u64, name: string = "") -> Value_Id {
    return irb_gep(b, ty, ptr, .[const_int(ir.t_i32, idx)], name);
}

// paintOrigin(IRB, Origin, OriginPtr, TS, Alignment)
msan_paint_origin :: (ms: *Msan, b: *Irb, origin: Value_Id, origin_ptr: Value_Id, size_bytes: u64, scalable: bool, alignment: u64) {
    intptr_alignment := dl_abi_align(ms.intptr);
    intptr_size := dl_type_store_size(ms.intptr);
    if scalable {
        size := irb_type_size(b, ms.intptr, size_bytes, true);
        round_up := irb_binop(b, .ADD, size, const_int(ms.intptr, MSAN_K_ORIGIN_SIZE - 1));
        end := irb_binop(b, .UDIV, round_up, const_int(ms.intptr, MSAN_K_ORIGIN_SIZE));
        pt := b.pt;
        if pt == NONE fatal("msan: paintOrigin at the end of a block");
        ip, index := sbi_simple_for_loop(end, pt);
        irb_set_before(b, ip);
        gep := irb_gep(b, ms.origin_ty, origin_ptr, .[index]);
        irb_store(b, origin, gep, MSAN_K_MIN_ORIGIN_ALIGNMENT);
        return;
    }
    size := size_bytes;
    ofs: u64 = 0;
    cur := alignment;
    if alignment >= intptr_alignment && intptr_size > MSAN_K_ORIGIN_SIZE {
        io := msan_origin_to_intptr(ms, b, origin);
        iop := irb_pointer_cast(b, origin_ptr, ms.ptr_ty);
        for i: 0..cast(s64)(size / intptr_size) - 1 {
            p := ifx i then irb_const_gep1_32(b, ms.intptr, iop, cast(u64) i) else iop;
            irb_store(b, io, p, cur);
            ofs += intptr_size / MSAN_K_ORIGIN_SIZE;
            cur = intptr_alignment;
        }
    }
    i := ofs;
    while i < (size + MSAN_K_ORIGIN_SIZE - 1) / MSAN_K_ORIGIN_SIZE {
        gep := ifx i then irb_const_gep1_32(b, ms.origin_ty, origin_ptr, i) else origin_ptr;
        irb_store(b, origin, gep, cur);
        cur = MSAN_K_MIN_ORIGIN_ALIGNMENT;
        i += 1;
    }
}

// TypeSize of a type: (bytes or bits as asked, scalable)
msan_store_size :: (t: Type_Id) -> (u64, bool) {
    if type_is_scalable(t) return san_scalable_min_store_bits(t) / 8, true;
    return dl_type_store_size(t), false;
}
msan_size_in_bits :: (t: Type_Id) -> (u64, bool) {
    if type_kind(t) == .SVECTOR return type_count(t) * dl_type_size_bits(type_elem(t)), true;
    return dl_type_size_bits(t), false;
}

// isKnownNonZero(V, DL) for a constant
msan_const_known_non_zero :: (v: Value_Id) -> bool {
    q: Simplify_Query; q.have_tli = false;
    return is_known_non_zero(v, q);
}

// storeOrigin(IRB, Addr, Shadow, Origin, OriginPtr, Alignment)
msan_store_origin :: (ms: *Msan, b: *Irb, addr: Value_Id, shadow: Value_Id, origin: Value_Id, origin_ptr: Value_Id, alignment: u64) {
    origin_alignment := max(cast(u64) MSAN_K_MIN_ORIGIN_ALIGNMENT, alignment);
    ss, sc := msan_store_size(vtype(shadow));
    conv := msan_convert_shadow_to_scalar(ms, shadow, b);
    if is_constant_kind(vkind(conv)) {
        if !msan_cl.check_constant_shadow || is_null_value(conv) return;
        if msan_const_known_non_zero(conv) {
            msan_paint_origin(ms, b, msan_update_origin(ms, origin, b), origin_ptr, ss, sc, origin_alignment);
            return;
        }
    }
    bits, bsc := msan_size_in_bits(vtype(conv));
    size_index := msan_type_size_to_size_index(bits, bsc);
    if msan_instrument_with_calls(ms, conv) && size_index < MSAN_K_NUMBER_OF_ACCESS_SIZES && !ms.compile_kernel {
        fn := ms.maybe_store_origin_fn[size_index];
        conv2 := irb_cast(b, .ZEXT, conv, type_int(8 * ((cast(u64) 1) << size_index)));
        cb := san_call(b, fn, .[conv2, addr, origin]);
        call_add_param_attr_kind(cb, 0, .ZExt);
        call_add_param_attr_kind(cb, 2, .ZExt);
    } else {
        cmp := msan_convert_to_bool(ms, conv, b, "_mscmp");
        if b.pt == NONE fatal("msan: storeOrigin at the end of a block");
        check_term := sbi_if_then(cmp, b.pt, false, ms.origin_store_weights);
        bn: Irb; irb_set_before(*bn, check_term);
        msan_paint_origin(ms, *bn, msan_update_origin(ms, origin, *bn), origin_ptr, ss, sc, origin_alignment);
    }
}


msan_add_release_ordering :: (a: u8) -> u8 {
    if a == {
        case 0; return 0;
        case 1; #through; case 2; #through; case 5; return 5;
        case 4; #through; case 6; return 6;
        case 7; return 7;
    }
    return a;
}
msan_add_acquire_ordering :: (a: u8) -> u8 {
    if a == {
        case 0; return 0;
        case 1; #through; case 2; #through; case 4; return 4;
        case 5; #through; case 6; return 6;
        case 7; return 7;
    }
    return a;
}
// makeAddReleaseOrderingTable / makeAddAcquireOrderingTable (AtomicOrderingCABI: relaxed 0, consume 1, acquire 2,
// release 3, acq_rel 4, seq_cst 5)
msan_add_release_ordering_table :: () -> Value_Id {
    t := u64.[3, 4, 4, 3, 4, 5];
    return const_data(type_vector(6, ir.t_i32, false), t);
}
msan_add_acquire_ordering_table :: () -> Value_Id {
    t := u64.[2, 2, 2, 4, 4, 5];
    return const_data(type_vector(6, ir.t_i32, false), t);
}

// materializeStores
msan_materialize_stores :: (ms: *Msan) {
    for si: ms.store_list {
        b: Irb; irb_set_before(*b, si);
        val := op(si, 0);
        addr := op(si, 1);
        atomic := inst(si).ord1 != 0;
        shadow := ifx atomic then msan_get_clean_shadow_v(ms, val) else msan_get_shadow(ms, val);
        alignment := inst(si).align;
        origin_alignment := max(cast(u64) MSAN_K_MIN_ORIGIN_ALIGNMENT, alignment);
        shadow_ptr, origin_ptr := msan_get_shadow_origin_ptr(ms, addr, *b, vtype(shadow), alignment, true);
        irb_store(*b, shadow, shadow_ptr, alignment);
        if atomic inst(si).ord1 = msan_add_release_ordering(inst(si).ord1);
        if ms.track_origins && !atomic msan_store_origin(ms, *b, addr, shadow, msan_get_origin(ms, val), origin_ptr, origin_alignment);
    }
}

// shouldDisambiguateWarningLocation
msan_should_disambiguate_warning_location :: (ms: *Msan, dl_loc: Md_Id) -> bool {
    if ms.track_origins < 2 return false;
    if !ms.lazy_warning_counted {
        ms.lazy_warning_counted = true;
        for ms.instrumentation_list {
            d := get_metadata(it.orig_ins, 0);
            p := table_find_pointer(*ms.lazy_warning_count, d);
            if p p.* += 1; else table_set(*ms.lazy_warning_count, d, 1);
        }
    }
    p := table_find_pointer(*ms.lazy_warning_count, dl_loc);
    if !p { table_set(*ms.lazy_warning_count, dl_loc, 0); return 0 >= msan_cl.disambiguate_warning; }
    return p.* >= msan_cl.disambiguate_warning;
}

// insertWarningFn(IRB, Origin)
msan_insert_warning_fn :: (ms: *Msan, b: *Irb, origin_in: Value_Id) {
    origin := origin_in;
    if origin == NONE origin = const_int(ir.t_i32, 0);
    if msan_should_disambiguate_warning_location(ms, b.dbg) {
        if is_inst(origin) {
            nd := get_metadata(origin, 0);
            if nd != NONE && nd != b.dbg {
                bo: Irb; irb_set_before(*bo, b.pt);
                bo.dbg = nd;
                origin = msan_update_origin(ms, origin, *bo);
            }
        }
    }
    c: Value_Id;
    if ms.compile_kernel || ms.track_origins c = san_call(b, ms.warning_fn, .[origin]);
    else c = san_call(b, ms.warning_fn, .[]);
    call_add_fn_attr(c, Attr_Kind.NoMerge);
}

// materializeOneCheck(IRB, ConvertedShadow, Origin)
msan_materialize_one_check :: (ms: *Msan, b: *Irb, conv_in: Value_Id, origin: Value_Id) {
    conv := conv_in;
    bits, sc := msan_size_in_bits(vtype(conv));
    size_index := msan_type_size_to_size_index(bits, sc);
    if msan_instrument_with_calls(ms, conv) && !ms.compile_kernel {
        conv = msan_convert_shadow_to_scalar(ms, conv, b);
        conv2 := irb_cast(b, .ZEXT, conv, type_int(8 * ((cast(u64) 1) << size_index)));
        o := ifx ms.track_origins && origin != NONE then origin else const_int(ir.t_i32, 0);
        if size_index < MSAN_K_NUMBER_OF_ACCESS_SIZES {
            cb := san_call(b, ms.maybe_warning_fn[size_index], .[conv2, o]);
            call_add_param_attr_kind(cb, 0, .ZExt);
            call_add_param_attr_kind(cb, 1, .ZExt);
        } else {
            sa := irb_alloca(b, vtype(conv2), NONE, "", 0);   // CreateAlloca(Ty, AddrSpace = 0)
            irb_store(b, conv2, sa, dl_abi_align(vtype(conv2)));
            ssz := dl_type_alloc_size(vtype(conv2));
            cb := san_call(b, ms.maybe_warning_var_size_fn, .[sa, const_int(type_int(64), ssz), o]);
            call_add_param_attr_kind(cb, 1, .ZExt);
            call_add_param_attr_kind(cb, 2, .ZExt);
        }
    } else {
        cmp := msan_convert_to_bool(ms, conv, b, "_mscmp");
        check_term := sbi_if_then(cmp, b.pt, !ms.recover, ms.cold_call_weights);
        irb_set_before(b, check_term);
        msan_insert_warning_fn(ms, b, origin);
    }
}

// materializeInstructionChecks
msan_materialize_instruction_checks :: (ms: *Msan, checks: [] Msan_Check) {
    combine := ms.track_origins == 0;
    i := checks[0].orig_ins;
    shadow: Value_Id = NONE;
    for sd: checks {
        b: Irb; irb_set_before(*b, i);
        conv := sd.shadow;
        if is_constant_kind(vkind(conv)) {
            if !msan_cl.check_constant_shadow || is_null_value(conv) continue;
            if msan_const_known_non_zero(conv) {
                msan_insert_warning_fn(ms, *b, sd.origin);
                if !ms.recover return;
                continue;
            }
        }
        if !combine { msan_materialize_one_check(ms, *b, conv, sd.origin); continue; }
        if shadow == NONE { shadow = conv; continue; }
        shadow = msan_convert_to_bool(ms, shadow, *b, "_mscmp");
        conv = msan_convert_to_bool(ms, conv, *b, "_mscmp");
        shadow = irb_binop(*b, .OR, shadow, conv, "_msor");
    }
    if shadow != NONE {
        b: Irb; irb_set_before(*b, i);
        msan_materialize_one_check(ms, *b, shadow, NONE);
    }
}

// isScalableNonVectorType (e.g. target("aarch64.svcount"))
msan_is_scalable_non_vector_type :: (t: Type_Id) -> bool {
    return type_is_scalable(t) && !is_vector_type(t);
}

// materializeChecks
msan_materialize_checks :: (ms: *Msan) {
    i := 0;
    l := ms.instrumentation_list;
    while i < l.count {
        o := l[i].orig_ins;
        j := i + 1;
        while j < l.count && l[j].orig_ins == o j += 1;
        msan_materialize_instruction_checks(ms, array_view(l, i, j - i));
        i = j;
    }
}

// insertKmsanPrologue
msan_insert_kmsan_prologue :: (ms: *Msan, b: *Irb) {
    cs := san_call(b, ms.get_context_state_fn, .[]);
    zero := const_int(ir.t_i32, 0);
    g :: (b: *Irb, ms: *Msan, cs: Value_Id, k: u64, name: string) -> Value_Id {
        return irb_gep(b, ms.context_state_ty, cs, .[const_int(ir.t_i32, 0), const_int(ir.t_i32, k)], name);
    }
    ms.param_tls = g(b, ms, cs, 0, "param_shadow");
    ms.retval_tls = g(b, ms, cs, 1, "retval_shadow");
    ms.va_arg_tls = g(b, ms, cs, 2, "va_arg_shadow");
    ms.va_arg_origin_tls = g(b, ms, cs, 3, "va_arg_origin");
    ms.va_arg_overflow_size_tls = g(b, ms, cs, 4, "va_arg_overflow_size");
    ms.param_origin_tls = g(b, ms, cs, 5, "param_origin");
    ms.retval_origin_tls = g(b, ms, cs, 6, "retval_origin");
    if ms.triple.arch == .systemz ms.metadata_alloca = irb_alloca(b, ms.metadata_ty, NONE, "", 0);
}

// runOnFunction
msan_run_on_function :: (ms: *Msan) -> bool {
    order: [..] Value_Id; order.allocator = temp;
    san_depth_first(inst(ms.fn_prologue_end).parent, *order);
    nosanitize := md_kind_id("nosanitize");
    for bb: order for i: block_insts(bb) {
        // visit(Instruction &I)
        if get_metadata(i, nosanitize) != NONE continue;
        if msan_is_in_prologue(ms, i) continue;
        array_add(*ms.instructions, i);
    }
    for ms.instructions msan_visit(ms, it);
    for pn: ms.shadow_phis {
        pns := msan_get_shadow(ms, pn);
        pno := ifx ms.track_origins then msan_get_origin(ms, pn) else NONE;
        n := phi_num_incoming(pn);
        for v: 0..cast(s64) n - 1 {
            ib := phi_block(pn, cast(u32) v);
            phi_add_incoming(pns, msan_get_shadow(ms, op(pn, cast(u32) v)), ib);
            if pno != NONE phi_add_incoming(pno, msan_get_origin(ms, op(pn, cast(u32) v)), ib);
        }
    }
    msan_va_finalize(ms);
    if msan_cl.handle_lifetime_intrinsics {
        for item: ms.lifetime_start_list {
            msan_instrument_alloca(ms, item[1], item[0]);
            for x, k: ms.alloca_set if x == item[1] { array_ordered_remove_by_index(*ms.alloca_set, k); break; }
        }
    }
    for ms.alloca_set msan_instrument_alloca(ms, it, NONE);
    msan_materialize_checks(ms);
    msan_materialize_stores(ms);
    return true;
}

// getShadowTy(OrigTy): NONE for unsized types
msan_get_shadow_ty :: (ms: *Msan, t: Type_Id) -> Type_Id {
    if !type_is_sized(t) return NONE;
    k := type_kind(t);
    if k == .INT return t;
    if k == .VECTOR || k == .SVECTOR return type_vector(type_count(t), type_int(dl_type_size_bits(type_elem(t))), k == .SVECTOR);
    if k == .ARRAY return type_array(type_count(t), msan_get_shadow_ty(ms, type_elem(t)));
    if k == .STRUCT {
        els: [..] Type_Id; els.allocator = temp;
        for i: 0..cast(s64) type_nsub(t) - 1 array_add(*els, msan_get_shadow_ty(ms, type_sub(t, cast(u32) i)));
        return type_literal_struct(els, (ir.types[t].flags & TYF_PACKED) != 0);
    }
    if msan_is_scalable_non_vector_type(t) return t;
    return type_int(dl_type_size_bits(t));
}
msan_get_shadow_ty_v :: (ms: *Msan, v: Value_Id) -> Type_Id { return msan_get_shadow_ty(ms, vtype(v)); }

// collapseStructShadow
msan_collapse_struct_shadow :: (ms: *Msan, st: Type_Id, shadow: Value_Id, b: *Irb) -> Value_Id {
    false_val := const_int(ir.t_i1, 0);
    agg := false_val;
    for idx: 0..cast(s64) type_nsub(st) - 1 {
        item := irb_extract_value(b, shadow, .[cast(u32) idx]);
        bv := msan_convert_to_bool(ms, item, b);
        if agg != false_val agg = irb_binop(b, .OR, agg, bv);
        else agg = bv;
    }
    return agg;
}
// collapseArrayShadow
msan_collapse_array_shadow :: (ms: *Msan, at: Type_Id, shadow: Value_Id, b: *Irb) -> Value_Id {
    n := type_count(at);
    if n == 0 return const_int(ir.t_i1, 0);
    first := irb_extract_value(b, shadow, .[0]);
    agg := msan_convert_shadow_to_scalar(ms, first, b);
    for idx: 1..cast(s64) n - 1 {
        item := irb_extract_value(b, shadow, .[cast(u32) idx]);
        inner := msan_convert_shadow_to_scalar(ms, item, b);
        agg = irb_binop(b, .OR, agg, inner);
    }
    return agg;
}
// convertShadowToScalar
msan_convert_shadow_to_scalar :: (ms: *Msan, v: Value_Id, b: *Irb) -> Value_Id {
    t := vtype(v);
    k := type_kind(t);
    if k == .STRUCT return msan_collapse_struct_shadow(ms, t, v, b);
    if k == .ARRAY return msan_collapse_array_shadow(ms, t, v, b);
    if k == .SVECTOR return msan_convert_shadow_to_scalar(ms, irb_or_reduce(b, v), b);
    if k == .VECTOR return irb_bitcast(b, v, type_int(dl_type_size_bits(t)));
    return v;
}
// IRBuilder::CreateOrReduce
irb_or_reduce :: (b: *Irb, v: Value_Id) -> Value_Id {
    return irb_intrinsic(b, "llvm.vector.reduce.or", .[vtype(v)], .[v]);
}
// convertToBool
msan_convert_to_bool :: (ms: *Msan, v: Value_Id, b: *Irb, name := "") -> Value_Id {
    t := vtype(v);
    if type_kind(t) != .INT return msan_convert_to_bool(ms, msan_convert_shadow_to_scalar(ms, v, b), b, name);
    if type_int_width(t) == 1 return v;
    return irb_icmp(b, ICMP_NE, v, const_int(t, 0), name);
}

// ptrToIntPtrType
msan_ptr_to_int_ptr_type :: (ms: *Msan, t: Type_Id) -> Type_Id {
    if is_vector_type(t) return type_vector(type_count(t), msan_ptr_to_int_ptr_type(ms, type_elem(t)), type_kind(t) == .SVECTOR);
    return ms.intptr;
}
msan_ptr_to_shadow_ptr_type :: (ms: *Msan, t: Type_Id) -> Type_Id {
    if is_vector_type(t) return type_vector(type_count(t), msan_ptr_to_shadow_ptr_type(ms, type_elem(t)), type_kind(t) == .SVECTOR);
    return ms.ptr_ty;
}
msan_const_to_int_ptr :: (ms: *Msan, t: Type_Id, c: u64) -> Value_Id {
    if is_vector_type(t) return cf_get_splat(t, msan_const_to_int_ptr(ms, type_elem(t), c));
    return const_int(ms.intptr, c);
}

// getShadowPtrOffset
msan_get_shadow_ptr_offset :: (ms: *Msan, addr: Value_Id, b: *Irb) -> Value_Id {
    it := msan_ptr_to_int_ptr_type(ms, vtype(addr));
    off := irb_pointer_cast(b, addr, it);
    if ms.map.and_mask off = irb_binop(b, .AND, off, msan_const_to_int_ptr(ms, it, ~ms.map.and_mask));
    if ms.map.xor_mask off = irb_binop(b, .XOR, off, msan_const_to_int_ptr(ms, it, ms.map.xor_mask));
    return off;
}

// getShadowOriginPtrUserspace
msan_get_shadow_origin_ptr_userspace :: (ms: *Msan, addr: Value_Id, b: *Irb, shadow_ty: Type_Id, alignment: u64) -> (Value_Id, Value_Id) {
    it := msan_ptr_to_int_ptr_type(ms, vtype(addr));
    soff := msan_get_shadow_ptr_offset(ms, addr, b);
    slong := soff;
    if ms.map.shadow_base slong = irb_binop(b, .ADD, slong, msan_const_to_int_ptr(ms, it, ms.map.shadow_base));
    sptr := irb_cast(b, .INTTOPTR, slong, msan_ptr_to_shadow_ptr_type(ms, it));
    optr: Value_Id = NONE;
    if ms.track_origins {
        olong := soff;
        if ms.map.origin_base olong = irb_binop(b, .ADD, olong, msan_const_to_int_ptr(ms, it, ms.map.origin_base));
        if alignment == 0 || alignment < MSAN_K_MIN_ORIGIN_ALIGNMENT {
            mask := cast(u64) MSAN_K_MIN_ORIGIN_ALIGNMENT - 1;
            olong = irb_binop(b, .AND, olong, msan_const_to_int_ptr(ms, it, ~mask));
        }
        optr = irb_cast(b, .INTTOPTR, olong, msan_ptr_to_shadow_ptr_type(ms, it));
    }
    return sptr, optr;
}

// createMetadataCall
msan_create_metadata_call :: (ms: *Msan, b: *Irb, c: San_Callee, args: [] Value_Id) -> Value_Id {
    if ms.triple.arch == .systemz fatal("msan: SystemZ is not supported");
    return san_call(b, c, args);
}

// getShadowOriginPtrKernelNoVec
msan_get_shadow_origin_ptr_kernel_no_vec :: (ms: *Msan, addr: Value_Id, b: *Irb, shadow_ty: Type_Id, is_store: bool) -> (Value_Id, Value_Id) {
    size, sc := msan_store_size(shadow_ty);
    if sc fatal("msan: KMSAN accesses of scalable types are not supported");
    getter := msan_kmsan_shadow_origin_access_fn(ms, is_store, size);
    addr_cast := irb_pointer_cast(b, addr, ms.ptr_ty);
    sop: Value_Id;
    if getter.callee != NONE sop = msan_create_metadata_call(ms, b, getter, .[addr_cast]);
    else sop = msan_create_metadata_call(ms, b, ifx is_store then ms.metadata_ptr_for_store_n else ms.metadata_ptr_for_load_n, .[addr_cast, const_int(ms.intptr, size)]);
    sptr := irb_extract_value(b, sop, .[0]);
    sptr = irb_pointer_cast(b, sptr, ms.ptr_ty);
    optr := irb_extract_value(b, sop, .[1]);
    return sptr, optr;
}

// getShadowOriginPtrKernel
msan_get_shadow_origin_ptr_kernel :: (ms: *Msan, addr: Value_Id, b: *Irb, shadow_ty: Type_Id, is_store: bool) -> (Value_Id, Value_Id) {
    vt := vtype(addr);
    if !is_vector_type(vt) {
        s, o := msan_get_shadow_origin_ptr_kernel_no_vec(ms, addr, b, shadow_ty, is_store);
        return s, o;
    }
    n := type_count(vt);
    sptrs := const_null_value(type_vector(n, ms.ptr_ty, false));
    optrs: Value_Id = NONE;
    if ms.track_origins optrs = const_null_value(type_vector(n, ms.ptr_ty, false));
    for i: 0..cast(s64) n - 1 {
        one := irb_extract_element_v(b, addr, const_int(ir.t_i32, cast(u64) i));
        sp, opp := msan_get_shadow_origin_ptr_kernel_no_vec(ms, one, b, shadow_ty, is_store);
        sptrs = irb_insert_element_v(b, sptrs, sp, const_int(ir.t_i32, cast(u64) i));
        if ms.track_origins optrs = irb_insert_element_v(b, optrs, opp, const_int(ir.t_i32, cast(u64) i));
    }
    return sptrs, optrs;
}

// IRBuilder::CreateInsertElement(Vec, NewElt, Idx (a Value))
irb_insert_element_v :: (b: *Irb, v: Value_Id, e: Value_Id, idx: Value_Id, name: string = "") -> Value_Id {
    if irb_is_const(v) && irb_is_const(e) && irb_is_const(idx) return ce_insert_element(v, e, idx);
    i := new_inst(.INSERTELEMENT, vtype(v), 3);
    set_op(i, 0, v); set_op(i, 1, e); set_op(i, 2, idx);
    return irb_insert(b, i, name);
}

// getShadowOriginPtr(Addr, IRB, ShadowTy, Alignment, isStore)
msan_get_shadow_origin_ptr :: (ms: *Msan, addr: Value_Id, b: *Irb, shadow_ty: Type_Id, alignment: u64, is_store: bool) -> (Value_Id, Value_Id) {
    if ms.compile_kernel { s, o := msan_get_shadow_origin_ptr_kernel(ms, addr, b, shadow_ty, is_store); return s, o; }
    s, o := msan_get_shadow_origin_ptr_userspace(ms, addr, b, shadow_ty, alignment);
    return s, o;
}

msan_get_shadow_ptr_for_argument :: (ms: *Msan, b: *Irb, off: s64) -> Value_Id {
    return irb_ptr_add(b, ms.param_tls, const_int(ms.intptr, cast(u64) off), "_msarg");
}
msan_get_origin_ptr_for_argument :: (ms: *Msan, b: *Irb, off: s64) -> Value_Id {
    if !ms.track_origins return NONE;
    return irb_ptr_add(b, ms.param_origin_tls, const_int(ms.intptr, cast(u64) off), "_msarg_o");
}
msan_get_shadow_ptr_for_retval :: (ms: *Msan, b: *Irb) -> Value_Id {
    return irb_pointer_cast(b, ms.retval_tls, type_ptr(0), "_msret");
}
msan_get_origin_ptr_for_retval :: (ms: *Msan) -> Value_Id { return ms.retval_origin_tls; }

msan_set_shadow :: (ms: *Msan, v: Value_Id, sv: Value_Id) {
    if table_find_pointer(*ms.shadow_map, v) fatal("internal: msan: values may only have one shadow");
    table_set(*ms.shadow_map, v, ifx ms.propagate_shadow then sv else msan_get_clean_shadow_v(ms, v));
}
msan_set_origin :: (ms: *Msan, v: Value_Id, o: Value_Id) {
    if !ms.track_origins return;
    if table_find_pointer(*ms.origin_map, v) fatal("internal: msan: values may only have one origin");
    table_set(*ms.origin_map, v, o);
}
msan_get_clean_shadow :: (ms: *Msan, t: Type_Id) -> Value_Id {
    st := msan_get_shadow_ty(ms, t);
    if st == NONE return NONE;
    return const_null_value(st);
}
msan_get_clean_shadow_v :: (ms: *Msan, v: Value_Id) -> Value_Id { return msan_get_clean_shadow(ms, vtype(v)); }
// getPoisonedShadow(ShadowTy)
msan_get_poisoned_shadow :: (ms: *Msan, st: Type_Id) -> Value_Id {
    k := type_kind(st);
    if k == .INT || k == .VECTOR || k == .SVECTOR return cf_all_ones(st);
    if k == .ARRAY {
        e := msan_get_poisoned_shadow(ms, type_elem(st));
        vals := NewArray(cast(s64) type_count(st), Value_Id,, temp);
        for * vals it.* = e;
        return const_aggregate(.C_ARRAY, st, vals);
    }
    if k == .STRUCT {
        vals: [..] Value_Id; vals.allocator = temp;
        for i: 0..cast(s64) type_nsub(st) - 1 array_add(*vals, msan_get_poisoned_shadow(ms, type_sub(st, cast(u32) i)));
        return const_aggregate(.C_STRUCT, st, vals);
    }
    fatal("internal: msan: unexpected shadow type");
    return NONE;
}
msan_get_poisoned_shadow_v :: (ms: *Msan, v: Value_Id) -> Value_Id {
    st := msan_get_shadow_ty_v(ms, v);
    if st == NONE return NONE;
    return msan_get_poisoned_shadow(ms, st);
}
msan_get_clean_origin :: (ms: *Msan) -> Value_Id { return const_null_value(ms.origin_ty); }

// getShadow(V)
msan_get_shadow :: (ms: *Msan, v: Value_Id) -> Value_Id {
    k := vkind(v);
    if k == .INST {
        if !ms.propagate_shadow || get_metadata(v, md_kind_id("nosanitize")) != NONE return msan_get_clean_shadow_v(ms, v);
        found, s := table_find(*ms.shadow_map, v);
        if !found || s == NONE fatal("internal: msan: no shadow for a value");
        return s;
    }
    if k == .C_UNDEF || k == .C_POISON {
        return ifx ms.propagate_shadow && ms.poison_undef then msan_get_poisoned_shadow_v(ms, v) else msan_get_clean_shadow_v(ms, v);
    }
    if k == .ARGUMENT {
        found, s := table_find(*ms.shadow_map, v);
        if found && s != NONE return s;
        f := arg_parent(v);
        eb: Irb; irb_set_before(*eb, ms.fn_prologue_end);
        arg_offset: s64 = 0;
        result: Value_Id = NONE;
        for ai: 0..cast(s64) glob(f).nargs - 1 {
            fa := fn_arg(f, cast(u32) ai);
            ft := vtype(fa);
            if !type_is_sized(ft) || type_is_scalable(ft) {
                if fa == v {
                    result = msan_get_clean_shadow_v(ms, v);
                    msan_set_origin(ms, fa, msan_get_clean_origin(ms));
                    break;
                }
                continue;
            }
            byval := fn_has_param_attr(f, cast(u32) ai, .ByVal);
            size: s64 = cast(s64)(ifx byval then dl_type_alloc_size(attr_set_find(fn_param_attr_set(f, cast(u32) ai), .ByVal).ty) else dl_type_alloc_size(ft));
            if fa == v {
                overflow := arg_offset + size > MSAN_K_PARAM_TLS_SIZE;
                if byval {
                    bt := attr_set_find(fn_param_attr_set(f, cast(u32) ai), .ByVal).ty;
                    pa := fn_param_align(f, cast(u32) ai);
                    arg_align := ifx pa then pa else dl_abi_align(bt);
                    cp_shadow, cp_origin := msan_get_shadow_origin_ptr(ms, v, *eb, ir.t_i8, arg_align, true);
                    if !ms.propagate_shadow || overflow {
                        irb_memset(*eb, cp_shadow, const_null_value(ir.t_i8), const_int(type_int(64), cast(u64) size), arg_align, false);
                    } else {
                        base := msan_get_shadow_ptr_for_argument(ms, *eb, arg_offset);
                        copy_align := min(arg_align, cast(u64) MSAN_K_SHADOW_TLS_ALIGNMENT);
                        irb_memcpy(*eb, cp_shadow, copy_align, base, copy_align, const_int(type_int(64), cast(u64) size), false);
                        if ms.track_origins {
                            optr := msan_get_origin_ptr_for_argument(ms, *eb, arg_offset);
                            osz := align_to(cast(u64) size, MSAN_K_MIN_ORIGIN_ALIGNMENT);
                            irb_memcpy(*eb, cp_origin, MSAN_K_MIN_ORIGIN_ALIGNMENT, optr, MSAN_K_MIN_ORIGIN_ALIGNMENT, const_int(type_int(64), osz), false);
                        }
                    }
                }
                if !ms.propagate_shadow || overflow || byval || (ms.eager_checks && fn_has_param_attr(f, cast(u32) ai, .NoUndef)) {
                    result = msan_get_clean_shadow_v(ms, v);
                    msan_set_origin(ms, fa, msan_get_clean_origin(ms));
                } else {
                    base := msan_get_shadow_ptr_for_argument(ms, *eb, arg_offset);
                    result = irb_load(*eb, msan_get_shadow_ty_v(ms, fa), base, MSAN_K_SHADOW_TLS_ALIGNMENT);
                    if ms.track_origins {
                        optr := msan_get_origin_ptr_for_argument(ms, *eb, arg_offset);
                        msan_set_origin(ms, fa, irb_load(*eb, ms.origin_ty, optr, dl_abi_align(ms.origin_ty)));
                    }
                }
                break;
            }
            arg_offset += cast(s64) align_to(cast(u64) size, MSAN_K_SHADOW_TLS_ALIGNMENT);
        }
        if result == NONE fatal("internal: msan: could not find shadow for an argument");
        table_set(*ms.shadow_map, v, result);
        return result;
    }
    t := vtype(v);
    if type_kind(t) == .VECTOR && is_constant_kind(k) && contains_undef_or_poison_element(v) && ms.propagate_shadow && ms.poison_undef_vectors {
        n := type_count(t);
        sv := NewArray(cast(s64) n, Value_Id,, temp);
        for i: 0..cast(s64) n - 1 {
            e := cf_elt(v, cast(u64) i);
            ek := vkind(e);
            sv[i] = ifx ek == .C_UNDEF || ek == .C_POISON then msan_get_poisoned_shadow_v(ms, e) else msan_get_clean_shadow_v(ms, e);
        }
        return const_aggregate(.C_VECTOR, msan_get_shadow_ty(ms, t), sv);
    }
    return msan_get_clean_shadow_v(ms, v);
}
msan_get_shadow_op :: (ms: *Msan, i: Value_Id, k: u32) -> Value_Id { return msan_get_shadow(ms, op(i, k)); }

// getOrigin(V)
msan_get_origin :: (ms: *Msan, v: Value_Id) -> Value_Id {
    if !ms.track_origins return NONE;
    k := vkind(v);
    if !ms.propagate_shadow || is_constant_kind(k) || k == .INLINE_ASM return msan_get_clean_origin(ms);
    if k == .INST && get_metadata(v, md_kind_id("nosanitize")) != NONE return msan_get_clean_origin(ms);
    found, o := table_find(*ms.origin_map, v);
    if !found || o == NONE fatal("internal: msan: missing origin");
    return o;
}
msan_get_origin_op :: (ms: *Msan, i: Value_Id, k: u32) -> Value_Id { return msan_get_origin(ms, op(i, k)); }

// insertCheckShadow(Shadow, Origin, OrigIns)
msan_insert_check_shadow :: (ms: *Msan, shadow: Value_Id, origin: Value_Id, orig_ins: Value_Id) {
    if !ms.insert_checks return;
    if msan_is_scalable_non_vector_type(vtype(shadow)) return;
    array_add(*ms.instrumentation_list, .{shadow, origin, orig_ins});
}
// insertCheckShadowOf(Val, OrigIns)
msan_insert_check_shadow_of :: (ms: *Msan, val: Value_Id, orig_ins: Value_Id) {
    shadow, origin: Value_Id;
    if msan_cl.check_constant_shadow {
        shadow = msan_get_shadow(ms, val);
        if shadow == NONE return;
        origin = msan_get_origin(ms, val);
    } else {
        shadow = msan_get_shadow(ms, val);
        if shadow == NONE || !is_inst(shadow) return;
        origin = msan_get_origin(ms, val);
        if origin != NONE && !is_inst(origin) origin = NONE;
    }
    msan_insert_check_shadow(ms, shadow, origin, orig_ins);
}

// ---------------------------------------------------------------- instruction handlers (part 1)

// visitLoadInst
msan_visit_load :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_next_node(*b, i);
    shadow_ty := msan_get_shadow_ty_v(ms, i);
    addr := op(i, 0);
    alignment := inst(i).align;
    sptr, optr: Value_Id = NONE;
    if ms.propagate_shadow {
        sptr, optr = msan_get_shadow_origin_ptr(ms, addr, *b, shadow_ty, alignment, false);
        msan_set_shadow(ms, i, irb_load(*b, shadow_ty, sptr, alignment, false, "_msld"));
    } else msan_set_shadow(ms, i, msan_get_clean_shadow_v(ms, i));
    if msan_cl.check_access_address msan_insert_check_shadow_of(ms, addr, i);
    if inst(i).ord1 != 0 inst(i).ord1 = msan_add_acquire_ordering(inst(i).ord1);
    if ms.track_origins {
        if ms.propagate_shadow {
            oa := max(cast(u64) MSAN_K_MIN_ORIGIN_ALIGNMENT, alignment);
            msan_set_origin(ms, i, irb_load(*b, ms.origin_ty, optr, oa));
        } else msan_set_origin(ms, i, msan_get_clean_origin(ms));
    }
}

// visitStoreInst
msan_visit_store :: (ms: *Msan, i: Value_Id) {
    array_add(*ms.store_list, i);
    if msan_cl.check_access_address msan_insert_check_shadow_of(ms, op(i, 1), i);
}

// handleCASOrRMW
msan_handle_cas_or_rmw :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    addr := op(i, 0);
    val := op(i, 1);
    sptr, _ := msan_get_shadow_origin_ptr(ms, addr, *b, msan_get_shadow_ty_v(ms, val), 1, true);
    if msan_cl.check_access_address msan_insert_check_shadow_of(ms, addr, i);
    if inst_op(i) == .CMPXCHG msan_insert_check_shadow_of(ms, val, i);
    cs := msan_get_clean_shadow_v(ms, val);
    irb_store(*b, cs, sptr, dl_abi_align(vtype(cs)));
    msan_set_shadow(ms, i, msan_get_clean_shadow_v(ms, i));
    msan_set_origin(ms, i, msan_get_clean_origin(ms));
}

// propagateEqualityComparison
msan_propagate_equality_comparison :: (ms: *Msan, b: *Irb, a_in: Value_Id, b_in: Value_Id, sa: Value_Id, sb: Value_Id) -> Value_Id {
    a := irb_pointer_cast(b, a_in, vtype(sa));
    bb := irb_pointer_cast(b, b_in, vtype(sb));
    c := irb_binop(b, .XOR, a, bb);
    sc := irb_binop(b, .OR, sa, sb);
    zero := const_null_value(vtype(sc));
    minus_one := cf_all_ones(vtype(sc));
    lhs := irb_icmp(b, ICMP_NE, sc, zero);
    rhs := irb_icmp(b, ICMP_EQ, irb_binop(b, .AND, irb_binop(b, .XOR, sc, minus_one), c), zero);
    si := irb_binop(b, .AND, lhs, rhs);
    if is_inst(si) set_name(si, "_msprop_icmp");   // Value::setName is a no-op on a constant
    return si;
}

// visitSwitchInst
msan_visit_switch :: (ms: *Msan, si: Value_Id) {
    b: Irb; irb_set_before(*b, si);
    val := op(si, 0);
    sval := msan_get_shadow(ms, val);
    left := msan_cl.switch_precision;
    cases: Value_Id = NONE;
    ncases := cast(s64) nops(si) - 2;
    for k: 0..ncases - 1 {
        if left <= 0 break;
        comparator := ir.u_aux[ir.v_ops[si] + cast(u32)(2 + k)];   // the case value (switch operands: cond, default, dests)
        cs := msan_propagate_equality_comparison(ms, *b, val, comparator, sval, msan_get_shadow(ms, comparator));
        if cases != NONE cases = irb_binop(*b, .OR, cases, cs);
        else cases = cs;
        left -= 1;
    }
    if cases != NONE msan_insert_check_shadow(ms, cases, msan_get_origin(ms, val), si);
}

msan_visit_extract_element :: (ms: *Msan, i: Value_Id) {
    msan_insert_check_shadow_of(ms, op(i, 1), i);
    b: Irb; irb_set_before(*b, i);
    msan_set_shadow(ms, i, irb_extract_element_v(*b, msan_get_shadow_op(ms, i, 0), op(i, 1), "_msprop"));
    msan_set_origin(ms, i, msan_get_origin_op(ms, i, 0));
}
msan_visit_insert_element :: (ms: *Msan, i: Value_Id) {
    msan_insert_check_shadow_of(ms, op(i, 2), i);
    b: Irb; irb_set_before(*b, i);
    s0 := msan_get_shadow_op(ms, i, 0);
    s1 := msan_get_shadow_op(ms, i, 1);
    msan_set_shadow(ms, i, irb_insert_element_v(*b, s0, s1, op(i, 2), "_msprop"));
    msan_set_origin_for_nary_op(ms, i);
}
msan_visit_shuffle_vector :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    s0 := msan_get_shadow_op(ms, i, 0);
    s1 := msan_get_shadow_op(ms, i, 1);
    mask := NewArray(cast(s64) inst(i).nidx, u32,, temp);   // a copy: irb_shuffle appends to ir.u32_pool
    for * mask it.* = ir.u32_pool[inst(i).idx + cast(u32) it_index];
    msan_set_shadow(ms, i, irb_shuffle(*b, s0, s1, mask, "_msprop"));
    msan_set_origin_for_nary_op(ms, i);
}
// SExt / ZExt / Trunc
msan_visit_ext_trunc :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    msan_set_shadow(ms, i, irb_cast(*b, inst_op(i), msan_get_shadow_op(ms, i, 0), vtype(i), "_msprop"));
    msan_set_origin(ms, i, msan_get_origin_op(ms, i, 0));
}
msan_visit_bitcast :: (ms: *Msan, i: Value_Id) {
    o := op(i, 0);
    if is_inst(o) && inst_op(o) == .CALL && call_tail_kind(o) == TCK_MUSTTAIL return;
    b: Irb; irb_set_before(*b, i);
    msan_set_shadow(ms, i, irb_bitcast(*b, msan_get_shadow_op(ms, i, 0), msan_get_shadow_ty_v(ms, i)));
    msan_set_origin(ms, i, msan_get_origin_op(ms, i, 0));
}
msan_visit_ptr_int_cast :: (ms: *Msan, i: Value_Id, name: string) {
    b: Irb; irb_set_before(*b, i);
    msan_set_shadow(ms, i, irb_int_cast(*b, msan_get_shadow_op(ms, i, 0), msan_get_shadow_ty_v(ms, i), false, name));
    msan_set_origin(ms, i, msan_get_origin_op(ms, i, 0));
}

// handleGenericVectorConvertIntrinsic(I, FixedPoint)
msan_handle_generic_vector_convert :: (ms: *Msan, i: Value_Id, fixed_point: bool) {
    if fixed_point msan_insert_check_shadow_of(ms, op(i, 1), i);
    b: Irb; irb_set_before(*b, i);
    s0 := msan_get_shadow_op(ms, i, 0);
    out := irb_cast(*b, .SEXT, irb_icmp(*b, ICMP_NE, s0, msan_get_clean_shadow_v(ms, s0)), msan_get_shadow_ty_v(ms, i));
    msan_set_shadow(ms, i, out);
    msan_set_origin_for_nary_op(ms, i);
}

// handleBitwiseAnd
msan_handle_bitwise_and :: (ms: *Msan, b: *Irb, v1: Value_Id, v2: Value_Id, s1: Value_Id, s2: Value_Id) -> Value_Id {
    s1s2 := irb_binop(b, .AND, s1, s2);
    v1s2 := irb_binop(b, .AND, v1, s2);
    s1v2 := irb_binop(b, .AND, s1, v2);
    return irb_binop(b, .OR, irb_binop(b, .OR, s1s2, v1s2), s1v2);
}
msan_visit_and :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    s := msan_handle_bitwise_and(ms, *b, op(i, 0), op(i, 1), msan_get_shadow_op(ms, i, 0), msan_get_shadow_op(ms, i, 1));
    msan_set_shadow(ms, i, s);
    msan_set_origin_for_nary_op(ms, i);
}
msan_visit_or :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    s1 := msan_get_shadow_op(ms, i, 0);
    s2 := msan_get_shadow_op(ms, i, 1);
    v1 := op(i, 0); v2 := op(i, 1);
    not_v1 := irb_not(*b, v1);
    not_v2 := irb_not(*b, v2);
    s1s2 := irb_binop(*b, .AND, s1, s2);
    s2nv1 := irb_binop(*b, .AND, not_v1, s2);
    s1nv2 := irb_binop(*b, .AND, s1, not_v2);
    s := irb_binop(*b, .OR, irb_binop(*b, .OR, s1s2, s2nv1), s1nv2);
    if msan_cl.precise_disjoint_or && (inst(i).flags & F_EXACT) {
        v1v2 := irb_binop(*b, .AND, v1, v2);
        dos := irb_cast(*b, .SEXT, irb_icmp(*b, ICMP_NE, v1v2, msan_get_clean_shadow_v(ms, v1v2)), vtype(v1v2));
        s = irb_binop(*b, .OR, s, dos, "_ms_disjoint");
    }
    msan_set_shadow(ms, i, s);
    msan_set_origin_for_nary_op(ms, i);
}

// Combiner<CombineShadow>
Msan_Combiner :: struct {
    ms: *Msan;
    b: *Irb;
    combine_shadow: bool;
    shadow: Value_Id = NONE;
    origin: Value_Id = NONE;
}
msan_combiner :: (ms: *Msan, b: *Irb, combine_shadow: bool) -> Msan_Combiner {
    c: Msan_Combiner; c.ms = ms; c.b = b; c.combine_shadow = combine_shadow;
    return c;
}
msan_comb_add_so :: (c: *Msan_Combiner, op_shadow_in: Value_Id, op_origin: Value_Id) {
    ms := c.ms; op_shadow := op_shadow_in;
    if c.combine_shadow {
        if c.shadow == NONE c.shadow = op_shadow;
        else {
            op_shadow = msan_create_shadow_cast(ms, c.b, op_shadow, vtype(c.shadow));
            c.shadow = irb_binop(c.b, .OR, c.shadow, op_shadow, "_msprop");
        }
    }
    if ms.track_origins {
        if c.origin == NONE c.origin = op_origin;
        else {
            if !(is_constant_kind(vkind(op_origin)) && is_null_value(op_origin)) {
                cond := msan_convert_to_bool(ms, op_shadow, c.b);
                c.origin = irb_select(c.b, cond, op_origin, c.origin);
            }
        }
    }
}
msan_comb_add :: (c: *Msan_Combiner, v: Value_Id) {
    s := msan_get_shadow(c.ms, v);
    o := ifx c.ms.track_origins then msan_get_origin(c.ms, v) else NONE;
    msan_comb_add_so(c, s, o);
}
msan_comb_done :: (c: *Msan_Combiner, i: Value_Id) {
    ms := c.ms;
    if c.combine_shadow {
        c.shadow = msan_create_shadow_cast(ms, c.b, c.shadow, msan_get_shadow_ty_v(ms, i));
        msan_set_shadow(ms, i, c.shadow);
    }
    if ms.track_origins msan_set_origin(ms, i, c.origin);
}
msan_comb_done_and_store_origin :: (c: *Msan_Combiner, size: u64, scalable: bool, origin_ptr: Value_Id) {
    if c.ms.track_origins msan_paint_origin(c.ms, c.b, c.origin, origin_ptr, size, scalable, MSAN_K_MIN_ORIGIN_ALIGNMENT);
}

// setOriginForNaryOp(I)
msan_set_origin_for_nary_op :: (ms: *Msan, i: Value_Id) {
    if !ms.track_origins return;
    b: Irb; irb_set_before(*b, i);
    oc := msan_combiner(ms, *b, false);
    for k: 0..cast(s64) nops(i) - 1 msan_comb_add(*oc, op(i, cast(u32) k));
    msan_comb_done(*oc, i);
}

// VectorOrPrimitiveTypeSizeInBits
msan_vector_or_primitive_bits :: (t: Type_Id) -> u64 {
    if is_vector_type(t) return type_count(t) * type_bits(type_elem(t));
    return type_bits(t);
}

// CreateShadowCast(IRB, V, dstTy, Signed)
msan_create_shadow_cast :: (ms: *Msan, b: *Irb, v: Value_Id, dst: Type_Id, signed := false) -> Value_Id {
    src := vtype(v);
    if src == dst return v;
    sb := msan_vector_or_primitive_bits(src);
    db := msan_vector_or_primitive_bits(dst);
    if sb > 1 && db == 1 return irb_icmp(b, ICMP_NE, v, msan_get_clean_shadow_v(ms, v));
    if type_kind(dst) == .INT && type_kind(src) == .INT return irb_int_cast(b, v, dst, signed);
    if is_vector_type(dst) && is_vector_type(src) && type_count(dst) == type_count(src) && type_kind(dst) == type_kind(src)
        return irb_int_cast(b, v, dst, signed);
    v1 := irb_bitcast(b, v, type_int(sb));
    v2 := irb_int_cast(b, v1, type_int(db), signed);
    return irb_bitcast(b, v2, dst);
}

// CreateAppToShadowCast
msan_create_app_to_shadow_cast :: (ms: *Msan, b: *Irb, v: Value_Id) -> Value_Id {
    st := msan_get_shadow_ty_v(ms, v);
    if vtype(v) == st return v;
    if is_ptr_type(scalar_type(vtype(v))) return irb_cast(b, .PTRTOINT, v, st);
    return irb_bitcast(b, v, st);
}

// handleShadowOr(I)
msan_handle_shadow_or :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    sc := msan_combiner(ms, *b, true);
    for k: 0..cast(s64) nops(i) - 1 msan_comb_add(*sc, op(i, cast(u32) k));
    msan_comb_done(*sc, i);
}

// handleMulByConstant
msan_handle_mul_by_constant :: (ms: *Msan, i: Value_Id, const_arg: Value_Id, other: Value_Id) {
    ty := vtype(const_arg);
    shadow_mul: Value_Id;
    pow2_of_tz :: (c: Value_Id, et: Type_Id) -> Value_Id {
        if vkind(c) == .C_INT {
            v := const_ap(c);
            tz := ap_ctz(v);
            w := type_int_width(et);
            if tz >= w return const_null_value(et);   // APInt(BW, 1) << BW = 0
            return cf_int(et, ap_shl(ap_one(w), tz));
        }
        return const_int(et, 1);
    }
    if is_vector_type(ty) {
        n := type_count(ty);
        et := type_elem(ty);
        els := NewArray(cast(s64) n, Value_Id,, temp);
        for k: 0..cast(s64) n - 1 els[k] = pow2_of_tz(cf_elt(const_arg, cast(u64) k), et);
        shadow_mul = const_aggregate(.C_VECTOR, ty, els);
    } else shadow_mul = pow2_of_tz(const_arg, ty);
    b: Irb; irb_set_before(*b, i);
    msan_set_shadow(ms, i, irb_binop(*b, .MUL, msan_get_shadow(ms, other), shadow_mul, "msprop_mul_cst"));
    msan_set_origin(ms, i, msan_get_origin(ms, other));
}
msan_visit_mul :: (ms: *Msan, i: Value_Id) {
    c0 := is_constant_kind(vkind(op(i, 0)));
    c1 := is_constant_kind(vkind(op(i, 1)));
    if c0 && !c1 msan_handle_mul_by_constant(ms, i, op(i, 0), op(i, 1));
    else if c1 && !c0 msan_handle_mul_by_constant(ms, i, op(i, 1), op(i, 0));
    else msan_handle_shadow_or(ms, i);
}

// handleIntegerDiv
msan_handle_integer_div :: (ms: *Msan, i: Value_Id) {
    msan_insert_check_shadow_of(ms, op(i, 1), i);
    msan_set_shadow(ms, i, msan_get_shadow_op(ms, i, 0));
    msan_set_origin(ms, i, msan_get_origin_op(ms, i, 0));
}

// handleEqualityComparison
msan_handle_equality_comparison :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    a := op(i, 0); bb := op(i, 1);
    si := msan_propagate_equality_comparison(ms, *b, a, bb, msan_get_shadow(ms, a), msan_get_shadow(ms, bb));
    msan_set_shadow(ms, i, si);
    msan_set_origin_for_nary_op(ms, i);
}
// handleRelationalComparisonExact
msan_handle_relational_comparison_exact :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    a := op(i, 0); bb := op(i, 1);
    sa := msan_get_shadow(ms, a); sb := msan_get_shadow(ms, bb);
    a = irb_pointer_cast(*b, a, vtype(sa));
    bb = irb_pointer_cast(*b, bb, vtype(sb));
    pred := inst(i).pred;
    is_signed := pred >= ICMP_SGT && pred <= ICMP_SLE;
    min_max :: (ms: *Msan, b: *Irb, v_in: Value_Id, s: Value_Id, is_signed: bool) -> (Value_Id, Value_Id) {
        v := v_in;
        if is_signed {
            w := type_bits(scalar_type(vtype(v)));
            v = irb_binop(b, .XOR, v, cf_int(vtype(v), ap_signed_min(w)));
        }
        mn := irb_binop(b, .AND, v, irb_not(b, s));
        mx := irb_binop(b, .OR, v, s);
        return mn, mx;
    }
    amin, amax := min_max(ms, *b, a, sa, is_signed);
    bmin, bmax := min_max(ms, *b, bb, sb, is_signed);
    up := icmp_unsigned_predicate(pred);
    s1 := irb_icmp(*b, up, amin, bmax);
    s2 := irb_icmp(*b, up, amax, bmin);
    msan_set_shadow(ms, i, irb_binop(*b, .XOR, s1, s2));
    msan_set_origin_for_nary_op(ms, i);
}
// handleSignedRelationalComparison
msan_handle_signed_relational_comparison :: (ms: *Msan, i: Value_Id) {
    const_op, x: Value_Id; pre: u8;
    if is_constant_kind(vkind(op(i, 1))) { const_op = op(i, 1); x = op(i, 0); pre = inst(i).pred; }
    else if is_constant_kind(vkind(op(i, 0))) { const_op = op(i, 0); x = op(i, 1); pre = icmp_swapped(inst(i).pred); }
    else { msan_handle_shadow_or(ms, i); return; }
    if (is_null_value(const_op) && (pre == ICMP_SLT || pre == ICMP_SGE)) || (cf_is_all_ones(const_op) && (pre == ICMP_SGT || pre == ICMP_SLE)) {
        b: Irb; irb_set_before(*b, i);
        s := irb_icmp(*b, ICMP_SLT, msan_get_shadow(ms, x), msan_get_clean_shadow_v(ms, x), "_msprop_icmp_s");
        msan_set_shadow(ms, i, s);
        msan_set_origin(ms, i, msan_get_origin(ms, x));
    } else msan_handle_shadow_or(ms, i);
}
// visitICmpInst
msan_visit_icmp :: (ms: *Msan, i: Value_Id) {
    if !msan_cl.handle_icmp { msan_handle_shadow_or(ms, i); return; }
    pred := inst(i).pred;
    if pred == ICMP_EQ || pred == ICMP_NE { msan_handle_equality_comparison(ms, i); return; }
    if msan_cl.handle_icmp_exact { msan_handle_relational_comparison_exact(ms, i); return; }
    if pred >= ICMP_SGT && pred <= ICMP_SLE { msan_handle_signed_relational_comparison(ms, i); return; }
    if is_constant_kind(vkind(op(i, 0))) || is_constant_kind(vkind(op(i, 1))) { msan_handle_relational_comparison_exact(ms, i); return; }
    msan_handle_shadow_or(ms, i);
}

// handleShift
msan_handle_shift :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    s1 := msan_get_shadow_op(ms, i, 0);
    s2 := msan_get_shadow_op(ms, i, 1);
    s2conv := irb_cast(*b, .SEXT, irb_icmp(*b, ICMP_NE, s2, msan_get_clean_shadow_v(ms, s2)), vtype(s2));
    shift := irb_binop(*b, inst_op(i), s1, op(i, 1));
    msan_set_shadow(ms, i, irb_binop(*b, .OR, shift, s2conv));
    msan_set_origin_for_nary_op(ms, i);
}

// visitMemMoveInst / visitMemCpyInst / visitMemSetInst
msan_visit_mem_transfer :: (ms: *Msan, i: Value_Id, is_move: bool) {
    msan_get_shadow(ms, op(i, 1));
    b: Irb; irb_set_before(*b, i);
    san_call(*b, ifx is_move then ms.memmove_fn else ms.memcpy_fn, .[op(i, 0), op(i, 1), irb_int_cast(*b, op(i, 2), ms.intptr, false)]);
    erase_inst(i);
}
msan_visit_mem_set :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    san_call(*b, ms.memset_fn, .[op(i, 0), irb_int_cast(*b, op(i, 1), ir.t_i32, false), irb_int_cast(*b, op(i, 2), ms.intptr, false)]);
    erase_inst(i);
}

// ---------------------------------------------------------------- instruction handlers (part 2)

// visitLibAtomicLoad
msan_visit_lib_atomic_load :: (ms: *Msan, cb: Value_Id) {
    b: Irb; irb_set_before(*b, cb);
    size := op(cb, 0); src := op(cb, 1); dst := op(cb, 2); ordering := op(cb, 3);
    no := irb_extract_element_v(*b, msan_add_acquire_ordering_table(), ordering);
    set_op(cb, 3, no);
    nb: Irb; irb_next_node(*nb, cb);
    ssp, sop := msan_get_shadow_origin_ptr(ms, src, *nb, ir.t_i8, 1, false);
    dsp, _ := msan_get_shadow_origin_ptr(ms, dst, *nb, ir.t_i8, 1, true);
    irb_memcpy(*nb, dsp, 1, ssp, 1, size, false);
    if ms.track_origins {
        so := irb_load(*nb, ms.origin_ty, sop, MSAN_K_MIN_ORIGIN_ALIGNMENT);
        no2 := msan_update_origin(ms, so, *nb);
        san_call(*nb, ms.set_origin_fn, .[dst, size, no2]);
    }
}
// visitLibAtomicStore
msan_visit_lib_atomic_store :: (ms: *Msan, cb: Value_Id) {
    b: Irb; irb_set_before(*b, cb);
    size := op(cb, 0); dst := op(cb, 2); ordering := op(cb, 3);
    no := irb_extract_element_v(*b, msan_add_release_ordering_table(), ordering);
    set_op(cb, 3, no);
    dsp, _ := msan_get_shadow_origin_ptr(ms, dst, *b, ir.t_i8, 1, true);
    irb_memset(*b, dsp, msan_get_clean_shadow(ms, ir.t_i8), size, 1, false);
}

// CallBase::removeFnAttrs({Memory, Speculatable})
call_remove_memory_speculatable :: (c: Value_Id) {
    l := inst(c).attrs;
    inst(c).attrs = attr_list_with_fn(l, attr_set_remove(attr_set_remove(attr_list_fn(l), .Memory), .Speculatable));
}

// visitCallBase
msan_visit_call_base :: (ms: *Msan, cb: Value_Id) {
    if call_is_inline_asm(cb) {
        if msan_cl.handle_asm_conservative msan_visit_asm_instruction(ms, cb);
        else msan_visit_instruction(ms, cb);
        return;
    }
    found, lf := tli_lookup_call(cb);
    if found {
        if lf == .atomic_load {
            if inst_op(cb) != .CALL print_to_stderr("MSAN -- cannot instrument invoke of libatomic load.Ignoring!\n");
            else { msan_visit_lib_atomic_load(ms, cb); return; }
        } else if lf == .atomic_store { msan_visit_lib_atomic_store(ms, cb); return; }
    }
    if inst_op(cb) == .CALL {
        call_remove_memory_speculatable(cb);
        fnv := call_called_function(cb);
        if fnv != NONE {
            l := glob(fnv).attrs;
            glob(fnv).attrs = attr_list_with_fn(l, attr_set_remove(attr_set_remove(attr_list_fn(l), .Memory), .Speculatable));
        }
        maybe_mark_sanitizer_library_call_no_builtin(cb, ms.tli);
    }
    b: Irb; irb_set_before(*b, cb);
    may_check_call := ms.eager_checks;
    fnv := call_called_function(cb);
    if fnv != NONE may_check_call &= !begins_with(vname(fnv), "__sanitizer_unaligned_");
    arg_offset: u64 = 0;
    n := call_arg_count(cb);
    for k: 0..cast(s64) n - 1 {
        a := op(cb, cast(u32) k);
        at := vtype(a);
        if !type_is_sized(at) continue;
        if type_is_scalable(at) { msan_insert_check_shadow_of(ms, a, cb); continue; }
        size: u64 = 0;
        byval := call_param_has_attr(cb, cast(u32) k, .ByVal);
        noundef := call_param_has_attr(cb, cast(u32) k, .NoUndef);
        eager := may_check_call && !byval && noundef;
        if eager {
            msan_insert_check_shadow_of(ms, a, cb);
            size = dl_type_alloc_size(at);
        } else {
            arg_shadow := msan_get_shadow(ms, a);
            base := msan_get_shadow_ptr_for_argument(ms, *b, cast(s64) arg_offset);
            if byval {
                size = dl_type_alloc_size(call_param_byval_type(cb, cast(u32) k));
                if arg_offset + size > MSAN_K_PARAM_TLS_SIZE break;
                pa := call_param_align(cb, cast(u32) k);
                al: u64 = 0;
                if pa al = min(pa, cast(u64) MSAN_K_SHADOW_TLS_ALIGNMENT);
                asp, aop := msan_get_shadow_origin_ptr(ms, a, *b, ir.t_i8, al, false);
                if !ms.propagate_shadow {
                    irb_memset(*b, base, const_null_value(ir.t_i8), const_int(type_int(64), size), al, false);
                } else {
                    irb_memcpy(*b, base, al, asp, al, const_int(type_int(64), size), false);
                    if ms.track_origins {
                        aob := msan_get_origin_ptr_for_argument(ms, *b, cast(s64) arg_offset);
                        osz := align_to(size, MSAN_K_MIN_ORIGIN_ALIGNMENT);
                        irb_memcpy(*b, aob, MSAN_K_MIN_ORIGIN_ALIGNMENT, aop, MSAN_K_MIN_ORIGIN_ALIGNMENT, const_int(type_int(64), osz), false);
                    }
                }
            } else {
                size = dl_type_alloc_size(at);
                if arg_offset + size > MSAN_K_PARAM_TLS_SIZE break;
                irb_store(*b, arg_shadow, base, MSAN_K_SHADOW_TLS_ALIGNMENT);
                cst := is_constant_kind(vkind(arg_shadow)) && is_null_value(arg_shadow);
                if ms.track_origins && !cst {
                    o := msan_get_origin(ms, a);
                    irb_store(*b, o, msan_get_origin_ptr_for_argument(ms, *b, cast(s64) arg_offset), dl_abi_align(vtype(o)));
                }
            }
        }
        arg_offset += align_to(size, MSAN_K_SHADOW_TLS_ALIGNMENT);
    }
    ft := inst(cb).ty2;
    if func_vararg(ft) msan_va_visit_call_base(ms, cb, *b);
    if !type_is_sized(vtype(cb)) return;
    if inst_op(cb) == .CALL && call_tail_kind(cb) == TCK_MUSTTAIL return;
    if may_check_call && call_has_ret_attr(cb, .NoUndef) {
        msan_set_shadow(ms, cb, msan_get_clean_shadow_v(ms, cb));
        msan_set_origin(ms, cb, msan_get_clean_origin(ms));
        return;
    }
    bb: Irb; irb_set_before(*bb, cb);
    base := msan_get_shadow_ptr_for_retval(ms, *bb);
    irb_store(*bb, msan_get_clean_shadow_v(ms, cb), base, MSAN_K_SHADOW_TLS_ALIGNMENT);
    next_bb, next_pt: Value_Id; head := false;
    if inst_op(cb) == .CALL {
        next_pt = inst(cb).next;
        next_bb = inst(cb).parent;
    } else {
        normal := get_successor(cb, 0);
        if block_single_predecessor(normal) == NONE {
            msan_set_shadow(ms, cb, msan_get_clean_shadow_v(ms, cb));
            msan_set_origin(ms, cb, msan_get_clean_origin(ms));
            return;
        }
        next_bb = normal; next_pt = block_first_insertion_pt(normal); head = true;
    }
    ba: Irb; irb_set_at(*ba, next_bb, next_pt, head);
    rs := irb_load(*ba, msan_get_shadow_ty_v(ms, cb), msan_get_shadow_ptr_for_retval(ms, *ba), MSAN_K_SHADOW_TLS_ALIGNMENT, false, "_msret");
    msan_set_shadow(ms, cb, rs);
    if ms.track_origins msan_set_origin(ms, cb, irb_load(*ba, ms.origin_ty, msan_get_origin_ptr_for_retval(ms), dl_abi_align(ms.origin_ty)));
}

// isAMustTailRetVal
msan_is_a_must_tail_ret_val :: (v_in: Value_Id) -> bool {
    v := v_in;
    if is_inst(v) && inst_op(v) == .BITCAST v = op(v, 0);
    if is_inst(v) && inst_op(v) == .CALL return call_tail_kind(v) == TCK_MUSTTAIL;
    return false;
}

// visitReturnInst
msan_visit_return :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    if nops(i) == 0 return;
    rv := op(i, 0);
    if msan_is_a_must_tail_ret_val(rv) return;
    sptr := msan_get_shadow_ptr_for_retval(ms, *b);
    has_noundef := fn_has_ret_attr(ms.f, .NoUndef);
    store_shadow := !(ms.eager_checks && has_noundef);
    eager := (ms.eager_checks && has_noundef) || vname(ms.f) == "main";
    shadow := msan_get_shadow(ms, rv);
    store_origin := true;
    if eager {
        msan_insert_check_shadow_of(ms, rv, i);
        shadow = msan_get_clean_shadow_v(ms, rv);
        store_origin = false;
    }
    if store_shadow {
        irb_store(*b, shadow, sptr, MSAN_K_SHADOW_TLS_ALIGNMENT);
        if ms.track_origins && store_origin {
            o := msan_get_origin(ms, rv);
            irb_store(*b, o, msan_get_origin_ptr_for_retval(ms), dl_abi_align(vtype(o)));
        }
    }
}

// visitPHINode
msan_visit_phi :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    if !ms.propagate_shadow {
        msan_set_shadow(ms, i, msan_get_clean_shadow_v(ms, i));
        msan_set_origin(ms, i, msan_get_clean_origin(ms));
        return;
    }
    array_add(*ms.shadow_phis, i);
    n := phi_num_incoming(i);
    msan_set_shadow(ms, i, irb_phi(*b, msan_get_shadow_ty_v(ms, i), n, "_msphi_s"));
    if ms.track_origins msan_set_origin(ms, i, irb_phi(*b, ms.origin_ty, n, "_msphi_o"));
}

// getLocalVarIdptr / getLocalVarDescription
msan_get_local_var_idptr :: (ms: *Msan, ai: Value_Id) -> Value_Id {
    return gv_create(ir.t_i32, false, .PRIVATE, const_int(ir.t_i32, 0), "", NONE, 0, dl.globals_as);
}
msan_get_local_var_description :: (ms: *Msan, ai: Value_Id) -> Value_Id {
    s := vname(ai);
    elts := NewArray(s.count + 1, u64,, temp);
    for 0..s.count-1 elts[it] = s[it];
    c := const_data(type_array(cast(u64) s.count + 1, ir.t_i8), elts);
    return gv_create(vtype(c), true, .PRIVATE, c, "", NONE, 0, dl.globals_as);
}

// poisonAllocaUserspace
msan_poison_alloca_userspace :: (ms: *Msan, ai: Value_Id, b: *Irb, len: Value_Id) {
    if ms.poison_stack && msan_cl.poison_stack_with_call {
        san_call(b, ms.poison_stack_fn, .[ai, len]);
    } else {
        sb, _ := msan_get_shadow_origin_ptr(ms, ai, b, ir.t_i8, 1, true);
        pv := const_int(ir.t_i8, cast(u64)(ifx ms.poison_stack then msan_cl.poison_stack_pattern else 0));
        irb_memset(b, sb, pv, len, inst(ai).align, false);
    }
    if ms.poison_stack && ms.track_origins {
        idptr := msan_get_local_var_idptr(ms, ai);
        if msan_cl.print_stack_names {
            descr := msan_get_local_var_description(ms, ai);
            san_call(b, ms.set_alloca_origin_with_descr_fn, .[ai, len, idptr, descr]);
        } else san_call(b, ms.set_alloca_origin_no_descr_fn, .[ai, len, idptr]);
    }
}
// poisonAllocaKmsan
msan_poison_alloca_kmsan :: (ms: *Msan, ai: Value_Id, b: *Irb, len: Value_Id) {
    descr := msan_get_local_var_description(ms, ai);
    if ms.poison_stack san_call(b, ms.poison_alloca_fn, .[ai, len, descr]);
    else san_call(b, ms.unpoison_alloca_fn, .[ai, len]);
}
// instrumentAlloca(I, InsPoint)
msan_instrument_alloca :: (ms: *Msan, ai: Value_Id, ins_point_in: Value_Id) {
    ins_point := ifx ins_point_in == NONE then ai else ins_point_in;
    b: Irb; irb_next_node(*b, ins_point);
    len := irb_allocation_size(*b, ms.intptr, ai);
    if ms.compile_kernel msan_poison_alloca_kmsan(ms, ai, *b, len);
    else msan_poison_alloca_userspace(ms, ai, *b, len);
}
// visitAllocaInst
msan_visit_alloca :: (ms: *Msan, i: Value_Id) {
    msan_set_shadow(ms, i, msan_get_clean_shadow_v(ms, i));
    msan_set_origin(ms, i, msan_get_clean_origin(ms));
    if !array_find(ms.alloca_set, i) array_add(*ms.alloca_set, i);
}

// handleSelectLikeInst(I, B, C, D)
msan_handle_select_like :: (ms: *Msan, i: Value_Id, bv_in: Value_Id, c_in: Value_Id, d_in: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    bv := bv_in; c := c_in; d := d_in;
    sb := msan_get_shadow(ms, bv); sc := msan_get_shadow(ms, c); sd := msan_get_shadow(ms, d);
    ob := ifx ms.track_origins then msan_get_origin(ms, bv) else NONE;
    oc := ifx ms.track_origins then msan_get_origin(ms, c) else NONE;
    od := ifx ms.track_origins then msan_get_origin(ms, d) else NONE;
    sa0 := irb_select(*b, bv, sc, sd);
    sa1: Value_Id;
    t := vtype(i);
    if is_aggregate(t) sa1 = msan_get_poisoned_shadow(ms, msan_get_shadow_ty(ms, t));
    else if msan_is_scalable_non_vector_type(t) sa1 = msan_get_clean_shadow(ms, t);
    else {
        c = msan_create_app_to_shadow_cast(ms, *b, c);
        d = msan_create_app_to_shadow_cast(ms, *b, d);
        sa1 = irb_binop(*b, .OR, irb_binop(*b, .OR, irb_binop(*b, .XOR, c, d), sc), sd);
    }
    sa := irb_select(*b, sb, sa1, sa0, "_msprop_select");
    msan_set_shadow(ms, i, sa);
    if ms.track_origins {
        if is_vector_type(vtype(bv)) {
            bv = msan_convert_to_bool(ms, bv, *b);
            sb = msan_convert_to_bool(ms, sb, *b);
        }
        msan_set_origin(ms, i, irb_select(*b, sb, ob, irb_select(*b, bv, oc, od)));
    }
}

msan_set_clean :: (ms: *Msan, i: Value_Id) {
    msan_set_shadow(ms, i, msan_get_clean_shadow_v(ms, i));
    msan_set_origin(ms, i, msan_get_clean_origin(ms));
}

msan_visit_extract_value :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    as := msan_get_shadow(ms, op(i, 0));
    idxs := NewArray(cast(s64) inst(i).nidx, u32,, temp);
    for * idxs it.* = ir.u32_pool[inst(i).idx + cast(u32) it_index];
    msan_set_shadow(ms, i, irb_extract_value(*b, as, idxs));
    msan_set_origin_for_nary_op(ms, i);
}
msan_visit_insert_value :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    as := msan_get_shadow(ms, op(i, 0));
    is := msan_get_shadow(ms, op(i, 1));
    idxs := NewArray(cast(s64) inst(i).nidx, u32,, temp);
    for * idxs it.* = ir.u32_pool[inst(i).idx + cast(u32) it_index];
    msan_set_shadow(ms, i, irb_insert_value(*b, as, is, idxs));
    msan_set_origin_for_nary_op(ms, i);
}

// instrumentAsmArgument
msan_instrument_asm_argument :: (ms: *Msan, operand: Value_Id, elem_ty: Type_Id, i: Value_Id, b: *Irb, is_output: bool) {
    msan_insert_check_shadow_of(ms, operand, i);
    if !is_ptr_type(vtype(operand)) || !is_output return;
    if elem_ty == NONE || !type_is_sized(elem_ty) return;
    size, sc := msan_store_size(elem_ty);
    size_val := irb_type_size(b, ms.intptr, size, sc);
    if ms.compile_kernel {
        san_call(b, ms.instrument_asm_store_fn, .[operand, size_val]);
    } else {
        sptr, _ := msan_get_shadow_origin_ptr_userspace(ms, operand, b, ir.t_i8, 1);
        if !sc && size <= 32 irb_store(b, msan_get_clean_shadow(ms, elem_ty), sptr, 1);
        else irb_memset(b, sptr, const_null_value(ir.t_i8), size_val, 1, false);
    }
}
// getNumOutputArgs
msan_get_num_output_args :: (ms: *Msan, cb: Value_Id) -> s64 {
    num_ret := 0;
    rt := vtype(cb);
    if rt != ir.t_void {
        if type_kind(rt) == .STRUCT num_ret = cast(s64) type_nsub(rt);
        else num_ret = 1;
    }
    num_out := 0;
    for c: split(inline_asm_constraints(call_callee(cb)), ",",, temp) if begins_with(c, "=") num_out += 1;
    return num_out - num_ret;
}
// visitAsmInstruction
msan_visit_asm_instruction :: (ms: *Msan, cb: Value_Id) {
    b: Irb; irb_set_before(*b, cb);
    outs := msan_get_num_output_args(ms, cb);
    nops_ := cast(s64) nops(cb) - 1;
    for k: outs..nops_-1 msan_instrument_asm_argument(ms, op(cb, cast(u32) k), call_param_elementtype(cb, cast(u32) k), cb, *b, false);
    for k: 0..outs-1 msan_instrument_asm_argument(ms, op(cb, cast(u32) k), call_param_elementtype(cb, cast(u32) k), cb, *b, true);
    msan_set_clean(ms, cb);
}
// CallBase::getParamElementType(ArgNo)
call_param_elementtype :: (c: Value_Id, k: u32) -> Type_Id {
    if k >= call_arg_count(c) return NONE;
    a := attr_set_find(attr_list_param(inst(c).attrs, k), .ElementType);
    if a return a.ty;
    return NONE;
}

// visitInstruction (strict)
msan_visit_instruction :: (ms: *Msan, i: Value_Id) {
    if msan_cl.dump_strict_instructions msan_dump_inst(i, "Strict");
    for k: 0..cast(s64) nops(i) - 1 {
        o := op(i, cast(u32) k);
        if type_is_sized(vtype(o)) msan_insert_check_shadow_of(ms, o, i);
    }
    msan_set_clean(ms, i);
}
msan_dump_inst :: (i: Value_Id, prefix: string) {
    fatal("msan: -msan-dump-*-instructions is not supported");
}

// InstVisitor<MemorySanitizerVisitor>::visit(I): the opcode dispatch
msan_visit :: (ms: *Msan, i: Value_Id) {
    o := inst_op(i);
    if o == {
        case .LOAD; msan_visit_load(ms, i);
        case .STORE; msan_visit_store(ms, i);
        case .ATOMICRMW; msan_handle_cas_or_rmw(ms, i); inst(i).ord1 = msan_add_release_ordering(inst(i).ord1);
        case .CMPXCHG; msan_handle_cas_or_rmw(ms, i); inst(i).ord1 = msan_add_release_ordering(inst(i).ord1);
        case .SWITCH; msan_visit_switch(ms, i);
        case .EXTRACTELEMENT; msan_visit_extract_element(ms, i);
        case .INSERTELEMENT; msan_visit_insert_element(ms, i);
        case .SHUFFLEVECTOR; msan_visit_shuffle_vector(ms, i);
        case .SEXT; #through; case .ZEXT; #through; case .TRUNC; msan_visit_ext_trunc(ms, i);
        case .BITCAST; msan_visit_bitcast(ms, i);
        case .PTRTOINT; msan_visit_ptr_int_cast(ms, i, "_msprop_ptrtoint");
        case .INTTOPTR; msan_visit_ptr_int_cast(ms, i, "_msprop_inttoptr");
        case .FPTOSI; #through; case .FPTOUI; #through; case .SITOFP; #through; case .UITOFP; msan_handle_generic_vector_convert(ms, i, false);
        case .FPEXT; #through; case .FPTRUNC; msan_handle_shadow_or(ms, i);
        case .AND; msan_visit_and(ms, i);
        case .OR; msan_visit_or(ms, i);
        case .FNEG; msan_handle_shadow_or(ms, i);
        case .MUL; msan_visit_mul(ms, i);
        case .FADD; #through; case .FSUB; #through; case .FMUL; #through; case .ADD; #through; case .SUB; #through; case .XOR;
            msan_handle_shadow_or(ms, i);
        case .UDIV; #through; case .SDIV; #through; case .UREM; #through; case .SREM; msan_handle_integer_div(ms, i);
        case .FDIV; #through; case .FREM; msan_handle_shadow_or(ms, i);
        case .ICMP; msan_visit_icmp(ms, i);
        case .FCMP; msan_handle_shadow_or(ms, i);
        case .SHL; #through; case .ASHR; #through; case .LSHR; msan_handle_shift(ms, i);
        case .RET; msan_visit_return(ms, i);
        case .PHI; msan_visit_phi(ms, i);
        case .ALLOCA; msan_visit_alloca(ms, i);
        case .SELECT; msan_handle_select_like(ms, i, op(i, 0), op(i, 1), op(i, 2));
        case .LANDINGPAD; #through; case .CATCHSWITCH; #through; case .CATCHPAD; #through; case .CLEANUPPAD; msan_set_clean(ms, i);
        case .GEP; msan_handle_shadow_or(ms, i);
        case .EXTRACTVALUE; msan_visit_extract_value(ms, i);
        case .INSERTVALUE; msan_visit_insert_value(ms, i);
        case .RESUME; #through; case .CLEANUPRET; #through; case .CATCHRET;
        case .FREEZE; msan_set_clean(ms, i);
        case .CALL; #through; case .INVOKE; #through; case .CALLBR;
            id := call_iid(i);
            // IntrinsicInst is a CallInst: invokes / callbrs of intrinsics are plain call bases
            if id == NOT_INTRINSIC || o != .CALL { msan_visit_call_base(ms, i); return; }
            // InstVisitor::delegateCallInst
            if id == IID_MEMCPY || id == IID_MEMCPY_INLINE { msan_visit_mem_transfer(ms, i, false); return; }
            if id == IID_MEMMOVE { msan_visit_mem_transfer(ms, i, true); return; }
            if id == IID_MEMSET || id == IID_MEMSET_INLINE { msan_visit_mem_set(ms, i); return; }
            n := function_intrinsic_base(call_called_function(i));
            if n == "llvm.va_start" { msan_va_visit_va_start(ms, i); return; }
            if n == "llvm.va_copy" { msan_va_visit_va_copy(ms, i); return; }
            msan_visit_intrinsic_inst(ms, i);
        case; msan_visit_instruction(ms, i);
    }
}

// visitIntrinsicInst
msan_visit_intrinsic_inst :: (ms: *Msan, i: Value_Id) {
    if msan_maybe_handle_cross_platform_intrinsic(ms, i) return;
    if msan_maybe_handle_x86_simd_intrinsic(ms, i) return;
    n := function_intrinsic_base(call_called_function(i));
    if begins_with(n, "llvm.aarch64.") || begins_with(n, "llvm.arm.") fatal("msan: ARM SIMD intrinsics are not supported (%)", n);
    if msan_maybe_handle_unknown_intrinsic(ms, i) return;
    msan_visit_instruction(ms, i);
}

// ---------------------------------------------------------------- VarArgHelper (AMD64, NoOp)

Msan_Va :: struct {
    kind: Msan_Va_Kind;
    va_list_tag_size: u64;
    va_start_list: [..] Value_Id;
    fp_end_offset: u64;
    va_arg_tls_copy: Value_Id = NONE;
    va_arg_tls_origin_copy: Value_Id = NONE;
    va_arg_overflow_size: Value_Id = NONE;
}
MSAN_AMD64_GP_END_OFFSET :: 48;
MSAN_AMD64_FP_END_OFFSET_SSE :: 176;

// CreateVarArgHelper
msan_create_vararg_helper :: (ms: *Msan) {
    va := *ms.va;
    va.va_start_list.allocator = temp;
    a := ms.triple.arch;
    if a == .x86_64 {
        va.kind = .AMD64;
        va.va_list_tag_size = 24;
        va.fp_end_offset = MSAN_AMD64_FP_END_OFFSET_SSE;
        for attr_set_items(attr_list_fn(glob(ms.f).attrs)) {
            if it.kind == .STRING_ATTR && it.key == "target-features" {
                if find_index_from_left(it.val, "-sse") >= 0 va.fp_end_offset = MSAN_AMD64_GP_END_OFFSET;
                break;
            }
        }
        return;
    }
    fatal("msan: the vararg helper for target '%' is not ported", ir.triple);
}

msan_va_shadow_ptr :: (ms: *Msan, b: *Irb, off: u64) -> Value_Id {
    return irb_ptr_add(b, ms.va_arg_tls, const_int(ms.intptr, off), "_msarg_va_s");
}
msan_va_origin_ptr :: (ms: *Msan, b: *Irb, off: u64) -> Value_Id {
    return irb_ptr_add(b, ms.va_arg_origin_tls, const_int(ms.intptr, off), "_msarg_va_o");
}
// CleanUnusedTLS
msan_va_clean_unused_tls :: (ms: *Msan, b: *Irb, shadow_base: Value_Id, base_offset: u64) {
    if base_offset >= MSAN_K_PARAM_TLS_SIZE return;
    tail := const_int(ir.t_i32, MSAN_K_PARAM_TLS_SIZE - base_offset);
    irb_memset(b, shadow_base, const_null_value(ir.t_i8), tail, 8, false);
}
// unpoisonVAListTagForInst
msan_va_unpoison_va_list_tag :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    tag := op(i, 0);
    sptr, _ := msan_get_shadow_origin_ptr(ms, tag, *b, ir.t_i8, 8, true);
    irb_memset(*b, sptr, const_null_value(ir.t_i8), const_int(type_int(64), ms.va.va_list_tag_size), 8, false);
}
CC_WIN64 :: 79;
msan_va_visit_va_start :: (ms: *Msan, i: Value_Id) {
    if ms.va.kind == .NOOP return;
    if glob(ms.f).cc == CC_WIN64 return;
    array_add(*ms.va.va_start_list, i);
    msan_va_unpoison_va_list_tag(ms, i);
}
msan_va_visit_va_copy :: (ms: *Msan, i: Value_Id) {
    if ms.va.kind == .NOOP return;
    if glob(ms.f).cc == CC_WIN64 return;
    msan_va_unpoison_va_list_tag(ms, i);
}

// VarArgAMD64Helper::classifyArgument: 0 general purpose, 1 floating point, 2 memory
msan_amd64_classify :: (t: Type_Id) -> u8 {
    if type_kind(t) == .X86_FP80 return 2;
    st := scalar_type(t);
    if is_fp_type(st) return 1;
    if type_kind(t) == .INT && type_bits(t) <= 64 return 0;
    if type_kind(t) == .PTR return 0;
    return 2;
}

// VarArgAMD64Helper::visitCallBase
msan_va_visit_call_base :: (ms: *Msan, cb: Value_Id, b: *Irb) {
    if ms.va.kind == .NOOP return;
    gp: u64 = 0;
    fp: u64 = MSAN_AMD64_GP_END_OFFSET;
    overflow := ms.va.fp_end_offset;
    nparams := func_nparams(inst(cb).ty2);
    n := call_arg_count(cb);
    for k: 0..cast(s64) n - 1 {
        a := op(cb, cast(u32) k);
        is_fixed := cast(u32) k < nparams;
        if call_param_has_attr(cb, cast(u32) k, .ByVal) {
            if is_fixed continue;
            real_ty := call_param_byval_type(cb, cast(u32) k);
            arg_size := dl_type_alloc_size(real_ty);
            aligned := align_to(arg_size, 8);
            base_off := overflow;
            sbase := msan_va_shadow_ptr(ms, b, overflow);
            obase: Value_Id = NONE;
            if ms.track_origins obase = msan_va_origin_ptr(ms, b, overflow);
            overflow += aligned;
            if overflow > MSAN_K_PARAM_TLS_SIZE { msan_va_clean_unused_tls(ms, b, sbase, base_off); continue; }
            sp, opp := msan_get_shadow_origin_ptr(ms, a, b, ir.t_i8, MSAN_K_SHADOW_TLS_ALIGNMENT, false);
            irb_memcpy(b, sbase, MSAN_K_SHADOW_TLS_ALIGNMENT, sp, MSAN_K_SHADOW_TLS_ALIGNMENT, const_int(type_int(64), arg_size), false);
            if ms.track_origins irb_memcpy(b, obase, MSAN_K_SHADOW_TLS_ALIGNMENT, opp, MSAN_K_SHADOW_TLS_ALIGNMENT, const_int(type_int(64), arg_size), false);
            continue;
        }
        ak := msan_amd64_classify(vtype(a));
        if ak == 0 && gp >= MSAN_AMD64_GP_END_OFFSET ak = 2;
        if ak == 1 && fp >= ms.va.fp_end_offset ak = 2;
        sbase, obase: Value_Id = NONE;
        if ak == 0 {
            sbase = msan_va_shadow_ptr(ms, b, gp);
            if ms.track_origins obase = msan_va_origin_ptr(ms, b, gp);
            gp += 8;
        } else if ak == 1 {
            sbase = msan_va_shadow_ptr(ms, b, fp);
            if ms.track_origins obase = msan_va_origin_ptr(ms, b, fp);
            fp += 16;
        } else {
            if is_fixed continue;
            arg_size := dl_type_alloc_size(vtype(a));
            aligned := align_to(arg_size, 8);
            base_off := overflow;
            sbase = msan_va_shadow_ptr(ms, b, overflow);
            if ms.track_origins obase = msan_va_origin_ptr(ms, b, overflow);
            overflow += aligned;
            if overflow > MSAN_K_PARAM_TLS_SIZE { msan_va_clean_unused_tls(ms, b, sbase, base_off); continue; }
        }
        if is_fixed continue;
        shadow := msan_get_shadow(ms, a);
        irb_store(b, shadow, sbase, MSAN_K_SHADOW_TLS_ALIGNMENT);
        if ms.track_origins {
            origin := msan_get_origin(ms, a);
            ss, sc := msan_store_size(vtype(shadow));
            msan_paint_origin(ms, b, origin, obase, ss, sc, max(cast(u64) MSAN_K_SHADOW_TLS_ALIGNMENT, cast(u64) MSAN_K_MIN_ORIGIN_ALIGNMENT));
        }
    }
    osz := const_int(type_int(64), overflow - ms.va.fp_end_offset);
    irb_store(b, osz, ms.va_arg_overflow_size_tls, dl_abi_align(type_int(64)));
}

// VarArgAMD64Helper::finalizeInstrumentation
msan_va_finalize :: (ms: *Msan) {
    va := *ms.va;
    if va.kind == .NOOP return;
    i64 := type_int(64);
    if va.va_start_list.count {
        b: Irb; irb_set_before(*b, ms.fn_prologue_end);
        va.va_arg_overflow_size = irb_load(*b, i64, ms.va_arg_overflow_size_tls, dl_abi_align(i64));
        copy_size := irb_binop(*b, .ADD, const_int(ms.intptr, va.fp_end_offset), va.va_arg_overflow_size);
        va.va_arg_tls_copy = irb_alloca(*b, ir.t_i8, copy_size);
        inst(va.va_arg_tls_copy).align = MSAN_K_SHADOW_TLS_ALIGNMENT;
        irb_memset(*b, va.va_arg_tls_copy, const_null_value(ir.t_i8), copy_size, MSAN_K_SHADOW_TLS_ALIGNMENT, false);
        src_size := irb_intrinsic(*b, "llvm.umin", .[vtype(copy_size)], .[copy_size, const_int(ms.intptr, MSAN_K_PARAM_TLS_SIZE)]);
        irb_memcpy(*b, va.va_arg_tls_copy, MSAN_K_SHADOW_TLS_ALIGNMENT, ms.va_arg_tls, MSAN_K_SHADOW_TLS_ALIGNMENT, src_size, false);
        if ms.track_origins {
            va.va_arg_tls_origin_copy = irb_alloca(*b, ir.t_i8, copy_size);
            inst(va.va_arg_tls_origin_copy).align = MSAN_K_SHADOW_TLS_ALIGNMENT;
            irb_memcpy(*b, va.va_arg_tls_origin_copy, MSAN_K_SHADOW_TLS_ALIGNMENT, ms.va_arg_origin_tls, MSAN_K_SHADOW_TLS_ALIGNMENT, src_size, false);
        }
    }
    for oi: va.va_start_list {
        b: Irb; irb_next_node(*b, oi);
        tag := op(oi, 0);
        rsapp := irb_ptr_add(*b, tag, const_int(ms.intptr, 16));
        rsap := irb_load(*b, ms.ptr_ty, rsapp, dl_abi_align(ms.ptr_ty));
        rss, rso := msan_get_shadow_origin_ptr(ms, rsap, *b, ir.t_i8, 16, true);
        irb_memcpy(*b, rss, 16, va.va_arg_tls_copy, 16, const_int(i64, va.fp_end_offset), false);
        if ms.track_origins irb_memcpy(*b, rso, 16, va.va_arg_tls_origin_copy, 16, const_int(i64, va.fp_end_offset), false);
        oapp := irb_ptr_add(*b, tag, const_int(ms.intptr, 8));
        oap := irb_load(*b, ms.ptr_ty, oapp, dl_abi_align(ms.ptr_ty));
        oas, oao := msan_get_shadow_origin_ptr(ms, oap, *b, ir.t_i8, 16, true);
        src := irb_const_gep1_32(*b, ir.t_i8, va.va_arg_tls_copy, va.fp_end_offset);
        irb_memcpy(*b, oas, 16, src, 16, va.va_arg_overflow_size, false);
        if ms.track_origins {
            src = irb_const_gep1_32(*b, ir.t_i8, va.va_arg_tls_origin_copy, va.fp_end_offset);
            irb_memcpy(*b, oao, 16, src, 16, va.va_arg_overflow_size, false);
        }
    }
}
