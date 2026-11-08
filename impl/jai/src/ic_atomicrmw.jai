// InstCombineAtomicRMW.cpp, complete: isIdempotentRMW, isSaturating, visitAtomicRMWInst.
// The operation is Inst_Row.ord2, an index into parser.jai's RMW_OPS.

RMW_XCHG :: 0; RMW_ADD :: 1; RMW_SUB :: 2; RMW_AND :: 3; RMW_NAND :: 4; RMW_OR :: 5; RMW_XOR :: 6; RMW_MAX :: 7;
RMW_MIN :: 8; RMW_UMAX :: 9; RMW_UMIN :: 10; RMW_FADD :: 11; RMW_FSUB :: 12; RMW_FMAX :: 13; RMW_FMIN :: 14;

ic_rmw_is_idempotent :: (i: Value_Id) -> bool {
    v := op(i, 1);
    o := inst(i).ord2;
    if vkind(v) == .C_FP {
        ok, f := pm_apfloat(v);
        if !ok return false;
        if o == RMW_FADD return apf_is_zero(f) && apf_is_negative(f);
        if o == RMW_FSUB return apf_is_zero(f) && !apf_is_negative(f);
        return false;
    }
    if vkind(v) != .C_INT return false;
    c := const_ap(v);
    if o == {
        case RMW_ADD; #through; case RMW_SUB; #through; case RMW_OR; #through; case RMW_XOR; return ap_is_zero(c);
        case RMW_AND; return ap_is_all_ones(c);
        case RMW_MIN; return ap_is_max_signed(c);
        case RMW_MAX; return ap_is_min_signed(c);
        case RMW_UMIN; return ap_is_all_ones(c);
        case RMW_UMAX; return ap_is_zero(c);
    }
    return false;
}

ic_rmw_is_saturating :: (i: Value_Id) -> bool {
    v := op(i, 1);
    o := inst(i).ord2;
    if vkind(v) == .C_FP {
        ok, f := pm_apfloat(v);
        if !ok return false;
        if o == RMW_FMAX return !apf_is_negative(f) && apf_is_inf(f);
        if o == RMW_FMIN return apf_is_negative(f) && apf_is_inf(f);
        if o == RMW_FADD || o == RMW_FSUB return apf_is_nan(f);
        return false;
    }
    if vkind(v) != .C_INT return false;
    c := const_ap(v);
    if o == {
        case RMW_XCHG; return true;
        case RMW_OR; return ap_is_all_ones(c);
        case RMW_AND; return ap_is_zero(c);
        case RMW_MIN; return ap_is_min_signed(c);
        case RMW_MAX; return ap_is_max_signed(c);
        case RMW_UMIN; return ap_is_zero(c);
        case RMW_UMAX; return ap_is_all_ones(c);
    }
    return false;
}

// visitAtomicRMWInst
ic_visit_atomicrmw :: (i: Value_Id) -> Value_Id {
    if is_volatile(i) return NONE;
    if ic_rmw_is_saturating(i) && inst(i).ord2 != RMW_XCHG {
        inst(i).ord2 = RMW_XCHG;
        return i;
    }
    o := inst(i).ord2;
    if o == RMW_ADD || o == RMW_SUB {
        ok, x := pm_neg(op(i, 1));
        if ok {
            inst(i).ord2 = ifx o == RMW_ADD then cast(u8) RMW_SUB else RMW_ADD;
            return ic_replace_operand(i, 1, x);
        }
    }
    if !ic_rmw_is_idempotent(i) return NONE;
    ty := vtype(i);
    if type_kind(ty) == .INT && inst(i).ord2 != RMW_OR {
        inst(i).ord2 = RMW_OR;
        return ic_replace_operand(i, 1, const_int(ty, 0));
    } else if is_fp_type(ty) && inst(i).ord2 != RMW_FADD {
        inst(i).ord2 = RMW_FADD;
        return ic_replace_operand(i, 1, const_fp_words(ty, fp_zero(type_kind(ty), true)));
    }
    return NONE;
}
