// The TargetTransformInfo queries of the vectorizers (VectorCombine, SLPVectorizer), dispatched to X86TTIImpl
// (tti_x86*.goose) or to TargetTransformInfoImplBase (NoTTIImpl, a module without a target triple). Ports the
// wrappers of llvm/lib/Analysis/TargetTransformInfo.cpp (getShuffleCost, getVectorInstrCost, commonOperandInfo,
// getScalarizationOverhead, the reduction costs, the register queries) and the defaults of
// llvm/include/llvm/Analysis/TargetTransformInfoImpl.h; getAddressComputationCost of X86TTIImpl /
// BasicTTIImplBase (without ScalarEvolution).
//
// Costs are InstructionCost i64s (TTI_INVALID; combine with tc_add / tc_mul). Masks and demanded-element sets
// are passed as slices and copied into tti_x86_vec.goose's mk_pool for the call.
import std;
import ir;
import irutil;
import instinfo;
import gen_iids;
import gen_x86target;
import datalayout;
import apint;
import pm;
import tti;
import tti_x86;
import tti_x86_vec;
import tti_x86_intr;

// Operand value infos: kind * 4 + properties (tti.goose's tti_operand_info encoding)
fn tv_oi_is_constant(i: i64) -> bool { let k = i / 4; k == OK_UNIFORM_CONST || k == OK_NONUNIFORM_CONST }
// OperandValueInfo::mergeWith
fn tv_oi_merge(a: i64, b: i64) -> i64 {
    var k = OK_ANY;
    if tv_oi_is_constant(a) && tv_oi_is_constant(b) { k = OK_NONUNIFORM_CONST; }
    var p = 0;
    if a % 4 == b % 4 { p = a % 4; }
    return k * 4 + p;
}
// TTI::commonOperandInfo(X, Y)
fn tv_common_operand_info(x: i32, y: i32) -> i64 {
    let ox = tti_operand_info(x);
    if x == y { return ox; }
    return tv_oi_merge(ox, tti_operand_info(y));
}
fn tv_operand_info(v: i32) -> i64 { tti_operand_info(v) }

// getShuffleCost(Kind, DstTy, SrcTy, Mask, CostKind, Index, SubTp, Args (a0, a1; nargs of them), CxtI)
fn tv_shuffle(sk: i64, dst: i32, src: i32, mask: const i32[:], kind: i64, index: i64, subtp: i32, a0: i32, a1: i32,
              nargs: i64, cxt: i32) -> i64 {
    if tti_kind != TTI_X86 { return 1; }
    let m = mk_mark();
    let im = ica_mark();
    let ms = mk_pool.len;
    for x in mask { mk_pool.push(x); }
    let c = x86_shuffle_cost(sk, dst, src, ms, mask.len, kind, index, subtp, a0, a1, nargs, cxt);
    mk_release(m);
    ica_release(im);
    return c;
}
fn tv_shuffle_simple(sk: i64, dst: i32, src: i32, mask: const i32[:], kind: i64) -> i64 {
    return tv_shuffle(sk, dst, src, mask, kind, 0, -1, -1, -1, 0, -1);
}

// getVectorInstrCost(Opcode, Val, CostKind, Index, Op0, Op1); index -1 = unknown (the unsigned -1 of LLVM)
fn tv_vec_inst(o: i64, vt: i32, index: i64, op0: i32, op1: i32, kind: i64) -> i64 {
    if tti_kind != TTI_X86 { return 1; }
    let m = mk_mark();
    let im = ica_mark();
    let c = x86_vector_inst_cost(o, vt, index, op0, op1, kind);
    mk_release(m);
    ica_release(im);
    return c;
}
// getVectorInstrCost(const Instruction &I, Val, CostKind, Index): BasicTTIImplBase passes an insertelement's
// two operands
fn tv_vec_inst_i(i: i32, vt: i32, index: i64, kind: i64) -> i64 {
    let o = iop(i);
    let o0 = if o == OP_INSERTELEMENT { op(i, 0) } else { -1 };
    let o1 = if o == OP_INSERTELEMENT { op(i, 1) } else { -1 };
    return tv_vec_inst(o, vt, index, o0, o1, kind);
}

// getArithmeticInstrCost(Opcode, Ty, CostKind, Op1Info, Op2Info) without Args / CxtI
fn tv_arith(o: i64, ty: i32, kind: i64, oi1: i64, oi2: i64) -> i64 {
    if tti_kind != TTI_X86 { return base_arith_cost(o, ty, kind, -1, -1); }
    let m = mk_mark();
    let im = ica_mark();
    let c = x86_arith_cost(o, ty, kind, oi1, oi2, -1, -1, 0, -1);
    mk_release(m);
    ica_release(im);
    return c;
}
fn tv_arith0(o: i64, ty: i32, kind: i64) -> i64 { tv_arith(o, ty, kind, 0, 0) }

// getCmpSelInstrCost(Opcode, ValTy, CondTy, VecPred, CostKind, Op1Info, Op2Info, I = nullptr)
fn tv_cmpsel(o: i64, valty: i32, condty: i32, pred: i64, kind: i64, oi1: i64, oi2: i64) -> i64 {
    if tti_kind != TTI_X86 { return 1; }
    let p = if pred < 0 { PRED_BAD_ICMP } else { pred };
    let m = mk_mark();
    let im = ica_mark();
    let c = x86_cmpsel_cost(o, valty, condty, p, kind, oi1, oi2, -1);
    mk_release(m);
    ica_release(im);
    return c;
}

// getCastInstrCost(Opcode, Dst, Src, CCH, CostKind, I); cch 0 = CastContextHint::None
fn tv_cast(o: i64, dst: i32, src: i32, cch: i64, kind: i64, i: i32) -> i64 {
    if tti_kind != TTI_X86 { return base_cast_cost(o, dst, src); }
    let m = mk_mark();
    let im = ica_mark();
    let c = x86_cast_cost(o, dst, src, cch, kind, i);
    mk_release(m);
    ica_release(im);
    return c;
}
// TTI::getCastContextHint(I)
fn tv_cast_context_hint(i: i32) -> i64 { x86_cast_context(i) }

// getMemoryOpCost(Opcode, Src, Alignment, AddressSpace, CostKind, OpInfo = {}, I = nullptr)
fn tv_mem(o: i64, ty: i32, align: i64, as_: i64, kind: i64) -> i64 {
    if tti_kind != TTI_X86 { return 1; }
    let m = mk_mark();
    let im = ica_mark();
    let c = x86_memory_op_cost(o, ty, align, as_, kind, 0, -1);
    mk_release(m);
    ica_release(im);
    return c;
}

// getScalarizationOverhead(Ty, DemandedElts, Insert, Extract, CostKind, ForPoisonSrc = true, VL = {})
fn tv_scalarization_overhead(ty: i32, demanded: const bool[:], insert: bool, extract: bool, kind: i64) -> i64 {
    if tti_kind != TTI_X86 { return 0; }
    let m = mk_mark();
    let im = ica_mark();
    let ds = mk_pool.len;
    for d in demanded { mk_pool.push(if d { 1 } else { 0 }); }
    let c = x86_scalarization_overhead(ty, ds, insert, extract, kind, true);
    mk_release(m);
    ica_release(im);
    return c;
}

// getIntrinsicInstrCost(IntrinsicCostAttributes(ID, RetTy, Tys, FMF), CostKind): types only, no instruction
fn tv_intrinsic_types(id: i32, rt: i32, tys: const i32[:], fmf: u8, kind: i64) -> i64 {
    if tti_kind != TTI_X86 { return base_intrinsic_cost(id, rt); }
    let m = mk_mark();
    let im = ica_mark();
    let ic = ica_new(id as i64, rt, fmf, -1, TTI_INVALID);
    for t in tys { ica_add_type(ic, t); }
    let c = x86_intrinsic_cost(ic, kind);
    mk_release(m);
    ica_release(im);
    return c;
}
// getIntrinsicInstrCost(IntrinsicCostAttributes(ID, CallBase), CostKind)
fn tv_intrinsic_call(c: i32, kind: i64) -> i64 {
    if tti_kind != TTI_X86 { return base_intrinsic_cost(inst_iid(c), vals[c].ty); }
    let m = mk_mark();
    let im = ica_mark();
    let ic = ica_from_call(c, false);
    let r = x86_intrinsic_cost(ic, kind);
    mk_release(m);
    ica_release(im);
    return r;
}

// getArithmeticReductionCost(Opcode, Ty, FMF, CostKind); ordered = TTI::requiresOrderedReduction(FMF)
// (an engaged FMF without reassoc)
fn tv_arith_reduction(o: i64, ty: i32, ordered: bool, kind: i64) -> i64 {
    if tti_kind != TTI_X86 { return 1; }
    let m = mk_mark();
    let im = ica_mark();
    let c = x86_arith_reduction_cost(o, ty, ordered, kind);
    mk_release(m);
    ica_release(im);
    return c;
}
// getMinMaxReductionCost(IID, Ty, FMF, CostKind)
fn tv_minmax_reduction(id: i32, ty: i32, fmf: u8, kind: i64) -> i64 {
    if tti_kind != TTI_X86 { return 1; }
    let m = mk_mark();
    let im = ica_mark();
    let c = x86_minmax_reduction_cost(id, ty, fmf, kind);
    mk_release(m);
    ica_release(im);
    return c;
}
// getExtendedReductionCost(Opcode, IsUnsigned, ResTy, Ty, FMF, CostKind)
fn tv_extended_reduction(o: i64, unsigned: bool, rt: i32, ty: i32, fmf: u8, ordered: bool, kind: i64) -> i64 {
    if tti_kind != TTI_X86 { return 1; }
    let m = mk_mark();
    let im = ica_mark();
    let c = bt_extended_reduction_cost(o, unsigned, rt, ty, fmf, ordered, kind);
    mk_release(m);
    ica_release(im);
    return c;
}
// getMulAccReductionCost(IsUnsigned, RedOpcode, ResTy, Ty, CostKind)
fn tv_mul_acc_reduction(unsigned: bool, ro: i64, rt: i32, ty: i32, kind: i64) -> i64 {
    if tti_kind != TTI_X86 { return 1; }
    let m = mk_mark();
    let im = ica_mark();
    let c = bt_mul_acc_reduction_cost(unsigned, ro, rt, ty, kind);
    mk_release(m);
    ica_release(im);
    return c;
}

// getAddressComputationCost(PtrTy, SE = nullptr, Ptr = nullptr, CostKind): X86 only differs with SE
fn tv_address_computation(ptrty: i32, kind: i64) -> i64 { 0 }

// getInstructionCost(U, CostKind)
fn tv_inst_cost(u: i32, kind: i64) -> i64 { tti_instruction_cost(u, kind) }

// getRegisterBitWidth(K): 0 scalar, 1 fixed-width vector, 2 scalable vector
fn tv_register_bit_width(k: i64) -> i64 {
    if tti_kind == TTI_X86 { return x86_register_bit_width(k); }
    return 32;
}
// getMinVectorRegisterBitWidth (X86 keeps the TargetTransformInfoImplBase value)
fn tv_min_vector_register_bit_width() -> i64 { 128 }
// getNumberOfRegisters(ClassID)
fn tv_number_of_registers(cls: i64) -> i64 {
    if tti_kind == TTI_X86 { return x86_number_of_registers(cls); }
    return 8;
}
// getRegisterClassForType(Vector, Ty)
fn tv_register_class_for_type(vector: bool, t: i32) -> i64 {
    if tti_kind == TTI_X86 { return x86_register_class_for_type(vector, t); }
    return if vector { 1 } else { 0 };
}
// allowVectorElementIndexingUsingGEP: true for X86 and the base
fn tv_allow_vector_element_indexing_using_gep() -> bool { true }
