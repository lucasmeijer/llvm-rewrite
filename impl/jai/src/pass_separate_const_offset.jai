// SeparateConstOffsetFromGEP (separate-const-offset-from-gep[<lower-gep>]): port of
// llvm/lib/Transforms/Scalar/SeparateConstOffsetFromGEP.cpp (ConstantOffsetExtractor, splitGEP, reorderGEP,
// lowerToSingleIndexGEPs, reuniteExts, swapGEPOperand). A GEP's constant index parts are pulled out into one trailing
// constant byte offset so that GEPs with the same variable part can be CSE'd.

scof_cl: struct {
    disable := false;   // -disable-separate-const-offset-from-gep
    verify_no_dead_code := false;   // -reassociate-geps-verify-no-dead-code
};

scof_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    dst: *bool;
    if name == "disable-separate-const-offset-from-gep" dst = *scof_cl.disable;
    else if name == "reassociate-geps-verify-no-dead-code" dst = *scof_cl.verify_no_dead_code;
    else return false;
    if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" dst.* = true;
    else if value == "false" || value == "0" || value == "FALSE" || value == "False" dst.* = false;
    else fatal("opt: for the --% option: '%' is invalid value for boolean argument! Try 0 or 1", name, value);
    return true;
}

scof_dl_q :: () -> Simplify_Query { q: Simplify_Query; q.have_tli = false; return q; }   // SimplifyQuery(DL)

// ---------------------------------------------------------------- ConstantOffsetExtractor

Coe :: struct {
    non_disjoint_xor_constant_bits: Value_Id = NONE;
    user_chain: [..] Value_Id;   // NONE = nulled cast
    cast_insts: [..] Value_Id;
    ip: Value_Id;                // insert before this instruction (the GEP)
}
coe_init :: (e: *Coe, ip: Value_Id) { e.ip = ip; e.user_chain.allocator = temp; e.cast_insts.allocator = temp; }

// canReorderAddSextToGEP
scof_can_reorder_add_sext_to_gep :: (gep: Value_Id, idx: Value_Id, add: Value_Id) -> bool {
    if is_known_non_negative(idx, scof_dl_q()) return true;
    if !gep_is_inbounds(gep) return false;
    ptr := op(gep, 0);
    base, offset := get_pointer_base_with_constant_offset(ptr);
    ci := op(add, 0);
    if vkind(ci) != .C_INT || is_vector_type(vtype(ci)) ci = op(add, 1);
    if vkind(ci) != .C_INT || is_vector_type(vtype(ci)) return false;
    n := type_bits(vtype(add));
    src := opr_gep_source_type(gep);
    if type_is_scalable(src) return false;
    stride := dl_type_alloc_size(src);
    cv := const_ap(ci);
    threshold: APInt;
    smin := ap_zext(ap_signed_min(n), 128);
    if !ap_is_negative(cv) threshold = ap_mul(ap_add(ap_sub(smin, ap_zext_or_trunc(cv, 128)), ap_one(128)), ap_from_u64(128, stride));
    else threshold = ap_mul(ap_add(smin, ap_sext_or_trunc(cv, 128)), ap_from_u64(128, stride));
    is_obj :: (b: Value_Id) -> bool { return b != NONE && ((is_inst(b) && inst_op(b) == .ALLOCA) || vkind(b) == .GLOBAL_VAR || vkind(b) == .FUNCTION); }   // AllocaInst / GlobalObject
    if is_obj(base) && !ap_is_negative(cv) {
        if offset == 0 return true;
        if offset < 0 return true;
        if ap_ult(ap_from_u64(128, cast(u64) offset), threshold) return true;
    } else {
        base = get_underlying_object(ptr);
        if !is_obj(base) return false;
    }
    obj_size: u64 = 0;
    if is_inst(base) && inst_op(base) == .ALLOCA {
        ok, sz := alloca_allocation_size(base);
        if ok obj_size = sz;
    } else if vkind(base) == .GLOBAL_VAR {
        vt := glob(base).value_type;
        if !type_is_scalable(vt) obj_size = dl_type_alloc_size(vt);
    }
    if obj_size > 0 && ap_ult(ap_from_u64(128, obj_size), threshold) return true;
    return false;
}

// canTraceInto
coe_can_trace_into :: (e: *Coe, sign_extended: bool, zero_extended: bool, bo: Value_Id, gep: Value_Id, idx: Value_Id) -> bool {
    o := inst_op(bo);
    if o != .ADD && o != .SUB && o != .OR return false;
    fl := inst(bo).flags;
    if o == .OR && (fl & F_EXACT) == 0 return false;   // disjoint
    if zero_extended && !sign_extended && o == .SUB return false;
    if o == .ADD && !zero_extended && gep != NONE {
        if scof_can_reorder_add_sext_to_gep(gep, idx, bo) return true;
    }
    gep_inbounds_nuw := gep != NONE && gep_is_inbounds(gep) && (opr_flags(gep) & F_GEP_NUW) != 0;
    if o == .ADD && sign_extended && !zero_extended && gep_inbounds_nuw && (fl & F_NUW) != 0 return true;
    if o == .ADD || o == .SUB {
        if sign_extended && (fl & F_NSW) == 0 return false;
        if zero_extended && (fl & F_NUW) == 0 return false;
    }
    return true;
}

// findInEitherOperand
coe_find_in_either_operand :: (e: *Coe, bo: Value_Id, sign_extended: bool, zero_extended: bool) -> APInt {
    chain_length := e.user_chain.count;
    c := coe_find(e, op(bo, 0), NONE, NONE, sign_extended, zero_extended);
    if !ap_is_zero(c) return c;
    e.user_chain.count = chain_length;
    c = coe_find(e, op(bo, 1), NONE, NONE, sign_extended, zero_extended);
    if inst_op(bo) == .SUB c = ap_neg(c);
    if ap_is_zero(c) e.user_chain.count = chain_length;
    return c;
}

// find
coe_find :: (e: *Coe, v: Value_Id, gep: Value_Id, idx: Value_Id, sign_extended: bool, zero_extended: bool) -> APInt {
    bw := type_bits(vtype(v));
    k := vkind(v);
    if k == .ARGUMENT || k == .BLOCK return ap_zero(bw);   // not a User
    c := ap_zero(bw);
    if k == .C_INT && !is_vector_type(vtype(v)) {
        c = const_ap(v);
    } else if is_inst(v) && is_binary_operator(v) {
        if coe_can_trace_into(e, sign_extended, zero_extended, v, gep, idx) c = coe_find_in_either_operand(e, v, sign_extended, zero_extended);
        else if inst_op(v) == .XOR c = coe_extract_disjoint_bits_from_xor(e, v);
    } else if is_inst(v) && inst_op(v) == .TRUNC {
        c = ap_trunc(coe_find(e, op(v, 0), gep, idx, sign_extended, zero_extended), bw);
    } else if is_inst(v) && inst_op(v) == .SEXT {
        c = ap_sext(coe_find(e, op(v, 0), gep, idx, true, zero_extended), bw);
    } else if is_inst(v) && inst_op(v) == .ZEXT {
        c = ap_zext(coe_find(e, op(v, 0), gep, idx, false, true), bw);
    }
    if !ap_is_zero(c) array_add(*e.user_chain, v);
    return c;
}

// applyCasts
coe_apply_casts :: (e: *Coe, v: Value_Id) -> Value_Id {
    current := v;
    for < ci: e.cast_insts {
        if is_constant_kind(vkind(current)) {
            folded := cfo_cast_operand(inst_op(ci), current, vtype(ci));
            if folded == NONE fatal("separate-const-offset-from-gep: a constant cast did not fold (LLVM clones the cast with a null operand)");
            current = folded;
            continue;
        }
        cl := inst_clone(ci);
        set_op(cl, 0, current);
        if inst_op(cl) == .TRUNC inst(cl).flags &= ~cast(u32) (F_NUW | F_NSW);   // dropPoisonGeneratingFlags
        insert_at_position(cl, inst_block(e.ip), e.ip, false);
        current = cl;
    }
    return current;
}

// rebuildWithoutConstOffset
coe_rebuild_without_const_offset :: (e: *Coe) -> Value_Id {
    coe_distribute_casts_and_clone_chain(e, e.user_chain.count - 1);
    n := 0;
    for e.user_chain if it != NONE { e.user_chain[n] = it; n += 1; }
    e.user_chain.count = n;
    return coe_remove_const_offset(e, e.user_chain.count - 1);
}

// distributeCastsAndCloneChain
coe_distribute_casts_and_clone_chain :: (e: *Coe, idx: s64) -> Value_Id {
    u := e.user_chain[idx];
    if idx == 0 {
        r := coe_apply_casts(e, u);
        e.user_chain[idx] = r;
        return r;
    }
    if is_inst(u) && is_cast_op(inst_op(u)) {
        array_add(*e.cast_insts, u);
        e.user_chain[idx] = NONE;
        return coe_distribute_casts_and_clone_chain(e, idx - 1);
    }
    bo := u;
    op_no: u32 = ifx op(bo, 0) == e.user_chain[idx - 1] then cast(u32) 0 else 1;
    the_other := coe_apply_casts(e, op(bo, 1 - op_no));
    next_in_chain := coe_distribute_casts_and_clone_chain(e, idx - 1);
    nb := ifx op_no == 0 then create_binop(inst_op(bo), next_in_chain, the_other) else create_binop(inst_op(bo), the_other, next_in_chain);
    insert_at_position(nb, inst_block(e.ip), e.ip, false);
    if vname(bo).count set_name(nb, vname(bo));
    e.user_chain[idx] = nb;
    return nb;
}

// removeConstOffset
coe_remove_const_offset :: (e: *Coe, idx: s64) -> Value_Id {
    if idx == 0 return const_null_value(vtype(e.user_chain[idx]));
    bo := e.user_chain[idx];
    op_no: u32 = ifx op(bo, 0) == e.user_chain[idx - 1] then cast(u32) 0 else 1;
    next_in_chain := coe_remove_const_offset(e, idx - 1);
    the_other := op(bo, 1 - op_no);
    if inst_op(bo) == .XOR next_in_chain = coe_apply_casts(e, e.non_disjoint_xor_constant_bits);
    if vkind(next_in_chain) == .C_INT && !is_vector_type(vtype(next_in_chain)) {
        if ap_is_zero(const_ap(next_in_chain)) && !(inst_op(bo) == .SUB && op_no == 0) return the_other;
    }
    new_op := inst_op(bo);
    if new_op == .OR new_op = .ADD;
    nb := ifx op_no == 0 then create_binop(new_op, next_in_chain, the_other) else create_binop(new_op, the_other, next_in_chain);
    insert_at_position(nb, inst_block(e.ip), e.ip, false);
    take_name(nb, bo);
    return nb;
}

// extractDisjointBitsFromXor
coe_extract_disjoint_bits_from_xor :: (e: *Coe, x: Value_Id) -> APInt {
    bw := type_bits(scalar_type(vtype(x)));
    base_op := op(x, 0);
    xc := op(x, 1);
    if vkind(xc) != .C_INT || is_vector_type(vtype(xc)) return ap_zero(bw);   // m_Xor(m_Value, m_ConstantInt)
    known := known_bits(base_op, scof_dl_q());
    cv := const_ap(xc);
    disjoint := ap_and(cv, known.zero);
    if ap_is_zero(disjoint) return disjoint;
    if ap_is_negative(disjoint) return ap_zero(bw);   // isSignBitSet
    non_disjoint := ap_and(cv, ap_not(disjoint));
    e.non_disjoint_xor_constant_bits = const_int_ap(type_int(non_disjoint.bits), non_disjoint);
    array_add(*e.user_chain, xc);
    return disjoint;
}

// allowsPreservingNUW
scof_allows_preserving_nuw :: (u: Value_Id) -> bool {
    if is_inst(u) && is_binary_operator(u) {
        o := inst_op(u);
        if o == .OR return true;
        return o == .ADD && (inst(u).flags & F_NUW) != 0;
    }
    if is_inst(u) && inst_op(u) == .TRUNC return (inst(u).flags & F_NUW) != 0;
    return true;
}

// ConstantOffsetExtractor::Extract: (NewIdx or NONE, UserChainTail, PreservesNUW)
coe_extract :: (idx: Value_Id, gep: Value_Id) -> (Value_Id, Value_Id, bool) {
    e: Coe; coe_init(*e, gep);
    c := coe_find(*e, idx, gep, idx, false, false);
    if ap_is_zero(c) return NONE, NONE, true;
    preserves_nuw := true;
    for e.user_chain if !scof_allows_preserving_nuw(it) { preserves_nuw = false; break; }
    r := coe_rebuild_without_const_offset(*e);
    return r, e.user_chain[e.user_chain.count - 1], preserves_nuw;
}
// ConstantOffsetExtractor::Find
coe_find_static :: (idx: Value_Id, gep: Value_Id) -> APInt {
    e: Coe; coe_init(*e, gep);
    return coe_find(*e, idx, gep, idx, false, false);
}

// ---------------------------------------------------------------- SeparateConstOffsetFromGEP

Scof :: struct {
    dt: *Dom_Tree;
    li: *Loop_Info;
    t: *Tti;
    lower_gep: bool;
    dominating_adds: Table(u64, [..] Value_Id);
    dominating_subs: Table(u64, [..] Value_Id);
}

// gep_type_iterator over the indices: (indexed type, sequential) for operand k (1-based)
Scof_Gti :: struct { cur: Type_Id; }
scof_gti_step :: (g: *Scof_Gti, gep: Value_Id, k: s64) -> (indexed: Type_Id, sequential: bool, struct_ty: Type_Id) {
    if k == 1 { g.cur = opr_gep_source_type(gep); return g.cur, true, NONE; }
    prev := g.cur;
    if type_kind(prev) == .STRUCT {
        g.cur = type_sub(prev, cast(u32) const_int_zext(op(gep, cast(u32) k)));
        return g.cur, false, prev;
    }
    g.cur = type_elem(prev);
    return g.cur, true, NONE;
}
// the type the k-th operand indexes into: GTI.getIndexedType() is the type *after* stepping (sequential: element)
// LLVM: for operand 1 the indexed type is the source element type; for later operands the element of the previous

// canonicalizeArrayIndicesToIndexSize
scof_canonicalize_array_indices :: (gep: Value_Id) -> bool {
    changed := false;
    ptr_idx_ty := dl_index_type(vtype(gep));
    g: Scof_Gti;
    for k: 1..cast(s64) nops(gep) - 1 {
        _, sequential := scof_gti_step(*g, gep, k);
        if !sequential continue;
        v := op(gep, cast(u32) k);
        if vtype(v) == ptr_idx_ty continue;
        sb := type_bits(vtype(v)); db := type_bits(ptr_idx_ty);
        opc: Opcode = ifx sb == db then Opcode.BITCAST else ifx sb > db then Opcode.TRUNC else .SEXT;
        c := new_inst(opc, ptr_idx_ty, 1);
        set_op(c, 0, v);
        insert_at_position(c, inst_block(gep), gep, false);
        set_name(c, "idxprom");
        set_op(gep, cast(u32) k, c);
        changed = true;
    }
    return changed;
}

// accumulateByteOffset: (offset, NeedsExtraction, SignedOverflow)
scof_accumulate_byte_offset :: (c: *Scof, gep: Value_Id) -> (APInt, bool, bool) {
    needs := false; signed_overflow := false;
    w := dl_index_type_size_bits(vtype(gep));
    acc := ap_zero(w);
    g: Scof_Gti;
    for k: 1..cast(s64) nops(gep) - 1 {
        indexed, sequential, st := scof_gti_step(*g, gep, k);
        if sequential {
            if type_is_scalable(indexed) continue;
            co := ap_sext_or_trunc(coe_find_static(op(gep, cast(u32) k), gep), w);
            if !ap_is_zero(co) {
                needs = true;
                bo, ov := ap_smul_ov(co, ap_from_s64(w, cast(s64) dl_type_alloc_size(indexed)));
                signed_overflow |= ov;
                acc, ov = ap_sadd_ov(acc, bo);
                signed_overflow |= ov;
            }
        } else if c.lower_gep {
            field := const_int_zext(op(gep, cast(u32) k));
            if field != 0 {
                needs = true;
                acc = ap_add(acc, ap_from_s64(w, cast(s64) dl_struct_offset(st, cast(u32) field)));
            }
        }
    }
    return acc, needs, signed_overflow;
}

// hasMoreThanOneUseInLoop
scof_has_more_than_one_use_in_loop :: (c: *Scof, v: Value_Id, l: Loop_Id) -> bool {
    if is_constant_kind(vkind(v)) return false;
    n := 0;
    for u: sx_users(v) if is_inst(u) && li_contains(c.li, l, inst_block(u)) { n += 1; if n > 1 return true; }
    return false;
}

// isLegalToSwapOperand
scof_is_legal_to_swap_operand :: (c: *Scof, first: Value_Id, second: Value_Id, l: Loop_Id) -> bool {
    if first == NONE || !has_one_use(first) return false;
    if second == NONE || inst_block(first) != inst_block(second) return false;
    if first == second return false;
    if nops(first) != nops(second) || nops(first) != 2 return false;
    first_base := op(first, 0); second_base := op(second, 0);
    first_offset := op(first, 1);
    if li_is_loop_invariant(c.li, l, first_offset) return false;
    if vtype(first_base) != vtype(second_base) return false;
    def: Value_Id = ifx is_inst(first_offset) then first_offset else NONE;
    if def != NONE && (inst_op(def) == .SHL || inst_op(def) == .LSHR || inst_op(def) == .ASHR) && vkind(op(def, 1)) == .C_INT
        def = ifx is_inst(op(def, 0)) then op(def, 0) else NONE;
    if def != NONE && is_binary_operator(def) {
        o := inst_op(def);
        if (o == .ADD || o == .SUB) && (vkind(op(def, 0)) == .C_INT || vkind(op(def, 1)) == .C_INT) return false;
    }
    return true;
}

// swapGEPOperand
scof_swap_gep_operand :: (c: *Scof, first: Value_Id, second: Value_Id) {
    o1 := op(first, 1); o2 := op(second, 1);
    set_op(first, 1, o2);
    set_op(second, 1, o1);
    bits := dl_index_size_bits(cast(u32) ir.types[scalar_type(vtype(first))].a);
    clear :: (a: Value_Id, b: Value_Id) {
        inst(a).flags &= ~cast(u32) (F_INBOUNDS | F_NUSW | F_GEP_NUW);
        inst(b).flags &= ~cast(u32) (F_INBOUNDS | F_NUSW | F_GEP_NUW);
    }
    ok, first_offset := gep_accumulate_constant_offset(first, ap_zero(bits));
    if !ok { clear(first, second); return; }
    new_base, base_offset := strip_and_accumulate_inbounds_constant_offsets(op(first, 0), ap_zero(bits));
    total, overflow := ap_uadd_ov(base_offset, first_offset);
    opts: Os_Opts;
    oks, obj_size := get_object_size(new_base, opts);
    if overflow || !oks || ap_ugt(total, ap_from_u64(total.bits, obj_size)) { clear(first, second); return; }
    inst(first).flags |= F_INBOUNDS;   // setIsInBounds(true)
}

// lowerToSingleIndexGEPs
scof_lower_to_single_index_geps :: (c: *Scof, variadic: Value_Id, acc: APInt) {
    b: Irb; irb_set_before(*b, variadic);
    ptr_index_ty := dl_index_type(vtype(variadic));
    result_ptr := op(variadic, 0);
    l := li_loop_for(c.li, inst_block(variadic));
    is_swap_candidate := l != NONE && li_is_loop_invariant(c.li, l, result_ptr) && !scof_has_more_than_one_use_in_loop(c, result_ptr, l);
    first_result: Value_Id = NONE;
    g: Scof_Gti;
    for k: 1..cast(s64) nops(variadic) - 1 {
        indexed, sequential := scof_gti_step(*g, variadic, k);
        if !sequential continue;
        idx := op(variadic, cast(u32) k);
        if vkind(idx) == .C_INT && ap_is_zero(const_ap(idx)) continue;
        es := ap_from_u64(type_bits(ptr_index_ty), dl_type_alloc_size(indexed));
        if !ap_is_one(es) {
            if ap_is_power_of_2(es) idx = irb_binop(*b, .SHL, idx, const_int(ptr_index_ty, ap_log2(es)));
            else idx = irb_binop(*b, .MUL, idx, const_int_ap(ptr_index_ty, es));
        }
        result_ptr = irb_gep(*b, ir.t_i8, result_ptr, .[idx], "uglygep");
        if first_result == NONE first_result = result_ptr;
    }
    if !ap_is_zero(acc) {
        result_ptr = irb_gep(*b, ir.t_i8, result_ptr, .[const_int_ap(ptr_index_ty, acc)], "uglygep");
    } else is_swap_candidate = false;
    first_gep: Value_Id = ifx first_result != NONE && is_inst(first_result) && inst_op(first_result) == .GEP then first_result else NONE;
    second_gep: Value_Id = ifx is_inst(result_ptr) && inst_op(result_ptr) == .GEP then result_ptr else NONE;
    if is_swap_candidate && scof_is_legal_to_swap_operand(c, first_gep, second_gep, l) scof_swap_gep_operand(c, first_gep, second_gep);
    replace_all_uses_with(variadic, result_ptr);
    erase_inst_with_metadata(variadic);
}

// reorderGEP
scof_reorder_gep :: (c: *Scof, gep: Value_Id) -> bool {
    ptr_gep := op(gep, 0);
    if !is_inst(ptr_gep) || inst_op(ptr_gep) != .GEP return false;
    nested, needs, _ := scof_accumulate_byte_offset(c, ptr_gep);
    if !needs return false;
    as := cast(u32) ir.types[scalar_type(vtype(ptr_gep))].a;
    if !tti_is_legal_addressing_mode(c.t, gep_result_element_type(gep), NONE, ap_sext_value(nested), true, 0, as) return false;
    chain_inbounds := gep_is_inbounds(gep) && gep_is_inbounds(ptr_gep);
    if chain_inbounds {
        for k: 1..cast(s64) nops(gep) - 1 if !is_known_non_negative(op(gep, cast(u32) k), scof_dl_q()) { chain_inbounds = false; break; }
        if chain_inbounds
            for k: 1..cast(s64) nops(ptr_gep) - 1 if !is_known_non_negative(op(ptr_gep, cast(u32) k), scof_dl_q()) { chain_inbounds = false; break; }
    }
    b: Irb; irb_set_before(*b, gep);
    idx1: [..] Value_Id; idx1.allocator = temp;
    for k: 1..cast(s64) nops(gep) - 1 array_add(*idx1, op(gep, cast(u32) k));
    idx2: [..] Value_Id; idx2.allocator = temp;
    for k: 1..cast(s64) nops(ptr_gep) - 1 array_add(*idx2, op(ptr_gep, cast(u32) k));
    fl: u32 = ifx chain_inbounds then cast(u32) F_INBOUNDS else 0;
    new_src := irb_gep(*b, opr_gep_source_type(gep), op(ptr_gep, 0), idx1, "", fl);
    new_gep := irb_gep(*b, opr_gep_source_type(ptr_gep), new_src, idx2, "", fl);
    replace_all_uses_with(gep, new_gep);
    recursively_delete_trivially_dead_no_tli(gep);
    return true;
}

// splitGEP
scof_split_gep :: (c: *Scof, gep: Value_Id) -> bool {
    if is_vector_type(vtype(gep)) return false;
    // m_PtrAdd(m_Value(NewBase), m_APInt(BaseOffset)): a GEPOperator with an i8 source type and one index
    p := op(gep, 0);
    extract_base := false;
    new_base: Value_Id = NONE;
    base_offset_ap: APInt;
    if opr_code(p) == .GEP && nops(p) == 2 && opr_gep_source_type(p) == ir.t_i8 {
        ok, ap := pm_apint(op(p, 1));
        if ok { extract_base = true; new_base = op(p, 0); base_offset_ap = ap; }
    }
    w := dl_index_type_size_bits(vtype(gep));
    base_byte_offset := ifx extract_base then ap_sext_or_trunc(base_offset_ap, w) else ap_zero(w);
    if gep_has_all_constant_indices(gep) && !extract_base return false;
    changed := scof_canonicalize_array_indices(gep);
    non_base, needs, offset_overflow := scof_accumulate_byte_offset(c, gep);
    acc, add_overflow := ap_sadd_ov(base_byte_offset, non_base);
    offset_overflow |= add_overflow;
    if !needs && !extract_base {
        changed |= scof_reorder_gep(c, gep);
        return changed;
    }
    if !c.lower_gep {
        as := cast(u32) ir.types[scalar_type(vtype(gep))].a;
        if !tti_is_legal_addressing_mode(c.t, gep_result_element_type(gep), NONE, ap_sext_value(acc), true, 0, as) {
            if !extract_base return changed;
            extract_base = false;
            base_byte_offset = ap_zero(w);
            acc = non_base;
            if !tti_is_legal_addressing_mode(c.t, gep_result_element_type(gep), NONE, ap_sext_value(acc), true, 0, as) return changed;
            needs = true;
        }
    }
    all_offsets_non_negative := !ap_is_negative(acc) && !offset_overflow;
    gf := inst(gep).flags;
    all_nuw_preserved := (gf & F_GEP_NUW) != 0;
    new_gep_inbounds := (gf & F_INBOUNDS) != 0;
    new_gep_nusw := (gf & (F_INBOUNDS | F_NUSW)) != 0;
    g: Scof_Gti;
    for k: 1..cast(s64) nops(gep) - 1 {
        indexed, sequential := scof_gti_step(*g, gep, k);
        if !sequential continue;
        if type_is_scalable(indexed) continue;
        idx := op(gep, cast(u32) k);
        new_idx, tail, preserves_nuw := coe_extract(idx, gep);
        if new_idx != NONE {
            set_op(gep, cast(u32) k, new_idx);
            recursively_delete_trivially_dead_no_tli(tail);
            recursively_delete_trivially_dead_no_tli(idx);
            idx = new_idx;
            all_nuw_preserved &= preserves_nuw;
        }
        all_offsets_non_negative = all_offsets_non_negative && is_known_non_negative(idx, scof_dl_q());
    }
    if extract_base {
        base := op(gep, 0);
        bf := opr_flags(base);
        all_nuw_preserved &= (bf & F_GEP_NUW) != 0;
        new_gep_inbounds &= (bf & F_INBOUNDS) != 0;
        new_gep_nusw &= (bf & (F_INBOUNDS | F_NUSW)) != 0;
        all_offsets_non_negative &= !ap_is_negative(base_byte_offset);
        set_op(gep, 0, new_base);
        recursively_delete_trivially_dead_no_tli(base);
    }
    new_flags: u32 = 0;
    can_preserve := all_offsets_non_negative;
    if all_nuw_preserved {
        new_flags |= F_GEP_NUW;
        can_preserve |= new_gep_nusw;
    }
    if can_preserve {
        if new_gep_inbounds new_flags |= F_INBOUNDS;
        else if new_gep_nusw new_flags |= F_NUSW;
    }
    inst(gep).flags = (inst(gep).flags & ~cast(u32) (F_INBOUNDS | F_NUSW | F_GEP_NUW)) | new_flags;
    if c.lower_gep {
        scof_lower_to_single_index_geps(c, gep, acc);
        return true;
    }
    if ap_is_zero(acc) return true;
    ng := inst_clone(gep);
    insert_at_position(ng, inst_block(gep), gep, false);
    ptr_idx_ty := dl_index_type(vtype(gep));
    b: Irb; irb_set_before(*b, gep);
    r := irb_gep(*b, ir.t_i8, ng, .[const_int_ap(ptr_idx_ty, acc)], vname(gep), new_flags);
    copy_metadata(r, gep);   // Instruction::copyMetadata(*GEP): all attachments incl. !dbg
    replace_all_uses_with(gep, r);
    erase_inst_with_metadata(gep);
    return true;
}

scof_key :: (a: Value_Id, b: Value_Id) -> u64 { hi: u64 = a; return (hi << 32) | cast(u64) b; }
// createNormalizedCommutablePair (by pointer in LLVM: only a canonical map key, so any total order works)
scof_key_commutable :: (a: Value_Id, b: Value_Id) -> u64 { if a < b return scof_key(a, b); return scof_key(b, a); }

// findClosestMatchingDominator
scof_find_closest_matching_dominator :: (c: *Scof, key: u64, dominatee: Value_Id, m: *Table(u64, [..] Value_Id)) -> Value_Id {
    p := table_find_pointer(m, key);
    if !p return NONE;
    while p.count {
        cand := p.*[p.count - 1];
        if vkind(cand) == .DEAD fatal("separate-const-offset-from-gep: a dominating add/sub was deleted (LLVM reads freed memory here)");
        if dt_dominates_inst(c.dt, cand, dominatee) return cand;
        p.count -= 1;
    }
    return NONE;
}
scof_push :: (m: *Table(u64, [..] Value_Id), key: u64, v: Value_Id) {
    p := table_find_pointer(m, key);
    if !p { e: [..] Value_Id; e.allocator = temp; table_set(m, key, e); p = table_find_pointer(m, key); }
    array_add(p, v);
}

// reuniteExts(Instruction *)
scof_reunite_exts_inst :: (c: *Scof, i: Value_Id) -> bool {
    if type_kind(scalar_type(vtype(i))) != .INT return false;
    is_sext :: (v: Value_Id) -> bool { return is_inst(v) && inst_op(v) == .SEXT; }
    o := inst_op(i);
    if (o == .ADD || o == .SUB) && is_sext(op(i, 0)) && is_sext(op(i, 1)) {
        lhs := op(op(i, 0), 0); rhs := op(op(i, 1), 0);
        if vtype(lhs) == vtype(rhs) {
            key := ifx o == .ADD then scof_key_commutable(lhs, rhs) else scof_key(lhs, rhs);
            dom := scof_find_closest_matching_dominator(c, key, i, ifx o == .ADD then *c.dominating_adds else *c.dominating_subs);
            if dom != NONE {
                ns := new_inst(.SEXT, vtype(i), 1);
                set_op(ns, 0, dom);
                insert_at_position(ns, inst_block(i), i, false);
                take_name(ns, i);
                replace_all_uses_with(i, ns);
                set_metadata(ns, 0, get_metadata(i, 0));
                recursively_delete_trivially_dead_no_tli(i);
                return true;
            }
        }
    }
    if o == .ADD && (inst(i).flags & F_NSW) != 0 {
        if program_undefined_if_poison(i) scof_push(*c.dominating_adds, scof_key_commutable(op(i, 0), op(i, 1)), i);
    } else if o == .SUB && (inst(i).flags & F_NSW) != 0 {
        if program_undefined_if_poison(i) scof_push(*c.dominating_subs, scof_key(op(i, 0), op(i, 1)), i);
    }
    return false;
}

// reuniteExts(Function &)
scof_reunite_exts :: (c: *Scof) -> bool {
    changed := false;
    table_reset(*c.dominating_adds);
    table_reset(*c.dominating_subs);
    blocks: [..] Value_Id; blocks.allocator = temp;
    dt_blocks_preorder(c.dt, *blocks);
    for bb: blocks {
        i := block_first(bb);
        while i != NONE {
            nx := inst_next(i);   // make_early_inc_range
            changed |= scof_reunite_exts_inst(c, i);
            i = nx;
        }
    }
    return changed;
}

// SeparateConstOffsetFromGEPPass::run
separate_const_offset_run :: (node: *Pass_Node, f: Value_Id) -> Preserved {
    c: Scof;
    if node.name == "separate-const-offset-from-gep" || node.name == "separate-const-offset-from-gep<>" c.lower_gep = false;
    else if node.name == "separate-const-offset-from-gep<lower-gep>" c.lower_gep = true;
    else fatal("invalid pass pipeline: invalid SeparateConstOffsetFromGEP pass parameter '%'", slice(node.name, 31, node.name.count - 32));
    if scof_cl.disable return PRESERVE_ALL;
    c.dt = get_domtree(f);
    c.li = get_loop_info(f);
    c.t = tti_get(f);
    c.dominating_adds.allocator = temp; c.dominating_subs.allocator = temp;
    changed := false;
    po: [..] Value_Id; po.allocator = temp;
    cfg_post_order(fn_entry(f), *po);
    for < bb: po {
        if !dt_is_reachable_from_entry(c.dt, bb) continue;
        i := block_first(bb);
        while i != NONE {
            nx := inst_next(i);
            if inst_op(i) == .GEP changed |= scof_split_gep(*c, i);
            i = nx;
        }
    }
    changed |= scof_reunite_exts(*c);
    if scof_cl.verify_no_dead_code {
        for bb: fn_blocks(f) for i: block_insts(bb) if is_instruction_trivially_dead(i) fatal("Dead instruction detected!");
    }
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    pa.cfg = true;
    return pa;
}
