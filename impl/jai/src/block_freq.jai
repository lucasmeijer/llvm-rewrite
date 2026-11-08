// BlockFrequencyInfo: a port of llvm/include/llvm/Analysis/BlockFrequencyInfoImpl.h and
// llvm/lib/Analysis/BlockFrequencyInfoImpl.cpp (mass distribution with loop packaging, irreducible control flow via
// IrreducibleGraph SCCs, loop scales, conversion to integers), llvm/lib/Analysis/BlockFrequencyInfo.cpp
// (print<block-freq>, setBlockFreq for blocks created later) and llvm/include/llvm/Support/ScaledNumber.h +
// llvm/lib/Support/ScaledNumber.cpp (ScaledNumber<uint64_t> arithmetic and toString).
//
// The result is `*Bfi` (heap, Fn_Analyses.bfi, get_bfi(f)): frequencies keyed by block. The iterative inference
// (-use-iterative-bfi-inference, off by default) is not ported.

// ---------------------------------------------------------------- ScaledNumber<uint64_t>

SN_MAX_SCALE :: 16383;
SN_MIN_SCALE :: -16382;

Scaled64 :: struct { digits: u64; scale: s16; }

sn_zero :: () -> Scaled64 { return .{0, 0}; }
sn_one :: () -> Scaled64 { return .{1, 0}; }
sn_largest :: () -> Scaled64 { return .{0xFFFF_FFFF_FFFF_FFFF, SN_MAX_SCALE}; }

sn_clz :: (x: u64) -> s32 { return cast(s32) clz64(x); }   // clz64 / ctz64 are in apint.jai
sn_ctz :: (x: u64) -> s32 { return cast(s32) ctz64(x); }

// getRounded
sn_get_rounded :: (digits_in: u64, scale: s32, should_round: bool) -> (u64, s32) {
    digits := digits_in;
    if should_round {
        digits += 1;
        if digits == 0 return (cast(u64) 1) << 63, scale + 1;
    }
    return digits, scale;
}
// multiply64
sn_multiply64 :: (lhs: u64, rhs: u64) -> (u64, s32) {
    ul := lhs >> 32; ll := lhs & 0xFFFF_FFFF; ur := rhs >> 32; lr := rhs & 0xFFFF_FFFF;
    p1 := ul * ur; p2 := ul * lr; p3 := ll * ur; p4 := ll * lr;
    upper := p1; lower := p4;
    add_with_carry :: (n: u64, upper: *u64, lower: *u64) {
        new_lower := lower.* + ((n & 0xFFFF_FFFF) << 32);
        upper.* += (n >> 32) + ifx new_lower < lower.* then cast(u64) 1 else 0;
        lower.* = new_lower;
    }
    add_with_carry(p2, *upper, *lower);
    add_with_carry(p3, *upper, *lower);
    if upper == 0 return lower, 0;
    lz := sn_clz(upper);
    shift := 64 - lz;
    if lz upper = (upper << cast(u64) lz) | (lower >> cast(u64) shift);
    d, s := sn_get_rounded(upper, shift, shift != 0 && (lower & ((cast(u64) 1) << cast(u64) (shift - 1))) != 0);
    return d, s;
}
sn_get_half :: (n: u64) -> u64 { return (n >> 1) + (n & 1); }
// divide64
sn_divide64 :: (dividend_in: u64, divisor_in: u64) -> (u64, s32) {
    dividend := dividend_in; divisor := divisor_in;
    shift: s32 = 0;
    z := sn_ctz(divisor);
    if z { shift -= z; divisor >>= cast(u64) z; }
    if divisor == 1 return dividend, shift;
    z = sn_clz(dividend);
    if z { shift -= z; dividend <<= cast(u64) z; }
    quotient := dividend / divisor;
    dividend %= divisor;
    while (quotient >> 63) == 0 && dividend != 0 {
        is_overflow := (dividend >> 63) != 0;
        dividend <<= 1;
        shift -= 1;
        quotient <<= 1;
        if is_overflow || divisor <= dividend { quotient |= 1; dividend -= divisor; }
    }
    d, s := sn_get_rounded(quotient, shift, dividend >= sn_get_half(divisor));
    return d, s;
}
// getQuotient
sn_get_quotient :: (dividend: u64, divisor: u64) -> Scaled64 {
    if dividend == 0 return .{0, 0};
    if divisor == 0 return .{0xFFFF_FFFF_FFFF_FFFF, SN_MAX_SCALE};
    d, s := sn_divide64(dividend, divisor);
    return .{d, cast(s16) s};
}
sn_get_fraction :: (n: u64, d: u64) -> Scaled64 { return sn_get_quotient(n, d); }
// getLgImpl / getLgFloor
sn_lg_floor :: (digits: u64, scale: s32) -> s32 {
    if digits == 0 return -2147483647 - 1;
    local_floor := 63 - sn_clz(digits);
    floor := scale + local_floor;
    if digits == (cast(u64) 1) << cast(u64) local_floor return floor;
    round := (digits & ((cast(u64) 1) << cast(u64) (local_floor - 1))) != 0;
    lg := floor + ifx round then cast(s32) 1 else 0;
    second: s32 = ifx round then cast(s32) 1 else -1;
    return lg - ifx second > 0 then cast(s32) 1 else 0;
}
// compareImpl
sn_compare_impl :: (l: u64, r: u64, scale_diff: s32) -> s32 {
    la := l >> cast(u64) scale_diff;
    if la < r return -1;
    if la > r return 1;
    return ifx l > (la << cast(u64) scale_diff) then cast(s32) 1 else 0;
}
// compare
sn_compare_raw :: (ld: u64, ls: s32, rd: u64, rs: s32) -> s32 {
    if ld == 0 return ifx rd != 0 then cast(s32) -1 else 0;
    if rd == 0 return 1;
    lg_l := sn_lg_floor(ld, ls); lg_r := sn_lg_floor(rd, rs);
    if lg_l != lg_r return ifx lg_l < lg_r then cast(s32) -1 else 1;
    if ls < rs return sn_compare_impl(ld, rd, rs - ls);
    return -sn_compare_impl(rd, ld, ls - rs);
}
sn_compare :: (a: Scaled64, b: Scaled64) -> s32 { return sn_compare_raw(a.digits, a.scale, b.digits, b.scale); }
sn_lt :: (a: Scaled64, b: Scaled64) -> bool { return sn_compare(a, b) < 0; }
// matchScales
sn_match_scales :: (ld: *u64, ls: *s32, rd: *u64, rs: *s32) -> s32 {
    if ls.* < rs.* return sn_match_scales(rd, rs, ld, ls);
    if ld.* == 0 return rs.*;
    if rd.* == 0 || ls.* == rs.* return ls.*;
    scale_diff := ls.* - rs.*;
    if scale_diff >= 128 { rd.* = 0; return ls.*; }
    shift_l := min(sn_clz(ld.*), scale_diff);
    shift_r := scale_diff - shift_l;
    if shift_r >= 64 { rd.* = 0; return ls.*; }
    ld.* <<= cast(u64) shift_l;
    rd.* >>= cast(u64) shift_r;
    ls.* -= shift_l;
    rs.* += shift_r;
    return ls.*;
}
// getSum
sn_add :: (a: Scaled64, b: Scaled64) -> Scaled64 {
    ld := a.digits; ls: s32 = a.scale; rd := b.digits; rs: s32 = b.scale;
    scale := sn_match_scales(*ld, *ls, *rd, *rs);
    sum := ld + rd;
    r: Scaled64;
    if sum >= rd { r = .{sum, cast(s16) scale}; }
    else { hb := (cast(u64) 1) << 63; r.digits = hb | (sum >> 1); r.scale = cast(s16) (scale + 1); }
    if r.scale > SN_MAX_SCALE return sn_largest();
    return r;
}
// getDifference
sn_sub :: (a: Scaled64, b: Scaled64) -> Scaled64 {
    ld := a.digits; ls: s32 = a.scale; rd := b.digits; rs: s32 = b.scale;
    saved_rd := rd; saved_rs := rs;
    sn_match_scales(*ld, *ls, *rd, *rs);
    if ld <= rd return .{0, 0};
    if rd != 0 || saved_rd == 0 return .{ld - rd, cast(s16) ls};
    r_lg_floor := sn_lg_floor(saved_rd, saved_rs);
    if sn_compare_raw(ld, ls, 1, r_lg_floor + 64) == 0 return .{0xFFFF_FFFF_FFFF_FFFF, cast(s16) r_lg_floor};
    return .{ld, cast(s16) ls};
}
sn_is_largest :: (a: Scaled64) -> bool { return sn_compare(a, sn_largest()) == 0; }
sn_shift_left :: (a: Scaled64, shift_in: s32) -> Scaled64 {
    shift := shift_in;
    r := a;
    if shift == 0 || r.digits == 0 return r;
    if shift < 0 return sn_shift_right(r, -shift);
    scale_shift := min(shift, SN_MAX_SCALE - cast(s32) r.scale);
    r.scale = cast(s16) (r.scale + scale_shift);
    if scale_shift == shift return r;
    if sn_is_largest(r) return r;
    shift -= scale_shift;
    if shift > sn_clz(r.digits) return sn_largest();
    r.digits <<= cast(u64) shift;
    return r;
}
sn_shift_right :: (a: Scaled64, shift_in: s32) -> Scaled64 {
    shift := shift_in;
    r := a;
    if shift == 0 || r.digits == 0 return r;
    if shift < 0 return sn_shift_left(r, -shift);
    scale_shift := min(shift, cast(s32) r.scale - SN_MIN_SCALE);
    r.scale = cast(s16) (r.scale - scale_shift);
    if scale_shift == shift return r;
    shift -= scale_shift;
    if shift >= 64 return sn_zero();
    r.digits >>= cast(u64) shift;
    return r;
}
// getProduct
sn_get_product :: (l: u64, r: u64) -> Scaled64 {
    if l <= 0xFFFF_FFFF && r <= 0xFFFF_FFFF return .{l * r, 0};   // getAdjusted<uint64_t> of a 64-bit product
    d, s := sn_multiply64(l, r);
    return .{d, cast(s16) s};
}
sn_mul :: (a: Scaled64, b: Scaled64) -> Scaled64 {
    if a.digits == 0 return a;
    if b.digits == 0 return b;
    scales := cast(s32) a.scale + cast(s32) b.scale;
    p := sn_get_product(a.digits, b.digits);
    return sn_shift_left(p, scales);
}
sn_div :: (a: Scaled64, b: Scaled64) -> Scaled64 {
    if a.digits == 0 return a;
    if b.digits == 0 return sn_largest();
    scales := cast(s32) a.scale - cast(s32) b.scale;
    q := sn_get_quotient(a.digits, b.digits);
    return sn_shift_left(q, scales);
}
sn_get :: (n: u64) -> Scaled64 { return .{n, 0}; }
sn_inverse :: (a: Scaled64) -> Scaled64 { return sn_div(sn_get(1), a); }
// toInt<uint64_t>
sn_to_int :: (a: Scaled64) -> u64 {
    if sn_compare_raw(a.digits, a.scale, 1, 0) < 0 return 0;
    if sn_compare_raw(a.digits, a.scale, 0xFFFF_FFFF_FFFF_FFFF, 0) >= 0 return 0xFFFF_FFFF_FFFF_FFFF;
    n := a.digits;
    if a.scale > 0 return n << cast(u64) a.scale;
    if a.scale < 0 return n >> cast(u64) (-a.scale);
    return n;
}

// ScaledNumberBase::toString(D, E, Width = 64, Precision)
sn_to_string :: (d_in: u64, e_in: s16, precision: u32) -> string {
    d := d_in; e: s32 = e_in;
    if d == 0 return "0.0";
    above0: u64 = 0; below0: u64 = 0; extra: u64 = 0; extra_shift: s32 = 0;
    if e == 0 above0 = d;
    else if e > 0 {
        shift := min(sn_clz(d), e);
        if shift {
            d <<= cast(u64) shift;
            e -= shift;
            if e == 0 above0 = d;
        }
    } else if e > -64 {
        above0 = d >> cast(u64) (-e);
        below0 = d << cast(u64) (64 + e);
    } else if e == -64 {
        below0 = d;
    } else if e > -120 {
        below0 = d >> cast(u64) (-e - 64);
        extra = d << cast(u64) (128 + e);
        extra_shift = -64 - e;
    }
    if above0 == 0 && below0 == 0 fatal("block-freq: printing a ScaledNumber through APFloat (toStringAPFloat) is not implemented yet");
    str: [..] u8; str.allocator = temp;
    digits_out := 0;
    if above0 {
        n := above0;
        while n { array_add(*str, cast(u8) (#char "0" + n % 10)); n /= 10; }
        digits_out = str.count;
    } else array_add(*str, #char "0");
    // reverse
    for k: 0..str.count / 2 - 1 { t := str[k]; str[k] = str[str.count - 1 - k]; str[str.count - 1 - k] = t; }
    if below0 == 0 { array_add(*str, #char "."); array_add(*str, #char "0"); return cast(string) str; }
    array_add(*str, #char ".");
    error: u64 = (cast(u64) 1) << (64 - 64);
    extra = ((below0 & 0xf) << 56) | (extra >> 8);
    below0 >>= 4;
    since_dot := 0;
    after_dot := str.count;
    while true {
        if extra_shift { extra_shift -= 1; error *= 5; }
        else error *= 10;
        below0 *= 10;
        extra *= 10;
        below0 += extra >> 60;
        extra = extra & ((cast(u64) 0xFFFF_FFFF_FFFF_FFFF) >> 4);
        array_add(*str, cast(u8) (#char "0" + (below0 >> 60)));
        below0 = below0 & ((cast(u64) 0xFFFF_FFFF_FFFF_FFFF) >> 4);
        if digits_out || str[str.count - 1] != #char "0" digits_out += 1;
        since_dot += 1;
        if !(error != 0 && ((below0 << 4) | (extra >> 60)) >= error / 2 && (precision == 0 || digits_out <= cast(s64) precision || since_dot < 2)) break;
    }
    strip :: (s: string) -> string {
        k := s.count - 1;
        while k >= 0 && s[k] == #char "0" k -= 1;
        if s[k] == #char "." k += 1;
        return slice(s, 0, k + 1);
    }
    s := cast(string) str;
    if precision == 0 || digits_out <= cast(s64) precision return strip(s);
    truncate := max(s.count - (digits_out - cast(s64) precision), after_dot + 1);
    if truncate >= s.count return strip(s);
    c := s[truncate];
    if !(c >= #char "5" && c <= #char "9") return strip(slice(s, 0, truncate));
    out: [..] u8; out.allocator = temp;
    for k: 0..truncate - 1 array_add(*out, s[k]);
    carry := true;
    k := truncate - 1;
    while k >= 0 {
        if out[k] == #char "." { k -= 1; continue; }
        if out[k] == #char "9" { out[k] = #char "0"; k -= 1; continue; }
        out[k] += 1;
        carry = false;
        break;
    }
    r := cast(string) out;
    if carry r = tprint("1%", r);
    return strip(r);
}

// ---------------------------------------------------------------- BlockMass

BM_FULL :: 0xFFFF_FFFF_FFFF_FFFF;
bm_add :: (a: u64, b: u64) -> u64 { s := a + b; return ifx s < a then BM_FULL else s; }
bm_sub :: (a: u64, b: u64) -> u64 { d := a - b; return ifx d > a then cast(u64) 0 else d; }
bm_to_scaled :: (m: u64) -> Scaled64 { if m == BM_FULL return .{1, 0}; return .{m + 1, -64}; }

// ---------------------------------------------------------------- BlockFrequencyInfoImpl

Bfi_Weight_Type :: enum u8 { LOCAL; EXIT; BACKEDGE; }
Bfi_Weight :: struct { type: Bfi_Weight_Type; target: u32 = 0xFFFF_FFFF; amount: u64; }
Bfi_Dist :: struct { weights: [..] Bfi_Weight; total: u64; did_overflow: bool; }

Bfi_Loop :: struct {
    parent: s32 = -1;
    is_packaged: bool;
    num_headers: u32 = 1;
    exits: [..] [2] u64;      // (node, mass)
    nodes: [..] u32;
    backedge_mass: [..] u64;
    mass: u64;
    scale: Scaled64;
}
Bfi_Working :: struct { node: u32; loop: s32 = -1; mass: u64; }

Bfi_Impl :: struct {
    bpi: *Bpi;
    li: *Loop_Info;
    f: Value_Id;
    rpot: [..] Value_Id;
    node_of: Table(Value_Id, u32);
    working: [..] Bfi_Working;
    loops: [..] Bfi_Loop;     // rows (stable ids)
    order: [..] s32;          // the std::list order of Loops
    freqs_scaled: [..] Scaled64;
    is_irr_loop_header: Table(u32, bool);
}

Bfi :: struct {
    f: Value_Id;
    freq: Table(Value_Id, u64);          // Freqs[].Integer per block (incl. blocks added by setBlockFreq)
    scaled: Table(Value_Id, Scaled64);   // Freqs[].Scaled (for printing)
    entry_freq: u64;
}

bfi_free :: (b: *Bfi) { deinit(*b.freq); deinit(*b.scaled); free(b); }

// BlockFrequencyInfo::getBlockFreq
bfi_get_block_freq :: (b: *Bfi, bb: Value_Id) -> u64 { found, f := table_find(*b.freq, bb); return ifx found then f else 0; }
// setBlockFreq
bfi_set_block_freq :: (b: *Bfi, bb: Value_Id, f: u64) { table_set(*b.freq, bb, f); }
// BlockFrequency * BranchProbability, BlockFrequency - BlockFrequency (saturating)
bf_mul_prob :: (f: u64, p: u32) -> u64 { return bp_scale(p, f); }
bf_sub :: (a: u64, b: u64) -> u64 { return ifx a >= b then a - b else 0; }
bf_add :: (a: u64, b: u64) -> u64 { s := a + b; return ifx s < a then 0xFFFF_FFFF_FFFF_FFFF else s; }

bfw :: inline (c: *Bfi_Impl, n: u32) -> *Bfi_Working { return *c.working[n]; }
bfl :: inline (c: *Bfi_Impl, l: s32) -> *Bfi_Loop { return *c.loops[l]; }

bfi_loop_is_irreducible :: (c: *Bfi_Impl, l: s32) -> bool { return bfl(c, l).num_headers > 1; }
bfi_loop_is_header :: (c: *Bfi_Impl, l: s32, n: u32) -> bool {
    lp := bfl(c, l);
    if lp.num_headers > 1 {
        for k: 0..lp.num_headers - 1 if lp.nodes[k] == n return true;   // binary_search over the sorted headers
        return false;
    }
    return n == lp.nodes[0];
}
bfi_loop_header_index :: (c: *Bfi_Impl, l: s32, n: u32) -> s64 {
    lp := bfl(c, l);
    if lp.num_headers > 1 {
        k: s64 = 0;
        while k < lp.num_headers && lp.nodes[k] < n k += 1;   // lower_bound
        return k;
    }
    return 0;
}
bfi_is_loop_header :: (c: *Bfi_Impl, n: u32) -> bool { w := bfw(c, n); return w.loop >= 0 && bfi_loop_is_header(c, w.loop, n); }
bfi_is_double_loop_header :: (c: *Bfi_Impl, n: u32) -> bool {
    w := bfw(c, n);
    if !bfi_is_loop_header(c, n) return false;
    p := bfl(c, w.loop).parent;
    return p >= 0 && bfi_loop_is_irreducible(c, p) && bfi_loop_is_header(c, p, n);
}
bfi_containing_loop :: (c: *Bfi_Impl, n: u32) -> s32 {
    w := bfw(c, n);
    if !bfi_is_loop_header(c, n) return w.loop;
    if !bfi_is_double_loop_header(c, n) return bfl(c, w.loop).parent;
    return bfl(c, bfl(c, w.loop).parent).parent;
}
bfi_packaged_loop :: (c: *Bfi_Impl, n: u32) -> s32 {
    w := bfw(c, n);
    if w.loop < 0 || !bfl(c, w.loop).is_packaged return -1;
    l := w.loop;
    while bfl(c, l).parent >= 0 && bfl(c, bfl(c, l).parent).is_packaged l = bfl(c, l).parent;
    return l;
}
bfi_resolved_node :: (c: *Bfi_Impl, n: u32) -> u32 { l := bfi_packaged_loop(c, n); return ifx l >= 0 then bfl(c, l).nodes[0] else n; }
bfi_is_a_package :: (c: *Bfi_Impl, n: u32) -> bool { return bfi_is_loop_header(c, n) && bfl(c, bfw(c, n).loop).is_packaged; }
bfi_is_a_double_package :: (c: *Bfi_Impl, n: u32) -> bool { return bfi_is_double_loop_header(c, n) && bfl(c, bfl(c, bfw(c, n).loop).parent).is_packaged; }
bfi_mass :: (c: *Bfi_Impl, n: u32) -> *u64 {
    w := bfw(c, n);
    if !bfi_is_a_package(c, n) return *w.mass;
    if !bfi_is_a_double_package(c, n) return *bfl(c, w.loop).mass;
    return *bfl(c, bfl(c, w.loop).parent).mass;
}
bfi_is_packaged :: (c: *Bfi_Impl, n: u32) -> bool { return bfi_resolved_node(c, n) != n; }

// Distribution::add
bfi_dist_add :: (d: *Bfi_Dist, node: u32, amount: u64, type: Bfi_Weight_Type) {
    new_total := d.total + amount;
    if new_total < d.total d.did_overflow = true;
    d.total = new_total;
    array_add(*d.weights, .{type, node, amount});
}
// combineWeight
bfi_combine_weight :: (w: *Bfi_Weight, o: Bfi_Weight) {
    if w.amount == 0 { w.* = o; return; }
    if w.amount > w.amount + o.amount w.amount = 0xFFFF_FFFF_FFFF_FFFF;
    else w.amount += o.amount;
}
// combineWeights (by sorting; by hashing for more than 128 weights, emulating DenseMap<unsigned> bucket order)
bfi_combine_weights :: (ws: *[..] Bfi_Weight) {
    if ws.count > 128 {
        // DenseMap<uint32_t, Weight> Combined(NextPowerOf2(2 * size)): hash = key * 37, quadratic probing
        reserve := next_power_of_2(cast(u64) (2 * ws.count));
        nb := next_power_of_2(reserve * 4 / 3 + 1);
        keys := NewArray(cast(s64) nb, u32,, allocator = temp);
        vals := NewArray(cast(s64) nb, Bfi_Weight,, allocator = temp);
        for * keys it.* = 0xFFFF_FFFF;
        count := 0;
        for w: ws.* {
            b := (w.target * 37) & cast(u32) (nb - 1);
            probe: u32 = 1;
            while keys[b] != 0xFFFF_FFFF && keys[b] != w.target { b = (b + probe) & cast(u32) (nb - 1); probe += 1; }
            if keys[b] == 0xFFFF_FFFF { keys[b] = w.target; vals[b] = .{}; count += 1; }
            bfi_combine_weight(*vals[b], w);
        }
        if count == ws.count return;
        ws.count = 0;
        for keys if it != 0xFFFF_FFFF array_add(ws, vals[it_index]);
        return;
    }
    // llvm::sort by TargetNode, then merge equal targets
    for i: 1..ws.count - 1 {
        x := ws.*[i]; j := i - 1;
        while j >= 0 && ws.*[j].target > x.target { ws.*[j + 1] = ws.*[j]; j -= 1; }
        ws.*[j + 1] = x;
    }
    o := 0;
    i := 0;
    while i < ws.count {
        cur := ws.*[i];
        l := i + 1;
        while l < ws.count && ws.*[l].target == cur.target { bfi_combine_weight(*cur, ws.*[l]); l += 1; }
        ws.*[o] = cur; o += 1;
        i = l;
    }
    ws.count = o;
}
next_power_of_2 :: (a: u64) -> u64 { x := a; x |= x >> 1; x |= x >> 2; x |= x >> 4; x |= x >> 8; x |= x >> 16; x |= x >> 32; return x + 1; }
// Distribution::normalize
bfi_dist_normalize :: (d: *Bfi_Dist) {
    if d.weights.count == 0 return;
    if d.weights.count > 1 bfi_combine_weights(*d.weights);
    if d.weights.count == 1 { d.total = 1; d.weights[0].amount = 1; return; }
    shift: s32 = 0;
    if d.did_overflow shift = 33;
    else if d.total > 0xFFFF_FFFF shift = 33 - sn_clz(d.total);
    if shift == 0 return;
    d.total = 0;
    for * d.weights {
        a := it.amount;
        r := (a >> cast(u64) shift) + ((a >> cast(u64) (shift - 1)) & 1);   // shiftRightAndRound
        it.amount = max(cast(u64) 1, r);
        d.total += it.amount;
    }
}
// DitheringDistributer
Bfi_Dither :: struct { rem_weight: u32; rem_mass: u64; }
bfi_dither_init :: (d: *Bfi_Dist, mass: u64) -> Bfi_Dither {
    bfi_dist_normalize(d);
    r: Bfi_Dither; r.rem_weight = cast(u32) d.total; r.rem_mass = mass;
    return r;
}
bfi_dither_take :: (dd: *Bfi_Dither, w: u32) -> u64 {
    m := bp_scale(bp_make(w, dd.rem_weight), dd.rem_mass);
    dd.rem_weight -= w;
    dd.rem_mass = bm_sub(dd.rem_mass, m);
    return m;
}

// addToDist
bfi_add_to_dist :: (c: *Bfi_Impl, d: *Bfi_Dist, outer: s32, pred: u32, succ: u32, weight_in: u64) -> bool {
    weight := ifx weight_in == 0 then cast(u64) 1 else weight_in;
    is_loop_header :: (c: *Bfi_Impl, outer: s32, n: u32) -> bool { return outer >= 0 && bfi_loop_is_header(c, outer, n); }
    resolved := bfi_resolved_node(c, succ);
    if is_loop_header(c, outer, resolved) { bfi_dist_add(d, resolved, weight, .BACKEDGE); return true; }
    if bfi_containing_loop(c, resolved) != outer { bfi_dist_add(d, resolved, weight, .EXIT); return true; }
    if resolved < pred {
        if !is_loop_header(c, outer, pred) return false;
    }
    bfi_dist_add(d, resolved, weight, .LOCAL);
    return true;
}
// addLoopSuccessorsToDist
bfi_add_loop_successors_to_dist :: (c: *Bfi_Impl, outer: s32, l: s32, d: *Bfi_Dist) -> bool {
    for e: bfl(c, l).exits if !bfi_add_to_dist(c, d, outer, bfl(c, l).nodes[0], cast(u32) e[0], e[1]) return false;
    return true;
}
// computeLoopScale
bfi_compute_loop_scale :: (c: *Bfi_Impl, l: s32) {
    total: u64 = 0;
    for bfl(c, l).backedge_mass total = bm_add(total, it);
    exit_mass := bm_sub(BM_FULL, total);
    bfl(c, l).scale = ifx exit_mass == 0 then Scaled64.{1, 12} else sn_inverse(bm_to_scaled(exit_mass));
}
// packageLoop
bfi_package_loop :: (c: *Bfi_Impl, l: s32) {
    for m: bfl(c, l).nodes {
        pl := bfi_packaged_loop(c, m);
        if pl >= 0 bfl(c, pl).exits.count = 0;
    }
    bfl(c, l).is_packaged = true;
}
// distributeMass
bfi_distribute_mass :: (c: *Bfi_Impl, source: u32, outer: s32, d: *Bfi_Dist) {
    mass := bfi_mass(c, source).*;
    dd := bfi_dither_init(d, mass);
    for w: d.weights {
        taken := bfi_dither_take(*dd, cast(u32) w.amount);
        if w.type == .LOCAL { m := bfi_mass(c, w.target); m.* = bm_add(m.*, taken); continue; }
        assert(outer >= 0, "backedge or exit outside of loop");
        if w.type == .BACKEDGE {
            hi := bfi_loop_header_index(c, outer, w.target);
            bfl(c, outer).backedge_mass[hi] = bm_add(bfl(c, outer).backedge_mass[hi], taken);
            continue;
        }
        array_add(*bfl(c, outer).exits, .[cast(u64) w.target, taken]);
    }
}
// propagateMassToSuccessors
bfi_propagate_mass_to_successors :: (c: *Bfi_Impl, outer: s32, node: u32) -> bool {
    d: Bfi_Dist; d.weights.allocator = temp;
    pl := bfi_packaged_loop(c, node);
    if pl >= 0 {
        if !bfi_add_loop_successors_to_dist(c, outer, pl, *d) return false;
    } else {
        bb := c.rpot[node];
        t := block_terminator(bb);
        n := num_successors(t);
        for k: 0..cast(s64) n - 1 {
            s := get_successor(t, cast(u32) k);
            _, sn := table_find(*c.node_of, s);
            if !bfi_add_to_dist(c, *d, outer, node, sn, bpi_edge_probability_idx(c.bpi, bb, cast(u32) k)) return false;
        }
    }
    bfi_distribute_mass(c, node, outer, *d);
    return true;
}

bfi_new_loop :: (c: *Bfi_Impl, parent: s32) -> s32 {
    lp: Bfi_Loop; lp.parent = parent;
    lp.exits.allocator = temp; lp.nodes.allocator = temp; lp.backedge_mass.allocator = temp;
    array_add(*c.loops, lp);
    return cast(s32) (c.loops.count - 1);
}

// initializeLoops
bfi_initialize_loops :: (c: *Bfi_Impl) {
    li := c.li;
    if li.top_level.count == 0 return;
    q: [..] [2] s32; q.allocator = temp;   // (Loop_Id, parent LoopData)
    for li.top_level array_add(*q, .[cast(s32) it, -1]);
    qi := 0;
    while qi < q.count {
        l := cast(Loop_Id) q[qi][0];
        parent := q[qi][1];
        qi += 1;
        _, header := table_find(*c.node_of, li_header(li, l));
        nl := bfi_new_loop(c, parent);
        array_add(*bfl(c, nl).nodes, header);
        array_add(*bfl(c, nl).backedge_mass, 0);
        array_add(*c.order, nl);
        bfw(c, header).loop = nl;
        for li.loops[l].subloops array_add(*q, .[cast(s32) it, nl]);
    }
    for idx: 0..c.rpot.count - 1 {
        n := cast(u32) idx;
        if bfi_is_loop_header(c, n) {
            cl := bfi_containing_loop(c, n);
            if cl >= 0 array_add(*bfl(c, cl).nodes, n);
            continue;
        }
        l := li_loop_for(li, c.rpot[idx]);
        if l == NONE continue;
        _, header := table_find(*c.node_of, li_header(li, l));
        hl := bfw(c, header).loop;
        bfw(c, n).loop = hl;
        array_add(*bfl(c, hl).nodes, n);
    }
}

// computeMassInLoop
bfi_compute_mass_in_loop :: (c: *Bfi_Impl, l: s32) -> bool {
    if bfi_loop_is_irreducible(c, l) {
        d: Bfi_Dist; d.weights.allocator = temp;
        num_with_weight := 0;
        have_min := false; min_weight: u64 = 0;
        without: [..] u32; without.allocator = temp;
        for h: 0..bfl(c, l).num_headers - 1 {
            hn := bfl(c, l).nodes[h];
            table_set(*c.is_irr_loop_header, hn, true);
            okw, hw := block_irr_loop_header_weight(c.rpot[hn]);
            if !okw { array_add(*without, h); continue; }
            num_with_weight += 1;
            if !have_min || hw < min_weight { min_weight = hw; have_min = true; }
            if hw bfi_dist_add(*d, hn, hw, .LOCAL);
        }
        if !have_min min_weight = 1;
        // HeadersWithoutWeight is a DenseSet<uint32_t>: iterate it in its bucket order
        for h: dense_set_u32_order(without) {
            hn := bfl(c, l).nodes[h];
            if min_weight bfi_dist_add(*d, hn, min_weight, .LOCAL);
        }
        bfi_distribute_irr_loop_header_mass(c, *d);
        for m: bfl(c, l).nodes if !bfi_propagate_mass_to_successors(c, l, m) fatal("block-freq: unhandled irreducible control flow");
        if num_with_weight == 0 bfi_adjust_loop_header_mass(c, l);
    } else {
        bfi_mass(c, bfl(c, l).nodes[0]).* = BM_FULL;
        if !bfi_propagate_mass_to_successors(c, l, bfl(c, l).nodes[0]) fatal("block-freq: irreducible control flow to loop header");
        for k: bfl(c, l).num_headers..bfl(c, l).nodes.count - 1 {
            if !bfi_propagate_mass_to_successors(c, l, bfl(c, l).nodes[k]) return false;
        }
    }
    bfi_compute_loop_scale(c, l);
    bfi_package_loop(c, l);
    return true;
}
// The iteration order of a small DenseSet<uint32_t> with these keys (hash = key * 37, quadratic probing)
dense_set_u32_order :: (keys: [] u32) -> [] u32 {
    if keys.count == 0 return keys;
    // DenseSet::reserve(NumHeaders) then inserts
    // DenseSet<uint32_t>::reserve(n) on an empty set: grow(getMinBucketToReserveForEntries(n)), and grow allocates
    // max(64, NextPowerOf2(AtLeast - 1)) buckets
    want := next_power_of_2(cast(u64) keys.count * 4 / 3 + 1);
    nb := max(cast(u64) 64, next_power_of_2(want - 1));
    slots := NewArray(cast(s64) nb, u32,, allocator = temp);
    for * slots it.* = 0xFFFF_FFFF;
    for k: keys {
        b := (k * 37) & cast(u32) (nb - 1);
        probe: u32 = 1;
        while slots[b] != 0xFFFF_FFFF && slots[b] != k { b = (b + probe) & cast(u32) (nb - 1); probe += 1; }
        slots[b] = k;
    }
    out: [..] u32; out.allocator = temp;
    for slots if it != 0xFFFF_FFFF array_add(*out, it);
    return out;
}
// BasicBlock::getIrrLoopHeaderWeight
block_irr_loop_header_weight :: (bb: Value_Id) -> (bool, u64) {
    m := get_metadata(block_terminator(bb), md_kind_id("irr_loop"));
    if m == NONE return false, 0;
    s := md_op(m, 0);
    if s == NONE || ir.mds[s].kind != .STRING || ir.mds[s].str != "loop_header_weight" return false, 0;
    c := md_const_int_op(m, 1);
    return true, const_int_zext(c);
}
// distributeIrrLoopHeaderMass
bfi_distribute_irr_loop_header_mass :: (c: *Bfi_Impl, d: *Bfi_Dist) {
    dd := bfi_dither_init(d, BM_FULL);
    for w: d.weights {
        taken := bfi_dither_take(*dd, cast(u32) w.amount);
        bfi_mass(c, w.target).* = taken;
    }
}
// adjustLoopHeaderMass
bfi_adjust_loop_header_mass :: (c: *Bfi_Impl, l: s32) {
    d: Bfi_Dist; d.weights.allocator = temp;
    for h: 0..bfl(c, l).num_headers - 1 {
        hn := bfl(c, l).nodes[h];
        bm := bfl(c, l).backedge_mass[bfi_loop_header_index(c, l, hn)];
        if bm > 0 bfi_dist_add(*d, hn, bm, .LOCAL);
    }
    dd := bfi_dither_init(*d, BM_FULL);
    for w: d.weights {
        taken := bfi_dither_take(*dd, cast(u32) w.amount);
        bfi_mass(c, w.target).* = taken;
    }
}

// IrreducibleGraph
Irr_Node :: struct { node: u32; num_in: u32; edges: [..] s32; }   // edges: [preds (push_front)..., succs...]
Irr_Graph :: struct { nodes: [..] Irr_Node; lookup: Table(u32, s32); start: u32; start_irr: s32; }

irr_add_node :: (c: *Bfi_Impl, g: *Irr_Graph, n: u32) {
    x: Irr_Node; x.node = n; x.edges.allocator = temp;
    array_add(*g.nodes, x);
    bfi_mass(c, n).* = 0;
}
irr_add_edge :: (c: *Bfi_Impl, g: *Irr_Graph, irr: s32, succ: u32, outer: s32) {
    if outer >= 0 && bfi_loop_is_header(c, outer, succ) return;
    found, si := table_find(*g.lookup, succ);
    if !found return;
    array_add(*g.nodes[irr].edges, si);
    array_insert_at(*g.nodes[si].edges, irr, 0);
    g.nodes[si].num_in += 1;
}
irr_build :: (c: *Bfi_Impl, g: *Irr_Graph, outer: s32) {
    g.nodes.allocator = temp; g.lookup.allocator = temp;
    add_edges :: (c: *Bfi_Impl, g: *Irr_Graph, n: u32, outer: s32) {
        found, irr := table_find(*g.lookup, n);
        if !found return;
        if bfi_is_a_package(c, n) {
            for e: bfl(c, bfw(c, n).loop).exits irr_add_edge(c, g, irr, cast(u32) e[0], outer);
        } else {
            bb := c.rpot[n];
            succs: [..] Value_Id; succs.allocator = temp;
            block_successors(bb, *succs);
            for s: succs { _, sn := table_find(*c.node_of, s); irr_add_edge(c, g, irr, sn, outer); }
        }
    }
    if outer >= 0 {
        g.start = bfl(c, outer).nodes[0];
        for n: bfl(c, outer).nodes irr_add_node(c, g, n);
        for g.nodes table_set(*g.lookup, it.node, cast(s32) it_index);
        for n: bfl(c, outer).nodes add_edges(c, g, n, outer);
    } else {
        g.start = 0;
        for idx: 0..c.working.count - 1 if !bfi_is_packaged(c, cast(u32) idx) irr_add_node(c, g, cast(u32) idx);
        for g.nodes table_set(*g.lookup, it.node, cast(s32) it_index);
        for idx: 0..c.working.count - 1 add_edges(c, g, cast(u32) idx, outer);
    }
    _, g.start_irr = table_find(*g.lookup, g.start);
}
// scc_iterator over the IrreducibleGraph (children = successor edges)
irr_sccs :: (g: *Irr_Graph, out: *[..] [..] s32) {
    Elem :: struct { node: s32; next_child: s64; min_visited: u32; }
    visit_num: u32 = 0;
    numbers := NewArray(g.nodes.count, u32,, allocator = temp);   // 0 = not visited
    scc_stack: [..] s32; scc_stack.allocator = temp;
    visit_stack: [..] Elem; visit_stack.allocator = temp;
    visit_one :: (g: *Irr_Graph, n: s32, visit_num: *u32, numbers: [] u32, scc_stack: *[..] s32, visit_stack: *[..] Elem) {
        visit_num.* += 1;
        numbers[n] = visit_num.*;
        array_add(scc_stack, n);
        array_add(visit_stack, .{n, cast(s64) g.nodes[n].num_in, visit_num.*});
    }
    visit_one(g, g.start_irr, *visit_num, numbers, *scc_stack, *visit_stack);
    while visit_stack.count {
        while true {
            top := *visit_stack[visit_stack.count - 1];
            if top.next_child >= g.nodes[top.node].edges.count break;
            child := g.nodes[top.node].edges[top.next_child];
            top.next_child += 1;
            if numbers[child] == 0 { visit_one(g, child, *visit_num, numbers, *scc_stack, *visit_stack); continue; }
            if top.min_visited > numbers[child] top.min_visited = numbers[child];
        }
        visiting := visit_stack[visit_stack.count - 1].node;
        min_visit := visit_stack[visit_stack.count - 1].min_visited;
        visit_stack.count -= 1;
        if visit_stack.count && visit_stack[visit_stack.count - 1].min_visited > min_visit visit_stack[visit_stack.count - 1].min_visited = min_visit;
        if min_visit != numbers[visiting] continue;
        scc: [..] s32; scc.allocator = temp;
        while true {
            x := pop(*scc_stack);
            array_add(*scc, x);
            numbers[x] = 0xFFFF_FFFF;
            if x == visiting break;
        }
        array_add(out, scc);
    }
}
// findIrreducibleHeaders + createIrreducibleLoop; returns the new loop
bfi_create_irreducible_loop :: (c: *Bfi_Impl, g: *Irr_Graph, outer: s32, insert_pos: s64, scc: [] s32) -> s32 {
    headers: [..] u32; headers.allocator = temp;
    others: [..] u32; others.allocator = temp;
    in_scc :: (scc: [] s32, x: s32) -> bool { for scc if it == x return true; return false; }
    is_header := NewArray(scc.count, bool,, allocator = temp);
    for irr, k: scc {
        nd := *g.nodes[irr];
        for p: 0..cast(s64) nd.num_in - 1 {
            if in_scc(scc, nd.edges[p]) continue;
            is_header[k] = true;
            array_add(*headers, nd.node);
            break;
        }
    }
    if headers.count != scc.count {
        for irr, k: scc {
            if is_header[k] continue;
            nd := *g.nodes[irr];
            added := false;
            for p: 0..cast(s64) nd.num_in - 1 {
                pn := g.nodes[nd.edges[p]];
                if pn.node < nd.node continue;
                // InSCC.lookup(P): true only for an SCC member already found to be a header
                pk := -1;
                for scc if it == nd.edges[p] { pk = it_index; break; }
                if pk >= 0 && is_header[pk] continue;
                array_add(*headers, nd.node);
                added = true;
                break;
            }
            if added continue;
            array_add(*others, nd.node);
        }
    }
    sort_u32 :: (a: *[..] u32) { for i: 1..a.count - 1 { x := a.*[i]; j := i - 1; while j >= 0 && a.*[j] > x { a.*[j + 1] = a.*[j]; j -= 1; } a.*[j + 1] = x; } }
    sort_u32(*headers);
    sort_u32(*others);
    nl := bfi_new_loop(c, outer);
    lp := bfl(c, nl);
    for headers array_add(*lp.nodes, it);
    lp.num_headers = cast(u32) headers.count;
    for others array_add(*lp.nodes, it);
    for 0..headers.count - 1 array_add(*lp.backedge_mass, 0);
    array_insert_at(*c.order, nl, insert_pos);
    for n: bfl(c, nl).nodes {
        if bfi_is_loop_header(c, n) bfl(c, bfw(c, n).loop).parent = nl;
        else bfw(c, n).loop = nl;
    }
    return nl;
}
// computeIrreducibleMass(OuterLoop, Insert): Insert is a position in c.order
bfi_compute_irreducible_mass :: (c: *Bfi_Impl, outer: s32, insert_pos_in: s64) {
    g: Irr_Graph;
    irr_build(c, *g, outer);
    sccs: [..] [..] s32; sccs.allocator = temp;
    irr_sccs(*g, *sccs);
    insert_pos := insert_pos_in;
    created: [..] s32; created.allocator = temp;
    for scc: sccs {
        if scc.count < 2 continue;
        array_add(*created, bfi_create_irreducible_loop(c, *g, outer, insert_pos, scc));
        insert_pos += 1;
    }
    for created bfi_compute_mass_in_loop(c, it);
    if outer < 0 return;
    // updateLoopWithIrreducible
    lp := bfl(c, outer);
    lp.exits.count = 0;
    for * lp.backedge_mass it.* = 0;
    o := 1;
    for k: 1..lp.nodes.count - 1 if !bfi_is_packaged(c, lp.nodes[k]) { lp.nodes[o] = lp.nodes[k]; o += 1; }
    lp.nodes.count = o;
}

// computeMassInLoops
bfi_compute_mass_in_loops :: (c: *Bfi_Impl) {
    i := c.order.count - 1;
    while i >= 0 {
        l := c.order[i];
        if bfi_compute_mass_in_loop(c, l) { i -= 1; continue; }
        // new irreducible loops go right after L in the list order
        bfi_compute_irreducible_mass(c, l, i + 1);
        if bfi_compute_mass_in_loop(c, l) { i -= 1; continue; }
        fatal("block-freq: unhandled irreducible control flow");
    }
}
// tryToComputeMassInFunction
bfi_try_to_compute_mass_in_function :: (c: *Bfi_Impl) -> bool {
    bfi_mass(c, 0).* = BM_FULL;
    for i: 0..c.rpot.count - 1 {
        if bfi_is_packaged(c, cast(u32) i) continue;
        if !bfi_propagate_mass_to_successors(c, -1, cast(u32) i) return false;
    }
    return true;
}
bfi_compute_mass_in_function :: (c: *Bfi_Impl) {
    if bfi_try_to_compute_mass_in_function(c) return;
    bfi_compute_irreducible_mass(c, -1, 0);
    if bfi_try_to_compute_mass_in_function(c) return;
    fatal("block-freq: unhandled irreducible control flow");
}
// unwrapLoops
bfi_unwrap_loops :: (c: *Bfi_Impl) {
    for idx: 0..c.working.count - 1 c.freqs_scaled[idx] = bm_to_scaled(c.working[idx].mass);
    for l: c.order {
        lp := bfl(c, l);
        lp.scale = sn_mul(lp.scale, bm_to_scaled(lp.mass));
        lp.is_packaged = false;
        for n: lp.nodes {
            if bfi_is_a_package(c, n) {
                pl := bfl(c, bfw(c, n).loop);
                pl.scale = sn_mul(lp.scale, pl.scale);
            } else c.freqs_scaled[n] = sn_mul(lp.scale, c.freqs_scaled[n]);
        }
    }
}

// BlockFrequencyInfoImpl::calculate
bfi_calculate :: (f: Value_Id, bpi: *Bpi, li: *Loop_Info) -> *Bfi {
    c: Bfi_Impl;
    c.bpi = bpi; c.li = li; c.f = f;
    c.rpot.allocator = temp; c.node_of.allocator = temp; c.working.allocator = temp; c.loops.allocator = temp;
    c.order.allocator = temp; c.freqs_scaled.allocator = temp; c.is_irr_loop_header.allocator = temp;
    po: [..] Value_Id; po.allocator = temp;
    cfg_post_order(fn_entry(f), *po);
    for < k: 0..po.count - 1 array_add(*c.rpot, po[k]);
    for c.rpot table_set(*c.node_of, it, cast(u32) it_index);
    for c.rpot array_add(*c.working, .{cast(u32) it_index, -1, 0});
    array_resize(*c.freqs_scaled, c.rpot.count);
    bfi_initialize_loops(*c);
    bfi_compute_mass_in_loops(*c);
    bfi_compute_mass_in_function(*c);
    bfi_unwrap_loops(*c);
    // finalizeMetrics / convertFloatingToInteger
    mx := sn_zero();
    for c.freqs_scaled if sn_lt(mx, it) mx = it;
    factor := sn_div(Scaled64.{1, 64 - 10}, mx);
    b := New(Bfi);
    b.f = f;
    for bb: c.rpot {
        s := c.freqs_scaled[it_index];
        table_set(*b.scaled, bb, s);
        table_set(*b.freq, bb, max(cast(u64) 1, sn_to_int(sn_mul(s, factor))));
    }
    b.entry_freq = bfi_get_block_freq(b, c.rpot[0]);
    return b;
}

// Function::getEntryCount: fn_entry_count (pass_loop_simplify.jai)
// getProfileCountFromFreq: (EntryCount * Freq + EntryFreq / 2) / EntryFreq in 128 bits, limited to 64
bfi_profile_count_from_freq :: (b: *Bfi, f: Value_Id, freq: u64) -> (bool, u64) {
    ok, entry := fn_entry_count(f);
    if !ok return false, 0;
    bc := ap_mul(ap_from_u64(128, entry), ap_from_u64(128, freq));
    ef := ap_from_u64(128, b.entry_freq);
    bc = ap_udiv(ap_add(bc, ap_lshr(ef, 1)), ef);
    return true, ap_limited(bc);
}

// BlockFrequencyPrinterPass::run
print_block_freq_run :: (f: Value_Id) -> Preserved {
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "Printing analysis results of BFI for function '%':\n", vname(f));
    b := get_bfi(f);
    print_to_builder(*sb, "block-frequency-info: %\n", vname(f));
    for bb: fn_blocks(f) {
        found, s := table_find(*b.scaled, bb);
        if !found s = sn_zero();
        fr := bfi_get_block_freq(b, bb);
        print_to_builder(*sb, " - %: float = %, int = %", vname(bb), sn_to_string(s.digits, s.scale, 5), fr);
        okc, cnt := bfi_profile_count_from_freq(b, f, fr);
        if okc print_to_builder(*sb, ", count = %", cnt);
        okw, w := block_irr_loop_header_weight(bb);
        if okw print_to_builder(*sb, ", irr_loop_header_weight = %", w);
        append(*sb, "\n");
    }
    append(*sb, "\n");
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}
