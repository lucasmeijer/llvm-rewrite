// Loop pass manager state: the FunctionToLoopPassAdaptor worklist and LPMUpdater.
// Ports llvm/include/llvm/Transforms/Scalar/LoopPassManager.h (LPMUpdater),
// llvm/include/llvm/ADT/PriorityWorklist.h (SmallPriorityWorklist) and appendLoopsToWorklist /
// appendReversedLoopsToWorklist (llvm/lib/Transforms/Utils/LoopUtils.cpp). The adaptor itself runs in
// passmgr.goose (run_loop_adaptor). Adaptors never nest, so there is one global worklist.
//
// API for loop passes (LPMUpdater): lpm_cur (the loop being processed), lpm_mark_loop_as_deleted(l),
// lpm_add_child_loops(run of loops), lpm_add_sibling_loops, lpm_revisit_current_loop, lpm_skip.
import std;
import ir;
import loopinfo;

var lpm_wl: i32[>..<];      // SmallPriorityWorklist vector V; -1 = an erased slot
var lpm_pos: i32[>..];      // map M: loop id -> index in lpm_wl (-1 = absent)
var lpm_cur: i32 = -1;
var lpm_skip: bool = false;
var lpm_nest_mode: bool = false;
var lpm_tmp: i32[>..<];     // scratch for appendLoopsToWorklist

fn lpm_pos_grow() { while lpm_pos.len < loops.len { lpm_pos.push(-1); } }

// SmallPriorityWorklist::insert(X)
fn lpm_wl_insert(l: i32) {
    lpm_pos_grow();
    let p = lpm_pos[l];
    if p < 0 { lpm_pos[l] = lpm_wl.len as i32; lpm_wl.push(l); return; }
    if p != (lpm_wl.len - 1) as i32 {
        lpm_wl[p] = -1;
        lpm_pos[l] = lpm_wl.len as i32;
        lpm_wl.push(l);
    }
}

// SmallPriorityWorklist::insert(Sequence): bulk append lpm_tmp[from..], then fix up duplicates backwards.
fn lpm_wl_insert_seq(from: i64) {
    lpm_pos_grow();
    let n = lpm_tmp.len - from;
    if n == 0 { return; }
    let start = lpm_wl.len;
    for k in n { lpm_wl.push(lpm_tmp[from + k]); }
    var i = lpm_wl.len - 1;
    while i >= start {
        let x = lpm_wl[i];
        let p = lpm_pos[x];
        if p < 0 { lpm_pos[x] = i as i32; }
        else if (p as i64) < start { lpm_wl[p] = -1; lpm_pos[x] = i as i32; }
        else { lpm_wl[i] = -1; }
        i--;
    }
}

fn lpm_wl_empty() -> bool { lpm_wl.len == 0 }

// pop_back_val
fn lpm_wl_pop() -> i32 {
    let r = lpm_wl[lpm_wl.len - 1];
    lpm_pos[r] = -1;
    lpm_wl.pop();
    while lpm_wl.len > 0 && lpm_wl[lpm_wl.len - 1] < 0 { lpm_wl.pop(); }
    return r;
}

// appendReversedLoopsToWorklist over the loops in lpm_tmp[from..] (in the given order): a preorder of each
// root's nest (children pushed in order, popped LIFO) inserted as one sequence.
fn lpm_append_reversed(from: i64) {
    let end = lpm_tmp.len;
    var k = from;
    while k < end {
        let root = lpm_tmp[k];
        let pre = lpm_tmp.len;
        var stack: i32[>..<] = [];
        stack.push(root);
        while stack.len > 0 {
            let l = stack.pop();
            for c in loop_nsubs(l) { stack.push(loop_sub(l, c)); }
            lpm_tmp.push(l);
        }
        lpm_wl_insert_seq(pre);
        lpm_tmp.resize(pre);
        k++;
    }
}

// appendLoopsToWorklist(LI): top-level loops in LoopInfo order.
fn lpm_append_function_loops(fv: i32) {
    let base = lpm_tmp.len;
    for k in li_ntop(fv) { lpm_tmp.push(li_top(fv, k)); }
    lpm_append_reversed(base);
    lpm_tmp.resize(base);
}

// appendLoopsToWorklist(ArrayRef): reverse(Loops), then the reversed walk.
fn lpm_append_loops(ls: const i32[:]) {
    let base = lpm_tmp.len;
    var k = ls.len - 1;
    while k >= 0 { lpm_tmp.push(ls[k]); k--; }
    lpm_append_reversed(base);
    lpm_tmp.resize(base);
}

fn lpm_mark_loop_as_deleted(l: i32) { if l == lpm_cur { lpm_skip = true; } }

fn lpm_add_child_loops(ls: const i32[:]) {
    lpm_wl_insert(lpm_cur);
    lpm_append_loops(ls);
    lpm_skip = true;
}

fn lpm_add_sibling_loops(ls: const i32[:]) {
    if lpm_nest_mode { for l in ls { lpm_wl_insert(l); } } else { lpm_append_loops(ls); }
}

fn lpm_revisit_current_loop() { lpm_skip = true; lpm_wl_insert(lpm_cur); }

// Loop::getName
fn loop_name(l: i32) -> const u8[:] {
    let h = loop_header(l);
    if h >= 0 && vals[h].name >= 0 { return val_name(h); }
    return "<unnamed loop>";
}
