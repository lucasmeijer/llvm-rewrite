// LoopVectorizationPlanner: plan building. Ports of llvm/lib/Transforms/Vectorize/LoopVectorize.cpp
// (tryToBuildVPlan1, buildVPlans, tryToBuildVPlan, the VPRecipeBuilder: tryToWidenMemory,
// tryToOptimizeInductionTruncate, shouldWiden, tryToWiden, handleReplication, tryToCreateWidenNonPhiRecipe,
// replaceWithFinalIfReductionStore; getDecisionAndClampRange) and of the VPlanTransforms that make the per-VF
// decisions (llvm/lib/Transforms/Vectorize/VPlanTransforms.cpp: makeMemOpWideningDecisions,
// makeScalarizationDecisions, makeCallWideningDecisions). Plans are archive slots (vplan.goose); lvp_plans lists
// the slots of VPlans in LLVM's order.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import flags;
import gen_iids;
import datalayout;
import pm;
import loopinfo;
import scev;
import scev_create;
import scev_lt;
import scev_eval;
import pse;
import laa;
import tti;
import tti_x86_vec;
import lv_pass;
import iv_descriptors;
import lv_legality;
import lv_interleave;
import lv_cm;
import constfold;
import vplan;
import vplan_utils;
import vplan_props;
import vplan_construct;
import vplan_transforms;
import vplan_interleave;
import vplan_predicate;
import delinearization;
import apint;
import lv_cost;
import vplan_cost;
import loop_versioning;

var lvp_plans: i32[>..<];        // VPlans (archive slots)
var lvp_plan1: i32 = -1;         // VPlan1's slot
var lvp_pse: i32 = -1;
var lvp_l: i32 = -1;
var lvp_range_start: i64 = 0;    // VFRange of the plan being built
var lvp_range_end: i64 = 0;

// getDecisionAndClampRange(Predicate, Range) with Predicate F(VF)
fn lvp_decide<F>() -> bool {
    let first = F(lvp_range_start);
    var vf = lvp_range_start * 2;
    while vf < lvp_range_end {
        if F(vf) != first { lvp_range_end = vf; break; }
        vf *= 2;
    }
    return first;
}

// ---------------------------------------------------------------------------------------------
// tryToBuildVPlan1: the base plan, saved in lvp_plan1 (false = no plan)

fn lvp_try_to_build_vplan1(allow_reordering: bool, force: bool, epilogue_status_opt_size: bool) -> bool {
    lvp_plan1 = -1;
    // loop versioning for inner loops with memory runtime checks: noalias metadata only for checks that guarantee no
    // overlap across all iterations
    lv_noalias_prepared = false;
    lver_init(lvp_l, rpc_checks);
    if rpc_checks.len != 0 && !rpc_can_diff { lver_prepare_noalias_metadata(); lv_noalias_prepared = true; }
    vp_build_vplan0(lvp_l, lvl_widest_ind_ty, lvp_pse);
    vp_dt_build();
    vpt_replace_symbolic_strides(lvp_pse);
    vpt_simplify_recipes();
    vpt_remove_dead_recipes();
    if !vp_create_header_phi_recipes(lvp_pse, allow_reordering) { return false; }
    vpt_replace_symbolic_strides(lvp_pse);
    let opt_for_size = !force && epilogue_status_opt_size;
    let thr = if force { flag_int("pragma-vectorize-scev-check-threshold", 128) } else { flag_int("vectorize-scev-check-threshold", 16) };
    if !vp_finalize_scev_predicates(lvp_pse, opt_for_size, thr) { return false; }
    vp_add_middle_check();
    var ee: i64 = 0;
    if lvl_has_uncountable_early_exit() { ee = if lvl_has_uncountable_exit_with_side_effects() { 2 } else { 1 }; }
    if !vp_handle_early_exits(ee) { return false; }
    let prim = lvl_primary;
    var dl: i32 = -1;
    if prim >= 0 {
        // getDebugLocFromInstOrOperands(Legal->getPrimaryInduction())
        dl = vp_inst_dl(prim);
        if dl < 0 {
            for k in nops(prim) { let o = op(prim, k); if is_inst(o) && vp_inst_dl(o) >= 0 { dl = vp_inst_dl(o); break; } }
        }
    }
    vp_create_loop_regions(dl);
    if cm_fold_tail { vp_fold_tail_by_masking(); }
    vp_introduce_masks_and_linearize();
    lvp_plan1 = vp_save();
    return true;
}

// VPlanTransforms::replaceSymbolicStrides(Plan, PSE, StridesMap, VPDT) (VPDT: built after buildVPlan0)
fn vpt_replace_symbolic_strides(pse: i32) {
    if lai_strides_k.len == 0 { return; }
    let ph = vp_succ(vph.entry, 1);
    fn can_use(u: i32, i: i64) -> bool { vp_dt_dominates(ph, vpr[u].parent) }
    var rw_from: i32[>..<] = [];
    var rw_to: i32[>..<] = [];
    for st in lai_strides_v {
        let sv = sc_value(st);
        let ps = pse_get_scev(pse, sv);
        if !sc_is_const(ps) { continue; }
        let ap = sc_ap(ps);
        let ci = vp_live_in(sc_value(ps));
        let svp = vp_get_live_in(sv);
        if svp >= 0 { vp_replace_uses_with_if(svp, ci) { u, i => can_use(u, i) }; }
        var us: i32[>..<] = [];
        var u = vals[sv].first_use;
        while u >= 0 { us.push(uses[u].user); u = uses[u].next; }
        for x in us {
            if !is_inst(x) || (iop(x) != OP_SEXT && iop(x) != OP_ZEXT) { continue; }
            let xvp = vp_get_live_in(x);
            if xvp < 0 { continue; }
            let bw = ty_bits(vals[x].ty as i32);
            let c = if iop(x) == OP_SEXT { ap_sext(ap, bw) } else { ap_zext(ap, bw) };
            let cv = vp_live_in(ap_to_cint(vals[x].ty as i32, c));
            vp_replace_uses_with_if(xvp, cv) { uu, ii => can_use(uu, ii) };
        }
        rw_from.push(sv);
        rw_to.push(ps);
    }
    var rs: i32[>..<] = [];
    vp_block_recipes(vph.entry, rs);
    for r in rs {
        if vpr[r].kind != VPR_EXPAND_SCEV { continue; }
        let e = vpr[r].expr;
        var ne = e;
        for k in rw_from.len { ne = dl_rewrite_param(ne, rw_from[k], rw_to[k]); }
        if ne != e {
            let nv = vp_get_or_create_value_for_scev(ne);
            vp_rauw(vpr[r].def, nv);
            if vph.trip_count == vpr[r].def { vph.trip_count = nv; }
        }
    }
}

// buildVPlans(VPlan1, MinVF, MaxVF)
fn lvp_build_vplans(min_vf: i64, max_vf: i64) {
    if min_vf > max_vf { return; }
    let max2 = max_vf * 2;
    var vf = min_vf;
    while vf < max2 {
        lvp_range_start = vf;
        lvp_range_end = max2;
        vp_duplicate_load(lvp_plan1);
        let ok = lvp_try_to_build_vplan();
        vf = lvp_range_end;
        if !ok { continue; }
        vpt_hoist_predicated_loads();
        vpt_sink_predicated_stores();
        vpt_truncate_to_minimal_bitwidths();
        vpt_optimize();
        if cm_fold_tail_with_evl() { vp_unported("EVL tail folding"); }
        let np = vpt_narrow_interleave_groups();
        if np >= 0 { lvp_plans.push(np); }
        vpt_materialize_header_mask(false, false);
        lvp_plans.push(vp_save());
    }
}
fn cm_fold_tail_with_evl() -> bool { false }

// ---------------------------------------------------------------------------------------------
// VPRecipeBuilder

// createConsecutiveVectorPointer(Ptr, SourceElementTy, Reverse, DL) at the builder's insert point
fn vpb_consecutive_vector_pointer(ptr: i32, src_ty: i32, reverse: bool, dl: i32) -> i32 {
    let f = vp_gep_flags_for_ptr(ptr);
    if reverse {
        var rf = f & ~GEP_NUW;
        if vp_has_tail_folded() { rf = 0; }
        let r = vp_new_single_def(VPR_VECTOR_END_POINTER, [ptr, vph.vf], vp_scalar_type(ptr), -1, dl);
        vpr[r].src_elt_ty = src_ty;
        vpr[r].stride = -1;
        vpr[r].f = vpf_gep(rf);
        return vpb_insert(r);
    }
    let stride_ty = ty_int(dl_ptr(ty_bits(vp_scalar_type(ptr))).idx);
    let one = vp_const_int(stride_ty, 1);
    let r = vp_new_single_def(VPR_VECTOR_POINTER, [ptr, one], vp_scalar_type(ptr), -1, dl);
    vpr[r].src_elt_ty = src_ty;
    vpr[r].f = vpf_gep(f);
    return vpb_insert(r);
}
// vputils::getGEPFlagsForPtr
fn vp_gep_flags_for_ptr(ptr0: i32) -> u8 {
    var ptr = ptr0;
    while true {
        let r = vp_def(ptr);
        if r < 0 || vpr[r].kind != VPR_INSTRUCTION { break; }
        let o = vpr[r].opcode;
        if o == OP_GEP as i32 {
            var all_zero = true;
            for k in 1..vp_nops(r) { if !vpm_zero_int(vp_op(r, k)) { all_zero = false; } }
            if !all_zero { return vpr[r].f.gep; }
            ptr = vp_op(r, 0);
            continue;
        }
        if o != OP_BITCAST as i32 && o != OP_ADDRSPACECAST as i32 { break; }
        ptr = vp_op(r, 0);
    }
    return 0;
}

// VPWidenLoadRecipe / VPWidenStoreRecipe constructors (flags / metadata of the VPInstruction)
fn vp_new_widen_load(li: i32, addr: i32, mask: i32, consecutive: bool, vpi: i32, dl: i32) -> i32 {
    let r = vp_new_single_def(VPR_WIDEN_LOAD, [addr], vals[li].ty as i32, li, dl);
    if mask >= 0 { vp_add_operand(r, mask); vpr[r].masked = true; }
    vpr[r].ir_inst = li;
    vpr[r].consecutive = consecutive;
    vpr[r].align = cm_ld_align(li);
    vp_md_copy(r, vpi);
    return r;
}
fn vp_new_widen_store(si: i32, addr: i32, val: i32, mask: i32, consecutive: bool, vpi: i32, dl: i32) -> i32 {
    let r = vp_new_recipe(VPR_WIDEN_STORE, [addr, val], dl);
    if mask >= 0 { vp_add_operand(r, mask); vpr[r].masked = true; }
    vpr[r].ir_inst = si;
    vpr[r].consecutive = consecutive;
    vpr[r].align = cm_ld_align(si);
    vp_md_copy(r, vpi);
    return r;
}
// VPReplicateRecipe(I, Operands, IsSingleScalar, Mask, Flags, Metadata, DL)
fn vp_new_replicate(i: i32, ops: const i32[:], single: bool, mask: i32, f: VPF, md_from: i32, dl: i32) -> i32 {
    let r = vp_new_single_def(VPR_REPLICATE, ops, vals[i].ty as i32, i, dl);
    if mask >= 0 { vp_add_operand(r, mask); vpr[r].predicated = true; }
    vpr[r].single_scalar = single;
    vpr[r].opcode = iop(i) as i32;
    vpr[r].f = f;
    if md_from >= 0 { vp_md_copy(r, md_from); }
    return r;
}
fn vp_ops_without_mask(r: i32, out: i32[>..<]&) {
    out.clear();
    let n = if vp_is_masked(r) { vp_nops(r) - 1 } else { vp_nops(r) };
    for k in n { out.push(vp_op(r, k)); }
}
// tryToWidenMemory (delegateMemOpWideningToLegacyCM)
fn lvp_try_to_widen_memory(vpi: i32) -> i32 {
    let i = vp_underlying_instr(vpi);
    let will = lvp_decide() { vf =>
        let d = cm_get_widening_decision(i, vf);
        if d == CM_INTERLEAVE { true }
        else if cm_is_scalar_after_vectorization(i, vf) || cm_is_profitable_to_scalarize(i, vf) { false }
        else { d != CM_SCALARIZE }
    };
    if !will { return -1; }
    let mask = if cm_is_mask_required(i) { vp_mask_of(vpi) } else { -1 };
    let d = cm_get_widening_decision(i, lvp_range_start);
    let reverse = d == CM_WIDEN_REVERSE;
    let consecutive = reverse || d == CM_WIDEN;
    let is_load = vpr[vpi].opcode == OP_LOAD as i32;
    var ptr = if is_load { vp_op(vpi, 0) } else { vp_op(vpi, 1) };
    if consecutive {
        vpb_set_before(vpi);
        ptr = vp_val(vpb_consecutive_vector_pointer(ptr, laa_ldst_type(i), reverse, vpr[vpi].dl));
    }
    if reverse && mask >= 0 { vp_unported("reverse masked accesses"); }
    if is_load {
        let lr = vp_new_widen_load(i, ptr, mask, consecutive, vpi, vp_inst_dl(i));
        if reverse {
            vpb_insert(lr);
            return vp_new_instruction(VPI_REVERSE, [vp_val(lr)], vpf_none(), vpr[lr].dl, "", -1);
        }
        return lr;
    }
    var sv = vp_op(vpi, 0);
    if reverse { sv = vp_val(vpb_nary(VPI_REVERSE, [sv], vpf_none(), vp_inst_dl(i), "", -1)); }
    return vp_new_widen_store(i, ptr, sv, mask, consecutive, vpi, vp_inst_dl(i));
}

// handleReplication
fn lvp_handle_replication(vpi: i32) -> i32 {
    let i = vp_underlying_instr(vpi);
    let uniform = lvp_decide() { vf => cm_is_uniform_after_vectorization(i, vf) };
    let pred = cm_is_predicated_inst(i);
    let mask = if pred { vp_mask_of(vpi) } else { -1 };
    var ops: i32[>..<] = [];
    vp_ops_without_mask(vpi, ops);
    if uniform { return vp_create_single_scalar_op(vpr[vpi].opcode, ops, mask, vpr[vpi].f, vpi, vpr[vpi].dl, i); }
    return vp_new_replicate(i, ops, false, mask, vpr[vpi].f, vpi, vpr[vpi].dl);
}

// tryToOptimizeInductionTruncate
fn lvp_try_to_optimize_induction_truncate(vpi: i32) -> i32 {
    let i = vp_underlying_instr(vpi);
    let ok = lvp_decide() { vf =>
        let src = vals[op(i, 0)].ty as i32;
        let dst = vals[i].ty as i32;
        let o = op(i, 0);
        if o != lvl_primary && lvp_is_truncate_free(src, dst, vf) { false } else { lvl_is_induction_phi(o) }
    };
    if !ok { return -1; }
    let w = vp_def(vp_op(vpi, 0));
    let phi = vp_underlying_instr(w);
    let d = vpr[w].ind;
    let step = vp_get_or_create_value_for_scev(ind_descs[d].step);
    return vp_new_widen_int_or_fp_induction(phi, vp_op(w, 0), step, vph.vf, d, vpf_wrap(false, false), vpr[vpi].dl, i);
}
// TTI.isTruncateFree(toVectorTy(Src, VF), toVectorTy(Dst, VF))
fn lvp_is_truncate_free(src: i32, dst: i32, vf: i64) -> bool {
    let s = if vf > 1 { ty_vector(src, vf, false) } else { src };
    let d = if vf > 1 { ty_vector(dst, vf, false) } else { dst };
    return tti_is_truncate_free(s, d);
}

// shouldWiden
fn lvp_should_widen(i: i32) -> bool {
    let scal = lvp_decide() { vf => cm_is_scalar_after_vectorization(i, vf) || cm_is_profitable_to_scalarize(i, vf) || cm_is_scalar_with_predication(i, vf) };
    return !scal;
}

// VPWidenRecipe(I, Operands, Flags, Metadata, DL)
fn vp_new_widen(i: i32, ops: const i32[:], f: VPF, md_from: i32, dl: i32) -> i32 {
    let r = vp_new_single_def(VPR_WIDEN, ops, vals[i].ty as i32, i, dl);
    vpr[r].opcode = iop(i) as i32;
    vpr[r].f = f;
    if md_from >= 0 { vp_md_copy(r, md_from); }
    return r;
}

// tryToWiden
fn lvp_try_to_widen(vpi: i32) -> i32 {
    let i = vp_underlying_instr(vpi);
    let o = vpr[vpi].opcode as i64;
    if o == OP_SDIV || o == OP_UDIV || o == OP_SREM || o == OP_UREM {
        if cm_is_predicated_inst(i) { vp_unported("masked division intrinsics"); }
    }
    if o == OP_SDIV || o == OP_UDIV || o == OP_SREM || o == OP_UREM || o == OP_ADD || o == OP_AND || o == OP_ASHR ||
       o == OP_FADD || o == OP_FCMP || o == OP_FDIV || o == OP_FMUL || o == OP_FNEG || o == OP_FREM || o == OP_FSUB ||
       o == OP_ICMP || o == OP_LSHR || o == OP_MUL || o == OP_OR || o == OP_SELECT || o == OP_SHL || o == OP_SUB ||
       o == OP_XOR || o == OP_FREEZE {
        var ops: i32[>..<] = [];
        vp_ops_without_mask(vpi, ops);
        return vp_new_widen(i, ops, vpr[vpi].f, vpi, vpr[vpi].dl);
    }
    if o == OP_EXTRACTVALUE { vp_unported("widening extractvalue"); }
    return -1;
}

// tryToCreateWidenNonPhiRecipe
fn lvp_try_to_create_widen_non_phi_recipe(vpi: i32) -> i32 {
    if vpr[vpi].opcode == OP_TRUNC as i32 {
        let r = lvp_try_to_optimize_induction_truncate(vpi);
        if r >= 0 { return r; }
    }
    let scalar = lvp_decide() { vf => vf == 1 };
    if scalar { return -1; }
    let i = vp_underlying_instr(vpi);
    if !lvp_should_widen(i) { return -1; }
    if vpr[vpi].opcode == OP_GEP as i32 {
        var ops: i32[>..<] = [];
        vp_ops_without_mask(vpi, ops);
        let r = vp_new_single_def(VPR_WIDEN_GEP, ops, vals[i].ty as i32, i, vpr[vpi].dl);
        vpr[r].src_elt_ty = insts[inst_of(i)].ty2;
        vpr[r].f = vpr[vpi].f;
        return r;
    }
    if vp_opcode_is_cast(vpr[vpi].opcode) {
        let r = vp_new_single_def(VPR_WIDEN_CAST, [vp_op(vpi, 0)], vpv[vpr[vpi].def].ty, i, vpr[vpi].dl);
        vpr[r].opcode = iop(i) as i32;
        vpr[r].f = vpr[vpi].f;
        vp_md_copy(r, vpi);
        return r;
    }
    return lvp_try_to_widen(vpi);
}

// ---------------------------------------------------------------------------------------------
// makeMemOpWideningDecisions / makeScalarizationDecisions / makeCallWideningDecisions

fn lvp_make_mem_op_widening_decisions() {
    let region = vp_vector_loop_region();
    var blocks: i32[>..<] = [];
    vp_depth_first(vpb[region].entry, false, blocks);
    vp_only_basic(blocks);
    var memops: i32[>..<] = [];
    for b in blocks {
        var r = vpb[b].first;
        while r >= 0 {
            if vpr[r].kind == VPR_INSTRUCTION && vpv[vpr[r].def].uv >= 0 &&
               (vpr[r].opcode == OP_LOAD as i32 || vpr[r].opcode == OP_STORE as i32) { memops.push(r); }
            r = vpr[r].next;
        }
    }
    fn replace_with(vpi: i32, nr: i32) -> bool {
        vp_insert_before(nr, vpi);
        if vpr[vpi].opcode == OP_LOAD as i32 { vp_rauw(vpr[vpi].def, vpr[nr].def); }
        vp_erase_recipe(vpi);
        return true;
    }
    var rem: i32[>..<] = [];
    // lowerMemoryIdioms
    for vpi in memops {
        let i = vp_underlying_instr(vpi);
        if iop(i) == OP_STORE && lvl_is_invariant_address_of_reduction(op(i, 1)) { vp_unported("final invariant stores of reductions"); }
        let scal = lvp_decide() { vf => vf == 1 };
        if !scal && flag_bool("enable-histogram-loop-vectorization", false) { vp_unported("histograms"); }
        rem.push(vpi);
    }
    memops.clear(); for x in rem { memops.push(x); } rem.clear();
    let scal = lvp_decide() { vf => vf == 1 };
    if scal { return; }
    // scalarizeMemOpsWithIrregularTypes
    for vpi in memops {
        let i = vp_underlying_instr(vpi);
        if cm_has_irregular_type(laa_ldst_type(i)) { replace_with(vpi, lvp_handle_replication(vpi)); continue; }
        rem.push(vpi);
    }
    memops.clear(); for x in rem { memops.push(x); } rem.clear();
    // makeVPlanMemOpDecision (TTI.prefersVectorizedAddressing() is false on X86 without gathers)
    if tti_kind == TTI_X86 && !x86_supports_gather_lv() {
        for vpi in memops {
            let i = vp_underlying_instr(vpi);
            let is_load = vpr[vpi].opcode == OP_LOAD as i32;
            if cm_is_predicated_inst(i) || !is_load || !vp_is_used_by_load_store_address(vpr[vpi].def) { rem.push(vpi); continue; }
            // scalarize loads used as addresses: single-scalar when the pointer is loop-invariant
            let ptr = vp_op(vpi, 0);
            let ps = vp_scev_for_value(ptr, lvp_pse, lvp_l);
            let single = !sc_is_cnc(ps) && sc_is_loop_invariant(ps, lvp_l);
            replace_with(vpi, vp_new_replicate(i, [ptr], single, -1, vpr[vpi].f, vpi, vpr[vpi].dl));
        }
        memops.clear(); for x in rem { memops.push(x); } rem.clear();
    }
    // widenConsecutiveMemOps
    for vpi in memops {
        let i = vp_underlying_instr(vpi);
        if cm_is_predicated_inst(i) { rem.push(vpi); continue; }
        let is_load = vpr[vpi].opcode == OP_LOAD as i32;
        let ptr = if is_load { vp_op(vpi, 0) } else { vp_op(vpi, 1) };
        let sty = if is_load { vpv[vpr[vpi].def].ty } else { vp_scalar_type(vp_op(vpi, 0)) };
        let ok, stride = lvp_constant_stride(ptr, sty);
        if !ok || stride != 1 { rem.push(vpi); continue; }
        let stride_ty = ty_int(dl_ptr(ty_bits(vp_scalar_type(ptr))).idx);
        let one = vp_const_int(stride_ty, 1);
        let vp_ = vp_new_single_def(VPR_VECTOR_POINTER, [ptr, one], vp_scalar_type(ptr), -1, vpr[vpi].dl);
        vpr[vp_].src_elt_ty = sty;
        vpr[vp_].f = vpf_gep(vp_gep_flags_for_ptr(ptr));
        vp_insert_before(vp_, vpi);
        var w: i32 = -1;
        if is_load { w = vp_new_widen_load(i, vpr[vp_].def, -1, true, vpi, vpr[vpi].dl); }
        else { w = vp_new_widen_store(i, vpr[vp_].def, vp_op(vpi, 0), -1, true, vpi, vpr[vpi].dl); }
        replace_with(vpi, w);
    }
    memops.clear(); for x in rem { memops.push(x); } rem.clear();
    // delegateMemOpWideningToLegacyCM
    for vpi in memops {
        let r = lvp_try_to_widen_memory(vpi);
        if r >= 0 { replace_with(vpi, r); } else { replace_with(vpi, lvp_handle_replication(vpi)); }
    }
}
fn x86_supports_gather_lv() -> bool { x86_supports_gather() }
// vputils::isUsedByLoadStoreAddress(V)
fn vp_is_used_by_load_store_address(v: i32) -> bool {
    var seen = hm_new();
    var wl: i32[>..<] = [];
    wl.push(v);
    while wl.len > 0 {
        let cur = wl.pop();
        if hm_has(seen, cur as u64) { continue; }
        hm_put(seen, cur as u64, 1);
        let cd = vp_def(cur);
        let blend = cd >= 0 && vpr[cd].kind == VPR_BLEND;
        if blend {
            var any = false;
            let n = vp_nops(cd);
            let nin = if n % 2 == 1 { (n + 1) / 2 } else { n / 2 };
            for k in nin {
                let iv = if n % 2 == 1 { if k == 0 { vp_op(cd, 0) } else { vp_op(cd, 2 * k - 1) } } else { vp_op(cd, 2 * k) };
                if hm_has(seen, iv as u64) { any = true; }
            }
            if !any { continue; }
        }
        for j in vp_num_users(cur) {
            let u = vp_user(cur, j);
            let k = vpr[u].kind;
            if (k == VPR_INTERLEAVE || k == VPR_INTERLEAVE_EVL) && vp_op(u, 0) == cur { return true; }
            let uo = vpm_opcode(u, false);
            if uo == OP_LOAD as i32 && vpm_arity_ok(u, 1) && vp_op(u, 0) == cur { return true; }
            if uo == OP_STORE as i32 && vpm_arity_ok(u, 2) && vp_op(u, 1) == cur { return true; }
            if vp_is_widen_memory_kind(k) && vp_op(u, 0) == cur && vpr[u].consecutive { return true; }
        }
        if blend { continue; }
        for j in vp_num_users(cur) {
            let u = vp_user(cur, j);
            if vpr[u].kind == VPR_INSTRUCTION && vp_mask_of(u) == cur {
                var other = false;
                for x in vp_nops(u) - 1 { if vp_op(u, x) == cur { other = true; } }
                if !other { continue; }
            }
            if vp_is_vpi(u, OP_LOAD as i32) { continue; }
            if vpr[u].def >= 0 { wl.push(vpr[u].def); }
        }
    }
    return false;
}

// getConstantStride(Addr, AccessTy, PSE, L): (ok, stride)
fn lvp_constant_stride(addr: i32, at: i32) -> bool, i64 {
    let s = vp_scev_for_value(addr, lvp_pse, lvp_l);
    if !sc_is_addrec(s) { return false, 0; }
    // getStrideFromAddRec(AddRec, L, AccessTy, Ptr = nullptr, PSE)
    let ok, st = laa_stride_from_addrec(s, lvp_l, at);
    return ok, st;
}

fn lvp_make_scalarization_decisions() {
    let scal = lvp_decide() { vf => vf == 1 };
    if scal { return; }
    var rpo: i32[>..<] = [];
    vp_rpo(vph.entry, true, rpo);
    var k = rpo.len - 1;
    while k >= 0 {
        let b = rpo[k];
        k--;
        if !vp_is_basic(b) { continue; }
        var rs: i32[>..<] = [];
        vp_block_recipes(b, rs);
        var j = rs.len - 1;
        while j >= 0 {
            let r = rs[j];
            j--;
            if vpr[r].kind != VPR_INSTRUCTION { continue; }
            let i = vpv[vpr[r].def].uv;
            if i < 0 { continue; }
            if vp_may_have_side_effects(r) { continue; }
            if vp_is_masked(r) && !vp_is_safe_to_speculatively_execute(r) { continue; }
            if vpr[r].opcode == OP_ADD as i32 {
                var has_iv = false;
                for x in vp_nops(r) { let d = vp_def(vp_op(r, x)); if d >= 0 && vpr[d].kind == VPR_WIDEN_INT_OR_FP_INDUCTION { has_iv = true; } }
                if has_iv { continue; }
            }
            if !vp_only_first_lane_used(vpr[r].def) { continue; }
            var ops: i32[>..<] = [];
            vp_ops_without_mask(r, ops);
            let nr = vp_create_single_scalar_op(vpr[r].opcode, ops, -1, vpr[r].f, r, vpr[r].dl, i);
            vp_insert_before(nr, r);
            vp_rauw(vpr[r].def, vpr[nr].def);
            vp_erase_recipe(r);
        }
    }
}

// CallWideningDecision::KindTy
let CWD_SCALARIZE: i64 = 0; let CWD_INTRINSIC: i64 = 1; let CWD_VARIANT: i64 = 2;
// VPCostContext::willBeScalarized(I, VF)
fn lvp_will_be_scalarized(i: i32, vf: i64) -> bool {
    return cm_is_scalar_with_predication_c(i, vf) || cm_is_uniform_after_vectorization(i, vf) || cm_is_forced_scalar(i, vf) ||
           (vf > 1 && cm_is_profitable_to_scalarize(i, vf));
}
// decideCallWidening(VPI, Ops, VF, CostCtx) (no vector-library variants: legality fails loudly on mappings)
fn lvp_decide_call_widening(vpi: i32, ops: const i32[:], vf: i64) -> i64 {
    let ci = vp_underlying_instr(vpi);
    if vf == 1 || lvp_will_be_scalarized(ci, vf) { return CWD_SCALARIZE; }
    let called = vp_ir(vp_op(vpi, vpm_num_ops_without_mask(vpi) - 1));
    let rty = vpv[vpr[vpi].def].ty;
    let id = laa_vector_intrinsic_id_for_call(ci);
    if id != 0 && vpc_is_free_scalar_intrinsic(id) { return CWD_SCALARIZE; }
    let sc = vpc_replicate_call_cost(called, rty, ops, false, vf);
    if id != 0 {
        let fmf = if vpr[vpi].f.ot == VOT_FMF || vpr[vpi].f.ot == VOT_FCMP { vpr[vpi].f.fmf } else { 0 };
        let ic = vpc_widen_intrinsic_call_cost(id, rty, ci, ops, fmf, vf);
        if lc_valid(ic) && sc >= ic { return CWD_INTRINSIC; }
    }
    return CWD_SCALARIZE;
}
// VPWidenIntrinsicRecipe(CI, ID, Ops, Ty, Flags, MD, DL)
fn vp_new_widen_intrinsic(ci: i32, id: i32, ops: const i32[:], ty: i32, from: i32, dl: i32) -> i32 {
    let r = vp_new_single_def(VPR_WIDEN_INTRINSIC, ops, ty, ci, dl);
    vpr[r].iid = id;
    vpr[r].may_read = inst_may_read_memory(ci);
    vpr[r].may_write = inst_may_write_memory(ci);
    vpr[r].may_se = inst_may_have_side_effects(ci);
    vpr[r].f = vpr[from].f;
    vp_md_copy(r, from);
    return r;
}

fn lvp_make_call_widening_decisions() {
    let region = vp_vector_loop_region();
    var blocks: i32[>..<] = [];
    vp_depth_first(vpb[region].entry, false, blocks);
    vp_only_basic(blocks);
    for b in blocks {
        var rs: i32[>..<] = [];
        vp_block_recipes(b, rs);
        for vpi in rs {
            if vpr[vpi].kind != VPR_INSTRUCTION || vpr[vpi].opcode != OP_CALL as i32 || vpv[vpr[vpi].def].uv < 0 { continue; }
            let ci = vp_underlying_instr(vpi);
            var ops: i32[>..<] = [];
            for k in cb_nargs(ci) { ops.push(vp_op(vpi, k)); }
            let d = lvp_decide_call_widening(vpi, ops, lvp_range_start);
            let same = lvp_decide() { vf => lvp_decide_call_widening(vpi, ops, vf) == d };
            var nr: i32 = -1;
            if d == CWD_INTRINSIC {
                if cb_nbundles(ci) != 0 { vp_unported("widening intrinsic calls with operand bundles"); }
                nr = vp_new_widen_intrinsic(ci, laa_vector_intrinsic_id_for_call(ci), ops, vpv[vpr[vpi].def].ty, vpi, vpr[vpi].dl);
            } else {
                nr = lvp_handle_replication(vpi);
            }
            vp_insert_before(nr, vpi);
            vp_rauw(vpr[vpi].def, vpr[nr].def);
            vp_erase_recipe(vpi);
        }
    }
}

// ---------------------------------------------------------------------------------------------
// tryToBuildVPlan(Plan, Range): the loaded plan is the duplicate of VPlan1

fn lvp_try_to_build_vplan() -> bool {
    let rse_check = lvp_decide() { vf => !cm_requires_scalar_epilogue_lv(vf > 1) };
    let middle = vp_middle_block();
    if !rse_check && vp_nsuccs(middle) == 2 {
        let br = vp_terminator(middle);
        vp_set_operand(br, 0, vp_false());
    }
    // IVUpdateMayOverflow over the range; with the tail not folded the increment keeps NUW anyway
    let region = vp_vector_loop_region();
    var may_overflow = false;
    var ovf = lvp_range_start;
    while ovf < lvp_range_end { if !lvp_is_indvar_overflow_check_known_false(ovf) { may_overflow = true; } ovf *= 2; }
    if may_overflow && cm_fold_tail {
        // clearCanonicalIVNUW(IVInc)
        let inc = vp_def(vp_op(vp_terminator(vpb[region].exiting), 0));
        vp_drop_poison_generating_flags(inc);
        vpb[region].can_iv_nuw = false;
    }
    let header = vpb[region].entry;
    // the interleave groups relevant for this (possibly trimmed) range
    var igs: i32[>..<] = [];
    for gi in iai_groups.len {
        let g = gi as i32;
        if !iai_groups[g].alive { continue; }
        let apply = lvp_decide() { vf => vf > 1 && cm_get_widening_decision(ig_insert_pos(g), vf) == CM_INTERLEAVE };
        if apply { igs.push(g); }
    }
    vpt_create_in_loop_reduction_recipes(lvp_range_start);
    lvp_make_mem_op_widening_decisions();
    lvp_make_scalarization_decisions();
    lvp_make_call_widening_decisions();
    var rpo: i32[>..<] = [];
    vp_rpo(header, false, rpo);
    for b in rpo {
        if !vp_is_basic(b) { continue; }
        var rs: i32[>..<] = [];
        var r = vp_first_non_phi(b);
        while r >= 0 { rs.push(r); r = vpr[r].next; }
        for x in rs {
            let k = vpr[x].kind;
            if k == VPR_WIDEN_CANONICAL_IV || k == VPR_BLEND || k == VPR_REDUCTION || k == VPR_REPLICATE ||
               k == VPR_WIDEN_LOAD || k == VPR_WIDEN_STORE || k == VPR_WIDEN_CALL || k == VPR_WIDEN_INTRINSIC ||
               k == VPR_VECTOR_POINTER || k == VPR_VECTOR_END_POINTER || k == VPR_HISTOGRAM { continue; }
            if vp_is_instruction_with_type(x) && vp_opcode_is_cast(vpr[x].opcode) && vp_only_first_lane_used(vpr[x].def) { continue; }
            if k != VPR_INSTRUCTION { continue; }
            if vpv[vpr[x].def].uv < 0 { continue; }
            vpb_set_before(x);
            var nr = lvp_try_to_create_widen_non_phi_recipe(x);
            if nr < 0 { nr = lvp_handle_replication(x); }
            let i = vpv[vpr[x].def].uv;
            if vpr[nr].kind == VPR_WIDEN_INT_OR_FP_INDUCTION && iop(i) == OP_TRUNC {
                vp_insert_recipe(nr, header, vp_first_non_phi(header));
            } else {
                vpb_insert(nr);
            }
            if vp_num_defined_values(nr) == 1 { vp_rauw(vpr[x].def, vp_defined_value(nr, 0)); }
            vp_erase_recipe(x);
        }
    }
    vpt_adjust_first_order_recurrence_middle_users();
    lvp_add_reduction_result_computation();
    vpt_optimize_find_iv_reductions();
    vpt_optimize_induction_live_out_users(lvp_pse);
    if !vpt_handle_multi_use_reductions() { return false; }
    if !vpt_handle_max_min_num_reductions() { return false; }
    if !vpt_handle_find_last_reductions() { return false; }
    vpt_remove_branch_on_const(false);
    vpt_create_partial_reductions();
    vpt_convert_to_abstract_recipes();
    vpt_create_interleave_groups(igs, lvp_epilogue_allowed);
    vpt_convert_to_strided_accesses();
    if lvp_range_start == 1 { lvp_range_end = 2; }
    var vf = lvp_range_start;
    while vf < lvp_range_end { vp_add_vf(vf); vf *= 2; }
    vph.name = intern("Initial VPlan");
    vpt_drop_poison_generating_recipes();
    return true;
}

// isIndvarOverflowCheckKnownFalse(Cost, VF) (UF unknown: the maximum interleave factor)
fn lvp_is_indvar_overflow_check_known_false(vf: i64) -> bool {
    let max_uf = if tti_kind == TTI_X86 { x86_max_interleave_factor(vf) } else { 1 };
    let w = ty_bits(lvl_widest_ind_ty);
    let tc = lv_small_best_known_tc(true, false, true);
    if tc == 0 { return false; }
    // (MaxUIntTripCount - MaxTC).ugt(MaxVF * MaxUF) at the induction's width (MaxTC, MaxVF: unsigned)
    let d = ap_sub(ap_ones(w), ap_u64((tc as u64) & 0xFFFFFFFF, w));
    let p = ap_u64(((vf as u64) * (max_uf as u64)) & 0xFFFFFFFF, w);
    return ap_ugt(d, p);
}

// requiresScalarEpilogue(IsVectorizing) of the cost model (lv_pass.goose keeps the epilogue status)
var lvp_epilogue_allowed: bool = true;
fn cm_requires_scalar_epilogue_lv(is_vectorizing: bool) -> bool {
    if !lvp_epilogue_allowed { return false; }
    let l = lvp_l;
    if lvp_exiting_block(l) != loop_latch(l) && !(flag_bool("enable-early-exit-vectorization", true) && lvl_has_uncountable_early_exit()) { return true; }
    if is_vectorizing && iai_requires_scalar_epilogue() { return true; }
    return false;
}
fn lvp_exiting_block(l: i32) -> i32 {
    var ex: i32[>..<] = [];
    loop_exiting_blocks(l, ex);
    return if ex.len == 1 { ex[0] } else { -1 };
}

// addReductionResultComputation(Plan, RecipeBuilder, MinVF): the plain reductions (AnyOf, FindIV, FindLast, in-loop,
// truncated and tail-folded reductions fail loudly before VPlans are built)
fn lvp_add_reduction_result_computation() {
    let region = vp_vector_loop_region();
    let header = vpb[region].entry;
    let middle = vp_middle_block();
    let ip = vp_first_non_phi(middle);
    let exit_dl = inst_get_md(block_terminator(loop_latch(lvp_l)), 0);
    var phis: i32[>..<] = [];
    vp_block_phis(header, phis);
    for phir in phis {
        if vpr[phir].kind != VPR_REDUCTION_PHI { continue; }
        let rk = vpr[phir].rdx_kind;
        let phi = vp_underlying_instr(phir);
        let rd = lvl_rdx_of(phi);
        let phi_ty = vpv[vpr[phir].def].ty;
        if vpb[region].header_mask >= 0 { vp_unported("reductions with a header mask"); }
        let be = vp_op(phir, 1);
        let bd = vp_def(be);
        if bd >= 0 && vpr[bd].kind == VPR_BLEND { vp_unported("reductions through blends"); }
        if rk_is_any_of(rk) { vp_unported("any-of reductions"); }
        if lvp_range_start > 1 && phi_ty != rdx_descs[rd].rty { vp_unported("truncated reductions"); }
        if ip >= 0 { vpb_set_before(ip); } else { vpb_set_at_end(middle); }
        let fl = vpf_reduction(rk, vpr[phir].rdx_style == VRS_ORDERED, vpr[phir].rdx_style != VRS_UNORDERED, vp_fmf_of_flags(vpr[phir].f));
        let fin = vpb_nary(VPI_COMPUTE_REDUCTION_RESULT, [be], fl, exit_dl, "", -1);
        let finv = vpr[fin].def;
        var users: i32[>..<] = [];
        for j in vp_num_users(be) { users.push(vp_user(be, j)); }
        for u0 in users {
            var u = u0;
            if u == fin || vpb[vpr[u].parent].parent >= 0 { continue; }
            if vp_is_vpi(u, VPI_COMPUTE_REDUCTION_RESULT) || (rk_is_find_iv(rk) && vp_is_vpi(u, OP_ICMP as i32)) { continue; }
            vp_replace_uses_of_with(u, be, finv);
            if vpm_vpi_r(u, VPI_EXTRACT_LAST_PART, 1) { u = vp_single_user(vpr[u].def); }
            if u >= 0 && (vpm_vpi_r(u, VPI_EXTRACT_LANE, 2) || vpm_vpi_r(u, VPI_EXTRACT_LAST_LANE, 1)) { vp_rauw(vpr[u].def, finv); }
        }
        if !rk_is_any_of(rk) && !rk_is_find_iv(rk) && !rk_is_minmax(rk) && !rk_is_find_last(rk) {
            let ph = vp_vector_preheader();
            vpb_set_at_end(ph);
            let iden = vp_live_in(lvp_recurrence_identity(rk, phi_ty, vp_fmf_of_flags(vpr[phir].f)));
            let sv = vpb_nary(VPI_REDUCTION_START_VECTOR, [vp_op(phir, 0), iden, vp_const_int(T_I32, 1)], vpr[phir].f, -1, "", -1);
            vp_set_operand(phir, 0, vpr[sv].def);
        }
    }
    vpt_clear_reduction_wrap_flags();
}
fn vp_fmf_of_flags(f: VPF) -> u8 { if f.ot == VOT_FMF || f.ot == VOT_FCMP || f.ot == VOT_REDUCTION { f.fmf } else { 0 } }
// getRecurrenceIdentity(K, Tp, FMF) for the arithmetic kinds
fn lvp_recurrence_identity(k: i32, ty: i32, fmf: u8) -> i32 {
    var o = rk_opcode(k);
    if k == RK_SUB || k == RK_ADD_CHAIN_WITH_SUBS { o = OP_ADD; }
    if k == RK_FSUB || k == RK_FADD_CHAIN_WITH_SUBS || k == RK_FMULADD { o = OP_FADD; }
    if o == OP_FADD && (fmf & FMF_NSZ) != 0 { return c_null(ty); }
    return binop_identity(o, ty, false);
}
// clearReductionWrapFlags
fn vpt_clear_reduction_wrap_flags() {
    var phis: i32[>..<] = [];
    vp_block_phis(vpb[vp_vector_loop_region()].entry, phis);
    for phir in phis {
        if vpr[phir].kind != VPR_REDUCTION_PHI { continue; }
        let rk = vpr[phir].rdx_kind;
        if rk != RK_ADD && rk != RK_MUL && rk != RK_SUB && rk != RK_ADD_CHAIN_WITH_SUBS { continue; }
        var us: i32[>..<] = [];
        var seen = hm_new();
        let d = vpr[phir].def;
        for j in vp_num_users(d) { let u = vp_user(d, j); if ivd_set_add(seen, u) { us.push(u); } }
        var k: i64 = 0;
        while k < us.len {
            let cur = us[k];
            k++;
            for j in vp_num_defined_values(cur) {
                let v = vp_defined_value(cur, j);
                for jj in vp_num_users(v) { let u = vp_user(v, jj); if ivd_set_add(seen, u) { us.push(u); } }
            }
        }
        for u in us { if vp_is_recipe_with_ir_flags(vpr[u].kind) { vp_drop_poison_generating_flags(u); } }
    }
}
