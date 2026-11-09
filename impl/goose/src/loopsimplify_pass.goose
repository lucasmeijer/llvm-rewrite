// LoopSimplify's driver: simplifyOneLoop, simplifyLoop and LoopSimplifyPass::run (llvm/lib/Transforms/Utils/
// LoopSimplify.cpp), split from loopsimplify.goose so that the exit merging can call SimplifyCFG's
// foldBranchToCommonDest (simplifycfg.goose imports loopsimplify.goose).
import std;
import ir;
import irutil;
import instinfo;
import calls;
import analyses;
import domtree;
import memoryssa;
import mssaupdater;
import loopinfo;
import ssaupdater;
import loopsimplify;
import simplifycfg;
import flags;
import local;
import scev;
import scev_eval;
import scev_update;

// ---------------------------------------------------------------------------------------------
// simplifyOneLoop / simplifyLoop

fn simplify_one_loop(l: i32, worklist: i32[>..<]&, preserve_lcssa: bool) -> bool {
    var changed = false;
    loop {
        // Delete edges from predecessors outside the loop to non-header blocks (they are unreachable).
        var bad: i32[>..<] = [];
        var bi: i64 = 0;
        while bi < loop_nblocks(l) {
            let bb = loop_block(l, bi);
            bi++;
            if bb == loop_header(l) { continue; }
            bad.clear();
            each_pred(bb) { p => if !loop_contains(l, p) && position(bad, p) < 0 { bad.push(p); } };
            for p in bad {
                change_to_unreachable(block_terminator(p), preserve_lcssa);
                changed = true;
            }
        }
        var exiting: i32[>..<] = [];
        loop_exiting_blocks(l, exiting);
        for eb in exiting {
            let t = block_terminator(eb);
            if iop(t) == OP_CONDBR {
                let c = op(t, 0);
                if vals[c].kind == VK_UNDEF || vals[c].kind == VK_POISON {
                    let v: i64 = if loop_contains(l, term_succ(t, 0)) { 0 } else { 1 };
                    set_op(t, 0, c_int(vals[c].ty, v));
                    changed = true;
                }
            }
        }
        var preheader = loop_preheader(l);
        if preheader < 0 {
            preheader = insert_preheader_for_loop(l, preserve_lcssa);
            if preheader >= 0 { changed = true; }
        }
        if form_dedicated_exit_blocks(l, preserve_lcssa) { changed = true; }
        var latch = loop_latch(l);
        if latch < 0 {
            if loop_num_back_edges(l) < 8 {
                let outer = separate_nested_loop(l, preheader, preserve_lcssa);
                if outer >= 0 {
                    worklist.push(outer);
                    changed = true;
                    continue;       // goto ReprocessLoop
                }
            }
            latch = insert_unique_backedge_block(l, preheader);
            if latch >= 0 { changed = true; }
        }
        // Simplify the header PHIs.
        var i = block_first(loop_header(l));
        while i >= 0 && iop(i) == OP_PHI {
            let pn = i;
            i = inst_next(i);
            let v = ls_simplify_inst(pn);
            if v >= 0 {
                if ls_se { sc_forget_value(pn); }
                // LoopInfo::replacementPreservesLCSSAForm(PN, V)
                var ok = true;
                if preserve_lcssa && is_inst(v) && inst_parent(v) != inst_parent(pn) {
                    let tl = li_loop_for(inst_parent(v));
                    if tl >= 0 { ok = loop_contains_loop(tl, li_loop_for(inst_parent(pn))); }
                }
                if ok {
                    rauw(pn, v);
                    inst_erase_from_parent(pn);
                    changed = true;
                }
            }
        }
        // Merge exits through foldBranchToCommonDest when every exit goes to one block.
        var unique_exit: i32 = -1;
        var has_unique = true;
        for eb in exiting {
            let t = block_terminator(eb);
            for k in term_nsucc(t) {
                let s = term_succ(t, k);
                if loop_contains(l, s) { continue; }
                if unique_exit < 0 { unique_exit = s; } else if unique_exit != s { has_unique = false; }
            }
        }
        if has_unique {
            for eb in exiting {
                if single_pred(eb) < 0 { continue; }
                let t = block_terminator(eb);
                if iop(t) != OP_CONDBR { continue; }
                let ci = op(t, 0);
                if !is_inst(ci) || (iop(ci) != OP_ICMP && iop(ci) != OP_FCMP) || inst_parent(ci) != eb { continue; }
                var all_inv = true;
                var any_inv = false;
                var j = block_first(eb);
                while j >= 0 && j != t {
                    let nj = inst_next(j);
                    if j != ci {
                        let ip = if preheader >= 0 { block_terminator(preheader) } else { -1 };
                        mli_se = ls_se;
                        let ok = make_loop_invariant(l, j, ip, any_inv);
                        mli_se = false;
                        if !ok { all_inv = false; break; }
                    }
                    j = nj;
                }
                if any_inv { changed = true; }
                if !all_inv { continue; }
                // foldBranchToCommonDest(BI, /*DTU=*/nullptr, MSSAU) (TTI and AC null, BonusInstThreshold 1)
                if !ls_fold_branch_to_common_dest(t) { continue; }
                changed = true;
                li_remove_block(eb);
                let fv = block_func(eb);
                loop {
                    let c = dt_first_child(fv, DT_DOM, eb);
                    if c < 0 { break; }
                    dt_change_idom(fv, DT_DOM, c, dt_idom(DT_DOM, eb));
                }
                dt_erase_node(fv, DT_DOM, eb);
                if ls_mssau { msu_remove_blocks([eb]); }
                block_remove_predecessor(term_succ(t, 0), eb, preserve_lcssa);
                block_remove_predecessor(term_succ(t, 1), eb, preserve_lcssa);
                block_erase(eb);
            }
        }
        break;
    }
    return changed;
}

fn simplify_loop(l: i32, preserve_lcssa: bool) -> bool {
    var changed = false;
    var worklist: i32[>..<] = [];
    worklist.push(l);
    var idx: i64 = 0;
    while idx < worklist.len {
        let l2 = worklist[idx];
        for k in loop_nsubs(l2) { worklist.push(loop_sub(l2, k)); }
        idx++;
    }
    while worklist.len > 0 {
        let x = worklist.pop();
        if simplify_one_loop(x, worklist, preserve_lcssa) { changed = true; }
    }
    if changed && ls_se { sc_forget_topmost_loop(l); }
    return changed;
}

// LoopSimplifyPass::run
fn loop_simplify_run(fv: i32) -> u32 {
    li_get(fv);
    dt_get(fv, DT_DOM);
    // AM.getCachedResult<MemorySSAAnalysis>(F): keep it up to date with a MemorySSAUpdater
    let has_mssa = mssa_valid(fv);
    ls_mssau = has_mssa;
    ls_se = scev_valid(fv);
    if has_mssa { msu_reset(); }
    var changed = false;
    var k: i64 = 0;
    while k < li_ntop(fv) {
        if simplify_loop(li_top(fv, k), false) { changed = true; }
        k++;
    }
    ls_mssau = false;
    ls_se = false;
    if !changed { return PA_ALL; }
    var pa = ((1 as u32) << A_DOMTREE) | ((1 as u32) << A_LOOPS) | ((1 as u32) << A_SCEV);
    if has_mssa { pa |= (1 as u32) << A_MEMORYSSA; }
    return pa;
}

// foldBranchToCommonDest as LoopSimplify calls it: no DomTreeUpdater, no TTI, no AssumptionCache, the cached
// MemorySSA (if any) through scf_mssau
fn ls_fold_branch_to_common_dest(bi: i32) -> bool {
    let save_dtu = cu_dtu;
    cu_dtu = false;
    scf_fbcd_no_ac = true;
    scf_mssau = ls_mssau;
    cl_branch_fold_vec_mult = flag_int("simplifycfg-branch-fold-common-dest-vector-multiplier", 2);
    cl_branch_fold_threshold = flag_int("simplifycfg-branch-fold-threshold", 2);
    let save_tli = local_have_tli;
    local_have_tli = false;
    let r = fold_branch_to_common_dest(bi, false, 1);
    local_have_tli = save_tli;
    scf_fbcd_no_ac = false;
    scf_mssau = false;
    cu_dtu = save_dtu;
    return r;
}
