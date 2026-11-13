// AddressSanitizer: a port of llvm/lib/Transforms/Instrumentation/AddressSanitizer.cpp (AddressSanitizerPass::run,
// AddressSanitizer = `Asan`, ModuleAddressSanitizer = `Asan_Module`, FunctionStackPoisoner = `Asan_Fsp`,
// RuntimeCallInserter = the `rtci_*` fields of Asan, getShadowMapping, all cl::opts), with the stack layout of
// llvm/lib/Transforms/Utils/ASanStackFrameLayout.cpp (sanitizer_common.jai) and StackSafetyGlobalInfo from
// stack_safety.jai. Only x86-64 (and no-triple) modules are supported; the AMDGPU, MachO, COFF and Windows
// catch-parameter paths fail loudly. -asan-debug* options are accepted but print nothing.

ASAN_K_DEFAULT_SHADOW_SCALE :: 3;
ASAN_K_DYNAMIC_SHADOW_SENTINEL :: 0xFFFF_FFFF_FFFF_FFFF;
ASAN_K_MIN_STACK_MALLOC_SIZE :: 1 << 6;
ASAN_K_MAX_STACK_MALLOC_SIZE :: 1 << 16;
ASAN_K_CURRENT_STACK_FRAME_MAGIC :: 0x41B58AB3;
ASAN_K_RETIRED_STACK_FRAME_MAGIC :: 0x45E0360E;
ASAN_K_MAX_STACK_MALLOC_SIZE_CLASS :: 10;
ASAN_K_ALLOCA_RZ_SIZE :: 32;
ASAN_K_NUMBER_OF_ACCESS_SIZES :: 5;
ASAN_GEN_PREFIX :: "___asan_gen_";

Asan_Uar :: enum u8 { NEVER; RUNTIME; ALWAYS; }
Asan_Ctor_Kind :: enum u8 { NONE; GLOBAL; }
Asan_Dtor_Kind :: enum u8 { NONE; GLOBAL; INVALID; }

// cl::opts of AddressSanitizer.cpp; `*_set` = getNumOccurrences() > 0
asan_cl: struct {
    kasan: bool; kasan_set: bool;
    recover: bool; recover_set: bool;
    insert_version_check := true; insert_version_check_set: bool;
    instrument_reads := true;
    instrument_writes := true;
    use_stack_safety := true;
    instrument_atomics := true;
    instrument_byval := true;
    always_slow_path: bool;
    force_dynamic_shadow: bool;
    with_ifunc := true;
    shadow_addr_space: s64;
    with_ifunc_suppress_remat := true;
    max_insns_per_bb: s64 = 10000;
    stack := true;
    max_inline_poisoning_size: s64 = 64; max_inline_poisoning_size_set: bool;
    use_after_return := Asan_Uar.RUNTIME; use_after_return_set: bool;
    redzone_byval_args := true;
    use_after_scope: bool;
    globals := true;
    initializers := true;
    invalid_pointer_pairs: bool;
    invalid_pointer_cmp: bool;
    invalid_pointer_sub: bool;
    realign_stack: u64 = 32;
    calls_threshold: s64 = 7000; calls_threshold_set: bool;
    memory_access_callback_prefix := "__asan_";
    kasan_mem_intrin_callback_prefix: bool;
    instrument_dynamic_allocas := true;
    skip_promotable_allocas := true;
    constructor_kind := Asan_Ctor_Kind.GLOBAL; constructor_kind_set: bool;
    mapping_scale: s64; mapping_scale_set: bool;
    mapping_offset: u64; mapping_offset_set: bool;
    opt := true;
    optimize_callbacks: bool;
    opt_same_temp := true;
    opt_globals := true;
    opt_stack: bool;
    dynamic_alloca_stack := true;
    force_experiment: u64;
    use_private_alias := true; use_private_alias_set: bool;
    use_odr_indicator := true; use_odr_indicator_set: bool;
    use_globals_gc := true;
    with_comdat := true;
    override_destructor_kind := Asan_Dtor_Kind.INVALID;
    addr_spaces: [..] u64;
    debug: s64; debug_stack: s64; debug_func: string; debug_min: s64 = -1; debug_max: s64 = -1;
};

asan_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
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
    pu :: (name: string, value: string, has_value: bool) -> u64 {
        if !has_value fatal("opt: for the --% option: requires a value!", name);
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
    o := *asan_cl;
    if name == {
        case "asan-kernel"; o.kasan = pb(name, value, has_value); o.kasan_set = true;
        case "asan-recover"; o.recover = pb(name, value, has_value); o.recover_set = true;
        case "asan-guard-against-version-mismatch"; o.insert_version_check = pb(name, value, has_value); o.insert_version_check_set = true;
        case "asan-instrument-reads"; o.instrument_reads = pb(name, value, has_value);
        case "asan-instrument-writes"; o.instrument_writes = pb(name, value, has_value);
        case "asan-use-stack-safety"; o.use_stack_safety = pb(name, value, has_value);
        case "asan-instrument-atomics"; o.instrument_atomics = pb(name, value, has_value);
        case "asan-instrument-byval"; o.instrument_byval = pb(name, value, has_value);
        case "asan-always-slow-path"; o.always_slow_path = pb(name, value, has_value);
        case "asan-force-dynamic-shadow"; o.force_dynamic_shadow = pb(name, value, has_value);
        case "asan-with-ifunc"; o.with_ifunc = pb(name, value, has_value);
        case "asan-shadow-addr-space"; o.shadow_addr_space = pi(name, value, has_value);
        case "asan-with-ifunc-suppress-remat"; o.with_ifunc_suppress_remat = pb(name, value, has_value);
        case "asan-max-ins-per-bb"; o.max_insns_per_bb = pi(name, value, has_value);
        case "asan-stack"; o.stack = pb(name, value, has_value);
        case "asan-max-inline-poisoning-size"; o.max_inline_poisoning_size = cast(s64) pu(name, value, has_value); o.max_inline_poisoning_size_set = true;
        case "asan-use-after-return";
            if value == "never" o.use_after_return = .NEVER;
            else if value == "runtime" o.use_after_return = .RUNTIME;
            else if value == "always" o.use_after_return = .ALWAYS;
            else fatal("opt: for the --asan-use-after-return option: Cannot find option named '%'!", value);
            o.use_after_return_set = true;
        case "asan-redzone-byval-args"; o.redzone_byval_args = pb(name, value, has_value);
        case "asan-use-after-scope"; o.use_after_scope = pb(name, value, has_value);
        case "asan-globals"; o.globals = pb(name, value, has_value);
        case "asan-initialization-order"; o.initializers = pb(name, value, has_value);
        case "asan-detect-invalid-pointer-pair"; o.invalid_pointer_pairs = pb(name, value, has_value);
        case "asan-detect-invalid-pointer-cmp"; o.invalid_pointer_cmp = pb(name, value, has_value);
        case "asan-detect-invalid-pointer-sub"; o.invalid_pointer_sub = pb(name, value, has_value);
        case "asan-realign-stack"; o.realign_stack = pu(name, value, has_value);
        case "asan-instrumentation-with-call-threshold"; o.calls_threshold = pi(name, value, has_value); o.calls_threshold_set = true;
        case "asan-memory-access-callback-prefix"; o.memory_access_callback_prefix = copy_string(value);
        case "asan-kernel-mem-intrinsic-prefix"; o.kasan_mem_intrin_callback_prefix = pb(name, value, has_value);
        case "asan-instrument-dynamic-allocas"; o.instrument_dynamic_allocas = pb(name, value, has_value);
        case "asan-skip-promotable-allocas"; o.skip_promotable_allocas = pb(name, value, has_value);
        case "asan-constructor-kind";
            if value == "none" o.constructor_kind = .NONE;
            else if value == "global" o.constructor_kind = .GLOBAL;
            else fatal("opt: for the --asan-constructor-kind option: Cannot find option named '%'!", value);
            o.constructor_kind_set = true;
        case "asan-mapping-scale"; o.mapping_scale = pi(name, value, has_value); o.mapping_scale_set = true;
        case "asan-mapping-offset"; o.mapping_offset = pu(name, value, has_value); o.mapping_offset_set = true;
        case "asan-opt"; o.opt = pb(name, value, has_value);
        case "asan-optimize-callbacks"; o.optimize_callbacks = pb(name, value, has_value);
        case "asan-opt-same-temp"; o.opt_same_temp = pb(name, value, has_value);
        case "asan-opt-globals"; o.opt_globals = pb(name, value, has_value);
        case "asan-opt-stack"; o.opt_stack = pb(name, value, has_value);
        case "asan-stack-dynamic-alloca"; o.dynamic_alloca_stack = pb(name, value, has_value);
        case "asan-force-experiment"; o.force_experiment = pu(name, value, has_value);
        case "asan-use-private-alias"; o.use_private_alias = pb(name, value, has_value); o.use_private_alias_set = true;
        case "asan-use-odr-indicator"; o.use_odr_indicator = pb(name, value, has_value); o.use_odr_indicator_set = true;
        case "asan-globals-live-support"; o.use_globals_gc = pb(name, value, has_value);
        case "asan-with-comdat"; o.with_comdat = pb(name, value, has_value);
        case "asan-destructor-kind";
            if value == "none" o.override_destructor_kind = .NONE;
            else if value == "global" o.override_destructor_kind = .GLOBAL;
            else fatal("opt: for the --asan-destructor-kind option: Cannot find option named '%'!", value);
        case "asan-instrument-address-spaces";
            for p: split(value, ",",, temp) array_add(*o.addr_spaces, pu(name, p, true));
        case "asan-debug"; o.debug = pi(name, value, has_value);
        case "asan-debug-stack"; o.debug_stack = pi(name, value, has_value);
        case "asan-debug-func"; o.debug_func = copy_string(value);
        case "asan-debug-min"; o.debug_min = pi(name, value, has_value);
        case "asan-debug-max"; o.debug_max = pi(name, value, has_value);
        case "ignore-redundant-instrumentation"; san_opts.ignore_redundant_instrumentation = pb(name, value, has_value);
        case; return false;
    }
    return true;
}

// ---------------------------------------------------------------- shadow mapping

Asan_Mapping :: struct { scale: s64; offset: u64; or_shadow_offset: bool; in_global: bool; }

// getShadowMapping(TargetTriple, LongSize, IsKasan)
asan_get_shadow_mapping :: (long_size: u64, is_kasan: bool) -> Asan_Mapping {
    t := san_triple();
    tt := *t;
    is_android := t.env == .Android;
    is_ios := triple_is_ios(tt) || t.os == .WatchOS || t.os == .DriverKit;
    is_macos := triple_is_macosx(tt);
    is_freebsd := t.os == .FreeBSD;
    is_netbsd := t.os == .NetBSD;
    is_ps := t.os == .PS4 || t.os == .PS5;
    is_linux := t.os == .Linux;
    a := t.arch;
    is_ppc64 := a == .ppc64 || a == .ppc64le;
    is_systemz := a == .systemz;
    is_x86_64 := a == .x86_64;
    is_mips_n32 := (a == .mips64 || a == .mips64el) && (t.env == .GNUABIN32 || t.env == .MuslABIN32);
    is_mips32 := a == .mips || a == .mipsel;
    is_mips64 := a == .mips64 || a == .mips64el;
    is_arm_or_thumb := a == .arm || a == .armeb || a == .thumb || a == .thumbeb;
    is_aarch64 := a == .aarch64 || a == .aarch64_be;
    is_loongarch64 := a == .loongarch64;
    is_riscv64 := a == .riscv64;
    is_windows := t.os == .Win32;
    is_fuchsia := t.os == .Fuchsia;
    is_amdgpu := a == .amdgpu || a == .r600;
    is_haiku := t.os == .Haiku;
    is_wasm := a == .wasm32 || a == .wasm64;
    is_bpf := a == .bpfel || a == .bpfeb;
    m: Asan_Mapping;
    m.scale = ASAN_K_DEFAULT_SHADOW_SCALE;
    if asan_cl.mapping_scale_set m.scale = asan_cl.mapping_scale;
    small_x86_64 := 0x7FFFFFFF & (~(cast(u64) 0xFFF) << cast(u64) m.scale);
    if long_size == 32 {
        if is_android m.offset = ASAN_K_DYNAMIC_SHADOW_SENTINEL;
        else if is_mips_n32 m.offset = 1 << 29;
        else if is_mips32 m.offset = 0x0aaa0000;
        else if is_freebsd m.offset = 1 << 30;
        else if is_netbsd m.offset = 1 << 30;
        else if is_ios m.offset = ASAN_K_DYNAMIC_SHADOW_SENTINEL;
        else if is_windows m.offset = 3 << 28;
        else if is_wasm m.offset = 0;
        else m.offset = 1 << 29;
    } else {
        if is_fuchsia m.offset = ASAN_K_DYNAMIC_SHADOW_SENTINEL;
        else if is_ppc64 m.offset = 1 << 44;
        else if is_systemz m.offset = 1 << 52;
        else if is_freebsd && is_aarch64 m.offset = 1 << 47;
        else if is_freebsd && !is_mips64 m.offset = ifx is_kasan then cast(u64) 0xdffff7c000000000 else 1 << 46;
        else if is_netbsd m.offset = ifx is_kasan then cast(u64) 0xdfff900000000000 else 1 << 46;
        else if is_ps m.offset = 1 << 40;
        else if is_linux && is_x86_64 m.offset = ifx is_kasan then cast(u64) 0xdffffc0000000000 else small_x86_64;
        else if is_windows && (is_x86_64 || is_aarch64) m.offset = ASAN_K_DYNAMIC_SHADOW_SENTINEL;
        else if is_mips64 m.offset = 1 << 37;
        else if is_ios m.offset = ASAN_K_DYNAMIC_SHADOW_SENTINEL;
        else if is_macos && is_aarch64 m.offset = ASAN_K_DYNAMIC_SHADOW_SENTINEL;
        else if is_aarch64 m.offset = 1 << 36;
        else if is_loongarch64 m.offset = 1 << 46;
        else if is_riscv64 m.offset = ASAN_K_DYNAMIC_SHADOW_SENTINEL;
        else if is_amdgpu m.offset = small_x86_64;
        else if is_haiku && is_x86_64 m.offset = small_x86_64;
        else if is_bpf m.offset = ASAN_K_DYNAMIC_SHADOW_SENTINEL;
        else if is_wasm m.offset = 0;
        else m.offset = 1 << 44;
    }
    if asan_cl.force_dynamic_shadow m.offset = ASAN_K_DYNAMIC_SHADOW_SENTINEL;
    if asan_cl.mapping_offset_set m.offset = asan_cl.mapping_offset;
    m.or_shadow_offset = !is_aarch64 && !is_ppc64 && !is_systemz && !is_ps && !is_riscv64 && !is_loongarch64 &&
                         (m.offset & (m.offset - 1)) == 0 && m.offset != ASAN_K_DYNAMIC_SHADOW_SENTINEL;
    m.in_global = asan_cl.with_ifunc && is_android && is_arm_or_thumb;
    if m.in_global fatal("asan: the ifunc shadow global (Android ARM) is not supported");
    return m;
}

// removeASanIncompatibleFnAttributes(F, ReadsArgMem)
remove_asan_incompatible_fn_attributes :: (f: Value_Id, reads_arg_mem: bool) {
    changed := false;
    me := fn_memory_effects(f);
    if !mem_does_not_access(me_without_loc(me, LOC_INACCESSIBLE)) && me_get(me, LOC_OTHER) != MR_MODREF {
        fn_set_memory_effects(f, me | me_loc(LOC_OTHER, MR_MODREF));
        changed = true;
    }
    if reads_arg_mem {
        me = fn_memory_effects(f);
        if me_get(me, LOC_ARG) == MR_MOD {
            fn_set_memory_effects(f, me | me_loc(LOC_ARG, MR_REF));
            changed = true;
        }
        for k: 0..cast(s64) glob(f).nargs - 1 {
            if fn_has_param_attr(f, cast(u32) k, .WriteOnly) {
                l := glob(f).attrs;
                fn_set_attr_list(f, attr_list_with_param(l, cast(u32) k, attr_set_remove(attr_list_param(l, cast(u32) k), .WriteOnly)));
                changed = true;
            }
        }
    }
    if changed fn_add_fn_attr_kind(f, .NoBuiltin);
}

asan_redzone_size_for_scale :: (scale: s64) -> u64 { return max(cast(u64) 32, (cast(u64) 1) << cast(u64) scale); }

// ---------------------------------------------------------------- the function sanitizer

Asan_Mop :: struct {   // InterestingMemoryOperand
    insn: Value_Id;
    opno: u32;
    is_write: bool;
    op_type: Type_Id;
    store_bits: u64;      // TypeStoreSize (bits)
    scalable: bool;       // TypeStoreSize.isScalable()
    align: u64;           // 0 = MaybeAlign() unset
    mask: Value_Id = NONE;
    evl: Value_Id = NONE;
    stride: Value_Id = NONE;
    byte_offset: Value_Id = NONE;
}
asan_mop :: (i: Value_Id, opno: u32, is_write: bool, ty: Type_Id, align: u64, mask: Value_Id = NONE, evl: Value_Id = NONE, stride: Value_Id = NONE) -> Asan_Mop {
    m: Asan_Mop;
    m.insn = i; m.opno = opno; m.is_write = is_write; m.op_type = ty; m.align = align;
    m.mask = mask; m.evl = evl; m.stride = stride;
    m.store_bits = dl_type_store_size(ty) * 8;
    m.scalable = type_is_scalable(ty);
    if m.scalable m.store_bits = san_scalable_min_store_bits(ty);
    return m;
}
asan_mop_ptr :: (m: *Asan_Mop) -> Value_Id { return op(m.insn, m.opno); }

// DataLayout::getTypeStoreSizeInBits(Ty).getKnownMinValue() for scalable types
san_scalable_min_store_bits :: (t: Type_Id) -> u64 {
    if type_kind(t) == .SVECTOR return type_count(t) * dl_type_size_bits(type_elem(t));
    return dl_type_store_size(t) * 8;
}

Asan :: struct {
    compile_kernel: bool;
    recover: bool;
    use_after_scope: bool;
    use_after_return: Asan_Uar;
    long_size: u64;
    intptr: Type_Id;
    mapping: Asan_Mapping;
    calls_threshold: s64;
    max_inline_poisoning_size: u64;
    ssgi: *Stack_Safety_Global;

    handle_no_return: San_Callee;
    ptr_cmp, ptr_sub: San_Callee;
    error_callback: [2][2][ASAN_K_NUMBER_OF_ACCESS_SIZES] San_Callee;
    memory_access_callback: [2][2][ASAN_K_NUMBER_OF_ACCESS_SIZES] San_Callee;
    error_callback_sized: [2][2] San_Callee;
    memory_access_callback_sized: [2][2] San_Callee;
    memmove, memcpy, memset: San_Callee;
    local_dynamic_shadow: Value_Id = NONE;
    processed_allocas: Table(Value_Id, bool);

    // RuntimeCallInserter
    f: Value_Id;
    rtci_track: bool;
    rtci_calls: [..] Value_Id;
}

// RuntimeCallInserter::createRuntimeCall
asan_rt_call :: (a: *Asan, b: *Irb, c: San_Callee, args: [] Value_Id, name: string = "") -> Value_Id {
    i := san_call(b, c, args, name);
    if a.rtci_track array_add(*a.rtci_calls, i);
    return i;
}

// ~RuntimeCallInserter: funclet bundles for the calls in monochromatic funclet blocks
asan_rtci_finish :: (a: *Asan) {
    if a.rtci_calls.count == 0 return;
    colors: Table(Value_Id, [..] Value_Id); colors.allocator = temp;
    color_eh_funclets(a.f, *colors);
    for ci: a.rtci_calls {
        bb := inst(ci).parent;
        found, cv := table_find(*colors, bb);
        if !found || cv.count == 0 continue;
        if cv.count != 1 { print_to_stderr("error: Instruction's BasicBlock is not monochromatic\n"); continue; }
        pad := block_first_non_phi(cv[0]);
        if pad != NONE && inst_is_eh_pad(pad) {
            nc := ic_call_with_bundles(ci, .[], "funclet", .[pad], call_callee(ci));
            copy_metadata(nc, ci);
            insert_at_position(nc, bb, ci, false);
            rauw_with_metadata(ci, nc);
            erase_inst(ci);
        }
    }
}

// AddressSanitizer::isInterestingAlloca
asan_is_interesting_alloca :: (a: *Asan, ai: Value_Id) -> bool {
    found, v := table_find(*a.processed_allocas, ai);
    if found return v;
    ty := inst(ai).ty2;
    interesting := type_is_sized(ty);
    if interesting && is_static_alloca(ai) {
        ok, sz := alloca_allocation_size(ai);
        // getAllocaSizeInBytes dereferences getAllocationSize, which is empty when the size overflows u64
        if !ok fatal("asan: a static alloca whose size does not fit in 64 bits (LLVM dereferences an empty optional here)");
        if sz == 0 interesting = false;
    }
    if interesting && asan_cl.skip_promotable_allocas && is_alloca_promotable(ai) interesting = false;
    if interesting && asan_alloca_is_used_with_inalloca(ai) interesting = false;
    if interesting && (inst(ai).flags & F_SWIFTERR) interesting = false;
    if interesting && a.ssgi && stack_safety_is_safe(a.ssgi, ai) interesting = false;
    table_set(*a.processed_allocas, ai, interesting);
    return interesting;
}
// AllocaInst::isUsedWithInAlloca
asan_alloca_is_used_with_inalloca :: (ai: Value_Id) -> bool { return (inst(ai).flags & F_INALLOCA) != 0; }

// isSupportedAddrspace
asan_is_supported_addrspace :: (v: Value_Id) -> bool {
    as := cast(u64) ir.types[scalar_type(vtype(v))].a;
    if asan_cl.addr_spaces.count { for asan_cl.addr_spaces if it == as return true; return false; }
    return as == 0;
}

// Value::isSwiftError
value_is_swift_error :: (v: Value_Id) -> bool {
    if vkind(v) == .ARGUMENT return arg_has_attr(v, .SwiftError);
    if is_inst(v) && inst_op(v) == .ALLOCA return (inst(v).flags & F_SWIFTERR) != 0;
    return false;
}

// AddressSanitizer::ignoreAccess
asan_ignore_access :: (a: *Asan, i: Value_Id, ptr: Value_Id) -> bool {
    if !asan_is_supported_addrspace(ptr) return true;
    if value_is_swift_error(ptr) return true;
    if is_inst(ptr) && inst_op(ptr) == .ALLOCA
        if asan_cl.skip_promotable_allocas && !asan_is_interesting_alloca(a, ptr) return true;
    if a.ssgi && stack_safety_access_is_safe(a.ssgi, i) && find_alloca_for_value(ptr) != NONE return true;
    return false;
}

// findAllocaForValue(V, OffsetZero = false)
find_alloca_for_value :: (v_in: Value_Id, offset_zero := false) -> Value_Id {
    result: Value_Id = NONE;
    visited: [..] Value_Id; visited.allocator = temp;
    wl: [..] Value_Id; wl.allocator = temp;
    add :: (v: Value_Id, visited: *[..] Value_Id, wl: *[..] Value_Id) { if !array_find(visited.*, v) { array_add(visited, v); array_add(wl, v); } }
    add(v_in, *visited, *wl);
    while wl.count {
        v := pop(*wl);
        if !is_inst(v) return NONE;
        o := inst_op(v);
        if o == .ALLOCA { if result != NONE && result != v return NONE; result = v; }
        else if is_cast_op(o) add(op(v, 0), *visited, *wl);
        else if o == .PHI { for k: 0..nops(v)-1 add(op(v, k), *visited, *wl); }
        else if o == .SELECT { add(op(v, 1), *visited, *wl); add(op(v, 2), *visited, *wl); }
        else if o == .GEP {
            if offset_zero { for k: 1..nops(v)-1 if !is_null_value(op(v, k)) return NONE; }
            add(op(v, 0), *visited, *wl);
        } else if is_call_base(v) {
            r := call_returned_arg(v);
            if r != NONE add(r, *visited, *wl); else return NONE;
        } else return NONE;
    }
    return result;
}

// AddressSanitizer::getInterestingMemoryOperands
asan_get_interesting_memory_operands :: (a: *Asan, i: Value_Id, out: *[..] Asan_Mop) {
    if a.local_dynamic_shadow == i return;
    o := inst_op(i);
    if o == .LOAD {
        if !asan_cl.instrument_reads || asan_ignore_access(a, i, op(i, 0)) return;
        array_add(out, asan_mop(i, 0, false, vtype(i), inst(i).align));
    } else if o == .STORE {
        if !asan_cl.instrument_writes || asan_ignore_access(a, i, op(i, 1)) return;
        array_add(out, asan_mop(i, 1, true, vtype(op(i, 0)), inst(i).align));
    } else if o == .ATOMICRMW {
        if !asan_cl.instrument_atomics || asan_ignore_access(a, i, op(i, 0)) return;
        array_add(out, asan_mop(i, 0, true, vtype(op(i, 1)), 0));
    } else if o == .CMPXCHG {
        if !asan_cl.instrument_atomics || asan_ignore_access(a, i, op(i, 0)) return;
        array_add(out, asan_mop(i, 0, true, vtype(op(i, 1)), 0));
    } else if o == .CALL {
        id := call_iid(i);
        if id == IID_MASKED_LOAD || id == IID_MASKED_STORE || id == IID_MASKED_GATHER || id == IID_MASKED_SCATTER {
            is_write := vtype(i) == ir.t_void;
            off: u32 = ifx is_write then cast(u32) 1 else 0;
            if ifx is_write then !asan_cl.instrument_writes else !asan_cl.instrument_reads return;
            base := op(i, off);
            if asan_ignore_access(a, i, base) return;
            ty := ifx is_write then vtype(op(i, 0)) else vtype(i);
            al := call_param_align(i, 0);
            mask := op(i, 1 + off);
            array_add(out, asan_mop(i, off, is_write, ty, al, mask));
            return;
        }
        if id == IID_MASKED_EXPANDLOAD || id == IID_MASKED_COMPRESSSTORE {
            is_write := id == IID_MASKED_COMPRESSSTORE;
            off: u32 = ifx is_write then cast(u32) 1 else 0;
            if ifx is_write then !asan_cl.instrument_writes else !asan_cl.instrument_reads return;
            base := op(i, off);
            if asan_ignore_access(a, i, base) return;
            al := pointer_alignment(base);
            ty := ifx is_write then vtype(op(i, 0)) else vtype(i);
            b: Irb; irb_set_before(*b, i);
            mask := op(i, 1 + off);
            ext_ty := vector_with_elt(ty, a.intptr);
            ext_mask := irb_cast(*b, .ZEXT, mask, ext_ty);
            evl := irb_intrinsic(*b, "llvm.vector.reduce.add", .[ext_ty], .[ext_mask]);
            true_mask := cf_get_splat(vtype(mask), const_int(ir.t_i1, 1));
            array_add(out, asan_mop(i, off, is_write, ty, al, true_mask, evl));
            return;
        }
        if id == IID_VP_LOAD || id == IID_VP_STORE || id == IID_VP_STRIDED_LOAD || id == IID_VP_STRIDED_STORE {
            is_write := vtype(i) == ir.t_void;
            if ifx is_write then !asan_cl.instrument_writes else !asan_cl.instrument_reads return;
            ptr_op: u32 = ifx is_write then cast(u32) 1 else 0;
            ty := ifx is_write then vtype(op(i, 0)) else vtype(i);
            al := pointer_alignment(op(i, ptr_op));
            stride: Value_Id = NONE;
            nextra: u32 = 0;
            if id == IID_VP_STRIDED_LOAD || id == IID_VP_STRIDED_STORE {
                stride = op(i, ptr_op + 1);
                nextra = 1;
                pa := ifx al == 0 then cast(u64) 1 else al;
                if vkind(stride) != .C_INT || const_int_zext(stride) % pa != 0 al = 1;
            }
            array_add(out, asan_mop(i, ptr_op, is_write, ty, al, op(i, ptr_op + 1 + nextra), op(i, ptr_op + 2 + nextra), stride));
            return;
        }
        if id == IID_VP_GATHER || id == IID_VP_SCATTER {
            is_write := id == IID_VP_SCATTER;
            if ifx is_write then !asan_cl.instrument_writes else !asan_cl.instrument_reads return;
            ptr_op: u32 = ifx is_write then cast(u32) 1 else 0;
            ty := ifx is_write then vtype(op(i, 0)) else vtype(i);
            al := call_param_align(i, ptr_op);
            array_add(out, asan_mop(i, ptr_op, is_write, ty, al, op(i, ptr_op + 1), op(i, ptr_op + 2)));
            return;
        }
        if id != NOT_INTRINSIC {
            // TTI->getTgtMemIntrinsic: false on x86
            return;
        }
        n := call_arg_count(i);
        if n > 0 for k: 0..n-1 {
            if !asan_cl.instrument_byval || !call_is_byval_arg(i, k) || asan_ignore_access(a, i, op(i, k)) continue;
            ty := call_param_byval_type(i, k);
            array_add(out, asan_mop(i, k, false, ty, 1));
        }
    }
}

asan_is_pointer_operand :: (v: Value_Id) -> bool { return is_ptr_type(vtype(v)) || (is_inst(v) && inst_op(v) == .PTRTOINT); }
asan_is_interesting_pointer_comparison :: (i: Value_Id) -> bool {
    if inst_op(i) != .ICMP return false;
    p := inst_pred(i);
    if p == ICMP_EQ || p == ICMP_NE return false;
    return asan_is_pointer_operand(op(i, 0)) && asan_is_pointer_operand(op(i, 1));
}
asan_is_interesting_pointer_subtraction :: (i: Value_Id) -> bool {
    if inst_op(i) != .SUB return false;
    return asan_is_pointer_operand(op(i, 0)) && asan_is_pointer_operand(op(i, 1));
}

// AddressSanitizer::GlobalIsLinkerInitialized
asan_global_is_linker_initialized :: (g: Value_Id) -> bool {
    if !glob(g).has_init return false;
    if glob(g).sanitizer & 8 return false;
    return true;
}

// AddressSanitizer::memToShadow
asan_mem_to_shadow :: (a: *Asan, shadow_in: Value_Id, b: *Irb) -> Value_Id {
    shadow := irb_binop(b, .LSHR, shadow_in, const_int(vtype(shadow_in), cast(u64) a.mapping.scale));
    if a.mapping.offset == 0 return shadow;
    base := ifx a.local_dynamic_shadow != NONE then a.local_dynamic_shadow else const_int(a.intptr, a.mapping.offset);
    if a.mapping.or_shadow_offset return irb_binop(b, .OR, shadow, base);
    return irb_binop(b, .ADD, shadow, base);
}

// AddressSanitizer::instrumentMemIntrinsic
asan_instrument_mem_intrinsic :: (a: *Asan, mi: Value_Id) {
    b: Irb; irb_instr_before(*b, mi);
    id := call_iid(mi);
    pty := type_ptr(0);
    if id == IID_MEMCPY || id == IID_MEMMOVE || id == IID_MEMCPY_INLINE {
        asan_rt_call(a, *b, ifx id == IID_MEMMOVE then a.memmove else a.memcpy,
            .[irb_addrspace_cast(*b, op(mi, 0), pty), irb_addrspace_cast(*b, op(mi, 1), pty), irb_int_cast(*b, op(mi, 2), a.intptr, false)]);
    } else {
        asan_rt_call(a, *b, a.memset,
            .[irb_addrspace_cast(*b, op(mi, 0), pty), irb_int_cast(*b, op(mi, 1), ir.t_i32, false), irb_int_cast(*b, op(mi, 2), a.intptr, false)]);
    }
    erase_inst(mi);
}

// isa<MemIntrinsic>: memcpy, memcpy.inline, memmove, memset, memset.inline
asan_is_mem_intrinsic :: (i: Value_Id) -> bool {
    id := call_iid(i);
    return id == IID_MEMCPY || id == IID_MEMCPY_INLINE || id == IID_MEMMOVE || id == IID_MEMSET || id == IID_MEMSET_INLINE;
}

// AddressSanitizer::instrumentPointerComparisonOrSubtraction
asan_instrument_pointer_cmp_or_sub :: (a: *Asan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    c := ifx inst_op(i) == .ICMP then a.ptr_cmp else a.ptr_sub;
    p: [2] Value_Id;
    p[0] = op(i, 0); p[1] = op(i, 1);
    for * p if is_ptr_type(vtype(it.*)) it.* = irb_pointer_cast(*b, it.*, a.intptr);
    asan_rt_call(a, *b, c, p);
}

// doInstrumentAddress
asan_do_instrument_address :: (a: *Asan, i: Value_Id, insert_before: Value_Id, addr: Value_Id, align: u64, granularity: u64,
                               store_bits: u64, scalable: bool, is_write: bool, use_calls: bool, exp: u32) {
    if !scalable {
        if store_bits == 8 || store_bits == 16 || store_bits == 32 || store_bits == 64 || store_bits == 128 {
            if align == 0 || align >= granularity || align >= store_bits / 8 {
                asan_instrument_address(a, i, insert_before, addr, align, store_bits, is_write, NONE, use_calls, exp);
                return;
            }
        }
    }
    asan_instrument_unusual_size_or_alignment(a, i, insert_before, addr, store_bits, scalable, is_write, use_calls, exp);
}

// AddressSanitizer::instrumentMaskedLoadOrStore
asan_instrument_masked_load_or_store :: (a: *Asan, mask: Value_Id, evl_in: Value_Id, stride_in: Value_Id, i: Value_Id, addr: Value_Id,
                                         align: u64, granularity: u64, op_type: Type_Id, is_write: bool, use_calls: bool, exp: u32) {
    vty := op_type;
    elem_bits := dl_type_store_size(scalar_type(vty)) * 8;
    zero := const_int(a.intptr, 0);
    scalable := type_kind(vty) == .SVECTOR;
    n := type_count(vty);
    ib: Irb; irb_set_before(*ib, i);
    loop_insert_before := i;
    evl := evl_in;
    if evl != NONE {
        is_evl_zero := irb_icmp(*ib, ICMP_NE, evl, const_int(vtype(evl), 0));
        loop_insert_before = sbi_if_then(is_evl_zero, i, false);
        irb_set_before(*ib, loop_insert_before);
        evl = irb_zext_or_trunc_any(*ib, evl, a.intptr);
        ec := irb_type_size(*ib, a.intptr, n, scalable);
        evl = irb_intrinsic(*ib, "llvm.umin", .[a.intptr], .[evl, ec]);
    } else {
        evl = irb_type_size(*ib, a.intptr, n, scalable);
    }
    stride := stride_in;
    if stride != NONE stride = irb_zext_or_trunc_any(*ib, stride, a.intptr);
    lane :: (a: *Asan, b: *Irb, index_in: Value_Id, mask: Value_Id, addr: Value_Id, stride: Value_Id, vty: Type_Id, zero: Value_Id,
             i: Value_Id, align: u64, granularity: u64, elem_bits: u64, is_write: bool, use_calls: bool, exp: u32) {
        index := index_in;
        mask_elem := irb_extract_element_v(b, mask, index);
        if vkind(mask_elem) == .C_INT {
            if const_int_zext(mask_elem) == 0 return;
        } else {
            then_term := sbi_if_then(mask_elem, b.pt, false);
            irb_set_before(b, then_term);
        }
        iaddr: Value_Id;
        if is_vector_type(vtype(addr)) iaddr = irb_extract_element_v(b, addr, index);
        else if stride != NONE { index = irb_binop(b, .MUL, index, stride); iaddr = irb_ptr_add(b, addr, index); }
        else iaddr = irb_gep(b, vty, addr, .[zero, index]);
        asan_do_instrument_address(a, i, b.pt, iaddr, align, granularity, elem_bits, false, is_write, use_calls, exp);
    }
    // SplitBlockAndInsertForEachLane(EVL, LoopInsertBefore, ...)
    if vkind(evl) != .C_INT {
        body_ip, index := sbi_simple_for_loop(evl, loop_insert_before);
        b: Irb; irb_set_before(*b, body_ip);
        lane(a, *b, index, mask, addr, stride, vty, zero, i, align, granularity, elem_bits, is_write, use_calls, exp);
        return;
    }
    num := const_int_zext(evl);
    for idx: 0..cast(s64) num - 1 {
        b: Irb; irb_set_before(*b, loop_insert_before);
        lane(a, *b, const_int(vtype(evl), cast(u64) idx), mask, addr, stride, vty, zero, i, align, granularity, elem_bits, is_write, use_calls, exp);
    }
}

// IRBuilder::CreateExtractElement(Vec, Idx (a Value))
irb_extract_element_v :: (b: *Irb, v: Value_Id, idx: Value_Id, name: string = "") -> Value_Id {
    if irb_is_const(v) && irb_is_const(idx) {
        r := cf_extract_element(v, idx);
        if r != NONE return r;
    }
    e := new_inst(.EXTRACTELEMENT, type_elem(vtype(v)), 2);
    set_op(e, 0, v); set_op(e, 1, idx);
    return irb_insert(b, e, name);
}

// AddressSanitizer::isSafeAccess
asan_is_safe_access :: (a: *Asan, addr: Value_Id, store_bits: u64, scalable: bool) -> bool {
    if scalable return false;
    opts: Os_Opts;
    ok, size, offset := os_compute(opts, addr);
    if !ok return false;
    sz := ap_zext_value(size);
    off := ap_sext_value(offset);
    return off >= 0 && sz >= cast(u64) off && sz - cast(u64) off >= store_bits / 8;
}

// AddressSanitizer::instrumentMop
asan_instrument_mop :: (a: *Asan, o: *Asan_Mop, use_calls: bool) {
    addr := asan_mop_ptr(o);
    exp := cast(u32) asan_cl.force_experiment;
    if asan_cl.opt && asan_cl.opt_globals {
        g := get_underlying_object(addr);
        if vkind(g) == .GLOBAL_VAR && (!asan_cl.initializers || asan_global_is_linker_initialized(g)) &&
           asan_is_safe_access(a, addr, o.store_bits, o.scalable) return;
    }
    if asan_cl.opt && asan_cl.opt_stack {
        u := get_underlying_object(addr);
        if is_inst(u) && inst_op(u) == .ALLOCA && asan_is_safe_access(a, addr, o.store_bits, o.scalable) return;
    }
    if o.byte_offset != NONE fatal("asan: byte-offset memory operands are not implemented yet");
    granularity := (cast(u64) 1) << cast(u64) a.mapping.scale;
    if o.mask != NONE {
        asan_instrument_masked_load_or_store(a, o.mask, o.evl, o.stride, o.insn, addr, o.align, granularity, o.op_type, o.is_write, use_calls, exp);
    } else {
        asan_do_instrument_address(a, o.insn, o.insn, addr, o.align, granularity, o.store_bits, o.scalable, o.is_write, use_calls, exp);
    }
}

// AddressSanitizer::generateCrashCode
asan_generate_crash_code :: (a: *Asan, insert_before: Value_Id, addr: Value_Id, is_write: bool, size_index: s64, size_arg: Value_Id, exp: u32) -> Value_Id {
    b: Irb; irb_instr_before(*b, insert_before);
    w := cast(s64) is_write;
    call: Value_Id;
    if size_arg != NONE {
        if exp == 0 call = asan_rt_call(a, *b, a.error_callback_sized[w][0], .[addr, size_arg]);
        else call = asan_rt_call(a, *b, a.error_callback_sized[w][1], .[addr, size_arg, const_int(ir.t_i32, exp)]);
    } else {
        if exp == 0 call = asan_rt_call(a, *b, a.error_callback[w][0][size_index], .[addr]);
        else call = asan_rt_call(a, *b, a.error_callback[w][1][size_index], .[addr, const_int(ir.t_i32, exp)]);
    }
    call_add_fn_attr(call, Attr_Kind.NoMerge);   // setCannotMerge
    return call;
}

// AddressSanitizer::createSlowPathCmp
asan_create_slow_path_cmp :: (a: *Asan, b: *Irb, addr_long: Value_Id, shadow_value: Value_Id, store_bits: u64) -> Value_Id {
    granularity := (cast(u64) 1) << cast(u64) a.mapping.scale;
    last := irb_binop(b, .AND, addr_long, const_int(a.intptr, granularity - 1));
    if store_bits / 8 > 1 last = irb_binop(b, .ADD, last, const_int(a.intptr, store_bits / 8 - 1));
    last = irb_int_cast(b, last, vtype(shadow_value), false);
    return irb_icmp(b, ICMP_SGE, last, shadow_value);
}

asan_size_index :: (store_bits: u64) -> s64 { n := store_bits / 8; r := 0; while n > 1 { n >>= 1; r += 1; } return r; }

// AddressSanitizer::instrumentAddress
asan_instrument_address :: (a: *Asan, orig: Value_Id, insert_before: Value_Id, addr: Value_Id, align: u64, store_bits: u64,
                            is_write: bool, size_arg: Value_Id, use_calls: bool, exp: u32) {
    b: Irb; irb_instr_before(*b, insert_before);
    size_index := asan_size_index(store_bits);
    w := cast(s64) is_write;
    if use_calls && asan_cl.optimize_callbacks {
        packed := ((cast(u64) is_write) << 5) + (cast(u64) a.compile_kernel) + ((cast(u64) size_index) << 1);
        c := san_intrinsic_with_attrs("llvm.asan.check.memaccess", ir.t_void, .[type_ptr(0), ir.t_i32], "nounwind", .["", "immarg"]);
        san_call(*b, c, .[irb_pointer_cast(*b, addr, type_ptr(0)), const_int(ir.t_i32, packed)]);
        return;
    }
    addr_long := irb_pointer_cast(*b, addr, a.intptr);
    if use_calls {
        if exp == 0 asan_rt_call(a, *b, a.memory_access_callback[w][0][size_index], .[addr_long]);
        else asan_rt_call(a, *b, a.memory_access_callback[w][1][size_index], .[addr_long, const_int(ir.t_i32, exp)]);
        return;
    }
    shadow_ty := type_int(max(cast(u64) 8, store_bits >> cast(u64) a.mapping.scale));
    shadow_ptr_ty := type_ptr(cast(u64) asan_cl.shadow_addr_space);
    shadow_ptr := asan_mem_to_shadow(a, addr_long, *b);
    al := ifx align == 0 then cast(u64) 1 else align;
    shadow_align := max(al >> cast(u64) a.mapping.scale, 1);
    shadow_value := irb_load(*b, shadow_ty, irb_cast(*b, .INTTOPTR, shadow_ptr, shadow_ptr_ty), shadow_align);
    cmp := irb_icmp(*b, ICMP_NE, shadow_value, const_null_value(shadow_ty));
    granularity := (cast(u64) 1) << cast(u64) a.mapping.scale;
    crash_term: Value_Id;
    gen_slow_path := asan_cl.always_slow_path || store_bits < 8 * granularity;
    if gen_slow_path {
        check_term := sbi_if_then(cmp, insert_before, false, create_unlikely_branch_weights());
        next_bb := get_successor(check_term, 0);
        irb_set_before(*b, check_term);
        cmp2 := asan_create_slow_path_cmp(a, *b, addr_long, shadow_value, store_bits);
        if a.recover {
            crash_term = sbi_if_then(cmp2, check_term, false);
        } else {
            crash_block := create_block(block_fn(next_bb), "", next_bb);
            crash_term = new_inst(.UNREACHABLE, ir.t_void, 0);
            block_append_inst(crash_block, crash_term);
            nt := create_cond_br(cmp2, crash_block, next_bb);
            replace_inst_with_inst(check_term, nt);
        }
    } else {
        crash_term = sbi_if_then(cmp, insert_before, !a.recover);
    }
    crash := asan_generate_crash_code(a, crash_term, addr_long, is_write, size_index, size_arg, exp);
    d := get_metadata(orig, 0);
    if d != NONE set_metadata(crash, 0, d);
}

// AddressSanitizer::instrumentUnusualSizeOrAlignment
asan_instrument_unusual_size_or_alignment :: (a: *Asan, i: Value_Id, insert_before: Value_Id, addr: Value_Id, store_bits: u64, scalable: bool,
                                              is_write: bool, use_calls: bool, exp: u32) {
    b: Irb; irb_instr_before(*b, insert_before);
    num_bits := irb_type_size(*b, a.intptr, store_bits, scalable);
    size := irb_binop(*b, .LSHR, num_bits, const_int(a.intptr, 3));
    addr_long := irb_pointer_cast(*b, addr, a.intptr);
    w := cast(s64) is_write;
    if use_calls {
        if exp == 0 asan_rt_call(a, *b, a.memory_access_callback_sized[w][0], .[addr_long, size]);
        else asan_rt_call(a, *b, a.memory_access_callback_sized[w][1], .[addr_long, size, const_int(ir.t_i32, exp)]);
    } else {
        size_minus_one := irb_binop(*b, .SUB, size, const_int(a.intptr, 1));
        last_byte := irb_cast(*b, .INTTOPTR, irb_binop(*b, .ADD, addr_long, size_minus_one), vtype(addr));
        asan_instrument_address(a, i, insert_before, addr, 0, 8, is_write, size, false, exp);
        asan_instrument_address(a, i, insert_before, last_byte, 0, 8, is_write, size, false, exp);
    }
}

// AddressSanitizer::initializeCallbacks
asan_initialize_callbacks :: (a: *Asan, t: *Tli) {
    v := ir.t_void;
    ip := a.intptr;
    pty := type_ptr(0);
    for exp: 0..1 {
        for w: 0..1 {
            type_str := ifx w then "store" else "load";
            exp_str := ifx exp then "exp_" else "";
            ending := ifx a.recover then "_noabort" else "";
            args2: [..] Type_Id; args2.allocator = temp; array_add(*args2, ip); array_add(*args2, ip);
            args1: [..] Type_Id; args1.allocator = temp; array_add(*args1, ip);
            al2: u32 = 0; al1: u32 = 0;
            if exp {
                array_add(*args2, ir.t_i32); array_add(*args1, ir.t_i32);
                ext := tli_ext_attr_for_i32_param(false);
                if ext != .NONE_ATTR {
                    al2 = san_attr_list_with_param_attr(0, 2, ext);
                    al1 = san_attr_list_with_param_attr(0, 1, ext);
                }
            }
            a.error_callback_sized[w][exp] = san_callee(tprint("__asan_report_%1%2_n%3", exp_str, type_str, ending), v, args2, al2);
            a.memory_access_callback_sized[w][exp] = san_callee(tprint("%1%2%3N%4", asan_cl.memory_access_callback_prefix, exp_str, type_str, ending), v, args2, al2);
            for k: 0..ASAN_K_NUMBER_OF_ACCESS_SIZES-1 {
                suffix := tprint("%1%2", type_str, (cast(u64) 1) << cast(u64) k);
                a.error_callback[w][exp][k] = san_callee(tprint("__asan_report_%1%2%3", exp_str, suffix, ending), v, args1, al1);
                a.memory_access_callback[w][exp][k] = san_callee(tprint("%1%2%3%4", asan_cl.memory_access_callback_prefix, exp_str, suffix, ending), v, args1, al1);
            }
        }
    }
    prefix := ifx a.compile_kernel && !asan_cl.kasan_mem_intrin_callback_prefix then "" else asan_cl.memory_access_callback_prefix;
    a.memmove = san_callee(tconcat(prefix, "memmove"), pty, .[pty, pty, ip]);
    a.memcpy = san_callee(tconcat(prefix, "memcpy"), pty, .[pty, pty, ip]);
    // TLI->getAttrList(C, {1}, /*Signed=*/false)
    ms_attrs: u32 = 0;
    ext := tli_ext_attr_for_i32_param(false);
    if ext != .NONE_ATTR ms_attrs = san_attr_list_with_param_attr(0, 1, ext);
    a.memset = san_callee(tconcat(prefix, "memset"), pty, .[pty, ir.t_i32, ip], ms_attrs);
    a.handle_no_return = san_callee("__asan_handle_no_return", v, .[]);
    a.ptr_cmp = san_callee("__sanitizer_ptr_cmp", v, .[ip, ip]);
    a.ptr_sub = san_callee("__sanitizer_ptr_sub", v, .[ip, ip]);
    // Mapping.InGlobal is false on the supported targets
    san_callee("llvm.amdgcn.is.shared", ir.t_i1, .[pty]);
    san_callee("llvm.amdgcn.is.private", ir.t_i1, .[pty]);
}

san_attr_list_with_param_attr :: (l: u32, k: u32, kind: Attr_Kind) -> u32 {
    a: Attr; a.kind = kind; a.ty = NONE;
    return attr_list_with_param(l, k, attr_set_with(attr_list_param(l, k), a));
}

// AddressSanitizer::maybeInsertAsanInitAtFunctionEntry
asan_maybe_insert_init_at_function_entry :: (f: Value_Id) -> bool {
    if find_index_from_left(vname(f), " load]") < 0 return false;
    init := san_declare_sanitizer_init_function("__asan_init", .[]);
    b: Irb; entry := fn_entry(f); irb_set_at(*b, entry, block_first(entry), false);
    san_call(*b, init, .[]);
    return true;
}

// AddressSanitizer::maybeInsertDynamicShadowAtFunctionEntry
asan_maybe_insert_dynamic_shadow_at_function_entry :: (a: *Asan, f: Value_Id) -> bool {
    if a.mapping.offset != ASAN_K_DYNAMIC_SHADOW_SENTINEL return false;
    b: Irb; irb_set_before(*b, block_first(fn_entry(f)));
    g := module_get_or_insert_global("__asan_shadow_memory_dynamic_address", a.intptr);
    a.local_dynamic_shadow = irb_load(*b, a.intptr, g, dl_abi_align(a.intptr));
    return true;
}

// AddressSanitizer::markEscapedLocalAllocas
asan_mark_escaped_local_allocas :: (a: *Asan, f: Value_Id) {
    if module_get_function("llvm.localescape") == NONE return;
    for i: block_insts(fn_entry(f)) {
        if call_iid(i) != IID_LOCALESCAPE continue;
        n := call_arg_count(i);
        if n > 0 for k: 0..n-1 {
            ai := strip_pointer_casts(op(i, k));
            table_set(*a.processed_allocas, ai, false);
        }
        break;
    }
}

// AddressSanitizer::suppressInstrumentationSiteForDebug
asan_suppress_for_debug :: (n: *s64) -> bool {
    should := asan_cl.debug_min < 0 || asan_cl.debug_max < 0 || (n.* >= asan_cl.debug_min && n.* <= asan_cl.debug_max);
    n.* += 1;
    return !should;
}

// AddressSanitizer::instrumentFunction
asan_instrument_function :: (a: *Asan, f: Value_Id, t: *Tli) -> bool {
    modified := false;
    if fn_has_fn_attr(f, .Naked) return modified;
    if asan_maybe_insert_init_at_function_entry(f) modified = true;
    if !fn_has_fn_attr(f, .SanitizeAddress) return modified;
    if fn_has_fn_attr(f, .DisableSanitizerInstrumentation) return modified;
    asan_initialize_callbacks(a, t);
    a.f = f;
    pers := fn_personality(f);
    if pers != NONE && is_scoped_eh_personality(classify_eh_personality(pers)) a.rtci_track = true;
    if asan_maybe_insert_dynamic_shadow_at_function_entry(a, f) modified = true;
    asan_mark_escaped_local_allocas(a, f);
    if san_triple_is_os_windows() {
        // markCatchParametersAsUninteresting
        for i: fn_insts(f) if inst_op(i) == .CATCHPAD {
            for k: 0..cast(s64) catchpad_num_args(i) - 1 { x := op(i, cast(u32) k); if is_inst(x) && inst_op(x) == .ALLOCA table_set(*a.processed_allocas, x, false); }
        }
    }
    temps: [..] Value_Id; temps.allocator = temp;
    mops: [..] Asan_Mop; mops.allocator = temp;
    intrin: [..] Value_Id; intrin.allocator = temp;
    no_return_calls: [..] Value_Id; no_return_calls.allocator = temp;
    ptr_cmps: [..] Value_Id; ptr_cmps.allocator = temp;
    nosanitize := md_kind_id("nosanitize");
    for bb: fn_blocks(f) {
        temps.count = 0;
        n_per_bb := 0;
        for i: block_insts(bb) {
            if get_metadata(i, nosanitize) != NONE continue;
            ops: [..] Asan_Mop; ops.allocator = temp;
            asan_get_interesting_memory_operands(a, i, *ops);
            if ops.count {
                for * o: ops {
                    if asan_cl.opt && asan_cl.opt_same_temp {
                        p := asan_mop_ptr(o);
                        if o.mask != NONE {
                            if array_find(temps, p) continue;
                        } else {
                            if array_find(temps, p) continue;
                            array_add(*temps, p);
                        }
                    }
                    array_add(*mops, o.*);
                    n_per_bb += 1;
                }
            } else if ((asan_cl.invalid_pointer_pairs || asan_cl.invalid_pointer_cmp) && asan_is_interesting_pointer_comparison(i)) ||
                      ((asan_cl.invalid_pointer_pairs || asan_cl.invalid_pointer_sub) && asan_is_interesting_pointer_subtraction(i)) {
                array_add(*ptr_cmps, i);
            } else if inst_op(i) == .CALL && asan_is_mem_intrinsic(i) {
                array_add(*intrin, i);
                n_per_bb += 1;
            } else {
                if is_call_base(i) {
                    temps.count = 0;
                    if call_does_not_return(i) array_add(*no_return_calls, i);
                }
                if inst_op(i) == .CALL maybe_mark_sanitizer_library_call_no_builtin(i, t);
            }
            if n_per_bb >= asan_cl.max_insns_per_bb break;
        }
    }
    use_calls := a.calls_threshold >= 0 && cast(s64)(mops.count + intrin.count) > a.calls_threshold;
    n_instrumented: s64 = 0;
    for * mops {
        if !asan_suppress_for_debug(*n_instrumented) asan_instrument_mop(a, it, use_calls);
        modified = true;
    }
    for intrin {
        if !asan_suppress_for_debug(*n_instrumented) asan_instrument_mem_intrinsic(a, it);
        modified = true;
    }
    changed_stack := asan_fsp_run(a, f);
    for no_return_calls {
        b: Irb; irb_set_before(*b, it);
        asan_rt_call(a, *b, a.handle_no_return, .[]);
    }
    for ptr_cmps {
        asan_instrument_pointer_cmp_or_sub(a, it);
        modified = true;
    }
    if changed_stack || no_return_calls.count modified = true;
    asan_rtci_finish(a);
    return modified;
}

catchpad_num_args :: (i: Value_Id) -> u32 { return nops(i) - 1; }

// ---------------------------------------------------------------- FunctionStackPoisoner

Asan_Poison_Call :: struct { ins_before: Value_Id; ai: Value_Id; size: u64; do_poison: bool; }

Asan_Fsp :: struct {
    a: *Asan;
    f: Value_Id;
    intptr: Type_Id;
    alloca_vec: [..] Value_Id;
    static_allocas_to_move_up: [..] Value_Id;
    ret_vec: [..] Value_Id;
    stack_malloc: [ASAN_K_MAX_STACK_MALLOC_SIZE_CLASS + 1] San_Callee;
    stack_free: [ASAN_K_MAX_STACK_MALLOC_SIZE_CLASS + 1] San_Callee;
    set_shadow: [256] San_Callee;
    poison_stack_memory, unpoison_stack_memory: San_Callee;
    alloca_poison, allocas_unpoison: San_Callee;
    dynamic_poison_calls: [..] Asan_Poison_Call;
    static_poison_calls: [..] Asan_Poison_Call;
    dynamic_alloca_vec: [..] Value_Id;
    stack_restore_vec: [..] Value_Id;
    dynamic_alloca_layout: Value_Id = NONE;
    local_escape_call: Value_Id = NONE;
    has_inline_asm: bool;
    has_returns_twice_call: bool;
}

// FunctionStackPoisoner::runOnFunction
asan_fsp_run :: (a: *Asan, f: Value_Id) -> bool {
    if !asan_cl.stack return false;
    s: Asan_Fsp;
    s.a = a; s.f = f; s.intptr = a.intptr;
    s.alloca_vec.allocator = temp; s.static_allocas_to_move_up.allocator = temp; s.ret_vec.allocator = temp;
    s.dynamic_poison_calls.allocator = temp; s.static_poison_calls.allocator = temp;
    s.dynamic_alloca_vec.allocator = temp; s.stack_restore_vec.allocator = temp;
    if asan_cl.redzone_byval_args asan_fsp_copy_args_passed_by_val_to_allocas(*s);
    // for (BasicBlock *BB : depth_first(&F.getEntryBlock())) visit(*BB);
    order: [..] Value_Id; order.allocator = temp;
    san_depth_first(fn_entry(f), *order);
    for bb: order for i: block_insts(bb) asan_fsp_visit(*s, i);
    if s.alloca_vec.count == 0 && s.dynamic_alloca_vec.count == 0 return false;
    asan_fsp_initialize_callbacks(*s);
    asan_fsp_process_dynamic_allocas(*s);
    asan_fsp_process_static_allocas(*s);
    return true;
}

// depth_first(Entry): preorder of an iterative DFS over successors (df_iterator)
san_depth_first :: (entry: Value_Id, out: *[..] Value_Id) {
    visited: Table(Value_Id, bool); visited.allocator = temp;
    Frame :: struct { b: Value_Id; next: u32; n: u32; }
    stack: [..] Frame; stack.allocator = temp;
    table_set(*visited, entry, true);
    array_add(out, entry);
    array_add(*stack, .{entry, 0, block_num_successors(entry)});
    while stack.count {
        top := *stack[stack.count - 1];
        if top.next >= top.n { pop(*stack); continue; }
        t := block_terminator(top.b);
        s := get_successor(t, top.next);
        top.next += 1;
        if table_find_pointer(*visited, s) continue;
        table_set(*visited, s, true);
        array_add(out, s);
        array_add(*stack, .{s, 0, block_num_successors(s)});
    }
}

asan_fsp_visit :: (s: *Asan_Fsp, i: Value_Id) {
    o := inst_op(i);
    if o == {
        case .RET;
            ci := block_terminating_must_tail_call(inst(i).parent);
            array_add(*s.ret_vec, ifx ci != NONE then ci else i);
        case .RESUME; array_add(*s.ret_vec, i);
        case .CLEANUPRET; array_add(*s.ret_vec, i);
        case .ALLOCA;
            ty := inst(i).ty2;
            if !asan_is_interesting_alloca(s.a, i) || type_kind(ty) == .SVECTOR || (type_kind(ty) == .STRUCT && type_is_scalable(ty)) {
                if is_static_alloca(i) {
                    if s.alloca_vec.count == 0 return;
                    array_add(*s.static_allocas_to_move_up, i);
                }
                return;
            }
            if !is_static_alloca(i) array_add(*s.dynamic_alloca_vec, i);
            else array_add(*s.alloca_vec, i);
        case .CALL; #through;
        case .INVOKE; #through;
        case .CALLBR;
            id := call_iid(i);
            if id != NOT_INTRINSIC {
                asan_fsp_visit_intrinsic(s, i, id);
                // visitIntrinsicInst does not fall through to visitCallBase
                return;
            }
            if o == .CALL {
                s.has_inline_asm |= call_is_inline_asm(i) && i != s.a.local_dynamic_shadow;
                s.has_returns_twice_call |= call_has_fn_attr(i, .ReturnsTwice);
            }
    }
}

asan_fsp_visit_intrinsic :: (s: *Asan_Fsp, ii: Value_Id, id: Intrinsic_Id) {
    if id == IID_STACKRESTORE array_add(*s.stack_restore_vec, ii);
    if id == IID_LOCALESCAPE s.local_escape_call = ii;
    if !s.a.use_after_scope return;
    if id != IID_LIFETIME_START && id != IID_LIFETIME_END return;
    ai := op(ii, 0);
    if !is_inst(ai) || inst_op(ai) != .ALLOCA || !asan_is_interesting_alloca(s.a, ai) return;
    if type_is_scalable(inst(ai).ty2) return;
    ok, size := alloca_allocation_size(ai);
    if !ok return;
    if s.a.long_size < 64 && size >= ((cast(u64) 1) << s.a.long_size) return;
    apc := Asan_Poison_Call.{ii, ai, size, id == IID_LIFETIME_END};
    if is_static_alloca(ai) array_add(*s.static_poison_calls, apc);
    else if asan_cl.instrument_dynamic_allocas array_add(*s.dynamic_poison_calls, apc);
}

// FunctionStackPoisoner::initializeCallbacks
asan_fsp_initialize_callbacks :: (s: *Asan_Fsp) {
    v := ir.t_void; ip := s.intptr;
    a := s.a;
    if a.use_after_return == .ALWAYS || a.use_after_return == .RUNTIME {
        tmpl := ifx a.use_after_return == .ALWAYS then "__asan_stack_malloc_always_" else "__asan_stack_malloc_";
        for k: 0..ASAN_K_MAX_STACK_MALLOC_SIZE_CLASS {
            s.stack_malloc[k] = san_callee(tprint("%1%2", tmpl, k), ip, .[ip]);
            s.stack_free[k] = san_callee(tprint("__asan_stack_free_%", k), v, .[ip, ip]);
        }
    }
    if a.use_after_scope {
        s.poison_stack_memory = san_callee("__asan_poison_stack_memory", v, .[ip, ip]);
        s.unpoison_stack_memory = san_callee("__asan_unpoison_stack_memory", v, .[ip, ip]);
    }
    for val: u8.[0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0xf1, 0xf2, 0xf3, 0xf5, 0xf8] {
        s.set_shadow[val] = san_callee(tprint("__asan_set_shadow_%", formatInt(val, base = 16, minimum_digits = 2)), v, .[ip, ip]);
    }
    s.alloca_poison = san_callee("__asan_alloca_poison", v, .[ip, ip]);
    s.allocas_unpoison = san_callee("__asan_allocas_unpoison", v, .[ip, ip]);
}

// FunctionStackPoisoner::copyToShadowInline
asan_copy_to_shadow_inline :: (s: *Asan_Fsp, mask: [] u8, bytes: [] u8, begin: s64, end: s64, b: *Irb, shadow_base: Value_Id) {
    if begin >= end return;
    largest := min(8, cast(s64) s.a.long_size / 8);
    i := begin;
    while i < end {
        if !mask[i] { i += 1; continue; }
        store_size := largest;
        while store_size > end - i store_size /= 2;
        j := store_size - 1;
        while j > 0 && !mask[i + j] {
            while j <= store_size / 2 store_size /= 2;
            j -= 1;
        }
        val: u64 = 0;
        for k: 0..store_size-1 {
            if !dl.big_endian val |= (cast(u64) bytes[i + k]) << cast(u64)(8 * k);
            else val = (val << 8) | cast(u64) bytes[i + k];
        }
        p := irb_binop(b, .ADD, shadow_base, const_int(s.intptr, cast(u64) i));
        poison := const_int(type_int(cast(u64) store_size * 8), val);
        irb_store(b, poison, irb_cast(b, .INTTOPTR, p, type_ptr(0)), 1);
        i += store_size;
    }
}

// FunctionStackPoisoner::copyToShadow(Mask, Bytes, Begin, End, IRB, ShadowBase)
asan_copy_to_shadow :: (s: *Asan_Fsp, mask: [] u8, bytes: [] u8, begin: s64, end: s64, b: *Irb, shadow_base: Value_Id) {
    done := begin;
    i := begin; j := begin + 1;
    while i < end {
        defer { i = j; j += 1; }
        if !mask[i] continue;
        val := bytes[i];
        if s.set_shadow[val].callee == NONE continue;
        while j < end && mask[j] && val == bytes[j] j += 1;
        if cast(u64)(j - i) >= s.a.max_inline_poisoning_size {
            asan_copy_to_shadow_inline(s, mask, bytes, done, i, b, shadow_base);
            asan_rt_call(s.a, b, s.set_shadow[val], .[irb_binop(b, .ADD, shadow_base, const_int(s.intptr, cast(u64) i)), const_int(s.intptr, cast(u64)(j - i))]);
            done = j;
        }
    }
    asan_copy_to_shadow_inline(s, mask, bytes, done, end, b, shadow_base);
}
asan_copy_to_shadow_all :: (s: *Asan_Fsp, mask: [] u8, bytes: [] u8, b: *Irb, shadow_base: Value_Id) {
    asan_copy_to_shadow(s, mask, bytes, 0, mask.count, b, shadow_base);
}

asan_stack_malloc_size_class :: (size: u64) -> s64 {
    m: u64 = ASAN_K_MIN_STACK_MALLOC_SIZE;
    i := 0;
    while true { if size <= m return i; i += 1; m *= 2; }
    return -1;
}

// FunctionStackPoisoner::copyArgsPassedByValToAllocas
asan_fsp_copy_args_passed_by_val_to_allocas :: (s: *Asan_Fsp) {
    f := s.f;
    pt := block_first(fn_entry(f));
    if pt == s.a.local_dynamic_shadow pt = inst(pt).next;
    b: Irb; irb_set_before(*b, pt);
    for k: 0..cast(s64) glob(f).nargs - 1 {
        arg := fn_arg(f, cast(u32) k);
        if !fn_has_param_attr(f, cast(u32) k, .ByVal) continue;
        ty := attr_set_find(fn_param_attr_set(f, cast(u32) k), .ByVal).ty;
        pa := fn_param_align(f, cast(u32) k);
        align := ifx pa != 0 then pa else dl_abi_align(ty);
        name := ifx vname(arg).count then tconcat(vname(arg), ".byval") else tprint("Arg%.byval", k);
        ai := irb_alloca(*b, ty, NONE, name);
        inst(ai).align = align;
        rauw_with_metadata(arg, ai);
        sz := dl_type_alloc_size(ty);
        irb_memcpy(*b, ai, align, arg, align, const_int(type_int(64), sz), false);
    }
}

// FunctionStackPoisoner::createPHI
asan_fsp_create_phi :: (b: *Irb, cond: Value_Id, if_true: Value_Id, then_term: Value_Id, if_false: Value_Id) -> Value_Id {
    phi := irb_phi(b, vtype(if_true), 2);
    phi_add_incoming(phi, if_false, inst(cond).parent);
    phi_add_incoming(phi, if_true, inst(then_term).parent);
    return phi;
}

// FunctionStackPoisoner::createAllocaForLayout
asan_fsp_create_alloca_for_layout :: (b: *Irb, l: Asan_Frame_Layout, dynamic: bool) -> Value_Id {
    a: Value_Id;
    if dynamic a = irb_alloca(b, ir.t_i8, const_int(type_int(64), l.frame_size), "MyAlloca");
    else a = irb_alloca(b, type_array(l.frame_size, ir.t_i8), NONE, "MyAlloca");
    inst(a).align = max(l.frame_alignment, asan_cl.realign_stack);
    return a;
}

// FunctionStackPoisoner::createDynamicAllocasInitStorage
asan_fsp_create_dynamic_allocas_init_storage :: (s: *Asan_Fsp) {
    b: Irb; irb_set_before(*b, block_first(fn_entry(s.f)));
    s.dynamic_alloca_layout = irb_alloca(*b, s.intptr, NONE);
    irb_store(*b, const_null_value(s.intptr), s.dynamic_alloca_layout, dl_abi_align(s.intptr));
    inst(s.dynamic_alloca_layout).align = 32;
}

// FunctionStackPoisoner::unpoisonDynamicAllocasBeforeInst
asan_fsp_unpoison_dynamic_allocas_before :: (s: *Asan_Fsp, before: Value_Id, saved_stack: Value_Id) {
    b: Irb; irb_set_before(*b, before);
    area := irb_cast(*b, .PTRTOINT, saved_stack, s.intptr);
    if inst_op(before) != .RET {
        off := irb_intrinsic(*b, "llvm.get.dynamic.area.offset", .[s.intptr], .[]);
        area = irb_binop(*b, .ADD, irb_cast(*b, .PTRTOINT, saved_stack, s.intptr), off);
    }
    asan_rt_call(s.a, *b, s.allocas_unpoison, .[irb_load(*b, s.intptr, s.dynamic_alloca_layout, dl_abi_align(s.intptr)), area]);
}

// FunctionStackPoisoner::processDynamicAllocas
asan_fsp_process_dynamic_allocas :: (s: *Asan_Fsp) {
    if !asan_cl.instrument_dynamic_allocas || s.dynamic_alloca_vec.count == 0 return;
    for apc: s.dynamic_poison_calls {
        b: Irb; irb_set_before(*b, apc.ins_before);
        asan_fsp_poison_alloca(s, apc.ai, apc.size, *b, apc.do_poison);
    }
    asan_fsp_create_dynamic_allocas_init_storage(s);
    for s.dynamic_alloca_vec asan_fsp_handle_dynamic_alloca_call(s, it);
    for s.ret_vec asan_fsp_unpoison_dynamic_allocas_before(s, it, s.dynamic_alloca_layout);
    for s.stack_restore_vec asan_fsp_unpoison_dynamic_allocas_before(s, it, op(it, 0));
}

// findStoresToUninstrumentedArgAllocas
asan_find_stores_to_uninstrumented_arg_allocas :: (a: *Asan, ins_before: Value_Id, out: *[..] Value_Id) {
    it := inst(ins_before).next;
    while it != NONE {
        defer it = inst(it).next;
        o := inst_op(it);
        if o == .ALLOCA || is_cast_op(o) continue;
        if o == .STORE {
            al := op(it, 1);
            if !is_inst(al) || inst_op(al) != .ALLOCA || asan_is_interesting_alloca(a, al) continue;
            val := op(it, 0);
            direct := vkind(val) == .ARGUMENT;
            via_cast := is_inst(val) && is_cast_op(inst_op(val)) && vkind(op(val, 0)) == .ARGUMENT && val == inst(it).prev;
            if !direct && !via_cast continue;
            if via_cast array_add(out, val);
            array_add(out, it);
            continue;
        }
        return;
    }
}

// getAllocaName
asan_get_alloca_name :: (ai: Value_Id) -> string {
    ann := get_metadata(ai, md_kind_id("annotation"));
    if ann != NONE && ir.mds[ann].kind == .TUPLE {
        for k: 0..md_nops(ann)-1 {
            t := md_op(ann, cast(u32) k);
            if t == NONE || ir.mds[t].kind != .TUPLE continue;
            n := md_nops(t);
            for j: 0..n-1 {
                ms := md_op(t, cast(u32) j);
                if ir.mds[ms].str == "alloca_name_altered" return ir.mds[md_op(t, cast(u32) j + 1)].str;
            }
        }
    }
    return vname(ai);
}

// FunctionStackPoisoner::processStaticAllocas
asan_fsp_process_static_allocas :: (s: *Asan_Fsp) {
    if s.alloca_vec.count == 0 return;
    a := s.a;
    f := s.f;
    stack_malloc_idx := -1;
    entry_dl: Md_Id = NONE;
    sp := fn_subprogram(f);
    if sp != NONE entry_dl = di_location_get(di_int(sp, 1), 0, sp, NONE);
    ins_before := s.alloca_vec[0];
    b: Irb; irb_set_before(*b, ins_before);
    ins_before_b := inst(ins_before).parent;
    for s.static_allocas_to_move_up if inst(it).parent == ins_before_b inst_move_before_dbg(it, ins_before);
    arg_inits: [..] Value_Id; arg_inits.allocator = temp;
    asan_find_stores_to_uninstrumented_arg_allocas(a, ins_before, *arg_inits);
    for arg_inits inst_move_before_dbg(it, ins_before);
    if s.local_escape_call != NONE inst_move_before_dbg(s.local_escape_call, ins_before);

    svd: [..] Asan_Stack_Var; svd.allocator = temp;
    for ai: s.alloca_vec {
        ok, sz := alloca_allocation_size(ai);
        d: Asan_Stack_Var;
        d.name = asan_get_alloca_name(ai);
        d.size = sz;
        d.alignment = inst(ai).align;
        d.ai = ai;
        array_add(*svd, d);
    }
    granularity := (cast(u64) 1) << cast(u64) a.mapping.scale;
    min_header := max(a.long_size / 2, granularity);
    l := compute_asan_stack_frame_layout(*svd, granularity, min_header);
    svd_of :: (svd: [] Asan_Stack_Var, ai: Value_Id) -> s64 { for svd if it.ai == ai return it_index; return -1; }
    for apc: s.static_poison_calls {
        d := *svd[svd_of(svd, apc.ai)];
        d.lifetime_size = d.size;
        if entry_dl != NONE {
            ll := get_metadata(apc.ins_before, 0);
            if ll != NONE && discope_file(diloc_scope(ll)) == discope_file(diloc_scope(entry_dl)) {
                line := cast(u32) diloc_line(ll);
                if line d.line = min(ifx d.line then d.line else line, line);
            }
        }
    }
    desc := compute_asan_stack_frame_description(svd);
    local_stack_size := l.frame_size;
    do_stack_malloc := a.use_after_return != .NEVER && !a.compile_kernel && local_stack_size <= ASAN_K_MAX_STACK_MALLOC_SIZE;
    do_dynamic_alloca := asan_cl.dynamic_alloca_stack;
    do_dynamic_alloca &= !s.has_inline_asm && !s.has_returns_twice_call;
    do_stack_malloc &= !s.has_inline_asm && !s.has_returns_twice_call;

    pty := type_ptr(dl.alloca_as);
    static_alloca: Value_Id = NONE;
    if !do_dynamic_alloca static_alloca = asan_fsp_create_alloca_for_layout(*b, l, false);
    fake_stack_ptr, fake_stack_int, local_stack_base, local_stack_base_alloca: Value_Id;
    diexpr_flags: u32 = DIEXPR_APPLY_OFFSET;
    if do_stack_malloc {
        local_stack_base_alloca = irb_alloca(*b, s.intptr, NONE, "asan_local_stack_base");
        if a.use_after_return == .RUNTIME {
            opt := module_get_or_insert_global("__asan_option_detect_stack_use_after_return", ir.t_i32);
            enabled := irb_icmp(*b, ICMP_NE, irb_load(*b, ir.t_i32, opt, 4), const_null_value(ir.t_i32));
            term := sbi_if_then(enabled, ins_before, false);
            bif: Irb; irb_set_before(*bif, term);
            stack_malloc_idx = asan_stack_malloc_size_class(local_stack_size);
            fake_val := asan_rt_call(a, *bif, s.stack_malloc[stack_malloc_idx], .[const_int(s.intptr, local_stack_size)]);
            irb_set_before(*b, ins_before);
            fake_stack_int = asan_fsp_create_phi(*b, enabled, fake_val, term, const_int(s.intptr, 0));
        } else {
            stack_malloc_idx = asan_stack_malloc_size_class(local_stack_size);
            fake_stack_int = asan_rt_call(a, *b, s.stack_malloc[stack_malloc_idx], .[const_int(s.intptr, local_stack_size)]);
        }
        fake_stack_ptr = irb_cast(*b, .INTTOPTR, fake_stack_int, pty);
        no_fake := irb_icmp(*b, ICMP_EQ, fake_stack_int, const_null_value(s.intptr));
        term := sbi_if_then(no_fake, ins_before, false);
        bif: Irb; irb_set_before(*bif, term);
        alloca_value := ifx do_dynamic_alloca then asan_fsp_create_alloca_for_layout(*bif, l, true) else static_alloca;
        irb_set_before(*b, ins_before);
        local_stack_base = asan_fsp_create_phi(*b, no_fake, alloca_value, term, fake_stack_ptr);
        irb_store(*b, local_stack_base, local_stack_base_alloca, dl_abi_align(pty));
        diexpr_flags |= DIEXPR_DEREF_BEFORE;
    } else {
        fake_stack_int = const_null_value(s.intptr);
        fake_stack_ptr = const_null_value(pty);
        local_stack_base = ifx do_dynamic_alloca then asan_fsp_create_alloca_for_layout(*b, l, true) else static_alloca;
        local_stack_base_alloca = local_stack_base;
    }
    new_ptrs: [..] Value_Id; new_ptrs.allocator = temp;
    for d: svd {
        replace_dbg_declare(f, d.ai, local_stack_base_alloca, diexpr_flags, cast(s64) d.offset);
        np := irb_ptr_add(*b, local_stack_base, const_int(s.intptr, d.offset));
        rauw_with_metadata(d.ai, np);
        array_add(*new_ptrs, np);
    }
    irb_store(*b, const_int(s.intptr, ASAN_K_CURRENT_STACK_FRAME_MAGIC), local_stack_base, dl_abi_align(s.intptr));
    base_plus1 := irb_ptr_add(*b, local_stack_base, const_int(s.intptr, a.long_size / 8));
    desc_global := create_private_global_for_string(desc, true, tconcat(ASAN_GEN_PREFIX, "stack"));
    description := irb_pointer_cast(*b, desc_global, s.intptr);
    irb_store(*b, description, base_plus1, dl_abi_align(s.intptr));
    base_plus2 := irb_ptr_add(*b, local_stack_base, const_int(s.intptr, 2 * a.long_size / 8));
    irb_store(*b, irb_pointer_cast(*b, f, s.intptr), base_plus2, dl_abi_align(s.intptr));

    shadow_after_scope := get_shadow_bytes_after_scope(svd, l);
    shadow_base := asan_mem_to_shadow(a, irb_cast(*b, .PTRTOINT, local_stack_base, s.intptr), *b);
    asan_copy_to_shadow_all(s, shadow_after_scope, shadow_after_scope, *b, shadow_base);
    if s.static_poison_calls.count {
        shadow_in_scope := get_shadow_bytes(svd, l);
        for apc: s.static_poison_calls {
            d := svd[svd_of(svd, apc.ai)];
            begin := cast(s64)(d.offset / l.granularity);
            end := begin + cast(s64)((apc.size + l.granularity - 1) / l.granularity);
            bb: Irb; irb_set_before(*bb, apc.ins_before);
            asan_copy_to_shadow(s, shadow_after_scope, ifx apc.do_poison then shadow_after_scope else shadow_in_scope, begin, end, *bb, shadow_base);
        }
    }
    // Remove lifetime markers now that these are no longer allocas.
    for np: new_ptrs {
        u := ir.v_first_use[np];
        while u != NONE {
            usr := ir.u_user[u];
            u = ir.u_next[u];
            if is_inst(usr) && is_lifetime_start_or_end(usr) erase_inst(usr);
        }
    }
    shadow_clean := NewArray(shadow_after_scope.count, u8,, temp);
    shadow_after_return: [..] u8; shadow_after_return.allocator = temp;
    for ret: s.ret_vec {
        br: Irb; irb_set_before(*br, ret);
        irb_store(*br, const_int(s.intptr, ASAN_K_RETIRED_STACK_FRAME_MAGIC), local_stack_base, dl_abi_align(s.intptr));
        if do_stack_malloc {
            cmp := irb_icmp(*br, ICMP_NE, fake_stack_int, const_null_value(s.intptr));
            then_term, else_term := sbi_if_then_else(cmp, ret, true, false, true, false);
            bp: Irb; irb_set_before(*bp, then_term);
            if a.max_inline_poisoning_size != 0 && stack_malloc_idx <= 4 {
                class_size := (cast(u64) ASAN_K_MIN_STACK_MALLOC_SIZE) << cast(u64) stack_malloc_idx;
                n := cast(s64)(class_size / l.granularity);
                if shadow_after_return.count > n shadow_after_return.count = n;
                while shadow_after_return.count < n array_add(*shadow_after_return, ASAN_STACK_USE_AFTER_RETURN_MAGIC);
                asan_copy_to_shadow_all(s, shadow_after_return, shadow_after_return, *bp, shadow_base);
                saved_flag_ptr_ptr := irb_ptr_add(*bp, fake_stack_ptr, const_int(s.intptr, class_size - a.long_size / 8));
                saved_flag_ptr := irb_load(*bp, s.intptr, saved_flag_ptr_ptr, dl_abi_align(s.intptr));
                irb_store(*bp, const_null_value(ir.t_i8), irb_cast(*bp, .INTTOPTR, saved_flag_ptr, type_ptr(0)), 1);
            } else {
                asan_rt_call(a, *bp, s.stack_free[stack_malloc_idx], .[fake_stack_int, const_int(s.intptr, local_stack_size)]);
            }
            be: Irb; irb_set_before(*be, else_term);
            asan_copy_to_shadow_all(s, shadow_after_scope, shadow_clean, *be, shadow_base);
        } else {
            asan_copy_to_shadow_all(s, shadow_after_scope, shadow_clean, *br, shadow_base);
        }
    }
    for s.alloca_vec erase_inst(it);
}

// FunctionStackPoisoner::poisonAlloca
asan_fsp_poison_alloca :: (s: *Asan_Fsp, v: Value_Id, size: u64, b: *Irb, do_poison: bool) {
    addr := irb_pointer_cast(b, v, s.intptr);
    sz := const_int(s.intptr, size);
    asan_rt_call(s.a, b, ifx do_poison then s.poison_stack_memory else s.unpoison_stack_memory, .[addr, sz]);
}

// FunctionStackPoisoner::handleDynamicAllocaCall
asan_fsp_handle_dynamic_alloca_call :: (s: *Asan_Fsp, ai: Value_Id) {
    b: Irb; irb_set_before(*b, ai);
    alignment := max(cast(u64) ASAN_K_ALLOCA_RZ_SIZE, inst(ai).align);
    rz_mask := cast(u64) ASAN_K_ALLOCA_RZ_SIZE - 1;
    zero := const_null_value(s.intptr);
    rz_size := const_int(s.intptr, ASAN_K_ALLOCA_RZ_SIZE);
    rz_mask_c := const_int(s.intptr, rz_mask);
    old_size := irb_allocation_size(*b, s.intptr, ai);
    partial := irb_binop(*b, .AND, old_size, rz_mask_c);
    misalign := irb_binop(*b, .SUB, rz_size, partial);
    cond := irb_icmp(*b, ICMP_NE, misalign, rz_size);
    partial_padding := irb_select(*b, cond, misalign, zero);
    additional := irb_binop(*b, .ADD, const_int(s.intptr, alignment + ASAN_K_ALLOCA_RZ_SIZE), partial_padding);
    new_size := irb_binop(*b, .ADD, old_size, additional);
    new_alloca := irb_alloca(*b, ir.t_i8, new_size);
    inst(new_alloca).align = alignment;
    new_address := irb_binop(*b, .ADD, irb_cast(*b, .PTRTOINT, new_alloca, s.intptr), const_int(s.intptr, alignment));
    asan_rt_call(s.a, *b, s.alloca_poison, .[new_address, old_size]);
    irb_store(*b, irb_cast(*b, .PTRTOINT, new_alloca, s.intptr), s.dynamic_alloca_layout, dl_abi_align(s.intptr));
    new_address_ptr := irb_cast(*b, .INTTOPTR, new_address, vtype(ai));
    u := ir.v_first_use[ai];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if is_inst(usr) && is_lifetime_start_or_end(usr) erase_inst(usr);
    }
    rauw_with_metadata(ai, new_address_ptr);
    erase_inst(ai);
}

// IRBuilder::CreateAllocationSize(DestTy, AI)
irb_allocation_size :: (b: *Irb, dest_ty: Type_Id, ai: Value_Id) -> Value_Id {
    ty := inst(ai).ty2;
    size := irb_type_size(b, dest_ty, dl_type_alloc_size(ty), type_is_scalable(ty));
    n := op(ai, 0);
    if !(vkind(n) == .C_INT && const_int_zext(n) == 1) {
        nn := irb_zext_or_trunc_any(b, n, dest_ty);
        size = irb_binop(b, .MUL, nn, size);
    }
    return size;
}

// ---------------------------------------------------------------- ModuleAddressSanitizer

Asan_Module :: struct {
    compile_kernel: bool;
    insert_version_check: bool;
    recover: bool;
    use_globals_gc: bool;
    use_private_alias: bool;
    use_odr_indicator: bool;
    use_ctor_comdat: bool;
    destructor_kind: Asan_Dtor_Kind;
    constructor_kind: Asan_Ctor_Kind;
    intptr: Type_Id;
    mapping: Asan_Mapping;
    poison_globals, unpoison_globals, register_globals, unregister_globals: San_Callee;
    register_image_globals, unregister_image_globals, register_elf_globals, unregister_elf_globals: San_Callee;
    ctor: Value_Id = NONE;
    dtor: Value_Id = NONE;
    module_name: Value_Id = NONE;
}

asan_module_initialize_callbacks :: (m: *Asan_Module) {
    v := ir.t_void; ip := m.intptr;
    m.poison_globals = san_callee("__asan_before_dynamic_init", v, .[ip]);
    m.unpoison_globals = san_callee("__asan_after_dynamic_init", v, .[]);
    m.register_globals = san_callee("__asan_register_globals", v, .[ip, ip]);
    m.unregister_globals = san_callee("__asan_unregister_globals", v, .[ip, ip]);
    m.register_image_globals = san_callee("__asan_register_image_globals", v, .[ip]);
    m.unregister_image_globals = san_callee("__asan_unregister_image_globals", v, .[ip]);
    m.register_elf_globals = san_callee("__asan_register_elf_globals", v, .[ip, ip, ip]);
    m.unregister_elf_globals = san_callee("__asan_unregister_elf_globals", v, .[ip, ip, ip]);
}

asan_module_get_or_create_module_name :: (m: *Asan_Module) -> Value_Id {
    if m.module_name == NONE m.module_name = create_private_global_for_string(ir.module_id, false, tconcat(ASAN_GEN_PREFIX, "module"));
    return m.module_name;
}

// GlobalWasGeneratedByCompiler
asan_global_was_generated_by_compiler :: (g: Value_Id) -> bool {
    n := vname(g);
    if begins_with(n, "llvm.") || begins_with(n, "__llvm_gcov_ctr") || begins_with(n, "__llvm_rtti_proxy") return true;
    if begins_with(n, ASAN_GEN_PREFIX) || begins_with(n, "__sancov_gen_") || begins_with(n, "__odr_asan_gen_") return true;
    return false;
}

// GlobalValue::hasExactDefinition: a definition that can't be replaced at link time (not weak / linkonce /
// available_externally / extern_weak / common)
gv_has_exact_definition :: (g: Value_Id) -> bool {
    if is_declaration(g) return false;
    l := glob(g).linkage;
    return !(l == .AVAILABLE_EXTERNALLY || l == .LINKONCE_ANY || l == .LINKONCE_ODR || l == .WEAK_ANY || l == .WEAK_ODR ||
             l == .EXTERN_WEAK || l == .COMMON);
}

// ModuleAddressSanitizer::shouldInstrumentGlobal
asan_should_instrument_global :: (m: *Asan_Module, g: Value_Id) -> bool {
    gr := glob(g);
    ty := gr.value_type;
    if gr.sanitizer & 1 return false;
    if !type_is_sized(ty) return false;
    if !gr.has_init return false;
    if !asan_is_supported_addrspace(g) return false;
    if asan_global_was_generated_by_compiler(g) return false;
    if gr.tls return false;
    if gr.align && gr.align > asan_redzone_size_for_scale(m.mapping.scale) return false;
    if !san_triple_is_coff() {
        if !gv_has_exact_definition(g) || gr.comdat >= 0 return false;
    } else {
        if gv_is_interposable(g) return false;
        if gr.linkage == .AVAILABLE_EXTERNALLY return false;
    }
    if gr.comdat >= 0 {
        k := ir.comdats[gr.comdat].kind;
        if k == 2 || k == 4 return false;   // Largest / SameSize
    }
    if gr.section.count {
        if m.compile_kernel return false;
        sec := gr.section;
        if sec == "llvm.metadata" return false;
        if find_index_from_left(sec, "__llvm") >= 0 || find_index_from_left(sec, "__LLVM") >= 0 return false;
        if begins_with(sec, ".preinit_array") || begins_with(sec, ".init_array") || begins_with(sec, ".fini_array") return false;
        if san_triple_is_elf() {
            all := true;
            for c: cast([] u8) sec if !(c_isalnum(c) || c == #char "_") { all = false; break; }
            if all return false;
        }
        if san_triple_is_coff() && find_index_from_left(sec, "$") >= 0 return false;
        if san_triple_is_macho() {
            segment, section, type := san_parse_macho_section(sec);
            if segment == "__OBJC" || (segment == "__DATA" && begins_with(section, "__objc_")) return false;
            if segment == "__DATA" && section == "__cfstring" return false;
            if segment == "__TEXT" && type == "cstring_literals" return false;
        }
    }
    if m.compile_kernel && begins_with(vname(g), "__") return false;
    return true;
}

// ModuleAddressSanitizer::getRedzoneSizeForGlobal
asan_redzone_size_for_global :: (m: *Asan_Module, size: u64) -> u64 {
    MAX_RZ :: cast(u64) 1 << 18;
    min_rz := asan_redzone_size_for_scale(m.mapping.scale);
    rz: u64;
    if size <= min_rz / 2 rz = min_rz - size;
    else {
        rz = min(max((size / min_rz / 4) * min_rz, min_rz), MAX_RZ);
        if size % min_rz rz += min_rz - (size % min_rz);
    }
    return rz;
}

// ModuleAddressSanitizer::getGlobalMetadataSection
asan_global_metadata_section :: () -> string {
    if san_triple_is_coff() return ".ASAN$GL";
    if san_triple_is_elf() return "asan_globals";
    if san_triple_is_macho() return "__DATA,__asan_globals,regular";
    fatal("ModuleAddressSanitizer not implemented for object file format");
    return "";
}

// ModuleAddressSanitizer::CreateMetadataGlobal
asan_create_metadata_global :: (init: Value_Id, original_name: string) -> Value_Id {
    linkage := ifx san_triple_is_macho() then Linkage.INTERNAL else .PRIVATE;
    n := original_name;
    if n.count && n[0] == 1 n = slice(n, 1, n.count - 1);   // dropLLVMManglingEscape
    md := gv_create(vtype(init), false, linkage, init, tconcat("__asan_global_", n), NONE, 0, dl.globals_as);
    glob(md).section = asan_global_metadata_section();
    set_global_variable_large_section(md);
    return md;
}

// ModuleAddressSanitizer::SetComdatForGlobalMetadata
asan_set_comdat_for_global_metadata :: (g: Value_Id, md: Value_Id, internal_suffix: string) {
    c := glob(g).comdat;
    if c < 0 {
        if vname(g).count == 0 set_name(g, tconcat(ASAN_GEN_PREFIX, "anon_global"));
        if internal_suffix.count && gv_has_local_linkage(g) c = get_comdat(tconcat(vname(g), internal_suffix));
        else c = get_comdat(vname(g));
        if san_triple_is_coff() {
            ir.comdats[c].kind = 3;   // NoDeduplicate
            if glob(g).linkage == .PRIVATE gv_set_linkage(g, .INTERNAL);
        }
        glob(g).comdat = c;
    }
    glob(md).comdat = glob(g).comdat;
}

// ModuleAddressSanitizer::CreateAsanModuleDtor: the dtor's return instruction
asan_create_module_dtor :: (m: *Asan_Module) -> Value_Id {
    m.dtor = fn_create_with_default_attr(type_func(ir.t_void, .[], false), .INTERNAL, "asan.module_dtor", 0);
    fn_add_fn_attr_kind(m.dtor, .NoUnwind);
    append_to_used(m.dtor);
    bb := create_block(m.dtor, "");
    r := new_inst(.RET, ir.t_void, 0);
    block_append_inst(bb, r);
    return r;
}

// ModuleAddressSanitizer::instrumentGlobalsELF
asan_instrument_globals_elf :: (m: *Asan_Module, b: *Irb, globals: [] Value_Id, inits: [] Value_Id, unique_module_id: string) {
    use_comdat := m.use_odr_indicator && unique_module_id.count > 0;
    mds: [..] Value_Id; mds.allocator = temp;
    assoc := md_kind_id("associated");
    for g, i: globals {
        md := asan_create_metadata_global(inits[i], vname(g));
        set_metadata(md, assoc, md_tuple(.[md_value(g)], false));
        array_add(*mds, md);
        if use_comdat asan_set_comdat_for_global_metadata(g, md, unique_module_id);
    }
    if mds.count mu_append_to_used_list("llvm.compiler.used", mds);
    ip := m.intptr;
    flag := gv_create(ip, false, .COMMON, const_int(ip, 0), "___asan_globals_registered", NONE, 0, dl.globals_as);
    gv_set_visibility(flag, 1);
    sec := asan_global_metadata_section();
    start := gv_create(ip, false, .EXTERN_WEAK, NONE, tconcat("__start_", sec), NONE, 0, dl.globals_as);
    gv_set_visibility(start, 1);
    stop := gv_create(ip, false, .EXTERN_WEAK, NONE, tconcat("__stop_", sec), NONE, 0, dl.globals_as);
    gv_set_visibility(stop, 1);
    if m.constructor_kind == .GLOBAL
        san_call(b, m.register_elf_globals, .[irb_pointer_cast(b, flag, ip), irb_pointer_cast(b, start, ip), irb_pointer_cast(b, stop, ip)]);
    if m.destructor_kind != .NONE && mds.count {
        bd: Irb; irb_set_before(*bd, asan_create_module_dtor(m));
        san_call(*bd, m.unregister_elf_globals, .[irb_pointer_cast(b, flag, ip), irb_pointer_cast(b, start, ip), irb_pointer_cast(b, stop, ip)]);
    }
}

// ModuleAddressSanitizer::InstrumentGlobalsCOFF
asan_instrument_globals_coff :: (m: *Asan_Module, b: *Irb, globals: [] Value_Id, inits: [] Value_Id) {
    mds: [..] Value_Id; mds.allocator = temp;
    assoc := md_kind_id("associated");
    for g, i: globals {
        md := asan_create_metadata_global(inits[i], vname(g));
        set_metadata(md, assoc, md_tuple(.[md_value(g)], false));
        array_add(*mds, md);
        glob(md).align = dl_type_alloc_size(vtype(inits[i]));
        asan_set_comdat_for_global_metadata(g, md, "");
    }
    if mds.count mu_append_to_used_list("llvm.compiler.used", mds);
}

// ModuleAddressSanitizer::InstrumentGlobalsMachO
asan_instrument_globals_macho :: (m: *Asan_Module, b: *Irb, globals: [] Value_Id, inits: [] Value_Id) {
    ip := m.intptr;
    lty := type_literal_struct(.[ip, ip], false);
    lgs: [..] Value_Id; lgs.allocator = temp;
    for g, i: globals {
        md := asan_create_metadata_global(inits[i], vname(g));
        binder := const_aggregate(.C_STRUCT, lty, .[op(inits[i], 0), san_ce_pointer_cast(md, ip)]);
        lv := gv_create(lty, false, .INTERNAL, binder, tconcat("__asan_binder_", vname(g)), NONE, 0, dl.globals_as);
        glob(lv).section = "__DATA,__asan_liveness,regular,live_support";
        array_add(*lgs, lv);
    }
    if lgs.count mu_append_to_used_list("llvm.compiler.used", lgs);
    flag := gv_create(ip, false, .COMMON, const_int(ip, 0), "___asan_globals_registered", NONE, 0, dl.globals_as);
    gv_set_visibility(flag, 1);
    if m.constructor_kind == .GLOBAL san_call(b, m.register_image_globals, .[irb_pointer_cast(b, flag, ip)]);
    if m.destructor_kind != .NONE {
        bd: Irb; irb_set_before(*bd, asan_create_module_dtor(m));
        san_call(*bd, m.unregister_image_globals, .[irb_pointer_cast(b, flag, ip)]);
    }
}

// ModuleAddressSanitizer::ShouldUseMachOGlobalsSection
asan_should_use_macho_globals_section :: () -> bool {
    if !san_triple_is_macho() return false;
    t := san_triple();
    if triple_is_macosx(*t) && !triple_is_macosx_version_lt(*t, 10, 11) return true;
    if triple_is_ios(*t) && !triple_is_os_version_lt(*t, 9) return true;
    if t.os == .WatchOS && !triple_is_os_version_lt(*t, 2) return true;
    if t.os == .DriverKit return true;
    if t.os == .XROS return true;
    return false;
}

// MCSectionMachO::ParseSectionSpecifier: segment, section and section type (the attributes are not needed)
san_parse_macho_section :: (spec: string) -> (string, string, string) {
    parts := split(spec, ",",, temp);
    tr :: (s: string) -> string { return trim(s); }
    seg := ifx parts.count > 0 then tr(parts[0]) else "";
    sec := ifx parts.count > 1 then tr(parts[1]) else "";
    typ := ifx parts.count > 2 then tr(parts[2]) else "";
    return seg, sec, typ;
}

// ConstantDataSequential::isCString: i8 elements, the last is 0 and no other is
san_is_c_string :: (c: Value_Id) -> bool {
    if vkind(c) != .C_DATA return false;
    t := vtype(c);
    if type_kind(t) != .ARRAY || type_elem(t) != ir.t_i8 return false;
    n := const_data_count(c);
    if n == 0 || const_data_elt(c, n - 1) != 0 return false;
    for k: 0..cast(s64) n - 2 if const_data_elt(c, cast(u64) k) == 0 return false;
    return true;
}


// ModuleAddressSanitizer::InstrumentGlobalsWithMetadataArray
asan_instrument_globals_with_metadata_array :: (m: *Asan_Module, b: *Irb, globals: [] Value_Id, inits: [] Value_Id) {
    n := cast(u64) globals.count;
    at := type_array(n, vtype(inits[0]));
    all := gv_create(at, false, .INTERNAL, const_aggregate(.C_ARRAY, at, inits), "", NONE, 0, dl.globals_as);
    if m.mapping.scale > 3 glob(all).align = (cast(u64) 1) << cast(u64) m.mapping.scale;
    ip := m.intptr;
    if m.constructor_kind == .GLOBAL
        san_call(b, m.register_globals, .[irb_pointer_cast(b, all, ip), const_int(ip, n)]);
    if m.destructor_kind != .NONE {
        bd: Irb; irb_set_before(*bd, asan_create_module_dtor(m));
        san_call(*bd, m.unregister_globals, .[irb_pointer_cast(b, all, ip), const_int(ip, n)]);
    }
}

// ModuleAddressSanitizer::instrumentGlobals
asan_instrument_globals :: (m: *Asan_Module, b: *Irb) -> bool {
    ctor_comdat := true;
    exclusions: [..] Value_Id; exclusions.allocator = temp;
    if m.compile_kernel {
        for ga: ir.m_aliases {
            if !begins_with(vname(ga), "__") continue;
            x := strip_pointer_casts_and_aliases(op(ga, 0));
            if vkind(x) == .GLOBAL_VAR array_add(*exclusions, x);
        }
    }
    to_change: [..] Value_Id; to_change.allocator = temp;
    for g: ir.m_globals if !array_find(exclusions, g) && asan_should_instrument_global(m, g) array_add(*to_change, g);
    n := to_change.count;
    ip := m.intptr;
    gst := type_literal_struct(.[ip, ip, ip, ip, ip, ip, ip, ip], false);
    new_globals: [..] Value_Id; new_globals.allocator = temp;
    inits: [..] Value_Id; inits.allocator = temp;
    for g: to_change {
        gr := glob(g);
        is_dyn_init := (gr.sanitizer & 8) != 0;
        name_for_global := copy_string(vname(g),, temp);
        name := create_private_global_for_string(llvm_demangle(name_for_global), true, tconcat(ASAN_GEN_PREFIX, "global"));
        ty := glob(g).value_type;
        size := dl_type_alloc_size(ty);
        rz := asan_redzone_size_for_global(m, size);
        rz_ty := type_array(rz, ir.t_i8);
        new_ty := type_literal_struct(.[ty, rz_ty], false);
        new_init := const_aggregate(.C_STRUCT, new_ty, .[gv_initializer(g), const_null_value(rz_ty)]);
        linkage := glob(g).linkage;
        if glob(g).is_const && linkage == .PRIVATE linkage = .INTERNAL;
        ng := gv_create(new_ty, glob(g).is_const, linkage, new_init, "", g, glob(g).tls, glob(g).addrspace);
        gv_copy_attributes_from(ng, g);
        glob(ng).comdat = glob(g).comdat;
        glob(ng).align = asan_redzone_size_for_scale(m.mapping.scale);
        glob(ng).unnamed_addr = 0;
        if san_triple_is_macho() && glob(g).section.count == 0 && glob(g).is_const && san_is_c_string(gv_initializer(g))
            glob(ng).section = "__TEXT,__asan_cstring,regular";
        all: [..] Kind_Md; all.allocator = temp;
        get_all_metadata(g, *all);
        for all add_metadata(ng, it.kind, it.md);
        ipo_rauw(g, ng);
        gv_take_name(ng, g);
        gv_erase_from_parent(g);
        array_add(*new_globals, ng);
        odr := const_null_value(ip);
        instrumented := ng;
        can_use_private_aliases := san_triple_is_elf() || san_triple_is_macho() || san_triple_is_wasm();
        if can_use_private_aliases && m.use_private_alias instrumented = san_create_private_alias(ng);
        if gv_has_local_linkage(ng) {
            odr = cf_all_ones(ip);
        } else if m.use_odr_indicator {
            sym := gv_create(ir.t_i8, false, linkage, const_null_value(ir.t_i8), tconcat("__odr_asan_gen_", name_for_global), NONE, glob(ng).tls, dl.globals_as);
            gv_set_visibility(sym, glob(ng).visibility);
            glob(sym).dll = glob(ng).dll;
            glob(sym).align = 1;
            odr = ce_cast(.PTRTOINT, sym, ip);
        }
        init := const_aggregate(.C_STRUCT, gst, .[
            san_ce_pointer_cast(instrumented, ip), const_int(ip, size), const_int(ip, size + rz),
            san_ce_pointer_cast(name, ip), san_ce_pointer_cast(asan_module_get_or_create_module_name(m), ip),
            const_int(ip, cast(u64) is_dyn_init), const_null_value(ip), odr]);
        array_add(*inits, init);
    }
    used: [..] Value_Id; used.allocator = temp;
    for new_globals if vname(it).count array_add(*used, it);
    mu_append_to_used_list("llvm.compiler.used", used);
    if m.use_globals_gc && san_triple_is_elf() {
        ctor_comdat = true;
        asan_instrument_globals_elf(m, b, new_globals, inits, get_unique_module_id());
    } else if n == 0 {
        ctor_comdat = san_triple_is_elf();
    } else {
        ctor_comdat = false;
        if m.use_globals_gc && san_triple_is_coff() asan_instrument_globals_coff(m, b, new_globals, inits);
        else if m.use_globals_gc && asan_should_use_macho_globals_section() asan_instrument_globals_macho(m, b, new_globals, inits);
        else asan_instrument_globals_with_metadata_array(m, b, new_globals, inits);
    }
    if asan_cl.initializers asan_create_initializer_poison_calls(m);
    return ctor_comdat;
}

// GlobalAlias::create(PrivateLinkage, "", Aliasee): appended to the alias list
san_create_private_alias :: (aliasee: Value_Id) -> Value_Id {
    ga := new_global(.ALIAS, glob(aliasee).value_type, glob(aliasee).addrspace, 1);
    set_op(ga, 0, aliasee);
    gv_set_linkage(ga, .PRIVATE);
    array_add(*ir.m_aliases, ga);
    return ga;
}

// ModuleAddressSanitizer::createInitializerPoisonCalls
asan_create_initializer_poison_calls :: (m: *Asan_Module) {
    gv := module_get_global_variable("llvm.global_ctors");
    if gv == NONE || !glob(gv).has_init return;
    ca := gv_initializer(gv);
    if vkind(ca) != .C_ARRAY return;
    for k: 0..nops(ca)-1 {
        e := op(ca, k);
        if vkind(e) == .C_ZERO continue;
        f := op(e, 1);
        if vkind(f) != .FUNCTION continue;
        if vname(f) == "asan.module_ctor" continue;
        if const_int_zext(op(e, 0)) <= 1 continue;
        asan_poison_one_initializer(m, f);
    }
}

// ModuleAddressSanitizer::poisonOneInitializer
asan_poison_one_initializer :: (m: *Asan_Module, f: Value_Id) {
    entry := fn_entry(f);
    b: Irb; irb_set_at(*b, entry, block_first_insertion_pt(entry), false);
    name_addr := san_ce_pointer_cast(asan_module_get_or_create_module_name(m), m.intptr);
    san_call(*b, m.poison_globals, .[name_addr]);
    for bb: fn_blocks(f) {
        t := block_terminator(bb);
        if t != NONE && inst_op(t) == .RET san_call_before(m.unpoison_globals, .[], t);
    }
}

// ModuleAddressSanitizer::instrumentModule
asan_instrument_module :: (m: *Asan_Module) -> bool {
    asan_module_initialize_callbacks(m);
    for f: ir.m_functions remove_asan_incompatible_fn_attributes(f, false);
    if m.constructor_kind == .GLOBAL {
        if m.compile_kernel m.ctor = create_sanitizer_ctor("asan.module_ctor");
        else {
            vc := ifx m.insert_version_check then "__asan_version_mismatch_check_v8" else "";
            m.ctor = create_sanitizer_ctor_and_init_functions("asan.module_ctor", "__asan_init", .[], .[], vc);
        }
    }
    ctor_comdat := true;
    if asan_cl.globals {
        b: Irb;
        if m.ctor != NONE irb_set_before(*b, block_terminator(fn_entry(m.ctor)));
        ctor_comdat = asan_instrument_globals(m, *b);
    }
    priority: s64 = 1;
    if m.use_ctor_comdat && san_triple_is_elf() && ctor_comdat {
        if m.ctor != NONE {
            glob(m.ctor).comdat = get_comdat("asan.module_ctor");
            append_to_global_ctors(m.ctor, priority, m.ctor);
        }
        if m.dtor != NONE {
            glob(m.dtor).comdat = get_comdat("asan.module_dtor");
            append_to_global_dtors(m.dtor, priority, m.dtor);
        }
    } else {
        if m.ctor != NONE append_to_global_ctors(m.ctor, priority);
        if m.dtor != NONE append_to_global_dtors(m.dtor, priority);
    }
    return true;
}

// ---------------------------------------------------------------- AddressSanitizerPass::run

asan_run :: (name: string) -> Preserved {
    compile_kernel := false; use_after_scope := false;
    if name != "asan" {
        if !begins_with(name, "asan<") || name[name.count - 1] != #char ">" fatal("unknown pass name '%'", name);
        params := slice(name, 5, name.count - 6);
        for p: split(params, ";",, temp) {
            if p.count == 0 continue;
            if p == "kernel" compile_kernel = true;
            else if p == "use-after-scope" use_after_scope = true;
            else fatal("invalid AddressSanitizer pass parameter '%'", p);
        }
    }
    if check_if_already_instrumented("nosanitize_address") return PRESERVE_ALL;
    long_size := dl_ptr_spec(0).bits;
    intptr := type_int(long_size);
    // ModuleAddressSanitizer(M, InsertVersionCheck = true, CompileKernel, Recover = false, UseGlobalsGC = true,
    // UseOdrIndicator = true, DestructorKind = Global, ConstructorKind = Global)
    m: Asan_Module;
    m.compile_kernel = ifx asan_cl.kasan_set then asan_cl.kasan else compile_kernel;
    m.insert_version_check = ifx asan_cl.insert_version_check_set then asan_cl.insert_version_check else true;
    m.recover = ifx asan_cl.recover_set then asan_cl.recover else false;
    m.use_globals_gc = asan_cl.use_globals_gc && !m.compile_kernel;
    m.use_private_alias = ifx asan_cl.use_private_alias_set then asan_cl.use_private_alias else true;
    m.use_odr_indicator = ifx asan_cl.use_odr_indicator_set then asan_cl.use_odr_indicator else true;
    m.use_ctor_comdat = asan_cl.with_comdat && !m.compile_kernel;
    m.destructor_kind = .GLOBAL;
    m.constructor_kind = ifx asan_cl.constructor_kind_set then asan_cl.constructor_kind else .GLOBAL;
    m.intptr = intptr;
    m.mapping = asan_get_shadow_mapping(long_size, m.compile_kernel);
    if asan_cl.override_destructor_kind != .INVALID m.destructor_kind = asan_cl.override_destructor_kind;

    ssgi: *Stack_Safety_Global = null;
    ss: Stack_Safety_Global;
    if asan_cl.use_stack_safety { ssgi = *ss; stack_safety_global_init(ssgi); }
    modified := false;
    fns: [..] Value_Id; fns.allocator = temp;
    for ir.m_functions array_add(*fns, it);
    for f: fns {
        if is_declaration(f) continue;
        if glob(f).linkage == .AVAILABLE_EXTERNALLY continue;
        if asan_cl.debug_func.count && asan_cl.debug_func == vname(f) continue;
        if begins_with(vname(f), "__asan_") continue;
        if fn_has_fn_attr(f, .PresplitCoroutine) continue;
        a: Asan;
        a.compile_kernel = ifx asan_cl.kasan_set then asan_cl.kasan else compile_kernel;
        a.recover = ifx asan_cl.recover_set then asan_cl.recover else false;
        a.use_after_scope = use_after_scope || asan_cl.use_after_scope;
        a.use_after_return = ifx asan_cl.use_after_return_set then asan_cl.use_after_return else .RUNTIME;
        a.ssgi = ssgi;
        a.calls_threshold = ifx asan_cl.calls_threshold_set then asan_cl.calls_threshold else 7000;
        a.max_inline_poisoning_size = cast(u64)(ifx asan_cl.max_inline_poisoning_size_set then asan_cl.max_inline_poisoning_size else 64);
        a.long_size = long_size;
        a.intptr = intptr;
        a.mapping = asan_get_shadow_mapping(long_size, a.compile_kernel);
        a.processed_allocas.allocator = temp;
        a.rtci_calls.allocator = temp;
        if asan_instrument_function(*a, f, tli_for(f)) modified = true;
    }
    if asan_instrument_module(*m) modified = true;
    printer_note_ir_changed();
    if !modified return PRESERVE_ALL;
    return PRESERVE_NONE;
}
