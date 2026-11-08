// LoopInfo: natural loops of a function.
// Ports llvm/include/llvm/Support/GenericLoopInfoImpl.h (LoopInfoBase::analyze, discoverAndMapSubloop,
// PopulateLoopsDFS, addBasicBlockToLoop, getLoopLatch, LoopBase::print) and the parts of
// llvm/include/llvm/Support/GenericLoopInfo.h and llvm/lib/Analysis/LoopInfo.cpp that passes need
// (contains, isLoopLatch, isLoopExiting, getLoopID, isAnnotatedParallel, LoopPrinterPass).
// Loops are ids into `loops` (never reused); a loop's blocks and subloops are runs in li_pool, in LLVM's
// order: Blocks[0] is the header, the rest in reverse post-order; subloops in program order; top-level loops
// in reverse program order (as LoopInfo stores them).
import std;
import ir;
import irutil;
import flags;
import instinfo;
import domtree;

struct LRun { at: i32, n: i32, cap: i32 }
struct Loop { header: i32, parent: i32, fv: i32, blocks: LRun, subs: LRun }
struct LIHead { valid: bool, epoch: i32, top: LRun }

var loops: Loop[>..];
var li_pool: i32[>..];
var li_heads: LIHead[>..];
var li_map: i32[>..];          // block index -> innermost loop (valid iff li_map_stamp matches the head's epoch)
var li_map_stamp: i32[>..];
var li_next_epoch: i32 = 1;

fn lrun_push(r: LRun, v: i32) -> LRun {
    var x = r;
    if x.n == x.cap {
        let nat = li_pool.len as i32;
        for k in x.n { let e = li_pool[x.at + k]; li_pool.push(e); }
        for k in x.n + 4 { li_pool.push(-1); }
        x.at = nat;
        x.cap = x.n * 2 + 4;
    }
    li_pool[x.at + x.n] = v;
    x.n++;
    return x;
}
fn lrun_get(r: LRun, k: i64) -> i32 { li_pool[r.at + k] }
fn lrun_reverse(r: LRun, from: i64) {
    var i = r.at as i64 + from;
    var j = (r.at + r.n) as i64 - 1;
    while i < j { let t = li_pool[i]; li_pool[i] = li_pool[j]; li_pool[j] = t; i++; j--; }
}
fn lrun_empty() -> LRun { LRun { at: 0, n: 0, cap: 0 } }

fn li_grow() { while li_heads.len < globs.len { li_heads.push(LIHead { valid: false, epoch: 0, top: lrun_empty() }); } }
fn li_valid(fv: i32) -> bool { let g = glob_of(fv) as i64; g < li_heads.len && li_heads[g].valid }
fn li_invalidate(fv: i32) { let g = glob_of(fv) as i64; if g < li_heads.len { li_heads[g].valid = false; } }

// ---------------------------------------------------------------------------------------------
// Queries

// LoopInfo::getLoopFor(BB): innermost loop containing bv, or -1.
fn li_loop_for(bv: i32) -> i32 {
    let g = glob_of(block_func(bv)) as i64;
    if g >= li_heads.len { return -1; }
    let k = block_of(bv) as i64;
    if k < li_map_stamp.len && li_map_stamp[k] == li_heads[g].epoch { return li_map[k]; }
    return -1;
}
// LoopInfo::changeLoopFor(BB, L); l = -1 removes the mapping.
fn li_change_loop_for(bv: i32, l: i32) {
    let g = glob_of(block_func(bv));
    let k = block_of(bv) as i64;
    while li_map_stamp.len <= k { li_map_stamp.push(0); li_map.push(-1); }
    if l < 0 { li_map_stamp[k] = 0; return; }
    li_map_stamp[k] = li_heads[g].epoch;
    li_map[k] = l;
}
fn li_ntop(fv: i32) -> i64 { li_heads[glob_of(fv)].top.n as i64 }
fn li_top(fv: i32, k: i64) -> i32 { lrun_get(li_heads[glob_of(fv)].top, k) }

fn loop_header(l: i32) -> i32 { loops[l].header }
fn loop_parent(l: i32) -> i32 { loops[l].parent }
fn loop_nblocks(l: i32) -> i64 { loops[l].blocks.n as i64 }
fn loop_block(l: i32, k: i64) -> i32 { lrun_get(loops[l].blocks, k) }
fn loop_nsubs(l: i32) -> i64 { loops[l].subs.n as i64 }
fn loop_sub(l: i32, k: i64) -> i32 { lrun_get(loops[l].subs, k) }
fn loop_depth(l: i32) -> i64 { var d = 1; var p = loops[l].parent; while p >= 0 { d++; p = loops[p].parent; } return d; }
fn loop_outermost(l: i32) -> i32 { var x = l; while loops[x].parent >= 0 { x = loops[x].parent; } return x; }
fn loop_is_outermost(l: i32) -> bool { loops[l].parent < 0 }
fn loop_is_innermost(l: i32) -> bool { loops[l].subs.n == 0 }
// contains(const LoopT *L): L is this loop or nested in it (x may be -1).
fn loop_contains_loop(l: i32, x0: i32) -> bool {
    var x = x0;
    while x >= 0 { if x == l { return true; } x = loops[x].parent; }
    return false;
}
// contains(const BlockT *BB)
fn loop_contains(l: i32, bv: i32) -> bool { loop_contains_loop(l, li_loop_for(bv)) }

// isLoopLatch(BB): BB is a predecessor of the header (BB must be in the loop).
fn loop_is_latch(l: i32, bv: i32) -> bool {
    var r = false;
    each_pred(loops[l].header) { p => if p == bv { r = true; } };
    return r;
}
// isLoopExiting(BB): some successor is outside the loop.
fn loop_is_exiting(l: i32, bv: i32) -> bool {
    let tm = block_terminator(bv);
    if tm < 0 { return false; }
    for k in term_nsucc(tm) { if !loop_contains(l, term_succ(tm, k)) { return true; } }
    return false;
}
// getLoopLatch: the single in-loop predecessor of the header, or -1.
fn loop_latch(l: i32) -> i32 {
    var latch: i32 = -1;
    var many = false;
    each_pred(loops[l].header) { p =>
        if loop_contains(l, p) { if latch >= 0 { many = true; } latch = p; }
    };
    return if many { -1 } else { latch };
}
// getLoopLatches
fn loop_latches(l: i32, out: i32[>..<]&) {
    out.clear();
    each_pred(loops[l].header) { p => if loop_contains(l, p) { out.push(p); } };
}
// getLoopPredecessor: the unique out-of-loop predecessor of the header (counting each block once), or -1.
fn loop_predecessor(l: i32) -> i32 {
    var out: i32 = -1;
    var bad = false;
    each_pred(loops[l].header) { p =>
        if !loop_contains(l, p) { if out >= 0 && out != p { bad = true; } out = p; }
    };
    return if bad { -1 } else { out };
}
// getLoopPreheader: the predecessor, if its only successor is the header (and it isn't an EH pad... LLVM
// checks isLegalToHoistInto: the terminator is not an EH pad terminator and it has one successor).
fn loop_preheader(l: i32) -> i32 {
    let p = loop_predecessor(l);
    if p < 0 { return -1; }
    let tm = block_terminator(p);
    if tm < 0 || term_nsucc(tm) != 1 { return -1; }
    let o = iop(tm);
    if o == OP_CATCHSWITCH || o == OP_CATCHRET || o == OP_CLEANUPRET || o == OP_INVOKE || o == OP_CALLBR { return -1; }
    return p;
}

// ---------------------------------------------------------------------------------------------
// Updates

// LoopBase::addBlockEntry
fn loop_add_block_entry(l: i32, bv: i32) { loops[l].blocks = lrun_push(loops[l].blocks, bv); }
// LoopBase::addBasicBlockToLoop(NewBB, LI): map NewBB to l, add it to l and all its parents.
fn loop_add_basic_block_to_loop(l: i32, bv: i32) {
    li_change_loop_for(bv, l);
    var x = l;
    while x >= 0 { loop_add_block_entry(x, bv); x = loops[x].parent; }
}
fn loop_alloc(fv: i32, header: i32) -> i32 {
    let id = loops.len as i32;
    loops.push(Loop { header: header, parent: -1, fv: fv, blocks: lrun_empty(), subs: lrun_empty() });
    loops[id].blocks = lrun_push(loops[id].blocks, header);
    return id;
}

// ---------------------------------------------------------------------------------------------
// LoopInfoBase::analyze(DomTree)

var li_vis: i32[>..];
var li_vis_epoch: i32 = 0;
fn li_vis_add(b: i32) -> bool {
    let k = block_of(b) as i64;
    while li_vis.len <= k { li_vis.push(0); }
    if li_vis[k] == li_vis_epoch { return false; }
    li_vis[k] = li_vis_epoch;
    return true;
}

fn li_compute(fv: i32) {
    li_grow();
    let g = glob_of(fv);
    li_heads[g].valid = true;
    li_heads[g].epoch = li_next_epoch;
    li_next_epoch++;
    li_heads[g].top = lrun_empty();
    dt_get(fv, DT_DOM);
    dt_update_dfs_numbers(fv, DT_DOM);
    var pre: i32[>..<] = [];
    dt_each_preorder(fv, DT_DOM) { n => pre.push(n); };
    var backedges: i32[>..<] = [];
    var wl: i32[>..<] = [];
    var i = pre.len;
    while i > 0 {
        i--;
        let header = pre[i];
        backedges.clear();
        each_pred(header) { be =>
            if dt_has_node(DT_DOM, be) && dt_dominates_block(DT_DOM, header, be) { backedges.push(be); }
        };
        if backedges.len == 0 { continue; }
        let l = loop_alloc(fv, header);
        // discoverAndMapSubloop
        wl.clear();
        for b in backedges { wl.push(b); }
        while wl.len > 0 {
            var pred = wl.pop();
            var sub = li_loop_for(pred);
            if sub < 0 {
                if !dt_has_node(DT_DOM, pred) { continue; }
                li_change_loop_for(pred, l);
                if pred == header { continue; }
                each_pred(pred) { p => wl.push(p); };
            } else {
                sub = loop_outermost(sub);
                if sub == l { continue; }
                loops[sub].parent = l;
                pred = loops[sub].header;
                each_pred(pred) { p => if li_loop_for(p) != sub { wl.push(p); } };
            }
        }
    }
    // PopulateLoopsDFS: post_order(entry)
    li_vis_epoch++;
    var sn: i32[>..<] = [];
    var sk: i32[>..<] = [];
    let entry = func_entry(fv);
    sn.push(entry);
    sk.push(0);
    li_vis_add(entry);
    while sn.len > 0 {
        let top = sn.len - 1;
        let n = sn[top];
        let tm = block_terminator(n);
        let ns = if tm >= 0 { term_nsucc(tm) } else { 0 };
        let k = sk[top] as i64;
        if k < ns {
            sk[top] = (k + 1) as i32;
            let s = term_succ(tm, k);
            if li_vis_add(s) { sn.push(s); sk.push(0); }
            continue;
        }
        sn.pop();
        sk.pop();
        // insertIntoLoop(n)
        var sub = li_loop_for(n);
        if sub >= 0 && n == loops[sub].header {
            let par = loops[sub].parent;
            if par >= 0 { loops[par].subs = lrun_push(loops[par].subs, sub); }
            else { li_heads[g].top = lrun_push(li_heads[g].top, sub); }
            lrun_reverse(loops[sub].blocks, 1);
            lrun_reverse(loops[sub].subs, 0);
            sub = par;
        }
        while sub >= 0 { loop_add_block_entry(sub, n); sub = loops[sub].parent; }
    }
}

// LoopAnalysis: compute if not cached.
fn li_get(fv: i32) { li_grow(); if !li_valid(fv) { li_compute(fv); } }

// ---------------------------------------------------------------------------------------------
// Loop metadata (llvm/lib/Analysis/LoopInfo.cpp)

let MDK_LOOP: i32 = 18;                     // llvm.loop
let MDK_MEM_PARALLEL_LOOP_ACCESS: i32 = 10; // llvm.mem.parallel_loop_access
let MDK_ACCESS_GROUP: i32 = 25;             // llvm.access.group

// Loop::getLoopID
fn loop_id(l: i32) -> i32 {
    var lid: i32 = -1;
    var latches: i32[>..<] = [];
    loop_latches(l, latches);
    for b in latches {
        let md = inst_get_md(block_terminator(b), MDK_LOOP);
        if md < 0 { return -1; }
        if lid < 0 { lid = md; } else if md != lid { return -1; }
    }
    if lid < 0 || mds[lid].nops == 0 || md_op(lid, 0) != lid { return -1; }
    return lid;
}

// findOptionMDForLoopID(LoopID, Name)
fn find_option_md_for_loop_id(lid: i32, name: const u8[:]) -> i32 {
    if lid < 0 { return -1; }
    for k in 1..mds[lid].nops as i64 {
        let m = md_op(lid, k);
        if m < 0 || !md_is_node(m) || mds[m].nops < 1 { continue; }
        let s = md_op(m, 0);
        if s < 0 || mds[s].kind != MK_STRING { continue; }
        if sbytes(mds[s].extra) == name { return m; }
    }
    return -1;
}

// Loop::isAnnotatedParallel
fn loop_is_annotated_parallel(l: i32) -> bool {
    let lid = loop_id(l);
    if lid < 0 { return false; }
    let pa = find_option_md_for_loop_id(lid, "llvm.loop.parallel_accesses");
    var groups: i32[>..<] = [];
    if pa >= 0 { for k in 1..mds[pa].nops as i64 { groups.push(md_op(pa, k)); } }
    for bi in loop_nblocks(l) {
        let bb = loop_block(l, bi);
        var i = block_first(bb);
        while i >= 0 {
            let ni = inst_next(i);
            if inst_may_read_or_write_memory(i) {
                let ag = inst_get_md(i, MDK_ACCESS_GROUP);
                var ok = false;
                if ag >= 0 {
                    if mds[ag].nops == 0 { ok = position(groups, ag) >= 0; }
                    else { for k in mds[ag].nops as i64 { if position(groups, md_op(ag, k)) >= 0 { ok = true; break; } } }
                }
                if !ok {
                    let lmd = inst_get_md(i, MDK_MEM_PARALLEL_LOOP_ACCESS);
                    if lmd < 0 { return false; }
                    var found = false;
                    for k in mds[lmd].nops as i64 { if md_op(lmd, k) == lid { found = true; break; } }
                    if !found { return false; }
                }
            }
            i = ni;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// Printing: LoopBase::print(OS, Verbose = false, PrintNested = true, Depth) and LoopPrinterPass.

recursive fn loop_print(l: i32, depth: i64) {
    let fv = loops[l].fv;
    for k in depth * 2 { errs(" "); }
    if loop_is_annotated_parallel(l) { errs("Parallel "); }
    errs("Loop at depth ");
    errs_int(loop_depth(l));
    errs(" containing: ");
    let h = loops[l].header;
    for i in loop_nblocks(l) {
        let bb = loop_block(l, i);
        if i > 0 { errs(","); }
        errs_operand(bb, fv, false);
        if bb == h { errs("<header>"); }
        if loop_is_latch(l, bb) { errs("<latch>"); }
        if loop_is_exiting(l, bb) { errs("<exiting>"); }
    }
    errs("\n");
    for k in loop_nsubs(l) { loop_print(loop_sub(l, k), depth + 2); }
}

fn print_loops(fv: i32) {
    li_get(fv);
    errs("Loop info for function '");
    errs(val_name(fv));
    errs("':\n");
    for k in li_ntop(fv) { loop_print(li_top(fv, k), 0); }
}
