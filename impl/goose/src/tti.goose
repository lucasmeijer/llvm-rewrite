// TargetTransformInfo: the front end of the cost model and the print<cost-model> printer. Ports
//   llvm/lib/Analysis/TargetTransformInfo.cpp   (the TargetTransformInfo wrappers, getOperandInfo,
//                                                getCastContextHint, getPredictableBranchThreshold)
//   llvm/include/llvm/Analysis/TargetTransformInfoImpl.h (TargetTransformInfoImplBase = NoTTIImpl, used by opt
//                                                when the module has no target triple, and
//                                                TargetTransformInfoImplCRTPBase::getInstructionCost / getGEPCost)
//   llvm/lib/Analysis/CostModel.cpp             (CostModelPrinterPass, -cost-kind, -intrinsic-cost-strategy)
// The x86 target (X86TTIImpl over BasicTTIImplBase) is tti_x86*.goose, selected by tti_init_function for x86
// triples. Costs are InstructionCost values (tti_x86.goose: TTI_INVALID, tc_add, tc_mul).
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import datalayout;
import apint;
import pm;
import vt;
import flags;
import tti_x86;
import tti_x86_vec;
import tti_x86_intr;
import x86_lower;
import gen_x86target;

// The target: 0 = none (NoTTIImpl), 1 = x86 (X86TTIImpl).
let TTI_NONE = 0;
let TTI_X86 = 1;
var tti_kind: i64 = 0;
var tti_module: i32 = -1;

// TargetIRAnalysis for the module: opt creates a TargetMachine from the module triple when the target is
// registered (an empty triple gives NoTTIImpl).
fn tti_init(m: i32) { tti_init_function(-1, m); }

// TargetIRAnalysis::run(F): the subtarget of an x86 target depends on the function's attributes.
fn tti_init_function(fv: i32, m: i32) {
    tti_module = m;
    let t = modules[m].triple;
    if t < 0 || sbytes(t).len == 0 { tti_kind = TTI_NONE; return; }
    let s = sbytes(t);
    if starts_with(s, "x86_64") || starts_with(s, "i386") || starts_with(s, "i686") || starts_with(s, "i586") ||
       starts_with(s, "i486") || starts_with(s, "x86") {
        tti_kind = TTI_X86;
        x86_subtarget_init(s, fv);
        return;
    }
    fatal(str("TargetTransformInfo for target triple '", s, "' is not supported"));
}

fn tti_x86_not_ported(what: const u8[:]) { x86_np(what); }

fn tti_branch_mispredict_penalty() -> i64 {
    if tti_kind == TTI_X86 { return 14; }
    return 0;
}

fn tti_is_profitable_to_hoist(i: i32) -> bool { true }

fn tti_has_conditional_load_store_for_type(t: i32, is_store: bool) -> bool {
    if tti_kind == TTI_X86 { return x86_has_conditional_load_store_for_type(t); }
    return false;
}

fn tti_should_build_lookup_tables() -> bool {
    if tti_kind == TTI_X86 {
        // BasicTTIImplBase: isOperationLegalOrCustom(BR_JT, Other) || isOperationLegalOrCustom(BRIND, Other)
        return tl_legal_or_custom(XISD_BR_JT, MVT_Other as i64) || tl_legal_or_custom(XISD_BRIND, MVT_Other as i64);
    }
    return true;
}
fn tti_should_build_lookup_tables_for_constant(c: i32) -> bool {
    return true;
}
fn tti_should_build_rel_lookup_tables() -> bool {
    // BasicTTIImplBase: PIC, not the medium/large code model, a 64-bit arch
    if tti_kind == TTI_X86 { return x86_pic && x86_is64; }
    return false;
}
fn tti_is_type_legal(t: i32) -> bool {
    if tti_kind == TTI_X86 { return x86_is_type_legal(t); }
    return false;
}
fn tti_minimum_lookup_table_entry_bits() -> i64 {
    return 8;
}
fn tti_reg_usage_for_type(t: i32) -> i64 {
    if tti_kind == TTI_X86 { return x86_reg_usage(t); }
    return 1;
}

// ---------------------------------------------------------------- the cost entry points

// getArithmeticInstrCost(Opcode, Ty, CostKind, getOperandInfo(Args[0..]), Args)
fn tti_arith_cost(o: i64, ty: i32, kind: i64, args: const i32[:]) -> i64 {
    let a0 = if args.len > 0 { args[0] } else { -1 };
    let a1 = if args.len > 1 { args[1] } else { -1 };
    if tti_kind == TTI_X86 {
        let o1 = if args.len > 0 { tti_operand_info(args[0]) } else { 0 };
        let o2 = if args.len > 1 { tti_operand_info(args[1]) } else { 0 };
        return x86_arith_cost(o, ty, kind, o1, o2, a0, a1, args.len, -1);
    }
    return base_arith_cost(o, ty, kind, a0, a1);
}

// getInstructionCost(U, Operands, CostKind) with Operands != U's operands (LoopUnroll's cost analysis passes
// the simplified operands): while tti_ovr_inst = U, operand k of U reads as tti_ovr_ops[k].
var tti_ovr_inst: i32 = -1;
var tti_ovr_ops: i32[>..<];
fn tti_opnd(u: i32, k: i64) -> i32 {
    if u == tti_ovr_inst && k < tti_ovr_ops.len { return tti_ovr_ops[k]; }
    return op(u, k);
}

fn tti_cast_cost(o: i64, dst: i32, src: i32, kind: i64) -> i64 { tti_cast_cost_i(o, dst, src, kind, -1) }

// getCastInstrCost(Opcode, Dst, Src, getCastContextHint(I), CostKind, I); i is the instruction or -1
fn tti_cast_cost_i(o: i64, dst: i32, src: i32, kind: i64, i: i32) -> i64 {
    if tti_kind == TTI_X86 { return x86_cast_cost(o, dst, src, x86_cast_context(i), kind, i); }
    return base_cast_cost(o, dst, src);
}

fn tti_cf_cost(o: i64, kind: i64) -> i64 {
    if tti_kind == TTI_X86 { return x86_cf_cost(o, kind); }
    if o == OP_PHI && kind != TCK_RECIP_THROUGHPUT { return 0; }
    return 1;
}

// getCmpSelInstrCost(Opcode, ValTy, CondTy, VecPred (-1: BAD_ICMP_PREDICATE), CostKind, ...)
fn tti_cmpsel_cost(o: i64, valty: i32, condty: i32, pred: i64, kind: i64) -> i64 {
    return tti_cmpsel_cost_i(o, valty, condty, pred, kind, -1);
}
fn tti_cmpsel_cost_i(o: i64, valty: i32, condty: i32, pred: i64, kind: i64, i: i32) -> i64 {
    let p = if pred < 0 { PRED_BAD_ICMP } else { pred };
    if tti_kind == TTI_X86 { return x86_cmpsel_cost(o, valty, condty, p, kind, 0, 0, i); }
    return 1;
}

fn tti_memory_op_cost(o: i64, ty: i32, align: i64, as_: i64, kind: i64) -> i64 {
    return tti_memory_op_cost_i(o, ty, align, as_, kind, -1);
}
fn tti_memory_op_cost_i(o: i64, ty: i32, align: i64, as_: i64, kind: i64, i: i32) -> i64 {
    if tti_kind == TTI_X86 {
        let oi = if i >= 0 && is_inst_op(i, OP_STORE) { tti_operand_info(op(i, 0)) } else { 0 };
        return x86_memory_op_cost(o, ty, align, as_, kind, oi, i);
    }
    return 1;
}

// getVectorInstrCost(I, Ty, CostKind, Index) for an insertelement / extractelement instruction
fn tti_vector_inst_cost(i: i32, kind: i64) -> i64 {
    if tti_kind != TTI_X86 { return 1; }
    let o = iop(i);
    let vt = if o == OP_INSERTELEMENT { vals[i].ty as i32 } else { vals[tti_opnd(i, 0)].ty as i32 };
    let ix = tti_opnd(i, if o == OP_INSERTELEMENT { 2 } else { 1 });
    var idx: i64 = -1;
    if vals[ix].kind == VK_CINT && !ty_is_vector(vals[ix].ty) && ap_active_bits(ci_ap(ix)) <= 32 {
        idx = ap_zext64(ci_ap(ix)) as i64;
    }
    let o0 = if o == OP_INSERTELEMENT { op(i, 0) } else { -1 };
    let o1 = if o == OP_INSERTELEMENT { op(i, 1) } else { -1 };
    return x86_vector_inst_cost(o, vt, idx, o0, o1, kind);
}

fn tti_insert_extract_value_cost(o: i64, kind: i64) -> i64 {
    // TargetTransformInfoImplBase::getInsertExtractValueCost (neither BasicTTIImpl nor X86 overrides it)
    if o == OP_INSERTVALUE && kind != TCK_RECIP_THROUGHPUT { return TCC_BASIC; }
    return TCC_FREE;
}

// getIntrinsicInstrCost(IntrinsicCostAttributes(id, CallBase)) for an intrinsic call
fn tti_intrinsic_cost(c: i32, id: i32, kind: i64) -> i64 { tti_intrinsic_cost_strategy(c, kind, false) }

fn tti_intrinsic_cost_strategy(c: i32, kind: i64, type_based: bool) -> i64 {
    if tti_kind != TTI_X86 { return base_intrinsic_cost(inst_iid(c), vals[c].ty); }
    let m = ica_mark();
    let mm = mk_mark();
    let ic = ica_from_call(c, type_based);
    let r = x86_intrinsic_cost(ic, kind);
    ica_release(m);
    mk_release(mm);
    return r;
}

// getIntrinsicInstrCost(IntrinsicCostAttributes(id, ret, args)) without an instruction
fn tti_intrinsic_cost_args(id: i32, rt: i32, args: const i32[:], kind: i64) -> i64 {
    if tti_kind != TTI_X86 { return base_intrinsic_cost(id, rt); }
    let m = ica_mark();
    let mm = mk_mark();
    let ic = ica_new(id, rt, 0, -1, TTI_INVALID);
    for a in args { ica_add_arg(ic, a); }
    for a in args { ica_add_type(ic, vals[a].ty); }
    let r = x86_intrinsic_cost(ic, kind);
    ica_release(m);
    mk_release(mm);
    return r;
}

// isTruncateFree(Ty1, Ty2): TargetTransformInfoImplBase says no; X86TargetLowering::isTruncateFree: integer types
// with Ty1 wider than Ty2
fn tti_is_truncate_free(t1: i32, t2: i32) -> bool {
    if tti_kind != TTI_X86 { return false; }
    if !ty_is_int(t1) || !ty_is_int(t2) { return false; }
    return ty_bits(t1) > ty_bits(t2);
}

// getIntImmCostInst(Opcode, Idx, Imm, Ty, CostKind)
fn tti_int_imm_cost_inst(o: i64, idx: i64, imm: AP, ty: i32, kind: i64) -> i64 {
    if tti_kind == TTI_X86 { return x86_int_imm_cost_inst(o, idx, imm, ty, kind, -1); }
    return TCC_FREE;
}

// X86TTIImpl::getIntImmCost(int64_t)
fn x86_int_imm_cost_val(v: i64) -> i64 {
    if v == 0 { return TCC_FREE; }
    if v >= -2147483648 && v <= 2147483647 { return TCC_BASIC; }
    return 2 * TCC_BASIC;
}
// X86TTIImpl::getIntImmCost(APInt, Ty)
fn x86_int_imm_cost(imm: AP, ty: i32, kind: i64) -> i64 {
    let bs = tt_prim_bits(ty);
    if bs == 0 { return 0xffffffff; }
    if bs > 128 { return TCC_FREE; }
    if ap_is_zero(imm) { return TCC_FREE; }
    let w = ((bs + 63) / 64) * 64;
    let iv = if bs % 64 != 0 { ap_sext(imm, w) } else { imm };
    var c: i64 = 0;
    var sh: i64 = 0;
    while sh < bs {
        let t = ap_sext_or_trunc(ap_ashr(iv, sh), 64);
        c = tc_add(c, x86_int_imm_cost_val(ap_sext64(t)));
        sh += 64;
    }
    return if c > 1 { c } else { 1 };
}
// X86TTIImpl::getIntImmCostInst
fn x86_int_imm_cost_inst(o: i64, idx: i64, imm: AP, ty: i32, kind: i64, inst: i32) -> i64 {
    let bs = tt_prim_bits(ty);
    let iw = imm.w as i64;
    if bs == 0 { return TCC_FREE; }
    var immidx: i64 = -1;
    if o == OP_GEP {
        if idx == 0 { return 2 * TCC_BASIC; }
        return TCC_FREE;
    } else if o == OP_STORE {
        immidx = 0;
    } else if o == OP_ICMP {
        if idx == 1 && iw == 64 {
            let v = ap_zext64(imm);
            if v == 0x100000000 || v == 0xffffffff { return TCC_FREE; }
            if inst >= 0 { x86_np("getIntImmCostInst of an icmp with computeKnownBits"); }
        }
        immidx = 1;
    } else if o == OP_AND {
        if idx == 1 && iw == 64 && ap_is_signed_int_n(imm, 32) { return TCC_FREE; }
        if idx == 1 && iw == 64 && x86_is64() && xst_hasBMI() && ap_is_mask(imm) {
            return x86_int_imm_cost_val(if xst_hasBMI2() { 255 } else { 65535 });
        }
        immidx = 1;
    } else if o == OP_ADD || o == OP_SUB {
        if idx == 1 && iw == 64 && ap_zext64(imm) == 0x80000000 { return TCC_FREE; }
        immidx = 1;
    } else if o == OP_UDIV || o == OP_SDIV || o == OP_UREM || o == OP_SREM {
        return TCC_FREE;
    } else if o == OP_MUL || o == OP_OR || o == OP_XOR {
        immidx = 1;
    } else if o == OP_SHL || o == OP_LSHR || o == OP_ASHR {
        if idx == 1 { return TCC_FREE; }
    } else if o == OP_TRUNC || o == OP_ZEXT || o == OP_SEXT || o == OP_INTTOPTR || o == OP_PTRTOINT ||
              o == OP_BITCAST || o == OP_PHI || o == OP_CALL || o == OP_SELECT || o == OP_RET || o == OP_LOAD {
    } else {
        return TCC_FREE;
    }
    if idx == immidx {
        let nc = (bs + 63) / 64;
        let c = x86_int_imm_cost(imm, ty, kind);
        return if c <= nc * TCC_BASIC { TCC_FREE } else { c };
    }
    return x86_int_imm_cost(imm, ty, kind);
}
// TargetTransformInfo::getPredictableBranchThreshold as (numerator, denominator) of a BranchProbability.
// -predictable-branch-threshold is not supported (fails as an unknown flag).
fn tti_predictable_branch_threshold() -> u32 {
    // BranchProbability(99, 100) in units of 1 << 31
    return bp_from_ratio(99, 100);
}

// BranchProbability(Numerator, Denominator): N * D_scale / D, rounded to nearest (BranchProbability.cpp).
let BP_D: u64 = 0x80000000;
fn bp_from_ratio(n: u64, d: u64) -> u32 {
    if d == BP_D { return n as u32; }
    let prob = (n * BP_D + d / 2) / d;
    return prob as u32;
}
// BranchProbability::getBranchProbability(Numerator, Denominator) with 64-bit inputs (scales down first)
fn bp_get(n0: u64, d0: u64) -> u32 {
    var n = n0;
    var d = d0;
    // Scale down Denominator to fit in a 32-bit integer.
    var scale = 0;
    while (d >> scale) > 0xFFFFFFFF { scale++; }
    n = n >> scale;
    d = d >> scale;
    return bp_from_ratio(n, d);
}
fn bp_compl(p: u32) -> u32 { (BP_D as u32) - p }


// isLoweredToCall(F) (TargetTransformInfoImplBase)
fn tti_is_lowered_to_call(f: i32) -> bool {
    if func_iid(f) != 0 { return false; }
    let l = globs[glob_of(f)].linkage as i64;
    if l == LK_INTERNAL || l == LK_PRIVATE || vals[f].name < 0 { return true; }
    let nm = sbytes(vals[f].name);
    let free_names: const u8[:][] = [
        "copysign", "copysignf", "copysignl", "fabs", "fabsf", "fabsl", "fmin", "fminf", "fminl",
        "fmax", "fmaxf", "fmaxl", "sin", "sinf", "sinl", "cos", "cosf", "cosl", "tan", "tanf", "tanl",
        "asin", "asinf", "asinl", "acos", "acosf", "acosl", "atan", "atanf", "atanl", "atan2", "atan2f", "atan2l",
        "sinh", "sinhf", "sinhl", "cosh", "coshf", "coshl", "tanh", "tanhf", "tanhl", "sqrt", "sqrtf", "sqrtl",
        "exp10", "exp10l", "exp10f",
        "pow", "powf", "powl", "exp2", "exp2l", "exp2f", "floor", "floorf", "ceil", "round", "ffs", "ffsl",
        "abs", "labs", "llabs"];
    for n in free_names { if n == nm { return false; } }
    return true;
}


// GEP access type for getGEPCost: the single user's getAccessType (Instruction::getAccessType).
fn tti_access_type(u: i32) -> i32 {
    let o = iop(u);
    if o == OP_LOAD { return vals[u].ty; }
    if o == OP_STORE { return vals[op(u, 0)].ty; }
    if o == OP_ATOMICRMW { return vals[op(u, 1)].ty; }
    if o == OP_CMPXCHG { return vals[op(u, 1)].ty; }
    return -1;
}

// isLegalAddressingMode (TargetTransformInfoImplBase)
fn tti_legal_addressing_mode(ty: i32, base_gv: i32, off: i64, has_base: bool, scale: i64, as_: i64) -> bool {
    if tti_kind == TTI_X86 { return x86_legal_addressing_mode(base_gv, off, has_base, scale); }
    return base_gv < 0 && off == 0 && (scale == 0 || scale == 1);
}

// getGEPCost (TargetTransformInfoImplCRTPBase)
fn tti_gep_cost(src_ty: i32, ptr: i32, g: i32, access_ty0: i32, kind: i64) -> i64 {
    let sp = strip_pointer_casts_tti(ptr);
    let base_gv = if is_global(sp) { sp } else { -1 };
    let has_base = base_gv < 0;
    let w = dl_size_bits(ty_scalar(vals[ptr].ty));
    var base_off = ap_zero(w);
    var scale: i64 = 0;
    let n = nops(g) - 1;
    if n == 0 { return if base_gv < 0 { TCC_FREE } else { TCC_BASIC }; }
    var t = src_ty;            // the indexed type before the current index
    var target_ty: i32 = -1;
    for k in n {
        let ix = tti_opnd(g, k + 1);
        // gep_type_iterator: the first index steps over the source type itself
        var cur = t;
        var is_struct = false;
        if k == 0 {
            target_ty = src_ty;
        } else {
            if ty_is_struct(t) { is_struct = true; }
            target_ty = ty_index_type(t, ix);
        }
        var ci = m_constant_int(ix);
        if ci < 0 && is_constant(ix) && ty_is_vector(vals[ix].ty) {
            let s = splat_value(ix, false);
            if s >= 0 && vals[s].kind == VK_CINT { ci = s; }
        }
        if is_struct {
            let field = ci_val(ci) as i64;
            base_off = ap_add(base_off, ap_u64(dl_struct_offset(t, field) as u64, w));
        } else {
            if ty_kind(target_ty) == TK_SVEC || ty_has_scalable_tti(target_ty) { return TCC_BASIC; }
            let esz = if k == 0 { dl_alloc_size(src_ty) } else { dl_gep_stride(t, target_ty) };
            if ci >= 0 {
                base_off = ap_add(base_off, ap_mul(ap_sext_or_trunc(ci_ap(ci), w), ap_i64(esz, w)));
            } else {
                if scale != 0 { return TCC_BASIC; }
                scale = esz;
            }
        }
        t = target_ty;
        cur = cur;
    }
    var access_ty = access_ty0;
    if access_ty < 0 { access_ty = target_ty; }
    if tti_legal_addressing_mode(access_ty, base_gv, ap_sext64(ap_sext_or_trunc(base_off, 64)), has_base, scale, ptr_as(vals[ptr].ty)) {
        return TCC_FREE;
    }
    return TCC_BASIC;
}

recursive fn ty_has_scalable_tti(t: i32) -> bool {
    let k = types[t].kind;
    if k == TK_SVEC { return true; }
    if k == TK_STRUCT { for j in types[t].cnt { if ty_has_scalable_tti(ty_field(t, j)) { return true; } } return false; }
    if k == TK_ARRAY || k == TK_FVEC { return ty_has_scalable_tti(types[t].a); }
    return false;
}

// GetElementPtrInst::getTypeAtIndex step for gep_type_iterator
fn ty_index_type(t: i32, ix: i32) -> i32 {
    if ty_is_struct(t) {
        var c = m_constant_int(ix);
        if c < 0 { c = m_apint(ix); }
        return ty_field(t, ci_val(c) as i64);
    }
    return types[t].a;
}

// Value::stripPointerCasts (stripPointerCastsAndOffsets<PSK_ZeroIndices>: stops when a value repeats)
fn strip_pointer_casts_tti(v0: i32) -> i32 {
    var v = v0;
    var seen: i32[>..<] = [];
    loop {
        for x in seen { if x == v { return v; } }
        seen.push(v);
        let o = opcode_of(v);
        if o == OP_BITCAST || o == OP_ADDRSPACECAST { v = op(v, 0); continue; }
        if o == OP_GEP {
            var allz = true;
            for k in 1..nops(v) { let x = op(v, k); if !(is_constant(x) && is_null_value(x)) { allz = false; } }
            if allz { v = op(v, 0); continue; }
        }
        return v;
    }
}

// AllocaInst::isStaticAlloca
fn tti_is_static_alloca(a: i32) -> bool {
    if vals[op(a, 0)].kind != VK_CINT { return false; }
    let b = inst_parent(a);
    if func_entry(block_func(b)) != b { return false; }
    return (insts[inst_of(a)].bits & 1) == 0;
}


let OK_ANY = 0;
let OK_UNIFORM = 1;
let OK_UNIFORM_CONST = 2;
let OK_NONUNIFORM_CONST = 3;

// TargetTransformInfo::getOperandInfo as kind * 4 + properties: kind OK_* above, properties 0 None,
// 1 PowerOf2, 2 NegatedPowerOf2.
fn tti_operand_info(v: i32) -> i64 {
    if v < 0 { return 0; }
    let k = vals[v].kind;
    if k == VK_UNDEF || k == VK_POISON { return 0; }
    if k == VK_CINT {
        // a vector-typed ConstantInt is a splat ConstantInt
        let a = ci_ap(v);
        if ap_is_pow2(a) { return OK_UNIFORM_CONST * 4 + 1; }
        if ap_is_neg_pow2(a) { return OK_UNIFORM_CONST * 4 + 2; }
        return OK_UNIFORM_CONST * 4;
    }
    if k == VK_CFP { return OK_UNIFORM_CONST * 4; }
    var info = OK_ANY;
    var props = 0;
    if is_inst_op(v, OP_SHUFFLEVECTOR) && shuffle_is_zero_elt_splat_tti(v) { info = OK_UNIFORM; }
    let sp = tti_get_splat_value(v);
    if sp >= 0 {
        if is_arg(sp) || is_global(sp) { info = OK_UNIFORM; }
        else if is_constant(sp) {
            info = OK_UNIFORM_CONST;
            if vals[sp].kind == VK_CINT {
                let a = ci_ap(sp);
                if ap_is_pow2(a) { props = 1; } else if ap_is_neg_pow2(a) { props = 2; }
            }
        }
    } else if k == VK_CDVECTOR || k == VK_CDARRAY {
        info = OK_NONUNIFORM_CONST;
        var all_p = true;
        var all_n = true;
        let n = ty_count(vals[v].ty);
        for e in n {
            let c = agg_elem(v, e);
            if c >= 0 && vals[c].kind == VK_CINT {
                let a = ci_ap(c);
                all_p = all_p && ap_is_pow2(a);
                all_n = all_n && ap_is_neg_pow2(a);
                if all_p || all_n { continue; }
            }
            all_p = false;
            all_n = false;
            break;
        }
        if all_p { props = 1; }
        if all_n { props = 2; }
    } else if k == VK_CVECTOR {
        info = OK_NONUNIFORM_CONST;
    }
    return info * 4 + props;
}

// ShuffleVectorInst::isZeroEltSplat: every mask element 0 or poison, not all poison, one fixed-length source.
fn shuffle_is_zero_elt_splat_tti(u: i32) -> bool {
    let ii = inst_of(u);
    if ty_kind(vals[op(u, 0)].ty) == TK_SVEC { return false; }
    if insts[ii].naux as i64 != ty_count(vals[op(u, 0)].ty) { return false; }
    var any = false;
    for k in insts[ii].naux {
        let m = ints[insts[ii].aux + k];
        if m < 0 { continue; }
        if m != 0 { return false; }
        any = true;
    }
    return any;
}

// llvm::getSplatValue (VectorUtils): a constant's splat value, or the scalar of
// shufflevector (insertelement poison/undef, X, 0), poison, zeroinitializer.
fn tti_get_splat_value(v: i32) -> i32 {
    if is_constant(v) { return splat_value(v, false); }
    if is_inst_op(v, OP_SHUFFLEVECTOR) && shuffle_is_zero_mask_tti(v) {
        let ie = op(v, 0);
        if is_inst_op(ie, OP_INSERTELEMENT) {
            let ix = op(ie, 2);
            if vals[ix].kind == VK_CINT && ap_is_zero(ci_ap(ix)) { return op(ie, 1); }
        }
    }
    return -1;
}

// m_ZeroMask: every mask element 0 or poison
fn shuffle_is_zero_mask_tti(u: i32) -> bool {
    let ii = inst_of(u);
    for k in insts[ii].naux { let m = ints[insts[ii].aux + k]; if m != 0 && m != -1 { return false; } }
    return true;
}


// TargetTransformInfo::getInstructionCost(U, CostKind) for an instruction or a constant expression.
fn tti_instruction_cost(u: i32, kind: i64) -> i64 {
    let m = mk_mark();
    let im = ica_mark();
    let c = tti_instruction_cost_impl(u, kind);
    mk_release(m);
    ica_release(im);
    return c;
}

// isa<IntrinsicInst>: a call of a function whose name starts with "llvm." (Function::isIntrinsic), whether or not
// it is a known intrinsic
fn tti_is_intrinsic_inst(u: i32) -> bool {
    if !is_inst_op(u, OP_CALL) { return false; }
    let f = called_function(u);
    if f < 0 || vals[f].name < 0 { return false; }
    return starts_with(sbytes(vals[f].name), "llvm.");
}

fn tti_instruction_cost_impl(u: i32, kind: i64) -> i64 {
    let is_i = is_inst(u);
    if is_i && is_callbase(u) && !tti_is_intrinsic_inst(u) {
        let f = called_function(u);
        if f >= 0 {
            if !tti_is_lowered_to_call(f) { return TCC_BASIC; }
            return TCC_BASIC * (ty_fn_nparams(func_type(f)) + 1);
        }
        return TCC_BASIC * (cb_nargs(u) + 1);
    }
    let ty = vals[u].ty as i32;
    let o = opcode_of(u);
    let x86 = tti_kind == TTI_X86;
    if o == OP_CALL {
        if !x86 { return base_intrinsic_cost(inst_iid(u), ty); }
        let ic = ica_from_call(u, false);
        return x86_intrinsic_cost(ic, kind);
    }
    if o == OP_BR || o == OP_CONDBR || o == OP_RET || o == OP_PHI || o == OP_SWITCH { return tti_cf_cost(o, kind); }
    if o == OP_FREEZE { return TCC_FREE; }
    if o == OP_EXTRACTVALUE || o == OP_INSERTVALUE { return tti_insert_extract_value_cost(o, kind); }
    if o == OP_ALLOCA {
        if tti_is_static_alloca(u) { return TCC_FREE; }
        return TCC_BASIC;
    }
    if o == OP_GEP {
        var at: i32 = -1;
        if is_i {
            // GEP->hasOneUser(): all uses by one user
            let fu = vals[u].first_use;
            if fu >= 0 {
                let us = uses[fu].user;
                var one = true;
                var x = uses[fu].next;
                while x >= 0 { if uses[x].user != us { one = false; } x = uses[x].next; }
                if one { at = tti_access_type(us); }
            }
        }
        let src = if is_i { insts[inst_of(u)].ty2 } else { csts[vals[u].sub].ty2 };
        return tti_gep_cost(src, tti_opnd(u, 0), u, at, kind);
    }
    if is_binary_op(o) || o == OP_FNEG {
        let a0 = tti_opnd(u, 0);
        let a1 = if o == OP_FNEG { -1 } else { tti_opnd(u, 1) };
        if !x86 { return base_arith_cost(o, ty, kind, a0, a1); }
        let o1 = tti_operand_info(a0);
        let o2 = if o == OP_FNEG { 0 } else { tti_operand_info(a1) };
        return x86_arith_cost(o, ty, kind, o1, o2, a0, a1, if o == OP_FNEG { 1 } else { 2 }, if is_i { u } else { -1 });
    }
    if is_cast_op(o) || o == OP_PTRTOADDR {
        return tti_cast_cost_i(o, ty, vals[tti_opnd(u, 0)].ty, kind, if is_i { u } else { -1 });
    }
    if o == OP_STORE {
        let a = insts[inst_of(u)].align;
        let v = tti_opnd(u, 0);
        if !x86 { return 1; }
        return x86_memory_op_cost(o, vals[v].ty, if a == 0 { 1 } else { 1 << (a - 1) as i64 }, ptr_as(vals[op(u, 1)].ty), kind,
                                  tti_operand_info(v), u);
    }
    if o == OP_LOAD {
        var lt = ty;
        if kind == TCK_CODE_SIZE && !ty_is_vector(lt) {
            let fu = vals[u].first_use;
            if fu >= 0 && uses[fu].next < 0 && is_inst_op(uses[fu].user, OP_TRUNC) { lt = vals[uses[fu].user].ty; }
        }
        let a = insts[inst_of(u)].align;
        if !x86 { return 1; }
        return x86_memory_op_cost(o, lt, if a == 0 { 1 } else { 1 << (a - 1) as i64 }, ptr_as(vals[op(u, 0)].ty), kind, 0, u);
    }
    if o == OP_SELECT {
        if is_i && (m_logical(u, true) || m_logical(u, false)) {
            let isor = m_logical(u, false);
            let a = lg_a;
            let b = lg_b;
            if !x86 { return base_arith_cost(if isor { OP_OR } else { OP_AND }, ty, kind, a, b); }
            return x86_arith_cost(if isor { OP_OR } else { OP_AND }, ty, kind, tti_operand_info(a), tti_operand_info(b), a, b, 2, u);
        }
        if !x86 { return 1; }
        return x86_cmpsel_cost(o, ty, vals[tti_opnd(u, 0)].ty, PRED_BAD_ICMP, kind, tti_operand_info(tti_opnd(u, 1)),
                               tti_operand_info(tti_opnd(u, 2)), if is_i { u } else { -1 });
    }
    if o == OP_ICMP || o == OP_FCMP {
        if !x86 { return 1; }
        return x86_cmpsel_cost(o, vals[tti_opnd(u, 0)].ty, ty, if is_i { inst_pred(u) } else { PRED_BAD_ICMP }, kind,
                               tti_operand_info(tti_opnd(u, 0)), tti_operand_info(tti_opnd(u, 1)), if is_i { u } else { -1 });
    }
    if o == OP_INSERTELEMENT || o == OP_EXTRACTELEMENT {
        if !is_i { return TCC_BASIC; }
        return tti_vector_inst_cost(u, kind);
    }
    if o == OP_SHUFFLEVECTOR {
        if !is_i { return TCC_BASIC; }
        return tti_shuffle_inst_cost(u, kind);
    }
    return TCC_BASIC;
}

// getInstructionCost's ShuffleVector case
fn tti_shuffle_inst_cost(u: i32, kind: i64) -> i64 {
    let ii = inst_of(u);
    let n = insts[ii].naux as i64;
    let ms = mk_pool.len;
    for k in n { mk_pool.push(ints[insts[ii].aux + k as i32]); }
    var allneg = true;
    for k in n { if mk_at(ms, k) >= 0 { allneg = false; } }
    if allneg { return TCC_FREE; }
    let vecty = vals[u].ty as i32;
    let a0 = tti_opnd(u, 0);
    let a1 = tti_opnd(u, 1);
    let srcty = vals[a0].ty as i32;
    let x86 = tti_kind == TTI_X86;
    let scal = ty_kind(srcty) == TK_SVEC;
    let nsrc = ty_count(srcty);
    if n != nsrc {
        // changesLength
        if n > nsrc && !scal && sv_identity_impl(ms, n, nsrc) {
            var padded = true;
            for k in nsrc..n { if mk_at(ms, k) != -1 { padded = false; } }
            if padded { return TCC_FREE; }
        }
        if !scal {
            let ex, si = sv_is_extract_subvector(ms, n, nsrc);
            if ex {
                if !x86 { return 1; }
                return x86_shuffle_cost(SK_EXTRACTSUBVECTOR, vecty, srcty, ms, n, kind, si, vecty, a0, a1, 2, u);
            }
            let ins, nsub, ix = sv_is_insert_subvector(ms, n, nsrc);
            if ins {
                if !x86 { return 1; }
                return x86_shuffle_cost(SK_INSERTSUBVECTOR, vecty, srcty, ms, n, kind, ix, tt_vec(ty_scalar(vecty), nsub), a0, a1, 2, u);
            }
            // isReplicationMask (instance version): VF = source elements
            if n % nsrc == 0 {
                let rf = n / nsrc;
                if sv_replication_with_params(ms, n, rf, nsrc) {
                    if !x86 { return 1; }
                    let dd = mk_push_n(n, 0);
                    for k in n { if mk_at(ms, k) != -1 { mk_pool[dd + k] = 1; } }
                    return x86_replication_shuffle_cost(ty_elem(srcty), rf, nsrc, dd, kind);
                }
            }
        }
        let unary = is_undef_or_poison(a1);
        let nsub = nsrc;
        let adj = mk_copy(ms, n);
        if n > nsrc {
            for k in n {
                let mv = mk_at(adj, k);
                if mv >= nsub { mk_pool[adj + k] = (mv + (n - nsub)) as i32; }
            }
            if !x86 { return 1; }
            return x86_shuffle_cost(if unary { SK_PERMUTESINGLESRC } else { SK_PERMUTETWOSRC }, vecty, vecty, adj, n, kind, 0,
                                    -1, a0, a1, 2, u);
        }
        for k in nsub - n { mk_pool.push(-1); }
        if !x86 { return 2; }
        let sc = x86_shuffle_cost(if unary { SK_PERMUTESINGLESRC } else { SK_PERMUTETWOSRC }, srcty, srcty, adj, nsub, kind, 0,
                                  -1, a0, a1, 2, u);
        let em = mk_pool.len;
        for k in n { mk_pool.push(k as i32); }
        return tc_add(sc, x86_shuffle_cost(SK_EXTRACTSUBVECTOR, vecty, srcty, em, n, kind, 0, vecty, -1, -1, 0, u));
    }
    if scal { return if x86 { x86_np("getShuffleCost of scalable vectors") ; 0 } else { 1 }; }
    if sv_is_identity(ms, n, n) { return TCC_FREE; }
    var sk = SK_PERMUTETWOSRC;
    var index: i64 = 0;
    var subt: i32 = -1;
    let spl, spi = sv_is_splice(ms, n, n);
    let ins, nsub, ix = sv_is_insert_subvector(ms, n, nsrc);
    if sv_is_reverse(ms, n, n) { sk = SK_REVERSE; }
    else if sv_is_transpose(ms, n, n) { sk = SK_TRANSPOSE; }
    else if sv_is_zero_elt_splat(ms, n, n) { sk = SK_BROADCAST; }
    else if sv_is_single_source(ms, n, n) { sk = SK_PERMUTESINGLESRC; }
    else if ins { sk = SK_INSERTSUBVECTOR; index = ix; subt = tt_vec(ty_scalar(vecty), nsub); }
    else if sv_is_select(ms, n, n) { sk = SK_SELECT; }
    else if spl { sk = SK_SPLICE; index = spi; }
    if !x86 { return 1; }
    return x86_shuffle_cost(sk, vecty, srcty, ms, n, kind, index, subt, a0, a1, 2, u);
}

// ---------------------------------------------------------------- print<cost-model> (CostModel.cpp)

// -cost-kind: 0 throughput, 1 latency, 2 code-size, 3 size-latency, 4 all
fn cm_cost_kind() -> i64 {
    if !flag_given("cost-kind") { return 0; }
    let v = flag_str("cost-kind");
    if v == "throughput" { return 0; }
    if v == "latency" { return 1; }
    if v == "code-size" { return 2; }
    if v == "size-latency" { return 3; }
    if v == "all" { return 4; }
    fatal(str("opt: for the --cost-kind option: Cannot find option named '", v, "'!"));
    return 0;
}
// -intrinsic-cost-strategy: 0 instruction-cost, 1 intrinsic-cost, 2 type-based-intrinsic-cost
fn cm_intrinsic_strategy() -> i64 {
    if !flag_given("intrinsic-cost-strategy") { return 0; }
    let v = flag_str("intrinsic-cost-strategy");
    if v == "instruction-cost" { return 0; }
    if v == "intrinsic-cost" { return 1; }
    if v == "type-based-intrinsic-cost" { return 2; }
    fatal(str("opt: for the --intrinsic-cost-strategy option: Cannot find option named '", v, "'!"));
    return 0;
}

fn cm_get_cost(i: i32, kind: i64, strategy: i64) -> i64 {
    if strategy != 0 && tti_is_intrinsic_inst(i) {
        return tti_intrinsic_cost_strategy(i, kind, strategy == 2);
    }
    return tti_instruction_cost(i, kind);
}

fn cm_put_cost(c: i64) {
    if tc_valid(c) { errs_int(c); } else { errs("Invalid"); }
}

// CostModelPrinterPass::run
fn print_cost_model(fv: i32) {
    let ck = cm_cost_kind();
    let st = cm_intrinsic_strategy();
    tti_init_function(fv, globs[glob_of(fv)].module);
    errs("Printing analysis 'Cost Model Analysis' for function '");
    errs(val_name(fv));
    errs("':\n");
    each_inst(fv) { i =>
        errs("Cost Model: ");
        if ck == 4 {
            errs("Found costs of ");
            let rt = cm_get_cost(i, TCK_RECIP_THROUGHPUT, st);
            let cs = cm_get_cost(i, TCK_CODE_SIZE, st);
            let lat = cm_get_cost(i, TCK_LATENCY, st);
            let sl = cm_get_cost(i, TCK_SIZE_AND_LATENCY, st);
            if rt == cs && rt == lat && rt == sl {
                cm_put_cost(rt);
            } else {
                errs("RThru:"); cm_put_cost(rt);
                errs(" CodeSize:"); cm_put_cost(cs);
                errs(" Lat:"); cm_put_cost(lat);
                errs(" SizeLat:"); cm_put_cost(sl);
            }
            errs(" for: ");
            errs_inst(i, fv);
            errs("\n");
        } else {
            let k = if ck == 0 { TCK_RECIP_THROUGHPUT } else if ck == 1 { TCK_LATENCY } else if ck == 2 { TCK_CODE_SIZE } else { TCK_SIZE_AND_LATENCY };
            let c = cm_get_cost(i, k, st);
            if tc_valid(c) { errs("Found an estimated cost of "); errs_int(c); } else { errs("Invalid cost"); }
            errs(" for instruction: ");
            errs_inst(i, fv);
            errs("\n");
        }
    };
}
