// Arbitrary-precision unsigned integers as little-endian u32 limbs (enough for APInt printing/parsing
// and for APFloat::toString's exact decimal conversion in llvm/lib/Support/APFloat.cpp).
import std;

fn bn_trim(a: u32[>..<]&) {
    while a.len > 0 && a[a.len - 1] == 0 { a.pop(); }
}

fn bn_set_u64(a: u32[>..<]&, v: u64) {
    a.clear();
    a.push((v & 0xFFFFFFFF) as! u32);
    a.push((v >> 32) as! u32);
    bn_trim(a);
}

fn bn_is_zero(a: u32[>..<]&) -> bool {
    for x in a { if x != 0 { return false; } }
    return true;
}

fn bn_mul_small(a: u32[>..<]&, m: u32) {
    var carry: u64 = 0;
    for &x in a {
        let p = (x as u64) * (m as u64) + carry;
        x = (p & 0xFFFFFFFF) as! u32;
        carry = p >> 32;
    }
    if carry != 0 { a.push(carry as! u32); }
}

fn bn_add_small(a: u32[>..<]&, v: u32) {
    var carry: u64 = v;
    for &x in a {
        if carry == 0 { break; }
        let s = (x as u64) + carry;
        x = (s & 0xFFFFFFFF) as! u32;
        carry = s >> 32;
    }
    if carry != 0 { a.push(carry as! u32); }
}

// a /= d, returns the remainder.
fn bn_divmod_small(a: u32[>..<]&, d: u32) -> u32 {
    var rem: u64 = 0;
    var i = a.len;
    while i > 0 {
        i--;
        let cur = (rem << 32) | (a[i] as u64);
        a[i] = (cur / (d as u64)) as! u32;
        rem = cur % (d as u64);
    }
    bn_trim(a);
    return rem as! u32;
}

// out = a * b
fn bn_mul(a: u32[>..<]&, b: u32[>..<]&, out: u32[>..<]&) {
    out.clear();
    out.resize(a.len + b.len + 1, 0);
    for i in a.len {
        var carry: u64 = 0;
        let ai = a[i] as u64;
        for j in b.len {
            let cur = (out[i + j] as u64) + ai * (b[j] as u64) + carry;
            out[i + j] = (cur & 0xFFFFFFFF) as! u32;
            carry = cur >> 32;
        }
        var k = i + b.len;
        while carry != 0 {
            let cur = (out[k] as u64) + carry;
            out[k] = (cur & 0xFFFFFFFF) as! u32;
            carry = cur >> 32;
            k++;
        }
    }
    bn_trim(out);
}

fn bn_copy(dst: u32[>..<]&, src: u32[>..<]&) {
    dst.clear();
    for x in src { dst.push(x); }
}

fn bn_shl(a: u32[>..<]&, k: i64) {
    if k <= 0 || a.len == 0 { return; }
    let limbs = k / 32;
    let bits = k % 32;
    if bits != 0 {
        var carry: u32 = 0;
        for &x in a {
            let nx = (x << bits) | carry;
            carry = x >> (32 - bits);
            x = nx;
        }
        if carry != 0 { a.push(carry); }
    }
    if limbs > 0 {
        let n = a.len;
        a.resize(n + limbs, 0);
        var i = n;
        while i > 0 { i--; a[i + limbs] = a[i]; }
        for j in limbs { a[j] = 0; }
    }
}

fn bn_shr(a: u32[>..<]&, k: i64) {
    if k <= 0 { return; }
    let limbs = k / 32;
    let bits = k % 32;
    if limbs >= a.len { a.clear(); return; }
    let n = a.len - limbs;
    for i in n { a[i] = a[i + limbs]; }
    a.resize(n);
    if bits != 0 {
        for i in n {
            let hi: u32 = if i + 1 < n { a[i + 1] << (32 - bits) } else { 0 };
            a[i] = (a[i] >> bits) | hi;
        }
    }
    bn_trim(a);
}

fn bn_cmp(a: u32[>..<]&, b: u32[>..<]&) -> i64 {
    bn_trim(a);
    bn_trim(b);
    if a.len != b.len { return if a.len < b.len { -1 } else { 1 }; }
    var i = a.len;
    while i > 0 {
        i--;
        if a[i] != b[i] { return if a[i] < b[i] { -1 } else { 1 }; }
    }
    return 0;
}

fn bn_active_bits(a: u32[>..<]&) -> i64 {
    bn_trim(a);
    if a.len == 0 { return 0; }
    let top = a[a.len - 1] as u64;
    return (a.len - 1) * 32 + (64 - clz(top));
}

fn bn_ctz(a: u32[>..<]&) -> i64 {
    for x, i in a { if x != 0 { return i * 32 + ctz(x as u64); } }
    return 0;
}

fn bn_bit(a: u32[>..<]&, k: i64) -> bool {
    let l = k / 32;
    if l >= a.len { return false; }
    return ((a[l] >> (k % 32)) & 1) != 0;
}

// a = a * 10^k
fn bn_mul_pow10(a: u32[>..<]&, k: i64) {
    var r = k;
    while r >= 9 { bn_mul_small(a, 1000000000); r -= 9; }
    var m: u32 = 1;
    for i in r { m *= 10; }
    if m != 1 { bn_mul_small(a, m); }
}

// a = a * 5^k
fn bn_mul_pow5(a: u32[>..<]&, k: i64) {
    var r = k;
    while r >= 13 { bn_mul_small(a, 1220703125); r -= 13; }
    var m: u32 = 1;
    for i in r { m *= 5; }
    if m != 1 { bn_mul_small(a, m); }
}

// Appends the decimal digits of a (destroys a).
fn bn_format_dec(out: u8[>..]&, a: u32[>..<]&) {
    bn_trim(a);
    if a.len == 0 { out.push('0'); return; }
    var digs: u8[>..<] = [];
    while a.len > 0 {
        var r = bn_divmod_small(a, 1000000000);
        if a.len == 0 {
            while r > 0 { digs.push(('0' + (r % 10) as! u8)); r /= 10; }
        } else {
            for k in 9 { digs.push(('0' + (r % 10) as! u8)); r /= 10; }
        }
    }
    var i = digs.len;
    while i > 0 { i--; out.push(digs[i]); }
}

// From/to u64 words (little-endian).
fn bn_from_words(a: u32[>..<]&, ws: const u64[:]) {
    a.clear();
    for w in ws { a.push((w & 0xFFFFFFFF) as! u32); a.push((w >> 32) as! u32); }
    bn_trim(a);
}

fn bn_word(a: u32[>..<]&, k: i64) -> u64 {
    let lo: u64 = if 2 * k < a.len { a[2 * k] as u64 } else { 0 };
    let hi: u64 = if 2 * k + 1 < a.len { a[2 * k + 1] as u64 } else { 0 };
    return lo | (hi << 32);
}

// a -= b (requires a >= b)
fn bn_sub(a: u32[>..<]&, b: u32[>..<]&) {
    var borrow: i64 = 0;
    for i in a.len {
        var d = (a[i] as i64) - borrow - (if i < b.len { b[i] as i64 } else { 0 });
        if d < 0 { d += 4294967296; borrow = 1; } else { borrow = 0; }
        a[i] = d as! u32;
    }
    bn_trim(a);
}

// q = num / den, r = num % den (binary long division).
fn bn_divmod(num: u32[>..<]&, den: u32[>..<]&, q: u32[>..<]&, r: u32[>..<]&) {
    q.clear();
    bn_copy(r, num);
    let nb = bn_active_bits(num);
    let db = bn_active_bits(den);
    if nb < db { return; }
    var sh: u32[>..<] = [];
    bn_copy(sh, den);
    var i = nb - db;
    bn_shl(sh, i);
    q.resize(i / 32 + 1, 0);
    loop {
        if bn_cmp(r, sh) >= 0 {
            bn_sub(r, sh);
            q[i / 32] = q[i / 32] | ((1 as u32) << (i % 32));
        }
        if i == 0 { break; }
        i--;
        bn_shr(sh, 1);
    }
    bn_trim(q);
}
