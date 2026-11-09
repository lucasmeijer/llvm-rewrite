// BranchProbabilityInfo: a port of llvm/lib/Analysis/BranchProbabilityInfo.cpp and BranchProbability
// (llvm/include/llvm/Support/BranchProbability.h, llvm/lib/Support/BranchProbability.cpp).
import std;
import ir;
import irutil;
import tti;

// ---------------------------------------------------------------------------------------------
// BranchProbability: a numerator over D = 1 << 31 (u32; UnknownN = 0xFFFFFFFF)

// BP_D, bp_from_ratio (the BranchProbability(N, D) constructor), bp_get and bp_compl are in tti.goose.
let BP_UNKNOWN: u32 = 0xFFFFFFFF;
fn bp_new(n: u64, d: u64) -> u32 { bp_from_ratio(n, d) }

fn bp_add(a: u32, b: u32) -> u32 { if (a as u64) + (b as u64) > BP_D { BP_D as u32 } else { a + b } }
fn bp_sub(a: u32, b: u32) -> u32 { if a < b { 0 } else { a - b } }
fn bp_mul(a: u32, b: u32) -> u32 { (((a as u64) * (b as u64) + BP_D / 2) / BP_D) as u32 }
fn bp_div_u32(a: u32, d: u32) -> u32 { a / d }

// scale<D>(Num, N, D): Num * N / D, floor, saturating
fn bp_scale_impl(num: u64, n: u32, d: u32) -> u64 {
    if num == 0 || d == n { return num; }
    let ph = (num >> 32) * (n as u64);
    let pl = (num & 0xFFFFFFFF) * (n as u64);
    var upper32 = (ph >> 32) as u32;
    let lower32 = (pl & 0xFFFFFFFF) as u32;
    let mid32p = (ph & 0xFFFFFFFF) as u32;
    let mid32 = mid32p + ((pl >> 32) as u32);
    if mid32 < mid32p { upper32 += 1; }
    var rem = ((upper32 as u64) << 32) | (mid32 as u64);
    let upperq = rem / (d as u64);
    if upperq > 0xFFFFFFFF { return 0xFFFFFFFFFFFFFFFF; }
    rem = ((rem % (d as u64)) << 32) | (lower32 as u64);
    let lowerq = rem / (d as u64);
    let q = (upperq << 32) + lowerq;
    return if q < lowerq { 0xFFFFFFFFFFFFFFFF } else { q };
}
fn bp_scale(p: u32, num: u64) -> u64 { bp_scale_impl(num, p, BP_D as u32) }
fn bp_scale_by_inverse(p: u32, num: u64) -> u64 { bp_scale_impl(num, BP_D as u32, p) }

// BlockFrequency arithmetic (saturating)
fn bf_mul(f: u64, p: u32) -> u64 { bp_scale(p, f) }
fn bf_div(f: u64, p: u32) -> u64 { bp_scale_by_inverse(p, f) }
fn bf_add(a: u64, b: u64) -> u64 { let s = a + b; if s < b { 0xFFFFFFFFFFFFFFFF } else { s } }
fn bf_sub(a: u64, b: u64) -> u64 { if a <= b { 0 } else { a - b } }

// normalizeProbabilities
fn bp_normalize(ps: u32[>..<]&) {
    if ps.len == 0 { return; }
    var unknown: u64 = 0;
    var sum: u64 = 0;
    for p in ps { if p == BP_UNKNOWN { unknown++; } else { sum += p as u64; } }
    if unknown > 0 {
        var pu: u32 = 0;
        if sum < BP_D { pu = ((BP_D - sum) / unknown) as u32; }
        for k in ps.len { if ps[k] == BP_UNKNOWN { ps[k] = pu; } }
        if sum <= BP_D { return; }
    }
    if sum == 0 {
        let b = bp_new(1, ps.len as u64);
        for k in ps.len { ps[k] = b; }
        return;
    }
    for k in ps.len { ps[k] = (((ps[k] as u64) * BP_D + sum / 2) / sum) as u32; }
}

// ---------------------------------------------------------------------------------------------
// BranchProbabilityInfo (not ported yet)

fn bpi_not_ported() { fatal("BranchProbabilityInfo is not ported yet"); }
fn bpi_valid(fv: i32) -> bool { false }
fn bpi_compute(fv: i32) { bpi_not_ported(); }
fn bpi_invalidate() {}
fn bpi_erase_block(bb: i32) { bpi_not_ported(); }
fn bpi_copy_edge_probabilities(src: i32, dst: i32) { bpi_not_ported(); }
fn bpi_edge_prob_to(src: i32, dst: i32) -> u32 { bpi_not_ported(); return 0; }
fn bpi_edge_prob_idx(src: i32, k: i64) -> u32 { bpi_not_ported(); return 0; }
fn bpi_set_edge_probability(bb: i32, ps: const u32[:]) { bpi_not_ported(); }
