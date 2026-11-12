// MD5 (RFC 1321) as llvm/lib/Support/MD5.cpp computes it: update / final / stringifyResult, and MD5Hash
// (llvm/include/llvm/Support/MD5.h: the low 8 bytes of the digest, little endian). One hash at a time.
import std;

let MD5_S: const u32[64] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
let MD5_K: const u32[64] = [
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391];

var md5_a: u32 = 0;
var md5_b: u32 = 0;
var md5_c: u32 = 0;
var md5_d: u32 = 0;
var md5_buf: u8[64] = [0; 64];
var md5_nbuf: i64 = 0;
var md5_total: u64 = 0;
var md5_res: u8[16] = [0; 16];

fn md5_init() {
    md5_a = 0x67452301; md5_b = 0xefcdab89; md5_c = 0x98badcfe; md5_d = 0x10325476;
    md5_nbuf = 0; md5_total = 0;
}
fn md5_block() {
    var w: u32[16] = [0; 16];
    for i in 16 {
        w[i] = (md5_buf[i * 4] as u32) | ((md5_buf[i * 4 + 1] as u32) << 8) | ((md5_buf[i * 4 + 2] as u32) << 16) |
            ((md5_buf[i * 4 + 3] as u32) << 24);
    }
    var a = md5_a;
    var b = md5_b;
    var c = md5_c;
    var d = md5_d;
    for i in 64 {
        var f: u32 = 0;
        var g: i64 = 0;
        if i < 16 { f = (b & c) | ((~b) & d); g = i; }
        else if i < 32 { f = (d & b) | ((~d) & c); g = (5 * i + 1) % 16; }
        else if i < 48 { f = b ^ c ^ d; g = (3 * i + 5) % 16; }
        else { f = c ^ (b | (~d)); g = (7 * i) % 16; }
        let x = a + f + MD5_K[i] + w[g];
        let s = MD5_S[i];
        a = d; d = c; c = b;
        b = b + ((x << s) | (x >> (32 - s)));
    }
    md5_a = md5_a + a; md5_b = md5_b + b; md5_c = md5_c + c; md5_d = md5_d + d;
}
fn md5_update(data: const u8[:]) {
    for x in data {
        md5_buf[md5_nbuf] = x;
        md5_nbuf++;
        if md5_nbuf == 64 { md5_block(); md5_nbuf = 0; }
    }
    md5_total = md5_total + (data.len as u64);
}
fn md5_update_byte(x: u8) { let one: u8[1] = [x]; md5_update(one[..]); }
fn md5_final() {
    let bits = md5_total * 8;
    let n = if md5_nbuf < 56 { 56 - md5_nbuf } else { 120 - md5_nbuf };
    md5_update_byte(0x80);
    for k in n - 1 { md5_update_byte(0); }
    for i in 8 { md5_update_byte(((bits >> ((8 * i) as u64)) & 0xff) as u8); }
    let vs: u32[4] = [md5_a, md5_b, md5_c, md5_d];
    for k in 4 { for j in 4 { md5_res[k * 4 + j] = ((vs[k] >> ((8 * j) as u32)) & 0xff) as u8; } }
}
// MD5::stringifyResult: lower-case hex
fn md5_hex(out: u8[>..]&) {
    let hex = "0123456789abcdef";
    for i in 16 { out.push(hex[(md5_res[i] >> 4) as i64]); out.push(hex[(md5_res[i] & 15) as i64]); }
}
// MD5Hash(Str)
fn md5_hash_u64(s: const u8[:]) -> u64 {
    md5_init();
    md5_update(s);
    md5_final();
    var v: u64 = 0;
    for i in 8 { v = v | ((md5_res[i] as u64) << ((8 * i) as u64)); }
    return v;
}
