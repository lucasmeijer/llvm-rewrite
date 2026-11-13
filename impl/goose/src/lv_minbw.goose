// computeMinimumValueSizes (llvm/lib/Analysis/VectorUtils.cpp) for LoopVectorize's VFSelectionContext::
// computeMinimalBitwidths, with the EquivalenceClasses<Value *> it uses (llvm/include/llvm/ADT/EquivalenceClasses.h:
// classes in insertion order, a union appends the second class's members to the first's list) (LLVM 23.1.5).
// The result, MinBWs, is lmb_map (instruction -> bit width); lmb_keys keeps the MapVector's insertion order.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import apint;
import datalayout;
import loopinfo;
import tti;
import demandedbits;

var lmb_map = hm_new();
var lmb_keys: i32[>..<];

// EquivalenceClasses: element index per value, its leader, and each leader's member list (a linked list)
var lec_idx = hm_new();
var lec_val: i32[>..<];
var lec_leader: i32[>..<];
var lec_next: i32[>..<];
var lec_tail: i32[>..<];
fn lec_reset() { hm_clear(lec_idx); lec_val.clear(); lec_leader.clear(); lec_next.clear(); lec_tail.clear(); }
fn lec_insert(v: i32) -> i32 {
    let x = hm_get(lec_idx, v as u64, -1);
    if x >= 0 { return x as i32; }
    let e = lec_val.len as i32;
    lec_val.push(v); lec_leader.push(e); lec_next.push(-1); lec_tail.push(e);
    hm_put(lec_idx, v as u64, e as i64);
    return e;
}
fn lec_find(e: i32) -> i32 { var x = e; while lec_leader[x] != x { x = lec_leader[x]; } return x; }
// getOrInsertLeaderValue(V)
fn lec_leader_value(v: i32) -> i32 { let e = lec_insert(v); let l = lec_find(e); return lec_val[l]; }
// unionSets(V1, V2)
fn lec_union(v1: i32, v2: i32) {
    let e1 = lec_insert(v1);
    let e2 = lec_insert(v2);
    let l1 = lec_find(e1);
    let l2 = lec_find(e2);
    if l1 == l2 { return; }
    lec_next[lec_tail[l1]] = l2;
    lec_tail[l1] = lec_tail[l2];
    // every member of l2's list now leads to l1
    var x = l2;
    while x >= 0 { lec_leader[x] = l1; x = lec_next[x]; }
}

fn lmb_bit_width(x: u64) -> u64 { var n: u64 = 0; var y = x; while y != 0 { n++; y = y >> 1; } return n; }
fn lmb_bit_ceil(x: u64) -> u64 { if x <= 1 { return 1; } var p: u64 = 1; while p < x { p = p << 1; } return p; }
fn lmb_scalar_bits(t: i32) -> i64 {
    let s = ty_scalar(t);
    if ty_is_int(s) { return ty_bits(s); }
    if ty_kind(s) == TK_VOID { return 0; }
    return dl_size_bits(s);
}
// DemandedBits::getDemandedBits(I): (width, low 64 bits)
fn lmb_demanded(i: i32) -> i64, u64 {
    if ty_is_int(ty_scalar(vals[i].ty)) {
        let a = db_demanded_bits_ap(i);
        return a.w as i64, ap_lo64(a);
    }
    let w = lmb_scalar_bits(vals[i].ty as i32);
    if w > 64 { return w, 0; }
    return w, if w == 64 { 0xFFFFFFFFFFFFFFFF } else { ((1 as u64) << (w as u64)) - 1 };
}

// computeMinimumValueSizes(TheLoop->getBlocks(), DB, &TTI)
fn lmb_compute(l: i32) {
    hm_clear(lmb_map);
    lmb_keys.clear();
    lec_reset();
    var wl: i32[>..<] = [];
    var roots = hm_new();
    var visited = hm_new();
    var dbits = hm_new();
    var dkeys: i32[>..<] = [];
    var inset = hm_new();
    var seen_ext_illegal = false;
    for b in loop_nblocks(l) {
        var i = block_first(loop_block(l, b));
        while i >= 0 {
            hm_put(inset, i as u64, 1);
            let o = iop(i);
            if (o == OP_ZEXT || o == OP_SEXT) && !tti_is_type_legal(vals[op(i, 0)].ty as i32) { seen_ext_illegal = true; }
            if (o == OP_TRUNC || o == OP_ICMP) && !ty_is_vector(vals[i].ty) && lmb_scalar_bits(vals[op(i, 0)].ty as i32) <= 64 {
                if !(o == OP_TRUNC && tti_is_type_legal(vals[i].ty as i32)) {
                    wl.push(i);
                    hm_put(roots, i as u64, 1);
                }
            }
            i = inst_next(i);
        }
    }
    if wl.len == 0 || !seen_ext_illegal { return; }
    fn dget(v: i32) -> u64 { hm_get(dbits, v as u64, 0) as u64 }
    fn dset(v: i32, x: u64) { if !hm_has(dbits, v as u64) { dkeys.push(v); } hm_put(dbits, v as u64, x as i64); }
    while wl.len > 0 {
        let i = wl.pop();
        let leader = lec_leader_value(i);
        if hm_has(visited, i as u64) { continue; }
        hm_put(visited, i as u64, 1);
        let w, v = lmb_demanded(i);
        if w > 64 { hm_clear(lmb_map); lmb_keys.clear(); return; }
        dset(leader, dget(leader) | v);
        dset(i, v);
        let o = iop(i);
        if o == OP_SEXT || o == OP_ZEXT || o == OP_LOAD || !hm_has(inset, i as u64) { continue; }
        if o == OP_BITCAST || o == OP_PTRTOINT || o == OP_INTTOPTR || !ty_is_int(vals[i].ty as i32) {
            dset(leader, 0xFFFFFFFFFFFFFFFF);
            continue;
        }
        if o == OP_PHI { continue; }
        if o == OP_CALL || o == OP_INVOKE || o == OP_CALLBR { continue; }
        if dget(leader) == 0xFFFFFFFFFFFFFFFF { continue; }
        for k in nops(i) {
            let x = op(i, k);
            lec_union(leader, x);
            if is_inst(x) { wl.push(x); }
        }
    }
    // users we did not see make their chain unoptimizable
    let nk = dkeys.len;
    for j in nk {
        let v = dkeys[j];
        var u = vals[v].first_use;
        while u >= 0 {
            let us = uses[u].user;
            u = uses[u].next;
            if ty_is_int(vals[us].ty as i32) && !hm_has(dbits, us as u64) {
                let ld = lec_leader_value(v);
                dset(ld, dget(ld) | 0xFFFFFFFFFFFFFFFF);
            }
        }
    }
    for e in lec_val.len {
        let ei = e as i32;
        if lec_leader[ei] != ei { continue; }
        var ldb: u64 = 0;
        var x = ei;
        while x >= 0 { ldb = ldb | dget(lec_val[x]); x = lec_next[x]; }
        let minbw = lmb_bit_ceil(lmb_bit_width(ldb));
        var abort = false;
        x = ei;
        while x >= 0 {
            let m = lec_val[x];
            if is_inst(m) && iop(m) == OP_PHI && minbw < lmb_scalar_bits(vals[m].ty as i32) as u64 { abort = true; }
            x = lec_next[x];
        }
        if abort { continue; }
        x = ei;
        while x >= 0 {
            let m = lec_val[x];
            x = lec_next[x];
            if !is_inst(m) { continue; }
            var ty = vals[m].ty as i32;
            if hm_has(roots, m as u64) { ty = vals[op(m, 0)].ty as i32; }
            if minbw >= lmb_scalar_bits(ty) as u64 { continue; }
            let is_call = iop(m) == OP_CALL || iop(m) == OP_INVOKE || iop(m) == OP_CALLBR;
            let nopnd = if is_call { cb_nargs(m) } else { nops(m) };
            var bad = false;
            for k in nopnd {
                let ov = op(m, k);
                let mo = iop(m);
                if vals[ov].kind == VK_CINT && (mo == OP_SHL || mo == OP_LSHR || mo == OP_ASHR) && k == 1 {
                    if !ap_ult_u64(ci_ap(ov), minbw) { bad = true; }
                    continue;
                }
                let bw = lmb_bit_width(ap_lo64(db_demanded_bits_use(m, k)));
                if lmb_bit_ceil(bw) > minbw { bad = true; }
            }
            if bad { continue; }
            if !hm_has(lmb_map, m as u64) { lmb_keys.push(m); }
            hm_put(lmb_map, m as u64, minbw as i64);
        }
    }
}
fn lmb_lookup(i: i32) -> i64 { if i < 0 { 0 } else { hm_get(lmb_map, i as u64, 0) } }
