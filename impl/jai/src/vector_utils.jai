// Vector utilities shared by the vectorizers: shuffle-mask scaling (narrowShuffleMaskElts, widenShuffleMaskElts) and
// propagateIRFlags from llvm/lib/Analysis/VectorUtils.cpp and llvm/lib/Transforms/Utils/LoopUtils.cpp, and the
// reduction-intrinsic mappings of LoopUtils.cpp (getReductionForBinop, getArithmeticReductionInstruction,
// getMinMaxReductionIntrinsicID, getMinMaxReductionIntrinsicOp).
// Masks are [..] s32 with -1 (PoisonMaskElem) for poison lanes.

// narrowShuffleMaskElts(Scale, Mask, ScaledMask)
narrow_shuffle_mask_elts :: (scale: s64, mask: [] s32) -> [..] s32 {
    out: [..] s32; out.allocator = temp;
    for m: mask for k: 0..scale-1 array_add(*out, ifx m < 0 then m else cast(s32) (scale * m + k));
    return out;
}
// widenShuffleMaskElts(Scale, Mask, ScaledMask)
widen_shuffle_mask_elts :: (scale: s64, mask: [] s32) -> (bool, [..] s32) {
    out: [..] s32; out.allocator = temp;
    if scale == 1 { for mask array_add(*out, it); return true, out; }
    n := mask.count;
    if n % scale != 0 return false, out;
    i := 0;
    while i < n {
        front := mask[i];
        if front < 0 {
            for k: 1..scale-1 if mask[i + k] != front return false, out;
            array_add(*out, front);
        } else {
            if front % scale != 0 return false, out;
            for k: 1..scale-1 if mask[i + k] != front + k return false, out;
            array_add(*out, cast(s32) (front / scale));
        }
        i += scale;
    }
    return true, out;
}

// propagateIRFlags(I, VL, OpValue = nullptr, IncludeWrapFlags = true)
propagate_ir_flags :: (i: Value_Id, vl: [] Value_Id, op_value: Value_Id = NONE) {
    if !is_inst(i) return;
    inter := ifx op_value == NONE then vl[0] else op_value;
    if !is_inst(inter) return;
    opc := inst_op(inter);
    copy_ir_flags(i, inter);
    for v: vl {
        if !is_inst(v) continue;
        if op_value == NONE || opc == inst_op(v) and_ir_flags(i, v);
    }
}

// getReductionForBinop
reduction_for_binop :: (opc: Opcode) -> Intrinsic_Id {
    if opc == {
        case .ADD; return IID_VECTOR_REDUCE_ADD;
        case .MUL; return IID_VECTOR_REDUCE_MUL;
        case .AND; return IID_VECTOR_REDUCE_AND;
        case .OR; return IID_VECTOR_REDUCE_OR;
        case .XOR; return IID_VECTOR_REDUCE_XOR;
        case .FADD; return IID_VECTOR_REDUCE_FADD;
        case .FMUL; return IID_VECTOR_REDUCE_FMUL;
    }
    return NOT_INTRINSIC;
}
// getArithmeticReductionInstruction
arithmetic_reduction_instruction :: (id: Intrinsic_Id) -> Opcode {
    if id == {
        case IID_VECTOR_REDUCE_FADD; return .FADD;
        case IID_VECTOR_REDUCE_FMUL; return .FMUL;
        case IID_VECTOR_REDUCE_ADD; return .ADD;
        case IID_VECTOR_REDUCE_MUL; return .MUL;
        case IID_VECTOR_REDUCE_AND; return .AND;
        case IID_VECTOR_REDUCE_OR; return .OR;
        case IID_VECTOR_REDUCE_XOR; return .XOR;
        case IID_VECTOR_REDUCE_SMAX; #through; case IID_VECTOR_REDUCE_SMIN; #through;
        case IID_VECTOR_REDUCE_UMAX; #through; case IID_VECTOR_REDUCE_UMIN; return .ICMP;
        case IID_VECTOR_REDUCE_FMAX; #through; case IID_VECTOR_REDUCE_FMIN; #through;
        case IID_VECTOR_REDUCE_FMAXIMUM; #through; case IID_VECTOR_REDUCE_FMINIMUM; return .FCMP;
    }
    fatal("internal: getArithmeticReductionInstruction of a non-reduction intrinsic");
    return .NONE_OP;
}
// getMinMaxReductionIntrinsicID
min_max_reduction_intrinsic_id :: (id: Intrinsic_Id) -> Intrinsic_Id {
    if id == {
        case IID_UMIN; return IID_VECTOR_REDUCE_UMIN;
        case IID_UMAX; return IID_VECTOR_REDUCE_UMAX;
        case IID_SMIN; return IID_VECTOR_REDUCE_SMIN;
        case IID_SMAX; return IID_VECTOR_REDUCE_SMAX;
    }
    fatal("internal: getMinMaxReductionIntrinsicID: unexpected intrinsic");
    return NOT_INTRINSIC;
}
// getMinMaxReductionIntrinsicOp(RdxID)
min_max_reduction_intrinsic_op :: (id: Intrinsic_Id) -> Intrinsic_Id {
    if id == {
        case IID_VECTOR_REDUCE_UMIN; return IID_UMIN;
        case IID_VECTOR_REDUCE_UMAX; return IID_UMAX;
        case IID_VECTOR_REDUCE_SMIN; return IID_SMIN;
        case IID_VECTOR_REDUCE_SMAX; return IID_SMAX;
        case IID_VECTOR_REDUCE_FMIN; return IID_MINNUM;
        case IID_VECTOR_REDUCE_FMAX; return IID_MAXNUM;
        case IID_VECTOR_REDUCE_FMINIMUM; return IID_MINIMUM;
        case IID_VECTOR_REDUCE_FMAXIMUM; return IID_MAXIMUM;
    }
    fatal("internal: getMinMaxReductionIntrinsicOp: unknown min/max recurrence kind");
    return NOT_INTRINSIC;
}

IID_LOOP_DEPENDENCE_WAR_MASK :: #run iid_by_name("llvm.loop.dependence.war.mask");

// isVPIntrinsic: the llvm.vp.* and llvm.experimental.vp.* families (none of their VectorUtils/TTI cases are ported)
is_vp_intrinsic :: (id: Intrinsic_Id) -> bool {
    if id == NOT_INTRINSIC return false;
    n := iid_name(id);
    return begins_with(n, "llvm.vp.") || begins_with(n, "llvm.experimental.vp.");
}

// isVectorIntrinsicWithScalarOpAtArg(ID, ScalarOpdIdx, TTI). X86 answers false for every target intrinsic
// (BasicTTI's isTargetIntrinsicWithScalarOpAtArg), which is also what the generic switch answers for them.
vu_is_vector_intrinsic_with_scalar_op_at_arg :: (id: Intrinsic_Id, idx: u32) -> bool {
    if is_vp_intrinsic(id) fatal("vectorizer: VP intrinsics (%) are not supported yet", iid_name(id));
    if id == IID_VECTOR_SPLICE_LEFT || id == IID_VECTOR_SPLICE_RIGHT return idx == 2;
    if id == IID_LOOP_DEPENDENCE_WAR_MASK return true;
    return is_vector_intrinsic_with_scalar_op_at_arg(id, idx);
}
