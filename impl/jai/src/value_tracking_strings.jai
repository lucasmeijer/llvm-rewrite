// The string helpers of llvm/lib/Analysis/ValueTracking.cpp (getConstantDataArrayInfo, getConstantStringInfo,
// GetStringLength, isOnlyUsedInZeroEqualityComparison, isOnlyUsedInZeroComparison) and ReadByteArrayFromGlobal
// (llvm/lib/Analysis/ConstantFolding.cpp), used by the library call simplifier.

// ConstantDataArraySlice. `has_array` false = Slice.Array == nullptr (a zero initializer); otherwise `elts` are the
// elements of the ConstantDataArray (one u64 per element, zero-extended).
Const_Data_Slice :: struct {
    has_array: bool;
    elts: [] u64;
    offset: u64;
    length: u64;
}

// ReadByteArrayFromGlobal(GV, Offset): the bytes of the initializer from Offset on, as a ConstantDataArray of i8
// (null when all bytes are zero: ConstantDataArray::get gives a ConstantAggregateZero then). ok = false on failure.
read_byte_array_from_global :: (gv: Value_Id, offset: u64) -> (ok: bool, is_zero: bool, bytes: [] u8) {
    empty: [] u8;
    if !glob(gv).is_const || !gv_has_definitive_initializer(gv) return false, false, empty;
    init := gv_initializer(gv);
    init_size := dl_type_alloc_size(vtype(init));
    if init_size < offset return false, false, empty;
    nbytes := init_size - offset;
    if nbytes > 0xFFFF return false, false, empty;
    raw := NewArray(cast(s64) nbytes, u8,, allocator = temp);
    if !read_data_from_global(init, offset, raw, cast(u32) nbytes) return false, false, empty;
    all_zero := true;
    for raw if it != 0 { all_zero = false; break; }
    return true, all_zero, raw;
}

// getConstantDataArrayInfo(V, Slice, ElementSize, Offset)
get_constant_data_array_info :: (v: Value_Id, element_size: u32, offset_in: u64 = 0) -> (bool, Const_Data_Slice) {
    slice_out: Const_Data_Slice;
    esz_bytes := cast(u64) (element_size / 8);
    gv := get_underlying_object(v);
    if vkind(gv) != .GLOBAL_VAR || !glob(gv).is_const || !gv_has_definitive_initializer(gv) return false, slice_out;
    base, off := strip_and_accumulate_constant_offsets(v, ap_zero(dl_index_type_size_bits(vtype(v))), true);
    if base != gv return false, slice_out;
    start_idx: u64 = ifx ap_active_bits(off) > 64 then 0xFFFF_FFFF_FFFF_FFFF else ap_zext_value(off);
    if start_idx == 0xFFFF_FFFF_FFFF_FFFF return false, slice_out;
    if start_idx % esz_bytes != 0 return false, slice_out;
    offset := offset_in + start_idx / esz_bytes;
    init := gv_initializer(gv);
    if is_null_value(init) {
        size_in_bytes := dl_type_store_size(glob(gv).value_type);
        length := size_in_bytes / esz_bytes;
        slice_out.has_array = false;
        slice_out.offset = 0;
        slice_out.length = ifx length < offset then cast(u64) 0 else length - offset;
        return true, slice_out;
    }
    have := false;
    num_elts: u64;
    if vkind(init) == .C_DATA && type_kind(vtype(init)) == .ARRAY {
        et := type_elem(vtype(init));
        if type_kind(et) == .INT && type_int_width(et) == element_size {
            n := const_data_count(init);
            e := NewArray(cast(s64) n, u64,, allocator = temp);
            for i: 0..cast(s64) n - 1 e[i] = const_data_elt(init, cast(u64) i);
            slice_out.elts = e;
            slice_out.has_array = true;
            num_elts = n;
            have = true;
        }
    }
    if !have {
        if element_size != 8 return false, slice_out;
        ok, zero, bytes := read_byte_array_from_global(gv, offset);
        if !ok return false, slice_out;
        offset = 0;
        num_elts = cast(u64) bytes.count;
        if !zero {
            e := NewArray(bytes.count, u64,, allocator = temp);
            for bytes e[it_index] = it;
            slice_out.elts = e;
            slice_out.has_array = true;
        }
    }
    if offset > num_elts return false, slice_out;
    slice_out.offset = offset;
    slice_out.length = num_elts - offset;
    return true, slice_out;
}

// getConstantStringInfo(V, Str, TrimAtNul)
get_constant_string_info :: (v: Value_Id, trim_at_nul := true) -> (bool, string) {
    ok, s := get_constant_data_array_info(v, 8);
    if !ok return false, "";
    if !s.has_array {
        if trim_at_nul return true, "";
        if s.length == 1 { r := alloc_string(1,, allocator = temp); r[0] = 0; return true, r; }
        return false, "";
    }
    n := s.elts.count - cast(s64) s.offset;
    str := alloc_string(n,, allocator = temp);
    for i: 0..n-1 str[i] = cast(u8) s.elts[cast(s64) s.offset + i];
    if trim_at_nul {
        for i: 0..str.count-1 if str[i] == 0 { str.count = i; break; }
    }
    return true, str;
}

// GetStringLengthH
get_string_length_h :: (v_in: Value_Id, phis: *[..] Value_Id, char_size: u32) -> u64 {
    ALL :: 0xFFFF_FFFF_FFFF_FFFF;
    v := strip_pointer_casts(v_in);
    if is_phi(v) {
        for phis.* if it == v return ALL;
        array_add(phis, v);
        len_so_far: u64 = ALL;
        for k: 0..cast(s64) nops(v) - 1 {
            len := get_string_length_h(phi_value(v, cast(u32) k), phis, char_size);
            if len == 0 return 0;
            if len == ALL continue;
            if len != len_so_far && len_so_far != ALL return 0;
            len_so_far = len;
        }
        return len_so_far;
    }
    if is_inst(v) && inst_op(v) == .SELECT {
        len1 := get_string_length_h(op(v, 1), phis, char_size);
        if len1 == 0 return 0;
        len2 := get_string_length_h(op(v, 2), phis, char_size);
        if len2 == 0 return 0;
        if len1 == ALL return len2;
        if len2 == ALL return len1;
        if len1 != len2 return 0;
        return len1;
    }
    ok, s := get_constant_data_array_info(v, char_size);
    if !ok return 0;
    if !s.has_array return 1;
    null_index: u64 = 0;
    // `unsigned NullIndex` / `unsigned E = Slice.Length` in LLVM: lengths are truncated to 32 bits there too
    e := s.length & 0xFFFF_FFFF;
    while null_index < e {
        if s.elts[cast(s64)(s.offset + null_index)] == 0 break;
        null_index += 1;
    }
    return null_index + 1;
}

// GetStringLength(V, CharSize): len+1, or 0 when unknown
get_string_length :: (v: Value_Id, char_size: u32 = 8) -> u64 {
    if !is_ptr_type(vtype(v)) return 0;
    phis: [..] Value_Id; phis.allocator = temp;
    len := get_string_length_h(v, *phis, char_size);
    return ifx len == 0xFFFF_FFFF_FFFF_FFFF then cast(u64) 1 else len;
}

// isOnlyUsedInZeroEqualityComparison(I)
is_only_used_in_zero_equality_comparison :: (i: Value_Id) -> bool {
    if !has_uses(i) return false;
    u := ir.v_first_use[i];
    while u != NONE {
        usr := ir.u_user[u];
        if !is_inst(usr) || inst_op(usr) != .ICMP return false;
        if !icmp_is_equality(inst_pred(usr)) return false;
        if !pm_zero(op(usr, 1)) return false;
        u = ir.u_next[u];
    }
    return true;
}
// isOnlyUsedInZeroComparison(I)
is_only_used_in_zero_comparison :: (i: Value_Id) -> bool {
    if !has_uses(i) return false;
    u := ir.v_first_use[i];
    while u != NONE {
        usr := ir.u_user[u];
        if !is_inst(usr) || inst_op(usr) != .ICMP return false;
        if !pm_zero(op(usr, 1)) return false;
        u = ir.u_next[u];
    }
    return true;
}
