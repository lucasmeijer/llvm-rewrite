// InstCombine: the cast visitors (visitTrunc, visitZExt, visitSExt, visitFPTrunc, visitFPExt, visitFPToUI/SI,
// visitUIToFP/SIToFP, visitIntToPtr, visitPtrToInt, visitPtrToAddr, visitBitCast, visitAddrSpaceCast) and all their
// helpers (commonCastTransforms, EvaluateInDifferentType, TypeEvaluationHelper's canEvaluate{Truncated,ZExtd,SExtd},
// narrowBinOp, narrowFunnelShift, transform{Z,S}ExtICmp, foldItoFPtoI, optimizeBitCastFromPhi, ...).
// Ported from: llvm/lib/Transforms/InstCombine/InstCombineCasts.cpp (LLVM 23.1.5), in the file's order.

// Type::getPrimitiveSizeInBits (vectors: element count * element bits; pointers: 0)
ic_prim_bits :: (t: Type_Id) -> u64 {
    if is_vector_type(t) return type_count(t) * cast(u64) type_bits(type_elem(t));
    return cast(u64) type_bits(t);
}
// Log2_32 (floor; -1 as u32 for 0)
ic_log2_32 :: (x: u64) -> u32 { if x == 0 return 0xFFFF_FFFF; n: u32 = 0; v := x; while v > 1 { n += 1; v >>= 1; } return n; }
ic_is_pow2 :: (x: u64) -> bool { return x != 0 && (x & (x - 1)) == 0; }
// Value::user_back (the most recently added user = first in the use list)
ic_user_back :: (v: Value_Id) -> Value_Id { return first_user(v); }
// a known-bits query with only the DataLayout (llvm::computeKnownBits(V, DL))
ic_known_bits_dl :: (v: Value_Id) -> Known_Bits { q: Simplify_Query; return known_bits(v, q); }
// InstCombiner::ComputeMaxSignificantBits
ic_max_significant_bits :: (v: Value_Id, cxt: Value_Id) -> u32 { return max_significant_bits(v, ic_q_no_dc(cxt)); }
// llvm::ComputeMaxSignificantBits(Op, DL, &AC, CxtI, &DT): no DomConditionCache, safeCxtI
ic_q_no_dc :: (i: Value_Id) -> Simplify_Query { q: Simplify_Query; q.dt = ic.dt; q.ac = ic.ac; q.cxt = i; return q; }
// CastInst::CreateIntegerCast (unlinked)
create_integer_cast :: (v: Value_Id, t: Type_Id, is_signed: bool) -> Value_Id {
    sb := scalar_bits(v); db := type_bits(scalar_type(t));
    opc: Opcode = ifx sb == db then .BITCAST else ifx sb > db then .TRUNC else ifx is_signed then .SEXT else .ZEXT;
    return create_cast(opc, v, t);
}
// CastInst::CreateFPCast (unlinked)
create_fp_cast :: (v: Value_Id, t: Type_Id) -> Value_Id {
    sb := type_bits(scalar_type(vtype(v))); db := type_bits(scalar_type(t));
    opc: Opcode = ifx sb == db then .BITCAST else ifx sb > db then .FPTRUNC else .FPEXT;
    return create_cast(opc, v, t);
}
// CastInst::CreateBitOrPointerCast (unlinked)
create_bit_or_pointer_cast :: (v: Value_Id, t: Type_Id) -> Value_Id {
    st := vtype(v);
    if is_ptr_or_ptr_vector(st) && !is_ptr_or_ptr_vector(t) return create_cast(.PTRTOINT, v, t);
    if !is_ptr_or_ptr_vector(st) && is_ptr_or_ptr_vector(t) return create_cast(.INTTOPTR, v, t);
    return create_cast(.BITCAST, v, t);
}
// CreateFPTruncFMF / CreateCast with explicit fast-math flags
icb_cast_fmf :: (opc: Opcode, v: Value_Id, dt: Type_Id, fmf: u32, name: string = "") -> Value_Id {
    if vtype(v) == dt return v;
    if is_const(v) { f := cfo_cast_operand(opc, v, dt); if f != NONE return f; }
    i := new_inst(opc, dt, 1);
    set_op(i, 0, v);
    if is_fp_math_inst(i) set_fmf(i, fmf);
    return icb_insert(i, name);
}
// CreateSelectFMF(C, T, F, FMF, Name, MDFrom)
icb_select_fmf :: (c: Value_Id, t: Value_Id, f: Value_Id, fmf: u32, name: string, md_from: Value_Id) -> Value_Id {
    if is_const(c) && is_const(t) && is_const(f) { x := cf_select(c, t, f); if x != NONE return x; }
    i := create_select(c, t, f);
    if md_from != NONE copy_prof_unpredictable(i, md_from);
    if is_fp_math_inst(i) set_fmf(i, fmf);
    return icb_insert(i, name);
}
// SelectInst::Create(C, T, F, "", nullptr, MDFrom): copies all metadata of MDFrom
create_select_md_from :: (c: Value_Id, t: Value_Id, f: Value_Id, md_from: Value_Id) -> Value_Id {
    s := create_select(c, t, f);
    if md_from != NONE copy_metadata(s, md_from);
    return s;
}
// ExtractElementInst::Create / InsertElementInst::Create (unlinked)
create_extract_element :: (v: Value_Id, idx: Value_Id) -> Value_Id {
    i := new_inst(.EXTRACTELEMENT, type_elem(vtype(v)), 2);
    set_op(i, 0, v); set_op(i, 1, idx);
    return i;
}
create_insert_element :: (v: Value_Id, e: Value_Id, idx: Value_Id) -> Value_Id {
    i := new_inst(.INSERTELEMENT, vtype(v), 3);
    set_op(i, 0, v); set_op(i, 1, e); set_op(i, 2, idx);
    return i;
}
// IRBuilder::CreateVScale(Ty)
icb_vscale :: (t: Type_Id) -> Value_Id { return icb_intrinsic(IID_VSCALE, .[t], .[]); }
// Attribute::getVScaleRangeMax of the function's vscale_range (0 = none)
ic_vscale_range_max :: (f: Value_Id) -> (bool, u64) {
    a := fn_get_fn_attr(f, .VScaleRange);
    if !a return false, 0;
    mx := a.ival & 0xFFFF_FFFF;
    if mx == 0 return false, 0;
    return true, mx;
}
// replaceAllDbgUsesWith(From, To, DomPoint, DT) with InstCombine's DominatorTree
ic_replace_all_dbg_uses_with :: (from: Value_Id, to: Value_Id, dom_point: Value_Id) {
    if !is_inst(from) return;
    replace_all_dbg_uses_with(from, to, dom_point, ic.dt);
}

// ---------------------------------------------------------------- EvaluateInDifferentType

ic_evaluate_in_different_type_impl :: (v: Value_Id, ty: Type_Id, is_signed: bool, processed: *Table(Value_Id, Value_Id)) -> Value_Id {
    found, r := table_find(processed, v);
    if found return r;
    if is_const(v) return cfo_integer_cast(v, ty, is_signed);
    i := v;
    res: Value_Id = NONE;
    opc := inst_op(i);
    if opc == {
        case .ADD; #through; case .SUB; #through; case .MUL; #through; case .AND; #through; case .OR; #through;
        case .XOR; #through; case .ASHR; #through; case .LSHR; #through; case .SHL; #through; case .UDIV; #through;
        case .UREM;
            lhs := ic_evaluate_in_different_type_impl(op(i, 0), ty, is_signed, processed);
            rhs := ic_evaluate_in_different_type_impl(op(i, 1), ty, is_signed, processed);
            res = create_binop(opc, lhs, rhs);
            if opc == .LSHR || opc == .ASHR set_exact(res, is_exact(i));
        case .TRUNC; #through; case .ZEXT; #through; case .SEXT;
            if vtype(op(i, 0)) == ty return op(i, 0);
            res = create_integer_cast(op(i, 0), ty, opc == .SEXT);
            if opc == .TRUNC {
                if inst_op(res) == .TRUNC {
                    if scalar_bits(i) <= type_bits(scalar_type(ty)) { set_nsw(res, has_nsw(i)); set_nuw(res, has_nuw(i)); }
                } else if inst_op(res) == .ZEXT {
                    if has_nuw(i) set_flag(res, F_EXACT, true);
                }
            }
        case .SELECT;
            t := ic_evaluate_in_different_type_impl(op(i, 1), ty, is_signed, processed);
            f := ic_evaluate_in_different_type_impl(op(i, 2), ty, is_signed, processed);
            res = create_select(op(i, 0), t, f);
        case .PHI;
            n := phi_num_incoming(i);
            res = create_phi(ty, n);
            for k: 0..cast(s64) n - 1 {
                x := ic_evaluate_in_different_type_impl(phi_value(i, cast(u32) k), ty, is_signed, processed);
                phi_add_incoming(res, x, phi_block(i, cast(u32) k));
            }
        case .FPTOUI; #through; case .FPTOSI;
            res = create_cast(opc, op(i, 0), ty);
        case .CALL;
            id := call_iid(i);
            if id == IID_VSCALE {
                res = create_intrinsic_call(IID_VSCALE, .[ty], .[]);
            } else if id == IID_UMIN || id == IID_UMAX || id == IID_SMIN || id == IID_SMAX {
                a0 := ic_evaluate_in_different_type_impl(call_arg(i, 0), ty, is_signed, processed);
                a1 := ic_evaluate_in_different_type_impl(call_arg(i, 1), ty, is_signed, processed);
                res = create_intrinsic_call(id, .[ty], .[a0, a1]);
            } else if id == IID_ABS {
                a := ic_evaluate_in_different_type_impl(call_arg(i, 0), ty, is_signed, processed);
                res = create_intrinsic_call(id, .[ty], .[a, get_false(ir.t_i1)]);
            } else fatal("internal: EvaluateInDifferentType of an unsupported call");
        case .SHUFFLEVECTOR;
            st := type_elem(ty);
            vt := vtype(op(i, 0));
            fixed := vector_with_elt(vt, st);
            a0 := ic_evaluate_in_different_type_impl(op(i, 0), fixed, is_signed, processed);
            a1 := ic_evaluate_in_different_type_impl(op(i, 1), fixed, is_signed, processed);
            res = create_shuffle(a0, a1, shuffle_mask(i));
        case;
            fatal("internal: EvaluateInDifferentType of '%'", opcode_name(opc));
    }
    ic_take_name(res, i);
    result := ic_insert_new_inst_with(res, i);
    if !has_one_use(v) table_set(processed, v, result);
    return result;
}
ic_evaluate_in_different_type :: (v: Value_Id, ty: Type_Id, is_signed: bool) -> Value_Id {
    processed: Table(Value_Id, Value_Id); processed.allocator = temp;
    return ic_evaluate_in_different_type_impl(v, ty, is_signed, *processed);
}

// InstCombinerImpl::isEliminableCastPair
ic_is_eliminable_cast_pair :: (ci1: Value_Id, ci2: Value_Id) -> Opcode {
    src := vtype(op(ci1, 0)); mid := vtype(ci1); dst := vtype(ci2);
    res := is_eliminable_cast_pair_dl(inst_op(ci1), inst_op(ci2), src, mid, dst);
    if res == .INTTOPTR && (!is_ptr_or_ptr_vector(dst) || src != irb_int_ptr_type(dst)) res = .NONE_OP;
    if res == .PTRTOINT && (!is_ptr_or_ptr_vector(src) || dst != irb_int_ptr_type(src)) res = .NONE_OP;
    return res;
}

// commonCastTransforms
ic_common_cast_transforms :: (i: Value_Id) -> Value_Id {
    src := op(i, 0);
    ty := vtype(i);
    opc := inst_op(i);
    v := simplify_cast_inst(opc, src, ty, ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if is_inst(src) && is_cast_op(inst_op(src)) {
        nopc := ic_is_eliminable_cast_pair(src, i);
        if nopc != .NONE_OP {
            res := create_cast(nopc, op(src, 0), ty);
            if has_one_use(src) ic_replace_all_dbg_uses_with(src, res, i);
            return res;
        }
    }
    if is_inst(src) && inst_op(src) == .SELECT {
        cmp := op(src, 0);
        if !is_cmp_inst(cmp) || vtype(op(cmp, 0)) != vtype(src) || (opc == .TRUNC && ic_should_change_type(vtype(src), ty)) {
            okb, x := pm_elementwise_bitcast(i);
            if opc != .BITCAST || okb {
                nv := ic_fold_op_into_select(i, src);
                if nv != NONE {
                    ic_replace_all_dbg_uses_with(src, nv, i);
                    return nv;
                }
            }
        }
    }
    if is_phi(src) {
        if !is_int_type(vtype(src)) || !is_int_type(ty) || ic_should_change_type(vtype(src), ty) {
            nv := ic_fold_op_into_phi(i, src);
            if nv != NONE return nv;
        }
    }
    oks, x, y, mask := pm_shuffle(src);
    if oks && has_one_use(src) && pm_poison(y) {
        sty := vtype(x);
        if type_kind(sty) == .VECTOR && type_kind(ty) == .VECTOR && type_count(sty) == type_count(ty) &&
           ic_prim_bits(sty) == ic_prim_bits(ty) {
            cx := icb_cast(opc, x, ty);
            return create_shuffle(cx, NONE, mask);
        }
    }
    return NONE;
}
// the old name
ic_visit_cast :: (i: Value_Id) -> Value_Id { return ic_common_cast_transforms(i); }

// ---------------------------------------------------------------- TypeEvaluationHelper

Type_Eval_Helper :: struct {
    visited: Table(Value_Id, bool);
    pending: [..] Value_Id;
}
teh_init :: (h: *Type_Eval_Helper) { h.visited.allocator = temp; h.pending.allocator = temp; }

// canAlwaysEvaluateInType
teh_can_always_evaluate_in_type :: (v: Value_Id, ty: Type_Id) -> bool {
    if is_const(v) return pm_imm_constant(v);
    ok, x := pmi_zext_or_sext(v);
    if !ok ok, x = pmi_cast(v, .TRUNC);
    if ok && vtype(x) == ty return true;
    return false;
}
// canNotEvaluateInType
teh_can_not_evaluate_in_type :: (v: Value_Id, ty: Type_Id) -> bool {
    if !is_inst(v) return true;
    if !has_one_use(v) return true;
    return false;
}
teh_all_pending_visited :: (h: *Type_Eval_Helper) -> bool {
    for h.pending if !table_contains(*h.visited, it) return false;
    return true;
}
Teh_Kind :: enum u8 { TRUNC; SEXT; }
// canEvaluate(V, Ty, Pred)
teh_can_evaluate :: (h: *Type_Eval_Helper, v: Value_Id, ty: Type_Id, kind: Teh_Kind, cxt: Value_Id) -> bool {
    if teh_can_always_evaluate_in_type(v, ty) return true;
    if !is_inst(v) return false;
    found, r := table_find(*h.visited, v);
    if found return r;
    table_set(*h.visited, v, false);
    if !has_one_use(v) {
        u := ir.v_first_use[v];
        while u != NONE {
            us := ir.u_user[u];
            if is_inst(us) && inst_op(us) == .SELECT && u - ir.v_ops[us] == 0 return false;
            array_add(*h.pending, us);
            u = ir.u_next[u];
        }
    }
    result := ifx kind == .TRUNC then teh_can_evaluate_truncated_pred(h, v, ty, cxt) else teh_can_evaluate_sextd_pred(h, v, ty);
    table_set(*h.visited, v, result);
    return result;
}

// canEvaluateTruncated
ic_can_evaluate_truncated :: (v: Value_Id, ty: Type_Id, cxt: Value_Id) -> bool {
    h: Type_Eval_Helper; teh_init(*h);
    return teh_can_evaluate(*h, v, ty, .TRUNC, cxt) && teh_all_pending_visited(*h);
}
teh_can_evaluate_truncated_pred :: (h: *Type_Eval_Helper, v: Value_Id, ty: Type_Id, cxt: Value_Id) -> bool {
    i := v;
    orig_ty := vtype(v);
    tr :: (h: *Type_Eval_Helper, x: Value_Id, ty: Type_Id, cxt: Value_Id) -> bool #expand { return teh_can_evaluate(h, x, ty, .TRUNC, cxt); }
    both :: (h: *Type_Eval_Helper, i: Value_Id, ty: Type_Id, cxt: Value_Id) -> bool {
        return teh_can_evaluate(h, op(i, 0), ty, .TRUNC, cxt) && teh_can_evaluate(h, op(i, 1), ty, .TRUNC, cxt);
    }
    if inst_op(i) == {
        case .ADD; #through; case .SUB; #through; case .MUL; #through; case .AND; #through; case .OR; #through; case .XOR;
            return both(h, i, ty, cxt);
        case .UDIV; #through; case .UREM;
            ow := type_bits(scalar_type(orig_ty)); bw := type_bits(scalar_type(ty));
            mask := ap_bits_set_from(ow, bw);
            if ic_masked_value_is_zero(op(i, 0), mask, i) && ic_masked_value_is_zero(op(i, 1), mask, i) return both(h, i, ty, cxt);
        case .SHL;
            bw := type_bits(scalar_type(ty));
            amt := ic_known_bits_dl(op(i, 1));
            if ap_ult_u64(kb_max_value(amt), bw) return both(h, i, ty, cxt);
        case .LSHR;
            ow := type_bits(scalar_type(orig_ty)); bw := type_bits(scalar_type(ty));
            amt := ic_known_bits(op(i, 1), cxt);
            max_amt := kb_max_value(amt);
            shifted := ap_bits_set_from(ow, bw);
            if ap_ult_u64(max_amt, bw) {
                ub := ic_user_back(v);
                if is_inst(ub) && inst_op(ub) == .TRUNC {
                    demanded := scalar_bits(ub);
                    if ap_ule_u64(ap_add_u64(max_amt, demanded), bw) return both(h, i, ty, cxt);
                }
                if ic_masked_value_is_zero(op(i, 0), shifted, cxt) return both(h, i, ty, cxt);
            }
        case .ASHR;
            ow := type_bits(scalar_type(orig_ty)); bw := type_bits(scalar_type(ty));
            amt := ic_known_bits_dl(op(i, 1));
            shifted := ow - bw;
            if ap_ult_u64(kb_max_value(amt), bw) && shifted < ic_num_sign_bits(op(i, 0), cxt) return both(h, i, ty, cxt);
        case .TRUNC; return true;
        case .ZEXT; #through; case .SEXT; return true;
        case .SELECT;
            return teh_can_evaluate(h, op(i, 1), ty, .TRUNC, cxt) && teh_can_evaluate(h, op(i, 2), ty, .TRUNC, cxt);
        case .PHI;
            n := phi_num_incoming(i);
            for k: 0..cast(s64) n - 1 if !teh_can_evaluate(h, phi_value(i, cast(u32) k), ty, .TRUNC, cxt) return false;
            return true;
        case .FPTOUI; #through; case .FPTOSI;
            in_ty := scalar_type(vtype(op(i, 0)));
            min_bw := ic_semantics_int_size_in_bits(type_kind(in_ty), inst_op(i) == .FPTOSI);
            return type_bits(scalar_type(ty)) >= min_bw;
        case .SHUFFLEVECTOR;
            return both(h, i, ty, cxt);
        case .CALL;
            if call_iid(i) == IID_ABS {
                abs_op := call_arg(i, 0);
                if ic_max_significant_bits(abs_op, cxt) > type_bits(scalar_type(ty)) return false;
                return teh_can_evaluate(h, abs_op, ty, .TRUNC, cxt);
            }
            id := call_iid(i);
            if !is_min_max_intrinsic(id) return false;
            op0 := call_arg(i, 0); op1 := call_arg(i, 1);
            bw := type_bits(scalar_type(ty));
            if id == IID_SMIN || id == IID_SMAX {
                if ic_max_significant_bits(op0, cxt) > bw || ic_max_significant_bits(op1, cxt) > bw return false;
            } else {
                mask := ap_bits_set_from(type_bits(scalar_type(orig_ty)), bw);
                if !ic_masked_value_is_zero(op0, mask, cxt) || !ic_masked_value_is_zero(op1, mask, cxt) return false;
            }
            return teh_can_evaluate(h, op0, ty, .TRUNC, cxt) && teh_can_evaluate(h, op1, ty, .TRUNC, cxt);
    }
    return false;
}
// APFloatBase::semanticsIntSizeInBits(Sem, isSigned)
ic_semantics_int_size_in_bits :: (k: Type_Kind, is_signed: bool) -> u32 {
    p, max_exp, min_exp, bits := fp_semantics(k);
    // The max FP value is pow(2, MaxExponent) * (1 + MaxFraction), so we need MaxExponent + 1 bits; plus the sign
    size_in_bits := cast(u32) max_exp + 1;
    if is_signed size_in_bits += 1;
    return size_in_bits;
}

// ---------------------------------------------------------------- trunc helpers

// foldVecTruncToExtElt
ic_fold_vec_trunc_to_ext_elt :: (trunc: Value_Id) -> Value_Id {
    trunc_op := op(trunc, 0);
    dest_ty := vtype(trunc);
    if !has_one_use(trunc_op) || !is_int_type(dest_ty) return NONE;
    vec_input: Value_Id = NONE;
    shift_val: Value_Id = NONE;
    okb, x := pm_cast(trunc_op, .BITCAST);
    if okb vec_input = x;
    else {
        ok, a, s := pm_binop(trunc_op, .LSHR);
        if !ok return NONE;
        okb2, x2 := pm_cast(a, .BITCAST);
        if !okb2 || !pm_constant_int(s) return NONE;
        vec_input = x2; shift_val = s;
    }
    if !is_vector_type(vtype(vec_input)) return NONE;
    vec_ty := vtype(vec_input);
    vec_width := ic_prim_bits(vec_ty);
    dest_width := ic_prim_bits(dest_ty);
    shift_amount: u64 = ifx shift_val != NONE then const_int_zext(shift_val) else 0;
    if vec_width % dest_width != 0 || shift_amount % dest_width != 0 return NONE;
    num_vec_elts := vec_width / dest_width;
    if type_elem(vec_ty) != dest_ty {
        vec_ty = type_vector(num_vec_elts, dest_ty, false);
        vec_input = icb_cast(.BITCAST, vec_input, vec_ty, "bc");
    }
    elt := shift_amount / dest_width;
    if dl.big_endian elt = num_vec_elts - 1 - elt;
    return create_extract_element(vec_input, const_int(ir.t_i32, elt));
}

// foldVecExtTruncToExtElt
ic_fold_vec_ext_trunc_to_ext_elt :: (trunc: Value_Id) -> Value_Id {
    src := op(trunc, 0);
    src_bits := scalar_bits(src);
    dst_bits := scalar_bits(trunc);
    ratio := src_bits / dst_bits;
    if src_bits % dst_bits != 0 return NONE;
    vec_op: Value_Id = NONE; cst: Value_Id = NONE;
    have_shift := false; shift_amount: APInt;
    if has_one_use(src) && is_inst(src) && inst_op(src) == .EXTRACTELEMENT && pm_constant_int(op(src, 1)) {
        vec_op = op(src, 0); cst = op(src, 1);
    } else if has_one_use(src) && is_inst(src) && inst_op(src) == .LSHR {
        e := op(src, 0);
        oka, sa := pm_apint(op(src, 1));
        if !(is_inst(e) && inst_op(e) == .EXTRACTELEMENT && pm_constant_int(op(e, 1)) && oka) return NONE;
        vec_op = op(e, 0); cst = op(e, 1); have_shift = true; shift_amount = sa;
    } else return NONE;
    vty := vtype(vec_op);
    elts := type_count(vty);
    bitcast_num_elts := elts * ratio;
    ci := const_ap(cst);
    if ap_uge_u64(ci, 0xFFFF_FFFF_FFFF_FFFF / cast(u64) ratio) return NONE;
    idx := ap_zext_value(ci);
    new_idx: u64 = ifx dl.big_endian then (idx + 1) * ratio - 1 else idx * ratio;
    if have_shift {
        if ap_uge_u64(shift_amount, src_bits) || ap_urem_u64(shift_amount, dst_bits) != 0 return NONE;
        ofs := ap_zext_value(shift_amount) / dst_bits;
        new_idx = ifx dl.big_endian then new_idx - ofs else new_idx + ofs;
    }
    to := type_vector(bitcast_num_elts, vtype(trunc), type_kind(vty) == .SVECTOR);
    bc := icb_cast(.BITCAST, vec_op, to);
    return create_extract_element(bc, const_int(ir.t_i64, new_idx));
}

// narrowFunnelShift
ic_narrow_funnel_shift :: (trunc: Value_Id) -> Value_Id {
    dest_ty := vtype(trunc);
    narrow := scalar_bits(trunc);
    wide := scalar_bits(op(trunc, 0));
    if !ic_is_pow2(narrow) return NONE;
    o := op(trunc, 0);
    if !has_one_use(o) || !ic_is_binop(o, .OR) return NONE;
    or0 := op(o, 0); or1 := op(o, 1);
    if !is_inst(or0) || !is_binary_operator(or0) || !is_inst(or1) || !is_binary_operator(or1) return NONE;
    is_log_shift :: (v: Value_Id) -> bool { return has_one_use(v) && (inst_op(v) == .SHL || inst_op(v) == .LSHR); }
    if !is_log_shift(or0) || !is_log_shift(or1) || inst_op(or0) == inst_op(or1) return NONE;
    sh_val0 := op(or0, 0); sh_amt0 := op(or0, 1);
    sh_val1 := op(or1, 0); sh_amt1 := op(or1, 1);
    if inst_op(or0) == .LSHR {
        t0 := or0; or0 = or1; or1 = t0; t1 := sh_val0; sh_val0 = sh_val1; sh_val1 = t1; t2 := sh_amt0; sh_amt0 = sh_amt1; sh_amt1 = t2;
    }
    match_shift_amount :: (l: Value_Id, r: Value_Id, width: u32, sh_val0: Value_Id, sh_val1: Value_Id, wide: u32, narrow: u32, trunc: Value_Id) -> Value_Id {
        max_w := ic_log2_32(narrow);
        hi := ap_not(ap_low_bits_set(wide, max_w));
        if sh_val0 == sh_val1 || ic_masked_value_is_zero(l, hi, trunc) {
            ok, a, b := pm_binop(r, .SUB);
            if ok && has_one_use(r) && is_inst(r) && pm_specific_int(a, width) && b == l return l;
        }
        if sh_val0 != sh_val1 return NONE;
        mask := cast(u64) width - 1;
        ok1, x, m1 := pm_binop(l, .AND);
        if ok1 && pm_specific_int(m1, mask) {
            ok2, nx, m2 := pm_binop(r, .AND);
            if ok2 && pm_specific_int(m2, mask) { okn, y := pm_neg(nx); if okn && y == x return x; }
        }
        okz1, zl := pmi_cast(l, .ZEXT);
        okz2, zr := pmi_cast(r, .ZEXT);
        if okz1 && okz2 {
            ok3, x3, m3 := pm_binop(zl, .AND);
            if ok3 && pm_specific_int(m3, mask) {
                ok4, nx4, m4 := pm_binop(zr, .AND);
                if ok4 && pm_specific_int(m4, mask) { okn, y := pm_neg(nx4); if okn && y == x3 return x3; }
            }
        }
        return NONE;
    }
    sh_amt := match_shift_amount(sh_amt0, sh_amt1, narrow, sh_val0, sh_val1, wide, narrow, trunc);
    is_fshl := true;
    if sh_amt == NONE {
        sh_amt = match_shift_amount(sh_amt1, sh_amt0, narrow, sh_val0, sh_val1, wide, narrow, trunc);
        is_fshl = false;
    }
    if sh_amt == NONE return NONE;
    hi := ap_high_bits_set(wide, wide - narrow);
    if !ic_masked_value_is_zero(sh_val1, hi, trunc) return NONE;
    narrow_amt := icb_zext_or_trunc(sh_amt, dest_ty);
    x := icb_trunc(sh_val0, dest_ty);
    y := x;
    if sh_val0 != sh_val1 y = icb_trunc(sh_val1, dest_ty);
    return create_intrinsic_call(ifx is_fshl then IID_FSHL else IID_FSHR, .[dest_ty], .[x, y, narrow_amt]);
}

// narrowBinOp
ic_narrow_bin_op :: (trunc: Value_Id) -> Value_Id {
    src_ty := vtype(op(trunc, 0));
    dest_ty := vtype(trunc);
    src_width := type_bits(scalar_type(src_ty));
    dest_width := type_bits(scalar_type(dest_ty));
    if !is_vector_type(src_ty) && !ic_should_change_type(src_ty, dest_ty) return NONE;
    bo := op(trunc, 0);
    if !has_one_use(bo) || !is_inst(bo) || !is_binary_operator(bo) return NONE;
    b0 := op(bo, 0); b1 := op(bo, 1);
    opc := inst_op(bo);
    if opc == .AND || opc == .OR || opc == .XOR || opc == .ADD || opc == .SUB || opc == .MUL {
        if is_const(b0) {
            nc := ce_cast(.TRUNC, b0, dest_ty);
            tx := icb_trunc(b1, dest_ty);
            return create_binop(opc, nc, tx);
        }
        if is_const(b1) {
            nc := ce_cast(.TRUNC, b1, dest_ty);
            tx := icb_trunc(b0, dest_ty);
            return create_binop(opc, tx, nc);
        }
        ok, x := pm_zext_or_sext(b0);
        if ok && vtype(x) == dest_ty {
            n1 := icb_trunc(b1, dest_ty);
            return create_binop(opc, x, n1);
        }
        ok, x = pm_zext_or_sext(b1);
        if ok && vtype(x) == dest_ty {
            n0 := icb_trunc(b0, dest_ty);
            return create_binop(opc, n0, x);
        }
    } else if opc == .LSHR || opc == .ASHR {
        okt, a := pmi_cast(b0, .TRUNC);
        if okt && is_const(b1) {
            c := b1;
            max_sh := src_width - dest_width;
            if pm_specific_int_icmp(c, ICMP_ULE, ap_from_u64(src_width, max_sh)) {
                old := bo;
                ex := is_exact(old);
                sh_amt := cfo_integer_cast(c, vtype(a), true);
                if sh_amt != NONE {
                    sh_amt = ic_merge_undefs_with(sh_amt, c);
                    shift := ifx inst_op(old) == .ASHR then icb_ashr(a, sh_amt, vname(old), ex) else icb_lshr(a, sh_amt, vname(old), ex);
                    return create_trunc_or_bitcast(shift, dest_ty);
                }
            }
        }
    }
    r := ic_narrow_funnel_shift(trunc);
    if r != NONE return r;
    return NONE;
}
// CastInst::CreateTruncOrBitCast
create_trunc_or_bitcast :: (v: Value_Id, t: Type_Id) -> Value_Id {
    if scalar_bits(v) == type_bits(scalar_type(t)) return create_cast(.BITCAST, v, t);
    return create_cast(.TRUNC, v, t);
}

// ShuffleVectorInst::isSplatMask-ish m_SplatMask: all non-poison lanes equal (at least one)
// m_SplatMask: all_equal(Mask) (a poison element is -1, so it only matches an all-poison mask)
ic_is_splat_mask :: (m: [] u32) -> bool {
    for m if it != m[0] return false;
    return true;
}
// shrinkSplatShuffle
ic_shrink_splat_shuffle :: (trunc: Value_Id) -> Value_Id {
    shuf := op(trunc, 0);
    ok, sv, p, mask := pm_shuffle(shuf);
    if !ok || !has_one_use(shuf) || !pm_poison(p) || !ic_is_splat_mask(mask) return NONE;
    st := vtype(shuf); vt := vtype(sv);
    if (type_kind(st) == .SVECTOR) != (type_kind(vt) == .SVECTOR) || type_count(st) < type_count(vt) return NONE;
    nt := vector_with_elt(vt, scalar_type(vtype(trunc)));
    narrow := icb_trunc(sv, nt);
    return create_shuffle(narrow, NONE, mask);
}
// shrinkInsertElt
ic_shrink_insert_elt :: (trunc: Value_Id) -> Value_Id {
    opc := inst_op(trunc);
    src := op(trunc, 0);
    if has_one_use(src) && is_inst(src) && inst_op(src) == .INSERTELEMENT && pm_poison(op(src, 0)) {
        np := const_poison(vtype(trunc));
        nop := icb_cast(opc, op(src, 1), scalar_type(vtype(trunc)));
        return create_insert_element(np, nop, op(src, 2));
    }
    return NONE;
}

// m_SMax/m_SMin/m_UMax/m_UMin (MaxMin_match, not commutable): the intrinsic (args 0, 1) or the select form
// (true value, false value)
ic_pm_min_max_lr :: (v: Value_Id, id: Intrinsic_Id) -> (bool, Value_Id, Value_Id) {
    if call_iid(v) != NOT_INTRINSIC {
        if call_iid(v) == id return true, op(v, 0), op(v, 1);
        return false, NONE, NONE;
    }
    oks, cond, tv, fv := pm_select(v);
    if !oks || !is_inst(cond) || inst_op(cond) != .ICMP return false, NONE, NONE;
    l := op(cond, 0); r := op(cond, 1);
    if (tv != l || fv != r) && (tv != r || fv != l) return false, NONE, NONE;
    pred := ifx tv == l then inst_pred(cond) else swapped_predicate(inst_pred(cond));
    ok := false;
    if id == IID_SMAX ok = pred == ICMP_SGT || pred == ICMP_SGE;
    else if id == IID_SMIN ok = pred == ICMP_SLT || pred == ICMP_SLE;
    else if id == IID_UMAX ok = pred == ICMP_UGT || pred == ICMP_UGE;
    else if id == IID_UMIN ok = pred == ICMP_ULT || pred == ICMP_ULE;
    if !ok return false, NONE, NONE;
    return true, tv, fv;
}

// ---------------------------------------------------------------- visitTrunc

ic_visit_trunc :: (trunc: Value_Id) -> Value_Id {
    r := ic_common_cast_transforms(trunc); if r != NONE return r;
    src := op(trunc, 0);
    dest_ty := vtype(trunc); src_ty := vtype(src);
    dest_width := type_bits(scalar_type(dest_ty));
    src_width := type_bits(scalar_type(src_ty));

    if (is_vector_type(dest_ty) || ic_should_change_type(src_ty, dest_ty)) && ic_can_evaluate_truncated(src, dest_ty, trunc) {
        res := ic_evaluate_in_different_type(src, dest_ty, false);
        return ic_replace_inst_uses_with(trunc, res);
    }
    if is_int_type(dest_ty) && dest_width * 2 < src_width {
        new_dest := type_int(dest_width * 2);
        if ic_should_change_type(src_ty, new_dest) && ic_can_evaluate_truncated(src, new_dest, trunc) {
            res := ic_evaluate_in_different_type(src, new_dest, false);
            return create_cast(.TRUNC, res, dest_ty);
        }
    }
    if ic_simplify_demanded_instruction_bits(trunc) return trunc;

    if dest_width == 1 {
        zero := const_null_value(src_ty);
        // trunc ((C1 << X) >> C2) to i1 --> X == (C2-cttz(C1))
        if has_one_use(src) && is_inst(src) && is_shr_op(inst_op(src)) {
            sh := op(src, 0); c2 := op(src, 1);
            oks, c1v, x := pm_binop(sh, .SHL);
            if oks && is_inst(sh) && pm_imm_constant(c2) {
                okp, c1 := pm_power2_ap(c1v);
                if okp {
                    log2c1 := const_int_of(src_ty, cast(u64) ap_exact_log2(c1));
                    cmpc := ce_binop(.SUB, c2, log2c1, 0);
                    return create_icmp(ICMP_EQ, x, cmpc);
                }
            }
        }
        if is_inst(src) && is_shr_op(inst_op(src)) && pm_specific_int(op(src, 1), cast(u64) src_width - 1)
            return create_icmp(ICMP_SLT, op(src, 0), zero);
        if has_one_use(src) && ic_is_binop(src, .LSHR) && pm_imm_constant(op(src, 1)) {
            x := op(src, 0); c := op(src, 1);
            one := const_int_of(src_ty, 1);
            mask_c := icb_shl(one, c);
            and := icb_and(x, mask_c);
            return create_icmp(ICMP_NE, and, zero);
        }
        if has_one_use(src) && ic_is_binop(src, .OR) {
            for side: 0..1 {
                s := op(src, cast(u32) side);
                if !(ic_is_binop(s, .LSHR) && pm_imm_constant(op(s, 1))) continue;
                x := op(s, 0); c := op(s, 1);
                if op(src, cast(u32) (1 - side)) != x continue;
                one := const_int_of(src_ty, 1);
                mask_c := icb_shl(one, c);
                and := icb_and(x, icb_or(mask_c, one));
                return create_icmp(ICMP_NE, and, zero);
            }
        }
        {
            ok, cv, x := pm_binop(src, .SHL);
            if ok && is_inst(src) {
                okc, c := pm_apint(cv);
                if okc && ap_get_bit(c, 0) return create_icmp(ICMP_EQ, x, zero);
            }
        }
        if has_nuw(trunc) || has_nsw(trunc) {
            ok, x, y := pm_binop(src, .XOR);
            if ok && is_inst(src) return create_icmp(ICMP_NE, x, y);
        }
        if has_one_use(src) {
            ok, one, x := pm_intrinsic2(src, IID_USUB_SAT);
            if ok && pm_one(one) return create_icmp(ICMP_EQ, x, const_null_value(src_ty));
        }
    }

    // trunc(u/smin(zext(a) + zext(b), MAX)) --> uadd.sat(a, b)
    if has_one_use(src) {
        for id: Intrinsic_Id.[IID_UMIN, IID_SMIN] {
            ok, add, mx := ic_pm_min_max_lr(src, id);
            if !ok || !has_one_use(add) || !ic_is_binop(add, .ADD) continue;
            oka, a := pmi_cast(op(add, 0), .ZEXT);
            okb, b := pmi_cast(op(add, 1), .ZEXT);
            if !oka || !okb || !pm_specific_int_ap(mx, ap_all_ones(dest_width)) continue;
            if vtype(a) == dest_ty && vtype(b) == dest_ty
                return ic_replace_inst_uses_with(trunc, icb_binary_intrinsic(IID_UADD_SAT, a, b));
            break;
        }
    }
    // trunc(smax(zext(a) - zext(b), 0)) --> usub.sat(a, b)
    if has_one_use(src) {
        ok, sub, z := ic_pm_min_max_lr(src, IID_SMAX);
        if ok && has_one_use(sub) && ic_is_binop(sub, .SUB) && pm_zero(z) {
            oka, a := pmi_cast(op(sub, 0), .ZEXT);
            okb, b := pmi_cast(op(sub, 1), .ZEXT);
            if oka && okb && vtype(a) == dest_ty && vtype(b) == dest_ty
                return ic_replace_inst_uses_with(trunc, icb_binary_intrinsic(IID_USUB_SAT, a, b));
        }
    }
    {
        ok, se, c := pm_binop(src, .LSHR);
        if ok && is_inst(src) && is_const(c) {
            oks, a := pmi_cast(se, .SEXT);
            if oks {
                a_width := scalar_bits(a);
                max_sh := src_width - max(dest_width, a_width);
                ex := is_exact(src);
                if pm_specific_int_icmp(c, ICMP_ULE, ap_from_u64(src_width, max_sh)) {
                    get_new_sh_amt :: (width: u32, c: Value_Id, src_ty: Type_Id, a: Value_Id) -> Value_Id {
                        max_amt := const_int_of(src_ty, cast(u64) width - 1);
                        cmp := cfo_compare_inst_operands(ICMP_ULT, c, max_amt);
                        sh := cf_select(cmp, c, max_amt);
                        return cfo_cast_operand(.TRUNC, sh, vtype(a));
                    }
                    if vtype(a) == dest_ty {
                        sh_amt := get_new_sh_amt(dest_width, c, src_ty, a);
                        sh_amt = ic_merge_undefs_with(sh_amt, c);
                        return create_binop_flags(.ASHR, a, sh_amt, ifx ex then cast(u32) F_EXACT else 0);
                    }
                    if has_one_use(src) {
                        sh_amt := get_new_sh_amt(a_width, c, src_ty, a);
                        shift := icb_ashr(a, sh_amt, "", ex);
                        return create_integer_cast(shift, dest_ty, true);
                    }
                }
            }
        }
    }
    r = ic_narrow_bin_op(trunc); if r != NONE return r;
    r = ic_shrink_splat_shuffle(trunc); if r != NONE return r;
    r = ic_shrink_insert_elt(trunc); if r != NONE return r;

    if has_one_use(src) && (is_vector_type(src_ty) || ic_should_change_type(src_ty, dest_ty)) {
        ok, a, c := pm_binop(src, .SHL);
        if ok && is_inst(src) && is_const(c) {
            okr, ra, rc := pm_shr(a);
            if !(okr && is_const(rc)) {
                if pm_specific_int_icmp(c, ICMP_ULT, ap_from_u64(scalar_bits(c), dest_width)) {
                    nt := icb_trunc(a, dest_ty, tprint("%.tr", vname(a)));
                    return create_binop(.SHL, nt, ce_cast(.TRUNC, c, dest_ty));
                }
            }
        }
    }
    // trunc (select(icmp_ult(A, DestTy_umax+1), A, sext(icmp_sgt(A, 0)))) --> trunc (smin(smax(0, A), DestTy_umax))
    if is_int_type(src_ty) && ic_is_pow2(cast(u64) src_width) && ic_is_pow2(ic_prim_bits(dest_ty)) && has_one_use(src) {
        oks, cnd, tv, fv := pm_select(src);
        if oks && has_one_use(cnd) {
            okc, a, c := pm_specific_icmp(cnd, ICMP_ULT);
            if okc && is_const(c) && tv == a && has_one_use(fv) {
                okse, ic2 := pmi_cast(fv, .SEXT);
                if okse && has_one_use(ic2) {
                    okg, a2, z := pm_specific_icmp(ic2, ICMP_SGT);
                    if okg && a2 == a && pm_zero(z) {
                        okub, upper := ic_get_unique_integer(c);
                        if okub {
                            tmax := ap_zext(ap_all_ones(type_int_width(dest_ty)), upper.bits);
                            if !ap_is_zero(upper) && ap_eq(ap_sub_u64(upper, 1), tmax) {
                                smax := icb_intrinsic(IID_SMAX, .[src_ty], .[const_int_of(src_ty, 0), a]);
                                smin := icb_intrinsic(IID_SMIN, .[src_ty], .[smax, const_int_ap(src_ty, tmax)]);
                                return create_cast(.TRUNC, smin, dest_ty);
                            }
                        }
                    }
                }
            }
        }
    }
    r = ic_fold_vec_trunc_to_ext_elt(trunc); if r != NONE return r;
    r = ic_fold_vec_ext_trunc_to_ext_elt(trunc); if r != NONE return r;

    // trunc (ctlz_i32(zext(A), B) --> add(ctlz_i16(A, B), C)
    if has_one_use(src) {
        ok, za, b := pm_intrinsic2(src, IID_CTLZ);
        if ok {
            okz, a := pmi_cast(za, .ZEXT);
            if okz {
                a_width := scalar_bits(a);
                if a_width == dest_width && a_width > ic_log2_32(src_width) {
                    diff := const_int_of(vtype(a), cast(u64) (src_width - a_width));
                    nc := icb_intrinsic(IID_CTLZ, .[dest_ty], .[a, b]);
                    return create_binop(.ADD, nc, diff);
                }
            }
        }
    }
    if call_iid(src) == IID_VSCALE {
        okv, mx := ic_vscale_range_max(ic.f);
        if okv && ic_log2_32(mx) < dest_width return ic_replace_inst_uses_with(trunc, icb_vscale(dest_ty));
    }
    if dest_width >= 2 {
        id := call_iid(src);
        if (id == IID_SCMP || id == IID_UCMP) && has_one_use(src)
            return ic_replace_inst_uses_with(trunc, icb_intrinsic(id, .[dest_ty, vtype(call_arg(src, 0))], .[call_arg(src, 0), call_arg(src, 1)]));
    }
    if dest_width == 1 && (has_nuw(trunc) || has_nsw(trunc)) && is_known_non_zero(src, ic_q(trunc))
        return ic_replace_inst_uses_with(trunc, get_true(dest_ty));

    changed := false;
    if !has_nsw(trunc) && ic_max_significant_bits(src, trunc) <= dest_width { set_nsw(trunc); changed = true; }
    if !has_nuw(trunc) && ic_masked_value_is_zero(src, ap_bits_set_from(src_width, dest_width), trunc) { set_nuw(trunc); changed = true; }

    if dest_width == 1 && is_inst(src) && is_shr_op(inst_op(src)) {
        c1v := op(src, 0); v1 := op(src, 1);
        okp, c1 := pm_power2_ap(c1v);
        if okp return create_icmp(ICMP_EQ, v1, const_int_of(vtype(v1), cast(u64) ap_ctz(c1)));
        okl, cl := pm_low_bit_mask_ap(c1v);
        if okl return create_icmp(ICMP_ULT, v1, const_int_of(vtype(v1), cast(u64) ap_cto(cl)));
        okn, cn := pm_apint_pred(c1v, ap_is_negated_power_of_2);
        if okn return create_icmp(ICMP_UGE, v1, const_int_of(vtype(v1), cast(u64) ap_ctz(cn)));
    }
    if changed return trunc;
    return NONE;
}
// Constant::getUniqueInteger (ConstantInt or splat)
ic_get_unique_integer :: (c: Value_Id) -> (bool, APInt) {
    if vkind(c) == .C_INT return true, const_ap(c);
    s := get_splat_value(c);
    if s != NONE && vkind(s) == .C_INT return true, const_ap(s);
    no: APInt;
    return false, no;
}

// ---------------------------------------------------------------- zext

// transformZExtICmp
ic_transform_zext_icmp :: (cmp: Value_Id, zext: Value_Id) -> Value_Id {
    pred := inst_pred(cmp);
    ok1, op1cv := pm_apint(op(cmp, 1));
    if ok1 {
        if pred == ICMP_SLT && ap_is_zero(op1cv) {
            in := op(cmp, 0);
            sh := const_int_of(vtype(in), cast(u64) scalar_bits(in) - 1);
            in = icb_lshr(in, sh, tprint("%.lobit", vname(in)));
            if vtype(in) != vtype(zext) in = icb_int_cast(in, vtype(zext), false);
            return ic_replace_inst_uses_with(zext, in);
        }
        if ap_is_zero(op1cv) && icmp_is_equality(pred) {
            known := ic_known_bits(op(cmp, 0), zext);
            kzm := ap_not(known.zero);
            sh_amt := ap_log2(kzm);
            expect := ap_is_power_of_2(kzm) && scalar_bits(zext) != sh_amt + 1;
            if expect && (vtype(op(cmp, 0)) == vtype(zext) || pred == ICMP_NE || sh_amt == 0) {
                in := op(cmp, 0);
                if sh_amt != 0 in = icb_lshr(in, const_int_of(vtype(in), cast(u64) sh_amt), tprint("%.lobit", vname(in)));
                if pred == ICMP_EQ in = icb_xor(in, const_int_of(vtype(in), 1));
                if vtype(zext) == vtype(in) return ic_replace_inst_uses_with(zext, in);
                c := icb_int_cast(in, vtype(zext), false);
                return ic_replace_inst_uses_with(zext, c);
            }
        }
    }
    if icmp_is_equality(pred) {
        and := op(cmp, 0);
        if has_one_use(cmp) && pm_zero_int(op(cmp, 1)) && has_one_use(and) && ic_is_binop(and, .AND) {
            x: Value_Id = NONE; sh_amt: Value_Id = NONE;
            for side: 0..1 {
                s := op(and, cast(u32) side);
                ok, one, amt := pm_binop(s, .SHL);
                if ok && is_inst(s) && pm_one(one) { sh_amt = amt; x = op(and, cast(u32) (1 - side)); break; }
            }
            if x != NONE {
                shift := op(and, ifx x == op(and, 0) then cast(u32) 1 else 0);
                if vtype(zext) == vtype(and) || pred != ICMP_EQ || has_one_use(shift) {
                    if pred == ICMP_EQ x = icb_not(x);
                    lshr := icb_lshr(x, sh_amt);
                    and1 := icb_and(lshr, const_int_of(vtype(x), 1));
                    return ic_replace_inst_uses_with(zext, icb_zext_or_trunc(and1, vtype(zext)));
                }
            }
        }
    }
    return NONE;
}

// canEvaluateZExtd
ic_can_evaluate_zextd :: (v: Value_Id, ty: Type_Id, bits_to_clear: *u32, cxt: Value_Id) -> bool {
    bits_to_clear.* = 0;
    if teh_can_always_evaluate_in_type(v, ty) return true;
    if teh_can_not_evaluate_in_type(v, ty) return false;
    i := v;
    tmp: u32;
    if inst_op(i) == {
        case .ZEXT; #through; case .SEXT; #through; case .TRUNC; return true;
        case .AND; #through; case .OR; #through; case .XOR; #through; case .ADD; #through; case .SUB; #through; case .MUL;
            if !ic_can_evaluate_zextd(op(i, 0), ty, bits_to_clear, cxt) || !ic_can_evaluate_zextd(op(i, 1), ty, *tmp, cxt) return false;
            if bits_to_clear.* == 0 && tmp == 0 return true;
            if tmp == 0 && is_bitwise_logic_op(inst_op(i)) {
                vsize := scalar_bits(v);
                if ic_masked_value_is_zero(op(i, 1), ap_high_bits_set(vsize, bits_to_clear.*), cxt) {
                    if inst_op(i) == .AND bits_to_clear.* = 0;
                    return true;
                }
            }
            return false;
        case .SHL;
            ok, amt := pm_constant_int_u64(op(i, 1));
            if ok {
                if !ic_can_evaluate_zextd(op(i, 0), ty, bits_to_clear, cxt) return false;
                bits_to_clear.* = ifx amt < cast(u64) bits_to_clear.* then bits_to_clear.* - cast(u32) amt else 0;
                return true;
            }
            return false;
        case .LSHR;
            ok, amt := pm_constant_int_u64(op(i, 1));
            if ok {
                if !ic_can_evaluate_zextd(op(i, 0), ty, bits_to_clear, cxt) return false;
                nb := cast(u64) bits_to_clear.* + amt;
                if nb > cast(u64) scalar_bits(v) nb = cast(u64) scalar_bits(v);
                bits_to_clear.* = cast(u32) nb;
                return true;
            }
            return false;
        case .SELECT;
            if !ic_can_evaluate_zextd(op(i, 1), ty, *tmp, cxt) || !ic_can_evaluate_zextd(op(i, 2), ty, bits_to_clear, cxt) || tmp != bits_to_clear.* return false;
            return true;
        case .PHI;
            if !ic_can_evaluate_zextd(phi_value(i, 0), ty, bits_to_clear, cxt) return false;
            n := phi_num_incoming(i);
            for k: 1..cast(s64) n - 1
                if !ic_can_evaluate_zextd(phi_value(i, cast(u32) k), ty, *tmp, cxt) || tmp != bits_to_clear.* return false;
            return true;
        case .CALL;
            return call_iid(i) == IID_VSCALE;
    }
    return false;
}

ic_visit_zext :: (zext: Value_Id) -> Value_Id {
    if has_one_use(zext) && is_inst(first_user(zext)) && inst_op(first_user(zext)) == .TRUNC && !is_const(op(zext, 0)) return NONE;
    r := ic_common_cast_transforms(zext); if r != NONE return r;
    r = ic_fold_extraction_of_vector_deinterleave_hook(zext); if r != NONE return r;
    src := op(zext, 0);
    src_ty := vtype(src); dest_ty := vtype(zext);
    if is_int_or_int_vector_n(src_ty, 1) && (inst(zext).flags & F_EXACT) != 0 return ic_replace_inst_uses_with(zext, const_null_value(dest_ty));

    bits_to_clear: u32;
    if ic_should_change_type(src_ty, dest_ty) &&
       ic_can_evaluate_zextd(src, dest_ty, *bits_to_clear, zext) {
        res := ic_evaluate_in_different_type(src, dest_ty, false);
        if is_inst(src) && has_one_use(src) ic_replace_all_dbg_uses_with(src, res, zext);
        src_bits_kept := type_bits(scalar_type(src_ty)) - bits_to_clear;
        dest_bit_size := type_bits(scalar_type(dest_ty));
        if ic_masked_value_is_zero(res, ap_high_bits_set(dest_bit_size, dest_bit_size - src_bits_kept), zext)
            return ic_replace_inst_uses_with(zext, res);
        c := const_int_ap(vtype(res), ap_low_bits_set(dest_bit_size, src_bits_kept));
        return create_binop(.AND, res, c);
    }
    if is_inst(src) && inst_op(src) == .TRUNC {
        csrc := src;
        a := op(csrc, 0);
        src_size := scalar_bits(a); mid_size := scalar_bits(csrc); dst_size := type_bits(scalar_type(dest_ty));
        if src_size < dst_size {
            and_const := const_int_ap(vtype(a), ap_low_bits_set(src_size, mid_size));
            and := icb_and(a, and_const, tprint("%.mask", vname(csrc)));
            return create_cast(.ZEXT, and, dest_ty);
        }
        if src_size == dst_size return create_binop(.AND, a, const_int_ap(vtype(a), ap_low_bits_set(src_size, mid_size)));
        if src_size > dst_size {
            t := icb_trunc(a, dest_ty);
            return create_binop(.AND, t, const_int_ap(vtype(t), ap_low_bits_set(dst_size, mid_size)));
        }
    }
    if is_inst(src) && inst_op(src) == .ICMP return ic_transform_zext_icmp(src, zext);

    // zext((trunc(X) & C) ^ C) -> ((X & zext(C)) ^ zext(C))
    if has_one_use(src) && ic_is_binop(src, .XOR) && is_const(op(src, 1)) {
        and := op(src, 0); c := op(src, 1);
        if has_one_use(and) && ic_is_binop(and, .AND) && op(and, 1) == c {
            okt, x := pmi_cast(op(and, 0), .TRUNC);
            if okt && vtype(x) == dest_ty {
                zc := icb_zext(c, dest_ty);
                return create_binop(.XOR, icb_and(x, zc), zc);
            }
        }
    }
    // zext(sub(0, trunc(X))) -> and(sub(0, X), mask)
    if ic_is_binop(src, .SUB) && pm_zero(op(src, 0)) {
        okt, x := pmi_cast(op(src, 1), .TRUNC);
        if okt && vtype(x) == dest_ty {
            mask := ap_low_bits_set(type_bits(scalar_type(dest_ty)), type_bits(scalar_type(src_ty)));
            neg := icb_sub(const_int_of(dest_ty, 0), x);
            return create_binop(.AND, neg, const_int_ap(dest_ty, mask));
        }
    }
    // zext (and (trunc X), C) --> and X, (zext C)
    if ic_is_binop(src, .AND) && is_const(op(src, 1)) {
        okt, x := pmi_cast(op(src, 0), .TRUNC);
        if okt && vtype(x) == dest_ty {
            zc := icb_zext(op(src, 1), dest_ty);
            return create_binop(.AND, x, zc);
        }
    }
    if has_one_use(src) && is_inst(src) && is_bitwise_logic_op(inst_op(src)) {
        for side: 0..1 {
            t := op(src, cast(u32) side);
            okt, x := pmi_cast(t, .TRUNC);
            if !okt || !has_nuw(t) continue;
            if vtype(x) != dest_ty break;
            y := op(src, cast(u32) (1 - side));
            zy := icb_zext(y, dest_ty);
            return create_binop(inst_op(src), x, zy);
        }
    }
    if call_iid(src) == IID_VSCALE {
        okv, mx := ic_vscale_range_max(ic.f);
        if okv && ic_log2_32(mx) < scalar_bits(src) return ic_replace_inst_uses_with(zext, icb_vscale(dest_ty));
    }
    if (inst(zext).flags & F_EXACT) == 0 {
        if has_one_use(zext) && cast(u64) type_bits(scalar_type(src_ty)) > log2_ceil_u64(cast(u64) type_bits(scalar_type(dest_ty))) {
            us := first_user(zext);
            if is_inst(us) && is_shift_op(inst_op(us)) && op(us, 1) == zext { set_flag(zext, F_EXACT, true); return zext; }
        }
        if is_known_non_negative(src, ic_q(zext)) { set_flag(zext, F_EXACT, true); return zext; }
    }
    return NONE;
}
log2_ceil_u64 :: (x: u64) -> u64 { if x <= 1 return 0; n: u64 = 0; v := x - 1; while v { n += 1; v >>= 1; } return n; }
// foldExtractionOfVectorDeinterleave (InstCombineVectorOps.cpp) is not ported here: fail loudly where it could apply
ic_fold_extraction_of_vector_deinterleave_hook :: (i: Value_Id) -> Value_Id { return ic_fold_extraction_of_vector_deinterleave(i); }

// ---------------------------------------------------------------- sext

// transformSExtICmp
ic_transform_sext_icmp :: (cmp: Value_Id, sext: Value_Id) -> Value_Id {
    op0 := op(cmp, 0); op1 := op(cmp, 1);
    pred := inst_pred(cmp);
    if !is_int_or_int_vector(vtype(op1)) return NONE;
    if pred == ICMP_SLT && pm_zero_int(op1) {
        sh := const_int_of(vtype(op0), cast(u64) scalar_bits(op0) - 1);
        in := icb_ashr(op0, sh, tprint("%.lobit", vname(op0)));
        if vtype(in) != vtype(sext) in = icb_int_cast(in, vtype(sext), true);
        return ic_replace_inst_uses_with(sext, in);
    }
    if vkind(op1) == .C_INT {
        c := const_ap(op1);
        if has_one_use(cmp) && icmp_is_equality(pred) && (ap_is_zero(c) || ap_is_power_of_2(c)) {
            known := ic_known_bits(op0, sext);
            kzm := ap_not(known.zero);
            if ap_is_power_of_2(kzm) {
                in := op0;
                if !ap_is_zero(c) && !ap_eq(c, kzm) {
                    v := ifx pred == ICMP_NE then const_all_ones_of(vtype(sext)) else const_null_value(vtype(sext));
                    return ic_replace_inst_uses_with(sext, v);
                }
                if (!ap_is_zero(c)) == (pred == ICMP_NE) {
                    sh := ap_ctz(kzm);
                    if sh != 0 in = icb_lshr(in, const_int_of(vtype(in), cast(u64) sh));
                    in = icb_add(in, const_all_ones_of(vtype(in)), "sext");
                } else {
                    sh := ap_clz(kzm);
                    if sh != 0 in = icb_shl(in, const_int_of(vtype(in), cast(u64) sh));
                    in = icb_ashr(in, const_int_of(vtype(in), cast(u64) kzm.bits - 1), "sext");
                }
                if vtype(sext) == vtype(in) return ic_replace_inst_uses_with(sext, in);
                return create_integer_cast(in, vtype(sext), true);
            }
        }
    }
    return NONE;
}

// canEvaluateSExtd
ic_can_evaluate_sextd :: (v: Value_Id, ty: Type_Id) -> bool {
    h: Type_Eval_Helper; teh_init(*h);
    return teh_can_evaluate(*h, v, ty, .SEXT, NONE) && teh_all_pending_visited(*h);
}
teh_can_evaluate_sextd_pred :: (h: *Type_Eval_Helper, v: Value_Id, ty: Type_Id) -> bool {
    i := v;
    if inst_op(i) == {
        case .SEXT; #through; case .ZEXT; #through; case .TRUNC; return true;
        case .AND; #through; case .OR; #through; case .XOR; #through; case .ADD; #through; case .SUB; #through; case .MUL;
            return teh_can_evaluate(h, op(i, 0), ty, .SEXT, NONE) && teh_can_evaluate(h, op(i, 1), ty, .SEXT, NONE);
        case .SELECT;
            return teh_can_evaluate(h, op(i, 1), ty, .SEXT, NONE) && teh_can_evaluate(h, op(i, 2), ty, .SEXT, NONE);
        case .PHI;
            n := phi_num_incoming(i);
            for k: 0..cast(s64) n - 1 if !teh_can_evaluate(h, phi_value(i, cast(u32) k), ty, .SEXT, NONE) return false;
            return true;
    }
    return false;
}

ic_visit_sext :: (sext: Value_Id) -> Value_Id {
    if has_one_use(sext) && is_inst(first_user(sext)) && inst_op(first_user(sext)) == .TRUNC return NONE;
    r := ic_common_cast_transforms(sext); if r != NONE return r;
    src := op(sext, 0);
    src_ty := vtype(src); dest_ty := vtype(sext);
    src_bit_size := type_bits(scalar_type(src_ty)); dest_bit_size := type_bits(scalar_type(dest_ty));
    if is_known_non_negative(src, ic_q(sext)) return create_cast_flags(.ZEXT, src, dest_ty, F_EXACT);

    should_extend := true;
    okt, trunc_src := pmi_cast(src, .TRUNC);
    if !okt trunc_src = NONE;
    if trunc_src != NONE && scalar_bits(trunc_src) > dest_bit_size should_extend = false;
    if should_extend && ic_should_change_type(src_ty, dest_ty) && ic_can_evaluate_sextd(src, dest_ty) {
        res := ic_evaluate_in_different_type(src, dest_ty, true);
        if ic_num_sign_bits(res, sext) > dest_bit_size - src_bit_size return ic_replace_inst_uses_with(sext, res);
        sh := const_int_of(dest_ty, cast(u64) (dest_bit_size - src_bit_size));
        return create_binop(.ASHR, icb_shl(res, sh, "sext"), sh);
    }
    x := trunc_src;
    if x != NONE {
        xbits := scalar_bits(x);
        has_nsw_t := has_nsw(src);
        if has_nsw_t || ic_num_sign_bits(x, sext) > xbits - src_bit_size {
            res := create_integer_cast(x, dest_ty, true);
            if inst_op(res) == .TRUNC && has_nsw_t set_nsw(res);
            return res;
        }
        if has_one_use(src) && vtype(x) == dest_ty {
            sh := const_int_of(dest_ty, cast(u64) (dest_bit_size - src_bit_size));
            return create_binop(.ASHR, icb_shl(x, sh), sh);
        }
        if has_one_use(src) {
            ok, y, amt := pm_binop(x, .LSHR);
            if ok && is_inst(x) && pm_specific_int_allow_poison(amt, cast(u64) (xbits - src_bit_size)) {
                ashr := icb_ashr(y, const_int_of(vtype(y), cast(u64) (xbits - src_bit_size)));
                return create_integer_cast(ashr, dest_ty, true);
            }
        }
    }
    if is_inst(src) && inst_op(src) == .ICMP return ic_transform_sext_icmp(src, sext);

    {
        ok, shl, ca := pm_binop(src, .ASHR);
        if ok && is_inst(src) && pm_imm_constant(ca) {
            ok2, tr, ba := pm_binop(shl, .SHL);
            if ok2 && is_inst(shl) && is_const(ba) {
                ok3, a := pmi_cast(tr, .TRUNC);
                if ok3 && const_is_element_wise_equal(ba, ca) && vtype(a) == dest_ty {
                    wide := cfo_cast_operand(.SEXT, ca, dest_ty);
                    left := ce_binop(.SUB, const_int_of(dest_ty, cast(u64) type_bits(scalar_type(src_ty))), wide, 0);
                    nsh := ce_binop(.SUB, const_int_of(dest_ty, cast(u64) dest_bit_size), left, 0);
                    nsh = ic_merge_undefs_with(ic_merge_undefs_with(nsh, ba), ca);
                    a2 := icb_shl(a, nsh, vname(sext));
                    return create_binop(.ASHR, a2, nsh);
                }
            }
        }
    }
    if has_one_use(src) && ic_is_binop(src, .ASHR) && pm_specific_int(op(src, 1), cast(u64) src_bit_size - 1) {
        okt2, x2 := pmi_cast(op(src, 0), .TRUNC);
        if okt2 {
            xty := vtype(x2);
            xbits := scalar_bits(x2);
            shl_amt := const_int_of(xty, cast(u64) (xbits - src_bit_size));
            ashr_amt := const_int_of(xty, cast(u64) xbits - 1);
            if xty == dest_ty return create_binop(.ASHR, icb_shl(x2, shl_amt), ashr_amt);
            if has_one_use(op(src, 0)) {
                ashr := icb_ashr(icb_shl(x2, shl_amt), ashr_amt);
                return create_integer_cast(ashr, dest_ty, true);
            }
        }
    }
    if call_iid(src) == IID_VSCALE {
        okv, mx := ic_vscale_range_max(ic.f);
        if okv && ic_log2_32(mx) < src_bit_size - 1 return ic_replace_inst_uses_with(sext, icb_vscale(dest_ty));
    }
    {
        id := call_iid(src);
        if (id == IID_SCMP || id == IID_UCMP) && has_one_use(src)
            return ic_replace_inst_uses_with(sext, icb_intrinsic(id, .[dest_ty, vtype(call_arg(src, 0))], .[call_arg(src, 0), call_arg(src, 1)]));
    }
    if has_one_use(src) && is_inst(src) && is_bitwise_logic_op(inst_op(src)) {
        for side: 0..1 {
            t := op(src, cast(u32) side);
            okt3, x3 := pmi_cast(t, .TRUNC);
            if !okt3 || !has_nsw(t) continue;
            if vtype(x3) != dest_ty break;
            y := op(src, cast(u32) (1 - side));
            sy := icb_sext(y, dest_ty);
            return create_binop(inst_op(src), x3, sy);
        }
    }
    return NONE;
}

// ---------------------------------------------------------------- FP casts

// fitsInFPType
ic_fits_in_fp_type :: (f: APFloat, to: Type_Kind) -> bool {
    g := f;
    w, exact := fp_convert(g.k, to, apf_words(*g));
    return exact;
}
// shrinkFPConstant(Ctx, F, PreferBFloat)
ic_shrink_fp_constant_apf :: (f: APFloat, prefer_bfloat: bool) -> Type_Id {
    if prefer_bfloat && ic_fits_in_fp_type(f, .BFLOAT) return type_simple(.BFLOAT);
    if !prefer_bfloat && ic_fits_in_fp_type(f, .HALF) return type_simple(.HALF);
    if ic_fits_in_fp_type(f, .FLOAT) return type_simple(.FLOAT);
    if f.k == .DOUBLE return NONE;
    if ic_fits_in_fp_type(f, .DOUBLE) return type_simple(.DOUBLE);
    return NONE;
}
// shrinkFPConstant(CFP, PreferBFloat)
ic_shrink_fp_constant :: (cfp: Value_Id, prefer_bfloat: bool) -> Type_Id {
    t := vtype(cfp);
    if type_kind(scalar_type(t)) == .PPC_FP128 return NONE;
    st := ic_shrink_fp_constant_apf(apf_from_const(cfp), prefer_bfloat);
    if st != NONE && is_vector_type(t) st = vector_with_elt(t, st);
    return st;
}
// shrinkFPConstantVector
ic_shrink_fp_constant_vector :: (v: Value_Id, prefer_bfloat: bool) -> Type_Id {
    if !is_const(v) || type_kind(vtype(v)) != .VECTOR return NONE;
    min_type: Type_Id = NONE;
    n := type_count(vtype(v));
    for k: 0..cast(s64) n - 1 {
        e := cf_elt(v, cast(u64) k);
        if pm_poison(e) continue;
        if e == NONE || vkind(e) != .C_FP return NONE;
        t := ic_shrink_fp_constant(e, prefer_bfloat);
        if t == NONE return NONE;
        if min_type == NONE || ic_fp_mantissa_width(t) > ic_fp_mantissa_width(min_type) min_type = t;
    }
    if min_type == NONE return NONE;
    return type_vector(n, min_type, false);
}
// getMinimumFPType
ic_get_minimum_fp_type :: (v: Value_Id, preferred: Type_Id) -> Type_Id {
    if is_inst(v) && inst_op(v) == .FPEXT return vtype(op(v, 0));
    if is_inst(v) && (inst_op(v) == .UITOFP || inst_op(v) == .SITOFP) &&
       ic_can_be_casted_exactly_int_to_fp(op(v, 0), preferred, inst_op(v) == .SITOFP, v) return preferred;
    prefer_bfloat := type_kind(scalar_type(preferred)) == .BFLOAT;
    if vkind(v) == .C_FP && !is_vector_type(vtype(v)) {
        t := ic_shrink_fp_constant(v, prefer_bfloat);
        if t != NONE return t;
    }
    if is_const(v) && is_vector_type(vtype(v)) {
        s := get_splat_value(v);
        if s != NONE && vkind(s) == .C_FP {
            t := ic_shrink_fp_constant(s, prefer_bfloat);
            if t != NONE return vector_with_elt(vtype(v), t);
        }
    }
    t := ic_shrink_fp_constant_vector(v, prefer_bfloat);
    if t != NONE return t;
    return vtype(v);
}

// canBeCastedExactlyIntToFP
ic_can_be_casted_exactly_int_to_fp :: (v: Value_Id, fp_ty: Type_Id, is_signed: bool, cxt: Value_Id) -> bool {
    src_size := cast(s64) scalar_bits(v) - (ifx is_signed then 1 else 0);
    dest_sig := ic_fp_mantissa_width(fp_ty);
    if src_size <= dest_sig return true;
    if opr_code(v) == .FPTOSI || opr_code(v) == .FPTOUI {
        src_sig := ic_fp_mantissa_width(vtype(op(v, 0)));
        if !is_signed && opr_code(v) == .FPTOSI src_sig += 1;
        if src_sig > 0 && dest_sig > 0 && src_sig <= dest_sig return true;
    }
    k := ic_known_bits(v, cxt);
    sig := cast(s64) scalar_bits(v) - cast(s64) kb_count_min_leading_zeros(k) - cast(s64) kb_count_min_trailing_zeros(k);
    if sig <= dest_sig return true;
    if is_signed {
        sig = cast(s64) scalar_bits(v) - cast(s64) ic_num_sign_bits(v, cxt);
        if sig <= dest_sig return true;
    }
    return false;
}
// isKnownExactCastIntToFP
ic_is_known_exact_cast_int_to_fp :: (i: Value_Id) -> bool {
    return ic_can_be_casted_exactly_int_to_fp(op(i, 0), vtype(i), inst_op(i) == .SITOFP, i);
}

ic_visit_fptrunc :: (fpt: Value_Id) -> Value_Id {
    r := ic_common_cast_transforms(fpt); if r != NONE return r;
    ty := vtype(fpt);
    bo := op(fpt, 0);
    if is_inst(bo) && is_binary_operator(bo) && has_one_use(bo) {
        lmin := ic_get_minimum_fp_type(op(bo, 0), ty);
        rmin := ic_get_minimum_fp_type(op(bo, 1), ty);
        op_width := ic_fp_mantissa_width(vtype(bo));
        lw := ic_fp_mantissa_width(lmin);
        rw := ic_fp_mantissa_width(rmin);
        src_width := max(lw, rw);
        dst_width := ic_fp_mantissa_width(ty);
        nfmf := get_fmf(bo);
        if (nfmf & FMF_NINF) != 0 && (get_fmf(fpt) & FMF_NINF) == 0 nfmf &= ~cast(u32) FMF_NINF;
        // the widths are unsigned in LLVM: -1 (ppc_fp128) compares as huge
        uw :: (x: s64) -> u64 { return cast,no_check(u64) cast(u32) x; }
        if inst_op(bo) == {
            case .FADD; #through; case .FSUB;
                if uw(op_width) >= 2 * uw(dst_width) + 1 && uw(dst_width) >= uw(src_width) {
                    l := icb_cast(.FPTRUNC, op(bo, 0), ty);
                    rr := icb_cast(.FPTRUNC, op(bo, 1), ty);
                    ri := create_binop(inst_op(bo), l, rr);
                    set_fmf(ri, nfmf);
                    return ri;
                }
            case .FMUL;
                if uw(op_width) >= uw(lw) + uw(rw) && uw(dst_width) >= uw(src_width) {
                    l := icb_cast(.FPTRUNC, op(bo, 0), ty);
                    rr := icb_cast(.FPTRUNC, op(bo, 1), ty);
                    return create_binop_fmf(.FMUL, l, rr, nfmf);
                }
            case .FDIV;
                if uw(op_width) >= 2 * uw(dst_width) && uw(dst_width) >= uw(src_width) {
                    l := icb_cast(.FPTRUNC, op(bo, 0), ty);
                    rr := icb_cast(.FPTRUNC, op(bo, 1), ty);
                    return create_binop_fmf(.FDIV, l, rr, nfmf);
                }
            case .FREM;
                if src_width != op_width {
                    l, rr: Value_Id;
                    if lw == src_width { l = icb_cast(.FPTRUNC, op(bo, 0), lmin); rr = icb_cast(.FPTRUNC, op(bo, 1), lmin); }
                    else { l = icb_cast(.FPTRUNC, op(bo, 0), rmin); rr = icb_cast(.FPTRUNC, op(bo, 1), rmin); }
                    exact := icb_binop_fmf(.FREM, l, rr, get_fmf(bo));
                    return create_fp_cast(exact, ty);
                }
        }
    }
    o := op(fpt, 0);
    if is_inst(o) && has_one_use(o) {
        fmf := get_fmf(fpt);
        if is_fp_math_inst(o) fmf &= get_fmf(o);
        okn, x := pm_fneg(o);
        if okn {
            inner := icb_cast_fmf(.FPTRUNC, x, ty, fmf);
            neg := icb_fneg_fmf(inner, fmf);
            return ic_replace_inst_uses_with(fpt, neg);
        }
        oks, cnd, tv, fv := pm_select(o);
        if oks {
            okx, x1 := pmi_cast(tv, .FPEXT);
            if okx && vtype(x1) == ty {
                ny := icb_cast_fmf(.FPTRUNC, fv, ty, fmf);
                sel := icb_select_fmf(cnd, x1, ny, fmf, "narrow.sel", o);
                return ic_replace_inst_uses_with(fpt, sel);
            }
            okx2, x2 := pmi_cast(fv, .FPEXT);
            if okx2 && vtype(x2) == ty {
                ny := icb_cast_fmf(.FPTRUNC, tv, ty, fmf);
                sel := icb_select_fmf(cnd, ny, x2, fmf, "narrow.sel", o);
                return ic_replace_inst_uses_with(fpt, sel);
            }
        }
    }
    id := call_iid(o);
    if id == IID_CEIL || id == IID_FABS || id == IID_FLOOR || id == IID_NEARBYINT || id == IID_RINT ||
       id == IID_ROUND || id == IID_ROUNDEVEN || id == IID_TRUNC {
        src := call_arg(o, 0);
        if has_one_use(src) {
            ok := true;
            if id != IID_FABS {
                if !(is_inst(src) && inst_op(src) == .FPEXT && vtype(op(src, 0)) == ty) ok = false;
            }
            if ok {
                if call_num_bundles(o) > 0 fatal("instcombine: visitFPTrunc of an intrinsic with operand bundles is not supported yet");
                inner := icb_cast(.FPTRUNC, src, ty);
                nci := create_intrinsic_call(id, .[ty], .[inner]);
                set_fmf(nci, get_fmf(fpt));
                return nci;
            }
        }
    }
    r = ic_shrink_insert_elt(fpt); if r != NONE return r;
    src := op(fpt, 0);
    if is_inst(src) && (inst_op(src) == .SITOFP || inst_op(src) == .UITOFP) {
        if ic_is_known_exact_cast_int_to_fp(src) return create_cast(inst_op(src), op(src, 0), ty);
    }
    return NONE;
}
// CreateFNegFMF(V, FMF)
icb_fneg_fmf :: (v: Value_Id, fmf: u32, name: string = "") -> Value_Id {
    if is_const(v) { f := cfo_unary_op_operand(.FNEG, v); if f != NONE return f; }
    i := new_inst(.FNEG, vtype(v), 1);
    set_op(i, 0, v);
    set_fmf(i, fmf);
    return icb_insert(i, name);
}

ic_visit_fpext :: (fpext: Value_Id) -> Value_Id {
    ty := vtype(fpext);
    src := op(fpext, 0);
    if is_inst(src) && (inst_op(src) == .SITOFP || inst_op(src) == .UITOFP) {
        if ic_is_known_exact_cast_int_to_fp(src) return create_cast(inst_op(src), op(src, 0), ty);
    }
    return ic_common_cast_transforms(fpext);
}

// foldItoFPtoI (FI is fptoui/fptosi, or the fptoui.sat/fptosi.sat intrinsics with is_saturating)
ic_fold_itofp_to_i :: (fi: Value_Id, is_saturating := false) -> Value_Id {
    opi := op(fi, 0);
    if !is_inst(opi) || (inst_op(opi) != .UITOFP && inst_op(opi) != .SITOFP) return NONE;
    x := op(opi, 0);
    xty := vtype(x);
    dest_ty := vtype(fi);
    is_input_signed := inst_op(opi) == .SITOFP;
    is_output_signed := ifx is_saturating then call_iid(fi) == IID_FPTOSI_SAT else inst_op(fi) == .FPTOSI;
    if !ic_is_known_exact_cast_int_to_fp(opi) {
        if !is_saturating {
            output_size := cast(s64) type_bits(scalar_type(dest_ty));
            if output_size > ic_fp_mantissa_width(vtype(opi)) return NONE;
        } else return NONE;
    }
    src_width := type_bits(scalar_type(xty));
    dest_width := type_bits(scalar_type(dest_ty));
    if is_saturating {
        if is_input_signed != is_output_signed || dest_width < src_width return NONE;
    }
    if dest_width > src_width {
        if is_input_signed && is_output_signed return create_cast(.SEXT, x, dest_ty);
        return create_cast(.ZEXT, x, dest_ty);
    }
    if dest_width < src_width return create_cast(.TRUNC, x, dest_ty);
    return ic_replace_inst_uses_with(fi, x);
}

// foldFPtoI
ic_fold_fp_to_i :: (fi: Value_Id) -> Value_Id {
    mask: u32 = ifx inst_op(fi) == .FPTOUI then cast(u32) FC_POS_NORMAL else FC_NORMAL;
    cls := compute_known_fp_class(op(fi, 0), mask, ic_q(fi));
    if kfpc_is_known_never(cls, mask) return ic_replace_inst_uses_with(fi, const_null_value(vtype(fi)));
    is_signed := inst_op(fi) == .FPTOSI;
    fd := op(fi, 0);
    if !has_one_use(fd) || !ic_is_binop(fd, .FDIV) return NONE;
    okc, x := pmi_cast(op(fd, 0), ifx is_signed then Opcode.SITOFP else .UITOFP);
    if !okc return NONE;
    oka, apf := pm_apfloat(op(fd, 1));
    if !oka return NONE;
    int_ty := vtype(x);
    if vtype(fi) != int_ty return NONE;
    int_width := type_bits(scalar_type(int_ty));
    prec, mx, mn, bits := fp_semantics(apf.k);
    if cast(s64) prec + (ifx is_signed then 1 else 0) < cast(s64) int_width return NONE;
    g := apf;
    rounded, st := fp_round_to_integral(g.k, apf_words(*g), RM_TOWARD_ZERO);
    if !apf_is_finite(apf) return NONE;
    h := apf;
    for apf_words(*h) if it != rounded[it_index] return NONE;   // isInteger
    w, st2, exact := fp_to_integer_rm(g.k, apf_words(*g), int_width, is_signed, RM_TOWARD_ZERO);
    if !exact return NONE;
    divisor := ap_from_words(int_width, w);
    if ap_is_zero(divisor) return NONE;
    if is_signed && ap_is_all_ones(divisor) return NONE;
    c := const_int_ap(int_ty, divisor);
    return create_binop(ifx is_signed then Opcode.SDIV else .UDIV, x, c);
}

ic_visit_fptoui :: (fi: Value_Id) -> Value_Id {
    r := ic_fold_itofp_to_i(fi); if r != NONE return r;
    r = ic_fold_fp_to_i(fi); if r != NONE return r;
    return ic_common_cast_transforms(fi);
}
ic_visit_fptosi :: (fi: Value_Id) -> Value_Id { return ic_visit_fptoui(fi); }

ic_visit_uitofp :: (ci: Value_Id) -> Value_Id {
    r := ic_common_cast_transforms(ci); if r != NONE return r;
    if (inst(ci).flags & F_EXACT) == 0 && is_known_non_negative(op(ci, 0), ic.sq) { set_flag(ci, F_EXACT, true); return ci; }
    return NONE;
}
ic_visit_sitofp :: (ci: Value_Id) -> Value_Id {
    r := ic_common_cast_transforms(ci); if r != NONE return r;
    if is_known_non_negative(op(ci, 0), ic.sq) return create_cast_flags(.UITOFP, op(ci, 0), vtype(ci), F_EXACT);
    return NONE;
}

// ---------------------------------------------------------------- pointer casts

// GetElementPtrInst::Create(i8, Base, {Offset}) (unlinked, no flags)
create_gep_i8 :: (base: Value_Id, off: Value_Id) -> Value_Id {
    i := new_inst(.GEP, irb_gep_result_type(base, .[off]), 2);
    inst(i).ty2 = ir.t_i8;
    set_op(i, 0, base); set_op(i, 1, off);
    return i;
}

ic_visit_int_to_ptr :: (ci: Value_Id) -> Value_Id {
    as := type_addrspace(vtype(ci));
    src := op(ci, 0);
    if cast(u64) scalar_bits(src) != cast(u64) dl_ptr_spec(as).bits {
        ty := vector_with_elt_or_scalar(vtype(src), type_int(dl_ptr_spec(as).bits));
        p := icb_zext_or_trunc(src, ty);
        return create_cast(.INTTOPTR, p, vtype(ci));
    }
    if has_one_use(src) && ic_is_binop(src, .ADD) {
        for side: 0..1 {
            pti := op(src, cast(u32) side);
            if opr_code(pti) != .PTRTOINT continue;
            base := op(pti, 0);
            if dl_type_size_bits(vtype(pti)) != dl_type_size_bits(vtype(base)) continue;
            offset := op(src, cast(u32) (1 - side));
            if type_addrspace(vtype(ci)) != type_addrspace(vtype(base)) break;
            all := true;
            u := ir.v_first_use[ci];
            while u != NONE {
                us := ir.u_user[u];
                ok := false;
                if is_inst(us) && (inst_op(us) == .ICMP || inst_op(us) == .PTRTOINT) ok = true;
                else if is_phi(us) {
                    pu := first_user(us);
                    ok = has_one_use(us) && is_inst(pu) && (inst_op(pu) == .ICMP || inst_op(pu) == .PTRTOINT);
                }
                if !ok { all = false; break; }
                u = ir.u_next[u];
            }
            if !all break;
            return create_gep_i8(base, offset);
        }
    }
    r := ic_common_cast_transforms(ci); if r != NONE return r;
    return NONE;
}
// Type::getWithNewType
vector_with_elt_or_scalar :: (t: Type_Id, et: Type_Id) -> Type_Id {
    if is_vector_type(t) return vector_with_elt(t, et);
    return et;
}

// foldPtrToIntOrAddrOfGEP
ic_fold_ptr_to_int_or_addr_of_gep :: (int_ty: Type_Id, ptr_in: Value_Id) -> Value_Id {
    ptr := ptr_in;
    ptr_ty := vtype(ptr);
    geps: [..] Value_Id; geps.allocator = temp;
    while true {
        if !is_gep_operator(ptr) || !has_one_use(ptr) break;
        array_add(*geps, ptr);
        ptr = op(ptr, 0);
    }
    if geps.count == 0 || ptr_ty != vtype(ptr) return NONE;
    res: Value_Id = NONE;
    idx_ty := dl_index_type(ptr_ty);
    if has_one_use(ptr) && opr_code(ptr) == .INTTOPTR && vtype(op(ptr, 0)) == int_ty && int_ty == idx_ty {
        res = op(ptr, 0);
    } else if vkind(ptr) == .C_NULL {
        res = const_null_value(idx_ty);
    } else return NONE;
    for < k: 0..geps.count-1 {
        g := geps[k];
        if !is_inst(g) fatal("instcombine: foldPtrToIntOrAddrOfGEP of a constant-expression GEP is not supported yet");
        offset := ic_emit_gep_offset(g);
        res = icb_add(res, offset, "", (gep_nw_bits(g) & F_GEP_NUW) != 0);
    }
    return icb_zext_or_trunc(res, int_ty);
}

ic_visit_ptr_to_int :: (ci: Value_Id) -> Value_Id {
    src_op := op(ci, 0);
    src_ty := vtype(src_op);
    ty := vtype(ci);
    as := type_addrspace(src_ty);
    ty_size := type_bits(scalar_type(ty));
    ptr_size := dl_ptr_spec(as).bits;
    if cast(u64) ty_size != cast(u64) ptr_size {
        ipt := vector_with_elt_or_scalar(src_ty, type_int(ptr_size));
        p := icb_cast(.PTRTOINT, src_op, ipt);
        return create_integer_cast(p, ty, false);
    }
    if has_one_use(src_op) {
        ok, p, m := pm_intrinsic2(src_op, IID_PTRMASK);
        if ok && vtype(m) == ty return create_binop(.AND, icb_cast(.PTRTOINT, p, ty), m);
    }
    v := ic_fold_ptr_to_int_or_addr_of_gep(ty, src_op);
    if v != NONE return ic_replace_inst_uses_with(ci, v);
    if has_one_use(src_op) && is_inst(src_op) && inst_op(src_op) == .INSERTELEMENT && opr_code(op(src_op, 0)) == .INTTOPTR {
        vec := op(op(src_op, 0), 0);
        if vtype(vec) == ty {
            nc := icb_cast(.PTRTOINT, op(src_op, 1), scalar_type(ty));
            return create_insert_element(vec, nc, op(src_op, 2));
        }
    }
    return ic_common_cast_transforms(ci);
}

ic_visit_ptr_to_addr :: (ci: Value_Id) -> Value_Id {
    src_op := op(ci, 0);
    ty := vtype(ci);
    if has_one_use(src_op) {
        ok, p, m := pm_intrinsic2(src_op, IID_PTRMASK);
        if ok && vtype(m) == ty return create_binop(.AND, icb_cast(.PTRTOADDR, p, dl_address_type(vtype(p))), m);
    }
    v := ic_fold_ptr_to_int_or_addr_of_gep(ty, src_op);
    if v != NONE return ic_replace_inst_uses_with(ci, v);
    return ic_common_cast_transforms(ci);
}

// ---------------------------------------------------------------- bitcast

// optimizeVectorResizeWithIntegerBitCasts
ic_optimize_vector_resize_with_integer_bitcasts :: (in_val_in: Value_Id, dest_ty: Type_Id) -> Value_Id {
    in_val := in_val_in;
    src_ty := vtype(in_val);
    if type_elem(src_ty) != type_elem(dest_ty) {
        if ic_prim_bits(type_elem(src_ty)) != ic_prim_bits(type_elem(dest_ty)) return NONE;
        src_ty = type_vector(type_count(src_ty), type_elem(dest_ty), false);
        in_val = icb_cast(.BITCAST, in_val, src_ty);
    }
    src_elts := cast(s64) type_count(src_ty);
    dest_elts := cast(s64) type_count(dest_ty);
    mask: [..] u32; mask.allocator = temp;
    v2: Value_Id;
    if src_elts > dest_elts {
        v2 = const_poison(src_ty);
        start := ifx dl.big_endian then src_elts - dest_elts else 0;
        for k: 0..dest_elts-1 array_add(*mask, cast(u32) (start + k));
    } else {
        v2 = const_null_value(src_ty);
        null_elt := cast(u32) src_elts;
        delta := dest_elts - src_elts;
        if dl.big_endian for k: 0..delta-1 array_add(*mask, null_elt);
        for k: 0..src_elts-1 array_add(*mask, cast(u32) k);
        if !dl.big_endian for k: 0..delta-1 array_add(*mask, null_elt);
    }
    return create_shuffle(in_val, v2, mask);
}

// collectInsertionElements
ic_collect_insertion_elements :: (v: Value_Id, shift_in: u32, elements: [] Value_Id, vec_elt_ty: Type_Id, big_endian: bool) -> bool {
    shift := shift_in;
    elt_bits := ic_prim_bits(vec_elt_ty);
    if pm_poison(v) return true;
    if vtype(v) == vec_elt_ty {
        if is_const(v) && is_null_value(v) return true;
        idx := cast(s64) (cast(u64) shift / elt_bits);
        if big_endian idx = elements.count - idx - 1;
        if elements[idx] != NONE return false;
        elements[idx] = v;
        return true;
    }
    if is_const(v) {
        c := v;
        num_elts := ic_prim_bits(vtype(c)) / elt_bits;
        if num_elts == 1 return ic_collect_insertion_elements(ce_cast(.BITCAST, c, vec_elt_ty), shift, elements, vec_elt_ty, big_endian);
        if !is_int_type(vtype(c)) c = ce_cast(.BITCAST, c, type_int(ic_prim_bits(vtype(c))));
        elt_int_ty := type_int(elt_bits);
        for k: 0..cast(s64) num_elts - 1 {
            shift_i := cast(u32) (cast(u64) k * elt_bits);
            piece := cfo_binary_op_operands(.LSHR, c, const_int_of(vtype(c), cast(u64) shift_i));
            if piece == NONE return false;
            piece = ce_cast(.TRUNC, piece, elt_int_ty);
            if !ic_collect_insertion_elements(piece, shift_i + shift, elements, vec_elt_ty, big_endian) return false;
        }
        return true;
    }
    if !has_one_use(v) return false;
    if !is_inst(v) return false;
    i := v;
    if inst_op(i) == {
        case .BITCAST;
            if is_vector_type(vtype(op(i, 0))) return false;
            return ic_collect_insertion_elements(op(i, 0), shift, elements, vec_elt_ty, big_endian);
        case .ZEXT;
            if ic_prim_bits(vtype(op(i, 0))) % elt_bits != 0 return false;
            return ic_collect_insertion_elements(op(i, 0), shift, elements, vec_elt_ty, big_endian);
        case .OR;
            return ic_collect_insertion_elements(op(i, 0), shift, elements, vec_elt_ty, big_endian) &&
                   ic_collect_insertion_elements(op(i, 1), shift, elements, vec_elt_ty, big_endian);
        case .SHL;
            c := op(i, 1);
            if !cf_is_int(c) return false;
            shift += cast(u32) const_int_zext(c);
            if cast(u64) shift % elt_bits != 0 return false;
            return ic_collect_insertion_elements(op(i, 0), shift, elements, vec_elt_ty, big_endian);
    }
    return false;
}

// optimizeIntegerToVectorInsertions
ic_optimize_integer_to_vector_insertions :: (ci: Value_Id) -> Value_Id {
    dest_ty := vtype(ci);
    int_input := op(ci, 0);
    if pm_undef_value(int_input) return NONE;
    elements := NewArray(cast(s64) type_count(dest_ty), Value_Id,, allocator = temp);
    for * elements it.* = NONE;
    if !ic_collect_insertion_elements(int_input, 0, elements, type_elem(dest_ty), dl.big_endian) return NONE;
    result := const_null_value(dest_ty);
    for e: elements {
        if e == NONE continue;
        result = icb_insert_element(result, e, const_int(ir.t_i64, cast(u64) it_index));
    }
    return result;
}

// canonicalizeBitCastExtElt
ic_canonicalize_bitcast_ext_elt :: (bc: Value_Id) -> Value_Id {
    e := op(bc, 0);
    if !has_one_use(e) || !is_inst(e) || inst_op(e) != .EXTRACTELEMENT return NONE;
    vec_op := op(e, 0); index := op(e, 1);
    dest_ty := vtype(bc);
    vty := vtype(vec_op);
    if ic_is_valid_vector_element_type(dest_ty) {
        nvt := vector_with_elt(vty, dest_ty);
        nbc := icb_cast(.BITCAST, vec_op, nvt, "bc");
        return create_extract_element(nbc, index);
    }
    if is_vector_type(dest_ty) && type_kind(vty) == .VECTOR && type_count(vty) == 1 return create_cast(.BITCAST, vec_op, dest_ty);
    return NONE;
}
// VectorType::isValidElementType
ic_is_valid_vector_element_type :: (t: Type_Id) -> bool {
    k := type_kind(t);
    return k == .INT || is_fp_kind(k) || k == .PTR || k == .BYTE || (k == .TARGET_EXT && false);
}

// foldBitCastBitwiseLogic
ic_fold_bitcast_bitwise_logic :: (bc: Value_Id) -> Value_Id {
    dest_ty := vtype(bc);
    bo := op(bc, 0);
    if !has_one_use(bo) || !is_inst(bo) || !is_bitwise_logic_op(inst_op(bo)) return NONE;
    if !is_vector_type(dest_ty) || !is_vector_type(vtype(bo)) return NONE;
    opc := inst_op(bo);
    if is_fp_or_fp_vector_ty(dest_ty) {
        b0 := op(bo, 0); b1 := op(bo, 1);
        okx, x := pm_cast(b0, .BITCAST);
        oky, y := pm_cast(b1, .BITCAST);
        if okx && has_one_use(b0) && oky && has_one_use(b1) {
            if is_fp_or_fp_vector_ty(vtype(x)) && is_int_or_int_vector(vtype(y)) {
                c := icb_cast(.BITCAST, b0, vtype(y));
                nb := icb_binop(opc, c, y);
                return create_bit_or_pointer_cast(nb, dest_ty);
            }
            if is_int_or_int_vector(vtype(x)) && is_fp_or_fp_vector_ty(vtype(y)) {
                c := icb_cast(.BITCAST, b1, vtype(x));
                nb := icb_binop(opc, c, x);
                return create_bit_or_pointer_cast(nb, dest_ty);
            }
        }
        return NONE;
    }
    if !is_int_or_int_vector(dest_ty) return NONE;
    b0 := op(bo, 0); b1 := op(bo, 1);
    okx, x := pm_cast(b0, .BITCAST);
    if okx && has_one_use(b0) && vtype(x) == dest_ty && !is_const(x) {
        c1 := icb_cast(.BITCAST, b1, dest_ty);
        return create_binop(opc, x, c1);
    }
    okx, x = pm_cast(b1, .BITCAST);
    if okx && has_one_use(b1) && vtype(x) == dest_ty && !is_const(x) {
        c0 := icb_cast(.BITCAST, b0, dest_ty);
        return create_binop(opc, c0, x);
    }
    if is_const(b1) {
        c0 := icb_cast(.BITCAST, b0, dest_ty);
        cc := icb_cast(.BITCAST, b1, dest_ty);
        return create_binop(opc, c0, cc);
    }
    return NONE;
}

// foldBitCastSelect
ic_fold_bitcast_select :: (bc: Value_Id) -> Value_Id {
    sel := op(bc, 0);
    oks, cnd, tv, fv := pm_select(sel);
    if !oks || !has_one_use(sel) return NONE;
    cond_ty := vtype(cnd);
    dest_ty := vtype(bc);
    dest_vec := is_vector_type(dest_ty);
    if is_vector_type(cond_ty) {
        if !dest_vec || !same_element_count(cond_ty, dest_ty) return NONE;
    }
    src_vec := is_vector_type(vtype(tv));
    if (is_const(tv) || is_const(fv)) &&
       (!dest_vec || (src_vec && (type_kind(dest_ty) == .SVECTOR) == (type_kind(vtype(tv)) == .SVECTOR) && type_count(dest_ty) <= type_count(vtype(tv)))) {
        ct := icb_cast(.BITCAST, tv, dest_ty);
        cf := icb_cast(.BITCAST, fv, dest_ty);
        return create_select_md_from(cnd, ct, cf, sel);
    }
    if dest_vec != src_vec return NONE;
    okx, x := pm_cast(tv, .BITCAST);
    if okx && has_one_use(tv) && vtype(x) == dest_ty && !is_const(x) {
        cv := icb_cast(.BITCAST, fv, dest_ty);
        return create_select_md_from(cnd, x, cv, sel);
    }
    okx, x = pm_cast(fv, .BITCAST);
    if okx && has_one_use(fv) && vtype(x) == dest_ty && !is_const(x) {
        cv := icb_cast(.BITCAST, tv, dest_ty);
        return create_select_md_from(cnd, cv, x, sel);
    }
    return NONE;
}

// hasStoreUsersOnly
ic_has_store_users_only :: (ci: Value_Id) -> bool {
    u := ir.v_first_use[ci];
    while u != NONE {
        us := ir.u_user[u];
        if !is_inst(us) || inst_op(us) != .STORE return false;
        u = ir.u_next[u];
    }
    return true;
}
ic_is_simple_mem :: (i: Value_Id) -> bool { return !is_volatile(i) && inst(i).ord1 == 0; }

// optimizeBitCastFromPhi
ic_optimize_bitcast_from_phi :: (ci: Value_Id, pn: Value_Id) -> Value_Id {
    if ic_has_store_users_only(ci) return NONE;
    src := op(ci, 0);
    src_ty := vtype(src);
    dest_ty := vtype(ci);
    work: [..] Value_Id; work.allocator = temp;
    old: [..] Value_Id; old.allocator = temp;
    old_set: Table(Value_Id, bool); old_set.allocator = temp;
    array_add(*work, pn); array_add(*old, pn); table_set(*old_set, pn, true);
    while work.count {
        opn := pop(*work);
        n := phi_num_incoming(opn);
        for k: 0..cast(s64) n - 1 {
            iv := phi_value(opn, cast(u32) k);
            if is_const(iv) continue;
            if is_inst(iv) && inst_op(iv) == .LOAD {
                addr := op(iv, 0);
                if addr == ci || (is_inst(addr) && inst_op(addr) == .LOAD) return NONE;
                if type_kind(dest_ty) == .X86_AMX return NONE;
                if has_one_use(iv) && ic_is_simple_mem(iv) continue;
                return NONE;
            }
            if is_phi(iv) {
                if !table_contains(*old_set, iv) { table_set(*old_set, iv, true); array_add(*old, iv); array_add(*work, iv); }
                continue;
            }
            if !is_inst(iv) || inst_op(iv) != .BITCAST return NONE;
            if vtype(op(iv, 0)) != dest_ty || vtype(iv) != src_ty return NONE;
        }
    }
    for opn: old {
        u := ir.v_first_use[opn];
        while u != NONE {
            v := ir.u_user[u];
            u = ir.u_next[u];
            if inst_op(v) == .STORE {
                if !ic_is_simple_mem(v) || op(v, 0) != opn return NONE;
            } else if inst_op(v) == .BITCAST {
                if vtype(v) != dest_ty || vtype(op(v, 0)) != src_ty return NONE;
            } else if is_phi(v) {
                if !table_contains(*old_set, v) return NONE;
            } else return NONE;
        }
    }
    new_pn: Table(Value_Id, Value_Id); new_pn.allocator = temp;
    for opn: old {
        icb_set_insert_point(opn);
        np := icb_phi(dest_ty, nops(opn));
        table_set(*new_pn, opn, np);
    }
    for opn: old {
        _, np := table_find(*new_pn, opn);
        n := phi_num_incoming(opn);
        for j: 0..cast(s64) n - 1 {
            v := phi_value(opn, cast(u32) j);
            nv: Value_Id = NONE;
            if is_const(v) nv = ce_cast(.BITCAST, v, dest_ty);
            else if inst_op(v) == .LOAD {
                icb_set_insert_point(v);
                nv = ic_combine_load_to_new_type(v, dest_ty);
                ic_replace_inst_uses_with(v, const_poison(vtype(v)));
                ic_erase_inst(v);
            } else if inst_op(v) == .BITCAST nv = op(v, 0);
            else if is_phi(v) { _, nv = table_find(*new_pn, v); }
            phi_add_incoming(np, nv, phi_block(opn, cast(u32) j));
        }
    }
    ret_val: Value_Id = NONE;
    for opn: old {
        _, np := table_find(*new_pn, opn);
        u := ir.v_first_use[opn];
        while u != NONE {
            v := ir.u_user[u];
            u = ir.u_next[u];
            if inst_op(v) == .STORE {
                icb_set_insert_point(v);
                nbc := icb_cast(.BITCAST, np, src_ty);
                set_op(v, 0, nbc);
                wl_push(v);
            } else if inst_op(v) == .BITCAST {
                r := ic_replace_inst_uses_with(v, np);
                if v == ci ret_val = r;
            }
        }
    }
    return ret_val;
}

// foldCopySignIdioms
ic_fold_copy_sign_idioms :: (ci: Value_Id, q: Simplify_Query) -> Value_Id {
    fty := vtype(ci);
    if !is_fp_or_fp_vector_ty(fty) return NONE;
    okb, o := pm_elementwise_bitcast(ci);
    if !okb || !ic_is_binop(o, .OR) return NONE;
    x: Value_Id = NONE; y: Value_Id = NONE;
    for side: 0..1 {
        a := op(o, cast(u32) side);
        ok, bx, sm := pm_binop(a, .AND);
        if !ok || !is_inst(a) || !pm_sign_mask(sm) continue;
        okx, bx2 := pm_elementwise_bitcast(bx);
        if !okx continue;
        x = bx2; y = op(o, cast(u32) (1 - side));
        break;
    }
    if x == NONE return NONE;
    if vtype(x) != fty return NONE;
    if !is_known_non_negative(y, q) return NONE;
    return icb_binary_intrinsic(IID_COPYSIGN, icb_cast(.BITCAST, y, fty), x);
}

ic_visit_bitcast :: (ci: Value_Id) -> Value_Id {
    src := op(ci, 0);
    src_ty := vtype(src);
    dest_ty := vtype(ci);
    if dest_ty == src_ty return ic_replace_inst_uses_with(ci, src);
    if type_kind(dest_ty) == .VECTOR && is_int_type(src_ty) {
        if is_inst(src) && (inst_op(src) == .TRUNC || inst_op(src) == .ZEXT) {
            bcin := op(src, 0);
            if is_inst(bcin) && inst_op(bcin) == .BITCAST && is_vector_type(vtype(op(bcin, 0)))  {
                r := ic_optimize_vector_resize_with_integer_bitcasts(op(bcin, 0), dest_ty);
                if r != NONE return r;
            }
        }
        v := ic_optimize_integer_to_vector_insertions(ci);
        if v != NONE return ic_replace_inst_uses_with(ci, v);
    }
    if type_kind(src_ty) == .VECTOR {
        if type_count(src_ty) == 1 {
            if !is_vector_type(dest_ty) {
                elem := icb_extract_element(src, const_int(ir.t_i64, 0));
                return create_cast(.BITCAST, elem, dest_ty);
            }
            if is_inst(src) && inst_op(src) == .INSERTELEMENT return create_cast(.BITCAST, op(src, 1), dest_ty);
        }
        bw := type_bits(scalar_type(dest_ty));
        if has_one_use(src) && is_inst(src) && inst_op(src) == .INSERTELEMENT {
            bcx := op(src, 0); y := op(src, 1);
            okx, x := pmi_cast(bcx, .BITCAST);
            okc, idx := pm_constant_int_u64(op(src, 2));
            if okx && has_one_use(bcx) && okc && is_int_type(dest_ty) && vtype(x) == dest_ty && is_int_type(vtype(y)) && ic_is_desirable_int_type(bw) {
                if dl.big_endian idx = type_count(src_ty) - 1 - idx;
                if idx == 0 {
                    elt_w := scalar_bits(y);
                    and_x := icb_and(x, const_int_ap(vtype(x), ap_high_bits_set(bw, bw - elt_w)));
                    zy := icb_zext(y, dest_ty);
                    return create_binop(.OR, and_x, zy);
                }
            }
        }
    }
    if is_inst(src) && inst_op(src) == .SHUFFLEVECTOR {
        shuf := src;
        s0 := op(shuf, 0); s1 := op(shuf, 1);
        sty := vtype(shuf); s0ty := vtype(s0);
        same_ec :: (a: Type_Id, b: Type_Id) -> bool { return type_count(a) == type_count(b) && (type_kind(a) == .SVECTOR) == (type_kind(b) == .SVECTOR); }
        if has_one_use(shuf) && is_vector_type(dest_ty) && same_ec(dest_ty, sty) && same_ec(sty, s0ty) {
            if (is_inst(s0) && inst_op(s0) == .BITCAST && vtype(op(s0, 0)) == dest_ty) ||
               (is_inst(s1) && inst_op(s1) == .BITCAST && vtype(op(s1, 0)) == dest_ty) {
                l := icb_cast(.BITCAST, s0, dest_ty);
                rr := icb_cast(.BITCAST, s1, dest_ty);
                return create_shuffle(l, rr, shuffle_mask(shuf));
            }
        }
        if is_int_type(dest_ty) && type_count(sty) % 2 == 0 && has_one_use(shuf) && ic_shuffle_is_reverse(shuf) && pm_poison(s1) {
            iid: Intrinsic_Id = NOT_INTRINSIC;
            if dl_is_legal_integer(type_bits(scalar_type(dest_ty))) && type_bits(scalar_type(src_ty)) == 8 iid = IID_BSWAP;
            else if type_bits(scalar_type(src_ty)) == 1 iid = IID_BITREVERSE;
            if iid != NOT_INTRINSIC {
                sx := icb_cast(.BITCAST, s0, dest_ty);
                return create_intrinsic_call(iid, .[dest_ty], .[sx]);
            }
        }
    }
    if is_phi(src) {
        r := ic_optimize_bitcast_from_phi(ci, src);
        if r != NONE return r;
    }
    r := ic_canonicalize_bitcast_ext_elt(ci); if r != NONE return r;
    r = ic_fold_bitcast_bitwise_logic(ci); if r != NONE return r;
    r = ic_fold_bitcast_select(ci); if r != NONE return r;
    v := ic_fold_copy_sign_idioms(ci, ic_q(ci));
    if v != NONE return ic_replace_inst_uses_with(ci, v);
    return ic_common_cast_transforms(ci);
}
// ShuffleVectorInst::isReverse (single source, same size, mask n-1..0 with poison allowed)
ic_shuffle_is_reverse :: (sv: Value_Id) -> bool {
    m := shuffle_mask(sv);
    st := vtype(op(sv, 0));
    if type_kind(st) != .VECTOR return false;
    n := cast(s64) type_count(st);
    if m.count != n || n < 2 return false;
    // isSingleSourceMask + reverse: every lane i is poison or (n-1-i) from either source
    uses0 := false; uses1 := false;
    for m {
        if it == 0xFFFF_FFFF continue;
        if cast(s64) it < n uses0 = true; else uses1 = true;
        if (cast(s64) it % n) != n - 1 - it_index return false;
    }
    if uses0 && uses1 return false;
    return uses0 || uses1;
}

ic_visit_addr_space_cast :: (ci: Value_Id) -> Value_Id { return ic_common_cast_transforms(ci); }
