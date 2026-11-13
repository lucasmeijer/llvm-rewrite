// NumericalStabilitySanitizer: a port of llvm/lib/Transforms/Instrumentation/NumericalStabilitySanitizer.cpp
// ("nsan": shadow values in a wider FP type, shadow stacks for arguments / returns, load / store shadow memory,
// fcmp checks, the widened intrinsic tables, cl::opts). -check-functions-filter (a Regex) fails loudly.

nsan_cl: struct {
    shadow_mapping := "dqq";
    instrument_fcmp := true;
    check_functions_filter: string;
    truncate_fcmp_eq := true;
    check_loads: bool;
    check_stores := true;
    check_ret := true;
    propagate_non_ft_const_stores_as_ft: bool;
};

nsan_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    pb :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("opt: for the --% option: '%' is invalid value for boolean argument! Try 0 or 1", name, value);
        return false;
    }
    o := *nsan_cl;
    if name == {
        case "nsan-shadow-type-mapping"; o.shadow_mapping = copy_string(value);
        case "nsan-instrument-fcmp"; o.instrument_fcmp = pb(name, value, has_value);
        case "check-functions-filter"; o.check_functions_filter = copy_string(value);
        case "nsan-truncate-fcmp-eq"; o.truncate_fcmp_eq = pb(name, value, has_value);
        case "nsan-check-loads"; o.check_loads = pb(name, value, has_value);
        case "nsan-check-stores"; o.check_stores = pb(name, value, has_value);
        case "nsan-check-ret"; o.check_ret = pb(name, value, has_value);
        case "nsan-propagate-non-ft-const-stores-as-ft"; o.propagate_non_ft_const_stores_as_ft = pb(name, value, has_value);
        case; return false;
    }
    return true;
}

NSAN_K_SHADOW_SCALE :: 2;
NSAN_K_MAX_VECTOR_WIDTH :: 8;
NSAN_K_MAX_NUM_ARGS :: 128;
NSAN_K_MAX_SHADOW_TYPE_SIZE_BYTES :: 16;

// FTValueType: 0 float, 1 double, 2 long double (x86_fp80)
nsan_ft_value_type :: (t: Type_Id) -> s64 {
    k := type_kind(t);
    if k == .FLOAT return 0;
    if k == .DOUBLE return 1;
    if k == .X86_FP80 return 2;
    return -1;
}
nsan_type_from_vt :: (vt: s64) -> Type_Id {
    if vt == 0 return type_simple(.FLOAT);
    if vt == 1 return type_simple(.DOUBLE);
    return type_simple(.X86_FP80);
}
NSAN_VT_NAMES :: string.["float", "double", "longdouble"];

Nsan :: struct {
    intptr: Type_Id;
    shadow_ids: [3] u8;
    shadow_tys: [3] Type_Id;
    get_shadow_ptr_for_store, get_shadow_ptr_for_load, check_value, fcmp_fail: [3] San_Callee;
    copy_fns: [4] San_Callee;          // fallback, 4, 8, 16
    set_unknown_fns: [4] San_Callee;
    get_raw_shadow_type_ptr, get_raw_shadow_ptr: San_Callee;
    shadow_ret_tag, shadow_ret_ptr, shadow_args_tag, shadow_args_ptr: Value_Id;
    shadow_ret_type, shadow_args_type: Type_Id;
    map: Table(Value_Id, Value_Id);
}

// MappingConfig: the shadow type of each FT value type
nsan_mapping_config :: (s: *Nsan) {
    m := nsan_cl.shadow_mapping;
    if m.count != 3 fatal("Invalid nsan mapping: %", m);
    bits: [3] u64;
    for vt: 0..2 {
        id := m[vt];
        t: Type_Id;
        if id == #char "d" t = type_simple(.DOUBLE);
        else if id == #char "l" t = type_simple(.X86_FP80);
        else if id == #char "q" t = type_simple(.FP128);
        else if id == #char "e" t = type_simple(.PPC_FP128);
        else fatal("nsan: invalid shadow type id '%'", string.{1, *m[vt]});
        app := dl_type_size_bits(nsan_type_from_vt(vt));
        sh := dl_type_size_bits(t);
        if type_kind(t) == .X86_FP80 sh = 80;
        if sh > NSAN_K_SHADOW_SCALE * app fatal("Invalid nsan mapping f%->f%: The shadow type size should be at most % times the application type size", app, sh, NSAN_K_SHADOW_SCALE);
        bits[vt] = sh;
        s.shadow_ids[vt] = id;
        s.shadow_tys[vt] = t;
    }
    if bits[0] > bits[1] || bits[1] > bits[2] fatal("Invalid nsan mapping: { float->f%; double->f%; long double->f% }", bits[0], bits[1], bits[2]);
}

// MappingConfig::getExtendedFPType (NONE for non-FT types)
nsan_extended_type :: (s: *Nsan, t: Type_Id) -> Type_Id {
    vt := nsan_ft_value_type(t);
    if vt >= 0 return s.shadow_tys[vt];
    if type_kind(t) == .VECTOR {
        e := nsan_extended_type(s, type_elem(t));
        if e == NONE return NONE;
        return type_vector(type_count(t), e, false);
    }
    return NONE;
}

// getMemoryExtentsOrDie: (value type, number of elements)
nsan_memory_extents :: (t: Type_Id) -> (s64, u64) {
    vt := nsan_ft_value_type(t);
    if vt >= 0 return vt, 1;
    if is_vector_type(t) { v, n := nsan_memory_extents(type_elem(t)); return v, n * type_count(t); }
    fatal("internal: nsan: invalid value type");
    return 0, 0;
}

// createThreadLocalGV
nsan_tls_gv :: (name: string, ty: Type_Id) -> Value_Id { return msan_get_or_insert_tls_global(name, ty); }

nsan_new :: () -> Nsan {
    s: Nsan;
    s.map.allocator = temp;
    nsan_mapping_config(*s);
    a: Attr; a.kind = .NoUnwind; a.ty = NONE;
    attr := attr_list_with_fn(0, attr_set_with(0, a));
    p := type_ptr(0); v := ir.t_void;
    s.intptr = type_int(dl_ptr_spec(0).bits);
    // NsanMemOpFn(M, Sized, Fallback, NumArgs)
    s.copy_fns[0] = san_callee("__nsan_copy_values", v, .[p, p, s.intptr], attr);
    for n, k: string.["__nsan_copy_4", "__nsan_copy_8", "__nsan_copy_16"] s.copy_fns[k + 1] = san_callee(n, v, .[p, p], attr);
    s.set_unknown_fns[0] = san_callee("__nsan_set_value_unknown", v, .[p, s.intptr], attr);
    for n, k: string.["__nsan_set_value_unknown_4", "__nsan_set_value_unknown_8", "__nsan_set_value_unknown_16"] s.set_unknown_fns[k + 1] = san_callee(n, v, .[p], attr);
    for vt: 0..2 {
        name := NSAN_VT_NAMES[vt];
        vtt := nsan_type_from_vt(vt);
        prefix := tconcat("__nsan_get_shadow_ptr_for_", name);
        s.get_shadow_ptr_for_store[vt] = san_callee(tconcat(prefix, "_store"), p, .[p, s.intptr], attr);
        s.get_shadow_ptr_for_load[vt] = san_callee(tconcat(prefix, "_load"), p, .[p, s.intptr], attr);
        st := s.shadow_tys[vt];
        id := string.{1, *s.shadow_ids[vt]};
        s.check_value[vt] = san_callee(tprint("__nsan_internal_check_%1_%2", name, id), ir.t_i32, .[vtt, st, ir.t_i32, s.intptr], attr);
        s.fcmp_fail[vt] = san_callee(tprint("__nsan_fcmp_fail_%1_%2", name, id), v, .[vtt, vtt, st, st, ir.t_i32, ir.t_i1, ir.t_i1], attr);
    }
    s.get_raw_shadow_type_ptr = san_callee("__nsan_internal_get_raw_shadow_type_ptr", p, .[p], attr);
    s.get_raw_shadow_ptr = san_callee("__nsan_internal_get_raw_shadow_ptr", p, .[p], attr);
    s.shadow_ret_tag = nsan_tls_gv("__nsan_shadow_ret_tag", s.intptr);
    s.shadow_ret_type = type_array(NSAN_K_MAX_VECTOR_WIDTH * NSAN_K_MAX_SHADOW_TYPE_SIZE_BYTES, ir.t_i8);
    s.shadow_ret_ptr = nsan_tls_gv("__nsan_shadow_ret_ptr", s.shadow_ret_type);
    s.shadow_args_tag = nsan_tls_gv("__nsan_shadow_args_tag", s.intptr);
    s.shadow_args_type = type_array(NSAN_K_MAX_VECTOR_WIDTH * NSAN_K_MAX_NUM_ARGS * NSAN_K_MAX_SHADOW_TYPE_SIZE_BYTES, ir.t_i8);
    s.shadow_args_ptr = nsan_tls_gv("__nsan_shadow_args_ptr", s.shadow_args_type);
    if nsan_cl.check_functions_filter.count fatal("nsan: -check-functions-filter (a regular expression) is not supported");
    return s;
}

// ValueToShadowMap
nsan_has_shadow :: (s: *Nsan, v: Value_Id) -> bool { return is_constant_kind(vkind(v)) || table_find(*s.map, v); }
nsan_get_shadow :: (s: *Nsan, v: Value_Id) -> Value_Id {
    if is_constant_kind(vkind(v)) return nsan_shadow_constant(s, v);
    found, r := table_find(*s.map, v);
    if !found fatal("internal: nsan: no shadow for a value");
    return r;
}
nsan_set_shadow :: (s: *Nsan, v: Value_Id, sh: Value_Id) {
    if table_find(*s.map, v) fatal("internal: nsan: duplicate shadow");
    table_set(*s.map, v, sh);
}
// getShadowConstant
nsan_shadow_constant :: (s: *Nsan, c: Value_Id) -> Value_Id {
    k := vkind(c);
    t := vtype(c);
    if k == .C_UNDEF || k == .C_POISON return const_undef(nsan_extended_type(s, t));
    if k == .C_FP {
        et := nsan_extended_type(s, t);   // also a splat vector constant (a C_FP of vector type)
        w, exact := fp_convert(type_kind(scalar_type(t)), type_kind(scalar_type(et)), const_fp_value(c));
        if !exact fatal("nsan: narrowing a constant to the shadow type (rmTowardZero) is not supported");
        return const_fp_words(et, w);
    }
    if is_vector_type(t) {
        n := type_count(t);
        els := NewArray(cast(s64) n, Value_Id,, temp);
        for i: 0..cast(s64) n - 1 els[i] = nsan_shadow_constant(s, cf_elt(c, cast(u64) i));
        return const_aggregate(.C_VECTOR, type_vector(n, vtype(els[0]), false), els);
    }
    fatal("internal: nsan: unimplemented shadow constant");
    return NONE;
}

// addrPointsToConstantData
nsan_addr_points_to_constant_data :: (addr_in: Value_Id) -> bool {
    addr := addr_in;
    if is_inst(addr) && inst_op(addr) == .GEP addr = op(addr, 0);
    if vkind(addr) == .GLOBAL_VAR return glob(addr).is_const;
    return false;
}

// IRBuilder::CreateConstGEP2_64(Ty, Ptr, 0, Idx1)
irb_const_gep2_64 :: (b: *Irb, ty: Type_Id, ptr: Value_Id, i0: u64, i1: u64) -> Value_Id {
    return irb_gep(b, ty, ptr, .[const_int(type_int(64), i0), const_int(type_int(64), i1)]);
}

// createShadowArguments
nsan_create_shadow_arguments :: (s: *Nsan, f: Value_Id) {
    n := cast(s64) glob(f).nargs;
    any := false;
    for k: 0..n-1 if nsan_extended_type(s, vtype(fn_arg(f, cast(u32) k))) != NONE any = true;
    if !any return;
    entry := fn_entry(f);
    b: Irb; irb_set_at(*b, entry, block_first_non_phi(entry), true);
    has := irb_icmp(*b, ICMP_EQ, irb_load(*b, s.intptr, s.shadow_args_tag, dl_abi_align(s.intptr)), irb_cast(*b, .PTRTOINT, f, s.intptr));
    off: u64 = 0;
    for k: 0..n-1 {
        a := fn_arg(f, cast(u32) k);
        et := nsan_extended_type(s, vtype(a));
        if et == NONE continue;
        l := irb_load(*b, et, irb_const_gep2_64(*b, s.shadow_args_type, s.shadow_args_ptr, 0, off), 1);
        sh := irb_select(*b, has, l, irb_cast(*b, .FPEXT, a, et));
        nsan_set_shadow(s, a, sh);
        off += dl_type_store_size(et);
    }
    irb_store(*b, const_int(s.intptr, 0), s.shadow_args_tag, dl_abi_align(s.intptr));
}

// shouldCheckArgs
nsan_should_check_args :: (s: *Nsan, ci: Value_Id) -> bool {
    fnv := call_called_function(ci);
    if fnv == NONE return true;
    if begins_with(vname(fnv), "__nsan_") return false;
    id := function_intrinsic_id(fnv);
    found, lf := tli_lookup_fn(fnv);
    if id == NOT_INTRINSIC && !found return true;
    if id == IID_FABS || (found && (lf == .fabsf || lf == .fabs || lf == .fabsl)) {
        u := ir.v_first_use[ci];
        while u != NONE {
            usr := ir.u_user[u];
            if is_inst(usr) && (inst_op(usr) == .ICMP || inst_op(usr) == .FCMP) return false;
            u = ir.u_next[u];
        }
    }
    return true;
}

// CheckLoc
Nsan_Check_Loc :: struct { kind: s64; address: Value_Id = NONE; arg_id: s64 = -1; }   // kind: 1 ret 2 arg 3 load 4 store 5 insert
nsan_check_loc_value :: (s: *Nsan, l: Nsan_Check_Loc, b: *Irb) -> Value_Id {
    if l.kind == 1 || l.kind == 5 return const_int(s.intptr, 0);
    if l.kind == 2 return const_int(s.intptr, cast(u64) l.arg_id);
    return irb_cast(b, .PTRTOINT, l.address, s.intptr);
}

// emitCheckInternal
nsan_emit_check_internal :: (s: *Nsan, v: Value_Id, sv: Value_Id, b: *Irb, l: Nsan_Check_Loc) -> Value_Id {
    if is_constant_kind(vkind(v)) return const_int(ir.t_i32, 0);
    t := vtype(v);
    vt := nsan_ft_value_type(t);
    if vt >= 0 return san_call(b, s.check_value[vt], .[v, sv, const_int(ir.t_i32, cast(u64) l.kind), nsan_check_loc_value(s, l, b)]);
    k := type_kind(t);
    if k == .VECTOR || k == .ARRAY {
        r: Value_Id = NONE;
        for i: 0..cast(s64) type_count(t) - 1 {
            ev := irb_extract_element(b, v, cast(u64) i);
            esv := irb_extract_element(b, sv, cast(u64) i);
            c := nsan_emit_check_internal(s, ev, esv, b, l);
            r = ifx r != NONE then irb_binop(b, .OR, r, c) else c;
        }
        return r;
    }
    if k == .STRUCT {
        r: Value_Id = NONE;
        for i: 0..cast(s64) type_nsub(t) - 1 {
            if nsan_extended_type(s, type_sub(t, cast(u32) i)) == NONE continue;
            ev := irb_extract_value(b, v, .[cast(u32) i]);
            esv := irb_extract_element(b, sv, cast(u64) i);
            c := nsan_emit_check_internal(s, ev, esv, b, l);
            r = ifx r != NONE then irb_binop(b, .OR, r, c) else c;
        }
        if r == NONE return const_int(ir.t_i32, 0);
        return r;
    }
    fatal("internal: nsan: check of an unsupported type");
    return NONE;
}
// emitCheck
nsan_emit_check :: (s: *Nsan, v: Value_Id, sv: Value_Id, b: *Irb, l: Nsan_Check_Loc) -> Value_Id {
    if is_constant_kind(vkind(v)) return sv;
    r := nsan_emit_check_internal(s, v, sv, b, l);
    eq := irb_icmp(b, ICMP_EQ, r, const_int(ir.t_i32, 1));
    return irb_select(b, eq, irb_cast(b, .FPEXT, v, nsan_extended_type(s, vtype(v))), sv);
}

// populateShadowStack
nsan_populate_shadow_stack :: (s: *Nsan, ci: Value_Id, t: *Tli) {
    if call_is_inline_asm(ci) return;
    n := cast(s64) nops(ci);
    any := false;
    for k: 0..n-1 if nsan_extended_type(s, vtype(op(ci, cast(u32) k))) != NONE any = true;
    if !any return;
    b: Irb; irb_set_before(*b, ci);
    shadows: [..] Value_Id; shadows.allocator = temp;
    check := nsan_should_check_args(s, ci);
    for k: 0..n-1 {
        a := op(ci, cast(u32) k);
        if nsan_extended_type(s, vtype(a)) == NONE continue;
        sh := nsan_get_shadow(s, a);
        array_add(*shadows, ifx check then nsan_emit_check(s, a, sh, *b, .{kind = 2, arg_id = k}) else sh);
    }
    fnv := call_called_function(ci);
    if fnv != NONE {
        found, _ := tli_lookup_fn(fnv);
        if glob(fnv).intrinsic || found return;
    }
    irb_store(*b, call_callee(ci), s.shadow_args_tag, dl_abi_align(vtype(call_callee(ci))));
    off: u64 = 0; id := 0;
    for k: 0..n-1 {
        a := op(ci, cast(u32) k);
        et := nsan_extended_type(s, vtype(a));
        if et == NONE continue;
        irb_store(*b, shadows[id], irb_const_gep2_64(*b, s.shadow_args_type, s.shadow_args_ptr, 0, off), 1);
        id += 1;
        off += dl_type_store_size(et);
    }
}

// emitFCmpCheck
nsan_emit_fcmp_check :: (s: *Nsan, fc: Value_Id) {
    if !nsan_cl.instrument_fcmp return;
    lhs := op(fc, 0); rhs := op(fc, 1);
    if nsan_extended_type(s, vtype(lhs)) == NONE return;
    bb := inst(fc).parent;
    next_bb := split_basic_block(bb, inst(fc).next, "");
    t := block_last(bb); drop_all_references(t); erase_inst(t);
    fail_bb := create_block(block_fn(bb), "", next_bb);
    fb: Irb; irb_set_end(*fb, bb); fb.dbg = get_metadata(fc, 0);
    sl := nsan_get_shadow(s, lhs); sr := nsan_get_shadow(s, rhs);
    pred := inst(fc).pred;
    if (pred == FCMP_OEQ || pred == FCMP_UEQ || pred == FCMP_ONE || pred == FCMP_UNE) && nsan_cl.truncate_fcmp_eq {
        ty := vtype(sl);
        sl = irb_cast(*fb, .FPEXT, irb_cast(*fb, .FPTRUNC, sl, vtype(lhs)), ty);
        sr = irb_cast(*fb, .FPEXT, irb_cast(*fb, .FPTRUNC, sr, vtype(rhs)), ty);
    }
    sfc := irb_fcmp_san(*fb, pred, sl, sr);
    match := irb_icmp(*fb, ICMP_EQ, fc, sfc);
    if is_vector_type(vtype(match)) match = msan_irb_and_reduce(*fb, match);
    br := irb_cond_br(*fb, match, next_bb, fail_bb);
    set_metadata(br, MDK_PROF, md_tuple(.[md_string("branch_weights"), md_value(const_int(ir.t_i32, 1048575)), md_value(const_int(ir.t_i32, 1))], false));
    xb: Irb; irb_set_end(*xb, fail_bb); xb.dbg = get_metadata(fc, 0);
    emit :: (s: *Nsan, xb: *Irb, l_in: Value_Id, r_in: Value_Id, shl: Value_Id, shr: Value_Id, res: Value_Id, sres: Value_Id, pred: u8) {
        l := l_in; r := r_in;
        ft := vtype(l);
        c: San_Callee;
        k := type_kind(ft);
        if k == .FLOAT c = s.fcmp_fail[0];
        else if k == .DOUBLE c = s.fcmp_fail[1];
        else if k == .X86_FP80 {
            c = s.fcmp_fail[1];
            l = irb_cast(xb, .FPTRUNC, l, type_simple(.DOUBLE));
            r = irb_cast(xb, .FPTRUNC, l, type_simple(.DOUBLE));   // sic: LLVM truncates L twice
        } else fatal("internal: nsan: fcmp on an unsupported type");
        san_call(xb, c, .[l, r, shl, shr, const_int(ir.t_i32, pred), res, sres]);
    }
    if is_vector_type(vtype(lhs)) {
        for i: 0..cast(s64) type_count(vtype(lhs)) - 1 {
            u := cast(u64) i;
            emit(s, *xb, irb_extract_element(*xb, lhs, u), irb_extract_element(*xb, rhs, u), irb_extract_element(*xb, sl, u),
                 irb_extract_element(*xb, sr, u), irb_extract_element(*xb, fc, u), irb_extract_element(*xb, sfc, u), pred);
        }
    } else emit(s, *xb, lhs, rhs, sl, sr, fc, sfc, pred);
    irb_br(*xb, next_bb);
}
// IRBuilder::CreateFCmp
irb_fcmp_san :: (b: *Irb, pred: u8, l: Value_Id, r: Value_Id) -> Value_Id {
    if irb_is_const(l) && irb_is_const(r) { f := cf_compare(pred, l, r); if f != NONE return f; }
    rt := ir.t_i1;
    if is_vector_type(vtype(l)) rt = type_vector(type_count(vtype(l)), ir.t_i1, type_kind(vtype(l)) == .SVECTOR);
    i := new_inst(.FCMP, rt, 2);
    inst(i).pred = pred;
    set_op(i, 0, l); set_op(i, 1, r);
    return irb_insert(b, i);
}

// handleLoad
nsan_handle_load :: (s: *Nsan, ld: Value_Id, vt: Type_Id, et: Type_Id) -> Value_Id {
    b: Irb; irb_next_node(*b, ld);
    if nsan_addr_points_to_constant_data(op(ld, 0)) return irb_cast(*b, .FPEXT, ld, et);
    evt, nelts := nsan_memory_extents(vt);
    sp := san_call(*b, s.get_shadow_ptr_for_load[evt], .[op(ld, 0), const_int(s.intptr, nelts)]);
    load_bb := inst(ld).parent;
    next_bb := split_basic_block(load_bb, b.pt, "");
    f := block_fn(load_bb);
    shadow_load_bb := create_block(f, "", next_bb);
    fext_bb := create_block(f, "", next_bb);
    {
        t := block_last(load_bb); drop_all_references(t); erase_inst(t);
        lb: Irb; irb_set_end(*lb, load_bb); lb.dbg = get_metadata(ld, 0);
        irb_cond_br(*lb, irb_icmp(*lb, ICMP_EQ, sp, const_null_value(vtype(sp))), fext_bb, shadow_load_bb);
    }
    sb: Irb; irb_set_end(*sb, shadow_load_bb); sb.dbg = get_metadata(ld, 0);
    sload := irb_load(*sb, et, sp, 1, (inst(ld).flags & F_VOLATILE) != 0);
    if nsan_cl.check_loads sload = nsan_emit_check(s, ld, sload, *sb, .{kind = 3, address = op(ld, 0)});
    irb_br(*sb, next_bb);
    fbb: Irb; irb_set_end(*fbb, fext_bb); fbb.dbg = get_metadata(ld, 0);
    fext := irb_cast(*fbb, .FPEXT, ld, et);
    irb_br(*fbb, next_bb);
    nb: Irb; irb_set_before(*nb, block_first(next_bb)); nb.dbg = get_metadata(ld, 0);
    phi := irb_phi(*nb, et, 2);
    phi_add_incoming(phi, sload, shadow_load_bb);
    phi_add_incoming(phi, fext, fext_bb);
    return phi;
}

// handleTrunc / handleExt
nsan_handle_trunc_ext :: (s: *Nsan, i: Value_Id, et: Type_Id, b: *Irb, is_trunc: bool) -> Value_Id {
    src := op(i, 0);
    est := nsan_extended_type(s, vtype(src));
    source := ifx est != NONE then nsan_get_shadow(s, src) else src;
    st := ifx est != NONE then est else vtype(src);
    if st == et return source;
    return irb_cast(b, ifx is_trunc then Opcode.FPTRUNC else .FPEXT, source, et);
}

// KnownIntrinsic::kWidenedIntrinsics: (narrow name, wide base name, function type kind)
Nsan_Widened :: struct { narrow: string; wide: string; ft: u8; }   // ft: 0 dd 1 ee 2 ddi 3 eei 4 ddd 5 eee 6 dddd 7 eeee
NSAN_WIDENED :: #run nsan_build_widened();
nsan_build_widened :: () -> [] Nsan_Widened {
    r: [..] Nsan_Widened;
    add :: (r: *[..] Nsan_Widened, base: string, d: u8, e: u8) {
        array_add(r, .{tprint("llvm.%.f32", base), tprint("llvm.%", base), d});
        array_add(r, .{tprint("llvm.%.f64", base), tprint("llvm.%", base), e});
        array_add(r, .{tprint("llvm.%.f80", base), tprint("llvm.%", base), e});
    }
    add(*r, "sqrt", 0, 1); add(*r, "powi", 2, 3); add(*r, "sin", 0, 1); add(*r, "cos", 0, 1); add(*r, "pow", 4, 5);
    add(*r, "exp", 0, 1); add(*r, "exp2", 0, 1); add(*r, "log", 0, 1); add(*r, "log10", 0, 1); add(*r, "log2", 0, 1);
    add(*r, "fma", 6, 7); add(*r, "fmuladd", 6, 7); add(*r, "fabs", 0, 1); add(*r, "minnum", 4, 5); add(*r, "maxnum", 4, 5);
    add(*r, "minimum", 4, 5); add(*r, "maximum", 4, 5); add(*r, "minimumnum", 4, 5); add(*r, "maximumnum", 4, 5);
    add(*r, "copysign", 4, 5); add(*r, "floor", 0, 1); add(*r, "ceil", 0, 1); add(*r, "trunc", 0, 1); add(*r, "rint", 0, 1);
    add(*r, "nearbyint", 0, 1); add(*r, "round", 0, 1);
    return r;
}
nsan_widened_fn_type :: (k: u8) -> Type_Id {
    d := type_simple(.DOUBLE); e := type_simple(.X86_FP80); i := ir.t_i32;
    if k == {
        case 0; return type_func(d, .[d], false);
        case 1; return type_func(e, .[e], false);
        case 2; return type_func(d, .[d, i], false);
        case 3; return type_func(e, .[e, i], false);
        case 4; return type_func(d, .[d, d], false);
        case 5; return type_func(e, .[e, e], false);
        case 6; return type_func(d, .[d, d, d], false);
    }
    return type_func(e, .[e, e, e], false);
}
// KnownIntrinsic::kLibfuncIntrinsics: libm name -> the intrinsic name
nsan_libfunc_intrinsic :: (name: string) -> string {
    bases :: string.["sqrt", "sin", "cos", "pow", "exp", "exp2", "log", "log10", "log2", "fabs", "copysign", "floor",
                     "ceil", "trunc", "rint", "nearbyint", "round"];
    for bases {
        if name == tconcat(it, "f") return tprint("llvm.%.f32", it);
        if name == it return tprint("llvm.%.f64", it);
        if name == tconcat(it, "l") return tprint("llvm.%.f80", it);
    }
    pairs :: [2] string.[.["fmax", "maxnum"], .["fmin", "minnum"], .["fmaximum_num", "maximumnum"], .["fminimum_num", "minimumnum"]];
    for pairs {
        if name == tconcat(it[0], "f") return tprint("llvm.%.f32", it[1]);
        if name == it[0] return tprint("llvm.%.f64", it[1]);
        if name == tconcat(it[0], "l") return tprint("llvm.%.f80", it[1]);
    }
    return "";
}

// maybeHandleKnownCallBase
nsan_maybe_handle_known_call_base :: (s: *Nsan, call: Value_Id, vt: Type_Id, et: Type_Id, b: *Irb) -> Value_Id {
    fnv := call_called_function(call);
    if fnv == NONE return NONE;
    wide: string; wft: Type_Id;
    id := function_intrinsic_id(fnv);
    find_widened :: (n: string) -> *Nsan_Widened { for * NSAN_WIDENED if it.narrow == n return it; return null; }
    if id != NOT_INTRINSIC {
        w := find_widened(vname(fnv));
        if w { wide = w.wide; wft = nsan_widened_fn_type(w.ft); }
        else { wide = vname(fnv); wft = glob(fnv).value_type; }
    } else {
        found, lf := tli_lookup_fn(fnv);
        if !found return NONE;
        n := nsan_libfunc_intrinsic(vname(fnv));
        if n.count == 0 return NONE;
        w := find_widened(n);
        if !w fatal("internal: nsan: inconsistent KnownIntrinsic tables");
        wide = w.wide; wft = nsan_widened_fn_type(w.ft);
    }
    args: [..] Value_Id; args.allocator = temp;
    for k: 0..cast(s64) nops(call) - 2 {
        a := op(call, cast(u32) k);
        pt := func_param(wft, cast(u32) k);
        if vtype(a) == pt { array_add(*args, a); continue; }
        sat := nsan_extended_type(s, vtype(a));
        if sat == NONE fatal("internal: nsan: don't know how to get the shadow value for a non-FT");
        sh := nsan_get_shadow(s, a);
        if sat == pt { array_add(*args, sh); continue; }
        array_add(*args, irb_cast(b, .FPTRUNC, sh, pt));
    }
    // Intrinsic::isSignatureValid(WidenedId, WidenedFnTy, OverloadTys) + CreateIntrinsic(ID, OverloadTys, Args)
    f := fnv;   // not in the widening table: the same intrinsic (and function type)
    if wide != vname(fnv) || wft != glob(fnv).value_type {
        otys: [..] Type_Id; otys.allocator = temp;
        array_add(*otys, func_ret(wft));
        if wide == "llvm.powi" array_add(*otys, ir.t_i32);
        f = get_or_insert_intrinsic_declaration(intrinsic_id_by_name(wide), otys);
    }
    c := san_call(b, .{glob(f).value_type, f}, args);
    if func_ret(wft) == et return c;
    return irb_cast(b, .FPEXT, c, et);
}

// handleCallBase
nsan_handle_call_base :: (s: *Nsan, call: Value_Id, vt: Type_Id, et: Type_Id, b: *Irb) -> Value_Id {
    if call_is_inline_asm(call) return irb_cast(b, .FPEXT, call, et);
    v := nsan_maybe_handle_known_call_base(s, call, vt, et, b);
    if v != NONE return v;
    l := irb_load(b, s.intptr, s.shadow_ret_tag, dl_abi_align(s.intptr));
    has := irb_icmp(b, ICMP_EQ, l, irb_cast(b, .PTRTOINT, call_callee(call), s.intptr));
    srv := irb_load(b, et, irb_const_gep2_64(b, s.shadow_ret_type, s.shadow_ret_ptr, 0, 0), dl_abi_align(et));
    return irb_select(b, has, srv, irb_cast(b, .FPEXT, call, et));
}

// createShadowValueWithOperandsAvailable
nsan_create_shadow_value :: (s: *Nsan, i: Value_Id) -> Value_Id {
    vt := vtype(i);
    et := nsan_extended_type(s, vt);
    o := inst_op(i);
    if o == .LOAD return nsan_handle_load(s, i, vt, et);
    if o == .CALL {
        b: Irb; irb_set_at(*b, inst(i).parent, inst(i).next, false); b.dbg = get_metadata(i, 0);
        return nsan_handle_call_base(s, i, vt, et, *b);
    }
    if o == .INVOKE {
        invoke_bb := inst(i).parent;
        next_bb := get_successor(i, 0);
        nbb := create_block(block_fn(next_bb), "", next_bb);
        set_successor(i, 0, nbb);   // replaceSuccessorWith(NextBB, NewBB)
        if get_successor(i, 1) == next_bb set_successor(i, 1, nbb);
        b: Irb; irb_set_end(*b, nbb); b.dbg = get_metadata(i, 0);
        sh := nsan_handle_call_base(s, i, vt, et, *b);
        irb_br(*b, next_bb);
        block_replace_successors_phi_uses_with(nbb, invoke_bb, nbb);
        return sh;
    }
    b: Irb; irb_next_node(*b, i);
    if o == .FPTRUNC return nsan_handle_trunc_ext(s, i, et, *b, true);
    if o == .FPEXT return nsan_handle_trunc_ext(s, i, et, *b, false);
    if o == .FNEG {
        x := nsan_get_shadow(s, op(i, 0));
        if irb_is_const(x) { f := cf_unary(.FNEG, x); if f != NONE return f; }
        ni := new_inst(.FNEG, vtype(x), 1); set_op(ni, 0, x);
        return irb_insert(*b, ni);
    }
    if is_binary_op(o) return irb_binop(*b, o, nsan_get_shadow(s, op(i, 0)), nsan_get_shadow(s, op(i, 1)));
    if o == .UITOFP || o == .SITOFP return irb_cast(*b, o, op(i, 0), et);
    if o == .SELECT return irb_select(*b, op(i, 0), nsan_get_shadow(s, op(i, 1)), nsan_get_shadow(s, op(i, 2)));
    if o == .FREEZE {
        x := nsan_get_shadow(s, op(i, 0));
        fr := new_inst(.FREEZE, vtype(x), 1); set_op(fr, 0, x);
        return irb_insert(*b, fr);
    }
    if o == .EXTRACTELEMENT return irb_extract_element_v(*b, nsan_get_shadow(s, op(i, 0)), op(i, 1));
    if o == .INSERTELEMENT return irb_insert_element_v(*b, nsan_get_shadow(s, op(i, 0)), nsan_get_shadow(s, op(i, 1)), op(i, 2));
    if o == .SHUFFLEVECTOR {
        mask := NewArray(cast(s64) inst(i).nidx, u32,, temp);
        for * mask it.* = ir.u32_pool[inst(i).idx + cast(u32) it_index];
        return irb_shuffle(*b, nsan_get_shadow(s, op(i, 0)), nsan_get_shadow(s, op(i, 1)), mask);
    }
    if o == .EXTRACTVALUE || o == .BITCAST return irb_cast(*b, .FPEXT, i, et);
    fatal("Unimplemented support for %", opcode_name(o));
    return NONE;
}

// maybeCreateShadowValue
nsan_maybe_create_shadow_value :: (s: *Nsan, root: Value_Id) {
    if nsan_extended_type(s, vtype(root)) == NONE return;
    if nsan_has_shadow(s, root) return;
    stack: [..] Value_Id; stack.allocator = temp;
    array_add(*stack, root);
    while stack.count {
        i := stack[stack.count - 1];
        if nsan_has_shadow(s, i) { pop(*stack); continue; }
        missing := false;
        for k: 0..cast(s64) nops(i) - 1 {
            x := op(i, cast(u32) k);
            if nsan_extended_type(s, vtype(x)) == NONE continue;
            if nsan_has_shadow(s, x) continue;
            missing = true;
            if !is_inst(x) fatal("internal: nsan: an FT operand without a shadow that is not an instruction");
            array_add(*stack, x);
        }
        if missing continue;
        sh := nsan_create_shadow_value(s, i);
        nsan_set_shadow(s, i, sh);
        pop(*stack);
    }
}

// propagateFTStore / propagateNonFTStore
nsan_propagate_ft_store :: (s: *Nsan, st: Value_Id, vt: Type_Id, et: Type_Id, f: Value_Id) {
    v := op(st, 0);
    b: Irb; irb_set_before(*b, st); b.dbg = get_metadata(st, 0);
    evt, n := nsan_memory_extents(vt);
    sp := san_call(*b, s.get_shadow_ptr_for_store[evt], .[op(st, 1), const_int(s.intptr, n)]);
    ss := nsan_get_shadow(s, v);
    if !fn_has_fn_attr(f, .OptimizeNone) && nsan_cl.check_stores
        ss = nsan_emit_check(s, v, ss, *b, .{kind = 4, address = op(st, 1)});
    irb_store(*b, ss, sp, 1, (inst(st).flags & F_VOLATILE) != 0);
}
nsan_propagate_non_ft_store :: (s: *Nsan, st: Value_Id, vt: Type_Id) {
    ptr := op(st, 1);
    b: Irb; irb_next_node(*b, st);
    size := dl_type_store_size(vt);
    // a scalable store: LLVM (release) takes the known minimum size (TypeSize::getFixedValue asserts only)
    vsize := const_int(s.intptr, size);
    v := op(st, 0);
    if is_inst(v) && inst_op(v) == .LOAD {
        sty := type_int(8 * size);
        svy := type_int(8 * NSAN_K_SHADOW_SCALE * size);
        lb: Irb; irb_set_before(*lb, inst(v).next);   // IRBuilder LoadBuilder(Load->getNextNode()): the load's location
        src := op(v, 0);
        rst := irb_load(*lb, sty, san_call(*lb, s.get_raw_shadow_type_ptr, .[src]), 1);
        rsv := irb_load(*lb, svy, san_call(*lb, s.get_raw_shadow_ptr, .[src]), 1);
        irb_store(*b, rst, san_call(*b, s.get_raw_shadow_type_ptr, .[ptr]), 1);
        irb_store(*b, rsv, san_call(*b, s.get_raw_shadow_ptr, .[ptr]), 1);
        return;
    }
    if nsan_cl.propagate_non_ft_const_stores_as_ft && is_constant_kind(vkind(v)) {
        bt: Type_Id = NONE;
        if vkind(v) == .C_INT || (vkind(v) == .C_DATA && is_vector_type(vtype(v))) {
            bits := type_bits(scalar_type(vtype(v)));
            if bits == 32 bt = type_simple(.FLOAT);
            else if bits == 64 bt = type_simple(.DOUBLE);
            else if bits == 80 bt = type_simple(.X86_FP80);
            if bt != NONE && is_vector_type(vtype(v)) bt = type_vector(type_count(vtype(v)), bt, false);
        }
        if bt != NONE {
            evt, n := nsan_memory_extents(bt);
            sp := san_call(*b, s.get_shadow_ptr_for_store[evt], .[ptr, const_int(s.intptr, n)]);
            ext := nsan_extended_type(s, bt);
            sh := irb_cast(*b, .FPEXT, irb_bitcast(*b, v, bt), ext);
            irb_store(*b, sh, sp, 1, (inst(st).flags & F_VOLATILE) != 0);
            return;
        }
    }
    san_call(*b, s.set_unknown_fns[0], .[ptr, vsize]);
}

// GetMemOpSize / instrumentMemIntrinsic
nsan_mem_op_index :: (v: Value_Id) -> s64 {
    sz: u64 = 0;
    if vkind(v) == .C_INT && type_int_width(vtype(v)) <= 64 sz = const_int_zext(v);
    return ifx sz == 4 then 1 else ifx sz == 8 then 2 else ifx sz == 16 then 3 else 0;
}
nsan_instrument_mem_intrinsic :: (s: *Nsan, mi: Value_Id) {
    b: Irb; irb_set_before(*b, mi);
    id := call_iid(mi);
    if id == IID_MEMSET || id == IID_MEMSET_INLINE {
        c := s.set_unknown_fns[nsan_mem_op_index(op(mi, 2))];
        if func_nparams(c.fty) == 1 san_call(*b, c, .[op(mi, 0)]);
        else san_call(*b, c, .[op(mi, 0), irb_int_cast(*b, op(mi, 2), s.intptr, false)]);
    } else {
        c := s.copy_fns[nsan_mem_op_index(op(mi, 2))];
        if func_nparams(c.fty) == 2 san_call(*b, c, .[op(mi, 0), op(mi, 1)]);
        else san_call(*b, c, .[op(mi, 0), op(mi, 1), irb_int_cast(*b, op(mi, 2), s.intptr, false)]);
    }
}

// maybeAddSuffixForNsanInterface
nsan_maybe_add_suffix :: (s: *Nsan, ci: Value_Id) {
    fnv := call_called_function(ci);
    if fnv == NONE || !begins_with(vname(fnv), "__nsan_") return;
    if vname(fnv) == "__nsan_dump_shadow_mem" {
        ids := ((cast(u64) s.shadow_ids[2]) << 16) | ((cast(u64) s.shadow_ids[1]) << 8) | cast(u64) s.shadow_ids[0];
        set_op(ci, 3, const_int(s.intptr, ids));
    }
}

// propagateShadowValues
nsan_propagate_shadow_values :: (s: *Nsan, i: Value_Id, f: Value_Id, t: *Tli) {
    o := inst_op(i);
    if o == .STORE {
        vt := vtype(op(i, 0));
        et := nsan_extended_type(s, vt);
        if et == NONE nsan_propagate_non_ft_store(s, i, vt);
        else nsan_propagate_ft_store(s, i, vt, et, f);
        return;
    }
    if o == .FCMP { nsan_emit_fcmp_check(s, i); return; }
    if is_call_base(i) {
        nsan_maybe_add_suffix(s, i);
        if o == .CALL maybe_mark_sanitizer_library_call_no_builtin(i, t);
        if o == .CALL && asan_is_mem_intrinsic(i) { nsan_instrument_mem_intrinsic(s, i); return; }
        nsan_populate_shadow_stack(s, i, t);
        return;
    }
    if o == .RET {
        if !nsan_cl.check_ret || nops(i) == 0 return;
        rv := op(i, 0);
        et := nsan_extended_type(s, vtype(rv));
        if et == NONE return;
        rs := nsan_get_shadow(s, rv);
        b: Irb; irb_set_before(*b, i);
        rs = nsan_emit_check(s, rv, rs, *b, .{kind = 1});
        fa := irb_cast(*b, .PTRTOINT, f, s.intptr);
        irb_store(*b, fa, s.shadow_ret_tag, dl_abi_align(s.intptr));
        p := irb_const_gep2_64(*b, s.shadow_ret_type, s.shadow_ret_ptr, 0, 0);
        irb_store(*b, rs, p, dl_abi_align(vtype(rs)));
        return;
    }
    if o == .INSERTVALUE {
        v := op(i, 1);
        if nsan_extended_type(s, vtype(v)) == NONE return;
        b: Irb; irb_set_before(*b, i);
        nsan_emit_check(s, v, nsan_get_shadow(s, v), *b, .{kind = 5});
    }
}

// sanitizeFunction
nsan_sanitize_function :: (s: *Nsan, f: Value_Id, t: *Tli) -> bool {
    if !fn_has_fn_attr(f, .SanitizeNumericalStability) || is_declaration(f) return false;
    if vname(f) == "nsan.module_ctor" return false;
    insts: [..] Value_Id; insts.allocator = temp;
    for i: fn_insts(f) array_add(*insts, i);
    // moveFastMathFlags: "no-signed-zeros-fp-math"="true" becomes nsz; every FP math operator's flags are replaced
    fmf: u32 = 0;
    a := fn_find_str_attr(f, "no-signed-zeros-fp-math");
    if a && a.val == "true" { fn_remove_str_attr(f, "no-signed-zeros-fp-math"); fmf = FMF_NSZ; }
    for insts if is_fp_math_operator(it) set_fmf(it, get_fmf(it) | fmf);   // setFastMathFlags ORs
    table_reset(*s.map);
    phis: [..] Value_Id; phis.allocator = temp;
    nsan_create_shadow_arguments(s, f);
    for i: insts if inst_op(i) == .PHI {
        et := nsan_extended_type(s, vtype(i));
        if et == NONE continue;
        sh := create_phi(et, phi_num_incoming(i));
        inst_insert_after(sh, i);
        array_add(*phis, i);
        nsan_set_shadow(s, i, sh);
    }
    for insts nsan_maybe_create_shadow_value(s, it);
    for insts nsan_propagate_shadow_values(s, it, f, t);
    for p: phis {
        sp := nsan_get_shadow(s, p);
        for k: 0..cast(s64) phi_num_incoming(p) - 1 phi_add_incoming(sp, nsan_get_shadow(s, op(p, cast(u32) k)), phi_block(p, cast(u32) k));
    }
    return s.map.count != 0;
}

// NumericalStabilitySanitizerPass::run ("nsan")
nsan_run :: () -> Preserved {
    ctor, init, created := get_or_create_sanitizer_ctor_and_init_functions("nsan.module_ctor", "__nsan_init", .[], .[], "");
    if created append_to_global_ctors(ctor, 0);
    s := nsan_new();
    fns: [..] Value_Id; fns.allocator = temp;
    for ir.m_functions array_add(*fns, it);
    for f: fns nsan_sanitize_function(*s, f, tli_for(f));
    printer_note_ir_changed();
    return PRESERVE_NONE;
}
