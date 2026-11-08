// InstCombine for fneg, fadd, fsub: port of llvm/lib/Transforms/InstCombine/InstCombineAddSub.cpp (FAddendCoef,
// FAddend, FAddCombine, foldSquareSumFP, factorizeLerp, factorizeFAddFSub, visitFAdd, foldFNegIntoConstant,
// hoistFNegAboveFMulFDiv, visitFNeg, visitFSub) and foldFBinOpOfIntCasts / foldFBinOpOfIntCastsFromSign from
// llvm/lib/Transforms/InstCombine/InstructionCombining.cpp.
namespace ic;
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import constfold;
import cfold;
import pm;
import vt;
import poison;
import knownbits;
import fpclass;
import overflow;
import instsimplify;
import apint;
import apfloat;
import fpu;
import ic;
import ic_builder;
import ic_common;

// ---------------------------------------------------------------------------------------------
// Fast-math flag helpers (FastMathFlags, FPMathOperator)

let FMF_VALUE_MASK: u8 = 14;      // nnan | ninf | nsz
let FMF_REWRITE_MASK: u8 = 113;   // reassoc | arcp | contract | afn
fn fmf_of(v: i32) -> u8 { inst_fmf(v) }
fn has_fmf(v: i32, f: u8) -> bool { (inst_fmf(v) & f) == f }
fn has_reassoc(v: i32) -> bool { has_fmf(v, FMF_REASSOC) }
fn has_nsz(v: i32) -> bool { has_fmf(v, FMF_NSZ) }
fn has_nnan(v: i32) -> bool { has_fmf(v, FMF_NNAN) }
fn has_ninf(v: i32) -> bool { has_fmf(v, FMF_NINF) }
fn has_arcp(v: i32) -> bool { has_fmf(v, FMF_ARCP) }
fn has_contract(v: i32) -> bool { has_fmf(v, FMF_CONTRACT) }
fn is_fast(v: i32) -> bool { has_fmf(v, FMF_FAST) }
fn set_fmf(v: i32, f: u8) { insts[inst_of(v)].fmf = f; }
fn set_fmf_bit(v: i32, bit: u8, on: bool) {
    let ii = inst_of(v);
    if on { insts[ii].fmf |= bit; } else { insts[ii].fmf &= ~bit; }
}
// FastMathFlags::unionValue / intersectRewrite
fn fmf_union_value(a: u8, b: u8) -> u8 { FMF_VALUE_MASK & (a | b) }
fn fmf_intersect_rewrite(a: u8, b: u8) -> u8 { FMF_REWRITE_MASK & a & b }

// m_FAdd / m_FSub / m_FMul / m_FDiv (instructions only)
fn is_fadd(v: i32) -> bool { is_inst_op(v, OP_FADD) }
fn is_fsub(v: i32) -> bool { is_inst_op(v, OP_FSUB) }
fn is_fmul(v: i32) -> bool { is_inst_op(v, OP_FMUL) }
fn is_fdiv(v: i32) -> bool { is_inst_op(v, OP_FDIV) }
// m_Intrinsic<ID>(...): a call to the intrinsic
fn is_intr(v: i32, id: i32) -> bool { v >= 0 && inst_iid(v) == id }
// m_AllowReassoc(P)
fn allow_reassoc(v: i32) -> bool { is_inst(v) && is_fp_math_operator(v) && has_reassoc(v) }

// ConstantFP::get(Ty, double), getInfinity, getZero, getQNaN (splat for vectors)
fn c_fpd(ty: i32, d: f64) -> i32 { c_fp_from_f64(ty, d) }
fn c_fp_inf_ty(ty: i32, neg: bool) -> i32 { let lo, hi = fp_encode(fp_kind_ty(ty), neg, 0, 0, 0, true); return c_fp_bits_ty(ty, lo, hi); }
fn c_fp_zero_ty(ty: i32, neg: bool) -> i32 { let lo, hi = fp_encode(fp_kind_ty(ty), neg, 0, 0, 0, false); return c_fp_bits_ty(ty, lo, hi); }
fn c_fp_qnan_ty(ty: i32) -> i32 { c_fp_nan_ty(ty) }

// Constant::isNormalFP / isFiniteNonZeroFP / hasExactInverseFP
let CFPP_NORMAL = 0;
let CFPP_FINITE_NONZERO = 1;
let CFPP_EXACT_INVERSE = 2;
fn cfp_elem_pred(c: i32, kind: i64) -> bool {
    let p = cfp_parts(c);
    if kind == CFPP_NORMAL { return p.cat == FC_NORMAL && p.expf != 0; }
    if kind == CFPP_FINITE_NONZERO { return p.cat == FC_NORMAL; }
    // APFloat::getExactInverse: a normal power of two whose reciprocal is a normal number
    if p.cat != FC_NORMAL || p.expf == 0 { return false; }
    if !(p.sig1 == 0 && (p.sig0 & (p.sig0 - 1)) == 0) && !(p.sig0 == 0 && (p.sig1 & (p.sig1 - 1)) == 0) { return false; }
    let f = fp_fmt(cfp_kind(c));
    let e = -p.exponent;
    return e >= 1 - f.bias && e <= f.bias;
}
fn c_fp_pred_all(c: i32, kind: i64) -> bool {
    if c < 0 || !is_constant(c) { return false; }
    let ty = vals[c].ty;
    if vals[c].kind == VK_CFP {
        if ty_is_vector(ty) { let s = splat_value(c, false); return s >= 0 && cfp_elem_pred(s, kind); }
        return cfp_elem_pred(c, kind);
    }
    if ty_kind(ty) == TK_FVEC {
        for k in ty_count(ty) {
            let e = agg_elem(c, k);
            if e < 0 || vals[e].kind != VK_CFP || !cfp_elem_pred(e, kind) { return false; }
        }
        return true;
    }
    if ty_is_vector(ty) {
        let s = c_splat_value(c);
        if s >= 0 && vals[s].kind == VK_CFP { return cfp_elem_pred(s, kind); }
    }
    return false;
}
fn c_is_normal_fp(c: i32) -> bool { c_fp_pred_all(c, CFPP_NORMAL) }
fn c_is_finite_non_zero_fp(c: i32) -> bool { c_fp_pred_all(c, CFPP_FINITE_NONZERO) }
fn c_has_exact_inverse_fp(c: i32) -> bool { c_fp_pred_all(c, CFPP_EXACT_INVERSE) }

// ConstantFoldUnaryOpOperand(FNeg, C) / ConstantFoldBinaryOpOperands(Opc, A, B)
fn cf_fneg(c: i32) -> i32 { cf_fold_unary(OP_FNEG, c) }

// Copy a value's name into a buffer with a suffix (Y->getName() + ".neg")
fn name_plus(v: i32, sfx: const u8[:]) -> u8[>..] {
    var nm: u8[>..] = [];
    nm.append(val_name(v));
    nm.append(sfx);
    return nm;
}

// ---------------------------------------------------------------------------------------------
// FAddendCoef / FAddend / FAddCombine

// A coefficient: a small integer, or an APFloat (bit pattern of the FP kind fk).
struct FCoef { is_fp: bool, iv: i64, fk: i64, lo: u64, hi: u64 }
struct FAddend { v: i32, c: FCoef }

fn fc_int(n: i64) -> FCoef { FCoef { is_fp: false, iv: n, fk: 0, lo: 0, hi: 0 } }
fn fc_fp(c: i32) -> FCoef { FCoef { is_fp: true, iv: 0, fk: cfp_kind(c), lo: cint_lo(c), hi: cint_hi(c) } }
fn fa_none() -> FAddend { FAddend { v: -1, c: fc_int(0) } }
fn fc_is_zero(c: FCoef) -> bool {
    if !c.is_fp { return c.iv == 0; }
    return fp_decompose(c.fk, c.lo, c.hi).cat == FC_ZERO;
}
fn fc_is_one(c: FCoef) -> bool { !c.is_fp && c.iv == 1 }
fn fc_is_two(c: FCoef) -> bool { !c.is_fp && c.iv == 2 }
fn fc_is_minus_one(c: FCoef) -> bool { !c.is_fp && c.iv == -1 }
fn fc_is_minus_two(c: FCoef) -> bool { !c.is_fp && c.iv == -2 }
// createAPFloatFromInt(Sem, Val)
fn fc_int_bits(fk: i64, n: i64) -> u64, u64 {
    if n >= 0 { let lo, hi = fp_from_f64(fk, n as f64); return lo, hi; }
    let lo, hi = fp_from_f64(fk, (0 - n) as f64);
    let nlo, nhi = fp_neg_bits(fk, lo, hi);
    return nlo, nhi;
}
// convertToFpType(Sem)
fn fc_to_fp(c: FCoef, fk: i64) -> FCoef {
    if c.is_fp { return c; }
    let lo, hi = fc_int_bits(fk, c.iv);
    return FCoef { is_fp: true, iv: 0, fk: fk, lo: lo, hi: hi };
}
fn fc_negate(c: FCoef) -> FCoef {
    if !c.is_fp { return fc_int(0 - c.iv); }
    let lo, hi = fp_neg_bits(c.fk, c.lo, c.hi);
    return FCoef { is_fp: true, iv: 0, fk: c.fk, lo: lo, hi: hi };
}
// operator+=
fn fc_add(a: FCoef, b: FCoef) -> FCoef {
    if a.is_fp == b.is_fp {
        if !a.is_fp { return fc_int(a.iv + b.iv); }
        let lo, hi = fp_arith(a.fk, FOP_ADD, a.lo, a.hi, b.lo, b.hi);
        return FCoef { is_fp: true, iv: 0, fk: a.fk, lo: lo, hi: hi };
    }
    if !a.is_fp {
        let x = fc_to_fp(a, b.fk);
        let lo, hi = fp_arith(b.fk, FOP_ADD, x.lo, x.hi, b.lo, b.hi);
        return FCoef { is_fp: true, iv: 0, fk: b.fk, lo: lo, hi: hi };
    }
    let blo, bhi = fc_int_bits(a.fk, b.iv);
    let lo, hi = fp_arith(a.fk, FOP_ADD, a.lo, a.hi, blo, bhi);
    return FCoef { is_fp: true, iv: 0, fk: a.fk, lo: lo, hi: hi };
}
// operator*=
fn fc_mul(a: FCoef, b: FCoef) -> FCoef {
    if fc_is_one(b) { return a; }
    if fc_is_minus_one(b) { return fc_negate(a); }
    if !a.is_fp && !b.is_fp { return fc_int(a.iv * b.iv); }
    let fk = if a.is_fp { a.fk } else { b.fk };
    let x = fc_to_fp(a, fk);
    var blo = b.lo; var bhi = b.hi;
    if !b.is_fp { let l, h = fc_int_bits(fk, b.iv); blo = l; bhi = h; }
    let lo, hi = fp_arith(fk, FOP_MUL, x.lo, x.hi, blo, bhi);
    return FCoef { is_fp: true, iv: 0, fk: fk, lo: lo, hi: hi };
}
// getValue(Ty)
fn fc_value(c: FCoef, ty: i32) -> i32 {
    if !c.is_fp { return c_fpd(ty, c.iv as f64); }
    return c_fp(ty, c.lo, c.hi);
}

// FAddend::drillValueDownOneStep(Val, Addend0, Addend1): number of addends, the two addends
fn fa_drill_value(v: i32) -> i64, FAddend, FAddend {
    var a0 = fa_none();
    var a1 = fa_none();
    if v < 0 || !is_inst(v) { return 0, a0, a1; }
    let o = iop(v);
    if o == OP_FADD || o == OP_FSUB {
        var op0 = op(v, 0);
        var op1 = op(v, 1);
        let c0 = if vals[op0].kind == VK_CFP { op0 } else { -1 };
        let c1 = if vals[op1].kind == VK_CFP { op1 } else { -1 };
        if c0 >= 0 && cfp_parts(c0).cat == FC_ZERO { op0 = -1; }
        if c1 >= 0 && cfp_parts(c1).cat == FC_ZERO { op1 = -1; }
        if op0 >= 0 {
            if c0 < 0 { a0 = FAddend { v: op0, c: fc_int(1) }; } else { a0 = FAddend { v: -1, c: fc_fp(c0) }; }
        }
        if op1 >= 0 {
            var a = if c1 < 0 { FAddend { v: op1, c: fc_int(1) } } else { FAddend { v: -1, c: fc_fp(c1) } };
            if o == OP_FSUB { a.c = fc_negate(a.c); }
            if op0 >= 0 { a1 = a; } else { a0 = a; }
        }
        if op0 >= 0 || op1 >= 0 { return if op0 >= 0 && op1 >= 0 { 2 } else { 1 }, a0, a1; }
        // both operands are zero
        let lo, hi = fp_encode(cfp_kind(c0), false, 0, 0, 0, false);
        a0 = FAddend { v: -1, c: FCoef { is_fp: true, iv: 0, fk: cfp_kind(c0), lo: lo, hi: hi } };
        return 1, a0, a1;
    }
    if o == OP_FMUL {
        let v0 = op(v, 0);
        let v1 = op(v, 1);
        if vals[v0].kind == VK_CFP { a0 = FAddend { v: v1, c: fc_fp(v0) }; return 1, a0, a1; }
        if vals[v1].kind == VK_CFP { a0 = FAddend { v: v0, c: fc_fp(v1) }; return 1, a0, a1; }
    }
    return 0, a0, a1;
}
// FAddend::drillAddendDownOneStep
fn fa_drill_addend(a: FAddend) -> i64, FAddend, FAddend {
    if a.v < 0 { return 0, fa_none(), fa_none(); }
    let n, b0, b1 = fa_drill_value(a.v);
    if n == 0 || fc_is_one(a.c) { return n, b0, b1; }
    var x0 = b0;
    var x1 = b1;
    x0.c = fc_mul(x0.c, a.c);
    if n == 2 { x1.c = fc_mul(x1.c, a.c); }
    return n, x0, x1;
}

var fac_instr: i32 = -1;
var fac_ads: FAddend[>..<];       // addends of one simplifyFAdd call (Addends)
var fac_simp: FAddend[>..<];      // SimpVect (copies)

// FAddCombine::createInstPostProc
fn fac_post(v: i32) {
    if !is_inst(v) { return; }
    let d = inst_get_md(fac_instr, 0);
    if d >= 0 { inst_set_md(v, 0, d); }
    set_fmf(v, fmf_of(fac_instr));
}
fn fac_create(o: i64, a: i32, b: i32) -> i32 {
    let v = icb_fbinop_fmf(o, a, b, icb_fmf, "");
    fac_post(v);
    return v;
}
// createAddendVal: value, NeedNeg
fn fac_addend_val(a: FAddend) -> i32, bool {
    let ty = vals[fac_instr].ty;
    if a.v < 0 { return fc_value(a.c, ty), false; }
    if fc_is_minus_one(a.c) || fc_is_one(a.c) { return a.v, fc_is_minus_one(a.c); }
    if fc_is_two(a.c) || fc_is_minus_two(a.c) { return fac_create(OP_FADD, a.v, a.v), fc_is_minus_two(a.c); }
    return fac_create(OP_FMUL, a.v, fc_value(a.c, ty)), false;
}
// calcInstrNumber over fac_simp
fn fac_calc_instr_number() -> i64 {
    var n = fac_simp.len - 1;
    for a in fac_simp {
        if a.v < 0 { continue; }
        if is_undef_or_poison(a.v) { continue; }
        if !fc_is_minus_one(a.c) && !fc_is_one(a.c) { n++; }
    }
    return n;
}
// createNaryFAdd(fac_simp, InstrQuota)
fn fac_create_nary(quota: i64) -> i32 {
    if fac_calc_instr_number() > quota { return -1; }
    var last: i32 = -1;
    var last_neg = false;
    for k in fac_simp.len {
        let a = fac_simp[k];
        let v, neg = fac_addend_val(a);
        if last < 0 { last = v; last_neg = neg; continue; }
        if last_neg == neg { last = fac_create(OP_FADD, last, v); continue; }
        if last_neg { last = fac_create(OP_FSUB, v, last); } else { last = fac_create(OP_FSUB, last, v); }
        last_neg = false;
    }
    if last_neg {
        last = icb_fneg_fmf(last, icb_fmf, "");
        fac_post(last);
    }
    return last;
}
// simplifyFAdd(fac_ads, InstrQuota)
fn fac_simplify_fadd(quota: i64) -> i32 {
    let n = fac_ads.len;
    var dead: bool[>..<] = [];
    for k in n { dead.push(false); }
    fac_simp.resize(0);
    for si in n {
        if dead[si] { continue; }
        let val = fac_ads[si].v;
        let start = fac_simp.len;
        fac_simp.push(fac_ads[si]);
        for sj in (si + 1)..n {
            if !dead[sj] && fac_ads[sj].v == val {
                dead[sj] = true;
                fac_simp.push(fac_ads[sj]);
            }
        }
        if start + 1 != fac_simp.len {
            var r = fac_simp[start];
            for idx in (start + 1)..fac_simp.len { r.c = fc_add(r.c, fac_simp[idx].c); }
            fac_simp.resize(start);
            if !fc_is_zero(r.c) { fac_simp.push(r); }
        }
    }
    if fac_simp.len > 0 { return fac_create_nary(quota); }
    return c_fpd(vals[fac_instr].ty, 0.0);
}
// FAddCombine::simplify(I)
fn fadd_combine_simplify(i: i32) -> i32 {
    if ty_is_vector(vals[i].ty) { return -1; }
    fac_instr = i;
    let num, o0a, o1a = fa_drill_value(i);
    var e0: i64 = 0;
    var e1: i64 = 0;
    var o00 = fa_none(); var o01 = fa_none(); var o10 = fa_none(); var o11 = fa_none();
    if o0a.v >= 0 { let n0, x0, x1 = fa_drill_addend(o0a); e0 = n0; o00 = x0; o01 = x1; }
    if num == 2 && o1a.v >= 0 { let n1, y0, y1 = fa_drill_addend(o1a); e1 = n1; o10 = y0; o11 = y1; }
    if e0 != 0 && e1 != 0 {
        fac_ads.resize(0);
        fac_ads.push(o00);
        fac_ads.push(o10);
        if e0 == 2 { fac_ads.push(o01); }
        if e1 == 2 { fac_ads.push(o11); }
        let v0 = op(i, 0);
        let v1 = op(i, 1);
        let quota = if (!is_constant(v0) && one_use(v0)) && (!is_constant(v1) && one_use(v1)) { 2 } else { 1 };
        let r = fac_simplify_fadd(quota);
        if r >= 0 { return r; }
    }
    if num != 2 { return if fc_is_one(o0a.c) { o0a.v } else { -1 }; }
    if e1 != 0 {
        fac_ads.resize(0);
        fac_ads.push(o0a);
        fac_ads.push(o10);
        if e1 == 2 { fac_ads.push(o11); }
        let r = fac_simplify_fadd(1);
        if r >= 0 { return r; }
    }
    if e0 != 0 {
        fac_ads.resize(0);
        fac_ads.push(o1a);
        fac_ads.push(o00);
        if e0 == 2 { fac_ads.push(o01); }
        let r = fac_simplify_fadd(1);
        if r >= 0 { return r; }
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// foldSquareSumFP (matchesSquareSum<FP=true> with m_SpecificFP(2.0))

fn is_fmul2_of(v: i32, a: i32) -> bool { is_fmul(v) && op(v, 0) == a && m_specific_fp(op(v, 1), 2.0) }
fn is_sq_of(v: i32, a: i32) -> bool { is_fmul(v) && op(v, 0) == a && op(v, 1) == a }
// m_OneUse(m_c_BinOp(FMul, m_c_BinOp(FAdd, m_BinOp(FMul, m_Deferred(A), 2.0), m_Value(B)), m_Deferred(B))): B or -1
fn mss_p2(v: i32, a: i32) -> i32 {
    if !(one_use(v) && is_fmul(v)) { return -1; }
    for j in 2 {
        let ad = op(v, j);
        if !is_fadd(ad) { continue; }
        var b: i32 = -1;
        if is_fmul2_of(op(ad, 0), a) { b = op(ad, 1); } else if is_fmul2_of(op(ad, 1), a) { b = op(ad, 0); }
        if b >= 0 && op(v, 1 - j) == b { return b; }
    }
    return -1;
}
// m_CombineOr(m_OneUse(m_BinOp(FMul, m_BinOp(FMul, A, B), 2.0)), m_OneUse(m_c_BinOp(FMul, m_BinOp(FMul, A, 2.0), B)))
fn mss_q1(v: i32) -> i32, i32 {
    if one_use(v) && is_fmul(v) && is_fmul(op(v, 0)) && m_specific_fp(op(v, 1), 2.0) { return op(op(v, 0), 0), op(op(v, 0), 1); }
    if one_use(v) && is_fmul(v) {
        for j in 2 {
            let m2 = op(v, j);
            if is_fmul(m2) && m_specific_fp(op(m2, 1), 2.0) { return op(m2, 0), op(v, 1 - j); }
        }
    }
    return -1, -1;
}
fn mss_q2(v: i32, a: i32, b: i32) -> bool {
    if !(one_use(v) && is_fadd(v)) { return false; }
    return (is_sq_of(op(v, 0), a) && is_sq_of(op(v, 1), b)) || (is_sq_of(op(v, 1), a) && is_sq_of(op(v, 0), b));
}
fn matches_square_sum_fp(i: i32) -> bool, i32, i32 {
    // (a * a) + (((a * 2) + b) * b)
    for k in 2 {
        let sq = op(i, k);
        if !(one_use(sq) && is_fmul(sq) && op(sq, 0) == op(sq, 1)) { continue; }
        let a = op(sq, 0);
        let b = mss_p2(op(i, 1 - k), a);
        if b >= 0 { return true, a, b; }
    }
    // ((a * b) * 2) or ((a * 2) * b)  +  (a * a + b * b) or (b * b + a * a)
    for k in 2 {
        let a, b = mss_q1(op(i, k));
        if a < 0 { continue; }
        if mss_q2(op(i, 1 - k), a, b) { return true, a, b; }
    }
    return false, -1, -1;
}
fn fold_square_sum_fp(i: i32) -> i32 {
    let ok, a, b = matches_square_sum_fp(i);
    if !ok { return -1; }
    let ab = icb_fbinop_fmf(OP_FADD, a, b, fmf_of(i), "");
    return ic_new_fbinop_fmf(OP_FMUL, ab, ab, fmf_of(i));
}

// ---------------------------------------------------------------------------------------------
// factorizeLerp / factorizeFAddFSub

fn factorize_lerp(i: i32) -> i32 {
    // m_c_FAdd(m_OneUse(m_c_FMul(m_Value(Y), m_OneUse(m_FSub(m_FPOne(), m_Value(Z))))), m_OneUse(m_c_FMul(m_Value(X), m_Deferred(Z))))
    if !is_fadd(i) { return -1; }
    for k in 2 {
        let m1 = op(i, k);
        let m2 = op(i, 1 - k);
        if !(one_use(m1) && is_fmul(m1)) { continue; }
        var y: i32 = -1;
        var z: i32 = -1;
        for j in 2 {
            let s = op(m1, 1 - j);
            if one_use(s) && is_fsub(s) && m_fp_one(op(s, 0)) { y = op(m1, j); z = op(s, 1); break; }
        }
        if y < 0 { continue; }
        if !(one_use(m2) && is_fmul(m2)) { continue; }
        var x: i32 = -1;
        if op(m2, 1) == z { x = op(m2, 0); } else if op(m2, 0) == z { x = op(m2, 1); }
        if x < 0 { continue; }
        let xy = icb_fbinop_fmf(OP_FSUB, x, y, fmf_of(i), "");
        let mz = icb_fbinop_fmf(OP_FMUL, z, xy, fmf_of(i), "");
        return ic_new_fbinop_fmf(OP_FADD, y, mz, fmf_of(i));
    }
    return -1;
}
fn factorize_fadd_fsub(i: i32) -> i32 {
    let l = factorize_lerp(i);
    if l >= 0 { return l; }
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    if !has_one_use(op0) || !has_one_use(op1) { return -1; }
    var x: i32 = -1; var y: i32 = -1; var z: i32 = -1;
    var is_fmul_k = false;
    var found = false;
    if is_fmul(op0) && is_fmul(op1) {
        // (X * Z) op (Y * Z) with Z = op0's operand 1, then operand 0
        for k in 2 {
            let zz = op(op0, 1 - k);
            if op(op1, 1) == zz { x = op(op0, k); z = zz; y = op(op1, 0); found = true; break; }
            if op(op1, 0) == zz { x = op(op0, k); z = zz; y = op(op1, 1); found = true; break; }
        }
        is_fmul_k = true;
    }
    if !found && is_fdiv(op0) && is_fdiv(op1) && op(op1, 1) == op(op0, 1) {
        x = op(op0, 0); z = op(op0, 1); y = op(op1, 0); found = true; is_fmul_k = false;
    }
    if !found { return -1; }
    let xy = if iop(i) == OP_FADD { icb_fbinop_fmf(OP_FADD, x, y, fmf_of(i), "") } else { icb_fbinop_fmf(OP_FSUB, x, y, fmf_of(i), "") };
    let c = m_apfloat(xy);
    if c >= 0 && !(cfp_parts(c).cat == FC_NORMAL && cfp_parts(c).expf != 0) { return -1; }
    return if is_fmul_k { ic_new_fbinop_fmf(OP_FMUL, xy, z, fmf_of(i)) } else { ic_new_fbinop_fmf(OP_FDIV, xy, z, fmf_of(i)) };
}

// ---------------------------------------------------------------------------------------------
// foldFBinOpOfIntCasts (InstructionCombining.cpp)

// m_IToFP: uitofp / sitofp instruction; the source or -1
fn m_itofp(v: i32) -> i32 { if is_inst_op(v, OP_UITOFP) || is_inst_op(v, OP_SITOFP) { op(v, 0) } else { -1 } }

fn fbo_kb(v: i32) -> KB { kb_cxt = -1; return kb_compute_all(v, 0); }

fn fold_fbinop_of_int_casts_from_sign(bo: i32, signed: bool, ops0: i32, ops1_0: i32, op1fpc: i32) -> i32 {
    let fpty = vals[bo].ty;
    let intty = vals[ops0].ty;
    let isz = ty_scalar_bits(intty);
    let maxbits = fp_fmt(fp_kind_ty(fpty)).p;
    var used0 = isz;
    var used1 = isz;
    var ops1 = ops1_0;
    if op1fpc >= 0 {
        if signed && iop(bo) == OP_FMUL && !m_cfp_pred(op1fpc, FPP_NONZERO) { return -1; }
        let ic = cf_fold_cast_operand(if signed { OP_FPTOSI } else { OP_FPTOUI }, op1fpc, intty);
        if ic < 0 { return -1; }
        if cf_fold_cast_operand(if signed { OP_SITOFP } else { OP_UITOFP }, ic, fpty) != op1fpc { return -1; }
        ops1 = ic;
    }
    if intty != vals[ops1].ty { return -1; }
    // IsValidPromotion(OpNo)
    for kk in 2 {
        let k = 1 - kk;
        if k == 1 && op1fpc >= 0 { continue; }
        let iop_v = if k == 0 { ops0 } else { ops1 };
        let src = op(bo, k);
        if signed != is_inst_op(src, OP_SITOFP) && !kb_is_nonneg(fbo_kb(iop_v)) { return -1; }
        var used = isz;
        if maxbits < isz {
            if signed {
                kb_cxt = if is_inst(iop_v) { iop_v } else { -1 };
                used = isz - num_sign_bits(iop_v, 0);
            } else {
                used = isz - kb_min_lz(fbo_kb(iop_v));
            }
        }
        if k == 0 { used0 = used; } else { used1 = used; }
        if maxbits < used { return -1; }
        if signed && iop(bo) == OP_FMUL {
            // IsNonZero(OpNo)
            let kb = fbo_kb(iop_v);
            if !kb_is_nonzero(kb) {
                kb_cxt = -1;
                if !is_known_non_zero(iop_v, 0) { return -1; }
            }
        }
    }
    var intopc: i64 = OP_ADD;
    var out_bits: i64 = if signed { 2 } else { 1 };
    let cur_bits = max(used0, used1);
    var out_signed = signed;
    let o = iop(bo);
    if o == OP_FADD { intopc = OP_ADD; out_bits += cur_bits; }
    else if o == OP_FSUB { intopc = OP_SUB; out_bits += cur_bits; }
    else { intopc = OP_MUL; out_bits += cur_bits * 2; }
    var need_check = true;
    if out_bits < isz {
        need_check = false;
        if intopc == OP_SUB { out_signed = true; }
    }
    if need_check && !will_not_overflow(intopc, ops0, ops1, bo, out_signed) { return -1; }
    let ib = icb_binop(intopc, ops0, ops1, "");
    if is_binop_inst(ib) { set_nsw(ib, out_signed); set_nuw(ib, !out_signed); }
    return ic_new_cast(if out_signed { OP_SITOFP } else { OP_UITOFP }, ib, fpty);
}
fn fold_fbinop_of_int_casts(bo: i32) -> i32 {
    if ty_is_vector(vals[bo].ty) { return -1; }
    let i0 = m_itofp(op(bo, 0));
    if i0 < 0 { return -1; }
    var c: i32 = -1;
    var i1: i32 = -1;
    if is_constant(op(bo, 1)) { c = op(bo, 1); }
    else { i1 = m_itofp(op(bo, 1)); if i1 < 0 { return -1; } }
    let r = fold_fbinop_of_int_casts_from_sign(bo, false, i0, i1, c);
    if r >= 0 { return r; }
    return fold_fbinop_of_int_casts_from_sign(bo, true, i0, i1, c);
}

// ---------------------------------------------------------------------------------------------
// visitFAdd

fn visit_fadd(i: i32) -> i32 {
    let v0 = simplify_fadd(op(i, 0), op(i, 1), fmf_of(i), sq_at(i), RECURSION_LIMIT, EB_IGNORE, RM_NEAREST);
    if v0 >= 0 { return ic_replace_inst_uses_with(i, v0); }
    if simplify_assoc_or_comm(i) { return i; }
    let xv = fold_vector_binop(i);
    if xv >= 0 { return xv; }
    let ph = fold_binop_with_phi_operands(i);
    if ph >= 0 { return ph; }
    let fs = fold_binop_into_select_or_phi(i);
    if fs >= 0 { return fs; }
    // B = fadd A, 0.0 ; Z = Op B  -->  Z = Op A  (Op ignores the sign of zero)
    if one_use(i) && m_any_zero_fp(op(i, 1)) && can_ignore_sign_bit_of_zero(vals[i].first_use) {
        return ic_replace_inst_uses_with(i, op(i, 0));
    }
    // (-X) + Y --> Y - X
    for k in 2 {
        let x = m_fneg(op(i, k));
        if x >= 0 { return ic_new_fbinop_fmf(OP_FSUB, op(i, 1 - k), x, fmf_of(i)); }
    }
    // (-X * Y) + Z --> Z - (X * Y)
    for k in 2 {
        let m = op(i, k);
        if !(one_use(m) && is_fmul(m)) { continue; }
        for j in 2 {
            let x = m_fneg(op(m, j));
            if x >= 0 {
                let xy = icb_fbinop_fmf(OP_FMUL, x, op(m, 1 - j), fmf_of(i), "");
                return ic_new_fbinop_fmf(OP_FSUB, op(i, 1 - k), xy, fmf_of(i));
            }
        }
    }
    // (-X / Y) + Z --> Z - (X / Y) ; (X / -Y) + Z --> Z - (X / Y)
    for pass in 2 {
        for k in 2 {
            let d = op(i, k);
            if !(one_use(d) && is_fdiv(d)) { continue; }
            var x: i32 = -1; var y: i32 = -1;
            if pass == 0 { let nx = m_fneg(op(d, 0)); if nx >= 0 { x = nx; y = op(d, 1); } }
            else { let ny = m_fneg(op(d, 1)); if ny >= 0 { x = op(d, 0); y = ny; } }
            if x < 0 { continue; }
            let xy = icb_fbinop_fmf(OP_FDIV, x, y, fmf_of(i), "");
            return ic_new_fbinop_fmf(OP_FSUB, op(i, 1 - k), xy, fmf_of(i));
        }
    }
    let r0 = fold_fbinop_of_int_casts(i);
    if r0 >= 0 { return r0; }
    let lhs = op(i, 0);
    let rhs = op(i, 1);
    let sv = simplify_selects_feeding_binop(i, lhs, rhs);
    if sv >= 0 { return ic_replace_inst_uses_with(i, sv); }
    if has_reassoc(i) && has_nsz(i) {
        let f = factorize_fadd_fsub(i);
        if f >= 0 { return f; }
        let sq = fold_square_sum_fp(i);
        if sq >= 0 { return sq; }
        // fadd (rdx 0.0, X), Y --> rdx Y, X
        for k in 2 {
            let rd = op(i, k);
            if one_use(rd) && is_intr(rd, IID_vector_reduce_fadd) && m_any_zero_fp(op(rd, 0)) {
                let x = op(rd, 1);
                let y = op(i, 1 - k);
                return ic_replace_inst_uses_with(i, icb_intrinsic_fmf(IID_vector_reduce_fadd, [vals[x].ty as i32], [y, x], fmf_of(i), ""));
            }
        }
        // fadd (rdx StartC, X), C --> rdx (C + StartC), X
        if one_use(lhs) && is_intr(lhs, IID_vector_reduce_fadd) && m_apfloat(op(lhs, 0)) >= 0 && m_apfloat(rhs) >= 0 {
            let sc = m_apfloat(op(lhs, 0));
            let c = m_apfloat(rhs);
            let x = op(lhs, 1);
            let lo, hi = fp_arith(cfp_kind(c), FOP_ADD, cint_lo(c), cint_hi(c), cint_lo(sc), cint_hi(sc));
            let nsc = c_fp_bits_ty(vals[i].ty, lo, hi);
            return ic_replace_inst_uses_with(i, icb_intrinsic_fmf(IID_vector_reduce_fadd, [vals[x].ty as i32], [nsc, x], fmf_of(i), ""));
        }
        // (X * MulC) + X --> X * (MulC + 1.0)
        for k in 2 {
            let m = op(i, k);
            if is_fmul(m) && is_imm_c(op(m, 1)) && op(i, 1 - k) == op(m, 0) {
                let x = op(m, 0);
                let nc = cf_fold_binop_operands(OP_FADD, op(m, 1), c_fpd(vals[i].ty, 1.0));
                if nc >= 0 { return ic_new_fbinop_fmf(OP_FMUL, x, nc, fmf_of(i)); }
                break;
            }
        }
        // (-X - Y) + (X + Z) --> Z - Y
        for k in 2 {
            let s = op(i, k);
            let a = op(i, 1 - k);
            if !is_fsub(s) { continue; }
            let x = m_fneg(op(s, 0));
            if x < 0 { continue; }
            let y = op(s, 1);
            if !is_fadd(a) { continue; }
            var z: i32 = -1;
            if op(a, 0) == x { z = op(a, 1); } else if op(a, 1) == x { z = op(a, 0); }
            if z >= 0 { return ic_new_fbinop_fmf(OP_FSUB, z, y, fmf_of(i)); }
        }
        let fc = fadd_combine_simplify(i);
        if fc >= 0 { return ic_replace_inst_uses_with(i, fc); }
    }
    // minimum(X, Y) + maximum(X, Y) => X + Y
    for k in 2 {
        let mx = op(i, k);
        let mn = op(i, 1 - k);
        if !is_intr(mx, IID_maximum) { continue; }
        let x = op(mx, 0); let y = op(mx, 1);
        if is_intr(mn, IID_minimum) && ((op(mn, 0) == x && op(mn, 1) == y) || (op(mn, 0) == y && op(mn, 1) == x)) {
            let r = ic_new_fbinop_fmf(OP_FADD, x, y, fmf_of(i));
            if !has_nnan(r) { set_fmf_bit(r, FMF_NINF, false); }
            return r;
        }
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// fneg

// foldFNegIntoConstant(I)
fn fold_fneg_into_constant(i: i32) -> i32 {
    let fo = m_fneg(i);
    if fo < 0 || !one_use(fo) || !is_inst(fo) { return -1; }
    // -(X * C) --> X * (-C)
    if is_fmul(fo) && is_constant(op(fo, 1)) {
        let nc = cf_fneg(op(fo, 1));
        if nc >= 0 {
            let f1 = fmf_of(i);
            let f2 = fmf_of(fo);
            var fmf = fmf_union_value(f1, f2) | fmf_intersect_rewrite(f1, f2);
            if (f1 & FMF_NINF) != 0 && (f2 & FMF_NINF) != 0 { fmf |= FMF_NINF; } else { fmf &= ~FMF_NINF; }
            return ic_new_fbinop_fmf(OP_FMUL, op(fo, 0), nc, fmf);
        }
    }
    // -(X / C) --> X / (-C) ; -(C / X) --> (-C) / X
    for k in 2 {
        let ck = 1 - k;
        if !(is_fdiv(fo) && is_constant(op(fo, ck))) { continue; }
        let nc = cf_fneg(op(fo, ck));
        if nc < 0 { continue; }
        let d = if ck == 1 { ic_new_fbinop_fmf(OP_FDIV, op(fo, 0), nc, fmf_of(i)) } else { ic_new_fbinop_fmf(OP_FDIV, nc, op(fo, 1), fmf_of(i)) };
        set_fmf_bit(d, FMF_NSZ, has_nsz(i) && has_nsz(fo));
        set_fmf_bit(d, FMF_NINF, has_ninf(i) && has_ninf(fo));
        ic_copy_all_md(d, fo);
        return d;
    }
    // -(X + C) --> -C - X (nsz)
    if has_nsz(i) && is_fadd(fo) && is_constant(op(fo, 1)) {
        let nc = cf_fneg(op(fo, 1));
        if nc >= 0 { return ic_new_fbinop_fmf(OP_FSUB, nc, op(fo, 0), fmf_of(i)); }
    }
    return -1;
}

// hoistFNegAboveFMulFDiv(FNegOp, FMFSource)
fn hoist_fneg_above_fmul_fdiv(fo: i32, src: i32) -> i32 {
    let f = fmf_of(src);
    if is_fmul(fo) {
        let ny = icb_fneg_fmf(op(fo, 1), f, "");
        return icb_fbinop_fmf(OP_FMUL, op(fo, 0), ny, f, "");
    }
    if is_fdiv(fo) {
        let nx = icb_fneg_fmf(op(fo, 0), f, "");
        let d = icb_fbinop_fmf(OP_FDIV, nx, op(fo, 1), f, "");
        ic_copy_all_md(d, fo);
        return d;
    }
    if is_intr(fo, IID_ldexp) {
        let fm = f | fmf_of(fo);
        let na = icb_fneg_fmf(op(fo, 0), fm, "");
        let c = ic_new_intrinsic(IID_ldexp, [vals[op(fo, 0)].ty as i32, vals[op(fo, 1)].ty], [na, op(fo, 1)]);
        icb_insert(c, "");
        set_fmf(c, fmf_of(c) | fm);
        ic_copy_all_md(c, fo);
        return c;
    }
    return -1;
}

fn visit_fneg(i: i32) -> i32 {
    let o = op(i, 0);
    let v0 = simplify_fneg(o, fmf_of(i), sq_at(i));
    if v0 >= 0 { return ic_replace_inst_uses_with(i, v0); }
    let fc = fold_fneg_into_constant(i);
    if fc >= 0 { return fc; }
    // -(X - Y) --> (Y - X) (nsz)
    if has_nsz(i) && one_use(o) && is_fsub(o) { return ic_new_fbinop_fmf(OP_FSUB, op(o, 1), op(o, 0), fmf_of(i)); }
    if !one_use(o) { return -1; }
    let h = hoist_fneg_above_fmul_fdiv(o, i);
    if h >= 0 { return ic_replace_inst_uses_with(i, h); }
    if is_select_inst(o) {
        let cond = op(o, 0);
        let x = op(o, 1);
        let y = op(o, 2);
        // -(Cond ? -P : Y) --> Cond ? P : -Y
        let p0 = m_fneg(x);
        if p0 >= 0 {
            let nm = name_plus(y, ".neg");
            let ny = icb_fneg_fmf(y, fmf_of(i), nm);
            let s = ic_new_select(cond, p0, ny);
            fneg_propagate_select_fmf(s, i, o, p0 == y);
            return s;
        }
        // -(Cond ? X : -P) --> Cond ? -X : P
        let p1 = m_fneg(y);
        if p1 >= 0 {
            let nm = name_plus(x, ".neg");
            let nx = icb_fneg_fmf(x, fmf_of(i), nm);
            let s = ic_new_select(cond, nx, p1);
            fneg_propagate_select_fmf(s, i, o, p1 == x);
            return s;
        }
        // -(Cond ? X : C) --> Cond ? -X : -C ; -(Cond ? C : Y) --> Cond ? -C : -Y
        if is_imm_c(x) || is_imm_c(y) {
            let nmx = name_plus(x, ".neg");
            let nx = icb_fneg_fmf(x, fmf_of(i), nmx);
            let nmy = name_plus(y, ".neg");
            let ny = icb_fneg_fmf(y, fmf_of(i), nmy);
            let s = ic_new_select(cond, nx, ny);
            fneg_propagate_select_fmf(s, i, o, true);
            return s;
        }
    }
    // fneg (copysign x, y) -> copysign x, (fneg y)
    if is_intr(o, IID_copysign) {
        let fmf = fmf_of(i) & fmf_of(o);
        let ny = icb_fneg_fmf(op(o, 1), fmf, "");
        let cs = icb_binary_intrinsic_fmf(IID_copysign, op(o, 0), ny, fmf, "");
        return ic_replace_inst_uses_with(i, cs);
    }
    // fneg (shuffle x, Mask) --> shuffle (fneg x), Mask
    if is_inst_op(o, OP_SHUFFLEVECTOR) && vals[op(o, 1)].kind == VK_POISON {
        let nx = icb_fneg_fmf(op(o, 0), fmf_of(i), "");
        var mask: i32[>..<] = [];
        let oi = inst_of(o);
        for k in insts[oi].naux { mask.push(ints[insts[oi].aux + k]); }
        return icc_new_shuffle(nx, mask);
    }
    // fneg (reverse x) --> reverse (fneg x)
    if is_intr(o, IID_vector_reverse) {
        let nx = icb_fneg_fmf(op(o, 0), fmf_of(i), "");
        return ic_replace_inst_uses_with(i, icb_vector_reverse(nx));
    }
    return -1;
}

// propagateSelectFMF(S, CommonOperand) of visitFNeg
fn fneg_propagate_select_fmf(s: i32, i: i32, old: i32, common: bool) {
    set_fmf(s, fmf_of(i));
    if is_select_inst(old) {
        set_fmf(s, fmf_of(i) | fmf_of(old));
        if !has_nsz(old) && !common {
            if !is_guaranteed_not_to_be_undef_or_poison(op(old, 0), -1, 0) { set_fmf_bit(s, FMF_NSZ, false); }
        }
    }
}

// IRBuilder::CreateVectorReverse(V)
fn icb_vector_reverse(v: i32) -> i32 {
    let ty = vals[v].ty;
    if ty_kind(ty) == TK_SVEC { return icb_intrinsic(IID_vector_reverse, [ty as i32], [v], ""); }
    let n = ty_count(ty);
    var mask: i32[>..<] = [];
    for k in n { mask.push((n - 1 - k) as i32); }
    if is_constant(v) {
        ic_not_ported("CreateVectorReverse of a constant (FoldShuffleVector)");
    }
    return icb_insert(icc_new_shuffle(v, mask), "");
}

// ---------------------------------------------------------------------------------------------
// visitFSub

fn visit_fsub(i: i32) -> i32 {
    let v0 = simplify_fsub(op(i, 0), op(i, 1), fmf_of(i), sq_at(i), RECURSION_LIMIT, EB_IGNORE, RM_NEAREST);
    if v0 >= 0 { return ic_replace_inst_uses_with(i, v0); }
    let xv = fold_vector_binop(i);
    if xv >= 0 { return xv; }
    let ph = fold_binop_with_phi_operands(i);
    if ph >= 0 { return ph; }
    // fsub -0.0, X ==> fneg X
    let fn0 = m_fneg(i);
    if fn0 >= 0 { return ic_new_fneg_fmf(fn0, fmf_of(i)); }
    let fc = fold_fneg_into_constant(i);
    if fc >= 0 { return fc; }
    let r0 = fold_fbinop_of_int_casts(i);
    if r0 >= 0 { return r0; }
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    let ty = vals[i].ty;
    // Z - (X - Y) --> Z + (Y - X)
    var nz = has_nsz(i);
    if !nz { kb_cxt = i; nz = cannot_be_negative_zero(op0, 0); }
    if nz {
        if one_use(op1) && is_fsub(op1) {
            let ns = icb_fbinop_fmf(OP_FSUB, op(op1, 1), op(op1, 0), fmf_of(i), "");
            return ic_new_fbinop_fmf(OP_FADD, op0, ns, fmf_of(i));
        }
    }
    // (-X) - Op1 --> -(X + Op1)
    if has_nsz(i) && !is_cexpr(op0) && one_use(op0) {
        let x = m_fneg(op0);
        if x >= 0 {
            let fa = icb_fbinop_fmf(OP_FADD, x, op1, fmf_of(i), "");
            return ic_new_fneg_fmf(fa, fmf_of(i));
        }
    }
    if is_constant(op0) && is_select_inst(op1) {
        let nv = fold_op_into_select(i, op1, false, false);
        if nv >= 0 { return nv; }
    }
    // X - C --> X + (-C)
    if is_imm_c(op1) {
        let nc = cf_fneg(op1);
        if nc >= 0 { return ic_new_fbinop_fmf(OP_FADD, op0, nc, fmf_of(i)); }
    }
    // X - (-Y) --> X + Y
    let y0 = m_fneg(op1);
    if y0 >= 0 { return ic_new_fbinop_fmf(OP_FADD, op0, y0, fmf_of(i)); }
    // X - (fptrunc(-Y)) --> X + fptrunc(Y) ; X - (fpext(-Y)) --> X + fpext(Y)
    if one_use(op1) && (is_inst_op(op1, OP_FPTRUNC) || is_inst_op(op1, OP_FPEXT)) {
        let y = m_fneg(op(op1, 0));
        if y >= 0 {
            let c = icb_cast(iop(op1), y, ty, "");
            return ic_new_fbinop_fmf(OP_FADD, op0, c, fmf_of(i));
        }
    }
    // Op0 - (-X * Y) --> Op0 + (X * Y)
    if one_use(op1) && is_fmul(op1) {
        for j in 2 {
            let x = m_fneg(op(op1, j));
            if x >= 0 {
                let m = icb_fbinop_fmf(OP_FMUL, x, op(op1, 1 - j), fmf_of(i), "");
                return ic_new_fbinop_fmf(OP_FADD, op0, m, fmf_of(i));
            }
        }
    }
    // Op0 - (-X / Y) --> Op0 + (X / Y) ; Op0 - (X / -Y) --> Op0 + (X / Y)
    if one_use(op1) && is_fdiv(op1) {
        var x: i32 = -1; var y: i32 = -1;
        let nx = m_fneg(op(op1, 0));
        if nx >= 0 { x = nx; y = op(op1, 1); }
        else { let ny = m_fneg(op(op1, 1)); if ny >= 0 { x = op(op1, 0); y = ny; } }
        if x >= 0 {
            let d = icb_fbinop_fmf(OP_FDIV, x, y, fmf_of(i), "");
            return ic_new_fbinop_fmf(OP_FADD, op0, d, fmf_of(i));
        }
    }
    let sv = simplify_selects_feeding_binop(i, op0, op1);
    if sv >= 0 { return ic_replace_inst_uses_with(i, sv); }
    if has_reassoc(i) && has_nsz(i) {
        // (Y - X) - Y --> -X
        if is_fsub(op0) && op(op0, 0) == op1 { return ic_new_fneg_fmf(op(op0, 1), fmf_of(i)); }
        // Y - (X + Y) --> -X ; Y - (Y + X) --> -X
        if is_fadd(op1) {
            if op(op1, 0) == op0 { return ic_new_fneg_fmf(op(op1, 1), fmf_of(i)); }
            if op(op1, 1) == op0 { return ic_new_fneg_fmf(op(op1, 0), fmf_of(i)); }
        }
        // (X * C) - X --> X * (C - 1.0)
        if is_fmul(op0) && op(op0, 0) == op1 && is_constant(op(op0, 1)) {
            let c = cf_fold_binop_operands(OP_FSUB, op(op0, 1), c_fpd(ty, 1.0));
            if c >= 0 { return ic_new_fbinop_fmf(OP_FMUL, op1, c, fmf_of(i)); }
        }
        // X - (X * C) --> X * (1.0 - C)
        if is_fmul(op1) && op(op1, 0) == op0 && is_constant(op(op1, 1)) {
            let c = cf_fold_binop_operands(OP_FSUB, c_fpd(ty, 1.0), op(op1, 1));
            if c >= 0 { return ic_new_fbinop_fmf(OP_FMUL, op0, c, fmf_of(i)); }
        }
        // ((X - Y) + Z) - Op1 --> (X + Z) - (Y + Op1)
        if one_use(op0) && is_fadd(op0) {
            for k in 2 {
                let s = op(op0, k);
                if one_use(s) && is_fsub(s) {
                    let z = op(op0, 1 - k);
                    let xz = icb_fbinop_fmf(OP_FADD, op(s, 0), z, fmf_of(i), "");
                    let yw = icb_fbinop_fmf(OP_FADD, op(s, 1), op1, fmf_of(i), "");
                    return ic_new_fbinop_fmf(OP_FSUB, xz, yw, fmf_of(i));
                }
            }
        }
        // add_rdx(A0, V0) - add_rdx(A1, V1) --> add_rdx(A0, V0 - V1) - A1
        if one_use(op0) && is_intr(op0, IID_vector_reduce_fadd) && one_use(op1) && is_intr(op1, IID_vector_reduce_fadd) &&
           vals[op(op0, 1)].ty == vals[op(op1, 1)].ty {
            let s = icb_fbinop_fmf(OP_FSUB, op(op0, 1), op(op1, 1), fmf_of(i), "");
            let rdx = icb_intrinsic_fmf(IID_vector_reduce_fadd, [vals[s].ty as i32], [op(op0, 0), s], fmf_of(i), "");
            return ic_new_fbinop_fmf(OP_FSUB, rdx, op(op1, 0), fmf_of(i));
        }
        let f = factorize_fadd_fsub(i);
        if f >= 0 { return f; }
        let fcv = fadd_combine_simplify(i);
        if fcv >= 0 { return ic_replace_inst_uses_with(i, fcv); }
        // (X - Y) - Op1 --> X - (Y + Op1)
        if one_use(op0) && is_fsub(op0) {
            let fa = icb_fbinop_fmf(OP_FADD, op(op0, 1), op1, fmf_of(i), "");
            return ic_new_fbinop_fmf(OP_FSUB, op(op0, 0), fa, fmf_of(i));
        }
    }
    return -1;
}
