// Arbitrary-width integers for passes and analyses: a port of the parts of llvm/include/llvm/ADT/APInt.h
// (llvm/lib/Support/APInt.cpp) that passes need. KnownBits is in knownbits.jai, ConstantRange in
// constant_range.jai.
//
// An APInt is a value: `bits`, and either `v` (bits <= 64: the value, normalized) or `w` (bits > 64:
// little-endian words, normalized, allocated from `temp`). Small values never allocate; every op has a 64-bit
// fast path. Use ap_word/ap_set_word when writing width-generic code; `ap_words` gives a slice for either form.
// Results that must outlive a pass are copied with ap_heap_copy.

APInt :: struct {
    bits: u32;
    v: u64;       // bits <= 64
    w: [] u64;    // bits > 64
}

ap_small :: inline (a: APInt) -> bool { return a.bits <= 64; }
ap_nwords :: inline (bits: u32) -> s64 { return cast(s64)((bits + 63) / 64); }
ap_mask64 :: inline (bits: u32) -> u64 { if bits >= 64 return 0xFFFF_FFFF_FFFF_FFFF; return ((cast(u64) 1) << bits) - 1; }

ap_word :: inline (a: APInt, i: s64) -> u64 { if a.bits <= 64 return ifx i == 0 then a.v else 0; return a.w[i]; }
ap_set_word :: inline (a: *APInt, i: s64, x: u64) { if a.bits <= 64 a.v = x; else a.w[i] = x; }

ap_alloc :: inline (bits: u32) -> APInt {
    r: APInt;
    r.bits = bits;
    if bits > 64 r.w = ap_alloc_words(bits);
    return r;
}
ap_alloc_words :: (bits: u32) -> [] u64 { return NewArray(ap_nwords(bits), u64,, allocator = temp); }   // zeroed

ap_normalize :: (a: *APInt) {
    if a.bits <= 64 { a.v &= ap_mask64(a.bits); return; }
    rem := a.bits % 64;
    if rem != 0 a.w[a.w.count - 1] &= ((cast(u64) 1) << cast(u64) rem) - 1;
}

// The words as a slice (temp copy for small values); for passing to const_int_words etc.
ap_words :: (a: APInt) -> [] u64 {
    if a.bits > 64 return a.w;
    r := NewArray(1, u64,, allocator = temp);
    r[0] = a.v;
    return r;
}

ap_heap_copy :: (a: APInt) -> APInt {
    r: APInt;
    r.bits = a.bits; r.v = a.v;
    if a.bits > 64 {
        r.w = NewArray(a.w.count, u64,, allocator = context.default_allocator);
        for a.w r.w[it_index] = it;
    }
    return r;
}
// Overwrite a (same width) in place, keeping its storage.
ap_assign :: (dst: *APInt, a: APInt) {
    assert(dst.bits == a.bits);
    if a.bits <= 64 { dst.v = a.v; return; }
    for a.w dst.w[it_index] = it;
}

ap_zero :: inline (bits: u32) -> APInt { return ap_alloc(bits); }
ap_from_u64 :: (bits: u32, v: u64) -> APInt {
    r := ap_alloc(bits);
    ap_set_word(*r, 0, v);
    ap_normalize(*r);
    return r;
}
ap_from_s64 :: (bits: u32, v: s64) -> APInt {
    r := ap_alloc(bits);
    if bits <= 64 { r.v = cast,no_check(u64) v; ap_normalize(*r); return r; }
    for i: 0..r.w.count-1 r.w[i] = ifx v < 0 then cast(u64) 0xFFFF_FFFF_FFFF_FFFF else 0;
    r.w[0] = cast,no_check(u64) v;
    ap_normalize(*r);
    return r;
}
ap_from_words :: (bits: u32, words: [] u64) -> APInt {
    r := ap_alloc(bits);
    if bits <= 64 { if words.count > 0 r.v = words[0]; ap_normalize(*r); return r; }
    for i: 0..min(r.w.count, words.count)-1 r.w[i] = words[i];
    ap_normalize(*r);
    return r;
}
ap_copy :: (a: APInt) -> APInt {
    if a.bits <= 64 return a;
    return ap_from_words(a.bits, a.w);
}
ap_all_ones :: (bits: u32) -> APInt {
    r := ap_alloc(bits);
    if bits <= 64 { r.v = ap_mask64(bits); return r; }
    for i: 0..r.w.count-1 r.w[i] = 0xFFFF_FFFF_FFFF_FFFF;
    ap_normalize(*r);
    return r;
}

ap_get_bit :: inline (a: APInt, i: u32) -> bool {
    if a.bits <= 64 return ((a.v >> cast(u64) i) & 1) != 0;
    return ((a.w[i / 64] >> cast(u64)(i % 64)) & 1) != 0;
}
ap_set_bit :: inline (a: *APInt, i: u32) {
    if a.bits <= 64 { a.v |= (cast(u64) 1) << cast(u64) i; return; }
    a.w[i / 64] |= (cast(u64) 1) << cast(u64)(i % 64);
}
ap_clear_bit :: inline (a: *APInt, i: u32) {
    if a.bits <= 64 { a.v &= ~((cast(u64) 1) << cast(u64) i); return; }
    a.w[i / 64] &= ~((cast(u64) 1) << cast(u64)(i % 64));
}
ap_set_bit_val :: (a: *APInt, i: u32, b: bool) { if b ap_set_bit(a, i); else ap_clear_bit(a, i); }
ap_set_sign_bit :: (a: *APInt) { ap_set_bit(a, a.bits - 1); }
ap_clear_sign_bit :: (a: *APInt) { ap_clear_bit(a, a.bits - 1); }
ap_is_negative :: inline (a: APInt) -> bool { return ap_get_bit(a, a.bits - 1); }
ap_is_non_negative :: inline (a: APInt) -> bool { return !ap_is_negative(a); }
ap_is_strictly_positive :: (a: APInt) -> bool { return !ap_is_negative(a) && !ap_is_zero(a); }
ap_is_non_positive :: (a: APInt) -> bool { return ap_is_negative(a) || ap_is_zero(a); }
ap_sign_bit :: (a: APInt) -> bool { return ap_is_negative(a); }

// [lo, hi) set
ap_set_bits :: (a: *APInt, lo: u32, hi: u32) {
    if lo >= hi return;
    if a.bits <= 64 {
        m := ap_mask64(hi - lo) << cast(u64) lo;
        a.v |= m;
        return;
    }
    i := lo; while i < hi { ap_set_bit(a, i); i += 1; }
}
ap_clear_bits_range :: (a: *APInt, lo: u32, hi: u32) { i := lo; while i < hi { ap_clear_bit(a, i); i += 1; } }
ap_set_low_bits :: (a: *APInt, n: u32) { ap_set_bits(a, 0, min(n, a.bits)); }
ap_set_high_bits :: (a: *APInt, n: u32) { n = min(n, a.bits); ap_set_bits(a, a.bits - n, a.bits); }
ap_set_bits_from :: (a: *APInt, lo: u32) { ap_set_bits(a, lo, a.bits); }
ap_clear_low_bits :: (a: *APInt, n: u32) { ap_clear_bits_range(a, 0, min(n, a.bits)); }
ap_clear_high_bits :: (a: *APInt, n: u32) { n = min(n, a.bits); ap_clear_bits_range(a, a.bits - n, a.bits); }
ap_low_bits_set :: (bits: u32, n: u32) -> APInt { r := ap_alloc(bits); ap_set_bits(*r, 0, min(n, bits)); return r; }
ap_high_bits_set :: (bits: u32, n: u32) -> APInt { r := ap_alloc(bits); n = min(n, bits); ap_set_bits(*r, bits - n, bits); return r; }
ap_bits_set_from :: (bits: u32, lo: u32) -> APInt { r := ap_alloc(bits); ap_set_bits(*r, lo, bits); return r; }
ap_bits_set :: (bits: u32, lo: u32, hi: u32) -> APInt { r := ap_alloc(bits); ap_set_bits(*r, lo, hi); return r; }
ap_one_bit_set :: (bits: u32, i: u32) -> APInt { r := ap_alloc(bits); ap_set_bit(*r, i); return r; }
ap_signed_min :: (bits: u32) -> APInt { return ap_one_bit_set(bits, bits - 1); }
ap_signed_max :: (bits: u32) -> APInt { r := ap_all_ones(bits); ap_clear_bit(*r, bits - 1); return r; }
ap_one :: (bits: u32) -> APInt { return ap_from_u64(bits, 1); }

ap_is_zero :: inline (a: APInt) -> bool { if a.bits <= 64 return a.v == 0; for a.w if it != 0 return false; return true; }
ap_is_all_ones :: (a: APInt) -> bool {
    if a.bits <= 64 return a.v == ap_mask64(a.bits);
    return ap_popcount(a) == a.bits;
}
ap_is_one :: (a: APInt) -> bool {
    if a.bits <= 64 return a.v == 1;
    if a.w[0] != 1 return false;
    for i: 1..a.w.count-1 if a.w[i] != 0 return false;
    return true;
}
ap_is_min_signed :: (a: APInt) -> bool { return ap_is_negative(a) && ap_popcount(a) == 1; }
ap_is_max_signed :: (a: APInt) -> bool { return !ap_is_negative(a) && ap_popcount(a) == a.bits - 1; }
ap_is_min_value :: (a: APInt) -> bool { return ap_is_zero(a); }
ap_is_max_value :: (a: APInt) -> bool { return ap_is_all_ones(a); }
ap_is_sign_mask :: (a: APInt) -> bool { return ap_is_min_signed(a); }
ap_eq :: (a: APInt, b: APInt) -> bool {
    assert(a.bits == b.bits);
    if a.bits <= 64 return a.v == b.v;
    for a.w if it != b.w[it_index] return false;
    return true;
}
ap_ne :: (a: APInt, b: APInt) -> bool { return !ap_eq(a, b); }
ap_eq_u64 :: (a: APInt, v: u64) -> bool {
    if a.bits <= 64 return a.v == v;
    if a.w[0] != v return false;
    for i: 1..a.w.count-1 if a.w[i] != 0 return false;
    return true;
}
// APInt == int64 (sign-extended to the width)
ap_eq_s64 :: (a: APInt, v: s64) -> bool { return ap_eq(a, ap_from_s64(a.bits, v)); }

popcount :: (x: u64) -> s64 {
    x = x - ((x >> 1) & 0x5555_5555_5555_5555);
    x = (x & 0x3333_3333_3333_3333) + ((x >> 2) & 0x3333_3333_3333_3333);
    x = (x + (x >> 4)) & 0x0F0F_0F0F_0F0F_0F0F;
    return cast(s64)((x * 0x0101_0101_0101_0101) >> 56);
}
clz64 :: (x: u64) -> u32 {
    if x == 0 return 64;
    n: u32 = 0;
    if (x & 0xFFFF_FFFF_0000_0000) == 0 { n += 32; x <<= 32; }
    if (x & 0xFFFF_0000_0000_0000) == 0 { n += 16; x <<= 16; }
    if (x & 0xFF00_0000_0000_0000) == 0 { n += 8; x <<= 8; }
    if (x & 0xF000_0000_0000_0000) == 0 { n += 4; x <<= 4; }
    if (x & 0xC000_0000_0000_0000) == 0 { n += 2; x <<= 2; }
    if (x & 0x8000_0000_0000_0000) == 0 { n += 1; }
    return n;
}
ctz64 :: (x: u64) -> u32 {
    if x == 0 return 64;
    n: u32 = 0;
    if (x & 0xFFFF_FFFF) == 0 { n += 32; x >>= 32; }
    if (x & 0xFFFF) == 0 { n += 16; x >>= 16; }
    if (x & 0xFF) == 0 { n += 8; x >>= 8; }
    if (x & 0xF) == 0 { n += 4; x >>= 4; }
    if (x & 0x3) == 0 { n += 2; x >>= 2; }
    if (x & 0x1) == 0 { n += 1; }
    return n;
}

ap_popcount :: (a: APInt) -> u32 {
    if a.bits <= 64 return cast(u32) popcount(a.v);
    n: u32 = 0; for a.w n += cast(u32) popcount(it); return n;
}

// countl_zero
ap_clz :: (a: APInt) -> u32 {
    if a.bits <= 64 {
        if a.bits == 0 return 0;
        return clz64(a.v) - (64 - a.bits);
    }
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
    if a.bits <= 64 return min(ctz64(a.v), a.bits);
    n: u32 = 0;
    for a.w { if it != 0 { n += ctz64(it); return min(n, a.bits); } n += 64; }
    return a.bits;
}
ap_clo :: (a: APInt) -> u32 {
    if a.bits <= 64 {
        if a.bits == 0 return 0;
        return clz64(~(a.v << cast(u64)(64 - a.bits)));
    }
    return ap_clz(ap_not(a));
}
ap_cto :: (a: APInt) -> u32 {
    if a.bits <= 64 return min(ctz64(~a.v), a.bits);
    return ap_ctz(ap_not(a));
}
ap_active_bits :: (a: APInt) -> u32 { return a.bits - ap_clz(a); }
ap_num_sign_bits :: (a: APInt) -> u32 { return ifx ap_is_negative(a) then ap_clo(a) else ap_clz(a); }
ap_min_signed_bits :: (a: APInt) -> u32 { return a.bits - ap_num_sign_bits(a) + 1; }
ap_significant_bits :: (a: APInt) -> u32 { return ap_min_signed_bits(a); }
// isMask(): a non-empty run of ones starting at bit 0 (APInt::isMask)
ap_is_mask :: (a: APInt) -> bool {
    if ap_is_zero(a) return false;
    ones := ap_cto(a);
    return ones + ap_clz(a) == a.bits;
}
// isMask(numBits)
ap_is_mask_n :: (a: APInt, n: u32) -> bool { return ap_eq(a, ap_low_bits_set(a.bits, n)); }
// isShiftedMask: a non-empty contiguous run of ones
ap_is_shifted_mask :: (a: APInt) -> bool {
    if ap_is_zero(a) return false;
    return ap_popcount(a) + ap_ctz(a) + ap_clz(a) == a.bits;
}
ap_is_power_of_2 :: (a: APInt) -> bool {
    if a.bits <= 64 return a.v != 0 && (a.v & (a.v - 1)) == 0;
    return ap_popcount(a) == 1;
}
ap_is_negated_power_of_2 :: (a: APInt) -> bool {
    // isNegatedPowerOf2: -x is a power of two (and x != 0); includes the signed min value
    if ap_is_zero(a) return false;
    lo := ap_ctz(a);
    return ap_clo(a) + lo == a.bits;
}
ap_log2 :: (a: APInt) -> u32 { return a.bits - 1 - ap_clz(a); }   // logBase2 (UINT_MAX-ish for 0: callers check)
ap_exact_log2 :: (a: APInt) -> s32 { if !ap_is_power_of_2(a) return -1; return cast(s32) ap_ctz(a); }
ap_bool :: (a: APInt) -> bool { return !ap_is_zero(a); }

// getLimitedValue(Limit = UINT64_MAX)
ap_limited :: (a: APInt, limit: u64 = 0xFFFF_FFFF_FFFF_FFFF) -> u64 {
    if a.bits <= 64 return ifx a.v > limit then limit else a.v;
    if ap_active_bits(a) > 64 return limit;
    return ifx a.w[0] > limit then limit else a.w[0];
}
ap_zext_value :: (a: APInt) -> u64 { return ap_word(a, 0); }
ap_sext_value :: (a: APInt) -> s64 {
    x := ap_word(a, 0);
    if a.bits >= 64 return cast,no_check(s64) x;
    sh := cast(u64)(64 - a.bits);
    return (cast,no_check(s64)(x << sh)) >> sh;
}
// tryZExtValue / tryZExtValue fits
ap_fits_u64 :: (a: APInt) -> bool { return ap_active_bits(a) <= 64; }
ap_fits_s64 :: (a: APInt) -> bool { return ap_min_signed_bits(a) <= 64; }
// ult(uint64_t RHS)
ap_ult_u64 :: (a: APInt, v: u64) -> bool { if !ap_fits_u64(a) return false; return ap_word(a, 0) < v; }
ap_ugt_u64 :: (a: APInt, v: u64) -> bool { if !ap_fits_u64(a) return true; return ap_word(a, 0) > v; }
ap_ule_u64 :: (a: APInt, v: u64) -> bool { return !ap_ugt_u64(a, v); }
ap_uge_u64 :: (a: APInt, v: u64) -> bool { return !ap_ult_u64(a, v); }
ap_slt_s64 :: (a: APInt, v: s64) -> bool { if !ap_fits_s64(a) return ap_is_negative(a); return ap_sext_value(a) < v; }
ap_sgt_s64 :: (a: APInt, v: s64) -> bool { if !ap_fits_s64(a) return !ap_is_negative(a); return ap_sext_value(a) > v; }

ap_not :: (a: APInt) -> APInt {
    if a.bits <= 64 { r := a; r.v = (~a.v) & ap_mask64(a.bits); return r; }
    r := ap_alloc(a.bits); for a.w r.w[it_index] = ~it; ap_normalize(*r); return r;
}
ap_and :: inline (a: APInt, b: APInt) -> APInt {
    assert(a.bits == b.bits);
    if a.bits <= 64 { r := a; r.v = a.v & b.v; return r; }
    r := ap_alloc(a.bits); for a.w r.w[it_index] = it & b.w[it_index]; return r;
}
ap_or :: inline (a: APInt, b: APInt) -> APInt {
    assert(a.bits == b.bits);
    if a.bits <= 64 { r := a; r.v = a.v | b.v; return r; }
    r := ap_alloc(a.bits); for a.w r.w[it_index] = it | b.w[it_index]; return r;
}
ap_xor :: (a: APInt, b: APInt) -> APInt {
    assert(a.bits == b.bits);
    if a.bits <= 64 { r := a; r.v = a.v ^ b.v; return r; }
    r := ap_alloc(a.bits); for a.w r.w[it_index] = it ^ b.w[it_index]; return r;
}
ap_intersects :: (a: APInt, b: APInt) -> bool {
    if a.bits <= 64 return (a.v & b.v) != 0;
    for a.w if (it & b.w[it_index]) != 0 return true; return false;
}
ap_is_subset_of :: (a: APInt, b: APInt) -> bool {
    if a.bits <= 64 return (a.v & ~b.v) == 0;
    for a.w if (it & ~b.w[it_index]) != 0 return false; return true;
}

ap_add :: (a: APInt, b: APInt) -> APInt {
    assert(a.bits == b.bits);
    if a.bits <= 64 { r := a; r.v = (a.v + b.v) & ap_mask64(a.bits); return r; }
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
ap_sub_u64 :: (a: APInt, v: u64) -> APInt { return ap_sub(a, ap_from_u64(a.bits, v)); }
ap_neg :: (a: APInt) -> APInt {
    if a.bits <= 64 { r := a; r.v = (0 - a.v) & ap_mask64(a.bits); return r; }
    return ap_add_u64(ap_not(a), 1);
}
ap_sub :: (a: APInt, b: APInt) -> APInt {
    assert(a.bits == b.bits);
    if a.bits <= 64 { r := a; r.v = (a.v - b.v) & ap_mask64(a.bits); return r; }
    return ap_add(a, ap_neg(b));
}
ap_mul :: (a: APInt, b: APInt) -> APInt {
    assert(a.bits == b.bits);
    if a.bits <= 64 { r := a; r.v = (a.v * b.v) & ap_mask64(a.bits); return r; }
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
    if a.bits <= 64 { r := a; if s >= a.bits r.v = 0; else r.v = (a.v << cast(u64) s) & ap_mask64(a.bits); return r; }
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
    if a.bits <= 64 { r := a; if s >= a.bits r.v = 0; else r.v = a.v >> cast(u64) s; return r; }
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
// shifts by an APInt amount (APInt::shl(const APInt&): amount limited to the width)
ap_shl_ap :: (a: APInt, s: APInt) -> APInt { return ap_shl(a, cast(u32) ap_limited(s, a.bits)); }
ap_lshr_ap :: (a: APInt, s: APInt) -> APInt { return ap_lshr(a, cast(u32) ap_limited(s, a.bits)); }
ap_ashr_ap :: (a: APInt, s: APInt) -> APInt { return ap_ashr(a, cast(u32) ap_limited(s, a.bits)); }
ap_rotl :: (a: APInt, s: u32) -> APInt {
    if a.bits == 0 return a;
    s = s % a.bits;
    if s == 0 return a;
    return ap_or(ap_shl(a, s), ap_lshr(a, a.bits - s));
}
ap_rotr :: (a: APInt, s: u32) -> APInt {
    if a.bits == 0 return a;
    s = s % a.bits;
    if s == 0 return a;
    return ap_or(ap_lshr(a, s), ap_shl(a, a.bits - s));
}

ap_zext :: (a: APInt, bits: u32) -> APInt {
    assert(bits >= a.bits);
    if bits <= 64 { r := a; r.bits = bits; return r; }
    r := ap_alloc(bits);
    if a.bits <= 64 r.w[0] = a.v;
    else for a.w r.w[it_index] = it;
    return r;
}
ap_trunc :: (a: APInt, bits: u32) -> APInt {
    assert(bits <= a.bits);
    if bits <= 64 { r: APInt; r.bits = bits; r.v = ap_word(a, 0) & ap_mask64(bits); return r; }
    return ap_from_words(bits, a.w);
}
ap_sext :: (a: APInt, bits: u32) -> APInt {
    assert(bits >= a.bits);
    neg := ap_is_negative(a);
    r := ap_zext(a, bits);
    if neg ap_set_bits(*r, a.bits, bits);
    return r;
}
ap_zext_or_trunc :: (a: APInt, bits: u32) -> APInt { if bits >= a.bits return ap_zext(a, bits); return ap_trunc(a, bits); }
ap_sext_or_trunc :: (a: APInt, bits: u32) -> APInt { if bits >= a.bits return ap_sext(a, bits); return ap_trunc(a, bits); }
// extractBits(numBits, bitPosition)
ap_extract_bits :: (a: APInt, n: u32, pos: u32) -> APInt { return ap_trunc(ap_lshr(a, pos), n); }
// insertBits(subBits, bitPosition)
ap_insert_bits :: (a: *APInt, sub: APInt, pos: u32) {
    for i: 0..cast(s64) sub.bits - 1 ap_set_bit_val(a, pos + cast(u32) i, ap_get_bit(sub, cast(u32) i));
}
ap_get_hi_bits :: (a: APInt, n: u32) -> APInt { return ap_lshr(a, a.bits - n); }
ap_get_lo_bits :: (a: APInt, n: u32) -> APInt { return ap_and(a, ap_low_bits_set(a.bits, n)); }
// concat(NewLSB): this in the high bits
ap_concat :: (hi: APInt, lo: APInt) -> APInt {
    r := ap_zext(lo, hi.bits + lo.bits);
    return ap_or(r, ap_shl(ap_zext(hi, hi.bits + lo.bits), lo.bits));
}

ap_reverse_bits :: (a: APInt) -> APInt {
    r := ap_alloc(a.bits);
    for i: 0..cast(s64) a.bits-1 if ap_get_bit(a, cast(u32) i) ap_set_bit(*r, a.bits - 1 - cast(u32) i);
    return r;
}
ap_byte_swap :: (a: APInt) -> APInt {
    assert(a.bits % 16 == 0, "byteSwap needs a multiple of 16 bits");
    r := ap_alloc(a.bits);
    nb := a.bits / 8;
    for i: 0..nb-1 {
        byte := (ap_word(a, i / 8) >> cast(u64)((i % 8) * 8)) & 0xFF;
        j := nb - 1 - i;
        ap_set_word(*r, j / 8, ap_word(r, j / 8) | (byte << cast(u64)((j % 8) * 8)));
    }
    return r;
}

ap_ult :: (a: APInt, b: APInt) -> bool {
    assert(a.bits == b.bits);
    if a.bits <= 64 return a.v < b.v;
    i := a.w.count - 1;
    while i >= 0 { if a.w[i] != b.w[i] return a.w[i] < b.w[i]; i -= 1; }
    return false;
}
ap_ule :: (a: APInt, b: APInt) -> bool { return !ap_ult(b, a); }
ap_ugt :: (a: APInt, b: APInt) -> bool { return ap_ult(b, a); }
ap_uge :: (a: APInt, b: APInt) -> bool { return !ap_ult(a, b); }
ap_slt :: (a: APInt, b: APInt) -> bool {
    na := ap_is_negative(a); nb := ap_is_negative(b);
    if na != nb return na;
    return ap_ult(a, b);
}
ap_sle :: (a: APInt, b: APInt) -> bool { return !ap_slt(b, a); }
ap_sgt :: (a: APInt, b: APInt) -> bool { return ap_slt(b, a); }
ap_sge :: (a: APInt, b: APInt) -> bool { return !ap_slt(a, b); }
ap_umin :: (a: APInt, b: APInt) -> APInt { return ifx ap_ult(a, b) then a else b; }
ap_umax :: (a: APInt, b: APInt) -> APInt { return ifx ap_ult(a, b) then b else a; }
ap_smin :: (a: APInt, b: APInt) -> APInt { return ifx ap_slt(a, b) then a else b; }
ap_smax :: (a: APInt, b: APInt) -> APInt { return ifx ap_slt(a, b) then b else a; }
ap_abs :: (a: APInt) -> APInt { if ap_is_negative(a) return ap_neg(a); return a; }
// APInt::compare / compareSigned
ap_ucmp :: (a: APInt, b: APInt) -> s32 { if ap_ult(a, b) return -1; if ap_ult(b, a) return 1; return 0; }
ap_scmp :: (a: APInt, b: APInt) -> s32 { if ap_slt(a, b) return -1; if ap_slt(b, a) return 1; return 0; }

// urem by a small value (used for shift amounts modulo the bit width)
ap_urem_u64 :: (a: APInt, d: u64) -> u64 {
    if a.bits <= 64 return a.v % d;
    rem: u64 = 0;
    i := a.w.count - 1;
    while i >= 0 {
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

// ---------------------------------------------------------------- saturating / overflow arithmetic

ap_uadd_ov :: (a: APInt, b: APInt) -> (APInt, bool) { s := ap_add(a, b); return s, ap_ult(s, b); }
ap_usub_ov :: (a: APInt, b: APInt) -> (APInt, bool) { return ap_sub(a, b), ap_ult(a, b); }
ap_sadd_ov :: (a: APInt, b: APInt) -> (APInt, bool) {
    s := ap_add(a, b);
    na := ap_is_negative(a); nb := ap_is_negative(b);
    return s, na == nb && ap_is_negative(s) != na;
}
ap_ssub_ov :: (a: APInt, b: APInt) -> (APInt, bool) {
    s := ap_sub(a, b);
    na := ap_is_negative(a); nb := ap_is_negative(b);
    return s, na != nb && ap_is_negative(s) != na;
}
ap_umul_ov :: (a: APInt, b: APInt) -> (APInt, bool) {
    r := ap_mul(a, b);
    if ap_is_zero(a) || ap_is_zero(b) return r, false;
    // APInt::umul_ov: overflow iff the full product needs more than BitWidth bits
    w := a.bits * 2;
    full := ap_mul(ap_zext(a, w), ap_zext(b, w));
    return r, ap_active_bits(full) > a.bits;
}
ap_smul_ov :: (a: APInt, b: APInt) -> (APInt, bool) {
    r := ap_mul(a, b);
    w := a.bits * 2;
    full := ap_mul(ap_sext(a, w), ap_sext(b, w));
    return r, !ap_eq(ap_sext(r, w), full);
}
ap_sdiv_ov :: (a: APInt, b: APInt) -> (APInt, bool) {
    ov := ap_is_min_signed(a) && ap_is_all_ones(b);
    return ap_sdiv(a, b), ov;
}
ap_ushl_ov :: (a: APInt, s: APInt) -> (APInt, bool) {
    if ap_uge_u64(s, a.bits) return ap_zero(a.bits), true;
    sh := cast(u32) ap_zext_value(s);
    return ap_shl(a, sh), sh > ap_clz(a);
}
ap_sshl_ov :: (a: APInt, s: APInt) -> (APInt, bool) {
    if ap_uge_u64(s, a.bits) return ap_zero(a.bits), true;
    sh := cast(u32) ap_zext_value(s);
    ov := ifx ap_is_negative(a) then sh >= ap_clo(a) else sh >= ap_clz(a);
    return ap_shl(a, sh), ov;
}
ap_uadd_sat :: (a: APInt, b: APInt) -> APInt { s, o := ap_uadd_ov(a, b); if o return ap_all_ones(a.bits); return s; }
ap_usub_sat :: (a: APInt, b: APInt) -> APInt { if ap_ult(a, b) return ap_zero(a.bits); return ap_sub(a, b); }
ap_sadd_sat :: (a: APInt, b: APInt) -> APInt {
    s, o := ap_sadd_ov(a, b);
    if o return ifx ap_is_negative(a) then ap_signed_min(a.bits) else ap_signed_max(a.bits);
    return s;
}
ap_ssub_sat :: (a: APInt, b: APInt) -> APInt {
    s, o := ap_ssub_ov(a, b);
    if o return ifx ap_is_negative(a) then ap_signed_min(a.bits) else ap_signed_max(a.bits);
    return s;
}
ap_umul_sat :: (a: APInt, b: APInt) -> APInt { r, o := ap_umul_ov(a, b); if o return ap_all_ones(a.bits); return r; }
ap_smul_sat :: (a: APInt, b: APInt) -> APInt {
    r, o := ap_smul_ov(a, b);
    if !o return r;
    res_neg := ap_is_negative(a) != ap_is_negative(b);
    return ifx res_neg then ap_signed_min(a.bits) else ap_signed_max(a.bits);
}
ap_ushl_sat :: (a: APInt, s: APInt) -> APInt { r, o := ap_ushl_ov(a, s); if o return ap_all_ones(a.bits); return r; }
ap_sshl_sat :: (a: APInt, s: APInt) -> APInt {
    r, o := ap_sshl_ov(a, s);
    if !o return r;
    return ifx ap_is_negative(a) then ap_signed_min(a.bits) else ap_signed_max(a.bits);
}

// ---------------------------------------------------------------- division (APInt::udiv/sdiv/urem/srem)

ap_udivrem :: (a: APInt, b: APInt) -> (q: APInt, r: APInt) {
    assert(a.bits == b.bits);
    assert(!ap_is_zero(b), "APInt division by zero");
    if a.bits <= 64 {
        q := a; r := a;
        q.v = a.v / b.v; r.v = a.v % b.v;
        return q, r;
    }
    q := ap_alloc(a.bits);
    r := ap_alloc(a.bits);
    i := cast(s64) a.bits - 1;
    while i >= 0 {
        top := ap_get_bit(r, a.bits - 1);
        r = ap_shl(r, 1);
        if ap_get_bit(a, cast(u32) i) ap_set_bit(*r, 0);
        if top || !ap_ult(r, b) { r = ap_sub(r, b); ap_set_bit(*q, cast(u32) i); }
        i -= 1;
    }
    return q, r;
}
ap_udiv :: (a: APInt, b: APInt) -> APInt { q, r := ap_udivrem(a, b); return q; }
ap_urem :: (a: APInt, b: APInt) -> APInt { q, r := ap_udivrem(a, b); return r; }
// APInt::sdiv: truncates toward zero
ap_sdiv :: (a: APInt, b: APInt) -> APInt {
    na := ap_is_negative(a); nb := ap_is_negative(b);
    q := ap_udiv(ifx na then ap_neg(a) else a, ifx nb then ap_neg(b) else b);
    if na != nb return ap_neg(q);
    return q;
}
// APInt::srem: the result has the sign of the dividend
ap_srem :: (a: APInt, b: APInt) -> APInt {
    na := ap_is_negative(a); nb := ap_is_negative(b);
    r := ap_urem(ifx na then ap_neg(a) else a, ifx nb then ap_neg(b) else b);
    if na return ap_neg(r);
    return r;
}
Rounding :: enum u8 { DOWN; TOWARD_ZERO; UP; }
// APIntOps::RoundingUDiv
ap_rounding_udiv :: (a: APInt, b: APInt, rm: Rounding) -> APInt {
    if rm == .DOWN || rm == .TOWARD_ZERO return ap_udiv(a, b);
    q, r := ap_udivrem(a, b);
    if ap_is_zero(r) return q;
    return ap_add_u64(q, 1);
}
// APIntOps::RoundingSDiv
ap_rounding_sdiv :: (a: APInt, b: APInt, rm: Rounding) -> APInt {
    q := ap_sdiv(a, b); r := ap_srem(a, b);
    if ap_is_zero(r) || rm == .TOWARD_ZERO return q;
    // signed rounding: the true quotient is q + fraction with sign of a*b
    pos := ap_is_negative(a) == ap_is_negative(b);
    if rm == .UP { if pos return ap_add_u64(q, 1); return q; }
    if pos return q;
    return ap_sub_u64(q, 1);
}
// APIntOps::GreatestCommonDivisor
ap_gcd :: (a_in: APInt, b_in: APInt) -> APInt {
    a := a_in; b := b_in;
    while !ap_is_zero(b) { t := ap_urem(a, b); a = b; b = t; }
    return a;
}
// APIntOps::mulhs / mulhu
ap_mulhu :: (a: APInt, b: APInt) -> APInt { w := a.bits * 2; return ap_extract_bits(ap_mul(ap_zext(a, w), ap_zext(b, w)), a.bits, a.bits); }
ap_mulhs :: (a: APInt, b: APInt) -> APInt { w := a.bits * 2; return ap_extract_bits(ap_mul(ap_sext(a, w), ap_sext(b, w)), a.bits, a.bits); }
// APIntOps::avgFloorU etc.
ap_avg_floor_u :: (a: APInt, b: APInt) -> APInt { return ap_add(ap_and(a, b), ap_lshr(ap_xor(a, b), 1)); }
ap_avg_floor_s :: (a: APInt, b: APInt) -> APInt { return ap_add(ap_and(a, b), ap_ashr(ap_xor(a, b), 1)); }
ap_avg_ceil_u :: (a: APInt, b: APInt) -> APInt { return ap_sub(ap_or(a, b), ap_lshr(ap_xor(a, b), 1)); }
ap_avg_ceil_s :: (a: APInt, b: APInt) -> APInt { return ap_sub(ap_or(a, b), ap_ashr(ap_xor(a, b), 1)); }
ap_abds :: (a: APInt, b: APInt) -> APInt { if ap_sge(a, b) return ap_sub(a, b); return ap_sub(b, a); }
ap_abdu :: (a: APInt, b: APInt) -> APInt { if ap_uge(a, b) return ap_sub(a, b); return ap_sub(b, a); }
// APInt::sqrt (floor), bit by bit
ap_sqrt :: (a: APInt) -> APInt {
    r := ap_zero(a.bits);
    i := cast(s64) a.bits - 1;
    // naive: binary search
    lo := ap_zero(a.bits + 2); hi := ap_add_u64(ap_zext(a, a.bits + 2), 1);
    aa := ap_zext(a, a.bits + 2);
    w := (a.bits + 2) * 2;
    while ap_ult(ap_add_u64(lo, 1), hi) {
        mid := ap_lshr(ap_add(lo, hi), 1);
        sq := ap_mul(ap_zext(mid, w), ap_zext(mid, w));
        if ap_ule(sq, ap_zext(aa, w)) lo = mid; else hi = mid;
    }
    return ap_trunc(lo, a.bits);
}

// APInt::toString radix 10
ap_to_string_unsigned :: (a: APInt) -> string { return apint_to_unsigned_decimal(ap_words(a)); }
ap_to_string_signed :: (a: APInt) -> string { return apint_to_signed_decimal(ap_words(a), a.bits); }

// (Basic: imported once, in ir.jai)
