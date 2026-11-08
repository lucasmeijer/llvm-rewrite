// TargetTransformInfo: the cost queries the scalar passes make. Ports
// llvm/include/llvm/Analysis/TargetTransformInfoImpl.h (TargetTransformInfoImplBase = NoTTIImpl, used by opt
// when the module has no target triple, and TargetTransformInfoImplCRTPBase::getInstructionCost) and
// llvm/lib/Analysis/TargetTransformInfo.cpp (getOperandInfo, getPredictableBranchThreshold).
// The x86 target (X86TTIImpl over BasicTTIImplBase) is selected by tti_init for x86 triples; its queries fail
// loudly until they are ported (see tti_x86_not_ported).
//
// Costs are InstructionCost values: an i64, with TTI_INVALID (and anything above it) as the invalid state,
// which compares greater than every valid cost exactly like InstructionCost::operator<.
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

let TCK_RECIP_THROUGHPUT = 0;
let TCK_LATENCY = 1;
let TCK_CODE_SIZE = 2;
let TCK_SIZE_AND_LATENCY = 3;

let TCC_FREE: i64 = 0;
let TCC_BASIC: i64 = 1;
let TCC_EXPENSIVE: i64 = 4;

let TTI_INVALID: i64 = 0x4000000000000000;

fn tc_valid(c: i64) -> bool { c < TTI_INVALID }
fn tc_add(a: i64, b: i64) -> i64 { if !tc_valid(a) || !tc_valid(b) { TTI_INVALID } else { a + b } }
fn tc_mul(a: i64, k: i64) -> i64 { if !tc_valid(a) { TTI_INVALID } else { a * k } }

// The target: 0 = none (NoTTIImpl), 1 = x86 (X86TTIImpl).
let TTI_NONE = 0;
let TTI_X86 = 1;
var tti_kind: i64 = 0;
var tti_module: i32 = -1;

// TargetIRAnalysis for the module: opt creates a TargetMachine from the module triple when the target is
// registered (an empty triple gives NoTTIImpl).
fn tti_init(m: i32) {
    tti_module = m;
    let t = modules[m].triple;
    if t < 0 || sbytes(t).len == 0 { tti_kind = TTI_NONE; return; }
    let s = sbytes(t);
    if starts_with(s, "x86_64") || starts_with(s, "i386") || starts_with(s, "i686") || starts_with(s, "i586") ||
       starts_with(s, "i486") || starts_with(s, "x86") {
        tti_kind = TTI_X86;
        return;
    }
    fatal(str("TargetTransformInfo for target triple '", s, "' is not supported"));
}

fn tti_x86_not_ported(what: const u8[:]) {
    fatal(str("TargetTransformInfo: the X86 cost model (", what, ") is not ported yet"));
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

fn tti_branch_mispredict_penalty() -> i64 {
    if tti_kind == TTI_X86 { tti_x86_not_ported("getBranchMispredictPenalty"); }
    return 0;
}

fn tti_is_profitable_to_hoist(i: i32) -> bool { true }

fn tti_has_conditional_load_store_for_type(t: i32, is_store: bool) -> bool {
    if tti_kind == TTI_X86 { tti_x86_not_ported("hasConditionalLoadStoreForType"); }
    return false;
}

fn tti_should_build_lookup_tables() -> bool {
    if tti_kind == TTI_X86 { tti_x86_not_ported("shouldBuildLookupTables"); }
    return true;
}
fn tti_should_build_lookup_tables_for_constant(c: i32) -> bool {
    if tti_kind == TTI_X86 { tti_x86_not_ported("shouldBuildLookupTablesForConstant"); }
    return true;
}
fn tti_should_build_rel_lookup_tables() -> bool {
    if tti_kind == TTI_X86 { tti_x86_not_ported("shouldBuildRelLookupTables"); }
    return false;
}
fn tti_is_type_legal(t: i32) -> bool {
    if tti_kind == TTI_X86 { tti_x86_not_ported("isTypeLegal"); }
    return false;
}
fn tti_minimum_lookup_table_entry_bits() -> i64 {
    if tti_kind == TTI_X86 { tti_x86_not_ported("getMinimumLookupTableEntryBitWidth"); }
    return 8;
}
fn tti_reg_usage_for_type(t: i32) -> i64 {
    if tti_kind == TTI_X86 { tti_x86_not_ported("getRegUsageForType"); }
    return 1;
}

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

// OperandValueInfo: kind (0 AnyValue, 1 UniformValue, 2 UniformConstantValue, 3 NonUniformConstantValue)
// and properties (0 None, 1 PowerOf2, 2 NegatedPowerOf2). Only the NoTTI model ignores them; kept for x86.
let OK_ANY = 0;
let OK_UNIFORM = 1;
let OK_UNIFORM_CONST = 2;
let OK_NONUNIFORM_CONST = 3;

// getArithmeticInstrCost (TargetTransformInfoImplBase)
fn tti_arith_cost(o: i64, ty: i32, kind: i64, args: const i32[:]) -> i64 {
    if tti_kind == TTI_X86 { tti_x86_not_ported("getArithmeticInstrCost"); }
    if o == OP_FDIV || o == OP_FREM || o == OP_SDIV || o == OP_SREM || o == OP_UDIV || o == OP_UREM { return TCC_EXPENSIVE; }
    if o == OP_AND || o == OP_OR {
        for a in args { if a >= 0 && inst_iid(a) == IID_experimental_widenable_condition { return TCC_FREE; } }
    }
    if kind == TCK_LATENCY && ty_is_fp(ty_scalar(ty)) { return 3; }
    return 1;
}

// getCastInstrCost (TargetTransformInfoImplBase)
fn tti_cast_cost(o: i64, dst: i32, src: i32, kind: i64) -> i64 {
    if tti_kind == TTI_X86 { tti_x86_not_ported("getCastInstrCost"); }
    if o == OP_INTTOPTR {
        let s = ty_bits(ty_scalar(src));
        if dl_is_legal_integer(s) && s <= dl_size_bits(ty_scalar(dst)) { return 0; }
    } else if o == OP_PTRTOADDR {
        if dl_is_legal_integer(ty_bits(ty_scalar(dst))) { return 0; }
    } else if o == OP_PTRTOINT {
        let d = ty_bits(ty_scalar(dst));
        if dl_is_legal_integer(d) && d >= dl_size_bits(ty_scalar(src)) { return 0; }
    } else if o == OP_BITCAST {
        if dst == src || (ty_kind(dst) == TK_PTR && ty_kind(src) == TK_PTR) { return 0; }
    } else if o == OP_TRUNC {
        if ty_kind(dst) != TK_SVEC && dl_is_legal_integer(dl_size_bits(dst)) { return 0; }
    }
    return 1;
}

fn tti_cf_cost(o: i64, kind: i64) -> i64 {
    if tti_kind == TTI_X86 { tti_x86_not_ported("getCFInstrCost"); }
    if o == OP_PHI && kind != TCK_RECIP_THROUGHPUT { return 0; }
    return 1;
}

// getCmpSelInstrCost(Opcode, ValTy, CondTy, VecPred, CostKind, ...)
fn tti_cmpsel_cost(o: i64, valty: i32, condty: i32, pred: i64, kind: i64) -> i64 {
    if tti_kind == TTI_X86 { tti_x86_not_ported("getCmpSelInstrCost"); }
    return 1;
}

fn tti_memory_op_cost(o: i64, ty: i32, align: i64, as_: i64, kind: i64) -> i64 {
    if tti_kind == TTI_X86 { tti_x86_not_ported("getMemoryOpCost"); }
    return 1;
}

fn tti_vector_inst_cost(i: i32, kind: i64) -> i64 {
    if tti_kind == TTI_X86 { tti_x86_not_ported("getVectorInstrCost"); }
    return 1;
}

fn tti_shuffle_cost(i: i32, kind: i64) -> i64 {
    if tti_kind == TTI_X86 { tti_x86_not_ported("getShuffleCost"); }
    return 1;
}

fn tti_insert_extract_value_cost(o: i64, kind: i64) -> i64 {
    if tti_kind == TTI_X86 { tti_x86_not_ported("getInsertExtractValueCost"); }
    if o == OP_INSERTVALUE && kind != TCK_RECIP_THROUGHPUT { return TCC_BASIC; }
    return TCC_FREE;
}

// getIntrinsicInstrCost (TargetTransformInfoImplBase) for an intrinsic call
fn tti_intrinsic_cost(c: i32, id: i32, kind: i64) -> i64 {
    if tti_kind == TTI_X86 { tti_x86_not_ported("getIntrinsicInstrCost"); }
    let zero: const i32[] = [IID_allow_runtime_check, IID_allow_ubsan_check, IID_annotation, IID_assume,
        IID_sideeffect, IID_pseudoprobe, IID_arithmetic_fence, IID_dbg_assign, IID_dbg_declare, IID_dbg_value,
        IID_dbg_label, IID_invariant_start, IID_invariant_end, IID_launder_invariant_group,
        IID_strip_invariant_group, IID_is_constant, IID_lifetime_start, IID_lifetime_end,
        IID_experimental_noalias_scope_decl, IID_objectsize, IID_ptr_annotation, IID_var_annotation,
        IID_experimental_gc_result, IID_experimental_gc_relocate, IID_coro_alloc, IID_coro_begin,
        IID_coro_begin_custom_abi, IID_coro_dead, IID_coro_id, IID_coro_id_async, IID_coro_id_retcon,
        IID_coro_id_retcon_once, IID_coro_noop, IID_coro_free, IID_coro_end, IID_coro_frame, IID_coro_size,
        IID_coro_align, IID_coro_suspend, IID_coro_subfn_addr, IID_threadlocal_address,
        IID_experimental_widenable_condition, IID_ssa_copy];
    for z in zero { if z == id { return 0; } }
    if id == IID_bswap {
        let rt = vals[c].ty;
        if !ty_is_vector(rt) {
            let b = dl_size_bits(rt);
            if b <= 0 || (b & (b - 1)) != 0 { return TTI_INVALID; }
        }
    }
    return 1;
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
    if tti_kind == TTI_X86 { tti_x86_not_ported("isLegalAddressingMode"); }
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
        let ix = op(g, k + 1);
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

// Value::stripPointerCasts
fn strip_pointer_casts_tti(v0: i32) -> i32 {
    var v = v0;
    loop {
        let o = opcode_of(v);
        if o == OP_BITCAST || o == OP_ADDRSPACECAST { v = op(v, 0); continue; }
        if o == OP_GEP {
            var allz = true;
            for k in 1..nops(v) { let x = op(v, k); if !(is_constant(x) && is_null_value(x)) { allz = false; } }
            if allz { v = op(v, 0); continue; }
        }
        if vals[v].kind == VK_ALIAS { return v; }
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

// TargetTransformInfo::getInstructionCost(U, CostKind) for an instruction or a constant expression.
fn tti_instruction_cost(u: i32, kind: i64) -> i64 {
    let is_i = is_inst(u);
    if is_i && is_callbase(u) && inst_iid(u) == 0 {
        if tti_kind == TTI_X86 { tti_x86_not_ported("getInstructionCost of calls"); }
        let f = called_function(u);
        if f >= 0 {
            if !tti_is_lowered_to_call(f) { return TCC_BASIC; }
            return TCC_BASIC * (ty_fn_nparams(func_type(f)) + 1);
        }
        return TCC_BASIC * (cb_nargs(u) + 1);
    }
    let ty = vals[u].ty;
    let o = opcode_of(u);
    if o == OP_CALL {
        return tti_intrinsic_cost(u, inst_iid(u), kind);
    }
    if o == OP_BR || o == OP_CONDBR || o == OP_RET || o == OP_PHI || o == OP_SWITCH { return tti_cf_cost(o, kind); }
    if o == OP_FREEZE { return TCC_FREE; }
    if o == OP_EXTRACTVALUE || o == OP_INSERTVALUE { return tti_insert_extract_value_cost(o, kind); }
    if o == OP_ALLOCA {
        if tti_is_static_alloca(u) { return TCC_FREE; }
        return TCC_BASIC;
    }
    if o == OP_GEP {
        if tti_kind == TTI_X86 { tti_x86_not_ported("getGEPCost"); }
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
        return tti_gep_cost(src, op(u, 0), u, at, kind);
    }
    if is_binary_op(o) || o == OP_FNEG {
        if o == OP_FNEG { return tti_arith_cost(o, ty, kind, [op(u, 0)]); }
        return tti_arith_cost(o, ty, kind, [op(u, 0), op(u, 1)]);
    }
    if is_cast_op(o) || o == OP_PTRTOADDR {
        return tti_cast_cost(o, ty, vals[op(u, 0)].ty, kind);
    }
    if o == OP_STORE {
        let a = insts[inst_of(u)].align;
        return tti_memory_op_cost(o, vals[op(u, 0)].ty, if a == 0 { 1 } else { 1 << (a - 1) as i64 }, ptr_as(vals[op(u, 1)].ty), kind);
    }
    if o == OP_LOAD {
        var lt = ty;
        if kind == TCK_CODE_SIZE && !ty_is_vector(lt) {
            let fu = vals[u].first_use;
            if fu >= 0 && uses[fu].next < 0 && is_inst_op(uses[fu].user, OP_TRUNC) { lt = vals[uses[fu].user].ty; }
        }
        let a = insts[inst_of(u)].align;
        return tti_memory_op_cost(o, lt, if a == 0 { 1 } else { 1 << (a - 1) as i64 }, ptr_as(vals[op(u, 0)].ty), kind);
    }
    if o == OP_SELECT {
        if is_i && (m_logical(u, true) || m_logical(u, false)) {
            let isor = m_logical(u, false);
            let a = lg_a;
            let b = lg_b;
            return tti_arith_cost(if isor { OP_OR } else { OP_AND }, ty, kind, [a, b]);
        }
        return tti_cmpsel_cost(o, ty, vals[op(u, 0)].ty, -1, kind);
    }
    if o == OP_ICMP || o == OP_FCMP {
        return tti_cmpsel_cost(o, vals[op(u, 0)].ty, ty, if is_i { inst_pred(u) } else { -1 }, kind);
    }
    if o == OP_INSERTELEMENT || o == OP_EXTRACTELEMENT {
        if !is_i { return TCC_BASIC; }
        return tti_vector_inst_cost(u, kind);
    }
    if o == OP_SHUFFLEVECTOR {
        if !is_i { return TCC_BASIC; }
        // all-poison masks are free
        let ii = inst_of(u);
        var allneg = true;
        for k in insts[ii].naux { if ints[insts[ii].aux + k] >= 0 { allneg = false; } }
        if allneg { return TCC_FREE; }
        if tti_kind == TTI_X86 { tti_x86_not_ported("getShuffleCost"); }
        // NoTTI: every shuffle kind costs 1, except the free identity / identity-with-padding cases
        if shuffle_is_free_identity(u) { return TCC_FREE; }
        if insts[ii].naux as i64 < ty_count(vals[op(u, 0)].ty) {
            fatal("TargetTransformInfo: the cost of a length-reducing shufflevector is not ported yet");
        }
        return 1;
    }
    return TCC_BASIC;
}

// ShuffleVectorInst: changesLength && increasesLength && isIdentityWithPadding, or !changesLength && isIdentity
fn shuffle_is_free_identity(u: i32) -> bool {
    let ii = inst_of(u);
    let n = insts[ii].naux;
    let src_n = ty_count(vals[op(u, 0)].ty);
    let mk = insts[ii].aux;
    if ty_kind(vals[op(u, 0)].ty) == TK_SVEC { return false; }
    if n as i64 == src_n {
        // isIdentity: single source, every element i or poison selecting lane i of one operand
        var use0 = true;
        var use1 = true;
        for k in n {
            let m = ints[mk + k] as i64;
            if m < 0 { continue; }
            if m != k as i64 { use0 = false; }
            if m != k as i64 + src_n { use1 = false; }
        }
        return use0 || use1;
    }
    if (n as i64) > src_n {
        // isIdentityWithPadding: the first src_n lanes are an identity of one source, the rest poison
        var use0 = true;
        var use1 = true;
        for k in n {
            let m = ints[mk + k] as i64;
            if (k as i64) >= src_n { if m >= 0 { return false; } continue; }
            if m < 0 { continue; }
            if m != k as i64 { use0 = false; }
            if m != k as i64 + src_n { use1 = false; }
        }
        return use0 || use1;
    }
    return false;
}
