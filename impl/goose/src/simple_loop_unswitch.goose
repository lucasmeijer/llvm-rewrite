// SimpleLoopUnswitch: port of llvm/lib/Transforms/Scalar/SimpleLoopUnswitch.cpp.
// This file: the cl::opts, skipTrivialSelect, collectHomogenousInstGraphLoopInvariants,
// replaceLoopInvariantUses, areLoopExitPHIsLoopInvariant, buildPartialUnswitchConditionalBranch,
// buildPartialInvariantUnswitchConditionalBranch, rewritePHINodesForUnswitchedExitBlock,
// rewritePHINodesForExitAndUnswitchedBlocks, hoistLoopToNewParent, getTopMostExitingLoop, unswitchTrivialBranch,
// unswitchTrivialSwitch, unswitchAllTrivialConditions. The non-trivial unswitching is
// simple_loop_unswitch_nt.goose; the pass entry is there too.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_attrs;
import gen_iids;
import flags;
import pm;
import poison;
import vt;
import domtree;
import loopinfo;
import loopsimplify;
import lcssa;
import cfgutil;
import profdata;
import bfi;
import memoryssa;
import mssaupdater;
import scev;
import scev_btc;
import scev_update;
import value_mapper;
import loop_md;
import unroll_utils;

fn slu_not_ported(what: const u8[:]) { fatal(str("SimpleLoopUnswitch: ", what, " is not ported yet")); }

var slu_mssau: bool = false;   // a MemorySSAUpdater exists
var slu_se: bool = false;      // a ScalarEvolution exists
var slu_fv: i32 = -1;

fn slu_verify_mssa() { if slu_mssau && flag_bool("verify-memoryssa", false) { mssa_verify(slu_fv); } }

// Loop::isLoopInvariant(V)
fn slu_invariant(l: i32, v: i32) -> bool { if is_inst(v) { return !loop_contains(l, inst_parent(v)); } return true; }

// skipTrivialSelect: select c, true, false -> c
fn skip_trivial_select(c0: i32) -> i32 {
    var c = c0;
    loop {
        if !is_inst_op(c, OP_SELECT) { return c; }
        let t = op(c, 1);
        let f = op(c, 2);
        if !(is_constant(t) && is_one_value(t)) || !(is_constant(f) && is_null_value(f)) { return c; }
        c = op(c, 0);
    }
    return c;
}

// collectHomogenousInstGraphLoopInvariants(L, Root, LI)
fn collect_homogenous_inst_graph_loop_invariants(l: i32, root: i32, out: i32[>..<]&) {
    let is_and = m_logical(root, true);
    let is_or = m_logical(root, false);
    var wl: i32[>..<] = [];
    var visited: i32[>..<] = [];
    wl.push(root);
    visited.push(root);
    while wl.len > 0 {
        let i = wl.pop();
        for k in nops(i) {
            let o = op(i, k);
            if is_constant(o) { continue; }
            if slu_invariant(l, o) { out.push(o); continue; }
            let oi = skip_trivial_select(o);
            if is_inst(oi) && ((is_and && m_logical(oi, true)) || (is_or && m_logical(oi, false))) {
                if position(visited, oi) < 0 { visited.push(oi); wl.push(oi); }
            }
        }
    }
}

// replaceLoopInvariantUses(L, Invariant, Replacement)
fn replace_loop_invariant_uses(l: i32, inv: i32, rep: i32) {
    var u = vals[inv].first_use;
    while u >= 0 {
        let nx = uses[u].next;
        let us = uses[u].user;
        if is_inst(us) && loop_contains(l, inst_parent(us)) { use_set(u, rep); }
        u = nx;
    }
}

// areLoopExitPHIsLoopInvariant(L, ExitingBB, ExitBB)
fn are_loop_exit_phis_loop_invariant(l: i32, exiting: i32, exit: i32) -> bool {
    var i = block_first(exit);
    while i >= 0 && iop(i) == OP_PHI {
        if !slu_invariant(l, phi_value_for_block(i, exiting)) { return false; }
        i = inst_next(i);
    }
    return true;
}

// setExplicitlyUnknownBranchWeightsIfProfiled(I, "simple-loop-unswitch")
fn slu_set_unknown_weights_if_profiled(i: i32) {
    let has, c = bf_entry_count(block_func(inst_parent(i)));
    if !has || c == 0 { return; }
    let ops: i32[2] = [md_string("unknown"), md_string("simple-loop-unswitch")];
    inst_set_md(i, MDK_PROF, md_get(MK_TUPLE, -1, ops, false));
}

// IRBuilder<> IRB(&BB) with DebugLoc::getCompilerGenerated(): append at the end, no location
fn slu_append(bb: i32, i: i32, name: const u8[:]) -> i32 {
    block_append_inst(bb, i);
    if name.len > 0 && vals[i].ty != T_VOID { set_name(i, name); }
    return i;
}
// IRB.CreateOr / CreateAnd (ConstantFolder) appended to bb
fn slu_create_logic(bb: i32, o: i64, a: i32, b: i32) -> i32 {
    if is_constant(b) {
        if o == OP_OR && is_null_value(b) { return a; }
        if o == OP_AND && vals[b].kind == VK_CINT && is_all_ones_value(b) { return a; }
    }
    if is_constant(a) && is_constant(b) {
        let r = ce_binop_or_fold(o, a, b);
        if r >= 0 { return r; }
    }
    return slu_append(bb, create_inst(o, vals[a].ty, [a, b]), "");
}
fn ce_binop_or_fold(o: i64, a: i32, b: i32) -> i32 { cf_fold_binop_operands(o, a, b) }

// buildPartialUnswitchConditionalBranch(BB, Invariants, Direction, UnswitchedSucc, NormalSucc, InsertFreeze, I,
// AC = nullptr, DT, ComputeProfFrom)
fn build_partial_unswitch_conditional_branch(bb: i32, invs: const i32[:], dir: bool, unswitched: i32, normal: i32,
                                             insert_freeze: bool, ctx: i32, prof_from: i32) {
    var ws: u64[>..<] = [];
    var has_w = flag_bool("simple-loop-unswitch-estimate-profile", true) && pd_extract(prof_from, ws);
    if has_w {
        var sum: f64 = 0.0;
        for w in ws { sum += w as f64; }
        let x = (ws[if dir { 0 } else { 1 }] as f64) / sum;
        if x > 0.5 { has_w = false; }
    }
    var frozen: i32[>..<] = [];
    for inv0 in invs {
        var inv = inv0;
        let save = sq_no_ac;
        sq_no_ac = true;
        let g = is_guaranteed_not_to_be_undef_or_poison(inv, ctx, 0);
        sq_no_ac = save;
        if insert_freeze && !g {
            var nm: u8[>..] = [];
            nm.append(val_name(inv));
            nm.append(".fr");
            inv = slu_append(bb, create_inst(OP_FREEZE, vals[inv].ty, [inv]), nm);
        }
        frozen.push(inv);
    }
    var cond = frozen[0];
    for k in 1..frozen.len { cond = slu_create_logic(bb, if dir { OP_OR } else { OP_AND }, cond, frozen[k]); }
    let br = create_inst(OP_CONDBR, T_VOID, [cond, if dir { unswitched } else { normal }, if dir { normal } else { unswitched }]);
    block_append_inst(bb, br);
    if has_w { inst_set_md(br, MDK_PROF, inst_get_md(prof_from, MDK_PROF)); }
    else { slu_set_unknown_weights_if_profiled(br); }
}

// rewritePHINodesForUnswitchedExitBlock(UnswitchedBB, OldExitingBB, OldPH)
fn rewrite_phis_for_unswitched_exit_block(ub: i32, old_exiting: i32, old_ph: i32) {
    var p = block_first(ub);
    while p >= 0 && iop(p) == OP_PHI {
        for k in nops(p) { phi_set_block(p, k, old_ph); }
        p = inst_next(p);
    }
}

// rewritePHINodesForExitAndUnswitchedBlocks(ExitBB, UnswitchedBB, OldExitingBB, OldPH, FullUnswitch)
fn rewrite_phis_for_exit_and_unswitched_blocks(exit: i32, ub: i32, old_exiting: i32, old_ph: i32, full: bool) {
    let ip = block_first(ub);
    var pn = block_first(exit);
    while pn >= 0 && iop(pn) == OP_PHI {
        let nx = inst_next(pn);
        let np = new_phi(vals[pn].ty, 2);
        inst_insert_before_head(np, ip);
        var nm: u8[>..] = [];
        nm.append(val_name(pn));
        nm.append(".split");
        set_name(np, nm);
        var i = nops(pn) - 1;
        while i >= 0 {
            if phi_block(pn, i) == old_exiting {
                let inc = phi_value(pn, i);
                if full { phi_remove_incoming(pn, i); }
                phi_add_incoming(np, inc, old_ph);
            }
            i--;
        }
        rauw(pn, np);
        phi_add_incoming(np, pn, exit);
        pn = nx;
    }
}

// hoistLoopToNewParent(L, Preheader, DT, LI, MSSAU, SE)
fn hoist_loop_to_new_parent(l: i32, ph: i32) {
    let fv = loops[l].fv;
    let old_parent = loop_parent(l);
    if old_parent < 0 { return; }
    var exits: i32[>..<] = [];
    loop_exit_blocks(l, exits);
    var np: i32 = -1;
    for e in exits {
        let el = li_loop_for(e);
        if el >= 0 && (np < 0 || loop_contains_loop(np, el)) { np = el; }
    }
    if np == old_parent { return; }
    li_change_loop_for(ph, np);
    loop_remove_child(old_parent, l);
    if np >= 0 { loop_add_child(np, l); } else { li_add_top_level_loop(fv, l); }
    var oc = old_parent;
    while oc != np {
        // erase_if(OldContainingL->getBlocksVector(), BB == Preheader || L.contains(BB))
        let r = loops[oc].blocks;
        var w: i64 = 0;
        for k in r.n {
            let x = lrun_get(r, k);
            if x == ph || loop_contains(l, x) { continue; }
            li_pool[r.at + w] = x;
            w++;
        }
        loops[oc].blocks.n = w as i32;
        let save = lcssa_se;
        lcssa_se = slu_se;
        form_lcssa(oc);
        lcssa_se = save;
        form_dedicated_exit_blocks(oc, true);
        oc = loop_parent(oc);
    }
}

// getTopMostExitingLoop(ExitBB, LI)
fn get_top_most_exiting_loop(exit: i32) -> i32 {
    var top = li_loop_for(exit);
    var cur = top;
    while cur >= 0 {
        if loop_is_exiting(cur, exit) { top = cur; }
        cur = loop_parent(cur);
    }
    return top;
}

// Loop::getUniqueLatchExitBlock
fn loop_unique_latch_exit_block(l: i32) -> i32 {
    let latch = loop_latch(l);
    if latch < 0 { return -1; }
    let t = block_terminator(latch);
    var r: i32 = -1;
    for k in term_nsucc(t) {
        let s = term_succ(t, k);
        if loop_contains(l, s) { continue; }
        if r >= 0 && r != s { return -1; }
        r = s;
    }
    return r;
}

fn slu_has_side_effects_or_convergent(i: i32) -> bool {
    if is_callbase(i) && call_has_fn_attr(i, AK_Convergent) { return true; }
    return inst_may_have_side_effects(i);
}

// SplitEdge / SplitBlock with the updater flag set
fn slu_split_edge(a: i32, b: i32) -> i32 { uu_mssau = slu_mssau; let r = lp_split_edge(a, b); uu_mssau = false; return r; }
// SplitBlock(BB, BB->begin(), ...): every caller passes begin(), an iterator with the head bit
fn slu_split_block(old: i32, at: i32) -> i32 { uu_mssau = slu_mssau; let r = lp_split_block_it(old, at, at == block_first(old)); uu_mssau = false; return r; }

// unswitchTrivialBranch(L, BI, DT, LI, SE, MSSAU)
fn unswitch_trivial_branch(l: i32, bi: i32) -> bool {
    let fv = slu_fv;
    var invs: i32[>..<] = [];
    var full = false;
    let cond = skip_trivial_select(op(bi, 0));
    if slu_invariant(l, cond) { invs.push(cond); full = true; }
    else {
        if is_inst(cond) { collect_homogenous_inst_graph_loop_invariants(l, cond, invs); }
        if invs.len == 0 { return false; }
    }
    var latch_idx: i64 = -1;
    let latch = loop_latch(l);
    let ulexit = loop_unique_latch_exit_block(l);
    if slu_se && full && ulexit >= 0 {
        if term_succ(bi, 0) == latch && loop_contains(l, term_succ(bi, 1)) { latch_idx = 0; }
        else if term_succ(bi, 1) == latch && loop_contains(l, term_succ(bi, 0)) { latch_idx = 1; }
    }
    var modified = false;
    if latch_idx >= 0 && are_loop_exit_phis_loop_invariant(l, latch, ulexit) {
        var bad = false;
        var i = block_first(latch);
        while i >= 0 { if slu_has_side_effects_or_convergent(i) { bad = true; } i = inst_next(i); }
        if !bad {
            let mbe = sc_get_constant_max_backedge_taken_count(l);
            if !sc_is_cnc(mbe) {
                var ups: DTUpdate[>..<] = [];
                ups.push(DTUpdate { kind: DT_DELETE, from: inst_parent(bi), to: term_succ(bi, latch_idx) });
                ups.push(DTUpdate { kind: DT_INSERT, from: inst_parent(bi), to: ulexit });
                block_remove_predecessor(latch, inst_parent(bi), false);
                term_set_succ(bi, latch_idx, ulexit);
                var p = block_first(ulexit);
                while p >= 0 && iop(p) == OP_PHI {
                    phi_add_incoming(p, phi_value_for_block(p, latch), inst_parent(bi));
                    p = inst_next(p);
                }
                if slu_mssau { msu_apply_updates(fv, ups, true); } else { dt_apply_updates(fv, DT_DOM, ups); }
                modified = true;
            }
        }
    }
    var exit_dir = true;
    var exit_idx: i64 = 0;
    var exit_bb = term_succ(bi, 0);
    if loop_contains(l, exit_bb) {
        exit_dir = false;
        exit_idx = 1;
        exit_bb = term_succ(bi, 1);
        if loop_contains(l, exit_bb) { return false; }
    }
    let cont = term_succ(bi, 1 - exit_idx);
    let parent = inst_parent(bi);
    if !modified && !are_loop_exit_phis_loop_invariant(l, parent, exit_bb) { return false; }
    if !full {
        if exit_dir { if !m_logical(cond, false) { return false; } }
        else { if !m_logical(cond, true) { return false; } }
    }
    if slu_se {
        let el = get_top_most_exiting_loop(exit_bb);
        if el >= 0 { sc_forget_loop(el); } else { sc_forget_topmost_loop(l); }
        sc_forget_block_and_loop_dispositions_all();
    }
    slu_verify_mssa();
    let old_ph = loop_preheader(l);
    let new_ph = slu_split_edge(old_ph, loop_header(l));
    var ub: i32 = -1;
    if full && cu_unique_pred(exit_bb) >= 0 { ub = exit_bb; }
    else { ub = slu_split_block(exit_bb, block_first(exit_bb)); }
    slu_verify_mssa();
    inst_erase_from_parent(block_terminator(old_ph));
    if full {
        inst_move_to_end(bi, old_ph);
        set_op(bi, 0, cond);
        if slu_mssau {
            let c = inst_clone(bi);
            block_append_inst(parent, c);
        } else {
            let nbi = create_inst(OP_BR, T_VOID, [cont]);
            block_append_inst(parent, nbi);
            let dl = inst_get_md(bi, 0);
            if dl >= 0 { inst_set_md(nbi, 0, dl); }
        }
        term_set_succ(bi, exit_idx, ub);
        term_set_succ(bi, 1 - exit_idx, new_ph);
    } else {
        build_partial_unswitch_conditional_branch(old_ph, invs, exit_dir, ub, new_ph, flag_bool("freeze-loop-unswitch-cond", true),
                                                  block_terminator(old_ph), bi);
    }
    dt_insert_edge(fv, DT_DOM, old_ph, ub);
    if slu_mssau {
        let ups: DTUpdate[1] = [DTUpdate { kind: DT_INSERT, from: old_ph, to: ub }];
        msu_apply_insert_updates(fv, ups);
    }
    if full {
        if slu_mssau {
            let term = block_terminator(parent);
            let nbi = create_inst(OP_BR, T_VOID, [cont]);
            block_append_inst(parent, nbi);
            let dl = inst_get_md(term, 0);
            if dl >= 0 { inst_set_md(nbi, 0, dl); }
            inst_erase_from_parent(term);
            msu_remove_edge(parent, exit_bb);
        }
        dt_delete_edge(fv, DT_DOM, parent, exit_bb);
    }
    slu_verify_mssa();
    if ub == exit_bb { rewrite_phis_for_unswitched_exit_block(ub, parent, old_ph); }
    else { rewrite_phis_for_exit_and_unswitched_blocks(exit_bb, ub, parent, old_ph, full); }
    let rep = if exit_dir { c_false() } else { c_true() };
    for inv in invs { replace_loop_invariant_uses(l, inv, rep); }
    if full { hoist_loop_to_new_parent(l, new_ph); }
    slu_verify_mssa();
    return true;
}

// SwitchInstProfUpdateWrapper state of one switch (two can be alive at once here)
struct SWW { has: bool, changed: bool }

// unswitchTrivialSwitch(L, SI, DT, LI, SE, MSSAU)
fn unswitch_trivial_switch(l: i32, si: i32) -> bool {
    let fv = slu_fv;
    let lc = op(si, 0);
    if !slu_invariant(l, lc) { return false; }
    let parent = inst_parent(si);
    fn trivially_unswitchable_exit(b: i32) -> bool {
        if loop_contains(l, b) { return false; }
        if !are_loop_exit_phis_loop_invariant(l, parent, b) { return false; }
        let ti = block_terminator(b);
        let unr = iop(ti) == OP_UNREACHABLE;
        return !unr || first_non_phi(b) != ti;
    }
    var exit_idx: i64[>..<] = [];
    for k in sw_ncases(si) { if trivially_unswitchable_exit(sw_case_dest(si, k)) { exit_idx.push(k); } }
    var default_exit: i32 = -1;
    // getSuccessorWeight(SI, 0)
    var ow: u64[>..<] = [];
    var ow_has = false;
    {
        let m = pd_prof(si);
        if pd_is_branch_weight_md(m) && pd_num_weights(m) == term_nsucc(si) { pd_extract_md(m, ow); ow_has = true; }
    }
    let dcw_has = ow_has;
    let dcw = if ow_has { ow[0] } else { 0 };
    if trivially_unswitchable_exit(sw_default(si)) { default_exit = sw_default(si); }
    else if exit_idx.len == 0 { return false; }
    slu_verify_mssa();
    var outer = l;
    if default_exit >= 0 {
        let el = get_top_most_exiting_loop(default_exit);
        if el < 0 || loop_contains_loop(el, outer) { outer = el; }
    }
    for k in exit_idx {
        let el = get_top_most_exiting_loop(sw_case_dest(si, k));
        if el < 0 || loop_contains_loop(el, outer) { outer = el; }
    }
    if slu_se {
        if outer >= 0 { sc_forget_loop(outer); } else { sc_forget_topmost_loop(l); }
    }
    if default_exit >= 0 { set_op(si, 1, -1); }
    // ExitCases: (value, block, has weight, weight), collected backwards
    var ec_v: i32[>..<] = [];
    var ec_b: i32[>..<] = [];
    var ec_h: bool[>..<] = [];
    var ec_w: u64[>..<] = [];
    var ow_changed = false;
    var e = exit_idx.len;
    while e > 0 {
        e--;
        let idx = exit_idx[e];
        ec_v.push(sw_case_val(si, idx));
        ec_b.push(sw_case_dest(si, idx));
        ec_h.push(ow_has);
        ec_w.push(if ow_has { ow[idx + 1] } else { 0 });
        // SIW.removeCase
        if ow_has { let last = ow.len - 1; ow[idx + 1] = ow[last]; ow.resize(last); ow_changed = true; }
        sw_remove_case_raw(si, idx);
    }
    var common: i32 = -1;
    let nc = sw_ncases(si);
    if nc > 0 {
        var all = true;
        for k in 1..nc { if sw_case_dest(si, k) != sw_case_dest(si, 0) { all = false; } }
        if all { common = sw_case_dest(si, 0); }
    }
    if default_exit < 0 {
        if nc == 0 { common = sw_default(si); }
        else if sw_default(si) != common { common = -1; }
    }
    let old_ph = loop_preheader(l);
    let new_ph = slu_split_edge(old_ph, loop_header(l));
    inst_erase_from_parent(block_terminator(old_ph));
    // SwitchInst::Create(LoopCond, NewPH, ExitCases.size(), OldPH)
    let nsi = new_inst(OP_SWITCH, T_VOID, 2 + 2 * ec_v.len);
    vals[nsi].nops = 2;
    set_op(nsi, 0, lc);
    set_op(nsi, 1, new_ph);
    block_append_inst(old_ph, nsi);
    let sdl = inst_get_md(si, 0);
    if sdl >= 0 { inst_set_md(nsi, 0, sdl); }
    var nw: u64[>..<] = [];
    var nw_has = false;
    var nw_changed = false;
    fn nsw_add_case(v: i32, d: i32, hw: bool, w: u64) {
        sw_add_case_raw(nsi, v, d);
        if !nw_has && hw && w != 0 {
            nw_changed = true;
            nw.clear();
            for k in term_nsucc(nsi) { nw.push(0); }
            nw[nw.len - 1] = w;
            nw_has = true;
        } else if nw_has {
            nw_changed = true;
            nw.push(if hw { w } else { 0 });
        }
    }
    fn nsw_set_weight(idx: i64, hw: bool, w: u64) {
        if !hw { return; }
        if !nw_has && w != 0 {
            nw.clear();
            for k in term_nsucc(nsi) { nw.push(0); }
            nw_has = true;
        }
        if nw_has && nw[idx] != w { nw[idx] = w; nw_changed = true; }
    }
    var unswitched_exits: i32[>..<] = [];
    var split_k: i32[>..<] = [];
    var split_v: i32[>..<] = [];
    if default_exit >= 0 {
        if pred_count(default_exit) == 0 {
            unswitched_exits.push(default_exit);
            rewrite_phis_for_unswitched_exit_block(default_exit, parent, old_ph);
        } else {
            let sb = slu_split_block(default_exit, block_first(default_exit));
            rewrite_phis_for_exit_and_unswitched_blocks(default_exit, sb, parent, old_ph, true);
            split_k.push(default_exit);
            split_v.push(sb);
            default_exit = sb;
        }
    }
    var j = ec_b.len;
    while j > 0 {
        j--;
        let eb = ec_b[j];
        if pred_count(eb) == 0 {
            if position(unswitched_exits, eb) < 0 {
                unswitched_exits.push(eb);
                rewrite_phis_for_unswitched_exit_block(eb, parent, old_ph);
            }
            continue;
        }
        let pk = position(split_k, eb);
        var sb: i32 = -1;
        if pk >= 0 { sb = split_v[pk]; }
        else {
            sb = slu_split_block(eb, block_first(eb));
            rewrite_phis_for_exit_and_unswitched_blocks(eb, sb, parent, old_ph, true);
            split_k.push(eb);
            split_v.push(sb);
        }
        ec_b[j] = sb;
    }
    j = ec_b.len;
    while j > 0 { j--; nsw_add_case(ec_v[j], ec_b[j], ec_h[j], ec_w[j]); }
    if default_exit >= 0 {
        set_op(nsi, 1, default_exit);
        nsw_set_weight(0, dcw_has, dcw);
        for k in sw_ncases(si) {
            nsw_add_case(sw_case_val(si, k), new_ph, ow_has, if ow_has { ow[k + 1] } else { 0 });
        }
    } else if dcw_has {
        var sw: u64 = dcw;
        for k in sw_ncases(si) { sw += ow[k + 1]; }
        nsw_set_weight(0, true, sw);
    }
    // ~NewSIW
    if nw_changed && nw_has {
        if nw.len >= 2 { pd_set(nsi, nw, false, false); } else { inst_erase_md(nsi, MDK_PROF); }
    }
    if common >= 0 {
        let bb = inst_parent(si);
        var skipped = default_exit < 0;
        for k in sw_ncases(si) {
            if !skipped { skipped = true; continue; }
            block_remove_predecessor(common, bb, true);
        }
        let nbi = create_inst(OP_BR, T_VOID, [common]);
        block_append_inst(bb, nbi);
        if sdl >= 0 { inst_set_md(nbi, 0, sdl); }
        inst_erase_from_parent(si);
    } else {
        if default_exit >= 0 {
            let last = sw_ncases(si) - 1;
            set_op(si, 1, sw_case_dest(si, last));
            // SIW.setSuccessorWeight(0, SIW.getSuccessorWeight(last + 1)); SIW.removeCase(last)
            if ow_has {
                let w = ow[last + 1];
                if ow[0] != w { ow[0] = w; ow_changed = true; }
                let li = ow.len - 1;
                ow[last + 1] = ow[li];
                ow.resize(li);
                ow_changed = true;
            }
            sw_remove_case_raw(si, last);
        }
        // ~SIW
        if ow_changed && ow_has {
            if ow.len >= 2 { pd_set(si, ow, false, false); } else { inst_erase_md(si, MDK_PROF); }
        }
    }
    var ups: DTUpdate[>..<] = [];
    for ue in unswitched_exits {
        ups.push(DTUpdate { kind: DT_DELETE, from: parent, to: ue });
        ups.push(DTUpdate { kind: DT_INSERT, from: old_ph, to: ue });
    }
    for k in split_k.len {
        ups.push(DTUpdate { kind: DT_DELETE, from: parent, to: split_k[k] });
        ups.push(DTUpdate { kind: DT_INSERT, from: old_ph, to: split_v[k] });
    }
    if slu_mssau { msu_apply_updates(fv, ups, true); slu_verify_mssa(); }
    else { dt_apply_updates(fv, DT_DOM, ups); }
    hoist_loop_to_new_parent(l, new_ph);
    slu_verify_mssa();
    return true;
}

// unswitchAllTrivialConditions(L, DT, LI, SE, MSSAU)
fn unswitch_all_trivial_conditions(l: i32) -> bool {
    var changed = false;
    var cur = loop_header(l);
    var visited: i32[>..<] = [];
    visited.push(cur);
    loop {
        if slu_mssau {
            let d = mb_dfirst(cur);
            if d >= 0 && (macc[d].kind != MAK_PHI || macc[d].dnext >= 0) { return changed; }
        }
        var i = block_first(cur);
        while i >= 0 { if slu_has_side_effects_or_convergent(i) { return changed; } i = inst_next(i); }
        let term = block_terminator(cur);
        if iop(term) == OP_SWITCH {
            if is_constant(op(term, 0)) { return changed; }
            if !unswitch_trivial_switch(l, term) { return changed; }
            changed = true;
            let t2 = block_terminator(cur);
            if iop(t2) != OP_BR { return changed; }
            cur = term_succ(t2, 0);
        } else {
            if iop(term) != OP_CONDBR { return changed; }
            if is_constant(skip_trivial_select(op(term, 0))) { return changed; }
            if !unswitch_trivial_branch(l, term) { return changed; }
            changed = true;
            let t2 = block_terminator(cur);
            if iop(t2) == OP_CONDBR { return changed; }
            cur = term_succ(t2, 0);
        }
        if !loop_contains(l, cur) || position(visited, cur) >= 0 { break; }
        visited.push(cur);
    }
    return changed;
}
