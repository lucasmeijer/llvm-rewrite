// MemProf instrumentation: `memprof` (MemProfilerPass, function) and `memprof-module` (ModuleMemProfilerPass).
// Ported from llvm/lib/Transforms/Instrumentation/MemProfInstrumentation.cpp.

memprof_cl: struct {
    insert_version_check := true;          // -memprof-guard-against-version-mismatch
    instrument_reads := true;              // -memprof-instrument-reads
    instrument_writes := true;             // -memprof-instrument-writes
    instrument_atomics := true;            // -memprof-instrument-atomics
    use_calls := false;                    // -memprof-use-callbacks
    callback_prefix := "__memprof_";       // -memprof-memory-access-callback-prefix
    mapping_scale: s64 = 3;                // -memprof-mapping-scale (DefaultShadowScale)
    mapping_granularity: s64 = 64;         // -memprof-mapping-granularity (DefaultMemGranularity)
    instrument_stack := false;             // -memprof-instrument-stack
    debug_func := "";                      // -memprof-debug-func
    debug_min: s64 = -1;                   // -memprof-debug-min
    debug_max: s64 = -1;                   // -memprof-debug-max
    histogram := false;                    // -memprof-histogram
    runtime_default_options := "";         // -memprof-runtime-default-options
};

MEMPROF_VERSION :: 1;
MEMPROF_HISTOGRAM_GRANULARITY :: 8;

Memprof_Access :: struct {
    addr: Value_Id = NONE;
    is_write: bool;
    access_ty: Type_Id;
    mask: Value_Id = NONE;
}

Mem_Profiler :: struct {
    intptr_ty: Type_Id;
    scale: s64;
    granularity: s64;
    mask: u64;
    access_cb: [2] Value_Id;   // indexed by AccessIsWrite
    memmove, memcpy, memset: Value_Id;
    dynamic_shadow_offset: Value_Id = NONE;
}

// getInstrProfSectionName(IPSK_cnts, OF, AddSegmentInfo = false)
instrprof_cnts_section_name :: (obj: Triple_Object_Format) -> string {
    if obj == .COFF return ".lprfc$M";
    return "__llvm_prf_cnts";
}

// MemProfiler::isInterestingMemoryAccess
mp_is_interesting :: (mp: *Mem_Profiler, i: Value_Id) -> (bool, Memprof_Access) {
    a: Memprof_Access;
    if mp.dynamic_shadow_offset == i return false, a;
    o := inst_op(i);
    if o == .LOAD {
        if !memprof_cl.instrument_reads return false, a;
        a.is_write = false; a.access_ty = vtype(i); a.addr = op(i, 0);
    } else if o == .STORE {
        if !memprof_cl.instrument_writes return false, a;
        a.is_write = true; a.access_ty = vtype(op(i, 0)); a.addr = op(i, 1);
    } else if o == .ATOMICRMW {
        if !memprof_cl.instrument_atomics return false, a;
        a.is_write = true; a.access_ty = vtype(op(i, 1)); a.addr = op(i, 0);
    } else if o == .CMPXCHG {
        if !memprof_cl.instrument_atomics return false, a;
        a.is_write = true; a.access_ty = vtype(op(i, 1)); a.addr = op(i, 0);
    } else if o == .CALL {
        id := fn_iid(call_called_function(i));
        if id == IID_MASKED_LOAD || id == IID_MASKED_STORE {
            off: u32 = 0;
            if id == IID_MASKED_STORE {
                if !memprof_cl.instrument_writes return false, a;
                off = 1;
                a.access_ty = vtype(op(i, 0));
                a.is_write = true;
            } else {
                if !memprof_cl.instrument_reads return false, a;
                a.access_ty = vtype(i);
                a.is_write = false;
            }
            a.mask = op(i, 1 + off);
            a.addr = op(i, 0 + off);
        }
    }
    if a.addr == NONE return false, a;
    pt := scalar_type(vtype(a.addr));
    if ir.types[pt].a != 0 return false, a;
    if is_swift_error(a.addr) return false, a;
    base := strip_in_bounds_offsets(a.addr);
    if vkind(base) == .GLOBAL_VAR {
        sec := glob(base).section;
        if sec.count {
            t := triple_parse(ir.triple);
            if ends_with(sec, instrprof_cnts_section_name(t.obj)) return false, a;
        }
        if begins_with(vname(base), "__llvm") || begins_with(vname(base), "__prof") return false, a;
    }
    return true, a;
}

// MemProfiler::memToShadow
mp_mem_to_shadow :: (mp: *Mem_Profiler, shadow_in: Value_Id, b: *Irb) -> Value_Id {
    s := irb_binop(b, .AND, shadow_in, const_int_words(vtype(shadow_in), .[mp.mask, 0]));   // ConstantInt::get(Ty, uint64_t): zero-extended
    s = irb_binop(b, .LSHR, s, const_int(vtype(s), cast(u64) mp.scale));
    return irb_binop(b, .ADD, s, mp.dynamic_shadow_offset);
}

// MemProfiler::instrumentAddress
mp_instrument_address :: (mp: *Mem_Profiler, insert_before: Value_Id, addr: Value_Id, is_write: bool) {
    b: Irb;
    irb_set_before(*b, insert_before);
    addr_long := irb_cast(*b, .PTRTOINT, addr, mp.intptr_ty);
    if memprof_cl.use_calls {
        irb_call(*b, mp.access_cb[ifx is_write then 1 else 0], .[addr_long]);
        return;
    }
    shadow_ty := ifx memprof_cl.histogram then ir.t_i8 else ir.t_i64;
    shadow_ptr := mp_mem_to_shadow(mp, addr_long, *b);
    shadow_addr := irb_cast(*b, .INTTOPTR, shadow_ptr, type_ptr(0));
    shadow_value := irb_load(*b, shadow_ty, shadow_addr, dl_alignment(shadow_ty, true));
    if memprof_cl.histogram {
        cmp := irb_icmp(*b, ICMP_ULT, shadow_value, const_int(ir.t_i8, 255));
        inc_block := mu_split_block_and_insert_if_then(cmp, insert_before, false);
        irb_set_before(*b, inc_block);
    }
    shadow_value = irb_binop(*b, .ADD, shadow_value, const_int(shadow_ty, 1));
    irb_store(*b, shadow_value, shadow_addr, dl_alignment(shadow_ty, true));
}

// MemProfiler::instrumentMaskedLoadOrStore
mp_instrument_masked :: (mp: *Mem_Profiler, mask: Value_Id, i: Value_Id, addr: Value_Id, access_ty: Type_Id, is_write: bool) {
    if !is_vector_type(access_ty) || type_kind(access_ty) == .SVECTOR fatal("memprof: masked access of a scalable vector type");
    n := type_count(access_ty);
    zero := const_int(mp.intptr_ty, 0);
    for idx: 0..cast(s64) n - 1 {
        insert_before := i;
        if vkind(mask) == .C_VECTOR {
            e := op(mask, cast(u32) idx);
            if vkind(e) == .C_INT && const_int_zext(e) == 0 continue;
        } else {
            b: Irb;
            irb_set_before(*b, i);
            elem := irb_extract_element(*b, mask, cast(u64) idx);
            insert_before = mu_split_block_and_insert_if_then(elem, i, false);
        }
        b: Irb;
        irb_set_before(*b, insert_before);
        gep := irb_gep(*b, access_ty, addr, .[zero, const_int(mp.intptr_ty, cast(u64) idx)]);
        mp_instrument_address(mp, insert_before, gep, is_write);
    }
}

// MemProfiler::instrumentMop
mp_instrument_mop :: (mp: *Mem_Profiler, i: Value_Id, a: Memprof_Access) {
    if !memprof_cl.instrument_stack {
        u := get_underlying_object(a.addr);
        if is_inst(u) && inst_op(u) == .ALLOCA return;
    }
    if a.mask != NONE mp_instrument_masked(mp, a.mask, i, a.addr, a.access_ty, a.is_write);
    else mp_instrument_address(mp, i, a.addr, a.is_write);
}

// MemProfiler::instrumentMemIntrinsic
mp_instrument_mem_intrinsic :: (mp: *Mem_Profiler, mi: Value_Id) {
    b: Irb;
    irb_set_before(*b, mi);
    id := call_iid(mi);
    if id == IID_MEMCPY || id == IID_MEMCPY_INLINE || id == IID_MEMMOVE {
        irb_call(*b, ifx id == IID_MEMMOVE then mp.memmove else mp.memcpy,
                 .[op(mi, 0), op(mi, 1), irb_int_cast(*b, op(mi, 2), mp.intptr_ty, false)]);
    } else {
        irb_call(*b, mp.memset, .[op(mi, 0), irb_int_cast(*b, op(mi, 1), ir.t_i32, false), irb_int_cast(*b, op(mi, 2), mp.intptr_ty, false)]);
    }
    erase_inst_with_metadata(mi);
}

// MemProfiler::initializeCallbacks
mp_initialize_callbacks :: (mp: *Mem_Profiler) {
    pre := memprof_cl.callback_prefix;
    hist := ifx memprof_cl.histogram then "hist_" else "";
    for w: 0..1 {
        ts := ifx w == 1 then "store" else "load";
        mp.access_cb[w] = module_get_or_insert_function(tprint("%1%2%3", pre, hist, ts), type_func(ir.t_void, .[mp.intptr_ty], false));
    }
    p := type_ptr(0);
    mp.memmove = module_get_or_insert_function(tconcat(pre, "memmove"), type_func(p, .[p, p, mp.intptr_ty], false));
    mp.memcpy = module_get_or_insert_function(tconcat(pre, "memcpy"), type_func(p, .[p, p, mp.intptr_ty], false));
    mp.memset = module_get_or_insert_function(tconcat(pre, "memset"), type_func(p, .[p, ir.t_i32, mp.intptr_ty], false));
}

memprof_run :: (f: Value_Id) -> Preserved {
    mp: Mem_Profiler;
    mp.intptr_ty = type_int(dl_ptr_spec(0).bits);
    mp.scale = memprof_cl.mapping_scale;
    mp.granularity = ifx memprof_cl.histogram then MEMPROF_HISTOGRAM_GRANULARITY else memprof_cl.mapping_granularity;
    mp.mask = ~(cast(u64) mp.granularity - 1);
    if glob(f).linkage == .AVAILABLE_EXTERNALLY return PRESERVE_ALL;
    if memprof_cl.debug_func == vname(f) return PRESERVE_ALL;
    if begins_with(vname(f), "__memprof_") return PRESERVE_ALL;
    modified := false;
    if contains(vname(f), " load]") {
        init := declare_sanitizer_init_function("__memprof_init", .[]);
        b: Irb;
        entry := fn_entry(f);
        irb_set_at(*b, entry, block_first(entry), false);
        irb_call(*b, init, .[]);
        modified = true;
    }
    mp_initialize_callbacks(*mp);
    to_instrument: [..] Value_Id; to_instrument.allocator = temp;
    for b: fn_blocks(f) for i: block_insts(b) {
        ok, _ := mp_is_interesting(*mp, i);
        if ok || is_mem_intrinsic_inst(i) array_add(*to_instrument, i);
    }
    if to_instrument.count == 0 {
        if modified { printer_note_ir_changed(); return PRESERVE_NONE; }
        return PRESERVE_ALL;
    }
    // insertDynamicShadowAtFunctionEntry
    {
        b: Irb;
        irb_set_before(*b, block_first(fn_entry(f)));
        gda := module_get_or_insert_global("__memprof_shadow_memory_dynamic_address", mp.intptr_ty);
        pic_ok, pic := mu_module_flag_int("PIC Level");
        if !pic_ok || pic == 0 glob(gda).dso_local = true;
        mp.dynamic_shadow_offset = irb_load(*b, mp.intptr_ty, gda, dl_alignment(mp.intptr_ty, true));
    }
    n := 0;
    for i: to_instrument {
        if memprof_cl.debug_min < 0 || memprof_cl.debug_max < 0 || (n >= memprof_cl.debug_min && n <= memprof_cl.debug_max) {
            ok, a := mp_is_interesting(*mp, i);
            if ok mp_instrument_mop(*mp, i, a);
            else mp_instrument_mem_intrinsic(*mp, i);
        }
        n += 1;
    }
    printer_note_ir_changed();
    return PRESERVE_NONE;
}

// ModuleMemProfiler::instrumentModule
memprof_module_run :: () -> Preserved {
    vc := ifx memprof_cl.insert_version_check then tprint("__memprof_version_mismatch_check_v%", MEMPROF_VERSION) else "";
    ctor := create_sanitizer_ctor_and_init_functions("memprof.module_ctor", "__memprof_init", .[], .[], vc);
    t := triple_parse(ir.triple);
    append_to_global_ctors(ctor, ifx t.os == .Emscripten then 50 else 1);
    comdat_ok := triple_supports_comdat();
    // createProfileFileNameVar
    fnm := module_flag("MemProfProfileFilename");
    if fnm != NONE && ir.mds[fnm].kind == .STRING {
        s := ir.mds[fnm].str;
        init := mp_c_string(s);
        gv := gv_create(vtype(init), true, .WEAK_ANY, init, "__memprof_profile_filename", NONE, 0, dl.globals_as);
        if comdat_ok { gv_set_linkage(gv, .EXTERNAL); glob(gv).comdat = get_comdat("__memprof_profile_filename"); }
    }
    // createMemprofHistogramFlagVar
    {
        gv := gv_create(ir.t_i1, true, .WEAK_ANY, const_int(ir.t_i1, ifx memprof_cl.histogram then cast(u64) 1 else 0), "__memprof_histogram", NONE, 0, dl.globals_as);
        if comdat_ok { gv_set_linkage(gv, .EXTERNAL); glob(gv).comdat = get_comdat("__memprof_histogram"); }
        append_to_compiler_used(gv);
    }
    // createMemprofDefaultOptionsVar
    {
        init := mp_c_string(memprof_cl.runtime_default_options);
        gv := gv_create(vtype(init), true, .WEAK_ANY, init, "__memprof_default_options_str", NONE, 0, dl.globals_as);
        if comdat_ok { gv_set_linkage(gv, .EXTERNAL); glob(gv).comdat = get_comdat(vname(gv)); }
    }
    printer_note_ir_changed();
    return PRESERVE_NONE;
}

// ConstantDataArray::getString(Ctx, S, AddNull = true)
mp_c_string :: (s: string) -> Value_Id {
    n := s.count + 1;
    ty := type_array(cast(u64) n, ir.t_i8);
    elts := NewArray(n, u64,, allocator = temp);
    all_zero := true;
    for i: 0..s.count-1 { elts[i] = s[i]; if s[i] != 0 all_zero = false; }
    return ifx all_zero then const_zero(ty) else const_data(ty, elts);
}
