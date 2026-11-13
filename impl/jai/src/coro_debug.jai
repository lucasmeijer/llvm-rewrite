// Debug info for coroutine frames: the artificial "__coro_frame" variable and its DICompositeType describing the
// frame layout, and the __coro_resume_N labels of the switch ABI's resume points.
// Ported from llvm/lib/Transforms/Coroutines/CoroFrame.cpp (cacheDIVar, solveTypeName, solveDIType,
// buildFrameDebugInfo), llvm/lib/Transforms/Coroutines/CoroSplit.cpp (the labels in createResumeEntryBlock) and the
// DIBuilder methods they use (llvm/lib/IR/DIBuilder.cpp: createBasicType, createPointerType, createMemberType,
// createStructType, createArrayType, getOrCreateSubrange, createAutoVariable, createLabel, replaceArrays,
// insertLabel).
//
// Integer size / offset operands follow the parser's convention (0 = no operand, else an i64 ConstantAsMetadata),
// so nodes built here unique with equal nodes read from the input.

DWT_BASE_TYPE :: 0x24; DWT_POINTER_TYPE :: 0x0f; DWT_MEMBER :: 0x0d; DWT_STRUCTURE_TYPE :: 0x13; DWT_ARRAY_TYPE :: 0x01;
DWATE_SIGNED :: 0x05; DWATE_FLOAT :: 0x04; DWATE_UNSIGNED_CHAR :: 0x08;

dib_size_md :: (v: u64) -> Md_Id { if v == 0 return NONE; return md_i64(v); }

// DIBuilder::createBasicType(Name, SizeInBits, Encoding, Flags)
dib_basic_type :: (name: string, size_bits: u64, encoding: u64, flags: u64) -> Md_Id {
    return di_get(.BASIC_TYPE, false, .[NONE, NONE, dib_str(name), dib_size_md(size_bits), NONE], .[DWT_BASE_TYPE, 0, 0, encoding, 0, 0, flags]);
}
// DIBuilder::createPointerType(PointeeTy, SizeInBits, AlignInBits, DWARFAddressSpace = none, Name)
dib_pointer_type :: (pointee: Md_Id, size_bits: u64, align_bits: u64, name: string) -> Md_Id {
    return di_get(.DERIVED_TYPE, false, .[NONE, NONE, dib_str(name), dib_size_md(size_bits), NONE, pointee, NONE, NONE],
                  .[DWT_POINTER_TYPE, 0, align_bits, 0xFFFF_FFFF, 0, 0, 0, 0, 0, 0]);
}
// DIBuilder::createMemberType
dib_member_type :: (scope: Md_Id, name: string, file: Md_Id, line: u64, size_bits: u64, align_bits: u64, offset_bits: u64,
                    flags: u64, ty: Md_Id) -> Md_Id {
    return di_get(.DERIVED_TYPE, false, .[file, dib_non_cu_scope(scope), dib_str(name), dib_size_md(size_bits), dib_size_md(offset_bits), ty, NONE, NONE],
                  .[DWT_MEMBER, line, align_bits, 0xFFFF_FFFF, flags, 0, 0, 0, 0, 0]);
}
// DIBuilder::createStructType(Context, Name, File, Line, SizeInBits, AlignInBits, Flags, nullptr, {})
dib_struct_type :: (ctx: Md_Id, name: string, file: Md_Id, line: u64, size_bits: u64, align_bits: u64, flags: u64) -> Md_Id {
    ops := Md_Id.[file, dib_non_cu_scope(ctx), dib_str(name), dib_size_md(size_bits), NONE, NONE, NONE, NONE, NONE,
                  NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE];
    return di_get(.COMPOSITE_TYPE, false, ops, .[DWT_STRUCTURE_TYPE, line, 0, align_bits, 0, 0xFFFF_FFFF, flags]);
}
// DIBuilder::createArrayType(Size, AlignInBits, Ty, Subscripts)
dib_array_type :: (size_bits: u64, align_bits: u64, ty: Md_Id, subscripts: Md_Id) -> Md_Id {
    ops := Md_Id.[NONE, NONE, NONE, dib_size_md(size_bits), NONE, ty, subscripts, NONE, NONE,
                  NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE];
    return di_get(.COMPOSITE_TYPE, false, ops, .[DWT_ARRAY_TYPE, 0, 0, align_bits, 0, 0xFFFF_FFFF, 0]);
}
// DIBuilder::getOrCreateSubrange(Lo, Count)
dib_subrange :: (lo: s64, count: s64) -> Md_Id {
    return di_get(.SUBRANGE, false, .[md_i64(cast(u64) count), md_i64(cast(u64) lo), NONE, NONE], .[]);
}
// getNonCompileUnitScope
dib_non_cu_scope :: (s: Md_Id) -> Md_Id { if s == NONE || is_di(s, .COMPILE_UNIT) return NONE; return s; }

// MDNode::replaceOperandWith on a uniqued node: the node is re-uniqued under its new contents
md_uniqued_replace_operand :: (m: Md_Id, idx: u32, v: Md_Id) {
    r := ir.mds[m];
    ints: [] u64; ints.data = ir.md_ints.data + r.ints; ints.count = r.nints;
    ops: [] Md_Id; ops.data = ir.md_ops.data + r.ops; ops.count = r.nops;
    if !r.distinct {
        k := md_special_key(r.sub, ints, ops);
        found, cur := table_find(*ir.md_map, key_view(k));
        if found && cur == m table_remove(*ir.md_map, key_view(k));
    }
    ir.md_ops[r.ops + idx] = v;
    if !r.distinct {
        k := md_special_key(r.sub, ints, ops);
        if table_contains(*ir.md_map, key_view(k)) fatal("coroutines: a re-uniqued debug info node collides with an existing node (not supported)");
        table_add(*ir.md_map, key_copy(k), m);
    }
}

ditype_name :: (t: Md_Id) -> string { if t == NONE return ""; return md_str_of(di_op(t, 2)); }
ditype_align_bits :: (t: Md_Id) -> u64 {
    if t == NONE return 0;
    k := di_kind(t);
    if k == .COMPOSITE_TYPE return di_int(t, 3);
    if k == .BASIC_TYPE || k == .DERIVED_TYPE return di_int(t, 2);
    return 0;
}

// cacheDIVar
coro_cache_di_var :: (f: Value_Id, defs: [] Value_Id, cache: *Table(Value_Id, Md_Id)) {
    recs: [..] u32; recs.allocator = temp;
    for v: defs {
        if table_contains(cache, v) continue;
        for kind: Dbg_Record_Kind.[.DECLARE, .DECLARE_VALUE] {
            coro_find_dbg_records(f, v, kind, *recs);
            for r: recs {
                if diexpr_elts(dbgr(r).expr).count == 0 {
                    if !table_contains(cache, v) table_set(cache, v, dbgr(r).var);
                    break;
                }
            }
        }
    }
}

// solveTypeName
coro_solve_type_name :: (t: Type_Id) -> string {
    if is_int_type(t) return tconcat("__int_", tdec(cast(u64) type_int_width(t)));
    if is_fp_type(t) {
        if type_kind(t) == .FLOAT return "__float_";
        if type_kind(t) == .DOUBLE return "__double_";
        return "__floating_type_";
    }
    if is_ptr_type(t) return "PointerType";
    if type_kind(t) == .STRUCT {
        name := ir.types[t].name;
        if name.count == 0 return "__LiteralStructType_";
        buf := copy_string(name,, allocator = temp);
        for k: 0..buf.count - 1 if buf[k] == #char "." || buf[k] == #char ":" buf[k] = #char "_";
        return buf;
    }
    return "UnknownType";
}

// solveDIType
coro_solve_di_type :: (t: Type_Id, scope: Md_Id, line: u64, cache: *Table(Type_Id, Md_Id)) -> Md_Id {
    found, c := table_find(cache, t);
    if found return c;
    name := coro_solve_type_name(t);
    ret: Md_Id = NONE;
    if is_int_type(t) {
        ret = dib_basic_type(name, type_int_width(t), DWATE_SIGNED, DI_FLAG_ARTIFICIAL);
    } else if is_fp_type(t) {
        ret = dib_basic_type(name, dl_type_size_bits(t), DWATE_FLOAT, DI_FLAG_ARTIFICIAL);
    } else if is_ptr_type(t) {
        ret = dib_pointer_type(NONE, dl_type_size_bits(t), dl_abi_align(t) * 8, name);
    } else if type_kind(t) == .STRUCT {
        ds := dib_struct_type(scope, name, di_op(scope, 0), line, dl_type_size_bits(t), dl_pref_align(t) * 8, DI_FLAG_ARTIFICIAL);
        elts: [..] Md_Id; elts.allocator = temp;
        n := type_nsub(t);
        for k: 0..cast(s64) n - 1 {
            dt := coro_solve_di_type(type_sub(t, cast(u32) k), ds, line, cache);
            array_add(*elts, dib_member_type(ds, ditype_name(dt), di_op(ds, 0), line, (ifx dt == NONE then cast(u64) 0 else ditype_size_bits(dt)), ditype_align_bits(dt),
                                             dl_struct_offset(t, cast(u32) k) * 8, DI_FLAG_ARTIFICIAL, dt));
        }
        md_uniqued_replace_operand(ds, 6, md_tuple(elts, false));   // replaceArrays
        ret = ds;
    } else {
        size := dl_type_size_bits(t);
        char_ty := dib_basic_type(name, 8, DWATE_UNSIGNED_CHAR, DI_FLAG_ARTIFICIAL);
        if size <= 8 ret = char_ty;
        else {
            if size % 8 != 0 size = size + 8 - (size % 8);
            ret = dib_array_type(size, dl_pref_align(t), char_ty, md_tuple(.[dib_subrange(0, cast(s64)(size / 8))], false));
        }
    }
    table_set(cache, t, ret);
    return ret;
}

// buildFrameDebugInfo
coro_build_frame_debug_info :: (f: Value_Id, shape: *Coro_Shape, fd: *Frame_Data) {
    dis := get_metadata(f, MDK_DBG);
    if dis == NONE || !is_di(dis, .SUBPROGRAM) return;
    cu := di_op(dis, 5);
    if cu == NONE return;
    if !coro_di_lang_is_cplusplus(cu) || di_int(cu, 6) != 1 return;   // FullDebug
    assert(shape.abi == .SWITCH, "We could only build debug infomation for C++ coroutine now.");
    dfile := di_op(dis, 0);
    line := di_int(dis, 0);
    frame_ty := dib_struct_type(cu, tconcat(vname(f), ".coro_frame_ty"), dfile, line, shape.frame_size * 8, shape.frame_align * 8, DI_FLAG_ARTIFICIAL);
    elts: [..] Md_Id; elts.allocator = temp;
    var_cache: Table(Value_Id, Md_Id); var_cache.allocator = temp;
    defs := fd_all_defs(fd);
    coro_cache_di_var(f, defs, *var_cache);
    unknown := 0;
    type_cache: Table(Type_Id, Md_Id); type_cache.allocator = temp;
    add_element :: (name: string, size_bits: u64, align: u64, offset: u64, ty: Md_Id) #expand {
        array_add(*elts, dib_member_type(frame_ty, name, dfile, line, size_bits, align, offset * 8, DI_FLAG_ARTIFICIAL, ty));
    }
    if shape.abi == .SWITCH {
        ptr_size := cast(u64) dl_ptr_spec(0).bits;
        ptr_align := dl_ptr_spec(0).abi * 8;
        di_ptr := dib_pointer_type(NONE, ptr_size, 0, "");   // createPointerType(nullptr, PtrSize, AddressSpace = 0 as AlignInBits)
        add_element("__resume_fn", ptr_size, ptr_align, 0, di_ptr);
        add_element("__destroy_fn", ptr_size, ptr_align, shape.sw_destroy_offset, di_ptr);
        index_size := dl_type_size_bits(shape.sw_index_type);
        add_element("__coro_index", index_size, shape.sw_index_align * 8, shape.sw_index_offset,
                    dib_basic_type("__coro_index", ifx index_size < 8 then cast(u64) 8 else index_size, DWATE_UNSIGNED_CHAR, 0));
    }
    for v: defs {
        offset := fd_get(*fd.offset, v);
        al := fd_get(*fd.align, v);
        name: string;
        dity: Md_Id = NONE;
        found, var := table_find(*var_cache, v);
        if found {
            name = md_str_of(di_op(var, 1));
            dity = di_op(var, 3);
        } else {
            is_alloca := is_inst(v) && inst_op(v) == .ALLOCA;
            dity = coro_solve_di_type(ifx is_alloca then inst(v).ty2 else vtype(v), frame_ty, line, *type_cache);
            name = tconcat(ditype_name(dity), "_", tdec(cast(u64) unknown));
            unknown += 1;
        }
        size_bits: u64;
        if is_inst(v) && inst_op(v) == .ALLOCA { sz, _ := coro_alloca_allocation_size(v); size_bits = sz * 8; }
        else size_bits = dl_type_size_bits(vtype(v));
        add_element(name, size_bits, al * 8, offset, dity);
    }
    md_uniqued_replace_operand(frame_ty, 6, md_tuple(elts, false));
    // createAutoVariable(DIS, "__coro_frame", DFile, LineNum, FrameDITy, AlwaysPreserve = true, FlagArtificial)
    frame_var := di_get(.LOCAL_VARIABLE, false, .[dis, dib_str("__coro_frame"), dfile, frame_ty, NONE], .[line, 0, DI_FLAG_ARTIFICIAL, 0]);
    // DIS->retainNodes(FrameDIVar)
    retained: [..] Md_Id; retained.allocator = temp;
    rn := di_op(dis, 7);
    if rn != NONE for k: 0..cast(s64) ir.mds[rn].nops - 1 array_add(*retained, md_op(rn, cast(u32) k));
    array_add(*retained, frame_var);
    nt := md_tuple(retained, false);   // may grow ir.md_ops: index after the call
    ir.md_ops[ir.mds[dis].ops + 7] = nt;
    loc := di_location_get(line, 1, dis, NONE);
    _, pt, head := coro_insert_pt_after_frame_ptr(shape);
    coro_new_dbg_record(.DECLARE, shape.frame_ptr, frame_var, diexpr_get(.[]), loc, pt, head);
}

// the __coro_resume_N label of createResumeEntryBlock (AddDebugLabels)
coro_add_resume_label :: (f: Value_Id, susp: Value_Id, index: u64, resume_bb: Value_Id) {
    sl := get_metadata(susp, MDK_DBG);
    if sl == NONE return;
    dis := get_metadata(f, MDK_DBG);
    dl := sl;
    while diloc_inlined_at(dl) != NONE dl = diloc_inlined_at(dl);
    file := discope_file(diloc_scope(dl));
    // DIBuilder::createLabel(DIS, Name, File, Line, Col, IsArtificial, CoroSuspendIdx, AlwaysPreserve = false)
    label := di_get(.LABEL, false, .[dis, dib_str(tconcat("__coro_resume_", tdec(index))), file],
                    .[diloc_line(sl), diloc_col(sl), 1, 1, index]);
    // DIBuilder::insertLabel(Label, DL, ResumeBB->begin()): a label record at the head of the first instruction
    r: Dbg_Record;
    r.kind = .LABEL; r.loc = label; r.dbg = dl;
    array_add(*ir.dbg_records, r);
    id := cast(u32) ir.dbg_records.count;
    dbgr_restamp(id);
    records_prepend(block_first(resume_bb), id);
    if dbg_index.fn != NONE dbgr_index_record(id);
}
