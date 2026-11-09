// VPlan utilities: the VPlanPatternMatch matchers used by the port, vputils (VPlanUtils.cpp), VPSCEVExpander.
// Ported from llvm/lib/Transforms/Vectorize/VPlanPatternMatch.h, VPlanUtils.cpp, VPlanUtils.h (LLVM 23.1.5).

// ---------------------------------------------------------------- pattern matching (VPlanPatternMatch.h)

// The opcode a Recipe_match<..., VPWidenRecipe, VPReplicateRecipe, VPWidenCastRecipe, VPInstruction> sees
vpm_opcode :: (r: Vp_Rec, with_cast := true) -> (bool, u16) {
    if r == NONE return false, 0;
    k := vr(r).kind;
    if k == .INSTRUCTION || k == .WIDEN return true, vr(r).opcode;
    if k == .WIDEN_CAST && with_cast return true, vr(r).opcode;
    if k == .REPLICATE return true, vp_opc(inst_op(vp_underlying_instr(r)));
    return false, 0;
}
vpm_num_ops_without_mask :: (r: Vp_Rec) -> s64 {
    if vr(r).kind == .INSTRUCTION return vp_nops(r) - cast(s64) vp_is_masked(r);
    if vr(r).kind == .REPLICATE return vp_nops(r) - cast(s64) vr(r).predicated;
    return vp_nops(r);
}
// Recipe_match's operand-count rule: exactly n operands, or n plus a mask (masked VPInstruction / predicated replicate)
vpm_arity_ok :: (r: Vp_Rec, n: s64) -> bool {
    c := vp_nops(r);
    if c < n return false;
    if c > n {
        k := vr(r).kind;
        if k == .INSTRUCTION return vp_is_masked(r) && vpm_num_ops_without_mask(r) == n;
        if k == .REPLICATE return vr(r).predicated && vpm_num_ops_without_mask(r) == n;
        return false;
    }
    return true;
}
// m_Binary<Opcode>(m_VPValue(A), m_VPValue(B)) on a value: (ok, A, B)
vpm_binary :: (v: Vp_Val, opc: u16) -> (bool, Vp_Val, Vp_Val) {
    r := vp_def(v);
    ok, o := vpm_opcode(r);
    if !ok || o != opc || !vpm_arity_ok(r, 2) return false, NONE, NONE;
    return true, vp_op(r, 0), vp_op(r, 1);
}
vpm_binary_r :: (r: Vp_Rec, opc: u16) -> (bool, Vp_Val, Vp_Val) {
    ok, o := vpm_opcode(r);
    if !ok || o != opc || !vpm_arity_ok(r, 2) return false, NONE, NONE;
    return true, vp_op(r, 0), vp_op(r, 1);
}
vpm_unary :: (v: Vp_Val, opc: u16) -> (bool, Vp_Val) {
    r := vp_def(v);
    ok, o := vpm_opcode(r);
    if !ok || o != opc || !vpm_arity_ok(r, 1) return false, NONE;
    return true, vp_op(r, 0);
}
// m_VPInstruction<Opcode>(...) with n operands (VPInstruction only)
vpm_vpi :: (v: Vp_Val, opc: u16, n: s64) -> (bool, Vp_Rec) {
    r := vp_def(v);
    if !vp_is_vpi(r, opc) || !vpm_arity_ok(r, n) return false, NONE;
    return true, r;
}
vpm_vpi_r :: (r: Vp_Rec, opc: u16, n: s64) -> bool { return vp_is_vpi(r, opc) && vpm_arity_ok(r, n); }
// m_c_Binary (AllRecipe_commutative_match: VPWidenRecipe, VPReplicateRecipe, VPInstruction): (ok, A, B) trying the
// written order first, then the swapped one; `want_a` restricts A to a specific value (NONE = any)
vpm_c_binary_with :: (v: Vp_Val, opc: u16, want: Vp_Val) -> (bool, Vp_Val) {
    r := vp_def(v);
    ok, o := vpm_opcode(r, false);
    if !ok || o != opc || !vpm_arity_ok(r, 2) return false, NONE;
    if vp_op(r, 0) == want return true, vp_op(r, 1);
    if vp_op(r, 1) == want return true, vp_op(r, 0);
    return false, NONE;
}
// m_ZeroInt / m_One / m_AllOnes / m_SpecificInt on a live-in ConstantInt
vpm_zero_int :: (v: Vp_Val) -> bool { return vp_is_const_int_zero(v); }
vpm_one :: (v: Vp_Val) -> bool { return vp_is_const_int_one(v); }
vpm_all_ones :: (v: Vp_Val) -> bool { return vp_is_constant_int(v) && ap_is_all_ones(vp_const_int_value(v)); }
vpm_specific_int :: (v: Vp_Val, x: u64) -> bool {
    if !vp_is_constant_int(v) return false;
    a := vp_const_int_value(v);
    return ap_active_bits(a) <= 64 && ap_zext_value(a) == x;
}
vpm_constant_int :: (v: Vp_Val) -> (bool, u64) {   // m_ConstantInt(uint64_t &)
    if !vp_is_constant_int(v) return false, 0;
    a := vp_const_int_value(v);
    if ap_active_bits(a) > 64 return false, 0;
    return true, ap_zext_value(a);
}
// m_BranchOnCond(m_VPValue(C))
vpm_branch_on_cond :: (r: Vp_Rec) -> (bool, Vp_Val) {
    if !vpm_vpi_r(r, VPI_BRANCH_ON_COND, 1) return false, NONE;
    return true, vp_op(r, 0);
}
vpm_branch_on_count :: (r: Vp_Rec) -> (bool, Vp_Val, Vp_Val) {
    if !vpm_vpi_r(r, VPI_BRANCH_ON_COUNT, 2) return false, NONE, NONE;
    return true, vp_op(r, 0), vp_op(r, 1);
}
// m_Select (AllRecipe_match<Instruction::Select>)
vpm_select :: (v: Vp_Val) -> (bool, Vp_Val, Vp_Val, Vp_Val) {
    r := vp_def(v);
    ok, o := vpm_opcode(r);
    if !ok || o != vp_opc(.SELECT) || !vpm_arity_ok(r, 3) return false, NONE, NONE, NONE;
    return true, vp_op(r, 0), vp_op(r, 1), vp_op(r, 2);
}
// m_Cmp: ICmp or FCmp (AllRecipe_match)
vpm_cmp :: (v: Vp_Val) -> (bool, Vp_Val, Vp_Val) {
    ok, a, b := vpm_binary(v, vp_opc(.ICMP));
    if ok return ok, a, b;
    ok, a, b = vpm_binary(v, vp_opc(.FCMP));
    return ok, a, b;
}

// VPInstruction::isMasked / getNumOperandsForOpcode
vp_is_masked :: (r: Vp_Rec) -> bool {
    n := vp_num_operands_for_opcode(r);
    if n < 0 return false;
    return n + 1 == vp_nops(r);
}
vp_mask_of :: (r: Vp_Rec) -> Vp_Val { if vp_is_masked(r) return vp_op(r, vp_nops(r) - 1); return NONE; }
// VPInstruction::getNumOperandsForOpcode (-1: variadic)
vp_num_operands_for_opcode :: (r: Vp_Rec) -> s64 {
    o := vr(r).opcode;
    if vp_is_ir_opcode(o) {
        io := vp_ir_opcode(o);
        if io == .FNEG || is_cast_op(io) return 1;
        if is_binary_op(io) return 2;
        if io == .ALLOCA || io == .EXTRACTVALUE || io == .FREEZE || io == .LOAD return 1;
        if io == .ICMP || io == .FCMP || io == .STORE || io == .EXTRACTELEMENT return 2;
        if io == .SELECT || io == .INSERTELEMENT return 3;
        if io == .CALL return vp_called_fn_operand_index(r) + 1;
        return -1;   // GetElementPtr, PHI, Switch, AtomicRMW, ...
    }
    if o == {
        case VPI_STEP_VECTOR; #through; case VPI_INCOMING_ALIAS_MASK; return 0;
        case VPI_BRANCH_ON_COND; #through; case VPI_BROADCAST; #through; case VPI_EXITING_IV_VALUE; #through;
        case VPI_EXPLICIT_VECTOR_LENGTH; #through; case VPI_EXTRACT_LAST_LANE; #through; case VPI_EXTRACT_LAST_PART; #through;
        case VPI_EXTRACT_PENULTIMATE_ELEMENT; #through; case VPI_MASKED_COND; #through; case VPI_NOT; #through;
        case VPI_REVERSE; #through; case VPI_UNPACK; #through; case VPI_NUM_ACTIVE_LANES;
            return 1;
        case VPI_BRANCH_ON_COUNT; #through; case VPI_BRANCH_ON_TWO_CONDS; #through; case VPI_FIRST_ORDER_RECURRENCE_SPLICE; #through;
        case VPI_LOGICAL_AND; #through; case VPI_LOGICAL_OR; #through; case VPI_PTR_ADD; #through; case VPI_WIDE_PTR_ADD; #through;
        case VPI_WIDE_IV_STEP; #through; case VPI_CALCULATE_TRIP_COUNT_MINUS_VF; #through; case VPI_RESUME_FOR_EPILOGUE;
            return 2;
        case VPI_ACTIVE_LANE_MASK; #through; case VPI_REDUCTION_START_VECTOR; return 3;
    }
    return -1;
}

// ---------------------------------------------------------------- VPBlockUtils (VPlanUtils.cpp)

// getPlainCFGHeaderAndLatch
vpbu_plain_cfg_header_and_latch :: () -> (Vp_Blk, Vp_Blk) {
    header := vp_single_succ(vb(vpl.entry).succs[1]);
    latch := vb(header).preds[1];
    return header, latch;
}
vpbu_plain_cfg_middle_block :: () -> Vp_Blk { return vb(vp_scalar_preheader()).preds[0]; }
vpbu_is_header :: (b: Vp_Blk, dt: *Vp_Dom_Tree) -> bool {
    if !vp_is_basic(b) return false;
    r := vb(b).parent;
    if r != NONE return !vp_is_replicator(r) && vb(b).preds.count == 0;
    return vb(b).preds.count == 2 && vp_dt_dominates(dt, b, vb(b).preds[1]);
}
vpbu_is_latch :: (b: Vp_Blk, dt: *Vp_Dom_Tree) -> bool {
    s := vb(b).succs;
    return s.count >= 2 && vpbu_is_header(s[s.count - 1], dt);
}

// vp_rpo_plain_cfg_loop_body (VPlanCFG.h)
vp_rpo_plain_cfg_loop_body :: (header: Vp_Blk) -> [..] Vp_Blk {
    middle := vb(vb(header).preds[1]).succs[0];
    out: [..] Vp_Blk; out.allocator = temp;
    for vp_rpo(header, false) {
        if it == middle break;
        if vp_is_ir_basic(it) continue;
        array_add(*out, it);
    }
    return out;
}

// ---------------------------------------------------------------- vputils

// vputils::getOrCreateVPValueForSCEVExpr
vp_get_or_create_value_for_scev :: (e: Scev_Id) -> Vp_Val {
    if sc_is_const(e) return vp_live_in(sc_value(e));
    if sc_is_unknown(e) && !is_inst(sc_value(e)) return vp_live_in(sc_value(e));
    r := vp_new_expand_scev(e);
    entry := vpl.entry;
    it := vp_first_non_phi(entry);
    while it != NONE && vr(it).kind == .IR_INSTRUCTION it = vr(it).next;
    vp_insert_recipe(r, entry, it);
    return vr(r).def;
}
vp_new_expand_scev :: (e: Scev_Id) -> Vp_Rec {
    r := vp_new_single_def(.EXPAND_SCEV, .[], sc_type(e));
    vr(r).expr = e;
    return r;
}

// vputils::getSCEVExprForVPValue
vp_scev_for_value :: (v: Vp_Val, pse: *Pse, l: Loop_Id = NONE) -> Scev_Id {
    row := vv(v);
    if row.kind == .REGION {
        if l == NONE return SCEV_CNC;
        t := row.ty;
        return sc_get_add_rec(sc_get_zero(t), sc_get_one(t), l, SF_ANY);
    }
    if row.kind == .IR || row.kind == .SYMBOLIC {
        lv := row.uv;
        if lv != NONE && sc_is_scevable(vtype(lv)) return sc_get_scev(lv);
        return SCEV_CNC;
    }
    sub :: (x: Vp_Val, pse: *Pse, l: Loop_Id) -> Scev_Id { return vp_scev_for_value(x, pse, l); }
    two :: (a: Vp_Val, b: Vp_Val, pse: *Pse, l: Loop_Id) -> (bool, Scev_Id, Scev_Id) {
        x := vp_scev_for_value(a, pse, l); if sc_is_cnc(x) return false, 0, 0;
        y := vp_scev_for_value(b, pse, l); if sc_is_cnc(y) return false, 0, 0;
        return true, x, y;
    }
    ok, a, b := vpm_binary(v, vp_opc(.ADD));
    if ok { ok2, x, y := two(a, b, pse, l); if !ok2 return SCEV_CNC; return pse_get_predicated_scev(pse, sc_get_add2(x, y)); }
    ok, a, b = vpm_binary(v, vp_opc(.SUB));
    if ok { ok2, x, y := two(a, b, pse, l); if !ok2 return SCEV_CNC; return pse_get_predicated_scev(pse, sc_get_minus(x, y)); }
    okn, na := vpm_vpi(v, VPI_NOT, 1);
    if okn {
        x := sub(vp_op(na, 0), pse, l); if sc_is_cnc(x) return SCEV_CNC;
        return pse_get_predicated_scev(pse, sc_get_minus(sc_get_minus_one(sc_type(x)), x));
    }
    ok, a, b = vpm_binary(v, vp_opc(.MUL));
    if ok { ok2, x, y := two(a, b, pse, l); if !ok2 return SCEV_CNC; return pse_get_predicated_scev(pse, sc_get_mul2(x, y)); }
    ok, a, b = vpm_binary(v, vp_opc(.SHL));
    if ok {
        okc, sh := vpm_constant_int(b);
        if okc && sh < cast(u64) type_bits(vp_scalar_type(a)) {
            x := sub(a, pse, l); if sc_is_cnc(x) return SCEV_CNC;
            return pse_get_predicated_scev(pse, sc_get_mul2(x, sc_get_power_of_two(sc_type(x), cast(u32) sh)));
        }
    }
    ok, a, b = vpm_binary(v, vp_opc(.LSHR));
    if ok {
        okc, sh := vpm_constant_int(b);
        ty := vp_scalar_type(v);
        if okc && sh < cast(u64) sc_type_bits(ty) {
            x := sub(a, pse, l); if sc_is_cnc(x) return SCEV_CNC;
            return pse_get_predicated_scev(pse, sc_get_udiv(x, sc_get_power_of_two(ty, cast(u32) sh)));
        }
    }
    ok, a, b = vpm_binary(v, vp_opc(.UDIV));
    if ok { ok2, x, y := two(a, b, pse, l); if !ok2 return SCEV_CNC; return pse_get_predicated_scev(pse, sc_get_udiv(x, y)); }
    ok, a, b = vpm_binary(v, vp_opc(.UREM));
    if ok { ok2, x, y := two(a, b, pse, l); if !ok2 return SCEV_CNC; return pse_get_predicated_scev(pse, sc_get_urem(x, y)); }
    ok, a, b = vpm_binary(v, vp_opc(.SREM));
    if ok {
        ok2, x, y := two(a, b, pse, l); if !ok2 return SCEV_CNC;
        if !sc_is_known_non_negative(x) || !sc_is_known_non_negative(y) return pse_get_predicated_scev(pse, SCEV_CNC);
        return pse_get_predicated_scev(pse, sc_get_urem(x, y));
    }
    {
        r := vp_def(v);
        oko, o := vpm_opcode(r, false);
        if oko && o == vp_opc(.AND) && vpm_arity_ok(r, 2) {
            for side: 0..1 {
                lhs := vp_op(r, side); m := vp_op(r, 1 - side);
                if !vp_is_constant_int(m) continue;
                mp1 := ap_add(vp_const_int_value(m), ap_one(vp_const_int_value(m).bits));
                if !ap_is_power_of_2(mp1) break;
                x := sub(lhs, pse, l); if sc_is_cnc(x) return SCEV_CNC;
                return pse_get_predicated_scev(pse, sc_get_urem(x, sc_get_constant(mp1)));
            }
        }
    }
    oka, ca := vpm_unary(v, vp_opc(.TRUNC));
    if oka { x := sub(ca, pse, l); if sc_is_cnc(x) return SCEV_CNC; return pse_get_predicated_scev(pse, sc_get_truncate(x, vp_scalar_type(v))); }
    oka, ca = vpm_unary(v, vp_opc(.ZEXT));
    if oka { x := sub(ca, pse, l); if sc_is_cnc(x) return SCEV_CNC; return pse_get_predicated_scev(pse, sc_get_zero_extend(x, vp_scalar_type(v))); }
    oka, ca = vpm_unary(v, vp_opc(.SEXT));
    if oka {
        dty := vp_scalar_type(v);
        oks, sl, sr := vpm_binary(ca, vp_opc(.SUB));
        subr := vp_def(ca);
        if oks && subr != NONE && vp_is_with_ir_flags_kind(vr(subr).kind) && vr(subr).flags.optype == .OVERFLOWING_BINOP &&
           vr(subr).flags.nsw && vp_poison_guarantees_ub(ca) {
            v1 := sub(sl, pse, l); v2 := sub(sr, pse, l);
            if !sc_is_cnc(v1) && !sc_is_cnc(v2)
                return sc_get_minus(sc_get_sign_extend(v1, dty), sc_get_sign_extend(v2, dty), SF_NSW);
        }
        x := sub(ca, pse, l); if sc_is_cnc(x) return SCEV_CNC;
        return pse_get_predicated_scev(pse, sc_get_sign_extend(x, dty));
    }
    {
        id, r := vp_intrinsic_id_of_value(v);
        if id == IID_UMAX || id == IID_SMAX || id == IID_UMIN || id == IID_SMIN {
            ok2, x, y := two(vp_op(r, 0), vp_op(r, 1), pse, l); if !ok2 return SCEV_CNC;
            res: Scev_Id;
            if id == IID_UMAX res = sc_get_umax2(x, y);
            else if id == IID_SMAX res = sc_get_smax2(x, y);
            else if id == IID_UMIN res = sc_get_umin2(x, y);
            else res = sc_get_smin2(x, y);
            return pse_get_predicated_scev(pse, res);
        }
        if id == IID_ABS {
            x := sub(vp_op(r, 0), pse, l); if sc_is_cnc(x) return SCEV_CNC;
            return pse_get_predicated_scev(pse, sc_get_abs(x, false));
        }
    }
    {
        okg, gr := vp_match_gep(v);
        if okg {
            ops: [..] Scev_Id; ops.allocator = temp;
            for vr(gr).ops { x := sub(it, pse, l); if sc_is_cnc(x) return SCEV_CNC; array_add(*ops, x); }
            idx: [..] Scev_Id; idx.allocator = temp;
            for k: 1..ops.count-1 array_add(*idx, ops[k]);
            return pse_get_predicated_scev(pse, sc_get_gep(ops[0], idx, vp_gep_source_element_type(gr), 0, .[]));
        }
    }
    r := vp_def(v);
    e: Scev_Id = SCEV_CNC;
    if r != NONE {
        k := vr(r).kind;
        if k == .EXPAND_SCEV e = vr(r).expr;
        else if k == .WIDEN_INT_OR_FP_INDUCTION {
            step := sub(vp_op(r, 1), pse, l);
            if l != NONE && !sc_is_cnc(step) {
                start := sub(vp_op(r, 0), pse, l);
                e = sc_get_add_rec(start, step, l, SF_ANY);
                if vr(r).ir_inst != NONE e = sc_get_truncate(e, vp_scalar_type(v));
            }
        } else if k == .WIDEN_POINTER_INDUCTION {
            start := sub(vp_op(r, 0), pse, l);
            if l != NONE && !sc_is_cnc(start) {
                step := sub(vp_op(r, 1), pse, l);
                if !sc_is_cnc(step) e = sc_get_add_rec(start, step, l, SF_ANY);
            }
        } else if k == .DERIVED_IV {
            s0 := sub(vp_op(r, 0), pse, l); iv := sub(vp_op(r, 1), pse, l); sc := sub(vp_op(r, 2), pse, l);
            if !sc_is_cnc(s0) && !sc_is_cnc(iv) && !sc_is_cnc(sc) {
                t := sc_type(iv);
                e = sc_get_add2(sc_get_truncate_or_sign_extend(s0, t), sc_get_mul2(iv, sc_get_truncate_or_sign_extend(sc, t)));
            }
        } else if k == .SCALAR_IV_STEPS {
            iv := sub(vp_op(r, 0), pse, l); step := sub(vp_op(r, 1), pse, l);
            if !sc_is_cnc(iv) && sc_is_const(step) e = sc_get_truncate_or_sign_extend(iv, sc_type(step));
        }
    }
    return pse_get_predicated_scev(pse, e);
}
// m_GetElementPtr(SourceElementType, Ops): a VPInstruction GEP or a VPWidenGEPRecipe / VPReplicateRecipe of a GEP
vp_match_gep :: (v: Vp_Val) -> (bool, Vp_Rec) {
    r := vp_def(v);
    if r == NONE return false, NONE;
    k := vr(r).kind;
    if k == .WIDEN_GEP return true, r;
    if k == .INSTRUCTION && vr(r).opcode == vp_opc(.GEP) return true, r;
    if k == .REPLICATE && inst_op(vp_underlying_instr(r)) == .GEP && !vr(r).predicated return true, r;
    return false, NONE;
}
vp_gep_source_element_type :: (r: Vp_Rec) -> Type_Id {
    if vr(r).kind == .WIDEN_GEP return vr(r).src_elt_ty;
    return gep_source_type(vp_underlying_instr(r));
}
// poisonGuaranteesUB
vp_poison_guarantees_ub :: (v: Vp_Val) -> bool {
    visited: Table(Vp_Val, bool); visited.allocator = temp;
    wl: [..] Vp_Val; wl.allocator = temp;
    array_add(*wl, v);
    while wl.count {
        cur := pop(*wl);
        if table_contains(*visited, cur) continue;
        table_set(*visited, cur, true);
        for u: vv(cur).users {
            k := vr(u).kind;
            if vp_is_widen_memory_kind(k) { if vp_op(u, 0) == cur return true; continue; }
            if k == .REPLICATE {
                o := inst_op(vp_underlying_instr(u));
                if (o == .LOAD && vp_op(u, 0) == cur) || (o == .STORE && vp_op(u, 1) == cur) return true;
            }
            propagates := k == .WIDEN_GEP || k == .WIDEN_CAST ||
                          (k == .REPLICATE && (inst_op(vp_underlying_instr(u)) == .GEP || is_cast_op(inst_op(vp_underlying_instr(u)))));
            if propagates for o: vr(u).ops if o == cur { array_add(*wl, vr(u).def); break; }
        }
    }
    return false;
}
// vputils::getIntrinsicID for a value's defining recipe: (id, recipe)
vp_intrinsic_id_of_value :: (v: Vp_Val) -> (Intrinsic_Id, Vp_Rec) {
    r := vp_def(v);
    if r == NONE return NOT_INTRINSIC, NONE;
    return vp_intrinsic_id(r), r;
}
vp_intrinsic_id :: (r: Vp_Rec) -> Intrinsic_Id {
    k := vr(r).kind;
    if k == .WIDEN_INTRINSIC || k == .WIDEN_MEM_INTRINSIC return vr(r).iid;
    callee_iid :: (c: Vp_Val) -> Intrinsic_Id {
        if !vp_is_ir_value(c) return NOT_INTRINSIC;
        f := vp_ir(c);
        if vkind(f) != .FUNCTION || !glob(f).intrinsic return NOT_INTRINSIC;
        return fn_iid(f);
    }
    if k == .WIDEN_CALL return callee_iid(vp_op(r, vp_nops(r) - 1));
    if k == .REPLICATE && inst_op(vp_underlying_instr(r)) == .CALL return callee_iid(vp_op(r, vpm_num_ops_without_mask(r) - 1));
    if k == .INSTRUCTION {
        if vr(r).opcode == vp_opc(.CALL) return callee_iid(vp_op(r, vp_nops(r) - 1));
        if vr(r).opcode == VPI_INTRINSIC return cast(Intrinsic_Id) ap_zext_value(vp_const_int_value(vp_op(r, vp_nops(r) - 1)));
    }
    return NOT_INTRINSIC;
}

// vputils::getFlagsFromIndDesc
vp_flags_from_ind_desc :: (d: *Ind_Desc) -> Vp_Flags {
    if d.kind == .FP return vpf_fmf(inst_fmf(d.bop));
    if d.bop != NONE && (inst_op(d.bop) == .ADD || inst_op(d.bop) == .SUB || inst_op(d.bop) == .MUL || inst_op(d.bop) == .SHL)
        return vpf_wrap(inst_has_nuw(d.bop), inst_has_nsw(d.bop));
    return vpf_wrap(false, false);
}

// vputils::findCanonicalIVIncrement
vp_find_canonical_iv_increment :: () -> Vp_Rec {
    region := vp_vector_loop_region();
    can_iv := vb(region).can_iv;
    vfxuf := vpl.vfxuf;
    is_step :: (step: Vp_Val) -> bool {
        if !vv(vpl.vfxuf).materialized return step == vpl.vfxuf;
        if !vv(vpl.uf).materialized {
            if step == vpl.uf return true;
            vp_unported("findCanonicalIVIncrement with a vscale step");
        }
        okz, x := vpm_unary(step, vp_opc(.ZEXT));
        if !okz { okz, x = vpm_unary(step, vp_opc(.TRUNC)); }
        if !okz x = step;
        if vp_val_is_vpi(x, VPI_NUM_ACTIVE_LANES) return true;
        uf := vpl.ufs[0];
        if vpm_specific_int(step, uf) return true;
        return false;
    }
    inc: Vp_Rec = NONE;
    for u: vv(can_iv).users {
        if vr(u).kind != .INSTRUCTION continue;
        ok, step := vpm_c_binary_with(vr(u).def, vp_opc(.ADD), can_iv);
        if ok && is_step(step) inc = u;
    }
    return inc;
}

// ---------------------------------------------------------------- VPSCEVExpander

Vp_Scev_Expander :: struct { b: *Vp_Builder; dl: Md_Id; }

vpsx_try_to_reuse_ir_value :: (x: *Vp_Scev_Expander, s: Scev_Id) -> Vp_Val {
    if sc_is_const(s) || sc_is_unknown(s) return NONE;
    ph := vb(vpl.entry).irbb;
    for v: sc_get_scev_values(s) {
        if !is_inst(v) return vp_live_in(v);
        if !dt_dominates(se.dt, inst_block(v), ph) continue;
        drops: [..] Value_Id; drops.allocator = temp;
        if !sc_can_reuse_instruction(s, v, *drops) continue;
        for d: drops sx_drop_poison_generating_annotations_and_reinfer(d);
        return vp_live_in(v);
    }
    return NONE;
}
// VPSCEVExpander::tryToExpand
vpsx_try_to_expand :: (x: *Vp_Scev_Expander, s: Scev_Id) -> Vp_Val {
    reuse := vpsx_try_to_reuse_ir_value(x, s);
    if reuse != NONE return reuse;
    k := sc_kind(s);
    if k == .CONSTANT || k == .UNKNOWN return vp_live_in(sc_value(s));
    if k == .VSCALE { vp_unported("VPSCEVExpander of vscale"); return NONE; }
    if k == .ADD || k == .MUL {
        nuw := sc_has_nuw(s); nsw := sc_has_nsw(s);
        if type_kind(sc_type(s)) == .PTR {
            base := vpsx_try_to_expand(x, sc_get_pointer_base(s));
            if base == NONE return NONE;
            off := vpsx_try_to_expand(x, sc_remove_pointer_base(s));
            if off == NONE return NONE;
            return vr(vpb_no_wrap_ptr_add(x.b, base, off, ifx nuw then cast(u32) F_GEP_NUW else 0, x.dl)).def;
        }
        opc := ifx k == .ADD then Opcode.ADD else .MUL;
        ops: [..] Vp_Val; ops.allocator = temp;
        n := sc_nops(s);
        k2 := cast(s64) n - 1;
        while k2 >= 0 {
            ov := vpsx_try_to_expand(x, sc_op(s, cast(u32) k2));
            if ov == NONE return NONE;
            array_add(*ops, ov);
            k2 -= 1;
        }
        result := ops[0];
        for i: 1..ops.count-1 result = vr(vpb_overflowing(x.b, opc, .[result, ops[i]], nuw, nsw, x.dl)).def;
        return result;
    }
    if k == .UDIV {
        l := vpsx_try_to_expand(x, sc_op(s, 0)); if l == NONE return NONE;
        r := vpsx_try_to_expand(x, sc_op(s, 1)); if r == NONE return NONE;
        return vr(vpb_nary(x.b, vp_opc(.UDIV), .[l, r], vpf_exact(false), .[], x.dl)).def;
    }
    if k == .TRUNC || k == .ZEXT || k == .SEXT {
        o := vpsx_try_to_expand(x, sc_op(s, 0)); if o == NONE return NONE;
        opc := ifx k == .TRUNC then Opcode.TRUNC else ifx k == .ZEXT then Opcode.ZEXT else .SEXT;
        return vr(vpb_scalar_cast(x.b, opc, o, sc_type(s), x.dl, vp_default_flags(vp_opc(opc), sc_type(s)))).def;
    }
    if k == .UMAX || k == .SMAX || k == .UMIN || k == .SMIN {
        vp_unported("VPSCEVExpander of min/max expressions");
    }
    return NONE;
}

// IR flag accessors used by VPIRFlags(Instruction &)
inst_has_nuw :: (i: Value_Id) -> bool { return has_nuw(i); }
inst_has_nsw :: (i: Value_Id) -> bool { return has_nsw(i); }
inst_has_exact :: (i: Value_Id) -> bool { return is_exact(i); }
inst_has_disjoint :: (i: Value_Id) -> bool { return is_exact(i); }
inst_has_nneg :: (i: Value_Id) -> bool { return is_exact(i); }
gep_nowrap_flags :: (i: Value_Id) -> u32 { return gep_flags_of(inst(i).flags); }
gep_source_type :: (i: Value_Id) -> Type_Id { return inst(i).ty2; }
