// VPlan utilities: the VPlanPatternMatch matchers the port uses (llvm/lib/Transforms/Vectorize/VPlanPatternMatch.h),
// vputils (llvm/lib/Transforms/Vectorize/VPlanUtils.cpp: getOrCreateVPValueForSCEVExpr, getSCEVExprForVPValue,
// poisonGuaranteesUB, getFlagsFromIndDesc, findCanonicalIVIncrement), VPInstruction::getNumOperandsForOpcode and
// the VPIRFlags / VPIRMetadata constructors from an IR instruction (llvm/lib/Transforms/Vectorize/VPlanRecipes.cpp,
// VPlanHelpers.h).
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_iids;
import pm;
import apint;
import scev;
import scev_create;
import scev_lt;
import pse;
import iv_descriptors;
import vplan;

// ---------------------------------------------------------------------------------------------
// VPIRFlags(Instruction &I) / VPIRMetadata(I)

fn vp_flags_from_inst(i: i32) -> VPF {
    let o = iop(i);
    let fl = insts[inst_of(i)].flags;
    if o == OP_FCMP { return vpf_fcmp(inst_pred(i), insts[inst_of(i)].fmf); }
    if o == OP_ICMP { return vpf_cmp(inst_pred(i)); }
    if o == OP_OR { return vpf_disjoint((fl & FL_DISJOINT) != 0); }
    if o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_SHL { return vpf_wrap((fl & FL_NUW) != 0, (fl & FL_NSW) != 0); }
    if o == OP_TRUNC { return vpf_trunc((fl & FL_NUW) != 0, (fl & FL_NSW) != 0); }
    if o == OP_UDIV || o == OP_SDIV || o == OP_LSHR || o == OP_ASHR { return vpf_exact((fl & FL_EXACT) != 0); }
    if o == OP_GEP { return vpf_gep(fl); }
    if o == OP_ZEXT || o == OP_UITOFP { return vpf_nneg((fl & FL_NNEG) != 0); }
    if is_fp_math_operator(i) { return vpf_fmf(insts[inst_of(i)].fmf); }
    return vpf_none();
}

// getMetadataToPropagate: the kinds VPIRMetadata keeps (no !dbg)
fn vp_md_is_propagated(kind: i32) -> bool {
    return kind == md_kind_id("tbaa") || kind == md_kind_id("alias.scope") || kind == md_kind_id("noalias") ||
           kind == md_kind_id("fpmath") || kind == md_kind_id("nontemporal") || kind == md_kind_id("invariant.load") ||
           kind == md_kind_id("llvm.access.group") || kind == md_kind_id("mmra");
}
// VPIRMetadata(*Inst) onto recipe r
fn vp_md_from_inst(r: i32, i: i32) {
    let ii = inst_of(i);
    for k in insts[ii].nmd as i64 {
        let kind = md_att[(insts[ii].md as i64) + 2 * k];
        let node = md_att[(insts[ii].md as i64) + 2 * k + 1];
        if kind == 0 { continue; }
        if vp_md_is_propagated(kind) { vp_md_set(r, kind, node); }
    }
}
fn vp_inst_dl(i: i32) -> i32 { inst_get_md(i, 0) }

// ---------------------------------------------------------------------------------------------
// pattern matching

// the opcode a Recipe_match<..., VPWidenRecipe, VPReplicateRecipe, VPWidenCastRecipe, VPInstruction> sees (-1: none)
fn vpm_opcode(r: i32, with_cast: bool) -> i32 {
    if r < 0 { return -1; }
    let k = vpr[r].kind;
    if k == VPR_INSTRUCTION || k == VPR_WIDEN { return vpr[r].opcode; }
    if k == VPR_WIDEN_CAST && with_cast { return vpr[r].opcode; }
    if k == VPR_REPLICATE { return iop(vp_underlying_instr(r)) as i32; }
    return -1;
}
// VPInstruction::getNumOperandsForOpcode (-1: variadic)
fn vp_num_operands_for_opcode(r: i32) -> i64 {
    let o = vpr[r].opcode;
    if vpi_is_ir_opcode(o) {
        let io = o as i64;
        if io == OP_FNEG || is_cast_op(io) { return 1; }
        if io >= OP_ADD && io <= OP_XOR { return 2; }
        if io == OP_ALLOCA || io == OP_EXTRACTVALUE || io == OP_FREEZE || io == OP_LOAD { return 1; }
        if io == OP_ICMP || io == OP_FCMP || io == OP_STORE || io == OP_EXTRACTELEMENT { return 2; }
        if io == OP_SELECT || io == OP_INSERTELEMENT { return 3; }
        if io == OP_CALL {
            var ops: i32[>..<] = [];
            xv_to(vpr[r].ops, ops);
            return vp_called_fn_operand_index_ops(ops) + 1;
        }
        return -1;
    }
    if o == VPI_STEP_VECTOR || o == VPI_INCOMING_ALIAS_MASK { return 0; }
    if o == VPI_BRANCH_ON_COND || o == VPI_BROADCAST || o == VPI_EXITING_IV_VALUE || o == VPI_EXPLICIT_VECTOR_LENGTH ||
       o == VPI_EXTRACT_LAST_LANE || o == VPI_EXTRACT_LAST_PART || o == VPI_EXTRACT_PENULTIMATE_ELEMENT ||
       o == VPI_MASKED_COND || o == VPI_NOT || o == VPI_REVERSE || o == VPI_UNPACK || o == VPI_NUM_ACTIVE_LANES { return 1; }
    if o == VPI_BRANCH_ON_COUNT || o == VPI_BRANCH_ON_TWO_CONDS || o == VPI_FIRST_ORDER_RECURRENCE_SPLICE ||
       o == VPI_LOGICAL_AND || o == VPI_LOGICAL_OR || o == VPI_PTR_ADD || o == VPI_WIDE_PTR_ADD || o == VPI_WIDE_IV_STEP ||
       o == VPI_CALCULATE_TRIP_COUNT_MINUS_VF || o == VPI_RESUME_FOR_EPILOGUE { return 2; }
    if o == VPI_ACTIVE_LANE_MASK || o == VPI_REDUCTION_START_VECTOR { return 3; }
    return -1;
}
// VPInstruction::isMasked
fn vp_is_masked(r: i32) -> bool {
    if vpr[r].kind != VPR_INSTRUCTION { return false; }
    let n = vp_num_operands_for_opcode(r);
    if n < 0 { return false; }
    return n + 1 == vp_nops(r);
}
fn vp_mask_of(r: i32) -> i32 { if vp_is_masked(r) { vp_op(r, vp_nops(r) - 1) } else { -1 } }
fn vpm_num_ops_without_mask(r: i32) -> i64 {
    if vpr[r].kind == VPR_INSTRUCTION { return vp_nops(r) - (if vp_is_masked(r) { 1 } else { 0 }); }
    if vpr[r].kind == VPR_REPLICATE { return vp_nops(r) - (if vpr[r].predicated { 1 } else { 0 }); }
    return vp_nops(r);
}
// Recipe_match's operand-count rule: exactly n operands, or n plus a mask
fn vpm_arity_ok(r: i32, n: i64) -> bool {
    let c = vp_nops(r);
    if c < n { return false; }
    if c > n {
        let k = vpr[r].kind;
        if k == VPR_INSTRUCTION { return vp_is_masked(r) && vpm_num_ops_without_mask(r) == n; }
        if k == VPR_REPLICATE { return vpr[r].predicated && vpm_num_ops_without_mask(r) == n; }
        return false;
    }
    return true;
}
// m_Binary<Opcode>(m_VPValue(A), m_VPValue(B)): (ok, A, B)
fn vpm_binary(v: i32, opc: i64) -> bool, i32, i32 {
    let r = vp_def(v);
    if vpm_opcode(r, true) != opc as i32 || !vpm_arity_ok(r, 2) { return false, -1, -1; }
    return true, vp_op(r, 0), vp_op(r, 1);
}
fn vpm_unary(v: i32, opc: i64) -> bool, i32 {
    let r = vp_def(v);
    if vpm_opcode(r, true) != opc as i32 || !vpm_arity_ok(r, 1) { return false, -1; }
    return true, vp_op(r, 0);
}
fn vpm_vpi_r(r: i32, opc: i32, n: i64) -> bool { vp_is_vpi(r, opc) && vpm_arity_ok(r, n) }
// m_c_Binary with one operand fixed: the other operand or -1
fn vpm_c_binary_with(v: i32, opc: i64, want: i32) -> i32 {
    let r = vp_def(v);
    if vpm_opcode(r, false) != opc as i32 || !vpm_arity_ok(r, 2) { return -1; }
    if vp_op(r, 0) == want { return vp_op(r, 1); }
    if vp_op(r, 1) == want { return vp_op(r, 0); }
    return -1;
}
// int_pred_ty looks through a Broadcast
fn vpm_through_broadcast(v: i32) -> i32 {
    let r = vp_def(v);
    if r >= 0 && vpr[r].kind == VPR_INSTRUCTION && vpr[r].opcode == VPI_BROADCAST { return vp_op(r, 0); }
    return v;
}
fn vpm_zero_int(v: i32) -> bool { vp_is_const_int_zero(vpm_through_broadcast(v)) }
fn vpm_one(v: i32) -> bool { vp_is_const_int_one(vpm_through_broadcast(v)) }
fn vpm_all_ones(v: i32) -> bool { let x = vpm_through_broadcast(v); vp_is_constant_int(x) && ap_is_all_ones(ci_ap(vp_ir(x))) }
fn vpm_specific_int(v: i32, x: u64) -> bool {
    let c = vpm_through_broadcast(v);
    if !vp_is_constant_int(c) { return false; }
    let a = ci_ap(vp_ir(c));
    return ap_active_bits(a) <= 64 && a.lo == x;
}
// m_ConstantInt(uint64_t &)
fn vpm_constant_int(v: i32) -> bool, u64 {
    if !vp_is_constant_int(v) { return false, 0; }
    let a = ci_ap(vp_ir(v));
    if ap_active_bits(a) > 64 { return false, 0; }
    return true, a.lo;
}

// ---------------------------------------------------------------------------------------------
// vputils

// getOrCreateVPValueForSCEVExpr
fn vp_get_or_create_value_for_scev(e: i32) -> i32 {
    if sc_is_const(e) { return vp_live_in(sc_value(e)); }
    if sc_is_unknown(e) && !is_inst(sc_value(e)) { return vp_live_in(sc_value(e)); }
    let r = vp_new_single_def(VPR_EXPAND_SCEV, [], sc_ty(e), -1, -1);
    vpr[r].expr = e;
    let entry = vph.entry;
    var it = vp_first_non_phi(entry);
    while it >= 0 && vpr[it].kind == VPR_IR_INSTRUCTION { it = vpr[it].next; }
    vp_insert_recipe(r, entry, it);
    return vp_val(r);
}

// poisonGuaranteesUB
fn vp_poison_guarantees_ub(v: i32) -> bool {
    var visited = hm_new();
    var wl: i32[>..<] = [];
    wl.push(v);
    while wl.len > 0 {
        let cur = wl.pop();
        if hm_has(visited, cur as u64) { continue; }
        hm_put(visited, cur as u64, 1);
        for j in vp_num_users(cur) {
            let u = vp_user(cur, j);
            let k = vpr[u].kind;
            if vp_is_widen_memory_kind(k) { if vp_op(u, 0) == cur { return true; } continue; }
            if k == VPR_REPLICATE {
                let o = iop(vp_underlying_instr(u));
                if (o == OP_LOAD && vp_op(u, 0) == cur) || (o == OP_STORE && vp_op(u, 1) == cur) { return true; }
            }
            let propagates = k == VPR_WIDEN_GEP || k == VPR_WIDEN_CAST ||
                             (k == VPR_REPLICATE && (iop(vp_underlying_instr(u)) == OP_GEP || is_cast_op(iop(vp_underlying_instr(u)))));
            if propagates {
                for x in vp_nops(u) { if vp_op(u, x) == cur { wl.push(vpr[u].def); break; } }
            }
        }
    }
    return false;
}

// m_GetElementPtr(SourceElementType, Ops): the recipe or -1
fn vp_match_gep(v: i32) -> i32 {
    let r = vp_def(v);
    if r < 0 { return -1; }
    let k = vpr[r].kind;
    if k == VPR_WIDEN_GEP { return r; }
    if k == VPR_INSTRUCTION && (vpr[r].opcode == OP_GEP as i32 || vpr[r].opcode == VPI_PTR_ADD) { return r; }
    if k == VPR_REPLICATE && iop(vp_underlying_instr(r)) == OP_GEP { return r; }
    return -1;
}
fn vp_gep_source_element_type(r: i32) -> i32 {
    if vpr[r].kind == VPR_WIDEN_GEP { return vpr[r].src_elt_ty; }
    if vpr[r].kind == VPR_INSTRUCTION && vpr[r].opcode == VPI_PTR_ADD { return ty_int(8); }
    return insts[inst_of(vp_underlying_instr(r))].ty2;
}

var vps_ops: i32[>..<];     // scratch for getSCEVExprForVPValue's operand SCEVs (stack discipline)

// getSCEVExprForVPValue(V, PSE, L); l = -1 for no loop
recursive fn vp_scev_for_value(v: i32, pse: i32, l: i32) -> i32 {
    let kind = vpv[v].kind;
    if kind == VVK_REGION {
        if l < 0 { return SCEV_CNC; }
        let t = vpv[v].ty;
        return sc_addrec2(sc_get_zero(t), sc_get_one(t), l, 0);
    }
    if kind == VVK_IR || kind == VVK_SYMBOLIC {
        let li = vpv[v].uv;
        if li >= 0 && sc_is_scevable(vals[li].ty) { return sc_get_scev(li); }
        return SCEV_CNC;
    }
    let r = vp_def(v);
    let opc = vpm_opcode(r, true);
    // binary / unary operations with SCEV equivalents (CreateSCEV: operands first, then PSE.getPredicatedSCEV)
    if opc >= 0 && vpm_arity_ok(r, 2) {
        let o = opc as i64;
        if o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_UDIV || o == OP_UREM || o == OP_SREM {
            let a = vp_scev_for_value(vp_op(r, 0), pse, l);
            if sc_is_cnc(a) { return SCEV_CNC; }
            let b = vp_scev_for_value(vp_op(r, 1), pse, l);
            if sc_is_cnc(b) { return SCEV_CNC; }
            var e: i32 = SCEV_CNC;
            if o == OP_ADD { e = sc_add(a, b); }
            else if o == OP_SUB { e = sc_get_minus(a, b, 0, 0); }
            else if o == OP_MUL { e = sc_mul(a, b); }
            else if o == OP_UDIV { e = sc_get_udiv(a, b); }
            else if o == OP_UREM { e = sc_get_urem(a, b); }
            else {
                if !sc_is_known_non_negative(a) || !sc_is_known_non_negative(b) { e = SCEV_CNC; } else { e = sc_get_urem(a, b); }
            }
            return pse_get_predicated_scev(pse, e);
        }
        if o == OP_SHL || o == OP_LSHR || o == OP_AND {
            vp_unported("getSCEVExprForVPValue of shl / lshr / and");
        }
    }
    if opc == VPI_NOT { vp_unported("getSCEVExprForVPValue of not"); }
    if opc >= 0 && vpm_arity_ok(r, 1) && (opc as i64 == OP_TRUNC || opc as i64 == OP_ZEXT || opc as i64 == OP_SEXT) {
        if opc as i64 == OP_SEXT {
            let s0 = vp_def(vp_op(r, 0));
            if vpm_opcode(s0, true) == OP_SUB as i32 { vp_unported("getSCEVExprForVPValue of sext(sub)"); }
        }
        let a = vp_scev_for_value(vp_op(r, 0), pse, l);
        if sc_is_cnc(a) { return SCEV_CNC; }
        let dt = vp_scalar_type(v);
        var e: i32 = SCEV_CNC;
        if opc as i64 == OP_TRUNC { e = sc_get_truncate(a, dt, 0); }
        else if opc as i64 == OP_ZEXT { e = sc_get_zero_extend(a, dt, 0); }
        else { e = sc_get_sign_extend(a, dt, 0); }
        return pse_get_predicated_scev(pse, e);
    }
    if r >= 0 && (vpr[r].kind == VPR_WIDEN_INTRINSIC || (vpr[r].kind == VPR_INSTRUCTION && vpr[r].opcode == VPI_INTRINSIC) ||
                  (opc as i64 == OP_CALL)) {
        vp_unported("getSCEVExprForVPValue of an intrinsic");
    }
    let g = vp_match_gep(v);
    if g >= 0 {
        let src = vp_gep_source_element_type(g);
        let n = vp_nops(g);
        let mark = vps_ops.len;
        for k in n {
            let s = vp_scev_for_value(vp_op(g, k), pse, l);
            if sc_is_cnc(s) { vps_ops.resize(mark); return SCEV_CNC; }
            vps_ops.push(s);
        }
        let b0 = ss.len;
        for k in 1..n { ss.push(vps_ops[mark + k]); }
        let base = vps_ops[mark];
        vps_ops.resize(mark);
        let e = sc_get_gep_expr(base, b0, src, false, false);
        return pse_get_predicated_scev(pse, e);
    }
    if r < 0 { return SCEV_CNC; }
    let rk = vpr[r].kind;
    var e: i32 = SCEV_CNC;
    if rk == VPR_EXPAND_SCEV { e = vpr[r].expr; }
    else if rk == VPR_WIDEN_INT_OR_FP_INDUCTION {
        let step = vp_scev_for_value(vp_op(r, 1), pse, l);
        if l < 0 || sc_is_cnc(step) { e = SCEV_CNC; }
        else {
            let start = vp_scev_for_value(vp_op(r, 0), pse, l);
            let ar = sc_addrec2(start, step, l, 0);
            e = if vpr[r].ir_inst >= 0 { sc_get_truncate(ar, vpv[vpr[r].def].ty, 0) } else { ar };
        }
    } else if rk == VPR_WIDEN_POINTER_INDUCTION {
        let start = vp_scev_for_value(vp_op(r, 0), pse, l);
        if l < 0 || sc_is_cnc(start) { e = SCEV_CNC; }
        else {
            let step = vp_scev_for_value(vp_op(r, 1), pse, l);
            e = if sc_is_cnc(step) { SCEV_CNC } else { sc_addrec2(start, step, l, 0) };
        }
    } else if rk == VPR_DERIVED_IV {
        let start = vp_scev_for_value(vp_op(r, 0), pse, l);
        let iv = vp_scev_for_value(vp_op(r, 1), pse, l);
        let scale = vp_scev_for_value(vp_op(r, 2), pse, l);
        if sc_is_cnc(start) || sc_is_cnc(iv) || sc_is_cnc(scale) { e = SCEV_CNC; }
        else {
            e = sc_add(sc_get_truncate_or_sign_extend(start, sc_ty(iv), 0), sc_mul(iv, sc_get_truncate_or_sign_extend(scale, sc_ty(iv), 0)));
        }
    } else if rk == VPR_SCALAR_IV_STEPS {
        let iv = vp_scev_for_value(vp_op(r, 0), pse, l);
        let step = vp_scev_for_value(vp_op(r, 1), pse, l);
        if sc_is_cnc(iv) || !sc_is_const(step) { e = SCEV_CNC; } else { e = sc_get_truncate_or_sign_extend(iv, sc_ty(step), 0); }
    }
    return pse_get_predicated_scev(pse, e);
}

// getFlagsFromIndDesc
fn vp_flags_from_ind_desc(d: i32) -> VPF {
    let b = ind_descs[d].binop;
    if ind_descs[d].kind == IK_FP { return vpf_fmf(insts[inst_of(b)].fmf); }
    if b >= 0 && (iop(b) == OP_ADD || iop(b) == OP_SUB || iop(b) == OP_MUL || iop(b) == OP_SHL) {
        let fl = insts[inst_of(b)].flags;
        return vpf_wrap((fl & FL_NUW) != 0, (fl & FL_NSW) != 0);
    }
    return vpf_wrap(false, false);
}

// VPBlockUtils::getPlainCFGHeaderAndLatch / the middle block of the plain CFG
fn vpbu_plain_cfg_header() -> i32 { vp_single_succ(vp_succ(vph.entry, 1)) }
fn vpbu_plain_cfg_latch() -> i32 { vp_pred(vpbu_plain_cfg_header(), 1) }
fn vpbu_plain_cfg_middle_block() -> i32 { vp_pred(vp_scalar_preheader(), 0) }

// VPPhiAccessors
fn vp_phi_num_incoming(r: i32) -> i64 { if vp_is_widen_induction_kind(vpr[r].kind) { 1 } else { vp_nops(r) } }
fn vp_phi_incoming_block(r: i32, idx: i64) -> i32 { vp_cfg_predecessor(vpr[r].parent, idx) }
fn vp_phi_incoming_value_for_block(r: i32, b: i32) -> i32 {
    for k in vp_phi_num_incoming(r) { if vp_phi_incoming_block(r, k) == b { return vp_op(r, k); } }
    fatal("internal: VPlan phi has no incoming value for the block");
    return -1;
}
fn vp_phi_set_incoming_value_for_block(r: i32, b: i32, v: i32) {
    for k in vp_phi_num_incoming(r) { if vp_phi_incoming_block(r, k) == b { vp_set_operand(r, k, v); return; } }
    fatal("internal: VPlan phi has no incoming value for the block");
}
fn vp_phi_remove_incoming_value_for(r: i32, b: i32) {
    let idx = xv_find(vpb[vpr[r].parent].preds, b);
    vp_remove_operand(r, idx);
}
