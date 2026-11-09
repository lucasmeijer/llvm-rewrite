// BlockFrequencyInfo: a port of llvm/lib/Analysis/BlockFrequencyInfo.cpp (the analysis, print<block-freq>),
// llvm/lib/Analysis/BlockFrequencyInfoImpl.cpp and the BasicBlock instantiation of
// llvm/include/llvm/Analysis/BlockFrequencyInfoImpl.h (BlockMass, Distribution, DitheringDistributer, the loop
// packaging, the irreducible-loop analysis with IrreducibleGraph and its scc_iterator), and ScaledNumber
// (llvm/include/llvm/Support/ScaledNumber.h, llvm/lib/Support/ScaledNumber.cpp) on 64-bit digits.
//
// One result exists at a time (bf_fn). Nodes are RPOT indices; bf_node maps a block id to its node.
// LoopData records live in bf_loops as a doubly linked list (std::list<LoopData>: irreducible loops are inserted
// in the middle); their Nodes / Exits / BackedgeMass vectors are runs in pools that are copied when they grow.
// Not ported (fail loudly): -use-iterative-bfi-inference, the x87 APFloat fallback of ScaledNumber printing.
import std;
import ir;
import irutil;
import apint;
import loopinfo;
import profdata;
import flags;
import scev;
import bpi;
import tti;

fn bfi_not_ported(what: const u8[:]) { fatal(str("BlockFrequencyInfo: ", what, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// ScaledNumber<uint64_t>

struct S64 { d: u64, s: i64 }
let SN_MAX_SCALE: i64 = 16383;
let SN_MIN_SCALE: i64 = -16382;
let U64_MAX: u64 = 0xFFFFFFFFFFFFFFFF;

fn sn(d: u64, s: i64) -> S64 { S64 { d: d, s: s } }
fn sn_zero() -> S64 { sn(0, 0) }
fn sn_largest() -> S64 { sn(U64_MAX, SN_MAX_SCALE) }
fn sn_is_largest(a: S64) -> bool { sn_compare(a, sn_largest()) == 0 }
// getRounded
fn sn_rounded(d: u64, s: i64, round: bool) -> S64 {
    if round {
        let x = d + 1;
        if x == 0 { return sn((1 as u64) << 63, s + 1); }
        return sn(x, s);
    }
    return sn(d, s);
}
// multiply64
fn sn_multiply64(l: u64, r: u64) -> S64 {
    let ul = l >> 32; let ll = l & 0xFFFFFFFF; let ur = r >> 32; let lr = r & 0xFFFFFFFF;
    let p1 = ul * ur; let p2 = ul * lr; let p3 = ll * ur; let p4 = ll * lr;
    var upper = p1;
    var lower = p4;
    // addWithCarry(P2), addWithCarry(P3)
    var nl = lower + ((p2 & 0xFFFFFFFF) << 32);
    upper = upper + (p2 >> 32) + (if nl < lower { 1 } else { 0 });
    lower = nl;
    nl = lower + ((p3 & 0xFFFFFFFF) << 32);
    upper = upper + (p3 >> 32) + (if nl < lower { 1 } else { 0 });
    lower = nl;
    if upper == 0 { return sn(lower, 0); }
    let lz = clz(upper);
    let shift = 64 - lz;
    if lz != 0 { upper = (upper << (lz as u64)) | (lower >> (shift as u64)); }
    let round = shift != 0 && (lower & ((1 as u64) << ((shift - 1) as u64))) != 0;
    return sn_rounded(upper, shift, round);
}
// getProduct<uint64_t>
fn sn_product(l: u64, r: u64) -> S64 {
    if l <= 0xFFFFFFFF && r <= 0xFFFFFFFF { return sn(l * r, 0); }
    return sn_multiply64(l, r);
}
fn sn_half(n: u64) -> u64 { (n >> 1) + (n & 1) }
// divide64
fn sn_divide64(dividend0: u64, divisor0: u64) -> S64 {
    var dividend = dividend0;
    var divisor = divisor0;
    var shift: i64 = 0;
    let tz = ctz(divisor);
    if tz != 0 { shift -= tz; divisor = divisor >> (tz as u64); }
    if divisor == 1 { return sn(dividend, shift); }
    let lz = clz(dividend);
    if lz != 0 { shift -= lz; dividend = dividend << (lz as u64); }
    var q = dividend / divisor;
    dividend = dividend % divisor;
    while (q >> 63) == 0 && dividend != 0 {
        let ov = (dividend >> 63) != 0;
        dividend = dividend << 1;
        shift--;
        q = q << 1;
        if ov || divisor <= dividend {
            q = q | 1;
            dividend = dividend - divisor;
        }
    }
    return sn_rounded(q, shift, dividend >= sn_half(divisor));
}
// getQuotient<uint64_t>
fn sn_quotient(a: u64, b: u64) -> S64 {
    if a == 0 { return sn(0, 0); }
    if b == 0 { return sn(U64_MAX, SN_MAX_SCALE); }
    return sn_divide64(a, b);
}
// getLgImpl: (floor, rounding direction)
fn sn_lg_impl(d: u64, s: i64) -> i64, i64 {
    if d == 0 { return -2147483648, 0; }
    let local_floor = 63 - clz(d);
    let fl = s + local_floor;
    if d == ((1 as u64) << (local_floor as u64)) { return fl, 0; }
    let round = (d & ((1 as u64) << ((local_floor - 1) as u64))) != 0;
    return fl + (if round { 1 } else { 0 }), (if round { 1 } else { -1 });
}
fn sn_lg_floor(d: u64, s: i64) -> i64 { let f, r = sn_lg_impl(d, s); return f - (if r > 0 { 1 } else { 0 }); }
// compareImpl
fn sn_compare_impl(l: u64, r: u64, diff: i64) -> i64 {
    let la = l >> (diff as u64);
    if la < r { return -1; }
    if la > r { return 1; }
    return if l > (la << (diff as u64)) { 1 } else { 0 };
}
// compare(LDigits, LScale, RDigits, RScale)
fn sn_compare_raw(ld: u64, ls: i64, rd: u64, rs: i64) -> i64 {
    if ld == 0 { return if rd != 0 { -1 } else { 0 }; }
    if rd == 0 { return 1; }
    let lgl = sn_lg_floor(ld, ls);
    let lgr = sn_lg_floor(rd, rs);
    if lgl != lgr { return if lgl < lgr { -1 } else { 1 }; }
    if ls < rs { return sn_compare_impl(ld, rd, rs - ls); }
    return -sn_compare_impl(rd, ld, ls - rs);
}
fn sn_compare(a: S64, b: S64) -> i64 { sn_compare_raw(a.d, a.s, b.d, b.s) }
fn sn_lt(a: S64, b: S64) -> bool { sn_compare(a, b) < 0 }
// matchScales: (LDigits, LScale, RDigits, RScale) after matching, and the returned common scale
recursive fn sn_match_scales(ld0: u64, ls0: i64, rd0: u64, rs0: i64) -> u64, i64, u64, i64, i64 {
    if ls0 < rs0 {
        let a, b, c, d, sc = sn_match_scales(rd0, rs0, ld0, ls0);
        return c, d, a, b, sc;
    }
    if ld0 == 0 { return ld0, ls0, rd0, rs0, rs0; }
    if rd0 == 0 || ls0 == rs0 { return ld0, ls0, rd0, rs0, ls0; }
    let diff = ls0 - rs0;
    if diff >= 128 { return ld0, ls0, 0, rs0, ls0; }
    let shl = min(clz(ld0), diff);
    let shr = diff - shl;
    if shr >= 64 { return ld0, ls0, 0, rs0, ls0; }
    return ld0 << (shl as u64), ls0 - shl, rd0 >> (shr as u64), rs0 + shr, ls0 - shl;
}
// getSum
fn sn_get_sum(ld0: u64, ls0: i64, rd0: u64, rs0: i64) -> S64 {
    let ld, ls, rd, rs, scale = sn_match_scales(ld0, ls0, rd0, rs0);
    let unused = ls + rs;
    let sum = ld + rd;
    if sum >= rd { return sn(sum, scale); }
    return sn(((1 as u64) << 63) | (sum >> 1), scale + 1);
}
fn sn_add(a: S64, b: S64) -> S64 {
    let r = sn_get_sum(a.d, a.s, b.d, b.s);
    if r.s > SN_MAX_SCALE { return sn_largest(); }
    return r;
}
// shiftLeft / shiftRight (operator<<= takes an int16_t)
recursive fn sn_shift_left(a: S64, shift0: i64) -> S64 {
    var x = a;
    var shift = shift0;
    if shift == 0 || x.d == 0 { return x; }
    if shift < 0 { return sn_shift_right(x, -shift); }
    let ss = min(shift, SN_MAX_SCALE - x.s);
    x.s += ss;
    if ss == shift { return x; }
    if sn_is_largest(x) { return x; }
    shift -= ss;
    if shift > clz(x.d) { return sn_largest(); }
    x.d = x.d << (shift as u64);
    return x;
}
recursive fn sn_shift_right(a: S64, shift0: i64) -> S64 {
    var x = a;
    var shift = shift0;
    if shift == 0 || x.d == 0 { return x; }
    if shift < 0 { return sn_shift_left(x, -shift); }
    let ss = min(shift, x.s - SN_MIN_SCALE);
    x.s -= ss;
    if ss == shift { return x; }
    shift -= ss;
    if shift >= 64 { return sn_zero(); }
    x.d = x.d >> (shift as u64);
    return x;
}
fn sn_to_i16(x: i64) -> i64 { let m = x & 0xFFFF; return if m >= 0x8000 { m - 0x10000 } else { m }; }
// operator*=
fn sn_mul(a: S64, b: S64) -> S64 {
    if a.d == 0 { return a; }
    if b.d == 0 { return b; }
    let scales = a.s + b.s;
    return sn_shift_left(sn_product(a.d, b.d), sn_to_i16(scales));
}
// operator/=
fn sn_div(a: S64, b: S64) -> S64 {
    if a.d == 0 { return a; }
    if b.d == 0 { return sn_largest(); }
    let scales = a.s - b.s;
    return sn_shift_left(sn_quotient(a.d, b.d), sn_to_i16(scales));
}
fn sn_inverse(a: S64) -> S64 { sn_div(sn(1, 0), a) }
// toInt<uint64_t>
fn sn_to_int(a: S64) -> u64 {
    if sn_compare_raw(a.d, a.s, 1, 0) < 0 { return 0; }
    if sn_compare_raw(a.d, a.s, U64_MAX, 0) >= 0 { return U64_MAX; }
    if a.s > 0 { return a.d << (a.s as u64); }
    if a.s < 0 { return a.d >> ((-a.s) as u64); }
    return a.d;
}

// ScaledNumberBase::toString(D, E, Width = 64, Precision)
fn sn_to_string(out: u8[>..]&, d0: u64, e0: i64, precision: i64) {
    var d = d0;
    var e = e0;
    if d == 0 { out.append("0.0"); return; }
    var above0: u64 = 0;
    var below0: u64 = 0;
    var extra: u64 = 0;
    var extra_shift: i64 = 0;
    if e == 0 { above0 = d; }
    else if e > 0 {
        let sh = min(clz(d), e);
        if sh != 0 {
            d = d << (sh as u64);
            e -= sh;
            if e == 0 { above0 = d; }
        }
    } else if e > -64 {
        above0 = d >> ((-e) as u64);
        below0 = d << ((64 + e) as u64);
    } else if e == -64 {
        below0 = d;
    } else if e > -120 {
        below0 = d >> ((-e - 64) as u64);
        extra = d << ((128 + e) as u64);
        extra_shift = -64 - e;
    }
    if above0 == 0 && below0 == 0 { bfi_not_ported("ScaledNumber::toString of a very small or very large number (APFloat)"); }
    var s: u8[>..] = [];
    var digits_out: i64 = 0;
    if above0 != 0 {
        var n = above0;
        while n != 0 { s.push(('0' as u64 + n % 10) as u8); n = n / 10; }
        digits_out = s.len;
    } else {
        s.push('0');
    }
    // reverse
    var i: i64 = 0;
    var j = s.len - 1;
    while i < j { let t = s[i]; s[i] = s[j]; s[j] = t; i++; j--; }
    if below0 == 0 { out.append(s); out.append(".0"); return; }
    s.push('.');
    var error: u64 = (1 as u64) << 0;   // 1 << (64 - Width) with Width = 64
    extra = ((below0 & 0xf) << 56) | (extra >> 8);
    below0 = below0 >> 4;
    var since_dot: i64 = 0;
    let after_dot = s.len;
    loop {
        if extra_shift != 0 { extra_shift--; error = error * 5; } else { error = error * 10; }
        below0 = below0 * 10;
        extra = extra * 10;
        below0 = below0 + (extra >> 60);
        extra = extra & (U64_MAX >> 4);
        s.push(('0' as u64 + (below0 >> 60)) as u8);
        below0 = below0 & (U64_MAX >> 4);
        if digits_out != 0 || s[s.len - 1] != '0' { digits_out++; }
        since_dot++;
        if !(error != 0 && ((below0 << 4) | (extra >> 60)) >= error / 2 &&
             (precision == 0 || digits_out <= precision || since_dot < 2)) { break; }
    }
    if precision == 0 || digits_out <= precision { sn_strip_trailing_zeros(out, s, s.len); return; }
    let truncate = max(s.len - (digits_out - precision), after_dot + 1);
    if truncate >= s.len { sn_strip_trailing_zeros(out, s, s.len); return; }
    let c = s[truncate];
    let carry0 = c >= '5' && c <= '9';
    if !carry0 { sn_strip_trailing_zeros(out, s, truncate); return; }
    var carry = true;
    var k = truncate - 1;
    while k >= 0 {
        if s[k] == '.' { k--; continue; }
        if s[k] == '9' { s[k] = '0'; k--; continue; }
        s[k] = s[k] + 1;
        carry = false;
        break;
    }
    var t2: u8[>..] = [];
    if carry { t2.push('1'); }
    t2.append(s[0..truncate]);
    sn_strip_trailing_zeros(out, t2, t2.len);
}
fn sn_strip_trailing_zeros(out: u8[>..]&, s: const u8[:], n: i64) {
    var nz = n - 1;
    while nz >= 0 && s[nz] == '0' { nz--; }
    if s[nz] == '.' { nz++; }
    out.append(s[0..nz + 1]);
}

// ---------------------------------------------------------------------------------------------
// BlockMass

let BM_FULL: u64 = 0xFFFFFFFFFFFFFFFF;
fn bm_add(a: u64, b: u64) -> u64 { let s = a + b; return if s < a { BM_FULL } else { s }; }
fn bm_sub(a: u64, b: u64) -> u64 { let d = a - b; return if d > a { 0 } else { d }; }
fn bm_mul(a: u64, p: u32) -> u64 { bp_scale(p, a) }
fn bm_to_scaled(m: u64) -> S64 { if m == BM_FULL { sn(1, 0) } else { sn(m + 1, -64) } }

// ---------------------------------------------------------------------------------------------
// The result and the working state

struct BRun { at: i32, n: i32, cap: i32 }
struct BLoop { parent: i32, packaged: bool, nheaders: i32, nodes: BRun, exits: BRun, bmass: BRun, mass: u64, sd: u64, ss: i64, prev: i32, next: i32 }

var bf_fn: i32 = -1;
var bf_node = hm_new();          // block id -> node (RPOT index, or an index given by setBlockFreq)
var bf_freq_sd: u64[>..<];       // Freqs[].Scaled
var bf_freq_ss: i64[>..<];
var bf_freq_int: u64[>..<];      // Freqs[].Integer
var bf_irr: bool[>..<];          // IsIrrLoopHeader
var bf_rpot: i32[>..<];          // RPOT
var wk_loop: i32[>..<];          // Working[].Loop
var wk_mass: u64[>..<];          // Working[].Mass
var bf_loops: BLoop[>..<];
var bf_lhead: i32 = -1;          // Loops (list order)
var bf_ltail: i32 = -1;
var bl_nodes: i32[>..<];         // run pools
var bl_exit_node: i32[>..<];
var bl_exit_mass: u64[>..<];
var bl_bmass: u64[>..<];

fn brun0() -> BRun { BRun { at: 0, n: 0, cap: 0 } }
fn bl_nodes_push(l: i32, x: i32) {
    var r = bf_loops[l].nodes;
    if r.n == r.cap {
        let nc = max(4, (r.cap as i64) * 2);
        let at = bl_nodes.len;
        for k in r.n { bl_nodes.push(bl_nodes[(r.at as i64) + k]); }
        for k in nc - (r.n as i64) { bl_nodes.push(-1); }
        r.at = at as i32;
        r.cap = nc as i32;
    }
    bl_nodes[(r.at as i64) + (r.n as i64)] = x;
    r.n = r.n + 1;
    bf_loops[l].nodes = r;
}
fn bl_node(l: i32, k: i64) -> i32 { bl_nodes[(bf_loops[l].nodes.at as i64) + k] }
fn bl_nnodes(l: i32) -> i64 { bf_loops[l].nodes.n as i64 }
fn bl_exits_push(l: i32, node: i32, m: u64) {
    var r = bf_loops[l].exits;
    if r.n == r.cap {
        let nc = max(4, (r.cap as i64) * 2);
        let at = bl_exit_node.len;
        for k in r.n { bl_exit_node.push(bl_exit_node[(r.at as i64) + k]); bl_exit_mass.push(bl_exit_mass[(r.at as i64) + k]); }
        for k in nc - (r.n as i64) { bl_exit_node.push(-1); bl_exit_mass.push(0); }
        r.at = at as i32;
        r.cap = nc as i32;
    }
    bl_exit_node[(r.at as i64) + (r.n as i64)] = node;
    bl_exit_mass[(r.at as i64) + (r.n as i64)] = m;
    r.n = r.n + 1;
    bf_loops[l].exits = r;
}
fn bl_nexits(l: i32) -> i64 { bf_loops[l].exits.n as i64 }
fn bl_exit_node_at(l: i32, k: i64) -> i32 { bl_exit_node[(bf_loops[l].exits.at as i64) + k] }
fn bl_exit_mass_at(l: i32, k: i64) -> u64 { bl_exit_mass[(bf_loops[l].exits.at as i64) + k] }
fn bl_bmass_at(l: i32, k: i64) -> u64 { bl_bmass[(bf_loops[l].bmass.at as i64) + k] }
fn bl_bmass_set(l: i32, k: i64, m: u64) { bl_bmass[(bf_loops[l].bmass.at as i64) + k] = m; }
fn bl_header(l: i32) -> i32 { bl_node(l, 0) }
fn bl_is_irreducible(l: i32) -> bool { bf_loops[l].nheaders > 1 }
// isHeader
fn bl_is_header(l: i32, node: i32) -> bool {
    if bl_is_irreducible(l) {
        // binary_search over the sorted headers
        var lo: i64 = 0;
        var hi = bf_loops[l].nheaders as i64;
        while lo < hi { let mid = (lo + hi) / 2; if bl_node(l, mid) < node { lo = mid + 1; } else { hi = mid; } }
        return lo < (bf_loops[l].nheaders as i64) && bl_node(l, lo) == node;
    }
    return node == bl_node(l, 0);
}
// getHeaderIndex
fn bl_header_index(l: i32, node: i32) -> i64 {
    if bl_is_irreducible(l) {
        var lo: i64 = 0;
        var hi = bf_loops[l].nheaders as i64;
        while lo < hi { let mid = (lo + hi) / 2; if bl_node(l, mid) < node { lo = mid + 1; } else { hi = mid; } }
        return lo;
    }
    return 0;
}
// a new LoopData inserted before `before` (-1 = end) of the list
fn bl_new(parent: i32, headers: const i32[:], others: const i32[:], before: i32) -> i32 {
    let id = bf_loops.len as i32;
    bf_loops.push(BLoop { parent: parent, packaged: false, nheaders: headers.len as i32, nodes: brun0(), exits: brun0(), bmass: brun0(),
                          mass: 0, sd: 0, ss: 0, prev: -1, next: -1 });
    for h in headers { bl_nodes_push(id, h); }
    for o in others { bl_nodes_push(id, o); }
    let at = bl_bmass.len;
    for k in headers.len { bl_bmass.push(0); }
    bf_loops[id].bmass = BRun { at: at as i32, n: headers.len as i32, cap: headers.len as i32 };
    // link
    if before < 0 {
        bf_loops[id].prev = bf_ltail;
        if bf_ltail >= 0 { bf_loops[bf_ltail].next = id; } else { bf_lhead = id; }
        bf_ltail = id;
    } else {
        let p = bf_loops[before].prev;
        bf_loops[id].prev = p;
        bf_loops[id].next = before;
        bf_loops[before].prev = id;
        if p >= 0 { bf_loops[p].next = id; } else { bf_lhead = id; }
    }
    return id;
}

// WorkingData
fn wk_is_loop_header(i: i32) -> bool { let l = wk_loop[i]; return l >= 0 && bl_is_header(l, i); }
fn wk_is_double_loop_header(i: i32) -> bool {
    if !wk_is_loop_header(i) { return false; }
    let p = bf_loops[wk_loop[i]].parent;
    return p >= 0 && bl_is_irreducible(p) && bl_is_header(p, i);
}
fn wk_containing_loop(i: i32) -> i32 {
    if !wk_is_loop_header(i) { return wk_loop[i]; }
    if !wk_is_double_loop_header(i) { return bf_loops[wk_loop[i]].parent; }
    return bf_loops[bf_loops[wk_loop[i]].parent].parent;
}
fn wk_packaged_loop(i: i32) -> i32 {
    let l0 = wk_loop[i];
    if l0 < 0 || !bf_loops[l0].packaged { return -1; }
    var l = l0;
    while bf_loops[l].parent >= 0 && bf_loops[bf_loops[l].parent].packaged { l = bf_loops[l].parent; }
    return l;
}
fn wk_resolved_node(i: i32) -> i32 { let l = wk_packaged_loop(i); return if l >= 0 { bl_header(l) } else { i }; }
fn wk_is_packaged(i: i32) -> bool { wk_resolved_node(i) != i }
fn wk_is_a_package(i: i32) -> bool { wk_is_loop_header(i) && bf_loops[wk_loop[i]].packaged }
fn wk_is_a_double_package(i: i32) -> bool { wk_is_double_loop_header(i) && bf_loops[bf_loops[wk_loop[i]].parent].packaged }
// getMass() as a reference: get / set
fn wk_get_mass(i: i32) -> u64 {
    if !wk_is_a_package(i) { return wk_mass[i]; }
    if !wk_is_a_double_package(i) { return bf_loops[wk_loop[i]].mass; }
    return bf_loops[bf_loops[wk_loop[i]].parent].mass;
}
fn wk_set_mass(i: i32, m: u64) {
    if !wk_is_a_package(i) { wk_mass[i] = m; return; }
    if !wk_is_a_double_package(i) { bf_loops[wk_loop[i]].mass = m; return; }
    bf_loops[bf_loops[wk_loop[i]].parent].mass = m;
}

// getNode(BB): -1 = invalid
fn bf_get_node(bb: i32) -> i32 { hm_get(bf_node, (bb as i64) as u64, -1) as i32 }

// ---------------------------------------------------------------------------------------------
// Distribution (one at a time) and DitheringDistributer

let W_LOCAL: u8 = 0;
let W_EXIT: u8 = 1;
let W_BACKEDGE: u8 = 2;
var ds_type: u8[>..<];
var ds_node: i32[>..<];
var ds_amt: u64[>..<];
var ds_total: u64 = 0;
var ds_overflow: bool = false;

fn ds_clear() { ds_type.clear(); ds_node.clear(); ds_amt.clear(); ds_total = 0; ds_overflow = false; }
fn ds_add(node: i32, amt: u64, t: u8) {
    let nt = ds_total + amt;
    if nt < ds_total { ds_overflow = true; }
    ds_total = nt;
    ds_type.push(t);
    ds_node.push(node);
    ds_amt.push(amt);
}
// combineWeight(W, OtherW) on entries a (accumulated) and b
fn ds_combine_into(w_t: u8&, w_n: i32&, w_a: u64&, t: u8, n: i32, a: u64) {
    if w_a == 0 { w_t = t; w_n = n; w_a = a; return; }
    if w_a > w_a + a { w_a = U64_MAX; } else { w_a = w_a + a; }
}
// combineWeightsBySorting
fn ds_combine_by_sorting() {
    var idx: i64[>..<] = [];
    for k in ds_node.len { idx.push(k); }
    sort(idx) { x, y => ds_node[x] < ds_node[y] };
    var nt: u8[>..<] = [];
    var nn: i32[>..<] = [];
    var na: u64[>..<] = [];
    var i: i64 = 0;
    while i < idx.len {
        var t = ds_type[idx[i]];
        var n = ds_node[idx[i]];
        var a = ds_amt[idx[i]];
        var l = i + 1;
        while l < idx.len && ds_node[idx[l]] == n {
            ds_combine_into(t, n, a, ds_type[idx[l]], ds_node[idx[l]], ds_amt[idx[l]]);
            l++;
        }
        nt.push(t); nn.push(n); na.push(a);
        i = l;
    }
    ds_type.clear(); ds_node.clear(); ds_amt.clear();
    for k in nt.len { ds_type.push(nt[k]); ds_node.push(nn[k]); ds_amt.push(na[k]); }
}
// combineWeightsByHashing: DenseMap<uint32_t, Weight> with NextPowerOf2(2 * size) reserved entries,
// hash = key * 37, quadratic probing; the result is in bucket order
fn ds_combine_by_hashing() {
    let n = ds_node.len;
    var reserve: u64 = 1;
    while reserve <= (2 * n) as u64 { reserve = reserve * 2; }
    // getMinBucketToReserveForEntries(reserve) = NextPowerOf2(reserve * 4 / 3 + 1)
    let want = reserve * 4 / 3 + 1;
    var nb: u64 = 1;
    while nb <= want { nb = nb * 2; }
    var keys: i64[>..<] = [];
    var bt: u8[>..<] = [];
    var bn: i32[>..<] = [];
    var ba: u64[>..<] = [];
    for k in (nb as i64) { keys.push(-1); bt.push(0); bn.push(-1); ba.push(0); }
    var count: i64 = 0;
    let mask = nb - 1;
    for k in n {
        let key = ds_node[k] as u32;
        var b = ((key * 37) as u64) & mask;
        var probe: u64 = 1;
        while keys[b as i64] >= 0 && keys[b as i64] != (key as i64) { b = (b + probe) & mask; probe++; }
        if keys[b as i64] < 0 { keys[b as i64] = key as i64; count++; }
        var t = bt[b as i64]; var nd = bn[b as i64]; var a = ba[b as i64];
        ds_combine_into(t, nd, a, ds_type[k], ds_node[k], ds_amt[k]);
        bt[b as i64] = t; bn[b as i64] = nd; ba[b as i64] = a;
    }
    if count == n { return; }
    ds_type.clear(); ds_node.clear(); ds_amt.clear();
    for k in (nb as i64) { if keys[k] >= 0 { ds_type.push(bt[k]); ds_node.push(bn[k]); ds_amt.push(ba[k]); } }
}
fn ds_shift_right_and_round(nv: u64, shift: i64) -> u64 {
    if shift == 0 { return nv; }
    return (nv >> (shift as u64)) + (1 & (nv >> ((shift - 1) as u64)));
}
// Distribution::normalize
fn ds_normalize() {
    if ds_node.len == 0 { return; }
    if ds_node.len > 1 {
        if ds_node.len > 128 { ds_combine_by_hashing(); } else { ds_combine_by_sorting(); }
    }
    if ds_node.len == 1 { ds_total = 1; ds_amt[0] = 1; return; }
    var shift: i64 = 0;
    if ds_overflow { shift = 33; }
    else if ds_total > 0xFFFFFFFF { shift = 33 - clz(ds_total); }
    if shift == 0 { return; }
    ds_total = 0;
    for k in ds_amt.len {
        ds_amt[k] = max(1 as u64, ds_shift_right_and_round(ds_amt[k], shift));
        ds_total += ds_amt[k];
    }
}

// DitheringDistributer
var dd_rem_weight: u32 = 0;
var dd_rem_mass: u64 = 0;
fn dd_init(mass: u64) { ds_normalize(); dd_rem_weight = ds_total as u32; dd_rem_mass = mass; }
fn dd_take_mass(w: u32) -> u64 {
    let m = bm_mul(dd_rem_mass, bp_new(w as u64, dd_rem_weight as u64));
    dd_rem_weight -= w;
    dd_rem_mass = bm_sub(dd_rem_mass, m);
    return m;
}

// ---------------------------------------------------------------------------------------------
// BlockFrequencyInfoImplBase

// addToDist
fn bf_add_to_dist(outer: i32, pred: i32, succ: i32, w0: u64) -> bool {
    let w = if w0 == 0 { 1 } else { w0 };
    let resolved = wk_resolved_node(succ);
    let is_hdr = outer >= 0 && bl_is_header(outer, resolved);
    if is_hdr { ds_add(resolved, w, W_BACKEDGE); return true; }
    if wk_containing_loop(resolved) != outer { ds_add(resolved, w, W_EXIT); return true; }
    if resolved < pred {
        if !(outer >= 0 && bl_is_header(outer, pred)) { return false; }
    }
    ds_add(resolved, w, W_LOCAL);
    return true;
}
// addLoopSuccessorsToDist
fn bf_add_loop_successors_to_dist(outer: i32, l: i32) -> bool {
    for k in bl_nexits(l) {
        if !bf_add_to_dist(outer, bl_header(l), bl_exit_node_at(l, k), bl_exit_mass_at(l, k)) { return false; }
    }
    return true;
}
// computeLoopScale
fn bf_compute_loop_scale(l: i32) {
    var tbm: u64 = 0;
    for k in bf_loops[l].bmass.n { tbm = bm_add(tbm, bl_bmass_at(l, k)); }
    let exit_mass = bm_sub(BM_FULL, tbm);
    let s = if exit_mass == 0 { sn(1, 12) } else { sn_inverse(bm_to_scaled(exit_mass)) };
    bf_loops[l].sd = s.d;
    bf_loops[l].ss = s.s;
}
// packageLoop
fn bf_package_loop(l: i32) {
    for k in bl_nnodes(l) {
        let m = bl_node(l, k);
        let pl = wk_packaged_loop(m);
        if pl >= 0 { bf_loops[pl].exits.n = 0; }
    }
    bf_loops[l].packaged = true;
}
// distributeMass
fn bf_distribute_mass(src: i32, outer: i32) {
    let mass = wk_get_mass(src);
    dd_init(mass);
    for k in ds_node.len {
        let taken = dd_take_mass(ds_amt[k] as u32);
        let t = ds_type[k];
        let tn = ds_node[k];
        if t == W_LOCAL { wk_set_mass(tn, bm_add(wk_get_mass(tn), taken)); continue; }
        if t == W_BACKEDGE {
            let hi = bl_header_index(outer, tn);
            bl_bmass_set(outer, hi, bm_add(bl_bmass_at(outer, hi), taken));
            continue;
        }
        bl_exits_push(outer, tn, taken);
    }
}
// convertFloatingToInteger
fn bf_convert_floating_to_integer(mx: S64) {
    let factor = sn_div(sn(1, 54), mx);
    for i in bf_freq_sd.len {
        let scaled = sn_mul(sn(bf_freq_sd[i], bf_freq_ss[i]), factor);
        bf_freq_int[i] = max(1 as u64, sn_to_int(scaled));
    }
}
// unwrapLoop
fn bf_unwrap_loop(l: i32) {
    let sc = sn_mul(sn(bf_loops[l].sd, bf_loops[l].ss), bm_to_scaled(bf_loops[l].mass));
    bf_loops[l].sd = sc.d;
    bf_loops[l].ss = sc.s;
    bf_loops[l].packaged = false;
    for k in bl_nnodes(l) {
        let n = bl_node(l, k);
        let ls = sn(bf_loops[l].sd, bf_loops[l].ss);
        if wk_is_a_package(n) {
            let pl = wk_packaged_loop(n);
            let nw = sn_mul(ls, sn(bf_loops[pl].sd, bf_loops[pl].ss));
            bf_loops[pl].sd = nw.d;
            bf_loops[pl].ss = nw.s;
        } else {
            let nw = sn_mul(ls, sn(bf_freq_sd[n], bf_freq_ss[n]));
            bf_freq_sd[n] = nw.d;
            bf_freq_ss[n] = nw.s;
        }
    }
}
// unwrapLoops
fn bf_unwrap_loops() {
    for i in wk_mass.len {
        let s = bm_to_scaled(wk_mass[i]);
        bf_freq_sd[i] = s.d;
        bf_freq_ss[i] = s.s;
    }
    var l = bf_lhead;
    while l >= 0 { bf_unwrap_loop(l); l = bf_loops[l].next; }
}
// finalizeMetrics
fn bf_finalize_metrics() {
    var mx = sn_zero();
    for i in wk_mass.len {
        let s = sn(bf_freq_sd[i], bf_freq_ss[i]);
        if sn_lt(mx, s) { mx = s; }
    }
    bf_convert_floating_to_integer(mx);
}

// ---------------------------------------------------------------------------------------------
// The irreducible-loop analysis (IrreducibleGraph, findIrreducibleHeaders, createIrreducibleLoop,
// analyzeIrreducible, updateLoopWithIrreducible, adjustLoopHeaderMass, distributeIrrLoopHeaderMass)

var ig_node: i32[>..<];          // IrrNode::Node
var ig_preds: i32[>..<];         // per IrrNode: pred list (pushed to the front of the deque: iterate reversed)
var ig_pred_run: BRun[>..<];
var ig_succs: i32[>..<];
var ig_succ_run: BRun[>..<];
var ig_lookup = hm_new();        // node -> IrrNode
var ig_start: i32 = -1;

fn ig_run_push(pool: i32[>..<]&, runs: BRun[>..<]&, k: i64, x: i32) {
    var r = runs[k];
    if r.n == r.cap {
        let nc = max(4, (r.cap as i64) * 2);
        let at = pool.len;
        for j in r.n { pool.push(pool[(r.at as i64) + j]); }
        for j in nc - (r.n as i64) { pool.push(-1); }
        r.at = at as i32;
        r.cap = nc as i32;
    }
    pool[(r.at as i64) + (r.n as i64)] = x;
    r.n = r.n + 1;
    runs[k] = r;
}
fn ig_add_node(n: i32) {
    ig_node.push(n);
    ig_pred_run.push(brun0());
    ig_succ_run.push(brun0());
    wk_set_mass(n, 0);
}
// addEdge
fn ig_add_edge(irr: i64, succ: i32, outer: i32) {
    if outer >= 0 && bl_is_header(outer, succ) { return; }
    if succ < 0 { return; }
    let s = hm_get(ig_lookup, (succ as i64) as u64, -1);
    if s < 0 { return; }
    ig_run_push(ig_succs, ig_succ_run, irr, s as i32);
    ig_run_push(ig_preds, ig_pred_run, s, irr as i32);
}
// IrreducibleGraph(BFI, OuterLoop, addBlockEdges)
fn ig_build(outer: i32) {
    ig_node.clear(); ig_preds.clear(); ig_pred_run.clear(); ig_succs.clear(); ig_succ_run.clear();
    hm_clear(ig_lookup);
    var start: i32 = 0;
    if outer >= 0 {
        start = bl_header(outer);
        for k in bl_nnodes(outer) { ig_add_node(bl_node(outer, k)); }
    } else {
        for i in wk_mass.len { if !wk_is_packaged(i as i32) { ig_add_node(i as i32); } }
    }
    for k in ig_node.len { hm_put(ig_lookup, (ig_node[k] as i64) as u64, k); }
    if outer >= 0 {
        for k in bl_nnodes(outer) { ig_add_edges(bl_node(outer, k), outer); }
    } else {
        for i in wk_mass.len { ig_add_edges(i as i32, outer); }
    }
    ig_start = hm_get(ig_lookup, (start as i64) as u64, -1) as i32;
}
// addEdges
fn ig_add_edges(n: i32, outer: i32) {
    let irr = hm_get(ig_lookup, (n as i64) as u64, -1);
    if irr < 0 { return; }
    if wk_is_a_package(n) {
        let l = wk_loop[n];
        for k in bl_nexits(l) { ig_add_edge(irr, bl_exit_node_at(l, k), outer); }
    } else {
        let bb = bf_rpot[n];
        let t = block_terminator(bb);
        if t >= 0 { for k in term_nsucc(t) { ig_add_edge(irr, bf_get_node(term_succ(t, k)), outer); } }
    }
}
fn ig_npreds(k: i64) -> i64 { ig_pred_run[k].n as i64 }
// the j-th predecessor in deque order (the last pushed first)
fn ig_pred(k: i64, j: i64) -> i32 { let r = ig_pred_run[k]; return ig_preds[(r.at as i64) + (r.n as i64) - 1 - j]; }
fn ig_nsuccs(k: i64) -> i64 { ig_succ_run[k].n as i64 }
fn ig_succ(k: i64, j: i64) -> i32 { let r = ig_succ_run[k]; return ig_succs[(r.at as i64) + j]; }

// scc_iterator over the IrreducibleGraph from StartIrr: SCCs flattened into out (size, then IrrNode indices)
fn ig_sccs(out: i32[>..<]&) {
    out.clear();
    var num: i64[>..<] = [];
    for k in ig_node.len { num.push(-1); }
    var scc_stack: i32[>..<] = [];
    var vs_node: i32[>..<] = [];
    var vs_next: i64[>..<] = [];
    var vs_min: i64[>..<] = [];
    var visit: i64 = 0;
    if ig_start < 0 { return; }
    visit++;
    num[ig_start] = visit;
    scc_stack.push(ig_start);
    vs_node.push(ig_start); vs_next.push(0); vs_min.push(visit);
    while vs_node.len > 0 {
        var found = false;
        while vs_node.len > 0 && !found {
            loop {
                let top = vs_node.len - 1;
                let n = vs_node[top] as i64;
                if vs_next[top] >= ig_nsuccs(n) { break; }
                let c = ig_succ(n, vs_next[top]);
                vs_next[top] = vs_next[top] + 1;
                if num[c] < 0 {
                    visit++;
                    num[c] = visit;
                    scc_stack.push(c);
                    vs_node.push(c); vs_next.push(0); vs_min.push(visit);
                    continue;
                }
                if vs_min[top] > num[c] { vs_min[top] = num[c]; }
            }
            let top = vs_node.len - 1;
            let visiting = vs_node[top];
            let minv = vs_min[top];
            vs_node.pop(); vs_next.pop(); vs_min.pop();
            if vs_node.len > 0 && vs_min[vs_node.len - 1] > minv { vs_min[vs_node.len - 1] = minv; }
            if minv != num[visiting] { continue; }
            let sz_at = out.len;
            out.push(0);
            loop {
                let x = scc_stack.pop();
                out.push(x);
                num[x] = 0xFFFFFFFF;
                if x == visiting { break; }
            }
            out[sz_at] = (out.len - sz_at - 1) as i32;
            found = true;
        }
    }
}

// findIrreducibleHeaders + createIrreducibleLoop for the SCC out[at+1 .. at+1+n)
fn bf_create_irreducible_loop(sccs: i32[>..<]&, at: i64, n: i64, outer: i32, insert: i32) -> i32 {
    var in_scc = hm_new();
    for j in n { hm_put(in_scc, (sccs[at + 1 + j] as i64) as u64, 0); }
    var headers: i32[>..<] = [];
    var others: i32[>..<] = [];
    // entry blocks (InSCC iteration order does not matter: the lists are sorted below)
    for j in n {
        let irr = sccs[at + 1 + j] as i64;
        for p in ig_npreds(irr) {
            let pr = ig_pred(irr, p);
            if hm_has(in_scc, (pr as i64) as u64) { continue; }
            hm_put(in_scc, (irr as u64), 1);
            headers.push(ig_node[irr]);
            break;
        }
    }
    if headers.len != n {
        for j in n {
            let irr = sccs[at + 1 + j] as i64;
            if hm_get(in_scc, irr as u64, 0) == 1 { continue; }
            var added = false;
            for p in ig_npreds(irr) {
                let pr = ig_pred(irr, p) as i64;
                if ig_node[pr] < ig_node[irr] { continue; }
                if hm_get(in_scc, pr as u64, 0) == 1 { continue; }
                headers.push(ig_node[irr]);
                added = true;
                break;
            }
            if added { continue; }
            others.push(ig_node[irr]);
        }
    }
    sort(headers) { x, y => x < y };
    sort(others) { x, y => x < y };
    let l = bl_new(outer, headers, others, insert);
    for k in bl_nnodes(l) {
        let nd = bl_node(l, k);
        if wk_is_loop_header(nd) { bf_loops[wk_loop[nd]].parent = l; }
        else { wk_loop[nd] = l; }
    }
    return l;
}

// computeIrreducibleMass(OuterLoop, Insert)
fn bf_compute_irreducible_mass(outer: i32, insert: i32) {
    ig_build(outer);
    var sccs: i32[>..<] = [];
    ig_sccs(sccs);
    // analyzeIrreducible: the new loops are inserted before Insert, in SCC order
    var created: i32[>..<] = [];
    var k: i64 = 0;
    while k < sccs.len {
        let n = sccs[k] as i64;
        if n >= 2 { created.push(bf_create_irreducible_loop(sccs, k, n, outer, insert)); }
        k += n + 1;
    }
    // for (auto &L : analyzeIrreducible(...)) computeMassInLoop(L): the loops from next(Prev) (or the list
    // head) to Insert, which are exactly the ones just created, in list order
    for l in created { bf_compute_mass_in_loop(l); }
    if outer < 0 { return; }
    // updateLoopWithIrreducible
    bf_loops[outer].exits.n = 0;
    for j in bf_loops[outer].bmass.n { bl_bmass_set(outer, j, 0); }
    var w: i64 = 1;
    for j in 1..bl_nnodes(outer) {
        let nd = bl_node(outer, j);
        if !wk_is_packaged(nd) { bl_nodes[(bf_loops[outer].nodes.at as i64) + w] = nd; w++; }
    }
    bf_loops[outer].nodes.n = w as i32;
}

// adjustLoopHeaderMass
fn bf_adjust_loop_header_mass(l: i32) {
    ds_clear();
    for h in bf_loops[l].nheaders {
        let hn = bl_node(l, h);
        let bm = bl_bmass_at(l, bl_header_index(l, hn));
        if bm > 0 { ds_add(hn, bm, W_LOCAL); }
    }
    bf_distribute_irr_loop_header_mass();
}
// distributeIrrLoopHeaderMass
fn bf_distribute_irr_loop_header_mass() {
    dd_init(BM_FULL);
    for k in ds_node.len {
        let taken = dd_take_mass(ds_amt[k] as u32);
        wk_set_mass(ds_node[k], taken);
    }
}

// ---------------------------------------------------------------------------------------------
// BlockFrequencyInfoImpl<BasicBlock>

// BasicBlock::getIrrLoopHeaderWeight: (has, weight)
fn bf_irr_loop_header_weight(bb: i32) -> bool, u64 {
    let t = block_terminator(bb);
    if t < 0 { return false, 0; }
    let m = inst_get_md(t, md_kind_id("irr_loop"));
    if m < 0 || mds[m].nops < 2 { return false, 0; }
    let s = md_op(m, 0);
    if s < 0 || mds[s].kind != MK_STRING || sbytes(mds[s].extra) != "loop_header_weight" { return false, 0; }
    let o = md_op(m, 1);
    if o < 0 || mds[o].kind != MK_VALUE { return false, 0; }
    let c = mds[o].extra;
    return true, ap_zext64(ap_from_cint(c));
}

// propagateMassToSuccessors
fn bf_propagate_mass_to_successors(outer: i32, node: i32) -> bool {
    ds_clear();
    let pl = wk_packaged_loop(node);
    if pl >= 0 {
        if !bf_add_loop_successors_to_dist(outer, pl) { return false; }
    } else {
        let bb = bf_rpot[node];
        let t = block_terminator(bb);
        if t >= 0 {
            for k in term_nsucc(t) {
                if !bf_add_to_dist(outer, node, bf_get_node(term_succ(t, k)), bpi_edge_prob_idx(bb, k) as u64) { return false; }
            }
        }
    }
    bf_distribute_mass(node, outer);
    return true;
}

// computeMassInLoop
fn bf_compute_mass_in_loop(l: i32) -> bool {
    if bl_is_irreducible(l) {
        ds_clear();
        var nwith: i64 = 0;
        var minw: i64 = -1;
        var without: i64[>..<] = [];
        for h in bf_loops[l].nheaders {
            let hn = bl_node(l, h);
            bf_irr[hn] = true;
            let has, hw = bf_irr_loop_header_weight(bf_rpot[hn]);
            if !has { without.push(h); continue; }
            nwith++;
            if minw < 0 || (hw as i64) < minw { minw = hw as i64; }
            if hw != 0 { ds_add(hn, hw, W_LOCAL); }
        }
        if minw < 0 { minw = 1; }
        if without.len > 1 && bf_loops[l].nheaders > 128 { bfi_not_ported("the HeadersWithoutWeight DenseSet order of a loop with over 128 headers"); }
        for h in without {
            let hn = bl_node(l, h);
            if minw != 0 { ds_add(hn, minw as u64, W_LOCAL); }
        }
        bf_distribute_irr_loop_header_mass();
        for k in bl_nnodes(l) {
            if !bf_propagate_mass_to_successors(l, bl_node(l, k)) { fatal("BlockFrequencyInfo: unhandled irreducible control flow"); }
        }
        if nwith == 0 { bf_adjust_loop_header_mass(l); }
    } else {
        wk_set_mass(bl_header(l), BM_FULL);
        if !bf_propagate_mass_to_successors(l, bl_header(l)) { fatal("BlockFrequencyInfo: irreducible control flow to loop header"); }
        for k in 1..bl_nnodes(l) {
            if !bf_propagate_mass_to_successors(l, bl_node(l, k)) { return false; }
        }
    }
    bf_compute_loop_scale(l);
    bf_package_loop(l);
    return true;
}

// initializeRPOT
fn bf_initialize_rpot(fv: i32) {
    var po: i32[>..<] = [];
    bpi_post_order(fv, po);
    bf_rpot.clear();
    var k = po.len - 1;
    while k >= 0 { bf_rpot.push(po[k]); k--; }
    hm_clear(bf_node);
    for i in bf_rpot.len { hm_put(bf_node, (bf_rpot[i] as i64) as u64, i); }
    wk_loop.clear(); wk_mass.clear();
    bf_freq_sd.clear(); bf_freq_ss.clear(); bf_freq_int.clear(); bf_irr.clear();
    for i in bf_rpot.len { wk_loop.push(-1); wk_mass.push(0); bf_freq_sd.push(0); bf_freq_ss.push(0); bf_freq_int.push(0); bf_irr.push(false); }
}

// initializeLoops: loops in breadth-first order (std::deque)
fn bf_initialize_loops(fv: i32) {
    bf_loops.clear(); bf_lhead = -1; bf_ltail = -1;
    bl_nodes.clear(); bl_exit_node.clear(); bl_exit_mass.clear(); bl_bmass.clear();
    if li_ntop(fv) == 0 { return; }
    var q_loop: i32[>..<] = [];
    var q_parent: i32[>..<] = [];
    for k in li_ntop(fv) { q_loop.push(li_top(fv, k)); q_parent.push(-1); }
    var qi: i64 = 0;
    while qi < q_loop.len {
        let lp = q_loop[qi];
        let parent = q_parent[qi];
        qi++;
        let header = bf_get_node(loop_header(lp));
        let hs: i32[1] = [header];
        let none: i32[0] = [];
        let id = bl_new(parent, hs, none, -1);
        wk_loop[header] = id;
        for k in loop_nsubs(lp) { q_loop.push(loop_sub(lp, k)); q_parent.push(id); }
    }
    for i in bf_rpot.len {
        let ix = i as i32;
        if wk_is_loop_header(ix) {
            let cl = wk_containing_loop(ix);
            if cl >= 0 { bl_nodes_push(cl, ix); }
            continue;
        }
        let lp = li_loop_for(bf_rpot[i]);
        if lp < 0 { continue; }
        let header = bf_get_node(loop_header(lp));
        let hl = wk_loop[header];
        wk_loop[ix] = hl;
        bl_nodes_push(hl, ix);
    }
}

// computeMassInLoops
fn bf_compute_mass_in_loops() {
    var l = bf_ltail;
    while l >= 0 {
        if !bf_compute_mass_in_loop(l) {
            bf_compute_irreducible_mass(l, bf_loops[l].next);
            if !bf_compute_mass_in_loop(l) { fatal("BlockFrequencyInfo: unhandled irreducible control flow"); }
        }
        l = bf_loops[l].prev;
    }
}
// tryToComputeMassInFunction
fn bf_try_to_compute_mass_in_function() -> bool {
    wk_set_mass(0, BM_FULL);
    for i in bf_rpot.len {
        if wk_is_packaged(i as i32) { continue; }
        if !bf_propagate_mass_to_successors(-1, i as i32) { return false; }
    }
    return true;
}
// computeMassInFunction
fn bf_compute_mass_in_function() {
    if bf_try_to_compute_mass_in_function() { return; }
    bf_compute_irreducible_mass(-1, bf_lhead);
    if bf_try_to_compute_mass_in_function() { return; }
    fatal("BlockFrequencyInfo: unhandled irreducible control flow");
}

// BlockFrequencyAnalysis::run: BranchProbabilityInfo, LoopInfo, then calculate
fn bfi_compute(fv: i32) {
    if flag_bool("use-iterative-bfi-inference", false) { bfi_not_ported("-use-iterative-bfi-inference"); }
    bpi_get(fv);
    li_get(fv);
    bf_fn = fv;
    bf_initialize_rpot(fv);
    bf_initialize_loops(fv);
    bf_compute_mass_in_loops();
    bf_compute_mass_in_function();
    bf_unwrap_loops();
    bf_finalize_metrics();
}
fn bfi_get(fv: i32) { if !bfi_valid(fv) { bfi_compute(fv); } }
fn bfi_valid(fv: i32) -> bool { bf_fn == fv && fv >= 0 }
fn bfi_invalidate() { bf_fn = -1; }

// getBlockFreq
fn bfi_freq(bb: i32) -> u64 {
    let n = bf_get_node(bb);
    if n < 0 { return 0; }
    return bf_freq_int[n];
}
// setBlockFreq
fn bfi_set_freq(bb: i32, f: u64) {
    var n = bf_get_node(bb);
    if n < 0 {
        n = bf_freq_int.len as i32;
        hm_put(bf_node, (bb as i64) as u64, n as i64);
        bf_freq_sd.push(0); bf_freq_ss.push(0); bf_freq_int.push(0); bf_irr.push(false);
    }
    bf_freq_int[n] = f;
}

// Function::getEntryCount() (AllowSynthetic = false): (has, count)
fn bf_entry_count(fv: i32) -> bool, u64 {
    let g = glob_of(fv);
    let k = md_kind_id("prof");
    for j in globs[g].nmd {
        if md_att[globs[g].md + 2 * j] != k { continue; }
        let m = md_att[globs[g].md + 2 * j + 1];
        if mds[m].nops < 2 { return false, 0; }
        let s = md_op(m, 0);
        if s < 0 || mds[s].kind != MK_STRING || sbytes(mds[s].extra) != "function_entry_count" { return false, 0; }
        let o = md_op(m, 1);
        if o < 0 || mds[o].kind != MK_VALUE { return false, 0; }
        let c = ap_zext64(ap_from_cint(mds[o].extra));
        if c == U64_MAX { return false, 0; }
        return true, c;
    }
    return false, 0;
}

// BlockFrequencyPrinterPass::run + BlockFrequencyInfoImpl::print
fn bfi_print(fv: i32) {
    errs("Printing analysis results of BFI for function '");
    errs(val_name(fv));
    errs("':\n");
    bfi_get(fv);
    errs("block-frequency-info: ");
    errs(val_name(fv));
    errs("\n");
    let has_ec, ec = bf_entry_count(fv);
    var line: u8[>..] = [];
    var b = func_entry(fv);
    while b >= 0 {
        line.clear();
        line.append(" - ");
        line.append(val_name(b));
        line.append(": float = ");
        let n = bf_get_node(b);
        if n >= 0 { sn_to_string(line, bf_freq_sd[n], bf_freq_ss[n], 5); } else { line.append("0.0"); }
        line.append(", int = ");
        let f = bfi_freq(b);
        format_u64_dec(line, f);
        if has_ec {
            // getProfileCountFromFreq: (EntryCount * Freq + EntryFreq / 2) / EntryFreq in 128 bits, saturated
            let ef = ap_u64(bf_freq_int[0], 128);
            var bc = ap_mul(ap_u64(ec, 128), ap_u64(f, 128));
            bc = ap_udiv(ap_add(bc, ap_lshr(ef, 1)), ef);
            line.append(", count = ");
            format_u64_dec(line, ap_limited(bc, U64_MAX));
        }
        let hw, w = bf_irr_loop_header_weight(b);
        if hw { line.append(", irr_loop_header_weight = "); format_u64_dec(line, w); }
        line.append("\n");
        errs(line);
        b = block_next(b);
    }
    errs("\n");
}
