// CycleInfo: the cycle hierarchy of a function, reducible or not.
// Ports llvm/include/llvm/ADT/GenericCycleImpl.h (GenericCycleInfoCompute::run and dfs,
// moveTopLevelCycleToNewParent, updateDepth, getSmallestCommonCycle, addBlockToCycle, splitCriticalEdge,
// print), llvm/include/llvm/ADT/GenericCycleInfo.h (GenericCycle::print) and
// llvm/lib/Analysis/CycleAnalysis.cpp (CycleInfoPrinterPass). Cycles are ids into `cycles`; entries, blocks
// (a SetVector: insertion order) and children are runs in ci_pool.
import std;
import ir;
import irutil;
import flags;

struct CRun { at: i32, n: i32, cap: i32 }
struct Cycle { parent: i32, toplevel: i32, depth: i32, fv: i32, entries: CRun, blocks: CRun, children: CRun }
struct CIHead { valid: bool, epoch: i32, top: CRun }

var cycles: Cycle[>..];
var ci_pool: i32[>..];
var ci_heads: CIHead[>..];
var ci_map: i32[>..];          // block index -> innermost cycle (BlockMap), stamped with the head's epoch
var ci_map_stamp: i32[>..];
var ci_next_epoch: i32 = 1;

fn crun_push(r: CRun, v: i32) -> CRun {
    var x = r;
    if x.n == x.cap {
        let nat = ci_pool.len as i32;
        for k in x.n { let e = ci_pool[x.at + k]; ci_pool.push(e); }
        for k in x.n + 4 { ci_pool.push(-1); }
        x.at = nat;
        x.cap = x.n * 2 + 4;
    }
    ci_pool[x.at + x.n] = v;
    x.n++;
    return x;
}
fn crun_get(r: CRun, k: i64) -> i32 { ci_pool[r.at + k] }
fn crun_set(r: CRun, k: i64, v: i32) { ci_pool[r.at + k] = v; }
fn crun_empty() -> CRun { CRun { at: 0, n: 0, cap: 0 } }
fn crun_has(r: CRun, v: i32) -> bool { for k in r.n { if ci_pool[r.at + k] == v { return true; } } return false; }

fn ci_grow() { while ci_heads.len < globs.len { ci_heads.push(CIHead { valid: false, epoch: 0, top: crun_empty() }); } }
fn ci_valid(fv: i32) -> bool { let g = glob_of(fv) as i64; g < ci_heads.len && ci_heads[g].valid }
fn ci_invalidate(fv: i32) { let g = glob_of(fv) as i64; if g < ci_heads.len { ci_heads[g].valid = false; } }

// getCycle(Block): innermost cycle or -1.
fn ci_cycle_for(bv: i32) -> i32 {
    let g = glob_of(block_func(bv)) as i64;
    if g >= ci_heads.len { return -1; }
    let k = block_of(bv) as i64;
    if k < ci_map_stamp.len && ci_map_stamp[k] == ci_heads[g].epoch { return ci_map[k]; }
    return -1;
}
fn ci_set_cycle_for(bv: i32, c: i32) {
    let g = glob_of(block_func(bv));
    let k = block_of(bv) as i64;
    while ci_map_stamp.len <= k { ci_map_stamp.push(0); ci_map.push(-1); }
    ci_map_stamp[k] = ci_heads[g].epoch;
    ci_map[k] = c;
}
fn ci_ntop(fv: i32) -> i64 { ci_heads[glob_of(fv)].top.n as i64 }
fn ci_top(fv: i32, k: i64) -> i32 { crun_get(ci_heads[glob_of(fv)].top, k) }
fn cycle_header(c: i32) -> i32 { crun_get(cycles[c].entries, 0) }
fn cycle_is_reducible(c: i32) -> bool { cycles[c].entries.n == 1 }
fn cycle_nentries(c: i32) -> i64 { cycles[c].entries.n as i64 }
fn cycle_entry(c: i32, k: i64) -> i32 { crun_get(cycles[c].entries, k) }
fn cycle_is_entry(c: i32, bv: i32) -> bool { crun_has(cycles[c].entries, bv) }
fn cycle_nblocks(c: i32) -> i64 { cycles[c].blocks.n as i64 }
fn cycle_block(c: i32, k: i64) -> i32 { crun_get(cycles[c].blocks, k) }
fn cycle_nchildren(c: i32) -> i64 { cycles[c].children.n as i64 }
fn cycle_child(c: i32, k: i64) -> i32 { crun_get(cycles[c].children, k) }
fn cycle_contains_cycle(c: i32, x0: i32) -> bool { var x = x0; while x >= 0 { if x == c { return true; } x = cycles[x].parent; } return false; }
fn cycle_contains(c: i32, bv: i32) -> bool { cycle_contains_cycle(c, ci_cycle_for(bv)) }

// depth_first(Cycle): pre-order over children.
fn cycle_each_depth_first<F>(root: i32) {
    var st: i32[>..<] = [];
    st.push(root);
    while st.len > 0 {
        let c = st.pop();
        F(c);
        let mark = st.len;
        for k in cycles[c].children.n { st.push(crun_get(cycles[c].children, k)); }
        reverse(st[mark..]);
    }
}

// SetVector::insert(Block) for a cycle's blocks
var ci_mark: i32[>..];
var ci_mark_epoch: i32 = 0;
fn ci_mark_set(b: i32) -> bool {
    let k = block_of(b) as i64;
    while ci_mark.len <= k { ci_mark.push(0); }
    if ci_mark[k] == ci_mark_epoch { return false; }
    ci_mark[k] = ci_mark_epoch;
    return true;
}

fn ci_new_cycle(fv: i32) -> i32 {
    let id = cycles.len as i32;
    cycles.push(Cycle { parent: -1, toplevel: id, depth: 0, fv: fv, entries: crun_empty(), blocks: crun_empty(), children: crun_empty() });
    return id;
}

// moveTopLevelCycleToNewParent(NewParent, Child)
fn ci_move_to_new_parent(fv: i32, np: i32, child: i32) {
    let g = glob_of(fv);
    var top = ci_heads[g].top;
    var pos: i64 = -1;
    for k in top.n { if crun_get(top, k) == child { pos = k; break; } }
    if pos < 0 { fatal("internal: CycleInfo child is not a top-level cycle"); }
    cycles[np].children = crun_push(cycles[np].children, child);
    crun_set(top, pos, crun_get(top, (top.n - 1) as i64));
    top.n--;
    ci_heads[g].top = top;
    cycles[child].parent = np;
    cycles[child].toplevel = np;
    cycle_each_depth_first(child) { c => cycles[c].toplevel = np; };
    // NewParent->Blocks.insert_range(Child->blocks())
    ci_mark_epoch++;
    for k in cycles[np].blocks.n { ci_mark_set(crun_get(cycles[np].blocks, k)); }
    for k in cycles[child].blocks.n {
        let b = crun_get(cycles[child].blocks, k);
        if ci_mark_set(b) { cycles[np].blocks = crun_push(cycles[np].blocks, b); }
    }
}

struct DFSInfo { stamp: i32, start: u32, end: u32 }
var ci_dfs: DFSInfo[>..];
var ci_dfs_epoch: i32 = 0;
fn ci_dfs_k(b: i32) -> i64 {
    let k = block_of(b) as i64;
    while ci_dfs.len <= k { ci_dfs.push(DFSInfo { stamp: 0, start: 0, end: 0 }); }
    if ci_dfs[k].stamp != ci_dfs_epoch { ci_dfs[k] = DFSInfo { stamp: ci_dfs_epoch, start: 0, end: 0 }; }
    return k;
}
fn ci_is_ancestor(a: i64, b: i64) -> bool { ci_dfs[a].start <= ci_dfs[b].start && ci_dfs[b].end <= ci_dfs[a].end }

// GenericCycleInfo::compute(F) / GenericCycleInfoCompute::run
fn ci_compute(fv: i32) {
    ci_grow();
    let g = glob_of(fv);
    ci_heads[g].valid = true;
    ci_heads[g].epoch = ci_next_epoch;
    ci_next_epoch++;
    ci_heads[g].top = crun_empty();
    // dfs(F, EntryBlock)
    ci_dfs_epoch++;
    var preorder: i32[>..<] = [];
    var ts: i32[>..<] = [];
    var dts: i64[>..<] = [];
    var counter: u32 = 0;
    ts.push(func_entry(fv));
    loop {
        let b = ts[ts.len - 1];
        let k = ci_dfs_k(b);
        if ci_dfs[k].start == 0 {
            counter++;
            ci_dfs[k].start = counter;
            dts.push(ts.len);
            let tm = block_terminator(b);
            if tm >= 0 { for j in term_nsucc(tm) { ts.push(term_succ(tm, j)); } }
            preorder.push(b);
        } else {
            if dts[dts.len - 1] == ts.len {
                ci_dfs[k].end = counter;
                dts.pop();
            }
            ts.pop();
        }
        if ts.len == 0 { break; }
    }
    var wl: i32[>..<] = [];
    // ProcessPredecessors(Block) for the cycle nc with header DFS info hk
    fn process_preds(b: i32, hk: i64, nc: i32) {
        var is_entry = false;
        each_pred(b) { p =>
            let pk = ci_dfs_k(p);
            if ci_is_ancestor(hk, pk) { wl.push(p); }
            else if ci_dfs[pk].start != 0 { is_entry = true; }
        };
        if is_entry { cycles[nc].entries = crun_push(cycles[nc].entries, b); }
    }
    var i = preorder.len;
    while i > 0 {
        i--;
        let hc = preorder[i];
        let hk = ci_dfs_k(hc);
        each_pred(hc) { p => let pk = ci_dfs_k(p); if ci_is_ancestor(hk, pk) { wl.push(p); } };
        if wl.len == 0 { continue; }
        let nc = ci_new_cycle(fv);
        cycles[nc].entries = crun_push(cycles[nc].entries, hc);
        cycles[nc].blocks = crun_push(cycles[nc].blocks, hc);
        ci_set_cycle_for(hc, nc);
        loop {
            let b = wl.pop();
            if b != hc {
                let bc = ci_cycle_for(b);
                let bp = if bc >= 0 { cycles[bc].toplevel } else { -1 };
                if bp >= 0 {
                    if bp != nc {
                        ci_move_to_new_parent(fv, nc, bp);
                        for e in cycles[bp].entries.n { process_preds(crun_get(cycles[bp].entries, e), hk, nc); }
                    }
                } else {
                    ci_set_cycle_for(b, nc);
                    cycles[nc].blocks = crun_push(cycles[nc].blocks, b);
                    process_preds(b, hk, nc);
                }
            }
            if wl.len == 0 { break; }
        }
        ci_heads[g].top = crun_push(ci_heads[g].top, nc);
    }
    for k in ci_heads[g].top.n {
        let tlc = crun_get(ci_heads[g].top, k);
        cycles[tlc].parent = -1;
        cycle_each_depth_first(tlc) { c =>
            let p = cycles[c].parent;
            cycles[c].depth = if p >= 0 { cycles[p].depth + 1 } else { 1 };
        };
    }
}

fn ci_get(fv: i32) { ci_grow(); if !ci_valid(fv) { ci_compute(fv); } }

// getSmallestCommonCycle(A, B)
fn ci_smallest_common_cycle(a0: i32, b0: i32) -> i32 {
    if a0 < 0 || b0 < 0 { return -1; }
    var a = a0;
    var b = b0;
    while cycles[a].depth > cycles[b].depth { a = cycles[a].parent; }
    while cycles[b].depth > cycles[a].depth { b = cycles[b].parent; }
    while a != b { a = cycles[a].parent; b = cycles[b].parent; if a < 0 || b < 0 { return -1; } }
    return a;
}

// addBlockToCycle(Block, Cycle)
fn ci_add_block_to_cycle(bv: i32, c: i32) {
    cycles[c].blocks = crun_push(cycles[c].blocks, bv);
    ci_set_cycle_for(bv, c);
    var p = cycles[c].parent;
    while p >= 0 { cycles[p].blocks = crun_push(cycles[p].blocks, bv); p = cycles[p].parent; }
}

// splitCriticalEdge(Pred, Succ, NewBlock)
fn ci_split_critical_edge(pred: i32, succ: i32, nb: i32) {
    let c = ci_smallest_common_cycle(ci_cycle_for(pred), ci_cycle_for(succ));
    if c < 0 { return; }
    ci_add_block_to_cycle(nb, c);
}

// ---------------------------------------------------------------------------------------------
// Printing (SSAContext::print(BasicBlock*): the name, or the local slot number when unnamed)

fn errs_block_label(bv: i32, fv: i32) {
    if vals[bv].name >= 0 { errs(sbytes(vals[bv].name)); return; }
    let mark = errbuf.len;
    errs_operand(bv, fv, false);
    // drop the '%'
    if errbuf.len > mark && errbuf[mark] == '%' {
        for k in mark..errbuf.len - 1 { errbuf[k] = errbuf[k + 1]; }
        errbuf.resize(errbuf.len - 1);
    }
}

fn print_cycles(fv: i32) {
    ci_get(fv);
    errs("CycleInfo for function: ");
    errs(val_name(fv));
    errs("\n");
    for k in ci_ntop(fv) {
        cycle_each_depth_first(ci_top(fv, k)) { c =>
            for d in cycles[c].depth { errs("    "); }
            errs("depth=");
            errs_int(cycles[c].depth as i64);
            errs(": entries(");
            for e in cycles[c].entries.n {
                if e > 0 { errs(" "); }
                errs_block_label(crun_get(cycles[c].entries, e), fv);
            }
            errs(")");
            for j in cycles[c].blocks.n {
                let b = crun_get(cycles[c].blocks, j);
                if cycle_is_entry(c, b) { continue; }
                errs(" ");
                errs_block_label(b, fv);
            }
            errs("\n");
        };
    }
}
