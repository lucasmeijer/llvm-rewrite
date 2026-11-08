// KnownBits: a port of llvm/include/llvm/Support/KnownBits.h and llvm/lib/Support/KnownBits.cpp.
// Values; every operation returns a fresh Known_Bits (small widths never allocate, see apint.jai).

Known_Bits :: struct {
    zero: APInt;
    one: APInt;
}

kb_new :: (bits: u32) -> Known_Bits { k: Known_Bits; k.zero = ap_zero(bits); k.one = ap_zero(bits); return k; }
kb_make :: (zero: APInt, one: APInt) -> Known_Bits { k: Known_Bits; k.zero = zero; k.one = one; return k; }
kb_bits :: inline (k: Known_Bits) -> u32 { return k.zero.bits; }
kb_from_const :: (c: APInt) -> Known_Bits { k: Known_Bits; k.one = ap_copy(c); k.zero = ap_not(c); return k; }   // makeConstant
kb_is_constant :: (k: Known_Bits) -> bool { return ap_popcount(k.zero) + ap_popcount(k.one) == kb_bits(k) && !kb_has_conflict(k); }
kb_constant :: (k: Known_Bits) -> APInt { return k.one; }
kb_has_conflict :: (k: Known_Bits) -> bool { return ap_intersects(k.zero, k.one); }
kb_is_unknown :: (k: Known_Bits) -> bool { return ap_is_zero(k.zero) && ap_is_zero(k.one); }
kb_is_sign_unknown :: (k: Known_Bits) -> bool { return !ap_is_negative(k.zero) && !ap_is_negative(k.one); }
kb_reset_all :: (k: *Known_Bits) { k.zero = ap_zero(kb_bits(k.*)); k.one = ap_zero(kb_bits(k.*)); }
kb_set_all_zero :: (k: *Known_Bits) { k.zero = ap_all_ones(kb_bits(k.*)); k.one = ap_zero(kb_bits(k.*)); }
kb_set_all_ones :: (k: *Known_Bits) { k.one = ap_all_ones(kb_bits(k.*)); k.zero = ap_zero(kb_bits(k.*)); }
kb_set_all_conflict :: (k: *Known_Bits) { k.zero = ap_all_ones(kb_bits(k.*)); k.one = ap_all_ones(kb_bits(k.*)); }
kb_min_value :: (k: Known_Bits) -> APInt { return k.one; }
kb_max_value :: (k: Known_Bits) -> APInt { return ap_not(k.zero); }
kb_signed_min_value :: (k: Known_Bits) -> APInt {
    r := ap_copy(k.one);
    if !ap_is_negative(k.zero) ap_set_sign_bit(*r);
    return r;
}
kb_signed_max_value :: (k: Known_Bits) -> APInt {
    r := ap_not(k.zero);
    if !ap_is_negative(k.one) ap_clear_bit(*r, r.bits - 1);
    return r;
}
kb_count_max_leading_zeros :: (k: Known_Bits) -> u32 { return ap_clz(k.one); }
kb_count_max_trailing_zeros :: (k: Known_Bits) -> u32 { return ap_ctz(k.one); }
kb_count_max_trailing_ones :: (k: Known_Bits) -> u32 { return ap_ctz(k.zero); }
kb_count_max_leading_ones :: (k: Known_Bits) -> u32 { return ap_clz(k.zero); }
kb_count_min_leading_zeros :: (k: Known_Bits) -> u32 { return ap_clo(k.zero); }
kb_count_min_trailing_zeros :: (k: Known_Bits) -> u32 { return ap_cto(k.zero); }
kb_count_min_trailing_ones :: (k: Known_Bits) -> u32 { return ap_cto(k.one); }
kb_count_min_leading_ones :: (k: Known_Bits) -> u32 { return ap_clo(k.one); }
kb_count_min_sign_bits :: (k: Known_Bits) -> u32 {
    if kb_is_non_negative(k) return kb_count_min_leading_zeros(k);
    if kb_is_negative(k) return kb_count_min_leading_ones(k);
    return 1;
}
kb_count_max_significant_bits :: (k: Known_Bits) -> u32 { return kb_bits(k) - kb_count_min_sign_bits(k) + 1; }
kb_count_min_population :: (k: Known_Bits) -> u32 { return ap_popcount(k.one); }
kb_count_max_population :: (k: Known_Bits) -> u32 { return kb_bits(k) - ap_popcount(k.zero); }
kb_count_max_active_bits :: (k: Known_Bits) -> u32 { return kb_bits(k) - kb_count_min_leading_zeros(k); }
kb_is_non_negative :: (k: Known_Bits) -> bool { return ap_is_negative(k.zero); }
kb_is_negative :: (k: Known_Bits) -> bool { return ap_is_negative(k.one); }
kb_is_non_zero :: (k: Known_Bits) -> bool { return !ap_is_zero(k.one); }
kb_is_zero :: (k: Known_Bits) -> bool { return ap_is_all_ones(k.zero); }
kb_is_all_ones :: (k: Known_Bits) -> bool { return ap_is_all_ones(k.one); }
kb_is_strictly_positive :: (k: Known_Bits) -> bool { return ap_is_negative(k.zero) && !ap_is_zero(k.one); }
kb_is_non_positive :: (k: Known_Bits) -> bool { return ap_is_non_positive(kb_signed_max_value(k)); }
kb_is_even :: (k: Known_Bits) -> bool { return ap_get_bit(k.zero, 0); }
kb_eq_kb :: (a: Known_Bits, b: Known_Bits) -> bool { return ap_eq(a.zero, b.zero) && ap_eq(a.one, b.one); }
kb_and :: (a: Known_Bits, b: Known_Bits) -> Known_Bits { r: Known_Bits; r.zero = ap_or(a.zero, b.zero); r.one = ap_and(a.one, b.one); return r; }
kb_or  :: (a: Known_Bits, b: Known_Bits) -> Known_Bits { r: Known_Bits; r.zero = ap_and(a.zero, b.zero); r.one = ap_or(a.one, b.one); return r; }
kb_xor :: (a: Known_Bits, b: Known_Bits) -> Known_Bits {
    r: Known_Bits;
    r.zero = ap_or(ap_and(a.zero, b.zero), ap_and(a.one, b.one));
    r.one = ap_or(ap_and(a.zero, b.one), ap_and(a.one, b.zero));
    return r;
}
kb_not :: (a: Known_Bits) -> Known_Bits { return kb_make(a.one, a.zero); }
// intersectWith: bits known in both
kb_intersect :: (a: Known_Bits, b: Known_Bits) -> Known_Bits { r: Known_Bits; r.zero = ap_and(a.zero, b.zero); r.one = ap_and(a.one, b.one); return r; }
// unionWith
kb_union :: (a: Known_Bits, b: Known_Bits) -> Known_Bits { r: Known_Bits; r.zero = ap_or(a.zero, b.zero); r.one = ap_or(a.one, b.one); return r; }
kb_have_no_common_bits_set :: (a: Known_Bits, b: Known_Bits) -> bool { return ap_is_all_ones(ap_or(a.zero, b.zero)); }
kb_trunc :: (k: Known_Bits, bits: u32) -> Known_Bits { r: Known_Bits; r.zero = ap_trunc(k.zero, bits); r.one = ap_trunc(k.one, bits); return r; }
kb_zext :: (k: Known_Bits, bits: u32) -> Known_Bits {
    old := kb_bits(k);
    r: Known_Bits; r.zero = ap_zext(k.zero, bits); r.one = ap_zext(k.one, bits);
    ap_set_bits(*r.zero, old, bits);
    return r;
}
kb_anyext :: (k: Known_Bits, bits: u32) -> Known_Bits { r: Known_Bits; r.zero = ap_zext(k.zero, bits); r.one = ap_zext(k.one, bits); return r; }
kb_sext :: (k: Known_Bits, bits: u32) -> Known_Bits { r: Known_Bits; r.zero = ap_sext(k.zero, bits); r.one = ap_sext(k.one, bits); return r; }
kb_zext_or_trunc :: (k: Known_Bits, bits: u32) -> Known_Bits {
    if bits > kb_bits(k) return kb_zext(k, bits);
    if bits < kb_bits(k) return kb_trunc(k, bits);
    return k;
}
kb_anyext_or_trunc :: (k: Known_Bits, bits: u32) -> Known_Bits {
    if bits > kb_bits(k) return kb_anyext(k, bits);
    if bits < kb_bits(k) return kb_trunc(k, bits);
    return k;
}
kb_sext_or_trunc :: (k: Known_Bits, bits: u32) -> Known_Bits {
    if bits > kb_bits(k) return kb_sext(k, bits);
    if bits < kb_bits(k) return kb_trunc(k, bits);
    return k;
}
kb_make_non_negative :: (k: *Known_Bits) { ap_set_sign_bit(*k.zero); }
kb_make_negative :: (k: *Known_Bits) { ap_set_sign_bit(*k.one); }
kb_extract_bits :: (k: Known_Bits, n: u32, pos: u32) -> Known_Bits { return kb_make(ap_extract_bits(k.zero, n, pos), ap_extract_bits(k.one, n, pos)); }
kb_insert_bits :: (k: *Known_Bits, sub: Known_Bits, pos: u32) { ap_insert_bits(*k.zero, sub.zero, pos); ap_insert_bits(*k.one, sub.one, pos); }
kb_concat :: (hi: Known_Bits, lo: Known_Bits) -> Known_Bits { return kb_make(ap_concat(hi.zero, lo.zero), ap_concat(hi.one, lo.one)); }
kb_byte_swap :: (k: Known_Bits) -> Known_Bits { return kb_make(ap_byte_swap(k.zero), ap_byte_swap(k.one)); }
kb_reverse_bits :: (k: Known_Bits) -> Known_Bits { return kb_make(ap_reverse_bits(k.zero), ap_reverse_bits(k.one)); }
kb_lshr_const :: (k: Known_Bits, s: u32) -> Known_Bits { return kb_make(ap_lshr(k.zero, s), ap_lshr(k.one, s)); }   // operator>>=
kb_shl_const :: (k: Known_Bits, s: u32) -> Known_Bits { return kb_make(ap_shl(k.zero, s), ap_shl(k.one, s)); }     // operator<<=

kb_flip_sign_bit :: (v: Known_Bits) -> Known_Bits {
    p := kb_bits(v) - 1;
    z := ap_copy(v.zero); o := ap_copy(v.one);
    ap_set_bit_val(*z, p, ap_get_bit(v.one, p));
    ap_set_bit_val(*o, p, ap_get_bit(v.zero, p));
    return kb_make(z, o);
}

// KnownBits::computeForAddCarry (static helper in KnownBits.cpp)
kb_add_carry_impl :: (lhs: Known_Bits, rhs: Known_Bits, carry_zero: bool, carry_one: bool) -> Known_Bits {
    possible_sum_zero := ap_add_u64(ap_add(kb_max_value(lhs), kb_max_value(rhs)), ifx carry_zero then cast(u64) 0 else 1);
    possible_sum_one := ap_add_u64(ap_add(kb_min_value(lhs), kb_min_value(rhs)), ifx carry_one then cast(u64) 1 else 0);
    carry_known_zero := ap_not(ap_xor(ap_xor(possible_sum_zero, lhs.zero), rhs.zero));
    carry_known_one := ap_xor(ap_xor(possible_sum_one, lhs.one), rhs.one);
    lhs_known_union := ap_or(lhs.zero, lhs.one);
    rhs_known_union := ap_or(rhs.zero, rhs.one);
    carry_known_union := ap_or(carry_known_zero, carry_known_one);
    known := ap_and(ap_and(lhs_known_union, rhs_known_union), carry_known_union);
    r: Known_Bits;
    r.zero = ap_and(ap_not(possible_sum_zero), known);
    r.one = ap_and(possible_sum_one, known);
    return r;
}
kb_compute_for_add_carry :: (lhs: Known_Bits, rhs: Known_Bits, carry: Known_Bits) -> Known_Bits {
    return kb_add_carry_impl(lhs, rhs, !ap_is_zero(carry.zero), !ap_is_zero(carry.one));
}
kb_compute_for_sub_borrow :: (lhs: Known_Bits, rhs: Known_Bits, borrow: Known_Bits) -> Known_Bits {
    return kb_add_carry_impl(lhs, kb_not(rhs), !ap_is_zero(borrow.one), !ap_is_zero(borrow.zero));
}

// KnownBits::computeForAddSub(Add, NSW, NUW, LHS, RHS)
kb_compute_for_add_sub :: (add: bool, nsw: bool, nuw: bool, lhs: Known_Bits, rhs: Known_Bits) -> Known_Bits {
    bits := kb_bits(lhs);
    known_out := kb_new(bits);
    if kb_is_unknown(lhs) && kb_is_unknown(rhs) return known_out;
    if !kb_is_unknown(lhs) && !kb_is_unknown(rhs) {
        if add {
            known_out = kb_add_carry_impl(lhs, rhs, true, false);
        } else {
            not_rhs: Known_Bits; not_rhs.zero = rhs.one; not_rhs.one = rhs.zero;
            known_out = kb_add_carry_impl(lhs, not_rhs, false, true);
        }
    }
    if nuw {
        if add {
            min_val := ap_uadd_sat(kb_min_value(lhs), kb_min_value(rhs));
            if nsw {
                n := ap_clo(ap_trunc(min_val, bits - 1));
                ap_set_bits(*known_out.one, bits - 1 - n, bits - 1);
            }
            ap_set_bits(*known_out.one, bits - ap_clo(min_val), bits);
        } else {
            max_val := ap_usub_sat(kb_max_value(lhs), kb_min_value(rhs));
            if nsw {
                n := ap_clz(ap_trunc(max_val, bits - 1));
                ap_set_bits(*known_out.zero, bits - 1 - n, bits - 1);
            }
            ap_set_bits(*known_out.zero, bits - ap_clz(max_val), bits);
        }
    }
    if nsw {
        min_val, max_val: APInt;
        if add {
            min_val = ap_sadd_sat(kb_signed_min_value(lhs), kb_signed_min_value(rhs));
            max_val = ap_sadd_sat(kb_signed_max_value(lhs), kb_signed_max_value(rhs));
        } else {
            min_val = ap_ssub_sat(kb_signed_min_value(lhs), kb_signed_max_value(rhs));
            max_val = ap_ssub_sat(kb_signed_max_value(lhs), kb_signed_min_value(rhs));
        }
        if !ap_is_negative(min_val) {
            n := ap_clo(ap_trunc(min_val, bits - 1));
            ap_set_bits(*known_out.one, bits - 1 - n, bits - 1);
            ap_set_sign_bit(*known_out.zero);
        }
        if ap_is_negative(max_val) {
            n := ap_clz(ap_trunc(max_val, bits - 1));
            ap_set_bits(*known_out.zero, bits - 1 - n, bits - 1);
            ap_set_sign_bit(*known_out.one);
        }
    }
    if kb_has_conflict(known_out) kb_set_all_zero(*known_out);
    return known_out;
}
kb_add :: (lhs: Known_Bits, rhs: Known_Bits, nsw := false, nuw := false, self_add := false) -> Known_Bits {
    if self_add return kb_shl(lhs, kb_from_const(ap_from_u64(8, 1)), nuw, nsw, true);
    return kb_compute_for_add_sub(true, nsw, nuw, lhs, rhs);
}
kb_sub :: (lhs: Known_Bits, rhs: Known_Bits, nsw := false, nuw := false) -> Known_Bits {
    return kb_compute_for_add_sub(false, nsw, nuw, lhs, rhs);
}

kb_trunc_ssat :: (k: Known_Bits, bw: u32) -> Known_Bits {
    ib := kb_bits(k);
    min_in := ap_sext(ap_signed_min(bw), ib);
    max_in := ap_sext(ap_signed_max(bw), ib);
    imin := kb_signed_min_value(k);
    imax := kb_signed_max_value(k);
    known := kb_new(bw);
    if ap_sge(imin, min_in) && ap_sle(imax, max_in) known = kb_trunc(k, bw);
    else if ap_slt(imax, min_in) known = kb_from_const(ap_signed_min(bw));
    else if ap_sgt(imin, max_in) known = kb_from_const(ap_signed_max(bw));
    else if ap_is_non_negative(imin) {
        known.zero = ap_zero(bw); ap_set_bit(*known.zero, bw - 1);
        known.one = ap_trunc(k.one, bw); ap_clear_bit(*known.one, bw - 1);
    } else if ap_is_negative(imax) {
        known.zero = ap_trunc(k.zero, bw); ap_clear_bit(*known.zero, bw - 1);
        known.one = ap_zero(bw); ap_set_bit(*known.one, bw - 1);
    } else {
        zl := ap_trunc(k.zero, bw); ol := ap_trunc(k.one, bw);
        mn := kb_from_const(ap_signed_min(bw)); mx := kb_from_const(ap_signed_max(bw));
        if ap_sle(imax, max_in) { known.zero = ap_and(zl, mn.zero); known.one = ap_and(ol, mn.one); }
        else if ap_sge(imin, min_in) { known.zero = ap_and(zl, mx.zero); known.one = ap_and(ol, mx.one); }
        else { known.zero = ap_and(ap_and(zl, mn.zero), mx.zero); known.one = ap_and(ap_and(ol, mn.one), mx.one); }
    }
    return known;
}
kb_trunc_ssat_u :: (k: Known_Bits, bw: u32) -> Known_Bits {
    ib := kb_bits(k);
    max_in := ap_zext(ap_all_ones(bw), ib);
    imin := kb_signed_min_value(k);
    imax := kb_signed_max_value(k);
    known := kb_new(bw);
    if kb_is_negative(k) kb_set_all_zero(*known);
    else if ap_is_non_negative(imin) && ap_ule(imax, max_in) known = kb_trunc(k, bw);
    else if ap_is_non_negative(imin) && ap_ugt(imin, max_in) kb_set_all_ones(*known);
    else if ap_is_non_negative(imin) { known.zero = ap_zero(bw); known.one = ap_trunc(k.one, bw); }
    else {
        if ap_ule(imax, max_in) { known.zero = ap_trunc(k.zero, bw); known.one = ap_zero(bw); }
    }
    return known;
}
kb_trunc_usat :: (k: Known_Bits, bw: u32) -> Known_Bits {
    ib := kb_bits(k);
    max_in := ap_low_bits_set(ib, bw);
    known := kb_new(bw);
    if ap_ule(kb_max_value(k), max_in) known = kb_trunc(k, bw);
    else if ap_ugt(kb_min_value(k), max_in) kb_set_all_ones(*known);
    else known.one = ap_trunc(k.one, bw);
    return known;
}
kb_sext_in_reg :: (k: Known_Bits, src_bits: u32) -> Known_Bits {
    bw := kb_bits(k);
    if src_bits == bw return k;
    ext := bw - src_bits;
    return kb_make(ap_ashr(ap_shl(k.zero, ext), ext), ap_ashr(ap_shl(k.one, ext), ext));
}
kb_make_ge :: (k: Known_Bits, val: APInt) -> Known_Bits {
    n := ap_clo(ap_or(k.zero, val));
    masked := ap_copy(val);
    ap_clear_low_bits(*masked, kb_bits(k) - n);
    return kb_make(k.zero, ap_or(k.one, masked));
}
kb_umax :: (lhs: Known_Bits, rhs: Known_Bits) -> Known_Bits {
    if ap_uge(kb_min_value(lhs), kb_max_value(rhs)) return lhs;
    if ap_uge(kb_min_value(rhs), kb_max_value(lhs)) return rhs;
    l := kb_make_ge(lhs, kb_min_value(rhs));
    r := kb_make_ge(rhs, kb_min_value(lhs));
    return kb_intersect(l, r);
}
kb_umin :: (lhs: Known_Bits, rhs: Known_Bits) -> Known_Bits { return kb_not(kb_umax(kb_not(lhs), kb_not(rhs))); }
kb_smax :: (lhs: Known_Bits, rhs: Known_Bits) -> Known_Bits { return kb_flip_sign_bit(kb_umax(kb_flip_sign_bit(lhs), kb_flip_sign_bit(rhs))); }
kb_smin :: (lhs: Known_Bits, rhs: Known_Bits) -> Known_Bits {
    flip :: (v: Known_Bits) -> Known_Bits {
        p := kb_bits(v) - 1;
        z := ap_copy(v.one); o := ap_copy(v.zero);
        ap_set_bit_val(*z, p, ap_get_bit(v.zero, p));
        ap_set_bit_val(*o, p, ap_get_bit(v.one, p));
        return kb_make(z, o);
    }
    return flip(kb_umax(flip(lhs), flip(rhs)));
}
kb_abdu :: (lhs: Known_Bits, rhs: Known_Bits) -> Known_Bits {
    if ap_uge(kb_min_value(lhs), kb_max_value(rhs)) return kb_compute_for_add_sub(false, false, false, lhs, rhs);
    if ap_uge(kb_min_value(rhs), kb_max_value(lhs)) return kb_compute_for_add_sub(false, false, false, rhs, lhs);
    d0 := kb_compute_for_add_sub(false, false, true, lhs, rhs);
    d1 := kb_compute_for_add_sub(false, false, true, rhs, lhs);
    return kb_intersect(d0, d1);
}
kb_abds :: (lhs_in: Known_Bits, rhs_in: Known_Bits) -> Known_Bits {
    lhs := lhs_in; rhs := rhs_in;
    if ap_sge(kb_signed_min_value(lhs), kb_signed_max_value(rhs)) return kb_compute_for_add_sub(false, false, false, lhs, rhs);
    if ap_sge(kb_signed_min_value(rhs), kb_signed_max_value(lhs)) return kb_compute_for_add_sub(false, false, false, rhs, lhs);
    lhs = kb_flip_sign_bit(lhs); rhs = kb_flip_sign_bit(rhs);
    d0 := kb_compute_for_add_sub(false, false, true, lhs, rhs);
    d1 := kb_compute_for_add_sub(false, false, true, rhs, lhs);
    return kb_intersect(d0, d1);
}

is_power_of_2_u32 :: (x: u32) -> bool { return x != 0 && (x & (x - 1)) == 0; }
log2_u32 :: (x: u32) -> u32 { return 63 - clz64(cast(u64) x); }   // Log2_32 (x != 0)
log2_ceil_u32 :: (x: u32) -> u32 { if x <= 1 return 0; return 64 - clz64(cast(u64)(x - 1)); }

kb_max_shift_amount :: (max_value: APInt, bits: u32) -> u32 {
    if is_power_of_2_u32(bits) {
        n := min(log2_u32(bits), max_value.bits);
        return cast(u32)(ap_word(max_value, 0) & ap_mask64(n));
    }
    return cast(u32) ap_limited(max_value, bits - 1);
}
kb_shift_masks :: (rhs: Known_Bits) -> (zm: u32, om: u32) {
    zm := cast(u32)(ap_word(ap_zext_or_trunc(rhs.zero, 32), 0));
    om := cast(u32)(ap_word(ap_zext_or_trunc(rhs.one, 32), 0));
    return zm, om;
}

// KnownBits::shl
kb_shl :: (lhs: Known_Bits, rhs: Known_Bits, nuw := false, nsw := false, sh_amt_non_zero := false) -> Known_Bits {
    bits := kb_bits(lhs);
    by_const :: (lhs: Known_Bits, s: u32, nuw: bool, nsw: bool) -> Known_Bits {
        bits := kb_bits(lhs);
        k: Known_Bits;
        out_zero := s >= bits || s > ap_clz(lhs.zero);   // APInt::ushl_ov
        out_one := s >= bits || s > ap_clz(lhs.one);
        k.zero = ap_shl(lhs.zero, s);
        ap_set_bits(*k.zero, 0, min(s, bits));
        k.one = ap_shl(lhs.one, s);
        if nsw {
            if nuw && s != 0 out_zero = true;
            if out_zero kb_make_non_negative(*k);
            else if out_one kb_make_negative(*k);
        }
        return k;
    }
    known := kb_new(bits);
    mn := cast(u32) ap_limited(kb_min_value(rhs), bits);
    if mn == 0 && sh_amt_non_zero mn = 1;
    if kb_is_unknown(lhs) {
        ap_set_bits(*known.zero, 0, min(mn, bits));
        if nuw && nsw && mn != 0 kb_make_non_negative(*known);
        return known;
    }
    mx := kb_max_shift_amount(kb_max_value(rhs), bits);
    // (unsigned arithmetic: countMaxLeadingZeros() - 1 may wrap to UINT_MAX)
    if nuw && nsw mx = min(mx, kb_count_max_leading_zeros(lhs) - 1);
    if nuw mx = min(mx, kb_count_max_leading_zeros(lhs));
    if nsw mx = min(mx, max(kb_count_max_leading_zeros(lhs), kb_count_max_leading_ones(lhs)) - 1);
    if mn == 0 && mx == bits - 1 && is_power_of_2_u32(bits) {
        ap_set_bits(*known.zero, 0, kb_count_min_trailing_zeros(lhs));
        if kb_is_all_ones(lhs) ap_set_sign_bit(*known.one);
        if nsw {
            if kb_is_non_negative(lhs) kb_make_non_negative(*known);
            if kb_is_negative(lhs) kb_make_negative(*known);
        }
        return known;
    }
    zm, om := kb_shift_masks(rhs);
    kb_set_all_conflict(*known);
    s := mn;
    while s <= mx {
        if (zm & s) == 0 && (om | s) == s {
            known = kb_intersect(known, by_const(lhs, s, nuw, nsw));
            if kb_is_unknown(known) break;
        }
        if s == 0xFFFF_FFFF break;
        s += 1;
    }
    if kb_has_conflict(known) kb_set_all_zero(*known);
    return known;
}

kb_shr_impl :: (lhs: Known_Bits, rhs: Known_Bits, sh_amt_non_zero: bool, exact: bool, arith: bool) -> Known_Bits {
    bits := kb_bits(lhs);
    known := kb_new(bits);
    mn := cast(u32) ap_limited(kb_min_value(rhs), bits);
    if mn == 0 && sh_amt_non_zero mn = 1;
    if kb_is_unknown(lhs) {
        if !arith { ap_set_bits(*known.zero, bits - min(mn, bits), bits); return known; }
        if mn == bits kb_set_all_zero(*known);
        return known;
    }
    mx := kb_max_shift_amount(kb_max_value(rhs), bits);
    if exact {
        first_one := kb_count_max_trailing_zeros(lhs);
        if first_one < mn { kb_set_all_zero(*known); return known; }
        mx = min(mx, first_one);
    }
    zm, om := kb_shift_masks(rhs);
    kb_set_all_conflict(*known);
    s := mn;
    while s <= mx {
        if (zm & s) == 0 && (om | s) == s {
            k: Known_Bits;
            if arith { k.zero = ap_ashr(lhs.zero, s); k.one = ap_ashr(lhs.one, s); }
            else {
                k.zero = ap_lshr(lhs.zero, s); k.one = ap_lshr(lhs.one, s);
                ap_set_bits(*k.zero, bits - min(s, bits), bits);
            }
            known = kb_intersect(known, k);
            if kb_is_unknown(known) break;
        }
        if s == 0xFFFF_FFFF break;
        s += 1;
    }
    if kb_has_conflict(known) kb_set_all_zero(*known);
    return known;
}
kb_lshr :: (lhs: Known_Bits, rhs: Known_Bits, sh_amt_non_zero := false, exact := false) -> Known_Bits { return kb_shr_impl(lhs, rhs, sh_amt_non_zero, exact, false); }
kb_ashr :: (lhs: Known_Bits, rhs: Known_Bits, sh_amt_non_zero := false, exact := false) -> Known_Bits { return kb_shr_impl(lhs, rhs, sh_amt_non_zero, exact, true); }

// APIntOps::fshl / fshr
ap_fshl :: (hi: APInt, lo: APInt, sh: APInt) -> APInt {
    bw := hi.bits;
    s := cast(u32) ap_urem_u64(sh, bw);
    if s == 0 return hi;
    return ap_or(ap_shl(hi, s), ap_lshr(lo, bw - s));
}
ap_fshr :: (hi: APInt, lo: APInt, sh: APInt) -> APInt {
    bw := hi.bits;
    s := cast(u32) ap_urem_u64(sh, bw);
    if s == 0 return lo;
    return ap_or(ap_shl(hi, bw - s), ap_lshr(lo, s));
}
kb_fshl :: (lhs: Known_Bits, rhs: Known_Bits, amt: APInt) -> Known_Bits { return kb_make(ap_fshl(lhs.zero, rhs.zero, amt), ap_fshl(lhs.one, rhs.one, amt)); }
kb_fshr :: (lhs: Known_Bits, rhs: Known_Bits, amt: APInt) -> Known_Bits { return kb_make(ap_fshr(lhs.zero, rhs.zero, amt), ap_fshr(lhs.one, rhs.one, amt)); }

// APIntOps::clmul
ap_clmul :: (a: APInt, b: APInt) -> APInt {
    r := ap_zero(a.bits);
    for i: 0..cast(s64) a.bits - 1 if ap_get_bit(b, cast(u32) i) r = ap_xor(r, ap_shl(a, cast(u32) i));
    return r;
}
kb_clmul :: (lhs: Known_Bits, rhs: Known_Bits) -> Known_Bits {
    res := kb_from_const(ap_clmul(kb_min_value(lhs), kb_min_value(rhs)));
    clmul_or :: (l: APInt, r: APInt) -> APInt {
        bw := l.bits;
        result := ap_zero(bw);
        n := min(ap_active_bits(r), bw - ap_ctz(l));
        for i: 0..cast(s64) n - 1 if ap_get_bit(r, cast(u32) i) result = ap_or(result, ap_shl(l, cast(u32) i));
        return result;
    }
    known := ap_not(ap_or(clmul_or(ap_and(ap_not(lhs.zero), ap_not(lhs.one)), ap_not(rhs.zero)),
                          clmul_or(ap_not(lhs.zero), ap_and(ap_not(rhs.zero), ap_not(rhs.one)))));
    res.zero = ap_and(res.zero, known);
    res.one = ap_and(res.one, known);
    return res;
}

// KnownBits::eq ... sle: 0 = false, 1 = true, -1 = unknown (std::optional<bool>)
kb_cmp_eq :: (l: Known_Bits, r: Known_Bits) -> s8 {
    if kb_is_constant(l) && kb_is_constant(r) return ifx ap_eq(kb_constant(l), kb_constant(r)) then cast(s8) 1 else 0;
    if ap_intersects(l.one, r.zero) || ap_intersects(r.one, l.zero) return 0;
    return -1;
}
kb_cmp_ne :: (l: Known_Bits, r: Known_Bits) -> s8 { e := kb_cmp_eq(l, r); if e < 0 return -1; return 1 - e; }
kb_cmp_ugt :: (l: Known_Bits, r: Known_Bits) -> s8 {
    if ap_ule(kb_max_value(l), kb_min_value(r)) return 0;
    if ap_ugt(kb_min_value(l), kb_max_value(r)) return 1;
    return -1;
}
kb_cmp_uge :: (l: Known_Bits, r: Known_Bits) -> s8 { g := kb_cmp_ugt(r, l); if g < 0 return -1; return 1 - g; }
kb_cmp_ult :: (l: Known_Bits, r: Known_Bits) -> s8 { return kb_cmp_ugt(r, l); }
kb_cmp_ule :: (l: Known_Bits, r: Known_Bits) -> s8 { return kb_cmp_uge(r, l); }
kb_cmp_sgt :: (l: Known_Bits, r: Known_Bits) -> s8 {
    if ap_sle(kb_signed_max_value(l), kb_signed_min_value(r)) return 0;
    if ap_sgt(kb_signed_min_value(l), kb_signed_max_value(r)) return 1;
    return -1;
}
kb_cmp_sge :: (l: Known_Bits, r: Known_Bits) -> s8 { g := kb_cmp_sgt(r, l); if g < 0 return -1; return 1 - g; }
kb_cmp_slt :: (l: Known_Bits, r: Known_Bits) -> s8 { return kb_cmp_sgt(r, l); }
kb_cmp_sle :: (l: Known_Bits, r: Known_Bits) -> s8 { return kb_cmp_sge(r, l); }

// KnownBits::abs
kb_abs :: (k: Known_Bits, int_min_is_poison := false) -> Known_Bits {
    if kb_is_non_negative(k) return k;
    bw := kb_bits(k);
    known_abs := kb_new(bw);
    if kb_is_negative(k) {
        tmp := k;
        if int_min_is_poison && ap_popcount(k.zero) + 2 == bw { tmp.one = ap_copy(tmp.one); ap_set_bit(*tmp.one, kb_count_min_trailing_zeros(k)); }
        known_abs = kb_compute_for_add_sub(false, int_min_is_poison, false, kb_from_const(ap_zero(bw)), tmp);
        if int_min_is_poison && kb_count_min_population(tmp) == 1 && kb_count_max_population(tmp) != 1 {
            tmp.one = ap_copy(tmp.one); tmp.zero = ap_copy(tmp.zero);
            ap_clear_sign_bit(*tmp.one);
            ap_set_sign_bit(*tmp.zero);
            ap_set_bits(*known_abs.one, bw - kb_count_min_leading_zeros(tmp), bw - 1);
        }
    } else {
        max_tz := kb_count_max_trailing_zeros(k);
        min_tz := kb_count_min_trailing_zeros(k);
        ap_set_low_bits(*known_abs.zero, min_tz);
        if max_tz == min_tz && max_tz < bw ap_set_bit(*known_abs.one, max_tz);
        if int_min_is_poison || (!ap_is_zero(k.one) && !ap_is_min_signed(k.one)) {
            ap_clear_sign_bit(*known_abs.one);
            ap_set_sign_bit(*known_abs.zero);
        }
    }
    return known_abs;
}

kb_reduce_add :: (k: Known_Bits, n: u32) -> Known_Bits {
    bw := kb_bits(k);
    if n == 0 return kb_new(bw);
    result := kb_new(bw);
    if kb_is_constant(k) return kb_from_const(ap_mul(ap_from_u64(bw, n), kb_constant(k)));
    lost := log2_ceil_u32(n);
    if kb_is_non_negative(k) {
        lz := kb_count_min_leading_zeros(k);
        lz = ifx lz > lost then lz - lost else 0;
        ap_set_high_bits(*result.zero, lz);
    } else if kb_is_negative(k) {
        lo := kb_count_min_leading_ones(k);
        lo = ifx lo > lost then lo - lost else 0;
        ap_set_high_bits(*result.one, lo);
    }
    return result;
}

kb_compute_for_sat_add_sub :: (add: bool, signed: bool, lhs: Known_Bits, rhs: Known_Bits) -> Known_Bits {
    bw := kb_bits(lhs);
    overflow: s8 = -1;
    may_neg_clamp := true; may_pos_clamp := true;
    if signed {
        if add && ((kb_is_negative(lhs) && kb_is_non_negative(rhs)) || (kb_is_non_negative(lhs) && kb_is_negative(rhs))) overflow = 0;
        else if !add && ((kb_is_negative(lhs) && kb_is_negative(rhs)) || (kb_is_non_negative(lhs) && kb_is_non_negative(rhs))) overflow = 0;
        else {
            ul := lhs; ur := rhs;
            ul.one = ap_copy(ul.one); ul.zero = ap_copy(ul.zero); ur.one = ap_copy(ur.one); ur.zero = ap_copy(ur.zero);
            ap_clear_sign_bit(*ul.one); ap_set_sign_bit(*ul.zero);
            ap_clear_sign_bit(*ur.one); ap_set_sign_bit(*ur.zero);
            res := kb_compute_for_add_sub(add, false, false, ul, ur);
            if add {
                if kb_is_negative(res) {
                    may_neg_clamp = false;
                    if kb_is_non_negative(lhs) && kb_is_non_negative(rhs) overflow = 1;
                } else if kb_is_non_negative(res) {
                    may_pos_clamp = false;
                    if kb_is_negative(lhs) && kb_is_negative(rhs) overflow = 1;
                }
                if kb_is_negative(lhs) || kb_is_negative(rhs) may_pos_clamp = false;
                if kb_is_non_negative(lhs) || kb_is_non_negative(rhs) may_neg_clamp = false;
            } else {
                if kb_is_negative(res) {
                    may_pos_clamp = false;
                    if kb_is_negative(lhs) && kb_is_non_negative(rhs) overflow = 1;
                } else if kb_is_non_negative(res) {
                    may_neg_clamp = false;
                    if kb_is_non_negative(lhs) && kb_is_negative(rhs) overflow = 1;
                }
                if kb_is_negative(lhs) || kb_is_non_negative(rhs) may_pos_clamp = false;
                if kb_is_non_negative(lhs) || kb_is_negative(rhs) may_neg_clamp = false;
            }
        }
        if !may_neg_clamp && !may_pos_clamp overflow = 0;
    } else if add {
        _, of := ap_uadd_ov(kb_max_value(lhs), kb_max_value(rhs));
        if !of overflow = 0;
        else { _, of2 := ap_uadd_ov(kb_min_value(lhs), kb_min_value(rhs)); if of2 overflow = 1; }
    } else {
        _, of := ap_usub_ov(kb_min_value(lhs), kb_max_value(rhs));
        if !of overflow = 0;
        else { _, of2 := ap_usub_ov(kb_max_value(lhs), kb_min_value(rhs)); if of2 overflow = 1; }
    }
    res := kb_compute_for_add_sub(add, signed, !signed, lhs, rhs);
    if overflow >= 0 {
        if overflow == 0 return res;
        c: APInt;
        if signed c = ifx kb_is_negative(lhs) then ap_signed_min(bw) else ap_signed_max(bw);
        else if add c = ap_all_ones(bw);
        else c = ap_zero(bw);
        return kb_from_const(c);
    }
    if signed {
        if may_pos_clamp { res.zero = ap_copy(res.zero); ap_clear_low_bits(*res.zero, bw - 1); }
        if may_neg_clamp { res.one = ap_copy(res.one); ap_clear_low_bits(*res.one, bw - 1); }
    } else if add res.zero = ap_zero(bw);
    else res.one = ap_zero(bw);
    return res;
}
kb_sadd_sat :: (l: Known_Bits, r: Known_Bits) -> Known_Bits { return kb_compute_for_sat_add_sub(true, true, l, r); }
kb_ssub_sat :: (l: Known_Bits, r: Known_Bits) -> Known_Bits { return kb_compute_for_sat_add_sub(false, true, l, r); }
kb_uadd_sat :: (l: Known_Bits, r: Known_Bits) -> Known_Bits { return kb_compute_for_sat_add_sub(true, false, l, r); }
kb_usub_sat :: (l: Known_Bits, r: Known_Bits) -> Known_Bits { return kb_compute_for_sat_add_sub(false, false, l, r); }

kb_avg_compute_u :: (lhs_in: Known_Bits, rhs_in: Known_Bits, is_ceil: bool) -> Known_Bits {
    bw := kb_bits(lhs_in);
    l := kb_zext(lhs_in, bw + 1); r := kb_zext(rhs_in, bw + 1);
    l = kb_add_carry_impl(l, r, !is_ceil, is_ceil);
    return kb_extract_bits(l, bw, 1);
}
kb_avg_floor_u :: (l: Known_Bits, r: Known_Bits) -> Known_Bits { return kb_avg_compute_u(l, r, false); }
kb_avg_ceil_u :: (l: Known_Bits, r: Known_Bits) -> Known_Bits { return kb_avg_compute_u(l, r, true); }
kb_avg_floor_s :: (l: Known_Bits, r: Known_Bits) -> Known_Bits { return kb_flip_sign_bit(kb_avg_floor_u(kb_flip_sign_bit(l), kb_flip_sign_bit(r))); }
kb_avg_ceil_s :: (l: Known_Bits, r: Known_Bits) -> Known_Bits { return kb_flip_sign_bit(kb_avg_ceil_u(kb_flip_sign_bit(l), kb_flip_sign_bit(r))); }

// KnownBits::mul
kb_mul :: (lhs: Known_Bits, rhs: Known_Bits, no_undef_self_multiply := false) -> Known_Bits {
    bw := kb_bits(lhs);
    umax_result, has_overflow := ap_umul_ov(kb_max_value(lhs), kb_max_value(rhs));
    lead_z := ifx has_overflow then cast(u32) 0 else ap_clz(umax_result);
    trail_known_l := ap_cto(ap_or(lhs.zero, lhs.one));
    trail_known_r := ap_cto(ap_or(rhs.zero, rhs.one));
    tz_l := kb_count_min_trailing_zeros(lhs);
    tz_r := kb_count_min_trailing_zeros(rhs);
    trail_z := tz_l + tz_r;
    smallest := min(trail_known_l - tz_l, trail_known_r - tz_r);
    result_known := min(smallest + trail_z, bw);
    bottom := ap_mul(lhs.one, rhs.one);
    res := kb_new(bw);
    ap_set_high_bits(*res.zero, lead_z);
    res.zero = ap_or(res.zero, ap_get_lo_bits(ap_not(bottom), result_known));
    res.one = ap_get_lo_bits(bottom, result_known);
    if no_undef_self_multiply {
        two_tzp1 := 2 * tz_l + 1;
        if two_tzp1 < bw ap_set_bit(*res.zero, two_tzp1);
        if tz_l < bw && ap_get_bit(lhs.one, tz_l) {
            two_tzp2 := two_tzp1 + 1;
            if two_tzp2 < bw ap_set_bit(*res.zero, two_tzp2);
        }
    }
    return res;
}
kb_mulhs :: (l: Known_Bits, r: Known_Bits) -> Known_Bits { bw := kb_bits(l); return kb_extract_bits(kb_mul(kb_sext(l, 2 * bw), kb_sext(r, 2 * bw)), bw, bw); }
kb_mulhu :: (l: Known_Bits, r: Known_Bits) -> Known_Bits { bw := kb_bits(l); return kb_extract_bits(kb_mul(kb_zext(l, 2 * bw), kb_zext(r, 2 * bw)), bw, bw); }

kb_div_compute_low_bit :: (known_in: Known_Bits, lhs: Known_Bits, rhs: Known_Bits, exact: bool) -> Known_Bits {
    if !exact return known_in;
    known := known_in;
    known.zero = ap_copy(known.zero); known.one = ap_copy(known.one);
    if ap_get_bit(lhs.one, 0) ap_set_bit(*known.one, 0);
    min_tz := cast(s32) kb_count_min_trailing_zeros(lhs) - cast(s32) kb_count_max_trailing_zeros(rhs);
    max_tz := cast(s32) kb_count_max_trailing_zeros(lhs) - cast(s32) kb_count_min_trailing_zeros(rhs);
    if min_tz >= 0 {
        ap_set_low_bits(*known.zero, cast(u32) min_tz);
        if min_tz == max_tz ap_set_bit(*known.one, cast(u32) min_tz);
    } else if max_tz < 0 kb_set_all_zero(*known);
    if kb_has_conflict(known) kb_set_all_zero(*known);
    return known;
}
kb_sdiv :: (lhs: Known_Bits, rhs: Known_Bits, exact := false) -> Known_Bits {
    if kb_is_non_negative(lhs) && kb_is_non_negative(rhs) return kb_udiv(lhs, rhs, exact);
    bw := kb_bits(lhs);
    known := kb_new(bw);
    if kb_is_zero(lhs) || kb_is_zero(rhs) { kb_set_all_zero(*known); return known; }
    has := false; res: APInt;
    if kb_is_negative(lhs) && kb_is_negative(rhs) {
        denom := kb_signed_max_value(rhs); num := kb_signed_min_value(lhs);
        res = ifx ap_is_min_signed(num) && ap_is_all_ones(denom) then ap_signed_max(bw) else ap_sdiv(num, denom);
        has = true;
    } else if kb_is_negative(lhs) && kb_is_non_negative(rhs) {
        if exact || ap_uge(ap_neg(kb_signed_max_value(lhs)), kb_signed_max_value(rhs)) {
            denom := kb_signed_min_value(rhs); num := kb_signed_min_value(lhs);
            res = ifx ap_is_zero(denom) then num else ap_sdiv(num, denom);
            has = true;
        }
    } else if kb_is_strictly_positive(lhs) && kb_is_negative(rhs) {
        if exact || ap_uge(kb_signed_min_value(lhs), ap_neg(kb_signed_min_value(rhs))) {
            denom := kb_signed_max_value(rhs); num := kb_signed_max_value(lhs);
            res = ap_sdiv(num, denom);
            has = true;
        }
    }
    if has {
        if ap_is_non_negative(res) ap_set_high_bits(*known.zero, ap_clz(res));
        else ap_set_high_bits(*known.one, ap_clo(res));
    }
    return kb_div_compute_low_bit(known, lhs, rhs, exact);
}
kb_udiv :: (lhs: Known_Bits, rhs: Known_Bits, exact := false) -> Known_Bits {
    bw := kb_bits(lhs);
    known := kb_new(bw);
    if kb_is_zero(lhs) || kb_is_zero(rhs) { kb_set_all_zero(*known); return known; }
    min_denom := kb_min_value(rhs);
    max_num := kb_max_value(lhs);
    max_res := ifx ap_is_zero(min_denom) then max_num else ap_udiv(max_num, min_denom);
    ap_set_high_bits(*known.zero, ap_clz(max_res));
    return kb_div_compute_low_bit(known, lhs, rhs, exact);
}
kb_rem_get_low_bits :: (lhs: Known_Bits, rhs: Known_Bits) -> Known_Bits {
    bw := kb_bits(lhs);
    if !kb_is_zero(rhs) && ap_get_bit(rhs.zero, 0) {
        mask := ap_low_bits_set(bw, kb_count_min_trailing_zeros(rhs));
        return kb_make(ap_and(lhs.zero, mask), ap_and(lhs.one, mask));
    }
    return kb_new(bw);
}
kb_urem :: (lhs: Known_Bits, rhs: Known_Bits) -> Known_Bits {
    known := kb_rem_get_low_bits(lhs, rhs);
    if kb_is_constant(rhs) && ap_is_power_of_2(kb_constant(rhs)) {
        high := ap_not(ap_sub_u64(kb_constant(rhs), 1));
        known.zero = ap_or(known.zero, high);
        return known;
    }
    leaders := max(kb_count_min_leading_zeros(lhs), kb_count_min_leading_zeros(rhs));
    known.zero = ap_copy(known.zero);
    ap_set_high_bits(*known.zero, leaders);
    return known;
}
kb_srem :: (lhs: Known_Bits, rhs: Known_Bits) -> Known_Bits {
    known := kb_rem_get_low_bits(lhs, rhs);
    if kb_is_constant(rhs) && ap_is_power_of_2(kb_constant(rhs)) {
        low := ap_sub_u64(kb_constant(rhs), 1);
        if kb_is_non_negative(lhs) || ap_is_subset_of(low, lhs.zero) known.zero = ap_or(known.zero, ap_not(low));
        if kb_is_negative(lhs) && ap_intersects(low, lhs.one) known.one = ap_or(known.one, ap_not(low));
        return known;
    }
    known.zero = ap_copy(known.zero); known.one = ap_copy(known.one);
    if kb_is_negative(lhs) && kb_is_non_zero(known)
        ap_set_high_bits(*known.one, max(kb_count_min_leading_ones(lhs), kb_count_min_sign_bits(rhs)));
    else if kb_is_non_negative(lhs)
        ap_set_high_bits(*known.zero, max(kb_count_min_leading_zeros(lhs), kb_count_min_sign_bits(rhs)));
    return known;
}
kb_blsi :: (k: Known_Bits) -> Known_Bits {
    bw := kb_bits(k);
    known := kb_make(ap_copy(k.zero), ap_zero(bw));
    mx := kb_count_max_trailing_zeros(k);
    ap_set_bits_from(*known.zero, min(mx + 1, bw));
    mn := kb_count_min_trailing_zeros(k);
    if mx == mn && mx < bw ap_set_bit(*known.one, mx);
    return known;
}
kb_blsmsk :: (k: Known_Bits) -> Known_Bits {
    bw := kb_bits(k);
    known := kb_new(bw);
    mx := kb_count_max_trailing_zeros(k);
    ap_set_bits_from(*known.zero, min(mx + 1, bw));
    mn := kb_count_min_trailing_zeros(k);
    ap_set_low_bits(*known.one, min(mn + 1, bw));
    return known;
}

// KnownBits::pext
kb_pext :: (val: Known_Bits, mask: Known_Bits) -> Known_Bits {
    bw := val.zero.bits;
    res: Known_Bits;
    res.zero = ap_all_ones(bw); res.one = ap_all_ones(bw);   // setAllConflict
    m0, m1: u32 = 0, 0;
    for i: 0..bw-1 {
        if !ap_get_bit(mask.zero, i) {
            if !ap_get_bit(val.zero, i) ap_clear_bits_range(*res.zero, m0, m1 + 1);
            if !ap_get_bit(val.one, i) ap_clear_bits_range(*res.one, m0, m1 + 1);
        }
        if ap_get_bit(mask.one, i) { m0 += 1; m1 += 1; }
        else if !ap_get_bit(mask.zero, i) m1 += 1;
    }
    ap_clear_bits_range(*res.one, m0, bw);
    return res;
}

// KnownBits::pdep
kb_pdep :: (val: Known_Bits, mask: Known_Bits) -> Known_Bits {
    bw := val.zero.bits;
    res: Known_Bits;
    res.zero = ap_all_ones(bw); res.one = ap_all_ones(bw);
    m0, m1: u32 = 0, 0;
    for i: 0..bw-1 {
        if !ap_get_bit(mask.one, i) ap_clear_bit(*res.one, i);
        if !ap_get_bit(mask.zero, i) {
            range := ap_bits_set(bw, m0, m1 + 1);
            if !ap_is_subset_of(range, val.one) ap_clear_bit(*res.one, i);
            if !ap_is_subset_of(range, val.zero) ap_clear_bit(*res.zero, i);
        }
        if ap_get_bit(mask.one, i) { m0 += 1; m1 += 1; }
        else if !ap_get_bit(mask.zero, i) m1 += 1;
    }
    return res;
}
