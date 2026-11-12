// Sink: port of llvm/lib/Transforms/Scalar/Sink.cpp (SinkingPass).
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import calls;
import domtree;
import loopinfo;
import aa;
import memloc;
import tli;
import instsimplify;
import misc_util;

// isSafeToMove; `stores` is the SmallPtrSet of the block's stores seen so far (only queried with "any")
fn sk_is_safe_to_move(i: i32, stores: i32[>..<]&) -> bool {
    if inst_may_write_memory(i) { stores.push(i); return false; }
    if iop(i) == OP_ALLOCA && is_static_alloca(i) { return false; }
    if iop(i) == OP_LOAD {
        let loc = ml_get(i);
        for s in stores { if mr_is_mod(aa_inst_loc_mr_simple(s, loc)) { return false; } }
    }
    if is_terminator(i) || iop(i) == OP_PHI || inst_is_eh_pad(i) || inst_may_throw(i) || !inst_will_return(i) { return false; }
    if is_callbase(i) {
        if call_has_fn_attr(i, AK_Convergent) { return false; }
        for s in stores { if mr_is_mod(aa_inst_call_mr_simple(s, i)) { return false; } }
    }
    return true;
}

fn sk_is_acceptable_target(i: i32, succ: i32) -> bool {
    let f = block_first(succ);
    if f >= 0 && inst_is_eh_pad(f) { return false; }
    if unique_pred_of(succ) != inst_parent(i) {
        if inst_may_read_memory(i) && inst_get_md(i, MDK_INVARIANT_LOAD) < 0 { return false; }
        let sl = li_loop_for(succ);
        let cl = li_loop_for(inst_parent(i));
        if sl >= 0 && sl != cl { return false; }
    }
    return true;
}

// BasicBlock::getUniquePredecessor
fn unique_pred_of(bb: i32) -> i32 {
    var r: i32 = -1;
    var u = vals[bb].first_use;
    while u >= 0 {
        let us = uses[u].user;
        if is_inst(us) && is_terminator(us) {
            let p = inst_parent(us);
            if r >= 0 && r != p { return -1; }
            r = p;
        }
        u = uses[u].next;
    }
    return r;
}

fn sk_sink_instruction(i: i32, stores: i32[>..<]&) -> bool {
    if !sk_is_safe_to_move(i, stores) { return false; }
    var succ: i32 = -1;
    let bb = inst_parent(i);
    var u = vals[i].first_use;
    while u >= 0 {
        let ui = uses[u].user;
        var ub = inst_parent(ui);
        if iop(ui) == OP_PHI {
            let k = u - vals[ui].ops;
            ub = phi_block(ui, k);
        }
        u = uses[u].next;
        if !dt_has_node(DT_DOM, ub) { continue; }
        if succ >= 0 { succ = dt_find_ncd(DT_DOM, succ, ub); } else { succ = ub; }
    }
    if succ >= 0 {
        while succ != bb && !sk_is_acceptable_target(i, succ) { succ = dt_idom(DT_DOM, succ); }
        if succ == bb { succ = -1; }
    }
    if succ < 0 { return false; }
    let pos = mu_first_insertion_pt(succ);
    if pos < 0 { fatal("sink: no insertion point in the target block"); }
    inst_move_before_head(i, pos);
    return true;
}

fn sk_process_block(bb: i32) -> bool {
    if !dt_has_node(DT_DOM, bb) { return false; }
    var changed = false;
    var stores: i32[>..<] = [];
    var it = block_last(bb);
    loop {
        let i = it;
        let processed_begin = it == block_first(bb);
        if !processed_begin { it = inst_prev(it); }
        if !mu_is_debug_or_pseudo(i) {
            if sk_sink_instruction(i, stores) { changed = true; }
        }
        if processed_begin { break; }
    }
    return changed;
}

fn sink_run(fv: i32) -> u32 {
    tli_cur_fn = fv;
    dt_get(fv, DT_DOM);
    li_get(fv);
    aa_begin(fv);
    var ever = false;
    loop {
        var changed = false;
        var bb = func_first_block(fv);
        while bb >= 0 {
            if sk_process_block(bb) { changed = true; }
            bb = block_next(bb);
        }
        if changed { ever = true; } else { break; }
    }
    if !ever { return PA_ALL; }
    return PA_CFG;
}
