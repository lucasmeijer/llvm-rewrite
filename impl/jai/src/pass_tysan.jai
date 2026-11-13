// TypeSanitizer: a port of llvm/lib/Transforms/Instrumentation/TypeSanitizer.cpp (TypeSanitizerPass "tysan": type
// descriptors from TBAA, globals, inline / outlined access instrumentation, memory-type resets, cl::opts).

tysan_cl: struct {
    writes_always_set_type: bool;
    outline_instrumentation := true;
    verify_outlined_instrumentation: bool;
};

tysan_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if !begins_with(name, "tysan-") return false;
    pb :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("opt: for the --% option: '%' is invalid value for boolean argument! Try 0 or 1", name, value);
        return false;
    }
    if name == {
        case "tysan-writes-always-set-type"; tysan_cl.writes_always_set_type = pb(name, value, has_value);
        case "tysan-outline-instrumentation"; tysan_cl.outline_instrumentation = pb(name, value, has_value);
        case "tysan-verify-outlined-instrumentation"; tysan_cl.verify_outlined_instrumentation = pb(name, value, has_value);
        case; return false;
    }
    return true;
}

Tysan :: struct {
    intptr: Type_Id;
    ptr_shift: u64;
    check, ctor_function, instrument_mem_inst, instrument_with_shadow_update, set_shadow_type: San_Callee;
    globals_set_type_function: Value_Id = NONE;
}
Tysan_Maps :: struct {
    descriptors: Table(Md_Id, Value_Id);
    names: Table(Md_Id, string);
}
tysan_maps :: () -> Tysan_Maps { m: Tysan_Maps; m.descriptors.allocator = temp; m.names.allocator = temp; return m; }

// TypeSanitizer::initializeCallbacks
tysan_initialize_callbacks :: (s: *Tysan) {
    a: Attr; a.kind = .NoUnwind; a.ty = NONE;
    attr := attr_list_with_fn(0, attr_set_with(0, a));
    v := ir.t_void; p := type_ptr(0); ord := ir.t_i32; u64t := type_int(64);
    s.check = san_callee("__tysan_check", v, .[p, ord, p, ord], attr);
    s.ctor_function = san_callee("tysan.module_ctor", v, .[], attr);
    s.instrument_mem_inst = san_callee("__tysan_instrument_mem_inst", v, .[p, p, u64t, ir.t_i1], attr);
    s.instrument_with_shadow_update = san_callee("__tysan_instrument_with_shadow_update", v, .[p, p, ir.t_i1, u64t, ord], attr);
    s.set_shadow_type = san_callee("__tysan_set_shadow_type", v, .[p, p, u64t], attr);
}

tysan_new :: () -> Tysan {
    s: Tysan;
    s.intptr = type_int(dl_ptr_spec(0).bits);
    s.ptr_shift = cast(u64) ctz64(cast(u64)(dl_ptr_spec(0).bits / 8));   // countr_zero
    s.globals_set_type_function = module_get_function("__tysan_set_globals_types");
    tysan_initialize_callbacks(*s);
    return s;
}

// encodeName
tysan_encode_name :: (name: string) -> string {
    LUT :: "0123456789abcdef";
    sb: String_Builder; sb.allocator = temp;
    append(*sb, "__tysan_v1_");
    for c: cast([] u8) name {
        if c_isalnum(c) { append(*sb, c); continue; }
        if c == #char "_" { append(*sb, "__"); continue; }
        append(*sb, #char "_"); append(*sb, LUT[c >> 4]); append(*sb, LUT[c & 15]);
    }
    return builder_to_string(*sb,, allocator = temp);
}

tysan_md_str :: (m: Md_Id) -> (bool, string) {
    if m == NONE || ir.mds[m].kind != .STRING return false, "";
    return true, ir.mds[m].str;
}
tysan_md_is_node :: (m: Md_Id) -> bool { return m != NONE && ir.mds[m].kind == .TUPLE; }
tysan_md_int :: (m: Md_Id) -> u64 { return const_int_zext(ir.mds[m].value); }

// getAnonymousStructIdentifier
tysan_anonymous_struct_identifier :: (md: Md_Id, maps: *Tysan_Maps) -> string {
    h: Md5;
    n := cast(s64) md_nops(md);
    i := 1;
    while i < n {
        member := md_op(md, cast(u32) i);
        if !tysan_md_is_node(member) return "";
        found, mn := table_find(*maps.names, member);
        if !found {
            if md_nops(member) < 1 return "";
            ok, s := tysan_md_str(md_op(member, 0));
            if !ok return "";
            mn = s;
            if mn.count == 0 mn = tysan_anonymous_struct_identifier(member, maps);
            if mn.count == 0 return "";
            table_set(*maps.names, member, mn);
        }
        md5_update_str(*h, mn);
        // Hash.update("\0") is an empty StringRef
        md5_update_str(*h, tprint("%", tysan_md_int(md_op(md, cast(u32) i + 1))));
        i += 2;
    }
    return tconcat("__anonymous_", md5_hex(md5_final(*h)));
}

// AnonNameRegex: ^_ZTS.*N[1-9][0-9]*_GLOBAL__N
tysan_anon_name_match :: (s: string) -> bool {
    if !begins_with(s, "_ZTS") return false;
    for start: 4..s.count-1 {
        if s[start] != #char "N" continue;
        k := start + 1;
        if k >= s.count || s[k] < #char "1" || s[k] > #char "9" continue;
        while k < s.count && s[k] >= #char "0" && s[k] <= #char "9" k += 1;
        rest := slice(s, k, s.count - k);
        if begins_with(rest, "_GLOBAL__N") return true;
    }
    return false;
}

// generateBaseTypeDescriptor
tysan_generate_base_type_descriptor :: (s: *Tysan, md: Md_Id, maps: *Tysan_Maps) -> bool {
    if md_nops(md) < 1 return false;
    ok, raw_name := tysan_md_str(md_op(md, 0));
    if !ok return false;
    name := raw_name;
    if name.count == 0 name = tysan_anonymous_struct_identifier(md, maps);
    if name.count == 0 return false;
    table_set(*maps.names, md, name);
    encoded := tysan_encode_name(name);
    g := lookup_global(encoded);
    if g != NONE && vkind(g) == .GLOBAL_VAR { table_set(*maps.descriptors, md, g); return true; }
    members: [..] [2] u64; members.allocator = temp;   // (descriptor, offset)
    n := cast(s64) md_nops(md);
    i := 1;
    while i < n {
        mn := md_op(md, cast(u32) i);
        if !tysan_md_is_node(mn) return false;
        found, member := table_find(*maps.descriptors, mn);
        if !found {
            if !tysan_generate_base_type_descriptor(s, mn, maps) return false;
            _, member = table_find(*maps.descriptors, mn);
        }
        off := tysan_md_int(md_op(md, cast(u32) i + 1));
        array_add(*members, .[cast(u64) member, off]);
        i += 2;
    }
    elts := NewArray(raw_name.count + 1, u64,, temp);
    for 0..raw_name.count-1 elts[it] = raw_name[it];
    name_data := const_data(type_array(cast(u64) raw_name.count + 1, ir.t_i8), elts);
    tys: [..] Type_Id; tys.allocator = temp;
    data: [..] Value_Id; data.allocator = temp;
    push :: (tys: *[..] Type_Id, data: *[..] Value_Id, c: Value_Id) { array_add(tys, vtype(c)); array_add(data, c); }
    push(*tys, *data, const_int(s.intptr, 2));
    push(*tys, *data, const_int(s.intptr, cast(u64) members.count));
    comdat := !tysan_anon_name_match(raw_name);
    for members { push(*tys, *data, cast(Value_Id) it[0]); push(*tys, *data, const_int(s.intptr, it[1])); }
    push(*tys, *data, name_data);
    tdty := type_literal_struct(tys, false);
    td := const_aggregate(.C_STRUCT, tdty, data);
    tdgv := gv_create(tdty, true, ifx comdat then Linkage.LINKONCE_ODR else .INTERNAL, td, encoded, NONE, 0, dl.globals_as);
    if comdat {
        if san_triple_is_elf() glob(tdgv).comdat = get_comdat(encoded);
        append_to_used(tdgv);
    }
    table_set(*maps.descriptors, md, tdgv);
    return true;
}

// generateTypeDescriptor
tysan_generate_type_descriptor :: (s: *Tysan, md: Md_Id, maps: *Tysan_Maps) -> bool {
    if md_nops(md) < 3 return false;
    base_node := md_op(md, 0);
    if !tysan_md_is_node(base_node) return false;
    access_node := md_op(md, 1);
    if !tysan_md_is_node(access_node) return false;
    found, base := table_find(*maps.descriptors, base_node);
    if !found {
        if !tysan_generate_base_type_descriptor(s, base_node, maps) return false;
        _, base = table_find(*maps.descriptors, base_node);
    }
    found2, access := table_find(*maps.descriptors, access_node);
    if !found2 {
        if !tysan_generate_base_type_descriptor(s, access_node, maps) return false;
        _, access = table_find(*maps.descriptors, access_node);
    }
    off := tysan_md_int(md_op(md, 2));
    encoded := tprint("%1_o_%2", vname(base), off);
    g := lookup_global(encoded);
    if g != NONE && vkind(g) == .GLOBAL_VAR { table_set(*maps.descriptors, md, g); return true; }
    tdty := type_literal_struct(.[s.intptr, vtype(base), vtype(access), s.intptr], false);
    td := const_aggregate(.C_STRUCT, tdty, .[const_int(s.intptr, 1), base, access, const_int(s.intptr, off)]);
    comdat := glob(base).linkage == .LINKONCE_ODR;
    tdgv := gv_create(tdty, true, ifx comdat then Linkage.LINKONCE_ODR else .INTERNAL, td, encoded, NONE, 0, dl.globals_as);
    if comdat {
        if san_triple_is_elf() glob(tdgv).comdat = get_comdat(encoded);
        append_to_used(tdgv);
    }
    table_set(*maps.descriptors, md, tdgv);
    return true;
}

tysan_get_shadow_base :: (s: *Tysan, f: Value_Id) -> Value_Id {
    b: Irb; irb_set_before(*b, block_first(fn_entry(f)));
    g := module_get_or_insert_global("__tysan_shadow_memory_address", s.intptr);
    return irb_load(*b, s.intptr, g, dl_abi_align(s.intptr), false, "shadow.base");
}
tysan_get_app_mem_mask :: (s: *Tysan, f: Value_Id) -> Value_Id {
    b: Irb; irb_set_before(*b, block_first(fn_entry(f)));
    g := module_get_or_insert_global("__tysan_app_memory_mask", s.intptr);
    return irb_load(*b, s.intptr, g, dl_abi_align(s.intptr), false, "app.mem.mask");
}

// TypeSanitizer::instrumentGlobals
tysan_instrument_globals :: (s: *Tysan) {
    s.globals_set_type_function = NONE;
    k := named_md_find("llvm.tysan.globals");
    if k < 0 return;
    f := new_function(type_func(ir.t_void, .[], false), "", dl.program_as);
    gv_set_linkage(f, .INTERNAL);
    array_add(*ir.m_functions, f);
    set_name(f, "__tysan_set_globals_types");
    s.globals_set_type_function = f;
    bb := create_block(f, "");
    block_append_inst(bb, new_inst(.RET, ir.t_void, 0));
    sb := tysan_get_shadow_base(s, f);
    amm := tysan_get_app_mem_mask(s, f);
    maps := tysan_maps();
    for gmd: ir.named_md[k].ops {
        gvm := md_op(gmd, 0);
        if gvm == NONE || ir.mds[gvm].kind != .VALUE continue;
        gv := ir.mds[gvm].value;
        if vkind(gv) != .GLOBAL_VAR continue;
        tbaa := md_op(gmd, 1);
        if !tysan_generate_base_type_descriptor(s, tbaa, *maps) continue;
        b: Irb; irb_set_before(*b, block_terminator(fn_entry(f)));
        size := dl_type_store_size(glob(gv).value_type);
        tysan_instrument_with_shadow_update(s, *b, tbaa, gv, size, false, false, sb, amm, true, false, *maps);
    }
    b: Irb; irb_set_before(*b, block_terminator(fn_entry(s.ctor_function.callee)));
    san_call(*b, .{type_func(ir.t_void, .[], false), f}, .[]);
}

// convertToShadowDataInt
tysan_shadow_data_int :: (s: *Tysan, b: *Irb, ptr: Value_Id, shadow_base: Value_Id, amm: Value_Id) -> Value_Id {
    pi := irb_cast(b, .PTRTOINT, ptr, s.intptr, "app.ptr.int");
    m := irb_binop(b, .AND, pi, amm, "app.ptr.masked");
    sh := irb_binop(b, .SHL, m, const_int(s.intptr, s.ptr_shift), "app.ptr.shifted");
    return irb_binop(b, .ADD, sh, shadow_base, "shadow.ptr.int");
}

// MDBuilder::createBranchWeights(1, 100000)
tysan_unlikely_bw :: () -> Md_Id {
    return md_tuple(.[md_string("branch_weights"), md_value(const_int(ir.t_i32, 1)), md_value(const_int(ir.t_i32, 100000))], false);
}

// instrumentWithShadowUpdate
tysan_instrument_with_shadow_update :: (s: *Tysan, b: *Irb, tbaa: Md_Id, ptr: Value_Id, size: u64, is_read: bool, is_write: bool,
                                        shadow_base: Value_Id, amm: Value_Id, force_set_type: bool, sanitize: bool, maps: *Tysan_Maps) -> bool {
    pty := type_ptr(0);
    tdgv: Value_Id;
    if tbaa != NONE { found, d := table_find(*maps.descriptors, tbaa); tdgv = ifx found then d else NONE; if tdgv == NONE fatal("internal: tysan: missing type descriptor"); }
    else tdgv = const_null_value(pty);
    td := irb_bitcast(b, tdgv, pty);
    flags_v := (cast(u64) is_read) | ((cast(u64) is_write) << 1);
    if tysan_cl.outline_instrumentation {
        if !force_set_type && (!tysan_cl.writes_always_set_type || is_read) {
            san_call(b, s.instrument_with_shadow_update, .[ptr, td, const_int(ir.t_i1, cast(u64) sanitize), const_int(type_int(64), size), const_int(ir.t_i32, flags_v)]);
        } else if force_set_type || is_write {
            san_call(b, s.set_shadow_type, .[ptr, td, const_int(type_int(64), size)]);
        }
        return true;
    }
    sdi := tysan_shadow_data_int(s, b, ptr, shadow_base, amm);
    sd := irb_cast(b, .INTTOPTR, sdi, pty, "shadow.ptr");
    set_type :: (s: *Tysan, b: *Irb, td: Value_Id, sd: Value_Id, sdi: Value_Id, size: u64, pty: Type_Id) {
        irb_store(b, td, sd, dl_abi_align(pty));
        for i: 1..cast(s64) size - 1 {
            off := irb_binop(b, .ADD, sdi, const_int(s.intptr, (cast(u64) i) << s.ptr_shift), tprint("shadow.byte.%.offset", i));
            bad := irb_cast(b, .INTTOPTR, off, pty, tprint("shadow.byte.%.ptr", i));
            btd := irb_cast(b, .INTTOPTR, const_int(s.intptr, cast,no_check(u64) (-i)), pty, tprint("bad.descriptor%", i));
            irb_store(b, btd, bad, dl_abi_align(pty));
        }
    }
    if force_set_type || (tysan_cl.writes_always_set_type && is_write) { set_type(s, b, td, sd, sdi, size, pty); return true; }
    ubw := tysan_unlikely_bw();
    if !sanitize {
        ltd := irb_load(b, pty, sd, dl_abi_align(pty), false, "shadow.desc");
        null_cmp := irb_icmp(b, ICMP_EQ, ltd, const_null_value(pty), "desc.set");
        term := sbi_if_then(null_cmp, b.pt, false, ubw);
        irb_set_before(b, term);
        set_name(inst(term).parent, "set.type");
        set_type(s, b, td, sd, sdi, size, pty);
        return true;
    }
    flags := const_int(ir.t_i32, flags_v);
    ltd := irb_load(b, pty, sd, dl_abi_align(pty), false, "shadow.desc");
    bad_cmp := irb_icmp(b, ICMP_NE, ltd, td, "bad.desc");
    bad_term, good_term := sbi_if_then_else(bad_cmp, b.pt, true, false, true, false, ubw);
    irb_set_before(b, bad_term);
    null_cmp := irb_icmp(b, ICMP_EQ, ltd, const_null_value(pty));
    null_term, mismatch_term := sbi_if_then_else(null_cmp, b.pt, true, false, true, false);
    irb_set_before(b, null_term);
    size_v := const_int(ir.t_i32, size);
    not_all_unk := const_int(ir.t_i1, 0);
    for i: 1..cast(s64) size - 1 {
        usd := irb_cast(b, .INTTOPTR, irb_binop(b, .ADD, sdi, const_int(s.intptr, (cast(u64) i) << s.ptr_shift)), pty);
        ild := irb_load(b, pty, usd, dl_abi_align(pty));
        not_all_unk = irb_binop(b, .OR, not_all_unk, irb_icmp(b, ICMP_NE, ild, const_null_value(pty)));
    }
    before_set := b.pt;
    but := sbi_if_then(not_all_unk, before_set, false, ubw);
    irb_set_before(b, but);
    san_call(b, s.check, .[irb_bitcast(b, ptr, pty), size_v, td, flags]);
    irb_set_before(b, before_set);
    set_type(s, b, td, sd, sdi, size, pty);
    irb_set_before(b, mismatch_term);
    san_call(b, s.check, .[irb_bitcast(b, ptr, pty), size_v, td, flags]);
    irb_set_before(b, good_term);
    not_all_bad := const_int(ir.t_i1, 0);
    for i: 1..cast(s64) size - 1 {
        bsd := irb_cast(b, .INTTOPTR, irb_binop(b, .ADD, sdi, const_int(s.intptr, (cast(u64) i) << s.ptr_shift)), pty);
        ild := irb_cast(b, .PTRTOINT, irb_load(b, pty, bsd, dl_abi_align(pty)), s.intptr);
        not_all_bad = irb_binop(b, .OR, not_all_bad, irb_icmp(b, ICMP_SGE, ild, const_int(s.intptr, 0)));
    }
    bit := sbi_if_then(not_all_bad, b.pt, false, ubw);
    irb_set_before(b, bit);
    san_call(b, s.check, .[irb_bitcast(b, ptr, pty), size_v, td, flags]);
    return true;
}

// instrumentMemInst
tysan_instrument_mem_inst :: (s: *Tysan, v: Value_Id, shadow_base_in: Value_Id, amm_in: Value_Id) -> bool {
    shadow_base := shadow_base_in; amm := amm_in;
    bb, ip: Value_Id; f: Value_Id; head := false;
    if vkind(v) == .INST { ip = v; bb = inst(v).parent; f = block_fn(bb); }
    else {
        f = arg_parent(v);
        bb = fn_entry(f);
        ip = block_first_insertion_pt(bb); head = true;
        if comes_before(ip, shadow_base) { ip = inst(shadow_base).next; head = false; }
        if comes_before(ip, amm) { ip = inst(amm).next; head = false; }
    }
    b: Irb; irb_set_at(*b, bb, ip, head);
    dest, size, src: Value_Id = NONE;
    needs_memmove := false;
    if vkind(v) == .ARGUMENT {
        dest = v;
        k := arg_numbers[ir.v_aux[v]];
        size = const_int(s.intptr, dl_type_alloc_size(attr_set_find(fn_param_attr_set(f, k), .ByVal).ty));
    } else {
        id := call_iid(v);
        if inst_op(v) == .CALL && asan_is_mem_intrinsic(v) {
            if type_addrspace(vtype(op(v, 0))) != 0 return false;
            dest = strip_pointer_casts(op(v, 0)); size = op(v, 2);   // MemIntrinsic::getDest: stripped
            if id == IID_MEMCPY || id == IID_MEMCPY_INLINE || id == IID_MEMMOVE {
                if type_addrspace(vtype(op(v, 1))) == 0 { src = strip_pointer_casts(op(v, 1)); needs_memmove = id == IID_MEMMOVE; }
            }
        } else if id == IID_LIFETIME_START || id == IID_LIFETIME_END {
            ai := op(v, 0);
            if !is_inst(ai) || inst_op(ai) != .ALLOCA return false;
            size = irb_allocation_size(*b, s.intptr, ai);
            dest = op(v, 0);
        } else if inst_op(v) == .ALLOCA {
            irb_set_before(*b, inst(v).next);
            // SetInstDebugLocation(I): the builder's location (now the next instruction's) goes onto the alloca
            if b.dbg != NONE set_metadata(v, 0, b.dbg);
            size = irb_allocation_size(*b, s.intptr, v);
            dest = v;
        } else return false;
    }
    pty := type_ptr(0);
    if tysan_cl.outline_instrumentation {
        if src == NONE src = const_null_value(pty);
        size64 := irb_zext_or_trunc_any(*b, size, type_int(64));
        san_call(*b, s.instrument_mem_inst, .[dest, src, size64, const_int(ir.t_i1, cast(u64) needs_memmove)]);
        return true;
    }
    if shadow_base == NONE shadow_base = tysan_get_shadow_base(s, f);
    if amm == NONE amm = tysan_get_app_mem_mask(s, f);
    sdi := irb_binop(*b, .ADD, irb_binop(*b, .SHL, irb_binop(*b, .AND, irb_cast(*b, .PTRTOINT, dest, s.intptr), amm), const_int(s.intptr, s.ptr_shift)), shadow_base);
    sd := irb_cast(*b, .INTTOPTR, sdi, pty);
    al := (cast(u64) 1) << s.ptr_shift;
    if src == NONE {
        irb_memset(*b, sd, const_int(ir.t_i8, 0), irb_binop(*b, .SHL, size, const_int(vtype(size), s.ptr_shift)), al, false);
        return true;
    }
    ssdi := irb_binop(*b, .ADD, irb_binop(*b, .SHL, irb_binop(*b, .AND, irb_cast(*b, .PTRTOINT, src, s.intptr), amm), const_int(s.intptr, s.ptr_shift)), shadow_base);
    ssd := irb_cast(*b, .INTTOPTR, ssdi, pty);
    len := irb_binop(*b, .SHL, size, const_int(vtype(size), s.ptr_shift));
    if needs_memmove irb_memmove_san(*b, sd, al, ssd, al, len);
    else irb_memcpy(*b, sd, al, ssd, al, len, false);
    return true;
}
// IRBuilder::CreateMemMove
irb_memmove_san :: (b: *Irb, dst: Value_Id, da: u64, src: Value_Id, sa: u64, size: Value_Id) -> Value_Id {
    ci := irb_intrinsic(b, "llvm.memmove", .[vtype(dst), vtype(src), vtype(size)], .[dst, src, size, const_int(ir.t_i1, 0)]);
    if da add_param_align(ci, 0, da);
    if sa add_param_align(ci, 1, sa);
    return ci;
}

// TypeSanitizer::sanitizeFunction
tysan_sanitize_function :: (s: *Tysan, f: Value_Id, t: *Tli) -> bool {
    if is_declaration(f) return false;
    if f == s.ctor_function.callee || f == s.globals_set_type_function return false;
    tysan_initialize_callbacks(s);
    accesses: [..] Value_Id; accesses.allocator = temp;
    tbaas: [..] Md_Id; tbaas.allocator = temp;
    resets: [..] Value_Id; resets.allocator = temp;
    nosanitize := md_kind_id("nosanitize");
    tbaa_kind := md_kind_id("tbaa");
    for i: fn_insts(f) {
        if get_metadata(i, nosanitize) != NONE continue;
        o := inst_op(i);
        if o == .LOAD || o == .STORE || o == .CMPXCHG || o == .ATOMICRMW {
            p := ifx o == .STORE then op(i, 1) else op(i, 0);
            if value_is_swift_error(p) continue;
            if type_addrspace(vtype(p)) != 0 continue;
            tag := get_metadata(i, tbaa_kind);
            if tag != NONE && !array_find(tbaas, tag) array_add(*tbaas, tag);
            array_add(*accesses, i);
        } else if o == .CALL || o == .INVOKE {
            if o == .CALL maybe_mark_sanitizer_library_call_no_builtin(i, t);
            id := call_iid(i);
            if (o == .CALL && asan_is_mem_intrinsic(i)) || id == IID_LIFETIME_START || id == IID_LIFETIME_END array_add(*resets, i);
        } else if o == .ALLOCA array_add(*resets, i);
    }
    for k: 0..cast(s64) glob(f).nargs - 1 if fn_has_param_attr(f, cast(u32) k, .ByVal) array_add(*resets, fn_arg(f, cast(u32) k));
    maps := tysan_maps();
    res := false;
    for md: tbaas {
        if table_find_pointer(*maps.descriptors, md) continue;
        if !tysan_generate_type_descriptor(s, md, *maps) return res;
        res = true;
    }
    sanitize := fn_has_fn_attr(f, .SanitizeType);
    no_instr := resets.count == 0 && accesses.count == 0;
    sb := ifx no_instr then NONE else tysan_get_shadow_base(s, f);
    amm := ifx no_instr then NONE else tysan_get_app_mem_mask(s, f);
    for i: accesses {
        b: Irb; irb_set_before(*b, i);
        o := inst_op(i);
        p := ifx o == .STORE then op(i, 1) else op(i, 0);
        vt := ifx o == .STORE then vtype(op(i, 0)) else (ifx o == .LOAD then vtype(i) else vtype(op(i, ifx o == .CMPXCHG then cast(u32) 1 else 1)));
        size := dl_type_store_size(vt);
        // mayReadFromMemory / mayWriteToMemory: a store reads and a load writes unless unordered
        is_read := o != .STORE || !is_unordered(i);
        is_write := o != .LOAD || !is_unordered(i);
        if tysan_instrument_with_shadow_update(s, *b, get_metadata(i, tbaa_kind), p, size, is_read, is_write, sb, amm, false, sanitize, *maps) res = true;
    }
    for resets if tysan_instrument_mem_inst(s, it, sb, amm) res = true;
    return res;
}

// TypeSanitizerPass::run
tysan_run :: () -> Preserved {
    ctor, init := create_sanitizer_ctor_and_init_functions("tysan.module_ctor", "__tysan_init", .[], .[], "");
    s := tysan_new();
    tysan_instrument_globals(*s);
    append_to_global_ctors(ctor, 0);
    fns: [..] Value_Id; fns.allocator = temp;
    for ir.m_functions array_add(*fns, it);
    for f: fns {
        tysan_sanitize_function(*s, f, tli_for(f));
        if tysan_cl.verify_outlined_instrumentation && tysan_cl.outline_instrumentation {
            tysan_cl.outline_instrumentation = false;
            tysan_sanitize_function(*s, f, tli_for(f));
            tysan_cl.outline_instrumentation = true;
        }
    }
    printer_note_ir_changed();
    return PRESERVE_NONE;
}
