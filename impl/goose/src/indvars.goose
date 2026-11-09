// IndVarSimplify (indvars) and the LoopUtils / Local helpers it uses.
// Port of llvm/lib/Transforms/Scalar/IndVarSimplify.cpp (LLVM 23.1.5): the floating-point IV rewrite
// (ConvertToSInt, isRepresentableAsExactInteger, getIntegerPredicate, maybeFloatingPointRecurrence,
// tryConvertToIntegerIV, canonicalizeToIntegerIV, handleFloatingPointIV, rewriteNonIntegerIVs),
// rewriteFirstIterationLoopExitValues, simplifyAndExtend (visitIVCast is in simplify_indvar.goose), LFTR
// (getLoopPhiForCounter, isLoopExitTestBasedOn, needsLFTR, hasConcreteDef(Impl), isLoopCounter, FindLoopCounter,
// genLoopLimit, linearFunctionTestReplace), sinkUnusedInvariants, replaceExitCond, createFoldedExitCond, foldExit,
// replaceLoopPHINodesWithPreheaderValues, createInvariantCond, createReplacement,
// optimizeLoopExitWithUnknownExitCount, canonicalizeExitCondition, optimizeLoopExits, crashingBBWithoutEffect,
// predicateLoopExits, IndVarSimplify::run and IndVarSimplifyPass::run.
// From llvm/lib/Transforms/Utils/LoopUtils.cpp: isAlmostDeadIV, hasHardUserWithinLoop, canLoopBeDeleted,
// rewriteLoopExitValues. From llvm/lib/Transforms/Utils/Local.cpp: RecursivelyDeleteTriviallyDeadInstructions (one
// value and a worklist, with a MemorySSAUpdater), areAllUsesEqual, RecursivelyDeleteDeadPHINode; from
// BasicBlockUtils.cpp: DeleteDeadPHIs. From llvm/lib/Analysis/ValueTracking.cpp: mustExecuteUBIfPoisonOnPathTo.
// Not ported (fails loudly): -replexitval=unusedindvarinloop (InductionDescriptor::isInductionPHI).
import std;
import ir;
import irutil;
import instinfo;
import calls;
import pm;
import gen_iids;
import intrinsics;
import gen_attrs;
import memloc;
import constfold;
import cfold;
import apfloat;
import datalayout;
import apint;
import constrange;
import poison;
import local;
import salvage;
import instsimplify;
import analyses;
import loopinfo;
import loopsimplify;
import loopnest;
import domtree;
import memoryssa;
import mssaupdater;
import tli;
import tti;
import flags;
import wvh;
import stdsort;
import scev;
import scev_create;
import scev_range;
import scev_eval;
import scev_btc;
import scev_pred;
import scev_update;
import scev_expander;
import simplify_indvar;

// ReplaceExitVal
let REPL_NEVER: i64 = 0;
let REPL_CHEAP: i64 = 1;
let REPL_UNUSED_IV: i64 = 2;
let REPL_NO_HARD_USE: i64 = 3;
let REPL_ALWAYS: i64 = 4;

var ivs_mssau: bool = false;          // MSSAU (loop-mssa)
var ivs_unswitch: bool = false;       // RunUnswitching
var ivs_replexitval: i64 = REPL_CHEAP;

fn ivs_read_flags() {
    let v = flag_str("replexitval");
    if v == "" || v == "cheap" { ivs_replexitval = REPL_CHEAP; }
    else if v == "never" { ivs_replexitval = REPL_NEVER; }
    else if v == "unusedindvarinloop" { ivs_replexitval = REPL_UNUSED_IV; }
    else if v == "noharduse" { ivs_replexitval = REPL_NO_HARD_USE; }
    else if v == "always" { ivs_replexitval = REPL_ALWAYS; }
    else { fatal(str("opt: for the --replexitval option: Cannot find option named '", v, "'!")); }
}

// ---------------------------------------------------------------------------------------------
// Local.cpp / BasicBlockUtils.cpp deletion helpers

// RecursivelyDeleteTriviallyDeadInstructions(DeadInsts, TLI, MSSAU) over a worklist of instruction ids
fn ivs_delete_dead_worklist(wl: i32[>..<]&) {
    while wl.len > 0 {
        let i = wl.pop();
        if i < 0 || is_dead(i) { continue; }
        salvage_debug_info(i);
        for k in nops(i) {
            let ov = op(i, k);
            set_op(i, k, -1);
            if ov < 0 || !has_use_list(ov) || vals[ov].first_use >= 0 { continue; }
            if is_inst(ov) && is_instruction_trivially_dead(ov) { wl.push(ov); }
        }
        if ivs_mssau { msu_remove_inst_access(i, false); }
        inst_erase_from_parent(i);
    }
}
// RecursivelyDeleteTriviallyDeadInstructions(V, TLI, MSSAU)
fn ivs_recursively_delete_trivially_dead(v: i32) -> bool {
    if !is_inst(v) || !is_instruction_trivially_dead(v) { return false; }
    var wl: i32[>..<] = [];
    wl.push(v);
    ivs_delete_dead_worklist(wl);
    return true;
}
// areAllUsesEqual
fn ivs_all_uses_equal(i: i32) -> bool {
    var u = vals[i].first_use;
    if u < 0 { return true; }
    let the = uses[u].user;
    u = uses[u].next;
    while u >= 0 { if uses[u].user != the { return false; } u = uses[u].next; }
    return true;
}
// RecursivelyDeleteDeadPHINode(PN, TLI, MSSAU)
fn ivs_recursively_delete_dead_phi(pn: i32) -> bool {
    var visited = hm_new();
    var i = pn;
    while ivs_all_uses_equal(i) && !inst_may_have_side_effects(i) {
        if vals[i].first_use < 0 { return ivs_recursively_delete_trivially_dead(i); }
        if hm_has(visited, i as u64) {
            rauw(i, c_poison(vals[i].ty));
            ivs_recursively_delete_trivially_dead(i);
            return true;
        }
        hm_put(visited, i as u64, 1);
        i = uses[vals[i].first_use].user;
    }
    return false;
}
// DeleteDeadPHIs(BB, TLI, MSSAU)
fn ivs_delete_dead_phis(bb: i32) -> bool {
    let mark = wvh_mark();
    var hs: i32[>..<] = [];
    var p = block_first(bb);
    while p >= 0 && iop(p) == OP_PHI { hs.push(wvh_new(p, WVH_WEAK_TRACKING)); p = inst_next(p); }
    var changed = false;
    for h in hs {
        let v = wvh_get(h);
        if v >= 0 && is_phi(v) { if ivs_recursively_delete_dead_phi(v) { changed = true; } }
    }
    wvh_release(mark);
    return changed;
}

// mustExecuteUBIfPoisonOnPathTo(Root, OnPathTo, DT): KnownPoison is the scratch set VS_ANA1
fn ivs_must_execute_ub_if_poison_on_path_to(root: i32, on_path_to: i32) -> bool {
    var known = hm_new();
    var wl: i32[>..<] = [];
    wl.push(root);
    while wl.len > 0 {
        let i = wl.pop();
        // mustTriggerUB(I, KnownPoison)
        vs_clear(VS_ANA1);
        for k in known.slots.len {
            let key = known.slots[k].key;
            if key != HM_EMPTY && key != HM_TOMB { vs_add(VS_ANA1, key as i32); }
        }
        if well_defined_ops_contain(i, true, -1, true) && dt_value_dominates_inst(i, on_path_to) { return true; }
        if i != root {
            var any = false;
            for k in nops(i) { if hm_has(known, op(i, k) as u64) && propagates_poison(i, k) { any = true; break; } }
            if !any { continue; }
        }
        if !hm_has(known, i as u64) {
            hm_put(known, i as u64, 1);
            var u = vals[i].first_use;
            while u >= 0 { wl.push(uses[u].user); u = uses[u].next; }
        }
    }
    return false;
}

// Loop::getUniqueExitBlocks
fn ivs_unique_exit_blocks(l: i32, out: i32[>..<]&) {
    out.clear();
    for i in loop_nblocks(l) {
        let t = block_terminator(loop_block(l, i));
        if t < 0 { continue; }
        for k in term_nsucc(t) {
            let s = term_succ(t, k);
            if loop_contains(l, s) || position(out, s) >= 0 { continue; }
            out.push(s);
        }
    }
}

// ---------------------------------------------------------------------------------------------
// rewriteNonIntegerIVs

// ConvertToSInt(APF, IntVal): (ok, value)
fn ivs_convert_to_sint(c: i32) -> bool, i64 {
    let r = cf_sse_convert_to_int(c, T_I64, false, true);
    if r < 0 || vals[r].kind != VK_CINT { return false, 0; }
    return true, ci_sval(r);
}
// isRepresentableAsExactInteger(FPVal, IntVal)
fn ivs_representable_exact(c: i32, x: i64) -> bool {
    let k = types[vals[c].ty].kind as i64;
    if k != TK_HALF && k != TK_BFLOAT && k != TK_FLOAT && k != TK_DOUBLE && k != TK_FP128 { return false; }
    let prec = fp_fmt(k).p;
    let a: u64 = if x < 0 { (0 as u64) - (x as! u64) } else { x as u64 };
    if prec >= 64 { return true; }
    return a < ((1 as u64) << (prec as u64));
}
// getIntegerPredicate(FPPred): -1 = BAD_ICMP_PREDICATE
fn ivs_integer_predicate(p: i64) -> i64 {
    // FCMP_OEQ 1, OGT 2, OGE 3, OLT 4, OLE 5, ONE 6, UEQ 9, UGT 10, UGE 11, ULT 12, ULE 13, UNE 14
    if p == 1 || p == 9 { return P_EQ; }
    if p == 6 || p == 14 { return P_NE; }
    if p == 2 || p == 10 { return P_SGT; }
    if p == 3 || p == 11 { return P_SGE; }
    if p == 4 || p == 12 { return P_SLT; }
    if p == 5 || p == 13 { return P_SLE; }
    return -1;
}
fn ivs_is_cfp(v: i32) -> bool { v >= 0 && vals[v].kind == VK_CFP }
fn ivs_fits_i32(x: i64) -> bool { x >= -2147483648 && x <= 2147483647 }

// handleFloatingPointIV(L, PN): maybeFloatingPointRecurrence, tryConvertToIntegerIV, canonicalizeToIntegerIV
fn ivs_handle_floating_point_iv(l: i32, pn: i32) -> bool {
    let ie: i64 = if loop_contains(l, phi_block(pn, 0)) { 1 } else { 0 };
    let be = ie ^ 1;
    // maybeFloatingPointRecurrence
    let initv = phi_value(pn, ie);
    if !ivs_is_cfp(initv) { return false; }
    let incr = phi_value(pn, be);
    if !is_inst(incr) || iop(incr) != OP_FADD { return false; }
    let incv = op(incr, 1);
    if !ivs_is_cfp(incv) || op(incr, 0) != pn { return false; }
    var nu = 0;
    var u = vals[incr].first_use;
    while u >= 0 { nu++; u = uses[u].next; }
    if nu != 2 { return false; }
    var cmp: i32 = -1;
    u = vals[incr].first_use;
    while u >= 0 { let x = uses[u].user; if is_inst(x) && iop(x) == OP_FCMP { cmp = x; break; } u = uses[u].next; }
    if cmp < 0 { return false; }
    let cu = vals[cmp].first_use;
    if cu < 0 || uses[cu].next >= 0 { return false; }
    let bi = uses[cu].user;
    if !is_inst(bi) || iop(bi) != OP_CONDBR { return false; }
    if !loop_contains(l, inst_parent(bi)) || (loop_contains(l, term_succ(bi, 0)) && loop_contains(l, term_succ(bi, 1))) { return false; }
    let exitv = op(cmp, 1);
    if !ivs_is_cfp(exitv) { return false; }
    // tryConvertToIntegerIV
    let np = ivs_integer_predicate(insts[inst_of(cmp)].pred as i64);
    if np < 0 { return false; }
    let ok1, iv0 = ivs_convert_to_sint(initv);
    if !ok1 { return false; }
    let ok2, ic = ivs_convert_to_sint(incv);
    if !ok2 { return false; }
    let ok3, ev = ivs_convert_to_sint(exitv);
    if !ok3 { return false; }
    if !ivs_representable_exact(initv, iv0) || !ivs_representable_exact(exitv, ev) { return false; }
    if !ivs_fits_i32(iv0) || !ivs_fits_i32(ic) || !ivs_fits_i32(ev) { return false; }
    if ic == 0 { return false; }
    if ic > 0 {
        if iv0 >= ev { return false; }
        var range = ((ev - iv0) as! u64) & 0xFFFFFFFF;
        if np == P_SLE || np == P_SGT {
            range = (range + 1) & 0xFFFFFFFF;
            if range == 0 { return false; }
        }
        let left = range % ((ic as! u64) & 0xFFFFFFFF);
        if (np == P_EQ || np == P_NE) && left != 0 { return false; }
        if left != 0 && sext64(((ev + ic) as! u64) & 0xFFFFFFFF, 32) < ev { return false; }
    } else {
        if iv0 <= ev { return false; }
        var range = ((iv0 - ev) as! u64) & 0xFFFFFFFF;
        if np == P_SGE || np == P_SLT {
            range = (range + 1) & 0xFFFFFFFF;
            if range == 0 { return false; }
        }
        let left = range % (((0 - ic) as! u64) & 0xFFFFFFFF);
        if (np == P_EQ || np == P_NE) && left != 0 { return false; }
        if left != 0 && sext64(((ev + ic) as! u64) & 0xFFFFFFFF, 32) > ev { return false; }
    }
    // canonicalizeToIntegerIV
    let i32t = T_I32;
    let nphi = new_inst(OP_PHI, i32t, 2);
    vals[nphi].nops = 0;
    inst_insert_before(nphi, pn);
    let nm1 = iv_name_plus(pn, ".int");
    set_name(nphi, nm1);
    phi_add_incoming(nphi, c_int_ty_s(i32t, iv0), phi_block(pn, ie));
    let pdl = inst_get_md(pn, 0);
    if pdl >= 0 { inst_set_md(nphi, 0, pdl); }
    let nadd = create_inst(OP_ADD, i32t, [nphi, c_int_ty_s(i32t, ic)]);
    inst_insert_before(nadd, incr);
    let nm2 = iv_name_plus(incr, ".int");
    set_name(nadd, nm2);
    let idl = inst_get_md(incr, 0);
    if idl >= 0 { inst_set_md(nadd, 0, idl); }
    phi_add_incoming(nphi, nadd, phi_block(pn, be));
    let ncmp = create_inst(OP_ICMP, T_I1, [nadd, c_int_ty_s(i32t, ev)]);
    insts[inst_of(ncmp)].pred = np as u8;
    inst_insert_before(ncmp, bi);
    let nm3 = iv_name_plus(cmp, "");
    set_name(ncmp, nm3);
    let cdl = inst_get_md(cmp, 0);
    if cdl >= 0 { inst_set_md(ncmp, 0, cdl); }
    let mark = wvh_mark();
    let weak_ph = wvh_new(pn, WVH_WEAK_TRACKING);
    // NewCompare->takeName(Compare)
    set_name(cmp, "");
    set_name(ncmp, nm3);
    rauw(cmp, ncmp);
    ivs_recursively_delete_trivially_dead(cmp);
    rauw(incr, c_poison(vals[incr].ty));
    ivs_recursively_delete_trivially_dead(incr);
    if wvh_get(weak_ph) >= 0 {
        let conv = create_inst(OP_SITOFP, vals[pn].ty, [nphi]);
        let fi = sx_first_insertion_pt(inst_parent(pn));
        inst_insert_at(conv, inst_parent(pn), fi.pos, true);
        set_name(conv, "indvar.conv");
        if pdl >= 0 { inst_set_md(conv, 0, pdl); }
        rauw(pn, conv);
        ivs_recursively_delete_trivially_dead(pn);
    }
    wvh_release(mark);
    return true;
}

// rewriteNonIntegerIVs(L)
fn ivs_rewrite_non_integer_ivs(l: i32) -> bool {
    let mark = wvh_mark();
    var hs: i32[>..<] = [];
    var p = block_first(loop_header(l));
    while p >= 0 && iop(p) == OP_PHI { hs.push(wvh_new(p, WVH_WEAK_TRACKING)); p = inst_next(p); }
    var changed = false;
    for h in hs {
        let pn = wvh_get(h);
        if pn >= 0 && is_phi(pn) { if ivs_handle_floating_point_iv(l, pn) { changed = true; } }
    }
    wvh_release(mark);
    if changed { sc_forget_loop(l); }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// rewriteFirstIterationLoopExitValues

fn ivs_rewrite_first_iteration_loop_exit_values(l: i32) -> bool {
    var exits: i32[>..<] = [];
    ivs_unique_exit_blocks(l, exits);
    var made = false;
    for eb in exits {
        var pn = block_first(eb);
        while pn >= 0 && iop(pn) == OP_PHI {
            for idx in nops(pn) {
                let ibb = phi_block(pn, idx);
                let latch = loop_latch(l);
                if latch < 0 || !dt_dominates_block(DT_DOM, ibb, latch) { continue; }
                let t = block_terminator(ibb);
                var cond: i32 = -1;
                if iop(t) == OP_CONDBR || iop(t) == OP_SWITCH { cond = op(t, 0); } else { continue; }
                if !sx_loop_invariant_v(l, cond) { continue; }
                let ev = phi_value(pn, idx);
                if !is_phi(ev) || inst_parent(ev) != loop_header(l) { continue; }
                let ph = loop_preheader(l);
                let pi = phi_block_index(ev, ph);
                if pi != -1 {
                    made = true;
                    set_op(pn, idx, phi_value(ev, pi));
                    sc_forget_value(pn);
                }
            }
            pn = inst_next(pn);
        }
    }
    return made;
}

// ---------------------------------------------------------------------------------------------
// simplifyAndExtend

struct WideIVInfo { narrow: i32, widest: i32, signed: bool }

fn ivs_simplify_and_extend(l: i32) -> bool {
    var wides: WideIVInfo[>..<] = [];
    var has_guards = false;
    var f = modules[globs[glob_of(block_func(loop_header(l)))].module].first_func;
    while f >= 0 {
        if func_iid(f) == IID_experimental_guard && vals[f].first_use >= 0 { has_guards = true; }
        f = globs[glob_of(f)].next;
    }
    let widen = flag_bool("indvars-widen-indvars", true);
    let post_inc_ranges = flag_bool("indvars-post-increment-ranges", true);
    var phis: i32[>..<] = [];
    var p = block_first(loop_header(l));
    while p >= 0 && iop(p) == OP_PHI { phis.push(p); p = inst_next(p); }
    var changed = false;
    while phis.len > 0 {
        loop {
            let cur = phis.pop();
            wi_narrow = cur;
            wi_widest = -1;
            wi_signed = false;
            let c, un = simplify_users_of_iv(cur, true);
            if c { changed = true; }
            if un { ivs_unswitch = true; }
            if wi_widest >= 0 { wides.push(WideIVInfo { narrow: wi_narrow, widest: wi_widest, signed: wi_signed }); }
            if phis.len == 0 { break; }
        }
        if !widen { continue; }
        while wides.len > 0 {
            let w = wides[wides.len - 1];
            let wp = create_wide_iv(w.narrow, w.widest, w.signed, has_guards, post_inc_ranges);
            if wp >= 0 { changed = true; phis.push(wp); }
            wides.pop();
        }
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// rewriteLoopExitValues (LoopUtils.cpp)

// hasHardUserWithinLoop(L, I)
fn ivs_has_hard_user_within_loop(l: i32, i: i32) -> bool {
    var visited = hm_new();
    var wl: i32[>..<] = [];
    hm_put(visited, i as u64, 1);
    wl.push(i);
    while wl.len > 0 {
        let c = wl.pop();
        if !loop_contains(l, inst_parent(c)) { continue; }
        if inst_may_have_side_effects(c) { return true; }
        var u = vals[c].first_use;
        while u >= 0 {
            let ui = uses[u].user;
            if !hm_has(visited, ui as u64) { hm_put(visited, ui as u64, 1); wl.push(ui); }
            u = uses[u].next;
        }
    }
    return false;
}

struct RewritePhi { pn: i32, ith: i64, s: i32, pt: i32, pt_head: bool, high: bool }

// canLoopBeDeleted(L, RewritePhiSet)
fn ivs_can_loop_be_deleted(l: i32, set: RewritePhi[>..<]&) -> bool {
    let ph = loop_preheader(l);
    if ph < 0 { return false; }
    var exiting: i32[>..<] = [];
    loop_exiting_blocks(l, exiting);
    var exits: i32[>..<] = [];
    ivs_unique_exit_blocks(l, exits);
    if exits.len != 1 || exiting.len != 1 { return false; }
    var p = block_first(exits[0]);
    while p >= 0 && iop(p) == OP_PHI {
        let inc = sx_phi_in(p, exiting[0]);
        var found = false;
        for rp in set { if rp.pn == p && phi_value(rp.pn, rp.ith) == inc { found = true; break; } }
        if !found && is_inst(inc) {
            if !loop_has_loop_invariant_operands(l, inc) { return false; }
        }
        p = inst_next(p);
    }
    for k in loop_nblocks(l) {
        var i = block_first(loop_block(l, k));
        while i >= 0 { if inst_may_have_side_effects(i) { return false; } i = inst_next(i); }
    }
    return true;
}

// rewriteLoopExitValues(L, LI, TLI, SE, TTI, Rewriter, DT, ReplaceExitValue, DeadInsts): NumReplaced
fn rewrite_loop_exit_values(l: i32, repl: i64) -> i64 {
    if repl == REPL_UNUSED_IV { fatal("rewriteLoopExitValues: -replexitval=unusedindvarinloop (InductionDescriptor) is not ported yet"); }
    var exits: i32[>..<] = [];
    ivs_unique_exit_blocks(l, exits);
    var set: RewritePhi[>..<] = [];
    for eb in exits {
        let first = block_first(eb);
        if first < 0 || iop(first) != OP_PHI { continue; }
        let npreds = nops(first);
        var pn = first;
        while pn >= 0 && iop(pn) == OP_PHI {
            let cur = pn;
            pn = inst_next(pn);
            if vals[cur].first_use < 0 { continue; }
            if !sc_is_scevable(vals[cur].ty) { continue; }
            for i in npreds {
                let inval = phi_value(cur, i);
                if !is_inst(inval) { continue; }
                if li_loop_for(phi_block(cur, i)) != l { continue; }
                let inst = inval;
                if !loop_contains(l, inst_parent(inst)) { continue; }
                var ev = sc_get_scev_at_scope(sc_get_scev(inst), loop_parent(l));
                if sc_is_cnc(ev) || !sc_is_loop_invariant(ev, l) || !sx_is_safe_to_expand(ev) {
                    let ec = sc_get_exit_count(l, phi_block(cur, i), BTC_EXACT, false);
                    if sc_is_cnc(ec) { continue; }
                    let ar = sc_get_scev(inst);
                    if sc_is_addrec(ar) && sc_loop(ar) == l { ev = sc_evaluate_at_iteration(ar, ec); }
                    if sc_is_cnc(ev) || !sc_is_loop_invariant(ev, l) || !sx_is_safe_to_expand(ev) { continue; }
                }
                if repl != REPL_ALWAYS && !sc_is_const(ev) && !sc_is_unknown(ev) && ivs_has_hard_user_within_loop(l, inst) { continue; }
                let high = sx_is_high_cost_expansion([ev], l, sx_cheap_budget(), inst);
                var pt = inst;
                var head = false;
                if iop(inst) == OP_PHI || iop(inst) == OP_LANDINGPAD {
                    let fi = sx_first_insertion_pt(inst_parent(inst));
                    pt = fi.pos;
                    head = true;
                }
                set.push(RewritePhi { pn: cur, ith: i, s: ev, pt: pt, pt_head: false, high: high });
            }
        }
    }
    let can_del = ivs_can_loop_be_deleted(l, set);
    var nrep: i64 = 0;
    for rp in set {
        let pn = rp.pn;
        if (repl == REPL_CHEAP || repl == REPL_UNUSED_IV) && !can_del && rp.high { continue; }
        let exitv = sx_expand_code_for_it(rp.s, vals[pn].ty, SxIt { bb: inst_parent(rp.pt), pos: rp.pt, head: rp.pt_head });
        nrep++;
        let inst = phi_value(pn, rp.ith);
        set_op(pn, rp.ith, exitv);
        sc_forget_value(pn);
        if is_instruction_trivially_dead(inst) { iv_dead_push(inst); }
        if nops(pn) == 1 && li_replacement_preserves_lcssa(pn, exitv) {
            rauw(pn, exitv);
            inst_erase_from_parent(pn);
        }
    }
    sx_clear_insert_point();
    return nrep;
}

// ---------------------------------------------------------------------------------------------
// LFTR

// getLoopPhiForCounter(IncV, L)
fn ivs_loop_phi_for_counter(incv: i32, l: i32) -> i32 {
    if !is_inst(incv) { return -1; }
    let o = iop(incv);
    if o == OP_ADD || o == OP_SUB { }
    else if o == OP_GEP { if nops(incv) != 2 { return -1; } }
    else { return -1; }
    let p0 = op(incv, 0);
    if is_phi(p0) && inst_parent(p0) == loop_header(l) {
        if sx_loop_invariant_v(l, op(incv, 1)) { return p0; }
        return -1;
    }
    if o == OP_GEP { return -1; }
    let p1 = op(incv, 1);
    if is_phi(p1) && inst_parent(p1) == loop_header(l) {
        if sx_loop_invariant_v(l, op(incv, 0)) { return p1; }
    }
    return -1;
}
// isLoopExitTestBasedOn(V, ExitingBB)
fn ivs_exit_test_based_on(v: i32, ebb: i32) -> bool {
    let bi = block_terminator(ebb);
    let c = op(bi, 0);
    if !is_inst(c) || iop(c) != OP_ICMP { return false; }
    return op(c, 0) == v || op(c, 1) == v;
}
// needsLFTR(L, ExitingBB)
fn ivs_needs_lftr(l: i32, ebb: i32) -> bool {
    let bi = block_terminator(ebb);
    if sx_loop_invariant_v(l, op(bi, 0)) { return false; }
    let c = op(bi, 0);
    if !is_inst(c) || iop(c) != OP_ICMP { return true; }
    let p = insts[inst_of(c)].pred as i64;
    if p != P_NE && p != P_EQ { return true; }
    var lhs = op(c, 0);
    var rhs = op(c, 1);
    if !sx_loop_invariant_v(l, rhs) {
        if !sx_loop_invariant_v(l, lhs) { return true; }
        let t = lhs; lhs = rhs; rhs = t;
    }
    var phi = if is_phi(lhs) { lhs } else { -1 };
    if phi < 0 { phi = ivs_loop_phi_for_counter(lhs, l); }
    if phi < 0 { return true; }
    let idx = phi_block_index(phi, loop_latch(l));
    if idx < 0 { return true; }
    let incv = phi_value(phi, idx);
    return phi != ivs_loop_phi_for_counter(incv, l);
}
// hasConcreteDefImpl(V, Visited, Depth)
fn ivs_has_concrete_def_impl(v: i32, visited: HMap&, depth: i64) -> bool {
    if is_constant(v) { return !is_undef_or_poison(v); }
    if depth >= 6 { return false; }
    if !is_inst(v) { return false; }
    if inst_may_read_memory(v) || iop(v) == OP_CALL || iop(v) == OP_INVOKE { return false; }
    for k in nops(v) {
        let o = op(v, k);
        if hm_has(visited, o as u64) { continue; }
        hm_put(visited, o as u64, 1);
        if !ivs_has_concrete_def_impl_r(o, visited, depth + 1) { return false; }
    }
    return true;
}
recursive fn ivs_has_concrete_def_impl_r(v: i32, visited: HMap&, depth: i64) -> bool {
    if is_constant(v) { return !is_undef_or_poison(v); }
    if depth >= 6 { return false; }
    if !is_inst(v) { return false; }
    if inst_may_read_memory(v) || iop(v) == OP_CALL || iop(v) == OP_INVOKE { return false; }
    for k in nops(v) {
        let o = op(v, k);
        if hm_has(visited, o as u64) { continue; }
        hm_put(visited, o as u64, 1);
        if !ivs_has_concrete_def_impl_r(o, visited, depth + 1) { return false; }
    }
    return true;
}
fn ivs_has_concrete_def(v: i32) -> bool {
    var visited = hm_new();
    hm_put(visited, v as u64, 1);
    return ivs_has_concrete_def_impl(v, visited, 0);
}
// isLoopCounter(Phi, L, SE)
fn ivs_is_loop_counter(phi: i32, l: i32) -> bool {
    if !sc_is_scevable(vals[phi].ty) { return false; }
    let s = sc_get_scev(phi);
    if !sc_is_addrec(s) || sc_nops(s) != 2 || !sc_is_one(sc_op(s, 1)) || sc_loop(s) != l { return false; }
    let li = phi_block_index(phi, loop_latch(l));
    let incv = phi_value(phi, li);
    return ivs_loop_phi_for_counter(incv, l) == phi && sc_is_addrec(sc_get_scev(incv));
}
// isAlmostDeadIV(PN, LatchBlock, Cond) (LoopUtils.cpp)
fn ivs_is_almost_dead_iv(pn: i32, latch: i32, cond: i32) -> bool {
    let li = phi_block_index(pn, latch);
    let incv = phi_value(pn, li);
    var u = vals[pn].first_use;
    while u >= 0 { let x = uses[u].user; if x != cond && x != incv { return false; } u = uses[u].next; }
    u = vals[incv].first_use;
    while u >= 0 { let x = uses[u].user; if x != cond && x != pn { return false; } u = uses[u].next; }
    return true;
}
// FindLoopCounter(L, ExitingBB, BECount, SE, DT)
fn ivs_find_loop_counter(l: i32, ebb: i32, bec: i32) -> i32 {
    let bcw = sc_bits(bec);
    let cond = op(block_terminator(ebb), 0);
    var best: i32 = -1;
    var best_init: i32 = -1;
    let latch = loop_latch(l);
    var phi = block_first(loop_header(l));
    while phi >= 0 && iop(phi) == OP_PHI {
        let cur = phi;
        phi = inst_next(phi);
        if !ivs_is_loop_counter(cur, l) { continue; }
        let ar = sc_get_scev(cur);
        let pw = sc_bits(ar);
        if pw < bcw || !dl_is_legal_integer(pw) { continue; }
        if !ivs_has_concrete_def(cur) {
            let incp = sx_phi_in(cur, latch);
            if !ivs_exit_test_based_on(cur, ebb) && !ivs_exit_test_based_on(incp, ebb) { continue; }
        }
        if !ty_is_int(vals[cur].ty) && !ivs_must_execute_ub_if_poison_on_path_to(cur, block_terminator(ebb)) { continue; }
        let init = sc_op(ar, 0);
        if best >= 0 && !ivs_is_almost_dead_iv(best, latch, cond) {
            if ivs_is_almost_dead_iv(cur, latch, cond) { continue; }
            if sc_is_zero(best_init) != sc_is_zero(init) {
                if sc_is_zero(best_init) { continue; }
            } else if pw <= sc_type_bits(vals[best].ty) { continue; }
        }
        best = cur;
        best_init = init;
    }
    return best;
}
// genLoopLimit(IndVar, ExitingBB, ExitCount, UsePostInc, L, Rewriter, SE)
fn ivs_gen_loop_limit(indvar: i32, ebb: i32, ec: i32, post_inc: bool, l: i32) -> i32 {
    var ar = sc_get_scev(indvar);
    if ty_is_int(vals[indvar].ty) && sc_bits(ar) > sc_bits(ec) {
        let init = sc_op(ar, 0);
        if !sc_is_const(init) || !sc_is_const(ec) {
            let te = sc_get_truncate(ar, sc_ty(ec), 0);
            if !sc_is_addrec(te) { return -1; }
            ar = te;
        }
    }
    let base = if post_inc { sc_get_post_inc(ar) } else { ar };
    let limit = sc_evaluate_at_iteration(base, ec);
    return sx_expand_code_for_at(limit, sc_ty(base), block_terminator(ebb));
}
// linearFunctionTestReplace(L, ExitingBB, ExitCount, IndVar, Rewriter)
fn ivs_linear_function_test_replace(l: i32, ebb: i32, ec: i32, indvar: i32) -> bool {
    let incvar = sx_phi_in(indvar, loop_latch(l));
    var cmpiv = indvar;
    var post_inc = false;
    if ebb == loop_latch(l) {
        let safe = ty_is_int(vals[indvar].ty) || ivs_exit_test_based_on(incvar, ebb) ||
                   ivs_must_execute_ub_if_poison_on_path_to(incvar, block_terminator(ebb));
        if safe { post_inc = true; cmpiv = incvar; }
    }
    var exitcnt = ivs_gen_loop_limit(indvar, ebb, ec, post_inc, l);
    if exitcnt < 0 { return false; }
    if is_inst(incvar) && is_binary_op(iop(incvar)) {
        let ar = sc_get_scev(incvar);
        if op_nuw(incvar) { iv_set_nuw(incvar, sc_has_nuw(ar)); }
        if op_nsw(incvar) { iv_set_nsw(incvar, sc_has_nsw(ar)); }
    }
    let bi = block_terminator(ebb);
    let p = if loop_contains(l, term_succ(bi, 0)) { P_NE } else { P_EQ };
    ib_set(bi);
    let oc = op(bi, 0);
    if is_inst(oc) { ib_dl = inst_get_md(oc, 0); }
    let cs = sc_type_bits(vals[cmpiv].ty);
    let es = sc_type_bits(vals[exitcnt].ty);
    if cs > es {
        var extended = false;
        let iv = sc_get_scev(cmpiv);
        let tiv = sc_get_truncate(iv, vals[exitcnt].ty, 0);
        let zt = sc_get_zero_extend(tiv, vals[cmpiv].ty, 0);
        if zt == iv {
            extended = true;
            exitcnt = ib_cast(OP_ZEXT, exitcnt, vals[indvar].ty, "wide.trip.count");
        } else {
            let st = sc_get_sign_extend(tiv, vals[cmpiv].ty, 0);
            if st == iv {
                extended = true;
                exitcnt = ib_cast(OP_SEXT, exitcnt, vals[indvar].ty, "wide.trip.count");
            }
        }
        if extended {
            var discard = false;
            make_loop_invariant(l, exitcnt, -1, discard);
        } else {
            cmpiv = ib_trunc(cmpiv, vals[exitcnt].ty, "lftr.wideiv", false, false);
        }
    }
    let cond = ib_icmp(p, cmpiv, exitcnt, "exitcond");
    set_op(bi, 0, cond);
    iv_dead_push(oc);
    return true;
}

// ---------------------------------------------------------------------------------------------
// sinkUnusedInvariants

fn ivs_sink_unused_invariants(l: i32) -> bool {
    let eb = ln_exit_block(l, false);
    if eb < 0 { return false; }
    let ph = loop_preheader(l);
    if ph < 0 { return false; }
    var made = false;
    var i = block_last(ph);
    while i >= 0 {
        let cur = i;
        i = inst_prev(i);
        if block_terminator(ph) == cur { continue; }
        if iop(cur) == OP_PHI { break; }
        if inst_may_have_side_effects(cur) || inst_may_read_memory(cur) { continue; }
        if inst_iid(cur) == IID_pseudoprobe { continue; }
        if inst_is_eh_pad(cur) { continue; }
        if iop(cur) == OP_ALLOCA { continue; }
        var used = false;
        var u = vals[cur].first_use;
        while u >= 0 {
            let user = uses[u].user;
            var ubb = inst_parent(user);
            if iop(user) == OP_PHI { ubb = use_aux[u]; }
            if ubb == ph || loop_contains(l, ubb) { used = true; break; }
            u = uses[u].next;
        }
        if used { continue; }
        let fi = sx_first_insertion_pt(eb);
        inst_move_impl(cur, eb, fi.pos, true, false);
        sc_forget_value(cur);
        made = true;
    }
    return made;
}

// ---------------------------------------------------------------------------------------------
// Exit folding

// replaceExitCond(BI, NewCond, DeadInsts)
fn ivs_replace_exit_cond(bi: i32, nc: i32) {
    let oc = op(bi, 0);
    set_op(bi, 0, nc);
    if vals[oc].first_use < 0 { iv_dead_push(oc); }
}
// createFoldedExitCond(L, ExitingBB, IsTaken)
fn ivs_folded_exit_cond(l: i32, ebb: i32, taken: bool) -> i32 {
    let bi = block_terminator(ebb);
    let exit_if_true = !loop_contains(l, term_succ(bi, 0));
    let oc = op(bi, 0);
    return c_bool_ty(vals[oc].ty, if taken { exit_if_true } else { !exit_if_true });
}
// foldExit(L, ExitingBB, IsTaken, DeadInsts)
fn ivs_fold_exit(l: i32, ebb: i32, taken: bool) {
    let bi = block_terminator(ebb);
    ivs_replace_exit_cond(bi, ivs_folded_exit_cond(l, ebb, taken));
}
// replaceLoopPHINodesWithPreheaderValues(LI, L, DeadInsts, SE)
fn ivs_replace_loop_phis_with_preheader_values(l: i32) {
    let ph = loop_preheader(l);
    let h = loop_header(l);
    var wl: i32[>..<] = [];
    var pn = block_first(h);
    while pn >= 0 && iop(pn) == OP_PHI {
        let cur = pn;
        pn = inst_next(pn);
        let inc = sx_phi_in(cur, ph);
        var u = vals[cur].first_use;
        while u >= 0 { wl.push(uses[u].user); u = uses[u].next; }
        sc_forget_value(cur);
        rauw(cur, inc);
        iv_dead_push(cur);
    }
    var visited = hm_new();
    while wl.len > 0 {
        let i = wl.pop();
        if hm_has(visited, i as u64) { continue; }
        hm_put(visited, i as u64, 1);
        if !loop_contains(l, inst_parent(i)) { continue; }
        // simplifyInstruction(I, DL): no DT, AC or TLI
        let sd = sq_no_dt; let sa = sq_no_ac; let st = sq_no_tli;
        sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
        let res = simplify_instruction(i);
        sq_no_dt = sd; sq_no_ac = sa; sq_no_tli = st;
        if res >= 0 && li_replacement_preserves_lcssa(i, res) {
            var u = vals[i].first_use;
            while u >= 0 { wl.push(uses[u].user); u = uses[u].next; }
            rauw(i, res);
            iv_dead_push(i);
        }
    }
}
// createInvariantCond(L, ExitingBB, LIP, Rewriter)
fn ivs_create_invariant_cond(l: i32, ebb: i32, lip: LIP) -> i32 {
    var p = lip.pred;
    let ph = loop_preheader(l);
    sx_set_insert_point(block_terminator(ph));
    let lv = sx_expand_code_for(lip.lhs, -1);
    let rv = sx_expand_code_for(lip.rhs, -1);
    let bi = block_terminator(ebb);
    let exit_if_true = !loop_contains(l, term_succ(bi, 0));
    if exit_if_true { p = sc_inverse_pred(p); }
    ib_set(block_terminator(ph));
    let nm = iv_name_plus(op(bi, 0), "");
    return ib_icmp(p, lv, rv, nm);
}
// createReplacement(ICmp, L, ExitingBB, MaxIter, Inverted, SkipLastIter, SE, Rewriter): -1 = std::nullopt
fn ivs_create_replacement(icmp: i32, l: i32, ebb: i32, max_iter0: i32, inverted: bool, skip_last: bool) -> i32 {
    var p = iv_cmp_pred(icmp);
    let lhs = op(icmp, 0);
    let rhs = op(icmp, 1);
    let bi = block_terminator(ebb);
    if inverted { p = cp_inverse(p); }
    let ls = sc_get_scev_at_scope(sc_get_scev(lhs), l);
    let rs = sc_get_scev_at_scope(sc_get_scev(rhs), l);
    let ev = sc_evaluate_predicate_at(p, ls, rs, bi);
    if ev >= 0 { return ivs_folded_exit_cond(l, ebb, ev == 0); }
    var max_iter = max_iter0;
    let arty = sc_ty(ls);
    let mty = sc_ty(max_iter);
    if sc_type_bits(arty) > sc_type_bits(mty) { max_iter = sc_get_zero_extend(max_iter, arty, 0); }
    else if sc_type_bits(arty) < sc_type_bits(mty) {
        let mo = sc_get_minus_one(arty);
        let mai = sc_get_zero_extend(mo, mty, 0);
        if sc_is_known_predicate_at(P_ULE, max_iter, mai, bi) { max_iter = sc_get_truncate(max_iter, arty, 0); }
    }
    if skip_last {
        if sc_kind(max_iter) == SC_UMIN {
            let b = ss.len;
            for k in sc_nops(max_iter) {
                let o = sc_op(max_iter, k);
                let x = sc_minus(o, sc_get_one(sc_ty(o)));
                ss.push(x);
            }
            max_iter = sc_get_umin_from_mismatched_n(b, false);
        } else {
            max_iter = sc_minus(max_iter, sc_get_one(sc_ty(max_iter)));
        }
    }
    let lip = sc_get_loop_invariant_exit_cond_during_first_iterations(p, ls, rs, l, bi, max_iter);
    if !lip.ok { return -1; }
    if sc_is_known_predicate_at(lip.pred, lip.lhs, lip.rhs, bi) { return ivs_folded_exit_cond(l, ebb, false); }
    return ivs_create_invariant_cond(l, ebb, lip);
}
// m_LogicalAnd / m_LogicalOr: (matched, lhs, rhs)
fn ivs_match_logical(v: i32, is_or: bool) -> bool, i32, i32 {
    if !is_inst(v) { return false, -1, -1; }
    let o = iop(v);
    if o == (if is_or { OP_OR } else { OP_AND }) && ty_is_int(vals[v].ty) && ty_bits(vals[v].ty) == 1 { return true, op(v, 0), op(v, 1); }
    if o == OP_SELECT && vals[op(v, 0)].ty == vals[v].ty && ty_kind(vals[v].ty) == TK_INT && ty_bits(vals[v].ty) == 1 {
        let c = op(v, 0);
        let t = op(v, 1);
        let f = op(v, 2);
        if is_or { if is_cint(t) && ap_is_one(ci_ap(t)) { return true, c, f; } }
        else { if is_cint(f) && ap_is_zero(ci_ap(f)) { return true, c, t; } }
    }
    return false, -1, -1;
}
// optimizeLoopExitWithUnknownExitCount(L, BI, ExitingBB, MaxIter, SkipLastIter, SE, Rewriter, DeadInsts)
fn ivs_optimize_exit_unknown_count(l: i32, bi: i32, ebb: i32, max_iter: i32, skip_last: bool) -> bool {
    let inverted = loop_contains(l, term_succ(bi, 1));
    var leaves: i32[>..<] = [];
    var wl: i32[>..<] = [];
    var visited = hm_new();
    let oc0 = op(bi, 0);
    hm_put(visited, oc0 as u64, 1);
    wl.push(oc0);
    loop {
        let cur = wl.pop();
        let fu = vals[cur].first_use;
        if has_use_list(cur) && fu >= 0 && uses[fu].next < 0 {
            let m, a, b = ivs_match_logical(cur, inverted);
            if m {
                if !hm_has(visited, a as u64) { hm_put(visited, a as u64, 1); wl.push(a); }
                if !hm_has(visited, b as u64) { hm_put(visited, b as u64, 1); wl.push(b); }
            } else if is_inst(cur) && iop(cur) == OP_ICMP { leaves.push(cur); }
        }
        if wl.len == 0 { break; }
    }
    var failing: i32[>..<] = [];     // ICmpsFailingOnLastIter (SmallPtrSet)
    if !skip_last && leaves.len > 1 && sc_get_exit_count(l, ebb, BTC_SYMBOLIC_MAX, false) == max_iter {
        for ic in leaves {
            let el = sc_compute_exit_limit_from_cond(l, ic, inverted, false, false);
            let em = el.smax;
            if sc_is_cnc(em) { continue; }
            let wt = sc_get_wider_type(sc_ty(em), sc_ty(max_iter));
            let wem = sc_get_noop_or_zero_extend(em, wt);
            let wmi = sc_get_noop_or_zero_extend(max_iter, wt);
            if wem == wmi && position(failing, ic) < 0 { failing.push(ic); }
        }
    }
    var changed = false;
    for oc in leaves {
        var opt_skip = skip_last;
        if !opt_skip {
            if failing.len > 1 { opt_skip = true; }
            else if failing.len == 1 { opt_skip = position(failing, oc) < 0; }
        }
        let nc = ivs_create_replacement(oc, l, ebb, max_iter, inverted, opt_skip);
        if nc >= 0 {
            changed = true;
            if is_inst(nc) {
                let nm = iv_name_plus(oc, ".first_iter");
                set_name(nc, nm);
            }
            rauw(oc, nc);
            iv_dead_push(oc);
            let fp = position(failing, oc);
            if fp >= 0 { remove_at(failing, fp); }
        }
    }
    return changed;
}

// canonicalizeExitCondition(L)
fn ivs_canonicalize_exit_condition(l: i32) -> bool {
    var exiting: i32[>..<] = [];
    loop_exiting_blocks(l, exiting);
    var changed = false;
    for ebb in exiting {
        let bi = block_terminator(ebb);
        if iop(bi) != OP_CONDBR { continue; }
        let ic = op(bi, 0);
        if !is_inst(ic) || iop(ic) != OP_ICMP { continue; }
        let fu = vals[ic].first_use;
        if fu < 0 || uses[fu].next >= 0 { continue; }
        var lhs = op(ic, 0);
        var rhs = op(ic, 1);
        if !sx_loop_invariant_v(l, rhs) {
            if !sx_loop_invariant_v(l, lhs) { continue; }
            let t = lhs; lhs = rhs; rhs = t;
        }
        if !is_inst(lhs) || iop(lhs) != OP_ZEXT || !sc_pred_is_signed(insts[inst_of(ic)].pred as i64) { continue; }
        let lop = op(lhs, 0);
        let iw = dl_size_bits(vals[lop].ty);
        let ow = dl_size_bits(vals[rhs].ty);
        let full = rg_zext(rg_full(iw), ow);
        let rcr = sc_get_unsigned_range(sc_apply_loop_guards(sc_get_scev(rhs), l));
        if rg_contains(full, rcr) {
            iv_set_pred(ic, sc_pred_unsigned(insts[inst_of(ic)].pred as i64));
            changed = true;
            continue;
        }
    }
    for ebb in exiting {
        let bi = block_terminator(ebb);
        if iop(bi) != OP_CONDBR { continue; }
        let ic = op(bi, 0);
        if !is_inst(ic) || iop(ic) != OP_ICMP { continue; }
        let fu = vals[ic].first_use;
        if fu < 0 || uses[fu].next >= 0 || !sc_pred_is_unsigned(insts[inst_of(ic)].pred as i64) { continue; }
        var swapped = false;
        var lhs = op(ic, 0);
        var rhs = op(ic, 1);
        if sx_loop_invariant_v(l, lhs) == sx_loop_invariant_v(l, rhs) { continue; }
        if sx_loop_invariant_v(l, lhs) {
            swapped = true;
            let t = lhs; lhs = rhs; rhs = t;
        }
        if !is_inst(lhs) || iop(lhs) != OP_ZEXT { continue; }
        let lop = op(lhs, 0);
        let lfu = vals[lhs].first_use;
        let one_use = lfu >= 0 && uses[lfu].next < 0;
        if !one_use && !sc_is_addrec(sc_get_scev(lop)) { continue; }
        let iw = dl_size_bits(vals[lop].ty);
        let ow = dl_size_bits(vals[rhs].ty);
        let full = rg_zext(rg_full(iw), ow);
        let rcr = sc_get_unsigned_range(sc_apply_loop_guards(sc_get_scev(rhs), l));
        if rg_contains(full, rcr) {
            // doRotateTransform
            let nr = create_inst(OP_TRUNC, vals[lop].ty, [rhs]);
            inst_insert_before(nr, block_terminator(loop_preheader(l)));
            set_op(ic, if swapped { 1 } else { 0 }, lop);
            set_op(ic, if swapped { 0 } else { 1 }, nr);
            insts[inst_of(ic)].flags &= ~FL_SAMESIGN;
            if vals[lhs].first_use < 0 { iv_dead_push(lhs); }
            changed = true;
            continue;
        }
    }
    return changed;
}

// llvm::sort(ExitingBlocks, dominance order) = std::sort
fn ivs_sort_by_dominance(xs: i32[>..<]&, two_queries: bool) {
    std_sort(xs, 0, xs.len) { a, b =>
        if a == b { false }
        else if dt_properly_dominates_block(DT_DOM, a, b) { true }
        else { if two_queries { dt_properly_dominates_block(DT_DOM, b, a); } false }
    };
}

// optimizeLoopExits(L, Rewriter)
fn ivs_optimize_loop_exits(l: i32) -> bool {
    var all: i32[>..<] = [];
    loop_exiting_blocks(l, all);
    var exiting: i32[>..<] = [];
    for ebb in all {
        if li_loop_for(ebb) != l { continue; }
        let bi = block_terminator(ebb);
        if iop(bi) != OP_CONDBR { continue; }
        if !dt_dominates_block(DT_DOM, ebb, loop_latch(l)) { continue; }
        let c = op(bi, 0);
        if is_cint(c) {
            if !loop_contains(l, term_succ(bi, if ap_is_zero(ci_ap(c)) { 1 } else { 0 })) { ivs_replace_loop_phis_with_preheader_values(l); }
            continue;
        }
        exiting.push(ebb);
    }
    if exiting.len == 0 { return false; }
    var max_bec = sc_get_symbolic_max_backedge_taken_count(l);
    if sc_is_cnc(max_bec) { return false; }
    ivs_sort_by_dominance(exiting, false);
    var changed = false;
    var skip_last = false;
    var cur_max: i32 = SCEV_CNC;
    var dom_exact = hm_new();
    for ebb in exiting {
        var exact = sc_get_exit_count(l, ebb, BTC_EXACT, false);
        let maxc = sc_get_exit_count(l, ebb, BTC_SYMBOLIC_MAX, false);
        if sc_is_cnc(exact) {
            let bi = block_terminator(ebb);
            if ivs_optimize_exit_unknown_count(l, bi, ebb, max_bec, false) { changed = true; }
            else if skip_last && ivs_optimize_exit_unknown_count(l, bi, ebb, max_bec, true) { changed = true; }
            // UpdateSkipLastIter(MaxExitCount)
            if !skip_last && !sc_is_cnc(maxc) {
                cur_max = if sc_is_cnc(cur_max) { maxc } else { sc_get_umin_from_mismatched(cur_max, maxc, false) };
                if cur_max == max_bec { skip_last = true; }
            }
            continue;
        }
        if !skip_last && !sc_is_cnc(exact) {
            cur_max = if sc_is_cnc(cur_max) { exact } else { sc_get_umin_from_mismatched(cur_max, exact, false) };
            if cur_max == max_bec { skip_last = true; }
        }
        if sc_is_zero(exact) {
            ivs_fold_exit(l, ebb, true);
            ivs_replace_loop_phis_with_preheader_values(l);
            changed = true;
            continue;
        }
        let wt = sc_get_wider_type(sc_ty(max_bec), sc_ty(exact));
        exact = sc_get_noop_or_zero_extend(exact, wt);
        max_bec = sc_get_noop_or_zero_extend(max_bec, wt);
        if sc_is_loop_entry_guarded_by_cond(l, P_ULT, max_bec, exact) {
            ivs_fold_exit(l, ebb, false);
            changed = true;
            continue;
        }
        if hm_has(dom_exact, exact as u64) {
            ivs_fold_exit(l, ebb, false);
            changed = true;
            continue;
        }
        hm_put(dom_exact, exact as u64, 1);
    }
    return changed;
}

// crashingBBWithoutEffect(BB)
fn ivs_crashing_bb_without_effect(bb: i32) -> bool {
    var i = block_first(bb);
    while i >= 0 {
        var ok = false;
        if is_callbase(i) {
            let me = call_memory_effects(i);
            if me_without(me, LOC_INACCESSIBLE) == 0 { ok = true; }
        }
        if !ok && iop(i) != OP_UNREACHABLE { return false; }
        i = inst_next(i);
    }
    return true;
}

// predicateLoopExits(L, Rewriter)
fn ivs_predicate_loop_exits(l: i32) -> bool {
    var exiting: i32[>..<] = [];
    loop_exiting_blocks(l, exiting);
    if !flag_bool("indvars-predicate-loops", true) { return false; }
    let exact_btc = sc_get_backedge_taken_count(l, BTC_EXACT);
    if sc_is_cnc(exact_btc) || !sx_is_safe_to_expand(exact_btc) { return false; }
    let latch = loop_latch(l);
    for ebb in exiting { if !dt_dominates_block(DT_DOM, ebb, latch) { return false; } }
    ivs_sort_by_dominance(exiting, true);
    for i in exiting.len {
        if ivs_bad_exit(l, exiting[i]) { exiting.resize(i); break; }
    }
    if exiting.len == 0 { return false; }
    let traps = flag_bool("indvars-predicate-loop-traps", true);
    var tl_side_effects = false;
    for k in loop_nblocks(l) {
        var i = block_first(loop_block(l, k));
        while i >= 0 {
            if inst_may_have_side_effects(i) {
                if !traps { return false; }
                tl_side_effects = true;
                if iop(i) == OP_STORE {
                    if (insts[inst_of(i)].bits & 1) != 0 || insts[inst_of(i)].ord != 0 { return false; }
                } else { return false; }
            }
            if vals[i].ty == T_TOKEN {
                var u = vals[i].first_use;
                while u >= 0 {
                    let ui = uses[u].user;
                    if is_inst(ui) && !loop_contains(l, inst_parent(ui)) { return false; }
                    u = uses[u].next;
                }
            }
            i = inst_next(i);
        }
    }
    var changed = false;
    let ph = loop_preheader(l);
    sx_set_insert_point(block_terminator(ph));
    var exact_btcv: i32 = -1;
    for ebb in exiting {
        let ec = sc_get_exit_count(l, ebb, BTC_EXACT, false);
        let bi = block_terminator(ebb);
        if tl_side_effects {
            var unreach: i32 = -1;
            for k in term_nsucc(bi) {
                let s = term_succ(bi, k);
                if iop(block_terminator(s)) == OP_UNREACHABLE { unreach = s; }
            }
            if unreach < 0 || !ivs_crashing_bb_without_effect(unreach) { return changed; }
        }
        var nc: i32 = -1;
        if ec == exact_btc {
            nc = if loop_contains(l, term_succ(bi, 0)) { c_false() } else { c_true() };
        } else {
            var ecv = sx_expand_code_for(ec, -1);
            if exact_btcv < 0 { exact_btcv = sx_expand_code_for(exact_btc, -1); }
            var rhs = exact_btcv;
            ib_set(block_terminator(ph));
            if vals[ecv].ty != vals[rhs].ty {
                let wt = sc_get_wider_type(vals[ecv].ty, vals[rhs].ty);
                ecv = ib_cast(OP_ZEXT, ecv, wt, "");
                rhs = ib_cast(OP_ZEXT, rhs, wt, "");
            }
            let p = if loop_contains(l, term_succ(bi, 0)) { P_NE } else { P_EQ };
            nc = ib_icmp(p, ecv, rhs, "");
        }
        let oc = op(bi, 0);
        set_op(bi, 0, nc);
        if vals[oc].first_use < 0 { iv_dead_push(oc); }
        changed = true;
        ivs_unswitch = true;
    }
    return changed;
}
// predicateLoopExits' BadExit(ExitingBB)
fn ivs_bad_exit(l: i32, ebb: i32) -> bool {
    if li_loop_for(ebb) != l { return true; }
    let bi = block_terminator(ebb);
    if iop(bi) != OP_CONDBR { return true; }
    if is_constant(op(bi, 0)) { return true; }
    let exit = term_succ(bi, if loop_contains(l, term_succ(bi, 0)) { 1 } else { 0 });
    let f = block_first(exit);
    if f >= 0 && iop(f) == OP_PHI { return true; }
    let ec = sc_get_exit_count(l, ebb, BTC_EXACT, false);
    if sc_is_cnc(ec) || !sx_is_safe_to_expand(ec) { return true; }
    return false;
}

// ---------------------------------------------------------------------------------------------
// IndVarSimplify::run

fn ivs_run(l: i32) -> bool {
    if !loop_is_simplify_form(l) { return false; }
    var changed = false;
    if ivs_rewrite_non_integer_ivs(l) { changed = true; }
    sx_begin("indvars", true);
    sx_disable_canonical_mode();
    if ivs_simplify_and_extend(l) { changed = true; }
    if ivs_replexitval != REPL_NEVER {
        let r = rewrite_loop_exit_values(l, ivs_replexitval);
        if r > 0 { changed = true; }
    }
    sx_replace_congruent_ivs(l, iv_dead, true);
    if ivs_canonicalize_exit_condition(l) { changed = true; }
    if ivs_optimize_loop_exits(l) {
        changed = true;
        sc_forget_topmost_loop(l);
    }
    if ivs_predicate_loop_exits(l) {
        changed = true;
        sc_forget_loop(l);
    }
    if !flag_bool("disable-lftr", false) {
        let ph = loop_preheader(l);
        var exiting: i32[>..<] = [];
        loop_exiting_blocks(l, exiting);
        for ebb in exiting {
            if iop(block_terminator(ebb)) != OP_CONDBR { continue; }
            if li_loop_for(ebb) != l { continue; }
            if !ivs_needs_lftr(l, ebb) { continue; }
            let ec = sc_get_exit_count(l, ebb, BTC_EXACT, false);
            if sc_is_cnc(ec) { continue; }
            if sc_is_zero(ec) { continue; }
            let indvar = ivs_find_loop_counter(l, ebb, ec);
            if indvar < 0 { continue; }
            if sx_is_high_cost_expansion([ec], l, sx_cheap_budget(), block_terminator(ph)) { continue; }
            if !sx_is_safe_to_expand(ec) { continue; }
            if ivs_linear_function_test_replace(l, ebb, ec, indvar) { changed = true; }
        }
    }
    sx_clear();
    while iv_dead.len > 0 {
        let h = iv_dead.pop();
        let v = wvh_get(h);
        if v < 0 { continue; }
        if is_phi(v) { if ivs_recursively_delete_dead_phi(v) { changed = true; } }
        else if is_inst(v) { if ivs_recursively_delete_trivially_dead(v) { changed = true; } }
    }
    if ivs_sink_unused_invariants(l) { changed = true; }
    if ivs_rewrite_first_iteration_loop_exit_values(l) { changed = true; }
    if ivs_delete_dead_phis(loop_header(l)) { changed = true; }
    if ivs_mssau && flag_bool("verify-memoryssa", false) { mssa_verify(block_func(loop_header(l))); }
    sx_end();
    return changed;
}

// IndVarSimplifyPass::run: the preserved set
fn indvars_pass_run(l: i32, use_mssa: bool) -> u32 {
    let fv = block_func(loop_header(l));
    tli_cur_fn = fv;
    local_have_tli = true;
    tti_init_function(fv, globs[glob_of(fv)].module);
    ivs_read_flags();
    ivs_mssau = use_mssa;
    if use_mssa { msu_reset(); }
    ivs_unswitch = false;
    iv_dead.clear();
    let mark = wvh_mark();
    let changed = ivs_run(l);
    iv_dead.clear();
    wvh_release(mark);
    ivs_mssau = false;
    if !changed { return PA_ALL; }
    var pa = PA_CFG | ((1 as u32) << A_DOMTREE) | ((1 as u32) << A_LOOPS) | ((1 as u32) << A_SCEV);
    if use_mssa { pa |= (1 as u32) << A_MEMORYSSA; }
    return pa;
}
