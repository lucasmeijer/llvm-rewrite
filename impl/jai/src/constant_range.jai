// ConstantRange: a port of llvm/include/llvm/IR/ConstantRange.h and llvm/lib/IR/ConstantRange.cpp
// (the operations ValueTracking, InstructionSimplify and ConstantFolding use). Values, like APInt.

Const_Range :: struct {
    lo: APInt;
    hi: APInt;
}

Preferred_Range :: enum u8 { SMALLEST; UNSIGNED; SIGNED; }

cr_full :: (bits: u32) -> Const_Range { r: Const_Range; r.lo = ap_all_ones(bits); r.hi = r.lo; return r; }
cr_empty :: (bits: u32) -> Const_Range { r: Const_Range; r.lo = ap_zero(bits); r.hi = r.lo; return r; }
cr_new :: (lo: APInt, hi: APInt) -> Const_Range {
    assert(lo.bits == hi.bits);
    assert(!ap_eq(lo, hi) || ap_is_all_ones(lo) || ap_is_zero(lo), "ConstantRange: Lower == Upper, but not min or max");
    r: Const_Range; r.lo = lo; r.hi = hi; return r;
}
cr_single :: (v: APInt) -> Const_Range { return cr_new(v, ap_add_u64(v, 1)); }
cr_non_empty :: (lo: APInt, hi: APInt) -> Const_Range { if ap_eq(lo, hi) return cr_full(lo.bits); return cr_new(lo, hi); }
cr_bits :: inline (r: Const_Range) -> u32 { return r.lo.bits; }
cr_eq :: (a: Const_Range, b: Const_Range) -> bool { return ap_eq(a.lo, b.lo) && ap_eq(a.hi, b.hi); }

cr_is_full_set :: (r: Const_Range) -> bool { return ap_eq(r.lo, r.hi) && ap_is_all_ones(r.lo); }
cr_is_empty_set :: (r: Const_Range) -> bool { return ap_eq(r.lo, r.hi) && ap_is_zero(r.lo); }
cr_is_wrapped_set :: (r: Const_Range) -> bool { return ap_ugt(r.lo, r.hi) && !ap_is_zero(r.hi); }
cr_is_upper_wrapped :: (r: Const_Range) -> bool { return ap_ugt(r.lo, r.hi); }
cr_is_sign_wrapped_set :: (r: Const_Range) -> bool { return ap_sgt(r.lo, r.hi) && !ap_is_min_signed(r.hi); }
cr_is_upper_sign_wrapped :: (r: Const_Range) -> bool { return ap_sgt(r.lo, r.hi); }
cr_single_element :: (r: Const_Range) -> (bool, APInt) {
    if ap_eq(r.hi, ap_add_u64(r.lo, 1)) return true, r.lo;
    return false, r.lo;
}
cr_is_single_element :: (r: Const_Range) -> bool { ok, _ := cr_single_element(r); return ok; }
cr_single_missing_element :: (r: Const_Range) -> (bool, APInt) {
    if ap_eq(r.lo, ap_add_u64(r.hi, 1)) return true, r.hi;
    return false, r.hi;
}
cr_is_size_strictly_smaller_than :: (a: Const_Range, b: Const_Range) -> bool {
    if cr_is_full_set(a) return false;
    if cr_is_full_set(b) return true;
    return ap_ult(ap_sub(a.hi, a.lo), ap_sub(b.hi, b.lo));
}
cr_is_size_larger_than :: (r: Const_Range, max_size: u64) -> bool {
    if cr_is_full_set(r) return max_size == 0 || ap_ugt_u64(ap_all_ones(cr_bits(r)), max_size - 1);
    return ap_ugt_u64(ap_sub(r.hi, r.lo), max_size);
}
cr_is_all_negative :: (r: Const_Range) -> bool {
    if cr_is_empty_set(r) return true;
    if cr_is_full_set(r) return false;
    return !cr_is_upper_sign_wrapped(r) && !ap_is_strictly_positive(r.hi);
}
cr_is_all_non_negative :: (r: Const_Range) -> bool { return !cr_is_sign_wrapped_set(r) && ap_is_non_negative(r.lo); }
cr_is_all_positive :: (r: Const_Range) -> bool {
    if cr_is_empty_set(r) return true;
    if cr_is_full_set(r) return false;
    return !cr_is_sign_wrapped_set(r) && ap_is_strictly_positive(r.lo);
}
cr_umax :: (r: Const_Range) -> APInt {
    if cr_is_full_set(r) || cr_is_upper_wrapped(r) return ap_all_ones(cr_bits(r));
    return ap_sub_u64(r.hi, 1);
}
cr_umin :: (r: Const_Range) -> APInt {
    if cr_is_full_set(r) || cr_is_wrapped_set(r) return ap_zero(cr_bits(r));
    return r.lo;
}
cr_smax :: (r: Const_Range) -> APInt {
    if cr_is_full_set(r) || cr_is_upper_sign_wrapped(r) return ap_signed_max(cr_bits(r));
    return ap_sub_u64(r.hi, 1);
}
cr_smin :: (r: Const_Range) -> APInt {
    if cr_is_full_set(r) || cr_is_sign_wrapped_set(r) return ap_signed_min(cr_bits(r));
    return r.lo;
}
cr_contains :: (r: Const_Range, v: APInt) -> bool {
    if ap_eq(r.lo, r.hi) return cr_is_full_set(r);
    if !cr_is_upper_wrapped(r) return ap_ule(r.lo, v) && ap_ult(v, r.hi);
    return ap_ule(r.lo, v) || ap_ult(v, r.hi);
}
cr_contains_range :: (r: Const_Range, o: Const_Range) -> bool {
    if cr_is_full_set(r) || cr_is_empty_set(o) return true;
    if cr_is_empty_set(r) || cr_is_full_set(o) return false;
    if !cr_is_upper_wrapped(r) {
        if cr_is_upper_wrapped(o) return false;
        return ap_ule(r.lo, o.lo) && ap_ule(o.hi, r.hi);
    }
    if !cr_is_upper_wrapped(o) return ap_ule(o.hi, r.hi) || ap_ule(r.lo, o.lo);
    return ap_ule(o.hi, r.hi) && ap_ule(r.lo, o.lo);
}
cr_active_bits :: (r: Const_Range) -> u32 { if cr_is_empty_set(r) return 0; return ap_active_bits(cr_umax(r)); }
cr_min_signed_bits :: (r: Const_Range) -> u32 {
    if cr_is_empty_set(r) return 0;
    return max(ap_min_signed_bits(cr_smin(r)), ap_min_signed_bits(cr_smax(r)));
}
cr_subtract :: (r: Const_Range, v: APInt) -> Const_Range {
    if ap_eq(r.lo, r.hi) return r;
    return cr_new(ap_sub(r.lo, v), ap_sub(r.hi, v));
}
cr_inverse :: (r: Const_Range) -> Const_Range {
    if cr_is_full_set(r) return cr_empty(cr_bits(r));
    if cr_is_empty_set(r) return cr_full(cr_bits(r));
    return cr_new(r.hi, r.lo);
}
cr_difference :: (a: Const_Range, b: Const_Range) -> Const_Range { return cr_intersect(a, cr_inverse(b)); }

// ConstantRange::fromKnownBits
cr_from_known_bits :: (k: Known_Bits, is_signed: bool) -> Const_Range {
    bw := kb_bits(k);
    if kb_has_conflict(k) return cr_empty(bw);
    if kb_is_unknown(k) return cr_full(bw);
    if !is_signed || kb_is_negative(k) || kb_is_non_negative(k) return cr_new(kb_min_value(k), ap_add_u64(kb_max_value(k), 1));
    lo := ap_copy(kb_min_value(k)); hi := kb_max_value(k);
    ap_set_sign_bit(*lo); ap_clear_sign_bit(*hi);
    return cr_new(lo, ap_add_u64(hi, 1));
}
// ConstantRange::toKnownBits
cr_to_known_bits :: (r: Const_Range) -> Known_Bits {
    bw := cr_bits(r);
    if cr_is_empty_set(r) return kb_new(bw);
    mn := cr_umin(r); mx := cr_umax(r);
    k := kb_from_const(mn);
    d := ap_xor(mn, mx);
    if !ap_is_zero(d) {
        msb := bw - 1 - ap_clz(d);
        ap_clear_low_bits(*k.zero, msb + 1);
        ap_clear_low_bits(*k.one, msb + 1);
    }
    return k;
}
cr_split_pos_neg :: (r: Const_Range) -> (Const_Range, Const_Range) {
    bw := cr_bits(r);
    smin := ap_signed_min(bw);
    pos := ifx bw == 1 then cr_empty(bw) else cr_new(ap_one(bw), smin);
    neg := cr_new(smin, ap_zero(bw));
    return cr_intersect(r, pos), cr_intersect(r, neg);
}


cr_allowed_icmp_region :: (pred: u8, r: Const_Range) -> Const_Range {
    if cr_is_empty_set(r) return r;
    w := cr_bits(r);
    if pred == {
        case ICMP_EQ; return r;
        case ICMP_NE;
            if cr_is_single_element(r) return cr_new(r.hi, r.lo);
            return cr_full(w);
        case ICMP_ULT;
            umax := cr_umax(r);
            if ap_is_zero(umax) return cr_empty(w);
            return cr_new(ap_zero(w), umax);
        case ICMP_SLT;
            smax := cr_smax(r);
            if ap_is_min_signed(smax) return cr_empty(w);
            return cr_new(ap_signed_min(w), smax);
        case ICMP_ULE; return cr_non_empty(ap_zero(w), ap_add_u64(cr_umax(r), 1));
        case ICMP_SLE; return cr_non_empty(ap_signed_min(w), ap_add_u64(cr_smax(r), 1));
        case ICMP_UGT;
            umin := cr_umin(r);
            if ap_is_all_ones(umin) return cr_empty(w);
            return cr_new(ap_add_u64(umin, 1), ap_zero(w));
        case ICMP_SGT;
            smin := cr_smin(r);
            if ap_is_max_signed(smin) return cr_empty(w);
            return cr_new(ap_add_u64(smin, 1), ap_signed_min(w));
        case ICMP_UGE; return cr_non_empty(cr_umin(r), ap_zero(w));
        case ICMP_SGE; return cr_non_empty(cr_smin(r), ap_signed_min(w));
    }
    fatal("internal: invalid icmp predicate % in makeAllowedICmpRegion", pred);
    return r;
}
// makeAllowedICmpRegion(CmpPredicate): with samesign, also intersect with the signed predicate's region
cr_allowed_icmp_region_ss :: (pred: u8, samesign: bool, r: Const_Range) -> Const_Range {
    res := cr_allowed_icmp_region(pred, r);
    if !samesign return res;
    return cr_intersect(res, cr_allowed_icmp_region(icmp_preferred_signed_predicate(pred), r));
}
cr_satisfying_icmp_region :: (pred: u8, r: Const_Range) -> Const_Range {
    return cr_inverse(cr_allowed_icmp_region(icmp_inverse(pred), r));
}
cr_exact_icmp_region :: (pred: u8, c: APInt) -> Const_Range { return cr_allowed_icmp_region(pred, cr_single(c)); }

cr_insensitive_to_signedness :: (a: Const_Range, b: Const_Range) -> bool {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return true;
    return (cr_is_all_non_negative(a) && cr_is_all_non_negative(b)) || (cr_is_all_negative(a) && cr_is_all_negative(b));
}
cr_insensitive_to_signedness_inverted :: (a: Const_Range, b: Const_Range) -> bool {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return true;
    return (cr_is_all_non_negative(a) && cr_is_all_negative(b)) || (cr_is_all_negative(a) && cr_is_all_non_negative(b));
}
// getEquivalentPredWithFlippedSignedness
cr_equivalent_pred_flipped_signedness :: (pred: u8, a: Const_Range, b: Const_Range) -> u8 {
    flipped := icmp_flipped_signedness(pred);
    if cr_insensitive_to_signedness(a, b) return flipped;
    if cr_insensitive_to_signedness_inverted(a, b) return icmp_inverse(flipped);
    return BAD_ICMP_PREDICATE;
}
// getEquivalentICmp(Pred, RHS, Offset)
cr_equivalent_icmp :: (r: Const_Range) -> (pred: u8, rhs: APInt, offset: APInt) {
    bw := cr_bits(r);
    offset := ap_zero(bw);
    if cr_is_full_set(r) || cr_is_empty_set(r) {
        return xx ifx cr_is_empty_set(r) then ICMP_ULT else ICMP_UGE, ap_zero(bw), offset;
    }
    ok, e := cr_single_element(r);
    if ok return ICMP_EQ, e, offset;
    ok2, m := cr_single_missing_element(r);
    if ok2 return ICMP_NE, m, offset;
    if ap_is_min_signed(r.lo) || ap_is_zero(r.lo) return xx ifx ap_is_min_signed(r.lo) then ICMP_SLT else ICMP_ULT, r.hi, offset;
    if ap_is_min_signed(r.hi) || ap_is_zero(r.hi) return xx ifx ap_is_min_signed(r.hi) then ICMP_SGE else ICMP_UGE, r.lo, offset;
    return ICMP_ULT, ap_sub(r.hi, r.lo), ap_neg(r.lo);
}
// ConstantRange::icmp: does the predicate hold for all pairs?
cr_icmp :: (a: Const_Range, pred: u8, b: Const_Range) -> bool {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return true;
    if pred == {
        case ICMP_EQ;
            ok1, l := cr_single_element(a); ok2, r := cr_single_element(b);
            if ok1 && ok2 return ap_eq(l, r);
            return false;
        case ICMP_NE; return cr_contains_range(cr_inverse(a), b);
        case ICMP_ULT; return ap_ult(cr_umax(a), cr_umin(b));
        case ICMP_ULE; return ap_ule(cr_umax(a), cr_umin(b));
        case ICMP_UGT; return ap_ugt(cr_umin(a), cr_umax(b));
        case ICMP_UGE; return ap_uge(cr_umin(a), cr_umax(b));
        case ICMP_SLT; return ap_slt(cr_smax(a), cr_smin(b));
        case ICMP_SLE; return ap_sle(cr_smax(a), cr_smin(b));
        case ICMP_SGT; return ap_sgt(cr_smin(a), cr_smax(b));
        case ICMP_SGE; return ap_sge(cr_smin(a), cr_smax(b));
    }
    fatal("internal: invalid icmp predicate in ConstantRange::icmp");
    return false;
}

cr_exact_mul_nuw_region :: (v: APInt) -> Const_Range {
    bw := v.bits;
    if ap_is_zero(v) return cr_full(bw);
    return cr_non_empty(ap_rounding_udiv(ap_zero(bw), v, .UP), ap_add_u64(ap_rounding_udiv(ap_all_ones(bw), v, .DOWN), 1));
}
cr_exact_mul_nsw_region :: (v: APInt) -> Const_Range {
    bw := v.bits;
    if ap_is_zero(v) return cr_full(bw);
    mn := ap_signed_min(bw); mx := ap_signed_max(bw);
    if ap_is_all_ones(v) return cr_new(ap_neg(mx), mn);
    lo, hi: APInt;
    if ap_is_negative(v) { lo = ap_rounding_sdiv(mx, v, .UP); hi = ap_rounding_sdiv(mn, v, .DOWN); }
    else { lo = ap_rounding_sdiv(mn, v, .UP); hi = ap_rounding_sdiv(mx, v, .DOWN); }
    return cr_non_empty(lo, ap_add_u64(hi, 1));
}
// makeGuaranteedNoWrapRegion (nuw: unsigned = true)
cr_guaranteed_no_wrap_region :: (opc: Opcode, o: Const_Range, unsigned: bool) -> Const_Range {
    bw := cr_bits(o);
    if opc == {
        case .ADD;
            if unsigned return cr_non_empty(ap_zero(bw), ap_neg(cr_umax(o)));
            smv := ap_signed_min(bw);
            smin := cr_smin(o); smax := cr_smax(o);
            return cr_non_empty(ifx ap_is_negative(smin) then ap_sub(smv, smin) else smv,
                                ifx ap_is_strictly_positive(smax) then ap_sub(smv, smax) else smv);
        case .SUB;
            if unsigned return cr_non_empty(cr_umax(o), ap_zero(bw));
            smv := ap_signed_min(bw);
            smin := cr_smin(o); smax := cr_smax(o);
            return cr_non_empty(ifx ap_is_strictly_positive(smax) then ap_add(smv, smax) else smv,
                                ifx ap_is_negative(smin) then ap_add(smv, smin) else smv);
        case .MUL;
            if unsigned return cr_exact_mul_nuw_region(cr_umax(o));
            ok, c := cr_single_element(o);
            if ok return cr_exact_mul_nsw_region(c);
            return cr_intersect(cr_exact_mul_nsw_region(cr_smin(o)), cr_exact_mul_nsw_region(cr_smax(o)));
        case .SHL;
            sh := cr_intersect(o, cr_new(ap_zero(bw), ap_from_u64(bw, bw)));
            if cr_is_empty_set(sh) return cr_full(bw);
            umax := cr_umax(sh);
            if unsigned return cr_non_empty(ap_zero(bw), ap_add_u64(ap_lshr_ap(ap_all_ones(bw), umax), 1));
            return cr_non_empty(ap_ashr_ap(ap_signed_min(bw), umax), ap_add_u64(ap_ashr_ap(ap_signed_max(bw), umax), 1));
    }
    fatal("internal: unsupported binary op in makeGuaranteedNoWrapRegion");
    return o;
}
cr_make_mask_not_equal_range :: (mask: APInt, c: APInt) -> Const_Range {
    bw := mask.bits;
    if !ap_eq(ap_and(mask, c), c) return cr_full(bw);
    if ap_is_zero(mask) return cr_empty(bw);
    return cr_non_empty(ap_add(ap_one_bit_set(bw, ap_ctz(mask)), c), c);
}

cr_preferred :: (a: Const_Range, b: Const_Range, t: Preferred_Range) -> Const_Range {
    if t == .UNSIGNED {
        if !cr_is_wrapped_set(a) && cr_is_wrapped_set(b) return a;
        if cr_is_wrapped_set(a) && !cr_is_wrapped_set(b) return b;
    } else if t == .SIGNED {
        if !cr_is_sign_wrapped_set(a) && cr_is_sign_wrapped_set(b) return a;
        if cr_is_sign_wrapped_set(a) && !cr_is_sign_wrapped_set(b) return b;
    }
    if cr_is_size_strictly_smaller_than(a, b) return a;
    return b;
}

cr_intersect :: (a: Const_Range, cr: Const_Range, t := Preferred_Range.SMALLEST) -> Const_Range {
    if cr_is_empty_set(a) || cr_is_full_set(cr) return a;
    if cr_is_empty_set(cr) || cr_is_full_set(a) return cr;
    if !cr_is_upper_wrapped(a) && cr_is_upper_wrapped(cr) return cr_intersect(cr, a, t);
    if !cr_is_upper_wrapped(a) && !cr_is_upper_wrapped(cr) {
        if ap_ult(a.lo, cr.lo) {
            if ap_ule(a.hi, cr.lo) return cr_empty(cr_bits(a));
            if ap_ult(a.hi, cr.hi) return cr_new(cr.lo, a.hi);
            return cr;
        }
        if ap_ult(a.hi, cr.hi) return a;
        if ap_ult(a.lo, cr.hi) return cr_new(a.lo, cr.hi);
        return cr_empty(cr_bits(a));
    }
    if cr_is_upper_wrapped(a) && !cr_is_upper_wrapped(cr) {
        if ap_ult(cr.lo, a.hi) {
            if ap_ult(cr.hi, a.hi) return cr;
            if ap_ule(cr.hi, a.lo) return cr_new(cr.lo, a.hi);
            return cr_preferred(a, cr, t);
        }
        if ap_ult(cr.lo, a.lo) {
            if ap_ule(cr.hi, a.lo) return cr_empty(cr_bits(a));
            return cr_new(a.lo, cr.hi);
        }
        return cr;
    }
    if ap_ult(cr.hi, a.hi) {
        if ap_ult(cr.lo, a.hi) return cr_preferred(a, cr, t);
        if ap_ult(cr.lo, a.lo) return cr_new(a.lo, cr.hi);
        return cr;
    }
    if ap_ule(cr.hi, a.lo) {
        if ap_ult(cr.lo, a.lo) return a;
        return cr_new(cr.lo, a.hi);
    }
    return cr_preferred(a, cr, t);
}

cr_union :: (a: Const_Range, cr: Const_Range, t := Preferred_Range.SMALLEST) -> Const_Range {
    if cr_is_full_set(a) || cr_is_empty_set(cr) return a;
    if cr_is_full_set(cr) || cr_is_empty_set(a) return cr;
    if !cr_is_upper_wrapped(a) && cr_is_upper_wrapped(cr) return cr_union(cr, a, t);
    if !cr_is_upper_wrapped(a) && !cr_is_upper_wrapped(cr) {
        if ap_ult(cr.hi, a.lo) || ap_ult(a.hi, cr.lo)
            return cr_preferred(cr_new(a.lo, cr.hi), cr_new(cr.lo, a.hi), t);
        l := ifx ap_ult(cr.lo, a.lo) then cr.lo else a.lo;
        u := ifx ap_ugt(ap_sub_u64(cr.hi, 1), ap_sub_u64(a.hi, 1)) then cr.hi else a.hi;
        if ap_is_zero(l) && ap_is_zero(u) return cr_full(cr_bits(a));
        return cr_new(l, u);
    }
    if !cr_is_upper_wrapped(cr) {
        if ap_ule(cr.hi, a.hi) || ap_uge(cr.lo, a.lo) return a;
        if ap_ule(cr.lo, a.hi) && ap_ule(a.lo, cr.hi) return cr_full(cr_bits(a));
        if ap_ult(a.hi, cr.lo) && ap_ult(cr.hi, a.lo)
            return cr_preferred(cr_new(a.lo, cr.hi), cr_new(cr.lo, a.hi), t);
        if ap_ult(a.hi, cr.lo) && ap_ule(a.lo, cr.hi) return cr_new(cr.lo, a.hi);
        return cr_new(a.lo, cr.hi);
    }
    if ap_ule(cr.lo, a.hi) || ap_ule(a.lo, cr.hi) return cr_full(cr_bits(a));
    l := ifx ap_ult(cr.lo, a.lo) then cr.lo else a.lo;
    u := ifx ap_ugt(cr.hi, a.hi) then cr.hi else a.hi;
    return cr_new(l, u);
}
cr_exact_intersect :: (a: Const_Range, b: Const_Range) -> (bool, Const_Range) {
    r := cr_intersect(a, b);
    if cr_eq(r, cr_inverse(cr_union(cr_inverse(a), cr_inverse(b)))) return true, r;
    return false, r;
}
cr_exact_union :: (a: Const_Range, b: Const_Range) -> (bool, Const_Range) {
    r := cr_union(a, b);
    if cr_eq(r, cr_inverse(cr_intersect(cr_inverse(a), cr_inverse(b)))) return true, r;
    return false, r;
}

cr_cast_op :: (r: Const_Range, opc: Opcode, rbits: u32) -> Const_Range {
    if opc == {
        case .TRUNC; return cr_truncate(r, rbits);
        case .SEXT; return cr_sign_extend(r, rbits);
        case .ZEXT; return cr_zero_extend(r, rbits);
        case .BITCAST; return r;
        case .FPTOUI; #through;
        case .FPTOSI; if cr_bits(r) == rbits return r; return cr_full(rbits);
        case .UITOFP;
            bw := cr_bits(r);
            mn := ap_zero(bw); mx := ap_all_ones(bw);
            if rbits > bw { mn = ap_zext(mn, rbits); mx = ap_zext(mx, rbits); }
            return cr_non_empty(mn, ap_add_u64(mx, 1));
        case .SITOFP;
            bw := cr_bits(r);
            mn := ap_signed_min(bw); mx := ap_signed_max(bw);
            if rbits > bw { mn = ap_sext(mn, rbits); mx = ap_sext(mx, rbits); }
            return cr_non_empty(mn, ap_add_u64(mx, 1));
    }
    return cr_full(rbits);
}
cr_zero_extend :: (r: Const_Range, dst: u32) -> Const_Range {
    if cr_is_empty_set(r) return cr_empty(dst);
    src := cr_bits(r);
    if dst == src return r;
    if cr_is_full_set(r) || cr_is_upper_wrapped(r) {
        lo := ap_zero(dst);
        if ap_is_zero(r.hi) lo = ap_zext(r.lo, dst);
        return cr_new(lo, ap_one_bit_set(dst, src));
    }
    return cr_new(ap_zext(r.lo, dst), ap_zext(r.hi, dst));
}
cr_sign_extend :: (r: Const_Range, dst: u32) -> Const_Range {
    if cr_is_empty_set(r) return cr_empty(dst);
    src := cr_bits(r);
    if dst == src return r;
    if ap_is_min_signed(r.hi) return cr_new(ap_sext(r.lo, dst), ap_zext(r.hi, dst));
    if cr_is_full_set(r) || cr_is_sign_wrapped_set(r)
        return cr_new(ap_high_bits_set(dst, dst - src + 1), ap_add_u64(ap_low_bits_set(dst, src - 1), 1));
    return cr_new(ap_sext(r.lo, dst), ap_sext(r.hi, dst));
}
cr_truncate :: (r: Const_Range, dst: u32, nuw := false) -> Const_Range {
    bw := cr_bits(r);
    if dst == bw return r;
    if cr_is_empty_set(r) return cr_empty(dst);
    if cr_is_full_set(r) return cr_full(dst);
    lower_div := r.lo; upper_div := r.hi;
    union_r := cr_empty(dst);
    if cr_is_upper_wrapped(r) {
        if ap_active_bits(r.hi) > dst return cr_full(dst);
        if nuw {
            union_r = cr_new(ap_zero(dst), ap_trunc(r.hi, dst));
            upper_div = ap_one_bit_set(bw, dst);
        } else {
            if ap_cto(r.hi) == dst return cr_full(dst);
            union_r = cr_new(ap_all_ones(dst), ap_trunc(r.hi, dst));
            upper_div = ap_all_ones(bw);
            if ap_eq(lower_div, upper_div) return union_r;
        }
    }
    if ap_active_bits(lower_div) > dst {
        if nuw return union_r;
        adjust := ap_and(lower_div, ap_bits_set_from(bw, dst));
        lower_div = ap_sub(lower_div, adjust);
        upper_div = ap_sub(upper_div, adjust);
    }
    udw := ap_active_bits(upper_div);
    if udw <= dst return cr_union(cr_new(ap_trunc(lower_div, dst), ap_trunc(upper_div, dst)), union_r);
    if !ap_is_zero(lower_div) && nuw return cr_union(cr_new(ap_trunc(lower_div, dst), ap_zero(dst)), union_r);
    if udw == dst + 1 {
        upper_div = ap_copy(upper_div);
        ap_clear_bit(*upper_div, dst);
        if ap_ult(upper_div, lower_div) return cr_union(cr_new(ap_trunc(lower_div, dst), ap_trunc(upper_div, dst)), union_r);
    }
    return cr_full(dst);
}
cr_zext_or_trunc :: (r: Const_Range, dst: u32) -> Const_Range {
    if cr_bits(r) > dst return cr_truncate(r, dst);
    if cr_bits(r) < dst return cr_zero_extend(r, dst);
    return r;
}
cr_sext_or_trunc :: (r: Const_Range, dst: u32) -> Const_Range {
    if cr_bits(r) > dst return cr_truncate(r, dst);
    if cr_bits(r) < dst return cr_sign_extend(r, dst);
    return r;
}

cr_binary_op :: (a: Const_Range, opc: Opcode, b: Const_Range) -> Const_Range {
    if opc == {
        case .ADD; return cr_add(a, b);
        case .SUB; return cr_sub(a, b);
        case .MUL; return cr_multiply(a, b);
        case .UDIV; return cr_udiv(a, b);
        case .SDIV; return cr_sdiv(a, b);
        case .UREM; return cr_urem(a, b);
        case .SREM; return cr_srem(a, b);
        case .SHL; return cr_shl(a, b);
        case .LSHR; return cr_lshr(a, b);
        case .ASHR; return cr_ashr(a, b);
        case .AND; return cr_binary_and(a, b);
        case .OR; return cr_binary_or(a, b);
        case .XOR; return cr_binary_xor(a, b);
        case .FADD; return cr_add(a, b);
        case .FSUB; return cr_sub(a, b);
        case .FMUL; return cr_multiply(a, b);
    }
    return cr_full(cr_bits(a));
}
// NoWrapKind bits: 1 = nuw, 2 = nsw (OverflowingBinaryOperator::NoUnsignedWrap = 1, NoSignedWrap = 2)
NW_NUW :: 1; NW_NSW :: 2;
cr_overflowing_binary_op :: (a: Const_Range, opc: Opcode, b: Const_Range, nw: u32) -> Const_Range {
    if opc == {
        case .ADD; return cr_add_with_no_wrap(a, b, nw);
        case .SUB; return cr_sub_with_no_wrap(a, b, nw);
        case .MUL; return cr_multiply(a, b, nw);
        case .SHL; return cr_shl_with_no_wrap(a, b, nw);
    }
    return cr_binary_op(a, opc, b);
}

cr_add :: (a: Const_Range, b: Const_Range) -> Const_Range {
    bw := cr_bits(a);
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(bw);
    if cr_is_full_set(a) || cr_is_full_set(b) return cr_full(bw);
    nl := ap_add(a.lo, b.lo);
    nu := ap_sub_u64(ap_add(a.hi, b.hi), 1);
    if ap_eq(nl, nu) return cr_full(bw);
    x := cr_new(nl, nu);
    if cr_is_size_strictly_smaller_than(x, a) || cr_is_size_strictly_smaller_than(x, b) return cr_full(bw);
    return x;
}
cr_add_with_no_wrap :: (a: Const_Range, b: Const_Range, nw: u32, t := Preferred_Range.SMALLEST) -> Const_Range {
    bw := cr_bits(a);
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(bw);
    if cr_is_full_set(a) && cr_is_full_set(b) return cr_full(bw);
    res := cr_add(a, b);
    if nw & NW_NSW res = cr_intersect(res, cr_sadd_sat(a, b), t);
    if nw & NW_NUW res = cr_intersect(res, cr_uadd_sat(a, b), t);
    return res;
}
cr_sub :: (a: Const_Range, b: Const_Range) -> Const_Range {
    bw := cr_bits(a);
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(bw);
    if cr_is_full_set(a) || cr_is_full_set(b) return cr_full(bw);
    nl := ap_add_u64(ap_sub(a.lo, b.hi), 1);
    nu := ap_sub(a.hi, b.lo);
    if ap_eq(nl, nu) return cr_full(bw);
    x := cr_new(nl, nu);
    if cr_is_size_strictly_smaller_than(x, a) || cr_is_size_strictly_smaller_than(x, b) return cr_full(bw);
    return x;
}
cr_sub_with_no_wrap :: (a: Const_Range, b: Const_Range, nw: u32, t := Preferred_Range.SMALLEST) -> Const_Range {
    bw := cr_bits(a);
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(bw);
    if cr_is_full_set(a) && cr_is_full_set(b) return cr_full(bw);
    res := cr_sub(a, b);
    if nw & NW_NSW res = cr_intersect(res, cr_ssub_sat(a, b), t);
    if nw & NW_NUW {
        if ap_ult(cr_umax(a), cr_umin(b)) return cr_empty(bw);
        res = cr_intersect(res, cr_usub_sat(a, b), t);
    }
    return res;
}
smin4 :: (l: [4] APInt) -> APInt { r := l[0]; for 1..3 if ap_slt(l[it], r) r = l[it]; return r; }
smax4 :: (l: [4] APInt) -> APInt { r := l[0]; for 1..3 if ap_slt(r, l[it]) r = l[it]; return r; }
cr_multiply :: (a: Const_Range, b: Const_Range, nw: u32 = 0) -> Const_Range {
    bw := cr_bits(a);
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(bw);
    ok, c := cr_single_element(a);
    if ok {
        if ap_is_one(c) return b;
        if ap_is_all_ones(c) return cr_sub(cr_single(ap_zero(bw)), b);
    }
    ok2, c2 := cr_single_element(b);
    if ok2 {
        if ap_is_one(c2) return a;
        if ap_is_all_ones(c2) return cr_sub(cr_single(ap_zero(bw)), a);
    }
    ur := cr_empty(bw);
    if nw & NW_NUW {
        min_mul, min_ov := ap_umul_ov(cr_umin(a), cr_umin(b));
        if min_ov return cr_empty(bw);
        max_mul := ap_umul_sat(cr_umax(a), cr_umax(b));
        ur = cr_non_empty(min_mul, ap_add_u64(max_mul, 1));
    } else {
        w := bw * 2;
        tmin := ap_zext(cr_umin(a), w); tmax := ap_zext(cr_umax(a), w);
        omin := ap_zext(cr_umin(b), w); omax := ap_zext(cr_umax(b), w);
        rz := cr_new(ap_mul(tmin, omin), ap_add_u64(ap_mul(tmax, omax), 1));
        ur = cr_truncate(rz, bw);
    }
    if !(nw & NW_NSW) && !cr_is_upper_wrapped(ur) && (ap_is_non_negative(ur.hi) || ap_is_min_signed(ur.hi)) return ur;
    w := bw * 2;
    tmin := ap_sext(cr_smin(a), w); tmax := ap_sext(cr_smax(a), w);
    omin := ap_sext(cr_smin(b), w); omax := ap_sext(cr_smax(b), w);
    l: [4] APInt;
    l[0] = ap_mul(tmin, omin); l[1] = ap_mul(tmin, omax); l[2] = ap_mul(tmax, omin); l[3] = ap_mul(tmax, omax);
    rs := cr_new(smin4(l), ap_add_u64(smax4(l), 1));
    if nw & NW_NSW rs = cr_intersect(rs, cr_new(ap_sext(ap_signed_min(bw), w), ap_add_u64(ap_sext(ap_signed_max(bw), w), 1)));
    sr := cr_truncate(rs, bw);
    result := ifx cr_is_size_strictly_smaller_than(ur, sr) then ur else sr;
    if nw == (NW_NSW | NW_NUW) && !cr_is_all_non_negative(result) {
        if ap_sgt_s64(cr_smin(a), 1) || ap_sgt_s64(cr_smin(b), 1)
            result = cr_intersect(result, cr_non_empty(ap_zero(bw), ap_signed_min(bw)));
    }
    return result;
}
cr_smax_op :: (a: Const_Range, b: Const_Range) -> Const_Range {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(cr_bits(a));
    res := cr_non_empty(ap_smax(cr_smin(a), cr_smin(b)), ap_add_u64(ap_smax(cr_smax(a), cr_smax(b)), 1));
    if cr_is_sign_wrapped_set(a) || cr_is_sign_wrapped_set(b) return cr_intersect(res, cr_union(a, b, .SIGNED), .SIGNED);
    return res;
}
cr_umax_op :: (a: Const_Range, b: Const_Range) -> Const_Range {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(cr_bits(a));
    res := cr_non_empty(ap_umax(cr_umin(a), cr_umin(b)), ap_add_u64(ap_umax(cr_umax(a), cr_umax(b)), 1));
    if cr_is_wrapped_set(a) || cr_is_wrapped_set(b) return cr_intersect(res, cr_union(a, b, .UNSIGNED), .UNSIGNED);
    return res;
}
cr_smin_op :: (a: Const_Range, b: Const_Range) -> Const_Range {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(cr_bits(a));
    res := cr_non_empty(ap_smin(cr_smin(a), cr_smin(b)), ap_add_u64(ap_smin(cr_smax(a), cr_smax(b)), 1));
    if cr_is_sign_wrapped_set(a) || cr_is_sign_wrapped_set(b) return cr_intersect(res, cr_union(a, b, .SIGNED), .SIGNED);
    return res;
}
cr_umin_op :: (a: Const_Range, b: Const_Range) -> Const_Range {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(cr_bits(a));
    res := cr_non_empty(ap_umin(cr_umin(a), cr_umin(b)), ap_add_u64(ap_umin(cr_umax(a), cr_umax(b)), 1));
    if cr_is_wrapped_set(a) || cr_is_wrapped_set(b) return cr_intersect(res, cr_union(a, b, .UNSIGNED), .UNSIGNED);
    return res;
}
cr_udiv :: (a: Const_Range, b: Const_Range) -> Const_Range {
    bw := cr_bits(a);
    if cr_is_empty_set(a) || cr_is_empty_set(b) || ap_is_zero(cr_umax(b)) return cr_empty(bw);
    lower := ap_udiv(cr_umin(a), cr_umax(b));
    rumin := cr_umin(b);
    if ap_is_zero(rumin) {
        if ap_is_one(b.hi) rumin = b.lo;
        else rumin = ap_one(bw);
    }
    upper := ap_add_u64(ap_udiv(cr_umax(a), rumin), 1);
    return cr_non_empty(lower, upper);
}
cr_sdiv :: (a: Const_Range, rhs: Const_Range) -> Const_Range {
    bw := cr_bits(a);
    zero := ap_zero(bw);
    smin := ap_signed_min(bw);
    pos_l, neg_l := cr_split_pos_neg(a);
    pos_r, neg_r := cr_split_pos_neg(rhs);
    pos_res := cr_empty(bw);
    if !cr_is_empty_set(pos_l) && !cr_is_empty_set(pos_r)
        pos_res = cr_new(ap_sdiv(pos_l.lo, ap_sub_u64(pos_r.hi, 1)), ap_add_u64(ap_sdiv(ap_sub_u64(pos_l.hi, 1), pos_r.lo), 1));
    if !cr_is_empty_set(neg_l) && !cr_is_empty_set(neg_r) {
        lo := ap_sdiv(ap_sub_u64(neg_l.hi, 1), neg_r.lo);
        if ap_is_min_signed(neg_l.lo) && ap_is_zero(neg_r.hi) {
            if !ap_is_all_ones(neg_r.lo) {
                adj: APInt;
                if ap_is_all_ones(rhs.lo) adj = rhs.hi; else adj = ap_sub_u64(neg_r.hi, 1);
                pos_res = cr_union(pos_res, cr_new(lo, ap_add_u64(ap_sdiv(neg_l.lo, ap_sub_u64(adj, 1)), 1)));
            }
            if !ap_eq(neg_l.hi, ap_add_u64(smin, 1)) {
                adj: APInt;
                if ap_eq(a.hi, ap_add_u64(smin, 1)) adj = a.lo; else adj = ap_add_u64(neg_l.lo, 1);
                pos_res = cr_union(pos_res, cr_new(lo, ap_add_u64(ap_sdiv(adj, ap_sub_u64(neg_r.hi, 1)), 1)));
            }
        } else {
            pos_res = cr_union(pos_res, cr_new(lo, ap_add_u64(ap_sdiv(neg_l.lo, ap_sub_u64(neg_r.hi, 1)), 1)));
        }
    }
    neg_res := cr_empty(bw);
    if !cr_is_empty_set(pos_l) && !cr_is_empty_set(neg_r)
        neg_res = cr_new(ap_sdiv(ap_sub_u64(pos_l.hi, 1), ap_sub_u64(neg_r.hi, 1)), ap_add_u64(ap_sdiv(pos_l.lo, neg_r.lo), 1));
    if !cr_is_empty_set(neg_l) && !cr_is_empty_set(pos_r)
        neg_res = cr_union(neg_res, cr_new(ap_sdiv(neg_l.lo, pos_r.lo), ap_add_u64(ap_sdiv(ap_sub_u64(neg_l.hi, 1), ap_sub_u64(pos_r.hi, 1)), 1)));
    res := cr_union(neg_res, pos_res, .SIGNED);
    if cr_contains(a, zero) && (!cr_is_empty_set(pos_r) || !cr_is_empty_set(neg_r)) res = cr_union(res, cr_single(zero));
    return res;
}
cr_urem :: (a: Const_Range, b: Const_Range) -> Const_Range {
    bw := cr_bits(a);
    if cr_is_empty_set(a) || cr_is_empty_set(b) || ap_is_zero(cr_umax(b)) return cr_empty(bw);
    ok, ri := cr_single_element(b);
    if ok {
        if ap_is_zero(ri) return cr_empty(bw);
        ok2, li := cr_single_element(a);
        if ok2 return cr_single(ap_urem(li, ri));
    }
    if ap_ult(cr_umax(a), cr_umin(b)) return a;
    upper := ap_add_u64(ap_umin(cr_umax(a), ap_sub_u64(cr_umax(b), 1)), 1);
    return cr_non_empty(ap_zero(bw), upper);
}
cr_srem :: (a: Const_Range, b: Const_Range) -> Const_Range {
    bw := cr_bits(a);
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(bw);
    ok, ri := cr_single_element(b);
    if ok {
        if ap_is_zero(ri) return cr_empty(bw);
        ok2, li := cr_single_element(a);
        if ok2 return cr_single(ap_srem(li, ri));
    }
    abs_rhs := cr_abs(b);
    min_abs := cr_umin(abs_rhs); max_abs := cr_umax(abs_rhs);
    if ap_is_zero(max_abs) return cr_empty(bw);
    if ap_is_zero(min_abs) min_abs = ap_add_u64(min_abs, 1);
    min_l := cr_smin(a); max_l := cr_smax(a);
    if ap_is_non_negative(min_l) {
        if ap_ult(max_l, min_abs) return a;
        return cr_new(ap_zero(bw), ap_add_u64(ap_umin(max_l, ap_sub_u64(max_abs, 1)), 1));
    }
    if ap_is_negative(max_l) {
        if ap_ugt(min_l, ap_neg(min_abs)) return a;
        return cr_new(ap_umax(min_l, ap_add_u64(ap_neg(max_abs), 1)), ap_one(bw));
    }
    lower := ap_umax(min_l, ap_add_u64(ap_neg(max_abs), 1));
    upper := ap_add_u64(ap_umin(max_l, ap_sub_u64(max_abs, 1)), 1);
    return cr_new(lower, upper);
}
cr_binary_not :: (a: Const_Range) -> Const_Range { return cr_sub(cr_single(ap_all_ones(cr_bits(a))), a); }
cr_estimate_bit_masked_and_lower_bound :: (l: Const_Range, r: Const_Range) -> APInt {
    bw := cr_bits(l);
    if cr_is_full_set(l) || cr_is_full_set(r) || cr_is_wrapped_set(l) || cr_is_wrapped_set(r) return ap_zero(bw);
    llo := l.lo; lhi := ap_sub_u64(l.hi, 1); rlo := r.lo; rhi := ap_sub_u64(r.hi, 1);
    mask := ap_not(ap_or(ap_or(ap_xor(llo, lhi), ap_xor(rlo, rhi)), ap_xor(llo, rlo)));
    lo := ap_clo(mask);
    ap_clear_low_bits(*mask, bw - lo);
    estimate :: (alo_in: APInt, blo: APInt, bhi: APInt, mask: APInt) -> APInt {
        bw := alo_in.bits;
        lo := ap_clo(ap_or(ap_and(blo, bhi), mask));
        alo := ap_copy(alo_in);
        ap_clear_low_bits(*alo, bw - lo);
        return alo;
    }
    return ap_umax(estimate(llo, rlo, rhi, mask), estimate(rlo, llo, lhi, mask));
}
cr_binary_and :: (a: Const_Range, b: Const_Range) -> Const_Range {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(cr_bits(a));
    kr := cr_from_known_bits(kb_and(cr_to_known_bits(a), cr_to_known_bits(b)), false);
    lb := cr_estimate_bit_masked_and_lower_bound(a, b);
    r := cr_non_empty(lb, ap_add_u64(ap_umin(cr_umax(b), cr_umax(a)), 1));
    return cr_intersect(kr, r);
}
cr_binary_or :: (a: Const_Range, b: Const_Range) -> Const_Range {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(cr_bits(a));
    kr := cr_from_known_bits(kb_or(cr_to_known_bits(a), cr_to_known_bits(b)), false);
    ub := ap_neg(cr_estimate_bit_masked_and_lower_bound(cr_binary_not(a), cr_binary_not(b)));
    r := cr_non_empty(ap_umax(cr_umin(a), cr_umin(b)), ub);
    return cr_intersect(kr, r);
}
cr_binary_xor :: (a: Const_Range, b: Const_Range) -> Const_Range {
    bw := cr_bits(a);
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(bw);
    ok1, s1 := cr_single_element(a); ok2, s2 := cr_single_element(b);
    if ok1 && ok2 return cr_single(ap_xor(s1, s2));
    if ok2 && ap_is_all_ones(s2) return cr_binary_not(a);
    if ok1 && ap_is_all_ones(s1) return cr_binary_not(b);
    lk := cr_to_known_bits(a); rk := cr_to_known_bits(b);
    r := cr_from_known_bits(kb_xor(lk, rk), false);
    if bw == 1 return r;
    if ap_is_subset_of(ap_not(lk.zero), rk.one) r = cr_intersect(r, cr_sub(b, a), .UNSIGNED);
    else if ap_is_subset_of(ap_not(rk.zero), lk.one) r = cr_intersect(r, cr_sub(a, b), .UNSIGNED);
    return r;
}
cr_shl :: (a: Const_Range, b: Const_Range) -> Const_Range {
    bw := cr_bits(a);
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(bw);
    mn := cr_umin(a); mx := cr_umax(a);
    ok, rhs := cr_single_element(b);
    if ok {
        if ap_uge_u64(rhs, bw) return cr_empty(bw);
        eq_lead := ap_clz(ap_xor(mn, mx));
        if ap_ule_u64(rhs, eq_lead) return cr_non_empty(ap_shl_ap(mn, rhs), ap_add_u64(ap_shl_ap(mx, rhs), 1));
        return cr_non_empty(ap_zero(bw), ap_add_u64(ap_bits_set_from(bw, cast(u32) ap_zext_value(rhs)), 1));
    }
    omax := cr_umax(b);
    if cr_is_all_negative(a) && ap_ule_u64(omax, ap_clo(mn)) {
        mx = ap_shl_ap(mx, cr_umin(b));
        mn = ap_shl_ap(mn, omax);
        return cr_non_empty(mn, ap_add_u64(mx, 1));
    }
    if ap_ugt_u64(omax, ap_clz(mx)) return cr_full(bw);
    mn = ap_shl_ap(mn, cr_umin(b));
    mx = ap_shl_ap(mx, omax);
    return cr_non_empty(mn, ap_add_u64(mx, 1));
}
cr_compute_shl_nuw :: (l: Const_Range, r: Const_Range) -> Const_Range {
    bw := cr_bits(l);
    lmin := cr_umin(l);
    rmin := cast(u32) ap_limited(cr_umin(r), bw);
    min_shl, ov := ap_ushl_ov(lmin, ap_from_u64(bw, rmin));
    if rmin >= bw { min_shl = ap_zero(bw); ov = true; }
    if ov return cr_empty(bw);
    lmax := cr_umax(l);
    rmax := cast(u32) ap_limited(cr_umax(r), bw);
    max_shl := min_shl;
    max_sh := ap_clz(lmax);
    if rmin <= max_sh max_shl = ap_shl(lmax, min(rmax, max_sh));
    rmin = max(rmin, max_sh + 1);
    rmax = min(rmax, ap_clz(lmin));
    if rmin <= rmax max_shl = ap_umax(max_shl, ap_high_bits_set(bw, bw - rmin));
    return cr_non_empty(min_shl, ap_add_u64(max_shl, 1));
}
cr_shl_nsw_nneg :: (lmin: APInt, lmax: APInt, rmin_in: u32, rmax_in: u32) -> Const_Range {
    bw := lmin.bits;
    rmin := rmin_in; rmax := rmax_in;
    if rmin >= bw return cr_empty(bw);
    min_shl, ov := ap_sshl_ov(lmin, ap_from_u64(bw, rmin));
    if ov return cr_empty(bw);
    max_shl := min_shl;
    max_sh := ap_clz(lmax) - 1;
    if rmin <= max_sh max_shl = ap_shl(lmax, min(rmax, max_sh));
    rmin = max(rmin, max_sh + 1);
    rmax = min(rmax, ap_clz(lmin) - 1);
    if rmin <= rmax max_shl = ap_umax(max_shl, ap_bits_set(bw, rmin, bw - 1));
    return cr_non_empty(min_shl, ap_add_u64(max_shl, 1));
}
cr_shl_nsw_neg :: (lmin: APInt, lmax: APInt, rmin_in: u32, rmax_in: u32) -> Const_Range {
    bw := lmin.bits;
    rmin := rmin_in; rmax := rmax_in;
    if rmin >= bw return cr_empty(bw);
    max_shl, ov := ap_sshl_ov(lmax, ap_from_u64(bw, rmin));
    if ov return cr_empty(bw);
    min_shl := max_shl;
    max_sh := ap_clo(lmin) - 1;
    if rmin <= max_sh min_shl = ap_shl(lmin, min(rmax, max_sh));
    rmin = max(rmin, max_sh + 1);
    rmax = min(rmax, ap_clo(lmax) - 1);
    if rmin <= rmax min_shl = ap_signed_min(bw);
    return cr_non_empty(min_shl, ap_add_u64(max_shl, 1));
}
cr_compute_shl_nsw :: (l: Const_Range, r: Const_Range) -> Const_Range {
    bw := cr_bits(l);
    rmin := cast(u32) ap_limited(cr_umin(r), bw);
    rmax := cast(u32) ap_limited(cr_umax(r), bw);
    lmin := cr_smin(l); lmax := cr_smax(l);
    if ap_is_non_negative(lmin) return cr_shl_nsw_nneg(lmin, lmax, rmin, rmax);
    if ap_is_negative(lmax) return cr_shl_nsw_neg(lmin, lmax, rmin, rmax);
    return cr_union(cr_shl_nsw_nneg(ap_zero(bw), lmax, rmin, rmax), cr_shl_nsw_neg(lmin, ap_all_ones(bw), rmin, rmax), .SIGNED);
}
cr_shl_with_no_wrap :: (a: Const_Range, b: Const_Range, nw: u32, t := Preferred_Range.SMALLEST) -> Const_Range {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(cr_bits(a));
    if nw == {
        case 0; return cr_shl(a, b);
        case NW_NSW; return cr_compute_shl_nsw(a, b);
        case NW_NUW; return cr_compute_shl_nuw(a, b);
    }
    return cr_intersect(cr_compute_shl_nsw(a, b), cr_compute_shl_nuw(a, b), t);
}
cr_lshr :: (a: Const_Range, b: Const_Range) -> Const_Range {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(cr_bits(a));
    mx := ap_add_u64(ap_lshr_ap(cr_umax(a), cr_umin(b)), 1);
    mn := ap_lshr_ap(cr_umin(a), cr_umax(b));
    return cr_non_empty(mn, mx);
}
cr_ashr :: (a: Const_Range, b: Const_Range) -> Const_Range {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(cr_bits(a));
    pos_max := ap_add_u64(ap_ashr_ap(cr_smax(a), cr_umin(b)), 1);
    pos_min := ap_ashr_ap(cr_smin(a), cr_umax(b));
    neg_max := ap_add_u64(ap_ashr_ap(cr_smax(a), cr_umax(b)), 1);
    neg_min := ap_ashr_ap(cr_smin(a), cr_umin(b));
    mn, mx: APInt;
    if ap_is_non_negative(cr_smin(a)) { mn = pos_min; mx = pos_max; }
    else if ap_is_negative(cr_smax(a)) { mn = neg_min; mx = neg_max; }
    else { mn = neg_min; mx = pos_max; }
    return cr_non_empty(mn, mx);
}
cr_uadd_sat :: (a: Const_Range, b: Const_Range) -> Const_Range {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(cr_bits(a));
    return cr_non_empty(ap_uadd_sat(cr_umin(a), cr_umin(b)), ap_add_u64(ap_uadd_sat(cr_umax(a), cr_umax(b)), 1));
}
cr_sadd_sat :: (a: Const_Range, b: Const_Range) -> Const_Range {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(cr_bits(a));
    return cr_non_empty(ap_sadd_sat(cr_smin(a), cr_smin(b)), ap_add_u64(ap_sadd_sat(cr_smax(a), cr_smax(b)), 1));
}
cr_usub_sat :: (a: Const_Range, b: Const_Range) -> Const_Range {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(cr_bits(a));
    return cr_non_empty(ap_usub_sat(cr_umin(a), cr_umax(b)), ap_add_u64(ap_usub_sat(cr_umax(a), cr_umin(b)), 1));
}
cr_ssub_sat :: (a: Const_Range, b: Const_Range) -> Const_Range {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(cr_bits(a));
    return cr_non_empty(ap_ssub_sat(cr_smin(a), cr_smax(b)), ap_add_u64(ap_ssub_sat(cr_smax(a), cr_smin(b)), 1));
}
cr_umul_sat :: (a: Const_Range, b: Const_Range) -> Const_Range {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(cr_bits(a));
    return cr_non_empty(ap_umul_sat(cr_umin(a), cr_umin(b)), ap_add_u64(ap_umul_sat(cr_umax(a), cr_umax(b)), 1));
}
cr_smul_sat :: (a: Const_Range, b: Const_Range) -> Const_Range {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(cr_bits(a));
    l: [4] APInt;
    l[0] = ap_smul_sat(cr_smin(a), cr_smin(b)); l[1] = ap_smul_sat(cr_smin(a), cr_smax(b));
    l[2] = ap_smul_sat(cr_smax(a), cr_smin(b)); l[3] = ap_smul_sat(cr_smax(a), cr_smax(b));
    return cr_non_empty(smin4(l), ap_add_u64(smax4(l), 1));
}
cr_ushl_sat :: (a: Const_Range, b: Const_Range) -> Const_Range {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(cr_bits(a));
    return cr_non_empty(ap_ushl_sat(cr_umin(a), cr_umin(b)), ap_add_u64(ap_ushl_sat(cr_umax(a), cr_umax(b)), 1));
}
cr_sshl_sat :: (a: Const_Range, b: Const_Range) -> Const_Range {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(cr_bits(a));
    mn := cr_smin(a); mx := cr_smax(a);
    smin := cr_umin(b); smax := cr_umax(b);
    nl := ap_sshl_sat(mn, ifx ap_is_non_negative(mn) then smin else smax);
    nu := ap_add_u64(ap_sshl_sat(mx, ifx ap_is_negative(mx) then smin else smax), 1);
    return cr_non_empty(nl, nu);
}
cr_abs :: (r: Const_Range, int_min_is_poison := false) -> Const_Range {
    bw := cr_bits(r);
    if cr_is_empty_set(r) return cr_empty(bw);
    if cr_is_sign_wrapped_set(r) {
        lo: APInt;
        if ap_is_strictly_positive(r.hi) || !ap_is_strictly_positive(r.lo) lo = ap_zero(bw);
        else lo = ap_umin(r.lo, ap_add_u64(ap_neg(r.hi), 1));
        if int_min_is_poison return cr_new(lo, ap_signed_min(bw));
        return cr_new(lo, ap_add_u64(ap_signed_min(bw), 1));
    }
    smin := cr_smin(r); smax := cr_smax(r);
    if int_min_is_poison && ap_is_min_signed(smin) {
        if ap_is_min_signed(smax) return cr_empty(bw);
        smin = ap_add_u64(smin, 1);
    }
    if ap_is_non_negative(smin) return cr_new(smin, ap_add_u64(smax, 1));
    if ap_is_negative(smax) return cr_new(ap_neg(smax), ap_add_u64(ap_neg(smin), 1));
    return cr_non_empty(ap_zero(bw), ap_add_u64(ap_umax(ap_neg(smin), smax), 1));
}
cr_ctlz :: (r: Const_Range, zero_is_poison := false) -> Const_Range {
    bw := cr_bits(r);
    if cr_is_empty_set(r) return cr_empty(bw);
    zero := ap_zero(bw);
    if zero_is_poison && cr_contains(r, zero) {
        if ap_is_zero(r.lo) {
            if ap_is_zero(ap_sub_u64(r.hi, 1)) return cr_empty(bw);
            return cr_new(ap_from_u64(bw, ap_clz(ap_sub_u64(r.hi, 1))), ap_from_u64(bw, ap_clz(ap_add_u64(r.lo, 1)) + 1));
        } else if ap_is_zero(ap_sub_u64(r.hi, 1)) {
            return cr_new(zero, ap_from_u64(bw, ap_clz(r.lo) + 1));
        }
        return cr_new(zero, ap_from_u64(bw, bw));
    }
    return cr_non_empty(ap_from_u64(bw, ap_clz(cr_umax(r))), ap_add_u64(ap_from_u64(bw, ap_clz(cr_umin(r))), 1));
}
cr_cttz_range :: (lo: APInt, hi: APInt) -> Const_Range {
    bw := lo.bits;
    if ap_eq(ap_add_u64(lo, 1), hi) return cr_single(ap_from_u64(bw, ap_ctz(lo)));
    if ap_is_zero(lo) return cr_new(ap_zero(bw), ap_from_u64(bw, bw + 1));
    lcp := ap_clz(ap_xor(lo, ap_sub_u64(hi, 1)));
    return cr_new(ap_zero(bw), ap_from_u64(bw, max(bw - lcp - 1, ap_ctz(lo)) + 1));
}
cr_cttz :: (r: Const_Range, zero_is_poison := false) -> Const_Range {
    bw := cr_bits(r);
    if cr_is_empty_set(r) return cr_empty(bw);
    zero := ap_zero(bw);
    if zero_is_poison && cr_contains(r, zero) {
        if ap_is_zero(r.lo) {
            if ap_is_one(r.hi) return cr_empty(bw);
            return cr_cttz_range(ap_one(bw), r.hi);
        } else if ap_is_one(r.hi) return cr_cttz_range(r.lo, zero);
        return cr_union(cr_cttz_range(r.lo, zero), cr_cttz_range(ap_one(bw), r.hi));
    }
    if cr_is_full_set(r) return cr_non_empty(zero, ap_add_u64(ap_from_u64(bw, bw), 1));
    if !cr_is_wrapped_set(r) return cr_cttz_range(r.lo, r.hi);
    return cr_union(cr_cttz_range(r.lo, zero), cr_cttz_range(zero, r.hi));
}
cr_popcount_range :: (lo: APInt, hi: APInt) -> Const_Range {
    bw := lo.bits;
    if ap_eq(ap_add_u64(lo, 1), hi) return cr_single(ap_from_u64(bw, ap_popcount(lo)));
    mx := ap_sub_u64(hi, 1);
    lcp := ap_clz(ap_xor(lo, mx));
    lcp_pop := ifx lcp == 0 then cast(u32) 0 else ap_popcount(ap_get_hi_bits(lo, lcp));
    min_bits := lcp_pop + (ifx ap_ctz(lo) < bw - lcp then cast(u32) 1 else 0);
    max_bits := lcp_pop + (bw - lcp) - (ifx ap_cto(mx) < bw - lcp then cast(u32) 1 else 0);
    return cr_new(ap_from_u64(bw, min_bits), ap_from_u64(bw, max_bits + 1));
}
cr_ctpop :: (r: Const_Range) -> Const_Range {
    bw := cr_bits(r);
    if cr_is_empty_set(r) return cr_empty(bw);
    zero := ap_zero(bw);
    if cr_is_full_set(r) return cr_non_empty(zero, ap_add_u64(ap_from_u64(bw, bw), 1));
    if !cr_is_wrapped_set(r) return cr_popcount_range(r.lo, r.hi);
    cr1 := cr_new(ap_from_u64(bw, ap_clo(r.lo)), ap_from_u64(bw, bw + 1));
    return cr_union(cr1, cr_popcount_range(zero, r.hi));
}

Overflow_Result :: enum u8 { ALWAYS_OVERFLOWS_LOW; ALWAYS_OVERFLOWS_HIGH; MAY_OVERFLOW; NEVER_OVERFLOWS; }
cr_unsigned_add_may_overflow :: (a: Const_Range, b: Const_Range) -> Overflow_Result {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return .MAY_OVERFLOW;
    if ap_ugt(cr_umin(a), ap_not(cr_umin(b))) return .ALWAYS_OVERFLOWS_HIGH;
    if ap_ugt(cr_umax(a), ap_not(cr_umax(b))) return .MAY_OVERFLOW;
    return .NEVER_OVERFLOWS;
}
cr_signed_add_may_overflow :: (a: Const_Range, b: Const_Range) -> Overflow_Result {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return .MAY_OVERFLOW;
    mn := cr_smin(a); mx := cr_smax(a); omn := cr_smin(b); omx := cr_smax(b);
    smin := ap_signed_min(cr_bits(a)); smax := ap_signed_max(cr_bits(a));
    if ap_is_non_negative(mn) && ap_is_non_negative(omn) && ap_sgt(mn, ap_sub(smax, omn)) return .ALWAYS_OVERFLOWS_HIGH;
    if ap_is_negative(mx) && ap_is_negative(omx) && ap_slt(mx, ap_sub(smin, omx)) return .ALWAYS_OVERFLOWS_LOW;
    if ap_is_non_negative(mx) && ap_is_non_negative(omx) && ap_sgt(mx, ap_sub(smax, omx)) return .MAY_OVERFLOW;
    if ap_is_negative(mn) && ap_is_negative(omn) && ap_slt(mn, ap_sub(smin, omn)) return .MAY_OVERFLOW;
    return .NEVER_OVERFLOWS;
}
cr_unsigned_sub_may_overflow :: (a: Const_Range, b: Const_Range) -> Overflow_Result {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return .MAY_OVERFLOW;
    if ap_ult(cr_umax(a), cr_umin(b)) return .ALWAYS_OVERFLOWS_LOW;
    if ap_ult(cr_umin(a), cr_umax(b)) return .MAY_OVERFLOW;
    return .NEVER_OVERFLOWS;
}
cr_signed_sub_may_overflow :: (a: Const_Range, b: Const_Range) -> Overflow_Result {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return .MAY_OVERFLOW;
    mn := cr_smin(a); mx := cr_smax(a); omn := cr_smin(b); omx := cr_smax(b);
    smin := ap_signed_min(cr_bits(a)); smax := ap_signed_max(cr_bits(a));
    if ap_is_non_negative(mn) && ap_is_negative(omx) && ap_sgt(mn, ap_add(smax, omx)) return .ALWAYS_OVERFLOWS_HIGH;
    if ap_is_negative(mx) && ap_is_non_negative(omn) && ap_slt(mx, ap_add(smin, omn)) return .ALWAYS_OVERFLOWS_LOW;
    if ap_is_non_negative(mx) && ap_is_negative(omn) && ap_sgt(mx, ap_add(smax, omn)) return .MAY_OVERFLOW;
    if ap_is_negative(mn) && ap_is_non_negative(omx) && ap_slt(mn, ap_add(smin, omx)) return .MAY_OVERFLOW;
    return .NEVER_OVERFLOWS;
}
cr_unsigned_mul_may_overflow :: (a: Const_Range, b: Const_Range) -> Overflow_Result {
    if cr_is_empty_set(a) || cr_is_empty_set(b) return .MAY_OVERFLOW;
    _, o1 := ap_umul_ov(cr_umin(a), cr_umin(b));
    if o1 return .ALWAYS_OVERFLOWS_HIGH;
    _, o2 := ap_umul_ov(cr_umax(a), cr_umax(b));
    if o2 return .MAY_OVERFLOW;
    return .NEVER_OVERFLOWS;
}

// ConstantRange::isIntrinsicSupported / intrinsic are in value_tracking.jai (they need intrinsic ids).

// getConstantRangeFromMetadata
cr_from_range_md :: (m: Md_Id) -> Const_Range {
    n := ir.mds[m].nops / 2;
    bits := type_int_width(scalar_type(vtype(ir.mds[md_op(m, 0)].value)));
    r: Const_Range;
    for p: 0..cast(s64) n - 1 {
        lo := ap_from_words(bits, const_int_value(ir.mds[md_op(m, cast(u32)(2 * p))].value));
        hi := ap_from_words(bits, const_int_value(ir.mds[md_op(m, cast(u32)(2 * p + 1))].value));
        if p == 0 r = cr_new(lo, hi);
        else r = cr_union(r, cr_new(lo, hi));
    }
    return r;
}
