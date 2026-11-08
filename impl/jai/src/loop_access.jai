// LoopAccessAnalysis: llvm/lib/Analysis/LoopAccessAnalysis.cpp. So far the free functions other passes use:
// getPointersDiff and isConsecutiveAccess (LoopIdiomRecognize, SLP).

// getLoadStoreType
load_store_type :: (i: Value_Id) -> Type_Id {
    if inst_op(i) == .LOAD return vtype(i);
    return vtype(op(i, 0));
}

// getPointersDiff(ElemTyA, PtrA, ElemTyB, PtrB, DL, SE, StrictCheck, CheckType)
get_pointers_diff :: (elem_a: Type_Id, ptr_a: Value_Id, elem_b: Type_Id, ptr_b: Value_Id, strict_check := false, check_type := true) -> (bool, s64) {
    if ptr_a == ptr_b return true, 0;
    if check_type && elem_a != elem_b return false, 0;
    asa := ptr_addrspace(vtype(ptr_a));
    asb := ptr_addrspace(vtype(ptr_b));
    if asa != asb return false, 0;
    idx_w := dl_index_size_bits(asa);
    off_a := ap_zero(idx_w); off_b := ap_zero(idx_w);
    a1, b1: Value_Id;
    a1, off_a = strip_and_accumulate_constant_offsets(ptr_a, off_a, true);
    b1, off_b = strip_and_accumulate_constant_offsets(ptr_b, off_b, true);
    val: s64;
    if a1 == b1 {
        asa = ptr_addrspace(vtype(a1));
        asb = ptr_addrspace(vtype(b1));
        if asa != asb return false, 0;
        idx_w = dl_index_size_bits(asa);
        off_a = ap_sext_or_trunc(off_a, idx_w);
        off_b = ap_sext_or_trunc(off_b, idx_w);
        off_b = ap_sub(off_b, off_a);
        if ap_min_signed_bits(off_b) > 64 return false, 0;   // trySExtValue
        val = ap_sext_value(off_b);
    } else {
        ok, diff := sc_compute_constant_difference(sc_get_scev(ptr_b), sc_get_scev(ptr_a));
        if !ok return false, 0;
        if ap_min_signed_bits(diff) > 64 return false, 0;
        val = ap_sext_value(diff);
    }
    size := cast(s64) dl_type_store_size(elem_a);
    dist := val / size;
    if !strict_check || dist * size == val return true, dist;
    return false, 0;
}

// isConsecutiveAccess(A, B, DL, SE, CheckType)
is_consecutive_access :: (a: Value_Id, b: Value_Id, check_type := true) -> bool {
    pa := load_store_pointer_operand(a);
    pb := load_store_pointer_operand(b);
    if pa == NONE || pb == NONE return false;
    ok, d := get_pointers_diff(load_store_type(a), pa, load_store_type(b), pb, true, check_type);
    return ok && d == 1;
}
