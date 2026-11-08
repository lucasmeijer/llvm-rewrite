// Critical edge splitting and the break-crit-edges pass.
// Ports llvm/lib/Transforms/Utils/BreakCriticalEdges.cpp (SplitCriticalEdge, SplitKnownCriticalEdge,
// BreakCriticalEdgesPass::run), SplitAllCriticalEdges from llvm/lib/Transforms/Utils/BasicBlockUtils.cpp and
// isCriticalEdge from llvm/lib/Analysis/CFG.cpp. The (post)dominator trees and LoopInfo are updated when
// the options say they are available (LLVM: non-null DT/PDT/LI pointers).
import std;
import ir;
import irutil;
import instinfo;
import analyses;
import domtree;
import loopinfo;
import loopsimplify;
import memoryssa;
import mssaupdater;

// CriticalEdgeSplittingOptions
struct CESOpts { dt: bool, pdt: bool, li: bool, merge_identical: bool, keep_one_input_phis: bool, preserve_lcssa: bool,
                 ignore_unreachable_dests: bool, preserve_loop_simplify: bool, mssau: bool }
fn ces_opts(dt: bool, li: bool, pdt: bool) -> CESOpts {
    CESOpts { dt: dt, pdt: pdt, li: li, merge_identical: false, keep_one_input_phis: false, preserve_lcssa: false,
              ignore_unreachable_dests: false, preserve_loop_simplify: true, mssau: false }
}

// isCriticalEdge(TI, SuccNum, AllowIdenticalEdges)
fn is_critical_edge(ti: i32, k: i64, allow_identical: bool) -> bool {
    if term_nsucc(ti) == 1 { return false; }
    let dest = term_succ(ti, k);
    var n = 0;
    var first: i32 = -1;
    var other = false;
    each_pred(dest) { p =>
        if n == 0 { first = p; } else if p != first { other = true; }
        n++;
    };
    if !allow_identical { return n > 1; }
    return other;
}

// BasicBlock::getFirstNonPHIOrDbgOrLifetime
fn first_non_phi_or_lifetime(bv: i32) -> i32 {
    var i = block_first(bv);
    while i >= 0 && (iop(i) == OP_PHI || inst_is_lifetime_start_or_end(i)) { i = inst_next(i); }
    return i;
}

// SplitCriticalEdge(TI, SuccNum, Options, BBName): the new block, or -1.
fn split_critical_edge(ti: i32, k: i64, o: CESOpts, name: const u8[:]) -> i32 {
    if !is_critical_edge(ti, k, o.merge_identical) { return -1; }
    return split_known_critical_edge(ti, k, o, name);
}

fn split_known_critical_edge(ti: i32, k: i64, o: CESOpts, name: const u8[:]) -> i32 {
    let tibb = inst_parent(ti);
    let dest = term_succ(ti, k);
    let fv = block_func(tibb);
    let fnp = first_non_phi(dest);
    if (fnp >= 0 && inst_is_eh_pad(fnp)) || iop(ti) == OP_INDIRECTBR { return -1; }
    if o.ignore_unreachable_dests {
        let x = first_non_phi_or_lifetime(dest);
        if x >= 0 && iop(x) == OP_UNREACHABLE { return -1; }
    }
    var loop_preds: i32[>..<] = [];
    if o.li {
        let til = li_loop_for(tibb);
        if til >= 0 {
            var cleared = false;
            each_pred(dest) { p =>
                if !cleared && p != tibb {
                    if li_loop_for(p) != til { loop_preds.clear(); cleared = true; }
                    else { loop_preds.push(p); }
                }
            };
            var any_ibr = false;
            for p in loop_preds { if iop(block_terminator(p)) == OP_INDIRECTBR { any_ibr = true; } }
            if any_ibr {
                if o.preserve_loop_simplify { return -1; }
                loop_preds.clear();
            }
        }
    }
    // Create a new basic block, linking it into the CFG: the branch is created first (its use of DestBB goes to
    // the head of DestBB's use list), then the block is inserted after TIBB, then TI is redirected.
    var nm: u8[>..] = [];
    if name.len > 0 { nm.append(name); }
    else {
        nm.append(val_name(tibb));
        nm.push('.');
        nm.append(val_name(dest));
        nm.append("_crit_edge");
    }
    let br = create_inst(OP_BR, T_VOID, [dest]);
    let dl = inst_get_md(ti, 0);
    if dl >= 0 { inst_set_md(br, 0, dl); }
    let lmd = inst_get_md(ti, MDK_LOOP);
    if lmd >= 0 { inst_set_md(br, MDK_LOOP, lmd); }
    let nb = create_block_after(fv, tibb, nm);
    block_append_inst(nb, br);
    term_set_succ(ti, k, nb);
    // Revector exactly one incoming entry of each PHI in DestBB from TIBB to NewBB.
    var bbidx: i64 = 0;
    var i = block_first(dest);
    while i >= 0 && iop(i) == OP_PHI {
        if phi_block(i, bbidx) != tibb { bbidx = phi_block_index(i, tibb); }
        phi_set_block(i, bbidx, nb);
        i = inst_next(i);
    }
    var nsplit = 1;
    if o.merge_identical {
        for j in k + 1..term_nsucc(ti) {
            if term_succ(ti, j) != dest { continue; }
            block_remove_predecessor(dest, tibb, o.keep_one_input_phis);
            term_set_succ(ti, j, nb);
            nsplit++;
        }
    }
    if o.mssau { msu_wire_old_preds_to_new_pred(dest, nb, [tibb], o.merge_identical); }
    if !o.dt && !o.pdt && !o.li { return nb; }
    if o.dt || o.pdt {
        var ups: DTUpdate[>..<] = [];
        ups.push(DTUpdate { kind: DT_INSERT, from: tibb, to: nb });
        ups.push(DTUpdate { kind: DT_INSERT, from: nb, to: dest });
        var still = false;
        for j in term_nsucc(ti) { if term_succ(ti, j) == dest { still = true; } }
        if !still { ups.push(DTUpdate { kind: DT_DELETE, from: tibb, to: dest }); }
        if o.dt { dt_apply_updates(fv, DT_DOM, ups); }
        if o.pdt { dt_apply_updates(fv, DT_POST, ups); }
    }
    if o.li {
        let til = li_loop_for(tibb);
        if til >= 0 {
            let dl2 = li_loop_for(dest);
            if dl2 >= 0 {
                if til == dl2 { loop_add_basic_block_to_loop(dl2, nb); }
                else if loop_contains_loop(til, dl2) { loop_add_basic_block_to_loop(til, nb); }
                else if loop_contains_loop(dl2, til) { loop_add_basic_block_to_loop(dl2, nb); }
                else {
                    let p = loop_parent(dl2);
                    if p >= 0 { loop_add_basic_block_to_loop(p, nb); }
                }
            }
            if !loop_contains(til, dest) {
                if o.preserve_lcssa {
                    var reps: i32[>..<] = [];
                    for r in nsplit { reps.push(tibb); }
                    create_phis_for_split_loop_exit(reps, nb, dest);
                }
                if loop_preds.len > 0 {
                    let save = ls_mssau;
                    ls_mssau = o.mssau;
                    let neb = split_block_predecessors(dest, loop_preds, "split", o.dt, o.li, o.preserve_lcssa);
                    ls_mssau = save;
                    if o.preserve_lcssa { create_phis_for_split_loop_exit(loop_preds, neb, dest); }
                }
            }
        }
    }
    return nb;
}

// SplitAllCriticalEdges(F, Options)
fn split_all_critical_edges(fv: i32, o: CESOpts) -> i64 {
    var n: i64 = 0;
    var b = func_first_block(fv);
    while b >= 0 {
        let ti = block_terminator(b);
        if ti >= 0 && term_nsucc(ti) > 1 && iop(ti) != OP_INDIRECTBR {
            for k in term_nsucc(ti) {
                if split_critical_edge(ti, k, o, "") >= 0 { n++; }
            }
        }
        b = block_next(b);
    }
    return n;
}

// BreakCriticalEdgesPass::run: updates the cached DominatorTree and LoopInfo.
fn break_crit_edges_run(fv: i32) -> u32 {
    let n = split_all_critical_edges(fv, ces_opts(dt_valid(fv, DT_DOM), li_valid(fv), false));
    if n == 0 { return PA_ALL; }
    return ((1 as u32) << A_DOMTREE) | ((1 as u32) << A_LOOPS);
}

// createPHIsForSplitLoopExit(Preds, SplitBB, DestBB) (BasicBlockUtils.cpp)
fn create_phis_for_split_loop_exit(preds: const i32[:], split_bb: i32, dest: i32) {
    var i = block_first(dest);
    while i >= 0 && iop(i) == OP_PHI {
        let pn = i;
        i = inst_next(i);
        let idx = phi_block_index(pn, split_bb);
        if idx < 0 { fatal("internal: createPHIsForSplitLoopExit: invalid block index"); }
        let v = phi_value(pn, idx);
        if is_inst_op(v, OP_PHI) && inst_parent(v) == split_bb { continue; }
        let np = new_phi(vals[pn].ty, preds.len);
        let fnp = first_non_phi(split_bb);
        let is_lp = fnp >= 0 && iop(fnp) == OP_LANDINGPAD;
        if is_lp { inst_insert_before(np, block_first(split_bb)); } else { inst_insert_before(np, block_terminator(split_bb)); }
        set_name(np, "split");
        for b in preds { phi_add_incoming(np, v, b); }
        set_op(pn, idx, np);
    }
}
