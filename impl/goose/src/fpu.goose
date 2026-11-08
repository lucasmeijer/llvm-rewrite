// IEEE arithmetic on constant bit patterns, following llvm/lib/Support/APFloat.cpp (IEEEFloat::add / subtract /
// multiply / divide / mod / compare, their *Specials NaN and infinity rules, makeNaN / makeQuiet).
// Finite results are computed exactly with bignums and rounded once (round to nearest, ties to even) by
// fp_round_rational, so every format (half, bfloat, float, double, x86_fp80, fp128) is handled the same way.
import std;
import ir;
import bignum;
import apfloat;

let FOP_ADD = 0;
let FOP_SUB = 1;
let FOP_MUL = 2;
let FOP_DIV = 3;
let FOP_MOD = 4;

// makeNaN(): the default quiet NaN, positive, zero payload
fn fp_default_nan(kind: i64) -> u64, u64 {
    let f = fp_fmt(kind);
    let fb = f.p - 1;
    if f.total <= 64 {
        let emask: u64 = ((1 as u64) << f.ebits) - 1;
        return (emask << fb) | ((1 as u64) << (fb - 1)), 0;
    }
    if kind == TK_X86_FP80 { return 0xC000000000000000, 0x7FFF; }
    return 0, (0x7FFF as u64) << 48 | ((1 as u64) << 47);
}

// makeQuiet(): set the quiet bit of a NaN
fn fp_make_quiet(kind: i64, lo: u64, hi: u64) -> u64, u64 {
    let f = fp_fmt(kind);
    let qb = f.p - 2;
    if f.total <= 64 { return lo | ((1 as u64) << qb), hi; }
    if kind == TK_X86_FP80 { return lo | ((1 as u64) << 62), hi; }
    return lo, hi | ((1 as u64) << (qb - 64));
}
fn fp_is_signaling_bits(kind: i64, lo: u64, hi: u64) -> bool {
    let p = fp_decompose(kind, lo, hi);
    if p.cat != FC_NAN { return false; }
    let f = fp_fmt(kind);
    let qb = f.p - 2;
    if kind == TK_X86_FP80 { return ((lo >> 62) & 1) == 0; }
    if f.total <= 64 { return ((lo >> qb) & 1) == 0; }
    return ((hi >> (qb - 64)) & 1) == 0;
}
fn fp_neg_bits(kind: i64, lo: u64, hi: u64) -> u64, u64 {
    let f = fp_fmt(kind);
    if f.total <= 64 { return lo ^ ((1 as u64) << (f.total - 1)), hi; }
    if kind == TK_X86_FP80 { return lo, hi ^ 0x8000; }
    return lo, hi ^ 0x8000000000000000;
}
fn fp_with_sign(kind: i64, lo: u64, hi: u64, neg: bool) -> u64, u64 {
    let p = fp_decompose(kind, lo, hi);
    if p.neg == neg { return lo, hi; }
    return fp_neg_bits(kind, lo, hi);
}

// significand as a bignum and the exponent of its lowest bit: value = sig * 2^e2
fn fp_sig_bn(p: FpParts, f: FpFmt, out: u32[>..<]&) -> i64 {
    if f.explicit_int { bn_from_words(out, [p.sig0]); }
    else { bn_from_words(out, [p.sig0, p.sig1]); }
    return p.exponent - (f.p - 1);
}

// APFloat binary operation with rmNearestTiesToEven
fn fp_arith(kind: i64, o: i64, alo: u64, ahi: u64, blo: u64, bhi: u64) -> u64, u64 {
    let f = fp_fmt(kind);
    let a = fp_decompose(kind, alo, ahi);
    let b = fp_decompose(kind, blo, bhi);
    // NaN propagation (all ops): the first NaN operand (LHS first), quieted; its own sign
    if a.cat == FC_NAN { return fp_make_quiet(kind, alo, ahi); }
    if b.cat == FC_NAN {
        // subtract keeps the RHS NaN's sign (assign(rhs) without negation); multiply/divide restore it too
        return fp_make_quiet(kind, blo, bhi);
    }
    if o == FOP_ADD || o == FOP_SUB {
        let sub = o == FOP_SUB;
        let bneg = b.neg != sub;   // effective sign of the RHS
        if a.cat == FC_INF && b.cat == FC_INF {
            if a.neg != bneg { return fp_default_nan(kind); }
            return alo, ahi;
        }
        if a.cat == FC_INF { return alo, ahi; }
        if b.cat == FC_INF { return fp_encode(kind, bneg, 0, 0, 0, true); }
        if a.cat == FC_ZERO && b.cat == FC_ZERO {
            // like-signed zeros keep the sign; otherwise +0 (round to nearest)
            if a.neg == bneg { return fp_encode(kind, a.neg, 0, 0, 0, false); }
            return fp_encode(kind, false, 0, 0, 0, false);
        }
        if b.cat == FC_ZERO { return alo, ahi; }
        if a.cat == FC_ZERO { return fp_with_sign(kind, blo, bhi, bneg); }
        var sa: u32[>..<] = [];
        var sb: u32[>..<] = [];
        let ea = fp_sig_bn(a, f, sa);
        let eb = fp_sig_bn(b, f, sb);
        let e = min(ea, eb);
        bn_shl(sa, ea - e);
        bn_shl(sb, eb - e);
        var num: u32[>..<] = [];
        var neg = false;
        if a.neg == bneg {
            // same sign: add magnitudes
            bn_copy(num, sa);
            bn_add_bn(num, sb);
            neg = a.neg;
        } else {
            let c = bn_cmp(sa, sb);
            if c == 0 { return fp_encode(kind, false, 0, 0, 0, false); }
            if c > 0 { bn_copy(num, sa); bn_sub(num, sb); neg = a.neg; }
            else { bn_copy(num, sb); bn_sub(num, sa); neg = bneg; }
        }
        var den: u32[>..<] = [];
        bn_set_u64(den, 1);
        if e >= 0 { bn_shl(num, e); } else { bn_shl(den, -e); }
        return fp_round_rational(kind, neg, num, den);
    }
    if o == FOP_MUL {
        let neg = a.neg != b.neg;
        if (a.cat == FC_ZERO && b.cat == FC_INF) || (a.cat == FC_INF && b.cat == FC_ZERO) { return fp_default_nan(kind); }
        if a.cat == FC_INF || b.cat == FC_INF { return fp_encode(kind, neg, 0, 0, 0, true); }
        if a.cat == FC_ZERO || b.cat == FC_ZERO { return fp_encode(kind, neg, 0, 0, 0, false); }
        var sa: u32[>..<] = [];
        var sb: u32[>..<] = [];
        let ea = fp_sig_bn(a, f, sa);
        let eb = fp_sig_bn(b, f, sb);
        var num: u32[>..<] = [];
        bn_mul(sa, sb, num);
        var den: u32[>..<] = [];
        bn_set_u64(den, 1);
        let e = ea + eb;
        if e >= 0 { bn_shl(num, e); } else { bn_shl(den, -e); }
        return fp_round_rational(kind, neg, num, den);
    }
    if o == FOP_DIV {
        let neg = a.neg != b.neg;
        if (a.cat == FC_INF && b.cat == FC_INF) || (a.cat == FC_ZERO && b.cat == FC_ZERO) { return fp_default_nan(kind); }
        if a.cat == FC_INF { return fp_encode(kind, neg, 0, 0, 0, true); }
        if b.cat == FC_INF { return fp_encode(kind, neg, 0, 0, 0, false); }
        if a.cat == FC_ZERO { return fp_encode(kind, neg, 0, 0, 0, false); }
        if b.cat == FC_ZERO { return fp_encode(kind, neg, 0, 0, 0, true); }
        var sa: u32[>..<] = [];
        var sb: u32[>..<] = [];
        let ea = fp_sig_bn(a, f, sa);
        let eb = fp_sig_bn(b, f, sb);
        let e = ea - eb;
        if e >= 0 { bn_shl(sa, e); } else { bn_shl(sb, -e); }
        return fp_round_rational(kind, neg, sa, sb);
    }
    if o == FOP_MOD {
        // fmod: exact remainder with the sign of the dividend
        if a.cat == FC_INF || b.cat == FC_ZERO { return fp_default_nan(kind); }
        if a.cat == FC_ZERO || b.cat == FC_INF { return alo, ahi; }
        var sa: u32[>..<] = [];
        var sb: u32[>..<] = [];
        let ea = fp_sig_bn(a, f, sa);
        let eb = fp_sig_bn(b, f, sb);
        let e = min(ea, eb);
        bn_shl(sa, ea - e);
        bn_shl(sb, eb - e);
        var qq: u32[>..<] = [];
        var rr: u32[>..<] = [];
        bn_divmod(sa, sb, qq, rr);
        if bn_is_zero(rr) { return fp_encode(kind, a.neg, 0, 0, 0, false); }
        var den: u32[>..<] = [];
        bn_set_u64(den, 1);
        if e >= 0 { bn_shl(rr, e); } else { bn_shl(den, -e); }
        return fp_round_rational(kind, a.neg, rr, den);
    }
    fatal("internal: fp_arith opcode");
    return 0, 0;
}

// a += b for bignums
fn bn_add_bn(a: u32[>..<]&, b: u32[>..<]&) {
    var carry: u64 = 0;
    let n = max(a.len, b.len);
    while a.len < n { a.push(0); }
    for i in n {
        let x = (a[i] as u64) + (if i < b.len { b[i] as u64 } else { 0 }) + carry;
        a[i] = (x & 0xFFFFFFFF) as u32;
        carry = x >> 32;
    }
    if carry != 0 { a.push(carry as u32); }
}

// APFloat::compare: 0 less, 1 equal, 2 greater, 3 unordered
fn fp_compare(kind: i64, alo: u64, ahi: u64, blo: u64, bhi: u64) -> i64 {
    let a = fp_decompose(kind, alo, ahi);
    let b = fp_decompose(kind, blo, bhi);
    if a.cat == FC_NAN || b.cat == FC_NAN { return 3; }
    if a.cat == FC_ZERO && b.cat == FC_ZERO { return 1; }
    // sign handling
    let aneg = a.neg && a.cat != FC_ZERO;
    let bneg = b.neg && b.cat != FC_ZERO;
    if a.cat == FC_ZERO { return if bneg { 2 } else { 0 }; }
    if b.cat == FC_ZERO { return if aneg { 0 } else { 2 }; }
    if aneg != bneg { return if aneg { 0 } else { 2 }; }
    var mag: i64 = 1;
    if a.cat == FC_INF && b.cat == FC_INF { mag = 1; }
    else if a.cat == FC_INF { mag = 2; }
    else if b.cat == FC_INF { mag = 0; }
    else if a.exponent != b.exponent { mag = if a.exponent > b.exponent { 2 } else { 0 }; }
    else if a.sig1 != b.sig1 { mag = if a.sig1 > b.sig1 { 2 } else { 0 }; }
    else if a.sig0 != b.sig0 { mag = if a.sig0 > b.sig0 { 2 } else { 0 }; }
    if aneg && mag != 1 { mag = 2 - mag; }
    return mag;
}

// FCmpInst::compare(APFloat, APFloat, Pred)
fn fp_fcmp(kind: i64, p: i64, alo: u64, ahi: u64, blo: u64, bhi: u64) -> bool {
    let r = fp_compare(kind, alo, ahi, blo, bhi);
    let lt = r == 0;
    let eq = r == 1;
    let gt = r == 2;
    let un = r == 3;
    return match p {
        0 => false, 1 => eq, 2 => gt, 3 => gt || eq, 4 => lt, 5 => lt || eq, 6 => lt || gt, 7 => !un,
        8 => un, 9 => un || eq, 10 => un || gt, 11 => un || gt || eq, 12 => un || lt, 13 => un || lt || eq,
        14 => !eq, _ => true,
    };
}

// The bits of `d` (a host double) converted into `kind` with round to nearest even (ConstantFP::get(Ty, double))
fn fp_from_f64(kind: i64, d: f64) -> u64, u64 {
    let bits = binary::bits_of_f64(d);
    if kind == TK_DOUBLE { return bits, 0; }
    return fp_convert(TK_DOUBLE, kind, bits, 0);
}

// APFloat::isLargest (largest finite magnitude)
fn fp_is_largest(kind: i64, lo: u64, hi: u64) -> bool {
    let p = fp_decompose(kind, lo, hi);
    if p.cat != FC_NORMAL { return false; }
    let f = fp_fmt(kind);
    if p.exponent != f.bias { return false; }
    // all significand bits set
    if f.p <= 64 {
        let m: u64 = if f.p == 64 { 0xFFFFFFFFFFFFFFFF } else { ((1 as u64) << f.p) - 1 };
        return p.sig0 == m;
    }
    let mh: u64 = ((1 as u64) << (f.p - 64)) - 1;
    return p.sig0 == 0xFFFFFFFFFFFFFFFF && p.sig1 == mh;
}
