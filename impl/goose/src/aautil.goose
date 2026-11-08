// Helpers shared by the memory analyses (alias analysis, capture tracking, MemorySSA):
//  - private O(1)-clear stamp sets over value ids or use ids (so the analyses never borrow the pass slots
//    of irutil.goose, DESIGN.md §8.4);
//  - CFG reachability: a port of llvm/lib/Analysis/CFG.cpp (isPotentiallyReachable,
//    isPotentiallyReachableFromMany) with a DominatorTree and optional LoopInfo (CycleInfo: not ported).
import std;
import ir;
import irutil;
import domtree;
import loopinfo;
import vt;

// ---------------------------------------------------------------------------------------------
// Stamp sets: (key * SS_N + slot) -> epoch. Keys are value ids or use ids (the slot decides).

let SS_N = 8;
let SS_CT_USES = 0;     // capture tracking: visited uses
let SS_REACH = 1;       // isPotentiallyReachable: visited blocks
let SS_MASK = 2;        // BasicAA getModRefInfoMask: visited values
let SS_MSSA = 3;        // MemorySSA build: defining blocks
let SS_MSSA2 = 4;       // MemorySSA IDF: VisitedPQ
let SS_MSSA3 = 5;       // MemorySSA IDF: VisitedWorklist
let SS_MSSA4 = 6;       // MemorySSA renamePass: Visited
let SS_SPARE = 7;
var ss_stamp: i32[>..];
var ss_epoch: i32[8] = [1, 1, 1, 1, 1, 1, 1, 1];
var ss_count: i64[8] = [0, 0, 0, 0, 0, 0, 0, 0];

fn ss_clear(s: i64) { ss_epoch[s] += 1; ss_count[s] = 0; }
fn ss_has(s: i64, k: i32) -> bool {
    let i = (k as i64) * SS_N + s;
    return i < ss_stamp.len && ss_stamp[i] == ss_epoch[s];
}
// Inserts; returns true if newly inserted.
fn ss_add(s: i64, k: i32) -> bool {
    let i = (k as i64) * SS_N + s;
    if i >= ss_stamp.len {
        let n = max(max(vals.len, uses.len), (k as i64) + 1) * SS_N;
        while ss_stamp.len < n { ss_stamp.push(0); }
    }
    if ss_stamp[i] == ss_epoch[s] { return false; }
    ss_stamp[i] = ss_epoch[s];
    ss_count[s] += 1;
    return true;
}
fn ss_size(s: i64) -> i64 { ss_count[s] }

// ---------------------------------------------------------------------------------------------
// CFG reachability (CFG.cpp)

let CFG_MAX_BBS_TO_EXPLORE = 32;     // -dom-tree-reachability-max-bbs-to-explore

fn cfr_outermost_loop(bv: i32) -> i32 {
    var l = li_loop_for(bv);
    if l < 0 { return -1; }
    while loops[l].parent >= 0 { l = loops[l].parent; }
    return l;
}

// isReachableImpl with a single stop block, no exclusion set; use_dt / use_li say whether DT / LI are given.
// The worklist is consumed.
fn cfr_reachable_impl(wl: i32[>..<]&, stop: i32, use_dt0: bool, use_li: bool) -> bool {
    var use_dt = use_dt0;
    if use_dt && !dt_has_node(DT_DOM, stop) { use_dt = false; }
    var stop_loop: i32 = -1;
    if use_li { stop_loop = cfr_outermost_loop(stop); }
    var limit = CFG_MAX_BBS_TO_EXPLORE;
    ss_clear(SS_REACH);
    while wl.len > 0 {
        let bb = wl.pop();
        if !ss_add(SS_REACH, bb) { continue; }
        if bb == stop { return true; }
        if use_dt && dt_dominates_block(DT_DOM, bb, stop) { return true; }
        var outer: i32 = -1;
        if use_li {
            outer = cfr_outermost_loop(bb);
            if outer >= 0 && outer == stop_loop { return true; }
        }
        limit--;
        if limit == 0 { return true; }
        if outer >= 0 {
            loop_exit_blocks_into(outer, wl);
        } else {
            let n = block_nsucc(bb);
            for k in n { wl.push(block_succ(bb, k)); }
        }
    }
    return false;
}

// Loop::getExitBlocks appended to wl (in LLVM's order: blocks of the loop in order, successors in order)
fn loop_exit_blocks_into(l: i32, wl: i32[>..<]&) {
    let n = loop_nblocks(l);
    for i in n {
        let b = loop_block(l, i);
        let ns = block_nsucc(b);
        for k in ns {
            let s = block_succ(b, k);
            if !loop_contains(l, s) { wl.push(s); }
        }
    }
}

// isPotentiallyReachableFromMany(Worklist, StopBB, nullptr, DT, LI)
fn cfr_from_many(wl: i32[>..<]&, stop: i32, use_dt: bool, use_li: bool) -> bool {
    return cfr_reachable_impl(wl, stop, use_dt, use_li);
}

fn cfr_is_entry(bv: i32) -> bool { func_entry(block_func(bv)) == bv }

// isPotentiallyReachable(BasicBlock A, BasicBlock B, nullptr, DT, LI)
fn cfr_block_reachable(a: i32, b: i32, use_dt: bool, use_li: bool) -> bool {
    if use_dt {
        if dt_has_node(DT_DOM, a) && !dt_has_node(DT_DOM, b) { return false; }
        if cfr_is_entry(a) && dt_has_node(DT_DOM, b) { return true; }
        if cfr_is_entry(b) && dt_has_node(DT_DOM, a) { return false; }
    }
    var wl: i32[>..<] = [];
    wl.push(a);
    return cfr_from_many(wl, b, use_dt, use_li);
}

// isPotentiallyReachable(Instruction A, Instruction B, nullptr, DT, LI)
fn cfr_inst_reachable(a: i32, b: i32, use_dt: bool, use_li: bool) -> bool {
    let ba = inst_parent(a);
    let bb = inst_parent(b);
    if ba == bb {
        if a == b || comes_before(a, b) { return true; }
        if use_li && li_loop_for(ba) >= 0 { return true; }
        if cfr_is_entry(ba) { return false; }
        var wl: i32[>..<] = [];
        let n = block_nsucc(ba);
        for k in n { wl.push(block_succ(ba, k)); }
        if wl.len == 0 { return false; }
        return cfr_from_many(wl, bb, use_dt, use_li);
    }
    return cfr_block_reachable(ba, bb, use_dt, use_li);
}

// BasicAA's isNotInCycle(I, DT, LI = nullptr, CI = nullptr)
fn cfr_not_in_cycle(iv: i32, use_dt: bool) -> bool {
    let bb = inst_parent(iv);
    var wl: i32[>..<] = [];
    let n = block_nsucc(bb);
    for k in n { wl.push(block_succ(bb, k)); }
    return wl.len == 0 || !cfr_from_many(wl, bb, use_dt, false);
}
