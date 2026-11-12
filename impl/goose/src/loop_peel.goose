// Loop peeling: port of llvm/lib/Transforms/Utils/LoopPeel.cpp (canPeel, PhiAnalyzer,
// peelToTurnInvariantLoadsDereferenceable, canPeelLastIteration, shouldPeelLastIteration,
// countToEliminateCompares, violatesLegacyMultiExitLoopCheck, computePeelCount, cloneLoopBlocks,
// gatherPeelingPreferences, peelLoop), with cloneLoop (llvm/lib/Transforms/Utils/LoopUtils.cpp) and
// SplitEdge / SplitBlock / splitBlockBefore with a DominatorTree and LoopInfo
// (llvm/lib/Transforms/Utils/BasicBlockUtils.cpp, BasicBlock::splitBasicBlockBefore).
//
// Not ported (fail loudly): -disable-advanced-peeling, SplitEdge of a critical edge, splitBlockBefore of a
// block with several predecessors.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_iids;
import flags;
import apint;
import pm;
import memloc;
import assume;
import speculate;
import domtree;
import dtu;
import loopinfo;
import loopsimplify;
import loopsimplify_pass;
import lcssa;
import cfgutil;
import profdata;
import tti;
import scev;
import scev_create;
import scev_btc;
import scev_eval;
import scev_pred;
import scev_range;
import scev_guards;
import scev_update;
import scev_expander;
import value_mapper;
import clone_function;
import loop_md;
import unroll_utils;

fn lp_not_ported(what: const u8[:]) { fatal(str("LoopPeel: ", what, " is not ported yet")); }

// TargetTransformInfo::PeelingPreferences
struct PeelPrefs { peel_count: i64, allow_peeling: bool, allow_loop_nests_peeling: bool, peel_profiled_iterations: bool, peel_last: bool }

// gatherPeelingPreferences(L, SE, TTI, UserAllowPeeling, UserAllowProfileBasedPeeling, UnrollingSpecficValues)
fn gather_peeling_preferences(l: i32, user_peel: i64, user_profile: i64, unrolling_specific: bool) -> PeelPrefs {
    var pp = PeelPrefs { peel_count: 0, allow_peeling: true, allow_loop_nests_peeling: false, peel_profiled_iterations: true, peel_last: false };
    // TTI.getPeelingPreferences: BasicTTIImplBase (X86) sets the defaults again; NoTTIImpl changes nothing
    if unrolling_specific {
        if flag_given("unroll-peel-count") { pp.peel_count = flag_int("unroll-peel-count", 0) & 0xFFFFFFFF; }
        if flag_given("unroll-allow-peeling") { pp.allow_peeling = flag_bool("unroll-allow-peeling", true); }
        if flag_given("unroll-allow-loop-nests-peeling") { pp.allow_loop_nests_peeling = flag_bool("unroll-allow-loop-nests-peeling", false); }
    }
    if user_peel >= 0 { pp.allow_peeling = user_peel != 0; }
    if user_profile >= 0 { pp.peel_profiled_iterations = user_profile != 0; }
    return pp;
}

// canPeel(L)
fn can_peel(l: i32) -> bool {
    if !loop_is_simplify_form(l) { return false; }
    if !flag_bool("disable-advanced-peeling", false) { return true; }
    lp_not_ported("-disable-advanced-peeling");
    return false;
}

// Loop::isLoopInvariant(V)
fn lp_is_loop_invariant(l: i32, v: i32) -> bool { if is_inst(v) { return !loop_contains(l, inst_parent(v)); } return true; }


// ---------------------------------------------------------------------------------------------
// PhiAnalyzer: counters are encoded as -1 = Unknown, else value * 2 + type (0 Invariant, 1 Induction)

var pa_map = hm_new();
var pa_l: i32 = -1;
var pa_max: i64 = 0;
var pa_for_iv: bool = false;

fn pa_add_one(pc: i64) -> i64 {
    if pc < 0 { return -1; }
    let v = pc / 2;
    return if v + 1 <= pa_max { (v + 1) * 2 + (pc % 2) } else { -1 };
}
// isInductionPHI
fn pa_is_induction_phi(phi: i32) -> bool {
    let latch = loop_latch(pa_l);
    if latch < 0 { return false; }
    var cur = phi_value_for_block(phi, latch);
    var visited: i32[>..<] = [];
    var visit_binop = false;
    loop {
        if cur == phi { break; }
        if position(visited, cur) >= 0 { return false; }
        visited.push(cur);
        if !is_inst(cur) || !loop_contains(pa_l, inst_parent(cur)) { return false; }
        let o = iop(cur);
        if is_cast_op(o) || o == OP_PTRTOADDR { cur = op(cur, 0); }
        else if is_binary_op(o) {
            if o != OP_ADD && o != OP_SUB { return false; }
            if vals[op(cur, 1)].kind != VK_CINT { return false; }
            visit_binop = true;
            cur = op(cur, 0);
        } else { return false; }
    }
    return visit_binop;
}
// mergeTwoCounters
fn pa_merge(i: i32, lhs: i64, rhs: i64) -> i64 {
    let lv = lhs / 2;
    let rv = rhs / 2;
    let nv = if lv > rv { lv } else { rv };
    if (lhs % 2) == 1 || (rhs % 2) == 1 {
        if iop(i) == OP_ADD || iop(i) == OP_SUB { return nv * 2 + 1; }
        return -1;
    }
    return nv * 2;
}
// calculate(V)
recursive fn pa_calculate(v: i32) -> i64 {
    if hm_has(pa_map, v as u64) { return hm_get(pa_map, v as u64, -1); }
    hm_put(pa_map, v as u64, -1);
    if lp_is_loop_invariant(pa_l, v) { hm_put(pa_map, v as u64, 0); return 0; }
    if is_inst(v) && iop(v) == OP_PHI {
        if inst_parent(v) != loop_header(pa_l) { return -1; }
        if pa_for_iv && pa_is_induction_phi(v) { hm_put(pa_map, v as u64, 1); return 1; }
        let input = phi_value_for_block(v, loop_latch(pa_l));
        let it = pa_calculate(input);
        let r = pa_add_one(it);
        hm_put(pa_map, v as u64, r);
        return r;
    }
    if is_inst(v) {
        let o = iop(v);
        if o == OP_ICMP || o == OP_FCMP || is_binary_op(o) {
            let lhs = pa_calculate(op(v, 0));
            if lhs < 0 { return -1; }
            let rhs = pa_calculate(op(v, 1));
            if rhs < 0 { return -1; }
            let r = pa_merge(v, lhs, rhs);
            hm_put(pa_map, v as u64, r);
            return r;
        }
        if is_cast_op(o) || o == OP_PTRTOADDR {
            let r = pa_calculate(op(v, 0));
            hm_put(pa_map, v as u64, r);
            return r;
        }
    }
    return -1;
}
// calculateIterationsToPeel: 0 = std::nullopt
fn pa_iterations_to_peel(l: i32, max_iters: i64, for_iv: bool) -> i64 {
    hm_clear(pa_map);
    pa_l = l;
    pa_max = max_iters;
    pa_for_iv = for_iv;
    var its: i64 = 0;
    var p = block_first(loop_header(l));
    while p >= 0 && iop(p) == OP_PHI {
        let c = pa_calculate(p);
        if c >= 0 {
            let v = c / 2;
            if v > its { its = v; }
            if its == max_iters { break; }
        }
        p = inst_next(p);
    }
    return its;
}

// peelToTurnInvariantLoadsDereferenceable(L, DT, AC)
fn peel_to_turn_invariant_loads_dereferenceable(l: i32) -> i64 {
    if loop_exiting_block(l) >= 0 { return 0; }
    var exits: i32[>..<] = [];
    loop_unique_non_latch_exit_blocks(l, exits);
    for e in exits { if iop(block_terminator(e)) != OP_UNREACHABLE { return 0; } }
    let header = loop_header(l);
    let latch = loop_latch(l);
    let fv = block_func(header);
    var load_users = hm_new();
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        var i = block_first(bb);
        while i >= 0 {
            if inst_may_write_memory(i) && !(is_callbase(i) && me_without(call_memory_effects(i), LOC_INACCESSIBLE) == 0) { return 0; }
            if hm_has(load_users, i as u64) {
                var u = vals[i].first_use;
                while u >= 0 { hm_put(load_users, uses[u].user as u64, 1); u = uses[u].next; }
            }
            if bb != header && iop(i) == OP_LOAD {
                let ptr = op(i, 0);
                if dt_dominates_block(DT_DOM, bb, latch) && lp_is_loop_invariant(l, ptr) &&
                   !lp_is_dereferenceable_pointer(ptr, vals[i].ty, i) {
                    var u = vals[i].first_use;
                    while u >= 0 { hm_put(load_users, uses[u].user as u64, 1); u = uses[u].next; }
                }
            }
            i = inst_next(i);
        }
    }
    var exiting: i32[>..<] = [];
    loop_exiting_blocks(l, exiting);
    for eb in exiting { if hm_has(load_users, block_terminator(eb) as u64) { return 1; } }
    return 0;
}
// isDereferenceablePointer(V, Ty, SimplifyQuery(DL, &DT, AC, CtxI))
fn lp_is_dereferenceable_pointer(v: i32, ty: i32, cx: i32) -> bool { spec_deref_aligned_ty_sq(v, ty, 1, cx) }

// canPeelLastIteration(L, SE)
fn can_peel_last_iteration(l: i32) -> bool {
    let btc = sc_get_backedge_taken_count(l, BTC_EXACT);
    if sc_is_cnc(btc) { return false; }
    let latch = loop_latch(l);
    if latch < 0 || latch != loop_exiting_block(l) { return false; }
    let br = block_terminator(latch);
    if iop(br) != OP_CONDBR { return false; }
    let c = op(br, 0);
    if !is_inst_op(c, OP_ICMP) || !lp_one_use(c) { return false; }
    let p = insts[inst_of(c)].pred as i64;
    let s1 = term_succ(br, 0);
    let s2 = term_succ(br, 1);
    if !((p == 32 && s2 == loop_header(l)) || (p == 33 && s1 == loop_header(l))) { return false; }
    let inc = op(c, 0);
    let bound = op(c, 1);
    if !ty_is_int(vals[bound].ty) { return false; }
    if !sc_is_loop_invariant(sc_get_scev(bound), l) { return false; }
    let s = sc_get_scev(inc);
    return sc_is_addrec(s) && sc_nops(s) == 2 && sc_is_one(sc_op(s, 1)) && sc_loop(s) == l;
}
fn lp_one_use(v: i32) -> bool { let u = vals[v].first_use; return u >= 0 && uses[u].next < 0; }

// shouldPeelLastIteration(L, Pred, LeftAR, RightSCEV, SE, TTI)
fn should_peel_last_iteration(l: i32, p: i64, ar: i32, rhs0: i32) -> bool {
    if !can_peel_last_iteration(l) { return false; }
    var btc = sc_get_backedge_taken_count(l, BTC_EXACT);
    if !sc_is_known_non_zero(btc) {
        sx_begin("loop-peel", true);
        let hc = sx_is_high_cost_expansion([btc], l, flag_int("scev-cheap-expansion-budget", 4), block_terminator(loop_predecessor(l)));
        sx_end();
        if hc { return false; }
    }
    let g = sc_loop_guards_collect(l);
    btc = sc_apply_loop_guards_g(btc, g);
    let rhs = sc_apply_loop_guards_g(rhs0, g);
    let last = sc_evaluate_at_iteration(ar, btc);
    let second = sc_evaluate_at_iteration(ar, sc_get_minus(btc, sc_get_one(sc_ty(btc)), SF_ANY, 0));
    return sc_is_known_predicate(sc_inverse_pred(p & 0xFF), last, rhs) && sc_is_known_predicate(p, second, rhs);
}

fn lp_is_equality(p: i64) -> bool { let x = p & 0xFF; x == 32 || x == 33 }
fn lp_swapped_pred(p: i64) -> i64 {
    let x = p & 0xFF;
    if x == 32 || x == 33 { return x; }
    if x == 34 { return 36; } if x == 36 { return 34; }
    if x == 35 { return 37; } if x == 37 { return 35; }
    if x == 38 { return 40; } if x == 40 { return 38; }
    if x == 39 { return 41; } if x == 41 { return 39; }
    return x;
}

// countToEliminateCompares(L, MaxPeelCount, SE, TTI): (DesiredPeelCount, DesiredPeelCountLast)
fn count_to_eliminate_compares(l: i32, max0: i64) -> i64, i64 {
    var desired: i64 = 0;
    var desired_last: i64 = 0;
    var max_peel = max0;
    let be = sc_get_constant_max_backedge_taken_count(l);
    if sc_is_const(be) {
        let lim = ap_limited(sc_ap(be), 0xFFFFFFFFFFFFFFFF);
        let m = ((lim & 0xFFFFFFFF) as i64 - 1) & 0xFFFFFFFF;
        if m < max_peel { max_peel = m; }
    }
    // PeelWhilePredicateIsKnown: (result, PeelCount, IterVal)
    fn peel_while(pc0: i64, iv0: i32, bound: i32, step: i32, p: i64) -> bool, i64, i32 {
        var pc = pc0;
        var iv = iv0;
        while pc < max_peel && sc_is_known_predicate(p, iv, bound) {
            iv = sc_add(iv, step);
            pc++;
        }
        return sc_is_known_predicate(sc_inverse_pred(p & 0xFF), iv, bound), pc, iv;
    }
    var stack_c: i32[>..<] = [];
    var stack_d: i64[>..<] = [];
    fn compute_peel_count(cond0: i32) {
        stack_c.push(cond0);
        stack_d.push(0);
        while stack_c.len > 0 {
            let cond = stack_c.pop();
            let depth = stack_d.pop();
            if !ty_is_int(vals[cond].ty) || depth >= 4 { continue; }
            if is_inst_op(cond, OP_AND) || is_inst_op(cond, OP_OR) {
                // ComputePeelCount(LeftVal), then ComputePeelCount(RightVal): push right first
                stack_c.push(op(cond, 1)); stack_d.push(depth + 1);
                stack_c.push(op(cond, 0)); stack_d.push(depth + 1);
                continue;
            }
            if !is_inst_op(cond, OP_ICMP) { continue; }
            var p = insts[inst_of(cond)].pred as i64;
            if has_flag(cond, FL_SAMESIGN) { p |= CP_SAMESIGN; }
            var ls = sc_get_scev(op(cond, 0));
            var rs = sc_get_scev(op(cond, 1));
            if sc_evaluate_predicate(p, ls, rs) >= 0 { continue; }
            if !sc_is_addrec(ls) {
                if sc_is_addrec(rs) { let t = ls; ls = rs; rs = t; p = lp_swapped_pred(p); }
                else { continue; }
            }
            let ar = ls;
            if sc_nops(ar) != 2 || sc_loop(ar) != l { continue; }
            if !(lp_is_equality(p) && sc_has_nw(ar)) && sc_get_monotonic_predicate_type(ar, p & 0xFF) < 0 { continue; }
            var npc = desired;
            var iv = sc_evaluate_at_iteration(ar, sc_get_constant_ty(sc_ty(ls), npc as u64, false));
            if !sc_is_known_predicate(p, iv, rs) { p = sc_inverse_pred(p & 0xFF); }
            let step = sc_get_step_recurrence(ar);
            let ok, npc2, iv2 = peel_while(npc, iv, rs, step, p & 0xFF);
            npc = npc2;
            iv = iv2;
            if !ok {
                if should_peel_last_iteration(l, p, ar, rs) { desired_last = 1; }
                continue;
            }
            let next_iv = sc_add(iv, step);
            if lp_is_equality(p) && !sc_is_known_predicate(sc_inverse_pred(p & 0xFF), next_iv, rs) &&
               !sc_is_known_predicate(p, iv, rs) && sc_is_known_predicate(p, next_iv, rs) {
                if npc >= max_peel { continue; }
                npc++;
            }
            if npc > desired { desired = npc; }
            if npc > desired_last { desired_last = npc; }
        }
    }
    fn compute_peel_count_minmax(mm: i32) {
        if !ty_is_int(vals[mm].ty) { return; }
        let lhs = cb_arg(mm, 0);
        let rhs = cb_arg(mm, 1);
        var bs: i32 = -1;
        var is_: i32 = -1;
        if lp_is_loop_invariant(l, lhs) { bs = sc_get_scev(lhs); is_ = sc_get_scev(rhs); }
        else if lp_is_loop_invariant(l, rhs) { bs = sc_get_scev(rhs); is_ = sc_get_scev(lhs); }
        else { return; }
        if !sc_is_addrec(is_) || sc_nops(is_) != 2 || sc_loop(is_) != l { return; }
        let step = sc_get_step_recurrence(is_);
        let id = inst_iid(mm);
        let signed = id == IID_smin || id == IID_smax;
        var p: i64 = 0;
        if sc_is_known_positive(step) { p = if signed { 40 } else { 36 }; }
        else if sc_is_known_negative(step) { p = if signed { 38 } else { 34 }; }
        else { return; }
        if !(if signed { sc_has_nsw(is_) } else { sc_has_nuw(is_) }) { return; }
        var npc = desired;
        let iv = sc_evaluate_at_iteration(is_, sc_get_constant_ty(sc_ty(is_), npc as u64, false));
        let ok, npc2, iv2 = peel_while(npc, iv, bs, step, p);
        npc = npc2;
        if !ok {
            if should_peel_last_iteration(l, p, is_, bs) { desired_last = 1; }
            return;
        }
        desired = npc;
    }
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        var i = block_first(bb);
        while i >= 0 {
            if iop(i) == OP_SELECT { compute_peel_count(op(i, 0)); }
            let id = inst_iid(i);
            if id == IID_smin || id == IID_smax || id == IID_umin || id == IID_umax { compute_peel_count_minmax(i); }
            i = inst_next(i);
        }
        let bi = block_terminator(bb);
        if iop(bi) != OP_CONDBR { continue; }
        if loop_latch(l) == bb { continue; }
        compute_peel_count(op(bi, 0));
    }
    return desired, desired_last;
}

// violatesLegacyMultiExitLoopCheck(L)
fn violates_legacy_multi_exit_loop_check(l: i32) -> bool {
    let latch = loop_latch(l);
    if latch < 0 { return true; }
    let br = block_terminator(latch);
    if iop(br) != OP_CONDBR || !loop_is_exiting(l, latch) { return true; }
    var exits: i32[>..<] = [];
    loop_unique_non_latch_exit_blocks(l, exits);
    for e in exits { if cu_terminating_deoptimize_call(e) < 0 { return true; } }
    return false;
}

// computePeelCount(L, LoopSize, PeelPrefs, TripCount, DT, SE, TTI, AC, Threshold)
fn compute_peel_count(l: i32, loop_size: i64, pp: PeelPrefs&, trip_count: i64, threshold: i64) {
    let target_peel = pp.peel_count;
    pp.peel_count = 0;
    pp.peel_last = false;
    if !can_peel(l) { return; }
    if !pp.allow_loop_nests_peeling && !loop_is_innermost(l) { return; }
    if flag_given("unroll-force-peel-count") {
        pp.peel_count = flag_int("unroll-force-peel-count", 0) & 0xFFFFFFFF;
        pp.peel_profiled_iterations = true;
        return;
    }
    if !pp.allow_peeling { return; }
    if 2 * loop_size > threshold { return; }
    var already: i64 = 0;
    let hp, pv = lmd_optional_int(l, "llvm.loop.peeled.count");
    if hp { already = pv & 0xFFFFFFFF; }
    let max_count = flag_int("unroll-peel-max-count", 7) & 0xFFFFFFFF;
    if already >= max_count { return; }
    var max_peel = max_count;
    let byc = ((threshold / loop_size) - 1) & 0xFFFFFFFF;
    if byc < max_peel { max_peel = byc; }
    var desired = target_peel;
    if max_peel > desired {
        let np = pa_iterations_to_peel(l, max_peel, flag_bool("enable-peeling-for-iv", false));
        if np > desired { desired = np; }
    }
    let ce, cel = count_to_eliminate_compares(l, max_peel);
    if ce > desired { desired = ce; }
    if desired == 0 { desired = peel_to_turn_invariant_loads_dereferenceable(l); }
    if desired > 0 {
        if max_peel < desired { desired = max_peel; }
        if desired + already <= max_count {
            pp.peel_count = desired;
            pp.peel_profiled_iterations = false;
            pp.peel_last = false;
            return;
        }
    }
    if cel > 0 {
        var dl = cel;
        if max_peel < dl { dl = max_peel; }
        if dl + already <= max_count {
            pp.peel_count = dl;
            pp.peel_profiled_iterations = false;
            pp.peel_last = true;
            return;
        }
    }
    if trip_count != 0 { return; }
    if !pp.peel_profiled_iterations { return; }
    let hpd, ec = bf_entry_count(block_func(loop_header(l)));
    if hpd {
        if violates_legacy_multi_exit_loop_check(l) { return; }
        let h, etc = get_loop_estimated_trip_count(l);
        if !h { return; }
        let total = (etc as i64) + already;
        if total <= 0xFFFFFFFF && total <= max_peel {
            pp.peel_count = etc as i64;
            return;
        }
    }
}

// ---------------------------------------------------------------------------------------------
// SplitEdge / SplitBlock with DT and LI



// ---------------------------------------------------------------------------------------------
// Peeling

// cloneLoopBlocks(L, IterNumber, PeelLast, InsertTop, InsertBot, OrigPreHeader, ExitEdges, NewBlocks,
// LoopBlocks, VMap, LVMap, DT, LI, LoopLocalNoAliasDeclScopes, SE)
fn clone_loop_blocks(l: i32, iter: i64, peel_last: bool, top: i32, bot: i32, orig_ph: i32, ee_a: i32[>..<]&, ee_b: i32[>..<]&,
                     new_blocks: i32[>..<]&, rpo: i32[>..<]&, vm: i32, lvm: i32, scopes: i32[>..<]&) {
    let header = loop_header(l);
    let latch = loop_latch(l);
    let ph = loop_preheader(l);
    let fv = block_func(header);
    let parent = loop_parent(l);
    for bb in rpo {
        let nb = clone_basic_block(bb, vm, ".peel", fv, false);
        new_blocks.push(nb);
        if parent >= 0 && li_loop_for(bb) == l { loop_add_basic_block_to_loop(parent, nb); }
        vmm_set(vm, bb, nb);
        if header == bb { dt_add_new_block(fv, DT_DOM, nb, top); }
        else { dt_add_new_block(fv, DT_DOM, nb, vmm_get(vm, dt_idom(DT_DOM, bb))); }
    }
    var ext: u8[>..] = [];
    format(ext, "Peel", iter);
    clone_and_adapt_noalias_scopes(scopes, new_blocks, ext);
    for k in loop_nsubs(l) { clone_loop(loop_sub(l, k), parent, vm); }
    term_set_succ(block_terminator(top), 0, vmm_get(vm, header));
    let nlatch = vmm_get(vm, latch);
    if peel_last {
        let lt = block_terminator(nlatch);
        term_set_succ(lt, 0, bot);
        term_set_succ(lt, 1, bot);
    } else {
        let lt = block_terminator(nlatch);
        for k in term_nsucc(lt) {
            if term_succ(lt, k) == header { term_set_succ(lt, k, bot); break; }
        }
    }
    dt_change_idom(fv, DT_DOM, bot, nlatch);
    if peel_last {
        let pos = first_non_phi(top);
        // IRBuilder<> B(InsertTop, InsertTop->getFirstNonPHIIt()): SetInsertPoint takes the debug location of the
        // instruction there (getStableDebugLoc), and CreatePHI gives it to every new phi
        let bdl = if pos >= 0 { inst_get_md(pos, 0) } else { -1 };
        var i = block_first(header);
        while i >= 0 && iop(i) == OP_PHI {
            let np = vmm_get(vm, i);
            let pn = new_phi(vals[np].ty, 2);
            inst_insert_before_head(pn, pos);
            if bdl >= 0 { inst_set_md(pn, 0, bdl); }
            inst_erase_from_parent(np);
            if orig_ph >= 0 { phi_add_incoming(pn, phi_value_for_block(i, ph), orig_ph); }
            phi_add_incoming(pn, phi_value_for_block(i, latch), latch);
            vmm_set(vm, i, pn);
            i = inst_next(i);
        }
    } else {
        var i = block_first(header);
        while i >= 0 && iop(i) == OP_PHI {
            let np = vmm_get(vm, i);
            if iter == 0 {
                vmm_set(vm, i, phi_value_for_block(np, ph));
            } else {
                let lv = phi_value_for_block(np, latch);
                if is_inst(lv) && loop_contains(l, inst_parent(lv)) { vmm_set(vm, i, vmm_get(lvm, lv)); }
                else { vmm_set(vm, i, lv); }
            }
            inst_erase_from_parent(np);
            i = inst_next(i);
        }
    }
    for k in ee_a.len {
        let from = ee_a[k];
        var q = block_first(ee_b[k]);
        while q >= 0 && iop(q) == OP_PHI {
            var lv = phi_value_for_block(q, from);
            if is_inst(lv) && loop_contains(l, inst_parent(lv)) { lv = vmm_get(vm, lv); }
            phi_add_incoming(q, lv, vmm_get(vm, from));
            sc_forget_lcssa_phi_with_new_predecessor(l, q);
            q = inst_next(q);
        }
    }
    vmm_copy_into(lvm, vm);
}

// peelLoop(L, PeelCount, PeelLast, LI, SE, DT, AC, PreserveLCSSA, LVMap)
fn peel_loop(l0: i32, peel_count: i64, peel_last: bool, preserve_lcssa: bool, lvm: i32) {
    var l = l0;
    var rpo: i32[>..<] = [];
    loop_blocks_rpo(l, rpo);
    let header = loop_header(l);
    let ph = loop_preheader(l);
    let latch = loop_latch(l);
    let fv = block_func(header);
    // getExitEdges
    var ee_a: i32[>..<] = [];
    var ee_b: i32[>..<] = [];
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        let t = block_terminator(bb);
        for j in term_nsucc(t) { let s = term_succ(t, j); if !loop_contains(l, s) { ee_a.push(bb); ee_b.push(s); } }
    }
    // NonLoopBlocksIDom (MapVector)
    var nli_k: i32[>..<] = [];
    var nli_v: i32[>..<] = [];
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        var ch: i32[>..<] = [];
        ul_dt_children(fv, bb, ch);
        var upd: i32[>..<] = [];
        for c in ch { if !loop_contains(l, c) { upd.push(c); } }
        let nidom = dt_find_ncd(DT_DOM, bb, latch);
        for c in upd {
            let j = position(nli_k, c);
            if j >= 0 { nli_v[j] = nidom; } else { nli_k.push(c); nli_v.push(nidom); }
        }
    }
    var top: i32 = -1;
    var bot: i32 = -1;
    var nph: i32 = -1;
    var ev_p: i32[>..<] = [];
    var ev_v: i32[>..<] = [];
    if peel_last {
        let exit = loop_exit_block(l);
        var q = block_first(exit);
        while q >= 0 && iop(q) == OP_PHI { ev_p.push(q); ev_v.push(phi_value_for_block(q, latch)); q = inst_next(q); }
        let btc = sc_get_backedge_taken_count(l, BTC_EXACT);
        top = lp_split_edge(latch, exit);
        bot = lp_split_block(top, block_terminator(top));
        var n1: u8[>..] = []; n1.append(val_name(exit)); n1.append(".peel.begin");
        set_name(top, n1);
        var n2: u8[>..] = []; n2.append(val_name(exit)); n2.append(".peel.next");
        set_name(bot, n2);
        if sc_is_known_non_zero(btc) {
            let p = get_loop_probability(l);
            if p != 0xFFFFFFFF {
                let exitp = bp_compl(p);
                if exitp != 0 {
                    let freq = 1.0 / bp_to_double(exitp);
                    var nf = freq - 1.0;
                    if nf < 1.0 { nf = 1.0; }
                    set_loop_probability(l, bp_from_double(1.0 - 1.0 / nf));
                }
            }
        } else {
            nph = lp_split_edge(ph, header);
            sx_begin("loop-peel", true);
            let phbr = block_terminator(ph);
            let btcv = sx_expand_code_for_at(btc, sc_ty(btc), phbr);
            sx_end();
            let cond = lp_icmp_ne_zero(btcv, phbr);
            let bi = create_inst(OP_CONDBR, T_VOID, [cond, nph, top]);
            inst_insert_before(bi, phbr);
            // IRBuilder<> B(PreHeaderBR): CreateCondBr gets the branch's debug location too
            let pdl = inst_get_md(phbr, 0);
            if pdl >= 0 { inst_set_md(bi, 0, pdl); }
            let olb = block_terminator(latch);
            var ws: u64[>..<] = [];
            if pd_extract(olb, ws) {
                if loop_exit_block(l) == term_succ(olb, 0) { let t = ws[0]; ws[0] = ws[1]; ws[1] = t; }
                pd_set(bi, ws, false, false);
            }
            inst_erase_from_parent(phbr);
            dt_change_idom(fv, DT_DOM, top, ph);
        }
    } else {
        top = lp_split_edge(ph, header);
        bot = lp_split_block(top, block_terminator(top));
        nph = lp_split_block(bot, block_terminator(bot));
        var n1: u8[>..] = []; n1.append(val_name(header)); n1.append(".peel.begin");
        set_name(top, n1);
        var n2: u8[>..] = []; n2.append(val_name(header)); n2.append(".peel.next");
        set_name(bot, n2);
        var n3: u8[>..] = []; n3.append(val_name(ph)); n3.append(".peel.newph");
        set_name(nph, n3);
    }
    let latch_term = block_terminator(latch);
    var scopes: i32[>..<] = [];
    var lblocks: i32[>..<] = [];
    for k in loop_nblocks(l) { lblocks.push(loop_block(l, k)); }
    identify_noalias_scopes_to_clone(lblocks, scopes);
    let vm = vmm_new();
    for iter in peel_count {
        var new_blocks: i32[>..<] = [];
        clone_loop_blocks(l, iter, peel_last, top, bot, if nph >= 0 { ph } else { -1 }, ee_a, ee_b, new_blocks, rpo, vm, lvm, scopes);
        remap_instructions_in_blocks(new_blocks, vm);
        if iter == 0 {
            if peel_last {
                let cmp = op(block_terminator(loop_latch(l)), 0);
                let b1 = op(cmp, 1);
                let one = c_int(vals[b1].ty, 1);
                let sub = lp_create_sub(b1, one, cmp);
                set_op(cmp, 1, sub);
            } else {
                for k in nli_k.len { dt_change_idom(fv, DT_DOM, nli_k[k], vmm_get(lvm, nli_v[k])); }
            }
        }
        let ltc = vmm_get(vm, latch_term);
        inst_set_md(ltc, MDK_LOOP, -1);
        top = bot;
        bot = lp_split_block(bot, block_terminator(bot));
        var n2: u8[>..] = []; n2.append(val_name(header)); n2.append(".peel.next");
        set_name(bot, n2);
        // F->splice(InsertTop, F, NewBlocks[0], F->end())
        var b = new_blocks[0];
        while b >= 0 { let nx = block_next(b); block_move_before(b, top); b = nx; }
    }
    if peel_last {
        for k in ev_p.len {
            let pv = ev_p[k];
            let e = ev_v[k];
            if is_inst(e) && loop_contains(l, inst_parent(e)) { ac_rauw(pv, vmm_get(vm, e)); rauw(pv, vmm_get(vm, e)); }
            else { ac_rauw(pv, e); rauw(pv, e); }
            inst_erase_from_parent(pv);
        }
        let save = lcssa_se;
        lcssa_se = true;
        form_lcssa(l);
        lcssa_se = save;
    } else {
        var i = block_first(header);
        while i >= 0 && iop(i) == OP_PHI {
            var nv = phi_value_for_block(i, latch);
            if is_inst(nv) && loop_contains(l, inst_parent(nv)) { nv = vmm_get(lvm, nv); }
            let k = phi_block_index(i, nph);
            set_op(i, k, nv);
            i = inst_next(i);
        }
    }
    var already: i64 = 0;
    let hp, pv = lmd_optional_int(l, "llvm.loop.peeled.count");
    if hp { already = pv & 0xFFFFFFFF; }
    let total = already + peel_count;
    add_string_metadata_to_loop(l, "llvm.loop.peeled.count", total);
    let h, etc = get_loop_estimated_trip_count(l);
    if h {
        var n = etc as i64;
        if n < total { n = 0; } else { n -= total; }
        set_loop_estimated_trip_count(l, n as u64, false, 0);
    }
    if loop_parent(l) >= 0 { l = loop_parent(l); }
    sc_forget_topmost_loop(l);
    sc_forget_block_and_loop_dispositions_all();
    let save_ls = ls_se;
    ls_se = true;
    simplify_loop(l, preserve_lcssa);
    ls_se = save_ls;
}
// IRBuilder B(PreHeaderBR); B.CreateICmpNE(V, 0)
fn lp_icmp_ne_zero(v: i32, before: i32) -> i32 {
    let z = c_int(vals[v].ty, 0);
    if is_constant(v) {
        let r = cf_fold_cmp_operands(33, v, z, -1);
        if r >= 0 { return r; }
    }
    let c = create_inst(OP_ICMP, cmp_result_ty(vals[v].ty), [v, z]);
    insts[inst_of(c)].pred = 33;
    inst_insert_before(c, before);
    let dl = inst_get_md(before, 0);
    if dl >= 0 { inst_set_md(c, 0, dl); }
    return c;
}
// IRBuilder B(Cmp); B.CreateSub(A, B)
fn lp_create_sub(a: i32, b: i32, before: i32) -> i32 {
    if is_constant(a) { return ce_binop(OP_SUB, a, b, 0); }
    let s = create_inst(OP_SUB, vals[a].ty, [a, b]);
    inst_insert_before(s, before);
    let dl = inst_get_md(before, 0);
    if dl >= 0 { inst_set_md(s, 0, dl); }
    return s;
}
