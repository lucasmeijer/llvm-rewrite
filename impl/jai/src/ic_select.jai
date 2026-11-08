// InstCombine for select: a port of llvm/lib/Transforms/InstCombine/InstCombineSelect.cpp (visitSelectInst and
// every helper of that file), in LLVM's order: helpers appear in the order of the C++ file, and visitSelectInst
// tries its folds in exactly LLVM's sequence (the first fold that fires wins).

// ---------------------------------------------------------------- small helpers of this port

ic_sel_cond :: inline (si: Value_Id) -> Value_Id { return op(si, 0); }
ic_sel_tv :: inline (si: Value_Id) -> Value_Id { return op(si, 1); }
ic_sel_fv :: inline (si: Value_Id) -> Value_Id { return op(si, 2); }
// m_BinOp(BO): a BinaryOperator instruction
ic_is_any_binop :: (v: Value_Id) -> bool { return is_inst(v) && is_binary_operator(v); }
// FPMathOperator::hasNoNaNs / hasNoInfs / hasNoSignedZeros
fmf_has :: inline (v: Value_Id, bit: u32) -> bool { return is_fp_math_inst(v) && (get_fmf(v) & bit) != 0; }
fmf_set_bit :: (i: Value_Id, bit: u32, on: bool) { f := get_fmf(i); if on f |= bit; else f &= ~bit; set_fmf(i, f); }
// ConstantExpr::getBinOpIdentity(Opcode, Ty, AllowRHSConstant, NSZ)
ic_binop_identity_nsz :: (opc: Opcode, t: Type_Id, allow_rhs: bool, nsz: bool) -> Value_Id {
    if opc == .FADD && nsz return const_null_value(t);   // +0.0
    return cf_binop_identity(opc, t, allow_rhs);
}
// Instruction::isSameOperationAs for the binary operators and GEPs that foldSelectOpOp compares
ic_is_same_operation_as :: (a: Value_Id, b: Value_Id) -> bool {
    if inst_op(a) != inst_op(b) || vtype(a) != vtype(b) || nops(a) != nops(b) return false;
    for k: 0..nops(a) - 1 if vtype(op(a, k)) != vtype(op(b, k)) return false;
    if inst_op(a) == .GEP && inst(a).ty2 != inst(b).ty2 return false;
    return true;
}
// GEPNoWrapFlags of a GEP in LLVM's form (inbounds implies nusw), intersected, back in this port's encoding
ic_gep_nw_intersect :: (a: Value_Id, b: Value_Id) -> u32 {
    nw :: (g: Value_Id) -> u32 {
        f := inst(g).flags & cast(u32) (F_INBOUNDS | F_NUSW | F_GEP_NUW);
        if f & F_INBOUNDS f |= F_NUSW;
        return f;
    }
    r := nw(a) & nw(b);
    if r & F_INBOUNDS r &= ~cast(u32) F_NUSW;
    return r;
}
// GetElementPtrInst::Create(Ty, Ptr, {Idx}, NW) (unlinked)
ic_create_gep1 :: (src_ty: Type_Id, ptr: Value_Id, idx: Value_Id, flags: u32) -> Value_Id {
    i := new_inst(.GEP, irb_gep_result_type(ptr, .[idx]), 2);
    inst(i).flags = flags; inst(i).ty2 = src_ty;
    set_op(i, 0, ptr); set_op(i, 1, idx);
    return i;
}
// new FreezeInst(V) (unlinked)
ic_create_freeze :: (v: Value_Id) -> Value_Id {
    i := new_inst(.FREEZE, vtype(v), 1);
    set_op(i, 0, v);
    return i;
}
// m_SpecificInt_ICMP(Pred, C)
pm_specific_int_icmp :: (v: Value_Id, pred: u8, c: APInt) -> bool {
    if pred == {
        case ICMP_ULT; return pm_int_pred_arg(v, (a: APInt, b: APInt) -> bool { return ap_ult(a, b); }, c);
        case ICMP_ULE; return pm_int_pred_arg(v, (a: APInt, b: APInt) -> bool { return ap_ule(a, b); }, c);
        case ICMP_UGT; return pm_int_pred_arg(v, (a: APInt, b: APInt) -> bool { return ap_ugt(a, b); }, c);
        case ICMP_UGE; return pm_int_pred_arg(v, (a: APInt, b: APInt) -> bool { return ap_uge(a, b); }, c);
        case ICMP_SLT; return pm_int_pred_arg(v, (a: APInt, b: APInt) -> bool { return ap_slt(a, b); }, c);
        case ICMP_SLE; return pm_int_pred_arg(v, (a: APInt, b: APInt) -> bool { return ap_sle(a, b); }, c);
        case ICMP_SGT; return pm_int_pred_arg(v, (a: APInt, b: APInt) -> bool { return ap_sgt(a, b); }, c);
        case ICMP_SGE; return pm_int_pred_arg(v, (a: APInt, b: APInt) -> bool { return ap_sge(a, b); }, c);
        case ICMP_EQ; return pm_int_pred_arg(v, (a: APInt, b: APInt) -> bool { return ap_eq(a, b); }, c);
        case ICMP_NE; return pm_int_pred_arg(v, (a: APInt, b: APInt) -> bool { return ap_ne(a, b); }, c);
    }
    return false;
}
// Constant::mergeUndefsWith
ce_merge_undefs_with :: (c: Value_Id, other: Value_Id) -> Value_Id {
    if pm_undef(c) return c;
    t := vtype(c);
    if pm_undef(other) return const_undef(t);
    if type_kind(t) != .VECTOR return c;
    n := cast(s64) type_count(t);
    et := type_elem(t);
    elts := NewArray(n, Value_Id,, allocator = temp);
    found := false;
    for e: 0..n - 1 {
        elts[e] = cf_elt(c, cast(u64) e);
        oe := cf_elt(other, cast(u64) e);
        if elts[e] == NONE || oe == NONE fatal("internal: mergeUndefsWith: unknown vector element");
        if !pm_undef(elts[e]) && pm_undef(oe) { elts[e] = const_undef(et); found = true; }
    }
    if found return cf_vector(t, elts);
    return c;
}
// m_IDiv / m_IRem (instructions)
pm_idiv :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
    if !is_inst(v) return false, NONE, NONE;
    o := inst_op(v);
    if o == .SDIV || o == .UDIV return true, op(v, 0), op(v, 1);
    return false, NONE, NONE;
}
pm_irem :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
    if !is_inst(v) return false, NONE, NONE;
    o := inst_op(v);
    if o == .SREM || o == .UREM return true, op(v, 0), op(v, 1);
    return false, NONE, NONE;
}

// ---------------------------------------------------------------- foldSelectBinOpIdentity

ic_fold_select_binop_identity :: (sel: Value_Id) -> Value_Id {
    cond := ic_sel_cond(sel);
    if !is_cmp_inst(cond) || !is_const(op(cond, 1)) return NONE;
    x := op(cond, 0); c := op(cond, 1);
    pred := inst_pred(cond);
    is_eq: bool;
    if icmp_is_equality(pred) && !is_fp_predicate(pred) is_eq = pred == ICMP_EQ;
    else if pred == FCMP_OEQ is_eq = true;
    else if pred == FCMP_UNE is_eq = false;
    else return NONE;
    k: u32 = ifx is_eq then cast(u32) 1 else 2;
    bo := op(sel, k);
    if !ic_is_any_binop(bo) return NONE;
    is_absorbing := false;
    y: Value_Id = NONE;
    if is_commutative_op(inst_op(bo)) {
        absorbing_match := false;
        if inst_op(bo) == .FMUL {
            for side: 0..1 {
                a := op(bo, cast(u32) side); b := op(bo, cast(u32) (1 - side));
                okf, fx := pm_fabs(a);
                if okf && fx == x { y = b; absorbing_match = true; break; }
            }
        }
        if absorbing_match && pm_any_zero_fp(c) && ic_fmul_by_zero_is_zero(y, get_fmf(bo), sel) {
            is_absorbing = true;
        } else {
            if op(bo, 1) == x y = op(bo, 0);
            else if op(bo, 0) == x y = op(bo, 1);
            else return NONE;
        }
    } else {
        if op(bo, 1) != x return NONE;
        y = op(bo, 0);
    }
    ty := vtype(bo);
    folded: Value_Id;
    if is_absorbing {
        folded = c;
    } else {
        idc := cf_binop_identity(inst_op(bo), ty, true);
        if idc != c {
            if idc == NONE || !is_fp_predicate(pred) return NONE;
            if !pm_any_zero_fp(idc) || !pm_any_zero_fp(c) return NONE;
        }
        if is_fp_math_inst(bo) && (get_fmf(bo) & FMF_NSZ) == 0 && !cannot_be_negative_zero(y, ic_q(sel)) return NONE;
        folded = y;
    }
    return ic_replace_operand(sel, k, folded);
}

// ---------------------------------------------------------------- foldSelectICmpAnd

ic_fold_select_icmp_and :: (sel: Value_Id, cond_val: Value_Id, true_val: Value_Id, false_val: Value_Id, v_in: Value_Id, and_mask: APInt, create_and: bool) -> Value_Id {
    v := v_in;
    ok1, tc := pm_apint(true_val);
    if !ok1 return NONE;
    ok2, fc := pm_apint(false_val);
    if !ok2 return NONE;
    sel_type := vtype(sel);
    if !ap_is_zero(tc) && !ap_is_zero(fc) {
        if tc.bits != and_mask.bits return NONE;
        if create_and && !has_one_use(cond_val) return NONE;
        tcc := cf_int(sel_type, tc);
        fcc := cf_int(sel_type, fc);
        mask_c := cf_int(sel_type, and_mask);
        for opc: Opcode.[.OR, .XOR, .ADD, .SUB] {
            if cfo_binary_op_operands(opc, tcc, mask_c) == fcc {
                if create_and v = icb_and(v, mask_c);
                return icb_binop(opc, tcc, v);
            }
        }
        return NONE;
    }
    if !ap_is_power_of_2(tc) && !ap_is_power_of_2(fc) return NONE;
    val_c := ifx !ap_is_zero(tc) then tc else fc;
    val_zeros := ap_log2(val_c);
    and_zeros := ap_log2(and_mask);
    should_not_val := !ap_is_zero(tc);
    need_shift := val_zeros != and_zeros;
    need_zext_trunc := scalar_bits(sel) != scalar_bits(v);
    cnt := cast(s32) create_and + cast(s32) should_not_val + cast(s32) need_shift + cast(s32) need_zext_trunc;
    if cnt > 1 + cast(s32) has_one_use(cond_val) return NONE;
    if create_and v = icb_and(v, cf_int(vtype(v), and_mask));
    if val_zeros > and_zeros {
        v = icb_zext_or_trunc(v, sel_type);
        v = icb_shl_c(v, cast(u64) (val_zeros - and_zeros));
    } else if val_zeros < and_zeros {
        v = icb_lshr(v, const_int(vtype(v), cast(u64) (and_zeros - val_zeros)));
        v = icb_zext_or_trunc(v, sel_type);
    } else {
        v = icb_zext_or_trunc(v, sel_type);
    }
    if should_not_val v = icb_xor(v, cf_int(vtype(v), val_c));
    return v;
}

// ---------------------------------------------------------------- foldSelectOpOp

// getSelectFoldableOperands
ic_get_select_foldable_operands :: (i: Value_Id) -> u32 {
    if inst_op(i) == {
        case .ADD; #through; case .FADD; #through; case .MUL; #through; case .FMUL; #through;
        case .AND; #through; case .OR; #through; case .XOR; return 3;
        case .SUB; #through; case .FSUB; #through; case .FDIV; #through; case .SHL; #through;
        case .LSHR; #through; case .ASHR; return 1;
    }
    return 0;
}

Ic_Common_Op :: struct { other_t: Value_Id; other_f: Value_Id; match_is_op_zero: bool; }
// the getCommonOp lambda of foldSelectOpOp
ic_get_common_op :: (ti: Value_Id, fi: Value_Id, commute: bool, swapped: bool, r: *Ic_Common_Op) -> Value_Id {
    if !swapped {
        if op(ti, 0) == op(fi, 0) {
            r.other_t = op(ti, 1); r.other_f = op(fi, 1); r.match_is_op_zero = true;
            return op(ti, 0);
        } else if op(ti, 1) == op(fi, 1) {
            r.other_t = op(ti, 0); r.other_f = op(fi, 0); r.match_is_op_zero = false;
            return op(ti, 1);
        }
    }
    if !commute && !swapped return NONE;
    if op(ti, 0) == op(fi, 1) {
        r.other_t = op(ti, 1); r.other_f = op(fi, 0); r.match_is_op_zero = true;
        return op(ti, 0);
    } else if op(ti, 1) == op(fi, 0) {
        r.other_t = op(ti, 0); r.other_f = op(fi, 1); r.match_is_op_zero = false;
        return op(ti, 1);
    }
    return NONE;
}

ic_fold_select_op_op :: (si: Value_Id, ti: Value_Id, fi: Value_Id) -> Value_Id {
    cond := ic_sel_cond(si);
    cond_ty := vtype(cond);
    if is_cast_op(inst_op(ti)) {
        fi_opnd_ty := vtype(op(fi, 0));
        if vtype(op(ti, 0)) != fi_opnd_ty return NONE;
        if is_vector_type(cond_ty) {
            if !is_vector_type(fi_opnd_ty) || type_count(cond_ty) != type_count(fi_opnd_ty) ||
               type_kind(cond_ty) != type_kind(fi_opnd_ty) return NONE;
            if inst_op(ti) != .BITCAST && (!has_one_use(ti) || !has_one_use(fi)) return NONE;
        } else if !has_one_use(ti) || !has_one_use(fi) {
            return NONE;
        }
        new_si := icb_select(cond, op(ti, 0), op(fi, 0), tprint("%.v", vname(si)), si);
        return create_cast(inst_op(ti), new_si, vtype(ti));
    }
    co: Ic_Common_Op;
    if has_one_use(ti) || has_one_use(fi) {
        okx, x := pm_fneg(ti);
        oky, y := pm_fneg(fi);
        if okx && oky && is_inst(ti) && is_inst(fi) {
            fmf := get_fmf(ti) & get_fmf(fi);
            fmf |= get_fmf(si);
            new_sel := icb_select(cond, x, y, tprint("%.v", vname(si)), si);
            if is_inst(new_sel) set_fmf(new_sel, fmf);
            nf := new_inst(.FNEG, vtype(new_sel), 1);
            set_op(nf, 0, new_sel);
            set_fmf(nf, fmf);
            return nf;
        }
        tid := call_iid(ti); fid := call_iid(fi);
        if tid != NOT_INTRINSIC && fid != NOT_INTRINSIC && tid == fid {
            if tid == IID_SMAX || tid == IID_SMIN || tid == IID_UMAX || tid == IID_UMIN {
                match_op := ic_get_common_op(ti, fi, true, false, *co);
                if match_op != NONE {
                    new_sel := icb_select(cond, co.other_t, co.other_f, "minmaxop", si);
                    return create_intrinsic_call(tid, .[vtype(ti)], .[new_sel, match_op]);
                }
            }
            if tid == IID_LDEXP {
                v0 := op(ti, 0); e0 := op(ti, 1);
                v1 := op(fi, 0); e1 := op(fi, 1);
                if vtype(e0) == vtype(e1) {
                    fmf := get_fmf(ti) & get_fmf(fi);
                    fmf |= get_fmf(si);
                    sel_val := icb_select(cond, v0, v1);
                    sel_exp := icb_select(cond, e0, e1);
                    saved := ic.b_fmf; ic.b_fmf = fmf;
                    nl := icb_intrinsic(IID_LDEXP, .[vtype(ti), vtype(sel_exp)], .[sel_val, sel_exp]);
                    ic.b_fmf = saved;
                    return ic_replace_inst_uses_with(si, nl);
                }
            }
        }
        okt, tp, tss, _, _ := pm_icmp(ti);
        okf, fp, fss, _, _ := pm_icmp(fi);
        if okt && okf {
            create_cmp_sel :: (si: Value_Id, cond: Value_Id, ti: Value_Id, fi: Value_Id, ok: bool, p: u8, swapped: bool) -> Value_Id {
                if !ok return NONE;
                co: Ic_Common_Op;
                match_op := ic_get_common_op(ti, fi, icmp_is_equality(p), icmp_is_relational(p) && swapped, *co);
                if match_op == NONE return NONE;
                new_sel := icb_select(cond, co.other_t, co.other_f, tprint("%.v", vname(si)), si);
                return create_icmp(ifx co.match_is_op_zero then p else icmp_swapped(p), match_op, new_sel);
            }
            okm, mp, _ := cmp_get_matching(tp, tss, fp, fss);
            r := create_cmp_sel(si, cond, ti, fi, okm, mp, false); if r != NONE return r;
            okm, mp = cmp_get_matching(tp, tss, icmp_swapped(fp), fss);
            r = create_cmp_sel(si, cond, ti, fi, okm, mp, true); if r != NONE return r;
        }
    }
    if nops(ti) != 2 || nops(fi) != 2 || !ic_is_same_operation_as(ti, fi) ||
       (!is_binary_operator(ti) && inst_op(ti) != .GEP) || !has_one_use(ti) || !has_one_use(fi) return NONE;
    commutative := is_binary_operator(ti) && is_commutative_op(inst_op(ti));
    match_op := ic_get_common_op(ti, fi, commutative, false, *co);
    if match_op == NONE return NONE;
    if is_vector_type(cond_ty) && (!is_vector_type(vtype(co.other_t)) || !is_vector_type(vtype(co.other_f))) return NONE;
    if is_binary_operator(ti) && is_int_div_rem(inst_op(ti)) && !is_guaranteed_not_to_be_poison(cond) {
        if inst_op(ti) == .SDIV || inst_op(ti) == .SREM || co.match_is_op_zero cond = icb_freeze(cond);
    }
    new_si := icb_select(cond, co.other_t, co.other_f, tprint("%.v", vname(si)), si);
    op0 := ifx co.match_is_op_zero then match_op else new_si;
    op1 := ifx co.match_is_op_zero then new_si else match_op;
    if is_binary_operator(ti) {
        nb := create_binop(inst_op(ti), op0, op1);
        copy_ir_flags(nb, ti);
        and_ir_flags(nb, fi);
        return nb;
    }
    return ic_create_gep1(inst(ti).ty2, op0, op1, ic_gep_nw_intersect(ti, fi));
}

// ---------------------------------------------------------------- foldSelectIntrinsic

ic_fold_select_intrinsic :: (si: Value_Id) -> Value_Id {
    l := ic_sel_tv(si); r := ic_sel_fv(si);
    lid := call_iid(l);
    if lid == NOT_INTRINSIC return NONE;
    rid := call_iid(r);
    if rid == NOT_INTRINSIC || lid != rid || !has_one_use(l) || !has_one_use(r) return NONE;
    if lid == {
        case IID_ABS; #through; case IID_CTTZ; #through; case IID_CTLZ;
            tz := op(l, 1); fz := op(r, 1);
            tv := op(l, 0); fv := op(r, 0);
            new_sel := icb_select(ic_sel_cond(si), tv, fv, "", si);
            new_flag := icb_and(tz, fz);
            nc := icb_binary_intrinsic(lid, new_sel, new_flag);
            return ic_replace_inst_uses_with(si, nc);
        case IID_CTPOP;
            tv := op(l, 0); fv := op(r, 0);
            new_sel := icb_select(ic_sel_cond(si), tv, fv, "", si);
            nc := icb_unary_intrinsic(lid, new_sel);
            return ic_replace_inst_uses_with(si, nc);
    }
    return NONE;
}

// isSelect01
ic_is_select01 :: (c1: APInt, c2: APInt) -> bool {
    if !ap_is_zero(c1) && !ap_is_zero(c2) return false;
    return ap_is_one(c1) || ap_is_all_ones(c1) || ap_is_one(c2) || ap_is_all_ones(c2);
}

// ---------------------------------------------------------------- foldSelectIntoOp

ic_fold_select_into_op :: (si: Value_Id, true_val: Value_Id, false_val: Value_Id) -> Value_Id {
    try_fold :: (si: Value_Id, true_val: Value_Id, false_val: Value_Id, swapped: bool) -> Value_Id {
        tvi := true_val;
        if !ic_is_any_binop(tvi) || !has_one_use(tvi) || is_const(false_val) return NONE;
        sfo := ic_get_select_foldable_operands(tvi);
        op_to_fold: u32 = 0;
        if (sfo & 1) && false_val == op(tvi, 0) op_to_fold = 1;
        else if (sfo & 2) && false_val == op(tvi, 1) op_to_fold = 2;
        if op_to_fold == 0 return NONE;
        fmf: u32 = 0;
        is_fpo := is_fp_math_inst(si);
        if is_fpo fmf = get_fmf(si);
        c := ic_binop_identity_nsz(inst_op(tvi), vtype(tvi), true, (fmf & FMF_NSZ) != 0);
        oop := op(tvi, 2 - op_to_fold);
        okc, oopc := pm_apint(oop);
        if is_const(oop) {
            if !okc return NONE;
            okk, cu := pm_apint(c);
            if !okk fatal("internal: foldSelectIntoOp: getUniqueInteger of a non-integer identity");
            if !ic_is_select01(cu, oopc) return NONE;
        }
        if is_fpo && !kfpc_is_known_never_nan(compute_known_fp_class_fmf(false_val, fmf, FC_NAN, ic_q(si))) return NONE;
        new_sel := icb_select(ic_sel_cond(si), ifx swapped then c else oop, ifx swapped then oop else c, "", si);
        if is_fpo {
            nfmf := fmf;
            o := inst_op(tvi);
            can_infer := o == .FADD || o == .FSUB || o == .FMUL;
            ninf := fmf_has(tvi, FMF_NINF) || (can_infer && (nfmf & FMF_NINF) != 0 && (nfmf & FMF_NNAN) != 0);
            if ninf nfmf |= FMF_NINF; else nfmf &= ~cast(u32) FMF_NINF;
            set_fmf(new_sel, nfmf);
        }
        ic_take_name(new_sel, tvi);
        bo := create_binop(inst_op(tvi), false_val, new_sel);
        copy_ir_flags(bo, tvi);
        if is_fpo {
            fmf_set_bit(bo, FMF_NNAN, fmf_has(bo, FMF_NNAN) && (fmf & FMF_NNAN) != 0);
            fmf_set_bit(bo, FMF_NINF, fmf_has(bo, FMF_NINF) && (fmf & FMF_NINF) != 0);
            fmf_set_bit(bo, FMF_NSZ, fmf_has(bo, FMF_NSZ) && (fmf & FMF_NSZ) != 0);
        }
        return bo;
    }
    r := try_fold(si, true_val, false_val, false); if r != NONE return r;
    r = try_fold(si, false_val, true_val, true); if r != NONE return r;
    return NONE;
}

// ---------------------------------------------------------------- canoncalizeSelectICmpMinMax / foldSelectICmpMinMax

ic_canoncalize_select_icmp_min_max :: (cmp: Value_Id, tval_in: Value_Id, fval_in: Value_Id, q: Simplify_Query) -> Value_Id {
    tval := tval_in; fval := fval_in;
    cl := op(cmp, 0); cr := op(cmp, 1);
    pred := inst_pred(cmp);
    if pm_zero(fval) { t := tval; tval = fval; fval = t; pred = icmp_inverse(pred); }
    if !pm_zero(tval) return NONE;
    if pred == ICMP_SGT || pred == ICMP_SGE { t := cl; cl = cr; cr = t; pred = icmp_swapped(pred); }
    if pred == ICMP_SLT || pred == ICMP_SLE {
        ok, a, b := pm_ob(fval, .SUB, F_NSW);
        if ok && a == cl && b == cr && is_guaranteed_not_to_be_undef(cl, q.ac, q.cxt, q.dt) {
            smin := icb_binary_intrinsic(IID_SMIN, cr, cl);
            return icb_sub(cl, smin, "", false, true);
        }
    }
    return NONE;
}

ic_fold_select_icmp_min_max :: (cmp: Value_Id, tval: Value_Id, fval: Value_Id, q: Simplify_Query) -> Value_Id {
    cl := op(cmp, 0); cr := op(cmp, 1);
    pred := inst_pred(cmp);
    v := ic_canoncalize_select_icmp_min_max(cmp, tval, fval, q); if v != NONE return v;
    if cr == tval { t := cl; cl = cr; cr = t; pred = icmp_swapped(pred); }
    if !(cl == tval && is_inst(fval)) return NONE;
    ok, a, b := pm_ob(fval, .ADD, F_NSW);
    if pred == ICMP_SGT && ok && a == cr && pm_one(b) {
        set_nuw(fval, false);
        return icb_binary_intrinsic(IID_SMAX, tval, fval);
    }
    if pred == ICMP_SLT && ok && a == cr && pm_all_ones(b) {
        set_nuw(fval, false);
        return icb_binary_intrinsic(IID_SMIN, tval, fval);
    }
    ok, a, b = pm_ob(fval, .ADD, F_NUW);
    if pred == ICMP_UGT && ok && a == cr && pm_one(b) {
        set_nsw(fval, false);
        return icb_binary_intrinsic(IID_UMAX, tval, fval);
    }
    ok, a, b = pm_binop(fval, .ADD);
    if pred == ICMP_ULT && ok && a == cr && pm_all_ones(b) && is_known_non_zero(cr, q) {
        set_nsw(fval, false);
        set_nuw(fval, false);
        return icb_binary_intrinsic(IID_UMIN, tval, fval);
    }
    return NONE;
}

// ---------------------------------------------------------------- foldSelectICmpAndAnd

ic_fold_select_icmp_and_and :: (sel_type: Type_Id, cmp: Value_Id, tval: Value_Id, fval: Value_Id) -> Value_Id {
    if !(has_one_use(cmp) && has_one_use(op(cmp, 0)) && inst_pred(cmp) == ICMP_EQ && pm_zero(op(cmp, 1)) && pm_one(fval)) return NONE;
    if !has_one_use(tval) return NONE;
    okb, b, one := pm_binop(tval, .AND);
    if !okb || !pm_one(one) return NONE;
    x, z: Value_Id;
    has_shift := false;
    if has_one_use(b) { ok, x1, z1 := pm_binop(b, .LSHR); if ok { has_shift = true; x = x1; z = z1; } }
    bw := type_bits(scalar_type(sel_type));
    if has_shift && !pm_specific_int_icmp(z, ICMP_ULT, ap_from_u64(bw, cast(u64) bw)) return NONE;
    if !has_shift x = b;
    oky, y := pm_c_binop_with(op(cmp, 0), .AND, x);
    if !oky return NONE;
    one_c := const_int(sel_type, 1);
    mask_b := ifx has_shift then icb_shl(one_c, z) else one_c;
    full_mask := icb_or(y, mask_b);
    masked_x := icb_and(x, full_mask);
    ne := icb_is_not_null(masked_x);
    return create_cast(.ZEXT, ne, sel_type);
}

// ---------------------------------------------------------------- foldSelectICmpAndZeroShl

ic_fold_select_icmp_and_zero_shl :: (cmp: Value_Id, tval_in: Value_Id, fval_in: Value_Id) -> Value_Id {
    tval := tval_in; fval := fval_in;
    okc, pred, _, and_val, z := pm_icmp(cmp);
    if !okc || !pm_zero(z) return NONE;
    if pred == ICMP_NE { pred = ICMP_EQ; t := tval; tval = fval; fval = t; }
    if pred != ICMP_EQ return NONE;
    oka, x, c1v := pm_binop(and_val, .AND);
    if !oka return NONE;
    ok1, c1 := pm_apint(c1v);
    if !ok1 || !pm_zero(tval) return NONE;
    oks, sx, c2v := pm_binop(fval, .SHL);
    if !oks || sx != x return NONE;
    ok2, c2 := pm_apint(c2v);
    if !ok2 return NONE;
    if !ap_is_mask(c1) || cast(u64) ap_clz(c1) != ap_zext_value(c2) return NONE;
    if !is_inst(fval) return NONE;
    set_nsw(fval, false);
    set_nuw(fval, false);
    return fval;
}

// ---------------------------------------------------------------- foldSelectICmpLshrAshr

ic_fold_select_icmp_lshr_ashr :: (ic_: Value_Id, tv_in: Value_Id, fv_in: Value_Id) -> Value_Id {
    tv := tv_in; fv := fv_in;
    pred := inst_pred(ic_);
    cl := op(ic_, 0); cr := op(ic_, 1);
    if !is_int_or_int_vector(vtype(cr)) return NONE;
    bw := scalar_bits(cr);
    if (pred != ICMP_SGT || !pm_specific_int_icmp(cr, ICMP_SGE, ap_all_ones(bw))) &&
       (pred != ICMP_SLT || !pm_specific_int_icmp(cr, ICMP_SGE, ap_zero(bw))) return NONE;
    if pred == ICMP_SLT { t := tv; tv = fv; fv = t; }
    ok1, x, y := pm_binop(tv, .LSHR);
    if !ok1 return NONE;
    ok2, x2, y2 := pm_binop(fv, .ASHR);
    if ok2 && x2 == x && y2 == y && cl == x {
        exact := is_exact(fv) && is_exact(tv);
        return icb_ashr(x, y, name_ref(vname(ic_)), exact);
    }
    return NONE;
}

// ---------------------------------------------------------------- foldSelectICmpAndBinOp

ic_fold_select_icmp_and_binop :: (cond_val: Value_Id, true_val: Value_Id, false_val: Value_Id, v_in: Value_Id, and_mask: APInt, create_and: bool) -> Value_Id {
    v := v_in;
    if !is_int_or_int_vector(vtype(true_val)) return NONE;
    c1_log := ap_log2(and_mask);
    y, binop: Value_Id;
    c2: APInt;
    need_xor: bool;
    m :: (bo: Value_Id, x: Value_Id) -> (bool, APInt) {
        if !ic_is_any_binop(bo) || op(bo, 0) != x return false, .{};
        ok, c := pm_power2_ap(op(bo, 1));
        return ok, c;
    }
    ok, c := m(false_val, true_val);
    if ok { y = true_val; binop = false_val; need_xor = false; c2 = c; }
    else {
        ok, c = m(true_val, false_val);
        if ok { y = false_val; binop = true_val; need_xor = true; c2 = c; }
        else return NONE;
    }
    idc := cf_binop_identity(inst_op(binop), vtype(binop), true);
    if idc == NONE || !is_null_value(idc) return NONE;
    c2_log := ap_log2(c2);
    need_shift := c1_log != c2_log;
    need_zext_trunc := scalar_bits(y) != scalar_bits(v);
    if cast(s32) need_shift + cast(s32) need_xor + cast(s32) need_zext_trunc + cast(s32) create_and >
       cast(s32) has_one_use(cond_val) + cast(s32) has_one_use(binop) return NONE;
    if create_and v = icb_and(v, cf_int(vtype(v), and_mask));
    if c2_log > c1_log {
        v = icb_zext_or_trunc(v, vtype(y));
        v = icb_shl_c(v, cast(u64) (c2_log - c1_log));
    } else if c1_log > c2_log {
        v = icb_lshr(v, const_int(vtype(v), cast(u64) (c1_log - c2_log)));
        v = icb_zext_or_trunc(v, vtype(y));
    } else {
        v = icb_zext_or_trunc(v, vtype(y));
    }
    if need_xor v = icb_xor(v, cf_int(vtype(v), c2));
    res := icb_binop(inst_op(binop), y, v);
    if ic_is_any_binop(res) copy_ir_flags(res, binop);
    return res;
}

// ---------------------------------------------------------------- foldSetClearBits

ic_fold_set_clear_bits :: (sel: Value_Id) -> Value_Id {
    cond := ic_sel_cond(sel); t := ic_sel_tv(sel); f := ic_sel_fv(sel);
    ty := vtype(sel);
    try :: (sel: Value_Id, cond: Value_Id, and_v: Value_Id, or_v: Value_Id, ty: Type_Id, or_is_true: bool) -> Value_Id {
        oka, x, nc := pm_binop(and_v, .AND);
        if !oka return NONE;
        ok1, notc := pm_apint(nc);
        if !ok1 || !has_one_use(or_v) return NONE;
        oko, ox, cc := pm_binop(or_v, .OR);
        if !oko || ox != x return NONE;
        ok2, c := pm_apint(cc);
        if !ok2 || !ap_eq(notc, ap_not(c)) return NONE;
        zero := const_null_value(ty);
        orc := cf_int(ty, c);
        new_sel := ifx or_is_true then icb_select(cond, orc, zero, "masksel", sel) else icb_select(cond, zero, orc, "masksel", sel);
        return create_binop(.OR, and_v, new_sel);
    }
    r := try(sel, cond, t, f, ty, false); if r != NONE return r;
    r = try(sel, cond, f, t, ty, true); if r != NONE return r;
    return NONE;
}

// ---------------------------------------------------------------- foldSelectZeroOrFixedOp

ic_fold_select_zero_or_fixed_op :: (si: Value_Id) -> Value_Id {
    cond := ic_sel_cond(si); tv := ic_sel_tv(si); fv := ic_sel_fv(si);
    okc, pred, _, x, z := pm_icmp(cond);
    if !okc || !pm_zero(z) || !icmp_is_equality(pred) return NONE;
    if pred == ICMP_NE { t := tv; tv = fv; fv = t; }
    if !is_const(tv) || !is_inst(fv) return NONE;
    freeze_y: bool;
    y: Value_Id = NONE;
    found := false;
    {
        ok, o := pm_c_binop_with(fv, .MUL, x); if ok { y = o; found = true; }
        if !found { ok, o = pm_c_binop_with(fv, .AND, x); if ok { y = o; found = true; } }
        if !found {
            id := call_iid(fv);
            if (id == IID_FSHL || id == IID_FSHR) && op(fv, 0) == x && op(fv, 1) == x { y = op(fv, 2); found = true; }
        }
        if !found && call_iid(fv) == IID_UMIN {
            if op(fv, 0) == x { y = op(fv, 1); found = true; }
            else if op(fv, 1) == x { y = op(fv, 0); found = true; }
        }
        if found freeze_y = true;
        else {
            okd, a, b := pm_idiv(fv);
            if okd && a == x { y = b; found = true; }
            if !found { okd, a, b = pm_irem(fv); if okd && a == x { y = b; found = true; } }
            if !found return NONE;
            freeze_y = false;
        }
    }
    zero_c := op(cond, 1);
    merged := ce_merge_undefs_with(tv, zero_c);
    if !pm_zero(merged) && !pm_undef(merged) return NONE;
    if freeze_y {
        fr := ic_create_freeze(y);
        set_name(fr, tprint("%.fr", vname(y)));
        fr = ic_insert_new_inst_before(fr, fv);
        k: u32 = ifx op(fv, 0) == y then cast(u32) 0 else ifx op(fv, 1) == y then cast(u32) 1 else 2;
        ic_replace_operand(fv, k, fr);
    }
    return ic_replace_inst_uses_with(si, fv);
}

// ---------------------------------------------------------------- saturated arithmetic

// canonicalizeSaturatedSubtractUnsigned
ic_canonicalize_saturated_subtract_unsigned :: (ici: Value_Id, tv_in: Value_Id, fv_in: Value_Id) -> Value_Id {
    tv := tv_in; fv := fv_in;
    pred := inst_pred(ici);
    a := op(ici, 0); b := op(ici, 1);
    if pm_zero(tv) { pred = icmp_inverse(pred); t := tv; tv = fv; fv = t; }
    if !pm_zero(fv) return NONE;
    if pred == ICMP_NE {
        ok, x, y := pm_binop(tv, .ADD);
        if pm_zero(b) && ok && x == a && pm_all_ones(y) return icb_binary_intrinsic(IID_USUB_SAT, a, const_int(vtype(a), 1));
        return NONE;
    }
    if !icmp_is_unsigned(pred) return NONE;
    if pred == ICMP_ULE || pred == ICMP_ULT { t := a; a = b; b = t; pred = icmp_swapped(pred); }
    is_negative := false;
    oks, sx, sy := pm_binop(tv, .SUB);
    oka, ax, ay := pm_binop(tv, .ADD);
    if oks && sx == b && sy == a is_negative = true;
    else {
        okc, c := pm_apint(a);
        if okc && oka && ax == b && pm_specific_int_ap(ay, ap_neg(c)) is_negative = true;
        else {
            m1 := oks && sx == a && sy == b;
            okc2, c2 := pm_apint(b);
            m2 := okc2 && oka && ax == a && pm_specific_int_ap(ay, ap_neg(c2));
            if !m1 && !m2 return NONE;
        }
    }
    if is_negative && !has_one_use(tv) && !has_one_use(ici) return NONE;
    result := icb_binary_intrinsic(IID_USUB_SAT, a, b);
    if is_negative result = icb_neg(result);
    return result;
}
// canonicalizeSaturatedSubtractSigned
ic_canonicalize_saturated_subtract_signed :: (ici: Value_Id, tv_in: Value_Id, fv_in: Value_Id) -> Value_Id {
    tv := tv_in; fv := fv_in;
    pred := inst_pred(ici);
    cl := op(ici, 0); cr := op(ici, 1);
    if pred == ICMP_NE { pred = ICMP_EQ; t := tv; tv = fv; fv = t; }
    okn, nx := pm_neg(fv);
    if pred == ICMP_EQ && pm_sign_mask(cr) && pm_max_signed_value(tv) && okn && nx == cl
        return icb_binary_intrinsic(IID_SSUB_SAT, const_null_value(vtype(cl)), cl);
    return NONE;
}
// canonicalizeSaturatedSubtract
ic_canonicalize_saturated_subtract :: (ici: Value_Id, tv: Value_Id, fv: Value_Id) -> Value_Id {
    v := ic_canonicalize_saturated_subtract_unsigned(ici, tv, fv); if v != NONE return v;
    v = ic_canonicalize_saturated_subtract_signed(ici, tv, fv); if v != NONE return v;
    return NONE;
}
// canonicalizeSaturatedAddUnsigned
ic_canonicalize_saturated_add_unsigned :: (cmp: Value_Id, tval_in: Value_Id, fval_in: Value_Id) -> Value_Id {
    tval := tval_in; fval := fval_in;
    cmp0 := op(cmp, 0); cmp1 := op(cmp, 1);
    pred := inst_pred(cmp);
    if pm_all_ones(fval) { t := tval; tval = fval; fval = t; pred = icmp_inverse(pred); }
    if !pm_all_ones(tval) return NONE;
    oka, ax, ay := pm_binop(fval, .ADD);
    if pred == ICMP_EQ {
        if oka && ax == cmp0 && pm_one(ay) && pm_all_ones(cmp1)
            return icb_binary_intrinsic(IID_UADD_SAT, cmp0, const_int(vtype(cmp0), 1));
        return NONE;
    }
    okc, c := false, APInt.{};
    if oka && ax == cmp0 { okc, c = pm_apint(ay, true); }
    if (pred == ICMP_UGE || pred == ICMP_UGT) && okc && ic_pm_specific_int_allow_poison_ap(cmp1, ap_not(c))
        return icb_binary_intrinsic(IID_UADD_SAT, cmp0, cf_int(vtype(cmp0), c));
    if pred == ICMP_UGT && okc && ic_pm_specific_int_allow_poison_ap(cmp1, ap_sub(ap_not(c), ap_one(c.bits))) && !ap_is_all_ones(c)
        return icb_binary_intrinsic(IID_UADD_SAT, cmp0, cf_int(vtype(cmp0), c));
    if pred == ICMP_UGE && okc && ic_pm_specific_int_allow_poison_ap(cmp1, ap_neg(c)) && !ap_is_zero(c)
        return icb_binary_intrinsic(IID_UADD_SAT, cmp0, cf_int(vtype(cmp0), c));
    if pred == ICMP_UGT || pred == ICMP_UGE { t := cmp0; cmp0 = cmp1; cmp1 = t; pred = icmp_swapped(pred); }
    if pred != ICMP_ULT && pred != ICMP_ULE return NONE;
    okn, x := pm_not(cmp0);
    if okn {
        oky, y := pm_c_binop_with(fval, .ADD, x);
        if oky && y == cmp1 return icb_binary_intrinsic(IID_UADD_SAT, x, y);
    }
    x = cmp0;
    y := cmp1;
    if is_inst(fval) && inst_op(fval) == .ADD {
        for side: 0..1 {
            a := op(fval, cast(u32) side); b := op(fval, cast(u32) (1 - side));
            okk, nx := pm_not_forbid_poison(a);
            if okk && nx == x && b == y return icb_binary_intrinsic(IID_UADD_SAT, op(fval, 0), op(fval, 1));
        }
    }
    if pred == ICMP_ULT {
        ok1, yy := pm_c_binop_with(cmp0, .ADD, cmp1);
        if ok1 {
            ok2, y2 := pm_c_binop_with(fval, .ADD, cmp1);
            if ok2 && y2 == yy return icb_binary_intrinsic(IID_UADD_SAT, cmp1, yy);
        }
    }
    return NONE;
}
// m_SpecificIntAllowPoison(APInt)
ic_pm_specific_int_allow_poison_ap :: (v: Value_Id, c: APInt) -> bool {
    ok, x := pm_apint(v, true);
    return ok && x.bits == c.bits && ap_eq(x, c);
}
// canonicalizeSaturatedAddSigned
ic_canonicalize_saturated_add_signed :: (cmp: Value_Id, tval_in: Value_Id, fval_in: Value_Id) -> Value_Id {
    tval := tval_in; fval := fval_in;
    cmp0 := op(cmp, 0); cmp1 := op(cmp, 1);
    pred := inst_pred(cmp);
    if pm_max_signed_value(fval) || pm_sign_mask(fval) { t := tval; tval = fval; fval = t; pred = icmp_inverse(pred); }
    oks, sat_c := pm_apint(tval);
    if !oks || !(ap_is_max_signed(sat_c) || ap_is_sign_mask(sat_c)) return NONE;
    is_max := ap_is_max_signed(sat_c);
    oka, ax, ay := pm_binop(fval, .ADD);
    if pred == ICMP_EQ && cmp1 == tval {
        if is_max && oka && ax == cmp0 && pm_one(ay) return icb_binary_intrinsic(IID_SADD_SAT, cmp0, const_int(vtype(cmp0), 1));
        if !is_max && oka && ax == cmp0 && pm_all_ones(ay) return icb_binary_intrinsic(IID_SADD_SAT, cmp0, cf_all_ones(vtype(cmp0)));
        return NONE;
    }
    if is_max && (pred == ICMP_SGT || pred == ICMP_SGE) && is_const(cmp1) && oka && ax == cmp0 {
        okc, c := pm_apint_pred(ay, ap_is_strictly_positive);
        if okc {
            if pred == ICMP_SGE {
                okf, np, nc := flipped_strictness_predicate_and_constant(pred, cmp1);
                if okf { pred = np; cmp1 = nc; }
            }
            threshold := ap_sub(sat_c, c);
            if pred == ICMP_SGT && (ic_pm_specific_int_allow_poison_ap(cmp1, threshold) || ic_pm_specific_int_allow_poison_ap(cmp1, ap_sub(threshold, ap_one(threshold.bits))))
                return icb_binary_intrinsic(IID_SADD_SAT, cmp0, cf_int(vtype(cmp0), c));
        }
    }
    if !is_max && (pred == ICMP_SLT || pred == ICMP_SLE) && is_const(cmp1) && oka && ax == cmp0 {
        okc, c := pm_negative_ap(ay);
        if okc {
            if pred == ICMP_SLE {
                okf, np, nc := flipped_strictness_predicate_and_constant(pred, cmp1);
                if okf { pred = np; cmp1 = nc; }
            }
            threshold := ap_sub(sat_c, c);
            if pred == ICMP_SLT && (ic_pm_specific_int_allow_poison_ap(cmp1, threshold) || ic_pm_specific_int_allow_poison_ap(cmp1, ap_add(threshold, ap_one(threshold.bits))))
                return icb_binary_intrinsic(IID_SADD_SAT, cmp0, cf_int(vtype(cmp0), c));
        }
    }
    if pred == ICMP_SGT || pred == ICMP_SGE { t := cmp0; cmp0 = cmp1; cmp1 = t; pred = icmp_swapped(pred); }
    if pred != ICMP_SLT && pred != ICMP_SLE return NONE;
    if is_max {
        ok, a, x := pm_ob(cmp0, .SUB, F_NSW);
        if ok && pm_specific_int_ap(a, sat_c) {
            okk, o := pm_c_binop_with(fval, .ADD, x);
            if okk && o == cmp1 return icb_binary_intrinsic(IID_SADD_SAT, x, cmp1);
        }
    }
    if !is_max {
        ok, a, x := pm_ob(cmp1, .SUB, F_NSW);
        if ok && pm_specific_int_ap(a, sat_c) {
            okk, o := pm_c_binop_with(fval, .ADD, x);
            if okk && o == cmp0 return icb_binary_intrinsic(IID_SADD_SAT, x, cmp0);
        }
    }
    return NONE;
}
// canonicalizeSaturatedAdd
ic_canonicalize_saturated_add :: (cmp: Value_Id, tval: Value_Id, fval: Value_Id) -> Value_Id {
    if !has_one_use(cmp) return NONE;
    v := ic_canonicalize_saturated_add_unsigned(cmp, tval, fval); if v != NONE return v;
    v = ic_canonicalize_saturated_add_signed(cmp, tval, fval); if v != NONE return v;
    return NONE;
}

// ---------------------------------------------------------------- foldAbsDiff

ic_fold_abs_diff :: (cmp: Value_Id, tval: Value_Id, fval: Value_Id) -> Value_Id {
    ti := tval; fi := fval;
    if !is_inst(ti) || !is_inst(fi) return NONE;
    pred := cmp_strict(inst_pred(cmp));
    a := op(cmp, 0); b := op(cmp, 1);
    is_sub :: (v: Value_Id, x: Value_Id, y: Value_Id) -> bool { ok, p, q := pm_binop(v, .SUB); return ok && p == x && q == y; }
    is_nsw_sub :: (v: Value_Id, x: Value_Id, y: Value_Id) -> bool { ok, p, q := pm_ob(v, .SUB, F_NSW); return ok && p == x && q == y; }
    is_neg_of :: (v: Value_Id, x: Value_Id) -> bool { ok, z := pm_neg(v); return ok && z == x; }
    if is_sub(fi, a, b) { t := fi; fi = ti; ti = t; pred = icmp_swapped(pred); }
    if pred == ICMP_SGT && is_sub(ti, a, b) && is_sub(fi, b, a) && (has_nsw(ti) || has_nuw(ti)) && (has_nsw(fi) || has_nuw(fi)) {
        set_nuw(ti, false);
        if !has_nsw(ti) set_nsw(ti, has_one_use(ti));
        return icb_binary_intrinsic(IID_ABS, ti, get_true(ir.t_i1));
    }
    if pred == ICMP_SGT && is_nsw_sub(ti, a, b) && is_neg_of(fi, ti) return icb_binary_intrinsic(IID_ABS, ti, get_false(ir.t_i1));
    if pred == ICMP_SLT && is_nsw_sub(fi, a, b) && is_neg_of(ti, fi) return icb_binary_intrinsic(IID_ABS, fi, get_false(ir.t_i1));
    if pred == ICMP_SGT && is_nsw_sub(fi, b, a) && is_neg_of(ti, fi) return icb_binary_intrinsic(IID_ABS, fi, get_false(ir.t_i1));
    if pred == ICMP_SLT && is_nsw_sub(ti, b, a) && is_neg_of(fi, ti) return icb_binary_intrinsic(IID_ABS, ti, get_false(ir.t_i1));
    return NONE;
}

// ---------------------------------------------------------------- foldSelectCtlzToCttz / foldSelectCttzCtlz

ic_fold_select_ctlz_to_cttz :: (ici: Value_Id, tv_in: Value_Id, fv_in: Value_Id) -> Value_Id {
    tv := tv_in; fv := fv_in;
    bw := scalar_bits(tv);
    if !icmp_is_equality(inst_pred(ici)) || !pm_zero(op(ici, 1)) return NONE;
    if inst_pred(ici) == ICMP_NE { t := tv; tv = fv; fv = t; }
    ctlz: Value_Id;
    okx, xa, xb := pm_binop(fv, .XOR);
    if okx && pm_specific_int_allow_poison(xb, cast(u64) (bw - 1)) {
        ctlz = xa;
        if (bw & (bw - 1)) != 0 return NONE;
    } else {
        oks, sa, sb := pm_binop(fv, .SUB);
        if !oks || !pm_specific_int_allow_poison(sa, cast(u64) (bw - 1)) return NONE;
        ctlz = sb;
    }
    if call_iid(ctlz) != IID_CTLZ return NONE;
    if !pm_specific_int(tv, cast(u64) bw) return NONE;
    x := op(ici, 0);
    a0 := op(ctlz, 0);
    if !is_inst(a0) || inst_op(a0) != .AND return NONE;
    found := false;
    for side: 0..1 {
        p := op(a0, cast(u32) side); q := op(a0, cast(u32) (1 - side));
        okn, nx := pm_neg(q);
        if p == x && okn && nx == x { found = true; break; }
    }
    if !found return NONE;
    return create_intrinsic_call(IID_CTTZ, .[vtype(ctlz)], .[x, get_false(ir.t_i1)]);
}

ic_fold_select_cttz_ctlz :: (ici: Value_Id, tv: Value_Id, fv: Value_Id) -> Value_Id {
    pred := inst_pred(ici);
    cl := op(ici, 0); cr := op(ici, 1);
    if !icmp_is_equality(pred) return NONE;
    select_arg := fv; value_on_zero := tv;
    if pred == ICMP_NE { t := select_arg; select_arg = value_on_zero; value_on_zero = t; }
    count: Value_Id = NONE;
    okz, zx := pmi_cast(select_arg, .ZEXT);
    if okz count = zx;
    else { okt, tx := pmi_cast(select_arg, .TRUNC); if okt count = tx; else count = select_arg; }
    id := call_iid(count);
    if id != IID_CTTZ && id != IID_CTLZ return NONE;
    x := op(count, 0);
    okn, nx := pm_not(x);
    xor_match := false;
    if is_inst(x) && inst_op(x) == .XOR && ((op(x, 0) == cl && op(x, 1) == cr) || (op(x, 1) == cl && op(x, 0) == cr)) xor_match = true;
    if (x != cl || !pm_zero(cr)) && (!okn || nx != cl || !pm_all_ones(cr)) && !xor_match return NONE;
    ii := count;
    size_bits := scalar_bits(count);
    if pm_specific_int(value_on_zero, cast(u64) size_bits) {
        drop_poison_generating_annotations(ii);
        wl_add(ii);
        return select_arg;
    }
    if has_one_use(ii) && has_one_use(select_arg) && !pm_one(op(ii, 1)) {
        set_op(ii, 1, get_true(ir.t_i1));
        drop_ub_implying_attrs_and_metadata(ii);
        wl_add(ii);
    }
    return NONE;
}

// ---------------------------------------------------------------- canonicalizeSPF

// dropPoisonGeneratingAnnotationsForSPFCanonicalization
ic_drop_poison_generating_annotations_for_spf :: (cond: Value_Id, lhs: Value_Id, rhs: Value_Id) {
    if !implies_poison(lhs, cond) && is_inst(lhs) drop_poison_generating_annotations(lhs);
    if !implies_poison(rhs, cond) && is_inst(rhs) drop_poison_generating_annotations(rhs);
}

ic_canonicalize_spf :: (cmp: Value_Id, tv: Value_Id, fv: Value_Id) -> Value_Id {
    if !is_int_or_int_vector(vtype(tv)) return NONE;
    s, lhs, rhs, _ := match_decomposed_select_pattern_full(cmp, tv, fv, 0, false, 0);
    if s.flavor == .ABS || s.flavor == .NABS {
        if !has_one_use(cmp) && !has_one_use(rhs) return NONE;
        okn, nx := pm_nsw_neg(rhs);
        int_min_is_poison := s.flavor == .ABS && okn && nx == lhs;
        abs := icb_binary_intrinsic(IID_ABS, lhs, ic_bool_const(ir.t_i1, int_min_is_poison));
        if s.flavor == .NABS return icb_neg(abs);
        return abs;
    }
    if spf_is_min_or_max(s.flavor) {
        id := min_max_intrinsic(s.flavor);
        ic_drop_poison_generating_annotations_for_spf(cmp, lhs, rhs);
        return icb_binary_intrinsic(id, lhs, rhs);
    }
    return NONE;
}

// ---------------------------------------------------------------- replaceInInstruction

// isSafeToSpeculativelyExecuteWithVariableReplaced(I) (UseVariableInfo = false, IgnoreUBImplyingAttrs = true)
ic_is_safe_to_speculatively_execute_with_variable_replaced :: (i: Value_Id) -> bool {
    if inst_op(i) == .LOAD return false;
    return is_safe_to_speculatively_execute(i, true);
}

ic_replace_in_instruction :: (v: Value_Id, old: Value_Id, new: Value_Id, depth: u32 = 0) -> bool {
    if depth == 2 return false;
    i := v;
    if !is_inst(i) || !has_one_use(i) || !ic_is_safe_to_speculatively_execute_with_variable_replaced(i) return false;
    if is_vector_type(vtype(old)) && !is_not_cross_lane_operation(i) return false;
    changed := false;
    n := nops(i);
    for k: 0..n - 1 {
        u := ir.v_ops[i] + k;
        if ir.u_val[u] == old {
            ic_replace_use(u, new);
            wl_add(i);
            changed = true;
        } else {
            changed |= ic_replace_in_instruction(ir.u_val[u], old, new, depth + 1);
        }
    }
    return changed;
}

// ---------------------------------------------------------------- foldSelectValueEquivalence

ic_fold_select_value_equivalence :: (sel: Value_Id, cmp: Value_Id) -> Value_Id {
    tv := ic_sel_tv(sel); fv := ic_sel_fv(sel);
    swapped := false;
    if cmp_is_equivalence(cmp, true) { t := tv; tv = fv; fv = t; swapped = true; }
    else if !cmp_is_equivalence(cmp, false) return NONE;
    cl := op(cmp, 0); cr := op(cmp, 1);
    k: u32 = ifx swapped then cast(u32) 2 else 1;
    replace_old_with_new :: (sel: Value_Id, tv: Value_Id, old_op: Value_Id, new_op: Value_Id, cl: Value_Id, k: u32) -> Value_Id {
        if tv == old_op && (is_const(old_op) || !is_const(new_op)) return NONE;
        v := simplify_with_op_replaced_pub(tv, old_op, new_op, ic.sq, true);
        if v != NONE {
            if pm_imm_constant(v) && is_guaranteed_not_to_be_undef(v, ic.ac, sel, ic.dt) return ic_replace_operand(sel, k, v);
            contained := false;
            if is_inst(tv) for j: 0..nops(tv) - 1 if op(tv, j) == v { contained = true; break; }
            if pm_imm_constant(new_op) || contained {
                if is_guaranteed_not_to_be_undef(new_op, ic.ac, sel, ic.dt) return ic_replace_operand(sel, k, v);
                return NONE;
            }
        }
        if old_op == cl && pm_imm_constant(new_op) && !is_const(old_op) && is_guaranteed_not_to_be_undef(new_op, ic.ac, sel, ic.dt)
            if ic_replace_in_instruction(tv, old_op, new_op) return sel;
        return NONE;
    }
    can_l := can_replace_pointers_if_equal(cl, cr);
    if can_l { r := replace_old_with_new(sel, tv, cl, cr, cl, k); if r != NONE return r; }
    can_r := can_replace_pointers_if_equal(cr, cl);
    if can_r { r := replace_old_with_new(sel, tv, cr, cl, cl, k); if r != NONE return r; }
    if !is_inst(fv) return NONE;
    drop_flags: [..] Value_Id; drop_flags.allocator = temp;
    hit := can_l && simplify_with_op_replaced_pub(fv, cl, cr, ic.sq, false, *drop_flags) == tv;
    if !hit hit = can_r && simplify_with_op_replaced_pub(fv, cr, cl, ic.sq, false, *drop_flags) == tv;
    if hit {
        for drop_flags { drop_poison_generating_annotations(it); wl_add(it); }
        return ic_replace_inst_uses_with(sel, fv);
    }
    if is_int_or_int_vector_n(vtype(fv), 1) {
        okt, tx := pmi_cast(fv, .TRUNC);
        if okt && has_nuw(fv) && tx == cl && pm_imm_constant(cr) &&
           cfo_compare_inst_operands(ICMP_NE, cr, const_null_value(vtype(cl))) == tv
            return create_icmp(ICMP_NE, cl, const_null_value(vtype(cl)));
    }
    return NONE;
}

// ---------------------------------------------------------------- foldSelectEqualityTest

ic_fold_select_equality_test :: (sel: Value_Id) -> Value_Id {
    xeqz := ic_sel_cond(sel); yeqz := ic_sel_tv(sel);
    ok, x, z := pm_specific_icmp(xeqz, ICMP_EQ);
    if !ok return NONE;
    // m_c_SpecificICmp(EQ, m_Value(Y), m_Specific(Z))
    c_eq_with :: (v: Value_Id, z: Value_Id) -> (bool, Value_Id) {
        ok, a, b := pm_specific_icmp(v, ICMP_EQ);
        if !ok return false, NONE;
        if b == z return true, a;
        if a == z return true, b;
        return false, NONE;
    }
    oky, y := c_eq_with(yeqz, z);
    if !oky { t := x; x = z; z = t; }
    oky, y = c_eq_with(yeqz, z);
    if !oky return NONE;
    okl, la, lb := pm_logical_and(ic_sel_fv(sel));
    if !okl return NONE;
    xeqy: Value_Id = NONE;
    okn, nn := pm_not(la);
    if okn && nn == yeqz xeqy = lb;
    else { okn, nn = pm_not(lb); if okn && nn == yeqz xeqy = la; else return NONE; }
    okq, qa, qb := pm_specific_icmp(xeqy, ICMP_EQ);
    if !okq || !((qa == x && qb == y) || (qa == y && qb == x)) return NONE;
    set_flag(xeqy, F_EXACT, false);
    return ic_replace_inst_uses_with(sel, xeqy);
}

// ---------------------------------------------------------------- foldSPFofSPF

ic_fold_spf_of_spf :: (inner: Value_Id, spf1: Select_Flavor, a: Value_Id, b: Value_Id, outer: Value_Id, spf2: Select_Flavor, c: Value_Id) -> Value_Id {
    if vtype(outer) != vtype(inner) return NONE;
    if c == a || c == b {
        if spf1 == spf2 && spf_is_min_or_max(spf1) return ic_replace_inst_uses_with(outer, inner);
    }
    return NONE;
}

is_fp_or_fp_vector_ty :: (t: Type_Id) -> bool { return is_fp_type(scalar_type(t)); }

// ---------------------------------------------------------------- foldAddSubSelect

ic_fold_add_sub_select :: (si: Value_Id) -> Value_Id {
    cond := ic_sel_cond(si); ti := ic_sel_tv(si); fi := ic_sel_fv(si);
    if !is_inst(ti) || !is_inst(fi) || !has_one_use(ti) || !has_one_use(fi) return NONE;
    add_op, sub_op: Value_Id = NONE, NONE;
    to := inst_op(ti); fo := inst_op(fi);
    if (to == .SUB && fo == .ADD) || (to == .FSUB && fo == .FADD) { add_op = fi; sub_op = ti; }
    else if (fo == .SUB && to == .ADD) || (fo == .FSUB && to == .FADD) { add_op = ti; sub_op = fi; }
    if add_op == NONE return NONE;
    other: Value_Id = NONE;
    if op(sub_op, 0) == op(add_op, 0) other = op(add_op, 1);
    else if op(sub_op, 0) == op(add_op, 1) other = op(add_op, 0);
    if other == NONE return NONE;
    is_fp := is_fp_or_fp_vector_ty(vtype(si));
    neg_val: Value_Id;
    if is_fp {
        neg_val = icb_fneg(op(sub_op, 1));
        if is_inst(neg_val) set_fmf(neg_val, get_fmf(add_op) & get_fmf(sub_op));
    } else {
        neg_val = icb_neg(op(sub_op, 1));
    }
    nt := other; nf := neg_val;
    if add_op != ti { t := nt; nt = nf; nf = t; }
    new_sel := icb_select(cond, nt, nf, tprint("%.p", vname(si)), si);
    if is_fp {
        ri := create_binop(.FADD, op(sub_op, 0), new_sel);
        set_fmf(ri, get_fmf(add_op) & get_fmf(sub_op));
        return ri;
    }
    return create_binop(.ADD, op(sub_op, 0), new_sel);
}

// ---------------------------------------------------------------- foldOverflowingAddSubSelect

is_with_overflow_iid :: (id: Intrinsic_Id) -> bool {
    return id == IID_UADD_WITH_OVERFLOW || id == IID_SADD_WITH_OVERFLOW || id == IID_USUB_WITH_OVERFLOW ||
           id == IID_SSUB_WITH_OVERFLOW || id == IID_UMUL_WITH_OVERFLOW || id == IID_SMUL_WITH_OVERFLOW;
}

ic_fold_overflowing_add_sub_select :: (si: Value_Id) -> Value_Id {
    cond := ic_sel_cond(si); tv := ic_sel_tv(si); fv := ic_sel_fv(si);
    ok, ii := pm_extract_value_idx(cond, 1);
    if !ok || !is_with_overflow_iid(call_iid(ii)) return NONE;
    ok2, agg := pm_extract_value_idx(fv, 0);
    if !ok2 || agg != ii return NONE;
    x := op(ii, 0); y := op(ii, 1);
    is_signed_saturate_limit :: (limit: Value_Id, is_add: bool, x: Value_Id, y: Value_Id) -> bool {
        ty := vtype(limit);
        oks, c0, tv, fv := pm_select(limit);
        if !oks return false;
        okc, pred, _, o, cv := pm_icmp(c0);
        if !okc return false;
        okk, c := pm_apint(cv);
        if !okk return false;
        is_zero_or_one :: (c: APInt) -> bool { return ap_is_zero(c) || ap_is_one(c); }
        is_min_max :: (mn: Value_Id, mx: Value_Id, ty: Type_Id) -> bool {
            bw := type_bits(scalar_type(ty));
            return pm_specific_int_ap(mn, ap_signed_min(bw)) && pm_specific_int_ap(mx, ap_signed_max(bw));
        }
        if o != x && o != y return false;
        one := ap_one(c.bits);
        if is_add {
            if pred == ICMP_SLT && is_zero_or_one(c) && is_min_max(tv, fv, ty) return true;
            if pred == ICMP_SGT && is_zero_or_one(ap_add(c, one)) && is_min_max(fv, tv, ty) return true;
        } else {
            if o == x && pred == ICMP_SLT && is_zero_or_one(ap_add(c, one)) && is_min_max(tv, fv, ty) return true;
            if o == x && pred == ICMP_SGT && is_zero_or_one(ap_add_u64(c, 2)) && is_min_max(fv, tv, ty) return true;
            if o == y && pred == ICMP_SLT && is_zero_or_one(c) && is_min_max(fv, tv, ty) return true;
            if o == y && pred == ICMP_SGT && is_zero_or_one(ap_add(c, one)) && is_min_max(tv, fv, ty) return true;
        }
        return false;
    }
    id := call_iid(ii);
    new_id: Intrinsic_Id;
    if id == IID_UADD_WITH_OVERFLOW && pm_all_ones(tv) new_id = IID_UADD_SAT;
    else if id == IID_USUB_WITH_OVERFLOW && pm_zero(tv) new_id = IID_USUB_SAT;
    else if id == IID_SADD_WITH_OVERFLOW && is_signed_saturate_limit(tv, true, x, y) new_id = IID_SADD_SAT;
    else if id == IID_SSUB_WITH_OVERFLOW && is_signed_saturate_limit(tv, false, x, y) new_id = IID_SSUB_SAT;
    else return NONE;
    return create_intrinsic_call(new_id, .[vtype(si)], .[x, y]);
}

// ---------------------------------------------------------------- foldSelectExtConst

ic_fold_select_ext_const :: (sel: Value_Id) -> Value_Id {
    tv := ic_sel_tv(sel); fv := ic_sel_fv(sel);
    c: Value_Id = NONE;
    if is_const(tv) c = tv; else if is_const(fv) c = fv; else return NONE;
    ext: Value_Id = NONE;
    if is_inst(tv) ext = tv; else if is_inst(fv) ext = fv; else return NONE;
    eo := inst_op(ext);
    if eo != .ZEXT && eo != .SEXT return NONE;
    x := op(ext, 0);
    small := vtype(x);
    cond := ic_sel_cond(sel);
    if !is_int_or_int_vector_n(small, 1) && (!is_cmp_inst(cond) || vtype(op(cond, 0)) != small) return NONE;
    sel_type := vtype(sel);
    trunc_c := get_lossless_inv_cast(c, small, eo);
    if trunc_c != NONE && has_one_use(ext) {
        tcv := trunc_c;
        if ext == fv { t := x; x = tcv; tcv = t; }
        new_sel := icb_select(cond, x, tcv, "narrow", sel);
        return create_cast(eo, new_sel, sel_type);
    }
    return NONE;
}

// ---------------------------------------------------------------- canonicalizeSelectToShuffle

ic_canonicalize_select_to_shuffle :: (si: Value_Id) -> Value_Id {
    cond := ic_sel_cond(si);
    ct := vtype(cond);
    if type_kind(ct) != .VECTOR || !is_const(cond) return NONE;
    n := type_count(ct);
    mask := NewArray(cast(s64) n, u32,, allocator = temp);
    for e: 0..cast(s64) n - 1 {
        elt := cf_elt(cond, cast(u64) e);
        if elt == NONE return NONE;
        if is_one_value(elt) mask[e] = cast(u32) e;
        else if is_null_value(elt) mask[e] = cast(u32) (cast(u64) e + n);
        else return NONE;   // undef or a constant expression
    }
    return create_shuffle(ic_sel_tv(si), ic_sel_fv(si), mask);
}

// ---------------------------------------------------------------- canonicalizeScalarSelectOfVecs

ic_canonicalize_scalar_select_of_vecs :: (sel: Value_Id) -> Value_Id {
    ty := vtype(sel);
    if !is_vector_type(ty) return NONE;
    cond := ic_sel_cond(sel);
    if !has_one_use(cond) || !is_inst(cond) || inst_op(cond) != .EXTRACTELEMENT || vkind(op(cond, 1)) != .C_INT return NONE;
    return ic_replace_operand(sel, 0, icb_vector_splat(type_count(ty), type_kind(ty) == .SVECTOR, cond));
}

// ---------------------------------------------------------------- foldSelectCmpBitcasts

ic_fold_select_cmp_bitcasts :: (sel: Value_Id) -> Value_Id {
    cond := ic_sel_cond(sel); tval := ic_sel_tv(sel); fval := ic_sel_fv(sel);
    if !is_cmp_inst(cond) return NONE;
    a := op(cond, 0); b := op(cond, 1);
    if tval == a || tval == b || fval == a || fval == b return NONE;
    okc, c := pm_cast(a, .BITCAST);
    okd, d := pm_cast(b, .BITCAST);
    if !okc || !okd return NONE;
    okt, tsrc := pm_cast(tval, .BITCAST);
    okf, fsrc := pm_cast(fval, .BITCAST);
    if !okt || !okf return NONE;
    new_sel: Value_Id;
    if tsrc == c && fsrc == d new_sel = icb_select(cond, a, b, "", sel);
    else if tsrc == d && fsrc == c new_sel = icb_select(cond, b, a, "", sel);
    else return NONE;
    return create_cast(.BITCAST, new_sel, vtype(sel));
}

// ---------------------------------------------------------------- foldSelectCmpXchg

ic_fold_select_cmpxchg :: (si: Value_Id) -> Value_Id {
    is_extract_from_cmpxchg :: (v_in: Value_Id, idx: u32) -> Value_Id {
        v := v_in;
        if idx == 0 && is_inst(v) && inst_op(v) == .BITCAST v = op(v, 0);
        if !is_inst(v) || inst_op(v) != .EXTRACTVALUE return NONE;
        if inst_indices(v)[0] != idx return NONE;
        agg := op(v, 0);
        if !is_inst(agg) || inst_op(agg) != .CMPXCHG return NONE;
        return agg;
    }
    is_compare_same_as_value :: (cmp_val: Value_Id, sel_val: Value_Id) -> bool {
        if cmp_val == sel_val return true;
        okb, x := pm_cast(cmp_val, .BITCAST);
        if okb && x == sel_val return true;
        if vkind(cmp_val) == .C_INT && !is_vector_type(vtype(cmp_val)) && vkind(sel_val) == .C_FP && !is_vector_type(vtype(sel_val)) {
            a := const_ap(cmp_val);
            f := apf_from_const(sel_val);
            fw := apf_words(*f);
            fb := cast(u32) fp_type_bits(f.k);
            if fb != a.bits return false;
            return ap_eq(a, ap_from_words(fb, fw));
        }
        return false;
    }
    if has_one_use(si) {
        us := first_user(si);
        if is_inst(us) && inst_op(us) == .SELECT && op(us, 0) == ic_sel_cond(si) &&
           (op(us, 2) == ic_sel_tv(si) || op(us, 1) == ic_sel_fv(si)) return NONE;
    }
    cx := is_extract_from_cmpxchg(ic_sel_cond(si), 1);
    if cx == NONE return NONE;
    x := is_extract_from_cmpxchg(ic_sel_tv(si), 0);
    if x != NONE && x == cx && is_compare_same_as_value(op(x, 1), ic_sel_fv(si)) return ic_sel_fv(si);
    x = is_extract_from_cmpxchg(ic_sel_fv(si), 0);
    if x != NONE && x == cx && is_compare_same_as_value(op(x, 1), ic_sel_tv(si)) return ic_sel_fv(si);
    return NONE;
}

// ---------------------------------------------------------------- foldSelectFunnelShift

ic_fold_select_funnel_shift :: (sel: Value_Id) -> Value_Id {
    width := scalar_bits(sel);
    if width == 0 || (width & (width - 1)) != 0 return NONE;
    fv := ic_sel_fv(sel);
    if !has_one_use(fv) return NONE;
    oko, or0, or1 := pm_binop(fv, .OR);
    if !oko || !ic_is_any_binop(or0) || !ic_is_any_binop(or1) return NONE;
    logical_shift :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
        if !has_one_use(v) return false, NONE, NONE;
        o := inst_op(v);
        if o != .SHL && o != .LSHR return false, NONE, NONE;
        return true, op(v, 0), zext_or_self_i(op(v, 1));
    }
    ok0, sv0, sa0 := logical_shift(or0);
    ok1, sv1, sa1 := logical_shift(or1);
    if !ok0 || !ok1 || inst_op(or0) == inst_op(or1) return NONE;
    if inst_op(or0) == .LSHR {
        t := or0; or0 = or1; or1 = t;
        t = sv0; sv0 = sv1; sv1 = t;
        t = sa0; sa0 = sa1; sa1 = t;
    }
    opposite :: (sa: Value_Id, other: Value_Id, width: u32) -> bool {
        if !has_one_use(sa) return false;
        ok, a, b := pm_binop(sa, .SUB);
        return ok && pm_specific_int(a, cast(u64) width) && b == other;
    }
    sh_amt: Value_Id;
    if opposite(sa1, sa0, width) sh_amt = sa0;
    else if opposite(sa0, sa1, width) sh_amt = sa1;
    else return NONE;
    is_fshl := sh_amt == sa0;
    tval := ic_sel_tv(sel);
    if (is_fshl && tval != sv0) || (!is_fshl && tval != sv1) return NONE;
    cond := ic_sel_cond(sel);
    if !has_one_use(cond) return NONE;
    okc, ca, cb := pm_specific_icmp(cond, ICMP_EQ);
    if !okc || ca != sh_amt || !pm_zero_int(cb) return NONE;
    if sv0 != sv1 {
        if is_fshl && !is_guaranteed_not_to_be_poison(sv1) sv1 = icb_freeze(sv1);
        else if !is_fshl && !is_guaranteed_not_to_be_poison(sv0) sv0 = icb_freeze(sv0);
    }
    id := ifx is_fshl then IID_FSHL else IID_FSHR;
    get_or_insert_intrinsic_declaration(id, .[vtype(sel)]);
    sh_amt = icb_zext(sh_amt, vtype(sel));
    return create_intrinsic_call(id, .[vtype(sel)], .[sv0, sv1, sh_amt]);
}

// ---------------------------------------------------------------- foldSelectToCopysign

ic_fold_select_to_copysign :: (sel: Value_Id) -> Value_Id {
    cond := ic_sel_cond(sel); tval := ic_sel_tv(sel); fval := ic_sel_fv(sel);
    sel_type := vtype(sel);
    okt, tc := pm_apfloat(tval, true);
    if !okt return NONE;
    okf, fc := pm_apfloat(fval, true);
    if !okf return NONE;
    abs_t := fp_with_sign(tc.k, apf_words(*tc), false);
    abs_f := fp_with_sign(fc.k, apf_words(*fc), false);
    if abs_t.count != abs_f.count return NONE;
    for abs_t if it != abs_f[it_index] return NONE;
    if !has_one_use(cond) return NONE;
    okc, pred, _, l, r := pm_icmp(cond);
    if !okc return NONE;
    okb, x := pm_elementwise_bitcast(l);
    if !okb return NONE;
    oka, c := pm_apint(r);
    if !oka return NONE;
    oks, is_true_if_sign_set := is_sign_bit_check(pred, c);
    if !oks || vtype(x) != sel_type return NONE;
    if is_true_if_sign_set != apf_is_negative(tc) x = icb_fneg(x);
    mag := const_fp_words(sel_type, abs_t);
    get_or_insert_intrinsic_declaration(IID_COPYSIGN, .[sel_type]);
    return create_intrinsic_call(IID_COPYSIGN, .[sel_type], .[mag, x]);
}

// ---------------------------------------------------------------- foldVectorSelect

// ShuffleVectorInst::isSelect
ic_shuffle_is_select :: (sv: Value_Id) -> bool {
    mask := shuffle_mask(sv);
    n := cast(s64) type_count(vtype(op(sv, 0)));
    if type_kind(vtype(op(sv, 0))) != .VECTOR || mask.count != n return false;   // changesLength
    // isSingleSourceMaskImpl
    uses_lhs := false; uses_rhs := false;
    for m: mask {
        if m == 0xFFFF_FFFF continue;
        if cast(s64) m < n uses_lhs = true; else uses_rhs = true;
        if uses_lhs && uses_rhs break;
    }
    if !(uses_lhs && uses_rhs) return false;
    for m, i: mask {
        if m == 0xFFFF_FFFF continue;
        if cast(s64) m != i && cast(s64) m != n + i return false;
    }
    return true;
}

ic_fold_vector_select :: (sel: Value_Id) -> Value_Id {
    if !is_vector_type(vtype(sel)) return NONE;
    cond := ic_sel_cond(sel); tval := ic_sel_tv(sel); fval := ic_sel_fv(sel);
    okr, c := pm_intrinsic1(cond, IID_VECTOR_REVERSE);
    if okr {
        create_sel_reverse :: (sel: Value_Id, c: Value_Id, x: Value_Id, y: Value_Id) -> Value_Id {
            v := icb_select(c, x, y, name_ref(vname(sel)), sel);
            if is_inst(v) copy_ir_flags(v, sel);
            get_or_insert_intrinsic_declaration(IID_VECTOR_REVERSE, .[vtype(v)]);
            return create_intrinsic_call(IID_VECTOR_REVERSE, .[vtype(v)], .[v]);
        }
        okx, x := pm_intrinsic1(tval, IID_VECTOR_REVERSE);
        if okx {
            oky, y := pm_intrinsic1(fval, IID_VECTOR_REVERSE);
            if oky && (has_one_use(cond) || has_one_use(tval) || has_one_use(fval)) return create_sel_reverse(sel, c, x, y);
            if (has_one_use(cond) || has_one_use(tval)) && is_splat_value(fval) return create_sel_reverse(sel, c, x, fval);
        } else {
            oky, y := pm_intrinsic1(fval, IID_VECTOR_REVERSE);
            if is_splat_value(tval) && oky && (has_one_use(cond) || has_one_use(fval)) return create_sel_reverse(sel, c, tval, y);
        }
    }
    vt := vtype(sel);
    if type_kind(vt) != .VECTOR return NONE;
    n := type_count(vt);
    poison_elts := ap_zero(cast(u32) n);
    all_ones := ap_all_ones(cast(u32) n);
    v := ic_simplify_demanded_vector_elts(sel, all_ones, *poison_elts);
    if v != NONE {
        if v != sel return ic_replace_inst_uses_with(sel, v);
        return sel;
    }
    no_poison :: (m: [] u32) -> bool { for m if it == 0xFFFF_FFFF return false; return true; }
    if has_one_use(tval) {
        oks, x, y, mask := pm_shuffle(tval);
        if oks && no_poison(mask) && ic_shuffle_is_select(tval) {
            if x == fval { ns := icb_select(cond, y, x, "sel", sel); return create_shuffle(x, ns, mask); }
            if y == fval { ns := icb_select(cond, x, y, "sel", sel); return create_shuffle(ns, y, mask); }
        }
    }
    if has_one_use(fval) {
        oks, x, y, mask := pm_shuffle(fval);
        if oks && no_poison(mask) && ic_shuffle_is_select(fval) {
            if x == tval { ns := icb_select(cond, x, y, "sel", sel); return create_shuffle(x, ns, mask); }
            if y == tval { ns := icb_select(cond, y, x, "sel", sel); return create_shuffle(ns, y, mask); }
        }
    }
    return NONE;
}

// ---------------------------------------------------------------- foldSelectToPhi

// DominatorTree::dominates(BasicBlockEdge, BasicBlockEdge)
dt_dominates_edge_edge :: (dt: *Dom_Tree, s1: Value_Id, e1: Value_Id, s2: Value_Id, e2: Value_Id) -> bool {
    if s1 == s2 && e1 == e2 return true;
    return dt_dominates_edge_block(dt, s1, e1, s2);
}

ic_fold_select_to_phi_impl :: (sel: Value_Id, bb: Value_Id) -> Value_Id {
    dt := ic.dt;
    idom := dt_idom_block(dt, bb);
    if idom == NONE return NONE;
    cond := ic_sel_cond(sel);
    term := block_terminator(idom);
    if term == NONE || inst_op(term) != .CONDBR return NONE;
    if_true, if_false: Value_Id;
    bc := op(term, 0);
    okn, nc := pm_not(bc);
    if bc == cond { if_true = ic_sel_tv(sel); if_false = ic_sel_fv(sel); }
    else if okn && nc == cond { if_true = ic_sel_fv(sel); if_false = ic_sel_tv(sel); }
    else return NONE;
    true_succ := get_successor(term, 0); false_succ := get_successor(term, 1);
    if true_succ == false_succ return NONE;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    inputs: [..] Value_Id; inputs.allocator = temp;
    for p: preds {
        iv: Value_Id;
        if dt_dominates_edge_edge(dt, idom, true_succ, p, bb) iv = do_phi_translation(if_true, bb, p);
        else if dt_dominates_edge_edge(dt, idom, false_succ, p, bb) iv = do_phi_translation(if_false, bb, p);
        else return NONE;
        array_add(*inputs, iv);
        if is_inst(iv) && !dt_dominates_inst(dt, iv, block_terminator(p)) return NONE;
    }
    // DenseMap<BasicBlock*, Value*> Inputs: a predecessor that appears twice keeps its first value
    irb_set_at(*ic.b, bb, block_first(bb), true);
    pn := icb_phi(vtype(sel), cast(u32) ic_count_distinct(preds));
    for p: preds {
        v: Value_Id = NONE;
        for q: preds { if q == p { v = inputs[it_index]; break; } }
        phi_add_incoming(pn, v, p);
    }
    ic_take_name(pn, sel);
    return pn;
}
ic_count_distinct :: (a: [] Value_Id) -> s64 {
    n := 0;
    for x, i: a {
        seen := false;
        for j: 0..i - 1 if a[j] == x { seen = true; break; }
        if !seen n += 1;
    }
    return n;
}

ic_fold_select_to_phi :: (sel: Value_Id) -> Value_Id {
    cands: [..] Value_Id; cands.allocator = temp;
    array_add(*cands, inst_block(sel));
    for k: 0..2 {
        v := op(sel, cast(u32) k);
        if is_inst(v) array_add_if_unique(*cands, inst_block(v));
    }
    for bb: cands {
        pn := ic_fold_select_to_phi_impl(sel, bb);
        if pn != NONE return pn;
    }
    return NONE;
}

// ---------------------------------------------------------------- foldSelectWithSRem

ic_fold_select_with_srem :: (si: Value_Id) -> Value_Id {
    cond := ic_sel_cond(si); tv := ic_sel_tv(si); fv := ic_sel_fv(si);
    okc, pred, _, rem_res, cv := pm_icmp(cond);
    if !okc return NONE;
    oka, c := pm_apint(cv);
    if !oka return NONE;
    oks, true_if_signed := is_sign_bit_check(pred, c);
    if !oks return NONE;
    if !true_if_signed { t := tv; tv = fv; fv = t; }
    fold_to_bitwise_and :: (o: Value_Id, rem: Value_Id, rem_res: Value_Id) -> Value_Id {
        add := icb_add(rem, cf_all_ones(vtype(rem_res)));
        return create_binop(.AND, o, add);
    }
    okr, remainder := pm_c_binop_with(tv, .ADD, rem_res);
    if okr {
        ok2, o, d := pm_binop(rem_res, .SREM);
        if ok2 && d == remainder && ic_is_known_to_be_power_of_two(remainder, true, si) && fv == rem_res
            return fold_to_bitwise_and(o, remainder, rem_res);
    }
    if pm_one(tv) {
        ok2, o, d := pm_binop(rem_res, .SREM);
        if ok2 && pm_specific_int(d, 2) && fv == rem_res return fold_to_bitwise_and(o, const_int(vtype(rem_res), 2), rem_res);
    }
    return NONE;
}

// ---------------------------------------------------------------- simplifyNestedSelectsUsingImpliedCond / foldAndOrOfSelectUsingImpliedCond

ic_simplify_nested_selects_using_implied_cond :: (si: Value_Id, cond_val: Value_Id, cond_is_true: bool) -> Value_Id {
    implied := is_implied_condition(cond_val, ic_sel_cond(si), cond_is_true);
    if implied >= 0 return ifx implied == 1 then ic_sel_tv(si) else ic_sel_fv(si);
    return NONE;
}

ic_fold_and_or_of_select_using_implied_cond :: (o: Value_Id, si: Value_Id, is_and: bool) -> Value_Id {
    if vtype(ic_sel_cond(si)) != vtype(o) return NONE;
    v := ic_simplify_nested_selects_using_implied_cond(si, o, is_and);
    if v != NONE {
        t := vtype(o);
        return ic_create_select_unknown_profile(o, ifx is_and then v else get_true(t), ifx is_and then get_false(t) else v);
    }
    return NONE;
}

// ---------------------------------------------------------------- foldSelectWithFCmpToFabs

// canIgnoreSignBitOfNaN (ValueTracking.cpp)
can_ignore_sign_bit_of_nan :: (u: Use_Id) -> bool {
    user := ir.u_user[u];
    if is_fp_math_op_value(user) && (get_fmf(user) & FMF_NNAN) != 0 return true;
    if inst_op(user) == {
        case .FPTOSI; #through; case .FPTOUI; return true;
        case .FADD; #through; case .FSUB; #through; case .FMUL; #through; case .FDIV; #through; case .FREM; #through;
        case .FPTRUNC; #through; case .FPEXT; #through; case .FCMP; return true;
        case .FNEG; #through; case .SELECT; #through; case .PHI; return false;
        case .RET;
            f := inst_fn(user);
            a := attr_set_find(attr_list_ret(glob(f).attrs), .NoFPClass);
            return a != null && (cast(u32) a.ival & FC_NAN) != 0;
        case .CALL; #through; case .INVOKE;
            id := call_iid(user);
            if id != NOT_INTRINSIC {
                if id == {
                    case IID_FABS; return true;
                    case IID_COPYSIGN; return u - ir.v_ops[user] == 0;
                    case IID_MAXNUM; #through; case IID_MINNUM; #through; case IID_MAXIMUM; #through; case IID_MINIMUM; #through;
                    case IID_MAXIMUMNUM; #through; case IID_MINIMUMNUM; #through; case IID_CANONICALIZE; #through;
                    case IID_FMA; #through; case IID_FMULADD; #through; case IID_SQRT; #through; case IID_POW; #through;
                    case IID_POWI; #through; case IID_FPTOUI_SAT; #through; case IID_FPTOSI_SAT; #through;
                    case IID_IS_FPCLASS; #through; case IID_VP_IS_FPCLASS; return true;
                }
                return false;
            }
            k := u - ir.v_ops[user];
            m: u32 = 0;
            a := attr_set_find(attr_list_param(inst(user).attrs, k), .NoFPClass);
            if a m |= cast(u32) a.ival;
            f := call_called_function(user);
            if f != NONE { b := attr_set_find(attr_list_param(glob(f).attrs, k), .NoFPClass); if b m |= cast(u32) b.ival; }
            return (m & FC_NAN) != 0;
    }
    return false;
}
// IRBuilder::CreateFAbs(V, FMFSource)
icb_fabs :: (v: Value_Id, fmf_src: Value_Id) -> Value_Id { return icb_unary_intrinsic(IID_FABS, v, "", fmf_src); }

ic_fold_select_with_fcmp_to_fabs :: (si: Value_Id) -> Value_Id {
    cond := ic_sel_cond(si);
    changed_fmf := false;
    for swap: 0..1 {
        tv := ic_sel_tv(si); x := ic_sel_fv(si);
        if swap { t := tv; tv = x; x = t; }
        okc, pred, ca, cb := pm_fcmp(cond);
        if !okc || ca != x || !pm_any_zero_fp(cb) continue;
        oks, s0, s1 := pm_binop(tv, .FSUB);
        if oks && pm_pos_zero_fp(s0) && s1 == x &&
           (fmf_has(cond, FMF_NNAN) || fmf_has(si, FMF_NNAN) || (has_one_use(si) && can_ignore_sign_bit_of_nan(ir.v_first_use[si])) ||
            kfpc_is_known_never_nan(compute_known_fp_class(x, FC_NAN, ic_q(cond)))) {
            if !swap && (pred == FCMP_OLE || pred == FCMP_ULE) return ic_replace_inst_uses_with(si, icb_fabs(x, si));
            if swap && (pred == FCMP_OGT || pred == FCMP_UGT) return ic_replace_inst_uses_with(si, icb_fabs(x, si));
        }
        okn, nx := pm_fneg(tv);
        if !okn || nx != x return NONE;
        fmf := get_fmf(cond);
        if (fmf & FMF_NNAN) && !fmf_has(si, FMF_NNAN) { fmf_set_bit(si, FMF_NNAN, true); changed_fmf = true; }
        if (fmf & FMF_NINF) && !fmf_has(si, FMF_NINF) { fmf_set_bit(si, FMF_NINF, true); changed_fmf = true; }
        if !fmf_has(si, FMF_NNAN) && fmf_has(tv, FMF_NNAN) && (ifx swap then cmp_is_ordered(pred) else cmp_is_unordered(pred)) {
            fmf_set_bit(si, FMF_NNAN, true); changed_fmf = true;
        }
        if !fmf_has(si, FMF_NSZ) && (!has_one_use(si) || !can_ignore_sign_bit_of_zero(ir.v_first_use[si])) return NONE;
        if !fmf_has(si, FMF_NNAN) && (!has_one_use(si) || !can_ignore_sign_bit_of_nan(ir.v_first_use[si])) return NONE;
        if swap pred = cmp_swapped(pred);
        is_lt := pred == FCMP_OLT || pred == FCMP_OLE || pred == FCMP_ULT || pred == FCMP_ULE;
        is_gt := pred == FCMP_OGT || pred == FCMP_OGE || pred == FCMP_UGT || pred == FCMP_UGE;
        if is_lt return ic_replace_inst_uses_with(si, icb_fabs(x, si));
        if is_gt {
            fabs := icb_fabs(x, si);
            nf := new_inst(.FNEG, vtype(fabs), 1);
            set_op(nf, 0, fabs);
            set_fmf(nf, get_fmf(si));
            return nf;
        }
    }
    for swap: 0..1 {
        tv := ic_sel_tv(si); x := ic_sel_fv(si);
        if swap { t := tv; tv = x; x = t; }
        okc, pred, _, l, r := pm_icmp(cond);
        if !okc continue;
        okb, bx := pm_elementwise_bitcast(l);
        if !okb || bx != x continue;
        oka, c := pm_apint(r);
        if !oka continue;
        oks, true_if_signed := is_sign_bit_check(pred, c);
        if !oks continue;
        okn, nx := pm_fneg(tv);
        if !okn || nx != x return NONE;
        if (swap != 0) == true_if_signed && !has_one_use(cond) && !has_one_use(tv) return NONE;
        fabs := icb_fabs(x, si);
        if (swap != 0) != true_if_signed return ic_replace_inst_uses_with(si, fabs);
        return create_fneg_fmf(fabs, si);
    }
    return ifx changed_fmf then si else NONE;
}

// ---------------------------------------------------------------- foldSelectOfOrderedFAbsCmpOfNaNScrubbedValue


ic_fold_select_of_ordered_fabs_cmp_of_nan_scrubbed_value :: (si: Value_Id) -> Value_Id {
    outer := ic_sel_cond(si);
    if !has_one_use(outer) return NONE;
    okc, pred, cmp0, cmp1 := pm_fcmp(outer);
    if !okc || !cmp_is_ordered(pred) return NONE;
    y := ic_sel_fv(si);
    inner := ic_sel_tv(si);
    oks, ic_c, it, iff := pm_select(inner);
    if !oks || !has_one_use(ic_c) return NONE;
    okf, ip, x, z := pm_fcmp(ic_c);
    if !okf || ip != FCMP_ORD || !pm_any_zero_fp(z) || it != x || iff != y return NONE;
    fabs_i: Value_Id = NONE;
    match_fabs :: (v: Value_Id, inner: Value_Id) -> bool {
        if !has_one_use(v) return false;
        ok, a := pm_fabs(v);
        return ok && a == inner;
    }
    if match_fabs(cmp0, inner) fabs_i = cmp0;
    else {
        if !match_fabs(cmp1, inner) return NONE;
        fabs_i = cmp1;
        t := cmp0; cmp0 = cmp1; cmp1 = t;
        pred = cmp_swapped(pred);
    }
    fabs_fmf := get_fmf(fabs_i);
    cmp_fmf := get_fmf(outer);
    common := fmf_intersect_rewrite(fabs_fmf, cmp_fmf);
    new_fabs_fmf := common | fmf_union_value(fabs_fmf, 0);
    new_cmp_fmf := common | fmf_union_value(cmp_fmf, 0);
    new_fabs_fmf &= ~cast(u32) FMF_NNAN;
    new_cmp_fmf &= ~cast(u32) FMF_NNAN;
    new_abs := icb_fabs_fmf(x, new_fabs_fmf);
    saved := ic.b_fmf; ic.b_fmf = new_cmp_fmf;
    new_cmp := icb_cmp(pred, new_abs, cmp1);
    ic.b_fmf = get_fmf(si);
    new_sel := icb_select(new_cmp, x, y, "", si);
    ic.b_fmf = saved;
    return ic_replace_inst_uses_with(si, new_sel);
}

// ---------------------------------------------------------------- foldRoundUpIntegerWithPow2Alignment

ic_fold_round_up_integer_with_pow2_alignment :: (si: Value_Id) -> Value_Id {
    cond := ic_sel_cond(si);
    x := ic_sel_tv(si); xb := ic_sel_fv(si);
    okc, pred, _, xlow, z := pm_icmp(cond);
    if !okc || !pm_zero_int(z) || !icmp_is_equality(pred) return NONE;
    if pred == ICMP_NE { t := x; x = xb; xb = t; }
    oka, ax, am := pm_binop(xlow, .AND);
    if !oka || ax != x return NONE;
    okl, low := pm_apint(am, true);
    if !okl return NONE;
    bias, high: APInt;
    matched := false;
    ok1, p, q := pm_binop(xb, .AND);
    if ok1 {
        ok2, px, pc := pm_binop(p, .ADD);
        if ok2 && px == x {
            okb, b := pm_apint(pc, true);
            okh, h := pm_apint(q, true);
            if okb && okh { bias = b; high = h; matched = true; }
        }
    }
    if !matched {
        ok3, p2, q2 := pm_binop(xb, .ADD);
        if ok3 {
            ok4, px, pc := pm_binop(p2, .AND);
            if ok4 && px == x {
                okh, h := pm_apint(pc, true);
                okb, b := pm_apint(q2, true);
                if okh && okb { bias = b; high = h; matched = true; }
            }
        }
    }
    if !matched return NONE;
    if !ap_is_mask(low) return NONE;
    if !ap_eq(ap_not(low), high) return NONE;
    alignment := ap_add(low, ap_one(low.bits));
    if !ap_eq(bias, alignment) && !ap_eq(bias, low) return NONE;
    if !has_one_use(xb) {
        if ap_eq(bias, low) && implies_poison(xb, x) return xb;
        return NONE;
    }
    ty := vtype(x);
    xoff := icb_add(x, cf_int(ty, low), tprint("%.biased", vname(x)));
    r := icb_and(xoff, cf_int(ty, high));
    ic_take_name(r, si);
    return r;
}

// ---------------------------------------------------------------- foldSelectOfSymmetricSelect / foldNestedSelects

ic_fold_select_of_symmetric_select :: (outer: Value_Id) -> Value_Id {
    oc := ic_sel_cond(outer); a := ic_sel_tv(outer); b := ic_sel_fv(outer);
    if !has_one_use(a) return NONE;
    oka, ic1, itv, ifv := pm_select(a);
    if !oka || !has_one_use(b) return NONE;
    okb, ic2, b1, b2 := pm_select(b);
    if !okb || ic2 != ic1 || b1 != ifv || b2 != itv return NONE;
    if vtype(oc) != vtype(ic1) return NONE;
    x := icb_xor(ic1, oc);
    return create_select(x, ifv, itv);
}

ic_fold_nested_selects :: (outer: Value_Id) -> Value_Id {
    o_cond := ic_sel_cond(outer); o_tv := ic_sel_tv(outer); o_fv := ic_sel_fv(outer);
    okn, nc := pm_not(o_cond);
    if okn { o_cond = nc; t := o_tv; o_tv = o_fv; o_fv = t; }
    okl, _, _ := pm_logical_op(o_cond);
    if !okl return NONE;
    is_and, _, _ := pm_logical_and(o_cond);
    inner_val := ifx is_and then o_fv else o_tv;
    if !has_one_use(ic_sel_cond(outer)) && !has_one_use(inner_val) return NONE;
    oki, i_cond, i_tv, i_fv := pm_select(inner_val);
    if !oki return NONE;
    okn2, nc2 := pm_not(i_cond);
    if okn2 { i_cond = nc2; t := i_tv; i_tv = i_fv; i_fv = t; }
    // matchOuterCond: m_c_LogicalAnd / m_c_LogicalOr with one side matching `m`, binding the other as AltCond
    match_outer :: (o_cond: Value_Id, is_and: bool, want: Value_Id, want_not_of: bool) -> (bool, Value_Id, Value_Id) {
        ok: bool; a, b: Value_Id;
        if is_and { ok, a, b = pm_logical_and(o_cond); } else { ok, a, b = pm_logical_or(o_cond); }
        if !ok return false, NONE, NONE;
        m :: (v: Value_Id, want: Value_Id, want_not_of: bool) -> bool {
            if !want_not_of return v == want;
            okn, x := pm_not(v);
            return okn && x == want;
        }
        if m(a, want, want_not_of) return true, b, a;
        if m(b, want, want_not_of) return true, a, b;
        return false, NONE, NONE;
    }
    ok1, alt, _ := match_outer(o_cond, is_and, i_cond, false);
    if !ok1 {
        ok2, alt2, not_inner := match_outer(o_cond, is_and, i_cond, true);
        if !ok2 return NONE;
        alt = alt2;
        t := i_tv; i_tv = i_fv; i_fv = t;
        i_cond = not_inner;
    }
    sel_inner := icb_select(alt, ifx is_and then o_tv else i_fv, ifx is_and then i_tv else o_fv);
    ic_take_name(sel_inner, inner_val);
    return create_select(i_cond, ifx is_and then sel_inner else i_tv, ifx !is_and then sel_inner else i_fv);
}

// ---------------------------------------------------------------- canonicalizeClampLike

ic_canonicalize_clamp_like :: (sel0: Value_Id, cmp0: Value_Id) -> Value_Id {
    x := ic_sel_tv(sel0); sel1 := ic_sel_fv(sel0);
    if !has_one_use(cmp0) return NONE;
    pred0 := inst_pred(cmp0);
    cmp00 := op(cmp0, 0);
    c0 := op(cmp0, 1);
    if !pm_any_integral_constant(c0) || !is_const(c0) return NONE;
    if !is_select_inst(sel1) { pred0 = icmp_inverse(pred0); t := x; x = sel1; sel1 = t; }
    bw0 := scalar_bits(c0);
    if pred0 == {
        case ICMP_ULT; #through; case ICMP_UGE;
            if !pm_specific_int_icmp(c0, ICMP_NE, ap_zero(bw0)) return NONE;
        case ICMP_ULE; #through; case ICMP_UGT;
            if !pm_specific_int_icmp(c0, ICMP_NE, ap_all_ones(bw0)) return NONE;
            pred0 = icmp_flipped_strictness(pred0);
            c0 = ic_add_one(c0);
        case; return NONE;
    }
    if !has_one_use(sel1) return NONE;
    if vtype(cmp00) != vtype(x) && has_one_use(x) x = trunc_or_self_i(x);
    c1: Value_Id;
    if cmp00 == x c1 = const_null_value(vtype(x));
    else {
        ok, a, b := pm_binop(cmp00, .ADD);
        if !ok || a != x || !pm_any_integral_constant(b) || !is_const(b) return NONE;
        c1 = b;
    }
    oks, cmp1, rlow, rhigh := pm_select(sel1);
    if !oks return NONE;
    okc, pred1, _, cx, c2 := pm_icmp(cmp1);
    if !okc || cx != x || !pm_any_integral_constant(c2) || !is_const(c2) return NONE;
    if !has_one_use(cmp1) && (cmp00 == x || !has_one_use(cmp00)) return NONE;
    if pred1 == {
        case ICMP_SLT;
        case ICMP_SLE; return NONE;
        case ICMP_SGT;
            if !pm_specific_int_icmp(c2, ICMP_NE, ap_signed_max(scalar_bits(c2))) return NONE;
            c2 = ic_add_one(c2);
            pred1 = ICMP_SLT; t := rlow; rlow = rhigh; rhigh = t;
        case ICMP_SGE;
            pred1 = ICMP_SLT; t := rlow; rlow = rhigh; rhigh = t;
        case; return NONE;
    }
    th_low := ce_neg(c1);
    th_high := ce_binop(.SUB, c0, c1, 0);
    if pred0 == ICMP_UGE { t := th_low; th_low = th_high; th_high = t; }
    p1 := cfo_compare_inst_operands(ICMP_SGE, c2, th_low);
    if p1 == NONE || !pm_one(p1) return NONE;
    p2 := cfo_compare_inst_operands(ICMP_SLE, c2, th_high);
    if p2 == NONE || !pm_one(p2) return NONE;
    if vtype(x) != vtype(sel0) {
        if !pm_imm_constant(rlow) || !pm_imm_constant(rhigh) return NONE;
        rlow = cfo_cast_operand(.SEXT, rlow, vtype(x));
        rhigh = cfo_cast_operand(.SEXT, rhigh, vtype(x));
    }
    should_low := icb_cmp(ICMP_SLT, x, th_low);
    should_high := icb_cmp(ICMP_SGE, x, th_high);
    maybe_low := icb_select(should_low, rlow, x);
    maybe_high := icb_select(should_high, rhigh, maybe_low);
    return icb_trunc(maybe_high, vtype(sel0));
}

// ---------------------------------------------------------------- tryToReuseConstantFromSelectInComparison

ic_try_to_reuse_constant_from_select_in_comparison :: (sel: Value_Id, cmp: Value_Id) -> Value_Id {
    if !has_one_use(cmp) return NONE;
    okc, pred, _, x, c0 := pm_icmp(cmp);
    if !okc || !pm_any_integral_constant(c0) || !is_const(c0) return NONE;
    if icmp_is_equality(pred) return NONE;
    if !is_canonical_predicate(pred) return NONE;
    if vtype(c0) != vtype(sel) return NONE;
    if pred == ICMP_ULT { ok, _, b := pm_binop(x, .ADD); if ok && is_const(b) return NONE; }
    sv0 := ic_sel_tv(sel); sv1 := ic_sel_fv(sel);
    if !pm_any_integral_constant(sv0) && !pm_any_integral_constant(sv1) return NONE;
    matches :: (c: Value_Id, a: Value_Id, b: Value_Id) -> bool { return const_is_element_wise_equal(c, a) || const_is_element_wise_equal(c, b); }
    if matches(c0, sv0, sv1) return NONE;
    okf, np, nc := flipped_strictness_predicate_and_constant(pred, c0);
    if !okf return NONE;
    if !matches(nc, sv0, sv1) return NONE;
    saved := ic.b; defer ic.b = saved;
    icb_set_insert_point(sel);
    new_cmp := icb_cmp(icmp_swapped(pred), x, nc, tprint("%.inv", vname(cmp)));
    ic_replace_operand(sel, 0, new_cmp);
    use_swap(op_use(sel, 1), op_use(sel, 2));
    swap_prof_metadata(sel);
    return sel;
}

// ---------------------------------------------------------------- foldSelectZeroOrOnes / foldSelectInstWithICmpConst

ic_fold_select_zero_or_ones :: (cmp: Value_Id, tval: Value_Id, fval: Value_Id) -> Value_Id {
    if !has_one_use(cmp) return NONE;
    ok, cmpc := pm_apint(op(cmp, 1), true);
    if !ok return NONE;
    x := op(cmp, 0);
    okt, tn := pm_neg(tval);
    if inst_pred(cmp) == ICMP_ULT && ap_eq_u64(cmpc, 2) && okt && tn == x && pm_all_ones(fval)
        return create_cast(.SEXT, icb_is_not_null(x), vtype(tval));
    okf, fn := pm_neg(fval);
    if inst_pred(cmp) == ICMP_UGT && ap_eq_u64(cmpc, 1) && okf && fn == x && pm_all_ones(tval)
        return create_cast(.SEXT, icb_is_not_null(x), vtype(tval));
    return NONE;
}

// ConstantRange::intrinsic for the min/max intrinsics
ic_cr_min_max_intrinsic :: (id: Intrinsic_Id, a: Const_Range, b: Const_Range) -> Const_Range {
    if id == {
        case IID_SMAX; return cr_smax_op(a, b);
        case IID_SMIN; return cr_smin_op(a, b);
        case IID_UMAX; return cr_umax_op(a, b);
        case IID_UMIN; return cr_umin_op(a, b);
    }
    fatal("internal: ConstantRange::intrinsic of a non-min/max intrinsic");
    return a;
}

ic_fold_select_inst_with_icmp_const :: (si: Value_Id, ici: Value_Id) -> Value_Id {
    okc, pred, _, v, cv := pm_icmp(ici);
    if !okc return NONE;
    okk, cmpc := pm_apint(cv);
    if !okk return NONE;
    tval := ic_sel_tv(si); fval := ic_sel_fv(si);
    if pred == ICMP_EQ && v == fval {
        one := ap_one(cmpc.bits);
        if ap_is_min_value(cmpc) && pm_specific_int_ap(tval, ap_add(cmpc, one)) return icb_binary_intrinsic(IID_UMAX, v, tval);
        if ap_is_max_value(cmpc) && pm_specific_int_ap(tval, ap_sub(cmpc, one)) return icb_binary_intrinsic(IID_UMIN, v, tval);
        if ap_is_min_signed(cmpc) && pm_specific_int_ap(tval, ap_add(cmpc, one)) return icb_binary_intrinsic(IID_SMAX, v, tval);
        if ap_is_max_signed(cmpc) && pm_specific_int_ap(tval, ap_sub(cmpc, one)) return icb_binary_intrinsic(IID_SMIN, v, tval);
    }
    o: Value_Id; c: APInt; cpred: u8;
    okt, ct := pm_apint(tval);
    okf, cf := pm_apint(fval);
    if okt && is_inst(fval) { o = fval; c = ct; cpred = pred; }
    else if is_inst(tval) && okf { o = tval; c = cf; cpred = icmp_inverse(pred); }
    else return NONE;
    inv := cr_exact_icmp_region(cpred, cmpc);
    if ic_is_any_binop(o) && op(o, 0) == v {
        oko, opc := pm_apint(op(o, 1));
        if oko {
            r := cr_binary_op(inv, inst_op(o), cr_single(opc));
            if cr_eq(r, cr_single(c)) { drop_poison_generating_flags(o); return o; }
        }
    }
    id := call_iid(o);
    if (id == IID_SMAX || id == IID_SMIN || id == IID_UMAX || id == IID_UMIN) && op(o, 0) == v {
        oko, opc := pm_apint(op(o, 1));
        if oko {
            r := ic_cr_min_max_intrinsic(id, inv, cr_single(opc));
            if cr_eq(r, cr_single(c)) { drop_poison_generating_annotations(o); return o; }
        }
    }
    return NONE;
}

// ---------------------------------------------------------------- foldSelectWithExtremeEqCond / foldSelectICmpEq

ic_fold_select_with_extreme_eq_cond :: (cl: Value_Id, cr: Value_Id, tv: Value_Id, fv: Value_Id) -> Value_Id {
    ty := vtype(cl);
    if is_ptr_type(scalar_type(ty)) return NONE;
    okc, pred, _, a, b0 := pm_icmp(fv);
    if !okc return NONE;
    b: Value_Id;
    if a == cl b = b0;
    else if b0 == cl { b = a; pred = icmp_swapped(pred); }
    else return NONE;
    okt, ta, trhs := pm_specific_icmp(tv, ICMP_NE);
    if !okt || ta != b return NONE;
    bw := type_bits(scalar_type(ty));
    c: APInt;
    if icmp_is_lt(pred) {
        c = ifx icmp_is_signed(pred) then ap_signed_min(bw) else ap_zero(bw);
    } else if icmp_is_gt(pred) {
        c = ifx icmp_is_signed(pred) then ap_signed_max(bw) else ap_all_ones(bw);
    } else return NONE;
    if !pm_specific_int_ap(cr, c) || !pm_specific_int_ap(trhs, c) return NONE;
    return create_icmp(pred, cl, b);
}

ic_fold_select_icmp_eq :: (si: Value_Id, ici: Value_Id) -> Value_Id {
    pred := inst_pred(ici);
    if !icmp_is_equality(pred) return NONE;
    tv := ic_sel_tv(si); fv := ic_sel_fv(si);
    if pred == ICMP_NE { t := tv; tv = fv; fv = t; }
    return ic_fold_select_with_extreme_eq_cond(op(ici, 0), op(ici, 1), tv, fv);
}

// ---------------------------------------------------------------- foldSelectWithConstOpToBinOp

ic_fold_select_with_const_op_to_binop :: (cmp: Value_Id, tv_in: Value_Id, fv_in: Value_Id) -> Value_Id {
    tv := tv_in; fv := fv_in;
    okc, pred, _, x, c1 := pm_icmp(cmp);
    if !okc || !is_const(c1) return NONE;
    if !icmp_is_relational(pred) return NONE;
    if is_const(tv) { t := fv; fv = tv; tv = t; pred = icmp_inverse(pred); }
    if !is_const(fv) || !has_one_use(tv) return NONE;
    c3 := fv;
    is_intrinsic: bool;
    opc: Opcode; iid: Intrinsic_Id;
    c2: Value_Id;
    if ic_is_any_binop(tv) {
        opc = inst_op(tv);
        is_intrinsic = false;
        if is_int_div_rem(opc) return NONE;
        if op(tv, 0) != x || !is_const(op(tv, 1)) return NONE;
        c2 = op(tv, 1);
    } else if call_iid(tv) != NOT_INTRINSIC {
        id := call_iid(tv);
        if !(id == IID_SMAX || id == IID_SMIN || id == IID_UMAX || id == IID_UMIN) || op(tv, 0) != x || !is_const(op(tv, 1)) return NONE;
        c2 = op(tv, 1);
        iid = id;
        is_intrinsic = true;
    } else return NONE;
    okf, fp, fc := flipped_strictness_predicate_and_constant(pred, c1);
    fold :: (is_intrinsic: bool, opc: Opcode, iid: Intrinsic_Id, l: Value_Id, r: Value_Id) -> Value_Id {
        if is_intrinsic return cfo_intrinsic(iid, .[l, r], vtype(l));
        return cfo_binary_op_operands(opc, l, r);
    }
    spf: Select_Flavor; rhs: Value_Id;
    if c3 == fold(is_intrinsic, opc, iid, c1, c2) { spf = get_select_pattern(pred, .NA, false).flavor; rhs = c1; }
    else if okf && c3 == fold(is_intrinsic, opc, iid, fc, c2) { spf = get_select_pattern(fp, .NA, false).flavor; rhs = fc; }
    else return NONE;
    mm := icb_binary_intrinsic(min_max_intrinsic(spf), x, rhs);
    if is_intrinsic return icb_binary_intrinsic(iid, mm, c2);
    bo := icb_binop(opc, mm, c2);
    if is_inst(bo) && (opc == .ADD || opc == .SUB || opc == .MUL) {
        if has_nsw(tv) && ic_will_not_overflow(opc, rhs, c2, bo, true) set_nsw(bo);
        if has_nuw(tv) && ic_will_not_overflow(opc, rhs, c2, bo, false) set_nuw(bo);
    }
    return bo;
}

// ---------------------------------------------------------------- foldICmpUSubSatWithAndForMostSignificantBitCmp

ic_fold_icmp_usub_sat_with_and_for_msb_cmp :: (si: Value_Id, ici: Value_Id) -> Value_Id {
    if !has_one_use(si) || !has_one_use(ici) return NONE;
    okc, pred, _, or_v, z := pm_icmp(ic_sel_cond(si));
    if !okc || !pm_zero(z) || !has_one_use(or_v) return NONE;
    oko, l, r := pm_binop(or_v, .OR);
    if !oko || !has_one_use(l) || !has_one_use(r) return NONE;
    oka, a, ca := pm_intrinsic2(l, IID_USUB_SAT);
    okb, b, cb := pm_intrinsic2(r, IID_USUB_SAT);
    if !oka || !okb return NONE;
    ok1, k1 := pm_apint(ca);
    ok2, k2 := pm_apint(cb);
    if !ok1 || !ok2 return NONE;
    tv := ic_sel_tv(si); fv := ic_sel_fv(si);
    if !((pred == ICMP_EQ && pm_zero(tv) && pm_sign_mask(fv)) || (pred == ICMP_NE && pm_sign_mask(tv) && pm_zero(fv))) return NONE;
    ty := vtype(a);
    bw := k1.bits;
    msb := ap_signed_min(bw);
    if ap_is_non_negative(k1) || ap_is_non_negative(k2) return NONE;
    one := ap_one(bw);
    adj1 := cf_int(ty, ap_add(ap_sub(k1, msb), one));
    adj2 := cf_int(ty, ap_add(ap_sub(k2, msb), one));
    na := icb_binary_intrinsic(IID_USUB_SAT, a, adj1);
    nb := icb_binary_intrinsic(IID_USUB_SAT, b, adj2);
    o := icb_or(na, nb);
    return create_binop(.AND, o, cf_int(ty, msb));
}

// ---------------------------------------------------------------- foldSelectInstWithICmp

ic_fold_select_inst_with_icmp :: (si: Value_Id, ici: Value_Id) -> Value_Id {
    v := ic_canonicalize_spf(ici, ic_sel_tv(si), ic_sel_fv(si)); if v != NONE return ic_replace_inst_uses_with(si, v);
    v = ic_fold_select_inst_with_icmp_const(si, ici); if v != NONE return ic_replace_inst_uses_with(si, v);
    v = ic_canonicalize_clamp_like(si, ici); if v != NONE return ic_replace_inst_uses_with(si, v);
    r := ic_try_to_reuse_constant_from_select_in_comparison(si, ici); if r != NONE return r;
    r = ic_fold_icmp_usub_sat_with_and_for_msb_cmp(si, ici); if r != NONE return r;
    tv := ic_sel_tv(si); fv := ic_sel_fv(si);
    pred := inst_pred(ici);
    cl := op(ici, 0); cr := op(ici, 1);
    r = ic_fold_select_icmp_eq(si, ici); if r != NONE return r;
    if pred == ICMP_SGT && pm_all_ones(cr) && !is_const(tv) && !is_const(fv) && has_one_use(ici) {
        saved := ic.b; defer ic.b = saved;
        icb_set_insert_point(si);
        is_neg := icb_cmp(ICMP_SLT, cl, const_null_value(vtype(cl)), name_ref(vname(ici)));
        ic_replace_operand(si, 0, is_neg);
        use_swap(op_use(si, 1), op_use(si, 2));
        swap_prof_metadata(si);
        return si;
    }
    v = ic_fold_select_icmp_min_max(ici, tv, fv, ic.sq); if v != NONE return ic_replace_inst_uses_with(si, v);
    r = ic_fold_select_icmp_and_and(vtype(si), ici, tv, fv); if r != NONE return r;
    v = ic_fold_select_icmp_and_zero_shl(ici, tv, fv); if v != NONE return ic_replace_inst_uses_with(si, v);
    r = ic_fold_select_ctlz_to_cttz(ici, tv, fv); if r != NONE return r;
    r = ic_fold_select_zero_or_ones(ici, tv, fv); if r != NONE return r;
    v = ic_fold_select_icmp_lshr_ashr(ici, tv, fv); if v != NONE return ic_replace_inst_uses_with(si, v);
    v = ic_fold_select_cttz_ctlz(ici, tv, fv); if v != NONE return ic_replace_inst_uses_with(si, v);
    v = ic_canonicalize_saturated_subtract(ici, tv, fv); if v != NONE return ic_replace_inst_uses_with(si, v);
    v = ic_canonicalize_saturated_add(ici, tv, fv); if v != NONE return ic_replace_inst_uses_with(si, v);
    v = ic_fold_abs_diff(ici, tv, fv); if v != NONE return ic_replace_inst_uses_with(si, v);
    v = ic_fold_select_with_const_op_to_binop(ici, tv, fv); if v != NONE return ic_replace_inst_uses_with(si, v);
    return NONE;
}

// ---------------------------------------------------------------- foldSelectOfBools

// impliesPoisonOrCond
ic_implies_poison_or_cond :: (val_assumed_poison: Value_Id, v: Value_Id, expected: bool) -> bool {
    if implies_poison(val_assumed_poison, v) return true;
    if is_inst(val_assumed_poison) && inst_op(val_assumed_poison) == .ICMP {
        icmp := val_assumed_poison;
        lhs := op(icmp, 0);
        ok1, c1 := pm_apint(op(icmp, 1), false);
        if (inst(icmp).flags & F_EXACT) != 0 && ok1 {
            okc, pred, _, vl, vr := pm_icmp(v);
            if okc && vl == lhs {
                ok2, c2 := pm_apint(vr, true);
                if ok2 {
                    bw := c1.bits;
                    crx := ifx ap_is_non_negative(c1) then cr_new(ap_signed_min(bw), ap_zero(bw)) else cr_new(ap_zero(bw), ap_signed_min(bw));
                    return cr_icmp(crx, ifx expected then pred else icmp_inverse(pred), cr_single(c2));
                }
            }
        }
    }
    okt, a := pmi_cast(val_assumed_poison, .TRUNC);
    if okt && has_nuw(val_assumed_poison) && is_guaranteed_not_to_be_poison(a) {
        k := known_bits(a, ic_q(val_assumed_poison));
        return ap_eq_u64(kb_max_value(k), 1);
    }
    return false;
}

// IRBuilder::CreateSelectWithUnknownProfile
icb_select_unknown_profile :: (c: Value_Id, t: Value_Id, f: Value_Id, name: string = "") -> Value_Id {
    r := icb_select(c, t, f, name);
    if is_select_inst(r) ic_set_unknown_profile_if_profiled(r);
    return r;
}

ic_fold_select_of_bools :: (si: Value_Id) -> Value_Id {
    cond := ic_sel_cond(si); tv := ic_sel_tv(si); fv := ic_sel_fv(si);
    sel_type := vtype(si);
    if !is_int_or_int_vector_n(sel_type, 1) || is_const(cond) || vtype(tv) != vtype(cond) return NONE;
    one := get_true(sel_type);
    zero := get_false(sel_type);
    if pm_one(tv) {
        if ic_implies_poison_or_cond(fv, cond, false) return create_binop(.OR, cond, fv);
        if has_one_use(cond) {
            oks, a, b1, b := pm_select(cond);
            if oks && pm_one(b1) && ic_implies_poison_or_cond(fv, b, false) {
                lor := icb_select(a, one, icb_or(b, fv));
                if is_inst(lor) ic_set_unknown_profile_if_profiled(lor);
                return ic_replace_inst_uses_with(si, lor);
            }
        }
        oka, a, b := pm_logical_and(cond);
        okc, c, d := pm_logical_and(fv);
        if oka && okc && (has_one_use(cond) || has_one_use(fv)) {
            cond_logic_and := is_select_inst(cond);
            false_logic_and := is_select_inst(fv);
            and_fact :: (common_in: Value_Id, inner_cond: Value_Id, inner_val: Value_Id, sel_first: bool, one: Value_Id, zero: Value_Id, a: Value_Id, cla: bool, fla: bool) -> Value_Id {
                common := common_in;
                inner_sel := icb_select_unknown_profile(inner_cond, one, inner_val);
                if sel_first { t := common; common = inner_sel; inner_sel = t; }
                if fla || (cla && common == a) return ic_create_select_unknown_profile(common, inner_sel, zero);
                return create_binop(.AND, common, inner_sel);
            }
            if a == c return and_fact(a, b, d, false, one, zero, a, cond_logic_and, false_logic_and);
            if a == d return and_fact(a, b, c, false, one, zero, a, cond_logic_and, false_logic_and);
            if b == c return and_fact(b, a, d, false, one, zero, a, cond_logic_and, false_logic_and);
            if b == d return and_fact(b, a, c, cond_logic_and && false_logic_and, one, zero, a, cond_logic_and, false_logic_and);
        }
    }
    if pm_zero(fv) {
        if ic_implies_poison_or_cond(tv, cond, true) return create_binop(.AND, cond, tv);
        if has_one_use(cond) {
            oks, a, b, z := pm_select(cond);
            if oks && pm_zero(z) && ic_implies_poison_or_cond(tv, b, true) {
                land := icb_select(a, icb_and(b, tv), zero);
                if is_inst(land) ic_set_unknown_profile_if_profiled(land);
                return ic_replace_inst_uses_with(si, land);
            }
        }
        oka, a, b := pm_logical_or(cond);
        okc, c, d := pm_logical_or(tv);
        if oka && okc && (has_one_use(cond) || has_one_use(tv)) {
            cond_logic_or := is_select_inst(cond);
            true_logic_or := is_select_inst(tv);
            or_fact :: (common_in: Value_Id, inner_cond: Value_Id, inner_val: Value_Id, sel_first: bool, one: Value_Id, zero: Value_Id, a: Value_Id, clo: bool, tlo: bool) -> Value_Id {
                common := common_in;
                inner_sel := icb_select_unknown_profile(inner_cond, inner_val, zero);
                if sel_first { t := common; common = inner_sel; inner_sel = t; }
                if tlo || (clo && common == a) return ic_create_select_unknown_profile(common, one, inner_sel);
                return create_binop(.OR, common, inner_sel);
            }
            if a == c return or_fact(a, b, d, false, one, zero, a, cond_logic_or, true_logic_or);
            if a == d return or_fact(a, b, c, false, one, zero, a, cond_logic_or, true_logic_or);
            if b == c return or_fact(b, a, d, false, one, zero, a, cond_logic_or, true_logic_or);
            if b == d return or_fact(b, a, c, cond_logic_or && true_logic_or, one, zero, a, cond_logic_or, true_logic_or);
        }
    }
    if tv == zero {
        not_cond := icb_not(cond, tprint("not.%", vname(cond)));
        nsi := ic_create_select_md_from(not_cond, fv, zero, si);
        swap_prof_metadata(nsi);
        return nsi;
    }
    if fv == one {
        not_cond := icb_not(cond, tprint("not.%", vname(cond)));
        nsi := ic_create_select_md_from(not_cond, one, tv, si);
        swap_prof_metadata(nsi);
        return nsi;
    }
    {
        okl, la, lb := pm_logical_and(si);
        if okl {
            oka, a := pm_not(la); okb, b := pm_not(lb);
            if oka && okb && (has_one_use(cond) || has_one_use(tv)) && vkind(a) != .C_EXPR && vkind(b) != .C_EXPR {
                nsi := icb_select(a, one, b, "", si);
                swap_prof_metadata(nsi);
                return create_not(nsi);
            }
        }
        okl, la, lb = pm_logical_or(si);
        if okl {
            oka, a := pm_not(la); okb, b := pm_not(lb);
            if oka && okb && (has_one_use(cond) || has_one_use(fv)) && vkind(a) != .C_EXPR && vkind(b) != .C_EXPR {
                nsi := icb_select(a, b, zero, "", si);
                swap_prof_metadata(nsi);
                return create_not(nsi);
            }
        }
    }
    {
        oks, a, o, b := pm_select(cond);
        if oks && pm_one(o) && pm_one(tv) && fv == b return ic_replace_operand(si, 0, a);
        oks2, a2, b2, z := pm_select(cond);
        if oks2 && pm_zero(z) && tv == b2 && pm_zero(fv) return ic_replace_operand(si, 0, a2);
    }
    {
        // ~(A & B) & (A | B) --> A ^ B  (m_c_LogicalAnd of m_Not(m_LogicalAnd(A, B)) and m_c_LogicalOr(A, B))
        okl, l0, l1 := pm_logical_and(si);
        if okl {
            for side: 0..1 {
                p := ifx side == 0 then l0 else l1;
                q := ifx side == 0 then l1 else l0;
                okn, inner := pm_not(p);
                if !okn continue;
                oki, a, b := pm_logical_and(inner);
                if !oki continue;
                oko, c, d := pm_logical_or(q);
                if oko && ((c == a && d == b) || (c == b && d == a)) return create_binop(.XOR, a, b);
            }
        }
    }
    if has_one_use(cond) && is_inst(cond) && inst_op(cond) == .OR {
        for side: 0..1 {
            p := op(cond, cast(u32) side); c := op(cond, cast(u32) (1 - side));
            okn, nx := pm_not(p);
            if okn && nx == tv {
                or_v := icb_select_unknown_profile(c, one, fv);
                return ic_create_select_unknown_profile(tv, or_v, zero);
            }
        }
    }
    if has_one_use(cond) {
        okc, c := pm_c_binop_with(cond, .AND, fv);
        if okc {
            not_c, _ := ic_get_freely_inverted(c, has_one_use(c), true);
            if not_c != NONE {
                or_v := icb_select_unknown_profile(not_c, one, tv);
                return ic_create_select_unknown_profile(fv, or_v, zero);
            }
        }
    }
    if has_one_use(cond) {
        okc, c := pm_c_binop_with(cond, .OR, tv);
        if okc {
            not_c, _ := ic_get_freely_inverted(c, has_one_use(c), true);
            if not_c != NONE {
                and_v := icb_select_unknown_profile(not_c, fv, zero);
                return ic_create_select_unknown_profile(tv, one, and_v);
            }
        }
    }
    if has_one_use(cond) && is_inst(cond) && inst_op(cond) == .AND {
        for side: 0..1 {
            c := op(cond, cast(u32) side); q := op(cond, cast(u32) (1 - side));
            okn, nx := pm_not(q);
            if okn && nx == fv {
                and_v := icb_select_unknown_profile(c, tv, zero);
                return ic_create_select_unknown_profile(fv, one, and_v);
            }
        }
    }
    if pm_zero(fv) || pm_one(tv) {
        is_and := pm_zero(fv);
        op1 := ifx is_and then tv else fv;
        okz, y := is_check_for_zero_and_mul_with_overflow(cond, op1, is_and);
        if okz {
            yv := ir.u_val[y];
            fi := ic_create_freeze(yv);
            set_name(fi, tprint("%.fr", vname(yv)));
            ic_insert_new_inst_before(fi, ir.u_user[y]);
            ic_replace_use(y, fi);
            return ic_replace_inst_uses_with(si, op1);
        }
        v := ic_fold_boolean_and_or(cond, op1, si, is_and, true);
        if v != NONE return ic_replace_inst_uses_with(si, v);
    }
    {
        oka, a, b := pm_logical_or(cond);
        if oka && pm_zero(fv) {
            r := is_implied_condition(tv, b, true);
            if r == 0 return ic_replace_operand(si, 0, a);
        }
        oka, a, b = pm_logical_or(tv);
        if oka && pm_zero(fv) {
            r := is_implied_condition(cond, b, true);
            if r == 0 return ic_replace_operand(si, 1, a);
        }
        if pm_one(tv) {
            okl, la, lb := pm_logical_and(fv);
            if okl {
                r := is_implied_condition(cond, lb, false);
                if r == 1 return ic_replace_operand(si, 2, la);
            }
        }
        okl, la, lb := pm_logical_and(cond);
        if okl && pm_one(tv) {
            r := is_implied_condition(fv, lb, false);
            if r == 1 return ic_replace_operand(si, 0, la);
        }
    }
    if pm_one(tv) {
        v := ic_fold_or_of_logical_ands(cond, fv);
        if v != NONE return v;
    }
    return NONE;
}

// ---------------------------------------------------------------- foldBitCeil

ic_is_safe_to_remove_bit_ceil_select :: (pred: u8, cond0: Value_Id, cond1: APInt, ctlz_op: Value_Id, bw: u32, should_drop_no_wrap: *bool) -> bool {
    cr := cr_exact_icmp_region(icmp_inverse(pred), cond1);
    should_drop_no_wrap.* = false;
    match_forward :: (ca: Value_Id, ctlz_op: Value_Id, cr: *Const_Range, sd: *bool) -> bool {
        if ctlz_op == ca return true;
        ok, a, b := pm_binop(ctlz_op, .ADD);
        if ok && a == ca { okc, c := pm_apint(b); if okc { sd.* = true; cr.* = cr_add(cr.*, cr_single(c)); return true; } }
        ok, a, b = pm_binop(ctlz_op, .SUB);
        if ok && b == ca { okc, c := pm_apint(a); if okc { sd.* = true; cr.* = cr_sub(cr_single(c), cr.*); return true; } }
        okn, nx := pm_not(ctlz_op);
        if okn && nx == ca { cr.* = cr_binary_not(cr.*); return true; }
        return false;
    }
    if match_forward(cond0, ctlz_op, *cr, should_drop_no_wrap) {
    } else {
        ok, ca, cb := pm_binop(cond0, .ADD);
        if !ok return false;
        okc, c := pm_apint(cb);
        if !okc return false;
        cr = cr_sub(cr, cr_single(c));
        if !match_forward(ca, ctlz_op, *cr, should_drop_no_wrap) return false;
    }
    int_max := ap_sub(ap_signed_min(bw), ap_one(bw));
    cr = cr_sub(cr, cr_single(ap_one(bw)));
    return cr_icmp(cr, ICMP_UGE, cr_single(int_max));
}

ic_fold_bit_ceil :: (si: Value_Id) -> Value_Id {
    sel_type := vtype(si);
    bw := scalar_bits(si);
    if bw == 0 || (bw & (bw - 1)) != 0 return NONE;
    fv := ic_sel_fv(si); tv := ic_sel_tv(si);
    okc, pred, _, cond0, c1v := pm_icmp(ic_sel_cond(si));
    if !okc return NONE;
    okk, cond1 := pm_apint(c1v);
    if !okk return NONE;
    if pm_one(tv) { t := fv; fv = tv; tv = t; pred = icmp_inverse(pred); }
    if !pm_one(fv) || !has_one_use(tv) return NONE;
    oks, one, sub := pm_binop(tv, .SHL);
    if !oks || !pm_one(one) || !has_one_use(sub) return NONE;
    oksub, w, ctlz := pm_binop(sub, .SUB);
    if !oksub || !pm_specific_int(w, cast(u64) bw) return NONE;
    if call_iid(ctlz) != IID_CTLZ return NONE;
    ctlz_op := op(ctlz, 0);
    should_drop: bool;
    if !ic_is_safe_to_remove_bit_ceil_select(pred, cond0, cond1, ctlz_op, bw, *should_drop) return NONE;
    if should_drop { set_nuw(ctlz_op, false); set_nsw(ctlz_op, false); }
    drop_poison_generating_annotations(ctlz);
    wl_add(ctlz);
    neg := icb_neg(ctlz);
    masked := icb_and(neg, const_int(sel_type, cast(u64) (bw - 1)));
    return create_binop(.SHL, const_int(sel_type, 1), masked);
}

// ---------------------------------------------------------------- foldSelectToCmp


ic_fold_select_to_cmp :: (si: Value_Id) -> Value_Id {
    tv := ic_sel_tv(si); fv := ic_sel_fv(si);
    okc, pred, _, lhs, rhs := pm_icmp(ic_sel_cond(si));
    if !okc return NONE;
    if !is_int_or_int_vector(vtype(lhs)) return NONE;
    if !is_const(tv) {
        if !is_const(fv) return NONE;
        pred = icmp_inverse(pred);
        t := tv; tv = fv; fv = t;
    }
    if cmp_is_non_strict(pred) {
        if !is_const(rhs) return NONE;
        okf, np, nc := flipped_strictness_predicate_and_constant(pred, rhs);
        if !okf return NONE;
        pred = np; rhs = nc;
    }
    if (icmp_is_gt(pred) && pm_all_ones(tv)) || (icmp_is_lt(pred) && pm_one(tv)) {
        pred = icmp_swapped(pred);
        t := lhs; lhs = rhs; rhs = t;
    }
    is_signed := icmp_is_signed(pred);
    replace := false;
    // m_c_ICmp(P, m_Specific(L), m_Specific(R)) -> predicate as if written (L, R)
    c_icmp :: (v: Value_Id, l: Value_Id, r: Value_Id) -> (bool, u8) {
        ok, p, _, a, b := pm_icmp(v);
        if !ok return false, 0;
        if a == l && b == r return true, p;
        if a == r && b == l return true, icmp_swapped(p);
        return false, 0;
    }
    if icmp_is_lt(pred) && pm_all_ones(tv) {
        okz, z := pmi_cast(fv, .ZEXT);
        if okz { ok, ep := c_icmp(z, lhs, rhs); if ok && (ep == ICMP_NE || icmp_swapped(ep) == pred) replace = true; }
    }
    if icmp_is_gt(pred) && pm_one(tv) {
        oks, z := pmi_cast(fv, .SEXT);
        if oks { ok, ep := c_icmp(z, lhs, rhs); if ok && (ep == ICMP_NE || icmp_swapped(ep) == pred) replace = true; }
    }
    if pred == ICMP_EQ && pm_zero(tv) {
        oks, ic2, itv, ifv := pm_select(fv);
        if oks {
            ok, fbp := c_icmp(ic2, lhs, rhs);
            ok1, inner_tv := pm_apint(itv);
            ok2, inner_fv := pm_apint(ifv);
            if ok && ok1 && ok2 {
                if !icmp_is_gt(fbp) { fbp = icmp_swapped(fbp); t := lhs; lhs = rhs; rhs = t; }
                if !ap_is_one(inner_tv) { t := inner_tv; inner_tv = inner_fv; inner_fv = t; t2 := lhs; lhs = rhs; rhs = t2; }
                if icmp_is_gt(fbp) && ap_is_one(inner_tv) && ap_is_all_ones(inner_fv) { is_signed = icmp_is_signed(fbp); replace = true; }
            }
        }
    }
    if pred == ICMP_EQ && pm_zero(tv) {
        okk, c := pm_apint(rhs);
        if okk {
            oks, ic2, itv, ifv := pm_select(fv);
            okc2, ip, _, il, ir_ := pm_icmp(ic2);
            ok1, inner_tv := pm_apint(itv);
            ok2, inner_fv := pm_apint(ifv);
            if oks && okc2 && il == lhs && ok1 && ok2 {
                if icmp_is_gt(ip) && ap_is_one(inner_tv) && ap_is_all_ones(inner_fv) {
                    is_signed = icmp_is_signed(ip);
                    can := ifx is_signed then !ap_is_min_signed(c) else !ap_is_min_value(c);
                    if can && pm_specific_int_ap(ir_, ap_sub(c, ap_one(c.bits))) replace = true;
                }
                if icmp_is_lt(ip) && ap_is_all_ones(inner_tv) && ap_is_one(inner_fv) {
                    is_signed = icmp_is_signed(ip);
                    can := ifx is_signed then !ap_is_max_signed(c) else !ap_is_max_value(c);
                    if can && pm_specific_int_ap(ir_, ap_add(c, ap_one(c.bits))) replace = true;
                }
            }
        }
    }
    id := ifx is_signed then IID_SCMP else IID_UCMP;
    if replace return ic_replace_inst_uses_with(si, icb_intrinsic(id, .[vtype(si), vtype(lhs)], .[lhs, rhs]));
    return NONE;
}

// ---------------------------------------------------------------- fmulByZeroIsZero / matchFMulByZeroIfResultEqZero / hasAffectedValue

ic_fmul_by_zero_is_zero :: (mul_val: Value_Id, fmf: u32, cxt: Value_Id) -> bool {
    k := compute_known_fp_class_fmf(mul_val, fmf, FC_NEGATIVE, ic_q(cxt));
    return kfpc_is_known_never_nan(k) && kfpc_is_known_never_infinity(k) && ((fmf & FMF_NSZ) != 0 || kfpc_sign_bit_is_zero_or_nan(k));
}

ic_match_fmul_by_zero_if_result_eq_zero :: (cmp0: Value_Id, cmp1: Value_Id, tv: Value_Id, cxt: Value_Id, select_is_nsz: bool) -> bool {
    if !pm_pos_zero_fp(cmp1) return false;
    ok, a, b := pm_binop(tv, .FMUL);
    if !ok return false;
    mul_rhs: Value_Id;
    if a == cmp0 mul_rhs = b; else if b == cmp0 mul_rhs = a; else return false;
    fmf := get_fmf(tv);
    if select_is_nsz fmf |= FMF_NSZ; else fmf &= ~cast(u32) FMF_NSZ;
    return ic_fmul_by_zero_is_zero(mul_rhs, fmf, cxt);
}

ic_has_affected_value :: (v: Value_Id, affected: [] Value_Id, depth_in: u32) -> bool {
    depth := depth_in;
    if depth == MAX_ANALYSIS_RECURSION_DEPTH return false;
    if depth != 0 { for affected if it == v return true; }
    if is_inst(v) {
        if inst_op(v) == .PHI {
            if depth == MAX_ANALYSIS_RECURSION_DEPTH - 1 return false;
            depth = MAX_ANALYSIS_RECURSION_DEPTH - 2;
        }
        for k: 0..nops(v) - 1 {
            o := op(v, k);
            if is_int_or_int_vector(vtype(o)) && ic_has_affected_value(o, affected, depth + 1) return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------- foldSelectIntoAddConstant

ic_fold_select_into_add_constant :: (si: Value_Id) -> Value_Id {
    if !is_fp_math_inst(si) || !fmf_has(si, FMF_NSZ) || !fmf_has(si, FMF_NNAN) return NONE;
    try_fold :: (si: Value_Id, pred: u8, x: Value_Id, z: Value_Id, fadd: Value_Id, c: Value_Id, swapped: bool) -> Value_Id {
        if !cmp_is_relational_any(pred) || !pm_any_zero_fp(z) return NONE;
        ok, a, b := pm_binop(fadd, .FADD);
        if !ok || a != x || b != c return NONE;
        new_select := icb_select(ic_sel_cond(si), ifx swapped then z else x, ifx swapped then x else z, "", si);
        ic_take_name(new_select, si);
        new_fadd := icb_binop(.FADD, new_select, c);
        ic_take_name(new_fadd, fadd);
        sf := get_fmf(si); af := get_fmf(fadd);
        nf := fmf_intersect_rewrite(sf, af) | fmf_union_value(sf, af);
        set_fmf(new_fadd, nf);
        set_fmf(new_select, nf);
        return new_fadd;
    }
    cond := ic_sel_cond(si);
    okf, pred, x, z := pm_fcmp(cond);
    if okf && has_one_use(cond) {
        tv := ic_sel_tv(si); fv := ic_sel_fv(si);
        if is_inst(tv) && has_one_use(tv) && is_const(fv) return try_fold(si, pred, x, z, tv, fv, false);
        if is_const(tv) && is_inst(fv) && has_one_use(fv) return try_fold(si, pred, x, z, fv, tv, true);
    }
    return NONE;
}
// CmpInst::isRelational for any predicate
cmp_is_relational_any :: (p: u8) -> bool {
    if is_fp_predicate(p) return !fcmp_is_equality(p);
    return icmp_is_relational(p);
}

// ---------------------------------------------------------------- foldSelectBitTest

ic_fold_select_bit_test :: (sel: Value_Id, cond_val: Value_Id, tv_in: Value_Id, fv_in: Value_Id) -> Value_Id {
    tv := tv_in; fv := fv_in;
    if is_vector_type(vtype(sel)) != is_vector_type(vtype(cond_val)) return NONE;
    v: Value_Id;
    and_mask: APInt;
    create_and := false;
    pred: u8;
    okc, p, _, cl, cr := pm_icmp(cond_val);
    if okc {
        pred = p;
        if icmp_is_equality(pred) {
            if !pm_zero(cr) return NONE;
            v = cl;
            oka, _, m := pm_binop(cl, .AND);
            if !oka return NONE;
            okp, and_rhs := pm_power2_ap(m);
            if !okp return NONE;
            and_mask = and_rhs;
        } else {
            okd, res := decompose_bit_test_icmp(cl, cr, pred);
            if !okd return NONE;
            and_mask = res.mask;
            v = res.x;
            k := known_bits(v, ic_q(sel));
            and_mask = ap_and(and_mask, kb_max_value(k));
            if !ap_is_power_of_2(and_mask) return NONE;
            pred = res.pred;
            create_and = true;
        }
    } else if is_inst(cond_val) && inst_op(cond_val) == .TRUNC {
        v = op(cond_val, 0);
        and_mask = ap_one(scalar_bits(v));
        pred = ICMP_NE;
        create_and = !has_nuw(cond_val);
    } else return NONE;
    if pred == ICMP_NE { t := tv; tv = fv; fv = t; }
    x := ic_fold_select_icmp_and(sel, cond_val, tv, fv, v, and_mask, create_and); if x != NONE return x;
    x = ic_fold_select_icmp_and_binop(cond_val, tv, fv, v, and_mask, create_and); if x != NONE return x;
    return NONE;
}

// ---------------------------------------------------------------- foldSelectNegNot

ic_fold_select_neg_not :: (si: Value_Id) -> Value_Id {
    cond := ic_sel_cond(si); tv := ic_sel_tv(si); fv := ic_sel_fv(si);
    t := vtype(si);
    if !is_int_or_int_vector(t) || is_int_or_int_vector_n(t, 1) return NONE;
    if is_vector_type(vtype(cond)) != is_vector_type(t) return NONE;
    match_neg_not :: (neg: Value_Id, not: Value_Id) -> (bool, Value_Id) {
        if !has_one_use(neg) return false, NONE;
        ok, x := pm_neg(neg);
        if !ok || !has_one_use(not) return false, NONE;
        okn, y := pm_not(not);
        if !okn || y != x return false, NONE;
        return true, x;
    }
    ok, x := match_neg_not(tv, fv);
    if ok {
        not_cond := icb_not(cond, tprint("not.%", vname(cond)));
        mask := icb_sext(not_cond, t);
        return create_binop(.SUB, mask, x);
    }
    ok, x = match_neg_not(fv, tv);
    if ok {
        mask := icb_sext(cond, t);
        return create_binop(.SUB, mask, x);
    }
    return NONE;
}

// Type::isIEEELikeFPTy
is_ieee_like_fp_type :: (t: Type_Id) -> bool { k := type_kind(t); return k == .HALF || k == .BFLOAT || k == .FLOAT || k == .DOUBLE || k == .FP128; }
kfpc_sign_bit_is_zero_or_nan :: (k: Known_FP_Class) -> bool { return kfpc_is_known_never(k, FC_NEGATIVE); }

// ---------------------------------------------------------------- visitSelectInst

ic_visit_select :: (si: Value_Id) -> Value_Id {
    cond_val := ic_sel_cond(si); true_val := ic_sel_tv(si); false_val := ic_sel_fv(si);
    sel_type := vtype(si);
    fmf: u32 = 0;
    if is_fp_math_inst(si) fmf = get_fmf(si);
    v := simplify_select_inst(cond_val, true_val, false_val, fmf, ic_q(si));
    if v != NONE return ic_replace_inst_uses_with(si, v);
    r := ic_canonicalize_select_to_shuffle(si); if r != NONE return r;
    r = ic_canonicalize_scalar_select_of_vecs(si); if r != NONE return r;
    {
        okp, px := pm_ctpop(false_val);
        oki, ia, ib := pm_specific_icmp(cond_val, ICMP_ULT);
        if okp && px == true_val && oki && ia == true_val && pm_specific_int(ib, 2) {
            drop_poison_generating_annotations(false_val);
            wl_add(false_val);
            return ic_replace_inst_uses_with(si, false_val);
        }
    }
    cond_type := vtype(cond_val);
    if !is_const(cond_val) && is_int_or_int_vector(sel_type) && is_vector_type(cond_type) == is_vector_type(sel_type) {
        s := simplify_with_op_replaced_pub(true_val, cond_val, get_true(cond_type), ic.sq, true);
        if s != NONE return ic_replace_operand(si, 1, s);
        s = simplify_with_op_replaced_pub(false_val, cond_val, get_false(cond_type), ic.sq, true);
        if s != NONE return ic_replace_operand(si, 2, s);
        if ic_replace_in_instruction(true_val, cond_val, get_true(cond_type)) ||
           ic_replace_in_instruction(false_val, cond_val, get_false(cond_type)) return si;
    }
    r = ic_fold_select_of_bools(si); if r != NONE return r;
    if is_int_or_int_vector(sel_type) && !is_int_or_int_vector_n(sel_type, 1) && is_vector_type(cond_type) == is_vector_type(sel_type) {
        if pm_one(true_val) && pm_zero(false_val) return create_cast(.ZEXT, cond_val, sel_type);
        if pm_all_ones(true_val) && pm_zero(false_val) return create_cast(.SEXT, cond_val, sel_type);
        if pm_zero(true_val) && pm_one(false_val) {
            nc := icb_not(cond_val, tprint("not.%", vname(cond_val)));
            return create_cast(.ZEXT, nc, sel_type);
        }
        if pm_zero(true_val) && pm_all_ones(false_val) {
            nc := icb_not(cond_val, tprint("not.%", vname(cond_val)));
            return create_cast(.SEXT, nc, sel_type);
        }
    }
    r = ic_fold_select_neg_not(si); if r != NONE return r;
    si_fpop := is_fp_math_inst(si);
    if is_inst(cond_val) && inst_op(cond_val) == .FCMP {
        fcmp := cond_val;
        pred := inst_pred(fcmp);
        cmp0 := op(fcmp, 0); cmp1 := op(fcmp, 1);
        if (cmp0 == true_val && cmp1 == false_val) || (cmp0 == false_val && cmp1 == true_val) {
            if has_one_use(fcmp) && cmp_is_unordered(pred) {
                inv := cmp_inverse(pred);
                saved := ic.b_fmf;
                ic.b_fmf = get_fmf(fcmp);
                new_cond := icb_cmp(inv, cmp0, cmp1, tprint("%.inv", vname(fcmp)));
                f2 := get_fmf(si);
                if fmf_has(fcmp, FMF_NNAN) f2 |= FMF_NNAN;
                if fmf_has(fcmp, FMF_NINF) f2 |= FMF_NINF;
                ic.b_fmf = f2;
                new_sel := icb_select(new_cond, false_val, true_val);
                ic.b_fmf = saved;
                return ic_replace_inst_uses_with(si, new_sel);
            }
        }
        if si_fpop {
            m0, m1: Value_Id = NONE, NONE;
            if pred == FCMP_OEQ || pred == FCMP_UEQ { m0 = false_val; m1 = true_val; }
            else if pred == FCMP_ONE || pred == FCMP_UNE { m0 = true_val; m1 = false_val; }
            if cmp0 == m0 && ic_match_fmul_by_zero_if_result_eq_zero(cmp0, cmp1, m1, si, fmf_has(si, FMF_NSZ))
                return ic_replace_inst_uses_with(si, cmp0);
            elt := scalar_type(sel_type);
            if (pred == FCMP_ORD || pred == FCMP_UNO) && pm_pos_zero_fp(cmp1) && is_ieee_like_fp_type(elt) {
                if pred == FCMP_ORD { m0 = true_val; m1 = false_val; } else { m0 = false_val; m1 = true_val; }
                okd, d0, d1 := pm_binop(m1, .FDIV);
                rcp_if_nan := okd && pm_fp_one(d0) && d1 == cmp0;
                okcn, cx := pm_intrinsic1(m0, IID_CANONICALIZE);
                canon_if_not_nan := okcn && cx == cmp0;
                if rcp_if_nan || canon_if_not_nan {
                    mode := dm_of_fn(ic.f, elt);
                    if rcp_if_nan {
                        if dm_eq(mode, DM_IEEE) {
                            if canon_if_not_nan return ic_replace_inst_uses_with(si, cmp0);
                            if is_guaranteed_not_to_be_undef(cmp0, ic.ac, si, ic.dt) {
                                ic_replace_operand(si, ifx pred == FCMP_ORD then cast(u32) 2 else 1, cmp0);
                                return si;
                            }
                            fr := ic_create_freeze(cmp0);
                            set_name(fr, tprint("%.fr", vname(cmp0)));
                            fr = ic_insert_new_inst_before(fr, fcmp);
                            ic_replace_operand(fcmp, 0, fr);
                            return ic_replace_operand(si, ifx pred == FCMP_ORD then cast(u32) 2 else 1, fr);
                        }
                    }
                    if canon_if_not_nan {
                        if dm_eq(mode, DM_IEEE) {
                            ic_replace_operand(si, ifx pred == FCMP_ORD then cast(u32) 1 else 2, cmp0);
                            return si;
                        }
                        if rcp_if_nan && (dm_inputs_are_zero(mode) || dm_outputs_are_zero(mode))
                            return ic_replace_inst_uses_with(si, m0);
                    }
                }
            }
        }
    }
    if si_fpop {
        fcmp := ifx is_inst(cond_val) && inst_op(cond_val) == .FCMP then cond_val else NONE;
        if fcmp != NONE && fmf_has(fcmp, FMF_NNAN) &&
           (fmf_has(si, FMF_NSZ) || (has_one_use(si) && can_ignore_sign_bit_of_zero(ir.v_first_use[si]))) {
            for is_max: bool.[true, false] {
                ok: bool; x, y: Value_Id;
                if is_max { ok, x, y = pm_ord_or_unord_fmax(si); } else { ok, x, y = pm_ord_or_unord_fmin(si); }
                if !ok continue;
                bi := icb_binary_intrinsic(ifx is_max then IID_MAXNUM else IID_MINNUM, x, y, "", si);
                if is_inst(bi) {
                    fmf_set_bit(bi, FMF_NINF, fmf_has(fcmp, FMF_NINF));
                    fmf_set_bit(bi, FMF_NSZ, true);
                    fmf_set_bit(bi, FMF_NNAN, true);
                }
                return ic_replace_inst_uses_with(si, bi);
            }
        }
    }
    r = ic_fold_select_with_fcmp_to_fabs(si); if r != NONE return r;
    r = ic_fold_select_of_ordered_fabs_cmp_of_nan_scrubbed_value(si); if r != NONE return r;
    if is_cmp_inst(cond_val) { r = ic_fold_select_value_equivalence(si, cond_val); if r != NONE return r; }
    if is_inst(cond_val) && inst_op(cond_val) == .ICMP { r = ic_fold_select_inst_with_icmp(si, cond_val); if r != NONE return r; }
    v = ic_fold_select_bit_test(si, cond_val, true_val, false_val); if v != NONE return ic_replace_inst_uses_with(si, v);
    r = ic_fold_add_sub_select(si); if r != NONE return r;
    r = ic_fold_overflowing_add_sub_select(si); if r != NONE return r;
    r = ic_fold_set_clear_bits(si); if r != NONE return r;
    r = ic_fold_select_zero_or_fixed_op(si); if r != NONE return r;
    if is_inst(true_val) && is_inst(false_val) && inst_op(true_val) == inst_op(false_val) {
        r = ic_fold_select_op_op(si, true_val, false_val); if r != NONE return r;
    }
    r = ic_fold_select_intrinsic(si); if r != NONE return r;
    r = ic_fold_select_ext_const(si); if r != NONE return r;
    r = ic_fold_select_with_srem(si); if r != NONE return r;
    select_gep_with_base :: (si: Value_Id, gep: Value_Id, base: Value_Id, swap: bool, cond_val: Value_Id) -> Value_Id {
        if nops(gep) != 2 || op(gep, 0) != base || !has_one_use(gep) return NONE;
        idx := op(gep, 1);
        if is_vector_type(vtype(cond_val)) && !is_vector_type(vtype(idx)) return NONE;
        nt := idx; nf := const_null_value(vtype(idx));
        if swap { t := nt; nt = nf; nf = t; }
        nsi := icb_select(cond_val, nt, nf, tprint("%.idx", vname(si)), si);
        return ic_create_gep1(inst(gep).ty2, op(gep, 0), nsi, inst(gep).flags & cast(u32) (F_INBOUNDS | F_NUSW | F_GEP_NUW));
    }
    if is_inst(true_val) && inst_op(true_val) == .GEP { r = select_gep_with_base(si, true_val, false_val, false, cond_val); if r != NONE return r; }
    if is_inst(false_val) && inst_op(false_val) == .GEP { r = select_gep_with_base(si, false_val, true_val, true, cond_val); if r != NONE return r; }
    if is_int_or_int_vector(sel_type) || is_fp_or_fp_vector_ty(sel_type) {
        r = ic_fold_select_into_op(si, true_val, false_val); if r != NONE return r;
        spr, lhs, rhs, cast_op := match_select_pattern_cast(si, true);
        spf := spr.flavor;
        if spf != .UNKNOWN {
            s2, l2, r2 := match_select_pattern(lhs);
            if s2.flavor != .UNKNOWN { r = ic_fold_spf_of_spf(lhs, s2.flavor, l2, r2, si, spf, rhs); if r != NONE return r; }
            s2, l2, r2 = match_select_pattern(rhs);
            if s2.flavor != .UNKNOWN { r = ic_fold_spf_of_spf(rhs, s2.flavor, l2, r2, si, spf, lhs); if r != NONE return r; }
        }
        if spf_is_min_or_max(spf) {
            is_cast_needed := vtype(lhs) != sel_type;
            cmp_lhs := op(cond_val, 0); cmp_rhs := op(cond_val, 1);
            if is_cast_needed || (is_fp_or_fp_vector_ty(vtype(lhs)) && ((cmp_lhs != lhs && cmp_lhs != rhs) || (cmp_rhs != lhs && cmp_rhs != rhs))) {
                mm_pred := min_max_pred(spf, spr.ordered);
                cmp: Value_Id;
                if is_int_predicate(mm_pred) {
                    ic_drop_poison_generating_annotations_for_spf(cond_val, lhs, rhs);
                    cmp = icb_cmp(mm_pred, lhs, rhs);
                } else {
                    saved := ic.b_fmf; ic.b_fmf = get_fmf(cond_val);
                    cmp = icb_cmp(mm_pred, lhs, rhs);
                    ic.b_fmf = saved;
                }
                nsi := icb_select(cmp, lhs, rhs, name_ref(vname(si)), si);
                if !is_cast_needed return ic_replace_inst_uses_with(si, nsi);
                nc := icb_cast(cast_op, nsi, sel_type);
                return ic_replace_inst_uses_with(si, nc);
            }
        }
    }
    if is_phi(cond_val) { r = ic_fold_op_into_phi(si, cond_val); if r != NONE return r; }
    if is_select_inst(true_val) && vtype(ic_sel_cond(true_val)) == vtype(cond_val) {
        tsi := true_val;
        v = ic_simplify_nested_selects_using_implied_cond(tsi, cond_val, true);
        if v != NONE return ic_replace_operand(si, 1, v);
        if has_one_use(tsi) {
            and_v, other: Value_Id = NONE, NONE;
            if ic_sel_fv(tsi) == false_val {
                and_v = icb_select(cond_val, ic_sel_cond(tsi), get_false(vtype(ic_sel_cond(tsi))), "", si);
                other = ic_sel_tv(tsi);
            } else if ic_sel_tv(tsi) == false_val {
                inv := icb_not(ic_sel_cond(tsi));
                and_v = icb_select(cond_val, inv, get_false(vtype(inv)), "", si);
                other = ic_sel_fv(tsi);
            }
            if and_v != NONE && other != NONE {
                ic_replace_operand(si, 0, and_v);
                ic_replace_operand(si, 1, other);
                ic_set_unknown_profile_if_profiled(si);
                return si;
            }
        }
    }
    if is_select_inst(false_val) && vtype(ic_sel_cond(false_val)) == vtype(cond_val) {
        fsi := false_val;
        v = ic_simplify_nested_selects_using_implied_cond(fsi, cond_val, false);
        if v != NONE return ic_replace_operand(si, 2, v);
        if has_one_use(fsi) {
            or_v, other: Value_Id = NONE, NONE;
            if ic_sel_tv(fsi) == true_val {
                or_v = icb_select(cond_val, cf_all_ones(vtype(ic_sel_cond(fsi))), ic_sel_cond(fsi), "", si);
                other = ic_sel_fv(fsi);
            } else if ic_sel_fv(fsi) == true_val {
                inv := icb_not(ic_sel_cond(fsi));
                or_v = icb_select(cond_val, cf_all_ones(vtype(inv)), inv, "", si);
                other = ic_sel_tv(fsi);
            }
            if or_v != NONE && other != NONE {
                ic_replace_operand(si, 0, or_v);
                ic_replace_operand(si, 2, other);
                ic_set_unknown_profile_if_profiled(si);
                return si;
            }
        }
    }
    if has_one_use(true_val) && ic_is_any_binop(true_val) && !is_int_div_rem(inst_op(true_val)) {
        tbo := true_val;
        s0 := op(tbo, 0);
        if is_select_inst(s0) && ic_sel_cond(s0) == cond_val { ic_replace_operand(tbo, 0, ic_sel_tv(s0)); wl_push(tbo); return si; }
        s1 := op(tbo, 1);
        if is_select_inst(s1) && ic_sel_cond(s1) == cond_val { ic_replace_operand(tbo, 1, ic_sel_tv(s1)); wl_push(tbo); return si; }
    }
    if has_one_use(false_val) && ic_is_any_binop(false_val) && !is_int_div_rem(inst_op(false_val)) {
        fbo := false_val;
        s0 := op(fbo, 0);
        if is_select_inst(s0) && ic_sel_cond(s0) == cond_val { ic_replace_operand(fbo, 0, ic_sel_fv(s0)); wl_push(fbo); return si; }
        s1 := op(fbo, 1);
        if is_select_inst(s1) && ic_sel_cond(s1) == cond_val { ic_replace_operand(fbo, 1, ic_sel_fv(s1)); wl_push(fbo); return si; }
    }
    {
        okn, not_cond := pm_not(cond_val);
        if okn && !should_avoid_absorbing_not_into_select(si) {
            ic_replace_operand(si, 0, not_cond);
            use_swap(op_use(si, 1), op_use(si, 2));
            swap_prof_metadata(si);
            return si;
        }
    }
    r = ic_fold_vector_select(si); if r != NONE return r;
    if !is_vector_type(vtype(cond_val)) && ic.ac && ic.ac.assumes.count > 0 {
        k := ic_known_bits(cond_val, si);
        if ap_is_one(k.one) return ic_replace_inst_uses_with(si, true_val);
        if ap_is_one(k.zero) return ic_replace_inst_uses_with(si, false_val);
    }
    r = ic_fold_select_cmp_bitcasts(si); if r != NONE return r;
    v = ic_fold_select_cmpxchg(si); if v != NONE return ic_replace_inst_uses_with(si, v);
    r = ic_fold_select_binop_identity(si); if r != NONE return r;
    r = ic_fold_select_funnel_shift(si); if r != NONE return r;
    r = ic_fold_select_to_copysign(si); if r != NONE return r;
    r = ic_fold_select_to_phi(si); if r != NONE return ic_replace_inst_uses_with(si, r);
    v = ic_fold_round_up_integer_with_pow2_alignment(si); if v != NONE return ic_replace_inst_uses_with(si, v);
    v = ic_fold_select_into_add_constant(si); if v != NONE return ic_replace_inst_uses_with(si, v);
    is_masked_load_or_gather :: (v: Value_Id) -> bool { id := call_iid(v); return id == IID_MASKED_LOAD || id == IID_MASKED_GATHER; }
    undef_or_zero :: (v: Value_Id) -> bool { return pm_undef(v) || pm_zero(v); }
    if pm_zero(false_val) && is_masked_load_or_gather(true_val) && op(true_val, 1) == cond_val && undef_or_zero(op(true_val, 2)) {
        if pm_undef_value(op(true_val, 2)) set_op(true_val, 2, false_val);
        return ic_replace_inst_uses_with(si, true_val);
    }
    if pm_zero(true_val) && is_masked_load_or_gather(false_val) && undef_or_zero(op(false_val, 2)) && vtype(cond_val) == vtype(op(false_val, 1)) {
        mask := op(false_val, 1);
        can_merge := false;
        sv := simplify_and_inst(cond_val, mask, ic_q(si));
        if sv != NONE can_merge = pm_zero(sv);
        if can_merge {
            if pm_undef_value(op(false_val, 2)) set_op(false_val, 2, true_val);
            return ic_replace_inst_uses_with(si, false_val);
        }
    }
    r = ic_fold_select_of_symmetric_select(si); if r != NONE return r;
    r = ic_fold_nested_selects(si); if r != NONE return r;
    if ic_sink_not_into_other_hand_of_logical_op(si) return si;
    r = ic_fold_bit_ceil(si); if r != NONE return r;
    r = ic_fold_select_to_cmp(si); if r != NONE return r;
    r = ic_fold_select_equality_test(si); if r != NONE return r;
    fold_with_and_or_cond :: (si: Value_Id, is_and: bool, a: Value_Id, b: Value_Id, fmf: u32) -> Value_Id {
        tv := ic_sel_tv(si); fv := ic_sel_fv(si);
        v := simplify_select_inst(b, tv, fv, fmf, ic_q(si));
        if v != NONE {
            nt := ifx is_and then v else tv;
            nf := ifx is_and then fv else v;
            md_from := ifx nt == tv && nf == fv then si else NONE;
            return ic_create_select_md_from(a, nt, nf, md_from);
        }
        if has_one_use(ic_sel_cond(si)) && is_int_or_int_vector(vtype(si)) {
            if is_inst(b) && inst_op(b) == .ICMP {
                v = ic_canonicalize_spf(b, tv, fv);
                if v != NONE return ic_create_select_md_from(a, ifx is_and then v else tv, ifx is_and then fv else v, si);
            }
        }
        return NONE;
    }
    {
        oka, l, rr := pm_binop(cond_val, .AND);
        if oka {
            r = fold_with_and_or_cond(si, true, l, rr, fmf); if r != NONE return r;
            r = fold_with_and_or_cond(si, true, rr, l, fmf); if r != NONE return r;
        } else {
            oko, l2, r2 := pm_binop(cond_val, .OR);
            if oko {
                r = fold_with_and_or_cond(si, false, l2, r2, fmf); if r != NONE return r;
                r = fold_with_and_or_cond(si, false, r2, l2, fmf); if r != NONE return r;
            } else {
                okla, l3, r3 := pm_logical_and(cond_val);
                if okla { r = fold_with_and_or_cond(si, true, l3, r3, fmf); if r != NONE return r; }
                else {
                    oklo, l4, r4 := pm_logical_or(cond_val);
                    if oklo { r = fold_with_and_or_cond(si, false, l4, r4, fmf); if r != NONE return r; }
                }
            }
        }
    }
    if vtype(cond_val) == vtype(si) && is_known_inversion(false_val, true_val) return create_binop(.XOR, cond_val, false_val);
    if is_int_type(sel_type) && (!is_const(true_val) || !is_const(false_val)) {
        cc: Cond_Context;
        cc.cond = cond_val;
        cc.affected.allocator = temp;
        aff: [..] Affected; aff.allocator = temp;
        find_values_affected_by_condition(cond_val, false, *aff, 0);
        for aff array_add_if_unique(*cc.affected, it.v);
        q := ic_q(si);
        q.cc = *cc;
        if cc.affected.count > 0 {
            if !is_const(true_val) && ic_has_affected_value(true_val, cc.affected, 0) {
                k := known_bits(true_val, q);
                if kb_is_constant(k) return ic_replace_operand(si, 1, cf_int(sel_type, kb_constant(k)));
            }
            cc.invert = true;
            if !is_const(false_val) && ic_has_affected_value(false_val, cc.affected, 0) {
                k := known_bits(false_val, q);
                if kb_is_constant(k) return ic_replace_operand(si, 2, cf_int(sel_type, kb_constant(k)));
            }
        }
    }
    {
        okt, trunc := pmi_cast(cond_val, .TRUNC);
        if okt && has_nuw(cond_val) && !is_const(trunc) {
            if true_val == trunc return ic_replace_operand(si, 1, const_int(vtype(true_val), 1));
            if false_val == trunc return ic_replace_operand(si, 2, const_int(vtype(false_val), 0));
        }
        if okt && has_nsw(cond_val) && !is_const(trunc) {
            if true_val == trunc return ic_replace_operand(si, 1, cf_all_ones(vtype(true_val)));
            if false_val == trunc return ic_replace_operand(si, 2, const_int(vtype(false_val), 0));
        }
        if okt && vtype(trunc) == sel_type {
            if pm_zero(false_val) && implies_poison(true_val, cond_val) && kb_count_max_active_bits(known_bits(true_val, ic_q(si))) == 1
                return create_binop(.AND, trunc, true_val);
            if has_nuw(cond_val) && pm_one(true_val) && implies_poison(false_val, cond_val) && kb_count_max_active_bits(known_bits(false_val, ic_q(si))) == 1
                return create_binop(.OR, trunc, false_val);
        }
    }
    if has_one_use(true_val) && call_iid(true_val) == IID_MASKED_LOAD && op(true_val, 1) == cond_val {
        if dt_dominates_inst(ic.dt, false_val, true_val) {
            icb_set_insert_point(true_val);
            al := attr_set_find(attr_list_param(inst(true_val).attrs, 0), .Alignment);
            align: u64 = 1;
            if al align = al.ival;
            ptr := op(true_val, 0);
            ml := icb_intrinsic(IID_MASKED_LOAD, .[vtype(true_val), vtype(ptr)], .[ptr, cond_val, false_val]);
            add_param_align(ml, 0, align);
            return ic_replace_inst_uses_with(si, ml);
        }
    }
    {
        bw := scalar_bits(si);
        okc, pred, _, cl, cr := pm_icmp(cond_val);
        if okc {
            is_sign_ashr :: (v: Value_Id, cl: Value_Id, bw: u32) -> bool { ok, a, b := pm_binop(v, .ASHR); return ok && a == cl && pm_specific_int(b, cast(u64) (bw - 1)); }
            if (pred == ICMP_SLT && pm_one(cr) && is_sign_ashr(true_val, cl, bw) && pm_one(false_val)) ||
               (pred == ICMP_SGT && pm_zero(cr) && pm_one(true_val) && is_sign_ashr(false_val, cl, bw)) {
                get_or_insert_intrinsic_declaration(IID_SCMP, .[sel_type, sel_type]);
                return create_intrinsic_call(IID_SCMP, .[sel_type, sel_type], .[cl, const_int(sel_type, 0)]);
            }
        }
    }
    return NONE;
}

