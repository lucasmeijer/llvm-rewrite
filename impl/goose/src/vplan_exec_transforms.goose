// The VPlan transforms LoopVectorizationPlanner::executePlan runs on the chosen plan before emitting IR
// (llvm/lib/Transforms/Vectorize/VPlanTransforms.cpp, VPlanUnroll.cpp, VPlan.cpp, VPlanConstruction.cpp):
// replaceWideCanonicalIVWithWideIV, unrollByUF (UF 1), materializePacksAndUnpacks, materializeBroadcasts,
// replicateByVF (without replicate regions), materializeConstantVectorTripCount, optimizeForVFAndUF
// (simplifyBranchConditionForVFAndUF), convertToConcreteRecipes, dissolveLoopRegions, expandBranchOnTwoConds,
// materializeBackedgeTakenCount / VectorTripCount / Factors, expandSCEVsToVPInstructions (VPSCEVExpander), cse,
// expandSCEVs, addMinimumIterationCheck. Unported paths fail loudly.
import std;
import ir;
import irutil;
import instinfo;
import gen_iids;
import datalayout;
import pm;
import apint;
import domtree;
import loopinfo;
import scev;
import scev_create;
import scev_guards;
import scev_pred;
import scev_update;
import scev_expander;
import pse;
import iv_descriptors;
import vplan;
import vplan_utils;
import vplan_props;
import vplan_transforms;

// replaceWideCanonicalIVWithWideIV (the plans built so far have no VPWidenCanonicalIVRecipe without tail folding)
fn vpx_replace_wide_canonical_iv_with_wide_iv() {
    let region = vp_vector_loop_region();
    if region < 0 { return; }
    let can_iv = vpb[region].can_iv;
    for j in vp_num_users(can_iv) {
        if vpr[vp_user(can_iv, j)].kind == VPR_WIDEN_CANONICAL_IV { vp_unported("replaceWideCanonicalIVWithWideIV"); }
    }
}

// unrollByUF (VPlanUnroll.cpp, UnrollState)
var vpu_uf: i64 = 1;
var vpu_parts = hm_new();       // VPV2Parts: value of part 0 -> index of a run of UF-1 values in vpu_pool
var vpu_pool: i32[>..<];
var vpu_skip = hm_new();        // ToSkip

fn vpu_part(v: i32, part: i64) -> i32 {
    if part == 0 || vp_is_ir_value(v) || vp_is_symbolic(v) { return v; }
    let at = hm_get(vpu_parts, v as u64, -1);
    if at < 0 { fatal("internal: loop-vectorize: unrollByUF: accessed value does not exist"); }
    return vpu_pool[at + part - 1];
}
fn vpu_run(v: i32) -> i64 {
    var at = hm_get(vpu_parts, v as u64, -1);
    if at < 0 {
        at = vpu_pool.len;
        for k in vpu_uf - 1 { vpu_pool.push(-1); }
        hm_put(vpu_parts, v as u64, at);
    }
    return at;
}
// addRecipeForPart(OrigR, CopyR, Part)
fn vpu_add_recipe_for_part(orig: i32, copy: i32, part: i64) {
    for k in vp_num_defined_values(orig) {
        let at = vpu_run(vp_defined_value(orig, k));
        vpu_pool[at + part - 1] = vp_defined_value(copy, k);
    }
}
// addUniformForAllParts(R)
fn vpu_add_uniform(r: i32) {
    let d = vpr[r].def;
    if hm_has(vpu_parts, d as u64) { fatal("internal: loop-vectorize: uniform value already added"); }
    let at = vpu_run(d);
    for k in vpu_uf - 1 { vpu_pool[at + k] = d; }
}
fn vpu_remap_operand(r: i32, k: i64, part: i64) { vp_set_operand(r, k, vpu_part(vp_op(r, k), part)); }
fn vpu_remap_operands(r: i32, part: i64) { for k in vp_nops(r) { vpu_remap_operand(r, k, part); } }
fn vpu_const_int(part: i64) -> i32 { vp_const_int(vpv[vpb[vp_vector_loop_region()].can_iv].ty, part as u64) }

// addStartIndexForScalarSteps(Steps, Part, Plan)
fn vpu_add_start_index_for_scalar_steps(steps: i32, part: i64) {
    if part == 0 { return; }
    vpb_set_before(steps);
    let base_ty = vp_scalar_type(vp_op(steps, 0));
    let int_ty = ty_int(ty_bits(ty_scalar(base_ty)));
    var si = vp_op(steps, 2);
    if part > 1 {
        si = vp_val(vpb_nary(OP_MUL as i32, [si, vp_const_int(vp_scalar_type(si), part as u64)], vpf_wrap(false, false), -1, "", -1));
    }
    si = vpb_scalar_sext_or_trunc(si, int_ty, vp_scalar_type(si), vpr[steps].dl);
    if ty_is_fp(base_ty) { si = vp_val(vpb_scalar_cast(OP_SITOFP, si, base_ty, vpr[steps].dl, vpf_none())); }
    if vp_nops(steps) == 4 { vp_set_operand(steps, 3, si); } else { vp_add_operand(steps, si); }
}

// unrollWidenInductionByUF(IV, InsertPtForPhi)
fn vpu_unroll_widen_induction(iv: i32, insert_pt: i32) {
    if vpr[iv].kind != VPR_WIDEN_INT_OR_FP_INDUCTION { vp_unported("unrolling pointer inductions"); }
    let ph = vp_single_pred(vp_enclosing_loop_region(vpr[iv].parent));
    let ivty = vpv[vpr[iv].def].ty;
    let d = vpr[iv].ind;
    var fmf: u8 = 0;
    if vpr[iv].f.ot == VOT_FMF { fmf = vpr[iv].f.fmf; }
    var wrap = vpf_wrap(false, false);
    if vpr[iv].f.ot == VOT_OVERFLOWING { wrap = vpf_wrap(vpr[iv].f.nuw, vpr[iv].f.nsw); }
    let sstep = vp_op(iv, 1);
    vpb_set_at_end(ph);
    let vsty = if ty_kind(ivty) == TK_PTR { vp_scalar_type(sstep) } else { ivty };
    let vstep = vpb_nary(VPI_WIDE_IV_STEP, [vph.vf, sstep], vpf_fmf(fmf), vpr[iv].dl, "", vsty);
    hm_put(vpu_skip, vstep as u64, 1);
    var prev = vpr[iv].def;
    if insert_pt >= 0 { vpb_set_before(insert_pt); } else { vpb_set_at_end(vpr[iv].parent); }
    var add_opc = OP_ADD as i32;
    var add_flags = wrap;
    if ty_is_fp(ivty) {
        add_opc = ind_opcode(d) as i32;
        add_flags = vpf_fmf(fmf);
    } else {
        let region = vp_vector_loop_region();
        let canonical = vpm_zero_int(vp_op(iv, 0)) && vpm_one(vp_op(iv, 1)) && ivty == vpv[vpb[region].can_iv].ty;
        if canonical { add_flags = vpf_wrap(true, false); }
    }
    for part in 1..vpu_uf {
        let nm = if part > 1 { str("step.add.", part) } else { str("step.add") };
        let add = vpb_nary(add_opc, [prev, vpr[vstep].def], add_flags, vpr[iv].dl, nm, -1);
        hm_put(vpu_skip, add as u64, 1);
        vpu_add_recipe_for_part(iv, add, part);
        prev = vpr[add].def;
    }
    vp_add_operand(iv, vpr[vstep].def);
    vp_add_operand(iv, prev);
}

// unrollHeaderPHIByUF(R, InsertPtForPhi)
fn vpu_unroll_header_phi(r: i32, insert_pt: i32) {
    let k = vpr[r].kind;
    if k == VPR_FIRST_ORDER_RECURRENCE_PHI { return; }
    if vp_is_widen_induction_kind(k) { vpu_unroll_widen_induction(r, insert_pt); return; }
    if k == VPR_REDUCTION_PHI && vpr[r].rdx_style == VRS_ORDERED { return; }
    if k != VPR_REDUCTION_PHI {
        if k != VPR_ACTIVE_LANE_MASK_PHI { fatal("internal: loop-vectorize: unexpected header phi recipe not needing unrolled part"); }
        vp_unported("unrolling active-lane-mask phis");
    }
    let next = vpr[r].next;
    for part in 1..vpu_uf {
        let c = vp_clone(r);
        if next >= 0 { vp_insert_before(c, next); } else { vp_append_recipe(vpr[r].parent, c); }
        vpu_add_recipe_for_part(r, c, part);
        let sv = vp_op(r, 0);
        let svr = vp_def(sv);
        if svr >= 0 && vpr[svr].kind == VPR_INSTRUCTION {
            if vpr[svr].opcode != VPI_REDUCTION_START_VECTOR { fatal("internal: loop-vectorize: unexpected start VPInstruction"); }
            if part != 1 { continue; }
            var startv: i32 = -1;
            if vpm_one(vp_op(svr, 2)) { startv = vp_op(svr, 1); }
            else {
                let cc = vp_clone(svr);
                vp_set_operand(cc, 0, vp_op(cc, 1));
                vp_insert_after(cc, svr);
                startv = vpr[cc].def;
            }
            let at = vpu_run(sv);
            for p2 in 1..vpu_uf { vpu_pool[at + p2 - 1] = startv; }
        }
    }
}

// unrollRecipeByUF(R)
fn vpu_unroll_recipe(r: i32) {
    if vpm_vpi_r(r, VPI_BRANCH_ON_COND, 1) || vpm_vpi_r(r, VPI_BRANCH_ON_COUNT, 2) { return; }
    if vpr[r].kind == VPR_INSTRUCTION && vp_only_first_part_used(vpr[r].def) { vpu_add_uniform(r); return; }
    if vpr[r].kind == VPR_REPLICATE {
        let ui = vp_underlying_instr(r);
        if iop(ui) == OP_STORE && vp_is_defined_outside_loop_regions(vp_op(r, 1)) { vpu_remap_operands(r, vpu_uf - 1); return; }
        if inst_iid(ui) == IID_experimental_noalias_scope_decl { vpu_add_uniform(r); return; }
    }
    let k = vpr[r].kind;
    if k == VPR_VECTOR_END_POINTER { vp_unported("unrolling vector end pointers (reverse accesses)"); }
    if k == VPR_REDUCTION { vp_unported("unrolling reductions"); }
    let next = vpr[r].next;
    let bb = vpr[r].parent;
    for part in 1..vpu_uf {
        let c = vp_clone(r);
        if next >= 0 { vp_insert_before(c, next); } else { vp_append_recipe(bb, c); }
        vpu_add_recipe_for_part(r, c, part);
        if vpr[c].kind == VPR_WIDEN_PHI { continue; }
        if vpm_vpi_r(r, VPI_FIRST_ORDER_RECURRENCE_SPLICE, 2) {
            let o = vp_op(r, 1);
            vp_set_operand(c, 0, vpu_part(o, part - 1));
            vp_set_operand(c, 1, vpu_part(o, part));
            continue;
        }
        if k == VPR_VECTOR_POINTER || k == VPR_WIDEN_CANONICAL_IV {
            vpb_set_before(r);
            let idx_ty = if k == VPR_WIDEN_CANONICAL_IV { vpv[vpb[vp_vector_loop_region()].can_iv].ty } else { ty_int(dl_ptr(types[ty_scalar(vp_scalar_type(vpr[r].def))].n as i64).idx) };
            let vfty = vp_scalar_type(vph.vf);
            let vfv = vpb_scalar_zext_or_trunc(vph.vf, idx_ty, vfty, -1);
            let m = vpb_nary(OP_MUL as i32, [vfv, vp_const_int(idx_ty, part as u64)], vpf_wrap(true, true), -1, "", -1);
            vp_add_operand(c, vpr[m].def);
            continue;
        }
        vpu_remap_operands(c, part);
        if vpr[c].kind == VPR_SCALAR_IV_STEPS { vpu_add_start_index_for_scalar_steps(c, part); }
        if vp_is_vpi(c, VPI_CANONICAL_IV_INCREMENT_FOR_PART) {
            vpb_set_before(c);
            let m = vpb_nary(OP_MUL as i32, [vp_op(c, 1), vpu_const_int(part)], vpf_wrap(false, false), -1, "", -1);
            vp_set_operand(c, 1, vpr[m].def);
        }
    }
    if k == VPR_WIDEN_CANONICAL_IV { vp_add_operand(r, vpu_const_int(0)); }
}

// UnrollState::unrollBlock for a basic block
fn vpu_unroll_basic_block(b: i32) {
    let insert_pt = vp_first_non_phi(b);
    var rs: i32[>..<] = [];
    vp_block_recipes(b, rs);
    for r in rs {
        if hm_has(vpu_skip, r as u64) || vpr[r].kind == VPR_IR_INSTRUCTION { continue; }
        if vpr[r].kind == VPR_INSTRUCTION {
            let o = vpr[r].opcode;
            if (o == VPI_ANY_OF || o == VPI_FIRST_ACTIVE_LANE || o == VPI_LAST_ACTIVE_LANE || o == VPI_COMPUTE_REDUCTION_RESULT) && vp_nops(r) == 1 {
                vpu_add_uniform(r);
                let x = vp_op(r, 0);
                for part in 1..vpu_uf { vp_add_operand(r, vpu_part(x, part)); }
                continue;
            }
            if o == VPI_EXTRACT_LANE && vp_nops(r) == 2 {
                vpu_add_uniform(r);
                let x = vp_op(r, 1);
                for part in 1..vpu_uf { vp_add_operand(r, vpu_part(x, part)); }
                continue;
            }
            if o == VPI_EXTRACT_LAST_ACTIVE && vp_nops(r) == 3 {
                vpu_add_uniform(r);
                let x1 = vp_op(r, 1);
                let x2 = vp_op(r, 2);
                for part in 1..vpu_uf { vp_add_operand(r, vpu_part(x1, part)); vp_add_operand(r, vpu_part(x2, part)); }
                continue;
            }
            if vp_has_scalar_vf_only() && ((o == VPI_EXTRACT_LAST_PART || o == VPI_EXTRACT_PENULTIMATE_ELEMENT) && vp_nops(r) == 1) {
                let pi = if o == VPI_EXTRACT_PENULTIMATE_ELEMENT { vpu_uf - 2 } else { vpu_uf - 1 };
                vp_rauw(vpr[r].def, vpu_part(vp_op(r, 0), pi));
                continue;
            }
            var is_last_of_last = false;
            if o == VPI_EXTRACT_LAST_LANE && vp_nops(r) == 1 {
                let d = vp_def(vp_op(r, 0));
                if vpm_vpi_r(d, VPI_EXTRACT_LAST_PART, 1) { is_last_of_last = true; }
            }
            if is_last_of_last || (o == VPI_EXTRACT_PENULTIMATE_ELEMENT && vp_nops(r) == 1) {
                vpu_add_uniform(r);
                vp_set_operand(r, 0, vpu_part(vp_op(r, 0), vpu_uf - 1));
                continue;
            }
        }
        if vpr[r].def >= 0 && vp_is_uniform_across_vfs_and_ufs(vpr[r].def) { vpu_add_uniform(r); continue; }
        if vp_is_header_phi(r) { vpu_unroll_header_phi(r, insert_pt); continue; }
        vpu_unroll_recipe(r);
    }
}

fn vpx_unroll_by_uf(uf: i64) {
    vp_set_uf(uf);
    if uf != 1 {
        vpu_uf = uf;
        hm_clear(vpu_parts); vpu_pool.clear(); hm_clear(vpu_skip);
        var top: i32[>..<] = [];
        vp_rpo(vph.entry, false, top);
        for b in top {
            if vp_is_region(b) {
                if vp_is_replicator(b) { vp_unported("unrolling replicate regions"); }
                var inner: i32[>..<] = [];
                vp_rpo(vpb[b].entry, false, inner);
                for ib in inner {
                    if vp_is_region(ib) { vp_unported("unrolling replicate regions"); }
                    vpu_unroll_basic_block(ib);
                }
            } else {
                vpu_unroll_basic_block(b);
            }
        }
        var part: i64 = 1;
        var phis: i32[>..<] = [];
        vp_block_phis(vp_entry_basic_block(vp_vector_loop_region()), phis);
        for h in phis {
            if vpr[h].kind == VPR_FIRST_ORDER_RECURRENCE_PHI { vpu_remap_operand(h, 1, uf - 1); continue; }
            if hm_has(vpu_parts, vpr[h].def as u64) { part = 1; continue; }
            vpu_remap_operands(h, part);
            part++;
        }
        vpt_remove_dead_recipes();
    }
    var bs: i32[>..<] = [];
    vp_all_basic_blocks_deep(bs);
    for b in bs {
        var rs: i32[>..<] = [];
        vp_block_recipes(b, rs);
        for r in rs {
            if vp_is_vpi(r, VPI_CANONICAL_IV_INCREMENT_FOR_PART) && vp_op(r, 1) == vph.vf {
                vp_rauw(vpr[r].def, vp_op(r, 0));
                vp_erase_recipe(r);
            }
        }
    }
    let tcty = vp_scalar_type(vph.trip_count);
    vp_rauw(vph.uf, vp_const_int(tcty, uf as u64));
}

// VPInstruction::doesGeneratePerAllLanes
fn vpi_does_generate_per_all_lanes(r: i32) -> bool { vpr[r].opcode == VPI_PTR_ADD && !vp_only_first_lane_used(vpr[r].def) }

// materializePacksAndUnpacks
fn vpx_materialize_packs_and_unpacks() {
    if vp_has_scalar_vf_only() { return; }
    let region = vp_vector_loop_region();
    var outside: i32[>..<] = [];
    vp_depth_first(vph.entry, false, outside);
    vp_only_basic(outside);
    var inside: i32[>..<] = [];
    vp_depth_first(vpb[region].entry, false, inside);
    vp_only_basic(inside);
    var all: i32[>..<] = [];
    for b in outside { all.push(b); }
    for b in inside { all.push(b); }
    for bb in all {
        var rs: i32[>..<] = [];
        vp_block_recipes(bb, rs);
        for r in rs {
            let k = vpr[r].kind;
            if k != VPR_SCALAR_IV_STEPS && k != VPR_REPLICATE && k != VPR_INSTRUCTION { continue; }
            let d = vpr[r].def;
            if k == VPR_REPLICATE && vpr[r].single_scalar { continue; }
            if k == VPR_INSTRUCTION && (vp_only_first_lane_used(d) || !vpi_does_generate_per_all_lanes(r)) { continue; }
            var any = false;
            for j in vp_num_users(d) { let u = vp_user(d, j); if !vp_uses_scalars(u, d) || vp_recipe_region(u) != region { any = true; } }
            if !any { continue; }
            if ty_is_struct(vp_scalar_type(d)) { vp_unported("struct build vectors"); }
            let bv = vp_new_instruction(VPI_BUILD_VECTOR, [d], vpf_none(), -1, "", -1);
            vp_insert_after(bv, r);
            let bvd = vpr[bv].def;
            vp_replace_uses_with_if(d, bvd) { u, i => u != bv && (!vp_uses_scalars(u, d) || vp_recipe_region(u) != region) };
        }
    }
    for bb in inside {
        var rs: i32[>..<] = [];
        vp_block_recipes(bb, rs);
        for r in rs {
            let k = vpr[r].kind;
            if k == VPR_REPLICATE || k == VPR_INSTRUCTION || k == VPR_SCALAR_IV_STEPS || k == VPR_DERIVED_IV { continue; }
            for di in vp_num_defined_values(r) {
                let d = vp_defined_value(r, di);
                if vp_is_single_scalar(d) { continue; }
                var n: i64 = 0;
                for j in vp_num_users(d) { if vp_uses_first_lane_only(vp_user(d, j), d) { n++; } }
                if n == 0 || n == vp_num_users(d) { continue; }
                let up = vp_new_instruction(VPI_UNPACK, [d], vpf_none(), -1, "", -1);
                if vp_is_phi_recipe(r) { vp_insert_recipe(up, bb, vp_first_non_phi(bb)); } else { vp_insert_after(up, r); }
                vp_replace_uses_with_if(d, vpr[up].def) { u, i => vp_uses_first_lane_only(u, d) };
            }
        }
    }
}

// materializeBroadcasts
fn vpx_materialize_broadcasts() {
    if vp_has_scalar_vf_only() { return; }
    var values: i32[>..<] = [];
    if vph.btc >= 0 { values.push(vph.btc); }
    for j in xv_len(vph.live_in_order) { let x = vp_get_live_in(xv_get(vph.live_in_order, j)); if x >= 0 { values.push(x); } }
    var r = vpb[vph.entry].first;
    while r >= 0 { for k in vp_num_defined_values(r) { values.push(vp_defined_value(r, k)); } r = vpr[r].next; }
    let vph_ = vp_vector_preheader();
    for v in values {
        if vp_only_scalar_values_used(v) || vp_is_constant(v) { continue; }
        var hoist: i32 = -1;
        for j in vp_num_users(v) {
            let u = vp_user(v, j);
            if vp_uses_scalars(u, v) { continue; }
            if vpr[u].parent == vph_ { hoist = vpb[vph_].first; }
        }
        vpb_set_at(vph_, hoist);
        let bc = vpb_nary(VPI_BROADCAST, [v], vpf_none(), -1, "", -1);
        vp_replace_uses_with_if(v, vpr[bc].def) { u, i => bc != u && !vp_uses_scalars(u, v) };
    }
}

// replicateByVF (no replicate regions)
var vpx_lane_defs = hm_new();        // VPValue -> index of its first lane in vpx_lane_pool
var vpx_lane_pool: i32[>..<];
fn vpx_lane_def(v: i32, lane: i64) -> i32 { let x = hm_get(vpx_lane_defs, v as u64, -1); if x < 0 { -1 } else { vpx_lane_pool[x + lane] } }

// addLaneToStartIndex
fn vpx_add_lane_to_start_index(steps: i32, lane: i64, insert_pt: i32) {
    let base_ty = vp_scalar_type(vp_op(steps, 0));
    let old = if vp_nops(steps) == 4 { vp_op(steps, 3) } else { -1 };
    if ty_is_fp(base_ty) { vp_unported("FP scalar IV steps lanes"); }
    let bits = ty_bits(base_ty);
    let mask: u64 = if bits >= 64 { 0xFFFFFFFFFFFFFFFF } else { ((1 as u64) << (bits as u64)) - 1 };
    let lane_off = vp_const_int(base_ty, (lane as u64) & mask);
    var nw = lane_off;
    if old >= 0 {
        vpb_set_before(insert_pt);
        nw = vp_val(vpb_nary(OP_ADD as i32, [old, lane_off], vpf_wrap(false, false), -1, "", -1));
    }
    if vp_nops(steps) == 4 { vp_set_operand(steps, 3, nw); } else { vp_add_operand(steps, nw); }
}

// cloneForLane
fn vpx_clone_for_lane(idx_ty: i32, defr: i32, lane: i64) -> i32 {
    vpb_set_before(defr);
    if vp_is_vpi(defr, VPI_UNPACK) {
        let o = vp_op(defr, 0);
        let ld = vpx_lane_def(o, lane);
        if ld >= 0 { return ld; }
        return vp_val(vpb_nary(OP_EXTRACTELEMENT as i32, [o, vp_const_int(idx_ty, lane as u64)], vpf_none(), -1, "", -1));
    }
    var nops_: i32[>..<] = [];
    for k in vp_nops(defr) {
        let o = vp_op(defr, k);
        let ld = vpx_lane_def(o, lane);
        if ld >= 0 { nops_.push(ld); continue; }
        if vp_is_single_scalar(o) { nops_.push(o); continue; }
        if vp_val_is_vpi(o, VPI_BUILD_VECTOR) { nops_.push(vp_op(vp_def(o), lane)); continue; }
        vpb_set_before(defr);
        nops_.push(vp_val(vpb_nary(OP_EXTRACTELEMENT as i32, [o, vp_const_int(idx_ty, lane as u64)], vpf_none(), -1, "", -1)));
    }
    var nw: i32 = -1;
    if vpr[defr].kind == VPR_REPLICATE {
        let ui = vp_underlying_instr(defr);
        nw = vp_create_single_scalar_op(iop(ui) as i32, nops_, -1, vpr[defr].f, defr, vpr[defr].dl, ui);
    } else {
        nw = vp_clone(defr);
        for k in nops_.len { vp_set_operand(nw, k, nops_[k]); }
        if vpr[nw].kind == VPR_SCALAR_IV_STEPS && lane != 0 { vpx_add_lane_to_start_index(nw, lane, defr); }
    }
    vp_insert_before(nw, defr);
    return vpr[nw].def;
}

fn vpx_replicate_by_vf(vf: i64) {
    let idx_ty = ty_int(32);
    hm_clear(vpx_lane_defs);
    vpx_lane_pool.clear();
    let region = vp_vector_loop_region();
    var bs: i32[>..<] = [];
    vp_depth_first(vpb[region].entry, false, bs);
    for b in bs { if vp_is_region(b) && vp_is_replicator(b) { vp_unported("replicate regions (replicateByVF)"); } }
    if vp_has_scalar_vf_only() { return; }
    var blocks: i32[>..<] = [];
    vp_depth_first(vph.entry, false, blocks);
    vp_only_basic(blocks);
    var inner: i32[>..<] = [];
    vp_depth_first(vpb[region].entry, false, inner);
    vp_only_basic(inner);
    for b in inner { blocks.push(b); }
    var to_remove: i32[>..<] = [];
    for bb in blocks {
        var rs: i32[>..<] = [];
        vp_block_recipes(bb, rs);
        for r in rs {
            let k = vpr[r].kind;
            if k != VPR_INSTRUCTION && k != VPR_REPLICATE && k != VPR_SCALAR_IV_STEPS { continue; }
            if k == VPR_REPLICATE && vpr[r].single_scalar { continue; }
            if k == VPR_INSTRUCTION && !vpi_does_generate_per_all_lanes(r) && vpr[r].opcode != VPI_UNPACK { continue; }
            let d = vpr[r].def;
            if vp_num_users(d) == 0 {
                for i in vf { vpx_clone_for_lane(idx_ty, r, i); }
                vp_erase_recipe(r);
                continue;
            }
            var defs: i32[>..<] = [];
            for i in vf { defs.push(vpx_clone_for_lane(idx_ty, r, i)); }
            let at = vpx_lane_pool.len;
            for x in defs { vpx_lane_pool.push(x); }
            hm_put(vpx_lane_defs, d as u64, at);
            vp_replace_uses_with_if(d, defs[0]) { u, i => vp_uses_first_lane_only(u, d) || (vp_is_instruction_with_type(u) && vp_opcode_is_cast(vpr[u].opcode)) };
            var users: i32[>..<] = [];
            vp_users(d, users);
            for us in users {
                if !(vp_is_vpi(us, VPI_BUILD_VECTOR) || vp_is_vpi(us, VPI_BUILD_STRUCT_VECTOR)) { continue; }
                vp_set_operand(us, 0, defs[0]);
                for i in 1..defs.len { vp_add_operand(us, defs[i]); }
            }
            to_remove.push(r);
        }
    }
    var k = to_remove.len - 1;
    while k >= 0 { vp_erase_recipe(to_remove[k]); k--; }
}

// materializeConstantVectorTripCount
fn vpx_materialize_constant_vector_trip_count(vf: i64, uf: i64) {
    let tc = vph.trip_count;
    if vp_num_users(tc) == 0 { return; }
    if vp_has_tail_folded() || !vp_has_scalar_tail() || vp_single_succ(vp_middle_block()) == vp_scalar_preheader() || !vp_is_ir_value(tc) { return; }
    let tcs = sc_get_scev(vp_ir(tc));
    if !sc_is_const(tcs) { return; }
    let vfxuf = sc_get_constant_ty(sc_ty(tcs), (vf * uf) as u64, false);
    let vtc = sc_mul(sc_get_udiv(tcs, vfxuf), vfxuf);
    if sc_is_const(vtc) { vp_set_underlying(vph.vtc, sc_value(vtc)); }
}

// isConditionTrueViaVFAndUF
recursive fn vpx_is_condition_true_via_vf_and_uf(cond: i32, vf: i64, uf: i64, pse: i32) -> bool {
    let r = vp_def(cond);
    let ok, a, b = vpm_binary(cond, OP_OR);
    if ok && vpr[r].kind != VPR_WIDEN_CAST {
        for k in vp_nops(r) { if vpx_is_condition_true_via_vf_and_uf(vp_op(r, k), vf, uf, pse) { return true; } }
        return false;
    }
    let can_iv = vpb[vp_vector_loop_region()].can_iv;
    let okc, l, rr = vpm_binary(cond, OP_ICMP);
    if !okc || vpr[r].f.pred != 32 { return false; }
    if rr != vph.vtc { return false; }
    let x = vpm_c_binary_with(l, OP_ADD, can_iv);
    if x < 0 || x != vph.vfxuf { return false; }
    var vtc = vp_scev_for_value(vph.vtc, pse, -1);
    if sc_is_cnc(vtc) { vtc = vp_scev_for_value(vph.trip_count, pse, -1); }
    let c = sc_get_constant_ty(sc_ty(vtc), (vf * uf) as u64, false);
    return sc_is_known_predicate(32, vtc, c);
}
// simplifyBranchConditionForVFAndUF
fn vpx_simplify_branch_condition_for_vf_and_uf(vf: i64, uf: i64, pse: i32) -> bool {
    let region = vp_vector_loop_region();
    let exiting = vp_exiting_basic_block(region);
    let term = vpb[exiting].last;
    fn is_can_iv_inc(v: i32) -> bool { let ok, a, b = vpm_binary(v, OP_ADD); ok && b == vph.vfxuf }
    var matched_count = false;
    if vpm_vpi_r(term, VPI_BRANCH_ON_COUNT, 2) {
        let civ = vp_op(term, 0);
        if is_can_iv_inc(civ) { matched_count = true; }
        else {
            let ok, a, b = vpm_binary(civ, OP_ADD);
            if ok && ((is_can_iv_inc(a) && vp_is_ir_value(b)) || (is_can_iv_inc(b) && vp_is_ir_value(a))) { matched_count = true; }
        }
    }
    let okb = vpm_vpi_r(term, VPI_BRANCH_ON_COND, 1);
    var alm_not = false;
    if okb {
        let nd = vp_def(vp_op(term, 0));
        if vpm_vpi_r(nd, VPI_NOT, 1) && vp_val_is_vpi(vp_op(nd, 0), VPI_ACTIVE_LANE_MASK) { alm_not = true; }
    }
    if matched_count || alm_not {
        var vtc = vp_scev_for_value(vph.vtc, pse, -1);
        if sc_is_cnc(vtc) { vtc = vp_scev_for_value(vph.trip_count, pse, -1); }
        let c = sc_get_constant_ty(sc_ty(vtc), (vf * uf) as u64, false);
        if !sc_is_known_predicate(37, vtc, c) { return false; }
    } else if okb {
        if !vpx_is_condition_true_via_vf_and_uf(vp_op(term, 0), vf, uf, pse) { return false; }
    } else if vpm_vpi_r(term, VPI_BRANCH_ON_TWO_CONDS, 2) {
        if !vpx_is_condition_true_via_vf_and_uf(vp_op(term, 1), vf, uf, pse) { return false; }
    } else { return false; }
    if vpm_vpi_r(term, VPI_BRANCH_ON_TWO_CONDS, 2) { vp_set_operand(term, 1, vp_true()); return true; }
    let boc = vp_new_instruction(VPI_BRANCH_ON_COND, [vp_true()], vpf_none(), vpr[term].dl, "", -1);
    vp_append_recipe(exiting, boc);
    vp_erase_recipe(term);
    return true;
}
// optimizeForVFAndUF
fn vpx_optimize_for_vf_and_uf(vf: i64, uf: i64, pse: i32) {
    var phis: i32[>..<] = [];
    vp_block_phis(vp_entry_basic_block(vp_vector_loop_region()), phis);
    for p in phis {
        if vpr[p].kind == VPR_ACTIVE_LANE_MASK_PHI { vp_unported("active lane masks"); }
        if vp_is_canonical_widen_iv(p) && vp_is_constant_int(vph.trip_count) { vp_unported("optimizeVectorInductionWidthForTCAndVFUF"); }
    }
    let changed = vpx_simplify_branch_condition_for_vf_and_uf(vf, uf, pse);
    if changed { vp_set_vf(vf); }
}

// convertToConcreteRecipes
fn vpx_widen_phi(incoming: const i32[:], dl: i32, name: const u8[:]) -> i32 {
    let r = vp_new_single_def(VPR_WIDEN_PHI, incoming, vp_scalar_type(incoming[0]), -1, dl);
    vpr[r].name = intern(name);
    return vpb_insert(r);
}
fn vpx_widen_cast(o: i64, v: i32, ty: i32) -> i32 {
    let r = vp_new_single_def(VPR_WIDEN_CAST, [v], ty, -1, -1);
    vpr[r].opcode = o as i32;
    vpr[r].f = vp_default_flags(o as i32, ty);
    return vpb_insert(r);
}
// expandVPWidenIntOrFpInduction
fn vpx_expand_widen_int_or_fp_induction(w: i32) {
    var start = vp_op(w, 0);
    var step = vp_op(w, 1);
    let vfv = vp_op(w, 2);
    let dl = vpr[w].dl;
    let ty = vpv[vpr[w].def].ty;
    let d = vpr[w].ind;
    let f = vpr[w].f;
    var add_op = OP_ADD;
    var mul_op = OP_MUL;
    if ind_descs[d].kind != IK_INT { add_op = ind_opcode(d); mul_op = OP_FMUL; }
    vpb_set_at_end(vp_vector_preheader());
    var step_ty = vp_scalar_type(step);
    if ty_bits(ty_scalar(ty)) < ty_bits(ty_scalar(step_ty)) {
        step = vp_val(vpb_scalar_cast(OP_TRUNC, step, ty, dl, vpf_none()));
        start = vp_val(vpb_scalar_cast(OP_TRUNC, start, ty, dl, vpf_none()));
        step_ty = ty;
    }
    let iv_int_ty = ty_int(ty_bits(ty_scalar(step_ty)));
    var init = vp_val(vpb_nary(VPI_STEP_VECTOR, [], vpf_none(), -1, "", iv_int_ty));
    if ty_is_fp(step_ty) { init = vp_val(vpx_widen_cast(OP_UITOFP, init, step_ty)); }
    let splat_start = vp_val(vpb_nary(VPI_BROADCAST, [start], vpf_none(), -1, "", -1));
    let splat_step = vp_val(vpb_nary(VPI_BROADCAST, [step], vpf_none(), -1, "", -1));
    init = vp_val(vpb_nary(mul_op as i32, [init, splat_step], f, -1, "", -1));
    init = vp_val(vpb_nary(add_op as i32, [splat_start, init], f, -1, "induction", -1));
    vpb_set_before(w);
    let wide_phi = vpx_widen_phi([init], dl, "vec.ind");
    var inc: i32 = -1;
    var prev: i32 = -1;
    if vp_nops(w) == 5 {
        inc = vp_op(w, 3);
        prev = vp_op(w, 4);
    } else {
        let vr_ = vp_def(vfv);
        vpb_set_at_end(vp_vector_preheader());
        if vr_ >= 0 && vp_enclosing_loop_region(vpr[vr_].parent) >= 0 { vpb_set_after(vr_); }
        var vf2: i32 = -1;
        if ty_is_fp(step_ty) { vf2 = vp_val(vpb_scalar_cast(OP_UITOFP, vfv, step_ty, dl, vpf_none())); }
        else { vf2 = vpb_scalar_zext_or_trunc(vfv, step_ty, vp_scalar_type(vfv), dl); }
        inc = vp_val(vpb_nary(mul_op as i32, [step, vf2], f, -1, "", -1));
        inc = vp_val(vpb_nary(VPI_BROADCAST, [inc], vpf_none(), -1, "", -1));
        prev = vpr[wide_phi].def;
    }
    let exiting = vp_exiting_basic_block(vp_vector_loop_region());
    vpb_set_before(vp_terminator(exiting));
    let nxt = vpb_nary(add_op as i32, [prev, inc], f, dl, "vec.ind.next", -1);
    vp_add_operand(wide_phi, vpr[nxt].def);
    vp_rauw(vpr[w].def, vpr[wide_phi].def);
}
// expandVPDerivedIV
fn vpx_expand_derived_iv(r: i32) {
    vpb_set_before(r);
    let start = vp_op(r, 0);
    var index = vp_op(r, 1);
    let step = vp_op(r, 2);
    let step_ty = vp_scalar_type(step);
    let index_ty = vp_scalar_type(index);
    if ty_is_int(ty_scalar(step_ty)) { index = vpb_scalar_sext_or_trunc(index, step_ty, index_ty, -1); }
    else { index = vp_val(vpb_scalar_cast(OP_SITOFP, index, step_ty, -1, vpf_none())); }
    let d = vpr[r].def;
    let k = vpr[r].ind_kind as i32;
    if k == IK_INT {
        let m = vpb_nary(OP_MUL as i32, [index, step], vpf_wrap(false, false), -1, "", -1);
        vp_rauw(d, vp_val(vpb_add(start, vp_val(m), -1, "", false, false)));
    } else if k == IK_PTR {
        let m = vpb_nary(OP_MUL as i32, [index, step], vpf_wrap(false, false), -1, "", -1);
        vp_rauw(d, vp_val(vpb_nary(VPI_PTR_ADD, [start, vp_val(m)], vpf_gep(0), -1, "", -1)));
    } else if k == IK_FP {
        let fpb = vpr[r].fp_binop;
        let fmf = insts[inst_of(fpb)].fmf;
        let fm = vpb_nary(OP_FMUL as i32, [step, index], vpf_fmf(fmf), -1, "", -1);
        vp_rauw(d, vp_val(vpb_nary(iop(fpb) as i32, [start, vp_val(fm)], vpf_fmf(fmf), -1, "", -1)));
    }
}
fn vpx_convert_to_concrete_recipes() {
    var bs: i32[>..<] = [];
    vp_all_basic_blocks_deep(bs);
    for bb in bs {
        var rs: i32[>..<] = [];
        vp_block_recipes(bb, rs);
        for r in rs {
            if vpr[r].dead { continue; }
            let k = vpr[r].kind;
            if k == VPR_WIDEN_INT_OR_FP_INDUCTION { vpx_expand_widen_int_or_fp_induction(r); vp_erase_recipe(r); continue; }
            if k == VPR_WIDEN_POINTER_INDUCTION { vp_unported("pointer inductions (convertToConcreteRecipes)"); }
            if k == VPR_DERIVED_IV { vpx_expand_derived_iv(r); vp_erase_recipe(r); continue; }
            if k == VPR_WIDEN_CANONICAL_IV || k == VPR_BLEND || k == VPR_VECTOR_END_POINTER || k == VPR_EXPRESSION {
                vp_unported("widen-canonical-IV / blend / end-pointer / expression recipes (convertToConcreteRecipes)");
            }
            if vp_is_vpi(r, VPI_LAST_ACTIVE_LANE) || vp_is_vpi(r, VPI_MASKED_COND) { vp_unported("last-active-lane / masked-cond"); }
            if vp_is_vpi(r, VPI_CANONICAL_IV_INCREMENT_FOR_PART) {
                vpb_set_before(r);
                let f = vpr[r].f;
                let add = vpb_nary(OP_ADD as i32, [vp_op(r, 0), vp_op(r, 1)], vpf_wrap(f.nuw, f.nsw), vpr[r].dl, "", -1);
                vp_rauw(vpr[r].def, vp_val(add));
                vp_erase_recipe(r);
                continue;
            }
            if vpm_vpi_r(r, VPI_BRANCH_ON_COUNT, 2) {
                vpb_set_before(r);
                let dl = vpr[r].dl;
                let c = vpb_icmp(32, vp_op(r, 0), vp_op(r, 1), dl, "");
                vpb_nary(VPI_BRANCH_ON_COND, [vp_val(c)], vpf_none(), dl, "", -1);
                vp_erase_recipe(r);
                continue;
            }
            if vpm_vpi_r(r, VPI_WIDE_IV_STEP, 2) {
                vpb_set_before(r);
                var vstep = vp_op(r, 0);
                var sstep = vp_op(r, 1);
                let ivty = vpv[vpr[r].def].ty;
                if vp_scalar_type(vstep) != ivty { let wc = vpx_widen_cast(if ty_is_fp(ivty) { OP_UITOFP } else { OP_TRUNC }, vstep, ivty); vstep = vpr[wc].def; }
                if vp_scalar_type(sstep) != ivty { let wc = vpx_widen_cast(OP_TRUNC, sstep, ivty); sstep = vpr[wc].def; }
                var mf = vp_default_flags(OP_MUL as i32, -1);
                var mo = OP_MUL as i32;
                if ty_is_fp(ivty) { mo = OP_FMUL as i32; mf = vpf_fmf(if vpr[r].f.ot == VOT_FMF { vpr[r].f.fmf } else { 0 }); }
                let m = vpb_nary(mo, [vstep, sstep], mf, vpr[r].dl, "", -1);
                vp_rauw(vpr[r].def, vpr[m].def);
                vp_erase_recipe(r);
                continue;
            }
        }
    }
}

// dissolveLoopRegions (VPRegionBlock::dissolveToCFGLoop)
fn vpx_find_canonical_iv_increment(region: i32) -> i32 {
    let can_iv = vpb[region].can_iv;
    var inc: i32 = -1;
    for j in vp_num_users(can_iv) {
        let u = vp_user(can_iv, j);
        if vpr[u].kind != VPR_INSTRUCTION { continue; }
        let step = vpm_c_binary_with(vpr[u].def, OP_ADD, can_iv);
        if step < 0 { continue; }
        var is_step = false;
        if !vpv[vph.vfxuf].materialized { is_step = step == vph.vfxuf; }
        else {
            if !vpv[vph.uf].materialized { is_step = step == vph.uf; }
            else { is_step = vpm_specific_int(step, xv_get(vph.ufs, 0) as u64); }
        }
        if is_step { inc = u; }
    }
    return inc;
}
fn vpx_dissolve_to_cfg_loop(region: i32) {
    let header = vpb[region].entry;
    let latch = vpb[region].exiting;
    let can_iv = vpb[region].can_iv;
    if vp_num_users(can_iv) != 0 {
        let zero = vp_const_int(vpv[can_iv].ty, 0);
        let dl = vpv[can_iv].dl;
        var inc = vpx_find_canonical_iv_increment(region);
        if inc < 0 {
            if vpv[vph.vfxuf].materialized { fatal("internal: VFxUF can be used only before it is materialized"); }
            vpb_set_before(vp_terminator(latch));
            inc = vpb_nary(OP_ADD as i32, [can_iv, vph.vfxuf], vpf_wrap(vpb[region].can_iv_nuw, false), dl, "index.next", -1);
        }
        vpb_set_at(header, vpb[header].first);
        let sc = vpb_scalar_phi([zero, vpr[inc].def], dl, "index", vpf_none(), -1);
        vp_rauw(can_iv, vpr[sc].def);
    }
    let ph = vp_single_pred(region);
    vpbu_disconnect(ph, region);
    var bs: i32[>..<] = [];
    vp_depth_first(vpb[region].entry, false, bs);
    for b in bs { vpb[b].parent = vpb[region].parent; }
    vpbu_connect(ph, header);
    vpbu_transfer_successors(region, latch);
    vpbu_connect(latch, header);
    vpb[region].dead = true;
}
fn vpx_dissolve_loop_regions() {
    var bs: i32[>..<] = [];
    vp_depth_first(vph.entry, true, bs);
    vp_only_regions(bs);
    var regions: i32[>..<] = [];
    for r in bs { if !vp_is_replicator(r) { regions.push(r); } }
    for r in regions { vpx_dissolve_to_cfg_loop(r); }
}

// expandBranchOnTwoConds
fn vpx_expand_branch_on_two_conds() {
    var bs: i32[>..<] = [];
    vp_depth_first(vph.entry, false, bs);
    for b in bs {
        if !vp_is_basic(b) || vp_block_empty(b) { continue; }
        if vpm_vpi_r(vpb[b].last, VPI_BRANCH_ON_TWO_CONDS, 2) { vp_unported("branch-on-two-conds (early exits)"); }
    }
}

// materializeBackedgeTakenCount
fn vpx_materialize_backedge_taken_count(vector_ph: i32) {
    let btc = vp_or_create_backedge_taken_count();
    if vp_num_users(btc) == 0 { return; }
    vpb_set_at(vector_ph, vpb[vector_ph].first);
    let tcty = vp_scalar_type(vph.trip_count);
    let t = vpb_sub(vph.trip_count, vp_const_int(tcty, 1), -1, "trip.count.minus.1", false, false);
    vp_rauw(btc, vp_val(t));
}
// materializeVectorTripCount
fn vpx_materialize_vector_trip_count(vector_ph: i32, tail_by_masking: bool, rse: bool, step: i32) {
    let vtc = vph.vtc;
    if vp_num_users(vtc) == 0 || vpv[vtc].uv >= 0 { return; }
    var tc = vph.trip_count;
    let tcty = vp_scalar_type(tc);
    var ip = vpb[vector_ph].first;
    let sr = vp_def(step);
    if sr >= 0 { ip = vpr[sr].next; }
    vpb_set_at(vector_ph, ip);
    // (no vscale_range: MaxRuntimeStep is std::nullopt on X86 / NoTTI)
    if tail_by_masking { vp_unported("tail folding (n.rnd.up)"); }
    var r = vp_val(vpb_nary(OP_UREM as i32, [tc, step], vpf_none(), -1, "n.mod.vf", -1));
    if rse {
        let z = vpb_icmp(32, r, vp_const_int(tcty, 0), -1, "");
        r = vp_val(vpb_nary(OP_SELECT as i32, [vp_val(z), step, r], vpf_none(), -1, "", -1));
    }
    let res = vpb_sub(tc, r, -1, "n.vec", false, false);
    vp_rauw(vtc, vp_val(res));
}
// materializeFactors
fn vpx_materialize_factors(vector_ph: i32, vf: i64) {
    if vpv[vph.vf].materialized { return; }
    vpb_set_at(vector_ph, vpb[vector_ph].first);
    let tcty = vp_scalar_type(vph.trip_count);
    let uf = xv_get(vph.ufs, 0) as i64;
    if vp_num_users(vph.vf) == 0 {
        vp_rauw(vph.vfxuf, vp_const_int(tcty, (vf * uf) as u64));
        return;
    }
    let rvf = vp_const_int(tcty, vf as u64);
    if !vp_only_scalar_values_used(vph.vf) {
        let bc = vpb_nary(VPI_BROADCAST, [rvf], vpf_none(), -1, "", -1);
        let vfv = vph.vf;
        vp_replace_uses_with_if(vfv, vpr[bc].def) { u, i => !vp_uses_scalars(u, vfv) };
    }
    vp_rauw(vph.vf, rvf);
    let mul = vpb_nary(OP_MUL as i32, [rvf, vp_const_int(tcty, uf as u64)], vpf_wrap(true, false), -1, "", -1);
    vp_rauw(vph.vfxuf, vp_val(mul));
}

// VPSCEVExpander::tryToExpand: a VPValue or -1
var vpsx_dl: i32 = -1;
recursive fn vpsx_try_to_expand(s: i32) -> i32 {
    // tryToReuseIRValue
    if !sc_is_const(s) && !sc_is_unknown(s) {
        var vs: i32[>..<] = [];
        sc_get_scev_values(s, vs);
        let ph = vpb[vph.entry].irbb;
        for v in vs {
            if !is_inst(v) { return vp_live_in(v); }
            if !dt_dominates_block(DT_DOM, inst_parent(v), ph) { continue; }
            var drop: i32[>..<] = [];
            if !sc_can_reuse_instruction(s, v, drop) { continue; }
            for di in drop { sx_drop_poison_annotations_and_reinfer(di); }
            return vp_live_in(v);
        }
    }
    let k = sc_kind(s);
    if k == SC_CONST || k == SC_UNKNOWN { return vp_live_in(sc_value(s)); }
    if k == SC_ADD || k == SC_MUL {
        let nuw = sc_has_nuw(s);
        let nsw = sc_has_nsw(s);
        if ty_kind(sc_ty(s)) == TK_PTR {
            // a ptradd of the pointer base and the integer offset, matching SCEVExpander
            let base = vpsx_try_to_expand(sc_get_pointer_base(s));
            if base < 0 { return -1; }
            let off = vpsx_try_to_expand(sc_remove_pointer_base(s));
            if off < 0 { return -1; }
            return vp_val(vpb_nary(VPI_PTR_ADD, [base, off], vpf_gep(if nuw { GEP_NUW } else { 0 }), vpsx_dl, "", -1));
        }
        let o = if k == SC_ADD { OP_ADD } else { OP_MUL };
        let mark = vpsx_stack.len;
        var j = sc_nops(s) - 1;
        while j >= 0 {
            let ov = vpsx_try_to_expand(sc_op(s, j));
            if ov < 0 { vpsx_stack.resize(mark); return -1; }
            vpsx_stack.push(ov);
            j--;
        }
        var res = vpsx_stack[mark];
        for i in mark + 1..vpsx_stack.len {
            res = vp_val(vpb_nary(o as i32, [res, vpsx_stack[i]], vpf_wrap(nuw, nsw), vpsx_dl, "", -1));
        }
        vpsx_stack.resize(mark);
        return res;
    }
    if k == SC_UDIV {
        let l = vpsx_try_to_expand(sc_op(s, 0));
        if l < 0 { return -1; }
        let r = vpsx_try_to_expand(sc_op(s, 1));
        if r < 0 { return -1; }
        return vp_val(vpb_nary(OP_UDIV as i32, [l, r], vpf_exact(false), vpsx_dl, "", -1));
    }
    if k == SC_TRUNC || k == SC_ZEXT || k == SC_SEXT {
        let o = vpsx_try_to_expand(sc_op(s, 0));
        if o < 0 { return -1; }
        let opc = if k == SC_TRUNC { OP_TRUNC } else if k == SC_ZEXT { OP_ZEXT } else { OP_SEXT };
        return vp_val(vpb_scalar_cast(opc, o, sc_ty(s), vpsx_dl, vp_default_flags(opc as i32, sc_ty(s))));
    }
    if k == SC_UMAX || k == SC_SMAX || k == SC_UMIN || k == SC_SMIN {
        let id = if k == SC_UMAX { IID_umax } else if k == SC_SMAX { IID_smax } else if k == SC_UMIN { IID_umin } else { IID_smin };
        let mark = vpsx_stack.len;
        var j = sc_nops(s) - 1;
        while j >= 0 {
            let ov = vpsx_try_to_expand(sc_op(s, j));
            if ov < 0 { vpsx_stack.resize(mark); return -1; }
            vpsx_stack.push(ov);
            j--;
        }
        var res = vpsx_stack[mark];
        // createScalarIntrinsic: the intrinsic id is a trailing i32 operand
        for i in mark + 1..vpsx_stack.len {
            res = vp_val(vpb_nary(VPI_INTRINSIC, [res, vpsx_stack[i], vp_const_int(T_I32, id as u64)], vpf_none(), vpsx_dl, "", sc_ty(s)));
        }
        vpsx_stack.resize(mark);
        return res;
    }
    return -1;
}
var vpsx_stack: i32[>..<];

// expandSCEVsToVPInstructions
fn vpx_expand_scevs_to_vp_instructions() {
    let entry = vph.entry;
    vpsx_dl = inst_get_md(block_terminator(vpb[entry].irbb), 0);
    var rs: i32[>..<] = [];
    vp_block_recipes(entry, rs);
    for r in rs {
        if vpr[r].kind != VPR_EXPAND_SCEV || vp_num_users(vpr[r].def) == 0 { continue; }
        vpb_set_before(r);
        let e = vpsx_try_to_expand(vpr[r].expr);
        if e < 0 { continue; }
        vp_rauw(vpr[r].def, e);
        if vph.trip_count == vpr[r].def { vph.trip_count = vp_poison(vp_scalar_type(vpr[r].def)); }
        vp_erase_recipe(r);
    }
}

// cse
fn vpx_cse_can_handle(r: i32) -> bool {
    let is_iid, oc = vpt_opcode_or_iid(r);
    if oc < 0 { return false; }
    if !is_iid && (oc == OP_INSERTVALUE as i32 || oc == OP_EXTRACTVALUE as i32 || oc == OP_ALLOCA as i32) { return false; }
    return !vp_may_read_or_write_memory(r);
}
fn vpx_cse_gep_src(r: i32) -> i32 {
    let k = vpr[r].kind;
    if k == VPR_REPLICATE { let ui = vp_underlying_instr(r); if iop(ui) == OP_GEP { return insts[inst_of(ui)].ty2; } return -1; }
    if k == VPR_VECTOR_POINTER || k == VPR_WIDEN_GEP { return vpr[r].src_elt_ty; }
    return -1;
}
fn vpx_cse_is_equal(l: i32, r: i32) -> bool {
    if vpr[l].kind != vpr[r].kind { return false; }
    let i1, o1 = vpt_opcode_or_iid(l);
    let i2, o2 = vpt_opcode_or_iid(r);
    if i1 != i2 || o1 != o2 { return false; }
    if vpx_cse_gep_src(l) != vpx_cse_gep_src(r) { return false; }
    if vp_is_single_scalar(vpr[l].def) != vp_is_single_scalar(vpr[r].def) { return false; }
    if vp_nops(l) != vp_nops(r) { return false; }
    for k in vp_nops(l) { if vp_op(l, k) != vp_op(r, k) { return false; } }
    let ot = vpr[l].f.ot;
    if vp_is_recipe_with_ir_flags(vpr[l].kind) && (ot == VOT_CMP || ot == VOT_FCMP) && vpr[l].f.pred != vpr[r].f.pred { return false; }
    if vpr[l].kind == VPR_SCALAR_IV_STEPS && vpr[l].ind_opcode != vpr[r].ind_opcode { return false; }
    if vpr[l].kind == VPR_WIDEN_PHI && vpr[l].parent != vpr[r].parent { return false; }
    let rl = vp_recipe_region(l);
    let rr = vp_recipe_region(r);
    if ((rl >= 0 && vp_is_replicator(rl)) || (rr >= 0 && vp_is_replicator(rr))) && vpr[l].parent != vpr[r].parent { return false; }
    return vp_scalar_type(vpr[l].def) == vp_scalar_type(vpr[r].def);
}
fn vpx_intersect_flags(a: i32, b: VPF) {
    let ot = vpr[a].f.ot;
    if ot == VOT_OVERFLOWING || ot == VOT_TRUNC { vpr[a].f.nuw = vpr[a].f.nuw && b.nuw; vpr[a].f.nsw = vpr[a].f.nsw && b.nsw; }
    else if ot == VOT_DISJOINT { vpr[a].f.disjoint = vpr[a].f.disjoint && b.disjoint; }
    else if ot == VOT_EXACT { vpr[a].f.exact = vpr[a].f.exact && b.exact; }
    else if ot == VOT_GEP { vpr[a].f.gep = vpr[a].f.gep & b.gep; }
    else if ot == VOT_FMF || ot == VOT_FCMP || ot == VOT_REDUCTION { vpr[a].f.fmf = vpr[a].f.fmf & b.fmf; }
    else if ot == VOT_NNEG { vpr[a].f.nneg = vpr[a].f.nneg && b.nneg; }
}
fn vpx_cse() {
    vp_dt_build();
    var seen: i32[>..<] = [];
    var rpo: i32[>..<] = [];
    vp_rpo(vph.entry, true, rpo);
    vp_only_basic(rpo);
    for bb in rpo {
        var r = vpb[bb].first;
        while r >= 0 {
            let nx = vpr[r].next;
            if vpr[r].def < 0 || !vpx_cse_can_handle(r) { r = nx; continue; }
            var found: i32 = -1;
            for c in seen { if !vpr[c].dead && vpx_cse_is_equal(c, r) { found = c; break; } }
            if found >= 0 {
                if !vp_dt_dominates(vpr[found].parent, bb) { r = nx; continue; }
                if vp_is_recipe_with_ir_flags(vpr[found].kind) { vpx_intersect_flags(found, vpr[r].f); }
                vp_rauw(vpr[r].def, vpr[found].def);
                r = nx;
                continue;
            }
            seen.push(r);
            r = nx;
        }
    }
}

// expandSCEVs: the remaining VPExpandSCEVRecipes become IR in the entry block; new entry instructions get
// VPIRInstructions
fn vpx_expand_scevs(entry_irbb: i32) {
    let entry = vph.entry;
    var rs: i32[>..<] = [];
    vp_block_recipes(entry, rs);
    var started = false;
    for r in rs {
        if vpr[r].kind != VPR_EXPAND_SCEV { continue; }
        if !started { sx_begin("induction", false); started = true; }
        let e = vpr[r].expr;
        let res = sx_expand_code_for_at(e, sc_ty(e), block_terminator(entry_irbb));
        let ex = vp_live_in(res);
        vp_rauw(vpr[r].def, ex);
        if vph.trip_count == vpr[r].def { vph.trip_count = ex; }
        vp_erase_recipe(r);
    }
    if started { sx_end(); }
    var ei = vpb[entry].first;
    let t = block_terminator(entry_irbb);
    var i = block_first(entry_irbb);
    while i >= 0 && i != t {
        if ei >= 0 && vpr[ei].kind == VPR_IR_INSTRUCTION && vpr[ei].ir_inst == i { ei = vpr[ei].next; i = inst_next(i); continue; }
        let n = vp_new_ir_instruction(i);
        vp_insert_recipe(n, entry, ei);
        i = inst_next(i);
    }
}

// addMinimumIterationCheck (into the plan entry)
fn vpx_add_minimum_iteration_check(vf: i64, uf: i64, min_profitable: i64, rse: bool, tail_folded: bool, l: i32, dl: i32, pse: i32, bw: bool) {
    let pred: i64 = if rse { 37 } else { 36 };
    let tcv = vph.trip_count;
    let tc = vp_scev_for_value(tcv, pse, -1);
    let tc_ty = sc_ty(tc);
    let vfxuf = sc_get_constant_ty(tc_ty, (vf * uf) as u64, false);
    var step = vfxuf;
    // max(MinProfitableTripCount, UF * VF): both constants, so the umax folds
    if uf * vf < min_profitable { step = sc_get_constant_ty(tc_ty, min_profitable as u64, false); }
    let check = vph.entry;
    vpb_set_at_end(check);
    var tc_check = vp_false();
    if !tail_folded {
        let tcg = sc_apply_loop_guards(tc, l);
        if sc_is_known_predicate(pred, tcg, step) {
            tc_check = vp_true();
        } else if !sc_is_known_predicate(pred_inverse_lv(pred), tcg, step) {
            vpsx_dl = dl;
            var min_tc = vpsx_try_to_expand(step);
            if min_tc < 0 { vp_unported("min.iters.check with an unexpandable step"); }
            vpb_set_at_end(check);
            tc_check = vp_val(vpb_icmp(pred, tcv, min_tc, dl, "min.iters.check"));
        }
    }
    vpb_set_at_end(check);
    let term = vpb_nary(VPI_BRANCH_ON_COND, [tc_check], vpf_none(), dl, "", -1);
    if bw { vp_unported("branch weights on the minimum iteration check"); }
}
fn pred_inverse_lv(p: i64) -> i64 {
    if p == 32 { return 33; } if p == 33 { return 32; }
    if p == 34 { return 37; } if p == 35 { return 36; } if p == 36 { return 35; } if p == 37 { return 34; }
    if p == 38 { return 41; } if p == 39 { return 40; } if p == 40 { return 39; } if p == 41 { return 38; }
    return p;
}
