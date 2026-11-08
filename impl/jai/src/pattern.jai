// PatternMatch: the matchers of llvm/include/llvm/IR/PatternMatch.h that the analyses use, written as plain
// procedures. Naming: pm_<matcher>(v) -> (matched, captures...). Binary-operator matchers also match constant
// expressions of the same opcode (BinaryOp_match / CastOperator_match match Operators), intrinsic and select
// matchers only match instructions, like LLVM's.
//
// Constants: the cst_pred_ty family (m_Zero, m_One, m_AllOnes, m_Power2, ...) accept a scalar ConstantInt, a
// vector splat, or (fixed vectors) every element matching with poison elements ignored. m_APInt only accepts
// scalars and non-poison splats; m_APIntAllowPoison also poison-containing splats.

// ---------------------------------------------------------------- constants

// Constant::getSplatValue(AllowPoison)
get_splat_value :: (c: Value_Id, allow_poison := false) -> Value_Id {
    t := vtype(c);
    if !is_vector_type(t) return NONE;
    et := type_elem(t);
    k := vkind(c);
    if k == .C_POISON return const_poison(et);
    if k == .C_ZERO return const_null_value(et);
    if k == .C_INT return const_int_words(et, const_int_value(c));
    if k == .C_FP return const_fp_words(et, const_fp_value(c));
    if k == .C_NULL return const_null(et);
    if k == .C_DATA {
        n := const_data_count(c);
        e := const_data_elt(c, 0);
        for i: 1..cast(s64) n - 1 if const_data_elt(c, cast(u64) i) != e return NONE;
        return cf_elt(c, 0);
    }
    if k == .C_VECTOR {
        elt := op(c, 0);
        n := nops(c);
        for i: 1..cast(s64) n - 1 {
            o := op(c, cast(u32) i);
            if o == elt continue;
            if !allow_poison return NONE;
            if vkind(o) == .C_POISON continue;
            if vkind(elt) == .C_POISON elt = o;
            if o != elt return NONE;
        }
        return elt;
    }
    if k == .C_EXPR {
        e := cexpr(c);
        if e.op == .SHUFFLEVECTOR && pm_undef_value(op(c, 1)) {
            ie := op(c, 0);
            if vkind(ie) == .C_EXPR && cexpr(ie).op == .INSERTELEMENT && pm_undef_value(op(ie, 0)) {
                idx := op(ie, 2);
                if vkind(idx) == .C_INT && !is_vector_type(vtype(idx)) && ap_is_zero(cf_ap(idx)) {
                    all0 := true;
                    if e.nidx > 0 for i: 0..e.nidx-1 if ir.u32_pool[e.idx + i] != 0 { all0 = false; break; }
                    if all0 return op(ie, 1);
                }
            }
        }
    }
    return NONE;
}

// a scalar ConstantInt (isa<ConstantInt> with a scalar type; vector-typed ConstantInt splats count as ConstantInt too)
is_const_int :: inline (v: Value_Id) -> bool { return vkind(v) == .C_INT; }
is_scalar_const_int :: inline (v: Value_Id) -> bool { return vkind(v) == .C_INT && !is_vector_type(vtype(v)); }
const_ap :: (v: Value_Id) -> APInt { return ap_from_words(type_bits(scalar_type(vtype(v))), const_int_value(v)); }

// m_APInt / m_APIntAllowPoison
pm_apint :: (v: Value_Id, allow_poison := false) -> (bool, APInt) {
    if v == NONE return false, .{};
    k := vkind(v);
    if k == .C_INT return true, const_ap(v);
    if is_vector_type(vtype(v)) && is_constant_kind(k) {
        s := get_splat_value(v, allow_poison);
        if s != NONE && vkind(s) == .C_INT return true, const_ap(s);
    }
    no: APInt;
    return false, no;
}
// m_APIntAllowPoison
pm_apint_ap :: (v: Value_Id) -> (bool, APInt) { ok, c := pm_apint(v, true); return ok, c; }
// m_ConstantInt() (isa<ConstantInt>)
pm_constant_int :: (v: Value_Id) -> bool { return v != NONE && vkind(v) == .C_INT; }
// m_ConstantInt(uint64_t &V): a ConstantInt whose value fits in 64 bits
pm_constant_int_u64 :: (v: Value_Id) -> (bool, u64) {
    if v == NONE return false, 0;
    if vkind(v) != .C_INT return false, 0;
    a := const_ap(v);
    if ap_active_bits(a) > 64 return false, 0;
    return true, ap_zext_value(a);
}

// cstval_pred_ty<Predicate, ConstantInt, AllowPoison>::match
pm_int_pred :: (v: Value_Id, pred: (APInt) -> bool, allow_poison := true) -> bool {
    if v == NONE return false;
    k := vkind(v);
    if k == .C_INT return pred(const_ap(v));
    t := vtype(v);
    if !is_vector_type(t) || !is_constant_kind(k) return false;
    s := get_splat_value(v);
    if s != NONE return vkind(s) == .C_INT && pred(const_ap(s));
    if type_kind(t) != .VECTOR return false;
    n := type_count(t);
    has_non_poison := false;
    for i: 0..cast(s64) n - 1 {
        e := cf_elt(v, cast(u64) i);
        if e == NONE return false;
        if allow_poison && vkind(e) == .C_POISON continue;
        if vkind(e) != .C_INT || !pred(const_ap(e)) return false;
        has_non_poison = true;
    }
    return has_non_poison;
}
// api_pred_ty: scalar or poison-allowing splat, binding the value
pm_apint_pred :: (v: Value_Id, pred: (APInt) -> bool) -> (bool, APInt) {
    if v == NONE return false, .{};
    k := vkind(v);
    if k == .C_INT { a := const_ap(v); if pred(a) return true, a; }
    else if is_vector_type(vtype(v)) && is_constant_kind(k) {
        s := get_splat_value(v, true);
        if s != NONE && vkind(s) == .C_INT { a := const_ap(s); if pred(a) return true, a; }
    }
    no: APInt;
    return false, no;
}

// m_Zero: any null constant or a vector of zero ints (poison allowed)
pm_zero :: (v: Value_Id) -> bool {
    if v == NONE return false;
    if !is_constant_kind(vkind(v)) return false;
    return is_null_value(v) || pm_int_pred(v, ap_is_zero);
}
pm_zero_int :: (v: Value_Id) -> bool { return pm_int_pred(v, ap_is_zero); }
pm_one :: (v: Value_Id) -> bool { return pm_int_pred(v, ap_is_one); }
pm_all_ones :: (v: Value_Id) -> bool { return pm_int_pred(v, ap_is_all_ones); }
pm_all_ones_forbid_poison :: (v: Value_Id) -> bool { return pm_int_pred(v, ap_is_all_ones, false); }
pm_non_zero_int :: (v: Value_Id) -> bool { return pm_int_pred(v, (a: APInt) -> bool { return !ap_is_zero(a); }); }
pm_power2 :: (v: Value_Id) -> bool { return pm_int_pred(v, ap_is_power_of_2); }
pm_power2_or_zero :: (v: Value_Id) -> bool { return pm_int_pred(v, (a: APInt) -> bool { return ap_is_zero(a) || ap_is_power_of_2(a); }); }
pm_negated_power2 :: (v: Value_Id) -> bool { return pm_int_pred(v, ap_is_negated_power_of_2); }
pm_sign_mask :: (v: Value_Id) -> bool { return pm_int_pred(v, ap_is_min_signed); }
pm_max_signed_value :: (v: Value_Id) -> bool { return pm_int_pred(v, ap_is_max_signed); }
pm_negative :: (v: Value_Id) -> bool { return pm_int_pred(v, ap_is_negative); }
pm_non_negative :: (v: Value_Id) -> bool { return pm_int_pred(v, ap_is_non_negative); }
pm_strictly_positive :: (v: Value_Id) -> bool { return pm_int_pred(v, ap_is_strictly_positive); }
pm_non_positive :: (v: Value_Id) -> bool { return pm_int_pred(v, ap_is_non_positive); }
pm_low_bit_mask :: (v: Value_Id) -> bool { return pm_int_pred(v, ap_is_mask); }
pm_low_bit_mask_or_zero :: (v: Value_Id) -> bool { return pm_int_pred(v, (a: APInt) -> bool { return ap_is_zero(a) || ap_is_mask(a); }); }
pm_shifted_mask :: (v: Value_Id) -> bool { return pm_int_pred(v, ap_is_shifted_mask); }
pm_any_integral_constant :: (v: Value_Id) -> bool { return pm_int_pred(v, (a: APInt) -> bool { return true; }); }
pm_power2_ap :: (v: Value_Id) -> (bool, APInt) { ok, c := pm_apint_pred(v, ap_is_power_of_2); return ok, c; }
pm_negative_ap :: (v: Value_Id) -> (bool, APInt) { ok, c := pm_apint_pred(v, ap_is_negative); return ok, c; }
pm_low_bit_mask_ap :: (v: Value_Id) -> (bool, APInt) { ok, c := pm_apint_pred(v, ap_is_mask); return ok, c; }
pm_max_signed_value_ap :: (v: Value_Id) -> (bool, APInt) { ok, c := pm_apint_pred(v, ap_is_max_signed); return ok, c; }
// m_SpecificInt(V): a constant (splat/vector, poison allowed) equal to V
pm_specific_int :: (v: Value_Id, val: u64) -> bool {
    if v == NONE return false;
    k := vkind(v);
    if k == .C_INT { a := const_ap(v); return ap_active_bits(a) <= 64 && ap_zext_value(a) == val; }
    if !is_vector_type(vtype(v)) || !is_constant_kind(k) return false;
    s := get_splat_value(v, true);
    if s != NONE && vkind(s) == .C_INT { a := const_ap(s); return ap_active_bits(a) <= 64 && ap_zext_value(a) == val; }
    return false;
}
pm_specific_int_ap :: (v: Value_Id, val: APInt) -> bool {
    if v == NONE return false;
    k := vkind(v);
    if k == .C_INT { a := const_ap(v); return a.bits == val.bits && ap_eq(a, val); }
    if !is_vector_type(vtype(v)) || !is_constant_kind(k) return false;
    s := get_splat_value(v, true);
    if s != NONE && vkind(s) == .C_INT { a := const_ap(s); return a.bits == val.bits && ap_eq(a, val); }
    return false;
}

// m_Undef: UndefValue (incl. poison) or an aggregate made only of undef/poison
pm_undef :: (v: Value_Id) -> bool {
    if v == NONE return false;
    k := vkind(v);
    if k == .C_UNDEF || k == .C_POISON return true;
    if k == .C_ARRAY || k == .C_STRUCT || k == .C_VECTOR {
        n := nops(v);
        for i: 0..cast(s64) n - 1 if !pm_undef(op(v, cast(u32) i)) return false;
        return true;
    }
    return false;
}
pm_undef_value :: inline (v: Value_Id) -> bool { if v == NONE return false; k := vkind(v); return k == .C_UNDEF || k == .C_POISON; }   // isa<UndefValue>
pm_poison :: inline (v: Value_Id) -> bool { return v != NONE && vkind(v) == .C_POISON; }

// m_ImmConstant: a constant that is not and does not contain a constant expression
pm_imm_constant :: (v: Value_Id) -> bool {
    if v == NONE return false;
    if !is_constant_kind(vkind(v)) return false;
    return !contains_constant_expression(v) && vkind(v) != .C_EXPR;
}
contains_constant_expression :: (c: Value_Id) -> bool {
    k := vkind(c);
    if k == .C_EXPR return true;
    if k == .C_VECTOR { n := nops(c); for i: 0..cast(s64) n - 1 if contains_constant_expression(op(c, cast(u32) i)) return true; }
    return false;
}

// ---------------------------------------------------------------- APFloat constants

APFloat :: struct {
    k: Type_Kind;
    w: [2] u64;
}
apf_from_const :: (c: Value_Id) -> APFloat {
    r: APFloat;
    r.k = type_kind(scalar_type(vtype(c)));
    ws := const_fp_value(c);
    for ws if it_index < 2 r.w[it_index] = it;
    return r;
}
apf_words :: (f: *APFloat) -> [] u64 { s: [] u64; s.data = f.w.data; s.count = words_for_bits(cast(u32) fp_type_bits(f.k)); return s; }
fp_type_bits :: (k: Type_Kind) -> s32 { p, mx, mn, b := fp_semantics(k); return b; }
apf_category :: (f: APFloat) -> Fp_Category { g := f; d := fp_decode(g.k, apf_words(*g)); return d.cat; }
apf_is_nan :: (f: APFloat) -> bool { return apf_category(f) == .NAN; }
apf_is_inf :: (f: APFloat) -> bool { return apf_category(f) == .INF; }
apf_is_zero :: (f: APFloat) -> bool { return apf_category(f) == .ZERO; }
apf_is_negative :: (f: APFloat) -> bool { g := f; d := fp_decode(g.k, apf_words(*g)); return d.neg; }
apf_is_finite :: (f: APFloat) -> bool { c := apf_category(f); return c == .ZERO || c == .NORMAL; }
apf_is_finite_non_zero :: (f: APFloat) -> bool { return apf_category(f) == .NORMAL; }
apf_is_pos_zero :: (f: APFloat) -> bool { return apf_is_zero(f) && !apf_is_negative(f); }
apf_is_neg_zero :: (f: APFloat) -> bool { return apf_is_zero(f) && apf_is_negative(f); }
apf_is_signaling :: (f: APFloat) -> bool { g := f; d := fp_decode(g.k, apf_words(*g)); return d.cat == .NAN && fp_is_signaling(g.k, d); }

// m_APFloat / m_APFloatAllowPoison
pm_apfloat :: (v: Value_Id, allow_poison := false) -> (bool, APFloat) {
    if v == NONE return false, .{};
    k := vkind(v);
    if k == .C_FP return true, apf_from_const(v);
    if is_vector_type(vtype(v)) && is_constant_kind(k) {
        s := get_splat_value(v, allow_poison);
        if s != NONE && vkind(s) == .C_FP return true, apf_from_const(s);
    }
    no: APFloat;
    return false, no;
}
// cstfp_pred_ty (poison allowed)
pm_fp_pred :: (v: Value_Id, pred: (APFloat) -> bool) -> bool {
    if v == NONE return false;
    k := vkind(v);
    if k == .C_FP return pred(apf_from_const(v));
    t := vtype(v);
    if !is_vector_type(t) || !is_constant_kind(k) return false;
    s := get_splat_value(v);
    if s != NONE return vkind(s) == .C_FP && pred(apf_from_const(s));
    if type_kind(t) != .VECTOR return false;
    n := type_count(t);
    has_non_poison := false;
    for i: 0..cast(s64) n - 1 {
        e := cf_elt(v, cast(u64) i);
        if e == NONE return false;
        if vkind(e) == .C_POISON continue;
        if vkind(e) != .C_FP || !pred(apf_from_const(e)) return false;
        has_non_poison = true;
    }
    return has_non_poison;
}
pm_any_zero_fp :: (v: Value_Id) -> bool { return pm_fp_pred(v, apf_is_zero); }
pm_pos_zero_fp :: (v: Value_Id) -> bool { return pm_fp_pred(v, apf_is_pos_zero); }
pm_neg_zero_fp :: (v: Value_Id) -> bool { return pm_fp_pred(v, apf_is_neg_zero); }
pm_nan :: (v: Value_Id) -> bool { return pm_fp_pred(v, apf_is_nan); }
pm_non_nan :: (v: Value_Id) -> bool { return pm_fp_pred(v, (f: APFloat) -> bool { return !apf_is_nan(f); }); }
pm_inf :: (v: Value_Id) -> bool { return pm_fp_pred(v, apf_is_inf); }
pm_non_inf :: (v: Value_Id) -> bool { return pm_fp_pred(v, (f: APFloat) -> bool { return !apf_is_inf(f); }); }
pm_finite :: (v: Value_Id) -> bool { return pm_fp_pred(v, apf_is_finite); }
pm_finite_non_zero :: (v: Value_Id) -> bool { return pm_fp_pred(v, apf_is_finite_non_zero); }
// m_FPOne = m_SpecificFP(1.0): a ConstantFP, or a vector constant whose getSplatValue() (no poison) is one
pm_fp_one :: (v: Value_Id) -> bool {
    if v == NONE return false;
    k := vkind(v);
    if k == .C_FP return apf_is_exactly_one(apf_from_const(v));
    if is_vector_type(vtype(v)) && is_constant_kind(k) {
        s := get_splat_value(v, false);
        return s != NONE && vkind(s) == .C_FP && apf_is_exactly_one(apf_from_const(s));
    }
    return false;
}
apf_is_exactly_one :: (f: APFloat) -> bool {
    g := f;
    one := fp_from_integer(g.k, .[1], 64, false);
    for apf_words(*g) if it != one[it_index] return false;
    return true;
}

// ---------------------------------------------------------------- operators

// m_BinOp<Opc>(m_Value(A), m_Value(B)). LLVM 23's BinaryOp_match / BinOpPred_match / AnyBinaryOp_match only match
// instructions (not constant expressions); OverflowingBinaryOp_match (m_NSWAdd, m_NSWNeg, ...) still does.
pm_binop :: (v: Value_Id, opc: Opcode) -> (bool, Value_Id, Value_Id) {
    if !is_inst(v) || inst_op(v) != opc return false, NONE, NONE;
    return true, op(v, 0), op(v, 1);
}
// m_c_<op>(m_Specific(X), m_Value(Y)): the other operand when one operand is x
pm_c_binop_with :: (v: Value_Id, opc: Opcode, x: Value_Id) -> (bool, Value_Id) {
    if !is_inst(v) || inst_op(v) != opc return false, NONE;
    a := op(v, 0); b := op(v, 1);
    if a == x return true, b;
    if b == x return true, a;
    return false, NONE;
}
// isa<BinaryOperator> (instructions only)
is_binary_operator :: (v: Value_Id) -> bool { return is_inst(v) && is_binary_op(inst_op(v)); }
// m_Not(m_Value(X)): xor X, -1 / xor -1, X
pm_not :: (v: Value_Id) -> (bool, Value_Id) {
    if !is_inst(v) || inst_op(v) != .XOR return false, NONE;
    a := op(v, 0); b := op(v, 1);
    if pm_all_ones(a) return true, b;
    if pm_all_ones(b) return true, a;
    return false, NONE;
}
pm_not_forbid_poison :: (v: Value_Id) -> (bool, Value_Id) {
    if !is_inst(v) || inst_op(v) != .XOR return false, NONE;
    a := op(v, 0); b := op(v, 1);
    if pm_all_ones_forbid_poison(a) return true, b;
    if pm_all_ones_forbid_poison(b) return true, a;
    return false, NONE;
}
// m_Neg(m_Value(X)): sub 0, X
pm_neg :: (v: Value_Id) -> (bool, Value_Id) {
    if !is_inst(v) || inst_op(v) != .SUB return false, NONE;
    if !pm_zero_int(op(v, 0)) return false, NONE;
    return true, op(v, 1);
}
pm_nsw_neg :: (v: Value_Id) -> (bool, Value_Id) {   // OverflowingBinaryOp_match: constant expressions too
    if opr_code(v) != .SUB || !pm_zero_int(op(v, 0)) return false, NONE;
    if (opr_flags(v) & F_NSW) != 0 return true, op(v, 1);
    return false, NONE;
}
// m_FNeg(m_Value(X)): fneg X, or fsub -0.0, X (fsub nsz 0.0, X)
pm_fneg :: (v: Value_Id) -> (bool, Value_Id) {
    o := opr_code(v);
    if o == .FNEG return true, op(v, 0);
    if o == .FSUB && is_inst(v) {
        a := op(v, 0);
        if (inst_fmf(v) & FMF_NSZ) != 0 { if pm_any_zero_fp(a) return true, op(v, 1); }
        else if pm_neg_zero_fp(a) return true, op(v, 1);
    }
    return false, NONE;
}
// m_AddLike(X, Y): add, or `or disjoint`
pm_add_like :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
    if !is_inst(v) return false, NONE, NONE;
    o := inst_op(v);
    if o == .ADD return true, op(v, 0), op(v, 1);
    if o == .OR && (opr_flags(v) & F_EXACT) != 0 return true, op(v, 0), op(v, 1);
    return false, NONE, NONE;
}
is_bool_ty :: (t: Type_Id) -> bool { st := scalar_type(t); return is_int_type(st) && type_int_width(st) == 1; }   // isIntOrIntVectorTy(1)
// m_LogicalAnd / m_LogicalOr: and/or of i1 (or vector of i1), or select c, x, false / select c, true, y
pm_logical_and :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
    if !is_inst(v) return false, NONE, NONE;
    o := inst_op(v);
    if !is_bool_ty(vtype(v)) return false, NONE, NONE;
    if o == .AND return true, op(v, 0), op(v, 1);
    if o == .SELECT {
        c := op(v, 0);
        if vtype(c) != vtype(v) return false, NONE, NONE;
        f := op(v, 2);
        if is_constant_kind(vkind(f)) && is_null_value(f) return true, c, op(v, 1);
    }
    return false, NONE, NONE;
}
pm_logical_or :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
    if !is_inst(v) return false, NONE, NONE;
    o := inst_op(v);
    if !is_bool_ty(vtype(v)) return false, NONE, NONE;
    if o == .OR return true, op(v, 0), op(v, 1);
    if o == .SELECT {
        c := op(v, 0);
        if vtype(c) != vtype(v) return false, NONE, NONE;
        t := op(v, 1);
        if is_constant_kind(vkind(t)) && is_one_value(t) return true, c, op(v, 2);
    }
    return false, NONE, NONE;
}
pm_logical_op :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
    ok, a, b := pm_logical_and(v);
    if ok return true, a, b;
    ok, a, b = pm_logical_or(v);
    return ok, a, b;
}
// Constant::isOneValue
is_one_value :: (c: Value_Id) -> bool {
    k := vkind(c);
    if k == .C_INT return ap_is_one(const_ap(c));
    if k == .C_FP return ap_is_one(ap_from_words(type_bits(scalar_type(vtype(c))), const_fp_value(c)));
    if is_vector_type(vtype(c)) { s := get_splat_value(c); if s != NONE return is_one_value(s); }
    return false;
}

// m_ElementWiseBitCast(m_Value(X)): bitcast with the same element count and scalar size
pm_elementwise_bitcast :: (v: Value_Id) -> (bool, Value_Id) {
    if opr_code(v) != .BITCAST return false, NONE;
    src := op(v, 0);
    st := vtype(src); dt := vtype(v);
    if is_vector_type(st) != is_vector_type(dt) return false, NONE;
    if is_vector_type(st) && (type_count(st) != type_count(dt) || type_kind(st) != type_kind(dt)) return false, NONE;
    if type_bits(scalar_type(st)) != type_bits(scalar_type(dt)) || type_bits(scalar_type(st)) == 0 return false, NONE;
    return true, src;
}
// m_ZExt / m_SExt / m_Trunc / m_PtrToInt ...: a cast Operator of that opcode
pm_cast :: (v: Value_Id, opc: Opcode) -> (bool, Value_Id) {
    if opr_code(v) != opc return false, NONE;
    return true, op(v, 0);
}
pm_zext_or_sext :: (v: Value_Id) -> (bool, Value_Id) {
    o := opr_code(v);
    if o == .ZEXT || o == .SEXT return true, op(v, 0);
    return false, NONE;
}
// m_ZExtOrSelf etc.
zext_or_self :: (v: Value_Id) -> Value_Id { if opr_code(v) == .ZEXT return op(v, 0); return v; }
sext_or_self :: (v: Value_Id) -> Value_Id { if opr_code(v) == .SEXT return op(v, 0); return v; }

// m_Intrinsic<ID>: an intrinsic call (instruction) with that id; args by call_arg
pm_intrinsic :: inline (v: Value_Id, id: Intrinsic_Id) -> bool { return call_iid(v) == id; }
// m_MaxOrMin: smax/smin/umax/umin intrinsic calls
is_min_max_intrinsic :: (id: Intrinsic_Id) -> bool { return id == IID_SMAX || id == IID_SMIN || id == IID_UMAX || id == IID_UMIN; }

// m_Select(m_Value(C), m_Value(T), m_Value(F)) (instructions only)
pm_select :: (v: Value_Id) -> (bool, Value_Id, Value_Id, Value_Id) {
    if !is_inst(v) || inst_op(v) != .SELECT return false, NONE, NONE, NONE;
    return true, op(v, 0), op(v, 1), op(v, 2);
}
// m_ICmp(Pred, m_Value(A), m_Value(B)) (instructions only): ok, pred, samesign, a, b
pm_icmp :: (v: Value_Id) -> (bool, u8, bool, Value_Id, Value_Id) {
    if !is_inst(v) || inst_op(v) != .ICMP return false, 0, false, NONE, NONE;
    return true, inst_pred(v), (inst(v).flags & F_EXACT) != 0, op(v, 0), op(v, 1);
}
pm_fcmp :: (v: Value_Id) -> (bool, u8, Value_Id, Value_Id) {
    if !is_inst(v) || inst_op(v) != .FCMP return false, 0, NONE, NONE;
    return true, inst_pred(v), op(v, 0), op(v, 1);
}
// isa<CmpInst>
is_cmp_inst :: (v: Value_Id) -> bool { return is_inst(v) && (inst_op(v) == .ICMP || inst_op(v) == .FCMP); }
// m_Shift / m_Shr / m_LogicalShift
is_shift_op :: (o: Opcode) -> bool { return o == .SHL || o == .LSHR || o == .ASHR; }
is_shr_op :: (o: Opcode) -> bool { return o == .LSHR || o == .ASHR; }
is_bitwise_logic_op :: (o: Opcode) -> bool { return o == .AND || o == .OR || o == .XOR; }

// m_c_SMin(m_Specific(X), m_Value()) etc.: a min/max intrinsic with x as an operand
pm_c_min_max_with :: (v: Value_Id, id: Intrinsic_Id, x: Value_Id) -> (bool, Value_Id) {
    if call_iid(v) != id return false, NONE;
    a := op(v, 0); b := op(v, 1);
    if a == x return true, b;
    if b == x return true, a;
    return false, NONE;
}
