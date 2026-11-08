// Pattern matching helpers: a port of the matchers of llvm/include/llvm/IR/PatternMatch.h that the
// analyses and InstSimplify use. Values are ids; a matcher is a predicate (bool) or returns the matched
// operand / constant id (-1 = no match).
//
// Integer constant values are APInts (ci_ap, any width). ci_val reads a constant as u64 and fails loudly
// (pm_wide) on a constant wider than 64 bits: use it only where LLVM itself takes getZExtValue().
import std;
import ir;
import irutil;
import instinfo;
import gen_iids;
import constfold;
import intrinsics;
import apfloat;
import fpu;
import apint;

fn pm_wide() { fatal("pattern match: an integer constant wider than 64 bits is not supported yet"); }

fn wmask64(w: i64) -> u64 { if w >= 64 { 0xFFFFFFFFFFFFFFFF } else { ((1 as u64) << w) - 1 } }
fn sbit64(w: i64) -> u64 { (1 as u64) << (w - 1) }
fn sext64(x: u64, w: i64) -> i64 { if w >= 64 { x as! i64 } else { ((x << (64 - w)) as! i64) >> (64 - w) } }

fn scalar_bits(v: i32) -> i64 { ty_bits(ty_scalar(vals[v].ty)) }
fn is_int_or_int_vec(t: i32) -> bool { ty_is_int(ty_scalar(t)) }
fn is_int_or_int_vec_w(t: i32, w: i64) -> bool { let s = ty_scalar(t); ty_is_int(s) && ty_bits(s) == w }
fn is_fp_or_fp_vec(t: i32) -> bool { ty_is_fp(ty_scalar(t)) }
fn is_ptr_or_ptr_vec(t: i32) -> bool { ty_kind(ty_scalar(t)) == TK_PTR }
fn is_fixed_vec(t: i32) -> bool { ty_kind(t) == TK_FVEC }
fn is_scalable_vec(t: i32) -> bool { ty_kind(t) == TK_SVEC }

// The value of an integer ConstantInt (scalar or vector-typed splat ConstantInt).
fn ci_val(c: i32) -> u64 {
    if ty_scalar_bits(vals[c].ty) > 64 { pm_wide(); }
    return cint_lo(c);
}
fn ci_w(c: i32) -> i64 { ty_scalar_bits(vals[c].ty) }
fn ci_sval(c: i32) -> i64 { sext64(ci_val(c), ci_w(c)) }

// The APInt of an integer ConstantInt (scalar or vector-typed splat ConstantInt), any width.
fn ci_ap(c: i32) -> AP { ap_from_cint(c) }
// ConstantInt::get(Ty, V): a scalar ConstantInt, or a splat of one for a vector type. x is zero-extended
// (c_int_ty_s: sign-extended) to the element width; c_int_ap takes an APInt of the element width.
fn c_int_ty(ty: i32, x: u64) -> i32 {
    let st = ty_scalar(ty);
    if ty_bits(st) > 64 { return ap_to_cint(ty, ap_u64(x, ty_bits(st))); }
    let e = c_int_words(st, x, 0);
    if ty_is_vector(ty) { return c_splat(ty, e); }
    return e;
}
fn c_int_ty_s(ty: i32, x: i64) -> i32 { ap_to_cint(ty, ap_i64(x, ty_bits(ty_scalar(ty)))) }
fn c_int_ap(ty: i32, a: AP) -> i32 { ap_to_cint(ty, a) }
fn c_bool_ty(ty: i32, b: bool) -> i32 { c_int_ty(ty, if b { 1 } else { 0 }) }
fn get_true(ty: i32) -> i32 { c_int_ty(ty, 1) }
fn get_false(ty: i32) -> i32 { c_int_ty(ty, 0) }
// CmpInst::makeCmpResultType
fn cmp_result_ty(t: i32) -> i32 {
    if ty_is_vector(t) { return ty_vector(T_I1, ty_count(t), ty_kind(t) == TK_SVEC); }
    return T_I1;
}

fn is_const(v: i32) -> bool { v >= 0 && is_constant(v) }
fn is_undef_val(v: i32) -> bool { v >= 0 && (vals[v].kind == VK_UNDEF || vals[v].kind == VK_POISON) }

// m_Undef: undef/poison, or a ConstantAggregate all of whose (recursively) elements are undef/poison.
recursive fn m_undef(v: i32) -> bool {
    let k = vals[v].kind;
    if k == VK_UNDEF || k == VK_POISON { return true; }
    if k == VK_CARRAY || k == VK_CSTRUCT || k == VK_CVECTOR {
        for i in nops(v) {
            let e = op(v, i);
            let ek = vals[e].kind;
            if ek == VK_CARRAY || ek == VK_CSTRUCT || ek == VK_CVECTOR {
                if !m_undef(e) { return false; }
            } else if ek != VK_UNDEF && ek != VK_POISON { return false; }
        }
        return true;
    }
    return false;
}

// Constant::getSplatValue(AllowPoison); -1 = not a splat. Handles vector-typed ConstantInt/FP.
fn splat_value(v: i32, allow_poison: bool) -> i32 {
    let ty = vals[v].ty;
    let k = vals[v].kind;
    if !ty_is_vector(ty) { return -1; }
    if k == VK_CINT { return c_int_words(ty_scalar(ty), cint_lo(v), cint_hi(v)); }
    if k == VK_CFP { return c_fp(ty_scalar(ty), cint_lo(v), cint_hi(v)); }
    if allow_poison && k == VK_CVECTOR {
        var s: i32 = -1;
        for i in nops(v) {
            let e = op(v, i);
            if vals[e].kind == VK_POISON { continue; }
            if s < 0 { s = e; } else if s != e { return -1; }
        }
        if s < 0 { return c_poison(ty_scalar(ty)); }
        return s;
    }
    return c_splat_value(v);
}

// Constant::getAggregateElement for vector-typed ConstantInt/FP as well.
fn agg_elem(v: i32, k: i64) -> i32 {
    let ty = vals[v].ty;
    let kind = vals[v].kind;
    if ty_is_vector(ty) && (kind == VK_CINT || kind == VK_CFP) {
        if ty_kind(ty) == TK_SVEC { return -1; }
        if k >= ty_count(ty) { return -1; }
        return splat_value(v, false);
    }
    return c_aggregate_element(v, k);
}

// m_APInt / m_APIntAllowPoison: the ConstantInt (scalar) of a ConstantInt or splat; -1 = none.
fn m_apint_ap(v: i32, allow_poison: bool) -> i32 {
    if v < 0 { return -1; }
    let k = vals[v].kind;
    if k == VK_CINT {
        if ty_is_vector(vals[v].ty) { return splat_value(v, false); }
        return v;
    }
    if ty_is_vector(vals[v].ty) && is_constant(v) {
        let s = splat_value(v, allow_poison);
        if s >= 0 && vals[s].kind == VK_CINT { return s; }
    }
    return -1;
}
fn m_apint(v: i32) -> i32 { m_apint_ap(v, false) }
// m_APFloat: the scalar ConstantFP; -1 = none
fn m_apfloat_ap(v: i32, allow_poison: bool) -> i32 {
    if v < 0 { return -1; }
    let k = vals[v].kind;
    if k == VK_CFP {
        if ty_is_vector(vals[v].ty) { return splat_value(v, false); }
        return v;
    }
    if ty_is_vector(vals[v].ty) && is_constant(v) {
        let s = splat_value(v, allow_poison);
        if s >= 0 && vals[s].kind == VK_CFP { return s; }
    }
    return -1;
}
fn m_apfloat(v: i32) -> i32 { m_apfloat_ap(v, false) }

// Integer predicates of cst_pred_ty.
let IP_ZERO = 0;
let IP_ONE = 1;
let IP_ALLONES = 2;
let IP_SIGNMASK = 3;
let IP_NEGATIVE = 4;
let IP_NONNEG = 5;
let IP_POWER2 = 6;
let IP_LOWBITMASK = 7;
let IP_STRICTLYPOS = 8;
let IP_NONPOS = 9;
let IP_POWER2_OR_ZERO = 10;
let IP_MAXSIGNED = 11;
let IP_NOT_MINSIGNED = 12;
let IP_NEG_POWER2 = 13;

fn int_pred(kind: i64, c: i32) -> bool {
    let x = ci_ap(c);
    if kind == IP_ZERO { return ap_is_zero(x); }
    if kind == IP_ONE { return ap_is_one(x); }
    if kind == IP_ALLONES { return ap_is_all_ones(x); }
    if kind == IP_SIGNMASK { return ap_is_min_signed(x); }
    if kind == IP_NEGATIVE { return ap_is_neg(x); }
    if kind == IP_NONNEG { return !ap_is_neg(x); }
    if kind == IP_POWER2 { return ap_is_pow2(x); }
    if kind == IP_POWER2_OR_ZERO { return ap_is_zero(x) || ap_is_pow2(x); }
    if kind == IP_LOWBITMASK { return ap_is_mask(x); }
    if kind == IP_STRICTLYPOS { return ap_is_strictly_pos(x); }
    if kind == IP_NONPOS { return !ap_is_strictly_pos(x); }
    if kind == IP_MAXSIGNED { return ap_is_max_signed(x); }
    if kind == IP_NOT_MINSIGNED { return !ap_is_min_signed(x); }
    if kind == IP_NEG_POWER2 { return ap_is_neg_pow2(x); }
    fatal("internal: unknown int predicate");
    return false;
}

// cst_pred_ty<P, AllowPoison>: scalar ConstantInt, splat, or fixed vector whose (non-poison) elements match.
fn m_cint_pred(v: i32, kind: i64, allow_poison: bool) -> bool {
    if v < 0 { return false; }
    let k = vals[v].kind;
    let ty = vals[v].ty;
    if k == VK_CINT { return int_pred(kind, if ty_is_vector(ty) { splat_value(v, false) } else { v }); }
    if !ty_is_vector(ty) || !is_constant(v) { return false; }
    let s = splat_value(v, false);
    if s >= 0 { if vals[s].kind == VK_CINT { return int_pred(kind, s); } }
    if ty_kind(ty) != TK_FVEC { return false; }
    let n = ty_count(ty);
    var has = false;
    for i in n {
        let e = agg_elem(v, i);
        if e < 0 { return false; }
        if allow_poison && vals[e].kind == VK_POISON { continue; }
        if vals[e].kind != VK_CINT || !int_pred(kind, e) { return false; }
        has = true;
    }
    return has;
}
fn m_zero_int(v: i32) -> bool { m_cint_pred(v, IP_ZERO, true) }
// m_Zero: null value or zero int (poison elements allowed)
fn m_zero(v: i32) -> bool { v >= 0 && is_constant(v) && (is_null_value(v) || m_cint_pred(v, IP_ZERO, true)) }
fn m_one(v: i32) -> bool { m_cint_pred(v, IP_ONE, true) }
fn m_all_ones(v: i32) -> bool { m_cint_pred(v, IP_ALLONES, true) }
fn m_all_ones_fp(v: i32) -> bool { m_cint_pred(v, IP_ALLONES, false) }
fn m_sign_mask(v: i32) -> bool { m_cint_pred(v, IP_SIGNMASK, true) }
fn m_negative(v: i32) -> bool { m_cint_pred(v, IP_NEGATIVE, true) }
fn m_nonneg(v: i32) -> bool { m_cint_pred(v, IP_NONNEG, true) }
fn m_power2(v: i32) -> bool { m_cint_pred(v, IP_POWER2, true) }
fn m_low_bit_mask(v: i32) -> bool { m_cint_pred(v, IP_LOWBITMASK, true) }
// m_ZeroOrPoison helper (masked load): zero or poison elements
fn m_zero_or_poison(v: i32) -> bool { v >= 0 && (vals[v].kind == VK_POISON || m_zero(v)) }

// m_SpecificInt(V): a scalar or splat (m_APInt semantics with poison allowed? no: specific_intval<false>)
fn m_specific_int(v: i32, x: u64) -> bool {
    let c = m_apint(v);
    if c < 0 {
        // specific_intval also matches non-splat fixed vectors? No: it uses getSplatValue(AllowPoison=false).
        return false;
    }
    // specific_intval64: CI->getValue() == Val (APInt == uint64_t: no truncation of Val)
    return ap_eq_u64(ci_ap(c), x);
}
// m_SpecificIntAllowPoison
fn m_specific_int_ap(v: i32, x: u64) -> bool {
    let c = m_apint_ap(v, true);
    if c < 0 { return false; }
    return ap_eq_u64(ci_ap(c), x);
}
// m_SpecificInt(const APInt &): specific_intval, APInt::isSameValue
fn m_specific_int_apv(v: i32, x: AP) -> bool {
    let c = m_apint(v);
    if c < 0 { return false; }
    return ap_same_value_u(ci_ap(c), x);
}

// m_ConstantInt (scalar ConstantInt only, vector-typed ConstantInt excluded) -> id
fn m_constant_int(v: i32) -> i32 { if v >= 0 && vals[v].kind == VK_CINT && !ty_is_vector(vals[v].ty) { v } else { -1 } }
// m_ConstantExpr: a ConstantExpr or a fixed vector constant with a ConstantExpr element
fn m_constant_expr(v: i32) -> bool {
    let k = vals[v].kind;
    if k == VK_CEXPR { return true; }
    if k == VK_CINT || k == VK_CFP { return false; }
    if ty_kind(vals[v].ty) == TK_FVEC && (k == VK_CVECTOR) {
        for i in nops(v) { if vals[op(v, i)].kind == VK_CEXPR { return true; } }
    }
    return false;
}
// m_ImmConstant (immconstant_ty): a constant that is not a constant expression, or a vector whose splat
// value (poison allowed) is not one.
fn m_imm_constant(v: i32) -> bool {
    if v < 0 || !is_constant(v) { return false; }
    if !m_constant_expr(v) { return true; }
    if ty_is_vector(vals[v].ty) {
        let s = splat_value(v, true);
        if s >= 0 && !m_constant_expr(s) { return true; }
    }
    return false;
}

// FP predicates
fn cfp_bits(c: i32) -> u64, u64 { return cint_lo(c), cint_hi(c); }
fn cfp_kind(c: i32) -> i64 { types[ty_scalar(vals[c].ty)].kind as i64 }
fn cfp_parts(c: i32) -> FpParts { fp_decompose(cfp_kind(c), cint_lo(c), cint_hi(c)) }

let FPP_POSZERO = 0;
let FPP_NEGZERO = 1;
let FPP_ANYZERO = 2;
let FPP_NAN = 3;
let FPP_INF = 4;
let FPP_ONE = 5;
let FPP_NONNAN = 6;
let FPP_FINITE = 7;
let FPP_NONZERO_NOT_DENORMAL = 8;
fn fp_pred(kind: i64, c: i32) -> bool {
    let p = cfp_parts(c);
    if kind == FPP_POSZERO { return p.cat == FC_ZERO && !p.neg; }
    if kind == FPP_NEGZERO { return p.cat == FC_ZERO && p.neg; }
    if kind == FPP_ANYZERO { return p.cat == FC_ZERO; }
    if kind == FPP_NAN { return p.cat == FC_NAN; }
    if kind == FPP_INF { return p.cat == FC_INF; }
    if kind == FPP_NONNAN { return p.cat != FC_NAN; }
    if kind == FPP_FINITE { return p.cat == FC_ZERO || p.cat == FC_NORMAL; }
    if kind == FPP_ONE { return fp_is_exactly(c, 1.0); }
    if kind == FPP_NONZERO_NOT_DENORMAL { return p.cat != FC_ZERO && !fp_is_denormal(c); }
    fatal("internal: unknown fp predicate");
    return false;
}
// is the FP constant exactly the double d?
fn fp_is_exactly(c: i32, d: f64) -> bool {
    let k = cfp_kind(c);
    let db = binary::bits_of_f64(d);
    let lo, hi = fp_convert(TK_DOUBLE, k, db, 0);
    // round-trip check: d must be representable; 1.0/2.0/10.0/-1.0 always are
    return lo == cint_lo(c) && hi == cint_hi(c);
}
// cstfp_pred_ty (poison elements allowed)
fn m_cfp_pred(v: i32, kind: i64) -> bool {
    if v < 0 { return false; }
    let k = vals[v].kind;
    let ty = vals[v].ty;
    if k == VK_CFP { return fp_pred(kind, if ty_is_vector(ty) { splat_value(v, false) } else { v }); }
    if !ty_is_vector(ty) || !is_constant(v) { return false; }
    let s = splat_value(v, false);
    if s >= 0 { if vals[s].kind == VK_CFP { return fp_pred(kind, s); } }
    if ty_kind(ty) != TK_FVEC { return false; }
    var has = false;
    for i in ty_count(ty) {
        let e = agg_elem(v, i);
        if e < 0 { return false; }
        if vals[e].kind == VK_POISON { continue; }
        if vals[e].kind != VK_CFP || !fp_pred(kind, e) { return false; }
        has = true;
    }
    return has;
}
fn m_pos_zero_fp(v: i32) -> bool { m_cfp_pred(v, FPP_POSZERO) }
fn m_neg_zero_fp(v: i32) -> bool { m_cfp_pred(v, FPP_NEGZERO) }
// m_FNeg(m_Value(X)): fneg X, or fsub -0.0, X (fsub nsz with any zero); X or -1
fn m_fneg(v: i32) -> i32 {
    if v < 0 || !is_inst(v) { return -1; }
    if iop(v) == OP_FNEG { return op(v, 0); }
    if iop(v) == OP_FSUB {
        let z = op(v, 0);
        if (inst_fmf(v) & FMF_NSZ) != 0 { if !m_any_zero_fp(z) { return -1; } }
        else if !m_neg_zero_fp(z) { return -1; }
        return op(v, 1);
    }
    return -1;
}
fn m_any_zero_fp(v: i32) -> bool { m_cfp_pred(v, FPP_ANYZERO) }
fn m_nan(v: i32) -> bool { m_cfp_pred(v, FPP_NAN) }
fn m_inf(v: i32) -> bool { m_cfp_pred(v, FPP_INF) }
// m_FPOne() = m_SpecificFP(1.0) (specific_fpval: a scalar, or a splat without poison elements)
fn m_fp_one(v: i32) -> bool { m_specific_fp(v, 1.0) }
// m_SpecificFP(d): m_APFloat-free comparison against a splat/scalar ConstantFP equal to d
fn m_specific_fp(v: i32, d: f64) -> bool {
    let c = m_apfloat(v);
    if c < 0 { return false; }
    return fp_is_exactly(c, d);
}

// ---------------------------------------------------------------------------------------------
// Operators (instruction or constant expression)

// BinaryOp_match / CastInst_match: opcode of an Instruction or ConstantExpr; -1 otherwise.
fn opcode_of(v: i32) -> i64 {
    if v < 0 { return -1; }
    let k = vals[v].kind;
    if k == VK_INST { return iop(v); }
    if k == VK_CEXPR { return csts[vals[v].sub].op as i64; }
    return -1;
}
fn is_op(v: i32, o: i64) -> bool { opcode_of(v) == o }
fn is_inst_op(v: i32, o: i64) -> bool { is_inst(v) && iop(v) == o }
// Poison-generating flags of an operator (instruction or constant expression)
fn op_flags(v: i32) -> u8 {
    let k = vals[v].kind;
    if k == VK_INST { return insts[inst_of(v)].flags; }
    if k == VK_CEXPR { return csts[vals[v].sub].flags; }
    return 0;
}
fn has_flag(v: i32, f: u8) -> bool { (op_flags(v) & f) != 0 }
fn op_nsw(v: i32) -> bool { has_flag(v, FL_NSW) }
fn op_nuw(v: i32) -> bool { has_flag(v, FL_NUW) }
fn op_exact(v: i32) -> bool { has_flag(v, FL_EXACT) }
fn op_disjoint(v: i32) -> bool { has_flag(v, FL_DISJOINT) }
fn inst_fmf(v: i32) -> u8 { if is_inst(v) { insts[inst_of(v)].fmf } else { 0 } }
fn inst_pred(v: i32) -> i64 { insts[inst_of(v)].pred as i64 }

// m_Not(X): xor X, -1 (m_c_Xor(m_AllOnes(), X)); returns X or -1.
// BinaryOp_match (m_Add, m_Sub, m_Xor, m_c_Xor, ...) matches BinaryOperator instructions only in LLVM 23,
// not ConstantExprs: use is_binop_match, not is_op, for those matchers.
fn is_binop_match(v: i32, o: i64) -> bool { is_inst_op(v, o) }
fn m_not(v: i32) -> i32 {
    if !is_binop_match(v, OP_XOR) { return -1; }
    if m_all_ones(op(v, 0)) { return op(v, 1); }
    if m_all_ones(op(v, 1)) { return op(v, 0); }
    return -1;
}
fn m_not_of(v: i32, x: i32) -> bool { m_not(v) == x && x >= 0 }
// m_Neg(X): sub 0, X (m_ZeroInt allowing poison); returns X or -1.
fn m_neg(v: i32) -> i32 { if is_binop_match(v, OP_SUB) && m_zero_int(op(v, 0)) { op(v, 1) } else { -1 } }
// m_c_BinOp(m_Specific(a), m_Value()) -> the other operand or -1
fn m_c_binop_with(v: i32, o: i64, a: i32) -> i32 {
    if !is_binop_match(v, o) { return -1; }
    if op(v, 0) == a { return op(v, 1); }
    if op(v, 1) == a { return op(v, 0); }
    return -1;
}
fn m_c_binop_both(v: i32, o: i64, a: i32, b: i32) -> bool {
    if !is_binop_match(v, o) { return false; }
    return (op(v, 0) == a && op(v, 1) == b) || (op(v, 0) == b && op(v, 1) == a);
}
// m_Intrinsic<ID>
fn m_intrinsic(v: i32, id: i32) -> bool { inst_iid(v) == id && id != 0 }
fn m_ptrtoint_or_addr(v: i32) -> i32 { if is_op(v, OP_PTRTOINT) || is_op(v, OP_PTRTOADDR) { op(v, 0) } else { -1 } }

// m_SMax/m_SMin/m_UMax/m_UMin: the min/max intrinsic (LLVM 23 matches intrinsics only). kind: 0 smax, 1 smin, 2 umax, 3 umin. Returns true with the operands in mm_a/mm_b.
var mm_a: i32 = -1;
var mm_b: i32 = -1;
fn minmax_iid(kind: i64) -> i32 { match kind { 0 => IID_smax, 1 => IID_smin, 2 => IID_umax, _ => IID_umin } }
fn m_minmax(v: i32, kind: i64) -> bool {
    if v < 0 { return false; }
    if m_intrinsic(v, minmax_iid(kind)) { mm_a = op(v, 0); mm_b = op(v, 1); return true; }
    return false;
}
fn pred_swap_i(p: i64) -> i64 {
    match p { 34 => 36, 35 => 37, 36 => 34, 37 => 35, 38 => 40, 39 => 41, 40 => 38, 41 => 39, _ => p }
}
// m_MaxOrMin: any of the four
fn m_max_or_min(v: i32) -> bool { m_minmax(v, 0) || m_minmax(v, 1) || m_minmax(v, 2) || m_minmax(v, 3) }

// m_LogicalAnd(L, R) / m_LogicalOr: and/or of i1 (or i1 vectors), or select c, x, false / select c, true, x.
// Returns true with operands in lg_a / lg_b.
var lg_a: i32 = -1;
var lg_b: i32 = -1;
fn m_logical(v: i32, is_and: bool) -> bool {
    if !is_inst(v) { return false; }
    if !is_int_or_int_vec_w(vals[v].ty, 1) { return false; }
    let o = iop(v);
    if o == (if is_and { OP_AND } else { OP_OR }) { lg_a = op(v, 0); lg_b = op(v, 1); return true; }
    if o == OP_SELECT {
        let c = op(v, 0);
        if vals[c].ty != vals[v].ty { return false; }
        let t = op(v, 1);
        let f = op(v, 2);
        if is_and {
            if is_constant(f) && is_null_value(f) { lg_a = c; lg_b = t; return true; }
        } else {
            if is_constant(t) && is_one_value(t) { lg_a = c; lg_b = f; return true; }
        }
    }
    return false;
}
// Constant::isOneValue
recursive fn is_one_value(v: i32) -> bool {
    let k = vals[v].kind;
    if k == VK_CINT { return cint_lo(v) == 1 && cint_hi(v) == 0 && ty_scalar_bits(vals[v].ty) <= 128; }
    if k == VK_CFP { return fp_is_exactly(if ty_is_vector(vals[v].ty) { splat_value(v, false) } else { v }, 1.0); }
    if ty_is_vector(vals[v].ty) {
        let s = splat_value(v, false);
        if s >= 0 { return is_one_value(s); }
    }
    return false;
}
// m_c_LogicalAnd(m_Specific(a), m_Specific(b))
fn m_c_logical_both(v: i32, is_and: bool, a: i32, b: i32) -> bool {
    if !m_logical(v, is_and) { return false; }
    return (lg_a == a && lg_b == b) || (lg_a == b && lg_b == a);
}
// m_c_LogicalOr(m_Specific(a), m_Value()) -> other or -1
fn m_c_logical_with(v: i32, is_and: bool, a: i32) -> i32 {
    if !m_logical(v, is_and) { return -1; }
    if lg_a == a { return lg_b; }
    if lg_b == a { return lg_a; }
    return -1;
}

// APFloat::isDenormal
fn fp_is_denormal(c: i32) -> bool {
    let p = cfp_parts(c);
    return p.cat == FC_NORMAL && p.expf == 0;
}
