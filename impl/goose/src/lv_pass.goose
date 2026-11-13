// LoopVectorizePass: the driver of llvm/lib/Transforms/Vectorize/LoopVectorize.cpp (runImpl, collectSupportedLoops,
// processLoop, getEpilogueLowering, getSmallBestKnownTC / getSmallConstantTripCount / getMaxTCFromNonZeroRange,
// LoopVectorizationCostModel::computeMaxVF / requiresScalarEpilogue / setTailFoldingStyle /
// collectValuesToIgnore) and VFSelectionContext from llvm/lib/Transforms/Vectorize/LoopVectorizationPlanner.cpp
// (computeFeasibleMaxVF, getMaximizedVFForTarget, clampVFByMaxTripCount, getSmallestAndWidestTypes,
// collectElementTypesForWidening, runtimeChecksRequired), containsIrreducibleCFG (llvm/include/llvm/Analysis/
// CFG.h) and LoopBlocksDFS (llvm/lib/Analysis/LoopIterator.cpp).
// Vector factors are fixed (X86 has no scalable vectors; scalable requests fail loudly): a VF is an i64.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import flags;
import analyses;
import gen_iids;
import gen_attrs;
import datalayout;
import pm;
import apint;
import local;
import domtree;
import loopinfo;
import loop_md;
import loopsimplify;
import loopsimplify_pass;
import lcssa;
import scev;
import scev_create;
import scev_eval;
import scev_btc;
import scev_range;
import scev_guards;
import scev_lt;
import pse;
import laa;
import aa;
import tli;
import tti;
import gen_x86target;
import tti_vec;
import tti_x86_vec;
import ivusers;
import demandedbits;
import iv_descriptors;
import lv_legality;
import lv_interleave;
import lv_cm;
import lv_cost;
import vplan_cost;
import vplan;
import vplan_construct;
import vplan_transforms;
import lv_plan;
import lv_exec;

// EpilogueLowering
let CM_EPILOGUE_ALLOWED: i64 = 0;
let CM_EPILOGUE_NOT_ALLOWED_OPT_SIZE: i64 = 1;
let CM_EPILOGUE_NOT_ALLOWED_FOLD_TAIL: i64 = 2;
let CM_EPILOGUE_NOT_NEEDED_FOLD_TAIL: i64 = 3;
let CM_EPILOGUE_NOT_ALLOWED_LOW_TRIP_LOOP: i64 = 4;

// TailFoldingStyle
let TFS_NONE: i64 = 0; let TFS_DATA: i64 = 1; let TFS_DATA_WITHOUT_LANE_MASK: i64 = 2; let TFS_DATA_AND_CONTROL_FLOW: i64 = 3;
let TFS_DATA_AND_CONTROL_FLOW_WITHOUT_RT_CHECK: i64 = 4; let TFS_DATA_WITH_EVL: i64 = 5;

var lv_l: i32 = -1;
var lv_fv: i32 = -1;
var lv_pse: i32 = -1;
var cm_epilogue: i64 = 0;          // EpilogueLoweringStatus
var cm_tfs: i64 = 0;               // ChosenTailFoldingStyle
var cm_partial_alias: i64 = 0;     // 0 NotDecided, 1 Disabled, 2 Enabled
var cfg_elem_types: i32[>..<];     // ElementTypesInLoop
var cfg_max_safe_elements: i64 = 0xFFFFFFFF;
var cfg_max_bw_fixed: i64 = 0;     // MaxPermissibleVFWithoutMaxBW.FixedVF
var lv_opt_for_size: bool = false;

fn lv_reset_loop() {
    cm_epilogue = CM_EPILOGUE_ALLOWED;
    cm_tfs = TFS_NONE;
    cm_partial_alias = 0;
    hm_clear(cm_vals_to_ignore);
    hm_clear(cm_vec_vals_to_ignore);
    cfg_elem_types.clear();
    cfg_max_safe_elements = 0xFFFFFFFF;
    cfg_max_bw_fixed = 0;
    ivd_reset();
}

// ---------------------------------------------------------------------------------------------
// LoopBlocksDFS / containsIrreducibleCFG

// containsIrreducibleCFG(LoopBlocksRPO, LI)
fn lv_contains_irreducible_cfg(l: i32) -> bool {
    var po: i32[>..<] = [];
    lv_loop_postorder(l, po);
    var visited = hm_new();
    var k = po.len - 1;
    while k >= 0 {
        let n = po[k];
        k--;
        hm_put(visited, n as u64, 1);
        for j in block_nsucc(n) {
            let s = block_succ(n, j);
            if !hm_has(visited, s as u64) { continue; }
            var proper = false;
            var lp = li_loop_for(n);
            while lp >= 0 { if loop_header(lp) == s { proper = true; break; } lp = loop_parent(lp); }
            if !proper { return true; }
        }
    }
    return false;
}

// collectSupportedLoops
recursive fn lv_collect_supported_loops(l: i32, out: i32[>..<]&) {
    if loop_is_innermost(l) {
        if flag_bool("vplan-build-outerloop-stress-test", false) || flag_bool("enable-vplan-native-path", false) {
            lvx_unported("outer-loop vectorization (VPlan-native path)");
        }
        if !lv_contains_irreducible_cfg(l) { out.push(l); return; }
    } else if flag_bool("vplan-build-outerloop-stress-test", false) || flag_bool("enable-vplan-native-path", false) {
        lvx_unported("outer-loop vectorization (VPlan-native path)");
    }
    for k in loop_nsubs(l) { lv_collect_supported_loops(loop_sub(l, k), out); }
}

// ---------------------------------------------------------------------------------------------
// trip counts

// getSmallConstantTripCount(SE, L) (fixed VFs only)
fn lv_small_constant_trip_count(l: i32) -> i64 {
    let tc = sc_get_small_constant_trip_count(l);
    if tc != 0 { return tc; }
    let btc = sc_get_backedge_taken_count(l, BTC_EXACT);
    if sc_is_cnc(btc) { return 0; }
    let ec = sc_trip_count_from_exit_count_ty(btc, sc_ty(btc), l);
    if sc_kind(ec) == SC_VSCALE { lvx_unported("a trip count that is a multiple of vscale"); }
    return 0;
}
// PSE.getSmallConstantMaxTripCount()
var lv_pse_max_tc: i64 = -1;
fn lv_pse_small_constant_max_trip_count() -> i64 {
    if lv_pse_max_tc < 0 {
        let m = sc_out_preds.len;
        lv_pse_max_tc = sc_constant_trip_count(sc_get_predicated_btc(lv_l, BTC_CONSTANT_MAX));
        var ps: i32[>..<] = [];
        for k in m..sc_out_preds.len { ps.push(sc_out_preds[k]); }
        sc_out_preds.resize(m);
        for p in ps { pse_add_predicate(lv_pse, p); }
    }
    return lv_pse_max_tc;
}
// getMaxTCFromNonZeroRange
fn lv_max_tc_from_non_zero_range() -> i64 {
    let btc = pse_get_backedge_taken_count(lv_pse);
    if sc_is_cnc(btc) { return 0; }
    let tc = sc_trip_count_from_exit_count_ty(btc, sc_ty(btc), lv_l);
    let mx = sc_get_unsigned_range_max(tc);
    if !ap_is_zero(mx) && ap_active_bits(mx) <= 32 { return ap_lo64(mx) as i64; }
    return 0;
}
// getSmallBestKnownTC: 0 = std::nullopt
fn lv_small_best_known_tc(can_use_constant_max: bool, can_exclude_zero: bool, upper_bound_only: bool) -> i64 {
    let tc = lv_small_constant_trip_count(lv_l);
    if tc != 0 { return tc; }
    if flag_bool("loop-vectorize-with-block-frequency", true) && !upper_bound_only {
        let est = lv_loop_estimated_trip_count(lv_l);
        if est >= 0 { return est; }
    }
    if !can_use_constant_max { return 0; }
    let mx = lv_pse_small_constant_max_trip_count();
    if mx != 0 { return mx; }
    if can_use_constant_max && can_exclude_zero {
        let r = lv_max_tc_from_non_zero_range();
        if r != 0 { return r; }
    }
    return 0;
}
// llvm::getLoopEstimatedTripCount(L): -1 = std::nullopt
fn lv_loop_estimated_trip_count(l: i32) -> i64 {
    let has, v = get_loop_estimated_trip_count(l);
    return if has { v as i64 } else { -1 };
}

// ---------------------------------------------------------------------------------------------
// cost-model state queries

fn cm_is_epilogue_allowed() -> bool { cm_epilogue == CM_EPILOGUE_ALLOWED }
fn cm_prefer_tail_folded_loop() -> bool { cm_epilogue == CM_EPILOGUE_NOT_NEEDED_FOLD_TAIL || cm_epilogue == CM_EPILOGUE_NOT_ALLOWED_FOLD_TAIL }
fn cm_fold_tail_by_masking() -> bool { cm_tfs != TFS_NONE }
fn cm_mask_partial_aliasing() -> bool { cm_partial_alias == 2 }
fn lv_enable_early_exit() -> bool { flag_bool("enable-early-exit-vectorization", true) }

// requiresScalarEpilogue(IsVectorizing)
fn cm_requires_scalar_epilogue(is_vectorizing: bool) -> bool {
    if !cm_is_epilogue_allowed() { return false; }
    if loop_exiting_block(lv_l) != loop_latch(lv_l) && !(lv_enable_early_exit() && lvl_has_uncountable_early_exit()) { return true; }
    if is_vectorizing && iai_requires_scalar_epilogue() { return true; }
    return false;
}

// setTailFoldingStyle(IsScalableVF, UserIC)
fn cm_set_tail_folding_style(user_ic: i64) {
    if !lvl_can_fold_tail_by_masking() { cm_tfs = TFS_NONE; return; }
    cm_tfs = TFS_DATA_WITHOUT_LANE_MASK;
    if flag_given("force-tail-folding-style") {
        let s = flag_str("force-tail-folding-style");
        if s == "none" { cm_tfs = TFS_NONE; }
        else if s == "data" { cm_tfs = TFS_DATA; }
        else if s == "data-without-lane-mask" { cm_tfs = TFS_DATA_WITHOUT_LANE_MASK; }
        else if s == "data-and-control" { cm_tfs = TFS_DATA_AND_CONTROL_FLOW; }
        else if s == "data-and-control-without-rt-check" { cm_tfs = TFS_DATA_AND_CONTROL_FLOW_WITHOUT_RT_CHECK; }
        else if s == "data-with-evl" { cm_tfs = TFS_DATA_WITH_EVL; }
        else { fatal(str("loop-vectorize: invalid -force-tail-folding-style=", s)); }
    }
    if cm_tfs != TFS_DATA_WITH_EVL { return; }
    // EVL needs scalable VFs and TTI.hasActiveVectorLength(): never on X86 / NoTTI
    if cm_epilogue == CM_EPILOGUE_ALLOWED || cm_epilogue == CM_EPILOGUE_NOT_NEEDED_FOLD_TAIL { cm_tfs = TFS_NONE; }
    else { cm_tfs = TFS_DATA_WITHOUT_LANE_MASK; }
}

// collectValuesToIgnore
fn cm_collect_values_to_ignore() {
    iu_collect_ephemeral_values(lv_l);
    var k: i64 = 0;
    // ValuesToIgnore starts as the ephemeral values (iu_eph is a set; copy its members by walking the loop)
    let l = lv_l;
    for b in loop_nblocks(l) {
        var i = block_first(loop_block(l, b));
        while i >= 0 { if hm_has(iu_eph, i as u64) { hm_put(cm_vals_to_ignore, i as u64, 1); } i = inst_next(i); }
    }
    var dead_ops: i32[>..<] = [];
    var dead_ilv_ptrs: i32[>..<] = [];
    let rse = cm_requires_scalar_epilogue(true);
    fn live_out_dead(u: i32) -> bool { rse && !loop_contains(l, inst_parent(u)) }
    fn ignored(u: i32) -> bool { hm_has(cm_vec_vals_to_ignore, u as u64) || hm_has(cm_vals_to_ignore, u as u64) }
    var po: i32[>..<] = [];
    lv_loop_postorder(l, po);
    local_have_tli = true;
    for bb in po {
        var i = block_last(bb);
        while i >= 0 {
            if ignored(i) { i = inst_prev(i); continue; }
            if would_be_trivially_dead(i) {
                var all = true;
                var u = vals[i].first_use;
                while u >= 0 { let us = uses[u].user; if !ignored(us) && !live_out_dead(us) { all = false; } u = uses[u].next; }
                if all { dead_ops.push(i); }
            }
            // interleave groups: only the insert position gets a pointer; queue the other members' addresses
            if iai_is_interleaved(i) && ig_insert_pos(iai_group_of(i)) != i { dead_ilv_ptrs.push(laa_ldst_ptr(i)); }
            if iop(i) == OP_CONDBR { dead_ops.push(i); }
            i = inst_prev(i);
        }
    }
    // mark ops feeding interleave group members as free if only other dead computations use them
    var di: i64 = 0;
    while di < dead_ilv_ptrs.len {
        let o = dead_ilv_ptrs[di];
        di++;
        if !is_inst(o) || !loop_contains(l, inst_parent(o)) { continue; }
        var live = false;
        var u = vals[o].first_use;
        while u >= 0 {
            let us = uses[u].user;
            if !hm_has(cm_vec_vals_to_ignore, us as u64) && (!iai_is_interleaved(us) || ig_insert_pos(iai_group_of(us)) == us) { live = true; }
            u = uses[u].next;
        }
        if live { continue; }
        hm_put(cm_vec_vals_to_ignore, o as u64, 1);
        for j in nops(o) { dead_ilv_ptrs.push(op(o, j)); }
    }
    let header = loop_header(l);
    fn is_empty_block(bb: i32) -> bool {
        var i = block_first(bb);
        while i >= 0 {
            if !(hm_has(cm_vals_to_ignore, i as u64) || hm_has(cm_vec_vals_to_ignore, i as u64) || iop(i) == OP_BR) { return false; }
            i = inst_next(i);
        }
        return true;
    }
    k = 0;
    while k < dead_ops.len {
        let o = dead_ops[k];
        k++;
        if is_inst(o) && iop(o) == OP_CONDBR {
            let tb = term_succ(o, 0);
            let eb = term_succ(o, 1);
            if !loop_contains(l, tb) || !loop_contains(l, eb) { continue; }
            let te = is_empty_block(tb);
            let ee = is_empty_block(eb);
            let tss = if block_nsucc(tb) == 1 { block_succ(tb, 0) } else { -1 };
            let ess = if block_nsucc(eb) == 1 { block_succ(eb, 0) } else { -1 };
            if (te && ee) || (te && tss == eb && iop(block_first(eb)) != OP_PHI) ||
               (ee && ess == tb && iop(block_first(tb)) != OP_PHI) {
                hm_put(cm_vec_vals_to_ignore, o as u64, 1);
                dead_ops.push(op(o, 0));
            }
            continue;
        }
        if !is_inst(o) || !loop_contains(l, inst_parent(o)) || (iop(o) == OP_PHI && inst_parent(o) == header) ||
           !would_be_trivially_dead(o) { continue; }
        var any_live = false;
        var all_scalar_ignored = true;
        var u = vals[o].first_use;
        while u >= 0 {
            let us = uses[u].user;
            if !hm_has(cm_vec_vals_to_ignore, us as u64) && !hm_has(cm_vals_to_ignore, us as u64) && !live_out_dead(us) { any_live = true; }
            if !hm_has(cm_vals_to_ignore, us as u64) { all_scalar_ignored = false; }
            u = uses[u].next;
        }
        if any_live { continue; }
        if all_scalar_ignored { hm_put(cm_vals_to_ignore, o as u64, 1); }
        hm_put(cm_vec_vals_to_ignore, o as u64, 1);
        for j in nops(o) { dead_ops.push(op(o, j)); }
    }
    local_have_tli = false;
    for d in lvl_rdx_desc { for j in rdx_descs[d].casts_n as i64 { hm_put(cm_vec_vals_to_ignore, rdx_cast(d, j) as u64, 1); } }
    for d in lvl_ind_desc { for j in ind_descs[d].casts_n as i64 { hm_put(cm_vec_vals_to_ignore, ind_cast(d, j) as u64, 1); } }
}

// ---------------------------------------------------------------------------------------------
// VFSelectionContext

// useOrderedReductions(RdxDesc)
fn cfg_use_ordered_reductions(d: i32) -> bool { !lvh_allow_reordering() && rdx_descs[d].ordered }
fn lv_prefer_in_loop_reductions() -> bool { flag_bool("prefer-inloop-reductions", false) }

// collectElementTypesForWidening(&ValuesToIgnore)
fn cfg_collect_element_types_for_widening() {
    cfg_elem_types.clear();
    for b in loop_nblocks(lv_l) {
        var i = block_first(loop_block(lv_l, b));
        while i >= 0 {
            var t: i32 = vals[i].ty as i32;
            let o = iop(i);
            if hm_has(cm_vals_to_ignore, i as u64) || (o != OP_LOAD && o != OP_STORE && o != OP_PHI) { i = inst_next(i); continue; }
            if o == OP_PHI {
                let d = lvl_rdx_of(i);
                if d < 0 { i = inst_next(i); continue; }
                // TTI.preferInLoopReduction: false on X86 and the base
                if lv_prefer_in_loop_reductions() || cfg_use_ordered_reductions(d) { i = inst_next(i); continue; }
                t = rdx_descs[d].rty;
            }
            if o == OP_STORE { t = vals[op(i, 0)].ty; }
            var found = false;
            for x in cfg_elem_types { if x == t { found = true; } }
            if !found { cfg_elem_types.push(t); }
            i = inst_next(i);
        }
    }
}

// getSmallestAndWidestTypes
fn cfg_smallest_and_widest_types() -> i64, i64 {
    var mn: i64 = 0xFFFFFFFF;
    var mx: i64 = 8;
    if cfg_elem_types.len == 0 && lvl_rdx_desc.len != 0 {
        for d in lvl_rdx_desc {
            let rb = ty_bits(ty_scalar(rdx_descs[d].rty));
            let mw = rdx_descs[d].min_width;
            let a = if mw < rb { mw } else { rb };
            if a < mn { mn = a; }
            if rb > mx { mx = rb; }
        }
    } else {
        for t in cfg_elem_types {
            let w = dl_size_bits(ty_scalar(t));
            if w < mn { mn = w; }
            if w > mx { mx = w; }
        }
    }
    return mn, mx;
}

fn lv_bit_floor(x: i64) -> i64 { if x <= 0 { return 0; } var p: i64 = 1; while p * 2 <= x { p *= 2; } return p; }

// useMaxBandwidth(IsScalable = false)
fn cfg_use_max_bandwidth() -> bool {
    if flag_given("vectorizer-maximize-bandwidth") { return flag_bool("vectorizer-maximize-bandwidth", false); }
    // TTI.shouldMaximizeVectorBandwidth: false on X86 and the base
    return flag_bool("vectorizer-maximize-bandwidth-for-vector-calls", true) && lvl_vec_call_variants;
}

// clampVFByMaxTripCount
fn cfg_clamp_vf_by_max_trip_count(vf: i64, max_tc0: i64, user_ic: i64, fold_tail: bool, req_scalar_epi: bool) -> i64 {
    var max_tc = max_tc0;
    if max_tc > 0 && req_scalar_epi { max_tc -= 1; }
    let ic = if user_ic > 0 { user_ic } else { 1 };
    let est = vf * ic;
    let pow2 = max_tc > 0 && (max_tc & (max_tc - 1)) == 0;
    if max_tc != 0 && max_tc <= est && (!fold_tail || pow2) {
        var c = lv_bit_floor(max_tc / ic);
        if c == 0 { c = 1; }
        return c;
    }
    return vf;
}

// getMaximizedVFForTarget (fixed VFs)
fn cfg_maximized_vf_for_target(max_tc: i64, smallest: i64, widest: i64, max_safe_vf: i64, user_ic: i64, fold_tail: bool, rse: bool) -> i64 {
    let wr = tv_register_bit_width(1);
    var mvec = lv_bit_floor(wr / widest);
    if max_safe_vf < mvec { mvec = max_safe_vf; }
    if mvec == 0 { return 1; }
    var mvf = cfg_clamp_vf_by_max_trip_count(mvec, max_tc, user_ic, fold_tail, rse);
    if mvf != mvec { return mvf; }
    cfg_max_bw_fixed = mvf;
    if cfg_use_max_bandwidth() {
        var m = lv_bit_floor(wr / smallest);
        if max_safe_vf < m { m = max_safe_vf; }
        // TTI.getMinimumVF: 0 on X86 and the base
        mvf = cfg_clamp_vf_by_max_trip_count(m, max_tc, user_ic, fold_tail, rse);
    }
    return mvf;
}

// computeFeasibleMaxVF: the fixed MaxVF (0 = none)
fn cfg_compute_feasible_max_vf(max_tc: i64, user_vf: i64, user_ic: i64, fold_tail: bool, rse: bool) -> i64 {
    let smallest, widest = cfg_smallest_and_widest_types();
    var max_safe_p2 = lv_bit_floor((lvl_max_safe_vector_width_bits() as i64) / widest);
    if mdc_max_sl_fwd != 0xFFFFFFFFFFFFFFFF {
        let sl = (mdc_max_sl_fwd as i64) / widest;
        if sl < max_safe_p2 { max_safe_p2 = sl; }
    }
    let max_safe_fixed = max_safe_p2;
    if !lvl_is_safe_for_any_vector_width() { cfg_max_safe_elements = max_safe_p2; }
    if user_vf != 0 {
        if user_vf <= max_safe_fixed { return user_vf; }
        return max_safe_fixed;
    }
    var res: i64 = 1;
    let m = cfg_maximized_vf_for_target(max_tc, smallest, widest, max_safe_fixed, user_ic, fold_tail, rse);
    if m != 0 { res = m; }
    return res;
}

// runtimeChecksRequired
fn cfg_runtime_checks_required() -> bool {
    if lvl_rt_need() { return true; }
    if !su_always_true(pse_union(lv_pse)) { return true; }
    if lai_strides_k.len != 0 { return true; }
    return false;
}

// useMaskedInterleavedAccesses(TTI)
fn lv_use_masked_interleaved_accesses() -> bool {
    if flag_given("enable-masked-interleaved-mem-accesses") { return flag_bool("enable-masked-interleaved-mem-accesses", false); }
    return false;
}

// computeMaxVF(UserVF, UserIC): the fixed MaxVF, 0 = none (FixedScalableVFPair::getNone())
fn cm_compute_max_vf(user_vf: i64, user_ic: i64) -> i64 {
    let r = cm_compute_max_vf_impl(user_vf, user_ic);
    if cm_partial_alias == 0 { cm_partial_alias = 1; }
    return r;
}
fn cm_compute_max_vf_impl(user_vf: i64, user_ic: i64) -> i64 {
    if !loop_is_innermost(lv_l) { lvx_unported("outer-loop vectorization (VPlan-native path)"); }
    // TTI.hasBranchDivergence(): false on X86 and the base
    let tc = lv_small_constant_trip_count(lv_l);
    var max_tc = lv_pse_small_constant_max_trip_count();
    if max_tc == 0 && cm_epilogue == CM_EPILOGUE_ALLOWED { max_tc = lv_max_tc_from_non_zero_range(); }
    if tc == 1 { return 0; }
    let btc = sc_get_backedge_taken_count(lv_l, BTC_EXACT);
    if !sc_is_cnc(btc) && sc_bits(btc) >= ty_bits(ty_scalar(lvl_widest_ind_ty)) &&
       sc_is_known_predicate(P_EQ, btc, sc_get_minus_one(sc_ty(btc))) { return 0; }
    if cm_epilogue == CM_EPILOGUE_ALLOWED {
        return cfg_compute_feasible_max_vf(max_tc, user_vf, user_ic, false, cm_requires_scalar_epilogue(true));
    }
    if cm_epilogue == CM_EPILOGUE_NOT_ALLOWED_LOW_TRIP_LOOP || cm_epilogue == CM_EPILOGUE_NOT_ALLOWED_OPT_SIZE {
        if cfg_runtime_checks_required() { return 0; }
    }
    if !lv_use_masked_interleaved_accesses() { iai_invalidate_groups_requiring_scalar_epilogue(); }
    var mf = cfg_compute_feasible_max_vf(max_tc, user_vf, user_ic, true, cm_requires_scalar_epilogue(true));
    let max_p2 = mf;
    fn no_scalar_epilogue_needed(max_vf: i64) -> bool {
        if loop_exiting_block(lv_l) != loop_latch(lv_l) && !lvl_has_uncountable_early_exit() { return false; }
        let vfic = if user_ic != 0 { max_vf * user_ic } else { max_vf };
        let bt = pse_get_symbolic_max_btc(lv_pse);
        let ec = sc_add(bt, sc_get_one(sc_ty(bt)));
        let rem = sc_get_urem(sc_apply_loop_guards(ec, lv_l), sc_get_constant_ty(sc_ty(bt), vfic as u64, false));
        return sc_is_zero(rem);
    }
    if max_p2 > 0 {
        if no_scalar_epilogue_needed(max_p2) { return mf; }
    }
    let exp_tc = lv_small_best_known_tc(true, false, false);
    // TTI.getMinTripCountTailFoldingThreshold(): 0 on X86 and the base
    if exp_tc != 0 && exp_tc <= 0 {
        return 0;
    }
    cm_set_tail_folding_style(user_ic);
    if cm_fold_tail_by_masking() {
        if cm_tfs == TFS_DATA_WITH_EVL { lvx_unported("EVL tail folding"); }
        cm_try_to_enable_partial_alias_masking();
        return mf;
    }
    if cm_epilogue == CM_EPILOGUE_NOT_NEEDED_FOLD_TAIL { cm_epilogue = CM_EPILOGUE_ALLOWED; return mf; }
    if cm_epilogue == CM_EPILOGUE_NOT_ALLOWED_FOLD_TAIL { return 0; }
    if tc == 0 { return 0; }
    return 0;
}

// tryToEnablePartialAliasMasking
fn cm_try_to_enable_partial_alias_masking() {
    cm_partial_alias = 1;
    if !flag_bool("force-partial-aliasing-vectorization", false) || lvl_fors.len != 0 { return; }
    lvx_unported("-force-partial-aliasing-vectorization");
}

// getEpilogueLowering(F, L, Hints, OptForSize, TTI, TLI, LVL, IAI)
fn lv_get_epilogue_lowering() -> i64 {
    if func_has_fn_attr(lv_fv, AK_OptimizeForSize) || func_has_fn_attr(lv_fv, AK_MinSize) ||
       (lv_opt_for_size && lvh_get_force() != FK_ENABLED) { return CM_EPILOGUE_NOT_ALLOWED_OPT_SIZE; }
    if flag_given("tail-folding-policy") {
        let s = flag_str("tail-folding-policy");
        if s == "dont-fold-tail" { return CM_EPILOGUE_ALLOWED; }
        if s == "prefer-fold-tail" { return CM_EPILOGUE_NOT_NEEDED_FOLD_TAIL; }
        if s == "must-fold-tail" { return CM_EPILOGUE_NOT_ALLOWED_FOLD_TAIL; }
        fatal(str("loop-vectorize: invalid -tail-folding-policy=", s));
    }
    if lvh_predicate == FK_ENABLED { return CM_EPILOGUE_NOT_NEEDED_FOLD_TAIL; }
    if lvh_predicate == FK_DISABLED { return CM_EPILOGUE_ALLOWED; }
    // TTI->preferTailFoldingOverEpilogue: false on X86 and the base
    return CM_EPILOGUE_ALLOWED;
}

// ---------------------------------------------------------------------------------------------
// processLoop

fn lv_check_flags() {
    if flag_given("epilogue-vectorization-force-VF") { lvx_unported("-epilogue-vectorization-force-VF"); }
}

// processLoop(L): true when the IR changed
fn lv_process_loop(l: i32, interleave_only_when_forced: bool, vectorize_only_when_forced: bool) -> bool {
    lv_l = l;
    lv_reset_loop();
    lvh_init(l, interleave_only_when_forced);
    if !lvh_allow_vectorization(vectorize_only_when_forced) { return false; }
    lv_pse = pse_new(l);
    lv_pse_max_tc = -1;
    // shouldOptimizeForSize(Header, PSI, BFI): F->hasOptSize(), then PSI (only cached with require<profile-summary>)
    lv_opt_for_size = func_has_fn_attr(lv_fv, AK_OptimizeForSize) || func_has_fn_attr(lv_fv, AK_MinSize);
    if !lv_opt_for_size && lv_psi_cached() { lvx_unported("profile-guided size optimization (a cached ProfileSummaryAnalysis)"); }
    lvl_reset(l, lv_pse, !lv_opt_for_size);
    if !lvl_can_vectorize() { return false; }
    let inner = loop_is_innermost(l);
    if lvl_has_uncountable_early_exit() {
        if !lv_enable_early_exit() { return false; }
        if lvl_has_uncountable_exit_with_side_effects() && !flag_bool("enable-early-exit-vectorization-with-side-effects", false) { return false; }
    }
    // InterleavedAccessInfo: TTI->enableInterleavedAccessVectorization() is true on X86
    var use_interleaved = inner && tti_kind == TTI_X86 && !xst_isAtom();   // enableInterleavedAccessVectorization
    if flag_given("enable-interleaved-mem-accesses") { use_interleaved = inner && flag_bool("enable-interleaved-mem-accesses", false); }
    iai_reset();
    if use_interleaved { iai_analyze_interleaving(l, lv_pse, lv_opt_for_size, lv_use_masked_interleaved_accesses()); }
    if lvl_has_uncountable_early_exit() {
        let latch = loop_latch(l);
        for b in lvl_countable_exiting { if b != latch { return false; } }
        if iai_requires_scalar_epilogue() { return false; }
    }
    var sel = lv_get_epilogue_lowering();
    let exp_tc = lv_small_best_known_tc(true, false, false);
    if exp_tc != 0 && exp_tc < flag_int("vectorizer-min-trip-count", 16) {
        if lvh_get_force() != FK_ENABLED {
            if sel != CM_EPILOGUE_NOT_NEEDED_FOLD_TAIL { sel = CM_EPILOGUE_NOT_ALLOWED_LOW_TRIP_LOOP; }
        }
    }
    if func_has_fn_attr(lv_fv, AK_NoImplicitFloat) { return false; }
    // TTI->isFPVectorizationPotentiallyUnsafe(): false on X86 and the base
    var allow_ordered = false;
    if flag_given("force-ordered-reductions") { allow_ordered = flag_bool("force-ordered-reductions", false); }
    if !lvl_can_vectorize_fp_math(allow_ordered) { return false; }
    cm_epilogue = sel;
    // getEpilogueTailLowering
    if flag_given("epilogue-tail-folding-policy") { lvx_unported("-epilogue-tail-folding-policy"); }
    let user_vf = lvh_get_width();
    var user_ic = lvh_get_interleave();
    if !inner { user_ic = 0; }
    else if user_ic > 1 && !lvl_is_safe_for_any_vector_width() { user_ic = 1; }
    // LVP.plan(UserVF, UserIC)
    cm_collect_values_to_ignore();
    cfg_collect_element_types_for_widening();
    let max_vf = cm_compute_max_vf(user_vf, user_ic);
    if lv_dbg_on() { var s: u8[>..] = []; s.append("LV: MaxVF "); format(s, max_vf); s.push('\n'); write_stderr(s); }
    if max_vf == 0 {
        // no plans: computeBestVF returns the scalar VF without a plan; nothing is vectorized or interleaved
        return false;
    }
    if max_vf == 1 && user_vf == 0 && user_ic <= 1 && !flag_given("force-target-max-scalar-interleave") {
        // Only VF 1 is feasible: computeBestVF returns the single scalar plan without costs and
        // selectInterleaveCount returns 1 (getMaxInterleaveFactor(VF=1) is 1 on X86 and the base), so the loop
        // is neither vectorized nor interleaved. Building the plan does not change the IR.
        return false;
    }
    return lv_plan_and_execute(max_vf, user_vf, user_ic, sel);
}

fn lv_psi_cached() -> bool { false }

// ---------------------------------------------------------------------------------------------
// LoopVectorizePass::run / runImpl

fn loop_vectorize_run(fv: i32, interleave_only_when_forced: bool, vectorize_only_when_forced: bool) -> u32 {
    lv_check_flags();
    lv_fv = fv;
    li_get(fv);
    if li_ntop(fv) == 0 { return PA_ALL; }
    scev_get(fv);
    tli_cur_fn = fv;
    tti_init_function(fv, globs[glob_of(fv)].module);
    dt_get(fv, DT_DOM);
    aa_begin(fv);
    db_invalidate();
    // !TTI->getNumberOfRegisters(TTI->getRegisterClassForType(true)) && getMaxInterleaveFactor(1) < 2
    if tv_number_of_registers(tv_register_class_for_type(true, -1)) == 0 { return PA_ALL; }
    var changed = false;
    var cfg_changed = false;
    ls_se = true;
    var k: i64 = 0;
    while k < li_ntop(fv) {
        if simplify_loop(li_top(fv, k), false) { changed = true; cfg_changed = true; }
        k++;
    }
    ls_se = false;
    var wl: i32[>..<] = [];
    for j in li_ntop(fv) { lv_collect_supported_loops(li_top(fv, j), wl); }
    while wl.len > 0 {
        let l = wl.pop();
        let s = lcssa_se;
        lcssa_se = true;
        if form_lcssa_recursively(l) { changed = true; }
        lcssa_se = s;
        if lv_process_loop(l, interleave_only_when_forced, vectorize_only_when_forced) { changed = true; cfg_changed = true; }
    }
    pse_reset();
    db_invalidate();
    if !changed { return PA_ALL; }
    var pa = ((1 as u32) << A_LOOPS) | ((1 as u32) << A_DOMTREE) | ((1 as u32) << A_SCEV);
    if !cfg_changed { pa = pa | PA_CFG; }
    return pa;
}

// LVP.plan(UserVF, UserIC), computeBestVF, selectInterleaveCount and the processLoop tail up to executePlan
fn lv_plan_and_execute(max_vf: i64, user_vf: i64, user_ic: i64, sel: i64) -> bool {
    // Config.collectInLoopReductions and the reduction kinds the plan transforms support
    for d in lvl_rdx_desc {
        let k = rdx_descs[d].kind;
        if lv_prefer_in_loop_reductions() || cfg_use_ordered_reductions(d) { lvx_unported("in-loop reductions"); }
        if rk_is_any_of(k) { lvx_unported("any-of reductions"); }
        if rk_is_find_iv(k) || rk_is_find_last(k) { lvx_unported("find-iv / find-last reductions"); }
        if rk_is_fp_minmax_num(k) { lvx_unported("fmaxnum / fminnum reductions (handleMaxMinNumReductions)"); }
        if rdx_descs[d].multi_use { lvx_unported("multi-use reductions (handleMultiUseReductions)"); }
        if rdx_descs[d].store >= 0 { lvx_unported("reductions stored to an invariant address"); }
    }
    if max_vf > 1 { lvl_collect_unit_stride_predicates(); }
    vp_reset();
    cm_reset(lv_l);
    lvc_reset(lv_pse, cm_is_epilogue_allowed());
    cm_fold_tail = cm_fold_tail_by_masking();
    lvp_l = lv_l;
    lvp_pse = lv_pse;
    lvp_epilogue_allowed = cm_is_epilogue_allowed();
    lvp_plans.clear();
    let force = lvh_get_force() == FK_ENABLED;
    let osz = cm_epilogue == CM_EPILOGUE_NOT_ALLOWED_OPT_SIZE || cm_epilogue == CM_EPILOGUE_NOT_ALLOWED_LOW_TRIP_LOOP;
    if !lvp_try_to_build_vplan1(lvh_allow_reordering(), force, osz) { lv_dbg("LV: tryToBuildVPlan1 failed\n"); return lv_no_plan_result(user_ic); }
    lv_check_minimal_bitwidths();
    // invalidating interleave groups for a predicated header: tail folding fails loudly below
    if cm_fold_tail { lvx_unported("tail folding"); }
    let tc = lv_small_constant_trip_count(lv_l);
    var have_user_plan = false;
    if user_vf != 0 && user_vf <= max_vf {
        cm_collect_non_vectorized_and_set_widening_decisions(user_vf);
        if flag_given("epilogue-vectorization-force-VF") && flag_int("epilogue-vectorization-force-VF", 1) > 1 &&
           flag_int("epilogue-vectorization-force-VF", 1) < user_vf { lvx_unported("-epilogue-vectorization-force-VF"); }
        lvp_build_vplans(user_vf, user_vf);
        if lvp_plans.len != 0 {
            vp_load(lvp_plans[lvp_plans.len - 1]);
            if xv_len(vph.vfs) == 1 && vp_single_vf() == user_vf {
                if user_vf == 1 || lc_valid(vpc_cost(user_vf, tc)) { have_user_plan = true; }
            }
        }
        if !have_user_plan { lvp_plans.clear(); }
    }
    if !have_user_plan {
        var vf: i64 = 1;
        while vf <= max_vf { cm_collect_non_vectorized_and_set_widening_decisions(vf); vf *= 2; }
        lvp_build_vplans(1, max_vf);
    }
    // computeBestVF
    if lvp_plans.len == 0 { lv_dbg("LV: no VPlans built\n"); return lv_no_plan_result(user_ic); }
    var best_vf: i64 = 1;
    var best_cost: i64 = 0;
    var best_scalar: i64 = 0;
    var best_plan = lvp_plans[0];
    if lvp_plans.len == 1 {
        vp_load(best_plan);
        best_vf = vp_single_vf();
    } else {
        let scalar_cost = cm_expected_cost(1);
        if lv_dbg_on() { var s: u8[>..] = []; s.append("LV: Scalar loop costs: "); lc_str(scalar_cost, s); s.append(".\n"); write_stderr(s); }
        best_cost = if force { LC_MAX } else { scalar_cost };
        best_scalar = scalar_cost;
        let max_tc = lv_pse_small_constant_max_trip_count();
        for p in lvp_plans {
            vp_load(p);
            var vfs: i32[>..<] = [];
            xv_to(vph.vfs, vfs);
            for vfi in vfs {
                let v = vfi as i64;
                if v == 1 { continue; }
                vp_load(p);
                if !force && !vpc_will_generate_vectors(v) {
                    lv_dbg("LV: Not considering vector loop because it will not generate any vector instructions.\n");
                    continue;
                }
                if lv_opt_for_size && !force && lv_has_replicator_region() {
                    lv_dbg("LV: Not considering vector loop because it would cause replicated blocks to be generated.\n");
                    continue;
                }
                let c = vpc_cost(v, tc);
                let has_tail = vp_has_scalar_tail();
                if vpc_is_more_profitable(c, v, scalar_cost, best_cost, best_vf, best_scalar, max_tc, has_tail) {
                    best_vf = v; best_cost = c; best_scalar = scalar_cost; best_plan = p;
                }
            }
        }
        if lv_dbg_on() { var s: u8[>..] = []; s.append("LV: Selecting VF: "); format(s, best_vf); s.append(".\n"); write_stderr(s); }
        vp_load(best_plan);
    }
    // hasPlanWithVF(VF.Width): the loaded plan has it
    lvx_setup(lv_l, lv_pse, lv_fv);
    lvx_epilogue_allowed = cm_is_epilogue_allowed();
    let rse = lvx_requires_scalar_epilogue();
    var ic = vpc_select_interleave_count(best_vf, best_cost, cm_is_epilogue_allowed(),
                                         lv_small_best_known_tc(true, cm_is_epilogue_allowed(), false), tc, rse);
    vp_load(best_plan);
    let selected_ic = if ic > user_ic { ic } else { user_ic };
    if best_vf > 1 || selected_ic > 1 {
        if !su_always_true(pse_union(lv_pse)) { lvx_unported("SCEV runtime checks (GeneratedRTChecks)"); }
    }
    var min_profitable_tc: i64 = 0;
    if !force && best_vf > 1 {
        let ok, m = vpc_is_outside_loop_work_profitable(best_vf, best_cost, best_scalar, sel == CM_EPILOGUE_ALLOWED,
                                                       lv_small_best_known_tc(true, false, false));
        vp_load(best_plan);
        if !ok { return false; }
        min_profitable_tc = m;
    }
    let vectorize = best_vf > 1;
    var interleave = true;
    if user_ic == 1 && lvh_get_interleave() > 1 { interleave = false; }
    else if ic == 1 && user_ic <= 1 { interleave = false; }
    else if ic > 1 && user_ic == 1 { interleave = false; }
    ic = if user_ic > 0 { user_ic } else { ic };
    if cm_mask_partial_aliasing() { interleave = false; ic = 1; }
    if interleave && lvl_has_uncountable_exit_with_side_effects() { interleave = false; ic = 1; }
    if !vectorize && !interleave { return false; }

    if !interleave { ic = 1; }
    return lv_execute_best_plan(best_vf, ic, min_profitable_tc);
}
fn lv_no_plan_result(user_ic: i64) -> bool { return false; }
// hasReplicatorRegion(Plan)
fn lv_has_replicator_region() -> bool {
    var bs: i32[>..<] = [];
    vp_depth_first(vpb[vp_vector_loop_region()].entry, false, bs);
    for b in bs { if vp_is_region(b) && vp_is_replicator(b) { return true; } }
    return false;
}

// computeMinimalBitwidths: computeMinimumValueSizes(TheLoop->getBlocks(), DB, &TTI) up to its early exit; a loop
// that gets past it fails loudly
fn lv_check_minimal_bitwidths() {
    var seen_ext_from_illegal = false;
    var have_root = false;
    for b in loop_nblocks(lv_l) {
        var i = block_first(loop_block(lv_l, b));
        while i >= 0 {
            let o = iop(i);
            if (o == OP_ZEXT || o == OP_SEXT) && !tti_is_type_legal(vals[op(i, 0)].ty as i32) { seen_ext_from_illegal = true; }
            if (o == OP_TRUNC || o == OP_ICMP) && !ty_is_vector(vals[i].ty) && (!ty_is_int(ty_scalar(vals[op(i, 0)].ty)) || ty_bits(ty_scalar(vals[op(i, 0)].ty)) <= 64) {
                if !(o == OP_TRUNC && tti_is_type_legal(vals[i].ty as i32)) { have_root = true; }
            }
            i = inst_next(i);
        }
    }
    if !have_root || !seen_ext_from_illegal { return; }
    lvx_unported("computeMinimumValueSizes (minimal bitwidths)");
}
