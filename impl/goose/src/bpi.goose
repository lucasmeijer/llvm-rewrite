// BranchProbabilityInfo: a port of llvm/lib/Analysis/BranchProbabilityInfo.cpp (BPIConstruction with SccInfo,
// the estimated block weights and every heuristic, the result's edge storage and print<branch-prob>) and
// BranchProbability (llvm/include/llvm/Support/BranchProbability.h, llvm/lib/Support/BranchProbability.cpp).
// The CFG scc_iterator (llvm/include/llvm/ADT/SCCIterator.h) is bpi_sccs.
//
// One result exists at a time (bpi_fn). Edge probabilities: bpi_start (block value id -> 1 + start in
// bpi_probs, 0 = no edges; LLVM's EdgeStarts by block number) and bpi_probs (u32 numerators over 1 << 31).
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_attrs;
import gen_iids;
import tti;
import tli;
import domtree;
import loopinfo;
import cfgutil;
import profdata;
import cfold;
import flags;
import scev;
import analyses;

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
// The result: edge probabilities per block

var bpi_fn: i32 = -1;
var bpi_probs: u32[>..<];
var bpi_start = hm_new();

fn bpi_valid(fv: i32) -> bool { bpi_fn == fv && fv >= 0 }
fn bpi_invalidate() { bpi_fn = -1; bpi_probs.clear(); hm_clear(bpi_start); }
fn bpi_key(bb: i32) -> u64 { (bb as i64) as u64 }
fn bpi_nsucc(bb: i32) -> i64 { let t = block_terminator(bb); if t < 0 { 0 } else { term_nsucc(t) } }

// allocEdges: the start of the block's new edge run, or -1 (no successors: eraseBlock)
fn bpi_alloc_edges(bb: i32) -> i64 {
    let n = bpi_nsucc(bb);
    if n == 0 { bpi_erase_block(bb); return -1; }
    let st = bpi_probs.len;
    hm_put(bpi_start, bpi_key(bb), st + 1);
    for k in n { bpi_probs.push(BP_UNKNOWN); }
    return st;
}
// getEdges: start or -1
fn bpi_edges(bb: i32) -> i64 { let s = hm_get(bpi_start, bpi_key(bb), 0); return if s == 0 { -1 } else { s - 1 }; }
// eraseBlock
fn bpi_erase_block(bb: i32) { if hm_has(bpi_start, bpi_key(bb)) { hm_put(bpi_start, bpi_key(bb), 0); } }
// setEdgeProbability(Src, Probs)
fn bpi_set_edge_probability(bb: i32, ps: const u32[:]) {
    let st = bpi_alloc_edges(bb);
    if st < 0 { return; }
    for k in ps.len { bpi_probs[st + k] = ps[k]; }
}
// copyEdgeProbabilities(Src, Dst)
fn bpi_copy_edge_probabilities(src: i32, dst: i32) {
    let dstp = bpi_alloc_edges(dst);
    let srcp = bpi_edges(src);
    if srcp < 0 { bpi_erase_block(dst); return; }
    if dstp < 0 { return; }
    for k in bpi_nsucc(dst) { bpi_probs[dstp + k] = bpi_probs[srcp + k]; }
}
// getEdgeProbability(Src, IndexInSuccessors)
fn bpi_edge_prob_idx(src: i32, k: i64) -> u32 {
    let p = bpi_edges(src);
    if p >= 0 { return bpi_probs[p + k]; }
    return bp_new(1, bpi_nsucc(src) as u64);
}
// getEdgeProbability(Src, Dst): the sum over all edges from Src to Dst
fn bpi_edge_prob_to(src: i32, dst: i32) -> u32 {
    let t = block_terminator(src);
    let n = bpi_nsucc(src);
    let p = bpi_edges(src);
    if p < 0 {
        var c: u64 = 0;
        for k in n { if term_succ(t, k) == dst { c++; } }
        return bp_new(c, n as u64);
    }
    var prob: u32 = 0;
    for k in n { if term_succ(t, k) == dst { prob = bp_add(prob, bpi_probs[p + k]); } }
    return prob;
}
// isEdgeHot
fn bpi_is_edge_hot(src: i32, dst: i32) -> bool { bpi_edge_prob_to(src, dst) > bp_new(4, 5) }

// ---------------------------------------------------------------------------------------------
// scc_iterator over the CFG (blocks from the entry, successors in terminator order): every SCC in the order
// the iterator yields them, flattened into out with each SCC's size before its blocks.

fn bpi_sccs(fv: i32, out: i32[>..<]&) {
    out.clear();
    var num = hm_new();                 // nodeVisitNumbers
    var scc_stack: i32[>..<] = [];      // SCCNodeStack
    var vs_node: i32[>..<] = [];        // VisitStack: node, next child, min visited
    var vs_next: i64[>..<] = [];
    var vs_min: u64[>..<] = [];
    var visit_num: u64 = 0;
    let entry = func_entry(fv);
    // DFSVisitOne(entry)
    visit_num++;
    hm_put(num, bpi_key(entry), visit_num as i64);
    scc_stack.push(entry);
    vs_node.push(entry); vs_next.push(0); vs_min.push(visit_num);
    while vs_node.len > 0 {
        // GetNextSCC
        var found = false;
        while vs_node.len > 0 && !found {
            // DFSVisitChildren
            loop {
                let top = vs_node.len - 1;
                let n = vs_node[top];
                if vs_next[top] >= bpi_nsucc(n) { break; }
                let c = term_succ(block_terminator(n), vs_next[top]);
                vs_next[top] = vs_next[top] + 1;
                let cn = hm_get(num, bpi_key(c), -1);
                if cn < 0 {
                    visit_num++;
                    hm_put(num, bpi_key(c), visit_num as i64);
                    scc_stack.push(c);
                    vs_node.push(c); vs_next.push(0); vs_min.push(visit_num);
                    continue;
                }
                if vs_min[top] > (cn as u64) { vs_min[top] = cn as u64; }
            }
            let top = vs_node.len - 1;
            let visiting = vs_node[top];
            let minv = vs_min[top];
            vs_node.pop(); vs_next.pop(); vs_min.pop();
            if vs_node.len > 0 && vs_min[vs_node.len - 1] > minv { vs_min[vs_node.len - 1] = minv; }
            if minv != (hm_get(num, bpi_key(visiting), -1) as u64) { continue; }
            let sz_at = out.len;
            out.push(0);
            loop {
                let x = scc_stack.pop();
                out.push(x);
                hm_put(num, bpi_key(x), 0xFFFFFFFF);
                if x == visiting { break; }
            }
            out[sz_at] = (out.len - sz_at - 1) as i32;
            found = true;
        }
    }
}

// ---------------------------------------------------------------------------------------------
// BPIConstruction

let LBH_TAKEN_WEIGHT: u64 = 124;
let LBH_NONTAKEN_WEIGHT: u64 = 4;
let BEW_ZERO: u64 = 0;
let BEW_LOWEST_NON_ZERO: u64 = 1;
let BEW_UNREACHABLE: u64 = 0;
let BEW_NORETURN: u64 = 1;
let BEW_UNWIND: u64 = 1;
let BEW_COLD: u64 = 0xffff;
let BEW_DEFAULT: u64 = 0xfffff;
let SCC_HEADER: u32 = 1;
let SCC_EXITING: u32 = 2;

var bc_scc_num = hm_new();          // SccNums: block -> SCC id
var bc_scc_type = hm_new();         // SccBlocks: (SCC id, block) -> type (only non-Inner blocks)
var bc_scc_blocks: i32[>..<];       // the blocks of SccBlocks[SccNum] in insertion order: (scc, block) pairs
var bc_block_weight = hm_new();     // EstimatedBlockWeight
var bc_loop_weight = hm_new();      // EstimatedLoopWeight: LoopData key -> weight
var bc_loop_exits = hm_new();       // LoopExitBlocks: LoopData key -> start in bc_exit_pool (+1)
var bc_exit_pool: i32[>..<];        // runs: count, blocks...

// LoopData = (Loop, SccNum): a loop id >= 0, or -2 - scc, or -1 for none
fn bc_scc_num_of(bb: i32) -> i64 { hm_get(bc_scc_num, bpi_key(bb), -1) }
fn bc_loop_of(bb: i32) -> i32 { li_loop_for(bb) }
// LoopBlock(BB): (loop, scc)
fn bc_ld(bb: i32) -> i64 {
    let l = li_loop_for(bb);
    if l >= 0 { return l as i64; }
    let s = bc_scc_num_of(bb);
    if s >= 0 { return -2 - s; }
    return -1;
}
fn bc_ld_loop(ld: i64) -> i32 { if ld >= 0 { ld as i32 } else { -1 } }
fn bc_ld_scc(ld: i64) -> i64 { if ld <= -2 { -2 - ld } else { -1 } }
fn bc_ld_key(ld: i64) -> u64 { ((ld + 2) as u64) }

fn bc_scc_block_type(bb: i32, scc: i64) -> u32 { hm_get(bc_scc_type, hk2(scc as i32, bb), 0) as u32 }
fn bc_is_scc_header(bb: i32, scc: i64) -> bool { (bc_scc_block_type(bb, scc) & SCC_HEADER) != 0 }
fn bc_is_scc_exiting(bb: i32, scc: i64) -> bool { (bc_scc_block_type(bb, scc) & SCC_EXITING) != 0 }

// SccInfo::calculateSccBlockType
fn bc_calculate_scc_block_type(bb: i32, scc: i64) {
    var t: u32 = 0;
    var hdr = false;
    each_pred(bb) { p => if bc_scc_num_of(p) != scc { hdr = true; } };
    if hdr { t = t | SCC_HEADER; }
    let tm = block_terminator(bb);
    if tm >= 0 { for k in term_nsucc(tm) { if bc_scc_num_of(term_succ(tm, k)) != scc { t = t | SCC_EXITING; } } }
    if t != 0 {
        hm_put(bc_scc_type, hk2(scc as i32, bb), t as i64);
        bc_scc_blocks.push(scc as i32);
        bc_scc_blocks.push(bb);
    }
}
// SccInfo::SccInfo(F)
fn bc_scc_info(fv: i32) {
    hm_clear(bc_scc_num);
    hm_clear(bc_scc_type);
    bc_scc_blocks.clear();
    var sccs: i32[>..<] = [];
    bpi_sccs(fv, sccs);
    var k: i64 = 0;
    var num: i64 = 0;
    while k < sccs.len {
        let n = sccs[k] as i64;
        if n != 1 {
            for j in n {
                let bb = sccs[k + 1 + j];
                hm_put(bc_scc_num, bpi_key(bb), num);
                bc_calculate_scc_block_type(bb, num);
            }
        }
        k += n + 1;
        num++;
    }
}
// getSccEnterBlocks / getSccExitBlocks (SccBlocks iterated in insertion order; LLVM's DenseMap is pointer order)
fn bc_scc_enter_blocks(scc: i64, out: i32[>..<]&) {
    var k: i64 = 0;
    while k < bc_scc_blocks.len {
        if bc_scc_blocks[k] as i64 == scc {
            let bb = bc_scc_blocks[k + 1];
            if bc_is_scc_header(bb, scc) { each_pred(bb) { p => if bc_scc_num_of(p) != scc { out.push(bb); } }; }
        }
        k += 2;
    }
}
fn bc_scc_exit_blocks(scc: i64, out: i32[>..<]&) {
    var k: i64 = 0;
    while k < bc_scc_blocks.len {
        if bc_scc_blocks[k] as i64 == scc {
            let bb = bc_scc_blocks[k + 1];
            if bc_is_scc_exiting(bb, scc) {
                let tm = block_terminator(bb);
                for j in term_nsucc(tm) { let s = term_succ(tm, j); if bc_scc_num_of(s) != scc { out.push(s); } }
            }
        }
        k += 2;
    }
}

// isLoopEnteringEdge / isLoopExitingEdge / isLoopEnteringExitingEdge / isLoopBackEdge on (src, dst) LoopData
fn bc_is_loop_entering(src: i64, dst: i64) -> bool {
    let dl = bc_ld_loop(dst);
    if dl >= 0 && !loop_contains_loop(dl, bc_ld_loop(src)) { return true; }
    return bc_ld_scc(dst) != -1 && bc_ld_scc(src) != bc_ld_scc(dst);
}
fn bc_is_loop_exiting(src: i64, dst: i64) -> bool { bc_is_loop_entering(dst, src) }
fn bc_is_loop_entering_exiting(src: i64, dst: i64) -> bool { bc_is_loop_entering(src, dst) || bc_is_loop_exiting(src, dst) }

// getLoopEnterBlocks / getLoopExitBlocks
fn bc_loop_enter_blocks(ld: i64, out: i32[>..<]&) {
    let l = bc_ld_loop(ld);
    if l >= 0 { each_pred(loop_header(l)) { p => out.push(p); }; }
    else { bc_scc_enter_blocks(bc_ld_scc(ld), out); }
}
fn bc_loop_exit_blocks(ld: i64, out: i32[>..<]&) {
    let l = bc_ld_loop(ld);
    if l >= 0 { var tmp: i32[>..<] = []; loop_exit_blocks(l, tmp); for x in tmp { out.push(x); } }
    else { bc_scc_exit_blocks(bc_ld_scc(ld), out); }
}

// getEstimatedBlockWeight / getEstimatedLoopWeight / getEstimatedEdgeWeight: -1 = std::nullopt
fn bc_block_weight_of(bb: i32) -> i64 { hm_get(bc_block_weight, bpi_key(bb), -1) }
fn bc_loop_weight_of(ld: i64) -> i64 { hm_get(bc_loop_weight, bc_ld_key(ld), -1) }
fn bc_edge_weight(src: i32, dst: i32) -> i64 {
    let sl = bc_ld(src);
    let dl = bc_ld(dst);
    if bc_is_loop_entering(sl, dl) { return bc_loop_weight_of(dl); }
    return bc_block_weight_of(dst);
}
// getMaxEstimatedEdgeWeight over a list of successors
fn bc_max_edge_weight(src: i32, succs: const i32[:]) -> i64 {
    var mx: i64 = -1;
    for d in succs {
        let w = bc_edge_weight(src, d);
        if w < 0 { return -1; }
        if mx < 0 || mx < w { mx = w; }
    }
    return mx;
}

// updateEstimatedBlockWeight
fn bc_update_block_weight(bb: i32, w: i64, bwl: i32[>..<]&, lwl: i64[>..<]&) -> bool {
    if hm_has(bc_block_weight, bpi_key(bb)) { return false; }
    hm_put(bc_block_weight, bpi_key(bb), w);
    let ld = bc_ld(bb);
    var preds: i32[>..<] = [];
    each_pred(bb) { p => preds.push(p); };
    for p in preds {
        let pl = bc_ld(p);
        if bc_is_loop_exiting(pl, ld) {
            if !hm_has(bc_loop_weight, bc_ld_key(pl)) { lwl.push(pl); lwl.push(p as i64); }
        } else if !hm_has(bc_block_weight, bpi_key(p)) {
            bwl.push(p);
        }
    }
    return true;
}

// propagateEstimatedBlockWeight
fn bc_propagate_block_weight(bb: i32, w: i64, bwl: i32[>..<]&, lwl: i64[>..<]&) {
    let fv = block_func(bb);
    let pstart = dt_post_node(bb);
    let ld = bc_ld(bb);
    var d = if dt_has_node(DT_DOM, bb) { bb } else { -1 };
    while d >= 0 {
        if !dt_dominates_nodes(fv, DT_POST, pstart, dt_post_node(d)) { break; }
        let dl = bc_ld(d);
        if !bc_is_loop_entering_exiting(dl, ld) {
            if !bc_update_block_weight(d, w, bwl, lwl) { break; }
        } else if bc_is_loop_exiting(dl, ld) {
            lwl.push(dl);
            lwl.push(d as i64);
        }
        d = dt_idom(DT_DOM, d);
    }
}
// PDT->getNode(BB): the block's node or -1
fn dt_post_node(bb: i32) -> i32 { if dt_has_node(DT_POST, bb) { bb } else { -1 } }

// getInitialEstimatedBlockWeight: -1 = std::nullopt
fn bc_initial_block_weight(bb: i32) -> i64 {
    let t = block_terminator(bb);
    if iop(t) == OP_UNREACHABLE || cu_terminating_deoptimize_call(bb) >= 0 {
        var noret = false;
        var i = block_last(bb);
        while i >= 0 { if iop(i) == OP_CALL && call_has_fn_attr(i, AK_NoReturn) { noret = true; break; } i = inst_prev(i); }
        return if noret { BEW_NORETURN as i64 } else { BEW_UNREACHABLE as i64 };
    }
    let f = first_non_phi(bb);
    if f >= 0 && inst_is_eh_pad(f) { return BEW_UNWIND as i64; }
    var i = block_first(bb);
    while i >= 0 {
        if iop(i) == OP_CALL && call_has_fn_attr(i, AK_Cold) { return BEW_COLD as i64; }
        i = inst_next(i);
    }
    return -1;
}

// post_order(&F.getEntryBlock()) (po_iterator: successors in order, a block is emitted after its children)
fn bpi_post_order(fv: i32, out: i32[>..<]&) {
    out.clear();
    var seen = hm_new();
    var sb: i32[>..<] = [];
    var sk: i64[>..<] = [];
    let e = func_entry(fv);
    hm_put(seen, bpi_key(e), 1);
    sb.push(e);
    sk.push(0);
    while sb.len > 0 {
        let top = sb.len - 1;
        let n = sb[top];
        if sk[top] < bpi_nsucc(n) {
            let c = term_succ(block_terminator(n), sk[top]);
            sk[top] = sk[top] + 1;
            if !hm_has(seen, bpi_key(c)) {
                hm_put(seen, bpi_key(c), 1);
                sb.push(c);
                sk.push(0);
            }
            continue;
        }
        out.push(n);
        sb.pop();
        sk.pop();
    }
}

// estimateBlockWeights
fn bc_estimate_block_weights(fv: i32) {
    var bwl: i32[>..<] = [];
    var lwl: i64[>..<] = [];        // LoopBlock pairs: LoopData, block
    hm_clear(bc_loop_exits);
    bc_exit_pool.clear();
    var po: i32[>..<] = [];
    bpi_post_order(fv, po);
    var k = po.len - 1;
    while k >= 0 {
        let bb = po[k];
        let w = bc_initial_block_weight(bb);
        if w >= 0 { bc_propagate_block_weight(bb, w, bwl, lwl); }
        k--;
    }
    loop {
        while lwl.len > 0 {
            let lbb = lwl.pop() as i32;
            let ld = lwl.pop();
            if hm_has(bc_loop_weight, bc_ld_key(ld)) { continue; }
            var st = hm_get(bc_loop_exits, bc_ld_key(ld), 0);
            if st == 0 {
                var ex: i32[>..<] = [];
                bc_loop_exit_blocks(ld, ex);
                st = bc_exit_pool.len + 1;
                bc_exit_pool.push(ex.len as i32);
                for x in ex { bc_exit_pool.push(x); }
                hm_put(bc_loop_exits, bc_ld_key(ld), st);
            }
            let at = st - 1;
            let n = bc_exit_pool[at] as i64;
            var exits: i32[>..<] = [];
            for j in n { exits.push(bc_exit_pool[at + 1 + j]); }
            var lw = bc_max_edge_weight(lbb, exits);
            if lw >= 0 {
                if lw <= BEW_UNREACHABLE as i64 { lw = BEW_LOWEST_NON_ZERO as i64; }
                hm_put(bc_loop_weight, bc_ld_key(ld), lw);
                bc_loop_enter_blocks(ld, bwl);
            }
        }
        while bwl.len > 0 {
            let bb = bwl.pop();
            if hm_has(bc_block_weight, bpi_key(bb)) { continue; }
            var succs: i32[>..<] = [];
            let t = block_terminator(bb);
            for j in term_nsucc(t) { succs.push(term_succ(t, j)); }
            let mw = bc_max_edge_weight(bb, succs);
            if mw >= 0 { bc_propagate_block_weight(bb, mw, bwl, lwl); }
        }
        if bwl.len == 0 && lwl.len == 0 { break; }
    }
}

// calcMetadataWeights
fn bc_calc_metadata_weights(bb: i32) -> bool {
    let t = block_terminator(bb);
    let o = iop(t);
    if !(o == OP_CONDBR || o == OP_SWITCH || o == OP_INDIRECTBR || o == OP_INVOKE || o == OP_CALLBR) { return false; }
    let m = pd_valid_md(t);
    if m < 0 { return false; }
    var ws: u64[>..<] = [];
    pd_extract_md(m, ws);
    var sum: u64 = 0;
    var unr: i64[>..<] = [];
    var reach: i64[>..<] = [];
    for i in ws.len {
        sum += ws[i];
        let w = bc_edge_weight(bb, term_succ(t, i));
        if w >= 0 && (w as u64) <= BEW_UNREACHABLE { unr.push(i); } else { reach.push(i); }
    }
    let n = term_nsucc(t);
    let sf: u64 = if sum > 0xFFFFFFFF { sum / 0xFFFFFFFF + 1 } else { 1 };
    if sf > 1 {
        sum = 0;
        for i in n { ws[i] = ws[i] / sf; sum += ws[i]; }
    }
    if sum == 0 || reach.len == 0 {
        for i in n { ws[i] = 1; }
        sum = n as u64;
    }
    var bp: u32[>..<] = [];
    for i in n { bp.push(bp_new(ws[i] & 0xFFFFFFFF, sum & 0xFFFFFFFF)); }
    if unr.len == 0 || reach.len == 0 { bpi_set_edge_probability(bb, bp); return true; }
    let ur_taken: u32 = 1;
    for i in unr { if ur_taken < bp[i] { bp[i] = ur_taken; } }
    var new_unr: u32 = 0;
    for i in unr { new_unr = bp_add(new_unr, bp[i]); }
    let new_reach = bp_sub(BP_D as u32, new_unr);
    var old_reach: u32 = 0;
    for i in reach { old_reach = bp_add(old_reach, bp[i]); }
    if old_reach != new_reach {
        if old_reach == 0 {
            let per = new_reach / (reach.len as u32);
            for i in reach { bp[i] = per; }
        } else {
            for i in reach {
                let mul = (new_reach as u64) * (bp[i] as u64);
                let d = old_reach as u64;
                bp[i] = ((mul + d / 2) / d) as u32;
            }
        }
    }
    bpi_set_edge_probability(bb, bp);
    return true;
}

// calcPointerHeuristics
fn bc_ptr_taken() -> u32 { bp_new(20, 32) }
fn bc_ptr_untaken() -> u32 { bp_new(12, 32) }
fn bc_calc_pointer_heuristics(bb: i32) -> bool {
    let t = block_terminator(bb);
    if iop(t) != OP_CONDBR { return false; }
    let c = op(t, 0);
    if !is_inst(c) || iop(c) != OP_ICMP { return false; }
    let p = insts[inst_of(c)].pred as i64;
    if p != P_EQ && p != P_NE { return false; }
    if ty_kind(vals[op(c, 0)].ty) != TK_PTR { return false; }
    if p == P_NE { let a: u32[2] = [bc_ptr_taken(), bc_ptr_untaken()]; bpi_set_edge_probability(bb, a); return true; }
    let b: u32[2] = [bc_ptr_untaken(), bc_ptr_taken()];
    bpi_set_edge_probability(bb, b);
    return true;
}

// computeUnlikelySuccessors: the unlikely blocks into out
fn bc_compute_unlikely_successors(bb: i32, l: i32, out: i32[>..<]&) {
    let t = block_terminator(bb);
    if iop(t) != OP_CONDBR { return; }
    let ci = op(t, 0);
    if !is_inst(ci) || (iop(ci) != OP_ICMP && iop(ci) != OP_FCMP) { return; }
    if !is_inst(op(ci, 0)) || !is_constant(op(ci, 1)) { return; }
    var lhs = op(ci, 0);
    var phi = if iop(lhs) == OP_PHI { lhs } else { -1 };
    let cc = op(ci, 1);
    var chain: i32[>..<] = [];
    while phi < 0 && lhs >= 0 && is_binary_op(iop(lhs)) && is_constant(op(lhs, 1)) {
        if !loop_contains(l, inst_parent(lhs)) { return; }
        chain.push(lhs);
        let nx = op(lhs, 0);
        lhs = if is_inst(nx) { nx } else { -1 };
        if lhs >= 0 && iop(lhs) == OP_PHI { phi = lhs; }
    }
    if phi < 0 || !loop_contains(l, inst_parent(phi)) { return; }
    var visited: i32[>..<] = [];
    var wl: i32[>..<] = [];
    wl.push(phi);
    visited.push(phi);
    while wl.len > 0 {
        let p = wl.pop();
        for k in phi_nincoming(p) {
            let b = phi_block(p, k);
            if !loop_contains(l, b) { continue; }
            let v = phi_value_for_block_bpi(p, b);
            if is_inst(v) && iop(v) == OP_PHI {
                var seen = false;
                for x in visited { if x == v { seen = true; } }
                if !seen { visited.push(v); wl.push(v); }
                continue;
            }
            if !is_constant(v) { continue; }
            var is_succ = false;
            for j in term_nsucc(t) { if term_succ(t, j) == b { is_succ = true; } }
            if !is_succ { continue; }
            var c = v;
            var k2 = chain.len - 1;
            while k2 >= 0 {
                let ins = chain[k2];
                c = cf_fold_binop_operands(iop(ins), c, op(ins, 1));
                if c < 0 { break; }
                k2--;
            }
            if c < 0 { continue; }
            let r = cf_fold_cmp_operands(insts[inst_of(ci)].pred as i64, c, cc, -1);
            if r >= 0 && ((is_null_value(r) && b == term_succ(t, 0)) || (bpi_is_one_value(r) && b == term_succ(t, 1))) {
                var seen = false;
                for x in out { if x == b { seen = true; } }
                if !seen { out.push(b); }
            }
        }
    }
}
fn bpi_is_one_value(c: i32) -> bool { vals[c].kind == VK_CINT && !ty_is_vector(vals[c].ty) && cint_lo(c) == 1 && ty_bits(vals[c].ty) <= 64 }
// PHINode::getIncomingValueForBlock (the first entry for the block)
fn phi_value_for_block_bpi(p: i32, b: i32) -> i32 {
    for k in phi_nincoming(p) { if phi_block(p, k) == b { return phi_value(p, k); } }
    return -1;
}

// calcEstimatedHeuristics
fn bc_calc_estimated_heuristics(bb: i32) -> bool {
    let ld = bc_ld(bb);
    let l = bc_ld_loop(ld);
    var unlikely: i32[>..<] = [];
    let tc = LBH_TAKEN_WEIGHT / LBH_NONTAKEN_WEIGHT;
    if l >= 0 { bc_compute_unlikely_successors(bb, l, unlikely); }
    var found = false;
    var sw: u64[>..<] = [];
    var total: u64 = 0;
    let t = block_terminator(bb);
    for k in term_nsucc(t) {
        let s = term_succ(t, k);
        let sl = bc_ld(s);
        var w = bc_edge_weight(bb, s);
        if bc_is_loop_exiting(ld, sl) && w != BEW_ZERO as i64 {
            let base = if w >= 0 { w as u64 } else { BEW_DEFAULT };
            w = max(BEW_LOWEST_NON_ZERO, base / tc) as i64;
        }
        var is_unlikely = false;
        if l >= 0 { for x in unlikely { if x == s { is_unlikely = true; } } }
        if is_unlikely && w != BEW_ZERO as i64 {
            let base = if w >= 0 { w as u64 } else { BEW_DEFAULT };
            w = max(BEW_LOWEST_NON_ZERO, base / 2) as i64;
        }
        if w >= 0 { found = true; }
        let wv = if w >= 0 { w as u64 } else { BEW_DEFAULT };
        total += wv;
        sw.push(wv);
    }
    if !found || total == 0 { return false; }
    let n = sw.len;
    if total > 0xFFFFFFFF {
        let sf = total / 0xFFFFFFFF + 1;
        total = 0;
        for i in n {
            sw[i] = sw[i] / sf;
            if sw[i] == BEW_ZERO { sw[i] = BEW_LOWEST_NON_ZERO; }
            total += sw[i];
        }
    }
    var ep: u32[>..<] = [];
    for i in n { ep.push(bp_new(sw[i], total)); }
    bpi_set_edge_probability(bb, ep);
    return true;
}

// calcZeroHeuristics
fn bc_zero_taken() -> u32 { bp_new(20, 32) }
fn bc_zero_untaken() -> u32 { bp_new(12, 32) }
fn bc_get_constant_int(v: i32) -> i32 {
    if is_inst(v) && iop(v) == OP_BITCAST { let x = op(v, 0); return if vals[x].kind == VK_CINT { x } else { -1 }; }
    return if vals[v].kind == VK_CINT { v } else { -1 };
}
fn bc_calc_zero_heuristics(bb: i32) -> bool {
    let t = block_terminator(bb);
    if iop(t) != OP_CONDBR { return false; }
    let ci = op(t, 0);
    if !is_inst(ci) || iop(ci) != OP_ICMP { return false; }
    let cv = bc_get_constant_int(op(ci, 1));
    if cv < 0 { return false; }
    let lhs = op(ci, 0);
    if is_inst(lhs) && iop(lhs) == OP_AND {
        let ar = bc_get_constant_int(op(lhs, 1));
        if ar >= 0 && ap_is_pow2(ap_from_cint(ar)) { return false; }
    }
    // TLI->getLibFunc(*CalledFn, Func): Func is set from the name even when the prototype check fails
    var lf: i64 = -1;
    if is_inst(lhs) && iop(lhs) == OP_CALL {
        let f = called_function(lhs);
        if f >= 0 && func_iid(f) == 0 { lf = tli_lookup_name(val_name(f)) as i64; }
    }
    let p = insts[inst_of(ci)].pred as i64;
    var likely = false;
    let cvv = ap_from_cint(cv);
    if lf == LF_strcasecmp || lf == LF_strcmp || lf == LF_strncasecmp || lf == LF_strncmp || lf == LF_memcmp || lf == LF_bcmp {
        if p == P_EQ { likely = false; } else if p == P_NE { likely = true; } else { return false; }
    } else if ap_is_zero(cvv) {
        if p == P_EQ { likely = false; } else if p == P_NE { likely = true; }
        else if p == P_SLT { likely = false; } else if p == P_SGT { likely = true; } else { return false; }
    } else if ap_is_one(cvv) {
        if p == P_SLT { likely = false; } else { return false; }
    } else if ap_is_all_ones(cvv) {
        if p == P_EQ { likely = false; } else if p == P_NE { likely = true; } else if p == P_SGT { likely = true; } else { return false; }
    } else {
        return false;
    }
    if likely { let a: u32[2] = [bc_zero_taken(), bc_zero_untaken()]; bpi_set_edge_probability(bb, a); }
    else { let b: u32[2] = [bc_zero_untaken(), bc_zero_taken()]; bpi_set_edge_probability(bb, b); }
    return true;
}

// calcFloatingPointHeuristics
fn bc_calc_fp_heuristics(bb: i32) -> bool {
    let t = block_terminator(bb);
    if iop(t) != OP_CONDBR { return false; }
    let fc = op(t, 0);
    if !is_inst(fc) || iop(fc) != OP_FCMP { return false; }
    let p = insts[inst_of(fc)].pred as i64;
    let fp_taken = bp_new(20, 32);
    let fp_untaken = bp_new(12, 32);
    let ord_taken = bp_new(1024 * 1024 - 1, 1024 * 1024);
    let ord_untaken = bp_new(1, 1024 * 1024);
    // isEquality: oeq, one, ueq, une; isTrueWhenEqual: oeq, ueq (and ole, oge, ule, uge, true)
    if p == 1 || p == 6 || p == 9 || p == 14 {
        let twe = p == 1 || p == 9;
        if !twe { let a: u32[2] = [fp_taken, fp_untaken]; bpi_set_edge_probability(bb, a); }
        else { let b: u32[2] = [fp_untaken, fp_taken]; bpi_set_edge_probability(bb, b); }
    } else if p == 7 {
        let a: u32[2] = [ord_taken, ord_untaken];
        bpi_set_edge_probability(bb, a);
    } else if p == 8 {
        let b: u32[2] = [ord_untaken, ord_taken];
        bpi_set_edge_probability(bb, b);
    } else {
        return false;
    }
    return true;
}

// BranchProbabilityAnalysis::run: LoopInfo, TLI, DT, PDT, then calculate
fn bpi_compute(fv: i32) {
    li_get(fv);
    tli_cur_fn = fv;
    dt_get(fv, DT_DOM);
    dt_get(fv, DT_POST);
    bpi_fn = fv;
    bpi_probs.clear();
    hm_clear(bpi_start);
    hm_clear(bc_block_weight);
    hm_clear(bc_loop_weight);
    bc_scc_info(fv);
    bc_estimate_block_weights(fv);
    var po: i32[>..<] = [];
    bpi_post_order(fv, po);
    for bb in po {
        if bpi_nsucc(bb) < 2 { continue; }
        if bc_calc_metadata_weights(bb) { continue; }
        if bc_calc_estimated_heuristics(bb) { continue; }
        if bc_calc_pointer_heuristics(bb) { continue; }
        if bc_calc_zero_heuristics(bb) { continue; }
        if bc_calc_fp_heuristics(bb) { continue; }
    }
}
// AM.getResult<BranchProbabilityAnalysis>(F)
fn bpi_get(fv: i32) { if !bpi_valid(fv) { bpi_compute(fv); } }

// BranchProbability::print: 0x%08x / 0x%08x = %.2f%% (the percentage rounded with rint first)
fn bp_print(out: u8[>..]&, p: u32) {
    if p == BP_UNKNOWN { out.append("?%"); return; }
    bpi_hex8(out, p as u64);
    out.append(" / ");
    bpi_hex8(out, BP_D);
    out.append(" = ");
    // double Percent = rint(((double)N / D) * 100.0 * 100.0) / 100.0, printed with %.2f
    let x = ((p as f64) / 2147483648.0) * 100.0 * 100.0;
    let f = floor(x);
    let diff = x - f;
    var k = f;
    if diff > 0.5 || (diff == 0.5 && fract(f * 0.5) != 0.0) { k = f + 1.0; }
    let v = k as u64;
    var tmp: u8[>..] = [];
    format_u64_dec(tmp, v / 100);
    out.append(tmp);
    out.push('.');
    let c = v % 100;
    out.push(('0' as u64 + c / 10) as u8);
    out.push(('0' as u64 + c % 10) as u8);
    out.push('%');
}
fn bpi_hex8(out: u8[>..]&, x: u64) {
    out.append("0x");
    let digits = "0123456789abcdef";
    var k: i64 = 7;
    while k >= 0 { out.push(digits[((x >> ((k * 4) as u64)) & 15) as i64]); k--; }
}

// BranchProbabilityPrinterPass::run
fn bpi_print(fv: i32) {
    errs("Printing analysis 'Branch Probability Analysis' for function '");
    errs(val_name(fv));
    errs("':\n");
    bpi_get(fv);
    errs("---- Branch Probabilities ----\n");
    var line: u8[>..] = [];
    var b = func_entry(fv);
    while b >= 0 {
        let t = block_terminator(b);
        if t >= 0 {
            for k in term_nsucc(t) {
                let s = term_succ(t, k);
                line.clear();
                errs("  edge ");
                errs_operand(b, fv, false);
                errs(" -> ");
                errs_operand(s, fv, false);
                errs(" probability is ");
                bp_print(line, bpi_edge_prob_to(b, s));
                errs(line);
                errs(if bpi_is_edge_hot(b, s) { " [HOT edge]\n" } else { "\n" });
            }
        }
        b = block_next(b);
    }
}
