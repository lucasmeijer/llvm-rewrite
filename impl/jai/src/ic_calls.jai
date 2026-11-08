// InstCombine: visitCallInst (the generic intrinsics), visitCallBase, visitInvokeInst, visitCallBrInst,
// visitFenceInst and their helpers.
// Ported from: llvm/lib/Transforms/InstCombine/InstCombineCalls.cpp (LLVM 23.1.5), in the file's order.

// ---------------------------------------------------------------- AA (InstCombinerImpl::AA)

ic_aar_state: struct { f: Value_Id = NONE; r: Aa_Results; }
// the function's AAResults (AM.getResult<AAManager>(F)); InstCombine preserves the CFG so one per function run
ic_aa :: () -> *Aa_Results {
    if ic_aar_state.f != ic.f { ic_aar_state.r = aa_results_for(ic.f); ic_aar_state.f = ic.f; }
    return *ic_aar_state.r;
}
// AA->getModRefInfoMask(Ptr) (MemoryLocation::getBeforeOrAfter(Ptr), IgnoreLocals = false)
ic_points_to_const_mem_mask :: (ptr: Value_Id) -> u8 {
    return aa_mod_ref_mask(aa_query_new(ic_aa()), mloc_before_or_after(ptr));
}

// ---------------------------------------------------------------- small helpers

// CallInst::Create(F, Args) with the call's function (unlinked)
create_call_fn :: (f: Value_Id, args: [] Value_Id) -> Value_Id {
    fty := glob(f).value_type;
    i := new_inst(.CALL, func_ret(fty), cast(u32)(args.count + 1));
    inst(i).ty2 = fty;
    for args set_op(i, cast(u32) it_index, it);
    set_op(i, cast(u32) args.count, f);
    return i;
}
// IRBuilder::CreateCall(F, Args)
// CallBase::setArgOperand / replace an argument
call_set_arg :: (i: Value_Id, k: u32, v: Value_Id) { set_op(i, k, v); }
// CallBase::setCalledFunction(F)
call_set_called_function :: (i: Value_Id, f: Value_Id) {
    set_op(i, nops(i) - 1, f);
    inst(i).ty2 = glob(f).value_type;
}
// call-site attribute list edits
call_param_attr_set :: (i: Value_Id, k: u32) -> u32 { return attr_list_param(inst(i).attrs, k); }
call_set_param_attr_set :: (i: Value_Id, k: u32, s: u32) {
    r := inst(i);
    np := max(cast(s64) call_arg_count(i), cast(s64) k + 1);
    old := ir.attr_lists[r.attrs].params;
    ps := NewArray(np, u32,, allocator = temp);
    for x: 0..np-1 ps[x] = attr_list_param(r.attrs, cast(u32) x);
    ps[k] = s;
    r.attrs = attr_list_get(attr_list_fn(r.attrs), attr_list_ret(r.attrs), ps);
}
call_set_ret_attr_set :: (i: Value_Id, s: u32) {
    r := inst(i);
    np := call_arg_count(i);
    ps := NewArray(cast(s64) np, u32,, allocator = temp);
    for x: 0..cast(s64) np - 1 ps[x] = attr_list_param(r.attrs, cast(u32) x);
    r.attrs = attr_list_get(attr_list_fn(r.attrs), s, ps);
}
attr_set_with :: (s: u32, a: Attr) -> u32 {
    s2 := attr_set_remove(s, a.kind);
    return attr_set_merge(s2, attr_set_get(.[a]));
}
call_add_ret_attr :: (i: Value_Id, a: Attr) { call_set_ret_attr_set(i, attr_set_with(attr_list_ret(inst(i).attrs), a)); }
call_add_ret_attr_kind :: (i: Value_Id, k: Attr_Kind) { a: Attr; a.kind = k; a.ty = NONE; call_add_ret_attr(i, a); }
call_add_ret_int_attr :: (i: Value_Id, k: Attr_Kind, v: u64) { a: Attr; a.kind = k; a.ty = NONE; a.ival = v; call_add_ret_attr(i, a); }
// CallBase::addRangeRetAttr
call_add_range_ret_attr :: (i: Value_Id, r: Const_Range) {
    a: Attr; a.kind = .Range; a.ty = NONE; a.ival = r.lo.bits;
    lw := ap_words(r.lo); hw := ap_words(r.hi);
    a.lo = NewArray(lw.count, u64); for lw a.lo[it_index] = it;
    a.hi = NewArray(hw.count, u64); for hw a.hi[it_index] = it;
    call_add_ret_attr(i, a);
}
// CallBase::getRetAlign (call site, then callee)
call_ret_align :: (i: Value_Id) -> u64 {
    a := call_ret_attr(i, .Alignment);
    if !a return 0;
    return a.ival;
}
// getKnownAlignment(V, DL, CxtI, AC, DT) = getOrEnforceKnownAlignment(V, MaybeAlign(), ...)
ic_get_known_alignment :: (v: Value_Id, cxt: Value_Id) -> u64 { return get_or_enforce_known_alignment(v, 0, cxt, ic.ac, ic.dt); }
// ConstantInt::get(Ty, APInt) for any (vector) integer type
ic_const_int_ap :: (t: Type_Id, a: APInt) -> Value_Id { return const_int_ap(t, a); }
// Builder.CreateAssumption(Cond)
icb_assumption :: (c: Value_Id) -> Value_Id { return icb_intrinsic(IID_ASSUME, .[], .[c]); }
// InstCombinerImpl::CreateNonTerminatorUnreachable: store i1 true, ptr poison before I
type_ptr_as :: (as: u32) -> Type_Id { return intern_type(.PTR, 0, cast(u64) as, .[]); }
// CreateExtractValue/CreateInsertValue
// Builder.CreateLoad(Ty, Ptr, Name) / CreateStore(V, Ptr, isVolatile) (alignment set by the caller)
icb_load_raw :: (ty: Type_Id, ptr: Value_Id, align: u64, name: string = "") -> Value_Id {
    l := new_inst(.LOAD, ty, 1);
    set_op(l, 0, ptr);
    inst(l).align = align;
    return icb_insert(l, name);
}
icb_store_raw :: (v: Value_Id, ptr: Value_Id, align: u64, volatile := false) -> Value_Id {
    s := new_inst(.STORE, ir.t_void, 2);
    set_op(s, 0, v); set_op(s, 1, ptr);
    inst(s).align = align;
    if volatile inst(s).flags |= F_VOLATILE;
    return icb_insert(s);
}
create_store_raw :: (v: Value_Id, ptr: Value_Id, align: u64) -> Value_Id {
    s := new_inst(.STORE, ir.t_void, 2);
    set_op(s, 0, v); set_op(s, 1, ptr);
    inst(s).align = align;
    return s;
}

// ---------------------------------------------------------------- AnyMemIntrinsic views

ic_is_any_mem_intrinsic :: (id: Intrinsic_Id) -> bool {
    return id == IID_MEMCPY || id == IID_MEMCPY_INLINE || id == IID_MEMMOVE || id == IID_MEMSET || id == IID_MEMSET_INLINE ||
           id == IID_MEMCPY_ELEMENT_UNORDERED_ATOMIC || id == IID_MEMMOVE_ELEMENT_UNORDERED_ATOMIC || id == IID_MEMSET_ELEMENT_UNORDERED_ATOMIC;
}
ic_is_any_mem_transfer :: (id: Intrinsic_Id) -> bool {
    return id == IID_MEMCPY || id == IID_MEMCPY_INLINE || id == IID_MEMMOVE || id == IID_MEMCPY_ELEMENT_UNORDERED_ATOMIC || id == IID_MEMMOVE_ELEMENT_UNORDERED_ATOMIC;
}
ic_is_any_mem_set :: (id: Intrinsic_Id) -> bool { return id == IID_MEMSET || id == IID_MEMSET_INLINE || id == IID_MEMSET_ELEMENT_UNORDERED_ATOMIC; }
ic_is_any_mem_move :: (id: Intrinsic_Id) -> bool { return id == IID_MEMMOVE || id == IID_MEMMOVE_ELEMENT_UNORDERED_ATOMIC; }
ic_mem_is_atomic :: (id: Intrinsic_Id) -> bool {
    return id == IID_MEMCPY_ELEMENT_UNORDERED_ATOMIC || id == IID_MEMMOVE_ELEMENT_UNORDERED_ATOMIC || id == IID_MEMSET_ELEMENT_UNORDERED_ATOMIC;
}
ic_mem_is_volatile :: (mi: Value_Id) -> bool {
    if ic_mem_is_atomic(call_iid(mi)) return false;
    v := call_arg(mi, 3);
    return vkind(v) == .C_INT && !ap_is_zero(const_ap(v));
}
// MemIntrinsicBase::setLength(uint64_t)
ic_mem_set_length :: (mi: Value_Id, n: u64) { set_op(mi, 2, const_int(vtype(call_arg(mi, 2)), n)); }
// setDestAlignment / setSourceAlignment
ic_mem_set_param_alignment :: (mi: Value_Id, k: u32, a: u64) { add_param_align(mi, k, a); }

// hasUndefSource
ic_has_undef_source :: (mi: Value_Id) -> bool {
    src := call_arg(mi, 1);
    while is_inst(src) && inst_op(src) == .GEP {
        if !has_one_use(src) return false;
        src = op(src, 0);
    }
    return is_inst(src) && inst_op(src) == .ALLOCA && has_one_use(src);
}

// AAMDNodes::adjustForAccess(Size) of a mem intrinsic's AA metadata (only the no-TBAA cases)
ic_mem_aa_copy_md :: (mi: Value_Id, dst: Value_Id) {
    if get_metadata(mi, md_kind_id("tbaa")) != NONE || get_metadata(mi, md_kind_id("tbaa.struct")) != NONE
        fatal("instcombine: SimplifyAnyMemTransfer with TBAA metadata (AAMDNodes::adjustForAccess) is not supported yet");
    for n: string.["alias.scope", "noalias"] {
        m := get_metadata(mi, md_kind_id(n));
        if m != NONE set_metadata(dst, md_kind_id(n), m);
    }
}

// SimplifyAnyMemTransfer
ic_simplify_any_mem_transfer :: (mi: Value_Id) -> Value_Id {
    dst_align := ic_get_known_alignment(call_arg(mi, 0), mi);
    copy_dst_align := call_param_align(mi, 0);
    if copy_dst_align == 0 || copy_dst_align < dst_align { ic_mem_set_param_alignment(mi, 0, dst_align); return mi; }
    src_align := ic_get_known_alignment(call_arg(mi, 1), mi);
    copy_src_align := call_param_align(mi, 1);
    if copy_src_align == 0 || copy_src_align < src_align { ic_mem_set_param_alignment(mi, 1, src_align); return mi; }
    if (ic_points_to_const_mem_mask(strip_pointer_casts(call_arg(mi, 0))) & MR_MOD) == 0 { ic_mem_set_length(mi, 0); return mi; }
    if ic_has_undef_source(mi) && !ic_mem_is_volatile(mi) { ic_mem_set_length(mi, 0); return mi; }
    len := call_arg(mi, 2);
    if !cf_is_int(len) return NONE;
    size := ap_limited(const_ap(len));
    if size > 8 || (size & (size - 1)) != 0 return NONE;
    atomic := ic_mem_is_atomic(call_iid(mi));
    if atomic && (copy_dst_align < size || copy_src_align < size) return NONE;
    int_ty := type_int(cast(u32) (size << 3));
    src := call_arg(mi, 1); dest := call_arg(mi, 0);
    l := icb_load_raw(int_ty, src, copy_src_align);
    ic_mem_aa_copy_md(mi, l);
    lmp := get_metadata(mi, md_kind_id("llvm.mem.parallel_loop_access"));
    if lmp != NONE set_metadata(l, md_kind_id("llvm.mem.parallel_loop_access"), lmp);
    ag := get_metadata(mi, md_kind_id("llvm.access.group"));
    if ag != NONE set_metadata(l, md_kind_id("llvm.access.group"), ag);
    s := icb_store_raw(l, dest, copy_dst_align);
    ic_mem_aa_copy_md(mi, s);
    if lmp != NONE set_metadata(s, md_kind_id("llvm.mem.parallel_loop_access"), lmp);
    if ag != NONE set_metadata(s, md_kind_id("llvm.access.group"), ag);
    da := get_metadata(mi, md_kind_id("DIAssignID"));
    if da != NONE fatal("instcombine: SimplifyAnyMemTransfer with DIAssignID is not supported yet");
    if !atomic {
        vol := ic_mem_is_volatile(mi);
        set_flag(l, F_VOLATILE, vol); set_flag(s, F_VOLATILE, vol);
    } else {
        inst(l).ord1 = ORD_UNORDERED; inst(s).ord1 = ORD_UNORDERED;
    }
    ic_mem_set_length(mi, 0);
    return mi;
}

// SimplifyAnyMemSet
ic_simplify_any_mem_set :: (mi: Value_Id) -> Value_Id {
    dest := strip_pointer_casts(call_arg(mi, 0));
    known := ic_get_known_alignment(dest, mi);
    ms_align := call_param_align(mi, 0);
    if ms_align == 0 || ms_align < known { ic_mem_set_param_alignment(mi, 0, known); return mi; }
    if (ic_points_to_const_mem_mask(dest) & MR_MOD) == 0 { ic_mem_set_length(mi, 0); return mi; }
    val := call_arg(mi, 1);
    if pm_undef_value(val) { ic_mem_set_length(mi, 0); return mi; }
    len_c := call_arg(mi, 2);
    if !cf_is_int(len_c) || !cf_is_int(val) || type_bits(vtype(val)) != 8 || type_kind(vtype(val)) != .INT return NONE;
    len := ap_limited(const_ap(len_c));
    alignment := ifx ms_align == 0 then cast(u64) 1 else ms_align;
    atomic := ic_mem_is_atomic(call_iid(mi));
    if atomic && alignment < len return NONE;
    if len <= 8 && ic_is_pow2(len) {
        b := ap_zext_value(const_ap(val)) & 0xFF;
        fill := ap_zero(cast(u32) (len * 8));
        for k: 0..cast(s64) len - 1 fill = ap_or(fill, ap_shl(ap_from_u64(cast(u32) (len * 8), b), cast(u32) (k * 8)));
        fill_val := const_int_ap(type_int(cast(u32) (len * 8)), fill);
        s := icb_store_raw(fill_val, call_arg(mi, 0), alignment, ic_mem_is_volatile(mi));
        if get_metadata(mi, md_kind_id("DIAssignID")) != NONE fatal("instcombine: SimplifyAnyMemSet with DIAssignID is not supported yet");
        if atomic inst(s).ord1 = ORD_UNORDERED;
        ic_mem_set_length(mi, 0);
        return mi;
    }
    return NONE;
}

// ---------------------------------------------------------------- masked memory intrinsics

// possiblyDemandedEltsInMask (VectorUtils.cpp)
ic_possibly_demanded_elts_in_mask :: (mask: Value_Id) -> APInt {
    n := cast(u32) type_count(vtype(mask));
    d := ap_all_ones(n);
    if vkind(mask) == .C_VECTOR
        for k: 0..n-1 if is_null_value(cf_elt(mask, cast(u64) k)) ap_clear_bit(*d, k);
    return d;
}
// maskContainsAllOneOrUndef (VectorUtils.cpp)
ic_mask_contains_all_one_or_undef :: (mask: Value_Id) -> bool {
    if pm_all_ones(mask) || pm_undef_value(mask) return true;
    t := vtype(mask);
    if type_kind(t) != .VECTOR || !is_const(mask) return false;
    for k: 0..cast(s64) type_count(t) - 1 {
        e := cf_elt(mask, cast(u64) k);
        if e != NONE && (pm_all_ones(e) || pm_undef_value(e)) return true;
    }
    return false;
}
// isDereferenceablePointer(Ptr, Ty, Q): Loads.cpp is ported by the memory unit; until then only the cases where it
// can only answer false are handled (fail loudly otherwise).
ic_is_dereferenceable_pointer_ty_guard :: (ptr: Value_Id, ty: Type_Id, cxt: Value_Id) -> bool { return is_dereferenceable_pointer_ty(ptr, ty, ic_q(cxt)); }

// simplifyMaskedLoad
ic_simplify_masked_load :: (ii: Value_Id) -> Value_Id {
    load_ptr := call_arg(ii, 0);
    alignment := call_param_align(ii, 0); if alignment == 0 alignment = 1;
    mask := call_arg(ii, 1);
    if pm_all_ones(mask) || pm_poison(mask) {
        l := icb_load_raw(vtype(ii), load_ptr, alignment, "unmaskedload");
        copy_metadata(l, ii);
        return l;
    }
    if ic_is_dereferenceable_pointer_ty_guard(load_ptr, vtype(ii), ii) {
        li := icb_load_raw(vtype(ii), load_ptr, alignment, "unmaskedload");
        copy_metadata(li, ii);
        return icb_select(call_arg(ii, 1), li, call_arg(ii, 2));
    }
    return NONE;
}
// simplifyMaskedStore
ic_simplify_masked_store :: (ii: Value_Id) -> Value_Id {
    store_ptr := call_arg(ii, 1);
    alignment := call_param_align(ii, 1); if alignment == 0 alignment = 1;
    cm := call_arg(ii, 2);
    if !is_const(cm) return NONE;
    if pm_zero(cm) || pm_poison(cm) return ic_erase_inst(ii);
    if pm_all_ones(cm) || pm_poison(cm) {
        s := create_store_raw(call_arg(ii, 0), store_ptr, alignment);
        copy_metadata(s, ii);
        return s;
    }
    if type_kind(vtype(cm)) == .SVECTOR return NONE;
    demanded := ic_possibly_demanded_elts_in_mask(cm);
    poison := ap_zero(demanded.bits);
    v := ic_simplify_demanded_vector_elts(op(ii, 0), demanded, *poison);
    if v != NONE return ic_replace_operand(ii, 0, v);
    return NONE;
}
// simplifyMaskedGather
ic_simplify_masked_gather :: (ii: Value_Id) -> Value_Id {
    cm := call_arg(ii, 1);
    if !is_const(cm) return NONE;
    if cf_is_all_ones(cm) {
        splat_ptr := get_splat_value_vt(call_arg(ii, 0));
        if splat_ptr != NONE {
            vt := vtype(ii);
            alignment := call_param_align(ii, 0); if alignment == 0 alignment = 1;
            l := icb_load_raw(type_elem(vt), splat_ptr, alignment, "load.scalar");
            shuf := icb_vector_splat(type_count(vt), type_kind(vt) == .SVECTOR, l, "broadcast");
            return ic_replace_inst_uses_with(ii, shuf);
        }
    }
    return NONE;
}
// simplifyMaskedScatter
ic_simplify_masked_scatter :: (ii: Value_Id) -> Value_Id {
    cm := call_arg(ii, 2);
    if !is_const(cm) return NONE;
    if pm_zero(cm) || pm_poison(cm) return ic_erase_inst(ii);
    splat_ptr := get_splat_value_vt(call_arg(ii, 1));
    if splat_ptr != NONE {
        splat_val := get_splat_value_vt(call_arg(ii, 0));
        if splat_val != NONE && ic_mask_contains_all_one_or_undef(cm) {
            alignment := call_param_align(ii, 1); if alignment == 0 alignment = 1;
            s := create_store_raw(splat_val, splat_ptr, alignment);
            copy_metadata(s, ii);
            return s;
        }
        if cf_is_all_ones(cm) {
            alignment := call_param_align(ii, 1); if alignment == 0 alignment = 1;
            wt := vtype(call_arg(ii, 1));
            if type_kind(wt) == .SVECTOR fatal("instcombine: simplifyMaskedScatter of a scalable vector is not supported yet");
            vf := const_int(ir.t_i32, type_count(wt));
            last := icb_sub(vf, const_int(ir.t_i32, 1));
            ext := icb_extract_element(call_arg(ii, 0), last);
            s := create_store_raw(ext, splat_ptr, alignment);
            copy_metadata(s, ii);
            return s;
        }
    }
    if type_kind(vtype(cm)) == .SVECTOR return NONE;
    demanded := ic_possibly_demanded_elts_in_mask(cm);
    poison := ap_zero(demanded.bits);
    v := ic_simplify_demanded_vector_elts(op(ii, 0), demanded, *poison);
    if v != NONE return ic_replace_operand(ii, 0, v);
    v = ic_simplify_demanded_vector_elts(op(ii, 1), demanded, *poison);
    if v != NONE return ic_replace_operand(ii, 1, v);
    return NONE;
}
// llvm::getSplatValue(V) (VectorUtils.cpp): splat constants, and shuffles of an insertelement at index 0 with a
// zero mask
get_splat_value_vt :: (v: Value_Id) -> Value_Id {
    if is_const(v) return get_splat_value(v);
    ok, ins, p, mask := pm_shuffle(v);
    if ok {
        for mask if it != 0 return NONE;
        if is_inst(ins) && inst_op(ins) == .INSERTELEMENT && pm_zero_int(op(ins, 2)) return op(ins, 1);
    }
    return NONE;
}
// IRBuilder::CreateVectorSplat(EC, V, Name)

// simplifyInvariantGroupIntrinsic
ic_simplify_invariant_group_intrinsic :: (ii: Value_Id) -> Value_Id {
    arg := call_arg(ii, 0);
    stripped := strip_pointer_casts(arg);
    s2 := stripped;
    while true {
        id := call_iid(s2);
        if id != IID_LAUNDER_INVARIANT_GROUP && id != IID_STRIP_INVARIANT_GROUP break;
        s2 = strip_pointer_casts(call_arg(s2, 0));
    }
    if stripped == s2 return NONE;
    id := call_iid(ii);
    result := icb_intrinsic(id, .[vtype(s2)], .[s2]);
    if type_addrspace(vtype(result)) != type_addrspace(vtype(ii)) result = icb_cast(.ADDRSPACECAST, result, vtype(ii));
    return result;
}

// ---------------------------------------------------------------- cttz / ctlz / ctpop

ic_fold_cttz_ctlz :: (ii: Value_Id) -> Value_Id {
    is_tz := call_iid(ii) == IID_CTTZ;
    op0 := call_arg(ii, 0); op1 := call_arg(ii, 1);
    ty := vtype(ii);
    f := call_called_function(ii);
    okb, x := pm_intrinsic1(op0, IID_BITREVERSE);
    if okb return create_intrinsic_call(ifx is_tz then IID_CTLZ else IID_CTTZ, .[ty], .[x, op1]);
    if is_int_or_int_vector_n(ty, 1) {
        if pm_zero(op1) return create_not(op0);
        return ic_replace_inst_uses_with(ii, const_null_value(ty));
    }
    if has_one_use(ii) && pm_zero(op1) {
        ub := first_user(ii);
        if is_inst(ub) && is_shift_op(inst_op(ub)) && op(ub, 1) == ii return create_call_fn(f, .[op0, get_true(ir.t_i1)]);
    }
    if is_tz {
        okn, nx := pm_neg(op0);
        if okn return create_call_fn(f, .[nx, op1]);
        if ic_is_binop(op0, .AND) {
            for side: 0..1 {
                okn2, nx2 := pm_neg(op(op0, cast(u32) side));
                if okn2 && op(op0, cast(u32) (1 - side)) == nx2 return create_call_fn(f, .[nx2, op1]);
            }
        }
        if has_one_use(op0) {
            oks, sx := pmi_cast(op0, .SEXT);
            if oks {
                z := icb_zext(sx, ty);
                c := icb_binary_intrinsic(IID_CTTZ, z, op1);
                return ic_replace_inst_uses_with(ii, c);
            }
            okz, zx := pmi_cast(op0, .ZEXT);
            if okz && pm_one(op1) {
                c := icb_binary_intrinsic(IID_CTTZ, zx, get_true(ir.t_i1));
                z := icb_zext(c, ty);
                return ic_replace_inst_uses_with(ii, z);
            }
        }
        sp, ax, ay := match_select_pattern(op0);
        if sp.flavor == .ABS || sp.flavor == .NABS return create_call_fn(f, .[ax, op1]);
        oka, absx := pm_intrinsic1(op0, IID_ABS);
        if oka return create_call_fn(f, .[absx, op1]);
        ok, c, sx2 := pm_binop(op0, .SHL);
        if ok && is_inst(op0) && pm_imm_constant(c) && pm_one(op1) {
            cc := icb_binary_intrinsic(IID_CTTZ, c, op1);
            return create_binop(.ADD, cc, sx2);
        }
        ok, c, sx2 = pm_binop(op0, .LSHR);
        if ok && is_inst(op0) && is_exact(op0) && pm_imm_constant(c) && pm_one(op1) {
            cc := icb_binary_intrinsic(IID_CTTZ, c, op1);
            return create_binop(.SUB, cc, sx2);
        }
        ok2, l, one := pm_binop(op0, .ADD);
        if ok2 && is_inst(op0) && pm_one(one) {
            ok3, ao, lx := pm_binop(l, .LSHR);
            if ok3 && is_inst(l) && pm_all_ones(ao) {
                width := const_int_of(ty, cast(u64) scalar_bits(ii));
                return create_binop(.SUB, width, lx);
            }
        }
    } else {
        ok, c, x2 := pm_binop(op0, .LSHR);
        if ok && is_inst(op0) && pm_imm_constant(c) && pm_one(op1) {
            cc := icb_binary_intrinsic(IID_CTLZ, c, op1);
            return create_binop(.ADD, cc, x2);
        }
        ok, c, x2 = pm_binop(op0, .SHL);
        if ok && is_inst(op0) && has_nuw(op0) && pm_imm_constant(c) && pm_one(op1) {
            cc := icb_binary_intrinsic(IID_CTLZ, c, op1);
            return create_binop(.SUB, cc, x2);
        }
        if has_one_use(op0) {
            okx, xv := ic_match_not_x_and_x_minus_1(op0);
            if okx {
                bw := scalar_bits(ii);
                cttz := icb_intrinsic(IID_CTTZ, .[ty], .[xv, get_false(ir.t_i1)]);
                b := const_int_of(ty, cast(u64) bw);
                return ic_replace_inst_uses_with(ii, icb_sub(b, cttz));
            }
        }
    }
    r := ic_try_get_log2(op0, pm_one(op1));
    if r != NONE {
        if is_tz return ic_replace_inst_uses_with(ii, r);
        bo := create_binop(.SUB, const_int_of(vtype(r), cast(u64) scalar_bits(r) - 1), r);
        set_nsw(bo); set_nuw(bo);
        return bo;
    }
    known := ic_known_bits(op0, ii);
    possible := ifx is_tz then kb_count_max_trailing_zeros(known) else kb_count_max_leading_zeros(known);
    definite := ifx is_tz then kb_count_min_trailing_zeros(known) else kb_count_min_leading_zeros(known);
    if possible == definite return ic_replace_inst_uses_with(ii, const_int_of(vtype(op0), cast(u64) definite));
    if !ap_is_zero(known.one) || is_known_non_zero(op0, ic_q(ii)) {
        if !pm_one(call_arg(ii, 1)) return create_call_fn(f, .[op0, get_true(ir.t_i1)]);
    }
    bw := scalar_bits(op0);
    if bw != 1 && !call_has_ret_attr(ii, .Range) && get_metadata(ii, md_kind_id("range")) == NONE {
        call_add_range_ret_attr(ii, cr_new(ap_from_u64(bw, cast(u64) definite), ap_from_u64(bw, cast(u64) possible + 1)));
        return ii;
    }
    return NONE;
}
// m_c_And(m_Not(m_Value(X)), m_Add(m_Deferred(X), m_AllOnes()))
ic_match_not_x_and_x_minus_1 :: (v: Value_Id) -> (bool, Value_Id) {
    if !ic_is_binop(v, .AND) return false, NONE;
    for side: 0..1 {
        okn, x := pm_not(op(v, cast(u32) side));
        if !okn continue;
        ok, a, m1 := pm_binop(op(v, cast(u32) (1 - side)), .ADD);
        if ok && is_inst(op(v, cast(u32) (1 - side))) && a == x && pm_all_ones(m1) return true, x;
    }
    return false, NONE;
}

ic_fold_ctpop :: (ii: Value_Id) -> Value_Id {
    ty := vtype(ii);
    bw := scalar_bits(ii);
    op0 := call_arg(ii, 0);
    f := call_called_function(ii);
    ok, x := pm_intrinsic1(op0, IID_BITREVERSE);
    if !ok ok, x = pm_intrinsic1(op0, IID_BSWAP);
    if ok return create_call_fn(f, .[x]);
    if call_iid(op0) == IID_FSHL || call_iid(op0) == IID_FSHR {
        if call_arg(op0, 0) == call_arg(op0, 1) return create_call_fn(f, .[call_arg(op0, 0)]);
    }
    if has_one_use(op0) && ic_is_binop(op0, .OR) {
        for side: 0..1 {
            xv := op(op0, cast(u32) side);
            okn, nx := pm_neg(op(op0, cast(u32) (1 - side)));
            if okn && nx == xv {
                cttz := icb_intrinsic(IID_CTTZ, .[ty], .[xv, get_false(ir.t_i1)]);
                b := const_int_of(ty, cast(u64) bw);
                return ic_replace_inst_uses_with(ii, icb_sub(b, cttz));
            }
        }
    }
    okx, xv := ic_match_not_x_and_x_minus_1(op0);
    if okx return create_intrinsic_call(IID_CTTZ, .[ty], .[xv, get_false(ir.t_i1)]);
    if has_one_use(op0) {
        okz, zx := pmi_cast(op0, .ZEXT);
        if okz {
            np := icb_unary_intrinsic(IID_CTPOP, zx);
            return create_cast(.ZEXT, np, ty);
        }
    }
    known := ic_known_bits(op0, ii);
    nz := ap_not(known.zero);
    if ap_is_power_of_2(nz) return create_binop(.LSHR, op0, const_int_of(ty, cast(u64) ap_exact_log2(nz)));
    if is_known_to_be_a_power_of_two(op0, true, ic_q(ii))
        return create_cast(.ZEXT, icb_cmp(ICMP_NE, op0, const_null_value(ty)), ty);
    if bw != 1 {
        okr, old := call_range(ii);
        if !okr old = cr_full(bw);
        lower := kb_count_min_population(known);
        upper := kb_count_max_population(known) + 1;
        if lower == 0 && cr_contains(old, ap_zero(bw)) && is_known_non_zero(op0, ic_q(ii)) lower = 1;
        range := cr_new(ap_from_u64(bw, cast(u64) lower), ap_from_u64(bw, cast(u64) upper));
        range = cr_intersect(range, old, .UNSIGNED);
        if !cr_eq(range, old) {
            call_add_range_ret_attr(ii, range);
            return ii;
        }
    }
    return NONE;
}

// ---------------------------------------------------------------- builder helpers

// IRBuilder::CreateIntrinsic(RetTy, ID, Args, FMFSource): overload types deduced from the signature
icb_intrinsic_ret :: (ret: Type_Id, id: Intrinsic_Id, args: [] Value_Id, fmf_src: Value_Id = NONE, name: string = "") -> Value_Id {
    ps := NewArray(args.count, Type_Id,, allocator = temp);
    for args ps[it_index] = vtype(it);
    ft := type_func(ret, ps, false);
    otys: [..] Type_Id; otys.allocator = temp;
    if !intrinsic_signature_valid(id, ft, *otys) fatal("internal: CreateIntrinsic with a wrong signature for %", intrinsic_name(id));
    return icb_intrinsic(id, otys, args, name, fmf_src);
}
icb_intrinsic_fmf :: (id: Intrinsic_Id, otys: [] Type_Id, args: [] Value_Id, fmf: u32, name: string = "") -> Value_Id {
    i := icb_intrinsic(id, otys, args, name);
    if is_fp_math_inst(i) set_fmf(i, fmf);
    return i;
}
// CreateBinaryIntrinsic(ID, L, R, FMFSource) with explicit flags
icb_binary_intrinsic_fmf :: (id: Intrinsic_Id, l: Value_Id, r: Value_Id, fmf: u32, name: string = "") -> Value_Id {
    if is_const(l) && is_const(r) {
        x := cfo_intrinsic(id, .[l, r], vtype(l));
        if x != NONE return x;
    }
    i := icb_intrinsic(id, .[vtype(l)], .[l, r], name);
    if is_fp_math_inst(i) set_fmf(i, fmf);
    return i;
}
// CreateFAbs(V, FMFSource)
// CreateCopySign(Mag, Sign, FMFSource)
icb_copysign_fmf :: (mag: Value_Id, sign: Value_Id, fmf: u32) -> Value_Id { return icb_binary_intrinsic_fmf(IID_COPYSIGN, mag, sign, fmf); }
// CreateLdexp(Src, Exp, FMFSource)
icb_ldexp :: (src: Value_Id, e: Value_Id, fmf: u32, name: string = "") -> Value_Id {
    return icb_intrinsic_fmf(IID_LDEXP, .[vtype(src), vtype(e)], .[src, e], fmf, name);
}
// CreateVectorReverse
icb_vector_reverse :: (v: Value_Id, name: string = "") -> Value_Id {
    t := vtype(v);
    if type_kind(t) == .SVECTOR return icb_intrinsic(IID_VECTOR_REVERSE, .[t], .[v], name);
    n := cast(s64) type_count(t);
    mask := NewArray(n, u32,, allocator = temp);
    for k: 0..n-1 mask[k] = cast(u32) (n - k - 1);
    return icb_shuffle(v, NONE, mask, name);
}
icb_reduce :: (id: Intrinsic_Id, src: Value_Id) -> Value_Id { return icb_intrinsic(id, .[vtype(src)], .[src]); }

// ---------------------------------------------------------------- range intrinsics, va_end

// removeTriviallyEmptyRange(EndI, IsStart)
ic_remove_trivially_empty_range :: (end_i: Value_Id, is_start: (Value_Id, Value_Id) -> bool) -> bool {
    end_id := call_iid(end_i);
    x := end_i;
    while true {
        x = inst(x).prev;
        if x == NONE break;
        id := call_iid(x);
        if id != NOT_INTRINSIC {
            if is_debug_or_pseudo_inst(x) || id == end_id continue;
            if is_start(x, end_i) {
                n := call_arg_count(end_i);
                same := true;
                for k: 0..cast(s64) n - 1 if call_arg(end_i, cast(u32) k) != call_arg(x, cast(u32) k) { same = false; break; }
                if same {
                    ic_erase_inst(x);
                    ic_erase_inst(end_i);
                    return true;
                }
                continue;
            }
        }
        break;
    }
    return false;
}
// visitVAEndInst
ic_visit_va_end :: (i: Value_Id) -> Value_Id {
    is_start :: (ii: Value_Id, end_i: Value_Id) -> bool {
        id := call_iid(ii);
        return id == IID_VASTART || (id == IID_VACOPY && call_arg(end_i, 0) != call_arg(ii, 1));
    }
    ic_remove_trivially_empty_range(i, is_start);
    return NONE;
}

// canonicalizeConstantArg0ToArg1
ic_canonicalize_constant_arg0_to_arg1 :: (call: Value_Id) -> Value_Id {
    a0 := call_arg(call, 0); a1 := call_arg(call, 1);
    if is_const(a0) && !is_const(a1) {
        set_op(call, 0, a1); set_op(call, 1, a0);
        l := call_param_attr_set(call, 0); r := call_param_attr_set(call, 1);
        if l != r {
            call_set_param_attr_set(call, 0, r);
            call_set_param_attr_set(call, 1, l);
        }
        return call;
    }
    return NONE;
}

// ---------------------------------------------------------------- overflow intrinsics

// WithOverflowInst::getBinaryOp / isSigned
ic_with_overflow_binop :: (id: Intrinsic_Id) -> (Opcode, bool) {
    if id == {
        case IID_UADD_WITH_OVERFLOW; return .ADD, false; case IID_SADD_WITH_OVERFLOW; return .ADD, true;
        case IID_USUB_WITH_OVERFLOW; return .SUB, false; case IID_SSUB_WITH_OVERFLOW; return .SUB, true;
        case IID_UMUL_WITH_OVERFLOW; return .MUL, false; case IID_SMUL_WITH_OVERFLOW; return .MUL, true;
    }
    return .NONE_OP, false;
}
// createOverflowTuple
ic_create_overflow_tuple :: (ii: Value_Id, result: Value_Id, overflow: Value_Id) -> Value_Id {
    st := vtype(ii);
    s := const_aggregate(.C_STRUCT, st, .[const_poison(vtype(result)), overflow]);
    return create_insert_value(s, result, .[0]);
}
// foldIntrinsicWithOverflowCommon
ic_fold_intrinsic_with_overflow_common :: (ii: Value_Id) -> Value_Id {
    opc, is_signed := ic_with_overflow_binop(call_iid(ii));
    ok, res, ov := ic_optimize_overflow_check(opc, is_signed, call_arg(ii, 0), call_arg(ii, 1), ii);
    if ok return ic_create_overflow_tuple(ii, res, ov);
    u := ir.v_first_use[ii];
    while u != NONE {
        us := ir.u_user[u];
        u = ir.u_next[u];
        okx, x := pm_extract_value_idx(us, 1);
        if !okx || !ic.ac continue;
        for e: ac_assumptions_for(ic.ac, us) {
            a := e.assume;
            if a == NONE || vkind(a) == .DEAD continue;
            okn, nx := pm_not(call_arg(a, 0));
            if !okn || nx != us continue;
            if !is_valid_assume_for_context(a, ii, null, true) continue;
            result := icb_binop(opc, call_arg(ii, 0), call_arg(ii, 1));
            if is_inst(result) ic_take_name(result, ii);
            if is_inst(result) { if is_signed set_nsw(result); else set_nuw(result); }
            return ic_create_overflow_tuple(ii, result, get_false(vtype(us)));
        }
    }
    return NONE;
}

// ---------------------------------------------------------------- llvm.is.fpclass

ic_input_denormal_is_ieee :: (f: Value_Id, t: Type_Id) -> bool { o, inp := fn_denormal_mode(f, t); return inp == DENORMAL_IEEE; }
// DenormalMode::inputsAreZero: PreserveSign or PositiveZero
ic_input_denormal_is_daz :: (f: Value_Id, t: Type_Id) -> bool { o, inp := fn_denormal_mode(f, t); return inp == DENORMAL_PRESERVE_SIGN || inp == DENORMAL_POSITIVE_ZERO; }
// fpclassTestIsFCmp0
ic_fpclass_test_is_fcmp0 :: (mask: u32, f: Value_Id, t: Type_Id) -> u8 {
    BAD :: cast(u8) BAD_FCMP_PREDICATE;
    m := mask;
    if m == FC_ZERO { if ic_input_denormal_is_ieee(f, t) return FCMP_OEQ; }
    else if m == FC_ZERO | FC_SUBNORMAL { if ic_input_denormal_is_daz(f, t) return FCMP_OEQ; }
    else if m == FC_POSITIVE | FC_NEG_ZERO { if ic_input_denormal_is_ieee(f, t) return FCMP_OGE; }
    else if m == FC_POSITIVE | FC_NEG_ZERO | FC_NEG_SUBNORMAL { if ic_input_denormal_is_daz(f, t) return FCMP_OGE; }
    else if m == FC_POS_SUBNORMAL | FC_POS_NORMAL | FC_POS_INF { if ic_input_denormal_is_ieee(f, t) return FCMP_OGT; }
    else if m == FC_NEGATIVE | FC_POS_ZERO { if ic_input_denormal_is_ieee(f, t) return FCMP_OLE; }
    else if m == FC_NEGATIVE | FC_POS_ZERO | FC_POS_SUBNORMAL { if ic_input_denormal_is_daz(f, t) return FCMP_OLE; }
    else if m == FC_NEG_SUBNORMAL | FC_NEG_NORMAL | FC_NEG_INF { if ic_input_denormal_is_ieee(f, t) return FCMP_OLT; }
    else if m == FC_POS_NORMAL | FC_POS_INF { if ic_input_denormal_is_daz(f, t) return FCMP_OGT; }
    else if m == FC_NEG_NORMAL | FC_NEG_INF { if ic_input_denormal_is_daz(f, t) return FCMP_OLT; }
    else if m == (FC_ALL_FLAGS & fc_not(FC_ZERO) & fc_not(FC_NAN)) { if ic_input_denormal_is_ieee(f, t) return FCMP_ONE; }
    else if m == (FC_ALL_FLAGS & fc_not(FC_ZERO | FC_SUBNORMAL) & fc_not(FC_NAN)) { if ic_input_denormal_is_daz(f, t) return FCMP_ONE; }
    return BAD_FCMP_PREDICATE;
}
ic_fp_inf_const :: (t: Type_Id, neg := false) -> Value_Id { return const_fp_words(t, fp_inf(type_kind(scalar_type(t)), neg)); }
// foldIntrinsicIsFPClass
ic_fold_intrinsic_is_fpclass :: (ii: Value_Id) -> Value_Id {
    src0 := call_arg(ii, 0); src1 := call_arg(ii, 1);
    mask := cast(u32) const_int_zext(src1) & FC_ALL_FLAGS;
    is_unordered := (mask & FC_NAN) == FC_NAN;
    is_ordered := (mask & FC_NAN) == 0;
    ordered_mask := mask & ~cast(u32) FC_NAN;
    ordered_inv := fc_not(ordered_mask) & fc_not(FC_NAN);
    is_strict := fn_has_fn_attr(inst_fn(ii), .StrictFP);
    f := call_called_function(ii);
    okn, fneg_src := pm_fneg(src0);
    if okn return create_call_fn(f, .[fneg_src, const_int_of(vtype(src1), cast(u64) fc_fneg(mask))]);
    oka, fabs_src := pm_fabs(src0);
    if oka return create_call_fn(f, .[fabs_src, const_int_of(vtype(src1), cast(u64) fc_inverse_fabs(mask))]);
    t := vtype(src0);
    take :: (r: Value_Id, ii: Value_Id) -> Value_Id { if is_inst(r) ic_take_name(r, ii); return ic_replace_inst_uses_with(ii, r); }
    if (ordered_mask == FC_INF || ordered_inv == FC_INF) && (is_ordered || is_unordered) && !is_strict {
        inf := ic_fp_inf_const(t);
        pred := ifx is_unordered then FCMP_UEQ else cast(u8) FCMP_OEQ;
        if ordered_inv == FC_INF pred = ifx is_unordered then FCMP_UNE else cast(u8) FCMP_ONE;
        fabs := icb_fabs(src0, NONE);
        return take(icb_cmp(pred, fabs, inf), ii);
    }
    if (ordered_mask == FC_POS_INF || ordered_mask == FC_NEG_INF) && (is_ordered || is_unordered) && !is_strict {
        inf := ic_fp_inf_const(t, ordered_mask == FC_NEG_INF);
        return take(icb_cmp(ifx is_unordered then FCMP_UEQ else cast(u8) FCMP_OEQ, src0, inf), ii);
    }
    if (ordered_inv == FC_POS_INF || ordered_inv == FC_NEG_INF) && (is_ordered || is_unordered) && !is_strict {
        inf := ic_fp_inf_const(t, ordered_inv == FC_NEG_INF);
        return take(icb_cmp(ifx is_unordered then FCMP_UNE else cast(u8) FCMP_ONE, src0, inf), ii);
    }
    if mask == FC_NAN && !is_strict return take(icb_cmp(FCMP_UNO, src0, fp_zero_of(t)), ii);
    if mask == fc_not(FC_NAN) && !is_strict return take(icb_cmp(FCMP_ORD, src0, fp_zero_of(t)), ii);
    if !is_strict && (is_ordered || is_unordered) {
        pt := ic_fpclass_test_is_fcmp0(ordered_mask, inst_fn(ii), t);
        if pt != BAD_FCMP_PREDICATE {
            return take(icb_cmp(ifx is_unordered then fcmp_unordered(pt) else pt, src0, fp_zero_of(t)), ii);
        }
    }
    known := compute_known_fp_class(src0, mask, ic_q(ii));
    if (mask & known.known_fp_classes) != mask {
        set_op(ii, 1, const_int_of(vtype(src1), cast(u64) (mask & known.known_fp_classes)));
        return ii;
    }
    if mask == known.known_fp_classes return ic_replace_inst_uses_with(ii, get_true(vtype(ii)));
    return NONE;
}

// getKnownSign / getKnownSignOrZero (-1 unknown, 0 false, 1 true)
ic_get_known_sign :: (v: Value_Id, q: Simplify_Query) -> s8 {
    k := known_bits(v, q);
    if kb_is_non_negative(k) return 0;
    if kb_is_negative(k) return 1;
    ok, x, y := pm_ob(v, .SUB, F_NSW);
    if ok return is_implied_by_dom_condition_pred(ICMP_SLT, false, x, y, q.cxt);
    return -1;
}
ic_get_known_sign_or_zero :: (v: Value_Id, q: Simplify_Query) -> s8 {
    s := ic_get_known_sign(v, q);
    if s >= 0 return s;
    ok, x, y := pm_ob(v, .SUB, F_NSW);
    if ok return is_implied_by_dom_condition_pred(ICMP_SLE, false, x, y, q.cxt);
    return -1;
}
// signBitMustBeTheSame
ic_sign_bit_must_be_the_same :: (op0: Value_Id, op1: Value_Id, q: Simplify_Query) -> bool {
    k1 := ic_get_known_sign(op1, q);
    if k1 < 0 return false;
    k0 := ic_get_known_sign(op0, q);
    if k0 < 0 return false;
    return k0 == k1;
}
// ldexpSaturatingAddIsSafe (computed on the exponents instead of with scalbn)
ic_ldexp_saturating_add_is_safe :: (fp_ty: Type_Id, exp_ty: Type_Id) -> bool {
    k := type_kind(scalar_type(fp_ty));
    p, emax, emin, bits := fp_semantics(k);
    if k == .PPC_FP128 fatal("instcombine: ldexpSaturatingAddIsSafe for ppc_fp128 is not supported yet");
    exp_bits := min(type_bits(scalar_type(exp_ty)), 32);
    smax := (cast(s64) 1 << (exp_bits - 1)) - 1;
    smin := -(cast(s64) 1 << (exp_bits - 1));
    scaled_up_inf := cast(s64) emin - cast(s64) p + 1 + smax > cast(s64) emax;
    scaled_down_zero := cast(s64) emax + 1 + smin <= cast(s64) emin - cast(s64) p;
    return scaled_up_inf && scaled_down_zero;
}

// ---------------------------------------------------------------- min/max helpers

ic_mm_is_signed :: (id: Intrinsic_Id) -> bool { return id == IID_SMAX || id == IID_SMIN; }
// MinMaxIntrinsic::getPredicate
ic_mm_predicate :: (id: Intrinsic_Id) -> u8 {
    if id == {
        case IID_SMAX; return ICMP_SGT; case IID_SMIN; return ICMP_SLT;
        case IID_UMAX; return ICMP_UGT; case IID_UMIN; return ICMP_ULT;
    }
    return 0;
}
// moveAddAfterMinMax
ic_move_add_after_min_max :: (ii: Value_Id) -> Value_Id {
    id := call_iid(ii);
    op0 := call_arg(ii, 0); op1 := call_arg(ii, 1);
    if !has_one_use(op0) || !ic_is_binop(op0, .ADD) return NONE;
    x := op(op0, 0);
    ok0, c0 := pm_apint(op(op0, 1));
    ok1, c1 := pm_apint(op1);
    if !ok0 || !ok1 return NONE;
    is_signed := ic_mm_is_signed(id);
    if (is_signed && !has_nsw(op0)) || (!is_signed && !has_nuw(op0)) return NONE;
    cdiff: APInt; ov: bool;
    if is_signed cdiff, ov = ap_ssub_ov(c1, c0); else cdiff, ov = ap_usub_ov(c1, c0);
    nc := const_int_ap(vtype(ii), cdiff);
    nmm := icb_binary_intrinsic(id, x, nc);
    return create_binop_flags(.ADD, nmm, op(op0, 1), ifx is_signed then cast(u32) F_NSW else F_NUW);
}
// matchSAddSubSat
ic_match_sadd_sub_sat :: (mm1: Value_Id) -> Value_Id {
    ty := vtype(mm1);
    mm2: Value_Id = NONE; add_sub: Value_Id = NONE;
    min_v, max_v: APInt;
    ok, a, b := ic_pm_min_max_lr(mm1, IID_SMIN);
    okc: bool;
    if ok && is_inst(a) { okc, max_v = pm_apint(b); ok = okc; }
    if ok {
        mm2 = a;
        ok2, a2, b2 := ic_pm_min_max_lr(mm2, IID_SMAX);
        okm: bool;
        if ok2 okm, min_v = pm_apint(b2);
        if !ok2 || !okm || !is_inst(a2) || !is_binary_operator(a2) return NONE;
        add_sub = a2;
    } else {
        ok, a, b = ic_pm_min_max_lr(mm1, IID_SMAX);
        if ok && is_inst(a) { okc, min_v = pm_apint(b); ok = okc; }
        if !ok return NONE;
        mm2 = a;
        ok2, a2, b2 := ic_pm_min_max_lr(mm2, IID_SMIN);
        okm: bool;
        if ok2 okm, max_v = pm_apint(b2);
        if !ok2 || !okm || !is_inst(a2) || !is_binary_operator(a2) return NONE;
        add_sub = a2;
    }
    mp1 := ap_add_u64(max_v, 1);
    if !ap_is_power_of_2(mp1) || !ap_eq(ap_neg(min_v), mp1) return NONE;
    nbw := ap_log2(mp1) + 1;
    if !ic_should_change_type_widths(type_int_width(scalar_type(ty)), nbw) return NONE;
    if !has_one_use(mm2) || !has_one_use(add_sub) return NONE;
    nty := type_with_new_bit_width(ty, nbw);
    iid: Intrinsic_Id;
    if inst_op(add_sub) == .ADD iid = IID_SADD_SAT;
    else if inst_op(add_sub) == .SUB iid = IID_SSUB_SAT;
    else return NONE;
    if ic_max_significant_bits(op(add_sub, 0), add_sub) > nbw || ic_max_significant_bits(op(add_sub, 1), add_sub) > nbw return NONE;
    at := icb_trunc(op(add_sub, 0), nty);
    bt := icb_trunc(op(add_sub, 1), nty);
    sat := icb_intrinsic(iid, .[nty], .[at, bt]);
    return create_cast(.SEXT, sat, ty);
}
// foldClampRangeOfTwo
ic_fold_clamp_range_of_two :: (ii: Value_Id) -> Value_Id {
    i0 := call_arg(ii, 0); i1 := call_arg(ii, 1);
    ok1, c1 := pm_apint(i1);
    if !ok1 || !has_one_use(i0) return NONE;
    pred: u8 = 0xFF;
    x: Value_Id; c0: APInt;
    inner := IID_SMIN;
    id := call_iid(ii);
    if id == IID_SMAX inner = IID_SMIN; else if id == IID_SMIN inner = IID_SMAX; else if id == IID_UMAX inner = IID_UMIN; else inner = IID_UMAX;
    ok, a, b := ic_pm_min_max_lr(i0, inner);
    if ok {
        okc: bool;
        okc, c0 = pm_apint(b);
        if okc {
            x = a;
            if id == IID_SMAX && ap_eq(c0, ap_add_u64(c1, 1)) pred = ICMP_SGT;
            if id == IID_SMIN && ap_eq(c1, ap_add_u64(c0, 1)) pred = ICMP_SLT;
            if id == IID_UMAX && ap_eq(c0, ap_add_u64(c1, 1)) pred = ICMP_UGT;
            if id == IID_UMIN && ap_eq(c1, ap_add_u64(c0, 1)) pred = ICMP_ULT;
        }
    }
    if pred == 0xFF return NONE;
    cmp := icb_cmp(pred, x, i1);
    return create_select(cmp, const_int_ap(vtype(ii), c0), i1);
}
// reassociateMinMaxWithConstants
ic_reassociate_min_max_with_constants :: (ii: Value_Id, q: Simplify_Query) -> Value_Id {
    id := call_iid(ii);
    lhs := call_arg(ii, 0);
    inner := call_iid(lhs);
    if !is_min_max_intrinsic(inner) return NONE;
    c0 := call_arg(lhs, 1); c1 := call_arg(ii, 1);
    if !pm_imm_constant(c0) || !pm_imm_constant(c1) return NONE;
    if inner != id && !(((id == IID_UMAX && inner == IID_SMAX) || (id == IID_SMIN && inner == IID_UMIN)) &&
                        is_known_non_negative(c0, q) && is_known_non_negative(c1, q)) return NONE;
    pred := ic_mm_predicate(id);
    cond := icb_cmp(pred, c0, c1);
    nc := icb_select(cond, c0, c1);
    return icb_intrinsic_ret(vtype(ii), inner, .[call_arg(lhs, 0), nc]);
}
// reassociateMinMaxWithConstantInOperand
ic_reassociate_min_max_with_constant_in_operand :: (ii: Value_Id) -> Value_Id {
    // m_c_MaxOrMin(m_OneUse(Inner = m_MaxOrMin(X, ImmC)), Y)
    if !is_min_max_intrinsic(call_iid(ii)) return NONE;
    inner: Value_Id = NONE; x, c, y: Value_Id;
    for side: 0..1 {
        o := call_arg(ii, cast(u32) side);
        if !has_one_use(o) || !is_inst(o) continue;
        mmo := pm_max_or_min_any(o);
        if !mmo || !pm_imm_constant(op(o, 1)) continue;
        inner = o; x = op(o, 0); c = op(o, 1); y = call_arg(ii, cast(u32) (1 - side));
        break;
    }
    if inner == NONE return NONE;
    id := call_iid(ii);
    if call_iid(inner) != id || pm_imm_constant(x) || pm_imm_constant(y) return NONE;
    ni := icb_binary_intrinsic(id, x, y);
    if is_inst(ni) ic_take_name(ni, inner);
    return create_intrinsic_call(id, .[vtype(ii)], .[ni, c]);
}
// factorizeMinMaxTree
ic_factorize_min_max_tree :: (ii: Value_Id) -> Value_Id {
    lhs := call_arg(ii, 0); rhs := call_arg(ii, 1);
    id := call_iid(ii);
    if call_iid(lhs) != id || call_iid(rhs) != id || (!has_one_use(lhs) && !has_one_use(rhs)) return NONE;
    a := call_arg(lhs, 0); b := call_arg(lhs, 1); c := call_arg(rhs, 0); d := call_arg(rhs, 1);
    mm: Value_Id = NONE; third: Value_Id = NONE;
    if has_one_use(lhs) {
        if d == a || c == a { mm = rhs; third = b; }
        else if d == b || c == b { mm = rhs; third = a; }
    } else {
        if d == a || d == b { mm = lhs; third = c; }
        else if c == a || c == b { mm = lhs; third = d; }
    }
    if mm == NONE || third == NONE return NONE;
    return create_intrinsic_call(id, .[vtype(ii)], .[mm, third]);
}

// ---------------------------------------------------------------- vector operand folds

// foldShuffledIntrinsicOperands
ic_fold_shuffled_intrinsic_operands :: (ii: Value_Id) -> Value_Id {
    id := call_iid(ii);
    f := call_called_function(ii);
    if !is_vector_type(vtype(ii)) || !is_trivially_vectorizable(id) || !fn_has_fn_attr(f, .Speculatable) return NONE;
    n := call_arg_count(ii);
    non_const: Value_Id = NONE;
    for k: 0..cast(s64) n - 1 {
        a := call_arg(ii, cast(u32) k);
        if is_const(a) || is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) k) continue;
        non_const = a; break;
    }
    if non_const == NONE return NONE;
    ok, x, p, mask := pm_shuffle(non_const);
    if !ok || !pm_poison(p) return NONE;
    any := false;
    for k: 0..cast(s64) n - 1 { a := call_arg(ii, cast(u32) k); oks, a1, a2, m := pm_shuffle(a); if oks && has_one_use(a) { any = true; break; } }
    if !any return NONE;
    args: [..] Value_Id; args.allocator = temp;
    src_ty := vtype(x);
    for k: 0..cast(s64) n - 1 {
        a := call_arg(ii, cast(u32) k);
        if is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) k) { array_add(*args, a); continue; }
        oks, sx, sp, sm := pm_shuffle(a);
        if oks && pm_poison(sp) && masks_equal(sm, mask) && vtype(sx) == src_ty { array_add(*args, sx); continue; }
        if pm_imm_constant(a) {
            sm := NewArray(mask.count, s32,, allocator = temp);
            for mask sm[it_index] = ifx it == 0xFFFF_FFFF then -1 else cast(s32) it;
            sc := ic_unshuffle_constant(sm, a, src_ty);
            if sc != NONE { array_add(*args, sc); continue; }
        }
        return NONE;
    }
    fpi := ifx is_fp_math_inst(ii) then ii else NONE;
    res_ty := vector_with_elt(src_ty, scalar_type(vtype(ii)));
    ni := icb_intrinsic_ret(res_ty, id, args, fpi);
    return create_shuffle(ni, NONE, mask);
}
// m_VecReverse (the vector.reverse intrinsic)
pm_vec_reverse :: (v: Value_Id) -> (bool, Value_Id) { ok, x := pm_intrinsic1(v, IID_VECTOR_REVERSE); return ok, x; }
// foldReversedIntrinsicOperands
ic_fold_reversed_intrinsic_operands :: (ii: Value_Id) -> Value_Id {
    id := call_iid(ii);
    if !is_vector_type(vtype(ii)) || !is_trivially_vectorizable(id) return NONE;
    n := call_arg_count(ii);
    any := false;
    for k: 0..cast(s64) n - 1 { a := call_arg(ii, cast(u32) k); ok, x := pm_vec_reverse(a); if ok && has_one_use(a) { any = true; break; } }
    if !any return NONE;
    args: [..] Value_Id; args.allocator = temp;
    for k: 0..cast(s64) n - 1 {
        a := call_arg(ii, cast(u32) k);
        if is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) k) { array_add(*args, a); continue; }
        ok, x := pm_vec_reverse(a);
        if ok { array_add(*args, x); continue; }
        if is_splat_value(a) { array_add(*args, a); continue; }
        if pm_imm_constant(a) { array_add(*args, icb_vector_reverse(a)); continue; }
        return NONE;
    }
    fpi := ifx is_fp_math_inst(ii) then ii else NONE;
    ni := icb_intrinsic_ret(vtype(ii), id, args, fpi);
    return icb_vector_reverse(ni);
}
// foldBitOrderCrossLogicOp<bswap|bitreverse>
ic_fold_bit_order_cross_logic_op :: (v: Value_Id, id: Intrinsic_Id) -> Value_Id {
    if !has_one_use(v) || !is_inst(v) || !is_bitwise_logic_op(inst_op(v)) return NONE;
    x := op(v, 0); y := op(v, 1);
    opc := inst_op(v);
    okx, ox := pm_intrinsic1(x, id);
    oky, oy := pm_intrinsic1(y, id);
    if okx && oky return create_binop(opc, ox, oy);
    if okx && has_one_use(x) {
        nr := icb_unary_intrinsic(id, y);
        return create_binop(opc, ox, nr);
    }
    if oky && has_one_use(y) {
        nr := icb_unary_intrinsic(id, x);
        return create_binop(opc, nr, oy);
    }
    return NONE;
}
ic_is_idempotent_binary_intrinsic :: (id: Intrinsic_Id) -> bool {
    return is_min_max_intrinsic(id) || id == IID_MAXIMUM || id == IID_MINIMUM || id == IID_MAXIMUMNUM || id == IID_MINIMUMNUM ||
           id == IID_MAXNUM || id == IID_MINNUM;
}
// matchSimpleBinaryIntrinsicRecurrence (ValueTracking.cpp)
match_simple_binary_intrinsic_recurrence :: (i: Value_Id) -> (bool, Value_Id, Value_Id, Value_Id) {
    if call_arg_count(i) != 2 || vtype(i) != vtype(call_arg(i, 0)) || vtype(i) != vtype(call_arg(i, 1)) return false, NONE, NONE, NONE;
    p := call_arg(i, 0);
    if !is_phi(p) p = call_arg(i, 1);
    if !is_phi(p) || phi_num_incoming(p) != 2 return false, NONE, NONE, NONE;
    for k: 0..1 {
        o := phi_value(p, cast(u32) k);
        if call_iid(o) == NOT_INTRINSIC || nops(o) < 2 continue;
        l := op(o, 0); r := op(o, 1);
        if l != p && r != p continue;
        if o != i return false, NONE, NONE, NONE;
        init := phi_value(p, cast(u32) (1 - k));
        other := ifx l == p then r else l;
        return true, p, init, other;
    }
    return false, NONE, NONE, NONE;
}
// foldIdempotentBinaryIntrinsicRecurrence
ic_fold_idempotent_binary_intrinsic_recurrence :: (ii: Value_Id) -> Value_Id {
    id := call_iid(ii);
    if !ic_is_idempotent_binary_intrinsic(id) return NONE;
    ok, pn, init, other := match_simple_binary_intrinsic_recurrence(ii);
    if !ok || !dt_dominates_inst(ic.dt, other, pn) return NONE;
    r := icb_binary_intrinsic(id, init, other);
    if is_inst(r) && is_fp_math_inst(r) set_fmf(r, get_fmf(ii));
    return r;
}
// simplifyReductionOperand
ic_simplify_reduction_operand :: (arg: Value_Id, can_reorder: bool) -> Value_Id {
    if !can_reorder return NONE;
    okr, v := pm_vec_reverse(arg);
    if okr return v;
    if type_kind(vtype(arg)) != .VECTOR return NONE;
    ok, x, u, mask := pm_shuffle(arg);
    if !ok || !pm_undef_value(u) || !ic_shuffle_is_single_source(arg) return NONE;
    sz := mask.count;
    used := NewArray(sz, bool,, allocator = temp);
    for idx: mask {
        if idx == 0xFFFF_FFFF return NONE;
        if cast(s64) idx >= sz || used[idx] return NONE;
        used[idx] = true;
    }
    for used if !it return NONE;
    return x;
}
// ShuffleVectorInst::isSingleSource (same length as the sources, one source used)
ic_shuffle_is_single_source :: (sv: Value_Id) -> bool {
    m := shuffle_mask(sv);
    n := cast(s64) type_count(vtype(op(sv, 0)));
    if m.count != n return false;
    u0 := false; u1 := false;
    for m { if it == 0xFFFF_FFFF continue; if cast(s64) it < n u0 = true; else u1 = true; }
    return (u0 || u1) && !(u0 && u1);
}
// foldMinimumOverTrailingOrLeadingZeroCount<cttz|ctlz>
ic_fold_minimum_over_tz_lz :: (i0: Value_Id, i1: Value_Id, id: Intrinsic_Id) -> Value_Id {
    ok1, ct1, zu1 := pm_intrinsic2(i0, id);
    if !ok1 || !has_one_use(i0) return NONE;
    ok2, ct2, zu2 := pm_intrinsic2(i1, id);
    if ok2 && has_one_use(i1) return icb_binary_intrinsic(id, icb_or(ct1, ct2), icb_or(zu1, zu2));
    bw := scalar_bits(i1);
    if !pm_int_ult(i1, cast(u64) bw) return NONE;
    ty := vtype(i1);
    base := ifx id == IID_CTTZ then const_int_of(ty, 1) else const_int_ap(ty, ap_signed_min(bw));
    nc := cfo_binary_op_operands(ifx id == IID_CTTZ then Opcode.SHL else .LSHR, base, i1);
    return icb_binary_intrinsic(id, icb_or(ct1, nc), get_true(vtype(zu1)));
}
// leftDistributesOverRight / rightDistributesOverLeft
ic_left_distributes_over_right :: (lop: Opcode, nuw: bool, nsw: bool, rop: Intrinsic_Id) -> bool {
    if rop == IID_UMAX || rop == IID_UMIN return (nuw && lop == .ADD) || (nuw && lop == .SHL);
    if rop == IID_SMAX || rop == IID_SMIN return nsw && lop == .ADD;
    return false;
}
ic_right_distributes_over_left :: (lop: Opcode, nuw: bool, nsw: bool, rop: Intrinsic_Id) -> bool {
    if is_commutative_op(lop) || lop == .SHL return ic_left_distributes_over_right(lop, nuw, nsw, rop);
    if rop == IID_UMAX || rop == IID_UMIN return nuw && lop == .SUB;
    if rop == IID_SMAX || rop == IID_SMIN return nsw && lop == .SUB;
    return false;
}
// foldIntrinsicUsingDistributiveLaws
ic_fold_intrinsic_using_distributive_laws :: (ii: Value_Id) -> Value_Id {
    lhs := op(ii, 0); rhs := op(ii, 1);
    top := call_iid(ii);
    if !is_overflowing_binop(lhs) || !is_overflowing_binop(rhs) return NONE;
    if opr_code(lhs) != opr_code(rhs) return NONE;
    if !has_one_use(lhs) || !has_one_use(rhs) return NONE;
    inner := opr_code(lhs);
    nuw := has_nuw(lhs) && has_nuw(rhs);
    nsw := has_nsw(lhs) && has_nsw(rhs);
    a := op(lhs, 0); b := op(lhs, 1); c := op(rhs, 0); d := op(rhs, 1);
    if is_commutative_op(inner) && a != c && b != d {
        if a == d || b == c { t := c; c = d; d = t; }
        else return NONE;
    }
    nb: Value_Id;
    if a == c && ic_left_distributes_over_right(inner, nuw, nsw, top) {
        ni := icb_binary_intrinsic(top, b, d);
        nb = icb_binop(inner, a, ni);
    } else if b == d && ic_right_distributes_over_left(inner, nuw, nsw, top) {
        ni := icb_binary_intrinsic(top, a, c);
        nb = icb_binop(inner, ni, b);
    } else return NONE;
    if is_inst(nb) { set_nuw(nb, nuw); set_nsw(nb, nsw); }
    return nb;
}

// ---------------------------------------------------------------- operand bundles

// IntrinsicInst::isCommutative
ic_intrinsic_is_commutative :: (id: Intrinsic_Id) -> bool {
    if id == {
        case IID_MAXNUM; #through; case IID_MINNUM; #through; case IID_MAXIMUM; #through; case IID_MINIMUM; #through;
        case IID_MAXIMUMNUM; #through; case IID_MINIMUMNUM; #through; case IID_SMAX; #through; case IID_SMIN; #through;
        case IID_UMAX; #through; case IID_UMIN; #through; case IID_SADD_SAT; #through; case IID_UADD_SAT; #through;
        case IID_SADD_WITH_OVERFLOW; #through; case IID_UADD_WITH_OVERFLOW; #through; case IID_SMUL_WITH_OVERFLOW; #through;
        case IID_UMUL_WITH_OVERFLOW; #through; case IID_SMUL_FIX; #through; case IID_UMUL_FIX; #through;
        case IID_SMUL_FIX_SAT; #through; case IID_UMUL_FIX_SAT; #through; case IID_FMA; #through; case IID_FMULADD;
            return true;
    }
    return false;
}
// the operands [begin, end) of bundle k
call_bundle_range :: (i: Value_Id, k: u32) -> (u32, u32) {
    r := inst(i);
    return ir.u32_pool[r.idx + 3 * k + 1], ir.u32_pool[r.idx + 3 * k + 2];
}
// CallBase::Create(CI, Bundles) without bundle `drop` (unlinked)
ic_call_remove_bundle_at :: (i: Value_Id, drop: u32) -> Value_Id {
    b, e := call_bundle_range(i, drop);
    n := nops(i);
    c := new_inst(inst_op(i), vtype(i), n - (e - b));
    src := inst(i).*;
    r := inst(c);
    r.* = src;
    r.parent = NONE; r.prev = NONE; r.next = NONE; r.records = 0;
    k: u32 = 0;
    for x: 0..n-1 { if x >= b && x < e continue; set_op(c, k, op(i, x)); k += 1; }
    nb := src.nidx;
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = nb - 1;
    for x: 0..nb-1 {
        if x == drop continue;
        t := ir.u32_pool[src.idx + 3 * x]; bb := ir.u32_pool[src.idx + 3 * x + 1]; ee := ir.u32_pool[src.idx + 3 * x + 2];
        if x > drop { bb -= e - b; ee -= e - b; }
        array_add(*ir.u32_pool, t); array_add(*ir.u32_pool, bb); array_add(*ir.u32_pool, ee);
    }
    copy_metadata(c, i);
    return c;
}
// CreateAssumption(true, {Bundle(tag, vals)})
icb_assumption_bundle :: (tag: string, vals: [] Value_Id) -> Value_Id {
    f := get_or_insert_intrinsic_declaration(IID_ASSUME, .[]);
    fty := glob(f).value_type;
    i := new_inst(.CALL, ir.t_void, cast(u32)(vals.count + 2));
    inst(i).ty2 = fty;
    set_op(i, 0, get_true(ir.t_i1));
    for vals set_op(i, cast(u32) (it_index + 1), it);
    set_op(i, cast(u32) (vals.count + 1), f);
    r := inst(i);
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = 1;
    array_add(*ir.u32_pool, bundle_tag_id(tag)); array_add(*ir.u32_pool, 1); array_add(*ir.u32_pool, cast(u32) (vals.count + 1));
    return icb_insert(i);
}
icb_alignment_assumption :: (ptr: Value_Id, align: u64, offset: Value_Id = NONE) -> Value_Id {
    av := const_int(ir.t_i64, align);
    if offset != NONE return icb_assumption_bundle("align", .[ptr, av, offset]);
    return icb_assumption_bundle("align", .[ptr, av]);
}

// ---------------------------------------------------------------- visitCallInst

ic_visit_call :: (ci: Value_Id) -> Value_Id {
    // InstVisitor delegates llvm.va_end to visitVAEndInst instead of visitCallInst
    if call_iid(ci) == IID_VAEND return ic_visit_va_end(ci);
    if has_uses(ci) {
        args: [..] Value_Id; args.allocator = temp;
        n := call_num_args(ci);
        if n > 0 for k: 0..n-1 array_add(*args, op(ci, k));
        v := simplify_call(ci, call_callee(ci), args, ic_q(ci));
        if v != NONE return ic_replace_inst_uses_with(ci, v);
    }
    freed := get_freed_operand(ci);
    if freed != NONE return ic_visit_free(ci, freed);
    if fn_has_fn_attr(ic.f, .NoUnwind) && !call_has_fn_attr(ci, .NoUnwind) {
        call_add_fn_attr(ci, .NoUnwind);
        return ci;
    }
    iid := call_iid(ci);
    if iid == NOT_INTRINSIC return ic_visit_call_base(ci);
    ii := ci;

    if ic_is_any_mem_intrinsic(iid) {
        len := call_arg(ii, 2);
        if cf_is_int(len) {
            nb := const_ap(len);
            if ap_is_zero(nb) return ic_erase_inst(ci);
            if ic_mem_is_atomic(iid) {
                es := const_int_zext(call_arg(ii, 3));
                if ap_is_negative(nb) || ap_zext_value(nb) % es != 0 {
                    ic_create_non_terminator_unreachable(ii);
                    return ic_erase_inst(ii);
                }
            }
        }
        if ic_mem_is_volatile(ii) return NONE;
        if ic_is_any_mem_transfer(iid) && strip_pointer_casts(call_arg(ii, 1)) == strip_pointer_casts(call_arg(ii, 0)) return ic_erase_inst(ci);
        is_pointer_undefined :: (p: Value_Id) -> bool {
            return vkind(p) == .C_NULL && !null_pointer_is_defined(ic.f, cast(u64) type_addrspace(vtype(p)));
        }
        src_undef := false;
        if ic_is_any_mem_transfer(iid) {
            r := ic_simplify_any_mem_transfer(ii); if r != NONE return r;
            src_undef = is_pointer_undefined(call_arg(ii, 1));
        } else if ic_is_any_mem_set(iid) {
            r := ic_simplify_any_mem_set(ii); if r != NONE return r;
        }
        if src_undef || is_pointer_undefined(call_arg(ii, 0)) {
            icb_assumption(icb_is_null(call_arg(ii, 2)));
            return ic_erase_inst(ci);
        }
        if ic_is_any_mem_move(iid) {
            src := strip_pointer_casts(call_arg(ii, 1));
            if vkind(src) == .GLOBAL_VAR && glob(src).is_const {
                mid := ifx ic_mem_is_atomic(iid) then IID_MEMCPY_ELEMENT_UNORDERED_ATOMIC else IID_MEMCPY;
                f := get_or_insert_intrinsic_declaration(mid, .[vtype(call_arg(ci, 0)), vtype(call_arg(ci, 1)), vtype(call_arg(ci, 2))]);
                call_set_called_function(ci, f);
                return ii;
            }
        }
    }
    {
        t := vtype(ii);
        if type_kind(t) == .VECTOR {
            vw := cast(u32) type_count(t);
            poison := ap_zero(vw);
            v := ic_simplify_demanded_vector_elts(ii, ap_all_ones(vw), *poison);
            if v != NONE {
                if v != ii return ic_replace_inst_uses_with(ii, v);
                return ii;
            }
        }
    }
    if ic_intrinsic_is_commutative(iid) {
        ok, a, b := ic_match_symmetric_pair(op(ii, 0), op(ii, 1));
        if ok {
            ic_replace_operand(ii, 0, a);
            ic_replace_operand(ii, 1, b);
            drop_poison_generating_annotations(ii);
            drop_ub_implying_attrs_and_metadata(ii);
            return ii;
        }
        r := ic_canonicalize_constant_arg0_to_arg1(ci);
        if r != NONE return r;
    }
    if !has_uses(ci) && is_constrained_fp_intrinsic(iid) {
        args: [..] Value_Id; args.allocator = temp;
        n := call_num_args(ci);
        if n > 0 for k: 0..n-1 array_add(*args, op(ci, k));
        q := ic_q(ci);
        v := try_constant_fold_call(ci, args, q);
        if v == NONE v = simplify_intrinsic_call(ci, args, q);
        if v != NONE return ic_erase_inst(ci);
    }

    r := ic_visit_intrinsic_switch(ii, iid);
    if r.done return r.v;

    if ic_is_safe_to_speculatively_execute_with_variable_replaced(ci) {
        n := call_arg_count(ii);
        for k: 0..cast(s64) n - 1 {
            o := call_arg(ii, cast(u32) k);
            if is_inst(o) && inst_op(o) == .SELECT {
                is_vector_cond := is_vector_type(vtype(op(o, 0)));
                if is_vector_cond && (!is_not_cross_lane_operation(ii) || !is_vector_type(vtype(ii))) continue;
                both := !is_vector_type(vtype(o)) && is_vector_type(vtype(ii));
                x := ic_fold_op_into_select(ii, o, false, both);
                if x != NONE return x;
            }
            if is_phi(o) {
                x := ic_fold_op_into_phi(ii, o);
                if x != NONE return x;
            }
        }
    }
    {
        x := ic_fold_shuffled_intrinsic_operands(ii); if x != NONE return x;
        rv := ic_fold_reversed_intrinsic_operands(ii); if rv != NONE return ic_replace_inst_uses_with(ii, rv);
        rr := ic_fold_idempotent_binary_intrinsic_recurrence(ii); if rr != NONE return ic_replace_inst_uses_with(ii, rr);
    }
    return ic_visit_call_base(ii);
}

// result of the intrinsic switch: `done` = LLVM returned from visitCallInst with `v`
Ic_Switch_Result :: struct { done: bool; v: Value_Id; }
brk :: () -> Ic_Switch_Result { r: Ic_Switch_Result; return r; }
sw_done :: (v: Value_Id) -> Ic_Switch_Result { r: Ic_Switch_Result; r.done = true; r.v = v; return r; }

ic_visit_intrinsic_switch :: (ii: Value_Id, iid: Intrinsic_Id) -> Ic_Switch_Result {
    done :: (v: Value_Id) -> Ic_Switch_Result { r: Ic_Switch_Result; r.done = true; r.v = v; return r; }
    ci := ii;
    f := call_called_function(ii);
    ty := vtype(ii);
    if iid == {
    case IID_OBJECTSIZE;
        inserted: [..] Value_Id; inserted.allocator = temp;
        v := lower_object_size_call(ii, ic_aa(), false, *inserted);
        if v != NONE {
            for inserted wl_add(it);
            return done(ic_replace_inst_uses_with(ci, v));
        }
        return done(NONE);
    case IID_ABS;
        opnd := call_arg(ii, 0);
        int_min_is_poison := is_one_value(call_arg(ii, 1));
        okn, x := pm_neg(opnd);
        if okn return done(create_call_fn(f, .[x, get_bool_c(int_min_is_poison || has_nsw(opnd))]));
        oks, c, tv, fv := pm_select(opnd);
        if oks {
            for side: 0..1 {
                a := ifx side == 0 then tv else fv; b := ifx side == 0 then fv else tv;
                okn2, x2 := pm_neg(a);
                if okn2 && b == x2 return done(create_call_fn(f, .[x2, call_arg(ii, 1)]));
            }
        }
        if has_one_use(opnd) && ic_is_binop(opnd, .MUL) {
            for side: 0..1 {
                x3 := op(opnd, cast(u32) side);
                oka, y := pm_intrinsic1(op(opnd, cast(u32) (1 - side)), IID_ABS);
                if !oka continue;
                nsw := has_nsw(opnd) && int_min_is_poison;
                xy := icb_mul(x3, y, "", false, nsw);
                return done(create_call_fn(f, .[xy, call_arg(ii, 1)]));
            }
        }
        known := ic_get_known_sign_or_zero(opnd, ic_q(ii));
        if known >= 0 {
            if known == 0 return done(ic_replace_inst_uses_with(ii, opnd));
            if int_min_is_poison return done(create_binop_flags(.SUB, const_null_value(vtype(opnd)), opnd, F_NSW));
            return done(create_neg(opnd));
        }
        if has_one_use(opnd) {
            okse, sx := pmi_cast(opnd, .SEXT);
            if okse {
                na := icb_binary_intrinsic(IID_ABS, sx, get_false(ir.t_i1));
                return done(create_cast(.ZEXT, na, ty));
            }
        }
        oksr, srx, src := pm_binop(opnd, .SREM);
        if oksr && is_inst(opnd) {
            okc, cv := pm_apint(src);
            if okc && ap_eq_u64(cv, 2) return done(create_binop(.AND, srx, const_int_of(ty, 1)));
        }
    case IID_UMIN; #through;
    case IID_UMAX; #through;
    case IID_SMAX; #through;
    case IID_SMIN;
        r := ic_visit_min_max(ii, iid);
        if r != NONE return done(r);
    case IID_SCMP;
        i0 := call_arg(ii, 0); i1 := call_arg(ii, 1);
        ok, l, r := pm_ob(i0, .SUB, F_NSW);
        if ok && is_inst(i0) && pm_zero(i1) return done(ic_replace_inst_uses_with(ci, icb_intrinsic_ret(ty, IID_SCMP, .[l, r])));
    case IID_BITREVERSE;
        opnd := call_arg(ii, 0);
        okz, x := pmi_cast(opnd, .ZEXT);
        if okz && is_int_or_int_vector_n(vtype(x), 1) {
            sb := ap_signed_min(scalar_bits(ii));
            return done(create_select(x, const_int_ap(ty, sb), const_null_value(ty)));
        }
        r := ic_fold_bit_order_cross_logic_op(opnd, IID_BITREVERSE);
        if r != NONE return done(r);
    case IID_BSWAP;
        opnd := call_arg(ii, 0);
        if has_one_use(opnd) && is_inst(opnd) && (inst_op(opnd) == .SHL || inst_op(opnd) == .LSHR) {
            x := op(opnd, 0); y := op(opnd, 1);
            bw := scalar_bits(opnd);
            if ic_masked_value_is_zero(y, ap_low_bits_set(bw, 3), ii) {
                ns := icb_unary_intrinsic(IID_BSWAP, x);
                inv: Opcode = ifx inst_op(opnd) == .SHL then .LSHR else .SHL;
                return done(create_binop(inv, ns, y));
            }
        }
        known := ic_known_bits(opnd, ii);
        lz := (kb_count_min_leading_zeros(known) / 8) * 8;
        tz := (kb_count_min_trailing_zeros(known) / 8) * 8;
        bw := kb_bits(known);
        if bw - lz - tz == 8 {
            if lz > tz return done(create_binop_flags(.SHL, opnd, const_int_of(vtype(opnd), cast(u64) (lz - tz)), F_NUW));
            return done(create_binop_flags(.LSHR, opnd, const_int_of(vtype(opnd), cast(u64) (tz - lz)), F_EXACT));
        }
        okt, tx := pmi_cast(opnd, .TRUNC);
        if okt {
            okb, x := pm_intrinsic1(tx, IID_BSWAP);
            if okb {
                c := scalar_bits(x) - bw;
                v := icb_lshr(x, const_int_of(vtype(x), cast(u64) c));
                return done(create_cast(.TRUNC, v, vtype(opnd)));
            }
        }
        r := ic_fold_bit_order_cross_logic_op(opnd, IID_BSWAP);
        if r != NONE return done(r);
        r = ic_match_bswap_or_bit_reverse(ii, false, true);
        if r != NONE return done(r);
    case IID_MASKED_LOAD;
        v := ic_simplify_masked_load(ii);
        if v != NONE return done(ic_replace_inst_uses_with(ci, v));
    case IID_MASKED_STORE; return done(ic_simplify_masked_store(ii));
    case IID_MASKED_GATHER; return done(ic_simplify_masked_gather(ii));
    case IID_MASKED_SCATTER; return done(ic_simplify_masked_scatter(ii));
    case IID_LAUNDER_INVARIANT_GROUP; #through;
    case IID_STRIP_INVARIANT_GROUP;
        s := ic_simplify_invariant_group_intrinsic(ii);
        if s != NONE return done(ic_replace_inst_uses_with(ii, s));
    case IID_POWI;
        power := call_arg(ii, 1);
        if cf_is_int(power) {
            pa := const_ap(power);
            if ap_is_all_ones(pa) return done(create_fop(.FDIV, fp_from_double(ty, 1.0), call_arg(ii, 0), ii));
            if ap_eq_u64(pa, 2) return done(create_fop(.FMUL, call_arg(ii, 0), call_arg(ii, 0), ii));
            if !ap_get_bit(pa, 0) {
                a0 := call_arg(ii, 0);
                ok, x := pm_fneg(a0);
                if !ok ok, x = pm_fabs(a0);
                if !ok { okc, cx, cy := pm_intrinsic2(a0, IID_COPYSIGN); ok = okc; x = cx; }
                if ok return done(create_call_fn(f, .[x, power]));
            }
        }
        base := call_arg(ii, 0);
        if vkind(base) == .C_FP {   // dyn_cast<ConstantFP>: also a vector-typed splat
            e := call_arg(ii, 1);
            if (get_fmf(ii) & FMF_AFN) != 0 && pm_specific_fp(base, 2.0) {
                one := fp_from_double(vtype(base), 1.0);
                if is_vector_type(vtype(base)) e = icb_vector_splat(type_count(vtype(base)), type_kind(vtype(base)) == .SVECTOR, e);
                ldexp := icb_ldexp(one, e, get_fmf(ii));
                return done(ic_replace_inst_uses_with(ii, ldexp));
            }
        }
    case IID_CTTZ; #through;
    case IID_CTLZ;
        r := ic_fold_cttz_ctlz(ii);
        if r != NONE return done(r);
    case IID_CTPOP;
        r := ic_fold_ctpop(ii);
        if r != NONE return done(r);
    case IID_FSHL; #through;
    case IID_FSHR;
        return ic_visit_funnel_shift(ii, iid);
    case IID_PDEP;
        okm, mc := pm_apint(call_arg(ii, 1));
        if okm && ap_is_shifted_mask(mc) {
            idx := ap_ctz(mc);
            sh := icb_shl(call_arg(ii, 0), const_int_of(ty, cast(u64) idx));
            m := icb_and(sh, call_arg(ii, 1));
            return done(ic_replace_inst_uses_with(ii, m));
        }
    case IID_PEXT;
        okm, mc := pm_apint(call_arg(ii, 1));
        if okm && ap_is_shifted_mask(mc) {
            idx := ap_ctz(mc);
            m := icb_and(call_arg(ii, 0), call_arg(ii, 1));
            sh := icb_lshr(m, const_int_of(ty, cast(u64) idx));
            return done(ic_replace_inst_uses_with(ii, sh));
        }
    case IID_PTRMASK;
        bw := cast(u32) dl_pointer_type_size_bits(ty);
        known := kb_new(bw);
        if ic_simplify_demanded_instruction_bits_known(ii, *known) return done(ii);
        changed := false;
        a0 := call_arg(ii, 0);
        if has_one_use(a0) {
            ok, ip, im := pm_intrinsic2(a0, IID_PTRMASK);
            if ok {
                nm := icb_and(call_arg(ii, 1), im);
                ic_replace_operand(ci, 0, ip);
                ic_replace_operand(ci, 1, nm);
                changed = true;
            }
        }
        if !call_has_ret_attr(ci, .NonNull) && (kb_is_non_zero(known) || is_known_non_zero(ii, ic_q(ii))) {
            call_add_ret_attr_kind(ci, .NonNull);
            changed = true;
        }
        nal := min(32, min(bw - 1, kb_count_min_trailing_zeros(known)));
        cur := call_ret_align(ci); if cur == 0 cur = 1;
        if (cast(u64) 1 << nal) > cur {
            call_add_ret_int_attr(ci, .Alignment, cast(u64) 1 << nal);
            changed = true;
        }
        if changed return done(ci);
    case IID_UADD_WITH_OVERFLOW; #through;
    case IID_SADD_WITH_OVERFLOW;
        r := ic_fold_intrinsic_with_overflow_common(ii);
        if r != NONE return done(r);
        a0 := call_arg(ii, 0); a1 := call_arg(ii, 1);
        is_signed := iid == IID_SADD_WITH_OVERFLOW;
        ok, x, c0v := pm_nuw_add_like_i(a0);
        if is_signed ok, x, c0v = pm_nsw_add_like_i(a0);
        okc0, c0 := pm_apint(c0v);
        okc1, c1 := pm_apint(a1);
        if ok && okc0 && okc1 {
            nc: APInt; ov: bool;
            if is_signed nc, ov = ap_sadd_ov(c1, c0); else nc, ov = ap_uadd_ov(c1, c0);
            if !ov return done(ic_replace_inst_uses_with(ii, icb_binary_intrinsic(iid, x, const_int_ap(vtype(a1), nc))));
        }
    case IID_UMUL_WITH_OVERFLOW; #through;
    case IID_SMUL_WITH_OVERFLOW; #through;
    case IID_USUB_WITH_OVERFLOW;
        r := ic_fold_intrinsic_with_overflow_common(ii);
        if r != NONE return done(r);
    case IID_SSUB_WITH_OVERFLOW;
        r := ic_fold_intrinsic_with_overflow_common(ii);
        if r != NONE return done(r);
        a1 := call_arg(ii, 1);
        if is_const(a1) && ic_is_not_min_signed_value(a1) {
            nv := ce_neg(a1);
            return done(ic_replace_inst_uses_with(ii, icb_binary_intrinsic(IID_SADD_WITH_OVERFLOW, call_arg(ii, 0), nv)));
        }
    case IID_UADD_SAT; #through; case IID_SADD_SAT; #through; case IID_USUB_SAT; #through; case IID_SSUB_SAT;
        return ic_visit_sat(ii, iid);
    case IID_MINNUM; #through; case IID_MAXNUM; #through; case IID_MINIMUMNUM; #through; case IID_MAXIMUMNUM; #through;
    case IID_MINIMUM; #through; case IID_MAXIMUM;
        return ic_visit_fp_min_max(ii, iid);
    case IID_MATRIX_MULTIPLY;
        return ic_visit_matrix_multiply(ii, iid);
    case IID_FMULADD; #through;
    case IID_FMA;
        if iid == IID_FMULADD {
            v := simplify_fmul_inst(call_arg(ii, 0), call_arg(ii, 1), get_fmf(ii), ic_q(ii));
            if v != NONE return done(create_binop_fmf(.FADD, v, call_arg(ii, 2), get_fmf(ii)));
        }
        s0 := call_arg(ii, 0); s1 := call_arg(ii, 1); s2 := call_arg(ii, 2);
        okx, x := pm_fneg(s0); oky, y := pm_fneg(s1);
        if okx && oky return done(ic_replace_inst_uses_with(ii, icb_intrinsic(iid, .[ty], .[x, y, s2], "", ii)));
        okx, x = pm_fabs(s0); oky, y = pm_fabs(s1);
        if okx && oky && x == y return done(ic_replace_inst_uses_with(ii, icb_intrinsic(iid, .[ty], .[x, x, s2], "", ii)));
        v := simplify_fma_fmul(s0, s1, get_fmf(ii), ic_q(ii));
        if v != NONE return done(create_binop_fmf(.FADD, v, s2, get_fmf(ii)));
        if pm_neg_zero_fp(s2) || (pm_pos_zero_fp(s2) && (get_fmf(ii) & FMF_NSZ) != 0) return done(create_fop(.FMUL, s0, s1, ii));
        if pm_specific_fp(s1, -1.0) return done(create_fop(.FSUB, s2, s0, ii));
    case IID_COPYSIGN;
        return ic_visit_copysign(ii);
    case IID_FABS;
        arg := call_arg(ii, 0);
        okn, x := pm_fneg(arg);
        if okn return done(ic_replace_inst_uses_with(ci, icb_fabs(x, ii)));
        oks, cnd, tv, fv := pm_select(arg);
        if oks {
            if ifx has_one_use(arg) then (is_const(tv) || is_const(fv)) else (is_const(tv) && is_const(fv)) {
                abs_t := icb_call_fn(f, .[tv]);
                abs_f := icb_call_fn(f, .[fv]);
                si := create_select(cnd, abs_t, abs_f);
                set_fmf(si, (get_fmf(ii) | get_fmf(arg)) & ~cast(u32) FMF_NSZ);
                return done(si);
            }
            okn2, x2 := pm_fneg(tv);
            if okn2 && x2 == fv return done(ic_replace_inst_uses_with(ii, icb_fabs(fv, ii)));
            okn3, x3 := pm_fneg(fv);
            if okn3 && x3 == tv return done(ic_replace_inst_uses_with(ii, icb_fabs(tv, ii)));
        }
        okc, mag, sign := pm_intrinsic2(call_arg(ii, 0), IID_COPYSIGN);
        if okc return done(ic_replace_inst_uses_with(ii, icb_fabs(mag, ii)));
        r := ic_narrow_fp_unary_through_fpext(ii, iid);
        if r != NONE return done(r);
    case IID_CEIL; #through; case IID_FLOOR; #through; case IID_ROUND; #through; case IID_ROUNDEVEN; #through;
    case IID_NEARBYINT; #through; case IID_RINT; #through; case IID_TRUNC;
        r := ic_narrow_fp_unary_through_fpext(ii, iid);
        if r != NONE return done(r);
    case IID_COS; #through; case IID_COSH;
        src := call_arg(ii, 0);
        ok, x := pm_fneg(src);
        if !ok ok, x = pm_fabs(src);
        if !ok { okc, cx, cy := pm_intrinsic2(src, IID_COPYSIGN); ok = okc; x = cx; }
        if ok return done(ic_replace_inst_uses_with(ii, icb_unary_intrinsic(iid, x, "", ii)));
    case IID_SIN; #through; case IID_SINH; #through; case IID_TAN; #through; case IID_TANH;
        a0 := call_arg(ii, 0);
        ok, x := pm_fneg(a0);
        if ok && has_one_use(a0) {
            nf := icb_unary_intrinsic(iid, x, "", ii);
            return done(create_fneg_fmf(nf, ii));
        }
    case IID_LDEXP;
        return ic_visit_ldexp(ii);
    case IID_PTRAUTH_AUTH; #through; case IID_PTRAUTH_RESIGN;
        fatal("instcombine: ptrauth intrinsics are not supported yet");
    case IID_STACKRESTORE;
        return ic_visit_stackrestore(ii);
    case IID_LIFETIME_END;
        fn := inst_fn(ii);
        if fn_has_fn_attr(fn, .SanitizeAddress) || fn_has_fn_attr(fn, .SanitizeMemory) || fn_has_fn_attr(fn, .SanitizeHWAddress) || fn_has_fn_attr(fn, .SanitizeMemTag) return brk();
        is_start :: (x: Value_Id, e: Value_Id) -> bool { return call_iid(x) == IID_LIFETIME_START; }
        if ic_remove_trivially_empty_range(ii, is_start) return done(NONE);
    case IID_ASSUME;
        return ic_visit_assume(ii);
    case IID_EXPERIMENTAL_GUARD;
        next_inst := inst(ii).next;
        for 0..GUARD_WIDENING_WINDOW-1 {
            if !ic_is_safe_to_speculatively_execute_no_cxt(next_inst) break;
            next_inst = inst(next_inst).next;
        }
        if call_iid(next_inst) == IID_EXPERIMENTAL_GUARD {
            next_cond := call_arg(next_inst, 0);
            curr := call_arg(ii, 0);
            if curr != next_cond {
                mv := inst(ii).next;
                while mv != next_inst {
                    t := mv; mv = inst(mv).next;
                    inst_move_before_dbg(t, ii);   // Temp->moveBefore(II->getIterator())
                }
                ic_replace_operand(ii, 0, icb_and(curr, next_cond));
            }
            ic_erase_inst(next_inst);
            return done(ii);
        }
    case IID_VECTOR_INSERT;
        return ic_visit_vector_insert(ii);
    case IID_VECTOR_EXTRACT;
        return ic_visit_vector_extract(ii);
    case IID_EXPERIMENTAL_VP_REVERSE;
        fatal("instcombine: llvm.experimental.vp.reverse is not supported yet");
    case IID_VECTOR_REDUCE_OR; #through; case IID_VECTOR_REDUCE_AND; #through; case IID_VECTOR_REDUCE_ADD; #through;
    case IID_VECTOR_REDUCE_XOR; #through; case IID_VECTOR_REDUCE_MUL; #through; case IID_VECTOR_REDUCE_UMIN; #through;
    case IID_VECTOR_REDUCE_UMAX; #through; case IID_VECTOR_REDUCE_SMIN; #through; case IID_VECTOR_REDUCE_SMAX; #through;
    case IID_VECTOR_REDUCE_FMAX; #through; case IID_VECTOR_REDUCE_FMIN; #through; case IID_VECTOR_REDUCE_FADD; #through;
    case IID_VECTOR_REDUCE_FMUL;
        return ic_visit_reduction(ii, iid);
    case IID_IS_FPCLASS;
        r := ic_fold_intrinsic_is_fpclass(ii);
        if r != NONE return done(r);
    case IID_THREADLOCAL_ADDRESS;
        min_align := ic_get_known_alignment(call_arg(ii, 0), ii);
        al := call_ret_align(ii); if al == 0 al = 1;
        if min_align > al { call_add_ret_int_attr(ii, .Alignment, min_align); return done(ii); }
    case IID_FPTOUI_SAT; #through; case IID_FPTOSI_SAT;
        r := ic_fold_itofp_to_i(ii, true);
        if r != NONE return done(r);
    case IID_FREXP;
        okx, fx := pm_extract_value_idx(call_arg(ii, 0), 0);
        if okx && call_iid(fx) == IID_FREXP {
            res := icb_insert_value(const_poison(ty), call_arg(ii, 0), .[0]);
            res = icb_insert_value(res, const_null_value(type_sub(ty, 1)), .[1]);
            return done(ic_replace_inst_uses_with(ii, res));
        }
    case IID_GET_ACTIVE_LANE_MASK;
        ok0, o0 := pm_apint_pred(op(ii, 0), ap_is_strictly_positive);
        ok1, o1 := pm_apint(op(ii, 1));
        if ok0 && ok1 {
            opty := vtype(op(ii, 0));
            return done(ic_replace_inst_uses_with(ii, icb_intrinsic_ret(ty, IID_GET_ACTIVE_LANE_MASK, .[const_null_value(opty), const_int_ap(opty, ap_usub_sat(o1, o0))])));
        }
    case IID_EXPERIMENTAL_GET_VECTOR_LENGTH;
        a0 := call_arg(ii, 0);
        bw := max(scalar_bits(a0), scalar_bits(ii));
        cnt := cr_zext_or_trunc(compute_constant_range_including_known_bits(a0, false, ic_q(ii)), bw);
        ml := cr_single(ap_zext_or_trunc(const_ap(call_arg(ii, 1)), bw));
        if is_one_value(call_arg(ii, 2)) ml = cr_multiply(ml, get_vscale_range(inst_fn(ii), bw));
        if cr_icmp(cnt, ICMP_ULE, ml) return done(ic_replace_inst_uses_with(ii, icb_zext_or_trunc(a0, ty)));
        return done(NONE);
    case;
        v, handled := ic_target_inst_combine_intrinsic(ii);
        if handled return done(v);
    }
    return brk();
}
get_bool_c :: (b: bool) -> Value_Id { return ifx b then get_true(ir.t_i1) else get_false(ir.t_i1); }
// Constant::isNotMinSignedValue
ic_is_not_min_signed_value :: (c: Value_Id) -> bool {
    if vkind(c) == .C_INT && !is_vector_type(vtype(c)) return !ap_is_min_signed(const_ap(c));
    if is_vector_type(vtype(c)) {
        s := get_splat_value(c);
        if s != NONE && vkind(s) == .C_INT return !ap_is_min_signed(const_ap(s));
        if type_kind(vtype(c)) == .VECTOR {
            for k: 0..cast(s64) type_count(vtype(c)) - 1 {
                e := cf_elt(c, cast(u64) k);
                if e == NONE || !ic_is_not_min_signed_value(e) return false;
            }
            return true;
        }
    }
    if is_int_type(scalar_type(vtype(c))) && (vkind(c) == .C_ZERO) return true;
    return false;
}

// case umin / umax / smax / smin (with LLVM's fallthroughs)
ic_visit_min_max :: (ii: Value_Id, iid: Intrinsic_Id) -> Value_Id {
    ci := ii;
    ty := vtype(ii);
    if iid == IID_UMIN {
        i0 := call_arg(ii, 0); i1 := call_arg(ii, 1);
        if pm_one(i1) {
            cmp := icb_cmp(ICMP_NE, i0, const_null_value(vtype(i0)));
            return create_cast(.ZEXT, cmp, ty);
        }
        fc := ic_fold_minimum_over_tz_lz(i0, i1, IID_CTTZ);
        if fc != NONE return ic_replace_inst_uses_with(ii, fc);
        fl := ic_fold_minimum_over_tz_lz(i0, i1, IID_CTLZ);
        if fl != NONE return ic_replace_inst_uses_with(ii, fl);
    }
    if iid == IID_UMIN || iid == IID_UMAX {
        i0 := call_arg(ii, 0); i1 := call_arg(ii, 1);
        okx, x := pmi_cast(i0, .ZEXT); oky, y := pmi_cast(i1, .ZEXT);
        if okx && oky && (has_one_use(i0) || has_one_use(i1)) && vtype(x) == vtype(y) {
            nmm := icb_binary_intrinsic(iid, x, y);
            return create_cast(.ZEXT, nmm, ty);
        }
        if okx && is_const(i1) && has_one_use(i0) {
            nc := get_lossless_unsigned_trunc(i1, vtype(x));
            if nc != NONE {
                nmm := icb_binary_intrinsic(iid, x, nc);
                return create_cast(.ZEXT, nmm, ty);
            }
        }
        fold_max_mul_shift :: (a: Value_Id, b: Value_Id, ii: Value_Id) -> Value_Id {
            ok, x, cv := pm_ob(a, .SHL, F_NUW);
            okc: bool; c: APInt;
            if ok && is_inst(a) okc, c = pm_apint(cv);
            if !(ok && is_inst(a) && okc) {
                ok, x, cv = pm_ob(a, .MUL, F_NUW);
                if !(ok && is_inst(a)) return NONE;
                okc, c = pm_apint(cv);
                if !okc || ap_is_one(c) return NONE;
            }
            if ap_is_zero(c) return NONE;
            okb, bx, one := pm_binop(b, .ADD);
            if !okb || !is_inst(b) || !has_one_use(b) || bx != x || !pm_one(one) return NONE;
            cmp := icb_cmp(ICMP_EQ, x, const_int_of(vtype(x), 0));
            sel := ic_create_select_unknown_profile(cmp, const_int_of(vtype(x), 1), a);
            sel = icb_insert(sel);
            return ic_replace_inst_uses_with(ii, sel);
        }
        if iid == IID_UMAX {
            r := fold_max_mul_shift(i0, i1, ii); if r != NONE return r;
            r = fold_max_mul_shift(i1, i0, ii); if r != NONE return r;
        }
    }
    i0 := call_arg(ii, 0); i1 := call_arg(ii, 1);
    {
        okx, x := pmi_cast(i0, .SEXT); oky, y := pmi_cast(i1, .SEXT);
        if okx && oky && (has_one_use(i0) || has_one_use(i1)) && vtype(x) == vtype(y) {
            nmm := icb_binary_intrinsic(iid, x, y);
            return create_cast(.SEXT, nmm, ty);
        }
        if okx && is_const(i1) && has_one_use(i0) {
            nc := get_lossless_signed_trunc(i1, vtype(x));
            if nc != NONE {
                nmm := icb_binary_intrinsic(iid, x, nc);
                return create_cast(.SEXT, nmm, ty);
            }
        }
    }
    canonical_clamp :: (ii: Value_Id, is_signed: bool, x: Value_Id, max_c: APInt, min_c: APInt) -> Value_Id {
        max_id := ifx is_signed then IID_SMAX else IID_UMAX;
        min_id := ifx is_signed then IID_SMIN else IID_UMIN;
        nmax := icb_binary_intrinsic(max_id, x, const_int_ap(vtype(x), max_c));
        return ic_replace_inst_uses_with(ii, icb_binary_intrinsic(min_id, nmax, const_int_ap(vtype(x), min_c)));
    }
    if (iid == IID_SMAX || iid == IID_UMAX) && has_one_use(i0) {
        inner := ifx iid == IID_SMAX then IID_SMIN else IID_UMIN;
        ok, x, mcv := pm_intrinsic2(i0, inner);
        if ok {
            okm, min_c := pm_apint(mcv);
            okx, max_c := pm_apint(i1);
            if okm && okx && (ifx iid == IID_SMAX then ap_sgt(min_c, max_c) else ap_ugt(min_c, max_c))
                return canonical_clamp(ii, iid == IID_SMAX, x, max_c, min_c);
        }
    }
    if (iid == IID_UMIN || iid == IID_SMAX) && is_int_or_int_vector_n(ty, 1) return create_binop(.AND, i0, i1);
    if (iid == IID_UMAX || iid == IID_SMIN) && is_int_or_int_vector_n(ty, 1) return create_binop(.OR, i0, i1);
    if iid == IID_SMIN && has_one_use(i0) {
        ok, x, ao := ic_pm_min_max_lr(i0, IID_SMAX);
        if ok && pm_all_ones(ao) && pm_one(i1) {
            zero := const_int_of(vtype(x), 0);
            return ic_replace_inst_uses_with(ci, icb_intrinsic_ret(ty, IID_SCMP, .[x, zero]));
        }
    }
    if iid == IID_SMAX || iid == IID_SMIN {
        okx, x := pm_nsw_neg(i0); oky, y := pm_nsw_neg(i1);
        if okx && oky && (has_one_use(i0) || has_one_use(i1)) {
            inv := inverse_min_max_intrinsic(iid);
            imm := icb_binary_intrinsic(inv, x, y);
            return create_binop_flags(.SUB, const_null_value(vtype(imm)), imm, F_NSW);
        }
    }
    {
        x: Value_Id = NONE;
        if ic_is_binop(i0, .XOR) {
            if op(i0, 0) == i1 x = op(i0, 1); else if op(i0, 1) == i1 x = op(i0, 0);
        }
        if x == NONE && ic_is_binop(i1, .XOR) {
            if op(i1, 0) == i0 x = op(i1, 1); else if op(i1, 1) == i0 x = op(i1, 0);
        }
        if x != NONE && is_known_to_be_a_power_of_two(x, true, ic.sq) {
            use_or := iid == IID_SMAX || iid == IID_UMAX;
            use_and_n := iid == IID_SMIN || iid == IID_UMIN;
            if iid == IID_SMAX || iid == IID_SMIN {
                ks := ic_get_known_sign(x, ic_q(ii));
                if ks < 0 { use_or = false; use_and_n = false; }
                else if ks == 1 {
                    use_or = !use_or; use_and_n = !use_and_n;
                    t := vtype(i0);
                    x = const_int_ap(t, ap_signed_min(scalar_bits(i0)));
                }
            }
            if use_or return create_binop(.OR, i0, x);
            else if use_and_n return create_binop(.AND, i0, icb_not(x));
        }
    }
    move_not_after_min_max :: (x: Value_Id, y: Value_Id, iid: Intrinsic_Id) -> Value_Id {
        if !has_one_use(x) return NONE;
        okn, a := pm_not(x);
        if !okn return NONE;
        free, dc := ic_is_free_to_invert(a, has_one_use(a));
        if free return NONE;
        not_y, dc2 := ic_get_freely_inverted(y, has_one_use(y), true);
        if not_y == NONE return NONE;
        inv := inverse_min_max_intrinsic(iid);
        imm := icb_binary_intrinsic(inv, a, not_y);
        return create_not(imm);
    }
    r := move_not_after_min_max(i0, i1, iid); if r != NONE return r;
    r = move_not_after_min_max(i1, i0, iid); if r != NONE return r;
    r = ic_move_add_after_min_max(ii); if r != NONE return r;
    if has_one_use(i0) && ic_is_binop(i0, .AND) && has_one_use(i1) && ic_is_binop(i1, .AND) {
        okc, rhsc := pm_apint_pred(op(i0, 1), ap_is_negated_power_of_2);
        if okc && pm_specific_int_ap(op(i1, 1), rhsc) {
            return create_binop(.AND, icb_binary_intrinsic(iid, op(i0, 0), op(i1, 0)), const_int_ap(ty, rhsc));
        }
    }
    a0 := i0; a1 := i1;
    if is_known_negation(a0, a1) {
        if has_one_use(a0) && !has_one_use(a1) { t := a0; a0 = a1; a1 = t; }
        imp := is_known_negation(a0, a1, true);
        abs := icb_binary_intrinsic(IID_ABS, a0, get_bool_c(imp));
        if iid == IID_SMIN || iid == IID_UMAX abs = icb_neg(abs, "nabs", imp);
        return ic_replace_inst_uses_with(ci, abs);
    }
    r = ic_fold_clamp_range_of_two(ii); if r != NONE return r;
    r = ic_match_sadd_sub_sat(ii); if r != NONE return r;
    nmm := ic_reassociate_min_max_with_constants(ii, ic.sq);
    if nmm != NONE return ic_replace_inst_uses_with(ii, nmm);
    r = ic_reassociate_min_max_with_constant_in_operand(ii); if r != NONE return r;
    r = ic_factorize_min_max_tree(ii); if r != NONE return r;
    okr, rhsc := pm_apint(i1, true);
    if okr {
        pred := cmp_non_strict(ic_mm_predicate(iid));
        is_signed := ic_mm_is_signed(iid);
        lcr := compute_constant_range_including_known_bits(i0, is_signed, ic_q(ii));
        if !cr_is_full_set(lcr) {
            rc := cr_single(rhsc);
            if cr_icmp(lcr, pred, rc) return ic_replace_inst_uses_with(ii, i0);
            if cr_icmp(lcr, swapped_predicate(pred), rc) return ic_replace_inst_uses_with(ii, const_int_ap(ty, rhsc));
        }
    }
    v := ic_fold_intrinsic_using_distributive_laws(ii);
    if v != NONE return ic_replace_inst_uses_with(ii, v);
    return NONE;
}

// case fshl / fshr
ic_visit_funnel_shift :: (ii: Value_Id, iid: Intrinsic_Id) -> Ic_Switch_Result {
    op0 := call_arg(ii, 0); op1 := call_arg(ii, 1);
    ty := vtype(ii);
    bw := scalar_bits(ii);
    sh_amt_c := call_arg(ii, 2);
    if pm_imm_constant(sh_amt_c) {
        width_c := const_int_of(ty, cast(u64) bw);
        modulo_c := cfo_binary_op_operands(.UREM, sh_amt_c, width_c);
        if modulo_c == NONE return sw_done(NONE);
        if modulo_c != sh_amt_c return sw_done(create_call_fn(call_called_function(ii), .[op0, op1, modulo_c]));
        if iid == IID_FSHR {
            if !is_known_non_zero(sh_amt_c, ic_q(ii)) return sw_done(NONE);
            left := ce_binop(.SUB, width_c, sh_amt_c, 0);
            return sw_done(create_intrinsic_call(IID_FSHL, .[ty], .[op0, op1, left]));
        }
        if pm_zero_int(op1) || pm_undef(op1) return sw_done(create_binop(.SHL, op0, sh_amt_c));
        if pm_zero_int(op0) || pm_undef(op0) return sw_done(create_binop(.LSHR, op1, ce_binop(.SUB, width_c, sh_amt_c, 0)));
        if op0 == op1 && bw == 16 && pm_specific_int(sh_amt_c, 8) return sw_done(create_intrinsic_call(IID_BSWAP, .[ty], .[op0]));
        r := ic_match_bswap_or_bit_reverse(ii, true, true);
        if r != NONE return sw_done(r);
        if call_iid(op0) == IID_FSHL && call_arg(op0, 0) == call_arg(op0, 1) && op0 == op1 {
            inner := call_arg(op0, 0);
            oki, ic_amt := pm_apint(call_arg(op0, 2));
            oko, oc_amt := pm_apint(sh_amt_c);
            if oki && oko {
                sum := ap_add(oc_amt, ic_amt);
                modulo := ap_urem(sum, ap_from_u64(sum.bits, cast(u64) bw));
                if ap_is_zero(modulo) return sw_done(ic_replace_inst_uses_with(ii, inner));
                return sw_done(create_call_fn(call_called_function(op0), .[inner, inner, const_int_ap(ty, modulo)]));
            }
        }
    }
    if op0 == op1 && ic_is_pow2(cast(u64) bw) {
        okn, y := pm_neg(call_arg(ii, 2));
        if okn return sw_done(create_intrinsic_call(ifx iid == IID_FSHL then IID_FSHR else IID_FSHL, .[ty], .[op0, op1, y]));
    }
    if iid == IID_FSHL && ic_is_pow2(cast(u64) bw) && pm_zero_int(op1) {
        and := icb_and(call_arg(ii, 2), const_int_of(ty, cast(u64) bw - 1));
        return sw_done(create_binop(.SHL, op0, and));
    }
    if ic_simplify_demanded_instruction_bits(ii) return sw_done(ii);
    if !ic_is_pow2(cast(u64) bw) return brk();
    dem := ap_low_bits_set(bw, cast(u32) log2_ceil_u64(cast(u64) bw));
    known := kb_new(bw);
    if ic_simplify_demanded_bits(ii, 2, dem, *known, ic_q(ii), 0) return sw_done(ii);
    return brk();
}

// case uadd.sat / sadd.sat / usub.sat / ssub.sat
ic_visit_sat :: (ii: Value_Id, iid: Intrinsic_Id) -> Ic_Switch_Result {
    ty := vtype(ii);
    a0 := call_arg(ii, 0); a1 := call_arg(ii, 1);
    is_signed := iid == IID_SADD_SAT || iid == IID_SSUB_SAT;
    opc: Opcode = ifx iid == IID_UADD_SAT || iid == IID_SADD_SAT then .ADD else .SUB;
    or := ic_compute_overflow(opc, is_signed, a0, a1, ii);
    bw := scalar_bits(ii);
    if or == {
        case .NEVER_OVERFLOWS;
            return sw_done(create_binop_flags(opc, a0, a1, ifx is_signed then cast(u32) F_NSW else F_NUW));
        case .ALWAYS_OVERFLOWS_LOW;
            mn := ifx is_signed then ap_signed_min(bw) else ap_zero(bw);
            return sw_done(ic_replace_inst_uses_with(ii, const_int_ap(ty, mn)));
        case .ALWAYS_OVERFLOWS_HIGH;
            mx := ifx is_signed then ap_signed_max(bw) else ap_all_ones(bw);
            return sw_done(ic_replace_inst_uses_with(ii, const_int_ap(ty, mx)));
    }
    if iid == IID_USUB_SAT {
        ok, c, a := pm_ob(a0, .SUB, F_NUW);
        if ok && is_inst(a0) && pm_imm_constant(c) && pm_imm_constant(a1) {
            nc := icb_binary_intrinsic(IID_USUB_SAT, c, a1);
            ns := icb_binary_intrinsic(IID_USUB_SAT, nc, a);
            return sw_done(ic_replace_inst_uses_with(ii, ns));
        }
    }
    if iid == IID_SSUB_SAT && is_const(a1) && ic_is_not_min_signed_value(a1) {
        nv := ce_neg(a1);
        return sw_done(ic_replace_inst_uses_with(ii, icb_binary_intrinsic(IID_SADD_SAT, a0, nv)));
    }
    if call_iid(a0) == iid {
        other := a0;
        okv, val := pm_apint(a1);
        x := call_arg(other, 0);
        okv2, val2 := pm_apint(call_arg(other, 1));
        if okv && okv2 {
            is_unsigned := iid == IID_UADD_SAT || iid == IID_USUB_SAT;
            nv: APInt;
            if is_unsigned nv = ap_uadd_sat(val, val2);
            else if ap_is_non_negative(val) == ap_is_non_negative(val2) {
                ov: bool;
                nv, ov = ap_sadd_ov(val, val2);
                if ov return brk();
            } else return brk();
            return sw_done(ic_replace_inst_uses_with(ii, icb_binary_intrinsic(iid, x, const_int_ap(ty, nv))));
        }
    }
    return brk();
}

// case minnum / maxnum / minimumnum / maximumnum / minimum / maximum
ic_visit_fp_min_max :: (ii: Value_Id, iid: Intrinsic_Id) -> Ic_Switch_Result {
    a0 := call_arg(ii, 0); a1 := call_arg(ii, 1);
    okx, x := pm_fneg(a0); oky, y := pm_fneg(a1);
    if okx && oky && (has_one_use(a0) || has_one_use(a1)) {
        nid: Intrinsic_Id;
        if iid == {
            case IID_MAXNUM; nid = IID_MINNUM; case IID_MINNUM; nid = IID_MAXNUM;
            case IID_MAXIMUMNUM; nid = IID_MINIMUMNUM; case IID_MINIMUMNUM; nid = IID_MAXIMUMNUM;
            case IID_MAXIMUM; nid = IID_MINIMUM; case IID_MINIMUM; nid = IID_MAXIMUM;
        }
        nc := icb_binary_intrinsic(nid, x, y, "", ii);
        fneg := new_inst(.FNEG, vtype(nc), 1);
        set_op(fneg, 0, nc);
        copy_ir_flags(fneg, ii);
        return sw_done(fneg);
    }
    if call_iid(a0) == iid {
        m := a0;
        okc1, c1 := pm_apfloat(a1);
        if okc1 {
            mx: Value_Id = NONE; c2: APFloat; okc2 := false;
            okc2, c2 = pm_apfloat(call_arg(m, 1));
            if okc2 mx = call_arg(m, 0);
            else { okc2, c2 = pm_apfloat(call_arg(m, 0)); if okc2 mx = call_arg(m, 1); }
            if okc2 {
                res: APFloat;
                if iid == {
                    case IID_MAXNUM; res = apf_maxnum(c1, c2); case IID_MINNUM; res = apf_minnum(c1, c2);
                    case IID_MAXIMUMNUM; res = apf_maximumnum(c1, c2); case IID_MINIMUMNUM; res = apf_minimumnum(c1, c2);
                    case IID_MAXIMUM; res = apf_maximum(c1, c2); case IID_MINIMUM; res = apf_minimum(c1, c2);
                }
                v := icb_binary_intrinsic_fmf(iid, mx, ic_const_fp(vtype(a0), res), get_fmf(ii) & get_fmf(m));
                return sw_done(ic_replace_inst_uses_with(ii, v));
            }
        }
    }
    okx, x = pmi_cast(a0, .FPEXT); oky, y = pmi_cast(a1, .FPEXT);
    if okx && oky && (has_one_use(a0) || has_one_use(a1)) && vtype(x) == vtype(y) {
        nc := icb_binary_intrinsic(iid, x, y, vname(ii), ii);
        return sw_done(create_cast(.FPEXT, nc, vtype(ii)));
    }
    okx, x = pmi_cast(a0, .FPEXT);
    if okx && has_one_use(a0) && pm_imm_constant(a1) {
        tc := get_lossless_inv_cast(a1, vtype(x), .FPEXT);
        if tc != NONE {
            nc := icb_binary_intrinsic(iid, x, tc, vname(ii), ii);
            return sw_done(create_cast(.FPEXT, nc, vtype(ii)));
        }
    }
    is_min := iid == IID_MINIMUM || iid == IID_MINNUM || iid == IID_MINIMUMNUM;
    xv: Value_Id = NONE;
    for side: 0..1 {
        o0 := ifx side == 0 then a0 else a1; o1 := ifx side == 0 then a1 else a0;
        okn, nx := pm_fneg(o0);
        if okn && o1 == nx && (has_one_use(o0) || !is_min) { xv = nx; break; }
    }
    if xv != NONE {
        r := icb_fabs(xv, ii);
        if is_min r = icb_fneg(r, "", ii);
        return sw_done(ic_replace_inst_uses_with(ii, r));
    }
    return brk();
}

// case matrix_multiply
ic_visit_matrix_multiply :: (ii: Value_Id, iid: Intrinsic_Id) -> Ic_Switch_Result {
    oka, a := pm_fneg(call_arg(ii, 0)); okb, b := pm_fneg(call_arg(ii, 1));
    if oka && okb {
        ic_replace_operand(ii, 0, a);
        ic_replace_operand(ii, 1, b);
        return sw_done(ii);
    }
    op0 := op(ii, 0); op1 := op(ii, 1);
    neg_arg: u32; other_arg: u32; not_neg: Value_Id; neg_op: Value_Id;
    ok0, n0 := pm_fneg(op0);
    if ok0 { neg_op = op0; neg_arg = 0; other_arg = 1; not_neg = n0; }
    else {
        ok1, n1 := pm_fneg(op1);
        if !ok1 return brk();
        neg_op = op1; neg_arg = 1; other_arg = 0; not_neg = n1;
    }
    if !has_one_use(neg_op) return brk();
    other := op(ii, other_arg);
    nc := type_count(vtype(neg_op)); oc := type_count(vtype(other)); rc := type_count(vtype(ii));
    if nc > oc && oc < rc {
        inv := icb_fneg(other);
        ic_replace_operand(ii, neg_arg, not_neg);
        ic_replace_operand(ii, other_arg, inv);
        return sw_done(ii);
    }
    if nc > rc {
        args: [..] Value_Id; args.allocator = temp;
        for k: 0..cast(s64) call_arg_count(ii) - 1 array_add(*args, call_arg(ii, cast(u32) k));
        args[neg_arg] = not_neg;
        nm := icb_intrinsic_ret(vtype(ii), iid, args, ii);
        return sw_done(ic_replace_inst_uses_with(ii, icb_fneg(nm, "", ii)));
    }
    return brk();
}

// APFloat::clearSign
apf_clear_sign :: (f: APFloat) -> APFloat {
    g := f;
    if g.k == .PPC_FP128 fatal("instcombine: clearSign of ppc_fp128 is not supported yet");
    bits := cast(u32) fp_type_bits(g.k);
    w := (bits - 1) / 64;
    g.w[w] &= ~((cast(u64) 1) << ((bits - 1) % 64));
    return g;
}
// case copysign
ic_visit_copysign :: (ii: Value_Id) -> Ic_Switch_Result {
    mag := call_arg(ii, 0); sign := call_arg(ii, 1);
    ks := compute_known_fp_class(sign, FC_ALL_FLAGS, ic_q(ii));
    if ks.sign_bit >= 0 {
        if ks.sign_bit == 1 {
            fabs := icb_fabs(mag, ii);
            return sw_done(ic_replace_inst_uses_with(ii, icb_fneg(fabs, "", ii)));
        }
        return sw_done(ic_replace_inst_uses_with(ii, icb_fabs(mag, ii)));
    }
    okc, cq, x := pm_intrinsic2(sign, IID_COPYSIGN);
    if okc return sw_done(ic_replace_inst_uses_with(ii, icb_copysign_fmf(mag, x, get_fmf(ii) & get_fmf(sign))));
    okm, magc := pm_apfloat(mag);
    if okm && apf_is_negative(magc) {
        pos := apf_clear_sign(magc);
        return sw_done(ic_replace_inst_uses_with(ii, icb_copysign_fmf(ic_const_fp(vtype(mag), pos), sign, get_fmf(ii))));
    }
    ok, mx := pm_fabs(mag);
    if !ok ok, mx = pm_fneg(mag);
    if ok return sw_done(ic_replace_inst_uses_with(ii, icb_copysign_fmf(mx, sign, get_fmf(ii))));
    okf, fl := pm_intrinsic1(mag, IID_FLOOR);
    if okf {
        oka, fa := pm_fabs(fl);
        if oka && fa == sign {
            tr := icb_unary_intrinsic(IID_TRUNC, sign, "", ii);
            return sw_done(ic_replace_inst_uses_with(ii, icb_copysign_fmf(tr, sign, get_fmf(ii))));
        }
    }
    sign_elt := scalar_type(vtype(sign));
    if has_one_use(sign) {
        okb, cast_src := pm_elementwise_bitcast(sign);
        if okb && is_inst(sign) && has_one_use(cast_src) && is_int_or_int_vector(vtype(cast_src)) && type_kind(sign_elt) != .PPC_FP128 {
            bw := type_bits(sign_elt);
            known := kb_new(bw);
            if ic_simplify_demanded_bits(sign, 0, ap_signed_min(bw), *known, ic.sq, 0) return sw_done(ii);
        }
    }
    return brk();
}
// case fabs (tail) / ceil / floor / round / roundeven / nearbyint / rint / trunc
ic_narrow_fp_unary_through_fpext :: (ii: Value_Id, iid: Intrinsic_Id) -> Value_Id {
    a := call_arg(ii, 0);
    okx, ext_src := pmi_cast(a, .FPEXT);
    if okx && has_one_use(a) {
        n := icb_unary_intrinsic(iid, ext_src, "", ii);
        return create_cast(.FPEXT, n, vtype(ii));
    }
    return NONE;
}

// case ldexp
ic_visit_ldexp :: (ii: Value_Id) -> Ic_Switch_Result {
    src := call_arg(ii, 0); e := call_arg(ii, 1);
    okc, ce := pm_constant_int_u64(e);
    if okc {
        k := type_kind(scalar_type(vtype(src)));
        one := fp_from_double(scalar_type(vtype(src)), 1.0);
        ow := const_fp_value(one);
        scaled := fp_scalbn(k, ow, cast(s64) cast,trunc(s32) ce, RM_NEAREST_TIES_TO_EVEN);
        sf := apf_make(k, scaled);
        if !apf_is_zero(sf) && !apf_is_inf(sf) {
            return sw_done(create_fop(.FMUL, src, ic_const_fp(vtype(src), sf), ii));
        }
    }
    if has_one_use(src) {
        okl, inner_src, inner_exp := pm_intrinsic2(src, IID_LDEXP);
        if okl && vtype(e) == vtype(inner_exp) {
            fmf := get_fmf(ii); inner_flags := get_fmf(src);
            if ic_ldexp_saturating_add_is_safe(vtype(ii), vtype(e)) &&
               (((fmf & FMF_REASSOC) != 0 && (inner_flags & FMF_REASSOC) != 0) || ic_sign_bit_must_be_the_same(e, inner_exp, ic_q(ii))) {
                ne := icb_binary_intrinsic(IID_SADD_SAT, inner_exp, e);
                return sw_done(ic_replace_inst_uses_with(ii, icb_ldexp(inner_src, ne, fmf | inner_flags)));
            }
        }
    }
    okz, ext := pmi_cast(e, .ZEXT);
    if okz && scalar_bits(ext) == 1 {
        sel := icb_select(ext, fp_from_double(vtype(ii), 2.0), fp_from_double(vtype(ii), 1.0));
        return sw_done(create_fop(.FMUL, src, sel, ii));
    }
    oks, ext2 := pmi_cast(e, .SEXT);
    if oks && scalar_bits(ext2) == 1 {
        sel := icb_select(ext2, fp_from_double(vtype(ii), 0.5), fp_from_double(vtype(ii), 1.0));
        return sw_done(create_fop(.FMUL, src, sel, ii));
    }
    a1 := call_arg(ii, 1);
    oksel, sc, sl, sr := pm_select(a1);
    if oksel && has_one_use(a1) {
        nl: Value_Id = NONE; sel: Value_Id = NONE;
        if pm_zero_int(sr) {
            nl = icb_ldexp(src, sl, get_fmf(ii));
            sel = icb_select(sc, nl, src);
        } else if pm_zero_int(sl) {
            nl = icb_ldexp(src, sr, get_fmf(ii));
            sel = icb_select(sc, src, nl);
        }
        if nl != NONE {
            if is_inst(sel) ic_take_name(sel, ii);
            return sw_done(ic_replace_inst_uses_with(ii, sel));
        }
    }
    return brk();
}

// case stackrestore
ic_visit_stackrestore :: (ii: Value_Id) -> Ic_Switch_Result {
    NONE_C :: 0; ALLOCA_C :: 1; RESTORE_C :: 2; SIDE_C :: 3;
    classify :: (i: Value_Id) -> int {
        if inst_op(i) == .ALLOCA return ALLOCA_C;
        if inst_op(i) == .CALL {
            id := call_iid(i);
            if id != NOT_INTRINSIC {
                if id == IID_STACKRESTORE return RESTORE_C;
                if may_have_side_effects(i) return SIDE_C;
            } else return SIDE_C;
        }
        return NONE_C;
    }
    ss := call_arg(ii, 0);
    if call_iid(ss) == IID_STACKSAVE && inst_block(ss) == inst_block(ii) {
        cannot := false;
        x := inst(ss).next;
        while x != ii {
            c := classify(x);
            if c == RESTORE_C { if call_arg(x, 0) != ss cannot = true; }
            else if c == ALLOCA_C || c == SIDE_C cannot = true;
            if cannot break;
            x = inst(x).next;
        }
        if !cannot return sw_done(ic_erase_inst(ii));
    }
    ti := block_terminator(inst_block(ii));
    cannot := false;
    x := inst(ii).next;
    while x != ti {
        c := classify(x);
        if c == RESTORE_C return sw_done(ic_erase_inst(ii));
        if c == ALLOCA_C || c == SIDE_C { cannot = true; break; }
        x = inst(x).next;
    }
    if !cannot && (inst_op(ti) == .RET || inst_op(ti) == .RESUME) return sw_done(ic_erase_inst(ii));
    return brk();
}

// case assume
ic_visit_assume :: (ii: Value_Id) -> Ic_Switch_Result {
    nb := call_num_bundles(ii);
    if nb > 0 for idx: 0..nb-1 {
        remove_bundle :: (ii: Value_Id, idx: u32) -> Ic_Switch_Result {
            if call_num_bundles(ii) == 1 return sw_done(ic_erase_inst(ii));
            return sw_done(ic_call_remove_bundle_at(ii, idx));
        }
        tag := call_bundle_tag(ii, idx);
        b, e := call_bundle_range(ii, idx);
        if tag == {
            case "align";
                ptr := op(ii, b);
                av := op(ii, b + 1);
                if !cf_is_int(av) continue;
                alignment := const_int_zext(av);
                offset_ptr: Value_Id = ifx e - b == 3 then op(ii, b + 2) else NONE;
                has_offset := offset_ptr == NONE || cf_is_int(offset_ptr);
                offset: u64 = ifx offset_ptr != NONE && cf_is_int(offset_ptr) then const_int_zext(offset_ptr) else 0;
                if alignment == 1 || !ic_is_pow2(alignment) return remove_bundle(ii, idx);
                if is_gep_operator(ptr) && ic_gep_max_preserved_alignment(ptr) >= alignment {
                    icb_alignment_assumption(op(ptr, 0), alignment, offset_ptr);
                    return remove_bundle(ii, idx);
                }
                if !has_offset continue;
                okp, base_ptr, ptr_off := pm_ptr_add_apint(ptr);
                if okp {
                    pv := ap_sext_or_trunc(ptr_off, dl_index_type_size_bits(vtype(ptr)));
                    if pv.bits > 64 && ap_min_signed_bits(pv) > 64 continue;   // trySExtValue
                    icb_alignment_assumption(base_ptr, alignment, const_int(ir.t_i64, offset - cast,no_check(u64) ap_sext_value(pv)));
                    return remove_bundle(ii, idx);
                }
                uo := get_underlying_object(ptr);
                if uo == NONE || is_argument(uo) continue;
                am := alignment - 1;
                kb := ic_known_bits(ptr, ii);
                zm := ap_zext_value(ap_zext_or_trunc(kb.zero, 64)) & am;
                om := ap_zext_value(ap_zext_or_trunc(kb.one, 64)) & am;
                if zm == (~offset & am) && om == (offset & am) return remove_bundle(ii, idx);
            case "dereferenceable";
                cnt := op(ii, b + 1);
                if !cf_is_int(cnt) continue;
                if const_int_zext(cnt) == 0 return remove_bundle(ii, idx);
                if is_dereferenceable_and_aligned_pointer(op(ii, b), 1, ap_from_u64(64, const_int_zext(cnt)), ic_q(ii)) return remove_bundle(ii, idx);
            case "ignore";
                return remove_bundle(ii, idx);
            case "nonnull";
                ptr := op(ii, b);
                if is_known_non_zero(ptr, ic_q(ii)) return remove_bundle(ii, idx);
                if is_inst(ptr) && inst_op(ptr) == .LOAD && is_valid_assume_for_context(ii, ptr, ic.dt, true) {
                    md := md_tuple(.[], false);
                    set_metadata(ptr, md_kind_id("nonnull"), md);
                    set_metadata(ptr, md_kind_id("noundef"), md);
                    return remove_bundle(ii, idx);
                }
                if is_gep_operator(ptr) && (gep_nw_bits(ptr) & F_INBOUNDS) != 0 && !null_pointer_is_defined(inst_fn(ii), cast(u64) type_addrspace(vtype(ptr))) {
                    icb_assumption_bundle("nonnull", .[strip_in_bounds_offsets(ptr)]);
                    return remove_bundle(ii, idx);
                }
            case "noundef";
                v := op(ii, b);
                if is_guaranteed_not_to_be_undef_or_poison(v, ic.ac, ii, ic.dt) return remove_bundle(ii, idx);
                if is_inst(v) && inst_op(v) == .LOAD && is_valid_assume_for_context(ii, v, ic.dt, true) {
                    set_metadata(v, md_kind_id("noundef"), md_tuple(.[], false));
                    return remove_bundle(ii, idx);
                }
            case "separate_storage";
                for k: 0..1 {
                    u := op_use(ii, b + cast(u32) k);
                    hint := ir.u_val[u];
                    uo := get_underlying_object(hint, 0);
                    if hint != uo ic_replace_use(u, uo);
                }
            case "dereferenceable_or_null"; case "cold";
            case; fatal("internal: unexpected assume bundle '%'", tag);
        }
    }
    if call_num_bundles(ii) > 0 return brk();
    operand := call_arg(ii, 0);
    okl, a, b := pm_logical_and(operand);
    if okl {
        icb_assumption(a);
        icb_assumption(b);
        return sw_done(ic_erase_inst(ii));
    }
    okn, no := pm_not(operand);
    if okn {
        oklo, a2, b2 := pm_logical_or(no);
        if oklo {
            icb_assumption(icb_not(a2));
            icb_assumption(icb_not(b2));
            return sw_done(ic_erase_inst(ii));
        }
    }
    okc, ca, cz := pm_specific_icmp(operand, ICMP_NE);
    if okc && pm_zero(cz) && is_ptr_type(vtype(ca)) {
        icb_assumption_bundle("nonnull", .[ca]);
        return sw_done(ic_erase_inst(ii));
    }
    {
        align_mask: u64 = 1;
        av: Value_Id = NONE;
        matched := false;
        if okn {
            okt, ta := pmi_cast(no, .TRUNC);
            if okt { av = ta; matched = true; }
        }
        if !matched {
            oke, ea, ez := pm_specific_icmp(operand, ICMP_EQ);
            if oke && pm_zero(ez) {
                oka, x, mc := pm_binop(ea, .AND);
                if oka && is_inst(ea) {
                    okm, m := pm_constant_int_u64(mc);
                    if okm { av = x; align_mask = m; matched = true; }
                }
            }
        }
        if matched && ic_is_pow2(align_mask + 1) {
            o := opr_code(av);
            if o == .PTRTOINT || o == .PTRTOADDR {
                icb_alignment_assumption(op(av, 0), align_mask + 1);
                return sw_done(ic_erase_inst(ii));
            }
        }
    }
    if cf_is_int(operand) || pm_undef_value(operand) {
        if !cf_is_int(operand) || ap_is_zero(const_ap(operand)) ic_create_non_terminator_unreachable(ii);
        return sw_done(ic_erase_inst(ii));
    }
    if ic.ac ac_update_affected_values(ic.ac, ii);
    return brk();
}

// case vector_insert
ic_visit_vector_insert :: (ii: Value_Id) -> Ic_Switch_Result {
    vec := call_arg(ii, 0); sub := call_arg(ii, 1); idx := call_arg(ii, 2);
    dt := vtype(ii); vt := vtype(vec); st := vtype(sub);
    if type_kind(dt) == .VECTOR && type_kind(vt) == .VECTOR && type_kind(st) == .VECTOR {
        dn := cast(s64) type_count(dt); vn := cast(s64) type_count(vt); sn := cast(s64) type_count(st);
        idxn := cast(s64) const_int_zext(idx);
        if vn == sn return sw_done(ic_replace_inst_uses_with(ii, sub));
        widen: [..] u32; widen.allocator = temp;
        for k: 0..sn-1 array_add(*widen, cast(u32) k);
        for k: sn..vn-1 array_add(*widen, 0xFFFF_FFFF);
        ws := icb_shuffle(sub, NONE, widen);
        mask: [..] u32; mask.allocator = temp;
        for k: 0..idxn-1 array_add(*mask, cast(u32) k);
        for k: dn..dn+sn-1 array_add(*mask, cast(u32) k);
        for k: idxn+sn..dn-1 array_add(*mask, cast(u32) k);
        sh := icb_shuffle(vec, ws, mask);
        return sw_done(ic_replace_inst_uses_with(ii, sh));
    }
    return brk();
}
// case vector_extract
ic_visit_vector_extract :: (ii: Value_Id) -> Ic_Switch_Result {
    vec := call_arg(ii, 0); idx := call_arg(ii, 1);
    rt := vtype(ii);
    ext_idx := const_int_zext(idx);
    if call_iid(vec) == IID_VECTOR_INSERT && vtype(call_arg(vec, 1)) == rt {
        index := const_int_zext(call_arg(vec, 2));
        if ext_idx == index return sw_done(ic_replace_inst_uses_with(ii, call_arg(vec, 1)));
        return sw_done(ic_replace_operand(ii, 0, call_arg(vec, 0)));
    }
    if call_iid(vec) == IID_GET_ACTIVE_LANE_MASK && cf_is_int(call_arg(vec, 1)) {
        a := fn_get_fn_attr(inst_fn(ii), .VScaleRange);
        vmin: u64 = ifx a then a.ival >> 32 else 0;
        scale := ifx type_kind(rt) == .SVECTOR then vmin else 1;
        if ext_idx * scale >= const_int_zext(call_arg(vec, 1)) return sw_done(ic_replace_inst_uses_with(ii, const_null_value(rt)));
    }
    if is_vector_type(rt) && is_vector_type(vtype(vec)) {
        dn := type_count(rt); vn := type_count(vtype(vec));
        if dn == vn && (type_kind(rt) == .SVECTOR) == (type_kind(vtype(vec)) == .SVECTOR) {
            ic_replace_inst_uses_with(ii, vec);
            return sw_done(ic_erase_inst(ii));
        }
        if type_kind(rt) == .SVECTOR || type_kind(vtype(vec)) == .SVECTOR return brk();
        mask: [..] u32; mask.allocator = temp;
        for k: 0..cast(s64) dn - 1 array_add(*mask, cast(u32) (ext_idx + cast(u64) k));
        sh := icb_shuffle(vec, NONE, mask);
        return sw_done(ic_replace_inst_uses_with(ii, sh));
    }
    return brk();
}

// the vector_reduce_* cases (with LLVM's fallthrough chain)
ic_visit_reduction :: (ii: Value_Id, iid: Intrinsic_Id) -> Ic_Switch_Result {
    ci := ii;
    ty := vtype(ii);
    stage := 0;
    // order: or/and (0), add (1), xor (2), mul (3), umin/umax (4), smin/smax (5), fp (6)
    if iid == IID_VECTOR_REDUCE_OR || iid == IID_VECTOR_REDUCE_AND stage = 0;
    else if iid == IID_VECTOR_REDUCE_ADD stage = 1;
    else if iid == IID_VECTOR_REDUCE_XOR stage = 2;
    else if iid == IID_VECTOR_REDUCE_MUL stage = 3;
    else if iid == IID_VECTOR_REDUCE_UMIN || iid == IID_VECTOR_REDUCE_UMAX stage = 4;
    else if iid == IID_VECTOR_REDUCE_SMIN || iid == IID_VECTOR_REDUCE_SMAX stage = 5;
    else stage = 6;
    zext_or_sext_or_self :: (v: Value_Id) -> Value_Id { ok, x := pmi_zext_or_sext(v); if ok return x; return v; }
    if stage == 0 {
        arg := call_arg(ii, 0);
        nop := ic_simplify_reduction_operand(arg, true);
        if nop != NONE { ic_replace_use(op_use(ii, 0), nop); return sw_done(ii); }
        vect := zext_or_sext_or_self(arg);
        ft := vtype(vect);
        if type_kind(ft) == .VECTOR && type_elem(ft) == ir.t_i1 {
            res := icb_cast(.BITCAST, vect, type_int(cast(u32) type_count(ft)));
            if iid == IID_VECTOR_REDUCE_AND res = icb_cmp(ICMP_EQ, res, const_all_ones_of(vtype(res)));
            else res = icb_is_not_null(res);
            if arg != vect res = icb_cast(inst_op(arg), res, ty);
            return sw_done(ic_replace_inst_uses_with(ci, res));
        }
    }
    if stage <= 1 && iid == IID_VECTOR_REDUCE_ADD {
        arg := call_arg(ii, 0);
        nop := ic_simplify_reduction_operand(arg, true);
        if nop != NONE { ic_replace_use(op_use(ii, 0), nop); return sw_done(ii); }
        splat := get_splat_value_vt(arg);
        if splat != NONE && type_kind(vtype(arg)) == .VECTOR {
            n := type_count(vtype(arg));
            return sw_done(create_binop(.MUL, splat, const_int_ap(vtype(splat), ap_trunc(ap_from_u64(64, n), scalar_bits(splat)))));
        }
        vect := zext_or_sext_or_self(arg);
        ft := vtype(vect);
        if type_kind(ft) == .VECTOR && type_elem(ft) == ir.t_i1 {
            v := icb_cast(.BITCAST, vect, type_int(cast(u32) type_count(ft)));
            res := icb_unary_intrinsic(IID_CTPOP, v);
            res = icb_zext_or_trunc(res, ty);
            if arg != vect && inst_op(arg) == .SEXT res = icb_neg(res);
            return sw_done(ic_replace_inst_uses_with(ci, res));
        }
    }
    if stage <= 2 && iid == IID_VECTOR_REDUCE_XOR {
        arg := call_arg(ii, 0);
        nop := ic_simplify_reduction_operand(arg, true);
        if nop != NONE { ic_replace_use(op_use(ii, 0), nop); return sw_done(ii); }
        vect := zext_or_sext_or_self(arg);
        if is_vector_type(vtype(vect)) && type_elem(vtype(vect)) == ir.t_i1 {
            res := icb_reduce(IID_VECTOR_REDUCE_ADD, vect);
            if arg != vect res = icb_cast(inst_op(arg), res, ty);
            return sw_done(ic_replace_inst_uses_with(ci, res));
        }
    }
    if stage <= 3 && iid == IID_VECTOR_REDUCE_MUL {
        arg := call_arg(ii, 0);
        nop := ic_simplify_reduction_operand(arg, true);
        if nop != NONE { ic_replace_use(op_use(ii, 0), nop); return sw_done(ii); }
        okz, vz := pmi_cast(arg, .ZEXT);
        is_zext := okz && is_int_or_int_vector_n(vtype(vz), 1);
        oks, vs := pmi_cast(arg, .SEXT);
        is_sext := oks && is_int_or_int_vector_n(vtype(vs), 1) && type_count(vtype(vs)) % 2 == 0;
        if is_zext || is_sext {
            v := ifx is_zext then vz else vs;
            res := icb_reduce(IID_VECTOR_REDUCE_AND, v);
            return sw_done(create_cast(.ZEXT, res, ty));
        }
        if is_int_or_int_vector_n(vtype(arg), 1) return sw_done(ic_replace_inst_uses_with(ci, icb_reduce(IID_VECTOR_REDUCE_AND, arg)));
    }
    if stage <= 4 && (iid == IID_VECTOR_REDUCE_UMIN || iid == IID_VECTOR_REDUCE_UMAX) {
        arg := call_arg(ii, 0);
        nop := ic_simplify_reduction_operand(arg, true);
        if nop != NONE { ic_replace_use(op_use(ii, 0), nop); return sw_done(ii); }
        vect := zext_or_sext_or_self(arg);
        if is_vector_type(vtype(vect)) && type_elem(vtype(vect)) == ir.t_i1 {
            res := icb_reduce(ifx iid == IID_VECTOR_REDUCE_UMIN then IID_VECTOR_REDUCE_AND else IID_VECTOR_REDUCE_OR, vect);
            if arg != vect res = icb_cast(inst_op(arg), res, ty);
            return sw_done(ic_replace_inst_uses_with(ci, res));
        }
    }
    if stage <= 5 && (iid == IID_VECTOR_REDUCE_SMIN || iid == IID_VECTOR_REDUCE_SMAX) {
        arg := call_arg(ii, 0);
        nop := ic_simplify_reduction_operand(arg, true);
        if nop != NONE { ic_replace_use(op_use(ii, 0), nop); return sw_done(ii); }
        vect := zext_or_sext_or_self(arg);
        if is_vector_type(vtype(vect)) && type_elem(vtype(vect)) == ir.t_i1 {
            ext: Opcode = .NONE_OP;
            if arg != vect ext = inst_op(arg);
            res := icb_reduce(ifx (iid == IID_VECTOR_REDUCE_SMIN) == (ext == .ZEXT) then IID_VECTOR_REDUCE_AND else IID_VECTOR_REDUCE_OR, vect);
            if arg != vect res = icb_cast(ext, res, ty);
            return sw_done(ic_replace_inst_uses_with(ci, res));
        }
    }
    can_reorder := (iid != IID_VECTOR_REDUCE_FADD && iid != IID_VECTOR_REDUCE_FMUL) || (get_fmf(ii) & FMF_REASSOC) != 0;
    arg_idx: u32 = ifx iid == IID_VECTOR_REDUCE_FADD || iid == IID_VECTOR_REDUCE_FMUL then cast(u32) 1 else 0;
    arg := call_arg(ii, arg_idx);
    nop := ic_simplify_reduction_operand(arg, can_reorder);
    if nop != NONE { ic_replace_use(op_use(ii, arg_idx), nop); return sw_done(NONE); }
    return brk();
}

// ---------------------------------------------------------------- target intrinsics (TTI::instCombineIntrinsic)

// The module's target decides which instCombineIntrinsic runs (BasicTTI: none). The target hooks are not ported:
// fail loudly when one could apply.
ic_target_inst_combine_intrinsic :: (ii: Value_Id) -> (Value_Id, bool) {
    name := intrinsic_name(call_iid(ii));
    t := ir.triple;
    arch_of :: (name: string) -> string {
        prefixes :: string.["x86", "aarch64", "arm", "amdgcn", "r600", "nvvm", "riscv", "ppc", "hexagon", "wasm", "s390", "mips", "loongarch", "spv", "dx", "systemz", "ve", "bpf", "xcore"];
        for prefixes if begins_with(name, tprint("llvm.%.", it)) return it;
        return "";
    }
    arch := arch_of(name);
    if arch.count == 0 || t.count == 0 return NONE, false;
    targets_x86 := begins_with(t, "x86_64") || begins_with(t, "i386") || begins_with(t, "i686") || begins_with(t, "x86");
    if arch == "x86" && targets_x86 { v, h := ic_x86_inst_combine_intrinsic(ii); return v, h; }
    if (arch == "aarch64" && begins_with(t, "aarch64")) || (arch == "arm" && (begins_with(t, "arm") || begins_with(t, "thumb"))) ||
       (arch == "amdgcn" && begins_with(t, "amdgcn")) || (arch == "nvvm" && begins_with(t, "nvptx")) ||
       (arch == "riscv" && begins_with(t, "riscv")) || (arch == "ppc" && begins_with(t, "powerpc")) ||
       (arch == "hexagon" && begins_with(t, "hexagon")) || (arch == "wasm" && begins_with(t, "wasm"))
        fatal("instcombine: TTI::instCombineIntrinsic for % intrinsics is not supported yet", arch);
    return NONE, false;
}
// ---------------------------------------------------------------- visitFenceInst / visitInvokeInst / visitCallBrInst

ic_visit_fence :: (fi: Value_Id) -> Value_Id {
    nfi := inst(fi).next;
    if nfi != NONE && inst_op(nfi) != .FENCE nfi = NONE;
    if nfi != NONE && is_identical_to(fi, nfi) return ic_erase_inst(fi);
    stronger :: (a: Value_Id, b: Value_Id) -> bool {
        sa := inst(a).sync; sb := inst(b).sync;
        if sa != sb || (sa != SYNC_SYSTEM && sa != SYNC_SINGLE_THREAD) return false;
        return ic_is_at_least_or_stronger(inst(a).ord1, inst(b).ord1);
    }
    if nfi != NONE && stronger(nfi, fi) return ic_erase_inst(fi);
    pfi := inst(fi).prev;
    if pfi != NONE && inst_op(pfi) == .FENCE && stronger(pfi, fi) return ic_erase_inst(fi);
    return NONE;
}
ic_visit_invoke :: (i: Value_Id) -> Value_Id { return ic_visit_call_base(i); }
ic_visit_callbr :: (i: Value_Id) -> Value_Id { return ic_visit_call_base(i); }

// ---------------------------------------------------------------- visitCallBase

// annotateAnyAllocSite: getAllocSize / getAllocAlignment (MemoryBuiltins.cpp) are not ported yet; fail loudly when
// they could produce something
ic_annotate_any_alloc_site :: (call: Value_Id) -> bool {
    changed := false;
    if !is_ptr_type(vtype(call)) return changed;
    oks, size := mb_get_alloc_size(call);
    if oks && !ap_is_zero(size) {
        if call_has_ret_attr(call, .NonNull) {
            changed = !call_has_ret_attr(call, .Dereferenceable);
            call_add_ret_int_attr(call, .Dereferenceable, ap_limited(size));
        } else {
            changed = !call_has_ret_attr(call, .DereferenceableOrNull);
            call_add_ret_int_attr(call, .DereferenceableOrNull, ap_limited(size));
        }
    }
    alignment := get_alloc_alignment(call);
    if alignment == NONE return changed;
    if cf_is_int(alignment) && ap_ult_u64(const_ap(alignment), cast(u64) 1 << 32) {
        av := const_int_zext(alignment);
        if ic_is_pow2(av) {
            existing := call_ret_align(call); if existing == 0 existing = 1;
            if av > existing { call_add_ret_int_attr(call, .Alignment, av); changed = true; }
        }
    }
    return changed;
}
// Type::canLosslesslyBitCastTo
can_losslessly_bitcast_to :: (a: Type_Id, b: Type_Id) -> bool {
    if a == b return true;
    if !is_first_class(a) || !is_first_class(b) return false;
    if is_vector_type(a) && is_vector_type(b) return ic_prim_bits(a) == ic_prim_bits(b) && ic_prim_bits(a) != 0;
    if is_ptr_type(a) && is_ptr_type(b) return type_addrspace(a) == type_addrspace(b);
    return false;
}
// CallBase::paramHasAttr-style dereferenceable bytes
// CallBase::getParamDereferenceableBytes: the call site's attributes only
call_param_dereferenceable_bytes :: (c: Value_Id, k: u32) -> u64 {
    a := attr_set_find(attr_list_param(inst(c).attrs, k), .Dereferenceable);
    if !a return 0;
    return a.ival;
}
// CallBase::isIndirectCall
call_is_indirect :: (c: Value_Id) -> bool {
    callee := call_callee(c);
    if vkind(callee) == .FUNCTION || vkind(callee) == .INLINE_ASM return false;
    if is_const(callee) && vkind(callee) != .C_EXPR return false;
    return true;
}
ic_visit_call_base :: (call: Value_Id) -> Value_Id {
    changed := ic_annotate_any_alloc_site(call);
    arg_nos: [..] u32; arg_nos.allocator = temp;
    n := call_arg_count(call);
    for k: 0..cast(s64) n - 1 {
        v := call_arg(call, cast(u32) k);
        if !is_ptr_type(vtype(v)) continue;
        has_deref := call_param_dereferenceable_bytes(call, cast(u32) k) > 0;
        if call_param_has_attr(call, cast(u32) k, .NonNull) || (has_deref && !null_pointer_is_defined(inst_fn(call), cast(u64) type_addrspace(vtype(v)))) {
            res := ic_simplify_non_null_operand(v, has_deref);
            if res != NONE { ic_replace_operand(call, cast(u32) k, res); changed = true; }
        } else if is_known_non_zero(v, ic_q(call)) {
            array_add(*arg_nos, cast(u32) k);
        }
    }
    if arg_nos.count {
        for k: arg_nos {
            s := call_param_attr_set(call, k);
            a: Attr; a.kind = .NonNull; a.ty = NONE;
            call_set_param_attr_set(call, k, attr_set_with(s, a));
        }
        changed = true;
    }
    callee := call_callee(call);
    callee_f: Value_Id = ifx vkind(callee) == .FUNCTION then callee else NONE;
    if callee_f == NONE || glob(callee_f).value_type != inst(call).ty2 {
        if ic_transform_const_expr_cast_call(call) return NONE;
    }
    if callee_f != NONE {
        if call_has_fn_attr_site(call, .Convergent) && !fn_has_fn_attr(callee_f, .Convergent) && !glob(callee_f).intrinsic {
            call_remove_fn_attr(call, .Convergent);
            return call;
        }
        if (glob(callee_f).cc != inst(call).cc &&
            !(glob(callee_f).cc == CC_C && ic_is_calling_conv_c_compatible(inst(call).cc, inst(call).ty2)) &&
            !(inst(call).cc == CC_C && ic_is_calling_conv_c_compatible(glob(callee_f).cc, glob(callee_f).value_type))) &&
           !is_declaration(callee_f) {
            ic_create_non_terminator_unreachable(call);
            if vtype(call) != ir.t_void ic_replace_inst_uses_with(call, const_poison(vtype(call)));
            if inst_op(call) == .CALL return ic_erase_inst(call);
            set_op(call, nops(call) - 1, const_null_value(vtype(callee_f)));
            inst(call).ty2 = glob(callee_f).value_type;
            return NONE;
        }
    }
    if (vkind(callee) == .C_NULL && !null_pointer_is_defined(inst_fn(call))) || pm_undef_value(callee) {
        if vtype(call) != ir.t_void ic_replace_inst_uses_with(call, const_poison(vtype(call)));
        if is_terminator(inst_op(call)) return NONE;
        ic_create_non_terminator_unreachable(call);
        return ic_erase_inst(call);
    }
    if call_iid(strip_pointer_casts(callee)) == IID_ADJUST_TRAMPOLINE fatal("instcombine: transformCallThroughTrampoline is not supported yet");
    if call_has_bundle(call, "ptrauth") {
        // foldPtrAuthIntrinsicCallee / foldPtrAuthConstantCallee
        c := callee;
        if (opr_code(c) == .INTTOPTR && is_inst(c) && (call_iid(op(c, 0)) == IID_PTRAUTH_RESIGN || call_iid(op(c, 0)) == IID_PTRAUTH_SIGN)) || vkind(c) == .C_PTRAUTH
            fatal("instcombine: ptrauth call bundles are not supported yet");
    }
    if vkind(callee) == .INLINE_ASM && !call_does_not_throw(call) {
        if !ic_inline_asm_can_throw(callee) { call_add_fn_attr(call, .NoUnwind); changed = true; }
    }
    if inst_op(call) == .CALL {
        r := ic_try_optimize_call(call);
        if r != NONE return ic_erase_inst(r);
    }
    if has_uses(call) && ((inst(call).flags >> TAIL_SHIFT) & 3) != 2 {
        ra := call_returned_arg(call);
        if ra != NONE && can_losslessly_bitcast_to(vtype(ra), vtype(call))
            return ic_replace_inst_uses_with(call, icb_bit_or_pointer_cast(ra, vtype(call)));
    }
    ct := md_kind_id("callee_type");
    if get_metadata(call, ct) != NONE && !call_is_indirect(call) { set_metadata(call, ct, NONE); changed = true; }
    if call_has_bundle(call, "kcfi") && !call_is_indirect(call) {
        nb := call_num_bundles(call);
        for k: 0..nb-1 if call_bundle_tag(call, k) == "kcfi" return ic_call_remove_bundle_at(call, k);
    }
    if is_removable_alloc(call) return ic_visit_alloc_site(call);
    if call_iid(call) == IID_EXPERIMENTAL_GC_STATEPOINT fatal("instcombine: gc.statepoint is not supported yet");
    return ifx changed then call else NONE;
}
// tryOptimizeCall: LibCallSimplifier (simplify_lib_calls.jai), then optimizeModularFormat
ic_try_optimize_call :: (ci: Value_Id) -> Value_Id {
    if call_called_function(ci) == NONE return NONE;
    tk := call_tail_kind(ci);
    if tk == TCK_MUSTTAIL || tk == TCK_NOTAIL return NONE;
    with := lcs_optimize_call(ci);
    if with != NONE {
        if !has_uses(ci) return ci;
        return ic_replace_inst_uses_with(ci, with);
    }
    if call_has_fn_str_attr(ci, "modular-format") || fn_has_str_attr(call_called_function(ci), "modular-format") fatal("instcombine: optimizeModularFormat is not supported yet");
    return NONE;
}
// InlineAsm::canThrow
ic_inline_asm_can_throw :: (ia: Value_Id) -> bool { return (inline_asms[ir.v_aux[ia]].flags & 8) != 0; }
call_has_fn_attr_site :: (c: Value_Id, k: Attr_Kind) -> bool { return attr_set_has(attr_list_fn(inst(c).attrs), k); }
call_remove_fn_attr :: (c: Value_Id, k: Attr_Kind) {
    l := inst(c).attrs;
    inst(c).attrs = attr_list_with_fn(l, attr_set_remove(attr_list_fn(l), k));
}
// isAtLeastOrStrongerThan(AO, Other) (AtomicOrdering.h lookup table)
ic_is_at_least_or_stronger :: (a: u8, b: u8) -> bool {
    T :: bool.[
        true, false, false, false, false, false, false, false,
        true, true, false, false, false, false, false, false,
        true, true, true, false, false, false, false, false,
        true, true, true, true, false, false, false, false,
        true, true, true, true, true, false, false, false,
        true, true, true, false, false, true, false, false,
        true, true, true, true, true, true, true, false,
        true, true, true, true, true, true, true, true];
    return T[cast(int) a * 8 + cast(int) b];
}
SYNC_SYSTEM :: 0; SYNC_SINGLE_THREAD :: 1;

// simplifyNonNullOperand (InstCombineLoadStoreAlloca.cpp)

// transformConstExprCastCall: the bail-outs are ported; the transform itself fails loudly
ic_transform_const_expr_cast_call :: (call: Value_Id) -> bool {
    callee := strip_pointer_casts(call_callee(call));
    if vkind(callee) != .FUNCTION return false;
    if is_declaration(callee) return false;
    if fn_has_str_attr(callee, "thunk") return false;
    if fn_has_fn_attr(callee, .Naked) return false;
    if ((inst(call).flags >> TAIL_SHIFT) & 3) == 2 return false;
    caller_pal := inst(call).attrs;
    ft := glob(callee).value_type;
    old_ret := vtype(call); new_ret := func_ret(ft);
    kinds: [..] Attr_Kind; kinds.allocator = temp;
    if old_ret != new_ret {
        if type_kind(new_ret) == .STRUCT return false;
        if !ic_is_bit_or_noop_pointer_castable(new_ret, old_ret) && has_uses(call) return false;
        if caller_pal != 0 && has_uses(call) {
            ic_type_incompatible(new_ret, attr_list_ret(caller_pal), ASK_ALL, *kinds);
            if ic_attr_set_overlaps(attr_list_ret(caller_pal), kinds) return false;
        }
        if has_uses(call) && inst_op(call) == .INVOKE {
            nd := get_successor(call, 0);
            u := ir.v_first_use[call];
            while u != NONE { us := ir.u_user[u]; if is_phi(us) && inst_block(us) == nd return false; u = ir.u_next[u]; }
        }
    }
    na := call_arg_count(call);
    np := func_nparams(ft);
    nc := min(np, na);
    callee_pal := glob(callee).attrs;
    if ic_attr_list_has_somewhere(callee_pal, .InAlloca) || ic_attr_list_has_somewhere(callee_pal, .Preallocated) return false;
    for k: 0..cast(s64) nc - 1 {
        pty := func_param(ft, cast(u32) k);
        if !ic_is_bit_or_noop_pointer_castable(vtype(call_arg(call, cast(u32) k)), pty) return false;
        ps := attr_list_param(caller_pal, cast(u32) k);
        kinds.count = 0;
        ic_type_incompatible(pty, ps, ASK_UNSAFE_TO_DROP, *kinds);
        if ic_attr_set_overlaps(ps, kinds) return false;
        if attr_set_has(ps, .InAlloca) || attr_set_has(ps, .Preallocated) return false;
        if attr_set_has(ps, .SwiftError) return false;
        if attr_set_has(ps, .ByVal) != attr_set_has(attr_list_param(callee_pal, cast(u32) k), .ByVal) return false;
    }
    if np < na && func_vararg(ft) && caller_pal != 0 {
        // hasAttrSomewhere(StructRet, &SRetIdx) with SRetIdx - FirstArgIndex >= NumParams
        n := ifx caller_pal == 0 then 0 else ir.attr_lists[caller_pal].params.count;
        for k: 0..n-1 if attr_set_has(attr_list_param(caller_pal, cast(u32) k), .StructRet) { if cast(u32) k >= np return false; break; }
    }
    if inst_op(call) != .CALL fatal("instcombine: transformConstExprCastCall of an invoke is not supported yet");

    args: [..] Value_Id; args.allocator = temp;
    arg_attrs: [..] u32; arg_attrs.allocator = temp;
    rattrs := attr_list_ret(caller_pal);
    kinds.count = 0;
    ic_type_incompatible(new_ret, attr_list_ret(caller_pal), ASK_ALL, *kinds);
    rattrs = attr_set_remove_kinds(rattrs, kinds);
    for k: 0..cast(s64) nc - 1 {
        pty := func_param(ft, cast(u32) k);
        a := call_arg(call, cast(u32) k);
        nv := a;
        if vtype(a) != pty nv = icb_bit_or_pointer_cast(a, pty);
        array_add(*args, nv);
        ps := attr_list_param(caller_pal, cast(u32) k);
        kinds.count = 0;
        ic_type_incompatible(pty, ps, ASK_SAFE_TO_DROP, *kinds);
        array_add(*arg_attrs, attr_set_remove_kinds(ps, kinds));
    }
    if np > nc for k: nc..np-1 { array_add(*args, const_null_value(func_param(ft, cast(u32) k))); array_add(*arg_attrs, 0); }
    if np < na && func_vararg(ft) {
        for k: np..na-1 {
            a := call_arg(call, cast(u32) k);
            t := vtype(a);
            // InstCombiner::getPromotedType and CastInst::getCastOpcode(V, false, PTy, false)
            pt := t;
            if type_kind(t) == .INT && type_int_width(t) < 32 pt = ir.t_i32;
            else if type_kind(t) == .FLOAT pt = type_simple(.DOUBLE);
            nv := a;
            if pt != t nv = icb_cast(ifx type_kind(t) == .INT then Opcode.ZEXT else .FPEXT, a, pt);
            array_add(*args, nv);
            array_add(*arg_attrs, attr_list_param(caller_pal, cast(u32) k));
        }
    }
    fn_attrs := attr_list_fn(caller_pal);
    if type_kind(new_ret) == .VOID && vname(call).count set_name(call, "");
    new_pal := attr_list_get(fn_attrs, rattrs, arg_attrs);
    nc_i := create_call_fn(callee, args);
    if inst(call).nidx > 0 nc_i = call_with_default_bundles(nc_i, call);   // getOperandBundlesAsDefs
    icb_insert(nc_i);
    call_set_tail_kind(nc_i, (inst(call).flags >> TAIL_SHIFT) & 3);
    ic_take_name(nc_i, call);
    inst(nc_i).cc = inst(call).cc;
    inst(nc_i).attrs = new_pal;
    prof := get_metadata(call, md_kind_id("prof"));
    if prof != NONE set_metadata(nc_i, md_kind_id("prof"), prof);
    nv: Value_Id = nc_i;
    if old_ret != vtype(nv) && has_uses(call) {
        cst := ic_create_bit_or_pointer_cast(nc_i, old_ret);
        set_metadata(cst, 0, get_metadata(call, 0));
        pos, bb, head := inst_insertion_point_after_def(nc_i);
        ic_insert_new_inst_before(cst, pos, head);
        wl_push_users(call);
        nv = cst;
    }
    if has_uses(call) ic_replace_inst_uses_with(call, nv);
    ic_erase_inst(call);
    return true;
}

ASK_SAFE_TO_DROP :: 1; ASK_UNSAFE_TO_DROP :: 2; ASK_ALL :: 3;
// AttributeFuncs::typeIncompatible(Ty, AS, ASK)
ic_type_incompatible :: (ty: Type_Id, s: u32, ask: u32, out: *[..] Attr_Kind) {
    k := type_kind(ty);
    safe := (ask & ASK_SAFE_TO_DROP) != 0; unsafe := (ask & ASK_UNSAFE_TO_DROP) != 0;
    if k != .INT && safe array_add(out, .AllocAlign);
    if k != .INT && k != .BYTE && unsafe { array_add(out, .SExt); array_add(out, .ZExt); }
    if !is_int_or_int_vector(ty) { if safe array_add(out, .Range); }
    else {
        r := attr_set_find(s, .Range);
        if r && cast(u32) r.ival != type_bits(scalar_type(ty)) array_add(out, .Range);
    }
    if k != .PTR {
        if safe for Attr_Kind.[.NoAlias, .NonNull, .ReadNone, .ReadOnly, .Dereferenceable, .DereferenceableOrNull, .Writable,
                               .DeadOnUnwind, .Initializes, .Captures, .DeadOnReturn] array_add(out, it);
        if unsafe for Attr_Kind.[.Nest, .SwiftError, .Preallocated, .InAlloca, .ByVal, .StructRet, .ByRef, .ElementType,
                                 .AllocatedPointer] array_add(out, it);
    }
    if !is_ptr_or_ptr_vector(ty) && safe array_add(out, .Alignment);
    if safe && !fp_math_supported_type(ty) array_add(out, .NoFPClass);
    if k == .VOID && safe array_add(out, .NoUndef);
}
// AttrBuilder(AS).overlaps(Mask)
ic_attr_set_overlaps :: (s: u32, kinds: [] Attr_Kind) -> bool {
    for kinds if attr_set_has(s, it) return true;
    return false;
}
// AttributeList::hasAttrSomewhere(Kind)
ic_attr_list_has_somewhere :: (l: u32, k: Attr_Kind) -> bool {
    if l == 0 return false;
    if attr_set_has(attr_list_fn(l), k) || attr_set_has(attr_list_ret(l), k) return true;
    for ir.attr_lists[l].params if attr_set_has(it, k) return true;
    return false;
}
// CastInst::isBitOrNoopPointerCastable (approximation for the bail-out checks)
ic_is_bit_or_noop_pointer_castable :: (src: Type_Id, dst: Type_Id) -> bool {
    if src == dst return true;
    if !is_first_class(src) || !is_first_class(dst) || is_aggregate(src) || is_aggregate(dst) return false;
    sp := is_ptr_or_ptr_vector(src); dp := is_ptr_or_ptr_vector(dst);
    if sp && dp return type_addrspace(src) == type_addrspace(dst) && (!is_vector_type(src) || type_count(src) == type_count(dst));
    if sp != dp {
        p := ifx sp then src else dst; i := ifx sp then dst else src;
        if is_vector_type(p) != is_vector_type(i) return false;
        return is_int_or_int_vector(i) && cast(u64) type_bits(scalar_type(i)) == dl_pointer_type_size_bits(scalar_type(p));
    }
    if type_kind(src) == .VOID || type_kind(dst) == .VOID return false;
    return ic_prim_bits(src) == ic_prim_bits(dst) && ic_prim_bits(src) != 0;
}

GUARD_WIDENING_WINDOW :: 3;   // -instcombine-guard-widening-window
CC_C :: 0; CC_ARM_APCS :: 66; CC_ARM_AAPCS :: 67; CC_ARM_AAPCS_VFP :: 68;
// isCallingConvCCompatible(CC, TT, FuncTy) (TargetLibraryInfo.cpp)
ic_is_calling_conv_c_compatible :: (cc: u32, fty: Type_Id) -> bool {
    if cc == CC_C return true;
    if cc == CC_ARM_APCS || cc == CC_ARM_AAPCS || cc == CC_ARM_AAPCS_VFP {
        if contains(ir.triple, "ios") return false;
        r := func_ret(fty);
        if !is_ptr_type(r) && !is_int_type(r) && type_kind(r) != .VOID return false;
        for k: 0..cast(s64) func_nparams(fty) - 1 { p := func_param(fty, cast(u32) k); if !is_ptr_type(p) && !is_int_type(p) return false; }
        return true;
    }
    return false;
}
// GEPOperator::getMaxPreservedAlignment
ic_gep_max_preserved_alignment :: (g: Value_Id) -> u64 {
    result: u64 = (cast(u64) 1) << 32;
    min_align :: (a: u64, b: u64) -> u64 { x := a | b; return x & (~x + 1); }
    cur := opr_gep_source_type(g);
    for k: 1..cast(s64) nops(g) - 1 {
        o := op(g, cast(u32) k);
        is_struct := k > 1 && type_kind(cur) == .STRUCT;
        indexed := gep_indexed_type(cur, k, o);
        defer cur = indexed;
        offset: u64;
        if is_struct {
            offset = dl_struct_offset(cur, cast(u32) (const_int_zext(o) & 0xFFFF_FFFF));
        } else {
            cnt: u64 = ifx cf_is_int(o) then ap_limited(const_ap(o)) else 1;
            offset = gep_seq_stride(cur, k, indexed) * cnt;
        }
        result = min_align(offset, result);
    }
    return result;
}

// isSafeToSpeculativelyExecute(I) without a context instruction (loads via Loads.cpp)
ic_is_safe_to_speculatively_execute_no_cxt :: (i: Value_Id) -> bool {
    if inst_op(i) == .LOAD {
        if must_suppress_speculation(i) return false;
        q: Simplify_Query;
        return is_dereferenceable_and_aligned_pointer_ty(op(i, 0), vtype(i), inst(i).align, q);
    }
    return is_safe_to_speculatively_execute(i);
}
