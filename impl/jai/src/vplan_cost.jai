// The VPlan-based cost model: VPCostContext, every recipe's computeCost (the `vp_compute_cost` switch), the block /
// region / plan costs, LoopVectorizationPlanner::precomputeCosts / cost / computeBestVF / isMoreProfitable,
// willGenerateVectors, collectEphemeralRecipesForVPlan, calculateRegisterUsageForPlan and selectInterleaveCount.
// Ported from llvm/lib/Transforms/Vectorize/VPlanRecipes.cpp (computeCost), VPlan.cpp (VPBasicBlock / VPRegionBlock /
// VPlan::cost, VPCostContext), VPlanAnalysis.cpp, LoopVectorize.cpp and LoopVectorizationPlanner.cpp (LLVM 23.1.5).

Vp_Cost_Ctx :: struct {
    lp: *Lv_Planner;
    cm: *Lv_Cm;
    tti: *Tti;
    kind: s64;
    skip: Iset;                    // SkipCostComputation
    num_pred_stores: s64 = -1;     // std::optional<unsigned> NumPredStores (-1 = not computed)
}
vpc_init :: (c: *Vp_Cost_Ctx, lp: *Lv_Planner) {
    c.lp = lp; c.cm = lp.cm; c.tti = lp.cm.tti; c.kind = lp.cm.cost_kind;
    c.skip = iset_new();
}

// VPCostContext::getLegacyCost
vpc_legacy_cost :: (c: *Vp_Cost_Ctx, ui: Value_Id, vf: Ec) -> Cost {
    cost := lv_cm_instruction_cost(c.cm, ui, vf);
    if cost_valid(cost) && lv_opts.force_target_instruction_cost.set return lv_forced_cost();
    return cost;
}
// VPCostContext::skipCostComputation
vpc_skip :: (c: *Vp_Cost_Ctx, ui: Value_Id, is_vector: bool) -> bool {
    return iset_has(*c.cm.values_to_ignore, ui) || (is_vector && iset_has(*c.cm.vec_values_to_ignore, ui)) || iset_has(*c.skip, ui);
}
// VPCostContext::willBeScalarized
vpc_will_be_scalarized :: (c: *Vp_Cost_Ctx, i: Value_Id, vf: Ec) -> bool {
    cm := c.cm;
    return lv_cm_is_scalar_with_predication(cm, i, vf) || lv_cm_is_uniform_after_vectorization(cm, i, vf) ||
           lv_cm_is_forced_scalar(cm, i, vf) || (ec_is_vector(vf) && lv_cm_is_profitable_to_scalarize(cm, i, vf));
}
// VPCostContext::getOperandInfo
vpc_operand_info :: (v: Vp_Val) -> Op_Info {
    if v != NONE && vp_is_ir_value(v) return tti_operand_info(vp_ir(v));
    return OI_ANY;
}
// VPCostContext::isFreeScalarIntrinsic
vpc_is_free_scalar_intrinsic :: (id: Intrinsic_Id) -> bool {
    return id == IID_ASSUME || id == IID_LIFETIME_END || id == IID_LIFETIME_START || id == IID_SIDEEFFECT ||
           id == IID_PSEUDOPROBE || id == IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL;
}
// VPCostContext::getScalarizationOverhead
vpc_scalarization_overhead :: (c: *Vp_Cost_Ctx, result_ty: Type_Id, ops: [] Vp_Val, vf: Ec, always_include_replicating := false) -> Cost {
    if ec_is_scalar(vf) return 0;
    assert(!vf.scalable, "Scalarization overhead not supported for scalable vectors");
    sc: Cost = 0;
    if type_kind(result_ty) != .VOID
        sc = lc_add(sc, lv_tti_scalarization_overhead_all(c.tti, lv_to_vectorized_ty(result_ty, vf), true, false, c.kind));
    seen: [..] Vp_Val; seen.allocator = temp;
    tys: [..] Type_Id; tys.allocator = temp;
    for o: ops {
        if vp_is_ir_value(o) continue;
        d := vp_def(o);
        is_rep := d != NONE && vr(d).kind == .REPLICATE;
        if !always_include_replicating && d != NONE && (is_rep || vr(d).kind == .PRED_INST_PHI) continue;
        if is_rep && inst_op(vp_underlying_instr(d)) == .LOAD continue;
        if array_find(seen, o) continue;
        array_add(*seen, o);
        array_add(*tys, lv_to_vectorized_ty(vp_scalar_type(o), vf));
    }
    return lc_add(sc, lv_tti_operands_scalarization_overhead(c.tti, tys, c.kind));
}
// VPCostContext::useEmulatedMaskMemRefHack
vpc_use_emulated_mask_mem_ref_hack :: (c: *Vp_Cost_Ctx, r: Vp_Rec, vf: Ec) -> bool {
    ui := vp_underlying_instr(r);
    if inst_op(ui) == .LOAD return true;
    if c.num_pred_stores < 0 {
        c.num_pred_stores = 0;
        for reg: vp_blocks_only_region(vp_depth_first_shallow(vb(vp_vector_loop_region()).entry)) {
            for bb: vp_blocks_only_basic(vp_depth_first_shallow(vb(reg).entry)) for rr: vp_block_recipes(bb) {
                if vr(rr).kind != .REPLICATE || inst_op(vp_underlying_instr(rr)) != .STORE continue;
                vty := type_vector(vf.n, vp_scalar_type(vp_op(rr, 0)), vf.scalable);
                if !lv_tti_is_legal_masked_scatter(c.tti, vty, load_store_align(vp_underlying_instr(rr))) c.num_pred_stores += 1;
            }
        }
    }
    return c.num_pred_stores > lv_opts.num_stores_to_predicate;
}
// VPCostContext::getPredBlockCostDivisor
vpc_pred_block_cost_divisor :: (c: *Vp_Cost_Ctx, bb: Value_Id) -> u64 { return lv_cm_pred_block_cost_divisor(c.cm, bb); }

// the underlying instruction a recipe's cost is keyed by (VPRecipeBase::cost)
vp_recipe_cost_instr :: (r: Vp_Rec) -> Value_Id {
    k := vr(r).kind;
    if vp_is_single_def_kind(k) {
        d := vr(r).def;
        if d == NONE return NONE;
        u := vv(d).uv;
        if u != NONE && is_inst(u) return u;
        return NONE;
    }
    if k == .INTERLEAVE || k == .INTERLEAVE_EVL return vr(r).ir_inst;
    if vp_is_widen_memory_kind(k) return vr(r).ir_inst;
    return NONE;
}

// VPRecipeBase::cost
vp_recipe_cost :: (c: *Vp_Cost_Ctx, r: Vp_Rec, vf: Ec) -> Cost {
    ui := vp_recipe_cost_instr(r);
    cost: Cost;
    if ui != NONE && vpc_skip(c, ui, ec_is_vector(vf)) {
        cost = 0;
    } else {
        cost = vp_compute_cost(c, r, vf);
        if lv_opts.force_target_instruction_cost.set && cost_valid(cost) {
            cost = ifx ui != NONE then lv_forced_cost() else 0;
        }
    }
    lv_dbg("Cost of % for VF %: %\n", lc_str(cost), lv_ec_str(vf), vp_recipe_str(r));
    return cost;
}

// VPRecipeWithIRFlags::getCostForRecipeWithOpcode
vp_cost_for_recipe_with_opcode :: (c: *Vp_Cost_Ctx, r: Vp_Rec, opcode: u16, vf: Ec) -> Cost {
    t := c.tti; kind := c.kind;
    scalar_ty := vp_scalar_type(vr(r).def);
    result_ty := ifx ec_is_vector(vf) then lv_to_vector_ty(scalar_ty, vf) else scalar_ty;
    uv := vp_uv(vr(r).def);
    ctx_i: Value_Id = ifx uv != NONE && is_inst(uv) then uv else NONE;
    opc := vp_ir_opcode(opcode);
    if opc == {
    case .FNEG;
        return lt_arith_cost(t, .FNEG, result_ty, kind);
    case .UDIV; #through; case .SDIV; #through; case .SREM; #through; case .UREM; #through; case .ADD; #through;
    case .FADD; #through; case .SUB; #through; case .FSUB; #through; case .MUL; #through; case .FMUL; #through;
    case .FDIV; #through; case .FREM; #through; case .SHL; #through; case .LSHR; #through; case .ASHR; #through;
    case .AND; #through; case .OR; #through; case .XOR;
        rhs := vp_op(r, 1);
        rhs_info := vpc_operand_info(rhs);
        if rhs_info.kind == OK_ANY_VALUE && vp_is_defined_outside_loop_regions(rhs) rhs_info.kind = OK_UNIFORM_VALUE;
        args: [] Value_Id;
        if ctx_i != NONE args = lv_inst_operands(ctx_i, false);
        return lt_arith_cost(t, opc, result_ty, kind, OI_ANY, rhs_info, args, ctx_i);
    case .FREEZE;
        return TCC_FREE;
    case .EXTRACTVALUE;
        return lt_insert_extract_value_cost(t, .EXTRACTVALUE, kind);
    case .ICMP; #through; case .FCMP;
        sop := vp_scalar_type(vp_op(r, 0));
        op_ty := ifx ec_is_vector(vf) then lv_to_vector_ty(sop, vf) else sop;
        return lt_cmp_sel_cost(t, opc, op_ty, lv_cmp_result_type(op_ty), vr(r).flags.pred, kind, OI_ANY, OI_ANY, ctx_i);
    case .BITCAST;
        if type_kind(scalar_ty) == .PTR return 0;
        return vp_cast_recipe_cost(c, r, opc, vf, result_ty);
    case .SEXT; #through; case .ZEXT; #through; case .FPTOUI; #through; case .FPTOSI; #through; case .FPEXT; #through;
    case .PTRTOINT; #through; case .PTRTOADDR; #through; case .INTTOPTR; #through; case .SITOFP; #through;
    case .UITOFP; #through; case .TRUNC; #through; case .FPTRUNC; #through; case .ADDRSPACECAST;
        return vp_cast_recipe_cost(c, r, opc, vf, result_ty);
    case .SELECT;
        return vp_select_recipe_cost(c, r, vf, result_ty);
    }
    fatal("internal: getCostForRecipeWithOpcode called for unsupported opcode %", opc);
    return COST_INVALID;
}

vp_cast_recipe_cost :: (c: *Vp_Cost_Ctx, r: Vp_Rec, opc: Opcode, vf: Ec, result_ty: Type_Id) -> Cost {
    compute_cch :: (rr: Vp_Rec, vf: Ec) -> u8 {
        k := vr(rr).kind;
        if k == .INTERLEAVE || k == .INTERLEAVE_EVL return CCH_INTERLEAVE;
        if k == .REPLICATE {
            ui := vp_underlying_instr(rr);
            if inst_op(ui) != .LOAD && inst_op(ui) != .STORE return CCH_NONE;
            return ifx vr(rr).predicated then cast(u8) CCH_MASKED else CCH_NORMAL;
        }
        if !vp_is_widen_memory_kind(k) return CCH_NONE;
        if ec_is_scalar(vf) return CCH_NORMAL;
        if !vr(rr).consecutive return CCH_GATHER_SCATTER;
        if vr(rr).masked return CCH_MASKED;
        return CCH_NORMAL;
    }
    is_reverse_r :: (rr: Vp_Rec) -> (bool, Vp_Val) {
        if vpm_vpi_r(rr, VPI_REVERSE, 1) return true, vp_op(rr, 0);
        if vr(rr).kind == .WIDEN_INTRINSIC && vr(rr).iid == iidn("llvm.experimental.vp.reverse") return true, vp_op(rr, 0);
        return false, NONE;
    }
    operand := vp_op(r, 0);
    cch: u8 = CCH_NONE;
    is_reverse := false;
    if opc == .TRUNC || opc == .FPTRUNC {
        rr := vp_single_user(vr(r).def);
        if rr != NONE {
            rev, _ := is_reverse_r(rr);
            if rev {
                is_reverse = true;
                rd := vr(rr).def;
                rr = ifx rd != NONE then vp_single_user(rd) else NONE;
            }
            if rr != NONE cch = compute_cch(rr, vf);
        }
    } else if opc == .ZEXT || opc == .SEXT || opc == .FPEXT {
        rr := vp_def(operand);
        if rr != NONE {
            rev, rop := is_reverse_r(rr);
            if rev { rr = vp_def(rop); is_reverse = true; }
            if rr != NONE cch = compute_cch(rr, vf);
        }
    }
    if is_reverse && cch != CCH_NONE cch = CCH_REVERSED;
    ssrc := vp_scalar_type(operand);
    src_ty := ifx ec_is_vector(vf) then lv_to_vector_ty(ssrc, vf) else ssrc;
    uv := vp_uv(vr(r).def);
    return lt_cast_cost(c.tti, opc, result_ty, src_ty, cch, c.kind, ifx uv != NONE && is_inst(uv) then uv else NONE);
}

vp_select_recipe_cost :: (c: *Vp_Cost_Ctx, r: Vp_Rec, vf: Ec, result_ty: Type_Id) -> Cost {
    t := c.tti; kind := c.kind;
    uv := vp_uv(vr(r).def);
    si: Value_Id = ifx uv != NONE && is_inst(uv) && inst_op(uv) == .SELECT then uv else NONE;
    s0 := vp_op(r, 0); s1 := vp_op(r, 1); s2 := vp_op(r, 2);
    is_scalar_cond := vp_is_defined_outside_loop_regions(s0);
    scalar_ty := vp_scalar_type(vr(r).def);
    // the matchers bind their operands as they go (later matchers overwrite earlier bindings, even when they fail)
    o0: Vp_Val = NONE; o1: Vp_Val = NONE;
    // m_c_LogicalAnd: m_Select(Op0, Op1, m_False()) | m_Select(m_Not(Op0), m_False(), Op1)
    is_and := false;
    o0 = s0; o1 = s1;
    if vpm_is_false(s2) is_and = true;
    else {
        okn, x := vpm_not(s0);
        if okn { o0 = x; if vpm_is_false(s1) { o1 = s2; is_and = true; } }
    }
    // m_c_LogicalOr: m_Select(Op0, m_True(), Op1) | m_Select(m_Not(Op0), Op1, m_True())
    is_or := false;
    o0 = s0;
    if vpm_is_true(s1) { o1 = s2; is_or = true; }
    else {
        okn, x := vpm_not(s0);
        if okn { o0 = x; o1 = s1; if vpm_is_true(s2) is_or = true; }
    }
    // m_Select(Op0, m_False(), Op1)
    o0 = s0;
    if vpm_is_false(s1) { o1 = s2; is_and = true; }
    // m_Select(Op0, Op1, m_True())
    o0 = s0; o1 = s1;
    if vpm_is_true(s2) is_or = true;
    if !is_scalar_cond && type_bits(scalar_type(scalar_ty)) == 1 && (is_and || is_or) {
        args: [] Value_Id;
        if si != NONE {
            all := true;
            for vr(r).ops if vp_uv(it) == NONE { all = false; break; }
            if all args = lv_inst_operands(si, false);
        }
        return lt_arith_cost(t, ifx is_or then Opcode.OR else .AND, result_ty, kind, vpc_operand_info(o0), vpc_operand_info(o1), args, si);
    }
    cond_ty := vp_scalar_type(s0);
    if !is_scalar_cond && ec_is_vector(vf) cond_ty = type_vector(vf.n, cond_ty, vf.scalable);
    pred: u8 = BAD_ICMP_PREDICATE;
    okc, _, _ := vpm_cmp(s0);
    if okc pred = vr(vp_def(s0)).flags.pred;
    else if vp_is_ir_value(s0) {
        x := vp_ir(s0);
        if is_inst(x) && (inst_op(x) == .ICMP || inst_op(x) == .FCMP) pred = inst_pred(x);
    }
    vty := lv_to_vector_ty(scalar_ty, vf);
    return lt_cmp_sel_cost(t, .SELECT, vty, cond_ty, pred, kind, OI_ANY, OI_ANY, si);
}

// the `computeCost` virtual: one case per recipe class
vp_compute_cost :: (c: *Vp_Cost_Ctx, r: Vp_Rec, vf: Ec) -> Cost {
    t := c.tti; kind := c.kind;
    k := vr(r).kind;
    if k == {
    case .INSTRUCTION;
        if vp_is_instruction_with_type(r) return vp_instruction_with_type_cost(c, r, vf);
        return vp_instruction_cost(c, r, vf);
    case .IR_INSTRUCTION; return 0;
    case .WIDEN; return vp_cost_for_recipe_with_opcode(c, r, vr(r).opcode, vf);
    case .WIDEN_CAST; return vp_cost_for_recipe_with_opcode(c, r, vr(r).opcode, vf);
    case .WIDEN_GEP; #through; case .VECTOR_END_POINTER; #through; case .VECTOR_POINTER; #through;
    case .PRED_INST_PHI; #through; case .EXPAND_SCEV; #through; case .CURRENT_ITERATION_PHI; #through;
    case .WIDEN_CANONICAL_IV; #through; case .BRANCH_ON_MASK;
        return 0;
    case .WIDEN_INT_OR_FP_INDUCTION; #through; case .WIDEN_POINTER_INDUCTION; #through; case .REDUCTION_PHI; #through;
    case .ACTIVE_LANE_MASK_PHI; #through; case .WIDEN_PHI;
        return lt_cf_cost(t, .PHI, kind);
    case .FIRST_ORDER_RECURRENCE_PHI;
        if ec_is_scalar(vf) return lt_cf_cost(t, .PHI, kind);
        return 0;
    case .DERIVED_IV; return vp_derived_iv_cost(c, r, vf);
    case .SCALAR_IV_STEPS; return vp_scalar_iv_steps_cost(c, r, vf);
    case .BLEND;
        bvf := vf;
        if vp_only_first_lane_used(vr(r).def) bvf = ec_fixed(1);
        res_ty := lv_to_vector_ty(vp_scalar_type(vr(r).def), bvf);
        cmp_ty := lv_to_vector_ty(type_int(1), bvf);
        return lc_mul(lt_cmp_sel_cost(t, .SELECT, res_ty, cmp_ty, BAD_ICMP_PREDICATE, kind), vp_blend_num_incoming(r) - 1);
    case .REPLICATE; return vp_replicate_cost(c, r, vf);
    case .WIDEN_LOAD; #through; case .WIDEN_STORE; #through; case .WIDEN_LOAD_EVL; #through; case .WIDEN_STORE_EVL;
        return vp_widen_memory_cost(c, r, vf);
    case .WIDEN_INTRINSIC;
        return vp_widen_intrinsic_call_cost(c, vr(r).iid, vr(r).ops, r, vf);
    case .WIDEN_MEM_INTRINSIC;
        ty := lv_to_vector_ty(vp_scalar_type(vr(r).def), vf);
        return lv_tti_mem_intrinsic_cost(t, iid_name(vr(r).iid), ty, NONE, !vpm_is_true(vp_op(r, 2)), vr(r).align, 0, kind);
    case .WIDEN_CALL;
        return vp_widen_call_cost(c, vr(r).variant);
    case .REDUCTION;
        return vp_reduction_cost(c, r, vf);
    case .INTERLEAVE; return vp_interleave_cost(c, r, vf);
    case .INTERLEAVE_EVL; vp_unported("EVL interleave group costs");
    case .HISTOGRAM; vp_unported("histogram costs");
    case .EXPRESSION; vp_unported("VPExpressionRecipe::computeCost");
    case .REDUCTION_EVL; vp_unported("EVL reduction costs");
    }
    fatal("internal: computeCost of %", k);
    return COST_INVALID;
}

// VPInstruction::computeCost
vp_instruction_cost :: (c: *Vp_Cost_Ctx, r: Vp_Rec, vf: Ec) -> Cost {
    t := c.tti; kind := c.kind;
    o := vr(r).opcode;
    first_lane := vp_only_first_lane_used(vr(r).def);
    if vp_is_ir_opcode(o) && is_binary_op(vp_ir_opcode(o)) {
        if vp_uv(vr(r).def) == NONE && vp_ir_opcode(o) != .FMUL return 0;
        return vp_cost_for_recipe_with_opcode(c, r, o, ifx first_lane then ec_fixed(1) else vf);
    }
    if o == {
    case cast(u16) Opcode.SELECT;
        pred: u8 = BAD_ICMP_PREDICATE;
        okc, _, _ := vpm_cmp(vp_op(r, 0));
        if okc pred = vr(vp_def(vp_op(r, 0))).flags.pred;
        cond_ty := vp_scalar_type(vp_op(r, 0));
        vec_ty := vp_scalar_type(vp_op(r, 1));
        if !first_lane { cond_ty = lv_to_vector_ty(cond_ty, vf); vec_ty = lv_to_vector_ty(vec_ty, vf); }
        return lt_cmp_sel_cost(t, .SELECT, vec_ty, cond_ty, pred, kind);
    case cast(u16) Opcode.EXTRACTELEMENT; #through;
    case VPI_EXTRACT_LANE;
        if ec_is_scalar(vf) return 0;
        vty := lv_to_vector_ty(vp_scalar_type(vp_op(r, 0)), vf);
        return lt_vector_instr_cost(t, .EXTRACTELEMENT, vty, kind, U32_NONE);
    case VPI_ANY_OF;
        vty := lv_to_vector_ty(vp_scalar_type(vr(r).def), vf);
        return lt_arithmetic_reduction_cost(t, .OR, vty, false, 0, kind);
    case VPI_FIRST_ACTIVE_LANE; #through; case VPI_LAST_ACTIVE_LANE;
        sty := vp_scalar_type(vp_op(r, 0));
        if ec_is_scalar(vf) return lt_cmp_sel_cost(t, .ICMP, sty, lv_cmp_result_type(sty), ICMP_EQ, kind);
        pty := lv_to_vector_ty(sty, vf);
        rty := vp_scalar_type(vr(r).def);
        a := ica_types(IID_EXPERIMENTAL_CTTZ_ELTS, rty, .[pty, type_int(1)]);
        cst := lt_intrinsic_cost(t, *a, kind);
        if o == VPI_LAST_ACTIVE_LANE {
            cst = lc_add(cst, lt_arith_cost(t, .XOR, pty, kind, OI_ANY, Op_Info.{OK_UNIFORM_CONSTANT_VALUE, OP_NONE}));
            cst = lc_add(cst, lt_arith_cost(t, .SUB, rty, kind));
        }
        return cst;
    case VPI_EXTRACT_LAST_ACTIVE;
        sty := vp_scalar_type(vr(r).def);
        vty := lv_to_vector_ty(sty, vf);
        mty := lv_to_vector_ty(type_int(1), vf);
        a := ica_types(iidn("llvm.experimental.vector.extract.last.active"), sty, .[vty, mty, sty]);
        return lt_intrinsic_cost(t, *a, kind);
    case VPI_FIRST_ORDER_RECURRENCE_SPLICE;
        vty := lv_to_vector_ty(vp_scalar_type(vr(r).def), vf);
        return lv_tti_shuffle(t, SK_SPLICE, vty, kind, -1);
    case VPI_ACTIVE_LANE_MASK; vp_unported("active lane mask costs");
    case VPI_EXPLICIT_VECTOR_LENGTH; vp_unported("EVL costs");
    case VPI_REVERSE;
        ety := vp_scalar_type(vr(r).def);
        if type_kind(ety) == .INT && type_bits(ety) == 1 return 0;
        vty := lv_to_vector_ty(ety, vf);
        return lv_tti_shuffle(t, SK_REVERSE, vty, kind, 0);
    case VPI_EXTRACT_LAST_LANE;
        vty := lv_to_vector_ty(vp_scalar_type(vp_op(r, 0)), vf);
        return lv_tti_vector_instr_cost_from_end(t, .EXTRACTELEMENT, vty, kind, 0);
    case VPI_NOT;
        val_ty := vp_scalar_type(vr(r).def);
        u := vp_single_user(vr(r).def);
        if u != NONE { okb, _ := vpm_branch_on_cond(u); if okb return 0; }
        if !first_lane val_ty = lv_to_vector_ty(val_ty, vf);
        return lt_arith_cost(t, .XOR, val_ty, kind);
    case VPI_BRANCH_ON_COUNT;
        tc := vp_uv(vpl.trip_count);
        if tc != NONE && vkind(tc) == .C_INT && ap_ule_u64(const_ap(tc), vf.n) return 0;
        vt := vp_scalar_type(vp_op(r, 0));
        return lt_cmp_sel_cost(t, .ICMP, vt, lv_cmp_result_type(vt), ICMP_EQ, kind);
    case cast(u16) Opcode.FCMP; #through; case cast(u16) Opcode.ICMP;
        return vp_cost_for_recipe_with_opcode(c, r, o, ifx first_lane then ec_fixed(1) else vf);
    case VPI_EXTRACT_PENULTIMATE_ELEMENT;
        if vf.scalable && vf.n == 1 return COST_INVALID;
    }
    return 0;
}

// VPInstructionWithType::computeCost
vp_instruction_with_type_cost :: (c: *Vp_Cost_Ctx, r: Vp_Rec, vf: Ec) -> Cost {
    o := vr(r).opcode;
    if vp_opcode_is_cast(o) return vp_cost_for_recipe_with_opcode(c, r, o, ec_fixed(1));
    if o == VPI_STEP_VECTOR return 0;
    if o == VPI_INTRINSIC {
        tys: [..] Type_Id; tys.allocator = temp;
        for k: 0..vp_nops(r) - 2 array_add(*tys, vp_scalar_type(vp_op(r, k)));
        a := ica_types(vp_intrinsic_id(r), vp_scalar_type(vr(r).def), tys);
        return lt_intrinsic_cost(c.tti, *a, c.kind);
    }
    fatal("internal: VPInstructionWithType::computeCost: unhandled opcode %", vp_opcode_name(o));
    return COST_INVALID;
}

// VPDerivedIVRecipe::computeCost
vp_derived_iv_cost :: (c: *Vp_Cost_Ctx, r: Vp_Rec, vf: Ec) -> Cost {
    if vr(r).ind_kind != .INT return 0;
    if !vp_only_first_lane_used(vr(r).def) return 0;
    t := c.tti; kind := c.kind;
    start := vp_op(r, 0); index := vp_op(r, 1); step := vp_op(r, 2);
    needs_mul := true; needs_add := true; needs_shl := false;
    if vp_is_constant_int(start) needs_add = !vp_is_const_int_zero(start);
    step_ty := vp_scalar_type(step);
    cost: Cost = 0;
    if vp_is_constant_int(step) {
        a := vp_const_int_value(step);
        if ap_is_one(a) needs_mul = false;
        else if ap_is_all_ones(a) { needs_mul = false; needs_add = true; }
        else if ap_is_power_of_2(a) { needs_mul = false; needs_shl = true; }
    }
    index_ty := vp_scalar_type(index);
    sts := type_bits(scalar_type(step_ty)); its := type_bits(scalar_type(index_ty));
    if (needs_add || needs_mul || needs_shl) && sts != its {
        opc := ifx sts < its then Opcode.TRUNC else .SEXT;
        cost = lc_add(cost, lt_cast_cost(t, opc, step_ty, index_ty, CCH_NONE, kind));
    }
    if needs_mul cost = lc_add(cost, lt_arith_cost(t, .MUL, step_ty, kind));
    if needs_shl cost = lc_add(cost, lt_arith_cost(t, .SHL, step_ty, kind, OI_ANY, .{OK_UNIFORM_CONSTANT_VALUE, OP_NONE}));
    if needs_add cost = lc_add(cost, lt_arith_cost(t, .ADD, step_ty, kind));
    return cost;
}

// VPScalarIVStepsRecipe::computeCost
vp_scalar_iv_steps_cost :: (c: *Vp_Cost_Ctx, r: Vp_Rec, vf: Ec) -> Cost {
    base_ty := vp_scalar_type(vp_op(r, 0));
    if type_kind(base_ty) != .INT return 0;
    reg := vp_recipe_region(r);
    if reg != NONE && vp_is_replicator(reg) return 0;
    if vp_only_first_lane_used(vr(r).def) return 0;
    return lt_arith_cost(c.tti, .ADD, base_ty, c.kind);
}

// VPReductionRecipe::computeCost (partial reductions are never formed: X86 and the base model have no
// partial-reduction costs)
vp_reduction_cost :: (c: *Vp_Cost_Ctx, r: Vp_Rec, vf: Ec) -> Cost {
    rk := vr(r).rdx_kind;
    ety := vp_scalar_type(vr(r).def);
    vty := lv_to_vector_ty(ety, vf);
    fmf := vp_fmf_or_none(r);
    if rk_is_min_max(rk) return lt_min_max_reduction_cost(c.tti, lv_min_max_reduction_intrinsic(rk), vty, fmf, c.kind);
    return lt_arithmetic_reduction_cost(c.tti, rk_opcode(rk), vty, is_fp_type(ety), fmf, c.kind);
}

// VPReplicateRecipe::computeCallCost
vp_replicate_call_cost :: (c: *Vp_Cost_Ctx, called: Value_Id, result_ty: Type_Id, args: [] Vp_Val, single: bool, vf: Ec) -> Cost {
    tys := NewArray(args.count, Type_Id,, allocator = temp);
    for args tys[it_index] = vp_scalar_type(it);
    id := ifx called != NONE && vkind(called) == .FUNCTION && glob(called).intrinsic then fn_iid(called) else NOT_INTRINSIC;
    if id != NOT_INTRINSIC && vpc_is_free_scalar_intrinsic(id) return 0;
    scalar_call := lv_tti_call_instr_cost(c.tti);
    if single {
        ic := COST_INVALID;
        if id != NOT_INTRINSIC { a := ica_types(id, result_ty, tys); ic = lt_intrinsic_cost(c.tti, *a, c.kind); }
        return ifx ic < scalar_call then ic else scalar_call;
    }
    if vf.scalable return COST_INVALID;
    return lc_add(lc_mul(scalar_call, cast(s64) vf.n), vpc_scalarization_overhead(c, result_ty, args, vf));
}

// getAddressAccessSCEV (the VPlan version): SCEV_NULL when not an address SCEV, SCEV_CNC when it cannot be computed
vp_address_access_scev :: (c: *Vp_Cost_Ctx, ptr: Vp_Val) -> Scev_Id {
    a := vp_scev_for_value(ptr, c.lp.pse, c.lp.l);
    if sc_is_cnc(a) return a;
    if lv_is_address_scev_for_cost(a, c.lp.l) return a;
    return SCEV_NULL;
}

// VPReplicateRecipe::computeCost
vp_replicate_cost :: (c: *Vp_Cost_Ctx, r: Vp_Rec, vf: Ec) -> Cost {
    t := c.tti; kind := c.kind;
    ui := vp_underlying_instr(r);
    iset_insert(*c.skip, ui);
    single := vr(r).single_scalar;
    if vf.scalable && !single return COST_INVALID;
    n := cast(s64) vf.n;
    o := inst_op(ui);
    while true {   // `break` falls back to the legacy cost
        if o == {
        case .ALLOCA;
            if vf.scalable return COST_INVALID;
            return lt_arith_cost(t, .MUL, vp_scalar_type(vr(r).def), kind);
        case .GEP; return 0;
        case .CALL;
            nn := vp_nops(r);
            callee := vp_ir(vp_op(r, nn - 1));
            args := array_view(vr(r).ops, 0, nn - 1);
            return vp_replicate_call_cost(c, callee, vp_scalar_type(vr(r).def), args, single, vf);
        case .ADD; #through; case .SUB; #through; case .FADD; #through; case .FSUB; #through; case .MUL; #through;
        case .FMUL; #through; case .FDIV; #through; case .FREM; #through; case .SHL; #through; case .LSHR; #through;
        case .ASHR; #through; case .AND; #through; case .OR; #through; case .XOR; #through; case .ICMP; #through; case .FCMP;
            return lc_mul(vp_cost_for_recipe_with_opcode(c, r, vp_opc(o), ec_fixed(1)), ifx single then 1 else n);
        case .SDIV; #through; case .UDIV; #through; case .SREM; #through; case .UREM;
            sc := vp_cost_for_recipe_with_opcode(c, r, vp_opc(o), ec_fixed(1));
            if single return sc;
            fallback := false;
            for x: vr(r).ops {
                d := vp_def(x);
                if d == NONE || vr(d).kind != .PRED_INST_PHI continue;
                u := vp_uv(vp_op(d, 0));
                if u != NONE && is_inst(u) && vpc_skip(c, u, ec_is_vector(vf)) { fallback = true; break; }
            }
            if fallback break;
            sc = lc_add(lc_mul(sc, n), vpc_scalarization_overhead(c, vp_scalar_type(vr(r).def), vr(r).ops, vf));
            if !vp_is_replicator(vp_recipe_region(r)) return sc;
            sc = lc_add(sc, lc_mul(lt_cf_cost(t, .PHI, kind), n));
            sc = lc_div(sc, vpc_pred_block_cost_divisor(c, inst_block(ui)));
            return sc;
        case .LOAD; #through; case .STORE;
            is_load := o == .LOAD;
            ptr_op := vp_op(r, ifx is_load then 0 else 1);
            ptr_scev := vp_address_access_scev(c, ptr_op);
            if ptr_scev != SCEV_NULL && sc_is_cnc(ptr_scev) break;
            val_ty := ifx is_load then vp_scalar_type(vr(r).def) else vp_scalar_type(vp_op(r, 0));
            sptr_ty := vp_scalar_type(ptr_op);
            align := load_store_align(ui);
            as := ptr_addrspace(sptr_ty);
            op_info := tti_operand_info(op(ui, 0));
            prefer_vec_addr := lv_tti_prefers_vectorized_addressing(t);
            used_by_addr := !prefer_vec_addr && vp_is_used_by_load_store_address(vr(r).def);
            mem := lt_memory_op_cost(t, o, val_ty, align, as, kind, op_info, ifx used_by_addr then ui else NONE);
            ptr_ty := ifx single then sptr_ty else lv_to_vector_ty(sptr_ty, vf);
            sc := lc_add(mem, lv_tti_address_computation_cost(t, ptr_ty, !used_by_addr, ptr_scev));
            if single return sc;
            ops_to_scalarize: [] Vp_Val;
            result_ty := type_simple(.VOID);
            if !used_by_addr {
                // supportsEfficientVectorElementLoadStore is false
                if !(is_load && !prefer_vec_addr) ops_to_scalarize = vr(r).ops;
                result_ty = vp_scalar_type(vr(r).def);
            }
            cost := lc_add(lc_mul(sc, n), vpc_scalarization_overhead(c, result_ty, ops_to_scalarize, vf, true));
            reg := vp_recipe_region(r);
            if reg != NONE && vp_is_replicator(reg) {
                if ptr_scev == SCEV_NULL break;
                cost = lc_div(cost, vpc_pred_block_cost_divisor(c, inst_block(ui)));
                cost = lc_add(cost, lt_cf_cost(t, .CONDBR, kind));
                cost = lc_add(cost, lv_tti_scalarization_overhead_all(t, type_vector(vf.n, type_int(1), false), false, true, kind));
                if vpc_use_emulated_mask_mem_ref_hack(c, r, vf) return lcv(3000000);
            }
            return cost;
        case .SEXT; #through; case .ZEXT; #through; case .FPTOUI; #through; case .FPTOSI; #through; case .FPEXT; #through;
        case .PTRTOINT; #through; case .PTRTOADDR; #through; case .INTTOPTR; #through; case .SITOFP; #through;
        case .UITOFP; #through; case .TRUNC; #through; case .FPTRUNC; #through; case .SELECT; #through; case .ADDRSPACECAST;
            return lc_mul(vp_cost_for_recipe_with_opcode(c, r, vp_opc(o), ec_fixed(1)), ifx single then 1 else n);
        case .EXTRACTVALUE; #through; case .INSERTVALUE;
            return lt_insert_extract_value_cost(t, o, kind);
        }
        break;
    }
    return vpc_legacy_cost(c, ui, vf);
}

// VPWidenMemoryRecipe::computeCost
vp_widen_memory_cost :: (c: *Vp_Cost_Ctx, r: Vp_Rec, vf: Ec) -> Cost {
    t := c.tti; kind := c.kind;
    k := vr(r).kind;
    is_load := k == .WIDEN_LOAD || k == .WIDEN_LOAD_EVL;
    sty := ifx is_load then vp_scalar_type(vr(r).def) else vp_scalar_type(vp_op(r, 1));
    ty := lv_to_vector_ty(sty, vf);
    addr := vp_op(r, ifx is_load then 0 else 0);
    // getAddr() is operand 0 for loads and stores
    as := ptr_addrspace(vp_scalar_type(addr));
    opc := ifx is_load then Opcode.LOAD else .STORE;
    if !vr(r).consecutive {
        ptr_ty := vp_scalar_type(addr);
        ptr := vp_uv(addr);
        if !vp_is_single_scalar(addr) ptr_ty = lv_to_vector_ty(ptr_ty, vf);
        name: string;
        if k == .WIDEN_LOAD name = "llvm.masked.gather";
        else if k == .WIDEN_STORE name = "llvm.masked.scatter";
        else if k == .WIDEN_LOAD_EVL name = "llvm.vp.gather";
        else name = "llvm.vp.scatter";
        return lc_add(lv_tti_address_computation_cost(t, ptr_ty, false, SCEV_NULL),
                      lv_tti_mem_intrinsic_cost(t, name, ty, ptr, vr(r).masked, vr(r).align, 0, kind, vr(r).ir_inst));
    }
    cost: Cost = 0;
    if vr(r).masked {
        name := ifx k == .WIDEN_LOAD then "llvm.masked.load" else "llvm.masked.store";
        cost = lc_add(cost, lv_tti_mem_intrinsic_cost(t, name, ty, NONE, true, vr(r).align, as, kind));
    } else {
        oi := vpc_operand_info(ifx is_load then vp_op(r, 0) else vp_op(r, 1));
        cost = lc_add(cost, lt_memory_op_cost(t, opc, ty, vr(r).align, as, kind, oi, vr(r).ir_inst));
    }
    return cost;
}

// VPWidenIntrinsicRecipe::computeCallCost
vp_widen_intrinsic_call_cost :: (c: *Vp_Cost_Ctx, id: Intrinsic_Id, ops: [] Vp_Val, r: Vp_Rec, vf: Ec) -> Cost {
    sret := vp_scalar_type(vr(r).def);
    if id == iidn("llvm.experimental.vp.reverse") && type_kind(sret) == .INT && type_bits(sret) == 1 return 0;
    uv := vp_uv(vr(r).def);
    args: [..] Value_Id; args.allocator = temp;
    for o: ops {
        v := vp_uv(o);
        if v == NONE {
            if uv != NONE && is_inst(uv) && is_call_base(uv) { array_add(*args, op(uv, cast(u32) it_index)); continue; }
            args.count = 0;
            break;
        }
        array_add(*args, v);
    }
    ret_ty := ifx ec_is_vector(vf) then lv_to_vectorized_ty(sret, vf) else sret;
    tys := NewArray(ops.count, Type_Id,, allocator = temp);
    for ops tys[it_index] = lv_to_vector_ty(vp_scalar_type(it), vf);
    a: Ica;
    a.id = id; a.ret = ret_ty; a.args = args; a.tys = tys; a.fmf = vp_fmf_or_none(r);
    a.inst = ifx uv != NONE && is_inst(uv) && call_iid(uv) != NOT_INTRINSIC then uv else NONE;
    a.scalar_cost = COST_INVALID;
    return lt_intrinsic_cost(c.tti, *a, c.kind);
}
// VPWidenCallRecipe::computeCallCost
vp_widen_call_cost :: (c: *Vp_Cost_Ctx, variant: Value_Id) -> Cost { return lv_tti_call_instr_cost(c.tti); }

// ---------------------------------------------------------------- block, region and plan costs

// VPBasicBlock::cost
vp_basic_block_cost :: (c: *Vp_Cost_Ctx, bb: Vp_Blk, vf: Ec) -> Cost {
    cost: Cost = 0;
    for r: vp_block_recipes(bb) cost = lc_add(cost, vp_recipe_cost(c, r, vf));
    return cost;
}
vp_block_cost :: (c: *Vp_Cost_Ctx, b: Vp_Blk, vf: Ec) -> Cost {
    if vp_is_region(b) return vp_region_cost(c, b, vf);
    return vp_basic_block_cost(c, b, vf);
}
// VPRegionBlock::cost
vp_region_cost :: (c: *Vp_Cost_Ctx, reg: Vp_Blk, vf: Ec) -> Cost {
    if !vp_is_replicator(reg) {
        cost: Cost = 0;
        for b: vp_depth_first_shallow(vb(reg).entry) cost = lc_add(cost, vp_block_cost(c, b, vf));
        be := ifx lv_opts.force_target_instruction_cost.set then lv_forced_cost() else lt_cf_cost(c.tti, .BR, c.kind);
        lv_dbg("Cost of % for VF %: vector loop backedge\n", lc_str(be), lv_ec_str(vf));
        return lc_add(cost, be);
    }
    if vf.scalable return COST_INVALID;
    then_bb := vb(vb(reg).entry).succs[0];
    return vp_basic_block_cost(c, then_bb, vf);
}
// VPlan::cost
vp_plan_cost :: (c: *Vp_Cost_Ctx, vf: Ec) -> Cost {
    cost := vp_region_cost(c, vp_vector_loop_region(), vf);
    if !cost_valid(cost) return COST_INVALID;
    for bb: vp_blocks_only_basic(vp_depth_first_shallow(vpl.entry))
        if !cost_valid(vp_basic_block_cost(c, bb, vf)) return COST_INVALID;
    return cost;
}

// addFullyUnrolledInstructionsToIgnore
lvp_add_fully_unrolled_instructions_to_ignore :: (lp: *Lv_Planner, s: *Iset) {
    cmp := li_latch_cmp_inst(lp.li, lp.l);
    if cmp != NONE iset_insert(s, cmp);
    latch := li_loop_latch(lp.li, lp.l);
    for *lp.lvl.inductions {
        iv := it.phi;
        inc := phi_incoming_value_for_block(iv, latch);
        all := true;
        u := ir.v_first_use[inc];
        while u != NONE { usr := ir.u_user[u]; if usr != iv && usr != cmp { all = false; break; } u = ir.u_next[u]; }
        if all iset_insert(s, inc);
    }
}

// LoopVectorizationPlanner::precomputeCosts
lvp_precompute_costs :: (lp: *Lv_Planner, vf: Ec, c: *Vp_Cost_Ctx) -> Cost {
    cm := lp.cm;
    cost: Cost = 0;
    latch := li_loop_latch(lp.li, lp.l);
    for *lp.lvl.inductions {
        iv := it.phi;
        inc := phi_incoming_value_for_block(iv, latch);
        iv_insts: [..] Value_Id; iv_insts.allocator = temp;
        array_add(*iv_insts, inc);
        k := 0;
        while k < iv_insts.count {
            x := iv_insts[k]; k += 1;
            for j: 0..cast(s64) nops(x) - 1 {
                o := op(x, cast(u32) j);
                if o == iv || !is_inst(o) || !li_contains_inst(lp.li, lp.l, o) || !has_one_use(o) continue;
                array_add(*iv_insts, o);
            }
        }
        array_add(*iv_insts, iv);
        u := ir.v_first_use[iv];
        while u != NONE {
            usr := ir.u_user[u];
            u = ir.u_next[u];
            if !lv_cm_is_optimizable_iv_truncate(cm, usr, vf) continue;
            array_add(*iv_insts, usr);
        }
        tc := lv_small_constant_trip_count(lp.l);
        if ec_eq(tc, vf) && !vp_has_tail_folded() lvp_add_fully_unrolled_instructions_to_ignore(lp, *c.skip);
        for x: iv_insts {
            if vpc_skip(c, x, ec_is_vector(vf)) continue;
            ic := vpc_legacy_cost(c, x, vf);
            lv_dbg("Cost of % for VF %: induction instruction %\n", lc_str(ic), lv_ec_str(vf), lv_inst_str(x));
            cost = lc_add(cost, ic);
            iset_insert(*c.skip, x);
        }
    }
    for bb: li_blocks(lp.li, lp.l) {
        term := block_terminator(bb);
        if vpc_skip(c, term, ec_is_vector(vf)) continue;
        iset_insert(*c.skip, term);
        if bb == latch continue;
        cost = lc_add(cost, vpc_legacy_cost(c, term, vf));
    }
    if lv_opts.force_target_instruction_cost.set return cost;
    st := lv_cm_vf_state(cm, vf);
    if st {
        for fs: st.forced_scalars {
            if vpc_skip(c, fs, ec_is_vector(vf)) continue;
            iset_insert(*c.skip, fs);
            fc := vpc_legacy_cost(c, fs, vf);
            lv_dbg("Cost of % for VF %: forced scalar %\n", lc_str(fc), lv_ec_str(vf), lv_inst_str(fs));
            cost = lc_add(cost, fc);
        }
        for s: st.insts_to_scalarize {
            o := inst_op(s);
            if o == .SDIV || o == .UDIV || o == .SREM || o == .UREM continue;
            if vpc_skip(c, s, ec_is_vector(vf)) continue;
            iset_insert(*c.skip, s);
            sc := st.insts_to_scalarize_cost[it_index];
            lv_dbg("Cost of % for VF %: profitable to scalarize %\n", lc_str(sc), lv_ec_str(vf), lv_inst_str(s));
            cost = lc_add(cost, sc);
        }
    }
    return cost;
}

Vp_Reg_Usage :: struct {
    loop_invariant_regs: [..] Reg_Class_Count;   // SmallMapVector<unsigned, unsigned>
    max_local_users: [..] Reg_Class_Count;
}
Reg_Class_Count :: struct { class: u32; n: u32; }
rcc_add :: (m: *[..] Reg_Class_Count, class: u32, n: u32) {
    for * m.* if it.class == class { it.n += n; return; }
    array_add(m, .{class, n});
}
rcc_get :: (m: *[..] Reg_Class_Count, class: u32) -> *Reg_Class_Count {
    for * m.* if it.class == class return it;
    array_add(m, .{class, 0});
    return *m.*[m.count - 1];
}

// LoopVectorizationPlanner::cost
lvp_cost :: (lp: *Lv_Planner, plan: *Vp_Plan, vf: Ec, ru: *Vp_Reg_Usage) -> Cost {
    vp_use(plan);
    c: Vp_Cost_Ctx;
    vpc_init(*c, lp);
    cost := lvp_precompute_costs(lp, vf, *c);
    cost = lc_add(cost, vp_plan_cost(*c, vf));
    if ru && lv_should_consider_reg_pressure_for_vf(lp.cm, vf) cost = lc_add(cost, vp_spill_cost(lp.cm.tti, ru));
    lv_dbg("Cost for VF %: %\n", lv_ec_str(vf), lc_str(cost));
    return cost;
}
// VPRegisterUsage::spillCost
vp_spill_cost :: (t: *Tti, ru: *Vp_Reg_Usage) -> Cost {
    cost: Cost = 0;
    ov := ifx lv_opts.force_target_num_vector_regs.set then cast(u32) lv_opts.force_target_num_vector_regs.v else 0;
    for ru.max_local_users {
        avail := ifx ov > 0 then ov else tti_number_of_registers(t, it.class);
        if it.n > avail {
            spills := it.n - avail;
            sc := lcv(tti_register_class_spill_cost(t, it.class) + tti_register_class_reload_cost(t, it.class));
            cost = lc_add(cost, lc_mul(sc, cast(s64) spills));
        }
    }
    return cost;
}
// VFSelectionContext::shouldConsiderRegPressureForVF
lv_should_consider_reg_pressure_for_vf :: (cm: *Lv_Cm, vf: Ec) -> bool {
    if lv_opts.consider_reg_pressure.set return lv_opts.consider_reg_pressure.v != 0;
    // TTI.shouldConsiderVectorizationRegPressure() is false for X86 and the base implementation
    if !lv_use_max_bandwidth(cm, vf.scalable) return false;
    return ec_known_gt(vf, ifx vf.scalable then Ec.{0, true} else cm.max_permissible_fixed);
}

// VectorizationFactor
Lv_Vf :: struct { width: Ec; cost: Cost; scalar_cost: Cost; min_profitable_tc: Ec; }

// LoopVectorizationPlanner::isMoreProfitable
lvp_is_more_profitable :: (lp: *Lv_Planner, a: Lv_Vf, b: Lv_Vf, max_tc: u64, has_tail: bool) -> bool {
    ca := a.cost; cb := b.cost;
    wa := cast(s64) a.width.n; wb := cast(s64) b.width.n;
    if lp.cm.cost_kind == TCK_CODE_SIZE return ca < cb || (ca == cb && wa > wb);
    // preferFixedOverScalableIfEqualCost: no scalable VFs are formed
    lower_without_tc := lc_mul(ca, wb) < lc_mul(cb, wa);
    if !max_tc return lower_without_tc;
    cost_for_tc :: (vf: s64, vc: Cost, sc: Cost, max_tc: u64, has_tail: bool) -> Cost {
        m := cast(s64) max_tc;
        if has_tail return lc_add(lc_mul(vc, m / vf), lc_mul(sc, m % vf));
        return lc_mul(vc, (m + vf - 1) / vf);
    }
    return cost_for_tc(wa, ca, a.scalar_cost, max_tc, has_tail) < cost_for_tc(wb, cb, b.scalar_cost, max_tc, has_tail);
}

// collectEphemeralRecipesForVPlan
vp_collect_ephemeral_recipes :: () -> [..] Vp_Rec {
    eph: [..] Vp_Rec; eph.allocator = temp;
    wl: [..] Vp_Rec; wl.allocator = temp;
    for bb: vp_blocks_only_basic(vp_depth_first_deep(vb(vp_vector_loop_region()).entry)) for r: vp_block_recipes(bb) {
        if vr(r).kind != .REPLICATE || call_iid(vp_underlying_instr(r)) != IID_ASSUME continue;
        array_add(*wl, r); array_add(*eph, r);
    }
    while wl.count {
        cur := pop(*wl);
        for o: vr(cur).ops {
            d := vp_def(o);
            if d == NONE || vp_may_have_side_effects(d) || array_find(eph, d) continue;
            ok := true;
            for u: vv(o).users if !array_find(eph, u) { ok = false; break; }
            if !ok continue;
            array_add(*eph, d); array_add(*wl, d);
        }
    }
    return eph;
}

// willGenerateVectors
vp_will_generate_vectors :: (t: *Tti, vf: Ec) -> bool {
    eph := vp_collect_ephemeral_recipes();
    visited: [..] Type_Id; visited.allocator = temp;
    for bb: vp_blocks_only_basic(vp_depth_first_shallow(vb(vp_vector_loop_region()).entry)) for r: vp_block_recipes(bb) {
        if array_find(eph, r) continue;
        k := vr(r).kind;
        if k == .DERIVED_IV || k == .SCALAR_IV_STEPS || k == .REPLICATE || k == .INSTRUCTION || k == .CURRENT_ITERATION_PHI ||
           k == .VECTOR_POINTER || k == .VECTOR_END_POINTER || k == .EXPAND_SCEV || k == .PRED_INST_PHI || k == .BRANCH_ON_MASK
            continue;
        if k == .IR_INSTRUCTION || k == .EXPRESSION || k == .REDUCTION_EVL fatal("internal: willGenerateVectors: unhandled recipe");
        nd := vp_num_defined_values(r);
        if nd == 0 && !(k == .WIDEN_STORE || k == .WIDEN_STORE_EVL || k == .INTERLEAVE || k == .INTERLEAVE_EVL) continue;
        to_check := ifx nd >= 1 then vp_defined_value(r, 0) else vp_op(r, 1);
        sty := vp_scalar_type(to_check);
        if array_find(visited, sty) continue;
        array_add(*visited, sty);
        wide := lv_to_vectorized_ty(sty, vf);
        parts := lv_tti_number_of_parts(t, wide);
        if parts == 0 continue;
        if vf.scalable { if parts <= vf.n return true; continue; }
        if parts < vf.n return true;
    }
    return false;
}

// calculateRegisterUsageForPlan
vp_calculate_register_usage :: (vfs: [] Ec, t: *Tti, values_to_ignore: *Iset) -> [..] Vp_Reg_Usage {
    idx2recipe: [..] Vp_Rec; idx2recipe.allocator = temp;
    end_point: Table(Vp_Val, s64); end_point.allocator = temp;
    ends: [..] Vp_Val; ends.allocator = temp;
    is_end :: (ends: [] Vp_Val, v: Vp_Val) -> bool { return array_find(ends, v); }
    invariants: [..] Vp_Val; invariants.allocator = temp;
    vtc := vpl.vector_trip_count;
    if vtc != NONE && vv(vtc).users.count array_add(*invariants, vtc);
    region := vp_vector_loop_region();
    for bb: vp_blocks_only_basic(vp_rpo(region, true)) {
        if vb(bb).parent == NONE break;
        for r: vp_block_recipes(bb) {
            array_add(*idx2recipe, r);
            for u: vr(r).ops {
                kk := vv(u).kind;
                if kk == .SINGLE_DEF || kk == .MULTI_DEF {
                    table_set(*end_point, u, idx2recipe.count);
                    if !array_find(ends, u) array_add(*ends, u);
                } else if kk == .IR {
                    if !is_inst(vp_ir(u)) continue;
                    if !array_find(invariants, u) array_add(*invariants, u);
                }
            }
        }
        if bb == vb(region).exiting {
            for p: vp_block_phis(vp_entry_basic_block(region)) {
                if vr(p).kind != .WIDEN_INT_OR_FP_INDUCTION continue;
                d := vr(p).def;
                table_set(*end_point, d, idx2recipe.count);
                if !array_find(ends, d) array_add(*ends, d);
            }
        }
    }
    open: [..] Vp_Val; open.allocator = temp;
    can_iv := vb(region).can_iv;
    if vv(can_iv).users.count array_add(*open, can_iv);
    max_usages := NewArray(vfs.count, [..] Reg_Class_Count,, allocator = temp);
    for * max_usages it.allocator = temp;
    get_reg_usage :: (t: *Tti, ty: Type_Id, vf: Ec) -> u32 {
        k := type_kind(ty);
        if k == .TOKEN || !(k == .INT || is_fp_type(ty) || k == .PTR) return 0;
        return cast(u32) tti_reg_usage_for_type(t, type_vector(vf.n, ty, vf.scalable));
    }
    for r, idx: idx2recipe {
        // remove the values whose intervals end here
        k := 0;
        while k < open.count {
            found, e := table_find(*end_point, open[k]);
            if found && e == idx { open[k] = open[open.count - 1]; open.count -= 1; continue; }
            k += 1;
        }
        defs: [..] Vp_Val; defs.allocator = temp;
        for j: 0..vp_num_defined_values(r) - 1 array_add(*defs, vp_defined_value(r, j));
        used := false;
        for defs if is_end(ends, it) { used = true; break; }
        if !used && !vp_may_have_side_effects(r) continue;
        if vp_is_single_def_kind(vr(r).kind) && vr(r).def != NONE && vv(vr(r).def).uv != NONE && iset_has(values_to_ignore, vv(vr(r).def).uv) continue;
        for vf, j: vfs {
            usage: [..] Reg_Class_Count; usage.allocator = temp;
            for v: open {
                d := vp_def(v);
                if d != NONE {
                    dk := vr(d).kind;
                    if dk == .VECTOR_POINTER || dk == .VECTOR_END_POINTER || dk == .BRANCH_ON_MASK continue;
                    if vpm_vpi_r(d, VPI_EXTRACT_LAST_PART, 1) continue;
                }
                scalar_use := ec_is_scalar(vf) || v == can_iv;
                if !scalar_use && d != NONE {
                    dk := vr(d).kind;
                    if dk == .REPLICATE || dk == .DERIVED_IV || dk == .CURRENT_ITERATION_PHI || dk == .SCALAR_IV_STEPS scalar_use = true;
                    else if dk == .INSTRUCTION && vp_only_scalar_values_used(v) scalar_use = true;
                    else if dk == .REDUCTION_PHI && vr(d).rdx_style != .UNORDERED scalar_use = true;
                }
                if scalar_use {
                    rcc_add(*usage, tti_register_class_for_type(t, false, vp_scalar_type(v)), 1);
                } else {
                    scale: u64 = 1;
                    if d != NONE && (vr(d).kind == .REDUCTION_PHI || vr(d).kind == .REDUCTION) scale = vr(d).rdx_scale;
                    if d != NONE && vr(d).kind == .EXPRESSION vp_unported("VPExpressionRecipe::getVFScaleFactor");
                    rvf := vf;
                    if scale > 1 rvf.n = vf.n / scale;
                    sty := vp_scalar_type(v);
                    rcc_add(*usage, tti_register_class_for_type(t, true, sty), get_reg_usage(t, sty, rvf));
                }
            }
            for usage {
                e := rcc_get(*max_usages[j], it.class);
                e.n = max(e.n, it.n);
            }
        }
        for defs if is_end(ends, it) && !array_find(open, it) array_add(*open, it);
    }
    rus: [..] Vp_Reg_Usage; rus.allocator = temp;
    for vf, j: vfs {
        ru: Vp_Reg_Usage;
        ru.loop_invariant_regs.allocator = temp; ru.max_local_users.allocator = temp;
        for inv: invariants {
            is_scalar := vp_only_scalar_values_used(inv);
            ivf := ifx is_scalar then ec_fixed(1) else vf;
            cls := tti_register_class_for_type(t, ec_is_vector(ivf), vp_scalar_type(inv));
            rcc_add(*ru.loop_invariant_regs, cls, get_reg_usage(t, vp_scalar_type(inv), ivf));
        }
        for max_usages[j] array_add(*ru.max_local_users, it);
        array_add(*rus, ru);
    }
    return rus;
}

// LoopVectorizationPlanner::computeBestVF: (factor, plan); plan is null when no plan was built
lvp_compute_best_vf :: (lp: *Lv_Planner) -> Lv_Vf, *Vp_Plan {
    disabled := Lv_Vf.{ec_fixed(1), 0, 0, ec_fixed(0)};
    if lp.vplans.count == 0 return disabled, null;
    first := lp.vplans[0];
    if lp.vplans.count == 1 {
        vp_use(first);
        return Lv_Vf.{vp_single_vf(), 0, 0, ec_fixed(0)}, first;
    }
    user_vf := Ec.{lvh_width(lp.hints), lvh_width_scalable(lp.hints)};
    if lv_opts.epilogue_force_vf.set && lv_opts.epilogue_force_vf.v > 1 && lvp_has_plan_with_vf(lp, user_vf) {
        assert(lp.vplans.count == 2, "Must have exactly 2 VPlans built");
        return Lv_Vf.{user_vf, 0, 0, ec_fixed(0)}, lp.vplans[1];
    }
    one := ec_fixed(1);
    scalar_cost := lv_cm_expected_cost(lp.cm, one);
    lv_dbg("LV: Scalar loop costs: %.\n", lc_str(scalar_cost));
    scalar_factor := Lv_Vf.{one, scalar_cost, scalar_cost, ec_fixed(0)};
    best := scalar_factor;
    force := lvh_force(lp.hints) == FK_ENABLED;
    if force best.cost = LV_COST_MAX;
    best_plan := first;
    max_tc := cast(u64) lv_pse_small_constant_max_trip_count(lp.cm);
    array_reset(*lp.profitable_vfs);
    for p: lp.vplans {
        vp_use(p);
        vfs: [..] Ec; vfs.allocator = temp;
        for p.vfs array_add(*vfs, it);
        consider := false;
        for vfs if lv_should_consider_reg_pressure_for_vf(lp.cm, it) consider = true;
        rus: [..] Vp_Reg_Usage;
        if consider rus = vp_calculate_register_usage(vfs, lp.cm.tti, *lp.cm.values_to_ignore);
        for vf, j: vfs {
            if ec_is_scalar(vf) continue;
            vp_use(p);
            if !force && !vp_will_generate_vectors(lp.cm.tti, vf) {
                lv_dbg("LV: Not considering vector loop of width % because it will not generate any vector instructions.\n", lv_ec_str(vf));
                continue;
            }
            if lp.cm.opt_for_size && !force && lv_has_replicator_region() continue;
            cost := lvp_cost(lp, p, vf, ifx consider then *rus[j] else null);
            cur := Lv_Vf.{vf, cost, scalar_cost, ec_fixed(0)};
            vp_use(p);
            has_tail := vp_has_scalar_tail();
            if lvp_is_more_profitable(lp, cur, best, max_tc, has_tail) { best = cur; best_plan = p; }
            if lvp_is_more_profitable(lp, cur, scalar_factor, max_tc, has_tail) array_add(*lp.profitable_vfs, cur);
        }
    }
    lv_dbg("LV: Selecting VF: %.\n", lv_ec_str(best.width));
    vp_use(best_plan);
    return best, best_plan;
}
lvp_has_plan_with_vf :: (lp: *Lv_Planner, vf: Ec) -> bool {
    saved := vpl;
    defer vpl = saved;
    for lp.vplans { vp_use(it); if vp_has_vf(vf) return true; }
    return false;
}
// hasReplicatorRegion
lv_has_replicator_region :: () -> bool {
    for reg: vp_blocks_only_region(vp_depth_first_shallow(vb(vp_vector_loop_region()).entry)) if vp_is_replicator(reg) return true;
    return false;
}

// LoopVectorizationPlanner::selectInterleaveCount
lvp_select_interleave_count :: (lp: *Lv_Planner, plan: *Vp_Plan, vf: Ec, loop_cost_in: Cost) -> u64 {
    vp_use(plan);
    cm := lp.cm;
    if cm.sel != .ALLOWED return 1;   // !isEpilogueAllowed() && !(preferTailFoldedLoop && useWideActiveLaneMask)
    header := vp_entry_basic_block(vp_vector_loop_region());
    for vp_block_phis(header) if vr(it).kind == .CURRENT_ITERATION_PHI return 1;
    if !lvl_is_safe_for_any_vector_width(lp.lvl) return 1;
    if vp_has_early_exit() return 1;
    has_rdx := false;
    for vp_block_phis(header) if vr(it).kind == .REDUCTION_PHI has_rdx = true;
    for vp_block_phis(header) if vr(it).kind == .REDUCTION_PHI && rk_is_find_last(vr(it).rdx_kind) return 1;
    vfs := Ec.[vf];
    rus := vp_calculate_register_usage(vfs, cm.tti, *cm.values_to_ignore);
    r := *rus[0];
    loop_cost := loop_cost_in;
    if loop_cost == 0 {
        if ec_is_scalar(vf) loop_cost = lv_cm_expected_cost(cm, vf);
        else loop_cost = lvp_cost(lp, plan, vf, r);
        vp_use(plan);
        assert(cost_valid(loop_cost), "Expected to have chosen a VF with valid cost");
        if loop_cost == 0 return 1;
    }
    for * r.max_local_users it.n = max(it.n, 1);
    ic: u64 = 0xFFFF_FFFF;
    for r.max_local_users {
        target_regs := tti_number_of_registers(cm.tti, it.class);
        if ec_is_scalar(vf) { if lv_opts.force_target_num_scalar_regs.set target_regs = cast(u32) lv_opts.force_target_num_scalar_regs.v; }
        else if lv_opts.force_target_num_vector_regs.set target_regs = cast(u32) lv_opts.force_target_num_vector_regs.v;
        max_local := it.n;
        inv: u32 = 0;
        for li_: r.loop_invariant_regs if li_.class == it.class inv = li_.n;
        // unsigned arithmetic (wraps like LLVM's)
        tmp := lv_bit_floor_u32((target_regs - inv) / max_local);
        if lv_opts.ind_var_register_heur {
            d := max_local - 1;
            if d < 1 d = 1;
            tmp = lv_bit_floor_u32((target_regs - inv - 1) / d);
        }
        ic = min(ic, cast(u64) tmp);
    }
    has_unordered := false;
    if has_rdx {
        has_unordered = true;
        for vp_block_phis(header) if vr(it).kind == .REDUCTION_PHI && vr(it).rdx_style == .ORDERED has_unordered = false;
    }
    max_ic := lv_tti_max_interleave_factor(cm.tti, vf, has_unordered);
    if ec_is_scalar(vf) { if lv_opts.force_target_max_scalar_interleave.set max_ic = cast(u64) lv_opts.force_target_max_scalar_interleave.v; }
    else if lv_opts.force_target_max_vector_interleave.set max_ic = cast(u64) lv_opts.force_target_max_vector_interleave.v;
    known, best_tc := lv_small_best_known_tc(cm, lp.l, true, cm.sel == .ALLOWED);
    if known && (!best_tc.scalable || vf.scalable) {
        avail := cast(u32) best_tc.n;
        est_vf := cast(u32) vf.n;
        if lvp_requires_scalar_epilogue() avail -= 1;
        lb := lv_bit_floor_u32(max(cast(u32) 1, min(avail / (est_vf * 2), cast(u32) max_ic)));
        if lv_small_constant_trip_count(lp.l).n != 0 {
            ub := lv_bit_floor_u32(max(cast(u32) 1, min(avail / est_vf, cast(u32) max_ic)));
            max_ic = cast(u64) lb;
            if ub != lb {
                tub := avail % (est_vf * ub);
                tlb := avail % (est_vf * lb);
                if tub == tlb max_ic = cast(u64) ub;
            }
        } else {
            max_ic = cast(u64) lb;
        }
    }
    assert(max_ic > 0, "Maximum interleave count must be greater than 0");
    if ic > max_ic ic = max_ic;
    else ic = max(cast(u64) 1, ic);
    if ec_is_vector(vf) && has_rdx return ic;
    pred_needed := false;
    if ec_is_scalar(vf) for bb: li_blocks(lp.li, lp.l) if lvl_block_needs_predication(lp.lvl, bb) pred_needed = true;
    rt_needed := ec_is_scalar(vf) && lp.lvl.laa.rt.need;
    lv_dbg("LV: Loop cost is %\nLV: IC is %\nLV: VF is %\n", lc_str(loop_cost), ic, lv_ec_str(vf));
    if !rt_needed && !pred_needed && loop_cost < lcv(lv_opts.small_loop_cost) {
        lcval := lc_value(loop_cost);
        if lcval == 0 vp_unported("a loop cost below 1 in selectInterleaveCount (division by zero in LLVM)");
        small_ic := min(ic, cast(u64) lv_bit_floor_u64(cast(u64) (lv_opts.small_loop_cost / lcval)));
        num_stores: u64 = 0; num_loads: u64 = 0;
        for bb: vp_blocks_only_basic(vp_depth_first_deep(vb(vp_vector_loop_region()).entry)) for rr: vp_block_recipes(bb) {
            k := vr(rr).kind;
            if k == .WIDEN_LOAD || k == .WIDEN_LOAD_EVL { num_loads += 1; continue; }
            if k == .WIDEN_STORE || k == .WIDEN_STORE_EVL { num_stores += 1; continue; }
            if k == .INTERLEAVE {
                so := vp_interleave_num_store_operands(rr);
                if so num_stores += cast(u64) so;
                else num_loads += cast(u64) vp_num_defined_values(rr);
                continue;
            }
            if k == .REPLICATE {
                ui := vp_underlying_instr(rr);
                if inst_op(ui) == .LOAD num_loads += 1;
                if inst_op(ui) == .STORE num_stores += 1;
                continue;
            }
            if k == .HISTOGRAM { num_loads += 1; num_stores += 1; continue; }
        }
        stores_ic := ic / (ifx num_stores then num_stores else 1);
        loads_ic := ic / (ifx num_loads then num_loads else 1);
        if has_rdx {
            for vp_block_phis(header) if vr(it).kind == .REDUCTION_PHI && (rk_is_any_of(vr(it).rdx_kind) || rk_is_find_iv(vr(it).rdx_kind)) return 1;
        }
        if has_rdx && li_depth(lp.li, lp.l) > 1 {
            for vp_block_phis(header) if vr(it).kind == .REDUCTION_PHI && vr(it).rdx_style == .ORDERED return 1;
            f := cast(u64) lv_opts.max_nested_scalar_reduction_ic;
            small_ic = min(small_ic, f); stores_ic = min(stores_ic, f); loads_ic = min(loads_ic, f);
        }
        if lv_opts.loadstore_runtime_interleave && max(stores_ic, loads_ic) > small_ic return max(stores_ic, loads_ic);
        // enableAggressiveInterleaving is false for X86 and the base implementation
        return small_ic;
    }
    return 1;
}
lv_bit_floor_u32 :: (x: u32) -> u32 {
    if x == 0 return 0;
    r: u32 = 1;
    while (r << 1) != 0 && (r << 1) <= x r <<= 1;
    return r;
}
lv_bit_floor_u64 :: (x: u64) -> u64 {
    if x == 0 return 0;
    r: u64 = 1;
    while r <= x / 2 r <<= 1;
    return r;
}

// getMinMaxReductionIntrinsicOp(RecurKind)
lv_min_max_reduction_intrinsic :: (k: Recur_Kind) -> Intrinsic_Id {
    if k == {
        case .UMIN; return IID_UMIN; case .UMAX; return IID_UMAX; case .SMIN; return IID_SMIN; case .SMAX; return IID_SMAX;
        case .FMIN; #through; case .FMINNUM; return IID_MINNUM;
        case .FMAX; #through; case .FMAXNUM; return IID_MAXNUM;
        case .FMINIMUM; return IID_MINIMUM; case .FMAXIMUM; return IID_MAXIMUM;
        case .FMINIMUMNUM; return iidn("llvm.minimumnum"); case .FMAXIMUMNUM; return iidn("llvm.maximumnum");
    }
    fatal("internal: getMinMaxReductionIntrinsicOp of %", k);
    return NOT_INTRINSIC;
}
