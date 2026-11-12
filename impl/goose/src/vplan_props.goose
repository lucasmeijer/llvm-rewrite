// The "virtual" queries of VPlan recipes as switches on the recipe kind: mayReadFromMemory / mayWriteToMemory /
// mayHaveSideEffects / isSafeToSpeculativelyExecute, VPUser::usesFirstLaneOnly / usesScalars /
// usesFirstPartOnly, VPInstruction::isVectorToScalar / isSingleScalar / opcodeMayReadOrWriteFromMemory,
// vputils::onlyFirstLaneUsed / onlyFirstPartUsed / onlyScalarValuesUsed / isSingleScalar /
// isUniformAcrossVFsAndUFs / cannotHoistOrSinkRecipe, isDeadRecipe, getIntrinsicID, and VPRecipeBase::clone().
// Ported from llvm/lib/Transforms/Vectorize/VPlanRecipes.cpp, VPlan.h and VPlanUtils.cpp.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_iids;
import pm;
import vecutils;
import vplan;
import vplan_utils;

fn vp_opcode_is_cast(o: i32) -> bool { vpi_is_ir_opcode(o) && is_cast_op(o as i64) }
fn vp_opcode_is_binary(o: i32) -> bool { vpi_is_ir_opcode(o) && (o as i64) >= OP_ADD && (o as i64) <= OP_XOR }

// VPInstruction::isVectorToScalar
fn vpi_is_vector_to_scalar(r: i32) -> bool {
    let o = vpr[r].opcode;
    return o == VPI_EXTRACT_LAST_LANE || o == VPI_EXTRACT_PENULTIMATE_ELEMENT || o == OP_EXTRACTELEMENT as i32 ||
           o == VPI_EXTRACT_LANE || o == VPI_FIRST_ACTIVE_LANE || o == VPI_LAST_ACTIVE_LANE || o == VPI_EXTRACT_LAST_ACTIVE ||
           o == VPI_COMPUTE_REDUCTION_RESULT || o == VPI_ANY_OF || o == VPI_NUM_ACTIVE_LANES;
}
// VPInstruction::isSingleScalar
fn vpi_is_single_scalar(r: i32) -> bool {
    let o = vpr[r].opcode;
    if o == OP_LOAD as i32 || o == OP_PHI as i32 || o == VPI_EXPLICIT_VECTOR_LENGTH || o == VPI_RESUME_FOR_EPILOGUE || o == VPI_INTRINSIC { return true; }
    return vp_opcode_is_cast(o);
}
fn vp_fn_memory(f: i32) -> u64 { aset_memory(alist_fn(func_attrs(f))) }
// VPInstruction::opcodeMayReadOrWriteFromMemory
fn vpi_opcode_may_read_or_write_memory(r: i32) -> bool {
    let o = vpr[r].opcode;
    if vpi_is_ir_opcode(o) {
        let io = o as i64;
        if (io >= OP_ADD && io <= OP_XOR) || io == OP_FNEG || is_cast_op(io) { return false; }
        if io == OP_EXTRACTVALUE || io == OP_INSERTVALUE || io == OP_GEP || io == OP_EXTRACTELEMENT || io == OP_INSERTELEMENT ||
           io == OP_FREEZE || io == OP_FCMP || io == OP_ICMP || io == OP_SELECT || io == OP_PHI { return false; }
        if io == OP_CALL {
            let n = vp_num_operands_for_opcode(r);
            let f = vp_ir(vp_op(r, n - 1));
            return !me_none(vp_fn_memory(f));
        }
        return true;
    }
    if o == VPI_INTRINSIC { vp_unported("VPInstruction::Intrinsic memory effects"); }
    if o == VPI_COMPUTE_REDUCTION_RESULT || o == VPI_RESUME_FOR_EPILOGUE || o == VPI_NUM_ACTIVE_LANES { return true; }
    return false;
}

fn vp_interleave_num_store_operands(r: i32) -> i64 {
    if vpr[r].kind == VPR_INTERLEAVE { return vp_nops(r) - (if vpr[r].masked { 2 } else { 1 }); }
    return vp_nops(r) - (if vpr[r].masked { 3 } else { 2 });
}

fn vp_may_write_to_memory(r: i32) -> bool {
    let k = vpr[r].kind;
    if k == VPR_EXPRESSION { vp_unported("VPExpressionRecipe::mayReadOrWriteMemory"); }
    if k == VPR_INSTRUCTION {
        if vpr[r].opcode == OP_LOAD as i32 { return false; }
        return vpi_opcode_may_read_or_write_memory(r);
    }
    if k == VPR_INTERLEAVE_EVL || k == VPR_INTERLEAVE { return vp_interleave_num_store_operands(r) > 0; }
    if k == VPR_WIDEN_STORE_EVL || k == VPR_WIDEN_STORE { return true; }
    if k == VPR_REPLICATE { return inst_may_write_memory(vp_underlying_instr(r)); }
    if k == VPR_WIDEN_CALL { return !me_only_reads(vp_fn_memory(vp_ir(vp_op(r, vp_nops(r) - 1)))); }
    if k == VPR_WIDEN_MEM_INTRINSIC || k == VPR_WIDEN_INTRINSIC { return vpr[r].may_write; }
    if k == VPR_ACTIVE_LANE_MASK_PHI || k == VPR_CURRENT_ITERATION_PHI || k == VPR_BRANCH_ON_MASK || k == VPR_DERIVED_IV ||
       k == VPR_FIRST_ORDER_RECURRENCE_PHI || k == VPR_REDUCTION_PHI || k == VPR_SCALAR_IV_STEPS || k == VPR_PRED_INST_PHI { return false; }
    if k == VPR_BLEND || k == VPR_REDUCTION_EVL || k == VPR_REDUCTION || k == VPR_VECTOR_POINTER || k == VPR_WIDEN_CANONICAL_IV ||
       k == VPR_WIDEN_CAST || k == VPR_WIDEN_GEP || k == VPR_WIDEN_INT_OR_FP_INDUCTION || k == VPR_WIDEN_LOAD_EVL ||
       k == VPR_WIDEN_LOAD || k == VPR_WIDEN_PHI || k == VPR_WIDEN_POINTER_INDUCTION || k == VPR_WIDEN { return false; }
    return true;
}
fn vp_may_read_from_memory(r: i32) -> bool {
    let k = vpr[r].kind;
    if k == VPR_EXPRESSION { vp_unported("VPExpressionRecipe::mayReadOrWriteMemory"); }
    if k == VPR_INSTRUCTION { return vpi_opcode_may_read_or_write_memory(r); }
    if k == VPR_WIDEN_LOAD_EVL || k == VPR_WIDEN_LOAD { return true; }
    if k == VPR_REPLICATE { return inst_may_read_memory(vp_underlying_instr(r)); }
    if k == VPR_WIDEN_CALL { return !me_only_writes(vp_fn_memory(vp_ir(vp_op(r, vp_nops(r) - 1)))); }
    if k == VPR_WIDEN_MEM_INTRINSIC || k == VPR_WIDEN_INTRINSIC { return vpr[r].may_read; }
    if k == VPR_BRANCH_ON_MASK || k == VPR_DERIVED_IV || k == VPR_CURRENT_ITERATION_PHI || k == VPR_FIRST_ORDER_RECURRENCE_PHI ||
       k == VPR_REDUCTION_PHI || k == VPR_PRED_INST_PHI || k == VPR_SCALAR_IV_STEPS || k == VPR_WIDEN_STORE_EVL || k == VPR_WIDEN_STORE { return false; }
    if k == VPR_BLEND || k == VPR_REDUCTION_EVL || k == VPR_REDUCTION || k == VPR_VECTOR_POINTER || k == VPR_WIDEN_CANONICAL_IV ||
       k == VPR_WIDEN_CAST || k == VPR_WIDEN_GEP || k == VPR_WIDEN_INT_OR_FP_INDUCTION || k == VPR_WIDEN_PHI ||
       k == VPR_WIDEN_POINTER_INDUCTION || k == VPR_WIDEN { return false; }
    return true;
}
fn vp_may_read_or_write_memory(r: i32) -> bool { vp_may_read_from_memory(r) || vp_may_write_to_memory(r) }
fn vp_may_have_side_effects(r: i32) -> bool {
    let k = vpr[r].kind;
    if k == VPR_EXPRESSION { vp_unported("VPExpressionRecipe::mayHaveSideEffects"); }
    if k == VPR_ACTIVE_LANE_MASK_PHI || k == VPR_DERIVED_IV || k == VPR_CURRENT_ITERATION_PHI || k == VPR_FIRST_ORDER_RECURRENCE_PHI ||
       k == VPR_REDUCTION_PHI || k == VPR_PRED_INST_PHI || k == VPR_VECTOR_END_POINTER { return false; }
    if k == VPR_INSTRUCTION {
        let o = vpr[r].opcode;
        return vp_may_write_to_memory(r) || o == VPI_BRANCH_ON_COUNT || o == VPI_BRANCH_ON_COND || o == VPI_BRANCH_ON_TWO_CONDS;
    }
    if k == VPR_WIDEN_CALL {
        let f = vp_ir(vp_op(r, vp_nops(r) - 1));
        return vp_may_write_to_memory(r) || !func_has_fn_attr(f, AK_NoUnwind) || !func_has_fn_attr(f, AK_WillReturn);
    }
    if k == VPR_WIDEN_MEM_INTRINSIC || k == VPR_WIDEN_INTRINSIC { return vpr[r].may_se; }
    if k == VPR_BLEND || k == VPR_REDUCTION_EVL || k == VPR_REDUCTION || k == VPR_SCALAR_IV_STEPS || k == VPR_VECTOR_POINTER ||
       k == VPR_WIDEN_CANONICAL_IV || k == VPR_WIDEN_CAST || k == VPR_WIDEN_GEP || k == VPR_WIDEN_INT_OR_FP_INDUCTION ||
       k == VPR_WIDEN_PHI || k == VPR_WIDEN_POINTER_INDUCTION || k == VPR_WIDEN { return false; }
    if k == VPR_INTERLEAVE_EVL || k == VPR_INTERLEAVE { return vp_may_write_to_memory(r); }
    if k == VPR_WIDEN_LOAD_EVL || k == VPR_WIDEN_LOAD || k == VPR_WIDEN_STORE_EVL || k == VPR_WIDEN_STORE { return vp_may_write_to_memory(r); }
    if k == VPR_REPLICATE { return inst_may_have_side_effects(vp_underlying_instr(r)); }
    return true;
}
// VPRecipeBase::isSafeToSpeculativelyExecute
fn vp_is_safe_to_speculatively_execute(r: i32) -> bool {
    if vpr[r].kind != VPR_INSTRUCTION { return false; }
    let o = vpr[r].opcode;
    if vp_opcode_is_cast(o) { return true; }
    return o == OP_ADD as i32 || o == OP_SUB as i32 || o == OP_MUL as i32 || o == OP_GEP as i32;
}

// ---------------------------------------------------------------------------------------------
// operand-use queries

// vputils::propagatesFirstLaneUse
fn vp_propagates_first_lane_use(u: i32, opv: i32) -> bool {
    if vpr[u].kind == VPR_BLEND { return true; }
    if vpr[u].kind != VPR_INSTRUCTION { return false; }
    let o = vpr[u].opcode;
    if o == OP_FCMP as i32 || o == OP_ICMP as i32 || o == OP_SELECT as i32 || o == OP_FREEZE as i32 || o == VPI_NOT { return true; }
    if o == VPI_PTR_ADD { return opv != vp_op(u, 0); }
    return vp_opcode_is_binary(o) || vp_opcode_is_cast(o);
}

var vpq_wl: i32[>..<];   // onlyFirstLaneUsed's worklists (segments with marks: the queries recurse)

// vputils::onlyFirstLaneUsed
recursive fn vp_only_first_lane_used(def: i32) -> bool {
    let mark = vpq_wl.len;
    vpq_wl.push(def);
    var k = mark;
    while k < vpq_wl.len {
        let cur = vpq_wl[k];
        k++;
        for j in vp_num_users(cur) {
            let u = vp_user(cur, j);
            if vp_propagates_first_lane_use(u, cur) {
                let d = vpr[u].def;
                var seen = false;
                for x in mark..vpq_wl.len { if vpq_wl[x] == d { seen = true; } }
                if !seen { vpq_wl.push(d); }
            } else if !vp_uses_first_lane_only(u, cur) {
                vpq_wl.resize(mark);
                return false;
            }
        }
    }
    vpq_wl.resize(mark);
    return true;
}
recursive fn vp_only_first_part_used(def: i32) -> bool {
    for j in vp_num_users(def) { if !vp_uses_first_part_only(vp_user(def, j), def) { return false; } }
    return true;
}
recursive fn vp_only_scalar_values_used(def: i32) -> bool {
    for j in vp_num_users(def) { if !vp_uses_scalars(vp_user(def, j), def) { return false; } }
    return true;
}

// VPUser::usesFirstLaneOnly (per recipe class)
recursive fn vp_uses_first_lane_only(r: i32, opv: i32) -> bool {
    let k = vpr[r].kind;
    if k == VPR_INSTRUCTION {
        if vp_propagates_first_lane_use(r, opv) { return vp_only_first_lane_used(vpr[r].def); }
        let o = vpr[r].opcode;
        if o == OP_EXTRACTELEMENT as i32 { return opv == vp_op(r, 1); }
        if o == OP_INSERTELEMENT as i32 { return opv == vp_op(r, 1) || opv == vp_op(r, 2); }
        if o == OP_PHI as i32 || o == OP_LOAD as i32 || o == VPI_ACTIVE_LANE_MASK || o == VPI_EXPLICIT_VECTOR_LENGTH ||
           o == VPI_CALCULATE_TRIP_COUNT_MINUS_VF || o == VPI_CANONICAL_IV_INCREMENT_FOR_PART || o == VPI_BRANCH_ON_COUNT ||
           o == VPI_BRANCH_ON_COND || o == VPI_BRANCH_ON_TWO_CONDS || o == VPI_BROADCAST || o == VPI_INTRINSIC ||
           o == VPI_REDUCTION_START_VECTOR || o == VPI_RESUME_FOR_EPILOGUE { return true; }
        if o == VPI_BUILD_STRUCT_VECTOR || o == VPI_BUILD_VECTOR { return vp_nops(r) > 1; }
        if o == VPI_PTR_ADD || o == VPI_EXITING_IV_VALUE || o == VPI_EXTRACT_LANE { return opv == vp_op(r, 0); }
        return false;
    }
    if k == VPR_IR_INSTRUCTION { return true; }
    if k == VPR_WIDEN { return vpr[r].opcode == OP_SELECT as i32 && opv == vp_op(r, 0) && vp_is_ir_value(opv); }
    if k == VPR_WIDEN_INTRINSIC || k == VPR_WIDEN_MEM_INTRINSIC {
        for i in vp_nops(r) { if vp_op(r, i) == opv && !vu_scalar_op_at_arg(vpr[r].iid, i, true) { return false; } }
        return true;
    }
    if k == VPR_WIDEN_CALL { vp_unported("VPWidenCallRecipe::usesFirstLaneOnly"); }
    if k == VPR_WIDEN_GEP { return vp_is_single_scalar(opv); }
    if k == VPR_VECTOR_END_POINTER || k == VPR_VECTOR_POINTER { return true; }
    if k == VPR_WIDEN_INT_OR_FP_INDUCTION || k == VPR_WIDEN_POINTER_INDUCTION { return opv == vp_op(r, 0) || opv == vp_op(r, 1); }
    if k == VPR_FIRST_ORDER_RECURRENCE_PHI { return opv == vp_op(r, 0); }
    if k == VPR_REDUCTION_PHI { return vpr[r].rdx_style != VRS_UNORDERED; }
    if k == VPR_BLEND { return vp_only_first_lane_used(vpr[r].def); }
    if k == VPR_INTERLEAVE {
        if opv != vp_op(r, 0) { return false; }
        let n = vp_interleave_num_store_operands(r);
        let base = vp_nops(r) - n - (if vpr[r].masked { 1 } else { 0 });
        for i in base..base + n { if vp_op(r, i) == opv { return false; } }
        return true;
    }
    if k == VPR_INTERLEAVE_EVL { vp_unported("VPInterleaveEVLRecipe"); }
    if k == VPR_REDUCTION_EVL { return opv == vp_op(r, 2); }
    if k == VPR_REPLICATE { return vpr[r].single_scalar; }
    if k == VPR_WIDEN_LOAD { return opv == vp_op(r, 0) && vpr[r].consecutive; }
    if k == VPR_WIDEN_LOAD_EVL { return opv == vp_op(r, 1) || (opv == vp_op(r, 0) && vpr[r].consecutive); }
    if k == VPR_WIDEN_STORE { return opv == vp_op(r, 0) && vpr[r].consecutive && opv != vp_op(r, 1); }
    if k == VPR_WIDEN_STORE_EVL {
        if opv == vp_op(r, 2) { return true; }
        return opv == vp_op(r, 0) && vpr[r].consecutive && opv != vp_op(r, 1);
    }
    if k == VPR_CURRENT_ITERATION_PHI || k == VPR_DERIVED_IV || k == VPR_SCALAR_IV_STEPS { return true; }
    return false;
}
// VPUser::usesScalars
recursive fn vp_uses_scalars(r: i32, opv: i32) -> bool {
    let k = vpr[r].kind;
    if k == VPR_INSTRUCTION && vp_is_instruction_with_type(r) && vp_opcode_is_cast(vpr[r].opcode) { return true; }
    if k == VPR_IR_INSTRUCTION || k == VPR_REPLICATE || k == VPR_BRANCH_ON_MASK || k == VPR_PRED_INST_PHI { return true; }
    return vp_uses_first_lane_only(r, opv);
}
// VPUser::usesFirstPartOnly
recursive fn vp_uses_first_part_only(r: i32, opv: i32) -> bool {
    let k = vpr[r].kind;
    if k == VPR_INSTRUCTION {
        let o = vpr[r].opcode;
        if vp_opcode_is_binary(o) { return vp_only_first_part_used(vpr[r].def); }
        if o == OP_FCMP as i32 || o == OP_ICMP as i32 || o == OP_SELECT as i32 { return vp_only_first_part_used(vpr[r].def); }
        return o == VPI_BRANCH_ON_COUNT || o == VPI_BRANCH_ON_COND || o == VPI_BRANCH_ON_TWO_CONDS || o == VPI_CANONICAL_IV_INCREMENT_FOR_PART;
    }
    if k == VPR_IR_INSTRUCTION || k == VPR_VECTOR_END_POINTER || k == VPR_VECTOR_POINTER { return true; }
    return false;
}

// preservesUniformity
fn vp_preserves_uniformity(o: i32) -> bool {
    if vpi_is_ir_opcode(o) {
        let io = o as i64;
        if (io >= OP_ADD && io <= OP_XOR) || is_cast_op(io) { return true; }
        return io == OP_FREEZE || io == OP_GEP || io == OP_ICMP || io == OP_FCMP || io == OP_SELECT;
    }
    return o == VPI_NOT || o == VPI_BROADCAST || o == VPI_MASKED_COND || o == VPI_PTR_ADD;
}
// vputils::isSingleScalar
recursive fn vp_is_single_scalar(v: i32) -> bool {
    let kind = vpv[v].kind;
    if kind == VVK_REGION { return v == vpb[vpv[v].region].can_iv; }
    if kind == VVK_IR || kind == VVK_SYMBOLIC { return true; }
    let r = vp_def(v);
    if r < 0 { return false; }
    let k = vpr[r].kind;
    if k == VPR_REPLICATE {
        let reg = vp_recipe_region(r);
        if reg >= 0 && vp_is_replicator(reg) { return false; }
        if vpr[r].single_scalar { return true; }
        if !vp_preserves_uniformity(iop(vp_underlying_instr(r)) as i32) { return false; }
        for i in vp_nops(r) { if !vp_is_single_scalar(vp_op(r, i)) { return false; } }
        return true;
    }
    if k == VPR_WIDEN_GEP || k == VPR_BLEND {
        for i in vp_nops(r) { if !vp_is_single_scalar(vp_op(r, i)) { return false; } }
        return true;
    }
    if k == VPR_WIDEN {
        if !vp_preserves_uniformity(vpr[r].opcode) { return false; }
        for i in vp_nops(r) { if !vp_is_single_scalar(vp_op(r, i)) { return false; } }
        return true;
    }
    if k == VPR_INSTRUCTION {
        if vpi_is_single_scalar(r) || vpi_is_vector_to_scalar(r) { return true; }
        if !vp_preserves_uniformity(vpr[r].opcode) { return false; }
        for i in vp_nops(r) { if !vp_is_single_scalar(vp_op(r, i)) { return false; } }
        return true;
    }
    if k == VPR_REDUCTION { return vpr[r].rdx_scale <= 1; }
    if k == VPR_VECTOR_POINTER || k == VPR_VECTOR_END_POINTER || k == VPR_DERIVED_IV { return true; }
    if k == VPR_EXPRESSION { vp_unported("VPExpressionRecipe::isVectorToScalar"); }
    return k == VPR_EXPAND_SCEV;
}
// vputils::isUniformAcrossVFsAndUFs
recursive fn vp_is_uniform_across_vfs_and_ufs(v: i32) -> bool {
    let kind = vpv[v].kind;
    if kind == VVK_REGION { return v == vpb[vpv[v].region].can_iv; }
    if kind == VVK_IR || kind == VVK_SYMBOLIC { return true; }
    let r = vp_def(v);
    if r < 0 { return false; }
    let b = vpr[r].parent;
    if b >= 0 && (b == vp_vector_preheader() || b == vph.entry) {
        if vp_is_vpi(r, VPI_CANONICAL_IV_INCREMENT_FOR_PART) { return false; }
        for i in vp_nops(r) { if !vp_is_uniform_across_vfs_and_ufs(vp_op(r, i)) { return false; } }
        return true;
    }
    let k = vpr[r].kind;
    if k == VPR_DERIVED_IV { return true; }
    if k == VPR_REPLICATE {
        let ui = vp_underlying_instr(r);
        if !(vpr[r].single_scalar && iop(ui) != OP_ALLOCA &&
             (!vp_may_have_side_effects(r) || (iop(ui) == OP_CALL && call_iid(ui) == IID_assume) || iop(ui) == OP_STORE)) { return false; }
        for i in vp_nops(r) { if !vp_is_uniform_across_vfs_and_ufs(vp_op(r, i)) { return false; } }
        return true;
    }
    if k == VPR_WIDEN {
        if !vp_preserves_uniformity(vpr[r].opcode) { return false; }
        for i in vp_nops(r) { if !vp_is_uniform_across_vfs_and_ufs(vp_op(r, i)) { return false; } }
        return true;
    }
    if vp_is_vp_phi(r) { return false; }
    if k == VPR_INSTRUCTION {
        if !(vpi_is_single_scalar(r) || vpi_is_vector_to_scalar(r) || vp_preserves_uniformity(vpr[r].opcode)) { return false; }
        for i in vp_nops(r) { if !vp_is_uniform_across_vfs_and_ufs(vp_op(r, i)) { return false; } }
        return true;
    }
    if k == VPR_WIDEN_CAST { return vp_is_uniform_across_vfs_and_ufs(vp_op(r, 0)); }
    return false;
}

// vputils::getIntrinsicID of a recipe (0 = not an intrinsic)
fn vp_intrinsic_id(r: i32) -> i32 {
    let k = vpr[r].kind;
    if k == VPR_WIDEN_INTRINSIC || k == VPR_WIDEN_MEM_INTRINSIC { return vpr[r].iid; }
    fn callee_iid(c: i32) -> i32 {
        if !vp_is_ir_value(c) { return 0; }
        let f = vp_ir(c);
        if vals[f].kind != VK_FUNC { return 0; }
        return func_iid(f) as i32;
    }
    if k == VPR_WIDEN_CALL { return callee_iid(vp_op(r, vp_nops(r) - 1)); }
    if k == VPR_REPLICATE && iop(vp_underlying_instr(r)) == OP_CALL { return callee_iid(vp_op(r, vpm_num_ops_without_mask(r) - 1)); }
    if k == VPR_INSTRUCTION {
        if vpr[r].opcode == OP_CALL as i32 { return callee_iid(vp_op(r, vp_num_operands_for_opcode(r) - 1)); }
        if vpr[r].opcode == VPI_INTRINSIC { return cint_lo(vp_ir(vp_op(r, vp_nops(r) - 1))) as i32; }
    }
    return 0;
}
// m_Intrinsic matches VPWidenIntrinsicRecipe, VPWidenCallRecipe, VPReplicateRecipe of a call and VPInstruction calls
fn vp_is_intrinsic_match_kind(r: i32) -> bool {
    let k = vpr[r].kind;
    return k == VPR_WIDEN_INTRINSIC || k == VPR_WIDEN_CALL || k == VPR_REPLICATE || k == VPR_INSTRUCTION;
}
// vputils::cannotHoistOrSinkRecipe
fn vp_cannot_hoist_or_sink_recipe(r: i32, sinking: bool) -> bool {
    if vp_intrinsic_id(r) == IID_assume && vp_is_intrinsic_match_kind(r) { return sinking; }
    if vp_may_have_side_effects(r) || vp_may_read_from_memory(r) || vp_is_phi_recipe(r) { return true; }
    return vpr[r].kind == VPR_REPLICATE && iop(vp_underlying_instr(r)) == OP_ALLOCA;
}
// isDeadRecipe
fn vp_is_dead_recipe(r: i32) -> bool {
    if vpr[r].kind == VPR_REPLICATE && vpr[r].predicated && vp_intrinsic_id(r) == IID_assume { return true; }
    if vp_may_have_side_effects(r) { return false; }
    for k in vp_num_defined_values(r) { if vp_num_users(vp_defined_value(r, k)) != 0 { return false; } }
    return true;
}

// VPRecipeBase::clone: a new unlinked recipe of the same class, operands and payload
fn vp_clone(r: i32) -> i32 {
    let k = vpr[r].kind;
    if k == VPR_EXPRESSION || k == VPR_INTERLEAVE_EVL || k == VPR_REDUCTION_EVL || k == VPR_WIDEN_LOAD_EVL ||
       k == VPR_WIDEN_STORE_EVL || k == VPR_CURRENT_ITERATION_PHI { vp_unported("cloning EVL / expression recipes"); }
    var ops: i32[>..<] = [];
    xv_to(vpr[r].ops, ops);
    var n: i32 = -1;
    if vpr[r].def >= 0 {
        let d = vpr[r].def;
        n = vp_new_single_def(k, ops, vpv[d].ty, vpv[d].uv, vpr[r].dl);
    } else {
        n = vp_new_recipe(k, ops, vpr[r].dl);
        if vpr[r].defs >= 0 {
            for j in xv_len(vpr[r].defs) { let x = xv_get(vpr[r].defs, j); vp_add_multi_def_value(n, vpv[x].uv, vpv[x].ty); }
        }
    }
    // the payload (everything but the links, operands and defined values)
    let keep_ops = vpr[n].ops; let keep_def = vpr[n].def; let keep_defs = vpr[n].defs; let keep_dl = vpr[n].dl;
    vpr[n] = vpr[r];
    vpr[n].ops = keep_ops; vpr[n].def = keep_def; vpr[n].defs = keep_defs; vpr[n].dl = keep_dl;
    vpr[n].parent = -1; vpr[n].prev = -1; vpr[n].next = -1; vpr[n].dead = false;
    vpr[n].md = -1;
    vp_md_copy(n, r);
    if vpr[r].expr_recipes >= 0 { vpr[n].expr_recipes = -1; vp_unported("cloning expression recipes"); }
    return n;
}
