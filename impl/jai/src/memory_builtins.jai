// MemoryBuiltins: a port of llvm/lib/Analysis/MemoryBuiltins.cpp — the allocation-function tables
// (AllocationFnData / FreeFnData with their families), getAllocationData, getAllocationFamily, getReallocatedOperand,
// getInitialValueOfAllocation, getAllocAlignment, getAllocSize with a Mapper, getObjectSize (ObjectSizeOffsetVisitor
// in all four evaluation modes, incl. load tracking through AA) and lowerObjectSizeCall.
// The older entry points (is_alloc_like_fn, get_freed_operand in inst_props.jai, get_alloc_size and
// get_base_object_size in basic_aa.jai) use the tables here.
// ObjectSizeOffsetEvaluator (llvm.objectsize with `dynamic` = true) builds its code with a plain IRBuilder (no
// worklist); the instructions it inserted are found by value id (everything it creates is new).
// Also ValueTracking's getConstantDataArrayInfo / GetStringLength (strdup-like sizes).

AT_OPNEW :: 1; AT_MALLOC :: 2; AT_STRDUP :: 4;
AT_MALLOC_OR_OPNEW :: AT_MALLOC | AT_OPNEW;
AT_ALLOC_LIKE :: AT_MALLOC_OR_OPNEW | AT_STRDUP;
AT_ANY :: AT_ALLOC_LIKE;

// MallocFamily -> mangledNameForMallocFamily
MF_MALLOC :: "malloc"; MF_NEW :: "_Znwm"; MF_NEW_ALIGNED :: "_ZnwmSt11align_val_t"; MF_NEW_ARRAY :: "_Znam";
MF_NEW_ARRAY_ALIGNED :: "_ZnamSt11align_val_t"; MF_MSVC_NEW :: "??2@YAPAXI@Z"; MF_MSVC_ARRAY_NEW :: "??_U@YAPAXI@Z";

Alloc_Fn :: struct { name: string; ty: u8; nparams: s32; fst: s32; snd: s32; align: s32; family: string; }
// AllocationFnData (the MSVC entries are unavailable in TLI on x86_64-linux; available on windows triples)
ALLOC_FNS :: Alloc_Fn.[
    .{"??2@YAPAXI@Z", AT_OPNEW, 1, 0, -1, -1, MF_MSVC_NEW}, .{"??2@YAPAXIABUnothrow_t@std@@@Z", AT_MALLOC, 2, 0, -1, -1, MF_MSVC_NEW},
    .{"??2@YAPEAX_K@Z", AT_OPNEW, 1, 0, -1, -1, MF_MSVC_NEW}, .{"??2@YAPEAX_KAEBUnothrow_t@std@@@Z", AT_MALLOC, 2, 0, -1, -1, MF_MSVC_NEW},
    .{"??_U@YAPAXI@Z", AT_OPNEW, 1, 0, -1, -1, MF_MSVC_ARRAY_NEW}, .{"??_U@YAPAXIABUnothrow_t@std@@@Z", AT_MALLOC, 2, 0, -1, -1, MF_MSVC_ARRAY_NEW},
    .{"??_U@YAPEAX_K@Z", AT_OPNEW, 1, 0, -1, -1, MF_MSVC_ARRAY_NEW}, .{"??_U@YAPEAX_KAEBUnothrow_t@std@@@Z", AT_MALLOC, 2, 0, -1, -1, MF_MSVC_ARRAY_NEW},
    .{"_Znwj", AT_OPNEW, 1, 0, -1, -1, MF_NEW}, .{"_ZnwjRKSt9nothrow_t", AT_MALLOC, 2, 0, -1, -1, MF_NEW},
    .{"_ZnwjSt11align_val_t", AT_OPNEW, 2, 0, -1, 1, MF_NEW_ALIGNED},
    .{"_ZnwjSt11align_val_tRKSt9nothrow_t", AT_MALLOC, 3, 0, -1, 1, MF_NEW_ALIGNED},
    .{"_Znwm", AT_OPNEW, 1, 0, -1, -1, MF_NEW}, .{"_Znwm12__hot_cold_t", AT_OPNEW, 2, 0, -1, -1, MF_NEW},
    .{"_ZnwmRKSt9nothrow_t", AT_MALLOC, 2, 0, -1, -1, MF_NEW},
    .{"_ZnwmRKSt9nothrow_t12__hot_cold_t", AT_MALLOC, 3, 0, -1, -1, MF_NEW},
    .{"_ZnwmSt11align_val_t", AT_OPNEW, 2, 0, -1, 1, MF_NEW_ALIGNED},
    .{"_ZnwmSt11align_val_t12__hot_cold_t", AT_OPNEW, 3, 0, -1, 1, MF_NEW_ALIGNED},
    .{"_ZnwmSt11align_val_tRKSt9nothrow_t", AT_MALLOC, 3, 0, -1, 1, MF_NEW_ALIGNED},
    .{"_ZnwmSt11align_val_tRKSt9nothrow_t12__hot_cold_t", AT_MALLOC, 4, 0, -1, 1, MF_NEW_ALIGNED},
    .{"_Znaj", AT_OPNEW, 1, 0, -1, -1, MF_NEW_ARRAY}, .{"_ZnajRKSt9nothrow_t", AT_MALLOC, 2, 0, -1, -1, MF_NEW_ARRAY},
    .{"_ZnajSt11align_val_t", AT_OPNEW, 2, 0, -1, 1, MF_NEW_ARRAY_ALIGNED},
    .{"_ZnajSt11align_val_tRKSt9nothrow_t", AT_MALLOC, 3, 0, -1, 1, MF_NEW_ARRAY_ALIGNED},
    .{"_Znam", AT_OPNEW, 1, 0, -1, -1, MF_NEW_ARRAY}, .{"_Znam12__hot_cold_t", AT_OPNEW, 2, 0, -1, -1, MF_NEW},
    .{"_ZnamRKSt9nothrow_t", AT_MALLOC, 2, 0, -1, -1, MF_NEW_ARRAY},
    .{"_ZnamRKSt9nothrow_t12__hot_cold_t", AT_MALLOC, 3, 0, -1, -1, MF_NEW},
    .{"_ZnamSt11align_val_t", AT_OPNEW, 2, 0, -1, 1, MF_NEW_ARRAY_ALIGNED},
    .{"_ZnamSt11align_val_t12__hot_cold_t", AT_OPNEW, 3, 0, -1, 1, MF_NEW_ALIGNED},
    .{"_ZnamSt11align_val_tRKSt9nothrow_t", AT_MALLOC, 3, 0, -1, 1, MF_NEW_ARRAY_ALIGNED},
    .{"_ZnamSt11align_val_tRKSt9nothrow_t12__hot_cold_t", AT_MALLOC, 4, 0, -1, 1, MF_NEW_ALIGNED},
    .{"strdup", AT_STRDUP, 1, -1, -1, -1, MF_MALLOC}, .{"__strdup", AT_STRDUP, 1, -1, -1, -1, MF_MALLOC},
    .{"strndup", AT_STRDUP, 2, 1, -1, -1, MF_MALLOC}, .{"__strndup", AT_STRDUP, 2, 1, -1, -1, MF_MALLOC},
];
Free_Fn :: struct { name: string; nparams: s32; family: string; }
// FreeFnData
FREE_FNS :: Free_Fn.[
    .{"??3@YAXPAX@Z", 1, MF_MSVC_NEW}, .{"??3@YAXPEAX@Z", 1, MF_MSVC_NEW},
    .{"??_V@YAXPAX@Z", 1, MF_MSVC_ARRAY_NEW}, .{"??_V@YAXPEAX@Z", 1, MF_MSVC_ARRAY_NEW},
    .{"??3@YAXPAXI@Z", 2, MF_MSVC_NEW}, .{"??3@YAXPEAX_K@Z", 2, MF_MSVC_NEW},
    .{"??3@YAXPAXABUnothrow_t@std@@@Z", 2, MF_MSVC_NEW}, .{"??3@YAXPEAXAEBUnothrow_t@std@@@Z", 2, MF_MSVC_NEW},
    .{"??_V@YAXPAXI@Z", 2, MF_MSVC_ARRAY_NEW}, .{"??_V@YAXPEAX_K@Z", 2, MF_MSVC_ARRAY_NEW},
    .{"??_V@YAXPAXABUnothrow_t@std@@@Z", 2, MF_MSVC_ARRAY_NEW}, .{"??_V@YAXPEAXAEBUnothrow_t@std@@@Z", 2, MF_MSVC_ARRAY_NEW},
    .{"_ZdlPv", 1, MF_NEW}, .{"_ZdaPv", 1, MF_NEW_ARRAY}, .{"_ZdlPvj", 2, MF_NEW}, .{"_ZdlPvm", 2, MF_NEW},
    .{"_ZdlPvRKSt9nothrow_t", 2, MF_NEW}, .{"_ZdlPvSt11align_val_t", 2, MF_NEW_ALIGNED},
    .{"_ZdaPvj", 2, MF_NEW_ARRAY}, .{"_ZdaPvm", 2, MF_NEW_ARRAY}, .{"_ZdaPvRKSt9nothrow_t", 2, MF_NEW_ARRAY},
    .{"_ZdaPvSt11align_val_t", 2, MF_NEW_ARRAY_ALIGNED}, .{"_ZdlPvSt11align_val_tRKSt9nothrow_t", 3, MF_NEW_ALIGNED},
    .{"_ZdaPvSt11align_val_tRKSt9nothrow_t", 3, MF_NEW_ARRAY_ALIGNED}, .{"_ZdlPvjSt11align_val_t", 3, MF_NEW_ALIGNED},
    .{"_ZdlPvmSt11align_val_t", 3, MF_NEW_ALIGNED}, .{"_ZdaPvjSt11align_val_t", 3, MF_NEW_ARRAY_ALIGNED},
    .{"_ZdaPvmSt11align_val_t", 3, MF_NEW_ARRAY_ALIGNED},
];

// TLI->getLibFunc(F) && TLI->has(F) for the functions of the tables above (their TLI prototypes are the checks
// getAllocationDataForFunction / isLibFreeFunction make, which are at least as strict here) and for `free`.
// the name TLI's getLibFunc looks up (sanitizeFunctionName: the \01 mangling escape dropped)
lib_func_name :: (callee: Value_Id) -> string {
    n := vname(callee);
    if n.count && n[0] == 1 return slice(n, 1, n.count - 1);
    return n;
}
mb_tli_knows :: (callee: Value_Id, caller: Value_Id) -> bool {
    ok, lf := tli_lookup_fn(callee);
    return ok && tli_func_has(tli_for(caller), lf);
}

// getAllocationDataForFunction(Callee, AllocTy, TLI)
mb_alloc_data_for_function :: (callee: Value_Id, caller: Value_Id, alloc_ty: u8) -> (bool, Alloc_Fn) {
    ft := glob(callee).value_type;
    if !is_ptr_type(func_ret(ft)) return false, .{};
    if !mb_tli_knows(callee, caller) return false, .{};
    for ALLOC_FNS {
        if it.name != lib_func_name(callee) continue;
        if (it.ty & alloc_ty) != it.ty return false, .{};
        if func_nparams(ft) != cast(u32) it.nparams return false, .{};
        if it.fst >= 0 && !is_int32_or_64(func_param(ft, cast(u32) it.fst)) return false, .{};
        if it.snd >= 0 && !is_int32_or_64(func_param(ft, cast(u32) it.snd)) return false, .{};
        return true, it;
    }
    return false, .{};
}
// getAllocationData(V, AllocTy, TLI)
mb_alloc_data :: (v: Value_Id, alloc_ty: u8) -> (bool, Alloc_Fn) {
    if !is_inst(v) || !is_call_base(v) return false, .{};
    callee := mb_called_function(v);
    if callee == NONE return false, .{};
    ok, d := mb_alloc_data_for_function(callee, value_function(v), alloc_ty);
    return ok, d;
}
// getAllocationSize(CB, TLI): the table entry, else the allocsize attribute (as MallocLike)
mb_allocation_size_data :: (cb: Value_Id) -> (bool, Alloc_Fn) {
    callee := mb_called_function(cb);
    if callee != NONE {
        ok, d := mb_alloc_data_for_function(callee, value_function(cb), AT_ANY);
        if ok return true, d;
    }
    a := call_get_fn_attr(cb, .AllocSize);
    if !a return false, .{};
    r: Alloc_Fn;
    r.ty = AT_MALLOC;
    r.nparams = cast(s32) call_num_args(cb);
    // allocsize(ElemSizeArg[, NumElemsArg]): packed as (first << 32) | (second or 0xFFFFFFFF)
    r.fst = cast(s32)(a.ival >> 32);
    s := a.ival & 0xFFFF_FFFF;
    r.snd = ifx s == 0xFFFF_FFFF then -1 else cast(s32) s;
    r.align = -1;
    return true, r;
}

// isAllocationFn
is_allocation_fn :: (v: Value_Id) -> bool {
    ok := mb_alloc_data(v, AT_ANY);
    if ok return true;
    return is_inst(v) && is_call_base(v) && (call_alloc_kind(v) & (AFK_ALLOC | AFK_REALLOC)) != 0;
}
// getReallocatedOperand
get_reallocated_operand :: (cb: Value_Id) -> Value_Id {
    if !is_inst(cb) || !is_call_base(cb) return NONE;
    if (call_alloc_kind(cb) & AFK_REALLOC) == 0 return NONE;
    return call_arg_with_attribute(cb, .AllocatedPointer);
}
// CallBase::getArgOperandWithAttribute
call_arg_with_attribute :: (cb: Value_Id, k: Attr_Kind) -> Value_Id {
    n := call_num_args(cb);
    if n > 0 for i: 0..n-1 if call_param_attr(cb, i, k) != null return call_arg(cb, i);
    return NONE;
}
// getAllocAlignment
get_alloc_alignment :: (cb: Value_Id) -> Value_Id {
    ok, d := mb_alloc_data(cb, AT_ANY);
    if ok && d.align >= 0 return op(cb, cast(u32) d.align);
    return call_arg_with_attribute(cb, .AllocAlign);
}

AFK_UNINITIALIZED :: 8; AFK_ZEROED :: 16;
// getInitialValueOfAllocation(V, TLI, Ty)
get_initial_value_of_allocation :: (v: Value_Id, ty: Type_Id) -> Value_Id {
    if is_inst(v) && inst_op(v) == .ALLOCA return const_undef(ty);
    if !is_inst(v) || !is_call_base(v) return NONE;
    ok := mb_alloc_data(v, AT_MALLOC_OR_OPNEW);
    if ok return const_undef(ty);
    ak := call_alloc_kind(v);
    if ak & AFK_UNINITIALIZED return const_undef(ty);
    if ak & AFK_ZEROED return const_null_value(ty);
    return NONE;
}

// getAllocationFamily(I, TLI): "" = none
get_allocation_family :: (i: Value_Id) -> string {
    callee := mb_called_function(i);
    if callee != NONE && mb_tli_knows(callee, value_function(i)) {
        ok, d := mb_alloc_data_for_function(callee, value_function(i), AT_ANY);
        if ok return d.family;
        for FREE_FNS if it.name == lib_func_name(callee) return it.family;
    }
    if is_inst(i) && is_call_base(i) && (call_alloc_kind(i) & (AFK_FREE | AFK_ALLOC | AFK_REALLOC)) != 0 {
        s := call_fn_str_attr(i, "alloc-family");
        if s.count return s;
    }
    return "";
}
// CallBase::getFnAttr("key") value ("" when absent)
call_fn_str_attr :: (i: Value_Id, key: string) -> string {
    for attr_set_items(call_fn_attrs(i)) if it.kind == .STRING_ATTR && it.key == key return it.val;
    f := call_called_operand_fn(i);
    if f != NONE for attr_set_items(attr_list_fn(glob(f).attrs)) if it.kind == .STRING_ATTR && it.key == key return it.val;
    return "";
}

// checkedZextOrTrunc
mb_checked_zext_or_trunc :: (x: *APInt, bits: u32) -> bool {
    if x.bits > bits && ap_active_bits(x.*) > bits return false;
    if x.bits != bits x.* = ap_zext_or_trunc(x.*, bits);
    return true;
}

// getAllocSize(CB, TLI, Mapper): the Mapper is ObjectSizeOffsetVisitor's (aggregatePossibleConstantValues in
// `mode`), or the identity when `use_mapper` is false
mb_get_alloc_size :: (cb: Value_Id, use_mapper := false, mode := Os_Mode.EXACT_SIZE_FROM_OFFSET) -> (bool, APInt) {
    ok, d := mb_allocation_size_data(cb);
    if !ok return false, .{};
    bits := dl_index_type_size_bits(vtype(cb));
    mapped :: (v: Value_Id, use_mapper: bool, mode: Os_Mode) -> (bool, APInt) {
        if is_scalar_const_int(v) return true, const_ap(v);
        if !use_mapper || !is_int_type(vtype(v)) return false, .{};
        okp, p := os_aggregate_possible_constant_values(v, mode, scalar_bits(v));
        return okp, p;
    }
    if d.ty == AT_STRDUP {
        // Mapper(CB->getArgOperand(0)) is the identity for pointers
        size := ap_from_u64(bits, get_string_length(call_arg(cb, 0)));
        if ap_is_zero(size) return false, .{};
        if d.fst > 0 {
            arg := call_arg(cb, cast(u32) d.fst);
            oka, a := mapped(arg, use_mapper, mode);
            if !oka || !is_int_type(vtype(arg)) return false, .{};
            max_size := ap_zext(a, bits);
            if ap_ugt(size, max_size) size = ap_add(max_size, ap_one(bits));
        }
        return true, size;
    }
    oka, size := mapped(call_arg(cb, cast(u32) d.fst), use_mapper, mode);
    if !oka return false, .{};
    if !mb_checked_zext_or_trunc(*size, bits) return false, .{};
    if d.snd < 0 return true, size;
    okb, ne := mapped(call_arg(cb, cast(u32) d.snd), use_mapper, mode);
    if !okb return false, .{};
    if !mb_checked_zext_or_trunc(*ne, bits) return false, .{};
    r, ov := ap_umul_ov(size, ne);
    if ov return false, .{};
    return true, r;
}

// ---------------------------------------------------------------- ObjectSizeOffsetVisitor

Os_Mode :: enum u8 { EXACT_SIZE_FROM_OFFSET; EXACT_UNDERLYING_SIZE_AND_OFFSET; MIN; MAX; }
Os_Opts :: struct {
    mode: Os_Mode;
    round_to_align: bool;
    null_is_unknown_size: bool;
    aar: *Aa_Results;   // Options.AA (null = none)
}
// OffsetSpan: Before/After; an APInt of width <= 1 is "unknown" (APInt())
Offset_Span :: struct { before: APInt; after: APInt; }
os_known_before :: (s: Offset_Span) -> bool { return s.before.bits > 1; }
os_known_after :: (s: Offset_Span) -> bool { return s.after.bits > 1; }
os_both_known :: (s: Offset_Span) -> bool { return os_known_before(s) && os_known_after(s); }
os_unknown :: () -> Offset_Span { return .{}; }
os_span_eq :: (a: Offset_Span, b: Offset_Span) -> bool {
    eqa :: (x: APInt, y: APInt) -> bool { if x.bits != y.bits return false; if x.bits <= 1 return x.bits == y.bits && (x.bits == 0 || ap_eq(x, y)); return ap_eq(x, y); }
    return eqa(a.before, b.before) && eqa(a.after, b.after);
}

Os_Visitor :: struct {
    opts: Os_Opts;
    int_ty_bits: u32;
    zero: APInt;
    seen: Table(Value_Id, Offset_Span);
    visited_count: u32;
}
OS_MAX_VISIT_INSTRUCTIONS :: 100;   // -object-size-offset-visitor-max-visit-instructions

// combinePossibleConstantValues / aggregatePossibleConstantValuesImpl / aggregatePossibleConstantValues
os_aggregate_impl :: (v: Value_Id, mode: Os_Mode, bw: u32, depth: u32) -> (bool, APInt) {
    if depth == 4 return false, .{};
    combine :: (oka: bool, a: APInt, okb: bool, b: APInt, mode: Os_Mode) -> (bool, APInt) {
        if !oka || !okb return false, .{};
        if mode == .MAX return true, ifx ap_sge(a, b) then a else b;
        return true, ifx ap_sle(a, b) then a else b;
    }
    if vkind(v) == .C_INT && !is_vector_type(vtype(v)) return true, ap_sext_or_trunc(const_ap(v), bw);
    if is_inst(v) && inst_op(v) == .SELECT {
        oka, a := os_aggregate_impl(op(v, 1), mode, bw, depth + 1);
        okb, b := os_aggregate_impl(op(v, 2), mode, bw, depth + 1);
        ok, r := combine(oka, a, okb, b, mode);
        return ok, r;
    }
    if is_phi(v) {
        n := nops(v);
        if n == 0 return false, .{};
        ok, acc := os_aggregate_impl(op(v, 0), mode, bw, depth + 1);
        k: u32 = 1;
        while ok && k < n {
            okt, t := os_aggregate_impl(op(v, k), mode, bw, depth + 1);
            ok, acc = combine(ok, acc, okt, t, mode);
            k += 1;
        }
        return ok, acc;
    }
    return false, .{};
}
os_aggregate_possible_constant_values :: (v: Value_Id, mode: Os_Mode, bw: u32) -> (bool, APInt) {
    if vkind(v) == .C_INT && !is_vector_type(vtype(v)) return true, ap_sext_or_trunc(const_ap(v), bw);
    if mode != .MIN && mode != .MAX return false, .{};
    ok, r := os_aggregate_impl(v, mode, bw, 0);
    return ok, r;
}

// ObjectSizeOffsetVisitor::align
os_align :: (vis: *Os_Visitor, size_in: APInt, align: u64) -> APInt {
    size := size_in;
    if vis.opts.round_to_align && align != 0 size = ap_from_u64(vis.int_ty_bits, align_to(ap_zext_value(size), align));
    if ap_is_negative(size) return .{};
    return size;
}

// Value::stripAndAccumulateConstantOffsets(DL, Offset, AllowNonInbounds = true, AllowInvariantGroup = true,
// ExternalAnalysis = aggregatePossibleConstantValues in `ext_mode`)
os_strip_with_external :: (v_in: Value_Id, offset_in: APInt, ext_mode: Os_Mode) -> (Value_Id, APInt) {
    v := v_in; offset := offset_in;
    if !is_ptr_type(scalar_type(vtype(v))) return v, offset;
    bw := offset.bits;
    visited: [..] Value_Id; visited.allocator = temp;
    array_add(*visited, v);
    while true {
        o := opr_code(v);
        if o == .GEP {
            ok, go := os_gep_accumulate_external(v, ap_zero(dl_index_bits(vtype(v))), ext_mode);
            if !ok return v, offset;
            if ap_min_signed_bits(go) > bw return v, offset;
            gst := ap_sext_or_trunc(go, bw);
            noff, ov := ap_sadd_ov(offset, gst);
            if ov return v, offset;
            offset = noff;
            v = op(v, 0);
        } else if o == .BITCAST {
            s := op(v, 0);
            if !is_ptr_type(scalar_type(vtype(s))) return v, offset;
            v = s;
        } else if o == .ADDRSPACECAST {
            v = op(v, 0);
        } else if vkind(v) == .ALIAS {
            if !gv_is_interposable(v) v = op(v, 0);
        } else if is_inst(v) && is_call_base(v) {
            rv := call_returned_arg(v);
            if rv != NONE v = rv;
            id := call_iid(v);
            if id == IID_LAUNDER_INVARIANT_GROUP || id == IID_STRIP_INVARIANT_GROUP v = op(v, 0);
        } else return v, offset;
        for visited if it == v return v, offset;
        array_add(*visited, v);
    }
    return v, offset;
}
// GEPOperator::accumulateConstantOffset with an ExternalAnalysis
os_gep_accumulate_external :: (g: Value_Id, offset_in: APInt, ext_mode: Os_Mode) -> (bool, APInt) {
    offset := offset_in;
    used_external := false;
    accumulate :: (offset: *APInt, index_in: APInt, size: u64, used_external: bool) -> bool {
        index := ap_sext_or_trunc(index_in, offset.bits);
        isz := ap_from_u64(offset.bits, size);
        if !used_external { offset.* = ap_add(offset.*, ap_mul(index, isz)); return true; }
        plus, ov := ap_smul_ov(index, isz);
        if ov return false;
        noff, ov2 := ap_sadd_ov(offset.*, plus);
        if ov2 return false;
        offset.* = noff;
        return true;
    }
    cur := opr_gep_source_type(g);
    n := nops(g);
    for k: 1..cast(s64) n - 1 {
        index := op(g, cast(u32) k);
        is_struct := k > 1 && type_kind(cur) == .STRUCT;
        indexed := gep_indexed_type(cur, k, index);
        defer cur = indexed;
        scalable := type_is_scalable(indexed);
        if is_scalar_const_int(index) {
            ci := const_ap(index);
            if ap_is_zero(ci) continue;
            if scalable return false, offset;
            if is_struct {
                if !accumulate(*offset, ap_from_u64(offset.bits, dl_struct_offset(cur, cast(u32) ap_zext_value(ci))), 1, used_external) return false, offset;
                continue;
            }
            if !accumulate(*offset, ci, gep_seq_stride(cur, k, indexed), used_external) return false, offset;
            continue;
        }
        if is_struct || scalable return false, offset;
        ok, ai := os_aggregate_possible_constant_values(index, ext_mode, offset.bits);
        if !ok return false, offset;
        used_external = true;
        if !accumulate(*offset, ai, gep_seq_stride(cur, k, indexed), used_external) return false, offset;
    }
    return true, offset;
}

// ObjectSizeOffsetVisitor::compute
os_compute :: (opts: Os_Opts, v: Value_Id) -> (bool, size: APInt, offset: APInt) {
    vis: Os_Visitor;
    vis.opts = opts;
    vis.seen.allocator = temp;
    span := os_compute_impl(*vis, v);
    if os_known_after(span) && !os_known_before(span) && opts.mode == .EXACT_SIZE_FROM_OFFSET
        span.before = ap_zero(span.after.bits);
    if !os_both_known(span) return false, .{}, .{};
    return true, ap_add(span.before, span.after), span.before;
}

os_compute_impl :: (vis: *Os_Visitor, v_in: Value_Id) -> Offset_Span {
    initial_bits := dl_index_type_size_bits(vtype(v_in));
    offset := ap_zero(initial_bits);
    v: Value_Id;
    v, offset = strip_and_accumulate_constant_offsets(v_in, offset, true, true);
    if (vis.opts.mode == .MIN || vis.opts.mode == .MAX) && opr_code(v) == .GEP {
        ext_mode: Os_Mode = ifx vis.opts.mode == .MIN then Os_Mode.MAX else .MIN;
        v, offset = os_strip_with_external(v, offset, ext_mode);
    }
    vis.int_ty_bits = dl_index_type_size_bits(vtype(v));
    vis.zero = ap_zero(vis.int_ty_bits);
    ort := os_compute_value(vis, v);
    changed := initial_bits != vis.int_ty_bits;
    if !changed && ap_is_zero(offset) return ort;
    if changed {
        if os_known_before(ort) && !mb_checked_zext_or_trunc(*ort.before, initial_bits) ort.before = .{};
        if os_known_after(ort) && !mb_checked_zext_or_trunc(*ort.after, initial_bits) ort.after = .{};
    }
    if os_known_before(ort) {
        r, ov := ap_sadd_ov(ort.before, offset);
        ort.before = ifx ov then APInt.{} else r;
    }
    if os_known_after(ort) {
        r, ov := ap_ssub_ov(ort.after, offset);
        ort.after = ifx ov then APInt.{} else r;
    }
    if os_known_before(ort) && ap_is_negative(ort.before) {
        if vis.opts.mode == .MIN || vis.opts.mode == .MAX return os_unknown();
    }
    return ort;
}

os_compute_value :: (vis: *Os_Visitor, v: Value_Id) -> Offset_Span {
    if is_inst(v) {
        found, cached := table_find(*vis.seen, v);
        if found return cached;
        table_set(*vis.seen, v, os_unknown());
        vis.visited_count += 1;
        if vis.visited_count > OS_MAX_VISIT_INSTRUCTIONS return os_unknown();
        res := os_visit_inst(vis, v);
        table_set(*vis.seen, v, res);
        return res;
    }
    k := vkind(v);
    if k == .ARGUMENT {
        mt := arg_pointee_in_memory_value_type(v);
        if mt == NONE || !type_is_sized(mt) return os_unknown();
        pa := attr_set_find(arg_attrs(v), .Alignment);
        return .{vis.zero, os_align(vis, ap_from_u64(vis.int_ty_bits, dl_type_alloc_size(mt)), ifx pa then pa.ival else 0)};
    }
    if k == .C_NULL {
        if vis.opts.null_is_unknown_size || ir.types[vtype(v)].a != 0 return os_unknown();
        return .{vis.zero, vis.zero};
    }
    if k == .ALIAS {
        if gv_is_interposable(v) return os_unknown();
        return os_compute_impl(vis, op(v, 0));
    }
    if k == .GLOBAL_VAR {
        g := glob(v);
        if !type_is_sized(g.value_type) || g.linkage == .EXTERN_WEAK ||
           ((!g.has_init || gv_is_interposable(v)) && vis.opts.mode != .MIN) return os_unknown();
        return .{vis.zero, os_align(vis, ap_from_u64(vis.int_ty_bits, dl_type_alloc_size(g.value_type)), g.align)};
    }
    if k == .C_UNDEF || k == .C_POISON return .{vis.zero, vis.zero};
    return os_unknown();
}

// combineOffsetRange
os_combine :: (vis: *Os_Visitor, l: Offset_Span, r: Offset_Span) -> Offset_Span {
    if !os_both_known(l) || !os_both_known(r) return os_unknown();
    if vis.opts.mode == {
        case .MIN; return .{ifx ap_slt(l.before, r.before) then l.before else r.before, ifx ap_slt(l.after, r.after) then l.after else r.after};
        case .MAX; return .{ifx ap_sgt(l.before, r.before) then l.before else r.before, ifx ap_sgt(l.after, r.after) then l.after else r.after};
        case .EXACT_SIZE_FROM_OFFSET;
            return .{ifx ap_eq(l.before, r.before) then l.before else APInt.{}, ifx ap_eq(l.after, r.after) then l.after else APInt.{}};
    }
    if os_span_eq(l, r) return l;
    return os_unknown();
}

os_visit_inst :: (vis: *Os_Visitor, i: Value_Id) -> Offset_Span {
    o := inst_op(i);
    if o == .ALLOCA {
        et := inst(i).ty2;
        esz := dl_type_alloc_size(et);
        if type_is_scalable(et) && vis.opts.mode != .MIN return os_unknown();
        if vis.int_ty_bits < 64 && (esz >> vis.int_ty_bits) != 0 return os_unknown();
        size := ap_from_u64(vis.int_ty_bits, esz);
        n := op(i, 0);
        if is_scalar_const_int(n) && ap_is_one(const_ap(n)) return .{vis.zero, os_align(vis, size, inst(i).align)};   // !isArrayAllocation
        ok, ne := os_aggregate_possible_constant_values(n, vis.opts.mode, scalar_bits(n));
        if !ok return os_unknown();
        if !mb_checked_zext_or_trunc(*ne, vis.int_ty_bits) return os_unknown();
        r, ov := ap_umul_ov(size, ne);
        if ov return os_unknown();
        return .{vis.zero, os_align(vis, r, inst(i).align)};
    }
    if is_call_base(i) {
        ok, size := mb_get_alloc_size(i, true, vis.opts.mode);
        if ok {
            if ap_is_negative(size) return os_unknown();
            return .{vis.zero, size};
        }
        return os_unknown();
    }
    if o == .LOAD {
        if vis.opts.aar == null return os_unknown();
        visited: Table(Value_Id, Offset_Span); visited.allocator = temp;
        scanned: u32 = 0;
        return os_find_load_offset_range(vis, i, inst_block(i), i, *visited, *scanned);
    }
    if o == .PHI {
        n := nops(i);
        if n == 0 return os_unknown();
        acc := os_compute_impl(vis, op(i, 0));
        for k: 1..cast(s64) n - 1 acc = os_combine(vis, acc, os_compute_impl(vis, op(i, cast(u32) k)));
        return acc;
    }
    if o == .SELECT return os_combine(vis, os_compute_impl(vis, op(i, 1)), os_compute_impl(vis, op(i, 2)));
    // extractelement, extractvalue, inttoptr, everything else: unknown
    return os_unknown();
}

// findLoadOffsetRange
os_find_load_offset_range :: (vis: *Os_Visitor, load: Value_Id, bb: Value_Id, from_in: Value_Id,
                              visited: *Table(Value_Id, Offset_Span), scanned: *u32) -> Offset_Span {
    MAX_INSTS_TO_SCAN :: 128;
    found, w := table_find(visited, bb);
    if found return w;
    unknown :: (visited: *Table(Value_Id, Offset_Span), bb: Value_Id) -> Offset_Span { table_set(visited, bb, os_unknown()); return os_unknown(); }
    known :: (visited: *Table(Value_Id, Offset_Span), bb: Value_Id, s: Offset_Span) -> Offset_Span { table_set(visited, bb, s); return s; }
    i := from_in;
    while i != NONE {
        defer i = inst(i).prev;
        if is_debug_or_pseudo_inst(i) continue;
        scanned.* += 1;
        if scanned.* > MAX_INSTS_TO_SCAN return unknown(visited, bb);
        if !may_write_to_memory(i) continue;
        if inst_op(i) == .STORE {
            ar := aa_alias(aa_query_new(vis.opts.aar), mloc_before_or_after(op(i, 1)), mloc_before_or_after(op(load, 0)));
            if ar.kind == AR_NO continue;
            if ar.kind == AR_MUST {
                if is_ptr_type(vtype(op(i, 0))) return known(visited, bb, os_compute_impl(vis, op(i, 0)));
                return unknown(visited, bb);
            }
            return unknown(visited, bb);
        }
        if is_call_base(i) {
            callee := call_called_function(i);
            if callee == NONE return unknown(visited, bb);
            if !mb_tli_knows(callee, value_function(i)) || vname(callee) != "posix_memalign" || !is_posix_memalign_proto(callee)
                return unknown(visited, bb);
            ar := aa_alias(aa_query_new(vis.opts.aar), mloc_before_or_after(op(i, 0)), mloc_before_or_after(op(load, 0)));
            if ar.kind == AR_NO continue;
            if ar.kind != AR_MUST return unknown(visited, bb);
            checked := is_implied_by_dom_condition_pred(ICMP_EQ, false, i, const_null_value(vtype(i)), load);
            if checked != 1 return unknown(visited, bb);
            sz := op(i, 2);
            if !is_scalar_const_int(sz) return unknown(visited, bb);
            cs := const_ap(sz);
            if ap_is_negative(cs) return unknown(visited, bb);
            return known(visited, bb, .{ap_zero(cs.bits), cs});
        }
        return unknown(visited, bb);
    }
    spans: [..] Offset_Span; spans.allocator = temp;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    for p: preds {
        s := os_find_load_offset_range(vis, load, p, block_terminator(p), visited, scanned);
        array_add(*spans, s);
        if !os_both_known(s) return unknown(visited, bb);
    }
    if spans.count == 0 return unknown(visited, bb);
    acc := spans[0];
    for k: 1..spans.count-1 acc = os_combine(vis, acc, spans[k]);
    return known(visited, bb, acc);
}
// TLI prototype of posix_memalign: i32 (ptr, size_t, size_t)
is_posix_memalign_proto :: (f: Value_Id) -> bool {
    ft := glob(f).value_type;
    return func_nparams(ft) == 3 && is_int_type(func_ret(ft)) && type_int_width(func_ret(ft)) == 32 &&
           is_ptr_type(func_param(ft, 0)) && is_int_type(func_param(ft, 1)) && type_int_width(func_param(ft, 1)) == dl_index_size_bits(0) &&
           func_param(ft, 1) == func_param(ft, 2);
}

// getSizeWithOverflow
os_size_with_overflow :: (size: APInt, offset: APInt) -> APInt {
    if ap_is_negative(offset) || ap_ult(size, offset) return ap_zero(size.bits);
    return ap_sub(size, offset);
}
// getObjectSize(Ptr, Size, DL, TLI, Opts)
get_object_size :: (ptr: Value_Id, opts: Os_Opts) -> (bool, u64) {
    ok, size, offset := os_compute(opts, ptr);
    if !ok return false, 0;
    return true, ap_zext_value(os_size_with_overflow(size, offset));
}

// lowerObjectSizeCall(ObjectSize, DL, TLI, AA, MustSucceed, InsertedInstructions)
lower_object_size_call :: (os: Value_Id, aar: *Aa_Results, must_succeed: bool, inserted: *[..] Value_Id = null) -> Value_Id {
    max_val := is_null_value(call_arg(os, 1));
    opts: Os_Opts;
    opts.aar = aar;
    if must_succeed opts.mode = ifx max_val then Os_Mode.MAX else .MIN;
    else opts.mode = .EXACT_SIZE_FROM_OFFSET;
    opts.null_is_unknown_size = ap_is_one(const_ap(call_arg(os, 2)));
    rt := vtype(os);
    rbits := type_int_width(rt);
    static_only := is_null_value(call_arg(os, 3));
    if static_only {
        ok, size := get_object_size(call_arg(os, 0), opts);
        if ok && (rbits >= 64 || (size >> rbits) == 0) return const_int(rt, size);
    } else {
        ev: Os_Evaluator;
        ev.opts = opts;
        ev.cache.allocator = temp; ev.seen.allocator = temp;
        ok, size, offset := ose_compute(*ev, call_arg(os, 0));
        if ok {
            b: Irb;
            irb_set_before(*b, os);
            first_new := cast(Value_Id) ir.v_kind.count;
            rs := irb_binop(*b, .SUB, size, offset);
            use_zero := irb_icmp(*b, ICMP_ULT, size, offset);
            rs = irb_zext_or_trunc(*b, rs, rt);
            ret := irb_select(*b, use_zero, const_int(rt, 0), rs);
            if !is_const(size) || !is_const(offset) {
                c := irb_icmp(*b, ICMP_NE, ret, const_all_ones_of(rt));
                irb_intrinsic(*b, "llvm.assume", .[], .[c]);
            }
            if inserted ose_collect_inserted(first_new, inserted);
            return ret;
        }
    }
    if !must_succeed return NONE;
    return ifx max_val then const_all_ones_of(rt) else const_null_value(rt);
}

// ---------------------------------------------------------------- ObjectSizeOffsetEvaluator

Os_Size_Offset :: struct { size: Value_Id = NONE; offset: Value_Id = NONE; }
ose_both_known :: (s: Os_Size_Offset) -> bool { return s.size != NONE && s.offset != NONE; }
ose_any_known :: (s: Os_Size_Offset) -> bool { return s.size != NONE || s.offset != NONE; }
Os_Evaluator :: struct {
    opts: Os_Opts;
    int_ty: Type_Id;
    zero: Value_Id;
    b: Irb;
    cache: Table(Value_Id, Os_Size_Offset);
    seen: [..] Value_Id;
    first_new: Value_Id;
}
// instructions created since `first` that are still in the function (InsertedInstructions)
ose_collect_inserted :: (first: Value_Id, out: *[..] Value_Id) {
    for v: cast(s64) first..ir.v_kind.count-1 {
        x := cast(Value_Id) v;
        if vkind(x) == .INST && inst(x).parent != NONE array_add(out, x);
    }
}

// ObjectSizeOffsetEvaluator::compute
ose_compute :: (ev: *Os_Evaluator, v: Value_Id) -> (bool, Value_Id, Value_Id) {
    ev.int_ty = dl_index_type(vtype(v));
    ev.zero = const_int(ev.int_ty, 0);
    ev.first_new = cast(Value_Id) ir.v_kind.count;
    r := ose_compute_(ev, v);
    if !ose_both_known(r) {
        for ev.seen {
            found, c := table_find(*ev.cache, it);
            if found && ose_any_known(c) table_remove(*ev.cache, it);
        }
        ins: [..] Value_Id; ins.allocator = temp;
        ose_collect_inserted(ev.first_new, *ins);
        for ins { replace_all_uses_with(it, const_poison(vtype(it))); erase_inst(it); }
    }
    ev.seen.count = 0;
    return ose_both_known(r), r.size, r.offset;
}

ose_compute_ :: (ev: *Os_Evaluator, v_in: Value_Id) -> Os_Size_Offset {
    vopts := ev.opts;
    vopts.mode = .EXACT_UNDERLYING_SIZE_AND_OFFSET;
    ok, size, offset := os_compute(vopts, v_in);
    if ok return .{const_int_ap(type_int(size.bits), size), const_int_ap(type_int(offset.bits), offset)};
    v := strip_pointer_casts(v_in);
    found, c := table_find(*ev.cache, v);
    if found return c;
    saved := ev.b;
    defer ev.b = saved;
    if is_inst(v) irb_set_before(*ev.b, v);
    result: Os_Size_Offset;
    seen := false;
    for ev.seen if it == v { seen = true; break; }
    if seen result = .{};
    else {
        array_add(*ev.seen, v);
        if opr_code(v) == .GEP result = ose_visit_gep(ev, v);
        else if is_inst(v) result = ose_visit_inst(ev, v);
        else result = .{};
    }
    table_set(*ev.cache, v, result);
    return result;
}

ose_visit_gep :: (ev: *Os_Evaluator, g: Value_Id) -> Os_Size_Offset {
    pd := ose_compute_(ev, op(g, 0));
    if !ose_both_known(pd) return .{};
    off := ic_emit_gep_offset_irb(*ev.b, g, true);
    off = irb_binop(*ev.b, .ADD, pd.offset, off);
    return .{pd.size, off};
}

ose_visit_inst :: (ev: *Os_Evaluator, i: Value_Id) -> Os_Size_Offset {
    o := inst_op(i);
    if o == .ALLOCA {
        if !type_is_sized(inst(i).ty2) return .{};
        it := dl_index_type(type_ptr(dl.alloca_as));
        // CreateAllocationSize(IndexTy, &I)
        sz := irb_type_size(*ev.b, it, dl_type_alloc_size(inst(i).ty2), type_is_scalable(inst(i).ty2));
        n := op(i, 0);
        if !(is_scalar_const_int(n) && ap_is_one(const_ap(n)))
            sz = irb_binop(*ev.b, .MUL, irb_zext_or_trunc(*ev.b, n, it), sz);
        return .{sz, ev.zero};
    }
    if is_call_base(i) {
        okd, d := mb_allocation_size_data(i);
        if !okd return .{};
        if d.ty == AT_STRDUP return .{};
        first := irb_zext_or_trunc(*ev.b, call_arg(i, cast(u32) d.fst), ev.int_ty);
        if d.snd < 0 return .{first, ev.zero};
        second := irb_zext_or_trunc(*ev.b, call_arg(i, cast(u32) d.snd), ev.int_ty);
        return .{irb_binop(*ev.b, .MUL, first, second), ev.zero};
    }
    if o == .PHI {
        n := nops(i);
        size_phi := irb_phi(*ev.b, ev.int_ty, n);
        off_phi := irb_phi(*ev.b, ev.int_ty, n);
        table_set(*ev.cache, i, Os_Size_Offset.{size_phi, off_phi});
        for k: 0..cast(s64) n - 1 {
            ib := phi_block(i, cast(u32) k);
            irb_set_at(*ev.b, ib, block_first_insertion_pt(ib), false);
            ed := ose_compute_(ev, op(i, cast(u32) k));
            if !ose_both_known(ed) {
                replace_all_uses_with(off_phi, const_poison(ev.int_ty)); erase_inst(off_phi);
                replace_all_uses_with(size_phi, const_poison(ev.int_ty)); erase_inst(size_phi);
                return .{};
            }
            phi_add_incoming(size_phi, ed.size, ib);
            phi_add_incoming(off_phi, ed.offset, ib);
        }
        size := size_phi; offset := off_phi;
        t := phi_has_constant_value(size_phi);
        if t != NONE { size = t; replace_all_uses_with(size_phi, t); erase_inst(size_phi); }
        t = phi_has_constant_value(off_phi);
        if t != NONE { offset = t; replace_all_uses_with(off_phi, t); erase_inst(off_phi); }
        return .{size, offset};
    }
    if o == .SELECT {
        ts := ose_compute_(ev, op(i, 1));
        fs := ose_compute_(ev, op(i, 2));
        if !ose_both_known(ts) || !ose_both_known(fs) return .{};
        if ts.size == fs.size && ts.offset == fs.offset return ts;
        size := irb_select(*ev.b, op(i, 0), ts.size, fs.size);
        offset := irb_select(*ev.b, op(i, 0), ts.offset, fs.offset);
        return .{size, offset};
    }
    return .{};   // extractelement, extractvalue, inttoptr, load, everything else
}

// IRBuilder::CreateTypeSize on a plain builder
irb_type_size :: (b: *Irb, ty: Type_Id, size: u64, scalable: bool) -> Value_Id {
    if !scalable || size == 0 return const_int(ty, size);
    vs := irb_intrinsic(b, "llvm.vscale", .[ty], .[]);
    if size == 1 return vs;
    return irb_binop(b, .MUL, vs, const_int(ty, size), "", F_NUW);
}

// getConstantDataArrayInfo / GetStringLength: value_tracking_strings.jai
