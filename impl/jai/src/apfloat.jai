// Arbitrary-precision helpers for APInt/APFloat behaviour the parser and printer need.
// Ported from llvm/lib/Support/APFloat.cpp (IEEEFloat::toString / toStringImpl / AdjustToPrecision,
// convertFromString semantics: round to nearest, ties to even) and llvm/lib/Support/APInt.cpp (toString).
// Big numbers are little-endian arrays of u32 limbs in temporary storage.

Big :: [..] u32;

big_from_u64 :: (x: u64) -> Big {
    b: Big; b.allocator = temp;
    while x != 0 { array_add(*b, cast,trunc(u32) x); x >>= 32; }
    return b;
}
big_from_words :: (w: [] u64) -> Big {
    b: Big; b.allocator = temp;
    for w { array_add(*b, cast,trunc(u32) it); array_add(*b, cast,trunc(u32)(it >> 32)); }
    big_trim(*b);
    return b;
}
big_to_words :: (b: Big, nwords: u32) -> [] u64 {
    r := NewArray(nwords, u64,, allocator = temp);
    for i: 0..b.count-1 {
        wi := i / 2;
        if wi >= nwords break;
        if i % 2 == 0 r[wi] |= cast(u64) b[i]; else r[wi] |= (cast(u64) b[i]) << 32;
    }
    return r;
}
big_copy :: (a: Big) -> Big {
    b: Big; b.allocator = temp;
    array_reserve(*b, a.count);
    for a array_add(*b, it);
    return b;
}
big_trim :: (b: *Big) { while b.count > 0 && b.*[b.count - 1] == 0 b.count -= 1; }
big_is_zero :: (b: Big) -> bool { return b.count == 0; }

big_mul_small :: (b: *Big, m: u32) {
    carry: u64 = 0;
    for i: 0..b.count-1 {
        t := (cast(u64) b.*[i]) * m + carry;
        b.*[i] = cast,trunc(u32) t;
        carry = t >> 32;
    }
    if carry array_add(b, cast,trunc(u32) carry);
}
big_add_small :: (b: *Big, a: u32) {
    carry: u64 = a;
    i := 0;
    while carry != 0 {
        if i == b.count { array_add(b, 0); }
        t := cast(u64) b.*[i] + carry;
        b.*[i] = cast,trunc(u32) t;
        carry = t >> 32;
        i += 1;
    }
}
// returns remainder
big_divmod_small :: (b: *Big, d: u32) -> u32 {
    rem: u64 = 0;
    i := b.count - 1;
    while i >= 0 {
        t := (rem << 32) | b.*[i];
        b.*[i] = cast,trunc(u32)(t / d);
        rem = t % d;
        i -= 1;
    }
    big_trim(b);
    return cast(u32) rem;
}
big_bitlen :: (b: Big) -> s64 {
    if b.count == 0 return 0;
    top := b[b.count - 1];
    n := 0;
    while top != 0 { n += 1; top >>= 1; }
    return (b.count - 1) * 32 + n;
}
big_bit :: (b: Big, i: s64) -> bool {
    if i < 0 return false;
    li := i / 32;
    if li >= b.count return false;
    return ((b[li] >> cast(u32)(i % 32)) & 1) != 0;
}
big_any_below :: (b: Big, nbits: s64) -> bool {  // any bit set in positions [0, nbits)
    if nbits <= 0 return false;
    full := nbits / 32;
    if min(full, b.count) > 0 for i: 0..min(full, b.count)-1 if b[i] != 0 return true;
    r := nbits % 32;
    if r != 0 && full < b.count {
        if (b[full] & ((cast(u32)1 << cast(u32) r) - 1)) != 0 return true;
    }
    return false;
}
big_shl :: (b: Big, s: s64) -> Big {
    r: Big; r.allocator = temp;
    if b.count == 0 return r;
    limbs := s / 32; bits := cast(u32)(s % 32);
    if limbs > 0 for 0..limbs-1 array_add(*r, 0);
    carry: u32 = 0;
    for b {
        if bits == 0 { array_add(*r, it); }
        else {
            array_add(*r, (it << bits) | carry);
            carry = it >> (32 - bits);
        }
    }
    if carry array_add(*r, carry);
    big_trim(*r);
    return r;
}
big_shr :: (b: Big, s: s64) -> Big {
    r: Big; r.allocator = temp;
    limbs := s / 32; bits := cast(u32)(s % 32);
    if limbs >= b.count return r;
    for i: limbs..b.count-1 {
        lo := b[i] >> bits;
        if bits != 0 && i + 1 < b.count lo |= b[i + 1] << (32 - bits);
        array_add(*r, lo);
    }
    big_trim(*r);
    return r;
}
big_cmp :: (a: Big, b: Big) -> int {
    if a.count != b.count return ifx a.count < b.count then -1 else 1;
    i := a.count - 1;
    while i >= 0 {
        if a[i] != b[i] return ifx a[i] < b[i] then -1 else 1;
        i -= 1;
    }
    return 0;
}
big_sub :: (a: *Big, b: Big) {  // a -= b, requires a >= b
    borrow: s64 = 0;
    for i: 0..a.count-1 {
        t := cast(s64) a.*[i] - borrow - (ifx i < b.count then cast(s64) b[i] else 0);
        if t < 0 { t += 0x1_0000_0000; borrow = 1; } else borrow = 0;
        a.*[i] = cast(u32) t;
    }
    big_trim(a);
}
big_mul :: (a: Big, b: Big) -> Big {
    r: Big; r.allocator = temp;
    if a.count == 0 || b.count == 0 return r;
    array_resize(*r, a.count + b.count);
    for i: 0..a.count-1 {
        carry: u64 = 0;
        ai := cast(u64) a[i];
        for j: 0..b.count-1 {
            t := ai * b[j] + r[i + j] + carry;
            r[i + j] = cast,trunc(u32) t;
            carry = t >> 32;
        }
        k := i + b.count;
        while carry != 0 {
            t := cast(u64) r[k] + carry;
            r[k] = cast,trunc(u32) t;
            carry = t >> 32;
            k += 1;
        }
    }
    big_trim(*r);
    return r;
}
big_pow :: (base: u32, e: s64) -> Big {
    r := big_from_u64(1);
    p := big_from_u64(base);
    while e > 0 {
        if e & 1 r = big_mul(r, p);
        e >>= 1;
        if e p = big_mul(p, p);
    }
    return r;
}
// Long division: q = a / d, returns remainder. Simple shift-subtract (only used on small sizes).
big_divmod :: (a: Big, d: Big) -> (q: Big, r: Big) {
    q: Big; q.allocator = temp;
    r: Big; r.allocator = temp;
    if big_cmp(a, d) < 0 { return q, big_copy(a); }
    n := big_bitlen(a);
    array_resize(*q, (n + 31) / 32);
    i := n - 1;
    while i >= 0 {
        r = big_shl(r, 1);
        if big_bit(a, i) { if r.count == 0 array_add(*r, 1); else r[0] |= 1; }
        if big_cmp(r, d) >= 0 {
            big_sub(*r, d);
            q[i / 32] |= cast(u32)1 << cast(u32)(i % 32);
        }
        i -= 1;
    }
    big_trim(*q);
    return q, r;
}

big_to_decimal :: (b: Big) -> string {
    if b.count == 0 return "0";
    t := big_copy(b);
    digits: [..] u8; digits.allocator = temp;
    while t.count > 0 {
        // divide by 10^9 at a time
        r := big_divmod_small(*t, 1_000_000_000);
        for 0..8 {
            array_add(*digits, cast(u8)(#char "0" + r % 10));
            r /= 10;
            if t.count == 0 && r == 0 break;
        }
    }
    while digits.count > 1 && digits[digits.count - 1] == #char "0" digits.count -= 1;
    s := alloc_string(digits.count,, allocator = temp);
    for i: 0..digits.count-1 s[i] = digits[digits.count - 1 - i];
    return s;
}

big_to_hex :: (b: Big) -> string {
    if b.count == 0 return "0";
    HEX :: "0123456789ABCDEF";
    n := (big_bitlen(b) + 3) / 4;
    s := alloc_string(n,, allocator = temp);
    if n > 0 for i: 0..n-1 {
        nib: u32 = 0;
        for k: 0..3 if big_bit(b, (n - 1 - i) * 4 + k) nib |= cast(u32)1 << cast(u32) k;
        s[i] = HEX[nib];
    }
    return s;
}

// ---------------------------------------------------------------- APInt printing

// APInt::toString(signed) of a value of `bits` width stored in words.
apint_to_signed_decimal :: (words: [] u64, bits: u32) -> string {
    neg := bits > 0 && ((words[(bits - 1) / 64] >> ((bits - 1) % 64)) & 1) != 0;
    if !neg return big_to_decimal(big_from_words(words));
    // two's complement negate within width
    nw := words.count;
    t := NewArray(nw, u64,, allocator = temp);
    carry: u64 = 1;
    if nw > 0 for i: 0..nw-1 {
        x := ~words[i];
        s := x + carry;
        carry = ifx s < x then cast(u64) 1 else 0;
        t[i] = s;
    }
    mask_words(t, bits);
    return tprint("-%", big_to_decimal(big_from_words(t)));
}
apint_to_unsigned_decimal :: (words: [] u64) -> string { return big_to_decimal(big_from_words(words)); }

// Parse a decimal integer literal (optional leading '-') into `bits`-wide two's complement words.
// Returns the active bit count needed (for range checks) as well.
apint_from_decimal :: (s: string, bits: u32) -> [] u64 {
    neg := false;
    i := 0;
    if s.count > 0 && s[0] == #char "-" { neg = true; i = 1; }
    b: Big; b.allocator = temp;
    while i < s.count {
        big_mul_small(*b, 10);
        big_add_small(*b, cast(u32)(s[i] - #char "0"));
        i += 1;
    }
    nw := max(words_for_bits(bits), 1);
    w := big_to_words(b, nw + 2);
    if neg {
        carry: u64 = 1;
        for k: 0..w.count-1 {
            x := ~w[k]; sm := x + carry;
            carry = ifx sm < x then cast(u64) 1 else 0;
            w[k] = sm;
        }
    }
    r := NewArray(nw, u64,, allocator = temp);
    if nw > 0 for k: 0..nw-1 r[k] = w[k];
    mask_words(r, bits);
    return r;
}

// Bit length a decimal literal needs (APSInt from string: active bits, +1 for sign if negative).
decimal_literal_bits :: (s: string) -> u32 {
    neg := s.count > 0 && s[0] == #char "-";
    b: Big; b.allocator = temp;
    for i: (ifx neg then 1 else 0)..s.count-1 { big_mul_small(*b, 10); big_add_small(*b, cast(u32)(s[i] - #char "0")); }
    return cast(u32) big_bitlen(b) + (ifx neg then cast(u32)1 else 0);
}

// ---------------------------------------------------------------- APFloat encoding

Fp_Category :: enum u8 { ZERO; NORMAL; INF; NAN; }

Fp_Decoded :: struct {
    cat:  Fp_Category;
    neg:  bool;
    exp:  s64;      // unbiased exponent of the leading significand bit (normal/denormal)
    sig:  Big;      // significand including the integer bit, `precision` bits wide
    // for NaN: raw payload bits (significand without integer bit)
}

fp_bits_get :: (w: [] u64, i: s64) -> bool { return ((w[i / 64] >> cast(u64)(i % 64)) & 1) != 0; }

// Decode the bit pattern of an fp type.
fp_decode :: (k: Type_Kind, w: [] u64) -> Fp_Decoded {
    if k == .PPC_FP128 {
        // DoubleAPFloat: category and sign are the first double's (exact value: only via fp_check_kind'ed ops)
        hi := NewArray(1, u64,, allocator = temp); hi[0] = w[0];
        return fp_decode(.DOUBLE, hi);
    }
    p, emax, emin, bits := fp_semantics(k);
    d: Fp_Decoded;
    d.sig.allocator = temp;
    if k == .X86_FP80 {
        mant := w[0];
        se := w[1] & 0xFFFF;
        d.neg = (se & 0x8000) != 0;
        e := cast(s64)(se & 0x7FFF);
        if e == 0x7FFF {
            frac := mant & 0x7FFF_FFFF_FFFF_FFFF;
            if frac == 0 d.cat = .INF; else d.cat = .NAN;
            d.sig = big_from_u64(mant);
            return d;
        }
        if e == 0 && mant == 0 { d.cat = .ZERO; return d; }
        d.cat = .NORMAL;
        d.sig = big_from_u64(mant);
        if e == 0 d.exp = emin; else d.exp = e - 16383;
        return d;
    }
    ebits := bits - p;  // exponent bits (sign bit is the extra one): bits = 1 + ebits + (p-1)
    ebits = bits - 1 - (p - 1);
    fracbits := p - 1;
    // extract fields
    frac: Big; frac.allocator = temp;
    if fracbits > 0 for i: 0..fracbits-1 {
        if fp_bits_get(w, i) {
            li := i / 32;
            while frac.count <= li array_add(*frac, 0);
            frac[li] |= cast(u32)1 << cast(u32)(i % 32);
        }
    }
    big_trim(*frac);
    e: s64 = 0;
    if ebits > 0 for i: 0..ebits-1 if fp_bits_get(w, fracbits + i) e |= (cast(s64)1) << i;
    d.neg = fp_bits_get(w, bits - 1);
    allones := (cast(s64)1 << ebits) - 1;
    if e == allones {
        if big_is_zero(frac) d.cat = .INF; else d.cat = .NAN;
        d.sig = frac;
        return d;
    }
    if e == 0 {
        if big_is_zero(frac) { d.cat = .ZERO; return d; }
        d.cat = .NORMAL;
        d.sig = frac;
        d.exp = emin;
        return d;
    }
    d.cat = .NORMAL;
    // add implicit bit
    one := big_shl(big_from_u64(1), fracbits);
    s := frac;
    // s = frac | one
    while s.count < one.count array_add(*s, 0);
    for one s[it_index] |= it;
    d.sig = s;
    d.exp = e - emax;   // bias = emax
    return d;
}

// Encode (neg, biased fields) to words.
fp_encode :: (k: Type_Kind, neg: bool, cat: Fp_Category, exp: s64, sig: Big) -> [] u64 {
    p, emax, emin, bits := fp_semantics(k);
    nw := words_for_bits(cast(u32) bits);
    w := NewArray(nw, u64,, allocator = temp);
    setbit :: (w: [] u64, i: s64) { w[i / 64] |= (cast(u64)1) << cast(u64)(i % 64); }
    if k == .X86_FP80 {
        se: u64 = ifx neg then cast(u64) 0x8000 else 0;
        if cat == .ZERO {}
        else if cat == .INF { se |= 0x7FFF; w[0] = 0x8000_0000_0000_0000; }
        else if cat == .NAN { se |= 0x7FFF; sw := big_to_words(sig, 1); w[0] = sw[0]; }
        else {
            sw := big_to_words(sig, 1);
            w[0] = sw[0];
            if (sw[0] >> 63) != 0 se |= cast(u64)(exp + 16383);   // normal
        }
        w[1] = se;
        return w;
    }
    ebits := bits - 1 - (p - 1);
    fracbits := p - 1;
    if neg setbit(w, bits - 1);
    if cat == .ZERO return w;
    if cat == .INF || cat == .NAN {
        if ebits > 0 for i: 0..ebits-1 setbit(w, fracbits + i);
        if cat == .NAN if fracbits > 0 for i: 0..fracbits-1 if big_bit(sig, i) setbit(w, i);
        return w;
    }
    if fracbits > 0 for i: 0..fracbits-1 if big_bit(sig, i) setbit(w, i);
    if big_bit(sig, fracbits) {   // normal
        be := exp + emax;
        if ebits > 0 for i: 0..ebits-1 if (be >> i) & 1 setbit(w, fracbits + i);
    }
    return w;
}

// Round value = num/den * 2^e2 (num, den > 0) to the format, nearest-even.
// Returns words and status flags (overflow / inexact / underflow-to-zero).
fp_round :: (k: Type_Kind, neg: bool, num: Big, den: Big, e2: s64) -> (w: [] u64, overflow: bool, zero: bool) {
    w, st, z := fp_round_rm(k, neg, num, den, e2, RM_NEAREST_TIES_TO_EVEN);
    return w, (st & .OVERFLOW) != 0, z;
}

// RoundingMode (llvm/ADT/FloatingPointMode.h)
RM_TOWARD_ZERO :: 0; RM_NEAREST_TIES_TO_EVEN :: 1; RM_TOWARD_POSITIVE :: 2; RM_TOWARD_NEGATIVE :: 3; RM_NEAREST_TIES_TO_AWAY :: 4; RM_DYNAMIC :: 7;

// IEEEFloat::normalize + roundAwayFromZero + handleOverflow for the exact value num/den * 2^e2 (num, den > 0).
// Correctly rounded in mode `rm`; status as APFloat reports it (underflow only for inexact tiny results;
// overflow to the largest finite value reports only inexact).
fp_round_rm :: (k: Type_Kind, neg: bool, num: Big, den: Big, e2: s64, rm: u8) -> (w: [] u64, st: Fp_Status, zero: bool) {
    p, emax, emin, bits := fp_semantics(k);
    kshift := cast(s64)(p + 3) + max(0, big_bitlen(den) - big_bitlen(num));
    q, r := big_divmod(big_shl(num, kshift), den);
    sticky := !big_is_zero(r);
    msb := big_bitlen(q) - 1;
    exp := msb + e2 - kshift;
    lsb_exp := max(exp, cast(s64) emin) - (p - 1);
    sh := lsb_exp - (e2 - kshift);
    mant: Big;
    roundbit := false;
    if sh > 0 {
        mant = big_shr(q, sh);
        roundbit = big_bit(q, sh - 1);
        if big_any_below(q, sh - 1) sticky = true;
    } else {
        mant = big_shl(q, -sh);
    }
    inexact := roundbit || sticky;
    st: Fp_Status;
    e := lsb_exp + (p - 1);
    overflow_result :: (k: Type_Kind, neg: bool, rm: u8) -> [] u64, Fp_Status {
        if rm == RM_NEAREST_TIES_TO_EVEN || rm == RM_NEAREST_TIES_TO_AWAY || (rm == RM_TOWARD_POSITIVE && !neg) || (rm == RM_TOWARD_NEGATIVE && neg)
            return fp_inf(k, neg), .OVERFLOW | .INEXACT;
        return fp_largest(k, neg), .INEXACT;
    }
    // pre-rounding overflow (exponent of the leading bit above emax)
    if exp > emax { w, s2 := overflow_result(k, neg, rm); return w, s2, false; }
    if inexact {
        up := false;
        if rm == {
            case RM_NEAREST_TIES_TO_AWAY; up = roundbit;
            case RM_NEAREST_TIES_TO_EVEN; up = roundbit && (sticky || big_bit(mant, 0));
            case RM_TOWARD_ZERO; up = false;
            case RM_TOWARD_POSITIVE; up = !neg;
            case RM_TOWARD_NEGATIVE; up = neg;
            case; fatal("internal: invalid rounding mode %", rm);
        }
        if up big_add_small(*mant, 1);
        if big_bitlen(mant) > p {
            mant = big_shr(mant, 1);
            e += 1;
            if e > emax { z: Big; z.allocator = temp; return fp_inf(k, neg), .OVERFLOW | .INEXACT, false; }
        }
        st |= .INEXACT;
    }
    if big_is_zero(mant) {
        if inexact st |= .UNDERFLOW;
        return fp_encode(k, neg, .ZERO, 0, mant), st, true;
    }
    if big_bitlen(mant) == p return fp_encode(k, neg, .NORMAL, e, mant), st, false;
    if inexact st |= .UNDERFLOW;
    return fp_encode(k, neg, .NORMAL, emin, mant), st, false;
}

// APFloat::getLargest
fp_largest :: (k: Type_Kind, neg: bool) -> [] u64 {
    p, emax, emin, bits := fp_semantics(k);
    sig: Big; sig.allocator = temp;
    for i: 0..p-1 { big_mul_small(*sig, 2); big_add_small(*sig, 1); }
    return fp_encode(k, neg, .NORMAL, emax, sig);
}

// APFloat::convertFromString for decimal and hexadecimal (0x...p...) literals and inf/nan forms.
fp_from_string :: (k: Type_Kind, s_in: string) -> (w: [] u64, ok: bool, overflow: bool, zero: bool) {
    s := s_in;
    neg := false;
    if s.count && (s[0] == #char "-" || s[0] == #char "+") { neg = s[0] == #char "-"; s = slice(s, 1, s.count - 1); }
    p, emax, emin, bits := fp_semantics(k);
    if s == "inf" { e: Big; return fp_encode(k, neg, .INF, 0, e), true, false, false; }
    if begins_with(s, "nan(") || begins_with(s, "snan(") {
        snan := s[0] == #char "s";
        inner := slice(s, ifx snan then 5 else 4, s.count - (ifx snan then 6 else 5));
        payload: Big; payload.allocator = temp;
        if begins_with(inner, "0x") inner = slice(inner, 2, inner.count - 2);
        for i: 0..inner.count-1 {
            c := inner[i];
            dgt: u32 = ifx c >= #char "a" then cast(u32)(c - #char "a" + 10) else ifx c >= #char "A" then cast(u32)(c - #char "A" + 10) else cast(u32)(c - #char "0");
            big_mul_small(*payload, 16); big_add_small(*payload, dgt);
        }
        // payload bits within fraction (excluding the quiet bit)
        qbit := p - 2;
        if k == .X86_FP80 qbit = 62;
        sig := big_shr(big_shl(payload, 0), 0);
        // truncate to below the quiet bit
        tr: Big; tr.allocator = temp;
        if qbit > 0 for i: 0..qbit-1 if big_bit(sig, i) { li := i / 32; while tr.count <= li array_add(*tr, 0); tr[li] |= cast(u32)1 << cast(u32)(i % 32); }
        big_trim(*tr);
        if !snan {
            q := big_shl(big_from_u64(1), qbit);
            while tr.count < q.count array_add(*tr, 0);
            for q tr[it_index] |= it;
        } else if big_is_zero(tr) {
            tr = big_from_u64(1);
        }
        if k == .X86_FP80 {
            ib := big_shl(big_from_u64(1), 63);
            while tr.count < ib.count array_add(*tr, 0);
            for ib tr[it_index] |= it;
        }
        return fp_encode(k, neg, .NAN, 0, tr), true, false, false;
    }
    if begins_with(s, "0x") || begins_with(s, "0X") {
        // hexadecimal float: 0xH.HHHp[+-]D
        num: Big; num.allocator = temp;
        e2: s64 = 0;
        i := 2; seen_dot := false;
        while i < s.count && s[i] != #char "p" && s[i] != #char "P" {
            c := s[i];
            if c == #char "." { seen_dot = true; i += 1; continue; }
            dgt: u32 = ifx c >= #char "a" then cast(u32)(c - #char "a" + 10) else ifx c >= #char "A" then cast(u32)(c - #char "A" + 10) else cast(u32)(c - #char "0");
            big_mul_small(*num, 16); big_add_small(*num, dgt);
            if seen_dot e2 -= 4;
            i += 1;
        }
        i += 1;
        eneg := false;
        if i < s.count && (s[i] == #char "-" || s[i] == #char "+") { eneg = s[i] == #char "-"; i += 1; }
        ev: s64 = 0;
        while i < s.count { ev = ev * 10 + cast(s64)(s[i] - #char "0"); i += 1; if ev > 100000 ev = 100000; }
        e2 += ifx eneg then -ev else ev;
        if big_is_zero(num) { z: Big; return fp_encode(k, neg, .ZERO, 0, z), true, false, false; }
        w, of, zr := fp_round(k, neg, num, big_from_u64(1), e2);
        return w, true, of, zr;
    }
    // decimal
    num: Big; num.allocator = temp;
    e10: s64 = 0;
    i := 0; seen_dot := false; any := false;
    while i < s.count {
        c := s[i];
        if c == #char "." { seen_dot = true; i += 1; continue; }
        if c < #char "0" || c > #char "9" break;
        big_mul_small(*num, 10); big_add_small(*num, cast(u32)(c - #char "0"));
        if seen_dot e10 -= 1;
        any = true;
        i += 1;
    }
    if i < s.count && (s[i] == #char "e" || s[i] == #char "E") {
        i += 1;
        eneg := false;
        if i < s.count && (s[i] == #char "-" || s[i] == #char "+") { eneg = s[i] == #char "-"; i += 1; }
        ev: s64 = 0;
        while i < s.count { ev = ev * 10 + cast(s64)(s[i] - #char "0"); i += 1; if ev > 100000 ev = 100000; }
        e10 += ifx eneg then -ev else ev;
    }
    if !any return .[], false, false, false;
    if big_is_zero(num) { z: Big; return fp_encode(k, neg, .ZERO, 0, z), true, false, false; }
    // clamp absurd exponents
    if e10 > 6000 { e: Big; return fp_encode(k, neg, .INF, 0, e), true, true, false; }
    if e10 < -6000 - num.count * 10 { z: Big; return fp_encode(k, neg, .ZERO, 0, z), true, false, true; }
    w: [] u64; of, zr: bool;
    if e10 >= 0 {
        w, of, zr = fp_round(k, neg, big_mul(num, big_pow(10, e10)), big_from_u64(1), 0);
    } else {
        w, of, zr = fp_round(k, neg, num, big_pow(10, -e10), 0);
    }
    return w, true, of, zr;
}

// APFloat::convert between formats (round to nearest even). Returns words and whether it was exact.
fp_convert :: (from: Type_Kind, to: Type_Kind, w: [] u64) -> (w: [] u64, exact: bool) {
    // ppc_fp128 (double-double): only values that are exactly a double (second double +0) are handled
    if to == .PPC_FP128 {
        if from == .PPC_FP128 return w, true;
        if from != .HALF && from != .BFLOAT && from != .FLOAT && from != .DOUBLE
            fatal("conversion to ppc_fp128 from this type is not supported yet");
        dw, ex := fp_convert(from, .DOUBLE, w);
        r := NewArray(2, u64,, allocator = temp);
        r[0] = dw[0];
        return r, true;
    }
    if from == .PPC_FP128 {
        if w[1] != 0 fatal("conversion of a ppc_fp128 that is not exactly a double is not supported yet");
        hw := NewArray(1, u64,, allocator = temp); hw[0] = w[0];
        cw, cx := fp_convert(.DOUBLE, to, hw);
        return cw, cx;
    }
    d := fp_decode(from, w);
    pf, ef, mf, bf := fp_semantics(from);
    pt, et, mt, bt := fp_semantics(to);
    if d.cat == .ZERO { z: Big; return fp_encode(to, d.neg, .ZERO, 0, z), true; }
    if d.cat == .INF { z: Big; return fp_encode(to, d.neg, .INF, 0, z), true; }
    if d.cat == .NAN {
        // shift the payload (fraction bits) to the destination width
        fracf := ifx from == .X86_FP80 then 63 else pf - 1;
        fract := ifx to == .X86_FP80 then 63 else pt - 1;
        sig := d.sig;
        if from == .X86_FP80 {
            // drop integer bit
            tr: Big; tr.allocator = temp;
            for i: 0..62 if big_bit(sig, i) { li := i / 32; while tr.count <= li array_add(*tr, 0); tr[li] |= cast(u32)1 << cast(u32)(i % 32); }
            big_trim(*tr); sig = tr;
        }
        exact := true;
        if fract < fracf {
            if big_any_below(sig, fracf - fract) exact = false;
            sig = big_shr(sig, fracf - fract);
        } else sig = big_shl(sig, fract - fracf);
        // APFloat::convert makes the NaN quiet
        q := big_shl(big_from_u64(1), fract - 1);
        while sig.count < q.count array_add(*sig, 0);
        for q sig[it_index] |= it;
        if to == .X86_FP80 {
            ib := big_shl(big_from_u64(1), 63);
            while sig.count < ib.count array_add(*sig, 0);
            for ib sig[it_index] |= it;
        }
        return fp_encode(to, d.neg, .NAN, 0, sig), exact;
    }
    // value = sig * 2^(exp - (pf-1))
    w2, of, zr := fp_round(to, d.neg, d.sig, big_from_u64(1), d.exp - (pf - 1));
    back := fp_convert_exact_check(to, from, w2, w);
    return w2, back;
}
fp_convert_exact_check :: (to: Type_Kind, from: Type_Kind, w2: [] u64, orig: [] u64) -> bool {
    // exact iff converting back yields the same value
    d := fp_decode(to, w2);
    if d.cat != .NORMAL return true;
    pt, et, mt, bt := fp_semantics(to);
    w3, of, zr := fp_round(from, d.neg, d.sig, big_from_u64(1), d.exp - (pt - 1));
    for w3 if it != orig[it_index] return false;
    return true;
}

// ---------------------------------------------------------------- APFloat::toString(Str, 6, 0, false)

adjust_to_precision_big :: (sig: *Big, exp: *s64, prec: s64) {
    bits := big_bitlen(sig.*);
    required := (prec * 196 + 58) / 59;
    if bits <= required return;
    tens := (bits - required) * 59 / 196;
    if tens == 0 return;
    exp.* += tens;
    if tens > 0 for 0..tens-1 big_divmod_small(sig, 10);
}

adjust_to_precision_digits :: (buffer: *[..] u8, exp: *s64, prec: s64) {
    n := buffer.count;
    if n <= prec return;
    first := n - prec;
    if buffer.*[first - 1] < #char "5" {
        while first < n && buffer.*[first] == #char "0" first += 1;
        exp.* += first;
        array_erase_front(buffer, first);
        return;
    }
    i := first;
    while i != n {
        if buffer.*[i] == #char "9" first += 1;
        else { buffer.*[i] += 1; break; }
        i += 1;
    }
    if first == n {
        exp.* += first;
        buffer.count = 0;
        array_add(buffer, #char "1");
        return;
    }
    exp.* += first;
    array_erase_front(buffer, first);
}
array_erase_front :: (b: *[..] u8, n: s64) {
    for i: 0..b.count-n-1 b.*[i] = b.*[i + n];
    b.count -= n;
}

// Returns the string APFloat::toString(FormatPrecision=6, FormatMaxPadding=0, TruncateZero=false) produces
// for a finite value.
fp_to_string_e6 :: (k: Type_Kind, w: [] u64) -> string {
    d := fp_decode(k, w);
    sb: String_Builder; sb.allocator = temp;
    prec: s64 = 6;
    if d.cat == .ZERO {
        if d.neg append(*sb, "-");
        append(*sb, "0.000000e+00");
        return builder_to_string(*sb,, allocator = temp);
    }
    p, emax, emin, bits := fp_semantics(k);
    if d.neg append(*sb, "-");
    exp := d.exp - (p - 1);
    sig := big_copy(d.sig);
    // trailing zeros
    tz := 0;
    while !big_bit(sig, tz) tz += 1;
    exp += tz;
    sig = big_shr(sig, tz);
    if exp > 0 {
        sig = big_shl(sig, exp);
        exp = 0;
    } else if exp < 0 {
        texp := -exp;
        sig = big_mul(sig, big_pow(5, texp));
    }
    adjust_to_precision_big(*sig, *exp, prec);
    buffer: [..] u8; buffer.allocator = temp;
    in_trail := true;
    while !big_is_zero(sig) {
        dg := big_divmod_small(*sig, 10);
        if in_trail && dg == 0 exp += 1;
        else { array_add(*buffer, cast(u8)(#char "0" + dg)); in_trail = false; }
    }
    adjust_to_precision_digits(*buffer, *exp, prec);
    nd := buffer.count;
    exp += nd - 1;
    append(*sb, buffer[nd - 1]);
    append(*sb, #char ".");
    for i: 1..nd-1 append(*sb, buffer[nd - 1 - i]);
    if prec > nd - 1 for 0..prec-nd append(*sb, #char "0");
    append(*sb, #char "e");
    append(*sb, ifx exp >= 0 then "+" else "-");
    if exp < 0 exp = -exp;
    if exp < 10 append(*sb, #char "0");
    append_u64(*sb, cast(u64) exp);
    return builder_to_string(*sb,, allocator = temp);
}

// ---------------------------------------------------------------- ppc_fp128 (double-double)
// A ppc_fp128 is a pair of doubles (words [hi, lo]); value = hi + lo. Only values whose decimal text is exactly a
// double (lo = +0) are converted from decimal; others fail loudly (DoubleAPFloat::convertFromString would need the
// 106-bit legacy semantics).

// exactness check: the decimal string and the double denote the same real number (compared at fp128 precision)
ppc_decimal_is_double :: (s: string, hi: u64) -> bool {
    q, ok, of, zr := fp_from_string(.FP128, s);
    if !ok return false;
    hw := NewArray(1, u64,, allocator = temp); hw[0] = hi;
    q2, exact := fp_convert(.DOUBLE, .FP128, hw);
    return q[0] == q2[0] && q[1] == q2[1];
}

ppc_from_decimal :: (s: string) -> (w: [] u64, ok: bool, overflow: bool) {
    d, ok, of, zr := fp_from_string(.DOUBLE, s);
    w := NewArray(2, u64,, allocator = temp);
    if !ok return w, false, false;
    w[0] = d[0]; w[1] = 0;
    if of return w, true, true;
    if !ppc_decimal_is_double(s, d[0]) fatal("ppc_fp128 decimal literal '%' is not exactly a double (not supported yet)", s);
    return w, true, false;
}

// ---------------------------------------------------------------- IEEEFloat arithmetic (nearest-even)
// Ported from llvm/lib/Support/APFloat.cpp (IEEEFloat::add/subtract/multiply/divide/mod, the *Specials tables,
// makeNaN/makeQuiet, compare, convertToInteger (rmTowardZero), convertFromAPInt). Values are exact rationals
// sig * 2^(exp - (p-1)) rounded once with fp_round, which is what IEEE round-to-nearest-even requires.
// ppc_fp128 (double-double) arithmetic is not supported and fails loudly.

Fp_Status :: enum_flags u8 { INVALID; DIV_BY_ZERO; OVERFLOW; UNDERFLOW; INEXACT; }

big_add :: (a: Big, b: Big) -> Big {
    r: Big; r.allocator = temp;
    carry: u64 = 0;
    n := max(a.count, b.count);
    for i: 0..n-1 {
        s := carry;
        if i < a.count s += a[i];
        if i < b.count s += b[i];
        array_add(*r, cast,trunc(u32) s);
        carry = s >> 32;
    }
    if carry array_add(*r, cast(u32) carry);
    big_trim(*r);
    return r;
}

fp_check_kind :: (k: Type_Kind) {
    if k == .PPC_FP128 fatal("ppc_fp128 arithmetic constant folding is not supported yet");
}

fp_frac_bits :: (k: Type_Kind) -> s64 { p, mx, mn, b := fp_semantics(k); return ifx k == .X86_FP80 then 63 else p - 1; }

fp_is_signaling :: (k: Type_Kind, d: Fp_Decoded) -> bool {
    if d.cat != .NAN return false;
    return !big_bit(d.sig, fp_frac_bits(k) - 1);
}

// makeQuiet on a NaN bit pattern
fp_quiet :: (k: Type_Kind, w: [] u64) -> [] u64 {
    r := NewArray(w.count, u64,, allocator = temp);
    for w r[it_index] = it;
    qb := fp_frac_bits(k) - 1;
    r[qb / 64] |= (cast(u64) 1) << cast(u64)(qb % 64);
    return r;
}

// makeNaN(): positive quiet NaN, zero payload
fp_default_nan :: (k: Type_Kind) -> [] u64 {
    s: Big; s.allocator = temp;
    s = big_shl(big_from_u64(1), fp_frac_bits(k) - 1);
    if k == .X86_FP80 s = big_add(s, big_shl(big_from_u64(1), 63));
    return fp_encode(k, false, .NAN, 0, s);
}

fp_inf :: (k: Type_Kind, neg: bool) -> [] u64 { z: Big; z.allocator = temp; return fp_encode(k, neg, .INF, 0, z); }
fp_zero :: (k: Type_Kind, neg: bool) -> [] u64 { z: Big; z.allocator = temp; return fp_encode(k, neg, .ZERO, 0, z); }

fp_with_sign :: (k: Type_Kind, w: [] u64, neg: bool) -> [] u64 {
    p, mx, mn, bits := fp_semantics(k);
    r := NewArray(w.count, u64,, allocator = temp);
    for w r[it_index] = it;
    if k == .PPC_FP128 {
        // DoubleAPFloat::changeSign flips both doubles; the sign is the first double's
        if ((r[0] >> 63) != 0) != neg { r[0] ^= 0x8000_0000_0000_0000; r[1] ^= 0x8000_0000_0000_0000; }
        return r;
    }
    sb := ifx k == .X86_FP80 then cast(s64) 79 else bits - 1;
    m := (cast(u64) 1) << cast(u64)(sb % 64);
    if neg r[sb / 64] |= m; else r[sb / 64] &= ~m;
    return r;
}
fp_neg :: (k: Type_Kind, w: [] u64) -> [] u64 { d := fp_decode(k, w); return fp_with_sign(k, w, !d.neg); }

// the NaN operand handling shared by the *Specials tables: result is the NaN (lhs first), quieted
fp_nan_result :: (k: Type_Kind, a: [] u64, da: Fp_Decoded, b: [] u64, db: Fp_Decoded) -> [] u64, Fp_Status {
    st: Fp_Status;
    src := ifx da.cat == .NAN then a else b;
    sd := ifx da.cat == .NAN then da else db;
    if fp_is_signaling(k, da) || fp_is_signaling(k, db) st |= .INVALID;
    if fp_is_signaling(k, sd) return fp_quiet(k, src), st;
    return src, st;
}

fp_round_status :: (k: Type_Kind, neg: bool, num: Big, den: Big, e2: s64, rm: u8 = RM_NEAREST_TIES_TO_EVEN) -> [] u64, Fp_Status {
    w, st, zr := fp_round_rm(k, neg, num, den, e2, rm);
    return w, st;
}

// IEEEFloat::addOrSubtract
fp_add_sub :: (k: Type_Kind, a: [] u64, b: [] u64, subtract: bool, rm: u8 = RM_NEAREST_TIES_TO_EVEN) -> [] u64, Fp_Status {
    fp_check_kind(k);
    da := fp_decode(k, a); db := fp_decode(k, b);
    if da.cat == .NAN || db.cat == .NAN { rr_, ss_ := fp_nan_result(k, a, da, b, db); return rr_, ss_; }
    bneg := db.neg != subtract;
    if da.cat == .INF && db.cat == .INF {
        if da.neg != bneg return fp_default_nan(k), .INVALID;
        return a, 0;
    }
    if da.cat == .INF return a, 0;
    if db.cat == .INF return fp_inf(k, bneg), 0;
    if da.cat == .ZERO && db.cat == .ZERO return fp_zero(k, ifx da.neg == bneg then da.neg else rm == RM_TOWARD_NEGATIVE), 0;
    if da.cat == .ZERO return fp_with_sign(k, b, bneg), 0;
    if db.cat == .ZERO return a, 0;
    p, mx, mn, bits := fp_semantics(k);
    ea := da.exp - (p - 1); eb := db.exp - (p - 1);
    e := min(ea, eb);
    sa := big_shl(da.sig, ea - e); sb := big_shl(db.sig, eb - e);
    if da.neg == bneg { rr_, ss_ := fp_round_status(k, da.neg, big_add(sa, sb), big_from_u64(1), e, rm); return rr_, ss_; }
    c := big_cmp(sa, sb);
    if c == 0 return fp_zero(k, rm == RM_TOWARD_NEGATIVE), 0;   // exact zero: +0 unless rounding toward -inf
    if c > 0 { r := big_copy(sa); big_sub(*r, sb); { rr_, ss_ := fp_round_status(k, da.neg, r, big_from_u64(1), e, rm); return rr_, ss_; } }
    r := big_copy(sb); big_sub(*r, sa);
    { rr_, ss_ := fp_round_status(k, bneg, r, big_from_u64(1), e, rm); return rr_, ss_; }
}

// IEEEFloat::multiply
fp_mul :: (k: Type_Kind, a: [] u64, b: [] u64, rm: u8 = RM_NEAREST_TIES_TO_EVEN) -> [] u64, Fp_Status {
    fp_check_kind(k);
    da := fp_decode(k, a); db := fp_decode(k, b);
    if da.cat == .NAN || db.cat == .NAN { rr_, ss_ := fp_nan_result(k, a, da, b, db); return rr_, ss_; }
    neg := da.neg != db.neg;
    if (da.cat == .ZERO && db.cat == .INF) || (da.cat == .INF && db.cat == .ZERO) return fp_default_nan(k), .INVALID;
    if da.cat == .INF || db.cat == .INF return fp_inf(k, neg), 0;
    if da.cat == .ZERO || db.cat == .ZERO return fp_zero(k, neg), 0;
    p, mx, mn, bits := fp_semantics(k);
    { rr_, ss_ := fp_round_status(k, neg, big_mul(da.sig, db.sig), big_from_u64(1), da.exp + db.exp - 2 * (p - 1), rm); return rr_, ss_; }
}

// IEEEFloat::divide
fp_div :: (k: Type_Kind, a: [] u64, b: [] u64, rm: u8 = RM_NEAREST_TIES_TO_EVEN) -> [] u64, Fp_Status {
    fp_check_kind(k);
    da := fp_decode(k, a); db := fp_decode(k, b);
    if da.cat == .NAN || db.cat == .NAN { rr_, ss_ := fp_nan_result(k, a, da, b, db); return rr_, ss_; }
    neg := da.neg != db.neg;
    if (da.cat == .INF && db.cat == .INF) || (da.cat == .ZERO && db.cat == .ZERO) return fp_default_nan(k), .INVALID;
    if da.cat == .INF return fp_inf(k, neg), 0;
    if da.cat == .ZERO return fp_zero(k, neg), 0;
    if db.cat == .INF return fp_zero(k, neg), 0;
    if db.cat == .ZERO return fp_inf(k, neg), .DIV_BY_ZERO;
    { rr_, ss_ := fp_round_status(k, neg, da.sig, db.sig, da.exp - db.exp, rm); return rr_, ss_; }
}

// IEEEFloat::mod (fmod: a - trunc(a/b)*b, exact, sign of a)
fp_mod :: (k: Type_Kind, a: [] u64, b: [] u64) -> [] u64, Fp_Status {
    fp_check_kind(k);
    da := fp_decode(k, a); db := fp_decode(k, b);
    if da.cat == .NAN || db.cat == .NAN { rr_, ss_ := fp_nan_result(k, a, da, b, db); return rr_, ss_; }
    if db.cat == .ZERO || da.cat == .INF return fp_default_nan(k), .INVALID;
    if da.cat == .ZERO || db.cat == .INF return a, 0;
    p, mx, mn, bits := fp_semantics(k);
    ea := da.exp - (p - 1); eb := db.exp - (p - 1);
    e := min(ea, eb);
    sa := big_shl(da.sig, ea - e); sb := big_shl(db.sig, eb - e);
    q, r := big_divmod(sa, sb);
    if big_is_zero(r) return fp_zero(k, da.neg), 0;
    { rr_, ss_ := fp_round_status(k, da.neg, r, big_from_u64(1), e); return rr_, ss_; }
}

Fp_Cmp :: enum u8 { LESS; EQUAL; GREATER; UNORDERED; }

// IEEEFloat::compare
fp_compare :: (k: Type_Kind, a: [] u64, b: [] u64) -> Fp_Cmp {
    fp_check_kind(k);
    da := fp_decode(k, a); db := fp_decode(k, b);
    if da.cat == .NAN || db.cat == .NAN return .UNORDERED;
    if da.cat == .ZERO && db.cat == .ZERO return .EQUAL;
    // signed magnitude comparison of exact values
    sgn :: (d: Fp_Decoded) -> int { if d.cat == .ZERO return 0; return ifx d.neg then -1 else 1; }
    s1 := sgn(da); s2 := sgn(db);
    if s1 != s2 return ifx s1 < s2 then .LESS else .GREATER;
    // same sign, both nonzero
    mag: int;
    if da.cat == .INF && db.cat == .INF mag = 0;
    else if da.cat == .INF mag = 1;
    else if db.cat == .INF mag = -1;
    else {
        p, mx, mn, bits := fp_semantics(k);
        ea := da.exp; eb := db.exp;
        e := min(ea, eb);
        mag = big_cmp(big_shl(da.sig, ea - e), big_shl(db.sig, eb - e));
    }
    if mag == 0 return .EQUAL;
    if s1 < 0 mag = -mag;
    return ifx mag < 0 then .LESS else .GREATER;
}

// IEEEFloat::convertToInteger(rmTowardZero): ok = false for opInvalidOp (NaN, inf, out of range)
fp_to_integer :: (k: Type_Kind, w: [] u64, bits: u32, is_signed: bool) -> (words: [] u64, ok: bool) {
    fp_check_kind(k);
    d := fp_decode(k, w);
    res := NewArray(words_for_bits(bits), u64,, allocator = temp);
    if d.cat == .NAN || d.cat == .INF return res, false;
    if d.cat == .ZERO return res, true;
    p, mx, mn, nb := fp_semantics(k);
    sh := d.exp - (p - 1);
    mag: Big;
    if sh >= 0 mag = big_shl(d.sig, sh); else mag = big_shr(d.sig, -sh);
    // range check
    lim := cast(s64) bits;
    if is_signed lim -= 1;
    bl := big_bitlen(mag);
    if d.neg && !is_signed { if !big_is_zero(mag) return res, false; return res, true; }
    if bl > lim {
        // -2^(bits-1) is representable for signed
        if !(is_signed && d.neg && bl == lim + 1 && !big_any_below(mag, lim)) return res, false;
    }
    mw := big_to_words(mag, cast(u32) res.count);
    for mw res[it_index] = it;
    if d.neg {
        // two's complement negate
        carry: u64 = 1;
        for i: 0..res.count-1 { x := ~res[i]; s := x + carry; carry = ifx s < x then cast(u64) 1 else 0; res[i] = s; }
        mask_words(res, bits);
    }
    return res, true;
}

// IEEEFloat::convertFromAPInt (nearest-even)
fp_from_integer :: (k: Type_Kind, words: [] u64, bits: u32, is_signed: bool) -> [] u64 {
    fp_check_kind(k);
    w := NewArray(words.count, u64,, allocator = temp);
    for words w[it_index] = it;
    neg := is_signed && bits > 0 && ((w[(bits - 1) / 64] >> cast(u64)((bits - 1) % 64)) & 1) != 0;
    if neg {
        carry: u64 = 1;
        for i: 0..w.count-1 { x := ~w[i]; s := x + carry; carry = ifx s < x then cast(u64) 1 else 0; w[i] = s; }
        mask_words(w, bits);
    }
    mag := big_from_words(w);
    if big_is_zero(mag) return fp_zero(k, false);
    r, of, zr := fp_round(k, neg, mag, big_from_u64(1), 0);
    return r;
}
