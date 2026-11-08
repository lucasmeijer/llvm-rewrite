// InstCombine: the visitor dispatch (InstVisitor<InstCombinerImpl>::visit as an opcode switch) and the visitors of
// the files that are not ported yet. Each partial visitor below ports the beginning of its LLVM counterpart (the
// InstSimplify call and the canonicalizations listed in its comment) and documents what it leaves out; extending
// one means porting the rest of its function in order (see DESIGN.md "InstCombine: how to add a fold").
// Ported from: InstructionCombining.cpp (visitReturnInst, visitUnreachableInst, visitUncondBrInst, visitCondBrInst,
// handlePotentiallyDeadSuccessors, visitExtractValueInst prologue, visitFreeze prologue, visitGetElementPtrInst
// prologue), InstCombineCompares.cpp (visitICmpInst/visitFCmpInst prologues), InstCombineSelect.cpp,
// InstCombineShifts.cpp, InstCombineAndOrXor.cpp, InstCombineCasts.cpp (commonCastTransforms), InstCombinePHI.cpp,
// InstCombineCalls.cpp, InstCombineVectorOps.cpp, InstCombineLoadStoreAlloca.cpp (prologues only).

ic_visit :: (i: Value_Id) -> Value_Id {
    o := inst_op(i);
    if o == {
        case .ADD; return ic_visit_add(i);
        case .SUB; return ic_visit_sub(i);
        case .MUL; return ic_visit_mul(i);
        case .UDIV; return ic_visit_udiv(i);
        case .SDIV; return ic_visit_sdiv(i);
        case .UREM; return ic_visit_urem(i);
        case .SREM; return ic_visit_srem(i);
        case .FADD; return ic_visit_fadd(i);
        case .FSUB; return ic_visit_fsub(i);
        case .FMUL; return ic_visit_fmul(i);
        case .FDIV; return ic_visit_fdiv(i);
        case .FREM; return ic_visit_frem(i);
        case .FNEG; return ic_visit_fneg(i);
        case .AND; #through;
        case .OR; #through;
        case .XOR; return ic_visit_bitwise(i);
        case .SHL; #through;
        case .LSHR; #through;
        case .ASHR; return ic_visit_shift(i);
        case .ICMP; return ic_visit_icmp(i);
        case .FCMP; return ic_visit_fcmp(i);
        case .SELECT; return ic_visit_select(i);
        case .PHI; return ic_visit_phi(i);
        case .GEP; return ic_visit_gep(i);
        case .CALL; return ic_visit_call(i);
        case .RET; return ic_visit_return(i);
        case .UNREACHABLE; return ic_visit_unreachable(i);
        case .BR; return ic_visit_uncond_br(i);
        case .CONDBR; return ic_visit_cond_br(i);
        case .FREEZE; return ic_visit_freeze(i);
        case .EXTRACTVALUE; return ic_visit_extract_value(i);
        case .LOAD; return ic_visit_load(i);
        case .EXTRACTELEMENT; #through;
        case .INSERTELEMENT; #through;
        case .INSERTVALUE; #through;
        case .SHUFFLEVECTOR; return ic_visit_simplify_only(i);
    }
    if o == {
        case .UITOFP; return ic_visit_uitofp(i);
        case .SITOFP; return ic_visit_sitofp(i);
        case .ZEXT; return ic_visit_zext(i);
        case .SEXT; return ic_visit_sext(i);
        case .TRUNC; return ic_visit_trunc(i);
    }
    if is_cast_op(o) return ic_visit_cast(i);
    return NONE;   // visitInstruction
}

// visitUIToFP / visitSIToFP (complete, given commonCastTransforms)
ic_visit_uitofp :: (i: Value_Id) -> Value_Id {
    r := ic_visit_cast(i); if r != NONE return r;
    if (inst(i).flags & F_EXACT) == 0 && is_known_non_negative(op(i, 0), ic.sq) { set_flag(i, F_EXACT, true); return i; }
    return NONE;
}
ic_visit_sitofp :: (i: Value_Id) -> Value_Id {
    r := ic_visit_cast(i); if r != NONE return r;
    if is_known_non_negative(op(i, 0), ic.sq) return create_cast_flags(.UITOFP, op(i, 0), vtype(i), F_EXACT);
    return NONE;
}
// visitZExt: the trunc-user bailout, commonCastTransforms, zext nneg i1, the nneg inference at the end.
// Not ported: everything in between (canEvaluateZExtd, transformZExtICmp, ...).
ic_visit_zext :: (i: Value_Id) -> Value_Id {
    if has_one_use(i) && inst_op(first_user(i)) == .TRUNC && !is_const(op(i, 0)) return NONE;
    r := ic_visit_cast(i); if r != NONE return r;
    src := op(i, 0);
    st := vtype(src); dt := vtype(i);
    if is_int_or_int_vector_n(st, 1) && (inst(i).flags & F_EXACT) != 0 return ic_replace_inst_uses_with(i, const_null_value(dt));
    if (inst(i).flags & F_EXACT) == 0 {
        if has_one_use(i) && cast(u64) scalar_bits(src) > log2_ceil_u64(cast(u64) type_bits(scalar_type(dt))) {
            us := first_user(i);
            if is_inst(us) && is_shift_op(inst_op(us)) && op(us, 1) == i { set_flag(i, F_EXACT, true); return i; }
        }
        if is_known_non_negative(src, ic_q(i)) { set_flag(i, F_EXACT, true); return i; }
    }
    return NONE;
}
log2_ceil_u64 :: (x: u64) -> u64 { if x <= 1 return 0; n: u64 = 0; v := x - 1; while v { n += 1; v >>= 1; } return n; }
// visitSExt: the trunc-user bailout, commonCastTransforms, sext of a non-negative value. Not ported: the rest.
ic_visit_sext :: (i: Value_Id) -> Value_Id {
    if has_one_use(i) && inst_op(first_user(i)) == .TRUNC return NONE;
    r := ic_visit_cast(i); if r != NONE return r;
    src := op(i, 0);
    if is_known_non_negative(src, ic_q(i)) return create_cast_flags(.ZEXT, src, vtype(i), F_EXACT);
    return NONE;
}
// visitTrunc: commonCastTransforms, SimplifyDemandedInstructionBits, the i1-of-nonzero fold and the nuw/nsw
// inference. Not ported: canEvaluateTruncated, narrowing, and the folds between.
ic_visit_trunc :: (i: Value_Id) -> Value_Id {
    r := ic_visit_cast(i); if r != NONE return r;
    src := op(i, 0);
    dw := scalar_bits(i); sw := scalar_bits(src);
    if ic_simplify_demanded_instruction_bits(i) return i;
    if dw == 1 && (has_nuw(i) || has_nsw(i)) && is_known_non_zero(src, ic_q(i)) return ic_replace_inst_uses_with(i, get_true(vtype(i)));
    changed := false;
    if !has_nsw(i) && max_significant_bits(src, ic_q_no_dc(i)) <= dw { set_nsw(i); changed = true; }
    if !has_nuw(i) && ic_masked_value_is_zero(src, ap_bits_set_from(sw, dw), i) { set_nuw(i); changed = true; }
    if changed return i;
    return NONE;
}
// llvm::ComputeMaxSignificantBits(Op, DL, &AC, CxtI, &DT): no DomConditionCache, safeCxtI
ic_q_no_dc :: (i: Value_Id) -> Simplify_Query { q: Simplify_Query; q.dt = ic.dt; q.ac = ic.ac; q.cxt = i; return q; }

// The InstSimplify step every visitor starts with (when nothing else is ported for it).
ic_visit_simplify_only :: (i: Value_Id) -> Value_Id {
    v := simplify_instruction(i, ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    return NONE;
}

// visitAnd / visitOr / visitXor: InstSimplify, SimplifyAssociativeOrCommutative, foldVectorBinop,
// foldBinopWithPhiOperands, SimplifyDemandedInstructionBits (visitXor: after foldNot etc., not ported).
// Not ported: everything after SimplifyDemandedInstructionBits.
ic_visit_bitwise :: (i: Value_Id) -> Value_Id {
    v := simplify_instruction(i, ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if ic_simplify_associative_or_commutative(i) return i;
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_fold_binop_with_phi_operands(i); if r != NONE return r;
    if inst_op(i) != .XOR && ic_simplify_demanded_instruction_bits(i) return i;
    return NONE;
}

// visitShl / visitLShr / visitAShr: InstSimplify, foldVectorBinop, the start of commonShiftTransforms
// (foldBinopWithPhiOperands, sext shift amount, SimplifyDemandedInstructionBits). Not ported: the rest.
ic_visit_shift :: (i: Value_Id) -> Value_Id {
    v := simplify_instruction(i, ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_fold_binop_with_phi_operands(i); if r != NONE return r;
    op1 := op(i, 1);
    oks, y := pmi_cast(op1, .SEXT);
    if oks && has_one_use(op1) {
        ne := icb_zext(y, vtype(i), name_ref(vname(op1)));
        return create_binop(inst_op(i), op(i, 0), ne);
    }
    if ic_simplify_demanded_instruction_bits(i) return i;
    if ic_set_shift_flags(i, ic_q(i)) return i;
    return NONE;
}

// setShiftFlags (InstCombineShifts.cpp)
ic_set_shift_flags :: (i: Value_Id, q: Simplify_Query) -> bool {
    if inst_op(i) == .SHL {
        if has_nuw(i) && has_nsw(i) return false;
    } else {
        if is_exact(i) return false;
        oks, x, y := pm_binop(op(i, 0), .SHL);
        if oks && y == op(i, 1) { set_exact(i); return true; }
        okc, cx, cz := pm_intrinsic2(op(i, 1), IID_CTTZ);
        if okc && cx == op(i, 0) { set_exact(i); return true; }
    }
    kc := known_bits(op(i, 1), q);
    bw := kb_bits(kc);
    max_cnt := ap_limited(kb_max_value(kc), bw - 1);
    ka := known_bits(op(i, 0), q);
    changed := false;
    if inst_op(i) == .SHL {
        if !has_nuw(i) && max_cnt <= kb_count_min_leading_zeros(ka) { set_nuw(i); changed = true; }
        if !has_nsw(i) {
            if max_cnt < kb_count_min_sign_bits(ka) || max_cnt < num_sign_bits_ctx(op(i, 0), q.cxt, q.dt, q.ac) { set_nsw(i); changed = true; }
        }
        return changed;
    }
    changed = max_cnt <= kb_count_min_trailing_zeros(ka);
    set_exact(i, changed);
    return changed;
}

// visitICmpInst: operand complexity order, InstSimplify, abs(x) != 0, foldICmpTruncWithTruncOrExt,
// canonicalizeICmpBool, canonicalizeCmpWithConstant, canonicalizeICmpPredicate. Not ported: everything after
// (foldICmpWithConstant onwards).
ic_visit_icmp :: (i: Value_Id) -> Value_Id {
    changed := false;
    if ic_complexity(op(i, 0)) < ic_complexity(op(i, 1)) { cmp_swap_operands(i); changed = true; }
    op0 := op(i, 0); op1 := op(i, 1);
    v := simplify_icmp_inst(inst_pred(i), (inst(i).flags & F_EXACT) != 0, op0, op1, ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    pred := inst_pred(i);
    if pred == ICMP_NE && pm_zero(op1) {
        ok, cond, st, sf := pm_select(op0);
        if ok {
            nv := ic_dyn_cast_neg_val(st);
            if nv != NONE { if nv == sf return create_icmp(pred, nv, op1); }
            else {
                nv = ic_dyn_cast_neg_val(sf);
                if nv != NONE && nv == st return create_icmp(pred, nv, op1);
            }
        }
    }
    r := ic_fold_icmp_trunc_with_trunc_or_ext(i); if r != NONE return r;
    if is_int_or_int_vector_n(vtype(op0), 1) { r = ic_canonicalize_icmp_bool(i); if r != NONE return r; }
    r = ic_canonicalize_cmp_with_constant(i); if r != NONE return r;
    r = ic_canonicalize_icmp_predicate(i); if r != NONE return r;
    if changed return i;
    return NONE;
}

// foldICmpTruncWithTruncOrExt
ic_fold_icmp_trunc_with_trunc_or_ext :: (cmp: Value_Id) -> Value_Id {
    pred := inst_pred(cmp);
    o0 := op(cmp, 0); o1 := op(cmp, 1);
    x, y: Value_Id = NONE;
    y_is_sext := false;
    ok0, x0 := pmi_cast(o0, .TRUNC);
    ok1, y1 := pmi_cast(o1, .TRUNC);
    if ok0 && ok1 {
        nw := inst(o0).flags & inst(o1).flags & cast(u32)(F_NUW | F_NSW);
        if icmp_is_signed(pred) { if (nw & F_NSW) == 0 return NONE; }
        else if nw == 0 return NONE;
        x = x0; y = y1;
        if vtype(x) != vtype(y) && (!has_one_use(o0) || !has_one_use(o1)) return NONE;
        if !ic_is_desirable_int_type(scalar_bits(x)) && ic_is_desirable_int_type(scalar_bits(y)) {
            t := x; x = y; y = t;
            pred = swapped_predicate(pred);
        }
        y_is_sext = (nw & F_NUW) == 0;
    } else {
        found := false;
        if !icmp_is_signed(pred) {
            for side: 0..1 {
                t := op(cmp, cast(u32) side); z := op(cmp, cast(u32) (1 - side));
                okt, tx := pmi_cast(t, .TRUNC);
                okz, zy := pmi_cast(z, .ZEXT);
                if okt && has_nuw(t) && okz && has_one_use(z) {
                    x = tx; y = zy; found = true;
                    if side == 1 pred = swapped_predicate(pred);
                    break;
                }
            }
        }
        if !found {
            for side: 0..1 {
                t := op(cmp, cast(u32) side); z := op(cmp, cast(u32) (1 - side));
                okt, tx := pmi_cast(t, .TRUNC);
                okz, zy := pmi_zext_or_sext(z);
                if okt && has_nsw(t) && okz && has_one_use(z) {
                    x = tx; y = zy; found = true;
                    if side == 1 pred = swapped_predicate(pred);
                    y_is_sext = inst_op(o0) == .SEXT || inst_op(o1) == .SEXT;
                    break;
                }
            }
        }
        if !found return NONE;
    }
    tbits := scalar_bits(o0);
    if ic_is_desirable_int_type(tbits) && !ic_is_desirable_int_type(scalar_bits(x)) return NONE;
    ny := icb_int_cast(y, vtype(x), y_is_sext);
    return create_icmp(pred, x, ny);
}

// canonicalizeICmpBool
ic_canonicalize_icmp_bool :: (i: Value_Id) -> Value_Id {
    a := op(i, 0); b := op(i, 1);
    p := inst_pred(i);
    if pm_zero(b) {
        if p == ICMP_EQ || p == ICMP_ULE || p == ICMP_SGE return create_not(a);
        fatal("internal: ICmp i1 X, C not simplified as expected.");
    } else if pm_one(b) {
        if p == ICMP_NE || p == ICMP_ULT || p == ICMP_SGT return create_not(a);
        fatal("internal: ICmp i1 X, C not simplified as expected.");
    }
    if p == {
        case ICMP_EQ; return create_not(icb_xor(a, b));
        case ICMP_NE; return create_binop(.XOR, a, b);
        case ICMP_UGT; return create_binop(.AND, icb_not(b), a);
        case ICMP_ULT; return create_binop(.AND, icb_not(a), b);
        case ICMP_SGT; return create_binop(.AND, icb_not(a), b);
        case ICMP_SLT; return create_binop(.AND, icb_not(b), a);
        case ICMP_UGE; return create_binop(.OR, icb_not(b), a);
        case ICMP_ULE; return create_binop(.OR, icb_not(a), b);
        case ICMP_SGE; return create_binop(.OR, icb_not(a), b);
        case ICMP_SLE; return create_binop(.OR, icb_not(b), a);
    }
    fatal("internal: Invalid icmp instruction!");
    return NONE;
}

// getFlippedStrictnessPredicateAndConstant (ValueTracking.cpp)
flipped_strictness_predicate_and_constant :: (pred: u8, c: Value_Id) -> (bool, u8, Value_Id) {
    if pm_undef_value(c) return false, 0, NONE;
    t := vtype(c);
    is_signed := icmp_is_signed(pred);
    up := icmp_unsigned_predicate(pred);
    will_inc := up == ICMP_ULE || up == ICMP_UGT;
    ok_c :: (ci: Value_Id, will_inc: bool, is_signed: bool) -> bool {
        a := const_ap(ci);
        if will_inc return !(ifx is_signed then ap_is_max_signed(a) else ap_is_all_ones(a));
        return !(ifx is_signed then ap_is_min_signed(a) else ap_is_zero(a));
    }
    safe: Value_Id = NONE;
    k := vkind(c);
    if k == .C_INT && !is_vector_type(t) {
        if !ok_c(c, will_inc, is_signed) return false, 0, NONE;
    } else if type_kind(t) == .VECTOR {
        n := type_count(t);
        for e: 0..cast(s64) n - 1 {
            elt := cf_elt(c, cast(u64) e);
            if elt == NONE return false, 0, NONE;
            if pm_undef_value(elt) continue;
            if vkind(elt) != .C_INT || !ok_c(elt, will_inc, is_signed) return false, 0, NONE;
            if safe == NONE safe = elt;
        }
    } else if is_vector_type(t) {
        s := get_splat_value(c);
        if s == NONE || vkind(s) != .C_INT || !ok_c(s, will_inc, is_signed) return false, 0, NONE;
    } else return false, 0, NONE;
    cc := c;
    if contains_undef_or_poison_element(cc) {
        n := type_count(t);
        elts := NewArray(cast(s64) n, Value_Id,, allocator = temp);
        for e: 0..cast(s64) n - 1 { elt := cf_elt(cc, cast(u64) e); elts[e] = ifx pm_undef_value(elt) then safe else elt; }
        cc = cf_vector(t, elts);
    }
    np := icmp_flipped_strictness(pred);
    one := const_int_signed(t, ifx will_inc then 1 else -1);
    return true, np, ce_binop(.ADD, cc, one, 0);
}
// CmpInst::getFlippedStrictnessPredicate
icmp_flipped_strictness :: (p: u8) -> u8 {
    if p == {
        case ICMP_SGT; return ICMP_SGE; case ICMP_SLT; return ICMP_SLE; case ICMP_SGE; return ICMP_SGT; case ICMP_SLE; return ICMP_SLT;
        case ICMP_UGT; return ICMP_UGE; case ICMP_ULT; return ICMP_ULE; case ICMP_UGE; return ICMP_UGT; case ICMP_ULE; return ICMP_ULT;
    }
    return p;
}
// canonicalizeCmpWithConstant
ic_canonicalize_cmp_with_constant :: (i: Value_Id) -> Value_Id {
    p := inst_pred(i);
    if icmp_is_equality(p) || !is_int_predicate(p) || is_canonical_predicate(p) return NONE;
    c := op(i, 1);
    if !is_const(c) return NONE;
    ok, np, nc := flipped_strictness_predicate_and_constant(p, c);
    if !ok return NONE;
    return create_icmp(np, op(i, 0), nc);
}
// canFreelyInvertAllUsersOf
can_freely_invert_all_users_of :: (v: Value_Id, ignored: Value_Id) -> bool {
    u := ir.v_first_use[v];
    while u != NONE {
        us := ir.u_user[u];
        defer u = ir.u_next[u];
        if us == ignored continue;
        if inst_op(us) == {
            case .SELECT;
                if u - ir.v_ops[us] != 0 return false;
                if should_avoid_absorbing_not_into_select(us) return false;
            case .CONDBR;
            case .XOR;
                ok, x := pm_not(us);
                if !ok return false;
            case; return false;
        }
    }
    return true;
}
// freelyInvertAllUsersOf
ic_freely_invert_all_users_of :: (v: Value_Id, ignored: Value_Id = NONE) {
    u := ir.v_first_use[v];
    while u != NONE {
        nu := ir.u_next[u];
        us := ir.u_user[u];
        if us != ignored {
            if inst_op(us) == {
                case .SELECT;
                    use_swap(op_use(us, 1), op_use(us, 2));
                    swap_prof_metadata(us);
                case .CONDBR;
                    swap_successors(us);
                case .XOR;
                    ic_replace_inst_uses_with(us, v);
                    wl_push(us);
                case; fatal("internal: freelyInvertAllUsersOf out of sync");
            }
        }
        u = nu;
    }
    users: [..] u32; users.allocator = temp;
    find_dbg_users(ic.f, v, *users);
    if users.count fatal("instcombine: freelyInvertAllUsersOf with debug users (DW_OP_not) is not supported yet");
}
// canonicalizeICmpPredicate
ic_canonicalize_icmp_predicate :: (i: Value_Id) -> Value_Id {
    p := inst_pred(i);
    if is_canonical_predicate(p) return NONE;
    if !can_freely_invert_all_users_of(i, NONE) return NONE;
    inst(i).pred = cmp_inverse(p);
    set_name(i, tprint("%.not", vname(i)));
    ic_freely_invert_all_users_of(i);
    return i;
}
// visitFCmpInst: operand complexity order, InstSimplify. Not ported: everything after.
ic_visit_fcmp :: (i: Value_Id) -> Value_Id {
    changed := false;
    if ic_complexity(op(i, 0)) < ic_complexity(op(i, 1)) { cmp_swap_operands(i); changed = true; }
    v := simplify_fcmp_inst(inst_pred(i), op(i, 0), op(i, 1), get_fmf(i), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if changed return i;
    return NONE;
}
// visitSelectInst: InstSimplify. Not ported: everything after.
ic_visit_select :: (i: Value_Id) -> Value_Id {
    fmf: u32 = 0;
    if is_fp_math_inst(i) fmf = get_fmf(i);
    v := simplify_select_inst(op(i, 0), op(i, 1), op(i, 2), fmf, ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    return NONE;
}
// visitPHINode: InstSimplify. Not ported: everything after.
ic_visit_phi :: (i: Value_Id) -> Value_Id { return ic_visit_simplify_only(i); }
// visitGetElementPtrInst: InstSimplify. Not ported: everything after.
ic_visit_gep :: (i: Value_Id) -> Value_Id { return ic_visit_simplify_only(i); }
// visitLoadInst: InstSimplify. Not ported: everything after.
ic_visit_load :: (i: Value_Id) -> Value_Id { return ic_visit_simplify_only(i); }
// visitFreeze: InstSimplify, foldOpIntoPhi. Not ported: everything after.
ic_visit_freeze :: (i: Value_Id) -> Value_Id {
    v := simplify_freeze_inst(op(i, 0), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if is_phi(op(i, 0)) { r := ic_fold_op_into_phi(i, op(i, 0)); if r != NONE return r; }
    return NONE;
}
// visitExtractValueInst: no indices, InstSimplify. Not ported: everything after.
ic_visit_extract_value :: (i: Value_Id) -> Value_Id {
    if inst(i).nidx == 0 return ic_replace_inst_uses_with(i, op(i, 0));
    return ic_visit_simplify_only(i);
}

// commonCastTransforms: InstSimplify, cast-of-cast elimination, FoldOpIntoSelect, foldOpIntoPhi.
// Not ported: the shuffle canonicalization and every visitTrunc/ZExt/... specific fold.
ic_visit_cast :: (i: Value_Id) -> Value_Id {
    src := op(i, 0);
    ty := vtype(i);
    opc := inst_op(i);
    v := simplify_cast_inst(opc, src, ty, ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if is_inst(src) && is_cast_op(inst_op(src)) {
        nopc := ic_is_eliminable_cast_pair(src, i);
        if nopc != .NONE_OP {
            if has_one_use(src) {
                users: [..] u32; users.allocator = temp;
                find_dbg_users(ic.f, src, *users);
                if users.count fatal("instcombine: replaceAllDbgUsesWith of an eliminated cast is not supported yet");
            }
            return create_cast(nopc, op(src, 0), ty);
        }
    }
    if is_inst(src) && inst_op(src) == .SELECT {
        cmp := op(src, 0);
        if !is_cmp_inst(cmp) || vtype(op(cmp, 0)) != vtype(src) || (opc == .TRUNC && ic_should_change_type(vtype(src), ty)) {
            okb, x := pm_elementwise_bitcast(i);
            if opc != .BITCAST || okb {
                nv := ic_fold_op_into_select(i, src);
                if nv != NONE {
                    users: [..] u32; users.allocator = temp;
                    find_dbg_users(ic.f, src, *users);
                    if users.count fatal("instcombine: replaceAllDbgUsesWith of a select folded into a cast is not supported yet");
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
    return NONE;
}
// InstCombinerImpl::isEliminableCastPair
ic_is_eliminable_cast_pair :: (ci1: Value_Id, ci2: Value_Id) -> Opcode {
    src := vtype(op(ci1, 0)); mid := vtype(ci1); dst := vtype(ci2);
    res := is_eliminable_cast_pair_dl(inst_op(ci1), inst_op(ci2), src, mid, dst);
    if res == .INTTOPTR && (!is_ptr_or_ptr_vector(dst) || src != irb_int_ptr_type(dst)) res = .NONE_OP;
    if res == .PTRTOINT && (!is_ptr_or_ptr_vector(src) || dst != irb_int_ptr_type(src)) res = .NONE_OP;
    return res;
}

// visitCallInst: InstSimplify (calls with uses), the nounwind inference. Not ported: everything after.
ic_visit_call :: (i: Value_Id) -> Value_Id {
    if has_uses(i) {
        args: [..] Value_Id; args.allocator = temp;
        n := call_num_args(i);
        if n > 0 for k: 0..n-1 array_add(*args, op(i, k));
        v := simplify_call(i, call_callee(i), args, ic_q(i));
        if v != NONE return ic_replace_inst_uses_with(i, v);
    }
    if get_freed_operand(i) != NONE fatal("instcombine: visitFree is not supported yet");
    if fn_has_fn_attr(ic.f, .NoUnwind) && !call_has_fn_attr(i, .NoUnwind) {
        call_add_fn_attr(i, .NoUnwind);
        return i;
    }
    return NONE;
}
// CallBase::addFnAttr(Kind)
call_add_fn_attr :: (i: Value_Id, k: Attr_Kind) {
    l := inst(i).attrs;
    fs := attr_list_fn(l);
    items: [..] Attr; items.allocator = temp;
    for attr_set_items(fs) array_add(*items, it);
    a: Attr; a.kind = k; a.ty = NONE;
    array_add(*items, a);
    nfs := attr_set_get(items);
    inst(i).attrs = attr_list_with_fn(l, nfs);
}

// ---------------------------------------------------------------- terminators (InstructionCombining.cpp)

// visitReturnInst. Not ported: simplifyNonNullOperand and SimplifyDemandedFPClass (fail loudly when they apply).
ic_visit_return :: (i: Value_Id) -> Value_Id {
    if nops(i) == 0 return NONE;
    rv := op(i, 0);
    rt := vtype(rv);
    f := ic.f;
    ret_attrs := attr_list_ret(glob(f).attrs);
    if is_ptr_type(rt) {
        has_deref := attr_set_has(ret_attrs, .Dereferenceable);
        if attr_set_has(ret_attrs, .NonNull) || (has_deref && !null_pointer_is_defined(f, ir.types[rt].a))
            if !is_const(rv) && !is_argument(rv) fatal("instcombine: simplifyNonNullOperand (nonnull return) is not supported yet");
    }
    if attr_set_has(ret_attrs, .NoFPClass) fatal("instcombine: SimplifyDemandedFPClass (nofpclass return) is not supported yet");
    return NONE;
}

// removeInstructionsBeforeUnreachable / visitUnreachableInst
ic_visit_unreachable :: (i: Value_Id) -> Value_Id {
    while true {
        prev := inst(i).prev;
        if prev == NONE break;
        if is_eh_pad(prev) break;
        if !is_guaranteed_to_transfer_execution(prev) break;
        ic_replace_inst_uses_with(prev, const_poison(vtype(prev)));
        ic_erase_inst(prev);
    }
    return NONE;
}

// visitUncondBrInst (mergeStoreIntoSuccessor is not ported: fail loudly when its preconditions hold)
ic_visit_uncond_br :: (i: Value_Id) -> Value_Id {
    first := block_first(inst_block(i));
    x := i;
    while true {
        if x != first x = inst(x).prev;
        if x == first || !is_debug_or_pseudo_inst(x) break;
    }
    if inst_op(x) == .STORE && x != i && ic_merge_store_into_successor(x) return i;
    return NONE;
}

// mergeStoreIntoSuccessor (InstCombineLoadStoreAlloca.cpp)
ic_merge_store_into_successor :: (si: Value_Id) -> bool {
    if !is_unordered(si) return false;
    store_bb := inst_block(si);
    dest := get_successor(block_terminator(store_bb), 0);
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(dest, *preds);
    if preds.count != 2 return false;
    other_bb := preds[0];
    if other_bb == store_bb other_bb = preds[1];
    if store_bb == dest || other_bb == dest return false;
    bbi := block_terminator(other_bb);
    if bbi == block_first(other_bb) return false;
    mergeable :: (os: Value_Id, si: Value_Id) -> bool {
        if os == NONE || !is_inst(os) || inst_op(os) != .STORE || op(os, 1) != op(si, 1) return false;
        st := vtype(op(si, 0)); ot := vtype(op(os, 0));
        if st != ot fatal("instcombine: mergeStoreIntoSuccessor with differently typed stores is not supported yet");
        a := inst(si); b := inst(os);
        return (a.flags & F_VOLATILE) == (b.flags & F_VOLATILE) && a.align == b.align && a.ord1 == b.ord1 && a.sync == b.sync;
    }
    other: Value_Id = NONE;
    if inst_op(bbi) == .BR {
        bbi = inst(bbi).prev;
        while is_debug_or_pseudo_inst(bbi) {
            if bbi == block_first(other_bb) return false;
            bbi = inst(bbi).prev;
        }
        other = bbi;
        if !mergeable(other, si) return false;
    } else if inst_op(bbi) == .CONDBR {
        if get_successor(bbi, 0) != store_bb && get_successor(bbi, 1) != store_bb return false;
        while true {
            if mergeable(bbi, si) { other = bbi; break; }
            if may_read_from_memory(bbi) || may_throw(bbi) || may_write_to_memory(bbi) || bbi == block_first(other_bb) return false;
            bbi = inst(bbi).prev;
        }
        x := block_first(store_bb);
        while x != si {
            if may_read_from_memory(x) || may_throw(x) || may_write_to_memory(x) return false;
            x = inst(x).next;
        }
    } else return false;
    for k: 0..1 {
        s := ifx k == 0 then si else other;
        if get_metadata(s, md_kind_id("tbaa")) != NONE || get_metadata(s, md_kind_id("tbaa.struct")) != NONE ||
           get_metadata(s, md_kind_id("alias.scope")) != NONE || get_metadata(s, md_kind_id("noalias")) != NONE ||
           get_metadata(s, md_kind_id("DIAssignID")) != NONE
            fatal("instcombine: mergeStoreIntoSuccessor with AA metadata or DIAssignID is not supported yet");
    }
    merged_val := op(other, 0);
    merged_loc := merged_debug_loc(get_metadata(si, 0), get_metadata(other, 0));
    if merged_val != op(si, 0) {
        pn := create_phi(vtype(op(si, 0)), 2);
        set_name(pn, "storemerge");
        phi_add_incoming(pn, op(si, 0), inst_block(si));
        icb_set_insert_point(other);
        phi_add_incoming(pn, icb_bit_or_pointer_cast(merged_val, vtype(pn)), other_bb);
        merged_val = ic_insert_new_inst_before(pn, block_first(dest));
        set_metadata(pn, 0, merged_loc);
    }
    pos := block_first_insertion_pt(dest);
    nsi := new_inst(.STORE, ir.t_void, 2);
    set_op(nsi, 0, merged_val); set_op(nsi, 1, op(si, 1));
    r := inst(nsi); src := inst(si);
    r.align = src.align; r.flags = src.flags & cast(u32) F_VOLATILE; r.ord1 = src.ord1; r.sync = src.sync;
    if pos == NONE { ic_link_at_end(nsi, dest); wl_add(nsi); }
    else ic_insert_new_inst_before(nsi, pos);
    set_metadata(nsi, 0, merged_loc);
    ic_erase_inst(si);
    ic_erase_inst(other);
    return true;
}
// CreateBitOrPointerCast
icb_bit_or_pointer_cast :: (v: Value_Id, t: Type_Id) -> Value_Id {
    if vtype(v) == t return v;
    st := vtype(v);
    if is_ptr_or_ptr_vector(st) && !is_ptr_or_ptr_vector(t) return icb_cast(.PTRTOINT, v, t);
    if !is_ptr_or_ptr_vector(st) && is_ptr_or_ptr_vector(t) return icb_cast(.INTTOPTR, v, t);
    return icb_cast(.BITCAST, v, t);
}

// CondBrInst::swapSuccessors (+ Instruction::swapProfMetadata)
swap_successors :: (br: Value_Id) {
    use_swap(op_use(br, 1), op_use(br, 2));
    swap_prof_metadata(br);
}
swap_prof_metadata :: (i: Value_Id) {
    k := md_kind_id("prof");
    m := get_metadata(i, k);
    if m == NONE return;
    if ir.mds[m].kind != .TUPLE || ir.mds[m].nops < 1 return;
    tag := md_op(m, 0);
    if tag == NONE || ir.mds[tag].kind != .STRING || ir.mds[tag].str != "branch_weights" return;
    first: u32 = 1;
    if ir.mds[m].nops > 1 { e := md_op(m, 1); if e != NONE && ir.mds[e].kind == .STRING && ir.mds[e].str == "expected" first = 2; }
    if ir.mds[m].nops != 2 + first return;
    ops: [..] Md_Id; ops.allocator = temp;
    for x: 0..first-1 array_add(*ops, md_op(m, x));
    array_add(*ops, md_op(m, first + 1));
    array_add(*ops, md_op(m, first));
    set_metadata(i, k, md_tuple(ops, false));
}

// addDeadEdge / handleUnreachableFrom / handlePotentiallyDeadBlocks / handlePotentiallyDeadSuccessors
ic_add_dead_edge :: (from: Value_Id, to: Value_Id, work: *[..] Value_Id) {
    key := edge_key(from, to);
    if table_contains(*ic.dead_edges, key) return;
    table_set(*ic.dead_edges, key, true);
    for p: block_insts(to) {
        if inst_op(p) != .PHI break;
        for k: 0..cast(s64) nops(p) - 1 {
            if phi_block(p, cast(u32) k) == from && !pm_poison(op(p, cast(u32) k)) {
                ic_replace_use(op_use(p, cast(u32) k), const_poison(vtype(p)));
                wl_push(p);
                ic.made_ir_change = true;
            }
        }
    }
    array_add(work, to);
}
ic_handle_unreachable_from :: (i: Value_Id, work: *[..] Value_Id) {
    bb := inst_block(i);
    term := block_terminator(bb);
    // instructions from the one before the terminator back to i, in reverse order
    x := inst(term).prev;
    stop := inst(i).prev;
    while x != stop && x != NONE {
        prev := inst(x).prev;
        if has_uses(x) && type_kind(vtype(x)) != .TOKEN { ic_replace_inst_uses_with(x, const_poison(vtype(x))); ic.made_ir_change = true; }
        if !(is_eh_pad(x) || type_kind(vtype(x)) == .TOKEN) {
            drop_dbg_records(x);
            ic_erase_inst(x);
            ic.made_ir_change = true;
        }
        x = prev;
    }
    // handleUnreachableTerminator
    drop_dbg_records(term);
    changed: [..] Value_Id; changed.allocator = temp;
    for k: 0..cast(s64) nops(term) - 1 {
        o := op(term, cast(u32) k);
        if is_inst(o) && type_kind(vtype(o)) != .TOKEN { set_op(term, cast(u32) k, const_poison(vtype(o))); array_add(*changed, o); }
    }
    if changed.count { ic.made_ir_change = true; for changed wl_add(it); }
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb, *succs);
    for s: succs ic_add_dead_edge(bb, s, work);
}
ic_handle_potentially_dead_blocks :: (work: *[..] Value_Id) {
    preds: [..] Value_Id; preds.allocator = temp;
    while work.count {
        bb := pop(work);
        preds.count = 0;
        block_predecessors(bb, *preds);
        all := true;
        for p: preds if !(table_contains(*ic.dead_edges, edge_key(p, bb)) || dt_dominates(ic.dt, bb, p)) { all = false; break; }
        if !all continue;
        ic_handle_unreachable_from(block_first(bb), work);
    }
}
ic_handle_potentially_dead_successors :: (bb: Value_Id, live: Value_Id) {
    work: [..] Value_Id; work.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb, *succs);
    for s: succs { if s == live continue; ic_add_dead_edge(bb, s, *work); }
    ic_handle_potentially_dead_blocks(*work);
}

// visitCondBrInst
ic_visit_cond_br :: (i: Value_Id) -> Value_Id {
    cond := op(i, 0);
    okn, x := pm_not(cond);
    if okn && !is_const(x) {
        swap_successors(i);
        return ic_replace_operand(i, 0, x);
    }
    if is_inst(cond) && inst_op(cond) == .SELECT && has_one_use(cond) {
        okl, lx, nly := pm_logical_and(cond);
        if okl && has_one_use(nly) {
            okn2, y := pm_not(nly);
            if okn2 {
                notx := icb_not(lx, tprint("not.%", vname(lx)));
                or := icb_select(notx, get_true(vtype(notx)), y);
                if is_inst(or) && get_metadata(cond, md_kind_id("prof")) != NONE fatal("instcombine: branch weights of a canonicalized logical and are not supported yet");
                swap_successors(i);
                return ic_replace_operand(i, 0, or);
            }
        }
    }
    if vkind(cond) != .C_INT && get_successor(i, 0) == get_successor(i, 1)
        return ic_replace_operand(i, 0, get_false(vtype(cond)));
    okf, pred, a, b := pm_fcmp(cond);
    if okf && has_one_use(cond) && !is_canonical_predicate(pred) {
        inst(cond).pred = cmp_inverse(pred);
        swap_successors(i);
        wl_push(cond);
        return i;
    }
    if pm_undef_value(cond) { ic_handle_potentially_dead_successors(inst_block(i), NONE); return NONE; }
    if vkind(cond) == .C_INT {
        cv := !ap_is_zero(const_ap(cond));
        ic_handle_potentially_dead_successors(inst_block(i), get_successor(i, ifx cv then cast(u32) 0 else 1));
        return NONE;
    }
    if !is_const(cond) && get_successor(i, 0) != get_successor(i, 1) {
        bb := inst_block(i);
        u := ir.v_first_use[cond];
        while u != NONE {
            nu := ir.u_next[u];
            if dt_dominates_edge_use(ic.dt, bb, get_successor(i, 0), u) {
                user := ir.u_user[u];
                ic_replace_use(u, get_true(vtype(cond)));
                wl_add(user);
            } else if dt_dominates_edge_use(ic.dt, bb, get_successor(i, 1), u) {
                user := ir.u_user[u];
                ic_replace_use(u, get_false(vtype(cond)));
                wl_add(user);
            }
            u = nu;
        }
    }
    dc_register_branch(*ic.dc, i);
    return NONE;
}
