// GeneratedRTChecks of LoopVectorize (create, getCost, the destructor's cleanup, getSCEVChecks /
// getMemRuntimeChecks) and LoopUtils' addDiffRuntimeChecks with SCEVPtrToAddrRewriter.
// Ported from llvm/lib/Transforms/Vectorize/LoopVectorize.cpp and llvm/lib/Transforms/Utils/LoopUtils.cpp
// (LLVM 23.1.5).
//
// LLVM keeps two SCEVExpanders alive (SCEVExp for the predicate checks, MemCheckExp for the memory checks); goose
// has one expander at a time, so each phase runs its own expander and keeps a snapshot of what it inserted (the
// instructions and the original poison flags), which is all the destructor's SCEVExpanderCleaner needs. The two
// expanders never share an expansion cache in LLVM either.
import std;
import ir;
import irutil;
import instinfo;
import flags;
import domtree;
import loopinfo;
import loop_utils;
import scev;
import scev_create;
import scev_eval;
import scev_update;
import scev_lt;
import scev_btc;
import scev_guards;
import scev_range;
import scev_expander;
import pse;
import laa;
import loop_versioning;
import tti;
import lv_cost;
import lv_pass;
import loop_md;

var lrt_created: bool = false;
var lrt_scev_block: i32 = -1;
var lrt_scev_cond: i32 = -1;
var lrt_mem_block: i32 = -1;
var lrt_mem_cond: i32 = -1;
var lrt_cost_too_high: bool = false;
var lrt_outer: i32 = -1;
var lrt_fv: i32 = -1;
// the expanders' snapshots: inserted instructions (insertion order) and (instruction, original flags) pairs
var lrt_scev_ins: i32[>..<];
var lrt_scev_flags: i32[>..<];
var lrt_mem_ins: i32[>..<];
var lrt_mem_flags: i32[>..<];

fn lrt_reset() {
    lrt_created = false;
    lrt_scev_block = -1; lrt_scev_cond = -1; lrt_mem_block = -1; lrt_mem_cond = -1;
    lrt_cost_too_high = false; lrt_outer = -1; lrt_fv = -1;
    lrt_scev_ins.clear(); lrt_scev_flags.clear(); lrt_mem_ins.clear(); lrt_mem_flags.clear();
}

fn lrt_is_const_int(v: i32, x: i64) -> bool { v >= 0 && vals[v].kind == VK_CINT && cint_lo(v) == x as u64 }
// getSCEVChecks / getMemRuntimeChecks: (cond, block); a check that folded to false is no check
fn lrt_scev_checks() -> i32, i32 {
    if lrt_scev_cond < 0 || lrt_is_const_int(lrt_scev_cond, 0) { return -1, -1; }
    return lrt_scev_cond, lrt_scev_block;
}
fn lrt_mem_checks() -> i32, i32 {
    if lrt_mem_cond >= 0 && lrt_is_const_int(lrt_mem_cond, 0) { return -1, -1; }
    return lrt_mem_cond, lrt_mem_block;
}
fn lrt_has_checks() -> bool {
    let a, ab = lrt_scev_checks();
    let b, bb = lrt_mem_checks();
    return a >= 0 || b >= 0;
}

// the active expander's state, for the destructor's SCEVExpanderCleaner
fn lrt_snapshot(ins: i32[>..<]&, fl: i32[>..<]&) {
    sx_all_inserted_instructions(ins);
    fl.clear();
    for i in sx_oflags_order { fl.push(i); fl.push(hm_get(sx_oflags, i as u64, 0) as i32); }
}
// SCEVExpanderCleaner::cleanup with ResultUsed = false
fn lrt_cleanup(ins: i32[>..<]&, fl: i32[>..<]&) {
    var k: i64 = 0;
    while k < fl.len {
        let i = fl[k];
        if !is_dead(i) { insts[inst_of(i)].flags = fl[k + 1] as u8; }
        k += 2;
    }
    var j = ins.len - 1;
    while j >= 0 {
        let i = ins[j];
        j--;
        if is_dead(i) { continue; }
        rauw(i, c_poison(vals[i].ty as i32));
        inst_erase_from_parent(i);
    }
    ins.clear();
    fl.clear();
}

// SplitBlock(Old, Old->getTerminator(), DT, LI, nullptr, Name)
fn lrt_split(old: i32, name: const u8[:]) -> i32 { lu_split_block_named(old, block_terminator(old), name, false) }

// GeneratedRTChecks::create(L, LAI, UnionPred, VF, IC)
fn lrt_create(l: i32, union_pred: i32, vf: i64, ic: i64) {
    lrt_reset();
    lrt_created = true;
    lrt_fv = block_func(loop_header(l));
    lrt_cost_too_high = rpc_checks.len > flag_int("runtime-memory-check-threshold", 128);
    if lrt_cost_too_high {
        lrt_mem_cond = c_true();
        lrt_scev_cond = c_true();
        return;
    }
    let header = loop_header(l);
    let ph = loop_preheader(l);
    if !su_always_true(union_pred) {
        lrt_scev_block = lrt_split(ph, "vector.scevcheck");
        sx_begin("scev.check", false);
        lrt_scev_cond = sx_expand_union_predicate(union_pred, block_terminator(lrt_scev_block));
        if is_constant(lrt_scev_cond) { sx_cleanup(); }
        // SCEVExp.eraseDeadInstructions(SCEVCheckCond) (LLVM runs it after the memory checks; MemCheckExp never
        // uses SCEVExp's instructions)
        sx_erase_dead_instructions(lrt_scev_cond);
        lrt_snapshot(lrt_scev_ins, lrt_scev_flags);
        sx_end();
    }
    if rpc_need {
        let pred = if lrt_scev_block >= 0 { lrt_scev_block } else { ph };
        lrt_mem_block = lrt_split(pred, "vector.memcheck");
        sx_begin("scev.check", false);
        let loc = block_terminator(lrt_mem_block);
        if rpc_can_diff {
            lrt_mem_cond = lrt_add_diff_runtime_checks(loc, vf, ic);
        } else {
            var cs: i64[>..<] = [];
            for c in rpc_checks { cs.push(c); }
            lrt_mem_cond = lver_add_runtime_checks_h(loc, l, cs, flag_bool("hoist-runtime-checks", true));
        }
        if lrt_mem_cond < 0 { fatal("internal: no RT checks generated although RtPtrChecking claimed checks are required"); }
        lrt_snapshot(lrt_mem_ins, lrt_mem_flags);
        sx_end();
    }
    if lrt_mem_block < 0 && lrt_scev_block < 0 { return; }
    // unhook the temporary blocks with the checks
    // replaceAllUsesWith(Preheader) also covers the successors' PHI incoming blocks (goose keeps those apart)
    fn block_rauw(blk: i32) {
        let t = block_terminator(blk);
        for k in term_nsucc(t) { block_replace_phi_uses_with(term_succ(t, k), blk, ph); }
        rauw(blk, ph);
    }
    if lrt_scev_block >= 0 { block_rauw(lrt_scev_block); }
    if lrt_mem_block >= 0 { block_rauw(lrt_mem_block); }
    fn unhook(blk: i32) {
        let t = block_terminator(blk);
        let pt = block_terminator(ph);
        inst_move_before(t, pt);
        block_append_inst(blk, create_inst(OP_UNREACHABLE, T_VOID, []));
        inst_erase_from_parent(pt);
    }
    if lrt_scev_block >= 0 { unhook(lrt_scev_block); }
    if lrt_mem_block >= 0 { unhook(lrt_mem_block); }
    if dt_has_node(DT_DOM, header) {
        dt_change_idom(lrt_fv, DT_DOM, header, ph);
        if lrt_mem_block >= 0 && dt_has_node(DT_DOM, lrt_mem_block) { dt_erase_node(lrt_fv, DT_DOM, lrt_mem_block); }
        if lrt_scev_block >= 0 && dt_has_node(DT_DOM, lrt_scev_block) { dt_erase_node(lrt_fv, DT_DOM, lrt_scev_block); }
    }
    if lrt_mem_block >= 0 { li_remove_block(lrt_mem_block); }
    if lrt_scev_block >= 0 { li_remove_block(lrt_scev_block); }
    lrt_outer = loop_parent(l);
}

// getSmallBestKnownTC(PSE, OuterLoop, CanUseConstantMax = false): 0 = none
fn lrt_outer_best_known_tc(l: i32) -> i64 {
    let tc = lv_small_constant_trip_count(l);
    if tc != 0 { return tc; }
    if flag_bool("loop-vectorize-with-block-frequency", true) {
        let has, v = get_loop_estimated_trip_count(l);
        if has { return v as i64; }
    }
    return -1;
}

// GeneratedRTChecks::getCost
fn lrt_get_cost() -> i64 {
    if !lrt_created { return 0; }
    if lrt_cost_too_high { return LC_INVALID; }
    var total: i64 = 0;
    if lrt_scev_block >= 0 {
        let t = block_terminator(lrt_scev_block);
        var i = block_first(lrt_scev_block);
        while i >= 0 { if i != t { total = lc_add(total, lcv(tti_instruction_cost(i, LV_KIND))); } i = inst_next(i); }
    }
    if lrt_mem_block >= 0 {
        var mc: i64 = 0;
        let t = block_terminator(lrt_mem_block);
        var i = block_first(lrt_mem_block);
        while i >= 0 { if i != t { mc = lc_add(mc, lcv(tti_instruction_cost(i, LV_KIND))); } i = inst_next(i); }
        if lrt_outer >= 0 {
            let cond = sc_get_scev(lrt_mem_cond);
            if sc_is_loop_invariant(cond, lrt_outer) {
                var best: i64 = 2;
                let e = lrt_outer_best_known_tc(lrt_outer);
                if e >= 0 { best = e; }
                if best == 0 { fatal("internal: loop-vectorize: an estimated outer trip count of 0"); }
                var n = lc_value(lc_div(mc, best));
                if n < 1 { n = 1; }
                mc = lcv(n);
            }
        }
        total = lc_add(total, mc);
    }
    return total;
}

// ~GeneratedRTChecks
fn lrt_destroy() {
    if !lrt_created { return; }
    lrt_created = false;
    let scev_used = lrt_scev_block < 0 || pred_count(lrt_scev_block) != 0;
    let mem_used = lrt_mem_block < 0 || pred_count(lrt_mem_block) != 0;
    if !mem_used {
        var is_ins = hm_new();
        for x in lrt_mem_ins { hm_put(is_ins, x as u64, 1); }
        var all: i32[>..<] = [];
        var i = block_first(lrt_mem_block);
        while i >= 0 { all.push(i); i = inst_next(i); }
        var k = all.len - 1;
        while k >= 0 {
            let x = all[k];
            k--;
            if hm_has(is_ins, x as u64) { continue; }
            sc_forget_value(x);
            if vals[x].first_use >= 0 { rauw(x, c_poison(vals[x].ty as i32)); }
            inst_erase_from_parent(x);
        }
        lrt_cleanup(lrt_mem_ins, lrt_mem_flags);
    }
    if !scev_used { lrt_cleanup(lrt_scev_ins, lrt_scev_flags); }
    if !scev_used { block_erase(lrt_scev_block); }
    if !mem_used { block_erase(lrt_mem_block); }
}

// SCEVPtrToAddrRewriter: diff check starts are getPtrToAddrExpr already; a ptrtoint inside them would need the
// rewrite
recursive fn lrt_has_ptr_to_int(s: i32) -> bool {
    if sc_kind(s) == SC_PTRTOINT { return true; }
    for k in sc_nops(s) { if lrt_has_ptr_to_int(sc_op(s, k)) { return true; } }
    return false;
}

// addDiffRuntimeChecks(Loc, Checks, Expander, GetVF, IC) (the expander is active)
fn lrt_add_diff_runtime_checks(loc: i32, vf: i64, ic: i64) -> i32 {
    lvb_set_before(loc);
    var mem_check: i32 = -1;
    var seen_d: i32[>..<] = [];
    var seen_t: i32[>..<] = [];
    var thr_ty: i32[>..<] = [];
    var thr_n: i64[>..<] = [];
    var thr_v: i32[>..<] = [];
    var k: i64 = 0;
    while k < rpc_diff.len {
        let src_start = rpc_diff[k];
        let sink_start = rpc_diff[k + 1];
        let size = rpc_diff[k + 2] as i64;
        let freeze = rpc_diff[k + 3] != 0;
        k += 4;
        let ty = sc_ty(sink_start);
        let n = ic * size;
        let one = c_int(ty, 1);
        var thr: i32 = -1;
        for j in thr_ty.len { if thr_ty[j] == ty && thr_n[j] == n { thr = thr_v[j]; } }
        if thr < 0 {
            lvb_set_before(loc);
            let m = lvb_binop(OP_MUL, c_int(ty, vf), c_int(ty, n), "");
            thr = lvb_binop(OP_SUB, m, one, "");
            thr_ty.push(ty); thr_n.push(n); thr_v.push(thr);
        }
        if lrt_has_ptr_to_int(sink_start) || lrt_has_ptr_to_int(src_start) { fatal("loop-vectorize: SCEVPtrToAddrRewriter of a ptrtoint is not supported yet"); }
        let diff = sx_expand_code_for_at(sc_minus(sink_start, src_start), ty, loc);
        var dup = false;
        for j in seen_d.len { if seen_d[j] == diff && seen_t[j] == thr { dup = true; } }
        if dup { continue; }
        lvb_set_before(loc);
        var conflict = lvb_icmp(P_ULT, lvb_binop(OP_SUB, diff, one, ""), thr, "diff.check");
        seen_d.push(diff); seen_t.push(thr);
        if freeze {
            var nm: u8[>..] = [];
            if vals[conflict].name >= 0 { nm.append(val_name(conflict)); }
            nm.append(".fr");
            conflict = lvb_insert(create_inst(OP_FREEZE, vals[conflict].ty as i32, [conflict]), nm);
        }
        if mem_check >= 0 { conflict = lvb_binop(OP_OR, mem_check, conflict, "conflict.rdx"); }
        mem_check = conflict;
    }
    sx_erase_dead_instructions(mem_check);
    return mem_check;
}
