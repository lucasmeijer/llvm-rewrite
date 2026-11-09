// JumpThreading: a port of llvm/lib/Transforms/Scalar/JumpThreading.cpp (every function, in file order), with the
// utilities it needs from llvm/lib/Transforms/Utils/Local.cpp (SimplifyInstructionsInBlock,
// simplifyAndDCEInstruction, replaceNonLocalUsesWith, remapDebugVariable), BasicBlockUtils.cpp (SplitEdge,
// SplitBlockAndInsertIfThen, DuplicateInstructionsInSplitBetween is in CloneFunction.cpp with cloneNoAliasScopes,
// identifyNoAliasScopesToClone, adaptNoAliasScopes), llvm/lib/Analysis/Loads.cpp (FindAvailableLoadedValue with a
// scan position, findAvailablePtrLoadStore), SSAUpdater::UpdateDebugValues and Constant::removeDeadConstantUsers.
//
// The DomTreeUpdater is the Lazy one (dtu.goose, cu_dtu for the cfgutil helpers). LazyValueInfo is lvi.goose.
// BlockFrequencyInfo / BranchProbabilityInfo (bfi.goose, bpi.goose) are computed and kept up to date exactly
// where LLVM does it (getOrCreateBFI / runExternalAnalysis).
//
// Containers: PredValueInfo lists live on the global stack jt_pv (pairs constant, block) with marks, because
// computeValueKnownInPredecessorsImpl is recursive; ValueToValueMapTy is scratch map VM_PASS0 (VM_PASS1 for the
// second map of threadGuard); Unreachable and LoopHeaders are hash sets (jt_unreach, jt_lh).
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_attrs;
import gen_iids;
import apint;
import constrange;
import valuelattice;
import constfold;
import cfold;
import instsimplify;
import knownbits;
import pm;
import vt;
import poison;
import assume;
import speculate;
import domtree;
import dtu;
import cfgutil;
import profdata;
import analyses;
import dinfo;
import dbgutil;
import salvage;
import local;
import loads;
import memloc;
import aa;
import tti;
import tli;
import flags;
import implied;
import ssaupdater;
import loopsimplify;
import breakcrit;
import scev;
import loopinfo;
import cycleinfo;
import memoryssa;
import mem2reg;
import ic;
import lvi;
import sccp;
import bpi;
import bfi;

fn jt_not_ported(what: const u8[:]) { fatal(str("JumpThreading: ", what, " is not ported yet")); }

let JT_WANT_INTEGER: i64 = 0;
let JT_WANT_BLOCK_ADDRESS: i64 = 1;
let JT_MDK_DBG: i32 = 0;
let JT_MDK_PROF: i32 = 2;

var jt_fn: i32 = -1;
var jt_unreach = hm_new();          // Unreachable (SmallPtrSet)
var jt_lh = hm_new();               // LoopHeaders (SmallPtrSet)
var jt_has_guards: bool = false;
var jt_bb_dup_threshold: i64 = 6;
var jt_default_threshold: i64 = 6;  // DefaultBBDupThreshold (pass parameter)
var jt_changed_since: bool = false; // ChangedSinceLastAnalysisUpdate
var jt_bpi: bool = false;           // BPI pointer set
var jt_bfi: bool = false;           // BFI pointer set
var jt_pv: i32[>..<];               // PredValueInfo pairs (constant, block)
var jt_rec = hm_new();              // RecursionSet of computeValueKnownInPredecessors
var jt_visited: i32[>..<];          // evaluateOnPredecessorEdge's Visited
var jt_q: i32 = -1;                 // BatchAAResults of simplifyPartiallyRedundantLoad

fn jt_lh_has(bb: i32) -> bool { hm_has(jt_lh, (bb as i64) as u64) }
fn jt_lh_insert(bb: i32) { hm_put(jt_lh, (bb as i64) as u64, 1); }
fn jt_lh_erase(bb: i32) -> bool { let k = (bb as i64) as u64; if !hm_has(jt_lh, k) { return false; } hm_del(jt_lh, k); return true; }
fn jt_unreach_has(bb: i32) -> bool { hm_has(jt_unreach, (bb as i64) as u64) }

fn jt_is_undef(v: i32) -> bool { v >= 0 && (vals[v].kind == VK_UNDEF || vals[v].kind == VK_POISON) }
fn jt_is_cint(v: i32) -> bool { v >= 0 && vals[v].kind == VK_CINT && !ty_is_vector(vals[v].ty) }
fn jt_preds(bb: i32, out: i32[>..<]&) { out.clear(); each_pred(bb) { p => out.push(p); }; }
fn jt_pred_empty(bb: i32) -> bool { pred_count(bb) == 0 }
fn jt_is_entry(bb: i32) -> bool { func_entry(block_func(bb)) == bb }
fn jt_has_one_use(v: i32) -> bool { let u = vals[v].first_use; return u >= 0 && uses[u].next < 0; }
fn jt_is_cond_br(t: i32) -> bool { t >= 0 && iop(t) == OP_CONDBR }
fn jt_is_uncond_br(t: i32) -> bool { t >= 0 && iop(t) == OP_BR }
// Value::DoPHITranslation(CurBB, PredBB)
fn jt_phi_translate(v: i32, cur: i32, pred: i32) -> i32 {
    if is_inst_op(v, OP_PHI) && inst_parent(v) == cur { return phi_value_for_block(v, pred); }
    return v;
}
// RAUW with the AssumptionCache's AffectedValueCallbackVH (LVI's handles are queued by rauw itself)
fn jt_rauw(old: i32, nv: i32) { ac_rauw(old, nv); rauw(old, nv); }
fn jt_copy_dl(dst: i32, src: i32) { let d = inst_get_md(src, JT_MDK_DBG); if d >= 0 { inst_set_md(dst, JT_MDK_DBG, d); } else { inst_erase_md(dst, JT_MDK_DBG); } }
// BasicBlock::isEHPad / isLandingPad
fn jt_is_eh_pad(bb: i32) -> bool { let f = first_non_phi(bb); return f >= 0 && inst_is_eh_pad(f); }
fn jt_is_landing_pad(bb: i32) -> bool { let f = first_non_phi(bb); return f >= 0 && iop(f) == OP_LANDINGPAD; }
// BasicBlock::getFirstNonPHIOrDbg(SkipPseudoOp = true)
fn jt_first_non_phi_or_dbg(bb: i32) -> i32 {
    var i = block_first(bb);
    while i >= 0 {
        if iop(i) != OP_PHI && inst_iid(i) != IID_pseudoprobe { return i; }
        i = inst_next(i);
    }
    return -1;
}
// UncondBrInst::Create(Dest, Pos) + setDebugLoc(DL of `dlfrom`)
fn jt_br_before(dest: i32, pos: i32, dlfrom: i32) -> i32 {
    let br = create_inst(OP_BR, T_VOID, [dest]);
    inst_insert_before(br, pos);
    jt_copy_dl(br, dlfrom);
    return br;
}

// ---------------------------------------------------------------------------------------------
// updatePredecessorProfileMetadata

fn jt_update_predecessor_profile_metadata(pn: i32, bb: i32) {
    let cbr = block_terminator(bb);
    if !jt_is_cond_br(cbr) { return; }
    let ok, tw, fw = pd_extract2(cbr);
    if !ok { return; }
    if tw + fw == 0 { return; }
    for i in phi_nincoming(pn) {
        let po = phi_value(pn, i);
        if !jt_is_cint(po) || ty_bits(vals[po].ty) != 1 { continue; }
        let bp = if !cint_is_zero(po) { bp_get(tw, tw + fw) } else { bp_get(fw, tw + fw) };
        // GetPredOutEdge
        var predbb = phi_block(pn, i);
        var succbb = bb;
        var visited: i32[>..<] = [];
        var found = false;
        loop {
            if jt_is_cond_br(block_terminator(predbb)) { found = true; break; }
            visited.push(predbb);
            let sp = single_pred(predbb);
            if sp < 0 { break; }
            var seen = false;
            for x in visited { if x == sp { seen = true; } }
            if seen { break; }
            succbb = predbb;
            predbb = sp;
        }
        if !found { return; }
        let pbr = block_terminator(predbb);
        let pok, ptw, pfw = pd_extract2(pbr);
        if pok { continue; }
        if bp >= bp_get(50, 100) { continue; }
        var ws: u64[2] = [0, 0];
        if term_succ(pbr, 0) == succbb { ws[0] = bp as u64; ws[1] = bp_compl(bp) as u64; }
        else { ws[0] = bp_compl(bp) as u64; ws[1] = bp as u64; }
        let unused = ptw + pfw;
        pd_set(pbr, ws, pd_has_origin(pd_prof(pbr)), false);
    }
}

// ---------------------------------------------------------------------------------------------
// run / runImpl

// JumpThreadingPass::run
fn jump_threading_run(fv: i32, threshold: i64) -> u32 {
    tti_init_function(fv, globs[glob_of(fv)].module);
    tli_cur_fn = fv;
    lvi_get(fv);
    aa_begin(fv);
    dt_get(fv, DT_DOM);
    jt_default_threshold = if threshold < 0 { flag_int("jump-threading-threshold", 6) } else { threshold };
    dtu_begin(fv, true, false, true);
    cu_dtu = true;
    jt_bpi = false;
    jt_bfi = false;
    let changed = jt_run_impl(fv);
    if !changed {
        cu_dtu = false;
        dtu_end();
        return PA_ALL;
    }
    dtu_flush();
    cu_dtu = false;
    dtu_end();
    return jt_preserved();
}
// getPreservedAnalysis
fn jt_preserved() -> u32 { ((1 as u32) << A_LVI) | ((1 as u32) << A_DOMTREE) }

// runImpl
fn jt_run_impl(fv: i32) -> bool {
    jt_fn = fv;
    let gd = lv_find_guard_decl(fv);
    jt_has_guards = gd >= 0 && vals[gd].first_use >= 0;
    if flag_given("jump-threading-threshold") { jt_bb_dup_threshold = flag_int("jump-threading-threshold", 6); }
    else if func_has_fn_attr(fv, AK_MinSize) { jt_bb_dup_threshold = 3; }
    else { jt_bb_dup_threshold = jt_default_threshold; }
    dtu_get_dt();
    hm_clear(jt_unreach);
    var b = func_entry(fv);
    while b >= 0 {
        if !dt_has_node(DT_DOM, b) { hm_put(jt_unreach, (b as i64) as u64, 1); }
        b = block_next(b);
    }
    hm_clear(jt_lh);
    if !flag_bool("jump-threading-across-loop-headers", false) { jt_find_loop_headers(fv); }
    var ever = false;
    loop {
        var changed = false;
        var bb = func_entry(fv);
        while bb >= 0 {
            if jt_unreach_has(bb) { bb = block_next(bb); continue; }
            while jt_process_block(bb) { changed = true; jt_changed_since = true; }
            if bb == func_entry(fv) || dtu_is_bb_pending_deletion(bb) { bb = block_next(bb); continue; }
            if jt_pred_empty(bb) {
                jt_lh_erase(bb);
                lvi_erase_block(bb);
                cu_delete_dead_block(bb);
                changed = true;
                jt_changed_since = true;
                bb = block_next(bb);
                continue;
            }
            let t = block_terminator(bb);
            if jt_is_uncond_br(t) {
                let succ = op(t, 0);
                let fnp = jt_first_non_phi_or_dbg(bb);
                if fnp >= 0 && is_terminator(fnp) && !jt_lh_has(bb) && !jt_lh_has(succ) &&
                   cu_try_simplify_uncond_branch_from_empty_block(bb) {
                    lvi_erase_block(bb);
                    changed = true;
                    jt_changed_since = true;
                }
            }
            bb = block_next(bb);
        }
        ever = ever || changed;
        if !changed { break; }
    }
    if ever {
        var x = func_entry(fv);
        while x >= 0 { remove_redundant_dbg_instrs(x); x = block_next(x); }
    }
    hm_clear(jt_lh);
    return ever;
}

// replaceNonLocalUsesWith
fn jt_replace_non_local_uses_with(from: i32, to: i32) -> i64 {
    let bb = inst_parent(from);
    var count: i64 = 0;
    var us: i32[>..<] = [];
    var u = vals[from].first_use;
    while u >= 0 { us.push(u); u = uses[u].next; }
    for x in us {
        if uses[x].val != from { continue; }
        if inst_parent(uses[x].user) == bb { continue; }
        use_set(x, to);
        count++;
    }
    return count;
}
// User::replaceUsesOfWith
fn jt_replace_uses_of_with(i: i32, from: i32, to: i32) -> bool {
    if from == to { return false; }
    var changed = false;
    for k in nops(i) { if op(i, k) == from { set_op(i, k, to); changed = true; } }
    return changed;
}

// replaceFoldableUses
fn jt_replace_foldable_uses(cond: i32, to: i32, known_at_end: i32) -> bool {
    var changed = false;
    if inst_parent(cond) == known_at_end { changed = jt_replace_non_local_uses_with(cond, to) > 0 || changed; }
    var i = block_last(known_at_end);
    while i >= 0 {
        // DVR.replaceVariableLocationOp(Cond, ToVal, /*AllowEmpty=*/true)
        var r = inst_first_dbg(i);
        while r >= 0 {
            if dbgrecs[r].kind as i64 != DR_LABEL { sv_replace_location_op(r, cond, to); }
            r = dbgrecs[r].next;
        }
        if i == cond { break; }
        if !guaranteed_to_transfer(i) { break; }
        changed = jt_replace_uses_of_with(i, cond, to) || changed;
        i = inst_prev(i);
    }
    if vals[cond].first_use < 0 && !inst_may_have_side_effects(cond) {
        inst_erase_from_parent(cond);
        changed = true;
    }
    return changed;
}

// getJumpThreadDuplicationCost
fn jt_duplication_cost(bb: i32, stop_at: i32, threshold0: i64) -> i64 {
    var phis: i64 = 0;
    var i = block_first(bb);
    while i >= 0 {
        if iop(i) != OP_PHI { break; }
        phis++;
        if phis > flag_int("jump-threading-phi-threshold", 76) { return 0xFFFFFFFF; }
        i = inst_next(i);
    }
    var bonus: i64 = 0;
    if block_terminator(bb) == stop_at {
        if iop(stop_at) == OP_SWITCH { bonus = 6; }
        if iop(stop_at) == OP_INDIRECTBR { bonus = 8; }
    }
    let threshold = threshold0 + bonus;
    var size: i64 = 0;
    while i != stop_at {
        if size > threshold { return size; }
        if ty_kind(vals[i].ty) == TK_TOKEN && jt_is_used_outside_of_block(i, bb) { return 0xFFFFFFFF; }
        if iop(i) == OP_CALL && (call_has_fn_attr(i, AK_NoDuplicate) || call_has_fn_attr(i, AK_Convergent)) { return 0xFFFFFFFF; }
        if tti_instruction_cost(i, TCK_SIZE_AND_LATENCY) == TCC_FREE { i = inst_next(i); continue; }
        size++;
        if iop(i) == OP_CALL {
            if !is_intrinsic_inst(i) { size += 3; }
            else if !ty_is_vector(vals[i].ty) { size += 1; }
        }
        i = inst_next(i);
    }
    return if size > bonus { size - bonus } else { 0 };
}
// Instruction::isUsedOutsideOfBlock
fn jt_is_used_outside_of_block(i: i32, bb: i32) -> bool {
    var u = vals[i].first_use;
    while u >= 0 {
        let us = uses[u].user;
        if iop(us) != OP_PHI { if inst_parent(us) != bb { return true; } }
        else if use_aux[u] != bb { return true; }
        u = uses[u].next;
    }
    return false;
}

// findLoopHeaders
fn jt_find_loop_headers(fv: i32) {
    var edges: i32[>..<] = [];
    cu_find_function_backedges(fv, edges);
    var k: i64 = 0;
    while k < edges.len { jt_lh_insert(edges[k + 1]); k += 2; }
}

// getKnownConstant
fn jt_get_known_constant(v: i32, pref: i64) -> i32 {
    if v < 0 { return -1; }
    if jt_is_undef(v) { return v; }
    if pref == JT_WANT_BLOCK_ADDRESS {
        let s = lv_strip_ptr_casts(v, false);
        if vals[s].kind == VK_BLOCKADDR { return s; }
        return -1;
    }
    if vals[v].kind == VK_CINT { return v; }
    return -1;
}

fn jt_pv_push(c: i32, bb: i32) { jt_pv.push(c); jt_pv.push(bb); }
// Move the pairs [from, end) down to `to` and truncate: the results of this call follow its sub-results
fn jt_pv_compact(to: i64, from: i64) {
    let n = jt_pv.len - from;
    for k in n { jt_pv[to + k] = jt_pv[from + k]; }
    jt_pv.resize(to + n);
}

// computeValueKnownInPredecessors: the results are the pairs jt_pv[mark..]; returns !Result.empty()
fn jt_compute_value_known_in_predecessors(v: i32, bb: i32, pref: i64, cxt: i32) -> bool {
    hm_clear(jt_rec);
    return jt_cvkip(v, bb, pref, cxt);
}

// computeValueKnownInPredecessorsImpl: appends its results at the top of jt_pv (from the length at entry)
recursive fn jt_cvkip(v: i32, bb: i32, pref: i64, cxt: i32) -> bool {
    let mark = jt_pv.len;
    let rk = (v as i64) as u64;
    if hm_has(jt_rec, rk) { return false; }
    hm_put(jt_rec, rk, 1);
    let kc = jt_get_known_constant(v, pref);
    if kc >= 0 {
        var u = vals[bb].first_use;
        while u >= 0 {
            let user = uses[u].user;
            if vals[user].kind == VK_INST && is_terminator_op(iop(user)) { jt_pv_push(kc, insts[inst_of(user)].parent); }
            u = uses[u].next;
        }
        return jt_pv.len > mark;
    }
    if !is_inst(v) || inst_parent(v) != bb {
        var u = vals[bb].first_use;
        while u >= 0 {
            let user = uses[u].user;
            u = uses[u].next;
            if vals[user].kind != VK_INST || !is_terminator_op(iop(user)) { continue; }
            let p = insts[inst_of(user)].parent;
            var pc = lvi_get_constant_on_edge(v, p, bb, cxt);
            if pc < 0 && is_inst(v) && (iop(v) == OP_ICMP || iop(v) == OP_FCMP) && is_constant(op(v, 1)) {
                pc = lvi_get_predicate_on_edge(inst_pred(v), op(v, 0), op(v, 1), p, bb, cxt);
            }
            let k2 = jt_get_known_constant(pc, pref);
            if k2 >= 0 { jt_pv_push(k2, p); }
        }
        return jt_pv.len > mark;
    }
    let i = v;
    let o = iop(i);
    if o == OP_PHI {
        for k in phi_nincoming(i) {
            let inv = phi_value(i, k);
            let ib = phi_block(i, k);
            let k1 = jt_get_known_constant(inv, pref);
            if k1 >= 0 { jt_pv_push(k1, ib); }
            else {
                let ci = lvi_get_constant_on_edge(inv, ib, bb, cxt);
                let k2 = jt_get_known_constant(ci, pref);
                if k2 >= 0 { jt_pv_push(k2, ib); }
            }
        }
        return jt_pv.len > mark;
    }
    if is_cast_op(o) {
        jt_cvkip(op(i, 0), bb, pref, cxt);
        let e1 = jt_pv.len;
        if e1 == mark { return false; }
        var k = mark;
        while k < e1 {
            let f = cf_fold_cast_operand(o, jt_pv[k], vals[i].ty);
            if f >= 0 { jt_pv_push(f, jt_pv[k + 1]); }
            k += 2;
        }
        jt_pv_compact(mark, e1);
        return jt_pv.len > mark;
    }
    if o == OP_FREEZE {
        jt_cvkip(op(i, 0), bb, pref, cxt);
        // erase_if(Result, !isGuaranteedNotToBeUndefOrPoison(first))
        var w = mark;
        var k = mark;
        while k < jt_pv.len {
            if is_guaranteed_not_to_be_undef_or_poison(jt_pv[k], -1, 0) { jt_pv[w] = jt_pv[k]; jt_pv[w + 1] = jt_pv[k + 1]; w += 2; }
            k += 2;
        }
        jt_pv.resize(w);
        return jt_pv.len > mark;
    }
    if jt_prim_bits(vals[i].ty) == 1 {
        if pref != JT_WANT_INTEGER { return false; }
        var is_or = false;
        var op0: i32 = -1;
        var op1: i32 = -1;
        if m_logical(i, false) { is_or = true; op0 = lg_a; op1 = lg_b; }
        else if m_logical(i, true) { is_or = false; op0 = lg_a; op1 = lg_b; }
        if op0 >= 0 {
            jt_cvkip(op0, bb, JT_WANT_INTEGER, cxt);
            let e1 = jt_pv.len;
            jt_cvkip(op1, bb, JT_WANT_INTEGER, cxt);
            let e2 = jt_pv.len;
            if e1 == mark && e2 == e1 { return false; }
            let interesting = if is_or { c_true() } else { c_false() };
            var lhs_bbs: i32[>..<] = [];
            var k = mark;
            while k < e1 {
                if jt_pv[k] == interesting || jt_is_undef(jt_pv[k]) {
                    jt_pv_push(interesting, jt_pv[k + 1]);
                    lhs_bbs.push(jt_pv[k + 1]);
                }
                k += 2;
            }
            k = e1;
            while k < e2 {
                if jt_pv[k] == interesting || jt_is_undef(jt_pv[k]) {
                    var seen = false;
                    for x in lhs_bbs { if x == jt_pv[k + 1] { seen = true; } }
                    if !seen { jt_pv_push(interesting, jt_pv[k + 1]); }
                }
                k += 2;
            }
            jt_pv_compact(mark, e2);
            return jt_pv.len > mark;
        }
        if o == OP_XOR && jt_is_cint(op(i, 1)) && is_one_value(op(i, 1)) {
            jt_cvkip(op(i, 0), bb, JT_WANT_INTEGER, cxt);
            if jt_pv.len == mark { return false; }
            var k = mark;
            while k < jt_pv.len { jt_pv[k] = ce_not(jt_pv[k]); k += 2; }
            return true;
        }
    } else if is_binary_op(o) {
        if pref != JT_WANT_INTEGER { return false; }
        let ci = op(i, 1);
        if vals[ci].kind == VK_CINT {
            jt_cvkip(op(i, 0), bb, JT_WANT_INTEGER, cxt);
            let e1 = jt_pv.len;
            var k = mark;
            while k < e1 {
                let f = cf_fold_binop_operands(o, jt_pv[k], ci);
                let kk = jt_get_known_constant(f, JT_WANT_INTEGER);
                if kk >= 0 { jt_pv_push(kk, jt_pv[k + 1]); }
                k += 2;
            }
            jt_pv_compact(mark, e1);
        }
        return jt_pv.len > mark;
    }
    if o == OP_ICMP || o == OP_FCMP {
        if pref != JT_WANT_INTEGER { return false; }
        let cty = vals[i].ty;
        let cl = op(i, 0);
        let cr = op(i, 1);
        let p = inst_pred(i);
        var pn: i32 = -1;
        if is_inst_op(cl, OP_PHI) { pn = cl; } else if is_inst_op(cr, OP_PHI) { pn = cr; }
        if pn >= 0 && inst_parent(pn) == bb && !jt_lh_has(bb) {
            for k in phi_nincoming(pn) {
                let pb = phi_block(pn, k);
                var l: i32 = -1;
                var r: i32 = -1;
                if pn == cl { l = phi_value(pn, k); r = jt_phi_translate(cr, bb, pb); }
                else { l = jt_phi_translate(cl, bb, pb); r = phi_value(pn, k); }
                var res = jt_simplify_cmp_dl(p, l, r);
                if res < 0 {
                    if !is_constant(r) { continue; }
                    if is_inst(l) && inst_parent(l) == bb { continue; }
                    res = lvi_get_predicate_on_edge(p, l, r, pb, bb, if cxt >= 0 { cxt } else { i });
                }
                let kk = jt_get_known_constant(res, JT_WANT_INTEGER);
                if kk >= 0 { jt_pv_push(kk, pb); }
            }
            return jt_pv.len > mark;
        }
        if is_constant(cr) && !ty_is_vector(cty) {
            if !is_inst(cl) || inst_parent(cl) != bb {
                var u = vals[bb].first_use;
                while u >= 0 {
                    let user = uses[u].user;
                    u = uses[u].next;
                    if vals[user].kind != VK_INST || !is_terminator_op(iop(user)) { continue; }
                    let pp = insts[inst_of(user)].parent;
                    let res = lvi_get_predicate_on_edge(p, cl, cr, pp, bb, if cxt >= 0 { cxt } else { i });
                    let kk = jt_get_known_constant(res, JT_WANT_INTEGER);
                    if kk >= 0 { jt_pv_push(kk, pp); }
                }
                return jt_pv.len > mark;
            }
            if vals[cr].kind == VK_CINT && is_inst_op(cl, OP_ADD) && jt_is_cint(op(cl, 1)) {
                let addl = op(cl, 0);
                let addc = op(cl, 1);
                if !is_inst(addl) || inst_parent(addl) != bb {
                    var u = vals[bb].first_use;
                    while u >= 0 {
                        let user = uses[u].user;
                        u = uses[u].next;
                        if vals[user].kind != VK_INST || !is_terminator_op(iop(user)) { continue; }
                        let pp = insts[inst_of(user)].parent;
                        var crr = lvi_get_constant_range_on_edge(addl, pp, bb, if cxt >= 0 { cxt } else { cl });
                        crr = rg_add(crr, rg_single(ci_ap(addc)));
                        let cmprange = rg_exact_icmp(p, ci_ap(cr));
                        var resc: i32 = -1;
                        if rg_contains(cmprange, crr) { resc = vl_bool_const(cty, true); }
                        else if rg_contains(rg_inverse(cmprange), crr) { resc = vl_bool_const(cty, false); }
                        else { continue; }
                        jt_pv_push(resc, pp);
                    }
                    return jt_pv.len > mark;
                }
            }
            jt_cvkip(op(i, 0), bb, JT_WANT_INTEGER, cxt);
            let e1 = jt_pv.len;
            var k = mark;
            while k < e1 {
                let f = cf_fold_cmp_operands(p, jt_pv[k], cr, -1);
                let kk = jt_get_known_constant(f, JT_WANT_INTEGER);
                if kk >= 0 { jt_pv_push(kk, jt_pv[k + 1]); }
                k += 2;
            }
            jt_pv_compact(mark, e1);
            return jt_pv.len > mark;
        }
    }
    if o == OP_SELECT {
        let tv = jt_get_known_constant(op(i, 1), pref);
        let fv = jt_get_known_constant(op(i, 2), pref);
        if tv >= 0 || fv >= 0 {
            if jt_cvkip(op(i, 0), bb, JT_WANT_INTEGER, cxt) {
                let e1 = jt_pv.len;
                var k = mark;
                while k < e1 {
                    let c = jt_pv[k];
                    var known = false;
                    if vals[c].kind == VK_CINT { known = !cint_is_zero(c); }
                    else { known = tv >= 0; }
                    let val = if known { tv } else { fv };
                    if val >= 0 { jt_pv_push(val, jt_pv[k + 1]); }
                    k += 2;
                }
                jt_pv_compact(mark, e1);
                return jt_pv.len > mark;
            }
            // the condition's (empty) results
            jt_pv.resize(mark);
        }
    }
    if cxt < 0 || inst_parent(cxt) != bb { fatal("internal: JumpThreading: CxtI should be in BB"); }
    let ci = lvi_get_constant(v, cxt);
    let kk = jt_get_known_constant(ci, pref);
    if kk >= 0 {
        var u = vals[bb].first_use;
        while u >= 0 {
            let user = uses[u].user;
            if vals[user].kind == VK_INST && is_terminator_op(iop(user)) { jt_pv_push(kk, insts[inst_of(user)].parent); }
            u = uses[u].next;
        }
    }
    return jt_pv.len > mark;
}
// Type::getPrimitiveSizeInBits (0 for non-primitive types)
fn jt_prim_bits(t: i32) -> i64 {
    if ty_is_int(t) { return ty_bits(t); }
    if ty_is_vector(t) && ty_is_int(ty_scalar(t)) && ty_kind(t) == TK_FVEC { return ty_bits(ty_scalar(t)) * ty_count(t); }
    return 0;
}
// simplifyCmpInst(Pred, LHS, RHS, {DL})
fn jt_simplify_cmp_dl(p: i64, l: i32, r: i32) -> i32 {
    let s1 = sq_no_dt; let s2 = sq_no_ac; let s3 = sq_no_tli;
    let sc = kb_cxt;
    sq_no_dt = true; sq_no_ac = true; sq_no_tli = true; kb_cxt = -1;
    let res = simplify_cmp(p, l, r, sq_new(-1), RECURSION_LIMIT);
    sq_no_dt = s1; sq_no_ac = s2; sq_no_tli = s3; kb_cxt = sc;
    return res;
}

// getBestDestForJumpOnUndef
fn jt_best_dest_for_jump_on_undef(bb: i32) -> i64 {
    let t = block_terminator(bb);
    var min_succ: i64 = 0;
    var min_preds = pred_count(term_succ(t, 0));
    for i in 1..term_nsucc(t) {
        let n = pred_count(term_succ(t, i));
        if n < min_preds { min_succ = i; min_preds = n; }
    }
    return min_succ;
}

// hasAddressTakenAndUsed
fn jt_has_address_taken_and_used(bb: i32) -> bool {
    let ba = cu_block_address(bb);
    if ba < 0 { return false; }
    sc_remove_dead_constant_users(ba);
    return vals[ba].first_use >= 0;
}

// processBlock
fn jt_process_block(bb: i32) -> bool {
    if dtu_is_bb_pending_deletion(bb) || (jt_pred_empty(bb) && !jt_is_entry(bb)) { return false; }
    if jt_maybe_merge_basic_block_into_only_pred(bb) { return true; }
    if jt_try_to_unfold_select_in_curr_bb(bb) { return true; }
    if jt_has_guards && jt_process_guards(bb) { return true; }
    var pref = JT_WANT_INTEGER;
    var cond: i32 = -1;
    let term = block_terminator(bb);
    let to = iop(term);
    if to == OP_CONDBR { cond = op(term, 0); }
    else if to == OP_SWITCH { cond = op(term, 0); }
    else if to == OP_INDIRECTBR {
        if term_nsucc(term) == 0 { return false; }
        cond = lv_strip_ptr_casts(op(term, 0), false);
        pref = JT_WANT_BLOCK_ADDRESS;
    } else {
        return false;
    }
    var folded = false;
    if is_inst(cond) {
        let sv = ic::ic_constant_fold_instruction(cond);
        if sv >= 0 {
            jt_rauw(cond, sv);
            if is_instruction_trivially_dead(cond) { inst_erase_from_parent(cond); }
            cond = sv;
            folded = true;
        }
    }
    let fi = if is_inst_op(cond, OP_FREEZE) { cond } else { -1 };
    if jt_is_undef(cond) || (fi >= 0 && jt_is_undef(op(fi, 0)) && jt_has_one_use(fi)) {
        let best = jt_best_dest_for_jump_on_undef(bb);
        var ups: DTUpdate[>..<] = [];
        let bbterm = block_terminator(bb);
        for i in term_nsucc(bbterm) {
            if i == best { continue; }
            let s = term_succ(bbterm, i);
            block_remove_predecessor(s, bb, true);
            ups.push(DTUpdate { kind: DT_DELETE, from: bb, to: s });
        }
        jt_br_before(term_succ(bbterm, best), bbterm, bbterm);
        inst_erase_from_parent(bbterm);
        dtu_apply_updates_permissive(ups);
        if fi >= 0 { inst_erase_from_parent(fi); }
        return true;
    }
    if jt_get_known_constant(cond, pref) >= 0 {
        cu_constant_fold_terminator(bb, true);
        if jt_get_bpi() { bpi_erase_block(bb); }
        return true;
    }
    if !is_inst(cond) {
        if jt_process_threadable_edges(cond, bb, pref, term) { return true; }
        return folded;
    }
    let cond_inst = cond;
    var cwf = cond_inst;
    if iop(cond_inst) == OP_FREEZE { cwf = op(cond_inst, 0); }
    if is_inst(cwf) && (iop(cwf) == OP_ICMP || iop(cwf) == OP_FCMP) {
        let cc = op(cwf, 1);
        if is_constant(cc) {
            let res = lvi_get_predicate_at(inst_pred(cwf), op(cwf, 0), cc, block_terminator(bb), false);
            if res >= 0 {
                if jt_replace_foldable_uses(cwf, res, bb) { return true; }
            }
            if jt_try_to_unfold_select_cmp(cwf, bb) { return true; }
        }
    }
    let t2 = block_terminator(bb);
    if iop(t2) == OP_SWITCH { if jt_try_to_unfold_select_switch(t2, bb) { return true; } }
    var sv = cwf;
    if is_inst(sv) && (iop(sv) == OP_ICMP || iop(sv) == OP_FCMP) && is_constant(op(sv, 1)) { sv = op(sv, 0); }
    if is_inst_op(sv, OP_LOAD) { if jt_simplify_partially_redundant_load(sv) { return true; } }
    if is_inst_op(cond_inst, OP_PHI) && inst_parent(cond_inst) == bb && jt_is_cond_br(block_terminator(bb)) {
        jt_update_predecessor_profile_metadata(cond_inst, bb);
    }
    if jt_process_threadable_edges(cond_inst, bb, pref, term) { return true; }
    if is_dead(cwf) || is_dead(cond_inst) { return false; }
    if is_inst_op(cwf, OP_PHI) && inst_parent(cwf) == bb && jt_is_cond_br(block_terminator(bb)) {
        return jt_process_branch_on_phi(cwf);
    }
    if iop(cond_inst) == OP_XOR && inst_parent(cond_inst) == bb && jt_is_cond_br(block_terminator(bb)) {
        return jt_process_branch_on_xor(cond_inst);
    }
    if jt_process_implied_condition(bb) { return true; }
    return false;
}

// processImpliedCondition
fn jt_process_implied_condition(bb: i32) -> bool {
    let bi = block_terminator(bb);
    if !jt_is_cond_br(bi) { return false; }
    var cond = op(bi, 0);
    var fic: i32 = -1;
    if is_inst_op(cond, OP_FREEZE) && jt_has_one_use(cond) { fic = cond; cond = op(fic, 0); }
    var cur = bb;
    var curpred = single_pred(bb);
    var iter: i64 = 0;
    let lim = flag_int("jump-threading-implication-search-threshold", 3);
    while curpred >= 0 && iter < lim {
        iter++;
        let pbi = block_terminator(curpred);
        if !jt_is_cond_br(pbi) { return false; }
        if term_succ(pbi, 0) != cur && term_succ(pbi, 1) != cur { return false; }
        let cond_true = term_succ(pbi, 0) == cur;
        var impl = implied_condition_v(op(pbi, 0), cond, cond_true, 0);
        if impl < 0 && fic >= 0 && is_inst_op(op(pbi, 0), OP_FREEZE) {
            if op(op(pbi, 0), 0) == op(fic, 0) { impl = if cond_true { 1 } else { 0 }; }
        }
        if impl >= 0 {
            let keep = term_succ(bi, if impl == 1 { 0 } else { 1 });
            let remove = term_succ(bi, if impl == 1 { 1 } else { 0 });
            block_remove_predecessor(remove, bb, false);
            jt_br_before(keep, bi, bi);
            inst_erase_from_parent(bi);
            if fic >= 0 { inst_erase_from_parent(fic); }
            let ups: DTUpdate[1] = [DTUpdate { kind: DT_DELETE, from: bb, to: remove }];
            dtu_apply_updates_permissive(ups);
            if jt_get_bpi() { bpi_erase_block(bb); }
            return true;
        }
        cur = curpred;
        curpred = single_pred(cur);
    }
    return false;
}

// isOpDefinedInBlock
fn jt_is_op_defined_in_block(o: i32, bb: i32) -> bool { is_inst(o) && inst_parent(o) == bb }

// findAvailablePtrLoadStore(Loc, AccessTy, AtLeastAtomic, ScanBB, ScanFrom, MaxInstsToScan, AA, IsLoadCSE,
// NumScanedInst): returns (value or -1, ScanFrom (instruction, -1 = end()), NumScanedInst)
fn jt_find_available_ptr_load_store(loc: ML, access_ty: i32, at_least_atomic: bool, scan_bb: i32, scan_from0: i32,
                                    max0: i64, nscanned0: i64) -> i32, i32, i64 {
    var max = max0;
    if max == 0 { max = 0xFFFFFFFF; }
    var nscanned = nscanned0;
    let sp = lv_strip_ptr_casts(loc.ptr, false);
    var sf = scan_from0;
    while sf != block_first(scan_bb) {
        let inst = if sf < 0 { block_last(scan_bb) } else { inst_prev(sf) };
        sf = inst;
        if ld_is_debug_or_pseudo(inst) { continue; }
        sf = inst_next(inst);
        nscanned++;
        if max == 0 { return -1, sf, nscanned; }
        max--;
        sf = inst;
        let avail = ld_get_available_load_store(inst, sp, access_ty, at_least_atomic);
        if avail >= 0 { return avail, sf, nscanned; }
        if iop(inst) == OP_STORE {
            let stp = lv_strip_ptr_casts(op(inst, 1), false);
            let a1 = is_inst_op(sp, OP_ALLOCA) || vals[sp].kind == VK_GVAR;
            let a2 = is_inst_op(stp, OP_ALLOCA) || vals[stp].kind == VK_GVAR;
            if a1 && a2 && sp != stp { continue; }
            if (jt_mod_ref(inst, loc) & MR_MOD) == 0 { continue; }
            sf = inst_next(inst);
            return -1, sf, nscanned;
        }
        if inst_may_write_memory(inst) {
            if (jt_mod_ref(inst, loc) & MR_MOD) == 0 { continue; }
            sf = inst_next(inst);
            return -1, sf, nscanned;
        }
    }
    return -1, sf, nscanned;
}
// BatchAA.getModRefInfo(I, Loc) with BatchAA.disableDominatorTree(): BasicAA's ValueTracking queries get no DT
fn jt_mod_ref(i: i32, loc: ML) -> i64 {
    let s = sq_no_dt;
    sq_no_dt = true;
    let r = aa_inst_loc_mr(i, loc, jt_q);
    sq_no_dt = s;
    return r;
}
fn jt_store_size(t: i32) -> u64 { dl_store_size(t) as u64 }

// isGuaranteedToTransferExecutionToSuccessor(Begin, End, ScanLimit = 32)
fn jt_guaranteed_to_transfer_range(b: i32, e: i32) -> bool {
    var lim: i64 = 32;
    var i = b;
    while i != e && i >= 0 {
        lim--;
        if lim == 0 { return false; }
        if !guaranteed_to_transfer(i) { return false; }
        i = inst_next(i);
    }
    return true;
}

// CastInst::CreateBitOrPointerCast(V, Ty, "", Pos)
fn jt_bit_or_pointer_cast_before(v: i32, ty: i32, pos: i32) -> i32 {
    let sp = ty_kind(ty_scalar(vals[v].ty)) == TK_PTR;
    let dp = ty_kind(ty_scalar(ty)) == TK_PTR;
    var o = OP_BITCAST;
    if sp && !dp { o = OP_PTRTOINT; } else if !sp && dp { o = OP_INTTOPTR; }
    let c = create_inst(o, ty, [v]);
    inst_insert_before(c, pos);
    return c;
}

// AAMDNodes of an instruction (tbaa, tbaa.struct, alias.scope, noalias, noalias.addrspace) and setAAMetadata
fn jt_copy_aa_metadata(dst: i32, src: i32) {
    let kinds: i32[5] = [MDK_TBAA, MDK_TBAA_STRUCT, MDK_ALIAS_SCOPE, MDK_NOALIAS, MDK_NOALIAS_ADDRSPACE];
    for k in kinds { let m = inst_get_md(src, k); if m >= 0 { inst_set_md(dst, k, m); } }
}

// simplifyPartiallyRedundantLoad
fn jt_simplify_partially_redundant_load(li: i32) -> bool {
    if !ld_is_unordered(li) { return false; }
    let lbb = inst_parent(li);
    if single_pred(lbb) >= 0 { return false; }
    if jt_is_eh_pad(lbb) { return false; }
    let lp = op(li, 0);
    if jt_is_op_defined_in_block(lp, lbb) && !is_inst_op(lp, OP_PHI) { return false; }
    let q = aq_push(CA_SIMPLE);
    aqs[q].use_dt = false;
    jt_q = q;
    let r = jt_simplify_partially_redundant_load_impl(li, lbb, lp);
    aq_pop(q);
    jt_q = -1;
    return r;
}
fn jt_simplify_partially_redundant_load_impl(li: i32, lbb: i32, lp: i32) -> bool {
    let maxs = ld_max_insts_to_scan();
    // FindAvailableLoadedValue(LoadI, LoadBB, BBIt, DefMaxInstsToScan, &BatchAA, &IsLoadCSE)
    ld_is_load_cse = false;
    let loc0 = ml_get(li);
    let avail0, bbit, ns0 = jt_find_available_ptr_load_store(loc0, vals[li].ty, ld_is_atomic(li), lbb, li, maxs, 0);
    let unused0 = ns0;
    if avail0 >= 0 {
        var avail = avail0;
        if ld_is_load_cse {
            ec_combine_metadata_for_cse(avail, li);
            lvi_forget_value(avail);
        }
        if avail == li { avail = c_poison(vals[li].ty); }
        if vals[avail].ty != vals[li].ty {
            avail = jt_bit_or_pointer_cast_before(avail, vals[li].ty, li);
            jt_copy_dl(avail, li);
        }
        jt_rauw(li, avail);
        inst_erase_from_parent(li);
        return true;
    }
    if bbit != block_first(lbb) { return false; }
    var scanned: i32[>..<] = [];
    var av_bb: i32[>..<] = [];
    var av_v: i32[>..<] = [];
    var one_unavailable: i32 = -1;
    var cse_loads: i32[>..<] = [];
    var preds: i32[>..<] = [];
    jt_preds(lbb, preds);
    let access_ty = vals[li].ty;
    for pb in preds {
        var seen = false;
        for x in scanned { if x == pb { seen = true; } }
        if seen { continue; }
        scanned.push(pb);
        var nscanned: i64 = 0;
        var loc = loc0;
        loc.ptr = jt_phi_translate(lp, lbb, pb);
        loc.size = ls_precise(jt_store_size(access_ty));
        ld_is_load_cse = false;
        let pa0, it0, ns1 = jt_find_available_ptr_load_store(loc, access_ty, ld_is_atomic(li), pb, -1, maxs, nscanned);
        var pa = pa0;
        var it = it0;
        nscanned = ns1;
        var spb = pb;
        while pa < 0 && spb >= 0 && it == block_first(spb) && nscanned < maxs {
            spb = single_pred(spb);
            if spb >= 0 {
                let pa2, it2, ns2 = jt_find_available_ptr_load_store(loc, access_ty, ld_is_atomic(li), spb, -1, maxs - nscanned, nscanned);
                pa = pa2;
                it = it2;
                nscanned = ns2;
            }
        }
        if pa < 0 { one_unavailable = pb; continue; }
        if ld_is_load_cse { cse_loads.push(pa); }
        av_bb.push(pb);
        av_v.push(pa);
    }
    if av_bb.len == 0 { return false; }
    var unavailable: i32 = -1;
    var gtt: i64 = -1;
    if scanned.len == av_bb.len + 1 && term_nsucc(block_terminator(one_unavailable)) == 1 {
        unavailable = one_unavailable;
        if !jt_can_speculate_into(li, lbb, unavailable, gtt) { return false; }
        gtt = jt_gtt_cache;
    } else if scanned.len != av_bb.len {
        var to_split: i32[>..<] = [];
        for p in preds {
            if iop(block_terminator(p)) == OP_INDIRECTBR { return false; }
            var in_av = false;
            for x in av_bb { if x == p { in_av = true; } }
            if !in_av {
                if !jt_can_speculate_into(li, lbb, p, gtt) { return false; }
                gtt = jt_gtt_cache;
                to_split.push(p);
            }
        }
        unavailable = jt_split_block_preds(lbb, to_split, "thread-pre-split");
    }
    if unavailable >= 0 {
        let nl = create_inst(OP_LOAD, vals[li].ty, [jt_phi_translate(lp, lbb, unavailable)]);
        let src = insts[inst_of(li)];
        insts[inst_of(nl)].align = src.align;
        insts[inst_of(nl)].ord = src.ord;
        insts[inst_of(nl)].ss = src.ss;
        inst_insert_before(nl, block_terminator(unavailable));
        var nm: u8[>..] = [];
        nm.append(val_name(li));
        nm.append(".pr");
        set_name(nl, nm);
        jt_copy_dl(nl, li);
        jt_copy_aa_metadata(nl, li);
        av_bb.push(unavailable);
        av_v.push(nl);
    }
    var lpreds: i32[>..<] = [];
    jt_preds(lbb, lpreds);
    let pn = new_phi(vals[li].ty, lpreds.len);
    inst_insert_before_head(pn, block_first(lbb));
    cu_take_name(pn, li);
    jt_copy_dl(pn, li);
    for p in lpreds {
        var k: i64 = -1;
        for j in av_bb.len { if av_bb[j] == p { k = j; break; } }
        if k < 0 { fatal("internal: JumpThreading: didn't find entry for predecessor"); }
        if vals[av_v[k]].ty != vals[li].ty {
            let t = block_terminator(p);
            let c = jt_bit_or_pointer_cast_before(av_v[k], vals[li].ty, t);
            if term_nsucc(t) == 1 { jt_copy_dl(c, li); }
            av_v[k] = c;
        }
        phi_add_incoming(pn, av_v[k], p);
    }
    for pl in cse_loads {
        cu_combine_metadata(pl, li, true, false);
        lvi_forget_value(pl);
    }
    jt_rauw(li, pn);
    inst_erase_from_parent(li);
    return true;
}
// CanSpeculateInto (GuaranteedToTransfer is cached across calls: gtt = -1 not computed, else 0/1)
var jt_gtt_cache: i64 = -1;
fn jt_can_speculate_into(li: i32, lbb: i32, pred: i32, gtt: i64) -> bool {
    jt_gtt_cache = gtt;
    if spec_safe(li, block_terminator(pred), false) { return true; }
    if jt_gtt_cache < 0 { jt_gtt_cache = if jt_guaranteed_to_transfer_range(block_first(lbb), li) { 1 } else { 0 }; }
    return jt_gtt_cache == 1;
}

// findMostPopularDest: dests[] parallel to preds (-1 = undef)
fn jt_find_most_popular_dest(bb: i32, dests: const i32[:]) -> i32 {
    var keys: i32[>..<] = [];
    var counts: i64[>..<] = [];
    keys.push(-1);
    counts.push(0);
    let t = block_terminator(bb);
    for k in term_nsucc(t) {
        let s = term_succ(t, k);
        var seen = false;
        for x in keys { if x == s { seen = true; } }
        if !seen { keys.push(s); counts.push(0); }
    }
    for d in dests {
        if d < 0 { continue; }
        var found = false;
        for j in keys.len { if keys[j] == d { counts[j] = counts[j] + 1; found = true; } }
        if !found { keys.push(d); counts.push(1); }
    }
    var best: i64 = 0;
    for j in keys.len { if counts[j] > counts[best] { best = j; } }
    return keys[best];
}

// evaluateOnPredecessorEdge
recursive fn jt_evaluate_on_predecessor_edge(bb: i32, ppbb: i32, v: i32) -> i32 {
    for x in jt_visited { if x == v { return -1; } }
    jt_visited.push(v);
    let r = jt_evaluate_on_predecessor_edge_impl(bb, ppbb, v);
    // scope_exit: Visited.erase(V)
    var k = jt_visited.len - 1;
    while k >= 0 { if jt_visited[k] == v { jt_visited[k] = jt_visited[jt_visited.len - 1]; jt_visited.pop(); break; } k--; }
    return r;
}
recursive fn jt_evaluate_on_predecessor_edge_impl(bb: i32, ppbb: i32, v: i32) -> i32 {
    let pbb = single_pred(bb);
    if is_constant(v) { return v; }
    if !is_inst(v) || (inst_parent(v) != bb && inst_parent(v) != pbb) {
        return lvi_get_constant_on_edge(v, ppbb, pbb, -1);
    }
    if iop(v) == OP_PHI {
        if inst_parent(v) == pbb {
            let x = phi_value_for_block(v, ppbb);
            return if x >= 0 && is_constant(x) { x } else { -1 };
        }
        return -1;
    }
    if iop(v) == OP_ICMP || iop(v) == OP_FCMP {
        if inst_parent(v) == bb {
            let op0 = jt_evaluate_on_predecessor_edge(bb, ppbb, op(v, 0));
            let op1 = jt_evaluate_on_predecessor_edge(bb, ppbb, op(v, 1));
            if op0 >= 0 && op1 >= 0 { return cf_fold_cmp_operands(inst_pred(v), op0, op1, -1); }
        }
        return -1;
    }
    return -1;
}

// processThreadableEdges
fn jt_process_threadable_edges(cond: i32, bb: i32, pref: i64, cxt: i32) -> bool {
    if jt_lh_has(bb) { return false; }
    let mark = jt_pv.len;
    if !jt_compute_value_known_in_predecessors(cond, bb, pref, cxt) {
        jt_pv.resize(mark);
        return jt_maybe_thread_through_two_basic_blocks(bb, cond);
    }
    var vals_c: i32[>..<] = [];
    var vals_b: i32[>..<] = [];
    var k = mark;
    while k < jt_pv.len { vals_c.push(jt_pv[k]); vals_b.push(jt_pv[k + 1]); k += 2; }
    jt_pv.resize(mark);
    var seen: i32[>..<] = [];
    var l_pred: i32[>..<] = [];
    var l_dest: i32[>..<] = [];
    let multiple: i32 = -2;
    var only_dest: i32 = -1;
    var only_val: i32 = -1;
    var have_first = false;
    let t = block_terminator(bb);
    for j in vals_c.len {
        let pred = vals_b[j];
        var dup = false;
        for x in seen { if x == pred { dup = true; } }
        if dup { continue; }
        seen.push(pred);
        let val = vals_c[j];
        var dest: i32 = -1;
        if jt_is_undef(val) { dest = -1; }
        else if iop(t) == OP_CONDBR { dest = term_succ(t, if cint_is_zero(val) { 1 } else { 0 }); }
        else if iop(t) == OP_SWITCH { dest = jt_switch_find_case_dest(t, val); }
        else {
            if vals[val].kind != VK_BLOCKADDR { fatal("internal: JumpThreading: expecting a constant blockaddress"); }
            dest = op(val, 1);
        }
        if !have_first {
            only_dest = dest;
            only_val = val;
            have_first = true;
        } else {
            if only_dest != dest { only_dest = multiple; }
            if val != only_val { only_val = multiple; }
        }
        if iop(block_terminator(pred)) == OP_INDIRECTBR { continue; }
        l_pred.push(pred);
        l_dest.push(dest);
    }
    if l_pred.len == 0 { return false; }
    if only_dest >= 0 {
        if pred_count(bb) == l_pred.len {
            var seen_first = false;
            var ups: DTUpdate[>..<] = [];
            for kk in term_nsucc(t) {
                let s = term_succ(t, kk);
                if s == only_dest && !seen_first { seen_first = true; }
                else {
                    block_remove_predecessor(s, bb, true);
                    ups.push(DTUpdate { kind: DT_DELETE, from: bb, to: s });
                }
            }
            jt_br_before(only_dest, t, t);
            inst_erase_from_parent(t);
            dtu_apply_updates_permissive(ups);
            if jt_get_bpi() { bpi_erase_block(bb); }
            if is_inst(cond) && !is_dead(cond) {
                if vals[cond].first_use < 0 && !inst_may_have_side_effects(cond) { inst_erase_from_parent(cond); }
                else if only_val >= 0 { jt_replace_foldable_uses(cond, only_val, bb); }
            }
            return true;
        }
    }
    var most_popular = only_dest;
    if most_popular == multiple {
        var w: i64 = 0;
        for j in l_pred.len {
            if l_dest[j] >= 0 && jt_lh_has(l_dest[j]) { continue; }
            l_pred[w] = l_pred[j];
            l_dest[w] = l_dest[j];
            w++;
        }
        l_pred.resize(w);
        l_dest.resize(w);
        if l_pred.len == 0 { return false; }
        most_popular = jt_find_most_popular_dest(bb, l_dest);
    }
    var to_factor: i32[>..<] = [];
    for j in l_pred.len {
        if l_dest[j] == most_popular {
            let pred = l_pred[j];
            let pt = block_terminator(pred);
            for kk in term_nsucc(pt) { if term_succ(pt, kk) == bb { to_factor.push(pred); } }
        }
    }
    if most_popular < 0 { most_popular = term_succ(block_terminator(bb), jt_best_dest_for_jump_on_undef(bb)); }
    return jt_try_thread_edge(bb, to_factor, most_popular);
}
// SwitchInst::findCaseValue(C)->getCaseSuccessor()
fn jt_switch_find_case_dest(si: i32, c: i32) -> i32 {
    for k in sw_ncases(si) { if sw_case_val(si, k) == c { return sw_case_dest(si, k); } }
    return sw_default(si);
}

// processBranchOnPHI
fn jt_process_branch_on_phi(pn: i32) -> bool {
    let bb = inst_parent(pn);
    for i in phi_nincoming(pn) {
        let pb = phi_block(pn, i);
        if jt_is_uncond_br(block_terminator(pb)) {
            let one: i32[1] = [pb];
            if jt_duplicate_cond_branch_on_phi_into_pred(bb, one) { return true; }
        }
    }
    return false;
}

// processBranchOnXOR
fn jt_process_branch_on_xor(bo: i32) -> bool {
    let bb = inst_parent(bo);
    if vals[op(bo, 0)].kind == VK_CINT || vals[op(bo, 1)].kind == VK_CINT { return false; }
    let f = block_first(bb);
    if iop(f) != OP_PHI { return false; }
    if jt_is_eh_pad(bb) { return false; }
    let mark = jt_pv.len;
    var is_lhs = true;
    if !jt_compute_value_known_in_predecessors(op(bo, 0), bb, JT_WANT_INTEGER, bo) {
        jt_pv.resize(mark);
        if !jt_compute_value_known_in_predecessors(op(bo, 1), bb, JT_WANT_INTEGER, bo) { jt_pv.resize(mark); return false; }
        is_lhs = false;
    }
    var xc: i32[>..<] = [];
    var xb: i32[>..<] = [];
    var k = mark;
    while k < jt_pv.len { xc.push(jt_pv[k]); xb.push(jt_pv[k + 1]); k += 2; }
    jt_pv.resize(mark);
    var nt: i64 = 0;
    var nf: i64 = 0;
    for c in xc {
        if jt_is_undef(c) { continue; }
        if cint_is_zero(c) { nf++; } else { nt++; }
    }
    var split: i32 = -1;
    if nt > nf { split = c_true(); }
    else if nt != 0 || nf != 0 { split = c_false(); }
    var fold_into: i32[>..<] = [];
    for j in xc.len {
        if xc[j] != split && !jt_is_undef(xc[j]) { continue; }
        fold_into.push(xb[j]);
    }
    if fold_into.len == phi_nincoming(block_first(bb)) {
        if split < 0 {
            jt_rauw(bo, c_undef(vals[bo].ty));
            inst_erase_from_parent(bo);
        } else if cint_is_zero(split) && bo != op(bo, if is_lhs { 1 } else { 0 }) {
            jt_rauw(bo, op(bo, if is_lhs { 1 } else { 0 }));
            inst_erase_from_parent(bo);
        } else {
            set_op(bo, if is_lhs { 0 } else { 1 }, split);
        }
        return true;
    }
    for p in fold_into { if iop(block_terminator(p)) == OP_INDIRECTBR { return false; } }
    return jt_duplicate_cond_branch_on_phi_into_pred(bb, fold_into);
}

// ValueToValueMapTy lookups (VM slot s)
fn jt_vm_find(s: i64, v: i32) -> i32 { vm_get(s, v, -1) as i32 }
fn jt_vm_set(s: i64, k: i32, v: i32) { vm_set(s, k, v as i64); }

// addPHINodeEntriesForMappedBlock
fn jt_add_phi_entries_for_mapped_block(phibb: i32, oldp: i32, newp: i32, s: i64) {
    var i = block_first(phibb);
    while i >= 0 && iop(i) == OP_PHI {
        var iv = phi_value_for_block(i, oldp);
        if is_inst(iv) { let m = jt_vm_find(s, iv); if m >= 0 { iv = m; } }
        phi_add_incoming(i, iv, newp);
        i = inst_next(i);
    }
}

// maybeMergeBasicBlockIntoOnlyPred
fn jt_maybe_merge_basic_block_into_only_pred(bb: i32) -> bool {
    let sp = single_pred(bb);
    if sp < 0 { return false; }
    let ti = block_terminator(sp);
    if cu_is_special_terminator(ti) || term_nsucc(ti) != 1 || sp == bb || jt_has_address_taken_and_used(bb) { return false; }
    if jt_unreach_has(sp) { return false; }
    if cu_has_loop_or_entry_convergence_token(bb) && cu_has_loop_or_entry_convergence_token(sp) { return false; }
    if jt_lh_erase(sp) { jt_lh_insert(bb); }
    lvi_erase_block(sp);
    cu_merge_basic_block_into_only_pred(bb);
    var all = true;
    var i = block_first(bb);
    while i >= 0 { if !guaranteed_to_transfer(i) { all = false; break; } i = inst_next(i); }
    if !all { lvi_erase_block(bb); }
    return true;
}

// updateSSA
fn jt_update_ssa(bb: i32, nbb: i32, s: i64) {
    var to_rename: i32[>..<] = [];
    var dvrs: i32[>..<] = [];
    var i = block_first(bb);
    while i >= 0 {
        let nx = inst_next(i);
        var lifetime: i32[>..<] = [];
        var u = vals[i].first_use;
        while u >= 0 {
            let user = uses[u].user;
            let nu = uses[u].next;
            if inst_is_lifetime_start_or_end(user) {
                lifetime.push(user);
            } else {
                if iop(user) == OP_PHI {
                    if use_aux[u] == bb { u = nu; continue; }
                } else if inst_parent(user) == bb { u = nu; continue; }
            }
            to_rename.push(u);
            u = nu;
        }
        dvrs.clear();
        find_dbg_values(i, dvrs);
        var w: i64 = 0;
        for k in dvrs.len { if dbg_record_block(dvrs[k]) != bb { dvrs[w] = dvrs[k]; w++; } }
        dvrs.resize(w);
        if to_rename.len == 0 && dvrs.len == 0 { i = nx; continue; }
        var nm: u8[>..] = [];
        nm.append(val_name(i));
        ssa_init(vals[i].ty, nm);
        ssa_add_available_value(bb, i);
        ssa_add_available_value(nbb, jt_vm_find(s, i));
        while to_rename.len > 0 { let x = to_rename.pop(); ssa_rewrite_use(x); }
        // SSAUpdater::UpdateDebugValues
        for r in dvrs {
            let ub = dbg_record_block(r);
            if ssa_has_value_for_block(ub) {
                let nv = ssa_get_value_at_end_of_block(ub);
                sv_replace_location_op(r, i, nv);
            } else {
                sv_set_kill_location(r);
            }
        }
        var has_phi_arg = false;
        for l in lifetime { if is_inst_op(op(l, 0), OP_PHI) { has_phi_arg = true; } }
        if has_phi_arg { for l in lifetime { inst_erase_from_parent(l); } }
        i = nx;
    }
}
// DbgRecord::getParent(): the block of the record's marker
fn dbg_record_block(r: i32) -> i32 {
    let o = dbgrecs[r].owner;
    if o >= 0 { return inst_parent(o); }
    return -2 - o;
}

// identifyNoAliasScopesToClone + cloneNoAliasScopes(..., "thread"): the scope map is the pair list `smap`
fn jt_clone_no_alias_scopes(first: i32, end: i32, smap: i32[>..<]&) {
    smap.clear();
    var i = first;
    while i >= 0 && i != end {
        if inst_iid(i) == IID_experimental_noalias_scope_decl {
            let sl = jt_scope_list(i);
            for k in mds[sl].nops as i64 {
                let md = md_op(sl, k);
                if md < 0 || !md_is_node(md) { continue; }
                // AliasScopeNode: domain = operand 1 (if an MDNode), name = operand 2 (if an MDString)
                var dom: i32 = -1;
                if mds[md].nops >= 2 { let d = md_op(md, 1); if d >= 0 && md_is_node(d) { dom = d; } }
                var nm: u8[>..] = [];
                if mds[md].nops > 2 {
                    let n = md_op(md, 2);
                    if n >= 0 && mds[n].kind == MK_STRING && sbytes(mds[n].extra).len > 0 { nm.append(sbytes(mds[n].extra)); nm.append(":"); }
                }
                nm.append("thread");
                // MDBuilder::createAnonymousAliasScope(Domain, Name) = createAnonymousAARoot(Name, Domain)
                var ops: i32[>..] = [];
                ops.push(-1);
                if dom >= 0 { ops.push(dom); }
                ops.push(md_string(nm));
                let root = md_get(MK_TUPLE, -1, ops, true);
                md_ops[mds[root].ops] = root;
                // DenseMap::insert: the first mapping of a scope wins
                var dup = false;
                var j: i64 = 0;
                while j < smap.len { if smap[j] == md { dup = true; } j += 2; }
                if !dup { smap.push(md); smap.push(root); }
            }
        }
        i = inst_next(i);
    }
}
fn jt_scope_list(decl: i32) -> i32 { vals[cb_arg(decl, 0)].sub }
fn jt_smap_lookup(smap: i32[>..<]&, md: i32) -> i32 {
    var j: i64 = 0;
    while j < smap.len { if smap[j] == md { return smap[j + 1]; } j += 2; }
    return -1;
}
// CloneScopeList: the new list or -1
fn jt_clone_scope_list(sl: i32, smap: i32[>..<]&) -> i32 {
    var need = false;
    var ops: i32[>..] = [];
    for k in mds[sl].nops as i64 {
        let md = md_op(sl, k);
        if md >= 0 && md_is_node(md) {
            let n = jt_smap_lookup(smap, md);
            if n >= 0 { ops.push(n); need = true; continue; }
            ops.push(md);
        }
    }
    if need { return md_get(MK_TUPLE, -1, ops, false); }
    return -1;
}
// adaptNoAliasScopes
fn jt_adapt_no_alias_scopes(i: i32, smap: i32[>..<]&) {
    if smap.len == 0 { return; }
    if inst_iid(i) == IID_experimental_noalias_scope_decl {
        let n = jt_clone_scope_list(jt_scope_list(i), smap);
        if n >= 0 { set_op(i, 0, get_md_as_value(n)); }
    }
    let kinds: i32[2] = [MDK_NOALIAS, MDK_ALIAS_SCOPE];
    for kd in kinds {
        let m = inst_get_md(i, kd);
        if m >= 0 {
            let n = jt_clone_scope_list(m, smap);
            if n >= 0 { inst_set_md(i, kd, n); }
        }
    }
}

// mapAtomInstance: key-instruction atom groups are not ported
fn jt_check_atom(i: i32) {
    let dl = inst_get_md(i, JT_MDK_DBG);
    if dl >= 0 && mds[dl].kind == MK_DI && di_kind(dl) == DIK_LOCATION && di_int(dl, "atomGroup") != 0 { jt_not_ported("key-instructions atom groups"); }
}

// RetargetDbgVariableRecordIfPossible
fn jt_retarget_record(r: i32, s: i64) {
    if dbgrecs[r].kind as i64 == DR_LABEL { return; }
    if dbgrecs[r].kind as i64 == DR_ASSIGN { jt_not_ported("cloning #dbg_assign records"); }
    var ls: i32[>..<] = [];
    dbg_location_ops(r, ls);
    var from: i32[>..<] = [];
    var to: i32[>..<] = [];
    for o in ls {
        if !is_inst(o) { continue; }
        let m = jt_vm_find(s, o);
        if m < 0 { continue; }
        var dup = false;
        for j in from.len { if from[j] == o && to[j] == m { dup = true; } }
        if !dup { from.push(o); to.push(m); }
    }
    if from.len > 16 { jt_not_ported("remapping more than 16 debug location operands (SmallSet order)"); }
    for j in from.len { sv_replace_location_op(r, from[j], to[j]); }
}

// cloneInstructions(ValueMapping, BI, BE, NewBB, PredBB); be = -1 is end()
fn jt_clone_instructions(s: i64, bi0: i32, be: i32, nbb: i32, pbb: i32) {
    var bi = bi0;
    let range_bb = inst_parent(bi0);
    while bi >= 0 && bi != be && iop(bi) == OP_PHI {
        let np = new_phi(vals[bi].ty, 1);
        block_append_inst(nbb, np);
        var nm: u8[>..] = [];
        nm.append(val_name(bi));
        if nm.len > 0 { set_name(np, nm); }
        phi_add_incoming(np, phi_value_for_block(bi, pbb), pbb);
        jt_vm_set(s, bi, np);
        jt_check_atom(bi);
        bi = inst_next(bi);
    }
    var smap: i32[>..<] = [];
    jt_clone_no_alias_scopes(bi, be, smap);
    while bi >= 0 && bi != be {
        let nw = inst_clone(bi);
        block_append_inst(nbb, nw);
        var nm: u8[>..] = [];
        nm.append(val_name(bi));
        if nm.len > 0 { set_name(nw, nm); }
        jt_vm_set(s, bi, nw);
        jt_adapt_no_alias_scopes(nw, smap);
        var recs: i32[>..<] = [];
        inst_clone_debug_info_from(nw, bi, -1, false, recs);
        for r in recs { jt_retarget_record(r, s); }
        jt_check_atom(nw);
        for k in nops(nw) {
            let o = op(nw, k);
            if o >= 0 && is_inst(o) {
                let m = jt_vm_find(s, o);
                if m >= 0 { set_op(nw, k, m); }
            }
        }
        bi = inst_next(bi);
    }
    if be >= 0 && inst_first_dbg(be) >= 0 {
        // EndMarker->cloneDebugInfoFrom(Marker): clones of BE's records become NewBB's trailing records
        var recs: i32[>..<] = [];
        var r = inst_first_dbg(be);
        while r >= 0 { recs.push(dbg_clone_record(r)); r = dbgrecs[r].next; }
        for k in recs.len { dbgrecs[recs[k]].next = if k + 1 < recs.len { recs[k + 1] } else { -1 }; }
        marker_absorb(nbb, -1, recs[0], false);
        for x in recs { jt_retarget_record(x, s); }
    }
    let unused = range_bb;
}

// maybethreadThroughTwoBasicBlocks
fn jt_maybe_thread_through_two_basic_blocks(bb: i32, cond: i32) -> bool {
    let cbr = block_terminator(bb);
    if !jt_is_cond_br(cbr) { return false; }
    let pbb = single_pred(bb);
    if pbb < 0 { return false; }
    let pbr = block_terminator(pbb);
    if !jt_is_cond_br(pbr) { return false; }
    if single_pred(pbb) >= 0 { return false; }
    for k in term_nsucc(pbr) { if term_succ(pbr, k) == pbb { return false; } }
    if jt_lh_has(pbb) { return false; }
    if jt_is_eh_pad(pbb) { return false; }
    var zero_count: i64 = 0;
    var one_count: i64 = 0;
    var zero_pred: i32 = -1;
    var one_pred: i32 = -1;
    var preds: i32[>..<] = [];
    jt_preds(pbb, preds);
    for p in preds {
        if iop(block_terminator(p)) == OP_INDIRECTBR { continue; }
        jt_visited.clear();
        let c = jt_evaluate_on_predecessor_edge(bb, p, cond);
        if c >= 0 && vals[c].kind == VK_CINT {
            if cint_is_zero(c) { zero_count++; zero_pred = p; }
            else if is_one_value(c) { one_count++; one_pred = p; }
        }
    }
    var ppbb: i32 = -1;
    if zero_count == 1 { ppbb = zero_pred; }
    else if one_count == 1 { ppbb = one_pred; }
    else { return false; }
    let succ = term_succ(cbr, if ppbb == zero_pred { 1 } else { 0 });
    if succ == bb { return false; }
    if jt_lh_has(bb) || jt_lh_has(succ) { return false; }
    let bbcost = jt_duplication_cost(bb, block_terminator(bb), jt_bb_dup_threshold);
    let pcost = jt_duplication_cost(pbb, block_terminator(pbb), jt_bb_dup_threshold);
    if bbcost > jt_bb_dup_threshold || pcost > jt_bb_dup_threshold || bbcost + pcost > jt_bb_dup_threshold { return false; }
    jt_thread_through_two_basic_blocks(ppbb, pbb, bb, succ);
    return true;
}

fn jt_name_plus(bb: i32, suffix: const u8[:]) -> u8[>..] {
    var nm: u8[>..] = [];
    nm.append(val_name(bb));
    nm.append(suffix);
    return nm;
}

// threadThroughTwoBasicBlocks
fn jt_thread_through_two_basic_blocks(ppbb: i32, pbb: i32, bb: i32, succ: i32) {
    let has_profile = jt_does_block_have_profile_data(bb);
    let have_bfi = jt_get_or_create_bfi(has_profile);
    let have_bpi = jt_get_or_create_bpi(have_bfi);
    let cbr = block_terminator(bb);
    let pbr = block_terminator(pbb);
    let fv = block_func(bb);
    let nbb = create_block_before(fv, pbb, jt_name_plus(pbb, ".thread"));
    block_move_after(nbb, pbb);
    if have_bfi {
        let f = bf_mul(bfi_get(ppbb), bpi_edge_prob_to(ppbb, pbb));
        bfi_set(nbb, f);
    }
    let s = VM_PASS0;
    vm_clear(s);
    jt_clone_instructions(s, block_first(pbb), -1, nbb, ppbb);
    if have_bpi { bpi_copy_edge_probabilities(pbb, nbb); }
    let ppt = block_terminator(ppbb);
    for i in term_nsucc(ppt) {
        if term_succ(ppt, i) == pbb {
            block_remove_predecessor(pbb, ppbb, true);
            term_set_succ(ppt, i, nbb);
        }
    }
    jt_add_phi_entries_for_mapped_block(term_succ(pbr, 0), pbb, nbb, s);
    jt_add_phi_entries_for_mapped_block(term_succ(pbr, 1), pbb, nbb, s);
    let ups: DTUpdate[4] = [DTUpdate { kind: DT_INSERT, from: nbb, to: term_succ(cbr, 0) },
                            DTUpdate { kind: DT_INSERT, from: nbb, to: term_succ(cbr, 1) },
                            DTUpdate { kind: DT_INSERT, from: ppbb, to: nbb },
                            DTUpdate { kind: DT_DELETE, from: ppbb, to: pbb }];
    dtu_apply_updates_permissive(ups);
    jt_update_ssa(pbb, nbb, s);
    jt_simplify_instructions_in_block(nbb);
    jt_simplify_instructions_in_block(pbb);
    let one: i32[1] = [nbb];
    jt_thread_edge(bb, one, succ);
}

// tryThreadEdge
fn jt_try_thread_edge(bb: i32, preds: const i32[:], succ: i32) -> bool {
    if succ == bb { return false; }
    if jt_lh_has(bb) || jt_lh_has(succ) { return false; }
    let cost = jt_duplication_cost(bb, block_terminator(bb), jt_bb_dup_threshold);
    if cost > jt_bb_dup_threshold { return false; }
    jt_thread_edge(bb, preds, succ);
    return true;
}

// threadEdge
fn jt_thread_edge(bb: i32, preds: const i32[:], succ: i32) {
    let has_profile = jt_does_block_have_profile_data(bb);
    let have_bfi = jt_get_or_create_bfi(has_profile);
    let have_bpi = jt_get_or_create_bpi(have_bfi);
    var pbb: i32 = -1;
    if preds.len == 1 { pbb = preds[0]; }
    else { pbb = jt_split_block_preds(bb, preds, ".thr_comm"); }
    lvi_thread_edge(pbb, bb, succ);
    let fv = block_func(bb);
    let nbb = create_block_before(fv, bb, jt_name_plus(bb, ".thread"));
    block_move_after(nbb, pbb);
    if have_bfi {
        let f = bf_mul(bfi_get(pbb), bpi_edge_prob_to(pbb, bb));
        bfi_set(nbb, f);
    }
    let s = VM_PASS0;
    vm_clear(s);
    jt_clone_instructions(s, block_first(bb), block_terminator(bb), nbb, pbb);
    let nbi = create_inst(OP_BR, T_VOID, [succ]);
    block_append_inst(nbb, nbi);
    jt_copy_dl(nbi, block_terminator(bb));
    jt_add_phi_entries_for_mapped_block(succ, bb, nbb, s);
    let pt = block_terminator(pbb);
    for i in term_nsucc(pt) {
        if term_succ(pt, i) == bb {
            block_remove_predecessor(bb, pbb, true);
            term_set_succ(pt, i, nbb);
        }
    }
    let ups: DTUpdate[3] = [DTUpdate { kind: DT_INSERT, from: nbb, to: succ },
                            DTUpdate { kind: DT_INSERT, from: pbb, to: nbb },
                            DTUpdate { kind: DT_DELETE, from: pbb, to: bb }];
    dtu_apply_updates_permissive(ups);
    jt_update_ssa(bb, nbb, s);
    jt_simplify_instructions_in_block(nbb);
    jt_update_block_freq_and_edge_weight(pbb, bb, nbb, succ, have_bfi, have_bpi, has_profile);
}

// splitBlockPreds
fn jt_split_block_preds(bb: i32, preds: const i32[:], suffix: const u8[:]) -> i32 {
    var fm_bb: i32[>..<] = [];
    var fm_f: u64[>..<] = [];
    let have_bfi = jt_get_bfi();
    if have_bfi {
        jt_get_or_create_bpi(true);
        for p in preds {
            var seen = false;
            for x in fm_bb { if x == p { seen = true; } }
            if seen { continue; }
            fm_bb.push(p);
            fm_f.push(bf_mul(bfi_get(p), bpi_edge_prob_to(p, bb)));
        }
    }
    var nbbs: i32[>..<] = [];
    if jt_is_landing_pad(bb) {
        var nm2: u8[>..] = [];
        nm2.append(suffix);
        nm2.append(".split-lp");
        nbbs.push(split_landing_pad_predecessors(bb, preds, suffix, nm2, false, false, false));
        if split_lp_nb2 >= 0 { nbbs.push(split_lp_nb2); }
    } else {
        nbbs.push(split_block_predecessors(bb, preds, suffix, false, false, false));
    }
    var ups: DTUpdate[>..<] = [];
    for nb in nbbs {
        var f: u64 = 0;
        ups.push(DTUpdate { kind: DT_INSERT, from: nb, to: bb });
        var np: i32[>..<] = [];
        jt_preds(nb, np);
        for p in np {
            ups.push(DTUpdate { kind: DT_DELETE, from: p, to: bb });
            ups.push(DTUpdate { kind: DT_INSERT, from: p, to: nb });
            if have_bfi { for j in fm_bb.len { if fm_bb[j] == p { f = bf_add(f, fm_f[j]); } } }
        }
        if have_bfi { bfi_set(nb, f); }
    }
    dtu_apply_updates_permissive(ups);
    return nbbs[0];
}

// doesBlockHaveProfileData
fn jt_does_block_have_profile_data(bb: i32) -> bool {
    let t = block_terminator(bb);
    if t < 0 || term_nsucc(t) < 2 { return false; }
    return pd_valid_md(t) >= 0;
}

// updateBlockFreqAndEdgeWeight
fn jt_update_block_freq_and_edge_weight(pbb: i32, bb: i32, nbb: i32, succ: i32, have_bfi: bool, have_bpi: bool, has_profile: bool) {
    if !have_bfi { return; }
    let orig = bfi_get(bb);
    let nf = bfi_get(nbb);
    let newf = bf_sub(orig, nf);
    bfi_set(bb, newf);
    var sfreq: u64[>..<] = [];
    let t = block_terminator(bb);
    for k in term_nsucc(t) {
        let f = bf_mul(orig, bpi_edge_prob_idx(bb, k));
        let sf = if term_succ(t, k) == succ { bf_sub(f, nf) } else { f };
        sfreq.push(sf);
    }
    var mx: u64 = 0;
    for f in sfreq { if f > mx { mx = f; } }
    var probs: u32[>..<] = [];
    if mx == 0 {
        for f in sfreq { probs.push(bp_get(1, sfreq.len as u64)); }
    } else {
        for f in sfreq { probs.push(bp_get(f, mx)); }
        bp_normalize(probs);
    }
    bpi_set_edge_probability(bb, probs);
    if probs.len >= 2 && has_profile {
        var ws: u64[>..<] = [];
        for p in probs { ws.push(p as u64); }
        pd_set(t, ws, pd_has_origin(pd_prof(t)), false);
    }
    let unused = pbb + (if have_bpi { 1 } else { 0 });
}

// SplitEdge(BB, Succ) without a DominatorTree or LoopInfo
fn jt_split_edge(bb: i32, succ: i32) -> i32 {
    let t = block_terminator(bb);
    var sn: i64 = 0;
    while term_succ(t, sn) != succ { sn++; }
    let o = ces_opts(false, false, false);
    if is_critical_edge(t, sn, false) { return split_known_critical_edge(t, sn, o, ""); }
    let sp = single_pred(succ);
    if sp >= 0 { jt_not_ported("SplitEdge through splitBlockBefore"); }
    return split_block(bb, t, "");
}

// duplicateCondBranchOnPHIIntoPred
fn jt_duplicate_cond_branch_on_phi_into_pred(bb: i32, preds: const i32[:]) -> bool {
    if jt_lh_has(bb) { return false; }
    let cost = jt_duplication_cost(bb, block_terminator(bb), jt_bb_dup_threshold);
    if cost > jt_bb_dup_threshold { return false; }
    var ups: DTUpdate[>..<] = [];
    var pbb: i32 = -1;
    if preds.len == 1 { pbb = preds[0]; }
    else { pbb = jt_split_block_preds(bb, preds, ".thr_comm"); }
    ups.push(DTUpdate { kind: DT_DELETE, from: pbb, to: bb });
    var opb = block_terminator(pbb);
    if !jt_is_uncond_br(opb) {
        let old = pbb;
        pbb = jt_split_edge(old, bb);
        ups.push(DTUpdate { kind: DT_INSERT, from: old, to: pbb });
        ups.push(DTUpdate { kind: DT_INSERT, from: pbb, to: bb });
        ups.push(DTUpdate { kind: DT_DELETE, from: old, to: bb });
        opb = block_terminator(pbb);
    }
    let s = VM_PASS0;
    vm_clear(s);
    var bi = block_first(bb);
    while bi >= 0 && iop(bi) == OP_PHI {
        jt_vm_set(s, bi, phi_value_for_block(bi, pbb));
        bi = inst_next(bi);
    }
    var smap: i32[>..<] = [];
    jt_clone_no_alias_scopes(bi, -1, smap);
    while bi >= 0 {
        var nw = inst_clone(bi);
        inst_insert_before(nw, opb);
        jt_adapt_no_alias_scopes(nw, smap);
        for k in nops(nw) {
            let o = op(nw, k);
            if o >= 0 && is_inst(o) {
                let m = jt_vm_find(s, o);
                if m >= 0 { set_op(nw, k, m); }
            }
        }
        jt_remap_debug_variable(s, nw);
        jt_check_atom(nw);
        let iv = jt_simplify_instruction_dl_tli(nw);
        if iv >= 0 {
            jt_vm_set(s, bi, iv);
            if !inst_may_have_side_effects(nw) {
                inst_erase_from_parent(nw);
                nw = -1;
                // OldPredBranch->cloneDebugInfoFrom(&*BI, std::nullopt, /*InsertAtHead=*/true)
                var recs: i32[>..<] = [];
                inst_clone_debug_info_from(opb, bi, -1, true, recs);
            }
        } else {
            jt_vm_set(s, bi, nw);
        }
        if nw >= 0 {
            var nm: u8[>..] = [];
            nm.append(val_name(bi));
            if nm.len > 0 { set_name(nw, nm); }
            var recs: i32[>..<] = [];
            inst_clone_debug_info_from(nw, bi, -1, false, recs);
            for k in nops(nw) {
                let o = op(nw, k);
                if o >= 0 && is_block(o) { ups.push(DTUpdate { kind: DT_INSERT, from: pbb, to: o }); }
            }
        }
        bi = inst_next(bi);
    }
    let bbr = block_terminator(bb);
    jt_add_phi_entries_for_mapped_block(term_succ(bbr, 0), bb, pbb, s);
    jt_add_phi_entries_for_mapped_block(term_succ(bbr, 1), bb, pbb, s);
    jt_update_ssa(bb, pbb, s);
    block_remove_predecessor(bb, pbb, true);
    inst_erase_from_parent(opb);
    if jt_get_bpi() { bpi_copy_edge_probabilities(bb, pbb); }
    dtu_apply_updates_permissive(ups);
    return true;
}
// simplifyInstruction(New, {DL, TLI, nullptr, nullptr, New}): TLI but no DT / AC
fn jt_simplify_instruction_dl_tli(i: i32) -> i32 {
    let s1 = sq_no_dt; let s2 = sq_no_ac;
    let sc = kb_cxt;
    sq_no_dt = true; sq_no_ac = true;
    let r = simplify_instruction(i);
    sq_no_dt = s1; sq_no_ac = s2; kb_cxt = sc;
    return r;
}
// remapDebugVariable(Mapping, Inst)
fn jt_remap_debug_variable(s: i64, i: i32) {
    var r = inst_first_dbg(i);
    while r >= 0 {
        let nr = dbgrecs[r].next;
        let kd = dbgrecs[r].kind as i64;
        if kd == DR_ASSIGN { jt_not_ported("remapping #dbg_assign records"); }
        if kd != DR_LABEL {
            var ls: i32[>..<] = [];
            dbg_location_ops(r, ls);
            for o in ls {
                let m = jt_vm_find(s, o);
                if m >= 0 { sv_replace_location_op(r, o, m); }
            }
        }
        r = nr;
    }
}

// SimplifyInstructionsInBlock(BB, TLI)
fn jt_simplify_instructions_in_block(bb: i32) -> bool {
    var changed = false;
    var wl: i32[>..<] = [];
    var bi = block_first(bb);
    let term = block_terminator(bb);
    while bi >= 0 && bi != term {
        let i = bi;
        bi = inst_next(bi);
        var inl = false;
        for x in wl { if x == i { inl = true; } }
        if !inl { changed = jt_simplify_and_dce_instruction(i, wl) || changed; }
    }
    while wl.len > 0 {
        let i = wl.pop();
        if is_dead(i) { continue; }
        changed = jt_simplify_and_dce_instruction(i, wl) || changed;
    }
    return changed;
}
fn jt_wl_insert(wl: i32[>..<]&, i: i32) { for x in wl { if x == i { return; } } wl.push(i); }
// simplifyAndDCEInstruction
fn jt_simplify_and_dce_instruction(i: i32, wl: i32[>..<]&) -> bool {
    if is_instruction_trivially_dead(i) {
        salvage_debug_info(i);
        for k in nops(i) {
            let o = op(i, k);
            set_op(i, k, -1);
            if o < 0 { continue; }
            if (!is_constant_data(o) && vals[o].first_use >= 0) || i == o { continue; }
            if is_constant_data(o) { continue; }
            if is_inst(o) && is_instruction_trivially_dead(o) { jt_wl_insert(wl, o); }
        }
        inst_erase_from_parent(i);
        return true;
    }
    let s1 = sq_no_dt; let s2 = sq_no_ac; let s3 = sq_no_tli;
    let sc = kb_cxt;
    sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
    let sv = simplify_instruction(i);
    sq_no_dt = s1; sq_no_ac = s2; sq_no_tli = s3; kb_cxt = sc;
    if sv >= 0 {
        var u = vals[i].first_use;
        while u >= 0 {
            let us = uses[u].user;
            if us != i { jt_wl_insert(wl, us); }
            u = uses[u].next;
        }
        var changed = false;
        if vals[i].first_use >= 0 { jt_rauw(i, sv); changed = true; }
        if is_instruction_trivially_dead(i) { inst_erase_from_parent(i); changed = true; }
        return changed;
    }
    return false;
}

// unfoldSelectInstr
fn jt_unfold_select_instr(pred: i32, bb: i32, si: i32, siuse: i32, idx: i64) {
    let pt = block_terminator(pred);
    let fv = block_func(bb);
    let nbb = create_block_before(fv, bb, "select.unfold");
    inst_remove_from_parent(pt);
    block_append_inst(nbb, pt);
    let bi = create_inst(OP_CONDBR, T_VOID, [op(si, 0), nbb, bb]);
    block_append_inst(pred, bi);
    // applyMergedLocation(PredTerm->getDebugLoc(), SI->getDebugLoc())
    jt_apply_merged_location(bi, inst_get_md(pt, JT_MDK_DBG), inst_get_md(si, JT_MDK_DBG));
    let prof = inst_get_md(si, JT_MDK_PROF);
    if prof >= 0 { inst_set_md(bi, JT_MDK_PROF, prof); }
    set_op(siuse, idx, op(si, 2));
    phi_add_incoming(siuse, op(si, 1), nbb);
    var tw: u64 = 1;
    var fw: u64 = 1;
    let ok, a, b = pd_extract2(si);
    if ok && a + b != 0 {
        tw = a;
        fw = b;
        let bp: u32[2] = [bp_get(tw, tw + fw), bp_get(fw, tw + fw)];
        if jt_get_bpi() { bpi_set_edge_probability(pred, bp); }
    } else if ok {
        tw = a;
        fw = b;
    }
    if jt_get_bfi() {
        if tw + fw == 0 { tw = 1; fw = 1; }
        let p = bp_get(tw, tw + fw);
        bfi_set(nbb, bf_mul(bfi_get(pred), p));
    }
    inst_erase_from_parent(si);
    let ups: DTUpdate[2] = [DTUpdate { kind: DT_INSERT, from: nbb, to: bb }, DTUpdate { kind: DT_INSERT, from: pred, to: nbb }];
    dtu_apply_updates_permissive(ups);
    var i = block_first(bb);
    while i >= 0 && iop(i) == OP_PHI {
        if i != siuse { phi_add_incoming(i, phi_value_for_block(i, pred), nbb); }
        i = inst_next(i);
    }
}
// Instruction::applyMergedLocation(LocA, LocB) = setDebugLoc(DebugLoc::getMergedLocation(LocA, LocB))
fn jt_apply_merged_location(i: i32, a: i32, b: i32) {
    if a < 0 || b < 0 { return; }
    if a == b { inst_set_md(i, JT_MDK_DBG, a); return; }
    jt_not_ported("DebugLoc::getMergedLocation of two different locations");
}

// tryToUnfoldSelect(SwitchInst *SI, BasicBlock *BB)
fn jt_try_to_unfold_select_switch(si: i32, bb: i32) -> bool {
    let cp = op(si, 0);
    if !is_inst_op(cp, OP_PHI) || inst_parent(cp) != bb { return false; }
    for i in phi_nincoming(cp) {
        let pred = phi_block(cp, i);
        let psi = phi_value(cp, i);
        if !is_inst_op(psi, OP_SELECT) || inst_parent(psi) != pred || !jt_has_one_use(psi) { continue; }
        if !jt_is_uncond_br(block_terminator(pred)) { continue; }
        jt_unfold_select_instr(pred, bb, psi, cp, i);
        return true;
    }
    return false;
}

// tryToUnfoldSelect(CmpInst *CondCmp, BasicBlock *BB)
fn jt_try_to_unfold_select_cmp(cc: i32, bb: i32) -> bool {
    let cbr = block_terminator(bb);
    let cl = op(cc, 0);
    let cr = op(cc, 1);
    if !jt_is_cond_br(cbr) || !is_inst_op(cl, OP_PHI) || inst_parent(cl) != bb { return false; }
    for i in phi_nincoming(cl) {
        let pred = phi_block(cl, i);
        let si = phi_value(cl, i);
        if !is_inst_op(si, OP_SELECT) || inst_parent(si) != pred || !jt_has_one_use(si) { continue; }
        if !jt_is_uncond_br(block_terminator(pred)) { continue; }
        let lr = lvi_get_predicate_on_edge(inst_pred(cc), op(si, 1), cr, pred, bb, cc);
        let rr = lvi_get_predicate_on_edge(inst_pred(cc), op(si, 2), cr, pred, bb, cc);
        if (lr >= 0 || rr >= 0) && lr != rr {
            jt_unfold_select_instr(pred, bb, si, cl, i);
            return true;
        }
    }
    return false;
}

// tryToUnfoldSelectInCurrBB
fn jt_is_unfold_candidate(si: i32, v: i32, bb: i32) -> bool {
    if inst_parent(si) != bb { return false; }
    let c = op(si, 0);
    let is_and_or = m_logical(si, true) || m_logical(si, false);
    return c == v && ty_kind(vals[c].ty) == TK_INT && ty_bits(vals[c].ty) == 1 && !is_and_or;
}
fn jt_try_to_unfold_select_in_curr_bb(bb: i32) -> bool {
    let fv = block_func(bb);
    if func_has_fn_attr(fv, AK_SanitizeMemory) { return false; }
    if jt_lh_has(bb) { return false; }
    var pn = block_first(bb);
    while pn >= 0 && iop(pn) == OP_PHI {
        var any_ci = false;
        for k in phi_nincoming(pn) { if vals[phi_value(pn, k)].kind == VK_CINT { any_ci = true; } }
        if !any_ci { pn = inst_next(pn); continue; }
        var si: i32 = -1;
        var u = vals[pn].first_use;
        while u >= 0 {
            let user = uses[u].user;
            let opno = (u - vals[user].ops) as i64;
            if is_inst_op(user, OP_ICMP) {
                if inst_parent(user) == bb && jt_has_one_use(user) && vals[op(user, 1 - opno)].kind == VK_CINT {
                    let su = uses[vals[user].first_use].user;
                    if is_inst_op(su, OP_SELECT) && jt_is_unfold_candidate(su, uses[vals[user].first_use].val, bb) { si = su; break; }
                }
            } else if is_inst_op(user, OP_SELECT) {
                if jt_is_unfold_candidate(user, uses[u].val, bb) { si = user; break; }
            }
            u = uses[u].next;
        }
        if si < 0 { pn = inst_next(pn); continue; }
        var cond = op(si, 0);
        if !is_guaranteed_not_to_be_undef_or_poison(cond, si, 0) {
            let fr = create_inst(OP_FREEZE, vals[cond].ty, [cond]);
            inst_insert_before(fr, si);
            set_name(fr, "cond.fr");
            cond = fr;
        }
        let bw = pd_branch_weight_md(si);
        let term = jt_split_block_and_insert_if_then(cond, si, bw);
        let split_bb = inst_parent(si);
        let nbb = inst_parent(term);
        let npn = new_phi(vals[si].ty, 2);
        inst_insert_before(npn, si);
        phi_add_incoming(npn, op(si, 1), nbb);
        phi_add_incoming(npn, op(si, 2), bb);
        jt_copy_dl(npn, si);
        jt_rauw(si, npn);
        let have_bpi = jt_get_bpi();
        let have_bfi = jt_get_bfi();
        if bw >= 0 && !flag_bool("profcheck-disable-metadata-fixes", false) {
            var ws: u64[>..<] = [];
            pd_extract_md(bw, ws);
            let den = ws[0] + ws[1];
            let tp = bp_get(ws[0], den);
            let fp = bp_get(ws[1], den);
            let bp: u32[2] = [tp, fp];
            if have_bpi { bpi_set_edge_probability(bb, bp); }
            if have_bfi {
                let orig = bfi_get(bb);
                bfi_set(nbb, bf_mul(orig, tp));
                bfi_set(split_bb, orig);
            }
        }
        inst_erase_from_parent(si);
        var ups: DTUpdate[>..<] = [];
        ups.push(DTUpdate { kind: DT_INSERT, from: bb, to: split_bb });
        ups.push(DTUpdate { kind: DT_INSERT, from: bb, to: nbb });
        ups.push(DTUpdate { kind: DT_INSERT, from: nbb, to: split_bb });
        let st = block_terminator(split_bb);
        for k in term_nsucc(st) {
            let s = term_succ(st, k);
            ups.push(DTUpdate { kind: DT_DELETE, from: bb, to: s });
            ups.push(DTUpdate { kind: DT_INSERT, from: split_bb, to: s });
        }
        dtu_apply_updates_permissive(ups);
        return true;
    }
    return false;
}
// getBranchWeightMDNode(I): the !prof node if it is branch_weights (with the right count), else -1
fn pd_branch_weight_md(i: i32) -> i32 {
    let m = pd_prof(i);
    if !pd_is_branch_weight_md(m) { return -1; }
    return m;
}

// SplitBlockAndInsertIfThen(Cond, SplitBefore, Unreachable = false, BranchWeights) without DTU / LoopInfo
fn jt_split_block_and_insert_if_then(cond: i32, split_before: i32, bw: i32) -> i32 {
    let head = inst_parent(split_before);
    let fv = block_func(head);
    let tail = split_block(head, split_before, "");
    let tb = create_block_before(fv, tail, "");
    let br = create_inst(OP_BR, T_VOID, [tail]);
    block_append_inst(tb, br);
    jt_copy_dl(br, split_before);
    let old = block_terminator(head);
    let nt = create_inst(OP_CONDBR, T_VOID, [cond, tb, tail]);
    if bw >= 0 { inst_set_md(nt, JT_MDK_PROF, bw); }
    // ReplaceInstWithInst: copy the debug location if the new one has none
    if inst_get_md(nt, JT_MDK_DBG) < 0 { let d = inst_get_md(old, JT_MDK_DBG); if d >= 0 { inst_set_md(nt, JT_MDK_DBG, d); } }
    inst_insert_before(nt, old);
    jt_rauw(old, nt);
    inst_erase_from_parent(old);
    return br;
}

// processGuards
fn jt_process_guards(bb: i32) -> bool {
    var preds: i32[>..<] = [];
    jt_preds(bb, preds);
    if preds.len != 2 { return false; }
    let p1 = preds[0];
    let p2 = preds[1];
    if p1 == p2 { return false; }
    let parent = single_pred(p1);
    if parent < 0 || parent != single_pred(p2) { return false; }
    let bi = block_terminator(parent);
    if jt_is_cond_br(bi) {
        var i = block_first(bb);
        while i >= 0 {
            let nx = inst_next(i);
            if inst_iid(i) == IID_experimental_guard && jt_thread_guard(bb, i, bi) { return true; }
            i = nx;
        }
    }
    return false;
}

// threadGuard
fn jt_thread_guard(bb: i32, grd: i32, bi: i32) -> bool {
    let gc = cb_arg(grd, 0);
    let bc = op(bi, 0);
    let td = term_succ(bi, 0);
    let fd = term_succ(bi, 1);
    var t_safe = false;
    var f_safe = false;
    let impl1 = implied_condition_v(bc, gc, true, 0);
    if impl1 == 1 { t_safe = true; }
    else {
        let impl2 = implied_condition_v(bc, gc, false, 0);
        if impl2 == 1 { f_safe = true; }
    }
    if !t_safe && !f_safe { return false; }
    let unguarded_pred = if t_safe { td } else { fd };
    let guarded_pred = if f_safe { td } else { fd };
    let after = inst_next(grd);
    let cost = jt_duplication_cost(bb, after, jt_bb_dup_threshold);
    if cost > jt_bb_dup_threshold { return false; }
    vm_clear(VM_PASS0);
    vm_clear(VM_PASS1);
    let gb = jt_duplicate_instructions_in_split_between(bb, guarded_pred, after, VM_PASS1);
    let ub = jt_duplicate_instructions_in_split_between(bb, unguarded_pred, grd, VM_PASS0);
    var to_remove: i32[>..<] = [];
    var x = block_first(bb);
    while x >= 0 && x != after { if iop(x) != OP_PHI { to_remove.push(x); } x = inst_next(x); }
    let ins = first_insertion_pt(bb);
    var k = to_remove.len - 1;
    while k >= 0 {
        let inst = to_remove[k];
        if vals[inst].first_use >= 0 {
            let npn = new_phi(vals[inst].ty, 2);
            phi_add_incoming(npn, jt_vm_find(VM_PASS0, inst), ub);
            phi_add_incoming(npn, jt_vm_find(VM_PASS1, inst), gb);
            jt_copy_dl(npn, inst);
            inst_insert_before_head(npn, ins);
            jt_rauw(inst, npn);
        }
        cu_drop_dbg_records(inst);
        inst_erase_from_parent(inst);
        k--;
    }
    return true;
}
// BasicBlock::getFirstInsertionPt
fn first_insertion_pt(bb: i32) -> i32 {
    var i = block_first(bb);
    while i >= 0 && (iop(i) == OP_PHI || inst_is_eh_pad(i)) { i = inst_next(i); }
    return i;
}

// DuplicateInstructionsInSplitBetween(BB, PredBB, StopAt, ValueMapping, DTU)
fn jt_duplicate_instructions_in_split_between(bb: i32, pbb: i32, stop_at: i32, s: i64) -> i32 {
    var bi = block_first(bb);
    while bi >= 0 && iop(bi) == OP_PHI { jt_vm_set(s, bi, phi_value_for_block(bi, pbb)); bi = inst_next(bi); }
    let nbb = jt_split_edge(pbb, bb);
    set_name(nbb, jt_name_plus(pbb, ".split"));
    let nterm = block_terminator(nbb);
    let ups: DTUpdate[3] = [DTUpdate { kind: DT_DELETE, from: pbb, to: bb }, DTUpdate { kind: DT_INSERT, from: pbb, to: nbb },
                            DTUpdate { kind: DT_INSERT, from: nbb, to: bb }];
    dtu_apply_updates(ups);
    while stop_at != bi && block_terminator(bb) != bi {
        let nw = inst_clone(bi);
        inst_insert_before(nw, nterm);
        var nm: u8[>..] = [];
        nm.append(val_name(bi));
        if nm.len > 0 { set_name(nw, nm); }
        var recs: i32[>..<] = [];
        inst_clone_debug_info_from(nw, bi, -1, false, recs);
        jt_vm_set(s, bi, nw);
        for k in nops(nw) {
            let o = op(nw, k);
            if o >= 0 && is_inst(o) { let m = jt_vm_find(s, o); if m >= 0 { set_op(nw, k, m); } }
        }
        jt_remap_debug_variable(s, nw);
        bi = inst_next(bi);
    }
    return nbb;
}

// ---------------------------------------------------------------------------------------------
// BPI / BFI (runExternalAnalysis, getBPI, getBFI, getOrCreateBPI, getOrCreateBFI)

// runExternalAnalysis<BranchProbabilityAnalysis / BlockFrequencyAnalysis>
fn jt_run_external_analysis(want_bfi: bool) {
    if jt_changed_since {
        jt_changed_since = false;
        // FAM->invalidate(*F, PA): everything but LVI, DT, BPI and BFI
        li_invalidate(jt_fn);
        ci_invalidate(jt_fn);
        dt_invalidate(jt_fn, DT_POST);
        mssa_invalidate(jt_fn);
        scev_invalidate(jt_fn);
        dtu_flush();
    }
    if want_bfi { bfi_compute(jt_fn); } else { bpi_compute(jt_fn); }
    tti_init_function(jt_fn, globs[glob_of(jt_fn)].module);
    tli_cur_fn = jt_fn;
}
// getBPI: the cached result
fn jt_get_bpi() -> bool {
    if !jt_bpi { jt_bpi = bpi_valid(jt_fn); }
    return jt_bpi;
}
fn jt_get_bfi() -> bool {
    if !jt_bfi { jt_bfi = bfi_valid(jt_fn); }
    return jt_bfi;
}
fn jt_get_or_create_bpi(force: bool) -> bool {
    if jt_get_bpi() { return true; }
    if force { jt_run_external_analysis(false); jt_bpi = true; }
    return jt_bpi;
}
fn jt_get_or_create_bfi(force: bool) -> bool {
    if jt_get_bfi() { return true; }
    if force { jt_run_external_analysis(true); jt_bfi = true; }
    return jt_bfi;
}
