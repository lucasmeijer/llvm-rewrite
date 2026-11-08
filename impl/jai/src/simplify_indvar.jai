// Induction variable simplification and widening.
// Port of llvm/lib/Transforms/Utils/SimplifyIndVar.cpp (LLVM 23.1.5): SimplifyIndvar (foldIVUser,
// makeIVComparisonInvariant, eliminateIVComparison, eliminateSDiv, the remainder rewrites, eliminateOverflowIntrinsic,
// eliminateSaturatingIntrinsic, eliminateTrunc, eliminateIVUser, replaceIVUserWithLoopInvariant,
// replaceFloatIVWithIntegerIV, eliminateIdentitySCEV, strengthenBinaryOp / OverflowingOperation / RightShift,
// pushIVUsers, isSimpleIVUser, simplifyUsers), simplifyUsersOfIV, simplifyLoopIVs, and WidenIV (createWideIV and
// everything it calls: getInsertPointForUses, createExtendInst, cloneIVUser / Arithmetic / Bitwise,
// getExtendedOperandRecurrence, getWideRecurrence, truncateIVUse, widenLoopCompare, widenWithVariantUse, widenIVUse,
// pushNarrowIVUsers, calculatePostIncRange(s)).
//
// SimplifyIndvar is `Siv` (one per simplifyUsersOfIV call), WidenIV is `Widen_IV`. IVVisitor has one implementation
// that matters (IndVarSimplifyVisitor::visitCast = visitIVCast), so the visitor is an optional *Wide_IV_Info.
// DeadInsts (SmallVectorImpl<WeakTrackingVH>) is a `*[..] Vh` of value_handles.jai slots.

// WideIVInfo
Wide_IV_Info :: struct {
    narrow_iv: Value_Id = NONE;
    widest_native_type: Type_Id = NONE;
    is_signed: bool;
}

Siv :: struct {
    l: Loop_Id;
    li: *Loop_Info;
    dt: *Dom_Tree;
    tti: *Tti;
    rw: *Scev_Expander;
    dead: *[..] Vh;
    changed: bool;
    run_unswitching: bool;
}

dead_push :: (dead: *[..] Vh, v: Value_Id) { array_add(dead, vh_new(v)); }

Iv_Use_Pair :: struct { use: Value_Id; oper: Value_Id; }

// findCommonDominator
siv_find_common_dominator :: (insts: [] Value_Id, dt: *Dom_Tree) -> Value_Id {
    common: Value_Id = NONE;
    for insts common = ifx common != NONE then dt_find_nearest_common_dominator_inst(dt, common, it) else it;
    return common;
}

// foldIVUser
siv_fold_iv_user :: (s: *Siv, use_inst: Value_Id, iv_operand: Value_Id) -> Value_Id {
    iv_src: Value_Id = NONE;
    oper_idx: u32 = 0;
    folded := SCEV_NULL;
    must_drop_exact := false;
    o := inst_op(use_inst);
    if o != .UDIV && o != .LSHR return NONE;
    if iv_operand != op(use_inst, oper_idx) || vkind(op(use_inst, 1)) != .C_INT return NONE;
    if !is_binary_operator(iv_operand) || vkind(op(iv_operand, 1)) != .C_INT return NONE;
    iv_src = op(iv_operand, 0);
    d := op(use_inst, 1);
    if o == .LSHR {
        bw := type_int_width(vtype(use_inst));
        dv := const_ap(d);
        if ap_uge_u64(dv, bw) return NONE;
        d = const_int_ap(vtype(use_inst), ap_shl(ap_one(bw), cast(u32) ap_zext_value(dv)));
    }
    lhs := sc_get_scev(iv_src);
    rhs := sc_get_scev(d);
    folded = sc_get_udiv(lhs, rhs);
    if (inst(use_inst).flags & F_EXACT) && lhs != sc_get_mul2(folded, rhs) must_drop_exact = true;
    if !sc_is_scevable(vtype(use_inst)) return NONE;
    if sc_get_scev(use_inst) != folded return NONE;
    set_op(use_inst, oper_idx, iv_src);
    if must_drop_exact drop_poison_generating_flags(use_inst);
    s.changed = true;
    if !has_uses(iv_operand) dead_push(s.dead, iv_operand);
    return iv_src;
}

// makeIVComparisonInvariant
siv_make_iv_comparison_invariant :: (s: *Siv, icmp: Value_Id, iv_operand: Value_Id) -> bool {
    ph := li_loop_preheader(s.li, s.l);
    if ph == NONE return false;
    iv_idx: u32 = 0;
    pred := inst_pred(icmp);
    if iv_operand != op(icmp, 0) { iv_idx = 1; pred = icmp_swapped(pred); }
    icmp_loop := li_loop_for(s.li, inst_block(icmp));
    sv := sc_get_scev_at_scope_value(op(icmp, iv_idx), icmp_loop);
    xv := sc_get_scev_at_scope_value(op(icmp, 1 - iv_idx), icmp_loop);
    lip := sc_get_loop_invariant_predicate(pred, sv, xv, s.l, icmp);
    if !lip.ok return false;
    ph_term := block_terminator(ph);
    if sx_is_high_cost_expansion(s.rw, .[lip.lhs, lip.rhs], s.l, 2 * scev_cheap_expansion_budget, s.tti, ph_term) ||
       !sx_is_safe_to_expand_at(s.rw, lip.lhs, ph_term) || !sx_is_safe_to_expand_at(s.rw, lip.rhs, ph_term)
        return false;
    new_lhs := sx_expand_code_for_at(s.rw, lip.lhs, vtype(iv_operand), ph_term);
    new_rhs := sx_expand_code_for_at(s.rw, lip.rhs, vtype(iv_operand), ph_term);
    inst(icmp).pred = lip.pred;
    set_op(icmp, 0, new_lhs);
    set_op(icmp, 1, new_rhs);
    s.run_unswitching = true;
    return true;
}

// eliminateIVComparison
siv_eliminate_iv_comparison :: (s: *Siv, icmp: Value_Id, iv_operand: Value_Id) {
    iv_idx: u32 = 0;
    pred := inst_pred(icmp);
    original_pred := pred;
    if iv_operand != op(icmp, 0) { iv_idx = 1; pred = icmp_swapped(pred); }
    icmp_loop := li_loop_for(s.li, inst_block(icmp));
    sv := sc_get_scev_at_scope_value(op(icmp, iv_idx), icmp_loop);
    xv := sc_get_scev_at_scope_value(op(icmp, 1 - iv_idx), icmp_loop);
    users := sx_users(icmp);
    cxt := siv_find_common_dominator(users, s.dt);
    known, ev := sc_evaluate_predicate_at(pred, sv, xv, cxt);
    if known {
        sc_forget_value(icmp);
        rauw_with_metadata(icmp, const_int(ir.t_i1, ifx ev then cast(u64) 1 else 0));
        dead_push(s.dead, icmp);
        s.changed = true;
        return;
    }
    if siv_make_iv_comparison_invariant(s, icmp, iv_operand) { s.changed = true; return; }
    has_samesign := (inst(icmp).flags & F_EXACT) != 0;
    if (icmp_is_signed(original_pred) || (icmp_is_unsigned(original_pred) && !has_samesign)) && sc_have_same_sign(sv, xv) {
        inst(icmp).pred = icmp_unsigned_predicate(original_pred);
        inst(icmp).flags |= F_EXACT;
        s.changed = true;
        return;
    }
}

// eliminateSDiv
siv_eliminate_sdiv :: (s: *Siv, sdiv: Value_Id) -> bool {
    n := sc_get_scev(op(sdiv, 0));
    d := sc_get_scev(op(sdiv, 1));
    l := li_loop_for(s.li, inst_block(sdiv));
    n = sc_get_scev_at_scope(n, l);
    d = sc_get_scev_at_scope(d, l);
    if sc_is_known_non_negative(n) && sc_is_known_non_negative(d) {
        udiv := create_binop(.UDIV, op(sdiv, 0), op(sdiv, 1));
        siv_insert_before(udiv, sdiv, tprint("%.udiv", vname(sdiv)));
        if inst(sdiv).flags & F_EXACT inst(udiv).flags |= F_EXACT;
        rauw_with_metadata(sdiv, udiv);
        copy_debug_loc(udiv, sdiv);
        s.changed = true;
        dead_push(s.dead, sdiv);
        return true;
    }
    return false;
}

// replaceSRemWithURem
siv_replace_srem_with_urem :: (s: *Siv, rem: Value_Id) {
    n := op(rem, 0); d := op(rem, 1);
    urem := create_binop(.UREM, n, d);
    siv_insert_before(urem, rem, tprint("%.urem", vname(rem)));
    rauw_with_metadata(rem, urem);
    copy_debug_loc(urem, rem);
    s.changed = true;
    dead_push(s.dead, rem);
}
// replaceRemWithNumerator
siv_replace_rem_with_numerator :: (s: *Siv, rem: Value_Id) {
    rauw_with_metadata(rem, op(rem, 0));
    s.changed = true;
    dead_push(s.dead, rem);
}
// replaceRemWithNumeratorOrZero
siv_replace_rem_with_numerator_or_zero :: (s: *Siv, rem: Value_Id) {
    t := vtype(rem);
    n := op(rem, 0); d := op(rem, 1);
    icmp := create_icmp(ICMP_EQ, n, d);
    siv_insert_before(icmp, rem, "");
    copy_debug_loc(icmp, rem);
    sel := new_inst(.SELECT, t, 3);
    set_op(sel, 0, icmp); set_op(sel, 1, const_int(t, 0)); set_op(sel, 2, n);
    siv_insert_before(sel, rem, "iv.rem");
    rauw_with_metadata(rem, sel);
    copy_debug_loc(sel, rem);
    s.changed = true;
    dead_push(s.dead, rem);
}

// simplifyIVRemainder
siv_simplify_iv_remainder :: (s: *Siv, rem: Value_Id, iv_operand: Value_Id, is_signed: bool) {
    n_value := op(rem, 0); d_value := op(rem, 1);
    used_as_numerator := iv_operand == n_value;
    if !used_as_numerator && !is_signed return;
    n := sc_get_scev(n_value);
    icmp_loop := li_loop_for(s.li, inst_block(rem));
    n = sc_get_scev_at_scope(n, icmp_loop);
    nonneg := !is_signed || sc_is_known_non_negative(n);
    if !nonneg return;
    d := sc_get_scev(d_value);
    d = sc_get_scev_at_scope(d, icmp_loop);
    if used_as_numerator {
        lt: u8 = ifx is_signed then cast(u8) ICMP_SLT else ICMP_ULT;
        if sc_is_known_predicate(lt, n, d) { siv_replace_rem_with_numerator(s, rem); return; }
        n_less_one := sc_get_minus(n, sc_get_one(vtype(rem)));
        if sc_is_known_predicate(lt, n_less_one, d) { siv_replace_rem_with_numerator_or_zero(s, rem); return; }
    }
    if !is_signed || !sc_is_known_non_negative(d) return;
    siv_replace_srem_with_urem(s, rem);
}

// eliminateOverflowIntrinsic
siv_eliminate_overflow_intrinsic :: (s: *Siv, wo: Value_Id) -> bool {
    id := call_iid(wo);
    lhs_v := call_arg(wo, 0); rhs_v := call_arg(wo, 1);
    lhs := sc_get_scev(lhs_v);
    rhs := sc_get_scev(rhs_v);
    if !sc_will_not_overflow(wo_binary_op(id), wo_is_signed(id), lhs, rhs) return false;
    new_result := create_binop(wo_binary_op(id), lhs_v, rhs_v);
    siv_insert_before(new_result, wo, "");
    if wo_is_signed(id) inst(new_result).flags |= F_NSW; else inst(new_result).flags |= F_NUW;
    to_delete: [..] Value_Id; to_delete.allocator = temp;
    for evi: sx_users(wo) {
        if !is_inst(evi) || inst_op(evi) != .EXTRACTVALUE continue;
        if ir.u32_pool[inst(evi).idx] == 1 rauw_with_metadata(evi, const_int(ir.t_i1, 0));
        else {
            rauw_with_metadata(evi, new_result);
            copy_debug_loc(new_result, evi);
        }
        array_add(*to_delete, evi);
    }
    for to_delete erase_inst_with_metadata(it);
    if !has_uses(wo) erase_inst_with_metadata(wo);
    s.changed = true;
    return true;
}

// SaturatingInst: (is, binop, signed)
sat_intrinsic_info :: (v: Value_Id) -> (bool, Opcode, bool) {
    id := call_iid(v);
    if id == IID_UADD_SAT return true, .ADD, false;
    if id == IID_SADD_SAT return true, .ADD, true;
    if id == IID_USUB_SAT return true, .SUB, false;
    if id == IID_SSUB_SAT return true, .SUB, true;
    return false, .ADD, false;
}

// eliminateSaturatingIntrinsic
siv_eliminate_saturating_intrinsic :: (s: *Siv, si: Value_Id, opc: Opcode, signed: bool) -> bool {
    lhs_v := call_arg(si, 0); rhs_v := call_arg(si, 1);
    if !sc_will_not_overflow(opc, signed, sc_get_scev(lhs_v), sc_get_scev(rhs_v)) return false;
    bo := create_binop(opc, lhs_v, rhs_v);
    siv_insert_before(bo, si, vname(si));
    if signed inst(bo).flags |= F_NSW; else inst(bo).flags |= F_NUW;
    rauw_with_metadata(si, bo);
    copy_debug_loc(bo, si);
    dead_push(s.dead, si);
    s.changed = true;
    return true;
}

// Loop::makeLoopInvariant(V, Changed) without ScalarEvolution
li_make_loop_invariant_no_se :: (li: *Loop_Info, l: Loop_Id, v: Value_Id) -> bool {
    saved := scev_pass_se;
    scev_pass_se = null;
    changed := false;
    r := li_make_loop_invariant(li, l, v, *changed, NONE, null);
    scev_pass_se = saved;
    return r;
}

// eliminateTrunc
siv_eliminate_trunc :: (s: *Siv, ti: Value_Id) -> bool {
    iv := op(ti, 0);
    iv_ty := vtype(iv);
    iv_scev := sc_get_scev(iv);
    ti_scev := sc_get_scev(ti);
    does_sext_collapse := iv_scev == sc_get_sign_extend(ti_scev, iv_ty);
    does_zext_collapse := iv_scev == sc_get_zero_extend(ti_scev, iv_ty);
    if !does_sext_collapse && !does_zext_collapse return false;
    icmp_users: [..] Value_Id; icmp_users.allocator = temp;
    for u: sx_users(ti) {
        if is_inst(u) && !dt_is_reachable_from_entry(s.dt, inst_block(u)) continue;
        if !is_inst(u) || inst_op(u) != .ICMP return false;
        if !(op(u, 0) == ti && li_is_loop_invariant(s.li, s.l, op(u, 1))) &&
           !(op(u, 1) == ti && li_is_loop_invariant(s.li, s.l, op(u, 0))) return false;
        p := inst_pred(u);
        if icmp_is_signed(p) && !does_sext_collapse return false;
        if icmp_is_unsigned(p) && !does_zext_collapse return false;
        array_add(*icmp_users, u);
    }
    can_use_zext :: (s: *Siv, ici: Value_Id, does_zext_collapse: bool) -> bool {
        p := inst_pred(ici);
        if icmp_is_unsigned(p) return true;
        if !does_zext_collapse return false;
        if icmp_is_equality(p) return true;
        a := sc_get_scev(op(ici, 0));
        b := sc_get_scev(op(ici, 1));
        return sc_is_known_non_negative(a) && sc_is_known_non_negative(b);
    }
    for ici: icmp_users {
        is_swapped := li_is_loop_invariant(s.li, s.l, op(ici, 0));
        op1 := ifx is_swapped then op(ici, 0) else op(ici, 1);
        b: Irb;
        irb_set_before(*b, ici);
        ext: Value_Id;
        pred := inst_pred(ici);
        if is_swapped pred = icmp_swapped(pred);
        if can_use_zext(s, ici, does_zext_collapse) {
            ext = irb_cast(*b, .ZEXT, op1, iv_ty, "zext");
            pred = icmp_unsigned_predicate(pred);
        } else {
            ext = irb_cast(*b, .SEXT, op1, iv_ty, "sext");
        }
        li_make_loop_invariant_no_se(s.li, s.l, ext);
        new_cmp := irb_icmp(*b, pred, iv, ext);
        rauw_with_metadata(ici, new_cmp);
        dead_push(s.dead, ici);
    }
    rauw_with_metadata(ti, const_poison(vtype(ti)));
    dead_push(s.dead, ti);
    return true;
}

// eliminateIVUser
siv_eliminate_iv_user :: (s: *Siv, use_inst: Value_Id, iv_operand: Value_Id) -> bool {
    o := inst_op(use_inst);
    if o == .ICMP { siv_eliminate_iv_comparison(s, use_inst, iv_operand); return true; }
    if is_binary_op(o) {
        is_srem := o == .SREM;
        if is_srem || o == .UREM { siv_simplify_iv_remainder(s, use_inst, iv_operand, is_srem); return true; }
        if o == .SDIV return siv_eliminate_sdiv(s, use_inst);
    }
    if is_with_overflow_inst(use_inst) && siv_eliminate_overflow_intrinsic(s, use_inst) return true;
    is_sat, sop, ssigned := sat_intrinsic_info(use_inst);
    if is_sat && siv_eliminate_saturating_intrinsic(s, use_inst, sop, ssigned) return true;
    if o == .TRUNC && siv_eliminate_trunc(s, use_inst) return true;
    if siv_eliminate_identity_scev(s, use_inst, iv_operand) return true;
    return false;
}

// replaceIVUserWithLoopInvariant
siv_replace_iv_user_with_loop_invariant :: (s: *Siv, i: Value_Id) -> bool {
    if !sc_is_scevable(vtype(i)) return false;
    sv := sc_get_scev(i);
    if !sc_is_loop_invariant(sv, s.l) return false;
    if sx_is_high_cost_expansion(s.rw, .[sv], s.l, scev_cheap_expansion_budget, s.tti, i) return false;
    ph := li_loop_preheader(s.li, s.l);
    ip := ifx ph != NONE then block_terminator(ph) else i;   // GetLoopInvariantInsertPosition
    if !sx_is_safe_to_expand_at(s.rw, sv, ip) return false;
    invariant := sx_expand_code_for_at(s.rw, sv, vtype(i), ip);
    need_lcssa := !li_replacement_preserves_lcssa_form(s.li, i, invariant);
    rauw_with_metadata(i, invariant);
    if need_lcssa {
        work: [..] Value_Id; work.allocator = temp;
        array_add(*work, invariant);
        cache: Lcssa_Exit_Cache;
        form_lcssa_for_instructions(*work, s.dt, s.li, *cache);
    }
    s.changed = true;
    dead_push(s.dead, i);
    return true;
}

// Type::getFPMantissaWidth
fp_mantissa_width :: (t: Type_Id) -> s32 {
    k := type_kind(t);
    if k == .HALF return 11;
    if k == .BFLOAT return 8;
    if k == .FLOAT return 24;
    if k == .DOUBLE return 53;
    if k == .X86_FP80 return 64;
    if k == .FP128 return 113;
    return -1;
}

// replaceFloatIVWithIntegerIV (returns the pass's Changed flag, as LLVM does)
siv_replace_float_iv_with_integer_iv :: (s: *Siv, use_inst: Value_Id) -> bool {
    uo := inst_op(use_inst);
    if uo != .SITOFP && uo != .UITOFP return false;
    iv_operand := op(use_inst, 0);
    iv := sc_get_scev(iv_operand);
    mask_bits: s32;
    if uo == .SITOFP mask_bits = cast(s32) cr_min_signed_bits(sc_signed_range(iv));
    else mask_bits = cast(s32) cr_active_bits(sc_unsigned_range(iv));
    dest_bits := fp_mantissa_width(vtype(use_inst));
    if mask_bits <= dest_bits {
        for ci: sx_users(use_inst) {
            if !is_inst(ci) || !is_cast_op(inst_op(ci)) continue;
            co := inst_op(ci);
            if co != .FPTOSI && co != .FPTOUI continue;
            conv: Value_Id;
            if vtype(iv_operand) != vtype(ci) {
                b: Irb;
                irb_set_before(*b, ci);
                nm := vname(iv_operand);
                if sc_type_bits(vtype(iv_operand)) > sc_type_bits(vtype(ci)) conv = irb_cast(*b, .TRUNC, iv_operand, vtype(ci), tprint("%.trunc", nm));
                else if co == .FPTOUI || uo == .UITOFP conv = irb_cast(*b, .ZEXT, iv_operand, vtype(ci), tprint("%.zext", nm));
                else conv = irb_cast(*b, .SEXT, iv_operand, vtype(ci), tprint("%.sext", nm));
            } else conv = iv_operand;
            rauw_with_metadata(ci, conv);
            dead_push(s.dead, ci);
            s.changed = true;
        }
    }
    return s.changed;
}

// eliminateIdentitySCEV
siv_eliminate_identity_scev :: (s: *Siv, use_inst: Value_Id, iv_operand: Value_Id) -> bool {
    if !sc_is_scevable(vtype(use_inst)) || vtype(use_inst) != vtype(iv_operand) return false;
    use_scev := sc_get_scev(use_inst);
    if use_scev != sc_get_scev(iv_operand) return false;
    if inst_op(use_inst) == .PHI {
        if !s.dt || !dt_dominates_inst(s.dt, iv_operand, use_inst) return false;
    }
    if !li_replacement_preserves_lcssa_form(s.li, use_inst, iv_operand) return false;
    if !implies_poison(iv_operand, use_inst) {
        drops: [..] Value_Id; drops.allocator = temp;
        if !sc_can_reuse_instruction(use_scev, iv_operand, *drops) return false;
        for drops drop_poison_generating_annotations(it);
    }
    sc_forget_value(use_inst);
    rauw_with_metadata(use_inst, iv_operand);
    s.changed = true;
    dead_push(s.dead, use_inst);
    return true;
}

// strengthenOverflowingOperation
siv_strengthen_overflowing_operation :: (s: *Siv, bo: Value_Id) -> bool {
    has, f := sc_get_strengthened_no_wrap_flags_from_bin_op(bo);
    if !has return false;
    sx_set_nuw(bo, mask_flags(f, SF_NUW) == SF_NUW);
    sx_set_nsw(bo, mask_flags(f, SF_NSW) == SF_NSW);
    return true;
}
// strengthenRightShift
siv_strengthen_right_shift :: (s: *Siv, bo: Value_Id, iv_operand: Value_Id) -> bool {
    if inst_op(bo) != .SHL return false;
    changed := false;
    iv_range := sc_unsigned_range(sc_get_scev(iv_operand));
    for u: sx_users(bo) {
        if !is_inst(u) continue;
        uo := inst_op(u);
        if uo != .ASHR && uo != .LSHR continue;
        sh := op(u, 0);
        if !is_inst(sh) || inst_op(sh) != .SHL || op(sh, 1) != iv_operand continue;
        ok, c := pm_apint(op(u, 1));
        if !ok continue;
        if !(inst(u).flags & F_EXACT) && ap_uge(cr_umin(iv_range), c) {
            inst(u).flags |= F_EXACT;
            changed = true;
        }
    }
    return changed;
}
// strengthenBinaryOp
siv_strengthen_binary_op :: (s: *Siv, bo: Value_Id, iv_operand: Value_Id) -> bool {
    return (sx_is_obo(bo) && siv_strengthen_overflowing_operation(s, bo)) ||
           (inst_op(bo) == .SHL && siv_strengthen_right_shift(s, bo, iv_operand));
}

// pushIVUsers
siv_push_iv_users :: (s: *Siv, def: Value_Id, simplified: *Table(Value_Id, bool), users: *[..] Iv_Use_Pair) {
    for ui: sx_users(def) {
        if ui == def continue;
        if !li_contains_inst(s.li, s.l, ui) continue;
        if table_contains(simplified, ui) continue;
        table_set(simplified, ui, true);
        array_add(users, .{ui, def});
    }
}

// isSimpleIVUser
siv_is_simple_iv_user :: (i: Value_Id, l: Loop_Id) -> bool {
    if !sc_is_scevable(vtype(i)) return false;
    sv := sc_get_scev(i);
    return sc_is_addrec(sv) && sc_loop(sv) == l;
}

// visitIVCast (IndVarSimplifyVisitor::visitCast)
visit_iv_cast :: (c: Value_Id, wi: *Wide_IV_Info, tti: *Tti) {
    is_signed := inst_op(c) == .SEXT;
    if !is_signed && inst_op(c) != .ZEXT return;
    ty := vtype(c);
    width := sc_type_bits(ty);
    if !dl_is_legal_integer(width) return;
    narrow_width := sc_type_bits(vtype(wi.narrow_iv));
    if narrow_width >= width return;
    if tti && tti_arith_cost(tti, .ADD, ty, TCK_RECIP_THROUGHPUT) > tti_arith_cost(tti, .ADD, vtype(op(c, 0)), TCK_RECIP_THROUGHPUT) return;
    if wi.widest_native_type == NONE || width > sc_type_bits(wi.widest_native_type) {
        wi.widest_native_type = sc_effective_type(ty);
        wi.is_signed = is_signed;
        return;
    }
    wi.is_signed |= is_signed;
}

// SimplifyIndvar::simplifyUsers
siv_simplify_users :: (s: *Siv, curr_iv: Value_Id, v: *Wide_IV_Info) {
    if !sc_is_scevable(vtype(curr_iv)) return;
    simplified: Table(Value_Id, bool); simplified.allocator = temp;
    users: [..] Iv_Use_Pair; users.allocator = temp;
    siv_push_iv_users(s, curr_iv, *simplified, *users);
    while users.count {
        pair := pop(*users);
        use_inst := pair.use;
        if is_instruction_trivially_dead_tli(use_inst, false) { dead_push(s.dead, use_inst); continue; }
        if use_inst == curr_iv continue;
        if siv_replace_iv_user_with_loop_invariant(s, use_inst) continue;
        uo := inst_op(use_inst);
        if uo == .PTRTOINT || uo == .TRUNC {
            for user: sx_users(use_inst) if siv_replace_iv_user_with_loop_invariant(s, user) break;
        }
        iv_operand := pair.oper;
        while iv_operand != NONE {
            new_oper := siv_fold_iv_user(s, use_inst, iv_operand);
            if new_oper == NONE break;
            iv_operand = ifx is_inst(new_oper) then new_oper else NONE;
        }
        if iv_operand == NONE continue;
        if siv_eliminate_iv_user(s, use_inst, iv_operand) {
            siv_push_iv_users(s, iv_operand, *simplified, *users);
            continue;
        }
        if is_binary_op(inst_op(use_inst)) {
            if siv_strengthen_binary_op(s, use_inst, iv_operand) siv_push_iv_users(s, iv_operand, *simplified, *users);
        }
        if siv_replace_float_iv_with_integer_iv(s, use_inst) {
            siv_push_iv_users(s, iv_operand, *simplified, *users);
            continue;
        }
        if v && is_cast_op(inst_op(use_inst)) {
            visit_iv_cast(use_inst, v, s.tti);
            continue;
        }
        if siv_is_simple_iv_user(use_inst, s.l) siv_push_iv_users(s, use_inst, *simplified, *users);
    }
}

// isInstructionTriviallyDead(I, TLI) with or without a TLI
is_instruction_trivially_dead_tli :: (i: Value_Id, use_tli: bool) -> bool {
    if has_uses(i) return false;
    return would_instruction_be_trivially_dead(i, use_tli);
}

// simplifyUsersOfIV: (changed, run_unswitching)
simplify_users_of_iv :: (curr_iv: Value_Id, li: *Loop_Info, dt: *Dom_Tree, tti: *Tti, dead: *[..] Vh, rw: *Scev_Expander, v: *Wide_IV_Info) -> (bool, bool) {
    s: Siv;
    s.l = li_loop_for(li, inst_block(curr_iv));
    s.li = li; s.dt = dt; s.tti = tti; s.rw = rw; s.dead = dead;
    siv_simplify_users(*s, curr_iv, v);
    return s.changed, s.run_unswitching;
}

// simplifyLoopIVs
simplify_loop_ivs :: (l: Loop_Id, li: *Loop_Info, dt: *Dom_Tree, tti: *Tti, dead: *[..] Vh) -> bool {
    rw: Scev_Expander;
    sx_init(*rw, "indvars");
    changed := false;
    for pn: block_insts(li_header(li, l)) {
        if inst_op(pn) != .PHI break;
        c, _ := simplify_users_of_iv(pn, li, dt, tti, dead, *rw, null);
        changed |= c;
    }
    return changed;
}

// ================================================================ WidenIV

Extend_Kind :: enum u8 { ZERO; SIGN; UNKNOWN; }

Narrow_IV_Def_Use :: struct {
    narrow_def: Value_Id;
    narrow_use: Value_Id;
    wide_def: Value_Id;
    never_negative: bool;
}

Widen_IV :: struct {
    orig_phi: Value_Id;
    wide_type: Type_Id;
    li: *Loop_Info;
    l: Loop_Id;
    dt: *Dom_Tree;
    has_guards: bool;
    use_post_increment_ranges: bool;
    num_elim_ext: u32;
    num_widened: u32;
    wide_phi: Value_Id = NONE;
    wide_inc: Value_Id = NONE;
    wide_inc_expr: Scev_Id = SCEV_NULL;
    dead: *[..] Vh;
    widened: Table(Value_Id, bool);
    extend_kind_map: Table(Value_Id, Extend_Kind);
    post_inc_range_infos: Table(u64, Const_Range);
    narrow_iv_users: [..] Narrow_IV_Def_Use;
}

wiv_key :: (def: Value_Id, use: Value_Id) -> u64 { return ((cast(u64) def) << 32) | cast(u64) use; }

wiv_get_extend_kind :: (w: *Widen_IV, i: Value_Id) -> Extend_Kind {
    found, k := table_find(*w.extend_kind_map, i);
    assert(found, "Instruction not yet extended!");
    return k;
}

// updatePostIncRangeInfo
wiv_update_post_inc_range_info :: (w: *Widen_IV, def: Value_Id, use: Value_Id, r: Const_Range) {
    key := wiv_key(def, use);
    p := table_find_pointer(*w.post_inc_range_infos, key);
    if !p { table_set(*w.post_inc_range_infos, key, r); return; }
    p.* = cr_intersect(r, p.*);
}

// getInsertPointForUses
wiv_insert_point_for_uses :: (user: Value_Id, def: Value_Id, dt: *Dom_Tree, li: *Loop_Info) -> Value_Id {
    if inst_op(user) != .PHI return user;
    insert_pt: Value_Id = NONE;
    for i: 0..cast(s64) phi_num_incoming(user) - 1 {
        if phi_value(user, cast(u32) i) != def continue;
        ibb := phi_block(user, cast(u32) i);
        if !dt_is_reachable_from_entry(dt, ibb) continue;
        if insert_pt == NONE { insert_pt = block_terminator(ibb); continue; }
        ibb = dt_find_nca(dt, inst_block(insert_pt), ibb);
        insert_pt = block_terminator(ibb);
    }
    if insert_pt == NONE return NONE;
    if !is_inst(def) return insert_pt;
    l := li_loop_for(li, inst_block(def));
    n := dt_node(dt, inst_block(insert_pt));
    while n >= 0 {
        b := dt_block(dt, n);
        if li_loop_for(li, b) == l return block_terminator(b);
        n = dt_idom(dt, n);
    }
    fatal("DefI dominates InsertPt!");
    return NONE;
}

// createExtendInst
wiv_create_extend_inst :: (w: *Widen_IV, narrow_oper: Value_Id, wide_type: Type_Id, is_signed: bool, use: Value_Id) -> Value_Id {
    b: Irb;
    irb_set_before(*b, use);
    l := li_loop_for(w.li, inst_block(use));
    while l != NONE && li_loop_preheader(w.li, l) != NONE && li_is_loop_invariant(w.li, l, narrow_oper) {
        irb_set_before(*b, block_terminator(li_loop_preheader(w.li, l)));
        l = li_parent(w.li, l);
    }
    return irb_cast(*b, ifx is_signed then Opcode.SEXT else .ZEXT, narrow_oper, wide_type);
}

// BinaryOperator::Create(Opc, LHS, RHS, NarrowBO->getName()) then IRBuilder(NarrowUse).Insert(WideBO): the name is
// taken (uniqued) when the instruction is linked and cleared again by Insert's setName("")
wiv_insert_clone :: (narrow_bo: Value_Id, lhs: Value_Id, rhs: Value_Id) -> Value_Id {
    wide_bo := create_binop(inst_op(narrow_bo), lhs, rhs);
    b: Irb;
    irb_set_before(*b, narrow_bo);
    insert_at_position(wide_bo, b.bb, b.pt, b.head);
    if vname(narrow_bo).count { set_name(wide_bo, vname(narrow_bo)); set_name(wide_bo, ""); }
    d := b.dbg;
    if d == NONE d = get_metadata(wide_bo, 0);
    set_metadata(wide_bo, 0, d);
    copy_ir_flags(wide_bo, narrow_bo);
    return wide_bo;
}

// cloneIVUser
wiv_clone_iv_user :: (w: *Widen_IV, du: Narrow_IV_Def_Use, wide_ar: Scev_Id) -> Value_Id {
    o := inst_op(du.narrow_use);
    if o == .ADD || o == .MUL || o == .UDIV || o == .SUB return wiv_clone_arithmetic_iv_user(w, du, wide_ar);
    if o == .AND || o == .OR || o == .XOR || o == .SHL || o == .LSHR || o == .ASHR return wiv_clone_bitwise_iv_user(w, du);
    return NONE;
}

// cloneBitwiseIVUser
wiv_clone_bitwise_iv_user :: (w: *Widen_IV, du: Narrow_IV_Def_Use) -> Value_Id {
    nu := du.narrow_use; nd := du.narrow_def; wd := du.wide_def;
    is_signed := wiv_get_extend_kind(w, nd) == .SIGN;
    lhs := ifx op(nu, 0) == nd then wd else wiv_create_extend_inst(w, op(nu, 0), w.wide_type, is_signed, nu);
    rhs := ifx op(nu, 1) == nd then wd else wiv_create_extend_inst(w, op(nu, 1), w.wide_type, is_signed, nu);
    return wiv_insert_clone(nu, lhs, rhs);
}

// getSCEVByOpCode
wiv_scev_by_opcode :: (lhs: Scev_Id, rhs: Scev_Id, opc: Opcode) -> Scev_Id {
    if opc == {
        case .ADD; return sc_get_add2(lhs, rhs);
        case .SUB; return sc_get_minus(lhs, rhs);
        case .MUL; return sc_get_mul2(lhs, rhs);
        case .UDIV; return sc_get_udiv(lhs, rhs);
    }
    fatal("Unsupported opcode.");
    return SCEV_CNC;
}

// cloneArithmeticIVUser
wiv_clone_arithmetic_iv_user :: (w: *Widen_IV, du: Narrow_IV_Def_Use, wide_ar: Scev_Id) -> Value_Id {
    nu := du.narrow_use; nd := du.narrow_def; wd := du.wide_def;
    iv_op_idx: u32 = ifx op(nu, 0) == nd then cast(u32) 0 else 1;
    guess :: (w: *Widen_IV, du: Narrow_IV_Def_Use, iv_op_idx: u32, sign_ext: bool, wide_ar: Scev_Id) -> bool {
        ext :: (s: Scev_Id, t: Type_Id, sign_ext: bool) -> Scev_Id { if sign_ext return sc_get_sign_extend(s, t); return sc_get_zero_extend(s, t); }
        wide_lhs, wide_rhs: Scev_Id;
        if iv_op_idx == 0 {
            wide_lhs = sc_get_scev(du.wide_def);
            narrow_rhs := sc_get_scev(op(du.narrow_use, 1));
            wide_rhs = ext(narrow_rhs, w.wide_type, sign_ext);
        } else {
            narrow_lhs := sc_get_scev(op(du.narrow_use, 0));
            wide_lhs = ext(narrow_lhs, w.wide_type, sign_ext);
            wide_rhs = sc_get_scev(du.wide_def);
        }
        wide_use := wiv_scev_by_opcode(wide_lhs, wide_rhs, inst_op(du.narrow_use));
        return wide_use == wide_ar;
    }
    sign_extend := wiv_get_extend_kind(w, nd) == .SIGN;
    if !guess(w, du, iv_op_idx, sign_extend, wide_ar) {
        sign_extend = !sign_extend;
        if !guess(w, du, iv_op_idx, sign_extend, wide_ar) return NONE;
    }
    lhs := ifx op(nu, 0) == nd then wd else wiv_create_extend_inst(w, op(nu, 0), w.wide_type, sign_extend, nu);
    rhs := ifx op(nu, 1) == nd then wd else wiv_create_extend_inst(w, op(nu, 1), w.wide_type, sign_extend, nu);
    return wiv_insert_clone(nu, lhs, rhs);
}

// matchBinaryOp's BinaryOp
Wiv_Binary_Op :: struct { ok: bool; opc: Opcode; ops: [2] Value_Id; is_nsw: bool; is_nuw: bool; }

// matchBinaryOp
wiv_match_binary_op :: (i: Value_Id) -> Wiv_Binary_Op {
    r: Wiv_Binary_Op;
    o := inst_op(i);
    if o == .ADD || o == .SUB || o == .MUL {
        r.ok = true; r.opc = o; r.ops[0] = op(i, 0); r.ops[1] = op(i, 1);
        r.is_nsw = sx_has_nsw(i); r.is_nuw = sx_has_nuw(i);
        return r;
    }
    if o == .OR {
        if inst(i).flags & F_EXACT { r.ok = true; r.opc = .ADD; r.ops[0] = op(i, 0); r.ops[1] = op(i, 1); r.is_nsw = true; r.is_nuw = true; }
        return r;
    }
    if o == .SHL {
        sa := op(i, 1);
        if vkind(sa) == .C_INT {
            bw := type_int_width(vtype(sa));
            sv := const_ap(sa);
            if ap_ult_u64(sv, bw) {
                is_nuw := sx_has_nuw(i);
                is_nsw := sx_has_nsw(i) && (is_nuw || ap_ult_u64(sv, cast(u64) bw - 1));
                xc := const_int_ap(vtype(sa), ap_shl(ap_one(bw), cast(u32) ap_zext_value(sv)));
                r.ok = true; r.opc = .MUL; r.ops[0] = op(i, 0); r.ops[1] = xc; r.is_nsw = is_nsw; r.is_nuw = is_nuw;
            }
        }
    }
    return r;
}

// getExtendedOperandRecurrence
wiv_get_extended_operand_recurrence :: (w: *Widen_IV, du: Narrow_IV_Def_Use) -> (Scev_Id, Extend_Kind) {
    bop := wiv_match_binary_op(du.narrow_use);
    if !bop.ok return SCEV_NULL, .UNKNOWN;
    ext_idx := ifx bop.ops[0] == du.narrow_def then 1 else 0;
    ext_kind := wiv_get_extend_kind(w, du.narrow_def);
    if !(ext_kind == .SIGN && bop.is_nsw) && !(ext_kind == .ZERO && bop.is_nuw) {
        ext_kind = .UNKNOWN;
        if du.never_negative {
            if bop.is_nsw ext_kind = .SIGN;
            else if bop.is_nuw ext_kind = .ZERO;
        }
    }
    ext_expr := sc_get_scev(bop.ops[ext_idx]);
    if ext_kind == .SIGN ext_expr = sc_get_sign_extend(ext_expr, w.wide_type);
    else if ext_kind == .ZERO ext_expr = sc_get_zero_extend(ext_expr, w.wide_type);
    else return SCEV_NULL, .UNKNOWN;
    lhs := sc_get_scev(du.wide_def);
    rhs := ext_expr;
    if ext_idx == 0 lhs, rhs = rhs, lhs;
    ar := wiv_scev_by_opcode(lhs, rhs, bop.opc);
    if !sc_is_addrec(ar) || sc_loop(ar) != w.l return SCEV_NULL, .UNKNOWN;
    return ar, ext_kind;
}

// getWideRecurrence
wiv_get_wide_recurrence :: (w: *Widen_IV, du: Narrow_IV_Def_Use) -> (Scev_Id, Extend_Kind) {
    if type_kind(vtype(du.narrow_use)) != .INT return SCEV_NULL, .UNKNOWN;
    narrow_expr := sc_get_scev(du.narrow_use);
    if sc_type_bits(sc_type(narrow_expr)) >= sc_type_bits(w.wide_type) return SCEV_NULL, .UNKNOWN;
    wide_expr: Scev_Id;
    ext_kind: Extend_Kind;
    if du.never_negative {
        wide_expr = sc_get_sign_extend(narrow_expr, w.wide_type);
        if sc_is_addrec(wide_expr) ext_kind = .SIGN;
        else { wide_expr = sc_get_zero_extend(narrow_expr, w.wide_type); ext_kind = .ZERO; }
    } else if wiv_get_extend_kind(w, du.narrow_def) == .SIGN {
        wide_expr = sc_get_sign_extend(narrow_expr, w.wide_type); ext_kind = .SIGN;
    } else {
        wide_expr = sc_get_zero_extend(narrow_expr, w.wide_type); ext_kind = .ZERO;
    }
    if !sc_is_addrec(wide_expr) || sc_loop(wide_expr) != w.l return SCEV_NULL, .UNKNOWN;
    return wide_expr, ext_kind;
}

// IRBuilder<>::CreateTrunc(V, DestTy, Name, IsNUW, IsNSW) (ConstantFolder)
irb_trunc_flags :: (b: *Irb, v: Value_Id, ty: Type_Id, name: string, nuw: bool, nsw: bool) -> Value_Id {
    if vtype(v) == ty return v;
    if irb_is_const(v) { f := fold_maybe_undesirable_cast(.TRUNC, v, ty); if f != NONE return f; }
    i := new_inst(.TRUNC, ty, 1);
    set_op(i, 0, v);
    if nuw inst(i).flags |= F_NUW;
    if nsw inst(i).flags |= F_NSW;
    return irb_insert(b, i, name);
}

// truncateIVUse
wiv_truncate_iv_use :: (w: *Widen_IV, du: Narrow_IV_Def_Use) {
    ip := wiv_insert_point_for_uses(du.narrow_use, du.narrow_def, w.dt, w.li);
    if ip == NONE return;
    ext_kind := wiv_get_extend_kind(w, du.narrow_def);
    b: Irb;
    irb_set_before(*b, ip);
    trunc := irb_trunc_flags(*b, du.wide_def, vtype(du.narrow_def), "", du.never_negative || ext_kind == .ZERO, du.never_negative || ext_kind == .SIGN);
    replace_uses_of_with(du.narrow_use, du.narrow_def, trunc);
}

// widenLoopCompare
wiv_widen_loop_compare :: (w: *Widen_IV, du: Narrow_IV_Def_Use) -> bool {
    cmp := du.narrow_use;
    if inst_op(cmp) != .ICMP return false;
    is_signed := wiv_get_extend_kind(w, du.narrow_def) == .SIGN;
    has_ss := (inst(cmp).flags & F_EXACT) != 0;
    cmp_preferred_sign := ifx has_ss then is_signed else icmp_is_signed(inst_pred(cmp));
    if !du.never_negative && is_signed != cmp_preferred_sign return false;
    o := op(cmp, ifx op(cmp, 0) == du.narrow_def then cast(u32) 1 else 0);
    cast_width := sc_type_bits(vtype(o));
    iv_width := sc_type_bits(w.wide_type);
    replace_uses_of_with(du.narrow_use, du.narrow_def, du.wide_def);
    if cast_width < iv_width {
        if du.never_negative && is_inst(o) && inst_op(o) == .SEXT && !icmp_is_signed(inst_pred(cmp)) cmp_preferred_sign = true;
        ext_op := wiv_create_extend_inst(w, o, w.wide_type, cmp_preferred_sign, cmp);
        replace_uses_of_with(du.narrow_use, o, ext_op);
    }
    return true;
}

// widenWithVariantUse
wiv_widen_with_variant_use :: (w: *Widen_IV, du: Narrow_IV_Def_Use) -> bool {
    nu := du.narrow_use; nd := du.narrow_def; wd := du.wide_def;
    opc := inst_op(nu);
    if opc != .ADD && opc != .SUB && opc != .MUL return false;
    ext_kind := wiv_get_extend_kind(w, nd);
    can_sign_extend := ext_kind == .SIGN && sx_has_nsw(nu);
    can_zero_extend := ext_kind == .ZERO && sx_has_nuw(nu);
    another_op_ext_kind := ext_kind;
    ext_users: [..] Value_Id; ext_users.allocator = temp;
    lcssa_phi_users: [..] Value_Id; lcssa_phi_users.allocator = temp;
    icmp_users: [..] Value_Id; icmp_users.allocator = temp;
    for user_in: sx_users(nu) {
        user := user_in;
        if user == nd continue;
        if !li_contains_inst(w.li, w.l, user) {
            if inst_op(user) != .PHI fatal("indvars: a use outside the loop that is not an LCSSA phi");
            if nops(user) != 1 return false;
            array_add(*lcssa_phi_users, user);
            continue;
        }
        if inst_op(user) == .ICMP {
            p := inst_pred(user);
            if ext_kind == .ZERO && icmp_is_signed(p) return false;
            if ext_kind == .SIGN && icmp_is_unsigned(p) return false;
            array_add(*icmp_users, user);
            continue;
        }
        want: Opcode = ifx ext_kind == .SIGN then Opcode.SEXT else .ZEXT;
        if inst_op(user) != want || vtype(user) != w.wide_type return false;
        array_add(*ext_users, user);
    }
    if ext_users.count == 0 {
        dead_push(w.dead, nu);
        return true;
    }
    cxt := siv_find_common_dominator(ext_users, w.dt);
    if !can_sign_extend && !can_zero_extend {
        if opc != .ADD return false;
        if ext_kind != .ZERO return false;
        lhs := sc_get_scev(op(nu, 0));
        rhs := sc_get_scev(op(nu, 1));
        if op(nu, 0) != nd return false;
        if op(nu, 1) == nd return false;
        if !sc_is_known_negative(rhs) return false;
        if !sc_is_known_predicate_at(ICMP_UGE, lhs, sc_get_negative(rhs), cxt) return false;
        another_op_ext_kind = .SIGN;
    }
    op1 := sc_get_scev(wd);
    if !sc_is_addrec(op1) || sc_loop(op1) != w.l return false;
    lhs_v := ifx op(nu, 0) == nd then wd else wiv_create_extend_inst(w, op(nu, 0), w.wide_type, another_op_ext_kind == .SIGN, nu);
    rhs_v := ifx op(nu, 1) == nd then wd else wiv_create_extend_inst(w, op(nu, 1), w.wide_type, another_op_ext_kind == .SIGN, nu);
    wide_bo := wiv_insert_clone(nu, lhs_v, rhs_v);
    table_set(*w.extend_kind_map, nu, ext_kind);
    for user: ext_users {
        w.num_elim_ext += 1;
        rauw_with_metadata(user, wide_bo);
        dead_push(w.dead, user);
    }
    b: Irb;
    irb_set_before(*b, nu);
    for user: lcssa_phi_users {
        irb_set_before(*b, user);
        wide_pn := irb_phi(*b, vtype(wide_bo), 1, tprint("%.wide", vname(user)));
        exiting := block_single_predecessor(inst_block(user));
        phi_add_incoming(wide_pn, wide_bo, exiting);
        fip := block_first_insertion_pt(inst_block(user));
        irb_set_at(*b, inst_block(user), fip, true);
        trunc_pn := irb_cast(*b, .TRUNC, wide_pn, vtype(user));
        rauw_with_metadata(user, trunc_pn);
        dead_push(w.dead, user);
    }
    for user: icmp_users {
        irb_set_before(*b, user);
        extended :: (b: *Irb, v: Value_Id, nu: Value_Id, wide_bo: Value_Id, ext_kind: Extend_Kind) -> Value_Id {
            if v == nu return wide_bo;
            if ext_kind == .ZERO return irb_cast(b, .ZEXT, v, vtype(wide_bo));
            return irb_cast(b, .SEXT, v, vtype(wide_bo));
        }
        p := inst_pred(user);
        l2 := extended(*b, op(user, 0), nu, wide_bo, ext_kind);
        r2 := extended(*b, op(user, 1), nu, wide_bo, ext_kind);
        wide_cmp := irb_icmp(*b, p, l2, r2, tprint("%.wide", vname(user)));
        rauw_with_metadata(user, wide_cmp);
        dead_push(w.dead, user);
    }
    return true;
}

// widenIVUse
wiv_widen_iv_use :: (w: *Widen_IV, du: Narrow_IV_Def_Use, rw: *Scev_Expander, orig_phi: Value_Id, wide_phi: Value_Id) -> Value_Id {
    can_widen_by_sext := du.never_negative || wiv_get_extend_kind(w, du.narrow_def) == .SIGN;
    can_widen_by_zext := du.never_negative || wiv_get_extend_kind(w, du.narrow_def) == .ZERO;
    nu := du.narrow_use;
    if inst_op(nu) == .PHI {
        if li_loop_for(w.li, inst_block(nu)) != w.l {
            if nops(nu) != 1 wiv_truncate_iv_use(w, du);
            else {
                if inst_op(block_terminator(inst_block(nu))) == .CATCHSWITCH return NONE;
                wp := create_phi(vtype(du.wide_def), 1);
                siv_insert_before(wp, nu, tprint("%.wide", vname(nu)));
                phi_add_incoming(wp, du.wide_def, phi_block(nu, 0));
                bb := inst_block(wp);
                b: Irb;
                irb_set_at(*b, bb, block_first_insertion_pt(bb), true);
                trunc := irb_trunc_flags(*b, wp, vtype(du.narrow_def), "", can_widen_by_zext, can_widen_by_sext);
                rauw_with_metadata(nu, trunc);
                dead_push(w.dead, nu);
            }
            return NONE;
        }
    }
    is_sext_like, _ := pm_sext_like(nu);
    if (is_sext_like && can_widen_by_sext) || (inst_op(nu) == .ZEXT && can_widen_by_zext) {
        new_def := du.wide_def;
        if vtype(nu) != w.wide_type {
            cast_width := sc_type_bits(vtype(nu));
            iv_width := sc_type_bits(w.wide_type);
            if cast_width < iv_width {
                b: Irb;
                irb_set_before(*b, nu);
                new_def = irb_trunc_flags(*b, du.wide_def, vtype(nu), "", can_widen_by_zext, can_widen_by_sext);
            } else {
                replace_uses_of_with(nu, du.narrow_def, du.wide_def);
                new_def = nu;
            }
        }
        if new_def != nu {
            w.num_elim_ext += 1;
            rauw_with_metadata(nu, new_def);
            dead_push(w.dead, nu);
        }
        return NONE;
    }
    // tryAddRecExpansion
    {
        wide_ar, wide_kind := wiv_get_extended_operand_recurrence(w, du);
        if wide_ar == SCEV_NULL { wide_ar, wide_kind = wiv_get_wide_recurrence(w, du); }
        if wide_ar != SCEV_NULL {
            can_use_wide_inc :: (w: *Widen_IV, du: Narrow_IV_Def_Use, rw: *Scev_Expander, orig_phi: Value_Id, wide_phi: Value_Id, wide_ar: Scev_Id) -> bool {
                if w.wide_inc == NONE return false;
                need_recompute := !sx_can_reuse_flags_from_original_iv_inc(orig_phi, wide_phi, du.narrow_use, w.wide_inc) ||
                    sx_has_nuw(du.narrow_use) != sx_has_nuw(w.wide_inc) || sx_has_nsw(du.narrow_use) != sx_has_nsw(w.wide_inc);
                return wide_ar == w.wide_inc_expr && sx_hoist_iv_inc(rw, w.wide_inc, du.narrow_use, need_recompute);
            }
            wide_use: Value_Id = NONE;
            done := false;
            if can_use_wide_inc(w, du, rw, orig_phi, wide_phi, wide_ar) wide_use = w.wide_inc;
            else {
                wide_use = wiv_clone_iv_user(w, du, wide_ar);
                if wide_use == NONE done = true;
            }
            if !done {
                if wide_ar != sc_get_scev(wide_use) {
                    dead_push(w.dead, wide_use);
                } else {
                    replace_all_dbg_uses_with(nu, wide_use, wide_use, w.dt);
                    table_set(*w.extend_kind_map, nu, wide_kind);
                    return wide_use;
                }
            }
        }
    }
    if wiv_widen_loop_compare(w, du) return NONE;
    if wiv_widen_with_variant_use(w, du) return NONE;
    wiv_truncate_iv_use(w, du);
    return NONE;
}

// pushNarrowIVUsers
wiv_push_narrow_iv_users :: (w: *Widen_IV, narrow_def: Value_Id, wide_def: Value_Id) {
    narrow_scev := sc_get_scev(narrow_def);
    non_negative_def := sc_is_known_predicate(ICMP_SGE, narrow_scev, sc_get_zero(sc_type(narrow_scev)));
    for nuser: sx_users(narrow_def) {
        if table_contains(*w.widened, nuser) continue;
        table_set(*w.widened, nuser, true);
        non_negative_use := false;
        if !non_negative_def {
            found, r := table_find(*w.post_inc_range_infos, wiv_key(narrow_def, nuser));
            if found non_negative_use = ap_is_non_negative(cr_smin(r));
        }
        array_add(*w.narrow_iv_users, .{narrow_def, nuser, wide_def, non_negative_def || non_negative_use});
    }
}

// createWideIV (WidenIV::createWideIV)
wiv_create_wide_iv :: (w: *Widen_IV, rw: *Scev_Expander) -> Value_Id {
    add_rec := sc_get_scev(w.orig_phi);
    if !sc_is_addrec(add_rec) return NONE;
    wide_iv_expr := ifx wiv_get_extend_kind(w, w.orig_phi) == .SIGN then sc_get_sign_extend(add_rec, w.wide_type) else sc_get_zero_extend(add_rec, w.wide_type);
    add_rec = wide_iv_expr;
    if !sc_is_addrec(add_rec) || sc_loop(add_rec) != w.l return NONE;
    if w.use_post_increment_ranges wiv_calculate_post_inc_ranges(w, w.orig_phi);
    insert_pt := block_first_insertion_pt(li_header(w.li, w.l));
    expand_inst := sx_expand_code_for_at(rw, add_rec, w.wide_type, insert_pt);
    if !is_phi(expand_inst) {
        if is_inst(expand_inst) && !has_uses(expand_inst) && sx_is_inserted_instruction(rw, expand_inst) dead_push(w.dead, expand_inst);
        return NONE;
    }
    w.wide_phi = expand_inst;
    latch := li_loop_latch(w.li, w.l);
    if latch != NONE {
        wi := phi_incoming_value_for_block(w.wide_phi, latch);
        if is_inst(wi) {
            w.wide_inc = wi;
            w.wide_inc_expr = sc_get_scev(wi);
            orig_inc := phi_incoming_value_for_block(w.orig_phi, latch);
            copy_debug_loc(wi, orig_inc);
            if sx_can_reuse_flags_from_original_iv_inc(w.orig_phi, w.wide_phi, orig_inc, wi) && sx_is_obo(orig_inc) && sx_is_obo(wi) {
                sx_set_nuw(wi, sx_has_nuw(wi) || sx_has_nuw(orig_inc));
                sx_set_nsw(wi, sx_has_nsw(wi) || sx_has_nsw(orig_inc));
            }
        }
    }
    w.num_widened += 1;
    table_set(*w.widened, w.orig_phi, true);
    wiv_push_narrow_iv_users(w, w.orig_phi, w.wide_phi);
    while w.narrow_iv_users.count {
        du := pop(*w.narrow_iv_users);
        wide_use := wiv_widen_iv_use(w, du, rw, w.orig_phi, w.wide_phi);
        if wide_use != NONE wiv_push_narrow_iv_users(w, du.narrow_use, wide_use);
        if !has_uses(du.narrow_def) dead_push(w.dead, du.narrow_def);
    }
    replace_all_dbg_uses_with(w.orig_phi, w.wide_phi, w.wide_phi, w.dt);
    return w.wide_phi;
}

// calculatePostIncRange
wiv_calculate_post_inc_range :: (w: *Widen_IV, narrow_def: Value_Id, narrow_user: Value_Id) {
    if inst_op(narrow_def) != .ADD || !sx_has_nsw(narrow_def) return;
    ok, rhs_c := pm_apint(op(narrow_def, 1));
    if !ok || !ap_is_non_negative(rhs_c) return;
    def_lhs := op(narrow_def, 0);
    update_from_condition :: (w: *Widen_IV, cond: Value_Id, true_dest: bool, def_lhs: Value_Id, rhs_c: APInt, narrow_def: Value_Id, narrow_user: Value_Id) {
        if !is_inst(cond) || inst_op(cond) != .ICMP || op(cond, 0) != def_lhs return;
        pred := inst_pred(cond);
        cmp_rhs := op(cond, 1);
        p := ifx true_dest then pred else icmp_inverse(pred);
        cmp_rhs_range := sc_signed_range(sc_get_scev(cmp_rhs));
        constrained := cr_allowed_icmp_region(p, cmp_rhs_range);
        r := cr_add_with_no_wrap(constrained, cr_single(rhs_c), NW_NSW);
        wiv_update_post_inc_range_info(w, narrow_def, narrow_user, r);
    }
    update_from_guards :: (w: *Widen_IV, ctx: Value_Id, def_lhs: Value_Id, rhs_c: APInt, narrow_def: Value_Id, narrow_user: Value_Id) {
        if !w.has_guards return;
        i := ctx;
        while i != NONE {
            if call_iid(i) == IID_EXPERIMENTAL_GUARD update_from_condition(w, call_arg(i, 0), true, def_lhs, rhs_c, narrow_def, narrow_user);
            i = inst_prev(i);
        }
    }
    update_from_guards(w, narrow_user, def_lhs, rhs_c, narrow_def, narrow_user);
    ubb := inst_block(narrow_user);
    if !dt_is_reachable_from_entry(w.dt, ubb) return;
    n := dt_idom(w.dt, dt_node(w.dt, ubb));
    while n >= 0 && li_contains(w.li, w.l, dt_block(w.dt, n)) {
        bb := dt_block(w.dt, n);
        ti := block_terminator(bb);
        update_from_guards(w, ti, def_lhs, rhs_c, narrow_def, narrow_user);
        if inst_op(ti) == .CONDBR {
            ts := get_successor(ti, 0);
            fs := get_successor(ti, 1);
            if dt_dominates_edge_block(w.dt, bb, ts, ubb) update_from_condition(w, op(ti, 0), true, def_lhs, rhs_c, narrow_def, narrow_user);
            if dt_dominates_edge_block(w.dt, bb, fs, ubb) update_from_condition(w, op(ti, 0), false, def_lhs, rhs_c, narrow_def, narrow_user);
        }
        n = dt_idom(w.dt, n);
    }
}

// calculatePostIncRanges
wiv_calculate_post_inc_ranges :: (w: *Widen_IV, orig_phi: Value_Id) {
    visited: Table(Value_Id, bool); visited.allocator = temp;
    work: [..] Value_Id; work.allocator = temp;
    array_add(*work, orig_phi);
    table_set(*visited, orig_phi, true);
    while work.count {
        nd := pop(*work);
        for nu: sx_users(nd) {
            nul := li_loop_for(w.li, inst_block(nu));
            if nul == NONE || !li_contains_loop(w.li, w.l, nul) continue;
            if table_contains(*visited, nu) continue;
            table_set(*visited, nu, true);
            array_add(*work, nu);
            wiv_calculate_post_inc_range(w, nd, nu);
        }
    }
}

// llvm::createWideIV: (wide phi, NumElimExt, NumWidened)
create_wide_iv :: (wi: Wide_IV_Info, li: *Loop_Info, rw: *Scev_Expander, dt: *Dom_Tree, dead: *[..] Vh, has_guards: bool, use_post_increment_ranges: bool) -> Value_Id, u32, u32 {
    w: Widen_IV;
    w.orig_phi = wi.narrow_iv;
    w.wide_type = wi.widest_native_type;
    w.li = li;
    w.l = li_loop_for(li, inst_block(w.orig_phi));
    w.dt = dt;
    w.has_guards = has_guards;
    w.use_post_increment_ranges = use_post_increment_ranges;
    w.dead = dead;
    w.widened.allocator = temp; w.extend_kind_map.allocator = temp; w.post_inc_range_infos.allocator = temp;
    w.narrow_iv_users.allocator = temp;
    table_set(*w.extend_kind_map, w.orig_phi, ifx wi.is_signed then Extend_Kind.SIGN else .ZERO);
    r := wiv_create_wide_iv(*w, rw);
    return r, w.num_elim_ext, w.num_widened;
}

// new X(..., Name, InsertBefore->getIterator()): Instruction::insertBefore adopts the debug records of the position
// (the iterator has no head bit), then the constructor names the instruction
siv_insert_before :: (i: Value_Id, pos: Value_Id, name: string) -> Value_Id {
    insert_at_position(i, inst_block(pos), pos, false);
    if name.count set_name(i, name);
    return i;
}
