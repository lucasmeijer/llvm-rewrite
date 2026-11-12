// LoopSink: port of llvm/lib/Transforms/Scalar/LoopSink.cpp (LoopSinkPass), with canSinkOrHoistInst and
// SinkAndHoistLICMFlags from licm.goose.
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import flags;
import domtree;
import loopinfo;
import bfi;
import bpi;
import aa;
import memoryssa;
import mssaupdater;
import licm;
import scev;
import scev_eval;
import tli;
import mem2reg;
import clone_function;
import o2_small;
import misc_util;

fn ls_sum_freq(bbs: const i32[:]) -> u64 {
    var t: u64 = 0;
    for b in bbs { let f = bfi_freq(b); let s = t + f; t = if s < t { 0xFFFFFFFFFFFFFFFF } else { s }; }
    if bbs.len > 1 { t = bp_scale_by_inverse(bp_new(flag_int("sink-freq-percent-threshold", 90) as u64, 100), t); }
    return t;
}

fn ls_contains(xs: i32[>..<]&, v: i32) -> bool { for x in xs { if x == v { return true; } } return false; }

// findBBsToSinkInto
fn ls_find_bbs(l: i32, use_bbs: i32[>..<]&, cold: const i32[:], out: i32[>..<]&) {
    out.clear();
    if use_bbs.len == 0 { return; }
    for b in use_bbs { out.push(b); }
    for coldest in cold {
        var dom: i32[>..<] = [];
        for s in out { if dt_dominates_block(DT_DOM, coldest, s) { dom.push(s); } }
        if dom.len == 0 { continue; }
        if ls_sum_freq(dom) > bfi_freq(coldest) {
            var keep: i32[>..<] = [];
            for s in out { if !ls_contains(dom, s) { keep.push(s); } }
            out.clear();
            for s in keep { out.push(s); }
            if !ls_contains(out, coldest) { out.push(coldest); }
            continue;
        }
        if ls_sum_freq(out) <= bfi_freq(coldest) { break; }
    }
    for b in out {
        if mu_first_insertion_pt(b) < 0 { out.clear(); break; }
    }
    if ls_sum_freq(out) > bfi_freq(loop_preheader(l)) { out.clear(); }
}

fn ls_sink_instruction(l: i32, i: i32, cold: const i32[:], num_b: const i32[:], num_v: const i32[:]) -> bool {
    var bbs: i32[>..<] = [];
    var u = vals[i].first_use;
    while u >= 0 {
        let ui = uses[u].user;
        let k = u - vals[ui].ops;
        u = uses[u].next;
        let ul = li_loop_for(inst_parent(ui));
        if ul < 0 || !loop_contains_loop(l, ul) { return false; }
        if iop(ui) != OP_PHI { if !ls_contains(bbs, inst_parent(ui)) { bbs.push(inst_parent(ui)); } continue; }
        let pb = phi_block(ui, k);
        if loop_preheader(l) == pb { return false; }
        if !ls_contains(bbs, pb) { bbs.push(pb); }
    }
    if bbs.len > flag_int("max-uses-for-sinking", 30) { return false; }
    var into: i32[>..<] = [];
    ls_find_bbs(l, bbs, cold, into);
    if into.len == 0 { return false; }
    fn number(b: i32, num_b: const i32[:], num_v: const i32[:]) -> i32 { for x, k in num_b { if x == b { return num_v[k]; } } return -1; }
    if into.len > 1 { for b in into { if number(b, num_b, num_v) < 0 { return false; } } }
    var sorted: i32[>..<] = [];
    for b in into { sorted.push(b); }
    if sorted.len > 1 {
        var a: i64 = 1;
        while a < sorted.len {
            var j = a;
            while j > 0 && number(sorted[j], num_b, num_v) < number(sorted[j - 1], num_b, num_v) {
                let t = sorted[j]; sorted[j] = sorted[j - 1]; sorted[j - 1] = t; j--;
            }
            a++;
        }
    }
    let move_bb = sorted[0];
    for q in 1..sorted.len {
        let n = sorted[q];
        let ic = inst_clone(i);
        inst_insert_before_head(ic, mu_first_insertion_pt(n));
        if vals[i].name >= 0 { set_name(ic, val_name(i)); }
        if mssa_access_of(i) >= 0 {
            let na = msu_create_access_in_bb(ic, -1, n, MSP_BEGINNING, false);
            if na >= 0 {
                if macc[na].kind == MAK_DEF { msu_insert_def(na, true); } else { msu_insert_use(na, true); }
            }
        }
        var u2 = vals[i].first_use;
        while u2 >= 0 {
            let nx = uses[u2].next;
            let ui = uses[u2].user;
            if inst_parent(ui) == n && iop(ui) != OP_PHI { use_set(u2, ic); }
            u2 = nx;
        }
        // replaceDominatedUsesWith(&I, IC, DT, N)
        u2 = vals[i].first_use;
        while u2 >= 0 {
            let nx = uses[u2].next;
            let ui = uses[u2].user;
            var dom = false;
            if iop(ui) == OP_PHI { dom = dt_dominates_block(DT_DOM, n, phi_block(ui, u2 - vals[ui].ops)); }
            else { dom = dt_properly_dominates_block(DT_DOM, n, inst_parent(ui)); }
            if dom { use_set(u2, ic); }
            u2 = nx;
        }
    }
    inst_move_impl(i, move_bb, mu_first_insertion_pt(move_bb), true, false);
    let oa = mssa_access_of(i);
    if oa >= 0 { msu_move_to_place(oa, move_bb, MSP_BEGINNING); }
    return true;
}

fn ls_sink_loop_invariant(l: i32) -> bool {
    let ph = loop_preheader(l);
    let phf = bfi_freq(ph);
    var all = true;
    for k in loop_nblocks(l) { if !(bfi_freq(loop_block(l, k)) > phf) { all = false; } }
    if all { return false; }
    msu_reset();
    lc_l = l;
    lc_flags_init(l);
    var changed = false;
    var cold: i32[>..<] = [];
    var num_b: i32[>..<] = [];
    var num_v: i32[>..<] = [];
    var n: i32 = 0;
    for k in loop_nblocks(l) {
        let b = loop_block(l, k);
        if bfi_freq(b) < phf { cold.push(b); n++; num_b.push(b); num_v.push(n); }
    }
    // stable_sort by frequency
    var a: i64 = 1;
    while a < cold.len {
        var j = a;
        while j > 0 && bfi_freq(cold[j]) < bfi_freq(cold[j - 1]) { let t = cold[j]; cold[j] = cold[j - 1]; cold[j - 1] = t; j--; }
        a++;
    }
    var i = block_last(ph);
    while i >= 0 {
        let prev = inst_prev(i);
        if iop(i) != OP_PHI {
            if lc_can_sink_or_hoist(i, l, false) {
                // SE is nullptr in LoopSinkPass::run
                if ls_sink_instruction(l, i, cold, num_b, num_v) { changed = true; }
            }
        }
        i = prev;
    }
    return changed;
}

fn loop_sink_run(fv: i32) -> u32 {
    if !os_has_profile_data(fv) { return PA_ALL; }
    li_get(fv);
    if li_ntop(fv) == 0 { return PA_ALL; }
    tli_cur_fn = fv;
    aa_begin(fv);
    dt_get(fv, DT_DOM);
    bfi_get(fv);
    mssa_get(fv);
    lc_fv = fv;
    lc_allow_spec = true;
    lc_tti_ready = false;
    m2r_collect_records(fv);
    var pre: i32[>..<] = [];
    var k = li_ntop(fv);
    while k > 0 { k--; loop_loops_in_preorder(li_top(fv, k), pre); }
    var changed = false;
    while pre.len > 0 {
        let l = pre.pop();
        if loop_preheader(l) < 0 { continue; }
        if ls_sink_loop_invariant(l) { changed = true; }
    }
    if !changed { return PA_ALL; }
    return PA_CFG | ((1 as u32) << A_MEMORYSSA);
}
