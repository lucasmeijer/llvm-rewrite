// InstCombine for mul, div and rem: a port of llvm/lib/Transforms/InstCombine/InstCombineMulDivRem.cpp
// (visitMul, visitUDiv, visitSDiv, visitURem, visitSRem and their helpers; the FP visitors are in
// ic_fp_muldivrem.jai). Folds are in LLVM's order.

// simplifyValueKnownNonZero
ic_simplify_value_known_non_zero :: (v: Value_Id, cxt: Value_Id) -> Value_Id {
    if !has_one_use(v) return NONE;
    made := false;
    okl, sh, b := pm_binop(v, .LSHR);
    if okl && has_one_use(sh) {
        oks, one, a := pm_binop(sh, .SHL);
        if oks && pm_one(one) {
            a2 := icb_sub(a, b);
            return icb_shl(one, a2);
        }
    }
    if is_binary_operator(v) && (inst_op(v) == .SHL || inst_op(v) == .LSHR) && ic_is_known_to_be_power_of_two(op(v, 0), false, cxt) {
        {
            saved := ic.b;
            defer ic.b = saved;
            irb_set_before(*ic.b, v);
            v2 := ic_simplify_value_known_non_zero(op(v, 0), cxt);
            if v2 != NONE { ic_replace_operand(v, 0, v2); made = true; }
        }
        if inst_op(v) == .LSHR && !is_exact(v) { set_exact(v); made = true; }
        if inst_op(v) == .SHL && !has_nuw(v) { set_nuw(v); made = true; }
    }
    return ifx made then v else NONE;
}

// foldMulSelectToNegate (integer and FP forms)
ic_fold_mul_select_to_negate :: (i: Value_Id) -> Value_Id {
    for side: 0..1 {
        sel := op(i, cast(u32) side); other := op(i, cast(u32) (1 - side));
        ok, cond, tv, fv := pm_select(sel);
        if !ok || !has_one_use(sel) continue;
        if inst_op(i) == .MUL {
            any_nw := has_nsw(i) || has_nuw(i);
            if pm_one(tv) && pm_all_ones(fv) { neg := icb_neg(other, "", any_nw); return icb_select(cond, other, neg); }
            if pm_all_ones(tv) && pm_one(fv) { neg := icb_neg(other, "", any_nw); return icb_select(cond, neg, other); }
        } else {
            if pm_specific_fp(tv, 1.0) && pm_specific_fp(fv, -1.0) {
                saved := ic.b_fmf; ic.b_fmf = get_fmf(i); defer ic.b_fmf = saved;
                return icb_select(cond, other, icb_fneg(other, "", i));
            }
            if pm_specific_fp(tv, -1.0) && pm_specific_fp(fv, 1.0) {
                saved := ic.b_fmf; ic.b_fmf = get_fmf(i); defer ic.b_fmf = saved;
                return icb_select(cond, icb_fneg(other, "", i), other);
            }
        }
    }
    return NONE;
}

// foldMulShl1
ic_fold_mul_shl1 :: (mul: Value_Id, commute: bool) -> Value_Id {
    x := op(mul, 0); y := op(mul, 1);
    if commute { t := x; x = y; y = t; }
    nsw := has_nsw(mul); nuw := has_nuw(mul);
    oks, one, z := pm_binop(y, .SHL);
    if oks && pm_one(one) return icb_shl(x, z, name_ref(vname(mul)), nuw, nsw && has_nsw(y));
    oka, sh, one2 := pm_binop(y, .ADD);
    if oka && has_one_use(y) && pm_one(one2) && is_binary_operator(sh) {
        ok2, one3, z2 := pm_binop(sh, .SHL);
        if ok2 && has_one_use(sh) && pm_one(one3) {
            pnsw := nsw && has_nsw(sh);
            frx := x;
            if !is_guaranteed_not_to_be_undef(x) frx = icb_freeze(x, tprint("%.fr", vname(x)));
            shl := icb_shl(frx, z2, "mulshl", nuw, pnsw);
            return icb_add(shl, frx, name_ref(vname(mul)), nuw, pnsw);
        }
    }
    okn, ns := pm_not(y);
    if okn && has_one_use(y) && has_one_use(ns) {
        ok3, m1, z3 := pm_binop(ns, .SHL);
        if ok3 && pm_all_ones(m1) {
            frx := x;
            if !is_guaranteed_not_to_be_undef(x) frx = icb_freeze(x, tprint("%.fr", vname(x)));
            shl := icb_shl(frx, z3, "mulshl");
            return icb_sub(shl, frx, name_ref(vname(mul)));
        }
    }
    return NONE;
}
// CreateFreeze
icb_freeze :: (v: Value_Id, name: string = "") -> Value_Id {
    i := new_inst(.FREEZE, vtype(v), 1);
    set_op(i, 0, v);
    return icb_insert(i, name);
}

// ConstantExpr::getExactLogBase2
ce_exact_log_base2 :: (c: Value_Id) -> Value_Id {
    t := vtype(c);
    ok, v := pm_apint(c);
    if ok && ap_is_power_of_2(v) return const_int_of(t, ap_log2(v));
    if type_kind(t) != .VECTOR return NONE;
    n := type_count(t);
    elts := NewArray(cast(s64) n, Value_Id,, allocator = temp);
    et := scalar_type(t);
    for k: 0..cast(s64) n - 1 {
        e := cf_elt(c, cast(u64) k);
        if e == NONE return NONE;
        if pm_undef_value(e) { elts[k] = const_null_value(et); continue; }
        oke, ev := pm_apint(e);
        if !oke || !ap_is_power_of_2(ev) return NONE;
        elts[k] = const_int_of(et, ap_log2(ev));
    }
    return cf_vector(t, elts);
}

// takeLog2 / tryGetLog2. With do_fold = false the result is a marker (IC_NONNULL) or NONE.
ic_take_log2 :: (v: Value_Id, depth_in: u32, assume_non_zero: bool, do_fold: bool) -> Value_Id {
    depth := depth_in;
    if pm_power2(v) {
        if !do_fold return IC_NONNULL;
        c := ce_exact_log_base2(v);
        if c == NONE fatal("internal: Failed to constant fold udiv -> logbase2");
        return c;
    }
    if depth == MAX_ANALYSIS_RECURSION_DEPTH return NONE;
    depth += 1;
    okz, x := pmi_cast(v, .ZEXT);
    if okz {
        lx := ic_take_log2(x, depth, assume_non_zero, do_fold);
        if lx != NONE return ifx do_fold then icb_zext(lx, vtype(v)) else IC_NONNULL;
    }
    okt, tx := pmi_cast(v, .TRUNC);
    if okt && (assume_non_zero || has_nuw(v)) {
        lx := ic_take_log2(tx, depth, assume_non_zero, do_fold);
        if lx != NONE return ifx do_fold then icb_trunc(lx, vtype(v), "", has_nuw(v)) else IC_NONNULL;
    }
    oks, sx, sy := pm_binop(v, .SHL);
    if oks && (assume_non_zero || has_nuw(v) || has_nsw(v)) {
        lx := ic_take_log2(sx, depth, assume_non_zero, do_fold);
        if lx != NONE return ifx do_fold then icb_add(lx, sy) else IC_NONNULL;
    }
    okl, lx0, ly := pm_binop(v, .LSHR);
    if okl && (assume_non_zero || is_exact(v)) {
        lx := ic_take_log2(lx0, depth, assume_non_zero, do_fold);
        if lx != NONE return ifx do_fold then icb_sub(lx, ly) else IC_NONNULL;
    }
    oka, ax, ay := pm_binop(v, .AND);
    if assume_non_zero && oka {
        lx := ic_take_log2(ax, depth, assume_non_zero, do_fold);
        if lx != NONE return lx;
        lyv := ic_take_log2(ay, depth, assume_non_zero, do_fold);
        if lyv != NONE return lyv;
    }
    if is_inst(v) && inst_op(v) == .SELECT {
        lx := ic_take_log2(op(v, 1), depth, assume_non_zero, do_fold);
        if lx != NONE {
            lyv := ic_take_log2(op(v, 2), depth, assume_non_zero, do_fold);
            if lyv != NONE return ifx do_fold then icb_select(op(v, 0), lx, lyv, "", v) else IC_NONNULL;
        }
    }
    id := call_iid(v);
    if (id == IID_UMIN || id == IID_UMAX) && has_one_use(v) {
        lx := ic_take_log2(op(v, 0), depth, false, do_fold);
        if lx != NONE {
            lyv := ic_take_log2(op(v, 1), depth, false, do_fold);
            if lyv != NONE return ifx do_fold then icb_binary_intrinsic(id, lx, lyv) else IC_NONNULL;
        }
    }
    return NONE;
}
ic_try_get_log2 :: (v: Value_Id, assume_non_zero: bool) -> Value_Id {
    if ic_take_log2(v, 0, assume_non_zero, false) != NONE return ic_take_log2(v, 0, assume_non_zero, true);
    return NONE;
}

// ---------------------------------------------------------------- visitMul

ic_visit_mul :: (i: Value_Id) -> Value_Id {
    op0 := op(i, 0); op1 := op(i, 1);
    v := simplify_mul_inst(op0, op1, has_nsw(i), has_nuw(i), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if ic_simplify_associative_or_commutative(i) return i;
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_fold_binop_with_phi_operands(i); if r != NONE return r;
    v = ic_fold_using_distributive_laws(i);
    if v != NONE return ic_replace_inst_uses_with(i, v);
    op0 = op(i, 0); op1 = op(i, 1);
    ty := vtype(i);
    bw := scalar_bits(i);
    nsw := has_nsw(i); nuw := has_nuw(i);
    // X * -1 --> 0 - X
    if pm_all_ones(op1) {
        n := create_neg(op0);
        if nsw set_nsw(n);
        return n;
    }
    {
        // ((X << C2)*C1) == (X * (C1 << C2))
        oks, newop, c2 := pm_binop(op0, .SHL);
        okc, ival := pm_apint(op1);
        if oks && pm_imm_constant(c2) && pm_imm_constant(op1) && okc {
            shl := cfo_binary_op_operands(.SHL, op1, c2);
            bo := create_binop(.MUL, newop, shl);
            if nuw && has_nuw(op0) set_nuw(bo);
            if nsw && has_nsw(op0) && const_is_not_min_signed_value(shl) set_nsw(bo);
            return bo;
        }
        // X*(2^C) --> X << C
        if pm_constant(op1) {
            newc := ce_exact_log_base2(op1);
            if newc != NONE {
                shl := create_binop(.SHL, op0, newc);
                if nuw set_nuw(shl);
                if nsw { okv, vv := pm_apint(newc); if okv && !ap_eq_u64(vv, bw - 1) set_nsw(shl); }
                return shl;
            }
        }
    }
    // mul (shr exact X, N), (2^N + 1) -> add (X, shr exact (X, N))
    if bw > 2 && is_binary_operator(op0) && is_shr_op(inst_op(op0)) && is_exact(op0) {
        newop := op(op0, 0);
        oks, shiftc := pm_apint(op(op0, 1));
        okm, mulap := pm_apint(op1);
        if oks && okm && ap_is_power_of_2(ap_sub_u64(mulap, 1)) && ap_eq_u64(shiftc, ap_log2(mulap)) {
            binop := op0;
            if nuw && inst_op(op0) == .ASHR && has_one_use(op0) binop = icb_lshr(newop, const_int_ap(ty, shiftc), "", true);
            na := create_binop(.ADD, newop, binop);
            if nsw && (nuw || inst_op(op0) == .LSHR || ap_zext_value(shiftc) < bw - 1) set_nsw(na);
            set_nuw(na, nuw);
            return na;
        }
    }
    if has_one_use(op0) && pm_negated_power2(op1) {
        neg0 := negator_negate(true, nsw, op0);
        if neg0 != NONE
            return ic_replace_inst_uses_with(i, icb_mul(neg0, ce_neg(op1), "", false, nsw && const_is_not_min_signed_value(op1)));
        oke, x := pmi_zext_or_sext(op0);
        okc, np2 := pm_apint_ap(op1);
        if oke && okc {
            sw := scalar_bits(x);
            sh := ap_ctz(np2);
            if sh >= bw - sw {
                n := icb_neg(x, tprint("%.neg", vname(x)));
                z := icb_zext(n, ty, tprint("%.z", vname(n)));
                return create_binop(.SHL, z, const_int_of(ty, sh));
            }
        }
    }
    r = ic_fold_binop_into_select_or_phi(i); if r != NONE return r;
    r = ic_fold_binop_select_binop(i); if r != NONE return r;
    v = ic_fold_mul_select_to_negate(i);
    if v != NONE return ic_replace_inst_uses_with(i, v);
    // (shl X, C1)*(select cond, C2, C3) --> X * (select cond, C2<<C1, C3<<C1) (and mul)
    for side: 0..1 {
        other := op(i, cast(u32) side); sel := op(i, cast(u32) (1 - side));
        if !has_one_use(other) || !has_one_use(sel) continue;
        ok, cond, c2, c3 := pm_select(sel);
        if !ok || !pm_imm_constant(c2) || !pm_imm_constant(c3) continue;
        okm, newop, c1 := pm_binop(other, .MUL);
        if !okm || !pm_imm_constant(c1) { okm, newop, c1 = pm_binop(other, .SHL); if !okm || !pm_imm_constant(c1) continue; }
        opc := inst_op(other);
        ntv := cfo_binary_op_operands(opc, c2, c1);
        nfv := cfo_binary_op_operands(opc, c3, c1);
        if ntv != NONE && nfv != NONE {
            ns := icb_select(cond, ntv, nfv);
            bo := create_binop(.MUL, newop, ns);
            if nuw && has_nuw(other) set_nuw(bo);
            if nsw && has_nsw(other) && const_is_not_min_signed_value(ntv) && const_is_not_min_signed_value(nfv) set_nsw(bo);
            return bo;
        }
        break;
    }
    // (X+C1)*MulC -> X*MulC+C1*MulC
    if pm_imm_constant(op1) {
        oka, x, c1 := pm_add_like(op0);
        if oka && has_one_use(op0) && pm_imm_constant(c1) {
            newc := icb_mul(c1, op1);
            op0_nuw := inst_op(op0) == .OR || has_nuw(op0);
            newmul := icb_mul(x, op1);
            bo := create_binop(.ADD, newmul, newc);
            if nuw && op0_nuw {
                if is_binary_operator(newmul) set_nuw(newmul);
                set_nuw(bo);
            }
            return bo;
        }
    }
    // abs(X) * abs(X) -> X * X
    {
        ok, x := pm_intrinsic1(op0, IID_ABS);
        if op0 == op1 && ok return create_binop(.MUL, x, x);
    }
    // abs(X) * abs(Y) -> abs(X * Y)
    if nsw {
        ok0, x, p0 := pm_intrinsic2(op0, IID_ABS);
        ok1, y, p1 := pm_intrinsic2(op1, IID_ABS);
        if ok0 && has_one_use(op0) && pm_one(p0) && ok1 && has_one_use(op1) && pm_one(p1)
            return ic_replace_inst_uses_with(i, icb_binary_intrinsic(IID_ABS, icb_mul(x, y, "", false, true), get_true(ir.t_i1)));
    }
    // -X * C --> X * -C
    {
        okn, x := pm_neg(op0);
        if okn && pm_constant(op1) return create_binop(.MUL, x, ce_neg(op1));
        // -X * -Y --> X * Y
        okn2, y := pm_neg(op1);
        if okn && okn2 {
            nm := create_binop(.MUL, x, y);
            if nsw && has_nsw(op0) && has_nsw(op1) set_nsw(nm);
            return nm;
        }
    }
    // -X * Y --> -(X * Y)
    for side: 0..1 {
        n := op(i, cast(u32) side); y := op(i, cast(u32) (1 - side));
        okn, x := pm_neg(n);
        if okn && has_one_use(n) return create_neg(icb_mul(x, y));
    }
    // (-X * Y) * -X --> (X * Y) * X
    {
        okn, x := pm_neg(op1);
        if okn {
            neg0 := negator_negate(false, false, op0);
            if neg0 != NONE return create_binop(.MUL, neg0, x);
        }
    }
    if has_one_use(op0) {
        okc, c1 := pm_apint(op1);
        if okc && is_binary_operator(op0) && is_exact(op0) && (inst_op(op0) == .UDIV || inst_op(op0) == .SDIV) {
            okd, dc := pm_apint(op(op0, 1));
            if okd {
                pass := false;
                if inst_op(op0) == .UDIV pass = ap_is_zero(ap_urem(dc, c1));
                else {
                    q, rm := ap_sdivrem(dc, c1);
                    pass = ap_is_zero(rm) && !ap_is_all_ones(q);
                }
                if pass {
                    bopc := inst_op(op0);
                    return create_binop_flags(bopc, op(op0, 0), icb_binop(bopc, op(op0, 1), op1), F_EXACT);
                }
            }
        }
    }
    // (X / Y) * Y = X - (X % Y); (X / Y) * -Y = (X % Y) - X
    {
        y := op1;
        div := op0;
        if !is_binary_operator(div) || (inst_op(div) != .UDIV && inst_op(div) != .SDIV) { y = op0; div = op1; }
        neg := ic_dyn_cast_neg_val(y);
        if is_binary_operator(div) && has_one_use(div) && (op(div, 1) == y || op(div, 1) == neg) &&
           (inst_op(div) == .UDIV || inst_op(div) == .SDIV) {
            x := op(div, 0); divop1 := op(div, 1);
            if is_exact(div) {
                if divop1 == y return ic_replace_inst_uses_with(i, x);
                return create_neg(x);
            }
            remopc: Opcode = ifx inst_op(div) == .UDIV then Opcode.UREM else .SREM;
            xf := x;
            if !is_guaranteed_not_to_be_undef(x) xf = icb_freeze(x, tprint("%.fr", vname(x)));
            rem := icb_binop(remopc, xf, divop1);
            if divop1 == y return create_binop(.SUB, xf, rem);
            return create_binop(.SUB, rem, xf);
        }
    }
    // i1 mul -> and; X * Y --> X & Y iff X, Y are {0,1}
    {
        oka, a0, a1 := pm_binop(op0, .AND);
        okb, b0, b1 := pm_binop(op1, .AND);
        if is_int_or_int_vector_n(ty, 1) || (oka && pm_one(a1) && okb && pm_one(b1)) return create_binop(.AND, op0, op1);
    }
    v = ic_fold_mul_shl1(i, false); if v != NONE return ic_replace_inst_uses_with(i, v);
    v = ic_fold_mul_shl1(i, true); if v != NONE return ic_replace_inst_uses_with(i, v);
    // (zext bool X) * (zext bool Y) / (sext * sext) --> zext (and X, Y)
    {
        okz0, zx := pmi_cast(op0, .ZEXT); okz1, zy := pmi_cast(op1, .ZEXT);
        oks0, sx := pmi_cast(op0, .SEXT); oks1, sy := pmi_cast(op1, .SEXT);
        x, y: Value_Id = NONE;
        if okz0 && okz1 { x = zx; y = zy; } else if oks0 && oks1 { x = sx; y = sy; }
        if x != NONE && is_int_or_int_vector_n(vtype(x), 1) && vtype(x) == vtype(y) && (has_one_use(op0) || has_one_use(op1) || x == y)
            return create_cast(.ZEXT, icb_and(x, y, "mulbool"), ty);
        x = NONE; y = NONE;
        if oks0 && okz1 { x = sx; y = zy; } else if okz0 && oks1 { x = zx; y = sy; }
        if x != NONE && is_int_or_int_vector_n(vtype(x), 1) && vtype(x) == vtype(y) && (has_one_use(op0) || has_one_use(op1))
            return create_cast(.SEXT, icb_and(x, y, "mulbool"), ty);
    }
    // (zext bool X) * Y --> X ? Y : 0
    {
        okz, x := pmi_cast(op0, .ZEXT);
        if okz && is_int_or_int_vector_n(vtype(x), 1) return ic_create_select_unknown_profile(x, op1, const_null_value(ty));
        okz, x = pmi_cast(op1, .ZEXT);
        if okz && is_int_or_int_vector_n(vtype(x), 1) return ic_create_select_unknown_profile(x, op0, const_null_value(ty));
    }
    // mul (sext X), Y -> select X, -Y, 0
    for side: 0..1 {
        se := op(i, cast(u32) side); y := op(i, cast(u32) (1 - side));
        oks, x := pmi_cast(se, .SEXT);
        if oks && has_one_use(se) && is_int_or_int_vector_n(vtype(x), 1)
            return ic_create_select_unknown_profile(x, icb_neg(y, "", nsw), const_null_value(vtype(op0)));
    }
    if pm_imm_constant(op1) {
        oks, x := pmi_cast(op0, .SEXT);
        if oks && is_int_or_int_vector_n(vtype(x), 1) return ic_create_select_unknown_profile(x, ce_neg(op1), const_null_value(ty));
        oka, ax, cv := pm_binop(op0, .ASHR);
        okc, c := pm_apint(cv);
        if oka && has_one_use(op0) && okc && ap_eq_u64(c, c.bits - 1) {
            negc := ce_neg(op1);
            isneg := icb_cmp(ICMP_SLT, ax, const_null_value(vtype(ax)), "isneg");
            return ic_create_select_unknown_profile(isneg, negc, const_null_value(ty));
        }
    }
    // (lshr X, 31) * Y --> (X < 0) ? Y : 0
    for side: 0..1 {
        sh := op(i, cast(u32) side); y := op(i, cast(u32) (1 - side));
        okl, x, cv := pm_binop(sh, .LSHR);
        okc, c := pm_apint(cv);
        if okl && okc && ap_eq_u64(c, c.bits - 1) {
            isneg := icb_cmp(ICMP_SLT, x, const_null_value(vtype(x)), "isneg");
            return ic_create_select_unknown_profile(isneg, y, const_null_value(ty));
        }
    }
    // (and X, 1) * Y --> (trunc X) ? Y : 0
    for side: 0..1 {
        an := op(i, cast(u32) side); y := op(i, cast(u32) (1 - side));
        oka, x, one := pm_binop(an, .AND);
        if oka && has_one_use(an) && pm_one(one) {
            tr := icb_trunc(x, make_cmp_result_type(ty));
            return ic_create_select_unknown_profile(tr, y, const_null_value(ty));
        }
    }
    // ((ashr X, 31) | 1) * X --> abs(X)
    for side: 0..1 {
        orv := op(i, cast(u32) side); x := op(i, cast(u32) (1 - side));
        oko, o0, o1 := pm_binop(orv, .OR);
        if !oko || !pm_one(o1) continue;
        oka, ax, sa := pm_binop(o0, .ASHR);
        if oka && ax == x && pm_specific_int_allow_poison(sa, bw - 1) {
            abs := icb_binary_intrinsic(IID_ABS, x, const_int_of(ir.t_i1, ifx nsw then cast(u64) 1 else 0));
            ic_take_name(abs, i);
            return ic_replace_inst_uses_with(i, abs);
        }
    }
    r = ic_narrow_math_if_no_overflow(i); if r != NONE return r;
    r = ic_fold_binop_of_select_and_cast_of_select_condition(i); if r != NONE return r;
    {
        res := ic_try_get_log2(op0, false);
        if res != NONE { shl := create_binop(.SHL, op1, res); set_nuw(shl, nuw); return shl; }
        res = ic_try_get_log2(op1, false);
        if res != NONE { shl := create_binop(.SHL, op0, res); set_nuw(shl, nuw); return shl; }
    }
    changed := false;
    if !nsw && ic_will_not_overflow_signed_mul(op0, op1, i) { changed = true; set_nsw(i); }
    if !nuw && ic_will_not_overflow_unsigned_mul(op0, op1, i, has_nsw(i)) { changed = true; set_nuw(i); }
    return ifx changed then i else NONE;
}

// ---------------------------------------------------------------- division and remainder helpers

// APInt::sdivrem / udivrem
ap_sdivrem :: (a: APInt, b: APInt) -> (APInt, APInt) { return ap_sdiv(a, b), ap_srem(a, b); }

// isMultiple
is_multiple :: (c1: APInt, c2: APInt, is_signed: bool) -> (bool, APInt) {
    if ap_is_zero(c2) return false, .{};
    if is_signed && ap_is_min_signed(c1) && ap_is_all_ones(c2) return false, .{};
    q, r: APInt;
    if is_signed q, r = ap_sdivrem(c1, c2); else q, r = ap_udivrem(c1, c2);
    return ap_is_zero(r), q;
}
// multiplyOverflows
multiply_overflows :: (c1: APInt, c2: APInt, is_signed: bool) -> (bool, APInt) {
    p: APInt; ov: bool;
    if is_signed p, ov = ap_smul_ov(c1, c2); else p, ov = ap_umul_ov(c1, c2);
    return ov, p;
}

// simplifyDivRemOfSelectWithZeroOp
ic_simplify_div_rem_of_select_with_zero_op :: (i: Value_Id) -> bool {
    si := op(i, 1);
    if !is_inst(si) || inst_op(si) != .SELECT return false;
    nn: u32;
    if pm_zero(op(si, 1)) nn = 2;
    else if pm_zero(op(si, 2)) nn = 1;
    else return false;
    ic_replace_operand(i, 1, op(si, nn));
    cond := op(si, 0);
    if !has_uses(si) && has_one_use(cond) return true;
    cty := vtype(cond);
    bbi := i;
    front := block_first(inst_block(i));
    sel := si; sc := cond;
    while bbi != front {
        bbi = inst(bbi).prev;
        if !is_guaranteed_to_transfer_execution(bbi) break;
        for k: 0..cast(s64) nops(bbi) - 1 {
            u := op_use(bbi, cast(u32) k);
            if sel != NONE && ir.u_val[u] == sel {
                ic_replace_use(u, op(sel, nn));
                wl_push(bbi);
            } else if sc != NONE && ir.u_val[u] == sc {
                ic_replace_use(u, ifx nn == 1 then get_true(cty) else get_false(cty));
                wl_push(bbi);
            }
        }
        if bbi == sel sel = NONE;
        if bbi == sc sc = NONE;
        if sc == NONE && sel == NONE break;
    }
    return true;
}

// m_ContainsMatchingVectorElement(m_CombineOr(m_Zero(), m_UndefValue()))
contains_zero_or_undef_element :: (c: Value_Id) -> bool {
    if !is_const(c) return false;
    t := vtype(c);
    if type_kind(t) != .VECTOR return false;
    n := type_count(t);
    for k: 0..cast(s64) n - 1 {
        e := cf_elt(c, cast(u64) k);
        if e == NONE continue;
        if pm_undef_value(e) || pm_zero(e) return true;
    }
    return false;
}

// commonIDivRemTransforms
ic_common_idiv_rem_transforms :: (i: Value_Id) -> Value_Id {
    op0 := op(i, 0); op1 := op(i, 1);
    if contains_zero_or_undef_element(op1) return ic_replace_inst_uses_with(i, const_poison(vtype(i)));
    r := ic_fold_binop_with_phi_operands(i); if r != NONE return r;
    v := ic_simplify_value_known_non_zero(op(i, 1), i);
    if v != NONE return ic_replace_operand(i, 1, v);
    if ic_simplify_div_rem_of_select_with_zero_op(i) return i;
    op0 = op(i, 0); op1 = op(i, 1);
    if pm_imm_constant(op0) {
        ok, c, t, f := pm_select(op1);
        if ok && pm_imm_constant(t) && pm_imm_constant(f) {
            rr := ic_fold_op_into_select(i, op1, true);
            if rr != NONE return rr;
        }
    }
    return NONE;
}

// foldIDivShl
ic_fold_idiv_shl :: (i: Value_Id) -> Value_Id {
    is_signed := inst_op(i) == .SDIV;
    op0 := op(i, 0); op1 := op(i, 1);
    ty := vtype(i);
    {
        oks, x, z := pm_binop(op1, .SHL);
        if oks {
            okm, y := pm_c_binop_with(op0, .MUL, x);
            if okm {
                nuw := has_nuw(op0) && has_nuw(op1);
                nsw := has_nsw(op0) && has_nsw(op1);
                if !is_signed && nuw return icb_lshr(y, z, "", is_exact(i));
                if is_signed && nsw && (has_one_use(op0) || has_one_use(op1)) {
                    shl := icb_shl(const_int_of(ty, 1), z);
                    return icb_sdiv(y, shl, "", is_exact(i));
                }
            }
        }
    }
    {
        ok0, x, z := pm_binop(op0, .SHL);
        ok1, y, z1 := pm_binop(op1, .SHL);
        if ok0 && ok1 && z1 == z {
            if !is_signed && ((has_nuw(op0) && has_nuw(op1)) || (has_nuw(op0) && has_nsw(op0) && has_nsw(op1)))
                return icb_udiv(x, y, "", is_exact(i));
            if is_signed && has_nsw(op0) && has_nsw(op1) && has_nuw(op1)
                return icb_sdiv(x, y, "", is_exact(i));
        }
    }
    {
        ok0, x, y := pm_binop(op0, .SHL);
        ok1, x1, z := pm_binop(op1, .SHL);
        if ok0 && ok1 && x1 == x {
            cond := ifx is_signed then (has_nsw(op0) && has_nsw(op1)) else (has_nuw(op0) && has_nuw(op1));
            if cond {
                one := const_int_of(vtype(x), 1);
                dividend := icb_shl(one, y, "shl.dividend", true, ifx is_signed then (has_nuw(op0) || has_nuw(op1)) else has_nsw(op0));
                return icb_lshr(dividend, z, "", is_exact(i));
            }
        }
    }
    return NONE;
}

// commonIDivTransforms
ic_common_idiv_transforms :: (i: Value_Id) -> Value_Id {
    r := ic_common_idiv_rem_transforms(i); if r != NONE return r;
    op0 := op(i, 0); op1 := op(i, 1);
    is_signed := inst_op(i) == .SDIV;
    ty := vtype(i);
    okc2, c2 := pm_apint(op1);
    if okc2 {
        // (X / C1) / C2 -> X / (C1*C2)
        okd, x, c1v := pm_binop(op0, ifx is_signed then Opcode.SDIV else .UDIV);
        okc1, c1 := pm_apint(c1v);
        if okd && okc1 {
            ov, prod := multiply_overflows(c1, c2, is_signed);
            if !ov return create_binop(inst_op(i), x, const_int_ap(ty, prod));
        }
        okm, mx, mcv := pm_ob(op0, .MUL, ifx is_signed then cast(u32) F_NSW else F_NUW);
        okmc, mc1 := pm_apint(mcv);
        if okm && okmc {
            ok, q := is_multiple(c2, mc1, is_signed);
            if ok {
                nd := create_binop(inst_op(i), mx, const_int_ap(ty, q));
                set_exact(nd, is_exact(i));
                return nd;
            }
            ok, q = is_multiple(mc1, c2, is_signed);
            if ok {
                mul := create_binop(.MUL, mx, const_int_ap(ty, q));
                set_nuw(mul, !is_signed && has_nuw(op0));
                set_nsw(mul, has_nsw(op0));
                return mul;
            }
        }
        oks, sx, scv := pm_ob(op0, .SHL, ifx is_signed then cast(u32) F_NSW else F_NUW);
        oksc, sc1 := pm_apint(scv);
        if oks && oksc && ((is_signed && ap_ult_u64(sc1, sc1.bits - 1)) || (!is_signed && ap_ult_u64(sc1, sc1.bits))) {
            shifted := ap_one_bit_set(sc1.bits, cast(u32) ap_zext_value(sc1));
            ok, q := is_multiple(c2, shifted, is_signed);
            if ok {
                bo := create_binop(inst_op(i), sx, const_int_ap(ty, q));
                set_exact(bo, is_exact(i));
                return bo;
            }
            ok, q = is_multiple(shifted, c2, is_signed);
            if ok {
                mul := create_binop(.MUL, sx, const_int_ap(ty, q));
                set_nuw(mul, !is_signed && has_nuw(op0));
                set_nsw(mul, has_nsw(op0));
                return mul;
            }
        }
        // ((X * C2) + C1) / C2 --> X + C1/C2
        if is_signed {
            oka, am, ac := pm_nsw_add_like_i(op0);
            okac, c1a := pm_apint(ac);
            if oka && okac {
                okmm, xv, mc := pm_ob(am, .MUL, F_NSW);
                if okmm && pm_specific_int_ap(mc, c2) {
                    ok, q := is_multiple(c1a, c2, true);
                    if ok return create_binop_flags(.ADD, xv, const_int_ap(ty, q), F_NSW);
                }
            }
        } else {
            oka, am, ac := pm_nuw_add_like_i(op0);
            okac, c1a := pm_apint(ac);
            if oka && okac {
                okmm, xv, mc := pm_ob(am, .MUL, F_NUW);
                if okmm && pm_specific_int_ap(mc, c2) return create_binop_flags(.ADD, xv, const_int_ap(ty, ap_udiv(c1a, c2)), F_NUW);
            }
        }
        if !ap_is_zero(c2) { rr := ic_fold_binop_into_select_or_phi(i); if rr != NONE return rr; }
    }
    if pm_one(op0) {
        if is_signed {
            f1 := op1;
            if !is_guaranteed_not_to_be_undef(op1) f1 = icb_freeze(op1, tprint("%.fr", vname(op1)));
            inc := icb_add(f1, op0);
            cmp := icb_cmp(ICMP_ULT, inc, const_int_of(ty, 3));
            return ic_create_select_unknown_profile(cmp, f1, const_int_of(ty, 0));
        }
        return create_cast(.ZEXT, icb_cmp(ICMP_EQ, op1, op0), ty);
    }
    if ic_simplify_demanded_instruction_bits(i) return i;
    // (X - (X rem Y)) / Y -> X / Y
    {
        oks, x, z := pm_binop(op0, .SUB);
        if oks {
            okr, rx, ry := pm_binop(z, ifx is_signed then Opcode.SREM else .UREM);
            if okr && rx == x && ry == op1 return create_binop(inst_op(i), x, op1);
        }
    }
    // (X << Y) / X -> 1 << Y
    {
        oks, sx, y := pm_ob(op0, .SHL, ifx is_signed then cast(u32) F_NSW else F_NUW);
        if oks && sx == op1 return create_binop_flags(.SHL, const_int_of(ty, 1), y, ifx is_signed then cast(u32) F_NSW else F_NUW);
    }
    // X / (X * Y) -> 1 / Y if the multiplication does not overflow
    {
        ok, y := pm_c_binop_with(op1, .MUL, op0);
        if ok {
            nsw := has_nsw(op1); nuw := has_nuw(op1);
            if (is_signed && nsw) || (!is_signed && nuw) {
                ic_replace_operand(i, 0, const_int_of(ty, 1));
                ic_replace_operand(i, 1, y);
                return i;
            }
        }
    }
    // (X << Z) / (X * Y) -> (1 << Z) / Y
    if !is_signed && has_one_use(op1) {
        oks, x, z := pm_ob(op0, .SHL, F_NUW);
        if oks {
            okm, y := pm_c_binop_with(op1, .MUL, x);
            if okm && has_nuw(op1) {
                nd := create_binop(.UDIV, icb_shl(const_int_of(ty, 1), z, "", true), y);
                set_exact(nd, is_exact(i));
                return nd;
            }
        }
    }
    {
        rv := ic_fold_idiv_shl(i);
        if rv != NONE return ic_replace_inst_uses_with(i, rv);
    }
    // ((Op1 * X) / Y) / Op1 --> X / Y
    {
        okd, m, y := pm_binop(op0, inst_op(i));
        if okd {
            okm, x := pm_c_binop_with(m, .MUL, op1);
            if okm {
                nd: Value_Id = NONE;
                if !is_signed && has_nuw(m) nd = create_binop(.UDIV, x, y);
                else if is_signed && has_nsw(m) nd = create_binop(.SDIV, x, y);
                if nd != NONE { set_exact(nd, is_exact(i) && is_exact(op0)); return nd; }
            }
        }
    }
    // X / (select Cond, 1, Y) --> select Cond, X, (X / Y) and the mirror
    {
        is_safe_divisor :: (v: Value_Id, is_signed: bool, i: Value_Id) -> bool {
            if is_signed { ok, c := pm_apint(v); return ok && !ap_is_zero(c) && !ap_is_all_ones(c); }
            return is_known_non_zero(v, ic_q(i)) && is_guaranteed_not_to_be_poison(v, ic.ac, i, ic.dt);
        }
        ok, cond, tv, fv := pm_select(op1);
        if ok && has_one_use(op1) {
            if pm_one(tv) && is_safe_divisor(fv, is_signed, i) {
                nd := icb_binop(inst_op(i), op0, fv, "", ifx is_exact(i) then cast(u32) F_EXACT else 0);
                s := create_select(cond, op0, nd); copy_prof_unpredictable(s, op1);
                return s;
            }
            if pm_one(fv) && is_safe_divisor(tv, is_signed, i) {
                nd := icb_binop(inst_op(i), op0, tv, "", ifx is_exact(i) then cast(u32) F_EXACT else 0);
                s := create_select(cond, nd, op0); copy_prof_unpredictable(s, op1);
                return s;
            }
        }
    }
    // (X * Y) / (X * Z) --> Y / Z
    {
        okm, x, y := pm_binop(op0, .MUL);
        if okm {
            ob0_nsw := has_nsw(op0); ob0_nuw := has_nuw(op0);
            create_div_or_null :: (a: Value_Id, b: Value_Id, is_signed: bool, ob0_nsw: bool, ob0_nuw: bool, op1: Value_Id) -> Value_Id {
                ob1_nsw := has_nsw(op1); ob1_nuw := has_nuw(op1);
                if is_signed && ob0_nsw {
                    okc, c1 := pm_apint(b);
                    if ob1_nsw && okc && !ap_is_all_ones(c1) return create_binop(.SDIV, a, b);
                }
                if !is_signed && ob0_nuw {
                    if ob1_nuw return create_binop(.UDIV, a, b);
                    oka, c1 := pm_apint(a);
                    okb, c2 := pm_apint(b);
                    if oka && okb && ap_ule(c2, c1) return create_binop(.UDIV, a, b);
                }
                return NONE;
            }
            ok, z := pm_c_binop_with(op1, .MUL, x);
            if ok { vv := create_div_or_null(y, z, is_signed, ob0_nsw, ob0_nuw, op1); if vv != NONE return vv; }
            ok, z = pm_c_binop_with(op1, .MUL, y);
            if ok { vv := create_div_or_null(x, z, is_signed, ob0_nsw, ob0_nuw, op1); if vv != NONE return vv; }
        }
    }
    return NONE;
}

// narrowUDivURem
ic_narrow_udiv_urem :: (i: Value_Id) -> Value_Id {
    opc := inst_op(i);
    n := op(i, 0); d := op(i, 1);
    ty := vtype(i);
    okx, x := pmi_cast(n, .ZEXT);
    oky, y := pmi_cast(d, .ZEXT);
    if okx && oky && vtype(x) == vtype(y) && (has_one_use(n) || has_one_use(d))
        return create_cast(.ZEXT, icb_binop(opc, x, y), ty);
    if is_inst(n) && okx && has_one_use(n) && pm_constant(d) {
        tc := get_lossless_unsigned_trunc(d, vtype(x));
        if tc == NONE return NONE;
        return create_cast(.ZEXT, icb_binop(opc, x, tc), ty);
    }
    okx2, x2 := pmi_cast(d, .ZEXT);
    if is_inst(d) && okx2 && has_one_use(d) && pm_constant(n) {
        tc := get_lossless_unsigned_trunc(n, vtype(x2));
        if tc == NONE return NONE;
        return create_cast(.ZEXT, icb_binop(opc, tc, x2), ty);
    }
    return NONE;
}

// ---------------------------------------------------------------- visitUDiv / visitSDiv

ic_visit_udiv :: (i: Value_Id) -> Value_Id {
    v := simplify_udiv_inst(op(i, 0), op(i, 1), is_exact(i), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_common_idiv_transforms(i); if r != NONE return r;
    op0 := op(i, 0); op1 := op(i, 1);
    {
        okl, x, c1v := pm_binop(op0, .LSHR);
        okc1, c1 := pm_apint(c1v);
        okc2, c2 := pm_apint(op1);
        if okl && okc1 && okc2 {
            s, ov := ap_ushl_ov(c2, c1);
            if !ov {
                ex := is_exact(i) && is_exact(op0);
                bo := create_binop(.UDIV, x, const_int_ap(vtype(x), s));
                if ex set_exact(bo);
                return bo;
            }
        }
    }
    ty := vtype(i);
    if pm_negative(op1) return create_zext_or_bitcast(icb_cmp(ICMP_UGE, op0, op1), ty);
    {
        oks, x := pmi_cast(op1, .SEXT);
        if oks && is_int_or_int_vector_n(vtype(x), 1) return create_zext_or_bitcast(icb_cmp(ICMP_EQ, op0, const_all_ones_of(ty)), ty);
    }
    r = ic_narrow_udiv_urem(i); if r != NONE return r;
    // ((Op1 *nuw A) >> B) / Op1 --> A >> B
    {
        okl, m, b := pm_binop(op0, .LSHR);
        if okl {
            okm, m0, m1 := pm_ob(m, .MUL, F_NUW);
            a: Value_Id = NONE;
            if okm { if m0 == op1 a = m1; else if m1 == op1 a = m0; }
            if a != NONE {
                lshr := create_binop(.LSHR, a, b);
                if is_exact(i) && is_exact(op0) set_exact(lshr);
                return lshr;
            }
        }
    }
    {
        res := ic_try_get_log2(op1, true);
        if res == NONE && ic_is_known_to_be_power_of_two(op1, true, i) res = icb_binary_intrinsic(IID_CTTZ, op1, get_true(ir.t_i1));
        if res != NONE return ic_replace_inst_uses_with(i, icb_lshr(op0, res, name_ref(vname(i)), is_exact(i)));
    }
    return NONE;
}
// CastInst::CreateZExtOrBitCast
create_zext_or_bitcast :: (v: Value_Id, t: Type_Id) -> Value_Id {
    if type_bits(scalar_type(vtype(v))) == type_bits(scalar_type(t))  return create_cast(.BITCAST, v, t);
    return create_cast(.ZEXT, v, t);
}

ic_visit_sdiv :: (i: Value_Id) -> Value_Id {
    v := simplify_sdiv_inst(op(i, 0), op(i, 1), is_exact(i), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_common_idiv_transforms(i); if r != NONE return r;
    op0 := op(i, 0); op1 := op(i, 1);
    ty := vtype(i);
    {
        oks, x := pmi_cast(op1, .SEXT);
        if pm_all_ones(op1) || (oks && is_int_or_int_vector_n(vtype(x), 1)) return create_binop_flags(.SUB, const_null_value(ty), op0, F_NSW);
    }
    if pm_sign_mask(op1) return create_cast(.ZEXT, icb_cmp(ICMP_EQ, op0, op1), ty);
    if is_exact(i) {
        if pm_power2(op1) && pm_non_negative(op1) {
            c := ce_exact_log_base2(op1);
            return create_binop_flags(.ASHR, op0, c, F_EXACT);
        }
        oks, one, shamt := pm_ob(op1, .SHL, F_NSW);
        if oks && pm_one(one) return create_binop_flags(.ASHR, op0, shamt, F_EXACT);
        if pm_negated_power2(op1) {
            negp := ce_neg(op1);
            c := ce_exact_log_base2(negp);
            ashr := icb_ashr(op0, c, tprint("%.neg", vname(i)), true);
            return create_binop_flags(.SUB, const_null_value(vtype(ashr)), ashr, F_NSW);
        }
    }
    okc, op1c := pm_apint(op1);
    if okc {
        oks, src := pmi_cast(op0, .SEXT);
        if oks && has_one_use(op0) && scalar_bits(src) >= ap_significant_bits(op1c) {
            nd := ce_cast(.TRUNC, op1, vtype(src));
            nop := icb_sdiv(src, nd);
            return create_cast(.SEXT, nop, ty);
        }
        okn, x := pm_nsw_neg(op0);
        if !ap_is_min_signed(op1c) && okn {
            bo := create_binop(.SDIV, x, const_int_ap(ty, ap_neg(op1c)));
            set_exact(bo, is_exact(i));
            return bo;
        }
    }
    // -X / Y --> -(X / Y)
    {
        okn, x := pm_nsw_neg(op0);
        if okn && has_one_use(op0) && is_inst(op0)
            return create_binop_flags(.SUB, const_null_value(ty), icb_sdiv(x, op1, name_ref(vname(i)), is_exact(i)), F_NSW);
    }
    // abs(X) / X --> X > -1 ? 1 : -1 (and X / abs(X))
    for side: 0..1 {
        ab := op(i, cast(u32) side); x := op(i, cast(u32) (1 - side));
        ok, ax, p := pm_intrinsic2(ab, IID_ABS);
        if ok && has_one_use(ab) && pm_one(p) && ax == x {
            cond := icb_cmp(ICMP_SGT, x, const_all_ones_of(vtype(x)));
            return ic_create_select_unknown_profile(cond, const_int_of(ty, 1), const_all_ones_of(ty));
        }
    }
    kd := ic_known_bits(op0, i);
    if !is_exact(i) {
        okp, pc := pm_power2_ap(op1);
        if !okp okp, pc = pm_apint_pred(op1, ap_is_negated_power_of_2);
        if okp && kb_count_min_trailing_zeros(kd) >= ap_ctz(pc) { set_exact(i); return i; }
    }
    if kb_is_non_negative(kd) {
        if is_known_non_negative(op1, ic_q(i)) {
            bo := create_binop(.UDIV, op0, op1);
            set_name(bo, vname(i));
            set_exact(bo, is_exact(i));
            return bo;
        }
        if pm_negated_power2(op1) {
            cnl := ce_exact_log_base2(ce_neg(op1));
            shr := icb_lshr(op0, cnl, name_ref(vname(i)), is_exact(i));
            return create_neg(shr);
        }
        if ic_is_known_to_be_power_of_two(op1, true, i) {
            bo := create_binop(.UDIV, op0, op1);
            set_name(bo, vname(i));
            set_exact(bo, is_exact(i));
            return bo;
        }
    }
    if is_known_negation(op0, op1) {
        minv := ap_signed_min(scalar_bits(i));
        cond := icb_cmp(ICMP_EQ, op0, const_int_ap(ty, minv));
        return ic_create_select_unknown_profile(cond, const_int_of(ty, 1), const_all_ones_of(ty));
    }
    return NONE;
}

// ---------------------------------------------------------------- remainders

// simplifyIRemMulShl
ic_simplify_irem_mul_shl :: (i: Value_Id) -> Value_Id {
    op0 := op(i, 0); op1 := op(i, 1);
    x: Value_Id = NONE;
    y, z: APInt;
    shift_by_x := false;
    match_shift_or_mul_xc :: (o: Value_Id, v: *Value_Id, c: *APInt, preserve_nsw: *bool) -> bool {
        okm, mx, mc := pm_binop(o, .MUL);
        if okm && (v.* == NONE || mx == v.*) {
            okc, cv := pm_apint(mc);
            if okc { v.* = mx; c.* = cv; return true; }
            if v.* == NONE v.* = mx;   // m_Value(V) bound before m_APInt failed
        }
        oks, sx, sc := pm_binop(o, .SHL);
        if oks && (v.* == NONE || sx == v.*) {
            okc, cv := pm_apint(sc);
            if okc { v.* = sx; c.* = ap_shl_ap(ap_one(cv.bits), cv); preserve_nsw.* = ap_ult_u64(cv, cv.bits - 1); return true; }
        }
        v.* = NONE;
        return false;
    }
    match_shift_cx :: (o: Value_Id, c: *APInt, v: *Value_Id) -> bool {
        oks, sc, sx := pm_binop(o, .SHL);
        if oks {
            okc, cv := pm_apint(sc);
            if okc && (v.* == NONE || sx == v.*) { c.* = cv; v.* = sx; return true; }
        }
        v.* = NONE;
        return false;
    }
    p0 := true; p1 := true;
    if match_shift_or_mul_xc(op0, *x, *y, *p0) && match_shift_or_mul_xc(op1, *x, *z, *p1) {
    } else if match_shift_cx(op0, *y, *x) && match_shift_cx(op1, *z, *x) {
        shift_by_x = true;
    } else return NONE;
    is_srem := inst_op(i) == .SREM;
    bo0_nsw := p0 && has_nsw(op0);
    bo0_nuw := has_nuw(op0);
    bo0_nw := ifx is_srem then bo0_nsw else bo0_nuw;
    remyz := ifx is_srem then ap_srem(y, z) else ap_urem(y, z);
    if ap_is_zero(remyz) && bo0_nw return ic_replace_inst_uses_with(i, const_null_value(vtype(i)));
    create_mul_or_shift :: (c: APInt, shift_by_x: bool, x: Value_Id, ty: Type_Id) -> Value_Id {
        rs := const_int_ap(ty, c);
        if shift_by_x return create_binop(.SHL, rs, x);
        return create_binop(.MUL, x, rs);
    }
    bo1_nsw := p1 && has_nsw(op1);
    bo1_nuw := has_nuw(op1);
    bo1_nw := ifx is_srem then bo1_nsw else bo1_nuw;
    if ap_eq(remyz, y) && bo1_nw {
        bo := create_mul_or_shift(y, shift_by_x, x, vtype(i));
        set_nsw(bo, is_srem || bo0_nsw);
        set_nuw(bo, !is_srem || bo0_nuw);
        return bo;
    }
    if ap_uge(y, z) && (ifx is_srem then (bo0_nsw && bo1_nsw) else bo0_nuw) {
        bo := create_mul_or_shift(remyz, shift_by_x, x, vtype(i));
        set_nsw(bo);
        set_nuw(bo, bo0_nuw);
        return bo;
    }
    return NONE;
}

// commonIRemTransforms
ic_common_irem_transforms :: (i: Value_Id) -> Value_Id {
    r := ic_common_idiv_rem_transforms(i); if r != NONE return r;
    op0 := op(i, 0); op1 := op(i, 1);
    if is_const(op1) && is_inst(op0) {
        if inst_op(op0) == .SELECT {
            rr := ic_fold_op_into_select(i, op0);
            if rr != NONE return rr;
        } else if inst_op(op0) == .PHI {
            okc, c := pm_apint(op1);
            if okc && !ap_is_zero(c) && (inst_op(i) == .UREM || !ap_is_min_signed(c)) {
                nv := ic_fold_op_into_phi(i, op0);
                if nv != NONE return nv;
            }
        }
        if ic_simplify_demanded_instruction_bits(i) return i;
    }
    r = ic_simplify_irem_mul_shl(i); if r != NONE return r;
    return NONE;
}

ic_visit_urem :: (i: Value_Id) -> Value_Id {
    v := simplify_urem_inst(op(i, 0), op(i, 1), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_common_irem_transforms(i); if r != NONE return r;
    r = ic_narrow_udiv_urem(i); if r != NONE return r;
    op0 := op(i, 0); op1 := op(i, 1);
    ty := vtype(i);
    if ic_is_known_to_be_power_of_two(op1, true, i) {
        add := icb_add(op1, const_all_ones_of(ty));
        return create_binop(.AND, op0, add);
    }
    if pm_one(op0) return create_zext_or_bitcast(icb_cmp(ICMP_NE, op1, const_int_of(ty, 1)), ty);
    if pm_negative(op1) {
        f0 := op0;
        if !is_guaranteed_not_to_be_undef(op0) f0 = icb_freeze(op0, tprint("%.fr", vname(op0)));
        cmp := icb_cmp(ICMP_ULT, f0, op1);
        sub := icb_sub(f0, op1);
        return ic_create_select_unknown_profile(cmp, f0, sub);
    }
    {
        oks, x := pmi_cast(op1, .SEXT);
        if oks && is_int_or_int_vector_n(vtype(x), 1) {
            f0 := op0;
            if !is_guaranteed_not_to_be_undef(op0) f0 = icb_freeze(op0, tprint("%.frozen", vname(op0)));
            cmp := icb_cmp(ICMP_EQ, f0, const_all_ones_of(ty));
            return ic_create_select_unknown_profile(cmp, const_null_value(ty), f0);
        }
    }
    {
        oka, x, one := pm_binop(op0, .ADD);
        if oka && pm_one(one) {
            val := simplify_icmp_inst(ICMP_ULT, false, x, op1, ic_q(i));
            if val != NONE && pm_one(val) {
                f0 := op0;
                if !is_guaranteed_not_to_be_undef(op0) f0 = icb_freeze(op0, tprint("%.frozen", vname(op0)));
                cmp := icb_cmp(ICMP_EQ, f0, op1);
                return ic_create_select_unknown_profile(cmp, const_null_value(ty), f0);
            }
        }
    }
    return NONE;
}

ic_visit_srem :: (i: Value_Id) -> Value_Id {
    v := simplify_srem_inst(op(i, 0), op(i, 1), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_common_irem_transforms(i); if r != NONE return r;
    op0 := op(i, 0); op1 := op(i, 1);
    ty := vtype(i);
    {
        ok, y := pm_negative_ap(op1);
        if ok && !ap_is_min_signed(y) return ic_replace_operand(i, 1, const_int_ap(ty, ap_neg(y)));
    }
    {
        okn, x := pm_nsw_neg(op0);
        if okn && has_one_use(op0) && is_inst(op0) return create_binop_flags(.SUB, const_null_value(ty), icb_binop(.SREM, x, op1), F_NSW);
    }
    mask := ap_signed_min(scalar_bits(i));
    if ic_masked_value_is_zero(op1, mask, i) && ic_masked_value_is_zero(op0, mask, i) {
        u := create_binop(.UREM, op0, op1);
        set_name(u, vname(i));
        return u;
    }
    k := vkind(op1);
    if k == .C_VECTOR || (k == .C_DATA && is_vector_type(vtype(op1))) {
        n := type_count(vtype(op1));
        has_negative := false; has_missing := false;
        elts := NewArray(cast(s64) n, Value_Id,, allocator = temp);
        for e: 0..cast(s64) n - 1 {
            elt := cf_elt(op1, cast(u64) e);
            if elt == NONE { has_missing = true; break; }
            elts[e] = elt;
            if vkind(elt) == .C_INT && ap_is_negative(const_ap(elt)) has_negative = true;
        }
        if has_negative && !has_missing {
            for e: 0..cast(s64) n - 1 if vkind(elts[e]) == .C_INT && ap_is_negative(const_ap(elts[e])) elts[e] = ce_neg(elts[e]);
            nrhs := cf_vector(vtype(op1), elts);
            if nrhs != op1 return ic_replace_operand(i, 1, nrhs);
        }
    }
    return NONE;
}

