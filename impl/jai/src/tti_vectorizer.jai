// TargetTransformInfo queries the vectorizers ask (VectorCombine, SLPVectorizer): the TargetTransformInfo.cpp
// wrappers over X86TTIImpl / BasicTTIImplBase / TargetTransformInfoImplBase (NoTTIImpl) for register classes and
// widths, insert/extract and scalarization costs with explicit operands, reduction costs, and
// TargetTransformInfo::commonOperandInfo. Ported from llvm/lib/Analysis/TargetTransformInfo.cpp,
// llvm/include/llvm/Analysis/TargetTransformInfoImpl.h, llvm/include/llvm/CodeGen/BasicTTIImpl.h and
// llvm/lib/Target/X86/X86TargetTransformInfo.cpp (getRegisterClassForType, getNumberOfRegisters,
// getRegisterBitWidth, getAddressComputationCost). The cost tables themselves are in tti_x86*.jai.

RGK_SCALAR :: 0; RGK_FIXED_WIDTH_VECTOR :: 1; RGK_SCALABLE_VECTOR :: 2;

// getRegisterClassForType(Vector, Ty)
tti_register_class_for_type :: (t: *Tti, vector: bool, ty: Type_Id = NONE) -> u32 {
    if t.kind == .X86 {
        if vector return 1;
        if ty != NONE && is_fp_type(ty) return 2;
        return 0;
    }
    return ifx vector then cast(u32) 1 else 0;
}
// getNumberOfRegisters(ClassID)
tti_number_of_registers :: (t: *Tti, class_id: u32) -> u32 {
    if t.kind != .X86 return 8;
    st := *t.xl;
    if class_id == 1 && !st_hasSSE1(st) return 0;
    if !st_is64Bit(st) return 8;
    if (class_id == 0 && xs_has(st, X86FLD_HasEGPR)) || (class_id != 0 && st_hasAVX512(st)) return 32;
    return 16;
}
// getRegisterBitWidth(K): (bits, scalable)
tti_register_bit_width :: (t: *Tti, k: s64) -> u64 {
    if t.kind != .X86 return 32;
    st := *t.xl;
    if k == RGK_SCALAR return ifx st_is64Bit(st) then cast(u64) 64 else 32;
    if k == RGK_FIXED_WIDTH_VECTOR return tti_fixed_vector_register_bit_width(t);
    return 0;
}
// getMinVectorRegisterBitWidth (X86 does not override it)
tti_min_vector_register_bit_width :: (t: *Tti) -> u64 { return 128; }
// allowVectorElementIndexingUsingGEP (X86 does not override it)
tti_allow_vector_element_indexing_using_gep :: (t: *Tti) -> bool { return true; }

// getVectorInstrCost(Opcode, Val, CostKind, Index, Op0, Op1); index U32_NONE = unknown (-1)
tti_vector_instr_cost :: (t: *Tti, opc: Opcode, ty: Type_Id, kind: s64, index: u32, op0: Value_Id = NONE, op1: Value_Id = NONE) -> Cost {
    if t.kind == .X86 return x86_vector_instr_cost(t, opc, ty, kind, index, op0, op1);
    return 1;
}

// getScalarizationOverhead(Ty, DemandedElts, Insert, Extract, CostKind, ForPoisonSrc, VL)
tti_scalarization_overhead :: (t: *Tti, ty: Type_Id, dem: [] bool, insert: bool, extract: bool, kind: s64, for_poison_src := true, vl: [] Value_Id = .[]) -> Cost {
    if t.kind == .X86 {
        if type_kind(ty) == .SVECTOR return COST_INVALID;
        return x86_scalarization_overhead_dem(t, ty, dem, insert, extract, kind, for_poison_src, vl);
    }
    return 0;
}

// getArithmeticReductionCost(Opcode, Ty, FMF, CostKind); has_fmf = false is std::nullopt
tti_arithmetic_reduction_cost :: (t: *Tti, opc: Opcode, ty: Type_Id, has_fmf: bool, fmf: u32, kind: s64) -> Cost {
    if t.kind == .X86 return x86_arithmetic_reduction_cost(t, opc, ty, has_fmf, fmf, kind);
    return 1;
}
// getMinMaxReductionCost(IID, Ty, FMF, CostKind)
tti_min_max_reduction_cost :: (t: *Tti, id: Intrinsic_Id, ty: Type_Id, fmf: u32, kind: s64) -> Cost {
    if t.kind == .X86 return x86_min_max_reduction_cost(t, id, ty, fmf, kind);
    return 1;
}
// getExtendedReductionCost (BasicTTIImplBase; X86 does not override it)
tti_extended_reduction_cost :: (t: *Tti, opc: Opcode, is_unsigned: bool, res_ty: Type_Id, ty: Type_Id, has_fmf: bool, fmf: u32, kind: s64) -> Cost {
    if t.kind != .X86 return 1;
    if type_kind(ty) == .VECTOR && is_unsigned && opc == .ADD && type_elem(ty) == type_int(1) {
        it := type_int(cast(u32) type_count(ty));
        a := ica_types(iidn("llvm.ctpop"), it, .[it], ifx has_fmf then fmf else 0);
        return cost_add(x86_cast_cost(t, .BITCAST, it, ty, CCH_NONE, kind), x86_intrinsic_cost(t, *a, kind));
    }
    ext_ty := vector_with_elt(ty, res_ty);
    red := x86_arithmetic_reduction_cost(t, opc, ext_ty, has_fmf, fmf, kind);
    ext := x86_cast_cost(t, ifx is_unsigned then Opcode.ZEXT else .SEXT, ext_ty, ty, CCH_NONE, kind);
    return cost_add(red, ext);
}
// getMulAccReductionCost (BasicTTIImplBase; X86 does not override it)
tti_mul_acc_reduction_cost :: (t: *Tti, is_unsigned: bool, red_opc: Opcode, res_ty: Type_Id, ty: Type_Id, kind: s64) -> Cost {
    if t.kind != .X86 return 1;
    ext_ty := vector_with_elt(ty, res_ty);
    red := x86_arithmetic_reduction_cost(t, red_opc, ext_ty, false, 0, kind);
    ext := x86_cast_cost(t, ifx is_unsigned then Opcode.ZEXT else .SEXT, ext_ty, ty, CCH_NONE, kind);
    mul := x86_arith_cost(t, .MUL, ext_ty, kind, OI_ANY, OI_ANY);
    return cost_add(cost_add(red, mul), cost_mul(2, ext));
}

// getAddressComputationCost(PtrTy, SE = nullptr, Ptr = nullptr, CostKind): without a ScalarEvolution X86 and
// BasicTTI both answer 0.
tti_address_computation_cost_no_se :: (t: *Tti, ptr_ty: Type_Id, kind: s64) -> Cost { return 0; }

// TargetTransformInfo::commonOperandInfo(X, Y)
tti_common_operand_info :: (x: Value_Id, y: Value_Id) -> Op_Info {
    ox := tti_operand_info(x);
    if x == y return ox;
    oy := tti_operand_info(y);
    // OperandValueInfo::mergeWith
    k := OK_ANY_VALUE;
    if oi_is_constant(ox) && oi_is_constant(oy) k = OK_NON_UNIFORM_CONSTANT_VALUE;
    p := OP_NONE;
    if ox.props == oy.props p = ox.props;
    return .{cast(u8) k, cast(u8) p};
}

// isLegalBroadcastLoad(ElementTy, NumElements)
tti_is_legal_broadcast_load :: (t: *Tti, elt: Type_Id, n: u64) -> bool {
    if t.kind == .X86 return x86_is_legal_broadcast_load(*t.xl, elt, n, false);
    return false;
}
// isLegalMaskedGather(DataType, Alignment)
tti_is_legal_masked_gather :: (t: *Tti, ty: Type_Id, align: u64) -> bool {
    if t.kind == .X86 return x86_is_legal_masked_gather(*t.xl, ty);
    return false;
}
