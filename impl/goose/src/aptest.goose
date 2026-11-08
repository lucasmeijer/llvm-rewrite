// Test driver for apint.goose (tools/aptest.py): reads "op w a b" lines (a, b hex) on stdin, prints results.
import std;
import os;
import binary;
import apint;

fn hexval(c: u8) -> u64 { if c >= '0' && c <= '9' { (c - '0') as u64 } else { (c - 'a' + 10) as u64 } }
fn parse_hex(s: const u8[:], w: i64) -> AP {
    var ws: u64[>..] = [];
    for k in ap_nw(w) { ws.push(0); }
    var bit: i64 = 0;
    var i = s.len - 1;
    while i >= 0 {
        let d = hexval(s[i]);
        if bit / 64 < ws.len { ws[bit / 64] = ws[bit / 64] | (d << (bit % 64)); }
        bit = bit + 4;
        i--;
    }
    return ap_from_words(w, ws);
}
fn put_hex(out: u8[>..]&, a: AP) {
    let n = ap_nwords(a);
    var started = false;
    var k = n - 1;
    while k >= 0 {
        let x = ap_word(a, k);
        var j: i64 = 15;
        while j >= 0 {
            let d = (x >> (4 * j)) & 15;
            if d != 0 || started || (k == 0 && j == 0) {
                started = true;
                out.push(if d < 10 { ('0' + d as! u8) } else { ('a' + (d - 10) as! u8) });
            }
            j--;
        }
        k--;
    }
}
fn main() {
    var all: u8[>..] = [];
    read_stdin(all);
    var out: u8[>..] = [];
    var p: i64 = 0;
    while p < all.len {
        var e = p;
        while e < all.len && all[e] != '\n' { e++; }
        // fields
        var f: i64[..8] = [];
        var q = p;
        f.push(q);
        while q < e { if all[q] == ' ' { f.push(q + 1); } q++; }
        let op = all[f[0]..f[1] - 1];
        let wv, ok = parse_int(all[f[1]..f[2] - 1]);
        let w = wv;
        let a = parse_hex(all[f[2]..f[3] - 1], w);
        let b = parse_hex(all[f[3]..e], w);
        let s = ap_lo64(b) as i64;
        if op == "add" { put_hex(out, ap_add(a, b)); }
        else if op == "sub" { put_hex(out, ap_sub(a, b)); }
        else if op == "mul" { put_hex(out, ap_mul(a, b)); }
        else if op == "udiv" { put_hex(out, ap_udiv(a, b)); }
        else if op == "urem" { put_hex(out, ap_urem(a, b)); }
        else if op == "sdiv" { put_hex(out, ap_sdiv(a, b)); }
        else if op == "srem" { put_hex(out, ap_srem(a, b)); }
        else if op == "shl" { put_hex(out, ap_shl(a, s)); }
        else if op == "lshr" { put_hex(out, ap_lshr(a, s)); }
        else if op == "ashr" { put_hex(out, ap_ashr(a, s)); }
        else if op == "rotl" { put_hex(out, ap_rotl(a, s)); }
        else if op == "rotr" { put_hex(out, ap_rotr(a, s)); }
        else if op == "and" { put_hex(out, ap_and(a, b)); }
        else if op == "or" { put_hex(out, ap_or(a, b)); }
        else if op == "xor" { put_hex(out, ap_xor(a, b)); }
        else if op == "not" { put_hex(out, ap_not(a)); }
        else if op == "neg" { put_hex(out, ap_neg(a)); }
        else if op == "ult" { out.append(if ap_ult(a, b) { "1" } else { "0" }); }
        else if op == "slt" { out.append(if ap_slt(a, b) { "1" } else { "0" }); }
        else if op == "clz" { out.append(str(ap_countl_zero(a))); }
        else if op == "clo" { out.append(str(ap_countl_one(a))); }
        else if op == "ctz" { out.append(str(ap_countr_zero(a))); }
        else if op == "cto" { out.append(str(ap_countr_one(a))); }
        else if op == "pop" { out.append(str(ap_popcount(a))); }
        else if op == "sext" { put_hex(out, ap_sext(ap_trunc(a, s), w)); }
        else if op == "bswap" { put_hex(out, ap_byte_swap(a)); }
        else if op == "brev" { put_hex(out, ap_reverse_bits(a)); }
        else if op == "umulov" { let r, o = ap_umul_ov(a, b); put_hex(out, r); out.append(if o { " 1" } else { " 0" }); }
        else if op == "smulov" { let r, o = ap_smul_ov(a, b); put_hex(out, r); out.append(if o { " 1" } else { " 0" }); }
        else if op == "dec" { ap_format(out, a, false); }
        else if op == "sdec" { ap_format(out, a, true); }
        else { out.append("?"); }
        out.push('\n');
        p = e + 1;
    }
    write_stdout(out);
}
