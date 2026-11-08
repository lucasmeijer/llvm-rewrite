// Pointer/offset utilities on values. Ported from llvm/lib/IR/Operator.cpp (GEPOperator::accumulateConstantOffset),
// llvm/lib/IR/Value.cpp (stripPointerCastsAndOffsets<PSK_InBounds>, stripAndAccumulateConstantOffsets),
// llvm/lib/IR/Instructions.cpp (CallBase::getReturnedArgOperand) and llvm/lib/IR/DataLayout.cpp
// (getIndexedOffsetInType). Offsets are APInts of the pointer's index width, kept here as u64 masked to `width`
// bits (index widths above 64 bits fail loudly).

sv_mask :: (width: u32) -> u64 {
    if width > 64 fatal("pointer index widths above 64 bits are not supported yet");
    if width == 64 return 0xFFFF_FFFF_FFFF_FFFF;
    return ((cast(u64) 1) << width) - 1;
}

// APInt::sextOrTrunc of a ConstantInt to `width` bits (as u64)
sv_sext_to :: (c: Value_Id, width: u32) -> u64 {
    w := type_int_width(scalar_type(vtype(c)));
    v := const_int_value(c)[0];
    if w < 64 && w > 0 {
        sign := (v >> (w - 1)) & 1;
        if sign v |= ~(((cast(u64) 1) << w) - 1);
    }
    return v & sv_mask(width);
}

// Operand of a gep index that is a scalar ConstantInt, else NONE
sv_gep_const_index :: (v: Value_Id) -> Value_Id {
    if vkind(v) == .C_INT && type_kind(vtype(v)) == .INT return v;
    return NONE;
}

// GEPOperator::accumulateConstantOffset(SourceType, Index, DL, Offset) without external analysis
sv_gep_accumulate :: (srcty: Type_Id, idxs: [] Value_Id, offset: *u64, width: u32) -> bool {
    mask := sv_mask(width);
    if type_kind(srcty) == .INT && type_int_width(srcty) == 8 && idxs.count > 0 {
        ci := sv_gep_const_index(idxs[0]);
        if ci != NONE { offset.* = (offset.* + sv_sext_to(ci, width)) & mask; return true; }
        return false;
    }
    cur := srcty;
    for idx, k: idxs {
        // gep_type_iterator: the first index steps over the source type itself
        indexed: Type_Id;
        is_struct := false;
        is_vec := false;
        if k == 0 indexed = srcty;
        else {
            ck := type_kind(cur);
            if ck == .STRUCT { is_struct = true; }
            else if ck == .ARRAY { indexed = type_elem(cur); }
            else if ck == .VECTOR || ck == .SVECTOR { indexed = type_elem(cur); is_vec = true; }
            else fatal("internal: bad gep type walk");
        }
        ci := sv_gep_const_index(idx);
        if is_struct {
            if ci == NONE return false;
            fi := cast(u32) const_int_zext(ci);
            if const_int_zext(ci) != 0 offset.* = (offset.* + dl_struct_offset(cur, fi)) & mask;
            cur = type_sub(cur, fi);
            continue;
        }
        scalable := type_kind(indexed) == .SVECTOR;
        if ci != NONE {
            if !is_null_value(ci) {
                if scalable return false;
                stride := ifx is_vec then dl_type_store_size(indexed) else dl_type_alloc_size(indexed);
                offset.* = (offset.* + sv_sext_to(ci, width) * (stride & mask)) & mask;
            }
        } else {
            return false;
        }
        cur = indexed;
    }
    return true;
}

sv_gep_accumulate_of :: (g: Value_Id, offset: *u64, width: u32) -> bool {
    n := nops(g);
    idxs: [..] Value_Id; idxs.allocator = temp;
    if n > 1 for k: 1..n-1 array_add(*idxs, op(g, k));
    srcty := ifx vkind(g) == .INST then inst(g).ty2 else cexpr(g).ty2;
    return sv_gep_accumulate(srcty, idxs, offset, width);
}

// Operator::getOpcode
sv_opcode :: (v: Value_Id) -> Opcode {
    k := vkind(v);
    if k == .INST return inst_op(v);
    if k == .C_EXPR return cexpr(v).op;
    return .NONE_OP;
}
sv_gep_flags :: (g: Value_Id) -> u32 { return ifx vkind(g) == .INST then inst(g).flags else cexpr(g).flags; }
sv_gep_inbounds :: (g: Value_Id) -> bool { return (sv_gep_flags(g) & F_INBOUNDS) != 0; }

// CallBase::getReturnedArgOperand
sv_call_returned_arg :: (c: Value_Id) -> Value_Id {
    n := call_arg_count(c);
    r := inst(c);
    if n > 0 for k: 0..n-1 if attr_set_has(attr_list_param(r.attrs, k), .Returned) return op(c, k);
    f := call_called_function(c);
    if f != NONE {
        if n > 0 for k: 0..n-1 if attr_set_has(attr_list_param(glob(f).attrs, k), .Returned) return op(c, k);
    }
    return NONE;
}

// Value::stripInBoundsOffsets
sv_strip_in_bounds_offsets :: (v_in: Value_Id) -> Value_Id {
    v := v_in;
    if !is_ptr_type(vtype(v)) return v;
    seen: [..] Value_Id; seen.allocator = temp;
    array_add(*seen, v);
    while true {
        o := sv_opcode(v);
        if o == .GEP {
            if !sv_gep_inbounds(v) return v;
            v = op(v, 0);
        } else if o == .BITCAST {
            nv := op(v, 0);
            if !is_ptr_type(vtype(nv)) return v;
            v = nv;
        } else if o == .ADDRSPACECAST {
            v = op(v, 0);
        } else {
            if is_inst(v) && is_call_base(v) {
                rv := sv_call_returned_arg(v);
                if rv != NONE {
                    v = rv;
                    for seen if it == v return v;
                    array_add(*seen, v);
                    continue;
                }
            }
            return v;
        }
        for seen if it == v return v;
        array_add(*seen, v);
    }
    return v;
}

// Value::stripAndAccumulateConstantOffsets(DL, Offset, AllowNonInbounds) (no invariant groups, no inttoptr)
sv_strip_and_accumulate :: (v_in: Value_Id, offset: *u64, width: u32, allow_non_inbounds: bool) -> Value_Id {
    v := v_in;
    if !is_ptr_or_ptr_vector(vtype(v)) return v;
    mask := sv_mask(width);
    seen: [..] Value_Id; seen.allocator = temp;
    array_add(*seen, v);
    while true {
        o := sv_opcode(v);
        if o == .GEP {
            if !allow_non_inbounds && !sv_gep_inbounds(v) return v;
            gw := dl_index_type_size_bits(vtype(v));
            go: u64 = 0;
            if !sv_gep_accumulate_of(v, *go, gw) return v;
            if gw > width {
                // getSignificantBits() > BitWidth
                fatal("SROA: offsets through address spaces with wider indices are not supported yet");
            }
            // sextOrTrunc to width
            if gw < width && gw > 0 && ((go >> (gw - 1)) & 1) go |= ~sv_mask(gw);
            offset.* = (offset.* + go) & mask;
            v = op(v, 0);
        } else if o == .BITCAST {
            src := op(v, 0);
            if !is_ptr_or_ptr_vector(vtype(src)) return v;
            v = src;
        } else if o == .ADDRSPACECAST {
            v = op(v, 0);
        } else if vkind(v) == .ALIAS {
            fatal("SROA: stripping offsets through a global alias is not supported yet");
        } else if is_inst(v) && is_call_base(v) {
            rv := sv_call_returned_arg(v);
            if rv != NONE v = rv;
        } else {
            return v;
        }
        for seen if it == v return v;
        array_add(*seen, v);
    }
    return v;
}

// DataLayout::getIndexedOffsetInType(ElemTy, Indices) with constant i32/i64 indices
sv_indexed_offset_in_type :: (elem_ty: Type_Id, idxs: [] Value_Id) -> s64 {
    result: s64 = 0;
    cur := elem_ty;
    for idx, k: idxs {
        if k == 0 {
            result += const_int_sext(idx) * cast(s64) dl_type_alloc_size(cur);
            continue;
        }
        if type_kind(cur) == .STRUCT {
            fi := cast(u32) const_int_zext(idx);
            result += cast(s64) dl_struct_offset(cur, fi);
            cur = type_sub(cur, fi);
        } else {
            cur = type_elem(cur);
            result += const_int_sext(idx) * cast(s64) dl_type_alloc_size(cur);
        }
    }
    return result;
}

// getOffsetFromIndex (Value.cpp): the constant offset implied by GEP operands Idx.. (false = not constant)
value_gep_offset_from_index :: (g: Value_Id, idx: u32) -> (bool, s64) {
    n := nops(g);
    t := opr_gep_source_type(g);
    prev: Type_Id = NONE;
    off: s64 = 0;
    for i: 1..cast(s64) n - 1 {
        c := op(g, cast(u32) i);
        if i > 1 { prev = t; t = gep_indexed_type(prev, i, c); }
        if i < idx continue;
        if !is_scalar_const_int(c) return false, 0;
        if ap_is_zero(const_ap(c)) continue;
        if i > 1 && type_kind(prev) == .STRUCT {
            off += cast(s64) dl_struct_offset(prev, cast(u32) ap_zext_value(const_ap(c)));
            continue;
        }
        if type_is_scalable(t) return false, 0;
        stride := gep_seq_stride(ifx i > 1 then prev else NONE, i, t);
        off += cast,no_check(s64) stride * ap_sext_value(const_ap(c));
    }
    return true, off;
}
// Value::getPointerOffsetFrom(Other, DL): this - other
value_pointer_offset_from :: (this: Value_Id, other: Value_Id) -> (bool, s64) {
    o1 := ap_zero(dl_index_type_size_bits(vtype(other)));
    o2 := ap_zero(dl_index_type_size_bits(vtype(this)));
    p1, a1 := strip_and_accumulate_constant_offsets(other, o1, true);
    p2, a2 := strip_and_accumulate_constant_offsets(this, o2, true);
    if p1 == p2 return true, ap_sext_value(a2) - ap_sext_value(a1);
    if opr_code(p1) != .GEP || opr_code(p2) != .GEP || op(p1, 0) != op(p2, 0) ||
       opr_gep_source_type(p1) != opr_gep_source_type(p2) return false, 0;
    idx: u32 = 1;
    while idx != nops(p1) && idx != nops(p2) {
        if op(p1, idx) != op(p2, idx) break;
        idx += 1;
    }
    ok1, i1 := value_gep_offset_from_index(p1, idx);
    ok2, i2 := value_gep_offset_from_index(p2, idx);
    if !ok1 || !ok2 return false, 0;
    return true, i2 - i1 + ap_sext_value(a2) - ap_sext_value(a1);
}
