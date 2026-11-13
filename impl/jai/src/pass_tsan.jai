// ThreadSanitizer: a port of llvm/lib/Transforms/Instrumentation/ThreadSanitizer.cpp (ThreadSanitizerPass "tsan",
// ModuleThreadSanitizerPass "tsan-module", all cl::opts) with EscapeEnumerator (llvm/lib/Transforms/Utils/
// EscapeEnumerator.cpp). RealtimeSanitizer (llvm/lib/Transforms/Instrumentation/RealtimeSanitizer.cpp, "rtsan") is at
// the end of the file.

tsan_cl: struct {
    instrument_memory_accesses := true;
    instrument_func_entry_exit := true;
    handle_cxx_exceptions := true;
    instrument_atomics := true;
    instrument_mem_intrinsics := true;
    distinguish_volatile: bool;
    instrument_read_before_write: bool;
    compound_read_before_write: bool;
    omit_non_captured := true;
};

tsan_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if !begins_with(name, "tsan-") return false;
    pb :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("opt: for the --% option: '%' is invalid value for boolean argument! Try 0 or 1", name, value);
        return false;
    }
    o := *tsan_cl;
    if name == {
        case "tsan-instrument-memory-accesses"; o.instrument_memory_accesses = pb(name, value, has_value);
        case "tsan-instrument-func-entry-exit"; o.instrument_func_entry_exit = pb(name, value, has_value);
        case "tsan-handle-cxx-exceptions"; o.handle_cxx_exceptions = pb(name, value, has_value);
        case "tsan-instrument-atomics"; o.instrument_atomics = pb(name, value, has_value);
        case "tsan-instrument-memintrinsics"; o.instrument_mem_intrinsics = pb(name, value, has_value);
        case "tsan-distinguish-volatile"; o.distinguish_volatile = pb(name, value, has_value);
        case "tsan-instrument-read-before-write"; o.instrument_read_before_write = pb(name, value, has_value);
        case "tsan-compound-read-before-write"; o.compound_read_before_write = pb(name, value, has_value);
        case "tsan-omit-by-pointer-capturing"; o.omit_non_captured = pb(name, value, has_value);
        case; return false;
    }
    return true;
}

TSAN_N :: 5;
TSAN_RMW_OPS :: 20;

Tsan :: struct {
    intptr: Type_Id;
    func_entry, func_exit, ignore_begin, ignore_end: San_Callee;
    read, write, unaligned_read, unaligned_write, volatile_read, volatile_write: [TSAN_N] San_Callee;
    unaligned_volatile_read, unaligned_volatile_write, compound_rw, unaligned_compound_rw: [TSAN_N] San_Callee;
    atomic_load, atomic_store, atomic_cas: [TSAN_N] San_Callee;
    atomic_rmw: [TSAN_RMW_OPS][TSAN_N] San_Callee;
    atomic_thread_fence, atomic_signal_fence, vptr_update, vptr_load: San_Callee;
    memmove, memcpy, memset: San_Callee;
}

Tsan_Ii :: struct { i: Value_Id; flags: u32; }
TSAN_K_COMPOUND_RW :: 1;

// AttributeList with NoUnwind on the function, plus TLI ext attributes
tsan_attr_list :: (t: *Tli, arg_nos: [] u32, signed: bool, ret: bool) -> u32 {
    l := msan_tli_attr_list(t, arg_nos, signed, ret);
    a: Attr; a.kind = .NoUnwind; a.ty = NONE;
    return attr_list_with_fn(l, attr_set_with(attr_list_fn(l), a));
}

// ThreadSanitizer::initialize
tsan_initialize :: (s: *Tsan, t: *Tli) {
    s.intptr = type_int(dl_ptr_spec(0).bits);
    attr := tsan_attr_list(t, .[], false, false);
    v := ir.t_void; p := type_ptr(0); ord := ir.t_i32;
    s.func_entry = san_callee("__tsan_func_entry", v, .[p], attr);
    s.func_exit = san_callee("__tsan_func_exit", v, .[], attr);
    s.ignore_begin = san_callee("__tsan_ignore_thread_begin", v, .[], attr);
    s.ignore_end = san_callee("__tsan_ignore_thread_end", v, .[], attr);
    for i: 0..TSAN_N-1 {
        bytes := (cast(u64) 1) << cast(u64) i;
        bits := bytes * 8;
        s.read[i] = san_callee(tprint("__tsan_read%", bytes), v, .[p], attr);
        s.write[i] = san_callee(tprint("__tsan_write%", bytes), v, .[p], attr);
        s.unaligned_read[i] = san_callee(tprint("__tsan_unaligned_read%", bytes), v, .[p], attr);
        s.unaligned_write[i] = san_callee(tprint("__tsan_unaligned_write%", bytes), v, .[p], attr);
        s.volatile_read[i] = san_callee(tprint("__tsan_volatile_read%", bytes), v, .[p], attr);
        s.volatile_write[i] = san_callee(tprint("__tsan_volatile_write%", bytes), v, .[p], attr);
        s.unaligned_volatile_read[i] = san_callee(tprint("__tsan_unaligned_volatile_read%", bytes), v, .[p], attr);
        s.unaligned_volatile_write[i] = san_callee(tprint("__tsan_unaligned_volatile_write%", bytes), v, .[p], attr);
        s.compound_rw[i] = san_callee(tprint("__tsan_read_write%", bytes), v, .[p], attr);
        s.unaligned_compound_rw[i] = san_callee(tprint("__tsan_unaligned_read_write%", bytes), v, .[p], attr);
        ty := type_int(bits);
        small := bits <= 32;
        s.atomic_load[i] = san_callee(tprint("__tsan_atomic%_load", bits), ty, .[p, ord], tsan_attr_list(t, .[1], true, small));
        A12 :: u32.[1, 2]; A2 :: u32.[2]; A1234 :: u32.[1, 2, 3, 4]; A34 :: u32.[3, 4];
        idxs2or12: [] u32 = ifx small then cast([] u32) A12 else cast([] u32) A2;
        idxs34or1234: [] u32 = ifx small then cast([] u32) A1234 else cast([] u32) A34;
        s.atomic_store[i] = san_callee(tprint("__tsan_atomic%_store", bits), v, .[p, ty, ord], tsan_attr_list(t, idxs2or12, true, false));
        for op: 0..TSAN_RMW_OPS-1 {
            part := "";
            // AtomicRMWInst::BinOp: Xchg 0, Add 1, Sub 2, And 3, Nand 4, Or 5, Xor 6, ...
            if op == {
                case 0; part = "_exchange";
                case 1; part = "_fetch_add";
                case 2; part = "_fetch_sub";
                case 3; part = "_fetch_and";
                case 5; part = "_fetch_or";
                case 6; part = "_fetch_xor";
                case 4; part = "_fetch_nand";
            }
            s.atomic_rmw[op][i] = .{};
            if part.count == 0 continue;
            s.atomic_rmw[op][i] = san_callee(tprint("__tsan_atomic%1%2", bits, part), ty, .[p, ty, ord], tsan_attr_list(t, idxs2or12, true, small));
        }
        s.atomic_cas[i] = san_callee(tprint("__tsan_atomic%_compare_exchange_val", bits), ty, .[p, ty, ty, ord, ord], tsan_attr_list(t, idxs34or1234, true, small));
    }
    s.vptr_update = san_callee("__tsan_vptr_update", v, .[p, p], attr);
    s.vptr_load = san_callee("__tsan_vptr_read", v, .[p], attr);
    s.atomic_thread_fence = san_callee("__tsan_atomic_thread_fence", v, .[ord], tsan_attr_list(t, .[0], true, false));
    s.atomic_signal_fence = san_callee("__tsan_atomic_signal_fence", v, .[ord], tsan_attr_list(t, .[0], true, false));
    s.memmove = san_callee("__tsan_memmove", p, .[p, p, s.intptr], attr);
    s.memcpy = san_callee("__tsan_memcpy", p, .[p, p, s.intptr], attr);
    s.memset = san_callee("__tsan_memset", p, .[p, ir.t_i32, s.intptr], tsan_attr_list(t, .[1], true, false));
}

// MDNode::isTBAAVtableAccess
tbaa_is_vtable_access :: (tag: Md_Id) -> bool {
    if tag == NONE || ir.mds[tag].kind != .TUPLE return false;
    n := md_nops(tag);
    md_str :: (m: Md_Id) -> string { if m == NONE || ir.mds[m].kind != .STRING return ""; return ir.mds[m].str; }
    is_node :: (m: Md_Id) -> bool { return m != NONE && ir.mds[m].kind == .TUPLE; }
    struct_path := n >= 3 && is_node(md_op(tag, 0));
    if !struct_path {
        if n < 1 return false;
        return md_str(md_op(tag, 0)) == "vtable pointer";
    }
    at := md_op(tag, 1);
    if !is_node(at) return false;
    an := md_nops(at);
    new_format := an >= 3 && is_node(md_op(at, 0));
    id := ifx new_format then md_op(at, 2) else md_op(at, 0);
    return md_str(id) == "vtable pointer";
}
tsan_is_vtable_access :: (i: Value_Id) -> bool { return tbaa_is_vtable_access(get_metadata(i, md_kind_id("tbaa"))); }

// shouldInstrumentReadWriteFromAddress
tsan_should_instrument_read_write_from_address :: (addr: Value_Id) -> bool {
    peeled := strip_in_bounds_offsets(addr);
    if vkind(peeled) == .GLOBAL_VAR {
        sec := glob(peeled).section;
        if sec.count {
            // getInstrProfSectionName(IPSK_cnts, OF, AddSegmentInfo = false)
            cnts := ifx san_triple_is_coff() then ".lprfc$M" else (ifx san_triple_is_macho() then "__llvm_prf_cnts" else "__llvm_prf_cnts");
            if ends_with(sec, cnts) return false;
        }
    }
    if ir.types[scalar_type(vtype(addr))].a != 0 return false;
    return true;
}

// addrPointsToConstantData
tsan_addr_points_to_constant_data :: (addr_in: Value_Id) -> bool {
    addr := addr_in;
    if is_inst(addr) && inst_op(addr) == .GEP addr = op(addr, 0);
    if vkind(addr) == .GLOBAL_VAR return glob(addr).is_const;
    if is_inst(addr) && inst_op(addr) == .LOAD return tsan_is_vtable_access(addr);
    return false;
}

// chooseInstructionsToInstrument
tsan_choose_instructions :: (local: *[..] Value_Id, all: *[..] Tsan_Ii) {
    write_targets: Table(Value_Id, s64); write_targets.allocator = temp;
    k := local.count - 1;
    while k >= 0 {
        defer k -= 1;
        i := local.*[k];
        is_write := inst_op(i) == .STORE;
        addr := ifx is_write then op(i, 1) else op(i, 0);
        if !tsan_should_instrument_read_write_from_address(addr) continue;
        if !is_write {
            found, wi_index := table_find(*write_targets, addr);
            if !tsan_cl.instrument_read_before_write && found {
                wi := *all.*[wi_index];
                any_volatile := tsan_cl.distinguish_volatile && ((inst(i).flags & F_VOLATILE) != 0 || (inst(wi.i).flags & F_VOLATILE) != 0);
                if !any_volatile { wi.flags |= TSAN_K_COMPOUND_RW; continue; }
            }
            if tsan_addr_points_to_constant_data(addr) continue;
        }
        ai := find_alloca_for_value(addr);
        if ai != NONE && !pointer_may_be_captured_bool(ai, true) && tsan_cl.omit_non_captured continue;
        array_add(all, .{i, 0});
        if is_write table_set(*write_targets, addr, all.count - 1);
    }
    local.count = 0;
}

// isTsanAtomic
tsan_is_atomic :: (i: Value_Id) -> bool {
    o := inst_op(i);
    // getAtomicSyncScopeID: loads/stores only when atomic; fence, cmpxchg, atomicrmw always
    if o == .LOAD || o == .STORE {
        if inst(i).ord1 == 0 return false;
        return inst(i).sync != SYNC_SCOPE_SINGLE_THREAD;   // != singlethread
    }
    return o == .FENCE || o == .CMPXCHG || o == .ATOMICRMW;
}

// getMemoryAccessFuncIndex
tsan_access_index :: (t: Type_Id) -> s64 {
    if type_is_scalable(t) return -1;
    bits := dl_type_store_size(t) * 8;
    if bits != 8 && bits != 16 && bits != 32 && bits != 64 && bits != 128 return -1;
    n := bits / 8; r := 0; while n > 1 { n >>= 1; r += 1; }
    return r;
}

// createOrdering
tsan_ordering :: (ord: u8) -> Value_Id {
    v: u64;
    if ord == {
        case 1; #through; case 2; v = 0;
        case 4; v = 2;
        case 5; v = 3;
        case 6; v = 4;
        case 7; v = 5;
        case; fatal("unexpected atomic ordering!");
    }
    return const_int(ir.t_i32, v);
}

// IRBuilder::CreateBitOrPointerCast
irb_bit_or_pointer_cast_san :: (b: *Irb, v: Value_Id, t: Type_Id) -> Value_Id {
    st := vtype(v);
    if st == t return v;
    if is_ptr_type(scalar_type(st)) && is_int_type(scalar_type(t)) return irb_cast(b, .PTRTOINT, v, t);
    if is_int_type(scalar_type(st)) && is_ptr_type(scalar_type(t)) return irb_cast(b, .INTTOPTR, v, t);
    return irb_cast(b, .BITCAST, v, t);
}

tsan_instrument_load_or_store :: (s: *Tsan, ii: Tsan_Ii) -> bool {
    i := ii.i;
    b: Irb; irb_instr_before(*b, i);
    is_write := inst_op(i) == .STORE;
    addr := ifx is_write then op(i, 1) else op(i, 0);
    orig_ty := ifx is_write then vtype(op(i, 0)) else vtype(i);
    if value_is_swift_error(addr) return false;
    idx := tsan_access_index(orig_ty);
    if idx < 0 return false;
    if is_write && tsan_is_vtable_access(i) {
        sv := op(i, 0);
        if is_vector_type(vtype(sv)) sv = irb_extract_element_v(*b, sv, const_int(ir.t_i32, 0));
        if type_kind(vtype(sv)) == .INT sv = irb_cast(*b, .INTTOPTR, sv, type_ptr(0));
        san_call(*b, s.vptr_update, .[addr, sv]);
        return true;
    }
    if !is_write && tsan_is_vtable_access(i) { san_call(*b, s.vptr_load, .[addr]); return true; }
    alignment := inst(i).align;
    is_compound := tsan_cl.compound_read_before_write && (ii.flags & TSAN_K_COMPOUND_RW) != 0;
    is_volatile := tsan_cl.distinguish_volatile && (inst(i).flags & F_VOLATILE) != 0;
    bytes := dl_type_store_size(orig_ty);
    f: San_Callee;
    if alignment >= 8 || alignment % bytes == 0 {
        if is_compound f = s.compound_rw[idx];
        else if is_volatile f = ifx is_write then s.volatile_write[idx] else s.volatile_read[idx];
        else f = ifx is_write then s.write[idx] else s.read[idx];
    } else {
        if is_compound f = s.unaligned_compound_rw[idx];
        else if is_volatile f = ifx is_write then s.unaligned_volatile_write[idx] else s.unaligned_volatile_read[idx];
        else f = ifx is_write then s.unaligned_write[idx] else s.unaligned_read[idx];
    }
    san_call(*b, f, .[addr]);
    return true;
}

tsan_instrument_mem_intrinsic :: (s: *Tsan, i: Value_Id) -> bool {
    b: Irb; irb_instr_before(*b, i);
    id := call_iid(i);
    if id == IID_MEMSET || id == IID_MEMSET_INLINE {
        c1 := irb_int_cast(*b, op(i, 1), ir.t_i32, false);
        c2 := irb_int_cast(*b, op(i, 2), s.intptr, false);
        san_call(*b, s.memset, .[op(i, 0), c1, c2]);
        erase_inst(i);
    } else if id == IID_MEMCPY || id == IID_MEMCPY_INLINE || id == IID_MEMMOVE {
        san_call(*b, ifx id == IID_MEMMOVE then s.memmove else s.memcpy, .[op(i, 0), op(i, 1), irb_int_cast(*b, op(i, 2), s.intptr, false)]);
        erase_inst(i);
    }
    return false;
}

tsan_instrument_atomic :: (s: *Tsan, i: Value_Id) -> bool {
    b: Irb; irb_instr_before(*b, i);
    o := inst_op(i);
    if o == .LOAD {
        addr := op(i, 0); orig := vtype(i);
        idx := tsan_access_index(orig);
        if idx < 0 return false;
        c := san_call(*b, s.atomic_load[idx], .[addr, tsan_ordering(inst(i).ord1)]);
        cast_ := irb_bit_or_pointer_cast_san(*b, c, orig);
        rauw_with_metadata(i, cast_);
        erase_inst(i);
    } else if o == .STORE {
        addr := op(i, 1);
        idx := tsan_access_index(vtype(op(i, 0)));
        if idx < 0 return false;
        ty := type_int(((cast(u64) 1) << cast(u64) idx) * 8);
        san_call(*b, s.atomic_store[idx], .[addr, irb_bit_or_pointer_cast_san(*b, op(i, 0), ty), tsan_ordering(inst(i).ord1)]);
        erase_inst(i);
    } else if o == .ATOMICRMW {
        addr := op(i, 0); val := op(i, 1);
        idx := tsan_access_index(vtype(val));
        if idx < 0 return false;
        rop := inst(i).ord2;
        if rop >= TSAN_RMW_OPS return false;
        f := s.atomic_rmw[rop][idx];
        if f.callee == NONE return false;
        ty := type_int(((cast(u64) 1) << cast(u64) idx) * 8);
        c := san_call(*b, f, .[addr, irb_bit_or_pointer_cast_san(*b, val, ty), tsan_ordering(inst(i).ord1)]);
        rauw_with_metadata(i, irb_bit_or_pointer_cast_san(*b, c, vtype(val)));
        erase_inst(i);
    } else if o == .CMPXCHG {
        addr := op(i, 0);
        orig := vtype(op(i, 2));
        idx := tsan_access_index(orig);
        if idx < 0 return false;
        ty := type_int(((cast(u64) 1) << cast(u64) idx) * 8);
        cmp := irb_bit_or_pointer_cast_san(*b, op(i, 1), ty);
        nv := irb_bit_or_pointer_cast_san(*b, op(i, 2), ty);
        c := san_call(*b, s.atomic_cas[idx], .[addr, cmp, nv, tsan_ordering(inst(i).ord1), tsan_ordering(cmpxchg_failure_ordering(i))]);
        success := irb_icmp(*b, ICMP_EQ, c, cmp);
        old := c;
        if ty != orig old = irb_cast(*b, .INTTOPTR, c, orig);
        res := irb_insert_value(*b, const_poison(vtype(i)), old, .[0]);
        res = irb_insert_value(*b, res, success, .[1]);
        rauw_with_metadata(i, res);
        erase_inst(i);
    } else if o == .FENCE {
        f := ifx inst(i).sync == SYNC_SCOPE_SINGLE_THREAD then s.atomic_signal_fence else s.atomic_thread_fence;
        san_call(*b, f, .[tsan_ordering(inst(i).ord1)]);
        erase_inst(i);
    }
    return true;
}

// the failure ordering of a cmpxchg
cmpxchg_failure_ordering :: (i: Value_Id) -> u8 { return inst(i).ord2; }

// EscapeEnumerator: the exits of F (returns / resumes, or the musttail call before them), then, with
// HandleExceptions, a cleanup landing pad that every throwing call is turned into an invoke to
Escape_Enumerator :: struct {
    f: Value_Id;
    cleanup_name: string;
    handle_exceptions: bool;
    state_bb: Value_Id;
    done: bool;
}
escape_enumerator :: (f: Value_Id, name: string, handle_exceptions: bool) -> Escape_Enumerator {
    e: Escape_Enumerator; e.f = f; e.cleanup_name = name; e.handle_exceptions = handle_exceptions; e.state_bb = fn_entry(f);
    return e;
}
// EscapeEnumerator::Next: the insertion point (an instruction to insert before), NONE when done
escape_enumerator_next :: (e: *Escape_Enumerator) -> Value_Id {
    if e.done return NONE;
    while e.state_bb != NONE {
        cur := e.state_bb;
        e.state_bb = block(cur).next;
        ti := block_terminator(cur);
        if ti == NONE || (inst_op(ti) != .RET && inst_op(ti) != .RESUME) continue;
        ci := block_terminating_must_tail_call(cur);
        if ci != NONE ti = ci;
        return ti;
    }
    e.done = true;
    if !e.handle_exceptions return NONE;
    if fn_has_fn_attr(e.f, .NoUnwind) return NONE;
    calls: [..] Value_Id; calls.allocator = temp;
    for bb: fn_blocks(e.f) for i: block_insts(bb)
        if inst_op(i) == .CALL && !call_has_fn_attr(i, .NoUnwind) && call_tail_kind(i) != TCK_MUSTTAIL array_add(*calls, i);
    if calls.count == 0 return NONE;
    cleanup := create_block(e.f, e.cleanup_name);
    exn_ty := type_literal_struct(.[type_ptr(0), ir.t_i32], false);
    if !glob(e.f).has_personality {
        // getDefaultEHPersonality: GNU C++ on PS5, GNU C everywhere else (getEHPersonalityName)
        pname := ifx san_triple().os == .PS5 then "__gxx_personality_v0" else "__gcc_personality_v0";
        pf := san_get_or_insert_function(pname, type_func(ir.t_i32, .[], true));
        set_op(e.f, 0, pf);
        glob(e.f).has_personality = true;
    }
    if is_scoped_eh_personality(classify_eh_personality(fn_personality(e.f))) fatal("Scoped EH not supported");
    lpad := new_inst(.LANDINGPAD, exn_ty, 0);
    inst(lpad).flags |= F_CLEANUP;   // setCleanup(true)
    block_append_inst(cleanup, lpad);
    set_name(lpad, "cleanup.lpad");
    ri := new_inst(.RESUME, ir.t_void, 1);
    set_op(ri, 0, lpad);
    block_append_inst(cleanup, ri);
    k := calls.count;
    while k > 0 { k -= 1; change_to_invoke_and_split_basic_block(calls[k], cleanup); }
    return ri;
}

// ThreadSanitizer::InsertRuntimeIgnores
tsan_insert_runtime_ignores :: (s: *Tsan, f: Value_Id) {
    entry := fn_entry(f);
    b: Irb; irb_set_at(*b, entry, block_first_non_phi(entry), true);
    san_ensure_debug_info(*b, f);
    san_call(*b, s.ignore_begin, .[]);
    ee := escape_enumerator(f, "tsan_ignore_cleanup", tsan_cl.handle_cxx_exceptions);
    while true {
        pt := escape_enumerator_next(*ee);
        if pt == NONE break;
        ab: Irb; irb_set_before(*ab, pt);
        san_ensure_debug_info(*ab, f);
        san_call(*ab, s.ignore_end, .[]);
    }
}

// ThreadSanitizer::sanitizeFunction
tsan_sanitize_function :: (f: Value_Id, t: *Tli) -> bool {
    if vname(f) == "tsan.module_ctor" return false;
    if fn_has_fn_attr(f, .Naked) return false;
    if fn_has_fn_attr(f, .DisableSanitizerInstrumentation) return false;
    s: Tsan;
    tsan_initialize(*s, t);
    all: [..] Tsan_Ii; all.allocator = temp;
    local: [..] Value_Id; local.allocator = temp;
    atomics: [..] Value_Id; atomics.allocator = temp;
    mem_intrin: [..] Value_Id; mem_intrin.allocator = temp;
    res := false; has_calls := false;
    sanitize := fn_has_fn_attr(f, .SanitizeThread);
    nosanitize := md_kind_id("nosanitize");
    for bb: fn_blocks(f) {
        for i: block_insts(bb) {
            if get_metadata(i, nosanitize) != NONE continue;
            o := inst_op(i);
            if tsan_is_atomic(i) array_add(*atomics, i);
            else if o == .LOAD || o == .STORE array_add(*local, i);
            else if o == .CALL || o == .INVOKE {
                if o == .CALL maybe_mark_sanitizer_library_call_no_builtin(i, t);
                if o == .CALL && asan_is_mem_intrinsic(i) array_add(*mem_intrin, i);
                has_calls = true;
                tsan_choose_instructions(*local, *all);
            }
        }
        tsan_choose_instructions(*local, *all);
    }
    if tsan_cl.instrument_memory_accesses && sanitize for all if tsan_instrument_load_or_store(*s, it) res = true;
    if tsan_cl.instrument_atomics for atomics if tsan_instrument_atomic(*s, it) res = true;
    if tsan_cl.instrument_mem_intrinsics && sanitize for mem_intrin if tsan_instrument_mem_intrinsic(*s, it) res = true;
    if fn_find_str_attr(f, "sanitize_thread_no_checking_at_run_time") != null {
        if has_calls tsan_insert_runtime_ignores(*s, f);
    }
    if (res || has_calls) && tsan_cl.instrument_func_entry_exit {
        entry := fn_entry(f);
        b: Irb; irb_set_at(*b, entry, block_first_non_phi(entry), true);
        san_ensure_debug_info(*b, f);
        ra := irb_intrinsic(*b, "llvm.returnaddress", .[type_ptr(dl.program_as)], .[const_int(ir.t_i32, 0)]);
        san_call(*b, s.func_entry, .[ra]);
        ee := escape_enumerator(f, "tsan_cleanup", tsan_cl.handle_cxx_exceptions);
        while true {
            pt := escape_enumerator_next(*ee);
            if pt == NONE break;
            ab: Irb; irb_set_before(*ab, pt);
            san_ensure_debug_info(*ab, f);
            san_call(*ab, s.func_exit, .[]);
        }
        res = true;
    }
    return res;
}

// ThreadSanitizerPass::run (function pass "tsan")
tsan_run :: (f: Value_Id) -> Preserved {
    if tsan_cl.instrument_read_before_write && tsan_cl.compound_read_before_write
        print_to_stderr("warning: Option -tsan-compound-read-before-write has no effect when -tsan-instrument-read-before-write is set.\n");
    if tsan_sanitize_function(f, tli_for(f)) return PRESERVE_NONE;
    return PRESERVE_ALL;
}

// ModuleThreadSanitizerPass::run ("tsan-module")
tsan_module_run :: () -> Preserved {
    if check_if_already_instrumented("nosanitize_thread") return PRESERVE_ALL;
    ctor, init, created := get_or_create_sanitizer_ctor_and_init_functions("tsan.module_ctor", "__tsan_init", .[], .[], "");
    if created append_to_global_ctors(ctor, 0);
    printer_note_ir_changed();
    return PRESERVE_NONE;
}

// ---------------------------------------------------------------- RealtimeSanitizer

rtsan_insert_call_before :: (name: string, i: Value_Id, args: [] Value_Id) {
    tys: [..] Type_Id; tys.allocator = temp;
    for args array_add(*tys, vtype(it));
    c := san_callee(name, ir.t_void, tys);
    b: Irb; irb_set_before(*b, i);
    san_call(*b, c, args);
}

// IRBuilder::CreateGlobalString(Str, Name = "", AddressSpace = 0, M): preferred alignment of i8
irb_create_global_string :: (s: string, name := "", as: u32 = 0) -> Value_Id {
    elts := NewArray(s.count + 1, u64,, temp);
    for 0..s.count-1 elts[it] = s[it];
    c := const_data(type_array(cast(u64) s.count + 1, ir.t_i8), elts);
    gv := gv_create(vtype(c), true, .PRIVATE, c, name, NONE, 0, as);
    glob(gv).unnamed_addr = 2;
    glob(gv).align = dl_pref_align(ir.t_i8);
    return gv;
}

// RealtimeSanitizerPass::run ("rtsan")
rtsan_run :: () -> Preserved {
    ctor, init, created := get_or_create_sanitizer_ctor_and_init_functions("rtsan.module_ctor", "__rtsan_ensure_initialized", .[], .[], "");
    if created append_to_global_ctors(ctor, 0);
    fns: [..] Value_Id; fns.allocator = temp;
    for ir.m_functions array_add(*fns, it);
    for f: fns {
        if is_declaration(f) continue;
        if fn_has_fn_attr(f, .SanitizeRealtime) {
            rtsan_insert_call_before("__rtsan_realtime_enter", block_first(fn_entry(f)), .[]);
            for i: fn_insts(f) if inst_op(i) == .RET rtsan_insert_call_before("__rtsan_realtime_exit", i, .[]);
        }
        if fn_has_fn_attr(f, .SanitizeRealtimeBlocking) {
            name := irb_create_global_string(llvm_demangle(vname(f)));
            rtsan_insert_call_before("__rtsan_notify_blocking_call", block_first(fn_entry(f)), .[name]);
        }
    }
    printer_note_ir_changed();
    return PRESERVE_NONE;
}
