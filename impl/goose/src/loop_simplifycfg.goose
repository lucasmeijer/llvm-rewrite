// LoopSimplifyCFG: port of llvm/lib/Transforms/Scalar/LoopSimplifyCFG.cpp (whole).
// ConstantTerminatorFoldingImpl's state is the lsc_* globals; LiveLoopBlocks = VS_PASS0, LiveExitBlocks =
// VS_PASS1 (+ the vector lsc_live_exits for iteration), BlocksInLoopAfterFolding = VS_PASS2, the RPO numbers of
// hasIrreducibleCFG = VM_PASS0.
import std;
import ir;
import irutil;
import instinfo;
import analyses;
import flags;
import domtree;
import dtu;
import loopinfo;
import memoryssa;
import mssaupdater;
import lcssa;
import cfgutil;
import profdata;
import looprotate;
import tli;
import scev;
import scev_eval;
import scev_update;
import loop_utils;
import lpm;

var lsc_l: i32 = -1;
var lsc_fv: i32 = -1;
var lsc_mssau: bool = false;
var lsc_irreducible: bool = false;
var lsc_delete_current: bool = false;
var lsc_indirect_entry: bool = false;
var lsc_dead_loop_blocks: i32[>..<];
var lsc_live_exits: i32[>..<];
var lsc_dead_exits: i32[>..<];
var lsc_fold_candidates: i32[>..<];
var lsc_in_loop_after: i64 = 0;     // BlocksInLoopAfterFolding.size()
var lsc_n_live: i64 = 0;            // LiveLoopBlocks.size()
var lsc_ups: DTUpdate[>..<];
var lsc_post: i32[>..<];            // the DFS post-order
var lsc_rpo: i32[>..<];

// getOnlyLiveSuccessor
fn lsc_only_live_succ(bb: i32) -> i32 {
    let t = block_terminator(bb);
    if iop(t) == OP_CONDBR {
        if term_succ(t, 0) == term_succ(t, 1) { return term_succ(t, 0); }
        let c = op(t, 0);
        if vals[c].kind != VK_CINT { return -1; }
        return if is_null_value(c) { term_succ(t, 1) } else { term_succ(t, 0) };
    }
    if iop(t) == OP_SWITCH {
        let c = op(t, 0);
        if vals[c].kind != VK_CINT { return -1; }
        for k in (nops(t) - 2) / 2 { if op(t, 2 + 2 * k) == c { return op(t, 3 + 2 * k); } }
        return op(t, 1);
    }
    return -1;
}

// removeBlockFromLoops(BB, FirstLoop, LastLoop)
fn lsc_remove_block_from_loops(bb: i32, first: i32, last: i32) {
    var cur = first;
    while cur != last { loop_remove_block_from_loop(cur, bb); cur = loop_parent(cur); }
}

// getInnermostLoopFor(BBs, L, LI)
fn lsc_innermost_loop_for(bbs: const i32[:], l: i32) -> i32 {
    var inner: i32 = -1;
    for bb in bbs {
        var bbl = li_loop_for(bb);
        while bbl >= 0 && !loop_contains(bbl, loop_header(l)) { bbl = loop_parent(bbl); }
        if bbl == l { bbl = loop_parent(bbl); }
        if bbl < 0 { continue; }
        if inner < 0 || loop_depth(bbl) > loop_depth(inner) { inner = bbl; }
    }
    return inner;
}

fn lsc_has_irreducible_cfg(l: i32) -> bool {
    vm_clear(VM_PASS0);
    for k in lsc_rpo.len { vm_set(VM_PASS0, lsc_rpo[k], k); }
    for bb in lsc_rpo {
        for k in block_nsucc(bb) {
            let s = block_succ(bb, k);
            if loop_contains(l, s) && !li_is_loop_header(s) && vm_get(VM_PASS0, bb, 0) > vm_get(VM_PASS0, s, 0) { return true; }
        }
    }
    return false;
}

fn lsc_live_insert(bb: i32) { if vs_add(VS_PASS0, bb) { lsc_n_live++; } }

// IsEdgeLive
fn lsc_is_edge_live(from: i32, to: i32) -> bool {
    if !vs_has(VS_PASS0, from) { return false; }
    let only = lsc_only_live_succ(from);
    return only < 0 || only == to || li_loop_for(from) != lsc_l;
}

fn lsc_analyze() {
    let l = lsc_l;
    lu_loop_postorder(l, lsc_post);
    lsc_rpo.clear();
    var i = lsc_post.len - 1;
    while i >= 0 { lsc_rpo.push(lsc_post[i]); i--; }
    if lsc_has_irreducible_cfg(l) { lsc_irreducible = true; return; }
    if loop_preheader(l) < 0 { lsc_indirect_entry = true; return; }
    lsc_live_insert(loop_header(l));
    for bb in lsc_rpo {
        if !vs_has(VS_PASS0, bb) { lsc_dead_loop_blocks.push(bb); continue; }
        let only = lsc_only_live_succ(bb);
        let take = only >= 0 && li_loop_for(bb) == l;
        if take { lsc_fold_candidates.push(bb); }
        for k in block_nsucc(bb) {
            let s = block_succ(bb, k);
            if !take || only == s {
                if loop_contains(l, s) { lsc_live_insert(s); }
                else if vs_add(VS_PASS1, s) { lsc_live_exits.push(s); }
            }
        }
    }
    var exits: i32[>..<] = [];
    loop_exit_blocks(l, exits);
    var uniq: i32[>..<] = [];
    for e in exits {
        if vs_has(VS_PASS1, e) { continue; }
        if !cu_push_unique(uniq, e) { continue; }
        var all_in = true;
        each_pred(e) { p => if !loop_contains(l, p) { all_in = false; } };
        if all_in { lsc_dead_exits.push(e); }
    }
    lsc_delete_current = !lsc_is_edge_live(loop_latch(l), loop_header(l));
    if lsc_delete_current { return; }
    if vs_add(VS_PASS2, loop_latch(l)) { lsc_in_loop_after++; }
    for bb in lsc_post {
        var in_loop = false;
        for k in block_nsucc(bb) {
            let s = block_succ(bb, k);
            if vs_has(VS_PASS2, s) && lsc_is_edge_live(bb, s) { in_loop = true; break; }
        }
        if in_loop && vs_add(VS_PASS2, bb) { lsc_in_loop_after++; }
    }
}

// Function::hasProfileData: a function_entry_count other than -1
fn lsc_has_profile_data(fv: i32) -> bool {
    let g = glob_of(fv);
    let k = md_kind_id("prof");
    for j in globs[g].nmd {
        if md_att[globs[g].md + 2 * j] != k { continue; }
        let m = md_att[globs[g].md + 2 * j + 1];
        if mds[m].nops < 2 { return false; }
        if !pd_md_string_is(md_op(m, 0), "function_entry_count") && !pd_md_string_is(md_op(m, 0), "synthetic_function_entry_count") { return false; }
        if pd_md_string_is(md_op(m, 0), "synthetic_function_entry_count") { return false; }
        let o = md_op(m, 1);
        if o < 0 || mds[o].kind != MK_VALUE { return false; }
        let c = mds[o].extra;
        if vals[c].kind != VK_CINT { return false; }
        return !is_all_ones_cint(c);
    }
    return false;
}
fn is_all_ones_cint(c: i32) -> bool { ap_is_all_ones(ci_ap(c)) }

fn lsc_apply_ups() {
    dt_apply_updates(lsc_fv, DT_DOM, lsc_ups);
    lsc_ups.clear();
}

fn lsc_handle_dead_exits() {
    if lsc_dead_exits.len == 0 { return; }
    let l = lsc_l;
    let preheader = loop_preheader(l);
    let new_ph = lu_split_block(preheader, block_terminator(preheader), lsc_mssau);
    let t = block_terminator(preheader);
    let si = new_inst(OP_SWITCH, T_VOID, 2 + 2 * 10);
    vals[si].nops = 2;
    set_op(si, 0, c_int(T_I32, 0));
    set_op(si, 1, new_ph);
    lu_copy_dbg_loc(si, t);
    inst_insert_before(si, t);
    inst_erase_from_parent(block_terminator(preheader));
    var idx: i64 = 1;
    for bb in lsc_dead_exits {
        var dead: i32[>..<] = [];
        var p = block_first(bb);
        while p >= 0 && iop(p) == OP_PHI { dead.push(p); p = inst_next(p); }
        if p >= 0 && iop(p) == OP_LANDINGPAD { dead.push(p); }
        for d in dead {
            sc_forget_value(d);
            if vals[d].first_use >= 0 { rauw(d, c_poison(vals[d].ty)); }
            inst_erase_from_parent(d);
        }
        sw_add_case_raw(si, c_int(T_I32, idx), bb);
        idx++;
        lsc_ups.push(DTUpdate { kind: DT_INSERT, from: preheader, to: bb });
    }
    if lsc_has_profile_data(lsc_fv) {
        var ws: u64[>..<] = [];
        ws.push(1);
        for k in sw_ncases(si) { ws.push(0); }
        pd_set(si, ws, false, false);
    }
    let outer = li_loop_for(preheader);
    if outer >= 0 {
        let still = lsc_innermost_loop_for(lsc_live_exits, l);
        if still != outer {
            li_change_loop_for(new_ph, still);
            lsc_remove_block_from_loops(new_ph, outer, still);
            for k in loop_nblocks(l) { lsc_remove_block_from_loops(loop_block(l, k), outer, still); }
            loop_remove_child(outer, l);
            if still >= 0 { loop_add_child(still, l); } else { li_add_top_level_loop(lsc_fv, l); }
            var fix = outer;
            while loop_parent(fix) != still { fix = loop_parent(fix); }
            if lsc_mssau { msu_apply_updates(lsc_fv, lsc_ups, true); lsc_ups.clear(); }
            else { lsc_apply_ups(); }
            let save = lcssa_se;
            lcssa_se = true;
            form_lcssa_recursively(fix);
            lcssa_se = save;
            sc_forget_block_and_loop_dispositions_all();
        }
    }
    if lsc_mssau {
        msu_apply_updates(lsc_fv, lsc_ups, true);
        lsc_ups.clear();
        if flag_bool("verify-memoryssa", false) { mssa_verify(lsc_fv); }
    }
}

fn lsc_delete_dead_loop_blocks() {
    if lsc_mssau {
        var set: i32[>..<] = [];
        for b in lsc_dead_loop_blocks { cu_push_unique(set, b); }
        msu_remove_blocks(set);
    }
    for bb in lsc_dead_loop_blocks {
        if li_is_loop_header(bb) {
            let dl = li_loop_for(bb);
            if !loop_is_outermost(dl) {
                var pl = loop_parent(dl);
                while pl >= 0 {
                    for k in loop_nblocks(dl) { loop_remove_block_from_loop(pl, loop_block(dl, k)); }
                    pl = loop_parent(pl);
                }
                loop_remove_child(loop_parent(dl), dl);
                li_add_top_level_loop(lsc_fv, dl);
            }
            lu_li_erase(lsc_fv, dl);
        }
    }
    for bb in lsc_dead_loop_blocks { li_remove_block(bb); }
    cu_dtu = true;
    cu_detach_dead_blocks(lsc_dead_loop_blocks, lsc_ups, true);
    cu_dtu = false;
    lsc_apply_ups();
    // DTU.deleteBB (eager): erase the tree node, then the block
    for bb in lsc_dead_loop_blocks {
        if dt_has_node(DT_DOM, bb) { dt_erase_node(lsc_fv, DT_DOM, bb); }
        lu_erase_dead_block(bb);
    }
}

fn lsc_fold_terminators() {
    let l = lsc_l;
    for bb in lsc_fold_candidates {
        let only = lsc_only_live_succ(bb);
        var dead: i32[>..<] = [];
        var dups: i64 = 0;
        var succs: i32[>..<] = [];
        cu_succs(bb, succs);
        for s in succs {
            if s != only {
                cu_push_unique(dead, s);
                block_remove_predecessor(s, bb, !loop_contains(l, s));
                if lsc_mssau { msu_remove_edge(bb, s); }
            } else { dups++; }
        }
        let keep = !loop_contains(l, only);
        for d in 1..dups { block_remove_predecessor(only, bb, keep); }
        if lsc_mssau && dups > 1 { msu_remove_duplicate_phi_edges_between(bb, only); }
        let t = block_terminator(bb);
        let br = create_inst(OP_BR, T_VOID, [only]);
        lu_copy_dbg_loc(br, t);
        inst_insert_before(br, t);
        inst_erase_from_parent(t);
        // SmallPtrSet iteration order: pointer order in LLVM, not reproducible beyond two entries (see knowledge/)
        for d in dead { lsc_ups.push(DTUpdate { kind: DT_DELETE, from: bb, to: d }); }
    }
}

// ConstantTerminatorFoldingImpl::run
fn lsc_constant_terminator_folding(l: i32) -> bool {
    lsc_l = l;
    lsc_irreducible = false;
    lsc_delete_current = false;
    lsc_indirect_entry = false;
    lsc_dead_loop_blocks.clear();
    lsc_live_exits.clear();
    lsc_dead_exits.clear();
    lsc_fold_candidates.clear();
    lsc_ups.clear();
    lsc_in_loop_after = 0;
    lsc_n_live = 0;
    vs_clear(VS_PASS0);
    vs_clear(VS_PASS1);
    vs_clear(VS_PASS2);
    lsc_analyze();
    if lsc_irreducible || lsc_indirect_entry { return false; }
    if lsc_fold_candidates.len == 0 { return false; }
    if lsc_delete_current { return false; }
    if lsc_in_loop_after + lsc_dead_loop_blocks.len != loop_nblocks(l) { return false; }
    if lsc_dead_exits.len > 0 && !lsc_is_lcssa_form(l) { return false; }
    sc_forget_topmost_loop(l);
    if lsc_dead_loop_blocks.len > 0 { sc_forget_block_and_loop_dispositions_all(); }
    lsc_handle_dead_exits();
    lsc_fold_terminators();
    if lsc_dead_loop_blocks.len > 0 { lsc_delete_dead_loop_blocks(); }
    else { lsc_apply_ups(); }
    if lsc_mssau && flag_bool("verify-memoryssa", false) { mssa_verify(lsc_fv); }
    return true;
}

// Loop::isLCSSAForm(DT, IgnoreTokens = false)
fn lsc_is_lcssa_form(l: i32) -> bool {
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        var i = block_first(bb);
        while i >= 0 {
            var u = vals[i].first_use;
            while u >= 0 {
                let us = uses[u].user;
                var ubb = inst_parent(us);
                if iop(us) == OP_PHI { ubb = use_aux[u]; }
                if ubb != bb && !loop_contains(l, ubb) && dt_has_node(DT_DOM, ubb) { return false; }
                u = uses[u].next;
            }
            i = inst_next(i);
        }
    }
    return true;
}

// mergeBlocksIntoPredecessors
fn lsc_merge_blocks_into_predecessors(l: i32) -> bool {
    var changed = false;
    var blocks: i32[>..<] = [];
    for k in loop_nblocks(l) { blocks.push(loop_block(l, k)); }
    lr_fv = lsc_fv;
    lr_mssau = lsc_mssau;
    for bi in blocks.len {
        let succ = blocks[bi];
        if succ < 0 || is_dead(succ) { continue; }
        let pred = single_pred(succ);
        if pred < 0 || cu_single_succ(pred) < 0 || li_loop_for(pred) != l { continue; }
        lr_merge_block_into_predecessor(succ, false);
        // the WeakTrackingVHs follow BB->replaceAllUsesWith(PredBB)
        for k in bi + 1..blocks.len { if blocks[k] == succ { blocks[k] = pred; } }
        if lsc_mssau && flag_bool("verify-memoryssa", false) { mssa_verify(lsc_fv); }
        changed = true;
    }
    lr_mssau = false;
    if changed { sc_forget_block_and_loop_dispositions_all(); }
    return changed;
}

// LoopSimplifyCFGPass::run
fn loop_simplifycfg_pass_run(l: i32, use_mssa: bool) -> u32 {
    lsc_fv = block_func(loop_header(l));
    tli_cur_fn = lsc_fv;
    lsc_mssau = use_mssa;
    if use_mssa { msu_reset(); }
    var changed = false;
    var deleted = false;
    if flag_bool("enable-loop-simplifycfg-term-folding", true) && loop_latch(l) >= 0 {
        let c = lsc_constant_terminator_folding(l);
        changed = c;
        deleted = c && lsc_delete_current;
    }
    if !deleted {
        if lsc_merge_blocks_into_predecessors(l) { changed = true; }
        if changed { sc_forget_topmost_loop(l); }
    }
    lsc_mssau = false;
    if !changed { return PA_ALL; }
    if deleted { lpm_mark_loop_as_deleted(l); }
    var pa = ((1 as u32) << A_DOMTREE) | ((1 as u32) << A_LOOPS) | ((1 as u32) << A_SCEV);
    if use_mssa { pa |= (1 as u32) << A_MEMORYSSA; }
    return pa;
}
