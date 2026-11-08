// CorrelatedValuePropagation: a port of llvm/lib/Transforms/Scalar/CorrelatedValuePropagation.cpp (complete).
// The analysis is LazyValueInfo (lazy_value_info.jai).

// getConstantAt
cvp_get_constant_at :: (v: Value_Id, at: Value_Id, lvi: *Lvi) -> Value_Id {
    c := lvi_get_constant(lvi, v, at);
    if c != NONE return c;
    if !is_inst(v) || (inst_op(v) != .ICMP && inst_op(v) != .FCMP) return NONE;
    op0 := op(v, 0);
    op1 := op(v, 1);
    if !is_constant_kind(vkind(op1)) return NONE;
    return lvi_get_predicate_at(lvi, inst_pred(v), op0, op1, at, false);
}

cvp_is_const_int_true :: (c: Value_Id) -> bool { return c != NONE && vkind(c) == .C_INT && !ap_is_zero(const_ap(c)); }

// processSelect
cvp_process_select :: (s: Value_Id, lvi: *Lvi) -> bool {
    if is_vector_type(vtype(s)) || is_constant_kind(vkind(op(s, 0))) return false;
    changed := false;
    u := ir.v_first_use[s];
    while u != NONE {
        nu := ir.u_next[u];
        i := ir.u_user[u];
        c: Value_Id;
        if inst_op(i) == .PHI c = lvi_get_constant_on_edge(lvi, op(s, 0), ir.u_aux[u], inst_block(i), i);
        else c = cvp_get_constant_at(op(s, 0), i, lvi);
        if c != NONE && vkind(c) == .C_INT {
            use_set(u, ifx ap_is_one(const_ap(c)) then op(s, 1) else op(s, 2));
            changed = true;
        }
        u = nu;
    }
    if changed && !has_uses(s) erase_inst_with_metadata(s);
    return changed;
}

// simplifyCommonValuePhi
cvp_simplify_common_value_phi :: (p: Value_Id, lvi: *Lvi, dt: *Dom_Tree) -> bool {
    incoming_constants: [..] [2] Value_Id; incoming_constants.allocator = temp;   // (constant, index)
    common: Value_Id = NONE;
    n := phi_num_incoming(p);
    for k: 0..cast(s64) n - 1 {
        inc := phi_value(p, cast(u32) k);
        if is_constant_kind(vkind(inc)) array_add(*incoming_constants, .[inc, cast(Value_Id) k]);
        else if common == NONE common = inc;
        else if inc != common return false;
    }
    if common == NONE || incoming_constants.count == 0 return false;
    to_bb := inst_block(p);
    if is_inst(common) && !dt_dominates_inst_block(dt, common, to_bb) return false;
    for incoming_constants {
        c := it[0];
        incoming_bb := phi_block(p, it[1]);
        if c != lvi_get_constant_on_edge(lvi, common, incoming_bb, to_bb, p) return false;
    }
    if !is_guaranteed_not_to_be_poison(common, null, p, dt) return false;
    rauw_with_metadata(p, common);
    erase_inst_with_metadata(p);
    return true;
}

// getValueOnEdge
cvp_get_value_on_edge :: (lvi: *Lvi, incoming: Value_Id, from: Value_Id, to: Value_Id, cxt: Value_Id) -> Value_Id {
    c := lvi_get_constant_on_edge(lvi, incoming, from, to, cxt);
    if c != NONE return c;
    if !is_inst(incoming) || inst_op(incoming) != .SELECT return NONE;
    si := incoming;
    condition := op(si, 0);
    if !is_vector_type(vtype(condition)) {
        cc := lvi_get_constant_on_edge(lvi, condition, from, to, cxt);
        if cc != NONE {
            if is_one_value(cc) return op(si, 1);
            if is_null_value(cc) return op(si, 2);
        }
    }
    fv := op(si, 2);
    if is_constant_kind(vkind(fv)) {
        res := lvi_get_predicate_on_edge(lvi, ICMP_EQ, si, fv, from, to, cxt);
        if res != NONE && vkind(res) == .C_INT && ap_is_zero(const_ap(res)) return op(si, 1);
    }
    tv := op(si, 1);
    if is_constant_kind(vkind(tv)) {
        res := lvi_get_predicate_on_edge(lvi, ICMP_EQ, si, tv, from, to, cxt);
        if res != NONE && vkind(res) == .C_INT && ap_is_zero(const_ap(res)) return op(si, 2);
    }
    return NONE;
}

// processPHI
cvp_process_phi :: (p: Value_Id, lvi: *Lvi, dt: *Dom_Tree, sq: Simplify_Query) -> bool {
    changed := false;
    bb := inst_block(p);
    n := phi_num_incoming(p);
    for k: 0..cast(s64) n - 1 {
        inc := phi_value(p, cast(u32) k);
        if is_constant_kind(vkind(inc)) continue;
        v := cvp_get_value_on_edge(lvi, inc, phi_block(p, cast(u32) k), bb, p);
        if v != NONE {
            phi_set_value(p, cast(u32) k, v);
            changed = true;
        }
    }
    v := simplify_instruction(p, sq);
    if v != NONE {
        rauw_with_metadata(p, v);
        erase_inst_with_metadata(p);
        changed = true;
    }
    if !changed changed = cvp_simplify_common_value_phi(p, lvi, dt);
    return changed;
}

// processICmp
cvp_process_icmp :: (cmp: Value_Id, lvi: *Lvi) -> bool {
    if !is_int_type(scalar_type(vtype(op(cmp, 0)))) return false;
    pred := inst_pred(cmp);
    samesign := (opr_flags(cmp) & F_EXACT) != 0;
    if !icmp_is_signed(pred) && (!icmp_is_unsigned(pred) || samesign) return false;
    changed := false;
    cr1 := lvi_get_constant_range_at_use(lvi, op_use(cmp, 0), false);
    cr2 := lvi_get_constant_range_at_use(lvi, op_use(cmp, 1), false);
    if icmp_is_signed(pred) {
        up := cr_equivalent_pred_flipped_signedness(pred, cr1, cr2);
        if up == BAD_ICMP_PREDICATE return false;
        inst(cmp).pred = up;
        changed = true;
    }
    if cr_insensitive_to_signedness(cr1, cr2) {
        inst(cmp).flags |= F_EXACT;
        changed = true;
    }
    return changed;
}

// constantFoldCmp
cvp_constant_fold_cmp :: (cmp: Value_Id, lvi: *Lvi) -> bool {
    res := lvi_get_predicate_at(lvi, inst_pred(cmp), op(cmp, 0), op(cmp, 1), cmp, true);
    if res == NONE return false;
    // replaceUsesWithIf(Res, [](Use &U) { return !isa<AssumeInst>(U.getUser()); })
    changed := false;
    u := ir.v_first_use[cmp];
    while u != NONE {
        nu := ir.u_next[u];
        usr := ir.u_user[u];
        if !is_intrinsic_call(usr, IID_ASSUME) {
            if !is_inst(usr) fatal("correlated-propagation: replaceUsesWithIf with a non-instruction user is not supported yet");
            use_set(u, res);
            changed = true;
        }
        u = nu;
    }
    if !has_uses(cmp) {
        erase_inst_with_metadata(cmp);
        changed = true;
    }
    return changed;
}

cvp_process_cmp :: (cmp: Value_Id, lvi: *Lvi) -> bool {
    if cvp_constant_fold_cmp(cmp, lvi) return true;
    if inst_op(cmp) == .ICMP && cvp_process_icmp(cmp, lvi) return true;
    return false;
}

// processSwitch
cvp_process_switch :: (sw: Value_Id, lvi: *Lvi, dt: *Dom_Tree) -> bool {
    dtu: Dtu; dtu.dt = dt; dtu.lazy = true;
    dtu.pending.allocator = temp; dtu.deleted.allocator = temp;
    cond := sw_cond(sw);
    bb := inst_block(sw);
    changed := false;
    succ_count: Table(Value_Id, s64); succ_count.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb, *succs);
    for succs { p := table_find_pointer(*succ_count, it); if p p.* += 1; else table_set(*succ_count, it, 1); }
    {
        prof: Sw_Prof;
        sw_prof_init(*prof, sw);
        cr := lvi_get_constant_range_at_use(lvi, op_use(sw, 0), false);
        reachable_case_count: u64 = 0;
        k: u32 = 0;
        while k < sw_num_cases(sw) {
            case_v := sw_case_value(sw, k);
            ca := const_ap(case_v);
            has_pred := false; pred_v := false;
            if !cr_contains(cr, ca) { has_pred = true; pred_v = false; }
            else {
                oks, se := cr_single_element(cr);
                if oks && ap_eq(se, ca) { has_pred = true; pred_v = true; }
            }
            if !has_pred {
                res := lvi_get_predicate_at(lvi, ICMP_EQ, cond, case_v, sw, true);
                if res != NONE && vkind(res) == .C_INT {
                    if ap_is_zero(const_ap(res)) { has_pred = true; pred_v = false; }
                    else if ap_is_one(const_ap(res)) { has_pred = true; pred_v = true; }
                }
            }
            if has_pred && !pred_v {
                succ := sw_case_dest(sw, k);
                block_remove_predecessor(succ, bb);
                sw_prof_remove_case(*prof, k);
                cond = sw_cond(sw);
                changed = true;
                p := table_find_pointer(*succ_count, succ);
                p.* -= 1;
                if p.* == 0 dtu_apply_permissive(*dtu, .[.{false, bb, succ}]);
                continue;
            }
            if has_pred && pred_v {
                set_op(sw, 0, case_v);
                changed = true;
                break;
            }
            k += 1;
            reachable_case_count += 1;
        }
        if !sw_default_dest_unreachable(sw) && !cr_is_size_larger_than(cr, reachable_case_count) {
            default_dest := sw_default(sw);
            new_unreachable := create_block(block_fn(bb), "default.unreachable", default_dest);
            ui := new_inst(.UNREACHABLE, ir.t_void, 0);
            block_append_inst(new_unreachable, ui);
            block_remove_predecessor(default_dest, bb);
            sw_set_default(sw, new_unreachable);
            p := table_find_pointer(*succ_count, default_dest);
            if p && p.* == 1 dtu_apply(*dtu, .[.{false, bb, default_dest}]);
            dtu_apply(*dtu, .[.{true, bb, new_unreachable}]);
            changed = true;
        }
        sw_prof_done(*prof);
    }
    if changed constant_fold_terminator(bb, false, *dtu);
    dtu_flush(*dtu);
    return changed;
}

// willNotOverflow (BinaryOpIntrinsic: with.overflow and saturating intrinsics)
cvp_will_not_overflow :: (bo: Value_Id, lvi: *Lvi, opc: Opcode, signed: bool) -> bool {
    lr := lvi_get_constant_range_at_use(lvi, op_use(bo, 0), false);
    rr := lvi_get_constant_range_at_use(lvi, op_use(bo, 1), false);
    nw := cr_guaranteed_no_wrap_region(opc, rr, !signed);
    return cr_contains_range(nw, lr);
}

// setDeducedOverflowingFlags (the statistics are not kept)
cvp_set_deduced_overflowing_flags :: (v: Value_Id, new_nsw: bool, new_nuw: bool) {
    if !is_inst(v) return;
    if new_nsw inst(v).flags |= F_NSW;
    if new_nuw inst(v).flags |= F_NUW;
}

// processAbsIntrinsic
cvp_process_abs_intrinsic :: (ii: Value_Id, lvi: *Lvi) -> bool {
    x := call_arg(ii, 0);
    is_int_min_poison := ap_is_one(const_ap(call_arg(ii, 1)));
    int_min := ap_signed_min(type_bits(scalar_type(vtype(x))));
    range := lvi_get_constant_range_at_use(lvi, op_use(ii, 0), is_int_min_poison);
    if cr_icmp(range, ICMP_ULE, cr_single(int_min)) {
        rauw_with_metadata(ii, x);
        erase_inst_with_metadata(ii);
        return true;
    }
    if ap_is_non_positive(cr_smax(range)) {
        b: Irb; irb_set_before(*b, ii);
        neg := irb_binop(*b, .SUB, const_null_value(vtype(x)), x, name_ref(vname(ii)), ifx is_int_min_poison then cast(u32) F_NSW else 0);
        rauw_with_metadata(ii, neg);
        erase_inst_with_metadata(ii);
        if is_binary_operator(neg) cvp_process_bin_op(neg, lvi);
        return true;
    }
    if !is_int_min_poison && !cr_contains(range, int_min) {
        set_op(ii, 1, const_int(ir.t_i1, 1));
        return true;
    }
    return false;
}

// processCmpIntrinsic (llvm.scmp / llvm.ucmp)
cvp_process_cmp_intrinsic :: (ci: Value_Id, lvi: *Lvi) -> bool {
    lhs_cr := lvi_get_constant_range_at_use(lvi, op_use(ci, 0), false);
    rhs_cr := lvi_get_constant_range_at_use(lvi, op_use(ci, 1), false);
    signed := call_iid(ci) == IID_SCMP;
    gt := ifx signed then cast(u8) ICMP_SGT else ICMP_UGT;
    lt := ifx signed then cast(u8) ICMP_SLT else ICMP_ULT;
    t := vtype(ci);
    if cr_icmp(lhs_cr, gt, rhs_cr) { rauw_with_metadata(ci, const_int(t, 1)); erase_inst_with_metadata(ci); return true; }
    if cr_icmp(lhs_cr, lt, rhs_cr) { rauw_with_metadata(ci, const_int(t, 0xFFFF_FFFF_FFFF_FFFF)); erase_inst_with_metadata(ci); return true; }
    if cr_icmp(lhs_cr, ICMP_EQ, rhs_cr) { rauw_with_metadata(ci, const_int(t, 0)); erase_inst_with_metadata(ci); return true; }
    return false;
}

// MinMaxIntrinsic::getPredicate
cvp_min_max_predicate :: (id: Intrinsic_Id) -> u8 {
    if id == IID_SMAX return ICMP_SGT;
    if id == IID_SMIN return ICMP_SLT;
    if id == IID_UMAX return ICMP_UGT;
    return ICMP_ULT;
}

// processMinMaxIntrinsic
cvp_process_min_max_intrinsic :: (mm: Value_Id, lvi: *Lvi) -> bool {
    id := call_iid(mm);
    pred := cmp_non_strict(cvp_min_max_predicate(id));
    lhs_cr := lvi_get_constant_range_at_use(lvi, op_use(mm, 0), false);
    rhs_cr := lvi_get_constant_range_at_use(lvi, op_use(mm, 1), false);
    if cr_icmp(lhs_cr, pred, rhs_cr) {
        rauw_with_metadata(mm, call_arg(mm, 0));
        erase_inst_with_metadata(mm);
        return true;
    }
    if cr_icmp(rhs_cr, pred, lhs_cr) {
        rauw_with_metadata(mm, call_arg(mm, 1));
        erase_inst_with_metadata(mm);
        return true;
    }
    if (id == IID_SMIN || id == IID_SMAX) && cr_insensitive_to_signedness(lhs_cr, rhs_cr) {
        b: Irb; irb_set_before(*b, mm);
        nid := ifx id == IID_SMIN then IID_UMIN else IID_UMAX;
        l := call_arg(mm, 0); r := call_arg(mm, 1);
        f := get_or_insert_intrinsic_declaration(nid, .[vtype(l)]);
        nc := irb_call(*b, f, .[l, r]);
        rauw_with_metadata(mm, nc);
        erase_inst_with_metadata(mm);
        return true;
    }
    return false;
}

// processOverflowIntrinsic
cvp_process_overflow_intrinsic :: (wo: Value_Id, lvi: *Lvi) -> bool {
    b: Irb; irb_set_before(*b, wo);
    id := call_iid(wo);
    opc := wo_binary_op(id);
    nsw := wo_is_signed(id);
    nuw := !nsw;
    new_op := irb_binop(*b, opc, call_arg(wo, 0), call_arg(wo, 1), name_ref(vname(wo)));
    cvp_set_deduced_overflowing_flags(new_op, nsw, nuw);
    st := vtype(wo);
    elts := Value_Id.[const_poison(type_sub(st, 0)), const_int(type_sub(st, 1), 0)];
    strct := const_aggregate(.C_STRUCT, st, elts);
    new_i := irb_insert_value(*b, strct, new_op, .[0]);
    rauw_with_metadata(wo, new_i);
    erase_inst_with_metadata(wo);
    if is_binary_operator(new_op) cvp_process_bin_op(new_op, lvi);
    return true;
}

// SaturatingInst::getBinaryOp / isSigned
cvp_sat_binary_op :: (id: Intrinsic_Id) -> Opcode { if id == IID_UADD_SAT || id == IID_SADD_SAT return .ADD; return .SUB; }
cvp_sat_is_signed :: (id: Intrinsic_Id) -> bool { return id == IID_SADD_SAT || id == IID_SSUB_SAT; }

// processSaturatingInst
cvp_process_saturating_inst :: (si: Value_Id, lvi: *Lvi) -> bool {
    id := call_iid(si);
    opc := cvp_sat_binary_op(id);
    nsw := cvp_sat_is_signed(id);
    nuw := !nsw;
    bo := create_binop(opc, call_arg(si, 0), call_arg(si, 1));
    insert_at_position(bo, inst_block(si), si, false);
    set_name(bo, vname(si));
    set_metadata(bo, 0, get_metadata(si, 0));
    cvp_set_deduced_overflowing_flags(bo, nsw, nuw);
    rauw_with_metadata(si, bo);
    erase_inst_with_metadata(si);
    cvp_process_bin_op(bo, lvi);
    return true;
}

cvp_is_with_overflow :: (id: Intrinsic_Id) -> bool {
    return id == IID_SADD_WITH_OVERFLOW || id == IID_UADD_WITH_OVERFLOW || id == IID_SSUB_WITH_OVERFLOW ||
           id == IID_USUB_WITH_OVERFLOW || id == IID_SMUL_WITH_OVERFLOW || id == IID_UMUL_WITH_OVERFLOW;
}

// processCallSite
cvp_process_call_site :: (cb: Value_Id, lvi: *Lvi) -> bool {
    id := call_iid(cb);
    if id == IID_ABS return cvp_process_abs_intrinsic(cb, lvi);
    if id == IID_SCMP || id == IID_UCMP return cvp_process_cmp_intrinsic(cb, lvi);
    if is_min_max_intrinsic(id) return cvp_process_min_max_intrinsic(cb, lvi);
    if cvp_is_with_overflow(id) {
        if cvp_will_not_overflow(cb, lvi, wo_binary_op(id), wo_is_signed(id)) return cvp_process_overflow_intrinsic(cb, lvi);
    }
    if id == IID_UADD_SAT || id == IID_SADD_SAT || id == IID_USUB_SAT || id == IID_SSUB_SAT {
        if cvp_will_not_overflow(cb, lvi, cvp_sat_binary_op(id), cvp_sat_is_signed(id)) return cvp_process_saturating_inst(cb, lvi);
    }
    changed := false;
    nb := call_num_bundles(cb);
    for k: 0..cast(s64) nb - 1 {
        if call_bundle_tag(cb, cast(u32) k) != "deopt" continue;
        begin := ir.u32_pool[inst(cb).idx + 3 * (cast(u32) k) + 1];
        end := ir.u32_pool[inst(cb).idx + 3 * (cast(u32) k) + 2];
        for j: begin..end - 1 {
            if end == 0 break;
            v := op(cb, j);
            if is_vector_type(vtype(v)) continue;
            if is_constant_kind(vkind(v)) continue;
            c := lvi_get_constant(lvi, v, cb);
            if c == NONE continue;
            set_op(cb, j, c);
            changed = true;
        }
        break;
    }
    arg_nos: [..] u32; arg_nos.allocator = temp;
    n := call_num_args(cb);
    for k: 0..cast(s64) n - 1 {
        v := call_arg(cb, cast(u32) k);
        t := vtype(v);
        if is_ptr_type(t) && !call_param_has_attr(cb, cast(u32) k, .NonNull) && !is_constant_kind(vkind(v)) {
            res := lvi_get_predicate_at(lvi, ICMP_EQ, v, const_null_value(t), cb, false);
            if res != NONE && vkind(res) == .C_INT && ap_is_zero(const_ap(res)) array_add(*arg_nos, cast(u32) k);
        }
    }
    if arg_nos.count == 0 return changed;
    for arg_nos call_add_param_attr_kind(cb, it, .NonNull);
    return true;
}

Cvp_Domain :: enum u8 { NON_NEGATIVE; NON_POSITIVE; UNKNOWN; }
cvp_get_domain :: (cr: Const_Range) -> Cvp_Domain {
    if cr_is_all_non_negative(cr) return .NON_NEGATIVE;
    if cr_icmp(cr, ICMP_SLE, cr_single(ap_zero(cr_bits(cr)))) return .NON_POSITIVE;
    return .UNKNOWN;
}

// IRBuilder::CreateTruncOrBitCast
cvp_irb_trunc_or_bitcast :: (b: *Irb, v: Value_Id, t: Type_Id, name: string) -> Value_Id {
    if type_bits(scalar_type(vtype(v))) == type_bits(scalar_type(t)) return irb_cast(b, .BITCAST, v, t, name);
    return irb_cast(b, .TRUNC, v, t, name);
}

// Type::getWithNewBitWidth
cvp_type_with_new_bit_width :: (t: Type_Id, bits: u32) -> Type_Id {
    it := type_int(bits);
    if is_vector_type(t) return intern_type(type_kind(t), 0, type_count(t), .[it]);
    return it;
}

cvp_power_of_2_ceil :: (x: u32) -> u32 {
    if x <= 1 return x;
    r: u32 = 1;
    while r < x r <<= 1;
    return r;
}

// narrowSDivOrSRem
cvp_narrow_sdiv_or_srem :: (i: Value_Id, lcr: Const_Range, rcr: Const_Range) -> bool {
    orig_width := type_bits(scalar_type(vtype(i)));
    min_signed_bits := max(cr_min_signed_bits(lcr), cr_min_signed_bits(rcr));
    if cr_contains(rcr, ap_all_ones(orig_width)) && cr_contains(lcr, ap_sext(ap_signed_min(min_signed_bits), orig_width))
        min_signed_bits += 1;
    new_width := max(cvp_power_of_2_ceil(min_signed_bits), 8);
    if new_width >= orig_width return false;
    b: Irb; irb_set_before(*b, i);
    trunc_ty := cvp_type_with_new_bit_width(vtype(i), new_width);
    nm := vname(i);
    lhs := cvp_irb_trunc_or_bitcast(*b, op(i, 0), trunc_ty, tprint("%.lhs.trunc", nm));
    rhs := cvp_irb_trunc_or_bitcast(*b, op(i, 1), trunc_ty, tprint("%.rhs.trunc", nm));
    bo := irb_binop(*b, inst_op(i), lhs, rhs, name_ref(nm));
    sext := irb_cast(*b, .SEXT, bo, vtype(i), tprint("%.sext", nm));
    if is_binary_operator(bo) && inst_op(bo) == .SDIV {
        if (inst(i).flags & F_EXACT) != 0 inst(bo).flags |= F_EXACT; else inst(bo).flags &= ~cast(u32) F_EXACT;
    }
    rauw_with_metadata(i, sext);
    erase_inst_with_metadata(i);
    return true;
}

// expandUDivOrURem
cvp_expand_udiv_or_urem :: (i: Value_Id, xcr: Const_Range, ycr: Const_Range) -> bool {
    ty := vtype(i);
    is_rem := inst_op(i) == .UREM;
    x := op(i, 0); y := op(i, 1);
    if cr_icmp(xcr, ICMP_ULT, ycr) {
        rauw_with_metadata(i, ifx is_rem then x else const_null_value(ty));
        erase_inst_with_metadata(i);
        return true;
    }
    if !cr_icmp(xcr, ICMP_ULT, cr_uadd_sat(ycr, ycr)) && !cr_is_all_negative(ycr) return false;
    b: Irb; irb_set_before(*b, i);
    expanded: Value_Id;
    nm := vname(i);
    if cr_icmp(xcr, ICMP_UGE, ycr) {
        if is_rem expanded = irb_binop(*b, .SUB, x, y, "", F_NUW);
        else expanded = const_int(ty, 1);
    } else if is_rem {
        frozen_x := x;
        if !is_guaranteed_not_to_be_undef(x) frozen_x = cvp_irb_freeze(*b, x, tprint("%.frozen", vname(x)));
        frozen_y := y;
        if !is_guaranteed_not_to_be_undef(y) frozen_y = cvp_irb_freeze(*b, y, tprint("%.frozen", vname(y)));
        adj_x := irb_binop(*b, .SUB, frozen_x, frozen_y, tprint("%.urem", nm), F_NUW);
        cmp := cvp_irb_icmp(*b, ICMP_ULT, frozen_x, frozen_y, tprint("%.cmp", nm));
        expanded = irb_select(*b, cmp, frozen_x, adj_x);
        if is_inst(expanded) && inst_op(expanded) == .SELECT set_explicitly_unknown_branch_weights_if_profiled(expanded, "correlated-value-propagation");
    } else {
        cmp := cvp_irb_icmp(*b, ICMP_UGE, x, y, tprint("%.cmp", nm));
        expanded = irb_cast(*b, .ZEXT, cmp, ty, tprint("%.udiv", nm));
    }
    ic_take_name(expanded, i);
    rauw_with_metadata(i, expanded);
    erase_inst_with_metadata(i);
    return true;
}

// IRBuilder::CreateFreeze
cvp_irb_freeze :: (b: *Irb, v: Value_Id, name: string) -> Value_Id {
    i := new_inst(.FREEZE, vtype(v), 1);
    set_op(i, 0, v);
    return irb_insert(b, i, name);
}
// IRBuilder::CreateICmp (ConstantFolder::FoldCmp)
cvp_irb_icmp :: (b: *Irb, pred: u8, l: Value_Id, r: Value_Id, name: string) -> Value_Id {
    if irb_is_const(l) && irb_is_const(r) { c := cf_compare(pred, l, r); if c != NONE return c; }
    i := new_inst(.ICMP, lvi_cmp_result_type(vtype(l)), 2);
    set_op(i, 0, l); set_op(i, 1, r);
    inst(i).pred = pred;
    return irb_insert(b, i, name);
}

// narrowUDivOrURem
cvp_narrow_udiv_or_urem :: (i: Value_Id, xcr: Const_Range, ycr: Const_Range) -> bool {
    max_active_bits := max(cr_active_bits(xcr), cr_active_bits(ycr));
    new_width := max(cvp_power_of_2_ceil(max_active_bits), 8);
    if new_width >= type_bits(scalar_type(vtype(i))) return false;
    b: Irb; irb_set_before(*b, i);
    trunc_ty := cvp_type_with_new_bit_width(vtype(i), new_width);
    nm := vname(i);
    lhs := cvp_irb_trunc_or_bitcast(*b, op(i, 0), trunc_ty, tprint("%.lhs.trunc", nm));
    rhs := cvp_irb_trunc_or_bitcast(*b, op(i, 1), trunc_ty, tprint("%.rhs.trunc", nm));
    bo := irb_binop(*b, inst_op(i), lhs, rhs, name_ref(nm));
    zext := irb_cast(*b, .ZEXT, bo, vtype(i), tprint("%.zext", nm));
    if is_binary_operator(bo) && inst_op(bo) == .UDIV {
        if (inst(i).flags & F_EXACT) != 0 inst(bo).flags |= F_EXACT; else inst(bo).flags &= ~cast(u32) F_EXACT;
    }
    rauw_with_metadata(i, zext);
    erase_inst_with_metadata(i);
    return true;
}

// processUDivOrURem
cvp_process_udiv_or_urem :: (i: Value_Id, lvi: *Lvi) -> bool {
    xcr := lvi_get_constant_range_at_use(lvi, op_use(i, 0), false);
    ycr := lvi_get_constant_range_at_use(lvi, op_use(i, 1), true);
    if cvp_expand_udiv_or_urem(i, xcr, ycr) return true;
    return cvp_narrow_udiv_or_urem(i, xcr, ycr);
}

// BinaryOperator::Create(Opc, L, R, Name, SDI->getIterator()) + setDebugLoc(SDI->getDebugLoc())
cvp_create_binop_before :: (opc: Opcode, l: Value_Id, r: Value_Id, name: string, before: Value_Id) -> Value_Id {
    bo := create_binop(opc, l, r);
    insert_at_position(bo, inst_block(before), before, false);
    if name.count set_name(bo, name);
    set_metadata(bo, 0, get_metadata(before, 0));
    return bo;
}

// processSRem
cvp_process_srem :: (sdi: Value_Id, lcr: Const_Range, rcr: Const_Range, lvi: *Lvi) -> bool {
    if cr_icmp(cr_abs(lcr), ICMP_ULT, cr_abs(rcr)) {
        rauw_with_metadata(sdi, op(sdi, 0));
        erase_inst_with_metadata(sdi);
        return true;
    }
    vs: [2] Value_Id = .[op(sdi, 0), op(sdi, 1)];
    ds: [2] Cvp_Domain = .[cvp_get_domain(lcr), cvp_get_domain(rcr)];
    if ds[0] == .UNKNOWN || ds[1] == .UNKNOWN return false;
    for k: 0..1 {
        if ds[k] == .NON_NEGATIVE continue;
        vs[k] = cvp_create_binop_before(.SUB, const_null_value(vtype(vs[k])), vs[k], tprint("%.nonneg", vname(vs[k])), sdi);
    }
    urem := cvp_create_binop_before(.UREM, vs[0], vs[1], vname(sdi), sdi);
    res := urem;
    if ds[0] == .NON_POSITIVE res = cvp_create_binop_before(.SUB, const_null_value(vtype(res)), res, tprint("%.neg", vname(res)), sdi);
    rauw_with_metadata(sdi, res);
    erase_inst_with_metadata(sdi);
    cvp_process_udiv_or_urem(urem, lvi);
    return true;
}

// processSDiv
cvp_process_sdiv :: (sdi: Value_Id, lcr: Const_Range, rcr: Const_Range, lvi: *Lvi) -> bool {
    div_cr := cr_sdiv(lcr, rcr);
    oks, elem := cr_single_element(div_cr);
    if oks {
        rauw_with_metadata(sdi, const_int_ap(vtype(sdi), elem));
        erase_inst_with_metadata(sdi);
        return true;
    }
    vs: [2] Value_Id = .[op(sdi, 0), op(sdi, 1)];
    ds: [2] Cvp_Domain = .[cvp_get_domain(lcr), cvp_get_domain(rcr)];
    if ds[0] == .UNKNOWN || ds[1] == .UNKNOWN return false;
    for k: 0..1 {
        if ds[k] == .NON_NEGATIVE continue;
        vs[k] = cvp_create_binop_before(.SUB, const_null_value(vtype(vs[k])), vs[k], tprint("%.nonneg", vname(vs[k])), sdi);
    }
    udiv := cvp_create_binop_before(.UDIV, vs[0], vs[1], vname(sdi), sdi);
    if (inst(sdi).flags & F_EXACT) != 0 inst(udiv).flags |= F_EXACT;
    res := udiv;
    if ds[0] != ds[1] res = cvp_create_binop_before(.SUB, const_null_value(vtype(res)), res, tprint("%.neg", vname(res)), sdi);
    rauw_with_metadata(sdi, res);
    erase_inst_with_metadata(sdi);
    cvp_process_udiv_or_urem(udiv, lvi);
    return true;
}

// processSDivOrSRem
cvp_process_sdiv_or_srem :: (i: Value_Id, lvi: *Lvi) -> bool {
    lcr := lvi_get_constant_range_at_use(lvi, op_use(i, 0), false);
    rcr := lvi_get_constant_range_at_use(lvi, op_use(i, 1), true);
    if inst_op(i) == .SDIV && cvp_process_sdiv(i, lcr, rcr, lvi) return true;
    if inst_op(i) == .SREM && cvp_process_srem(i, lcr, rcr, lvi) return true;
    return cvp_narrow_sdiv_or_srem(i, lcr, rcr);
}

// processAShr
cvp_process_ashr :: (sdi: Value_Id, lvi: *Lvi) -> bool {
    lrange := lvi_get_constant_range_at_use(lvi, op_use(sdi, 0), false);
    w := type_bits(scalar_type(vtype(sdi)));
    neg_one_or_zero := cr_new(ap_all_ones(w), ap_from_u64(w, 1));
    if cr_contains_range(neg_one_or_zero, lrange) {
        rauw_with_metadata(sdi, op(sdi, 0));
        erase_inst_with_metadata(sdi);
        return true;
    }
    if !cr_is_all_non_negative(lrange) return false;
    bo := create_binop(.LSHR, op(sdi, 0), op(sdi, 1));
    insert_at_position(bo, inst_block(sdi), sdi, false);
    take_name(bo, sdi);
    set_metadata(bo, 0, get_metadata(sdi, 0));
    if (inst(sdi).flags & F_EXACT) != 0 inst(bo).flags |= F_EXACT;
    rauw_with_metadata(sdi, bo);
    erase_inst_with_metadata(sdi);
    return true;
}

// CastInst::Create(Opc, V, Ty, "", Before) + takeName + setDebugLoc + setNonNeg
cvp_replace_cast_nneg :: (old: Value_Id, opc: Opcode, src: Value_Id) {
    c := create_cast(opc, src, vtype(old));
    insert_at_position(c, inst_block(old), old, false);
    take_name(c, old);
    set_metadata(c, 0, get_metadata(old, 0));
    inst(c).flags |= F_EXACT;   // nneg
    rauw_with_metadata(old, c);
    erase_inst_with_metadata(old);
}

// processSExt
cvp_process_sext :: (sdi: Value_Id, lvi: *Lvi) -> bool {
    if !cr_is_all_non_negative(lvi_get_constant_range_at_use(lvi, op_use(sdi, 0), false)) return false;
    // CreateZExtOrBitCast: the types differ in width here
    cvp_replace_cast_nneg(sdi, .ZEXT, op(sdi, 0));
    return true;
}

// processPossibleNonNeg (zext, uitofp)
cvp_process_possible_non_neg :: (i: Value_Id, lvi: *Lvi) -> bool {
    if (inst(i).flags & F_EXACT) != 0 return false;
    if !cr_is_all_non_negative(lvi_get_constant_range_at_use(lvi, op_use(i, 0), false)) return false;
    inst(i).flags |= F_EXACT;
    return true;
}

// processSIToFP
cvp_process_sitofp :: (i: Value_Id, lvi: *Lvi) -> bool {
    if !cr_is_all_non_negative(lvi_get_constant_range_at_use(lvi, op_use(i, 0), false)) return false;
    cvp_replace_cast_nneg(i, .UITOFP, op(i, 0));
    return true;
}

// processBinOp
cvp_process_bin_op :: (bo: Value_Id, lvi: *Lvi) -> bool {
    nsw := (inst(bo).flags & F_NSW) != 0;
    nuw := (inst(bo).flags & F_NUW) != 0;
    if nsw && nuw return false;
    opc := inst_op(bo);
    lrange := lvi_get_constant_range_at_use(lvi, op_use(bo, 0), false);
    rrange := lvi_get_constant_range_at_use(lvi, op_use(bo, 1), false);
    changed := false;
    new_nuw := false; new_nsw := false;
    if !nuw {
        r := cr_guaranteed_no_wrap_region(opc, rrange, true);
        new_nuw = cr_contains_range(r, lrange);
        changed |= new_nuw;
    }
    if !nsw {
        r := cr_guaranteed_no_wrap_region(opc, rrange, false);
        new_nsw = cr_contains_range(r, lrange);
        changed |= new_nsw;
    }
    cvp_set_deduced_overflowing_flags(bo, new_nsw, new_nuw);
    return changed;
}

// processAnd
cvp_process_and :: (bo: Value_Id, lvi: *Lvi) -> bool {
    ok, rhs := pm_low_bit_mask_ap(op(bo, 1));
    if !ok return false;
    lrange := lvi_get_constant_range_at_use(lvi, op_use(bo, 0), false);
    if !ap_ule(cr_umax(lrange), rhs) return false;
    rauw_with_metadata(bo, op(bo, 0));
    erase_inst_with_metadata(bo);
    return true;
}

// processTrunc
cvp_process_trunc :: (ti: Value_Id, lvi: *Lvi) -> bool {
    f := inst(ti).flags;
    if (f & F_NSW) != 0 && (f & F_NUW) != 0 return false;
    range := lvi_get_constant_range_at_use(lvi, op_use(ti, 0), false);
    dest_width := type_bits(scalar_type(vtype(ti)));
    changed := false;
    if (f & F_NUW) == 0 && cr_active_bits(range) <= dest_width { inst(ti).flags |= F_NUW; changed = true; }
    if (f & F_NSW) == 0 && cr_min_signed_bits(range) <= dest_width { inst(ti).flags |= F_NSW; changed = true; }
    return changed;
}

// depth_first(&F.getEntryBlock()) as an iterator: a block's successors are read when the walk moves past it (the
// df_iterator child iterator is created lazily, so CFG changes made while visiting a block are seen).
Cfg_Dfs :: struct {
    Frame :: struct { b: Value_Id; term: Value_Id; next: u32; init: bool; }
    visited: Table(Value_Id, bool);
    stack: [..] Frame;
    started: bool;
}
cfg_dfs_begin :: (d: *Cfg_Dfs, entry: Value_Id) {
    d.visited.allocator = temp; d.stack.allocator = temp;
    table_set(*d.visited, entry, true);
    array_add(*d.stack, .{entry, NONE, 0, false});
}
// The next block in preorder (NONE at the end); the first call returns the entry block.
cfg_dfs_next :: (d: *Cfg_Dfs) -> Value_Id {
    if !d.started { d.started = true; if d.stack.count return d.stack[0].b; return NONE; }
    while d.stack.count {
        top := *d.stack[d.stack.count - 1];
        if !top.init { top.init = true; top.term = block_terminator(top.b); top.next = 0; }
        if top.term != NONE && top.next < num_successors(top.term) {
            s := get_successor(top.term, top.next);
            top.next += 1;
            if !table_contains(*d.visited, s) {
                table_set(*d.visited, s, true);
                array_add(*d.stack, .{s, NONE, 0, false});
                return s;
            }
            continue;
        }
        d.stack.count -= 1;
    }
    return NONE;
}

// GlobalValue::hasExactDefinition
cvp_has_exact_definition :: (f: Value_Id) -> bool {
    if is_declaration(f) return false;
    l := glob(f).linkage;
    if l == .WEAK_ODR || l == .LINKONCE_ODR || l == .AVAILABLE_EXTERNALLY return false;
    if gv_is_interposable(f) return false;
    if fn_has_fn_attr(f, .NoBuiltin) return false;   // isNobuiltinFnDef
    return true;
}

// runImpl
cvp_run_impl :: (f: Value_Id, lvi: *Lvi, dt: *Dom_Tree, sq: Simplify_Query) -> bool {
    fn_changed := false;
    ret_ty := func_ret(glob(f).value_type);
    has_ret_range := false;
    ret_range: Const_Range;
    if cvp_has_exact_definition(f) && is_int_type(scalar_type(ret_ty)) {
        has_ret_range = true;
        ret_range = cr_empty(type_bits(scalar_type(ret_ty)));
    }
    dfs: Cfg_Dfs;
    cfg_dfs_begin(*dfs, fn_entry(f));
    while true {
        bb := cfg_dfs_next(*dfs);
        if bb == NONE break;
        bb_changed := false;
        i := block_first(bb);
        while i != NONE {
            nx := inst_next(i);
            o := inst_op(i);
            if o == {
                case .SELECT; bb_changed |= cvp_process_select(i, lvi);
                case .PHI; bb_changed |= cvp_process_phi(i, lvi, dt, sq);
                case .ICMP; #through;
                case .FCMP; bb_changed |= cvp_process_cmp(i, lvi);
                case .CALL; #through;
                case .INVOKE; bb_changed |= cvp_process_call_site(i, lvi);
                case .SREM; #through;
                case .SDIV; bb_changed |= cvp_process_sdiv_or_srem(i, lvi);
                case .UDIV; #through;
                case .UREM; bb_changed |= cvp_process_udiv_or_urem(i, lvi);
                case .ASHR; bb_changed |= cvp_process_ashr(i, lvi);
                case .SEXT; bb_changed |= cvp_process_sext(i, lvi);
                case .ZEXT; bb_changed |= cvp_process_possible_non_neg(i, lvi);
                case .UITOFP; bb_changed |= cvp_process_possible_non_neg(i, lvi);
                case .SITOFP; bb_changed |= cvp_process_sitofp(i, lvi);
                case .ADD; #through;
                case .SUB; #through;
                case .MUL; #through;
                case .SHL; bb_changed |= cvp_process_bin_op(i, lvi);
                case .AND; bb_changed |= cvp_process_and(i, lvi);
                case .TRUNC; bb_changed |= cvp_process_trunc(i, lvi);
            }
            i = nx;
        }
        term := block_terminator(bb);
        if inst_op(term) == .SWITCH {
            bb_changed |= cvp_process_switch(term, lvi, dt);
        } else if inst_op(term) == .RET && nops(term) > 0 {
            ret_val := op(term, 0);
            if has_ret_range && !cr_is_full_set(ret_range)
                ret_range = cr_union(ret_range, lvi_get_constant_range(lvi, ret_val, term, false));
            if !is_constant_kind(vkind(ret_val)) {
                c := cvp_get_constant_at(ret_val, term, lvi);
                if c != NONE {
                    // replaceUsesOfWith
                    n := nops(term);
                    for k: 0..cast(s64) n - 1 if op(term, cast(u32) k) == ret_val set_op(term, cast(u32) k, c);
                    bb_changed = true;
                }
            }
        }
        fn_changed |= bb_changed;
    }
    if has_ret_range && !cr_is_full_set(ret_range) {
        ra := attr_set_find(attr_list_ret(glob(f).attrs), .Range);
        if ra ret_range = cr_intersect(ret_range, attr_range(ra));
        if !cr_is_empty_set(ret_range) && !cr_is_single_element(ret_range) {
            fn_add_range_ret_attr(f, ret_range);
            fn_changed = true;
        }
    }
    return fn_changed;
}

// Function::addRangeRetAttr
fn_add_range_ret_attr :: (f: Value_Id, r: Const_Range) {
    a: Attr; a.kind = .Range; a.ty = NONE; a.ival = r.lo.bits;
    lw := ap_words(r.lo); hw := ap_words(r.hi);
    a.lo = NewArray(lw.count, u64); for lw a.lo[it_index] = it;
    a.hi = NewArray(hw.count, u64); for hw a.hi[it_index] = it;
    l := glob(f).attrs;
    ps := ifx l == 0 then .[] else ir.attr_lists[l].params;
    fn_set_attr_list(f, attr_list_get(attr_list_fn(l), attr_set_with(attr_list_ret(l), a), ps));
}

// CorrelatedValuePropagationPass::run
cvp_run :: (f: Value_Id) -> Preserved {
    lvi := get_lvi(f);
    dt := get_domtree(f);
    // getBestSimplifyQuery(AM, F): the cached DT, TLI and AC
    sq: Simplify_Query;
    sq.dt = cached_domtree(f);
    sq.ac = cached_assumption_cache(f);
    changed := cvp_run_impl(f, lvi, dt, sq);
    pa: Preserved;
    if !changed pa = PRESERVE_ALL;
    else preserve(*pa, .DOMTREE);
    // PA.abandon<LazyValueAnalysis>()
    if pa.all { pa.all = false; pa.cfg = true; pa.mask = ~cast(u32) 0; }
    pa.mask &= ~((cast(u32) 1) << cast(u32) Analysis_Kind.LVI);
    return pa;
}
