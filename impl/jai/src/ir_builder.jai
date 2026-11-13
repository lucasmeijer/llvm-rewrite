// IRBuilder<ConstantFolder, Inserter> for passes: insertion point, current debug location, an optional name prefix
// (SROA's IRBuilderPrefixedInserter), and the Create* methods passes use, folding constants like ConstantFolder.
// Ported from llvm/include/llvm/IR/IRBuilder.h, llvm/lib/IR/IRBuilder.cpp, llvm/include/llvm/IR/ConstantFolder.h
// and the debug-record side of llvm/lib/IR/Instruction.cpp (Instruction::insertBefore adopts the records of the
// insertion position unless the iterator has its "head bit" set).

Irb :: struct {
    bb: Value_Id = NONE;
    pt: Value_Id = NONE;   // insert before this instruction; NONE = at the end of bb
    head: bool;            // the insertion iterator has the head bit (insert before pt's debug records)
    dbg: Md_Id = NONE;     // StoredDL
    prefix: string;
}

// SetInsertPoint(Instruction *I)
irb_set_before :: (b: *Irb, i: Value_Id) {
    b.bb = inst(i).parent; b.pt = i; b.head = false;
    b.dbg = get_metadata(i, 0);
}
// SetInsertPoint(BB, It) with It = (pt, head bit); debug location from pt unless at the end
irb_set_at :: (b: *Irb, bb: Value_Id, pt: Value_Id, head: bool) {
    b.bb = bb; b.pt = pt; b.head = head;
    if pt != NONE b.dbg = get_metadata(pt, 0);
}
// SetInsertPoint(BB): at the end, debug location unchanged
irb_set_end :: (b: *Irb, bb: Value_Id) { b.bb = bb; b.pt = NONE; b.head = false; }

// Insert `i` at the position the way Instruction::insertBefore does.
insert_at_position :: (i: Value_Id, bb: Value_Id, pt: Value_Id, head: bool) {
    if pt == NONE { block_append_inst(bb, i); return; }
    inst_insert_before(i, pt);
    if !head && inst(pt).records {
        // adoptDbgRecords: the records before pt now come before i
        r := inst(pt).records;
        inst(pt).records = 0;
        attach_records_before(i, r);
    }
}

// IRBuilderBase::Insert: InsertHelper (insert, then setName with the prefix), then SetInstDebugLocation
irb_insert :: (b: *Irb, i: Value_Id, name: string = "") -> Value_Id {
    insert_at_position(i, b.bb, b.pt, b.head);
    // Twine semantics: a "" literal is trivially empty (no prefix); a StringRef name (name_ref) is not
    if name == NAME_STRINGREF_EMPTY { if b.prefix.count set_name(i, b.prefix); }
    else if name.count set_name(i, ifx b.prefix.count then tconcat(b.prefix, name) else name);
    d := b.dbg;
    if d == NONE d = get_metadata(i, 0);
    set_metadata(i, 0, d);
    return i;
}

// A name that came from Value::getName(): even when empty it is not a trivially empty Twine, so the prefix applies.
NAME_STRINGREF_EMPTY :: "\x01";
name_ref :: (s: string) -> string { if s.count == 0 return NAME_STRINGREF_EMPTY; return s; }

irb_is_const :: inline (v: Value_Id) -> bool { return is_constant_kind(vkind(v)); }

// CreateCast
irb_cast :: (b: *Irb, opc: Opcode, v: Value_Id, dt: Type_Id, name: string = "") -> Value_Id {
    if vtype(v) == dt return v;
    if irb_is_const(v) {
        f := fold_maybe_undesirable_cast(opc, v, dt);
        if f != NONE return f;
    }
    i := new_inst(opc, dt, 1);
    set_op(i, 0, v);
    return irb_insert(b, i, name);
}
irb_bitcast :: (b: *Irb, v: Value_Id, dt: Type_Id, name: string = "") -> Value_Id { return irb_cast(b, .BITCAST, v, dt, name); }

// CreatePointerBitCastOrAddrSpaceCast
irb_pointer_bitcast_or_addrspacecast :: (b: *Irb, v: Value_Id, dt: Type_Id, name: string = "") -> Value_Id {
    if vtype(v) == dt return v;
    opc: Opcode = ifx ir.types[scalar_type(vtype(v))].a != ir.types[scalar_type(dt)].a then .ADDRSPACECAST else .BITCAST;
    if irb_is_const(v) return ce_cast(opc, v, dt);
    i := new_inst(opc, dt, 1);
    set_op(i, 0, v);
    return irb_insert(b, i, name);
}

// CreateBinOp / CreateAnd / CreateShl ... (ConstantFolder::FoldBinOp / FoldNoWrapBinOp / FoldExactBinOp)
irb_binop :: (b: *Irb, opc: Opcode, l: Value_Id, r: Value_Id, name: string = "", flags: u32 = 0) -> Value_Id {
    if irb_is_const(l) && irb_is_const(r) {
        if is_desirable_bin_op(opc) return ce_binop(opc, l, r, flags);
        f := cf_binary(opc, l, r);
        if f != NONE return f;
    }
    i := new_inst(opc, vtype(l), 2);
    set_op(i, 0, l); set_op(i, 1, r);
    inst(i).flags = flags;
    return irb_insert(b, i, name);
}

// CreateAlignedLoad
irb_load :: (b: *Irb, ty: Type_Id, ptr: Value_Id, align: u64, volatile := false, name: string = "") -> Value_Id {
    i := new_inst(.LOAD, ty, 1);
    set_op(i, 0, ptr);
    inst(i).align = align;
    if volatile inst(i).flags |= F_VOLATILE;
    return irb_insert(b, i, name);
}
// CreateAlignedStore
irb_store :: (b: *Irb, v: Value_Id, ptr: Value_Id, align: u64, volatile := false) -> Value_Id {
    i := new_inst(.STORE, ir.t_void, 2);
    set_op(i, 0, v); set_op(i, 1, ptr);
    inst(i).align = align;
    if volatile inst(i).flags |= F_VOLATILE;
    return irb_insert(b, i);
}

// GetElementPtrInst::getGEPReturnType
irb_gep_result_type :: (ptr: Value_Id, idxs: [] Value_Id) -> Type_Id {
    rt := vtype(ptr);
    if !is_vector_type(rt) for idxs if is_vector_type(vtype(it)) { rt = type_vector(type_count(vtype(it)), rt, type_kind(vtype(it)) == .SVECTOR); break; }
    return rt;
}

// CreateGEP(Ty, Ptr, IdxList, Name, NW)
irb_gep :: (b: *Irb, srcty: Type_Id, ptr: Value_Id, idxs: [] Value_Id, name: string = "", flags: u32 = 0) -> Value_Id {
    if irb_is_const(ptr) && type_kind(srcty) != .SVECTOR {
        all := true;
        for idxs if !irb_is_const(it) { all = false; break; }
        if all return ce_gep(srcty, ptr, idxs, flags);
    }
    i := new_inst(.GEP, irb_gep_result_type(ptr, idxs), cast(u32)(1 + idxs.count));
    inst(i).flags = flags; inst(i).ty2 = srcty;
    set_op(i, 0, ptr);
    for idxs set_op(i, cast(u32)(1 + it_index), it);
    return irb_insert(b, i, name);
}
// CreateInBoundsPtrAdd(Ptr, Offset): getelementptr inbounds i8
irb_inbounds_ptr_add :: (b: *Irb, ptr: Value_Id, off: Value_Id, name: string = "") -> Value_Id {
    return irb_gep(b, ir.t_i8, ptr, .[off], name, F_INBOUNDS);
}


irb_extract_element :: (b: *Irb, v: Value_Id, idx: u64, name: string = "") -> Value_Id {
    ix := const_int(ir.t_i64, idx);
    if irb_is_const(v) return ce_extract_element(v, ix);
    i := new_inst(.EXTRACTELEMENT, type_elem(vtype(v)), 2);
    set_op(i, 0, v); set_op(i, 1, ix);
    return irb_insert(b, i, name);
}
irb_insert_element :: (b: *Irb, v: Value_Id, e: Value_Id, idx: u64, name: string = "") -> Value_Id {
    ix := const_int(ir.t_i64, idx);
    if irb_is_const(v) && irb_is_const(e) return ce_insert_element(v, e, ix);
    i := new_inst(.INSERTELEMENT, vtype(v), 3);
    set_op(i, 0, v); set_op(i, 1, e); set_op(i, 2, ix);
    return irb_insert(b, i, name);
}
// CreateShuffleVector(V1, V2, Mask); mask element 0xFFFFFFFF = poison (-1)
irb_shuffle :: (b: *Irb, v1: Value_Id, v2_in: Value_Id, mask: [] u32, name: string = "") -> Value_Id {
    v2 := v2_in;
    if v2 == NONE v2 = const_poison(vtype(v1));
    if irb_is_const(v1) && irb_is_const(v2) return ce_shuffle_vector(v1, v2, mask);
    vt := vtype(v1);
    rt := type_vector(cast(u64) mask.count, type_elem(vt), type_kind(vt) == .SVECTOR);
    i := new_inst(.SHUFFLEVECTOR, rt, 2);
    set_op(i, 0, v1); set_op(i, 1, v2);
    r := inst(i);
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) mask.count;
    for mask array_add(*ir.u32_pool, it);
    return irb_insert(b, i, name);
}
// CreateVectorSplat
irb_vector_splat :: (b: *Irb, n: u64, v: Value_Id, name: string, scalable := false) -> Value_Id {
    poison := const_poison(type_vector(n, vtype(v), scalable));
    x := irb_insert_element(b, poison, v, 0, tprint("%.splatinsert", name));
    zeros := NewArray(cast(s64) n, u32,, allocator = temp);
    return irb_shuffle(b, x, NONE, zeros, tprint("%.splat", name));
}

irb_extract_value :: (b: *Irb, agg: Value_Id, idxs: [] u32, name: string = "") -> Value_Id {
    if irb_is_const(agg) { f := cf_extract_value(agg, idxs); if f != NONE return f; }
    rt := vtype(agg);
    for idxs rt = type_sub(rt, ifx type_kind(rt) == .STRUCT then it else 0);
    i := new_inst(.EXTRACTVALUE, rt, 1);
    set_op(i, 0, agg);
    r := inst(i);
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) idxs.count;
    for idxs array_add(*ir.u32_pool, it);
    return irb_insert(b, i, name);
}
irb_insert_value :: (b: *Irb, agg: Value_Id, v: Value_Id, idxs: [] u32, name: string = "") -> Value_Id {
    if irb_is_const(agg) && irb_is_const(v) { f := cf_insert_value(agg, v, idxs); if f != NONE return f; }
    i := new_inst(.INSERTVALUE, vtype(agg), 2);
    set_op(i, 0, agg); set_op(i, 1, v);
    r := inst(i);
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) idxs.count;
    for idxs array_add(*ir.u32_pool, it);
    return irb_insert(b, i, name);
}

// CreateSelect(C, True, False, Name, MDFrom)
irb_select :: (b: *Irb, c: Value_Id, t: Value_Id, f: Value_Id, name: string = "", md_from: Value_Id = NONE) -> Value_Id {
    if irb_is_const(c) && irb_is_const(t) && irb_is_const(f) { x := cf_select(c, t, f); if x != NONE return x; }
    i := new_inst(.SELECT, vtype(t), 3);
    set_op(i, 0, c); set_op(i, 1, t); set_op(i, 2, f);
    if md_from != NONE {
        prof := get_metadata(md_from, md_fixed("prof"));
        unpred := get_metadata(md_from, md_fixed("unpredictable"));
        if prof != NONE set_metadata(i, md_fixed("prof"), prof);
        if unpred != NONE set_metadata(i, md_fixed("unpredictable"), unpred);
    }
    return irb_insert(b, i, name);
}

// CreatePHI(Ty, NumReservedValues, Name)
irb_phi :: (b: *Irb, ty: Type_Id, reserved: u32, name: string = "") -> Value_Id {
    return irb_insert(b, create_phi(ty, reserved), name);
}

// CreateCall(Callee, Args) without attributes or bundles
irb_call :: (b: *Irb, callee: Value_Id, args: [] Value_Id, name: string = "") -> Value_Id {
    fty := glob(callee).value_type;
    i := new_inst(.CALL, func_ret(fty), cast(u32)(args.count + 1));
    inst(i).ty2 = fty;
    for args set_op(i, cast(u32) it_index, it);
    set_op(i, cast(u32) args.count, callee);
    return irb_insert(b, i, name);
}
// CreateCall(Callee, Args, OpBundles) with `from`'s bundles (CallBase::getOperandBundlesAsDefs)
irb_call_with_bundles_of :: (b: *Irb, callee: Value_Id, args: [] Value_Id, from: Value_Id, name: string = "") -> Value_Id {
    nb := call_num_bundles(from);
    if nb == 0 return irb_call(b, callee, args, name);
    nbops: u32 = 0;
    for k: 0..nb-1 { bb, ee := call_bundle_range(from, k); nbops += ee - bb; }
    fty := glob(callee).value_type;
    i := new_inst(.CALL, func_ret(fty), cast(u32) args.count + nbops + 1);
    inst(i).ty2 = fty;
    for args set_op(i, cast(u32) it_index, it);
    at := cast(u32) args.count;
    r := inst(i);
    pool_start := cast(u32) ir.u32_pool.count;
    for k: 0..nb-1 {
        bb, ee := call_bundle_range(from, k);
        tag := ir.u32_pool[inst(from).idx + 3 * k];
        begin := at;
        for x: bb..ee-1 { set_op(i, at, op(from, x)); at += 1; }
        array_add(*ir.u32_pool, tag); array_add(*ir.u32_pool, begin); array_add(*ir.u32_pool, at);
    }
    r = inst(i);
    r.idx = pool_start; r.nidx = nb;
    set_op(i, at, callee);
    return irb_insert(b, i, name);
}
// CreateIntrinsic(ID, OverloadTypes, Args)
irb_intrinsic :: (b: *Irb, name: string, otys: [] Type_Id, args: [] Value_Id) -> Value_Id {
    f := get_or_insert_intrinsic_declaration(intrinsic_id_by_name(name), otys);
    return irb_call(b, f, args);
}

// CreateMemSet(Ptr, Val, Size, Align, isVolatile)
irb_memset :: (b: *Irb, ptr: Value_Id, val: Value_Id, size: Value_Id, align: u64, volatile: bool) -> Value_Id {
    ci := irb_intrinsic(b, "llvm.memset", .[vtype(ptr), vtype(size)], .[ptr, val, size, const_int(ir.t_i1, ifx volatile then cast(u64) 1 else 0)]);
    if align add_param_align(ci, 0, align);
    return ci;
}
// CreateMemCpy(Dst, DstAlign, Src, SrcAlign, Size, isVolatile)
irb_memcpy :: (b: *Irb, dst: Value_Id, dst_align: u64, src: Value_Id, src_align: u64, size: Value_Id, volatile: bool) -> Value_Id {
    ci := irb_intrinsic(b, "llvm.memcpy", .[vtype(dst), vtype(src), vtype(size)], .[dst, src, size, const_int(ir.t_i1, ifx volatile then cast(u64) 1 else 0)]);
    if dst_align add_param_align(ci, 0, dst_align);
    if src_align add_param_align(ci, 1, src_align);
    return ci;
}

// CreateBitPreservingCastChain (fixed-size types only)
irb_bit_preserving_cast_chain :: (b: *Irb, v: Value_Id, nt: Type_Id) -> Value_Id {
    ot := vtype(v);
    if ot == nt return v;
    if type_kind(ot) == .SVECTOR || type_kind(nt) == .SVECTOR fatal("SROA: casts between scalable vector types are not supported yet");
    is_int_or_int_vec :: (t: Type_Id) -> bool { return is_int_type(scalar_type(t)); }
    if is_int_or_int_vec(ot) && is_ptr_or_ptr_vector(nt)
        return irb_cast(b, .INTTOPTR, irb_bitcast(b, v, irb_int_ptr_type(nt)), nt);
    if is_ptr_or_ptr_vector(ot) && is_int_or_int_vec(nt)
        return irb_bitcast(b, irb_cast(b, .PTRTOINT, v, irb_int_ptr_type(ot)), nt);
    if is_ptr_or_ptr_vector(ot) && is_ptr_or_ptr_vector(nt) {
        oas := ir.types[scalar_type(ot)].a;
        nas := ir.types[scalar_type(nt)].a;
        if oas != nas
            return irb_cast(b, .INTTOPTR, irb_bitcast(b, irb_cast(b, .PTRTOINT, v, irb_int_ptr_type(ot)), irb_int_ptr_type(nt)), nt);
    }
    return irb_bitcast(b, v, nt);
}

// DataLayout::getIntPtrType(Ty): integer (vector) of the pointer's size
irb_int_ptr_type :: (t: Type_Id) -> Type_Id {
    st := scalar_type(t);
    it := type_int(dl_ptr_spec(cast(u32) ir.types[st].a).bits);
    if is_vector_type(t) return vector_with_elt(t, it);
    return it;
}
