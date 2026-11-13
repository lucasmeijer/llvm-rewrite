// InstCombine for fadd, fsub, fneg: InstCombineAddSub.cpp (visitFAdd, visitFSub, visitFNeg, foldFNegIntoConstant,
// hoistFNegAboveFMulFDiv, factorizeLerp, factorizeFAddFSub, foldSquareSumFP) and foldFBinOpOfIntCasts from
// InstructionCombining.cpp. FAddCombine (the reassociating fadd/fsub simplifier) is not ported: it fails loudly
// when reached.

FMF_VALUE_MASK :: cast(u32)(FMF_NNAN | FMF_NINF | FMF_NSZ);
FMF_REWRITE_MASK :: cast(u32)(FMF_REASSOC | FMF_ARCP | FMF_CONTRACT | FMF_AFN);
fmf_union_value :: (a: u32, b: u32) -> u32 { return FMF_VALUE_MASK & (a | b); }
fmf_intersect_rewrite :: (a: u32, b: u32) -> u32 { return FMF_REWRITE_MASK & a & b; }
has_fmf :: (i: Value_Id, f: u32) -> bool { return (get_fmf(i) & f) != 0; }

// Builder.CreateF*FMF(L, R, FMFSource)
icb_fadd_fmf :: (l: Value_Id, r: Value_Id, src: Value_Id, name: string = "") -> Value_Id { return icb_binop_fmf(.FADD, l, r, get_fmf(src), name); }
icb_fsub_fmf :: (l: Value_Id, r: Value_Id, src: Value_Id, name: string = "") -> Value_Id { return icb_binop_fmf(.FSUB, l, r, get_fmf(src), name); }
icb_fmul_fmf :: (l: Value_Id, r: Value_Id, src: Value_Id, name: string = "") -> Value_Id { return icb_binop_fmf(.FMUL, l, r, get_fmf(src), name); }
icb_fdiv_fmf :: (l: Value_Id, r: Value_Id, src: Value_Id, name: string = "") -> Value_Id { return icb_binop_fmf(.FDIV, l, r, get_fmf(src), name); }
// BinaryOperator::CreateF*FMF(L, R, FMFSource) (unlinked)
create_fop :: (opc: Opcode, l: Value_Id, r: Value_Id, src: Value_Id) -> Value_Id { return create_binop_fmf(opc, l, r, get_fmf(src)); }

// m_FMul / m_FDiv / m_FAdd / m_FSub (instructions only)
pm_fbin :: (v: Value_Id, opc: Opcode) -> (bool, Value_Id, Value_Id) { ok, a, b := pm_binop(v, opc); return ok, a, b; }

// canIgnoreSignBitOfZero (ValueTracking.cpp)
can_ignore_sign_bit_of_zero :: (u: Use_Id) -> bool {
    user := ir.u_user[u];
    if is_fp_math_op_value(user) && (get_fmf(user) & FMF_NSZ) != 0 return true;
    o := inst_op(user);
    if o == .FPTOSI || o == .FPTOUI || o == .FCMP return true;
    if o == .CALL {
        id := call_iid(user);
        if id == IID_FABS return true;
        if id == IID_COPYSIGN return u - ir.v_ops[user] == 0;
        if id == IID_IS_FPCLASS || id == IID_VP_IS_FPCLASS {
            t := cast(u32) const_int_zext(op(user, 1)) & FC_ZERO;
            return t == FC_ZERO || t == 0;
        }
    }
    return false;
}

// ---------------------------------------------------------------- foldFBinOpOfIntCasts (InstructionCombining.cpp)

ic_fold_fbinop_of_int_casts_from_sign :: (bo: Value_Id, from_signed: bool, ops_in: [2] Value_Id, op1fpc: Value_Id) -> Value_Id {
    int_ops := ops_in;
    fpty := vtype(bo);
    ity := vtype(int_ops[0]);
    isz := scalar_bits(int_ops[0]);
    p, mx, mn, b := fp_semantics(type_kind(scalar_type(fpty)));
    max_repr := cast(u32) p;
    used: [2] u32; used[0] = isz; used[1] = isz;
    sq := ic.sq;
    is_non_zero :: (v: Value_Id, sq: Simplify_Query) -> bool {
        if kb_is_non_zero(known_bits(v, sq)) return true;
        return is_known_non_zero(v, sq);
    }
    is_valid_promotion :: (k: s64, bo: Value_Id, from_signed: bool, int_ops: [2] Value_Id, used: *[2] u32, max_repr: u32, isz: u32, sq: Simplify_Query) -> bool {
        is_si := inst_op(op(bo, cast(u32) k)) == .SITOFP;
        if from_signed != is_si && !kb_is_non_negative(known_bits(int_ops[k], sq)) return false;
        if max_repr < isz {
            if from_signed used.*[k] = isz - num_sign_bits_ctx(int_ops[k], NONE, ic.dt, ic.ac);
            else used.*[k] = isz - kb_count_min_leading_zeros(known_bits(int_ops[k], sq));
        }
        if max_repr < used.*[k] return false;
        return !from_signed || inst_op(bo) != .FMUL || is_non_zero(int_ops[k], sq);
    }
    if op1fpc != NONE {
        if from_signed && inst_op(bo) == .FMUL && !pm_fp_pred(op1fpc, (f: APFloat) -> bool { return !apf_is_zero(f); }) return NONE;
        op1ic := cfo_cast_operand(ifx from_signed then Opcode.FPTOSI else .FPTOUI, op1fpc, ity);
        if op1ic == NONE return NONE;
        if cfo_cast_operand(ifx from_signed then Opcode.SITOFP else .UITOFP, op1ic, fpty) != op1fpc return NONE;
        int_ops[1] = op1ic;
    }
    if ity != vtype(int_ops[1]) return NONE;
    if op1fpc == NONE { if !is_valid_promotion(1, bo, from_signed, int_ops, *used, max_repr, isz, sq) return NONE; }
    if !is_valid_promotion(0, bo, from_signed, int_ops, *used, max_repr, isz, sq) return NONE;
    int_opc: Opcode;
    needs_check := true;
    max_out: u32 = ifx from_signed then cast(u32) 2 else 1;
    max_cur := max(used[0], used[1]);
    out_signed := from_signed;
    if inst_op(bo) == {
        case .FADD; int_opc = .ADD; max_out += max_cur;
        case .FSUB; int_opc = .SUB; max_out += max_cur;
        case .FMUL; int_opc = .MUL; max_out += max_cur * 2;
        case; fatal("internal: foldFBinOpOfIntCasts");
    }
    if max_out < isz {
        needs_check = false;
        if int_opc == .SUB out_signed = true;
    }
    if needs_check && !ic_will_not_overflow(int_opc, int_ops[0], int_ops[1], bo, out_signed) return NONE;
    ib := icb_binop(int_opc, int_ops[0], int_ops[1]);
    if is_binary_operator(ib) { set_nsw(ib, out_signed); set_nuw(ib, !out_signed); }
    return create_cast(ifx out_signed then Opcode.SITOFP else .UITOFP, ib, fpty);
}
ic_fold_fbinop_of_int_casts :: (bo: Value_Id) -> Value_Id {
    if is_vector_type(vtype(bo)) return NONE;
    ops: [2] Value_Id;
    o0 := op(bo, 0); o1 := op(bo, 1);
    if !is_inst(o0) || (inst_op(o0) != .SITOFP && inst_op(o0) != .UITOFP) return NONE;
    ops[0] = op(o0, 0);
    fpc: Value_Id = NONE;
    if is_const(o1) fpc = o1;
    else if is_inst(o1) && (inst_op(o1) == .SITOFP || inst_op(o1) == .UITOFP) ops[1] = op(o1, 0);
    else return NONE;
    if fpc != NONE ops[1] = NONE;
    r := ic_fold_fbinop_of_int_casts_from_sign(bo, false, ops, fpc);
    if r != NONE return r;
    return ic_fold_fbinop_of_int_casts_from_sign(bo, true, ops, fpc);
}

// ---------------------------------------------------------------- fneg

// foldFNegIntoConstant
ic_fold_fneg_into_constant :: (i: Value_Id) -> Value_Id {
    okn, fnop := pm_fneg(i);
    if !okn || !is_inst(fnop) || !has_one_use(fnop) return NONE;
    okm, x, c := pm_fbin(fnop, .FMUL);
    if okm && is_const(c) {
        negc := cfo_unary_op_operand(.FNEG, c);
        if negc != NONE {
            f := get_fmf(i); of := get_fmf(fnop);
            fmf := fmf_union_value(f, of) | fmf_intersect_rewrite(f, of);
            fmf &= ~cast(u32) FMF_NINF;
            if (f & FMF_NINF) != 0 && (of & FMF_NINF) != 0 fmf |= FMF_NINF;
            return create_binop_fmf(.FMUL, x, negc, fmf);
        }
    }
    okd, dx, dc := pm_fbin(fnop, .FDIV);
    if okd && is_const(dc) {
        negc := cfo_unary_op_operand(.FNEG, dc);
        if negc != NONE {
            fd := create_fop(.FDIV, dx, negc, i);
            fmf := get_fmf(i); of := get_fmf(fnop);
            r := get_fmf(fd) & ~cast(u32)(FMF_NSZ | FMF_NINF);
            if (fmf & FMF_NSZ) != 0 && (of & FMF_NSZ) != 0 r |= FMF_NSZ;
            if (fmf & FMF_NINF) != 0 && (of & FMF_NINF) != 0 r |= FMF_NINF;
            set_fmf(fd, r);
            copy_metadata(fd, fnop);
            return fd;
        }
    }
    if okd && is_const(op(fnop, 0)) {
        negc := cfo_unary_op_operand(.FNEG, op(fnop, 0));
        if negc != NONE {
            fd := create_fop(.FDIV, negc, op(fnop, 1), i);
            fmf := get_fmf(i); of := get_fmf(fnop);
            r := get_fmf(fd) & ~cast(u32)(FMF_NSZ | FMF_NINF);
            if (fmf & FMF_NSZ) != 0 && (of & FMF_NSZ) != 0 r |= FMF_NSZ;
            if (fmf & FMF_NINF) != 0 && (of & FMF_NINF) != 0 r |= FMF_NINF;
            set_fmf(fd, r);
            copy_metadata(fd, fnop);
            return fd;
        }
    }
    oka, ax, ac := pm_fbin(fnop, .FADD);
    if has_fmf(i, FMF_NSZ) && oka && is_const(ac) {
        negc := cfo_unary_op_operand(.FNEG, ac);
        if negc != NONE return create_fop(.FSUB, negc, ax, i);
    }
    return NONE;
}

// hoistFNegAboveFMulFDiv
ic_hoist_fneg_above_fmul_fdiv :: (fnop: Value_Id, src: Value_Id) -> Value_Id {
    okm, x, y := pm_fbin(fnop, .FMUL);
    if okm return icb_fmul_fmf(x, icb_fneg(y, "", src), src);
    okd, dx, dy := pm_fbin(fnop, .FDIV);
    if okd {
        fd := icb_fdiv_fmf(icb_fneg(dx, "", src), dy, src);
        if is_inst(fd) copy_metadata(fd, fnop);
        return fd;
    }
    if is_inst(fnop) && call_iid(fnop) == IID_LDEXP {
        // preserve flags and metadata on the call
        fmf := get_fmf(src) | get_fmf(fnop);
        neg := icb_fneg_fmf(call_arg(fnop, 0), fmf);
        nc := icb_call_fn(call_called_function(fnop), .[neg, call_arg(fnop, 1)]);
        set_fmf(nc, fmf);
        copy_metadata(nc, fnop);
        return nc;
    }
    return NONE;
}

ic_visit_fneg :: (i: Value_Id) -> Value_Id {
    o := op(i, 0);
    v := simplify_fneg_inst(o, get_fmf(i), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    r := ic_fold_fneg_into_constant(i); if r != NONE return r;
    if has_fmf(i, FMF_NSZ) && has_one_use(o) {
        oks, x, y := pm_fbin(o, .FSUB);
        if oks return create_fop(.FSUB, y, x, i);
    }
    if !has_one_use(o) return NONE;
    r = ic_hoist_fneg_above_fmul_fdiv(o, i);
    if r != NONE return ic_replace_inst_uses_with(i, r);
    oks, cond, x, y := pm_select(o);
    if oks {
        propagate :: (s: Value_Id, common: bool, i: Value_Id, o: Value_Id) {
            set_fmf(s, get_fmf(i));
            if is_inst(o) && inst_op(o) == .SELECT {
                set_fmf(s, get_fmf(i) | get_fmf(o));
                if !has_fmf(o, FMF_NSZ) && !common && !is_guaranteed_not_to_be_undef_or_poison(op(o, 0))
                    set_fmf(s, get_fmf(s) & ~cast(u32) FMF_NSZ);
            }
        }
        okp, p := pm_fneg(x);
        if okp {
            negy := icb_fneg(y, tprint("%.neg", vname(y)), i);
            ns := create_select(cond, p, negy);
            propagate(ns, p == y, i, o);
            return ns;
        }
        okp, p = pm_fneg(y);
        if okp {
            negx := icb_fneg(x, tprint("%.neg", vname(x)), i);
            ns := create_select(cond, negx, p);
            propagate(ns, p == x, i, o);
            return ns;
        }
        if pm_imm_constant(x) || pm_imm_constant(y) {
            negx := icb_fneg(x, tprint("%.neg", vname(x)), i);
            negy := icb_fneg(y, tprint("%.neg", vname(y)), i);
            ns := create_select(cond, negx, negy);
            propagate(ns, true, i, o);
            return ns;
        }
    }
    okc, cx, cy := pm_intrinsic2(o, IID_COPYSIGN);
    if okc {
        fmf := get_fmf(i) & get_fmf(o);
        saved := ic.b_fmf; ic.b_fmf = fmf; defer ic.b_fmf = saved;
        negy := icb_fneg(cy);
        ncs := icb_intrinsic(IID_COPYSIGN, .[vtype(cx)], .[cx, negy]);
        if is_inst(ncs) set_fmf(ncs, fmf);
        return ic_replace_inst_uses_with(i, ncs);
    }
    oksh, sx, sp, mask := pm_shuffle(o);
    if oksh && pm_poison(sp) return create_shuffle(icb_fneg(sx, "", i), NONE, mask);
    // fneg (reverse x) --> reverse (fneg x)
    if is_inst(o) && call_iid(o) == IID_VECTOR_REVERSE
        return ic_replace_inst_uses_with(i, icb_vector_reverse(icb_fneg(call_arg(o, 0), "", i)));
    return NONE;
}

// ---------------------------------------------------------------- fsub

ic_visit_fsub :: (i: Value_Id) -> Value_Id {
    v := simplify_fsub_inst(op(i, 0), op(i, 1), get_fmf(i), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_fold_binop_with_phi_operands(i); if r != NONE return r;
    okn, nop := pm_fneg(i);
    if okn return create_fneg_fmf(nop, i);
    r = ic_fold_fneg_into_constant(i); if r != NONE return r;
    r = ic_fold_fbinop_of_int_casts(i); if r != NONE return r;
    op0 := op(i, 0); op1 := op(i, 1);
    ty := vtype(i);
    if has_fmf(i, FMF_NSZ) || cannot_be_negative_zero(op0, ic_q(i)) {
        oks, x, y := pm_fbin(op1, .FSUB);
        if oks && has_one_use(op1) {
            ns := icb_fsub_fmf(y, x, i);
            return create_fop(.FADD, op0, ns, i);
        }
    }
    if has_fmf(i, FMF_NSZ) && vkind(op0) != .C_EXPR && has_one_use(op0) {
        ok, x := pm_fneg(op0);
        if ok {
            fa := icb_fadd_fmf(x, op1, i);
            return create_fneg_fmf(fa, i);
        }
    }
    if is_const(op0) && is_inst(op1) && inst_op(op1) == .SELECT {
        nv := ic_fold_op_into_select(i, op1);
        if nv != NONE return nv;
    }
    if pm_imm_constant(op1) {
        negc := cfo_unary_op_operand(.FNEG, op1);
        if negc != NONE return create_fop(.FADD, op0, negc, i);
    }
    { ok, y := pm_fneg(op1); if ok return create_fop(.FADD, op0, y, i); }
    if has_one_use(op1) {
        okt, t := pmi_cast(op1, .FPTRUNC);
        if okt { ok, y := pm_fneg(t); if ok return create_fop(.FADD, op0, icb_cast(.FPTRUNC, y, ty), i); }
        oke, e := pmi_cast(op1, .FPEXT);
        if oke { ok, y := pm_fneg(e); if ok return create_fop(.FADD, op0, icb_cast(.FPEXT, y, ty), i); }
        okm, m0, m1 := pm_fbin(op1, .FMUL);
        if okm {
            for side: 0..1 {
                n := ifx side == 0 then m0 else m1;
                yv := ifx side == 0 then m1 else m0;
                okf, x := pm_fneg(n);
                if okf { fm := icb_fmul_fmf(x, yv, i); return create_fop(.FADD, op0, fm, i); }
            }
        }
        okd, d0, d1 := pm_fbin(op1, .FDIV);
        if okd {
            ok0, x0 := pm_fneg(d0);
            if ok0 { fd := icb_fdiv_fmf(x0, d1, i); return create_fop(.FADD, op0, fd, i); }
            ok1, y1 := pm_fneg(d1);
            if ok1 { fd := icb_fdiv_fmf(d0, y1, i); return create_fop(.FADD, op0, fd, i); }
        }
    }
    v = ic_simplify_selects_feeding_binop(i, op0, op1);
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if has_fmf(i, FMF_REASSOC) && has_fmf(i, FMF_NSZ) {
        { ok, a, x := pm_fbin(op0, .FSUB); if ok && a == op1 return create_fneg_fmf(x, i); }
        { ok, x := pm_c_binop_with(op1, .FADD, op0); if ok return create_fneg_fmf(x, i); }
        {
            ok, a, c := pm_fbin(op0, .FMUL);
            if ok && a == op1 && is_const(c) {
                cs := cfo_binary_op_operands(.FSUB, c, fp_const(ty, 1));
                if cs != NONE return create_fop(.FMUL, op1, cs, i);
            }
        }
        {
            ok, a, c := pm_fbin(op1, .FMUL);
            if ok && a == op0 && is_const(c) {
                cs := cfo_binary_op_operands(.FSUB, fp_const(ty, 1), c);
                if cs != NONE return create_fop(.FMUL, op0, cs, i);
            }
        }
        if has_one_use(op0) {
            oka, a0, a1 := pm_fbin(op0, .FADD);
            if oka {
                for side: 0..1 {
                    sb := ifx side == 0 then a0 else a1;
                    z := ifx side == 0 then a1 else a0;
                    oks, x, y := pm_fbin(sb, .FSUB);
                    if oks && has_one_use(sb) {
                        xz := icb_fadd_fmf(x, z, i);
                        yw := icb_fadd_fmf(y, op1, i);
                        return create_fop(.FSUB, xz, yw, i);
                    }
                }
            }
        }
        {
            ok0, a0, v0 := pm_intrinsic2(op0, IID_VECTOR_REDUCE_FADD);
            ok1, a1, v1 := pm_intrinsic2(op1, IID_VECTOR_REDUCE_FADD);
            if ok0 && has_one_use(op0) && ok1 && has_one_use(op1) && vtype(v0) == vtype(v1) {
                sub := icb_fsub_fmf(v0, v1, i);
                rdx := icb_intrinsic(IID_VECTOR_REDUCE_FADD, .[vtype(sub)], .[a0, sub], "", i);
                return create_fop(.FSUB, rdx, a1, i);
            }
        }
        r = ic_factorize_fadd_fsub(i); if r != NONE return r;
        v = fadd_combine_simplify(i);
        if v != NONE return ic_replace_inst_uses_with(i, v);
        oks, x, y := pm_fbin(op0, .FSUB);
        if oks && has_one_use(op0) {
            fa := icb_fadd_fmf(y, op1, i);
            return create_fop(.FSUB, x, fa, i);
        }
    }
    return NONE;
}

// factorizeLerp / factorizeFAddFSub
ic_factorize_lerp :: (i: Value_Id) -> Value_Id {
    for side: 0..1 {
        m1 := op(i, cast(u32) side); m2 := op(i, cast(u32) (1 - side));
        if !has_one_use(m1) || !has_one_use(m2) continue;
        ok1, a, b := pm_fbin(m1, .FMUL);
        if !ok1 continue;
        for s2: 0..1 {
            y := ifx s2 == 0 then a else b;
            sb := ifx s2 == 0 then b else a;
            if !has_one_use(sb) continue;
            oks, one, z := pm_fbin(sb, .FSUB);
            if !oks || !pm_fp_one(one) continue;
            okx, x := pm_c_binop_with(m2, .FMUL, z);
            if !okx continue;
            xy := icb_fsub_fmf(x, y, i);
            mulz := icb_fmul_fmf(z, xy, i);
            return create_fop(.FADD, y, mulz, i);
        }
    }
    return NONE;
}
ic_factorize_fadd_fsub :: (i: Value_Id) -> Value_Id {
    r := ic_factorize_lerp(i); if r != NONE return r;
    op0 := op(i, 0); op1 := op(i, 1);
    if !has_one_use(op0) || !has_one_use(op1) return NONE;
    x, y, z: Value_Id = NONE;
    is_fmul := false;
    okm, m0, m1 := pm_fbin(op0, .FMUL);
    if okm {
        okz, yy := pm_c_binop_with(op1, .FMUL, m1);
        if okz { x = m0; z = m1; y = yy; is_fmul = true; }
        else {
            okz, yy = pm_c_binop_with(op1, .FMUL, m0);
            if okz { x = m1; z = m0; y = yy; is_fmul = true; }
        }
    }
    if x == NONE {
        okd, d0, d1 := pm_fbin(op0, .FDIV);
        okd2, e0, e1 := pm_fbin(op1, .FDIV);
        if okd && okd2 && e1 == d1 { x = d0; z = d1; y = e0; is_fmul = false; }
        else return NONE;
    }
    xy := ifx inst_op(i) == .FADD then icb_fadd_fmf(x, y, i) else icb_fsub_fmf(x, y, i);
    okc, c := pm_apfloat(xy);
    if okc && !apf_is_finite_non_zero(c) return NONE;   // !isNormal (denormals count as not normal)
    if okc && apf_is_denormal(c) return NONE;
    return create_fop(ifx is_fmul then Opcode.FMUL else .FDIV, xy, z, i);
}

// ---------------------------------------------------------------- fadd

ic_visit_fadd :: (i: Value_Id) -> Value_Id {
    v := simplify_fadd_inst(op(i, 0), op(i, 1), get_fmf(i), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if ic_simplify_associative_or_commutative(i) return i;
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_fold_binop_with_phi_operands(i); if r != NONE return r;
    r = ic_fold_binop_into_select_or_phi(i); if r != NONE return r;
    {
        ok, a, z := pm_fbin(i, .FADD);
        if has_one_use(i) && pm_any_zero_fp(op(i, 1)) && can_ignore_sign_bit_of_zero(ir.v_first_use[i]) return ic_replace_inst_uses_with(i, op(i, 0));
    }
    for side: 0..1 {
        okn, x := pm_fneg(op(i, cast(u32) side));
        if okn return create_fop(.FSUB, op(i, cast(u32) (1 - side)), x, i);
    }
    for side: 0..1 {
        m := op(i, cast(u32) side); z := op(i, cast(u32) (1 - side));
        if !has_one_use(m) continue;
        okm, m0, m1 := pm_fbin(m, .FMUL);
        if okm {
            for s2: 0..1 {
                n := ifx s2 == 0 then m0 else m1;
                y := ifx s2 == 0 then m1 else m0;
                okf, x := pm_fneg(n);
                if okf { xy := icb_fmul_fmf(x, y, i); return create_fop(.FSUB, z, xy, i); }
            }
        }
    }
    for side: 0..1 {
        d := op(i, cast(u32) side); z := op(i, cast(u32) (1 - side));
        if !has_one_use(d) continue;
        okd, d0, d1 := pm_fbin(d, .FDIV);
        if okd {
            ok0, x := pm_fneg(d0);
            if ok0 { xy := icb_fdiv_fmf(x, d1, i); return create_fop(.FSUB, z, xy, i); }
        }
    }
    for side: 0..1 {
        d := op(i, cast(u32) side); z := op(i, cast(u32) (1 - side));
        if !has_one_use(d) continue;
        okd, d0, d1 := pm_fbin(d, .FDIV);
        if okd {
            ok1, y := pm_fneg(d1);
            if ok1 { xy := icb_fdiv_fmf(d0, y, i); return create_fop(.FSUB, z, xy, i); }
        }
    }
    r = ic_fold_fbinop_of_int_casts(i); if r != NONE return r;
    lhs := op(i, 0); rhs := op(i, 1);
    v = ic_simplify_selects_feeding_binop(i, lhs, rhs);
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if has_fmf(i, FMF_REASSOC) && has_fmf(i, FMF_NSZ) {
        r = ic_factorize_fadd_fsub(i); if r != NONE return r;
        oks, a, b := ic_matches_square_sum(i, true);
        if oks { ab := icb_fadd_fmf(a, b, i); return create_fop(.FMUL, ab, ab, i); }
        for side: 0..1 {
            rd := op(i, cast(u32) side); y := op(i, cast(u32) (1 - side));
            okr, st, x := pm_intrinsic2(rd, IID_VECTOR_REDUCE_FADD);
            if okr && has_one_use(rd) && pm_any_zero_fp(st)
                return ic_replace_inst_uses_with(i, icb_intrinsic(IID_VECTOR_REDUCE_FADD, .[vtype(x)], .[y, x], "", i));
        }
        {
            okr, st, x := pm_intrinsic2(lhs, IID_VECTOR_REDUCE_FADD);
            oksc, sc := pm_apfloat(st);
            okc, c := pm_apfloat(rhs);
            if okr && has_one_use(lhs) && oksc && okc {
                // fadd (rdx StartC, X), C --> rdx (C + StartC), X
                sum := fp_add_sub(c.k, c.w, sc.w, false);
                nsc := const_fp_words(vtype(i), sum);
                return ic_replace_inst_uses_with(i, icb_intrinsic(IID_VECTOR_REDUCE_FADD, .[vtype(x)], .[nsc, x], "", i));
            }
        }
        for side: 0..1 {
            m := op(i, cast(u32) side); x := op(i, cast(u32) (1 - side));
            okm, mx, mc := pm_fbin(m, .FMUL);
            if okm && mx == x && pm_imm_constant(mc) {
                nm := cfo_binary_op_operands(.FADD, mc, fp_const(vtype(i), 1));
                if nm != NONE return create_fop(.FMUL, x, nm, i);
            }
        }
        for side: 0..1 {
            s := op(i, cast(u32) side); a := op(i, cast(u32) (1 - side));
            oks2, sn, y := pm_fbin(s, .FSUB);
            if !oks2 continue;
            okn, x := pm_fneg(sn);
            if !okn continue;
            oka, z := pm_c_binop_with(a, .FADD, x);
            if oka return create_fop(.FSUB, z, y, i);
        }
        v = fadd_combine_simplify(i);
        if v != NONE return ic_replace_inst_uses_with(i, v);
    }
    for side: 0..1 {
        mx := op(i, cast(u32) side); mn := op(i, cast(u32) (1 - side));
        okx, x, y := pm_intrinsic2(mx, IID_MAXIMUM);
        okn, a, b := pm_intrinsic2(mn, IID_MINIMUM);
        if okx && okn && ((a == x && b == y) || (a == y && b == x)) {
            res := create_fop(.FADD, x, y, i);
            if !has_fmf(res, FMF_NNAN) set_fmf(res, get_fmf(res) & ~cast(u32) FMF_NINF);
            return res;
        }
    }
    return NONE;
}

// ---------------------------------------------------------------- FAddCombine (InstCombineAddSub.cpp)

FAdd_Coef :: struct {
    is_fp: bool;
    ival: s32;
    f: APFloat;
}
FAddend :: struct {
    val: Value_Id = NONE;   // NONE = constant addend
    coef: FAdd_Coef;
}
fac_is_zero :: (c: FAdd_Coef) -> bool { if !c.is_fp return c.ival == 0; return apf_is_zero(c.f); }
fac_is_int :: (c: FAdd_Coef, v: s32) -> bool { return !c.is_fp && c.ival == v; }
fac_from_int :: (k: Type_Kind, v: s32) -> APFloat {
    r: APFloat; r.k = k;
    mag := ifx v < 0 then -v else v;
    w := fp_from_integer(k, .[cast(u64) mag], 64, false);
    if v < 0 w = fp_neg(k, w);
    for w if it_index < 2 r.w[it_index] = it;
    return r;
}
apf_set_words :: (f: *APFloat, w: [] u64) { f.w[0] = 0; f.w[1] = 0; for w if it_index < 2 f.w[it_index] = it; }
fac_to_fp :: (c: *FAdd_Coef, k: Type_Kind) {
    if c.is_fp return;
    c.f = fac_from_int(k, c.ival);
    c.is_fp = true;
}
fac_add :: (a: *FAdd_Coef, b: FAdd_Coef) {
    if a.is_fp == b.is_fp {
        if !a.is_fp { a.ival += b.ival; return; }
        bb := b.f;
        r, st := fp_add_sub(a.f.k, apf_words(*a.f), apf_words(*bb), false);
        apf_set_words(*a.f, r);
        return;
    }
    if !a.is_fp {
        fac_to_fp(a, b.f.k);
        bb := b.f;
        r, st := fp_add_sub(a.f.k, apf_words(*a.f), apf_words(*bb), false);
        apf_set_words(*a.f, r);
        return;
    }
    t := fac_from_int(a.f.k, b.ival);
    r, st := fp_add_sub(a.f.k, apf_words(*a.f), apf_words(*t), false);
    apf_set_words(*a.f, r);
}
fac_negate :: (c: *FAdd_Coef) {
    if !c.is_fp { c.ival = -c.ival; return; }
    apf_set_words(*c.f, fp_neg(c.f.k, apf_words(*c.f)));
}
fac_mul :: (a: *FAdd_Coef, b: FAdd_Coef) {
    if fac_is_int(b, 1) return;
    if fac_is_int(b, -1) { fac_negate(a); return; }
    if !a.is_fp && !b.is_fp { a.ival *= b.ival; return; }
    k := ifx a.is_fp then a.f.k else b.f.k;
    if !a.is_fp fac_to_fp(a, k);
    other: APFloat;
    if !b.is_fp other = fac_from_int(k, b.ival); else other = b.f;
    r, st := fp_mul(k, apf_words(*a.f), apf_words(*other));
    apf_set_words(*a.f, r);
}
fac_value :: (c: FAdd_Coef, t: Type_Id) -> Value_Id {
    if !c.is_fp return fp_const(t, c.ival);
    g := c.f;
    return const_fp_words(t, apf_words(*g));
}
fadd_set_const :: (a: *FAddend, c: Value_Id, v: Value_Id) {
    a.coef.is_fp = true; a.coef.f = apf_from_const(c); a.val = v;
}
fadd_set_int :: (a: *FAddend, coef: s32, v: Value_Id) { a.coef.is_fp = false; a.coef.ival = coef; a.val = v; }
// dyn_cast<ConstantFP>
is_constant_fp :: (v: Value_Id) -> bool { return v != NONE && vkind(v) == .C_FP; }

// FAddend::drillValueDownOneStep
fadd_drill_value :: (v: Value_Id, a0: *FAddend, a1: *FAddend) -> u32 {
    if v == NONE || !is_inst(v) return 0;
    o := inst_op(v);
    if o == .FADD || o == .FSUB {
        o0 := op(v, 0); o1 := op(v, 1);
        c0 := ifx is_constant_fp(o0) then o0 else NONE;
        c1 := ifx is_constant_fp(o1) then o1 else NONE;
        if c0 != NONE && apf_is_zero(apf_from_const(c0)) o0 = NONE;
        if c1 != NONE && apf_is_zero(apf_from_const(c1)) o1 = NONE;
        if o0 != NONE {
            if c0 == NONE fadd_set_int(a0, 1, o0); else fadd_set_const(a0, c0, NONE);
        }
        if o1 != NONE {
            a := ifx o0 != NONE then a1 else a0;
            if c1 == NONE fadd_set_int(a, 1, o1); else fadd_set_const(a, c1, NONE);
            if o == .FSUB fac_negate(*a.coef);
        }
        if o0 != NONE || o1 != NONE return ifx o0 != NONE && o1 != NONE then cast(u32) 2 else 1;
        z: APFloat; z.k = type_kind(scalar_type(vtype(c0)));
        a0.coef.is_fp = true; a0.coef.f = z; a0.val = NONE;
        return 1;
    }
    if o == .FMUL {
        v0 := op(v, 0); v1 := op(v, 1);
        if is_constant_fp(v0) { fadd_set_const(a0, v0, v1); return 1; }
        if is_constant_fp(v1) { fadd_set_const(a0, v1, v0); return 1; }
    }
    return 0;
}
// FAddend::drillAddendDownOneStep
fadd_drill_addend :: (a: FAddend, a0: *FAddend, a1: *FAddend) -> u32 {
    if a.val == NONE return 0;
    n := fadd_drill_value(a.val, a0, a1);
    if n == 0 || fac_is_int(a.coef, 1) return n;
    fac_mul(*a0.coef, a.coef);
    if n == 2 fac_mul(*a1.coef, a.coef);
    return n;
}

// FAddCombine::simplify
fadd_combine_simplify :: (i: Value_Id) -> Value_Id {
    if is_vector_type(vtype(i)) return NONE;
    o0, o1, o00, o01, o10, o11: FAddend;
    num := fadd_drill_value(i, *o0, *o1);
    e0: u32 = 0; e1: u32 = 0;
    if o0.val != NONE e0 = fadd_drill_addend(o0, *o00, *o01);
    if num == 2 && o1.val != NONE e1 = fadd_drill_addend(o1, *o10, *o11);
    if e0 != 0 && e1 != 0 {
        all: [..] *FAddend; all.allocator = temp;
        array_add(*all, *o00); array_add(*all, *o10);
        if e0 == 2 array_add(*all, *o01);
        if e1 == 2 array_add(*all, *o11);
        v0 := op(i, 0); v1 := op(i, 1);
        quota: u32 = ifx (!is_const(v0) && has_one_use(v0)) && (!is_const(v1) && has_one_use(v1)) then cast(u32) 2 else 1;
        r := fadd_simplify_addends(i, all, quota);
        if r != NONE return r;
    }
    if num != 2 return ifx fac_is_int(o0.coef, 1) then o0.val else NONE;
    if e1 != 0 {
        all: [..] *FAddend; all.allocator = temp;
        array_add(*all, *o0); array_add(*all, *o10);
        if e1 == 2 array_add(*all, *o11);
        r := fadd_simplify_addends(i, all, 1);
        if r != NONE return r;
    }
    if e0 != 0 {
        all: [..] *FAddend; all.allocator = temp;
        array_add(*all, *o1); array_add(*all, *o00);
        if e0 == 2 array_add(*all, *o01);
        r := fadd_simplify_addends(i, all, 1);
        if r != NONE return r;
    }
    return NONE;
}
// FAddCombine::simplifyFAdd
fadd_simplify_addends :: (instr: Value_Id, addends: [..] *FAddend, quota: u32) -> Value_Id {
    n := addends.count;
    tmp: [3] FAddend;
    next_tmp := 0;
    simp: [..] *FAddend; simp.allocator = temp;
    for sym: 0..n-1 {
        this := addends[sym];
        if this == null continue;
        val := this.val;
        start := simp.count;
        array_add(*simp, this);
        for same: sym+1..n-1 {
            t := addends[same];
            if t != null && t.val == val { addends[same] = null; array_add(*simp, t); }
        }
        if start + 1 != simp.count {
            r := *tmp[next_tmp]; next_tmp += 1;
            r.* = simp[start].*;
            for k: start+1..simp.count-1 fac_add(*r.coef, simp[k].coef);
            simp.count = start;
            if !fac_is_zero(r.coef) array_add(*simp, r);
        }
    }
    if simp.count return fadd_create_nary(instr, simp, quota);
    return fp_const(vtype(instr), 0);
}
// calcInstrNumber / createNaryFAdd / createAddendVal and the create* helpers
fadd_create_nary :: (instr: Value_Id, opnds: [..] *FAddend, quota: u32) -> Value_Id {
    needed: u32 = cast(u32) opnds.count - 1;
    for opnds {
        if it.val == NONE continue;
        if pm_undef_value(it.val) continue;
        if !fac_is_int(it.coef, -1) && !fac_is_int(it.coef, 1) needed += 1;
    }
    if needed > quota return NONE;
    post :: (v: Value_Id, instr: Value_Id) -> Value_Id {
        if is_inst(v) { set_metadata(v, 0, get_metadata(instr, 0)); set_fmf(v, get_fmf(instr)); }
        return v;
    }
    last: Value_Id = NONE;
    last_neg := false;
    for opnd: opnds {
        need_neg := false;
        v: Value_Id;
        if opnd.val == NONE { v = fac_value(opnd.coef, vtype(instr)); }
        else if fac_is_int(opnd.coef, -1) || fac_is_int(opnd.coef, 1) { need_neg = fac_is_int(opnd.coef, -1); v = opnd.val; }
        else if fac_is_int(opnd.coef, 2) || fac_is_int(opnd.coef, -2) { need_neg = fac_is_int(opnd.coef, -2); v = post(icb_binop(.FADD, opnd.val, opnd.val), instr); }
        else v = post(icb_binop(.FMUL, opnd.val, fac_value(opnd.coef, vtype(instr))), instr);
        if last == NONE { last = v; last_neg = need_neg; continue; }
        if last_neg == need_neg { last = post(icb_binop(.FADD, last, v), instr); continue; }
        if last_neg last = post(icb_binop(.FSUB, v, last), instr);
        else last = post(icb_binop(.FSUB, last, v), instr);
        last_neg = false;
    }
    if last_neg last = post(icb_fneg(last), instr);
    return last;
}
