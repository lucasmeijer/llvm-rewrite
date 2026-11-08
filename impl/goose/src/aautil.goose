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
import cycleinfo;
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
// CFG reachability (CFG.cpp). `use_dt`, `use_li`, `use_ci` say whether DT / LoopInfo / CycleInfo are given
// (both LI and CI: CI wins, as in isReachableImpl). No exclusion sets.

let CFG_MAX_BBS_TO_EXPLORE = 32;     // -dom-tree-reachability-max-bbs-to-explore

fn cfr_outermost_loop(bv: i32) -> i32 {
    var l = li_loop_for(bv);
    if l < 0 { return -1; }
    while loops[l].parent >= 0 { l = loops[l].parent; }
    return l;
}
// CycleInfo::getTopLevelParentCycle
fn cfr_top_cycle(bv: i32) -> i32 {
    var c = ci_cycle_for(bv);
    if c < 0 { return -1; }
    while cycles[c].parent >= 0 { c = cycles[c].parent; }
    return c;
}

// isReachableImpl with a single stop block; the worklist is consumed.
fn cfr_reachable_impl(wl: i32[>..<]&, stop: i32, use_dt0: bool, use_li0: bool, use_ci: bool) -> bool {
    var use_dt = use_dt0;
    let use_li = use_li0 && !use_ci;
    if use_dt && !dt_has_node(DT_DOM, stop) { use_dt = false; }
    var stop_loop: i32 = -1;
    if use_li { stop_loop = cfr_outermost_loop(stop); }
    var stop_cycle: i32 = -1;
    if use_ci { stop_cycle = cfr_top_cycle(stop); }
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
        var outer_c: i32 = -1;
        if use_ci {
            outer_c = cfr_top_cycle(bb);
            if outer_c >= 0 {
                if outer_c == stop_cycle { return true; }
            } else if use_dt && dt_has_node(DT_DOM, bb) && dt_dominates_block(DT_DOM, stop, bb) {
                continue;
            }
        }
        limit--;
        if limit == 0 { return true; }
        if outer >= 0 {
            loop_exit_blocks_into(outer, wl);
        } else if outer_c >= 0 {
            cycle_exit_blocks_into(outer_c, wl);
        } else {
            let n = block_nsucc(bb);
            for k in n { wl.push(block_succ(bb, k)); }
        }
    }
    return false;
}

// Loop::getExitBlocks appended to wl (blocks of the loop in order, successors in order)
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
// GenericCycle::getExitBlocks appended to wl (unique, in first-seen order)
fn cycle_exit_blocks_into(c: i32, wl: i32[>..<]&) {
    let base = wl.len;
    let n = cycle_nblocks(c);
    for i in n {
        let b = cycle_block(c, i);
        let ns = block_nsucc(b);
        for k in ns {
            let s = block_succ(b, k);
            if cycle_contains(c, s) { continue; }
            var dup = false;
            var j = base;
            while j < wl.len { if wl[j] == s { dup = true; } j++; }
            if !dup { wl.push(s); }
        }
    }
}

fn cfr_is_entry(bv: i32) -> bool { func_entry(block_func(bv)) == bv }

// isPotentiallyReachable(BasicBlock A, BasicBlock B, nullptr, DT, LI, CI)
fn cfr_block_reachable(a: i32, b: i32, use_dt: bool, use_li: bool, use_ci: bool) -> bool {
    if use_dt {
        if dt_has_node(DT_DOM, a) && !dt_has_node(DT_DOM, b) { return false; }
        if cfr_is_entry(a) && dt_has_node(DT_DOM, b) { return true; }
        if cfr_is_entry(b) && dt_has_node(DT_DOM, a) { return false; }
    }
    var wl: i32[>..<] = [];
    wl.push(a);
    return cfr_reachable_impl(wl, b, use_dt, use_li, use_ci);
}

// isPotentiallyReachable(Instruction A, Instruction B, nullptr, DT, LI, CI)
fn cfr_inst_reachable(a: i32, b: i32, use_dt: bool, use_li: bool, use_ci: bool) -> bool {
    let ba = inst_parent(a);
    let bb = inst_parent(b);
    if ba == bb {
        if a == b || comes_before(a, b) { return true; }
        if use_ci { return ci_cycle_for(ba) >= 0; }
        if use_li && li_loop_for(ba) >= 0 { return true; }
        if cfr_is_entry(ba) { return false; }
        var wl: i32[>..<] = [];
        let n = block_nsucc(ba);
        for k in n { wl.push(block_succ(ba, k)); }
        if wl.len == 0 { return false; }
        return cfr_reachable_impl(wl, bb, use_dt, use_li, use_ci);
    }
    return cfr_block_reachable(ba, bb, use_dt, use_li, use_ci);
}

// isPotentiallyReachableFromMany(Worklist, StopBB, nullptr, DT, LI, CI)
fn cfr_from_many(wl: i32[>..<]&, stop: i32, use_dt: bool, use_li: bool, use_ci: bool) -> bool {
    return cfr_reachable_impl(wl, stop, use_dt, use_li, use_ci);
}

// isNotInCycle(I, DT, LI, CI) (BasicAliasAnalysis.cpp)
fn cfr_not_in_cycle(iv: i32, use_dt: bool, use_li: bool, use_ci: bool) -> bool {
    let bb = inst_parent(iv);
    if use_ci { return ci_cycle_for(bb) < 0; }
    var wl: i32[>..<] = [];
    let n = block_nsucc(bb);
    for k in n { wl.push(block_succ(bb, k)); }
    return wl.len == 0 || !cfr_reachable_impl(wl, bb, use_dt, use_li, false);
}
