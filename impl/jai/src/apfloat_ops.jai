// APFloat operations needed by constant folding of calls (ConstantFolding.cpp): rounding-mode aware
// fused multiply-add, roundToIntegral, next, remainder, scalbn/ilogb/frexp, convertToInteger with a rounding mode,
// minnum/maxnum/minimum/maximum/minimumnum/maximumnum and conversions to/from host doubles.
// Ported from llvm/lib/Support/APFloat.cpp (IEEEFloat::fusedMultiplyAdd, roundToIntegral, next, remainder,
// convertToSignExtendedInteger/convertToInteger, scalbn, ilogb, frexp) and llvm/include/llvm/ADT/APFloat.h
// (minnum & co). Every operation is computed on the exact value and rounded once (fp_round_rm), which is what
// APFloat's lost-fraction bookkeeping amounts to.

// exact value of a finite nonzero decoded float: sig * 2^e2
fp_exact :: (k: Type_Kind, d: Fp_Decoded) -> (sig: Big, e2: s64) {
    p, mx, mn, b := fp_semantics(k);
    return d.sig, d.exp - (p - 1);
}

// IEEEFloat::fusedMultiplyAdd: a * b + c, rounded once
fp_fma :: (k: Type_Kind, a: [] u64, b: [] u64, c: [] u64, rm: u8 = RM_NEAREST_TIES_TO_EVEN) -> [] u64, Fp_Status {
    fp_check_kind(k);
    da := fp_decode(k, a); db := fp_decode(k, b); dc := fp_decode(k, c);
    pneg := da.neg != db.neg;
    if da.cat == .NORMAL && db.cat == .NORMAL && (dc.cat == .NORMAL || dc.cat == .ZERO) {
        sa, ea := fp_exact(k, da); sb, eb := fp_exact(k, db);
        prod := big_mul(sa, sb); pe := ea + eb;
        if dc.cat == .ZERO {
            w, st := fp_round_status(k, pneg, prod, big_from_u64(1), pe, rm);
            return w, st;
        }
        sc, ec := fp_exact(k, dc);
        e := min(pe, ec);
        x := big_shl(prod, pe - e); y := big_shl(sc, ec - e);
        if pneg == dc.neg { w, st := fp_round_status(k, pneg, big_add(x, y), big_from_u64(1), e, rm); return w, st; }
        cmp := big_cmp(x, y);
        if cmp == 0 return fp_zero(k, rm == RM_TOWARD_NEGATIVE), 0;
        if cmp > 0 { r := big_copy(x); big_sub(*r, y); w, st := fp_round_status(k, pneg, r, big_from_u64(1), e, rm); return w, st; }
        r := big_copy(y); big_sub(*r, x);
        w, st := fp_round_status(k, dc.neg, r, big_from_u64(1), e, rm);
        return w, st;
    }
    // multiplySpecials then addOrSubtract. When both factors are finite and nonzero (so the addend is inf/NaN)
    // multiplySpecials leaves the factor unchanged: stand in any finite value with the product's sign.
    if da.cat == .NORMAL && db.cat == .NORMAL {
        w, st := fp_add_sub(k, fp_with_sign(k, a, pneg), c, false, rm);
        return w, st;
    }
    pw, pst := fp_mul(k, a, b, rm);
    if pst & .INVALID return pw, pst;
    w, st := fp_add_sub(k, pw, c, false, rm);
    return w, st | pst;
}

// IEEEFloat::roundToIntegral
fp_round_to_integral :: (k: Type_Kind, w: [] u64, rm: u8) -> [] u64, Fp_Status {
    fp_check_kind(k);
    d := fp_decode(k, w);
    if d.cat == .INF || d.cat == .ZERO return w, 0;
    if d.cat == .NAN {
        if fp_is_signaling(k, d) return fp_quiet(k, w), .INVALID;
        return w, 0;
    }
    p, mx, mn, b := fp_semantics(k);
    if d.exp + 1 >= p return w, 0;
    sig, e2 := fp_exact(k, d);   // e2 < 0
    sh := -e2;
    n := big_shr(sig, sh);
    roundbit := big_bit(sig, sh - 1);
    sticky := big_any_below(sig, sh - 1);
    if !roundbit && !sticky return w, 0;
    up := false;
    if rm == {
        case RM_NEAREST_TIES_TO_AWAY; up = roundbit;
        case RM_NEAREST_TIES_TO_EVEN; up = roundbit && (sticky || big_bit(n, 0));
        case RM_TOWARD_ZERO; up = false;
        case RM_TOWARD_POSITIVE; up = !d.neg;
        case RM_TOWARD_NEGATIVE; up = d.neg;
        case; fatal("internal: invalid rounding mode %", rm);
    }
    if up big_add_small(*n, 1);
    if big_is_zero(n) return fp_zero(k, d.neg), .INEXACT;
    r, st, z := fp_round_rm(k, d.neg, n, big_from_u64(1), 0, RM_NEAREST_TIES_TO_EVEN);
    return r, .INEXACT;
}

// IEEEFloat::next
fp_next :: (k: Type_Kind, w: [] u64, down: bool) -> [] u64, Fp_Status {
    fp_check_kind(k);
    if down {
        // nextDown(x) = -nextUp(-x)
        r, st := fp_next(k, fp_neg(k, w), false);
        return fp_neg(k, r), st;
    }
    d := fp_decode(k, w);
    p, emax, emin, b := fp_semantics(k);
    if d.cat == .INF {
        if !d.neg return w, 0;
        return fp_largest(k, true), 0;
    }
    if d.cat == .NAN {
        if fp_is_signaling(k, d) { r := fp_default_nan(k); return fp_with_sign(k, r, d.neg), .INVALID; }
        return w, 0;
    }
    one := big_from_u64(1);
    if d.cat == .ZERO {
        r, st, z := fp_round_rm(k, false, one, one, emin - (p - 1), RM_NEAREST_TIES_TO_EVEN);
        return r, 0;
    }
    sig, e2 := fp_exact(k, d);
    if !d.neg {
        r, st, z := fp_round_rm(k, false, big_add(sig, one), one, e2, RM_NEAREST_TIES_TO_EVEN);
        if st & .OVERFLOW return fp_inf(k, false), 0;
        if fp_decode(k, r).cat == .INF return r, 0;
        return r, 0;
    }
    // negative: move toward zero by one ulp (the ulp below a power of two is half as large, unless denormal)
    pow2 := big_bitlen(sig) == p && !big_any_below(sig, p - 1);
    s := big_shl(sig, 1); e := e2 - 1;
    if pow2 && d.exp > emin big_sub(*s, one); else big_sub(*s, big_from_u64(2));
    if big_is_zero(s) return fp_zero(k, true), 0;
    r, st, z := fp_round_rm(k, true, s, one, e, RM_NEAREST_TIES_TO_EVEN);
    return r, 0;
}

// IEEEFloat::remainder (IEEE 754 remainder: x - n*y with n = x/y rounded to nearest even)
fp_remainder :: (k: Type_Kind, a: [] u64, b: [] u64) -> [] u64, Fp_Status {
    fp_check_kind(k);
    da := fp_decode(k, a); db := fp_decode(k, b);
    if da.cat == .NAN || db.cat == .NAN { r, s := fp_nan_result(k, a, da, b, db); return r, s; }
    if db.cat == .ZERO || da.cat == .INF return fp_default_nan(k), .INVALID;
    if da.cat == .ZERO || db.cat == .INF return a, 0;
    sa, ea := fp_exact(k, da); sb, eb := fp_exact(k, db);
    e := min(ea, eb);
    x := big_shl(sa, ea - e); y := big_shl(sb, eb - e);
    q, r := big_divmod(x, y);
    // round the quotient to nearest even: compare 2r with y
    r2 := big_shl(r, 1);
    c := big_cmp(r2, y);
    neg := da.neg;
    res: Big;
    if c > 0 || (c == 0 && big_bit(q, 0)) {
        // |x| - (q+1)|y| = r - y < 0: result magnitude y - r, sign flipped
        res = big_copy(y); big_sub(*res, r); neg = !neg;
    } else res = r;
    if big_is_zero(res) return fp_zero(k, da.neg), 0;
    w, st := fp_round_status(k, neg, res, big_from_u64(1), e);
    return w, st;
}

IEK_NAN :: -2147483648;
IEK_ZERO :: -2147483647;
IEK_INF :: 2147483647;

// ilogb(IEEEFloat)
fp_ilogb :: (k: Type_Kind, w: [] u64) -> s64 {
    d := fp_decode(k, w);
    if d.cat == .NAN return IEK_NAN;
    if d.cat == .ZERO return IEK_ZERO;
    if d.cat == .INF return IEK_INF;
    p, mx, mn, b := fp_semantics(k);
    sig, e2 := fp_exact(k, d);
    return big_bitlen(sig) - 1 + e2;
}

// scalbn(IEEEFloat, int, roundingMode)
fp_scalbn :: (k: Type_Kind, w: [] u64, exp: s64, rm: u8) -> [] u64 {
    d := fp_decode(k, w);
    if d.cat == .NAN return fp_quiet(k, w);
    if d.cat != .NORMAL return w;
    p, emax, emin, b := fp_semantics(k);
    max_inc := cast(s64) emax - (cast(s64) emin - (p - 1)) + 1;
    e := clamp(exp, -max_inc - 1, max_inc);
    sig, e2 := fp_exact(k, d);
    r, st, z := fp_round_rm(k, d.neg, sig, big_from_u64(1), e2 + e, rm);
    return r;
}

// frexp(IEEEFloat, int&, roundingMode)
fp_frexp :: (k: Type_Kind, w: [] u64, rm: u8) -> ([] u64, s64) {
    e := fp_ilogb(k, w);
    if e == IEK_NAN return fp_quiet(k, w), e;
    if e == IEK_INF return w, e;
    e = ifx e == IEK_ZERO then 0 else e + 1;
    return fp_scalbn(k, w, -e, rm), e;
}

// IEEEFloat::convertToInteger: words (deterministic saturated values on invalid), status, isExact
fp_to_integer_rm :: (k: Type_Kind, w: [] u64, width: u32, is_signed: bool, rm: u8) -> (words: [] u64, st: Fp_Status, is_exact: bool) {
    fp_check_kind(k);
    d := fp_decode(k, w);
    nw := words_for_bits(width);
    res := NewArray(nw, u64,, allocator = temp);
    invalid :: (res: [] u64, d: Fp_Decoded, width: u32, is_signed: bool) -> [] u64 {
        for * res it.* = 0;
        if d.cat == .NAN return res;
        nbits: u32;
        if d.neg nbits = ifx is_signed then cast(u32) 1 else 0;
        else nbits = width - (ifx is_signed then cast(u32) 1 else 0);
        for i: 0..cast(s64) nbits - 1 res[i / 64] |= (cast(u64) 1) << cast(u64)(i % 64);
        if d.neg && is_signed { for * res it.* = 0; res[(width - 1) / 64] |= (cast(u64) 1) << cast(u64)((width - 1) % 64); }
        return res;
    }
    if d.cat == .INF || d.cat == .NAN return invalid(res, d, width, is_signed), .INVALID, false;
    if d.cat == .ZERO return res, 0, !d.neg;
    sig, e2 := fp_exact(k, d);
    mag: Big;
    inexact := false;
    if e2 >= 0 mag = big_shl(sig, e2);
    else {
        sh := -e2;
        mag = big_shr(sig, sh);
        roundbit := big_bit(sig, sh - 1);
        sticky := big_any_below(sig, sh - 1);
        inexact = roundbit || sticky;
        if inexact {
            up := false;
            if rm == {
                case RM_NEAREST_TIES_TO_AWAY; up = roundbit;
                case RM_NEAREST_TIES_TO_EVEN; up = roundbit && (sticky || big_bit(mag, 0));
                case RM_TOWARD_ZERO; up = false;
                case RM_TOWARD_POSITIVE; up = !d.neg;
                case RM_TOWARD_NEGATIVE; up = d.neg;
            }
            if up big_add_small(*mag, 1);
        }
    }
    omsb := big_bitlen(mag);
    if d.neg {
        if !is_signed {
            if omsb != 0 return invalid(res, d, width, is_signed), .INVALID, false;
        } else {
            if omsb > width return invalid(res, d, width, is_signed), .INVALID, false;
            if omsb == width && big_any_below(mag, width - 1) return invalid(res, d, width, is_signed), .INVALID, false;
        }
    } else {
        if omsb >= cast(s64) width + (ifx is_signed then 0 else 1) return invalid(res, d, width, is_signed), .INVALID, false;
    }
    mw := big_to_words(mag, cast(u32) nw);
    for mw res[it_index] = it;
    if d.neg {
        carry: u64 = 1;
        for i: 0..res.count-1 { x := ~res[i]; s := x + carry; carry = ifx s < x then cast(u64) 1 else 0; res[i] = s; }
        mask_words(res, width);
    }
    if !inexact return res, 0, true;
    return res, .INEXACT, false;
}

// APFloat::convertToDouble (after converting to double, nearest-even) and APFloat(double)
fp_to_f64 :: (k: Type_Kind, w: [] u64) -> float64 {
    dw := w;
    if k != .DOUBLE { cw, ex := fp_convert(k, .DOUBLE, w); dw = cw; }
    bits := dw[0];
    return (cast(*float64) *bits).*;
}
fp_from_f64 :: (k: Type_Kind, x: float64) -> [] u64 {
    v := x;
    dw := NewArray(1, u64,, allocator = temp);
    dw[0] = (cast(*u64) *v).*;
    if k == .DOUBLE return dw;
    r, ex := fp_convert(.DOUBLE, k, dw);
    return r;
}

// ---------------------------------------------------------------- APFloat.h min/max (on APFloat values)

apf_make_quiet :: (f: APFloat) -> APFloat { g := f; return apf_from_words(g.k, fp_quiet(g.k, apf_words(*g))); }
apf_lt :: (a: APFloat, b: APFloat) -> bool { return apf_compare(a, b) == .LESS; }
apf_minnum :: (a: APFloat, b: APFloat) -> APFloat {
    if apf_is_signaling(a) return apf_make_quiet(a);
    if apf_is_signaling(b) return apf_make_quiet(b);
    if apf_is_nan(a) return b;
    if apf_is_nan(b) return a;
    if apf_is_zero(a) && apf_is_zero(b) && apf_is_negative(a) != apf_is_negative(b) return ifx apf_is_negative(a) then a else b;
    return ifx apf_lt(b, a) then b else a;
}
apf_maxnum :: (a: APFloat, b: APFloat) -> APFloat {
    if apf_is_signaling(a) return apf_make_quiet(a);
    if apf_is_signaling(b) return apf_make_quiet(b);
    if apf_is_nan(a) return b;
    if apf_is_nan(b) return a;
    if apf_is_zero(a) && apf_is_zero(b) && apf_is_negative(a) != apf_is_negative(b) return ifx apf_is_negative(a) then b else a;
    return ifx apf_lt(a, b) then b else a;
}
apf_minimum :: (a: APFloat, b: APFloat) -> APFloat {
    if apf_is_nan(a) return apf_make_quiet(a);
    if apf_is_nan(b) return apf_make_quiet(b);
    if apf_is_zero(a) && apf_is_zero(b) && apf_is_negative(a) != apf_is_negative(b) return ifx apf_is_negative(a) then a else b;
    return ifx apf_lt(b, a) then b else a;
}
apf_maximum :: (a: APFloat, b: APFloat) -> APFloat {
    if apf_is_nan(a) return apf_make_quiet(a);
    if apf_is_nan(b) return apf_make_quiet(b);
    if apf_is_zero(a) && apf_is_zero(b) && apf_is_negative(a) != apf_is_negative(b) return ifx apf_is_negative(a) then b else a;
    return ifx apf_lt(a, b) then b else a;
}
apf_minimumnum :: (a: APFloat, b: APFloat) -> APFloat {
    if apf_is_nan(a) return ifx apf_is_nan(b) then apf_make_quiet(b) else b;
    if apf_is_nan(b) return a;
    if apf_is_zero(a) && apf_is_zero(b) && apf_is_negative(a) != apf_is_negative(b) return ifx apf_is_negative(a) then a else b;
    return ifx apf_lt(b, a) then b else a;
}
apf_maximumnum :: (a: APFloat, b: APFloat) -> APFloat {
    if apf_is_nan(a) return ifx apf_is_nan(b) then apf_make_quiet(b) else b;
    if apf_is_nan(b) return a;
    if apf_is_zero(a) && apf_is_zero(b) && apf_is_negative(a) != apf_is_negative(b) return ifx apf_is_negative(a) then b else a;
    return ifx apf_lt(a, b) then b else a;
}
