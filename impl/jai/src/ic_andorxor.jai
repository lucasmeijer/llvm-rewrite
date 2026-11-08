// InstCombine: visitAnd, visitOr, visitXor and their helpers.
// Ported from: llvm/lib/Transforms/InstCombine/InstCombineAndOrXor.cpp (LLVM 23.1.5), in the file's order, plus
// the CmpInstAnalysis.cpp helpers it uses (getICmpCode, getPredForICmpCode, getPredForFCmpCode,
// predicatesFoldable). insertRangeTest is at the end of the compare folds section below.

// ---------------------------------------------------------------- CmpInstAnalysis.cpp

// getICmpCode
ic_get_icmp_code :: (p: u8) -> u32 {
    if p == {
        case ICMP_UGT; return 1;
        case ICMP_SGT; return 1;
        case ICMP_EQ; return 2;
        case ICMP_UGE; return 3;
        case ICMP_SGE; return 3;
        case ICMP_ULT; return 4;
        case ICMP_SLT; return 4;
        case ICMP_NE; return 5;
        case ICMP_ULE; return 6;
        case ICMP_SLE; return 6;
    }
    fatal("internal: Invalid ICmp predicate!");
    return 0;
}
// getPredForICmpCode: (constant or NONE, predicate)
ic_get_pred_for_icmp_code :: (code: u32, sign: bool, op_ty: Type_Id) -> (Value_Id, u8) {
    if code == {
        case 0; return const_int_of(make_cmp_result_type(op_ty), 0), 0;
        case 1; return NONE, ifx sign then cast(u8) ICMP_SGT else ICMP_UGT;
        case 2; return NONE, ICMP_EQ;
        case 3; return NONE, ifx sign then cast(u8) ICMP_SGE else ICMP_UGE;
        case 4; return NONE, ifx sign then cast(u8) ICMP_SLT else ICMP_ULT;
        case 5; return NONE, ICMP_NE;
        case 6; return NONE, ifx sign then cast(u8) ICMP_SLE else ICMP_ULE;
        case 7; return const_int_of(make_cmp_result_type(op_ty), 1), 0;
    }
    fatal("internal: Illegal ICmp code!");
    return NONE, 0;
}
// predicatesFoldable
ic_predicates_foldable :: (p1: u8, p2: u8) -> bool {
    return (cmp_is_signed(p1) == cmp_is_signed(p2)) || (cmp_is_signed(p1) && icmp_is_equality(p2)) ||
           (cmp_is_signed(p2) && icmp_is_equality(p1));
}
// getPredForFCmpCode
ic_get_pred_for_fcmp_code :: (code: u32, op_ty: Type_Id) -> (Value_Id, u8) {
    p := cast(u8) code;
    if p == FCMP_FALSE return const_int_of(make_cmp_result_type(op_ty), 0), p;
    if p == FCMP_TRUE return const_int_of(make_cmp_result_type(op_ty), 1), p;
    return NONE, p;
}

// ---------------------------------------------------------------- small helpers

// Builder.CreateFCmpFMF(P, L, R, FMF)
icb_fcmp_fmf :: (pred: u8, l: Value_Id, r: Value_Id, fmf: u32, name: string = "") -> Value_Id {
    saved := ic.b_fmf;
    ic.b_fmf = fmf;
    v := icb_cmp(pred, l, r, name);
    ic.b_fmf = saved;
    return v;
}
// FMFSource::intersect(A, B)
ic_fmf_intersect :: (a: Value_Id, b: Value_Id) -> u32 {
    fa: u32 = ifx is_fp_math_op_value(a) then get_fmf(a) else 0;
    fb: u32 = ifx is_fp_math_op_value(b) then get_fmf(b) else 0;
    return fa & fb;
}
// PossiblyDisjointInst::isDisjoint
ic_is_disjoint :: (v: Value_Id) -> bool { return is_inst(v) && inst_op(v) == .OR && (inst(v).flags & F_EXACT) != 0; }
ic_set_disjoint :: (v: Value_Id, on := true) { set_flag(v, F_EXACT, on); }
// ICmpInst::setSameSign
ic_set_same_sign :: (v: Value_Id, on: bool) { set_flag(v, F_EXACT, on); }
ic_has_same_sign :: (v: Value_Id) -> bool { return (inst(v).flags & F_EXACT) != 0; }
// isa<ICmpInst>
ic_is_icmp :: (v: Value_Id) -> bool { return is_inst(v) && inst_op(v) == .ICMP; }
ic_is_fcmp :: (v: Value_Id) -> bool { return is_inst(v) && inst_op(v) == .FCMP; }
// m_c_ICmp(Pred, m_Specific(X), m_Value(Y)): (ok, pred (swapped if X is operand 1), samesign, Y)
pm_c_icmp_with :: (v: Value_Id, x: Value_Id) -> (bool, u8, bool, Value_Id) {
    if !ic_is_icmp(v) return false, 0, false, NONE;
    if op(v, 0) == x return true, inst_pred(v), ic_has_same_sign(v), op(v, 1);
    if op(v, 1) == x return true, icmp_swapped(inst_pred(v)), ic_has_same_sign(v), op(v, 0);
    return false, 0, false, NONE;
}
// Builder.CreateLogicalAnd / CreateLogicalOr (select C, T, false / select C, true, F)
icb_logical_and :: (a: Value_Id, b: Value_Id, name: string = "", md_from: Value_Id = NONE) -> Value_Id {
    return icb_select(a, b, const_null_value(vtype(a)), name, md_from);
}
icb_logical_or :: (a: Value_Id, b: Value_Id, name: string = "", md_from: Value_Id = NONE) -> Value_Id {
    return icb_select(a, const_all_ones_of(vtype(a)), b, name, md_from);
}
icb_logical_op :: (opc: Opcode, a: Value_Id, b: Value_Id, name: string = "", md_from: Value_Id = NONE) -> Value_Id {
    if opc == .AND return icb_logical_and(a, b, name, md_from);
    return icb_logical_or(a, b, name, md_from);
}

// APFloat::bitwiseIsEqual
ic_apf_bitwise_equal :: (a: APFloat, b: APFloat) -> bool { return a.k == b.k && a.w[0] == b.w[0] && a.w[1] == b.w[1]; }
// llvm::neg(APFloat): flip the sign bit
ic_apf_neg :: (f: APFloat) -> APFloat {
    g := f;
    if g.k == {
        case .HALF; g.w[0] ^= 1 << 15;
        case .BFLOAT; g.w[0] ^= 1 << 15;
        case .FLOAT; g.w[0] ^= 1 << 31;
        case .DOUBLE; g.w[0] ^= 1 << 63;
        case .X86_FP80; g.w[1] ^= 1 << 15;
        case .FP128; g.w[1] ^= 1 << 63;
        case .PPC_FP128; g.w[0] ^= 1 << 63; g.w[1] ^= 1 << 63;
    }
    return g;
}
// Builder.CreateFAbs(V, FMF)
icb_fabs_fmf :: (v: Value_Id, fmf: u32, name: string = "") -> Value_Id {
    saved := ic.b_fmf;
    ic.b_fmf = fmf;
    r := icb_unary_intrinsic(IID_FABS, v, name);
    ic.b_fmf = saved;
    return r;
}

// ---------------------------------------------------------------- getNewICmpValue / getFCmpValue

ic_get_new_icmp_value :: (code: u32, sign: bool, lhs: Value_Id, rhs: Value_Id) -> Value_Id {
    tf, p := ic_get_pred_for_icmp_code(code, sign, vtype(lhs));
    if tf != NONE return tf;
    return icb_cmp(p, lhs, rhs);
}
ic_get_fcmp_value :: (code: u32, lhs: Value_Id, rhs: Value_Id, fmf: u32) -> Value_Id {
    tf, p := ic_get_pred_for_fcmp_code(code, vtype(lhs));
    if tf != NONE return tf;
    return icb_fcmp_fmf(p, lhs, rhs, fmf);
}

// ---------------------------------------------------------------- masked icmps

AMASK_ALL_ONES :: 1;
AMASK_NOT_ALL_ONES :: 2;
BMASK_ALL_ONES :: 4;
BMASK_NOT_ALL_ONES :: 8;
MASK_ALL_ZEROS :: 16;
MASK_NOT_ALL_ZEROS :: 32;
AMASK_MIXED :: 64;
AMASK_NOT_MIXED :: 128;
BMASK_MIXED :: 256;
BMASK_NOT_MIXED :: 512;

// getMaskedICmpType
ic_get_masked_icmp_type :: (a: Value_Id, b: Value_Id, c: Value_Id, pred: u8) -> u32 {
    oka, ca := pm_apint(a);
    okb, cb := pm_apint(b);
    okc, cc := pm_apint(c);
    is_eq := pred == ICMP_EQ;
    is_a_pow2 := oka && ap_is_power_of_2(ca);
    is_b_pow2 := okb && ap_is_power_of_2(cb);
    mask_val: u32 = 0;
    if okc && ap_is_zero(cc) {
        mask_val |= ifx is_eq then cast(u32) (MASK_ALL_ZEROS | AMASK_MIXED | BMASK_MIXED) else (MASK_NOT_ALL_ZEROS | AMASK_NOT_MIXED | BMASK_NOT_MIXED);
        if is_a_pow2 mask_val |= ifx is_eq then cast(u32) (AMASK_NOT_ALL_ONES | AMASK_NOT_MIXED) else (AMASK_ALL_ONES | AMASK_MIXED);
        if is_b_pow2 mask_val |= ifx is_eq then cast(u32) (BMASK_NOT_ALL_ONES | BMASK_NOT_MIXED) else (BMASK_ALL_ONES | BMASK_MIXED);
        return mask_val;
    }
    if a == c {
        mask_val |= ifx is_eq then cast(u32) (AMASK_ALL_ONES | AMASK_MIXED) else (AMASK_NOT_ALL_ONES | AMASK_NOT_MIXED);
        if is_a_pow2 mask_val |= ifx is_eq then cast(u32) (MASK_NOT_ALL_ZEROS | AMASK_NOT_MIXED) else (MASK_ALL_ZEROS | AMASK_MIXED);
    } else if oka && okc && ap_is_subset_of(cc, ca) {
        mask_val |= ifx is_eq then cast(u32) AMASK_MIXED else AMASK_NOT_MIXED;
    }
    if b == c {
        mask_val |= ifx is_eq then cast(u32) (BMASK_ALL_ONES | BMASK_MIXED) else (BMASK_NOT_ALL_ONES | BMASK_NOT_MIXED);
        if is_b_pow2 mask_val |= ifx is_eq then cast(u32) (MASK_NOT_ALL_ZEROS | BMASK_NOT_MIXED) else (MASK_ALL_ZEROS | BMASK_MIXED);
    } else if okb && okc && ap_is_subset_of(cc, cb) {
        mask_val |= ifx is_eq then cast(u32) BMASK_MIXED else BMASK_NOT_MIXED;
    }
    return mask_val;
}

// conjugateICmpMask
ic_conjugate_icmp_mask :: (mask: u32) -> u32 {
    nm := (mask & (AMASK_ALL_ONES | BMASK_ALL_ONES | MASK_ALL_ZEROS | AMASK_MIXED | BMASK_MIXED)) << 1;
    nm |= (mask & (AMASK_NOT_ALL_ONES | BMASK_NOT_ALL_ONES | MASK_NOT_ALL_ZEROS | AMASK_NOT_MIXED | BMASK_NOT_MIXED)) >> 1;
    return nm;
}

// decomposeBitTest (the static adapter): (ok, pred, X, Y = mask constant, Z = C constant)
ic_decompose_bit_test_local :: (cond: Value_Id) -> (bool, u8, Value_Id, Value_Id, Value_Id) {
    ok, r := decompose_bit_test(cond, true, true, true);
    if !ok return false, 0, NONE, NONE, NONE;
    t := vtype(r.x);
    return true, r.pred, r.x, const_int_ap(t, r.mask), const_int_ap(t, r.c);
}

Masked_Pair :: struct {
    a, b, c, d, e: Value_Id = NONE;
    pred_l, pred_r: u8;
    left_type, right_type: u32;
}

// getMaskedTypeForICmpPair
ic_get_masked_type_for_icmp_pair :: (lhs: Value_Id, rhs: Value_Id) -> (bool, Masked_Pair) {
    mp: Masked_Pair;
    l1, l11, l12, l2, l21, l22: Value_Id = NONE;
    okd, pl, dx, dy, dz := ic_decompose_bit_test_local(lhs);
    if okd {
        mp.pred_l = pl; l11 = dx; l12 = dy; l2 = dz;
        l21 = NONE; l22 = NONE; l1 = NONE;
    } else {
        if !ic_is_icmp(lhs) return false, mp;
        if !is_int_or_int_vector(vtype(op(lhs, 0))) return false, mp;
        mp.pred_l = inst_pred(lhs);
        l1 = op(lhs, 0); l2 = op(lhs, 1);
        ok1, a1, b1 := pm_binop(l1, .AND);
        if ok1 { l11 = a1; l12 = b1; }
        else { l11 = l1; l12 = const_all_ones_of(vtype(l1)); }
        ok2, a2, b2 := pm_binop(l2, .AND);
        if ok2 { l21 = a2; l22 = b2; }
        else { l21 = l2; l22 = const_all_ones_of(vtype(l2)); }
    }
    if !icmp_is_equality(mp.pred_l) return false, mp;

    in_l :: (v: Value_Id, l11: Value_Id, l12: Value_Id, l21: Value_Id, l22: Value_Id) -> bool {
        return v == l11 || v == l12 || v == l21 || v == l22;
    }
    r11, r12, r2: Value_Id = NONE;
    okr, pr, rx, ry, rz := ic_decompose_bit_test_local(rhs);
    if okr {
        mp.pred_r = pr; r11 = rx; r12 = ry; r2 = rz;
        if in_l(r11, l11, l12, l21, l22) { mp.a = r11; mp.d = r12; }
        else if in_l(r12, l11, l12, l21, l22) { mp.a = r12; mp.d = r11; }
        else return false, mp;
        mp.e = r2;
    } else {
        if !ic_is_icmp(rhs) return false, mp;
        if !is_int_or_int_vector(vtype(op(rhs, 0))) return false, mp;
        mp.pred_r = inst_pred(rhs);
        r1 := op(rhs, 0);
        r2 = op(rhs, 1);
        ok := false;
        oka, ra, rb := pm_binop(r1, .AND);
        if oka { r11 = ra; r12 = rb; }
        else { r11 = r1; r12 = const_all_ones_of(vtype(r1)); }
        if in_l(r11, l11, l12, l21, l22) { mp.a = r11; mp.d = r12; mp.e = r2; ok = true; }
        else if in_l(r12, l11, l12, l21, l22) { mp.a = r12; mp.d = r11; mp.e = r2; ok = true; }
        if ok && pm_all_ones(mp.a) ok = false;
        if !ok {
            oka2, ra2, rb2 := pm_binop(r2, .AND);
            if oka2 { r11 = ra2; r12 = rb2; }
            else { r11 = r2; r12 = const_all_ones_of(vtype(r2)); }
            if in_l(r11, l11, l12, l21, l22) { mp.a = r11; mp.d = r12; mp.e = r1; }
            else if in_l(r12, l11, l12, l21, l22) { mp.a = r12; mp.d = r11; mp.e = r1; }
            else return false, mp;
        }
    }
    if !icmp_is_equality(mp.pred_r) return false, mp;
    if l11 == mp.a { mp.b = l12; mp.c = l2; }
    else if l12 == mp.a { mp.b = l11; mp.c = l2; }
    else if l21 == mp.a { mp.b = l22; mp.c = l1; }
    else if l22 == mp.a { mp.b = l21; mp.c = l1; }
    mp.left_type = ic_get_masked_icmp_type(mp.a, mp.b, mp.c, mp.pred_l);
    mp.right_type = ic_get_masked_icmp_type(mp.a, mp.d, mp.e, mp.pred_r);
    return true, mp;
}

// foldLogOpOfMaskedICmps_NotAllZeros_BMask_Mixed
ic_fold_log_op_of_masked_icmps_not_all_zeros_bmask_mixed :: (lhs: Value_Id, rhs: Value_Id, is_and: bool, a: Value_Id, b: Value_Id, d: Value_Id, e: Value_Id, pred_l: u8, pred_r: u8) -> Value_Id {
    okb, bc := pm_apint(b);
    okd, dc := pm_apint(d);
    oke, orig_ec := pm_apint(e);
    if !okb || !okd || !oke return NONE;
    new_cc := ifx is_and then cast(u8) ICMP_EQ else ICMP_NE;
    ec := orig_ec;
    if pred_r != new_cc ec = ap_xor(ec, dc);
    if ap_is_zero(bc) || ap_is_zero(dc) return NONE;
    if !ap_intersects(bc, dc) {
        okbc, src := pm_elementwise_bitcast(a);
        if ap_eq(dc, ec) && okbc && !fn_has_fn_attr(ic.f, .StrictFP) {
            t := scalar_type(vtype(src));
            if !ic_is_ieee_like_fp_ty(t) return NONE;
            exp_bits := ic_fp_inf_bits(t);
            if ap_ne(ec, exp_bits) return NONE;
            fraction_bits := ap_not(exp_bits);
            ap_clear_sign_bit(*fraction_bits);
            if ap_ne(bc, fraction_bits) return NONE;
            return icb_cmp(ifx is_and then cast(u8) FCMP_UNO else FCMP_ORD, src, const_null_value(vtype(src)));
        }
        return NONE;
    }
    if ap_is_zero(ap_and(ap_and(bc, dc), ec)) && ap_is_power_of_2(ap_and(bc, ap_xor(bc, dc))) {
        bord := ap_or(bc, dc);
        band := ap_or(ap_and(bc, ap_xor(bc, dc)), ec);
        new_mask := const_int_ap(vtype(a), bord);
        new_masked := const_int_ap(vtype(a), band);
        new_and := icb_and(a, new_mask);
        return icb_cmp(new_cc, new_and, new_masked);
    }
    is_subset_or_equal :: (c1: APInt, c2: APInt) -> bool { return ap_eq(ap_and(c1, c2), c1); }
    is_superset_or_equal :: (c1: APInt, c2: APInt) -> bool { return ap_eq(ap_and(c1, c2), c2); }
    if !is_subset_or_equal(bc, dc) && !is_superset_or_equal(bc, dc) return NONE;
    if ap_is_zero(ec) {
        if is_subset_or_equal(bc, dc) return const_int_of(vtype(lhs), ifx is_and then cast(u64) 0 else 1);
        return NONE;
    }
    if is_superset_or_equal(bc, dc) {
        if ic_is_icmp(rhs) ic_set_same_sign(rhs, false);
        return rhs;
    }
    if !ap_is_zero(ap_and(bc, ec)) {
        if ic_is_icmp(rhs) ic_set_same_sign(rhs, false);
        return rhs;
    }
    return const_int_of(vtype(lhs), ifx is_and then cast(u64) 0 else 1);
}

// foldLogOpOfMaskedICmpsAsymmetric
ic_fold_log_op_of_masked_icmps_asymmetric :: (lhs: Value_Id, rhs: Value_Id, is_and: bool, a: Value_Id, b: Value_Id, c: Value_Id, d: Value_Id, e: Value_Id, pred_l: u8, pred_r: u8, lhs_mask_in: u32, rhs_mask_in: u32) -> Value_Id {
    lhs_mask := lhs_mask_in; rhs_mask := rhs_mask_in;
    if !is_and { lhs_mask = ic_conjugate_icmp_mask(lhs_mask); rhs_mask = ic_conjugate_icmp_mask(rhs_mask); }
    if (lhs_mask & MASK_NOT_ALL_ZEROS) != 0 && (rhs_mask & BMASK_MIXED) != 0 {
        v := ic_fold_log_op_of_masked_icmps_not_all_zeros_bmask_mixed(lhs, rhs, is_and, a, b, d, e, pred_l, pred_r);
        if v != NONE return v;
    } else if (lhs_mask & BMASK_MIXED) != 0 && (rhs_mask & MASK_NOT_ALL_ZEROS) != 0 {
        v := ic_fold_log_op_of_masked_icmps_not_all_zeros_bmask_mixed(rhs, lhs, is_and, a, d, b, c, pred_r, pred_l);
        if v != NONE return v;
    }
    return NONE;
}

// foldLogOpOfMaskedICmps
ic_fold_log_op_of_masked_icmps :: (lhs: Value_Id, rhs: Value_Id, is_and: bool, is_logical: bool, q: Simplify_Query) -> Value_Id {
    ok, mp := ic_get_masked_type_for_icmp_pair(lhs, rhs);
    if !ok return NONE;
    a := mp.a; b := mp.b; c := mp.c; d := mp.d; e := mp.e;
    pred_l := mp.pred_l; pred_r := mp.pred_r;
    lhs_mask := mp.left_type; rhs_mask := mp.right_type;
    mask := lhs_mask & rhs_mask;
    if mask == 0 {
        v := ic_fold_log_op_of_masked_icmps_asymmetric(lhs, rhs, is_and, a, b, c, d, e, pred_l, pred_r, lhs_mask, rhs_mask);
        if v != NONE return v;
        return NONE;
    }
    new_cc := ifx is_and then cast(u8) ICMP_EQ else ICMP_NE;
    if !is_and mask = ic_conjugate_icmp_mask(mask);

    if mask & MASK_ALL_ZEROS {
        if is_logical && !is_guaranteed_not_to_be_undef_or_poison(d) return NONE;
        new_or := icb_or(b, d);
        new_and := icb_and(a, new_or);
        zero := const_null_value(vtype(a));
        return icb_cmp(new_cc, new_and, zero);
    }
    if mask & BMASK_ALL_ONES {
        if is_logical && !is_guaranteed_not_to_be_undef_or_poison(d) return NONE;
        new_or := icb_or(b, d);
        new_and := icb_and(a, new_or);
        return icb_cmp(new_cc, new_and, new_or);
    }
    if mask & AMASK_ALL_ONES {
        if is_logical && !is_guaranteed_not_to_be_undef_or_poison(d) return NONE;
        new_and1 := icb_and(b, d);
        new_and2 := icb_and(a, new_and1);
        return icb_cmp(new_cc, new_and2, a);
    }

    okb, const_b := pm_apint(b);
    okd, const_d := pm_apint(d);
    if okb && okd {
        if mask & (MASK_NOT_ALL_ZEROS | BMASK_NOT_ALL_ONES) {
            new_mask := ap_and(const_b, const_d);
            if ap_eq(new_mask, const_b) return lhs;
            if ap_eq(new_mask, const_d) {
                if is_logical && is_inst(rhs) drop_poison_generating_flags(rhs);
                return rhs;
            }
        }
        if mask & AMASK_NOT_ALL_ONES {
            new_mask := ap_or(const_b, const_d);
            if ap_eq(new_mask, const_b) return lhs;
            if ap_eq(new_mask, const_d) return rhs;
        }
        if mask & (BMASK_MIXED | BMASK_NOT_MIXED) {
            okc, old_c := pm_apint(c);
            oke, old_e := pm_apint(e);
            if !okc || !oke return NONE;
            fold_b_mixed :: (cc_in: u8, is_not: bool, lhs: Value_Id, a: Value_Id, is_and: bool, pred_l: u8, pred_r: u8,
                             const_b: APInt, const_d: APInt, old_c: APInt, old_e: APInt) -> Value_Id {
                cc := ifx is_not then cmp_inverse(cc_in) else cc_in;
                const_c := ifx pred_l != cc then ap_xor(const_b, old_c) else old_c;
                const_e := ifx pred_r != cc then ap_xor(const_d, old_e) else old_e;
                if ap_bool(ap_and(ap_and(const_b, const_d), ap_xor(const_c, const_e))) {
                    if is_not return NONE;
                    return const_int_of(vtype(lhs), ifx is_and then cast(u64) 0 else 1);
                }
                if is_not && !ap_is_subset_of(const_b, const_d) && !ap_is_subset_of(const_d, const_b) return NONE;
                bd, ce: APInt;
                if is_not { bd = ap_and(const_b, const_d); ce = ap_and(const_c, const_e); }
                else { bd = ap_or(const_b, const_d); ce = ap_or(const_c, const_e); }
                new_and := icb_and(a, const_int_ap(vtype(a), bd));
                ce_val := const_int_ap(vtype(a), ce);
                return icb_cmp(cc, new_and, ce_val);
            }
            if mask & BMASK_MIXED return fold_b_mixed(new_cc, false, lhs, a, is_and, pred_l, pred_r, const_b, const_d, old_c, old_e);
            if mask & BMASK_NOT_MIXED return fold_b_mixed(new_cc, true, lhs, a, is_and, pred_l, pred_r, const_b, const_d, old_c, old_e);
        }
    }

    if (mask & MASK_NOT_ALL_ZEROS) != 0 && is_known_to_be_a_power_of_two(b, false, q) && is_known_to_be_a_power_of_two(d, false, q) {
        dd := d;
        if is_logical dd = icb_freeze(dd);
        m := icb_or(b, dd);
        masked := icb_and(a, m);
        return icb_cmp(new_cc, masked, m);
    }
    return NONE;
}

// simplifyRangeCheck
ic_simplify_range_check :: (cmp0: Value_Id, cmp1: Value_Id, inverted: bool) -> Value_Id {
    range_start := op(cmp0, 1);
    if vkind(range_start) != .C_INT return NONE;
    pred0 := ifx inverted then cmp_inverse(inst_pred(cmp0)) else inst_pred(cmp0);
    rs := const_ap(range_start);
    if !((pred0 == ICMP_SGT && ap_is_all_ones(rs)) || (pred0 == ICMP_SGE && ap_is_zero(rs))) return NONE;
    pred1 := ifx inverted then cmp_inverse(inst_pred(cmp1)) else inst_pred(cmp1);
    input := op(cmp0, 0);
    cmp1_op0 := op(cmp1, 0); cmp1_op1 := op(cmp1, 1);
    range_end: Value_Id = NONE;
    if sext_or_self_i(cmp1_op0) == input || cmp1_op0 == input {
        input = cmp1_op0; range_end = cmp1_op1;
    } else if sext_or_self_i(cmp1_op1) == input || cmp1_op1 == input {
        input = cmp1_op1; range_end = cmp1_op0;
        pred1 = icmp_swapped(pred1);
    } else return NONE;
    new_pred: u8;
    if pred1 == ICMP_SLT new_pred = ICMP_ULT;
    else if pred1 == ICMP_SLE new_pred = ICMP_ULE;
    else return NONE;
    known := ic_known_bits(range_end, cmp1);
    if !kb_is_non_negative(known) return NONE;
    if inverted new_pred = cmp_inverse(new_pred);
    return icb_cmp(new_pred, input, range_end);
}

// foldAndOrOfICmpsWithPow2AndWithZero
ic_fold_and_or_of_icmps_with_pow2_and_with_zero :: (lhs_in: Value_Id, rhs_in: Value_Id, is_and: bool, q: Simplify_Query) -> Value_Id {
    lhs := lhs_in; rhs := rhs_in;
    pred := ifx is_and then cast(u8) ICMP_NE else ICMP_EQ;
    if inst_pred(lhs) != pred || inst_pred(rhs) != pred return NONE;
    if pm_zero(op(rhs, 1)) { t := lhs; lhs = rhs; rhs = t; }
    if !has_one_use(lhs) || !pm_zero(op(lhs, 1)) return NONE;
    opv := op(lhs, 0);
    if !has_one_use(rhs) return NONE;
    okc, _, _, pow2 := pm_c_icmp_with(rhs, opv);
    if !okc return NONE;
    if pm_one(pow2) || !is_known_to_be_a_power_of_two_ctx(pow2, true, q.cxt, q.dt, q.ac) return NONE;
    a := icb_and(opv, pow2);
    return icb_cmp(pred, a, opv);
}

// foldSignedTruncationCheck
ic_fold_signed_truncation_check :: (icmp0: Value_Id, icmp1: Value_Id, cxt: Value_Id) -> Value_Id {
    try_match :: (icmp: Value_Id) -> (bool, Value_Id, APInt) {
        no: APInt;
        ok, l, r := pm_specific_icmp(icmp, ICMP_ULT);
        if !ok return false, NONE, no;
        oka, x, c01 := pm_binop(l, .ADD);
        if !oka return false, NONE, no;
        ok01, i01 := pm_power2_ap(c01);
        ok1, i1 := pm_power2_ap(r);
        if !ok01 || !ok1 return false, NONE, no;
        if !(ap_ugt(i1, i01) && ap_eq(ap_shl(i01, 1), i1)) return false, NONE, no;
        return true, x, i01;
    }
    x1: Value_Id = NONE; highest_bit: APInt; other: Value_Id = NONE;
    ok, mx, hb := try_match(icmp1);
    if ok { x1 = mx; highest_bit = hb; other = icmp0; }
    else {
        ok, mx, hb = try_match(icmp0);
        if !ok return NONE;
        x1 = mx; highest_bit = hb; other = icmp1;
    }
    okd, res := decompose_bit_test_icmp(op(other, 0), op(other, 1), inst_pred(other), false, false, true);
    if !(okd && res.pred == ICMP_EQ) return NONE;
    x0 := res.x;
    unset_bits_mask := res.mask;
    x: Value_Id = NONE;
    if x1 == x0 x = x1;
    else {
        okt, tx := pmi_cast(x0, .TRUNC);
        if okt && tx == x1 {
            unset_bits_mask = ap_zext(unset_bits_mask, scalar_bits(x1));
            x = x1;
        } else return NONE;
    }
    sign_bits_mask := ap_not(ap_sub_u64(highest_bit, 1));
    if !ap_intersects(unset_bits_mask, sign_bits_mask) return NONE;
    if !ap_is_subset_of(unset_bits_mask, sign_bits_mask) {
        other_highest_bit := ap_add_u64(ap_not(unset_bits_mask), 1);
        if !ap_is_power_of_2(other_highest_bit) return NONE;
        highest_bit = ap_umin(highest_bit, other_highest_bit);
    }
    return icb_cmp(ICMP_ULT, x, const_int_ap(vtype(x), highest_bit), tprint("%.simplified", vname(cxt)));
}

// foldIsPowerOf2OrZero
ic_fold_is_power_of2_or_zero :: (cmp0: Value_Id, cmp1: Value_Id, is_and: bool) -> Value_Id {
    ok0, pred0, _, ct, one := pm_icmp(cmp0);
    if !ok0 return NONE;
    okp, x := pm_ctpop(ct);
    if !okp || !pm_specific_int(one, 1) return NONE;
    ok1, pred1, _, x1, z := pm_icmp(cmp1);
    if !ok1 || x1 != x || !pm_zero_int(z) return NONE;
    ctpop := op(cmp0, 0);
    if is_and && pred0 == ICMP_NE && pred1 == ICMP_NE {
        drop_poison_generating_annotations(ctpop);
        wl_add(ctpop);
        return icb_cmp(ICMP_UGT, ctpop, const_int_of(vtype(ctpop), 1));
    }
    if !is_and && pred0 == ICMP_EQ && pred1 == ICMP_EQ {
        drop_poison_generating_annotations(ctpop);
        wl_add(ctpop);
        return icb_cmp(ICMP_ULT, ctpop, const_int_of(vtype(ctpop), 2));
    }
    return NONE;
}

// foldIsPowerOf2
ic_fold_is_power_of2 :: (cmp0_in: Value_Id, cmp1_in: Value_Id, joined_by_and: bool) -> Value_Id {
    cmp0 := cmp0_in; cmp1 := cmp1_in;
    if joined_by_and && inst_pred(cmp1) == ICMP_NE { t := cmp0; cmp0 = cmp1; cmp1 = t; }
    else if !joined_by_and && inst_pred(cmp1) == ICMP_EQ { t := cmp0; cmp0 = cmp1; cmp1 = t; }
    if joined_by_and {
        ok, x, z := pm_specific_icmp(cmp0, ICMP_NE);
        if ok && pm_zero_int(z) {
            ok1, ct, two := pm_specific_icmp(cmp1, ICMP_ULT);
            okp, cx := pm_ctpop(ct);
            if ok1 && okp && cx == x && pm_specific_int(two, 2) {
                ctpop := op(cmp1, 0);
                drop_poison_generating_annotations(ctpop);
                wl_add(ctpop);
                return icb_cmp(ICMP_EQ, ctpop, const_int_of(vtype(ctpop), 1));
            }
        }
    }
    if !joined_by_and {
        ok, x, z := pm_specific_icmp(cmp0, ICMP_EQ);
        if ok && pm_zero_int(z) {
            ok1, ct, one := pm_specific_icmp(cmp1, ICMP_UGT);
            okp, cx := pm_ctpop(ct);
            if ok1 && okp && cx == x && pm_specific_int(one, 1) {
                ctpop := op(cmp1, 0);
                drop_poison_generating_annotations(ctpop);
                wl_add(ctpop);
                return icb_cmp(ICMP_NE, ctpop, const_int_of(vtype(ctpop), 1));
            }
        }
    }
    return NONE;
}

// foldNegativePower2AndShiftedMask
ic_fold_negative_power2_and_shifted_mask :: (a: Value_Id, b: Value_Id, d: Value_Id, e: Value_Id, pred_l: u8, pred_r: u8) -> Value_Id {
    if pred_l != ICMP_EQ || pred_r != ICMP_NE return NONE;
    if !pm_negated_power2(b) || !pm_shifted_mask(d) || !pm_shifted_mask(e) return NONE;
    is_reducible :: (b: Value_Id, d: Value_Id, e: Value_Id) -> bool {
        okb, bc := pm_apint_ap(b);
        okd, dc := pm_apint(d);
        oke, ec := pm_apint(e);
        return okb && okd && oke && ap_eq(dc, ec) && (vkind(b) == .C_POISON || ap_clo(bc) == ap_clz(dc));
    }
    bt := vtype(b);
    if is_vector_type(bt) {
        if type_kind(bt) != .VECTOR || !is_const(b) || !is_const(d) || !is_const(e) return NONE;
        n := type_count(bt);
        for k: 0..cast(s64) n - 1 {
            be := cf_elt(b, cast(u64) k);
            de := cf_elt(d, cast(u64) k);
            ee := cf_elt(e, cast(u64) k);
            if be == NONE || de == NONE || ee == NONE return NONE;
            if !is_reducible(be, de, ee) return NONE;
        }
    } else {
        if !is_reducible(b, d, e) return NONE;
    }
    return icb_cmp(ICMP_ULT, a, d);
}

// foldPowerOf2AndShiftedMask
ic_fold_power_of2_and_shifted_mask :: (cmp0: Value_Id, cmp1: Value_Id, joined_by_and: bool) -> Value_Id {
    if !joined_by_and return NONE;
    ok, mp := ic_get_masked_type_for_icmp_pair(cmp0, cmp1);
    if !ok return NONE;
    compare_b_mask :: BMASK_NOT_MIXED | BMASK_NOT_ALL_ONES;
    m0 := mp.left_type; m1 := mp.right_type;
    if (m0 & MASK_ALL_ZEROS) != 0 && m1 == compare_b_mask {
        v := ic_fold_negative_power2_and_shifted_mask(mp.a, mp.b, mp.d, mp.e, mp.pred_l, mp.pred_r);
        if v != NONE return v;
    } else if m0 == compare_b_mask && (m1 & MASK_ALL_ZEROS) != 0 {
        v := ic_fold_negative_power2_and_shifted_mask(mp.a, mp.d, mp.b, mp.c, mp.pred_r, mp.pred_l);
        if v != NONE return v;
    }
    return NONE;
}

// foldUnsignedUnderflowCheck
ic_fold_unsigned_underflow_check :: (zero_icmp: Value_Id, unsigned_icmp: Value_Id, is_and: bool, q: Simplify_Query) -> Value_Id {
    ok, eq_pred, _, zero_cmp_op, z := pm_icmp(zero_icmp);
    if !ok || !pm_zero(z) || !icmp_is_equality(eq_pred) return NONE;
    okc, unsigned_pred, _, a := pm_c_icmp_with(unsigned_icmp, zero_cmp_op);
    if !okc return NONE;
    oka, b := pm_c_binop_with(zero_cmp_op, .ADD, a);
    if !oka || !(has_one_use(zero_icmp) || has_one_use(unsigned_icmp)) return NONE;
    aa := a; bb := b;
    get_known_non_zero_and_other :: (non_zero: *Value_Id, other: *Value_Id, q: Simplify_Query) -> bool {
        if !is_known_non_zero(non_zero.*, q) { t := non_zero.*; non_zero.* = other.*; other.* = t; }
        return is_known_non_zero(non_zero.*, q);
    }
    if unsigned_pred == ICMP_ULT && eq_pred == ICMP_NE && is_and && get_known_non_zero_and_other(*bb, *aa, q)
        return icb_cmp(ICMP_ULT, icb_neg(bb), aa);
    if unsigned_pred == ICMP_UGE && eq_pred == ICMP_EQ && !is_and && get_known_non_zero_and_other(*bb, *aa, q)
        return icb_cmp(ICMP_UGE, icb_neg(bb), aa);
    return NONE;
}

Int_Part :: struct { from: Value_Id; start_bit: u32; num_bits: u32; }

// matchIntPart
ic_match_int_part :: (v: Value_Id) -> (bool, Int_Part) {
    p: Int_Part;
    okt, x := pmi_cast(v, .TRUNC);
    if !okt || !has_one_use(v) return false, p;
    num_orig := scalar_bits(x);
    num_extracted := scalar_bits(v);
    ok, y, sh := pm_binop(x, .LSHR);
    okc, shift := pm_apint(sh);
    if ok && has_one_use(x) && okc && ap_ule_u64(shift, cast(u64) (num_orig - num_extracted)) {
        p.from = y; p.start_bit = cast(u32) ap_zext_value(shift); p.num_bits = num_extracted;
        return true, p;
    }
    p.from = x; p.start_bit = 0; p.num_bits = num_extracted;
    return true, p;
}

// extractIntPart
ic_extract_int_part :: (p: Int_Part) -> Value_Id {
    v := p.from;
    if p.start_bit v = icb_lshr(v, const_int_of(vtype(v), cast(u64) p.start_bit));
    trunc_ty := type_with_new_bit_width(vtype(v), p.num_bits);
    if trunc_ty != vtype(v) v = icb_trunc(v, trunc_ty);
    return v;
}

// foldEqOfParts
ic_fold_eq_of_parts :: (cmp0: Value_Id, cmp1: Value_Id, is_and: bool) -> Value_Id {
    if !has_one_use(cmp0) || !has_one_use(cmp1) return NONE;
    pred := ifx is_and then cast(u8) ICMP_EQ else ICMP_NE;
    get_match_part :: (cmpv: Value_Id, op_no: u32, pred: u8) -> (bool, Int_Part) {
        p: Int_Part;
        t := cmpv;
        if pred == ICMP_EQ {
            okn, nx := pm_not(cmpv);
            t = ifx okn then nx else NONE;
        }
        if t != NONE {
            okt, xr := pmi_cast(t, .TRUNC);
            if okt {
                okx, x, y := pm_binop(xr, .XOR);
                if okx {
                    p.from = ifx op_no == 0 then x else y; p.start_bit = 0; p.num_bits = 1;
                    return true, p;
                }
            }
        }
        if !ic_is_icmp(cmpv) return false, p;
        if pred == inst_pred(cmpv) {
            ok, r := ic_match_int_part(op(cmpv, op_no));
            return ok, r;
        }
        c: APInt;
        if pred == ICMP_EQ && inst_pred(cmpv) == ICMP_ULT {
            okc, cc := pm_power2_ap(op(cmpv, 1));
            okx, _, _ := pm_binop(op(cmpv, 0), .XOR);
            if !okc || !okx return false, p;
            c = cc;
        } else if pred == ICMP_NE && inst_pred(cmpv) == ICMP_UGT {
            okc, cc := pm_low_bit_mask_ap(op(cmpv, 1));
            okx, _, _ := pm_binop(op(cmpv, 0), .XOR);
            if !okc || !okx return false, p;
            c = cc;
        } else return false, p;
        from := ifx pred == ICMP_NE then ap_popcount(c) else ap_ctz(c);
        i := op(cmpv, 0);
        p.from = op(i, op_no); p.start_bit = from; p.num_bits = c.bits - from;
        return true, p;
    }
    okl0, l0 := get_match_part(cmp0, 0, pred);
    okr0, r0 := get_match_part(cmp0, 1, pred);
    okl1, l1 := get_match_part(cmp1, 0, pred);
    okr1, r1 := get_match_part(cmp1, 1, pred);
    if !okl0 || !okr0 || !okl1 || !okr1 return NONE;
    if l0.from != l1.from || r0.from != r1.from {
        if l0.from != r1.from || r0.from != l1.from return NONE;
        t := l1; l1 = r1; r1 = t;
    }
    if l0.start_bit + l0.num_bits != l1.start_bit || r0.start_bit + r0.num_bits != r1.start_bit {
        if l1.start_bit + l1.num_bits != l0.start_bit || r1.start_bit + r1.num_bits != r0.start_bit return NONE;
        t := l0; l0 = l1; l1 = t;
        t = r0; r0 = r1; r1 = t;
    }
    l := Int_Part.{l0.from, l0.start_bit, l0.num_bits + l1.num_bits};
    r := Int_Part.{r0.from, r0.start_bit, r0.num_bits + r1.num_bits};
    lv := ic_extract_int_part(l);
    rv := ic_extract_int_part(r);
    return icb_cmp(pred, lv, rv);
}

// foldAndOrOfICmpsWithConstEq
ic_fold_and_or_of_icmps_with_const_eq :: (cmp0: Value_Id, cmp1: Value_Id, is_and: bool, is_logical: bool, q: Simplify_Query, i: Value_Id) -> Value_Id {
    ok, pred0, _, x, c := pm_icmp(cmp0);
    if !ok || !is_const(c) || !is_guaranteed_not_to_be_undef_or_poison(c) || is_const(x) return NONE;
    if (is_and && pred0 != ICMP_EQ) || (!is_and && pred0 != ICMP_NE) return NONE;
    // m_c_ICmp(Pred1, m_Value(Y), m_Specific(X)): X canonicalized as operand 1
    if !ic_is_icmp(cmp1) return NONE;
    y: Value_Id = NONE; pred1: u8;
    ss1 := ic_has_same_sign(cmp1);
    if op(cmp1, 1) == x { y = op(cmp1, 0); pred1 = inst_pred(cmp1); }
    else if op(cmp1, 0) == x { y = op(cmp1, 1); pred1 = icmp_swapped(inst_pred(cmp1)); }
    else return NONE;
    sub := simplify_icmp_inst(pred1, ss1, y, c, q);
    if sub == NONE {
        if !has_one_use(cmp1) return NONE;
        sub = icb_cmp(pred1, y, c);
    }
    if is_logical {
        md_from := i;   // ProfcheckDisableMetadataFixes is off
        if is_and return icb_logical_and(cmp0, sub, "", md_from);
        return icb_logical_or(cmp0, sub, "", md_from);
    }
    return icb_binop(ifx is_and then Opcode.AND else .OR, cmp0, sub);
}

// foldAndOrOfICmpsUsingRanges
ic_fold_and_or_of_icmps_using_ranges :: (icmp1: Value_Id, icmp2: Value_Id, is_and: bool) -> Value_Id {
    match_exact_range_check :: (icmp: Value_Id) -> (bool, Value_Id, Const_Range) {
        cr0: Const_Range;
        okc, c := pm_apint(op(icmp, 1));
        if !okc return false, NONE, cr0;
        lhs := op(icmp, 0);
        pred := inst_pred(icmp);
        if icmp_is_equality(pred) && has_one_use(lhs) {
            oka, x, mv := pm_binop(lhs, .AND);
            if oka {
                okm, mask := pm_apint_pred(mv, ap_is_negated_power_of_2);
                if okm && ap_ctz(c) >= ap_ctz(mask) {
                    cr := cr_new(c, ap_sub(c, mask));
                    if pred == ICMP_NE cr = cr_inverse(cr);
                    return true, x, cr;
                }
            }
        }
        cr := cr_exact_icmp_region(pred, c);
        oka, x, c1v := pm_add_like(lhs);
        if oka {
            okc1, c1 := pm_apint(c1v);
            if okc1 return true, x, cr_subtract(cr, c1);
        }
        return true, lhs, cr;
    }
    ok1, v1, cr1 := match_exact_range_check(icmp1);
    if !ok1 return NONE;
    ok2, v2, cr2 := match_exact_range_check(icmp2);
    if !ok2 return NONE;
    if v1 != v2 return NONE;
    if is_and { cr1 = cr_inverse(cr1); cr2 = cr_inverse(cr2); }
    ty := vtype(v1);
    new_v := v1;
    okcr, cr := cr_exact_union(cr1, cr2);
    if !okcr {
        if !(has_one_use(icmp1) && has_one_use(icmp2)) || cr_is_wrapped_set(cr1) || cr_is_wrapped_set(cr2) return NONE;
        lower_diff := ap_xor(cr1.lo, cr2.lo);
        upper_diff := ap_xor(ap_sub_u64(cr1.hi, 1), ap_sub_u64(cr2.hi, 1));
        cr1_size := ap_sub(cr1.hi, cr1.lo);
        if !ap_is_power_of_2(lower_diff) || ap_ne(lower_diff, upper_diff) || ap_ne(cr1_size, ap_sub(cr2.hi, cr2.lo)) return NONE;
        cr = ifx ap_ult(cr1.lo, cr2.lo) then cr1 else cr2;
        new_v = icb_and(new_v, const_int_ap(ty, ap_not(lower_diff)));
    }
    if is_and cr = cr_inverse(cr);
    new_pred, new_c, offset := cr_equivalent_icmp(cr);
    if !ap_is_zero(offset) new_v = icb_add(new_v, const_int_ap(ty, offset));
    return icb_cmp(new_pred, new_v, const_int_ap(ty, new_c));
}

// matchIsNotNaN / matchUnorderedInfCompare / matchIsFiniteTest
ic_match_is_finite_test :: (lhs: Value_Id, rhs: Value_Id) -> Value_Id {
    lhs1 := op(lhs, 1);
    rhs0 := op(rhs, 0); rhs1 := op(rhs, 1);
    pred_l := inst_pred(lhs); pred_r := inst_pred(rhs);
    if !(pred_l == FCMP_ORD && pm_any_zero_fp(lhs1)) || !(cmp_is_unordered(pred_r) && pm_inf(rhs1)) return NONE;
    return icb_fcmp_fmf(fcmp_ordered(pred_r), rhs0, rhs1, ic_fmf_intersect(lhs, rhs));
}

// InstCombiner::stripSignOnlyFPOps
ic_strip_sign_only_fp_ops :: (v_in: Value_Id) -> Value_Id {
    v := v_in;
    okn, x := pm_fneg(v); if okn v = x;
    oka, y := pm_intrinsic1(v, IID_FABS); if oka v = y;
    okc, z, _ := pm_intrinsic2(v, IID_COPYSIGN); if okc v = z;
    return v;
}

// fcmpToClassTest(Pred, F, LHS, RHS Value)
ic_fcmp_to_class_test_v :: (pred: u8, f: Value_Id, lhs: Value_Id, rhs: Value_Id) -> (Value_Id, u32) {
    ok, c := pm_apfloat(rhs, true);
    if !ok return NONE, FC_ALL_FLAGS;
    v, m := fcmp_to_class_test(pred, f, lhs, c);
    return v, m;
}

// foldLogicOfFCmps
ic_fold_logic_of_fcmps :: (lhs: Value_Id, rhs: Value_Id, is_and: bool, is_logical_select := false) -> Value_Id {
    lhs0 := op(lhs, 0); lhs1 := op(lhs, 1);
    rhs0 := op(rhs, 0); rhs1 := op(rhs, 1);
    pred_l := inst_pred(lhs); pred_r := inst_pred(rhs);
    if lhs0 == rhs1 && rhs0 == lhs1 {
        pred_r = cmp_swapped(pred_r);
        t := rhs0; rhs0 = rhs1; rhs1 = t;
    }
    if lhs0 == rhs0 && lhs1 == rhs1 {
        code_l := cast(u32) pred_l; code_r := cast(u32) pred_r;
        new_pred := ifx is_and then code_l & code_r else code_l | code_r;
        return ic_get_fcmp_value(new_pred, lhs0, lhs1, ic_fmf_intersect(lhs, rhs));
    }
    if (pred_l == FCMP_ORD && pred_r == FCMP_ORD && is_and) || (pred_l == FCMP_UNO && pred_r == FCMP_UNO && !is_and) {
        if vtype(lhs0) != vtype(rhs0) return NONE;
        if pm_pos_zero_fp(lhs1) && pm_pos_zero_fp(rhs1) {
            y := rhs0;
            fmf := get_fmf(lhs) & get_fmf(rhs);
            if is_logical_select {
                y = icb_freeze(y, tprint("%.fr", vname(y)));
                fmf &= ~cast(u32) (FMF_NNAN | FMF_NINF);
            }
            return icb_fcmp_fmf(pred_l, lhs0, y, fmf);
        }
    }
    if !is_logical_select && is_and && ic_strip_sign_only_fp_ops(lhs0) == ic_strip_sign_only_fp_ops(rhs0) {
        l := ic_match_is_finite_test(lhs, rhs); if l != NONE return l;
        r := ic_match_is_finite_test(rhs, lhs); if r != NONE return r;
    }
    if has_one_use(lhs) && has_one_use(rhs) {
        cv_r, cm_r := ic_fcmp_to_class_test_v(pred_r, inst_fn(rhs), rhs0, rhs1);
        if cv_r != NONE {
            cv_l, cm_l := ic_fcmp_to_class_test_v(pred_l, inst_fn(lhs), lhs0, lhs1);
            if cv_l == cv_r {
                combined := ifx is_and then (cm_l & cm_r) else (cm_l | cm_r);
                return icb_intrinsic(IID_IS_FPCLASS, .[vtype(cv_l)], .[cv_l, const_int_of(ir.t_i32, cast(u64) combined)]);
            }
        }
    }
    if lhs0 == rhs0 && has_one_use(lhs) && has_one_use(rhs) && cmp_swapped(pred_l) == pred_r {
        okl, lc := pm_apfloat(lhs1, true);
        okr, rc := pm_apfloat(rhs1, true);
        if okl && okr && ic_apf_bitwise_equal(lc, ic_apf_neg(rc)) {
            is_lt_or_le :: (p: u8) -> bool { return p == FCMP_OLT || p == FCMP_OLE || p == FCMP_ULT || p == FCMP_ULE; }
            if is_lt_or_le(ifx is_and then pred_r else pred_l) {
                t := lc; lc = rc; rc = t;
                tp := pred_l; pred_l = pred_r; pred_r = tp;
            }
            if is_lt_or_le(ifx is_and then pred_l else pred_r) {
                new_flag := get_fmf(lhs);
                if !is_logical_select new_flag |= get_fmf(rhs);
                fabs := icb_fabs_fmf(lhs0, new_flag);
                return icb_fcmp_fmf(pred_l, fabs, ic_const_fp(vtype(lhs0), lc), new_flag);
            }
        }
    }
    return NONE;
}

// matchIsFPClassLikeFCmp
ic_match_is_fp_class_like_fcmp :: (v: Value_Id) -> (bool, Value_Id, u64) {
    if !ic_is_fcmp(v) || !has_one_use(v) return false, NONE, 0;
    cv, cm := ic_fcmp_to_class_test_v(inst_pred(v), inst_fn(v), op(v, 0), op(v, 1));
    return cv != NONE, cv, cast(u64) cm;
}

// foldLogicOfIsFPClass
ic_fold_logic_of_is_fp_class :: (bo: Value_Id, op0: Value_Id, op1: Value_Id) -> Value_Id {
    match_class :: (v: Value_Id) -> (bool, Value_Id, u64) {
        if !has_one_use(v) return false, NONE, 0;
        ok, cv, mv := pm_intrinsic2(v, IID_IS_FPCLASS);
        if !ok return false, NONE, 0;
        okm, m := pm_constant_int_u64(mv);
        if !okm return false, NONE, 0;
        return true, cv, m;
    }
    is_lhs_class, cv0, cm0 := match_class(op0);
    is_rhs_class, cv1, cm1 := match_class(op1);
    ok0 := is_lhs_class;
    if !ok0 { ok0, cv0, cm0 = ic_match_is_fp_class_like_fcmp(op0); }
    if !ok0 return NONE;
    ok1 := is_rhs_class;
    if !ok1 { ok1, cv1, cm1 = ic_match_is_fp_class_like_fcmp(op1); }
    if !ok1 || cv0 != cv1 return NONE;
    new_mask: u64;
    if inst_op(bo) == {
        case .AND; new_mask = cm0 & cm1;
        case .OR; new_mask = cm0 | cm1;
        case .XOR; new_mask = cm0 ^ cm1;
        case; fatal("internal: not a binary logic operator");
    }
    new_mask &= 0xFFFF_FFFF;
    if is_lhs_class {
        set_op(op0, 1, const_int_of(vtype(op(op0, 1)), new_mask));
        return ic_replace_inst_uses_with(bo, op0);
    }
    if is_rhs_class {
        set_op(op1, 1, const_int_of(vtype(op(op1, 1)), new_mask));
        return ic_replace_inst_uses_with(bo, op1);
    }
    nc := icb_intrinsic(IID_IS_FPCLASS, .[vtype(cv0)], .[cv0, const_int_of(ir.t_i32, new_mask)]);
    return ic_replace_inst_uses_with(bo, nc);
}

// canonicalizeConditionalNegationViaMathToSelect
ic_canonicalize_conditional_negation_via_math_to_select :: (i: Value_Id) -> Value_Id {
    if !ic_some_operand_has_one_use(i) return NONE;
    oks, cond := pmi_cast(op(i, 1), .SEXT);
    if !oks || !is_int_or_int_vector_n(vtype(cond), 1) return NONE;
    o0 := op(i, 0);
    if !ic_is_binop(o0, .ADD) return NONE;
    x: Value_Id = NONE;
    for side: 0..1 {
        okc, cc := pmi_cast(op(o0, cast(u32) side), .SEXT);
        if okc && cc == cond { x = op(o0, cast(u32) (1 - side)); break; }
    }
    if x == NONE return NONE;
    return ic_create_select_unknown_profile(cond, icb_neg(x, tprint("%.neg", vname(x))), x);
}

// reassociateFCmps
ic_reassociate_fcmps :: (bo: Value_Id) -> Value_Id {
    opc := inst_op(bo);
    op0 := op(bo, 0); op1 := op(bo, 1);
    {
        ok, _, _, z := pm_fcmp(op1);
        if ok && pm_any_zero_fp(z) { t := op0; op0 = op1; op1 = t; }
    }
    nan_pred := ifx opc == .AND then cast(u8) FCMP_ORD else FCMP_UNO;
    match_nan :: (v: Value_Id, nan_pred: u8) -> (bool, Value_Id) {
        ok, p, x, z := pm_fcmp(v);
        if ok && p == nan_pred && pm_any_zero_fp(z) return true, x;
        return false, NONE;
    }
    okx, x := match_nan(op0, nan_pred);
    if !okx return NONE;
    okb, bo10, bo11 := pm_binop(op1, opc);
    if !okb return NONE;
    oky, y := match_nan(bo10, nan_pred);
    if !oky || vtype(x) != vtype(y) { t := bo10; bo10 = bo11; bo11 = t; }
    oky, y = match_nan(bo10, nan_pred);
    if !oky || vtype(x) != vtype(y) return NONE;
    new_fcmp := icb_fcmp_fmf(nan_pred, x, y, ic_fmf_intersect(op0, bo10));
    return create_binop(opc, new_fcmp, bo11);
}

// matchDeMorgansLaws
ic_match_de_morgans_laws :: (i: Value_Id) -> Value_Id {
    opc := inst_op(i);
    flipped := ifx opc == .AND then Opcode.OR else .AND;
    op0 := op(i, 0); op1 := op(i, 1);
    {
        oka, a := pm_not(op0);
        okb, b := pm_not(op1);
        if oka && has_one_use(op0) && okb && has_one_use(op1) {
            fa, _ := ic_is_free_to_invert(a, has_one_use(a));
            fb, _ := ic_is_free_to_invert(b, has_one_use(b));
            if !fa && !fb {
                and_or := icb_binop(flipped, a, b, tprint("%.demorgan", vname(i)));
                return create_not(and_or);
            }
        }
    }
    if ic_is_binop(op0, opc) && has_one_use(op0) {
        okc, c := pm_not(op1);
        if okc {
            for side: 0..1 {
                okn, b := pm_not(op(op0, cast(u32) (1 - side)));
                if okn {
                    a := op(op0, cast(u32) side);
                    flipped_bo := icb_binop(flipped, b, c);
                    return create_binop(opc, a, icb_not(flipped_bo));
                }
            }
        }
    }
    return NONE;
}

// isa<CastInst>
ic_is_cast_inst :: (v: Value_Id) -> bool { return is_inst(v) && is_cast_op(inst_op(v)); }

// shouldOptimizeCast
ic_should_optimize_cast :: (ci: Value_Id) -> bool {
    src := op(ci, 0);
    if vtype(src) == vtype(ci) || is_const(src) return false;
    if ic_is_cast_inst(src) && ic_is_eliminable_cast_pair(src, ci) != .NONE_OP return false;
    return true;
}

// getLosslessUnsignedTrunc(C, Ty, DL, &Flags): (constant, Flags.NNeg)
ic_lossless_unsigned_trunc_flags :: (c: Value_Id, t: Type_Id) -> (Value_Id, bool) {
    inv := ce_cast(.TRUNC, c, t);
    back := cfo_cast_operand(.ZEXT, inv, vtype(c));
    if back == NONE || back != c return NONE, false;
    sext_inv := cfo_cast_operand(.SEXT, inv, vtype(c));
    return inv, back == sext_inv;
}

// foldLogicCastConstant
ic_fold_logic_cast_constant :: (logic: Value_Id, cst: Value_Id) -> Value_Id {
    c := op(logic, 1);
    if !is_const(c) return NONE;
    logic_opc := inst_op(logic);
    dest_ty := vtype(logic);
    src_ty := vtype(op(cst, 0));
    okz, x := pmi_cast(cst, .ZEXT);
    if okz && has_one_use(cst) {
        trunc_c, nneg := ic_lossless_unsigned_trunc_flags(c, src_ty);
        if trunc_c != NONE {
            new_op := icb_binop(logic_opc, x, trunc_c);
            z := create_cast(.ZEXT, new_op, dest_ty);
            set_flag(z, F_EXACT, nneg);
            and_ir_flags(z, cst);
            return z;
        }
    }
    oks, sx := pm_sext_like(cst);
    if oks && is_inst(cst) && has_one_use(cst) {
        trunc_c := get_lossless_signed_trunc(c, src_ty);
        if trunc_c != NONE {
            new_op := icb_binop(logic_opc, sx, trunc_c);
            return create_cast(.SEXT, new_op, dest_ty);
        }
    }
    return NONE;
}

// foldCastedBitwiseLogic
ic_fold_casted_bitwise_logic :: (i: Value_Id) -> Value_Id {
    logic_opc := inst_op(i);
    op0 := op(i, 0); op1 := op(i, 1);
    fold_bitwise_icmp_zero_with_icmp :: (i: Value_Id, op0: Value_Id, op1: Value_Id) -> Value_Id {
        ok, a, sa := pm_binop(op0, .LSHR);
        if !ok || !has_one_use(op0) || !pm_specific_int(sa, cast(u64) scalar_bits(op0) - 1) return NONE;
        okz, ic0 := pmi_cast(op1, .ZEXT);
        if !okz || !has_one_use(op1) || !ic_is_icmp(ic0) return NONE;
        icmp_l := icb_cmp(ICMP_SLT, a, const_null_value(vtype(a)));
        icmp_r := op(op1, 0);
        bw := icb_binop(inst_op(i), icmp_l, icmp_r);
        return create_cast(.ZEXT, bw, vtype(op0));
    }
    r := fold_bitwise_icmp_zero_with_icmp(i, op0, op1); if r != NONE return r;
    r = fold_bitwise_icmp_zero_with_icmp(i, op1, op0); if r != NONE return r;

    if !ic_is_cast_inst(op0) return NONE;
    cast0 := op0;
    dest_ty := vtype(i);
    src_ty := vtype(op(cast0, 0));
    if !is_int_or_int_vector(src_ty) return NONE;
    r = ic_fold_logic_cast_constant(i, cast0); if r != NONE return r;
    if !ic_is_cast_inst(op1) return NONE;
    cast1 := op1;
    cast_opc := inst_op(cast0);
    if cast_opc != inst_op(cast1) return NONE;
    if !has_one_use(cast0) && !has_one_use(cast1) return NONE;
    if cast_opc == .ZEXT || cast_opc == .SEXT {
        x := op(cast0, 0); y := op(cast1, 0);
        xn := scalar_bits(x); yn := scalar_bits(y);
        if xn != yn {
            if !has_one_use(cast0) || !has_one_use(cast1) return NONE;
            if xn < yn x = icb_cast(cast_opc, x, vtype(y));
            else if yn < xn y = icb_cast(cast_opc, y, vtype(x));
        }
        narrow := icb_binop(logic_opc, x, y, vname(i));
        if inst_op(i) == .OR && is_inst(narrow) && inst_op(narrow) == .OR ic_set_disjoint(narrow, ic_is_disjoint(i));
        return create_cast(cast_opc, narrow, dest_ty);
    }
    if src_ty != vtype(op(cast1, 0)) return NONE;
    c0s := op(cast0, 0); c1s := op(cast1, 0);
    if ic_should_optimize_cast(cast0) && ic_should_optimize_cast(cast1) {
        new_op := icb_binop(logic_opc, c0s, c1s, vname(i));
        return create_cast(cast_opc, new_op, dest_ty);
    }
    return NONE;
}

// foldAndToXor
ic_fold_and_to_xor :: (i: Value_Id) -> Value_Id {
    op0 := op(i, 0); op1 := op(i, 1);
    {
        oko, a, b := pm_binop(op0, .OR);
        okn, n := pm_not(op1);
        if oko && okn && ic_is_binop(n, .AND) && ((op(n, 0) == a && op(n, 1) == b) || (op(n, 0) == b && op(n, 1) == a))
            return create_binop(.XOR, a, b);
    }
    if has_one_use(op0) || has_one_use(op1) {
        // m_BinOp(m_c_Or(m_Value(A), m_Not(m_Value(B))), m_c_Or(m_Not(m_Deferred(A)), m_Deferred(B)))
        if ic_is_binop(op0, .OR) && ic_is_binop(op1, .OR) {
            for side: 0..1 {
                a := op(op0, cast(u32) side);
                okn, b := pm_not(op(op0, cast(u32) (1 - side)));
                if !okn continue;
                matched := false;
                for s2: 0..1 {
                    okn2, na := pm_not(op(op1, cast(u32) s2));
                    if okn2 && na == a && op(op1, cast(u32) (1 - s2)) == b { matched = true; break; }
                }
                if matched return create_not(icb_xor(a, b));
                break;   // m_c_Or bound A/B on the first matching order
            }
        }
    }
    return NONE;
}

// foldOrToXor
ic_fold_or_to_xor :: (i: Value_Id) -> Value_Id {
    op0 := op(i, 0); op1 := op(i, 1);
    is_not_or_of :: (v: Value_Id, a: Value_Id, b: Value_Id) -> bool {
        okn, n := pm_not(v);
        return okn && ic_is_binop(n, .OR) && ((op(n, 0) == a && op(n, 1) == b) || (op(n, 0) == b && op(n, 1) == a));
    }
    if has_one_use(op0) || has_one_use(op1) {
        ok, a, b := pm_binop(op0, .AND);
        if ok && is_not_or_of(op1, a, b) return create_not(icb_xor(a, b));
    }
    if has_one_use(op0) || has_one_use(op1) {
        ok, a, b := pm_binop(op0, .XOR);
        if ok && is_not_or_of(op1, a, b) return create_not(icb_and(a, b));
    }
    if ic_is_binop(op0, .AND) && ic_is_binop(op1, .AND) {
        for side: 0..1 {
            a := op(op0, cast(u32) side);
            okn, b := pm_not(op(op0, cast(u32) (1 - side)));
            if !okn continue;
            for s2: 0..1 {
                okn2, na := pm_not(op(op1, cast(u32) s2));
                if okn2 && na == a && op(op1, cast(u32) (1 - s2)) == b return create_binop(.XOR, a, b);
            }
            break;   // m_c_And bound A/B on the first matching order; m_Specific then fails or succeeds
        }
    }
    return NONE;
}

// canNarrowShiftAmt
ic_can_narrow_shift_amt :: (c: Value_Id, bw: u32) -> bool { return pm_int_ult(c, cast(u64) bw); }

// narrowMaskedBinOp
ic_narrow_masked_bin_op :: (and: Value_Id) -> Value_Id {
    op0 := op(and, 0); op1 := op(and, 1);
    if !has_one_use(op0) || !is_binary_operator(op0) return NONE;
    c: Value_Id = NONE;
    o := inst_op(op0);
    if (o == .ADD || o == .MUL || o == .LSHR || o == .SHL) && op(op0, 0) == op1 && is_const(op(op0, 1)) c = op(op0, 1);
    else if o == .SUB && is_const(op(op0, 0)) && op(op0, 1) == op1 c = op(op0, 0);
    if c == NONE return NONE;
    okz, x := pmi_cast(op1, .ZEXT);
    if !okz || has_n_uses_or_more(op1, 3) return NONE;
    ty := vtype(and);
    if !is_vector_type(ty) && !ic_should_change_type(ty, vtype(x)) return NONE;
    if o == .LSHR || o == .SHL {
        if !ic_can_narrow_shift_amt(c, scalar_bits(x)) return NONE;
    }
    new_c := ce_cast(.TRUNC, c, vtype(x));
    new_bo := ifx o == .SUB then icb_binop(o, new_c, x) else icb_binop(o, x, new_c);
    return create_cast(.ZEXT, icb_and(new_bo, x), ty);
}

// ---------------------------------------------------------------- foldComplexAndOrPatterns

// m_c_BinOp(Opc, m_Specific(X), m_Specific(Y))
ic_is_c_binop_of :: (v: Value_Id, opc: Opcode, x: Value_Id, y: Value_Id) -> bool {
    if !ic_is_binop(v, opc) return false;
    return (op(v, 0) == x && op(v, 1) == y) || (op(v, 0) == y && op(v, 1) == x);
}
// m_c_BinOp(Opc, m_c_BinOp(Opc, m_Specific(X), m_Specific(Y)), m_Specific(Z))
ic_is_c_binop_nested :: (v: Value_Id, opc: Opcode, x: Value_Id, y: Value_Id, z: Value_Id) -> bool {
    if !ic_is_binop(v, opc) return false;
    if ic_is_c_binop_of(op(v, 0), opc, x, y) && op(v, 1) == z return true;
    if ic_is_c_binop_of(op(v, 1), opc, x, y) && op(v, 0) == z return true;
    return false;
}

ic_fold_complex_and_or_patterns :: (i: Value_Id) -> Value_Id {
    opc := inst_op(i);
    flipped := ifx opc == .AND then Opcode.OR else .AND;
    op0 := op(i, 0); op1 := op(i, 1);

    // matchNotOrAnd(Op, m_Value(A), m_Value(B), m_Value(C), X)
    match_capture :: (v: Value_Id, opc: Opcode, flipped: Opcode) -> (bool, Value_Id, Value_Id, Value_Id, Value_Id) {
        if !ic_is_binop(v, flipped) return false, NONE, NONE, NONE, NONE;
        for side: 0..1 {
            x := op(v, cast(u32) side);
            okn, n := pm_not(x);
            if okn && ic_is_binop(n, opc) return true, op(n, 0), op(n, 1), op(v, cast(u32) (1 - side)), x;
        }
        return false, NONE, NONE, NONE, NONE;
    }
    // matchNotOrAnd(Op, m_Specific(A), m_Specific(B), m_Specific(C), Dummy, CountUses)
    match_specific :: (v: Value_Id, opc: Opcode, flipped: Opcode, a: Value_Id, b: Value_Id, c: Value_Id, count_uses: bool) -> bool {
        if count_uses && !has_one_use(v) return false;
        if !ic_is_binop(v, flipped) return false;
        for side: 0..1 {
            x := op(v, cast(u32) side);
            okn, n := pm_not(x);
            if okn && ic_is_c_binop_of(n, opc, a, b) && op(v, cast(u32) (1 - side)) == c return !count_uses || has_one_use(x);
        }
        return false;
    }
    // m_OneUse(m_Not(m_OneUse(m_c_BinOp(Opc, m_Specific(X), m_Specific(Y)))))
    is_one_use_not_of :: (v: Value_Id, opc: Opcode, x: Value_Id, y: Value_Id) -> bool {
        if !has_one_use(v) return false;
        okn, n := pm_not(v);
        return okn && has_one_use(n) && ic_is_c_binop_of(n, opc, x, y);
    }

    ok, a, b, c, x := match_capture(op0, opc, flipped);
    if ok {
        if match_specific(op1, opc, flipped, a, c, b, true) {
            xr := icb_xor(b, c);
            if opc == .OR return create_binop(.AND, xr, icb_not(a));
            return create_not(icb_and(xr, a));
        }
        if match_specific(op1, opc, flipped, b, c, a, true) {
            xr := icb_xor(a, c);
            if opc == .OR return create_binop(.AND, xr, icb_not(b));
            return create_not(icb_and(xr, b));
        }
        if is_one_use_not_of(op1, opc, a, c)
            return create_not(icb_binop(opc, icb_binop(flipped, b, c), a));
        if is_one_use_not_of(op1, opc, b, c)
            return create_not(icb_binop(opc, icb_binop(flipped, a, c), b));
        if opc == .OR && has_one_use(op0) && has_one_use(op1) {
            okn, y := pm_not(op1);
            if okn && ic_is_binop(y, opc) {
                matched := false;
                for side: 0..1 {
                    if op(y, cast(u32) side) == c && ic_is_c_binop_of(op(y, cast(u32) (1 - side)), .XOR, a, b) { matched = true; break; }
                }
                if matched {
                    orv := op(x, 0);
                    return create_not(icb_and(orv, y));
                }
            }
        }
    }

    // (~A & B & C) | ... --> ...
    {
        a2, b2, c2, x2: Value_Id = NONE;
        matched := false;
        if has_one_use(op0) && ic_is_binop(op0, flipped) {
            // m_c_BinOp(Flipped, m_BinOp(Flipped, m_Value(B), m_Value(C)), m_Value(X, m_Not(m_Value(A))))
            for side: 0..1 {
                inner := op(op0, cast(u32) side);
                nx := op(op0, cast(u32) (1 - side));
                okn, na := pm_not(nx);
                if ic_is_binop(inner, flipped) && okn {
                    b2 = op(inner, 0); c2 = op(inner, 1); x2 = nx; a2 = na; matched = true; break;
                }
            }
            if !matched {
                // m_c_BinOp(Flipped, m_c_BinOp(Flipped, m_Value(C), m_Value(X, m_Not(m_Value(A)))), m_Value(B))
                for side: 0..1 {
                    inner := op(op0, cast(u32) side);
                    if !ic_is_binop(inner, flipped) continue;
                    found := false;
                    for s2: 0..1 {
                        nx := op(inner, cast(u32) (1 - s2));
                        okn, na := pm_not(nx);
                        if okn { c2 = op(inner, cast(u32) s2); x2 = nx; a2 = na; found = true; break; }
                    }
                    if found { b2 = op(op0, cast(u32) (1 - side)); matched = true; break; }
                }
            }
        }
        if matched {
            a = a2; b = b2; c = c2; x = x2;
            okn, n := pm_not(op1);
            if has_one_use(op1) && okn &&
               (ic_is_c_binop_nested(n, opc, a, b, c) || ic_is_c_binop_nested(n, opc, b, c, a) || ic_is_c_binop_nested(n, opc, a, c, b)) {
                xr := icb_xor(b, c);
                if opc == .OR return create_not(icb_or(xr, a));
                return create_binop(.OR, xr, x);
            }
            if is_one_use_not_of(op1, opc, a, b)
                return create_binop(flipped, icb_binop(opc, c, icb_not(b)), x);
            if is_one_use_not_of(op1, opc, a, c)
                return create_binop(flipped, icb_binop(opc, b, icb_not(c)), x);
        }
    }
    return NONE;
}

// reassociateForUses
ic_reassociate_for_uses :: (bo: Value_Id) -> Value_Id {
    opc := inst_op(bo);
    for side: 0..1 {
        inner := op(bo, cast(u32) side);
        z := op(bo, cast(u32) (1 - side));
        if !(ic_is_binop(inner, opc) && has_one_use(inner) && has_one_use(z)) continue;
        x := op(inner, 0); y := op(inner, 1);
        if !is_const(x) && !is_const(y) && !is_const(z) {
            if !has_one_use(x) {
                yz := icb_binop(opc, y, z);
                return create_binop(opc, yz, x);
            }
            if !has_one_use(y) {
                xz := icb_binop(opc, x, z);
                return create_binop(opc, xz, y);
            }
        }
        break;
    }
    return NONE;
}

// canonicalizeLogicFirst
ic_canonicalize_logic_first :: (i: Value_Id) -> Value_Id {
    ty := vtype(i);
    opc := inst_op(i);
    op0 := op(i, 0); op1 := op(i, 1);
    ok, x, c2v := pm_binop(op0, .ADD);
    if !ok || !has_one_use(op0) return NONE;
    okc2, c2 := pm_apint(c2v);
    okc, c := pm_apint(op1);
    if !okc2 || !okc return NONE;
    width := type_int_width(scalar_type(ty));
    last_one_math := width - ap_ctz(c2);
    if opc == {
        case .AND; if ap_clo(c) < last_one_math return NONE;
        case .XOR; #through;
        case .OR; if ap_clz(c) < last_one_math return NONE;
        case; fatal("internal: Unexpected BinaryOp!");
    }
    new_bin_op := icb_binop(opc, x, const_int_ap(ty, c));
    r := create_binop(.ADD, new_bin_op, const_int_ap(ty, c2));
    copy_ir_flags(r, op0);
    return r;
}

// foldBitwiseLogicWithIntrinsics
ic_fold_bitwise_logic_with_intrinsics :: (i: Value_Id) -> Value_Id {
    op0 := op(i, 0); op1 := op(i, 1);
    if !has_one_use(op0) return NONE;
    xid := call_iid(op0);
    if xid == NOT_INTRINSIC return NONE;
    yid := call_iid(op1);
    y_is := yid != NOT_INTRINSIC;
    if y_is && (!has_one_use(op1) || xid != yid) return NONE;
    rhsc: APInt;
    if !y_is {
        if !(xid == IID_BSWAP || xid == IID_BITREVERSE) return NONE;
        okc, c := pm_apint(op1);
        if !okc return NONE;
        rhsc = c;
    }
    if xid == IID_FSHL || xid == IID_FSHR {
        if op(op0, 2) != op(op1, 2) return NONE;
        n0 := icb_binop(inst_op(i), op(op0, 0), op(op1, 0));
        n1 := icb_binop(inst_op(i), op(op0, 1), op(op1, 1));
        return create_intrinsic_call(xid, .[vtype(i)], .[n0, n1, op(op0, 2)]);
    }
    if xid == IID_BSWAP || xid == IID_BITREVERSE {
        other := ifx y_is then op(op1, 0) else const_int_ap(vtype(i), ifx xid == IID_BSWAP then ap_byte_swap(rhsc) else ap_reverse_bits(rhsc));
        n0 := icb_binop(inst_op(i), op(op0, 0), other);
        return create_intrinsic_call(xid, .[vtype(i)], .[n0]);
    }
    return NONE;
}

// simplifyAndOrWithOpReplaced
ic_simplify_and_or_with_op_replaced :: (v: Value_Id, opv: Value_Id, rep_op: Value_Id, simplify_only_in: bool, depth: u32 = 0) -> Value_Id {
    if opv == rep_op return NONE;
    if v == opv return rep_op;
    if !is_binary_operator(v) || !is_bitwise_logic_op(inst_op(v)) || depth >= 3 return NONE;
    simplify_only := simplify_only_in;
    if !has_one_use(v) simplify_only = true;
    n0 := ic_simplify_and_or_with_op_replaced(op(v, 0), opv, rep_op, simplify_only, depth + 1);
    n1 := ic_simplify_and_or_with_op_replaced(op(v, 1), opv, rep_op, simplify_only, depth + 1);
    if n0 == NONE && n1 == NONE return NONE;
    if n0 == NONE n0 = op(v, 0);
    if n1 == NONE n1 = op(v, 1);
    res := simplify_binop_r(inst_op(v), n0, n1, sq_with_instruction(ic.sq, v), RECURSION_LIMIT);
    if res != NONE return res;
    if simplify_only return NONE;
    return icb_binop(inst_op(v), n0, n1);
}

// reassociateBooleanAndOr
ic_reassociate_boolean_and_or :: (lhs: Value_Id, x: Value_Id, y: Value_Id, i: Value_Id, is_and: bool, rhs_is_logical: bool) -> Value_Id {
    opc := ifx is_and then Opcode.AND else .OR;
    folded: Value_Id = NONE;
    res := ic_fold_boolean_and_or(lhs, x, i, is_and, false);
    if res != NONE {
        folded = ifx rhs_is_logical then icb_logical_op(opc, res, y) else icb_binop(opc, res, y);
    } else {
        res = ic_fold_boolean_and_or(lhs, y, i, is_and, false);
        if res != NONE folded = ifx rhs_is_logical then icb_logical_op(opc, x, res) else icb_binop(opc, x, res);
    }
    if folded != NONE && ic_is_binop(folded, .SELECT) ic_set_unknown_profile_if_profiled(folded);
    return folded;
}

// ---------------------------------------------------------------- funnel shifts, concats, select-from-and/or

// convertOrOfShiftsToFunnelShift: (ok, the three funnel-shift arguments, fshl or fshr)
ic_convert_or_of_shifts_to_funnel_shift :: (orv: Value_Id) -> (bool, [3] Value_Id, Intrinsic_Id) {
    none: [3] Value_Id;
    width := scalar_bits(orv);
    or0 := op(orv, 0); or1 := op(orv, 1);
    if !is_inst(or0) || !is_inst(or1) return false, none, IID_FSHL;
    if is_binary_operator(or0) && is_binary_operator(or1) {
        is_ls :: (v: Value_Id) -> bool { return has_one_use(v) && (inst_op(v) == .SHL || inst_op(v) == .LSHR); }
        if !is_ls(or0) || !is_ls(or1) || inst_op(or0) == inst_op(or1) return false, none, IID_FSHL;
        if inst_op(or0) == .LSHR { t := or0; or0 = or1; or1 = t; }
        shv0 := op(or0, 0); sha0 := op(or0, 1);
        shv1 := op(or1, 0); sha1 := op(or1, 1);
        match_amt :: (l: Value_Id, r: Value_Id, width: u32, shv0: Value_Id, shv1: Value_Id, orv: Value_Id) -> Value_Id {
            okl, li := pm_apint_ap(l);
            okr, ri := pm_apint_ap(r);
            if okl && okr && ap_ult_u64(li, width) && ap_ult_u64(ri, width) && ap_eq_u64(ap_add(li, ri), width) return const_int_ap(vtype(l), li);
            if is_const(l) && is_const(r) {
                ult :: (a: APInt) -> bool { return ap_ult_u64(a, a.bits); }
                if pm_int_pred(l, ult) && pm_int_pred(r, ult) && pm_specific_int_allow_poison(ce_binop(.ADD, l, r, 0), width)
                    return ic_merge_undefs_with(l, r);
            }
            oks, w, x := pm_binop(r, .SUB);
            if oks && has_one_use(r) && pm_specific_int(w, width) && x == l {
                kl := ic_known_bits(l, orv);
                if ap_ult_u64(kb_max_value(kl), width) return l;
                return NONE;
            }
            if shv0 != shv1 return NONE;
            if (width & (width - 1)) != 0 return NONE;
            mask := width - 1;
            neg_and :: (v: Value_Id, x: Value_Id, mask: u32) -> bool {
                ok, a, m := pm_binop(v, .AND);
                if !ok || !pm_specific_int(m, mask) return false;
                okn, nx := pm_neg(a);
                return okn && nx == x;
            }
            oka, ax, am := pm_binop(l, .AND);
            if oka && pm_specific_int(am, mask) && neg_and(r, ax, mask) return ax;
            if neg_and(r, l, mask) return l;
            okz, za := pmi_cast(l, .ZEXT);
            if okz {
                oka2, x2, m2 := pm_binop(za, .AND);
                if oka2 && pm_specific_int(m2, mask) {
                    okr2, ra, rm := pm_binop(r, .AND);
                    if okr2 && pm_specific_int(rm, mask) {
                        okn, nz := pm_neg(ra);
                        if okn {
                            okz2, za2 := pmi_cast(nz, .ZEXT);
                            if okz2 { okk, kx, km := pm_binop(za2, .AND); if okk && kx == x2 && pm_specific_int(km, mask) return l; }
                        }
                    }
                    okzr, zr := pmi_cast(r, .ZEXT);
                    if okzr {
                        okk, ka, km := pm_binop(zr, .AND);
                        if okk && pm_specific_int(km, mask) { okn, nx := pm_neg(ka); if okn && nx == x2 return l; }
                    }
                }
            }
            return NONE;
        }
        is_fshl := true;
        amt := match_amt(sha0, sha1, width, shv0, shv1, orv);
        if amt == NONE { amt = match_amt(sha1, sha0, width, shv0, shv1, orv); is_fshl = false; }
        if amt == NONE return false, none, IID_FSHL;
        r: [3] Value_Id; r[0] = shv0; r[1] = shv1; r[2] = amt;
        return true, r, ifx is_fshl then IID_FSHL else IID_FSHR;
    }
    if inst_op(or0) == .ZEXT || inst_op(or1) == .ZEXT {
        if inst_op(or1) != .ZEXT { t := or0; or0 = or1; or1 = t; }
        oks, zh, amtv := pm_binop(or0, .SHL);
        okc, amt := pm_apint(amtv);
        if !oks || !has_one_use(or0) || !okc return false, none, IID_FSHL;
        okl, low := pmi_cast(or1, .ZEXT);
        okh, high := pmi_cast(zh, .ZEXT);
        if !okl || !okh return false, none, IID_FSHL;
        hs := scalar_bits(high); ls := scalar_bits(low);
        if ap_ult_u64(amt, ls) || ap_ugt_u64(amt, width - hs) return false, none, IID_FSHL;
        u := ir.v_first_use[zh];
        while u != NONE {
            defer u = ir.u_next[u];
            us := ir.u_user[u];
            oko, x, y := pm_binop(us, .OR);
            if !oko continue;
            if !is_inst(y) || inst_op(y) != .ZEXT { t := x; x = y; y = t; }
            oks2, sx, lamtv := pm_binop(x, .SHL);
            okc2, lamt := pm_apint(lamtv);
            if !oks2 || sx != or1 || !okc2 || y != zh || !dt_dominates_inst(ic.dt, us, orv) continue;
            if !ap_eq_u64(ap_add(lamt, amt), width) continue;
            drop_poison_generating_flags(us);
            drop_poison_generating_flags(x);
            r: [3] Value_Id; r[0] = us; r[1] = us; r[2] = const_int_ap(vtype(or0), amt);
            return true, r, IID_FSHL;
        }
        return false, none, IID_FSHL;
    }
    return false, none, IID_FSHL;
}

// matchFunnelShift
ic_match_funnel_shift :: (orv: Value_Id) -> Value_Id {
    ok, args, iid := ic_convert_or_of_shifts_to_funnel_shift(orv);
    if !ok return NONE;
    return create_intrinsic_call(iid, .[vtype(orv)], args);
}

// peekThroughBitcast (InstCombineInternal.h)
ic_peek_through_bitcast :: (v: Value_Id, one_use_only := false) -> Value_Id {
    if is_inst(v) && inst_op(v) == .BITCAST && (!one_use_only || has_one_use(v)) return op(v, 0);
    return v;
}

// matchOrConcat
ic_match_or_concat :: (orv: Value_Id) -> Value_Id {
    op0 := op(orv, 0); op1 := op(orv, 1);
    ty := vtype(orv);
    width := type_int_width(scalar_type(ty));
    if (width & 1) != 0 return NONE;
    half := width / 2;
    if !(is_inst(op0) && inst_op(op0) == .ZEXT) { t := op0; op0 = op1; op1 = t; }
    okl, lower_src := pmi_cast(op0, .ZEXT);
    if !okl || !has_one_use(op0) return NONE;
    oks, shl_val, cv := pm_binop(op1, .SHL);
    okc, c := pm_apint(cv);
    if !oks || !has_one_use(op1) || !okc return NONE;
    oku, upper_src := pmi_cast(shl_val, .ZEXT);
    if !oku || !has_one_use(shl_val) return NONE;
    if !ap_eq_u64(c, half) || vtype(lower_src) != vtype(upper_src) || scalar_bits(lower_src) != half return NONE;
    concat_intrinsic_calls :: (id: Intrinsic_Id, lo: Value_Id, hi: Value_Id, ty: Type_Id, half: u32) -> Value_Id {
        nl := icb_zext(lo, ty);
        nu := icb_zext(hi, ty);
        nu = icb_shl_c(nu, half);
        bo := icb_disjoint_or(nl, nu);
        return icb_intrinsic(id, .[ty], .[bo]);
    }
    okb1, lb := pm_intrinsic1(lower_src, IID_BSWAP);
    okb2, ub := pm_intrinsic1(upper_src, IID_BSWAP);
    if okb1 && okb2 return concat_intrinsic_calls(IID_BSWAP, ub, lb, ty, half);
    okr1, lr := pm_intrinsic1(lower_src, IID_BITREVERSE);
    okr2, ur := pm_intrinsic1(upper_src, IID_BITREVERSE);
    if okr1 && okr2 return concat_intrinsic_calls(IID_BITREVERSE, ur, lr, ty, half);
    x := sext_or_self_i(lower_src);
    u := sext_or_self_i(upper_src);
    // m_SExtOrSelf(m_AShr(m_Specific(X), C)): try sext(ashr) first, then the value itself
    match_ashr :: (v: Value_Id, x: Value_Id) -> bool {
        ok, a, s := pm_binop(v, .ASHR);
        return ok && a == x && pm_specific_int(s, cast(u64) scalar_bits(x) - 1);
    }
    if match_ashr(u, x) || (u != upper_src && match_ashr(upper_src, x)) return icb_sext(x, ty);
    return NONE;
}

// areInverseVectorBitmasks
ic_are_inverse_vector_bitmasks :: (c1: Value_Id, c2: Value_Id) -> bool {
    n := type_count(vtype(c1));
    for k: 0..cast(s64) n - 1 {
        e1 := cf_elt(c1, cast(u64) k);
        e2 := cf_elt(c2, cast(u64) k);
        if e1 == NONE || e2 == NONE return false;
        if !((pm_zero(e1) && pm_all_ones(e2)) || (pm_zero(e2) && pm_all_ones(e1))) return false;
    }
    return true;
}

// getSelectCondition
ic_get_select_condition :: (a_in: Value_Id, b: Value_Id, ab_is_the_same: bool) -> Value_Id {
    a := a_in;
    ty := vtype(a);
    if !is_int_or_int_vector(ty) || !is_int_or_int_vector(vtype(b)) return NONE;
    is_not_a := false;
    if ab_is_the_same is_not_a = a == b;
    else { okn, na := pm_not(b); is_not_a = okn && na == a; }
    if is_not_a {
        if is_int_or_int_vector_n(ty, 1) return a;
        a = ic_peek_through_bitcast(a);
        if is_int_or_int_vector(vtype(a)) {
            nsb := ic_num_sign_bits(a, NONE);
            if nsb == scalar_bits(a) && nsb <= type_int_width(scalar_type(ty)) return icb_trunc(a, make_cmp_result_type(vtype(a)));
        }
        return NONE;
    }
    if ab_is_the_same return NONE;
    if is_const(a) && is_const(b) {
        if a == ce_not(b) && ic_num_sign_bits(a, NONE) == type_int_width(scalar_type(ty))
            return icb_zext_or_trunc(a, make_cmp_result_type(ty));
    }
    oks, cond := pmi_cast(a, .SEXT);
    if oks && is_int_or_int_vector_n(vtype(cond), 1) {
        okb, nb := pmi_cast(b, .SEXT);
        if okb { okn, nc := pm_not(nb); if okn && nc == cond return cond; }
        okn, not_b := pm_not(b);
        if okn && has_one_use(b) {
            not_b = ic_peek_through_bitcast(not_b, true);
            okz, zc := pmi_cast(not_b, .SEXT);
            if okz && zc == cond return cond;
        }
    }
    if !is_vector_type(ty) return NONE;
    {
        oka, sa, ac := pm_binop(a, .XOR);
        if oka && is_const(ac) {
            okc, c2 := pmi_cast(sa, .SEXT);
            if okc {
                okb, sb, bc := pm_binop(b, .XOR);
                if okb && is_const(bc) {
                    okc2, cb := pmi_cast(sb, .SEXT);
                    if okc2 && cb == c2 && is_int_or_int_vector_n(vtype(c2), 1) && ic_are_inverse_vector_bitmasks(ac, bc) {
                        act := ce_cast(.TRUNC, ac, make_cmp_result_type(ty));
                        return icb_xor(c2, act);
                    }
                }
            }
        }
    }
    return NONE;
}

// matchSelectFromAndOr
ic_match_select_from_and_or :: (a_in: Value_Id, b: Value_Id, c_in: Value_Id, d_in: Value_Id, invert_false_val := false) -> Value_Id {
    orig_type := vtype(a_in);
    a := ic_peek_through_bitcast(a_in, true);
    c := ic_peek_through_bitcast(c_in, true);
    d := d_in;
    cond := ic_get_select_condition(a, c, invert_false_val);
    if cond == NONE return NONE;
    sel_ty := vtype(a);
    ct := vtype(cond);
    if is_vector_type(ct) {
        elts := type_count(ct);
        sel_elt_size := ic_primitive_size_bits(sel_ty);
        elt_ty := type_int(cast(u32) (sel_elt_size / elts));
        sel_ty = type_vector(elts, elt_ty, type_kind(ct) == .SVECTOR);
    }
    bcb := icb_cast(.BITCAST, b, sel_ty);
    if invert_false_val d = icb_not(d);
    bcd := icb_cast(.BITCAST, d, sel_ty);
    sel := icb_select(cond, bcb, bcd);
    return icb_cast(.BITCAST, sel, orig_type);
}

// foldAndOrOfICmpEqConstantAndICmp
ic_fold_and_or_of_icmp_eq_constant_and_icmp :: (lhs: Value_Id, rhs: Value_Id, is_and: bool, is_logical: bool) -> Value_Id {
    lhs0 := op(lhs, 0); rhs0 := op(rhs, 0); rhs1 := op(rhs, 1);
    lpred := ifx is_and then cmp_inverse(inst_pred(lhs)) else inst_pred(lhs);
    rpred := ifx is_and then cmp_inverse(inst_pred(rhs)) else inst_pred(rhs);
    okc, cint := pm_apint_ap(op(lhs, 1));
    if lpred != ICMP_EQ || !okc || !is_int_or_int_vector(vtype(lhs0)) || !(has_one_use(lhs) || has_one_use(rhs)) return NONE;
    match_rhs_op :: (v: Value_Id, lhs0: Value_Id, cint: APInt) -> bool {
        ok, a, b := pm_binop(v, .ADD);
        if ok && a == lhs0 && pm_specific_int_ap(b, ap_neg(cint)) return true;
        return ap_is_zero(cint) && v == lhs0;
    }
    other: Value_Id = NONE;
    if rpred == ICMP_ULT && match_rhs_op(rhs1, lhs0, cint) other = rhs0;
    else if rpred == ICMP_UGT && match_rhs_op(rhs0, lhs0, cint) other = rhs1;
    else return NONE;
    if is_logical other = icb_freeze(other);
    return icb_cmp(ifx is_and then cast(u8) ICMP_ULT else ICMP_UGE,
                   icb_sub(lhs0, const_int_ap(vtype(lhs0), ap_add_u64(cint, 1))), other);
}

// foldAndOrOfICmps
ic_fold_and_or_of_icmps :: (lhs: Value_Id, rhs: Value_Id, i: Value_Id, is_and: bool, is_logical: bool) -> Value_Id {
    q := ic_q(i);
    pred_l := inst_pred(lhs); pred_r := inst_pred(rhs);
    lhs0 := op(lhs, 0); rhs0 := op(rhs, 0);
    lhs1 := op(lhs, 1); rhs1 := op(rhs, 1);
    has_lc, lhsc := pm_apint(lhs1);
    has_rc, rhsc := pm_apint(rhs1);

    if ic_predicates_foldable(pred_l, pred_r) {
        if lhs0 == rhs1 && lhs1 == rhs0 {
            pred_l = icmp_swapped(pred_l);
            t := lhs0; lhs0 = lhs1; lhs1 = t;
        }
        if lhs0 == rhs0 && lhs1 == rhs1 {
            code := ifx is_and then ic_get_icmp_code(pred_l) & ic_get_icmp_code(pred_r) else ic_get_icmp_code(pred_l) | ic_get_icmp_code(pred_r);
            is_signed := icmp_is_signed(inst_pred(lhs)) || icmp_is_signed(inst_pred(rhs));
            return ic_get_new_icmp_value(code, is_signed, lhs0, lhs1);
        }
    }

    v := ic_fold_and_or_of_icmp_eq_constant_and_icmp(lhs, rhs, is_and, is_logical); if v != NONE return v;
    v = ic_fold_and_or_of_icmp_eq_constant_and_icmp(rhs, lhs, is_and, false); if v != NONE return v;

    v = ic_fold_and_or_of_icmps_with_const_eq(lhs, rhs, is_and, is_logical, q, i); if v != NONE return v;
    v = ic_fold_and_or_of_icmps_with_const_eq(rhs, lhs, is_and, false, q, i);
    if v != NONE {
        if is_logical && ic_has_same_sign(rhs) && ir.v_first_use[rhs] != NONE {
            ic_set_same_sign(rhs, false);
            wl_add(rhs);
        }
        return v;
    }

    v = ic_fold_is_power_of2_or_zero(lhs, rhs, is_and); if v != NONE return v;
    v = ic_fold_is_power_of2_or_zero(rhs, lhs, is_and); if v != NONE return v;

    if !is_logical {
        v = ic_simplify_range_check(lhs, rhs, !is_and); if v != NONE return v;
        v = ic_simplify_range_check(rhs, lhs, !is_and); if v != NONE return v;
    }

    if is_and && !is_logical {
        v = ic_fold_signed_truncation_check(lhs, rhs, i); if v != NONE return v;
    }

    v = ic_fold_is_power_of2(lhs, rhs, is_and); if v != NONE return v;
    v = ic_fold_power_of2_and_shifted_mask(lhs, rhs, is_and); if v != NONE return v;

    if !is_logical {
        v = ic_fold_unsigned_underflow_check(lhs, rhs, is_and, q); if v != NONE return v;
        v = ic_fold_unsigned_underflow_check(rhs, lhs, is_and, q); if v != NONE return v;
    }

    eq_or_ne := ifx is_and then cast(u8) ICMP_EQ else ICMP_NE;
    if pred_l == eq_or_ne && pred_l == pred_r && pm_zero_int(lhs1) && pm_zero_int(rhs1) && vtype(lhs0) == vtype(rhs0) &&
       (!is_logical || is_guaranteed_not_to_be_poison(rhs0)) {
        new_or := icb_or(lhs0, rhs0);
        return icb_cmp(pred_l, new_or, const_null_value(vtype(new_or)));
    }
    if pred_l == eq_or_ne && pred_l == pred_r && pm_all_ones(lhs1) && pm_all_ones(rhs1) && vtype(lhs0) == vtype(rhs0) &&
       (!is_logical || is_guaranteed_not_to_be_poison(rhs0)) {
        new_and := icb_and(lhs0, rhs0);
        return icb_cmp(pred_l, new_and, const_all_ones_of(vtype(lhs0)));
    }

    if !is_logical {
        v = ic_fold_and_or_of_icmps_with_pow2_and_with_zero(lhs, rhs, is_and, q); if v != NONE return v;
    }

    if !has_lc || !has_rc return NONE;

    if pred_l == eq_or_ne && pred_l == pred_r && has_one_use(lhs) && has_one_use(rhs) {
        vv: Value_Id = NONE;
        and_c, small_c, big_c: APInt;
        found := false;
        okt, tv := pmi_cast(rhs0, .TRUNC);
        if okt {
            oka, av, acv := pm_binop(lhs0, .AND);
            okc, ac := pm_apint(acv);
            if oka && av == tv && okc { vv = tv; and_c = ac; small_c = rhsc; big_c = lhsc; found = true; }
        }
        if !found {
            okt2, tv2 := pmi_cast(lhs0, .TRUNC);
            if okt2 {
                oka, av, acv := pm_binop(rhs0, .AND);
                okc, ac := pm_apint(acv);
                if oka && av == tv2 && okc { vv = tv2; and_c = ac; small_c = lhsc; big_c = rhsc; found = true; }
            }
        }
        if found {
            big_bits := big_c.bits;
            small_bits := small_c.bits;
            low := ap_low_bits_set(big_bits, small_bits);
            if ap_is_zero(ap_and(low, and_c)) && ap_is_zero(ap_and(low, big_c)) {
                new_and := icb_and(vv, const_int_ap(vtype(vv), ap_or(low, and_c)));
                n := ap_or(ap_zext(small_c, big_bits), big_c);
                new_val := const_int_ap(vtype(new_and), n);
                return icb_cmp(pred_l, new_and, new_val);
            }
        }
    }

    sbl, true_if_signed_l := is_sign_bit_check(pred_l, lhsc);
    sbr, true_if_signed_r := is_sign_bit_check(pred_r, rhsc);
    if sbl && sbr && (has_one_use(rhs) || has_one_use(lhs)) {
        match_pair :: (l0: Value_Id, r0: Value_Id, l_opc: Opcode, r_opc: Opcode) -> (bool, Value_Id, Value_Id) {
            ok, x, y := pm_binop(l0, l_opc);
            if ok && ic_is_c_binop_of(r0, r_opc, x, y) return true, x, y;
            return false, NONE, NONE;
        }
        if is_and {
            ok := false; x, y: Value_Id;
            if true_if_signed_l && !true_if_signed_r { ok, x, y = match_pair(lhs0, rhs0, .OR, .AND); }
            if !ok && !true_if_signed_l && true_if_signed_r { ok, x, y = match_pair(lhs0, rhs0, .AND, .OR); }
            if ok {
                new_xor := icb_xor(x, y);
                return icb_cmp(ICMP_SLT, new_xor, const_null_value(vtype(new_xor)), "isneg");
            }
        } else {
            ok := false; x, y: Value_Id;
            if true_if_signed_l && !true_if_signed_r { ok, x, y = match_pair(lhs0, rhs0, .AND, .OR); }
            if !ok && !true_if_signed_l && true_if_signed_r { ok, x, y = match_pair(lhs0, rhs0, .OR, .AND); }
            if ok {
                new_xor := icb_xor(x, y);
                return icb_cmp(ICMP_SGT, new_xor, const_all_ones_of(vtype(new_xor)), "isnotneg");
            }
        }
    }

    if lhs0 == rhs0 && pred_l == pred_r && pred_l == (ifx is_and then cast(u8) ICMP_NE else ICMP_EQ) &&
       !fn_has_fn_attr(inst_fn(i), .NoImplicitFloat) && has_one_use(lhs) && has_one_use(rhs) {
        oka, bc, mcv := pm_binop(lhs0, .AND);
        okm, mask_c := pm_apint(mcv);
        if oka && okm {
            okb, x := pm_elementwise_bitcast(bc);
            if okb {
                st := scalar_type(vtype(x));
                if ic_is_ieee_like_fp_ty(st) && ap_eq(mask_c, ic_fp_inf_bits(st)) &&
                   ((ap_is_zero(lhsc) && ap_eq(rhsc, mask_c)) || (ap_is_zero(rhsc) && ap_eq(lhsc, mask_c)))
                    return icb_is_fpclass(x, ifx is_and then cast(u32) FC_NORMAL else fc_not(FC_NORMAL));
            }
        }
    }

    return ic_fold_and_or_of_icmps_using_ranges(lhs, rhs, is_and);
}

// ---------------------------------------------------------------- recognizeBSwapOrBitReverseIdiom (Transforms/Utils/Local.cpp)

BIT_PART_UNSET :: -1;
BIT_PART_RECURSION_MAX_DEPTH :: 48;
Bit_Part :: struct { valid: bool; provider: Value_Id; prov: [..] s8; }
Bit_Parts :: struct { map: Table(Value_Id, s32); parts: [..] Bit_Part; found_root: bool; }

ic_bp_new :: (provider: Value_Id, bw: u32) -> Bit_Part {
    r: Bit_Part;
    r.valid = true; r.provider = provider;
    r.prov.allocator = temp;
    array_resize(*r.prov, bw);
    for * r.prov it.* = 0;
    return r;
}
ic_bp_copy :: (src: Bit_Part) -> Bit_Part {
    r: Bit_Part;
    r.valid = src.valid; r.provider = src.provider;
    r.prov.allocator = temp;
    for src.prov array_add(*r.prov, it);
    return r;
}

// collectBitParts: index of the (memoized) result in bps.parts
ic_collect_bit_parts :: (v: Value_Id, match_bswaps: bool, match_bit_reversals: bool, bps: *Bit_Parts, depth: s32) -> s32 {
    found, idx := table_find(*bps.map, v);
    if found return idx;
    ri := cast(s32) bps.parts.count;
    empty: Bit_Part;
    array_add(*bps.parts, empty);
    table_add(*bps.map, v, ri);
    bw := scalar_bits(v);
    if bw > 128 return ri;
    if depth == BIT_PART_RECURSION_MAX_DEPTH return ri;
    set :: (bps: *Bit_Parts, ri: s32, p: Bit_Part) -> s32 { bps.parts[ri] = p; return ri; }
    if is_inst(v) {
        o := inst_op(v);
        if o == .OR {
            ai := ic_collect_bit_parts(op(v, 0), match_bswaps, match_bit_reversals, bps, depth + 1);
            if !bps.parts[ai].valid || bps.parts[ai].provider == NONE return ri;
            bi := ic_collect_bit_parts(op(v, 1), match_bswaps, match_bit_reversals, bps, depth + 1);
            if !bps.parts[bi].valid || bps.parts[ai].provider != bps.parts[bi].provider return ri;
            r := ic_bp_new(bps.parts[ai].provider, bw);
            a := bps.parts[ai]; b := bps.parts[bi];
            for k: 0..cast(s64) bw - 1 {
                if a.prov[k] != BIT_PART_UNSET && b.prov[k] != BIT_PART_UNSET && a.prov[k] != b.prov[k] {
                    nothing: Bit_Part;
                    return set(bps, ri, nothing);
                }
                r.prov[k] = ifx a.prov[k] == BIT_PART_UNSET then b.prov[k] else a.prov[k];
            }
            return set(bps, ri, r);
        }
        if o == .SHL || o == .LSHR {
            okc, c := pm_apint(op(v, 1));
            if okc {
                if ap_uge_u64(c, bw) return ri;
                sh := cast(s64) ap_zext_value(c);
                if !match_bit_reversals && (sh % 8) != 0 return ri;
                xi := ic_collect_bit_parts(op(v, 0), match_bswaps, match_bit_reversals, bps, depth + 1);
                if !bps.parts[xi].valid return ri;
                r := ic_bp_copy(bps.parts[xi]);
                n := r.prov.count;
                np: [..] s8; np.allocator = temp;
                if o == .SHL {
                    for 0..sh - 1 array_add(*np, BIT_PART_UNSET);
                    for k: 0..n - sh - 1 array_add(*np, r.prov[k]);
                } else {
                    for k: sh..n - 1 array_add(*np, r.prov[k]);
                    for 0..sh - 1 array_add(*np, BIT_PART_UNSET);
                }
                r.prov = np;
                return set(bps, ri, r);
            }
        }
        if o == .AND {
            okc, mask := pm_apint(op(v, 1));
            if okc {
                if !match_bit_reversals && (ap_popcount(mask) % 8) != 0 return ri;
                xi := ic_collect_bit_parts(op(v, 0), match_bswaps, match_bit_reversals, bps, depth + 1);
                if !bps.parts[xi].valid return ri;
                r := ic_bp_copy(bps.parts[xi]);
                for k: 0..cast(s64) bw - 1 if !ap_bit(mask, cast(u32) k) r.prov[k] = BIT_PART_UNSET;
                return set(bps, ri, r);
            }
        }
        if o == .ZEXT {
            x := op(v, 0);
            xi := ic_collect_bit_parts(x, match_bswaps, match_bit_reversals, bps, depth + 1);
            if !bps.parts[xi].valid return ri;
            r := ic_bp_new(bps.parts[xi].provider, bw);
            nbw := scalar_bits(x);
            for k: 0..cast(s64) nbw - 1 r.prov[k] = bps.parts[xi].prov[k];
            for k: cast(s64) nbw..cast(s64) bw - 1 r.prov[k] = BIT_PART_UNSET;
            return set(bps, ri, r);
        }
        if o == .TRUNC {
            xi := ic_collect_bit_parts(op(v, 0), match_bswaps, match_bit_reversals, bps, depth + 1);
            if !bps.parts[xi].valid return ri;
            r := ic_bp_new(bps.parts[xi].provider, bw);
            for k: 0..cast(s64) bw - 1 r.prov[k] = bps.parts[xi].prov[k];
            return set(bps, ri, r);
        }
        iid := ifx o == .CALL then call_iid(v) else NOT_INTRINSIC;
        if iid == IID_BITREVERSE {
            xi := ic_collect_bit_parts(op(v, 0), match_bswaps, match_bit_reversals, bps, depth + 1);
            if !bps.parts[xi].valid return ri;
            r := ic_bp_new(bps.parts[xi].provider, bw);
            for k: 0..cast(s64) bw - 1 r.prov[(cast(s64) bw - 1) - k] = bps.parts[xi].prov[k];
            return set(bps, ri, r);
        }
        if iid == IID_BSWAP {
            xi := ic_collect_bit_parts(op(v, 0), match_bswaps, match_bit_reversals, bps, depth + 1);
            if !bps.parts[xi].valid return ri;
            byte_width := cast(s64) bw / 8;
            r := ic_bp_new(bps.parts[xi].provider, bw);
            for bi: 0..byte_width - 1 {
                ofs := bi * 8;
                for k: 0..7 r.prov[(cast(s64) bw - 8 - ofs) + k] = bps.parts[xi].prov[ofs + k];
            }
            return set(bps, ri, r);
        }
        if iid == IID_FSHL || iid == IID_FSHR {
            okc, c := pm_apint(op(v, 2));
            if okc {
                mod_amt := cast(s64) ap_urem_u64(c, bw);
                if iid == IID_FSHR mod_amt = cast(s64) bw - mod_amt;
                if !match_bit_reversals && (mod_amt % 8) != 0 return ri;
                li := ic_collect_bit_parts(op(v, 0), match_bswaps, match_bit_reversals, bps, depth + 1);
                if !bps.parts[li].valid || bps.parts[li].provider == NONE return ri;
                rr := ic_collect_bit_parts(op(v, 1), match_bswaps, match_bit_reversals, bps, depth + 1);
                if !bps.parts[rr].valid || bps.parts[li].provider != bps.parts[rr].provider return ri;
                start_rhs := cast(s64) bw - mod_amt;
                r := ic_bp_new(bps.parts[li].provider, bw);
                for k: 0..start_rhs - 1 r.prov[k + mod_amt] = bps.parts[li].prov[k];
                for k: 0..mod_amt - 1 r.prov[k] = bps.parts[rr].prov[k + start_rhs];
                return set(bps, ri, r);
            }
        }
    }
    if bps.found_root return ri;
    bps.found_root = true;
    r := ic_bp_new(v, bw);
    for k: 0..cast(s64) bw - 1 r.prov[k] = cast(s8) k;
    return set(bps, ri, r);
}

ap_bit :: (a: APInt, k: u32) -> bool { return !ap_is_zero(ap_and(ap_lshr(a, k), ap_one(a.bits))); }

// recognizeBSwapOrBitReverseIdiom: the inserted instructions (all linked before I), or an empty list
ic_recognize_bswap_or_bit_reverse_idiom :: (i: Value_Id, match_bswaps: bool, match_bit_reversals: bool) -> [..] Value_Id {
    inserted: [..] Value_Id; inserted.allocator = temp;
    iid := call_iid(i);
    if inst_op(i) != .OR && iid != IID_FSHL && iid != IID_FSHR && iid != IID_BSWAP return inserted;
    if !match_bswaps && !match_bit_reversals return inserted;
    ity := vtype(i);
    if !is_int_or_int_vector(ity) || scalar_bits(i) == 1 || scalar_bits(i) > 128 return inserted;
    bps: Bit_Parts;
    bps.map.allocator = temp;
    bps.parts.allocator = temp;
    ri := ic_collect_bit_parts(i, match_bswaps, match_bit_reversals, *bps, 0);
    if !bps.parts[ri].valid return inserted;
    prov := bps.parts[ri].prov;
    n := prov.count;
    demanded_ty := ity;
    if prov[n - 1] == BIT_PART_UNSET {
        while n > 0 && prov[n - 1] == BIT_PART_UNSET n -= 1;
        if n == 0 return inserted;
        demanded_ty = type_with_new_bit_width(ity, cast(u32) n);
    }
    demanded_bw := cast(u32) n;
    if demanded_bw > scalar_bits(i) return inserted;
    demanded_mask := ap_all_ones(demanded_bw);
    ok_bswap := match_bswaps && (demanded_bw % 16) == 0;
    ok_brev := match_bit_reversals;
    k: u32 = 0;
    while k < demanded_bw && (ok_bswap || ok_brev) {
        defer k += 1;
        if prov[k] == BIT_PART_UNSET { ap_set_bit_val(*demanded_mask, k, false); continue; }
        from := cast(u32) prov[k];
        // bitTransformIsCorrectForBSwap
        bs_ok := (from % 8 == k % 8) && ((from >> 3) == (demanded_bw >> 3) - (k >> 3) - 1);
        ok_bswap = ok_bswap && bs_ok;
        ok_brev = ok_brev && from == demanded_bw - k - 1;
    }
    intrin: Intrinsic_Id;
    if ok_bswap intrin = IID_BSWAP;
    else if ok_brev intrin = IID_BITREVERSE;
    else return inserted;
    provider := bps.parts[ri].provider;
    if demanded_ty != vtype(provider) {
        // CastInst::CreateIntegerCast(Provider, DemandedTy, isSigned=false)
        tr := create_cast(ifx scalar_bits(provider) < demanded_bw then Opcode.ZEXT else .TRUNC, provider, demanded_ty);
        insert_before_named(tr, i, "trunc");
        array_add(*inserted, tr);
        provider = tr;
    }
    result := create_intrinsic_call(intrin, .[demanded_ty], .[provider]);
    insert_before_named(result, i, "rev");
    array_add(*inserted, result);
    if !ap_is_all_ones(demanded_mask) {
        result = create_binop(.AND, result, const_int_ap(demanded_ty, demanded_mask));
        insert_before_named(result, i, "mask");
        array_add(*inserted, result);
    }
    if ity != vtype(result) {
        ext := create_cast(.ZEXT, result, ity);
        insert_before_named(ext, i, "zext");
        array_add(*inserted, ext);
    }
    return inserted;
}

// Instruction::removeFromParent: unlinked, the name leaves the symbol table but stays on the value
ic_remove_from_parent :: (i: Value_Id) {
    n := vname(i);
    set_name(i, "");
    inst_unlink(i);
    ir.v_name[i] = n;
}

// matchBSwapOrBitReverse
ic_match_bswap_or_bit_reverse :: (i: Value_Id, match_bswaps: bool, match_bit_reversals: bool) -> Value_Id {
    insts := ic_recognize_bswap_or_bit_reverse_idiom(i, match_bswaps, match_bit_reversals);
    if insts.count == 0 return NONE;
    last := insts[insts.count - 1];
    ic_remove_from_parent(last);
    for k: 0..insts.count - 2 {
        copy_debug_loc_or_clear(insts[k], i);
        wl_push(insts[k]);
    }
    return last;
}

// ---------------------------------------------------------------- foldBooleanAndOr and the or helpers

// foldBooleanAndOr
ic_fold_boolean_and_or :: (lhs: Value_Id, rhs: Value_Id, i: Value_Id, is_and: bool, is_logical: bool) -> Value_Id {
    if !is_int_or_int_vector_n(vtype(lhs), 1) return NONE;
    v := ic_fold_log_op_of_masked_icmps(lhs, rhs, is_and, is_logical, ic_q(i)); if v != NONE return v;
    if ic_is_icmp(lhs) && ic_is_icmp(rhs) {
        v = ic_fold_and_or_of_icmps(lhs, rhs, i, is_and, is_logical); if v != NONE return v;
    }
    if ic_is_fcmp(lhs) && ic_is_fcmp(rhs) {
        v = ic_fold_logic_of_fcmps(lhs, rhs, is_and, is_logical); if v != NONE return v;
    }
    v = ic_fold_eq_of_parts(lhs, rhs, is_and); if v != NONE return v;
    return NONE;
}

// foldOrOfInversions
ic_fold_or_of_inversions :: (i: Value_Id) -> Value_Id {
    ok1, c1, c2 := pm_binop(op(i, 0), .AND);
    ok2, c3, c4 := pm_binop(op(i, 1), .AND);
    if !ok1 || !ok2 return NONE;
    if is_known_inversion(c1, c3) && is_known_inversion(c2, c4) return icb_xor(c1, c4);
    if is_known_inversion(c1, c4) && is_known_inversion(c2, c3) return icb_xor(c1, c3);
    return NONE;
}

Sub_Pack :: struct { vec: Value_Id; offset: s64; }

// matchSubIntegerPackFromVector (Mask is a bit vector of `mask.count` elements)
ic_match_sub_integer_pack_from_vector :: (v: Value_Id, mask: *[..] bool) -> (bool, Value_Id, s64) {
    // m_ShlOrSelf(m_ZExtOrSelf(m_ExtractElt(m_Value(Vec), m_ConstantInt(VecIdx))), ShlAmt)
    {
        sv := v; shl_amt: u64 = 0;
        oks, sx, sa := pm_binop(v, .SHL);
        if oks { okc, a := pm_constant_int_u64(sa); if okc { sv = sx; shl_amt = a; } else sv = NONE; }
        e := ifx sv != NONE then zext_or_self_i(sv) else NONE;
        if e != NONE && ic_is_binop(e, .EXTRACTELEMENT) {
            okc, vec_idx := pm_constant_int_u64(op(e, 1));
            if okc {
                vec := op(e, 0);
                vt := vtype(vec);
                if type_kind(vt) != .VECTOR return false, NONE, 0;
                et := type_elem(vt);
                if !is_int_type(et) return false, NONE, 0;
                ebw := cast(u64) type_int_width(et);
                tbw := cast(u64) type_int_width(vtype(v));
                if tbw % ebw != 0 || shl_amt % ebw != 0 return false, NONE, 0;
                tew := tbw / ebw;
                shl_elt := shl_amt / ebw;
                mask_idx := ifx !dl.big_endian then shl_elt else tew - shl_elt - 1;
                off := cast(s64) vec_idx - cast(s64) mask_idx;
                array_resize(mask, cast(s64) tew);
                mask.*[mask_idx] = true;
                return true, vec, off;
            }
        }
    }
    okb, src := pm_cast(v, .BITCAST);
    if !okb || !is_inst(src) return false, NONE, 0;
    st := vtype(src);
    if type_kind(st) != .VECTOR return false, NONE, 0;
    array_resize(mask, cast(s64) type_count(st));
    if inst_op(src) == .SHUFFLEVECTOR {
        vec := op(src, 0); cv := op(src, 1);
        if !is_const(cv) return false, NONE, 0;
        smask := shuffle_mask(src);
        vt := vtype(vec);
        if type_kind(vt) != .VECTOR return false, NONE, 0;
        nve := cast(u32) type_count(vt);
        found := false; off: s64 = 0;
        for idx: 0..smask.count - 1 {
            if smask[idx] == POISON_MASK_ELEM return false, NONE, 0;
            si := smask[idx];
            if si >= nve {
                ce := cf_elt(cv, cast(u64) (si - nve));
                if ce == NONE || vkind(ce) != .C_INT || !is_null_value(ce) {
                    if !(ce != NONE && vkind(ce) == .C_INT && ap_is_zero(const_ap(ce))) return false, NONE, 0;
                }
                continue;
            }
            if found { if off + idx != cast(s64) si return false, NONE, 0; }
            else {
                if cast(s64) si < idx return false, NONE, 0;
                off = cast(s64) si - idx; found = true;
            }
            mask.*[idx] = true;
        }
        return found, vec, off;
    }
    if inst_op(src) == .INSERTELEMENT && pm_zero(op(src, 1)) {
        okc, ins_idx := pm_constant_int_u64(op(src, 2));
        if !okc return false, NONE, 0;
        vec := op(src, 0);
        if type_kind(vtype(vec)) != .VECTOR return false, NONE, 0;
        already := mask.*[ins_idx];
        for * mask.* it.* = true;
        if !already mask.*[ins_idx] = false;
        return true, vec, 0;
    }
    return false, NONE, 0;
}

// foldIntegerPackFromVector
ic_fold_integer_pack_from_vector :: (i: Value_Id) -> Value_Id {
    mask: [..] bool; mask.allocator = temp;
    okl, lv, loff := ic_match_sub_integer_pack_from_vector(op(i, 0), *mask);
    if !okl return NONE;
    okr, rv, roff := ic_match_sub_integer_pack_from_vector(op(i, 1), *mask);
    if !okr return NONE;
    if lv != rv || loff != roff return NONE;
    zero_idx := cast(u32) type_count(vtype(lv));
    smask := NewArray(mask.count, u32,, allocator = temp);
    for mask { smask[it_index] = ifx it then cast(u32) (loff + it_index) else zero_idx; }
    masked := icb_shuffle(lv, const_null_value(vtype(lv)), smask, tprint("%.v", vname(i)));
    return create_cast(.BITCAST, masked, vtype(i));
}

// matchZExtedSubInteger: (ok, Int, Mask, Offset, IsShlNUW, IsShlNSW)
ic_match_zexted_sub_integer :: (v: Value_Id) -> (bool, Value_Id, APInt, u64, bool, bool) {
    no: APInt;
    oks, shl_op0, sa := pm_binop(v, .SHL);
    if !oks || !has_one_use(v) return false, NONE, no, 0, false, false;
    okc, shl_amt := pm_constant_int_u64(sa);
    if !okc return false, NONE, no, 0, false, false;
    nuw := has_nuw(v); nsw := has_nsw(v);
    okz, zop := pmi_cast(shl_op0, .ZEXT);
    if !okz || !has_one_use(shl_op0) return false, NONE, no, 0, false, false;
    masked := zop;
    has_mask := false; smc: APInt;
    oka, ma, mc := pm_binop(zop, .AND);
    if oka && has_one_use(zop) {
        okm, m := pm_apint(mc);
        if okm { masked = ma; smc = m; has_mask = true; }
    }
    int_v := masked; lshr_amt: u64 = 0;
    okl, la, lsa := pm_binop(masked, .LSHR);
    if okl && has_one_use(masked) {
        okc2, a := pm_constant_int_u64(lsa);
        if okc2 { int_v = la; lshr_amt = a; }
    }
    if lshr_amt > shl_amt return false, NONE, no, 0, false, false;
    offset := shl_amt - lshr_amt;
    mask := ifx has_mask then ap_shl(smc, cast(u32) lshr_amt) else ap_bits_set_from(scalar_bits(int_v), cast(u32) lshr_amt);
    return true, int_v, mask, offset, nuw, nsw;
}

// foldIntegerRepackThroughZExt
ic_fold_integer_repack_through_zext :: (lhs: Value_Id, rhs: Value_Id) -> Value_Id {
    okl, li, lm, lo, lnuw, lnsw := ic_match_zexted_sub_integer(lhs);
    if !okl return NONE;
    okr, rint, rm, ro, rnuw, rnsw := ic_match_zexted_sub_integer(rhs);
    if !okr return NONE;
    if li != rint || lo != ro return NONE;
    mask := ap_or(lm, rm);
    dest_ty := vtype(lhs);
    a := icb_and(li, const_int_ap(vtype(li), mask), tprint("%.mask", vname(li)));
    z := icb_zext(a, dest_ty, tprint("%.zext", vname(li)));
    res := icb_shl(z, const_int_of(dest_ty, lo), "", lnuw && rnuw, lnsw && rnsw);
    ic_take_name(res, lhs);
    return res;
}

Bit_Mask_Mul :: struct { x: Value_Id; factor: APInt; mask: APInt; nuw: bool; nsw: bool; }

// matchBitmaskMul
ic_match_bitmask_mul :: (v: Value_Id) -> (bool, Bit_Mask_Mul) {
    r: Bit_Mask_Mul;
    if !is_inst(v) return false, r;
    {
        okm, a, mcv := pm_binop(v, .MUL);
        if okm {
            oka, orig, mv := pm_binop(a, .AND);
            okmask, mask := pm_apint(mv);
            okc, mul_c := pm_apint(mcv);
            if oka && okmask && okc {
                if ap_is_zero(mul_c) || ap_is_zero(mask) return false, r;
                r.x = orig; r.factor = mul_c; r.mask = mask; r.nuw = has_nuw(v); r.nsw = has_nsw(v);
                return true, r;
            }
        }
    }
    oks, cond, tv, fv := pm_select(v);
    if oks {
        okt, eq_zero := pm_apint(tv);
        okf, ne_zero := pm_apint(fv);
        if okt && okf {
            okd, d := decompose_bit_test(cond, true, false, true);
            if !okd return false, r;
            if vtype(d.x) != vtype(v) return false, r;
            if d.pred == ICMP_NE { t := eq_zero; eq_zero = ne_zero; ne_zero = t; }
            if !ap_is_zero(eq_zero) || ap_is_zero(ne_zero) return false, r;
            if !ap_is_power_of_2(d.mask) || ap_is_zero(d.mask) return false, r;
            if !ap_is_zero(ap_urem(ne_zero, d.mask)) return false, r;
            r.x = d.x; r.factor = ap_udiv(ne_zero, d.mask); r.mask = d.mask; r.nuw = false; r.nsw = false;
            return true, r;
        }
    }
    return false, r;
}

// foldBitmaskMul
ic_fold_bitmask_mul :: (op0: Value_Id, op1: Value_Id) -> Value_Id {
    ok1, d1 := ic_match_bitmask_mul(op1);
    if !ok1 return NONE;
    ok0, d0 := ic_match_bitmask_mul(op0);
    if !ok0 return NONE;
    if d0.x == d1.x && !ap_intersects(d0.mask, d1.mask) && ap_eq(d0.factor, d1.factor) {
        new_and := icb_and(d0.x, const_int_ap(vtype(d0.x), ap_add(d0.mask, d1.mask)));
        return icb_mul(new_and, const_int_ap(vtype(new_and), d1.factor), "", d0.nuw && d1.nuw, d0.nsw && d1.nsw);
    }
    return NONE;
}

// foldDisjointOr
ic_fold_disjoint_or :: (lhs: Value_Id, rhs: Value_Id) -> Value_Id {
    r := ic_fold_bitmask_mul(lhs, rhs); if r != NONE return r;
    r = ic_fold_integer_repack_through_zext(lhs, rhs); if r != NONE return r;
    return NONE;
}

// reassociateDisjointOr
ic_reassociate_disjoint_or :: (lhs: Value_Id, rhs: Value_Id) -> Value_Id {
    ok, x, y := pm_disjoint_or(rhs);
    if ok && has_one_use(rhs) {
        r := ic_fold_disjoint_or(lhs, x); if r != NONE return icb_disjoint_or(r, y);
        r = ic_fold_disjoint_or(lhs, y); if r != NONE return icb_disjoint_or(r, x);
    }
    ok, x, y = pm_disjoint_or(lhs);
    if ok && has_one_use(lhs) {
        r := ic_fold_disjoint_or(x, rhs); if r != NONE return icb_disjoint_or(r, y);
        r = ic_fold_disjoint_or(y, rhs); if r != NONE return icb_disjoint_or(r, x);
    }
    return NONE;
}

// m_ExtractValue<Idx>(m_Value(V)) (instructions with one index)
pm_extract_value_idx :: (v: Value_Id, idx: u32) -> (bool, Value_Id) {
    if !is_inst(v) || inst_op(v) != .EXTRACTVALUE return false, NONE;
    r := inst(v);
    if r.nidx != 1 || ir.u32_pool[r.idx] != idx return false, NONE;
    return true, op(v, 0);
}

// foldOrUnsignedUMulOverflowICmp
ic_fold_or_unsigned_umul_overflow_icmp :: (i: Value_Id) -> Value_Id {
    for side: 0..1 {
        e1 := op(i, cast(u32) side); c := op(i, cast(u32) (1 - side));
        ok1, wov := pm_extract_value_idx(e1, 1);
        if !ok1 continue;
        okw, x, c1v := pm_intrinsic2(wov, IID_UMUL_WITH_OVERFLOW);
        okc1, c1 := pm_apint(c1v);
        if !okw || !okc1 continue;
        if !has_one_use(c) continue;
        okc, l, r := pm_specific_icmp(c, ICMP_UGT);
        if !okc continue;
        ok0, w0 := pm_extract_value_idx(l, 0);
        okc2, c2 := pm_apint(r);
        if !ok0 || w0 != wov || !okc2 continue;
        if ap_is_zero(c1) return NONE;
        return icb_cmp(ICMP_UGT, x, const_int_ap(vtype(x), ap_udiv(c2, c1)));
    }
    return NONE;
}

// m_SMax / m_SMin / m_UMax / m_UMin (MaxMin_match): the intrinsic or the select-of-icmp form; (ok, a, b)
pm_max_min :: (v: Value_Id, id: Intrinsic_Id) -> (bool, Value_Id, Value_Id) {
    if call_iid(v) != NOT_INTRINSIC {
        if call_iid(v) == id && inst_op(v) == .CALL return true, op(v, 0), op(v, 1);
        return false, NONE, NONE;
    }
    oks, cond, tv, fv := pm_select(v);
    if !oks || !ic_is_icmp(cond) return false, NONE, NONE;
    l := op(cond, 0); r := op(cond, 1);
    if (tv != l || fv != r) && (tv != r || fv != l) return false, NONE, NONE;
    pred := ifx tv == l then inst_pred(cond) else cmp_inverse(inst_pred(cond));
    ok := false;
    if id == IID_SMAX ok = pred == ICMP_SGT || pred == ICMP_SGE;
    else if id == IID_SMIN ok = pred == ICMP_SLT || pred == ICMP_SLE;
    else if id == IID_UMAX ok = pred == ICMP_UGT || pred == ICMP_UGE;
    else if id == IID_UMIN ok = pred == ICMP_ULT || pred == ICMP_ULE;
    if !ok return false, NONE, NONE;
    return true, l, r;
}

// FoldOrOfSelectSmaxToAbs
ic_fold_or_of_select_smax_to_abs :: (i: Value_Id) -> Value_Id {
    for side: 0..1 {
        sel := op(i, cast(u32) side); mm := op(i, cast(u32) (1 - side));
        if !has_one_use(mm) continue;
        okm, x, z := pm_max_min(mm, IID_SMAX);
        if !okm || !pm_zero_int(z) continue;
        is_neg_x :: (v: Value_Id, x: Value_Id) -> bool { ok, n := pm_neg(v); return ok && n == x; }
        oks, cond, tv, fv := pm_select(sel);
        if oks {
            okc, cl, cr := pm_specific_icmp(cond, ICMP_SGT);
            if okc && cl == x && pm_zero_int(cr) && pm_zero_int(tv) && is_neg_x(fv, x)
                return icb_binary_intrinsic(IID_ABS, x, const_false());
            okc, cl, cr = pm_specific_icmp(cond, ICMP_SLT);
            if okc && cl == x && pm_zero_int(cr) && is_neg_x(tv, x) && pm_zero_int(fv)
                return icb_binary_intrinsic(IID_ABS, x, const_false());
        }
        return NONE;
    }
    return NONE;
}

// SelectInst::Create(C, T, F, "", nullptr, MDFrom)
ic_create_select_md_from :: (c: Value_Id, t: Value_Id, f: Value_Id, md_from: Value_Id) -> Value_Id {
    s := create_select(c, t, f);
    if md_from != NONE copy_metadata(s, md_from);
    return s;
}

// FoldOrOfLogicalAnds
ic_fold_or_of_logical_ands :: (op0: Value_Id, op1: Value_Id) -> Value_Id {
    // m_c_LogicalAnd(m_Not(m_Value(C)), m_Value(B)): (ok, C, B)
    match_not_and :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
        ok, a, b := pm_logical_and(v);
        if !ok return false, NONE, NONE;
        okn, c := pm_not(a); if okn return true, c, b;
        okn, c = pm_not(b); if okn return true, c, a;
        return false, NONE, NONE;
    }
    // m_c_LogicalAnd(m_Specific(C), m_Value(A))
    match_spec_and :: (v: Value_Id, c: Value_Id) -> (bool, Value_Id) {
        ok, a, b := pm_logical_and(v);
        if !ok return false, NONE;
        if a == c return true, b;
        if b == c return true, a;
        return false, NONE;
    }
    is_sel :: (v: Value_Id) -> bool { return ic_is_binop(v, .SELECT); }
    {
        ok1, c, b := match_not_and(op1);
        if ok1 {
            ok0, a := match_spec_and(op0, c);
            if ok0 {
                sel0 := is_sel(op0); sel1 := is_sel(op1);
                may_need_freeze := false;
                if sel0 && sel1 { okn, nt := pm_not(op(op1, 1)); may_need_freeze = okn && nt == op(op0, 1); }
                if may_need_freeze c = icb_freeze(c);
                okl, l0, _ := pm_logical_and(op0);
                if okl && l0 == c && sel0 return ic_create_select_md_from(c, a, b, op0);
                okl1, l1, _ := pm_logical_and(op1);
                okn1, _ := pm_not(l1);
                if okl1 && okn1 && sel1 {
                    ns := ic_create_select_md_from(c, a, b, op1);
                    swap_prof_metadata(ns);
                    return ns;
                }
                return ic_create_select_unknown_profile(c, a, b);
            }
        }
    }
    {
        ok0, c, a := match_not_and(op0);
        if ok0 {
            ok1, b := match_spec_and(op1, c);
            if ok1 {
                sel0 := is_sel(op0); sel1 := is_sel(op1);
                may_need_freeze := false;
                if sel0 && sel1 { okn, nt := pm_not(op(op0, 1)); may_need_freeze = okn && nt == op(op1, 1); }
                if may_need_freeze c = icb_freeze(c);
                okl0, l0, _ := pm_logical_and(op0);
                okn0, _ := pm_not(l0);
                if okl0 && okn0 && sel0 {
                    ns := ic_create_select_md_from(c, b, a, op0);
                    swap_prof_metadata(ns);
                    return ns;
                }
                okl1, l1, _ := pm_logical_and(op1);
                if okl1 && l1 == c && sel1 return ic_create_select_md_from(c, b, a, op1);
                return ic_create_select_unknown_profile(c, b, a);
            }
        }
    }
    return NONE;
}

// ---------------------------------------------------------------- visitAnd

ic_visit_and :: (i: Value_Id) -> Value_Id {
    ty := vtype(i);
    v := simplify_and_inst(op(i, 0), op(i, 1), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if ic_simplify_associative_or_commutative(i) return i;
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_fold_binop_with_phi_operands(i); if r != NONE return r;
    if ic_simplify_demanded_instruction_bits(i) return i;
    r = ic_fold_and_to_xor(i); if r != NONE return r;
    r = ic_fold_complex_and_or_patterns(i); if r != NONE return r;
    v = ic_fold_using_distributive_laws(i);
    if v != NONE return ic_replace_inst_uses_with(i, v);
    r = ic_fold_binop_shift_with_shift(i); if r != NONE return r;

    op0 := op(i, 0); op1 := op(i, 1);
    x, y: Value_Id = NONE;

    // (1 >> X) & 1 --> zext(X == 0); (C << X) & 1 --> zext(X == 0), when C is odd
    if pm_one(op1) && has_one_use(op0) {
        matched := false;
        if is_binary_operator(op0) && (inst_op(op0) == .SHL || inst_op(op0) == .LSHR) && pm_one(op(op0, 0)) { x = op(op0, 1); matched = true; }
        if !matched {
            ok, cv, sx := pm_binop(op0, .SHL);
            okc, c := pm_apint(cv);
            if ok && okc && ap_bit(c, 0) { x = sx; matched = true; }
        }
        if matched {
            is_zero := icb_cmp(ICMP_EQ, x, const_int_of(ty, 0));
            return create_cast(.ZEXT, is_zero, ty);
        }
    }

    // (-(X & 1)) & Y --> (X & 1) == 0 ? 0 : Y
    for side: 0..1 {
        neg := op(i, cast(u32) side);
        if !has_one_use(neg) continue;
        okn, a := pm_neg(neg);
        if !okn continue;
        oka, _, one := pm_binop(a, .AND);
        if !oka || !pm_one(one) continue;
        yv := op(i, cast(u32) (1 - side));
        cmp := icb_is_null(neg);
        return ic_create_select_unknown_profile(cmp, const_null_value(ty), yv);
    }

    // (X +/- Y) & Y --> ~X & Y when Y is a power of 2.
    for side: 0..1 {
        yv := op(i, cast(u32) side);
        o := op(i, cast(u32) (1 - side));
        if !has_one_use(o) continue;
        xv: Value_Id = NONE;
        oka, ax := pm_c_binop_with(o, .ADD, yv);
        if oka xv = ax;
        else { oks, sx, sy := pm_binop(o, .SUB); if oks && sy == yv xv = sx; }
        if xv == NONE continue;
        if ic_is_known_to_be_power_of_two(yv, true, i) return create_binop(.AND, icb_not(xv), yv);
        break;   // m_c_And bound Y on the first matching order
    }

    okc, c := pm_apint(op1);
    if okc {
        {
            ok, xv, xcv := pm_binop(op0, .XOR);
            okx, xor_c := pm_apint(xcv);
            if ok && has_one_use(op0) && okx {
                new_c := const_int_ap(ty, ap_and(c, xor_c));
                a := icb_and(xv, op1);
                ic_take_name(a, op0);
                return create_binop(.XOR, a, new_c);
            }
        }
        {
            ok, xv, ocv := pm_binop(op0, .OR);
            oko, or_c := pm_apint(ocv);
            if ok && has_one_use(op0) && oko {
                together := ap_and(c, or_c);
                a := icb_and(xv, const_int_ap(ty, ap_xor(together, c)));
                ic_take_name(a, op0);
                return create_binop(.OR, a, const_int_ap(ty, together));
            }
        }
        width := type_int_width(scalar_type(ty));
        {
            oks, sa := pmi_cast(op0, .SEXT);
            if oks && has_one_use(op0) {
                ok, xv, scv := pm_binop(sa, .ASHR);
                okc2, shift_c := pm_apint(scv);
                if ok && okc2 && ap_ult_u64(shift_c, width) {
                    if ap_eq(c, ap_low_bits_set(width, width - cast(u32) ap_zext_value(shift_c))) {
                        sext := icb_sext(xv, ty);
                        sh := const_int_ap(ty, ap_zext(shift_c, width));
                        return create_binop(.LSHR, sext, sh);
                    }
                }
            }
        }
        {
            ok, xv, scv := pm_binop(op0, .ASHR);
            okc2, shift_c := pm_apint(scv);
            if ok && okc2 && ap_ult_u64(shift_c, width) && ap_is_mask_n(c, width - cast(u32) ap_zext_value(shift_c))
                return create_binop(.LSHR, xv, const_int_ap(ty, shift_c));
        }
        {
            ok, xv, acv := pm_binop(op0, .ADD);
            oka, add_c := pm_apint(acv);
            if ok && oka {
                if has_one_use(op0) && ap_is_power_of_2(c) && ap_is_zero(ap_and(add_c, ap_sub_u64(c, 1))) {
                    new_and := icb_and(xv, op1);
                    return create_binop(.XOR, new_and, op1);
                }
            }
        }
        if is_binary_operator(op0) && has_one_use(op0) {
            bo := op0;
            bopc := inst_op(bo);
            if bopc == .XOR || bopc == .OR || bopc == .MUL || bopc == .ADD || bopc == .SUB {
                // m_c_BinOp(m_OneUse(m_ZExt(m_Value(X))), m_APInt(C1))
                xv: Value_Id = NONE; c1: APInt; found := false;
                for side: 0..1 {
                    z := op(bo, cast(u32) side);
                    okz, zx := pmi_cast(z, .ZEXT);
                    okc1, cc1 := pm_apint(op(bo, cast(u32) (1 - side)));
                    if okz && has_one_use(z) && okc1 { xv = zx; c1 = cc1; found = true; break; }
                }
                if found && ap_active_bits(c) <= scalar_bits(xv) {
                    xw := scalar_bits(xv);
                    trunc_c1 := const_int_ap(vtype(xv), ap_trunc(c1, xw));
                    bin := ifx is_inst(op(bo, 0)) && inst_op(op(bo, 0)) == .ZEXT then icb_binop(bopc, xv, trunc_c1) else icb_binop(bopc, trunc_c1, xv);
                    trunc_c := const_int_ap(vtype(xv), ap_trunc(c, xw));
                    a := icb_and(bin, trunc_c);
                    return create_cast(.ZEXT, a, ty);
                }
                o0 := op(bo, 0);
                if is_inst(o0) {
                    okz, zx := pmi_cast(o0, .ZEXT);
                    if okz && has_one_use(o0) && ap_is_mask_n(c, scalar_bits(zx)) {
                        yv := op(bo, 1);
                        tr_y := icb_trunc(yv, vtype(zx), tprint("%.tr", vname(yv)));
                        nbo := icb_binop(bopc, zx, tr_y, tprint("%.narrow", vname(bo)));
                        return create_cast(.ZEXT, nbo, ty);
                    }
                }
                o1 := op(bo, 1);
                if is_inst(o1) {
                    okz, zx := pmi_cast(o1, .ZEXT);
                    if okz && has_one_use(o1) && ap_is_mask_n(c, scalar_bits(zx)) {
                        yv := op(bo, 0);
                        tr_y := icb_trunc(yv, vtype(zx), tprint("%.tr", vname(yv)));
                        nbo := icb_binop(bopc, tr_y, zx, tprint("%.narrow", vname(bo)));
                        return create_cast(.ZEXT, nbo, ty);
                    }
                }
            }
        }
        if (ic_is_binop(op0, .XOR) || ic_is_binop(op0, .OR)) && has_one_use(op0) {
            xv := op(op0, 0); yv := op(op0, 1);
            not_and_mask := ap_not(c);
            bin_op := inst_op(op0);
            if ic_masked_value_is_zero(xv, not_and_mask, i) {
                new_rhs := icb_and(yv, op1, tprint("%.masked", vname(yv)));
                return create_binop(bin_op, xv, new_rhs);
            }
            if !is_const(yv) && ic_masked_value_is_zero(yv, not_and_mask, i) {
                new_lhs := icb_and(xv, op1, tprint("%.masked", vname(xv)));
                return create_binop(bin_op, new_lhs, yv);
            }
        }
        if ap_is_power_of_2(c) && has_one_use(op0) && is_binary_operator(op0) && (inst_op(op0) == .SHL || inst_op(op0) == .LSHR) {
            oksc, shift_c := pm_power2_ap(op(op0, 0));
            if oksc {
                xv := op(op0, 1);
                log2_shift_c := ap_exact_log2(shift_c);
                log2_c := ap_exact_log2(c);
                is_shift_left := inst_op(op0) == .SHL;
                bit_num := ifx is_shift_left then log2_c - log2_shift_c else log2_shift_c - log2_c;
                cmp := icb_cmp(ICMP_EQ, xv, const_int_of(ty, cast(u64) bit_num));
                return ic_create_select_unknown_profile(cmp, const_int_ap(ty, c), const_null_value(ty));
            }
        }
        c3 := c;
        if ap_is_power_of_2(c3) {
            log2_c3 := const_int_of(ty, cast(u64) ap_ctz(c3));
            {
                ok, shl, c2 := pm_binop(op0, .LSHR);
                if ok && has_one_use(op0) && pm_imm_constant(c2) {
                    oks, c1, xv := pm_binop(shl, .SHL);
                    if oks && pm_imm_constant(c1) && pm_power2(c1) {
                        log2_c1 := ce_exact_log_base2(c1);
                        lshr_c := ce_binop(.ADD, c2, log2_c3, 0);
                        known_lshrc := known_bits(lshr_c, ic.sq);
                        if ap_ult_u64(kb_max_value(known_lshrc), width) {
                            cmp_c := ce_binop(.SUB, lshr_c, log2_c1, 0);
                            cmp := icb_cmp(ICMP_EQ, xv, cmp_c);
                            return ic_create_select_unknown_profile(cmp, const_int_ap(ty, c3), const_null_value(ty));
                        }
                    }
                }
            }
            {
                ok, lshr, c2 := pm_binop(op0, .SHL);
                if ok && has_one_use(op0) && pm_imm_constant(c2) {
                    okl, c1, xv := pm_binop(lshr, .LSHR);
                    if okl && pm_imm_constant(c1) && pm_power2(c1) {
                        log2_c1 := ce_exact_log_base2(c1);
                        cmp0 := cfo_compare_inst_operands(ICMP_ULT, log2_c3, c2);
                        if cmp0 != NONE && is_null_value(cmp0) {
                            shl_c := ce_binop(.ADD, c2, log2_c1, 0);
                            cmp_c := ce_binop(.SUB, shl_c, log2_c3, 0);
                            cmp := icb_cmp(ICMP_EQ, xv, cmp_c);
                            return ic_create_select_unknown_profile(cmp, const_int_ap(ty, c3), const_null_value(ty));
                        }
                    }
                }
            }
        }
    }

    // clearing the sign bit of a floating-point value --> fabs
    {
        okb, cast_op := pm_elementwise_bitcast(op0);
        if okb && pm_max_signed_value(op1) && !fn_has_fn_attr(ic.f, .NoImplicitFloat) {
            et := scalar_type(vtype(cast_op));
            if is_fp_kind(type_kind(et)) {
                fabs := icb_unary_intrinsic(IID_FABS, cast_op);
                return create_cast(.BITCAST, fabs, ty);
            }
        }
    }

    // and(shl(zext(X), Y), SignMask) -> and(sext(X), SignMask)
    {
        ok, z, yv := pm_binop(op0, .SHL);
        if ok && has_one_use(op0) && pm_sign_mask(op1) {
            okz, xv := pmi_cast(z, .ZEXT);
            if okz {
                eq :: (a: APInt, b: APInt) -> bool { return ap_eq(a, b); }
                bw := type_int_width(scalar_type(ty));
                if pm_int_pred_arg(yv, eq, ap_from_u64(bw, cast(u64) (bw - scalar_bits(xv)))) {
                    sext := icb_sext(xv, ty, tprint("%.signext", vname(xv)));
                    return create_binop(.AND, sext, op1);
                }
            }
        }
    }

    r = ic_narrow_masked_bin_op(i); if r != NONE return r;

    if is_int_or_int_vector_n(ty, 1) {
        if ic_is_binop(op0, .SELECT) {
            r = ic_fold_and_or_of_select_using_implied_cond(op1, op0, true); if r != NONE return r;
        }
        if ic_is_binop(op1, .SELECT) {
            r = ic_fold_and_or_of_select_using_implied_cond(op0, op1, true); if r != NONE return r;
        }
    }

    r = ic_fold_binop_into_select_or_phi(i); if r != NONE return r;
    r = ic_match_de_morgans_laws(i); if r != NONE return r;

    {
        // A & ~(A ^ B) --> A & B
        okn, n := pm_not(op1);
        if okn { okx, b := pm_c_binop_with(n, .XOR, op0); if okx return create_binop(.AND, op0, b); }
        // ~(A ^ B) & A --> A & B
        okn, n = pm_not(op0);
        if okn { okx, b := pm_c_binop_with(n, .XOR, op1); if okx return create_binop(.AND, op1, b); }

        // (A ^ B) & ((B ^ C) ^ A) -> (A ^ B) & ~C
        {
            ok, a, b := pm_binop(op0, .XOR);
            ok1, inner, a2 := pm_binop(op1, .XOR);
            if ok && ok1 && a2 == a {
                oki, b2, cc := pm_binop(inner, .XOR);
                if oki && b2 == b {
                    not_c := ifx has_one_use(op1) then icb_not(cc) else ic_get_freely_inverted(cc, has_one_use(cc), true);
                    if not_c != NONE return create_binop(.AND, op0, not_c);
                }
            }
        }
        // ((A ^ C) ^ B) & (B ^ A) -> (B ^ A) & ~C
        {
            ok, inner, b := pm_binop(op0, .XOR);
            if ok {
                oki, a, cc := pm_binop(inner, .XOR);
                ok1, b2, a2 := pm_binop(op1, .XOR);
                if oki && ok1 && b2 == b && a2 == a {
                    not_c := ifx has_one_use(op0) then icb_not(cc) else ic_get_freely_inverted(cc, has_one_use(cc), true);
                    if not_c != NONE return create_binop(.AND, op1, not_c);
                }
            }
        }
        // m_c_Xor(m_Not(m_Value(A)), m_Value(B)): (ok, A, B)
        c_xor_not :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
            if !ic_is_binop(v, .XOR) return false, NONE, NONE;
            okn, a := pm_not(op(v, 0)); if okn return true, a, op(v, 1);
            okn, a = pm_not(op(v, 1)); if okn return true, a, op(v, 0);
            return false, NONE, NONE;
        }
        c_or_not :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
            if !ic_is_binop(v, .OR) return false, NONE, NONE;
            okn, a := pm_not(op(v, 0)); if okn return true, a, op(v, 1);
            okn, a = pm_not(op(v, 1)); if okn return true, a, op(v, 0);
            return false, NONE, NONE;
        }
        {
            ok, a, b := c_xor_not(op1);
            if ok && ic_is_c_binop_of(op0, .OR, a, b) return create_binop(.AND, a, b);
        }
        {
            ok, a, b := c_xor_not(op0);
            if ok && ic_is_c_binop_of(op1, .OR, a, b) return create_binop(.AND, a, b);
        }
        {
            ok, a, b := c_or_not(op0);
            if ok && ic_is_c_binop_of(op1, .XOR, a, b) return create_binop(.AND, icb_not(a), b);
        }
        {
            ok, a, b := c_or_not(op1);
            if ok && ic_is_c_binop_of(op0, .XOR, a, b) return create_binop(.AND, icb_not(a), b);
        }
    }

    v = ic_fold_boolean_and_or(op0, op1, i, true, false);
    if v != NONE return ic_replace_inst_uses_with(i, v);

    if has_one_use(op1) {
        ok, lx, ly := pm_logical_and(op1);
        if ok {
            is_logical := ic_is_binop(op1, .SELECT);
            v = ic_reassociate_boolean_and_or(op0, lx, ly, i, true, is_logical);
            if v != NONE return ic_replace_inst_uses_with(i, v);
        }
    }
    if has_one_use(op0) {
        ok, lx, ly := pm_logical_and(op0);
        if ok {
            is_logical := ic_is_binop(op0, .SELECT);
            v = ic_reassociate_boolean_and_or(op1, lx, ly, i, true, is_logical);
            if v != NONE return ic_replace_inst_uses_with(i, v);
        }
    }

    r = ic_reassociate_fcmps(i); if r != NONE return r;
    r = ic_fold_casted_bitwise_logic(i); if r != NONE return r;
    r = ic_fold_binop_of_sext_bool_to_select(i); if r != NONE return r;

    // and(sext(A), B) / and(B, sext(A)) --> A ? B : 0
    for side: 0..1 {
        oks, a := pmi_cast(op(i, cast(u32) side), .SEXT);
        if !oks continue;
        if is_int_or_int_vector_n(vtype(a), 1) return ic_create_select_unknown_profile(a, op(i, cast(u32) (1 - side)), const_null_value(ty));
        break;
    }
    // ~sext(A) & B --> A ? 0 : B
    for side: 0..1 {
        okn, s := pm_not(op(i, cast(u32) side));
        if !okn continue;
        oks, a := pmi_cast(s, .SEXT);
        if !oks continue;
        if is_int_or_int_vector_n(vtype(a), 1) return ic_create_select_unknown_profile(a, const_null_value(ty), op(i, cast(u32) (1 - side)));
        break;
    }
    // and(zext(A), B) -> A ? (B & 1) : 0
    for side: 0..1 {
        z := op(i, cast(u32) side);
        okz, a := pmi_cast(z, .ZEXT);
        if !okz || !has_one_use(z) continue;
        b := op(i, cast(u32) (1 - side));
        if is_int_or_int_vector_n(vtype(a), 1)
            return ic_create_select_unknown_profile(a, icb_and(b, const_int_of(ty, 1)), const_null_value(ty));
        break;
    }
    // (-1 + A) & B --> A ? 0 : B where A is 0/1.
    for side: 0..1 {
        ad := op(i, cast(u32) side);
        if !has_one_use(ad) continue;
        oka, za, m1 := pm_binop(ad, .ADD);
        if !oka || !pm_all_ones(m1) continue;
        a := zext_or_self_i(za);
        b := op(i, cast(u32) (1 - side));
        if is_int_or_int_vector_n(vtype(a), 1) return ic_create_select_unknown_profile(a, const_null_value(ty), b);
        if kb_count_max_active_bits(ic_known_bits(a, i)) <= 1
            return ic_create_select_unknown_profile(icb_cmp(ICMP_EQ, a, const_null_value(vtype(a))), b, const_null_value(ty));
        break;
    }
    // (iN X s>> (N-1)) & Y --> (X s< 0) ? Y : 0 -- with optional sext
    for side: 0..1 {
        s := op(i, cast(u32) side);
        if !has_one_use(s) continue;
        sh := sext_or_self_i(s);
        ok, xv, cv := pm_binop(sh, .ASHR);
        okc2, c2 := pm_apint_ap(cv);
        if !ok || !okc2 continue;
        yv := op(i, cast(u32) (1 - side));
        if ap_eq_u64(c2, cast(u64) scalar_bits(xv) - 1) {
            is_neg := icb_cmp(ICMP_SLT, xv, const_null_value(vtype(xv)), "isneg");
            return ic_create_select_unknown_profile(is_neg, yv, const_null_value(ty));
        }
        break;
    }
    // ~(iN X s>> (N-1)) & Y --> (X s< 0) ? 0 : Y -- with optional sext
    for side: 0..1 {
        s := op(i, cast(u32) side);
        if !has_one_use(s) continue;
        okn, sh := pm_not(sext_or_self_i(s));
        if !okn continue;
        ok, xv, cv := pm_binop(sh, .ASHR);
        okc2, c2 := pm_apint_ap(cv);
        if !ok || !okc2 continue;
        yv := op(i, cast(u32) (1 - side));
        if ap_eq_u64(c2, cast(u64) scalar_bits(xv) - 1) {
            is_neg := icb_cmp(ICMP_SLT, xv, const_null_value(vtype(xv)), "isneg");
            return ic_create_select_unknown_profile(is_neg, const_null_value(ty), yv);
        }
        break;
    }

    if ic_sink_not_into_other_hand_of_logical_op(i) return i;

    {
        okr, pn, start, step := match_simple_recurrence_bo(i);
        if okr && dt_dominates_inst(ic.dt, step, pn) return ic_replace_inst_uses_with(i, icb_and(start, step));
    }

    r = ic_reassociate_for_uses(i); if r != NONE return r;
    r = ic_canonicalize_logic_first(i); if r != NONE return r;
    r = ic_fold_logic_of_is_fp_class(i, op0, op1); if r != NONE return r;
    r = ic_fold_binop_of_displaced_shifts(i); if r != NONE return r;
    r = ic_fold_bitwise_logic_with_intrinsics(i); if r != NONE return r;

    v = ic_simplify_and_or_with_op_replaced(op0, op1, const_all_ones_of(ty), false);
    if v != NONE return create_binop(.AND, v, op1);
    v = ic_simplify_and_or_with_op_replaced(op1, op0, const_all_ones_of(ty), false);
    if v != NONE return create_binop(.AND, op0, v);
    return NONE;
}

// ---------------------------------------------------------------- visitOr

ic_visit_or :: (i: Value_Id) -> Value_Id {
    v := simplify_or_inst(op(i, 0), op(i, 1), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if ic_simplify_associative_or_commutative(i) return i;
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_fold_binop_with_phi_operands(i); if r != NONE return r;
    if ic_simplify_demanded_instruction_bits(i) return i;
    r = ic_fold_or_to_xor(i); if r != NONE return r;
    r = ic_fold_complex_and_or_patterns(i); if r != NONE return r;
    r = ic_fold_integer_pack_from_vector(i); if r != NONE return r;
    v = ic_fold_or_of_inversions(i);
    if v != NONE return ic_replace_inst_uses_with(i, v);
    v = ic_fold_using_distributive_laws(i);
    if v != NONE return ic_replace_inst_uses_with(i, v);

    op0 := op(i, 0); op1 := op(i, 1);
    ty := vtype(i);
    if is_int_or_int_vector_n(ty, 1) {
        if ic_is_binop(op0, .SELECT) { r = ic_fold_and_or_of_select_using_implied_cond(op1, op0, false); if r != NONE return r; }
        if ic_is_binop(op1, .SELECT) { r = ic_fold_and_or_of_select_using_implied_cond(op0, op1, false); if r != NONE return r; }
    }
    r = ic_fold_binop_into_select_or_phi(i); if r != NONE return r;
    r = ic_fold_binop_select_binop(i); if r != NONE return r;
    r = ic_match_bswap_or_bit_reverse(i, true, true); if r != NONE return r;
    r = ic_match_funnel_shift(i); if r != NONE return r;
    v = ic_match_or_concat(i);
    if v != NONE return ic_replace_inst_uses_with(i, v);
    r = ic_fold_binop_shift_with_shift(i); if r != NONE return r;
    r = ic_try_fold_inst_with_ctpop_with_not(i); if r != NONE return r;

    if ic_is_disjoint(i) {
        r = ic_fold_add_like_commutative(op(i, 0), op(i, 1), true, true); if r != NONE return r;
        r = ic_fold_add_like_commutative(op(i, 1), op(i, 0), true, true); if r != NONE return r;
        v = ic_fold_disjoint_or(op(i, 0), op(i, 1));
        if v != NONE return ic_replace_inst_uses_with(i, v);
        v = ic_reassociate_disjoint_or(op(i, 0), op(i, 1));
        if v != NONE return ic_replace_inst_uses_with(i, v);
    }

    // (X ^ C) | Y -> (X | Y) ^ C iff Y & C == 0
    for side: 0..1 {
        xr := op(i, cast(u32) side);
        if !has_one_use(xr) continue;
        ok, x, cvv := pm_binop(xr, .XOR);
        okc, cv := pm_apint(cvv);
        if !ok || !okc continue;
        y := op(i, cast(u32) (1 - side));
        if !ap_is_all_ones(cv) && ic_masked_value_is_zero(y, cv, i) {
            orv := icb_or(x, y);
            return create_binop(.XOR, orv, const_int_ap(ty, cv));
        }
        break;
    }

    // or disjoint (mul X, Y), X --> mul X, (Y + 1)
    if ic_is_disjoint(i) {
        for side: 0..1 {
            m := op(i, cast(u32) side);
            ok, x, y := pm_binop(m, .MUL);
            if ok && has_one_use(m) && op(i, cast(u32) (1 - side)) == x {
                inc := icb_add(y, const_int_of(ty, 1));
                return create_binop(.MUL, x, inc);
            }
        }
    }

    // ~X | (X-1) => ~(X & -X)
    for side: 0..1 {
        n := op(i, cast(u32) side); a := op(i, cast(u32) (1 - side));
        if !has_one_use(n) continue;
        okn, opv := pm_not(n);
        if !okn continue;
        oka, ax, m1 := pm_binop(a, .ADD);
        if oka && has_one_use(a) && ax == opv && pm_all_ones(m1) {
            neg_x := icb_neg(opv);
            andv := icb_and(opv, neg_x);
            return create_not(andv);
        }
    }

    if is_int_or_int_vector_n(ty, 1) && (has_one_use(op0) || has_one_use(op1)) {
        r = ic_fold_or_of_logical_ands(op0, op1); if r != NONE return r;
    }

    // (A & C) | (B & D)
    {
        ok0, a, c := pm_binop(op0, .AND);
        ok1, b, d := pm_binop(op1, .AND);
        if ok0 && ok1 {
            okc0, c0 := pm_apint(c);
            okc1, c1 := pm_apint(d);
            if okc0 && okc1 {
                if ap_eq(c0, ap_not(c1)) {
                    okx, x := pm_c_binop_with(a, .OR, b);
                    if okx return create_binop(.OR, icb_and(x, const_int_ap(vtype(x), c0)), b);
                    okx, x = pm_c_binop_with(b, .OR, a);
                    if okx return create_binop(.OR, icb_and(x, const_int_ap(vtype(x), c1)), a);
                    okx, x = pm_c_binop_with(a, .XOR, b);
                    if okx return create_binop(.XOR, icb_and(x, const_int_ap(vtype(x), c0)), b);
                    okx, x = pm_c_binop_with(b, .XOR, a);
                    if okx return create_binop(.XOR, icb_and(x, const_int_ap(vtype(x), c1)), a);
                }
                if ap_is_zero(ap_and(c0, c1)) {
                    okx, x := pm_c_binop_with(a, .OR, b);
                    if okx && ic_masked_value_is_zero(x, ap_not(c0), i) return create_binop(.AND, a, const_int_ap(ty, ap_or(c0, c1)));
                    okx, x = pm_c_binop_with(b, .OR, a);
                    if okx && ic_masked_value_is_zero(x, ap_not(c1), i) return create_binop(.AND, b, const_int_ap(ty, ap_or(c0, c1)));
                    oka, ax, c2v := pm_binop(a, .OR);
                    okc2, c2 := pm_apint(c2v);
                    if oka && okc2 {
                        okb, bx, c3v := pm_binop(b, .OR);
                        okc3, c3 := pm_apint(c3v);
                        if okb && bx == ax && okc3 && ap_is_zero(ap_and(c2, ap_not(c0))) && ap_is_zero(ap_and(c3, ap_not(c1))) {
                            orv := icb_or(ax, const_int_ap(vtype(ax), ap_or(c2, c3)), "bitfield");
                            return create_binop(.AND, orv, const_int_ap(ty, ap_or(c0, c1)));
                        }
                    }
                }
            }
            if has_one_use(op0) || has_one_use(op1) {
                v = ic_match_select_from_and_or(a, c, b, d); if v != NONE return ic_replace_inst_uses_with(i, v);
                v = ic_match_select_from_and_or(a, c, d, b); if v != NONE return ic_replace_inst_uses_with(i, v);
                v = ic_match_select_from_and_or(c, a, b, d); if v != NONE return ic_replace_inst_uses_with(i, v);
                v = ic_match_select_from_and_or(c, a, d, b); if v != NONE return ic_replace_inst_uses_with(i, v);
                v = ic_match_select_from_and_or(b, d, a, c); if v != NONE return ic_replace_inst_uses_with(i, v);
                v = ic_match_select_from_and_or(b, d, c, a); if v != NONE return ic_replace_inst_uses_with(i, v);
                v = ic_match_select_from_and_or(d, b, a, c); if v != NONE return ic_replace_inst_uses_with(i, v);
                v = ic_match_select_from_and_or(d, b, c, a); if v != NONE return ic_replace_inst_uses_with(i, v);
            }
        }
    }
    {
        ok0, a, c := pm_binop(op0, .AND);
        okn, n := pm_not(op1);
        if ok0 && okn {
            ok1, b, d := pm_binop(n, .OR);
            if ok1 && (has_one_use(op0) || has_one_use(op1)) {
                v = ic_match_select_from_and_or(a, c, b, d, true); if v != NONE return ic_replace_inst_uses_with(i, v);
                v = ic_match_select_from_and_or(a, c, d, b, true); if v != NONE return ic_replace_inst_uses_with(i, v);
                v = ic_match_select_from_and_or(c, a, b, d, true); if v != NONE return ic_replace_inst_uses_with(i, v);
                v = ic_match_select_from_and_or(c, a, d, b, true); if v != NONE return ic_replace_inst_uses_with(i, v);
            }
        }
    }

    // m_c_Xor(m_c_Xor(m_Specific(P), m_Value(C)), m_Specific(Q)): C or NONE
    c_xor_xor :: (v: Value_Id, p: Value_Id, q: Value_Id) -> Value_Id {
        if !ic_is_binop(v, .XOR) return NONE;
        for side: 0..1 {
            inner := op(v, cast(u32) side);
            if op(v, cast(u32) (1 - side)) != q continue;
            ok, c := pm_c_binop_with(inner, .XOR, p);
            if ok return c;
        }
        return NONE;
    }
    {
        ok, a, b := pm_binop(op0, .XOR);
        if ok {
            c := c_xor_xor(op1, b, a);
            if c == NONE c = c_xor_xor(op1, a, b);
            if c != NONE return create_binop(.OR, op0, c);
        }
    }
    {
        ok, a, b := pm_binop(op1, .XOR);
        if ok {
            c := c_xor_xor(op0, b, a);
            if c == NONE c = c_xor_xor(op0, a, b);
            if c != NONE return create_binop(.OR, op1, c);
        }
    }

    r = ic_match_de_morgans_laws(i); if r != NONE return r;

    swapped_for_xor := false;
    if ic_is_binop(op0, .XOR) { t := op0; op0 = op1; op1 = t; swapped_for_xor = true; }
    {
        ok, a, b := pm_binop(op1, .XOR);
        if ok {
            if ic_is_binop(op0, .OR) && (op(op0, 0) == a || op(op0, 1) == a) return create_binop(.OR, op0, b);
            if ic_is_binop(op0, .OR) && (op(op0, 0) == b || op(op0, 1) == b) return create_binop(.OR, op0, a);
            if ic_is_c_binop_of(op0, .AND, a, b) return create_binop(.OR, a, b);
            if has_one_use(op0) || has_one_use(op1) {
                okn, na := pm_not(op0);
                if okn && (na == a || na == b) return create_not(icb_and(a, b));
            }
            if has_one_use(op0) || has_one_use(op1) {
                okn, an := pm_not(op0);
                if okn && ic_is_binop(an, .AND) && (op(an, 0) == a || op(an, 1) == a) return create_not(icb_and(an, b));
                if okn && ic_is_binop(an, .AND) && (op(an, 0) == b || op(an, 1) == b) return create_not(icb_and(an, a));
            }
            if has_one_use(op0) && has_one_use(op1) && ic_is_binop(op0, .OR) {
                // m_c_Or(m_Not(m_Specific(A)), m_Value(C)) || m_c_Or(m_Not(m_Specific(B)), m_Value(C))
                c: Value_Id = NONE;
                for target: Value_Id.[a, b] {
                    for side: 0..1 {
                        okn, nn := pm_not(op(op0, cast(u32) side));
                        if okn && nn == target { c = op(op0, cast(u32) (1 - side)); break; }
                    }
                    if c != NONE break;
                }
                if c != NONE {
                    nand := icb_not(icb_and(a, b), "nand");
                    return create_binop(.OR, nand, c);
                }
            }
        }
    }
    if swapped_for_xor { t := op0; op0 = op1; op1 = t; }

    v = ic_fold_boolean_and_or(op0, op1, i, false, false);
    if v != NONE return ic_replace_inst_uses_with(i, v);

    if has_one_use(op1) {
        ok, lx, ly := pm_logical_or(op1);
        if ok {
            v = ic_reassociate_boolean_and_or(op0, lx, ly, i, false, ic_is_binop(op1, .SELECT));
            if v != NONE return ic_replace_inst_uses_with(i, v);
        }
    }
    if has_one_use(op0) {
        ok, lx, ly := pm_logical_or(op0);
        if ok {
            v = ic_reassociate_boolean_and_or(op1, lx, ly, i, false, ic_is_binop(op0, .SELECT));
            if v != NONE return ic_replace_inst_uses_with(i, v);
        }
    }

    r = ic_reassociate_fcmps(i); if r != NONE return r;
    r = ic_fold_casted_bitwise_logic(i); if r != NONE return r;
    r = ic_fold_binop_of_sext_bool_to_select(i); if r != NONE return r;

    // or(sext(A), B) --> A ? -1 : B
    for side: 0..1 {
        s := op(i, cast(u32) side);
        oks, a := pmi_cast(s, .SEXT);
        if !oks || !has_one_use(s) continue;
        if is_int_or_int_vector_n(vtype(a), 1) return ic_create_select_unknown_profile(a, const_all_ones_of(ty), op(i, cast(u32) (1 - side)));
        break;
    }

    // (X|C) | V --> (X|V) | C
    if has_one_use(op0) && vkind(op1) != .C_INT {
        ok, a, ci := pm_binop(op0, .OR);
        if ok && vkind(ci) == .C_INT {
            outer := ic_is_disjoint(i);
            inner_d := ic_is_disjoint(op0);
            inner := icb_binop(.OR, a, op1, "", ifx outer then cast(u32) F_EXACT else 0);
            ic_take_name(inner, op0);
            if outer && inner_d return create_binop_flags(.OR, inner, ci, F_EXACT);
            return create_binop(.OR, inner, ci);
        }
    }

    // (or (bool?A:B),(bool?C:D)) --> (bool?(or A,C):(or B,D))
    if has_one_use(op0) && has_one_use(op1) {
        ok0, x, a, b := pm_select(op0);
        ok1, y, c, d := pm_select(op1);
        if ok0 && ok1 && x == y {
            or_t := icb_or(a, c);
            or_f := icb_or(b, d);
            return create_select(x, or_t, or_f);
        }
    }

    // or(ashr(subNSW(Y, X), BW - 1), X)  --> X s> Y ? -1 : X.
    for side: 0..1 {
        sh := op(i, cast(u32) side);
        if !has_one_use(sh) continue;
        ok, sub, amt := pm_binop(sh, .ASHR);
        if !ok continue;
        oks, y, x := pm_ob(sub, .SUB, F_NSW);
        if !oks || !pm_specific_int(amt, cast(u64) scalar_bits(i) - 1) continue;
        if op(i, cast(u32) (1 - side)) != x continue;
        cmp := icb_cmp(ICMP_SGT, x, y);
        return ic_create_select_unknown_profile(cmp, const_all_ones_of(ty), x);
    }

    {
        try_xor_opt :: (lhs: Value_Id, rhs: Value_Id) -> Value_Id {
            if !ic_is_binop(lhs, .XOR) return NONE;
            a, b: Value_Id = NONE;
            for side: 0..1 {
                ok, aa, bb := pm_binop(op(lhs, cast(u32) side), .AND);
                if ok && op(lhs, cast(u32) (1 - side)) == aa { a = aa; b = bb; break; }
            }
            if a == NONE return NONE;
            if !ic_is_binop(rhs, .XOR) return NONE;
            for side: 0..1 {
                ok, aa, bb := pm_binop(op(rhs, cast(u32) side), .AND);
                if ok && aa == a && bb == b && op(rhs, cast(u32) (1 - side)) == b return create_binop(.XOR, a, b);
            }
            return NONE;
        }
        r = try_xor_opt(op0, op1); if r != NONE return r;
        r = try_xor_opt(op1, op0); if r != NONE return r;
    }

    r = ic_canonicalize_cond_signext_of_high_bit_extract(i); if r != NONE return r;

    // umul.with.overflow: Ov | (Mul != 0) --> (A != 0) & (B != 0)
    for side: 0..1 {
        ov := op(i, cast(u32) side);
        mnz := op(i, cast(u32) (1 - side));
        ok1, umwo := pm_extract_value_idx(ov, 1);
        if !ok1 continue;
        okc, mul, z := pm_specific_icmp(mnz, ICMP_NE);
        if !okc || !pm_zero_int(z) continue;
        ok0, u0 := pm_extract_value_idx(mul, 0);
        if !ok0 || u0 != umwo continue;
        if has_one_use(ov) || (has_one_use(mnz) && has_one_use(mul)) {
            okw, a, b := pm_intrinsic2(umwo, IID_UMUL_WITH_OVERFLOW);
            if okw {
                nna := icb_is_not_null(a);
                nnb := icb_is_not_null(b);
                return create_binop(.AND, nna, nnb);
            }
        }
        break;
    }

    // Overflow | icmp pred Res, C2  -->  Overflow | icmp pred X, C2 +/- C1
    for side: 0..1 {
        ov := op(i, cast(u32) side);
        cmp := op(i, cast(u32) (1 - side));
        ok1, wov := pm_extract_value_idx(ov, 1);
        if !ok1 continue;
        wid := call_iid(wov);
        if !(wid == IID_UADD_WITH_OVERFLOW || wid == IID_SADD_WITH_OVERFLOW || wid == IID_USUB_WITH_OVERFLOW ||
             wid == IID_SSUB_WITH_OVERFLOW || wid == IID_UMUL_WITH_OVERFLOW || wid == IID_SMUL_WITH_OVERFLOW) continue;
        if !has_one_use(cmp) continue;
        okc, pred, _, res, c2v := pm_icmp(cmp);
        if !okc continue;
        ok0, w0 := pm_extract_value_idx(res, 0);
        okc2, c2 := pm_apint(c2v);
        if !ok0 || w0 != wov || !okc2 continue;
        is_add := wid == IID_UADD_WITH_OVERFLOW || wid == IID_SADD_WITH_OVERFLOW;
        is_sub := wid == IID_USUB_WITH_OVERFLOW || wid == IID_SSUB_WITH_OVERFLOW;
        wo_signed := wid == IID_SADD_WITH_OVERFLOW || wid == IID_SSUB_WITH_OVERFLOW || wid == IID_SMUL_WITH_OVERFLOW;
        okc1, c1 := pm_apint(op(wov, 1));
        if (is_add || is_sub) && (icmp_is_equality(pred) || wo_signed == icmp_is_signed(pred)) && okc1 {
            new_c: APInt; overflow: bool;
            if is_add { if icmp_is_signed(pred) new_c, overflow = ap_ssub_ov(c2, c1); else new_c, overflow = ap_usub_ov(c2, c1); }
            else { if icmp_is_signed(pred) new_c, overflow = ap_sadd_ov(c2, c1); else new_c, overflow = ap_uadd_ov(c2, c1); }
            if !overflow || icmp_is_equality(pred) {
                lhsw := op(wov, 0);
                new_cmp := icb_cmp(pred, lhsw, const_int_ap(vtype(lhsw), new_c));
                return create_binop(.OR, ov, new_cmp);
            }
        }
        break;
    }

    v = ic_fold_or_unsigned_umul_overflow_icmp(i);
    if v != NONE return ic_replace_inst_uses_with(i, v);

    if ic_sink_not_into_other_hand_of_logical_op(i) return i;

    // (1 << X) | ((1 << X) + -1)  -->  -1 l>> (bitwidth(x) - 1 - X)
    {
        found_x: Value_Id = NONE;
        for side: 0..1 {
            ad := op(i, cast(u32) side); sh := op(i, cast(u32) (1 - side));
            oka, s1, m1 := pm_binop(ad, .ADD);
            if !oka || !pm_all_ones(m1) continue;
            oks1, one1, x := pm_binop(s1, .SHL);
            if !oks1 || !pm_one(one1) continue;
            oks2, one2, x2 := pm_binop(sh, .SHL);
            if oks2 && pm_one(one2) && x2 == x { found_x = x; break; }
        }
        if found_x != NONE && ic_some_operand_has_one_use(i) {
            sub := icb_sub(const_int_of(ty, cast(u64) scalar_bits(i) - 1), found_x);
            return create_binop(.LSHR, const_all_ones_of(ty), sub);
        }
    }

    {
        okr, pn, start, step := match_simple_recurrence_bo(i);
        if okr && dt_dominates_inst(ic.dt, step, pn) return ic_replace_inst_uses_with(i, icb_or(start, step));
    }

    // (A & B) | (C | D) or (C | D) | (A & B)
    for side: 0..1 {
        an := op(i, cast(u32) side); orv := op(i, cast(u32) (1 - side));
        oka, a, b := pm_binop(an, .AND);
        oko, c, d := pm_binop(orv, .OR);
        if !(oka && has_one_use(an) && oko && has_one_use(orv)) continue;
        if has_one_use(d) && (ic_is_binop(d, .AND) && (op(d, 0) == a || op(d, 1) == a || op(d, 0) == b || op(d, 1) == b))
            return create_binop(.OR, c, icb_or(d, icb_and(a, b)));
        if has_one_use(c) && (ic_is_binop(c, .AND) && (op(c, 0) == a || op(c, 1) == a || op(c, 0) == b || op(c, 1) == b))
            return create_binop(.OR, icb_or(c, icb_and(a, b)), d);
        break;
    }

    r = ic_reassociate_for_uses(i); if r != NONE return r;
    r = ic_canonicalize_logic_first(i); if r != NONE return r;
    r = ic_fold_logic_of_is_fp_class(i, op0, op1); if r != NONE return r;
    r = ic_fold_binop_of_displaced_shifts(i); if r != NONE return r;

    // setting the sign bit of a floating-point value --> fneg(fabs)
    {
        okb, cast_op := pm_elementwise_bitcast(op0);
        if okb && pm_sign_mask(op1) && !fn_has_fn_attr(ic.f, .NoImplicitFloat) {
            et := scalar_type(vtype(cast_op));
            if is_fp_kind(type_kind(et)) {
                fabs := icb_unary_intrinsic(IID_FABS, cast_op);
                fneg := icb_fneg(fabs);
                return create_cast(.BITCAST, fneg, ty);
            }
        }
    }

    // (X & C1) | C2 -> X & (C1 | C2) iff (X & C2) == C2
    {
        ok, x, c1v := pm_binop(op0, .AND);
        okc1, c1 := pm_apint(c1v);
        okc2, c2 := pm_apint(op1);
        if ok && has_one_use(op0) && okc1 && okc2 {
            kx := ic_known_bits(x, i);
            if ap_eq(ap_and(kx.one, c2), c2) return create_binop(.AND, x, const_int_ap(ty, ap_or(c1, c2)));
        }
    }

    r = ic_fold_bitwise_logic_with_intrinsics(i); if r != NONE return r;

    v = ic_simplify_and_or_with_op_replaced(op0, op1, const_null_value(ty), false);
    if v != NONE return create_binop(.OR, v, op1);
    v = ic_simplify_and_or_with_op_replaced(op1, op0, const_null_value(ty), false);
    if v != NONE return create_binop(.OR, op0, v);

    if ic_is_disjoint(i) {
        v = ic_simplify_add_with_remainder(i);
        if v != NONE return ic_replace_inst_uses_with(i, v);
    }

    v = ic_fold_or_of_select_smax_to_abs(i);
    if v != NONE return ic_replace_inst_uses_with(i, v);

    // signum: or (ashr X, BW-1), zext (icmp ne|sgt X, 0) --> scmp(X, 0)
    {
        bw := scalar_bits(i);
        for side: 0..1 {
            ok, x, sa := pm_binop(op(i, cast(u32) side), .ASHR);
            if !ok || !pm_specific_int_allow_poison(sa, cast(u64) bw - 1) continue;
            okz, cmp := pmi_cast(op(i, cast(u32) (1 - side)), .ZEXT);
            if !okz continue;
            okc, pred, _, cx, z := pm_icmp(cmp);
            if !okc || cx != x || !pm_zero_int(z) continue;
            if (pred == ICMP_NE || pred == ICMP_SGT) && (has_one_use(op0) || has_one_use(op1))
                return ic_replace_inst_uses_with(i, icb_intrinsic(IID_SCMP, .[ty, vtype(x)], .[x, const_null_value(ty)]));
            break;
        }
    }
    return NONE;
}

// ---------------------------------------------------------------- xor helpers

// m_c_BinOp(Opc, m_Value(A), m_Not(m_Value(B))) with the first matching order committed: (ok, A, B)
pm_c_binop_val_not :: (v: Value_Id, opc: Opcode) -> (bool, Value_Id, Value_Id) {
    if !ic_is_binop(v, opc) return false, NONE, NONE;
    okn, b := pm_not(op(v, 1)); if okn return true, op(v, 0), b;
    okn, b = pm_not(op(v, 0)); if okn return true, op(v, 1), b;
    return false, NONE, NONE;
}
// m_c_BinOp(Opc, m_Not(m_Value(X)), m_Value(Y)): (ok, X, Y), the not tried as operand 0 first
pm_c_binop_not_val :: (v: Value_Id, opc: Opcode) -> (bool, Value_Id, Value_Id) {
    if !ic_is_binop(v, opc) return false, NONE, NONE;
    okn, x := pm_not(op(v, 0)); if okn return true, x, op(v, 1);
    okn, x = pm_not(op(v, 1)); if okn return true, x, op(v, 0);
    return false, NONE, NONE;
}
// m_c_BinOp(Opc, m_Not(m_Specific(A)), m_Specific(B))
ic_is_c_binop_not_of :: (v: Value_Id, opc: Opcode, a: Value_Id, b: Value_Id) -> bool {
    if !ic_is_binop(v, opc) return false;
    for side: 0..1 {
        okn, na := pm_not(op(v, cast(u32) side));
        if okn && na == a && op(v, cast(u32) (1 - side)) == b return true;
    }
    return false;
}

// foldXorToXor
ic_fold_xor_to_xor :: (i: Value_Id) -> Value_Id {
    op0 := op(i, 0); op1 := op(i, 1);
    // (A & B) ^ (A | B) -> A ^ B (commuted)
    for side: 0..1 {
        ok, a, b := pm_binop(op(i, cast(u32) side), .AND);
        if ok && ic_is_c_binop_of(op(i, cast(u32) (1 - side)), .OR, a, b) return create_binop(.XOR, a, b);
    }
    {
        ok, a, b := pm_c_binop_val_not(op0, .OR);
        if ok && ic_is_c_binop_not_of(op1, .OR, a, b) return create_binop(.XOR, a, b);
    }
    {
        ok, a, b := pm_c_binop_val_not(op0, .AND);
        if ok && ic_is_c_binop_not_of(op1, .AND, a, b) return create_binop(.XOR, a, b);
    }
    if !has_one_use(op0) && !has_one_use(op1) return NONE;
    {
        okn, n := pm_not(op1);
        ok, a, b := pm_binop(op0, .OR);
        if ok && okn && ic_is_c_binop_of(n, .AND, a, b) return create_not(icb_xor(a, b));
        ok, a, b = pm_binop(op0, .AND);
        if ok && okn && ic_is_c_binop_of(n, .OR, a, b) return create_not(icb_xor(a, b));
    }
    return NONE;
}

// replaceUsesWithIf(New, [](Use &U) { return U.getUser() != Excluded; }) for instruction users
ic_replace_uses_except :: (old: Value_Id, new: Value_Id, excluded: Value_Id) {
    u := ir.v_first_use[old];
    while u != NONE {
        nu := ir.u_next[u];
        usr := ir.u_user[u];
        if usr != excluded {
            if is_constant_kind(vkind(usr)) && !is_global_value(vkind(usr)) fatal("instcombine: replaceUsesWithIf with a constant user is not supported yet");
            use_set(u, new);
        }
        u = nu;
    }
}

// foldXorOfICmps
ic_fold_xor_of_icmps :: (lhs: Value_Id, rhs: Value_Id, i: Value_Id) -> Value_Id {
    pred_l := inst_pred(lhs); pred_r := inst_pred(rhs);
    lhs0 := op(lhs, 0); lhs1 := op(lhs, 1);
    rhs0 := op(rhs, 0); rhs1 := op(rhs, 1);
    if ic_predicates_foldable(pred_l, pred_r) {
        if lhs0 == rhs1 && lhs1 == rhs0 {
            t := lhs0; lhs0 = lhs1; lhs1 = t;
            pred_l = icmp_swapped(pred_l);
        }
        if lhs0 == rhs0 && lhs1 == rhs1 {
            code := ic_get_icmp_code(pred_l) ^ ic_get_icmp_code(pred_r);
            is_signed := icmp_is_signed(inst_pred(lhs)) || icmp_is_signed(inst_pred(rhs));
            return ic_get_new_icmp_value(code, is_signed, lhs0, lhs1);
        }
    }
    okl, lc := pm_apint(lhs1);
    okr, rc := pm_apint(rhs1);
    if okl && okr && vtype(lhs0) == vtype(rhs0) && is_int_or_int_vector(vtype(lhs0)) {
        sbl, tsl := is_sign_bit_check(pred_l, lc);
        sbr, tsr := is_sign_bit_check(pred_r, rc);
        if (has_one_use(lhs) || has_one_use(rhs)) && sbl && sbr {
            xor_lr := icb_xor(lhs0, rhs0);
            if tsl == tsr return icb_cmp(ICMP_SLT, xor_lr, const_null_value(vtype(xor_lr)), "isneg");
            return icb_cmp(ICMP_SGT, xor_lr, const_all_ones_of(vtype(xor_lr)), "isnotneg");
        }
        if lhs0 == rhs0 {
            cr1 := cr_exact_icmp_region(pred_l, lc);
            cr2 := cr_exact_icmp_region(pred_r, rc);
            oku, cru := cr_exact_union(cr1, cr2);
            oki, cri := cr_exact_intersect(cr1, cr2);
            if oku && oki {
                okx, cr := cr_exact_intersect(cru, cr_inverse(cri));
                if okx {
                    if cr_is_full_set(cr) return get_true(vtype(i));
                    if cr_is_empty_set(cr) return get_false(vtype(i));
                    new_pred, new_c, offset := cr_equivalent_icmp(cr);
                    if (ap_is_zero(offset) && (has_one_use(lhs) || has_one_use(rhs))) || (has_one_use(lhs) && has_one_use(rhs)) {
                        nv := lhs0;
                        ty := vtype(lhs0);
                        if !ap_is_zero(offset) nv = icb_add(nv, const_int_ap(ty, offset));
                        return icb_cmp(new_pred, nv, const_int_ap(ty, new_c));
                    }
                }
            }
        }
        if icmp_is_equality(pred_l) && icmp_is_equality(pred_r) && ap_is_zero(lc) && ap_is_zero(rc) && has_one_use(lhs) && has_one_use(rhs) {
            ok1, x, pow2 := pm_binop(lhs0, .AND);
            ok2, y, p2 := pm_binop(rhs0, .AND);
            if ok1 && ok2 && p2 == pow2 && ic_is_known_to_be_power_of_two(pow2, true, i) {
                xr := icb_xor(x, y);
                a := icb_and(xr, pow2);
                return icb_cmp(ifx pred_l == pred_r then cast(u8) ICMP_NE else ICMP_EQ, a, const_null_value(vtype(xr)));
            }
        }
    }
    or_icmp := simplify_binop_r(.OR, lhs, rhs, ic.sq, RECURSION_LIMIT);
    if or_icmp != NONE {
        and_icmp := simplify_binop_r(.AND, lhs, rhs, ic.sq, RECURSION_LIMIT);
        if and_icmp != NONE {
            x, y: Value_Id = NONE;
            if or_icmp == lhs && and_icmp == rhs { x = lhs; y = rhs; }
            if or_icmp == rhs && and_icmp == lhs { x = rhs; y = lhs; }
            if x != NONE && y != NONE && (has_one_use(y) || can_freely_invert_all_users_of(y, i)) {
                inst(y).pred = cmp_inverse(inst_pred(y));
                if !has_one_use(y) {
                    saved := ic.b;
                    icb_set_insert_point_after(y);
                    not_y := icb_not(y, tprint("%.not", vname(y)));
                    ic.b = saved;
                    wl_push_users(y);
                    ic_replace_uses_except(y, not_y, not_y);
                }
                return icb_and(lhs, rhs);
            }
        }
    }
    return NONE;
}

// visitMaskedMerge
ic_visit_masked_merge :: (i: Value_Id) -> Value_Id {
    b, x, d, m: Value_Id = NONE;
    found := false;
    for side: 0..1 {
        bb := op(i, cast(u32) side);
        an := op(i, cast(u32) (1 - side));
        if !ic_is_binop(an, .AND) || !has_one_use(an) continue;
        for s2: 0..1 {
            dd := op(an, cast(u32) s2);
            okx, xv := pm_c_binop_with(dd, .XOR, bb);
            if okx { b = bb; d = dd; x = xv; m = op(an, cast(u32) (1 - s2)); found = true; break; }
        }
        if found break;
    }
    if !found return NONE;
    okn, not_m := pm_not(m);
    if okn {
        new_a := icb_and(d, not_m);
        return create_binop(.XOR, new_a, x);
    }
    if has_one_use(d) && is_const(m) {
        c := ic_replace_undefs_with(m, const_all_ones_of(scalar_type(vtype(m))));
        lhs := icb_and(x, c);
        not_c := icb_not(c);
        rhs := icb_and(b, not_c);
        return create_binop(.OR, lhs, rhs);
    }
    return NONE;
}

// foldNotXor
ic_fold_not_xor :: (i: Value_Id) -> Value_Id {
    okn, xr := pm_not(i);
    if !okn || !has_one_use(xr) return NONE;
    okx, x, y := pm_binop(xr, .XOR);
    if !okx return NONE;
    has_common :: (a: Value_Id, b: Value_Id, c: Value_Id, d: Value_Id) -> bool { return a == c || a == d || b == c || b == d; }
    {
        oka, a, b := pm_binop(x, .AND);
        oko, c, d := pm_binop(y, .OR);
        if oka && oko && has_common(a, b, c, d) return create_binop(.OR, x, icb_not(y));
    }
    {
        oka, a, b := pm_binop(y, .AND);
        oko, c, d := pm_binop(x, .OR);
        if oka && oko && has_common(a, b, c, d) return create_binop(.OR, y, icb_not(x));
    }
    return NONE;
}

// canonicalizeAbs
ic_canonicalize_abs :: (xor: Value_Id) -> Value_Id {
    op0 := op(xor, 0); op1 := op(xor, 1);
    if has_n_uses(op0, 2) { t := op0; op0 = op1; op1 = t; }
    ty := vtype(xor);
    ok, a, sa := pm_binop(op1, .ASHR);
    okc, sh := pm_apint(sa);
    if ok && okc && has_n_uses(op1, 2) && ap_eq_u64(sh, cast(u64) scalar_bits(xor) - 1) && has_one_use(op0) && ic_is_c_binop_of(op0, .ADD, a, op1) {
        is_neg := icb_cmp(ICMP_SLT, a, const_null_value(vtype(a)));
        neg_a := ifx has_nuw(op0) then const_null_value(vtype(a)) else icb_neg(a, "", has_nsw(op0));
        return create_select(is_neg, neg_a, a);
    }
    return NONE;
}

// canFreelyInvert
ic_can_freely_invert :: (v: Value_Id, ignored_user: Value_Id) -> bool {
    if !is_inst(v) return false;
    free, _ := ic_is_free_to_invert(v, true);
    return free && can_freely_invert_all_users_of(v, ignored_user);
}

// Instruction::getInsertionPointAfterDef as the Builder's insertion point
ic_set_insert_point_after_def :: (i: Value_Id) {
    o := inst_op(i);
    if o == .PHI {
        b := inst(i).parent;
        pt := block_first_insertion_pt(b);
        if pt == NONE fatal("internal: getInsertionPointAfterDef: no insertion point");
        icb_set_insert_point(pt);
        return;
    }
    if o == .INVOKE || o == .CALLBR fatal("instcombine: getInsertionPointAfterDef of an invoke/callbr is not supported yet");
    nx := inst(i).next;
    if nx == NONE fatal("internal: getInsertionPointAfterDef: no insertion point");
    icb_set_insert_point(nx);
}

// freelyInvert
ic_freely_invert :: (v: Value_Id, ignored_user: Value_Id) -> Value_Id {
    ic_set_insert_point_after_def(v);
    not_op := icb_not(v, tprint("%.not", vname(v)));
    ic_replace_uses_except(v, not_op, not_op);
    ic_freely_invert_all_users_of(not_op, ignored_user);
    return not_op;
}

// sinkNotIntoLogicalOp
ic_sink_not_into_logical_op :: (i: Value_Id) -> bool {
    ok, op0, op1 := pm_logical_op(i);
    if !ok return false;
    if op0 == op1 return false;
    okn0, n0 := pm_not(op0);
    okn1, n1 := pm_not(op1);
    if (okn0 && n0 == op1) || (okn1 && n1 == op0) return false;
    oka, _, _ := pm_logical_and(i);
    new_opc := ifx oka then Opcode.OR else .AND;
    is_binary_op := is_binary_operator(i);
    if !can_freely_invert_all_users_of(i, NONE) return false;
    if !ic_can_freely_invert(op0, i) || !ic_can_freely_invert(op1, i) return false;
    op0 = ic_freely_invert(op0, i);
    op1 = ic_freely_invert(op1, i);
    ic_set_insert_point_after_def(i);
    new_logic_op: Value_Id;
    if is_binary_op new_logic_op = icb_binop(new_opc, op0, op1, tprint("%.not", vname(i)));
    else {
        new_logic_op = icb_logical_op(new_opc, op0, op1, tprint("%.not", vname(i)), i);
        if ic_is_binop(new_logic_op, .SELECT) swap_prof_metadata(new_logic_op);
    }
    ic_replace_inst_uses_with(i, new_logic_op);
    ic_freely_invert_all_users_of(new_logic_op);
    return true;
}

// sinkNotIntoOtherHandOfLogicalOp
ic_sink_not_into_other_hand_of_logical_op :: (i: Value_Id) -> bool {
    ok, op0, op1 := pm_logical_op(i);
    if !ok return false;
    oka, _, _ := pm_logical_and(i);
    new_opc := ifx oka then Opcode.OR else .AND;
    is_binary_op := is_binary_operator(i);
    invert_op1 := false;
    okn0, n0 := pm_not(op0);
    if okn0 && ic_can_freely_invert(op1, i) { op0 = n0; invert_op1 = true; }
    else {
        okn1, n1 := pm_not(op1);
        if okn1 && ic_can_freely_invert(op0, i) { op1 = n1; invert_op1 = false; }
        else return false;
    }
    to_invert := ifx invert_op1 then op1 else op0;
    kept := ifx invert_op1 then op0 else op1;
    okk, nk := pm_not(kept);
    if okk && nk == to_invert return false;
    if !can_freely_invert_all_users_of(i, NONE) return false;
    inv := ic_freely_invert(to_invert, i);
    if invert_op1 op1 = inv; else op0 = inv;
    ic_set_insert_point_after_def(i);
    new_bin_op: Value_Id;
    if is_binary_op new_bin_op = icb_binop(new_opc, op0, op1, tprint("%.not", vname(i)));
    else new_bin_op = icb_logical_op(new_opc, op0, op1, tprint("%.not", vname(i)));
    ic_replace_inst_uses_with(i, new_bin_op);
    ic_freely_invert_all_users_of(new_bin_op);
    return true;
}

// foldNot
ic_fold_not :: (i: Value_Id) -> Value_Id {
    okn, not_op := pm_not(i);
    if !okn return NONE;
    ty := vtype(i);
    if has_one_use(not_op) {
        ok, x, y := pm_c_binop_not_val(not_op, .AND);
        if ok {
            not_y := icb_not(y, tprint("%.not", vname(y)));
            return create_binop(.OR, x, not_y);
        }
    }
    if has_one_use(not_op) {
        ok, a, y := pm_logical_and(not_op);
        if ok {
            okx, x := pm_not(a);
            if okx {
                not_y := icb_not(y, tprint("%.not", vname(y)));
                si := ic_create_select_md_from(x, get_true(ty), not_y, not_op);
                swap_prof_metadata(si);
                return si;
            }
        }
    }
    if has_one_use(not_op) {
        ok, x, y := pm_c_binop_not_val(not_op, .OR);
        if ok {
            not_y := icb_not(y, tprint("%.not", vname(y)));
            return create_binop(.AND, x, not_y);
        }
    }
    if has_one_use(not_op) {
        ok, a, y := pm_logical_or(not_op);
        if ok {
            okx, x := pm_not(a);
            if okx {
                not_y := icb_not(y, tprint("%.not", vname(y)));
                si := ic_create_select_md_from(x, not_y, get_false(ty), not_op);
                swap_prof_metadata(si);
                return si;
            }
        }
    }

    if is_binary_operator(not_op) {
        not_val := not_op;
        // ~((-X) | Y) --> (X - 1) & (~Y)
        if has_one_use(not_val) && ic_is_binop(not_val, .OR) {
            for side: 0..1 {
                ng := op(not_val, cast(u32) side);
                okng, x := pm_neg(ng);
                if okng && has_one_use(ng) {
                    y := op(not_val, cast(u32) (1 - side));
                    dec_x := icb_add(x, const_all_ones_of(ty));
                    not_y := icb_not(y);
                    return create_binop(.AND, dec_x, not_y);
                }
            }
        }
        {
            ok, nx, y := pm_binop(not_val, .ASHR);
            if ok { okx, x := pm_not(nx); if okx return create_binop(.ASHR, x, y); }
        }
        {
            ok, nx, y := pm_binop(not_val, .LSHR);
            if ok {
                okx, x := pm_not(nx);
                if okx && is_known_negative(x, ic_q(not_val)) return create_binop(.ASHR, x, y);
            }
        }
        full_shift := scalar_bits(i) - 1;
        {
            ok, x, sa := pm_binop(not_val, .ASHR);
            if ok && has_one_use(not_val) && pm_specific_int(sa, cast(u64) full_shift) {
                is_not_neg := icb_cmp(ICMP_SGT, x, const_all_ones_of(vtype(x)), "isnotneg");
                return create_cast(.SEXT, is_not_neg, ty);
            }
        }
        {
            ok, c, y := pm_binop(not_val, .ASHR);
            if ok && is_const(c) && pm_negative(c) return create_binop(.LSHR, ce_not(c), y);
        }
        {
            ok, c, y := pm_binop(not_val, .LSHR);
            if ok && is_const(c) && pm_non_negative(c) return create_binop(.ASHR, ce_not(c), y);
        }
        {
            ok, x, c := pm_binop(not_val, .ADD);
            if ok && pm_imm_constant(c) return create_binop(.SUB, ce_not(c), x);
        }
        {
            ok, x, y := pm_binop(not_val, .SUB);
            if ok && (is_const(x) || has_one_use(not_val)) return create_binop(.ADD, icb_not(x), y);
        }
        {
            ok, x, y := pm_c_binop_not_val(not_val, .ADD);
            if ok {
                s := create_binop(.SUB, x, y);
                copy_ir_flags(s, not_val);
                return s;
            }
        }
    }

    if is_cmp_inst(not_op) && (has_one_use(not_op) || can_freely_invert_all_users_of(not_op, NONE)) {
        inst(not_op).pred = cmp_inverse(inst_pred(not_op));
        ic_freely_invert_all_users_of(not_op);
        return i;
    }
    {
        okb, x := pm_cast(not_op, .BITCAST);
        if okb && has_one_use(not_op) && is_cmp_inst(x) && has_one_use(x) {
            inst(x).pred = cmp_inverse(inst_pred(x));
            return create_cast(.BITCAST, x, ty);
        }
    }
    {
        okb, s := pm_cast(not_op, .BITCAST);
        if okb && has_one_use(not_op) {
            oks, x := pmi_cast(s, .SEXT);
            if oks && has_one_use(s) && is_int_or_int_vector_n(vtype(x), 1) {
                sext_ty := vtype(op(not_op, 0));
                not_x := icb_not(x);
                sext := icb_sext(not_x, sext_ty);
                return create_cast(.BITCAST, sext, ty);
            }
        }
    }

    if is_inst(not_op) && ic_sink_not_into_logical_op(not_op) return i;

    iid := call_iid(not_op);
    if iid != NOT_INTRINSIC && inst_op(not_op) == .CALL && has_one_use(not_op) {
        if is_min_max_intrinsic(iid) {
            for side: 0..1 {
                okx, x := pm_not(op(not_op, cast(u32) side));
                if okx {
                    y := op(not_op, cast(u32) (1 - side));
                    inv_id := inverse_min_max_intrinsic(iid);
                    not_y := icb_not(y);
                    inv := icb_binary_intrinsic(inv_id, x, not_y);
                    return ic_replace_inst_uses_with(i, inv);
                }
            }
        }
        if iid == IID_IS_FPCLASS {
            cm := op(not_op, 1);
            set_op(not_op, 1, const_int_of(vtype(cm), ~const_int_zext(cm) & cast(u64) FC_ALL_FLAGS));
            return ic_replace_inst_uses_with(i, not_op);
        }
    }

    if has_one_use(not_op) && ic_is_binop(not_op, .SELECT) {
        sel := not_op;
        tv := op(sel, 1); fv := op(sel, 2);
        cmp_t := is_cmp_inst(tv); cmp_f := is_cmp_inst(fv);
        inv_t := (cmp_t && has_one_use(tv)) || is_const(tv);
        inv_f := (cmp_f && has_one_use(fv)) || is_const(fv);
        if inv_t && inv_f {
            if cmp_t inst(tv).pred = cmp_inverse(inst_pred(tv));
            else set_op(sel, 1, ce_not(tv));
            if cmp_f inst(fv).pred = cmp_inverse(inst_pred(fv));
            else set_op(sel, 2, ce_not(fv));
            return ic_replace_inst_uses_with(i, sel);
        }
    }

    r := ic_fold_not_xor(i); if r != NONE return r;

    rv := ic_get_freely_inverted(not_op, has_one_use(not_op), true);
    if rv != NONE return ic_replace_inst_uses_with(i, rv);
    return NONE;
}

// foldMaskedAddXorPattern
ic_fold_masked_add_xor_pattern :: (i: Value_Id) -> Value_Id {
    ok, an, mask := pm_binop(i, .XOR);
    if !ok || !has_one_use(an) return NONE;
    oka, add, m2 := pm_binop(an, .AND);
    if !oka || m2 != mask || !has_one_use(add) || !is_binary_operator(add) return NONE;
    okd, x, add_c := pm_binop(add, .ADD);
    if !okd || !pm_imm_constant(add_c) return NONE;
    not_c := icb_not(add_c);
    new_sub := icb_sub(not_c, x, "", has_nuw(add), has_nsw(add));
    return create_binop(.AND, new_sub, mask);
}

// ---------------------------------------------------------------- visitXor

ic_visit_xor :: (i: Value_Id) -> Value_Id {
    v := simplify_xor_inst(op(i, 0), op(i, 1), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if ic_simplify_associative_or_commutative(i) return i;
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_fold_binop_with_phi_operands(i); if r != NONE return r;
    r = ic_fold_xor_to_xor(i); if r != NONE return r;
    v = ic_fold_using_distributive_laws(i);
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if ic_simplify_demanded_instruction_bits(i) return i;
    r = ic_fold_not(i); if r != NONE return r;
    r = ic_fold_binop_shift_with_shift(i); if r != NONE return r;

    op0 := op(i, 0); op1 := op(i, 1);
    ty := vtype(i);

    // (X | Y) ^ M -> (X ^ M) ^ Y
    for side: 0..1 {
        o := op(i, cast(u32) side);
        ok, x, y := pm_disjoint_or(o);
        if !ok || !has_one_use(o) continue;
        m := op(i, cast(u32) (1 - side));
        xm := simplify_xor_inst(x, m, ic_q(i));
        if xm != NONE return create_binop(.XOR, xm, y);
        ym := simplify_xor_inst(y, m, ic_q(i));
        if ym != NONE return create_binop(.XOR, ym, x);
        break;
    }

    // (X & M) ^ (Y & ~M) -> (X & M) | (Y & ~M)
    for side: 0..1 {
        a := op(i, cast(u32) side); b := op(i, cast(u32) (1 - side));
        ok, m, _ := pm_c_binop_not_val(a, .AND);
        if !ok continue;
        if !(ic_is_binop(b, .AND) && (op(b, 0) == m || op(b, 1) == m)) continue;
        if is_guaranteed_not_to_be_undef(m) return create_binop_flags(.OR, op0, op1, F_EXACT);
        return create_binop(.OR, op0, op1);
    }

    r = ic_visit_masked_merge(i); if r != NONE return r;

    if is_const(op1) {
        c1 := op1;
        {
            ok, x, c2 := pm_binop(op0, .OR);
            if ok && has_one_use(op0) && pm_imm_constant(c2) && pm_imm_constant(c1) {
                c2 = ic_replace_undefs_with(c2, const_all_ones_of(scalar_type(vtype(c2))));
                a := icb_and(x, ic_merge_undefs_with(ce_not(c2), c1));
                return create_binop(.XOR, a, ic_merge_undefs_with(ce_binop(.XOR, c1, c2, 0), c1));
            }
        }
        {
            ok, nx, c2 := pm_binop(op0, .OR);
            if ok && has_one_use(op0) && is_const(c2) {
                okn, x := pm_not(nx);
                if okn {
                    a := icb_and(x, ce_not(c2));
                    return create_binop(.XOR, a, ce_not(c1));
                }
            }
        }
        {
            ok, nx, c2 := pm_binop(op0, .AND);
            if ok && has_one_use(op0) && is_const(c2) {
                okn, x := pm_not(nx);
                if okn {
                    o := icb_or(x, ce_not(c2));
                    return create_binop(.XOR, o, ce_not(c1));
                }
            }
        }
        if has_one_use(op0) {
            sh := trunc_or_self_i(op0);
            ok, x, cav := pm_binop(sh, .ASHR);
            okc, ca := pm_apint_ap(cav);
            if ok && okc && ap_eq_u64(ca, cast(u64) scalar_bits(x) - 1) && !pm_all_ones(c1) {
                is_not_neg := icb_cmp(ICMP_SGT, x, const_all_ones_of(vtype(x)));
                return ic_create_select_unknown_profile(is_not_neg, op1, icb_not(op1));
            }
        }
    }

    {
        okr, rhsc := pm_apint(op1);
        if okr {
            if ap_is_sign_mask(rhsc) {
                ok, cv, x := pm_binop(op0, .SUB);
                okc, c := pm_apint(cv);
                if ok && okc return create_binop(.SUB, const_int_ap(ty, ap_add(c, rhsc)), x);
            }
            if ap_is_sign_mask(rhsc) {
                ok, x, cv := pm_binop(op0, .ADD);
                okc, c := pm_apint(cv);
                if ok && okc return create_binop(.ADD, x, const_int_ap(ty, ap_add(c, rhsc)));
            }
            {
                ok, x, cv := pm_binop(op0, .OR);
                okc, c := pm_apint(cv);
                if ok && okc && ic_masked_value_is_zero(x, c, i) return create_binop(.XOR, x, const_int_ap(ty, ap_xor(c, rhsc)));
            }
            iid := call_iid(op0);
            if iid != NOT_INTRINSIC && inst_op(op0) == .CALL && has_one_use(op0) && ap_eq_u64(rhsc, cast(u64) scalar_bits(i) - 1) {
                if (iid == IID_CTLZ || iid == IID_CTTZ) && pm_one(op(op0, 1)) && is_known_to_be_a_power_of_two(op(op0, 0), true, ic.sq) {
                    niid := ifx iid == IID_CTLZ then IID_CTTZ else IID_CTLZ;
                    return create_intrinsic_call(niid, .[ty], .[op(op0, 0), get_true(ir.t_i1)]);
                }
            }
            bw := scalar_bits(i);
            {
                ok, x, cv := pm_binop(op0, .SHL);
                okc, c := pm_apint(cv);
                if ok && has_one_use(op0) && okc && ap_eq(rhsc, ap_shl_ap(ap_all_ones(bw), c)) {
                    not_x := icb_not(x);
                    return create_binop(.SHL, not_x, const_int_ap(ty, c));
                }
            }
            {
                ok, x, cv := pm_binop(op0, .LSHR);
                okc, c := pm_apint(cv);
                if ok && has_one_use(op0) && okc && ap_eq(rhsc, ap_lshr_ap(ap_all_ones(bw), c)) {
                    not_x := icb_not(x);
                    return create_binop(.LSHR, not_x, const_int_ap(ty, c));
                }
            }
        }
        okb, cast_op := pm_elementwise_bitcast(op0);
        if okb && pm_sign_mask(op1) && !fn_has_fn_attr(ic.f, .NoImplicitFloat) {
            et := scalar_type(vtype(cast_op));
            if is_fp_kind(type_kind(et)) {
                fneg := icb_fneg(cast_op);
                return create_cast(.BITCAST, fneg, ty);
            }
        }
    }

    // ((X^C1) >> C2) ^ C3 -> (X>>C2) ^ ((C1>>C2)^C3)
    if vkind(op1) == .C_INT {
        ok, xr, c2 := pm_binop(op0, .LSHR);
        if ok && vkind(c2) == .C_INT && has_one_use(op0) {
            okx, x, c1 := pm_binop(xr, .XOR);
            if okx && vkind(c1) == .C_INT {
                fold := ap_xor(ap_lshr_ap(const_ap(c1), const_ap(c2)), const_ap(op1));
                opnd0 := icb_lshr(x, c2);
                ic_take_name(opnd0, op0);
                return create_binop(.XOR, opnd0, const_int_ap(ty, fold));
            }
        }
    }

    r = ic_fold_binop_into_select_or_phi(i); if r != NONE return r;
    r = ic_fold_binop_select_binop(i); if r != NONE return r;

    if has_one_use(op1) { ok, x := pm_c_binop_with(op1, .OR, op0); if ok return create_binop(.AND, x, icb_not(op0)); }
    if has_one_use(op0) { ok, x := pm_c_binop_with(op0, .OR, op1); if ok return create_binop(.AND, x, icb_not(op1)); }
    if has_one_use(op1) { ok, x := pm_c_binop_with(op1, .AND, op0); if ok return create_binop(.AND, op0, icb_not(x)); }
    if !is_const(op1) && has_one_use(op0) { ok, x := pm_c_binop_with(op0, .AND, op1); if ok return create_binop(.AND, op1, icb_not(x)); }

    // (A ^ B) ^ (A | C) --> (~A & C) ^ B ; (A ^ B) ^ (B | C) --> (~B & C) ^ A
    for which: 0..1 {
        for side: 0..1 {
            xr := op(i, cast(u32) side); orv := op(i, cast(u32) (1 - side));
            if !has_one_use(xr) || !has_one_use(orv) continue;
            ok, a, b := pm_binop(xr, .XOR);
            if !ok continue;
            key := ifx which == 0 then a else b;
            okc, c := pm_c_binop_with(orv, .OR, key);
            if !okc continue;
            other := ifx which == 0 then b else a;
            return create_binop(.XOR, icb_and(icb_not(key), c), other);
        }
    }

    {
        ok, a, b := pm_binop(op0, .AND);
        if ok && ic_is_c_binop_of(op1, .XOR, a, b) return create_binop(.OR, a, b);
        ok, a, b = pm_binop(op0, .XOR);
        if ok && ic_is_c_binop_of(op1, .AND, a, b) return create_binop(.OR, a, b);
    }
    {
        ok, a, b := pm_c_binop_val_not(op0, .AND);
        okn, na := pm_not(op1);
        if ok && okn && na == a return create_not(icb_and(a, b));
    }
    // (~A & B) ^ A --> A | B
    for side: 0..1 {
        ok, a, b := pm_c_binop_not_val(op(i, cast(u32) side), .AND);
        if !ok continue;
        if op(i, cast(u32) (1 - side)) == a return create_binop(.OR, a, b);
    }
    // (~A | B) ^ A --> ~(A & B)
    if has_one_use(op0) && ic_is_binop(op0, .OR) {
        for side: 0..1 {
            okn, na := pm_not(op(op0, cast(u32) side));
            if okn && na == op1 return create_not(icb_and(op1, op(op0, cast(u32) (1 - side))));
        }
    }
    if has_one_use(op1) && ic_is_binop(op1, .OR) {
        for side: 0..1 {
            okn, na := pm_not(op(op1, cast(u32) side));
            if okn && na == op0 return create_not(icb_and(op0, op(op1, cast(u32) (1 - side))));
        }
    }

    // (A | B) ^ (A | C) --> (B ^ C) & ~A
    {
        ok0, a, b := pm_binop(op0, .OR);
        ok1, c, d := pm_binop(op1, .OR);
        if ok0 && has_one_use(op0) && ok1 && has_one_use(op1) {
            if b == c || b == d { t := a; a = b; b = t; }
            if a == c { t := c; c = d; d = t; }
            if a == d {
                not_a := icb_not(a);
                return create_binop(.AND, icb_xor(b, c), not_a);
            }
        }
    }

    // (A & B) ^ (A | C) --> A ? ~B : C
    if is_int_or_int_vector_n(ty, 1) {
        for side: 0..1 {
            o0 := op(i, cast(u32) side); o1 := op(i, cast(u32) (1 - side));
            if !has_one_use(o0) || !has_one_use(o1) continue;
            ok0, a, b := pm_logical_and(o0);
            ok1, c, d := pm_logical_or(o1);
            if !ok0 || !ok1 continue;
            need_freeze := ic_is_binop(op0, .SELECT) && ic_is_binop(op1, .SELECT) && b == d;
            md_from := op0;
            if b == c || b == d {
                t := a; a = b; b = t;
                md_from = ifx b == c then op1 else NONE;
            }
            if a == c { t := c; c = d; d = t; }
            if a == d {
                if need_freeze a = icb_freeze(a);
                not_b := icb_not(b);
                if md_from == NONE return ic_create_select_unknown_profile(a, not_b, c);
                return ic_create_select_md_from(a, not_b, c, md_from);
            }
            break;
        }
    }

    if ic_is_icmp(op(i, 0)) && ic_is_icmp(op(i, 1)) {
        v = ic_fold_xor_of_icmps(op(i, 0), op(i, 1), i);
        if v != NONE return ic_replace_inst_uses_with(i, v);
    }

    r = ic_fold_casted_bitwise_logic(i); if r != NONE return r;
    r = ic_canonicalize_abs(i); if r != NONE return r;

    // (X ^ C) ^ Y --> (X ^ Y) ^ C
    for side: 0..1 {
        xr := op(i, cast(u32) side);
        if !has_one_use(xr) continue;
        ok, x, c1 := pm_binop(xr, .XOR);
        if !ok || vkind(x) == .C_EXPR || !pm_imm_constant(c1) continue;
        y := op(i, cast(u32) (1 - side));
        return create_binop(.XOR, icb_xor(x, y), c1);
    }

    r = ic_reassociate_for_uses(i); if r != NONE return r;
    r = ic_canonicalize_logic_first(i); if r != NONE return r;
    r = ic_fold_logic_of_is_fp_class(i, op0, op1); if r != NONE return r;
    r = ic_canonicalize_conditional_negation_via_math_to_select(i); if r != NONE return r;
    r = ic_fold_binop_of_displaced_shifts(i); if r != NONE return r;
    r = ic_fold_bitwise_logic_with_intrinsics(i); if r != NONE return r;
    r = ic_fold_masked_add_xor_pattern(i); if r != NONE return r;
    return NONE;
}

// ---------------------------------------------------------------- TEMPORARY (InstCombineSelect.cpp, owned by ic_select.jai)
// Ported here only until ic_select.jai lands on main; whoever rebases second deletes this block.

// simplifyNestedSelectsUsingImpliedCond
ic_simplify_nested_selects_using_implied_cond :: (si: Value_Id, cond_val: Value_Id, cond_is_true: bool) -> Value_Id {
    implied := is_implied_condition(cond_val, op(si, 0), cond_is_true);
    if implied < 0 return NONE;
    return ifx implied == 1 then op(si, 1) else op(si, 2);
}
// foldAndOrOfSelectUsingImpliedCond
ic_fold_and_or_of_select_using_implied_cond :: (opv: Value_Id, si: Value_Id, is_and: bool) -> Value_Id {
    if vtype(op(si, 0)) != vtype(opv) return NONE;
    v := ic_simplify_nested_selects_using_implied_cond(si, opv, is_and);
    if v == NONE return NONE;
    t := vtype(opv);
    return ic_create_select_unknown_profile(opv, ifx is_and then v else get_true(t), ifx is_and then get_false(t) else v);
}
