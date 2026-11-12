// SLPVectorizer: the store-chain and list seeds of the pass driver. Port of llvm/lib/Transforms/Vectorize/
// SLPVectorizer.cpp: SLPVectorizerPass::vectorizeStoreChain, StoreChainContext (addOperand, markRangeVectorized,
// initializeContext, getFirstUnvecStore, getFirstVecStoreAfter, allVectorized, isFirstSizeSameRange,
// allOfRangeProfitable, updateRangeSizesFromCache, updateCachedRangeSizes, updateCandidateVFs, getCurrentVF,
// checkTreeSizes, vectorizeOneVF), RelatedStoreInsts, vectorizeStores, vectorizeStoreChains (StoreSorter,
// AreCompatibleStores, HasConsecutiveStoresOrSameAddress), tryToVectorizeSequence for stores, and
// tryToVectorizeList.
//
// Every tree goes through buildTree and isTreeTinyAndNotFullyVectorizable; a tree that is not tiny would continue
// with the reordering and the cost model, which are not ported: that fails loudly (slp_after_tree).
import std;
import ir;
import irutil;
import calls;
import instinfo;
import datalayout;
import pm;
import flags;
import domtree;
import laa;
import tti;
import tti_x86;
import tti_x86_vec;
import tti_vec;
import slp_util;
import slp_tree;
import slp_ops;
import slp_sched;
import slp_loads;
import slp_build;

fn slp_after_tree() { slp_fail("BoUpSLP after buildTree (reorderTopToBottom / transformNodes / computeMinimumValueSizes / the cost model)"); }
fn slp_max_vf_opt() -> i64 { if flag_given("slp-max-vf") { flag_int("slp-max-vf", 0) } else { 0 } }
// getMaximumVF(ElemWidth, Opcode): X86 and the base TTI answer 0
fn slp_maximum_vf(ew: i64, o: i64) -> i64 {
    let m = slp_max_vf_opt();
    return if m != 0 { m } else { 0xFFFFFFFF };
}
fn slp_vectorize_non_pow2() -> bool { flag_bool("slp-vectorize-non-power-of-2", false) }
fn slp_allowed_non_pow2_vf(n: i64) -> bool { slp_vectorize_non_pow2() && !slp_is_pow2(n + 1) }
fn slp_inst_is_safe_to_remove(i: i32) -> bool {
    return (iop(i) != OP_CALL || !inst_may_have_side_effects(i)) && !is_terminator(i) && !inst_is_eh_pad(i);
}

// ---------------------------------------------------------------- vectorizeStoreChain
// vectorizeStoreChain(Chain, R, Idx, MinVF, Size): 0 false, 1 true, -1 std::nullopt; and Size
fn slp_vectorize_store_chain(chain: const i32[:], idx: i64, minvf: i64) -> i64, i64 {
    var size: i64 = 0;
    if slp_dbg_on { errs("SLP: Analyzing a store chain of length "); errs_int(chain.len); errs("\n"); slp_dbg_flush(); }
    let sz = slp_vector_element_size(chain[0]);
    let vf = chain.len;
    if !slp_is_pow2(sz) || !slp_has_full_vectors_or_pow2(vals[op(chain[0], 0)].ty, vf) || vf < 2 || vf < minvf {
        if !slp_vectorize_non_pow2() || (vf < minvf && vf + 1 != minvf) { return 0, size; }
    }
    if slp_dbg_on { errs("SLP: Analyzing "); errs_int(vf); errs(" stores at offset "); errs_int(idx); errs("\n"); slp_dbg_flush(); }
    var valops: i32[>..<] = [];
    sh_clear(SH_TMP0);
    for v in chain { let x = op(v, 0); if sh_add(SH_TMP0, x as i64, 0) { valops.push(x); } }
    let s = slp_build_instructions_state(valops, false, false);
    var all_inst = true;
    for v in valops { if !is_inst(v) { all_inst = false; break; } }
    if all_inst && valops.len > 1 {
        let allowed = slp_has_full_vectors_or_pow2(vals[valops[0]].ty, valops.len) || slp_allowed_non_pow2_vf(valops.len);
        var bad_uses = false;
        if !allowed && sis_valid(s) && sis_opcode(s) != OP_LOAD {
            if !slp_inst_is_safe_to_remove(s.main) { bad_uses = true; }
            else {
                for v in valops {
                    if is_inst_op(v, OP_EXTRACTELEMENT) { continue; }
                    if slp_num_uses(v) > chain.len { bad_uses = true; break; }
                    var u = vals[v].first_use;
                    var other = false;
                    while u >= 0 {
                        let usr = uses[u].user;
                        var found = false;
                        for c in chain { if c == usr { found = true; break; } }
                        if !found { other = true; break; }
                        u = uses[u].next;
                    }
                    if other { bad_uses = true; break; }
                }
            }
        }
        if bad_uses || (valops.len > chain.len / 2 && !sis_valid(s)) {
            size = if !allowed && sis_valid(s) { 1 } else { 2 };
            return 0, size;
        }
    }
    let none_: i32[1] = [0];
    slp_build_tree(chain, false, none_[..0]);
    if slp_is_tree_tiny_and_not_fully_vectorizable(false) {
        if slp_is_gathered(chain[0]) || slp_is_not_scheduled(op(chain[0], 0)) { return -1, size; }
        size = slp_base_graph_size;
        return 0, size;
    }
    slp_after_tree();
    return 0, size;
}

// ---------------------------------------------------------------- StoreChainContext
let SCC_UNVEC: i64 = 0xFFFFFFFF;    // LocallyUnvectorizable
struct SCtx { ops: i32, nops: i32, rs: i32, minvf: i64, maxvf: i64, maxregvf: i64, probevf: i64, store_ty: i32,
              cq: i32, ncq: i32, end_: i64, repeat: i64, repeat_changed: bool, stride: i64, alive: bool,
              ns: i32 }
var slp_sctx: SCtx[>..];
var slp_sc_ops: i32[>..];        // Operands runs (grown in place: a context's run is re-allocated when it grows)
var slp_sc_rs1: i64[>..];        // RangeSizes .first
var slp_sc_rs2: i64[>..];        // RangeSizes .second
var slp_sc_cq: i64[>..];         // CandidateVFs queues
var slp_sc_ns_key: i32[>..];     // NonSchedulable: (context, value) -> (max, min)
var slp_sc_ns_ctx: i32[>..];
var slp_sc_ns_max: i64[>..];
var slp_sc_ns_min: i64[>..];
var slp_range_sizes_by_idx: i64[>..<];
var slp_stores_cur: i32[>..<];   // the Stores of vectorizeStores
var slp_vectorized_stores: i32[>..<];
var slp_attempted: i64[>..<];    // Attempted / Visited tuples, 5 per entry

fn scx_add_operand(c: i32, store: i32, idx: i64) {
    let e = slp_sctx[c];
    let at = slp_sc_ops.len as i32;
    let rat = slp_sc_rs1.len as i32;
    for k in e.nops as i64 { slp_sc_ops.push(slp_sc_ops[e.ops as i64 + k]); slp_sc_rs1.push(slp_sc_rs1[e.rs as i64 + k]); slp_sc_rs2.push(slp_sc_rs2[e.rs as i64 + k]); }
    slp_sc_ops.push(store);
    slp_sc_rs1.push(idx);
    slp_sc_rs2.push(1);
    slp_sctx[c].ops = at;
    slp_sctx[c].rs = rat;
    slp_sctx[c].nops = e.nops + 1;
}
fn scx_new(s0: i32, i0: i64, s1: i32, i1: i64, stride: i64) -> i32 {
    let c = slp_sctx.len as i32;
    let at = slp_sc_ops.len as i32;
    let rat = slp_sc_rs1.len as i32;
    slp_sc_ops.push(s0); slp_sc_ops.push(s1);
    slp_sc_rs1.push(i0); slp_sc_rs2.push(1);
    slp_sc_rs1.push(i1); slp_sc_rs2.push(1);
    slp_sctx.push(SCtx { ops: at, nops: 2, rs: rat, minvf: 0, maxvf: 0, maxregvf: 0, probevf: 0, store_ty: -1, cq: 0, ncq: 0,
                         end_: 0, repeat: 1, repeat_changed: false, stride: stride, alive: true, ns: 0 });
    return c;
}
fn scx_op(c: i32, k: i64) -> i32 { slp_sc_ops[slp_sctx[c].ops as i64 + k] }
fn scx_n(c: i32) -> i64 { slp_sctx[c].nops as i64 }
fn scx_rs1(c: i32, k: i64) -> i64 { slp_sc_rs1[slp_sctx[c].rs as i64 + k] }
fn scx_rs2(c: i32, k: i64) -> i64 { slp_sc_rs2[slp_sctx[c].rs as i64 + k] }
fn scx_set_rs(c: i32, k: i64, a: i64, b: i64) { slp_sc_rs1[slp_sctx[c].rs as i64 + k] = a; slp_sc_rs2[slp_sctx[c].rs as i64 + k] = b; }
fn scx_is_not_vectorized(c: i32, k: i64) -> bool { let f = scx_rs1(c, k); return f != SCC_UNVEC && slp_range_sizes_by_idx[f] > 0; }
fn scx_is_vectorized(c: i32, k: i64) -> bool { let f = scx_rs1(c, k); return f == SCC_UNVEC || slp_range_sizes_by_idx[f] == 0; }
fn scx_rsbi(c: i32, k: i64) -> i64 { slp_range_sizes_by_idx[scx_rs1(c, k)] }
fn scx_cq_push(c: i32, vf: i64) {
    let e = slp_sctx[c];
    let at = slp_sc_cq.len as i32;
    for k in e.ncq as i64 { slp_sc_cq.push(slp_sc_cq[e.cq as i64 + k]); }
    slp_sc_cq.push(vf);
    slp_sctx[c].cq = at;
    slp_sctx[c].ncq = e.ncq + 1;
}
fn scx_cq_pop(c: i32) { if slp_sctx[c].ncq > 0 { slp_sctx[c].cq += 1; slp_sctx[c].ncq -= 1; } }
fn scx_cq_front(c: i32) -> i64 { slp_sc_cq[slp_sctx[c].cq as i64] }
fn scx_current_vf(c: i32) -> i64 { if slp_sctx[c].ncq == 0 { -1 } else { scx_cq_front(c) } }
// markRangeVectorized(StartIdx, Length, FirstUnvecStore, MaxSliceEnd)
fn scx_mark_range_vectorized(c: i32, start: i64, len: i64, first_unvec: i64&, max_end: i64&) {
    for k in start..start + len { slp_range_sizes_by_idx[scx_rs1(c, k)] = 0; scx_set_rs(c, k, scx_rs1(c, k), 0); }
    let minvf = slp_sctx[c].minvf;
    if start < first_unvec + minvf {
        for k in first_unvec..start { scx_set_rs(c, k, SCC_UNVEC, 0); }
        first_unvec = start + len;
    }
    if start + len > max_end - minvf {
        for k in start + len..max_end { scx_set_rs(c, k, SCC_UNVEC, 0); }
        if max_end == slp_sctx[c].end_ { slp_sctx[c].end_ = start; }
        max_end = start;
    }
}
fn slp_attempted_insert(a: i32, b: i32, c: i32, d: i32, n: i64) -> bool {
    var k: i64 = 0;
    while k < slp_attempted.len {
        if slp_attempted[k] == a as i64 && slp_attempted[k + 1] == b as i64 && slp_attempted[k + 2] == c as i64 &&
           slp_attempted[k + 3] == d as i64 && slp_attempted[k + 4] == n { return false; }
        k += 5;
    }
    slp_attempted.push(a as i64); slp_attempted.push(b as i64); slp_attempted.push(c as i64); slp_attempted.push(d as i64);
    slp_attempted.push(n);
    return true;
}
// initializeContext(R, DL, TTI, Visited)
fn scx_initialize(c: i32) -> bool {
    let n = scx_n(c);
    let f = scx_op(c, 0);
    let b = scx_op(c, n - 1);
    if !slp_attempted_insert(f, op(f, 0), b, op(b, 0), n) { return false; }
    let elt = slp_vector_element_size(f);
    let maxelts = slp_bit_floor(slp_max_vreg / elt);
    var maxvf = slp_maximum_vf(elt, OP_STORE);
    if maxelts < maxvf { maxvf = maxelts; }
    let st: i32 = vals[op(f, 0)].ty;
    var vt = st;
    if is_inst_op(op(f, 0), OP_TRUNC) { vt = vals[op(op(f, 0), 0)].ty; }
    let sst = ty_scalar(st);
    var minvf: i64 = 0;
    if tti_kind == TTI_X86 {
        minvf = x86_store_minimum_vf(slp_min_vf(dl_store_size(sst) * 8), sst, ty_scalar(vt));
    } else {
        minvf = slp_min_vf(dl_store_size(sst) * 8);
    }
    minvf = slp_bit_ceil(minvf);
    minvf = minvf / slp_num_elements(st);
    if minvf < 2 { minvf = 2; }
    if slp_sctx[c].stride > 1 { let m = flag_int("slp-min-strided-stores", 2); if m > minvf { minvf = m; } }
    slp_sctx[c].store_ty = st;
    slp_sctx[c].minvf = minvf;
    if maxvf < minvf {
        if slp_dbg_on { errs("SLP: Vectorization infeasible as MaxVF ("); errs_int(maxvf); errs(") < MinVF ("); errs_int(minvf); errs(")\n"); slp_dbg_flush(); }
        return false;
    }
    var npow2vf: i64 = 0;
    var cand = n;
    if cand < minvf { cand = minvf; }
    if cand > maxvf { cand = maxvf; }
    if slp_allowed_non_pow2_vf(cand) { npow2vf = cand; }
    slp_sctx[c].maxregvf = maxvf;
    let bf = slp_bit_floor(n);
    if bf < maxvf { maxvf = bf; }
    slp_sctx[c].maxvf = maxvf;
    if maxvf < minvf {
        if slp_dbg_on { errs("SLP: Vectorization infeasible as MaxVF ("); errs_int(maxvf); errs(") < MinVF ("); errs_int(minvf); errs(")\n"); slp_dbg_flush(); }
        return false;
    }
    var vf = if maxvf > npow2vf { maxvf } else { npow2vf };
    while vf >= minvf {
        scx_cq_push(c, vf);
        vf = slp_div_ceil(vf, 2);
        if vf == 1 && minvf <= 1 { break; }
    }
    slp_sctx[c].end_ = n;
    slp_sctx[c].probevf = maxvf;
    return true;
}
fn scx_first_unvec(c: i32, start: i64) -> i64 {
    var k = start;
    while k < scx_n(c) && !scx_is_not_vectorized(c, k) { k++; }
    return k;
}
fn scx_first_vec_after(c: i32, start: i64) -> i64 {
    var k = start;
    while k < scx_n(c) && !scx_is_vectorized(c, k) { k++; }
    return k;
}
fn scx_all_vectorized(c: i32) -> bool { for k in scx_n(c) { if !scx_is_vectorized(c, k) { return false; } } return true; }
fn scx_first_size_same_range(c: i32, start: i64, len: i64, ts: i64) -> bool {
    for k in start..start + len { if ts != scx_rsbi(c, k) { return false; } }
    return true;
}
fn scx_all_of_range_profitable(c: i32, start: i64, len: i64, ts: i64) -> bool {
    for k in start..start + len { if !(ts >= scx_rsbi(c, k)) { return false; } }
    return true;
}
fn scx_update_range_sizes_from_cache(c: i32) {
    for k in scx_n(c) {
        let f = scx_rs1(c, k);
        if f != SCC_UNVEC && slp_range_sizes_by_idx[f] != 0 {
            let s2 = scx_rs2(c, k);
            if s2 > slp_range_sizes_by_idx[f] { slp_range_sizes_by_idx[f] = s2; }
        }
    }
}
fn scx_update_cached_range_sizes(c: i32, start: i64, len: i64, ts: i64) {
    for k in start..start + len { let s2 = scx_rs2(c, k); scx_set_rs(c, k, scx_rs1(c, k), if s2 > ts { s2 } else { ts }); }
}
fn scx_update_candidate_vfs(c: i32) -> bool {
    let fu = scx_first_unvec(c, 0);
    let a = scx_n(c);
    let b = slp_sctx[c].end_ - fu;
    let max_total = if a < b { a } else { b };
    let vf = slp_bit_ceil(slp_sctx[c].probevf) * 2;
    if vf > max_total || vf >= 64 { return false; }
    let lim = slp_floor_full_vector_number_of_elements(slp_sctx[c].store_ty, max_total);
    if slp_bit_floor(lim) == vf && lim != vf { scx_cq_push(c, lim); }
    scx_cq_push(c, vf);
    slp_sctx[c].probevf = scx_cq_front(c);
    slp_sctx[c].repeat += 1;
    slp_sctx[c].repeat_changed = false;
    return true;
}
fn scx_check_tree_sizes(c: i32, start: i64, vf: i64) -> bool {
    var num: i64 = 0;
    var sum: i64 = 0;
    for k in start..start + vf {
        let f = scx_rs1(c, k);
        let sz = if f == SCC_UNVEC { 0 } else { slp_range_sizes_by_idx[f] };
        if sz == 1 { continue; }
        num++;
        sum += sz;
    }
    if num == 0 { return true; }
    let mean = sum / num;
    if mean == 0 { return true; }
    var dev: u64 = 0;
    for k in start..start + vf {
        let f = scx_rs1(c, k);
        let p = if f == SCC_UNVEC { 0 } else { slp_range_sizes_by_idx[f] };
        if p == 1 { continue; }
        // (P - Mean) * (P - Mean) in unsigned arithmetic
        let d = ((p as u64) - (mean as u64)) & 0xFFFFFFFF;
        dev = dev + d * d;
    }
    dev = dev / (num as u64);
    return dev * 96 / ((mean * mean) as u64) == 0;
}
fn scx_ns_lookup(c: i32, v: i32) -> i64, i64 {
    for k in slp_sc_ns_key.len { if slp_sc_ns_ctx[k] == c && slp_sc_ns_key[k] == v { return slp_sc_ns_max[k], slp_sc_ns_min[k]; } }
    return 0, 0;
}
fn scx_ns_set_min(c: i32, v: i32, vf: i64) {
    for k in slp_sc_ns_key.len { if slp_sc_ns_ctx[k] == c && slp_sc_ns_key[k] == v { slp_sc_ns_min[k] = vf; return; } }
    slp_sc_ns_key.push(v); slp_sc_ns_ctx.push(c); slp_sc_ns_max.push(vf); slp_sc_ns_min.push(vf);
    slp_sctx[c].ns += 1;
}
// vectorizeOneVF(TTI, VF, VectorizedStores, Changed, VectorizeStoreChain)
fn scx_vectorize_one_vf(c: i32, vf: i64, changed: bool&) -> bool {
    var any_profitable = false;
    var first_unvec = scx_first_unvec(c, 0);
    while first_unvec < slp_sctx[c].end_ {
        let fv = scx_first_vec_after(c, first_unvec);
        var max_end = if fv >= slp_sctx[c].end_ { slp_sctx[c].end_ } else { fv };
        var start = first_unvec;
        while start + vf <= max_end {
            if !scx_check_tree_sizes(c, start, vf) { start++; continue; }
            var slice: i32[>..<] = [];
            for k in start..start + vf { slice.push(scx_op(c, k)); }
            if slp_sctx[c].ns > 0 {
                let mx, mn = scx_ns_lookup(c, slice[0]);
                if mx > 0 && mn <= vf { start += mx; continue; }
            }
            let res, ts = slp_vectorize_store_chain(slice, start, slp_sctx[c].minvf);
            if res < 0 {
                scx_ns_set_min(c, slice[0], vf);
            } else if res > 0 {
                for x in slice { slp_vectorized_stores.push(x); }
                any_profitable = true;
                slp_sctx[c].repeat_changed = true;
                changed = true;
                scx_mark_range_vectorized(c, start, vf, first_unvec, max_end);
                start += vf;
                continue;
            }
            if vf > 2 && res >= 0 && !scx_all_of_range_profitable(c, start, vf, ts) { start += vf; continue; }
            if vf > slp_sctx[c].maxregvf && ts > 1 && scx_first_size_same_range(c, start, vf, ts) {
                start += vf;
                while start != max_end && scx_first_size_same_range(c, start, 1, ts) { start++; }
                continue;
            }
            if ts > 1 { scx_update_cached_range_sizes(c, start, vf, ts); }
            start++;
            any_profitable = true;
        }
        if first_unvec >= slp_sctx[c].end_ { break; }
        if max_end - first_unvec < vf && max_end - first_unvec >= slp_sctx[c].minvf { any_profitable = true; }
        first_unvec = scx_first_unvec(c, max_end);
    }
    if !any_profitable && vf >= slp_sctx[c].maxregvf && slp_is_pow2(vf) { slp_sctx[c].ncq = 0; }
    if vf == slp_sctx[c].maxregvf { scx_update_range_sizes_from_cache(c); }
    scx_cq_pop(c);
    if scx_current_vf(c) < 0 {
        if scx_all_vectorized(c) { return false; }
        let rep = slp_sctx[c].repeat;
        if rep >= 4 || (rep > 1 && (slp_sctx[c].repeat_changed || !any_profitable)) { return false; }
        if !scx_update_candidate_vfs(c) { return false; }
        if vf != slp_sctx[c].maxregvf { scx_update_range_sizes_from_cache(c); }
    }
    return true;
}

// ---------------------------------------------------------------- vectorizeStores
// RelatedStoreInsts: std::map<distance, store index> per sequence; sequences are runs of (dist, idx) pairs in
// slp_rsi_d / slp_rsi_i, kept sorted by distance
struct SRsi { base: i64, at: i32, n: i32 }
var slp_rsi: SRsi[>..<];
var slp_rsi_d: i64[>..<];
var slp_rsi_i: i64[>..<];
fn rsi_reset(r: i64, base: i64) {
    let at = slp_rsi_d.len as i32;
    slp_rsi_d.push(0); slp_rsi_i.push(base);
    slp_rsi[r] = SRsi { base: base, at: at, n: 1 };
}
fn rsi_new(base: i64) { slp_rsi.push(SRsi { base: 0, at: 0, n: 0 }); rsi_reset(slp_rsi.len - 1, base); }
// insertOrLookup(InstrIdx, PtrDist): the existing index with that distance, or -1 after inserting
fn rsi_insert_or_lookup(r: i64, idx: i64, d: i64) -> i64 {
    let e = slp_rsi[r];
    var pos: i64 = 0;
    while pos < e.n as i64 && slp_rsi_d[e.at as i64 + pos] < d { pos++; }
    if pos < e.n as i64 && slp_rsi_d[e.at as i64 + pos] == d { return slp_rsi_i[e.at as i64 + pos]; }
    let at = slp_rsi_d.len as i32;
    for k in e.n as i64 {
        if k == pos { slp_rsi_d.push(d); slp_rsi_i.push(idx); }
        slp_rsi_d.push(slp_rsi_d[e.at as i64 + k]); slp_rsi_i.push(slp_rsi_i[e.at as i64 + k]);
    }
    if pos == e.n as i64 { slp_rsi_d.push(d); slp_rsi_i.push(idx); }
    slp_rsi[r] = SRsi { base: e.base, at: at, n: e.n + 1 };
    return -1;
}
fn rsi_pointer_diff(r: i64, si: i32) -> bool, i64 {
    let bs = slp_stores_cur[slp_rsi[r].base];
    let ok, d = laa_get_pointers_diff(vals[op(bs, 0)].ty, op(bs, 1), vals[op(si, 0)].ty, op(si, 1), true, true);
    return ok, d;
}
fn rsi_rebase(r: i64, min_safe: i64, new_base: i64, dist: i64) {
    let e = slp_rsi[r];
    rsi_reset(r, new_base);
    for k in e.n as i64 {
        let ii = slp_rsi_i[e.at as i64 + k];
        if ii >= min_safe { rsi_insert_or_lookup(r, ii, slp_rsi_d[e.at as i64 + k] - dist); }
    }
}
// ExtendContexts(StoreSeq)
fn slp_extend_contexts(r: i64) {
    let max_stride: i64 = if flag_bool("slp-enable-strided-stores", false) { flag_int("slp-max-stride", 8) } else { 1 };
    let nch = max_stride + 1;
    // Chains[key]: lists of PartialChainStatus (added, idx, first store, stride)
    var ch_key: i64[>..<] = [];
    var ch_added: bool[>..<] = [];
    var ch_idx: i64[>..<] = [];
    var ch_first: i32[>..<] = [];
    var ch_stride: i64[>..<] = [];
    var ch_alive: bool[>..<] = [];
    fn key(q: i64) -> i64 { var rem = q % nch; if rem < 0 { rem += nch; } return rem; }
    fn clear_key(kk: i64) { for j in ch_key.len { if ch_alive[j] && ch_key[j] == kk { ch_alive[j] = false; } } }
    let e = slp_rsi[r];
    var last: i64 = 0;
    let mps = flag_int("slp-max-stride", 8);
    for idx in e.n as i64 {
        let dist = slp_rsi_d[e.at as i64 + idx];
        let ii = slp_rsi_i[e.at as i64 + idx];
        if idx > 0 {
            var d = last;
            let lim = if dist < last + nch { dist } else { last + nch };
            while d < lim { clear_key(key(d)); d++; }
        }
        last = dist;
        var found: bool[>..<] = [];
        for k in mps + 1 { found.push(false); }
        let kd = key(dist);
        let nbefore = ch_key.len;
        for j in nbefore {
            if !ch_alive[j] || ch_key[j] != kd { continue; }
            if ch_added[j] {
                scx_add_operand(ch_idx[j] as i32, slp_stores_cur[ii], ii);
            } else {
                let c = scx_new(ch_first[j], ch_idx[j], slp_stores_cur[ii], ii, ch_stride[j]);
                ch_idx[j] = c as i64;
            }
            let nk = key(ch_stride[j] + dist);
            ch_key.push(nk); ch_added.push(true); ch_idx.push(ch_idx[j]); ch_first.push(-1); ch_stride.push(ch_stride[j]); ch_alive.push(true);
            found[ch_stride[j]] = true;
        }
        for j in nbefore { if ch_alive[j] && ch_key[j] == kd { ch_alive[j] = false; } }
        for st in 1..max_stride + 1 {
            if found[st] { continue; }
            let nk = key(dist + st);
            ch_key.push(nk); ch_added.push(false); ch_idx.push(ii); ch_first.push(slp_stores_cur[ii]); ch_stride.push(st); ch_alive.push(true);
        }
    }
}
// vectorizeStores(Stores, R, Visited, AllowMaskedStores)
fn slp_vectorize_stores(stores: const i32[:], allow_masked: bool) -> bool {
    var changed = false;
    slp_vectorized_stores.clear();
    slp_sctx.clear(); slp_sc_ops.clear(); slp_sc_rs1.clear(); slp_sc_rs2.clear(); slp_sc_cq.clear();
    slp_sc_ns_key.clear(); slp_sc_ns_ctx.clear(); slp_sc_ns_max.clear(); slp_sc_ns_min.clear();
    slp_range_sizes_by_idx.clear();
    for k in stores.len { slp_range_sizes_by_idx.push(1); }
    slp_stores_cur.clear();
    for s in stores { slp_stores_cur.push(s); }
    slp_rsi.clear(); slp_rsi_d.clear(); slp_rsi_i.clear();
    var prev_ty: i32 = -1;
    for i in stores.len {
        let si = stores[i];
        if slp_is_deleted(si) { continue; }
        if prev_ty < 0 { prev_ty = vals[op(si, 0)].ty; }
        if prev_ty != vals[op(si, 0)].ty as i32 {
            for r in slp_rsi.len { slp_extend_contexts(r); }
            slp_rsi.clear();
            prev_ty = vals[op(si, 0)].ty;
        }
        // FillStoresSet(I, SI)
        var rel: i64 = -1;
        var pd: i64 = 0;
        for r in slp_rsi.len {
            let ok, d = rsi_pointer_diff(r, si);
            if ok { rel = r; pd = d; break; }
        }
        if rel < 0 { rsi_new(i); continue; }
        let prev = rsi_insert_or_lookup(rel, i, pd);
        if prev >= 0 {
            slp_extend_contexts(rel);
            rsi_rebase(rel, prev + 1, i, pd);
        }
    }
    for r in slp_rsi.len { slp_extend_contexts(r); }
    // ActuallyVectorizeContexts()
    var gmax: i64 = 0;
    for c in slp_sctx.len {
        if scx_initialize(c as i32) { let m = slp_sctx[c].maxvf; if m > gmax { gmax = m; } } else { slp_sctx[c].alive = false; }
    }
    // stable_sort: live contexts by stride, dead ones last
    var order: i32[>..<] = [];
    for c in slp_sctx.len { order.push(c as i32); }
    for a in 1..order.len {
        var j = a;
        while j > 0 {
            let x = order[j];
            let y = order[j - 1];
            let less = slp_sctx[x].alive && (!slp_sctx[y].alive || slp_sctx[x].stride < slp_sctx[y].stride);
            if !less { break; }
            order[j] = y; order[j - 1] = x;
            j--;
        }
    }
    var limit = gmax;
    while limit > 0 {
        for c in order {
            if !slp_sctx[c].alive { break; }
            var vf = scx_current_vf(c);
            while vf >= 0 && vf >= limit {
                if !scx_vectorize_one_vf(c, vf, changed) { slp_sctx[c].alive = false; break; }
                vf = scx_current_vf(c);
            }
        }
        limit = slp_bit_ceil(limit) / 2;
    }
    if !allow_masked { return changed; }
    var rem: i32[>..<] = [];
    for s in stores {
        if slp_is_deleted(s) { continue; }
        var vec = false;
        for x in slp_vectorized_stores { if x == s { vec = true; break; } }
        if !vec { rem.push(s); }
    }
    if rem.len < 2 { return changed; }
    let vt = slp_value_type(rem[0], false);
    for s in rem { if vals[op(s, 0)].ty as i32 != vt { return changed; } }
    var ptrs: i32[>..<] = [];
    for s in rem { ptrs.push(op(s, 1)); }
    var ord: i32[>..<] = [];
    if !slp_sort_ptr_accesses(ptrs, vt, ord) { return changed; }
    var sorted: i32[>..<] = [];
    for i in rem.len { sorted.push(rem[if ord.len == 0 { i } else { ord[i] as i64 }]); }
    let f = sorted[0];
    let b = sorted[sorted.len - 1];
    if !slp_attempted_insert(f, op(f, 0), b, op(b, 0), sorted.len) { return changed; }
    let res, sz = slp_vectorize_store_chain(sorted, 0, 2);
    if res > 0 { for x in sorted { slp_vectorized_stores.push(x); } changed = true; }
    return changed;
}

// ---------------------------------------------------------------- vectorizeStoreChains
fn slp_dom_dfs_in(bb: i32) -> u32 { dt_dfs_in(slp_fn, DT_DOM, bb) }
// StoreSorter(V, V2)
fn slp_store_less(v: i32, v2: i32) -> bool {
    let a = op(v, 0);
    let b = op(v2, 0);
    let ta = slp_type_id(vals[a].ty);
    let tb = slp_type_id(vals[b].ty);
    if ta < tb { return true; }
    if ta > tb { return false; }
    let pa = slp_type_id(vals[op(v, 1)].ty);
    let pb = slp_type_id(vals[op(v2, 1)].ty);
    if pa < pb { return true; }
    if pa > pb { return false; }
    let sa = tt_scalar_bits(vals[a].ty);
    let sb = tt_scalar_bits(vals[b].ty);
    if sa < sb { return true; }
    if sa > sb { return false; }
    let i1 = is_inst(a);
    let i2 = is_inst(b);
    if i1 && i2 {
        let n1 = inst_parent(a);
        let n2 = inst_parent(b);
        if n1 != n2 { return slp_dom_dfs_in(n1) < slp_dom_dfs_in(n2); }
        return iop(a) < iop(b);
    }
    if i1 && !i2 { return true; }
    if !i1 && i2 { return false; }
    return slp_value_id(a) < slp_value_id(b);
}
var slp_same_parent: bool = true;
// AreCompatibleStores(VL, V1)
fn slp_compatible_stores(vl: const i32[:], v1: i32) -> bool {
    if vl.len == 0 { slp_same_parent = true; return true; }
    let v2 = vl[vl.len - 1];
    if v1 == v2 { return true; }
    let a = op(v1, 0);
    let b = op(v2, 0);
    if vals[a].ty as i32 != vals[b].ty as i32 { return false; }
    if vals[op(v1, 1)].ty as i32 != vals[op(v2, 1)].ty as i32 { return false; }
    if is_undef_or_poison(a) || is_undef_or_poison(b) { return true; }
    if is_constant(a) && is_constant(b) { return true; }
    let i1 = is_inst(a);
    let i2 = is_inst(b);
    if i1 || i2 {
        if i1 && !i2 { return false; }
        slp_same_parent = slp_same_parent && i1 && i2 && inst_parent(a) == inst_parent(b);
        var nvl: i32[>..<] = [];
        for s in vl { nvl.push(op(s, 0)); }
        nvl.push(a);
        let s = slp_build_instructions_state(nvl, true, !slp_same_parent);
        if s.copy { slp_fail("copyable elements (AreCompatibleStores)"); }
        if sis_valid(s) { return true; }
        if !slp_same_parent { return false; }
    }
    return slp_value_id(a) == slp_value_id(b);
}
// HasConsecutiveStoresOrSameAddress(SIs)
fn slp_has_consecutive_or_same_address(sis: const i32[:]) -> bool {
    if sis.len < 2 { return false; }
    let ty: i32 = vals[op(sis[0], 0)].ty;
    let base = op(sis[0], 1);
    var offs: i64[>..<] = [];
    for s in sis {
        let ok, d = laa_get_pointers_diff(ty, base, ty, op(s, 1), false, true);
        if ok { offs.push(d); }
    }
    sort(offs) { a, b => a < b };
    for i in 1..offs.len { if offs[i] - offs[i - 1] == 1 || offs[i] == offs[i - 1] { return true; } }
    return false;
}
// tryToVectorizeSequence<StoreInst>(Incoming, StoreSorter, AreCompatibleStores, vectorizeStores, MaxVFOnly = false)
fn slp_try_vectorize_store_sequence(incoming: i32[>..<]&, allow_masked: bool) -> bool {
    var changed = false;
    // stable_sort (insertion sort: StoreSorter is a strict weak order)
    for a in 1..incoming.len {
        var j = a;
        while j > 0 && slp_store_less(incoming[j], incoming[j - 1]) {
            let t = incoming[j]; incoming[j] = incoming[j - 1]; incoming[j - 1] = t;
            j--;
        }
    }
    var cands: i32[>..<] = [];
    var vl: i32[>..<] = [];
    var it: i64 = 0;
    let e = incoming.len;
    while it != e {
        vl.clear();
        let i = incoming[it];
        if slp_is_deleted(i) || !slp_is_valid_element_type(slp_value_type(i, false)) { it++; continue; }
        var st = it;
        while st != e && (slp_is_deleted(incoming[st]) || slp_compatible_stores(vl, incoming[st])) {
            let x = incoming[st];
            st++;
            if !slp_is_deleted(x) { vl.push(x); }
        }
        let n = vl.len;
        if slp_dbg_on { errs("SLP: Trying to vectorize starting at nodes ("); errs_int(n); errs(")\n"); slp_dbg_flush(); }
        if n > 1 && slp_vectorize_stores(vl, allow_masked) {
            changed = true;
            cands.clear();
            for v in vl { if !slp_is_deleted(v) { cands.push(v); } }
        } else {
            let es = slp_vector_element_size(incoming[it]);
            let mn = if slp_max_vreg / es > 2 { slp_max_vreg / es } else { 2 };
            if n < mn && (cands.len == 0 || vals[cands[0]].ty as i32 == vals[incoming[it]].ty as i32) {
                for v in vl { if !slp_is_deleted(v) { cands.push(v); } }
            }
        }
        if cands.len > 1 && (st == e || vals[incoming[st]].ty as i32 != vals[incoming[it]].ty as i32) {
            if slp_vectorize_stores(cands, allow_masked) { changed = true; }
            cands.clear();
        }
        it = st;
    }
    return changed;
}
// vectorizeStoreChains(R): the store groups are slp.goose's Stores MapVector
fn slp_vectorize_store_chains_r(keys_n: i64, key_of: const i32[:], insts_: const i32[:]) -> bool {
    var changed = false;
    slp_attempted.clear();
    for k in keys_n {
        var grp: i32[>..<] = [];
        for j in key_of.len { if key_of[j] as i64 == k { grp.push(insts_[j]); } }
        if grp.len < 2 { continue; }
        if slp_dbg_on { errs("SLP: Analyzing a store chain of length "); errs_int(grp.len); errs(".\n"); slp_dbg_flush(); }
        if !slp_is_valid_element_type(vals[op(grp[0], 0)].ty) { continue; }
        let allow_masked = flag_bool("slp-enable-masked-stores", true) && !slp_has_consecutive_or_same_address(grp);
        var rev: i32[>..<] = [];
        var x = grp.len;
        while x > 0 { x--; rev.push(grp[x]); }
        if slp_try_vectorize_store_sequence(rev, allow_masked) { changed = true; }
    }
    return changed;
}

// ---------------------------------------------------------------- tryToVectorizeList
// tryToVectorizeList(VL, R, MaxVFOnly, LimitToRegisterVF)
fn slp_try_to_vectorize_list_r(vl: const i32[:], max_vf_only: bool, limit_reg_vf: bool) -> bool {
    if vl.len < 2 { return false; }
    if slp_dbg_on { errs("SLP: Trying to vectorize a list of length = "); errs_int(vl.len); errs(".\n"); slp_dbg_flush(); }
    let s = slp_get_same_opcode(vl);
    if !sis_valid(s) { return false; }
    let i0 = s.main;
    for v in vl {
        if !(is_inst_op(v, OP_INSERTELEMENT) || is_inst_op(v, OP_INSERTVALUE)) && !slp_is_valid_element_type(vals[v].ty) { return false; }
    }
    let sty = slp_value_type(vl[0], true);
    let sz = slp_vector_element_size(i0);
    let minvf = slp_min_vf(sz);
    var maxvf = slp_floor_full_vector_number_of_elements(sty, vl.len);
    if maxvf < minvf { maxvf = minvf; }
    let mvf = slp_maximum_vf(sz, sis_opcode(s));
    if mvf < maxvf { maxvf = mvf; }
    if limit_reg_vf && sz != 0 {
        let x = if minvf > slp_max_vreg / sz { minvf } else { slp_max_vreg / sz };
        if x < maxvf { maxvf = x; }
    }
    if maxvf < 2 { return false; }
    var changed = false;
    var next_inst: i64 = 0;
    let max_inst = vl.len;
    var vf = maxvf;
    while next_inst + 1 < max_inst && vf >= minvf {
        let vecty = slp_widened_type(sty, vf);
        if slp_number_of_parts(vecty, sty, 0x7FFFFFFFFFFFFFFF) == vf {
            vf = slp_floor_full_vector_number_of_elements(vals[i0].ty, vf - 1);
            continue;
        }
        var i = next_inst;
        while i < max_inst {
            let avf = if max_inst - i < vf { max_inst - i } else { vf };
            if !slp_has_full_vectors_or_pow2(sty, avf) { i++; continue; }
            if max_vf_only && avf < maxvf { break; }
            if (vf > minvf && avf < vf) || (vf == minvf && avf < 2) { break; }
            var ops: i32[>..<] = [];
            for k in i..vl.len {
                let v = vl[k];
                if !is_inst(v) || !slp_is_deleted(v) {
                    ops.push(v);
                    if ops.len == avf { break; }
                }
            }
            if ops.len != avf { break; }
            if slp_dbg_on { errs("SLP: Analyzing "); errs_int(avf); errs(" operations \n"); slp_dbg_flush(); }
            let none_: i32[1] = [0];
            slp_build_tree(ops, false, none_[..0]);
            if slp_is_tree_tiny_and_not_fully_vectorizable(false) { i++; continue; }
            slp_after_tree();
            i++;
        }
        vf = slp_floor_full_vector_number_of_elements(vals[i0].ty, vf - 1);
    }
    return changed;
}
