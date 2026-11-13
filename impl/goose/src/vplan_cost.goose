// The VPlan-based cost model (LLVM 23.1.5): VPCostContext (getLegacyCost, skipCostComputation, willBeScalarized,
// getOperandInfo, getScalarizationOverhead, useEmulatedMaskMemRefHack), every recipe's computeCost (the
// vpc_compute_cost switch), VPRecipeBase::cost, VPBasicBlock / VPRegionBlock / VPlan::cost (VPlan.cpp,
// VPlanRecipes.cpp), calculateRegisterUsageForPlan (VPlanAnalysis.cpp), and from LoopVectorize.cpp
// LoopVectorizationPlanner::precomputeCosts / cost / computeBestVF / isMoreProfitable / selectInterleaveCount,
// willGenerateVectors, collectEphemeralRecipesForVPlan, addFullyUnrolledInstructionsToIgnore and
// isOutsideLoopWorkProfitable (without runtime checks).
// Costs are lc values (lv_cost.goose).
import std;
import ir;
import irutil;
import instinfo;
import calls;
import flags;
import gen_iids;
import gen_x86target;
import pm;
import intrinsics;
import apint;
import loopinfo;
import scev;
import scev_create;
import scev_eval;
import pse;
import laa;
import tti;
import tti_x86;
import tti_vec;
import tti_x86_vec;
import tti_x86_intr;
import iv_descriptors;
import lv_legality;
import lv_interleave;
import lv_cm;
import lv_cost;
import vplan;
import vplan_utils;
import vplan_props;
import vplan_transforms;
import lv_plan;

// ---------------------------------------------------------------------------------------------
// VPCostContext

var vpc_skip = hm_new();          // SkipCostComputation
var vpc_num_pred_stores: i64 = -1;

fn vpc_reset() { hm_clear(vpc_skip); vpc_num_pred_stores = -1; }
// getLegacyCost(UI, VF)
fn vpc_legacy_cost(ui: i32, vf: i64) -> i64 {
    let c = cm_instruction_cost(ui, vf);
    if lc_valid(c) && lv_has_forced_cost() { return lv_forced_cost(); }
    return c;
}
// skipCostComputation(UI, IsVector)
fn vpc_skip_cost(ui: i32, is_vector: bool) -> bool {
    return hm_has(cm_vals_to_ignore, ui as u64) || (is_vector && hm_has(cm_vec_vals_to_ignore, ui as u64)) || hm_has(vpc_skip, ui as u64);
}
// getOperandInfo(V)
fn vpc_operand_info(v: i32) -> i64 { if v >= 0 && vp_is_ir_value(v) { tti_operand_info(vp_ir(v)) } else { 0 } }
// isFreeScalarIntrinsic
fn vpc_is_free_scalar_intrinsic(id: i32) -> bool {
    return id == IID_assume || id == IID_lifetime_end || id == IID_lifetime_start || id == IID_sideeffect ||
           id == IID_pseudoprobe || id == IID_experimental_noalias_scope_decl;
}
// getScalarizationOverhead(ResultTy, Operands, VF, VIC, AlwaysIncludeReplicatingR)
fn vpc_scalarization_overhead(result_ty: i32, ops: const i32[:], vf: i64, always_rep: bool) -> i64 {
    if vf == 1 { return 0; }
    var c: i64 = 0;
    if result_ty != T_VOID { c = lc_add(c, lt_scalarization_all(lv_vec_ty(result_ty, vf), true, false)); }
    var seen: i32[>..<] = [];
    var tys: i32[>..<] = [];
    for o in ops {
        if vp_is_ir_value(o) { continue; }
        let d = vp_def(o);
        let is_rep = d >= 0 && vpr[d].kind == VPR_REPLICATE;
        if !always_rep && d >= 0 && (is_rep || vpr[d].kind == VPR_PRED_INST_PHI) { continue; }
        if is_rep && iop(vp_underlying_instr(d)) == OP_LOAD { continue; }
        var dup = false;
        for s in seen { if s == o { dup = true; } }
        if dup { continue; }
        seen.push(o);
        tys.push(lv_vec_ty(vp_scalar_type(o), vf));
    }
    return lc_add(c, lt_operands_scalarization(tys));
}
// useEmulatedMaskMemRefHack(R, VF)
fn vpc_use_emulated_mask_mem_ref_hack(r: i32, vf: i64) -> bool {
    let ui = vp_underlying_instr(r);
    if iop(ui) == OP_LOAD { return true; }
    if vpc_num_pred_stores < 0 {
        vpc_num_pred_stores = 0;
        var regs: i32[>..<] = [];
        vp_depth_first(vpb[vp_vector_loop_region()].entry, false, regs);
        vp_only_regions(regs);
        for reg in regs {
            var bbs: i32[>..<] = [];
            vp_depth_first(vpb[reg].entry, false, bbs);
            vp_only_basic(bbs);
            for bb in bbs {
                var rr = vpb[bb].first;
                while rr >= 0 {
                    if vpr[rr].kind == VPR_REPLICATE && iop(vp_underlying_instr(rr)) == OP_STORE {
                        let vty = ty_vector(vp_scalar_type(vp_op(rr, 0)), vf, false);
                        if !lt_is_legal_masked_scatter(vty) { vpc_num_pred_stores++; }
                    }
                    rr = vpr[rr].next;
                }
            }
        }
    }
    return vpc_num_pred_stores > flag_int("vectorize-num-stores-pred", 1);
}

// ---------------------------------------------------------------------------------------------
// recipe costs

// the underlying instruction VPRecipeBase::cost keys the recipe by (-1: none)
fn vpc_recipe_instr(r: i32) -> i32 {
    let k = vpr[r].kind;
    if k == VPR_INTERLEAVE || k == VPR_INTERLEAVE_EVL { return vpr[r].ir_inst; }
    if vpr[r].def >= 0 {
        let u = vpv[vpr[r].def].uv;
        return if u >= 0 && is_inst(u) { u } else { -1 };
    }
    if vp_is_widen_memory_kind(k) { return vpr[r].ir_inst; }
    return -1;
}

// VPRecipeBase::cost(VF, Ctx)
fn vpc_recipe_cost(r: i32, vf: i64) -> i64 {
    let ui = vpc_recipe_instr(r);
    var c: i64 = 0;
    if ui >= 0 && vpc_skip_cost(ui, vf > 1) {
        c = 0;
    } else {
        c = vpc_compute_cost(r, vf);
        if lv_has_forced_cost() && lc_valid(c) { c = if ui >= 0 { lv_forced_cost() } else { 0 }; }
    }
    if lv_dbg_on() {
        var s: u8[>..] = [];
        s.append(": recipe kind ");
        format(s, vpr[r].kind as i64);
        s.append(" opcode ");
        format(s, vpr[r].opcode as i64);
        if ui >= 0 { lv_dbg_inst_name(ui, s); }
        lv_dbg_cost("Cost of ", c, vf, s);
    }
    return c;
}

// the predicate a m_Cmp sees on V (-1: no compare recipe)
fn vpc_cmp_pred(v: i32) -> i64 {
    let r = vp_def(v);
    let o = vpm_opcode(r, false);
    if (o == OP_ICMP as i32 || o == OP_FCMP as i32) && vpm_arity_ok(r, 2) { return vpr[r].f.pred as i64; }
    return -1;
}
fn vpc_ctx_inst(r: i32) -> i32 {
    if vpr[r].def < 0 { return -1; }
    let u = vpv[vpr[r].def].uv;
    return if u >= 0 && is_inst(u) { u } else { -1 };
}

// VPRecipeWithIRFlags::getCostForRecipeWithOpcode(Opcode, VF, Ctx)
fn vpc_cost_for_recipe_with_opcode(r: i32, o: i64, vf: i64) -> i64 {
    let sty = vp_scalar_type(vpr[r].def);
    let rty = if vf > 1 { lv_vec_ty(sty, vf) } else { sty };
    let cxt = vpc_ctx_inst(r);
    if o == OP_FNEG { return lt_arith0(OP_FNEG, rty); }
    if o == OP_UDIV || o == OP_SDIV || o == OP_SREM || o == OP_UREM || o == OP_ADD || o == OP_FADD || o == OP_SUB ||
       o == OP_FSUB || o == OP_MUL || o == OP_FMUL || o == OP_FDIV || o == OP_FREM || o == OP_SHL || o == OP_LSHR ||
       o == OP_ASHR || o == OP_AND || o == OP_OR || o == OP_XOR {
        let rhs = vp_op(r, 1);
        var ri = vpc_operand_info(rhs);
        if ri / 4 == OK_ANY && vp_is_defined_outside_loop_regions(rhs) { ri = OK_UNIFORM * 4 + ri % 4; }
        let a0 = if cxt >= 0 { op(cxt, 0) } else { -1 };
        let a1 = if cxt >= 0 && nops(cxt) > 1 { op(cxt, 1) } else { -1 };
        let na = if cxt >= 0 { nops(cxt) } else { 0 };
        return lt_arith(o, rty, 0, ri, a0, a1, na, cxt);
    }
    if o == OP_FREEZE { return 0; }
    if o == OP_EXTRACTVALUE { return lcv(tti_insert_extract_value_cost(OP_EXTRACTVALUE, LV_KIND)); }
    if o == OP_ICMP || o == OP_FCMP {
        let sop = vp_scalar_type(vp_op(r, 0));
        let oty = if vf > 1 { lv_vec_ty(sop, vf) } else { sop };
        return lt_cmpsel(o, oty, lvc_cmp_result_type(oty), vpr[r].f.pred as i64, 0, 0, cxt);
    }
    if o == OP_BITCAST && ty_kind(sty) == TK_PTR { return 0; }
    if o == OP_BITCAST || o == OP_SEXT || o == OP_ZEXT || o == OP_FPTOUI || o == OP_FPTOSI || o == OP_FPEXT ||
       o == OP_PTRTOINT || o == OP_PTRTOADDR || o == OP_INTTOPTR || o == OP_SITOFP || o == OP_UITOFP || o == OP_TRUNC ||
       o == OP_FPTRUNC || o == OP_ADDRSPACECAST {
        return vpc_cast_cost(r, o, vf, rty, cxt);
    }
    if o == OP_SELECT { return vpc_select_cost(r, vf, rty); }
    fatal("internal: loop-vectorize: getCostForRecipeWithOpcode called for an unsupported opcode");
    return LC_INVALID;
}

// the CastContextHint of a recipe that may access memory
fn vpc_compute_cch(rr: i32, vf: i64) -> i64 {
    let k = vpr[rr].kind;
    if k == VPR_INTERLEAVE || k == VPR_INTERLEAVE_EVL { return 4; }
    if k == VPR_REPLICATE {
        let ui = vp_underlying_instr(rr);
        if iop(ui) != OP_LOAD && iop(ui) != OP_STORE { return 0; }
        return if vpr[rr].predicated { 2 } else { 1 };
    }
    if !vp_is_widen_memory_kind(k) { return 0; }
    if vf == 1 { return 1; }
    if !vpr[rr].consecutive { return 3; }
    if vpr[rr].masked { return 2; }
    return 1;
}
// m_Reverse(X) | m_Intrinsic<experimental_vp_reverse>(X): X or -1
fn vpc_reverse_of(rr: i32) -> bool, i32 {
    if vpm_vpi_r(rr, VPI_REVERSE, 1) { return true, vp_op(rr, 0); }
    if vpr[rr].kind == VPR_WIDEN_INTRINSIC && vpr[rr].iid == IID_experimental_vp_reverse { return true, vp_op(rr, 0); }
    return false, -1;
}
fn vpc_cast_cost(r: i32, o: i64, vf: i64, rty: i32, cxt: i32) -> i64 {
    let operand = vp_op(r, 0);
    var cch: i64 = 0;
    var is_rev = false;
    if o == OP_TRUNC || o == OP_FPTRUNC {
        var rr = vp_single_user(vpr[r].def);
        if rr >= 0 {
            let rev, x = vpc_reverse_of(rr);
            if rev {
                is_rev = true;
                let d = vpr[rr].def;
                rr = if d >= 0 { vp_single_user(d) } else { -1 };
            }
            if rr >= 0 { cch = vpc_compute_cch(rr, vf); }
        }
    } else if o == OP_ZEXT || o == OP_SEXT || o == OP_FPEXT {
        var rr = vp_def(operand);
        if rr >= 0 {
            let rev, x = vpc_reverse_of(rr);
            if rev { rr = vp_def(x); is_rev = true; }
            if rr >= 0 { cch = vpc_compute_cch(rr, vf); }
        }
    }
    if is_rev && cch != 0 { cch = 5; }
    let ssrc = vp_scalar_type(operand);
    let src = if vf > 1 { lv_vec_ty(ssrc, vf) } else { ssrc };
    return lt_cast(o, rty, src, cch, cxt);
}
fn vpc_select_cost(r: i32, vf: i64, rty: i32) -> i64 {
    let cxt = vpc_ctx_inst(r);
    let si = if cxt >= 0 && iop(cxt) == OP_SELECT { cxt } else { -1 };
    let s0 = vp_op(r, 0);
    let s1 = vp_op(r, 1);
    let s2 = vp_op(r, 2);
    let is_scalar_cond = vp_is_defined_outside_loop_regions(s0);
    let sty = vp_scalar_type(vpr[r].def);
    // m_c_LogicalAnd / m_c_LogicalOr and the inverted forms; the operand bindings end as (op 0, op 1)
    let is_and = vpm_false(s2) || vpm_false(s1);
    let is_or = vpm_true(s1) || vpm_true(s2);
    if !is_scalar_cond && ty_bits(ty_scalar(sty)) == 1 && (is_and || is_or) {
        var all = true;
        for k in vp_nops(r) { if vp_uv(vp_op(r, k)) < 0 { all = false; } }
        let use_ops = si >= 0 && all;
        let a0 = if use_ops { op(si, 0) } else { -1 };
        let a1 = if use_ops { op(si, 1) } else { -1 };
        return lt_arith(if is_or { OP_OR } else { OP_AND }, rty, vpc_operand_info(s0), vpc_operand_info(s1), a0, a1,
                        if use_ops { 3 } else { 0 }, si);
    }
    var cty = vp_scalar_type(s0);
    if !is_scalar_cond && vf > 1 { cty = ty_vector(cty, vf, false); }
    var pred = vpc_cmp_pred(s0);
    if pred < 0 && vp_is_ir_value(s0) {
        let x = vp_ir(s0);
        if is_inst(x) && (iop(x) == OP_ICMP || iop(x) == OP_FCMP) { pred = inst_pred(x); }
    }
    return lt_cmpsel(OP_SELECT, lv_vec_ty(sty, vf), cty, pred, 0, 0, si);
}

// the `computeCost` virtual
fn vpc_compute_cost(r: i32, vf: i64) -> i64 {
    let k = vpr[r].kind;
    if k == VPR_INSTRUCTION {
        if vp_is_instruction_with_type(r) { return vpc_instruction_with_type_cost(r, vf); }
        return vpc_instruction_cost(r, vf);
    }
    if k == VPR_IR_INSTRUCTION { return 0; }
    if k == VPR_WIDEN || k == VPR_WIDEN_CAST { return vpc_cost_for_recipe_with_opcode(r, vpr[r].opcode as i64, vf); }
    if k == VPR_WIDEN_GEP || k == VPR_VECTOR_END_POINTER || k == VPR_VECTOR_POINTER || k == VPR_PRED_INST_PHI ||
       k == VPR_EXPAND_SCEV || k == VPR_CURRENT_ITERATION_PHI || k == VPR_WIDEN_CANONICAL_IV || k == VPR_BRANCH_ON_MASK {
        return 0;
    }
    if k == VPR_WIDEN_INT_OR_FP_INDUCTION || k == VPR_WIDEN_POINTER_INDUCTION || k == VPR_REDUCTION_PHI ||
       k == VPR_ACTIVE_LANE_MASK_PHI || k == VPR_WIDEN_PHI {
        return lt_cf(OP_PHI);
    }
    if k == VPR_FIRST_ORDER_RECURRENCE_PHI { return if vf == 1 { lt_cf(OP_PHI) } else { 0 }; }
    if k == VPR_DERIVED_IV { return vpc_derived_iv_cost(r, vf); }
    if k == VPR_SCALAR_IV_STEPS { return vpc_scalar_iv_steps_cost(r, vf); }
    if k == VPR_BLEND {
        let bvf = if vp_only_first_lane_used(vpr[r].def) { 1 } else { vf };
        let rt = lv_vec_ty(vp_scalar_type(vpr[r].def), bvf);
        let ct = lv_vec_ty(T_I1, bvf);
        let n = vp_nops(r);
        let nin = if n % 2 == 1 { (n + 1) / 2 } else { n / 2 };
        return lc_mul(lt_cmpsel(OP_SELECT, rt, ct, -1, 0, 0, -1), nin - 1);
    }
    if k == VPR_REPLICATE { return vpc_replicate_cost(r, vf); }
    if k == VPR_WIDEN_LOAD || k == VPR_WIDEN_STORE { return vpc_widen_memory_cost(r, vf); }
    if k == VPR_WIDEN_INTRINSIC { return vpc_widen_intrinsic_cost(r, vf); }
    if k == VPR_WIDEN_MEM_INTRINSIC {
        let ty = lv_vec_ty(vp_scalar_type(vpr[r].def), vf);
        return lt_mem_intrinsic(vpr[r].iid, ty, -1, !vpm_true(vp_op(r, 2)), vpr[r].align, 0);
    }
    if k == VPR_WIDEN_CALL { return lt_call(); }
    if k == VPR_REDUCTION { vp_unported("VPReductionRecipe::computeCost"); }
    if k == VPR_INTERLEAVE { vp_unported("VPInterleaveRecipe::computeCost"); }
    if k == VPR_EXPRESSION { vp_unported("VPExpressionRecipe::computeCost"); }
    if k == VPR_HISTOGRAM { vp_unported("VPHistogramRecipe::computeCost"); }
    vp_unported("the cost of an EVL recipe");
    return LC_INVALID;
}

// VPInstruction::computeCost
fn vpc_instruction_cost(r: i32, vf: i64) -> i64 {
    let o = vpr[r].opcode;
    let first_lane = vp_only_first_lane_used(vpr[r].def);
    if vpi_is_ir_opcode(o) && vp_opcode_is_binary(o) {
        if vp_uv(vpr[r].def) < 0 && o != OP_FMUL as i32 { return 0; }
        return vpc_cost_for_recipe_with_opcode(r, o as i64, if first_lane { 1 } else { vf });
    }
    if o == OP_SELECT as i32 {
        var pred = vpc_cmp_pred(vp_op(r, 0));
        var cty = vp_scalar_type(vp_op(r, 0));
        var vty = vp_scalar_type(vp_op(r, 1));
        if !first_lane { cty = lv_vec_ty(cty, vf); vty = lv_vec_ty(vty, vf); }
        return lt_cmpsel(OP_SELECT, vty, cty, pred, 0, 0, -1);
    }
    if o == OP_EXTRACTELEMENT as i32 || o == VPI_EXTRACT_LANE {
        if vf == 1 { return 0; }
        return lt_vec_inst(OP_EXTRACTELEMENT, lv_vec_ty(vp_scalar_type(vp_op(r, 0)), vf), -1);
    }
    if o == VPI_ANY_OF {
        let vty = lv_vec_ty(vp_scalar_type(vpr[r].def), vf);
        return lcv(tv_arith_reduction(OP_OR, vty, false, LV_KIND));
    }
    if o == VPI_FIRST_ACTIVE_LANE || o == VPI_LAST_ACTIVE_LANE {
        let sty = vp_scalar_type(vp_op(r, 0));
        if vf == 1 { return lt_cmpsel(OP_ICMP, sty, lvc_cmp_result_type(sty), 32, 0, 0, -1); }
        let pty = lv_vec_ty(sty, vf);
        let rty = vp_scalar_type(vpr[r].def);
        var c = lt_intrinsic_types(IID_experimental_cttz_elts, rty, [pty, T_I1], 0);
        if o == VPI_LAST_ACTIVE_LANE {
            c = lc_add(c, lt_arith(OP_XOR, pty, 0, OK_UNIFORM_CONST * 4, -1, -1, 0, -1));
            c = lc_add(c, lt_arith0(OP_SUB, rty));
        }
        return c;
    }
    if o == VPI_EXTRACT_LAST_ACTIVE {
        let sty = vp_scalar_type(vpr[r].def);
        return lt_intrinsic_types(IID_experimental_vector_extract_last_active, sty, [lv_vec_ty(sty, vf), lv_vec_ty(T_I1, vf), sty], 0);
    }
    if o == VPI_FIRST_ORDER_RECURRENCE_SPLICE { return lt_shuffle(SK_SPLICE, lv_vec_ty(vp_scalar_type(vpr[r].def), vf), -1); }
    if o == VPI_ACTIVE_LANE_MASK { vp_unported("active-lane-mask costs"); }
    if o == VPI_EXPLICIT_VECTOR_LENGTH { vp_unported("EVL costs"); }
    if o == VPI_REVERSE {
        let et = vp_scalar_type(vpr[r].def);
        if ty_is_int(et) && ty_bits(et) == 1 { return 0; }
        return lt_shuffle(SK_REVERSE, lv_vec_ty(et, vf), 0);
    }
    if o == VPI_EXTRACT_LAST_LANE { return lt_vec_inst_from_end(OP_EXTRACTELEMENT, lv_vec_ty(vp_scalar_type(vp_op(r, 0)), vf), 0); }
    if o == VPI_NOT {
        var vt = vp_scalar_type(vpr[r].def);
        let u = vp_single_user(vpr[r].def);
        if u >= 0 && vpm_vpi_r(u, VPI_BRANCH_ON_COND, 1) { return 0; }
        if !first_lane { vt = lv_vec_ty(vt, vf); }
        return lt_arith0(OP_XOR, vt);
    }
    if o == VPI_BRANCH_ON_COUNT {
        let tc = if vph.trip_count >= 0 { vp_uv(vph.trip_count) } else { -1 };
        if tc >= 0 && vals[tc].kind == VK_CINT && ap_ule_u64_lv(ci_ap(tc), vf as u64) { return 0; }
        let vt = vp_scalar_type(vp_op(r, 0));
        return lt_cmpsel(OP_ICMP, vt, lvc_cmp_result_type(vt), 32, 0, 0, -1);
    }
    if o == OP_FCMP as i32 || o == OP_ICMP as i32 { return vpc_cost_for_recipe_with_opcode(r, o as i64, if first_lane { 1 } else { vf }); }
    return 0;
}
fn ap_ule_u64_lv(a: AP, x: u64) -> bool { ap_active_bits(a) <= 64 && ap_zext64(a) <= x }

// VPInstructionWithType::computeCost
fn vpc_instruction_with_type_cost(r: i32, vf: i64) -> i64 {
    let o = vpr[r].opcode;
    if vp_opcode_is_cast(o) { return vpc_cost_for_recipe_with_opcode(r, o as i64, 1); }
    if o == VPI_STEP_VECTOR { return 0; }
    if o == VPI_INTRINSIC {
        var tys: i32[>..<] = [];
        for k in vp_nops(r) - 1 { tys.push(vp_scalar_type(vp_op(r, k))); }
        return lt_intrinsic_types(vp_intrinsic_id(r), vp_scalar_type(vpr[r].def), tys, 0);
    }
    fatal("internal: loop-vectorize: VPInstructionWithType::computeCost: unhandled opcode");
    return LC_INVALID;
}

// VPDerivedIVRecipe::computeCost
fn vpc_derived_iv_cost(r: i32, vf: i64) -> i64 {
    if vpr[r].ind_kind as i32 != IK_INT { return 0; }
    if !vp_only_first_lane_used(vpr[r].def) { return 0; }
    let start = vp_op(r, 0);
    let index = vp_op(r, 1);
    let step = vp_op(r, 2);
    var needs_mul = true;
    var needs_add = true;
    var needs_shl = false;
    if vp_is_constant_int(start) { needs_add = !vp_is_const_int_zero(start); }
    let sty = vp_scalar_type(step);
    var c: i64 = 0;
    if vp_is_constant_int(step) {
        let a = ci_ap(vp_ir(step));
        if ap_is_one(a) { needs_mul = false; }
        else if ap_is_all_ones(a) { needs_mul = false; needs_add = true; }
        else if ap_is_pow2(a) { needs_mul = false; needs_shl = true; }
    }
    let ity = vp_scalar_type(index);
    let sts = ty_bits(ty_scalar(sty));
    let its = ty_bits(ty_scalar(ity));
    if (needs_add || needs_mul || needs_shl) && sts != its {
        c = lc_add(c, lt_cast(if sts < its { OP_TRUNC } else { OP_SEXT }, sty, ity, 0, -1));
    }
    if needs_mul { c = lc_add(c, lt_arith0(OP_MUL, sty)); }
    if needs_shl { c = lc_add(c, lt_arith(OP_SHL, sty, 0, OK_UNIFORM_CONST * 4, -1, -1, 0, -1)); }
    if needs_add { c = lc_add(c, lt_arith0(OP_ADD, sty)); }
    return c;
}
// VPScalarIVStepsRecipe::computeCost
fn vpc_scalar_iv_steps_cost(r: i32, vf: i64) -> i64 {
    let bt = vp_scalar_type(vp_op(r, 0));
    if !ty_is_int(bt) { return 0; }
    let reg = vp_recipe_region(r);
    if reg >= 0 && vp_is_replicator(reg) { return 0; }
    if vp_only_first_lane_used(vpr[r].def) { return 0; }
    return lt_arith0(OP_ADD, bt);
}

// VPReplicateRecipe::computeCallCost
fn vpc_replicate_call_cost(called: i32, rty: i32, args: const i32[:], single: bool, vf: i64) -> i64 {
    var tys: i32[>..<] = [];
    for a in args { tys.push(vp_scalar_type(a)); }
    let id = if called >= 0 && vals[called].kind == VK_FUNC { fn_intrinsic_id_lv(called) } else { 0 };
    if id != 0 && vpc_is_free_scalar_intrinsic(id) { return 0; }
    let scall = lt_call();
    if single {
        let ic = if id != 0 { lt_intrinsic_types(id, rty, tys, 0) } else { LC_INVALID };
        return lc_min(scall, ic);
    }
    return lc_add(lc_mul(scall, vf), vpc_scalarization_overhead(rty, args, vf, false));
}
fn fn_intrinsic_id_lv(f: i32) -> i32 { func_iid(f) as i32 }

// getAddressAccessSCEV (the VPlan version): -1 = nullptr, -2 = SCEVCouldNotCompute
fn vpc_address_access_scev(ptr: i32) -> i32 {
    let a = vp_scev_for_value(ptr, lvp_pse, lvp_l);
    if sc_is_cnc(a) { return -2; }
    return if lv_is_address_scev_for_cost(a, lvp_l) { a } else { -1 };
}

// VPReplicateRecipe::computeCost
fn vpc_replicate_cost(r: i32, vf: i64) -> i64 {
    let ui = vp_underlying_instr(r);
    hm_put(vpc_skip, ui as u64, 1);
    let single = vpr[r].single_scalar;
    let o = iop(ui);
    let n = if single { 1 } else { vf };
    if o == OP_ALLOCA { return lt_arith0(OP_MUL, vp_scalar_type(vpr[r].def)); }
    if o == OP_GEP { return 0; }
    if o == OP_CALL {
        let nn = vp_nops(r);
        var args: i32[>..<] = [];
        for k in nn - 1 { args.push(vp_op(r, k)); }
        let callee = vp_ir(vp_op(r, nn - 1));
        return vpc_replicate_call_cost(callee, vp_scalar_type(vpr[r].def), args, single, vf);
    }
    if o == OP_ADD || o == OP_SUB || o == OP_FADD || o == OP_FSUB || o == OP_MUL || o == OP_FMUL || o == OP_FDIV ||
       o == OP_FREM || o == OP_SHL || o == OP_LSHR || o == OP_ASHR || o == OP_AND || o == OP_OR || o == OP_XOR ||
       o == OP_ICMP || o == OP_FCMP {
        return lc_mul(vpc_cost_for_recipe_with_opcode(r, o, 1), n);
    }
    var ops: i32[>..<] = [];
    xv_to(vpr[r].ops, ops);
    if o == OP_SDIV || o == OP_UDIV || o == OP_SREM || o == OP_UREM {
        var sc = vpc_cost_for_recipe_with_opcode(r, o, 1);
        if single { return sc; }
        var fallback = false;
        for x in ops {
            let d = vp_def(x);
            if d < 0 || vpr[d].kind != VPR_PRED_INST_PHI { continue; }
            let u = vp_uv(vp_op(d, 0));
            if u >= 0 && is_inst(u) && vpc_skip_cost(u, vf > 1) { fallback = true; }
        }
        if !fallback {
            sc = lc_add(lc_mul(sc, vf), vpc_scalarization_overhead(vp_scalar_type(vpr[r].def), ops, vf, false));
            if !vp_is_replicator(vp_recipe_region(r)) { return sc; }
            sc = lc_add(sc, lc_mul(lt_cf(OP_PHI), vf));
            return lc_div(sc, cm_pred_block_cost_divisor(inst_parent(ui)));
        }
        return vpc_legacy_cost(ui, vf);
    }
    if o == OP_LOAD || o == OP_STORE {
        let is_load = o == OP_LOAD;
        let ptr_op = vp_op(r, if is_load { 0 } else { 1 });
        let ps = vpc_address_access_scev(ptr_op);
        if ps == -2 { return vpc_legacy_cost(ui, vf); }
        let vt = if is_load { vp_scalar_type(vpr[r].def) } else { vp_scalar_type(vp_op(r, 0)) };
        let spty = vp_scalar_type(ptr_op);
        let align = cm_ld_align(ui);
        let as_ = lv_ptr_as(spty);
        let oi = tti_operand_info(op(ui, 0));
        let pva = lt_prefers_vectorized_addressing();
        let used_by_addr = !pva && vp_is_used_by_load_store_address(vpr[r].def);
        let mem = lt_mem(o, vt, align, as_, oi, if used_by_addr { ui } else { -1 });
        let pty = if single { spty } else { lv_vec_ty(spty, vf) };
        let sc = lc_add(mem, lt_address_computation(pty, !used_by_addr, ps));
        if single { return sc; }
        var to_scal: i32[>..<] = [];
        var rty = T_VOID;
        if !used_by_addr {
            // supportsEfficientVectorElementLoadStore() is false
            if !(is_load && !pva) { for x in ops { to_scal.push(x); } }
            rty = vp_scalar_type(vpr[r].def);
        }
        var c = lc_add(lc_mul(sc, vf), vpc_scalarization_overhead(rty, to_scal, vf, true));
        let reg = vp_recipe_region(r);
        if reg >= 0 && vp_is_replicator(reg) {
            if ps < 0 { return vpc_legacy_cost(ui, vf); }
            c = lc_div(c, cm_pred_block_cost_divisor(inst_parent(ui)));
            c = lc_add(c, lt_cf(OP_CONDBR));
            c = lc_add(c, lt_scalarization_all(ty_vector(T_I1, vf, false), false, true));
            if vpc_use_emulated_mask_mem_ref_hack(r, vf) { return lcv(3000000); }
        }
        return c;
    }
    if o == OP_SEXT || o == OP_ZEXT || o == OP_FPTOUI || o == OP_FPTOSI || o == OP_FPEXT || o == OP_PTRTOINT ||
       o == OP_PTRTOADDR || o == OP_INTTOPTR || o == OP_SITOFP || o == OP_UITOFP || o == OP_TRUNC || o == OP_FPTRUNC ||
       o == OP_SELECT || o == OP_ADDRSPACECAST {
        return lc_mul(vpc_cost_for_recipe_with_opcode(r, o, 1), n);
    }
    if o == OP_EXTRACTVALUE || o == OP_INSERTVALUE { return lcv(tti_insert_extract_value_cost(o, LV_KIND)); }
    return vpc_legacy_cost(ui, vf);
}

// VPWidenMemoryRecipe::computeCost
fn vpc_widen_memory_cost(r: i32, vf: i64) -> i64 {
    let is_load = vpr[r].kind == VPR_WIDEN_LOAD;
    let sty = if is_load { vp_scalar_type(vpr[r].def) } else { vp_scalar_type(vp_op(r, 1)) };
    let ty = lv_vec_ty(sty, vf);
    let addr = vp_op(r, 0);
    let as_ = lv_ptr_as(vp_scalar_type(addr));
    if !vpr[r].consecutive {
        var pty = vp_scalar_type(addr);
        let ptr = vp_uv(addr);
        if !vp_is_single_scalar(addr) { pty = lv_vec_ty(pty, vf); }
        let id = if is_load { IID_masked_gather } else { IID_masked_scatter };
        return lc_add(lt_address_computation(pty, false, -1), lt_mem_intrinsic(id as i32, ty, ptr, vpr[r].masked, vpr[r].align, 0));
    }
    if vpr[r].masked {
        let id = if is_load { IID_masked_load } else { IID_masked_store };
        return lt_mem_intrinsic(id as i32, ty, -1, true, vpr[r].align, as_);
    }
    let oi = vpc_operand_info(vp_op(r, if is_load { 0 } else { 1 }));
    return lt_mem(if is_load { OP_LOAD } else { OP_STORE }, ty, vpr[r].align, as_, oi, vpr[r].ir_inst);
}

// VPWidenIntrinsicRecipe::computeCallCost
fn vpc_widen_intrinsic_cost(r: i32, vf: i64) -> i64 {
    let id = vpr[r].iid;
    let sret = vp_scalar_type(vpr[r].def);
    if id == IID_experimental_vp_reverse && ty_is_int(sret) && ty_bits(sret) == 1 { return 0; }
    let uv = vp_uv(vpr[r].def);
    let n = vp_nops(r);
    var args: i32[>..<] = [];
    var have_args = true;
    for k in n {
        let v = vp_uv(vp_op(r, k));
        if v < 0 {
            if uv >= 0 && is_inst(uv) && iop(uv) == OP_CALL { args.push(cb_arg(uv, k)); continue; }
            have_args = false;
            break;
        }
        args.push(v);
    }
    let rt = if vf > 1 { lv_vec_ty(sret, vf) } else { sret };
    if tti_kind != TTI_X86 { return lcv(base_intrinsic_cost(id, rt)); }
    let m = mk_mark();
    let im = ica_mark();
    let ii = if uv >= 0 && is_inst(uv) && call_iid(uv) != 0 { uv } else { -1 };
    let fmf = if vpr[r].f.ot == VOT_FMF || vpr[r].f.ot == VOT_FCMP { vpr[r].f.fmf } else { 0 };
    let ic = ica_new(id as i64, rt, fmf, ii, TTI_INVALID);
    if have_args { for a in args { ica_add_arg(ic, a); } }
    for k in n { ica_add_type(ic, lv_vec_ty(vp_scalar_type(vp_op(r, k)), vf)); }
    let c = x86_intrinsic_cost(ic, LV_KIND);
    mk_release(m);
    ica_release(im);
    return lcv(c);
}

// ---------------------------------------------------------------------------------------------
// block, region and plan costs

fn vpc_basic_block_cost(b: i32, vf: i64) -> i64 {
    var c: i64 = 0;
    var r = vpb[b].first;
    while r >= 0 { let nx = vpr[r].next; c = lc_add(c, vpc_recipe_cost(r, vf)); r = nx; }
    return c;
}
// VPRegionBlock::cost of a replicate region: the cost of its "then" block
fn vpc_replicate_region_cost(reg: i32, vf: i64) -> i64 { vpc_basic_block_cost(vp_succ(vpb[reg].entry, 0), vf) }
// VPRegionBlock::cost of the loop region (its child regions are replicate regions)
fn vpc_region_cost(reg: i32, vf: i64) -> i64 {
    if vp_is_replicator(reg) { return vpc_replicate_region_cost(reg, vf); }
    var c: i64 = 0;
    var bs: i32[>..<] = [];
    vp_depth_first(vpb[reg].entry, false, bs);
    for b in bs {
        if vp_is_region(b) {
            if !vp_is_replicator(b) { vp_unported("nested loop regions in the cost model"); }
            c = lc_add(c, vpc_replicate_region_cost(b, vf));
        } else {
            c = lc_add(c, vpc_basic_block_cost(b, vf));
        }
    }
    let be = if lv_has_forced_cost() { lv_forced_cost() } else { lt_cf(OP_BR) };
    lv_dbg_cost("Cost of ", be, vf, ": vector loop backedge");
    return lc_add(c, be);
}
// VPlan::cost
fn vpc_plan_cost(vf: i64) -> i64 {
    let c = vpc_region_cost(vp_vector_loop_region(), vf);
    if !lc_valid(c) { return LC_INVALID; }
    var bs: i32[>..<] = [];
    vp_depth_first(vph.entry, false, bs);
    vp_only_basic(bs);
    var bad = false;
    for b in bs { if !bad && !lc_valid(vpc_basic_block_cost(b, vf)) { bad = true; } }
    return if bad { LC_INVALID } else { c };
}

// addFullyUnrolledInstructionsToIgnore(L, IL, InstsToIgnore)
fn vpc_add_fully_unrolled_instructions_to_ignore() {
    let l = lvp_l;
    let latch = loop_latch(l);
    let br = block_terminator(latch);
    let cmp = if iop(br) == OP_CONDBR && is_inst(op(br, 0)) && iop(op(br, 0)) == OP_ICMP { op(br, 0) } else { -1 };
    if cmp >= 0 { hm_put(vpc_skip, cmp as u64, 1); }
    for iv in lvl_ind_phis {
        let inc = phi_incoming_for_block_lv(iv, latch);
        var all = true;
        var u = vals[inc].first_use;
        while u >= 0 { let us = uses[u].user; if us != iv && us != cmp { all = false; } u = uses[u].next; }
        if all { hm_put(vpc_skip, inc as u64, 1); }
    }
}
fn phi_incoming_for_block_lv(phi: i32, bb: i32) -> i32 {
    for k in phi_nincoming(phi) { if phi_block(phi, k) == bb { return op(phi, k); } }
    fatal("internal: loop-vectorize: no incoming value for the latch");
    return -1;
}

// LoopVectorizationPlanner::precomputeCosts(Plan, VF, CostCtx)
fn vpc_precompute_costs(vf: i64, tc: i64) -> i64 {
    let l = lvp_l;
    var c: i64 = 0;
    let latch = loop_latch(l);
    for iv in lvl_ind_phis {
        let inc = phi_incoming_for_block_lv(iv, latch);
        var ivs: i32[>..<] = [];
        ivs.push(inc);
        var k: i64 = 0;
        while k < ivs.len {
            let x = ivs[k];
            k++;
            for j in nops(x) {
                let o = op(x, j);
                if o == iv || !is_inst(o) || !loop_contains(l, inst_parent(o)) || !ivd_has_one_use(o) { continue; }
                ivs.push(o);
            }
        }
        ivs.push(iv);
        var u = vals[iv].first_use;
        while u >= 0 {
            let us = uses[u].user;
            u = uses[u].next;
            if cm_is_optimizable_iv_truncate(us, vf) { ivs.push(us); }
        }
        if tc == vf && !vp_has_tail_folded() { vpc_add_fully_unrolled_instructions_to_ignore(); }
        for x in ivs {
            if vpc_skip_cost(x, vf > 1) { continue; }
            let ic = vpc_legacy_cost(x, vf);
            if lv_dbg_on() { var s: u8[>..] = []; s.append(": induction instruction"); lv_dbg_inst_name(x, s); lv_dbg_cost("Cost of ", ic, vf, s); }
            c = lc_add(c, ic);
            hm_put(vpc_skip, x as u64, 1);
        }
    }
    for b in loop_nblocks(l) {
        let bb = loop_block(l, b);
        let t = block_terminator(bb);
        if vpc_skip_cost(t, vf > 1) { continue; }
        hm_put(vpc_skip, t as u64, 1);
        if bb == latch { continue; }
        c = lc_add(c, vpc_legacy_cost(t, vf));
    }
    if lv_has_forced_cost() { return c; }
    for key in cm_forced_list {
        if ((key as u64) >> 32) as i64 != vf { continue; }
        let x = ((key as u64) & 0xFFFFFFFF) as i32;
        if vpc_skip_cost(x, vf > 1) { continue; }
        hm_put(vpc_skip, x as u64, 1);
        let fc = vpc_legacy_cost(x, vf);
        if lv_dbg_on() { var s: u8[>..] = []; s.append(": forced scalar"); lv_dbg_inst_name(x, s); lv_dbg_cost("Cost of ", fc, vf, s); }
        c = lc_add(c, fc);
    }
    for key in cm_its_list {
        if ((key as u64) >> 32) as i64 != vf { continue; }
        let x = ((key as u64) & 0xFFFFFFFF) as i32;
        let o = iop(x);
        if o == OP_SDIV || o == OP_UDIV || o == OP_SREM || o == OP_UREM { continue; }
        if vpc_skip_cost(x, vf > 1) { continue; }
        hm_put(vpc_skip, x as u64, 1);
        let sc = hm_get(cm_its_cost, key as u64, 0);
        if lv_dbg_on() { var s: u8[>..] = []; s.append(": profitable to scalarize"); lv_dbg_inst_name(x, s); lv_dbg_cost("Cost of ", sc, vf, s); }
        c = lc_add(c, sc);
    }
    return c;
}

// LoopVectorizationPlanner::cost(Plan, VF, RU) for the loaded plan; tc = getSmallConstantTripCount
fn vpc_cost(vf: i64, tc: i64) -> i64 {
    vpc_reset();
    var c = vpc_precompute_costs(vf, tc);
    c = lc_add(c, vpc_plan_cost(vf));
    // shouldConsiderRegPressureForVF: only with maximized bandwidth (never on X86 without the flag)
    if lv_dbg_on() {
        var s: u8[>..] = [];
        s.append("Cost for VF ");
        format(s, vf);
        s.append(": ");
        lc_str(c, s);
        s.append(" (Estimated cost per lane: ...)\n");
        write_stderr(s);
    }
    return c;
}

// ---------------------------------------------------------------------------------------------
// willGenerateVectors, isMoreProfitable

// collectEphemeralRecipesForVPlan
fn vpc_collect_ephemeral_recipes(eph: HMap&) {
    var wl: i32[>..<] = [];
    var bs: i32[>..<] = [];
    vp_depth_first(vpb[vp_vector_loop_region()].entry, true, bs);
    vp_only_basic(bs);
    for b in bs {
        var r = vpb[b].first;
        while r >= 0 {
            if vpr[r].kind == VPR_REPLICATE && inst_iid(vp_underlying_instr(r)) == IID_assume {
                wl.push(r);
                hm_put(eph, r as u64, 1);
            }
            r = vpr[r].next;
        }
    }
    while wl.len > 0 {
        let cur = wl.pop();
        for k in vp_nops(cur) {
            let o = vp_op(cur, k);
            let d = vp_def(o);
            if d < 0 || vp_may_have_side_effects(d) || hm_has(eph, d as u64) { continue; }
            var all = true;
            for j in vp_num_users(o) { if !hm_has(eph, vp_user(o, j) as u64) { all = false; } }
            if !all { continue; }
            hm_put(eph, d as u64, 1);
            wl.push(d);
        }
    }
}
// willGenerateVectors(Plan, VF, TTI)
fn vpc_will_generate_vectors(vf: i64) -> bool {
    var eph = hm_new();
    vpc_collect_ephemeral_recipes(eph);
    var visited: i32[>..<] = [];
    var bs: i32[>..<] = [];
    vp_depth_first(vpb[vp_vector_loop_region()].entry, false, bs);
    vp_only_basic(bs);
    for b in bs {
        var r = vpb[b].first;
        while r >= 0 {
            let nx = vpr[r].next;
            let k = vpr[r].kind;
            if hm_has(eph, r as u64) || k == VPR_DERIVED_IV || k == VPR_SCALAR_IV_STEPS || k == VPR_REPLICATE ||
               k == VPR_INSTRUCTION || k == VPR_CURRENT_ITERATION_PHI || k == VPR_VECTOR_POINTER ||
               k == VPR_VECTOR_END_POINTER || k == VPR_EXPAND_SCEV || k == VPR_PRED_INST_PHI || k == VPR_BRANCH_ON_MASK {
                r = nx;
                continue;
            }
            if k == VPR_IR_INSTRUCTION || k == VPR_EXPRESSION || k == VPR_REDUCTION_EVL {
                fatal("internal: loop-vectorize: willGenerateVectors: unhandled recipe");
            }
            let nd = vp_num_defined_values(r);
            if nd == 0 && !(k == VPR_WIDEN_STORE || k == VPR_WIDEN_STORE_EVL || k == VPR_INTERLEAVE || k == VPR_INTERLEAVE_EVL) {
                r = nx;
                continue;
            }
            let v = if nd >= 1 { vp_defined_value(r, 0) } else { vp_op(r, 1) };
            let sty = vp_scalar_type(v);
            var dup = false;
            for t in visited { if t == sty { dup = true; } }
            if !dup {
                visited.push(sty);
                let wide = lv_vec_ty(sty, vf);
                let parts = lt_number_of_parts(wide);
                if parts != 0 && parts < vf { return true; }
            }
            r = nx;
        }
    }
    return false;
}

// isMoreProfitable(A, B, HasTail): (cost, width, scalar cost) triples; max_tc = getSmallConstantMaxTripCount
fn vpc_is_more_profitable(ca: i64, wa: i64, sa: i64, cb: i64, wb: i64, sb: i64, max_tc: i64, has_tail: bool) -> bool {
    // CostKind is TCK_RecipThroughput; preferFixedOverScalableIfEqualCost does not matter (no scalable VFs)
    let lower_without_tc = lc_mul(ca, wb) < lc_mul(cb, wa);
    if max_tc == 0 { return lower_without_tc; }
    fn cost_for_tc(vf: i64, vc: i64, sc: i64) -> i64 {
        if has_tail { return lc_add(lc_mul(vc, max_tc / vf), lc_mul(sc, max_tc % vf)); }
        return lc_mul(vc, (max_tc + vf - 1) / vf);
    }
    return cost_for_tc(wa, ca, sa) < cost_for_tc(wb, cb, sb);
}

// ---------------------------------------------------------------------------------------------
// calculateRegisterUsageForPlan(Plan, {VF}, TTI, ValuesToIgnore)

// SmallMapVector<unsigned, unsigned>: (class, count) pairs in insertion order
var vru_inv_cls: i64[>..<];
var vru_inv_n: i64[>..<];
var vru_max_cls: i64[>..<];
var vru_max_n: i64[>..<];
fn rcc_add(cls: i64[>..<]&, ns: i64[>..<]&, c: i64, n: i64) {
    for k in cls.len { if cls[k] == c { ns[k] += n; return; } }
    cls.push(c);
    ns.push(n);
}
fn vru_reg_usage(ty: i32, vf: i64) -> i64 {
    if ty_kind(ty) == TK_TOKEN || !lv_valid_elem_ty(ty) { return 0; }
    return tti_reg_usage_for_type(ty_vector(ty, vf, false));
}
fn vru_class(vector: bool, ty: i32) -> i64 { tv_register_class_for_type(vector, ty) }

fn vru_calculate(vf: i64) {
    vru_inv_cls.clear(); vru_inv_n.clear(); vru_max_cls.clear(); vru_max_n.clear();
    var idx2r: i32[>..<] = [];
    var end_point = hm_new();
    var ends = hm_new();
    var invariants: i32[>..<] = [];
    var inv_set = hm_new();
    if vph.vtc >= 0 && vp_num_users(vph.vtc) > 0 { invariants.push(vph.vtc); hm_put(inv_set, vph.vtc as u64, 1); }
    let region = vp_vector_loop_region();
    var bs: i32[>..<] = [];
    vp_rpo(region, true, bs);
    vp_only_basic(bs);
    for bb in bs {
        if vpb[bb].parent < 0 { break; }
        var r = vpb[bb].first;
        while r >= 0 {
            idx2r.push(r);
            for k in vp_nops(r) {
                let u = vp_op(r, k);
                let kk = vpv[u].kind;
                if kk == VVK_SINGLE_DEF || kk == VVK_MULTI_DEF {
                    hm_put(end_point, u as u64, idx2r.len);
                    hm_put(ends, u as u64, 1);
                } else if kk == VVK_IR {
                    if !is_inst(vp_ir(u)) { continue; }
                    if !hm_has(inv_set, u as u64) { hm_put(inv_set, u as u64, 1); invariants.push(u); }
                }
            }
            r = vpr[r].next;
        }
        if bb == vpb[region].exiting {
            var phis: i32[>..<] = [];
            vp_block_phis(vp_entry_basic_block(region), phis);
            for p in phis {
                if vpr[p].kind != VPR_WIDEN_INT_OR_FP_INDUCTION { continue; }
                hm_put(end_point, vpr[p].def as u64, idx2r.len);
                hm_put(ends, vpr[p].def as u64, 1);
            }
        }
    }
    var open: i32[>..<] = [];
    let can_iv = vpb[region].can_iv;
    if vp_num_users(can_iv) > 0 { open.push(can_iv); }
    for idx in idx2r.len {
        let r = idx2r[idx];
        var k: i64 = 0;
        while k < open.len {
            let e = hm_get(end_point, open[k] as u64, -1);
            if e == idx { open[k] = open[open.len - 1]; open.pop(); continue; }
            k++;
        }
        var used = false;
        for j in vp_num_defined_values(r) { if hm_has(ends, vp_defined_value(r, j) as u64) { used = true; } }
        if !used && !vp_may_have_side_effects(r) { continue; }
        if vpr[r].def >= 0 {
            let uv = vpv[vpr[r].def].uv;
            if uv >= 0 && hm_has(cm_vals_to_ignore, uv as u64) { continue; }
        }
        var ucls: i64[>..<] = [];
        var un: i64[>..<] = [];
        for v in open {
            let d = vp_def(v);
            if d >= 0 {
                let dk = vpr[d].kind;
                if dk == VPR_VECTOR_POINTER || dk == VPR_VECTOR_END_POINTER || dk == VPR_BRANCH_ON_MASK { continue; }
                if vpm_vpi_r(d, VPI_EXTRACT_LAST_PART, 1) { continue; }
            }
            var scalar_use = vf == 1 || v == can_iv;
            if !scalar_use && d >= 0 {
                let dk = vpr[d].kind;
                if dk == VPR_REPLICATE || dk == VPR_DERIVED_IV || dk == VPR_CURRENT_ITERATION_PHI || dk == VPR_SCALAR_IV_STEPS { scalar_use = true; }
                else if dk == VPR_INSTRUCTION && vp_only_scalar_values_used(v) { scalar_use = true; }
                else if dk == VPR_REDUCTION_PHI && vpr[d].rdx_style != VRS_UNORDERED { scalar_use = true; }
            }
            if scalar_use {
                rcc_add(ucls, un, vru_class(false, vp_scalar_type(v)), 1);
            } else {
                var scale: i64 = 1;
                if d >= 0 && (vpr[d].kind == VPR_REDUCTION_PHI || vpr[d].kind == VPR_REDUCTION) { scale = vpr[d].rdx_scale as i64; }
                if d >= 0 && vpr[d].kind == VPR_EXPRESSION { vp_unported("VPExpressionRecipe register usage"); }
                let rvf = if scale > 1 { vf / scale } else { vf };
                let sty = vp_scalar_type(v);
                rcc_add(ucls, un, vru_class(true, sty), vru_reg_usage(sty, rvf));
            }
        }
        for j in ucls.len {
            var found = false;
            for m in vru_max_cls.len {
                if vru_max_cls[m] == ucls[j] { found = true; if un[j] > vru_max_n[m] { vru_max_n[m] = un[j]; } }
            }
            if !found { vru_max_cls.push(ucls[j]); vru_max_n.push(un[j]); }
        }
        for j in vp_num_defined_values(r) {
            let dv = vp_defined_value(r, j);
            if !hm_has(ends, dv as u64) { continue; }
            var have = false;
            for x in open { if x == dv { have = true; } }
            if !have { open.push(dv); }
        }
    }
    for inv in invariants {
        let is_scalar = vp_only_scalar_values_used(inv);
        let ivf = if is_scalar { 1 } else { vf };
        rcc_add(vru_inv_cls, vru_inv_n, vru_class(ivf > 1, vp_scalar_type(inv)), vru_reg_usage(vp_scalar_type(inv), ivf));
    }
}

// ---------------------------------------------------------------------------------------------
// selectInterleaveCount(Plan, VF, LoopCost) for the loaded plan
// best_tc = getSmallBestKnownTC(PSE, L, true, isEpilogueAllowed()) (0 = none), const_tc = getSmallConstantTripCount,
// rse = requiresScalarEpilogue(Plan, VF), scalar_cost: CM.expectedCost(VF) when VF is scalar

fn bit_floor_lv(x: u64) -> u64 {
    if x == 0 { return 0; }
    var r: u64 = 1;
    while r <= x / 2 { r = r << 1; }
    return r;
}

fn vpc_select_interleave_count(vf: i64, loop_cost0: i64, ep_allowed: bool, best_tc: i64, const_tc: i64, rse: bool) -> i64 {
    // !isEpilogueAllowed() && !(preferTailFoldedLoop() && useWideActiveLaneMask()): no wide lane masks on X86
    if !ep_allowed { return 1; }
    let region = vp_vector_loop_region();
    var phis: i32[>..<] = [];
    vp_block_phis(vp_entry_basic_block(region), phis);
    for p in phis { if vpr[p].kind == VPR_CURRENT_ITERATION_PHI { return 1; } }
    if !lvl_is_safe_for_any_vector_width() { return 1; }
    if vp_has_early_exit() { return 1; }
    var has_rdx = false;
    for p in phis { if vpr[p].kind == VPR_REDUCTION_PHI { has_rdx = true; } }
    for p in phis { if vpr[p].kind == VPR_REDUCTION_PHI && rk_is_find_last(vpr[p].rdx_kind) { return 1; } }
    vru_calculate(vf);
    var loop_cost = loop_cost0;
    if loop_cost == 0 {
        loop_cost = if vf == 1 { cm_expected_cost(1) } else { vpc_cost(vf, const_tc) };
        if loop_cost == 0 { return 1; }
    }
    for k in vru_max_n.len { if vru_max_n[k] < 1 { vru_max_n[k] = 1; } }
    var ic: u64 = 0xFFFFFFFF;
    for k in vru_max_cls.len {
        var target = tv_number_of_registers(vru_max_cls[k]) as u32;
        if vf == 1 { if flag_given("force-target-num-scalar-regs") { target = flag_int("force-target-num-scalar-regs", 0) as u32; } }
        else if flag_given("force-target-num-vector-regs") { target = flag_int("force-target-num-vector-regs", 0) as u32; }
        let max_local = vru_max_n[k] as u32;
        var inv: u32 = 0;
        for j in vru_inv_cls.len { if vru_inv_cls[j] == vru_max_cls[k] { inv = vru_inv_n[j] as u32; } }
        var tmp = bit_floor_lv(((target - inv) / max_local) as u64);
        if flag_bool("enable-ind-var-register-heur", true) {
            let d = if max_local - 1 > 1 { max_local - 1 } else { 1 };
            tmp = bit_floor_lv(((target - inv - 1) / d) as u64);
        }
        if tmp < ic { ic = tmp; }
    }
    var has_unordered = false;
    if has_rdx {
        has_unordered = true;
        for p in phis { if vpr[p].kind == VPR_REDUCTION_PHI && vpr[p].rdx_style == VRS_ORDERED { has_unordered = false; } }
    }
    var max_ic: u64 = if tti_kind == TTI_X86 { x86_max_interleave_factor(vf) as u64 } else { 1 };
    if vf == 1 { if flag_given("force-target-max-scalar-interleave") { max_ic = flag_int("force-target-max-scalar-interleave", 0) as u64; } }
    else if flag_given("force-target-max-vector-interleave") { max_ic = flag_int("force-target-max-vector-interleave", 0) as u64; }
    if best_tc != 0 {
        var avail = best_tc as u32;
        let est_vf = vf as u32;
        if rse { avail = avail - 1; }
        fn umax1(x: u32) -> u32 { if x > 1 { x } else { 1 } }
        fn umin(a: u32, b: u32) -> u32 { if a < b { a } else { b } }
        let lb = bit_floor_lv(umax1(umin(avail / (est_vf * 2), max_ic as u32)) as u64) as u32;
        if const_tc != 0 {
            let ub = bit_floor_lv(umax1(umin(avail / est_vf, max_ic as u32)) as u64) as u32;
            max_ic = lb as u64;
            if ub != lb {
                let tub = avail % (est_vf * ub);
                let tlb = avail % (est_vf * lb);
                if tub == tlb { max_ic = ub as u64; }
            }
        } else {
            max_ic = lb as u64;
        }
    }
    if max_ic == 0 { fatal("internal: loop-vectorize: Maximum interleave count must be greater than 0"); }
    if ic > max_ic { ic = max_ic; } else if ic < 1 { ic = 1; }
    if vf > 1 && has_rdx { return ic as i64; }
    var pred_needed = false;
    if vf == 1 { for b in loop_nblocks(lvp_l) { if lvl_block_needs_predication(loop_block(lvp_l, b)) { pred_needed = true; } } }
    let rt_needed = vf == 1 && lvl_rt_need();
    if lv_dbg_on() {
        var s: u8[>..] = [];
        s.append("LV: Loop cost is ");
        lc_str(loop_cost, s);
        s.append("\nLV: IC is ");
        format(s, ic as i64);
        s.append("\nLV: VF is ");
        format(s, vf);
        s.push('\n');
        write_stderr(s);
    }
    let small = flag_int("small-loop-cost", 20);
    // enableAggressiveInterleaving is false on X86 and the base
    if !rt_needed && !pred_needed && loop_cost < lcv(small) {
        let lcval = lc_value(loop_cost);
        if lcval == 0 { vp_unported("a loop cost below 1 in selectInterleaveCount (a division by zero in LLVM)"); }
        var small_ic = bit_floor_lv((small / lcval) as u64);
        if ic < small_ic { small_ic = ic; }
        var num_stores: u64 = 0;
        var num_loads: u64 = 0;
        var bs: i32[>..<] = [];
        vp_depth_first(vpb[region].entry, true, bs);
        vp_only_basic(bs);
        for b in bs {
            var r = vpb[b].first;
            while r >= 0 {
                let k = vpr[r].kind;
                if k == VPR_WIDEN_LOAD || k == VPR_WIDEN_LOAD_EVL { num_loads++; }
                else if k == VPR_WIDEN_STORE || k == VPR_WIDEN_STORE_EVL { num_stores++; }
                else if k == VPR_INTERLEAVE {
                    let so = vp_interleave_num_store_operands(r);
                    if so != 0 { num_stores += so as u64; } else { num_loads += vp_num_defined_values(r) as u64; }
                } else if k == VPR_REPLICATE {
                    let ui = vp_underlying_instr(r);
                    if iop(ui) == OP_LOAD { num_loads++; }
                    if iop(ui) == OP_STORE { num_stores++; }
                } else if k == VPR_HISTOGRAM { num_loads++; num_stores++; }
                r = vpr[r].next;
            }
        }
        var stores_ic = ic / (if num_stores != 0 { num_stores } else { 1 });
        var loads_ic = ic / (if num_loads != 0 { num_loads } else { 1 });
        if has_rdx {
            for p in phis {
                if vpr[p].kind == VPR_REDUCTION_PHI && (rk_is_any_of(vpr[p].rdx_kind) || rk_is_find_iv(vpr[p].rdx_kind)) { return 1; }
            }
        }
        if has_rdx && loop_depth(lvp_l) > 1 {
            for p in phis { if vpr[p].kind == VPR_REDUCTION_PHI && vpr[p].rdx_style == VRS_ORDERED { return 1; } }
            let f = flag_int("max-nested-scalar-reduction-interleave", 2) as u64;
            if f < small_ic { small_ic = f; }
            if f < stores_ic { stores_ic = f; }
            if f < loads_ic { loads_ic = f; }
        }
        let mx = if stores_ic > loads_ic { stores_ic } else { loads_ic };
        if flag_bool("enable-loadstore-runtime-interleave", true) && mx > small_ic { return mx as i64; }
        return small_ic as i64;
    }
    return 1;
}

// isOutsideLoopWorkProfitable without runtime checks (RtC = 0) for a vector VF; sel_allowed: SEL ==
// CM_EpilogueAllowed, expected_tc = getSmallBestKnownTC(PSE, L) (0 = none). Returns (profitable, MinProfitableTC).
fn vpc_is_outside_loop_work_profitable(vf: i64, vf_cost: i64, scalar_cost: i64, sel_allowed: bool, expected_tc: i64) -> bool, i64 {
    let sc = lc_value(scalar_cost) as u64;
    if sc == 0 { return true, 0; }
    vpc_reset();
    var total: i64 = 0;
    for k in xv_len(vph.exit_blocks) {
        let eb = xv_get(vph.exit_blocks, k);
        for j in vp_npreds(eb) {
            let p = vp_pred(eb, j);
            if p != vp_middle_block() { total = lc_add(total, vpc_basic_block_cost(p, vf)); }
        }
    }
    total = lc_add(total, vpc_basic_block_cost(vp_middle_block(), vf));
    let ivf = vf as u64;
    let div = sc * ivf - (lc_value(vf_cost) as u64);
    let tv = lc_value(total) as u64;
    let min1: u64 = if div == 0 { 0 } else { (tv * ivf + div - 1) / div };
    var min_tc = min1;
    if sel_allowed { min_tc = (min_tc + ivf - 1) / ivf * ivf; }
    if expected_tc != 0 && (expected_tc as u64) < min_tc { return false, min_tc as i64; }
    return true, min_tc as i64;
}
