// MD5 (RFC 1321), as llvm/lib/Support/MD5.cpp computes it: update / final / stringifyResult.

Md5 :: struct {
    a: u32 = 0x67452301; b: u32 = 0xefcdab89; c: u32 = 0x98badcfe; d: u32 = 0x10325476;
    buf: [64] u8;
    nbuf: s64;
    total: u64;
}

MD5_S :: u32.[7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
              5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
              4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
              6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
MD5_K :: u32.[
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391];

md5_block :: (m: *Md5, p: *u8) {
    w: [16] u32;
    for i: 0..15 w[i] = (cast(u32) p[i*4]) | ((cast(u32) p[i*4+1]) << 8) | ((cast(u32) p[i*4+2]) << 16) | ((cast(u32) p[i*4+3]) << 24);
    a := m.a; b := m.b; c := m.c; d := m.d;
    for i: 0..63 {
        f: u32; g: s64;
        if i < 16 { f = (b & c) | ((~b) & d); g = i; }
        else if i < 32 { f = (d & b) | ((~d) & c); g = (5 * i + 1) % 16; }
        else if i < 48 { f = b ^ c ^ d; g = (3 * i + 5) % 16; }
        else { f = c ^ (b | (~d)); g = (7 * i) % 16; }
        x := a + f + MD5_K[i] + w[g];
        s := MD5_S[i];
        a = d; d = c; c = b;
        b = b + ((x << s) | (x >> (32 - s)));
    }
    m.a += a; m.b += b; m.c += c; m.d += d;
}

md5_update :: (m: *Md5, data: [] u8) {
    for data {
        m.buf[m.nbuf] = it;
        m.nbuf += 1;
        if m.nbuf == 64 { md5_block(m, m.buf.data); m.nbuf = 0; }
    }
    m.total += cast(u64) data.count;
}
md5_update_str :: (m: *Md5, s: string) { d: [] u8; d.data = s.data; d.count = s.count; md5_update(m, d); }

md5_final :: (m: *Md5) -> [16] u8 {
    bits := m.total * 8;
    pad: [72] u8;
    pad[0] = 0x80;
    n := ifx m.nbuf < 56 then 56 - m.nbuf else 120 - m.nbuf;
    total := m.total;
    p: [] u8; p.data = pad.data; p.count = n;
    md5_update(m, p);
    lb: [8] u8;
    for i: 0..7 lb[i] = cast(u8) ((bits >> cast(u64) (8 * i)) & 0xff);
    q: [] u8; q.data = lb.data; q.count = 8;
    md5_update(m, q);
    r: [16] u8;
    vals: [4] u32;
    vals[0] = m.a; vals[1] = m.b; vals[2] = m.c; vals[3] = m.d;
    for k: 0..3 for j: 0..3 r[k*4+j] = cast(u8) ((vals[k] >> cast(u32) (8 * j)) & 0xff);
    return r;
}

// MD5::stringifyResult: lower-case hex
md5_hex :: (r: [16] u8) -> string {
    HEX :: "0123456789abcdef";
    s := alloc_string(32,, allocator = temp);
    for i: 0..15 { s[2*i] = HEX[r[i] >> 4]; s[2*i+1] = HEX[r[i] & 0xf]; }
    return s;
}
// MD5Hash(Str): the low 8 bytes of the digest, little endian (MD5Result::low)
md5_hash_u64 :: (s: string) -> u64 {
    m: Md5;
    md5_update_str(*m, s);
    r := md5_final(*m);
    v: u64 = 0;
    for i: 0..7 v |= (cast(u64) r[i]) << cast(u64) (8 * i);
    return v;
}
