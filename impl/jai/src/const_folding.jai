// Constant folding with a DataLayout: a port of llvm/lib/Analysis/ConstantFolding.cpp up to (not including) the
// call folding (FoldBitCast, IsConstantOffsetFromGlobal, ConstantFoldLoadThroughBitcast, ReadDataFromGlobal,
// FoldReinterpretLoadFromConst, getConstantAtOffset, ConstantFoldLoadFromConst(Ptr), ConstantFoldLoadFromUniformValue,
// SymbolicallyEvaluateBinop, CastGEPIndices, SymbolicallyEvaluateGEP, ConstantFoldInstOperandsImpl,
// ConstantFoldConstant, ConstantFoldInstruction, ConstantFoldCompareInstOperands, ConstantFoldUnary/BinaryOpOperands,
// FlushFPConstant, ConstantFoldFPInstOperands, ConstantFoldCastOperand, ConstantFoldIntegerCast). Calls are in
// const_folding_calls.jai. The DataLayout-free folds this builds on are constfold.jai (lib/IR/ConstantFold.cpp).
//
// All cfo_* procedures return NONE where LLVM returns nullptr.

// ---------------------------------------------------------------- DataLayout helpers

// DataLayout::getIntPtrType / getIndexType / getAddressType for a pointer (or vector of pointers) type
dl_int_ptr_type :: (t: Type_Id) -> Type_Id {
    st := scalar_type(t);
    it := type_int(dl_ptr_spec(cast(u32) ir.types[st].a).bits);
    if is_vector_type(t) return vector_with_elt(t, it);
    return it;
}
dl_index_type :: (t: Type_Id) -> Type_Id {
    st := scalar_type(t);
    it := type_int(dl_ptr_spec(cast(u32) ir.types[st].a).idx_bits);
    if is_vector_type(t) return vector_with_elt(t, it);
    return it;
}
dl_address_type :: (t: Type_Id) -> Type_Id { return dl_index_type(t); }
type_int :: inline (bits: u32) -> Type_Id { return type_int(cast(u64) bits); }
// DataLayout::isNonIntegralPointerType / mustNotIntroduceIntToPtr: address spaces listed in "ni:" of the datalayout
dl_is_non_integral_as :: (as: u32) -> bool { return dl_ni_as(as); }
dl_is_non_integral_pointer_type :: (t: Type_Id) -> bool { st := scalar_type(t); return is_ptr_type(st) && dl_is_non_integral_as(cast(u32) ir.types[st].a); }
// DataLayout::mustNotIntroduceIntToPtr / mustNotIntroducePtrToInt / hasUnstableRepresentation / hasExternalState
dl_ptr_spec_of :: (t: Type_Id) -> (bool, Ptr_Spec) { st := scalar_type(t); if !is_ptr_type(st) { z: Ptr_Spec; return false, z; } return true, dl_ptr_spec(cast(u32) ir.types[st].a); }
dl_must_not_introduce_int_to_ptr :: (t: Type_Id) -> bool { ok, ps := dl_ptr_spec_of(t); return ok && (ps.unstable || ps.external); }
dl_must_not_introduce_ptr_to_int :: (t: Type_Id) -> bool { ok, ps := dl_ptr_spec_of(t); return ok && ps.unstable; }
// DataLayout::typeSizeEqualsStoreSize
dl_type_size_equals_store_size :: (t: Type_Id) -> bool { return dl_type_size_bits(t) == dl_type_store_size(t) * 8; }

// DataLayout::getIndexedOffsetInType(ElemTy, Indices): the indices are ConstantInts
dl_indexed_offset_in_type :: (elem_ty: Type_Id, idxs: [] Value_Id) -> s64 {
    result: s64 = 0;
    cur := elem_ty;
    for idx, k: idxs {
        if k == 0 {
            result += ap_sext_value(const_ap(idx)) * cast(s64) dl_type_alloc_size(cur);
            continue;
        }
        if type_kind(cur) == .STRUCT {
            fi := cast(u32) ap_zext_value(const_ap(idx));
            result += cast(s64) dl_struct_offset(cur, fi);
            cur = type_sub(cur, fi);
        } else {
            container := cur;
            cur = type_elem(cur);
            result += ap_sext_value(const_ap(idx)) * cast(s64) gep_seq_stride(container, k + 1, cur);
        }
    }
    return result;
}
// StructLayout::getElementContainingOffset
dl_struct_element_containing_offset :: (t: Type_Id, off: u64) -> u32 {
    n := type_nsub(t);
    r: u32 = 0;
    for i: 0..cast(s64) n - 1 { if dl_struct_offset(t, cast(u32) i) <= off r = cast(u32) i; else break; }
    return r;
}
// getElementIndex(ElemSize, Offset)
dl_element_index :: (elem_size: u64, offset: *APInt) -> APInt {
    bw := offset.bits;
    if elem_size == 0 || (bw - 1 < 64 && elem_size >= (cast(u64) 1) << cast(u64)(bw - 1)) return ap_zero(bw);
    es := ap_from_u64(bw, elem_size);
    index := ap_sdiv(offset.*, es);
    offset.* = ap_sub(offset.*, ap_mul(index, es));
    if ap_is_negative(offset.*) {
        index = ap_sub_u64(index, 1);
        offset.* = ap_add(offset.*, es);
    }
    return index;
}
// DataLayout::getGEPIndicesForOffset
dl_gep_indices_for_offset :: (elem_ty: *Type_Id, offset: *APInt) -> [..] APInt {
    out: [..] APInt; out.allocator = temp;
    array_add(*out, dl_element_index(dl_type_alloc_size(elem_ty.*), offset));
    while !ap_is_zero(offset.*) {
        t := elem_ty.*;
        k := type_kind(t);
        if k == .ARRAY {
            elem_ty.* = type_elem(t);
            array_add(*out, dl_element_index(dl_type_alloc_size(elem_ty.*), offset));
        } else if k == .STRUCT {
            io := ap_zext_value(offset.*);
            if io >= dl_type_alloc_size(t) break;   // SL->getSizeInBytes()
            sz, al := dl_struct_layout(t);
            if io >= sz break;
            idx := dl_struct_element_containing_offset(t, io);
            offset.* = ap_sub(offset.*, ap_from_u64(offset.bits, dl_struct_offset(t, idx)));
            elem_ty.* = type_sub(t, idx);
            array_add(*out, ap_from_u64(32, idx));
        } else break;
    }
    return out;
}

// ---------------------------------------------------------------- FoldBitCast

// foldConstVectorToAPInt: returns NONE on success (result in *result) or a bitcast constant expression
fold_const_vector_to_apint :: (result: *APInt, dt: Type_Id, c: Value_Id, src_elt: Type_Id, n: u64) -> Value_Id {
    shift := cast(u32) dl_type_size_bits(src_elt);
    for i: 0..cast(s64) n - 1 {
        e: Value_Id;
        if !dl.big_endian e = cf_elt(c, n - cast(u64) i - 1);
        else e = cf_elt(c, cast(u64) i);
        if e != NONE && pm_undef_value(e) { result.* = ap_shl(result.*, shift); continue; }
        if e == NONE || vkind(e) != .C_INT return ce_cast(.BITCAST, c, dt);
        result.* = ap_shl(result.*, shift);
        result.* = ap_or(result.*, ap_zext(const_ap(e), result.bits));
    }
    return NONE;
}
fold_mixes_poison_bits :: (c: Value_Id, nsrc: u32, ndst: u32) -> bool {
    if nsrc % ndst != 0 return contains_poison_element(c);
    ratio := nsrc / ndst;
    i: u32 = 0;
    while i < nsrc {
        hp := false; hn := false;
        for j: 0..ratio-1 {
            s := cf_elt(c, i + j);
            if s == NONE return true;
            if vkind(s) == .C_POISON hp = true; else hn = true;
        }
        if hp && hn return true;
        i += ratio;
    }
    return false;
}
// FoldBitCast
cfo_fold_bitcast :: (c_in: Value_Id, dt: Type_Id) -> Value_Id {
    c := c_in;
    r := cfo_load_from_uniform_value(c, dt);
    if r != NONE return r;
    st := vtype(c);
    if is_vector_type(st) {
        if is_int_type(dt) || is_fp_type(dt) {
            n := type_count(st);
            src_elt := type_elem(st);
            if type_kind(src_elt) == .BYTE && contains_poison_element(c) return const_poison(dt);
            if is_fp_type(src_elt) || type_kind(src_elt) == .BYTE {
                w := type_bits(src_elt);
                c = ce_cast(.BITCAST, c, type_vector(n, type_int(w), false));
            }
            result := ap_zero(cast(u32) dl_type_size_bits(dt));
            ce := fold_const_vector_to_apint(*result, dt, c, src_elt, n);
            if ce != NONE return ce;
            if is_int_type(dt) return cf_int(dt, result);
            return const_fp_words(dt, ap_words(result));
        }
    }
    if !is_vector_type(dt) return ce_cast(.BITCAST, c, dt);
    k := vkind(c);
    if !is_vector_type(st) && (k == .C_FP || k == .C_INT) {
        return cfo_fold_bitcast(cf_vector(type_vector(1, st, false), .[c]), dt);
    }
    if type_kind(st) != .VECTOR return ce_cast(.BITCAST, c, dt);
    if k != .C_DATA && k != .C_VECTOR && k != .C_INT && k != .C_FP return ce_cast(.BITCAST, c, dt);
    ndst := cast(u32) type_count(dt);
    nsrc := cast(u32) type_count(st);
    if ndst == nsrc return ce_cast(.BITCAST, c, dt);
    src_elt := type_elem(st);
    dst_elt := type_elem(dt);
    if is_fp_type(dst_elt) {
        w := type_bits(dst_elt);
        c = cfo_fold_bitcast(c, type_vector(ndst, type_int(w), false));
        return ce_cast(.BITCAST, c, dt);
    }
    if type_kind(dst_elt) == .BYTE {
        if ndst < nsrc && fold_mixes_poison_bits(c, nsrc, ndst) return ce_cast(.BITCAST, c, dt);
        w := type_bits(dst_elt);
        c = cfo_fold_bitcast(c, type_vector(ndst, type_int(w), false));
        return ce_cast(.BITCAST, c, dt);
    }
    if is_fp_type(src_elt) {
        w := type_bits(src_elt);
        c = ce_cast(.BITCAST, c, type_vector(nsrc, type_int(w), false));
    }
    // byte source: fold through integers, then restore the destination lanes whose source bytes had poison bits
    poison_dst: [] bool;
    if type_kind(src_elt) == .BYTE {
        ok, pd := compute_poison_dst_lanes(c, nsrc, ndst);
        if !ok return ce_cast(.BITCAST, c, dt);
        poison_dst = pd;
        c = ce_cast(.BITCAST, c, type_vector(nsrc, type_int(type_bits(src_elt)), false));
    }
    is_le := !dl.big_endian;
    src_bits := type_bits(src_elt);
    dst_bits := type_bits(dst_elt);
    result: [..] Value_Id; result.allocator = temp;
    src_i: u32 = 0;
    bw := 2 * max(src_bits, dst_bits);
    buffer := ap_zero(bw); undef_mask := ap_zero(bw); poison_mask := ap_zero(bw);
    buf_bits: u32 = 0;
    while result.count != cast(s64) ndst {
        while buf_bits < dst_bits {
            e := cf_elt(c, src_i);
            src_i += 1;
            if e == NONE return ce_cast(.BITCAST, c, dt);
            if !is_le { buffer = ap_shl(buffer, src_bits); undef_mask = ap_shl(undef_mask, src_bits); poison_mask = ap_shl(poison_mask, src_bits); }
            pos := ifx is_le then buf_bits else 0;
            sv: APInt;
            if pm_undef_value(e) {
                ap_set_bits(*undef_mask, pos, pos + src_bits);
                if vkind(e) == .C_POISON ap_set_bits(*poison_mask, pos, pos + src_bits);
                sv = ap_zero(src_bits);
            } else {
                if vkind(e) != .C_INT return ce_cast(.BITCAST, c, dt);
                sv = const_ap(e);
            }
            buffer = ap_copy(buffer);
            ap_insert_bits(*buffer, sv, pos);
            buf_bits += src_bits;
        }
        while buf_bits >= dst_bits {
            sh := ifx is_le then cast(u32) 0 else buf_bits - dst_bits;
            if ap_is_all_ones(ap_extract_bits(undef_mask, dst_bits, sh)) {
                if !ap_is_zero(ap_extract_bits(poison_mask, dst_bits, sh)) array_add(*result, const_poison(dst_elt));
                else array_add(*result, const_undef(dst_elt));
            } else {
                array_add(*result, cf_int(dst_elt, ap_extract_bits(buffer, dst_bits, sh)));
            }
            if is_le { buffer = ap_lshr(buffer, dst_bits); undef_mask = ap_lshr(undef_mask, dst_bits); poison_mask = ap_lshr(poison_mask, dst_bits); }
            buf_bits -= dst_bits;
        }
    }
    for poison_dst if it result[it_index] = const_poison(dst_elt);
    return cf_vector(dt, result);
}
// computePoisonDstLanes
compute_poison_dst_lanes :: (c: Value_Id, nsrc: u32, ndst: u32) -> (bool, [] bool) {
    pd := NewArray(ndst, bool,, allocator = temp);
    uneven := ifx ndst < nsrc then nsrc % ndst else ndst % nsrc;
    if uneven != 0 return !contains_poison_element(c), pd;
    if ndst < nsrc {
        ratio := nsrc / ndst;
        for i: 0..ndst-1 for j: 0..ratio-1 {
            e := cf_elt(c, i * ratio + j);
            if e == NONE return false, pd;
            if vkind(e) == .C_POISON { pd[i] = true; break; }
        }
    } else {
        ratio := ndst / nsrc;
        for i: 0..nsrc-1 {
            e := cf_elt(c, i);
            if e == NONE return false, pd;
            if vkind(e) == .C_POISON for k: i * ratio..(i + 1) * ratio - 1 pd[k] = true;
        }
    }
    return true, pd;
}

// ---------------------------------------------------------------- loads

// IsConstantOffsetFromGlobal: (ok, global, offset)
is_constant_offset_from_global :: (c: Value_Id) -> (bool, Value_Id, APInt) {
    no: APInt;
    k := vkind(c);
    if is_global_value(k) return true, c, ap_zero(dl_index_bits(vtype(c)));
    if k == .C_DSO_EQUIV { g := op(c, 0); return true, g, ap_zero(dl_index_bits(vtype(g))); }
    if k != .C_EXPR return false, NONE, no;
    o := cexpr(c).op;
    if o == .PTRTOINT || o == .PTRTOADDR { ok, g, off := is_constant_offset_from_global(op(c, 0)); return ok, g, off; }
    if o != .GEP return false, NONE, no;
    ok, g, tmp := is_constant_offset_from_global(op(c, 0));
    if !ok return false, NONE, no;
    tmp = ap_zero(dl_index_bits(vtype(c)));   // TmpOffset(BitWidth, 0) is what's accumulated into
    ok2, off := gep_accumulate_constant_offset(c, tmp);
    if !ok2 return false, NONE, no;
    return true, g, off;
}

// ConstantFoldLoadThroughBitcast
cfo_load_through_bitcast :: (c_in: Value_Id, dt: Type_Id) -> Value_Id {
    c := c_in;
    while c != NONE {
        st := vtype(c);
        if st == dt return c;
        ds := dl_type_size_bits(dt); ss := dl_type_size_bits(st);
        // TypeSize::isKnownGE(SrcSize, DestSize) is false for a scalable destination and a fixed source
        if type_is_scalable(dt) && !type_is_scalable(st) return NONE;
        // TypeSize::isKnownGE (sizes are known minimums for scalable types)
        if ss < ds return NONE;
        r := cfo_load_from_uniform_value(c, dt);
        if r != NONE return r;
        if ss == ds && type_is_scalable(st) == type_is_scalable(dt) && dl_is_non_integral_pointer_type(st) == dl_is_non_integral_pointer_type(dt) {
            opc := Opcode.BITCAST;
            if is_int_type(st) && is_ptr_type(dt) opc = .INTTOPTR;
            else if is_ptr_type(st) && is_int_type(dt) opc = .PTRTOINT;
            if cast_is_valid(opc, st, dt) return cfo_cast_operand(opc, c, dt);
        }
        if !is_aggregate(st) && !is_vector_type(st) return NONE;
        if type_kind(st) == .STRUCT {
            e: u64 = 0;
            ec: Value_Id;
            while true {
                ec = cf_elt(c, e); e += 1;
                if ec == NONE || dl_type_size_bits(vtype(ec)) != 0 break;
            }
            c = ec;
        } else {
            if is_vector_type(st) && !dl_type_size_equals_store_size(type_elem(st)) return NONE;
            // getAggregateElement(0): null for a scalable integer splat unless it is a ConstantInt
            // (-use-constant-int-for-scalable-splat; ours always is one)
            ck := vkind(c);
            if type_kind(st) == .SVECTOR && ck == .C_INT && !opts.use_constant_int_for_scalable_splat return NONE;
            c = cf_elt(c, 0);
        }
    }
    return NONE;
}
// CastInst::castIsValid (the cases load folding produces)
// CastInst::castIsValid (the casts constant folding of loads creates)
cast_is_valid :: (opc: Opcode, st: Type_Id, dt: Type_Id) -> bool {
    if !is_first_class(st) || !is_first_class(dt) || type_kind(st) == .STRUCT || type_kind(dt) == .STRUCT ||
       type_kind(st) == .ARRAY || type_kind(dt) == .ARRAY return false;
    sv := is_vector_type(st); dv := is_vector_type(dt);
    s := scalar_type(st); d := scalar_type(dt);
    if opc == {
        case .INTTOPTR; #through;
        case .PTRTOINT;
            if sv != dv return false;
            if sv && (type_count(st) != type_count(dt) || type_kind(st) != type_kind(dt)) return false;
            if opc == .INTTOPTR return is_int_type(s) && is_ptr_type(d);
            return is_ptr_type(s) && is_int_type(d);
        case .BITCAST;
            sp := is_ptr_type(s); dp := is_ptr_type(d);
            if (sp && type_kind(d) == .BYTE) || (type_kind(s) == .BYTE && dp) return true;
            if sp != dp return false;
            if !sp return type_kind(st) != .SVECTOR && type_kind(dt) != .SVECTOR && dl_type_size_bits(st) == dl_type_size_bits(dt) ||
                          (type_kind(st) == .SVECTOR && type_kind(dt) == .SVECTOR && dl_type_size_bits(st) == dl_type_size_bits(dt));
            if ir.types[s].a != ir.types[d].a return false;
            if sv && dv return type_count(st) == type_count(dt) && type_kind(st) == type_kind(dt);
            if sv return type_kind(st) == .VECTOR && type_count(st) == 1;
            if dv return type_kind(dt) == .VECTOR && type_count(dt) == 1;
            return true;
    }
    return false;
}

// ReadDataFromGlobal
read_data_from_global :: (c_in: Value_Id, byte_offset_in: u64, cur: [] u8, bytes_left_in: u32, is_byte_load := false) -> bool {
    c := c_in; byte_offset := byte_offset_in; bytes_left := bytes_left_in;
    ptr := cur.data;
    t := vtype(c);
    if byte_offset >= dl_type_store_size(t) return true;
    k := vkind(c);
    if k == .C_ZERO || k == .C_UNDEF || k == .C_POISON return true;
    if k == .C_NULL && !is_vector_type(t) {
        // ConstantPointerNull isn't handled specially: fall through to "can't read"
        return false;
    }
    if k == .C_INT && is_int_type(t) {
        bw := type_int_width(t);
        if (bw & 7) != 0 return false;
        v := const_ap(c);
        int_bytes := bw / 8;
        i: u32 = 0;
        while i != bytes_left && byte_offset != int_bytes {
            n := cast(u32) byte_offset;
            if dl.big_endian n = int_bytes - n - 1;
            ptr[i] = cast(u8) ap_zext_value(ap_extract_bits(v, 8, n * 8));
            byte_offset += 1;
            i += 1;
        }
        return true;
    }
    if k == .C_FP && is_fp_type(t) {
        tk := type_kind(t);
        if tk == .DOUBLE return read_data_from_global(cfo_fold_bitcast(c, ir.t_i64), byte_offset, cur, bytes_left, is_byte_load);
        if tk == .FLOAT return read_data_from_global(cfo_fold_bitcast(c, ir.t_i32), byte_offset, cur, bytes_left, is_byte_load);
        if tk == .HALF return read_data_from_global(cfo_fold_bitcast(c, type_int(16)), byte_offset, cur, bytes_left, is_byte_load);
        return false;
    }
    if k == .C_STRUCT {
        idx := dl_struct_element_containing_offset(t, byte_offset);
        cur_elt := dl_struct_offset(t, idx);
        byte_offset -= cur_elt;
        n := type_nsub(t);
        p := cur;
        while true {
            esz := dl_type_alloc_size(vtype(op(c, idx)));
            if byte_offset < esz && !read_data_from_global(op(c, idx), byte_offset, p, bytes_left, is_byte_load) return false;
            idx += 1;
            if idx == n return true;
            next_off := dl_struct_offset(t, idx);
            adv := next_off - cur_elt - byte_offset;
            if bytes_left <= adv return true;
            p.data += adv; p.count -= cast(s64) adv;
            bytes_left -= cast(u32) adv;
            byte_offset = 0;
            cur_elt = next_off;
        }
    }
    if k == .C_ARRAY || k == .C_VECTOR || k == .C_DATA || k == .C_INT || k == .C_FP {
        num: u64; esz: u64; et: Type_Id;
        if type_kind(t) == .ARRAY { num = type_count(t); et = type_elem(t); esz = dl_type_alloc_size(et); }
        else {
            if type_kind(t) != .VECTOR return false;
            num = type_count(t); et = type_elem(t);
            if !dl_type_size_equals_store_size(et) return false;
            esz = dl_type_store_size(et);
        }
        index := byte_offset / esz;
        off := byte_offset - index * esz;
        p := cur;
        while index != num {
            if !read_data_from_global(cf_elt(c, index), off, p, bytes_left, is_byte_load) return false;
            written := esz - off;
            if written >= bytes_left return true;
            off = 0;
            bytes_left -= cast(u32) written;
            p.data += written; p.count -= cast(s64) written;
            index += 1;
        }
        return true;
    }
    if k == .C_EXPR {
        e := cexpr(c);
        if e.op == .INTTOPTR && vtype(op(c, 0)) == dl_int_ptr_type(t) {
            if is_byte_load return false;
            return read_data_from_global(op(c, 0), byte_offset, cur, bytes_left, is_byte_load);
        }
    }
    return false;
}

// FoldReinterpretLoadFromConst
fold_reinterpret_load_from_const :: (c: Value_Id, load_ty: Type_Id, orig_load_ty: Type_Id, offset_in: s64) -> Value_Id {
    offset := offset_in;
    if type_kind(load_ty) == .SVECTOR return NONE;
    if !is_int_type(load_ty) {
        lk := type_kind(load_ty);
        if !is_fp_type(load_ty) && lk != .PTR && lk != .BYTE && !is_vector_type(load_ty) return NONE;
        map_ty := type_int(cast(u32) dl_type_size_bits(load_ty));
        res := fold_reinterpret_load_from_const(c, map_ty, orig_load_ty, offset);
        if res != NONE {
            if is_null_value(res) && lk != .X86_AMX return const_null_value(load_ty);
            cast_ty := ifx is_ptr_or_ptr_vector(load_ty) then dl_int_ptr_type(load_ty) else load_ty;
            res = cfo_fold_bitcast(res, cast_ty);
            if is_ptr_or_ptr_vector(load_ty) {
                if is_null_value(res) && lk != .X86_AMX return const_null_value(load_ty);
                if dl_is_non_integral_pointer_type(load_ty) return NONE;
                res = ce_cast(.INTTOPTR, res, load_ty);
            }
            return res;
        }
        return NONE;
    }
    bw := type_int_width(load_ty);
    bytes_loaded := (bw + 7) / 8;
    if bytes_loaded > 128 || bytes_loaded == 0 return NONE;
    if bytes_loaded > 32 && is_int_type(orig_load_ty) return NONE;
    if offset <= -1 * cast(s64) bytes_loaded return const_poison(load_ty);
    init_size := dl_type_alloc_size(vtype(c));
    if type_is_scalable(vtype(c)) return NONE;
    if offset >= cast(s64) init_size return const_poison(load_ty);
    raw := NewArray(bytes_loaded, u8,, allocator = temp);
    p := raw;
    left := bytes_loaded;
    if offset < 0 {
        p.data += -offset; p.count -= -offset;
        left = cast(u32)(cast(s64) left + offset);
        offset = 0;
    }
    orig_is_byte := type_kind(scalar_type(orig_load_ty)) == .BYTE;
    if !read_data_from_global(c, cast(u64) offset, p, left, orig_is_byte) return NONE;
    rv := ap_zero(bw);
    if !dl.big_endian {
        rv = ap_from_u64(bw, raw[bytes_loaded - 1]);
        for i: 1..cast(s64) bytes_loaded - 1 { rv = ap_shl(rv, 8); rv = ap_or(rv, ap_from_u64(bw, raw[bytes_loaded - 1 - cast(u32) i])); }
    } else {
        rv = ap_from_u64(bw, raw[0]);
        for i: 1..cast(s64) bytes_loaded - 1 { rv = ap_shl(rv, 8); rv = ap_or(rv, ap_from_u64(bw, raw[i])); }
    }
    return cf_int(load_ty, rv);
}

// getConstantAtOffset
constant_at_offset :: (base: Value_Id, offset_in: APInt) -> Value_Id {
    offset := offset_in;
    if ap_is_zero(offset) return base;
    k := vkind(base);
    if k != .C_ARRAY && k != .C_STRUCT && k != .C_VECTOR && k != .C_DATA return NONE;
    et := vtype(base);
    idxs := dl_gep_indices_for_offset(*et, *offset);
    if !ap_is_zero(offset) || !ap_is_zero(idxs[0]) return NONE;
    c := base;
    for idx, i: idxs {
        if i == 0 continue;
        if ap_is_negative(idx) || ap_active_bits(idx) >= 32 return NONE;
        c = cf_elt(c, ap_zext_value(idx));
        if c == NONE return NONE;
    }
    return c;
}
// ConstantFoldLoadFromConst(C, Ty, Offset)
cfo_load_from_const :: (c: Value_Id, ty: Type_Id, offset: APInt) -> Value_Id {
    at := constant_at_offset(c, offset);
    if at != NONE {
        r := cfo_load_through_bitcast(at, ty);
        if r != NONE return r;
    }
    size := dl_type_alloc_size(vtype(c));
    if !type_is_scalable(vtype(c)) && !ap_slt_s64(offset, cast(s64) size) return const_poison(ty);
    r := cfo_load_from_uniform_value(c, ty);
    if r != NONE return r;
    if ap_min_signed_bits(offset) <= 64 {
        r = fold_reinterpret_load_from_const(c, ty, ty, ap_sext_value(offset));
        if r != NONE return r;
    }
    return NONE;
}
// GlobalVariable::hasDefinitiveInitializer
gv_has_definitive_initializer :: (g: Value_Id) -> bool {
    gr := glob(g);
    if !gr.has_init return false;
    if is_declaration(g) return false;
    if gr.ext_init return false;
    // isInterposable
    if gv_is_interposable(g) return false;
    return true;
}
gv_initializer :: (g: Value_Id) -> Value_Id { return op(g, 0); }
// ConstantFoldLoadFromConstPtr(C, Ty, Offset)
cfo_load_from_const_ptr_off :: (c_in: Value_Id, ty: Type_Id, offset_in: APInt) -> Value_Id {
    gv := get_underlying_object(c_in);
    if vkind(gv) != .GLOBAL_VAR || !glob(gv).is_const || !gv_has_definitive_initializer(gv) return NONE;
    c, offset := strip_and_accumulate_constant_offsets(c_in, offset_in, true);
    if c == gv {
        r := cfo_load_from_const(gv_initializer(gv), ty, offset);
        if r != NONE return r;
    }
    return cfo_load_from_uniform_value(gv_initializer(gv), ty);
}
cfo_load_from_const_ptr :: (c: Value_Id, ty: Type_Id) -> Value_Id {
    return cfo_load_from_const_ptr_off(c, ty, ap_zero(dl_index_bits(vtype(c))));
}
// ConstantFoldLoadFromUniformValue
cfo_load_from_uniform_value :: (c: Value_Id, ty: Type_Id) -> Value_Id {
    if vkind(c) == .C_POISON return const_poison(ty);
    if vkind(c) == .C_UNDEF return const_undef(ty);
    if !dl_type_size_equals_store_size(vtype(c)) return NONE;
    if is_null_value(c) && type_kind(ty) != .X86_AMX return const_null_value(ty);
    st := scalar_type(ty);
    if cf_is_all_ones(c) && (is_int_type(st) || type_kind(st) == .BYTE || is_fp_type(st)) return cf_all_ones(ty);
    return NONE;
}

// ---------------------------------------------------------------- binops, GEPs

// SymbolicallyEvaluateBinop
symbolically_evaluate_binop :: (opc: Opcode, op0: Value_Id, op1: Value_Id) -> Value_Id {
    if opc == .AND {
        q: Simplify_Query;
        k0 := known_bits(op0, q); k1 := known_bits(op1, q);
        if ap_is_all_ones(ap_or(k1.one, k0.zero)) return op0;
        if ap_is_all_ones(ap_or(k0.one, k1.zero)) return op1;
        k := kb_and(k0, k1);
        if kb_is_constant(k) return cf_int(vtype(op0), kb_constant(k));
    }
    if opc == .SUB {
        ok1, g1, o1 := is_constant_offset_from_global(op0);
        if ok1 {
            ok2, g2, o2 := is_constant_offset_from_global(op1);
            if ok2 && g1 == g2 {
                sz := cast(u32) dl_type_size_bits(vtype(op0));
                return cf_int(vtype(op0), ap_sub(ap_zext_or_trunc(o1, sz), ap_zext_or_trunc(o2, sz)));
            }
        }
    }
    return NONE;
}

// GetElementPtrInst::getIndexedType(SrcElemTy, Idxs[0..n)) is a struct?
gep_indexed_type_n :: (src: Type_Id, idxs: [] Value_Id) -> Type_Id {
    cur := src;
    for idx, k: idxs {
        if k == 0 continue;
        cur = gep_indexed_type(cur, k + 1, idx);
    }
    return cur;
}
// CastInst::getCastOpcode(Src, SrcIsSigned = true, DestTy, DstIsSigned = true) for integer (vector) indices
int_cast_opcode :: (src_ty: Type_Id, dst_ty: Type_Id) -> Opcode {
    sb := type_bits(scalar_type(src_ty)); db := type_bits(scalar_type(dst_ty));
    if db < sb return .TRUNC;
    if db > sb return .SEXT;
    return .BITCAST;
}
// CastGEPIndices
cast_gep_indices :: (src: Type_Id, ops: [] Value_Id, res_ty: Type_Id, flags: u32, extra: [] u32) -> Value_Id {
    idx_ty := dl_index_type(res_ty);
    idx_sty := scalar_type(idx_ty);
    any := false;
    new_idxs: [..] Value_Id; new_idxs.allocator = temp;
    for i: 1..ops.count-1 {
        sub: [] Value_Id; sub.data = ops.data + 1; sub.count = i - 1;
        if (i == 1 || type_kind(gep_indexed_type_n(src, sub)) != .STRUCT) && scalar_type(vtype(ops[i])) != idx_sty {
            any = true;
            nt := ifx is_vector_type(vtype(ops[i])) then idx_ty else idx_sty;
            ni := cfo_cast_operand(int_cast_opcode(vtype(ops[i]), nt), ops[i], nt);
            if ni == NONE return NONE;
            array_add(*new_idxs, ni);
        } else array_add(*new_idxs, ops[i]);
    }
    if !any return NONE;
    c := ce_gep(src, ops[0], new_idxs, flags, extra);
    return cfo_constant(c);
}
gep_inrange :: (g: Value_Id) -> (bool, Const_Range) {
    r: Const_Range;
    if vkind(g) != .C_EXPR || (cexpr(g).flags & F_INRANGE) == 0 return false, r;
    e := cexpr(g);
    lo := (cast(u64) ir.u32_pool[e.idx]) | ((cast(u64) ir.u32_pool[e.idx + 1]) << 32);
    hi := (cast(u64) ir.u32_pool[e.idx + 2]) | ((cast(u64) ir.u32_pool[e.idx + 3]) << 32);
    return true, cr_new(ap_from_u64(64, lo), ap_from_u64(64, hi));
}
inrange_extra :: (has: bool, r: Const_Range) -> [] u32 {
    if !has return .[];
    lo := ap_word(ap_sext_or_trunc(r.lo, 64), 0); hi := ap_word(ap_sext_or_trunc(r.hi, 64), 0);
    x := NewArray(4, u32,, allocator = temp);
    x[0] = cast,trunc(u32) lo; x[1] = cast,trunc(u32)(lo >> 32); x[2] = cast,trunc(u32) hi; x[3] = cast,trunc(u32)(hi >> 32);
    return x;
}
gep_flags_of :: (f: u32) -> u32 { return f & (F_INBOUNDS | F_NUSW | F_GEP_NUW); }
// SymbolicallyEvaluateGEP
symbolically_evaluate_gep :: (gep: Value_Id, ops: [] Value_Id) -> Value_Id {
    src := opr_gep_source_type(gep);
    res_ty := vtype(gep);
    if !type_is_sized(src) || type_kind(src) == .SVECTOR return NONE;
    has_ir, ir_range := gep_inrange(gep);
    c := cast_gep_indices(src, ops, res_ty, gep_flags_of(opr_flags(gep)) | ifx has_ir then cast(u32) F_INRANGE else 0, inrange_extra(has_ir, ir_range));
    if c != NONE return c;
    ptr := ops[0];
    if !is_ptr_type(vtype(ptr)) return NONE;
    idx_ty := dl_index_type(vtype(ptr));
    for i: 1..ops.count-1 if !is_scalar_const_int(ops[i]) return NONE;
    bw := type_int_width(idx_ty);
    sub: [] Value_Id; sub.data = ops.data + 1; sub.count = ops.count - 1;
    offset := ap_from_s64(bw, dl_indexed_offset_in_type(src, sub));
    if has_ir ir_range = cr_sext_or_trunc(ir_range, bw);
    nw := gep_flags_of(opr_flags(gep));
    overflow := false;
    while opr_code(ptr) == .GEP {
        g := ptr;
        nw &= gep_flags_of(opr_flags(g));
        all_ci := true;
        n := nops(g);
        for k: 1..cast(s64) n - 1 if !is_scalar_const_int(op(g, cast(u32) k)) { all_ci = false; break; }
        if !all_ci break;
        okg, gr := gep_inrange(g);
        if okg {
            adj := cr_subtract(cr_sext_or_trunc(gr, bw), offset);
            if has_ir ir_range = cr_intersect(ir_range, adj); else { ir_range = adj; has_ir = true; }
        }
        nested: [..] Value_Id; nested.allocator = temp;
        for k: 1..cast(s64) n - 1 array_add(*nested, op(g, cast(u32) k));
        ptr = op(g, 0);
        src = opr_gep_source_type(g);
        o, ov := ap_sadd_ov(offset, ap_from_s64(bw, dl_indexed_offset_in_type(src, nested)));
        offset = o;
        overflow = ov;   // (sadd_ov sets Overflow each time)
    }
    // NW.hasNoUnsignedSignedWrap() && !NW.isInBounds() && Overflow
    if (nw & F_NUSW) != 0 && (nw & F_INBOUNDS) == 0 && overflow nw &= ~cast(u32) F_NUSW;   // (inbounds implies nusw)
    base_int := ap_zero(dl_ptr_spec(cast(u32) ir.types[vtype(ptr)].a).bits);
    if vkind(ptr) == .C_EXPR && cexpr(ptr).op == .INTTOPTR && is_scalar_const_int(op(ptr, 0))
        base_int = ap_zext_or_trunc(const_ap(op(ptr, 0)), base_int.bits);
    if (is_null_value(ptr) || !ap_is_zero(base_int)) && !dl_must_not_introduce_int_to_ptr(vtype(ptr)) {
        base_int = ap_copy(base_int);
        ap_insert_bits(*base_int, ap_add(ap_trunc(base_int, bw), offset), 0);
        ci := cf_int(type_int(base_int.bits), base_int);
        return ce_cast(.INTTOPTR, ci, res_ty);
    }
    if (nw & F_INBOUNDS) == 0 && ap_is_non_negative(offset) {
        can_be_null, deref := pointer_dereferenceable_bytes(ptr);
        if deref != 0 && !can_be_null && !ap_sgt_s64(offset, cast(s64) deref)
            nw |= F_INBOUNDS;   // GEPNoWrapFlags::inBounds() (implies nusw)
    }
    if (nw & (F_NUSW | F_INBOUNDS)) != 0 && ap_is_non_negative(offset) nw |= F_GEP_NUW;
    // ConstantExpr::getPtrAdd(Ptr, Offset, NW, InRange): getelementptr i8
    oc := cf_int(type_int(bw), offset);
    f := nw;
    if has_ir f |= F_INRANGE;
    return ce_gep(ir.t_i8, ptr, .[oc], f, inrange_extra(has_ir, ir_range));
}

// Value::getPointerDereferenceableBytes: (CanBeNull, bytes)
pointer_dereferenceable_bytes :: (v: Value_Id) -> (bool, u64) {
    k := vkind(v);
    if k == .ARGUMENT {
        s := arg_attrs(v);
        a := attr_set_find(s, .Dereferenceable);
        d: u64 = ifx a then a.ival else 0;
        if d == 0 {
            mt := arg_pointee_in_memory_value_type(v);
            if mt != NONE && type_is_sized(mt) d = dl_type_store_size(mt);
        }
        if d == 0 {
            a2 := attr_set_find(s, .DereferenceableOrNull);
            return true, ifx a2 then a2.ival else 0;
        }
        return false, d;
    }
    if k == .INST {
        o := inst_op(v);
        if is_call_base(v) {
            a := call_ret_attr(v, .Dereferenceable);
            if a && a.ival != 0 return false, a.ival;
            a2 := call_ret_attr(v, .DereferenceableOrNull);
            return true, ifx a2 then a2.ival else 0;
        }
        if o == .LOAD || o == .INTTOPTR {
            m := get_metadata(v, md_fixed("dereferenceable"));
            d: u64 = 0;
            if m != NONE d = ap_limited(const_ap(ir.mds[md_op(m, 0)].value));
            if d == 0 {
                m2 := get_metadata(v, md_fixed("dereferenceable_or_null"));
                if m2 != NONE d = ap_limited(const_ap(ir.mds[md_op(m2, 0)].value));
                return true, d;
            }
            return false, d;
        }
        if o == .ALLOCA {
            ok, sz := alloca_allocation_size(v);
            if ok return false, sz;
        }
        return false, 0;
    }
    if k == .GLOBAL_VAR {
        g := glob(v);
        if type_is_sized(g.value_type) && g.linkage != .EXTERN_WEAK return false, dl_type_store_size(g.value_type);
    }
    return false, 0;
}
// Argument::getPointeeInMemoryValueType (byval / sret / inalloca / preallocated / byref types)
arg_pointee_in_memory_value_type :: (a: Value_Id) -> Type_Id {
    s := arg_attrs(a);
    for k: Attr_Kind.[.ByVal, .StructRet, .InAlloca, .Preallocated, .ByRef] {
        at := attr_set_find(s, k);
        if at && at.ty != NONE return at.ty;
    }
    return NONE;
}
// AllocaInst::getAllocationSize (fixed sizes only)
// AllocaInst::getAllocationSize (the known minimum for scalable types)
alloca_allocation_size :: (a: Value_Id) -> (bool, u64) {
    t := inst(a).ty2;
    sz := dl_type_alloc_size(t);
    if sz == 0 return true, 0;
    n := op(a, 0);
    if !is_scalar_const_int(n) return false, 0;
    c := const_ap(n);
    if ap_active_bits(c) > 64 return false, 0;
    lo, hi := mul_u64(sz, ap_zext_value(c));
    if hi != 0 return false, 0;
    return true, lo;
}

// ---------------------------------------------------------------- instructions

// ConstantFoldInstOperandsImpl
cfo_inst_operands_impl :: (v: Value_Id, opc: Opcode, ops: [] Value_Id, allow_non_deterministic: bool) -> Value_Id {
    dt := vtype(v);
    if opc == .FNEG return cfo_unary_op_operand(opc, ops[0]);
    if is_binary_op(opc) {
        if (opc == .FADD || opc == .FSUB || opc == .FMUL || opc == .FDIV || opc == .FREM) && vkind(v) == .INST
            return cfo_fp_inst_operands(opc, ops[0], ops[1], v, allow_non_deterministic);
        return cfo_binary_op_operands(opc, ops[0], ops[1]);
    }
    if is_cast_op(opc) return cfo_cast_operand(opc, ops[0], dt);
    if opc == .GEP {
        src := opr_gep_source_type(v);
        // ConstantExpr::isSupportedGetElementPtr: not a target extension type... (sized-ness is checked later)
        if type_kind(src) == .TARGET_EXT || type_is_scalable(src) return NONE;   // !isScalableTy()
        c := symbolically_evaluate_gep(v, ops);
        if c != NONE return c;
        has_ir, irr := gep_inrange(v);
        f := gep_flags_of(opr_flags(v));
        if has_ir f |= F_INRANGE;
        rest: [] Value_Id; rest.data = ops.data + 1; rest.count = ops.count - 1;
        return ce_gep(src, ops[0], rest, f, inrange_extra(has_ir, irr));
    }
    if vkind(v) == .C_EXPR return ce_with_operands(v, ops);
    if opc == {
        case .ICMP; #through;
        case .FCMP; return cfo_compare_inst_operands(inst_pred(v), ops[0], ops[1], v);
        case .FREEZE; if is_guaranteed_not_to_be_undef_or_poison(ops[0]) return ops[0]; return NONE;
        case .CALL;
            f := ops[ops.count - 1];
            if vkind(f) == .FUNCTION && can_constant_fold_call_to(v, f) {
                args: [] Value_Id; args.data = ops.data; args.count = ops.count - 1;
                return cfo_call(v, f, args, allow_non_deterministic);
            }
            return NONE;
        case .SELECT; return cf_select(ops[0], ops[1], ops[2]);
        case .EXTRACTELEMENT; return ce_extract_element(ops[0], ops[1]);
        case .EXTRACTVALUE; return cf_extract_value(ops[0], inst_indices(v));
        case .INSERTELEMENT; return ce_insert_element(ops[0], ops[1], ops[2]);
        case .INSERTVALUE; return cf_insert_value(ops[0], ops[1], inst_indices(v));
        case .SHUFFLEVECTOR; return ce_shuffle_vector(ops[0], ops[1], shuffle_mask(v));
        case .LOAD;
            if (inst(v).flags & F_VOLATILE) != 0 return NONE;
            return cfo_load_from_const_ptr(ops[0], dt);
    }
    return NONE;
}
inst_indices :: (v: Value_Id) -> [] u32 {
    s: [] u32; r := inst(v); s.data = ir.u32_pool.data + r.idx; s.count = r.nidx; return s;
}
// ConstantExpr::getWithOperands
ce_with_operands :: (c: Value_Id, ops: [] Value_Id) -> Value_Id {
    e := cexpr(c);
    same := true;
    for ops if it != op(c, cast(u32) it_index) { same = false; break; }
    if same return c;
    extra: [] u32; extra.data = ir.u32_pool.data + e.idx; extra.count = e.nidx;
    if is_cast_op(e.op) return ce_cast(e.op, ops[0], vtype(c));
    if e.op == {
        case .SHUFFLEVECTOR; return ce_shuffle_vector(ops[0], ops[1], extra);
        case .INSERTELEMENT; return ce_insert_element(ops[0], ops[1], ops[2]);
        case .EXTRACTELEMENT; return ce_extract_element(ops[0], ops[1]);
        case .GEP;
            rest: [] Value_Id; rest.data = ops.data + 1; rest.count = ops.count - 1;
            return ce_gep(e.ty2, ops[0], rest, e.flags, extra);
    }
    if is_binary_op(e.op) return ce_binop(e.op, ops[0], ops[1], e.flags);
    fatal("internal: ConstantExpr::getWithOperands for '%'", opcode_name(e.op));
    return NONE;
}

// ConstantFoldConstantImpl
cfo_constant_impl :: (c: Value_Id, folded: *Table(Value_Id, Value_Id)) -> Value_Id {
    k := vkind(c);
    if k != .C_VECTOR && k != .C_EXPR return c;
    ops: [..] Value_Id; ops.allocator = temp;
    n := nops(c);
    for i: 0..cast(s64) n - 1 {
        old := op(c, cast(u32) i);
        nc := old;
        ok := vkind(old);
        if ok == .C_VECTOR || ok == .C_EXPR {
            found, prev := table_find(folded, old);
            if !found { nc = cfo_constant_impl(old, folded); table_set(folded, old, nc); }
            else nc = prev;
        }
        array_add(*ops, nc);
    }
    if k == .C_EXPR {
        r := cfo_inst_operands_impl(c, cexpr(c).op, ops, true);
        if r != NONE return r;
        return c;
    }
    return cf_vector(vtype(c), ops);
}
// ConstantFoldConstant
cfo_constant :: (c: Value_Id) -> Value_Id {
    folded: Table(Value_Id, Value_Id); folded.allocator = temp;
    return cfo_constant_impl(c, *folded);
}
// ConstantFoldInstruction
cfo_instruction :: (i: Value_Id) -> Value_Id {
    folded: Table(Value_Id, Value_Id); folded.allocator = temp;
    if is_phi(i) {
        common: Value_Id = NONE;
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            inc := op(i, cast(u32) k);
            if pm_undef_value(inc) continue;
            if !is_const(inc) return NONE;
            c := cfo_constant_impl(inc, *folded);
            if common != NONE && c != common return NONE;
            common = c;
        }
        if common != NONE return common;
        return const_undef(vtype(i));
    }
    n := nops(i);
    for k: 0..cast(s64) n - 1 if !is_const(op(i, cast(u32) k)) return NONE;
    ops: [..] Value_Id; ops.allocator = temp;
    for k: 0..cast(s64) n - 1 array_add(*ops, cfo_constant_impl(op(i, cast(u32) k), *folded));
    return cfo_inst_operands(i, ops);
}
// ConstantFoldInstOperands
cfo_inst_operands :: (i: Value_Id, ops: [] Value_Id, allow_non_deterministic := true) -> Value_Id {
    return cfo_inst_operands_impl(i, inst_op(i), ops, allow_non_deterministic);
}

// ConstantFoldCompareInstOperands
cfo_compare_inst_operands :: (pred_in: u8, ops0_in: Value_Id, ops1_in: Value_Id, i: Value_Id = NONE) -> Value_Id {
    pred := pred_in; ops0 := ops0_in; ops1 := ops1_in;
    if vkind(ops0) == .C_EXPR {
        ce0 := cexpr(ops0);
        if is_null_value(ops1) {
            if ce0.op == .INTTOPTR {
                ipt := dl_int_ptr_type(vtype(ops0));
                c := cfo_integer_cast(op(ops0, 0), ipt, false);
                if c != NONE return cfo_compare_inst_operands(pred, c, const_null_value(vtype(c)));
            }
            if ce0.op == .PTRTOINT || ce0.op == .PTRTOADDR {
                at := dl_address_type(vtype(op(ops0, 0)));
                if vtype(ops0) == at {
                    c := op(ops0, 0);
                    return cfo_compare_inst_operands(pred, c, const_null_value(vtype(c)));
                }
            }
        }
        if vkind(ops1) == .C_EXPR {
            ce1 := cexpr(ops1);
            if ce0.op == ce1.op {
                if ce0.op == .INTTOPTR {
                    ipt := dl_int_ptr_type(vtype(ops0));
                    c0 := cfo_integer_cast(op(ops0, 0), ipt, false);
                    c1 := cfo_integer_cast(op(ops1, 0), ipt, false);
                    if c0 != NONE && c1 != NONE return cfo_compare_inst_operands(pred, c0, c1);
                }
                if ce0.op == .PTRTOINT || ce0.op == .PTRTOADDR {
                    at := dl_address_type(vtype(op(ops0, 0)));
                    if vtype(ops0) == at && vtype(op(ops0, 0)) == vtype(op(ops1, 0))
                        return cfo_compare_inst_operands(pred, op(ops0, 0), op(ops1, 0));
                }
            }
        }
        if is_ptr_type(vtype(ops0)) && !icmp_is_signed(pred) {
            iw := dl_index_bits(vtype(ops0));
            is_eq := icmp_is_equality(pred);
            s0, o0 := strip_and_accumulate_constant_offsets(ops0, ap_zero(iw), is_eq, false, is_eq);
            s1, o1 := strip_and_accumulate_constant_offsets(ops1, ap_zero(iw), is_eq, false, is_eq);
            if s0 == s1 return cf_bool(ir.t_i1, icmp_compare(o0, o1, icmp_signed_predicate(pred)));
        }
    } else if vkind(ops1) == .C_EXPR {
        return cfo_compare_inst_operands(cmp_swapped(pred), ops1, ops0, i);
    }
    if is_fp_predicate(pred) {
        ops0 = flush_fp_constant(ops0, i, false);
        if ops0 == NONE return NONE;
        ops1 = flush_fp_constant(ops1, i, false);
        if ops1 == NONE return NONE;
    }
    return cf_compare(pred, ops0, ops1);
}
// ConstantFoldUnaryOpOperand
cfo_unary_op_operand :: (opc: Opcode, c: Value_Id) -> Value_Id { return cf_unary(opc, c); }
// ConstantFoldBinaryOpOperands
cfo_binary_op_operands :: (opc: Opcode, lhs: Value_Id, rhs: Value_Id) -> Value_Id {
    if vkind(lhs) == .C_EXPR || vkind(rhs) == .C_EXPR {
        c := symbolically_evaluate_binop(opc, lhs, rhs);
        if c != NONE return c;
    }
    if is_desirable_bin_op(opc) return ce_binop(opc, lhs, rhs, 0);
    return cf_binary(opc, lhs, rhs);
}

// Denormal mode of the function containing `i` for FP type `t` (Function::getDenormalMode): (output, input),
// kinds 0 ieee, 1 preservesign, 2 positivezero, 3 dynamic
DENORMAL_IEEE :: 0; DENORMAL_PRESERVE_SIGN :: 1; DENORMAL_POSITIVE_ZERO :: 2; DENORMAL_DYNAMIC :: 3;
fn_denormal_mode :: (f: Value_Id, t: Type_Id) -> (u8, u8) {
    a := fn_get_fn_attr(f, .DenormalFPEnv);
    if !a return DENORMAL_IEEE, DENORMAL_IEEE;
    e := a.ival;
    if type_kind(scalar_type(t)) == .FLOAT e = e >> 8;
    return cast(u8)(e & 0xF), cast(u8)((e >> 4) & 0xF);
}
inst_denormal_mode :: (i: Value_Id, t: Type_Id) -> (u8, u8) {
    if i == NONE || vkind(i) != .INST || inst(i).parent == NONE return DENORMAL_DYNAMIC, DENORMAL_DYNAMIC;
    o, inp := fn_denormal_mode(inst_fn(i), t);
    return o, inp;
}
apf_is_denormal :: (f: APFloat) -> bool {
    g := f;
    if g.k == .PPC_FP128 return dd_is_denormal(apf_words(*g));
    d := fp_decode(g.k, apf_words(*g));
    if d.cat != .NORMAL return false;
    if g.k == .PPC_FP128 {
        // DoubleAPFloat::isDenormal: either half denormal, or (double)(Hi + Lo) != Hi
        w := apf_words(*g);
        hi := w[0]; lo := w[1];
        hd := (cast(*float64) *hi).*; ld := (cast(*float64) *lo).*;
        is_den :: (x: u64) -> bool { return ((x >> 52) & 0x7FF) == 0 && (x & 0xF_FFFF_FFFF_FFFF) != 0; }
        return is_den(hi) || is_den(lo) || hd != hd + ld;
    }
    p, emax, emin, b := fp_semantics(g.k);
    return big_bitlen(d.sig) < p;   // fp_decode gives denormals exponent emin and a significand narrower than p
}
// flushDenormalConstant
flush_denormal_constant :: (t: Type_Id, f: APFloat, mode: u8) -> Value_Id {
    g := f;
    if mode == {
        case DENORMAL_DYNAMIC; return NONE;
        case DENORMAL_IEEE; return const_fp_words(t, apf_words(*g));
        case DENORMAL_PRESERVE_SIGN; return const_fp_words(t, fp_zero(g.k, apf_is_negative(g)));
        case DENORMAL_POSITIVE_ZERO; return const_fp_words(t, fp_zero(g.k, false));
    }
    fatal("internal: unknown denormal mode");
    return NONE;
}
flush_denormal_constant_fp :: (c: Value_Id, i: Value_Id, is_output: bool) -> Value_Id {
    f := apf_from_const(c);
    if !apf_is_denormal(f) return c;
    o, inp := inst_denormal_mode(i, vtype(c));
    return flush_denormal_constant(vtype(c), f, ifx is_output then o else inp);
}
// FlushFPConstant
flush_fp_constant :: (operand: Value_Id, i: Value_Id, is_output: bool) -> Value_Id {
    k := vkind(operand);
    if k == .C_FP && !is_vector_type(vtype(operand)) return flush_denormal_constant_fp(operand, i, is_output);
    if k == .C_ZERO || pm_undef_value(operand) return operand;
    ty := vtype(operand);
    if is_vector_type(ty) {
        s := get_splat_value(operand);
        if s != NONE && vkind(s) == .C_FP {
            folded := flush_denormal_constant_fp(s, i, is_output);
            if folded == NONE return NONE;
            return cf_get_splat(ty, folded);
        }
        ty = type_elem(ty);
    }
    if k == .C_EXPR return operand;
    if k == .C_VECTOR {
        ne: [..] Value_Id; ne.allocator = temp;
        n := nops(operand);
        for e: 0..cast(s64) n - 1 {
            el := op(operand, cast(u32) e);
            if pm_undef_value(el) { array_add(*ne, el); continue; }
            if vkind(el) != .C_FP return NONE;
            f := flush_denormal_constant_fp(el, i, is_output);
            if f == NONE return NONE;
            array_add(*ne, f);
        }
        return cf_vector(vtype(operand), ne);
    }
    if k == .C_DATA {
        ne: [..] Value_Id; ne.allocator = temp;
        n := const_data_count(operand);
        for e: 0..cast(s64) n - 1 {
            el := cf_elt(operand, cast(u64) e);
            f := apf_from_const(el);
            if !apf_is_denormal(f) array_add(*ne, el);
            else {
                o, inp := inst_denormal_mode(i, ty);
                fl := flush_denormal_constant(ty, f, ifx is_output then o else inp);
                if fl == NONE return NONE;
                array_add(*ne, fl);
            }
        }
        return cf_vector(vtype(operand), ne);
    }
    return NONE;
}
// Constant::isNaN
const_is_nan :: (c: Value_Id) -> bool {
    if vkind(c) == .C_FP && !is_vector_type(vtype(c)) return apf_is_nan(apf_from_const(c));
    if !is_vector_type(vtype(c)) return false;
    s := get_splat_value(c);
    if s != NONE return vkind(s) == .C_FP && apf_is_nan(apf_from_const(s));
    if type_kind(vtype(c)) != .VECTOR return false;
    n := type_count(vtype(c));
    for e: 0..cast(s64) n - 1 {
        el := cf_elt(c, cast(u64) e);
        if el == NONE || vkind(el) != .C_FP || !apf_is_nan(apf_from_const(el)) return false;
    }
    return true;
}
// ConstantFoldFPInstOperands
cfo_fp_inst_operands :: (opc: Opcode, lhs: Value_Id, rhs: Value_Id, i: Value_Id, allow_non_deterministic := true) -> Value_Id {
    if is_binary_op(opc) {
        op0 := flush_fp_constant(lhs, i, false);
        if op0 == NONE return NONE;
        op1 := flush_fp_constant(rhs, i, false);
        if op1 == NONE return NONE;
        if !allow_non_deterministic && i != NONE && is_fp_math_operator(i) {
            fm := inst_fmf(i);
            if (fm & (FMF_NSZ | FMF_REASSOC | FMF_CONTRACT | FMF_ARCP)) != 0 return NONE;
        }
        c := cfo_binary_op_operands(opc, op0, op1);
        if c == NONE return NONE;
        c = flush_fp_constant(c, i, true);
        if c == NONE return NONE;
        if !allow_non_deterministic && const_is_nan(c) return NONE;
        return c;
    }
    return cfo_binary_op_operands(opc, lhs, rhs);
}

disable_i2p_p2i_opt := false;   // -disable-i2p-p2i-opt (Instructions.cpp DisableI2pP2iOpt)

// CastInst::isEliminableCastPair with a DataLayout (cases 7 and 11 need it; the rest is constfold.jai's)
is_eliminable_cast_pair_dl :: (first: Opcode, second: Opcode, src: Type_Id, mid: Type_Id, dst: Type_Id) -> Opcode {
    first_bc := first == .BITCAST; second_bc := second == .BITCAST;
    if (first_bc && is_vector_type(src) != is_vector_type(mid)) || (second_bc && is_vector_type(mid) != is_vector_type(dst))
        if !(first_bc && second_bc) return .NONE_OP;
    c := CAST_RESULTS[(cast(s64) first - cast(s64) Opcode.TRUNC) * 14 + (cast(s64) second - cast(s64) Opcode.TRUNC)];
    if c == 7 {
        if disable_i2p_p2i_opt return .NONE_OP;   // -disable-i2p-p2i-opt
        if src != dst return .NONE_OP;
        if type_bits(scalar_type(mid)) < dl_ptr_spec(cast(u32) ir.types[scalar_type(src)].a).bits return .NONE_OP;
        return .BITCAST;
    }
    if c == 11 {
        ms := ifx second == .PTRTOADDR then dl_index_bits(mid) else dl_ptr_spec(cast(u32) ir.types[scalar_type(mid)].a).bits;
        ss := type_bits(scalar_type(src)); ds := type_bits(scalar_type(dst));
        if ms < ss && ms < ds return .NONE_OP;
        if ds < ss return .TRUNC;
        if ds > ss return .ZEXT;
        return .BITCAST;
    }
    return is_eliminable_cast_pair(first, second, src, mid, dst);
}

// ConstantFoldCastOperand
cfo_cast_operand :: (opc: Opcode, c: Value_Id, dt: Type_Id) -> Value_Id {
    if vkind(c) == .C_EXPR && is_cast_op(cexpr(c).op) {
        nop := is_eliminable_cast_pair_dl(cexpr(c).op, opc, vtype(op(c, 0)), vtype(c), dt);
        if nop != .NONE_OP return cfo_cast_operand(nop, op(c, 0), dt);
    }
    if opc == {
        case .PTRTOADDR; #through;
        case .PTRTOINT;
            if vkind(c) == .C_EXPR {
                e := cexpr(c);
                folded: Value_Id = NONE;
                if e.op == .INTTOPTR {
                    mid := ifx opc == .PTRTOINT then dl_address_type(vtype(c)) else dl_int_ptr_type(vtype(c));
                    folded = cfo_integer_cast(op(c, 0), mid, false);
                } else if e.op == .GEP {
                    bw := dl_index_bits(vtype(c));
                    base, boff := strip_and_accumulate_constant_offsets(c, ap_zero(bw), true);
                    if is_null_value(base) {
                        folded = cf_int(type_int(bw), boff);
                    } else if nops(c) == 2 && is_int_type(e.ty2) && type_int_width(e.ty2) == 8 {
                        ptr := op(c, 0);
                        sub := op(c, 1);
                        iit := dl_index_type(vtype(ptr));
                        if vkind(sub) == .C_EXPR && vtype(sub) == iit && cexpr(sub).op == .SUB && is_null_value(op(sub, 0))
                            folded = ce_binop(.SUB, ce_cast(opc, ptr, iit), op(sub, 1), 0);
                    }
                }
                if folded != NONE return cfo_integer_cast(folded, dt, false);
            }
        case .INTTOPTR;
            if vkind(c) == .C_EXPR && cexpr(c).op == .PTRTOINT {
                sp := op(c, 0);
                sps := dl_ptr_spec(cast(u32) ir.types[scalar_type(vtype(sp))].a).bits;
                mis := type_bits(scalar_type(vtype(c)));
                if mis >= sps {
                    if ir.types[scalar_type(vtype(sp))].a == ir.types[scalar_type(dt)].a return cfo_fold_bitcast(sp, dt);
                }
            }
        case .BITCAST;
            return cfo_fold_bitcast(c, dt);
    }
    if is_desirable_cast_op(opc) return ce_cast(opc, c, dt);
    return cf_cast(opc, c, dt);
}
// ConstantFoldIntegerCast
cfo_integer_cast :: (c: Value_Id, dt: Type_Id, is_signed: bool) -> Value_Id {
    st := vtype(c);
    if st == dt return c;
    if type_bits(scalar_type(st)) > type_bits(scalar_type(dt)) return cfo_cast_operand(.TRUNC, c, dt);
    if is_signed return cfo_cast_operand(.SEXT, c, dt);
    return cfo_cast_operand(.ZEXT, c, dt);
}
