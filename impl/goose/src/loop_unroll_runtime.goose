// Runtime unrolling: port of llvm/lib/Transforms/Utils/LoopUnrollRuntime.cpp (ConnectProlog,
// probOfNextInRemainder, ConnectEpilog, CloneLoopBlocks, canProfitablyRuntimeUnrollMultiExitLoop,
// CreateTripRemainder, UnrollRuntimeLoopRemainder), with breakLoopBackedge and getBranchProbability(Src, Dst)
// (llvm/lib/Transforms/Utils/LoopUtils.cpp) and BasicBlock::getPostdominatingDeoptimizeCall.
//
// UnrollRuntimeLoopRemainder ends by unrolling the remainder loop (-unroll-remainder): that call is made by
// the caller (unroll_loop in loop_unroll.goose), which is what runs right after it in LLVM too.
// The IRBuilder<> (ConstantFolder) is ur_*: instructions go before an instruction (adopting its debug
// records) and take its debug location.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_iids;
import flags;
import apint;
import pm;
import constfold;
import cfold;
import local;
import instsimplify;
import vt;
import poison;
import assume;
import autoupgrade;
import domtree;
import dtu;
import loopinfo;
import loopsimplify;
import lcssa;
import cfgutil;
import profdata;
import tti;
import scev;
import scev_create;
import scev_btc;
import scev_update;
import scev_expander;
import value_mapper;
import clone_function;
import loop_md;
import unroll_utils;

fn urt_not_ported(what: const u8[:]) { fatal(str("LoopUnroll (runtime): ", what, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// IRBuilder<> (ConstantFolder)

var ur_pos: i32 = -1;       // insert before this instruction
var ur_head: bool = false;
var ur_dl: i32 = -1;
fn ur_set(i: i32) { ur_pos = i; ur_head = false; ur_dl = inst_get_md(i, 0); }
fn ur_set_head(i: i32) { ur_pos = i; ur_head = true; ur_dl = inst_get_md(i, 0); }
fn ur_insert(iv: i32, name: const u8[:]) -> i32 {
    if ur_head { inst_insert_before_head(iv, ur_pos); } else { inst_insert_before(iv, ur_pos); }
    if name.len > 0 && vals[iv].ty != T_VOID { set_name(iv, name); }
    if ur_dl >= 0 { inst_set_md(iv, 0, ur_dl); }
    return iv;
}
fn ur_binop(o: i64, a: i32, b: i32, name: const u8[:]) -> i32 {
    if is_constant(a) && is_constant(b) {
        let r = if is_desirable_binop(o) { ce_binop(o, a, b, 0) } else { cf_binop(o, a, b) };
        if r >= 0 { return r; }
    }
    return ur_insert(create_inst(o, vals[a].ty, [a, b]), name);
}
fn ur_icmp(p: i64, a: i32, b: i32, name: const u8[:]) -> i32 {
    if is_constant(a) && is_constant(b) {
        let r = cf_fold_cmp_operands(p, a, b, -1);
        if r >= 0 { return r; }
    }
    let c = create_inst(OP_ICMP, cmp_result_ty(vals[a].ty), [a, b]);
    insts[inst_of(c)].pred = p as u8;
    return ur_insert(c, name);
}
fn ur_condbr(c: i32, t: i32, f: i32, ws: const u64[:]) -> i32 {
    let br = create_inst(OP_CONDBR, T_VOID, [c, t, f]);
    if ws.len > 0 { inst_set_md(br, MDK_PROF, pd_create(ws, false)); }
    return ur_insert(br, "");
}

// hasBranchWeightMD
fn has_branch_weight_md(i: i32) -> bool { pd_is_branch_weight_md(inst_get_md(i, MDK_PROF)) }

// ---------------------------------------------------------------------------------------------

// probOfNextInRemainder(OriginalLoopProb, N)
fn prob_of_next_in_remainder(p: u32, n: i64) -> u32 {
    if p == (BP_D as u32) { return p; }
    let too_many = bp_pow(p, n + 1);
    let not_too_many = bp_compl(too_many);
    let one_not_too_many = if p >= too_many { p - too_many } else { 0 };
    // BranchProbability::operator/(BranchProbability)
    return bp_from_ratio(one_not_too_many as u64, not_too_many as u64);
}

// getBranchProbability(Src, Dst)
fn lmd_branch_probability_edge(src: i32, dst: i32) -> u32 {
    let t = block_terminator(src);
    if t < 0 || term_nsucc(t) == 0 { return 0; }
    var ws: u64[>..<] = [];
    if !pd_extract(t, ws) { return 0xFFFFFFFF; }
    var total: u64 = 0;
    var num: u64 = 0;
    for k in ws.len {
        if term_succ(t, k) == dst { num = (num + ws[k]) & 0xFFFFFFFF; }
        total += ws[k];
    }
    if total == 0 || total > 0xFFFFFFFF { return 0xFFFFFFFF; }
    return bp_from_ratio(num, total);
}
// BasicBlock::getPostdominatingDeoptimizeCall
fn postdominating_deoptimize_call(bb0: i32) -> i32 {
    var bb = bb0;
    var visited: i32[>..<] = [];
    visited.push(bb);
    loop {
        let s = cu_unique_succ(bb);
        if s < 0 { break; }
        if position(visited, s) >= 0 { return -1; }
        visited.push(s);
        bb = s;
    }
    return cu_terminating_deoptimize_call(bb);
}

// ConnectProlog
fn connect_prolog(l: i32, be_count: i32, count: i64, prolog_exit: i32, latch_exit: i32, ph: i32, nph: i32, vm: i32, preserve_lcssa: bool) {
    let latch = loop_latch(l);
    let prolog_latch = vmm_get(vm, latch);
    let lt = block_terminator(latch);
    var succs: i32[>..<] = [];
    for k in term_nsucc(lt) { succs.push(term_succ(lt, k)); }
    for s in succs {
        var pn = block_first(s);
        while pn >= 0 && iop(pn) == OP_PHI {
            let np = new_phi(vals[pn].ty, 2);
            inst_insert_before_head(np, first_non_phi(prolog_exit));
            var nm: u8[>..] = [];
            nm.append(val_name(pn));
            nm.append(".unr");
            set_name(np, nm);
            let in_loop = loop_contains(l, inst_parent(pn));
            if in_loop { phi_add_incoming(np, phi_value_for_block(pn, nph), ph); }
            else { phi_add_incoming(np, c_poison(vals[pn].ty), ph); }
            var v = phi_value_for_block(pn, latch);
            if is_inst(v) && loop_contains(l, inst_parent(v)) { v = vmm_get(vm, v); }
            phi_add_incoming(np, v, prolog_latch);
            if in_loop { set_op(pn, phi_block_index(pn, nph), np); }
            else { phi_add_incoming(pn, np, prolog_exit); }
            sc_forget_lcssa_phi_with_new_predecessor(l, pn);
            pn = inst_next(pn);
        }
    }
    let pl = li_loop_for(prolog_latch);
    if pl >= 0 {
        var preds: i32[>..<] = [];
        each_pred(prolog_exit) { p => if loop_contains(pl, p) { preds.push(p); } };
        split_block_predecessors(prolog_exit, preds, ".unr-lcssa", true, true, preserve_lcssa);
    }
    let ip = block_terminator(prolog_exit);
    ur_set(ip);
    let br_exit = ur_icmp(36, be_count, c_int(vals[be_count].ty, count - 1), "");
    var preds2: i32[>..<] = [];
    each_pred(latch_exit) { p => preds2.push(p); };
    split_block_predecessors(latch_exit, preds2, ".unr-lcssa", true, true, preserve_lcssa);
    var ws: u64[>..<] = [];
    if has_branch_weight_md(block_terminator(latch)) { ws.push(1); ws.push(127); }
    ur_condbr(br_exit, latch_exit, nph, ws);
    inst_erase_from_parent(ip);
    let fv = block_func(ph);
    let nd = dt_find_ncd(DT_DOM, latch_exit, prolog_exit);
    dt_change_idom(fv, DT_DOM, latch_exit, nd);
}

// ConnectEpilog
fn connect_epilog(l: i32, mod_val: i32, new_exit: i32, exit: i32, ph: i32, epil_ph: i32, nph: i32, vm: i32,
                  preserve_lcssa: bool, count: i64, orig_prob: u32) {
    let latch = loop_latch(l);
    let epil_latch = vmm_get(vm, latch);
    let fv = block_func(ph);
    var pn = block_first(new_exit);
    while pn >= 0 && iop(pn) == OP_PHI {
        let epn = uses[vals[pn].first_use].user;
        var v = phi_value_for_block(pn, latch);
        if is_inst(v) && loop_contains(l, inst_parent(v)) { v = vmm_get(vm, v); }
        phi_add_incoming(epn, v, epil_latch);
        sc_forget_lcssa_phi_with_new_predecessor(l, epn);
        phi_set_block(epn, phi_block_index(epn, epil_ph), new_exit);
        pn = inst_next(pn);
    }
    let lt = block_terminator(latch);
    var succs: i32[>..<] = [];
    for k in term_nsucc(lt) { succs.push(term_succ(lt, k)); }
    for s in succs {
        if !loop_contains(l, s) { continue; }
        var p = block_first(s);
        while p >= 0 && iop(p) == OP_PHI {
            let np0 = new_phi(vals[p].ty, 1);
            inst_insert_before_head(np0, first_non_phi(new_exit));
            var n0: u8[>..] = [];
            n0.append(val_name(p));
            n0.append(".unr");
            set_name(np0, n0);
            phi_add_incoming(np0, phi_value_for_block(p, latch), latch);
            let np1 = new_phi(vals[p].ty, 2);
            inst_insert_before_head(np1, first_non_phi(epil_ph));
            var n1: u8[>..] = [];
            n1.append(val_name(p));
            n1.append(".epil.init");
            set_name(np1, n1);
            phi_add_incoming(np1, phi_value_for_block(p, nph), ph);
            phi_add_incoming(np1, np0, new_exit);
            let vpn = vmm_get(vm, p);
            set_op(vpn, phi_block_index(vpn, epil_ph), np1);
            p = inst_next(p);
        }
    }
    let ip = block_terminator(new_exit);
    ur_set(ip);
    let br_exit = ur_icmp(33, mod_val, c_null(vals[mod_val].ty), "lcmp.mod");
    var preds: i32[>..<] = [];
    each_pred(exit) { q => preds.push(q); };
    split_block_predecessors(exit, preds, ".epilog-lcssa", true, true, preserve_lcssa);
    var ws: u64[>..<] = [];
    if orig_prob == 0xFFFFFFFF && has_branch_weight_md(block_terminator(latch)) { ws.push(1); ws.push(((count - 1) & 0xFFFFFFFF) as u64); }
    let rguard = ur_condbr(br_exit, epil_ph, exit, ws);
    if orig_prob != 0xFFFFFFFF { lmd_set_branch_probability(rguard, prob_of_next_in_remainder(orig_prob, count - 1), true); }
    inst_erase_from_parent(ip);
    let nd = dt_find_ncd(DT_DOM, exit, new_exit);
    dt_change_idom(fv, DT_DOM, exit, nd);
    // IRBuilder<> B2(EpilogPreHeader, EpilogPreHeader->getFirstNonPHIIt())
    ur_set_head(first_non_phi(epil_ph));
    let nn = ur_icmp(33, mod_val, c_null(vals[mod_val].ty), "lcmp.mod");
    let assume = au_get_declaration(IID_assume, []);
    let ci = create_inst(OP_CALL, T_VOID, [nn, assume]);
    insts[inst_of(ci)].ty2 = globs[glob_of(assume)].vty;
    ur_insert(ci, "");
    vt_invalidate_assumes();
    ac_register_assumption(ci);
}

// CloneLoopBlocks(L, NewIter, UseEpilogRemainder, UnrollRemainder, InsertTop, InsertBot, Preheader, NewBlocks,
// LoopBlocks, VMap, DT, LI, Count, OriginalTripCount, OriginalLoopProb)
fn ur_clone_loop_blocks(l: i32, new_iter: i32, epilog: bool, unroll_remainder: bool, top: i32, bot: i32, ph: i32,
                        new_blocks: i32[>..<]&, rpo: i32[>..<]&, vm: i32, count: i64, has_otc: bool, otc: u64, orig_prob: u32) -> i32 {
    let sfx: const u8[:] = if epilog { "epil" } else { "prol" };
    var dsfx: u8[>..] = [];
    dsfx.append(".");
    dsfx.append(sfx);
    let header = loop_header(l);
    let latch = loop_latch(l);
    let fv = block_func(header);
    let parent = loop_parent(l);
    var nl_o: i32[>..<] = [];
    var nl_n: i32[>..<] = [];
    nl_o.push(parent);
    nl_n.push(parent);
    for bb in rpo {
        let nb = clone_basic_block(bb, vm, dsfx, fv, false);
        new_blocks.push(nb);
        add_cloned_block_to_loop_info(bb, nb, nl_o, nl_n);
        vmm_set(vm, bb, nb);
        if header == bb { term_set_succ(block_terminator(top), 0, nb); }
        if header == bb { dt_add_new_block(fv, DT_DOM, nb, top); }
        else { dt_add_new_block(fv, DT_DOM, nb, vmm_get(vm, dt_idom(DT_DOM, bb))); }
        if latch == bb {
            vmm_erase(vm, block_terminator(bb));
            let first = vmm_get(vm, header);
            let lbr = block_terminator(nb);
            ur_set(lbr);
            let nidx = new_phi(vals[new_iter].ty, 2);
            inst_insert_before_head(nidx, first_non_phi(first));
            var inm: u8[>..] = [];
            inm.append(sfx);
            inm.append(".iter");
            set_name(nidx, inm);
            let zero = c_int(vals[nidx].ty, 0);
            let one = c_int(vals[nidx].ty, 1);
            var nn: u8[>..] = [];
            nn.append(val_name(nidx));
            nn.append(".next");
            let idx_next = ur_binop(OP_ADD, nidx, one, nn);
            var nc: u8[>..] = [];
            nc.append(val_name(nidx));
            nc.append(".cmp");
            let idx_cmp = ur_icmp(33, idx_next, new_iter, nc);
            var ws: u64[>..<] = [];
            if (orig_prob == 0xFFFFFFFF || !epilog) && has_branch_weight_md(lbr) {
                var bw: u64 = 0;
                if count >= 3 { bw = ((count - 2) / 2) as u64; }
                ws.push(bw);
                ws.push(1);
            }
            let rll = ur_condbr(idx_cmp, first, bot, ws);
            if orig_prob != 0xFFFFFFFF && epilog {
                var freq = 1.0;
                if count > 2 {
                    var reach = BP_D as u32;
                    var n = count - 2;
                    while n >= 1 {
                        reach = bp_mul(reach, prob_of_next_in_remainder(orig_prob, n));
                        freq += bp_to_double(reach);
                        n--;
                    }
                }
                lmd_set_branch_probability(rll, bp_from_double(1.0 - 1.0 / freq), true);
            }
            phi_add_incoming(nidx, zero, top);
            phi_add_incoming(nidx, idx_next, nb);
            inst_erase_from_parent(lbr);
        }
    }
    var i = block_first(header);
    while i >= 0 && iop(i) == OP_PHI {
        let np = vmm_get(vm, i);
        var idx = phi_block_index(np, ph);
        phi_set_block(np, idx, top);
        let nlatch = vmm_get(vm, latch);
        idx = phi_block_index(np, latch);
        let inv = phi_value(np, idx);
        phi_set_block(np, idx, nlatch);
        let v = vmm_get(vm, inv);
        if v >= 0 { set_op(np, idx, v); }
        i = inst_next(i);
    }
    var nl: i32 = -1;
    for k in nl_o.len { if nl_o[k] == l { nl = nl_n[k]; } }
    if has_otc && epilog { set_loop_estimated_trip_count(nl, otc % (count as u64), false, 0); }
    if !unroll_remainder { loop_set_already_unrolled(nl); }
    return nl;
}

// canProfitablyRuntimeUnrollMultiExitLoop
fn can_profitably_runtime_unroll_multi_exit_loop(l: i32, other_exits: i32[>..<]&, latch_exit: i32, epilog: bool) -> bool {
    var exiting: i32[>..<] = [];
    loop_exiting_blocks(l, exiting);
    if exiting.len > 2 { return false; }
    if other_exits.len == 0 { return true; }
    if other_exits.len != 1 { return false; }
    if flag_bool("unroll-runtime-other-exit-predictable", false) { return true; }
    if tti_kind != TTI_NONE || true {
        let lbb = loop_latch(l);
        let nle = if exiting[0] == lbb { exiting[1] } else { exiting[0] };
        let bp = lmd_branch_probability_edge(nle, other_exits[0]);
        if bp != 0xFFFFFFFF {
            let th = bp_compl(tti_predictable_branch_threshold());
            return bp < th;
        }
    }
    return postdominating_deoptimize_call(other_exits[0]) >= 0;
}

// CreateTripRemainder(B, BECount, TripCount, Count)
fn create_trip_remainder(be: i32, tc: i32, count: i64) -> i32 {
    if (count & (count - 1)) == 0 { return ur_binop(OP_AND, tc, c_int(vals[tc].ty, count - 1), "xtraiter"); }
    let cc = c_int(vals[be].ty, count);
    let tmp = ur_binop(OP_UREM, be, cc, "");
    let add = ur_binop(OP_ADD, tmp, c_int(vals[tmp].ty, 1), "");
    return ur_binop(OP_UREM, add, cc, "xtraiter");
}

// breakLoopBackedge(L, DT, SE, LI, MSSA = null)
fn break_loop_backedge(l: i32) {
    let latch = loop_latch(l);
    let header = loop_header(l);
    let fv = block_func(header);
    let outermost = loop_outermost(l);
    sc_forget_loop(l);
    sc_forget_block_and_loop_dispositions_all();
    let bi = block_terminator(latch);
    if iop(bi) == OP_BR {
        dtu_begin(fv, true, false, false);
        let save = cu_dtu;
        cu_dtu = true;
        urt_not_ported("breakLoopBackedge of an unconditional latch");
        cu_dtu = save;
        dtu_end();
    } else if iop(bi) == OP_CONDBR && loop_is_exiting(l, latch) {
        let ei: i64 = if loop_contains(l, term_succ(bi, 0)) { 1 } else { 0 };
        let exit_bb = term_succ(bi, ei);
        block_remove_predecessor(header, latch, true);
        let nbi = create_inst(OP_BR, T_VOID, [exit_bb]);
        inst_insert_before(nbi, bi);
        let dl = inst_get_md(bi, 0);
        if dl >= 0 { inst_set_md(nbi, 0, dl); }
        let an = inst_get_md(bi, 30);
        if an >= 0 { inst_set_md(nbi, 30, an); }
        inst_erase_from_parent(bi);
        let ups: DTUpdate[1] = [DTUpdate { kind: DT_DELETE, from: latch, to: header }];
        dt_apply_updates(fv, DT_DOM, ups);
    } else {
        urt_not_ported("breakLoopBackedge through SplitEdge");
    }
    li_erase_loop(l);
    if outermost != l {
        let save = lcssa_se;
        lcssa_se = true;
        form_lcssa_recursively(outermost);
        lcssa_se = save;
    }
}

// UnrollRuntimeLoopRemainder: (done, remainder loop, unroll the remainder by Count - 1 afterwards)
fn unroll_runtime_loop_remainder(l: i32, count: i64, allow_expensive: bool, epilog: bool, unroll_remainder: bool,
                                 forget_all: bool, preserve_lcssa: bool, budget: i64, multi_exit: bool,
                                 has_otc: bool, otc: u64, orig_prob: u32) -> bool, i32, bool {
    if !loop_is_simplify_form(l) { return false, -1, false; }
    let latch = loop_latch(l);
    let header = loop_header(l);
    let fv = block_func(header);
    let lbr = block_terminator(latch);
    if iop(lbr) != OP_CONDBR { return false, -1, false; }
    let exit_index: i64 = if term_succ(lbr, 0) == header { 1 } else { 0 };
    let latch_exit = term_succ(lbr, exit_index);
    if loop_contains(l, latch_exit) { return false, -1, false; }
    var other_exits: i32[>..<] = [];
    loop_unique_non_latch_exit_blocks(l, other_exits);
    if loop_exiting_block(l) < 0 || other_exits.len > 0 {
        if !preserve_lcssa { return false, -1, false; }
        if flag_given("unroll-runtime-multi-exit") {
            if !flag_bool("unroll-runtime-multi-exit", false) { return false, -1, false; }
        } else {
            if !multi_exit && !can_profitably_runtime_unroll_multi_exit_loop(l, other_exits, latch_exit, epilog) { return false, -1, false; }
        }
    }
    if !scev_valid(fv) { return false, -1, false; }
    let be_sc = sc_get_exit_count(l, latch, BTC_EXACT, false);
    if sc_is_cnc(be_sc) { return false, -1, false; }
    let be_width = ty_bits(sc_ty(be_sc));
    let tc_sc = sc_add(be_sc, sc_get_constant_ty(sc_ty(be_sc), 1, false));
    if sc_is_cnc(tc_sc) { return false, -1, false; }
    let ph = loop_preheader(l);
    var phbr = block_terminator(ph);
    sx_begin("loop-unroll", true);
    if !allow_expensive && sx_is_high_cost_expansion([tc_sc], l, budget, phbr) { sx_end(); return false, -1, false; }
    var lg: i64 = 0;
    while ((1 as i64) << (lg + 1)) <= count { lg++; }
    if lg > be_width { sx_end(); return false, -1, false; }
    var nph: i32 = -1;
    var new_exit: i32 = -1;
    var prolog_exit: i32 = -1;
    var epil_ph: i32 = -1;
    var prol_ph: i32 = -1;
    if epilog {
        nph = lp_split_block(ph, block_terminator(ph));
        var n1: u8[>..] = []; n1.append(val_name(ph)); n1.append(".new");
        set_name(nph, n1);
        let pl: i32[1] = [latch];
        new_exit = split_block_predecessors(latch_exit, pl, ".unr-lcssa", true, true, preserve_lcssa);
        let net = block_terminator(new_exit);
        inst_set_md(net, 0, inst_get_md(block_terminator(header), 0));
        epil_ph = lp_split_block(new_exit, net);
        var n2: u8[>..] = []; n2.append(val_name(header)); n2.append(".epil.preheader");
        set_name(epil_ph, n2);
        let parent = loop_parent(l);
        if parent >= 0 && li_loop_for(latch_exit) != parent {
            li_remove_block(new_exit);
            loop_add_basic_block_to_loop(parent, new_exit);
            li_remove_block(epil_ph);
            loop_add_basic_block_to_loop(parent, epil_ph);
        }
    } else {
        prol_ph = lp_split_edge(ph, header);
        var n1: u8[>..] = []; n1.append(val_name(header)); n1.append(".prol.preheader");
        set_name(prol_ph, n1);
        prolog_exit = lp_split_block(prol_ph, block_terminator(prol_ph));
        var n2: u8[>..] = []; n2.append(val_name(header)); n2.append(".prol.loopexit");
        set_name(prolog_exit, n2);
        nph = lp_split_block(prolog_exit, block_terminator(prolog_exit));
        var n3: u8[>..] = []; n3.append(val_name(ph)); n3.append(".new");
        set_name(nph, n3);
    }
    phbr = block_terminator(ph);
    ur_set(phbr);
    var trip_count = sx_expand_code_for_at(tc_sc, sc_ty(tc_sc), phbr);
    var be_count: i32 = -1;
    if (other_exits.len > 0 || !sc_loop_has_no_abnormal_exits(l)) && !is_guaranteed_not_to_be_undef_or_poison(trip_count, phbr, 0) {
        ur_set(phbr);
        trip_count = ur_insert(create_inst(OP_FREEZE, vals[trip_count].ty, [trip_count]), "");
        be_count = ur_binop(OP_ADD, trip_count, c_all_ones(vals[trip_count].ty), "");
    } else {
        be_count = sx_expand_code_for_at(be_sc, sc_ty(be_sc), phbr);
    }
    ur_set(phbr);
    let mod_val = create_trip_remainder(be_count, trip_count, count);
    let branch_val = if epilog { ur_icmp(36, be_count, c_int(vals[be_count].ty, count - 1), "") }
                     else { ur_icmp(33, mod_val, c_null(vals[mod_val].ty), "lcmp.mod") };
    let remainder_bb = if epilog { epil_ph } else { prol_ph };
    let unrolling_bb = if epilog { nph } else { prolog_exit };
    var ws: u64[>..<] = [];
    if (orig_prob == 0xFFFFFFFF || !epilog) && has_branch_weight_md(block_terminator(latch)) { ws.push(1); ws.push(127); }
    let rguard = ur_condbr(branch_val, remainder_bb, unrolling_bb, ws);
    if orig_prob != 0xFFFFFFFF && epilog { lmd_set_branch_probability(rguard, bp_pow(orig_prob, count - 1), false); }
    inst_erase_from_parent(phbr);
    if epilog { dt_change_idom(fv, DT_DOM, epil_ph, ph); } else { dt_change_idom(fv, DT_DOM, prolog_exit, ph); }
    var rpo: i32[>..<] = [];
    loop_blocks_rpo(l, rpo);
    var new_blocks: i32[>..<] = [];
    let vm = vmm_new();
    let ins_bot = if epilog { latch_exit } else { prolog_exit };
    let ins_top = if epilog { epil_ph } else { prol_ph };
    var rl = ur_clone_loop_blocks(l, mod_val, epilog, unroll_remainder, ins_top, ins_bot, nph, new_blocks, rpo, vm, count, has_otc, otc, orig_prob);
    var b = new_blocks[0];
    while b >= 0 { let nx = block_next(b); block_move_before(b, ins_bot); b = nx; }
    for bb in other_exits {
        var pn = block_first(bb);
        while pn >= 0 && iop(pn) == OP_PHI {
            let n = nops(pn);
            for k in n {
                let pb = phi_block(pn, k);
                if pb == latch { continue; }
                if !loop_contains(l, pb) { continue; }
                var v = phi_value(pn, k);
                if is_inst(v) && loop_contains(l, inst_parent(v)) { v = vmm_get(vm, v); }
                phi_add_incoming(pn, v, vmm_get(vm, pb));
            }
            pn = inst_next(pn);
        }
    }
    if loop_exiting_block(l) < 0 {
        var upd: i32[>..<] = [];
        for k in loop_nblocks(l) {
            let bb = loop_block(l, k);
            var ch: i32[>..<] = [];
            ul_dt_children(fv, bb, ch);
            for c in ch {
                if !loop_contains_loop(l, li_loop_for(c)) && cu_unique_pred(c) != bb { upd.push(c); }
            }
        }
        for c in upd { dt_change_idom(fv, DT_DOM, c, ph); }
    }
    for bb in new_blocks {
        var i = block_first(bb);
        while i >= 0 {
            remap_instruction(i, vm, RF_NO_MODULE_LEVEL_CHANGES | RF_IGNORE_MISSING_LOCALS);
            remap_dbg_record_range(i, vm, RF_NO_MODULE_LEVEL_CHANGES | RF_IGNORE_MISSING_LOCALS);
            i = inst_next(i);
        }
    }
    if epilog {
        connect_epilog(l, mod_val, new_exit, latch_exit, ph, epil_ph, nph, vm, preserve_lcssa, count, orig_prob);
        ur_set(block_terminator(nph));
        let test = ur_binop(OP_SUB, trip_count, mod_val, "unroll_iter");
        let lb = block_terminator(latch);
        let nidx = new_phi(vals[test].ty, 2);
        inst_insert_before_head(nidx, first_non_phi(header));
        set_name(nidx, "niter");
        ur_set(lb);
        let zero = c_int(vals[nidx].ty, 0);
        let one = c_int(vals[nidx].ty, 1);
        let inext = ur_binop(OP_ADD, nidx, one, "niter.next");
        let pred: i64 = if term_succ(lb, 0) == header { 33 } else { 32 };
        let icmp = ur_icmp(pred, inext, test, "niter.ncmp");
        phi_add_incoming(nidx, zero, nph);
        phi_add_incoming(nidx, inext, latch);
        set_op(lb, 0, icmp);
    } else {
        connect_prolog(l, be_count, count, prolog_exit, latch_exit, ph, nph, vm, preserve_lcssa);
    }
    sx_end();
    sc_forget_topmost_loop(l);
    if count == 2 {
        let rlatch = loop_latch(rl);
        var rblocks: i32[>..<] = [];
        for k in loop_nblocks(rl) { rblocks.push(loop_block(rl, k)); }
        break_loop_backedge(rl);
        rl = -1;
        let save_tli = local_have_tli;
        local_have_tli = false;
        for bb in rblocks {
            var dead: i32[>..<] = [];
            var i = block_first(bb);
            while i >= 0 {
                let nx = inst_next(i);
                let a = sq_no_tli; let bq = sq_no_dt; let c = sq_no_ac; let d = dc_active;
                sq_no_tli = true; sq_no_dt = false; sq_no_ac = false; dc_active = false;
                let v = simplify_instruction(i);
                sq_no_tli = a; sq_no_dt = bq; sq_no_ac = c; dc_active = d;
                if v >= 0 && uu_replacement_preserves_lcssa(i, v) { ac_rauw(i, v); rauw(i, v); }
                if is_instruction_trivially_dead(i) { dead.push(i); }
                i = nx;
            }
            recursively_delete_trivially_dead(dead);
        }
        local_have_tli = save_tli;
        let exit_bb = cu_unique_succ_single(rlatch);
        dtu_begin(fv, true, false, false);
        ul_merge_block_into_predecessor(exit_bb, true);
        dtu_end();
    }
    if other_exits.len > 0 {
        form_dedicated_exit_blocks(l, preserve_lcssa);
        if rl >= 0 { form_dedicated_exit_blocks(rl, preserve_lcssa); }
    }
    return true, rl, rl >= 0 && unroll_remainder;
}
// BasicBlock::getSingleSuccessor
fn cu_unique_succ_single(bb: i32) -> i32 {
    let t = block_terminator(bb);
    if t < 0 || term_nsucc(t) != 1 { return -1; }
    return term_succ(t, 0);
}
