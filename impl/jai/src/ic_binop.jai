// InstCombine: the folds shared by all binary operators, from llvm/lib/Transforms/InstCombine/InstructionCombining.cpp
// (SimplifyAssociativeOrCommutative, foldUsingDistributiveLaws, tryFactorization, SimplifySelectsFeedingBinaryOp,
// FoldOpIntoSelect, foldOpIntoPhi, foldBinOpSelectBinOp, foldBinopWithPhiOperands, foldBinOpIntoSelectOrPhi,
// foldVectorBinop, narrowMathIfNoOverflow, getFreelyInvertedImpl, dyn_castNegVal, foldBinopOfSextBoolToSelect,
// tryFoldInstWithCtpopWithNot, foldBinOpShiftWithShift, foldBinOpOfSelectAndCastOfSelectCondition) and the
// overflow helpers of InstCombineInternal.h.

// ---------------------------------------------------------------- operand order

// Use::swap is use_swap (pass_sroa.jai)
swap_operands :: (i: Value_Id) { use_swap(op_use(i, 0), op_use(i, 1)); }
// CmpInst::swapOperands
cmp_swap_operands :: (i: Value_Id) {
    inst(i).pred = swapped_predicate(inst(i).pred);
    swap_operands(i);
}

// ---------------------------------------------------------------- overflow (InstCombineInternal.h)

ic_will_not_overflow_signed_add :: (l: Value_Id, r: Value_Id, cxt: Value_Id) -> bool { return compute_overflow_for_signed_add(l, r, ic_q(cxt)) == .NEVER_OVERFLOWS; }
ic_will_not_overflow_unsigned_add :: (l: Value_Id, r: Value_Id, cxt: Value_Id) -> bool { return compute_overflow_for_unsigned_add(l, r, ic_q(cxt)) == .NEVER_OVERFLOWS; }
ic_will_not_overflow_signed_sub :: (l: Value_Id, r: Value_Id, cxt: Value_Id) -> bool { return compute_overflow_for_signed_sub(l, r, ic_q(cxt)) == .NEVER_OVERFLOWS; }
ic_will_not_overflow_unsigned_sub :: (l: Value_Id, r: Value_Id, cxt: Value_Id) -> bool { return compute_overflow_for_unsigned_sub(l, r, ic_q(cxt)) == .NEVER_OVERFLOWS; }
ic_will_not_overflow_signed_mul :: (l: Value_Id, r: Value_Id, cxt: Value_Id) -> bool { return compute_overflow_for_signed_mul(l, r, ic_q(cxt)) == .NEVER_OVERFLOWS; }
ic_will_not_overflow_unsigned_mul :: (l: Value_Id, r: Value_Id, cxt: Value_Id, is_nsw := false) -> bool { return compute_overflow_for_unsigned_mul(l, r, ic_q(cxt), is_nsw) == .NEVER_OVERFLOWS; }
ic_will_not_overflow :: (opc: Opcode, l: Value_Id, r: Value_Id, cxt: Value_Id, is_signed: bool) -> bool {
    if opc == {
        case .ADD; return ifx is_signed then ic_will_not_overflow_signed_add(l, r, cxt) else ic_will_not_overflow_unsigned_add(l, r, cxt);
        case .SUB; return ifx is_signed then ic_will_not_overflow_signed_sub(l, r, cxt) else ic_will_not_overflow_unsigned_sub(l, r, cxt);
        case .MUL; return ifx is_signed then ic_will_not_overflow_signed_mul(l, r, cxt) else ic_will_not_overflow_unsigned_mul(l, r, cxt);
    }
    fatal("internal: ic_will_not_overflow of '%'", opcode_name(opc));
    return false;
}
// InstCombiner wrappers around ValueTracking with SQ.getWithInstruction(CxtI)
ic_known_bits :: (v: Value_Id, cxt: Value_Id, depth: u32 = 0) -> Known_Bits { return known_bits(v, ic_q(cxt), depth); }
ic_masked_value_is_zero :: (v: Value_Id, mask: APInt, cxt: Value_Id, depth: u32 = 0) -> bool { return masked_value_is_zero(v, mask, ic_q(cxt), depth); }
ic_num_sign_bits :: (v: Value_Id, cxt: Value_Id, depth: u32 = 0) -> u32 { return num_sign_bits(v, ic_q(cxt), depth); }
ic_is_known_non_negative :: (v: Value_Id, cxt: Value_Id) -> bool { return is_known_non_negative(v, ic_q(cxt)); }
ic_is_known_to_be_power_of_two :: (v: Value_Id, or_zero: bool, cxt: Value_Id) -> bool { return is_known_to_be_a_power_of_two(v, or_zero, ic_q(cxt)); }

// getLosslessInvCast (llvm/lib/Analysis/ConstantFolding.cpp), without the PreservedCastFlags output
get_lossless_inv_cast :: (c: Value_Id, to: Type_Id, cast_op: Opcode) -> Value_Id {
    if cast_op == {
        case .BITCAST; return cfo_cast_operand(.BITCAST, c, to);
        case .TRUNC; return cfo_cast_operand(.ZEXT, c, to);
        case .SEXT; #through;
        case .ZEXT;
            inv := ce_cast(.TRUNC, c, to);
            back := cfo_cast_operand(cast_op, inv, vtype(c));
            if back == NONE || back != c return NONE;
            return inv;
        case .FPEXT;
            inv := cfo_cast_operand(.FPTRUNC, c, to);
            if inv != NONE { back := cfo_cast_operand(cast_op, inv, vtype(c)); if back == c return inv; }
            return NONE;
    }
    return NONE;
}
get_lossless_unsigned_trunc :: (c: Value_Id, t: Type_Id) -> Value_Id { return get_lossless_inv_cast(c, t, .ZEXT); }
get_lossless_signed_trunc :: (c: Value_Id, t: Type_Id) -> Value_Id { return get_lossless_inv_cast(c, t, .SEXT); }

// ---------------------------------------------------------------- SimplifyAssociativeOrCommutative

ic_maintain_no_signed_wrap :: (i: Value_Id, b: Value_Id, c: Value_Id) -> bool {
    if !is_overflowing_binop(i) || !has_nsw(i) return false;
    okb, bv := pm_apint(b); okc, cv := pm_apint(c);
    if !okb || !okc return false;
    ov: bool;
    if inst_op(i) == {
        case .ADD; _, ov = ap_sadd_ov(bv, cv);
        case .SUB; _, ov = ap_ssub_ov(bv, cv);
        case .MUL; _, ov = ap_smul_ov(bv, cv);
        case; return false;
    }
    return !ov;
}
binop_has_nuw :: (i: Value_Id) -> bool { return is_overflowing_binop(i) && has_nuw(i); }
binop_has_nsw :: (i: Value_Id) -> bool { return is_overflowing_binop(i) && has_nsw(i); }

// simplifyAssocCastAssoc
ic_simplify_assoc_cast_assoc :: (b1: Value_Id) -> bool {
    cst := op(b1, 0);
    if !is_inst(cst) || !is_cast_op(inst_op(cst)) || !has_one_use(cst) return false;
    if inst_op(cst) != .ZEXT return false;
    if !is_bitwise_logic_op(inst_op(b1)) return false;
    opc := inst_op(b1);
    b2 := op(cst, 0);
    if !is_binary_operator(b2) || !has_one_use(b2) || inst_op(b2) != opc return false;
    c1 := op(b1, 1); c2 := op(b2, 1);
    if !is_const(c1) || !is_const(c2) return false;
    cc2 := cfo_cast_operand(.ZEXT, c2, vtype(c1));
    if cc2 == NONE return false;
    fc := cfo_binary_op_operands(opc, c1, cc2);
    if fc == NONE return false;
    ic_replace_operand(cst, 0, op(b2, 0));
    ic_replace_operand(b1, 1, fc);
    drop_poison_generating_flags(b1);
    drop_poison_generating_flags(cst);
    return true;
}

// matchSymmetricPair
ic_match_symmetric_pair :: (l: Value_Id, r: Value_Id) -> (bool, Value_Id, Value_Id) {
    if !is_inst(l) || !is_inst(r) || inst_op(l) != inst_op(r) return false, NONE, NONE;
    if inst_op(l) == {
        case .PHI;
            if inst_block(l) != inst_block(r) return false, NONE, NONE;
            n := nops(l);
            if n < 2 || nops(r) != n return false, NONE, NONE;
            for k: 0..n-1 if phi_block(l, k) != phi_block(r, k) return false, NONE, NONE;
            l0 := op(l, 0); r0 := op(r, 0);
            for k: 1..n-1 {
                l1 := op(l, k); r1 := op(r, k);
                if (l0 == l1 && r0 == r1) || (l0 == r1 && r0 == l1) continue;
                return false, NONE, NONE;
            }
            return true, l0, r0;
        case .SELECT;
            if op(l, 0) == op(r, 0) && op(l, 1) == op(r, 2) && op(l, 2) == op(r, 1) return true, op(l, 1), op(l, 2);
            return false, NONE, NONE;
        case .CALL;
            li := call_iid(l); ri := call_iid(r);
            if !is_min_max_intrinsic(li) || !is_min_max_intrinsic(ri) return false, NONE, NONE;
            if min_max_intrinsic_pred(li) != swapped_predicate(min_max_intrinsic_pred(ri)) return false, NONE, NONE;
            a := op(l, 0); b := op(l, 1); c := op(r, 0); d := op(r, 1);
            if (a == c && b == d) || (a == d && b == c) return true, a, b;
            return false, NONE, NONE;
    }
    return false, NONE, NONE;
}
// MinMaxIntrinsic::getPredicate
min_max_intrinsic_pred :: (id: Intrinsic_Id) -> u8 {
    if id == IID_SMAX return ICMP_SGT;
    if id == IID_SMIN return ICMP_SLT;
    if id == IID_UMAX return ICMP_UGT;
    return ICMP_ULT;
}

is_fp_binop :: (o: Opcode) -> bool { return o == .FADD || o == .FSUB || o == .FMUL || o == .FDIV || o == .FREM; }
// Instruction::isAssociative (FP ops with reassoc + nsz)
inst_is_associative :: (i: Value_Id) -> bool {
    o := inst_op(i);
    if is_associative_op(o) return true;
    if o == .FADD || o == .FMUL { f := get_fmf(i); return (f & FMF_REASSOC) != 0 && (f & FMF_NSZ) != 0; }
    return false;
}

ic_simplify_associative_or_commutative :: (i: Value_Id) -> bool {
    opc := inst_op(i);
    changed := false;
    commutative := is_commutative_op(opc);
    while true {
        if commutative && ic_complexity(op(i, 0)) < ic_complexity(op(i, 1)) { swap_operands(i); changed = true; }
        if commutative {
            ok, a, b := ic_match_symmetric_pair(op(i, 0), op(i, 1));
            if ok { ic_replace_operand(i, 0, a); ic_replace_operand(i, 1, b); changed = true; }
        }
        op0 := op(i, 0); op1 := op(i, 1);
        b0 := ifx is_binary_operator(op0) then op0 else NONE;
        b1 := ifx is_binary_operator(op1) then op1 else NONE;
        assoc := inst_is_associative(i);
        if assoc {
            if b0 != NONE && inst_op(b0) == opc {
                a := op(b0, 0); b := op(b0, 1); c := op1;
                v := simplify_binop(opc, b, c, ic_q(i));
                if v != NONE {
                    ic_replace_operand(i, 0, a);
                    ic_replace_operand(i, 1, v);
                    is_nuw := binop_has_nuw(i) && binop_has_nuw(b0);
                    is_nsw := ic_maintain_no_signed_wrap(i, b, c) && binop_has_nsw(b0);
                    if opc == .OR set_flag(i, F_EXACT, false);
                    if is_overflowing_binop(i) { set_nuw(i, is_nuw); set_nsw(i, is_nsw); }
                    changed = true;
                    continue;
                }
            }
            if b1 != NONE && inst_op(b1) == opc {
                a := op0; b := op(b1, 0); c := op(b1, 1);
                v := simplify_binop(opc, a, b, ic_q(i));
                if v != NONE {
                    ic_replace_operand(i, 0, v);
                    ic_replace_operand(i, 1, c);
                    if !is_fp_math_op_value(i) drop_poison_generating_flags(i);
                    changed = true;
                    continue;
                }
            }
        }
        if assoc && commutative {
            if ic_simplify_assoc_cast_assoc(i) { changed = true; continue; }
            if b0 != NONE && inst_op(b0) == opc {
                a := op(b0, 0); b := op(b0, 1); c := op1;
                v := simplify_binop(opc, c, a, ic_q(i));
                if v != NONE {
                    ic_replace_operand(i, 0, v);
                    ic_replace_operand(i, 1, b);
                    if !is_fp_math_op_value(i) drop_poison_generating_flags(i);
                    changed = true;
                    continue;
                }
            }
            if b1 != NONE && inst_op(b1) == opc {
                a := op0; b := op(b1, 0); c := op(b1, 1);
                v := simplify_binop(opc, c, a, ic_q(i));
                if v != NONE {
                    ic_replace_operand(i, 0, b);
                    ic_replace_operand(i, 1, v);
                    if !is_fp_math_op_value(i) drop_poison_generating_flags(i);
                    changed = true;
                    continue;
                }
            }
            if b0 != NONE && b1 != NONE && inst_op(b0) == opc && inst_op(b1) == opc &&
               has_one_use(b0) && has_one_use(b1) && is_const(op(b0, 1)) && is_const(op(b1, 1)) {
                a := op(b0, 0); c1 := op(b0, 1); b := op(b1, 0); c2 := op(b1, 1);
                cres := cfo_binary_op_operands(opc, c1, c2);
                if cres != NONE {
                    is_nuw := binop_has_nuw(i) && binop_has_nuw(b0) && binop_has_nuw(b1);
                    nb := create_binop_flags(opc, a, b, ifx is_nuw && opc == .ADD then cast(u32) F_NUW else 0);
                    if is_fp_math_inst(nb) set_fmf(nb, get_fmf(i) & get_fmf(b0) & get_fmf(b1));
                    ic_insert_new_inst_with(nb, i);
                    ic_take_name(nb, b1);
                    ic_replace_operand(i, 0, nb);
                    ic_replace_operand(i, 1, cres);
                    if !is_fp_math_op_value(i) drop_poison_generating_flags(i);
                    if is_nuw set_nuw(i);
                    changed = true;
                    continue;
                }
            }
        }
        return changed;
    }
    return changed;
}

// ---------------------------------------------------------------- distributive laws

left_distributes_over_right :: (l: Opcode, r: Opcode) -> bool {
    if l == .AND return r == .OR || r == .XOR;
    if l == .OR return r == .AND;
    if l == .MUL return r == .ADD || r == .SUB;
    return false;
}
right_distributes_over_left :: (l: Opcode, r: Opcode) -> bool {
    if is_commutative_op(r) return left_distributes_over_right(r, l);
    return is_bitwise_logic_op(l) && is_shift_op(r);
}
// getIdentityValue
ic_identity_value :: (opc: Opcode, v: Value_Id) -> Value_Id {
    if is_const(v) return NONE;
    return cf_binop_identity(opc, vtype(v), false);
}
// getBinOpsForFactorization: returns (opcode, lhs, rhs)
ic_binops_for_factorization :: (top: Opcode, bo: Value_Id, other: Value_Id) -> (Opcode, Value_Id, Value_Id) {
    l := op(bo, 0); r := op(bo, 1);
    if top == .ADD || top == .SUB {
        if inst_op(bo) == .SHL && pm_imm_constant(r) {
            nr := cf_binary(.SHL, const_int_of(vtype(bo), 1), r);
            return .MUL, l, nr;
        }
    }
    if is_bitwise_logic_op(top) {
        if other != NONE && inst_op(other) == .ASHR && inst_op(bo) == .LSHR && pm_non_negative(l) return .ASHR, l, r;
    }
    return inst_op(bo), l, r;
}
// tryFactorization
ic_try_factorization :: (i: Value_Id, inner: Opcode, a_in: Value_Id, b: Value_Id, c_in: Value_Id, d_in: Value_Id) -> Value_Id {
    a := a_in; c := c_in; d := d_in;
    v: Value_Id = NONE;
    ret: Value_Id = NONE;
    lhs := op(i, 0); rhs := op(i, 1);
    top := inst_op(i);
    inner_comm := is_commutative_op(inner);
    if left_distributes_over_right(inner, top) {
        if a == c || (inner_comm && a == d) {
            if a != c { t := c; c = d; d = t; }
            v = simplify_binop(top, b, d, ic_q(i));
            if v == NONE && (has_one_use(lhs) || has_one_use(rhs)) v = icb_binop(top, b, d, name_ref(vname(rhs)));
            if v != NONE ret = icb_binop(inner, a, v);
        }
    }
    if ret == NONE && right_distributes_over_left(top, inner) {
        bb := b;
        if bb == d || (inner_comm && bb == c) {
            if bb != d { t := c; c = d; d = t; }
            v = simplify_binop(top, a, c, ic_q(i));
            if v == NONE && (has_one_use(lhs) || has_one_use(rhs)) v = icb_binop(top, a, c, name_ref(vname(lhs)));
            if v != NONE ret = icb_binop(inner, v, bb);
        }
    }
    if ret == NONE return NONE;
    ic_take_name(ret, i);
    if is_binary_operator(ret) {
        nsw := false; nuw := false;
        if is_overflowing_binop(i) { nsw = has_nsw(i); nuw = has_nuw(i); }
        if is_overflowing_binop(lhs) { nsw &= has_nsw(lhs); nuw &= has_nuw(lhs); }
        if is_overflowing_binop(rhs) { nsw &= has_nsw(rhs); nuw &= has_nuw(rhs); }
        if top == .ADD && inner == .MUL {
            okc, cv := pm_apint(v);
            if okc && !ap_is_min_signed(cv) set_nsw(ret, nsw);
            set_nuw(ret, nuw);
        }
    }
    return ret;
}
// tryFactorizationFolds
ic_try_factorization_folds :: (i: Value_Id) -> Value_Id {
    lhs := op(i, 0); rhs := op(i, 1);
    b0 := ifx is_binary_operator(lhs) then lhs else NONE;
    b1 := ifx is_binary_operator(rhs) then rhs else NONE;
    top := inst_op(i);
    lop, rop: Opcode;
    a, b, c, d: Value_Id;
    if b0 != NONE lop, a, b = ic_binops_for_factorization(top, b0, b1);
    if b1 != NONE rop, c, d = ic_binops_for_factorization(top, b1, b0);
    if b0 != NONE && b1 != NONE && lop == rop {
        v := ic_try_factorization(i, lop, a, b, c, d);
        if v != NONE return v;
    }
    if b0 != NONE {
        id := ic_identity_value(lop, rhs);
        if id != NONE { v := ic_try_factorization(i, lop, a, b, rhs, id); if v != NONE return v; }
    }
    if b1 != NONE {
        id := ic_identity_value(rop, lhs);
        if id != NONE { v := ic_try_factorization(i, rop, lhs, id, c, d); if v != NONE return v; }
    }
    return NONE;
}
// foldUsingDistributiveLaws
ic_fold_using_distributive_laws :: (i: Value_Id) -> Value_Id {
    lhs := op(i, 0); rhs := op(i, 1);
    b0 := ifx is_binary_operator(lhs) then lhs else NONE;
    b1 := ifx is_binary_operator(rhs) then rhs else NONE;
    top := inst_op(i);
    r := ic_try_factorization_folds(i);
    if r != NONE return r;
    if b0 != NONE && right_distributes_over_left(inst_op(b0), top) {
        a := op(b0, 0); b := op(b0, 1); c := rhs;
        inner := inst_op(b0);
        sqd := sq_without_undef(ic_q(i));
        l := simplify_binop(top, a, c, sqd);
        rr := simplify_binop(top, b, c, sqd);
        if l != NONE && rr != NONE { x := icb_binop(inner, l, rr); ic_take_name(x, i); return x; }
        if l != NONE && l == cf_binop_identity(inner, vtype(l), false) { x := icb_binop(top, b, c); ic_take_name(x, i); return x; }
        if rr != NONE && rr == cf_binop_identity(inner, vtype(rr), false) { x := icb_binop(top, a, c); ic_take_name(x, i); return x; }
    }
    if b1 != NONE && left_distributes_over_right(top, inst_op(b1)) {
        a := lhs; b := op(b1, 0); c := op(b1, 1);
        inner := inst_op(b1);
        sqd := sq_without_undef(ic_q(i));
        l := simplify_binop(top, a, b, sqd);
        rr := simplify_binop(top, a, c, sqd);
        if l != NONE && rr != NONE { x := icb_binop(inner, l, rr); ic_take_name(x, i); return x; }
        if l != NONE && l == cf_binop_identity(inner, vtype(l), false) { x := icb_binop(top, a, c); ic_take_name(x, i); return x; }
        if rr != NONE && rr == cf_binop_identity(inner, vtype(rr), false) { x := icb_binop(top, a, b); ic_take_name(x, i); return x; }
    }
    return ic_simplify_selects_feeding_binop(i, lhs, rhs);
}

// SimplifySelectsFeedingBinaryOp
ic_simplify_selects_feeding_binop :: (i: Value_Id, lhs: Value_Id, rhs: Value_Id) -> Value_Id {
    ls, a, b, c := pm_select(lhs);
    rs, d, e, f := pm_select(rhs);
    if !ls && !rs return NONE;
    si := ifx ls then lhs else rhs;
    fmf: u32 = 0;
    saved_fmf := ic.b_fmf;
    defer ic.b_fmf = saved_fmf;
    if is_fp_math_op_value(i) { fmf = get_fmf(i); ic.b_fmf = fmf; }
    opc := inst_op(i);
    q := ic_q(i);
    cond: Value_Id = NONE; tv: Value_Id = NONE; fv: Value_Id = NONE;

    fold_add_negate :: (tval: Value_Id, fval: Value_Id, z: Value_Id, opc: Opcode, cond: Value_Id, tv: Value_Id, fv: Value_Id, i: Value_Id, si: Value_Id) -> Value_Id {
        if opc != .ADD || (tv == NONE && fv == NONE) || (tv != NONE && fv != NONE) return NONE;
        if tv != NONE { ok, n := pm_neg(fval); if ok { sub := icb_sub(z, n); return icb_select(cond, tv, sub, name_ref(vname(i)), si); } }
        if fv != NONE { ok, n := pm_neg(tval); if ok { sub := icb_sub(z, n); return icb_select(cond, sub, fv, name_ref(vname(i)), si); } }
        return NONE;
    }

    if ls && rs && a == d {
        cond = a;
        tv = simplify_binop_fmf(opc, b, e, fmf, q);
        fv = simplify_binop_fmf(opc, c, f, fmf, q);
        if has_one_use(lhs) && has_one_use(rhs) {
            if fv != NONE && tv == NONE tv = icb_binop(opc, b, e);
            else if tv != NONE && fv == NONE fv = icb_binop(opc, c, f);
        }
    } else if ls && has_one_use(lhs) {
        cond = a;
        tv = simplify_binop_fmf(opc, b, rhs, fmf, q);
        fv = simplify_binop_fmf(opc, c, rhs, fmf, q);
        ns := fold_add_negate(b, c, rhs, opc, cond, tv, fv, i, si);
        if ns != NONE return ns;
    } else if rs && has_one_use(rhs) {
        cond = d;
        tv = simplify_binop_fmf(opc, lhs, e, fmf, q);
        fv = simplify_binop_fmf(opc, lhs, f, fmf, q);
        ns := fold_add_negate(e, f, lhs, opc, cond, tv, fv, i, si);
        if ns != NONE return ns;
    }
    if tv == NONE || fv == NONE return NONE;
    nsi := icb_select(cond, tv, fv, name_ref(vname(i)), si);
    ic_take_name(nsi, i);
    return nsi;
}

// ---------------------------------------------------------------- negation / inversion helpers

// dyn_castNegVal
ic_dyn_cast_neg_val :: (v: Value_Id) -> Value_Id {
    ok, x := pm_neg(v);
    if ok return x;
    k := vkind(v);
    t := vtype(v);
    if k == .C_INT && !is_vector_type(t) return ce_neg(v);
    if k == .C_DATA && is_vector_type(t) && is_int_type(type_elem(t)) return ce_neg(v);
    if k == .C_VECTOR {
        n := nops(v);
        for e: 0..cast(s64) n - 1 {
            elt := op(v, cast(u32) e);
            if pm_undef_value(elt) continue;
            if vkind(elt) != .C_INT return NONE;
        }
        return ce_neg(v);
    }
    if is_const(v) && is_vector_type(t) && is_int_type(scalar_type(t)) && get_splat_value(v) != NONE return ce_neg(v);
    return NONE;
}

// shouldAvoidAbsorbingNotIntoSelect
should_avoid_absorbing_not_into_select :: (si: Value_Id) -> bool {
    ok, a, b := pm_logical_and(si); if ok return true;
    ok, a, b = pm_logical_or(si);
    return ok;
}

IC_NONNULL :: 0xFFFF_FFFE;   // the NonNull marker getFreelyInvertedImpl returns without a builder

// getFreelyInvertedImpl. `build` = a Builder was passed.
ic_get_freely_inverted_impl :: (v: Value_Id, will_invert_all_uses: bool, build: bool, does_consume: *bool, depth_in: u32) -> Value_Id {
    depth := depth_in;
    okn, a := pm_not(v);
    if okn { does_consume.* = true; return a; }
    if pm_imm_constant(v) return ce_not(v);
    if depth >= MAX_ANALYSIS_RECURSION_DEPTH return NONE;
    depth += 1;
    if !will_invert_all_uses return NONE;
    if is_cmp_inst(v) {
        if build return icb_cmp(cmp_inverse(inst_pred(v)), op(v, 0), op(v, 1));
        return IC_NONNULL;
    }
    ok, x, y := pm_binop(v, .ADD);
    if ok {
        bv := ic_get_freely_inverted_impl(y, has_one_use(y), build, does_consume, depth);
        if bv != NONE return ifx build then icb_sub(bv, x) else IC_NONNULL;
        av := ic_get_freely_inverted_impl(x, has_one_use(x), build, does_consume, depth);
        if av != NONE return ifx build then icb_sub(av, y) else IC_NONNULL;
        return NONE;
    }
    ok, x, y = pm_binop(v, .XOR);
    if ok {
        bv := ic_get_freely_inverted_impl(y, has_one_use(y), build, does_consume, depth);
        if bv != NONE return ifx build then icb_xor(x, bv) else IC_NONNULL;
        av := ic_get_freely_inverted_impl(x, has_one_use(x), build, does_consume, depth);
        if av != NONE return ifx build then icb_xor(av, y) else IC_NONNULL;
        return NONE;
    }
    ok, x, y = pm_binop(v, .SUB);
    if ok {
        av := ic_get_freely_inverted_impl(x, has_one_use(x), build, does_consume, depth);
        if av != NONE return ifx build then icb_add(av, y) else IC_NONNULL;
        return NONE;
    }
    ok, x, y = pm_binop(v, .ASHR);
    if ok {
        av := ic_get_freely_inverted_impl(x, has_one_use(x), build, does_consume, depth);
        if av != NONE return ifx build then icb_ashr(av, y) else IC_NONNULL;
        return NONE;
    }
    oks, cond, sa, sb := pm_select(v);
    is_select := oks && !should_avoid_absorbing_not_into_select(v);
    is_mm := is_min_max_intrinsic(call_iid(v));
    if is_select || is_mm {
        if is_mm { sa = op(v, 0); sb = op(v, 1); }
        local := does_consume.*;
        if ic_get_freely_inverted_impl(sb, has_one_use(sb), false, *local, depth) == NONE return NONE;
        not_a := ic_get_freely_inverted_impl(sa, has_one_use(sa), build, *local, depth);
        if not_a != NONE {
            does_consume.* = local;
            if build {
                not_b := ic_get_freely_inverted_impl(sb, has_one_use(sb), build, does_consume, depth);
                if is_mm return icb_binary_intrinsic(inverse_min_max_intrinsic(call_iid(v)), not_a, not_b);
                return icb_select(cond, not_a, not_b, "", v);
            }
            return IC_NONNULL;
        }
    }
    if is_phi(v) {
        local := does_consume.*;
        vals: [..] Value_Id; vals.allocator = temp;
        n := nops(v);
        for k: 0..cast(s64) n - 1 {
            nv := ic_get_freely_inverted_impl(op(v, cast(u32) k), false, false, *local, MAX_ANALYSIS_RECURSION_DEPTH - 1);
            if nv == NONE return NONE;
            if nv == v return NONE;
            if build array_add(*vals, nv);
        }
        does_consume.* = local;
        if build {
            saved := ic.b;
            irb_set_before(*ic.b, v);
            np := icb_insert(create_phi(vtype(v), n));
            ic.b = saved;
            for k: 0..cast(s64) n - 1 phi_add_incoming(np, vals[k], phi_block(v, cast(u32) k));
            return np;
        }
        return IC_NONNULL;
    }
    oke, ex := pm_sext_like(v);
    if oke {
        av := ic_get_freely_inverted_impl(ex, has_one_use(ex), build, does_consume, depth);
        if av != NONE return ifx build then icb_sext(av, vtype(v)) else IC_NONNULL;
        return NONE;
    }
    okt, tx := pm_cast(v, .TRUNC);
    if okt && is_inst(v) {
        av := ic_get_freely_inverted_impl(tx, has_one_use(tx), build, does_consume, depth);
        if av != NONE return ifx build then icb_trunc(av, vtype(v)) else IC_NONNULL;
        return NONE;
    }
    try_demorgan :: (opc: Opcode, logical: bool, a: Value_Id, b: Value_Id, build: bool, does_consume: *bool, depth: u32) -> Value_Id {
        local := does_consume.*;
        if ic_get_freely_inverted_impl(b, has_one_use(b), false, *local, depth) == NONE return NONE;
        not_a := ic_get_freely_inverted_impl(a, has_one_use(a), build, *local, depth);
        if not_a != NONE {
            not_b := ic_get_freely_inverted_impl(b, has_one_use(b), build, *local, depth);
            does_consume.* = local;
            if logical {
                if !build return IC_NONNULL;
                if opc == .AND return icb_select(not_a, not_b, get_false(vtype(not_a)));
                return icb_select(not_a, get_true(vtype(not_a)), not_b);
            }
            return ifx build then icb_binop(opc, not_a, not_b) else IC_NONNULL;
        }
        return NONE;
    }
    ok, x, y = pm_binop(v, .OR);
    if ok return try_demorgan(.AND, false, x, y, build, does_consume, depth);
    ok, x, y = pm_binop(v, .AND);
    if ok return try_demorgan(.OR, false, x, y, build, does_consume, depth);
    ok, x, y = pm_logical_or(v);
    if ok return try_demorgan(.AND, true, x, y, build, does_consume, depth);
    ok, x, y = pm_logical_and(v);
    if ok return try_demorgan(.OR, true, x, y, build, does_consume, depth);
    return NONE;
}
ic_get_freely_inverted :: (v: Value_Id, will_invert_all_uses: bool, build: bool) -> Value_Id, bool {
    dc := false;
    r := ic_get_freely_inverted_impl(v, will_invert_all_uses, build, *dc, 0);
    return r, dc;
}
ic_is_free_to_invert :: (v: Value_Id, will_invert_all_uses: bool) -> bool, bool {
    r, dc := ic_get_freely_inverted(v, will_invert_all_uses, false);
    return r != NONE, dc;
}
// m_SExtLike: sext, or zext nneg
pm_sext_like :: (v: Value_Id) -> (bool, Value_Id) {
    o := opr_code(v);
    if o == .SEXT return true, op(v, 0);
    if o == .ZEXT && (opr_flags(v) & F_EXACT) != 0 return true, op(v, 0);
    return false, NONE;
}

// ---------------------------------------------------------------- select / phi folding

// simplifyOperationIntoSelectOperand
ic_simplify_op_into_select_operand :: (i: Value_Id, si: Value_Id, is_true_arm: bool) -> Value_Id {
    ops: [..] Value_Id; ops.allocator = temp;
    cond := op(si, 0);
    n := nops(i);
    for k: 0..cast(s64) n - 1 {
        o := op(i, cast(u32) k);
        v: Value_Id = NONE;
        if o == si {
            v = ifx is_true_arm then op(si, 1) else op(si, 2);
        } else {
            okc, pred, ss, ca, cb := pm_icmp(cond);
            want := ifx is_true_arm then ICMP_EQ else ICMP_NE;
            if okc && pred == want && ca == o && is_guaranteed_not_to_be_undef_or_poison(cb) {
                v = cb;
            } else {
                okz, zx := pm_cast(o, .ZEXT);
                if okz && zx == cond v = ifx is_true_arm then const_int_of(vtype(o), 1) else const_null_value(vtype(o));
                else v = o;
            }
        }
        array_add(*ops, v);
    }
    q: Simplify_Query;   // simplifyInstructionWithOperands(&I, Ops, DL): no analyses, no context
    return simplify_instruction_with_operands(i, ops, q);
}
// foldOperationIntoSelectOperand
ic_fold_op_into_select_operand :: (i: Value_Id, si: Value_Id, new_op: Value_Id) -> Value_Id {
    c := ic_clone_inst(i);
    replace_uses_of_with(c, si, new_op);
    drop_ub_implying_attrs_and_metadata(c);
    ic_insert_new_inst_before(c, i);
    return c;
}
// FoldOpIntoSelect
ic_fold_op_into_select :: (i: Value_Id, si: Value_Id, fold_with_multi_use := false, simplify_both_arms := false) -> Value_Id {
    if !has_one_user(si) && !fold_with_multi_use return NONE;
    tv := op(si, 1); fv := op(si, 2);
    if is_int_or_int_vector_n(vtype(si), 1) return NONE;
    if is_min_max_intrinsic(call_iid(i)) {
        for k: 0..cast(s64) nops(i) - 1 {
            pn := op(i, cast(u32) k);
            if is_phi(pn) for kk: 0..cast(s64) nops(pn) - 1 if op(pn, cast(u32) kk) == i return NONE;
        }
    }
    ci := op(si, 0);
    if is_inst(ci) && inst_op(ci) == .FCMP && has_one_use(ci) {
        o0 := op(ci, 0); o1 := op(ci, 1);
        if ((tv == o0 && fv == o1) || (fv == o0 && tv == o1)) && !fcmp_is_commutative(inst_pred(ci)) return NONE;
    }
    ntv := ic_simplify_op_into_select_operand(i, si, true);
    nfv := ic_simplify_op_into_select_operand(i, si, false);
    if ntv == NONE && nfv == NONE return NONE;
    if simplify_both_arms && !(ntv != NONE && nfv != NONE) return NONE;
    if ntv == NONE ntv = ic_fold_op_into_select_operand(i, si, tv);
    if nfv == NONE nfv = ic_fold_op_into_select_operand(i, si, fv);
    ns := create_select(op(si, 0), ntv, nfv);
    copy_prof_unpredictable(ns, si);
    set_metadata(ns, 0, get_metadata(si, 0));
    return ns;
}
// CmpInst::isCommutative for fcmp: equality-like predicates
fcmp_is_commutative :: (p: u8) -> bool { return p == FCMP_OEQ || p == FCMP_ONE || p == FCMP_UEQ || p == FCMP_UNE || p == FCMP_ORD || p == FCMP_UNO || p == FCMP_TRUE || p == FCMP_FALSE; }

// Value::DoPHITranslation(CurBB, PredBB)
do_phi_translation :: (v: Value_Id, cur: Value_Id, pred: Value_Id) -> Value_Id {
    if is_phi(v) && inst_block(v) == cur {
        k := phi_block_index(v, pred);
        if k >= 0 return op(v, cast(u32) k);
    }
    return v;
}
// simplifyInstructionWithPHI
ic_simplify_inst_with_phi :: (i: Value_Id, pn: Value_Id, in_val: Value_Id, in_bb: Value_Id) -> Value_Id {
    ops: [..] Value_Id; ops.allocator = temp;
    for k: 0..cast(s64) nops(i) - 1 {
        o := op(i, cast(u32) k);
        if o == pn array_add(*ops, in_val);
        else array_add(*ops, do_phi_translation(o, inst_block(pn), in_bb));
    }
    nv := simplify_instruction_with_operands(i, ops, ic_q(block_terminator(in_bb)));
    if nv != NONE && nv != pn && vkind(nv) != .C_EXPR return nv;
    tbi := block_terminator(in_bb);
    if inst_op(tbi) == .CONDBR && get_successor(tbi, 0) != get_successor(tbi, 1) && inst_op(i) == .ICMP {
        lhs_true := get_successor(tbi, 0) == inst_block(pn);
        r := is_implied_condition_pred(op(tbi, 0), inst_pred(i), (inst(i).flags & F_EXACT) != 0, ops[0], ops[1], lhs_true);
        if r >= 0 return const_int_of(vtype(i), cast(u64) r);
    }
    return NONE;
}
// foldOpIntoPhi
ic_fold_op_into_phi :: (i: Value_Id, pn: Value_Id, allow_multiple_uses := false) -> Value_Id {
    n := phi_num_incoming(pn);
    if n == 0 return NONE;
    one_use := has_one_use(pn);
    identical_users := false;
    if !allow_multiple_uses && !one_use {
        u := ir.v_first_use[pn];
        while u != NONE {
            ui := ir.u_user[u];
            if ui != i && !is_identical_to(i, ui) return NONE;
            u = ir.u_next[u];
        }
        identical_users = true;
    }
    for k: 0..cast(s64) nops(i) - 1 {
        o := op(i, cast(u32) k);
        if o == pn continue;
        if !is_inst(o) continue;
        if inst_op(o) == .PHI && inst_block(o) == inst_block(pn) continue;
        if dt_dominates_inst_block(ic.dt, o, inst_block(pn)) continue;
        return NONE;
    }
    new_vals: [..] Value_Id; new_vals.allocator = temp;
    to_move: [..] u32; to_move.allocator = temp;
    seen_non_simplified := false;
    for k: 0..n-1 {
        in_val := op(pn, k);
        in_bb := phi_block(pn, k);
        nv := ic_simplify_inst_with_phi(i, pn, in_val, in_bb);
        if nv != NONE { array_add(*new_vals, nv); continue; }
        will_fold := false;
        if has_one_user(in_val) && vkind(in_val) == .INST {
            ok1, pred, ss, ca, cb := pm_icmp(i);
            okc, cc := pm_apint(cb);
            if (call_iid(in_val) == IID_UCMP || call_iid(in_val) == IID_SCMP) && ok1 && ca == pn && okc will_fold = true;
            if !will_fold && inst_op(in_val) == .ZEXT && is_int_or_int_vector_n(vtype(op(in_val, 0)), 1) && ok1 && pred == ICMP_EQ && ca == pn && pm_zero(cb) will_fold = true;
        }
        if will_fold { array_add(*to_move, k); array_add(*new_vals, NONE); continue; }
        if !one_use && !identical_users return NONE;
        if seen_non_simplified return NONE;
        seen_non_simplified = true;
        bi := block_terminator(in_bb);
        if inst_op(bi) != .BR || !dt_is_reachable_from_entry(ic.dt, in_bb) return NONE;
        array_add(*new_vals, NONE);
        array_add(*to_move, k);
        if ic_is_back_edge(in_bb, inst_block(pn)) return NONE;
    }
    clones: Table(Value_Id, Value_Id); clones.allocator = temp;
    for idx: to_move {
        o := op(pn, idx);
        obb := phi_block(pn, idx);
        found, c := table_find(*clones, obb);
        if !found {
            c = ic_clone_inst(i);
            for k: 0..cast(s64) nops(c) - 1 {
                u := op(c, cast(u32) k);
                if u == pn set_op(c, cast(u32) k, o);
                else set_op(c, cast(u32) k, do_phi_translation(u, inst_block(pn), obb));
            }
            ic_insert_new_inst_before(c, block_terminator(obb));
            table_set(*clones, obb, c);
            drop_ub_implying_attrs_and_metadata(c);
        }
        new_vals[idx] = c;
    }
    np := create_phi(vtype(i), n);
    ic_insert_new_inst_before(np, pn);
    ic_take_name(np, pn);
    set_metadata(np, 0, get_metadata(pn, 0));
    for k: 0..n-1 phi_add_incoming(np, new_vals[k], phi_block(pn, k));
    if identical_users {
        to_replace: [..] Value_Id; to_replace.allocator = temp;
        u := ir.v_first_use[pn];
        while u != NONE {
            us := ir.u_user[u];
            if us != i {
                dup := false;
                for to_replace if it == us { dup = true; break; }
                if !dup array_add(*to_replace, us);
            }
            u = ir.u_next[u];
        }
        for to_replace { ic_replace_inst_uses_with(it, np); ic_erase_inst(it); }
        one_use = true;
    }
    if one_use {
        users: [..] u32; users.allocator = temp;
        find_dbg_users(ic.f, pn, *users);
        if users.count fatal("instcombine: replaceAllDbgUsesWith in foldOpIntoPhi is not supported yet");
    }
    return ic_replace_inst_uses_with(i, np);
}

// foldBinOpSelectBinOp
ic_fold_binop_select_binop :: (i: Value_Id) -> Value_Id {
    si := op(i, 0);
    if !is_inst(si) || inst_op(si) != .SELECT return NONE;
    cst := op(i, 1);
    if !pm_imm_constant(cst) || !has_one_use(i) || !has_one_use(si) return NONE;
    tv := op(si, 1); fv := op(si, 2);
    opc := inst_op(i);
    ntv, nfv, input: Value_Id;
    ok, x, c2 := pm_binop(tv, opc);
    if has_one_use(tv) && ok && x == fv && pm_imm_constant(c2) {
        ntv = cf_binary(opc, cst, c2); nfv = cst; input = fv;
    } else {
        ok, x, c2 = pm_binop(fv, opc);
        if has_one_use(fv) && ok && x == tv && pm_imm_constant(c2) {
            ntv = cst; nfv = cf_binary(opc, cst, c2); input = tv;
        } else return NONE;
    }
    if ntv == NONE || nfv == NONE return NONE;
    ns := icb_select(op(si, 0), ntv, nfv, "", si);
    return create_binop(opc, ns, input);
}

// foldBinopWithRecurrence
ic_fold_binop_with_recurrence :: (bo: Value_Id) -> Value_Id {
    if !inst_is_associative(bo) return NONE;
    opc := inst_op(bo);
    b0 := op(bo, 0); b1 := op(bo, 1);
    if !is_binary_operator(b0) || !is_binary_operator(b1) || !has_n_uses(b0, 2) || !has_n_uses(b1, 2) ||
       inst_op(b0) != opc || inst_op(b1) != opc || !inst_is_associative(b0) || !inst_is_associative(b1) ||
       inst_block(b0) != inst_block(b1) return NONE;
    ok0, pn0, start0, step0 := match_simple_recurrence_bo(b0);
    if !ok0 || !has_one_use(pn0) return NONE;
    ok1, pn1, start1, step1 := match_simple_recurrence_bo(b1);
    if !ok1 || !has_one_use(pn1) || inst_block(pn0) != inst_block(pn1) return NONE;
    if !is_const(start0) || !is_const(start1) || !is_const(step0) || !is_const(step1) return NONE;
    init := cf_binary(opc, start0, start1);
    c := cf_binary(opc, step0, step1);
    if init == NONE || c == NONE return NONE;
    np := create_phi(vtype(pn0), phi_num_incoming(pn0));
    set_name(np, "reduced.phi");
    nb := create_binop(opc, np, c);
    if opc == .FADD || opc == .FMUL set_fmf(nb, get_fmf(b0) & get_fmf(b1) & get_fmf(bo));
    else {
        // OverflowTracking with AllKnownNonNegative = AllKnownNonZero = false: nuw/nsw survive if all three have them
        nuw := has_nuw(b0) && has_nuw(b1) && has_nuw(bo);
        nsw := has_nsw(b0) && has_nsw(b1) && has_nsw(bo);
        if is_overflowing_binop(nb) { set_nuw(nb, nuw); set_nsw(nb, nsw); }
    }
    ic_take_name(nb, bo);
    for k: 0..phi_num_incoming(pn0)-1 {
        v := op(pn0, k); bb := phi_block(pn0, k);
        if v == start0 phi_add_incoming(np, init, bb);
        else if v == b0 phi_add_incoming(np, nb, bb);
        else fatal("internal: foldBinopWithRecurrence");
    }
    ic_insert_new_inst_with(np, pn0);
    ic_insert_new_inst_with(nb, b0);
    ic_erase_inst(ic_replace_inst_uses_with(b0, const_poison(vtype(b0))));
    ic_erase_inst(ic_replace_inst_uses_with(b1, const_poison(vtype(b1))));
    ic_erase_inst(pn0);
    ic_erase_inst(pn1);
    return ic_replace_inst_uses_with(bo, nb);
}
// matchSimpleRecurrence(const BinaryOperator *I, PHINode *&P, Value *&Start, Value *&Step)
match_simple_recurrence_bo :: (i: Value_Id) -> (bool, Value_Id, Value_Id, Value_Id) {
    p0 := op(i, 0); p1 := op(i, 1);
    if is_phi(p0) { ok, bo, start, step := match_simple_recurrence(p0); if ok && bo == i return true, p0, start, step; }
    if is_phi(p1) { ok, bo, start, step := match_simple_recurrence(p1); if ok && bo == i return true, p1, start, step; }
    return false, NONE, NONE, NONE;
}

// foldBinopWithPhiOperands
ic_fold_binop_with_phi_operands :: (bo: Value_Id) -> Value_Id {
    nb := ic_fold_binop_with_recurrence(bo);
    if nb != NONE return nb;
    phi0 := op(bo, 0); phi1 := op(bo, 1);
    if !is_phi(phi0) || !is_phi(phi1) || !has_one_use(phi0) || !has_one_use(phi1) || nops(phi0) != nops(phi1) return NONE;
    if inst_block(bo) != inst_block(phi0) || inst_block(bo) != inst_block(phi1) return NONE;
    c := cf_binop_identity(inst_op(bo), vtype(bo), false);
    if c != NONE {
        vals: [..] Value_Id; vals.allocator = temp;
        all := true;
        for k: 0..nops(phi0)-1 {
            if phi_block(phi0, k) != phi_block(phi1, k) { all = false; break; }
            a := op(phi0, k); b := op(phi1, k);
            if a == c array_add(*vals, b);
            else if b == c array_add(*vals, a);
            else { all = false; break; }
        }
        if all {
            np := create_phi(vtype(phi0), nops(phi0));
            for k: 0..nops(phi0)-1 phi_add_incoming(np, vals[k], phi_block(phi0, k));
            return np;
        }
    }
    if nops(phi0) != 2 || nops(phi1) != 2 return NONE;
    const_bb, other_bb: Value_Id;
    c0, c1: Value_Id;
    if pm_imm_constant(op(phi0, 0)) { c0 = op(phi0, 0); const_bb = phi_block(phi0, 0); other_bb = phi_block(phi0, 1); }
    else if pm_imm_constant(op(phi0, 1)) { c0 = op(phi0, 1); const_bb = phi_block(phi0, 1); other_bb = phi_block(phi0, 0); }
    else return NONE;
    c1 = phi_incoming_for_block(phi1, const_bb);
    if !pm_imm_constant(c1) return NONE;
    pbr := block_terminator(other_bb);
    if inst_op(pbr) != .BR || !dt_is_reachable_from_entry(ic.dt, other_bb) return NONE;
    x := block_first(inst_block(bo));
    while x != bo { if !is_guaranteed_to_transfer_execution(x) return NONE; x = inst(x).next; }
    newc := cfo_binary_op_operands(inst_op(bo), c0, c1);
    if newc == NONE return NONE;
    icb_set_insert_point(pbr);
    nbo := icb_binop(inst_op(bo), phi_incoming_for_block(phi0, other_bb), phi_incoming_for_block(phi1, other_bb));
    if is_binary_operator(nbo) copy_ir_flags(nbo, bo);
    np := create_phi(vtype(bo), 2);
    phi_add_incoming(np, nbo, other_bb);
    phi_add_incoming(np, newc, const_bb);
    return np;
}

// foldBinOpIntoSelectOrPhi
ic_fold_binop_into_select_or_phi :: (i: Value_Id) -> Value_Id {
    try_operand :: (i: Value_Id, k: u32, other_const: bool) -> Value_Id {
        o := op(i, k);
        if is_inst(o) && inst_op(o) == .SELECT return ic_fold_op_into_select(i, o, false, !other_const);
        if is_phi(o) return ic_fold_op_into_phi(i, o);
        return NONE;
    }
    r := try_operand(i, 0, is_const(op(i, 1)));
    if r != NONE return r;
    return try_operand(i, 1, is_const(op(i, 0)));
}

// foldBinopOfSextBoolToSelect
ic_fold_binop_of_sext_bool_to_select :: (bo: Value_Id) -> Value_Id {
    ok, x := pm_cast(op(bo, 0), .SEXT);
    c := op(bo, 1);
    if !ok || !pm_imm_constant(c) || !is_int_or_int_vector_n(vtype(x), 1) return NONE;
    ones := const_all_ones_of(vtype(bo));
    zero := const_null_value(vtype(bo));
    tv := icb_binop(inst_op(bo), ones, c);
    fv := icb_binop(inst_op(bo), zero, c);
    return ic_create_select_unknown_profile(x, tv, fv);
}

// m_SelectLike(m_Value(A), m_Constant(T), m_Constant(F))
pm_select_like_consts :: (v: Value_Id) -> (bool, Value_Id, Value_Id, Value_Id) {
    ok, c, t, f := pm_select(v);
    if ok && is_const(t) && is_const(f) return true, c, t, f;
    okz, x := pm_cast(v, .ZEXT);
    if okz && is_int_or_int_vector_n(vtype(x), 1) return true, x, const_int_of(vtype(v), 1), const_null_value(vtype(v));
    oks, y := pm_cast(v, .SEXT);
    if oks && is_int_or_int_vector_n(vtype(y), 1) return true, y, const_all_ones_of(vtype(v)), const_null_value(vtype(v));
    return false, NONE, NONE, NONE;
}
// foldBinOpOfSelectAndCastOfSelectCondition
ic_fold_binop_of_select_and_cast_of_select_condition :: (i: Value_Id) -> Value_Id {
    opc := inst_op(i);
    lhs := op(i, 0); rhs := op(i, 1);
    a, ctv, cfv, cond, tv, fv, cast_op: Value_Id;
    match_sc :: (c: Value_Id, s: Value_Id) -> (bool, Value_Id, Value_Id, Value_Id, Value_Id, Value_Id, Value_Id) {
        ok, a, ct, cf := pm_select_like_consts(c);
        if !ok return false, NONE, NONE, NONE, NONE, NONE, NONE;
        oks, cd, t, f := pm_select(s);
        if !oks return false, NONE, NONE, NONE, NONE, NONE, NONE;
        return true, a, ct, cf, cd, t, f;
    }
    ok: bool;
    ok, a, ctv, cfv, cond, tv, fv = match_sc(lhs, rhs);
    if ok cast_op = lhs;
    else {
        ok, a, ctv, cfv, cond, tv, fv = match_sc(rhs, lhs);
        if ok cast_op = rhs; else return NONE;
    }
    si := ifx cast_op == lhs then rhs else lhs;
    new_folded :: (is_true_arm: bool, v: Value_Id, opc: Opcode, cast_is_rhs: bool, ctv: Value_Id, cfv: Value_Id) -> Value_Id {
        cv := ifx is_true_arm then cfv else ctv;
        if cast_is_rhs return icb_binop(opc, v, cv);
        return icb_binop(opc, cv, v);
    }
    is_rhs := cast_op == rhs;
    if cond == a {
        nt := new_folded(false, tv, opc, is_rhs, ctv, cfv);
        nf := new_folded(true, fv, opc, is_rhs, ctv, cfv);
        s := create_select(cond, nt, nf);
        copy_prof_unpredictable(s, si);
        return s;
    }
    okn, nx := pm_not(a);
    if okn && nx == cond {
        nt := new_folded(true, tv, opc, is_rhs, ctv, cfv);
        nf := new_folded(false, fv, opc, is_rhs, ctv, cfv);
        s := create_select(cond, nt, nf);
        copy_prof_unpredictable(s, si);
        return s;
    }
    return NONE;
}

// tryFoldInstWithCtpopWithNot
ic_try_fold_inst_with_ctpop_with_not :: (i: Value_Id) -> Value_Id {
    opc := inst_op(i);
    const_idx: u32 = 1;
    if opc == {
        case .SUB; const_idx = 0;
        case .ICMP; if cmp_is_signed(inst_pred(i)) return NONE;
        case .OR; if (inst(i).flags & F_EXACT) == 0 return NONE;
        case .ADD;
        case; return NONE;
    }
    ct := op(i, 1 - const_idx);
    if !has_one_use(ct) || call_iid(ct) != IID_CTPOP return NONE;
    x := op(ct, 0);
    c := op(i, const_idx);
    if !pm_imm_constant(c) return NONE;
    ty := vtype(x);
    bwc := const_int_of(ty, scalar_bits(x));
    if opc == .ICMP && !is_equality_pred(inst_pred(i)) {
        cmp := cfo_compare_inst_operands(ICMP_UGT, c, bwc);
        if cmp == NONE || !is_null_value(cmp) return NONE;
    }
    free, consumes := ic_is_free_to_invert(x, has_one_use(x));
    if !free || !consumes return NONE;
    not_op := ic_get_freely_inverted(x, has_one_use(x), true);
    ctpop := icb_intrinsic(IID_CTPOP, .[ty], .[not_op]);
    r: Value_Id;
    if opc == {
        case .SUB; r = icb_add(ctpop, ce_binop(.SUB, c, bwc, 0));
        case .OR; #through;
        case .ADD; r = icb_sub(ce_binop(.ADD, c, bwc, 0), ctpop);
        case .ICMP; r = icb_cmp(swapped_predicate(inst_pred(i)), ctpop, ce_binop(.SUB, bwc, c, 0));
    }
    return ic_replace_inst_uses_with(i, r);
}

// foldBinOpShiftWithShift
ic_fold_binop_shift_with_shift :: (i: Value_Id) -> Value_Id {
    is_valid_binopc :: (o: Opcode) -> bool { return o == .AND || o == .OR || o == .XOR || o == .ADD; }
    is_completely_distributable :: (b1: Opcode, b2: Opcode, sh: Opcode) -> bool { return (b1 != .ADD && b2 != .ADD) || sh == .SHL; }
    inv_shift :: (sh: Opcode) -> Opcode { return ifx sh == .LSHR then Opcode.SHL else .LSHR; }
    can_distribute :: (b1: Opcode, b2: Opcode, sh: Opcode, cmask: Value_Id, cshift: Value_Id) -> bool {
        if b1 == .AND return true;
        if !is_completely_distributable(b1, b2, sh) return false;
        if b2 == .AND return true;
        mis := cfo_binary_op_operands(inv_shift(sh), cmask, cshift);
        return cfo_binary_op_operands(sh, mis, cshift) == cmask;
    }
    match_binop :: (i: Value_Id, shn: u32) -> Value_Id {
        iy := op(i, shn);
        if !has_one_use(iy) || !is_inst(iy) || !is_shift_op(inst_op(iy)) return NONE;
        y := op(iy, 0); shift := op(iy, 1);
        bo2 := op(i, 1 - shn);
        if !has_one_use(bo2) || !is_binary_operator(bo2) return NONE;
        ix: Value_Id = NONE; mask: Value_Id = NONE;
        for side: 0..1 {
            cand := op(bo2, cast(u32) side);
            if has_one_use(cand) && is_inst(cand) && is_shift_op(inst_op(cand)) && op(cand, 1) == shift { ix = cand; mask = op(bo2, cast(u32) (1 - side)); break; }
        }
        if ix == NONE return NONE;
        x := op(ix, 0);
        sh := inst_op(iy);
        if sh != inst_op(ix) return NONE;
        binopc := inst_op(bo2);
        if !is_valid_binopc(inst_op(i)) || !is_valid_binopc(binopc) return NONE;
        if sh == .ASHR {
            if is_bitwise_logic_op(inst_op(i)) && binopc == .XOR && pm_all_ones(mask) {
                nx := icb_not(x);
                nb := icb_binop(inst_op(i), y, nx);
                return create_binop(sh, nb, shift);
            }
            return NONE;
        }
        if binopc == inst_op(i) && is_completely_distributable(inst_op(i), binopc, sh) {
            nb2 := icb_binop(inst_op(i), x, y);
            nb1 := icb_binop(sh, nb2, shift);
            return create_binop(inst_op(i), nb1, mask);
        }
        if !pm_imm_constant(shift) || !pm_imm_constant(mask) return NONE;
        if !can_distribute(inst_op(i), binopc, sh, mask, shift) return NONE;
        ncm := cfo_binary_op_operands(inv_shift(sh), mask, shift);
        nb2 := icb_binop(binopc, x, ncm);
        nb1 := icb_binop(inst_op(i), y, nb2);
        return create_binop(sh, nb1, shift);
    }
    r := match_binop(i, 0);
    if r != NONE return r;
    return match_binop(i, 1);
}

// ---------------------------------------------------------------- foldVectorBinop

// isSafeToSpeculativelyExecuteWithVariableReplaced for binary operators
is_safe_to_speculate_binop_variable_replaced :: (i: Value_Id) -> bool {
    o := inst_op(i);
    if o == .UDIV || o == .UREM {
        ok, v := pm_apint(op(i, 1));
        return ok && !ap_is_zero(v);
    }
    if o == .SDIV || o == .SREM {
        ok, d := pm_apint(op(i, 1));
        if !ok || ap_is_zero(d) return false;
        if !ap_is_all_ones(d) return true;
        okn, nn := pm_apint(op(i, 0));
        if okn return !ap_is_min_signed(nn);
        return false;
    }
    return true;
}
// m_Shuffle(m_Value(A), m_Value(B), m_Mask(M)) (instructions only)
pm_shuffle :: (v: Value_Id) -> (bool, Value_Id, Value_Id, [] u32) {
    if !is_inst(v) || inst_op(v) != .SHUFFLEVECTOR return false, NONE, NONE, .[];
    return true, op(v, 0), op(v, 1), shuffle_mask(v);
}
masks_equal :: (a: [] u32, b: [] u32) -> bool {
    if a.count != b.count return false;
    for a if it != b[it_index] return false;
    return true;
}
// ShuffleVectorInst::isConcat
shuffle_is_concat :: (sv: Value_Id) -> bool {
    m := shuffle_mask(sv);
    st := vtype(op(sv, 0));
    if type_kind(st) == .SVECTOR || pm_undef_value(op(sv, 0)) || pm_undef_value(op(sv, 1)) return false;
    n := cast(s64) type_count(st);
    if m.count != 2 * n return false;
    for m if it != 0xFFFF_FFFF && it != cast(u32) it_index return false;
    return true;
}
ic_fold_vector_binop :: (i: Value_Id) -> Value_Id {
    t := vtype(i);
    if !is_vector_type(t) return NONE;
    opc := inst_op(i);
    lhs := op(i, 0); rhs := op(i, 1);
    if call_iid(lhs) == IID_VECTOR_INSERT || call_iid(rhs) == IID_VECTOR_INSERT {
        if is_const(op(lhs, 0)) || is_const(op(rhs, 0)) fatal("instcombine: foldVectorBinop through llvm.vector.insert is not supported yet");
    }
    okl, l0, l1, lm := pm_shuffle(lhs);
    okr, r0, r1, rm := pm_shuffle(rhs);
    if okl && okr && masks_equal(lm, rm) && has_one_use(lhs) && has_one_use(rhs) && shuffle_is_concat(lhs) && shuffle_is_concat(rhs) {
        n0 := icb_binop(opc, l0, r0); if is_binary_operator(n0) copy_ir_flags(n0, i);
        n1 := icb_binop(opc, l1, r1); if is_binary_operator(n1) copy_ir_flags(n1, i);
        return create_shuffle(n0, n1, lm);
    }
    if call_iid(lhs) == IID_VECTOR_REVERSE || call_iid(rhs) == IID_VECTOR_REVERSE fatal("instcombine: foldVectorBinop of llvm.vector.reverse is not supported yet");
    if call_iid(lhs) == IID_EXPERIMENTAL_VP_REVERSE || call_iid(rhs) == IID_EXPERIMENTAL_VP_REVERSE fatal("instcombine: foldVectorBinop of llvm.experimental.vp.reverse is not supported yet");
    if call_iid(lhs) == IID_VECTOR_SPLICE_LEFT || call_iid(rhs) == IID_VECTOR_SPLICE_LEFT || call_iid(lhs) == IID_VECTOR_SPLICE_RIGHT || call_iid(rhs) == IID_VECTOR_SPLICE_RIGHT
        fatal("instcombine: foldVectorBinop of llvm.vector.splice is not supported yet");
    if !is_safe_to_speculate_binop_variable_replaced(i) return NONE;
    create_binop_shuffle :: (opc: Opcode, x: Value_Id, y: Value_Id, m: [] u32, i: Value_Id) -> Value_Id {
        xy := icb_binop(opc, x, y);
        if is_binary_operator(xy) copy_ir_flags(xy, i);
        return create_shuffle(xy, NONE, m);
    }
    if okl && okr && pm_poison(l1) && pm_poison(r1) && masks_equal(lm, rm) && vtype(l0) == vtype(r0) &&
       (has_one_use(lhs) || has_one_use(rhs) || lhs == rhs)
        return create_binop_shuffle(opc, l0, r0, lm, i);
    if is_commutative_op(opc) && okl && okr && r0 == l1 && r1 == l0 && masks_equal(lm, rm) {
        no_poison := true;
        for lm if it == 0xFFFF_FFFF no_poison = false;
        for rm if it == 0xFFFF_FFFF no_poison = false;
        if shuffle_is_select(lhs) && shuffle_is_select(rhs) && no_poison {
            nb := create_binop(opc, l0, l1);
            copy_ir_flags(nb, i);
            return nb;
        }
    }
    // Op(shuffle(V1, Mask), C) / Op(C, shuffle(V1, Mask))
    for side: 0..1 {
        sh := op(i, cast(u32) side);
        cc := op(i, cast(u32) (1 - side));
        oks, v1, v2, m := pm_shuffle(sh);
        if oks && has_one_use(sh) && pm_poison(v2) && pm_imm_constant(cc) {
            fatal("instcombine: foldVectorBinop with a shuffle and a constant (unshuffleConstant) is not supported yet");
        }
    }
    if is_associative_op(opc) && is_commutative_op(opc) {
        l := lhs; r := rhs;
        if is_inst(r) && inst_op(r) == .SHUFFLEVECTOR { t2 := l; l = r; r = t2; }
        oks, x, und, mc := pm_shuffle(l);
        if !oks || !has_one_use(l) || !pm_undef(und) return NONE;
        splat_index: s64 = -1;
        for mc {
            if it == 0xFFFF_FFFF continue;
            if splat_index == -1 splat_index = it;
            else if splat_index != it return NONE;
        }
        if splat_index == -1 return NONE;   // m_SplatOrPoisonMask needs a non-poison element
        if vtype(x) != vtype(i) return NONE;
        okb, y, other := pm_binop(r, opc);
        if !okb || !has_one_use(r) return NONE;
        if is_splat_value(other, cast(s32) splat_index) { t3 := y; y = other; other = t3; }
        else if !is_splat_value(y, cast(s32) splat_index) return NONE;
        nb := icb_binop(opc, x, y);
        nm := NewArray(mc.count, u32,, allocator = temp);
        for * nm it.* = cast(u32) splat_index;
        ns := icb_shuffle(nb, NONE, nm);
        rr := create_binop(opc, ns, other);
        if is_fp_math_inst(rr) { set_fmf(rr, get_fmf(i)); and_ir_flags(rr, r); }
        if is_binary_operator(nb) copy_ir_flags(nb, rr);
        return rr;
    }
    return NONE;
}

// ---------------------------------------------------------------- narrowMathIfNoOverflow

ic_narrow_math_if_no_overflow :: (bo: Value_Id) -> Value_Id {
    op0 := op(bo, 0); op1 := op(bo, 1);
    if inst_op(bo) == .SUB { t := op0; op0 = op1; op1 = t; }
    is_sext, x := pm_cast(op0, .SEXT);
    if !is_sext {
        okz, zx := pm_cast(op0, .ZEXT);
        if !okz return NONE;
        x = zx;
    }
    cast_opc: Opcode = ifx is_sext then .SEXT else .ZEXT;
    y: Value_Id;
    oky, yy := pm_zext_or_sext(op1);
    if !(oky && vtype(x) == vtype(yy) && opr_code(op1) == cast_opc && (has_one_use(op0) || has_one_use(op1))) {
        if !has_one_use(op0) || !is_const(op1) return NONE;
        nc := get_lossless_inv_cast(op1, vtype(x), cast_opc);
        if nc == NONE return NONE;
        y = nc;
    } else y = yy;
    if inst_op(bo) == .SUB { t := x; x = y; y = t; }
    if !ic_will_not_overflow(inst_op(bo), x, y, bo, is_sext) return NONE;
    nbo := icb_binop(inst_op(bo), x, y, "narrow");
    if is_binary_operator(nbo) { if is_sext set_nsw(nbo); else set_nuw(nbo); }
    return create_cast(cast_opc, nbo, vtype(bo));
}
