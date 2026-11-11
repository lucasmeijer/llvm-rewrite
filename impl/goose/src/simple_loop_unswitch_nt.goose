// SimpleLoopUnswitch, non-trivial unswitching and the pass. Port of
// llvm/lib/Transforms/Scalar/SimpleLoopUnswitch.cpp (postUnswitch, unswitchNontrivialInvariants,
// computeDomSubtreeCost, turnSelectIntoBranch, turnGuardIntoBranch, CalculateUnswitchCostMultiplier,
// collectUnswitchCandidates, canonicalizeForInvariantConditionInjection, shouldTryInjectInvariantCondition,
// shouldTryInjectBasingOnMetadata, injectPendingInvariantConditions, insertCandidatesWithPendingInjections,
// collectUnswitchCandidatesWithInjections, isSafeForNoNTrivialUnswitching, findBestNonTrivialUnswitchCandidate,
// shouldInsertFreeze, unswitchBestCondition, unswitchLoop, SimpleLoopUnswitchPass::run) and hasPartialIVCondition
// (llvm/lib/Transforms/Utils/LoopUtils.cpp).
//
// Not ported (fail loudly): injected invariant conditions whose candidates come from more than one compared value
// (LLVM iterates a DenseMap keyed by pointers there), key-instruction atoms in partially invariant clones.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_attrs;
import gen_iids;
import flags;
import analyses;
import pm;
import apint;
import memloc;
import aa;
import poison;
import vt;
import assume;
import local;
import instsimplify;
import domtree;
import dtu;
import loopinfo;
import loopsimplify;
import lcssa;
import cfgutil;
import simplifycfg;
import profdata;
import tti;
import mustexec;
import memoryssa;
import mssaupdater;
import scev;
import scev_update;
import lpm;
import value_mapper;
import clone_function;
import loop_md;
import loop_utils;
import unroll_utils;
import loop_unroll_pass;
import looprotate;
import simple_loop_unswitch;
import simple_loop_unswitch_ntc;

// NonTrivialUnswitchCandidate: invariants are runs in slu_cinv
struct SLUCand { ti: i32, inv_at: i64, inv_n: i64, has_cost: bool, cost: i64,
                 pending: bool, ppred: i64, plhs: i32, prhs: i32, psucc: i32 }
var slu_cinv: i32[>..<];
fn slu_cand_inv(c: SLUCand, k: i64) -> i32 { slu_cinv[c.inv_at + k] }

// IVConditionInfo
var piv_insts: i32[>..<];         // InstToDuplicate
var piv_known_true: bool = false; // KnownValue
var piv_path_is_noop: bool = true;
var piv_exit: i32 = -1;

fn slu_is_guard(i: i32) -> bool { is_inst(i) && inst_iid(i) == IID_experimental_guard }

// postUnswitch(L, U, LoopName, CurrentLoopValid, PartiallyInvariant, InjectedCondition, NewLoops)
fn post_unswitch(l: i32, valid: bool, partially: bool, injected: bool, new_loops: const i32[:]) {
    if new_loops.len > 0 { lpm_add_sibling_loops(new_loops); }
    if valid {
        if partially {
            let pf: const u8[:][1] = ["llvm.loop.unswitch.partial"];
            lmd_add_string_loop_attribute(l, "llvm.loop.unswitch.partial.disable", pf);
        } else if injected {
            let pf: const u8[:][1] = ["llvm.loop.unswitch.injection"];
            lmd_add_string_loop_attribute(l, "llvm.loop.unswitch.injection.disable", pf);
        } else {
            lpm_revisit_current_loop();
        }
    } else {
        lpm_mark_loop_as_deleted(l);
    }
}

// Loop::getUniqueExitBlocks
fn loop_unique_exit_blocks(l: i32, out: i32[>..<]&) {
    for k in loop_nblocks(l) {
        let t = block_terminator(loop_block(l, k));
        for j in term_nsucc(t) {
            let s = term_succ(t, j);
            if !loop_contains(l, s) && position(out, s) < 0 { out.push(s); }
        }
    }
}

// buildPartialInvariantUnswitchConditionalBranch(BB, ToDuplicate, Direction, UnswitchedSucc, NormalSucc, L,
// MSSAU, OriginalBranch)
fn build_partial_invariant_unswitch_conditional_branch(bb: i32, dup: const i32[:], dir: bool, unswitched: i32, normal: i32,
                                                       l: i32, orig_br: i32) {
    let vm = vmm_new();
    var k = dup.len;
    while k > 0 {
        k--;
        let inst = dup[k];
        let ni = inst_clone(inst);
        vmp_check_atom(inst);
        block_append_inst(bb, ni);
        remap_instruction(ni, vm, RF_NO_MODULE_LEVEL_CHANGES | RF_IGNORE_MISSING_LOCALS);
        vmm_set(vm, inst, ni);
        if !slu_mssau { continue; }
        let ma = mssa_access_of(inst);
        if ma >= 0 && macc[ma].kind == MAK_USE {
            var d = ma_def(ma);
            while loop_contains(l, macc[d].bb) && !mssa_is_live(d) {
                if macc[d].kind == MAK_PHI { d = mphi_value_for_block(d, loop_preheader(l)); }
                else { d = ma_def(d); }
            }
            msu_create_access_in_bb(ni, d, inst_parent(ni), MSP_BEFORE_TERMINATOR, true);
        }
    }
    let cond = vmm_get(vm, dup[0]);
    var prof: i32 = -1;
    if dup[0] == skip_trivial_select(op(orig_br, 0)) { prof = inst_get_md(orig_br, MDK_PROF); }
    let br = create_inst(OP_CONDBR, T_VOID, [cond, if dir { unswitched } else { normal }, if dir { normal } else { unswitched }]);
    block_append_inst(bb, br);
    if prof >= 0 { inst_set_md(br, MDK_PROF, prof); } else { slu_set_unknown_weights_if_profiled(br); }
}

// unswitchNontrivialInvariants(L, TI, Invariants, PartialIVInfo, DT, LI, AC, SE, MSSAU, LoopUpdater, InsertFreeze,
// InjectedCondition)
fn unswitch_nontrivial_invariants(l: i32, ti: i32, invs: const i32[:], insert_freeze: bool, injected: bool) {
    let fv = slu_fv;
    let parent_bb = inst_parent(ti);
    let is_br = iop(ti) == OP_CONDBR;
    let partially = piv_insts.len > 0;
    let full = !is_br || (skip_trivial_select(op(ti, 0)) == invs[0] && !partially);
    slu_verify_mssa();
    var dir = true;
    var cloned_succ: i64 = 0;
    if !full {
        let c = skip_trivial_select(op(ti, 0));
        if !m_logical(c, false) {
            if m_logical(c, true) || (partially && !piv_known_true) { dir = false; cloned_succ = 1; }
        }
    }
    let retained = if is_br { term_succ(ti, 1 - cloned_succ) } else { sw_default(ti) };
    var unswitched_succs: i32[>..<] = [];
    if is_br { unswitched_succs.push(term_succ(ti, cloned_succ)); }
    else {
        for k in sw_ncases(ti) {
            let d = sw_case_dest(ti, k);
            if d != retained && position(unswitched_succs, d) < 0 { unswitched_succs.push(d); }
        }
    }
    let parent_l = loop_parent(l);
    var lbrpo: i32[>..<] = [];
    if slu_mssau { loop_blocks_rpo(l, lbrpo); }
    var outer_exit = l;
    var exits: i32[>..<] = [];
    loop_unique_exit_blocks(l, exits);
    for eb in exits {
        let noe = get_top_most_exiting_loop(eb);
        if noe < 0 { outer_exit = -1; break; }
        if noe != outer_exit && loop_contains_loop(noe, outer_exit) { outer_exit = noe; }
    }
    if slu_se {
        if outer_exit >= 0 { sc_forget_loop(outer_exit); } else { sc_forget_topmost_loop(l); }
        sc_forget_block_and_loop_dispositions_all();
    }
    // DominatingSucc
    var ds_k: i32[>..<] = [];
    var ds_v: i32[>..<] = [];
    var succs_all: i32[>..<] = [];
    succs_all.push(retained);
    for s in unswitched_succs { succs_all.push(s); }
    for s in succs_all {
        var ok = cu_unique_pred(s) >= 0;
        if !ok {
            ok = true;
            each_pred(s) { p => if !(p == parent_bb || dt_dominates_block(DT_DOM, s, p)) { ok = false; } };
        }
        if !ok { continue; }
        // visitDomSubTree
        var wl: i32[>..<] = [];
        wl.push(s);
        while wl.len > 0 {
            let n = wl.pop();
            let j = position(ds_k, n);
            if j >= 0 { ds_v[j] = s; } else { ds_k.push(n); ds_v.push(s); }
            var c = dt_first_child(fv, DT_DOM, n);
            while c >= 0 { wl.push(c); c = dt_next_sibling(DT_DOM, c); }
        }
    }
    let split_bb = loop_preheader(l);
    let loop_ph = slu_split_edge(split_bb, loop_header(l));
    var dt_ups: DTUpdate[>..<] = [];
    var vms: i32[>..<] = [];
    var cph_k: i32[>..<] = [];
    var cph_v: i32[>..<] = [];
    for s in unswitched_succs {
        let vm = vmm_new();
        vms.push(vm);
        let cph = build_cloned_loop_blocks(l, loop_ph, exits, parent_bb, s, ds_k, ds_v, vm, dt_ups);
        cph_k.push(s);
        cph_v.push(cph);
    }
    fn cph_of(s: i32) -> i32 { return cph_v[position(cph_k, s)]; }
    let mdk_make_implicit: i32 = 14;
    if inst_get_md(ti, mdk_make_implicit) >= 0 {
        if flag_bool("simple-loop-unswitch-drop-non-trivial-implicit-null-checks", false) { inst_set_md(ti, mdk_make_implicit, -1); }
        else {
            lsi_compute(l);
            if !lsi_guaranteed_to_execute(ti, l) { inst_set_md(ti, mdk_make_implicit, -1); }
        }
    }
    inst_erase_from_parent(block_terminator(split_bb));
    if full {
        let nti = inst_clone(ti);
        block_append_inst(parent_bb, nti);
        inst_move_to_end(ti, split_bb);
        inst_set_md(ti, 0, -1);
        if is_br {
            let cph = cph_v[0];
            term_set_succ(ti, cloned_succ, cph);
            term_set_succ(ti, 1 - cloned_succ, loop_ph);
            var c = skip_trivial_select(op(ti, 0));
            if insert_freeze {
                var nm: u8[>..] = [];
                nm.append(val_name(c));
                nm.append(".fr");
                let fr = create_inst(OP_FREEZE, vals[c].ty, [c]);
                inst_insert_before(fr, ti);
                set_name(fr, nm);
                c = fr;
            }
            set_op(ti, 0, c);
            dt_ups.push(DTUpdate { kind: DT_INSERT, from: split_bb, to: cph });
        } else {
            set_op(ti, 1, loop_ph);
            for k in sw_ncases(ti) {
                if sw_case_dest(ti, k) == retained { set_op(ti, 3 + 2 * k, loop_ph); }
                else { set_op(ti, 3 + 2 * k, cph_of(sw_case_dest(ti, k))); }
            }
            if insert_freeze {
                let c = op(ti, 0);
                var nm: u8[>..] = [];
                nm.append(val_name(c));
                nm.append(".fr");
                let fr = create_inst(OP_FREEZE, vals[c].ty, [c]);
                inst_insert_before(fr, ti);
                set_name(fr, nm);
                set_op(ti, 0, fr);
            }
            for s in unswitched_succs { dt_ups.push(DTUpdate { kind: DT_INSERT, from: split_bb, to: cph_of(s) }); }
        }
        if slu_mssau {
            dt_apply_updates(fv, DT_DOM, dt_ups);
            dt_ups.clear();
            msu_remove_duplicate_phi_edges_between(parent_bb, retained);
            for s in unswitched_succs { msu_remove_duplicate_phi_edges_between(parent_bb, s); }
            for vm in vms { msu_update_for_cloned_loop(lbrpo, exits, vm, true); }
            msu_update_exit_blocks_for_cloned_loop(fv, exits, vms);
            for s in unswitched_succs { msu_remove_edge(parent_bb, s); }
        }
        if is_br {
            let us = unswitched_succs[0];
            block_remove_predecessor(us, parent_bb, true);
            dt_ups.push(DTUpdate { kind: DT_DELETE, from: parent_bb, to: us });
        } else {
            for k in sw_ncases(nti) { block_remove_predecessor(sw_case_dest(nti, k), parent_bb, true); }
            for s in unswitched_succs { dt_ups.push(DTUpdate { kind: DT_DELETE, from: parent_bb, to: s }); }
        }
        let nbi = create_inst(OP_BR, T_VOID, [retained]);
        block_append_inst(parent_bb, nbi);
        let dl = inst_get_md(nti, 0);
        if dl >= 0 { inst_set_md(nbi, 0, dl); }
        inst_erase_from_parent(nti);
    } else {
        let cph = cph_v[0];
        if partially {
            build_partial_invariant_unswitch_conditional_branch(split_bb, invs, dir, cph, loop_ph, l, ti);
        } else {
            build_partial_unswitch_conditional_branch(split_bb, invs, dir, cph, loop_ph, flag_bool("freeze-loop-unswitch-cond", true), ti, ti);
        }
        dt_ups.push(DTUpdate { kind: DT_INSERT, from: split_bb, to: cph });
        if slu_mssau {
            dt_apply_updates(fv, DT_DOM, dt_ups);
            dt_ups.clear();
            for vm in vms { msu_update_for_cloned_loop(lbrpo, exits, vm, true); }
            msu_update_exit_blocks_for_cloned_loop(fv, exits, vms);
        }
    }
    dt_apply_updates(fv, DT_DOM, dt_ups);
    delete_dead_cloned_blocks(l, exits, vms);
    var non_child: i32[>..<] = [];
    for vm in vms { build_cloned_loops(l, exits, vm, non_child); }
    delete_dead_blocks_from_loop(l, exits);
    slu_verify_mssa();
    var hoisted: i32[>..<] = [];
    let still = rebuild_loop_after_unswitch(l, exits, hoisted);
    slu_verify_mssa();
    if is_br && !partially {
        let cph = cph_v[0];
        let rep_unsw = full || invs.len == 1 || partially;
        let unsw_rep = if dir { c_true() } else { c_false() };
        let cont_rep = if dir { c_false() } else { c_true() };
        for inv in invs {
            var u = vals[inv].first_use;
            while u >= 0 {
                let nx = uses[u].next;
                let us = uses[u].user;
                if is_inst(us) {
                    let ub = inst_parent(us);
                    if dt_dominates_block(DT_DOM, loop_ph, ub) { use_set(u, cont_rep); }
                    else if rep_unsw && dt_dominates_block(DT_DOM, cph, ub) { use_set(u, unsw_rep); }
                }
                u = nx;
            }
        }
    }
    fn update_loop(ul: i32) {
        let save = lcssa_se;
        lcssa_se = slu_se;
        form_lcssa(ul);
        lcssa_se = save;
        form_dedicated_exit_blocks(ul, true);
    }
    for x in non_child { update_loop(x); if loop_is_outermost(x) { outer_exit = -1; } }
    for x in hoisted { update_loop(x); if loop_is_outermost(x) { outer_exit = -1; } }
    if still {
        update_loop(l);
        if loop_is_outermost(l) { outer_exit = -1; }
    }
    if outer_exit != l {
        var ol = parent_l;
        while ol != outer_exit { update_loop(ol); ol = loop_parent(ol); }
    }
    var sibs: i32[>..<] = [];
    for x in non_child { if loop_parent(x) == parent_l { sibs.push(x); } }
    for x in hoisted { if loop_parent(x) == parent_l { sibs.push(x); } }
    post_unswitch(l, still, partially, injected, sibs);
    slu_verify_mssa();
}

// computeDomSubtreeCost(N, BBCostMap, DTCostMap)
recursive fn compute_dom_subtree_cost(fv: i32, n: i32, bbc: HMap&, dtc: HMap&) -> i64 {
    if !hm_has(bbc, n as u64) { return 0; }
    if hm_has(dtc, n as u64) { return hm_get(dtc, n as u64, 0); }
    var cost = hm_get(bbc, n as u64, 0);
    var c = dt_first_child(fv, DT_DOM, n);
    while c >= 0 {
        cost = tc_add(cost, compute_dom_subtree_cost(fv, c, bbc, dtc));
        c = dt_next_sibling(DT_DOM, c);
    }
    hm_put(dtc, n as u64, cost);
    return cost;
}

// turnSelectIntoBranch(SI, DT, LI, MSSAU, AC)
fn turn_select_into_branch(si: i32) -> i32 {
    let fv = slu_fv;
    let head = inst_parent(si);
    let l = li_loop_for(head);
    dtu_begin(fv, true, false, false);
    let save = cu_dtu;
    cu_dtu = true;
    let prof = inst_get_md(si, MDK_PROF);
    let tterm = split_block_and_insert_if_then(op(si, 0), si, false, prof);
    cu_dtu = save;
    dtu_end();
    let then_bb = inst_parent(tterm);
    let cbr = block_terminator(head);
    let tail = term_succ(cbr, 1);
    if l >= 0 { loop_add_basic_block_to_loop(l, then_bb); loop_add_basic_block_to_loop(l, tail); }
    if slu_mssau { msu_move_all_after_splice_blocks(head, tail, si); }
    let phi = new_phi(vals[si].ty, 2);
    inst_insert_before(phi, si);
    set_name(phi, "unswitched.select");
    phi_add_incoming(phi, op(si, 1), then_bb);
    phi_add_incoming(phi, op(si, 2), head);
    let dl = inst_get_md(si, 0);
    if dl >= 0 { inst_set_md(phi, 0, dl); }
    ac_rauw(si, phi);
    rauw(si, phi);
    inst_erase_from_parent(si);
    slu_verify_mssa();
    return cbr;
}

// turnGuardIntoBranch(GI, L, DT, LI, MSSAU)
fn turn_guard_into_branch(gi: i32, l: i32) -> i32 {
    let fv = slu_fv;
    let check = inst_parent(gi);
    slu_verify_mssa();
    var w: i32 = -1;
    if flag_bool("simple-loop-unswitch-estimate-profile", true) { w = pd_create([1, 1048575], false); }
    dtu_begin(fv, true, false, false);
    let save = cu_dtu;
    cu_dtu = true;
    let dterm = split_block_and_insert_if_then(cb_arg(gi, 0), gi, true, w);
    cu_dtu = save;
    dtu_end();
    let cbi = block_terminator(check);
    let tail = term_succ(cbi, 1);
    if li_loop_for(check) >= 0 { loop_add_basic_block_to_loop(li_loop_for(check), tail); }
    // CondBrInst::swapSuccessors (swaps the profile too)
    let s0 = term_succ(cbi, 0);
    let s1 = term_succ(cbi, 1);
    term_set_succ(cbi, 0, s1);
    term_set_succ(cbi, 1, s0);
    var ws: u64[>..<] = [];
    if pd_extract(cbi, ws) && ws.len == 2 { let pm_ = inst_get_md(cbi, MDK_PROF); let ex = pd_has_origin(pm_); let t = ws[0]; ws[0] = ws[1]; ws[1] = t; pd_set(cbi, ws, ex, false); }
    let guarded = term_succ(cbi, 0);
    set_name(guarded, "guarded");
    set_name(term_succ(cbi, 1), "deopt");
    let deopt = term_succ(cbi, 1);
    if slu_mssau { msu_move_all_after_splice_blocks(check, guarded, gi); }
    inst_move_before(gi, dterm);
    set_op(gi, 0, c_false());
    if slu_mssau {
        let md = mssa_access_of(gi);
        msu_move_to_place(md, deopt, MSP_BEFORE_TERMINATOR);
        slu_verify_mssa();
    }
    return cbi;
}

// CalculateUnswitchCostMultiplier(TI, L, LI, DT, UnswitchCandidates)
fn calculate_unswitch_cost_multiplier(ti: i32, l: i32, cands: const SLUCand[:]) -> i64 {
    let fv = slu_fv;
    let latch = loop_latch(l);
    let cb = inst_parent(ti);
    let thr = flag_int("unswitch-threshold", 50);
    if dt_dominates_block(DT_DOM, cb, latch) {
        var in_loop: i64 = 0;
        var is_term = is_terminator(ti);
        if is_term { let t = ti; for k in term_nsucc(t) { if loop_contains(l, term_succ(t, k)) { in_loop++; } } }
        if slu_is_guard(ti) || (is_term && in_loop <= 1) { return 1; }
    }
    let pl = loop_parent(l);
    var plm: i64 = 1;
    if pl >= 0 { let d = loop_nblocks(pl) / flag_int("unswitch-parent-blocks-div", 8); plm = if d > 1 { d } else { 1 }; }
    let sib = if pl >= 0 { loop_nsubs(pl) } else { li_ntop(fv) };
    var clones: i64 = 0;
    for c in cands {
        let ci = c.ti;
        let cb2 = inst_parent(ci);
        let skip_exiting = dt_dominates_block(DT_DOM, cb2, latch);
        if iop(ci) == OP_SELECT { clones++; continue; }
        if slu_is_guard(ci) { if !skip_exiting { clones++; } continue; }
        var ne: i64 = 0;
        let t = block_terminator(cb2);
        for k in term_nsucc(t) { if !skip_exiting || loop_contains(l, term_succ(t, k)) { ne++; } }
        clones += slu_log2(ne);
    }
    var cp = clones - flag_int("unswitch-num-initial-unscaled-candidates", 8);
    if cp < 0 { cp = 0; }
    var sm = if pl >= 0 { sib } else { sib / flag_int("unswitch-siblings-toplevel-div", 2) };
    if sm < 1 { sm = 1; }
    if cp > slu_log2(thr) || sm > thr || plm > thr { return thr; }
    let m = sm * ((1 as i64) << cp);
    return if m < thr { m } else { thr };
}
// Log2_32 (floor; 0 -> -1 as unsigned 4294967295 in LLVM, never reached with n >= 1)
fn slu_log2(n: i64) -> i64 {
    if n <= 0 { return 4294967295; }
    var r: i64 = -1;
    var x = n;
    while x > 0 { r++; x = x >> 1; }
    return r;
}

// hasPartialIVCondition(L, MSSAThreshold, MSSA, AA)
fn has_partial_iv_condition(l: i32, thr: i64) -> bool {
    let ti = block_terminator(loop_header(l));
    if iop(ti) != OP_CONDBR { return false; }
    let ci = op(ti, 0);
    if !is_inst(ci) || !(iop(ci) == OP_ICMP || iop(ci) == OP_FCMP || iop(ci) == OP_TRUNC) || !loop_contains(l, inst_parent(ci)) { return false; }
    var dup: i32[>..<] = [];
    dup.push(ci);
    var wl: i32[>..<] = [];
    for k in nops(ci) { wl.push(op(ci, k)); }
    var acc: i32[>..<] = [];
    var locs: ML[>..<] = [];
    while wl.len > 0 {
        let i = wl.pop();
        if !is_inst(i) || !loop_contains(l, inst_parent(i)) { continue; }
        if iop(i) != OP_LOAD && iop(i) != OP_GEP { return false; }
        if iop(i) == OP_LOAD && ((insts[inst_of(i)].bits & 1) != 0 || insts[inst_of(i)].ord != 0) { return false; }
        dup.push(i);
        let ma = mssa_access_of(i);
        if ma >= 0 {
            if macc[ma].kind == MAK_USE { acc.push(ma_def(ma)); locs.push(ml_get(i)); }
            else { return false; }
        }
        for k in nops(i) { wl.push(op(i, k)); }
    }
    if dup.len == 0 { return false; }
    var exiting: i32[>..<] = [];
    loop_exiting_blocks(l, exiting);
    fn no_clobbers_on_path(succ: i32, header: i32) -> bool {
        piv_path_is_noop = true;
        piv_exit = -1;
        var bwl: i32[>..<] = [];
        bwl.push(succ);
        bwl.push(header);
        var seen: i32[>..<] = [];
        seen.push(header);
        var i = block_first(header);
        while i >= 0 { if inst_may_have_side_effects(i) { piv_path_is_noop = false; } i = inst_next(i); }
        while bwl.len > 0 {
            let cur = bwl.pop();
            if !loop_contains(l, cur) { continue; }
            if position(seen, cur) >= 0 { continue; }
            seen.push(cur);
            var x = block_first(cur);
            var ok = true;
            while x >= 0 { if inst_may_have_side_effects(x) { ok = false; } x = inst_next(x); }
            if !ok { piv_path_is_noop = false; }
            let t = block_terminator(cur);
            for k in term_nsucc(t) { bwl.push(term_succ(t, k)); }
        }
        if seen.len < 2 { return false; }
        var seen_acc: i32[>..<] = [];
        var awl: i32[>..<] = [];
        for a in acc { awl.push(a); }
        while awl.len > 0 {
            let cur = awl.pop();
            if position(seen_acc, cur) >= 0 { continue; }
            seen_acc.push(cur);
            if position(seen, macc[cur].bb) < 0 { continue; }
            if seen_acc.len >= thr { return false; }
            if macc[cur].kind == MAK_USE { continue; }
            if macc[cur].kind == MAK_DEF {
                for loc in locs {
                    if mr_is_mod(aa_inst_loc_mr_simple(macc[cur].inst, loc)) { return false; }
                }
            }
            var u = mssa_first_use(cur);
            while u >= 0 { awl.push(mssa_use_user(u)); u = mssa_use_next(u); }
        }
        let fvv = block_func(header);
        let must = func_has_fn_attr(fvv, AK_MustProgress) || lmd_bool(l, "llvm.loop.mustprogress");
        piv_path_is_noop = piv_path_is_noop && must;
        if piv_path_is_noop {
            for eb in exiting {
                if position(seen, eb) < 0 { continue; }
                let t = block_terminator(eb);
                for k in term_nsucc(t) {
                    let s = term_succ(t, k);
                    if loop_contains(l, s) { continue; }
                    piv_path_is_noop = piv_path_is_noop && iop(block_first(s)) != OP_PHI && (piv_exit < 0 || piv_exit == s);
                    if !piv_path_is_noop { break; }
                    piv_exit = s;
                }
            }
        }
        if piv_exit < 0 { piv_path_is_noop = false; }
        piv_insts.clear();
        for d in dup { piv_insts.push(d); }
        return true;
    }
    if term_succ(ti, 0) == term_succ(ti, 1) { return false; }
    if no_clobbers_on_path(term_succ(ti, 0), loop_header(l)) { piv_known_true = true; return true; }
    if no_clobbers_on_path(term_succ(ti, 1), loop_header(l)) { piv_known_true = false; return true; }
    return false;
}

// collectUnswitchCandidates
fn collect_unswitch_candidates(cands: SLUCand[>..<]&, l: i32) -> i32 {
    var piv_branch: i32 = -1;
    fn push_cand(i: i32, invs: const i32[:]) {
        let at = slu_cinv.len;
        for v in invs { slu_cinv.push(v); }
        cands.push(SLUCand { ti: i, inv_at: at, inv_n: invs.len, has_cost: false, cost: 0, pending: false, ppred: 0, plhs: -1, prhs: -1, psucc: -1 });
    }
    fn add_for_inst(i: i32, c0: i32) {
        let c = skip_trivial_select(c0);
        if is_constant(c) { return; }
        if slu_invariant(l, c) { push_cand(i, [c]); return; }
        if m_logical(c, true) || m_logical(c, false) {
            var invs: i32[>..<] = [];
            collect_homogenous_inst_graph_loop_invariants(l, c, invs);
            if invs.len > 0 { push_cand(i, invs); }
        }
    }
    var collect_guards = false;
    if flag_bool("simple-loop-unswitch-guards", true) {
        let gd = sc_guard_decl_in(slu_fv);
        if gd >= 0 && vals[gd].first_use >= 0 { collect_guards = true; }
    }
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        if li_loop_for(bb) != l { continue; }
        var i = block_first(bb);
        while i >= 0 {
            if iop(i) == OP_SELECT {
                let c = op(i, 0);
                if vals[c].ty == T_I1 && vals[i].ty != T_I1 { add_for_inst(i, c); }
            } else if collect_guards && slu_is_guard(i) {
                let c = skip_trivial_select(cb_arg(i, 0));
                if !is_constant(c) && slu_invariant(l, c) { push_cand(i, [c]); }
            }
            i = inst_next(i);
        }
        let t = block_terminator(bb);
        if iop(t) == OP_SWITCH {
            if !is_constant(op(t, 0)) && slu_invariant(l, op(t, 0)) && cu_unique_succ(bb) < 0 { push_cand(t, [op(t, 0)]); }
            continue;
        }
        if iop(t) != OP_CONDBR || term_succ(t, 0) == term_succ(t, 1) { continue; }
        add_for_inst(t, op(t, 0));
    }
    if slu_mssau && lmd_find(l, "llvm.loop.unswitch.partial.disable") < 0 {
        let ht = block_terminator(loop_header(l));
        var any = false;
        for c in cands { if c.ti == ht { any = true; } }
        if !any && has_partial_iv_condition(l, flag_int("simple-loop-unswitch-memoryssa-threshold", 100) & 0xFFFFFFFF) {
            piv_branch = ht;
            push_cand(ht, piv_insts);
        }
    }
    return piv_branch;
}

// collectUnswitchCandidatesWithInjections
fn collect_unswitch_candidates_with_injections(cands: SLUCand[>..<]&, l: i32) -> bool {
    if !flag_bool("simple-loop-unswitch-inject-invariant-conditions", true) { return false; }
    if !dt_has_node(DT_DOM, loop_header(l)) { return false; }
    let latch = loop_latch(l);
    if latch < 0 { return false; }
    // CandidatesULT: key -> list of (term, invariant, in-loop succ)
    var ck: i32[>..<] = [];
    var ct: i32[>..<] = [];
    var ci: i32[>..<] = [];
    var cs: i32[>..<] = [];
    var bb = latch;
    while bb >= 0 && loop_contains(l, bb) {
        let cur = bb;
        bb = dt_idom(DT_DOM, bb);
        if li_loop_for(cur) != l { continue; }
        let term = block_terminator(cur);
        if iop(term) != OP_CONDBR || !is_inst_op(op(term, 0), OP_ICMP) { continue; }
        let cmp = op(term, 0);
        var lhs = op(cmp, 0);
        var rhs = op(cmp, 1);
        var p = insts[inst_of(cmp)].pred as i64;
        var it = term_succ(term, 0);
        var iff = term_succ(term, 1);
        if !ty_is_int(vals[lhs].ty) { continue; }
        // canonicalizeForInvariantConditionInjection
        if !loop_contains(l, it) { p = cmp_inverse_pred(p); let t = it; it = iff; iff = t; }
        if slu_invariant(l, lhs) { p = slu_swapped_pred(p); let t = lhs; lhs = rhs; rhs = t; }
        if p == 39 && is_constant(rhs) && is_null_value(rhs) {
            p = 36;
            rhs = ap_to_cint(vals[rhs].ty, ap_smin_val(ty_bits(vals[rhs].ty)));
        }
        // shouldTryInjectInvariantCondition
        if slu_invariant(l, lhs) || !slu_invariant(l, rhs) { continue; }
        if p != 36 { continue; }
        if !loop_contains(l, it) || loop_contains(l, iff) { continue; }
        if loop_header(l) == it { continue; }
        if !should_try_inject_basing_on_metadata(term, it) { continue; }
        var key = lhs;
        while is_inst_op(key, OP_ZEXT) { key = op(key, 0); }
        ck.push(key); ct.push(term); ci.push(rhs); cs.push(it);
    }
    var keys: i32[>..<] = [];
    for k in ck { if position(keys, k) < 0 { keys.push(k); } }
    var found = false;
    var multi = 0;
    for key in keys {
        var n = 0;
        for k in ck { if k == key { n++; } }
        if n >= 2 { multi++; }
    }
    if multi > 1 { slu_not_ported("injected invariant conditions for several compared values (DenseMap iteration order)"); }
    for key in keys {
        var idx: i64[>..<] = [];
        for k in ck.len { if ck[k] == key { idx.push(k); } }
        if idx.len < 2 { continue; }
        // insertCandidatesWithPendingInjections(..., ICMP_ULT, Compares): NonStrictPred = ule
        for j in 0..idx.len - 1 {
            let prev = idx[j];
            let next = idx[j + 1];
            let at = slu_cinv.len;
            slu_cinv.push(ci[next]);
            slu_cinv.push(ci[prev]);
            cands.push(SLUCand { ti: ct[prev], inv_at: at, inv_n: 2, has_cost: false, cost: 0, pending: true, ppred: 37,
                                 plhs: ci[next], prhs: ci[prev], psucc: cs[prev] });
        }
        found = true;
    }
    return found;
}
fn slu_swapped_pred(p: i64) -> i64 {
    if p == 32 || p == 33 { return p; }
    if p == 34 { return 36; } if p == 36 { return 34; }
    if p == 35 { return 37; } if p == 37 { return 35; }
    if p == 38 { return 40; } if p == 40 { return 38; }
    if p == 39 { return 41; } if p == 41 { return 39; }
    return p;
}

// shouldTryInjectBasingOnMetadata(BI, TakenSucc)
fn should_try_inject_basing_on_metadata(bi: i32, taken: i32) -> bool {
    var ws: u64[>..<] = [];
    if !pd_extract(bi, ws) { return false; }
    let t = flag_int("simple-loop-unswitch-inject-invariant-condition-hotness-threshold", 16) & 0xFFFFFFFF;
    let likely = bp_from_ratio((t - 1) as u64, t as u64);
    let idx: i64 = if term_succ(bi, 0) == taken { 0 } else { 1 };
    let num = ws[idx] & 0xFFFFFFFF;
    let den = (ws[0] + ws[1]) & 0xFFFFFFFF;
    if den == 0 || num > den { return false; }
    let actual = bp_from_ratio(num, den);
    if likely > actual { return false; }
    return true;
}

// injectPendingInvariantConditions(Candidate, L, DT, LI, AC, MSSAU)
fn inject_pending_invariant_conditions(c: SLUCand, l: i32) -> SLUCand {
    let fv = slu_fv;
    let ph = loop_preheader(l);
    var lhs = c.plhs;
    var rhs = c.prhs;
    let in_succ = c.psucc;
    let ti = c.ti;
    let bb = inst_parent(ti);
    let out_succ = if in_succ == term_succ(ti, 0) { term_succ(ti, 1) } else { term_succ(ti, 0) };
    let pt = block_terminator(ph);
    let pdl = inst_get_md(pt, 0);
    if vals[lhs].ty != vals[rhs].ty {
        if ty_bits(vals[lhs].ty) < ty_bits(vals[rhs].ty) {
            var nm: u8[>..] = []; nm.append(val_name(lhs)); nm.append(".wide");
            lhs = slu_zext_before(lhs, vals[rhs].ty, nm, pt, pdl);
        } else {
            var nm: u8[>..] = []; nm.append(val_name(rhs)); nm.append(".wide");
            rhs = slu_zext_before(rhs, vals[lhs].ty, nm, pt, pdl);
        }
    }
    let ic = create_inst(OP_ICMP, cmp_result_ty(vals[lhs].ty), [lhs, rhs]);
    insts[inst_of(ic)].pred = c.ppred as u8;
    inst_insert_before(ic, pt);
    set_name(ic, "injected.cond");
    var cn: u8[>..] = [];
    cn.append(val_name(bb));
    cn.append(".check");
    let check = create_block_before(fv, in_succ, cn);
    let ibr = create_inst(OP_CONDBR, T_VOID, [ic, in_succ, check]);
    inst_insert_before(ibr, ti);
    let tdl = inst_get_md(ti, 0);
    if tdl >= 0 { inst_set_md(ibr, 0, tdl); }
    slu_set_unknown_weights_if_profiled(ibr);
    let cbr = create_inst(OP_CONDBR, T_VOID, [op(ti, 0), term_succ(ti, 0), term_succ(ti, 1)]);
    block_append_inst(check, cbr);
    if tdl >= 0 { inst_set_md(cbr, 0, tdl); }
    let tprof = inst_get_md(ti, MDK_PROF);
    if tprof >= 0 { inst_set_md(cbr, MDK_PROF, tprof); }
    inst_erase_from_parent(ti);
    var p = block_first(in_succ);
    while p >= 0 && iop(p) == OP_PHI { phi_add_incoming(p, phi_value_for_block(p, bb), check); p = inst_next(p); }
    block_replace_phi_uses_with(out_succ, bb, check);
    var ups: DTUpdate[>..<] = [];
    ups.push(DTUpdate { kind: DT_INSERT, from: bb, to: check });
    ups.push(DTUpdate { kind: DT_INSERT, from: check, to: in_succ });
    ups.push(DTUpdate { kind: DT_INSERT, from: check, to: out_succ });
    ups.push(DTUpdate { kind: DT_DELETE, from: bb, to: out_succ });
    dt_apply_updates(fv, DT_DOM, ups);
    if slu_mssau { msu_apply_updates(fv, ups, false); }
    loop_add_basic_block_to_loop(l, check);
    let at = slu_cinv.len;
    slu_cinv.push(ic);
    return SLUCand { ti: ibr, inv_at: at, inv_n: 1, has_cost: c.has_cost, cost: c.cost, pending: false, ppred: 0, plhs: -1, prhs: -1, psucc: -1 };
}
// Builder.CreateZExt(V, Ty, Name) before `before` (ConstantFolder)
fn slu_zext_before(v: i32, ty: i32, name: const u8[:], before: i32, dl: i32) -> i32 {
    if is_constant(v) { return ce_cast(OP_ZEXT, v, ty); }
    let z = create_inst(OP_ZEXT, ty, [v]);
    inst_insert_before(z, before);
    set_name(z, name);
    if dl >= 0 { inst_set_md(z, 0, dl); }
    return z;
}

// isSafeForNoNTrivialUnswitching(L, LI)
fn is_safe_for_nontrivial_unswitching(l: i32) -> bool {
    if !loop_is_safe_to_clone(l) { return false; }
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        var i = block_first(bb);
        while i >= 0 {
            if vals[i].ty == T_TOKEN && lr_used_outside_block(i, bb) { return false; }
            if is_callbase(i) && call_has_fn_attr(i, AK_Convergent) { return false; }
            i = inst_next(i);
        }
    }
    var rpo: i32[>..<] = [];
    lu_loop_rpo(l, rpo);
    if lu_contains_irreducible(rpo) { return false; }
    var exits: i32[>..<] = [];
    loop_unique_exit_blocks(l, exits);
    for e in exits {
        let f = first_non_phi(e);
        if iop(f) == OP_CLEANUPPAD || iop(f) == OP_CATCHSWITCH { return false; }
    }
    return true;
}

// findBestNonTrivialUnswitchCandidate
fn find_best_nontrivial_unswitch_candidate(cands: SLUCand[>..<]&, l: i32) -> i64 {
    let fv = slu_fv;
    cm_collect_ephemeral_values(l);
    var bbc = hm_new();
    let kind = if func_has_fn_attr(fv, AK_MinSize) { TCK_CODE_SIZE } else { TCK_SIZE_AND_LATENCY };
    var loop_cost: i64 = 0;
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        var cost: i64 = 0;
        var i = block_first(bb);
        while i >= 0 {
            if !cm_is_eph(i) { cost = tc_add(cost, tti_instruction_cost(i, kind)); }
            i = inst_next(i);
        }
        loop_cost = tc_add(loop_cost, cost);
        hm_put(bbc, bb as u64, cost);
    }
    var dtc = hm_new();
    fn unswitched_cost(ti: i32, full: bool) -> i64 {
        if iop(ti) == OP_SELECT { return loop_cost; }
        let bb = inst_parent(ti);
        var visited: i32[>..<] = [];
        var cost: i64 = 0;
        let t = block_terminator(bb);
        for k in term_nsucc(t) {
            let s = term_succ(t, k);
            if position(visited, s) >= 0 { continue; }
            visited.push(s);
            if !full {
                let c = skip_trivial_select(op(ti, 0));
                if m_logical(c, true) { if s == term_succ(ti, 1) { continue; } }
                else if m_logical(c, false) { if s == term_succ(ti, 0) { continue; } }
                else if (piv_known_true && s == term_succ(ti, 0)) || (!piv_known_true && s == term_succ(ti, 1)) { continue; }
            }
            var ok = cu_unique_pred(s) >= 0;
            if !ok {
                ok = true;
                each_pred(s) { p => if !(p == bb || dt_dominates_block(DT_DOM, s, p)) { ok = false; } };
            }
            if ok { cost = tc_add(cost, compute_dom_subtree_cost(fv, s, bbc, dtc)); }
        }
        let sc: i64 = if slu_is_guard(ti) { 2 } else { visited.len };
        return tc_mul(loop_cost - cost, sc - 1);
    }
    var best: i64 = -1;
    for k in cands.len {
        let ti = cands[k].ti;
        let is_br = iop(ti) == OP_CONDBR;
        let full = !is_br || cands[k].pending || (cands[k].inv_n == 1 && slu_cand_inv(cands[k], 0) == skip_trivial_select(op(ti, 0)));
        var cc = unswitched_cost(ti, full);
        if flag_bool("enable-unswitch-cost-multiplier", true) {
            let m = calculate_unswitch_cost_multiplier(ti, l, cands);
            cc = tc_mul(cc, m);
        }
        if best < 0 || cc < cands[best].cost {
            best = k;
            cands[k].cost = cc;
            cands[k].has_cost = true;
        }
    }
    return best;
}

// shouldInsertFreeze(L, TI, DT, AC)
fn should_insert_freeze(l: i32, ti: i32) -> bool {
    if !flag_bool("freeze-loop-unswitch-cond", true) { return false; }
    lsi_compute(l);
    if lsi_guaranteed_to_execute(ti, l) { return false; }
    let c = skip_trivial_select(op(ti, 0));
    return !is_guaranteed_not_to_be_undef_or_poison(c, block_terminator(loop_preheader(l)), 0);
}

// unswitchBestCondition
fn unswitch_best_condition(l: i32) -> bool {
    var cands: SLUCand[>..<] = [];
    slu_cinv.clear();
    piv_insts.clear();
    let piv_branch = collect_unswitch_candidates(cands, l);
    if lmd_find(l, "llvm.loop.unswitch.injection.disable") < 0 { collect_unswitch_candidates_with_injections(cands, l); }
    if cands.len == 0 { return false; }
    let bi = find_best_nontrivial_unswitch_candidate(cands, l);
    var best = cands[bi];
    if best.cost >= flag_int("unswitch-threshold", 50) { return false; }
    var injected = false;
    if best.pending { best = inject_pending_invariant_conditions(best, l); injected = true; }
    if best.ti != piv_branch { piv_insts.clear(); }
    var insert_freeze = false;
    if iop(best.ti) == OP_SELECT {
        insert_freeze = !is_guaranteed_not_to_be_undef_or_poison(op(best.ti, 0), block_terminator(loop_preheader(l)), 0);
        best.ti = turn_select_into_branch(best.ti);
    } else {
        if slu_is_guard(best.ti) { best.ti = turn_guard_into_branch(best.ti, l); }
        insert_freeze = should_insert_freeze(l, best.ti);
    }
    var invs: i32[>..<] = [];
    for k in best.inv_n { invs.push(slu_cand_inv(best, k)); }
    unswitch_nontrivial_invariants(l, best.ti, invs, insert_freeze, injected);
    return true;
}

// unswitchLoop(L, DT, LI, AC, AA, TTI, Trivial, NonTrivial, SE, MSSAU, LoopUpdater)
fn unswitch_loop(l: i32, trivial: bool, nontrivial: bool) -> bool {
    if !loop_is_simplify_form(l) { return false; }
    if trivial && unswitch_all_trivial_conditions(l) {
        post_unswitch(l, true, false, false, []);
        return true;
    }
    let fv = slu_fv;
    let cont = flag_bool("enable-nontrivial-unswitch", false) || nontrivial;
    if !cont { return false; }
    if func_has_fn_attr(fv, AK_OptimizeForSize) || func_has_fn_attr(fv, AK_MinSize) { return false; }
    if !is_safe_for_nontrivial_unswitching(l) { return false; }
    return unswitch_best_condition(l);
}

// SimpleLoopUnswitchPass::run: arg bit 0 = NonTrivial, bit 1 = Trivial
fn simple_loop_unswitch_pass_run(l: i32, nontrivial: bool, trivial: bool, use_mssa: bool) -> u32 {
    let fv = block_func(loop_header(l));
    slu_fv = fv;
    tli_cur_fn = fv;
    tti_init_function(fv, globs[glob_of(fv)].module);
    slu_mssau = use_mssa;
    slu_se = scev_valid(fv);
    ls_mssau = use_mssa;
    if use_mssa {
        msu_reset();
        if flag_bool("verify-memoryssa", false) { mssa_verify(fv); }
    }
    let vm = vmm_mark();
    let changed = unswitch_loop(l, trivial, nontrivial);
    vmm_release(vm);
    slu_mssau = false;
    ls_mssau = false;
    if !changed { return PA_ALL; }
    if use_mssa && flag_bool("verify-memoryssa", false) { mssa_verify(fv); }
    var pa = ((1 as u32) << A_DOMTREE) | ((1 as u32) << A_LOOPS) | ((1 as u32) << A_SCEV);
    if use_mssa { pa |= (1 as u32) << A_MEMORYSSA; }
    return pa;
}
