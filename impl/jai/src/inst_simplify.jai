// InstructionSimplify: a port of llvm/lib/Analysis/InstructionSimplify.cpp. The simplify_* procedures return the
// simpler value an instruction (or opcode + operands) folds to, or NONE when LLVM's would return nullptr. They never
// create instructions; they may create constants. `max_recurse` is LLVM's MaxRecurse (RecursionLimit = 3).
//
// Entry points for passes: simplify_instruction(i, q), simplify_instruction_with_operands(i, ops, q),
// simplify_binop(opc, a, b, q), simplify_cmp_inst(pred, a, b, q), simplify_cast_inst, simplify_gep_inst,
// simplify_select_inst, simplify_phi_node, simplify_call ... (all take a Simplify_Query; see analysis_base.jai).

RECURSION_LIMIT :: 3;

get_false :: (t: Type_Id) -> Value_Id { return const_int(t, 0); }   // ConstantInt::getFalse (splat for vectors)
get_true :: (t: Type_Id) -> Value_Id { return const_int(t, 1); }
const_null_of :: (v: Value_Id) -> Value_Id { return const_null_value(vtype(v)); }
const_all_ones_of :: (t: Type_Id) -> Value_Id { return cf_all_ones(t); }
const_int_of :: (t: Type_Id, v: u64) -> Value_Id { return const_int(t, v); }   // ConstantInt::get(Ty, uint64)

// isSameCompare
is_same_compare :: (v: Value_Id, pred: u8, lhs: Value_Id, rhs: Value_Id) -> bool {
    if !is_cmp_inst(v) return false;
    cp := inst_pred(v);
    cl := op(v, 0); cr := op(v, 1);
    if cp == pred && cl == lhs && cr == rhs return true;
    return cp == cmp_swapped(pred) && cl == rhs && cr == lhs;
}
// simplifyCmpSelCase
simplify_cmp_sel_case :: (pred: u8, ss: bool, lhs: Value_Id, rhs: Value_Id, cond: Value_Id, q: Simplify_Query, max_recurse: u32, true_or_false: Value_Id) -> Value_Id {
    sc := simplify_cmp_inst_r(pred, ss, lhs, rhs, q, max_recurse);
    if sc == cond return true_or_false;
    if sc == NONE && is_same_compare(cond, pred, lhs, rhs) return true_or_false;
    return sc;
}
// handleOtherCmpSelSimplifications
handle_other_cmp_sel_simplifications :: (tcmp: Value_Id, fcmp: Value_Id, cond: Value_Id, q: Simplify_Query, max_recurse: u32) -> Value_Id {
    if pm_zero(fcmp) && implies_poison(tcmp, cond) {
        v := simplify_and_inst(cond, tcmp, q, max_recurse);
        if v != NONE return v;
    }
    if pm_one(tcmp) && implies_poison(fcmp, cond) {
        v := simplify_or_inst(cond, fcmp, q, max_recurse);
        if v != NONE return v;
    }
    if pm_one(fcmp) && pm_zero(tcmp) {
        v := simplify_xor_inst(cond, cf_all_ones(vtype(cond)), q, max_recurse);
        if v != NONE return v;
    }
    return NONE;
}
// valueDominatesPHI
value_dominates_phi :: (v: Value_Id, p: Value_Id, dt: *Dom_Tree) -> bool {
    if !is_inst(v) return true;
    if dt return dt_dominates_inst(dt, v, p);
    b := inst_block(v);
    if b == fn_entry(block_fn(b)) && inst_op(v) != .INVOKE && inst_op(v) != .CALLBR return true;
    return false;
}
// expandBinOp
expand_binop :: (opc: Opcode, v: Value_Id, other: Value_Id, opc_to_expand: Opcode, q: Simplify_Query, max_recurse: u32) -> Value_Id {
    if !is_binary_operator(v) || inst_op(v) != opc_to_expand return NONE;
    b0 := op(v, 0); b1 := op(v, 1);
    l := simplify_binop_r(opc, b0, other, sq_without_undef(q), max_recurse);
    if l == NONE return NONE;
    r := simplify_binop_r(opc, b1, other, sq_without_undef(q), max_recurse);
    if r == NONE return NONE;
    if (l == b0 && r == b1) || (is_commutative_op(opc_to_expand) && l == b1 && r == b0) return v;
    s := simplify_binop_r(opc_to_expand, l, r, q, max_recurse);
    if s == NONE return NONE;
    return s;
}
// expandCommutativeBinOp
expand_commutative_binop :: (opc: Opcode, l: Value_Id, r: Value_Id, opc_to_expand: Opcode, q: Simplify_Query, max_recurse_in: u32) -> Value_Id {
    if max_recurse_in == 0 return NONE;
    max_recurse := max_recurse_in - 1;
    v := expand_binop(opc, l, r, opc_to_expand, q, max_recurse);
    if v != NONE return v;
    v = expand_binop(opc, r, l, opc_to_expand, q, max_recurse);
    if v != NONE return v;
    return NONE;
}
// simplifyAssociativeBinOp
simplify_associative_binop :: (opc: Opcode, lhs: Value_Id, rhs: Value_Id, q: Simplify_Query, max_recurse_in: u32) -> Value_Id {
    if max_recurse_in == 0 return NONE;
    max_recurse := max_recurse_in - 1;
    op0_ok := is_binary_operator(lhs) && inst_op(lhs) == opc;
    op1_ok := is_binary_operator(rhs) && inst_op(rhs) == opc;
    if op0_ok {
        a := op(lhs, 0); b := op(lhs, 1); c := rhs;
        v := simplify_binop_r(opc, b, c, q, max_recurse);
        if v != NONE {
            if v == b return lhs;
            w := simplify_binop_r(opc, a, v, q, max_recurse);
            if w != NONE return w;
        }
    }
    if op1_ok {
        a := lhs; b := op(rhs, 0); c := op(rhs, 1);
        v := simplify_binop_r(opc, a, b, q, max_recurse);
        if v != NONE {
            if v == b return rhs;
            w := simplify_binop_r(opc, v, c, q, max_recurse);
            if w != NONE return w;
        }
    }
    if !is_commutative_op(opc) return NONE;
    if op0_ok {
        a := op(lhs, 0); b := op(lhs, 1); c := rhs;
        v := simplify_binop_r(opc, c, a, q, max_recurse);
        if v != NONE {
            if v == a return lhs;
            w := simplify_binop_r(opc, v, b, q, max_recurse);
            if w != NONE return w;
        }
    }
    if op1_ok {
        a := lhs; b := op(rhs, 0); c := op(rhs, 1);
        v := simplify_binop_r(opc, c, a, q, max_recurse);
        if v != NONE {
            if v == c return rhs;
            w := simplify_binop_r(opc, b, v, q, max_recurse);
            if w != NONE return w;
        }
    }
    return NONE;
}
is_select_inst :: inline (v: Value_Id) -> bool { return is_inst(v) && inst_op(v) == .SELECT; }
// threadBinOpOverSelect
thread_binop_over_select :: (opc: Opcode, lhs: Value_Id, rhs: Value_Id, q: Simplify_Query, max_recurse_in: u32) -> Value_Id {
    if max_recurse_in == 0 return NONE;
    max_recurse := max_recurse_in - 1;
    si := ifx is_select_inst(lhs) then lhs else rhs;
    tv, fv: Value_Id;
    if si == lhs {
        tv = simplify_binop_r(opc, op(si, 1), rhs, q, max_recurse);
        fv = simplify_binop_r(opc, op(si, 2), rhs, q, max_recurse);
    } else {
        tv = simplify_binop_r(opc, lhs, op(si, 1), q, max_recurse);
        fv = simplify_binop_r(opc, lhs, op(si, 2), q, max_recurse);
    }
    if tv == fv return tv;
    if tv != NONE && sq_is_undef_value(q, tv) return fv;
    if fv != NONE && sq_is_undef_value(q, fv) return tv;
    if tv == op(si, 1) && fv == op(si, 2) return si;
    if (fv != NONE && tv == NONE) || (tv != NONE && fv == NONE) {
        simplified := ifx fv != NONE then fv else tv;
        if is_inst(simplified) && inst_op(simplified) == opc && !has_poison_generating_flags(simplified) {
            unsimplified_branch := ifx fv != NONE then op(si, 1) else op(si, 2);
            ul := ifx si == lhs then unsimplified_branch else lhs;
            ur := ifx si == lhs then rhs else unsimplified_branch;
            if op(simplified, 0) == ul && op(simplified, 1) == ur return simplified;
            if is_commutative_op(inst_op(simplified)) && op(simplified, 1) == ul && op(simplified, 0) == ur return simplified;
        }
    }
    return NONE;
}
// threadCmpOverSelect
thread_cmp_over_select :: (pred_in: u8, ss: bool, lhs_in: Value_Id, rhs_in: Value_Id, q: Simplify_Query, max_recurse_in: u32) -> Value_Id {
    if max_recurse_in == 0 return NONE;
    max_recurse := max_recurse_in - 1;
    pred := pred_in; lhs := lhs_in; rhs := rhs_in;
    if !is_select_inst(lhs) { t := lhs; lhs = rhs; rhs = t; pred = cmp_swapped(pred); }
    si := lhs;
    cond := op(si, 0); tv := op(si, 1); fv := op(si, 2);
    tcmp := simplify_cmp_sel_case(pred, ss, tv, rhs, cond, q, max_recurse, get_true(vtype(cond)));
    if tcmp == NONE return NONE;
    fcmp := simplify_cmp_sel_case(pred, ss, fv, rhs, cond, q, max_recurse, get_false(vtype(cond)));
    if fcmp == NONE return NONE;
    if tcmp == fcmp return tcmp;
    if is_vector_type(vtype(cond)) == is_vector_type(vtype(rhs)) return handle_other_cmp_sel_simplifications(tcmp, fcmp, cond, q, max_recurse);
    return NONE;
}
// threadBinOpOverPHI
thread_binop_over_phi :: (opc: Opcode, lhs: Value_Id, rhs: Value_Id, q: Simplify_Query, max_recurse_in: u32) -> Value_Id {
    if max_recurse_in == 0 return NONE;
    max_recurse := max_recurse_in - 1;
    pi: Value_Id;
    if is_phi(lhs) {
        pi = lhs;
        if !value_dominates_phi(rhs, pi, q.dt) return NONE;
    } else {
        pi = rhs;
        if !value_dominates_phi(lhs, pi, q.dt) return NONE;
    }
    common: Value_Id = NONE;
    n := nops(pi);
    for k: 0..n-1 {
        inc := phi_value(pi, k);
        if inc == pi continue;
        ti := block_terminator(phi_block(pi, k));
        v := ifx pi == lhs then simplify_binop_r(opc, inc, rhs, sq_with_instruction(q, ti), max_recurse)
             else simplify_binop_r(opc, lhs, inc, sq_with_instruction(q, ti), max_recurse);
        if v == NONE || (common != NONE && v != common) return NONE;
        common = v;
    }
    return common;
}
// threadCmpOverPHI
thread_cmp_over_phi :: (pred_in: u8, ss: bool, lhs_in: Value_Id, rhs_in: Value_Id, q: Simplify_Query, max_recurse_in: u32) -> Value_Id {
    if max_recurse_in == 0 return NONE;
    max_recurse := max_recurse_in - 1;
    pred := pred_in; lhs := lhs_in; rhs := rhs_in;
    if !is_phi(lhs) { t := lhs; lhs = rhs; rhs = t; pred = cmp_swapped(pred); }
    pi := lhs;
    if !value_dominates_phi(rhs, pi, q.dt) return NONE;
    common: Value_Id = NONE;
    n := nops(pi);
    for k: 0..n-1 {
        inc := phi_value(pi, k);
        ti := block_terminator(phi_block(pi, k));
        if inc == pi continue;
        v := simplify_cmp_inst_r(pred, ss, inc, rhs, sq_with_instruction(q, ti), max_recurse);
        if v == NONE || (common != NONE && v != common) return NONE;
        common = v;
    }
    return common;
}
// foldOrCommuteConstant: (folded constant or NONE, op0, op1 possibly swapped)
fold_or_commute_constant :: (opc: Opcode, op0: Value_Id, op1: Value_Id, q: Simplify_Query) -> (Value_Id, Value_Id, Value_Id) {
    if is_const(op0) {
        if is_const(op1) {
            if opc == .FADD || opc == .FSUB || opc == .FMUL || opc == .FDIV || opc == .FREM {
                if q.cxt != NONE return cfo_fp_inst_operands(opc, op0, op1, q.cxt), op0, op1;
            }
            return cfo_binary_op_operands(opc, op0, op1), op0, op1;
        }
        if is_commutative_op(opc) return NONE, op1, op0;
    }
    return NONE, op0, op1;
}

// ---------------------------------------------------------------- add / sub / mul

simplify_add_inst :: (op0_in: Value_Id, op1_in: Value_Id, is_nsw: bool, is_nuw: bool, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    c, op0, op1 := fold_or_commute_constant(.ADD, op0_in, op1_in, q);
    if c != NONE return c;
    if pm_poison(op1) return op1;
    if sq_is_undef_value(q, op1) return op1;
    if pm_zero(op1) return op0;
    if is_known_negation(op0, op1) return const_null_of(op0);
    oks, sy, sx := pm_binop(op1, .SUB);
    if oks && sx == op0 return sy;
    oks, sy, sx = pm_binop(op0, .SUB);
    if oks && sx == op1 return sy;
    ty := vtype(op0);
    okn, nx := pm_not(op0);
    okn2, nx2 := pm_not(op1);
    if (okn && nx == op1) || (okn2 && nx2 == op0) return cf_all_ones(ty);
    if (is_nsw || is_nuw) && pm_sign_mask(op1) {
        okx, xa, xb := pm_binop(op0, .XOR);
        if okx && pm_sign_mask(xb) return xa;
    }
    if is_nuw && pm_all_ones(op1) return op1;
    if max_recurse > 0 && is_bool_ty(vtype(op0)) {
        v := simplify_xor_inst(op0, op1, q, max_recurse - 1);
        if v != NONE return v;
    }
    v := simplify_associative_binop(.ADD, op0, op1, q, max_recurse);
    if v != NONE return v;
    return NONE;
}
// stripAndComputeConstantOffsets
strip_and_compute_constant_offsets :: (v: *Value_Id) -> APInt {
    off := ap_zero(dl_index_bits(vtype(v.*)));
    nv, o := strip_and_accumulate_constant_offsets(v.*, off, true);
    v.* = nv;
    return ap_sext_or_trunc(o, dl_index_bits(vtype(nv)));
}
// computePointerDifference
compute_pointer_difference :: (lhs_in: Value_Id, rhs_in: Value_Id) -> Value_Id {
    lhs := lhs_in; rhs := rhs_in;
    lo := strip_and_compute_constant_offsets(*lhs);
    ro := strip_and_compute_constant_offsets(*rhs);
    if lhs != rhs return NONE;
    d := ap_sub(lo, ro);
    res := cf_int(type_int(d.bits), d);
    if is_vector_type(vtype(lhs)) res = cf_get_splat(vector_with_elt(vtype(lhs), type_int(d.bits)), res);
    return res;
}
// simplifyByDomEq
simplify_by_dom_eq :: (opc: Opcode, op0: Value_Id, op1: Value_Id, q: Simplify_Query, max_recurse: u32) -> Value_Id {
    if max_recurse != RECURSION_LIMIT return NONE;
    imp := is_implied_by_dom_condition_pred(ICMP_EQ, false, op0, op1, q.cxt);
    if imp == 1 {
        ty := vtype(op0);
        if opc == .SUB || opc == .XOR || opc == .UREM || opc == .SREM return const_null_value(ty);
        if opc == .SDIV || opc == .UDIV return const_int(ty, 1);
        if opc == .AND || opc == .OR return op1;
    }
    return NONE;
}
simplify_sub_inst :: (op0_in: Value_Id, op1_in: Value_Id, is_nsw: bool, is_nuw: bool, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    c, op0, op1 := fold_or_commute_constant(.SUB, op0_in, op1_in, q);
    if c != NONE return c;
    if pm_poison(op0) || pm_poison(op1) return const_poison(vtype(op0));
    if sq_is_undef_value(q, op0) || sq_is_undef_value(q, op1) return const_undef(vtype(op0));
    if pm_zero(op1) return op0;
    if op0 == op1 return const_null_of(op0);
    if pm_zero(op0) {
        if is_nuw return const_null_of(op0);
        known := known_bits(op1, q);
        if ap_is_max_signed(known.zero) {
            if is_nsw return const_null_of(op0);
            return op1;
        }
    }
    if max_recurse > 0 {
        oka, x, y := pm_binop(op0, .ADD);
        if oka {
            z := op1;
            v := simplify_binop_r(.SUB, y, z, q, max_recurse - 1);
            if v != NONE { w := simplify_binop_r(.ADD, x, v, q, max_recurse - 1); if w != NONE return w; }
            v = simplify_binop_r(.SUB, x, z, q, max_recurse - 1);
            if v != NONE { w := simplify_binop_r(.ADD, y, v, q, max_recurse - 1); if w != NONE return w; }
        }
        x2 := op0;
        oka2, y2, z2 := pm_binop(op1, .ADD);
        if oka2 {
            v := simplify_binop_r(.SUB, x2, y2, q, max_recurse - 1);
            if v != NONE { w := simplify_binop_r(.SUB, v, z2, q, max_recurse - 1); if w != NONE return w; }
            v = simplify_binop_r(.SUB, x2, z2, q, max_recurse - 1);
            if v != NONE { w := simplify_binop_r(.SUB, v, y2, q, max_recurse - 1); if w != NONE return w; }
        }
        z3 := op0;
        oks3, x3, y3 := pm_binop(op1, .SUB);
        if oks3 {
            v := simplify_binop_r(.SUB, z3, x3, q, max_recurse - 1);
            if v != NONE { w := simplify_binop_r(.ADD, v, y3, q, max_recurse - 1); if w != NONE return w; }
        }
        okt1, tx := pm_cast(op0, .TRUNC);
        okt2, ty := pm_cast(op1, .TRUNC);
        if okt1 && okt2 && vtype(tx) == vtype(ty) {
            v := simplify_binop_r(.SUB, tx, ty, q, max_recurse - 1);
            if v != NONE { w := simplify_cast_inst_r(.TRUNC, v, vtype(op0), q, max_recurse - 1); if w != NONE return w; }
        }
    }
    okp1, px := pm_ptrtoint_or_addr(op0);
    okp2, py := pm_ptrtoint_or_addr(op1);
    if okp1 && okp2 {
        r := compute_pointer_difference(px, py);
        if r != NONE return cfo_integer_cast(r, vtype(op0), true);
    }
    if max_recurse > 0 && is_bool_ty(vtype(op0)) {
        v := simplify_xor_inst(op0, op1, q, max_recurse - 1);
        if v != NONE return v;
    }
    v := simplify_by_dom_eq(.SUB, op0, op1, q, max_recurse);
    if v != NONE return v;
    if is_nuw {
        okx, xa, xb := pm_binop(op1, .XOR);
        if okx && xb == op0 && pm_low_bit_mask(op0) return xa;
    }
    return NONE;
}
pm_ptrtoint_or_addr :: (v: Value_Id) -> (bool, Value_Id) {
    o := opr_code(v);
    if o == .PTRTOINT || o == .PTRTOADDR return true, op(v, 0);
    return false, NONE;
}
simplify_mul_inst :: (op0_in: Value_Id, op1_in: Value_Id, is_nsw: bool, is_nuw: bool, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    c, op0, op1 := fold_or_commute_constant(.MUL, op0_in, op1_in, q);
    if c != NONE return c;
    if pm_poison(op1) return op1;
    if sq_is_undef_value(q, op1) || pm_zero(op1) return const_null_of(op0);
    if pm_one(op1) return op0;
    if q.use_instr_info {
        exact_idiv_of :: (v: Value_Id, y: Value_Id) -> (bool, Value_Id) {
            o := opr_code(v);
            if (o == .SDIV || o == .UDIV) && (opr_flags(v) & F_EXACT) != 0 && op(v, 1) == y return true, op(v, 0);
            return false, NONE;
        }
        ok1, x1 := exact_idiv_of(op0, op1);
        if ok1 return x1;
        ok2, x2 := exact_idiv_of(op1, op0);
        if ok2 return x2;
    }
    if is_bool_ty(vtype(op0)) {
        if is_nsw return const_null_of(op0);
        if max_recurse > 0 {
            v := simplify_and_inst(op0, op1, q, max_recurse - 1);
            if v != NONE return v;
        }
    }
    v := simplify_associative_binop(.MUL, op0, op1, q, max_recurse);
    if v != NONE return v;
    v = expand_commutative_binop(.MUL, op0, op1, .ADD, q, max_recurse);
    if v != NONE return v;
    if is_select_inst(op0) || is_select_inst(op1) {
        v = thread_binop_over_select(.MUL, op0, op1, q, max_recurse);
        if v != NONE return v;
    }
    if is_phi(op0) || is_phi(op1) {
        v = thread_binop_over_phi(.MUL, op0, op1, q, max_recurse);
        if v != NONE return v;
    }
    return NONE;
}

// ---------------------------------------------------------------- div / rem

// isICmpTrue
is_icmp_true :: (pred: u8, lhs: Value_Id, rhs: Value_Id, q: Simplify_Query, max_recurse: u32) -> bool {
    v := simplify_icmp_inst(pred, false, lhs, rhs, q, max_recurse);
    return v != NONE && is_const(v) && cf_is_all_ones(v);
}
// isDivZero
is_div_zero :: (x: Value_Id, y: Value_Id, q: Simplify_Query, max_recurse_in: u32, is_signed: bool) -> bool {
    if max_recurse_in == 0 return false;
    max_recurse := max_recurse_in - 1;
    if is_signed {
        oks, _, sb := pm_binop(x, .SREM);
        if oks && sb == y return true;
        ty := vtype(x);
        okc, c := pm_apint(x);
        if okc && !ap_is_min_signed(c) {
            pos := cf_int(ty, ap_abs(c));
            neg := cf_int(ty, ap_neg(ap_abs(c)));
            if is_icmp_true(ICMP_SLT, y, neg, q, max_recurse) || is_icmp_true(ICMP_SGT, y, pos, q, max_recurse) return true;
        }
        okc2, c2 := pm_apint(y);
        if okc2 {
            if ap_is_min_signed(c2) return is_icmp_true(ICMP_NE, x, y, q, max_recurse);
            pos := cf_int(ty, ap_abs(c2));
            neg := cf_int(ty, ap_neg(ap_abs(c2)));
            if is_icmp_true(ICMP_SGT, x, neg, q, max_recurse) && is_icmp_true(ICMP_SLT, x, pos, q, max_recurse) return true;
        }
        return false;
    }
    okc, c := pm_apint(y);
    if okc && ap_ult(kb_max_value(known_bits(x, q)), c) return true;
    return is_icmp_true(ICMP_ULT, x, y, q, max_recurse);
}
// simplifyDivRem
simplify_div_rem :: (opc: Opcode, op0: Value_Id, op1: Value_Id, q: Simplify_Query, max_recurse: u32) -> Value_Id {
    is_div := opc == .SDIV || opc == .UDIV;
    is_signed := opc == .SDIV || opc == .SREM;
    ty := vtype(op0);
    if sq_is_undef_value(q, op1) || pm_poison(op1) return const_poison(ty);
    if pm_zero(op1) return const_poison(ty);
    if pm_poison(op0) return op0;
    if sq_is_undef_value(q, op0) return const_null_value(ty);
    if pm_zero(op0) return const_null_value(ty);
    if op0 == op1 return ifx is_div then const_int(ty, 1) else const_null_value(ty);
    known := known_bits(op1, q);
    if kb_is_zero(known) return const_poison(ty);
    if kb_count_min_leading_zeros(known) == kb_bits(known) - 1 return ifx is_div then op0 else const_null_value(ty);
    okm, x := pm_c_binop_with(op0, .MUL, op1);
    if okm {
        sd := opr_code(x) == .SDIV && op(x, 1) == op1;
        ud := opr_code(x) == .UDIV && op(x, 1) == op1;
        if (is_signed && iiq_nsw(q, op0)) || (!is_signed && iiq_nuw(q, op0)) || (is_signed && sd) || (!is_signed && ud)
            return ifx is_div then x else const_null_value(ty);
    }
    if is_div_zero(op0, op1, q, max_recurse, is_signed) return ifx is_div then const_null_value(ty) else op0;
    v := simplify_by_dom_eq(opc, op0, op1, q, max_recurse);
    if v != NONE return v;
    if is_select_inst(op0) || is_select_inst(op1) {
        v = thread_binop_over_select(opc, op0, op1, q, max_recurse);
        if v != NONE return v;
    }
    if is_phi(op0) || is_phi(op1) {
        v = thread_binop_over_phi(opc, op0, op1, q, max_recurse);
        if v != NONE return v;
    }
    return NONE;
}
// simplifyDiv
simplify_div :: (opc: Opcode, op0_in: Value_Id, op1_in: Value_Id, is_exact: bool, q: Simplify_Query, max_recurse: u32) -> Value_Id {
    c, op0, op1 := fold_or_commute_constant(opc, op0_in, op1_in, q);
    if c != NONE return c;
    v := simplify_div_rem(opc, op0, op1, q, max_recurse);
    if v != NONE return v;
    okd, divc := pm_apint(op1);
    if is_exact && okd {
        if ap_ctz(divc) != 0 {
            k := known_bits(op0, q);
            if kb_count_max_trailing_zeros(k) < ap_ctz(divc) return const_poison(vtype(op0));
        }
        if !ap_is_power_of_2(divc) {
            okm, mx, my := pm_binop(op0, .MUL);
            if okm && my == op1 {
                f := opr_flags(op0);
                if (opc == .UDIV && (f & F_NSW) != 0) || (opc != .UDIV && (f & F_NUW) != 0) return mx;
            }
        }
    }
    return NONE;
}
// simplifyRem
simplify_rem :: (opc: Opcode, op0_in: Value_Id, op1_in: Value_Id, q: Simplify_Query, max_recurse: u32) -> Value_Id {
    c, op0, op1 := fold_or_commute_constant(opc, op0_in, op1_in, q);
    if c != NONE return c;
    v := simplify_div_rem(opc, op0, op1, q, max_recurse);
    if v != NONE return v;
    if q.use_instr_info {
        oks, sa, _ := pm_binop(op0, .SHL);
        if oks && sa == op1 {
            f := opr_flags(op0);
            if (opc == .SREM && (f & F_NSW) != 0) || (opc == .UREM && (f & F_NUW) != 0) return const_null_of(op0);
        }
        okc, c0 := pm_apint(op1);
        if okc {
            okm, _, mc := pm_binop(op0, .MUL);
            if okm {
                f := opr_flags(op0);
                if (opc == .SREM && (f & F_NSW) != 0) || (opc == .UREM && (f & F_NUW) != 0) {
                    if pm_int_pred_checked(mc, c0, opc == .SREM) return const_null_of(op0);
                }
            }
        }
    }
    return NONE;
}
// m_CheckedInt([C0](const APInt &C) { return C.srem(*C0).isZero(); }) (poison elements allowed)
pm_int_pred_checked :: (v: Value_Id, c0: APInt, signed: bool) -> bool {
    check :: (c: APInt, c0: APInt, signed: bool) -> bool {
        if signed return ap_is_zero(ap_srem(c, c0));
        return ap_is_zero(ap_urem(c, c0));
    }
    k := vkind(v);
    if k == .C_INT return check(const_ap(v), c0, signed);
    t := vtype(v);
    if !is_vector_type(t) || !is_constant_kind(k) return false;
    s := get_splat_value(v);
    if s != NONE return vkind(s) == .C_INT && check(const_ap(s), c0, signed);
    if type_kind(t) != .VECTOR return false;
    n := type_count(t);
    any := false;
    for i: 0..cast(s64) n - 1 {
        e := cf_elt(v, cast(u64) i);
        if e == NONE return false;
        if vkind(e) == .C_POISON continue;
        if vkind(e) != .C_INT || !check(const_ap(e), c0, signed) return false;
        any = true;
    }
    return any;
}
simplify_sdiv_inst :: (op0: Value_Id, op1: Value_Id, is_exact: bool, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    if is_known_negation(op0, op1, true) return cf_all_ones(vtype(op0));
    return simplify_div(.SDIV, op0, op1, is_exact, q, max_recurse);
}
simplify_udiv_inst :: (op0: Value_Id, op1: Value_Id, is_exact: bool, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    return simplify_div(.UDIV, op0, op1, is_exact, q, max_recurse);
}
simplify_srem_inst :: (op0: Value_Id, op1: Value_Id, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    oks, x := pm_cast(op1, .SEXT);
    if oks && is_bool_ty(vtype(x)) return const_null_of(op0);
    if is_known_negation(op0, op1) return const_null_of(op0);
    return simplify_rem(.SREM, op0, op1, q, max_recurse);
}
simplify_urem_inst :: (op0: Value_Id, op1: Value_Id, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    return simplify_rem(.UREM, op0, op1, q, max_recurse);
}

// ---------------------------------------------------------------- shifts

// isPoisonShift
is_poison_shift :: (amount: Value_Id, q: Simplify_Query) -> bool {
    if amount == NONE || !is_const(amount) return false;
    if sq_is_undef_value(q, amount) return true;
    okc, c := pm_apint(amount);
    if okc && ap_uge_u64(c, c.bits) return true;
    k := vkind(amount);
    if k == .C_VECTOR || k == .C_DATA {
        n := type_count(vtype(amount));
        for i: 0..cast(s64) n - 1 if !is_poison_shift(cf_elt(amount, cast(u64) i), q) return false;
        return true;
    }
    return false;
}
// simplifyShift
simplify_shift :: (opc: Opcode, op0_in: Value_Id, op1_in: Value_Id, is_nsw: bool, q: Simplify_Query, max_recurse: u32) -> Value_Id {
    c, op0, op1 := fold_or_commute_constant(opc, op0_in, op1_in, q);
    if c != NONE return c;
    if pm_poison(op0) return op0;
    if pm_zero(op0) return const_null_of(op0);
    oks, x := pm_cast(op1, .SEXT);
    if pm_zero(op1) || (oks && is_bool_ty(vtype(x))) return op0;
    if is_poison_shift(op1, q) return const_poison(vtype(op0));
    if is_select_inst(op0) || is_select_inst(op1) {
        v := thread_binop_over_select(opc, op0, op1, q, max_recurse);
        if v != NONE return v;
    }
    if is_phi(op0) || is_phi(op1) {
        v := thread_binop_over_phi(opc, op0, op1, q, max_recurse);
        if v != NONE return v;
    }
    known_amt := known_bits(op1, q);
    if ap_uge_u64(kb_min_value(known_amt), kb_bits(known_amt)) return const_poison(vtype(op0));
    valid := log2_ceil_u32(kb_bits(known_amt));
    if kb_count_min_trailing_zeros(known_amt) >= valid return op0;
    if is_nsw {
        kv := known_bits(op0, q);
        ks := kb_shl(kv, known_amt);
        if ap_is_negative(kv.zero) { ks.zero = ap_copy(ks.zero); ap_set_sign_bit(*ks.zero); }
        if ap_is_negative(kv.one) { ks.one = ap_copy(ks.one); ap_set_sign_bit(*ks.one); }
        if kb_has_conflict(ks) return const_poison(vtype(op0));
    }
    return NONE;
}
// simplifyRightShift
simplify_right_shift :: (opc: Opcode, op0: Value_Id, op1: Value_Id, is_exact: bool, q: Simplify_Query, max_recurse: u32) -> Value_Id {
    v := simplify_shift(opc, op0, op1, false, q, max_recurse);
    if v != NONE return v;
    if op0 == op1 return const_null_of(op0);
    if sq_is_undef_value(q, op0) return ifx is_exact then op0 else const_null_of(op0);
    if is_exact {
        k := known_bits(op0, q);
        if ap_get_bit(k.one, 0) return op0;
    }
    return NONE;
}
simplify_shl_inst :: (op0: Value_Id, op1: Value_Id, is_nsw: bool, is_nuw: bool, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    v := simplify_shift(.SHL, op0, op1, is_nsw, q, max_recurse);
    if v != NONE return v;
    ty := vtype(op0);
    if sq_is_undef_value(q, op0) return ifx is_nsw || is_nuw then op0 else const_null_value(ty);
    if q.use_instr_info {
        o := opr_code(op0);
        if (o == .LSHR || o == .ASHR) && (opr_flags(op0) & F_EXACT) != 0 && op(op0, 1) == op1 return op(op0, 0);
    }
    if is_nuw && pm_negative(op0) return op0;
    if is_nsw && is_nuw && pm_specific_int(op1, type_bits(scalar_type(ty)) - 1) return const_null_value(ty);
    return NONE;
}
simplify_lshr_inst :: (op0: Value_Id, op1: Value_Id, is_exact: bool, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    v := simplify_right_shift(.LSHR, op0, op1, is_exact, q, max_recurse);
    if v != NONE return v;
    if q.use_instr_info {
        oks, x, s := pm_binop(op0, .SHL);
        if oks && (opr_flags(op0) & F_NUW) != 0 && s == op1 return x;
    }
    okr, shr := pm_apint(op1);
    if q.use_instr_info && okr && opr_code(op0) == .OR {
        for k: 0..1 {
            sh := op(op0, cast(u32) k); y := op(op0, cast(u32)(1 - k));
            oks, x, sl := pm_binop(sh, .SHL);
            if !oks || (opr_flags(sh) & F_NUW) == 0 continue;
            okl, shl := pm_apint(sl);
            if !okl continue;
            if ap_eq(shr, shl) {
                yk := known_bits(y, q);
                if ap_uge_u64(shr, kb_count_max_active_bits(yk)) return x;
            }
            break;   // m_c_Or matched (the commuted form is only tried when the first doesn't match)
        }
    }
    return NONE;
}
simplify_ashr_inst :: (op0: Value_Id, op1: Value_Id, is_exact: bool, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    v := simplify_right_shift(.ASHR, op0, op1, is_exact, q, max_recurse);
    if v != NONE return v;
    if pm_all_ones(op0) return cf_all_ones(vtype(op0));
    oks, sa, sb := pm_binop(op0, .SHL);
    if oks && pm_all_ones(sa) && sb == op1 return cf_all_ones(vtype(op0));
    if q.use_instr_info && oks && (opr_flags(op0) & F_NSW) != 0 && sb == op1 return sa;
    nsb := num_sign_bits_ctx(op0, q.cxt, q.dt, q.ac);
    if nsb == type_bits(scalar_type(vtype(op0))) return op0;
    return NONE;
}

// ---------------------------------------------------------------- and/or of icmps

// simplifyUnsignedRangeCheck
simplify_unsigned_range_check :: (zero_icmp: Value_Id, unsigned_icmp: Value_Id, is_and: bool, q: Simplify_Query) -> Value_Id {
    ok, eq_pred, _, y, z := pm_icmp(zero_icmp);
    if !ok || !pm_zero(z) || !icmp_is_equality(eq_pred) return NONE;
    oku, up_raw, _, ua, ub := pm_icmp(unsigned_icmp);
    oks, a, b := pm_binop(y, .SUB);
    if oks {
        // m_c_ICmp(UnsignedPred, m_Specific(A), m_Specific(B))
        if oku {
            up := up_raw; matched := false;
            if ua == a && ub == b matched = true;
            else if ua == b && ub == a { matched = true; up = cmp_swapped(up); }
            if matched && icmp_is_unsigned(up) {
                if (up == ICMP_UGE || up == ICMP_ULE) && eq_pred == ICMP_NE && !is_and return get_true(vtype(unsigned_icmp));
                if (up == ICMP_ULT || up == ICMP_UGT) && eq_pred == ICMP_EQ && is_and return get_false(vtype(unsigned_icmp));
                if eq_pred == ICMP_NE && (up == ICMP_ULT || up == ICMP_UGT) return ifx is_and then unsigned_icmp else zero_icmp;
                if eq_pred == ICMP_EQ && (up == ICMP_ULE || up == ICMP_UGE) return ifx is_and then zero_icmp else unsigned_icmp;
            }
            up = up_raw; matched = false;
            if ua == y && ub == a matched = true;
            else if ua == a && ub == y { matched = true; up = cmp_swapped(up); }
            if matched {
                if up == ICMP_UGE && is_and && eq_pred == ICMP_NE && is_known_non_zero(b, q) return unsigned_icmp;
                if up == ICMP_ULT && !is_and && eq_pred == ICMP_EQ && is_known_non_zero(b, q) return unsigned_icmp;
            }
        }
    }
    if !oku return NONE;
    up: u8; x: Value_Id;
    if ub == y && icmp_is_unsigned(up_raw) { up = up_raw; x = ua; }
    else if ua == y && icmp_is_unsigned(up_raw) { up = cmp_swapped(up_raw); x = ub; }
    else return NONE;
    if up == ICMP_UGT && eq_pred == ICMP_EQ && is_known_non_zero(x, q) return ifx is_and then zero_icmp else unsigned_icmp;
    if up == ICMP_ULE && eq_pred == ICMP_NE && is_known_non_zero(x, q) return ifx is_and then unsigned_icmp else zero_icmp;
    if up == ICMP_ULT && eq_pred == ICMP_NE return ifx is_and then unsigned_icmp else zero_icmp;
    if up == ICMP_UGE && eq_pred == ICMP_EQ return ifx is_and then zero_icmp else unsigned_icmp;
    if up == ICMP_ULT && eq_pred == ICMP_EQ && is_and return get_false(vtype(unsigned_icmp));
    if up == ICMP_UGE && eq_pred == ICMP_NE && !is_and return get_true(vtype(unsigned_icmp));
    return NONE;
}
// simplifyAndOrOfICmpsWithConstants
simplify_and_or_of_icmps_with_constants :: (c0: Value_Id, c1: Value_Id, is_and: bool) -> Value_Id {
    if op(c0, 0) != op(c1, 0) return NONE;
    ok0, k0 := pm_apint(op(c0, 1));
    ok1, k1 := pm_apint(op(c1, 1));
    if !ok0 || !ok1 return NONE;
    r0 := cr_exact_icmp_region(inst_pred(c0), k0);
    r1 := cr_exact_icmp_region(inst_pred(c1), k1);
    if is_and && cr_is_empty_set(cr_intersect(r0, r1)) return get_false(vtype(c0));
    if !is_and && cr_is_full_set(cr_union(r0, r1)) return get_true(vtype(c0));
    if cr_contains_range(r0, r1) return ifx is_and then c1 else c0;
    if cr_contains_range(r1, r0) return ifx is_and then c0 else c1;
    return NONE;
}
// simplifyAndOfICmpsWithAdd / simplifyOrOfICmpsWithAdd
simplify_and_or_of_icmps_with_add :: (op0: Value_Id, op1: Value_Id, q: Simplify_Query, is_and: bool) -> Value_Id {
    ok, p0, _, a, c1v := pm_icmp(op0);
    if !ok return NONE;
    oka, v, c0v := pm_binop(a, .ADD);
    if !oka return NONE;
    okc0, c0 := pm_apint(c0v);
    okc1, c1 := pm_apint(c1v);
    if !okc0 || !okc1 return NONE;
    ok1, p1, _, b0, _ := pm_icmp(op1);
    if !ok1 || b0 != v return NONE;
    if op(a, 1) != op(op1, 1) return NONE;
    ity := vtype(op0);
    nsw := iiq_nsw(q, a); nuw := iiq_nuw(q, a);
    delta := ap_sub(c1, c0);
    if is_and {
        if ap_is_strictly_positive(c0) {
            if ap_eq_u64(delta, 2) {
                if p0 == ICMP_ULT && p1 == ICMP_SGT return get_false(ity);
                if p0 == ICMP_SLT && p1 == ICMP_SGT && nsw return get_false(ity);
            }
            if ap_eq_u64(delta, 1) {
                if p0 == ICMP_ULE && p1 == ICMP_SGT return get_false(ity);
                if p0 == ICMP_SLE && p1 == ICMP_SGT && nsw return get_false(ity);
            }
        }
        if !ap_is_zero(c0) && nuw {
            if ap_eq_u64(delta, 2) && p0 == ICMP_ULT && p1 == ICMP_UGT return get_false(ity);
            if ap_eq_u64(delta, 1) && p0 == ICMP_ULE && p1 == ICMP_UGT return get_false(ity);
        }
    } else {
        if ap_is_strictly_positive(c0) {
            if ap_eq_u64(delta, 2) {
                if p0 == ICMP_UGE && p1 == ICMP_SLE return get_true(ity);
                if p0 == ICMP_SGE && p1 == ICMP_SLE && nsw return get_true(ity);
            }
            if ap_eq_u64(delta, 1) {
                if p0 == ICMP_UGT && p1 == ICMP_SLE return get_true(ity);
                if p0 == ICMP_SGT && p1 == ICMP_SLE && nsw return get_true(ity);
            }
        }
        if !ap_is_zero(c0) && nuw {
            if ap_eq_u64(delta, 2) && p0 == ICMP_UGE && p1 == ICMP_ULE return get_true(ity);
            if ap_eq_u64(delta, 1) && p0 == ICMP_UGT && p1 == ICMP_ULE return get_true(ity);
        }
    }
    return NONE;
}
// simplifyAndOrOfICmpsWithCtpop
simplify_and_or_of_icmps_with_ctpop :: (c0: Value_Id, c1: Value_Id, is_and: bool) -> Value_Id {
    ok, p0, _, a, cv := pm_icmp(c0);
    if !ok || call_iid(a) != IID_CTPOP return NONE;
    x := op(a, 0);
    okc, c := pm_apint(cv);
    if !okc return NONE;
    ok1, p1, _, b0, b1 := pm_icmp(c1);
    if !ok1 || b0 != x || !pm_zero_int(b1) || ap_is_zero(c) return NONE;
    if !is_and && p0 == ICMP_EQ && p1 == ICMP_NE return c1;
    if is_and && p0 == ICMP_NE && p1 == ICMP_EQ return c1;
    return NONE;
}
simplify_and_of_icmps :: (op0: Value_Id, op1: Value_Id, q: Simplify_Query) -> Value_Id {
    x := simplify_unsigned_range_check(op0, op1, true, q); if x != NONE return x;
    x = simplify_unsigned_range_check(op1, op0, true, q); if x != NONE return x;
    x = simplify_and_or_of_icmps_with_constants(op0, op1, true); if x != NONE return x;
    x = simplify_and_or_of_icmps_with_ctpop(op0, op1, true); if x != NONE return x;
    x = simplify_and_or_of_icmps_with_ctpop(op1, op0, true); if x != NONE return x;
    x = simplify_and_or_of_icmps_with_add(op0, op1, q, true); if x != NONE return x;
    x = simplify_and_or_of_icmps_with_add(op1, op0, q, true); if x != NONE return x;
    return NONE;
}
simplify_or_of_icmps :: (op0: Value_Id, op1: Value_Id, q: Simplify_Query) -> Value_Id {
    x := simplify_unsigned_range_check(op0, op1, false, q); if x != NONE return x;
    x = simplify_unsigned_range_check(op1, op0, false, q); if x != NONE return x;
    x = simplify_and_or_of_icmps_with_constants(op0, op1, false); if x != NONE return x;
    x = simplify_and_or_of_icmps_with_ctpop(op0, op1, false); if x != NONE return x;
    x = simplify_and_or_of_icmps_with_ctpop(op1, op0, false); if x != NONE return x;
    x = simplify_and_or_of_icmps_with_add(op0, op1, q, false); if x != NONE return x;
    x = simplify_and_or_of_icmps_with_add(op1, op0, q, false); if x != NONE return x;
    return NONE;
}
// simplifyAndOrOfFCmpsWithConstants
simplify_and_or_of_fcmps_with_constants :: (c0: Value_Id, c1: Value_Id, is_and: bool) -> Value_Id {
    if op(c0, 0) != op(c1, 0) return NONE;
    ok0, k0 := pm_apfloat(op(c0, 1));
    ok1, k1 := pm_apfloat(op(c1, 1));
    if !ok0 || !ok1 return NONE;
    p0 := ifx is_and then inst_pred(c0) else cmp_inverse(inst_pred(c0));
    p1 := ifx is_and then inst_pred(c1) else cmp_inverse(inst_pred(c1));
    okr0, r0 := cfr_make_exact_fcmp_region(p0, k0);
    okr1, r1 := cfr_make_exact_fcmp_region(p1, k1);
    if !okr0 || !okr1 return NONE;
    if cfr_is_empty_set(cfr_intersect(r0, r1)) return cf_bool(vtype(c0), !is_and);
    if cfr_contains_range(r0, r1) return c1;
    if cfr_contains_range(r1, r0) return c0;
    return NONE;
}
// simplifyAndOrOfFCmps
simplify_and_or_of_fcmps :: (q: Simplify_Query, lhs: Value_Id, rhs: Value_Id, is_and: bool) -> Value_Id {
    l0 := op(lhs, 0); l1 := op(lhs, 1); r0 := op(rhs, 0); r1 := op(rhs, 1);
    if vtype(l0) != vtype(r0) return NONE;
    pl := inst_pred(lhs); pr := inst_pred(rhs);
    abs_or_self :: (v: Value_Id, x: Value_Id) -> bool { return v == x || (call_iid(v) == IID_FABS && op(v, 0) == x); }
    if (pl == FCMP_ORD || pl == FCMP_UNO) && ((cmp_is_ordered(pr) && is_and) || (cmp_is_unordered(pr) && !is_and)) {
        if (abs_or_self(r0, l0) || abs_or_self(r1, l0)) && pm_pos_zero_fp(l1)
            return ifx cmp_is_ordered(pl) == cmp_is_ordered(pr) then rhs else cf_bool(vtype(lhs), !is_and);
    }
    if (pr == FCMP_ORD || pr == FCMP_UNO) && ((cmp_is_ordered(pl) && is_and) || (cmp_is_unordered(pl) && !is_and)) {
        if (abs_or_self(l0, r0) || abs_or_self(l1, r0)) && pm_pos_zero_fp(r1)
            return ifx cmp_is_ordered(pl) == cmp_is_ordered(pr) then lhs else cf_bool(vtype(lhs), !is_and);
    }
    v := simplify_and_or_of_fcmps_with_constants(lhs, rhs, is_and);
    if v != NONE return v;
    return NONE;
}
// simplifyAndOrOfCmps
simplify_and_or_of_cmps :: (q: Simplify_Query, op0_in: Value_Id, op1_in: Value_Id, is_and: bool) -> Value_Id {
    op0 := op0_in; op1 := op1_in;
    cast0 := is_inst(op0) && is_cast_op(inst_op(op0));
    cast1 := is_inst(op1) && is_cast_op(inst_op(op1));
    orig0 := op0;
    if cast0 && cast1 && inst_op(op0) == inst_op(op1) && vtype(op(op0, 0)) == vtype(op(op1, 0)) {
        op0 = op(op0, 0); op1 = op(op1, 0);
    }
    v: Value_Id = NONE;
    if is_inst(op0) && inst_op(op0) == .ICMP && is_inst(op1) && inst_op(op1) == .ICMP
        v = ifx is_and then simplify_and_of_icmps(op0, op1, q) else simplify_or_of_icmps(op0, op1, q);
    if is_inst(op0) && inst_op(op0) == .FCMP && is_inst(op1) && inst_op(op1) == .FCMP
        v = simplify_and_or_of_fcmps(q, op0, op1, is_and);
    if v == NONE return NONE;
    if !cast0 return v;
    if is_const(v) return cfo_cast_operand(inst_op(orig0), v, vtype(orig0));
    return NONE;
}
// simplifyAndOrWithICmpEq
simplify_and_or_with_icmp_eq :: (opc: Opcode, op0: Value_Id, op1: Value_Id, q: Simplify_Query, max_recurse: u32) -> Value_Id {
    ok, pred, _, a, b := pm_icmp_like(op0);
    if !ok || !icmp_is_equality(pred) return NONE;
    simplify :: (res: Value_Id, opc: Opcode, pred: u8, op0: Value_Id, op1: Value_Id) -> Value_Id {
        absorber := cf_binop_absorber(opc, vtype(res), false);
        want := ifx opc == .AND then cast(u8) ICMP_EQ else ICMP_NE;
        if pred == want {
            if res == absorber return absorber;
            if res == cf_binop_identity(opc, vtype(res), false) return op0;
            return NONE;
        }
        if res == absorber return op1;
        return NONE;
    }
    res := simplify_with_op_replaced(op1, a, b, sq_without_undef(q), true, null, max_recurse);
    if res != NONE return simplify(res, opc, pred, op0, op1);
    res = simplify_with_op_replaced(op1, b, a, sq_without_undef(q), true, null, max_recurse);
    if res != NONE return simplify(res, opc, pred, op0, op1);
    return NONE;
}
// simplifyLogicOfAddSub
simplify_logic_of_add_sub :: (op0: Value_Id, op1: Value_Id, opc: Opcode) -> Value_Id {
    try :: (a: Value_Id, s: Value_Id) -> bool {
        oka, x, c1 := pm_binop(a, .ADD);
        if !oka || !is_const(c1) return false;
        oks, c2, y := pm_binop(s, .SUB);
        if !oks || !is_const(c2) || y != x return false;
        return ce_not(c1) == c2;
    }
    if try(op0, op1) || try(op1, op0) {
        ty := vtype(op0);
        return ifx opc == .AND then const_null_value(ty) else cf_all_ones(ty);
    }
    return NONE;
}
// isCheckForZeroAndMulWithOverflow (llvm/lib/Analysis/OverflowInstAnalysis.cpp): (matched, Y use)
is_check_for_zero_and_mul_with_overflow :: (op0: Value_Id, op1: Value_Id, is_and: bool) -> (bool, Use_Id) {
    ok, pred, _, x, z := pm_icmp(op0);
    if !ok || !pm_zero(z) return false, NONE;
    match_mul_overflow_check :: (v: Value_Id, x: Value_Id) -> (bool, Value_Id, u32) {
        if !is_inst(v) || inst_op(v) != .EXTRACTVALUE || inst(v).nidx != 1 || ir.u32_pool[inst(v).idx] != 1 return false, NONE, 0;
        ii := op(v, 0);
        id := call_iid(ii);
        if id != IID_UMUL_WITH_OVERFLOW && id != IID_SMUL_WITH_OVERFLOW return false, NONE, 0;
        if op(ii, 0) == x return true, ii, 0;
        if op(ii, 1) == x return true, ii, 1;
        return false, NONE, 0;
    }
    if is_and && pred == ICMP_NE {
        okm, ii, xi := match_mul_overflow_check(op1, x);
        if okm return true, op_use(ii, 1 - xi);
    }
    if !is_and && pred == ICMP_EQ {
        okn, n := pm_not(op1);
        if okn {
            okm, ii, xi := match_mul_overflow_check(n, x);
            if okm return true, op_use(ii, 1 - xi);
        }
    }
    return false, NONE;
}
// simplifyAndCommutative
simplify_and_commutative :: (op0: Value_Id, op1: Value_Id, q: Simplify_Query, max_recurse: u32) -> Value_Id {
    okn, nx := pm_not(op0);
    if okn && nx == op1 return const_null_of(op0);
    okc, _ := pm_c_binop_with(op0, .OR, op1);
    if okc return op1;
    // m_c_Or(m_Value(X), m_Not(m_Value(Y))) && m_c_Or(m_Specific(X), m_Specific(Y))
    if opr_code(op0) == .OR {
        for k: 0..1 {
            x := op(op0, cast(u32) k);
            okn2, y := pm_not(op(op0, cast(u32)(1 - k)));
            if !okn2 continue;
            if opr_code(op1) == .OR && ((op(op1, 0) == x && op(op1, 1) == y) || (op(op1, 1) == x && op(op1, 0) == y)) return x;
            break;
        }
    }
    okz, _ := is_check_for_zero_and_mul_with_overflow(op0, op1, true);
    if okz return op1;
    okng, ng := pm_neg(op0);
    if okng && ng == op1 && is_known_to_be_a_power_of_two_ctx(op1, true, q.cxt, q.dt, q.ac) return op1;
    oka, aa, ab := pm_binop(op0, .ADD);
    if oka && aa == op1 && pm_all_ones(ab) && is_known_to_be_a_power_of_two_ctx(op1, true, q.cxt, q.dt, q.ac) return const_null_value(vtype(op1));
    oks, x, s1v := pm_binop(op0, .SHL);
    if oks {
        oks1, s1 := pm_apint(s1v);
        oka2, a2, a2b := pm_binop(op1, .ADD);
        if oks1 && oka2 && pm_all_ones(a2b) {
            oks2, sx, s2v := pm_binop(a2, .SHL);
            oks2c, s2 := pm_apint(s2v);
            if oks2 && sx == x && oks2c && is_known_to_be_a_power_of_two_ctx(x, true, q.cxt, null, q.ac) && ap_uge(s1, s2) return const_null_of(op0);
        }
    }
    v := simplify_and_or_with_icmp_eq(.AND, op0, op1, q, max_recurse);
    if v != NONE return v;
    return NONE;
}
simplify_and_inst :: (op0_in: Value_Id, op1_in: Value_Id, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    c, op0, op1 := fold_or_commute_constant(.AND, op0_in, op1_in, q);
    if c != NONE return c;
    if pm_poison(op1) return op1;
    if sq_is_undef_value(q, op1) return const_null_of(op0);
    if op0 == op1 return op0;
    if pm_zero(op1) return const_null_of(op0);
    if pm_all_ones(op1) return op0;
    r := simplify_and_commutative(op0, op1, q, max_recurse); if r != NONE return r;
    r = simplify_and_commutative(op1, op0, q, max_recurse); if r != NONE return r;
    v := simplify_logic_of_add_sub(op0, op1, .AND); if v != NONE return v;
    okm, mask := pm_apint(op1);
    if okm {
        oks, x, sv := pm_binop(op0, .SHL);
        if oks { okc, sh := pm_apint(sv); if okc && ap_is_zero(ap_lshr_ap(ap_not(mask), sh)) return op0; }
        okl, xl, lv := pm_binop(op0, .LSHR);
        if okl { okc, sh := pm_apint(lv); if okc && ap_is_zero(ap_shl_ap(ap_not(mask), sh)) return op0; }
    }
    okp, powc := pm_power2_ap(op1);
    if okp {
        oka, shift, am := pm_binop(op0, .ADD);
        if oka && pm_all_ones(am) && is_known_to_be_a_power_of_two_ctx(shift, false, q.cxt, q.dt, q.ac) {
            k := known_bits(shift, q);
            if ap_active_bits(powc) >= ap_active_bits(kb_max_value(k)) return const_null_value(vtype(op1));
        }
    }
    v = simplify_and_or_of_cmps(q, op0, op1, true); if v != NONE return v;
    v = simplify_associative_binop(.AND, op0, op1, q, max_recurse); if v != NONE return v;
    v = expand_commutative_binop(.AND, op0, op1, .OR, q, max_recurse); if v != NONE return v;
    v = expand_commutative_binop(.AND, op0, op1, .XOR, q, max_recurse); if v != NONE return v;
    if is_select_inst(op0) || is_select_inst(op1) {
        if is_bool_ty(vtype(op0)) {
            if is_select_inst(op1) && op(op1, 0) == op0 && pm_zero(op(op1, 2)) return op1;
            else if is_select_inst(op0) && op(op0, 0) == op1 && pm_zero(op(op0, 2)) return op0;
        }
        v = thread_binop_over_select(.AND, op0, op1, q, max_recurse); if v != NONE return v;
    }
    if is_phi(op0) || is_phi(op1) {
        v = thread_binop_over_phi(.AND, op0, op1, q, max_recurse); if v != NONE return v;
    }
    if q.use_instr_info && okm && opr_code(op0) == .OR {
        for k: 0..1 {
            xs := op(op0, cast(u32) k); y := op(op0, cast(u32)(1 - k));
            oks, x, shv := pm_binop(xs, .SHL);
            if !oks || (opr_flags(xs) & F_NUW) == 0 continue;
            okc, sh := pm_apint(shv);
            if !okc continue;
            width := type_bits(scalar_type(vtype(op0)));
            cnt := cast(u32) ap_limited(sh, width);
            yk := known_bits(y, q);
            ewy := kb_count_max_active_bits(yk);
            if ewy <= cnt {
                xk := known_bits(x, q);
                ewx := kb_count_max_active_bits(xk);
                eby := ap_low_bits_set(width, ewy);
                ebx := ap_shl(ap_low_bits_set(width, ewx), cnt);
                if ap_is_subset_of(eby, mask) && !ap_intersects(ebx, mask) return y;
                if ap_is_subset_of(ebx, mask) && !ap_intersects(eby, mask) return xs;
            }
            break;
        }
    }
    // m_c_Xor(m_Value(X), m_CombineAnd(m_BinOp(Or), m_c_Or(m_Deferred(X), m_Value(Y)))) && m_c_Xor(m_Specific(Or), m_Specific(Y))
    if opr_code(op0) == .XOR {
        for k: 0..1 {
            x := op(op0, cast(u32) k); orv := op(op0, cast(u32)(1 - k));
            if !is_binary_operator(orv) || inst_op(orv) != .OR continue;
            oky, y := pm_c_binop_with(orv, .OR, x);
            if !oky continue;
            if opr_code(op1) == .XOR && ((op(op1, 0) == orv && op(op1, 1) == y) || (op(op1, 1) == orv && op(op1, 0) == y)) return const_null_of(op0);
            break;
        }
    }
    okx, xa, xc := pm_binop(op0, .XOR);
    if okx {
        okc1, c1 := pm_apint(xc);
        if okc1 {
            okx2, ya, yc := pm_binop(op1, .XOR);
            if okx2 && ya == xa && pm_specific_int_ap(yc, ap_not(c1)) return const_null_of(op0);
        }
    }
    if is_bool_ty(vtype(op0)) {
        imp := is_implied_condition(op0, op1, true);
        if imp == 1 return op0;
        if imp == 0 return get_false(vtype(op0));
        imp = is_implied_condition(op1, op0, true);
        if imp == 1 return op1;
        if imp == 0 return get_false(vtype(op1));
    }
    v = simplify_by_dom_eq(.AND, op0, op1, q, max_recurse); if v != NONE return v;
    return NONE;
}

// ---------------------------------------------------------------- or / xor

// v is `opc` (instruction or constant expression) with operands {a, b} in either order (m_c_<Op>(m_Specific(a), m_Specific(b)))
is_c_op_of :: (v: Value_Id, opc: Opcode, a: Value_Id, b: Value_Id) -> bool {
    if opr_code(v) != opc return false;
    return (op(v, 0) == a && op(v, 1) == b) || (op(v, 0) == b && op(v, 1) == a);
}
// m_c_<Op>(m_Not(m_Value(A)), m_Value(B)): (ok, A, B, the not operand)
pm_c_op_not :: (v: Value_Id, opc: Opcode) -> (bool, Value_Id, Value_Id, Value_Id) {
    if opr_code(v) != opc return false, NONE, NONE, NONE;
    for k: 0..1 {
        n := op(v, cast(u32) k);
        ok, a := pm_not(n);
        if ok return true, a, op(v, cast(u32)(1 - k)), n;
    }
    return false, NONE, NONE, NONE;
}
// m_c_LogicalAnd(m_CombineAnd(m_Value(NotA), m_Not(m_Value(A))), m_Value(B))
pm_c_logical_and_not :: (v: Value_Id) -> (bool, Value_Id, Value_Id, Value_Id) {
    ok, l, r := pm_logical_and(v);
    if !ok return false, NONE, NONE, NONE;
    okn, a := pm_not(l);
    if okn return true, a, r, l;
    okn, a = pm_not(r);
    if okn return true, a, l, r;
    return false, NONE, NONE, NONE;
}
// simplifyOrLogic
simplify_or_logic :: (x: Value_Id, y: Value_Id) -> Value_Id {
    ty := vtype(x);
    okn, ny := pm_not(y);
    if okn && ny == x return cf_all_ones(ty);
    if okn {
        oka, _ := pm_c_binop_with(ny, .AND, x);
        if oka return cf_all_ones(ty);
    }
    oka, _ := pm_c_binop_with(y, .AND, x);
    if oka return x;
    okx, a, b := pm_binop(x, .XOR);
    if okx && is_c_op_of(y, .OR, a, b) return y;
    oknx, nx := pm_not(x);
    if oknx {
        okx2, a2, b2 := pm_binop(nx, .XOR);
        if okx2 && is_c_op_of(y, .OR, a2, b2) return cf_all_ones(ty);
    }
    ok6, a6, b6, _ := pm_c_op_not(x, .AND);
    if ok6 && is_c_op_of(y, .XOR, a6, b6) return y;
    ok7, a7, b7, _ := pm_c_op_not(x, .XOR);
    if ok7 && is_c_op_of(y, .AND, a7, b7) return x;
    ok8, a8, b8, _ := pm_c_op_not(x, .OR);
    if ok8 && is_c_op_of(y, .XOR, a8, b8) return cf_all_ones(ty);
    ok9, a9, b9, nota := pm_c_op_not(x, .AND);
    if ok9 && okn && is_c_op_of(ny, .OR, a9, b9) return nota;
    ok10, a10, b10, nota10 := pm_c_logical_and_not(x);
    if ok10 && okn {
        oko, l, r := pm_logical_or(ny);
        if oko && ((l == a10 && r == b10) || (l == b10 && r == a10)) return nota10;
    }
    if oknx {
        okx3, a3, b3 := pm_binop(nx, .XOR);
        if okx3 && is_c_op_of(y, .AND, a3, b3) return x;
        oka4, a4, b4 := pm_binop(nx, .AND);
        if oka4 && is_c_op_of(y, .XOR, a4, b4) return x;
    }
    return NONE;
}
simplify_or_inst :: (op0_in: Value_Id, op1_in: Value_Id, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    c, op0, op1 := fold_or_commute_constant(.OR, op0_in, op1_in, q);
    if c != NONE return c;
    if pm_poison(op1) return op1;
    if sq_is_undef_value(q, op1) || pm_all_ones(op1) return cf_all_ones(vtype(op0));
    if op0 == op1 || pm_zero(op1) return op0;
    r := simplify_or_logic(op0, op1); if r != NONE return r;
    r = simplify_or_logic(op1, op0); if r != NONE return r;
    v := simplify_logic_of_add_sub(op0, op1, .OR); if v != NONE return v;
    {
        x, y: Value_Id;
        matched := false;
        ok1, s0, sx := pm_binop(op0, .SHL);
        ok2, l0, ly := pm_binop(op1, .LSHR);
        if ok1 && pm_all_ones(s0) && ok2 && pm_all_ones(l0) { x = sx; y = ly; matched = true; }
        else {
            ok1, s0, sx = pm_binop(op1, .SHL);
            ok2, l0, ly = pm_binop(op0, .LSHR);
            if ok1 && pm_all_ones(s0) && ok2 && pm_all_ones(l0) { x = sx; y = ly; matched = true; }
        }
        if matched {
            cc: APInt; okc := false;
            oks, sc, sy := pm_binop(x, .SUB);
            if oks && sy == y { okc, cc = pm_apint(sc); }
            if !okc { oks, sc, sy = pm_binop(y, .SUB); if oks && sy == x { okc, cc = pm_apint(sc); } }
            if okc && ap_ule_u64(cc, type_bits(scalar_type(vtype(x)))) return cf_all_ones(vtype(x));
        }
    }
    for k: 0..1 {
        a := ifx k == 0 then op0 else op1; b := ifx k == 0 then op1 else op0;
        if call_iid(a) == IID_FSHL {
            x := op(a, 0); y := op(a, 2);
            oks, s0, s1 := pm_binop(b, .SHL);
            if oks && s0 == x && s1 == y return a;
        }
    }
    for k: 0..1 {
        a := ifx k == 0 then op0 else op1; b := ifx k == 0 then op1 else op0;
        if call_iid(a) == IID_FSHR {
            x := op(a, 1); y := op(a, 2);
            okl, l0, l1 := pm_binop(b, .LSHR);
            if okl && l0 == x && l1 == y return a;
        }
    }
    v = simplify_and_or_with_icmp_eq(.OR, op0, op1, q, max_recurse); if v != NONE return v;
    v = simplify_and_or_with_icmp_eq(.OR, op1, op0, q, max_recurse); if v != NONE return v;
    v = simplify_and_or_of_cmps(q, op0, op1, false); if v != NONE return v;
    okz, _ := is_check_for_zero_and_mul_with_overflow(op0, op1, false); if okz return op1;
    okz, _ = is_check_for_zero_and_mul_with_overflow(op1, op0, false); if okz return op0;
    v = simplify_associative_binop(.OR, op0, op1, q, max_recurse); if v != NONE return v;
    v = expand_commutative_binop(.OR, op0, op1, .AND, q, max_recurse); if v != NONE return v;
    if is_select_inst(op0) || is_select_inst(op1) {
        if is_bool_ty(vtype(op0)) {
            if is_select_inst(op1) && op(op1, 0) == op0 && pm_one(op(op1, 1)) return op1;
            else if is_select_inst(op0) && op(op0, 0) == op1 && pm_one(op(op0, 1)) return op0;
        }
        v = thread_binop_over_select(.OR, op0, op1, q, max_recurse); if v != NONE return v;
    }
    oka, a, ac1 := pm_binop(op0, .AND);
    okb, b, bc2 := pm_binop(op1, .AND);
    if oka && okb {
        ok1, c1 := pm_apint(ac1);
        ok2, c2 := pm_apint(bc2);
        if ok1 && ok2 && ap_eq(c1, ap_not(c2)) {
            if ap_is_mask(c2) {
                okn, n := pm_c_binop_with(a, .ADD, b);
                if okn && masked_value_is_zero(n, c2, q) return a;
            }
            if ap_is_mask(c1) {
                okn, n := pm_c_binop_with(b, .ADD, a);
                if okn && masked_value_is_zero(n, c1, q) return b;
            }
        }
    }
    if is_phi(op0) || is_phi(op1) {
        v = thread_binop_over_phi(.OR, op0, op1, q, max_recurse); if v != NONE return v;
    }
    okx, xa, xc := pm_binop(op0, .XOR);
    if okx {
        okc1, c1 := pm_apint(xc);
        if okc1 {
            okx2, ya, yc := pm_binop(op1, .XOR);
            if okx2 && ya == xa && pm_specific_int_ap(yc, ap_not(c1)) return cf_all_ones(vtype(op0));
        }
    }
    if is_bool_ty(vtype(op0)) {
        imp := is_implied_condition(op0, op1, false);
        if imp == 0 return op0;
        if imp == 1 return get_true(vtype(op0));
        imp = is_implied_condition(op1, op0, false);
        if imp == 0 return op1;
        if imp == 1 return get_true(vtype(op1));
    }
    v = simplify_by_dom_eq(.OR, op0, op1, q, max_recurse); if v != NONE return v;
    return NONE;
}
simplify_xor_inst :: (op0_in: Value_Id, op1_in: Value_Id, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    c, op0, op1 := fold_or_commute_constant(.XOR, op0_in, op1_in, q);
    if c != NONE return c;
    if pm_poison(op1) return op1;
    if sq_is_undef_value(q, op1) return op1;
    if pm_zero(op1) return op0;
    if op0 == op1 return const_null_of(op0);
    okn, nx := pm_not(op0);
    okn2, nx2 := pm_not(op1);
    if (okn && nx == op1) || (okn2 && nx2 == op0) return cf_all_ones(vtype(op0));
    fold_and_or_not :: (x: Value_Id, y: Value_Id) -> Value_Id {
        ok, a, b, _ := pm_c_op_not(x, .AND);
        if ok && is_c_op_of(y, .OR, a, b) return a;
        ok2, a2, b2, nota := pm_c_op_not(x, .OR);
        if ok2 && is_c_op_of(y, .AND, a2, b2) return nota;
        return NONE;
    }
    r := fold_and_or_not(op0, op1); if r != NONE return r;
    r = fold_and_or_not(op1, op0); if r != NONE return r;
    v := simplify_logic_of_add_sub(op0, op1, .XOR); if v != NONE return v;
    v = simplify_associative_binop(.XOR, op0, op1, q, max_recurse); if v != NONE return v;
    v = simplify_by_dom_eq(.XOR, op0, op1, q, max_recurse); if v != NONE return v;
    oks, sa, sx := pm_binop(op0, .SUB);
    if oks && (opr_flags(op0) & F_NUW) != 0 && sa == op1 && pm_low_bit_mask(op1) return sx;
    return NONE;
}

// ---------------------------------------------------------------- icmp helpers

// CmpInst::makeCmpResultType
get_compare_ty :: (v: Value_Id) -> Type_Id {
    t := vtype(v);
    if is_vector_type(t) return vector_with_elt(t, ir.t_i1);
    return ir.t_i1;
}
// extractEquivalentCondition
extract_equivalent_condition :: (v: Value_Id, pred: u8, lhs: Value_Id, rhs: Value_Id) -> Value_Id {
    if !is_select_inst(v) return NONE;
    cmp := op(v, 0);
    if !is_cmp_inst(cmp) return NONE;
    cl := op(cmp, 0); cr := op(cmp, 1);
    if pred == inst_pred(cmp) && lhs == cl && rhs == cr return cmp;
    if pred == cmp_swapped(inst_pred(cmp)) && lhs == cr && rhs == cl return cmp;
    return NONE;
}
is_byval_arg :: (v: Value_Id) -> bool { return vkind(v) == .ARGUMENT && arg_has_attr(v, .ByVal); }
is_dereferenceable_arg :: (v: Value_Id) -> bool {
    if vkind(v) != .ARGUMENT || !is_ptr_type(vtype(v)) return false;
    a := attr_set_find(arg_attrs(v), .Dereferenceable);
    return a != null && a.ival > 0;
}
is_alloca :: inline (v: Value_Id) -> bool { return is_inst(v) && inst_op(v) == .ALLOCA; }
// AllocaInst::isStaticAlloca
is_static_alloca :: (a: Value_Id) -> bool {
    if !is_const_int(op(a, 0)) return false;
    b := inst_block(a);
    return b == fn_entry(block_fn(b)) && (inst(a).flags & F_INALLOCA) == 0;
}
// isAllocDisjoint
is_alloc_disjoint :: (v: Value_Id) -> bool {
    if is_alloca(v) return is_static_alloca(v);
    if is_global_value(vkind(v)) {
        g := glob(v);
        local := g.linkage == .INTERNAL || g.linkage == .PRIVATE;
        return (local || g.visibility == 1 || g.visibility == 2 || g.unnamed_addr == 2) && g.tls == 0;
    }
    return is_byval_arg(v);
}
// haveNonOverlappingStorage
have_non_overlapping_storage :: (v1: Value_Id, v2: Value_Id) -> bool {
    gv :: (v: Value_Id) -> bool { return vkind(v) == .GLOBAL_VAR; }
    if is_byval_arg(v1) return is_alloca(v2) || gv(v2) || is_byval_arg(v2) || is_dereferenceable_arg(v2);
    if is_byval_arg(v2) return is_alloca(v1) || gv(v1) || is_byval_arg(v1) || is_dereferenceable_arg(v1);
    if (is_dereferenceable_arg(v1) && is_alloca(v2)) || (is_dereferenceable_arg(v2) && is_alloca(v1)) return true;
    return is_alloca(v1) && (is_alloca(v2) || gv(v2));
}
// getUnderlyingObjects (no LoopInfo)
get_underlying_objects :: (v: Value_Id, out: *[..] Value_Id) {
    visited: [..] Value_Id; visited.allocator = temp;
    work: [..] Value_Id; work.allocator = temp;
    array_add(*work, v);
    while work.count {
        p := get_underlying_object(pop(*work));
        seen := false;
        for visited if it == p { seen = true; break; }
        if seen continue;
        array_add(*visited, p);
        if is_select_inst(p) { array_add(*work, op(p, 1)); array_add(*work, op(p, 2)); continue; }
        if is_phi(p) {
            n := nops(p);
            for k: 0..n-1 array_add(*work, phi_value(p, k));
            continue;
        }
        array_add(out, p);
    }
}
// isNoAliasCall
is_no_alias_call :: (v: Value_Id) -> bool { return is_inst(v) && is_call_base(v) && call_has_ret_attr(v, .NoAlias); }

// CaptureTracking (llvm/lib/Analysis/CaptureTracking.cpp): DetermineUseCaptureKind as (UseCC, ResultCC)
CC_NONE :: 0; CC_ADDRESS_IS_NULL :: 1; CC_ADDRESS :: 3; CC_READ_PROVENANCE :: 4; CC_PROVENANCE :: 12; CC_ALL :: 15;
capture_info_of_attrs :: (s: u32) -> (u8, u8) {
    a := attr_set_find(s, .Captures);
    if !a return CC_ALL, CC_ALL;
    return cast(u8)(a.ival & 0xF), cast(u8)((a.ival >> 4) & 0xF);
}
determine_use_capture_kind :: (u: Use_Id, base: Value_Id) -> (u8, u8) {
    i := ir.u_user[u];
    if !is_inst(i) return CC_ALL, CC_NONE;
    opno := u - ir.v_ops[i];
    o := inst_op(i);
    if o == {
        case .CALL; #through;
        case .INVOKE;
            if argument_aliasing_to_returned_pointer_intrinsic(i) return CC_NONE, CC_ALL;
            if opno == nops(i) - 1 && o == .CALL return CC_NONE, CC_NONE;   // isCallee
            if o == .INVOKE && opno >= nops(i) - 3 {
                if opno == nops(i) - 1 return CC_NONE, CC_NONE;
            }
            volatile_cc: u8 = CC_NONE;
            if is_mem_intrinsic_call(i) && is_volatile(i) volatile_cc |= CC_ADDRESS;
            oth, ret: u8;
            na := call_num_args(i);
            if opno < na {
                if call_param_has_attr(i, opno, .ByVal) { oth = CC_NONE; ret = CC_NONE; }
                else {
                    oth, ret = capture_info_of_attrs(attr_list_param(inst(i).attrs, opno));
                    f := call_callee(i);
                    if vkind(f) == .FUNCTION {
                        o2, r2 := capture_info_of_attrs(attr_list_param(glob(f).attrs, opno));
                        oth &= o2; ret &= r2;
                    }
                }
            } else {
                if call_iid(i) == IID_ASSUME { oth = CC_NONE; ret = CC_NONE; }
                else fatal("capture tracking through operand bundles is not supported yet");
            }
            mask: u8 = CC_ALL;
            if call_only_reads_memory(i) && type_kind(vtype(i)) == .VOID mask = CC_ADDRESS;
            return (oth & mask) | volatile_cc, ret;
        case .LOAD;
            if (inst(i).flags & F_VOLATILE) != 0 return CC_ADDRESS, CC_NONE;
            return CC_NONE, CC_NONE;
        case .VAARG; return CC_NONE, CC_NONE;
        case .STORE;
            if opno == 0 {
                if inst_md(i, "captures") != NONE fatal("!captures metadata is not supported yet");
                return CC_ALL, CC_NONE;
            }
            if (inst(i).flags & F_VOLATILE) != 0 return CC_ADDRESS, CC_NONE;
            return CC_NONE, CC_NONE;
        case .ATOMICRMW;
            if opno == 1 return CC_ALL, CC_NONE;
            if (inst(i).flags & F_VOLATILE) != 0 return CC_ADDRESS, CC_NONE;
            return CC_NONE, CC_NONE;
        case .CMPXCHG;
            if opno == 1 || opno == 2 return CC_ALL, CC_NONE;
            if (inst(i).flags & F_VOLATILE) != 0 return CC_ADDRESS, CC_NONE;
            return CC_NONE, CC_NONE;
        case .GEP;
            if is_vector_type(vtype(i)) return CC_ALL, CC_NONE;
            return CC_NONE, CC_ALL;
        case .BITCAST; #through; case .PHI; #through; case .SELECT; #through; case .ADDRSPACECAST;
            return CC_NONE, CC_ALL;
        case .PTRTOADDR; return CC_ADDRESS, CC_NONE;
        case .ICMP;
            other := op(i, 1 - opno);
            if vkind(other) == .C_NULL && icmp_is_equality(inst_pred(i)) && ir.u_val[u] == base return CC_ADDRESS_IS_NULL, CC_NONE;
            return CC_ADDRESS, CC_NONE;
    }
    return CC_ALL, CC_NONE;
}
argument_aliasing_to_returned_pointer_intrinsic :: (c: Value_Id) -> bool {
    id := call_iid(c);
    if id == IID_LAUNDER_INVARIANT_GROUP || id == IID_STRIP_INVARIANT_GROUP || id == IID_PTRMASK return true;
    if id == IID_THREADLOCAL_ADDRESS return !fn_has_fn_attr(inst_fn(c), .PresplitCoroutine);
    return false;
}
is_mem_intrinsic_call :: (i: Value_Id) -> bool { return is_mem_intrinsic_name(intrinsic_id_of_call(i)); }
// PointerMayBeCaptured(MI, &CustomCaptureTracker) as used by computePointerICmp: is the allocation captured?
pointer_icmp_alloc_captured :: (v: Value_Id) -> bool {
    MAX_USES :: 100;
    work: [..] Use_Id; work.allocator = temp;
    visited: Table(Use_Id, bool); visited.allocator = temp;
    nvisited := 0;
    add_uses :: (v: Value_Id, work: *[..] Use_Id, visited: *Table(Use_Id, bool), nvisited: *int) -> bool {
        u := ir.v_first_use[v];
        while u != NONE {
            if nvisited.* >= 100 return false;   // tooManyUses: Captured = true
            if !table_contains(visited, u) {
                table_set(visited, u, true);
                nvisited.* += 1;
                array_add(work, u);
            }
            u = ir.u_next[u];
        }
        return true;
    }
    if !add_uses(v, *work, *visited, *nvisited) return true;
    while work.count {
        u := pop(*work);
        use_cc, res_cc := determine_use_capture_kind(u, v);
        if use_cc != CC_NONE {
            // CustomCaptureTracker::captured
            user := ir.u_user[u];
            cont := false;
            if is_inst(user) && inst_op(user) == .ICMP {
                other := op(user, 1 - (u - ir.v_ops[user]));
                if is_inst(other) && inst_op(other) == .LOAD && vkind(op(other, 0)) == .GLOBAL_VAR cont = true;
            }
            if !cont return true;
            if (res_cc & ~use_cc) == 0 continue;
        }
        if res_cc != CC_NONE && !add_uses(ir.u_user[u], *work, *visited, *nvisited) return true;
    }
    return false;
}

// computePointerICmp
compute_pointer_icmp :: (pred_in: u8, lhs_in: Value_Id, rhs_in: Value_Id, q: Simplify_Query) -> Value_Id {
    if cmp_is_signed(pred_in) return NONE;
    pred := icmp_signed_predicate(pred_in);
    allow_non_inbounds := icmp_is_equality(pred);
    isz := dl_index_bits(vtype(lhs_in));
    lhs, lo := strip_and_accumulate_constant_offsets(lhs_in, ap_zero(isz), allow_non_inbounds);
    rhs, ro := strip_and_accumulate_constant_offsets(rhs_in, ap_zero(isz), allow_non_inbounds);
    if lhs == rhs return cf_bool(get_compare_ty(lhs), icmp_compare(lo, ro, pred));
    if icmp_is_equality(pred) {
        if have_non_overlapping_storage(lhs, rhs) {
            cbn1, ls := pointer_dereferenceable_bytes(lhs);
            cbn2, rs := pointer_dereferenceable_bytes(rhs);
            if ls != 0 && !cbn1 && rs != 0 && !cbn2 {
                dist := ap_sub(lo, ro);
                if (ifx ap_is_non_negative(dist) then ap_ult_u64(dist, ls) else ap_ult_u64(ap_neg(dist), rs))
                    return cf_bool(get_compare_ty(lhs), !cmp_is_true_when_equal(pred));
            }
        }
        lobjs: [..] Value_Id; lobjs.allocator = temp;
        robjs: [..] Value_Id; robjs.allocator = temp;
        get_underlying_objects(lhs, *lobjs);
        get_underlying_objects(rhs, *robjs);
        all_no_alias :: (objs: [] Value_Id) -> bool { for objs if !is_no_alias_call(it) return false; return true; }
        all_disjoint :: (objs: [] Value_Id) -> bool { for objs if !is_alloc_disjoint(it) return false; return true; }
        if (all_no_alias(lobjs) && all_disjoint(robjs)) || (all_no_alias(robjs) && all_disjoint(lobjs))
            return cf_bool(get_compare_ty(lhs), !cmp_is_true_when_equal(pred));
        mi: Value_Id = NONE;
        if is_inst(lhs) && is_call_base(lhs) && is_alloc_like_fn(lhs, q.have_tli) && is_known_non_zero(rhs, q) mi = lhs;
        else if is_inst(rhs) && is_call_base(rhs) && is_alloc_like_fn(rhs, q.have_tli) && is_known_non_zero(lhs, q) mi = rhs;
        if mi != NONE {
            if !pointer_icmp_alloc_captured(mi) return cf_bool(get_compare_ty(lhs), cmp_is_false_when_equal(pred));
        }
    }
    return NONE;
}

// simplifyICmpOfBools
simplify_icmp_of_bools :: (pred: u8, lhs: Value_Id, rhs: Value_Id, q: Simplify_Query) -> Value_Id {
    ity := get_compare_ty(lhs);
    if !is_bool_ty(vtype(lhs)) return NONE;
    extract_not :: (v: Value_Id) -> Value_Id { ok, x := pm_not(v); if ok return x; return NONE; }
    if pm_zero(rhs) {
        if pred == {
            case ICMP_NE; #through; case ICMP_UGT; #through; case ICMP_SLT; return lhs;
            case ICMP_EQ; #through; case ICMP_ULE; #through; case ICMP_SGE;
                x := extract_not(lhs); if x != NONE return x;
            case ICMP_ULT; #through; case ICMP_SGT; return get_false(ity);
            case ICMP_UGE; #through; case ICMP_SLE; return get_true(ity);
        }
    } else if pm_one(rhs) {
        if pred == {
            case ICMP_EQ; #through; case ICMP_UGE; #through; case ICMP_SLE; return lhs;
            case ICMP_NE; #through; case ICMP_ULT; #through; case ICMP_SGT;
                x := extract_not(lhs); if x != NONE return x;
            case ICMP_UGT; #through; case ICMP_SLT; return get_false(ity);
            case ICMP_ULE; #through; case ICMP_SGE; return get_true(ity);
        }
    }
    if pred == {
        case ICMP_UGE; if is_implied_condition(rhs, lhs, true) == 1 return get_true(ity);
        case ICMP_SGE; if is_implied_condition(lhs, rhs, true) == 1 return get_true(ity);
        case ICMP_ULE; if is_implied_condition(lhs, rhs, true) == 1 return get_true(ity);
        case ICMP_SLE; if is_implied_condition(rhs, lhs, true) == 1 return get_true(ity);
    }
    return NONE;
}
// matchEquivZeroRHS
match_equiv_zero_rhs :: (pred: *u8, rhs: Value_Id) -> bool {
    if pm_zero(rhs) return true;
    if pm_all_ones(rhs) {
        if pred.* == ICMP_SGT { pred.* = ICMP_SGE; return true; }
        if pred.* == ICMP_SLE { pred.* = ICMP_SLT; return true; }
        return false;
    }
    if pm_one(rhs) {
        if pred.* == ICMP_SGE { pred.* = ICMP_SGT; return true; }
        if pred.* == ICMP_UGE { pred.* = ICMP_UGT; return true; }
        if pred.* == ICMP_SLT { pred.* = ICMP_SLE; return true; }
        if pred.* == ICMP_ULT { pred.* = ICMP_ULE; return true; }
        return false;
    }
    return false;
}
// simplifyICmpWithZero
simplify_icmp_with_zero :: (pred_in: u8, lhs: Value_Id, rhs: Value_Id, q: Simplify_Query) -> Value_Id {
    pred := pred_in;
    if !match_equiv_zero_rhs(*pred, rhs) return NONE;
    ity := get_compare_ty(lhs);
    if pred == {
        case ICMP_ULT; return get_false(ity);
        case ICMP_UGE; return get_true(ity);
        case ICMP_EQ; #through; case ICMP_ULE; if is_known_non_zero(lhs, q) return get_false(ity);
        case ICMP_NE; #through; case ICMP_UGT; if is_known_non_zero(lhs, q) return get_true(ity);
        case ICMP_SLT;
            k := known_bits(lhs, q);
            if kb_is_negative(k) return get_true(ity);
            if kb_is_non_negative(k) return get_false(ity);
        case ICMP_SLE;
            k := known_bits(lhs, q);
            if kb_is_negative(k) return get_true(ity);
            if kb_is_non_negative(k) && is_known_non_zero(lhs, q) return get_false(ity);
        case ICMP_SGE;
            k := known_bits(lhs, q);
            if kb_is_negative(k) return get_false(ity);
            if kb_is_non_negative(k) return get_true(ity);
        case ICMP_SGT;
            k := known_bits(lhs, q);
            if kb_is_negative(k) return get_false(ity);
            if kb_is_non_negative(k) && is_known_non_zero(lhs, q) return get_true(ity);
    }
    return NONE;
}
// isSignBitCheck: (is a sign bit check, TrueIfSigned)
is_sign_bit_check :: (pred: u8, rhs: APInt) -> (bool, bool) {
    if pred == {
        case ICMP_SLT; return ap_is_zero(rhs), true;
        case ICMP_SLE; return ap_is_all_ones(rhs), true;
        case ICMP_SGT; return ap_is_all_ones(rhs), false;
        case ICMP_SGE; return ap_is_zero(rhs), false;
        case ICMP_UGT; return ap_is_max_signed(rhs), true;
        case ICMP_UGE; return ap_is_min_signed(rhs), true;
        case ICMP_ULT; return ap_is_min_signed(rhs), false;
        case ICMP_ULE; return ap_is_max_signed(rhs), false;
    }
    return false, false;
}
// simplifyICmpWithConstant
simplify_icmp_with_constant :: (pred: u8, lhs: Value_Id, rhs: Value_Id, q: Simplify_Query) -> Value_Id {
    ity := get_compare_ty(rhs);
    okc, c := pm_apint_ap(rhs);
    if !okc return NONE;
    okb, bx := pm_elementwise_bitcast(lhs);
    if okb && opr_code(bx) == .UITOFP {
        oks, tis := is_sign_bit_check(pred, c);
        if oks return cf_bool(ity, !tis);
    }
    rcr := cr_exact_icmp_region(pred, c);
    if cr_is_empty_set(rcr) return get_false(ity);
    if cr_is_full_set(rcr) return get_true(ity);
    lcr := compute_constant_range(lhs, cmp_is_signed(pred), q);
    if !cr_is_full_set(lcr) {
        if cr_contains_range(rcr, lcr) return get_true(ity);
        if cr_contains_range(cr_inverse(rcr), lcr) return get_false(ity);
    }
    if q.use_instr_info && icmp_is_equality(pred) {
        okm, _, mcv := pm_binop(lhs, .MUL);
        if okm {
            okmc, mc := pm_apint_ap(mcv);
            f := opr_flags(lhs);
            if okmc && !ap_is_zero(mc) {
                if ((f & F_NUW) != 0 && !ap_is_zero(ap_urem(c, mc))) || ((f & F_NSW) != 0 && !ap_is_zero(ap_srem(c, mc)))
                    return cf_bool(ity, pred == ICMP_NE);
            }
        }
    }
    if pred == ICMP_UGE && ap_is_one(c) && is_known_non_zero(lhs, q) return get_true(ity);
    return NONE;
}
// getUnsignedMonotonicValues
get_unsigned_monotonic_values :: (res: *[..] Value_Id, v: Value_Id, greater: bool, q: Simplify_Query, depth_in: u32 = 0) {
    for res.* if it == v return;
    array_add(res, v);
    depth := depth_in + 1;
    if depth > 1 return;
    if !is_inst(v) return;
    if greater {
        x, y: Value_Id; ok := false;
        if inst_op(v) == .OR { x = op(v, 0); y = op(v, 1); ok = true; }
        else if call_iid(v) == IID_UADD_SAT { x = op(v, 0); y = op(v, 1); ok = true; }
        if ok { get_unsigned_monotonic_values(res, x, greater, q, depth); get_unsigned_monotonic_values(res, y, greater, q, depth); }
        if inst_op(v) == .MUL && (inst(v).flags & F_NUW) != 0 {
            x = op(v, 0); y = op(v, 1);
            if is_known_non_zero(x, q) get_unsigned_monotonic_values(res, y, greater, q, depth);
            if is_known_non_zero(y, q) get_unsigned_monotonic_values(res, x, greater, q, depth);
        }
    } else {
        o := inst_op(v);
        if o == .AND { get_unsigned_monotonic_values(res, op(v, 0), greater, q, depth); get_unsigned_monotonic_values(res, op(v, 1), greater, q, depth); }
        else if o == .UREM || o == .UDIV || o == .LSHR get_unsigned_monotonic_values(res, op(v, 0), greater, q, depth);
        else if o == .CALL && call_iid(v) == IID_USUB_SAT get_unsigned_monotonic_values(res, op(v, 0), greater, q, depth);
    }
}
simplify_icmp_using_monotonic_values :: (pred: u8, lhs: Value_Id, rhs: Value_Id, q: Simplify_Query) -> Value_Id {
    if pred != ICMP_UGE && pred != ICMP_ULT return NONE;
    gv: [..] Value_Id; gv.allocator = temp;
    lv: [..] Value_Id; lv.allocator = temp;
    get_unsigned_monotonic_values(*gv, lhs, true, q);
    get_unsigned_monotonic_values(*lv, rhs, false, q);
    for g: gv for l: lv if g == l return cf_bool(get_compare_ty(lhs), pred == ICMP_UGE);
    return NONE;
}
// simplifyICmpWithBinOpOnLHS
simplify_icmp_with_binop_on_lhs :: (pred: u8, lbo: Value_Id, rhs: Value_Id, q: Simplify_Query, max_recurse: u32) -> Value_Id {
    ity := get_compare_ty(rhs);
    oko, y := pm_c_binop_with(lbo, .OR, rhs);
    if oko {
        if pred == ICMP_SLT || pred == ICMP_SGE {
            rk := known_bits(rhs, q); yk := known_bits(y, q);
            if kb_is_non_negative(rk) && kb_is_negative(yk) return ifx pred == ICMP_SLT then get_true(ity) else get_false(ity);
            if kb_is_negative(rk) || kb_is_non_negative(yk) return ifx pred == ICMP_SLT then get_false(ity) else get_true(ity);
        }
    }
    oku, _, ur := pm_binop(lbo, .UREM);
    if oku && ur == rhs {
        if pred == {
            case ICMP_SGT; #through; case ICMP_SGE;
                if kb_is_non_negative(known_bits(rhs, q)) return get_false(ity);
            case ICMP_EQ; #through; case ICMP_UGT; #through; case ICMP_UGE; return get_false(ity);
            case ICMP_SLT; #through; case ICMP_SLE;
                if kb_is_non_negative(known_bits(rhs, q)) return get_true(ity);
            case ICMP_NE; #through; case ICMP_ULT; #through; case ICMP_ULE; return get_true(ity);
        }
    }
    okl, la, lc := pm_binop(lbo, .LSHR);
    okd, da, dc := pm_binop(lbo, .UDIV);
    cond := false;
    if okl && la == rhs { okc, c := pm_apint(lc); if okc && !ap_is_zero(c) cond = true; }
    if !cond && okd && da == rhs { okc, c := pm_apint(dc); if okc && !ap_is_one(c) cond = true; }
    if cond && is_known_non_zero(rhs, q) {
        if pred == ICMP_EQ || pred == ICMP_UGE || pred == ICMP_UGT return get_false(ity);
        if pred == ICMP_NE || pred == ICMP_ULT || pred == ICMP_ULE return get_true(ity);
    }
    {
        m := false;
        // m_UDiv(m_Mul(m_Specific(RHS), m_APInt(C1)), m_APInt(C2)) && C1 <=u C2
        if okd {
            okm, ma, mc := pm_binop(da, .MUL);
            ok1, c1 := pm_apint(mc); ok2, c2 := pm_apint(dc);
            if okm && ma == rhs && ok1 && ok2 && ap_ule(c1, c2) m = true;
        }
        if !m && okl {
            okm, ma, mc := pm_binop(la, .MUL);
            ok1, c1 := pm_apint(mc); ok2, c2 := pm_apint(lc);
            if okm && ma == rhs && ok1 && ok2 && ap_ule(c1, ap_shl_ap(ap_one(c2.bits), c2)) m = true;
        }
        if !m && okd {
            oks, sa, sc := pm_binop(da, .SHL);
            ok1, c1 := pm_apint(sc); ok2, c2 := pm_apint(dc);
            if oks && sa == rhs && ok1 && ok2 && ap_ule(ap_shl_ap(ap_one(c1.bits), c1), c2) m = true;
        }
        if m {
            if pred == ICMP_UGT return get_false(ity);
            if pred == ICMP_ULE return get_true(ity);
        }
    }
    oks, sc, sr := pm_binop(lbo, .SUB);
    if oks && sr == rhs {
        okc, c := pm_apint_ap(sc);
        if okc && ap_get_bit(c, 0) && icmp_is_equality(pred) return ifx pred == ICMP_EQ then get_false(ity) else get_true(ity);
    }
    return NONE;
}
// trySimplifyICmpWithAdds
try_simplify_icmp_with_adds :: (pred: u8, lhs_in: Value_Id, rhs_in: Value_Id, q: Simplify_Query) -> bool {
    if !cmp_is_signed(pred) || !q.use_instr_info return false;
    lhs := lhs_in; rhs := rhs_in;
    is_nsw_add :: (v: Value_Id) -> bool { return opr_code(v) == .ADD && (opr_flags(v) & F_NSW) != 0; }
    if !is_nsw_add(rhs) { t := lhs; lhs = rhs; rhs = t; }
    if !is_nsw_add(rhs) return false;
    oka, x, c1v := pm_binop(lhs, .ADD);
    if !oka return false;
    ok1, c1 := pm_apint(c1v);
    if !ok1 return false;
    okb, bx, c2v := pm_binop(rhs, .ADD);
    if !okb || bx != x return false;
    ok2, c2 := pm_apint(c2v);
    if !ok2 return false;
    return (ap_sle(c1, c2) && ap_is_non_negative(c1)) || (ap_sle(c2, c1) && ap_is_non_positive(c1));
}
// simplifyICmpWithBinOp
simplify_icmp_with_binop :: (pred_in: u8, lhs: Value_Id, rhs: Value_Id, q: Simplify_Query, max_recurse: u32) -> Value_Id {
    pred := pred_in;
    lbo := ifx is_binary_operator(lhs) then lhs else NONE;
    rbo := ifx is_binary_operator(rhs) then rhs else NONE;
    if max_recurse > 0 && (lbo != NONE || rbo != NONE) {
        a, b, c, d: Value_Id = NONE;
        no_lhs_wrap := false; no_rhs_wrap := false;
        if lbo != NONE && inst_op(lbo) == .ADD {
            a = op(lbo, 0); b = op(lbo, 1);
            no_lhs_wrap = icmp_is_equality(pred) || (cmp_is_unsigned(pred) && iiq_nuw(q, lbo)) || (cmp_is_signed(pred) && iiq_nsw(q, lbo));
        }
        if rbo != NONE && inst_op(rbo) == .ADD {
            c = op(rbo, 0); d = op(rbo, 1);
            no_rhs_wrap = icmp_is_equality(pred) || (cmp_is_unsigned(pred) && iiq_nuw(q, rbo)) || (cmp_is_signed(pred) && iiq_nsw(q, rbo));
        }
        if a != NONE && (a == rhs || b == rhs) && no_lhs_wrap {
            v := simplify_icmp_inst(pred, false, ifx a == rhs then b else a, const_null_value(vtype(rhs)), q, max_recurse - 1);
            if v != NONE return v;
        }
        if c != NONE && (c == lhs || d == lhs) && no_rhs_wrap {
            v := simplify_icmp_inst(pred, false, const_null_value(vtype(lhs)), ifx c == lhs then d else c, q, max_recurse - 1);
            if v != NONE return v;
        }
        can := (no_lhs_wrap && no_rhs_wrap) || try_simplify_icmp_with_adds(pred, lhs, rhs, q);
        if a != NONE && c != NONE && (a == c || a == d || b == c || b == d) && can {
            y, z: Value_Id;
            if a == c { y = b; z = d; }
            else if a == d { y = b; z = c; }
            else if b == c { y = a; z = d; }
            else { y = a; z = c; }
            v := simplify_icmp_inst(pred, false, y, z, q, max_recurse - 1);
            if v != NONE return v;
        }
    }
    if lbo != NONE {
        v := simplify_icmp_with_binop_on_lhs(pred, lbo, rhs, q, max_recurse);
        if v != NONE return v;
    }
    if rbo != NONE {
        v := simplify_icmp_with_binop_on_lhs(cmp_swapped(pred), rbo, lhs, q, max_recurse);
        if v != NONE return v;
    }
    if !cmp_is_unsigned(pred) {
        okn, nz := pm_neg(lhs);
        if okn && opr_code(nz) == .ZEXT {
            okc, c := pm_apint(rhs);
            if okc {
                if ap_is_strictly_positive(c) {
                    if pred == ICMP_SLT || pred == ICMP_NE return get_true(get_compare_ty(rhs));
                    if pred == ICMP_SGE || pred == ICMP_EQ return get_false(get_compare_ty(rhs));
                }
                if ap_is_non_negative(c) {
                    if pred == ICMP_SLE return get_true(get_compare_ty(rhs));
                    if pred == ICMP_SGT return get_false(get_compare_ty(rhs));
                }
            }
        }
    }
    oksh, sh0, _ := pm_binop(lhs, .SHL);
    if oksh && pm_power2(sh0) {
        okc, c := pm_apint_ap(rhs);
        if okc && !ap_is_power_of_2(c) {
            if iiq_nsw(q, lbo) || iiq_nuw(q, lbo) || pm_one(sh0) || !ap_is_zero(c) {
                if pred == ICMP_EQ return get_false(get_compare_ty(rhs));
                if pred == ICMP_NE return get_true(get_compare_ty(rhs));
            }
        }
        if pm_sign_mask(rhs) {
            if pred == ICMP_UGT return get_false(get_compare_ty(rhs));
            if pred == ICMP_ULE return get_true(get_compare_ty(rhs));
        }
    }
    if max_recurse == 0 || lbo == NONE || rbo == NONE || inst_op(lbo) != inst_op(rbo) return NONE;
    if op(lbo, 0) == op(rbo, 0) {
        o := inst_op(lbo);
        if o == .SHL {
            nuw := iiq_nuw(q, lbo) && iiq_nuw(q, rbo);
            nsw := iiq_nsw(q, lbo) && iiq_nsw(q, rbo);
            if !(!nuw || (cmp_is_signed(pred) && !nsw) || !is_known_non_zero(op(lbo, 0), q)) {
                v := simplify_icmp_inst(pred, false, op(lbo, 1), op(rbo, 1), q, max_recurse - 1);
                if v != NONE return v;
            }
        } else if o == .AND || o == .OR {
            ok1, c1 := pm_apint(op(lbo, 1));
            ok2, c2 := pm_apint(op(rbo, 1));
            if icmp_is_relational(pred) && ok1 && ok2 {
                if !ap_is_subset_of(c1, c2) { t := c1; c1 = c2; c2 = t; pred = cmp_swapped(pred); }
                if ap_is_subset_of(c1, c2) {
                    if pred == ICMP_ULE return get_true(get_compare_ty(lhs));
                    if pred == ICMP_UGT return get_false(get_compare_ty(lhs));
                    if ap_is_non_negative(c1) == ap_is_non_negative(c2) {
                        if pred == ICMP_SLE return get_true(get_compare_ty(lhs));
                        if pred == ICMP_SGT return get_false(get_compare_ty(lhs));
                    }
                }
            }
        }
    }
    if op(lbo, 1) == op(rbo, 1) {
        o := inst_op(lbo);
        if o == .UDIV || o == .LSHR {
            if !(cmp_is_signed(pred) || !iiq_exact(q, lbo) || !iiq_exact(q, rbo)) {
                v := simplify_icmp_inst(pred, false, op(lbo, 0), op(rbo, 0), q, max_recurse - 1);
                if v != NONE return v;
            }
        } else if o == .SDIV {
            if !(!icmp_is_equality(pred) || !iiq_exact(q, lbo) || !iiq_exact(q, rbo)) {
                v := simplify_icmp_inst(pred, false, op(lbo, 0), op(rbo, 0), q, max_recurse - 1);
                if v != NONE return v;
            }
        } else if o == .ASHR {
            if iiq_exact(q, lbo) && iiq_exact(q, rbo) {
                v := simplify_icmp_inst(pred, false, op(lbo, 0), op(rbo, 0), q, max_recurse - 1);
                if v != NONE return v;
            }
        } else if o == .SHL {
            nuw := iiq_nuw(q, lbo) && iiq_nuw(q, rbo);
            nsw := iiq_nsw(q, lbo) && iiq_nsw(q, rbo);
            if (nuw || nsw) && !(!nsw && cmp_is_signed(pred)) {
                v := simplify_icmp_inst(pred, false, op(lbo, 0), op(rbo, 0), q, max_recurse - 1);
                if v != NONE return v;
            }
        }
    }
    return NONE;
}
// simplifyICmpWithMinMax
simplify_icmp_with_min_max :: (pred_in: u8, lhs_in: Value_Id, rhs_in: Value_Id, q: Simplify_Query, max_recurse: u32) -> Value_Id {
    pred := pred_in; lhs := lhs_in; rhs := rhs_in;
    ity := get_compare_ty(lhs);
    a, b: Value_Id;
    for pass: 0..1 {
        max_id := ifx pass == 0 then IID_SMAX else IID_UMAX;
        min_id := ifx pass == 0 then IID_SMIN else IID_UMIN;
        ge := ifx pass == 0 then cast(u8) ICMP_SGE else ICMP_UGE;
        le := ifx pass == 0 then cast(u8) ICMP_SLE else ICMP_ULE;
        gt := ifx pass == 0 then cast(u8) ICMP_SGT else ICMP_UGT;
        lt := ifx pass == 0 then cast(u8) ICMP_SLT else ICMP_ULT;
        p: u8 = BAD_ICMP_PREDICATE;
        eqp: u8;
        if call_iid(lhs) == max_id && (op(lhs, 0) == rhs || op(lhs, 1) == rhs) {
            a = op(lhs, 0); b = op(lhs, 1);
            if a != rhs { t := a; a = b; b = t; }
            eqp = ge; p = pred;
        } else if call_iid(rhs) == max_id && (op(rhs, 0) == lhs || op(rhs, 1) == lhs) {
            a = op(rhs, 0); b = op(rhs, 1);
            if a != lhs { t := a; a = b; b = t; }
            eqp = ge; p = cmp_swapped(pred);
        } else if call_iid(lhs) == min_id && (op(lhs, 0) == rhs || op(lhs, 1) == rhs) {
            a = op(lhs, 0); b = op(lhs, 1);
            if a != rhs { t := a; a = b; b = t; }
            eqp = le; p = cmp_swapped(pred);
        } else if call_iid(rhs) == min_id && (op(rhs, 0) == lhs || op(rhs, 1) == lhs) {
            a = op(rhs, 0); b = op(rhs, 1);
            if a != lhs { t := a; a = b; b = t; }
            eqp = le; p = pred;
        }
        if p != BAD_ICMP_PREDICATE {
            if p == ICMP_EQ || p == le {
                v := extract_equivalent_condition(lhs, eqp, a, b); if v != NONE return v;
                v = extract_equivalent_condition(rhs, eqp, a, b); if v != NONE return v;
                if max_recurse > 0 { v = simplify_icmp_inst(eqp, false, a, b, q, max_recurse - 1); if v != NONE return v; }
            } else if p == ICMP_NE || p == gt {
                inv := cmp_inverse(eqp);
                v := extract_equivalent_condition(lhs, inv, a, b); if v != NONE return v;
                v = extract_equivalent_condition(rhs, inv, a, b); if v != NONE return v;
                if max_recurse > 0 { v = simplify_icmp_inst(inv, false, a, b, q, max_recurse - 1); if v != NONE return v; }
            } else if p == ge return get_true(ity);
            else if p == lt return get_false(ity);
        }
    }
    li := call_iid(lhs);
    if li == IID_UMIN || li == IID_SMIN { t := lhs; lhs = rhs; rhs = t; pred = cmp_swapped(pred); }
    shares :: (x: Value_Id, y: Value_Id) -> bool { return op(x, 0) == op(y, 0) || op(x, 0) == op(y, 1) || op(x, 1) == op(y, 0) || op(x, 1) == op(y, 1); }
    if call_iid(lhs) == IID_SMAX && call_iid(rhs) == IID_SMIN && shares(lhs, rhs) {
        if pred == ICMP_SGE return get_true(ity);
        if pred == ICMP_SLT return get_false(ity);
    } else if call_iid(lhs) == IID_UMAX && call_iid(rhs) == IID_UMIN && shares(lhs, rhs) {
        if pred == ICMP_UGE return get_true(ity);
        if pred == ICMP_ULT return get_false(ity);
    }
    return NONE;
}
// simplifyICmpWithDominatingAssume
simplify_icmp_with_dominating_assume :: (pred: u8, ss: bool, lhs: Value_Id, rhs: Value_Id, q: Simplify_Query) -> Value_Id {
    if !q.ac || q.cxt == NONE return NONE;
    for base: Value_Id.[lhs, rhs] {
        for e: ac_assumptions_for(q.ac, base) {
            if vkind(e.assume) == .DEAD continue;
            a := e.assume;
            imp := is_implied_condition_pred(op(a, 0), pred, ss, lhs, rhs, true);
            if imp >= 0 && is_valid_assume_q(a, q) return const_int(get_compare_ty(lhs), cast(u64) imp);
        }
    }
    return NONE;
}
// simplifyICmpWithIntrinsicOnLHS
simplify_icmp_with_intrinsic_on_lhs :: (pred: u8, lhs: Value_Id, rhs: Value_Id) -> Value_Id {
    id := call_iid(lhs);
    if id == IID_UADD_SAT {
        if is_c_op_of(rhs, .ADD, op(lhs, 0), op(lhs, 1)) {
            if pred == ICMP_UGE return get_true(get_compare_ty(lhs));
            if pred == ICMP_ULT return get_false(get_compare_ty(lhs));
        }
        return NONE;
    }
    if id == IID_USUB_SAT {
        oks, a, b := pm_binop(rhs, .SUB);
        if oks && a == op(lhs, 0) && b == op(lhs, 1) {
            if pred == ICMP_ULE return get_true(get_compare_ty(lhs));
            if pred == ICMP_UGT return get_false(get_compare_ty(lhs));
        }
    }
    return NONE;
}
// getRange
get_range_of :: (v: Value_Id, q: Simplify_Query) -> (bool, Const_Range) {
    r: Const_Range;
    if is_inst(v) {
        m := iiq_metadata(q, v, "range");
        if m != NONE return true, cr_from_range_md(m);
    }
    if vkind(v) == .ARGUMENT { ok, ar := arg_range(v); return ok, ar; }
    if is_inst(v) && is_call_base(v) { ok, cr := call_range(v); return ok, cr; }
    return false, r;
}
simplify_icmp_inst :: (pred: u8, ss: bool, lhs: Value_Id, rhs: Value_Id, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    return simplify_icmp_inst_impl(pred, ss, lhs, rhs, q, max_recurse);
}
is_cast_inst :: (v: Value_Id) -> bool { return is_inst(v) && is_cast_op(inst_op(v)); }
simplify_icmp_inst_impl :: (pred_in: u8, ss: bool, lhs_in: Value_Id, rhs_in: Value_Id, q: Simplify_Query, max_recurse: u32) -> Value_Id {
    pred := pred_in; lhs := lhs_in; rhs := rhs_in;
    if is_const(lhs) {
        if is_const(rhs) return cfo_compare_inst_operands(pred, lhs, rhs);
        t := lhs; lhs = rhs; rhs = t; pred = cmp_swapped(pred);
    }
    ity := get_compare_ty(lhs);
    if pm_poison(rhs) return const_poison(ity);
    if sq_is_undef_value(q, rhs) && icmp_is_equality(pred) return const_undef(ity);
    if lhs == rhs || sq_is_undef_value(q, rhs) return cf_bool(ity, cmp_is_true_when_equal(pred));
    v := simplify_icmp_of_bools(pred, lhs, rhs, q); if v != NONE return v;
    v = simplify_icmp_with_zero(pred, lhs, rhs, q); if v != NONE return v;
    v = simplify_icmp_with_constant(pred, lhs, rhs, q); if v != NONE return v;
    okr, rcr := get_range_of(rhs, q);
    if okr {
        okl, lcr := get_range_of(lhs, q);
        if okl {
            if cr_icmp(lcr, pred, rcr) return get_true(ity);
            if cr_icmp(lcr, cmp_inverse(pred), rcr) return get_false(ity);
        }
    }
    if is_cast_inst(lhs) && (is_const(rhs) || is_cast_inst(rhs)) {
        li := lhs;
        src := op(li, 0);
        sty := vtype(src); dty := vtype(li);
        lo := inst_op(li);
        if max_recurse > 0 && (lo == .PTRTOINT || lo == .PTRTOADDR) && dl_address_type(sty) == dty {
            if is_const(rhs) {
                v = simplify_icmp_inst(pred, false, src, ce_cast(.INTTOPTR, rhs, sty), q, max_recurse - 1);
                if v != NONE return v;
            } else if is_inst(rhs) && (inst_op(rhs) == .PTRTOINT || inst_op(rhs) == .PTRTOADDR) {
                if vtype(op(rhs, 0)) == sty {
                    v = simplify_icmp_inst(pred, false, src, op(rhs, 0), q, max_recurse - 1);
                    if v != NONE return v;
                }
            }
        }
        if lo == .ZEXT {
            if is_inst(rhs) && inst_op(rhs) == .ZEXT {
                if max_recurse > 0 && sty == vtype(op(rhs, 0)) {
                    v = simplify_icmp_inst(icmp_unsigned_predicate(pred), false, src, op(rhs, 0), q, max_recurse - 1);
                    if v != NONE return v;
                }
            } else if is_inst(rhs) && inst_op(rhs) == .SEXT {
                if src == op(rhs, 0) {
                    if pred == ICMP_ULE || pred == ICMP_SGE return get_true(ity);
                    if pred == ICMP_UGT || pred == ICMP_SLT return get_false(ity);
                }
            } else if pm_imm_constant(rhs) {
                c := rhs;
                tr := cfo_cast_operand(.TRUNC, c, sty);
                rext := cfo_cast_operand(.ZEXT, tr, dty);
                any_eq := cfo_compare_inst_operands(ICMP_EQ, rext, c);
                if cf_is_all_ones(any_eq) && max_recurse > 0 {
                    v = simplify_icmp_inst(icmp_unsigned_predicate(pred), false, src, tr, q, max_recurse - 1);
                    if v != NONE return v;
                }
                if is_null_value(any_eq) {
                    if pred == {
                        case ICMP_EQ; #through; case ICMP_UGT; #through; case ICMP_UGE; return const_null_value(ity);
                        case ICMP_NE; #through; case ICMP_ULT; #through; case ICMP_ULE; return cf_all_ones(ity);
                        case ICMP_SGT; #through; case ICMP_SGE; return cfo_compare_inst_operands(ICMP_SLT, c, const_null_value(vtype(c)));
                        case ICMP_SLT; #through; case ICMP_SLE; return cfo_compare_inst_operands(ICMP_SGE, c, const_null_value(vtype(c)));
                    }
                }
            }
        }
        if lo == .SEXT {
            if is_inst(rhs) && inst_op(rhs) == .SEXT {
                if max_recurse > 0 && sty == vtype(op(rhs, 0)) {
                    v = simplify_icmp_inst(pred, false, src, op(rhs, 0), q, max_recurse - 1);
                    if v != NONE return v;
                }
            } else if is_inst(rhs) && inst_op(rhs) == .ZEXT {
                if src == op(rhs, 0) {
                    if pred == ICMP_UGE || pred == ICMP_SLE return get_true(ity);
                    if pred == ICMP_ULT || pred == ICMP_SGT return get_false(ity);
                }
            } else if pm_imm_constant(rhs) {
                c := rhs;
                tr := cfo_cast_operand(.TRUNC, c, sty);
                rext := cfo_cast_operand(.SEXT, tr, dty);
                any_eq := cfo_compare_inst_operands(ICMP_EQ, rext, c);
                if cf_is_all_ones(any_eq) && max_recurse > 0 {
                    v = simplify_icmp_inst(pred, false, src, tr, q, max_recurse - 1);
                    if v != NONE return v;
                }
                if is_null_value(any_eq) {
                    if pred == {
                        case ICMP_EQ; return const_null_value(ity);
                        case ICMP_NE; return cf_all_ones(ity);
                        case ICMP_SGT; #through; case ICMP_SGE; return cfo_compare_inst_operands(ICMP_SLT, c, const_null_value(vtype(c)));
                        case ICMP_SLT; #through; case ICMP_SLE; return cfo_compare_inst_operands(ICMP_SGE, c, const_null_value(vtype(c)));
                        case ICMP_UGT; #through; case ICMP_UGE;
                            if max_recurse > 0 { v = simplify_icmp_inst(ICMP_SLT, false, src, const_null_value(sty), q, max_recurse - 1); if v != NONE return v; }
                        case ICMP_ULT; #through; case ICMP_ULE;
                            if max_recurse > 0 { v = simplify_icmp_inst(ICMP_SGE, false, src, const_null_value(sty), q, max_recurse - 1); if v != NONE return v; }
                    }
                }
            }
        }
    }
    if icmp_is_equality(pred) && !pm_zero(rhs) && is_known_non_equal(lhs, rhs, q)
        return ifx pred == ICMP_NE then get_true(ity) else get_false(ity);
    v = simplify_icmp_with_binop(pred, lhs, rhs, q, max_recurse); if v != NONE return v;
    v = simplify_icmp_with_min_max(pred, lhs, rhs, q, max_recurse); if v != NONE return v;
    v = simplify_icmp_with_intrinsic_on_lhs(pred, lhs, rhs); if v != NONE return v;
    v = simplify_icmp_with_intrinsic_on_lhs(cmp_swapped(pred), rhs, lhs); if v != NONE return v;
    v = simplify_icmp_using_monotonic_values(pred, lhs, rhs, q); if v != NONE return v;
    v = simplify_icmp_using_monotonic_values(cmp_swapped(pred), rhs, lhs, q); if v != NONE return v;
    v = simplify_icmp_with_dominating_assume(pred, ss, lhs, rhs, q); if v != NONE return v;
    res := is_implied_by_dom_condition_pred(pred, ss, lhs, rhs, q.cxt);
    if res >= 0 return cf_bool(ity, res == 1);
    if is_ptr_type(vtype(lhs)) {
        c := compute_pointer_icmp(pred, lhs, rhs, q);
        if c != NONE return c;
    }
    if is_select_inst(lhs) || is_select_inst(rhs) {
        v = thread_cmp_over_select(pred, ss, lhs, rhs, q, max_recurse); if v != NONE return v;
    }
    if is_phi(lhs) || is_phi(rhs) {
        v = thread_cmp_over_phi(pred, ss, lhs, rhs, q, max_recurse); if v != NONE return v;
    }
    return NONE;
}

// ---------------------------------------------------------------- fcmp

simplify_fcmp_inst :: (pred_in: u8, lhs_in: Value_Id, rhs_in: Value_Id, fmf: u32, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    pred := pred_in; lhs := lhs_in; rhs := rhs_in;
    if is_const(lhs) {
        if is_const(rhs) {
            r := cfo_compare_inst_operands(pred, lhs, rhs, q.cxt);
            if r != NONE return r;
        } else { t := lhs; lhs = rhs; rhs = t; pred = cmp_swapped(pred); }
    }
    rt := get_compare_ty(lhs);
    if pred == FCMP_FALSE return get_false(rt);
    if pred == FCMP_TRUE return get_true(rt);
    if pm_poison(lhs) || pm_poison(rhs) return const_poison(rt);
    if sq_is_undef_value(q, lhs) || sq_is_undef_value(q, rhs) return cf_bool(rt, cmp_is_unordered(pred));
    if lhs == rhs {
        if cmp_is_true_when_equal(pred) return get_true(rt);
        if cmp_is_false_when_equal(pred) return get_false(rt);
    }
    nnan := (fmf & FMF_NNAN) != 0;
    if pred == FCMP_ORD || pred == FCMP_UNO {
        rc := compute_known_fp_class(rhs, FC_ALL_FLAGS, q);
        lc := compute_known_fp_class(lhs, FC_ALL_FLAGS, q);
        if nnan || (kfpc_is_known_never_nan(rc) && kfpc_is_known_never_nan(lc)) return cf_bool(rt, pred == FCMP_ORD);
        if kfpc_is_known_always_nan(rc) || kfpc_is_known_always_nan(lc) return cf_bool(rt, pred == FCMP_UNO);
    }
    res := is_implied_by_dom_condition_pred(pred, false, lhs, rhs, q.cxt);
    if res >= 0 return cf_bool(rt, res == 1);
    okc, c := pm_apfloat(rhs, true);
    have_full := false;
    full: Known_FP_Class;
    lhs_class :: (lhs: Value_Id, fmf: u32, interested: u32, q: Simplify_Query, have_full: bool, full: Known_FP_Class) -> Known_FP_Class {
        if have_full return full;
        return compute_known_fp_class_fmf(lhs, fmf, interested, q);
    }
    if okc && q.cxt != NONE {
        cv, ct := fcmp_to_class_test(pred, inst_fn(q.cxt), lhs, c);
        if cv != NONE {
            full = lhs_class(lhs, fmf, FC_ALL_FLAGS, q, false, full);
            have_full = true;
            if (full.known_fp_classes & ct) == FC_NONE return get_false(rt);
            if (full.known_fp_classes & ~ct) == FC_NONE return get_true(rt);
        }
    }
    if okc {
        if apf_is_nan(c) return cf_bool(rt, cmp_is_unordered(pred));
        if apf_is_negative(c) && !apf_is_neg_zero(c) {
            interested: u32 = KFPC_ORDERED_LESS_THAN_ZERO_MASK;
            if pred == FCMP_UGE || pred == FCMP_UGT || pred == FCMP_UNE {
                k := lhs_class(lhs, fmf, interested, q, have_full, full);
                if kfpc_cannot_be_ordered_less_than_zero(k) return get_true(rt);
            } else if pred == FCMP_OEQ || pred == FCMP_OLE || pred == FCMP_OLT {
                k := lhs_class(lhs, fmf, interested, q, have_full, full);
                if kfpc_cannot_be_ordered_less_than_zero(k) return get_false(rt);
            }
        }
        id := call_iid(lhs);
        is_max := false; is_min := false; c2: APFloat;
        if id == IID_MAXNUM || id == IID_MAXIMUMNUM { ok2, cc := pm_apfloat(op(lhs, 1)); if ok2 { is_max = true; c2 = cc; } }
        if id == IID_MINNUM || id == IID_MINIMUMNUM { ok2, cc := pm_apfloat(op(lhs, 1)); if ok2 { is_min = true; c2 = cc; } }
        if (is_max && apf_compare(c2, c) == .GREATER) || (is_min && apf_compare(c2, c) == .LESS) {
            if pred == {
                case FCMP_OEQ; #through; case FCMP_UEQ; return get_false(rt);
                case FCMP_ONE; #through; case FCMP_UNE; return get_true(rt);
                case FCMP_OGE; #through; case FCMP_UGE; #through; case FCMP_OGT; #through; case FCMP_UGT; return cf_bool(rt, is_max);
                case FCMP_OLE; #through; case FCMP_ULE; #through; case FCMP_OLT; #through; case FCMP_ULT; return cf_bool(rt, !is_max);
            }
            fatal("internal: unexpected fcmp predicate");
        }
    }
    if pm_any_zero_fp(rhs) {
        if pred == FCMP_OGE || pred == FCMP_ULT {
            interested: u32 = KFPC_ORDERED_LESS_THAN_ZERO_MASK;
            if !nnan interested |= FC_NAN;
            k := lhs_class(lhs, fmf, interested, q, have_full, full);
            if (nnan || kfpc_is_known_never_nan(k)) && kfpc_cannot_be_ordered_less_than_zero(k)
                return ifx pred == FCMP_OGE then get_true(rt) else get_false(rt);
        } else if pred == FCMP_UGE || pred == FCMP_OLT {
            k := lhs_class(lhs, fmf, KFPC_ORDERED_LESS_THAN_ZERO_MASK, q, have_full, full);
            if kfpc_cannot_be_ordered_less_than_zero(k) return ifx pred == FCMP_UGE then get_true(rt) else get_false(rt);
        }
    }
    if is_select_inst(lhs) || is_select_inst(rhs) {
        v := thread_cmp_over_select(pred, false, lhs, rhs, q, max_recurse); if v != NONE return v;
    }
    if is_phi(lhs) || is_phi(rhs) {
        v := thread_cmp_over_phi(pred, false, lhs, rhs, q, max_recurse); if v != NONE return v;
    }
    return NONE;
}
apf_compare :: (a: APFloat, b: APFloat) -> Fp_Cmp { x := a; y := b; return fp_compare(x.k, apf_words(*x), apf_words(*y)); }

// ---------------------------------------------------------------- simplifyWithOpsReplaced

Op_Rep :: struct { from: Value_Id; to: Value_Id; }
// isTriviallyVectorizable (llvm/lib/Analysis/VectorUtils.cpp)
is_trivially_vectorizable :: (id: Intrinsic_Id) -> bool {
    if id == {
        case IID_ABS; #through; case IID_BSWAP; #through; case IID_BITREVERSE; #through; case IID_CTPOP; #through; case IID_CTLZ; #through;
        case IID_CTTZ; #through; case IID_FSHL; #through; case IID_FSHR; #through; case IID_SMAX; #through; case IID_SMIN; #through;
        case IID_UMAX; #through; case IID_UMIN; #through; case IID_SADD_SAT; #through; case IID_SSUB_SAT; #through; case IID_UADD_SAT; #through;
        case IID_USUB_SAT; #through; case IID_SMUL_FIX; #through; case IID_SMUL_FIX_SAT; #through; case IID_UMUL_FIX; #through;
        case IID_UMUL_FIX_SAT; #through; case IID_UADD_WITH_OVERFLOW; #through; case IID_SADD_WITH_OVERFLOW; #through;
        case IID_USUB_WITH_OVERFLOW; #through; case IID_SSUB_WITH_OVERFLOW; #through; case IID_UMUL_WITH_OVERFLOW; #through;
        case IID_SMUL_WITH_OVERFLOW; #through; case IID_SQRT; #through; case IID_ASIN; #through; case IID_ACOS; #through; case IID_ATAN; #through;
        case IID_ATAN2; #through; case IID_SIN; #through; case IID_COS; #through; case IID_SINCOS; #through; case IID_SINCOSPI; #through;
        case IID_TAN; #through; case IID_SINH; #through; case IID_COSH; #through; case IID_TANH; #through; case IID_EXP; #through;
        case IID_EXP10; #through; case IID_EXP2; #through; case IID_FREXP; #through; case IID_LDEXP; #through; case IID_LOG; #through;
        case IID_LOG10; #through; case IID_LOG2; #through; case IID_FABS; #through; case IID_MINNUM; #through; case IID_MAXNUM; #through;
        case IID_MINIMUM; #through; case IID_MAXIMUM; #through; case IID_MINIMUMNUM; #through; case IID_MAXIMUMNUM; #through;
        case IID_MODF; #through; case IID_COPYSIGN; #through; case IID_FLOOR; #through; case IID_CEIL; #through; case IID_TRUNC; #through;
        case IID_RINT; #through; case IID_NEARBYINT; #through; case IID_ROUND; #through; case IID_ROUNDEVEN; #through; case IID_POW; #through;
        case IID_FMA; #through; case IID_FMULADD; #through; case IID_IS_FPCLASS; #through; case IID_POWI; #through;
        case IID_CANONICALIZE; #through; case IID_FPTOSI_SAT; #through; case IID_FPTOUI_SAT; #through; case IID_LROUND; #through;
        case IID_LLROUND; #through; case IID_LRINT; #through; case IID_LLRINT; #through; case IID_UCMP; #through; case IID_SCMP; #through;
        case IID_CLMUL;
            return true;
    }
    return false;
}
// ShuffleVectorInst::isSelect
shuffle_is_select :: (s: Value_Id) -> bool {
    mask := shuffle_mask(s);
    n := cast(s64) type_count(vtype(op(s, 0)));
    if mask.count != n return false;   // changesLength
    uses_l := false; uses_r := false;
    for mask { if it == POISON_MASK_ELEM continue; if it < n uses_l = true; else uses_r = true; }
    if !(uses_l && uses_r) && (uses_l || uses_r) return false;   // isSingleSourceMask
    for m, i: mask {
        if m == POISON_MASK_ELEM continue;
        if m != i && m != n + i return false;
    }
    return true;
}
// isNotCrossLaneOperation
is_not_cross_lane_operation :: (i: Value_Id) -> bool {
    id := call_iid(i);
    if id != NOT_INTRINSIC return is_trivially_vectorizable(id);
    o := inst_op(i);
    if o == .SHUFFLEVECTOR && !shuffle_is_select(i) return false;
    return !is_call_base(i) && o != .BITCAST && o != .EXTRACTELEMENT;
}
// MinMaxIntrinsic::getIdentity / getPredicate
min_max_identity :: (id: Intrinsic_Id, bits: u32) -> APInt {
    if id == IID_UMIN return ap_all_ones(bits);
    if id == IID_UMAX return ap_zero(bits);
    if id == IID_SMIN return ap_signed_max(bits);
    return ap_signed_min(bits);
}
min_max_predicate :: (id: Intrinsic_Id) -> u8 {
    if id == IID_UMIN return ICMP_ULT; if id == IID_UMAX return ICMP_UGT; if id == IID_SMIN return ICMP_SLT;
    return ICMP_SGT;
}
// Constant::isNotMinSignedValue
is_not_min_signed_value :: (c: Value_Id) -> bool {
    k := vkind(c);
    if k == .C_INT return !ap_is_min_signed(const_ap(c));
    if k == .C_FP return !ap_is_min_signed(ap_from_words(type_bits(scalar_type(vtype(c))), const_fp_value(c)));
    if type_kind(vtype(c)) == .VECTOR {
        n := type_count(vtype(c));
        for i: 0..cast(s64) n - 1 {
            e := cf_elt(c, cast(u64) i);
            if e == NONE || !is_not_min_signed_value(e) return false;
        }
        return true;
    }
    if is_vector_type(vtype(c)) {
        s := get_splat_value(c);
        if s != NONE return is_not_min_signed_value(s);
    }
    return false;
}
// simplifyWithOpsReplaced
simplify_with_ops_replaced :: (v: Value_Id, ops: [] Op_Rep, q: Simplify_Query, allow_refinement: bool, drop_flags: *[..] Value_Id, max_recurse_in: u32) -> Value_Id {
    for ops {
        if is_const(it.from) return NONE;
        if v == it.from return it.to;
    }
    if max_recurse_in == 0 return NONE;
    max_recurse := max_recurse_in - 1;
    if !is_inst(v) return NONE;
    i := v;
    if is_phi(i) return NONE;
    if call_iid(i) == IID_IS_CONSTANT return NONE;
    if inst_op(i) == .FREEZE return NONE;
    for ops if is_vector_type(vtype(it.from)) && !is_not_cross_lane_operation(i) return NONE;
    new_ops: [..] Value_Id; new_ops.allocator = temp;
    any_replaced := false;
    n := nops(i);
    for k: 0..cast(s64) n - 1 {
        o := op(i, cast(u32) k);
        no := simplify_with_ops_replaced(o, ops, q, allow_refinement, drop_flags, max_recurse);
        if no != NONE { array_add(*new_ops, no); any_replaced = o != no; }
        else array_add(*new_ops, o);
        if pm_undef_value(new_ops[new_ops.count - 1]) && !q.can_use_undef return NONE;
    }
    if !any_replaced return NONE;
    if !allow_refinement {
        if is_binary_operator(i) {
            opc := inst_op(i);
            ity := vtype(i);
            if !is_fp_type(scalar_type(ity)) {
                if new_ops[0] == cf_binop_identity(opc, ity, false) return new_ops[1];
                if new_ops[1] == cf_binop_identity(opc, ity, true) return new_ops[0];
            }
            if (opc == .AND || opc == .OR) && new_ops[0] == new_ops[1] {
                if opc == .OR && (inst(i).flags & F_EXACT) != 0 {
                    if !drop_flags return NONE;
                    array_add(drop_flags, i);
                }
                return new_ops[0];
            }
            if (opc == .SUB || opc == .XOR) && new_ops[0] == new_ops[1] {
                for ops if new_ops[0] == it.to return const_null_value(ity);
            }
            absorber := cf_binop_absorber(opc, ity, false);
            if absorber != NONE && (new_ops[0] == absorber || new_ops[1] == absorber) {
                for ops if implies_poison(i, it.from) return absorber;
            }
        }
        id := call_iid(i);
        if id != NOT_INTRINSIC {
            if (id == IID_SCMP || id == IID_UCMP) && new_ops[0] == new_ops[1] {
                if has_poison_generating_annotations(i) {
                    if !drop_flags return NONE;
                    array_add(drop_flags, i);
                }
                return const_int(vtype(i), 0);
            }
            if is_min_max_intrinsic(id) {
                identity := min_max_identity(id, type_bits(scalar_type(vtype(i))));
                result: Value_Id = NONE;
                if pm_specific_int_ap(new_ops[0], identity) result = new_ops[1];
                else if pm_specific_int_ap(new_ops[1], identity) result = new_ops[0];
                if result != NONE {
                    if has_poison_generating_annotations(i) {
                        if !drop_flags return NONE;
                        array_add(drop_flags, i);
                    }
                    return result;
                }
            }
        }
        if inst_op(i) == .GEP {
            if new_ops.count == 2 && pm_zero(new_ops[1]) return new_ops[0];
        }
    } else {
        s := simplify_instruction_with_operands_r(i, new_ops, q, max_recurse);
        if s != v return s;
        return NONE;
    }
    const_ops: [..] Value_Id; const_ops.allocator = temp;
    for new_ops { if !is_const(it) return NONE; array_add(*const_ops, it); }
    if !allow_refinement {
        id := call_iid(i);
        if can_create_poison(i, drop_flags == null) {
            if id == IID_ABS {
                if !is_not_min_signed_value(const_ops[0]) return NONE;
            } else return NONE;
        }
        if drop_flags && id != NOT_INTRINSIC {
            if id == IID_ABS || id == IID_CTLZ || id == IID_CTTZ const_ops[1] = const_int(ir.t_i1, 0);
        }
        res := cfo_inst_operands(i, const_ops, false);
        if drop_flags && res != NONE && has_poison_generating_annotations(i) array_add(drop_flags, i);
        return res;
    }
    return cfo_inst_operands(i, const_ops, false);
}
simplify_with_op_replaced :: (v: Value_Id, from: Value_Id, to: Value_Id, q: Simplify_Query, allow_refinement: bool, drop_flags: *[..] Value_Id, max_recurse: u32) -> Value_Id {
    ops: [1] Op_Rep;
    ops[0] = .{from, to};
    return simplify_with_ops_replaced(v, ops, q, allow_refinement, drop_flags, max_recurse);
}
// llvm::simplifyWithOpReplaced (public)
simplify_with_op_replaced_pub :: (v: Value_Id, from: Value_Id, to: Value_Id, q: Simplify_Query, allow_refinement: bool, drop_flags: *[..] Value_Id = null) -> Value_Id {
    if !allow_refinement return simplify_with_op_replaced(v, from, to, sq_without_undef(q), allow_refinement, drop_flags, RECURSION_LIMIT);
    return simplify_with_op_replaced(v, from, to, q, allow_refinement, drop_flags, RECURSION_LIMIT);
}

// ---------------------------------------------------------------- select

// simplifySelectBitTest
simplify_select_bit_test :: (tv: Value_Id, fv: Value_Id, x: Value_Id, y: APInt, true_when_unset: bool) -> Value_Id {
    and_c :: (v: Value_Id, x: Value_Id) -> (bool, APInt) { no: APInt; ok, a, b := pm_binop(v, .AND); if !ok || a != x return false, no; okc, c := pm_apint(b); return okc, c; }
    or_c :: (v: Value_Id, x: Value_Id) -> (bool, APInt) { no: APInt; ok, a, b := pm_binop(v, .OR); if !ok || a != x return false, no; okc, c := pm_apint(b); return okc, c; }
    if fv == x { ok, c := and_c(tv, x); if ok && ap_eq(y, ap_not(c)) return ifx true_when_unset then fv else tv; }
    if tv == x { ok, c := and_c(fv, x); if ok && ap_eq(y, ap_not(c)) return ifx true_when_unset then fv else tv; }
    if ap_is_power_of_2(y) {
        if fv == x {
            ok, c := or_c(tv, x);
            if ok && ap_eq(y, c) {
                if true_when_unset && (opr_flags(tv) & F_EXACT) != 0 return NONE;
                return ifx true_when_unset then tv else fv;
            }
        }
        if tv == x {
            ok, c := or_c(fv, x);
            if ok && ap_eq(y, c) {
                if !true_when_unset && (opr_flags(fv) & F_EXACT) != 0 return NONE;
                return ifx true_when_unset then tv else fv;
            }
        }
    }
    return NONE;
}
// simplifyCmpSelOfMaxMin
simplify_cmp_sel_of_max_min :: (cl_in: Value_Id, cr_in: Value_Id, pred_in: u8, tv_in: Value_Id, fv_in: Value_Id) -> Value_Id {
    cl := cl_in; cr := cr_in; pred := pred_in; tv := tv_in; fv := fv_in;
    if cr == tv || cr == fv { t := cl; cl = cr; cr = t; pred = cmp_swapped(pred); }
    if cl == fv { t := tv; tv = fv; fv = t; pred = cmp_inverse(pred); }
    x := cl; y := cr;
    peeked := false;
    if is_inst(fv) && inst_op(fv) == .SHUFFLEVECTOR && shuffle_is_select(fv) {
        if op(fv, 0) == y fv = op(fv, 1);
        else if op(fv, 1) == y fv = op(fv, 0);
        else return NONE;
        peeked = true;
    }
    id := call_iid(fv);
    if !is_min_max_intrinsic(id) || tv != x || !is_c_op_of_call(fv, x, y) return NONE;
    mmp := min_max_predicate(id);
    if mmp == cmp_strict(pred) return fv;
    if peeked return NONE;
    if pred == ICMP_EQ return fv;
    if pred == ICMP_NE return x;
    if mmp == cmp_strict(cmp_inverse(pred)) return x;
    return NONE;
}
is_c_op_of_call :: (c: Value_Id, a: Value_Id, b: Value_Id) -> bool { return (op(c, 0) == a && op(c, 1) == b) || (op(c, 0) == b && op(c, 1) == a); }
// decomposeBitTest (llvm/lib/Analysis/CmpInstAnalysis.cpp), with the defaults LookThroughTrunc = true, AllowNonZeroC = false, DecomposeAnd = false
Bit_Test :: struct { x: Value_Id; pred: u8; mask: APInt; c: APInt; }
decompose_bit_test_icmp :: (lhs_in: Value_Id, rhs: Value_Id, pred_in: u8, look_through_trunc := true, allow_non_zero_c := false, decompose_and := false) -> (bool, Bit_Test) {
    r: Bit_Test;
    lhs := lhs_in; pred := pred_in;
    okc, orig_c := pm_apint_ap(rhs);
    if (icmp_is_equality(pred) && !decompose_and) || !okc return false, r;
    inverted := false;
    if pred == ICMP_UGT || pred == ICMP_SGT || pred == ICMP_UGE || pred == ICMP_SGE { inverted = true; pred = cmp_inverse(pred); }
    c := orig_c;
    if pred == ICMP_ULE || pred == ICMP_SLE {
        if (ifx cmp_is_signed(pred) then ap_is_max_signed(c) else ap_is_all_ones(c)) return false, r;
        c = ap_add_u64(c, 1);
        pred = cmp_strict(pred);
    }
    bw := c.bits;
    if pred == ICMP_SLT {
        if ap_is_zero(c) { r.mask = ap_signed_min(bw); r.c = ap_zero(bw); r.pred = ICMP_NE; }
        else {
            fs := ap_xor(c, ap_signed_min(bw));
            if ap_is_power_of_2(fs) { r.mask = ap_neg(fs); r.c = ap_signed_min(bw); r.pred = ICMP_EQ; }
            else if ap_is_negated_power_of_2(fs) { r.mask = fs; r.c = c; r.pred = ICMP_NE; }
            else return false, r;
        }
    } else if pred == ICMP_ULT {
        if ap_is_power_of_2(c) { r.mask = ap_neg(c); r.c = ap_zero(bw); r.pred = ICMP_EQ; }
        else if ap_is_negated_power_of_2(c) { r.mask = c; r.c = c; r.pred = ICMP_NE; }
        else return false, r;
    } else if pred == ICMP_EQ || pred == ICMP_NE {
        oka, av, ac := pm_binop(lhs, .AND);
        okm, m := pm_apint_ap(ac);
        if oka && okm { lhs = av; r.mask = m; r.c = c; r.pred = pred; }
        else if look_through_trunc && is_inst(lhs) && inst_op(lhs) == .TRUNC { r.pred = pred; r.mask = ap_all_ones(bw); r.c = c; }
        else return false, r;
    } else fatal("internal: unexpected predicate in decomposeBitTestICmp");
    if !allow_non_zero_c && !ap_is_zero(r.c) return false, r;
    if inverted r.pred = cmp_inverse(r.pred);
    okt, x := pm_cast(lhs, .TRUNC);
    if look_through_trunc && okt {
        r.x = x;
        xb := type_bits(scalar_type(vtype(x)));
        r.mask = ap_zext(r.mask, xb);
        r.c = ap_zext(r.c, xb);
    } else r.x = lhs;
    return true, r;
}
decompose_bit_test :: (cond: Value_Id, look_through_trunc := true, allow_non_zero_c := false, decompose_and := false) -> (bool, Bit_Test) {
    r: Bit_Test;
    if is_inst(cond) && inst_op(cond) == .ICMP {
        if !is_int_type(scalar_type(vtype(op(cond, 0)))) return false, r;
        ok, res := decompose_bit_test_icmp(op(cond, 0), op(cond, 1), inst_pred(cond), look_through_trunc, allow_non_zero_c, decompose_and);
        return ok, res;
    }
    if is_bool_ty(vtype(cond)) {
        x: Value_Id = NONE; is_trunc := false;
        okt, tx := pm_cast(cond, .TRUNC);
        if okt { x = tx; is_trunc = true; }
        else {
            okn, n := pm_not(cond);
            if okn { okt2, tx2 := pm_cast(n, .TRUNC); if okt2 x = tx2; }
        }
        if x != NONE {
            r.x = x;
            bw := type_bits(scalar_type(vtype(x)));
            r.mask = ap_one(bw); r.c = ap_zero(bw);
            r.pred = ifx is_inst(cond) && inst_op(cond) == .TRUNC then cast(u8) ICMP_NE else ICMP_EQ;
            return true, r;
        }
    }
    return false, r;
}
simplify_select_with_bit_test :: (cond: Value_Id, tv: Value_Id, fv: Value_Id) -> Value_Id {
    ok, r := decompose_bit_test(cond);
    if ok return simplify_select_bit_test(tv, fv, r.x, r.mask, r.pred == ICMP_EQ);
    return NONE;
}
// simplifySelectWithEquivalence
simplify_select_with_equivalence :: (reps: [] Op_Rep, tv: Value_Id, fv: Value_Id, q: Simplify_Query, max_recurse: u32) -> Value_Id {
    sf := simplify_with_ops_replaced(fv, reps, sq_without_undef(q), false, null, max_recurse);
    if sf == NONE sf = fv;
    st := simplify_with_ops_replaced(tv, reps, q, true, null, max_recurse);
    if st == NONE st = tv;
    if sf == st return fv;
    return NONE;
}
// getUnderlyingObjectAggressive
get_underlying_object_aggressive :: (v: Value_Id) -> Value_Id {
    visited: [..] Value_Id; visited.allocator = temp;
    work: [..] Value_Id; work.allocator = temp;
    array_add(*work, v);
    object: Value_Id = NONE;
    first := true;
    first_object := get_underlying_object(v);
    while work.count {
        p := pop(*work);
        p = ifx first then first_object else get_underlying_object(p);
        first = false;
        seen := false;
        for visited if it == p { seen = true; break; }
        if seen continue;
        array_add(*visited, p);
        if visited.count == 8 return first_object;
        if is_select_inst(p) { array_add(*work, op(p, 1)); array_add(*work, op(p, 2)); continue; }
        if is_phi(p) { n := nops(p); for k: 0..n-1 array_add(*work, phi_value(p, k)); continue; }
        if object == NONE object = p;
        else if object != p return first_object;
    }
    return ifx object != NONE then object else first_object;
}
// isDereferenceablePointer(To, i8, DL) for a constant pointer without a context (llvm/lib/Analysis/Loads.cpp: the
// GEP / bitcast / addrspacecast / getPointerDereferenceableBytes cases; without a CxtI nothing else applies)
is_dereferenceable_constant_pointer :: (v: Value_Id, size: APInt, depth: u32 = 16) -> bool {
    if depth == 0 return false;
    o := opr_code(v);
    if o == .GEP {
        base := op(v, 0);
        ok, off := gep_accumulate_constant_offset(v, ap_zero(dl_index_bits(vtype(v))));
        if !ok || ap_is_negative(off) return false;
        return is_dereferenceable_constant_pointer(base, ap_add(off, ap_sext_or_trunc(size, off.bits)), depth - 1);
    }
    if o == .BITCAST && is_ptr_type(vtype(op(v, 0))) return is_dereferenceable_constant_pointer(op(v, 0), size, depth - 1);
    can_be_null, deref := pointer_dereferenceable_bytes(v);
    if ap_ule_u64(size, deref) && deref != 0 {
        q: Simplify_Query;
        if can_be_null && !is_known_non_zero(v, q) return false;
        if vkind(v) == .GLOBAL_VAR || vkind(v) == .ARGUMENT return true;   // alignment 1 is always satisfied
    }
    if o == .ADDRSPACECAST return is_dereferenceable_constant_pointer(op(v, 0), size, depth - 1);
    return false;
}
// canReplacePointersIfEqual (isPointerAlwaysReplaceable)
can_replace_pointers_if_equal :: (from: Value_Id, to: Value_Id) -> bool {
    if !is_ptr_or_ptr_vector(vtype(from)) return true;
    if vkind(to) == .C_NULL return true;
    if vkind(from) == .C_NULL && ir.types[scalar_type(vtype(from))].a == 0 return true;
    if is_const(to) && is_ptr_type(vtype(to)) && is_dereferenceable_constant_pointer(to, ap_one(dl_ptr_spec(cast(u32) ir.types[vtype(to)].a).bits)) return true;
    return get_underlying_object_aggressive(from) == get_underlying_object_aggressive(to);
}
// matchDecomposedSelectPattern(CmpI, TrueVal, FalseVal, LHS, RHS) (FMF none, CastOp null)
match_decomposed_select_pattern :: (cmp: Value_Id, tv: Value_Id, fv: Value_Id) -> (Select_Pattern, Value_Id, Value_Id) {
    s, l, r := match_decomposed_select_pattern_full(cmp, tv, fv, 0, false, 0);
    return s, l, r;
}
// getMinMaxLimit
min_max_limit :: (f: Select_Flavor, bits: u32) -> APInt {
    if f == .SMAX return ap_signed_max(bits);
    if f == .SMIN return ap_signed_min(bits);
    if f == .UMAX return ap_all_ones(bits);
    return ap_zero(bits);
}
// simplifySelectWithICmpCond
simplify_select_with_icmp_cond :: (cond: Value_Id, tv_in: Value_Id, fv_in: Value_Id, q: Simplify_Query, max_recurse: u32) -> Value_Id {
    tv := tv_in; fv := fv_in;
    ok, pred, _, cl, cr := pm_icmp(cond);
    if !ok return NONE;
    v := simplify_cmp_sel_of_max_min(cl, cr, pred, tv, fv); if v != NONE return v;
    if pred == ICMP_NE { pred = ICMP_EQ; t := tv; tv = fv; fv = t; }
    if is_int_type(scalar_type(vtype(tv))) {
        s, x, y := match_decomposed_select_pattern(cond, tv, fv);
        if spf_is_min_or_max(s.flavor) && pred == min_max_pred(s.flavor) {
            limit := min_max_limit(inverse_min_max_flavor(s.flavor), type_bits(scalar_type(vtype(x))));
            if pm_specific_int_ap(y, limit) return x;
        }
    }
    if pred == ICMP_EQ && pm_zero(cr) {
        oka, x, yv := pm_binop(cl, .AND);
        if oka {
            oky, y := pm_apint(yv);
            if oky { v = simplify_select_bit_test(tv, fv, x, y, true); if v != NONE return v; }
        }
        // isFsh: m_FShl(m_Value(X), m_Value(), m_Value(ShAmt)) or m_FShr(m_Value(), m_Value(X), m_Value(ShAmt))
        tid := call_iid(tv);
        if tid == IID_FSHL && fv == op(tv, 0) && cl == op(tv, 2) return op(tv, 0);
        if tid == IID_FSHR && fv == op(tv, 1) && cl == op(tv, 2) return op(tv, 1);
        fid := call_iid(fv);
        if (fid == IID_FSHL || fid == IID_FSHR) && op(fv, 0) == op(fv, 1) && tv == op(fv, 0) && cl == op(fv, 2) && pred == ICMP_EQ return fv;
        is_abs_of :: (v: Value_Id, x: Value_Id) -> bool { return call_iid(v) == IID_ABS && op(v, 0) == x; }
        is_neg_abs_of :: (v: Value_Id, x: Value_Id) -> bool { ok, n := pm_neg(v); return ok && is_abs_of(n, x); }
        if is_abs_of(tv, cl) && is_neg_abs_of(fv, cl) return fv;
        if is_neg_abs_of(tv, cl) && is_abs_of(fv, cl) return fv;
    }
    if pred == ICMP_EQ {
        if is_int_type(scalar_type(vtype(cl))) || can_replace_pointers_if_equal(cl, cr) {
            reps: [1] Op_Rep; reps[0] = .{cl, cr};
            v = simplify_select_with_equivalence(reps, tv, fv, q, max_recurse); if v != NONE return v;
        }
        if is_int_type(scalar_type(vtype(cl))) || can_replace_pointers_if_equal(cr, cl) {
            reps: [1] Op_Rep; reps[0] = .{cr, cl};
            v = simplify_select_with_equivalence(reps, tv, fv, q, max_recurse); if v != NONE return v;
        }
        oko, x, y := pm_binop(cl, .OR);
        if oko && pm_zero(cr) {
            reps: [2] Op_Rep; reps[0] = .{x, cr}; reps[1] = .{y, cr};
            v = simplify_select_with_equivalence(reps, tv, fv, q, max_recurse); if v != NONE return v;
        }
        oka, ax, ay := pm_binop(cl, .AND);
        if oka && pm_all_ones(cr) {
            reps: [2] Op_Rep; reps[0] = .{ax, cr}; reps[1] = .{ay, cr};
            v = simplify_select_with_equivalence(reps, tv, fv, q, max_recurse); if v != NONE return v;
        }
    }
    return NONE;
}
// CmpInst::isEquivalence(Invert)
cmp_is_equivalence :: (cmp: Value_Id, invert: bool) -> bool {
    p := inst_pred(cmp);
    if invert p = cmp_inverse(p);
    if p == ICMP_EQ return true;
    if p == FCMP_UEQ { if (inst_fmf(cmp) & FMF_NNAN) == 0 return false; return has_non_zero_fp_operands(cmp); }
    if p == FCMP_OEQ return has_non_zero_fp_operands(cmp);
    return false;
}
has_non_zero_fp_operands :: (cmp: Value_Id) -> bool {
    c := op(cmp, 0);
    if !is_const(c) { c = op(cmp, 1); if !is_const(c) return false; }
    return pm_fp_pred(c, (f: APFloat) -> bool { return !apf_is_zero(f) && !apf_is_denormal(f); });
}
// simplifySelectWithFCmp
simplify_select_with_fcmp :: (cond: Value_Id, t_in: Value_Id, f_in: Value_Id, fmf: u32, q: Simplify_Query, max_recurse: u32) -> Value_Id {
    t := t_in; f := f_in;
    ok, pred, cl, cr := pm_fcmp(cond);
    if !ok return NONE;
    is_equiv := cmp_is_equivalence(cond, false);
    if cmp_is_equivalence(cond, true) { tmp := t; t = f; f = tmp; pred = cmp_inverse(pred); is_equiv = true; }
    if is_equiv {
        reps: [1] Op_Rep; reps[0] = .{cl, cr};
        v := simplify_select_with_equivalence(reps, t, f, q, max_recurse); if v != NONE return v;
        reps[0] = .{cr, cl};
        v = simplify_select_with_equivalence(reps, t, f, q, max_recurse); if v != NONE return v;
    }
    if cl == f && cr == t { tmp := cl; cl = cr; cr = tmp; }
    if cl != t || cr != f return NONE;
    if (fmf & FMF_NSZ) != 0 {
        if pred == FCMP_OEQ return f;
        if pred == FCMP_UNE return t;
    }
    return NONE;
}
// isSelectWithIdenticalPHI
phi_incoming_for_block :: (p: Value_Id, b: Value_Id) -> Value_Id {
    idx := phi_block_index(p, b);
    if idx < 0 return NONE;
    return phi_value(p, cast(u32) idx);
}
is_select_with_identical_phi :: (pn: Value_Id, ipn: Value_Id) -> bool {
    if inst_block(pn) != inst_block(ipn) return false;
    if nops(pn) != 2 return false;
    diff := 0; diff_bb: Value_Id = NONE;
    for i: 0..1 {
        pb := phi_block(pn, cast(u32) i);
        if phi_value(pn, cast(u32) i) != phi_incoming_for_block(ipn, pb) { diff += 1; diff_bb = pb; }
    }
    if diff != 1 return false;
    si := phi_incoming_for_block(pn, diff_bb);
    isi := phi_incoming_for_block(ipn, diff_bb);
    if !is_select_inst(si) || !is_select_inst(isi) return false;
    if op(si, 0) != op(isi, 0) return false;
    other: Value_Id; iother: Value_Id;
    if op(si, 1) == op(isi, 1) { other = op(si, 2); iother = op(isi, 2); }
    else if op(si, 2) == op(isi, 2) { other = op(si, 1); iother = op(isi, 1); }
    else return false;
    if !is_select_inst(other) || iother != ipn return false;
    if !(op(other, 1) == ipn && op(other, 2) == pn) && !(op(other, 1) == pn && op(other, 2) == ipn) return false;
    return true;
}
// m_c_LogicalAnd / m_c_LogicalOr with both operands specific
is_c_logical_of :: (v: Value_Id, is_and: bool, a: Value_Id, b: Value_Id) -> bool {
    ok: bool; l, r: Value_Id;
    if is_and { ok, l, r = pm_logical_and(v); } else { ok, l, r = pm_logical_or(v); }
    return ok && ((l == a && r == b) || (l == b && r == a));
}
// m_c_LogicalOr(m_Specific(a), m_Value())
c_logical_with :: (v: Value_Id, is_and: bool, a: Value_Id) -> bool {
    ok: bool; l, r: Value_Id;
    if is_and { ok, l, r = pm_logical_and(v); } else { ok, l, r = pm_logical_or(v); }
    return ok && (l == a || r == a);
}
simplify_select_inst :: (cond: Value_Id, tv: Value_Id, fv: Value_Id, fmf: u32, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    if is_const(cond) {
        if is_const(tv) && is_const(fv) {
            c := cf_select(cond, tv, fv);
            if c != NONE return c;
        }
        if pm_poison(cond) return const_poison(vtype(tv));
        if sq_is_undef_value(q, cond) return ifx is_const(fv) then fv else tv;
        if pm_one(cond) return tv;
        if pm_zero(cond) return fv;
    }
    ct := vtype(cond);
    if ct == vtype(tv) {
        if pm_one(tv) && pm_zero_int(fv) return cond;
        if is_c_logical_of(cond, true, tv, fv) return fv;
        if is_c_logical_of(cond, false, tv, fv) return tv;
        if c_logical_with(cond, false, fv) && pm_zero_int(tv) return get_false(ct);
        if pm_zero_int(fv) {
            okn, nc := pm_not(cond);
            if okn && c_logical_with(nc, false, tv) return get_false(ct);
            okn2, nt := pm_not(tv);
            if okn2 && c_logical_with(nt, false, cond) return get_false(ct);
            if c_logical_with(cond, false, tv) return tv;
            if c_logical_with(tv, false, cond) return cond;
            // m_c_LogicalOr(m_Value(X), m_Not(m_Value(Y))) && m_c_LogicalOr(m_Specific(X), m_Specific(Y))
            match_or_not :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
                ok, l, r := pm_logical_or(v);
                if !ok return false, NONE, NONE;
                okn, y := pm_not(r);
                if okn return true, l, y;
                okn, y = pm_not(l);
                if okn return true, r, y;
                return false, NONE, NONE;
            }
            ok1, x, y := match_or_not(cond);
            if ok1 && is_c_logical_of(tv, false, x, y) return x;
            ok2, x2, y2 := match_or_not(tv);
            if ok2 && is_c_logical_of(cond, false, x2, y2) return x2;
        }
        if pm_one(tv) {
            okn, nc := pm_not(cond);
            if okn && c_logical_with(nc, true, fv) return get_true(ct);
            okn2, nf := pm_not(fv);
            if okn2 && c_logical_with(nf, true, cond) return get_true(ct);
            if c_logical_with(cond, true, fv) return fv;
            if c_logical_with(fv, true, cond) return cond;
        }
    }
    if tv == fv return tv;
    if cond == tv {
        if pm_zero_int(fv) return cond;
        if pm_one(fv) return get_true(ct);
    }
    if cond == fv {
        if pm_one(tv) return cond;
        if pm_zero_int(tv) return get_false(ct);
    }
    if pm_poison(tv) || (sq_is_undef_value(q, tv) && implies_poison(fv, cond)) return fv;
    if pm_poison(fv) || (sq_is_undef_value(q, fv) && implies_poison(tv, cond)) return tv;
    if type_kind(vtype(tv)) == .VECTOR && is_const(tv) && is_const(fv) {
        n := type_count(vtype(tv));
        nc: [..] Value_Id; nc.allocator = temp;
        for i: 0..cast(s64) n - 1 {
            te := cf_elt(tv, cast(u64) i); fe := cf_elt(fv, cast(u64) i);
            if te == NONE || fe == NONE break;
            if te == fe array_add(*nc, te);
            else if pm_poison(te) || (sq_is_undef_value(q, te) && is_guaranteed_not_to_be_poison(fe)) array_add(*nc, fe);
            else if pm_poison(fe) || (sq_is_undef_value(q, fe) && is_guaranteed_not_to_be_poison(te)) array_add(*nc, te);
            else break;
        }
        if nc.count == cast(s64) n return cf_vector(vtype(tv), nc);
    }
    v := simplify_select_with_icmp_cond(cond, tv, fv, q, max_recurse); if v != NONE return v;
    v = simplify_select_with_bit_test(cond, tv, fv); if v != NONE return v;
    v = simplify_select_with_fcmp(cond, tv, fv, fmf, q, max_recurse); if v != NONE return v;
    imp := is_implied_by_dom_condition(cond, q.cxt);
    if imp >= 0 return ifx imp == 1 then tv else fv;
    if is_phi(tv) && is_phi(fv) {
        if is_select_with_identical_phi(tv, fv) return fv;
        if is_select_with_identical_phi(fv, tv) return tv;
    }
    return NONE;
}

// ---------------------------------------------------------------- gep / aggregates / vectors / phi / casts

simplify_gep_inst :: (src_ty: Type_Id, ptr: Value_Id, idxs: [] Value_Id, nw: u32, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    as := cast(u32) ir.types[scalar_type(vtype(ptr))].a;
    if idxs.count == 0 return ptr;
    last_type := gep_indexed_type_n(src_ty, idxs);
    gep_ty := vtype(ptr);
    if !is_vector_type(gep_ty) {
        for idxs if is_vector_type(vtype(it)) { gep_ty = vector_with_elt(vtype(it), gep_ty); break; }
    }
    all_zero := true;
    for idxs if !pm_zero(it) { all_zero = false; break; }
    if vtype(ptr) == gep_ty && all_zero return ptr;
    any_poison := false;
    for idxs if pm_poison(it) any_poison = true;
    if pm_poison(ptr) || any_poison return const_poison(gep_ty);
    if sq_is_undef_value(q, ptr) return const_undef(gep_ty);
    scalable := type_is_scalable(src_ty);
    for idxs if type_kind(vtype(it)) == .SVECTOR scalable = true;
    if idxs.count == 1 {
        ty := src_ty;
        if !scalable && type_is_sized(ty) {
            alloc := dl_type_alloc_size(ty);
            if alloc == 0 && vtype(ptr) == gep_ty return ptr;
            if type_bits(scalar_type(vtype(idxs[0]))) >= dl_index_bits(vtype(ptr)) {
                can_simplify :: (p: Value_Id, gep_ty: Type_Id, ptr: Value_Id) -> bool {
                    return vtype(p) == gep_ty && get_underlying_object(p) == get_underlying_object(ptr);
                }
                sub_of_ptrs :: (v: Value_Id, ptr: Value_Id) -> (bool, Value_Id) {
                    ok, a, b := pm_binop(v, .SUB);
                    if !ok return false, NONE;
                    oka, p := pm_ptrtoint_or_addr(a);
                    okb, pb := pm_ptrtoint_or_addr(b);
                    if oka && okb && pb == ptr return true, p;
                    return false, NONE;
                }
                i0 := idxs[0];
                ok1, p1 := sub_of_ptrs(i0, ptr);
                if alloc == 1 && ok1 && can_simplify(p1, gep_ty, ptr) return p1;
                oka, sa, sc := pm_binop(i0, .ASHR);
                if oka {
                    ok2, p2 := sub_of_ptrs(sa, ptr);
                    okc, c := pm_constant_int_u64(sc);
                    if ok2 && okc && c < 64 && alloc == (cast(u64) 1) << c && can_simplify(p2, gep_ty, ptr) return p2;
                }
                okd, da, dc := pm_binop(i0, .SDIV);
                if okd {
                    ok3, p3 := sub_of_ptrs(da, ptr);
                    if ok3 && pm_specific_int(dc, alloc) && can_simplify(p3, gep_ty, ptr) return p3;
                }
            }
        }
    }
    if !scalable && last_type != NONE && dl_type_alloc_size(last_type) == 1 {
        all_but_last_zero := true;
        for i: 0..idxs.count-2 if !pm_zero(idxs[i]) { all_but_last_zero = false; break; }
        if all_but_last_zero {
            iw := dl_ptr_spec(cast(u32) ir.types[scalar_type(vtype(ptr))].a).idx_bits;
            lastx := idxs[idxs.count - 1];
            if dl_type_size_bits(vtype(lastx)) == iw {
                stripped, off := strip_and_accumulate_inbounds_constant_offsets(ptr, ap_zero(iw));
                okn, nx := pm_neg(lastx);
                if okn {
                    okp, px := pm_cast(nx, .PTRTOINT);
                    if okp && px == stripped && !ap_is_zero(off) return ce_cast(.INTTOPTR, cf_int(type_int(iw), off), gep_ty);
                }
                okx, xa, xb := pm_binop(lastx, .XOR);
                if okx && pm_all_ones(xb) {
                    okp, px := pm_cast(xa, .PTRTOINT);
                    if okp && px == stripped && !ap_is_one(off) return ce_cast(.INTTOPTR, cf_int(type_int(iw), ap_sub_u64(off, 1)), gep_ty);
                }
            }
        }
    }
    if !is_const(ptr) return NONE;
    for idxs if !is_const(it) return NONE;
    if type_is_scalable(src_ty) return cf_gep(src_ty, ptr, false, idxs);
    ce := ce_gep(src_ty, ptr, idxs, nw);
    return cfo_constant(ce);
}
simplify_insert_value_inst :: (agg: Value_Id, val: Value_Id, idxs: [] u32, q: Simplify_Query) -> Value_Id {
    if is_const(agg) && is_const(val) return cf_insert_value(agg, val, idxs);
    if pm_poison(val) || (sq_is_undef_value(q, val) && is_guaranteed_not_to_be_poison(agg)) return agg;
    if is_inst(val) && inst_op(val) == .EXTRACTVALUE {
        ev_agg := op(val, 0);
        ev_idx := inst_indices(val);
        same := ev_idx.count == idxs.count;
        if same for ev_idx if it != idxs[it_index] { same = false; break; }
        if vtype(ev_agg) == vtype(agg) && same {
            if pm_poison(agg) || (sq_is_undef_value(q, agg) && is_guaranteed_not_to_be_poison(ev_agg)) return ev_agg;
            if agg == ev_agg return agg;
        }
    }
    return NONE;
}
simplify_insert_element_inst :: (vec: Value_Id, val: Value_Id, idx: Value_Id, q: Simplify_Query) -> Value_Id {
    if is_const(vec) && is_const(val) && is_const(idx) return ce_insert_element(vec, val, idx);
    if is_scalar_const_int(idx) {
        if type_kind(vtype(vec)) == .VECTOR && ap_uge_u64(const_ap(idx), type_count(vtype(vec))) return const_poison(vtype(vec));
    }
    if sq_is_undef_value(q, idx) return const_poison(vtype(vec));
    if pm_poison(val) || (sq_is_undef_value(q, val) && is_guaranteed_not_to_be_poison(vec)) return vec;
    if is_const(vec) && is_const(val) && get_splat_value(vec) == val return vec;
    if is_inst(val) && inst_op(val) == .EXTRACTELEMENT && op(val, 0) == vec && op(val, 1) == idx return vec;
    return NONE;
}
simplify_extract_value_inst :: (agg: Value_Id, idxs: [] u32, q: Simplify_Query) -> Value_Id {
    if is_const(agg) return cf_extract_value(agg, idxs);
    visited: [..] Value_Id; visited.allocator = temp;
    ivi := agg;
    while is_inst(ivi) && inst_op(ivi) == .INSERTVALUE {
        for visited if it == ivi break;
        seen := false;
        for visited if it == ivi seen = true;
        if seen break;
        array_add(*visited, ivi);
        ins := inst_indices(ivi);
        common := min(ins.count, idxs.count);
        eq := true;
        for i: 0..common-1 if ins[i] != idxs[i] { eq = false; break; }
        if eq {
            if idxs.count == ins.count return op(ivi, 1);
            break;
        }
        ivi = op(ivi, 0);
    }
    if idxs.count == 1 && call_iid(agg) == IID_UMUL_WITH_OVERFLOW {
        v: Value_Id = NONE;
        if pm_one(op(agg, 1)) v = op(agg, 0);
        else if pm_one(op(agg, 0)) v = op(agg, 1);
        if v != NONE {
            if idxs[0] == 0 return v;
            return get_false(get_compare_ty(v));
        }
    }
    return NONE;
}
// findScalarElement
find_scalar_element :: (v: Value_Id, elt: u32) -> Value_Id {
    vt := vtype(v);
    if type_kind(vt) == .VECTOR && elt >= type_count(vt) return const_poison(type_elem(vt));
    if is_const(v) return cf_elt(v, elt);
    if is_inst(v) && inst_op(v) == .INSERTELEMENT {
        ok, ie := pm_constant_int_u64(op(v, 2));
        if !ok return NONE;
        if elt == ie return op(v, 1);
        if v == op(v, 0) return NONE;
        return find_scalar_element(op(v, 0), elt);
    }
    if is_inst(v) && inst_op(v) == .SHUFFLEVECTOR && type_kind(vt) == .VECTOR {
        lw := cast(u32) type_count(vtype(op(v, 0)));
        m := shuffle_mask(v)[elt];
        if m == POISON_MASK_ELEM return const_poison(type_elem(vt));
        if m < lw return find_scalar_element(op(v, 0), m);
        return find_scalar_element(op(v, 1), m - lw);
    }
    oka, val, c := pm_binop(v, .ADD);
    if oka && is_const(c) {
        e := cf_elt(c, elt);
        if e != NONE && is_null_value(e) return find_scalar_element(val, elt);
    }
    if type_kind(vt) == .SVECTOR {
        s := vt_get_splat_value(v);
        if s != NONE && elt < type_count(vt) return s;
    }
    return NONE;
}
simplify_extract_element_inst :: (vec: Value_Id, idx: Value_Id, q: Simplify_Query) -> Value_Id {
    vt := vtype(vec);
    if is_const(vec) {
        if is_const(idx) return ce_extract_element(vec, idx);
        if sq_is_undef_value(q, vec) return const_undef(type_elem(vt));
    }
    if sq_is_undef_value(q, idx) return const_poison(type_elem(vt));
    if is_scalar_const_int(idx) {
        ci := const_ap(idx);
        mn := type_count(vt);
        if type_kind(vt) == .VECTOR && ap_uge_u64(ci, mn) return const_poison(type_elem(vt));
        if ap_ult_u64(ci, mn) {
            s := vt_get_splat_value(vec);
            if s != NONE return s;
        }
        e := find_scalar_element(vec, cast,trunc(u32) ap_zext_value(ci));   // unsigned EltNo (truncating getZExtValue)
        if e != NONE return e;
    } else {
        if is_inst(vec) && inst_op(vec) == .INSERTELEMENT && op(vec, 2) == idx return op(vec, 1);
        s := vt_get_splat_value(vec);
        if s != NONE return s;
    }
    return NONE;
}
// simplifyPHINode
simplify_phi_node :: (pn: Value_Id, incoming: [] Value_Id, q: Simplify_Query) -> Value_Id {
    common: Value_Id = NONE;
    has_poison := false; has_undef := false;
    for inc: incoming {
        if inc == pn continue;
        if pm_poison(inc) { has_poison = true; continue; }
        if sq_is_undef_value(q, inc) { has_undef = true; continue; }
        if common != NONE && inc != common return NONE;
        common = inc;
    }
    if common == NONE return ifx has_undef then const_undef(vtype(pn)) else const_poison(vtype(pn));
    if has_poison || has_undef {
        if !value_dominates_phi(common, pn, q.dt) return NONE;
        if has_undef && !is_guaranteed_not_to_be_poison(common, q.ac, q.cxt, q.dt) return NONE;
        return common;
    }
    return common;
}
// simplifyCastInst
simplify_cast_inst :: (opc: Opcode, o: Value_Id, ty: Type_Id, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    return simplify_cast_inst_r(opc, o, ty, q, max_recurse);
}
simplify_cast_inst_r :: (opc: Opcode, o: Value_Id, ty: Type_Id, q: Simplify_Query, max_recurse: u32) -> Value_Id {
    if is_const(o) return cfo_cast_operand(opc, o, ty);
    if is_cast_inst(o) {
        src := op(o, 0);
        if vtype(src) == ty {
            if is_eliminable_cast_pair_dl(inst_op(o), opc, vtype(src), vtype(o), ty) == .BITCAST return src;
        }
    }
    if opc == .BITCAST && vtype(o) == ty return o;
    if opc == .PTRTOINT || opc == .PTRTOADDR {
        // m_PtrAdd(m_Value(Ptr), m_Sub(m_Value(X), m_PtrToIntOrAddr(m_Deferred(Ptr))))
        if opr_code(o) == .GEP && is_int_type(opr_gep_source_type(o)) && type_int_width(opr_gep_source_type(o)) == 8 && nops(o) >= 2 {
            ptr := op(o, 0);
            oks, x, sb := pm_binop(op(o, 1), .SUB);
            if oks {
                okp, pp := pm_ptrtoint_or_addr(sb);
                if okp && pp == ptr && vtype(x) == ty && ty == dl_index_type(vtype(ptr)) return x;
            }
        }
    }
    if opc == .ZEXT || opc == .SEXT {
        if is_inst(o) && inst_op(o) == .TRUNC {
            src := op(o, 0);
            no_wrap := (inst(o).flags & (ifx opc == .ZEXT then cast(u32) F_NUW else F_NSW)) != 0;
            if vtype(src) == ty && no_wrap return src;
        }
    }
    return NONE;
}
// foldIdentityShuffles
fold_identity_shuffles :: (dest_elt: s64, op0: Value_Id, op1: Value_Id, mask_val: u32, root_vec: Value_Id, max_recurse_in: u32) -> Value_Id {
    if max_recurse_in == 0 return NONE;
    max_recurse := max_recurse_in - 1;
    if mask_val == POISON_MASK_ELEM return NONE;
    n := cast(u32) type_count(vtype(op0));
    root_elt := mask_val;
    source := op0;
    if mask_val >= n { root_elt = mask_val - n; source = op1; }
    if is_inst(source) && inst_op(source) == .SHUFFLEVECTOR
        return fold_identity_shuffles(dest_elt, op(source, 0), op(source, 1), shuffle_mask(source)[root_elt], root_vec, max_recurse);
    rv := root_vec;
    if rv == NONE rv = source;
    if rv != source return NONE;
    if cast(s64) root_elt != dest_elt return NONE;
    return rv;
}
simplify_shuffle_vector_inst :: (op0_in: Value_Id, op1_in: Value_Id, mask: [] u32, ret_ty: Type_Id, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    op0 := op0_in; op1 := op1_in;
    all_poison := true;
    for mask if it != POISON_MASK_ELEM { all_poison = false; break; }
    if all_poison return const_poison(ret_ty);
    in_ty := vtype(op0);
    scalable := type_kind(in_ty) == .SVECTOR;
    n := cast(u32) type_count(in_ty);
    indices := NewArray(mask.count, u32,, allocator = temp);
    for mask indices[it_index] = it;
    if !scalable {
        s0 := false; s1 := false;
        for indices { if it == POISON_MASK_ELEM continue; if it < n s0 = true; else s1 = true; }
        if !s0 op0 = const_poison(in_ty);
        if !s1 op1 = const_poison(in_ty);
    }
    if is_const(op0) && is_const(op1) return ce_shuffle_vector(op0, op1, mask);
    if !scalable && is_const(op0) && !is_const(op1) {
        t := op0; op0 = op1; op1 = t;
        for * indices { if it.* == POISON_MASK_ELEM continue; it.* = ifx it.* < n then it.* + n else it.* - n; }
    }
    if !scalable && is_inst(op0) && inst_op(op0) == .INSERTELEMENT && is_const(op(op0, 1)) && is_const_int(op(op0, 2)) {
        c := op(op0, 1);
        ins := cast(u32) ap_zext_value(const_ap(op(op0, 2)));
        all := true;
        for indices if it != ins && it != POISON_MASK_ELEM { all = false; break; }
        if all {
            vc := NewArray(indices.count, Value_Id,, allocator = temp);
            for indices vc[it_index] = ifx it == POISON_MASK_ELEM then const_poison(vtype(c)) else c;
            return cf_vector(type_vector(cast(u64) indices.count, vtype(c), false), vc);
        }
    }
    if is_inst(op0) && inst_op(op0) == .SHUFFLEVECTOR && sq_is_undef_value(q, op1) && ret_ty == in_ty {
        m := shuffle_mask(op0);
        all_eq := true;
        for m if it != m[0] { all_eq = false; break; }
        if all_eq return op0;
    }
    if scalable return NONE;
    for indices if it == POISON_MASK_ELEM return NONE;
    root: Value_Id = NONE;
    for i: 0..indices.count-1 {
        root = fold_identity_shuffles(i, op0, op1, indices[i], root, max_recurse);
        if root == NONE || vtype(root) != ret_ty return NONE;
    }
    return root;
}
simplify_fneg_inst :: (o: Value_Id, fmf: u32, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    if is_const(o) return cfo_unary_op_operand(.FNEG, o);
    ok, x := pm_fneg(o);
    if ok return x;
    return NONE;
}

// ---------------------------------------------------------------- floating point binops

// fp::ExceptionBehavior and RoundingMode (llvm/ADT/FloatingPointMode.h)
EB_IGNORE :: 0; EB_MAY_TRAP :: 1; EB_STRICT :: 2;
is_default_fp_environment :: (eb: u8, rm: u8) -> bool { return eb == EB_IGNORE && rm == RM_NEAREST_TIES_TO_EVEN; }
can_rounding_mode_be :: (rm: u8, qrm: u8) -> bool { return rm == qrm || rm == RM_DYNAMIC; }
can_ignore_snan :: (eb: u8, fmf: u32) -> bool { return eb == EB_IGNORE || (fmf & FMF_NNAN) != 0; }

// propagateNaN
propagate_nan :: (c: Value_Id) -> Value_Id {
    ty := vtype(c);
    if type_kind(ty) == .VECTOR {
        n := type_count(ty);
        et := type_elem(ty);
        nc := NewArray(cast(s64) n, Value_Id,, allocator = temp);
        for i: 0..cast(s64) n - 1 {
            e := cf_elt(c, cast(u64) i);
            if e != NONE && pm_poison(e) nc[i] = e;
            else if e != NONE && const_is_nan(e) nc[i] = const_fp_words(et, fp_quiet(type_kind(et), const_fp_value(e)));
            else nc[i] = cf_nan(et);
        }
        return cf_vector(ty, nc);
    }
    if !const_is_nan(c) return cf_nan(ty);
    x := c;
    if type_kind(ty) == .SVECTOR x = get_splat_value(c);
    return const_fp_words(ty, fp_quiet(type_kind(scalar_type(ty)), const_fp_value(x)));
}
// simplifyFPOp
simplify_fp_op :: (ops: [] Value_Id, fmf: u32, q: Simplify_Query, eb: u8, rm: u8) -> Value_Id {
    for ops if pm_poison(it) return const_poison(vtype(ops[0]));
    for v: ops {
        is_nan := pm_nan(v); is_inf := pm_inf(v); is_undef := sq_is_undef_value(q, v);
        if (fmf & FMF_NNAN) != 0 && (is_nan || is_undef) return const_poison(vtype(v));
        if (fmf & FMF_NINF) != 0 && (is_inf || is_undef) return const_poison(vtype(v));
        if is_default_fp_environment(eb, rm) {
            if is_undef return cf_nan(vtype(v));
            if is_nan return propagate_nan(v);
        } else if eb != EB_STRICT {
            if is_nan return propagate_nan(v);
        }
    }
    return NONE;
}
fp_zero_of :: (t: Type_Id, neg := false) -> Value_Id { return const_fp_words(t, fp_zero(type_kind(scalar_type(t)), neg)); }
fp_from_double :: (t: Type_Id, d: float64) -> Value_Id {   // ConstantFP::get(Ty, double) for exactly representable values
    k := type_kind(scalar_type(t));
    dw: [1] u64;
    dw[0] = (cast(*u64) *d).*;
    w, exact := fp_convert(.DOUBLE, k, dw);
    return const_fp_words(t, w);
}
simplify_fadd_inst :: (op0_in: Value_Id, op1_in: Value_Id, fmf: u32, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT, eb: u8 = EB_IGNORE, rm: u8 = RM_NEAREST_TIES_TO_EVEN) -> Value_Id {
    op0 := op0_in; op1 := op1_in;
    if is_default_fp_environment(eb, rm) {
        c: Value_Id;
        c, op0, op1 = fold_or_commute_constant(.FADD, op0, op1, q);
        if c != NONE return c;
    }
    c := simplify_fp_op(.[op0, op1], fmf, q, eb, rm); if c != NONE return c;
    nsz := (fmf & FMF_NSZ) != 0;
    if can_ignore_snan(eb, fmf) && (!can_rounding_mode_be(rm, RM_TOWARD_NEGATIVE) || nsz)
        if pm_neg_zero_fp(op1) return op0;
    if can_ignore_snan(eb, fmf)
        if pm_pos_zero_fp(op1) && (nsz || cannot_be_negative_zero(op0, q)) return op0;
    if !is_default_fp_environment(eb, rm) return NONE;
    if (fmf & FMF_NNAN) != 0 {
        if pm_inf(op1) return op1;
        fsub_zero_of :: (v: Value_Id, x: Value_Id) -> bool { ok, a, b := pm_binop(v, .FSUB); return ok && pm_any_zero_fp(a) && b == x; }
        if fsub_zero_of(op0, op1) || fsub_zero_of(op1, op0) return fp_zero_of(vtype(op0));
        okn, n0 := pm_fneg(op0); okn2, n1 := pm_fneg(op1);
        if (okn && n0 == op1) || (okn2 && n1 == op0) return fp_zero_of(vtype(op0));
    }
    if nsz && (fmf & FMF_REASSOC) != 0 {
        ok, x, s := pm_binop(op0, .FSUB);
        if ok && s == op1 return x;
        ok, x, s = pm_binop(op1, .FSUB);
        if ok && s == op0 return x;
    }
    return NONE;
}
simplify_fsub_inst :: (op0_in: Value_Id, op1_in: Value_Id, fmf: u32, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT, eb: u8 = EB_IGNORE, rm: u8 = RM_NEAREST_TIES_TO_EVEN) -> Value_Id {
    op0 := op0_in; op1 := op1_in;
    if is_default_fp_environment(eb, rm) {
        c: Value_Id;
        c, op0, op1 = fold_or_commute_constant(.FSUB, op0, op1, q);
        if c != NONE return c;
    }
    c := simplify_fp_op(.[op0, op1], fmf, q, eb, rm); if c != NONE return c;
    nsz := (fmf & FMF_NSZ) != 0;
    if can_ignore_snan(eb, fmf) && (!can_rounding_mode_be(rm, RM_TOWARD_NEGATIVE) || nsz)
        if pm_pos_zero_fp(op1) return op0;
    if can_ignore_snan(eb, fmf)
        if pm_neg_zero_fp(op1) && (nsz || cannot_be_negative_zero(op0, q)) return op0;
    if can_ignore_snan(eb, fmf) {
        okn, x := pm_fneg(op1);
        if pm_neg_zero_fp(op0) && okn return x;
    }
    if can_ignore_snan(eb, fmf) && nsz && pm_any_zero_fp(op0) {
        ok, a, x := pm_binop(op1, .FSUB);
        if ok && pm_any_zero_fp(a) return x;
        okn, x2 := pm_fneg(op1);
        if okn return x2;
    }
    if !is_default_fp_environment(eb, rm) return NONE;
    if (fmf & FMF_NNAN) != 0 {
        if op0 == op1 return const_null_value(vtype(op0));
        if pm_inf(op0) return op0;
        if pm_inf(op1) return cfo_unary_op_operand(.FNEG, op1);
    }
    if nsz && (fmf & FMF_REASSOC) != 0 {
        ok, a, x := pm_binop(op1, .FSUB);
        if ok && a == op0 return x;
        okc, x2 := pm_c_binop_with(op0, .FADD, op1);
        if okc return x2;
    }
    return NONE;
}
simplify_fma_fmul :: (op0_in: Value_Id, op1_in: Value_Id, fmf: u32, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT, eb: u8 = EB_IGNORE, rm: u8 = RM_NEAREST_TIES_TO_EVEN) -> Value_Id {
    op0 := op0_in; op1 := op1_in;
    c := simplify_fp_op(.[op0, op1], fmf, q, eb, rm); if c != NONE return c;
    if !is_default_fp_environment(eb, rm) return NONE;
    if pm_fp_one(op0) || pm_any_zero_fp(op0) { t := op0; op0 = op1; op1 = t; }
    if pm_fp_one(op1) return op0;
    if pm_any_zero_fp(op1) {
        if (fmf & FMF_NNAN) != 0 && (fmf & FMF_NSZ) != 0 return fp_zero_of(vtype(op0));
        known := compute_known_fp_class_fmf(op0, fmf, FC_INF | FC_NAN, q);
        if kfpc_is_known_never(known, FC_INF | FC_NAN) {
            if (fmf & FMF_NSZ) != 0 return fp_zero_of(vtype(op0));
            if known.sign_bit == 0 return op1;
            if known.sign_bit == 1 return cfo_unary_op_operand(.FNEG, op1);
        }
    }
    if op0 == op1 && call_iid(op0) == IID_SQRT && (fmf & FMF_REASSOC) != 0 && (fmf & FMF_NNAN) != 0 && (fmf & FMF_NSZ) != 0 return op(op0, 0);
    return NONE;
}
simplify_fmul_inst :: (op0_in: Value_Id, op1_in: Value_Id, fmf: u32, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT, eb: u8 = EB_IGNORE, rm: u8 = RM_NEAREST_TIES_TO_EVEN) -> Value_Id {
    op0 := op0_in; op1 := op1_in;
    if is_default_fp_environment(eb, rm) {
        c: Value_Id;
        c, op0, op1 = fold_or_commute_constant(.FMUL, op0, op1, q);
        if c != NONE return c;
    }
    return simplify_fma_fmul(op0, op1, fmf, q, max_recurse, eb, rm);
}
simplify_fdiv_inst :: (op0_in: Value_Id, op1_in: Value_Id, fmf: u32, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT, eb: u8 = EB_IGNORE, rm: u8 = RM_NEAREST_TIES_TO_EVEN) -> Value_Id {
    op0 := op0_in; op1 := op1_in;
    if is_default_fp_environment(eb, rm) {
        c: Value_Id;
        c, op0, op1 = fold_or_commute_constant(.FDIV, op0, op1, q);
        if c != NONE return c;
    }
    c := simplify_fp_op(.[op0, op1], fmf, q, eb, rm); if c != NONE return c;
    if !is_default_fp_environment(eb, rm) return NONE;
    if pm_fp_one(op1) return op0;
    nnan := (fmf & FMF_NNAN) != 0;
    if nnan && (fmf & FMF_NSZ) != 0 && pm_any_zero_fp(op0) return fp_zero_of(vtype(op0));
    if nnan {
        if op0 == op1 return fp_from_double(vtype(op0), 1.0);
        if (fmf & FMF_REASSOC) != 0 {
            okm, x := pm_c_binop_with(op0, .FMUL, op1);
            if okm return x;
        }
        if pm_fneg_nsz_of(op0, op1) || pm_fneg_nsz_of(op1, op0) return fp_from_double(vtype(op0), -1.0);
        if (fmf & FMF_NINF) != 0 && pm_any_zero_fp(op1) return const_poison(vtype(op1));
    }
    return NONE;
}
// m_FNegNSZ(m_Specific(X)): fneg X, or fsub -0.0, X, or fsub nsz 0.0, X (FNeg_match) or fsub nsz +0.0, X
// m_FNegNSZ(m_Specific(X)) = m_FSub(m_AnyZeroFP(), m_Specific(X))
pm_fneg_nsz_of :: (v: Value_Id, x: Value_Id) -> bool {
    return is_inst(v) && inst_op(v) == .FSUB && op(v, 1) == x && pm_any_zero_fp(op(v, 0));
}
simplify_frem_inst :: (op0_in: Value_Id, op1_in: Value_Id, fmf: u32, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT, eb: u8 = EB_IGNORE, rm: u8 = RM_NEAREST_TIES_TO_EVEN) -> Value_Id {
    op0 := op0_in; op1 := op1_in;
    if is_default_fp_environment(eb, rm) {
        c: Value_Id;
        c, op0, op1 = fold_or_commute_constant(.FREM, op0, op1, q);
        if c != NONE return c;
    }
    c := simplify_fp_op(.[op0, op1], fmf, q, eb, rm); if c != NONE return c;
    if !is_default_fp_environment(eb, rm) return NONE;
    if (fmf & FMF_NNAN) != 0 {
        if pm_pos_zero_fp(op0) return fp_zero_of(vtype(op0));
        if pm_neg_zero_fp(op0) return fp_zero_of(vtype(op0), true);
    }
    return NONE;
}
simplify_unop :: (opc: Opcode, o: Value_Id, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    if opc == .FNEG return simplify_fneg_inst(o, 0, q, max_recurse);
    fatal("internal: unexpected unary opcode");
    return NONE;
}
simplify_fp_unop :: (opc: Opcode, o: Value_Id, fmf: u32, q: Simplify_Query, max_recurse: u32 = RECURSION_LIMIT) -> Value_Id {
    if opc == .FNEG return simplify_fneg_inst(o, fmf, q, max_recurse);
    return simplify_unop(opc, o, q, max_recurse);
}
// simplifyBinOp(Opcode, LHS, RHS, Q, MaxRecurse)
simplify_binop_r :: (opc: Opcode, lhs: Value_Id, rhs: Value_Id, q: Simplify_Query, max_recurse: u32) -> Value_Id {
    if opc == {
        case .ADD; return simplify_add_inst(lhs, rhs, false, false, q, max_recurse);
        case .SUB; return simplify_sub_inst(lhs, rhs, false, false, q, max_recurse);
        case .MUL; return simplify_mul_inst(lhs, rhs, false, false, q, max_recurse);
        case .SDIV; return simplify_sdiv_inst(lhs, rhs, false, q, max_recurse);
        case .UDIV; return simplify_udiv_inst(lhs, rhs, false, q, max_recurse);
        case .SREM; return simplify_srem_inst(lhs, rhs, q, max_recurse);
        case .UREM; return simplify_urem_inst(lhs, rhs, q, max_recurse);
        case .SHL; return simplify_shl_inst(lhs, rhs, false, false, q, max_recurse);
        case .LSHR; return simplify_lshr_inst(lhs, rhs, false, q, max_recurse);
        case .ASHR; return simplify_ashr_inst(lhs, rhs, false, q, max_recurse);
        case .AND; return simplify_and_inst(lhs, rhs, q, max_recurse);
        case .OR; return simplify_or_inst(lhs, rhs, q, max_recurse);
        case .XOR; return simplify_xor_inst(lhs, rhs, q, max_recurse);
        case .FADD; return simplify_fadd_inst(lhs, rhs, 0, q, max_recurse);
        case .FSUB; return simplify_fsub_inst(lhs, rhs, 0, q, max_recurse);
        case .FMUL; return simplify_fmul_inst(lhs, rhs, 0, q, max_recurse);
        case .FDIV; return simplify_fdiv_inst(lhs, rhs, 0, q, max_recurse);
        case .FREM; return simplify_frem_inst(lhs, rhs, 0, q, max_recurse);
    }
    fatal("internal: unexpected binary opcode");
    return NONE;
}
simplify_binop_fmf_r :: (opc: Opcode, lhs: Value_Id, rhs: Value_Id, fmf: u32, q: Simplify_Query, max_recurse: u32) -> Value_Id {
    if opc == {
        case .FADD; return simplify_fadd_inst(lhs, rhs, fmf, q, max_recurse);
        case .FSUB; return simplify_fsub_inst(lhs, rhs, fmf, q, max_recurse);
        case .FMUL; return simplify_fmul_inst(lhs, rhs, fmf, q, max_recurse);
        case .FDIV; return simplify_fdiv_inst(lhs, rhs, fmf, q, max_recurse);
    }
    return simplify_binop_r(opc, lhs, rhs, q, max_recurse);
}
simplify_binop :: (opc: Opcode, lhs: Value_Id, rhs: Value_Id, q: Simplify_Query) -> Value_Id { return simplify_binop_r(opc, lhs, rhs, q, RECURSION_LIMIT); }
simplify_binop_fmf :: (opc: Opcode, lhs: Value_Id, rhs: Value_Id, fmf: u32, q: Simplify_Query) -> Value_Id { return simplify_binop_fmf_r(opc, lhs, rhs, fmf, q, RECURSION_LIMIT); }
// simplifyCmpInst
simplify_cmp_inst_r :: (pred: u8, ss: bool, lhs: Value_Id, rhs: Value_Id, q: Simplify_Query, max_recurse: u32) -> Value_Id {
    if is_int_predicate(pred) return simplify_icmp_inst(pred, ss, lhs, rhs, q, max_recurse);
    return simplify_fcmp_inst(pred, lhs, rhs, 0, q, max_recurse);
}
simplify_cmp_inst :: (pred: u8, ss: bool, lhs: Value_Id, rhs: Value_Id, q: Simplify_Query) -> Value_Id { return simplify_cmp_inst_r(pred, ss, lhs, rhs, q, RECURSION_LIMIT); }

// ---------------------------------------------------------------- intrinsics and calls

is_idempotent_intrinsic :: (id: Intrinsic_Id) -> bool {
    return id == IID_FABS || id == IID_FLOOR || id == IID_CEIL || id == IID_TRUNC || id == IID_RINT || id == IID_NEARBYINT ||
           id == IID_ROUND || id == IID_ROUNDEVEN || id == IID_CANONICALIZE || id == IID_ARITHMETIC_FENCE;
}
removes_fp_fraction :: (id: Intrinsic_Id) -> bool {
    return id == IID_FLOOR || id == IID_CEIL || id == IID_TRUNC || id == IID_RINT || id == IID_NEARBYINT || id == IID_ROUND || id == IID_ROUNDEVEN;
}
// simplifyRelativeLoad
simplify_relative_load :: (ptr: Value_Id, offset: Value_Id) -> Value_Id {
    ok, sym, poff := is_constant_offset_from_global(ptr);
    if !ok return NONE;
    if !is_scalar_const_int(offset) || type_int_width(vtype(offset)) > 64 return NONE;
    oi := ap_sext_or_trunc(const_ap(offset), dl_index_bits(vtype(ptr)));
    if !ap_is_zero(ap_srem(oi, ap_from_u64(oi.bits, 4))) return NONE;
    loaded := cfo_load_from_const_ptr_off(ptr, ir.t_i32, oi);
    if loaded == NONE || vkind(loaded) != .C_EXPR return NONE;
    if cexpr(loaded).op == .TRUNC {
        loaded = op(loaded, 0);
        if vkind(loaded) != .C_EXPR return NONE;
    }
    if cexpr(loaded).op != .SUB return NONE;
    lhs := op(loaded, 0);
    if vkind(lhs) != .C_EXPR || cexpr(lhs).op != .PTRTOINT return NONE;
    lptr := op(lhs, 0);
    okr, rsym, roff := is_constant_offset_from_global(op(loaded, 1));
    if !okr || sym != rsym || poff.bits != roff.bits || !ap_eq(poff, roff) return NONE;
    return lptr;
}
// simplifyLdexp
simplify_ldexp :: (op0: Value_Id, op1: Value_Id, q: Simplify_Query, is_strict: bool) -> Value_Id {
    if pm_poison(op0) || pm_poison(op1) return op0;
    if sq_is_undef_value(q, op0) return cf_nan(vtype(op0));
    if !is_strict && sq_is_undef_value(q, op1) return op0;
    okc, c := pm_apfloat(op0);
    if okc && (apf_is_zero(c) || apf_is_inf(c)) return op0;
    if is_strict return NONE;
    if okc && apf_is_nan(c) { cc := c; return const_fp_words(vtype(op0), fp_quiet(cc.k, apf_words(*cc))); }
    if pm_zero_int(op1) return op0;
    return NONE;
}
// isSplatValue (VectorUtils.cpp)
is_splat_value :: (v: Value_Id, index: s32 = -1, depth_in: u32 = 0) -> bool {
    depth := depth_in;
    if is_vector_type(vtype(v)) {
        if pm_undef_value(v) return true;
        if is_const(v) return get_splat_value(v) != NONE;
    }
    if is_inst(v) && inst_op(v) == .SHUFFLEVECTOR {
        m := shuffle_mask(v);
        for m if it != m[0] return false;
        if index == -1 return true;
        return m[index] == cast(u32) index;
    }
    if depth == MAX_ANALYSIS_RECURSION_DEPTH return false;
    depth += 1;
    if opr_code(v) != .NONE_OP && is_binary_op(opr_code(v)) return is_splat_value(op(v, 0), index, depth) && is_splat_value(op(v, 1), index, depth);
    oks, x, y, z := pm_select(v);
    if oks return is_splat_value(x, index, depth) && is_splat_value(y, index, depth) && is_splat_value(z, index, depth);
    return false;
}
pm_specific_fp :: (v: Value_Id, d: float64) -> bool {
    ok, c := pm_apfloat(v);
    if !ok return false;
    want := fp_from_double(vtype(v), d);
    w := apf_from_const(want);
    return apf_compare(c, w) == .EQUAL && apf_is_negative(c) == apf_is_negative(w);
}
// simplifyUnaryIntrinsic
simplify_unary_intrinsic :: (id: Intrinsic_Id, op0: Value_Id, fmf: u32, q: Simplify_Query) -> Value_Id {
    if is_idempotent_intrinsic(id) && call_iid(op0) == id return op0;
    if removes_fp_fraction(id) {
        if removes_fp_fraction(call_iid(op0)) || opr_code(op0) == .UITOFP || opr_code(op0) == .SITOFP return op0;
    }
    reassoc := (fmf & FMF_REASSOC) != 0;
    if id == {
        case IID_FABS;
            k := compute_known_fp_class(op0, FC_ALL_FLAGS, q);
            if k.sign_bit == 0 return op0;
            if kfpc_cannot_be_ordered_less_than_zero(k) && kfpc_is_known_never_nan(k) && (fmf & FMF_NSZ) != 0 return op0;
        case IID_BSWAP; if call_iid(op0) == IID_BSWAP return op(op0, 0);
        case IID_BITREVERSE; if call_iid(op0) == IID_BITREVERSE return op(op0, 0);
        case IID_CTPOP;
            if is_known_to_be_a_power_of_two_ctx(op0, false, q.cxt, q.dt, q.ac) return const_int(vtype(op0), 1);
            bw := type_bits(scalar_type(vtype(op0)));
            if masked_value_is_zero(op0, ap_high_bits_set(bw, bw - 1), q) return op0;
        case IID_EXP; if reassoc && call_iid(op0) == IID_LOG return op(op0, 0);
        case IID_EXP2; if reassoc && call_iid(op0) == IID_LOG2 return op(op0, 0);
        case IID_EXP10; if reassoc && call_iid(op0) == IID_LOG10 return op(op0, 0);
        case IID_LOG; if reassoc && call_iid(op0) == IID_EXP return op(op0, 0);
        case IID_LOG2;
            if reassoc && (call_iid(op0) == IID_EXP2 || (call_iid(op0) == IID_POW && pm_specific_fp(op(op0, 0), 2.0))) return ifx call_iid(op0) == IID_EXP2 then op(op0, 0) else op(op0, 1);
        case IID_LOG10;
            if reassoc && (call_iid(op0) == IID_EXP10 || (call_iid(op0) == IID_POW && pm_specific_fp(op(op0, 0), 10.0))) return ifx call_iid(op0) == IID_EXP10 then op(op0, 0) else op(op0, 1);
        case IID_VECTOR_REVERSE;
            if call_iid(op0) == IID_VECTOR_REVERSE return op(op0, 0);
            if is_splat_value(op0) return op0;
        case IID_STRUCTURED_GEP; return op0;
    }
    return NONE;
}
// foldMinMaxSharedOp
fold_min_max_shared_op :: (id: Intrinsic_Id, op0: Value_Id, op1: Value_Id) -> Value_Id {
    id0 := call_iid(op0);
    if !is_min_max_intrinsic(id0) return NONE;
    x := op(op0, 0); y := op(op0, 1);
    if op1 == x || op1 == y || (is_min_max_intrinsic(call_iid(op1)) && is_c_op_of_call(op1, x, y)) {
        if id0 == id return op0;
        if id0 == inverse_min_max_intrinsic(id) return op1;
    }
    return NONE;
}
is_minimum_maximum_intrinsic :: (id: Intrinsic_Id) -> bool {
    return id == IID_MAXNUM || id == IID_MINNUM || id == IID_MAXIMUM || id == IID_MINIMUM || id == IID_MAXIMUMNUM || id == IID_MINIMUMNUM;
}
// foldMinimumMaximumSharedOp
fold_minimum_maximum_shared_op :: (id: Intrinsic_Id, op0: Value_Id, op1: Value_Id) -> Value_Id {
    if call_iid(op0) != id return NONE;
    x0 := op(op0, 0); y0 := op(op0, 1);
    if x0 == op1 || y0 == op1 return op0;
    id1 := call_iid(op1);
    if !is_minimum_maximum_intrinsic(id1) return NONE;
    x1 := op(op1, 0); y1 := op(op1, 1);
    if (x0 == x1 && y0 == y1) || (x0 == y1 && y0 == x1)
        if id1 == id || inverse_min_max_intrinsic(id1) == id return op0;
    return NONE;
}
Min_Max_Opt :: enum u8 { CANNOT_OPTIMIZE :: 0; USE_NEW_CONST_VAL :: 1; USE_OTHER_VAL :: 2; USE_EITHER :: 3; }
// OptimizeConstMinMax
optimize_const_min_max :: (c: Value_Id, id: Intrinsic_Id, fmf: u32) -> (Min_Max_Opt, Value_Id) {
    propagate_nan := id == IID_MINIMUM || id == IID_MAXIMUM;
    propagate_snan := id == IID_MINNUM || id == IID_MAXNUM;
    is_min := id == IID_MINIMUM || id == IID_MINNUM || id == IID_MINIMUMNUM;
    if pm_undef_value(c) return .USE_EITHER, c;
    if vkind(c) != .C_FP || is_vector_type(vtype(c)) return .CANNOT_OPTIMIZE, NONE;
    f := apf_from_const(c);
    if apf_is_nan(f) {
        if propagate_nan || (propagate_snan && apf_is_signaling(f)) {
            g := f;
            return .USE_NEW_CONST_VAL, const_fp_words(vtype(c), fp_quiet(g.k, apf_words(*g)));
        }
        return .USE_OTHER_VAL, NONE;
    }
    if apf_is_inf(f) || ((fmf & FMF_NINF) != 0 && apf_is_largest(f)) {
        nnan := (fmf & FMF_NNAN) != 0;
        if apf_is_negative(f) == is_min && (!propagate_nan || nnan) return .USE_NEW_CONST_VAL, c;
        if apf_is_negative(f) != is_min && (propagate_nan || nnan) return .USE_OTHER_VAL, NONE;
    }
    return .CANNOT_OPTIMIZE, NONE;
}
// APFloat::isLargest: the largest finite magnitude
apf_is_largest :: (f: APFloat) -> bool {
    if !apf_is_finite_non_zero(f) return false;
    g := f;
    big := fp_largest(g.k, apf_is_negative(g));
    for apf_words(*g) if it != big[it_index] return false;
    return true;
}
// MinMaxIntrinsic::getSaturationPoint
min_max_saturation_point :: (id: Intrinsic_Id, bits: u32) -> APInt {
    if id == IID_UMIN return ap_zero(bits);
    if id == IID_UMAX return ap_all_ones(bits);
    if id == IID_SMIN return ap_signed_min(bits);
    return ap_signed_max(bits);
}
// simplifyBinaryIntrinsic
simplify_binary_intrinsic :: (id: Intrinsic_Id, ret_ty: Type_Id, op0_in: Value_Id, op1_in: Value_Id, fmf: u32, q: Simplify_Query) -> Value_Id {
    op0 := op0_in; op1 := op1_in;
    bw := type_bits(scalar_type(ret_ty));
    if id == {
        case IID_GET_ACTIVE_LANE_MASK;
            if pm_zero(op1) return get_false(ret_ty);
            if q.cxt == NONE return NONE;
            f := inst_fn(q.cxt);
            a := fn_get_fn_attr(f, .VScaleRange);
            if type_kind(ret_ty) == .SVECTOR && a {
                vmax := a.ival & 0xFFFF_FFFF;
                if vmax == 0 return NONE;
                max_elems := type_count(ret_ty) * vmax;
                okc, c := pm_apint(op1);
                if pm_zero(op0) && okc && ap_uge_u64(c, max_elems) return cf_all_ones(ret_ty);
            }
        case IID_ABS; if call_iid(op0) == IID_ABS return op0;
        case IID_CTTZ;
            oks, s0, x := pm_binop(op0, .SHL);
            if oks && pm_one(s0) return x;
        case IID_CTLZ;
            okl, l0, x := pm_binop(op0, .LSHR);
            if okl && pm_negative(l0) return x;
            oka, a0, _ := pm_binop(op0, .ASHR);
            if oka && pm_negative(a0) return const_null_value(ret_ty);
        case IID_PDEP; #through;
        case IID_PEXT;
            if pm_zero(op0) return const_null_value(ret_ty);
            if pm_zero(op1) return const_null_value(ret_ty);
            if pm_all_ones(op1) return op0;
        case IID_PTRMASK;
            if sq_is_undef_value(q, op0) || pm_zero(op0) return const_null_value(vtype(op0));
            okp, p := pm_ptrtoint_or_addr(op1);
            if okp && p == op0 return op0;
            if pm_all_ones(op1) || sq_is_undef_value(q, op1) return op0;
            if pm_imm_constant(op1) {
                pk := known_bits(op0, q);
                irr := ap_zext_or_trunc(pk.zero, type_bits(scalar_type(vtype(op1))));
                c := cfo_binary_op_operands(.OR, op1, cf_int(vtype(op1), irr));
                if c != NONE && cf_is_all_ones(c) return op0;
            }
        case IID_SMAX; #through; case IID_SMIN; #through; case IID_UMAX; #through; case IID_UMIN;
            if op0 == op1 return op0;
            if pm_imm_constant(op0) { t := op0; op0 = op1; op1 = t; }
            if sq_is_undef_value(q, op1) return cf_int(ret_ty, min_max_saturation_point(id, bw));
            okc, c := pm_apint_ap(op1);
            if okc {
                if ap_eq(c, min_max_saturation_point(id, bw)) return cf_int(ret_ty, c);
                if ap_eq(c, min_max_saturation_point(inverse_min_max_intrinsic(id), bw)) return op0;
                if call_iid(op0) == id {
                    m00 := op(op0, 0); m01 := op(op0, 1);
                    oki, inner := pm_apint(m00);
                    if !oki { oki, inner = pm_apint(m01); }
                    if oki && icmp_compare(inner, c, cmp_non_strict(min_max_predicate(id))) return op0;
                }
            }
            v := fold_min_max_shared_op(id, op0, op1); if v != NONE return v;
            v = fold_min_max_shared_op(id, op1, op0); if v != NONE return v;
            pred := cmp_non_strict(min_max_predicate(id));
            if is_icmp_true(pred, op0, op1, sq_without_undef(q), RECURSION_LIMIT) return op0;
            if is_icmp_true(pred, op1, op0, sq_without_undef(q), RECURSION_LIMIT) return op1;
        case IID_SCMP; #through;
        case IID_UCMP;
            if is_icmp_true(ICMP_EQ, op0, op1, q, RECURSION_LIMIT) return const_null_value(ret_ty);
            gt := ifx id == IID_SCMP then cast(u8) ICMP_SGT else ICMP_UGT;
            if is_icmp_true(gt, op0, op1, q, RECURSION_LIMIT) return const_int(ret_ty, 1);
            lt := ifx id == IID_SCMP then cast(u8) ICMP_SLT else ICMP_ULT;
            if is_icmp_true(lt, op0, op1, q, RECURSION_LIMIT) return const_int(ret_ty, 0xFFFF_FFFF_FFFF_FFFF);
        case IID_USUB_WITH_OVERFLOW; #through;
        case IID_SSUB_WITH_OVERFLOW;
            if op0 == op1 || sq_is_undef_value(q, op0) || sq_is_undef_value(q, op1) return const_null_value(ret_ty);
        case IID_UADD_WITH_OVERFLOW; #through;
        case IID_SADD_WITH_OVERFLOW;
            if sq_is_undef_value(q, op0) || sq_is_undef_value(q, op1)
                return const_aggregate(.C_STRUCT, ret_ty, .[cf_all_ones(type_sub(ret_ty, 0)), const_null_value(type_sub(ret_ty, 1))]);
        case IID_UMUL_WITH_OVERFLOW; #through;
        case IID_SMUL_WITH_OVERFLOW;
            if pm_zero(op0) || pm_zero(op1) return const_null_value(ret_ty);
            if sq_is_undef_value(q, op0) || sq_is_undef_value(q, op1) return const_null_value(ret_ty);
        case IID_UADD_SAT;
            if pm_all_ones(op0) || pm_all_ones(op1) return cf_all_ones(ret_ty);
            #through;
        case IID_SADD_SAT;
            if sq_is_undef_value(q, op0) || sq_is_undef_value(q, op1) return cf_all_ones(ret_ty);
            if pm_zero(op1) return op0;
            if pm_zero(op0) return op1;
        case IID_USUB_SAT;
            if pm_zero(op0) || pm_all_ones(op1) return const_null_value(ret_ty);
            #through;
        case IID_SSUB_SAT;
            if op0 == op1 || sq_is_undef_value(q, op0) || sq_is_undef_value(q, op1) return const_null_value(ret_ty);
            if pm_zero(op1) return op0;
        case IID_LOAD_RELATIVE;
            if is_const(op0) && is_const(op1) return simplify_relative_load(op0, op1);
        case IID_POWI;
            if is_const_int(op1) {
                if ap_is_zero(const_ap(op1)) return fp_from_double(vtype(op0), 1.0);
                if ap_is_one(const_ap(op1)) return op0;
            }
        case IID_LDEXP; return simplify_ldexp(op0, op1, q, false);
        case IID_COPYSIGN;
            if op0 == op1 return op0;
            okn, n0 := pm_fneg(op0); okn2, n1 := pm_fneg(op1);
            if (okn && n0 == op1) || (okn2 && n1 == op0) return op1;
        case IID_IS_FPCLASS;
            mask := const_int_zext(op1);
            if (mask & FC_ALL_FLAGS) == FC_ALL_FLAGS return const_int(ret_ty, 1);
            if (mask & FC_ALL_FLAGS) == 0 return const_int(ret_ty, 0);
            if sq_is_undef_value(q, op0) return const_undef(ret_ty);
        case IID_MAXNUM; #through; case IID_MINNUM; #through; case IID_MAXIMUM; #through; case IID_MINIMUM; #through;
        case IID_MAXIMUMNUM; #through; case IID_MINIMUMNUM;
            if op0 == op1 return op0;
            if is_const(op0) { t := op0; op0 = op1; op1 = t; }
            if is_const(op1) {
                c := op1;
                res := Min_Max_Opt.CANNOT_OPTIMIZE;
                new_const: Value_Id = NONE;
                if is_vector_type(vtype(c)) {
                    s := get_splat_value(c);
                    if s != NONE {
                        res, new_const = optimize_const_min_max(s, id, fmf);
                        if res == .USE_NEW_CONST_VAL new_const = cf_get_splat(vtype(c), new_const);
                    } else if type_kind(vtype(c)) == .VECTOR {
                        n := type_count(vtype(c));
                        nc := NewArray(cast(s64) n, Value_Id,, allocator = temp);
                        res = .USE_EITHER;
                        for i: 0..cast(s64) n - 1 {
                            e := cf_elt(c, cast(u64) i);
                            if e == NONE { res = .CANNOT_OPTIMIZE; break; }
                            er, nv := optimize_const_min_max(e, id, fmf);
                            new_const = nv;
                            if er == .CANNOT_OPTIMIZE || (er != res && res != .USE_EITHER && er != .USE_EITHER) { res = .CANNOT_OPTIMIZE; break; }
                            nc[i] = new_const;
                            if er != .USE_EITHER res = er;
                        }
                        if res == .USE_NEW_CONST_VAL new_const = cf_vector(vtype(c), nc);
                    }
                } else {
                    res, new_const = optimize_const_min_max(c, id, fmf);
                }
                if res == .USE_OTHER_VAL || res == .USE_EITHER return op0;
                else if res == .USE_NEW_CONST_VAL return new_const;
            }
            v := fold_minimum_maximum_shared_op(id, op0, op1); if v != NONE return v;
            v = fold_minimum_maximum_shared_op(id, op1, op0); if v != NONE return v;
        case IID_VECTOR_EXTRACT;
            idx := const_int_zext(op1);
            if call_iid(op0) == IID_VECTOR_INSERT && pm_zero(op(op0, 2)) && idx == 0 && vtype(op(op0, 1)) == ret_ty return op(op0, 1);
    }
    return NONE;
}
interleave_factor :: (id: Intrinsic_Id) -> u32 {
    if id == {
        case IID_VECTOR_INTERLEAVE2; return 2; case IID_VECTOR_INTERLEAVE3; return 3; case IID_VECTOR_INTERLEAVE4; return 4;
        case IID_VECTOR_INTERLEAVE5; return 5; case IID_VECTOR_INTERLEAVE6; return 6; case IID_VECTOR_INTERLEAVE7; return 7;
        case IID_VECTOR_INTERLEAVE8; return 8;
    }
    return 0;
}
deinterleave_id :: (factor: u32) -> Intrinsic_Id {
    if factor == {
        case 2; return IID_VECTOR_DEINTERLEAVE2; case 3; return IID_VECTOR_DEINTERLEAVE3; case 4; return IID_VECTOR_DEINTERLEAVE4;
        case 5; return IID_VECTOR_DEINTERLEAVE5; case 6; return IID_VECTOR_DEINTERLEAVE6; case 7; return IID_VECTOR_DEINTERLEAVE7;
    }
    return IID_VECTOR_DEINTERLEAVE8;
}
// simplifyIdentityInterleave
simplify_identity_interleave :: (id: Intrinsic_Id, args: [] Value_Id) -> Value_Id {
    factor := interleave_factor(id);
    if factor == 0 || factor != args.count return NONE;
    did := deinterleave_id(factor);
    di: Value_Id = NONE;
    for k: 0..cast(s64) factor - 1 {
        ev := args[k];
        if !is_inst(ev) || inst_op(ev) != .EXTRACTVALUE || inst(ev).nidx != 1 || ir.u32_pool[inst(ev).idx] != cast(u32) k return NONE;
        cur := op(ev, 0);
        if call_iid(cur) != did return NONE;
        if di == NONE di = cur;
        else if di != cur return NONE;
    }
    return op(di, 0);
}
// llvm::simplifyIntrinsic(IID, ReturnType, Args, FMF, Q, CxtF, ExBehavior, Rounding)
simplify_intrinsic :: (id: Intrinsic_Id, ret_ty: Type_Id, args: [] Value_Id, fmf: u32, q: Simplify_Query, cxt_f: Value_Id, eb: u8, rm: u8) -> Value_Id {
    n := args.count;
    if id != NOT_INTRINSIC && intrinsic_propagates_poison(id) {
        for args if pm_poison(it) return const_poison(ret_ty);
    }
    if n == 0 {
        if id == IID_VSCALE {
            if cxt_f == NONE return NONE;
            r := get_vscale_range(cxt_f, 64);
            ok, c := cr_single_element(r);
            if ok return const_int(ret_ty, ap_zext_value(c));
        }
        return NONE;
    }
    v := simplify_identity_interleave(id, args); if v != NONE return v;
    if n == 1 return simplify_unary_intrinsic(id, args[0], fmf, q);
    if n == 2 return simplify_binary_intrinsic(id, ret_ty, args[0], args[1], fmf, q);
    if id == {
        case IID_MASKED_LOAD; #through;
        case IID_MASKED_GATHER;
            if pm_zero(args[1]) || pm_poison(args[1]) return args[2];
            return NONE;
        case IID_FSHL; #through;
        case IID_FSHR;
            op0 := args[0]; op1 := args[1]; sh := args[2];
            if sq_is_undef_value(q, op0) && sq_is_undef_value(q, op1) return const_undef(ret_ty);
            if sq_is_undef_value(q, sh) return args[ifx id == IID_FSHL then 0 else 1];
            okc, shc := pm_apint(sh);
            if okc {
                bwap := ap_from_u64(shc.bits, shc.bits);
                amt := ap_urem(shc, bwap);
                if ap_is_zero(amt) return args[ifx id == IID_FSHL then 0 else 1];
                okl, x, c1v := pm_binop(op0, .LSHR);
                oks, sx, c2v := pm_binop(op1, .SHL);
                if okl && oks && sx == x {
                    ok1, c1 := pm_apint(c1v); ok2, c2 := pm_apint(c2v);
                    if ok1 && ok2 && ap_eq(ap_add(c1, c2), bwap) && ap_eq(amt, ifx id == IID_FSHL then c1 else c2) return x;
                }
            }
            if pm_zero(op0) && pm_zero(op1) return const_null_value(ret_ty);
            if pm_all_ones(op0) && pm_all_ones(op1) return cf_all_ones(ret_ty);
            return NONE;
        case IID_EXPERIMENTAL_CONSTRAINED_FMA; return simplify_fp_op(args, 0, q, eb, rm);
        case IID_FMA; #through;
        case IID_FMULADD; return simplify_fp_op(args, 0, q, EB_IGNORE, RM_NEAREST_TIES_TO_EVEN);
        case IID_SMUL_FIX; #through;
        case IID_SMUL_FIX_SAT;
            op0 := args[0]; op1 := args[1]; op2 := args[2];
            if is_const(op0) { t := op0; op0 = op1; op1 = t; }
            if pm_zero(op1) return const_null_value(ret_ty);
            if sq_is_undef_value(q, op1) return const_null_value(ret_ty);
            scaled := ap_one_bit_set(type_bits(scalar_type(ret_ty)), cast(u32) const_int_zext(op2));
            if ap_is_non_negative(scaled) && pm_specific_int_ap(op1, scaled) return op0;
            return NONE;
        case IID_VECTOR_INSERT;
            vec := args[0]; sub := args[1]; idx := const_int_zext(args[2]);
            if call_iid(sub) == IID_VECTOR_EXTRACT && pm_zero(op(sub, 1)) {
                x := op(sub, 0);
                if (sq_is_undef_value(q, vec) || vec == x) && idx == 0 && vtype(x) == ret_ty return x;
            }
            return NONE;
        case IID_VECTOR_SPLICE_RIGHT;
            off := args[2];
            a0 := args[0];
            if call_iid(a0) == IID_VECTOR_SPLICE_LEFT && pm_poison(op(a0, 0)) && op(a0, 2) == off && pm_poison(args[1]) return op(a0, 1);
            return simplify_vector_splice_left(id, ret_ty, args, q, cxt_f);
        case IID_VECTOR_SPLICE_LEFT;
            return simplify_vector_splice_left(id, ret_ty, args, q, cxt_f);
        case IID_EXPERIMENTAL_CONSTRAINED_FADD; return simplify_fadd_inst(args[0], args[1], fmf, q, RECURSION_LIMIT, eb, rm);
        case IID_EXPERIMENTAL_CONSTRAINED_FSUB; return simplify_fsub_inst(args[0], args[1], fmf, q, RECURSION_LIMIT, eb, rm);
        case IID_EXPERIMENTAL_CONSTRAINED_FMUL; return simplify_fmul_inst(args[0], args[1], fmf, q, RECURSION_LIMIT, eb, rm);
        case IID_EXPERIMENTAL_CONSTRAINED_FDIV; return simplify_fdiv_inst(args[0], args[1], fmf, q, RECURSION_LIMIT, eb, rm);
        case IID_EXPERIMENTAL_CONSTRAINED_FREM; return simplify_frem_inst(args[0], args[1], fmf, q, RECURSION_LIMIT, eb, rm);
        case IID_EXPERIMENTAL_CONSTRAINED_LDEXP; return simplify_ldexp(args[0], args[1], q, true);
        case IID_EXPERIMENTAL_VP_REVERSE;
            vec := args[0]; evl := args[2];
            if call_iid(vec) == IID_EXPERIMENTAL_VP_REVERSE && op(vec, 2) == evl return op(vec, 0);
            if is_splat_value(vec) return vec;
            return NONE;
    }
    return NONE;
}
simplify_vector_splice_left :: (id: Intrinsic_Id, ret_ty: Type_Id, args: [] Value_Id, q: Simplify_Query, cxt_f: Value_Id) -> Value_Id {
    off := args[2];
    if sq_is_undef_value(q, off) return const_poison(ret_ty);
    bw := type_bits(scalar_type(vtype(off)));
    ne := cr_single(ap_from_u64(bw, type_count(ret_ty)));
    if type_kind(ret_ty) == .SVECTOR ne = cr_multiply(ne, ifx cxt_f != NONE then get_vscale_range(cxt_f, bw) else cr_full(bw));
    r := compute_constant_range_including_known_bits(off, false, q);
    if ap_ugt(cr_umin(r), cr_umax(ne)) return const_poison(ret_ty);
    ok, c := cr_single_element(r);
    if ok && ap_is_zero(c) return ifx id == IID_VECTOR_SPLICE_LEFT then args[0] else args[1];
    return NONE;
}
// ConstrainedFPIntrinsic::getExceptionBehavior / getRoundingMode (metadata string arguments)
constrained_md_string :: (c: Value_Id, from_end: u32) -> string {
    n := call_num_args(c);
    if n < from_end return "";
    a := op(c, n - from_end);
    if vkind(a) != .MD_VALUE return "";
    m := cast(Md_Id) ir.v_aux[a];
    if m == NONE || ir.mds[m].kind != .STRING return "";
    return ir.mds[m].str;
}
is_constrained_fp_intrinsic :: (id: Intrinsic_Id) -> bool {
    if id == NOT_INTRINSIC return false;
    return begins_with(intrinsic_name(id), "llvm.experimental.constrained.");
}
constrained_has_rounding :: (id: Intrinsic_Id) -> bool {
    // the intrinsics whose last-but-one argument is the rounding mode (all but the compares, fptoui/fptosi, fpext,
    // and the rounding operations with an implied mode)
    name := intrinsic_name(id);
    for string.["fcmp", "fcmps", "fptosi", "fptoui", "fpext", "ceil", "floor", "round", "roundeven", "trunc", "maxnum", "minnum", "maximum", "minimum", "lround", "llround"] {
        if name == tprint("llvm.experimental.constrained.%", it) return false;
    }
    return true;
}
constrained_eb_rm :: (c: Value_Id, id: Intrinsic_Id) -> (u8, u8) {
    eb: u8 = EB_IGNORE; rm: u8 = RM_NEAREST_TIES_TO_EVEN;
    es := constrained_md_string(c, 1);
    if es == "fpexcept.ignore" eb = EB_IGNORE;
    else if es == "fpexcept.maytrap" eb = EB_MAY_TRAP;
    else if es == "fpexcept.strict" eb = EB_STRICT;
    if constrained_has_rounding(id) {
        rs := constrained_md_string(c, 2);
        if rs == "round.dynamic" rm = RM_DYNAMIC;
        else if rs == "round.tonearest" rm = RM_NEAREST_TIES_TO_EVEN;
        else if rs == "round.tonearestaway" rm = RM_NEAREST_TIES_TO_AWAY;
        else if rs == "round.downward" rm = RM_TOWARD_NEGATIVE;
        else if rs == "round.upward" rm = RM_TOWARD_POSITIVE;
        else if rs == "round.towardzero" rm = RM_TOWARD_ZERO;
    }
    return eb, rm;
}
// static simplifyIntrinsic(CallBase *Call, ArrayRef<Value *> Args, Q)
simplify_intrinsic_call :: (call: Value_Id, args: [] Value_Id, q: Simplify_Query) -> Value_Id {
    f := call_called_function(call);
    id := fn_iid(f);
    ret_ty := func_ret(glob(f).value_type);
    if id == IID_EXPERIMENTAL_GC_RELOCATE {
        derived := gc_relocate_ptr(call, 2);
        base := gc_relocate_ptr(call, 1);
        if derived == NONE || base == NONE return NONE;
        if pm_undef_value(derived) || pm_undef_value(base) return const_undef(ret_ty);
        if type_kind(ret_ty) == .PTR && vkind(derived) == .C_NULL return const_null(ret_ty);
        return NONE;
    }
    eb: u8 = EB_IGNORE; rm: u8 = RM_NEAREST_TIES_TO_EVEN;
    if is_constrained_fp_intrinsic(id) { eb, rm = constrained_eb_rm(call, id); }
    fmf: u32 = 0;
    if is_fp_math_operator(call) fmf = inst_fmf(call);
    return simplify_intrinsic(id, ret_ty, args, fmf, q, inst_fn(call), eb, rm);
}
// tryConstantFoldCall
try_constant_fold_call :: (call: Value_Id, args: [] Value_Id, q: Simplify_Query) -> Value_Id {
    f := call_called_function(call);
    if f == NONE || !can_constant_fold_call_to(call, f) return NONE;
    // ConstantFoldLibCall1/2/3 return nullptr without a TLI; only intrinsics fold
    if q.no_tli_libcalls && fn_iid(f) == NOT_INTRINSIC return NONE;
    cargs: [..] Value_Id; cargs.allocator = temp;
    for args {
        if !is_const(it) {
            if vkind(it) == .MD_VALUE continue;
            return NONE;
        }
        array_add(*cargs, it);
    }
    return cfo_call(call, f, cargs, true);
}
// simplifyCall
simplify_call :: (call: Value_Id, callee: Value_Id, args: [] Value_Id, q: Simplify_Query) -> Value_Id {
    if ((inst(call).flags >> TAIL_SHIFT) & 3) == 2 return NONE;   // isMustTailCall
    if pm_undef_value(callee) || vkind(callee) == .C_NULL return const_poison(vtype(call));
    v := try_constant_fold_call(call, args, q); if v != NONE return v;
    if vkind(callee) == .FUNCTION && glob(callee).intrinsic {
        r := simplify_intrinsic_call(call, args, q);
        if r != NONE return r;
    }
    return NONE;
}
simplify_freeze_inst :: (op0: Value_Id, q: Simplify_Query) -> Value_Id {
    if is_guaranteed_not_to_be_undef_or_poison(op0, q.ac, q.cxt, q.dt) return op0;
    return NONE;
}
// simplifyLoadInst
simplify_load_inst :: (li: Value_Id, ptr_in: Value_Id, q: Simplify_Query) -> Value_Id {
    if (inst(li).flags & F_VOLATILE) != 0 return NONE;
    ptr := ptr_in;
    if is_const(ptr) return cfo_load_from_const_ptr(ptr, vtype(li));
    gv := get_underlying_object(ptr);
    if vkind(gv) != .GLOBAL_VAR || !glob(gv).is_const || !gv_has_definitive_initializer(gv) return NONE;
    c := cfo_load_from_uniform_value(gv_initializer(gv), vtype(li));
    if c != NONE return c;
    off := ap_zero(dl_index_bits(vtype(ptr)));
    ptr, off = strip_and_accumulate_constant_offsets(ptr, off, true, true);
    if ptr == gv {
        off = ap_sext_or_trunc(off, dl_index_bits(vtype(ptr)));
        return cfo_load_from_const_ptr_off(gv, vtype(li), off);
    }
    return NONE;
}

// ---------------------------------------------------------------- simplifyInstruction

// simplifyInstructionWithOperands(I, NewOps, SQ, MaxRecurse)
simplify_instruction_with_operands_r :: (i: Value_Id, new_ops: [] Value_Id, sq: Simplify_Query, max_recurse: u32) -> Value_Id {
    q := ifx sq.cxt != NONE then sq else sq_with_instruction(sq, i);
    r := inst(i);
    fmf := ifx is_fp_math_operator(i) then inst_fmf(i) else 0;
    if r.op == {
        case .FNEG; return simplify_fneg_inst(new_ops[0], fmf, q, max_recurse);
        case .FADD; return simplify_fadd_inst(new_ops[0], new_ops[1], fmf, q, max_recurse);
        case .ADD; return simplify_add_inst(new_ops[0], new_ops[1], iiq_nsw(q, i), iiq_nuw(q, i), q, max_recurse);
        case .FSUB; return simplify_fsub_inst(new_ops[0], new_ops[1], fmf, q, max_recurse);
        case .SUB; return simplify_sub_inst(new_ops[0], new_ops[1], iiq_nsw(q, i), iiq_nuw(q, i), q, max_recurse);
        case .FMUL; return simplify_fmul_inst(new_ops[0], new_ops[1], fmf, q, max_recurse);
        case .MUL; return simplify_mul_inst(new_ops[0], new_ops[1], iiq_nsw(q, i), iiq_nuw(q, i), q, max_recurse);
        case .SDIV; return simplify_sdiv_inst(new_ops[0], new_ops[1], iiq_exact(q, i), q, max_recurse);
        case .UDIV; return simplify_udiv_inst(new_ops[0], new_ops[1], iiq_exact(q, i), q, max_recurse);
        case .FDIV; return simplify_fdiv_inst(new_ops[0], new_ops[1], fmf, q, max_recurse);
        case .SREM; return simplify_srem_inst(new_ops[0], new_ops[1], q, max_recurse);
        case .UREM; return simplify_urem_inst(new_ops[0], new_ops[1], q, max_recurse);
        case .FREM; return simplify_frem_inst(new_ops[0], new_ops[1], fmf, q, max_recurse);
        case .SHL; return simplify_shl_inst(new_ops[0], new_ops[1], iiq_nsw(q, i), iiq_nuw(q, i), q, max_recurse);
        case .LSHR; return simplify_lshr_inst(new_ops[0], new_ops[1], iiq_exact(q, i), q, max_recurse);
        case .ASHR; return simplify_ashr_inst(new_ops[0], new_ops[1], iiq_exact(q, i), q, max_recurse);
        case .AND; return simplify_and_inst(new_ops[0], new_ops[1], q, max_recurse);
        case .OR; return simplify_or_inst(new_ops[0], new_ops[1], q, max_recurse);
        case .XOR; return simplify_xor_inst(new_ops[0], new_ops[1], q, max_recurse);
        case .ICMP; return simplify_icmp_inst(r.pred, (r.flags & F_EXACT) != 0, new_ops[0], new_ops[1], q, max_recurse);
        case .FCMP; return simplify_fcmp_inst(r.pred, new_ops[0], new_ops[1], fmf, q, max_recurse);
        case .SELECT; return simplify_select_inst(new_ops[0], new_ops[1], new_ops[2], fmf, q, max_recurse);
        case .GEP;
            rest: [] Value_Id; rest.data = new_ops.data + 1; rest.count = new_ops.count - 1;
            return simplify_gep_inst(r.ty2, new_ops[0], rest, gep_flags_of(r.flags), q, max_recurse);
        case .INSERTVALUE; return simplify_insert_value_inst(new_ops[0], new_ops[1], inst_indices(i), q);
        case .INSERTELEMENT; return simplify_insert_element_inst(new_ops[0], new_ops[1], new_ops[2], q);
        case .EXTRACTVALUE; return simplify_extract_value_inst(new_ops[0], inst_indices(i), q);
        case .EXTRACTELEMENT; return simplify_extract_element_inst(new_ops[0], new_ops[1], q);
        case .SHUFFLEVECTOR; return simplify_shuffle_vector_inst(new_ops[0], new_ops[1], shuffle_mask(i), vtype(i), q, max_recurse);
        case .PHI; return simplify_phi_node(i, new_ops, q);
        case .CALL;
            nb := call_num_bundle_operands(i);
            args: [] Value_Id; args.data = new_ops.data; args.count = new_ops.count - 1 - nb;
            return simplify_call(i, new_ops[new_ops.count - 1], args, q);
        case .FREEZE; return simplify_freeze_inst(new_ops[0], q);
        case .ALLOCA; return NONE;
        case .LOAD; return simplify_load_inst(i, new_ops[0], q);
    }
    if is_cast_op(r.op) return simplify_cast_inst_r(r.op, new_ops[0], vtype(i), q, max_recurse);
    for new_ops if !is_const(it) return NONE;
    return cfo_inst_operands(i, new_ops);
}
call_num_bundle_operands :: (i: Value_Id) -> s64 {
    r := inst(i);
    if r.nidx == 0 return 0;
    last := r.nidx - 1;
    return cast(s64)(ir.u32_pool[r.idx + last * 3 + 2] - ir.u32_pool[r.idx + 1]);
}
simplify_instruction_with_operands :: (i: Value_Id, new_ops: [] Value_Id, q: Simplify_Query) -> Value_Id {
    return simplify_instruction_with_operands_r(i, new_ops, q, RECURSION_LIMIT);
}
// llvm::simplifyInstruction
simplify_instruction :: (i: Value_Id, q: Simplify_Query) -> Value_Id {
    n := cast(s64) nops(i);
    buf: [8] Value_Id = ---;   // most instructions: no temp allocation
    ops: [] Value_Id;
    if n <= buf.count { ops.data = buf.data; ops.count = n; }
    else ops = NewArray(n, Value_Id,, allocator = temp);
    for k: 0..n - 1 ops[k] = op(i, cast(u32) k);
    res := simplify_instruction_with_operands_r(i, ops, q, RECURSION_LIMIT);
    if res == i return const_poison(vtype(i));
    return res;
}

