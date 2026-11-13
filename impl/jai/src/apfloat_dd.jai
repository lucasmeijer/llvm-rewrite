// ppc_fp128 arithmetic: APFloat's DoubleAPFloat (a pair of doubles, words [hi, lo], value hi + lo).
// Ported from llvm/lib/Support/APFloat.cpp: DoubleAPFloat (addImpl, addWithSpecial, add, subtract, multiply,
// divide, remainder, mod, fusedMultiplyAdd, roundToIntegral, compare, compareAbsoluteValue, next,
// convertToSignExtendedInteger, convertToInteger, handleOverflow, convertFromUnsignedParts, convertFromAPInt,
// isDenormal, isSmallest, isSmallestNormalized, isLargest, isInteger, toString, convertFromString,
// getExactLog2Abs, makeLargest/Smallest/SmallestNormalized/NaN), fastTwoSum, harrisonUlp, ilogb/scalbn/frexp of a
// DoubleAPFloat, APFloat::convert between IEEE and double-double, IEEEFloat::initFromPPCDoubleDoubleLegacyAPInt and
// convertPPCDoubleDoubleLegacyAPFloatToAPInt.
//
// Operations LLVM implements through semPPCDoubleDoubleLegacy (divide, remainder, mod, fma, string conversion,
// conversion from other IEEE formats) use the internal Type_Kind PPC_LEGACY: an IEEE format with 106 bits of
// precision and minExponent -969, handled by the generic IEEE code in apfloat.jai / apfloat_ops.jai.

DD_SIGN : u64 : 0x8000_0000_0000_0000;
sgn_bit :: inline (neg: bool) -> u64 { if neg return DD_SIGN; return 0; }

dd_w1 :: (x: u64) -> [] u64 { r := NewArray(1, u64,, allocator = temp); r[0] = x; return r; }
dd_make :: (hi: u64, lo: u64) -> [] u64 { r := NewArray(2, u64,, allocator = temp); r[0] = hi; r[1] = lo; return r; }

// IEEE double helpers (APFloat on semIEEEdouble)
d_cat :: (x: u64) -> Fp_Category { return fp_decode(.DOUBLE, dd_w1(x)).cat; }
d_neg :: inline (x: u64) -> bool { return (x >> 63) != 0; }
d_is_finite :: (x: u64) -> bool { c := d_cat(x); return c == .ZERO || c == .NORMAL; }
d_is_zero :: (x: u64) -> bool { return (x & ~DD_SIGN) == 0; }
d_is_inf :: (x: u64) -> bool { return d_cat(x) == .INF; }
d_is_finite_nonzero :: (x: u64) -> bool { return d_cat(x) == .NORMAL; }
d_add :: (a: u64, b: u64, rm: u8 = RM_NEAREST_TIES_TO_EVEN) -> u64, Fp_Status { w, st := fp_add_sub(.DOUBLE, dd_w1(a), dd_w1(b), false, rm); return w[0], st; }
d_sub :: (a: u64, b: u64, rm: u8 = RM_NEAREST_TIES_TO_EVEN) -> u64, Fp_Status { w, st := fp_add_sub(.DOUBLE, dd_w1(a), dd_w1(b), true, rm); return w[0], st; }
d_mul :: (a: u64, b: u64, rm: u8 = RM_NEAREST_TIES_TO_EVEN) -> u64, Fp_Status { w, st := fp_mul(.DOUBLE, dd_w1(a), dd_w1(b), rm); return w[0], st; }
d_fma :: (a: u64, b: u64, c: u64, rm: u8 = RM_NEAREST_TIES_TO_EVEN) -> u64, Fp_Status { w, st := fp_fma(.DOUBLE, dd_w1(a), dd_w1(b), dd_w1(c), rm); return w[0], st; }
d_cmp :: (a: u64, b: u64) -> Fp_Cmp { return fp_compare(.DOUBLE, dd_w1(a), dd_w1(b)); }
// IEEEFloat::compareAbsoluteValue (finite operands)
d_cmp_abs :: (a: u64, b: u64) -> Fp_Cmp { return fp_compare(.DOUBLE, dd_w1(a & ~DD_SIGN), dd_w1(b & ~DD_SIGN)); }
d_round_to_integral :: (x: u64, rm: u8) -> u64, Fp_Status { w, st := fp_round_to_integral(.DOUBLE, dd_w1(x), rm); return w[0], st; }
d_next :: (x: u64, down: bool) -> u64 { w, st := fp_next(.DOUBLE, dd_w1(x), down); return w[0]; }
d_scalbn :: (x: u64, e: s64, rm: u8) -> u64 { return fp_scalbn(.DOUBLE, dd_w1(x), e, rm)[0]; }
d_ilogb :: (x: u64) -> s64 { return fp_ilogb(.DOUBLE, dd_w1(x)); }
d_is_denormal :: (x: u64) -> bool { return d_cat(x) == .NORMAL && ((x >> 52) & 0x7ff) == 0; }
d_is_smallest_normalized :: (x: u64) -> bool { return (x & ~DD_SIGN) == 0x0010_0000_0000_0000; }
d_is_largest :: (x: u64) -> bool { return (x & ~DD_SIGN) == 0x7fef_ffff_ffff_ffff; }
d_is_signaling :: (x: u64) -> bool { return d_cat(x) == .NAN && ((x >> 51) & 1) == 0; }
D_ONE :: 0x3ff0_0000_0000_0000;
D_SMALLEST :: 0x0000_0000_0000_0001;
// IEEEFloat::getExactLog2Abs: the exponent of a finite nonzero power of two, else INT_MIN

d_exact_log2_abs :: (x: u64) -> s64 {
    if d_cat(x) != .NORMAL return INT_MIN32;
    d := fp_decode(.DOUBLE, dd_w1(x));
    if big_any_below(d.sig, big_bitlen(d.sig) - 1) return INT_MIN32;
    return d_ilogb(x);
}
// IEEEFloat::isInteger
d_is_integer :: (x: u64) -> bool {
    if !d_is_finite(x) return false;
    r, st := d_round_to_integral(x, RM_TOWARD_ZERO);
    return d_cmp(r, x) == .EQUAL;
}
// IEEEFloat::makeNaN(SNaN = false, Neg): the default quiet NaN
d_qnan :: (neg: bool) -> u64 { return 0x7ff8_0000_0000_0000 | sgn_bit(neg); }

DD_LARGEST_HI :: 0x7fef_ffff_ffff_ffff;
DD_LARGEST_LO :: 0x7c8f_ffff_ffff_fffe;
dd_largest :: (neg: bool) -> [] u64 {
    if neg return dd_make(DD_LARGEST_HI | DD_SIGN, DD_LARGEST_LO | DD_SIGN);
    return dd_make(DD_LARGEST_HI, DD_LARGEST_LO);
}
dd_smallest :: (neg: bool) -> [] u64 { return dd_make(D_SMALLEST | sgn_bit(neg), 0); }
dd_smallest_normalized :: (neg: bool) -> [] u64 { return dd_make(0x0360_0000_0000_0000 | sgn_bit(neg), 0); }
dd_inf :: (neg: bool) -> [] u64 { return dd_make(0x7ff0_0000_0000_0000 | sgn_bit(neg), 0); }
dd_zero :: (neg: bool) -> [] u64 { return dd_make(sgn_bit(neg), 0); }
dd_chs :: (w: [] u64) -> [] u64 { return dd_make(w[0] ^ DD_SIGN, w[1] ^ DD_SIGN); }

// fastTwoSum: (Hi, Lo) with Hi = RTNE(X + Y), Hi + Lo = X + Y (requires log2(X) >= log2(Y))
dd_fast_two_sum :: (x: u64, y: u64) -> u64, u64 {
    if !d_is_finite(x) return x, 0;
    hi := d_add(x, y);
    delta := d_sub(hi, x);
    lo := d_sub(y, delta);
    return hi, lo;
}

// ---------------------------------------------------------------- semPPCDoubleDoubleLegacy conversions

// IEEEFloat::initFromPPCDoubleDoubleLegacyAPInt: the legacy IEEE value of a double-double
dd_to_legacy :: (w: [] u64) -> [] u64 {
    l, ex := fp_convert(.DOUBLE, .PPC_LEGACY, dd_w1(w[0]));
    if fp_decode(.PPC_LEGACY, l).cat != .NORMAL return l;
    v, ex2 := fp_convert(.DOUBLE, .PPC_LEGACY, dd_w1(w[1]));
    r, st := fp_add_sub(.PPC_LEGACY, l, v, false);
    return r;
}

// IEEEFloat::convertPPCDoubleDoubleLegacyAPFloatToAPInt: the double-double of a legacy IEEE value
dd_from_legacy :: (l: [] u64) -> [] u64 {
    // normalize against double's minExponent first (exact), then round to double
    ext, ex := fp_convert(.PPC_LEGACY, .PPC_LEGACY_EXT, l);
    u, exact := fp_convert(.PPC_LEGACY_EXT, .DOUBLE, ext);
    if fp_decode(.DOUBLE, u).cat == .NORMAL && !exact {
        u2, ex2 := fp_convert(.DOUBLE, .PPC_LEGACY_EXT, u);
        v, st := fp_add_sub(.PPC_LEGACY_EXT, ext, u2, true);
        vd, ex3 := fp_convert(.PPC_LEGACY_EXT, .DOUBLE, v);
        return dd_make(u[0], vd[0]);
    }
    return dd_make(u[0], 0);
}

// APFloat::convert from an IEEE format to ppc_fp128 (via semPPCDoubleDoubleLegacy); exact = !losesInfo
dd_convert_from_ieee :: (from: Type_Kind, w: [] u64) -> [] u64, bool {
    l, exact := fp_convert(from, .PPC_LEGACY, w);
    return dd_from_legacy(l), exact;
}
// APFloat::convert from ppc_fp128 to an IEEE format: converts the first double
dd_convert_to_ieee :: (to: Type_Kind, w: [] u64) -> [] u64, bool {
    if to == .DOUBLE return dd_w1(w[0]), true;
    r, exact := fp_convert(.DOUBLE, to, dd_w1(w[0]));
    return r, exact;
}

// DoubleAPFloat::convertFromString
dd_from_string :: (s: string) -> (w: [] u64, ok: bool, overflow: bool, zero: bool) {
    l, ok, of, zr := fp_from_string(.PPC_LEGACY, s);
    if !ok return dd_make(0, 0), false, false, false;
    return dd_from_legacy(l), ok, of, zr;
}
// rounding an exact value through semPPCDoubleDoubleLegacy (what every legacy-routed operation ends with)
dd_round_rm :: (neg: bool, num: Big, den: Big, e2: s64, rm: u8) -> (w: [] u64, st: Fp_Status, zero: bool) {
    l, st, zr := fp_round_rm(.PPC_LEGACY, neg, num, den, e2, rm);
    return dd_from_legacy(l), st, zr;
}
// DoubleAPFloat::toString (FormatPrecision 6)
dd_to_string_e6 :: (w: [] u64) -> string { return fp_to_string_e6(.PPC_LEGACY, dd_to_legacy(w)); }

// ---------------------------------------------------------------- arithmetic

// DoubleAPFloat::addImpl (Linnainmaa)
dd_add_impl :: (a: u64, aa: u64, c: u64, cc: u64, rm: u8) -> [] u64, Fp_Status {
    st: Fp_Status;
    s: Fp_Status;
    z: u64;
    z, s = d_add(a, c, rm); st |= s;
    if !d_is_finite(z) {
        if !d_is_inf(z) return dd_make(z, 0), st;
        st = 0;
        a_cmp_c := d_cmp_abs(a, c);
        z, s = d_add(cc, aa, rm); st |= s;
        if a_cmp_c == .GREATER {
            z, s = d_add(z, c, rm); st |= s;
            z, s = d_add(z, a, rm); st |= s;
        } else {
            z, s = d_add(z, a, rm); st |= s;
            z, s = d_add(z, c, rm); st |= s;
        }
        if !d_is_finite(z) return dd_make(z, 0), st;
        hi := z;
        zz: u64;
        zz, s = d_add(aa, cc, rm); st |= s;
        lo: u64;
        if a_cmp_c == .GREATER {
            lo, s = d_sub(a, z, rm); st |= s;
            lo, s = d_add(lo, c, rm); st |= s;
            lo, s = d_add(lo, zz, rm); st |= s;
        } else {
            lo, s = d_sub(c, z, rm); st |= s;
            lo, s = d_add(lo, a, rm); st |= s;
            lo, s = d_add(lo, zz, rm); st |= s;
        }
        return dd_make(hi, lo), st;
    }
    q: u64;
    q, s = d_sub(a, z, rm); st |= s;
    zz: u64;
    zz, s = d_add(q, c, rm); st |= s;
    q, s = d_add(q, z, rm); st |= s;
    q, s = d_sub(q, a, rm); st |= s;
    q ^= DD_SIGN;
    zz, s = d_add(zz, q, rm); st |= s;
    zz, s = d_add(zz, aa, rm); st |= s;
    zz, s = d_add(zz, cc, rm); st |= s;
    if zz == 0 return dd_make(z, 0), 0;   // +0
    hi: u64;
    hi, s = d_add(z, zz, rm); st |= s;
    if !d_is_finite(hi) return dd_make(hi, 0), st;
    lo: u64;
    lo, s = d_sub(z, hi, rm); st |= s;
    lo, s = d_add(lo, zz, rm); st |= s;
    return dd_make(hi, lo), st;
}

// DoubleAPFloat::addWithSpecial (Out is the left operand)
dd_add :: (l: [] u64, r: [] u64, rm: u8) -> [] u64, Fp_Status {
    lc := d_cat(l[0]); rc := d_cat(r[0]);
    if lc == .NAN return l, 0;
    if rc == .NAN return r, 0;
    if lc == .ZERO return r, 0;
    if rc == .ZERO return l, 0;
    if lc == .INF && rc == .INF && d_neg(l[0]) != d_neg(r[0]) return dd_make(d_qnan(d_neg(l[0])), 0), .INVALID;
    if lc == .INF return l, 0;
    if rc == .INF return r, 0;
    w, st := dd_add_impl(l[0], l[1], r[0], r[1], rm);
    return w, st;
}

dd_add_sub :: (a: [] u64, b: [] u64, subtract: bool, rm: u8) -> [] u64, Fp_Status {
    if !subtract { w, st := dd_add(a, b, rm); return w, st; }
    // subtract: changeSign(); add(RHS); changeSign()
    w, st := dd_add(dd_chs(a), b, rm);
    return dd_chs(w), st;
}

// DoubleAPFloat::multiply
dd_mul :: (l: [] u64, r: [] u64, rm: u8) -> [] u64, Fp_Status {
    lc := d_cat(l[0]); rc := d_cat(r[0]);
    if lc == .NAN return l, 0;
    if rc == .NAN return r, 0;
    if (lc == .ZERO && rc == .INF) || (lc == .INF && rc == .ZERO) return dd_make(d_qnan(false), 0), 0;
    if lc == .ZERO || lc == .INF return l, 0;
    if rc == .ZERO || rc == .INF return r, 0;
    st: Fp_Status;
    s: Fp_Status;
    a := l[0]; b := l[1]; c := r[0]; d := r[1];
    t: u64;
    t, s = d_mul(a, c, rm); st |= s;
    if !d_is_finite_nonzero(t) return dd_make(t, 0), st;
    // tau = fmsub(a, c, t) = -fmadd(-a, c, t)
    tau: u64;
    tau, s = d_fma(a, c, t ^ DD_SIGN, rm); st |= s;
    v, w: u64;
    v, s = d_mul(a, d, rm); st |= s;
    w, s = d_mul(b, c, rm); st |= s;
    v, s = d_add(v, w, rm); st |= s;
    tau, s = d_add(tau, v, rm); st |= s;
    u: u64;
    u, s = d_add(t, tau, rm); st |= s;
    if !d_is_finite(u) return dd_make(u, 0), st;
    t, s = d_sub(t, u, rm); st |= s;
    t, s = d_add(t, tau, rm); st |= s;
    return dd_make(u, t), st;
}

// DoubleAPFloat::divide / remainder / mod / fusedMultiplyAdd: through semPPCDoubleDoubleLegacy
dd_div :: (a: [] u64, b: [] u64, rm: u8) -> [] u64, Fp_Status {
    w, st := fp_div(.PPC_LEGACY, dd_to_legacy(a), dd_to_legacy(b), rm);
    return dd_from_legacy(w), st;
}
dd_remainder :: (a: [] u64, b: [] u64) -> [] u64, Fp_Status {
    w, st := fp_remainder(.PPC_LEGACY, dd_to_legacy(a), dd_to_legacy(b));
    return dd_from_legacy(w), st;
}
dd_mod :: (a: [] u64, b: [] u64) -> [] u64, Fp_Status {
    w, st := fp_mod(.PPC_LEGACY, dd_to_legacy(a), dd_to_legacy(b));
    return dd_from_legacy(w), st;
}
dd_fma :: (a: [] u64, b: [] u64, c: [] u64, rm: u8) -> [] u64, Fp_Status {
    w, st := fp_fma(.PPC_LEGACY, dd_to_legacy(a), dd_to_legacy(b), dd_to_legacy(c), rm);
    return dd_from_legacy(w), st;
}

// DoubleAPFloat::compare
dd_compare :: (a: [] u64, b: [] u64) -> Fp_Cmp {
    r := d_cmp(a[0], b[0]);
    if r == .EQUAL return d_cmp(a[1], b[1]);
    return r;
}

// DoubleAPFloat::compareAbsoluteValue
dd_compare_abs :: (a: [] u64, b: [] u64) -> Fp_Cmp {
    hi := d_cmp_abs(a[0], b[0]);
    if hi != .EQUAL return hi;
    if d_is_zero(a[1]) && d_is_zero(b[1]) return .EQUAL;
    this_sub := d_neg(a[0]) != d_neg(a[1]);
    rhs_sub := d_neg(b[0]) != d_neg(b[1]);
    if d_is_zero(a[1]) return ifx rhs_sub then Fp_Cmp.GREATER else .LESS;
    if d_is_zero(b[1]) return ifx this_sub then Fp_Cmp.LESS else .GREATER;
    if this_sub != rhs_sub return ifx this_sub then Fp_Cmp.LESS else .GREATER;
    lo := d_cmp_abs(a[1], b[1]);
    if this_sub {
        if lo == .LESS return .GREATER;
        if lo == .GREATER return .LESS;
    }
    return lo;
}

// DoubleAPFloat::roundToIntegral
dd_round_to_integral :: (w: [] u64, rm: u8) -> [] u64, Fp_Status {
    hi := w[0]; lo := w[1];
    rhi, hst := d_round_to_integral(hi, rm);
    if !d_is_finite_nonzero(hi) || d_is_zero(lo) return dd_make(rhi, 0), hst;
    // RoundToNearestHelper: adjust Rounded toward TieBreaker if ToRound was at a halfway point
    nearest_helper :: (to_round: u64, rounded: u64, tie: u64) -> u64 {
        err := d_sub(rounded, to_round);
        if !d_is_zero(tie) && d_neg(tie) != d_neg(err) && (err & ~DD_SIGN) == 0x3fe0_0000_0000_0000 {
            r := d_add(rounded, D_ONE | sgn_bit(d_neg(tie)));
            return r;
        }
        return rounded;
    }
    if d_cmp(rhi, hi) != .EQUAL {
        if rm == RM_NEAREST_TIES_TO_AWAY || rm == RM_NEAREST_TIES_TO_EVEN rhi = nearest_helper(hi, rhi, lo);
        return dd_make(rhi, 0), hst;
    }
    lo_rm := rm;
    if rm == RM_TOWARD_ZERO lo_rm = ifx d_neg(hi) then cast(u8) RM_TOWARD_POSITIVE else RM_TOWARD_NEGATIVE;
    rlo, lst := d_round_to_integral(lo, lo_rm);
    if lo_rm == RM_NEAREST_TIES_TO_AWAY rlo = nearest_helper(lo, rlo, hi);
    h2, l2 := dd_fast_two_sum(rhi, rlo);
    return dd_make(h2, l2), lst;
}

// harrisonUlp (on a double)
d_harrison_ulp :: (x: u64) -> u64 {
    c := d_cat(x);
    if c == .NAN return d_qnan(false);
    if c == .INF return 0x7ff0_0000_0000_0000;
    if c == .ZERO return D_SMALLEST;
    if d_is_denormal(x) || d_is_smallest_normalized(x) return D_SMALLEST;
    e := d_ilogb(x);
    if !d_neg(x) && d_exact_log2_abs(x) != INT_MIN32 e -= 1;   // getExactLog2
    return d_scalbn(D_ONE, e - 52, RM_NEAREST_TIES_TO_EVEN);
}

// DoubleAPFloat::next
dd_next :: (w: [] u64, down: bool) -> [] u64, Fp_Status {
    if down {
        r, st := dd_next(dd_chs(w), false);
        return dd_chs(r), st;
    }
    c := d_cat(w[0]);
    if c == .INF {
        if d_neg(w[0]) return dd_largest(true), 0;
        return w, 0;
    }
    if c == .NAN {
        if d_is_signaling(w[0]) return dd_make(d_qnan(d_neg(w[0])), 0), .INVALID;
        return w, 0;
    }
    if c == .ZERO return dd_smallest(false), 0;
    hi_old := w[0]; lo_old := w[1];
    next_lo := d_next(lo_old, false);
    in_lattice :: (hi: u64, lo: u64) -> bool { s := d_add(hi, lo); return d_cmp(s, hi) == .EQUAL; }
    if in_lattice(hi_old, next_lo) {
        r := dd_make(hi_old, next_lo);
        if dd_compare(r, dd_largest(false)) == .GREATER return dd_inf(false), 0;
        return r, 0;
    }
    next_hi := d_next(hi_old, false);
    if d_is_inf(next_hi) return dd_inf(false), 0;
    if d_is_zero(next_hi) return dd_zero(true), 0;
    next_lo = d_scalbn(d_harrison_ulp(next_hi), -1, RM_TOWARD_ZERO) ^ DD_SIGN;
    if !in_lattice(next_hi, next_lo) next_lo = d_next(next_lo, false);
    return dd_make(next_hi, next_lo), 0;
}

// IEEEFloat::convertToInteger of one double into `width` bits (words, status, isExact)
d_to_int :: (x: u64, width: u32, is_signed: bool, rm: u8) -> [] u64, Fp_Status, bool {
    r, st, ex := fp_to_integer_rm(.DOUBLE, dd_w1(x), width, is_signed, rm);
    return r, st, ex;
}

// DoubleAPFloat::convertToSignExtendedInteger
dd_to_sext_integer :: (w: [] u64, width: u32, is_signed: bool, rm: u8) -> [] u64, Fp_Status, bool {
    hi := w[0]; lo := w[1];
    if !d_is_finite_nonzero(hi) || d_is_zero(lo) {
        r, st, ex := d_to_int(hi, width, is_signed, rm);
        return r, st, ex;
    }
    nw := words_for_bits(width);
    integral, round_st := dd_round_to_integral(w, rm);
    if round_st & .INVALID { r := NewArray(nw, u64,, allocator = temp); return r, .INVALID, false; }
    ihi := integral[0]; ilo := integral[1];
    if d_is_zero(ihi) || d_is_zero(ilo) {
        r, hst, hex := d_to_int(ihi, width, is_signed, rm);
        return r, ifx hst == 0 then Fp_Status.INEXACT else hst, false;
    }
    if !is_signed && d_neg(ihi) { r := NewArray(nw, u64,, allocator = temp); return r, .INVALID, false; }
    hi_log2 := d_exact_log2_abs(ihi);
    pow_width := ifx is_signed then width - 1 else width;
    if hi_log2 >= 0 && cast(u32) hi_log2 == pow_width {
        if d_neg(ihi) == d_neg(ilo) { r := NewArray(nw, u64,, allocator = temp); return r, .INVALID, false; }
        r, lst, lex := d_to_int(ilo, width, true, rm);
        if lst & .INVALID return r, .INVALID, false;
        if is_signed && !d_neg(ihi) r[pow_width / 64] &= ~((cast(u64) 1) << cast(u64)(pow_width % 64));
        return r, round_st, round_st == 0;
    }
    r, hst, hex := d_to_int(ihi, width, is_signed, RM_TOWARD_ZERO);
    if hst & .INVALID return r, hst, false;
    lr, lst, lex := d_to_int(ilo, width, is_signed, RM_TOWARD_ZERO);
    if lst & .INVALID return r, lst, false;
    // APInt::tcAdd over the parts
    carry: u64 = 0;
    for i: 0..nw-1 {
        x := r[i] + lr[i];
        c1 := ifx x < r[i] then cast(u64) 1 else 0;
        y := x + carry;
        c2 := ifx y < x then cast(u64) 1 else 0;
        r[i] = y; carry = c1 | c2;
    }
    mask_words(r, width);
    return r, round_st, round_st == 0;
}

// DoubleAPFloat::convertToInteger: saturated bits on invalid
dd_to_integer_rm :: (w: [] u64, width: u32, is_signed: bool, rm: u8) -> (words: [] u64, st: Fp_Status, is_exact: bool) {
    r, st, ex := dd_to_sext_integer(w, width, is_signed, rm);
    if st & .INVALID {
        for * r it.* = 0;
        nbits: u32;
        if d_cat(w[0]) == .NAN nbits = 0;
        else if d_neg(w[0]) nbits = ifx is_signed then cast(u32) 1 else 0;
        else nbits = width - (ifx is_signed then cast(u32) 1 else 0);
        for i: 0..cast(s64) nbits - 1 r[i / 64] |= (cast(u64) 1) << cast(u64)(i % 64);
        if d_neg(w[0]) && is_signed && d_cat(w[0]) != .NAN { for * r it.* = 0; r[(width - 1) / 64] |= (cast(u64) 1) << cast(u64)((width - 1) % 64); }
    }
    return r, st, ex;
}

// DoubleAPFloat::handleOverflow (of a non-negative value: the callers only convert magnitudes)
dd_handle_overflow :: (neg: bool, rm: u8) -> [] u64, Fp_Status {
    r: [] u64;
    if rm == {
        case RM_TOWARD_ZERO; r = dd_largest(neg);
        case RM_TOWARD_NEGATIVE; r = ifx neg then dd_inf(true) else dd_largest(false);
        case RM_TOWARD_POSITIVE; r = ifx neg then dd_largest(true) else dd_inf(false);
        case; r = dd_inf(neg);
    }
    st := Fp_Status.INEXACT;
    if !d_is_finite(r[0]) st |= .OVERFLOW;
    return r, st;
}

// IEEEFloat::convertFromAPInt for a double with a rounding mode
d_from_int_rm :: (words: [] u64, bits: u32, is_signed: bool, rm: u8) -> u64, Fp_Status {
    w := NewArray(words.count, u64,, allocator = temp);
    for words w[it_index] = it;
    mask_words(w, bits);
    neg := is_signed && bits > 0 && ((w[(bits - 1) / 64] >> cast(u64)((bits - 1) % 64)) & 1) != 0;
    if neg {
        carry: u64 = 1;
        for i: 0..w.count-1 { x := ~w[i]; s := x + carry; carry = ifx s < x then cast(u64) 1 else 0; w[i] = s; }
        mask_words(w, bits);
    }
    mag := big_from_words(w);
    if big_is_zero(mag) return 0, 0;
    r, st, z := fp_round_rm(.DOUBLE, neg, mag, big_from_u64(1), 0, rm);
    return r[0], st;
}

// DoubleAPFloat::convertFromAPInt (convertFromUnsignedParts of the magnitude)
dd_from_integer_rm :: (words: [] u64, bits: u32, is_signed: bool, rm: u8) -> [] u64, Fp_Status {
    api := NewArray(words_for_bits(bits), u64,, allocator = temp);
    for words if it_index < api.count api[it_index] = it;
    mask_words(api, bits);
    negate := is_signed && bits > 0 && ((api[(bits - 1) / 64] >> cast(u64)((bits - 1) % 64)) & 1) != 0;
    if negate {
        carry: u64 = 1;
        for i: 0..api.count-1 { x := ~api[i]; s := x + carry; carry = ifx s < x then cast(u64) 1 else 0; api[i] = s; }
        mask_words(api, bits);
    }
    r, st := dd_from_unsigned_parts(api, rm);
    if negate r = dd_chs(r);
    return r, st;
}

dd_from_unsigned_parts :: (src: [] u64, rm: u8) -> [] u64, Fp_Status {
    msb: s64 = -1;
    for i: 0..src.count * 64 - 1 if (src[i / 64] >> cast(u64)(i % 64)) & 1 msb = i;
    if msb < 0 return dd_zero(false), 0;
    src_bits := cast(u32)(msb + 1);
    hi, hst := d_from_int_rm(src, src_bits, false, RM_NEAREST_TIES_TO_EVEN);
    if !d_is_finite(hi) { r, s := dd_handle_overflow(false, rm); return r, s; }
    hi_bits := cast(u32)(d_ilogb(hi) + 1);
    hi_int, his, hex := d_to_int(hi, hi_bits, false, RM_NEAREST_TIES_TO_EVEN);
    // Error = SrcInt.zext(hi_bits) - HiAsInt (hi_bits-wide two's complement)
    nw := words_for_bits(hi_bits);
    err := NewArray(nw, u64,, allocator = temp);
    borrow: u64 = 0;
    for i: 0..nw-1 {
        a := ifx i < src.count then src[i] else 0;
        b := hi_int[i];
        d := a - b;
        b1 := ifx a < b then cast(u64) 1 else 0;
        d2 := d - borrow;
        b2 := ifx d < borrow then cast(u64) 1 else 0;
        err[i] = d2; borrow = b1 | b2;
    }
    mask_words(err, hi_bits);
    err_neg := ((err[(hi_bits - 1) / 64] >> cast(u64)((hi_bits - 1) % 64)) & 1) != 0;
    lo_rm := rm;
    if err_neg {
        if rm == RM_NEAREST_TIES_TO_AWAY {
            // getSignificantBits - 1 of the negative error = active bits of ~err
            sig_bits: s64 = 1;
            for i: 0..cast(s64) hi_bits - 1 {
                if ((~err[i / 64] >> cast(u64)(i % 64)) & 1) sig_bits = i + 2;
            }
            active := sig_bits - 1;
            LO_PRECISION :: 53;
            if active > LO_PRECISION {
                boundary := active - LO_PRECISION;
                tz: s64 = 0;
                while tz < hi_bits && ((err[tz / 64] >> cast(u64)(tz % 64)) & 1) == 0 tz += 1;
                if tz == boundary - 1 lo_rm = RM_TOWARD_POSITIVE;
            }
        } else if rm == RM_TOWARD_ZERO lo_rm = RM_TOWARD_NEGATIVE;
    }
    lo, st := d_from_int_rm(err, hi_bits, true, lo_rm);
    h2, l2 := dd_fast_two_sum(hi, lo);
    if !d_is_finite(h2) { r, s := dd_handle_overflow(false, rm); return r, s; }
    r := dd_make(h2, l2);
    if d_is_finite_nonzero(h2) && d_is_largest(h2) && dd_compare(r, dd_largest(false)) == .GREATER {
        o, s := dd_handle_overflow(false, rm);
        return o, s;
    }
    return r, st;
}

// ---------------------------------------------------------------- classification

dd_is_denormal :: (w: [] u64) -> bool {
    if d_cat(w[0]) != .NORMAL return false;
    if d_is_denormal(w[0]) || d_is_denormal(w[1]) return true;
    s := d_add(w[0], w[1]);
    return d_cmp(w[0], s) != .EQUAL;
}
dd_is_smallest :: (w: [] u64) -> bool { return d_cat(w[0]) == .NORMAL && dd_compare(dd_smallest(d_neg(w[0])), w) == .EQUAL; }
dd_is_smallest_normalized :: (w: [] u64) -> bool { return d_cat(w[0]) == .NORMAL && dd_compare(dd_smallest_normalized(d_neg(w[0])), w) == .EQUAL; }
dd_is_largest :: (w: [] u64) -> bool { return d_cat(w[0]) == .NORMAL && dd_compare(dd_largest(d_neg(w[0])), w) == .EQUAL; }
dd_is_integer :: (w: [] u64) -> bool { return d_is_integer(w[0]) && d_is_integer(w[1]); }
dd_exact_log2_abs :: (w: [] u64) -> s64 {
    if !d_is_zero(w[1]) return INT_MIN32;
    return d_exact_log2_abs(w[0]);
}

// ilogb(DoubleAPFloat)
dd_ilogb :: (w: [] u64) -> s64 {
    hi := w[0]; lo := w[1];
    r := d_ilogb(hi);
    if d_cat(hi) != .NORMAL return r;
    if d_is_zero(lo) || d_neg(hi) == d_neg(lo) return r;
    if d_exact_log2_abs(hi) == INT_MIN32 return r;
    return r - 1;
}

// frexp(DoubleAPFloat)
dd_frexp :: (w: [] u64, rm: u8) -> [] u64, s64 {
    e := dd_ilogb(w);
    if e == IEK_NAN return dd_make(fp_quiet(.DOUBLE, dd_w1(w[0]))[0], w[1]), e;
    if e == IEK_INF return w, e;
    if e == IEK_ZERO return w, 0;
    hi := w[0]; lo := w[1];
    e += 1;
    signs_disagree := d_neg(hi) != d_neg(lo);
    second := lo;
    if d_cat(hi) == .NORMAL && d_is_finite_nonzero(lo) {
        lo_rm: u8;
        if rm == RM_TOWARD_ZERO lo_rm = ifx d_neg(hi) then cast(u8) RM_TOWARD_POSITIVE else RM_TOWARD_NEGATIVE;
        else if rm == RM_NEAREST_TIES_TO_AWAY && signs_disagree && e > 0 lo_rm = RM_NEAREST_TIES_TO_EVEN;
        else lo_rm = rm;
        second = d_scalbn(lo, -e, lo_rm);
        if rm == RM_NEAREST_TIES_TO_AWAY && lo_rm == RM_NEAREST_TIES_TO_EVEN {
            recomposed := d_scalbn(second, e, RM_NEAREST_TIES_TO_EVEN);
            if d_cmp(recomposed, lo) != .EQUAL {
                err := d_sub(recomposed, lo);
                ulp := d_harrison_ulp(second);
                scaled_ulp := d_scalbn(ulp, e - 1, RM_NEAREST_TIES_TO_EVEN);
                is_mid := d_cmp(err & ~DD_SIGN, scaled_ulp) == .EQUAL;
                rounded_away := d_neg(second) == d_neg(err);
                if is_mid && rounded_away second = d_next(second, !d_neg(second));
            }
        }
        if d_is_zero(second) && signs_disagree && d_exact_log2_abs(hi) != INT_MIN32 e += 1;
    }
    first := d_scalbn(hi, -e, rm);
    return dd_make(first, second), e;
}
