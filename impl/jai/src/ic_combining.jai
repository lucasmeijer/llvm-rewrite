// InstCombine: the visitors of llvm/lib/Transforms/InstCombine/InstructionCombining.cpp that are not part of the
// driver (ic_core.jai), the binop helpers (ic_binop.jai) or the terminators (ic_misc.jai). Ported completely, in
// LLVM's order: shouldMergeGEPs, getMergedGEPNoWrapFlags, foldSelectGEP, canonicalizeGEPOfConstGEPI8,
// combineConstantOffsets, visitGEPOfGEP, shouldCanonicalizeGEPToPtrAdd, foldGEPOfPhi, visitGetElementPtrInst,
// isNeverEqualToUnescapedAlloc, isRemovableWrite, isAllocSiteRemovable, visitAllocSite, tryToMoveFreeBeforeNullTest,
// visitFree, simplifySwitchOnSelectUsingRanges, visitSwitchInst, foldExtractOfOverflowIntrinsic, foldFrexpOfSelect,
// visitExtractValueInst, isCatchAll, visitLandingPadInst, pushFreezeToPreventPoisonFromPropagating,
// foldFreezeIntoRecurrence, freezeOtherUses, isUsedWithinShuffleVector, visitFreeze.
// Also Instruction::getInsertionPointAfterDef and BasicBlock::getFirstNonPHIOrDbgOrAlloca.


ic_cl: struct { max_alloc_site_removable_users: s64 = 2048; };   // -instcombine-max-allocsite-removable-users (registered in pass_debugify.jai)

// ---------------------------------------------------------------- GEP helpers

gep_nw_intersect_for_reassociate :: (a: u32, b: u32) -> u32 {
    r := a & b & cast(u32)(F_INBOUNDS | F_NUSW | F_GEP_NUW);
    if (r & F_GEP_NUW) == 0 return 0;
    return r;
}
GEP_NW_ALL :: cast(u32)(F_INBOUNDS | F_NUSW | F_GEP_NUW);
gep_has_nuw :: (g: Value_Id) -> bool { return (opr_flags(g) & F_GEP_NUW) != 0; }
gep_has_nusw :: (g: Value_Id) -> bool { return (opr_flags(g) & (F_NUSW | F_INBOUNDS)) != 0; }
gep_is_inbounds :: (g: Value_Id) -> bool { return (opr_flags(g) & F_INBOUNDS) != 0; }
gep_num_indices :: (g: Value_Id) -> u32 { return nops(g) - 1; }
// setNoWrapFlags (stored form: inbounds without the implied nusw bit)
gep_set_nw :: (g: Value_Id, nw: u32) {
    f := nw & GEP_NW_ALL;
    if (f & F_INBOUNDS) != 0 f &= ~cast(u32) F_NUSW;
    inst(g).flags = (inst(g).flags & ~GEP_NW_ALL) | f;
}
// GEPOperator::getResultElementType
gep_result_element_type :: (g: Value_Id) -> Type_Id {
    cur := opr_gep_source_type(g);
    for k: 1..cast(s64) nops(g) - 1 cur = ifx k == 1 then cur else gep_indexed_type(cur, k, op(g, cast(u32) k));
    return cur;
}
// GEPOperator::hasAllZeroIndices (ConstantInt zeros only)
gep_all_zero_indices_op :: (g: Value_Id) -> bool {
    for k: 1..cast(s64) nops(g) - 1 { x := op(g, cast(u32) k); if !(vkind(x) == .C_INT && is_null_value(x)) return false; }
    return true;
}
// m_PtrAdd(m_Value(Base), m_APInt(C)): a GEPOperator with source type i8 and one index
pm_ptr_add_apint :: (v: Value_Id) -> (bool, Value_Id, APInt) {
    if opr_code(v) != .GEP return false, NONE, .{};
    st := opr_gep_source_type(v);
    if !is_int_type(st) || type_int_width(st) != 8 || nops(v) != 2 return false, NONE, .{};
    ok, c := pm_apint(op(v, 1));
    if !ok return false, NONE, .{};
    return true, op(v, 0), c;
}

// shouldMergeGEPs
should_merge_geps :: (g: Value_Id, src: Value_Id) -> bool {
    if gep_all_zero_indices_op(g) && !gep_all_zero_indices_op(src) && !has_one_use(src) return false;
    return true;
}

// foldSelectGEP
ic_fold_select_gep :: (g: Value_Id) -> Value_Id {
    if !gep_has_all_constant_indices(g) return NONE;
    sel := op(g, 0);
    if !is_inst(sel) || inst_op(sel) != .SELECT return NONE;
    cond := op(sel, 0); tc := op(sel, 1); fc := op(sel, 2);
    if !is_const(tc) || !is_const(fc) return NONE;
    idx: [..] Value_Id; idx.allocator = temp;
    for k: 1..cast(s64) nops(g) - 1 array_add(*idx, op(g, cast(u32) k));
    nw := gep_nw_bits(g);
    ty := inst(g).ty2;
    nt := icb_gep(ty, tc, idx, "", nw);
    nf := icb_gep(ty, fc, idx, "", nw);
    return create_select_md_from(cond, nt, nf, sel);
}

// canonicalizeGEPOfConstGEPI8
ic_canonicalize_gep_of_const_gep_i8 :: (g: Value_Id, src: Value_Id) -> Value_Id {
    if gep_num_indices(g) != 1 return NONE;
    ok, base, c1 := pm_ptr_add_apint(src);
    if !ok return NONE;
    idx_bits := dl_index_type_size_bits(scalar_type(vtype(src)));
    okv, var_index, c2 := ic_pm_add_like_apint(op(g, 1));
    if !okv return NONE;
    if c1.bits != idx_bits || c2.bits != idx_bits return NONE;
    base_ty := inst(g).ty2;
    if type_kind(base_ty) == .SVECTOR return NONE;
    ts := ap_from_u64(idx_bits, dl_type_alloc_size(base_ty));
    new_off := ap_add(ap_mul(ts, c2), c1);
    if ap_is_zero(new_off) || (has_one_use(src) && has_one_use(op(g, 1))) {
        flags: u32 = 0;
        oknuw := pm_nuw_add_like_i(op(g, 1));
        if gep_has_nuw(g) && gep_has_nuw(src) && oknuw {
            flags |= F_GEP_NUW;
            if gep_is_inbounds(g) && gep_is_inbounds(src) flags |= F_INBOUNDS | F_NUSW;
        }
        gc := icb_ptr_add(base, const_int_ap(type_int(idx_bits), new_off), "", flags);
        return create_gep(base_ty, gc, .[var_index], flags);
    }
    return NONE;
}
// m_AddLike(m_Value(X), m_APInt(C)) (instructions)
ic_pm_add_like_apint :: (v: Value_Id) -> (bool, Value_Id, APInt) {
    ok, a, b := pm_add_like(v);
    if !ok return false, NONE, .{};
    okc, c := pm_apint(b);
    if !okc return false, NONE, .{};
    return true, a, c;
}

// combineConstantOffsets
ic_combine_constant_offsets :: (g: Value_Id) -> Value_Id {
    if !gep_has_all_constant_indices(g) return NONE;
    nw := GEP_NW_ALL;
    skipped: [..] Value_Id; skipped.allocator = temp;
    inner := op(g, 0);
    if !is_inst(inner) || inst_op(inner) != .GEP inner = NONE;
    while true {
        if inner == NONE return NONE;
        nw = gep_nw_intersect_for_reassociate(nw, gep_nw_bits(inner));
        if gep_has_all_constant_indices(inner) break;
        if !has_one_use(inner) return NONE;
        array_add(*skipped, inner);
        inner = op(inner, 0);
        if !is_inst(inner) || inst_op(inner) != .GEP inner = NONE;
    }
    if skipped.count == 0 return NONE;
    if !has_one_use(inner) return NONE;
    ty := vtype(g);
    if vtype(inner) != ty return NONE;
    offset := ap_zero(dl_index_type_size_bits(ty));
    ok: bool;
    ok, offset = gep_accumulate_constant_offset(g, offset);
    if !ok return NONE;
    ok, offset = gep_accumulate_constant_offset(inner, offset);
    if !ok return NONE;
    ic_replace_operand(skipped[skipped.count - 1], 0, op(inner, 0));
    for skipped gep_set_nw(it, nw);
    return ic_replace_inst_uses_with(g, icb_ptr_add(skipped[0], const_int_ap(type_int(offset.bits), offset), "",
                                                    gep_nw_intersect_for_offset_add(nw, gep_nw_bits(g))));
}

// visitGEPOfGEP
ic_visit_gep_of_gep :: (g: Value_Id, src: Value_Id) -> Value_Id {
    if !should_merge_geps(g, src) return NONE;
    r := ic_canonicalize_gep_of_const_gep_i8(g, src); if r != NONE return r;
    r = ic_combine_constant_offsets(g); if r != NONE return r;
    if gep_result_element_type(src) != inst(g).ty2 return NONE;
    if has_one_use(src) && gep_num_indices(g) == 1 && gep_num_indices(src) == 1 {
        src_idx := op(src, 1); gep_idx := op(g, 1);
        cond: Value_Id = NONE; c_off, tv, fv: APInt;
        found := false;
        ok1, co := pm_apint(src_idx);
        oks, sc, st, sf := pm_select(gep_idx);
        if ok1 && oks {
            okt, a := pm_apint(st); okf, b := pm_apint(sf);
            if okt && okf { found = true; cond = sc; c_off = co; tv = a; fv = b; }
        }
        if !found {
            ok2, co2 := pm_apint(gep_idx);
            oks2, sc2, st2, sf2 := pm_select(src_idx);
            if ok2 && oks2 {
                okt, a := pm_apint(st2); okf, b := pm_apint(sf2);
                if okt && okf { found = true; cond = sc2; c_off = co2; tv = a; fv = b; }
            }
        }
        if found {
            sel := ifx is_inst(gep_idx) && inst_op(gep_idx) == .SELECT then gep_idx else src_idx;
            if !has_one_use(sel) return NONE;
            if tv.bits != c_off.bits || fv.bits != c_off.bits return NONE;
            nt := const_int_ap(vtype(sel), ap_add(c_off, tv));
            nf := const_int_ap(vtype(sel), ap_add(c_off, fv));
            ns := icb_select(cond, nt, nf, "", sel);
            flags := gep_nw_intersect_for_offset_add(gep_nw_bits(src), gep_nw_bits(g));
            return ic_replace_inst_uses_with(g, icb_gep(gep_result_element_type(g), op(src, 0), .[ns], "", flags));
        }
    }
    // EndsWithSequential: the last index of Src is not a struct index
    ends_with_sequential := false;
    {
        cur := opr_gep_source_type(src);
        for k: 1..cast(s64) nops(src) - 1 {
            ends_with_sequential = !(k > 1 && type_kind(cur) == .STRUCT);
            cur = gep_indexed_type(cur, k, op(src, cast(u32) k));
        }
    }
    if !ends_with_sequential return NONE;
    so1 := op(src, nops(src) - 1);
    go1 := op(g, 1);
    if vtype(so1) != vtype(go1) return NONE;
    sum := simplify_add_inst(go1, so1, false, false, ic_q(g));
    if sum == NONE return NONE;
    idxs: [..] Value_Id; idxs.allocator = temp;
    for k: 1..cast(s64) nops(src) - 2 array_add(*idxs, op(src, cast(u32) k));
    array_add(*idxs, sum);
    for k: 2..cast(s64) nops(g) - 1 array_add(*idxs, op(g, cast(u32) k));
    nnz := 0;
    for idxs if !(is_const(it) && is_null_value(it)) nnz += 1;
    if nnz > 1 return NONE;
    return ic_replace_inst_uses_with(g, icb_gep(opr_gep_source_type(src), op(src, 0), idxs, "",
                                                gep_nw_intersect_for_offset_add(gep_nw_bits(src), gep_nw_bits(g))));
}

// shouldCanonicalizeGEPToPtrAdd
should_canonicalize_gep_to_ptr_add :: (g: Value_Id) -> bool {
    ptr := op(g, 0);
    et := inst(g).ty2;
    if is_int_type(et) && type_int_width(et) == 8 return false;
    if type_is_scalable(et) return true;
    if gep_num_indices(g) == 1 {
        i1 := op(g, 1);
        if has_one_use(i1) && is_inst(i1) && (inst_op(i1) == .MUL || inst_op(i1) == .SHL) && pm_constant_int(op(i1, 1)) return true;
    }
    if opr_code(ptr) == .GEP && gep_has_all_constant_indices(ptr) {
        for k: 1..cast(s64) nops(g) - 1 {
            ok, c := pm_apint(op(g, cast(u32) k));
            if ok && !ap_is_zero(c) return true;
        }
    }
    return false;
}

// foldGEPOfPhi
ic_fold_gep_of_phi :: (g: Value_Id, pn: Value_Id) -> Value_Id {
    op1 := op(pn, 0);
    if !is_inst(op1) || inst_op(op1) != .GEP return NONE;
    if op1 == g return NONE;
    nw := gep_nw_bits(op1);
    di: s64 = -1;
    for pk: 1..cast(s64) nops(pn) - 1 {
        op2 := op(pn, cast(u32) pk);
        if !is_inst(op2) || inst_op(op2) != .GEP || nops(op1) != nops(op2) || inst(op1).ty2 != inst(op2).ty2 return NONE;
        if op2 == g return NONE;
        cur: Type_Id = NONE;
        for j: 0..cast(s64) nops(op1) - 1 {
            a := op(op1, cast(u32) j); b := op(op2, cast(u32) j);
            if vtype(a) != vtype(b) return NONE;
            if a != b {
                if di == -1 {
                    if j > 1 && type_kind(cur) == .STRUCT return NONE;
                    di = j;
                } else return NONE;
            }
            if j > 0 {
                if j == 1 cur = inst(op1).ty2;
                else cur = gep_indexed_type(cur, j, a);
            }
        }
        nw &= gep_nw_bits(op2);
    }
    if di != -1 && !has_one_use(pn) return NONE;
    ng := ic_clone_inst(op1);
    gep_set_nw(ng, nw);
    if di != -1 {
        new_pn: Value_Id;
        {
            saved := ic.b;
            defer ic.b = saved;
            icb_set_insert_point(pn);
            new_pn = icb_phi(vtype(op(op1, cast(u32) di)), nops(pn));
        }
        for k: 0..cast(s64) nops(pn) - 1 phi_add_incoming(new_pn, op(op(pn, cast(u32) k), cast(u32) di), phi_block(pn, cast(u32) k));
        set_op(ng, cast(u32) di, new_pn);
    }
    bb := inst_block(g);
    pos := block_first_insertion_pt(bb);
    if pos == NONE ic_link_at_end(ng, bb); else ic_link_before(ng, pos, true);
    return ng;
}

// visitGetElementPtrInst
ic_visit_gep :: (g: Value_Id) -> Value_Id {
    ptr := op(g, 0);
    indices: [..] Value_Id; indices.allocator = temp;
    for k: 1..cast(s64) nops(g) - 1 array_add(*indices, op(g, cast(u32) k));
    gep_ty := vtype(g);
    et := inst(g).ty2;
    v := simplify_gep_inst(et, ptr, indices, gep_nw_bits(g), ic_q(g));
    if v != NONE return ic_replace_inst_uses_with(g, v);
    if type_kind(gep_ty) == .VECTOR {
        vw := cast(u32) type_count(gep_ty);
        poison := ap_zero(vw);
        all := ap_all_ones(vw);
        r := ic_simplify_demanded_vector_elts(g, all, *poison);
        if r != NONE {
            if r != g return ic_replace_inst_uses_with(g, r);
            return g;
        }
    }
    made_change := false;
    new_scalar_idx_ty := dl_index_type(scalar_type(vtype(ptr)));
    {
        cur := et;
        for k: 1..cast(s64) nops(g) - 1 {
            x := op(g, cast(u32) k);
            is_struct := k > 1 && type_kind(cur) == .STRUCT;
            indexed := gep_indexed_type(cur, k, x);
            defer cur = indexed;
            if is_struct continue;
            idx_ty := vtype(x);
            new_idx_ty := ifx is_vector_type(idx_ty) then type_vector(type_count(idx_ty), new_scalar_idx_ty, type_kind(idx_ty) == .SVECTOR) else new_scalar_idx_ty;
            if type_is_sized(indexed) && dl_type_alloc_size(indexed) == 0 {
                if !is_const(x) || !pm_zero(x) {
                    set_op(g, cast(u32) k, const_null_value(new_idx_ty));
                    made_change = true;
                }
            }
            if idx_ty != new_idx_ty {
                cv := op(g, cast(u32) k);
                if scalar_bits(x) < type_bits(scalar_type(new_idx_ty)) {
                    if gep_has_nuw(g) && gep_has_nusw(g) set_op(g, cast(u32) k, icb_zext(cv, new_idx_ty, "", nneg = true));
                    else set_op(g, cast(u32) k, icb_sext(cv, new_idx_ty));
                } else set_op(g, cast(u32) k, icb_trunc(cv, new_idx_ty, "", gep_has_nuw(g), gep_has_nusw(g)));
                made_change = true;
            }
        }
    }
    if made_change return g;
    if !(is_int_type(et) && type_int_width(et) == 8) && gep_has_all_constant_indices(g) {
        ok, off := gep_accumulate_constant_offset(g, ap_zero(dl_index_type_size_bits(gep_ty)));
        if ok return ic_replace_inst_uses_with(g, icb_ptr_add(ptr, const_int_ap(type_int(off.bits), off), "", gep_nw_bits(g)));
    }
    if should_canonicalize_gep_to_ptr_add(g) {
        off := ic_emit_gep_offset(g);
        return ic_replace_inst_uses_with(g, icb_ptr_add(ptr, off, "", gep_nw_bits(g)));
    }
    last := indices[indices.count - 1];
    if is_const(last) && is_null_value(last) && !is_vector_type(vtype(last)) {
        front := aview(indices, 0, indices.count - 1);
        return ic_replace_inst_uses_with(g, icb_gep(et, ptr, front, "", gep_nw_bits(g)));
    }
    first := indices[0];
    if is_const(first) && is_null_value(first) && !is_vector_type(vtype(first)) && indices.count > 1 {
        // ++GTI: operand 2 indexes the source element type
        x2 := indices[1];
        if type_kind(et) != .STRUCT {
            indexed := gep_indexed_type(et, 2, x2);
            if gep_seq_stride(et, 2, indexed) == dl_type_alloc_size(indexed)
                return ic_replace_inst_uses_with(g, icb_gep(indexed, ptr, aview(indices, 1, indices.count - 1), "", gep_nw_bits(g)));
        }
    }
    if is_vector_type(gep_ty) {
        any := false;
        for k: 0..cast(s64) nops(g) - 1 { o := op(g, cast(u32) k); if is_vector_type(vtype(o)) && vu_get_splat_value(o) != NONE { any = true; break; } }
        if any {
            new_ops: [..] Value_Id; new_ops.allocator = temp;
            for k: 0..cast(s64) nops(g) - 1 {
                o := op(g, cast(u32) k);
                if is_vector_type(vtype(o)) {
                    s := vu_get_splat_value(o);
                    if s != NONE { array_add(*new_ops, s); continue; }
                }
                array_add(*new_ops, o);
            }
            res := icb_gep(et, new_ops[0], aview(new_ops, 1, new_ops.count - 1), name_ref(vname(g)), gep_nw_bits(g));
            if !is_vector_type(vtype(res)) res = icb_vector_splat(type_count(gep_ty), type_kind(gep_ty) == .SVECTOR, res);
            return ic_replace_inst_uses_with(g, res);
        }
    }
    seen_non_zero := false;
    for idx, num: indices {
        if is_const(idx) && is_null_value(idx) && num == 0 continue;
        if !seen_non_zero { seen_non_zero = true; continue; }
        front := aview(indices, 0, num);
        front_gep := icb_gep(et, ptr, front, tprint("%.split", vname(g)), gep_nw_bits(g));
        back: [..] Value_Id; back.allocator = temp;
        array_add(*back, const_null_value(new_scalar_idx_ty));
        for k: num..indices.count-1 array_add(*back, indices[k]);
        return create_gep(gep_indexed_type_n(et, front), front_gep, back, gep_nw_bits(g));
    }
    is_canonical_type :: (t: Type_Id) -> bool {
        x := t;
        if type_kind(x) == .ARRAY x = type_elem(x);
        return is_int_type(x) && type_int_width(x) == 8;
    }
    if indices.count == 1 && !is_canonical_type(et) {
        scale := dl_type_alloc_size(et);
        nt := ir.t_i8;
        if scale != 1 nt = type_array(scale, ir.t_i8);
        inst(g).ty2 = nt;
        ic.made_ir_change = true;
        et = nt;
    }
    if is_phi(ptr) {
        np := ic_fold_gep_of_phi(g, ptr);
        if np != NONE return ic_replace_operand(g, 0, np);
    }
    if opr_code(ptr) == .GEP {
        r := ic_visit_gep_of_gep(g, ptr); if r != NONE return r;
    }
    if gep_num_indices(g) == 1 {
        as := type_addrspace(vtype(g));
        if scalar_bits(op(g, 1)) == dl_index_size_bits(as) {
            ty_alloc_size := dl_type_alloc_size(et);
            if ty_alloc_size == 1 {
                x := op(g, 0);
                oks, a, b := pm_binop(op(g, 1), .SUB);
                y: Value_Id = NONE;
                if oks {
                    oka, ya := pm_ptr_to_int_or_addr(a);
                    okb, xb := pm_ptr_to_int_or_addr(b);
                    if oka && okb && xb == x y = ya;
                }
                if y != NONE && gep_ty == vtype(y) {
                    has_non_address_bits := dl_address_size_bits(as) != dl_ptr_spec(as).bits;
                    changed := false;
                    u := ir.v_first_use[g];
                    while u != NONE {
                        nu := ir.u_next[u];
                        us := ir.u_user[u];
                        if is_inst(us) && (inst_op(us) == .PTRTOADDR || inst_op(us) == .ICMP || (!has_non_address_bits && inst_op(us) == .PTRTOINT)) {
                            use_set(u, y);
                            changed = true;
                        }
                        u = nu;
                    }
                    return ifx changed then g else NONE;
                }
            } else {
                ex := op(g, 1);
                eo := opr_code(ex);
                if eo == .UDIV || eo == .SDIV || eo == .LSHR || eo == .ASHR {
                    exact := (opr_flags(ex) & F_EXACT) != 0;
                    if exact {
                        is_pow2 := ty_alloc_size != 0 && (ty_alloc_size & (ty_alloc_size - 1)) == 0;
                        tz := ifx ty_alloc_size == 0 then cast(u64) 64 else cast(u64) ctz64(ty_alloc_size);
                        vv := op(ex, 0);
                        if (is_pow2 && (eo == .LSHR || eo == .ASHR) && pm_specific_int(op(ex, 1), tz)) ||
                           ((eo == .UDIV || eo == .SDIV) && pm_specific_int(op(ex, 1), ty_alloc_size))
                            return create_gep(ir.t_i8, op(g, 0), .[vv], gep_nw_bits(g));
                    }
                    if exact && has_one_use(ex) {
                        okc, c := pm_apint(op(ex, 1));
                        vv := op(ex, 0);
                        have := false; new_c: APInt;
                        if okc {
                            is_pow2 := ty_alloc_size != 0 && (ty_alloc_size & (ty_alloc_size - 1)) == 0;
                            tz := ifx ty_alloc_size == 0 then cast(u64) 64 else cast(u64) ctz64(ty_alloc_size);
                            if is_pow2 && (eo == .LSHR || eo == .ASHR) {
                                if ap_uge_u64(c, tz) { have = true; new_c = ap_sub(c, ap_from_u64(c.bits, tz)); }
                            } else if eo == .UDIV {
                                q, rem := ap_udivrem(c, ap_from_u64(c.bits, ty_alloc_size));
                                if ap_is_zero(rem) { have = true; new_c = q; }
                            } else if eo == .SDIV {
                                q := ap_sdiv(c, ap_from_u64(c.bits, ty_alloc_size));
                                rem := ap_srem(c, ap_from_u64(c.bits, ty_alloc_size));
                                if !ap_is_all_ones(q) && ap_is_zero(rem) { have = true; new_c = q; }
                            }
                        }
                        if have {
                            nop := icb_binop(eo, vv, const_int_ap(vtype(vv), new_c), "", F_EXACT);
                            return create_gep(ir.t_i8, op(g, 0), .[nop], gep_nw_bits(g));
                        }
                    }
                }
            }
        }
    }
    if is_vector_type(gep_ty) return NONE;
    if !gep_is_inbounds(g) {
        idx_width := dl_index_size_bits(type_addrspace(vtype(ptr)));
        underlying, base_off := strip_and_accumulate_inbounds_constant_offsets(ptr, ap_zero(idx_width));
        can_be_null, deref_bytes := pointer_dereferenceable_bytes(underlying);
        if !can_be_null && deref_bytes != 0 {
            ok, off := gep_accumulate_constant_offset(g, base_off);
            if ok && ap_is_non_negative(off) {
                if ap_ule(off, ap_from_u64(idx_width, deref_bytes)) {
                    ng := create_gep(et, ptr, indices, F_INBOUNDS);
                    set_name(ng, vname(g));
                    return ng;
                }
            }
        }
    }
    if gep_has_nusw(g) && !gep_has_nuw(g) {
        all_nn := true;
        for indices if !is_known_non_negative(it, ic_q(g)) { all_nn = false; break; }
        if all_nn {
            gep_set_nw(g, gep_nw_bits(g) | F_GEP_NUW);
            return g;
        }
    }
    if gep_num_indices(g) == 1 {
        preserved :: (g: Value_Id, add_is_nuw: bool) -> u32 {
            if gep_has_nuw(g) && add_is_nuw return gep_nw_bits(g);
            return 0;
        }
        i1 := op(g, 1);
        oka, idx1, idx2 := pm_add_like(i1);
        if oka && has_one_use(i1) {
            nuw := pm_nuw_add_like_i(i1);
            nwf := preserved(g, nuw);
            np := icb_gep(et, op(g, 0), .[idx1], "", nwf);
            return ic_replace_inst_uses_with(g, icb_gep(et, np, .[idx2], "", nwf));
        }
        okx, inner := pm_sext_like(i1);
        if okx && has_one_use(i1) && has_one_use(inner) {
            okn, a, c := pm_nsw_add_like_i(inner);
            if okn && vkind(c) == .C_INT && !is_vector_type(vtype(c)) {
                nuw := false;
                if opr_code(i1) == .ZEXT && (opr_flags(i1) & F_EXACT) != 0 { oku := pm_nuw_add_like_i(inner); nuw = oku; }
                nwf := preserved(g, nuw);
                np := icb_gep(et, op(g, 0), .[icb_sext(a, vtype(i1))], "", nwf);
                return ic_replace_inst_uses_with(g, icb_gep(et, np, .[icb_sext(c, vtype(i1))], "", nwf));
            }
        }
    }
    r := ic_fold_select_gep(g); if r != NONE return r;
    if indices.count == 1 && gep_is_inbounds(g) && gep_has_nuw(g) {
        x0 := indices[0];
        oks, x, y := pm_binop(x0, .SREM);
        if oks && has_one_use(x0) && is_known_to_be_a_power_of_two(y, true, ic_q(g)) {
            ni := icb_binop(.UREM, x, y, name_ref(vname(x0)));
            return create_gep(et, ptr, .[ni], gep_nw_bits(g));
        }
    }
    return NONE;
}
// m_PtrToIntOrAddr(m_Value(X))
pm_ptr_to_int_or_addr :: (v: Value_Id) -> (bool, Value_Id) {
    o := opr_code(v);
    if o == .PTRTOINT || o == .PTRTOADDR return true, op(v, 0);
    return false, NONE;
}
// DataLayout::getAddressSizeInBits
dl_address_size_bits :: (as: u32) -> u32 { return dl_ptr_spec(as).idx_bits; }

// ---------------------------------------------------------------- allocation sites

// isNeverEqualToUnescapedAlloc
is_never_equal_to_unescaped_alloc :: (v: Value_Id, ai: Value_Id) -> bool {
    if vkind(v) == .C_NULL return true;
    if is_inst(v) && inst_op(v) == .LOAD return vkind(op(v, 0)) == .GLOBAL_VAR;
    return is_alloc_like_fn(v) && v != ai;
}
// isRemovableWrite
is_removable_write :: (cb: Value_Id, used_v: Value_Id) -> bool {
    if has_uses(cb) return false;
    if is_terminator(inst_op(cb)) return false;
    if !will_return(cb) || !call_does_not_throw(cb) return false;
    ok, dest := mloc_for_dest_call(cb);
    return ok && dest.ptr == used_v;
}

// isAllocSiteRemovable: (removable, access ModRef)
is_alloc_site_removable :: (ai: Value_Id, users: *[..] Value_Id, know_init: bool) -> (bool, u8) {
    work: [..] Value_Id; work.allocator = temp;
    family := get_allocation_family(ai);
    array_add(*work, ai);
    access := ifx know_init then MR_NO else MR_MOD;
    while work.count {
        pi := pop(*work);
        u := ir.v_first_use[pi];
        while u != NONE {
            defer u = ir.u_next[u];
            i := ir.u_user[u];
            if users.count >= ic_cl.max_alloc_site_removable_users return false, 0;
            o := inst_op(i);
            if o == .ADDRSPACECAST || o == .BITCAST || o == .GEP { array_add(users, i); array_add(*work, i); continue; }
            if o == .ICMP {
                p := inst(i).pred;
                if p != ICMP_EQ && p != ICMP_NE return false, 0;
                other := ifx op(i, 0) == pi then op(i, 1) else op(i, 0);
                if !is_never_equal_to_unescaped_alloc(other, ai) return false, 0;
                if is_call_base(ai) {
                    callee := call_called_function(ai);
                    if callee != NONE && vname(callee) == "aligned_alloc" && mb_tli_knows(callee, value_function(ai)) && is_aligned_alloc_proto(callee) {
                        oka, al := pm_apint(call_arg(ai, 0));
                        oks, sz := pm_apint(call_arg(ai, 1));
                        valid := oka && oks && ap_is_power_of_2(al) && ap_is_zero(ap_urem(sz, al));
                        if !valid return false, 0;
                    }
                }
                array_add(users, i);
                continue;
            }
            if o == .CALL {
                id := call_iid(i);
                if id != NOT_INTRINSIC {
                    if id == IID_MEMMOVE || id == IID_MEMCPY || id == IID_MEMSET {
                        if mi_is_volatile(i) return false, 0;
                        new_access := ifx call_arg(i, 0) == pi then MR_MOD else MR_REF;
                        if (access & ~new_access) != MR_NO return false, 0;
                        access |= new_access;
                        array_add(users, i);
                        continue;
                    }
                    if id == IID_ASSUME || id == IID_INVARIANT_START || id == IID_INVARIANT_END || id == IID_LIFETIME_START ||
                       id == IID_LIFETIME_END || id == IID_OBJECTSIZE { array_add(users, i); continue; }
                    if id == IID_LAUNDER_INVARIANT_GROUP || id == IID_STRIP_INVARIANT_GROUP { array_add(users, i); array_add(*work, i); continue; }
                    return false, 0;
                }
                if family.count && get_freed_operand(i) == pi && get_allocation_family(i) == family { array_add(users, i); continue; }
                if family.count && get_reallocated_operand(i) == pi && get_allocation_family(i) == family { array_add(users, i); array_add(*work, i); continue; }
                if (access & MR_REF) == 0 && is_removable_write(i, pi) { access |= MR_MOD; array_add(users, i); continue; }
                return false, 0;
            }
            if o == .STORE {
                if (inst(i).flags & F_VOLATILE) != 0 || op(i, 1) != pi return false, 0;
                if (access & MR_REF) != 0 return false, 0;
                access |= MR_MOD;
                array_add(users, i);
                continue;
            }
            if o == .LOAD {
                if (inst(i).flags & F_VOLATILE) != 0 || op(i, 0) != pi return false, 0;
                if (access & MR_MOD) != 0 return false, 0;
                access |= MR_REF;
                array_add(users, i);
                continue;
            }
            return false, 0;
        }
    }
    return true, access;
}
// TLI prototype of aligned_alloc: ptr (size_t, size_t)
is_aligned_alloc_proto :: (f: Value_Id) -> bool {
    ft := glob(f).value_type;
    return func_nparams(ft) == 2 && is_ptr_type(func_ret(ft)) && is_int_type(func_param(ft, 0)) &&
           type_int_width(func_param(ft, 0)) == dl_index_size_bits(0) && func_param(ft, 0) == func_param(ft, 1);   // size_t: the index width of address space 0
}

// visitAllocSite
ic_visit_alloc_site :: (mi: Value_Id) -> Value_Id {
    raw_users: [..] Value_Id; raw_users.allocator = temp;
    dvrs: [..] u32; dvrs.allocator = temp;
    if inst_op(mi) == .ALLOCA find_dbg_users(ic.f, mi, *dvrs);
    know_init_undef := false; know_init_zero := false;
    init := get_initial_value_of_allocation(mi, ir.t_i8);
    if init != NONE {
        if vkind(init) == .C_UNDEF || vkind(init) == .C_POISON know_init_undef = true;
        else if is_null_value(init) know_init_zero = true;
    }
    if fn_has_fn_attr(ic.f, .SanitizeMemory) || fn_has_fn_attr(ic.f, .SanitizeAddress) know_init_undef = false;
    removable, access := is_alloc_site_removable(mi, *raw_users, know_init_zero || know_init_undef);
    if !removable return NONE;
    // WeakTrackingVH: entries become null when the user is deleted
    users := raw_users;
    for * users {
        i := it.*;
        if i == NONE || vkind(i) == .DEAD { it.* = NONE; continue; }
        id := call_iid(i);
        if id == IID_OBJECTSIZE {
            inserted: [..] Value_Id; inserted.allocator = temp;
            result := lower_object_size_call(i, ic_aa(), true, *inserted);
            for inserted wl_add(it);
            ic_replace_inst_uses_with(i, result);
            ic_erase_inst(i);
            it.* = NONE;
            continue;
        }
        if is_mem_transfer_inst(i) && know_init_zero && (access & MR_REF) != 0 {
            saved := ic.b;
            defer ic.b = saved;
            icb_set_insert_point(i);
            m := icb_memset(call_arg(i, 0), const_int(ir.t_i8, 0), call_arg(i, 2), mi_param_align(i, 0));
            copy_metadata(m, i);
        }
    }
    for i: users {
        if i == NONE || vkind(i) == .DEAD continue;
        o := inst_op(i);
        if o == .ICMP {
            ic_replace_inst_uses_with(i, const_int(vtype(i), ifx inst(i).pred == ICMP_NE then cast(u64) 1 else 0));
        } else if o == .STORE {
            for r: dvrs if dbgr(r).owner != NONE && (dbgr(r).kind == .DECLARE || dbgr(r).kind == .DECLARE_VALUE) convert_debug_declare_to_debug_value_store(r, i);
        } else {
            rep: Value_Id;
            if o == .LOAD rep = ifx know_init_undef then const_undef(vtype(i)) else const_null_value(vtype(i));
            else rep = const_poison(vtype(i));
            ic_replace_inst_uses_with(i, rep);
        }
        ic_erase_inst(i);
    }
    if inst_op(mi) == .INVOKE {
        // Replace invoke with a NOP intrinsic to maintain the original CFG
        f := get_or_insert_intrinsic_declaration(IID_DONOTHING, .[]);
        fty := glob(f).value_type;
        ni := new_inst(.INVOKE, ir.t_void, 3);
        inst(ni).ty2 = fty;
        set_op(ni, 0, op(mi, nops(mi) - 3)); set_op(ni, 1, op(mi, nops(mi) - 2)); set_op(ni, 2, f);
        block_append_inst(inst_block(mi), ni);
        set_metadata(ni, 0, get_metadata(mi, 0));
    }
    for r: dvrs {
        if dbgr(r).owner == NONE continue;
        if dbgr(r).kind == .DECLARE || dbgr(r).kind == .DECLARE_VALUE || diexpr_starts_with_deref(dbgr(r).expr) dbgr_erase(r);
    }
    return ic_erase_inst(mi);
}
// CreateMemSet(Ptr, Val, Size, Align)
icb_memset :: (ptr: Value_Id, val: Value_Id, size: Value_Id, align: u64) -> Value_Id {
    ci := icb_intrinsic(IID_MEMSET, .[vtype(ptr), vtype(size)], .[ptr, val, size, const_int(ir.t_i1, 0)]);
    if align add_param_align(ci, 0, align);
    return ci;
}

// tryToMoveFreeBeforeNullTest
ic_try_to_move_free_before_null_test :: (fi: Value_Id) -> Value_Id {
    o := call_arg(fi, 0);
    free_bb := inst_block(fi);
    pred_bb := block_single_predecessor(free_bb);
    if pred_bb == NONE return NONE;
    term := block_terminator(free_bb);
    if inst_op(term) != .BR return NONE;
    succ_bb := get_successor(term, 0);
    if block_size(free_bb) != 2 {
        for x: block_insts(free_bb) {
            if x == fi || x == term || call_iid(x) == IID_PSEUDOPROBE continue;
            if !is_cast_op(inst_op(x)) || !cast_is_noop(x) return NONE;
        }
    }
    ti := block_terminator(pred_bb);
    if inst_op(ti) != .CONDBR return NONE;
    c := op(ti, 0);
    if !is_inst(c) || inst_op(c) != .ICMP return NONE;
    l := op(c, 0);
    if !(l == o || l == strip_pointer_casts(o)) || !pm_zero(op(c, 1)) return NONE;
    pred := inst(c).pred;
    if pred != ICMP_EQ && pred != ICMP_NE return NONE;
    tb := get_successor(ti, 0); fb := get_successor(ti, 1);
    if succ_bb != (ifx pred == ICMP_EQ then tb else fb) return NONE;
    x := block_first(free_bb);
    while x != NONE && x != term {
        nx := inst(x).next;
        inst_move_before(x, ti);
        x = nx;
    }
    l0 := attr_list_param(inst(fi).attrs, 0);
    items: [..] Attr; items.allocator = temp;
    deref: u64 = 0;
    for attr_set_items(l0) {
        if it.kind == .NonNull continue;
        if it.kind == .Dereferenceable { deref = it.ival; continue; }
        array_add(*items, it);
    }
    if deref {
        a: Attr; a.kind = .DereferenceableOrNull; a.ival = deref; a.ty = NONE;
        array_add(*items, a);
    }
    inst(fi).attrs = attr_list_with_param(inst(fi).attrs, 0, attr_set_get(items));
    return fi;
}

// visitFree(FI, Op)
ic_visit_free :: (fi: Value_Id, o: Value_Id) -> Value_Id {
    if vkind(o) == .C_UNDEF || vkind(o) == .C_POISON {
        ic_create_non_terminator_unreachable(fi);
        return ic_erase_inst(fi);
    }
    if vkind(o) == .C_NULL return ic_erase_inst(fi);
    if is_inst(o) && inst_op(o) == .CALL && has_one_use(o) {
        ro := get_reallocated_operand(o);
        if ro != NONE {
            ic_replace_inst_uses_with(o, ro);
            return ic_erase_inst(o);
        }
    }
    if ic.min_size {
        callee := call_called_function(fi);
        if callee != NONE && vname(callee) == "free" && mb_tli_knows(callee, ic.f) && !call_is_no_builtin(fi) {
            ft := glob(callee).value_type;
            if func_ret(ft) == ir.t_void && func_nparams(ft) == 1 && is_ptr_type(func_param(ft, 0)) {
                r := ic_try_to_move_free_before_null_test(fi);
                if r != NONE return r;
            }
        }
    }
    return NONE;
}

// ---------------------------------------------------------------- switch

switch_num_cases :: (sw: Value_Id) -> u32 { return nops(sw) - 2; }
switch_case_value_at :: (sw: Value_Id, k: u32) -> Value_Id { return ir.u_aux[ir.v_ops[sw] + 2 + k]; }
switch_set_case_value :: (sw: Value_Id, k: u32, c: Value_Id) { ir.u_aux[ir.v_ops[sw] + 2 + k] = c; }

// simplifySwitchOnSelectUsingRanges
simplify_switch_on_select_using_ranges :: (sw: Value_Id, sel: Value_Id, is_true_arm: bool) -> Value_Id {
    cst_idx: u32 = ifx is_true_arm then cast(u32) 1 else 2;
    c := op(sel, cst_idx);
    if !is_scalar_const_int(c) return NONE;
    if switch_find_case_dest(sw, c) != op(sw, 1) return NONE;
    x := op(sel, 3 - cst_idx);
    okc, pred, ss, a, b := pm_icmp(op(sel, 0));
    if !okc || a != x return NONE;
    okr, rhsc := pm_apint(b);
    if !okr return NONE;
    p := pred;
    if is_true_arm p = icmp_inverse(p);
    cr := cr_exact_icmp_region(p, rhsc);
    for k: 0..cast(s64) switch_num_cases(sw) - 1 if !cr_contains(cr, const_ap(switch_case_value_at(sw, cast(u32) k))) return NONE;
    return x;
}

// visitSwitchInst
ic_visit_switch :: (sw: Value_Id) -> Value_Id {
    cond := op(sw, 0);
    n := switch_num_cases(sw);
    ctx := vtype(cond);
    // MaybeInvertible
    kind := 0; op0: Value_Id = NONE; cc: APInt;
    {
        ok, a, b := pm_binop(cond, .ADD);
        if ok { okc, c := pm_apint(b); if okc { kind = 1; op0 = a; cc = c; } }
        if kind == 0 {
            ok, a, b = pm_binop(cond, .SUB);
            if ok { okc, c := pm_apint(a); if okc { kind = 2; op0 = b; cc = c; } }
        }
        if kind == 0 {
            ok, a, b = pm_binop(cond, .XOR);
            if ok { okc, c := pm_apint(b); if okc && !ap_is_min_signed(c) && !ap_is_max_signed(c) { kind = 3; op0 = a; cc = c; } }
        }
    }
    if kind != 0 && has_one_use(cond) {
        for k: 0..cast(s64) n - 1 {
            cv := const_ap(switch_case_value_at(sw, cast(u32) k));
            nv: APInt;
            if kind == 1 nv = ap_sub(cv, cc);
            else if kind == 2 nv = ap_sub(cc, cv);
            else nv = ap_xor(cv, cc);
            switch_set_case_value(sw, cast(u32) k, const_int_ap(ctx, nv));
        }
        return ic_replace_operand(sw, 0, op0);
    }
    {
        oks, a, b := pm_binop(cond, .SHL);
        okc, sh := pm_constant_int_u64(b);
        if oks && okc && sh < cast(u64) scalar_bits(a) {
            all_ok := true;
            for k: 0..cast(s64) n - 1 if cast(u64) ap_ctz(const_ap(switch_case_value_at(sw, cast(u32) k))) < sh { all_ok = false; break; }
            if all_ok {
                nuw := (opr_flags(cond) & F_NUW) != 0; nsw := (opr_flags(cond) & F_NSW) != 0;
                if nuw || nsw || has_one_use(cond) {
                    new_cond := a;
                    if !nuw && !nsw {
                        bw := scalar_bits(a);
                        new_cond = icb_and(a, const_int_ap(vtype(a), ap_low_bits_set(bw, bw - cast(u32) sh)));
                    }
                    for k: 0..cast(s64) n - 1 {
                        cv := const_ap(switch_case_value_at(sw, cast(u32) k));
                        s := ifx nsw then ap_ashr(cv, cast(u32) sh) else ap_lshr(cv, cast(u32) sh);
                        switch_set_case_value(sw, cast(u32) k, const_int_ap(ctx, s));
                    }
                    return ic_replace_operand(sw, 0, new_cond);
                }
            }
        }
    }
    {
        okx, x := pm_zext_or_sext(cond);
        if okx {
            is_zext := opr_code(cond) == .ZEXT;
            nw := scalar_bits(x);
            all_ok := true;
            for k: 0..cast(s64) n - 1 {
                cv := const_ap(switch_case_value_at(sw, cast(u32) k));
                fits := ifx is_zext then ap_active_bits(cv) <= nw else ap_min_signed_bits(cv) <= nw;
                if !fits { all_ok = false; break; }
            }
            if all_ok {
                for k: 0..cast(s64) n - 1 {
                    cv := const_ap(switch_case_value_at(sw, cast(u32) k));
                    switch_set_case_value(sw, cast(u32) k, const_int_ap(vtype(x), ap_trunc(cv, nw)));
                }
                return ic_replace_operand(sw, 0, x);
            }
        }
    }
    if is_inst(cond) && inst_op(cond) == .SELECT {
        v := simplify_switch_on_select_using_ranges(sw, cond, true);
        if v != NONE return ic_replace_operand(sw, 0, v);
        v = simplify_switch_on_select_using_ranges(sw, cond, false);
        if v != NONE return ic_replace_operand(sw, 0, v);
    }
    known := ic_known_bits(cond, sw);
    lz := kb_count_min_leading_zeros(known);
    lo := kb_count_min_leading_ones(known);
    for k: 0..cast(s64) n - 1 {
        cv := const_ap(switch_case_value_at(sw, cast(u32) k));
        lz = min(lz, ap_clz(cv));
        lo = min(lo, ap_clo(cv));
    }
    bw := kb_bits(known);
    new_width := bw - max(lz, lo);
    if new_width > 0 && new_width < bw && ic_should_change_type_widths(bw, new_width) {
        ty := type_int(new_width);
        icb_set_insert_point(sw);
        new_cond := icb_trunc(cond, ty, "trunc");
        for k: 0..cast(s64) n - 1 {
            cv := const_ap(switch_case_value_at(sw, cast(u32) k));
            switch_set_case_value(sw, cast(u32) k, const_int_ap(ty, ap_trunc(cv, new_width)));
        }
        return ic_replace_operand(sw, 0, new_cond);
    }
    if vkind(cond) == .C_UNDEF || vkind(cond) == .C_POISON {
        ic_handle_potentially_dead_successors(inst_block(sw), NONE);
        return NONE;
    }
    if is_scalar_const_int(cond) {
        ic_handle_potentially_dead_successors(inst_block(sw), switch_find_case_dest(sw, cond));
        return NONE;
    }
    return NONE;
}

// ---------------------------------------------------------------- extractvalue

wo_binary_op :: (id: Intrinsic_Id) -> Opcode {
    if id == IID_UADD_WITH_OVERFLOW || id == IID_SADD_WITH_OVERFLOW return .ADD;
    if id == IID_USUB_WITH_OVERFLOW || id == IID_SSUB_WITH_OVERFLOW return .SUB;
    return .MUL;
}
wo_is_signed :: (id: Intrinsic_Id) -> bool { return id == IID_SADD_WITH_OVERFLOW || id == IID_SSUB_WITH_OVERFLOW || id == IID_SMUL_WITH_OVERFLOW; }

// foldExtractOfOverflowIntrinsic
ic_fold_extract_of_overflow_intrinsic :: (ev: Value_Id) -> Value_Id {
    wo := op(ev, 0);
    id := call_iid(wo);
    if !is_with_overflow_iid(id) return NONE;
    lhs := call_arg(wo, 0); rhs := call_arg(wo, 1);
    idx0 := ir.u32_pool[inst(ev).idx];
    okc, c := pm_apint(rhs, true);
    if okc {
        if idx0 == 0 && (id == IID_SMUL_WITH_OVERFLOW || id == IID_UMUL_WITH_OVERFLOW) {
            if ap_is_all_ones(c) return create_neg(lhs);
            if ap_is_power_of_2(c) return create_binop(.SHL, lhs, const_int_of(vtype(lhs), cast(u64) ap_log2(c)));
        }
    }
    if !has_one_use(wo) return NONE;
    if idx0 == 0 {
        bop := wo_binary_op(id);
        ic_replace_inst_uses_with(wo, const_poison(vtype(wo)));
        ic_erase_inst(wo);
        return create_binop(bop, lhs, rhs);
    }
    if id == IID_USUB_WITH_OVERFLOW return create_icmp(ICMP_ULT, lhs, rhs);
    if id == IID_SMUL_WITH_OVERFLOW && is_int_or_int_vector_n(vtype(lhs), 1) return create_binop(.AND, lhs, rhs);
    if id == IID_UMUL_WITH_OVERFLOW && lhs == rhs {
        bw := scalar_bits(lhs);
        if bw % 2 == 0 return create_icmp(ICMP_UGT, lhs, const_int_ap(vtype(lhs), ap_low_bits_set(bw, bw / 2)));
    }
    if okc {
        nwr := cr_make_exact_no_wrap_region(wo_binary_op(id), c, !wo_is_signed(id));
        pred, new_rhs, offset := cr_equivalent_icmp(nwr);
        op_ty := vtype(rhs);
        new_lhs := lhs;
        if !ap_is_zero(offset) new_lhs = icb_add(new_lhs, const_int_ap(op_ty, offset));
        return create_icmp(icmp_inverse(pred), new_lhs, const_int_ap(op_ty, new_rhs));
    }
    return NONE;
}

// foldFrexpOfSelect
ic_fold_frexp_of_select :: (ev: Value_Id, frexp: Value_Id, sel: Value_Id) -> Value_Id {
    if !has_one_use(sel) || !has_one_use(frexp) return NONE;
    cond := op(sel, 0); tv := op(sel, 1); fv := op(sel, 2);
    var_op: Value_Id; const_is_true: bool; cval: APFloat;
    okt, ct := pm_apfloat(tv);
    if okt { var_op = fv; const_is_true = true; cval = ct; }
    else {
        okf, cf := pm_apfloat(fv);
        if !okf return NONE;
        var_op = tv; const_is_true = false; cval = cf;
    }
    icb_set_insert_point(ev);
    callee := call_called_function(frexp);
    nf := icb_call_fn(callee, .[var_op], "frexp");
    copy_ir_flags(nf, frexp);
    nev := icb_extract_value(nf, .[0], "mantissa");
    mw, e := fp_frexp(cval.k, cval.w, 0);
    cm := const_fp_words(scalar_type(vtype(tv)), mw);
    if is_vector_type(vtype(tv)) cm = cf_get_splat(vtype(tv), cm);
    return icb_select_fmf(cond, ifx const_is_true then cm else nev, ifx const_is_true then nev else cm, get_fmf(sel), "select.frexp", sel);
}
// Builder.CreateCall(F, Args, Name)
icb_call_fn :: (f: Value_Id, args: [] Value_Id, name: string = "") -> Value_Id {
    fty := glob(f).value_type;
    i := new_inst(.CALL, func_ret(fty), cast(u32)(args.count + 1));
    inst(i).ty2 = fty;
    for args set_op(i, cast(u32) it_index, it);
    set_op(i, cast(u32) args.count, f);
    if is_fp_math_inst(i) set_fmf(i, ic.b_fmf);
    return icb_insert(i, name);
}
// InsertValueInst::Create (unlinked)
create_insert_value :: (agg: Value_Id, v: Value_Id, idxs: [] u32) -> Value_Id {
    i := new_inst(.INSERTVALUE, vtype(agg), 2);
    set_op(i, 0, agg); set_op(i, 1, v);
    cp := NewArray(idxs.count, u32,, allocator = temp);   // idxs may be a view into ir.u32_pool
    for idxs cp[it_index] = it;
    r := inst(i);
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) cp.count;
    for cp array_add(*ir.u32_pool, it);
    return i;
}
inst_indices_copy :: (i: Value_Id) -> [] u32 {   // a copy: u32_pool may grow while it is used
    r := inst(i);
    out := NewArray(r.nidx, u32,, allocator = temp);
    for k: 0..cast(s64) r.nidx - 1 out[k] = ir.u32_pool[r.idx + cast(u32) k];
    return out;
}

// visitExtractValueInst
ic_visit_extract_value :: (ev: Value_Id) -> Value_Id {
    agg := op(ev, 0);
    if inst(ev).nidx == 0 return ic_replace_inst_uses_with(ev, agg);
    eidx := inst_indices_copy(ev);
    v := simplify_extract_value_inst(agg, eidx, ic_q(ev));
    if v != NONE return ic_replace_inst_uses_with(ev, v);
    if eidx.count == 1 && eidx[0] == 0 && call_iid(agg) == IID_FREXP {
        a := call_arg(agg, 0);
        if is_inst(a) && inst_op(a) == .SELECT {
            r := ic_fold_frexp_of_select(ev, agg, a);
            if r != NONE return ic_replace_inst_uses_with(ev, r);
        }
    }
    if is_inst(agg) && inst_op(agg) == .INSERTVALUE {
        iidx := inst_indices_copy(agg);
        e := 0; s := 0;
        while e < eidx.count && s < iidx.count {
            if iidx[s] != eidx[e] return create_extract_value(op(agg, 0), eidx);
            e += 1; s += 1;
        }
        if e == eidx.count && s == iidx.count return ic_replace_inst_uses_with(ev, op(agg, 1));
        if e == eidx.count {
            nev := icb_extract_value(op(agg, 0), eidx);
            return create_insert_value(nev, op(agg, 1), aview(iidx, s, iidx.count - s));
        }
        if s == iidx.count return create_extract_value(op(agg, 1), aview(eidx, e, eidx.count - e));
    }
    r := ic_fold_extract_of_overflow_intrinsic(ev); if r != NONE return r;
    if is_inst(agg) && inst_op(agg) == .LOAD {
        if type_kind(vtype(agg)) == .STRUCT && type_is_scalable(vtype(agg)) return NONE;
        if inst_is_simple(agg) && has_one_use(agg) {
            idxs: [..] Value_Id; idxs.allocator = temp;
            array_add(*idxs, const_int(ir.t_i32, 0));
            for eidx array_add(*idxs, const_int(ir.t_i32, it));
            icb_set_insert_point(agg);
            g := icb_gep(vtype(agg), op(agg, 0), idxs, "", F_INBOUNDS);
            nl := icb_aligned_load(vtype(ev), g, dl_abi_align(vtype(ev)));
            set_aa_metadata(nl, get_aa_metadata(agg));
            return ic_replace_inst_uses_with(ev, nl);
        }
    }
    if is_phi(agg) { r = ic_fold_op_into_phi(ev, agg); if r != NONE return r; }
    if is_inst(agg) && inst_op(agg) == .SELECT { r = ic_fold_op_into_select(ev, agg, true); if r != NONE return r; }
    return NONE;
}

// ---------------------------------------------------------------- landingpad

Eh_Personality :: enum u8 { UNKNOWN; GNU_ADA; GNU_C; GNU_C_SJLJ; GNU_CXX; GNU_CXX_SJLJ; GNU_OBJC; MSVC_X86SEH; MSVC_TABLESEH; MSVC_CXX; CORECLR; RUST; WASM_CXX; XL_CXX; ZOS_CXX; }
// classifyEHPersonality (EHPersonalities.cpp)
classify_eh_personality :: (pers: Value_Id) -> Eh_Personality {
    if pers == NONE return .UNKNOWN;
    f := strip_pointer_casts(pers);
    if vkind(f) != .FUNCTION return .UNKNOWN;
    n := vname(f);
    if n == {
        case "__gnat_eh_personality"; return .GNU_ADA;
        case "__gcc_personality_v0"; return .GNU_C;
        case "__gcc_personality_seh0"; return .GNU_C;
        case "__gcc_personality_sj0"; return .GNU_C_SJLJ;
        case "__gxx_personality_v0"; return .GNU_CXX;
        case "__gxx_personality_seh0"; return .GNU_CXX;
        case "__gxx_personality_sj0"; return .GNU_CXX_SJLJ;
        case "__gxx_wasm_personality_v0"; return .WASM_CXX;
        case "__objc_personality_v0"; return .GNU_OBJC;
        case "_except_handler3"; return .MSVC_X86SEH;
        case "_except_handler4"; return .MSVC_X86SEH;
        case "__C_specific_handler"; return .MSVC_TABLESEH;
        case "__CxxFrameHandler3"; return .MSVC_CXX;
        case "ProcessCLRException"; return .CORECLR;
        case "rust_eh_personality"; return .RUST;
        case "__xlcxx_personality_v1"; return .XL_CXX;
        case "__zos_cxx_personality_v2"; return .ZOS_CXX;
    }
    return .UNKNOWN;
}
// isCatchAll
is_catch_all :: (p: Eh_Personality, tinfo: Value_Id) -> bool {
    if p == .GNU_C || p == .GNU_C_SJLJ || p == .RUST || p == .UNKNOWN || p == .GNU_ADA return false;
    return vkind(tinfo) == .C_NULL;
}

// visitLandingPadInst
ic_visit_landing_pad :: (li: Value_Id) -> Value_Id {
    pers := classify_eh_personality(fn_personality(ic.f));
    make_new := false;
    new_clauses: [..] Value_Id; new_clauses.allocator = temp;
    cleanup := (inst(li).flags & F_CLEANUP) != 0;
    already: [..] Value_Id; already.allocator = temp;
    n := nops(li);
    for i: 0..cast(s64) n - 1 {
        is_last := i + 1 == n;
        clause := op(li, cast(u32) i);
        is_filter := ir.u32_pool[inst(li).idx + cast(u32) i] != 0;
        if !is_filter {
            ti := strip_pointer_casts(clause);
            if pr_insert(*already, ti) array_add(*new_clauses, clause);
            else make_new = true;
            if is_catch_all(pers, ti) {
                if !is_last make_new = true;
                cleanup = false;
                break;
            }
        } else {
            fty := vtype(clause);
            nti := type_count(fty);
            if nti == 0 {
                array_add(*new_clauses, clause);
                if !is_last make_new = true;
                cleanup = false;
                break;
            }
            make_new_filter := false;
            new_elts: [..] Value_Id; new_elts.allocator = temp;
            if vkind(clause) == .C_ZERO {
                ti := const_null_value(type_elem(fty));
                if is_catch_all(pers, ti) { make_new = true; continue; }
                array_add(*new_elts, ti);
                if nti > 1 make_new_filter = true;
            } else {
                seen: [..] Value_Id; seen.allocator = temp;
                saw_catch_all := false;
                for j: 0..cast(s64) nti - 1 {
                    elt := const_aggregate_elt(clause, cast(u64) j);
                    ti := strip_pointer_casts(elt);
                    if is_catch_all(pers, ti) { saw_catch_all = true; break; }
                    if pr_insert(*seen, ti) array_add(*new_elts, elt);
                }
                if saw_catch_all { make_new = true; continue; }
                if cast(u64) new_elts.count < nti make_new_filter = true;
            }
            if make_new_filter {
                clause = const_array_of(type_array(cast(u64) new_elts.count, type_elem(fty)), new_elts);
                make_new = true;
            }
            array_add(*new_clauses, clause);
            if make_new_filter && new_elts.count == 0 { cleanup = false; break; }
        }
    }
    is_filter_v :: (c: Value_Id) -> bool { return type_kind(vtype(c)) == .ARRAY; }
    filter_len :: (c: Value_Id) -> u64 { return type_count(vtype(c)); }
    i := 0;
    while i + 1 < new_clauses.count {
        j := i;
        while j != new_clauses.count && is_filter_v(new_clauses[j]) j += 1;
        for k: i..j-2 {
            if filter_len(new_clauses[k + 1]) < filter_len(new_clauses[k]) {
                // std::stable_sort by length (insertion sort is stable)
                for a: i+1..j-1 {
                    x := new_clauses[a];
                    b := a - 1;
                    while b >= i && filter_len(x) < filter_len(new_clauses[b]) { new_clauses[b + 1] = new_clauses[b]; b -= 1; }
                    new_clauses[b + 1] = x;
                }
                make_new = true;
                break;
            }
        }
        i = j + 1;
    }
    i = 0;
    while i + 1 < new_clauses.count {
        defer i += 1;
        filter := new_clauses[i];
        if !is_filter_v(filter) continue;
        felts := filter_len(filter);
        j := new_clauses.count - 1;
        while j != i {
            defer j -= 1;
            lfilter := new_clauses[j];
            if !is_filter_v(lfilter) continue;
            if felts == 0 { array_ordered_remove_by_index(*new_clauses, j); make_new = true; continue; }
            lelts := filter_len(lfilter);
            if felts > lelts continue;
            if vkind(lfilter) == .C_ZERO {
                if vkind(filter) == .C_ZERO { array_ordered_remove_by_index(*new_clauses, j); make_new = true; }
                continue;
            }
            if vkind(filter) == .C_ZERO {
                for l: 0..cast(s64) lelts - 1 if vkind(const_aggregate_elt(lfilter, cast(u64) l)) == .C_NULL {
                    array_ordered_remove_by_index(*new_clauses, j); make_new = true; break;
                }
                continue;
            }
            all_found := true;
            for f: 0..cast(s64) felts - 1 {
                fti := strip_pointer_casts(const_aggregate_elt(filter, cast(u64) f));
                all_found = false;
                for l: 0..cast(s64) lelts - 1 if strip_pointer_casts(const_aggregate_elt(lfilter, cast(u64) l)) == fti { all_found = true; break; }
                if !all_found break;
            }
            if all_found { array_ordered_remove_by_index(*new_clauses, j); make_new = true; }
        }
    }
    if make_new {
        nli := new_inst(.LANDINGPAD, vtype(li), 0);
        grow_ops(nli, cast(u32) new_clauses.count);
        r := inst(nli);
        r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) new_clauses.count;
        for new_clauses { add_op(nli, it); array_add(*ir.u32_pool, ifx is_filter_v(it) then cast(u32) 1 else 0); }
        if new_clauses.count == 0 cleanup = true;
        if cleanup inst(nli).flags |= F_CLEANUP;
        return nli;
    }
    if ((inst(li).flags & F_CLEANUP) != 0) != cleanup {
        inst(li).flags &= ~cast(u32) F_CLEANUP;
        return li;
    }
    return NONE;
}

// ---------------------------------------------------------------- freeze

// Instruction::getInsertionPointAfterDef (NONE = no insertion point); `head` = the iterator's head bit
inst_insertion_point_after_def :: (i: Value_Id) -> (Value_Id, bb: Value_Id, head: bool) {
    o := inst_op(i);
    if o == .PHI { b := inst_block(i); return block_first_insertion_pt(b), b, true; }
    if o == .INVOKE { b := op(i, nops(i) - 3); return block_first_insertion_pt(b), b, true; }
    if o == .CALLBR return NONE, NONE, false;
    return inst(i).next, inst_block(i), true;
}
// BasicBlock::getFirstNonPHIOrDbgOrAlloca
block_first_non_phi_or_dbg_or_alloca :: (b: Value_Id) -> Value_Id {
    pt := block_first_non_phi(b);
    if pt == NONE return NONE;
    if is_eh_pad(pt) pt = inst(pt).next;
    if b == fn_entry(block_fn(b)) {
        while pt != NONE && (inst_op(pt) == .ALLOCA || call_iid(pt) == IID_PSEUDOPROBE) {
            if inst_op(pt) == .ALLOCA && !alloca_is_static(pt) break;
            pt = inst(pt).next;
        }
    }
    return pt;
}

// pushFreezeToPreventPoisonFromPropagating
ic_push_freeze_to_prevent_poison_from_propagating :: (fi: Value_Id) -> Value_Id {
    orig := op(fi, 0);
    if !is_inst(orig) || !has_one_use(orig) || is_phi(orig) return NONE;
    if can_create_undef_or_poison(orig, false) return NONE;
    maybe_poison: Value_Id = NONE;
    for k: 0..cast(s64) nops(orig) - 1 {
        v := op(orig, cast(u32) k);
        if vkind(v) == .MD_VALUE || is_guaranteed_not_to_be_undef_or_poison(v) || (maybe_poison != NONE && maybe_poison == v) continue;
        if maybe_poison == NONE maybe_poison = v;
        else return NONE;
    }
    drop_poison_generating_annotations(orig);
    if maybe_poison == NONE return orig;
    icb_set_insert_point(orig);
    frozen := icb_freeze(maybe_poison, tprint("%.fr", vname(maybe_poison)));
    replace_uses_of_with(orig, maybe_poison, frozen);
    return orig;
}

// foldFreezeIntoRecurrence
ic_fold_freeze_into_recurrence :: (fi: Value_Id, pn: Value_Id) -> Value_Id {
    start_u: Use_Id = NONE;
    work: [..] Value_Id; work.allocator = temp;
    for k: 0..cast(s64) nops(pn) - 1 {
        if dt_dominates(ic.dt, inst_block(pn), phi_block(pn, cast(u32) k)) { array_add(*work, op(pn, cast(u32) k)); continue; }
        if start_u != NONE return NONE;
        start_u = op_use(pn, cast(u32) k);
    }
    if start_u == NONE || work.count == 0 return NONE;
    start_v := ir.u_val[start_u];
    start_bb := ir.u_aux[start_u];
    start_needs_freeze := !is_guaranteed_not_to_be_undef_or_poison(start_v);
    if start_needs_freeze && block_terminator(start_bb) == start_v return NONE;
    visited: [..] Value_Id; visited.allocator = temp;
    drop: [..] Value_Id; drop.allocator = temp;
    while work.count {
        v := pop(*work);
        if !pr_insert(*visited, v) continue;
        if visited.count > 32 return NONE;
        if v == pn || is_guaranteed_not_to_be_undef_or_poison(v) continue;
        if !is_inst(v) || can_create_undef_or_poison(v, false) return NONE;
        array_add(*drop, v);
        for k: 0..cast(s64) nops(v) - 1 array_add(*work, op(v, cast(u32) k));
    }
    for drop drop_poison_generating_annotations(it);
    if start_needs_freeze {
        icb_set_insert_point(block_terminator(start_bb));
        frozen := icb_freeze(start_v, tprint("%.fr", vname(start_v)));
        ic_replace_use(start_u, frozen);
    }
    return ic_replace_inst_uses_with(fi, pn);
}

// freezeOtherUses
ic_freeze_other_uses :: (fi: Value_Id) -> bool {
    o := op(fi, 0);
    if is_const(o) || has_one_use(o) return false;
    move_before: Value_Id;
    if vkind(o) == .ARGUMENT {
        move_before = block_first_non_phi_or_dbg_or_alloca(fn_entry(ic.f));
    } else {
        mb, bb, head := inst_insertion_point_after_def(o);
        if mb == NONE return false;
        move_before = mb;
    }
    changed := false;
    if fi != move_before {
        inst_move_before_dbg(fi, move_before);   // MoveBefore.setHeadBit(false): absorb the records at MoveBefore
        changed = true;
    }
    users: [..] Value_Id; users.allocator = temp;
    u := ir.v_first_use[o];
    while u != NONE {
        nu := ir.u_next[u];
        if dt_dominates_use(ic.dt, fi, u) {
            array_add(*users, ir.u_user[u]);
            use_set(u, fi);
            changed = true;
        }
        u = nu;
    }
    for users { wl_push_users(it); wl_push(it); }
    return changed;
}

// isUsedWithinShuffleVector
is_used_within_shuffle_vector :: (v: Value_Id) -> bool {
    u := ir.v_first_use[v];
    while u != NONE {
        us := ir.u_user[u];
        if is_inst(us) && inst_op(us) == .SHUFFLEVECTOR return true;
        if opr_code(us) == .BITCAST && op(us, 0) == v && is_used_within_shuffle_vector(us) return true;
        u = ir.u_next[u];
    }
    return false;
}

// visitFreeze
ic_visit_freeze :: (i: Value_Id) -> Value_Id {
    op0 := op(i, 0);
    v := simplify_freeze_inst(op0, ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if is_phi(op0) {
        r := ic_fold_op_into_phi(i, op0); if r != NONE return r;
        r = ic_fold_freeze_into_recurrence(i, op0); if r != NONE return r;
    }
    ni := ic_push_freeze_to_prevent_poison_from_propagating(i);
    if ni != NONE return ic_replace_inst_uses_with(i, ni);
    if pm_undef(op0) {
        if is_used_within_shuffle_vector(i) return NONE;
        return ic_replace_inst_uses_with(i, ic_freeze_undef_replacement(i, vtype(i)));
    }
    if is_const(op0) && contains_undef_or_poison_element(op0) && !contains_constant_expression(op0) {
        t := vtype(op0);
        if type_kind(t) == .VECTOR {
            best: Value_Id = NONE;
            n := type_count(t);
            for k: 0..cast(s64) n - 1 {
                e := cf_elt(op0, cast(u64) k);
                if e != NONE && !pm_undef(e) { best = e; break; }
            }
            if best == NONE best = const_null_value(scalar_type(t));
            return ic_replace_inst_uses_with(i, ic_replace_undefs_with(op0, best));
        }
    }
    if ic_freeze_other_uses(i) return i;
    return NONE;
}
// getUndefReplacement
ic_freeze_undef_replacement :: (fi: Value_Id, ty: Type_Id) -> Value_Id {
    pick_common_constant_from_phi :: (pn: Value_Id) -> Value_Id {
        best: Value_Id = NONE;
        for k: 0..cast(s64) nops(pn) - 1 {
            v := op(pn, cast(u32) k);
            if is_inst(v) && inst_op(v) == .FREEZE && pm_undef(op(v, 0)) continue;
            if !is_const(v) return NONE;
            if !is_guaranteed_not_to_be_undef_or_poison(v) return NONE;
            if best != NONE && best != v return NONE;
            best = v;
        }
        return best;
    }
    null_v := const_null_value(ty);
    best: Value_Id = NONE;
    u := ir.v_first_use[fi];
    while u != NONE {
        us := ir.u_user[u];
        u = ir.u_next[u];
        v := null_v;
        if is_inst(us) && inst_op(us) == .OR v = const_all_ones_of(ty);
        else if is_inst(us) && inst_op(us) == .SELECT && op(us, 0) == fi && is_const(op(us, 1)) v = const_all_ones_of(ty);   // ConstantInt::getTrue(Ty)
        else if is_inst(us) && inst_op(us) == .SELECT && (op(us, 1) == fi || op(us, 2) == fi) {
            // m_c_Select(m_Specific(&I), m_Value(V))
            v = ifx op(us, 1) == fi then op(us, 2) else op(us, 1);
            if v == fi || !is_guaranteed_not_to_be_undef_or_poison(v, ic.ac, fi, ic.dt) v = null_v;
        } else if is_phi(us) {
            mv := pick_common_constant_from_phi(us);
            if mv != NONE v = mv;
        }
        if best == NONE best = v;
        else if best != v best = null_v;
    }
    return best;
}

// Function::getPersonalityFn
fn_personality :: (f: Value_Id) -> Value_Id { if glob(f).has_personality return op(f, 0); return NONE; }
// ConstantArray::getOperand(j)
const_aggregate_elt :: (c: Value_Id, j: u64) -> Value_Id { return cf_elt(c, j); }
// ConstantArray::get(Ty, Elts)
const_array_of :: (t: Type_Id, elts: [] Value_Id) -> Value_Id { return const_aggregate(.C_ARRAY, t, elts); }
// AttributeList with the attribute set of parameter `k` replaced
attr_list_with_param :: (l: u32, k: u32, s: u32) -> u32 {
    params: [..] u32; params.allocator = temp;
    if l != 0 for ir.attr_lists[l].params array_add(*params, it);
    while cast(u32) params.count <= k array_add(*params, 0);
    params[k] = s;
    return attr_list_get(attr_list_fn(l), attr_list_ret(l), params);
}

// ArrayRef(...).slice
aview :: (a: [] $T, start: s64, n: s64) -> [] T { r: [] T; r.data = a.data + start; r.count = n; return r; }
