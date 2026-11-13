// HWAddressSanitizer: a port of llvm/lib/Transforms/Instrumentation/HWAddressSanitizer.cpp (HWAddressSanitizerPass
// "hwasan" / "hwasan<kernel;recover>", every cl::opt) with memtag:: from llvm/lib/Transforms/Utils/
// MemoryTaggingSupport.cpp and isReachableImpl (LoopInfo flavour, exclusion sets) from llvm/lib/Analysis/CFG.cpp.
// Scope: the x86-64 parts (callbacks, inline checks with the int3 trap, page aliasing, kernel mode, globals,
// personality thunks, stack tagging) and the target-independent code. Not ported (fail loudly): the AArch64/RISC-V
// outlined checks (llvm.hwasan.check.memaccess*), Android/Darwin thread slots, -hwasan-random-rate.
// The DomTreeUpdater / LoopInfo updates are not ported: the function analyses are dropped after the pass instead
// of preserved.

hwasan_cl: struct {
    memory_access_callback_prefix := "__hwasan_";
    kasan_mem_intrin_callback_prefix: bool;
    instrument_with_calls: bool;        has_instrument_with_calls: bool;
    instrument_reads := true;
    instrument_writes := true;
    instrument_atomics := true;
    instrument_byval := true;
    recover: bool;                      has_recover: bool;
    instrument_stack := true;
    use_stack_safety := true;           has_use_stack_safety: bool;
    max_lifetimes: s64 = 3;
    use_after_scope := true;
    strict_use_after_scope := true;
    generate_tags_with_calls: bool;
    globals: bool;                      has_globals: bool;
    all_globals: bool;
    match_all_tag: s64 = -1;            has_match_all_tag: bool;
    enable_khwasan: bool;               has_enable_khwasan: bool;
    mapping_offset: u64;                mapping_offset_pos: s64;      // 0 = not given
    mapping_offset_dynamic: s64;        mapping_offset_dynamic_pos: s64;  // 1 global 2 ifunc 3 tls
    frame_records: bool;                has_frame_records: bool;
    hot_percentile_cutoff: s64;         has_hot_percentile_cutoff: bool;
    has_random_keep_rate: bool;
    static_linking: bool;
    record_stack_history: s64 = 1;      // 0 none 1 instr 2 libcall
    instrument_mem_intrinsics := true;
    instrument_landing_pads: bool;      has_instrument_landing_pads: bool;
    use_short_granules: bool;           has_use_short_granules: bool;
    instrument_personality_functions: bool; has_instrument_personality_functions: bool;
    inline_all_checks: bool;            has_inline_all_checks: bool;
    inline_fast_path_checks: bool;      has_inline_fast_path_checks: bool;
    use_page_aliases: bool;
    tag_bits: u64;
    position: s64;
};

hwasan_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    pb :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("opt: for the --% option: '%' is invalid value for boolean argument! Try 0 or 1", name, value);
        return false;
    }
    pi :: (name: string, value: string) -> s64 {
        v, ok, rest := string_to_int(value);
        if !ok || rest.count fatal("opt: for the --% option: '%' value invalid for integer argument!", name, value);
        return v;
    }
    pu :: (name: string, value: string) -> u64 {
        v, ok, rest := string_to_int(value, 10, u64);
        if !ok || rest.count fatal("opt: for the --% option: '%' value invalid for uint argument!", name, value);
        return v;
    }
    o := *hwasan_cl;
    o.position += 1;
    if name == {
        case "hwasan-memory-access-callback-prefix"; o.memory_access_callback_prefix = copy_string(value);
        case "hwasan-kernel-mem-intrinsic-prefix"; o.kasan_mem_intrin_callback_prefix = pb(name, value, has_value);
        case "hwasan-instrument-with-calls"; o.instrument_with_calls = pb(name, value, has_value); o.has_instrument_with_calls = true;
        case "hwasan-instrument-reads"; o.instrument_reads = pb(name, value, has_value);
        case "hwasan-instrument-writes"; o.instrument_writes = pb(name, value, has_value);
        case "hwasan-instrument-atomics"; o.instrument_atomics = pb(name, value, has_value);
        case "hwasan-instrument-byval"; o.instrument_byval = pb(name, value, has_value);
        case "hwasan-recover"; o.recover = pb(name, value, has_value); o.has_recover = true;
        case "hwasan-instrument-stack"; o.instrument_stack = pb(name, value, has_value);
        case "hwasan-use-stack-safety"; o.use_stack_safety = pb(name, value, has_value); o.has_use_stack_safety = true;
        case "hwasan-max-lifetimes-for-alloca"; o.max_lifetimes = pi(name, value);
        case "hwasan-use-after-scope"; o.use_after_scope = pb(name, value, has_value);
        case "hwasan-strict-use-after-scope"; o.strict_use_after_scope = pb(name, value, has_value);
        case "hwasan-generate-tags-with-calls"; o.generate_tags_with_calls = pb(name, value, has_value);
        case "hwasan-globals"; o.globals = pb(name, value, has_value); o.has_globals = true;
        case "hwasan-all-globals"; o.all_globals = pb(name, value, has_value);
        case "hwasan-match-all-tag"; o.match_all_tag = pi(name, value); o.has_match_all_tag = true;
        case "hwasan-kernel"; o.enable_khwasan = pb(name, value, has_value); o.has_enable_khwasan = true;
        case "hwasan-mapping-offset"; o.mapping_offset = pu(name, value); o.mapping_offset_pos = o.position;
        case "hwasan-mapping-offset-dynamic";
            if value == "global" o.mapping_offset_dynamic = 1;
            else if value == "ifunc" o.mapping_offset_dynamic = 2;
            else if value == "tls" o.mapping_offset_dynamic = 3;
            else fatal("opt: for the --hwasan-mapping-offset-dynamic option: Cannot find option named '%'!", value);
            o.mapping_offset_dynamic_pos = o.position;
        case "hwasan-with-frame-record"; o.frame_records = pb(name, value, has_value); o.has_frame_records = true;
        case "hwasan-percentile-cutoff-hot"; o.hot_percentile_cutoff = pi(name, value); o.has_hot_percentile_cutoff = true;
        case "hwasan-random-rate"; o.has_random_keep_rate = true;
        case "hwasan-static-linking"; o.static_linking = pb(name, value, has_value);
        case "hwasan-record-stack-history";
            if value == "none" o.record_stack_history = 0;
            else if value == "instr" o.record_stack_history = 1;
            else if value == "libcall" o.record_stack_history = 2;
            else fatal("opt: for the --hwasan-record-stack-history option: Cannot find option named '%'!", value);
        case "hwasan-instrument-mem-intrinsics"; o.instrument_mem_intrinsics = pb(name, value, has_value);
        case "hwasan-instrument-landing-pads"; o.instrument_landing_pads = pb(name, value, has_value); o.has_instrument_landing_pads = true;
        case "hwasan-use-short-granules"; o.use_short_granules = pb(name, value, has_value); o.has_use_short_granules = true;
        case "hwasan-instrument-personality-functions"; o.instrument_personality_functions = pb(name, value, has_value); o.has_instrument_personality_functions = true;
        case "hwasan-inline-all-checks"; o.inline_all_checks = pb(name, value, has_value); o.has_inline_all_checks = true;
        case "hwasan-inline-fast-path-checks"; o.inline_fast_path_checks = pb(name, value, has_value); o.has_inline_fast_path_checks = true;
        case "hwasan-experimental-use-page-aliases"; o.use_page_aliases = pb(name, value, has_value);
        case "hwasan-tag-bits"; o.tag_bits = pu(name, value);
        case; o.position -= 1; return false;
    }
    return true;
}

HWASAN_NUMBER_OF_ACCESS_SIZES :: 5;
HWASAN_SHADOW_BASE_ALIGNMENT :: 32;
// HWASanAccessInfo
HWAI_ACCESS_SIZE_SHIFT :: 0; HWAI_IS_WRITE_SHIFT :: 4; HWAI_RECOVER_SHIFT :: 5; HWAI_MATCH_ALL_SHIFT :: 16;
HWAI_HAS_MATCH_ALL_SHIFT :: 24; HWAI_COMPILE_KERNEL_SHIFT :: 25; HWAI_RUNTIME_MASK :: 0xffff;

// memtag::AllocaInfo / StackInfo
Mt_Bb_Info :: struct { bb: Value_Id; first: Intrinsic_Id; last: Intrinsic_Id; }
Mt_Alloca_Info :: struct {
    ai: Value_Id;
    lifetime_start: [..] Value_Id;
    lifetime_end: [..] Value_Id;
    dbg_records: [..] u32;
    bb_infos: [..] Mt_Bb_Info;   // a MapVector: insertion order
}
Mt_Stack_Info :: struct {
    allocas: [..] Mt_Alloca_Info;   // AllocasToInstrument (a MapVector)
    index: Table(Value_Id, s64);
    ret_vec: [..] Value_Id;
    calls_return_twice: bool;
}

Hwasan :: struct {
    ssi: *Stack_Safety_Global;
    recover, compile_kernel: bool;
    is_x86_64: bool;
    // ShadowMapping: kind 0 fixed 1 global 2 ifunc 3 tls
    map_kind: s64; map_offset: u64; map_scale: u64; map_with_frame_record: bool;
    intptr: Type_Id;
    outlined_checks, inline_fast_path, use_short_granules, instrument_landing_pads, instrument_with_calls: bool;
    instrument_stack, instrument_globals, detect_use_after_scope, use_page_aliases, use_match_all_callback: bool;
    has_match_all_tag: bool; match_all_tag: u64;
    pointer_tag_shift: u64;
    tag_mask_byte: u64;
    ctor_function: Value_Id = NONE;
    access_cb: [2][HWASAN_NUMBER_OF_ACCESS_SIZES] San_Callee;
    access_cb_sized: [2] San_Callee;
    memmove, memcpy, memset, handle_vfork, tag_memory, generate_tag, record_frame_record: San_Callee;
    shadow_global: Value_Id = NONE;
    shadow_base: Value_Id = NONE;
    stack_base_tag: Value_Id = NONE;
    cached_fp: Value_Id = NONE;
    thread_ptr_global: Value_Id = NONE;
}

hwasan_obj_align :: (h: *Hwasan) -> u64 { return (cast(u64) 1) << h.map_scale; }
hwasan_align_to :: (v: u64, a: u64) -> u64 { return (v + a - 1) / a * a; }

// ShadowMapping::init
hwasan_mapping_init :: (h: *Hwasan, t: Triple) {
    h.map_scale = 4;
    h.map_kind = 3;
    h.map_with_frame_record = true;
    if t.os == .Fuchsia h.map_kind = 1;
    else if h.compile_kernel || h.instrument_with_calls { h.map_kind = 0; h.map_offset = 0; h.map_with_frame_record = false; }
    if hwasan_cl.has_frame_records h.map_with_frame_record = hwasan_cl.frame_records;
    if hwasan_cl.mapping_offset_dynamic_pos h.map_kind = hwasan_cl.mapping_offset_dynamic;
    if hwasan_cl.mapping_offset_pos && !(hwasan_cl.mapping_offset_dynamic_pos && hwasan_cl.mapping_offset_dynamic_pos > hwasan_cl.mapping_offset_pos) {
        h.map_kind = 0; h.map_offset = hwasan_cl.mapping_offset;
    }
}

// InlineAsm::get(FTy, AsmString, Constraints, HasSideEffects)
san_inline_asm :: (fty: Type_Id, asm_str: string, constraints: string, side_effects: bool) -> Value_Id {
    flags: u32 = ifx side_effects then cast(u32) 1 else 0;
    ty := type_ptr(0);
    k := const_key_begin(.INLINE_ASM, ty);
    key_str(k, asm_str); key_str(k, constraints); key_u32(k, flags); key_u32(k, fty);
    found, v := table_find(*ir.const_map, key_view(k));
    if found return v;
    aux := cast(u32) inline_asms.count;
    array_add(*inline_asms, .{intern_str(asm_str), intern_str(constraints), flags, fty});
    return const_lookup_or_create(k, .INLINE_ASM, ty, .[], aux);
}

// createHwasanNote
hwasan_create_note :: (h: *Hwasan) {
    cd := get_comdat("hwasan.module_ctor");
    i8a0 := type_array(0, ir.t_i8);
    st := gv_create(i8a0, true, .EXTERNAL, NONE, "__start_hwasan_globals", NONE, 0, dl.globals_as);
    glob(st).visibility = 1;
    sp := gv_create(i8a0, true, .EXTERNAL, NONE, "__stop_hwasan_globals", NONE, 0, dl.globals_as);
    glob(sp).visibility = 1;
    name_elts := u64.[#char "L", #char "L", #char "V", #char "M", 0, 0, 0, 0];
    name := const_data(type_array(8, ir.t_i8), name_elts);
    i32 := ir.t_i32; i64 := ir.t_i64;
    note_ty := type_literal_struct(.[i32, i32, i32, vtype(name), i32, i32], false);
    note := gv_create(note_ty, true, .PRIVATE, NONE, "hwasan.note", NONE, 0, dl.globals_as);
    glob(note).section = ".note.hwasan.globals";
    glob(note).comdat = cd;
    glob(note).align = 4;
    rel :: (p: Value_Id, note: Value_Id) -> Value_Id {
        d := ce_binop(.SUB, ce_cast(.PTRTOINT, p, ir.t_i64), ce_cast(.PTRTOINT, note, ir.t_i64), 0);
        return ce_cast(.TRUNC, d, ir.t_i32);
    }
    NT_LLVM_HWASAN_GLOBALS :: 3;
    gv_set_initializer(note, const_aggregate(.C_STRUCT, note_ty, .[const_int(i32, 8), const_int(i32, 8), const_int(i32, NT_LLVM_HWASAN_GLOBALS), name, rel(st, note), rel(sp, note)]));
    append_to_compiler_used(note);
    dummy := gv_create(i8a0, true, .PRIVATE, const_null_value(i8a0), "hwasan.dummy.global", NONE, 0, dl.globals_as);
    glob(dummy).section = "hwasan_globals";
    glob(dummy).comdat = cd;
    set_metadata(dummy, md_kind_id("associated"), md_tuple(.[md_value(note)], false));
    append_to_compiler_used(dummy);
}

// initializeModule
hwasan_initialize_module :: (h: *Hwasan) {
    t := san_triple();
    for ir.m_functions remove_asan_incompatible_fn_attributes(it, true);
    h.is_x86_64 = t.arch == .x86_64;
    h.use_page_aliases = hwasan_cl.use_page_aliases && h.is_x86_64;
    h.instrument_with_calls = ifx hwasan_cl.has_instrument_with_calls then hwasan_cl.instrument_with_calls else h.is_x86_64;
    h.instrument_stack = !h.use_page_aliases && hwasan_cl.instrument_stack;
    h.detect_use_after_scope = hwasan_cl.use_after_scope && h.instrument_stack;
    h.pointer_tag_shift = ifx h.is_x86_64 then cast(u64) 57 else 56;
    h.tag_mask_byte = ifx h.is_x86_64 then cast(u64) 0x3F else 0xFF;
    if hwasan_cl.tag_bits {
        if h.tag_mask_byte < 4 fatal("need more than 4 bits of tag to have non-short-granule tags");
        h.tag_mask_byte &= ((cast(u64) 1) << hwasan_cl.tag_bits) - 1;
    }
    h.intptr = type_int(dl_ptr_spec(0).bits);
    hwasan_mapping_init(h, t);
    h.ctor_function = NONE;
    is_android := t.env == .Android;
    if is_android fatal("hwasan: Android targets are not supported (only the x86-64 parts are ported)");
    new_runtime := true;   // !isAndroid() || !isAndroidVersionLT(30)
    h.use_short_granules = ifx hwasan_cl.has_use_short_granules then hwasan_cl.use_short_granules else new_runtime;
    is_aarch64 := t.arch == .aarch64 || t.arch == .aarch64_be || t.arch == .aarch64_32;
    inline_all := ifx hwasan_cl.has_inline_all_checks then hwasan_cl.inline_all_checks else h.recover;
    h.outlined_checks = (is_aarch64 || t.arch == .riscv64) && t.obj == .ELF && !inline_all;
    h.inline_fast_path = ifx hwasan_cl.has_inline_fast_path_checks then hwasan_cl.inline_fast_path_checks else !(is_android || t.os == .Fuchsia);
    if hwasan_cl.has_match_all_tag {
        if hwasan_cl.match_all_tag != -1 { h.has_match_all_tag = true; h.match_all_tag = cast(u64) hwasan_cl.match_all_tag & 0xFF; }
    } else if h.compile_kernel { h.has_match_all_tag = true; h.match_all_tag = 0xFF; }
    h.use_match_all_callback = !h.compile_kernel && h.has_match_all_tag;
    h.instrument_landing_pads = ifx hwasan_cl.has_instrument_landing_pads then hwasan_cl.instrument_landing_pads else !new_runtime;
    h.instrument_globals = !h.compile_kernel && !h.use_page_aliases && (ifx hwasan_cl.has_globals then hwasan_cl.globals else new_runtime);
    if !h.compile_kernel {
        if h.instrument_globals hwasan_instrument_globals(h);
        // createHwasanCtorComdat
        ctor, init, created := get_or_create_sanitizer_ctor_and_init_functions("hwasan.module_ctor", "__hwasan_init", .[], .[], "");
        h.ctor_function = ctor;
        if created {
            glob(ctor).comdat = get_comdat("hwasan.module_ctor");
            append_to_global_ctors(ctor, 0, ctor);
        }
        if !hwasan_cl.static_linking hwasan_create_note(h);
        ipf := ifx hwasan_cl.has_instrument_personality_functions then hwasan_cl.instrument_personality_functions else new_runtime;
        if ipf hwasan_instrument_personality_functions(h);
    }
    if !is_android {
        g := lookup_global("__hwasan_tls");
        if g == NONE || vkind(g) != .GLOBAL_VAR {
            g = gv_create(h.intptr, false, .EXTERNAL, NONE, "__hwasan_tls", NONE, 3, dl.globals_as);
            append_to_compiler_used(g);
        }
        h.thread_ptr_global = g;
    }
}

// initializeCallbacks
hwasan_initialize_callbacks :: (h: *Hwasan) {
    p := type_ptr(0); v := ir.t_void; i8 := ir.t_i8; i32 := ir.t_i32; ip := h.intptr;
    match_all := ifx h.use_match_all_callback then "_match_all" else "";
    sized_p, cb_p, tr_p, ms_p: [..] Type_Id;
    sized_p.allocator = temp; cb_p.allocator = temp; tr_p.allocator = temp; ms_p.allocator = temp;
    array_add(*sized_p, ip, ip); array_add(*cb_p, ip); array_add(*tr_p, p, p, ip); array_add(*ms_p, p, i32, ip);
    if h.use_match_all_callback { array_add(*sized_p, i8); array_add(*cb_p, i8); array_add(*tr_p, i8); array_add(*ms_p, i8); }
    prefix := hwasan_cl.memory_access_callback_prefix;
    for w: 0..1 {
        ts := ifx w then "store" else "load";
        es := ifx h.recover then "_noabort" else "";
        h.access_cb_sized[w] = san_callee(tprint("%1%2N%3%4", prefix, ts, match_all, es), v, sized_p);
        for k: 0..HWASAN_NUMBER_OF_ACCESS_SIZES - 1
            h.access_cb[w][k] = san_callee(tprint("%1%2%3%4%5", prefix, ts, (cast(u64) 1) << cast(u64) k, match_all, es), v, cb_p);
    }
    mi_prefix := ifx h.compile_kernel && !hwasan_cl.kasan_mem_intrin_callback_prefix then "" else prefix;
    h.memmove = san_callee(tprint("%1memmove%2", mi_prefix, match_all), p, tr_p);
    h.memcpy = san_callee(tprint("%1memcpy%2", mi_prefix, match_all), p, tr_p);
    h.memset = san_callee(tprint("%1memset%2", mi_prefix, match_all), p, ms_p);
    h.tag_memory = san_callee("__hwasan_tag_memory", v, .[p, i8, ip]);
    h.generate_tag = san_callee("__hwasan_generate_tag", i8, .[]);
    h.record_frame_record = san_callee("__hwasan_add_frame_record", v, .[ir.t_i64]);
    h.shadow_global = module_get_or_insert_global("__hwasan_shadow", type_array(0, i8));
    h.handle_vfork = san_callee("__hwasan_handle_vfork", v, .[ip]);
}

// getOpaqueNoopCast / getDynamicShadowIfunc / getShadowNonTls
hwasan_opaque_noop_cast :: (b: *Irb, v: Value_Id) -> Value_Id {
    p := type_ptr(0);
    fty := type_func(p, .[vtype(v)], false);
    asm := san_inline_asm(fty, "", "=r,0", false);
    return san_call(b, .{fty, asm}, .[v], ".hwasan.shadow");
}
hwasan_shadow_non_tls :: (h: *Hwasan, b: *Irb) -> Value_Id {
    p := type_ptr(0);
    if h.map_kind == 0 return hwasan_opaque_noop_cast(b, ce_cast(.INTTOPTR, const_int(h.intptr, h.map_offset), p));
    if h.map_kind == 2 return hwasan_opaque_noop_cast(b, h.shadow_global);
    g := module_get_or_insert_global("__hwasan_shadow_memory_dynamic_address", p);
    return irb_load(b, p, g, dl_abi_align(p));
}

// ignoreAccessWithoutRemark (the remarks themselves are not emitted)
hwasan_ignore_access :: (h: *Hwasan, i: Value_Id, ptr: Value_Id) -> bool {
    pt := scalar_type(vtype(ptr));
    if ir.types[pt].a != 0 return true;
    if is_swift_error(ptr) return true;
    if find_alloca_for_value(ptr) != NONE {
        if !h.instrument_stack return true;
        if h.ssi && stack_safety_access_is_safe(h.ssi, i) return true;
    }
    if vkind(get_underlying_object(ptr)) == .GLOBAL_VAR && !h.instrument_globals return true;
    return false;
}

// getInterestingMemoryOperands
hwasan_get_interesting_memory_operands :: (h: *Hwasan, i: Value_Id, t: *Tli, out: *[..] Asan_Mop) {
    if get_metadata(i, md_kind_id("nosanitize")) != NONE return;
    if h.shadow_base == i return;
    o := inst_op(i);
    c := *hwasan_cl;
    if o == .LOAD {
        if !c.instrument_reads || hwasan_ignore_access(h, i, op(i, 0)) return;
        array_add(out, asan_mop(i, 0, false, vtype(i), inst(i).align));
    } else if o == .STORE {
        if !c.instrument_writes || hwasan_ignore_access(h, i, op(i, 1)) return;
        array_add(out, asan_mop(i, 1, true, vtype(op(i, 0)), inst(i).align));
    } else if o == .ATOMICRMW {
        if !c.instrument_atomics || hwasan_ignore_access(h, i, op(i, 0)) return;
        array_add(out, asan_mop(i, 0, true, vtype(op(i, 1)), 0));
    } else if o == .CMPXCHG {
        if !c.instrument_atomics || hwasan_ignore_access(h, i, op(i, 0)) return;
        array_add(out, asan_mop(i, 0, true, vtype(op(i, 1)), 0));
    } else if o == .CALL {
        n := call_arg_count(i);
        if n > 0 for k: 0..n-1 {
            if !c.instrument_byval || !call_is_byval_arg(i, k) || hwasan_ignore_access(h, i, op(i, k)) continue;
            array_add(out, asan_mop(i, k, false, call_param_byval_type(i, k), 1));
        }
        maybe_mark_sanitizer_library_call_no_builtin(i, t);
    }
}

// untagPointer / tagPointer / memToShadow
hwasan_untag_pointer :: (h: *Hwasan, b: *Irb, p: Value_Id) -> Value_Id {
    if h.use_page_aliases fatal("internal: hwasan: untagPointer with page aliases");
    m := h.tag_mask_byte << h.pointer_tag_shift;
    if h.compile_kernel return hwasan_binop_wide_const(b, .OR, p, m);
    return hwasan_binop_wide_const(b, .AND, p, ~m);
}
// IRB.CreateOp(V, ConstantInt::get(V->getType(), C)) with a 64-bit C: when C does not fit the (narrower) type, a
// release build keeps the high bits in the APInt (no implicitTrunc), so the constant is never the canonical
// identity / absorbing value and the operation is not folded unless V is a ConstantInt too.
hwasan_binop_wide_const :: (b: *Irb, opc: Opcode, v: Value_Id, c: u64) -> Value_Id {
    t := vtype(v);
    w := type_int_width(t);
    k := vkind(v);
    if w > 64 return irb_binop(b, opc, v, const_int_words(t, .[c, 0]));   // ConstantInt::get zero-extends a uint64_t
    if w == 64 || (c >> w) == 0 || k == .C_INT return irb_binop(b, opc, v, const_int(t, c));
    // ConstantFoldBinaryInstruction with the non-canonical constant: no identity fold
    if k == .C_POISON return const_poison(t);
    if k == .C_UNDEF return ifx opc == .AND then const_null_value(t) else cf_all_ones(t);
    i := new_inst(opc, t, 2);
    set_op(i, 0, v); set_op(i, 1, const_int(t, c));
    return irb_insert(b, i);
}
hwasan_tag_pointer :: (h: *Hwasan, b: *Irb, ty: Type_Id, p: Value_Id, tag: Value_Id) -> Value_Id {
    if h.use_page_aliases fatal("internal: hwasan: tagPointer with page aliases");
    tagged: Value_Id;
    if h.compile_kernel {
        sh := hwasan_binop_wide_const(b, .OR, irb_binop(b, .SHL, tag, const_int(vtype(tag), h.pointer_tag_shift)), ((cast(u64) 1) << h.pointer_tag_shift) - 1);
        tagged = irb_binop(b, .AND, p, sh);
    } else {
        tagged = irb_binop(b, .OR, p, irb_binop(b, .SHL, tag, const_int(vtype(tag), h.pointer_tag_shift)));
    }
    return irb_cast(b, .INTTOPTR, tagged, ty);
}
hwasan_mem_to_shadow :: (h: *Hwasan, mem: Value_Id, b: *Irb) -> Value_Id {
    sh := irb_binop(b, .LSHR, mem, const_int(vtype(mem), h.map_scale));
    if h.map_kind == 0 && h.map_offset == 0 return irb_cast(b, .INTTOPTR, sh, type_ptr(0));
    return irb_ptr_add(b, h.shadow_base, sh);
}

hwasan_access_info :: (h: *Hwasan, is_write: bool, size_index: u64) -> u64 {
    bi :: (x: bool) -> u64 { return ifx x then cast(u64) 1 else 0; }
    return (bi(h.compile_kernel) << HWAI_COMPILE_KERNEL_SHIFT) | (bi(h.has_match_all_tag) << HWAI_HAS_MATCH_ALL_SHIFT) |
           ((ifx h.has_match_all_tag then h.match_all_tag else 0) << HWAI_MATCH_ALL_SHIFT) | (bi(h.recover) << HWAI_RECOVER_SHIFT) |
           (bi(is_write) << HWAI_IS_WRITE_SHIFT) | (size_index << HWAI_ACCESS_SIZE_SHIFT);
}

// SplitBlockAndInsertIfThen(Cond, SplitBefore, false, Weights, DTU, LI, ThenBlock) with a caller-supplied ThenBlock
sbi_if_then_existing :: (cond: Value_Id, split_before: Value_Id, weights: Md_Id, then_bb: Value_Id) {
    head := inst(split_before).parent;
    tail := split_basic_block(head, split_before, "");
    old := block_terminator(head);
    nt := create_cond_br(cond, then_bb, tail);
    if weights != NONE set_metadata(nt, MDK_PROF, weights);
    replace_inst_with_inst(old, nt);
}

Hwasan_Tag_Check :: struct { term: Value_Id; ptr_long: Value_Id; addr_long: Value_Id; ptr_tag: Value_Id; mem_tag: Value_Id; }

// insertShadowTagCheck
hwasan_insert_shadow_tag_check :: (h: *Hwasan, ptr: Value_Id, before: Value_Id) -> Hwasan_Tag_Check {
    r: Hwasan_Tag_Check;
    b: Irb; irb_set_before(*b, before);
    r.ptr_long = irb_pointer_cast(*b, ptr, h.intptr);
    r.ptr_tag = irb_cast(*b, .TRUNC, irb_binop(*b, .LSHR, r.ptr_long, const_int(h.intptr, h.pointer_tag_shift)), ir.t_i8);
    r.addr_long = hwasan_untag_pointer(h, *b, r.ptr_long);
    sh := hwasan_mem_to_shadow(h, r.addr_long, *b);
    r.mem_tag = irb_load(*b, ir.t_i8, sh, dl_abi_align(ir.t_i8));
    mismatch := irb_icmp(*b, ICMP_NE, r.ptr_tag, r.mem_tag);
    if h.has_match_all_tag {
        not_ignored := irb_icmp(*b, ICMP_NE, r.ptr_tag, const_int(vtype(r.ptr_tag), h.match_all_tag));
        mismatch = irb_binop(*b, .AND, mismatch, not_ignored);
    }
    r.term = sbi_if_then(mismatch, before, false, create_unlikely_branch_weights());
    return r;
}

// instrumentMemAccessInline
hwasan_instrument_mem_access_inline :: (h: *Hwasan, ptr: Value_Id, is_write: bool, size_index: u64, before: Value_Id) {
    if h.use_page_aliases fatal("internal: hwasan: inline checks with page aliases");
    ai := hwasan_access_info(h, is_write, size_index);
    tci := hwasan_insert_shadow_tag_check(h, ptr, before);
    b: Irb; irb_set_before(*b, tci.term);
    oor := irb_icmp(*b, ICMP_UGT, tci.mem_tag, const_int(ir.t_i8, 15));
    fail_term := sbi_if_then(oor, tci.term, !h.recover, create_unlikely_branch_weights());
    irb_set_before(*b, tci.term);
    low := irb_cast(*b, .TRUNC, irb_binop(*b, .AND, tci.ptr_long, const_int(h.intptr, 15)), ir.t_i8);
    low = irb_binop(*b, .ADD, low, const_int(ir.t_i8, ((cast(u64) 1) << size_index) - 1));
    oob := irb_icmp(*b, ICMP_UGE, low, tci.mem_tag);
    sbi_if_then_existing(oob, tci.term, create_unlikely_branch_weights(), inst(fail_term).parent);
    irb_set_before(*b, tci.term);
    ita := irb_binop(*b, .OR, tci.addr_long, const_int(h.intptr, 15));
    ita = irb_cast(*b, .INTTOPTR, ita, type_ptr(0));
    itag := irb_load(*b, ir.t_i8, ita, dl_abi_align(ir.t_i8));
    imm := irb_icmp(*b, ICMP_NE, tci.ptr_tag, itag);
    sbi_if_then_existing(imm, tci.term, create_unlikely_branch_weights(), inst(fail_term).parent);
    irb_set_before(*b, fail_term);
    if !h.is_x86_64 fatal("hwasan: inline checks are only ported for x86-64 (the brk / ebreak traps of AArch64 and RISC-V are not)");
    fty := type_func(ir.t_void, .[vtype(tci.ptr_long)], false);
    asm := san_inline_asm(fty, tconcat("int3\nnopl ", tprint("%", 0x40 + (ai & HWAI_RUNTIME_MASK)), "(%rax)"), "{rdi}", true);
    san_call(*b, .{fty, asm}, .[tci.ptr_long]);
    if h.recover set_successor(fail_term, 0, inst(tci.term).parent);
}

// ignoreMemIntrinsic / instrumentMemIntrinsic
hwasan_ignore_mem_intrinsic :: (h: *Hwasan, mi: Value_Id) -> bool {
    id := call_iid(mi);
    c := *hwasan_cl;
    if id == IID_MEMCPY || id == IID_MEMMOVE || id == IID_MEMCPY_INLINE
        // MemIntrinsic::getDest / getSource strip pointer casts
        return (!c.instrument_writes || hwasan_ignore_access(h, mi, strip_pointer_casts(op(mi, 0)))) &&
               (!c.instrument_reads || hwasan_ignore_access(h, mi, strip_pointer_casts(op(mi, 1))));
    if id == IID_MEMSET || id == IID_MEMSET_INLINE return !c.instrument_writes || hwasan_ignore_access(h, mi, strip_pointer_casts(op(mi, 0)));
    return false;
}
hwasan_instrument_mem_intrinsic :: (h: *Hwasan, mi: Value_Id) {
    b: Irb; irb_set_before(*b, mi);
    id := call_iid(mi);
    if id == IID_MEMCPY || id == IID_MEMMOVE || id == IID_MEMCPY_INLINE {
        args: [..] Value_Id; args.allocator = temp;
        array_add(*args, op(mi, 0), op(mi, 1), irb_int_cast(*b, op(mi, 2), h.intptr, false));
        if h.use_match_all_callback array_add(*args, const_int(ir.t_i8, h.match_all_tag));
        san_call(*b, ifx id == IID_MEMMOVE then h.memmove else h.memcpy, args);
    } else if id == IID_MEMSET || id == IID_MEMSET_INLINE {
        args: [..] Value_Id; args.allocator = temp;
        array_add(*args, op(mi, 0), irb_int_cast(*b, op(mi, 1), ir.t_i32, false), irb_int_cast(*b, op(mi, 2), h.intptr, false));
        if h.use_match_all_callback array_add(*args, const_int(ir.t_i8, h.match_all_tag));
        san_call(*b, h.memset, args);
    }
    erase_inst(mi);
}

// instrumentMemAccess
hwasan_instrument_mem_access :: (h: *Hwasan, o: *Asan_Mop) -> bool {
    addr := op(o.insn, o.opno);
    q: Simplify_Query;
    kb := known_bits(addr, q);
    if ap_is_all_ones(kb.zero) return false;
    if o.mask != NONE return false;
    b: Irb; irb_set_before(*b, o.insn);
    sz := o.store_bits;
    is_pow2 := sz != 0 && (sz & (sz - 1)) == 0;
    if !o.scalable && is_pow2 && sz / 8 <= (cast(u64) 1) << (HWASAN_NUMBER_OF_ACCESS_SIZES - 1) &&
       (o.align == 0 || o.align >= hwasan_obj_align(h) || o.align >= sz / 8) {
        n := sz / 8; idx: u64 = 0; while n > 1 { n >>= 1; idx += 1; }
        if h.instrument_with_calls {
            args: [..] Value_Id; args.allocator = temp;
            array_add(*args, irb_pointer_cast(*b, addr, h.intptr));
            if h.use_match_all_callback array_add(*args, const_int(ir.t_i8, h.match_all_tag));
            san_call(*b, h.access_cb[cast(s64) o.is_write][idx], args);
        } else if h.outlined_checks {
            fatal("hwasan: outlined checks (llvm.hwasan.check.memaccess, AArch64 / RISC-V) are not supported");
        } else hwasan_instrument_mem_access_inline(h, addr, o.is_write, idx, o.insn);
    } else {
        args: [..] Value_Id; args.allocator = temp;
        array_add(*args, irb_pointer_cast(*b, addr, h.intptr));
        array_add(*args, irb_binop(*b, .UDIV, irb_type_size(*b, h.intptr, sz, o.scalable), const_int(h.intptr, 8)));
        if h.use_match_all_callback array_add(*args, const_int(ir.t_i8, h.match_all_tag));
        san_call(*b, h.access_cb_sized[cast(s64) o.is_write], args);
    }
    // untagPointerOperand: nothing on AArch64, x86-64 and RISC-V 64
    t := san_triple();
    if !(t.arch == .aarch64 || t.arch == .aarch64_be || t.arch == .aarch64_32 || h.is_x86_64 || t.arch == .riscv64) {
        ub: Irb; irb_set_before(*ub, o.insn);
        al := irb_pointer_cast(*ub, addr, h.intptr);
        up := irb_cast(*ub, .INTTOPTR, hwasan_untag_pointer(h, *ub, al), vtype(addr));
        set_op(o.insn, o.opno, up);
    }
    return true;
}

// tagAlloca
hwasan_tag_alloca :: (h: *Hwasan, b: *Irb, ai: Value_Id, tag_in: Value_Id, size_in: u64) {
    aligned := hwasan_align_to(size_in, hwasan_obj_align(h));
    size := ifx h.use_short_granules then size_in else aligned;
    tag := irb_cast(b, .TRUNC, tag_in, ir.t_i8);
    p := type_ptr(0);
    if h.instrument_with_calls {
        san_call(b, h.tag_memory, .[irb_pointer_cast(b, ai, p), tag, const_int(h.intptr, aligned)]);
    } else {
        shadow_size := size >> h.map_scale;
        al := hwasan_untag_pointer(h, b, irb_pointer_cast(b, ai, h.intptr));
        sp := hwasan_mem_to_shadow(h, al, b);
        if shadow_size irb_memset(b, sp, tag, const_int(ir.t_i64, shadow_size), 1, false);
        if size != aligned {
            rem := size % hwasan_obj_align(h);
            irb_store(b, const_int(ir.t_i8, rem & 0xFF), irb_gep(b, ir.t_i8, sp, .[const_int(ir.t_i32, shadow_size)]), dl_abi_align(ir.t_i8));
            irb_store(b, tag, irb_gep(b, ir.t_i8, irb_pointer_cast(b, ai, p), .[const_int(ir.t_i32, aligned - 1)]), dl_abi_align(ir.t_i8));
        }
    }
}

// retagMask / applyTagMask / tags
HWASAN_FAST_MASKS :: u64.[0, 128, 64, 192, 32, 96, 224, 112, 240, 48, 16, 120, 248, 56, 24, 8, 124, 252, 60, 28, 12, 4, 126, 254,
                          62, 30, 14, 6, 2, 127, 63, 31, 15, 7, 3, 1];
hwasan_retag_mask :: (h: *Hwasan, n: u64) -> u64 {
    if h.is_x86_64 return n & h.tag_mask_byte;
    return HWASAN_FAST_MASKS[n % HWASAN_FAST_MASKS.count];
}
hwasan_apply_tag_mask :: (h: *Hwasan, b: *Irb, old: Value_Id) -> Value_Id {
    if h.tag_mask_byte == 0xFF return old;
    return irb_binop(b, .AND, old, const_int(vtype(old), h.tag_mask_byte));
}
hwasan_next_tag_with_call :: (h: *Hwasan, b: *Irb) -> Value_Id { return irb_cast(b, .ZEXT, san_call(b, h.generate_tag, .[]), h.intptr); }
hwasan_stack_base_tag :: (h: *Hwasan, b: *Irb) -> Value_Id {
    if hwasan_cl.generate_tags_with_calls return NONE;
    if h.stack_base_tag != NONE return h.stack_base_tag;
    fp := hwasan_cached_fp(h, b);
    st := hwasan_apply_tag_mask(h, b, irb_binop(b, .XOR, fp, irb_binop(b, .LSHR, fp, const_int(vtype(fp), 20))));
    if is_inst(st) set_name(st, "hwasan.stack.base.tag");
    return st;
}
hwasan_alloca_tag :: (h: *Hwasan, b: *Irb, stack_tag: Value_Id, n: u64) -> Value_Id {
    if hwasan_cl.generate_tags_with_calls return hwasan_next_tag_with_call(h, b);
    return irb_binop(b, .XOR, stack_tag, const_int(vtype(stack_tag), hwasan_retag_mask(h, n)));
}
hwasan_uar_tag :: (h: *Hwasan, b: *Irb) -> Value_Id {
    fp := hwasan_cached_fp(h, b);
    t := hwasan_apply_tag_mask(h, b, irb_binop(b, .LSHR, fp, const_int(vtype(fp), h.pointer_tag_shift)));
    if is_inst(t) set_name(t, "hwasan.uar.tag");
    return t;
}
// memtag::getFP / getPC
hwasan_cached_fp :: (h: *Hwasan, b: *Irb) -> Value_Id {
    if h.cached_fp == NONE {
        fa := irb_intrinsic(b, "llvm.frameaddress", .[type_ptr(dl.alloca_as)], .[const_int(ir.t_i32, 0)]);
        h.cached_fp = irb_cast(b, .PTRTOINT, fa, h.intptr);
    }
    return h.cached_fp;
}
hwasan_frame_record_info :: (h: *Hwasan, b: *Irb) -> Value_Id {
    t := san_triple();
    if t.arch == .aarch64 fatal("hwasan: memtag::getPC on AArch64 (read_register pc) is not supported");
    pc := irb_cast(b, .PTRTOINT, block_fn(b.bb), h.intptr);
    fp := hwasan_cached_fp(h, b);
    fp = irb_binop(b, .SHL, fp, const_int(vtype(fp), 44));
    return irb_binop(b, .OR, pc, fp);
}

// memtag::incrementThreadLong
mt_increment_thread_long :: (b: *Irb, tl: Value_Id, inc: u64) -> Value_Id {
    t := vtype(tl);
    wrap := irb_binop(b, .XOR, irb_binop(b, .SHL, irb_binop(b, .ASHR, tl, const_int(t, 56)), const_int(t, 12), "", F_NUW | F_NSW), cf_all_ones(t));
    return irb_binop(b, .AND, irb_binop(b, .ADD, tl, const_int(t, inc)), wrap);
}

// emitPrologue
hwasan_emit_prologue :: (h: *Hwasan, b: *Irb, with_frame_record: bool) {
    t := san_triple();
    if h.map_kind != 3 h.shadow_base = hwasan_shadow_non_tls(h, b);
    if !with_frame_record && h.shadow_base != NONE return;
    slot: Value_Id = NONE; tl: Value_Id = NONE; tlu: Value_Id = NONE;
    is_aarch64 := t.arch == .aarch64 || t.arch == .aarch64_be || t.arch == .aarch64_32;
    get_tlu :: () -> Value_Id #expand {
        if slot == NONE slot = h.thread_ptr_global;
        if tl == NONE tl = irb_load(b, h.intptr, slot, dl_abi_align(h.intptr));
        return ifx is_aarch64 then tl else hwasan_untag_pointer(h, b, tl);
    }
    if with_frame_record {
        if hwasan_cl.record_stack_history == 2 {
            san_call(b, h.record_frame_record, .[hwasan_frame_record_info(h, b)]);
        } else if hwasan_cl.record_stack_history == 1 {
            tlu = get_tlu();
            h.stack_base_tag = irb_binop(b, .ASHR, tl, const_int(h.intptr, 3));
            fri := hwasan_frame_record_info(h, b);
            rp := irb_cast(b, .INTTOPTR, tlu, type_ptr(0));
            irb_store(b, fri, rp, dl_abi_align(vtype(fri)));
            inc := mt_increment_thread_long(b, tl, 8);
            irb_store(b, inc, slot, dl_abi_align(vtype(inc)));
        } else fatal("internal: hwasan: A stack history recording mode should've been selected.");
    }
    if h.shadow_base == NONE {
        if tlu == NONE tlu = get_tlu();
        sb := irb_binop(b, .ADD, irb_binop(b, .OR, tlu, const_int(h.intptr, ((cast(u64) 1) << HWASAN_SHADOW_BASE_ALIGNMENT) - 1)), const_int(h.intptr, 1), "hwasan.shadow");
        h.shadow_base = irb_cast(b, .INTTOPTR, sb, type_ptr(0));
    }
}

// instrumentLandingPads (memtag::readRegister)
hwasan_instrument_landing_pads :: (h: *Hwasan, lps: [] Value_Id) {
    for lp: lps {
        b: Irb; irb_next_node_plain(*b, lp);
        reg := ifx h.is_x86_64 then "rsp" else "sp";
        rr := irb_intrinsic(*b, "llvm.read_register", .[h.intptr], .[md_as_value(md_tuple(.[md_string(reg)], false))]);
        san_call(*b, h.handle_vfork, .[rr]);
    }
}
// IRBuilder<> IRB(I->getNextNode()): the next instruction's position and debug location
irb_next_node_plain :: (b: *Irb, i: Value_Id) { irb_set_before(b, inst(i).next); }

// ---------------------------------------------------------------- memtag:: (MemoryTaggingSupport.cpp)

// StackInfoBuilder::getAllocaInterestingness: 0 uninteresting, 1 safe, 2 interesting
mt_alloca_interestingness :: (h: *Hwasan, ai: Value_Id) -> s64 {
    ok, sz := alloca_allocation_size(ai);
    if ok && !type_is_scalable(inst(ai).ty2) && is_static_alloca(ai) && sz != 0 && !is_alloca_promotable(ai) &&
       (inst(ai).flags & F_INALLOCA) == 0 && !is_swift_error(ai) {
        if !(h.ssi && stack_safety_is_safe(h.ssi, ai)) return 2;
        return 1;
    }
    return 0;
}
mt_info_for :: (si: *Mt_Stack_Info, ai: Value_Id) -> *Mt_Alloca_Info {
    found, k := table_find(*si.index, ai);
    if found return *si.allocas[k];
    a := array_add(*si.allocas);
    a.ai = ai;
    a.lifetime_start.allocator = temp; a.lifetime_end.allocator = temp; a.dbg_records.allocator = temp; a.bb_infos.allocator = temp;
    table_set(*si.index, ai, si.allocas.count - 1);
    return a;
}
// getUntagLocationIfFunctionExit
mt_untag_location_if_function_exit :: (i: Value_Id) -> Value_Id {
    o := inst_op(i);
    if o == .RET {
        ci := block_terminating_must_tail_call(inst(i).parent);
        if ci != NONE return ci;
        return i;
    }
    if o == .RESUME || o == .CLEANUPRET return i;
    return NONE;
}
// StackInfoBuilder::visit
mt_visit :: (h: *Hwasan, si: *Mt_Stack_Info, i: Value_Id) {
    r := inst(i).records;
    locs: [..] Value_Id; locs.allocator = temp;
    while r != 0 {
        rec := dbgr(r);
        if rec.kind != .LABEL {
            add :: (h: *Hwasan, si: *Mt_Stack_Info, v: Value_Id, r: u32) {
                if v == NONE || !is_inst(v) || inst_op(v) != .ALLOCA return;
                if mt_alloca_interestingness(h, v) != 2 return;
                a := mt_info_for(si, v);
                if a.dbg_records.count == 0 || a.dbg_records[a.dbg_records.count - 1] != r array_add(*a.dbg_records, r);
            }
            dbgr_location_ops(r, *locs);
            for locs add(h, si, it, r);
            if rec.kind == .ASSIGN && rec.addr != NONE && ir.mds[rec.addr].kind == .VALUE add(h, si, ir.mds[rec.addr].value, r);
        }
        r = rec.next;
    }
    o := inst_op(i);
    if o == .CALL && call_has_fn_attr(i, .ReturnsTwice) si.calls_return_twice = true;
    if o == .ALLOCA {
        if mt_alloca_interestingness(h, i) == 2 mt_info_for(si, i);
        return;
    }
    if o == .CALL && (call_iid(i) == IID_LIFETIME_START || call_iid(i) == IID_LIFETIME_END) {
        ai := op(i, 0);
        if !is_inst(ai) || inst_op(ai) != .ALLOCA || mt_alloca_interestingness(h, ai) != 2 return;
        a := mt_info_for(si, ai);
        bbi: *Mt_Bb_Info = null;
        for * a.bb_infos if it.bb == inst(i).parent { bbi = it; break; }
        if !bbi { bbi = array_add(*a.bb_infos); bbi.bb = inst(i).parent; bbi.first = NOT_INTRINSIC; bbi.last = NOT_INTRINSIC; }
        id := call_iid(i);
        if id == IID_LIFETIME_START array_add(*a.lifetime_start, i);
        else if bbi.last != IID_LIFETIME_END array_add(*a.lifetime_end, i);
        bbi.last = id;
        if bbi.first == NOT_INTRINSIC bbi.first = id;
        return;
    }
    x := mt_untag_location_if_function_exit(i);
    if x != NONE array_add(*si.ret_vec, x);
}

// isReachableImpl (CFG.cpp) with LoopInfo and an exclusion set, no CycleInfo
cfg_is_reachable_impl :: (worklist_in: [] Value_Id, stop: [] Value_Id, exclusion: [] Value_Id, dt_in: *Dom_Tree, li: *Loop_Info) -> bool {
    dt := dt_in;
    if dt for stop if !dt_is_reachable_from_entry(dt, it) { dt = null; break; }
    if exclusion.count dt = null;
    holes: [..] Loop_Id; holes.allocator = temp;
    if li for exclusion { l := li_loop_for(li, it); if l != NONE { o := li_outermost(li, l); if !array_find(holes, o) array_add(*holes, o); } }
    stop_loops: [..] Loop_Id; stop_loops.allocator = temp;
    if li for stop { l := li_loop_for(li, it); if l != NONE { o := li_outermost(li, l); if !array_find(stop_loops, o) array_add(*stop_loops, o); } }
    worklist: [..] Value_Id; worklist.allocator = temp;
    for worklist_in array_add(*worklist, it);
    visited: Table(Value_Id, bool); visited.allocator = temp;
    limit := CFG_MAX_BBS_TO_EXPLORE;
    while worklist.count {
        bb := pop(*worklist);
        if table_find_pointer(*visited, bb) continue;
        table_set(*visited, bb, true);
        if array_find(stop, bb) return true;
        if array_find(exclusion, bb) continue;
        if dt for stop if dt_dominates(dt, bb, it) return true;
        outer: Loop_Id = NONE;
        if li {
            l := li_loop_for(li, bb);
            if l != NONE outer = li_outermost(li, l);
            if outer != NONE && array_find(holes, outer) outer = NONE;
            else if outer != NONE && array_find(stop_loops, outer) return true;
        }
        limit -= 1;
        if limit == 0 return true;
        if outer != NONE li_exit_blocks(li, outer, *worklist);
        else {
            succs: [..] Value_Id; succs.allocator = temp;
            block_successors(bb, *succs);
            for succs array_add(*worklist, it);
        }
    }
    return false;
}

// memtag::forAllReachableExits; the callback is TagEnd (tag with the UAR tag before the exit)
mt_for_all_reachable_exits :: (h: *Hwasan, dt: *Dom_Tree, pdt: *Dom_Tree, li: *Loop_Info, a: *Mt_Alloca_Info, ret_vec: [] Value_Id, out: *[..] Value_Id) {
    if a.lifetime_end.count == 1 && a.lifetime_start.count == 1 && dt_dominates_post_inst(pdt, a.lifetime_end[0], a.lifetime_start[0]) {
        array_add(out, a.lifetime_end[0]);
        return;
    }
    ends: [..] Value_Id; ends.allocator = temp;
    starts: [..] Value_Id; starts.allocator = temp;
    for a.bb_infos { if it.last == IID_LIFETIME_END array_add(*ends, it.bb); else array_add(*starts, it.bb); }
    if starts.count {
        for ri: ret_vec {
            rb := inst(ri).parent;
            if !array_find(ends, rb) && cfg_is_reachable_impl(starts, .[rb], ends, dt, li) array_add(out, ri);
        }
    }
    for a.lifetime_end array_add(out, it);
}

// memtag::isSupportedLifetime
mt_is_supported_lifetime :: (a: *Mt_Alloca_Info, dt: *Dom_Tree, li: *Loop_Info) -> bool {
    if a.lifetime_start.count == 0 return false;
    last_ends: [..] Value_Id; last_ends.allocator = temp;
    first_ends: [..] Value_Id; first_ends.allocator = temp;
    starts: [..] Value_Id; starts.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    for a.bb_infos {
        if it.last == IID_LIFETIME_END { succs.count = 0; block_successors(it.bb, *succs); for s: succs array_add(*last_ends, s); }
        else if !array_find(starts, it.bb) array_add(*starts, it.bb);
        if it.first == IID_LIFETIME_END && !array_find(first_ends, it.bb) array_add(*first_ends, it.bb);
    }
    if last_ends.count == 0 || first_ends.count == 0 return true;
    return !cfg_is_reachable_impl(last_ends, first_ends, starts, dt, li);
}

// memtag::annotateDebugRecords
mt_annotate_debug_records :: (a: *Mt_Alloca_Info, tag: u64) {
    DW_OP_LLVM_TAG_OFFSET :: 0x1002;
    locs: [..] Value_Id; locs.allocator = temp;
    for r: a.dbg_records {
        new_ops := u64.[DW_OP_LLVM_TAG_OFFSET, tag];
        dbgr_location_ops(r, *locs);
        for v, k: locs if v == a.ai dbgr(r).expr = diexpr_append_ops_to_arg(dbgr(r).expr, new_ops, cast(u64) k, false);
        rec := dbgr(r);
        if rec.kind == .ASSIGN && rec.addr != NONE && ir.mds[rec.addr].kind == .VALUE && ir.mds[rec.addr].value == a.ai {
            ops: [..] u64; ops.allocator = temp;
            array_add(*ops, DW_OP_LLVM_TAG_OFFSET, tag);
            rec.addr_expr = diexpr_prepend_opcodes(rec.addr_expr, *ops, false);
        }
    }
}

// memtag::alignAndPadAlloca
mt_align_and_pad_alloca :: (a: *Mt_Alloca_Info, alignment: u64) {
    ai := a.ai;
    inst(ai).align = max(inst(ai).align, alignment);
    ok, size := alloca_allocation_size(ai);
    aligned := hwasan_align_to(size, alignment);
    if size == aligned return;
    at := inst(ai).ty2;
    n := op(ai, 0);
    if !(vkind(n) == .C_INT && const_int_zext(n) == 1) at = type_array(const_int_zext(n), at);   // isArrayAllocation
    pad := type_array(aligned - size, ir.t_i8);
    twp := type_literal_struct(.[at, pad], false);
    na := new_inst(.ALLOCA, vtype(ai), 1);
    inst(na).ty2 = twp;
    inst(na).addrspace = inst(ai).addrspace;
    set_op(na, 0, const_int(ir.t_i32, 1));
    insert_at_position(na, inst(ai).parent, ai, false);
    take_name(na, ai);
    inst(na).align = inst(ai).align;
    inst(na).flags |= inst(ai).flags & F_INALLOCA;
    if is_swift_error(ai) inst(na).flags |= inst(ai).flags & F_SWIFTERROR;
    copy_metadata(na, ai);
    rauw_with_metadata(ai, na);
    erase_inst(ai);
    a.ai = na;
}

// ---------------------------------------------------------------- instrumentStack

hwasan_instrument_stack :: (h: *Hwasan, si: *Mt_Stack_Info, stack_tag: Value_Id, uar_tag: Value_Id, dt: *Dom_Tree, pdt: *Dom_Tree, li: *Loop_Info) {
    for * a, n: si.allocas {
        ai := a.ai;
        b: Irb; irb_next_node_plain(*b, ai);
        tag := hwasan_alloca_tag(h, *b, stack_tag, cast(u64) n);
        ai_long := irb_pointer_cast(*b, ai, h.intptr);
        no_tag := hwasan_untag_pointer(h, *b, ai_long);
        repl := hwasan_tag_pointer(h, *b, vtype(ai), no_tag, tag);
        nm := ifx vname(ai).count then vname(ai) else tprint("alloca.%", n);
        set_name(repl, tconcat(nm, ".hwasan"));
        _, size := alloca_allocation_size(ai);
        aligned := hwasan_align_to(size, hwasan_obj_align(h));
        // AI->replaceUsesWithIf(Replacement, User != AILong && !isa<LifetimeIntrinsic>(User)): real uses only
        u := ir.v_first_use[ai];
        while u != NONE {
            nx := ir.u_next[u];
            usr := ir.u_user[u];
            if usr != ai_long && !(is_inst(usr) && inst_op(usr) == .CALL && (call_iid(usr) == IID_LIFETIME_START || call_iid(usr) == IID_LIFETIME_END))
                use_set(u, repl);
            u = nx;
        }
        mt_annotate_debug_records(a, hwasan_retag_mask(h, cast(u64) n));
        tag_starts :: () #expand {
            for s: a.lifetime_start { irb_next_node_plain(*b, s); hwasan_tag_alloca(h, *b, ai, tag, size); }
        }
        tag_end :: (node: Value_Id) #expand { irb_set_before(*b, node); hwasan_tag_alloca(h, *b, ai, uar_tag, aligned); }
        erase_lifetimes :: () #expand {
            for a.lifetime_start erase_inst(it);
            for a.lifetime_end erase_inst(it);
        }
        if h.detect_use_after_scope && !si.calls_return_twice && mt_is_supported_lifetime(a, dt, li) {
            tag_starts();
            exits: [..] Value_Id; exits.allocator = temp;
            mt_for_all_reachable_exits(h, dt, pdt, li, a, si.ret_vec, *exits);
            for exits tag_end(it);
        } else if h.detect_use_after_scope && hwasan_cl.strict_use_after_scope {
            hwasan_tag_alloca(h, *b, ai, tag, size);
            tag_starts();
            for a.lifetime_end tag_end(it);
            for si.ret_vec tag_end(it);
            erase_lifetimes();
        } else {
            hwasan_tag_alloca(h, *b, ai, tag, size);
            for si.ret_vec tag_end(it);
            erase_lifetimes();
        }
        mt_align_and_pad_alloca(a, hwasan_obj_align(h));
    }
}

// selectiveInstrumentationShouldSkip
hwasan_should_skip :: (h: *Hwasan, f: Value_Id) -> bool {
    if hwasan_cl.has_random_keep_rate fatal("hwasan: -hwasan-random-rate (Module::createRNG) is not supported");
    if !hwasan_cl.has_hot_percentile_cutoff return false;
    p := psi_cached_or_null();
    if !p || !p.has_summary return false;
    // isFunctionHotInCallGraphNthPercentile
    bfi := get_bfi(f);
    cut := hwasan_cl.hot_percentile_cutoff;
    ok, c := function_entry_count(f);
    if ok && psi_is_hot_count_nth_percentile(p, cut, c) return true;
    ok2, tc := psi_total_call_count(p, f);
    if ok2 && psi_is_hot_count_nth_percentile(p, cut, tc) return true;
    for bb: fn_blocks(f) { okb, cb := bfi_block_profile_count(bfi, bb); if okb && psi_is_hot_count_nth_percentile(p, cut, cb) return true; }
    return false;
}

// sanitizeFunction
hwasan_sanitize_function :: (h: *Hwasan, f: Value_Id) {
    if f == h.ctor_function return;
    if fn_has_fn_attr(f, .Naked) || !fn_has_fn_attr(f, .SanitizeHWAddress) || is_declaration(f) return;
    if fn_has_fn_attr(f, .PresplitCoroutine) return;
    if hwasan_should_skip(h, f) return;
    ops: [..] Asan_Mop; ops.allocator = temp;
    intrins: [..] Value_Id; intrins.allocator = temp;
    lps: [..] Value_Id; lps.allocator = temp;
    t := tli_for(f);
    si: Mt_Stack_Info;
    si.allocas.allocator = temp; si.index.allocator = temp; si.ret_vec.allocator = temp;
    for i: fn_insts(f) {
        if h.instrument_stack mt_visit(h, *si, i);
        if h.instrument_landing_pads && inst_op(i) == .LANDINGPAD array_add(*lps, i);
        hwasan_get_interesting_memory_operands(h, i, t, *ops);
        if inst_op(i) == .CALL && asan_is_mem_intrinsic(i) && !hwasan_ignore_mem_intrinsic(h, i) array_add(*intrins, i);
    }
    hwasan_initialize_callbacks(h);
    if lps.count hwasan_instrument_landing_pads(h, lps);
    if si.allocas.count == 0 && glob(f).has_personality && vname(fn_personality(f)) == "__hwasan_personality_thunk" {
        set_op(f, 0, const_null_value(type_ptr(0)));
        glob(f).has_personality = false;
    }
    if si.allocas.count == 0 && ops.count == 0 && intrins.count == 0 return;
    entry := fn_entry(f);
    eb: Irb; irb_set_at(*eb, entry, block(entry).first, true);
    hwasan_emit_prologue(h, *eb, hwasan_cl.record_stack_history != 0 && h.map_with_frame_record && si.allocas.count != 0);
    if si.allocas.count {
        dt := get_domtree(f);
        pdt := get_postdomtree(f);
        li := get_loop_info(f);
        st := hwasan_stack_base_tag(h, *eb);
        ut := hwasan_uar_tag(h, *eb);
        hwasan_instrument_stack(h, *si, st, ut, dt, pdt, li);
    }
    if eb.bb != fn_entry(f) fatal("internal: hwasan: the entry block changed");
    for * ops hwasan_instrument_mem_access(h, it);
    if hwasan_cl.instrument_mem_intrinsics for intrins hwasan_instrument_mem_intrinsic(h, it);
    fam_invalidate(f, PRESERVE_NONE);   // LLVM keeps DT/PDT/LoopInfo up to date (DomTreeUpdater); here they are dropped
    h.shadow_base = NONE; h.stack_base_tag = NONE; h.cached_fp = NONE;
}

// ---------------------------------------------------------------- globals and personality functions

// instrumentGlobal
hwasan_instrument_global :: (h: *Hwasan, gv: Value_Id, tag: u64) {
    init := gv_initializer(gv);
    size := dl_type_alloc_size(vtype(init));
    new_size := hwasan_align_to(size, hwasan_obj_align(h));
    if size != new_size {
        elts := NewArray(cast(s64)(new_size - size), u64,, temp);
        elts[elts.count - 1] = tag;
        padding := const_data(type_array(cast(u64) elts.count, ir.t_i8), elts);
        st := type_literal_struct(.[vtype(init), vtype(padding)], false);
        init = const_aggregate(.C_STRUCT, st, .[init, padding]);
    }
    ng := gv_create(vtype(init), glob(gv).is_const, .EXTERNAL, init, tconcat(vname(gv), ".hwasan"), NONE, 0, dl.globals_as);
    gv_copy_attributes_from(ng, gv);
    gv_set_linkage(ng, .PRIVATE);
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(gv, *all);
    for all add_metadata(ng, it.kind, it.md);
    glob(ng).align = max(max(glob(gv).align, cast(u64) 1), hwasan_obj_align(h));
    glob(ng).unnamed_addr = 0;
    i32 := ir.t_i32; i64 := ir.t_i64;
    dty := type_literal_struct(.[i32, i32], false);
    MAX_DESCRIPTOR_SIZE :: cast(u64) 0xfffff0;
    pos: u64 = 0;
    while pos < size {
        d := gv_create(dty, true, .PRIVATE, NONE, tconcat(vname(gv), ".hwasan.descriptor"), NONE, 0, dl.globals_as);
        rel := ce_cast(.TRUNC, ce_binop(.ADD, ce_binop(.SUB, ce_cast(.PTRTOINT, ng, i64), ce_cast(.PTRTOINT, d, i64), 0), const_int(i64, pos), 0), i32);
        sz := min(size - pos, MAX_DESCRIPTOR_SIZE);
        sat := const_int(i32, (sz | (tag << 24)) & 0xFFFF_FFFF);
        glob(d).comdat = glob(ng).comdat;
        gv_set_initializer(d, const_aggregate(.C_STRUCT, dty, .[rel, sat]));
        glob(d).section = "hwasan_globals";
        set_metadata(d, md_kind_id("associated"), md_tuple(.[md_value(ng)], false));
        append_to_compiler_used(d);
        pos += MAX_DESCRIPTOR_SIZE;
    }
    aliasee := ce_cast(.INTTOPTR, ce_binop(.ADD, ce_cast(.PTRTOINT, ng, i64), const_int(i64, tag << h.pointer_tag_shift), 0), vtype(gv));
    ga := new_global(.ALIAS, glob(gv).value_type, glob(gv).addrspace, 1);
    set_op(ga, 0, aliasee);
    gv_set_linkage(ga, glob(gv).linkage);
    array_add(*ir.m_aliases, ga);
    glob(ga).visibility = glob(gv).visibility;
    gv_take_name(ga, gv);
    ipo_rauw(gv, ga);
    gv_erase_from_parent(gv);
}

// instrumentGlobals
hwasan_instrument_globals :: (h: *Hwasan) {
    globals: [..] Value_Id; globals.allocator = temp;
    for g: ir.m_globals {
        if vkind(g) != .GLOBAL_VAR continue;
        if (glob(g).sanitizer & 2) != 0 continue;
        if gv_is_declaration_for_linker(g) || begins_with(vname(g), "llvm.") || glob(g).tls != 0 continue;
        if glob(g).linkage == .COMMON continue;
        if hwasan_cl.all_globals { if glob(g).section == "llvm.metadata" continue; }
        else if glob(g).section.count continue;
        array_add(*globals, g);
    }
    m: Md5;
    md5_update_str(*m, ir.source_filename);
    hash := md5_final(*m);
    tag := cast(u64) hash[0];
    if h.tag_mask_byte < 16 fatal("internal: hwasan: TagMaskByte < 16");
    for g: globals {
        if tag < 16 || tag > h.tag_mask_byte tag = 16;
        hwasan_instrument_global(h, g, tag & 0xFF);
        tag = (tag + 1) & 0xFF;
    }
}

// instrumentPersonalityFunctions
hwasan_instrument_personality_functions :: (h: *Hwasan) {
    Entry :: struct { key: Value_Id; fns: [..] Value_Id; }
    pfs: [..] Entry; pfs.allocator = temp;
    add :: (pfs: *[..] Entry, key: Value_Id, f: Value_Id) {
        for * pfs.* if it.key == key { array_add(*it.fns, f); return; }
        e := array_add(pfs); e.key = key; e.fns.allocator = temp; array_add(*e.fns, f);
    }
    for f: ir.m_functions {
        if is_declaration(f) || !fn_has_fn_attr(f, .SanitizeHWAddress) continue;
        if glob(f).has_personality add(*pfs, strip_pointer_casts(fn_personality(f)), f);
        else if !fn_has_fn_attr(f, .NoUnwind) add(*pfs, NONE, f);
    }
    if pfs.count == 0 return;
    p := type_ptr(0); i32 := ir.t_i32; i64 := ir.t_i64;
    wrapper := san_callee("__hwasan_personality_wrapper", i32, .[i32, i32, i64, p, p, p, p, p]);
    get_gr := san_callee("_Unwind_GetGR", ir.t_void, .[]);
    get_cfa := san_callee("_Unwind_GetCFA", ir.t_void, .[]);
    for e: pfs {
        name := "__hwasan_personality_thunk";
        if e.key != NONE name = tconcat(name, ".", vname(e.key));
        fty := type_func(i32, .[i32, i32, i64, p, p], false);
        is_local := e.key != NONE && (!is_global_value(vkind(e.key)) || gv_has_local_linkage(e.key));
        thunk := new_function(fty, name, dl.program_as);
        array_add(*ir.m_functions, thunk);
        gv_set_linkage(thunk, ifx is_local then Linkage.INTERNAL else .LINKONCE_ODR);
        bte := false;
        for f: e.fns if fn_find_str_attr(f, "branch-target-enforcement") != null bte = true;
        if bte fn_add_fn_str_attr(thunk, "branch-target-enforcement", "");
        if !is_local {
            glob(thunk).visibility = 1;
            glob(thunk).comdat = get_comdat(name);
        }
        bb := create_block(thunk, "entry");
        b: Irb; irb_set_end(*b, bb);
        pers := ifx e.key != NONE then e.key else const_null_value(p);
        wc := san_call(*b, wrapper, .[fn_arg(thunk, 0), fn_arg(thunk, 1), fn_arg(thunk, 2), fn_arg(thunk, 3), fn_arg(thunk, 4), pers, get_gr.callee, get_cfa.callee]);
        call_set_tail_kind(wc, TCK_TAIL);
        ret := new_inst(.RET, ir.t_void, 1); set_op(ret, 0, wc); irb_insert(*b, ret);
        for f: e.fns { set_op(f, 0, thunk); glob(f).has_personality = true; }
    }
}

// HWAddressSanitizerPass::run
hwasan_run :: (name: string) -> Preserved {
    compile_kernel := false; recover := false;
    if name != "hwasan" {
        params := slice(name, 7, name.count - 8);
        for p: split(params, ";",, temp) {
            if p.count == 0 continue;
            if p == "recover" recover = true;
            else if p == "kernel" compile_kernel = true;
            else fatal("invalid HWAddressSanitizer pass parameter '%'", p);
        }
    }
    if check_if_already_instrumented("nosanitize_hwaddress") return PRESERVE_ALL;
    h: Hwasan;
    t := san_triple();
    h.is_x86_64 = t.arch == .x86_64;
    pages := hwasan_cl.use_page_aliases && h.is_x86_64;
    instrument_stack := !pages && hwasan_cl.instrument_stack;
    ss: Stack_Safety_Global;
    if instrument_stack && (ifx hwasan_cl.has_use_stack_safety then hwasan_cl.use_stack_safety else true) {
        stack_safety_global_init(*ss);
        h.ssi = *ss;
    }
    h.recover = ifx hwasan_cl.has_recover then hwasan_cl.recover else recover;
    h.compile_kernel = ifx hwasan_cl.has_enable_khwasan then hwasan_cl.enable_khwasan else compile_kernel;
    hwasan_initialize_module(*h);
    fns: [..] Value_Id; fns.allocator = temp;
    for ir.m_functions array_add(*fns, it);
    for f: fns hwasan_sanitize_function(*h, f);
    printer_note_ir_changed();
    pa := PRESERVE_NONE;
    pa.abandon_globals_aa = true;
    return pa;
}
