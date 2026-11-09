// The "virtual" queries of VPlan recipes as switches on Vp_Kind: mayReadFromMemory / mayWriteToMemory /
// mayHaveSideEffects / isSafeToSpeculativelyExecute, VPUser::usesFirstLaneOnly / usesScalars / usesFirstPartOnly,
// VPInstruction::isVectorToScalar / isSingleScalar / opcodeMayReadOrWriteFromMemory, vputils::onlyFirstLaneUsed &
// friends, isSingleScalar, isUniformAcrossVFsAndUFs, cannotHoistOrSinkRecipe, isDeadRecipe, and clone().
// Ported from llvm/lib/Transforms/Vectorize/VPlanRecipes.cpp, VPlan.h and VPlanUtils.cpp (LLVM 23.1.5).

// VPInstruction::isVectorToScalar
vpi_is_vector_to_scalar :: (r: Vp_Rec) -> bool {
    o := vr(r).opcode;
    return o == VPI_EXTRACT_LAST_LANE || o == VPI_EXTRACT_PENULTIMATE_ELEMENT || o == vp_opc(.EXTRACTELEMENT) ||
           o == VPI_EXTRACT_LANE || o == VPI_FIRST_ACTIVE_LANE || o == VPI_LAST_ACTIVE_LANE || o == VPI_EXTRACT_LAST_ACTIVE ||
           o == VPI_COMPUTE_REDUCTION_RESULT || o == VPI_ANY_OF || o == VPI_NUM_ACTIVE_LANES;
}
// VPInstruction::isSingleScalar
vpi_is_single_scalar :: (r: Vp_Rec) -> bool {
    o := vr(r).opcode;
    if o == vp_opc(.LOAD) || o == vp_opc(.PHI) || o == VPI_EXPLICIT_VECTOR_LENGTH || o == VPI_RESUME_FOR_EPILOGUE || o == VPI_INTRINSIC return true;
    return vp_opcode_is_cast(o);
}
// VPInstruction::opcodeMayReadOrWriteFromMemory
vpi_opcode_may_read_or_write_memory :: (r: Vp_Rec) -> bool {
    o := vr(r).opcode;
    if vp_is_ir_opcode(o) {
        io := vp_ir_opcode(o);
        if is_binary_op(io) || io == .FNEG || is_cast_op(io) return false;
        if io == {
            case .EXTRACTVALUE; #through; case .INSERTVALUE; #through; case .GEP; #through; case .EXTRACTELEMENT; #through;
            case .INSERTELEMENT; #through; case .FREEZE; #through; case .FCMP; #through; case .ICMP; #through;
            case .SELECT; #through; case .PHI; return false;
            case .CALL;
                f := vp_ir(vp_op(r, vp_called_fn_operand_index(r)));
                return !mem_does_not_access(fn_memory_effects(f));
        }
        return true;
    }
    if o == VPI_INTRINSIC {
        id := vp_intrinsic_id(r);
        return !mem_does_not_access(attr_set_memory(intrinsic_fn_attr_set(id)));
    }
    if o == VPI_COMPUTE_REDUCTION_RESULT || o == VPI_RESUME_FOR_EPILOGUE || o == VPI_NUM_ACTIVE_LANES return true;
    return false;
}

vp_may_write_to_memory :: (r: Vp_Rec) -> bool {
    k := vr(r).kind;
    if k == {
        case .EXPRESSION; vp_unported("VPExpressionRecipe::mayReadOrWriteMemory"); return true;
        case .INSTRUCTION;
            if vr(r).opcode == vp_opc(.LOAD) return false;
            return vpi_opcode_may_read_or_write_memory(r);
        case .INTERLEAVE_EVL; #through; case .INTERLEAVE; return vp_interleave_num_store_operands(r) > 0;
        case .WIDEN_STORE_EVL; #through; case .WIDEN_STORE; return true;
        case .REPLICATE; return may_write_to_memory(vp_underlying_instr(r));
        case .WIDEN_CALL; return !mem_only_reads(fn_memory_effects(vp_ir(vp_op(r, vp_nops(r) - 1))));
        case .WIDEN_MEM_INTRINSIC; #through; case .WIDEN_INTRINSIC; return vr(r).may_write;
        case .ACTIVE_LANE_MASK_PHI; #through; case .CURRENT_ITERATION_PHI; #through; case .BRANCH_ON_MASK; #through;
        case .DERIVED_IV; #through; case .FIRST_ORDER_RECURRENCE_PHI; #through; case .REDUCTION_PHI; #through;
        case .SCALAR_IV_STEPS; #through; case .PRED_INST_PHI; return false;
        case .BLEND; #through; case .REDUCTION_EVL; #through; case .REDUCTION; #through; case .VECTOR_POINTER; #through;
        case .WIDEN_CANONICAL_IV; #through; case .WIDEN_CAST; #through; case .WIDEN_GEP; #through;
        case .WIDEN_INT_OR_FP_INDUCTION; #through; case .WIDEN_LOAD_EVL; #through; case .WIDEN_LOAD; #through;
        case .WIDEN_PHI; #through; case .WIDEN_POINTER_INDUCTION; #through; case .WIDEN; return false;
    }
    return true;
}
vp_may_read_from_memory :: (r: Vp_Rec) -> bool {
    k := vr(r).kind;
    if k == {
        case .EXPRESSION; vp_unported("VPExpressionRecipe::mayReadOrWriteMemory"); return true;
        case .INSTRUCTION; return vpi_opcode_may_read_or_write_memory(r);
        case .WIDEN_LOAD_EVL; #through; case .WIDEN_LOAD; return true;
        case .REPLICATE; return may_read_from_memory(vp_underlying_instr(r));
        case .WIDEN_CALL; return !mem_only_writes(fn_memory_effects(vp_ir(vp_op(r, vp_nops(r) - 1))));
        case .WIDEN_MEM_INTRINSIC; #through; case .WIDEN_INTRINSIC; return vr(r).may_read;
        case .BRANCH_ON_MASK; #through; case .DERIVED_IV; #through; case .CURRENT_ITERATION_PHI; #through;
        case .FIRST_ORDER_RECURRENCE_PHI; #through; case .REDUCTION_PHI; #through; case .PRED_INST_PHI; #through;
        case .SCALAR_IV_STEPS; #through; case .WIDEN_STORE_EVL; #through; case .WIDEN_STORE; return false;
        case .BLEND; #through; case .REDUCTION_EVL; #through; case .REDUCTION; #through; case .VECTOR_POINTER; #through;
        case .WIDEN_CANONICAL_IV; #through; case .WIDEN_CAST; #through; case .WIDEN_GEP; #through;
        case .WIDEN_INT_OR_FP_INDUCTION; #through; case .WIDEN_PHI; #through; case .WIDEN_POINTER_INDUCTION; #through;
        case .WIDEN; return false;
    }
    return true;
}
vp_may_read_or_write_memory :: (r: Vp_Rec) -> bool { return vp_may_read_from_memory(r) || vp_may_write_to_memory(r); }
vp_may_have_side_effects :: (r: Vp_Rec) -> bool {
    k := vr(r).kind;
    if k == {
        case .EXPRESSION; vp_unported("VPExpressionRecipe::mayHaveSideEffects"); return true;
        case .ACTIVE_LANE_MASK_PHI; #through; case .DERIVED_IV; #through; case .CURRENT_ITERATION_PHI; #through;
        case .FIRST_ORDER_RECURRENCE_PHI; #through; case .REDUCTION_PHI; #through; case .PRED_INST_PHI; #through;
        case .VECTOR_END_POINTER; return false;
        case .INSTRUCTION;
            o := vr(r).opcode;
            return vp_may_write_to_memory(r) || o == VPI_BRANCH_ON_COUNT || o == VPI_BRANCH_ON_COND || o == VPI_BRANCH_ON_TWO_CONDS;
        case .WIDEN_CALL;
            f := vp_ir(vp_op(r, vp_nops(r) - 1));
            return vp_may_write_to_memory(r) || !fn_does_not_throw(f) || !fn_will_return(f);
        case .WIDEN_MEM_INTRINSIC; #through; case .WIDEN_INTRINSIC; return vr(r).may_side_effects;
        case .BLEND; #through; case .REDUCTION_EVL; #through; case .REDUCTION; #through; case .SCALAR_IV_STEPS; #through;
        case .VECTOR_POINTER; #through; case .WIDEN_CANONICAL_IV; #through; case .WIDEN_CAST; #through; case .WIDEN_GEP; #through;
        case .WIDEN_INT_OR_FP_INDUCTION; #through; case .WIDEN_PHI; #through; case .WIDEN_POINTER_INDUCTION; #through;
        case .WIDEN; return false;
        case .INTERLEAVE_EVL; #through; case .INTERLEAVE; return vp_may_write_to_memory(r);
        case .WIDEN_LOAD_EVL; #through; case .WIDEN_LOAD; #through; case .WIDEN_STORE_EVL; #through; case .WIDEN_STORE;
            return vp_may_write_to_memory(r);
        case .REPLICATE; return may_have_side_effects(vp_underlying_instr(r));
    }
    return true;
}
// VPRecipeBase::isSafeToSpeculativelyExecute
vp_is_safe_to_speculatively_execute :: (r: Vp_Rec) -> bool {
    if vr(r).kind != .INSTRUCTION return false;
    o := vr(r).opcode;
    if vp_opcode_is_cast(o) return true;
    return o == vp_opc(.ADD) || o == vp_opc(.SUB) || o == vp_opc(.MUL) || o == vp_opc(.GEP);
}
vp_interleave_num_store_operands :: (r: Vp_Rec) -> s64 {
    if vr(r).kind == .INTERLEAVE return vp_nops(r) - (ifx vr(r).masked then 2 else 1);
    return vp_nops(r) - (ifx vr(r).masked then 3 else 2);
}

// ---------------------------------------------------------------- operand-use queries

// vputils::propagatesFirstLaneUse
vp_propagates_first_lane_use :: (u: Vp_Rec, op: Vp_Val) -> bool {
    if vr(u).kind == .BLEND return true;
    if vr(u).kind != .INSTRUCTION return false;
    o := vr(u).opcode;
    if o == vp_opc(.FCMP) || o == vp_opc(.ICMP) || o == vp_opc(.SELECT) || o == vp_opc(.FREEZE) || o == VPI_NOT return true;
    if o == VPI_PTR_ADD return op != vp_op(u, 0);
    return vp_is_ir_opcode(o) && (is_binary_op(vp_ir_opcode(o)) || is_cast_op(vp_ir_opcode(o)));
}
// vputils::onlyFirstLaneUsed
vp_only_first_lane_used :: (def: Vp_Val) -> bool {
    wl: [..] Vp_Val; wl.allocator = temp;
    inset: Table(Vp_Val, bool); inset.allocator = temp;
    array_add(*wl, def); table_set(*inset, def, true);
    k := 0;
    while k < wl.count {
        cur := wl[k]; k += 1;
        for u: vv(cur).users {
            if vp_propagates_first_lane_use(u, cur) {
                d := vr(u).def;
                if !table_contains(*inset, d) { table_set(*inset, d, true); array_add(*wl, d); }
            } else if !vp_uses_first_lane_only(u, cur) return false;
        }
    }
    return true;
}
vp_only_first_part_used :: (def: Vp_Val) -> bool {
    for u: vv(def).users if !vp_uses_first_part_only(u, def) return false;
    return true;
}
vp_only_scalar_values_used :: (def: Vp_Val) -> bool {
    for u: vv(def).users if !vp_uses_scalars(u, def) return false;
    return true;
}

// VPUser::usesFirstLaneOnly (per recipe class)
vp_uses_first_lane_only :: (r: Vp_Rec, op: Vp_Val) -> bool {
    k := vr(r).kind;
    if k == {
        case .INSTRUCTION;
            if vp_propagates_first_lane_use(r, op) return vp_only_first_lane_used(vr(r).def);
            o := vr(r).opcode;
            if o == vp_opc(.EXTRACTELEMENT) return op == vp_op(r, 1);
            if o == vp_opc(.INSERTELEMENT) return op == vp_op(r, 1) || op == vp_op(r, 2);
            if o == vp_opc(.PHI) || o == vp_opc(.LOAD) || o == VPI_ACTIVE_LANE_MASK || o == VPI_EXPLICIT_VECTOR_LENGTH ||
               o == VPI_CALCULATE_TRIP_COUNT_MINUS_VF || o == VPI_CANONICAL_IV_INCREMENT_FOR_PART || o == VPI_BRANCH_ON_COUNT ||
               o == VPI_BRANCH_ON_COND || o == VPI_BRANCH_ON_TWO_CONDS || o == VPI_BROADCAST || o == VPI_INTRINSIC ||
               o == VPI_REDUCTION_START_VECTOR || o == VPI_RESUME_FOR_EPILOGUE return true;
            if o == VPI_BUILD_STRUCT_VECTOR || o == VPI_BUILD_VECTOR return vp_nops(r) > 1;
            if o == VPI_PTR_ADD || o == VPI_EXITING_IV_VALUE || o == VPI_EXTRACT_LANE return op == vp_op(r, 0);
            return false;
        case .IR_INSTRUCTION; return true;
        case .WIDEN; return vr(r).opcode == vp_opc(.SELECT) && op == vp_op(r, 0) && vp_is_ir_value(op);
        case .WIDEN_INTRINSIC; #through; case .WIDEN_MEM_INTRINSIC;
            for o, i: vr(r).ops if o == op && !vu_is_vector_intrinsic_with_scalar_op_at_arg(vr(r).iid, cast(u32) i) return false;
            return true;
        case .WIDEN_CALL;
            vty := glob(vr(r).variant).value_type;
            for i: 0..vp_nops(r)-2 {
                if vp_op(r, i) != op continue;
                at := type_sub(vty, cast(u32) (i + 1));
                kk := type_kind(at);
                if !(kk == .INT || is_fp_type(at) || kk == .PTR || kk == .BYTE) return false;
            }
            return true;
        case .WIDEN_GEP; return vp_is_single_scalar(op);
        case .VECTOR_END_POINTER; #through; case .VECTOR_POINTER; return true;
        case .WIDEN_INT_OR_FP_INDUCTION; #through; case .WIDEN_POINTER_INDUCTION; return op == vp_op(r, 0) || op == vp_op(r, 1);
        case .FIRST_ORDER_RECURRENCE_PHI; return op == vp_op(r, 0);
        case .REDUCTION_PHI; return vr(r).rdx_style != .UNORDERED;
        case .BLEND; return vp_only_first_lane_used(vr(r).def);
        case .INTERLEAVE;
            if op != vp_op(r, 0) return false;
            n := vp_interleave_num_store_operands(r);
            base := vp_nops(r) - n - (ifx vr(r).masked then 1 else 0);
            for i: base..base+n-1 if vp_op(r, i) == op return false;
            return true;
        case .INTERLEAVE_EVL; vp_unported("VPInterleaveEVLRecipe"); return false;
        case .REDUCTION_EVL; return op == vp_op(r, 2);
        case .REPLICATE; return vr(r).single_scalar;
        case .WIDEN_LOAD; return op == vp_op(r, 0) && vr(r).consecutive;
        case .WIDEN_LOAD_EVL; return op == vp_op(r, 1) || (op == vp_op(r, 0) && vr(r).consecutive);
        case .WIDEN_STORE; return op == vp_op(r, 0) && vr(r).consecutive && op != vp_op(r, 1);
        case .WIDEN_STORE_EVL;
            if op == vp_op(r, 2) return true;
            return op == vp_op(r, 0) && vr(r).consecutive && op != vp_op(r, 1);
        case .CURRENT_ITERATION_PHI; #through; case .DERIVED_IV; #through; case .SCALAR_IV_STEPS; return true;
    }
    return false;
}
// VPUser::usesScalars
vp_uses_scalars :: (r: Vp_Rec, op: Vp_Val) -> bool {
    k := vr(r).kind;
    if k == .INSTRUCTION && vp_is_instruction_with_type(r) && vp_opcode_is_cast(vr(r).opcode) return true;
    if k == .IR_INSTRUCTION || k == .REPLICATE || k == .BRANCH_ON_MASK return true;
    return vp_uses_first_lane_only(r, op);
}
// VPUser::usesFirstPartOnly
vp_uses_first_part_only :: (r: Vp_Rec, op: Vp_Val) -> bool {
    k := vr(r).kind;
    if k == .INSTRUCTION {
        o := vr(r).opcode;
        if vp_is_ir_opcode(o) && is_binary_op(vp_ir_opcode(o)) return vp_only_first_part_used(vr(r).def);
        if o == vp_opc(.FCMP) || o == vp_opc(.ICMP) || o == vp_opc(.SELECT) return vp_only_first_part_used(vr(r).def);
        return o == VPI_BRANCH_ON_COUNT || o == VPI_BRANCH_ON_COND || o == VPI_BRANCH_ON_TWO_CONDS || o == VPI_CANONICAL_IV_INCREMENT_FOR_PART;
    }
    if k == .IR_INSTRUCTION || k == .VECTOR_END_POINTER || k == .VECTOR_POINTER return true;
    return false;
}

// preservesUniformity
vp_preserves_uniformity :: (o: u16) -> bool {
    if vp_is_ir_opcode(o) {
        io := vp_ir_opcode(o);
        if is_binary_op(io) || is_cast_op(io) return true;
        return io == .FREEZE || io == .GEP || io == .ICMP || io == .FCMP || io == .SELECT;
    }
    return o == VPI_NOT || o == VPI_BROADCAST || o == VPI_MASKED_COND || o == VPI_PTR_ADD;
}
// vputils::isSingleScalar
vp_is_single_scalar :: (v: Vp_Val) -> bool {
    row := vv(v);
    if row.kind == .REGION return v == vb(row.region).can_iv;
    if row.kind == .IR || row.kind == .SYMBOLIC return true;
    r := vp_def(v);
    if r == NONE return false;
    k := vr(r).kind;
    all_ops :: (r: Vp_Rec) -> bool { for vr(r).ops if !vp_is_single_scalar(it) return false; return true; }
    if k == .REPLICATE {
        reg := vp_recipe_region(r);
        if reg != NONE && vp_is_replicator(reg) return false;
        return vr(r).single_scalar || (vp_preserves_uniformity(vp_opc(inst_op(vp_underlying_instr(r)))) && all_ops(r));
    }
    if k == .WIDEN_GEP || k == .BLEND return all_ops(r);
    if k == .WIDEN return vp_preserves_uniformity(vr(r).opcode) && all_ops(r);
    if k == .INSTRUCTION return vpi_is_single_scalar(r) || vpi_is_vector_to_scalar(r) || (vp_preserves_uniformity(vr(r).opcode) && all_ops(r));
    if k == .REDUCTION return vr(r).rdx_scale <= 1;
    if k == .VECTOR_POINTER || k == .VECTOR_END_POINTER || k == .DERIVED_IV return true;
    if k == .EXPRESSION { vp_unported("VPExpressionRecipe::isVectorToScalar"); return false; }
    return k == .EXPAND_SCEV;
}
// vputils::isUniformAcrossVFsAndUFs
vp_is_uniform_across_vfs_and_ufs :: (v: Vp_Val) -> bool {
    row := vv(v);
    if row.kind == .REGION return v == vb(row.region).can_iv;
    if row.kind == .IR || row.kind == .SYMBOLIC return true;
    r := vp_def(v);
    all_ops :: (r: Vp_Rec) -> bool { for vr(r).ops if !vp_is_uniform_across_vfs_and_ufs(it) return false; return true; }
    if r != NONE {
        b := vr(r).parent;
        if b != NONE && (b == vp_vector_preheader() || b == vpl.entry) {
            if vp_is_vpi(r, VPI_CANONICAL_IV_INCREMENT_FOR_PART) return false;
            return all_ops(r);
        }
    }
    if r == NONE return false;
    k := vr(r).kind;
    if k == .DERIVED_IV return true;
    if k == .REPLICATE {
        ui := vp_underlying_instr(r);
        return vr(r).single_scalar && inst_op(ui) != .ALLOCA &&
               (!vp_may_have_side_effects(r) || call_iid(ui) == IID_ASSUME || inst_op(ui) == .STORE) && all_ops(r);
    }
    if k == .WIDEN return vp_preserves_uniformity(vr(r).opcode) && all_ops(r);
    if vp_is_vp_phi(r) return false;
    if k == .INSTRUCTION return (vpi_is_single_scalar(r) || vpi_is_vector_to_scalar(r) || vp_preserves_uniformity(vr(r).opcode)) && all_ops(r);
    if k == .WIDEN_CAST return vp_is_uniform_across_vfs_and_ufs(vp_op(r, 0));
    return false;
}
// vputils::cannotHoistOrSinkRecipe
vp_cannot_hoist_or_sink_recipe :: (r: Vp_Rec, sinking := false) -> bool {
    if vp_intrinsic_id(r) == IID_ASSUME && vp_is_intrinsic_match_kind(r) return sinking;
    if vp_may_have_side_effects(r) || vp_may_read_from_memory(r) || vp_is_phi_recipe(r) return true;
    return vr(r).kind == .REPLICATE && inst_op(vp_underlying_instr(r)) == .ALLOCA;
}
// m_Intrinsic matches VPWidenIntrinsicRecipe, VPWidenCallRecipe, VPReplicateRecipe of a call and VPInstruction calls
vp_is_intrinsic_match_kind :: (r: Vp_Rec) -> bool {
    k := vr(r).kind;
    return k == .WIDEN_INTRINSIC || k == .WIDEN_CALL || k == .REPLICATE || k == .INSTRUCTION;
}
// isDeadRecipe
vp_is_dead_recipe :: (r: Vp_Rec) -> bool {
    if vr(r).kind == .REPLICATE && vr(r).predicated && vp_intrinsic_id(r) == IID_ASSUME return true;
    if vp_may_have_side_effects(r) return false;
    for k: 0..vp_num_defined_values(r)-1 if vp_num_users(vp_defined_value(r, k)) return false;
    return true;
}

// ---------------------------------------------------------------- clone()

vp_copy_payload :: (dst: Vp_Rec, src: Vp_Rec) {
    s := vr(src); d := vr(dst);
    d.opcode = s.opcode; d.flags = s.flags; d.name = s.name; d.with_type = s.with_type; d.ir_inst = s.ir_inst;
    d.iid = s.iid; d.may_read = s.may_read; d.may_write = s.may_write; d.may_side_effects = s.may_side_effects;
    d.src_elt_ty = s.src_elt_ty; d.stride = s.stride; d.ind = s.ind; d.ind_kind = s.ind_kind; d.fp_binop = s.fp_binop;
    d.ind_opcode = s.ind_opcode; d.rdx_kind = s.rdx_kind; d.rdx_style = s.rdx_style; d.rdx_scale = s.rdx_scale;
    d.has_uses_outside_chain = s.has_uses_outside_chain; d.is_conditional = s.is_conditional;
    d.single_scalar = s.single_scalar; d.predicated = s.predicated; d.align = s.align; d.consecutive = s.consecutive;
    d.masked = s.masked; d.needs_mask_for_gaps = s.needs_mask_for_gaps; d.ig = s.ig; d.expr = s.expr;
    d.variant = s.variant; d.expr_type = s.expr_type;
    for s.md array_add(*d.md, it);
}
// VPRecipeBase::clone: a new unlinked recipe of the same class with the same operands (and underlying value)
vp_clone :: (r: Vp_Rec) -> Vp_Rec {
    k := vr(r).kind;
    if k == .EXPRESSION || k == .INTERLEAVE_EVL || k == .REDUCTION_EVL || k == .WIDEN_LOAD_EVL || k == .WIDEN_STORE_EVL ||
       k == .CURRENT_ITERATION_PHI
        vp_unported(tprint("cloning % recipes", k));
    ops: [..] Vp_Val; ops.allocator = temp;
    for vr(r).ops array_add(*ops, it);
    n: Vp_Rec;
    if vr(r).def != NONE {
        d := vr(r).def;
        uv := vv(d).uv;
        n = vp_new_single_def(k, ops, vv(d).ty, uv, vr(r).dl);
    } else {
        n = vp_new_recipe(k, ops, vr(r).dl);
        for vr(r).defs vp_add_multi_def_value(n, vv(it).uv, vv(it).ty);
    }
    vp_copy_payload(n, r);
    return n;
}

// Intrinsic::getFnAttributes(Ctx, ID)
intrinsic_fn_attr_set :: (id: Intrinsic_Id) -> u32 {
    base := intrinsic_name(id);
    for INTRINSIC_ATTRS if it.name == base return parse_attr_text(it.fn, true);
    fatal("intrinsic '%' has no entry in the generated attribute table (impl/jai/gen/gen_intrinsics.py)", base);
    return 0;
}
