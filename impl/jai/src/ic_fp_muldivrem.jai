// InstCombine for fmul, fdiv, frem: InstCombineMulDivRem.cpp (visitFMul, visitFDiv, visitFRem, foldFPSignBitOps,
// foldFDivConstantDivisor, foldFDivConstantDividend, foldFDivPowDivisor, foldFDivSqrtDivisor). Not ported (fail
// loudly when reached): foldFMulReassoc, foldPowiReassoc, the 1/sqrt rewrite (convertFSqrtDivIntoFMul), sin/cos ->
// tan, SimplifyDemandedInstructionFPClass at the end of visitFMul (skipped: see NOTES.md).

// m_FAbs
pm_fabs :: (v: Value_Id) -> (bool, Value_Id) { ok, x := pm_intrinsic1(v, IID_FABS); return ok, x; }

// Constant::isNormalFP / hasExactInverseFP
apf_is_normal :: (f: APFloat) -> bool { return apf_category(f) == .NORMAL && !apf_is_denormal(f); }
const_fp_all :: (c: Value_Id, pred: (APFloat) -> bool) -> bool {
    k := vkind(c);
    if k == .C_FP return pred(apf_from_const(c));
    t := vtype(c);
    if type_kind(t) == .VECTOR {
        n := type_count(t);
        for e: 0..cast(s64) n - 1 {
            elt := cf_elt(c, cast(u64) e);
            if elt == NONE || vkind(elt) != .C_FP || !pred(apf_from_const(elt)) return false;
        }
        return true;
    }
    if is_vector_type(t) {
        s := get_splat_value(c);
        return s != NONE && vkind(s) == .C_FP && pred(apf_from_const(s));
    }
    return false;
}
const_is_normal_fp :: (c: Value_Id) -> bool { return const_fp_all(c, apf_is_normal); }
apf_has_exact_inverse :: (f: APFloat) -> bool {
    if f.k == .PPC_FP128 fatal("instcombine: getExactInverse of ppc_fp128 is not supported yet");
    if !apf_is_normal(f) return false;
    g := f;
    one := fp_from_integer(g.k, .[1], 64, false);
    inv, st := fp_div(g.k, one, apf_words(*g));
    if st != 0 return false;
    r: APFloat; r.k = g.k;
    for inv if it_index < 2 r.w[it_index] = it;
    return !apf_is_denormal(r);
}
const_has_exact_inverse_fp :: (c: Value_Id) -> bool { return const_fp_all(c, apf_has_exact_inverse); }

// foldFPSignBitOps
ic_fold_fp_sign_bit_ops :: (i: Value_Id) -> Value_Id {
    opc := inst_op(i);
    op0 := op(i, 0); op1 := op(i, 1);
    ok0, x := pm_fneg(op0);
    ok1, y := pm_fneg(op1);
    if ok0 && ok1 { r := create_binop(opc, x, y); copy_ir_flags(r, i); return r; }
    oka, ax := pm_fabs(op0);
    if op0 == op1 && oka { r := create_binop(opc, ax, ax); copy_ir_flags(r, i); return r; }
    okb, by := pm_fabs(op1);
    if oka && okb && (has_one_use(op0) || has_one_use(op1)) {
        xy := icb_binop_fmf(opc, ax, by, get_fmf(i));
        fabs := icb_unary_intrinsic(IID_FABS, xy, name_ref(vname(i)), i);
        return ic_replace_inst_uses_with(i, fabs);
    }
    return NONE;
}

// ---------------------------------------------------------------- fmul

ic_visit_fmul :: (i: Value_Id) -> Value_Id {
    v := simplify_fmul_inst(op(i, 0), op(i, 1), get_fmf(i), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if ic_simplify_associative_or_commutative(i) return i;
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_fold_binop_with_phi_operands(i); if r != NONE return r;
    r = ic_fold_binop_into_select_or_phi(i); if r != NONE return r;
    v = ic_fold_mul_select_to_negate(i); if v != NONE return ic_replace_inst_uses_with(i, v);
    r = ic_fold_fp_sign_bit_ops(i); if r != NONE return r;
    r = ic_fold_fbinop_of_int_casts(i); if r != NONE return r;
    op0 := op(i, 0); op1 := op(i, 1);
    ty := vtype(i);
    if pm_specific_fp(op1, -1.0) return create_fneg_fmf(op0, i);
    {
        ok, x := pm_fneg(op0);
        if ok && is_const(op1) {
            negc := cfo_unary_op_operand(.FNEG, op1);
            if negc != NONE return create_fop(.FMUL, x, negc, i);
        }
    }
    if has_fmf(i, FMF_NNAN) && has_fmf(i, FMF_NSZ) {
        for side: 0..1 {
            u := op(i, cast(u32) side); other := op(i, cast(u32) (1 - side));
            ok, x := pmi_cast(u, .UITOFP);
            if ok && is_int_or_int_vector_n(vtype(x), 1) {
                si := ic_create_select_unknown_profile(x, other, fp_const(ty, 0));
                set_fmf(si, get_fmf(i));
                return si;
            }
        }
    }
    v = ic_simplify_selects_feeding_binop(i, op0, op1);
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if has_fmf(i, FMF_REASSOC) { rr := ic_fold_fmul_reassoc(i); if rr != NONE return rr; }
    // log2(X * 0.5) * Y = log2(X) * Y - Y
    if (get_fmf(i) & FMF_ALL) == FMF_ALL {
        found := false; lx: Value_Id = NONE; ly: Value_Id = NONE;
        for side: 0..1 {
            l := op(i, cast(u32) side);
            if is_inst(l) && call_iid(l) == IID_LOG2 && has_one_use(l) {
                m := op(l, 0);
                okm, mx, half := pm_fbin(m, .FMUL);
                if okm && has_one_use(m) && pm_specific_fp(half, 0.5) { found = true; lx = mx; ly = op(i, cast(u32) (1 - side)); }
            }
        }
        if found {
            lg := icb_unary_intrinsic(IID_LOG2, lx, "", i);
            lxy := icb_fmul_fmf(lg, ly, i);
            return create_fop(.FSUB, lxy, ly, i);
        }
    }
    {
        ok, pn, start, step := match_simple_recurrence_bo(i);
        if ok && has_fmf(i, FMF_NNAN) && has_fmf(i, FMF_NSZ) && pm_zero(start) return ic_replace_inst_uses_with(i, start);
    }
    for side: 0..1 {
        mx := op(i, cast(u32) side); mn := op(i, cast(u32) (1 - side));
        okx, x, y := pm_intrinsic2(mx, IID_MAXIMUM);
        okn, a, b := pm_intrinsic2(mn, IID_MINIMUM);
        if okx && okn && ((a == x && b == y) || (a == y && b == x)) {
            res := create_fop(.FMUL, x, y, i);
            if !has_fmf(res, FMF_NNAN) set_fmf(res, get_fmf(res) & ~cast(u32) FMF_NINF);
            return res;
        }
    }
    if has_fmf(i, FMF_CONTRACT) {
        for side: 0..1 {
            t := op(i, cast(u32) side); c := op(i, cast(u32) (1 - side));
            okt, x := pm_intrinsic1(t, IID_TAN);
            okc, cx := pm_intrinsic1(c, IID_COS);
            if okt && has_one_use(t) && okc && has_one_use(c) && cx == x {
                sin := icb_unary_intrinsic(IID_SIN, x, "", i);
                md := get_metadata(i, md_kind_id("fpmath"));
                if md != NONE && is_inst(sin) set_metadata(sin, md_kind_id("fpmath"), md);
                return ic_replace_inst_uses_with(i, sin);
            }
        }
    }
    for side: 0..1 {
        x := op(i, cast(u32) side); l := op(i, cast(u32) (1 - side));
        if call_iid(l) == IID_LDEXP && has_one_use(l) && has_fmf(i, FMF_REASSOC) && has_fmf(l, FMF_REASSOC) && pm_fp_one(op(l, 0))
            return ic_replace_inst_uses_with(i, icb_intrinsic(IID_LDEXP, .[vtype(x), vtype(op(l, 1))], .[x, op(l, 1)], "", i));
    }
    if ic_simplify_demanded_instruction_fp_class(i) return i;
    return NONE;
}

// ---------------------------------------------------------------- fdiv

// foldFDivConstantDivisor
ic_fold_fdiv_constant_divisor :: (i: Value_Id) -> Value_Id {
    c := op(i, 1);
    if !is_const(c) return NONE;
    ok, x := pm_fneg(op(i, 0));
    if ok {
        negc := cfo_unary_op_operand(.FNEG, c);
        if negc != NONE return create_fop(.FDIV, x, negc, i);
    }
    if has_fmf(i, FMF_NNAN) && (pm_pos_zero_fp(c) || (has_fmf(i, FMF_NSZ) && pm_any_zero_fp(c))) {
        // IRBuilder<> B(&I): a plain builder, so the call does not go on the worklist
        b: Irb;
        irb_set_before(*b, i);
        inf := const_fp_words(vtype(i), fp_inf(type_kind(scalar_type(vtype(i))), false));
        cs := create_intrinsic_call(IID_COPYSIGN, .[vtype(c)], .[inf, op(i, 0)]);
        set_fmf(cs, get_fmf(i));
        irb_insert(*b, cs);
        ic_take_name(cs, i);
        return ic_replace_inst_uses_with(i, cs);
    }
    if !(const_has_exact_inverse_fp(c) || (has_fmf(i, FMF_ARCP) && const_is_normal_fp(c))) return NONE;
    recip := cfo_binary_op_operands(.FDIV, fp_const(vtype(i), 1), c);
    if recip == NONE || !const_is_normal_fp(recip) return NONE;
    return create_fop(.FMUL, op(i, 0), recip, i);
}
// foldFDivConstantDividend
ic_fold_fdiv_constant_dividend :: (i: Value_Id) -> Value_Id {
    c := op(i, 0);
    if !is_const(c) return NONE;
    ok, x := pm_fneg(op(i, 1));
    if ok {
        negc := cfo_unary_op_operand(.FNEG, c);
        if negc != NONE return create_fop(.FDIV, negc, x, i);
    }
    if !has_fmf(i, FMF_REASSOC) || !has_fmf(i, FMF_ARCP) return NONE;
    newc: Value_Id = NONE;
    okm, mx, mc := pm_fbin(op(i, 1), .FMUL);
    if okm && is_const(mc) { newc = cfo_binary_op_operands(.FDIV, c, mc); x = mx; }
    else {
        okd, dx, dc := pm_fbin(op(i, 1), .FDIV);
        if okd && is_const(dc) { newc = cfo_binary_op_operands(.FMUL, c, dc); x = dx; }
    }
    if newc == NONE || !const_is_normal_fp(newc) return NONE;
    return create_fop(.FDIV, newc, x, i);
}
// foldFDivPowDivisor
ic_fold_fdiv_pow_divisor :: (i: Value_Id) -> Value_Id {
    op0 := op(i, 0); ii := op(i, 1);
    id := call_iid(ii);
    if id == NONE || !has_one_use(ii) || !has_fmf(i, FMF_REASSOC) || !has_fmf(i, FMF_ARCP) return NONE;
    if id == IID_POW {
        args: [2] Value_Id;
        args[0] = op(ii, 0); args[1] = icb_fneg(op(ii, 1), "", i);
        pw := icb_intrinsic(id, .[vtype(i)], args, "", i);
        return create_fop(.FMUL, op0, pw, i);
    }
    if id == IID_POWI {
        if !has_fmf(i, FMF_NINF) return NONE;
        args: [2] Value_Id;
        args[0] = op(ii, 0); args[1] = icb_neg(op(ii, 1));
        pw := icb_intrinsic(id, .[vtype(i), vtype(op(ii, 1))], args, "", i);
        return create_fop(.FMUL, op0, pw, i);
    }
    if id == IID_EXP || id == IID_EXP2 {
        a := icb_fneg(op(ii, 0), "", i);
        pw := icb_intrinsic(id, .[vtype(i)], .[a], "", i);
        return create_fop(.FMUL, op0, pw, i);
    }
    return NONE;
}
// foldFDivSqrtDivisor
ic_fold_fdiv_sqrt_divisor :: (i: Value_Id) -> Value_Id {
    if !has_fmf(i, FMF_REASSOC) || !has_fmf(i, FMF_ARCP) return NONE;
    op0 := op(i, 0); ii := op(i, 1);
    if call_iid(ii) != IID_SQRT || !has_one_use(ii) || !has_fmf(ii, FMF_REASSOC) || !has_fmf(ii, FMF_ARCP) return NONE;
    d := op(ii, 0);
    if !is_inst(d) return NONE;
    ok, y, z := pm_fbin(d, .FDIV);
    if !ok return NONE;
    if !has_fmf(d, FMF_REASSOC) || !has_fmf(i, FMF_ARCP) || !has_one_use(d) return NONE;
    sd := icb_fdiv_fmf(z, y, d);
    ns := icb_unary_intrinsic(IID_SQRT, sd, "", ii);
    return create_fop(.FMUL, op0, ns, i);
}

ic_visit_fdiv :: (i: Value_Id) -> Value_Id {
    v := simplify_fdiv_inst(op(i, 0), op(i, 1), get_fmf(i), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_fold_binop_with_phi_operands(i); if r != NONE return r;
    r = ic_fold_fdiv_constant_divisor(i); if r != NONE return r;
    r = ic_fold_fdiv_constant_dividend(i); if r != NONE return r;
    r = ic_fold_fp_sign_bit_ops(i); if r != NONE return r;
    op0 := op(i, 0); op1 := op(i, 1);
    ty := vtype(i);
    // isFSqrtDivToFMulLegal / convertFSqrtDivIntoFMul
    if (pm_fp_one(op0) || pm_specific_fp(op0, -1.0)) && is_inst(op1) && call_iid(op1) == IID_SQRT {
        r := ic_fsqrt_div_into_fmul(i, op1);
        if r != NONE return r;
    }
    if is_const(op0) && is_inst(op1) && inst_op(op1) == .SELECT { rr := ic_fold_op_into_select(i, op1); if rr != NONE return rr; }
    if is_const(op1) && is_inst(op0) && inst_op(op0) == .SELECT { rr := ic_fold_op_into_select(i, op0); if rr != NONE return rr; }
    if has_fmf(i, FMF_REASSOC) && has_fmf(i, FMF_ARCP) {
        ok, x, y := pm_fbin(op0, .FDIV);
        if ok && has_one_use(op0) && (!is_const(y) || !is_const(op1)) {
            yz := icb_fmul_fmf(y, op1, i);
            return create_fop(.FDIV, x, yz, i);
        }
        ok, x, y = pm_fbin(op1, .FDIV);
        if ok && has_one_use(op1) && (!is_const(y) || !is_const(op0)) {
            yz := icb_fmul_fmf(y, op0, i);
            return create_fop(.FDIV, yz, x, i);
        }
        ok, x, y = pm_fbin(op1, .FDIV);
        if ok && pm_specific_fp(x, 1.0) return create_fop(.FMUL, y, op0, i);
    }
    if has_fmf(i, FMF_REASSOC) && has_one_use(op0) && has_one_use(op1) {
        oks, x := pm_intrinsic1(op0, IID_SIN);
        okc, cx := pm_intrinsic1(op1, IID_COS);
        is_tan := oks && okc && cx == x;
        okc2, x2 := pm_intrinsic1(op0, IID_COS);
        oks2, sx := pm_intrinsic1(op1, IID_SIN);
        is_cot := !is_tan && okc2 && oks2 && sx == x2;
        if is_tan || is_cot {
            t := tli_for(ic.f);
            if has_float_fn(t, ty, .tan, .tanf, .tanl) {
                // IRBuilder<> B(&I) (ConstantFolder, nothing goes to the worklist), FMF = I's;
                // emitUnaryFloatFnCall(X, TLI, tan, tanf, tanl, B, sin/cos's function attributes)
                name, lf := get_float_fn(t, ty, .tan, .tanf, .tanl);
                xv := ifx is_tan then x else x2;
                f := get_or_insert_lib_func(t, lf, type_func(vtype(xv), .[vtype(xv)], false));
                c := new_inst(.CALL, vtype(xv), 2);
                inst(c).ty2 = glob(f).value_type;
                set_op(c, 0, xv); set_op(c, 1, f);
                set_fmf(c, get_fmf(i));
                inst(c).attrs = attr_list_without_fn_attr(glob(call_called_function(op0)).attrs, .Speculatable);
                inst(c).cc = glob(f).cc;
                irb_insert(*ic.b, c, name);
                res := c;
                if is_cot {
                    d := new_inst(.FDIV, ty, 2);
                    set_op(d, 0, fp_const(ty, 1)); set_op(d, 1, c);
                    set_fmf(d, get_fmf(i));
                    irb_insert(*ic.b, d, "");
                    res = d;
                }
                return ic_replace_inst_uses_with(i, res);
            }
        }
    }
    if has_fmf(i, FMF_NNAN) && has_fmf(i, FMF_REASSOC) {
        ok, y := pm_c_binop_with(op1, .FMUL, op0);
        if ok {
            ic_replace_operand(i, 0, fp_const(ty, 1));
            ic_replace_operand(i, 1, y);
            return i;
        }
    }
    if has_fmf(i, FMF_NNAN) && has_fmf(i, FMF_NINF) {
        oka, ax := pm_fabs(op1);
        okb, bx := pm_fabs(op0);
        x: Value_Id = NONE;
        if oka && ax == op0 x = op0;
        else if okb && bx == op1 x = op1;
        if x != NONE {
            vv := icb_binary_intrinsic(IID_COPYSIGN, fp_const(ty, 1), x, "", i);
            return ic_replace_inst_uses_with(i, vv);
        }
    }
    r = ic_fold_fdiv_pow_divisor(i); if r != NONE return r;
    r = ic_fold_fdiv_sqrt_divisor(i); if r != NONE return r;
    if has_fmf(i, FMF_REASSOC) {
        okp, px, y := pm_intrinsic2(op0, IID_POW);
        if okp && has_one_use(op0) && px == op1 {
            y1 := icb_fadd_fmf(y, fp_const(ty, -1), i);
            pw := icb_binary_intrinsic(IID_POW, op1, y1, "", i);
            return ic_replace_inst_uses_with(i, pw);
        }
    }
    r = ic_fold_powi_reassoc(i); if r != NONE return r;
    return NONE;
}
// the TLI name of a unary math libcall for an fp type (hasFloatFn): "tanf" / "tan" / "tanl"
math_libfunc_for_type :: (t: Type_Id, base: string) -> (string, Type_Kind) {
    k := type_kind(scalar_type(t));
    if k == .FLOAT return tprint("%f", base), k;
    if k == .DOUBLE return base, k;
    if k == .X86_FP80 || k == .FP128 return tprint("%l", base), k;
    return "", k;
}

// ---------------------------------------------------------------- frem

ic_visit_frem :: (i: Value_Id) -> Value_Id {
    v := simplify_frem_inst(op(i, 0), op(i, 1), get_fmf(i), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_fold_binop_with_phi_operands(i); if r != NONE return r;
    return NONE;
}

// m_AllowReassoc(...)
fp_reassoc :: (v: Value_Id) -> bool { return is_fp_math_op_value(v) && has_fmf(v, FMF_REASSOC); }
// Instruction::isOnlyUserOfAnyOperand
is_only_user_of_any_operand :: (i: Value_Id) -> bool {
    for k: 0..cast(s64) nops(i) - 1 if has_one_user(op(i, cast(u32) k)) return true;
    return false;
}
// foldFMulReassoc
ic_fold_fmul_reassoc :: (i: Value_Id) -> Value_Id {
    op0 := op(i, 0); op1 := op(i, 1);
    ty := vtype(i);
    if is_const(op1) && const_fp_all(op1, apf_is_finite_non_zero) && is_binary_operator(op0) && fp_reassoc(op0) {
        fmf := get_fmf(i) & get_fmf(op0);
        c := op1;
        okd, c1, x := pm_fbin(op0, .FDIV);
        if okd && has_one_use(op0) && is_const(c1) {
            cc1 := cfo_binary_op_operands(.FMUL, c, c1);
            if cc1 != NONE && const_is_normal_fp(cc1) return create_binop_fmf(.FDIV, cc1, x, fmf);
        }
        okd2, x2, c1b := pm_fbin(op0, .FDIV);
        if okd2 && is_const(c1b) {
            cdc1 := cfo_binary_op_operands(.FDIV, c, c1b);
            if cdc1 != NONE && const_is_normal_fp(cdc1) return create_binop_fmf(.FMUL, x2, cdc1, fmf);
            c1dc := cfo_binary_op_operands(.FDIV, c1b, c);
            if c1dc != NONE && has_one_use(op0) && const_is_normal_fp(c1dc) return create_binop_fmf(.FDIV, x2, c1dc, fmf);
        }
        oka, ax, ac := pm_fbin(op0, .FADD);
        if oka && has_one_use(op0) && is_const(ac) {
            cc1 := cfo_binary_op_operands(.FMUL, c, ac);
            if cc1 != NONE {
                xc := icb_binop_fmf(.FMUL, ax, c, fmf);
                return create_binop_fmf(.FADD, xc, cc1, fmf);
            }
        }
        oks, sc, sx := pm_fbin(op0, .FSUB);
        if oks && has_one_use(op0) && is_const(sc) {
            cc1 := cfo_binary_op_operands(.FMUL, c, sc);
            if cc1 != NONE {
                xc := icb_binop_fmf(.FMUL, sx, c, fmf);
                return create_binop_fmf(.FSUB, cc1, xc, fmf);
            }
        }
    }
    for side: 0..1 {
        d := op(i, cast(u32) side); z := op(i, cast(u32) (1 - side));
        if !fp_reassoc(d) || !has_one_use(d) continue;
        okd, x, y := pm_fbin(d, .FDIV);
        if !okd continue;
        fmf := get_fmf(i) & get_fmf(d);
        if (fmf & FMF_REASSOC) != 0 {
            nm := icb_binop_fmf(.FMUL, x, z, fmf);
            return create_binop_fmf(.FDIV, nm, y, fmf);
        }
        break;
    }
    if has_fmf(i, FMF_NNAN) {
        ok0, x := pm_intrinsic1(op0, IID_SQRT);
        ok1, y := pm_intrinsic1(op1, IID_SQRT);
        if ok0 && has_one_use(op0) && ok1 && has_one_use(op1) {
            xy := icb_fmul_fmf(x, y, i);
            sq := icb_unary_intrinsic(IID_SQRT, xy, "", i);
            return ic_replace_inst_uses_with(i, sq);
        }
    }
    if has_fmf(i, FMF_NSZ) {
        okd, one, y := pm_fbin(op0, .FDIV);
        if okd && pm_specific_fp(one, 1.0) { oks, x := pm_intrinsic1(y, IID_SQRT); if oks && op1 == x return create_fop(.FDIV, x, y, i); }
        okd, one, y = pm_fbin(op1, .FDIV);
        if okd && pm_specific_fp(one, 1.0) { oks, x := pm_intrinsic1(y, IID_SQRT); if oks && op0 == x return create_fop(.FDIV, x, y, i); }
    }
    if has_fmf(i, FMF_NNAN) && has_fmf(i, FMF_NSZ) && op0 == op1 && has_n_uses(op0, 2) {
        okd, x, sy := pm_fbin(op0, .FDIV);
        if okd {
            oks, y := pm_intrinsic1(sy, IID_SQRT);
            if oks { xsq := icb_fmul_fmf(x, x, i); return create_fop(.FDIV, xsq, y, i); }
            oks2, y2 := pm_intrinsic1(x, IID_SQRT);
            if oks2 { xsq := icb_fmul_fmf(sy, sy, i); return create_fop(.FDIV, y2, xsq, i); }
        }
    }
    for side: 0..1 {
        pw := op(i, cast(u32) side); x := op(i, cast(u32) (1 - side));
        okp, px, y := pm_intrinsic2(pw, IID_POW);
        if okp && has_one_use(pw) && px == x {
            y1 := icb_fadd_fmf(y, fp_const(ty, 1), i);
            np := icb_binary_intrinsic(IID_POW, x, y1, "", i);
            return ic_replace_inst_uses_with(i, np);
        }
    }
    r := ic_fold_powi_reassoc(i); if r != NONE return r;
    if is_only_user_of_any_operand(i) {
        okp0, x, y := pm_intrinsic2(op0, IID_POW);
        okp1, x1, z := pm_intrinsic2(op1, IID_POW);
        if okp0 && okp1 && x1 == x {
            yz := icb_fadd_fmf(y, z, i);
            np := icb_binary_intrinsic(IID_POW, x, yz, "", i);
            return ic_replace_inst_uses_with(i, np);
        }
        if okp0 && okp1 && z == y {
            xz := icb_fmul_fmf(x, x1, i);
            np := icb_binary_intrinsic(IID_POW, xz, y, "", i);
            return ic_replace_inst_uses_with(i, np);
        }
        for id: IID_EXP_IDS {
            ok0, ex := pm_intrinsic1(op0, id);
            ok1, ey := pm_intrinsic1(op1, id);
            if ok0 && ok1 {
                xy := icb_fadd_fmf(ex, ey, i);
                e := icb_unary_intrinsic(id, xy, "", i);
                return ic_replace_inst_uses_with(i, e);
            }
        }
    }
    if has_one_use(op0) {
        ok, y := pm_c_binop_with(op0, .FMUL, op1);
        if ok && op1 != y { xsq := icb_fmul_fmf(op1, op1, i); return create_fop(.FMUL, xsq, y, i); }
    }
    if has_one_use(op1) {
        ok, y := pm_c_binop_with(op1, .FMUL, op0);
        if ok && op0 != y { xsq := icb_fmul_fmf(op0, op0, i); return create_fop(.FMUL, xsq, y, i); }
    }
    return NONE;
}
IID_EXP_IDS :: Intrinsic_Id.[IID_EXP, IID_EXP2];

// foldPowiReassoc
ic_fold_powi_reassoc :: (i: Value_Id) -> Value_Id {
    create_powi :: (i: Value_Id, x: Value_Id, y: Value_Id, z: Value_Id) -> Value_Id {
        yz := icb_add(y, z, "", false, true);
        return icb_intrinsic(IID_POWI, .[vtype(x), vtype(yz)], .[x, yz], "", i);
    }
    opc := inst_op(i);
    op0 := op(i, 0); op1 := op(i, 1);
    if opc == .FMUL {
        for side: 0..1 {
            pw := op(i, cast(u32) side); x := op(i, cast(u32) (1 - side));
            ok, px, y := pm_intrinsic2(pw, IID_POWI);
            if ok && has_one_use(pw) && fp_reassoc(pw) && px == x {
                one := const_int_of(vtype(y), 1);
                if ic_will_not_overflow_signed_add(y, one, i) return ic_replace_inst_uses_with(i, create_powi(i, x, y, one));
            }
        }
    }
    if opc == .FMUL && is_only_user_of_any_operand(i) {
        ok0, x, y := pm_intrinsic2(op0, IID_POWI);
        ok1, x1, z := pm_intrinsic2(op1, IID_POWI);
        if ok0 && fp_reassoc(op0) && ok1 && fp_reassoc(op1) && x1 == x && vtype(y) == vtype(z) && ic_will_not_overflow_signed_add(y, z, i)
            return ic_replace_inst_uses_with(i, create_powi(i, x, y, z));
    }
    if opc == .FDIV && has_fmf(i, FMF_REASSOC) && has_fmf(i, FMF_NNAN) {
        ok0, px, y := pm_intrinsic2(op0, IID_POWI);
        if ok0 && has_one_use(op0) && fp_reassoc(op0) && px == op1 && ic_will_not_overflow_signed_sub(y, const_int_of(vtype(y), 1), i)
            return ic_replace_inst_uses_with(i, create_powi(i, op1, y, const_all_ones_of(vtype(y))));
        if ok0 && has_one_use(op0) && fp_reassoc(op0) && fp_reassoc(op1) {
            okm, z := pm_c_binop_with(op1, .FMUL, px);
            if okm && ic_will_not_overflow_signed_sub(y, const_int_of(vtype(y), 1), i) {
                np := create_powi(i, px, y, const_all_ones_of(vtype(y)));
                return create_fop(.FDIV, np, z, i);
            }
        }
    }
    return NONE;
}

// getFSqrtDivOptPattern + isFSqrtDivToFMulLegal + convertFSqrtDivIntoFMul (InstCombineMulDivRem.cpp):
//   x = 1.0/sqrt(a); r1 = x * x; r2 = a/sqrt(a)  -->  r1 = 1/a; r2 = sqrt(a); x = r1 * r2
// R1 and R2 are SmallPtrSet<Instruction *, 2>: insertion order while small; a third element switches to pointer-hash
// order, which fails loudly.
ic_fsqrt_div_into_fmul :: (x: Value_Id, ci: Value_Id) -> Value_Id {
    a := op(ci, 0);
    r1: [..] Value_Id; r1.allocator = temp;
    r2: [..] Value_Id; r2.allocator = temp;
    u := ir.v_first_use[x];
    while u != NONE {
        us := ir.u_user[u];
        ok, m0, m1 := pm_fbin(us, .FMUL);
        if ok && m0 == x && m1 == x array_add_if_unique(*r1, us);
        u = ir.u_next[u];
    }
    u = ir.v_first_use[ci];
    while u != NONE {
        us := ir.u_user[u];
        ok, d0, d1 := pm_fbin(us, .FDIV);
        if ok && d0 == a && is_inst(d1) && call_iid(d1) == IID_SQRT && op(d1, 0) == a array_add_if_unique(*r2, us);
        u = ir.u_next[u];
    }
    if r1.count == 0 || r2.count == 0 return NONE;
    if r1.count > 2 || r2.count > 2 fatal("instcombine: convertFSqrtDivIntoFMul with more than two r1/r2 instructions (SmallPtrSet iteration order) is not supported yet");
    bbx := inst_block(x); bbr1 := inst_block(r1[0]); bbr2 := inst_block(r2[0]);
    need :: FMF_REASSOC | FMF_NNAN | FMF_NSZ | FMF_NINF;
    if (get_fmf(ci) & need) != need return NONE;
    if !has_fmf(x, FMF_REASSOC) || !has_fmf(x, FMF_ARCP) || !has_fmf(x, FMF_NINF) return NONE;
    if bbx != bbr1 && bbx != bbr2 return NONE;
    for r1 if inst_block(it) != bbr1 || !has_fmf(it, FMF_REASSOC) return NONE;
    for r2 if inst_block(it) != bbr2 || !has_fmf(it, FMF_REASSOC) return NONE;

    icb_set_insert_point(x);
    fpmath := md_kind_id("fpmath");
    saved := ic.b_fmf; ic.b_fmf = 0; defer ic.b_fmf = saved;
    fdiv := icb_binop(.FDIV, lcs_const_fp_f64(vtype(x), 1.0), a);
    r1md := get_metadata(r1[0], fpmath);
    r1fmf := get_fmf(r1[0]);
    for r1 {
        r1md = md_most_generic_fpmath(r1md, get_metadata(it, fpmath));
        r1fmf &= get_fmf(it);
        ic_replace_inst_uses_with(it, fdiv);
        ic_erase_inst(it);
    }
    set_metadata(fdiv, fpmath, r1md);
    set_fmf(fdiv, r1fmf);
    fsqrt := ic_clone_inst(ci);
    ic_link_before(fsqrt, ci);
    r2md := get_metadata(r2[0], fpmath);
    r2fmf := get_fmf(r2[0]);
    for r2 {
        r2md = md_most_generic_fpmath(r2md, get_metadata(it, fpmath));
        r2fmf &= get_fmf(it);
        ic_replace_inst_uses_with(it, fsqrt);
        ic_erase_inst(it);
    }
    set_metadata(fsqrt, fpmath, r2md);
    set_fmf(fsqrt, r2fmf);
    fmul: Value_Id;
    if pm_specific_fp(op(x, 0), -1.0) fmul = icb_fneg(icb_binop(.FMUL, fdiv, fsqrt));
    else fmul = icb_binop(.FMUL, fdiv, fsqrt);
    copy_metadata(fmul, x);
    set_fmf(fmul, fmf_intersect_rewrite(r1fmf, r2fmf) | fmf_union_value(r1fmf, r2fmf));
    return ic_replace_inst_uses_with(x, fmul);
}
