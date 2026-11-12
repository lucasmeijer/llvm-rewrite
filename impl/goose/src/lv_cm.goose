// LoopVectorizationCostModel: the widening, uniform and scalar decisions of
// llvm/lib/Transforms/Vectorize/LoopVectorize.cpp (setCostBasedWideningDecision, memoryInstructionCanBeWidened,
// collectLoopUniforms, collectLoopScalars, isScalarWithPredication, isPredicatedInst, isMaskRequired,
// collectNonVectorizedAndSetWideningDecisions, getWideningDecision, isUniformAfterVectorization,
// isScalarAfterVectorization) and VFSelectionContext::isLegalMaskedLoadOrStore / isLegalGatherOrScatter
// (LoopVectorizationPlanner.cpp). Per-VF sets are HMaps keyed (VF << 32 | instruction).
// The costs of the decisions are computed by the cost-model milestone; until then a decision that needs a cost
// comparison fails loudly.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import flags;
import gen_iids;
import datalayout;
import speculate;
import loopinfo;
import scev;
import laa;
import tti;
import tti_vec;
import tti_x86_vec;
import iv_descriptors;
import lv_legality;
import lv_interleave;

// InstWidening
let CM_UNKNOWN: i64 = 0; let CM_WIDEN: i64 = 1; let CM_WIDEN_REVERSE: i64 = 2; let CM_INTERLEAVE: i64 = 3;
let CM_GATHER_SCATTER: i64 = 4; let CM_SCALARIZE: i64 = 5; let CM_INVALIDATED: i64 = 6;

var cm_l: i32 = -1;
var cm_fold_tail: bool = false;     // foldTailByMasking() (set by the pass driver)
var cm_wd = hm_new();               // WideningDecisions: (VF, I) -> decision
var cm_wd_cost = hm_new();          // ... -> cost (fixed point)
var cm_uni_vfs: i64[>..<];          // VFs with Uniforms computed
var cm_uni = hm_new();              // Uniforms
var cm_scal = hm_new();             // Scalars
var cm_forced = hm_new();           // ForcedScalars
var cm_to_scalarize = hm_new();     // InstsToScalarize

fn cm_reset(l: i32) {
    cm_l = l;
    cm_fold_tail = false;
    hm_clear(cm_wd); hm_clear(cm_wd_cost); cm_uni_vfs.clear(); hm_clear(cm_uni); hm_clear(cm_scal);
    hm_clear(cm_forced); hm_clear(cm_to_scalarize);
}
fn cm_key(vf: i64, i: i32) -> u64 { ((vf as u64) << 32) | (i as u64) }

fn cm_get_widening_decision(i: i32, vf: i64) -> i64 { hm_get(cm_wd, cm_key(vf, i), CM_UNKNOWN) }
fn cm_set_widening_decision(i: i32, vf: i64, d: i64, cost: i64) {
    hm_put(cm_wd, cm_key(vf, i), d);
    hm_put(cm_wd_cost, cm_key(vf, i), cost);
}
fn cm_is_uniform_after_vectorization(i: i32, vf: i64) -> bool {
    if vf == 1 { return true; }
    if is_inst(i) && iop(i) == OP_CALL && call_iid(i) == IID_pseudoprobe { return false; }
    return hm_has(cm_uni, cm_key(vf, i));
}
fn cm_is_scalar_after_vectorization(i: i32, vf: i64) -> bool {
    if vf == 1 { return true; }
    return hm_has(cm_scal, cm_key(vf, i));
}
fn cm_is_profitable_to_scalarize(i: i32, vf: i64) -> bool { hm_has(cm_to_scalarize, cm_key(vf, i)) }

// isMaskRequired(I): Legal->isMaskRequired(I, foldTailByMasking())
fn cm_is_mask_required(i: i32) -> bool {
    if cm_fold_tail { return hm_has(lvl_tail_ops, i as u64); }
    return hm_has(lvl_cond_ops, i as u64);
}

// isPredicatedInst
fn cm_is_predicated_inst(i: i32) -> bool {
    let o = iop(i);
    if spec_safe(i, -1, false) || ((o == OP_LOAD || o == OP_STORE || o == OP_CALL) && !cm_is_mask_required(i)) ||
       o == OP_BR || o == OP_CONDBR || o == OP_SWITCH || o == OP_PHI || o == OP_ALLOCA { return false; }
    if lvl_block_needs_predication(inst_parent(i)) { return true; }
    if !cm_fold_tail && !lvl_has_uncountable_exit_with_side_effects() { return false; }
    if o == OP_CALL { return true; }
    if o == OP_LOAD { return !lvl_is_invariant(op(i, 0)); }
    if o == OP_STORE { return !(lvl_is_invariant(op(i, 1)) && ivd_loop_invariant(cm_l, op(i, 0))); }
    if o == OP_UDIV || o == OP_UREM { return !lvl_is_invariant(op(i, 1)); }
    if o == OP_SDIV || o == OP_SREM { return true; }
    fatal("internal: instruction should have been considered by earlier checks");
    return false;
}

fn cm_ld_align(i: i32) -> i64 { let a = insts[inst_of(i)].align; return if a == 0 { 1 } else { (1 as i64) << ((a - 1) as i64) }; }
// VFSelectionContext::isLegalMaskedLoadOrStore
fn cfg_is_legal_masked_load_or_store(i: i32, vf: i64) -> bool {
    if flag_bool("force-target-supports-masked-memory-ops", false) { return true; }
    let t = laa_ldst_type(i);
    if tti_kind == TTI_X86 {
        return if iop(i) == OP_LOAD { x86_is_legal_masked_load(t) } else { x86_is_legal_masked_store(t) };
    }
    return false;
}
// VFSelectionContext::isLegalGatherOrScatter
fn cfg_is_legal_gather_or_scatter(i: i32, vf: i64) -> bool {
    let o = iop(i);
    if o != OP_LOAD && o != OP_STORE { return false; }
    if flag_bool("force-target-supports-gather-scatter-ops", false) { return true; }
    var t = laa_ldst_type(i);
    if vf > 1 { t = ty_vector(t, vf, false); }
    if tti_kind == TTI_X86 {
        return if o == OP_LOAD { x86_is_legal_masked_gather(t) } else { x86_is_legal_masked_scatter(t) };
    }
    return false;
}

// isScalarWithPredication(I, VF)
fn cm_is_scalar_with_predication(i: i32, vf: i64) -> bool {
    if !cm_is_predicated_inst(i) { return false; }
    let o = iop(i);
    if o == OP_CALL {
        if vf == 1 { return true; }
        return laa_vector_intrinsic_id_for_call(i) == 0;
    }
    if o == OP_LOAD || o == OP_STORE {
        let cons = lvl_is_consecutive_ptr(laa_ldst_type(i), laa_ldst_ptr(i)) != 0;
        return !(cons && cfg_is_legal_masked_load_or_store(i, vf)) && !cfg_is_legal_gather_or_scatter(i, vf);
    }
    if o == OP_UDIV || o == OP_SDIV || o == OP_SREM || o == OP_UREM {
        vp_unported_cm("predicated division (getDivRemSpeculationCost)");
    }
    return true;
}
fn vp_unported_cm(what: const u8[:]) { fatal(str("loop-vectorize: ", what, " is not supported yet")); }

// hasIrregularType
fn cm_has_irregular_type(t: i32) -> bool { dl_alloc_size(t) * 8 != dl_size_bits(t) }

// memoryInstructionCanBeWidened: CM_UNKNOWN = std::nullopt
fn cm_memory_instruction_can_be_widened(i: i32, vf: i64) -> i64 {
    let stride = lvl_is_consecutive_ptr(laa_ldst_type(i), laa_ldst_ptr(i));
    if stride == 0 { return CM_UNKNOWN; }
    if cm_is_scalar_with_predication(i, vf) { return CM_UNKNOWN; }
    if cm_has_irregular_type(laa_ldst_type(i)) { return CM_UNKNOWN; }
    return if stride == 1 { CM_WIDEN } else { CM_WIDEN_REVERSE };
}

// setCostBasedWideningDecision(VF) (decisions; costs are filled by the cost model)
fn cm_set_cost_based_widening_decision(vf: i64) {
    if vf == 1 { return; }
    let l = cm_l;
    for b in loop_nblocks(l) {
        var i = block_first(loop_block(l, b));
        while i >= 0 {
            let ptr = laa_ldst_ptr(i);
            if ptr < 0 { i = inst_next(i); continue; }
            if lvl_is_uniform_mem_op(i, vf) {
                if cfg_is_legal_gather_or_scatter(i, vf) { vp_unported_cm("gather/scatter cost of a uniform memory access"); }
                cm_set_widening_decision(i, vf, CM_SCALARIZE, -1);
                i = inst_next(i);
                continue;
            }
            let d = cm_memory_instruction_can_be_widened(i, vf);
            if d != CM_UNKNOWN { cm_set_widening_decision(i, vf, d, -1); i = inst_next(i); continue; }
            if iai_is_interleaved(i) { vp_unported_cm("interleave groups (getInterleaveGroupCost)"); }
            vp_unported_cm("non-consecutive memory accesses (gather/scatter or scalarization costs)");
            i = inst_next(i);
        }
    }
    // prefersVectorizedAddressing: true for NoTTI, supportsGather() on X86
    if tti_kind != TTI_X86 || x86_supports_gather() { return; }
    var addr_defs: i32[>..<] = [];
    var addr_set = hm_new();
    for b in loop_nblocks(l) {
        var i = block_first(loop_block(l, b));
        while i >= 0 {
            let p = laa_ldst_ptr(i);
            if p >= 0 && is_inst(p) && ivd_contains_inst(l, p) && cm_get_widening_decision(i, vf) != CM_GATHER_SCATTER {
                if ivd_set_add(addr_set, p) { addr_defs.push(p); }
            }
            i = inst_next(i);
        }
    }
    var wl: i32[>..<] = [];
    for x in addr_defs { wl.push(x); }
    while wl.len > 0 {
        let x = wl.pop();
        for k in nops(x) {
            let o = op(x, k);
            if is_inst(o) && ivd_contains_inst(l, o) && iop(o) != OP_PHI && ivd_set_add(addr_set, o) { addr_defs.push(o); wl.push(o); }
        }
    }
    for x in addr_defs {
        if iop(x) == OP_LOAD {
            vp_unported_cm("scalarized address loads (prefersVectorizedAddressing)");
        } else {
            if iop(x) == OP_PHI && lvl_is_fixed_order_recurrence(x) { continue; }
            hm_put(cm_forced, cm_key(vf, x), 1);
        }
    }
}

// collectLoopUniforms(VF)
fn cm_collect_loop_uniforms(vf: i64) {
    let l = cm_l;
    cm_uni_vfs.push(vf);
    var wl: i32[>..<] = [];
    var wset = hm_new();
    fn out_of_scope(v: i32) -> bool { !is_inst(v) || !loop_contains(l, inst_parent(v)) }
    fn add_if_allowed(i: i32) {
        if out_of_scope(i) { return; }
        if cm_is_predicated_inst(i) { return; }
        if ivd_set_add(wset, i) { wl.push(i); }
    }
    var exiting: i32[>..<] = [];
    loop_exiting_blocks(l, exiting);
    for e in exiting {
        if lvl_has_uncountable_early_exit() && loop_latch(l) != e { continue; }
        let c = op(block_terminator(e), 0);
        if is_inst(c) && ivd_contains_inst(l, c) && ivd_has_one_use(c) { add_if_allowed(c); }
    }
    let prev_vf = vf / 2;
    fn is_uniform_mem_op_use(i: i32) -> bool {
        if prev_vf > 1 {
            var has_prev = false;
            for x in cm_uni_vfs { if x == prev_vf { has_prev = true; } }
            if has_prev && !hm_has(cm_uni, cm_key(prev_vf, i)) { return false; }
        }
        if !lvl_is_uniform_mem_op(i, vf) { return false; }
        if iop(i) == OP_LOAD { return true; }
        return ivd_loop_invariant(l, op(i, 0));
    }
    fn is_uniform_decision(i: i32) -> bool {
        let d = cm_get_widening_decision(i, vf);
        if is_uniform_mem_op_use(i) { return true; }
        return d == CM_WIDEN || d == CM_WIDEN_REVERSE || d == CM_INTERLEAVE;
    }
    fn is_vectorized_mem_access_use(i: i32, ptr: i32) -> bool {
        if iop(i) == OP_STORE && op(i, 0) == ptr { return false; }
        return laa_ldst_ptr(i) == ptr && (is_uniform_decision(i) || lvl_is_invariant(ptr));
    }
    var has_uniform_use: i32[>..<] = [];
    var huu_set = hm_new();
    for b in loop_nblocks(l) {
        var i = block_first(loop_block(l, b));
        while i >= 0 {
            let id = if iop(i) == OP_CALL { call_iid(i) } else { 0 };
            if id == IID_sideeffect || id == IID_experimental_noalias_scope_decl || id == IID_assume ||
               id == IID_lifetime_start || id == IID_lifetime_end {
                var inv = true;
                for k in nops(i) { if !ivd_loop_invariant(l, op(i, k)) { inv = false; } }
                if inv { add_if_allowed(i); }
            }
            if iop(i) == OP_EXTRACTVALUE {
                if out_of_scope(op(i, 0)) { add_if_allowed(i); i = inst_next(i); continue; }
            }
            let ptr = laa_ldst_ptr(i);
            if ptr < 0 { i = inst_next(i); continue; }
            if is_inst(ptr) && lvl_is_uniform(ptr, vf) { add_if_allowed(ptr); }
            if is_uniform_mem_op_use(i) { add_if_allowed(i); }
            if is_vectorized_mem_access_use(i, ptr) {
                if ivd_set_add(huu_set, ptr) { has_uniform_use.push(ptr); }
            }
            i = inst_next(i);
        }
    }
    for v in has_uniform_use {
        if out_of_scope(v) { continue; }
        var all = true;
        var u = vals[v].first_use;
        while u >= 0 {
            let ui = uses[u].user;
            if !(loop_contains(l, inst_parent(ui)) && is_vectorized_mem_access_use(ui, v)) { all = false; }
            u = uses[u].next;
        }
        if all { add_if_allowed(v); }
    }
    var idx: i64 = 0;
    while idx < wl.len {
        let i = wl[idx];
        idx++;
        for k in nops(i) {
            let ov = op(i, k);
            if out_of_scope(ov) { continue; }
            if iop(ov) == OP_PHI && lvl_is_fixed_order_recurrence(ov) { continue; }
            var all = true;
            var u = vals[ov].first_use;
            while u >= 0 {
                let j = uses[u].user;
                if !(ivd_set_has(wset, j) || is_vectorized_mem_access_use(j, ov)) { all = false; }
                u = uses[u].next;
            }
            if all { add_if_allowed(ov); }
        }
    }
    let latch = loop_latch(l);
    for ind in lvl_ind_phis {
        let upd = ivd_incoming_for_block(ind, latch);
        var uind = true;
        var u = vals[ind].first_use;
        while u >= 0 {
            let x = uses[u].user;
            if !(x == upd || !loop_contains(l, inst_parent(x)) || ivd_set_has(wset, x) || is_vectorized_mem_access_use(x, ind)) { uind = false; }
            u = uses[u].next;
        }
        if !uind { continue; }
        var uupd = true;
        u = vals[upd].first_use;
        while u >= 0 {
            let x = uses[u].user;
            if !(x == ind || ivd_set_has(wset, x) || is_vectorized_mem_access_use(x, upd)) { uupd = false; }
            u = uses[u].next;
        }
        if !uupd { continue; }
        add_if_allowed(ind);
        add_if_allowed(upd);
    }
    for x in wl { hm_put(cm_uni, cm_key(vf, x), 1); }
}

// collectLoopScalars(VF)
fn cm_collect_loop_scalars(vf: i64) {
    let l = cm_l;
    var wl: i32[>..<] = [];
    var wset = hm_new();
    fn wl_add(i: i32) { if ivd_set_add(wset, i) { wl.push(i); } }
    var scalar_ptrs: i32[>..<] = [];
    var sp_set = hm_new();
    var possible_non_scalar = hm_new();
    let latch = loop_latch(l);
    fn is_scalar_use(mem: i32, ptr: i32) -> bool {
        let d = cm_get_widening_decision(mem, vf);
        if iop(mem) == OP_STORE && ptr == op(mem, 0) { return d == CM_SCALARIZE; }
        return d != CM_GATHER_SCATTER;
    }
    fn is_loop_varying_gep(v: i32) -> bool { is_inst(v) && iop(v) == OP_GEP && !ivd_loop_invariant(l, v) }
    fn evaluate_ptr_use(mem: i32, ptr: i32) {
        if !is_loop_varying_gep(ptr) { return; }
        if ivd_set_has(wset, ptr) { return; }
        var all_mem = true;
        var u = vals[ptr].first_use;
        while u >= 0 { let x = uses[u].user; if iop(x) != OP_LOAD && iop(x) != OP_STORE { all_mem = false; } u = uses[u].next; }
        if is_scalar_use(mem, ptr) && all_mem { if ivd_set_add(sp_set, ptr) { scalar_ptrs.push(ptr); } }
        else { hm_put(possible_non_scalar, ptr as u64, 1); }
    }
    for b in loop_nblocks(l) {
        var i = block_first(loop_block(l, b));
        while i >= 0 { if hm_has(cm_uni, cm_key(vf, i)) { wl_add(i); } i = inst_next(i); }
    }
    // (1) Uniforms[VF] in SetVector insertion order: the order only affects the worklist expansion below, which
    // reaches a fixed point either way
    for b in loop_nblocks(l) {
        var i = block_first(loop_block(l, b));
        while i >= 0 {
            if iop(i) == OP_LOAD { evaluate_ptr_use(i, op(i, 0)); }
            else if iop(i) == OP_STORE { evaluate_ptr_use(i, op(i, 1)); evaluate_ptr_use(i, op(i, 0)); }
            i = inst_next(i);
        }
    }
    for x in scalar_ptrs { if !hm_has(possible_non_scalar, x as u64) { wl_add(x); } }
    for b in loop_nblocks(l) {
        var i = block_first(loop_block(l, b));
        while i >= 0 { if hm_has(cm_forced, cm_key(vf, i)) { wl_add(i); } i = inst_next(i); }
    }
    var idx: i64 = 0;
    while idx < wl.len {
        let dst = wl[idx];
        idx++;
        if nops(dst) == 0 || !is_loop_varying_gep(op(dst, 0)) { continue; }
        let src = op(dst, 0);
        var all = true;
        var u = vals[src].first_use;
        while u >= 0 {
            let j = uses[u].user;
            if !(!loop_contains(l, inst_parent(j)) || ivd_set_has(wset, j) || ((iop(j) == OP_LOAD || iop(j) == OP_STORE) && is_scalar_use(j, src))) { all = false; }
            u = uses[u].next;
        }
        if all { wl_add(src); }
    }
    for k in lvl_ind_phis.len {
        let ind = lvl_ind_phis[k];
        let d = lvl_ind_desc[k];
        let upd = ivd_incoming_for_block(ind, latch);
        if ind == lvl_primary && cm_fold_tail { continue; }
        fn direct_ldst(iv: i32, i: i32) -> bool {
            return ind_descs[d].kind == IK_PTR && (iop(i) == OP_LOAD || iop(i) == OP_STORE) && iv == laa_ldst_ptr(i) && is_scalar_use(i, iv);
        }
        var sind = true;
        var u = vals[ind].first_use;
        while u >= 0 {
            let x = uses[u].user;
            if !(x == upd || !loop_contains(l, inst_parent(x)) || ivd_set_has(wset, x) || direct_ldst(ind, x)) { sind = false; }
            u = uses[u].next;
        }
        if !sind { continue; }
        if iop(upd) == OP_PHI && lvl_is_fixed_order_recurrence(upd) { continue; }
        var supd = true;
        u = vals[upd].first_use;
        while u >= 0 {
            let x = uses[u].user;
            if !(x == ind || !loop_contains(l, inst_parent(x)) || ivd_set_has(wset, x) || direct_ldst(upd, x)) { supd = false; }
            u = uses[u].next;
        }
        if !supd { continue; }
        wl_add(ind);
        wl_add(upd);
    }
    for x in wl { hm_put(cm_scal, cm_key(vf, x), 1); }
}

// collectInstsToScalarize(VF): only blocks needing predication contribute
fn cm_collect_insts_to_scalarize(vf: i64) {
    if vf == 1 { return; }
    for b in loop_nblocks(cm_l) {
        let bb = loop_block(cm_l, b);
        if !(cm_fold_tail || lvl_block_needs_predication(bb)) { continue; }
        var i = block_first(bb);
        while i >= 0 {
            if cm_is_scalar_with_predication(i, vf) { vp_unported_cm("collectInstsToScalarize (computePredInstDiscount)"); }
            i = inst_next(i);
        }
    }
}

// collectNonVectorizedAndSetWideningDecisions(VF)
fn cm_collect_non_vectorized_and_set_widening_decisions(vf: i64) {
    if vf == 1 { return; }
    for x in cm_uni_vfs { if x == vf { return; } }
    cm_set_cost_based_widening_decision(vf);
    cm_collect_loop_uniforms(vf);
    cm_collect_loop_scalars(vf);
    cm_collect_insts_to_scalarize(vf);
}
