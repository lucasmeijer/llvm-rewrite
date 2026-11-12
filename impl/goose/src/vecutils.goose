// VectorUtils and the reduction helpers of LoopUtils that the vectorizers (VectorCombine, SLPVectorizer) share.
// Ports from
//   llvm/lib/Analysis/VectorUtils.cpp         (isVectorIntrinsicWithScalarOpAtArg, isVectorIntrinsicWithOverloadTypeAtArg,
//                                              isVectorIntrinsicWithStructReturnOverloadAtField, getSplatValue,
//                                              isSplatValue, narrowShuffleMaskElts, widenShuffleMaskElts)
//   llvm/lib/Transforms/Utils/LoopUtils.cpp   (getReductionForBinop, getArithmeticReductionInstruction,
//                                              getMinMaxReductionIntrinsicID, getMinMaxReductionIntrinsicOp,
//                                              propagateIRFlags)
//   llvm/lib/IR/Instruction.cpp               (copyIRFlags, andIRFlags)
//   llvm/lib/Analysis/ConstantFolding.cpp     (getLosslessInvCast)
// Functions are prefixed vu_ (one global namespace).
import std;
import ir;
import irutil;
import instinfo;
import gen_iids;
import intrinsics;
import constfold;
import cfold;
import pm;
import apint;

// Intrinsic::isTargetIntrinsic: target intrinsics are numbered after the target-independent ones
fn vu_is_target_intrinsic(id: i32) -> bool { id > IID_xray_typedevent }

fn vu_is_vp_intrinsic(id: i32) -> bool {
    if id <= 0 { return false; }
    let n = intr_name(id as i64);
    return starts_with(n, "llvm.vp.") || starts_with(n, "llvm.experimental.vp.");
}

// VPIntrinsic::getVectorLengthParamPos: VP intrinsics fail loudly (not ported); -1 for every other id
fn vu_vp_length_param_pos(id: i32) -> i64 {
    if vu_is_vp_intrinsic(id) { fatal("VectorUtils: VPIntrinsic::getVectorLengthParamPos is not ported yet"); }
    return -1;
}

// isVectorIntrinsicWithScalarOpAtArg(ID, ScalarOpdIdx, TTI). With an X86 TTI a target intrinsic asks
// isTargetIntrinsicWithScalarOpAtArg, which X86 does not override (false); has_tti says whether a TTI is passed.
fn vu_scalar_op_at_arg(id: i32, k: i64, has_tti: bool) -> bool {
    if has_tti && vu_is_target_intrinsic(id) { return false; }
    if vu_vp_length_param_pos(id) == k { return true; }
    if id == IID_abs || id == IID_ctlz || id == IID_cttz || id == IID_is_fpclass || id == IID_powi || id == IID_vector_extract { return k == 1; }
    if vu_is_vp_intrinsic(id) { fatal("VectorUtils: isVectorIntrinsicWithScalarOpAtArg of VP intrinsics is not ported yet"); }
    if id == IID_smul_fix || id == IID_smul_fix_sat || id == IID_umul_fix || id == IID_umul_fix_sat ||
       id == IID_vector_splice_left || id == IID_vector_splice_right { return k == 2; }
    if id == IID_loop_dependence_war_mask { return true; }
    return false;
}

// isVectorIntrinsicWithOverloadTypeAtArg(ID, OpdIdx, TTI)
fn vu_overload_type_at_arg(id: i32, k: i64, has_tti: bool) -> bool {
    if has_tti && vu_is_target_intrinsic(id) { return k == -1; }   // isTargetIntrinsicWithOverloadTypeAtArg: OpdIdx == -1
    if vu_is_vp_intrinsic(id) { fatal("VectorUtils: isVectorIntrinsicWithOverloadTypeAtArg of VP intrinsics is not ported yet"); }
    if id == IID_fptosi_sat || id == IID_fptoui_sat || id == IID_lround || id == IID_llround || id == IID_lrint ||
       id == IID_llrint || id == IID_ucmp || id == IID_scmp || id == IID_vector_extract ||
       id == IID_loop_dependence_war_mask { return k == -1 || k == 0; }
    if id == IID_modf || id == IID_sincos || id == IID_sincospi || id == IID_is_fpclass { return k == 0; }
    if id == IID_powi || id == IID_ldexp { return k == -1 || k == 1; }
    return k == -1;
}

// isVectorIntrinsicWithStructReturnOverloadAtField(ID, RetIdx, TTI)
fn vu_struct_return_overload_at_field(id: i32, k: i64, has_tti: bool) -> bool {
    if has_tti && vu_is_target_intrinsic(id) { return k == 0; }
    if id == IID_frexp { return k == 0 || k == 1; }
    return k == 0;
}

// llvm::getSplatValue(V)
fn vu_get_splat_value(v: i32) -> i32 {
    if ty_is_vector(vals[v].ty) && is_constant(v) { return splat_value(v, false); }
    // shuf (inselt ?, Splat, 0), ?, <0, undef, 0, ...>
    if is_inst_op(v, OP_SHUFFLEVECTOR) {
        let ie = op(v, 0);
        if is_inst_op(ie, OP_INSERTELEMENT) && m_zero_int(op(ie, 2)) {
            let x = insts[inst_of(v)];
            for k in x.naux { let m = ints[x.aux + k]; if m != 0 && m != -1 { return -1; } }
            return op(ie, 1);
        }
    }
    return -1;
}

// llvm::isSplatValue(V, Index = -1, Depth)
recursive fn vu_is_splat_value(v: i32, depth0: i64) -> bool {
    var depth = depth0;
    if ty_is_vector(vals[v].ty) {
        if is_undef_or_poison(v) { return true; }
        if is_constant(v) { return splat_value(v, false) >= 0; }
    }
    if is_inst_op(v, OP_SHUFFLEVECTOR) {
        let x = insts[inst_of(v)];
        for k in x.naux { if ints[x.aux + k] != ints[x.aux] { return false; } }
        return true;
    }
    if depth == 6 { return false; }
    depth++;
    if is_inst(v) && is_binary_op(iop(v)) { return vu_is_splat_value(op(v, 0), depth) && vu_is_splat_value(op(v, 1), depth); }
    if is_inst_op(v, OP_SELECT) {
        return vu_is_splat_value(op(v, 0), depth) && vu_is_splat_value(op(v, 1), depth) && vu_is_splat_value(op(v, 2), depth);
    }
    return false;
}

// narrowShuffleMaskElts(Scale, Mask, ScaledMask)
fn vu_narrow_mask(scale: i64, mask: const i32[:], out: i32[>..<]&) {
    out.clear();
    for m in mask {
        for s in scale { out.push(if m < 0 { m } else { (scale * m as i64 + s) as i32 }); }
    }
}

// widenShuffleMaskElts(Scale, Mask, ScaledMask)
fn vu_widen_mask(scale: i64, mask: const i32[:], out: i32[>..<]&) -> bool {
    out.clear();
    if scale == 1 { for m in mask { out.push(m); } return true; }
    let n = mask.len;
    if n % scale != 0 { return false; }
    var at: i64 = 0;
    while at < n {
        let front = mask[at] as i64;
        if front < 0 {
            for k in scale { if mask[at + k] as i64 != front { out.clear(); return false; } }
            out.push(front as i32);
        } else {
            if front % scale != 0 { out.clear(); return false; }
            for k in 1..scale { if mask[at + k] as i64 != front + k { out.clear(); return false; } }
            out.push((front / scale) as i32);
        }
        at += scale;
    }
    return true;
}

// getReductionForBinop(Opc): 0 = not_intrinsic
fn vu_reduction_for_binop(o: i64) -> i32 {
    if o == OP_ADD { return IID_vector_reduce_add; }
    if o == OP_MUL { return IID_vector_reduce_mul; }
    if o == OP_AND { return IID_vector_reduce_and; }
    if o == OP_OR { return IID_vector_reduce_or; }
    if o == OP_XOR { return IID_vector_reduce_xor; }
    if o == OP_FADD { return IID_vector_reduce_fadd; }
    if o == OP_FMUL { return IID_vector_reduce_fmul; }
    return 0;
}

// getArithmeticReductionInstruction(RdxID)
fn vu_arith_reduction_instruction(id: i32) -> i64 {
    if id == IID_vector_reduce_fadd { return OP_FADD; }
    if id == IID_vector_reduce_fmul { return OP_FMUL; }
    if id == IID_vector_reduce_add { return OP_ADD; }
    if id == IID_vector_reduce_mul { return OP_MUL; }
    if id == IID_vector_reduce_and { return OP_AND; }
    if id == IID_vector_reduce_or { return OP_OR; }
    if id == IID_vector_reduce_xor { return OP_XOR; }
    if id == IID_vector_reduce_smax || id == IID_vector_reduce_smin || id == IID_vector_reduce_umax || id == IID_vector_reduce_umin { return OP_ICMP; }
    if id == IID_vector_reduce_fmax || id == IID_vector_reduce_fmin || id == IID_vector_reduce_fmaximum || id == IID_vector_reduce_fminimum { return OP_FCMP; }
    fatal("getArithmeticReductionInstruction: unexpected intrinsic");
    return -1;
}

// getMinMaxReductionIntrinsicID(IID)
fn vu_minmax_reduction_id(id: i32) -> i32 {
    if id == IID_umin { return IID_vector_reduce_umin; }
    if id == IID_umax { return IID_vector_reduce_umax; }
    if id == IID_smin { return IID_vector_reduce_smin; }
    if id == IID_smax { return IID_vector_reduce_smax; }
    fatal("getMinMaxReductionIntrinsicID: unexpected intrinsic");
    return 0;
}

// getMinMaxReductionIntrinsicOp(RdxID)
fn vu_minmax_reduction_op(id: i32) -> i32 {
    if id == IID_vector_reduce_umin { return IID_umin; }
    if id == IID_vector_reduce_umax { return IID_umax; }
    if id == IID_vector_reduce_smin { return IID_smin; }
    if id == IID_vector_reduce_smax { return IID_smax; }
    if id == IID_vector_reduce_fmin { return IID_minnum; }
    if id == IID_vector_reduce_fmax { return IID_maxnum; }
    if id == IID_vector_reduce_fminimum { return IID_minimum; }
    if id == IID_vector_reduce_fmaximum { return IID_maximum; }
    fatal("getMinMaxReductionIntrinsicOp: unknown min/max recurrence kind");
    return 0;
}

// MinMaxIntrinsic: smax/smin/umax/umin
fn vu_is_minmax_intrinsic(v: i32) -> bool {
    let id = inst_iid(v);
    return id != 0 && (id == IID_smax || id == IID_smin || id == IID_umax || id == IID_umin);
}

// ---------------------------------------------------------------- IR flags (Instruction.cpp)

fn vu_is_overflowing_op(o: i64) -> bool { o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_SHL }
fn vu_is_possibly_exact(o: i64) -> bool { o == OP_UDIV || o == OP_SDIV || o == OP_LSHR || o == OP_ASHR }
// FPMathOperator for an instruction or a constant expression (constant expressions are never FP math operators here)
fn vu_is_fp_math(v: i32) -> bool { is_inst(v) && is_fp_math_operator(v) }

// Instruction::copyIRFlags(V, IncludeWrapFlags): sets the flags V has that this instruction can carry
fn vu_copy_ir_flags(dst: i32, src: i32, include_wrap: bool) {
    if !is_inst(dst) { return; }
    let so = opcode_of(src);
    if so < 0 { return; }
    let o = iop(dst);
    let sf = op_flags(src);
    let d = inst_of(dst);
    var f = insts[d].flags;
    if include_wrap && vu_is_overflowing_op(o) && vu_is_overflowing_op(so) {
        f = (f & ~(FL_NUW | FL_NSW)) | (sf & (FL_NUW | FL_NSW));
    }
    if so == OP_TRUNC && o == OP_TRUNC { f = (f & ~(FL_NUW | FL_NSW)) | (sf & (FL_NUW | FL_NSW)); }
    if vu_is_possibly_exact(so) && vu_is_possibly_exact(o) { f = (f & ~FL_EXACT) | (sf & FL_EXACT); }
    if so == OP_OR && o == OP_OR { f = (f & ~FL_DISJOINT) | (sf & FL_DISJOINT); }
    if so == OP_GEP && o == OP_GEP { f = f | sf; }
    if (so == OP_ZEXT || so == OP_UITOFP) && (o == OP_ZEXT || o == OP_UITOFP) { f = (f & ~FL_NNEG) | (sf & FL_NNEG); }
    if so == OP_ICMP && o == OP_ICMP { f = (f & ~FL_SAMESIGN) | (sf & FL_SAMESIGN); }
    insts[d].flags = f;
    if vu_is_fp_math(src) && is_fp_math_operator(dst) { insts[d].fmf = insts[inst_of(src)].fmf; }
}

// Instruction::andIRFlags(V)
fn vu_and_ir_flags(dst: i32, src: i32) {
    if !is_inst(dst) { return; }
    let so = opcode_of(src);
    if so < 0 { return; }
    let o = iop(dst);
    let fs = op_flags(src);
    let d = inst_of(dst);
    var f = insts[d].flags;
    if vu_is_overflowing_op(so) && vu_is_overflowing_op(o) { f = f & (fs | ~(FL_NSW | FL_NUW)); }
    if so == OP_TRUNC && o == OP_TRUNC { f = f & (fs | ~(FL_NSW | FL_NUW)); }
    if vu_is_possibly_exact(so) && vu_is_possibly_exact(o) { f = f & (fs | ~FL_EXACT); }
    if so == OP_OR && o == OP_OR { f = f & (fs | ~FL_DISJOINT); }
    if so == OP_GEP && o == OP_GEP { f = f & fs; }
    if (so == OP_ZEXT || so == OP_UITOFP) && (o == OP_ZEXT || o == OP_UITOFP) { f = f & (fs | ~FL_NNEG); }
    if so == OP_ICMP && o == OP_ICMP { f = f & (fs | ~FL_SAMESIGN); }
    insts[d].flags = f;
    if vu_is_fp_math(src) && is_fp_math_operator(dst) { insts[d].fmf = insts[d].fmf & insts[inst_of(src)].fmf; }
}

// propagateIRFlags(I, VL, OpValue = nullptr, IncludeWrapFlags = true)
fn vu_propagate_ir_flags(i: i32, vl: const i32[:], opvalue: i32, include_wrap: bool) {
    if !is_inst(i) || vl.len == 0 { return; }
    let inter = if opvalue < 0 { vl[0] } else { opvalue };
    if !is_inst(inter) { return; }
    let opc = iop(inter);
    vu_copy_ir_flags(i, inter, include_wrap);
    for v in vl {
        if !is_inst(v) { continue; }
        if opvalue < 0 || opc == iop(v) { vu_and_ir_flags(i, v); }
    }
}

// getLosslessInvCast(C, InvCastTo, CastOp, DL, &Flags): (constant or -1, nneg, nuw, nsw)
fn vu_lossless_inv_cast(c: i32, to: i32, cast_op: i64) -> i32, bool, bool, bool {
    if cast_op == OP_BITCAST { return cf_fold_cast_operand(OP_BITCAST, c, to), false, false, false; }
    if cast_op == OP_TRUNC {
        let z = cf_fold_cast_operand(OP_ZEXT, c, to);
        let s = cf_fold_cast_operand(OP_SEXT, c, to);
        return z, false, true, z == s;
    }
    if cast_op == OP_SEXT || cast_op == OP_ZEXT {
        let inv = ce_cast(OP_TRUNC, c, to);
        if inv < 0 { return -1, false, false, false; }
        let back = cf_fold_cast_operand(cast_op, inv, vals[c].ty);
        if back < 0 || back != c { return -1, false, false, false; }
        var nneg = false;
        if cast_op == OP_ZEXT { nneg = back == cf_fold_cast_operand(OP_SEXT, inv, vals[c].ty); }
        return inv, nneg, false, false;
    }
    if cast_op == OP_FPEXT {
        let inv = cf_fold_cast_operand(OP_FPTRUNC, c, to);
        if inv >= 0 && cf_fold_cast_operand(cast_op, inv, vals[c].ty) == c { return inv, false, false, false; }
        return -1, false, false, false;
    }
    return -1, false, false, false;
}
