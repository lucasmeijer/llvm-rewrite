// InstCombine: visitShl, visitLShr, visitAShr and their helpers.
// Ported from: llvm/lib/Transforms/InstCombine/InstCombineShifts.cpp (LLVM 23.1.5), in the file's order.
// canTryToConstantAddTwoShiftAmounts, reassociateShiftAmtsOfTwoSameDirectionShifts, canEvaluateShiftedShift,
// canEvaluateShifted, foldShiftedShift and getShiftedValue live at the end of this file too (the compare folds use
// them).

// ---------------------------------------------------------------- Constant helpers (Constants.cpp)

// Constant::replaceUndefsWith(C, Replacement)
ic_replace_undefs_with :: (c: Value_Id, repl: Value_Id) -> Value_Id {
    if pm_undef(c) return repl;
    t := vtype(c);
    if type_kind(t) != .VECTOR return c;
    n := type_count(t);
    elts := NewArray(cast(s64) n, Value_Id,, allocator = temp);
    for k: 0..cast(s64) n - 1 {
        e := cf_elt(c, cast(u64) k);
        elts[k] = ifx e != NONE && pm_undef(e) then repl else e;
    }
    return cf_vector(t, elts);
}

// Constant::mergeUndefsWith(C, Other)
ic_merge_undefs_with :: (c: Value_Id, other: Value_Id) -> Value_Id {
    if pm_undef(c) return c;
    t := vtype(c);
    if pm_undef(other) return const_undef(t);
    if type_kind(t) != .VECTOR return c;
    n := type_count(t);
    elts := NewArray(cast(s64) n, Value_Id,, allocator = temp);
    found := false;
    for k: 0..cast(s64) n - 1 {
        elts[k] = cf_elt(c, cast(u64) k);
        oe := cf_elt(other, cast(u64) k);
        if !pm_undef(elts[k]) && pm_undef(oe) { elts[k] = const_undef(type_elem(t)); found = true; }
    }
    if found return cf_vector(t, elts);
    return c;
}

// Type::getExtendedType
ic_extended_type :: (t: Type_Id) -> Type_Id {
    return type_with_new_bit_width(t, type_int_width(scalar_type(t)) * 2);
}

// m_Shift(m_Value(A), m_Value(B)) (instructions only)
pm_shift :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
    if !is_inst(v) || !is_shift_op(inst_op(v)) return false, NONE, NONE;
    return true, op(v, 0), op(v, 1);
}
// m_Shr(m_Value(A), m_Value(B)) (instructions only)
pm_shr :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
    if !is_inst(v) || !is_shr_op(inst_op(v)) return false, NONE, NONE;
    return true, op(v, 0), op(v, 1);
}
// m_c_BinOp(m_OneUse(m_Value()), m_Value())
ic_some_operand_has_one_use :: (v: Value_Id) -> bool {
    return has_one_use(op(v, 0)) || has_one_use(op(v, 1));
}
// m_SpecificInt_ICMP(ULT, APInt(bw, n))
pm_int_ult :: (v: Value_Id, n: u64) -> bool {
    ult :: (a: APInt, b: APInt) -> bool { return ap_ult(a, b); }
    return pm_int_pred_arg(v, ult, ap_from_u64(scalar_bits(v), n));
}

// ---------------------------------------------------------------- dropRedundantMaskingOfLeftShiftInput

// MaskA: ((1 << MaskShAmt) - 1); MaskB: (~(-1 << MaskShAmt))
ic_match_mask_a_or_b :: (v: Value_Id) -> (bool, Value_Id) {
    ok, s, m1 := pm_binop(v, .ADD);
    if ok && pm_all_ones(m1) {
        oks, one, amt := pm_binop(s, .SHL);
        if oks && pm_one(one) return true, amt;
    }
    okn, x := pm_not(v);
    if okn {
        oks, ones, amt := pm_binop(x, .SHL);
        if oks && pm_all_ones(ones) return true, amt;
    }
    return false, NONE;
}
// MaskC: (-1 l>> MaskShAmt); MaskD: ((-1 << MaskShAmt) l>> MaskShAmt)
ic_match_mask_c_or_d :: (v: Value_Id) -> (bool, Value_Id) {
    ok, a, amt := pm_binop(v, .LSHR);
    if !ok return false, NONE;
    if pm_all_ones(a) return true, amt;
    oks, ones, amt2 := pm_binop(a, .SHL);
    if oks && pm_all_ones(ones) && amt == amt2 return true, amt2;
    return false, NONE;
}

ic_drop_redundant_masking_of_left_shift_input :: (outer: Value_Id, q: Simplify_Query) -> Value_Id {
    masked := op(outer, 0);
    shift_sh_amt := zext_or_self_i(op(outer, 1));
    okt, tsrc := pmi_cast(masked, .TRUNC);
    if okt {
        trunc := masked;
        masked = tsrc;
        if !has_one_use(trunc) return NONE;
    }
    narrowest_ty := vtype(outer);
    widest_ty := vtype(masked);
    had_trunc := widest_ty != narrowest_ty;
    if cast(u64) type_int_width(scalar_type(widest_ty)) * 2 > (1 << 23) return NONE;
    extended_ty := ic_extended_type(widest_ty);

    mask_sh_amt: Value_Id = NONE;
    x: Value_Id = NONE;
    new_mask: Value_Id = NONE;
    matched_ab := false;
    if ic_is_binop(masked, .AND) {
        for side: 0..1 {
            ok, amt := ic_match_mask_a_or_b(op(masked, cast(u32) side));
            if ok { mask_sh_amt = amt; x = op(masked, cast(u32) (1 - side)); matched_ab = true; break; }
        }
    }
    matched_cd := false;
    if !matched_ab {
        if ic_is_binop(masked, .AND) {
            for side: 0..1 {
                ok, amt := ic_match_mask_c_or_d(op(masked, cast(u32) side));
                if ok { mask_sh_amt = amt; x = op(masked, cast(u32) (1 - side)); matched_cd = true; break; }
            }
        }
        if !matched_cd {
            ok, s, amt := pm_shr(masked);
            if ok {
                oks, sx, samt := pm_binop(s, .SHL);
                if oks && samt == amt { x = sx; mask_sh_amt = samt; matched_cd = true; }
            }
        }
    }
    if matched_ab {
        mask_sh_amt = zext_or_self_i(mask_sh_amt);
        if !ic_can_try_to_constant_add_two_shift_amounts(outer, shift_sh_amt, masked, mask_sh_amt) return NONE;
        sum := simplify_add_inst(mask_sh_amt, shift_sh_amt, false, false, q);
        if sum == NONE || !is_const(sum) return NONE;
        sum = ic_replace_undefs_with(sum, const_int_of(scalar_type(vtype(sum)), cast(u64) type_int_width(scalar_type(extended_ty))));
        ext_sum := cfo_cast_operand(.ZEXT, sum, extended_ty);
        if ext_sum == NONE return NONE;
        ext_all_ones := cf_all_ones(extended_ty);
        ext_inv_mask := cfo_binary_op_operands(.SHL, ext_all_ones, ext_sum);
        if ext_inv_mask == NONE return NONE;
        new_mask = ce_not(ext_inv_mask);
    } else if matched_cd {
        mask_sh_amt = zext_or_self_i(mask_sh_amt);
        if !ic_can_try_to_constant_add_two_shift_amounts(outer, shift_sh_amt, masked, mask_sh_amt) return NONE;
        diff := simplify_sub_inst(shift_sh_amt, mask_sh_amt, false, false, q);
        if diff == NONE || !is_const(diff) return NONE;
        widest_bw := type_int_width(scalar_type(widest_ty));
        diff = ic_replace_undefs_with(diff, const_int_signed(scalar_type(vtype(diff)), -cast(s64) widest_bw));
        ext_nhb := cfo_cast_operand(.ZEXT, ce_binop(.SUB, const_int_of(vtype(diff), cast(u64) widest_bw), diff, 0), extended_ty);
        if ext_nhb == NONE return NONE;
        ext_all_ones := cf_all_ones(extended_ty);
        new_mask = cfo_binary_op_operands(.LSHR, ext_all_ones, ext_nhb);
        if new_mask == NONE return NONE;
    } else return NONE;

    new_mask = ce_cast(.TRUNC, new_mask, narrowest_ty);
    need_mask := !pm_all_ones(new_mask);
    if need_mask {
        if !has_one_use(masked) return NONE;
        if ic_is_binop(masked, .ASHR) return NONE;
    }
    if had_trunc x = icb_trunc(x, narrowest_ty);
    new_shift := create_binop(inst_op(outer), x, op(outer, 1));
    if !need_mask return new_shift;
    icb_insert(new_shift);
    return create_binop(.AND, new_shift, new_mask);
}

// ---------------------------------------------------------------- foldShiftOfShiftedBinOp

ic_fold_shift_of_shifted_bin_op :: (i: Value_Id) -> Value_Id {
    bin := op(i, 0);
    if !is_binary_operator(bin) return NONE;
    bo := inst_op(bin);
    if (!is_bitwise_logic_op(bo) && bo != .ADD && bo != .SUB) || !has_one_use(bin) return NONE;
    c1 := op(i, 1);
    if !is_const(c1) return NONE;
    shift_opc := inst_op(i);
    if (bo == .ADD || bo == .SUB) && shift_opc != .SHL return NONE;
    ty := vtype(i);
    x: Value_Id = NONE; c0: Value_Id = NONE;
    match_first_shift :: (v: Value_Id, w: Value_Id, shift_opc: Opcode, c1: Value_Id, ty: Type_Id) -> (bool, Value_Id, Value_Id) {
        size := type_int_width(scalar_type(ty));
        ok, x, c0 := pm_binop(v, shift_opc);
        if !ok || !is_const(c0) return false, NONE, NONE;
        if !(has_one_use(v) || pm_imm_constant(w)) return false, NONE, NONE;
        if !pm_int_ult(ce_binop(.ADD, c0, c1, 0), size) return false, NONE, NONE;
        return true, x, c0;
    }
    first_shift_is_op1 := false;
    y: Value_Id = NONE;
    ok, mx, mc0 := match_first_shift(op(bin, 0), op(bin, 1), shift_opc, c1, ty);
    if ok { x = mx; c0 = mc0; y = op(bin, 1); }
    else {
        ok, mx, mc0 = match_first_shift(op(bin, 1), op(bin, 0), shift_opc, c1, ty);
        if !ok return NONE;
        x = mx; c0 = mc0; y = op(bin, 0);
        first_shift_is_op1 = bo == .SUB;
    }
    shift_sum_c := ce_binop(.ADD, c0, c1, 0);
    ns1 := icb_binop(shift_opc, x, shift_sum_c);
    ns2 := icb_binop(shift_opc, y, c1);
    o1 := ifx first_shift_is_op1 then ns2 else ns1;
    o2 := ifx first_shift_is_op1 then ns1 else ns2;
    return create_binop(bo, o1, o2);
}

// ---------------------------------------------------------------- commonShiftTransforms

ic_common_shift_transforms :: (i: Value_Id) -> Value_Id {
    r := ic_fold_binop_with_phi_operands(i); if r != NONE return r;
    op0 := op(i, 0); op1 := op(i, 1);
    ty := vtype(i);
    opc := inst_op(i);

    // If the shift amount is a one-use `sext`, we can demote it to `zext`.
    oks, y := pmi_cast(op1, .SEXT);
    if oks && has_one_use(op1) {
        ne := icb_zext(y, ty, vname(op1));
        return create_binop(opc, op0, ne);
    }

    if ic_simplify_demanded_instruction_bits(i) return i;

    if is_const(op0) && ic_is_binop(op1, .SELECT) {
        r = ic_fold_op_into_select(i, op1); if r != NONE return r;
    }

    if pm_imm_constant(op1) {
        r = ic_fold_shift_by_constant(op0, op1, i); if r != NONE return r;
    }

    ns := ic_reassociate_shift_amts_of_two_same_direction_shifts(i, ic.sq);
    if ns != NONE return ns;

    // C shift (A add nuw C1) --> (C shift C1) shift A
    if is_const(op0) {
        oka, a, c1 := pm_nuw_add_like_i(op1);
        if oka && is_const(c1) {
            new_c := icb_binop(opc, op0, c1);
            nso := create_binop(opc, new_c, a);
            if opc == .SHL { set_nsw(nso, has_nsw(i)); set_nuw(nso, has_nuw(i)); }
            else set_exact(nso, is_exact(i));
            return nso;
        }
    }

    bw := type_int_width(scalar_type(ty));

    okac, ac := pm_apint(op0);
    if okac {
        // C << (X - AddC) --> (C >> AddC) << X ; C >> (X - AddC) --> (C << AddC) >> X
        oka, a, addcv := pm_binop(op1, .ADD);
        okc, add_c := pm_apint(addcv);
        if oka && okc && ap_sign_bit(add_c) && ap_ult_u64(ap_neg(add_c), bw) {
            pos := cast(u32) ap_zext_value(ap_neg(add_c));
            suitable := false;
            if opc == {
                case .SHL; suitable = (has_nsw(i) || has_nuw(i)) && ap_eq(ac, ap_shl(ap_lshr(ac, pos), pos));
                case .LSHR; suitable = is_exact(i) && ap_eq(ac, ap_lshr(ap_shl(ac, pos), pos));
                case .ASHR; suitable = is_exact(i) && ap_eq(ac, ap_ashr(ap_shl(ac, pos), pos));
            }
            if suitable {
                new_c := const_int_ap(ty, ifx opc == .SHL then ap_lshr(ac, pos) else ap_shl(ac, pos));
                nso := create_binop(opc, new_c, a);
                if opc == .SHL set_nuw(nso, has_nuw(i));
                else set_exact(nso);
                return nso;
            }
        }

        // C1 << (C2 - X) -> (C1 << C2) >> X ; C1 >> (C2 - X) -> (C1 >> C2) << X
        c2: u64 = 0; x: Value_Id = NONE;
        matched := false;
        oksub, sc2, sx := pm_ob(op1, .SUB, F_NUW);
        if oksub {
            okci, v := pm_constant_int_u64(sc2);
            if okci { c2 = v; x = sx; matched = true; }
        }
        if !matched {
            okx, xv, xc := pm_binop(op1, .XOR);
            if okx {
                okci, v := pm_constant_int_u64(xc);
                if okci {
                    kx := ic_known_bits(xv, i);
                    if ap_is_all_ones(ap_or(ap_from_u64(bw, v), kx.zero)) { c2 = v; x = xv; matched = true; }
                }
            }
        }
        if matched {
            if opc == .SHL {
                if cast(u64) ap_clz(ac) >= c2 return create_binop_flags(.LSHR, const_int_ap(ty, ap_shl(ac, cast(u32) c2)), x, F_EXACT);
                if cast(u64) ap_clo(ac) > c2 return create_binop_flags(.ASHR, const_int_ap(ty, ap_shl(ac, cast(u32) c2)), x, F_EXACT);
            } else if cast(u64) ap_ctz(ac) >= c2 {
                if !ap_sign_bit(ac) {
                    shl := create_binop_flags(.SHL, const_int_ap(ty, ap_lshr(ac, cast(u32) c2)), x, F_NUW);
                    set_nsw(shl);
                    return shl;
                }
                if opc == .LSHR return create_binop_flags(.SHL, const_int_ap(ty, ap_lshr(ac, cast(u32) c2)), x, F_NUW);
                return create_binop_flags(.SHL, const_int_ap(ty, ap_ashr(ac, cast(u32) c2)), x, F_NSW);
            }
        }
    }

    // X shift (A srem C) -> X shift (A and (C - 1)) iff C is a power of 2.
    if has_one_use(op1) {
        ok, a, c := pm_binop(op1, .SREM);
        if ok && is_const(c) && pm_power2(c) {
            mask := ce_binop(.SUB, c, const_int_of(ty, 1), 0);
            rem := icb_and(a, mask, vname(op1));
            return ic_replace_operand(i, 1, rem);
        }
    }

    r = ic_fold_shift_of_shifted_bin_op(i); if r != NONE return r;

    {
        ok, _, m := pm_binop(op1, .OR);
        if ok && pm_specific_int(m, cast(u64) bw - 1) return ic_replace_operand(i, 1, const_int_of(ty, cast(u64) bw - 1));
    }

    if (opc == .LSHR || opc == .ASHR) && is_inst(op0) && has_one_use(op0) {
        iid := call_iid(op0);
        if (iid == IID_SCMP || iid == IID_UCMP) && pm_specific_int(op1, cast(u64) bw - 1) {
            lt := ifx iid == IID_SCMP then cast(u8) ICMP_SLT else ICMP_ULT;
            cmp := icb_cmp(lt, op(op0, 0), op(op0, 1));
            return create_cast(ifx opc == .LSHR then Opcode.ZEXT else .SEXT, cmp, ty);
        }
    }
    return NONE;
}

// ---------------------------------------------------------------- FoldShiftByConstant

// canShiftBinOpWithConstantRHS
ic_can_shift_bin_op_with_constant_rhs :: (shift: Value_Id, bo: Value_Id) -> bool {
    if inst_op(bo) == {
        case .ADD; return inst_op(shift) == .SHL;
        case .OR; #through;
        case .AND; return true;
        case .XOR;
            logical := inst_op(shift) == .SHL || inst_op(shift) == .LSHR;
            okn, _ := pm_not(bo);
            return !(logical && okn);
    }
    return false;
}

ic_fold_shift_by_constant :: (op0: Value_Id, c1: Value_Id, i: Value_Id) -> Value_Id {
    opc := inst_op(i);
    is_left_shift := opc == .SHL;
    {
        ok, c2, x := pm_binop(op0, opc);
        if ok && pm_imm_constant(c2) {
            r := create_binop(opc, icb_binop(opc, c2, c1), x);
            if is_left_shift {
                set_nuw(r, has_nuw(i) && has_nuw(op0));
                set_nsw(r, has_nsw(i) && has_nsw(op0));
            } else set_exact(r, is_exact(i) && is_exact(op0));
            return r;
        }
    }
    ty := vtype(i);
    type_bits := type_int_width(scalar_type(ty));

    // (X / +DivC) >> (Width - 1) --> ext (X <= -DivC)
    if !is_left_shift && pm_specific_int_allow_poison(c1, cast(u64) type_bits - 1) {
        ok, x, dv := pm_binop(op0, .SDIV);
        okd, div_c := pm_apint(dv);
        if ok && okd && !ap_is_zero(div_c) && !ap_is_min_signed(div_c) {
            neg_div_c := const_int_ap(ty, ap_neg(div_c));
            pred := ifx ap_sign_bit(div_c) then cast(u8) ICMP_SGE else ICMP_SLE;
            cmp := icb_cmp(pred, x, neg_div_c);
            return create_cast(ifx opc == .ASHR then Opcode.SEXT else .ZEXT, cmp, ty);
        }
    }

    okc, op1c := pm_apint(c1);
    if !okc return NONE;

    if opc != .ASHR {
        sem := ifx is_left_shift then Shift_Semantics.LOSSY else .UNSIGNED;
        amt := cast(u32) ap_zext_value(op1c);
        if ic_can_evaluate_shifted(op0, amt, is_left_shift, sem, i)
            return ic_replace_inst_uses_with(i, ic_get_shifted_value(op0, amt, is_left_shift, sem));
    }

    r := ic_fold_binop_into_select_or_phi(i); if r != NONE return r;

    if !has_one_use(op0) return NONE;

    if is_binary_operator(op0) {
        ok0, _ := pm_apint(op(op0, 1));
        if ok0 && ic_can_shift_bin_op_with_constant_rhs(i, op0) {
            new_rhs := icb_binop(opc, op(op0, 1), c1);
            new_shift := icb_binop(opc, op(op0, 0), c1);
            ic_take_name(new_shift, op0);
            return create_binop(inst_op(op0), new_shift, new_rhs);
        }
    }

    {
        oks, cond, tbo, fv := pm_select(op0);
        if oks && is_binary_operator(tbo) && has_one_use(tbo) {
            okc2, _ := pm_apint(op(tbo, 1));
            if !is_const(fv) && op(tbo, 0) == fv && okc2 && ic_can_shift_bin_op_with_constant_rhs(i, tbo) {
                new_rhs := icb_binop(opc, op(tbo, 1), c1);
                new_shift := icb_binop(opc, fv, c1);
                new_op := icb_binop(inst_op(tbo), new_shift, new_rhs);
                return create_select(cond, new_op, new_shift);
            }
        }
    }
    {
        oks, cond, tv, fbo := pm_select(op0);
        if oks && is_binary_operator(fbo) && has_one_use(fbo) {
            okc2, _ := pm_apint(op(fbo, 1));
            if !is_const(tv) && op(fbo, 0) == tv && okc2 && ic_can_shift_bin_op_with_constant_rhs(i, fbo) {
                new_rhs := icb_binop(opc, op(fbo, 1), c1);
                new_shift := icb_binop(opc, tv, c1);
                new_op := icb_binop(inst_op(fbo), new_shift, new_rhs);
                return create_select(cond, new_shift, new_op);
            }
        }
    }
    return NONE;
}

// ---------------------------------------------------------------- foldLShrOverflowBit

ic_fold_lshr_overflow_bit :: (i: Value_Id) -> Value_Id {
    add := op(i, 0); shift_amt := op(i, 1);
    ty := vtype(i);
    if type_int_width(scalar_type(ty)) < 3 return NONE;
    okc, sh := pm_apint(shift_amt);
    if !okc return NONE;
    oka, za, zb := pm_binop(add, .ADD);
    if !oka return NONE;
    okx, x := pmi_cast(za, .ZEXT);
    oky, y := pmi_cast(zb, .ZEXT);
    if !okx || !has_one_use(za) || !oky || !has_one_use(zb) return NONE;
    sh_amt := ap_zext_value(sh);
    if sh_amt == 1 return NONE;
    if cast(u64) scalar_bits(x) != sh_amt || cast(u64) scalar_bits(y) != sh_amt return NONE;
    if !has_one_use(add) {
        u := ir.v_first_use[add];
        while u != NONE {
            usr := ir.u_user[u];
            u = ir.u_next[u];
            if usr == i continue;
            if !(is_inst(usr) && inst_op(usr) == .TRUNC) || cast(u64) scalar_bits(usr) > sh_amt return NONE;
        }
    }
    icb_set_insert_point(add);
    narrow_add := icb_add(x, y, "add.narrowed");
    overflow := icb_cmp(ICMP_ULT, narrow_add, x, "add.narrowed.overflow");
    if !has_one_use(add) {
        ic_replace_inst_uses_with(add, icb_zext(narrow_add, ty));
        ic_erase_inst(add);
    }
    return create_cast(.ZEXT, overflow, ty);
}

// setShiftFlags (InstCombineShifts.cpp)
ic_set_shift_flags :: (i: Value_Id, q: Simplify_Query) -> bool {
    if inst_op(i) == .SHL {
        if has_nuw(i) && has_nsw(i) return false;
    } else {
        if is_exact(i) return false;
        oks, x, y := pm_binop(op(i, 0), .SHL);
        if oks && y == op(i, 1) { set_exact(i); return true; }
        okc, cx, cz := pm_intrinsic2(op(i, 1), IID_CTTZ);
        if okc && cx == op(i, 0) { set_exact(i); return true; }
    }
    kc := known_bits(op(i, 1), q);
    bw := kb_bits(kc);
    max_cnt := ap_limited(kb_max_value(kc), bw - 1);
    ka := known_bits(op(i, 0), q);
    changed := false;
    if inst_op(i) == .SHL {
        if !has_nuw(i) && max_cnt <= kb_count_min_leading_zeros(ka) { set_nuw(i); changed = true; }
        if !has_nsw(i) {
            if max_cnt < kb_count_min_sign_bits(ka) || max_cnt < num_sign_bits_ctx(op(i, 0), q.cxt, q.dt, q.ac) { set_nsw(i); changed = true; }
        }
        return changed;
    }
    changed = max_cnt <= kb_count_min_trailing_zeros(ka);
    set_exact(i, changed);
    return changed;
}


// ---------------------------------------------------------------- visitShl

ic_visit_shl :: (i: Value_Id) -> Value_Id {
    q := ic_q(i);
    v := simplify_shl_inst(op(i, 0), op(i, 1), has_nsw(i), has_nuw(i), q);
    if v != NONE return ic_replace_inst_uses_with(i, v);
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_common_shift_transforms(i); if r != NONE return r;
    r = ic_drop_redundant_masking_of_left_shift_input(i, q); if r != NONE return r;

    op0 := op(i, 0); op1 := op(i, 1);
    ty := vtype(i);
    bw := type_int_width(scalar_type(ty));

    okc, c := pm_apint(op1);
    if okc {
        sh_amt_c := cast(u32) ap_zext_value(c);

        // shl (zext X), C --> zext (shl X, C)
        okz, x := pmi_cast(op0, .ZEXT);
        if okz && has_one_use(op0) {
            src_w := scalar_bits(x);
            if sh_amt_c < src_w && ic_masked_value_is_zero(x, ap_high_bits_set(src_w, sh_amt_c), i)
                return create_cast(.ZEXT, icb_shl_c(x, sh_amt_c), ty);
        }

        // (X >> C) << C --> X & (-1 << C)
        {
            ok, sx, samt := pm_shr(op0);
            if ok && samt == op1 return create_binop(.AND, sx, const_int_ap(ty, ap_high_bits_set(bw, bw - sh_amt_c)));
        }

        {
            ok, sx, sc := pm_shr(op0);
            okc1, c1 := pm_apint(sc);
            if ok && is_exact(op0) && okc1 && ap_ult_u64(c1, bw) {
                shr_amt := cast(u32) ap_zext_value(c1);
                if shr_amt < sh_amt_c {
                    nshl := create_binop(.SHL, sx, const_int_of(ty, cast(u64) (sh_amt_c - shr_amt)));
                    set_nuw(nshl, has_nuw(i) || (shr_amt != 0 && inst_op(op0) == .LSHR && has_nsw(i)));
                    set_nsw(nshl, has_nsw(i));
                    return nshl;
                }
                if shr_amt > sh_amt_c {
                    nshr := create_binop(inst_op(op0), sx, const_int_of(ty, cast(u64) (shr_amt - sh_amt_c)));
                    set_exact(nshr, true);
                    return nshr;
                }
            }
        }

        if has_one_use(op0) {
            ok, sx, sc := pm_shr(op0);
            okc1, c1 := pm_apint(sc);
            if ok && okc1 && ap_ult_u64(c1, bw) {
                shr_amt := cast(u32) ap_zext_value(c1);
                if shr_amt < sh_amt_c {
                    nshl := create_binop(.SHL, sx, const_int_of(ty, cast(u64) (sh_amt_c - shr_amt)));
                    set_nuw(nshl, has_nuw(i) || (shr_amt != 0 && inst_op(op0) == .LSHR && has_nsw(i)));
                    set_nsw(nshl, has_nsw(i));
                    icb_insert(nshl);
                    return create_binop(.AND, nshl, const_int_ap(ty, ap_high_bits_set(bw, bw - sh_amt_c)));
                }
                if shr_amt > sh_amt_c {
                    nshr := create_binop(inst_op(op0), sx, const_int_of(ty, cast(u64) (shr_amt - sh_amt_c)));
                    set_exact(nshr, is_exact(op0));
                    icb_insert(nshr);
                    return create_binop(.AND, nshr, const_int_ap(ty, ap_high_bits_set(bw, bw - sh_amt_c)));
                }
            }
        }

        // Similar to above, but look through an intermediate trunc instruction.
        {
            okt, shr := pmi_cast(op0, .TRUNC);
            if okt && has_one_use(op0) && is_binary_operator(shr) && has_one_use(shr) {
                ok, sx, sc := pm_shr(shr);
                okc1, c1 := pm_apint(sc);
                if ok && okc1 {
                    shr_amt_c := cast(u32) ap_zext_value(c1);
                    sh_diff := ifx shr_amt_c > sh_amt_c then shr_amt_c - sh_amt_c else sh_amt_c - shr_amt_c;
                    sh_diff_c := const_int_of(vtype(sx), cast(u64) sh_diff);
                    shift_opc := ifx shr_amt_c > sh_amt_c then inst_op(shr) else .SHL;
                    new_shift := icb_binop(shift_opc, sx, sh_diff_c, "sh.diff");
                    tr := icb_trunc(new_shift, ty, "tr.sh.diff");
                    return create_binop(.AND, tr, const_int_ap(ty, ap_high_bits_set(bw, bw - sh_amt_c)));
                }
            }
        }

        // reorder binops and shifts
        if is_binary_operator(op0) && has_one_use(op0) {
            bop := inst_op(op0);
            if bop == .ADD || bop == .AND || bop == .OR || bop == .XOR || bop == .SUB {
                shr := op(op0, 0);
                yy := op(op0, 1);
                if is_commutative_op(bop) && has_one_use(yy) {
                    swap := false;
                    oky, _, ya := pm_shr(yy);
                    if oky && ya == op1 swap = true;
                    else {
                        oka, ay, acc := pm_binop(yy, .AND);
                        if oka {
                            oks2, _, sa2 := pm_shr(ay);
                            okcc, _ := pm_apint(acc);
                            if oks2 && sa2 == op1 && has_one_use(ay) && okcc swap = true;
                        }
                    }
                    if swap { tmp := shr; shr = yy; yy = tmp; }
                }
                {
                    ok, sx, sa := pm_shr(shr);
                    if ok && sa == op1 && has_one_use(shr) {
                        ys := icb_shl(yy, op1, vname(op0));
                        b := icb_binop(bop, sx, ys, vname(shr));
                        op1_val := cast(u32) ap_limited(c, bw);
                        return create_binop(.AND, b, const_int_ap(ty, ap_high_bits_set(bw, bw - op1_val)));
                    }
                }
                {
                    oka, ash, acc := pm_binop(shr, .AND);
                    if oka && has_one_use(shr) {
                        ok, sx, sa := pm_shr(ash);
                        okcc, cc := pm_apint(acc);
                        if ok && sa == op1 && has_one_use(ash) && okcc {
                            ys := icb_shl(yy, op1, vname(op0));
                            m := icb_and(sx, const_int_ap(ty, ap_shl(cc, sh_amt_c)), tprint("%.mask", vname(sx)));
                            new_op := create_binop(bop, m, ys);
                            if bop == .OR && (inst(op0).flags & F_EXACT) != 0 set_flag(new_op, F_EXACT, true);
                            return new_op;
                        }
                    }
                }
            }
        }

        // (C1 - X) << C --> (C1 << C) - (X << C)
        {
            ok, sc1, sx := pm_binop(op0, .SUB);
            okc1, c1 := pm_apint(sc1);
            if ok && has_one_use(op0) && okc1 {
                new_lhs := const_int_ap(ty, ap_shl(c1, sh_amt_c));
                new_shift := icb_shl(sx, op1);
                return create_binop(.SUB, new_lhs, new_shift);
            }
        }
    }

    if ic_set_shift_flags(i, q) return i;

    // (x >> y) << y  -->  x & (-1 << y)
    {
        ok, x, sa := pm_shr(op0);
        if ok && sa == op1 && has_one_use(op0) {
            mask := icb_shl(cf_all_ones(ty), op1);
            return create_binop(.AND, mask, x);
        }
    }
    // (-1 >> y) << y  -->  -1 << y
    {
        ok, a, sa := pm_binop(op0, .LSHR);
        if ok && pm_all_ones(a) && sa == op1 return create_binop(.SHL, cf_all_ones(ty), op1);
    }

    if pm_imm_constant(op1) {
        c1 := op1;
        // (X * C2) << C1 --> X * (C2 << C1)
        ok, x, c2 := pm_binop(op0, .MUL);
        if ok && pm_imm_constant(c2) return create_binop(.MUL, x, icb_shl(c2, c1));
        // shl (zext i1 X), C1 --> select (X, 1 << C1, 0)
        okz, zx := pmi_cast(op0, .ZEXT);
        if okz && is_int_or_int_vector_n(vtype(zx), 1) {
            new_c := icb_shl(const_int_of(ty, 1), c1);
            return ic_create_select_unknown_profile(zx, new_c, const_null_value(ty));
        }
    }

    if pm_one(op0) {
        // (1 << (C - x)) -> ((1 << C) >> x) if C is bitwidth - 1
        ok, sc, x := pm_binop(op1, .SUB);
        if ok && pm_specific_int(sc, cast(u64) bw - 1) return create_binop(.LSHR, const_int_ap(ty, ap_one_bit_set(bw, bw - 1)), x);
        // 1 << (cttz X) --> -X & X
        okt, tx, _ := pm_intrinsic2(op1, IID_CTTZ);
        if okt && has_one_use(op1) {
            neg_x := icb_neg(tx, "neg");
            return create_binop(.AND, neg_x, tx);
        }
    }
    return NONE;
}

// ---------------------------------------------------------------- visitLShr

ic_visit_lshr :: (i: Value_Id) -> Value_Id {
    v := simplify_lshr_inst(op(i, 0), op(i, 1), is_exact(i), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_common_shift_transforms(i); if r != NONE return r;

    op0 := op(i, 0); op1 := op(i, 1);
    ty := vtype(i);
    bw := type_int_width(scalar_type(ty));

    // lshr 1, X --> zext (X == 0)
    if pm_one(op0) return create_cast(.ZEXT, icb_is_null(op1), ty);

    // (iN (~X) u>> (N - 1)) --> zext (X > -1)
    {
        okn, x := pm_not(op0);
        if okn && has_one_use(op0) && pm_specific_int_allow_poison(op1, cast(u64) bw - 1)
            return create_cast(.ZEXT, icb_cmp(ICMP_SGT, x, cf_all_ones(vtype(x)), "isnotneg"), ty);
    }

    // ((X << nuw Z) sub nuw Y) >>u exact Z --> X sub nuw (Y >>u exact Z)
    if is_exact(i) && has_one_use(op0) {
        ok, s, y := pm_ob(op0, .SUB, F_NUW);
        if ok {
            okl, x, z := pm_ob(s, .SHL, F_NUW);
            if okl && z == op1 {
                nl := icb_lshr(y, op1, "", true);
                ns := create_binop_flags(.SUB, x, nl, F_NUW);
                set_nsw(ns, has_nsw(op0));
                return ns;
            }
        }
    }

    // (X + Y) / 2 --> (X & Y) iff (X u<= 1) && (Y u<= 1)
    {
        ok, x, y := pm_binop(op0, .ADD);
        if ok && pm_one(op1) && kb_count_max_active_bits(ic_known_bits(x, i)) <= 1 && kb_count_max_active_bits(ic_known_bits(y, i)) <= 1
            return create_binop(.AND, x, y);
    }

    // (sub nuw X, (Y << nuw Z)) >>u exact Z --> (X >>u exact Z) sub nuw Y
    if is_exact(i) && has_one_use(op0) {
        ok, x, s := pm_ob(op0, .SUB, F_NUW);
        if ok {
            okl, y, z := pm_ob(s, .SHL, F_NUW);
            if okl && z == op1 {
                nl := icb_lshr(x, op1, "", true);
                ns := create_binop_flags(.SUB, nl, y, F_NUW);
                set_nsw(ns, has_nsw(op0));
                return ns;
            }
        }
    }

    // ((X << nuw Z) binop nuw Y) >>u Z --> X binop nuw (Y >>u Z)
    if is_binary_operator(op0) && has_one_use(op0) {
        x: Value_Id = NONE; y: Value_Id = NONE;
        for side: 0..1 {
            okl, sx, z := pm_ob(op(op0, cast(u32) side), .SHL, F_NUW);
            if okl && z == op1 { x = sx; y = op(op0, cast(u32) (1 - side)); break; }
        }
        if x != NONE {
            bop := inst_op(op0);
            if bop == .ADD || bop == .AND || bop == .OR || bop == .XOR {
                is_obo := bop == .ADD;
                if !is_obo || has_nuw(op0) {
                    nl := icb_lshr(y, op1, "", is_exact(i) && bop != .AND);
                    nb := create_binop(bop, nl, x);
                    if is_obo { set_nuw(nb, true); set_nsw(nb, has_nsw(op0)); }
                    else if bop == .OR set_flag(nb, F_EXACT, (inst(op0).flags & F_EXACT) != 0);
                    return nb;
                }
            }
        }
    }

    okc, c := pm_apint(op1);
    if okc {
        sh_amt_c := cast(u32) ap_zext_value(c);
        iid := call_iid(op0);
        if is_inst(op0) && (bw & (bw - 1)) == 0 && log2_u32(bw) == sh_amt_c && (iid == IID_CTLZ || iid == IID_CTTZ || iid == IID_CTPOP) {
            is_pop := iid == IID_CTPOP;
            rhs := const_int_signed(ty, ifx is_pop then -1 else 0);
            cmp := icb_cmp(ICMP_EQ, op(op0, 0), rhs);
            return create_cast(.ZEXT, cmp, ty);
        }

        {
            ok, x, sc := pm_binop(op0, .SHL);
            okc1, c1 := pm_apint(sc);
            if ok && okc1 && ap_ult_u64(c1, bw) {
                if ap_ult_u64(c1, sh_amt_c) {
                    shl_amt_c := cast(u32) ap_zext_value(c1);
                    diff := const_int_of(ty, cast(u64) (sh_amt_c - shl_amt_c));
                    if has_nuw(op0) {
                        nl := create_binop(.LSHR, x, diff);
                        set_exact(nl, is_exact(i));
                        return nl;
                    }
                    if has_one_use(op0) {
                        nl := icb_lshr(x, diff, "", is_exact(i));
                        return create_binop(.AND, nl, const_int_ap(ty, ap_low_bits_set(bw, bw - sh_amt_c)));
                    }
                } else if ap_ugt_u64(c1, sh_amt_c) {
                    shl_amt_c := cast(u32) ap_zext_value(c1);
                    diff := const_int_of(ty, cast(u64) (shl_amt_c - sh_amt_c));
                    if has_nuw(op0) {
                        ns := create_binop(.SHL, x, diff);
                        set_nuw(ns, true);
                        set_nsw(ns, sh_amt_c > 0);
                        return ns;
                    }
                    if has_one_use(op0) {
                        ns := icb_shl(x, diff);
                        return create_binop(.AND, ns, const_int_ap(ty, ap_low_bits_set(bw, bw - sh_amt_c)));
                    }
                } else {
                    return create_binop(.AND, x, const_int_ap(ty, ap_low_bits_set(bw, bw - sh_amt_c)));
                }
            }
        }

        // ((X << C) + Y) >>u C --> (X + (Y >>u C)) & (-1 >>u C)
        if ic_is_binop(op0, .ADD) && has_one_use(op0) {
            x: Value_Id = NONE; y: Value_Id = NONE;
            for side: 0..1 {
                s := op(op0, cast(u32) side);
                ok, sx, sa := pm_binop(s, .SHL);
                if ok && has_one_use(s) && sa == op1 { x = sx; y = op(op0, cast(u32) (1 - side)); break; }
            }
            if x != NONE {
                nl := icb_lshr(y, op1);
                na := icb_add(nl, x);
                op1_val := cast(u32) ap_limited(c, bw);
                return create_binop(.AND, na, const_int_ap(ty, ap_low_bits_set(bw, bw - op1_val)));
            }
        }

        {
            okz, x := pmi_cast(op0, .ZEXT);
            if okz && has_one_use(op0) && (!is_int_type(ty) || ic_should_change_type(ty, vtype(x))) {
                nl := icb_lshr(x, const_int_of(vtype(x), cast(u64) sh_amt_c));
                return create_cast(.ZEXT, nl, ty);
            }
        }

        {
            oks, x := pmi_cast(op0, .SEXT);
            if oks {
                src_bw := scalar_bits(x);
                if src_bw == 1 {
                    new_c := const_int_ap(ty, ap_low_bits_set(bw, bw - sh_amt_c));
                    return create_select(x, new_c, const_null_value(ty));
                }
                if (!is_int_type(ty) || ic_should_change_type(ty, vtype(x))) && has_one_use(op0) {
                    if sh_amt_c == bw - 1 {
                        nl := icb_lshr(x, const_int_of(vtype(x), cast(u64) (src_bw - 1)));
                        return create_cast(.ZEXT, nl, ty);
                    }
                    if sh_amt_c == bw - src_bw {
                        new_sh := min(sh_amt_c, src_bw - 1);
                        ash := icb_ashr(x, const_int_of(vtype(x), cast(u64) new_sh));
                        return create_cast(.ZEXT, ash, ty);
                    }
                }
            }
        }

        if sh_amt_c == bw - 1 {
            // lshr i32 or(X,-X), 31 --> zext (X != 0)
            if ic_is_binop(op0, .OR) && has_one_use(op0) {
                for side: 0..1 {
                    okn, x := pm_neg(op(op0, cast(u32) side));
                    if okn && op(op0, cast(u32) (1 - side)) == x return create_cast(.ZEXT, icb_is_not_null(x), ty);
                }
            }
            // lshr i32 (X -nsw Y), 31 --> zext (X < Y)
            {
                ok, x, y := pm_ob(op0, .SUB, F_NSW);
                if ok && has_one_use(op0) return create_cast(.ZEXT, icb_cmp(ICMP_SLT, x, y), ty);
            }
            // lshr i32 (srem X, 2), 31 --> and (X >> 31), X
            {
                ok, x, two := pm_binop(op0, .SREM);
                if ok && has_one_use(op0) && pm_specific_int(two, 2) {
                    sb := icb_lshr(x, const_int_of(vtype(x), cast(u64) sh_amt_c));
                    return create_binop(.AND, sb, x);
                }
            }
            // lshr iN (X - 1) & ~X, N-1 --> zext (X == 0)
            if ic_is_binop(op0, .AND) && has_one_use(op0) {
                x := ic_match_dec_and_not(op0);
                if x != NONE return create_cast(.ZEXT, icb_is_null(x), ty);
            }
        }

        {
            okt, trunc_src := pmi_cast(op0, .TRUNC);
            if okt && has_one_use(op0) && is_inst(trunc_src) {
                ok, x, sc := pm_binop(trunc_src, .LSHR);
                okc1, c1 := pm_apint(sc);
                if ok && okc1 {
                    src_w := scalar_bits(x);
                    amt_sum := cast(u64) sh_amt_c + ap_zext_value(c1);
                    if amt_sum < cast(u64) src_w && (has_one_use(trunc_src) || ap_uge_u64(c1, cast(u64) (src_w - bw))) {
                        sum_shift := icb_lshr(x, const_int_of(vtype(x), amt_sum), "sum.shift");
                        tr := icb_trunc(sum_shift, ty, vname(i));
                        mask_c := ap_lshr(ap_all_ones(bw), sh_amt_c);
                        return create_binop(.AND, tr, const_int_ap(ty, mask_c));
                    }
                }
            }
        }

        {
            okm, x, mcv := pm_ob(op0, .MUL, F_NUW);
            okmc, mul_c := pm_apint(mcv);
            if okm && okmc {
                if bw > 2 && ap_is_power_of_2(ap_sub_u64(mul_c, 1)) && ap_log2(mul_c) == sh_amt_c {
                    if sh_amt_c * 2 == bw return ic_replace_inst_uses_with(i, x);
                    if has_one_use(op0) {
                        na := create_binop_flags(.ADD, x, icb_lshr(x, const_int_of(ty, cast(u64) sh_amt_c), "", is_exact(i)), F_NUW);
                        set_nsw(na, has_nsw(op0));
                        return na;
                    }
                }
                if has_one_use(op0) {
                    new_mul_c := ap_lshr(mul_c, sh_amt_c);
                    if ap_eq(mul_c, ap_shl(new_mul_c, sh_amt_c)) {
                        nm := create_binop_flags(.MUL, x, const_int_ap(ty, new_mul_c), F_NUW);
                        set_nsw(nm, true);
                        return nm;
                    }
                }
            }
        }

        {
            okm, x, mcv := pm_ob(op0, .MUL, F_NSW);
            okmc, mul_c := pm_apint(mcv);
            if okm && has_one_use(op0) && okmc {
                if bw > 2 && ap_is_power_of_2(ap_sub_u64(mul_c, 1)) && ap_log2(mul_c) == sh_amt_c
                    return create_binop_flags(.ADD, x, icb_lshr(x, const_int_of(ty, cast(u64) sh_amt_c), "", is_exact(i)), F_NSW);
            }
        }

        // Try to narrow bswap.
        {
            okb, bz := pm_intrinsic1(op0, IID_BSWAP);
            if okb && has_one_use(op0) {
                okz, x := pmi_cast(bz, .ZEXT);
                if okz && has_one_use(bz) {
                    src_w := scalar_bits(x);
                    width_diff := bw - src_w;
                    if src_w % 16 == 0 {
                        narrow_swap := icb_unary_intrinsic(IID_BSWAP, x);
                        if sh_amt_c >= width_diff {
                            new_shift := icb_lshr(narrow_swap, const_int_of(vtype(narrow_swap), cast(u64) (sh_amt_c - width_diff)));
                            return create_cast(.ZEXT, new_shift, ty);
                        } else {
                            new_zext := icb_zext(narrow_swap, ty);
                            return create_binop(.SHL, new_zext, const_int_of(ty, cast(u64) (width_diff - sh_amt_c)));
                        }
                    }
                }
            }
        }

        // ((zext BoolX) + (zext BoolY)) >> 1 --> zext (BoolX && BoolY)
        if sh_amt_c == 1 {
            ok, x, y := pm_binop(op0, .ADD);
            if ok {
                okx, bx := pmi_cast(x, .ZEXT);
                oky, by := pmi_cast(y, .ZEXT);
                if okx && oky && is_int_or_int_vector_n(vtype(bx), 1) && is_int_or_int_vector_n(vtype(by), 1) &&
                   (has_one_use(x) || has_one_use(y) || has_one_use(op0)) {
                    a := icb_and(bx, by);
                    return create_cast(.ZEXT, a, ty);
                }
            }
        }
    }

    q := ic_q(i);
    if ic_set_shift_flags(i, q) return i;

    // (x << y) >> y  -->  x & (-1 >> y)
    {
        ok, x, sa := pm_binop(op0, .SHL);
        if ok && sa == op1 && has_one_use(op0) {
            mask := icb_lshr(cf_all_ones(ty), op1);
            return create_binop(.AND, mask, x);
        }
    }
    // (-1 << y) >> y  -->  -1 >> y
    {
        ok, a, sa := pm_binop(op0, .SHL);
        if ok && pm_all_ones(a) && sa == op1 return create_binop(.LSHR, cf_all_ones(ty), op1);
    }

    r = ic_fold_lshr_overflow_bit(i); if r != NONE return r;

    // ((pow2 << x) >> cttz(pow2 << y)) -> ((1 << x) >> y)
    {
        ok0, shl0_op0, shl0_op1 := pm_binop(op0, .SHL);
        okt, shl1, _ := pm_intrinsic2(op1, IID_CTTZ);
        if ok0 && okt && is_binary_operator(shl1) {
            ok1, s1o0, shl1_op1 := pm_binop(shl1, .SHL);
            if ok1 && s1o0 == shl0_op0 && ic_is_known_to_be_power_of_two(shl0_op0, true, i) {
                has_nuw_ := has_nuw(op0) && has_nuw(shl1);
                has_nsw_ := has_nsw(op0) && has_nsw(shl1);
                if has_nuw_ || has_nsw_ {
                    nshl := icb_shl(const_int_of(vtype(shl1), 1), shl0_op1, "", has_nuw_, has_nsw_);
                    return create_binop(.LSHR, nshl, shl1_op1);
                }
            }
        }
    }
    return NONE;
}

// m_c_And(m_Add(m_Value(X), m_AllOnes()), m_Not(m_Deferred(X))) on an `and`: X or NONE
ic_match_dec_and_not :: (a: Value_Id) -> Value_Id {
    for side: 0..1 {
        ok, x, m1 := pm_binop(op(a, cast(u32) side), .ADD);
        if !ok || !pm_all_ones(m1) continue;
        okn, nx := pm_not(op(a, cast(u32) (1 - side)));
        if okn && nx == x return x;
    }
    return NONE;
}


// ---------------------------------------------------------------- foldVariableSignZeroExtensionOfVariableHighBitExtract

ic_fold_variable_sign_zero_extension_of_variable_high_bit_extract :: (old: Value_Id) -> Value_Id {
    bit_width_splat :: (c: Value_Id, v: Value_Id) -> bool { return pm_specific_int_allow_poison(c, cast(u64) scalar_bits(v)); }
    // m_Sub(m_Constant(C), m_ZExtOrSelf(X)) under an optional zext: (ok, C, X)
    match_sub_c :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
        s := zext_or_self_i(v);
        ok, c, x := pm_binop(s, .SUB);
        if !ok || !is_const(c) return false, NONE, NONE;
        return true, c, zext_or_self_i(x);
    }
    ok, shl, amt2 := pm_binop(old, .ASHR);
    if !ok return NONE;
    oks, maybe_trunc, amt1 := pm_binop(shl, .SHL);
    if !oks || !is_inst(maybe_trunc) return NONE;
    ok1, c1, nbits := match_sub_c(amt1);
    if !ok1 return NONE;
    ok2, c2, nbits2 := match_sub_c(amt2);
    if !ok2 || nbits2 != nbits return NONE;
    if !bit_width_splat(c1, old) || !bit_width_splat(c2, old) return NONE;

    high_bit_extract := maybe_trunc;
    okt, ts := pmi_cast(maybe_trunc, .TRUNC);
    if okt {
        if !is_inst(ts) return NONE;   // m_TruncOrSelf(m_Instruction): a trunc of a non-instruction doesn't match
        high_bit_extract = ts;
    }
    had_trunc := maybe_trunc != high_bit_extract;

    okr, x, num_low_bits_to_skip := pm_shr(high_bit_extract);
    if !okr return NONE;
    ok0, c0, nb0 := match_sub_c(num_low_bits_to_skip);
    if !ok0 || nb0 != nbits || !bit_width_splat(c0, high_bit_extract) return NONE;

    if inst_op(high_bit_extract) == inst_op(old) return ic_replace_inst_uses_with(old, maybe_trunc);
    if had_trunc && !ic_some_operand_has_one_use(old) return NONE;

    new_ashr := create_binop(inst_op(old), x, num_low_bits_to_skip);
    copy_ir_flags(new_ashr, high_bit_extract);
    if !had_trunc return new_ashr;
    icb_insert(new_ashr);
    if scalar_bits(new_ashr) == scalar_bits(old) && vtype(new_ashr) == vtype(old) return create_cast(.BITCAST, new_ashr, vtype(old));
    return create_cast(.TRUNC, new_ashr, vtype(old));
}

// ---------------------------------------------------------------- visitAShr

ic_visit_ashr :: (i: Value_Id) -> Value_Id {
    v := simplify_ashr_inst(op(i, 0), op(i, 1), is_exact(i), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_common_shift_transforms(i); if r != NONE return r;

    op0 := op(i, 0); op1 := op(i, 1);
    ty := vtype(i);
    bw := type_int_width(scalar_type(ty));
    okc, sh_ap := pm_apint(op1);
    if okc && ap_ult_u64(sh_ap, bw) {
        sh_amt := cast(u32) ap_zext_value(sh_ap);

        // ashr (shl (zext X), C), C --> sext X
        {
            ok, z, sa := pm_binop(op0, .SHL);
            if ok && sa == op1 {
                okz, x := pmi_cast(z, .ZEXT);
                if okz && sh_amt == bw - scalar_bits(x) return create_cast(.SEXT, x, ty);
            }
        }

        {
            ok, x, sc := pm_ob(op0, .SHL, F_NSW);
            okc1, sh_op1 := pm_apint(sc);
            if ok && okc1 && ap_ult_u64(sh_op1, bw) {
                shl_amt := cast(u32) ap_zext_value(sh_op1);
                if shl_amt < sh_amt {
                    na := create_binop(.ASHR, x, const_int_of(ty, cast(u64) (sh_amt - shl_amt)));
                    set_exact(na, is_exact(i));
                    return na;
                }
                if shl_amt > sh_amt {
                    ns := create_binop(.SHL, x, const_int_of(ty, cast(u64) (shl_amt - sh_amt)));
                    set_nsw(ns, true);
                    return ns;
                }
            }
        }

        {
            ok, x, sc := pm_binop(op0, .ASHR);
            okc1, sh_op1 := pm_apint(sc);
            if ok && okc1 && ap_ult_u64(sh_op1, bw) {
                amt_sum := cast(u64) sh_amt + ap_zext_value(sh_op1);
                amt_sum = min(amt_sum, cast(u64) bw - 1);
                return create_binop(.ASHR, x, const_int_of(ty, amt_sum));
            }
        }

        {
            oks, x := pmi_cast(op0, .SEXT);
            if oks && has_one_use(op0) && (is_vector_type(ty) || ic_should_change_type(ty, vtype(x))) {
                src_ty := vtype(x);
                sa := min(sh_amt, scalar_bits(x) - 1);
                nsh := icb_ashr(x, const_int_of(src_ty, cast(u64) sa));
                return create_cast(.SEXT, nsh, ty);
            }
        }

        if sh_amt == bw - 1 {
            if ic_is_binop(op0, .OR) && has_one_use(op0) {
                for side: 0..1 {
                    okn, x := pm_neg(op(op0, cast(u32) side));
                    if okn && op(op0, cast(u32) (1 - side)) == x return create_cast(.SEXT, icb_is_not_null(x), ty);
                }
            }
            {
                ok, x, y := pm_ob(op0, .SUB, F_NSW);
                if ok && has_one_use(op0) return create_cast(.SEXT, icb_cmp(ICMP_SLT, x, y), ty);
            }
            if ic_is_binop(op0, .AND) && has_one_use(op0) {
                x := ic_match_dec_and_not(op0);
                if x != NONE return create_cast(.SEXT, icb_is_null(x), ty);
            }
        }

        {
            okm, x, mcv := pm_ob(op0, .MUL, F_NSW);
            okmc, mul_c := pm_apint(mcv);
            if okm && has_one_use(op0) && okmc &&
               bw > 2 && ap_is_power_of_2(ap_sub_u64(mul_c, 1)) && ap_log2(mul_c) == sh_amt && sh_amt < bw - 1 {
                na := create_binop_flags(.ADD, x, icb_ashr(x, const_int_of(ty, cast(u64) sh_amt), "", is_exact(i)), F_NSW);
                set_nuw(na, has_nuw(op0));
                return na;
            }
        }
    }

    q := ic_q(i);
    if ic_set_shift_flags(i, q) return i;

    // Prefer `-(x & 1)` over `(x << (bitwidth(x)-1)) a>> (bitwidth(x)-1)`
    if pm_specific_int_allow_poison(op1, cast(u64) bw - 1) {
        ok, x, sa := pm_binop(op0, .SHL);
        if ok && has_one_use(op0) && pm_specific_int_allow_poison(sa, cast(u64) bw - 1) {
            mask := const_int_of(ty, 1);
            mask = ic_merge_undefs_with(ic_merge_undefs_with(mask, op1), sa);
            x2 := icb_and(x, mask);
            return create_neg(x2);
        }
    }

    r = ic_fold_variable_sign_zero_extension_of_variable_high_bit_extract(i); if r != NONE return r;

    // See if we can turn a signed shr into an unsigned shr.
    if ic_masked_value_is_zero(op0, ap_one_bit_set(bw, bw - 1), i) {
        l := create_binop(.LSHR, op0, op1);
        set_exact(l, is_exact(i));
        return l;
    }

    // ashr (xor %x, -1), %y  -->  xor (ashr %x, %y), -1
    {
        okn, x := pm_not(op0);
        if okn && has_one_use(op0) {
            na := icb_ashr(x, op1, tprint("%.not", vname(op0)));
            return create_not(na);
        }
    }
    return NONE;
}

// ---------------------------------------------------------------- shift helpers used by the compare folds too

// canTryToConstantAddTwoShiftAmounts (InstCombineShifts.cpp)
ic_can_try_to_constant_add_two_shift_amounts :: (sh0: Value_Id, sh_amt0: Value_Id, sh1: Value_Id, sh_amt1: Value_Id) -> bool {
    if vtype(sh_amt0) != vtype(sh_amt1) return false;
    max_total := cast(u64) (scalar_bits(sh0) - 1) + cast(u64) (scalar_bits(sh1) - 1);
    return ap_uge_u64(ap_all_ones(scalar_bits(sh_amt0)), max_total);
}

// reassociateShiftAmtsOfTwoSameDirectionShifts (InstCombineShifts.cpp)
ic_reassociate_shift_amts_of_two_same_direction_shifts :: (sh0: Value_Id, sq: Simplify_Query, analyze_for_sign_bit_extraction := false) -> Value_Id {
    if !(is_inst(sh0) && is_shift_op(inst_op(sh0))) return NONE;
    sh0_op0 := op(sh0, 0);
    if !is_inst(sh0_op0) return NONE;
    sh_amt0 := zext_or_self_i(op(sh0, 1));
    sh1: Value_Id = NONE; trunc: Value_Id = NONE;
    okt, t := pmi_cast(sh0_op0, .TRUNC);
    if okt && is_inst(t) { sh1 = t; trunc = sh0_op0; }
    else sh1 = sh0_op0;
    if !(is_inst(sh1) && is_shift_op(inst_op(sh1))) return NONE;
    x := op(sh1, 0);
    sh_amt1 := zext_or_self_i(op(sh1, 1));
    if !ic_can_try_to_constant_add_two_shift_amounts(sh0, sh_amt0, sh1, sh_amt1) return NONE;
    had_two_right := is_shr_op(inst_op(sh0)) && is_shr_op(inst_op(sh1));
    if analyze_for_sign_bit_extraction && !had_two_right return NONE;
    shift_opc := inst_op(sh0);
    identical := inst_op(sh0) == inst_op(sh1);
    if !identical && !analyze_for_sign_bit_extraction return NONE;
    if trunc != NONE && !analyze_for_sign_bit_extraction && !(has_one_use(op(sh0, 0)) || has_one_use(op(sh0, 1))) return NONE;
    new_sh_amt := simplify_add_inst(sh_amt0, sh_amt1, false, false, sq_with_instruction(sq, sh0));
    if new_sh_amt == NONE || !is_const(new_sh_amt) return NONE;
    nbw := scalar_bits(new_sh_amt);
    xbw := scalar_bits(x);
    ult :: (a: APInt, b: APInt) -> bool { return ap_ult(a, b); }
    eq :: (a: APInt, b: APInt) -> bool { return ap_eq(a, b); }
    if !pm_int_pred_arg(new_sh_amt, ult, ap_from_u64(nbw, cast(u64) xbw)) return NONE;
    if had_two_right && (trunc != NONE || analyze_for_sign_bit_extraction) {
        if !pm_int_pred_arg(new_sh_amt, eq, ap_from_u64(nbw, cast(u64) (xbw - 1))) return NONE;
        if analyze_for_sign_bit_extraction return x;
    }
    if vtype(new_sh_amt) != vtype(x) {
        new_sh_amt = cfo_cast_operand(.ZEXT, new_sh_amt, vtype(x));
        if new_sh_amt == NONE return NONE;
    }
    new_shift := create_binop(shift_opc, x, new_sh_amt);
    if trunc == NONE {
        if shift_opc == .SHL {
            set_nuw(new_shift, has_nuw(sh0) && has_nuw(sh1));
            set_nsw(new_shift, has_nsw(sh0) && has_nsw(sh1));
        } else set_exact(new_shift, is_exact(sh0) && is_exact(sh1));
    }
    ret := new_shift;
    if trunc != NONE {
        icb_insert(new_shift);
        ret = create_cast(.TRUNC, new_shift, vtype(sh0));
    }
    return ret;
}

// ShiftSemantics (InstCombineInternal.h)
Shift_Semantics :: enum u8 { LOSSY; SIGNED; UNSIGNED; }

// canEvaluateShiftedShift (InstCombineShifts.cpp)
ic_can_evaluate_shifted_shift :: (outer_sh_amt: u32, is_outer_shl: bool, sem: Shift_Semantics, inner: Value_Id, cxt: Value_Id) -> bool {
    ok, inner_c := pm_apint(op(inner, 1));
    if !ok return false;
    is_inner_shl := inst_op(inner) == .SHL;
    if !is_outer_shl && sem == .SIGNED return is_inner_shl && has_nsw(inner) && ap_eq_u64(inner_c, outer_sh_amt);
    if is_inner_shl == is_outer_shl return sem == .LOSSY;
    if ap_eq_u64(inner_c, outer_sh_amt) return true;
    tw := scalar_bits(inner);
    if ap_ugt_u64(inner_c, outer_sh_amt) && ap_ult_u64(inner_c, tw) {
        inner_sh_amt := cast(u32) ap_zext_value(inner_c);
        mask_shift := ifx is_inner_shl then tw - inner_sh_amt else inner_sh_amt - outer_sh_amt;
        mask := ap_shl(ap_low_bits_set(tw, outer_sh_amt), mask_shift);
        if ic_masked_value_is_zero(op(inner, 0), mask, cxt) return true;
    }
    return false;
}

// canEvaluateShifted (InstCombineShifts.cpp)
ic_can_evaluate_shifted :: (v: Value_Id, num_bits: u32, is_left_shift: bool, sem: Shift_Semantics, cxt: Value_Id) -> bool {
    if pm_imm_constant(v) {
        if sem == .LOSSY return true;
        ok, c := pm_apint_ap(v);
        if ok && !is_left_shift return ap_ctz(c) >= num_bits;
        return false;
    }
    if !is_inst(v) return false;
    if !has_one_use(v) return false;
    o := inst_op(v);
    if o == {
        case .AND; #through;
        case .OR; #through;
        case .XOR;
            return ic_can_evaluate_shifted(op(v, 0), num_bits, is_left_shift, sem, v) && ic_can_evaluate_shifted(op(v, 1), num_bits, is_left_shift, sem, v);
        case .SHL; #through;
        case .LSHR;
            return ic_can_evaluate_shifted_shift(num_bits, is_left_shift, sem, v, cxt);
        case .SELECT;
            return ic_can_evaluate_shifted(op(v, 1), num_bits, is_left_shift, sem, v) && ic_can_evaluate_shifted(op(v, 2), num_bits, is_left_shift, sem, v);
        case .PHI;
            n := phi_num_incoming(v);
            if n > 0 for k: 0..n-1 if !ic_can_evaluate_shifted(phi_value(v, cast(u32) k), num_bits, is_left_shift, sem, v) return false;
            return true;
        case .MUL;
            ok, mc := pm_apint(op(v, 1));
            return !is_left_shift && sem == .UNSIGNED && ok && ap_is_negated_power_of_2(mc) && ap_ctz(mc) == num_bits;
        case .ADD;
            if is_left_shift {
                if sem == .LOSSY return ic_can_evaluate_shifted(op(v, 0), num_bits, is_left_shift, sem, v) && ic_can_evaluate_shifted(op(v, 1), num_bits, is_left_shift, sem, v);
                return false;
            }
            if sem == .LOSSY return false;
            wrap := (sem == .SIGNED && has_nsw(v)) || (sem == .UNSIGNED && has_nuw(v));
            return wrap && ic_can_evaluate_shifted(op(v, 0), num_bits, is_left_shift, sem, v) && ic_can_evaluate_shifted(op(v, 1), num_bits, is_left_shift, sem, v);
    }
    return false;
}

// foldShiftedShift (InstCombineShifts.cpp)
ic_fold_shifted_shift :: (inner: Value_Id, outer_sh_amt: u32, is_outer_shl: bool, sem: Shift_Semantics) -> Value_Id {
    is_inner_shl := inst_op(inner) == .SHL;
    sht := vtype(inner);
    tw := scalar_bits(inner);
    _, c1 := pm_apint(op(inner, 1));
    inner_sh_amt := cast(u32) ap_zext_value(c1);
    new_inner_shift :: (inner: Value_Id, sh_amt: u32, is_inner_shl: bool) -> Value_Id {
        set_op(inner, 1, const_int_of(vtype(inner), cast(u64) sh_amt));
        if is_inner_shl { set_nuw(inner, false); set_nsw(inner, false); }
        else set_exact(inner, false);
        return inner;
    }
    if is_inner_shl == is_outer_shl {
        if inner_sh_amt + outer_sh_amt >= tw return const_null_value(sht);
        return new_inner_shift(inner, inner_sh_amt + outer_sh_amt, is_inner_shl);
    }
    if inner_sh_amt == outer_sh_amt {
        if !is_outer_shl && sem == .SIGNED return op(inner, 0);
        if !is_outer_shl && sem == .UNSIGNED && is_inner_shl && has_nuw(inner) return op(inner, 0);
        mask := ifx is_inner_shl then ap_low_bits_set(tw, tw - outer_sh_amt) else ap_high_bits_set(tw, tw - outer_sh_amt);
        a := icb_and(op(inner, 0), const_int_ap(sht, mask));
        if is_inst(a) {
            inst_move_before_dbg(a, inner);   // moveBefore: the records stay behind
            ic_take_name(a, inner);
        }
        return a;
    }
    return new_inner_shift(inner, inner_sh_amt - outer_sh_amt, is_inner_shl);
}

// getShiftedValue (InstCombineShifts.cpp)
ic_get_shifted_value :: (v: Value_Id, num_bits: u32, is_left_shift: bool, sem: Shift_Semantics) -> Value_Id {
    if is_const(v) {
        opc: Opcode = ifx is_left_shift then Opcode.SHL else (ifx sem == .SIGNED then Opcode.ASHR else .LSHR);
        return icb_binop(opc, v, const_int_of(vtype(v), cast(u64) num_bits));
    }
    wl_push(v);
    o := inst_op(v);
    if o == {
        case .AND; #through;
        case .OR; #through;
        case .XOR;
            set_op(v, 0, ic_get_shifted_value(op(v, 0), num_bits, is_left_shift, sem));
            set_op(v, 1, ic_get_shifted_value(op(v, 1), num_bits, is_left_shift, sem));
            return v;
        case .SHL; #through;
        case .LSHR;
            return ic_fold_shifted_shift(v, num_bits, is_left_shift, sem);
        case .SELECT;
            set_op(v, 1, ic_get_shifted_value(op(v, 1), num_bits, is_left_shift, sem));
            set_op(v, 2, ic_get_shifted_value(op(v, 2), num_bits, is_left_shift, sem));
            return v;
        case .PHI;
            n := phi_num_incoming(v);
            if n > 0 for k: 0..n-1 phi_set_value(v, k, ic_get_shifted_value(phi_value(v, cast(u32) k), num_bits, is_left_shift, sem));
            return v;
        case .MUL;
            neg := create_neg(op(v, 0));
            ic_insert_new_inst_with(neg, v);
            tw := scalar_bits(v);
            mask := ap_low_bits_set(tw, tw - num_bits);
            a := create_binop(.AND, neg, const_int_ap(vtype(v), mask));
            ic_take_name(a, v);
            return ic_insert_new_inst_with(a, v);
        case .ADD;
            if is_left_shift drop_poison_generating_flags(v);
            set_op(v, 0, ic_get_shifted_value(op(v, 0), num_bits, is_left_shift, sem));
            set_op(v, 1, ic_get_shifted_value(op(v, 1), num_bits, is_left_shift, sem));
            return v;
    }
    fatal("internal: Inconsistency with CanEvaluateShifted");
    return NONE;
}
