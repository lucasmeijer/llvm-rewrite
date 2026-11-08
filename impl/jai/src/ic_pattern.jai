// PatternMatch matchers InstCombine needs beyond pattern.jai (llvm/include/llvm/IR/PatternMatch.h). Same conventions:
// pm_<matcher>(v) -> (matched, captures...). Instruction-only matchers (CastInst_match: m_ZExt, m_SExt, m_Trunc,
// m_UIToFP...; BinaryOp_match; DisjointOr_match) check is_inst; Operator matchers (OverflowingBinaryOp_match,
// CastOperator_match: m_PtrToInt, m_BitCast, m_IntToPtr) accept constant expressions too.

// CastInst_match: m_ZExt / m_SExt / m_Trunc / m_FPExt / m_SIToFP ... (instructions only)
pmi_cast :: (v: Value_Id, opc: Opcode) -> (bool, Value_Id) {
    if !is_inst(v) || inst_op(v) != opc return false, NONE;
    return true, op(v, 0);
}
// m_ZExtOrSExt (instructions)
pmi_zext_or_sext :: (v: Value_Id) -> (bool, Value_Id) {
    if !is_inst(v) return false, NONE;
    o := inst_op(v);
    if o == .ZEXT || o == .SEXT return true, op(v, 0);
    return false, NONE;
}
// m_ZExtOrSelf / m_SExtOrSelf / m_TruncOrSelf (instructions)
zext_or_self_i :: (v: Value_Id) -> Value_Id { ok, x := pmi_cast(v, .ZEXT); if ok return x; return v; }
sext_or_self_i :: (v: Value_Id) -> Value_Id { ok, x := pmi_cast(v, .SEXT); if ok return x; return v; }
trunc_or_self_i :: (v: Value_Id) -> Value_Id { ok, x := pmi_cast(v, .TRUNC); if ok return x; return v; }

// OverflowingBinaryOp_match: m_NSWAdd / m_NUWSub / ... (operators: constant expressions too)
pm_ob :: (v: Value_Id, opc: Opcode, flags: u32) -> (bool, Value_Id, Value_Id) {
    if v == NONE || opr_code(v) != opc return false, NONE, NONE;
    if (opr_flags(v) & flags) != flags return false, NONE, NONE;
    return true, op(v, 0), op(v, 1);
}
// m_DisjointOr (instructions)
pm_disjoint_or :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
    if !is_inst(v) || inst_op(v) != .OR || (inst(v).flags & F_EXACT) == 0 return false, NONE, NONE;
    return true, op(v, 0), op(v, 1);
}
// m_NUWAddLike / m_NSWAddLike: add with the flag, or `or disjoint`
pm_nuw_add_like_i :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
    ok, a, b := pm_ob(v, .ADD, F_NUW); if ok return true, a, b;
    ok, a, b = pm_disjoint_or(v); return ok, a, b;
}
pm_nsw_add_like_i :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
    ok, a, b := pm_ob(v, .ADD, F_NSW); if ok return true, a, b;
    ok, a, b = pm_disjoint_or(v); return ok, a, b;
}
// m_SpecificICmp(Pred, m_Value(A), m_Value(B)) (instructions)
pm_specific_icmp :: (v: Value_Id, pred: u8) -> (bool, Value_Id, Value_Id) {
    ok, p, ss, a, b := pm_icmp(v);
    if !ok || p != pred return false, NONE, NONE;
    return true, a, b;
}
// m_Constant: isa<Constant>
pm_constant :: inline (v: Value_Id) -> bool { return v != NONE && is_const(v); }
// m_SpecificIntAllowPoison(V) (same as m_SpecificInt in this port: splat with poison allowed)
pm_specific_int_allow_poison :: (v: Value_Id, val: u64) -> bool { return pm_specific_int(v, val, true); }
// m_APInt for an arbitrary value: scalar ConstantInt or non-poison splat
pm_apint_v :: (v: Value_Id) -> (bool, APInt) { ok, c := pm_apint(v); return ok, c; }
// m_Intrinsic<ID>(...) with operand capture
pm_intrinsic1 :: (v: Value_Id, id: Intrinsic_Id) -> (bool, Value_Id) {
    if call_iid(v) != id return false, NONE;
    return true, op(v, 0);
}
pm_intrinsic2 :: (v: Value_Id, id: Intrinsic_Id) -> (bool, Value_Id, Value_Id) {
    if call_iid(v) != id return false, NONE, NONE;
    return true, op(v, 0), op(v, 1);
}
// m_c_BinOp(opc) where the first operand must equal `x`: returns the other operand
pm_c_with :: (v: Value_Id, opc: Opcode, x: Value_Id) -> (bool, Value_Id) {
    ok, o := pm_c_binop_with(v, opc, x);
    return ok, o;
}
// m_Ctpop(m_Value(X))
pm_ctpop :: (v: Value_Id) -> (bool, Value_Id) { ok, x := pm_intrinsic1(v, IID_CTPOP); return ok, x; }
