// VNCoercion: port of llvm/lib/Transforms/Utils/VNCoercion.cpp (canCoerceMustAliasedValueToLoad,
// coerceAvailableValueToLoadType, analyzeLoadFromClobberingWrite / Store / Load / MemInst,
// getStoreValueForLoadHelper, getValueForLoad, getMemInstValueForLoad). The NewGVN-only getConstantValueForLoad and
// getConstantMemInstValueForLoad are in pass_newgvn.jai. The builder is IRBuilder<> (ConstantFolder): Irb.

vnc_is_first_class_aggregate_or_scalable :: (t: Type_Id) -> bool {
    k := type_kind(t);
    return k == .STRUCT || k == .ARRAY || type_is_scalable(t);
}

// canCoerceMustAliasedValueToLoad
vnc_can_coerce_must_aliased_value_to_load :: (stored_val: Value_Id, load_ty: Type_Id, f: Value_Id) -> bool {
    stored_ty := vtype(stored_val);
    if stored_ty == load_ty return true;
    min_store := dl_type_size_bits(stored_ty);
    store_scalable := type_kind(stored_ty) == .SVECTOR;
    load_size := dl_type_size_bits(load_ty);
    load_scalable := type_kind(load_ty) == .SVECTOR;
    if store_scalable && load_scalable && min_store == load_size return true;
    if store_scalable && type_kind(load_ty) == .VECTOR {
        if scalar_type(stored_ty) != scalar_type(load_ty) return false;
        a := fn_get_fn_attr(f, .VScaleRange);
        min_vscale: u64 = 1;
        if a min_vscale = a.ival >> 32;
        min_store = min_store * min_vscale;
        store_scalable = false;
    } else if vnc_is_first_class_aggregate_or_scalable(load_ty) || vnc_is_first_class_aggregate_or_scalable(stored_ty) {
        return false;
    }
    if ((min_store + 7) / 8) * 8 != min_store return false;
    // TypeSize::isKnownGE(MinStoreSize, LoadSize)
    if store_scalable != load_scalable {
        if !store_scalable && load_scalable return false;
    }
    if min_store < load_size return false;
    stored_ni := dl_is_non_integral_pointer_type(scalar_type(stored_ty));
    load_ni := dl_is_non_integral_pointer_type(scalar_type(load_ty));
    if stored_ni != load_ni {
        if is_const(stored_val) return is_null_value(stored_val);
        return false;
    } else if stored_ni && load_ni && ir.types[scalar_type(stored_ty)].a != ir.types[scalar_type(load_ty)].a {
        return false;
    }
    if stored_ni && (type_is_scalable(stored_ty) || min_store != load_size) return false;
    if type_kind(stored_ty) == .TARGET_EXT || type_kind(load_ty) == .TARGET_EXT return false;
    return true;
}

// coerceAvailableValueToLoadType
vnc_coerce_available_value_to_load_type :: (stored_val_in: Value_Id, loaded_ty: Type_Id, b: *Irb, f: Value_Id) -> Value_Id {
    stored_val := stored_val_in;
    if is_const(stored_val) stored_val = cfo_constant(stored_val);
    stored_ty := vtype(stored_val);
    if type_kind(stored_ty) == .SVECTOR && type_kind(loaded_ty) == .VECTOR
        return irb_intrinsic(b, "llvm.vector.extract", .[loaded_ty, stored_ty], .[stored_val, const_int(ir.t_i64, 0)]);
    stored_size := dl_type_size_bits(stored_ty);
    loaded_size := dl_type_size_bits(loaded_ty);
    if stored_size == loaded_size && type_is_scalable(stored_ty) == type_is_scalable(loaded_ty) {
        if is_ptr_or_ptr_vector(stored_ty) && is_ptr_or_ptr_vector(loaded_ty) {
            stored_val = irb_bitcast(b, stored_val, loaded_ty);
        } else {
            if is_ptr_or_ptr_vector(stored_ty) {
                stored_ty = dl_int_ptr_type(stored_ty);
                stored_val = irb_cast(b, .PTRTOINT, stored_val, stored_ty);
            }
            cast_to := loaded_ty;
            if is_ptr_or_ptr_vector(cast_to) cast_to = dl_int_ptr_type(cast_to);
            if stored_ty != cast_to stored_val = irb_bitcast(b, stored_val, cast_to);
            if is_ptr_or_ptr_vector(loaded_ty) stored_val = irb_cast(b, .INTTOPTR, stored_val, loaded_ty);
        }
        if vkind(stored_val) == .C_EXPR stored_val = cfo_constant(stored_val);
        return stored_val;
    }
    if is_ptr_or_ptr_vector(stored_ty) {
        stored_ty = dl_int_ptr_type(stored_ty);
        stored_val = irb_cast(b, .PTRTOINT, stored_val, stored_ty);
    }
    if !is_int_type(stored_ty) {
        stored_ty = type_int(cast(u32) stored_size);
        stored_val = irb_bitcast(b, stored_val, stored_ty);
    }
    if dl.big_endian {
        shift := dl_type_store_size(stored_ty) * 8 - dl_type_store_size(loaded_ty) * 8;
        stored_val = irb_binop(b, .LSHR, stored_val, const_int(vtype(stored_val), shift));
    }
    new_int_ty := type_int(cast(u32) loaded_size);
    stored_val = irb_trunc_or_bitcast(b, stored_val, new_int_ty);
    if loaded_ty != new_int_ty {
        if is_ptr_or_ptr_vector(loaded_ty) stored_val = irb_cast(b, .INTTOPTR, stored_val, loaded_ty);
        else stored_val = irb_bitcast(b, stored_val, loaded_ty);
    }
    if is_const(stored_val) stored_val = cfo_constant(stored_val);
    return stored_val;
}

// CreateTruncOrBitCast
irb_trunc_or_bitcast :: (b: *Irb, v: Value_Id, t: Type_Id) -> Value_Id {
    if scalar_bits_of_type(vtype(v)) == scalar_bits_of_type(t) return irb_bitcast(b, v, t);
    return irb_cast(b, .TRUNC, v, t);
}
// CreateZExtOrBitCast
irb_zext_or_bitcast :: (b: *Irb, v: Value_Id, t: Type_Id) -> Value_Id {
    if scalar_bits_of_type(vtype(v)) == scalar_bits_of_type(t) return irb_bitcast(b, v, t);
    return irb_cast(b, .ZEXT, v, t);
}
scalar_bits_of_type :: (t: Type_Id) -> u64 { return dl_type_size_bits(scalar_type(t)); }

// analyzeLoadFromClobberingWrite
vnc_analyze_load_from_clobbering_write :: (load_ty: Type_Id, load_ptr: Value_Id, write_ptr: Value_Id, write_size_bits: u64) -> s64 {
    if vnc_is_first_class_aggregate_or_scalable(load_ty) return -1;
    store_base, store_off := get_pointer_base_with_constant_offset(write_ptr);
    load_base, load_off := get_pointer_base_with_constant_offset(load_ptr);
    if store_base != load_base return -1;
    load_size := dl_type_size_bits(load_ty);
    if ((write_size_bits & 7) | (load_size & 7)) != 0 return -1;
    store_size := cast(s64) (write_size_bits / 8);
    ls := cast(s64) (load_size / 8);
    if store_off > load_off || store_off + store_size < load_off + ls return -1;
    return load_off - store_off;
}
// analyzeLoadFromClobberingStore
vnc_analyze_load_from_clobbering_store :: (load_ty: Type_Id, load_ptr: Value_Id, dep_si: Value_Id) -> s64 {
    sv := op(dep_si, 0);
    if vnc_is_first_class_aggregate_or_scalable(vtype(sv)) return -1;
    if !vnc_can_coerce_must_aliased_value_to_load(sv, load_ty, inst_fn(dep_si)) return -1;
    return vnc_analyze_load_from_clobbering_write(load_ty, load_ptr, op(dep_si, 1), dl_type_size_bits(vtype(sv)));
}
// analyzeLoadFromClobberingLoad
vnc_analyze_load_from_clobbering_load :: (load_ty: Type_Id, load_ptr: Value_Id, dep_li: Value_Id) -> s64 {
    if vnc_is_first_class_aggregate_or_scalable(vtype(dep_li)) return -1;
    if !vnc_can_coerce_must_aliased_value_to_load(dep_li, load_ty, inst_fn(dep_li)) return -1;
    return vnc_analyze_load_from_clobbering_write(load_ty, load_ptr, op(dep_li, 0), dl_type_size_bits(vtype(dep_li)));
}
// analyzeLoadFromClobberingMemInst
vnc_analyze_load_from_clobbering_mem_inst :: (load_ty: Type_Id, load_ptr: Value_Id, mi: Value_Id) -> s64 {
    len := call_arg(mi, 2);
    if vkind(len) != .C_INT return -1;
    mem_size_bits := const_int_zext(len) * 8;
    if is_memset_intrinsic(mi) {
        if dl_is_non_integral_pointer_type(scalar_type(load_ty)) {
            v := call_arg(mi, 1);
            if vkind(v) != .C_INT || !is_null_value(v) return -1;
        }
        return vnc_analyze_load_from_clobbering_write(load_ty, load_ptr, strip_pointer_casts(call_arg(mi, 0)), mem_size_bits);
    }
    src := strip_pointer_casts(call_arg(mi, 1));   // MemTransferInst::getSource
    if !is_const(src) return -1;
    gv := get_underlying_object(src);
    if vkind(gv) != .GLOBAL_VAR || !glob(gv).is_const || !gv_has_definitive_initializer(gv) return -1;
    offset := vnc_analyze_load_from_clobbering_write(load_ty, load_ptr, strip_pointer_casts(call_arg(mi, 0)), mem_size_bits);
    if offset == -1 return offset;
    if cfo_load_from_const_ptr_off(src, load_ty, ap_from_u64(dl_index_type_size_bits(vtype(src)), cast(u64) offset)) != NONE return offset;
    return -1;
}

// getStoreValueForLoadHelper
vnc_store_value_for_load_helper :: (src_in: Value_Id, offset: u64, load_ty: Type_Id, b: *Irb) -> Value_Id {
    src := src_in;
    st := vtype(src);
    if type_kind(st) == .PTR && type_kind(load_ty) == .PTR && ir.types[st].a == ir.types[load_ty].a return src;
    if type_kind(load_ty) == .SVECTOR return src;
    if type_kind(st) == .SVECTOR && type_kind(load_ty) == .VECTOR return src;
    store_size := (dl_type_size_bits(st) + 7) / 8;
    load_size := (dl_type_size_bits(load_ty) + 7) / 8;
    if is_ptr_or_ptr_vector(vtype(src)) src = irb_cast(b, .PTRTOINT, src, dl_int_ptr_type(vtype(src)));
    if !is_int_type(vtype(src)) src = irb_bitcast(b, src, type_int(cast(u32) (store_size * 8)));
    shift: u64;
    if !dl.big_endian shift = offset * 8;
    else shift = (store_size - load_size - offset) * 8;
    if shift src = irb_binop(b, .LSHR, src, const_int(vtype(src), shift));
    if load_size != store_size src = irb_trunc_or_bitcast(b, src, type_int(cast(u32) (load_size * 8)));
    return src;
}

// getValueForLoad(SrcVal, Offset, LoadTy, InsertPt, F)
vnc_get_value_for_load :: (src: Value_Id, offset: u64, load_ty: Type_Id, insert_pt: Value_Id, f: Value_Id) -> Value_Id {
    b: Irb; irb_set_before(*b, insert_pt);
    v := vnc_store_value_for_load_helper(src, offset, load_ty, *b);
    return vnc_coerce_available_value_to_load_type(v, load_ty, *b, f);
}

// getMemInstValueForLoad(SrcInst, Offset, LoadTy, InsertPt, DL)
vnc_get_mem_inst_value_for_load :: (mi: Value_Id, offset: u64, load_ty: Type_Id, insert_pt: Value_Id) -> Value_Id {
    load_size := dl_type_size_bits(load_ty) / 8;
    b: Irb; irb_set_before(*b, insert_pt);
    if is_memset_intrinsic(mi) {
        val := call_arg(mi, 1);
        if load_size != 1 val = irb_zext_or_bitcast(*b, val, type_int(cast(u32) (load_size * 8)));
        one_elt := val;
        num_set: u64 = 1;
        while num_set != load_size {
            if num_set * 2 <= load_size {
                sh := irb_binop(*b, .SHL, val, const_int(vtype(val), num_set * 8));
                val = irb_binop(*b, .OR, val, sh);
                num_set <<= 1;
                continue;
            }
            sh := irb_binop(*b, .SHL, val, const_int(vtype(val), 8));
            val = irb_binop(*b, .OR, one_elt, sh);
            num_set += 1;
        }
        return vnc_coerce_available_value_to_load_type(val, load_ty, *b, inst_fn(insert_pt));
    }
    src := strip_pointer_casts(call_arg(mi, 1));
    return cfo_load_from_const_ptr_off(src, load_ty, ap_from_u64(dl_index_type_size_bits(vtype(src)), offset));
}
