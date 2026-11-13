// MemorySanitizerVisitor's intrinsic handlers (llvm/lib/Transforms/Instrumentation/MemorySanitizer.cpp:
// handle*Intrinsic, maybeHandleSimpleNomemIntrinsic, maybeHandleUnknownIntrinsic, the masked memory and x86 SIMD
// handlers). The dispatch switches are generated: gen_msan_switch.jai.

Msan_Lanes :: enum u8 { BOTH; EVEN; ODD; }

msan_nargs :: (i: Value_Id) -> u32 { return call_arg_count(i); }
msan_arg :: (i: Value_Id, k: u32) -> Value_Id { return op(i, k); }

// a call of `callee` (a FunctionCallee with I's own function type) without folding
msan_call_like :: (b: *Irb, callee: Value_Id, fty: Type_Id, args: [] Value_Id, name := "") -> Value_Id {
    return san_call(b, .{fty, callee}, args, name);
}

// IRBuilder::CreateIntrinsic(RetTy, ID, Args) for an intrinsic with the same signature as the call `i`
msan_same_sig_intrinsic :: (i: Value_Id, base: string) -> San_Callee {
    callee := call_called_function(i);
    fty := inst(i).ty2;
    name := ifx base == function_intrinsic_base(callee) then vname(callee) else base;
    return .{fty, get_or_insert_function(name, fty)};
}

// maybeHandleSimpleNomemIntrinsic(I, trailingFlags)
msan_maybe_handle_simple_nomem_intrinsic :: (ms: *Msan, i: Value_Id, trailing: u32) -> bool {
    rt := vtype(i);
    st := scalar_type(rt);
    if !(type_kind(st) == .INT || is_fp_type(st)) return false;
    n := msan_nargs(i);
    for k: 0..cast(s64) n - cast(s64) trailing - 1 if vtype(op(i, cast(u32) k)) != rt return false;
    b: Irb; irb_set_before(*b, i);
    sc := msan_combiner(ms, *b, true);
    for k: 0..cast(s64) n - 1 msan_comb_add(*sc, op(i, cast(u32) k));
    msan_comb_done(*sc, i);
    return true;
}

// Instruction::onlyReadsMemory / doesNotAccessMemory for a call: CallBase::getMemoryEffects (inst_props.jai)
msan_call_memory_effects :: (c: Value_Id) -> u64 { return call_memory_effects(c); }

// handleVectorStoreIntrinsic
msan_handle_vector_store_intrinsic :: (ms: *Msan, i: Value_Id) -> bool {
    b: Irb; irb_set_before(*b, i);
    addr := op(i, 0);
    shadow := msan_get_shadow_op(ms, i, 1);
    sp, opp := msan_get_shadow_origin_ptr(ms, addr, *b, vtype(shadow), 1, true);
    irb_store(*b, shadow, sp, 1);
    if msan_cl.check_access_address msan_insert_check_shadow_of(ms, addr, i);
    if ms.track_origins { o := msan_get_origin_op(ms, i, 1); irb_store(*b, o, opp, dl_abi_align(vtype(o))); }
    return true;
}
// handleVectorLoadIntrinsic
msan_handle_vector_load_intrinsic :: (ms: *Msan, i: Value_Id) -> bool {
    b: Irb; irb_set_before(*b, i);
    addr := op(i, 0);
    st := msan_get_shadow_ty_v(ms, i);
    sp, opp: Value_Id = NONE;
    if ms.propagate_shadow {
        sp, opp = msan_get_shadow_origin_ptr(ms, addr, *b, st, 1, false);
        msan_set_shadow(ms, i, irb_load(*b, st, sp, 1, false, "_msld"));
    } else msan_set_shadow(ms, i, msan_get_clean_shadow_v(ms, i));
    if msan_cl.check_access_address msan_insert_check_shadow_of(ms, addr, i);
    if ms.track_origins {
        if ms.propagate_shadow msan_set_origin(ms, i, irb_load(*b, ms.origin_ty, opp, dl_abi_align(ms.origin_ty)));
        else msan_set_origin(ms, i, msan_get_clean_origin(ms));
    }
    return true;
}
// maybeHandleUnknownIntrinsicUnlogged / maybeHandleUnknownIntrinsic
msan_maybe_handle_unknown_intrinsic :: (ms: *Msan, i: Value_Id) -> bool {
    n := msan_nargs(i);
    if n == 0 return false;
    me := msan_call_memory_effects(i);
    if n == 2 && is_ptr_type(vtype(op(i, 0))) && is_vector_type(vtype(op(i, 1))) && vtype(i) == ir.t_void && !mem_only_reads(me)
        return msan_handle_vector_store_intrinsic(ms, i);
    if n == 1 && is_ptr_type(vtype(op(i, 0))) && is_vector_type(vtype(i)) && mem_only_reads(me)
        return msan_handle_vector_load_intrinsic(ms, i);
    if mem_does_not_access(me) && msan_maybe_handle_simple_nomem_intrinsic(ms, i, 0) {
        if msan_cl.dump_heuristic_instructions msan_dump_inst(i, "Heuristic");
        return true;
    }
    return false;
}

msan_handle_invariant_group :: (ms: *Msan, i: Value_Id) {
    msan_set_shadow(ms, i, msan_get_shadow_op(ms, i, 0));
    msan_set_origin(ms, i, msan_get_origin_op(ms, i, 0));
}
msan_handle_lifetime_start :: (ms: *Msan, i: Value_Id) {
    if !ms.poison_stack return;
    ai := op(i, 0);
    if is_inst(ai) && inst_op(ai) == .ALLOCA array_add(*ms.lifetime_start_list, .[i, ai]);
}
msan_handle_bswap :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    x := op(i, 0);
    msan_set_shadow(ms, i, irb_intrinsic(*b, "llvm.bswap", .[vtype(x)], .[msan_get_shadow(ms, x)]));
    msan_set_origin(ms, i, msan_get_origin(ms, x));
}
// handleCountLeadingTrailingZeros
msan_handle_count_leading_trailing_zeros :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    src := op(i, 0);
    ss := msan_get_shadow(ms, src);
    f := const_int(ir.t_i1, 0);
    base := function_intrinsic_base(call_called_function(i));
    conc := irb_intrinsic(*b, base, .[vtype(i)], .[src, f]);
    shz := irb_intrinsic(*b, base, .[vtype(i)], .[ss, f]);
    cmp := irb_icmp(*b, ICMP_UGE, conc, shz, "_mscz_cmp_zeros");
    nz := irb_icmp(*b, ICMP_NE, ss, const_null_value(vtype(ss)), "_mscz_shadow_not_null");
    out := irb_binop(*b, .AND, cmp, nz, "_mscz_main");
    izp := op(i, 1);
    if !is_null_value(izp) {
        bzp := irb_icmp(*b, ICMP_EQ, src, const_null_value(vtype(src)), "_mscz_bzp");
        out = irb_binop(*b, .OR, out, bzp, "_mscz_bs");
    }
    out = irb_cast(*b, .SEXT, out, msan_get_shadow_ty_v(ms, src), "_mscz_os");
    msan_set_shadow(ms, i, out);
    msan_set_origin_for_nary_op(ms, i);
}
// handleFunnelShift
msan_handle_funnel_shift :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    s0 := msan_get_shadow_op(ms, i, 0); s1 := msan_get_shadow_op(ms, i, 1); s2 := msan_get_shadow_op(ms, i, 2);
    s2c := irb_cast(*b, .SEXT, irb_icmp(*b, ICMP_NE, s2, msan_get_clean_shadow_v(ms, s2)), vtype(s2));
    base := function_intrinsic_base(call_called_function(i));
    shift := irb_intrinsic(*b, base, .[vtype(s2c)], .[s0, s1, op(i, 2)]);
    msan_set_shadow(ms, i, irb_binop(*b, .OR, shift, s2c));
    msan_set_origin_for_nary_op(ms, i);
}
// handleGenericBitManipulation
msan_handle_generic_bit_manipulation :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    st := msan_get_shadow_ty_v(ms, i);
    smask := msan_get_shadow_op(ms, i, 1);
    smask = irb_cast(*b, .SEXT, irb_icmp(*b, ICMP_NE, smask, msan_get_clean_shadow(ms, st)), st);
    s := msan_call_like(*b, call_called_function(i), inst(i).ty2, .[msan_get_shadow_op(ms, i, 0), op(i, 1)]);
    msan_set_shadow(ms, i, irb_binop(*b, .OR, smask, s));
    msan_set_origin_for_nary_op(ms, i);
}
// handleArithmeticWithOverflow
msan_handle_arithmetic_with_overflow :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    s0 := msan_get_shadow_op(ms, i, 0); s1 := msan_get_shadow_op(ms, i, 1);
    e0 := irb_binop(*b, .OR, s0, s1);
    e1 := irb_icmp(*b, ICMP_NE, e0, msan_get_clean_shadow_v(ms, e0));
    s := const_poison(msan_get_shadow_ty_v(ms, i));
    s = irb_insert_value(*b, s, e0, .[0]);
    s = irb_insert_value(*b, s, e1, .[1]);
    msan_set_shadow(ms, i, s);
    msan_set_origin_for_nary_op(ms, i);
}
// handleAbsIntrinsic
msan_handle_abs :: (ms: *Msan, i: Value_Id) {
    src := op(i, 0); poison_flag := op(i, 1);
    b: Irb; irb_set_before(*b, i);
    ss := msan_get_shadow(ms, src);
    minv := cf_int(vtype(src), ap_signed_min(type_bits(scalar_type(vtype(src)))));
    is_min := irb_icmp(*b, ICMP_EQ, src, minv);
    ps := msan_get_poisoned_shadow_v(ms, src);
    pim := irb_select(*b, is_min, ps, ss);
    msan_set_shadow(ms, i, irb_select(*b, poison_flag, pim, ss));
    msan_set_origin(ms, i, msan_get_origin_op(ms, i, 0));
}
msan_handle_is_fpclass :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    s := msan_get_shadow_op(ms, i, 0);
    msan_set_shadow(ms, i, irb_icmp(*b, ICMP_NE, s, msan_get_clean_shadow_v(ms, s)));
    msan_set_origin(ms, i, msan_get_origin_op(ms, i, 0));
}
// handleIntrinsicByApplyingToShadow(I, shadowIntrinsicID, trailingVerbatimArgs)
msan_handle_intrinsic_by_applying_to_shadow :: (ms: *Msan, i: Value_Id, shadow_intrinsic: string, trailing: u32) {
    b: Irb; irb_set_before(*b, i);
    n := msan_nargs(i);
    args: [..] Value_Id; args.allocator = temp;
    for k: 0..n - trailing - 1 array_add(*args, irb_bitcast(*b, msan_get_shadow_op(ms, i, k), vtype(op(i, k))));
    for k: n - trailing..n - 1 array_add(*args, op(i, k));
    c := msan_same_sig_intrinsic(i, shadow_intrinsic);
    combined := san_call(*b, c, args);
    for k: n - trailing..n - 1 {
        s := msan_create_shadow_cast(ms, *b, msan_get_shadow_op(ms, i, k), vtype(combined));
        combined = irb_binop(*b, .OR, s, combined, "_msprop");
    }
    msan_set_shadow(ms, i, irb_bitcast(*b, combined, msan_get_shadow_ty_v(ms, i)));
    msan_set_origin_for_nary_op(ms, i);
}

// ---------------------------------------------------------------- vector reductions

msan_irb_and_reduce :: (b: *Irb, v: Value_Id) -> Value_Id { return irb_intrinsic(b, "llvm.vector.reduce.and", .[vtype(v)], .[v]); }
msan_handle_vector_reduce :: (ms: *Msan, i: Value_Id, allow_shadow_cast: bool) {
    b: Irb; irb_set_before(*b, i);
    s := irb_or_reduce(*b, msan_get_shadow_op(ms, i, 0));
    if allow_shadow_cast s = msan_create_shadow_cast(ms, *b, s, msan_get_shadow_ty_v(ms, i));
    msan_set_shadow(ms, i, s);
    msan_set_origin_for_nary_op(ms, i);
}
msan_handle_vector_reduce_with_starter :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    s0 := msan_get_shadow_op(ms, i, 0);
    s1 := irb_or_reduce(*b, msan_get_shadow_op(ms, i, 1));
    msan_set_shadow(ms, i, irb_binop(*b, .OR, s0, s1));
    msan_set_origin_for_nary_op(ms, i);
}
msan_handle_vector_reduce_or :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    os := msan_get_shadow_op(ms, i, 0);
    unset := irb_not(*b, op(i, 0));
    unset_or_poison := irb_binop(*b, .OR, unset, os);
    mask := msan_irb_and_reduce(*b, unset_or_poison);
    ors := irb_or_reduce(*b, os);
    msan_set_shadow(ms, i, irb_binop(*b, .AND, mask, ors));
    msan_set_origin(ms, i, msan_get_origin_op(ms, i, 0));
}
msan_handle_vector_reduce_and :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    os := msan_get_shadow_op(ms, i, 0);
    set_or_poison := irb_binop(*b, .OR, op(i, 0), os);
    mask := msan_irb_and_reduce(*b, set_or_poison);
    ors := irb_or_reduce(*b, os);
    msan_set_shadow(ms, i, irb_binop(*b, .AND, mask, ors));
    msan_set_origin(ms, i, msan_get_origin_op(ms, i, 0));
}

// ---------------------------------------------------------------- masked memory intrinsics

msan_add_param_align :: (c: Value_Id, k: u32, align: u64) {
    if align == 0 return;
    a: Attr; a.kind = .Alignment; a.ty = NONE; a.ival = align;
    l := inst(c).attrs;
    inst(c).attrs = attr_list_with_param(l, k, attr_set_with(attr_list_param(l, k), a));
}
msan_masked_intrinsic :: (b: *Irb, base: string, otys: [] Type_Id, args: [] Value_Id, name := "") -> Value_Id {
    f := get_or_insert_intrinsic_declaration(intrinsic_id_by_name(base), otys);
    return san_call(b, .{glob(f).value_type, f}, args, name);
}

msan_handle_masked_expand_load :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    ptr := op(i, 0); al := call_param_align(i, 0); mask := op(i, 1); pass := op(i, 2);
    if msan_cl.check_access_address { msan_insert_check_shadow_of(ms, ptr, i); msan_insert_check_shadow_of(ms, mask, i); }
    if !ms.propagate_shadow { msan_set_clean(ms, i); return; }
    st := msan_get_shadow_ty_v(ms, i);
    est := type_elem(st);
    sp, _ := msan_get_shadow_origin_ptr(ms, ptr, *b, est, al, false);
    s := msan_masked_intrinsic(*b, "llvm.masked.expandload", .[st, vtype(sp)], .[sp, mask, msan_get_shadow(ms, pass)], "_msmaskedexpload");
    msan_add_param_align(s, 0, al);
    msan_set_shadow(ms, i, s);
    msan_set_origin(ms, i, msan_get_clean_origin(ms));
}
msan_handle_masked_compress_store :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    vals := op(i, 0); ptr := op(i, 1); al := call_param_align(i, 1); mask := op(i, 2);
    if msan_cl.check_access_address { msan_insert_check_shadow_of(ms, ptr, i); msan_insert_check_shadow_of(ms, mask, i); }
    s := msan_get_shadow(ms, vals);
    est := msan_get_shadow_ty(ms, type_elem(vtype(vals)));
    sp, _ := msan_get_shadow_origin_ptr(ms, ptr, *b, est, al, true);
    c := msan_masked_intrinsic(*b, "llvm.masked.compressstore", .[vtype(s), vtype(sp)], .[s, sp, mask]);
    msan_add_param_align(c, 1, al);
}
msan_handle_masked_gather :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    ptrs := op(i, 0); al := max(call_param_align(i, 0), 1); mask := op(i, 1); pass := op(i, 2);
    pst := msan_get_shadow_ty_v(ms, ptrs);
    if msan_cl.check_access_address {
        msan_insert_check_shadow_of(ms, mask, i);
        mps := irb_select(*b, mask, msan_get_shadow(ms, ptrs), const_null_value(pst), "_msmaskedptrs");
        msan_insert_check_shadow(ms, mps, msan_get_origin(ms, ptrs), i);
    }
    if !ms.propagate_shadow { msan_set_clean(ms, i); return; }
    st := msan_get_shadow_ty_v(ms, i);
    sps, _ := msan_get_shadow_origin_ptr(ms, ptrs, *b, type_elem(st), al, false);
    s := msan_masked_intrinsic(*b, "llvm.masked.gather", .[st, vtype(sps)], .[sps, mask, msan_get_shadow(ms, pass)], "_msmaskedgather");
    msan_add_param_align(s, 0, al);
    msan_set_shadow(ms, i, s);
    msan_set_origin(ms, i, msan_get_clean_origin(ms));
}
msan_handle_masked_scatter :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    vals := op(i, 0); ptrs := op(i, 1); al := max(call_param_align(i, 1), 1); mask := op(i, 2);
    pst := msan_get_shadow_ty_v(ms, ptrs);
    if msan_cl.check_access_address {
        msan_insert_check_shadow_of(ms, mask, i);
        mps := irb_select(*b, mask, msan_get_shadow(ms, ptrs), const_null_value(pst), "_msmaskedptrs");
        msan_insert_check_shadow(ms, mps, msan_get_origin(ms, ptrs), i);
    }
    s := msan_get_shadow(ms, vals);
    est := msan_get_shadow_ty(ms, type_elem(vtype(vals)));
    sps, _ := msan_get_shadow_origin_ptr(ms, ptrs, *b, est, al, true);
    c := msan_masked_intrinsic(*b, "llvm.masked.scatter", .[vtype(s), vtype(sps)], .[s, sps, mask]);
    msan_add_param_align(c, 1, al);
}
msan_handle_masked_store :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    v := op(i, 0); ptr := op(i, 1); al := max(call_param_align(i, 1), 1); mask := op(i, 2);
    s := msan_get_shadow(ms, v);
    if msan_cl.check_access_address { msan_insert_check_shadow_of(ms, ptr, i); msan_insert_check_shadow_of(ms, mask, i); }
    sp, opp := msan_get_shadow_origin_ptr(ms, ptr, *b, vtype(s), al, true);
    c := msan_masked_intrinsic(*b, "llvm.masked.store", .[vtype(s), vtype(sp)], .[s, sp, mask]);
    msan_add_param_align(c, 1, al);
    if !ms.track_origins return;
    sz, sc := msan_store_size(vtype(s));
    msan_paint_origin(ms, *b, msan_get_origin(ms, v), opp, sz, sc, max(al, cast(u64) MSAN_K_MIN_ORIGIN_ALIGNMENT));
}
msan_handle_masked_load :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    ptr := op(i, 0); al := max(call_param_align(i, 0), 1); mask := op(i, 1); pass := op(i, 2);
    if msan_cl.check_access_address { msan_insert_check_shadow_of(ms, ptr, i); msan_insert_check_shadow_of(ms, mask, i); }
    if !ms.propagate_shadow { msan_set_clean(ms, i); return; }
    st := msan_get_shadow_ty_v(ms, i);
    sp, opp := msan_get_shadow_origin_ptr(ms, ptr, *b, st, al, false);
    s := msan_masked_intrinsic(*b, "llvm.masked.load", .[st, vtype(sp)], .[sp, mask, msan_get_shadow(ms, pass)], "_msmaskedld");
    msan_add_param_align(s, 0, al);
    msan_set_shadow(ms, i, s);
    if !ms.track_origins return;
    neg := irb_binop(*b, .SUB, const_null_value(vtype(mask)), mask);   // CreateNeg
    mpts := irb_binop(*b, .AND, msan_get_shadow(ms, pass), irb_cast(*b, .SEXT, neg, st));
    not_null := msan_convert_to_bool(ms, mpts, *b, "_mscmp");
    po := irb_load(*b, ms.origin_ty, opp, dl_abi_align(ms.origin_ty));
    msan_set_origin(ms, i, irb_select(*b, not_null, msan_get_origin(ms, pass), po));
}

// ---------------------------------------------------------------- x86 SIMD handlers

msan_handle_stmxcsr :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    addr := op(i, 0);
    sp, _ := msan_get_shadow_origin_ptr(ms, addr, *b, ir.t_i32, 1, true);
    irb_store(*b, msan_get_clean_shadow(ms, ir.t_i32), sp, dl_abi_align(ir.t_i32));
    if msan_cl.check_access_address msan_insert_check_shadow_of(ms, addr, i);
}
msan_handle_ldmxcsr :: (ms: *Msan, i: Value_Id) {
    if !ms.insert_checks return;
    b: Irb; irb_set_before(*b, i);
    addr := op(i, 0);
    sp, opp := msan_get_shadow_origin_ptr(ms, addr, *b, ir.t_i32, 1, false);
    if msan_cl.check_access_address msan_insert_check_shadow_of(ms, addr, i);
    s := irb_load(*b, ir.t_i32, sp, 1, false, "_ldmxcsr");
    o := ifx ms.track_origins then irb_load(*b, ms.origin_ty, opp, dl_abi_align(ms.origin_ty)) else msan_get_clean_origin(ms);
    msan_insert_check_shadow(ms, s, o, i);
}

// maybeShrinkVectorShadowType / maybeExtendVectorShadowWithZeros
msan_maybe_shrink_vector_shadow_type :: (ms: *Msan, src: Value_Id, i: Value_Id) -> Type_Id {
    st := msan_get_shadow_ty_v(ms, i);
    if type_count(st) == type_count(vtype(src)) * 2 st = type_vector(type_count(st) / 2, type_elem(st), false);
    return st;
}
msan_maybe_extend_vector_shadow_with_zeros :: (ms: *Msan, shadow: Value_Id, i: Value_Id) -> Value_Id {
    b: Irb; irb_set_before(*b, i);
    full := msan_get_clean_shadow_v(ms, i);
    sn := type_count(vtype(shadow));
    fn := type_count(vtype(full));
    if sn == fn return shadow;
    mask := NewArray(cast(s64) fn, u32,, temp);
    for k: 0..cast(s64) fn - 1 mask[k] = cast(u32) k;
    return irb_shuffle(*b, shadow, msan_get_clean_shadow_v(ms, shadow), mask);
}

// handleSSEVectorConvertIntrinsicByProp(I, HasRoundingMode)
msan_handle_sse_vector_convert_by_prop :: (ms: *Msan, i: Value_Id, has_rounding_mode: bool) {
    src := op(i, 0);
    st := msan_maybe_shrink_vector_shadow_type(ms, src, i);
    b: Irb; irb_set_before(*b, i);
    s0 := msan_get_shadow_op(ms, i, 0);
    s := irb_cast(*b, .SEXT, irb_icmp(*b, ICMP_NE, s0, msan_get_clean_shadow_v(ms, s0)), st);
    msan_set_shadow(ms, i, msan_maybe_extend_vector_shadow_with_zeros(ms, s, i));
    msan_set_origin_for_nary_op(ms, i);
}

// handleSSEVectorConvertIntrinsic(I, NumUsedElements, HasRoundingMode)
msan_handle_sse_vector_convert :: (ms: *Msan, i: Value_Id, num_used: s64, has_rounding_mode := false) {
    b: Irb; irb_set_before(*b, i);
    copy_op, convert_op: Value_Id = NONE;
    na := cast(s64) msan_nargs(i) - cast(s64) has_rounding_mode;
    if na == 2 { copy_op = op(i, 0); convert_op = op(i, 1); }
    else if na == 1 { convert_op = op(i, 0); }
    else fatal("internal: msan: cvt intrinsic with unsupported number of arguments");
    cs := msan_get_shadow(ms, convert_op);
    agg: Value_Id;
    if is_vector_type(vtype(convert_op)) {
        agg = irb_extract_element_v(*b, cs, const_int(ir.t_i32, 0));
        for k: 1..num_used-1 agg = irb_binop(*b, .OR, agg, irb_extract_element_v(*b, cs, const_int(ir.t_i32, cast(u64) k)));
    } else agg = cs;
    msan_insert_check_shadow(ms, agg, msan_get_origin(ms, convert_op), i);
    if copy_op != NONE {
        rs := msan_get_shadow(ms, copy_op);
        et := type_elem(vtype(rs));
        for k: 0..num_used-1 rs = irb_insert_element_v(*b, rs, const_null_value(et), const_int(ir.t_i32, cast(u64) k));
        msan_set_shadow(ms, i, rs);
        msan_set_origin(ms, i, msan_get_origin(ms, copy_op));
    } else msan_set_clean(ms, i);
}

// Lower64ShadowExtend / LowerElementShadowExtend / VariableShadowExtend
msan_lower64_shadow_extend :: (ms: *Msan, b: *Irb, s_in: Value_Id, t: Type_Id) -> Value_Id {
    s := s_in;
    if is_vector_type(vtype(s)) s = msan_create_shadow_cast(ms, b, s, type_int(64), true);
    s2 := irb_icmp(b, ICMP_NE, s, msan_get_clean_shadow_v(ms, s));
    return msan_create_shadow_cast(ms, b, s2, t, true);
}
msan_lower_element_shadow_extend :: (ms: *Msan, b: *Irb, s: Value_Id, t: Type_Id) -> Value_Id {
    s1 := irb_extract_element(b, s, 0);
    s2 := irb_icmp(b, ICMP_NE, s1, msan_get_clean_shadow_v(ms, s1));
    return msan_create_shadow_cast(ms, b, s2, t, true);
}
msan_variable_shadow_extend :: (ms: *Msan, b: *Irb, s: Value_Id) -> Value_Id {
    s2 := irb_icmp(b, ICMP_NE, s, msan_get_clean_shadow_v(ms, s));
    return irb_cast(b, .SEXT, s2, vtype(s));
}
// handleVectorShiftIntrinsic(I, Variable)
msan_handle_vector_shift :: (ms: *Msan, i: Value_Id, variable: bool) {
    b: Irb; irb_set_before(*b, i);
    s1 := msan_get_shadow_op(ms, i, 0); s2 := msan_get_shadow_op(ms, i, 1);
    s2c := ifx variable then msan_variable_shadow_extend(ms, *b, s2) else msan_lower64_shadow_extend(ms, *b, s2, msan_get_shadow_ty_v(ms, i));
    v1 := op(i, 0); v2 := op(i, 1);
    shift := msan_call_like(*b, call_callee(i), inst(i).ty2, .[irb_bitcast(*b, s1, vtype(v1)), v2]);
    shift = irb_bitcast(*b, shift, msan_get_shadow_ty_v(ms, i));
    msan_set_shadow(ms, i, irb_binop(*b, .OR, shift, s2c));
    msan_set_origin_for_nary_op(ms, i);
}
msan_get_mmx_vector_ty :: (elt_bits: u64, mmx_bits: u64 = 64) -> Type_Id { return type_vector(mmx_bits / elt_bits, type_int(elt_bits), false); }

// getSignedPackIntrinsic
msan_get_signed_pack_intrinsic :: (n: string) -> string {
    if n == {
        case "llvm.x86.sse2.packsswb.128"; #through; case "llvm.x86.sse2.packuswb.128"; return "llvm.x86.sse2.packsswb.128";
        case "llvm.x86.sse2.packssdw.128"; #through; case "llvm.x86.sse41.packusdw"; return "llvm.x86.sse2.packssdw.128";
        case "llvm.x86.avx2.packsswb"; #through; case "llvm.x86.avx2.packuswb"; return "llvm.x86.avx2.packsswb";
        case "llvm.x86.avx2.packssdw"; #through; case "llvm.x86.avx2.packusdw"; return "llvm.x86.avx2.packssdw";
        case "llvm.x86.mmx.packsswb"; #through; case "llvm.x86.mmx.packuswb"; return "llvm.x86.mmx.packsswb";
        case "llvm.x86.mmx.packssdw"; return "llvm.x86.mmx.packssdw";
        case "llvm.x86.avx512.packssdw.512"; #through; case "llvm.x86.avx512.packusdw.512"; return "llvm.x86.avx512.packssdw.512";
        case "llvm.x86.avx512.packsswb.512"; #through; case "llvm.x86.avx512.packuswb.512"; return "llvm.x86.avx512.packsswb.512";
    }
    fatal("internal: msan: unexpected intrinsic id");
    return "";
}
// handleVectorPackIntrinsic(I, MMXEltSizeInBits)
msan_handle_vector_pack :: (ms: *Msan, i: Value_Id, mmx_elt_bits: u64 = 0) {
    b: Irb; irb_set_before(*b, i);
    s1 := msan_get_shadow_op(ms, i, 0); s2 := msan_get_shadow_op(ms, i, 1);
    t := ifx mmx_elt_bits then msan_get_mmx_vector_ty(mmx_elt_bits) else vtype(s1);
    if mmx_elt_bits { s1 = irb_bitcast(*b, s1, t); s2 = irb_bitcast(*b, s2, t); }
    s1e := irb_cast(*b, .SEXT, irb_icmp(*b, ICMP_NE, s1, const_null_value(t)), t);
    s2e := irb_cast(*b, .SEXT, irb_icmp(*b, ICMP_NE, s2, const_null_value(t)), t);
    if mmx_elt_bits { s1e = irb_bitcast(*b, s1e, msan_get_mmx_vector_ty(64)); s2e = irb_bitcast(*b, s2e, msan_get_mmx_vector_ty(64)); }
    pk := msan_get_signed_pack_intrinsic(function_intrinsic_base(call_called_function(i)));
    f := get_or_insert_intrinsic_declaration(intrinsic_id_by_name(pk), .[]);
    s := san_call(*b, .{glob(f).value_type, f}, .[s1e, s2e], "_msprop_vector_pack");
    if mmx_elt_bits s = irb_bitcast(*b, s, msan_get_shadow_ty_v(ms, i));
    msan_set_shadow(ms, i, s);
    msan_set_origin_for_nary_op(ms, i);
}

// createDppMask / findDppPoisonedOutput / handleDppIntrinsic
msan_create_dpp_mask :: (width: u64, mask_in: u64) -> Value_Id {
    els := NewArray(cast(s64) width, Value_Id,, temp);
    mask := mask_in;
    for * els { it.* = const_int(ir.t_i1, mask & 1); mask >>= 1; }
    return const_aggregate(.C_VECTOR, type_vector(width, ir.t_i1, false), els);
}
msan_find_dpp_poisoned_output :: (ms: *Msan, b: *Irb, s_in: Value_Id, src_mask: u64, dst_mask: u64) -> Value_Id {
    width := type_count(vtype(s_in));
    s := irb_select(b, msan_create_dpp_mask(width, src_mask), s_in, const_null_value(vtype(s_in)));
    se := irb_or_reduce(b, s);
    is_clean := irb_icmp(b, ICMP_EQ, se, const_null_value(vtype(se)), "_msdpp");
    dm := msan_create_dpp_mask(width, dst_mask);
    return irb_select(b, is_clean, const_null_value(vtype(dm)), dm);
}
msan_handle_dpp :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    s := irb_binop(*b, .OR, msan_get_shadow_op(ms, i, 0), msan_get_shadow_op(ms, i, 1));
    width := type_count(vtype(s));
    mask := const_int_zext(op(i, 2));
    src_mask := mask >> 4; dst_mask := mask & 0xf;
    si1 := msan_find_dpp_poisoned_output(ms, *b, s, src_mask, dst_mask);
    if width == 8 si1 = irb_binop(*b, .OR, si1, msan_find_dpp_poisoned_output(ms, *b, s, src_mask << 4, dst_mask << 4));
    s = irb_cast(*b, .SEXT, si1, vtype(s), "_msdpp");
    msan_set_shadow(ms, i, s);
    msan_set_origin_for_nary_op(ms, i);
}

// convertBlendvToSelectMask / handleBlendvIntrinsic
msan_convert_blendv_to_select_mask :: (ms: *Msan, b: *Irb, c_in: Value_Id) -> Value_Id {
    c := msan_create_app_to_shadow_cast(ms, b, c_in);
    ct := vtype(c);
    el := type_bits(type_elem(ct));
    c = irb_binop(b, .ASHR, c, cf_int(ct, ap_from_u64(cast(u32) el, el - 1)));
    return irb_cast(b, .TRUNC, c, type_vector(type_count(ct), ir.t_i1, false));
}
msan_handle_blendv :: (ms: *Msan, i: Value_Id) {
    c := op(i, 2); t := op(i, 1); f := op(i, 0);
    sc := msan_get_shadow_op(ms, i, 2);
    oc := ifx ms.track_origins then msan_get_origin(ms, c) else NONE;
    {
        b: Irb; irb_set_before(*b, i);
        c = msan_convert_blendv_to_select_mask(ms, *b, c);
        sc = msan_convert_blendv_to_select_mask(ms, *b, sc);
        msan_set_shadow(ms, c, sc);
        msan_set_origin(ms, c, oc);
    }
    msan_handle_select_like(ms, i, c, t, f);
}

// handleVectorSadIntrinsic(I, IsMMX)
msan_handle_vector_sad :: (ms: *Msan, i: Value_Id, is_mmx := false) {
    res_ty := ifx is_mmx then type_int(64) else vtype(i);
    zero_bits := type_bits(scalar_type(res_ty)) - 16;
    b: Irb; irb_set_before(*b, i);
    s := irb_binop(*b, .OR, msan_get_shadow_op(ms, i, 0), msan_get_shadow_op(ms, i, 1));
    s = irb_bitcast(*b, s, res_ty);
    s = irb_cast(*b, .SEXT, irb_icmp(*b, ICMP_NE, s, const_null_value(res_ty)), res_ty);
    s = irb_binop(*b, .LSHR, s, cf_int(res_ty, ap_from_u64(cast(u32) type_bits(scalar_type(res_ty)), zero_bits)));
    s = irb_bitcast(*b, s, msan_get_shadow_ty_v(ms, i));
    msan_set_shadow(ms, i, s);
    msan_set_origin_for_nary_op(ms, i);
}

// getPclmulMask
msan_pclmul_mask :: (width: u64, odd: bool) -> [..] u32 {
    m: [..] u32; m.allocator = temp;
    x: u64 = ifx odd then cast(u64) 1 else 0;
    while x < width { array_add(*m, cast(u32) x); array_add(*m, cast(u32) x); x += 2; }
    return m;
}

// handleVectorDotProductIntrinsic(I, ReductionFactor, ZeroPurifies, EltSizeInBits, Lanes)
msan_handle_vector_dot_product :: (ms: *Msan, i: Value_Id, reduction: u64, zero_purifies: bool, elt_bits: u64, lanes: Msan_Lanes) {
    b: Irb; irb_set_before(*b, i);
    rt := vtype(i);
    va, vb, sa, sb: Value_Id;
    na := msan_nargs(i);
    if na == 2 {
        va = op(i, 0); vb = op(i, 1); sa = msan_get_shadow_op(ms, i, 0); sb = msan_get_shadow_op(ms, i, 1);
    } else {
        va = op(i, 1); vb = op(i, 2); sa = msan_get_shadow_op(ms, i, 1); sb = msan_get_shadow_op(ms, i, 2);
        if lanes == .EVEN || lanes == .ODD {
            w := type_count(vtype(sa));
            sa = irb_shuffle(*b, sa, NONE, msan_pclmul_mask(w, lanes == .ODD));
            sb = irb_shuffle(*b, sb, NONE, msan_pclmul_mask(w, lanes == .ODD));
        }
    }
    param_ty := vtype(va);
    implicit_rt := msan_get_shadow_ty(ms, rt);
    if elt_bits {
        pbits := dl_type_size_bits(param_ty);
        implicit_rt = msan_get_mmx_vector_ty(elt_bits * reduction, pbits);
        param_ty = msan_get_mmx_vector_ty(elt_bits, pbits);
        va = irb_bitcast(*b, va, param_ty); vb = irb_bitcast(*b, vb, param_ty);
        sa = irb_bitcast(*b, sa, msan_get_shadow_ty(ms, param_ty)); sb = irb_bitcast(*b, sb, msan_get_shadow_ty(ms, param_ty));
    }
    sa_nz := irb_icmp(*b, ICMP_NE, sa, const_null_value(vtype(sa)));
    sb_nz := irb_icmp(*b, ICMP_NE, sb, const_null_value(vtype(sb)));
    and: Value_Id;
    if zero_purifies {
        va_int := va; vb_int := vb;
        if type_kind(vtype(va)) != .INT { va_int = msan_create_app_to_shadow_cast(ms, *b, va); vb_int = msan_create_app_to_shadow_cast(ms, *b, vb); }
        va_nz := irb_icmp(*b, ICMP_NE, va_int, const_null_value(vtype(va_int)));
        vb_nz := irb_icmp(*b, ICMP_NE, vb_int, const_null_value(vtype(vb_int)));
        and = msan_handle_bitwise_and(ms, *b, va_nz, vb_nz, sa_nz, sb_nz);
    } else {
        and = irb_binop(*b, .OR, sa_nz, sb_nz);
    }
    and = irb_cast(*b, .SEXT, and, vtype(sa));
    horizontal := irb_bitcast(*b, and, implicit_rt);
    out := irb_cast(*b, .SEXT, irb_icmp(*b, ICMP_NE, horizontal, const_null_value(vtype(horizontal))), implicit_rt);
    if elt_bits out = msan_create_shadow_cast(ms, *b, out, msan_get_shadow_ty_v(ms, i));
    if na == 3 out = irb_binop(*b, .OR, out, msan_get_shadow_op(ms, i, 0));
    msan_set_shadow(ms, i, out);
    msan_set_origin_for_nary_op(ms, i);
}

// handleVectorComparePackedIntrinsic / handleVectorCompareScalarIntrinsic
msan_handle_vector_compare_packed :: (ms: *Msan, i: Value_Id, predicate_as_operand: bool) {
    b: Irb; irb_set_before(*b, i);
    rt := msan_get_shadow_ty_v(ms, i);
    s0 := irb_binop(*b, .OR, msan_get_shadow_op(ms, i, 0), msan_get_shadow_op(ms, i, 1));
    s := irb_cast(*b, .SEXT, irb_icmp(*b, ICMP_NE, s0, const_null_value(rt)), rt);
    msan_set_shadow(ms, i, s);
    msan_set_origin_for_nary_op(ms, i);
}
msan_handle_vector_compare_scalar :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    s0 := irb_binop(*b, .OR, msan_get_shadow_op(ms, i, 0), msan_get_shadow_op(ms, i, 1));
    msan_set_shadow(ms, i, msan_lower_element_shadow_extend(ms, *b, s0, msan_get_shadow_ty_v(ms, i)));
    msan_set_origin_for_nary_op(ms, i);
}

// handlePclmulIntrinsic
msan_handle_pclmul :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    width := type_count(vtype(op(i, 0)));
    imm := const_int_zext(op(i, 2));
    s0 := irb_shuffle(*b, msan_get_shadow_op(ms, i, 0), NONE, msan_pclmul_mask(width, (imm & 0x01) != 0));
    s1 := irb_shuffle(*b, msan_get_shadow_op(ms, i, 1), NONE, msan_pclmul_mask(width, (imm & 0x10) != 0));
    soc := msan_combiner(ms, *b, true);
    msan_comb_add_so(*soc, s0, msan_get_origin_op(ms, i, 0));
    msan_comb_add_so(*soc, s1, msan_get_origin_op(ms, i, 1));
    msan_comb_done(*soc, i);
}
// handleUnarySdSsIntrinsic / handleBinarySdSsIntrinsic
msan_sd_ss_mask :: (width: u64) -> [..] u32 {
    m: [..] u32; m.allocator = temp;
    array_add(*m, cast(u32) width);
    for k: 1..cast(s64) width - 1 array_add(*m, cast(u32) k);
    return m;
}
msan_handle_unary_sd_ss :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    width := type_count(vtype(op(i, 0)));
    s := irb_shuffle(*b, msan_get_shadow_op(ms, i, 0), msan_get_shadow_op(ms, i, 1), msan_sd_ss_mask(width));
    msan_set_shadow(ms, i, s);
    msan_set_origin_for_nary_op(ms, i);
}
msan_handle_binary_sd_ss :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    width := type_count(vtype(op(i, 0)));
    first := msan_get_shadow_op(ms, i, 0); second := msan_get_shadow_op(ms, i, 1);
    ors := irb_binop(*b, .OR, first, second);
    msan_set_shadow(ms, i, irb_shuffle(*b, first, ors, msan_sd_ss_mask(width)));
    msan_set_origin_for_nary_op(ms, i);
}
// handleVtestIntrinsic
msan_handle_vtest :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    o := irb_binop(*b, .OR, msan_get_shadow_op(ms, i, 0), msan_get_shadow_op(ms, i, 1));
    nz := irb_icmp(*b, ICMP_NE, o, const_null_value(vtype(o)));
    scalar := msan_convert_shadow_to_scalar(ms, nz, *b);
    msan_set_shadow(ms, i, irb_cast(*b, .ZEXT, scalar, msan_get_shadow_ty_v(ms, i)));
    msan_set_origin_for_nary_op(ms, i);
}
// handleRoundPdPsIntrinsic
msan_handle_round_pd_ps :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    sc := msan_combiner(ms, *b, true);
    msan_comb_add(*sc, op(i, 0));
    msan_comb_done(*sc, i);
}

// horizontalReduce
msan_horizontal_reduce :: (ms: *Msan, i: Value_Id, reduction: u64, shards: u64, va: Value_Id, vb: Value_Id) -> Value_Id {
    n := type_count(vtype(va));
    or: Value_Id = NONE;
    b: Irb; irb_set_before(*b, i);
    for r: 0..cast(s64) reduction - 1 {
        mask: [..] u32; mask.allocator = temp;
        for j: 0..cast(s64) shards - 1 {
            off := n / shards * cast(u64) j;
            x: u64 = 0;
            while x < n / shards { array_add(*mask, cast(u32)(off + x + cast(u64) r)); x += reduction; }
            if vb != NONE {
                x = 0;
                while x < n / shards { array_add(*mask, cast(u32)(n + off + x + cast(u64) r)); x += reduction; }
            }
        }
        masked := irb_shuffle(*b, va, vb, mask);
        if or != NONE or = irb_binop(*b, .OR, or, masked); else or = masked;
    }
    return or;
}
// handlePairwiseShadowOrIntrinsic(I, Shards[, ReinterpretElemWidth])
msan_handle_pairwise_shadow_or :: (ms: *Msan, i: Value_Id, shards: u64, reinterpret_elem_width: u64 = 0) {
    b: Irb; irb_set_before(*b, i);
    first := msan_get_shadow_op(ms, i, 0);
    second: Value_Id = NONE;
    if reinterpret_elem_width {
        pbits := dl_type_size_bits(vtype(op(i, 0)));
        rt := type_vector(pbits / reinterpret_elem_width, type_int(reinterpret_elem_width), false);
        first = irb_bitcast(*b, first, rt);
        if msan_nargs(i) == 2 second = irb_bitcast(*b, msan_get_shadow_op(ms, i, 1), rt);
    } else if msan_nargs(i) == 2 second = msan_get_shadow_op(ms, i, 1);
    ors := msan_horizontal_reduce(ms, i, 2, shards, first, second);
    ors = msan_create_shadow_cast(ms, *b, ors, msan_get_shadow_ty_v(ms, i));
    msan_set_shadow(ms, i, ors);
    msan_set_origin_for_nary_op(ms, i);
}

// handleAVXMaskedStore / handleAVXMaskedLoad
msan_handle_avx_masked_store :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    dst := op(i, 0); mask := op(i, 1); src := op(i, 2);
    ss := msan_get_shadow(ms, src);
    if msan_cl.check_access_address { msan_insert_check_shadow_of(ms, dst, i); msan_insert_check_shadow_of(ms, mask, i); }
    dsp, dop := msan_get_shadow_origin_ptr(ms, dst, *b, vtype(ss), 1, true);
    ci := msan_call_like(*b, call_called_function(i), inst(i).ty2, .[dsp, mask, irb_bitcast(*b, ss, vtype(src))]);
    msan_set_shadow(ms, i, ci);
    if !ms.track_origins return;
    sz, sc := msan_store_size(vtype(ss));
    msan_paint_origin(ms, *b, msan_get_origin(ms, src), dop, sz, sc, MSAN_K_MIN_ORIGIN_ALIGNMENT);
}
msan_handle_avx_masked_load :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    src := op(i, 0); mask := op(i, 1);
    if msan_cl.check_access_address msan_insert_check_shadow_of(ms, mask, i);
    sst := msan_get_shadow_ty_v(ms, src);
    ssp, sop := msan_get_shadow_origin_ptr(ms, src, *b, sst, 1, false);
    ci := msan_call_like(*b, call_called_function(i), inst(i).ty2, .[ssp, mask]);
    msan_set_shadow(ms, i, irb_bitcast(*b, ci, msan_get_shadow_ty_v(ms, i)));
    if !ms.track_origins return;
    msan_set_origin(ms, i, irb_load(*b, ms.origin_ty, sop, dl_abi_align(ms.origin_ty)));
}
// maskedCheckAVXIndexShadow
msan_masked_check_avx_index_shadow :: (ms: *Msan, b: *Irb, idx: Value_Id, i: Value_Id) {
    n := type_count(vtype(idx));
    if is_constant_kind(vkind(idx)) return;
    is := msan_get_shadow(ms, idx);
    lg: u64 = 0; while ((cast(u64) 1) << lg) < n lg += 1;
    t := irb_cast(b, .TRUNC, is, type_vector(n, type_int(lg), false));
    msan_insert_check_shadow(ms, t, msan_get_origin(ms, idx), i);
}
msan_handle_avx_vpermilvar :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    s := msan_get_shadow_op(ms, i, 0);
    msan_masked_check_avx_index_shadow(ms, *b, op(i, 1), i);
    s = irb_bitcast(*b, s, vtype(op(i, 0)));
    ci := msan_call_like(*b, call_called_function(i), inst(i).ty2, .[s, op(i, 1)]);
    msan_set_shadow(ms, i, irb_bitcast(*b, ci, msan_get_shadow_ty_v(ms, i)));
    msan_set_origin_for_nary_op(ms, i);
}
msan_handle_avx_vpermi2var :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    as := msan_get_shadow_op(ms, i, 0); idx := op(i, 1); bs := msan_get_shadow_op(ms, i, 2);
    msan_masked_check_avx_index_shadow(ms, *b, idx, i);
    as = irb_bitcast(*b, as, vtype(op(i, 0)));
    bs = irb_bitcast(*b, bs, vtype(op(i, 2)));
    ci := msan_call_like(*b, call_called_function(i), inst(i).ty2, .[as, idx, bs]);
    msan_set_shadow(ms, i, irb_bitcast(*b, ci, msan_get_shadow_ty_v(ms, i)));
    msan_set_origin_for_nary_op(ms, i);
}

// handleAVX512VectorConvertFPToInt(I, LastMask)
msan_handle_avx512_vector_convert_fp_to_int :: (ms: *Msan, i: Value_Id, last_mask: bool) {
    b: Irb; irb_set_before(*b, i);
    a := op(i, 0);
    wt, mask, rm: Value_Id;
    if last_mask { wt = op(i, 2); mask = op(i, 3); rm = op(i, 1); }
    else { wt = op(i, 1); mask = op(i, 2); rm = op(i, 3); }
    an := type_count(vtype(a));
    mn := type_bits(vtype(mask));
    msan_insert_check_shadow_of(ms, mask, i);
    msan_insert_check_shadow_of(ms, rm, i);
    ash := msan_get_shadow(ms, a);
    ash = msan_maybe_extend_vector_shadow_with_zeros(ms, ash, i);
    if an * 2 == mn {
        mask = irb_cast(*b, .TRUNC, mask, type_int(an), "_ms_mask_trunc");
        mask = irb_cast(*b, .ZEXT, mask, type_int(mn), "_ms_mask_zext");
    }
    mask = irb_bitcast(*b, mask, type_vector(mn, ir.t_i1, false), "_ms_mask_bitcast");
    ash = irb_cast(*b, .SEXT, irb_icmp(*b, ICMP_NE, ash, msan_get_clean_shadow(ms, vtype(ash))), msan_get_shadow_ty_v(ms, i), "_ms_a_shadow");
    wts := msan_get_shadow(ms, wt);
    msan_set_shadow(ms, i, irb_select(*b, mask, ash, wts, "_ms_writethru_select"));
    msan_set_origin_for_nary_op(ms, i);
}

// extractLowerShadow
msan_extract_lower_shadow :: (ms: *Msan, b: *Irb, v: Value_Id) -> Value_Id {
    return irb_extract_element_v(b, msan_get_shadow(ms, v), const_int(ir.t_i32, 0));
}
// handleAVX512VectorDownConvert
msan_handle_avx512_vector_down_convert :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    a := op(i, 0); wt := op(i, 1); mask := op(i, 2);
    an := type_count(vtype(a));
    on := type_count(vtype(wt));
    msan_insert_check_shadow_of(ms, mask, i);
    if type_bits(vtype(mask)) == 8 && on < 8 mask = irb_cast(*b, .TRUNC, mask, type_int(on));
    if an != on {
        mask = irb_not(*b, mask);
        mask = irb_cast(*b, .ZEXT, mask, type_int(on), "_ms_widen_mask");
        mask = irb_not(*b, mask);
    }
    mask = irb_bitcast(*b, mask, type_vector(on, ir.t_i1, false));
    ash := msan_get_shadow(ms, a);
    st := msan_maybe_shrink_vector_shadow_type(ms, a, i);
    ash = irb_cast(*b, .TRUNC, ash, st, "_ms_trunc_shadow");
    ash = msan_maybe_extend_vector_shadow_with_zeros(ms, ash, i);
    wts := msan_get_shadow(ms, wt);
    msan_set_shadow(ms, i, irb_select(*b, mask, ash, wts));
    msan_set_origin_for_nary_op(ms, i);
}
// handleAVX512VectorGenericMaskedFP(I, DataIndices, WriteThruIndex, MaskIndex)
msan_handle_avx512_vector_generic_masked_fp :: (ms: *Msan, i: Value_Id, data: [] u32, wt_index: u32, mask_index: u32) {
    b: Irb; irb_set_before(*b, i);
    na := msan_nargs(i);
    wt := op(i, wt_index);
    on := type_count(vtype(wt));
    is_data: [16] bool;
    for data is_data[it] = true;
    mask := op(i, mask_index);
    for k: 0..cast(s64) na - 1 if !is_data[k] && cast(u32) k != wt_index msan_insert_check_shadow_of(ms, op(i, cast(u32) k), i);
    if type_bits(vtype(mask)) == 8 && on < 8 mask = irb_cast(*b, .TRUNC, mask, type_int(on));
    mask = irb_bitcast(*b, mask, type_vector(on, ir.t_i1, false));
    ds: Value_Id = NONE;
    for data {
        a := op(i, it);
        if ds != NONE ds = irb_binop(*b, .OR, ds, msan_get_shadow(ms, a));
        else ds = msan_get_shadow(ms, a);
    }
    ds = irb_cast(*b, .SEXT, irb_icmp(*b, ICMP_NE, ds, msan_get_clean_shadow_v(ms, ds)), vtype(ds));
    wts := msan_get_shadow(ms, wt);
    msan_set_shadow(ms, i, irb_select(*b, mask, ds, wts));
    msan_set_origin_for_nary_op(ms, i);
}
// visitGenericScalarHalfwordInst
msan_visit_generic_scalar_halfword :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    a := op(i, 0); bb := op(i, 1); wt := op(i, 2); mask := op(i, 3); rm := op(i, 4);
    msan_insert_check_shadow_of(ms, mask, i);
    msan_insert_check_shadow_of(ms, rm, i);
    n := type_count(vtype(a));
    al := msan_extract_lower_shadow(ms, *b, a);
    bl := msan_extract_lower_shadow(ms, *b, bb);
    abl := irb_binop(*b, .OR, al, bl);
    wtl := msan_extract_lower_shadow(ms, *b, wt);
    mask = irb_bitcast(*b, mask, type_vector(n, ir.t_i1, false));
    ml := irb_extract_element_v(*b, mask, const_int(ir.t_i32, 0));
    ash := msan_get_shadow(ms, a);
    dl_ := irb_select(*b, ml, abl, wtl);
    msan_set_shadow(ms, i, irb_insert_element_v(*b, ash, dl_, const_int(ir.t_i32, 0), "_msprop"));
    msan_set_origin_for_nary_op(ms, i);
}
// handleAVXGF2P8Affine
msan_handle_avx_gf2p8_affine :: (ms: *Msan, i: Value_Id) {
    b: Irb; irb_set_before(*b, i);
    a := op(i, 0); x := op(i, 1); bv := op(i, 2);
    ash := msan_get_shadow(ms, a);
    xsh := msan_get_shadow(ms, x);
    bz := msan_get_clean_shadow_v(ms, bv);
    callee := call_called_function(i);
    fty := inst(i).ty2;
    axs := msan_call_like(*b, callee, fty, .[xsh, ash, bz]);
    ax := msan_call_like(*b, callee, fty, .[x, ash, bz]);
    xa := msan_call_like(*b, callee, fty, .[xsh, a, bz]);
    n := type_count(vtype(i));
    bsh := msan_get_shadow(ms, bv);
    bb := msan_get_clean_shadow_v(ms, ash);
    for k: 0..cast(s64) n - 1 bb = irb_insert_element(*b, bb, bsh, cast(u64) k);
    msan_set_shadow(ms, i, irb_binop(*b, .OR, irb_binop(*b, .OR, irb_binop(*b, .OR, axs, ax), xa), bb));
    msan_set_origin_for_nary_op(ms, i);
}
