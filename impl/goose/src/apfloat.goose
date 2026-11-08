// IEEE floating point formats for printing/parsing constants.
// Ported from llvm/lib/Support/APFloat.cpp (IEEEFloat::toString / toStringImpl / AdjustToPrecision)
// and llvm/lib/IR/AsmWriter.cpp (writeAPFloatInternal). Values are kept as raw bit patterns (lo, hi).
import std;
import ir;
import bignum;

struct FpFmt { total: i64, p: i64, ebits: i64, bias: i64, explicit_int: bool }

fn fp_fmt(kind: i64) -> FpFmt {
    if kind == TK_HALF { return FpFmt { total: 16, p: 11, ebits: 5, bias: 15, explicit_int: false }; }
    if kind == TK_BFLOAT { return FpFmt { total: 16, p: 8, ebits: 8, bias: 127, explicit_int: false }; }
    if kind == TK_FLOAT { return FpFmt { total: 32, p: 24, ebits: 8, bias: 127, explicit_int: false }; }
    if kind == TK_DOUBLE { return FpFmt { total: 64, p: 53, ebits: 11, bias: 1023, explicit_int: false }; }
    if kind == TK_X86_FP80 { return FpFmt { total: 80, p: 64, ebits: 15, bias: 16383, explicit_int: true }; }
    if kind == TK_FP128 { return FpFmt { total: 128, p: 113, ebits: 15, bias: 16383, explicit_int: false }; }
    fatal("unsupported floating-point type (ppc_fp128)");
    return FpFmt { total: 0, p: 0, ebits: 0, bias: 0, explicit_int: false };
}

let FC_ZERO = 0;
let FC_NORMAL = 1;
let FC_INF = 2;
let FC_NAN = 3;

// Decomposed value: category, sign, significand words (sig0 low 64 bits, sig1 high), exponent of the MSB position
// (value = sig * 2^(exponent - (p-1))).
struct FpParts { cat: i64, neg: bool, sig0: u64, sig1: u64, exponent: i64, expf: i64 }

fn fp_decompose(kind: i64, lo: u64, hi: u64) -> FpParts {
    let f = fp_fmt(kind);
    var r = FpParts { cat: FC_ZERO, neg: false, sig0: 0, sig1: 0, exponent: 0, expf: 0 };
    let emask: i64 = (1 << f.ebits) - 1;
    var frac0: u64 = 0;
    var frac1: u64 = 0;
    var expf: i64 = 0;
    if f.total <= 64 {
        let fb = f.p - 1;
        r.neg = ((lo >> (f.total - 1)) & 1) != 0;
        expf = ((lo >> fb) as! i64) & emask;
        frac0 = lo & ((1 << fb) - 1);
    } else if kind == TK_X86_FP80 {
        r.neg = ((hi >> 15) & 1) != 0;
        expf = (hi as! i64) & 0x7FFF;
        frac0 = lo & 0x7FFFFFFFFFFFFFFF;   // fraction without the explicit integer bit
    } else {
        r.neg = (hi >> 63) != 0;
        expf = ((hi >> 48) as! i64) & 0x7FFF;
        frac0 = lo;
        frac1 = hi & 0xFFFFFFFFFFFF;
    }
    r.expf = expf;
    let fzero = frac0 == 0 && frac1 == 0;
    if expf == emask {
        r.cat = if fzero { FC_INF } else { FC_NAN };
        r.sig0 = frac0;
        r.sig1 = frac1;
        return r;
    }
    if expf == 0 {
        if fzero && (kind != TK_X86_FP80 || (lo >> 63) == 0) { r.cat = FC_ZERO; return r; }
        r.cat = FC_NORMAL;
        r.sig0 = frac0;
        r.sig1 = frac1;
        if kind == TK_X86_FP80 { r.sig0 = lo; }
        r.exponent = 1 - f.bias;
        return r;
    }
    r.cat = FC_NORMAL;
    r.exponent = expf - f.bias;
    let fb = f.p - 1;
    if fb < 64 { r.sig0 = frac0 | ((1 as u64) << fb); r.sig1 = 0; }
    else { r.sig0 = frac0; r.sig1 = frac1 | ((1 as u64) << (fb - 64)); }
    if kind == TK_X86_FP80 { r.sig0 = lo; }
    return r;
}

// Encode sign, significand M (< 2^p; >= 2^(p-1) unless denormal) and MSB exponent E.
// denormal: M < 2^(p-1) means biased exponent 0.
fn fp_encode(kind: i64, neg: bool, m0: u64, m1: u64, e: i64, inf: bool) -> u64, u64 {
    let f = fp_fmt(kind);
    let emask: i64 = (1 << f.ebits) - 1;
    let fb = f.p - 1;
    var expf: i64 = 0;
    var fr0 = m0;
    var fr1 = m1;
    if inf {
        expf = emask;
        fr0 = 0;
        fr1 = 0;
    } else {
        let top = if fb < 64 { ((m0 >> fb) & 1) != 0 } else { ((m1 >> (fb - 64)) & 1) != 0 };
        if top { expf = e + f.bias; } else { expf = 0; }
        if !f.explicit_int {
            if fb < 64 { fr0 = m0 & ((1 << fb) - 1); } else { fr1 = m1 & ((1 << (fb - 64)) - 1); }
        }
    }
    let s: u64 = if neg { 1 } else { 0 };
    if f.total <= 64 {
        return (s << (f.total - 1)) | ((expf as! u64) << fb) | fr0, 0;
    }
    if kind == TK_X86_FP80 {
        var sig = fr0;
        if inf { sig = 0x8000000000000000; }
        return sig, (s << 15) | (expf as! u64);
    }
    return fr0, (s << 63) | ((expf as! u64) << 48) | fr1;
}

// Correctly rounded (nearest-even) value of num/den in `kind`. Returns bits.
fn fp_round_rational(kind: i64, neg: bool, num: u32[>..<]&, den: u32[>..<]&) -> u64, u64 {
    let f = fp_fmt(kind);
    let p = f.p;
    if bn_is_zero(num) { return fp_encode(kind, neg, 0, 0, 0, false); }
    let emin = 1 - f.bias;
    let emax = f.bias;
    // q = floor(num * 2^s / den) with p+3 bits or more
    var s = (p + 3) - (bn_active_bits(num) - bn_active_bits(den)) + 1;
    var n2: u32[>..<] = [];
    var d2: u32[>..<] = [];
    var q: u32[>..<] = [];
    var r: u32[>..<] = [];
    bn_copy(n2, num);
    bn_copy(d2, den);
    if s >= 0 { bn_shl(n2, s); } else { bn_shl(d2, -s); }
    bn_divmod(n2, d2, q, r);
    var sticky = !bn_is_zero(r);
    // value = q * 2^-s; msb exponent E
    var qb = bn_active_bits(q);
    var e = qb - 1 - s;
    // lsb exponent we keep
    var keep_lsb = e - (p - 1);
    if e < emin { keep_lsb = emin - (p - 1); }
    let drop = keep_lsb - (-s);       // number of low bits of q to drop
    var m: u32[>..<] = [];
    bn_copy(m, q);
    var half = false;
    if drop > 0 {
        half = bn_bit(q, drop - 1);
        for k in drop - 1 { if bn_bit(q, k) { sticky = true; } }
        bn_shr(m, drop);
    } else if drop < 0 {
        bn_shl(m, -drop);
    }
    var round_up = false;
    if half && (sticky || bn_bit(m, 0)) { round_up = true; }
    if round_up { bn_add_small(m, 1); }
    let mb = bn_active_bits(m);
    var ee = keep_lsb + (p - 1);
    if mb > p { bn_shr(m, 1); ee += 1; }
    // denormal stays at emin with top bit clear
    if bn_active_bits(m) < p { ee = emin; }
    if ee > emax { return fp_encode(kind, neg, 0, 0, 0, true); }
    if bn_is_zero(m) { return fp_encode(kind, neg, 0, 0, 0, false); }
    return fp_encode(kind, neg, bn_word(m, 0), bn_word(m, 1), ee, false);
}

// Parse a decimal string ([-+]?digits[.digits][e[-+]digits]) correctly rounded into kind.
fn fp_parse_decimal(kind: i64, s: const u8[:]) -> u64, u64, bool {
    var i = 0;
    var neg = false;
    if i < s.len && (s[i] == '-' || s[i] == '+') { neg = s[i] == '-'; i++; }
    var d: u32[>..<] = [];
    var e10: i64 = 0;
    var any = false;
    while i < s.len && s[i] >= '0' && s[i] <= '9' { bn_mul_small(d, 10); bn_add_small(d, (s[i] - '0') as u32); i++; any = true; }
    if i < s.len && s[i] == '.' {
        i++;
        while i < s.len && s[i] >= '0' && s[i] <= '9' { bn_mul_small(d, 10); bn_add_small(d, (s[i] - '0') as u32); e10 -= 1; i++; any = true; }
    }
    if i < s.len && (s[i] == 'e' || s[i] == 'E') {
        i++;
        var eneg = false;
        if i < s.len && (s[i] == '-' || s[i] == '+') { eneg = s[i] == '-'; i++; }
        var ev: i64 = 0;
        while i < s.len && s[i] >= '0' && s[i] <= '9' { if ev < 100000 { ev = ev * 10 + (s[i] - '0') as i64; } i++; }
        e10 += if eneg { -ev } else { ev };
    }
    if !any || i != s.len { return 0, 0, false; }
    var den: u32[>..<] = [];
    bn_set_u64(den, 1);
    if e10 >= 0 { bn_mul_pow10(d, e10); } else { bn_mul_pow10(den, -e10); }
    let lo, hi = fp_round_rational(kind, neg, d, den);
    return lo, hi, true;
}

// Convert bits of one format to another (round to nearest even), like APFloat::convert.
fn fp_convert(from: i64, to: i64, lo: u64, hi: u64) -> u64, u64 {
    let p = fp_decompose(from, lo, hi);
    let ff = fp_fmt(from);
    if p.cat == FC_ZERO { return fp_encode(to, p.neg, 0, 0, 0, false); }
    if p.cat == FC_INF { return fp_encode(to, p.neg, 0, 0, 0, true); }
    if p.cat == FC_NAN {
        // keep the payload's top bits (quiet bit first), like APFloat::convert does for NaNs
        let tf = fp_fmt(to);
        let fbf = ff.p - 1;
        let fbt = tf.p - 1;
        var num: u32[>..<] = [];
        bn_from_words(num, [p.sig0, p.sig1]);
        if ff.explicit_int { bn_from_words(num, [p.sig0 & 0x7FFFFFFFFFFFFFFF]); }
        if fbt >= fbf { bn_shl(num, fbt - fbf); } else { bn_shr(num, fbf - fbt); }
        if bn_is_zero(num) { bn_set_u64(num, 1); bn_shl(num, fbt - 1); }
        let emask: u64 = (1 << tf.ebits) - 1;
        let s: u64 = if p.neg { 1 } else { 0 };
        if tf.total <= 64 { return (s << (tf.total - 1)) | (emask << fbt) | bn_word(num, 0), 0; }
        if to == TK_X86_FP80 { return bn_word(num, 0) | 0x8000000000000000, (s << 15) | emask; }
        return bn_word(num, 0), (s << 63) | (emask << 48) | bn_word(num, 1);
    }
    var num: u32[>..<] = [];
    var den: u32[>..<] = [];
    bn_from_words(num, [p.sig0, p.sig1]);
    bn_set_u64(den, 1);
    let e2 = p.exponent - (ff.p - 1);
    if e2 >= 0 { bn_shl(num, e2); } else { bn_shl(den, -e2); }
    return fp_round_rational(to, p.neg, num, den);
}

fn hexdig(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return (c - '0') as i64; }
    if c >= 'a' && c <= 'f' { return (c - 'a') as i64 + 10; }
    if c >= 'A' && c <= 'F' { return (c - 'A') as i64 + 10; }
    return -1;
}

fn write_hex_fixed(out: u8[>..]&, ws: const u64[:], bits: i64) {
    let nd = max((bits + 3) / 4, 1);
    var i = nd;
    while i > 0 {
        i--;
        let w = ws[(i * 4) / 64];
        let d = (w >> ((i * 4) % 64)) & 15;
        out.push("0123456789ABCDEF"[d]);
    }
}

// AdjustToPrecision for the decimal digit buffer (least significant digit first).
fn adjust_digits(buf: u8[>..<]&, exp: i64&, prec: i64) {
    let n = buf.len;
    if n <= prec { return; }
    var first = n - prec;
    if buf[first - 1] < '5' {
        while first < n && buf[first] == '0' { first++; }
        exp += first;
        for k in n - first { buf[k] = buf[k + first]; }
        buf.resize(n - first);
        return;
    }
    var i = first;
    while i != n {
        if buf[i] == '9' { first++; } else { buf[i] += 1; break; }
        i++;
    }
    if first == n {
        exp += first;
        buf.clear();
        buf.push('1');
        return;
    }
    exp += first;
    for k in n - first { buf[k] = buf[k + first]; }
    buf.resize(n - first);
}

// writeAPFloatInternal
fn write_apfloat(out: u8[>..]&, kind: i64, lo: u64, hi: u64) {
    if kind == TK_PPC_FP128 { write_ppc_fp128(out, lo, hi); return; }
    write_apfloat_ieee(out, kind, lo, hi);
}

fn write_ppc_fp128(out: u8[>..]&, lo: u64, hi: u64) {
    if true {
        // double-double: lo = first (high) double, hi = second. writeAPFloatInternal forces bitwise output when
        // the second double is nonzero; otherwise the value is the first double, and the decimal string must
        // round-trip in the 106-bit legacy semantics (checked here with fp128's 113 bits).
        if hi == 0 {
            let p = fp_decompose(TK_DOUBLE, lo, 0);
            if p.cat == FC_INF || p.cat == FC_NAN || p.cat == FC_ZERO { write_apfloat_ieee(out, TK_DOUBLE, lo, 0); return; }
            var tmp: u8[>..] = [];
            write_apfloat_ieee(tmp, TK_DOUBLE, lo, 0);
            if tmp[0] != 'f' {
                let ql, qh, ok = fp_parse_decimal(TK_FP128, tmp);
                let el, eh = fp_convert(TK_DOUBLE, TK_FP128, lo, 0);
                if ok && ql == el && qh == eh { out.append(tmp); return; }
            }
        }
        out.append("f0x");
        write_hex_fixed(out, [lo, hi], 128);
        return;
    }
}

fn write_apfloat_ieee(out: u8[>..]&, kind: i64, lo: u64, hi: u64) {
    let f = fp_fmt(kind);
    let p = fp_decompose(kind, lo, hi);
    if p.cat == FC_INF {
        out.append(if p.neg { "-inf" } else { "+inf" });
        return;
    }
    if p.cat == FC_NAN {
        out.push(if p.neg { '-' } else { '+' });
        // payload: fraction field (p-1 bits); quiet bit is its top bit
        let fb = f.p - 1;
        var pl0 = p.sig0;
        var pl1 = p.sig1;
        if f.explicit_int { pl0 = pl0 & 0x7FFFFFFFFFFFFFFF; }
        let qb = fb - 1;
        let quiet = if qb < 64 { ((pl0 >> qb) & 1) != 0 } else { ((pl1 >> (qb - 64)) & 1) != 0 };
        var rest0 = pl0;
        var rest1 = pl1;
        if qb < 64 { rest0 = rest0 & ~((1 as u64) << qb); } else { rest1 = rest1 & ~((1 as u64) << (qb - 64)); }
        if quiet && rest0 == 0 && rest1 == 0 { out.append("qnan"); return; }
        if !quiet { out.push('s'); }
        out.append("nan(0x");
        var a: u32[>..<] = [];
        bn_from_words(a, [rest0, rest1]);
        let ab = bn_active_bits(a);
        write_hex_fixed(out, [rest0, rest1], ab);
        out.push(')');
        return;
    }
    // toString(6, 0, false)
    var s: u8[>..] = [];
    var dig: u32[>..<] = [];
    var dexp: i64 = 0;
    if p.cat == FC_ZERO {
        if p.neg { s.push('-'); }
        s.append("0.000000e+00");
    } else {
        if p.neg { s.push('-'); }
        var exp = p.exponent - (f.p - 1);
        var sig: u32[>..<] = [];
        bn_from_words(sig, [p.sig0, p.sig1]);
        let tz = bn_ctz(sig);
        exp += tz;
        bn_shr(sig, tz);
        if exp > 0 {
            bn_shl(sig, exp);
            exp = 0;
        } else if exp < 0 {
            bn_mul_pow5(sig, -exp);
        }
        // AdjustToPrecision (APInt)
        let bits = bn_active_bits(sig);
        let req = (6 * 196 + 58) / 59;
        if bits > req {
            var tr = (bits - req) * 59 / 196;
            if tr > 0 {
                exp += tr;
                while tr >= 9 { bn_divmod_small(sig, 1000000000); tr -= 9; }
                var dv: u32 = 1;
                for k in tr { dv *= 10; }
                if dv != 1 { bn_divmod_small(sig, dv); }
            }
        }
        var buf: u8[>..<] = [];
        var in_trail = true;
        while !bn_is_zero(sig) {
            let d = bn_divmod_small(sig, 10);
            if in_trail && d == 0 { exp++; }
            else { buf.push('0' + d as! u8); in_trail = false; }
        }
        adjust_digits(buf, exp, 6);
        let nd = buf.len;
        // remember the exact decimal value: digits * 10^exp
        for k in nd { bn_mul_small(dig, 10); bn_add_small(dig, (buf[nd - 1 - k] - '0') as u32); }
        dexp = exp;
        exp += nd - 1;
        s.push(buf[nd - 1]);
        s.push('.');
        for k in 1..nd { s.push(buf[nd - 1 - k]); }
        if 6 > nd - 1 { for k in 6 - nd + 1 { s.push('0'); } }
        s.push('e');
        s.push(if exp >= 0 { '+' } else { '-' });
        var ae = if exp < 0 { -exp } else { exp };
        var eb: u8[>..<] = [];
        loop { eb.push('0' + (ae % 10) as! u8); ae /= 10; if ae == 0 { break; } }
        if eb.len < 2 { eb.push('0'); }
        var j = eb.len;
        while j > 0 { j--; s.push(eb[j]); }
    }
    // Round-trip check: does the decimal string parse back to the same value?
    var ok = true;
    if p.cat == FC_NORMAL {
        var den: u32[>..<] = [];
        bn_set_u64(den, 1);
        if dexp >= 0 { bn_mul_pow10(dig, dexp); } else { bn_mul_pow10(den, -dexp); }
        let rl, rh = fp_round_rational(kind, p.neg, dig, den);
        ok = rl == lo && (f.total <= 64 || (if kind == TK_X86_FP80 { (rh & 0xFFFF) == (hi & 0xFFFF) } else { rh == hi }));
    }
    if ok { out.append(s); return; }
    out.append("f0x");
    write_hex_fixed(out, [lo, hi], f.total);
}
