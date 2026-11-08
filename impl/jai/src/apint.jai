// Arbitrary-width integers for passes and analyses: the subset of llvm/include/llvm/ADT/APInt.h
// (llvm/lib/Support/APInt.cpp) that passes need, plus KnownBits (llvm/include/llvm/Support/KnownBits.h).
//
// An APInt is a value: `bits` and a slice of little-endian 64-bit words, normalized (bits above `bits` are zero).
// Every operation returns a fresh value whose words come from `context.allocator`; passes run with the temporary
// allocator as context, analyses that outlive a pass push their own allocator (see DESIGN.md "Pass infrastructure").

APInt :: struct {
    bits: u32;
    w: [] u64;
}

ap_nwords :: inline (bits: u32) -> s64 { return cast(s64)((bits + 63) / 64); }

ap_alloc :: (bits: u32) -> APInt {
    r: APInt;
    r.bits = bits;
    r.w = NewArray(ap_nwords(bits), u64,, allocator = temp);   // zeroed
    return r;
}

ap_normalize :: (a: *APInt) {
    rem := a.bits % 64;
    if rem != 0 && a.w.count > 0 a.w[a.w.count - 1] &= ((cast(u64) 1) << cast(u64) rem) - 1;
}

ap_zero :: (bits: u32) -> APInt { return ap_alloc(bits); }
ap_from_u64 :: (bits: u32, v: u64) -> APInt {
    r := ap_alloc(bits);
    if r.w.count > 0 r.w[0] = v;
    ap_normalize(*r);
    return r;
}
ap_from_s64 :: (bits: u32, v: s64) -> APInt {
    r := ap_alloc(bits);
    for i: 0..r.w.count-1 r.w[i] = ifx v < 0 then cast(u64) 0xFFFF_FFFF_FFFF_FFFF else 0;
    if r.w.count > 0 r.w[0] = cast,no_check(u64) v;
    ap_normalize(*r);
    return r;
}
ap_from_words :: (bits: u32, words: [] u64) -> APInt {
    r := ap_alloc(bits);
    for i: 0..min(r.w.count, words.count)-1 r.w[i] = words[i];
    ap_normalize(*r);
    return r;
}
ap_copy :: (a: APInt) -> APInt { return ap_from_words(a.bits, a.w); }
ap_all_ones :: (bits: u32) -> APInt {
    r := ap_alloc(bits);
    for i: 0..r.w.count-1 r.w[i] = 0xFFFF_FFFF_FFFF_FFFF;
    ap_normalize(*r);
    return r;
}

ap_get_bit :: inline (a: APInt, i: u32) -> bool { return ((a.w[i / 64] >> cast(u64)(i % 64)) & 1) != 0; }
ap_set_bit :: inline (a: *APInt, i: u32) { a.w[i / 64] |= (cast(u64) 1) << cast(u64)(i % 64); }
ap_clear_bit :: inline (a: *APInt, i: u32) { a.w[i / 64] &= ~((cast(u64) 1) << cast(u64)(i % 64)); }
ap_set_sign_bit :: (a: *APInt) { ap_set_bit(a, a.bits - 1); }
ap_is_negative :: (a: APInt) -> bool { return ap_get_bit(a, a.bits - 1); }

// [lo, hi) set
ap_set_bits :: (a: *APInt, lo: u32, hi: u32) { i := lo; while i < hi { ap_set_bit(a, i); i += 1; } }
ap_low_bits_set :: (bits: u32, n: u32) -> APInt { r := ap_alloc(bits); ap_set_bits(*r, 0, min(n, bits)); return r; }
ap_high_bits_set :: (bits: u32, n: u32) -> APInt { r := ap_alloc(bits); n = min(n, bits); ap_set_bits(*r, bits - n, bits); return r; }
ap_bits_set_from :: (bits: u32, lo: u32) -> APInt { r := ap_alloc(bits); ap_set_bits(*r, lo, bits); return r; }
ap_one_bit_set :: (bits: u32, i: u32) -> APInt { r := ap_alloc(bits); ap_set_bit(*r, i); return r; }
ap_signed_min :: (bits: u32) -> APInt { return ap_one_bit_set(bits, bits - 1); }
ap_signed_max :: (bits: u32) -> APInt { r := ap_all_ones(bits); ap_clear_bit(*r, bits - 1); return r; }

ap_is_zero :: (a: APInt) -> bool { for a.w if it != 0 return false; return true; }
ap_is_all_ones :: (a: APInt) -> bool { return ap_popcount(a) == a.bits; }
ap_is_one :: (a: APInt) -> bool { if a.w[0] != 1 return false; for i: 1..a.w.count-1 if a.w[i] != 0 return false; return true; }
ap_eq :: (a: APInt, b: APInt) -> bool {
    assert(a.bits == b.bits);
    for a.w if it != b.w[it_index] return false;
    return true;
}
ap_eq_u64 :: (a: APInt, v: u64) -> bool {
    if a.w[0] != v return false;
    for i: 1..a.w.count-1 if a.w[i] != 0 return false;
    return true;
}

ap_popcount :: (a: APInt) -> u32 { n: u32 = 0; for a.w n += cast(u32) popcount(it); return n; }
popcount :: (x: u64) -> s64 { n := 0; while x != 0 { x &= x - 1; n += 1; } return n; }
clz64 :: (x: u64) -> u32 { if x == 0 return 64; n: u32 = 0; while (x & 0x8000_0000_0000_0000) == 0 { x <<= 1; n += 1; } return n; }
ctz64 :: (x: u64) -> u32 { if x == 0 return 64; n: u32 = 0; while (x & 1) == 0 { x >>= 1; n += 1; } return n; }

// countl_zero
ap_clz :: (a: APInt) -> u32 {
    n: u32 = 0;
    i := a.w.count - 1;
    rem := a.bits % 64;
    top_unused := ifx rem == 0 then cast(u32) 0 else 64 - rem;
    while i >= 0 {
        if a.w[i] != 0 { n += clz64(a.w[i]); return n - top_unused; }
        n += 64;
        i -= 1;
    }
    return a.bits;
}
ap_ctz :: (a: APInt) -> u32 {
    n: u32 = 0;
    for a.w { if it != 0 { n += ctz64(it); return min(n, a.bits); } n += 64; }
    return a.bits;
}
ap_clo :: (a: APInt) -> u32 { return ap_clz(ap_not(a)); }
ap_cto :: (a: APInt) -> u32 { return ap_ctz(ap_not(a)); }
ap_active_bits :: (a: APInt) -> u32 { return a.bits - ap_clz(a); }
ap_num_sign_bits :: (a: APInt) -> u32 { return ifx ap_is_negative(a) then ap_clo(a) else ap_clz(a); }
ap_min_signed_bits :: (a: APInt) -> u32 { return a.bits - ap_num_sign_bits(a) + 1; }
// isMask(): a non-empty run of ones starting at bit 0 (APInt::isMask)
ap_is_mask :: (a: APInt) -> bool {
    if ap_is_zero(a) return false;
    ones := ap_cto(a);
    return ones + ap_clz(a) == a.bits;
}
ap_is_power_of_2 :: (a: APInt) -> bool { return ap_popcount(a) == 1; }
ap_bool :: (a: APInt) -> bool { return !ap_is_zero(a); }

// getLimitedValue(Limit = UINT64_MAX)
ap_limited :: (a: APInt, limit: u64 = 0xFFFF_FFFF_FFFF_FFFF) -> u64 {
    if ap_active_bits(a) > 64 return limit;
    return ifx a.w[0] > limit then limit else a.w[0];
}
ap_zext_value :: (a: APInt) -> u64 { return a.w[0]; }
ap_sext_value :: (a: APInt) -> s64 {
    if a.bits >= 64 return cast,no_check(s64) a.w[0];
    sh := cast(u64)(64 - a.bits);
    return (cast,no_check(s64)(a.w[0] << sh)) >> sh;
}

ap_not :: (a: APInt) -> APInt { r := ap_alloc(a.bits); for a.w r.w[it_index] = ~it; ap_normalize(*r); return r; }
ap_and :: (a: APInt, b: APInt) -> APInt { assert(a.bits == b.bits); r := ap_alloc(a.bits); for a.w r.w[it_index] = it & b.w[it_index]; return r; }
ap_or  :: (a: APInt, b: APInt) -> APInt { assert(a.bits == b.bits); r := ap_alloc(a.bits); for a.w r.w[it_index] = it | b.w[it_index]; return r; }
ap_xor :: (a: APInt, b: APInt) -> APInt { assert(a.bits == b.bits); r := ap_alloc(a.bits); for a.w r.w[it_index] = it ^ b.w[it_index]; return r; }
ap_intersects :: (a: APInt, b: APInt) -> bool { for a.w if (it & b.w[it_index]) != 0 return true; return false; }
ap_is_subset_of :: (a: APInt, b: APInt) -> bool { for a.w if (it & ~b.w[it_index]) != 0 return false; return true; }

ap_add :: (a: APInt, b: APInt) -> APInt {
    assert(a.bits == b.bits);
    r := ap_alloc(a.bits);
    carry: u64 = 0;
    for a.w {
        x := it; y := b.w[it_index];
        s := x + y;
        c1 := ifx s < x then cast(u64) 1 else 0;
        s2 := s + carry;
        c2 := ifx s2 < s then cast(u64) 1 else 0;
        r.w[it_index] = s2;
        carry = c1 + c2;
    }
    ap_normalize(*r);
    return r;
}
ap_add_u64 :: (a: APInt, v: u64) -> APInt { return ap_add(a, ap_from_u64(a.bits, v)); }
ap_neg :: (a: APInt) -> APInt { return ap_add_u64(ap_not(a), 1); }
ap_sub :: (a: APInt, b: APInt) -> APInt { return ap_add(a, ap_neg(b)); }
ap_mul :: (a: APInt, b: APInt) -> APInt {
    r := ap_alloc(a.bits);
    n := a.w.count;
    for i: 0..n-1 {
        carry: u64 = 0;
        for j: 0..n-1-i {
            lo, hi := mul_u64(a.w[i], b.w[j]);
            s := r.w[i + j] + lo;
            c := ifx s < lo then cast(u64) 1 else 0;
            s2 := s + carry;
            c += ifx s2 < s then cast(u64) 1 else 0;
            r.w[i + j] = s2;
            carry = hi + c;
        }
    }
    ap_normalize(*r);
    return r;
}
mul_u64 :: (a: u64, b: u64) -> (lo: u64, hi: u64) {
    a0 := a & 0xFFFF_FFFF; a1 := a >> 32; b0 := b & 0xFFFF_FFFF; b1 := b >> 32;
    p00 := a0 * b0; p01 := a0 * b1; p10 := a1 * b0; p11 := a1 * b1;
    mid := (p00 >> 32) + (p01 & 0xFFFF_FFFF) + (p10 & 0xFFFF_FFFF);
    lo := (p00 & 0xFFFF_FFFF) | (mid << 32);
    hi := p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
    return lo, hi;
}

ap_shl :: (a: APInt, s: u32) -> APInt {
    r := ap_alloc(a.bits);
    if s >= a.bits return r;
    ws := cast(s64)(s / 64); bs := cast(u64)(s % 64);
    i := r.w.count - 1;
    while i >= ws {
        v := a.w[i - ws] << bs;
        if bs != 0 && i - ws - 1 >= 0 v |= a.w[i - ws - 1] >> (64 - bs);
        r.w[i] = v;
        i -= 1;
    }
    ap_normalize(*r);
    return r;
}
ap_lshr :: (a: APInt, s: u32) -> APInt {
    r := ap_alloc(a.bits);
    if s >= a.bits return r;
    ws := cast(s64)(s / 64); bs := cast(u64)(s % 64);
    for i: 0..r.w.count-1-ws {
        v := a.w[i + ws] >> bs;
        if bs != 0 && i + ws + 1 < a.w.count v |= a.w[i + ws + 1] << (64 - bs);
        r.w[i] = v;
    }
    return r;
}
ap_ashr :: (a: APInt, s: u32) -> APInt {
    if !ap_is_negative(a) return ap_lshr(a, s);
    if s >= a.bits return ap_all_ones(a.bits);
    r := ap_lshr(a, s);
    ap_set_bits(*r, a.bits - s, a.bits);
    return r;
}

ap_zext :: (a: APInt, bits: u32) -> APInt { assert(bits >= a.bits); return ap_from_words(bits, a.w); }
ap_trunc :: (a: APInt, bits: u32) -> APInt { assert(bits <= a.bits); return ap_from_words(bits, a.w); }
ap_sext :: (a: APInt, bits: u32) -> APInt {
    r := ap_from_words(bits, a.w);
    if ap_is_negative(a) ap_set_bits(*r, a.bits, bits);
    return r;
}
ap_zext_or_trunc :: (a: APInt, bits: u32) -> APInt { if bits >= a.bits return ap_zext(a, bits); return ap_trunc(a, bits); }
ap_sext_or_trunc :: (a: APInt, bits: u32) -> APInt { if bits >= a.bits return ap_sext(a, bits); return ap_trunc(a, bits); }

ap_reverse_bits :: (a: APInt) -> APInt {
    r := ap_alloc(a.bits);
    for i: 0..a.bits-1 if ap_get_bit(a, i) ap_set_bit(*r, a.bits - 1 - i);
    return r;
}
ap_byte_swap :: (a: APInt) -> APInt {
    assert(a.bits % 16 == 0, "byteSwap needs a multiple of 16 bits");
    r := ap_alloc(a.bits);
    nb := a.bits / 8;
    for i: 0..nb-1 {
        byte := (a.w[i / 8] >> cast(u64)((i % 8) * 8)) & 0xFF;
        j := nb - 1 - i;
        r.w[j / 8] |= byte << cast(u64)((j % 8) * 8);
    }
    return r;
}

ap_ult :: (a: APInt, b: APInt) -> bool {
    i := a.w.count - 1;
    while i >= 0 { if a.w[i] != b.w[i] return a.w[i] < b.w[i]; i -= 1; }
    return false;
}
ap_ule :: (a: APInt, b: APInt) -> bool { return !ap_ult(b, a); }
ap_ugt :: (a: APInt, b: APInt) -> bool { return ap_ult(b, a); }
ap_slt :: (a: APInt, b: APInt) -> bool {
    na := ap_is_negative(a); nb := ap_is_negative(b);
    if na != nb return na;
    return ap_ult(a, b);
}
ap_umin :: (a: APInt, b: APInt) -> APInt { return ifx ap_ult(a, b) then a else b; }
ap_umax :: (a: APInt, b: APInt) -> APInt { return ifx ap_ult(a, b) then b else a; }

// urem by a small value (used for shift amounts modulo the bit width)
ap_urem_u64 :: (a: APInt, d: u64) -> u64 {
    rem: u64 = 0;
    i := a.w.count - 1;
    while i >= 0 {
        // (rem * 2^64 + w) % d, bit by bit
        x := a.w[i];
        for b: 0..63 {
            bit := (x >> cast(u64)(63 - b)) & 1;
            hi := rem >> 63;
            rem = (rem << 1) | bit;
            if hi != 0 || rem >= d rem -= d;
        }
        i -= 1;
    }
    return rem;
}

// Twine::utohexstr (lower case, no leading zeros)
u64_to_hex :: (x: u64) -> string {
    if x == 0 return "0";
    HEX :: "0123456789abcdef";
    buf: [16] u8; n := 0;
    while x != 0 { buf[n] = HEX[x & 15]; x >>= 4; n += 1; }
    s := alloc_string(n);
    for i: 0..n-1 s[i] = buf[n - 1 - i];
    return s;
}

// ---------------------------------------------------------------- KnownBits (llvm/Support/KnownBits.h, lib/Support/KnownBits.cpp)

Known_Bits :: struct {
    zero: APInt;
    one: APInt;
}

kb_new :: (bits: u32) -> Known_Bits { k: Known_Bits; k.zero = ap_zero(bits); k.one = ap_zero(bits); return k; }
kb_bits :: inline (k: Known_Bits) -> u32 { return k.zero.bits; }
kb_from_const :: (c: APInt) -> Known_Bits { k: Known_Bits; k.one = ap_copy(c); k.zero = ap_not(c); return k; }
kb_is_constant :: (k: Known_Bits) -> bool { return ap_popcount(k.zero) + ap_popcount(k.one) == kb_bits(k); }
kb_has_conflict :: (k: Known_Bits) -> bool { return ap_intersects(k.zero, k.one); }
kb_is_unknown :: (k: Known_Bits) -> bool { return ap_is_zero(k.zero) && ap_is_zero(k.one); }
kb_min_value :: (k: Known_Bits) -> APInt { return k.one; }
kb_max_value :: (k: Known_Bits) -> APInt { return ap_not(k.zero); }
kb_count_max_leading_zeros :: (k: Known_Bits) -> u32 { return ap_clz(k.one); }
kb_count_max_trailing_zeros :: (k: Known_Bits) -> u32 { return ap_ctz(k.one); }
kb_count_min_leading_zeros :: (k: Known_Bits) -> u32 { return ap_clo(k.zero); }
kb_count_min_trailing_zeros :: (k: Known_Bits) -> u32 { return ap_cto(k.zero); }
kb_count_min_leading_ones :: (k: Known_Bits) -> u32 { return ap_clo(k.one); }
kb_count_min_sign_bits :: (k: Known_Bits) -> u32 {
    if ap_is_negative(k.one) return ap_clo(k.one);
    if ap_is_negative(k.zero) return ap_clo(k.zero);
    return 1;
}
kb_is_non_negative :: (k: Known_Bits) -> bool { return ap_is_negative(k.zero); }
kb_is_negative :: (k: Known_Bits) -> bool { return ap_is_negative(k.one); }
kb_is_non_zero :: (k: Known_Bits) -> bool { return !ap_is_zero(k.one); }
kb_is_zero :: (k: Known_Bits) -> bool { return ap_is_all_ones(k.zero); }
kb_and :: (a: Known_Bits, b: Known_Bits) -> Known_Bits { r: Known_Bits; r.zero = ap_or(a.zero, b.zero); r.one = ap_and(a.one, b.one); return r; }
kb_or  :: (a: Known_Bits, b: Known_Bits) -> Known_Bits { r: Known_Bits; r.zero = ap_and(a.zero, b.zero); r.one = ap_or(a.one, b.one); return r; }
kb_xor :: (a: Known_Bits, b: Known_Bits) -> Known_Bits {
    r: Known_Bits;
    r.zero = ap_or(ap_and(a.zero, b.zero), ap_and(a.one, b.one));
    r.one = ap_or(ap_and(a.zero, b.one), ap_and(a.one, b.zero));
    return r;
}
// intersectWith: bits known in both
kb_intersect :: (a: Known_Bits, b: Known_Bits) -> Known_Bits { r: Known_Bits; r.zero = ap_and(a.zero, b.zero); r.one = ap_and(a.one, b.one); return r; }
// unionWith
kb_union :: (a: Known_Bits, b: Known_Bits) -> Known_Bits { r: Known_Bits; r.zero = ap_or(a.zero, b.zero); r.one = ap_or(a.one, b.one); return r; }
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
kb_make_non_negative :: (k: *Known_Bits) { ap_set_sign_bit(*k.zero); }
kb_make_negative :: (k: *Known_Bits) { ap_set_sign_bit(*k.one); }

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

ap_uadd_sat :: (a: APInt, b: APInt) -> APInt { s := ap_add(a, b); if ap_ult(s, a) return ap_all_ones(a.bits); return s; }
ap_usub_sat :: (a: APInt, b: APInt) -> APInt { if ap_ult(a, b) return ap_zero(a.bits); return ap_sub(a, b); }
ap_sadd_sat :: (a: APInt, b: APInt) -> APInt {
    s := ap_add(a, b);
    na := ap_is_negative(a); nb := ap_is_negative(b);
    if na == nb && ap_is_negative(s) != na return ifx na then ap_signed_min(a.bits) else ap_signed_max(a.bits);
    return s;
}
ap_ssub_sat :: (a: APInt, b: APInt) -> APInt {
    s := ap_sub(a, b);
    na := ap_is_negative(a); nb := ap_is_negative(b);
    if na != nb && ap_is_negative(s) != na return ifx na then ap_signed_min(a.bits) else ap_signed_max(a.bits);
    return s;
}
kb_signed_min_value :: (k: Known_Bits) -> APInt {
    // getSignedMinValue: if sign bit unknown, it is set
    r := ap_copy(k.one);
    if !ap_is_negative(k.zero) ap_set_sign_bit(*r);
    return r;
}
kb_signed_max_value :: (k: Known_Bits) -> APInt {
    r := ap_not(k.zero);
    if !ap_is_negative(k.one) ap_clear_bit(*r, r.bits - 1);
    return r;
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
    if kb_has_conflict(known_out) { known_out.zero = ap_all_ones(bits); known_out.one = ap_zero(bits); }
    return known_out;
}

#import "Basic";
