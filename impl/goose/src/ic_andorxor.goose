// InstCombine and/or/xor: port of llvm/lib/Transforms/InstCombine/InstCombineAndOrXor.cpp, whole and in the order
// of the C++ file (visitAnd, visitOr, visitXor and every helper: foldAndOrOfICmps, foldLogOpOfMaskedICmps,
// foldLogicOfFCmps, foldCastedBitwiseLogic, foldNot, sinkNotIntoLogicalOp, convertOrOfShiftsToFunnelShift, ...).
// Helpers LLVM keeps in other files are ported here where noted: recognizeBSwapOrBitReverseIdiom and
// collectBitParts (Transforms/Utils/Local.cpp), decomposeBitTest (Analysis/CmpInstAnalysis.cpp; the ICmp form
// is ic_compares.goose's icc_decompose_bit_test_icmp), isKnownInversion and matchSimpleRecurrence
// (Analysis/ValueTracking.cpp), foldAndOrOfSelectUsingImpliedCond (InstCombineSelect.cpp),
// getLosslessUnsignedTrunc/getLosslessSignedTrunc (Analysis/ConstantFolding.cpp), Constant::mergeUndefsWith.
//
// Conventions (DESIGN.md §12): a fold returns an instruction id: -1 = nullptr, the visited instruction =
// modified in place, or a new unattached instruction; folds that return a Value* in LLVM return a value id
// (-1 = nullptr). Private helpers are prefixed `ao_`.
namespace ic;
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import intrinsics;
import datalayout;
import domtree;
import constfold;
import cfold;
import pm;
import vt;
import poison;
import knownbits;
import constrange;
import implied;
import fpclass;
import instsimplify;
import apint;
import overflow;
import domcond;
import cfgutil;
import ic;
import ic_builder;
import ic_common;
import ic_shifts;
import ic_casts;
import ic_compares;
import ic_demanded;
import ic_addsub;
import ic_muldivrem;

// ---------------------------------------------------------------------------------------------
// Small helpers

fn ao_kb(v: i32, cx: i32) -> KB { kb_cxt = cx; return kb_compute_all(v, 0); }
fn ao_pow2(v: i32, or_zero: bool, cx: i32) -> bool { kb_cxt = cx; return is_known_pow2(v, or_zero, 0); }
fn ao_nonzero(v: i32, cx: i32) -> bool { kb_cxt = cx; return is_known_non_zero(v, 0); }
fn ao_masked_zero(v: i32, mask: AP, cx: i32) -> bool { kb_cxt = cx; return masked_value_is_zero(v, mask, 0); }
fn ao_signbits(v: i32, cx: i32) -> i64 { kb_cxt = cx; return num_sign_bits(v, 0); }
// isGuaranteedNotToBeUndefOrPoison(V) / isGuaranteedNotToBePoison(V) without a context
fn ao_not_undef_poison(v: i32) -> bool { is_guaranteed_not_to_be_undef_or_poison(v, -1, 0) }
fn ao_not_poison(v: i32) -> bool { is_guaranteed_not_to_be_poison(v, -1, 0) }
fn ao_cmp_inst(v: i32) -> bool { is_inst_op(v, OP_ICMP) }
fn ao_fcmp_inst(v: i32) -> bool { is_inst_op(v, OP_FCMP) }
fn ao_splat_if_vec(ty: i32, s: i32) -> i32 { if ty_is_vector(ty) { c_splat(ty, s) } else { s } }
fn ao_ty_with_bits(t: i32, w: i64) -> i32 { ty_with_elem(t, ty_int(w)) }
// m_ElementWiseBitCast(m_Value(X)): a bitcast instruction between scalars or same-length vectors
fn ao_elementwise_bitcast(v: i32) -> i32 { if is_inst_op(v, OP_BITCAST) && ic_elementwise_bitcast(v) { op(v, 0) } else { -1 } }
// m_SExtOrSelf(m_Specific(x))
fn ao_sext_or_self_of(v: i32, x: i32) -> bool { v == x || (is_inst_op(v, OP_SEXT) && op(v, 0) == x) }
fn ao_sext_or_self(v: i32) -> i32 { let s = m_sext(v); if s >= 0 { s } else { v } }
fn ao_zext_or_self(v: i32) -> i32 { let s = m_zext(v); if s >= 0 { s } else { v } }
fn ao_trunc_or_self(v: i32) -> i32 { let s = m_trunc(v); if s >= 0 { s } else { v } }
// m_LogicalShift: shl or lshr instruction
fn ao_logical_shift(v: i32) -> bool { bo(v, OP_SHL) || bo(v, OP_LSHR) }
fn ao_is_shift(v: i32) -> bool { bo(v, OP_SHL) || bo(v, OP_LSHR) || bo(v, OP_ASHR) }
// m_Power2(const APInt *&) / m_NegatedPower2 / m_LowBitMask
// (api_pred_ty: scalar or splat with poison lanes allowed; the value is ap_cp)
fn ao_api_pow2(v: i32) -> bool { has_apint_poison(v) && ap_is_pow2(ap_cp(v)) }
fn ao_api_neg_pow2(v: i32) -> bool { has_apint_poison(v) && ap_is_neg_pow2(ap_cp(v)) }
fn ao_api_low_bit_mask(v: i32) -> bool { has_apint_poison(v) && ap_is_mask(ap_cp(v)) }
// FMFSource::intersect(A, B)
fn ao_fmf_intersect(a: i32, b: i32) -> u8 { inst_fmf(a) & inst_fmf(b) }
// IRBuilder::CreateFCmpFMF(P, LHS, RHS, FMFSource)
fn ao_fcmp_fmf(p: i64, a: i32, b: i32, fmf: u8, name: const u8[:]) -> i32 {
    let sv = icb_fmf;
    icb_fmf = fmf;
    let r = icb_fcmp(p, a, b, name);
    icb_fmf = sv;
    return r;
}
// IRBuilder::CreateFAbs(V, FMFSource) / CreateFNeg(V, Name, FMFSource)
fn ao_fabs(v: i32, fmf: u8) -> i32 {
    let sv = icb_fmf;
    icb_fmf = fmf;
    let r = icb_unary_intrinsic(IID_fabs, v, "");
    icb_fmf = sv;
    return r;
}
fn ao_fneg(v: i32) -> i32 {
    if is_constant(v) {
        let f = cf_fold_unary(OP_FNEG, v);
        if f >= 0 { return f; }
    }
    let i = create_inst(OP_FNEG, vals[v].ty, [v]);
    insts[inst_of(i)].fmf = icb_fmf;
    return icb_insert(i, "");
}
// IRBuilder::CreateIsNeg / CreateIsNotNeg
fn ao_is_neg(v: i32, name: const u8[:]) -> i32 { icb_icmp(P_SLT, v, c_null(vals[v].ty), name) }
fn ao_is_not_neg(v: i32, name: const u8[:]) -> i32 { icb_icmp(P_SGT, v, c_all_ones(vals[v].ty), name) }
// IRBuilder::CreateLogicalOp(Opc, Cond1, Cond2, Name, MDFrom)
fn ao_logical_op(o: i64, a: i32, b: i32, name: const u8[:], mdfrom: i32) -> i32 {
    if o == OP_AND { return icb_select(a, b, c_null(vals[b].ty), name, mdfrom); }
    return icb_select(a, c_all_ones(vals[b].ty), b, name, mdfrom);
}
// copy the name of v plus a suffix into buf
fn ao_name_suffix(buf: u8[>..]&, v: i32, sfx: const u8[:]) {
    buf.append(val_name(v));
    buf.append(sfx);
}
// m_ConstantInt(uint64_t &): a scalar ConstantInt that fits in 64 bits
fn ao_cint_u64(v: i32) -> bool { has_apint(v) && ap_fits_u64(ap_c(v)) }
fn ao_cint_val(v: i32) -> u64 { ap_zext64(ap_c(v)) }
// m_ImmConstant
fn ao_imm(v: i32) -> bool { is_imm_c(v) }

// Constant::mergeUndefsWith(C, Other): lanes of C where Other is undef/poison become undef
fn ao_merge_undefs_with(c: i32, other: i32) -> i32 {
    if m_undef(c) { return c; }
    let ty = vals[c].ty;
    if m_undef(other) { return c_undef(ty); }
    if ty_kind(ty) != TK_FVEC { return c; }
    let n = ty_count(ty);
    let et = ty_elem(ty);
    var found = false;
    let mark = is_ops.len;
    for k in n {
        var e = agg_elem(c, k);
        let oe = agg_elem(other, k);
        if !m_undef(e) && m_undef(oe) { e = c_undef(et); found = true; }
        is_ops.push(e);
    }
    if !found { is_ops.resize(mark); return c; }
    let r = c_aggregate(ty, is_ops[mark..is_ops.len]);
    is_ops.resize(mark);
    return r;
}

// getLosslessUnsignedTrunc(C, DestTy, DL, Flags) / getLosslessSignedTrunc: (constant or -1, NNeg)
fn ao_lossless_trunc(c: i32, to_ty: i32, ext: i64) -> i32, bool {
    let inv = ce_cast(OP_TRUNC, c, to_ty);
    if inv < 0 { return -1, false; }
    let back = cf_fold_cast_operand(ext, inv, vals[c].ty);
    if back < 0 || back != c { return -1, false; }
    var nneg = false;
    if ext == OP_ZEXT {
        let sx = cf_fold_cast_operand(OP_SEXT, inv, vals[c].ty);
        nneg = back == sx;
    }
    return inv, nneg;
}

// isKnownInversion(X, Y) (ValueTracking.cpp)
fn ao_is_known_inversion(x: i32, y: i32) -> bool {
    if !ao_cmp_inst(x) || !ao_cmp_inst(y) { return false; }
    let a = op(x, 0);
    let b = op(x, 1);
    var c: i32 = -1;
    var p2: i64 = 0;
    if op(y, 0) == a { c = op(y, 1); p2 = inst_pred(y); }
    else if op(y, 1) == a { c = op(y, 0); p2 = pred_swapped(inst_pred(y)); }
    else { return false; }
    let p1 = inst_pred(x);
    let ss1 = icc_samesign(x);
    let ss2 = icc_samesign(y);
    if ss1 != ss2 { return false; }
    if b == c { return p1 == pred_inverse(p2); }
    if !has_apint(b) || !has_apint(c) { return false; }
    let c1 = ap_c(b);
    let c2 = ap_c(c);
    if ss1 && ap_is_nonneg(c1) != ap_is_nonneg(c2) { return false; }
    let cr1 = rg_exact_icmp(p1, c1);
    let cr2 = rg_exact_icmp(p2, c2);
    return rg_eq(rg_inverse(cr1), cr2);
}

// ---------------------------------------------------------------------------------------------
// getNewICmpValue / getFCmpValue (and getICmpCode / getPredForICmpCode / predicatesFoldable of
// CmpInstAnalysis.cpp)

fn ao_icmp_code(p: i64) -> u32 {
    match p {
        P_UGT => 1, P_SGT => 1, P_EQ => 2, P_UGE => 3, P_SGE => 3, P_ULT => 4, P_SLT => 4, P_NE => 5,
        P_ULE => 6, P_SLE => 6,
        _ => { fatal("internal: getICmpCode of an invalid predicate"); 0 },
    }
}
fn ao_predicates_foldable(p1: i64, p2: i64) -> bool {
    return pred_is_signed(p1) == pred_is_signed(p2) || (pred_is_signed(p1) && icmp_is_equality(p2)) ||
           (pred_is_signed(p2) && icmp_is_equality(p1));
}
// getNewICmpValue(Code, Sign, LHS, RHS, Builder)
fn ao_new_icmp_value(code: u32, sign: bool, l: i32, r: i32) -> i32 {
    let rty = cmp_result_ty(vals[l].ty);
    var p: i64 = 0;
    match code {
        0 => { return c_bool_ty(rty, false); },
        1 => { p = if sign { P_SGT } else { P_UGT }; },
        2 => { p = P_EQ; },
        3 => { p = if sign { P_SGE } else { P_UGE }; },
        4 => { p = if sign { P_SLT } else { P_ULT }; },
        5 => { p = P_NE; },
        6 => { p = if sign { P_SLE } else { P_ULE }; },
        _ => { return c_bool_ty(rty, true); },
    }
    return icb_icmp(p, l, r, "");
}
// getFCmpValue(Code, LHS, RHS, Builder, FMF)
fn ao_fcmp_value(code: u32, l: i32, r: i32, fmf: u8) -> i32 {
    let rty = cmp_result_ty(vals[l].ty);
    if code == 0 { return c_bool_ty(rty, false); }
    if code == 15 { return c_bool_ty(rty, true); }
    return ao_fcmp_fmf(code as i64, l, r, fmf, "");
}

// insertRangeTest(V, Lo, Hi, isSigned, Inside): (V >= Lo && V < Hi) if Inside, else (V < Lo || V >= Hi)
fn insert_range_test(v: i32, lo: AP, hi: AP, signed: bool, inside: bool) -> i32 {
    let ty = vals[v].ty;
    var p = if inside { P_ULT } else { P_UGE };
    if (signed && ap_is_min_signed(lo)) || (!signed && ap_is_zero(lo)) {
        if signed { p = pred_signed(p); }
        return icb_icmp(p, v, c_int_ap(ty, hi), "");
    }
    var nm: u8[>..] = [];
    ao_name_suffix(nm, v, ".off");
    let vml = icb_sub(v, c_int_ap(ty, lo), nm);
    let hml = c_int_ap(ty, ap_sub(hi, lo));
    return icb_icmp(p, vml, hml, "");
}

// ---------------------------------------------------------------------------------------------
// Masked icmps

let AMASK_ALLONES: u32 = 1;
let AMASK_NOTALLONES: u32 = 2;
let BMASK_ALLONES: u32 = 4;
let BMASK_NOTALLONES: u32 = 8;
let MASK_ALLZEROS: u32 = 16;
let MASK_NOTALLZEROS: u32 = 32;
let AMASK_MIXED: u32 = 64;
let AMASK_NOTMIXED: u32 = 128;
let BMASK_MIXED: u32 = 256;
let BMASK_NOTMIXED: u32 = 512;

// getMaskedICmpType(A, B, C, Pred)
fn ao_masked_icmp_type(a: i32, b: i32, c: i32, p: i64) -> u32 {
    let ha = has_apint(a);
    let hb = has_apint(b);
    let hc = has_apint(c);
    let is_eq = p == P_EQ;
    let a_pow2 = ha && ap_is_pow2(ap_c(a));
    let b_pow2 = hb && ap_is_pow2(ap_c(b));
    var m: u32 = 0;
    if hc && ap_is_zero(ap_c(c)) {
        m |= if is_eq { MASK_ALLZEROS | AMASK_MIXED | BMASK_MIXED } else { MASK_NOTALLZEROS | AMASK_NOTMIXED | BMASK_NOTMIXED };
        if a_pow2 { m |= if is_eq { AMASK_NOTALLONES | AMASK_NOTMIXED } else { AMASK_ALLONES | AMASK_MIXED }; }
        if b_pow2 { m |= if is_eq { BMASK_NOTALLONES | BMASK_NOTMIXED } else { BMASK_ALLONES | BMASK_MIXED }; }
        return m;
    }
    if a == c {
        m |= if is_eq { AMASK_ALLONES | AMASK_MIXED } else { AMASK_NOTALLONES | AMASK_NOTMIXED };
        if a_pow2 { m |= if is_eq { MASK_NOTALLZEROS | AMASK_NOTMIXED } else { MASK_ALLZEROS | AMASK_MIXED }; }
    } else if ha && hc && ap_is_subset_of(ap_c(c), ap_c(a)) {
        m |= if is_eq { AMASK_MIXED } else { AMASK_NOTMIXED };
    }
    if b == c {
        m |= if is_eq { BMASK_ALLONES | BMASK_MIXED } else { BMASK_NOTALLONES | BMASK_NOTMIXED };
        if b_pow2 { m |= if is_eq { MASK_NOTALLZEROS | BMASK_NOTMIXED } else { MASK_ALLZEROS | BMASK_MIXED }; }
    } else if hb && hc && ap_is_subset_of(ap_c(c), ap_c(b)) {
        m |= if is_eq { BMASK_MIXED } else { BMASK_NOTMIXED };
    }
    return m;
}

// conjugateICmpMask(Mask)
fn ao_conjugate_icmp_mask(m: u32) -> u32 {
    var n = (m & (AMASK_ALLONES | BMASK_ALLONES | MASK_ALLZEROS | AMASK_MIXED | BMASK_MIXED)) << 1;
    n |= (m & (AMASK_NOTALLONES | BMASK_NOTALLONES | MASK_NOTALLZEROS | AMASK_NOTMIXED | BMASK_NOTMIXED)) >> 1;
    return n;
}

// llvm::decomposeBitTest(Cond, LookThroughTrunc, AllowNonZeroC, DecomposeAnd) (CmpInstAnalysis.cpp):
// ok, X, Mask, C, Pred
fn ao_decompose_bit_test(cond: i32, look_trunc: bool, allow_nonzero_c: bool, decompose_and: bool) -> bool, i32, AP, AP, i64 {
    let z = ap_zero(1);
    if ao_cmp_inst(cond) {
        if !is_int_or_int_vec(vals[op(cond, 0)].ty) { return false, -1, z, z, 0; }
        let ok, x, mask, c, p = icc_decompose_bit_test_icmp(op(cond, 0), op(cond, 1), inst_pred(cond), look_trunc, allow_nonzero_c, decompose_and);
        return ok, x, mask, c, p;
    }
    if is_int_ty1(vals[cond].ty) {
        var x = m_trunc(cond);
        let is_trunc = x >= 0;
        if x < 0 { let n = m_not(cond); if n >= 0 { x = m_trunc(n); } }
        if x >= 0 {
            let bw = ty_sbits(x);
            return true, x, ap_u64(1, bw), ap_zero(bw), if is_trunc { P_NE } else { P_EQ };
        }
    }
    return false, -1, z, z, 0;
}
// the local decomposeBitTest(Cond, Pred, X, Y, Z) of InstCombineAndOrXor.cpp: ok, Pred, X, Y, Z
fn ao_decompose_bit_test_v(cond: i32) -> bool, i64, i32, i32, i32 {
    let ok, x, mask, c, p = ao_decompose_bit_test(cond, true, true, true);
    if !ok { return false, 0, -1, -1, -1; }
    let ty = vals[x].ty;
    return true, p, x, c_int_ap(ty, mask), c_int_ap(ty, c);
}

// getMaskedTypeForICmpPair(A, B, C, D, E, LHS, RHS, PredL, PredR): the outputs are mk_*
var mk_a: i32 = -1;
var mk_b: i32 = -1;
var mk_c: i32 = -1;
var mk_d: i32 = -1;
var mk_e: i32 = -1;
var mk_pl: i64 = 0;
var mk_pr: i64 = 0;
fn ao_masked_type_for_icmp_pair(lhs: i32, rhs: i32) -> bool, u32, u32 {
    var l1: i32 = -1;
    var l11: i32 = -1;
    var l12: i32 = -1;
    var l2: i32 = -1;
    var l21: i32 = -1;
    var l22: i32 = -1;
    var pl: i64 = 0;
    var pr: i64 = 0;
    let okl, plx, lx, ly, lz = ao_decompose_bit_test_v(lhs);
    if okl {
        pl = plx; l11 = lx; l12 = ly; l2 = lz;
    } else {
        if !ao_cmp_inst(lhs) { return false, 0, 0; }
        if !is_int_or_int_vec(vals[op(lhs, 0)].ty) { return false, 0, 0; }
        pl = inst_pred(lhs);
        l1 = op(lhs, 0);
        l2 = op(lhs, 1);
        if bo(l1, OP_AND) { l11 = op(l1, 0); l12 = op(l1, 1); }
        else { l11 = l1; l12 = c_all_ones(vals[l1].ty); }
        if bo(l2, OP_AND) { l21 = op(l2, 0); l22 = op(l2, 1); }
        else { l21 = l2; l22 = c_all_ones(vals[l2].ty); }
    }
    if !icmp_is_equality(pl) { return false, 0, 0; }
    var a: i32 = -1;
    var b: i32 = -1;
    var c: i32 = -1;
    var d: i32 = -1;
    var e: i32 = -1;
    let okr, prx, r11d, r12d, r2d = ao_decompose_bit_test_v(rhs);
    if okr {
        pr = prx;
        if r11d == l11 || r11d == l12 || r11d == l21 || r11d == l22 { a = r11d; d = r12d; }
        else if r12d == l11 || r12d == l12 || r12d == l21 || r12d == l22 { a = r12d; d = r11d; }
        else { return false, 0, 0; }
        e = r2d;
    } else {
        if !ao_cmp_inst(rhs) { return false, 0, 0; }
        if !is_int_or_int_vec(vals[op(rhs, 0)].ty) { return false, 0, 0; }
        pr = inst_pred(rhs);
        let r1 = op(rhs, 0);
        let r2 = op(rhs, 1);
        var r11: i32 = -1;
        var r12: i32 = -1;
        var ok = false;
        if bo(r1, OP_AND) { r11 = op(r1, 0); r12 = op(r1, 1); }
        else { r11 = r1; r12 = c_all_ones(vals[r1].ty); }
        if r11 == l11 || r11 == l12 || r11 == l21 || r11 == l22 { a = r11; d = r12; e = r2; ok = true; }
        else if r12 == l11 || r12 == l12 || r12 == l21 || r12 == l22 { a = r12; d = r11; e = r2; ok = true; }
        // Avoid matching against the -1 value we created for unmasked operand.
        if ok && m_all_ones(a) { ok = false; }
        if !ok {
            if bo(r2, OP_AND) { r11 = op(r2, 0); r12 = op(r2, 1); }
            else { r11 = r2; r12 = c_all_ones(vals[r2].ty); }
            if r11 == l11 || r11 == l12 || r11 == l21 || r11 == l22 { a = r11; d = r12; e = r1; }
            else if r12 == l11 || r12 == l12 || r12 == l21 || r12 == l22 { a = r12; d = r11; e = r1; }
            else { return false, 0, 0; }
        }
    }
    if !icmp_is_equality(pr) { return false, 0, 0; }
    if l11 == a { b = l12; c = l2; }
    else if l12 == a { b = l11; c = l2; }
    else if l21 == a { b = l22; c = l1; }
    else if l22 == a { b = l21; c = l1; }
    let lt = ao_masked_icmp_type(a, b, c, pl);
    let rt = ao_masked_icmp_type(a, d, e, pr);
    mk_a = a; mk_b = b; mk_c = c; mk_d = d; mk_e = e; mk_pl = pl; mk_pr = pr;
    return true, lt, rt;
}

// foldLogOpOfMaskedICmps_NotAllZeros_BMask_Mixed(LHS, RHS, IsAnd, A, B, D, E, PredL, PredR, Builder)
fn ao_fold_masked_notallzeros_bmask_mixed(lhs: i32, rhs: i32, is_and: bool, a: i32, b: i32, d: i32, e: i32, pl: i64, pr: i64) -> i32 {
    if !has_apint(b) || !has_apint(d) || !has_apint(e) { return -1; }
    let bc = ap_c(b);
    let dc = ap_c(d);
    let oec = ap_c(e);
    let ncc = if is_and { P_EQ } else { P_NE };
    var ec = oec;
    if pr != ncc { ec = ap_xor(ec, dc); }
    if ap_is_zero(bc) || ap_is_zero(dc) { return -1; }
    if !ap_intersects(bc, dc) {
        let src = ao_elementwise_bitcast(a);
        if ap_eq(dc, ec) && src >= 0 && !func_has_fn_attr(ic_fn, AK_StrictFP) {
            let fty = ty_scalar(vals[src].ty);
            if !icc_is_ieee_like(fty) { return -1; }
            let exp = icc_fp_exponent_mask(fty);
            if !ap_eq(ec, exp) { return -1; }
            var frac = ap_not(exp);
            frac = ap_clear_bit(frac, frac.w as i64 - 1);
            if !ap_eq(bc, frac) { return -1; }
            return icb_fcmp(if is_and { P_UNO } else { P_ORD }, src, c_null(vals[src].ty), "");
        }
        return -1;
    }
    let bd = ap_and(bc, dc);
    let bxd = ap_and(bc, ap_xor(bc, dc));
    if ap_is_zero(ap_and(bd, ec)) && ap_is_pow2(bxd) {
        let bord = ap_or(bc, dc);
        let bbde = ap_or(bxd, ec);
        let ty = vals[a].ty;
        let na = icb_and(a, c_int_ap(ty, bord), "");
        return icb_icmp(ncc, na, c_int_ap(ty, bbde), "");
    }
    // IsSubSetOrEqual(C1, C2): (C1 & C2) == C1; IsSuperSetOrEqual(C1, C2): (C1 & C2) == C2
    let sub = ap_eq(bd, bc);
    let sup = ap_eq(bd, dc);
    if !sub && !sup { return -1; }
    if ap_is_zero(ec) {
        if sub { return c_bool_ty(vals[lhs].ty, !is_and); }
        return -1;
    }
    if sup {
        if ao_cmp_inst(rhs) { icc_set_samesign(rhs, false); }
        return rhs;
    }
    if !ap_is_zero(ap_and(bc, ec)) {
        if ao_cmp_inst(rhs) { icc_set_samesign(rhs, false); }
        return rhs;
    }
    return c_bool_ty(vals[lhs].ty, !is_and);
}

// foldLogOpOfMaskedICmpsAsymmetric(LHS, RHS, IsAnd, A, B, C, D, E, PredL, PredR, LHSMask, RHSMask, Builder)
fn ao_fold_masked_asymmetric(lhs: i32, rhs: i32, is_and: bool, a: i32, b: i32, c: i32, d: i32, e: i32, pl: i64, pr: i64, lm0: u32, rm0: u32) -> i32 {
    var lm = lm0;
    var rm = rm0;
    if !is_and { lm = ao_conjugate_icmp_mask(lm); rm = ao_conjugate_icmp_mask(rm); }
    if (lm & MASK_NOTALLZEROS) != 0 && (rm & BMASK_MIXED) != 0 {
        let v = ao_fold_masked_notallzeros_bmask_mixed(lhs, rhs, is_and, a, b, d, e, pl, pr);
        if v >= 0 { return v; }
    } else if (lm & BMASK_MIXED) != 0 && (rm & MASK_NOTALLZEROS) != 0 {
        let v = ao_fold_masked_notallzeros_bmask_mixed(rhs, lhs, is_and, a, d, b, c, pr, pl);
        if v >= 0 { return v; }
    }
    return -1;
}

// the FoldBMixed lambda of foldLogOpOfMaskedICmps
fn ao_fold_bmixed(lhs: i32, is_and: bool, a: i32, cb: AP, cd: AP, occ: AP, oce: AP, pl: i64, pr: i64, cc0: i64, is_not: bool) -> i32 {
    let cc = if is_not { pred_inverse(cc0) } else { cc0 };
    let constc = if pl != cc { ap_xor(cb, occ) } else { occ };
    let conste = if pr != cc { ap_xor(cd, oce) } else { oce };
    if !ap_is_zero(ap_and(ap_and(cb, cd), ap_xor(constc, conste))) {
        return if is_not { -1 } else { c_bool_ty(vals[lhs].ty, !is_and) };
    }
    if is_not && !ap_is_subset_of(cb, cd) && !ap_is_subset_of(cd, cb) { return -1; }
    var bd = ap_or(cb, cd);
    var ce = ap_or(constc, conste);
    if is_not { bd = ap_and(cb, cd); ce = ap_and(constc, conste); }
    let ty = vals[a].ty;
    let na = icb_and(a, c_int_ap(ty, bd), "");
    return icb_icmp(cc, na, c_int_ap(ty, ce), "");
}

// foldLogOpOfMaskedICmps(LHS, RHS, IsAnd, IsLogical, Builder, Q)
fn ao_fold_log_op_of_masked_icmps(lhs: i32, rhs: i32, is_and: bool, is_logical: bool, cx: i32) -> i32 {
    let okp, lm, rm = ao_masked_type_for_icmp_pair(lhs, rhs);
    if !okp { return -1; }
    let a = mk_a;
    let b = mk_b;
    let c = mk_c;
    var d = mk_d;
    let e = mk_e;
    let pl = mk_pl;
    let pr = mk_pr;
    var mask = lm & rm;
    if mask == 0 {
        let v = ao_fold_masked_asymmetric(lhs, rhs, is_and, a, b, c, d, e, pl, pr, lm, rm);
        if v >= 0 { return v; }
        return -1;
    }
    let ncc = if is_and { P_EQ } else { P_NE };
    if !is_and { mask = ao_conjugate_icmp_mask(mask); }
    if (mask & MASK_ALLZEROS) != 0 {
        if is_logical && !ao_not_undef_poison(d) { return -1; }
        let nor = icb_or(b, d, "");
        let nand = icb_and(a, nor, "");
        return icb_icmp(ncc, nand, c_null(vals[a].ty), "");
    }
    if (mask & BMASK_ALLONES) != 0 {
        if is_logical && !ao_not_undef_poison(d) { return -1; }
        let nor = icb_or(b, d, "");
        let nand = icb_and(a, nor, "");
        return icb_icmp(ncc, nand, nor, "");
    }
    if (mask & AMASK_ALLONES) != 0 {
        if is_logical && !ao_not_undef_poison(d) { return -1; }
        let na1 = icb_and(b, d, "");
        let na2 = icb_and(a, na1, "");
        return icb_icmp(ncc, na2, a, "");
    }
    if has_apint(b) && has_apint(d) {
        let cb = ap_c(b);
        let cd = ap_c(d);
        if (mask & (MASK_NOTALLZEROS | BMASK_NOTALLONES)) != 0 {
            let nm = ap_and(cb, cd);
            if ap_eq(nm, cb) { return lhs; }
            if ap_eq(nm, cd) {
                if is_logical && is_inst(rhs) { drop_poison_generating_flags(rhs); }
                return rhs;
            }
        }
        if (mask & AMASK_NOTALLONES) != 0 {
            let nm = ap_or(cb, cd);
            if ap_eq(nm, cb) { return lhs; }
            if ap_eq(nm, cd) { return rhs; }
        }
        if (mask & (BMASK_MIXED | BMASK_NOTMIXED)) != 0 {
            if !has_apint(c) || !has_apint(e) { return -1; }
            let occ = ap_c(c);
            let oce = ap_c(e);
            if (mask & BMASK_MIXED) != 0 { return ao_fold_bmixed(lhs, is_and, a, cb, cd, occ, oce, pl, pr, ncc, false); }
            if (mask & BMASK_NOTMIXED) != 0 { return ao_fold_bmixed(lhs, is_and, a, cb, cd, occ, oce, pl, pr, ncc, true); }
        }
    }
    if (mask & MASK_NOTALLZEROS) != 0 && ao_pow2(b, false, cx) && ao_pow2(d, false, cx) {
        if is_logical { d = icb_freeze(d, ""); }
        let m2 = icb_or(b, d, "");
        let masked = icb_and(a, m2, "");
        return icb_icmp(ncc, masked, m2, "");
    }
    return -1;
}

// simplifyRangeCheck(Cmp0, Cmp1, Inverted)
fn ao_simplify_range_check(cmp0: i32, cmp1: i32, inverted: bool) -> i32 {
    let rs = m_constant_int(op(cmp0, 1));
    if rs < 0 { return -1; }
    let p0 = if inverted { pred_inverse(inst_pred(cmp0)) } else { inst_pred(cmp0) };
    if !((p0 == P_SGT && ap_is_all_ones(ci_ap(rs))) || (p0 == P_SGE && ap_is_zero(ci_ap(rs)))) { return -1; }
    var p1 = if inverted { pred_inverse(inst_pred(cmp1)) } else { inst_pred(cmp1) };
    var input = op(cmp0, 0);
    let c10 = op(cmp1, 0);
    let c11 = op(cmp1, 1);
    var range_end: i32 = -1;
    if ao_sext_or_self_of(c10, input) { input = c10; range_end = c11; }
    else if ao_sext_or_self_of(c11, input) { input = c11; range_end = c10; p1 = pred_swapped(p1); }
    else { return -1; }
    var np: i64 = 0;
    if p1 == P_SLT { np = P_ULT; } else if p1 == P_SLE { np = P_ULE; } else { return -1; }
    let k = ao_kb(range_end, cmp1);
    if !kb_is_nonneg(k) { return -1; }
    if inverted { np = pred_inverse(np); }
    return icb_icmp(np, input, range_end, "");
}

// foldAndOrOfICmpsWithPow2AndWithZero(Builder, LHS, RHS, IsAnd, Q)
fn ao_fold_and_or_of_icmps_with_pow2_and_with_zero(lhs0: i32, rhs0: i32, is_and: bool, cx: i32) -> i32 {
    var lhs = lhs0;
    var rhs = rhs0;
    let p = if is_and { P_NE } else { P_EQ };
    if inst_pred(lhs) != p || inst_pred(rhs) != p { return -1; }
    if m_zero(op(rhs, 1)) { let t = lhs; lhs = rhs; rhs = t; }
    if !one_use(lhs) || !m_zero(op(lhs, 1)) { return -1; }
    let opv = op(lhs, 0);
    if !one_use(rhs) { return -1; }
    var pow2: i32 = -1;
    if op(rhs, 0) == opv { pow2 = op(rhs, 1); } else if op(rhs, 1) == opv { pow2 = op(rhs, 0); } else { return -1; }
    if m_one(pow2) { return -1; }
    // isKnownToBeAPowerOfTwo(V, DL, OrZero, AC, CxtI, DT): no DomConditionCache
    let sv = dc_active;
    dc_active = false;
    let ok = ao_pow2(pow2, true, cx);
    dc_active = sv;
    if !ok { return -1; }
    let a = icb_and(opv, pow2, "");
    return icb_icmp(p, a, opv, "");
}

// foldSignedTruncationCheck(ICmp0, ICmp1, CxtI, Builder)
fn ao_try_signed_truncation_check(icmp: i32) -> bool, i32, AP {
    let z = ap_zero(1);
    if inst_pred(icmp) != P_ULT { return false, -1, z; }
    let ad = op(icmp, 0);
    if !bo(ad, OP_ADD) || !ao_api_pow2(op(ad, 1)) || !ao_api_pow2(op(icmp, 1)) { return false, -1, z; }
    let i01 = ap_cp(op(ad, 1));
    let i1 = ap_cp(op(icmp, 1));
    if !(ap_ugt(i1, i01) && ap_eq(ap_shl(i01, 1), i1)) { return false, -1, z; }
    return true, op(ad, 0), i01;
}
fn ao_fold_signed_truncation_check(icmp0: i32, icmp1: i32, cxti: i32) -> i32 {
    var x1: i32 = -1;
    var hb = ap_zero(1);
    var other: i32 = -1;
    let ok1, xa, ha = ao_try_signed_truncation_check(icmp1);
    if ok1 { x1 = xa; hb = ha; other = icmp0; }
    else {
        let ok0, xb, hbb = ao_try_signed_truncation_check(icmp0);
        if ok0 { x1 = xb; hb = hbb; other = icmp1; } else { return -1; }
    }
    let okd, x0, mask0, cd, pd = icc_decompose_bit_test_icmp(op(other, 0), op(other, 1), inst_pred(other), false, false, true);
    if !okd || pd != P_EQ { return -1; }
    var unset = mask0;
    var x: i32 = -1;
    if x1 == x0 { x = x1; }
    else if m_trunc(x0) == x1 && x1 >= 0 { unset = ap_zext(unset, ty_sbits(x1)); x = x1; }
    else { return -1; }
    let sbm = ap_not(ap_sub_u64(hb, 1));
    if !ap_intersects(unset, sbm) { return -1; }
    if !ap_is_subset_of(unset, sbm) {
        let ohb = ap_add_u64(ap_not(unset), 1);
        if !ap_is_pow2(ohb) { return -1; }
        hb = ap_umin(hb, ohb);
    }
    var nm: u8[>..] = [];
    ao_name_suffix(nm, cxti, ".simplified");
    return icb_icmp(P_ULT, x, c_int_ap(vals[x].ty, hb), nm);
}

// m_Ctpop(m_Value(X)) -> X or -1
fn ao_m_ctpop(v: i32) -> i32 { if m_intrinsic(v, IID_ctpop) { op(v, 0) } else { -1 } }

// foldIsPowerOf2OrZero(Cmp0, Cmp1, IsAnd, Builder, IC)
fn ao_fold_is_power_of2_or_zero(cmp0: i32, cmp1: i32, is_and: bool) -> i32 {
    let x = ao_m_ctpop(op(cmp0, 0));
    if x < 0 || !m_specific_int(op(cmp0, 1), 1) { return -1; }
    if op(cmp1, 0) != x || !m_zero_int(op(cmp1, 1)) { return -1; }
    let p0 = inst_pred(cmp0);
    let p1 = inst_pred(cmp1);
    let ct = op(cmp0, 0);
    if is_and && p0 == P_NE && p1 == P_NE {
        drop_poison_generating_annotations(ct);
        icw_add(ct);
        return icb_icmp(P_UGT, ct, c_int_ty(vals[ct].ty, 1), "");
    }
    if !is_and && p0 == P_EQ && p1 == P_EQ {
        drop_poison_generating_annotations(ct);
        icw_add(ct);
        return icb_icmp(P_ULT, ct, c_int_ty(vals[ct].ty, 2), "");
    }
    return -1;
}

// foldIsPowerOf2(Cmp0, Cmp1, JoinedByAnd, Builder, IC)
fn ao_fold_is_power_of2(c0: i32, c1: i32, joined_by_and: bool) -> i32 {
    var cmp0 = c0;
    var cmp1 = c1;
    if joined_by_and && inst_pred(cmp1) == P_NE { let t = cmp0; cmp0 = cmp1; cmp1 = t; }
    else if !joined_by_and && inst_pred(cmp1) == P_EQ { let t = cmp0; cmp0 = cmp1; cmp1 = t; }
    if joined_by_and && inst_pred(cmp0) == P_NE && m_zero_int(op(cmp0, 1)) {
        let x = op(cmp0, 0);
        if inst_pred(cmp1) == P_ULT && ao_m_ctpop(op(cmp1, 0)) == x && m_specific_int(op(cmp1, 1), 2) {
            let ct = op(cmp1, 0);
            drop_poison_generating_annotations(ct);
            icw_add(ct);
            return icb_icmp(P_EQ, ct, c_int_ty(vals[ct].ty, 1), "");
        }
    }
    if !joined_by_and && inst_pred(cmp0) == P_EQ && m_zero_int(op(cmp0, 1)) {
        let x = op(cmp0, 0);
        if inst_pred(cmp1) == P_UGT && ao_m_ctpop(op(cmp1, 0)) == x && m_specific_int(op(cmp1, 1), 1) {
            let ct = op(cmp1, 0);
            drop_poison_generating_annotations(ct);
            icw_add(ct);
            return icb_icmp(P_NE, ct, c_int_ty(vals[ct].ty, 1), "");
        }
    }
    return -1;
}

// cst_pred_ty matchers this file needs that pm.goose lacks: 0 = m_ShiftedMask
fn ao_int_pred_shifted_mask(c: i32) -> bool { ap_is_shifted_mask(ci_ap(c)) }
fn ao_m_shifted_mask(v: i32) -> bool {
    if v < 0 { return false; }
    let k = vals[v].kind;
    let ty = vals[v].ty;
    if k == VK_CINT { return ao_int_pred_shifted_mask(if ty_is_vector(ty) { splat_value(v, false) } else { v }); }
    if !ty_is_vector(ty) || !is_constant(v) { return false; }
    let s = splat_value(v, false);
    if s >= 0 { if vals[s].kind == VK_CINT { return ao_int_pred_shifted_mask(s); } }
    if ty_kind(ty) != TK_FVEC { return false; }
    var has = false;
    for i in ty_count(ty) {
        let e = agg_elem(v, i);
        if e < 0 { return false; }
        if vals[e].kind == VK_POISON { continue; }
        if vals[e].kind != VK_CINT || !ao_int_pred_shifted_mask(e) { return false; }
        has = true;
    }
    return has;
}

// the isReducible lambda of foldNegativePower2AndShiftedMask
fn ao_np2_is_reducible(b: i32, d: i32, e: i32) -> bool {
    if !has_apint_poison(b) || !has_apint(d) || !has_apint(e) { return false; }
    if !ap_eq(ap_c(d), ap_c(e)) { return false; }
    return is_poison(b) || ap_countl_one(ap_cp(b)) == ap_countl_zero(ap_c(d));
}
// foldNegativePower2AndShiftedMask(A, B, D, E, PredL, PredR, Builder)
fn ao_fold_negative_power2_and_shifted_mask(a: i32, b: i32, d: i32, e: i32, pl: i64, pr: i64) -> i32 {
    if pl != P_EQ || pr != P_NE { return -1; }
    if !m_cint_pred(b, IP_NEG_POWER2, true) || !ao_m_shifted_mask(d) || !ao_m_shifted_mask(e) { return -1; }
    let bty = vals[b].ty;
    if ty_is_vector(bty) {
        if ty_kind(bty) != TK_FVEC || !is_constant(b) || !is_constant(d) || !is_constant(e) { return -1; }
        for k in ty_count(bty) {
            let be = agg_elem(b, k);
            let de = agg_elem(d, k);
            let ee = agg_elem(e, k);
            if be < 0 || de < 0 || ee < 0 { return -1; }
            if !ao_np2_is_reducible(be, de, ee) { return -1; }
        }
    } else {
        if !ao_np2_is_reducible(b, d, e) { return -1; }
    }
    return icb_icmp(P_ULT, a, d, "");
}

// foldPowerOf2AndShiftedMask(Cmp0, Cmp1, JoinedByAnd, Builder)
fn ao_fold_power_of2_and_shifted_mask(cmp0: i32, cmp1: i32, joined_by_and: bool) -> i32 {
    if !joined_by_and { return -1; }
    let okp, m0, m1 = ao_masked_type_for_icmp_pair(cmp0, cmp1);
    if !okp { return -1; }
    let cbm = BMASK_NOTMIXED | BMASK_NOTALLONES;
    if (m0 & MASK_ALLZEROS) != 0 && m1 == cbm {
        let v = ao_fold_negative_power2_and_shifted_mask(mk_a, mk_b, mk_d, mk_e, mk_pl, mk_pr);
        if v >= 0 { return v; }
    } else if m0 == cbm && (m1 & MASK_ALLZEROS) != 0 {
        let v = ao_fold_negative_power2_and_shifted_mask(mk_a, mk_d, mk_b, mk_c, mk_pr, mk_pl);
        if v >= 0 { return v; }
    }
    return -1;
}

// foldUnsignedUnderflowCheck(ZeroICmp, UnsignedICmp, IsAnd, Q, Builder)
fn ao_fold_unsigned_underflow_check(zc: i32, uc: i32, is_and: bool, cx: i32) -> i32 {
    if !m_zero(op(zc, 1)) { return -1; }
    let eqp = inst_pred(zc);
    if !icmp_is_equality(eqp) { return -1; }
    let z = op(zc, 0);
    var up: i64 = 0;
    var a: i32 = -1;
    if op(uc, 0) == z { up = inst_pred(uc); a = op(uc, 1); }
    else if op(uc, 1) == z { up = pred_swapped(inst_pred(uc)); a = op(uc, 0); }
    else { return -1; }
    if !bo(z, OP_ADD) { return -1; }
    var b: i32 = -1;
    if op(z, 0) == a { b = op(z, 1); } else if op(z, 1) == a { b = op(z, 0); } else { return -1; }
    if !(has_one_use(zc) || has_one_use(uc)) { return -1; }
    if up == P_ULT && eqp == P_NE && is_and {
        if !ao_nonzero(b, cx) { let t = b; b = a; a = t; }
        if ao_nonzero(b, cx) { return icb_icmp(P_ULT, icb_neg(b, "", false), a, ""); }
        return -1;
    }
    if up == P_UGE && eqp == P_EQ && !is_and {
        if !ao_nonzero(b, cx) { let t = b; b = a; a = t; }
        if ao_nonzero(b, cx) { return icb_icmp(P_UGE, icb_neg(b, "", false), a, ""); }
    }
    return -1;
}

// IntPart, matchIntPart, extractIntPart
struct IntPart { from: i32, start: i64, num: i64 }
fn ao_no_part() -> IntPart { IntPart { from: -1, start: 0, num: 0 } }
fn ao_match_int_part(v: i32) -> bool, IntPart {
    if !one_use(v) || m_trunc(v) < 0 { return false, ao_no_part(); }
    let x = op(v, 0);
    let nob = ty_sbits(x);
    let neb = ty_sbits(v);
    if one_use(x) && bo(x, OP_LSHR) && has_apint(op(x, 1)) && ap_ule_u64(ap_c(op(x, 1)), (nob - neb) as u64) {
        return true, IntPart { from: op(x, 0), start: ap_zext64(ap_c(op(x, 1))) as i64, num: neb };
    }
    return true, IntPart { from: x, start: 0, num: neb };
}
fn ao_extract_int_part(p: IntPart) -> i32 {
    var v = p.from;
    if p.start != 0 { v = icb_lshr(v, c_int_ty(vals[v].ty, p.start as u64), "", false); }
    let tty = ao_ty_with_bits(vals[v].ty, p.num);
    if tty != vals[v].ty { v = icb_trunc(v, tty, ""); }
    return v;
}
// the GetMatchPart lambda of foldEqOfParts
fn ao_get_match_part(cmpv: i32, opno: i64, p: i64) -> bool, IntPart {
    // icmp ne (and x, 1), (and y, 1) <=> trunc (xor x, y) to i1; eq: not (trunc (xor x, y))
    var t: i32 = -1;
    if p == P_NE { t = m_trunc(cmpv); }
    else { let n = m_not(cmpv); if n >= 0 { t = m_trunc(n); } }
    if t >= 0 && bo(t, OP_XOR) { return true, IntPart { from: op(t, opno), start: 0, num: 1 }; }
    if !ao_cmp_inst(cmpv) { return false, ao_no_part(); }
    let cp0 = inst_pred(cmpv);
    if p == cp0 {
        let ok, ip = ao_match_int_part(op(cmpv, opno));
        return ok, ip;
    }
    var from: i64 = 0;
    if p == P_EQ && cp0 == P_ULT {
        if !ao_api_pow2(op(cmpv, 1)) || !bo(op(cmpv, 0), OP_XOR) { return false, ao_no_part(); }
    } else if p == P_NE && cp0 == P_UGT {
        if !ao_api_low_bit_mask(op(cmpv, 1)) || !bo(op(cmpv, 0), OP_XOR) { return false, ao_no_part(); }
    } else { return false, ao_no_part(); }
    let c = ap_cp(op(cmpv, 1));
    from = if p == P_NE { ap_popcount(c) } else { ap_countr_zero(c) };
    let i = op(cmpv, 0);
    return true, IntPart { from: op(i, opno), start: from, num: c.w as i64 - from };
}

// foldEqOfParts(Cmp0, Cmp1, IsAnd)
fn ao_fold_eq_of_parts(cmp0: i32, cmp1: i32, is_and: bool) -> i32 {
    if !has_one_use(cmp0) || !has_one_use(cmp1) { return -1; }
    let p = if is_and { P_EQ } else { P_NE };
    let ok0, l0a = ao_get_match_part(cmp0, 0, p);
    let ok1, r0a = ao_get_match_part(cmp0, 1, p);
    let ok2, l1a = ao_get_match_part(cmp1, 0, p);
    let ok3, r1a = ao_get_match_part(cmp1, 1, p);
    if !ok0 || !ok1 || !ok2 || !ok3 { return -1; }
    var l0 = l0a;
    var r0 = r0a;
    var l1 = l1a;
    var r1 = r1a;
    if l0.from != l1.from || r0.from != r1.from {
        if l0.from != r1.from || r0.from != l1.from { return -1; }
        let t = l1; l1 = r1; r1 = t;
    }
    if l0.start + l0.num != l1.start || r0.start + r0.num != r1.start {
        if l1.start + l1.num != l0.start || r1.start + r1.num != r0.start { return -1; }
        let t = l0; l0 = l1; l1 = t;
        let u = r0; r0 = r1; r1 = u;
    }
    let l = IntPart { from: l0.from, start: l0.start, num: l0.num + l1.num };
    let r = IntPart { from: r0.from, start: r0.start, num: r0.num + r1.num };
    let lv = ao_extract_int_part(l);
    let rv = ao_extract_int_part(r);
    return icb_icmp(p, lv, rv, "");
}

// foldAndOrOfICmpsWithConstEq(Cmp0, Cmp1, IsAnd, IsLogical, Builder, Q, I)
fn ao_fold_and_or_of_icmps_with_const_eq(cmp0: i32, cmp1: i32, is_and: bool, is_logical: bool, i: i32) -> i32 {
    let x = op(cmp0, 0);
    let c = op(cmp0, 1);
    if !is_constant(c) || !ao_not_undef_poison(c) || is_constant(x) { return -1; }
    let p0 = inst_pred(cmp0);
    if (is_and && p0 != P_EQ) || (!is_and && p0 != P_NE) { return -1; }
    var y: i32 = -1;
    var p1: i64 = 0;
    let ss = icc_samesign(cmp1);
    if op(cmp1, 1) == x { y = op(cmp1, 0); p1 = inst_pred(cmp1); }
    else if op(cmp1, 0) == x { y = op(cmp1, 1); p1 = pred_swapped(inst_pred(cmp1)); }
    else { return -1; }
    var sub = simplify_icmp(cp(p1, ss), y, c, sq_at(i), RECURSION_LIMIT);
    if sub < 0 {
        if !has_one_use(cmp1) { return -1; }
        sub = icb_icmp(p1, y, c, "");
    }
    if is_logical {
        let mdfrom = i;
        return if is_and { ao_logical_op(OP_AND, cmp0, sub, "", mdfrom) } else { ao_logical_op(OP_OR, cmp0, sub, "", mdfrom) };
    }
    return icb_binop(if is_and { OP_AND } else { OP_OR }, cmp0, sub, "");
}

// the MatchExactRangeCheck lambda of foldAndOrOfICmpsUsingRanges: ok, V, CR
fn ao_match_exact_range_check(icmp: i32) -> bool, i32, CRange {
    let none = rg_empty(1);
    if !has_apint(op(icmp, 1)) { return false, -1, none; }
    let c = ap_c(op(icmp, 1));
    let lhs = op(icmp, 0);
    let p = inst_pred(icmp);
    if icmp_is_equality(p) && one_use(lhs) && bo(lhs, OP_AND) && ao_api_neg_pow2(op(lhs, 1)) {
        let mask = ap_cp(op(lhs, 1));
        if ap_countr_zero(c) >= ap_countr_zero(mask) {
            var cr = rg_new(c, ap_sub(c, mask));
            if p == P_NE { cr = rg_inverse(cr); }
            return true, op(lhs, 0), cr;
        }
    }
    let cr = rg_exact_icmp(p, c);
    if m_add_like(lhs) && has_apint(op(lhs, 1)) {
        return true, op(lhs, 0), rg_subtract(cr, ap_c(op(lhs, 1)));
    }
    return true, lhs, cr;
}

// foldAndOrOfICmpsUsingRanges(ICmp1, ICmp2, IsAnd)
fn fold_and_or_of_icmps_using_ranges(icmp1: i32, icmp2: i32, is_and: bool) -> i32 {
    let ok1, v1, cr1a = ao_match_exact_range_check(icmp1);
    if !ok1 { return -1; }
    let ok2, v2, cr2a = ao_match_exact_range_check(icmp2);
    if !ok2 { return -1; }
    if v1 != v2 { return -1; }
    var cr1 = cr1a;
    var cr2 = cr2a;
    if is_and { cr1 = rg_inverse(cr1); cr2 = rg_inverse(cr2); }
    let ty = vals[v1].ty;
    var nv = v1;
    var okc, cr = rg_exact_union(cr1, cr2);
    if !okc {
        if !(has_one_use(icmp1) && has_one_use(icmp2)) || rg_is_wrapped(cr1) || rg_is_wrapped(cr2) { return -1; }
        let ld = ap_xor(cr1.lo, cr2.lo);
        let ud = ap_xor(ap_sub_u64(cr1.hi, 1), ap_sub_u64(cr2.hi, 1));
        let s1 = ap_sub(cr1.hi, cr1.lo);
        if !ap_is_pow2(ld) || !ap_eq(ld, ud) || !ap_eq(s1, ap_sub(cr2.hi, cr2.lo)) { return -1; }
        cr = if ap_ult(cr1.lo, cr2.lo) { cr1 } else { cr2 };
        nv = icb_and(nv, c_int_ap(ty, ap_not(ld)), "");
    }
    if is_and { cr = rg_inverse(cr); }
    let np, nc, off = rg_equivalent_icmp_off(cr);
    if !ap_is_zero(off) { nv = icb_add(nv, c_int_ap(ty, off), ""); }
    return icb_icmp(np, nv, c_int_ap(ty, nc), "");
}

// ---------------------------------------------------------------------------------------------
// FCmps

// InstCombiner::stripSignOnlyFPOps(Val)
fn ao_strip_sign_only_fp_ops(v0: i32) -> i32 {
    var v = v0;
    let a = m_fneg(v);
    if a >= 0 { v = a; }
    if m_intrinsic(v, IID_fabs) { v = op(v, 0); }
    if m_intrinsic(v, IID_copysign) { v = op(v, 0); }
    return v;
}

// fcmpToClassTest(Pred, F, LHS, Value *RHS): matchConstantFloat (m_APFloatAllowPoison), and LookThroughSrc is
// always true (the header's `LookThroughSrc = true` argument)
fn ao_fcmp_to_class_test_v(p: i64, fv: i32, l: i32, r: i32) -> i32, u64 {
    let c = m_apfloat_ap(r, true);
    if c < 0 { return -1, FCL_ALL; }
    let a, b = fcmp_to_class_test_lt(p, fv, l, c, true);
    return a, b;
}

// matchIsFiniteTest(Builder, LHS, RHS)
fn ao_match_is_finite_test(lhs: i32, rhs: i32) -> i32 {
    let pl = inst_pred(lhs);
    let pr = inst_pred(rhs);
    // matchIsNotNaN(PredL, LHS0, LHS1): fcmp ord x, 0
    if !(pl == P_ORD && m_any_zero_fp(op(lhs, 1))) { return -1; }
    // matchUnorderedInfCompare(PredR, RHS0, RHS1): fcmp u__ x, +/-inf
    if !(fpred_is_unordered(pr) && m_inf(op(rhs, 1))) { return -1; }
    return ao_fcmp_fmf(pr & P_ORD, op(rhs, 0), op(rhs, 1), ao_fmf_intersect(lhs, rhs), "");
}

// the sign bit index of an FP type (for APFloat negation)
fn ao_fp_sign_bit(t: i32) -> i64 {
    let k = ty_kind(t);
    if k == TK_HALF || k == TK_BFLOAT { return 15; }
    if k == TK_FLOAT { return 31; }
    if k == TK_DOUBLE { return 63; }
    if k == TK_X86_FP80 { return 79; }
    if k == TK_FP128 { return 127; }
    ic_not_ported("APFloat negation of a ppc_fp128 constant");
    return 0;
}
// LHSC->bitwiseIsEqual(neg(*RHSC)) for two scalar ConstantFPs of the same type
fn ao_fp_is_neg_of(a: i32, b: i32) -> bool {
    let sb = ao_fp_sign_bit(vals[b].ty);
    var lo = cint_lo(b);
    var hi = cint_hi(b);
    if sb < 64 { lo = lo ^ ((1 as u64) << sb); } else { hi = hi ^ ((1 as u64) << (sb - 64)); }
    return cint_lo(a) == lo && cint_hi(a) == hi;
}
fn ao_is_lt_or_le(p: i64) -> bool { p == P_OLT || p == P_OLE || p == P_FULT || p == P_FULE }

// foldLogicOfFCmps(LHS, RHS, IsAnd, IsLogicalSelect)
fn fold_logic_of_fcmps(lhs: i32, rhs: i32, is_and: bool, is_logical_select: bool) -> i32 {
    let l0 = op(lhs, 0);
    let l1 = op(lhs, 1);
    var r0 = op(rhs, 0);
    var r1 = op(rhs, 1);
    var pl = inst_pred(lhs);
    var pr = inst_pred(rhs);
    if l0 == r1 && r0 == l1 {
        pr = pred_swap_any(pr);
        let t = r0; r0 = r1; r1 = t;
    }
    if l0 == r0 && l1 == r1 {
        let code = if is_and { (pl & pr) as u32 } else { (pl | pr) as u32 };
        return ao_fcmp_value(code, l0, l1, ao_fmf_intersect(lhs, rhs));
    }
    if (pl == P_ORD && pr == P_ORD && is_and) || (pl == P_UNO && pr == P_UNO && !is_and) {
        if vals[l0].ty != vals[r0].ty { return -1; }
        if m_pos_zero_fp(l1) && m_pos_zero_fp(r1) {
            var y = r0;
            var fmf = inst_fmf(lhs) & inst_fmf(rhs);
            if is_logical_select {
                var nm: u8[>..] = [];
                ao_name_suffix(nm, y, ".fr");
                y = icb_freeze(y, nm);
                fmf &= ~(FMF_NNAN | FMF_NINF);
            }
            return ao_fcmp_fmf(pl, l0, y, fmf, "");
        }
    }
    if !is_logical_select && is_and && ao_strip_sign_only_fp_ops(l0) == ao_strip_sign_only_fp_ops(r0) {
        let left = ao_match_is_finite_test(lhs, rhs);
        if left >= 0 { return left; }
        let right = ao_match_is_finite_test(rhs, lhs);
        if right >= 0 { return right; }
    }
    if has_one_use(lhs) && has_one_use(rhs) {
        let cvr, cmr = ao_fcmp_to_class_test_v(pr, inst_func(rhs), r0, r1);
        if cvr >= 0 {
            let cvl, cml = ao_fcmp_to_class_test_v(pl, inst_func(lhs), l0, l1);
            if cvl == cvr {
                let cm = if is_and { cml & cmr } else { cml | cmr };
                let cmc = c_int(T_I32, cm as i64);
                let cty = vals[cvl].ty;
                return icb_intrinsic(IID_is_fpclass, [cty], [cvl, cmc], "");
            }
        }
    }
    if l0 == r0 && has_one_use(lhs) && has_one_use(rhs) && pred_swap_any(pl) == pr {
        var lc = m_apfloat_ap(l1, true);
        var rc = m_apfloat_ap(r1, true);
        if lc >= 0 && rc >= 0 && ao_fp_is_neg_of(lc, rc) {
            if ao_is_lt_or_le(if is_and { pr } else { pl }) {
                let t = lc; lc = rc; rc = t;
                let u = pl; pl = pr; pr = u;
            }
            if ao_is_lt_or_le(if is_and { pl } else { pr }) {
                var nf = inst_fmf(lhs);
                if !is_logical_select { nf |= inst_fmf(rhs); }
                let fa = ao_fabs(l0, nf);
                return ao_fcmp_fmf(pl, fa, ao_splat_if_vec(vals[l0].ty, lc), nf, "");
            }
        }
    }
    return -1;
}

// matchIsFPClassLikeFCmp(Op, ClassVal, ClassMask): ok, ClassVal, ClassMask
fn ao_match_is_fpclass_like_fcmp(v: i32) -> bool, i32, u64 {
    if !ao_fcmp_inst(v) || !has_one_use(v) { return false, -1, 0; }
    let cv, cm = ao_fcmp_to_class_test_v(inst_pred(v), inst_func(v), op(v, 0), op(v, 1));
    return cv >= 0, cv, cm;
}

// foldLogicOfIsFPClass(BO, Op0, Op1)
fn ao_fold_logic_of_is_fpclass(bop: i32, op0: i32, op1: i32) -> i32 {
    var cv0: i32 = -1;
    var cv1: i32 = -1;
    var cm0: u64 = 0;
    var cm1: u64 = 0;
    let lcls = one_use(op0) && m_intrinsic(op0, IID_is_fpclass) && ao_cint_u64(op(op0, 1));
    if lcls { cv0 = op(op0, 0); cm0 = ao_cint_val(op(op0, 1)); }
    let rcls = one_use(op1) && m_intrinsic(op1, IID_is_fpclass) && ao_cint_u64(op(op1, 1));
    if rcls { cv1 = op(op1, 0); cm1 = ao_cint_val(op(op1, 1)); }
    var ok0 = lcls;
    if !ok0 {
        let k, a, b = ao_match_is_fpclass_like_fcmp(op0);
        ok0 = k;
        if k { cv0 = a; cm0 = b; }
    }
    if !ok0 { return -1; }
    var ok1 = rcls;
    if !ok1 {
        let k, a, b = ao_match_is_fpclass_like_fcmp(op1);
        ok1 = k;
        if k { cv1 = a; cm1 = b; }
    }
    if !ok1 || cv0 != cv1 { return -1; }
    let o = iop(bop);
    var nm: u64 = 0;
    if o == OP_AND { nm = cm0 & cm1; } else if o == OP_OR { nm = cm0 | cm1; } else { nm = cm0 ^ cm1; }
    nm = nm & 0xFFFFFFFF;
    if lcls {
        set_op(op0, 1, c_int(vals[op(op0, 1)].ty, nm as i64));
        return ic_replace_inst_uses_with(bop, op0);
    }
    if rcls {
        set_op(op1, 1, c_int(vals[op(op1, 1)].ty, nm as i64));
        return ic_replace_inst_uses_with(bop, op1);
    }
    let nmc = c_int(T_I32, nm as i64);
    let cty = vals[cv0].ty;
    let nc = icb_intrinsic(IID_is_fpclass, [cty], [cv0, nmc], "");
    return ic_replace_inst_uses_with(bop, nc);
}

// canonicalizeConditionalNegationViaMathToSelect(I)
fn ao_canonicalize_conditional_negation_via_math_to_select(i: i32) -> i32 {
    if !(one_use(op(i, 0)) || one_use(op(i, 1))) { return -1; }
    let cond = m_sext(op(i, 1));
    if cond < 0 || !is_int_ty1(vals[cond].ty) { return -1; }
    let ad = op(i, 0);
    if !bo(ad, OP_ADD) { return -1; }
    var x: i32 = -1;
    if m_sext(op(ad, 0)) == cond { x = op(ad, 1); }
    else if m_sext(op(ad, 1)) == cond { x = op(ad, 0); }
    else { return -1; }
    var nm: u8[>..] = [];
    ao_name_suffix(nm, x, ".neg");
    let n = icb_neg(x, nm, false);
    return ic_new_select_unknown_prof(cond, n, x);
}

// m_SpecificFCmp(P, m_Value(X), m_AnyZeroFP()) -> X or -1
fn ao_m_specific_fcmp_zero(v: i32, p: i64) -> i32 {
    if ao_fcmp_inst(v) && inst_pred(v) == p && m_any_zero_fp(op(v, 1)) { op(v, 0) } else { -1 }
}

// reassociateFCmps(BO, Builder)
fn ao_reassociate_fcmps(bop: i32) -> i32 {
    let o = iop(bop);
    var op0 = op(bop, 0);
    var op1 = op(bop, 1);
    if ao_fcmp_inst(op1) && m_any_zero_fp(op(op1, 1)) { let t = op0; op0 = op1; op1 = t; }
    let nanp = if o == OP_AND { P_ORD } else { P_UNO };
    let x = ao_m_specific_fcmp_zero(op0, nanp);
    if x < 0 || !bo(op1, o) { return -1; }
    var b10 = op(op1, 0);
    var b11 = op(op1, 1);
    var y = ao_m_specific_fcmp_zero(b10, nanp);
    if y < 0 || vals[x].ty != vals[y].ty { let t = b10; b10 = b11; b11 = t; }
    y = ao_m_specific_fcmp_zero(b10, nanp);
    if y < 0 || vals[x].ty != vals[y].ty { return -1; }
    let nf = ao_fcmp_fmf(nanp, x, y, ao_fmf_intersect(op0, b10), "");
    return ic_new_binop(o, nf, b11);
}

// matchDeMorgansLaws(I, IC)
fn ao_match_demorgans_laws(i: i32) -> i32 {
    let o = iop(i);
    let fo = if o == OP_AND { OP_OR } else { OP_AND };
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    if one_use(op0) && one_use(op1) {
        let a = m_not(op0);
        let b = m_not(op1);
        if a >= 0 && b >= 0 && !is_free_to_invert(a, has_one_use(a)) && !is_free_to_invert(b, has_one_use(b)) {
            var nm: u8[>..] = [];
            ao_name_suffix(nm, i, ".demorgan");
            let ao = icb_binop(fo, a, b, nm);
            return ic_new_not(ao);
        }
    }
    if one_use(op0) && bo(op0, o) {
        let c = m_not(op1);
        if c >= 0 {
            var a: i32 = -1;
            var b = m_not(op(op0, 1));
            if b >= 0 { a = op(op0, 0); }
            else { b = m_not(op(op0, 0)); if b >= 0 { a = op(op0, 1); } }
            if b >= 0 {
                let fb = icb_binop(fo, b, c, "");
                return ic_new_binop(o, a, icb_not(fb, ""));
            }
        }
    }
    return -1;
}

// shouldOptimizeCast(CI)
fn ao_should_optimize_cast(ci: i32) -> bool {
    let src = op(ci, 0);
    if vals[src].ty == vals[ci].ty || is_constant(src) { return false; }
    if is_cast_inst(src) && ic_eliminable_cast_pair(src, ci) != 0 { return false; }
    return true;
}

// foldLogicCastConstant(Logic, Cast, IC)
fn ao_fold_logic_cast_constant(logic: i32, cast: i32) -> i32 {
    let c = op(logic, 1);
    if !is_constant(c) { return -1; }
    let lo = iop(logic);
    let dty = vals[logic].ty;
    let sty = vals[op(cast, 0)].ty;
    if one_use(cast) && is_inst_op(cast, OP_ZEXT) {
        let x = op(cast, 0);
        let tc, nneg = ao_lossless_trunc(c, sty, OP_ZEXT);
        if tc >= 0 {
            let nop = icb_binop(lo, x, tc, "");
            let z = ic_new_cast(OP_ZEXT, nop, dty);
            set_nneg(z, nneg && (op_flags(cast) & FL_NNEG) != 0);
            return z;
        }
    }
    if one_use(cast) {
        let x = m_sext_like(cast);
        if x >= 0 {
            let tc, unused = ao_lossless_trunc(c, sty, OP_SEXT);
            if tc >= 0 {
                let nop = icb_binop(lo, x, tc, "");
                return ic_new_cast(OP_SEXT, nop, dty);
            }
        }
    }
    return -1;
}

// the FoldBitwiseICmpZeroWithICmp lambda of foldCastedBitwiseLogic
fn ao_fold_bitwise_icmp_zero_with_icmp(i: i32, op0: i32, op1: i32) -> i32 {
    if !(one_use(op0) && bo(op0, OP_LSHR) && m_specific_int(op(op0, 1), (ty_sbits(op0) - 1) as u64)) { return -1; }
    if !(one_use(op1) && is_inst_op(op1, OP_ZEXT) && ao_cmp_inst(op(op1, 0))) { return -1; }
    let a = op(op0, 0);
    let il = icb_icmp(P_SLT, a, c_null(vals[a].ty), "");
    let ir = op(op1, 0);
    let bw = icb_binop(iop(i), il, ir, "");
    return ic_new_cast(OP_ZEXT, bw, vals[op0].ty);
}

// foldCastedBitwiseLogic(I)
fn fold_casted_bitwise_logic(i: i32) -> i32 {
    let lo = iop(i);
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    var r = ao_fold_bitwise_icmp_zero_with_icmp(i, op0, op1);
    if r >= 0 { return r; }
    r = ao_fold_bitwise_icmp_zero_with_icmp(i, op1, op0);
    if r >= 0 { return r; }
    if !is_cast_inst(op0) { return -1; }
    let dty = vals[i].ty;
    let sty = vals[op(op0, 0)].ty;
    if !is_int_or_int_vec(sty) { return -1; }
    r = ao_fold_logic_cast_constant(i, op0);
    if r >= 0 { return r; }
    if !is_cast_inst(op1) { return -1; }
    let co = iop(op0);
    if co != iop(op1) { return -1; }
    if !has_one_use(op0) && !has_one_use(op1) { return -1; }
    var x = m_zext_or_sext(op0);
    var y = m_zext_or_sext(op1);
    if x >= 0 && y >= 0 {
        let xb = ty_sbits(x);
        let yb = ty_sbits(y);
        if xb != yb {
            if !has_one_use(op0) || !has_one_use(op1) { return -1; }
            if xb < yb { x = icb_cast(co, x, vals[y].ty, ""); }
            else if yb < xb { y = icb_cast(co, y, vals[x].ty, ""); }
        }
        var nm: u8[>..] = [];
        nm.append(val_name(i));
        let nl = icb_binop(lo, x, y, nm);
        if lo == OP_OR && is_inst_op(nl, OP_OR) { set_disjoint(nl, op_disjoint(i)); }
        return ic_new_cast(co, nl, dty);
    }
    if sty != vals[op(op1, 0)].ty { return -1; }
    let s0 = op(op0, 0);
    let s1 = op(op1, 0);
    if ao_should_optimize_cast(op0) && ao_should_optimize_cast(op1) {
        var nm: u8[>..] = [];
        nm.append(val_name(i));
        let nop = icb_binop(lo, s0, s1, nm);
        return ic_new_cast(co, nop, dty);
    }
    return -1;
}

// foldAndToXor(I, Builder)
fn ao_fold_and_to_xor(i: i32) -> i32 {
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    // (A | B) & ~(A & B) --> A ^ B
    if bo(op0, OP_OR) {
        let a = op(op0, 0);
        let b = op(op0, 1);
        let n = m_not(op1);
        if n >= 0 && m_c_binop_both(n, OP_AND, a, b) { return ic_new_binop(OP_XOR, a, b); }
    }
    // (A | ~B) & (~A | B) --> ~(A ^ B) (four commuted forms)
    if has_one_use(op0) || has_one_use(op1) {
        if bo(op0, OP_OR) && bo(op1, OP_OR) {
            for k in 2 {
                let a = op(op0, k);
                let b = m_not(op(op0, 1 - k));
                if b < 0 { continue; }
                // m_c_Or(m_Not(m_Deferred(A)), m_Deferred(B))
                if (m_not_of(op(op1, 0), a) && op(op1, 1) == b) || (m_not_of(op(op1, 1), a) && op(op1, 0) == b) {
                    return ic_new_not(icb_xor(a, b, ""));
                }
                break;
            }
        }
    }
    return -1;
}

// foldOrToXor(I, Builder)
fn ao_fold_or_to_xor(i: i32) -> i32 {
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    if has_one_use(op0) || has_one_use(op1) {
        // (A & B) | ~(A | B) --> ~(A ^ B)
        if bo(op0, OP_AND) {
            let a = op(op0, 0);
            let b = op(op0, 1);
            let n = m_not(op1);
            if n >= 0 && m_c_binop_both(n, OP_OR, a, b) { return ic_new_not(icb_xor(a, b, "")); }
        }
    }
    if has_one_use(op0) || has_one_use(op1) {
        // (A ^ B) | ~(A | B) --> ~(A & B)
        if bo(op0, OP_XOR) {
            let a = op(op0, 0);
            let b = op(op0, 1);
            let n = m_not(op1);
            if n >= 0 && m_c_binop_both(n, OP_OR, a, b) { return ic_new_not(icb_and(a, b, "")); }
        }
    }
    // (A & ~B) | (~A & B) --> A ^ B
    if bo(op0, OP_AND) && bo(op1, OP_AND) {
        for k in 2 {
            let a = op(op0, k);
            let b = m_not(op(op0, 1 - k));
            if b < 0 { continue; }
            if (m_not_of(op(op1, 0), a) && op(op1, 1) == b) || (m_not_of(op(op1, 1), a) && op(op1, 0) == b) {
                return ic_new_binop(OP_XOR, a, b);
            }
            break;
        }
    }
    return -1;
}

// canNarrowShiftAmt(C, BitWidth)
fn ao_can_narrow_shift_amt(c: i32, bw: i64) -> bool {
    return ao_specific_int_icmp(c, P_ULT, ap_u64(bw as u64, ty_sbits(c)));
}

// narrowMaskedBinOp(And)
fn ao_narrow_masked_binop(an: i32) -> i32 {
    let op0 = op(an, 0);
    let op1 = op(an, 1);
    var c: i32 = -1;
    if one_use(op0) {
        if (bo(op0, OP_ADD) || bo(op0, OP_MUL) || bo(op0, OP_LSHR) || bo(op0, OP_SHL)) && op(op0, 0) == op1 && is_constant(op(op0, 1)) { c = op(op0, 1); }
        else if bo(op0, OP_SUB) && is_constant(op(op0, 0)) && op(op0, 1) == op1 { c = op(op0, 0); }
    }
    if c < 0 { return -1; }
    let x = m_zext(op1);
    if x < 0 || has_n_uses_or_more(op1, 3) { return -1; }
    let ty = vals[an].ty;
    if !ty_is_vector(ty) && !should_change_type(ty, vals[x].ty) { return -1; }
    let o = iop(op0);
    if o == OP_LSHR || o == OP_SHL {
        if !ao_can_narrow_shift_amt(c, ty_sbits(x)) { return -1; }
    }
    let nc = ce_cast(OP_TRUNC, c, vals[x].ty);
    let nb = if o == OP_SUB { icb_binop(o, nc, x, "") } else { icb_binop(o, x, nc, "") };
    return ic_new_cast(OP_ZEXT, icb_and(nb, x, ""), ty);
}

// m_SpecificInt_ICMP(Pred, Threshold): cst_pred_ty<icmp_pred_with_threshold> (poison lanes allowed)
fn ao_specific_int_icmp(v: i32, p: i64, thr: AP) -> bool {
    if v < 0 { return false; }
    let k = vals[v].kind;
    let ty = vals[v].ty;
    if k == VK_CINT {
        let s = if ty_is_vector(ty) { splat_value(v, false) } else { v };
        return ap_icmp(ci_ap(s), thr, p);
    }
    if !ty_is_vector(ty) || !is_constant(v) { return false; }
    let s = splat_value(v, false);
    if s >= 0 { if vals[s].kind == VK_CINT { return ap_icmp(ci_ap(s), thr, p); } }
    if ty_kind(ty) != TK_FVEC { return false; }
    var has = false;
    for i in ty_count(ty) {
        let e = agg_elem(v, i);
        if e < 0 { return false; }
        if vals[e].kind == VK_POISON { continue; }
        if vals[e].kind != VK_CINT || !ap_icmp(ci_ap(e), thr, p) { return false; }
        has = true;
    }
    return has;
}

// ---------------------------------------------------------------------------------------------
// foldComplexAndOrPatterns

// matchNotOrAnd(Op, m_Value(A), m_Value(B), m_Value(C), X): ok, X, A, B, C
fn ao_match_not_or_and_bind(v: i32, opc: i64, fopc: i64) -> bool, i32, i32, i32, i32 {
    if !bo(v, fopc) { return false, -1, -1, -1, -1; }
    for k in 2 {
        let x = op(v, k);
        let n = m_not(x);
        if n >= 0 && bo(n, opc) { return true, x, op(n, 0), op(n, 1), op(v, 1 - k); }
    }
    return false, -1, -1, -1, -1;
}
// matchNotOrAnd(Op, m_Specific(A), m_Specific(B), m_Specific(C), Dummy, CountUses)
fn ao_match_not_or_and(v: i32, opc: i64, fopc: i64, a: i32, b: i32, c: i32, count_uses: bool) -> bool {
    if count_uses && !has_one_use(v) { return false; }
    if !bo(v, fopc) { return false; }
    for k in 2 {
        let x = op(v, k);
        let n = m_not(x);
        if n >= 0 && bo(n, opc) && ((op(n, 0) == a && op(n, 1) == b) || (op(n, 0) == b && op(n, 1) == a)) && op(v, 1 - k) == c {
            return !count_uses || has_one_use(x);
        }
    }
    return false;
}
// m_OneUse(m_Not(m_OneUse(m_c_BinOp(Opc, m_Specific(A), m_Specific(B)))))
fn ao_one_use_not_of_one_use_binop(v: i32, opc: i64, a: i32, b: i32) -> bool {
    if !one_use(v) { return false; }
    let n = m_not(v);
    return n >= 0 && one_use(n) && m_c_binop_both(n, opc, a, b);
}
// m_c_BinOp(Opc, m_c_BinOp(Opc, m_Specific(A), m_Specific(B)), m_Specific(C))
fn ao_nested_binop3(v: i32, opc: i64, a: i32, b: i32, c: i32) -> bool {
    if !bo(v, opc) { return false; }
    for k in 2 {
        if m_c_binop_both(op(v, k), opc, a, b) && op(v, 1 - k) == c { return true; }
    }
    return false;
}

// foldComplexAndOrPatterns(I, Builder)
fn ao_fold_complex_and_or_patterns(i: i32) -> i32 {
    let opc = iop(i);
    let fopc = if opc == OP_AND { OP_OR } else { OP_AND };
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    let okm, x, a, b, c = ao_match_not_or_and_bind(op0, opc, fopc);
    if okm {
        if ao_match_not_or_and(op1, opc, fopc, a, c, b, true) {
            let xo = icb_xor(b, c, "");
            return if opc == OP_OR { ic_new_binop(OP_AND, xo, icb_not(a, "")) } else { ic_new_not(icb_and(xo, a, "")) };
        }
        if ao_match_not_or_and(op1, opc, fopc, b, c, a, true) {
            let xo = icb_xor(a, c, "");
            return if opc == OP_OR { ic_new_binop(OP_AND, xo, icb_not(b, "")) } else { ic_new_not(icb_and(xo, b, "")) };
        }
        if ao_one_use_not_of_one_use_binop(op1, opc, a, c) {
            return ic_new_not(icb_binop(opc, icb_binop(fopc, b, c, ""), a, ""));
        }
        if ao_one_use_not_of_one_use_binop(op1, opc, b, c) {
            return ic_new_not(icb_binop(opc, icb_binop(fopc, a, c, ""), b, ""));
        }
        if opc == OP_OR && has_one_use(op0) && one_use(op1) {
            let y = m_not(op1);
            if y >= 0 && bo(y, opc) {
                var hit = false;
                for k in 2 {
                    let xo = op(y, 1 - k);
                    if !hit && op(y, k) == c && m_c_binop_both(xo, OP_XOR, a, b) { hit = true; }
                }
                if hit {
                    let orv = op(x, 0);
                    return ic_new_not(icb_and(orv, y, ""));
                }
            }
        }
    }
    // (~A & B & C) | ... ; (~A | B | C) & ...
    var ok2 = false;
    var a2: i32 = -1;
    var b2: i32 = -1;
    var c2: i32 = -1;
    var x2: i32 = -1;
    if one_use(op0) && bo(op0, fopc) {
        // m_c_BinOp(Flipped, m_BinOp(Flipped, m_Value(B), m_Value(C)), m_Value(X, m_Not(m_Value(A))))
        for k in 2 {
            if ok2 { break; }
            let inner = op(op0, k);
            let nx = op(op0, 1 - k);
            if bo(inner, fopc) && m_not(nx) >= 0 { ok2 = true; b2 = op(inner, 0); c2 = op(inner, 1); x2 = nx; a2 = m_not(nx); }
        }
        // m_c_BinOp(Flipped, m_c_BinOp(Flipped, m_Value(C), m_Value(X, m_Not(m_Value(A)))), m_Value(B))
        for k in 2 {
            if ok2 { break; }
            let inner = op(op0, k);
            if !bo(inner, fopc) { continue; }
            for j in 2 {
                if ok2 { break; }
                let nx = op(inner, 1 - j);
                if m_not(nx) >= 0 { ok2 = true; c2 = op(inner, j); x2 = nx; a2 = m_not(nx); b2 = op(op0, 1 - k); }
            }
        }
    }
    if ok2 {
        let n = if one_use(op1) { m_not(op1) } else { -1 };
        if n >= 0 && (ao_nested_binop3(n, opc, a2, b2, c2) || ao_nested_binop3(n, opc, b2, c2, a2) || ao_nested_binop3(n, opc, a2, c2, b2)) {
            let xo = icb_xor(b2, c2, "");
            return if opc == OP_OR { ic_new_not(icb_or(xo, a2, "")) } else { ic_new_binop(OP_OR, xo, x2) };
        }
        if ao_one_use_not_of_one_use_binop(op1, opc, a2, b2) {
            return ic_new_binop(fopc, icb_binop(opc, c2, icb_not(b2, ""), ""), x2);
        }
        if ao_one_use_not_of_one_use_binop(op1, opc, a2, c2) {
            return ic_new_binop(fopc, icb_binop(opc, b2, icb_not(c2, ""), ""), x2);
        }
    }
    return -1;
}

// reassociateForUses(BO, Builder)
fn ao_reassociate_for_uses(b: i32) -> i32 {
    let opc = iop(b);
    for k in 2 {
        let inner = op(b, k);
        let z = op(b, 1 - k);
        if one_use(inner) && bo(inner, opc) && one_use(z) {
            let x = op(inner, 0);
            let y = op(inner, 1);
            if !is_constant(x) && !is_constant(y) && !is_constant(z) {
                if !has_one_use(x) { return ic_new_binop(opc, icb_binop(opc, y, z, ""), x); }
                if !has_one_use(y) { return ic_new_binop(opc, icb_binop(opc, x, z, ""), y); }
            }
            return -1;
        }
    }
    return -1;
}

// canonicalizeLogicFirst(I, Builder)
fn ao_canonicalize_logic_first(i: i32) -> i32 {
    let ty = vals[i].ty;
    let opc = iop(i);
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    if !(one_use(op0) && bo(op0, OP_ADD) && has_apint(op(op0, 1)) && has_apint(op1)) { return -1; }
    let x = op(op0, 0);
    let c2 = ap_c(op(op0, 1));
    let c = ap_c(op1);
    let w = ty_sbits(i);
    let last = w - ap_countr_zero(c2);
    if opc == OP_AND {
        if ap_countl_one(c) < last { return -1; }
    } else {
        if ap_countl_zero(c) < last { return -1; }
    }
    let nb = icb_binop(opc, x, c_int_ap(ty, c), "");
    let r = ic_new_binop(OP_ADD, nb, c_int_ap(ty, c2));
    copy_ir_flags(r, op0);
    return r;
}

// foldBinOpOfDisplacedShifts(I)
fn fold_binop_of_displaced_shifts(i: i32) -> i32 {
    let ty = vals[i].ty;
    let bw = ty_sbits(i);
    var c1: i32 = -1;
    var c2: i32 = -1;
    var addc: i32 = -1;
    var sham: i32 = -1;
    for k in 2 {
        let s0 = op(i, k);
        let s1 = op(i, 1 - k);
        if !ao_is_shift(s0) || !ao_imm(op(s0, 0)) { continue; }
        if !ao_is_shift(s1) || !ao_imm(op(s1, 0)) { continue; }
        let am = op(s1, 1);
        if !(bo(am, OP_ADD) || m_disjoint_or(am)) || op(am, 0) != op(s0, 1) || !ao_imm(op(am, 1)) { continue; }
        c1 = op(s0, 0); sham = op(s0, 1); c2 = op(s1, 0); addc = op(am, 1);
        break;
    }
    if c1 < 0 { return -1; }
    if !ao_specific_int_icmp(addc, P_ULT, ap_u64(bw as u64, bw)) { return -1; }
    let i0 = op(i, 0);
    let i1 = op(i, 1);
    if !is_inst(i0) || !is_inst(i1) { return -1; }
    let sho = iop(i0);
    if sho != iop(i1) { return -1; }
    if iop(i) == OP_ADD && sho != OP_SHL { return -1; }
    let nc = icb_binop(iop(i), c1, icb_binop(sho, c2, addc, ""), "");
    return ic_new_binop(sho, nc, sham);
}

// foldBitwiseLogicWithIntrinsics(I, Builder)
fn ao_fold_bitwise_logic_with_intrinsics(i: i32) -> i32 {
    if !has_one_use(op(i, 0)) { return -1; }
    let x = op(i, 0);
    if inst_iid(x) == 0 { return -1; }
    var y = op(i, 1);
    if inst_iid(y) == 0 { y = -1; }
    if y >= 0 && (!has_one_use(y) || inst_iid(x) != inst_iid(y)) { return -1; }
    let iid = inst_iid(x);
    if y < 0 && (!(iid == IID_bswap || iid == IID_bitreverse) || !has_apint(op(i, 1))) { return -1; }
    let ty = vals[i].ty;
    if iid == IID_fshl || iid == IID_fshr {
        if op(x, 2) != op(y, 2) { return -1; }
        let n0 = icb_binop(iop(i), op(x, 0), op(y, 0), "");
        let n1 = icb_binop(iop(i), op(x, 1), op(y, 1), "");
        return ic_new_intrinsic(iid as i64, [ty], [n0, n1, op(x, 2)]);
    }
    if iid == IID_bswap || iid == IID_bitreverse {
        var other: i32 = -1;
        if y >= 0 { other = op(y, 0); }
        else {
            let rc = ap_c(op(i, 1));
            other = c_int_ap(ty, if iid == IID_bswap { ap_byte_swap(rc) } else { ap_reverse_bits(rc) });
        }
        let n0 = icb_binop(iop(i), op(x, 0), other, "");
        return ic_new_intrinsic(iid as i64, [ty], [n0]);
    }
    return -1;
}

// simplifyAndOrWithOpReplaced(V, Op, RepOp, SimplifyOnly, IC, Depth)
recursive fn ao_simplify_and_or_with_op_replaced(v: i32, opv: i32, rep: i32, simplify_only0: bool, depth: i64) -> i32 {
    if opv == rep { return -1; }
    if v == opv { return rep; }
    if !is_binop_inst(v) || !is_logic_op(iop(v)) || depth >= 3 { return -1; }
    var simplify_only = simplify_only0;
    if !has_one_use(v) { simplify_only = true; }
    var n0 = ao_simplify_and_or_with_op_replaced(op(v, 0), opv, rep, simplify_only, depth + 1);
    var n1 = ao_simplify_and_or_with_op_replaced(op(v, 1), opv, rep, simplify_only, depth + 1);
    if n0 < 0 && n1 < 0 { return -1; }
    if n0 < 0 { n0 = op(v, 0); }
    if n1 < 0 { n1 = op(v, 1); }
    let r = simplify_binop(iop(v), n0, n1, sq_at(v), RECURSION_LIMIT);
    if r >= 0 { return r; }
    if simplify_only { return -1; }
    return icb_binop(iop(v), n0, n1, "");
}

// reassociateBooleanAndOr(LHS, X, Y, I, IsAnd, RHSIsLogical)
fn ao_reassociate_boolean_and_or(lhs: i32, x: i32, y: i32, i: i32, is_and: bool, rhs_is_logical: bool) -> i32 {
    let opc = if is_and { OP_AND } else { OP_OR };
    var folded: i32 = -1;
    let r1 = fold_boolean_and_or(lhs, x, i, is_and, false);
    if r1 >= 0 {
        folded = if rhs_is_logical { ao_logical_op(opc, r1, y, "", -1) } else { icb_binop(opc, r1, y, "") };
    } else {
        let r2 = fold_boolean_and_or(lhs, y, i, is_and, false);
        if r2 >= 0 {
            folded = if rhs_is_logical { ao_logical_op(opc, x, r2, "", -1) } else { icb_binop(opc, x, r2, "") };
        }
    }
    if folded >= 0 && is_select_inst(folded) && ic_fn_has_entry_count(ic_fn) {
        ic_not_ported("setExplicitlyUnknownBranchWeightsIfProfiled in reassociateBooleanAndOr");
    }
    return folded;
}

// foldAndOrOfSelectUsingImpliedCond(Op, SI, IsAnd) (InstCombineSelect.cpp, with
// simplifyNestedSelectsUsingImpliedCond)
fn fold_and_or_of_select_using_implied_cond(opv: i32, si: i32, is_and: bool) -> i32 {
    if vals[op(si, 0)].ty != vals[opv].ty { return -1; }
    kb_cxt = -1;
    let imp = implied_condition_v(opv, op(si, 0), is_and, 0);
    if imp < 0 { return -1; }
    let v = if imp == 1 { op(si, 1) } else { op(si, 2) };
    let ty = vals[opv].ty;
    return ic_new_select_unknown_prof(opv, if is_and { v } else { c_bool_ty(ty, true) }, if is_and { c_bool_ty(ty, false) } else { v });
}

// matchSimpleRecurrence(I, PN, Start, Step) (ValueTracking.cpp): ok, PN, Start, Step
fn ao_match_simple_recurrence(i: i32) -> bool, i32, i32, i32 {
    var pn: i32 = -1;
    if is_phi_inst(op(i, 0)) { pn = op(i, 0); } else if is_phi_inst(op(i, 1)) { pn = op(i, 1); }
    if pn < 0 || nops(pn) != 2 { return false, -1, -1, -1; }
    for k in 2 {
        let o = phi_value(pn, k);
        if is_binop_inst(o) && nops(o) >= 2 {
            let l = op(o, 0);
            let r = op(o, 1);
            if l != pn && r != pn { continue; }
            if o != i { return false, -1, -1, -1; }
            return true, pn, phi_value(pn, 1 - k), if l == pn { r } else { l };
        }
    }
    return false, -1, -1, -1;
}

// ---------------------------------------------------------------------------------------------
// bswap / bitreverse recognition: collectBitParts and recognizeBSwapOrBitReverseIdiom
// (llvm/lib/Transforms/Utils/Local.cpp)

// A memoized BitPart (BPS map entry): ok = the optional has a value; provenance bits in bp_pool[ix, ix + w)
struct BPEnt { v: i32, ok: bool, provider: i32, ix: i32, w: i32 }
var bp_ents: BPEnt[>..<];
var bp_pool: i8[>..<];
var bp_found_root: bool = false;
let BP_MAX_DEPTH = 48;

fn bp_find(v: i32) -> i64 {
    for k in bp_ents.len { if bp_ents[k].v == v { return k; } }
    return -1;
}
fn bp_alloc(w: i64) -> i32 {
    let ix = bp_pool.len as i32;
    for k in w { bp_pool.push(-1); }
    return ix;
}
fn bp_set(e: i64, provider: i32, ix: i32, w: i64) {
    bp_ents[e].ok = true;
    bp_ents[e].provider = provider;
    bp_ents[e].ix = ix;
    bp_ents[e].w = w as i32;
}
fn bp_get(e: i64, k: i64) -> i8 { bp_pool[bp_ents[e].ix as i64 + k] }

// collectBitParts(V, MatchBSwaps, MatchBitReversals, BPS, Depth, FoundRoot): the entry index
recursive fn bp_collect(v: i32, mb: bool, mr: bool, depth: i64) -> i64 {
    let f = bp_find(v);
    if f >= 0 { return f; }
    let e = bp_ents.len;
    bp_ents.push(BPEnt { v: v, ok: false, provider: -1, ix: -1, w: 0 });
    let bw = ty_sbits(v);
    if bw > 128 { return e; }
    if depth == BP_MAX_DEPTH { return e; }
    if is_inst(v) {
        if bo(v, OP_OR) {
            let a = bp_collect(op(v, 0), mb, mr, depth + 1);
            if !bp_ents[a].ok || bp_ents[a].provider < 0 { return e; }
            let b = bp_collect(op(v, 1), mb, mr, depth + 1);
            if !bp_ents[b].ok || bp_ents[a].provider != bp_ents[b].provider { return e; }
            let ix = bp_alloc(bw);
            for k in bw {
                let pa = bp_get(a, k);
                let pb = bp_get(b, k);
                if pa != -1 && pb != -1 && pa != pb { return e; }
                bp_pool[ix as i64 + k] = if pa == -1 { pb } else { pa };
            }
            bp_set(e, bp_ents[a].provider, ix, bw);
            return e;
        }
        if ao_logical_shift(v) && has_apint(op(v, 1)) {
            let sh = ap_c(op(v, 1));
            if ap_uge_u64(sh, bw as u64) { return e; }
            let s = ap_zext64(sh) as i64;
            if !mr && s % 8 != 0 { return e; }
            let r = bp_collect(op(v, 0), mb, mr, depth + 1);
            if !bp_ents[r].ok { return e; }
            let ix = bp_alloc(bw);
            if iop(v) == OP_SHL {
                for k in bw { bp_pool[ix as i64 + k] = if k < s { -1 } else { bp_get(r, k - s) }; }
            } else {
                for k in bw { bp_pool[ix as i64 + k] = if k < bw - s { bp_get(r, k + s) } else { -1 }; }
            }
            bp_set(e, bp_ents[r].provider, ix, bw);
            return e;
        }
        if bo(v, OP_AND) && has_apint(op(v, 1)) {
            let m = ap_c(op(v, 1));
            if !mr && ap_popcount(m) % 8 != 0 { return e; }
            let r = bp_collect(op(v, 0), mb, mr, depth + 1);
            if !bp_ents[r].ok { return e; }
            let ix = bp_alloc(bw);
            for k in bw { bp_pool[ix as i64 + k] = if ap_get_bit(m, k) { bp_get(r, k) } else { -1 }; }
            bp_set(e, bp_ents[r].provider, ix, bw);
            return e;
        }
        if is_inst_op(v, OP_ZEXT) {
            let x = op(v, 0);
            let r = bp_collect(x, mb, mr, depth + 1);
            if !bp_ents[r].ok { return e; }
            let nbw = ty_sbits(x);
            let ix = bp_alloc(bw);
            for k in bw { bp_pool[ix as i64 + k] = if k < nbw { bp_get(r, k) } else { -1 }; }
            bp_set(e, bp_ents[r].provider, ix, bw);
            return e;
        }
        if is_inst_op(v, OP_TRUNC) {
            let r = bp_collect(op(v, 0), mb, mr, depth + 1);
            if !bp_ents[r].ok { return e; }
            let ix = bp_alloc(bw);
            for k in bw { bp_pool[ix as i64 + k] = bp_get(r, k); }
            bp_set(e, bp_ents[r].provider, ix, bw);
            return e;
        }
        if m_intrinsic(v, IID_bitreverse) {
            let r = bp_collect(op(v, 0), mb, mr, depth + 1);
            if !bp_ents[r].ok { return e; }
            let ix = bp_alloc(bw);
            for k in bw { bp_pool[ix as i64 + (bw - 1) - k] = bp_get(r, k); }
            bp_set(e, bp_ents[r].provider, ix, bw);
            return e;
        }
        if m_intrinsic(v, IID_bswap) {
            let r = bp_collect(op(v, 0), mb, mr, depth + 1);
            if !bp_ents[r].ok { return e; }
            let byw = bw / 8;
            let ix = bp_alloc(bw);
            for bi in byw {
                let ofs = bi * 8;
                for k in 8 { bp_pool[ix as i64 + (bw - 8 - ofs) + k] = bp_get(r, ofs + k); }
            }
            bp_set(e, bp_ents[r].provider, ix, bw);
            return e;
        }
        if (m_intrinsic(v, IID_fshl) || m_intrinsic(v, IID_fshr)) && has_apint(op(v, 2)) {
            var md = ap_zext64(ap_urem(ap_c(op(v, 2)), ap_u64(bw as u64, ty_sbits(op(v, 2))))) as i64;
            if m_intrinsic(v, IID_fshr) { md = bw - md; }
            if !mr && md % 8 != 0 { return e; }
            let l = bp_collect(op(v, 0), mb, mr, depth + 1);
            if !bp_ents[l].ok || bp_ents[l].provider < 0 { return e; }
            let r = bp_collect(op(v, 1), mb, mr, depth + 1);
            if !bp_ents[r].ok || bp_ents[l].provider != bp_ents[r].provider { return e; }
            let sr = bw - md;
            let ix = bp_alloc(bw);
            for k in sr { bp_pool[ix as i64 + k + md] = bp_get(l, k); }
            for k in md { bp_pool[ix as i64 + k] = bp_get(r, k + sr); }
            bp_set(e, bp_ents[l].provider, ix, bw);
            return e;
        }
    }
    if bp_found_root { return e; }
    bp_found_root = true;
    let ix = bp_alloc(bw);
    for k in bw { bp_pool[ix as i64 + k] = k as i8; }
    bp_set(e, v, ix, bw);
    return e;
}

fn bp_correct_for_bswap(from0: i64, to0: i64, bw0: i64) -> bool {
    if from0 % 8 != to0 % 8 { return false; }
    let from = from0 >> 3;
    let to = to0 >> 3;
    let bw = bw0 >> 3;
    return from == bw - to - 1;
}
fn bp_correct_for_bitreverse(from: i64, to: i64, bw: i64) -> bool { from == bw - to - 1 }

// CastInst::CreateIntegerCast(V, Ty, isSigned=false, Name, InsertBefore)
fn bp_integer_cast_before(v: i32, ty: i32, name: const u8[:], before: i32) -> i32 {
    let sb = ty_sbits(v);
    let db = ty_scalar_bits(ty);
    let o = if sb == db { OP_BITCAST } else if sb > db { OP_TRUNC } else { OP_ZEXT };
    let c = ic_new_cast(o, v, ty);
    set_name(c, name);
    ic_insert_before_pos(c, before);
    return c;
}

// recognizeBSwapOrBitReverseIdiom(I, MatchBSwaps, MatchBitReversals, InsertedInsts): the inserted
// instructions are in bp_inserted
var bp_inserted: i32[>..<];
fn recognize_bswap_or_bitreverse_idiom(i: i32, mb: bool, mr: bool) -> bool {
    bp_inserted.resize(0);
    if !bo(i, OP_OR) && !m_intrinsic(i, IID_fshl) && !m_intrinsic(i, IID_fshr) && !m_intrinsic(i, IID_bswap) { return false; }
    if !mb && !mr { return false; }
    let ity = vals[i].ty;
    if !is_int_or_int_vec(ity) || ty_scalar_bits(ity) == 1 || ty_scalar_bits(ity) > 128 { return false; }
    bp_found_root = false;
    bp_ents.resize(0);
    bp_pool.resize(0);
    let r = bp_collect(i, mb, mr, 0);
    if !bp_ents[r].ok { return false; }
    var n = bp_ents[r].w as i64;
    var dty = ity;
    if bp_get(r, n - 1) == -1 {
        while n > 0 && bp_get(r, n - 1) == -1 { n -= 1; }
        if n == 0 { return false; }
        dty = ao_ty_with_bits(ity, n);
    }
    let dbw = n;
    if dbw > ty_scalar_bits(ity) { return false; }
    var dmask = ap_ones(dbw);
    var ok_bswap = mb && dbw % 16 == 0;
    var ok_brev = mr;
    var k: i64 = 0;
    while k < dbw && (ok_bswap || ok_brev) {
        let p = bp_get(r, k) as i64;
        if p == -1 {
            dmask = ap_clear_bit(dmask, k);
        } else {
            ok_bswap = ok_bswap && bp_correct_for_bswap(p, k, dbw);
            ok_brev = ok_brev && bp_correct_for_bitreverse(p, k, dbw);
        }
        k += 1;
    }
    var intrin: i64 = 0;
    if ok_bswap { intrin = IID_bswap; } else if ok_brev { intrin = IID_bitreverse; } else { return false; }
    var provider = bp_ents[r].provider;
    if dty != vals[provider].ty {
        let t = bp_integer_cast_before(provider, dty, "trunc", i);
        bp_inserted.push(t);
        provider = t;
    }
    var res = ic_new_intrinsic(intrin, [dty], [provider]);
    set_name(res, "rev");
    ic_insert_before_pos(res, i);
    bp_inserted.push(res);
    if !ap_is_all_ones(dmask) {
        let m = ic_new_binop(OP_AND, res, c_int_ap(dty, dmask));
        set_name(m, "mask");
        ic_insert_before_pos(m, i);
        bp_inserted.push(m);
        res = m;
    }
    if ity != vals[res].ty {
        let z = bp_integer_cast_before(res, ity, "zext", i);
        bp_inserted.push(z);
    }
    return true;
}

// matchBSwapOrBitReverse(I, MatchBSwaps, MatchBitReversals)
fn match_bswap_or_bitreverse(i: i32, mb: bool, mr: bool) -> i32 {
    if !recognize_bswap_or_bitreverse_idiom(i, mb, mr) { return -1; }
    let last = bp_inserted[bp_inserted.len - 1];
    bp_inserted.resize(bp_inserted.len - 1);
    inst_remove_from_parent(last);
    let dl = inst_get_md(i, 0);
    for x in bp_inserted {
        if dl >= 0 { inst_set_md(x, 0, dl); } else { inst_erase_md(x, 0); }
        icw_push(x);
    }
    return last;
}

// ---------------------------------------------------------------------------------------------
// Funnel shifts and concats

// m_Neg(m_Specific(x))
fn ao_is_neg_of(v: i32, x: i32) -> bool { m_neg(v) == x && x >= 0 }
// m_And(m_Value(X), m_SpecificInt(Mask)) -> X or -1
fn ao_and_mask(v: i32, mask: u64) -> i32 { if bo(v, OP_AND) && m_specific_int(op(v, 1), mask) { op(v, 0) } else { -1 } }

// the matchShiftAmount lambda of convertOrOfShiftsToFunnelShift
fn ao_match_shift_amount(l: i32, r: i32, w: i64, shv0: i32, shv1: i32, orv: i32) -> i32 {
    if has_apint_poison(l) && has_apint_poison(r) {
        let li = ap_cp(l);
        let ri = ap_cp(r);
        if ap_ult_u64(li, w as u64) && ap_ult_u64(ri, w as u64) && ap_eq_u64(ap_add(li, ri), w as u64) {
            return c_int_ap(vals[l].ty, li);
        }
    }
    let lw = ty_sbits(l);
    if is_constant(l) && is_constant(r) && ao_specific_int_icmp(l, P_ULT, ap_u64(w as u64, lw)) &&
       ao_specific_int_icmp(r, P_ULT, ap_u64(w as u64, lw)) && m_specific_int_ap(ce_binop(OP_ADD, l, r, 0), w as u64) {
        return ao_merge_undefs_with(l, r);
    }
    if one_use(r) && bo(r, OP_SUB) && m_specific_int(op(r, 0), w as u64) && op(r, 1) == l {
        let k = ao_kb(l, orv);
        return if ap_ult_u64(ap_not(k.z), w as u64) { l } else { -1 };
    }
    if shv0 != shv1 { return -1; }
    if w <= 0 || (w & (w - 1)) != 0 { return -1; }
    let mask = (w - 1) as u64;
    let x = ao_and_mask(l, mask);
    if x >= 0 {
        let rn = ao_and_mask(r, mask);
        if rn >= 0 && ao_is_neg_of(rn, x) { return x; }
    }
    let rn = ao_and_mask(r, mask);
    if rn >= 0 && ao_is_neg_of(rn, l) { return l; }
    let lz = m_zext(l);
    if lz >= 0 {
        let x2 = ao_and_mask(lz, mask);
        if x2 >= 0 {
            let r1 = ao_and_mask(r, mask);
            if r1 >= 0 {
                let ng = m_neg(r1);
                if ng >= 0 {
                    let z = m_zext(ng);
                    if z >= 0 && ao_and_mask(z, mask) == x2 { return l; }
                }
            }
            let rz = m_zext(r);
            if rz >= 0 {
                let r2 = ao_and_mask(rz, mask);
                if r2 >= 0 && ao_is_neg_of(r2, x2) { return l; }
            }
        }
    }
    return -1;
}

// convertOrOfShiftsToFunnelShift(Or): ok, IID, the three arguments
fn convert_or_of_shifts_to_funnel_shift(orv: i32) -> bool, i64, i32, i32, i32 {
    let w = ty_sbits(orv);
    var or0 = op(orv, 0);
    var or1 = op(orv, 1);
    if !is_inst(or0) || !is_inst(or1) { return false, 0, -1, -1, -1; }
    var is_fshl = true;
    var a0: i32 = -1;
    var a1: i32 = -1;
    var a2: i32 = -1;
    if is_binop_inst(or0) && is_binop_inst(or1) {
        if !(one_use(or0) && ao_logical_shift(or0)) || !(one_use(or1) && ao_logical_shift(or1)) || iop(or0) == iop(or1) {
            return false, 0, -1, -1, -1;
        }
        var shv0 = op(or0, 0);
        var sha0 = op(or0, 1);
        var shv1 = op(or1, 0);
        var sha1 = op(or1, 1);
        if iop(or0) == OP_LSHR {
            let t = or0; or0 = or1; or1 = t;
            let u = shv0; shv0 = shv1; shv1 = u;
            let s = sha0; sha0 = sha1; sha1 = s;
        }
        var sha = ao_match_shift_amount(sha0, sha1, w, shv0, shv1, orv);
        if sha < 0 {
            sha = ao_match_shift_amount(sha1, sha0, w, shv0, shv1, orv);
            is_fshl = false;
        }
        if sha < 0 { return false, 0, -1, -1, -1; }
        a0 = shv0; a1 = shv1; a2 = sha;
    } else if is_inst_op(or0, OP_ZEXT) || is_inst_op(or1, OP_ZEXT) {
        if !is_inst_op(or1, OP_ZEXT) { let t = or0; or0 = or1; or1 = t; }
        if !(one_use(or0) && bo(or0, OP_SHL) && has_apint(op(or0, 1))) { return false, 0, -1, -1, -1; }
        let zhigh = op(or0, 0);
        let zhsa = ap_c(op(or0, 1));
        let low = m_zext(or1);
        let high = m_zext(zhigh);
        if low < 0 || high < 0 { return false, 0, -1, -1, -1; }
        let hs = ty_sbits(high);
        let ls = ty_sbits(low);
        if ap_ult_u64(zhsa, ls as u64) || ap_ugt_u64(zhsa, (w - hs) as u64) { return false, 0, -1, -1, -1; }
        var u = vals[zhigh].first_use;
        while u >= 0 {
            let us = uses[u].user;
            u = uses[u].next;
            if !bo(us, OP_OR) { continue; }
            var x = op(us, 0);
            var y = op(us, 1);
            if !is_inst_op(y, OP_ZEXT) { let t = x; x = y; y = t; }
            if !(bo(x, OP_SHL) && op(x, 0) == or1 && has_apint(op(x, 1))) || y != zhigh || !dt_value_dominates_inst(us, orv) { continue; }
            let zlsa = ap_c(op(x, 1));
            if !ap_eq_u64(ap_add(zlsa, zhsa), w as u64) { continue; }
            drop_poison_generating_flags(us);
            drop_poison_generating_flags(x);
            a0 = us; a1 = us; a2 = c_int_ap(vals[or0].ty, zhsa);
            break;
        }
    }
    if a0 < 0 { return false, 0, -1, -1, -1; }
    return true, if is_fshl { IID_fshl } else { IID_fshr }, a0, a1, a2;
}

// matchFunnelShift(Or, IC)
fn ao_match_funnel_shift(orv: i32) -> i32 {
    let ok, iid, a0, a1, a2 = convert_or_of_shifts_to_funnel_shift(orv);
    if !ok { return -1; }
    return ic_new_intrinsic(iid, [vals[orv].ty], [a0, a1, a2]);
}

// matchOrConcat(Or, Builder)
fn ao_match_or_concat(orv: i32) -> i32 {
    var op0 = op(orv, 0);
    var op1 = op(orv, 1);
    let ty = vals[orv].ty;
    let w = ty_sbits(orv);
    if (w & 1) != 0 { return -1; }
    let hw = w / 2;
    if !is_inst_op(op0, OP_ZEXT) { let t = op0; op0 = op1; op1 = t; }
    if !(one_use(op0) && is_inst_op(op0, OP_ZEXT)) { return -1; }
    let lsrc = op(op0, 0);
    if !(one_use(op1) && bo(op1, OP_SHL) && has_apint(op(op1, 1))) { return -1; }
    let shv = op(op1, 0);
    if !(one_use(shv) && is_inst_op(shv, OP_ZEXT)) { return -1; }
    let usrc = op(shv, 0);
    if !ap_eq_u64(ap_c(op(op1, 1)), hw as u64) || vals[lsrc].ty != vals[usrc].ty || ty_sbits(lsrc) != hw { return -1; }
    for pass in 2 {
        let id: i32 = if pass == 0 { IID_bswap } else { IID_bitreverse };
        if m_intrinsic(lsrc, id) && m_intrinsic(usrc, id) {
            let lo = op(usrc, 0);
            let hi = op(lsrc, 0);
            let nl = icb_zext(lo, ty, "");
            var nu = icb_zext(hi, ty, "");
            nu = icb_shl(nu, c_int_ty(ty, hw as u64), "");
            let b = icb_disjoint_or(nl, nu, "");
            return icb_intrinsic(id, [ty], [b], "");
        }
    }
    let x = ao_sext_or_self(lsrc);
    let xb = ty_sbits(x) - 1;
    // m_SExtOrSelf(m_AShr(m_Specific(X), m_SpecificInt(XBW - 1)))
    var ok = false;
    let us = m_sext(usrc);
    if us >= 0 && bo(us, OP_ASHR) && op(us, 0) == x && m_specific_int(op(us, 1), xb as u64) { ok = true; }
    if !ok && bo(usrc, OP_ASHR) && op(usrc, 0) == x && m_specific_int(op(usrc, 1), xb as u64) { ok = true; }
    if ok { return icb_sext(x, ty, ""); }
    return -1;
}

// areInverseVectorBitmasks(C1, C2)
fn ao_are_inverse_vector_bitmasks(c1: i32, c2: i32) -> bool {
    let n = ty_count(vals[c1].ty);
    for k in n {
        let e1 = agg_elem(c1, k);
        let e2 = agg_elem(c2, k);
        if e1 < 0 || e2 < 0 { return false; }
        if !((m_zero(e1) && m_all_ones(e2)) || (m_zero(e2) && m_all_ones(e1))) { return false; }
    }
    return true;
}

// peekThroughBitcast(V, OneUseOnly)
fn ao_peek_through_bitcast(v: i32, one_use_only: bool) -> i32 {
    if is_inst_op(v, OP_BITCAST) && (!one_use_only || has_one_use(v)) { return op(v, 0); }
    return v;
}

// getSelectCondition(A, B, ABIsTheSame)
fn ao_get_select_condition(a0: i32, b: i32, ab_same: bool) -> i32 {
    var a = a0;
    let ty = vals[a].ty;
    if !is_int_or_int_vec(ty) || !is_int_or_int_vec(vals[b].ty) { return -1; }
    if if ab_same { a == b } else { m_not_of(b, a) } {
        if is_int_ty1(ty) { return a; }
        a = ao_peek_through_bitcast(a, false);
        if is_int_or_int_vec(vals[a].ty) {
            let nsb = ao_signbits(a, -1);
            if nsb == ty_sbits(a) && nsb <= ty_scalar_bits(ty) {
                return icb_trunc(a, cmp_result_ty(vals[a].ty), "");
            }
        }
        return -1;
    }
    if ab_same { return -1; }
    if is_constant(a) && is_constant(b) {
        if a == ce_not(b) && ao_signbits(a, -1) == ty_scalar_bits(ty) {
            return icb_zext_or_trunc(a, cmp_result_ty(ty), "");
        }
    }
    let cond = m_sext(a);
    if cond >= 0 && is_int_ty1(vals[cond].ty) {
        let sb = m_sext(b);
        if sb >= 0 && m_not_of(sb, cond) { return cond; }
        if one_use(b) {
            var nb = m_not(b);
            if nb >= 0 {
                nb = ao_peek_through_bitcast(nb, true);
                if m_sext(nb) == cond { return cond; }
            }
        }
    }
    if !ty_is_vector(ty) { return -1; }
    if bo(a, OP_XOR) && is_constant(op(a, 1)) && bo(b, OP_XOR) && is_constant(op(b, 1)) {
        let c2 = m_sext(op(a, 0));
        if c2 >= 0 && m_sext(op(b, 0)) == c2 && is_int_ty1(vals[c2].ty) && ao_are_inverse_vector_bitmasks(op(a, 1), op(b, 1)) {
            let ac = ce_cast(OP_TRUNC, op(a, 1), cmp_result_ty(ty));
            return icb_xor(c2, ac, "");
        }
    }
    return -1;
}

// matchSelectFromAndOr(A, B, C, D, InvertFalseVal)
fn ao_match_select_from_and_or(a0: i32, b: i32, c0: i32, d0: i32, invert_false_val: bool) -> i32 {
    let orig = vals[a0].ty;
    let a = ao_peek_through_bitcast(a0, true);
    let c = ao_peek_through_bitcast(c0, true);
    let cond = ao_get_select_condition(a, c, invert_false_val);
    if cond < 0 { return -1; }
    var selty = vals[a].ty;
    let cty = vals[cond].ty;
    if ty_is_vector(cty) {
        let elts = ty_count(cty);
        let sel_bits = if ty_is_vector(selty) { ty_count(selty) * ty_scalar_bits(selty) } else { ty_bits(selty) };
        let et = ty_int(sel_bits / elts);
        selty = ty_vector(et, elts, ty_kind(cty) == TK_SVEC);
    }
    let bb = icb_cast(OP_BITCAST, b, selty, "");
    var d = d0;
    if invert_false_val { d = icb_not(d, ""); }
    let bd = icb_cast(OP_BITCAST, d, selty, "");
    let s = icb_select(cond, bb, bd, "", -1);
    return icb_cast(OP_BITCAST, s, orig, "");
}

// foldAndOrOfICmpEqConstantAndICmp(LHS, RHS, IsAnd, IsLogical, Builder)
fn ao_fold_and_or_of_icmp_eq_constant_and_icmp(lhs: i32, rhs: i32, is_and: bool, is_logical: bool) -> i32 {
    let l0 = op(lhs, 0);
    let r0 = op(rhs, 0);
    let r1 = op(rhs, 1);
    let lp = if is_and { pred_inverse(inst_pred(lhs)) } else { inst_pred(lhs) };
    let rp = if is_and { pred_inverse(inst_pred(rhs)) } else { inst_pred(rhs) };
    if lp != P_EQ || !has_apint_poison(op(lhs, 1)) || !is_int_or_int_vec(vals[l0].ty) || !(has_one_use(lhs) || has_one_use(rhs)) { return -1; }
    let ci = ap_cp(op(lhs, 1));
    var other: i32 = -1;
    if rp == P_ULT && ao_match_rhs_op(r1, l0, ci) { other = r0; }
    else if rp == P_UGT && ao_match_rhs_op(r0, l0, ci) { other = r1; }
    else { return -1; }
    if is_logical { other = icb_freeze(other, ""); }
    let s = icb_sub(l0, c_int_ap(vals[l0].ty, ap_inc(ci)), "");
    return icb_icmp(if is_and { P_ULT } else { P_UGE }, s, other, "");
}
// the MatchRHSOp lambda
fn ao_match_rhs_op(v: i32, l0: i32, ci: AP) -> bool {
    if bo(v, OP_ADD) && op(v, 0) == l0 && has_apint_poison(op(v, 1)) && ap_eq(ap_cp(op(v, 1)), ap_neg(ci)) { return true; }
    return ap_is_zero(ci) && v == l0;
}

// ---------------------------------------------------------------------------------------------
// foldAndOrOfICmps / foldBooleanAndOr

// foldAndOrOfICmps(LHS, RHS, I, IsAnd, IsLogical)
fn fold_and_or_of_icmps(lhs: i32, rhs: i32, i: i32, is_and: bool, is_logical: bool) -> i32 {
    var pl = inst_pred(lhs);
    let pr = inst_pred(rhs);
    var l0 = op(lhs, 0);
    let r0 = op(rhs, 0);
    var l1 = op(lhs, 1);
    let r1 = op(rhs, 1);
    let hlc = has_apint(l1);
    let hrc = has_apint(r1);
    if ao_predicates_foldable(pl, pr) {
        if l0 == r1 && l1 == r0 {
            pl = pred_swapped(pl);
            let t = l0; l0 = l1; l1 = t;
        }
        if l0 == r0 && l1 == r1 {
            let code = if is_and { ao_icmp_code(pl) & ao_icmp_code(pr) } else { ao_icmp_code(pl) | ao_icmp_code(pr) };
            let signed = pred_is_signed(inst_pred(lhs)) || pred_is_signed(pr);
            return ao_new_icmp_value(code, signed, l0, l1);
        }
    }
    var v = ao_fold_and_or_of_icmp_eq_constant_and_icmp(lhs, rhs, is_and, is_logical);
    if v >= 0 { return v; }
    v = ao_fold_and_or_of_icmp_eq_constant_and_icmp(rhs, lhs, is_and, false);
    if v >= 0 { return v; }
    v = ao_fold_and_or_of_icmps_with_const_eq(lhs, rhs, is_and, is_logical, i);
    if v >= 0 { return v; }
    v = ao_fold_and_or_of_icmps_with_const_eq(rhs, lhs, is_and, false, i);
    if v >= 0 {
        if is_logical && icc_samesign(rhs) && !use_empty(rhs) {
            icc_set_samesign(rhs, false);
            icw_add(rhs);
        }
        return v;
    }
    v = ao_fold_is_power_of2_or_zero(lhs, rhs, is_and);
    if v >= 0 { return v; }
    v = ao_fold_is_power_of2_or_zero(rhs, lhs, is_and);
    if v >= 0 { return v; }
    if !is_logical {
        v = ao_simplify_range_check(lhs, rhs, !is_and);
        if v >= 0 { return v; }
        v = ao_simplify_range_check(rhs, lhs, !is_and);
        if v >= 0 { return v; }
    }
    if is_and && !is_logical {
        v = ao_fold_signed_truncation_check(lhs, rhs, i);
        if v >= 0 { return v; }
    }
    v = ao_fold_is_power_of2(lhs, rhs, is_and);
    if v >= 0 { return v; }
    v = ao_fold_power_of2_and_shifted_mask(lhs, rhs, is_and);
    if v >= 0 { return v; }
    if !is_logical {
        v = ao_fold_unsigned_underflow_check(lhs, rhs, is_and, i);
        if v >= 0 { return v; }
        v = ao_fold_unsigned_underflow_check(rhs, lhs, is_and, i);
        if v >= 0 { return v; }
    }
    let want = if is_and { P_EQ } else { P_NE };
    if pl == want && pl == pr && m_zero_int(l1) && m_zero_int(r1) && vals[l0].ty == vals[r0].ty && (!is_logical || ao_not_poison(r0)) {
        let nor = icb_or(l0, r0, "");
        return icb_icmp(pl, nor, c_null(vals[nor].ty), "");
    }
    if pl == want && pl == pr && m_all_ones(l1) && m_all_ones(r1) && vals[l0].ty == vals[r0].ty && (!is_logical || ao_not_poison(r0)) {
        let nand = icb_and(l0, r0, "");
        return icb_icmp(pl, nand, c_all_ones(vals[l0].ty), "");
    }
    if !is_logical {
        v = ao_fold_and_or_of_icmps_with_pow2_and_with_zero(lhs, rhs, is_and, i);
        if v >= 0 { return v; }
    }
    if !hlc || !hrc { return -1; }
    let lc = ap_c(l1);
    let rc = ap_c(r1);
    if pl == want && pl == pr && has_one_use(lhs) && has_one_use(rhs) {
        var vv: i32 = -1;
        var andc = ap_zero(1);
        var smallc = ap_zero(1);
        var bigc = ap_zero(1);
        var found = false;
        let tr = m_trunc(r0);
        if tr >= 0 && bo(l0, OP_AND) && op(l0, 0) == tr && has_apint(op(l0, 1)) {
            vv = tr; andc = ap_c(op(l0, 1)); smallc = rc; bigc = lc; found = true;
        } else {
            let tl = m_trunc(l0);
            if tl >= 0 && bo(r0, OP_AND) && op(r0, 0) == tl && has_apint(op(r0, 1)) {
                vv = tl; andc = ap_c(op(r0, 1)); smallc = lc; bigc = rc; found = true;
            }
        }
        if found {
            let bbs = bigc.w as i64;
            let sbs = smallc.w as i64;
            let low = ap_low_bits(bbs, sbs);
            if ap_is_zero(ap_and(low, andc)) && ap_is_zero(ap_and(low, bigc)) {
                let nand = icb_and(vv, c_int_ap(vals[vv].ty, ap_or(low, andc)), "");
                let n = ap_or(ap_zext(smallc, bbs), bigc);
                return icb_icmp(pl, nand, c_int_ap(vals[nand].ty, n), "");
            }
        }
    }
    let sbl, tisl = is_sign_bit_check(pl, lc);
    let sbr, tisr = is_sign_bit_check(pr, rc);
    if sbl && sbr && (has_one_use(rhs) || has_one_use(lhs)) {
        if is_and {
            if tisl && !tisr && bo(l0, OP_OR) && m_c_binop_both(r0, OP_AND, op(l0, 0), op(l0, 1)) {
                return ao_is_neg(icb_xor(op(l0, 0), op(l0, 1), ""), "");
            }
            if !tisl && tisr && bo(l0, OP_AND) && m_c_binop_both(r0, OP_OR, op(l0, 0), op(l0, 1)) {
                return ao_is_neg(icb_xor(op(l0, 0), op(l0, 1), ""), "");
            }
        } else {
            if tisl && !tisr && bo(l0, OP_AND) && m_c_binop_both(r0, OP_OR, op(l0, 0), op(l0, 1)) {
                return ao_is_not_neg(icb_xor(op(l0, 0), op(l0, 1), ""), "");
            }
            if !tisl && tisr && bo(l0, OP_OR) && m_c_binop_both(r0, OP_AND, op(l0, 0), op(l0, 1)) {
                return ao_is_not_neg(icb_xor(op(l0, 0), op(l0, 1), ""), "");
            }
        }
    }
    let nonnorm = if is_and { P_NE } else { P_EQ };
    if l0 == r0 && pl == pr && pl == nonnorm && !func_has_fn_attr(inst_func(i), AK_NoImplicitFloat) &&
       has_one_use(lhs) && has_one_use(rhs) && bo(l0, OP_AND) && has_apint(op(l0, 1)) {
        let x = ao_elementwise_bitcast(op(l0, 0));
        if x >= 0 {
            let fty = ty_scalar(vals[x].ty);
            let mc = ap_c(op(l0, 1));
            if icc_is_ieee_like(fty) && ap_eq(mc, icc_fp_exponent_mask(fty)) &&
               ((ap_is_zero(lc) && ap_eq(rc, mc)) || (ap_is_zero(rc) && ap_eq(lc, mc))) {
                return icb_is_fpclass(x, if is_and { FCL_NORMAL } else { ~FCL_NORMAL & FCL_ALL });
            }
        }
    }
    return fold_and_or_of_icmps_using_ranges(lhs, rhs, is_and);
}

// foldBooleanAndOr(LHS, RHS, I, IsAnd, IsLogical)
fn fold_boolean_and_or(lhs: i32, rhs: i32, i: i32, is_and: bool, is_logical: bool) -> i32 {
    if !is_int_ty1(vals[lhs].ty) { return -1; }
    var v = ao_fold_log_op_of_masked_icmps(lhs, rhs, is_and, is_logical, i);
    if v >= 0 { return v; }
    if ao_cmp_inst(lhs) && ao_cmp_inst(rhs) {
        v = fold_and_or_of_icmps(lhs, rhs, i, is_and, is_logical);
        if v >= 0 { return v; }
    }
    if ao_fcmp_inst(lhs) && ao_fcmp_inst(rhs) {
        v = fold_logic_of_fcmps(lhs, rhs, is_and, is_logical);
        if v >= 0 { return v; }
    }
    v = ao_fold_eq_of_parts(lhs, rhs, is_and);
    if v >= 0 { return v; }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// visitOr helpers

// foldOrOfInversions(I, Builder)
fn ao_fold_or_of_inversions(i: i32) -> i32 {
    let a = op(i, 0);
    let b = op(i, 1);
    if !bo(a, OP_AND) || !bo(b, OP_AND) { return -1; }
    let c1 = op(a, 0);
    let c2 = op(a, 1);
    let c3 = op(b, 0);
    let c4 = op(b, 1);
    if ao_is_known_inversion(c1, c3) && ao_is_known_inversion(c2, c4) { return icb_xor(c1, c4, ""); }
    if ao_is_known_inversion(c1, c4) && ao_is_known_inversion(c2, c3) { return icb_xor(c1, c3, ""); }
    return -1;
}

// matchSubIntegerPackFromVector(V, Vec, VecOffset, Mask, DL): ok, Vec, VecOffset; the mask is ao_pack_mask
var ao_pack_mask: bool[>..<];
fn ao_mask_resize(n: i64) {
    while ao_pack_mask.len < n { ao_pack_mask.push(false); }
    if ao_pack_mask.len > n { ao_pack_mask.resize(n); }
}
// m_ExtractElt(m_Value(Vec), m_ConstantInt(Idx)): ok, Vec, Idx
fn ao_m_extract_elt_ci(v: i32) -> bool, i32, u64 {
    if !is_inst_op(v, OP_EXTRACTELEMENT) || !ao_cint_u64(op(v, 1)) { return false, -1, 0; }
    return true, op(v, 0), ao_cint_val(op(v, 1));
}
fn ao_match_sub_integer_pack_from_vector(v: i32) -> bool, i32, i64 {
    // m_ShlOrSelf(m_ZExtOrSelf(m_ExtractElt(m_Value(Vec), m_ConstantInt(VecIdx))), ShlAmt)
    var okx = false;
    var vec: i32 = -1;
    var vidx: u64 = 0;
    var shl_amt: u64 = 0;
    var inner: i32 = -1;
    if bo(v, OP_SHL) {
        if ao_cint_u64(op(v, 1)) { shl_amt = ao_cint_val(op(v, 1)); inner = op(v, 0); }
    } else { inner = v; }
    if inner >= 0 {
        let z = m_zext(inner);
        if z >= 0 {
            let k1, vv, ii = ao_m_extract_elt_ci(z);
            if k1 { okx = true; vec = vv; vidx = ii; }
        }
        if !okx {
            let k2, vv, ii = ao_m_extract_elt_ci(inner);
            if k2 { okx = true; vec = vv; vidx = ii; }
        }
    }
    if okx {
        let vty = vals[vec].ty;
        if ty_kind(vty) != TK_FVEC { return false, -1, 0; }
        let et = ty_elem(vty);
        if !ty_is_int(et) { return false, -1, 0; }
        let ebw = ty_bits(et);
        let tbw = ty_bits(vals[v].ty);
        if tbw % ebw != 0 || (shl_amt as i64) % ebw != 0 { return false, -1, 0; }
        let tew = tbw / ebw;
        let shl_elt = (shl_amt as i64) / ebw;
        let mi = if !dl_big_endian { shl_elt } else { tew - shl_elt - 1 };
        let off = (vidx as i64) - mi;
        ao_mask_resize(tew);
        ao_pack_mask[mi] = true;
        return true, vec, off;
    }
    if !is_op(v, OP_BITCAST) || !is_inst(op(v, 0)) { return false, -1, 0; }
    let src = op(v, 0);
    let sty = vals[src].ty;
    if ty_kind(sty) != TK_FVEC { return false, -1, 0; }
    ao_mask_resize(ty_count(sty));
    if is_inst_op(src, OP_SHUFFLEVECTOR) {
        let cv = op(src, 1);
        if !is_constant(cv) { return false, -1, 0; }
        let vv = op(src, 0);
        let vty = vals[vv].ty;
        if ty_kind(vty) != TK_FVEC { return false, -1, 0; }
        let nve = ty_count(vty);
        var found = false;
        var off: i64 = 0;
        let ii = inst_of(src);
        let n = insts[ii].naux as i64;
        for idx in n {
            let m = ints[insts[ii].aux + idx] as i64;
            if m < 0 { return false, -1, 0; }
            if m >= nve {
                let ce = agg_elem(cv, m - nve);
                if ce < 0 || vals[ce].kind != VK_CINT || !is_null_value(ce) { return false, -1, 0; }
                continue;
            }
            if found {
                if off + idx != m { return false, -1, 0; }
            } else {
                if m < idx { return false, -1, 0; }
                off = m - idx;
                found = true;
            }
            ao_pack_mask[idx] = true;
        }
        return found, vv, off;
    }
    if !is_inst_op(src, OP_INSERTELEMENT) || !m_zero(op(src, 1)) || !ao_cint_u64(op(src, 2)) { return false, -1, 0; }
    let vv = op(src, 0);
    if ty_kind(vals[vv].ty) != TK_FVEC { return false, -1, 0; }
    let ins = ao_cint_val(op(src, 2)) as i64;
    let already = ao_pack_mask[ins];
    for k in ao_pack_mask.len { ao_pack_mask[k] = true; }
    if !already { ao_pack_mask[ins] = false; }
    return true, vv, 0;
}

// foldIntegerPackFromVector(I, Builder, DL)
fn ao_fold_integer_pack_from_vector(i: i32) -> i32 {
    ao_pack_mask.resize(0);
    let ok1, lv, lo = ao_match_sub_integer_pack_from_vector(op(i, 0));
    if !ok1 { return -1; }
    let ok2, rv, ro = ao_match_sub_integer_pack_from_vector(op(i, 1));
    if !ok2 { return -1; }
    if lv != rv || lo != ro { return -1; }
    let lty = vals[lv].ty;
    let zi = ty_count(lty) as i32;
    var mask: i32[>..<] = [];
    for k in ao_pack_mask.len { mask.push(if ao_pack_mask[k] { (lo + k) as i32 } else { zi }); }
    if is_constant(lv) { ic_not_ported("CreateShuffleVector of constants (foldIntegerPackFromVector)"); }
    let rty = ty_vector(ty_elem(lty), mask.len, false);
    let s = create_inst(OP_SHUFFLEVECTOR, rty, [lv, c_null(lty)]);
    let ii = inst_of(s);
    insts[ii].aux = ints.len as i32;
    insts[ii].naux = mask.len as i32;
    for m in mask { ints.push(m); }
    var nm: u8[>..] = [];
    ao_name_suffix(nm, i, ".v");
    let mv = icb_insert(s, nm);
    return ic_new_cast(OP_BITCAST, mv, vals[i].ty);
}

// matchZExtedSubInteger(V, Int, Mask, Offset, IsShlNUW, IsShlNSW): ok, Int, Mask, Offset, NUW, NSW
fn ao_match_zexted_sub_integer(v: i32) -> bool, i32, AP, u64, bool, bool {
    let z = ap_zero(1);
    if !(one_use(v) && bo(v, OP_SHL) && ao_cint_u64(op(v, 1))) { return false, -1, z, 0, false, false; }
    let shl_amt = ao_cint_val(op(v, 1));
    let nuw = op_nuw(v);
    let nsw = op_nsw(v);
    let s0 = op(v, 0);
    if !(one_use(s0) && is_inst_op(s0, OP_ZEXT)) { return false, -1, z, 0, false, false; }
    let zo = op(s0, 0);
    var masked = zo;
    var has_mask = false;
    var smc = z;
    if one_use(zo) && bo(zo, OP_AND) && has_apint(op(zo, 1)) { masked = op(zo, 0); smc = ap_c(op(zo, 1)); has_mask = true; }
    var iv = masked;
    var lshr_amt: u64 = 0;
    if one_use(masked) && bo(masked, OP_LSHR) && ao_cint_u64(op(masked, 1)) { iv = op(masked, 0); lshr_amt = ao_cint_val(op(masked, 1)); }
    if lshr_amt > shl_amt { return false, -1, z, 0, false, false; }
    let off = shl_amt - lshr_amt;
    let mask = if has_mask { ap_shl(smc, lshr_amt as i64) } else { ap_bits_from(ty_sbits(iv), lshr_amt as i64) };
    return true, iv, mask, off, nuw, nsw;
}

// foldIntegerRepackThroughZExt(Lhs, Rhs, Builder)
fn ao_fold_integer_repack_through_zext(l: i32, r: i32) -> i32 {
    let ok1, li, lm, lo, lnuw, lnsw = ao_match_zexted_sub_integer(l);
    if !ok1 { return -1; }
    let ok2, ri, rm, ro, rnuw, rnsw = ao_match_zexted_sub_integer(r);
    if !ok2 { return -1; }
    if li != ri || lo != ro { return -1; }
    let mask = ap_or(lm, rm);
    let dty = vals[l].ty;
    var n1: u8[>..] = [];
    ao_name_suffix(n1, li, ".mask");
    let a = icb_and(li, c_int_ap(vals[li].ty, mask), n1);
    var n2: u8[>..] = [];
    ao_name_suffix(n2, li, ".zext");
    let zx = icb_zext(a, dty, n2);
    let res = icb_shl_nw(zx, c_int_ty(dty, lo), "", lnuw && rnuw, lnsw && rnsw);
    ic_take_name(res, l);
    return res;
}

// DecomposedBitMaskMul and matchBitmaskMul(V)
struct BMM { x: i32, factor: AP, mask: AP, nuw: bool, nsw: bool }
fn ao_match_bitmask_mul(v: i32) -> bool, BMM {
    let z = ap_zero(1);
    let none = BMM { x: -1, factor: z, mask: z, nuw: false, nsw: false };
    if !is_inst(v) { return false, none; }
    if bo(v, OP_MUL) && bo(op(v, 0), OP_AND) && has_apint(op(op(v, 0), 1)) && has_apint(op(v, 1)) {
        let mask = ap_c(op(op(v, 0), 1));
        let mc = ap_c(op(v, 1));
        if ap_is_zero(mc) || ap_is_zero(mask) { return false, none; }
        return true, BMM { x: op(op(v, 0), 0), factor: mc, mask: mask, nuw: op_nuw(v), nsw: op_nsw(v) };
    }
    if is_select_inst(v) && has_apint(op(v, 1)) && has_apint(op(v, 2)) {
        let ok, x, dmask, dc, dp = ao_decompose_bit_test(op(v, 0), true, false, true);
        if !ok { return false, none; }
        if vals[x].ty != vals[v].ty { return false, none; }
        var eqz = ap_c(op(v, 1));
        var nez = ap_c(op(v, 2));
        if dp == P_NE { let t = eqz; eqz = nez; nez = t; }
        if !ap_is_zero(eqz) || ap_is_zero(nez) { return false, none; }
        if !ap_is_pow2(dmask) || ap_is_zero(dmask) { return false, none; }
        if !ap_is_zero(ap_urem(nez, dmask)) { return false, none; }
        return true, BMM { x: x, factor: ap_udiv(nez, dmask), mask: dmask, nuw: false, nsw: false };
    }
    return false, none;
}

// foldBitmaskMul(Op0, Op1, Builder)
fn ao_fold_bitmask_mul(op0: i32, op1: i32) -> i32 {
    let ok1, d1 = ao_match_bitmask_mul(op1);
    if !ok1 { return -1; }
    let ok0, d0 = ao_match_bitmask_mul(op0);
    if !ok0 { return -1; }
    if d0.x == d1.x && !ap_intersects(d0.mask, d1.mask) && ap_eq(d0.factor, d1.factor) {
        let xt = vals[d0.x].ty;
        let na = icb_and(d0.x, c_int_ap(xt, ap_add(d0.mask, d1.mask)), "");
        return icb_mul_nw(na, c_int_ap(vals[na].ty, d1.factor), "", d0.nuw && d1.nuw, d0.nsw && d1.nsw);
    }
    return -1;
}

// foldDisjointOr(LHS, RHS)
fn fold_disjoint_or(l: i32, r: i32) -> i32 {
    let a = ao_fold_bitmask_mul(l, r);
    if a >= 0 { return a; }
    let b = ao_fold_integer_repack_through_zext(l, r);
    if b >= 0 { return b; }
    return -1;
}

// reassociateDisjointOr(LHS, RHS)
fn ao_reassociate_disjoint_or(l: i32, r: i32) -> i32 {
    if one_use(r) && m_disjoint_or(r) {
        let x = op(r, 0);
        let y = op(r, 1);
        let a = fold_disjoint_or(l, x);
        if a >= 0 { return icb_disjoint_or(a, y, ""); }
        let b = fold_disjoint_or(l, y);
        if b >= 0 { return icb_disjoint_or(b, x, ""); }
    }
    if one_use(l) && m_disjoint_or(l) {
        let x = op(l, 0);
        let y = op(l, 1);
        let a = fold_disjoint_or(x, r);
        if a >= 0 { return icb_disjoint_or(a, y, ""); }
        let b = fold_disjoint_or(y, r);
        if b >= 0 { return icb_disjoint_or(b, x, ""); }
    }
    return -1;
}

// foldOrUnsignedUMulOverflowICmp(I, Builder, DL)
fn ao_fold_or_unsigned_umul_overflow_icmp(i: i32) -> i32 {
    for k in 2 {
        let ev = op(i, k);
        let cm = op(i, 1 - k);
        if icc_ev_index(ev) != 1 { continue; }
        let wov = op(ev, 0);
        if !m_intrinsic(wov, IID_umul_with_overflow) || !has_apint(op(wov, 1)) { continue; }
        if !(one_use(cm) && ao_cmp_inst(cm) && inst_pred(cm) == P_UGT) { continue; }
        let e0 = op(cm, 0);
        if icc_ev_index(e0) != 0 || op(e0, 0) != wov || !has_apint(op(cm, 1)) { continue; }
        let c1 = ap_c(op(wov, 1));
        let c2 = ap_c(op(cm, 1));
        if ap_is_zero(c1) { return -1; }
        let x = op(wov, 0);
        return icb_icmp(P_UGT, x, c_int_ap(vals[x].ty, ap_udiv(c2, c1)), "");
    }
    return -1;
}

// FoldOrOfSelectSmaxToAbs(I, Builder)
fn ao_fold_or_of_select_smax_to_abs(i: i32) -> i32 {
    for k in 2 {
        let sel = op(i, k);
        let mx = op(i, 1 - k);
        if !(one_use(mx) && m_intrinsic(mx, IID_smax) && m_zero_int(op(mx, 1))) { continue; }
        let x = op(mx, 0);
        if is_select_inst(sel) {
            let c = op(sel, 0);
            if ao_cmp_inst(c) && op(c, 0) == x && m_zero_int(op(c, 1)) {
                if inst_pred(c) == P_SGT && m_zero_int(op(sel, 1)) && ao_is_neg_of(op(sel, 2), x) {
                    return icb_binary_intrinsic(IID_abs, x, c_bool_ty(T_I1, false), "");
                }
                if inst_pred(c) == P_SLT && ao_is_neg_of(op(sel, 1), x) && m_zero_int(op(sel, 2)) {
                    return icb_binary_intrinsic(IID_abs, x, c_bool_ty(T_I1, false), "");
                }
            }
        }
        return -1;
    }
    return -1;
}

// m_c_LogicalAnd(m_Not(m_Value(C)), m_Value(X)): ok, C, X
fn ao_m_c_logical_and_not(v: i32) -> bool, i32, i32 {
    if !m_logical(v, true) { return false, -1, -1; }
    let a = lg_a;
    let b = lg_b;
    let na = m_not(a);
    if na >= 0 { return true, na, b; }
    let nb = m_not(b);
    if nb >= 0 { return true, nb, a; }
    return false, -1, -1;
}

// FoldOrOfLogicalAnds(Op0, Op1)
fn ao_fold_or_of_logical_ands(op0: i32, op1: i32) -> i32 {
    // (C && A) || (!C && B) => select C, A, B
    let ok1, c, b = ao_m_c_logical_and_not(op1);
    if ok1 {
        let a = m_c_logical_with(op0, true, c);
        if a >= 0 {
            let s0 = is_select_inst(op0);
            let s1 = is_select_inst(op1);
            var cc = c;
            let may_freeze = s0 && s1 && m_not_of(op(op1, 1), op(op0, 1));
            if may_freeze { cc = icb_freeze(cc, ""); }
            if m_logical(op0, true) && lg_a == cc && s0 {
                return ic_new_select_md_all(cc, a, b, op0);
            } else if s1 && ao_logical_and_not_first(op1) {
                let ns = ic_new_select_md_all(cc, a, b, op1);
                cu_swap_prof_metadata(ns);
                return ns;
            } else {
                return ic_new_select_unknown_prof(cc, a, b);
            }
        }
    }
    // (!C && A) || (C && B) => select C, B, A
    let ok2, c2, a2 = ao_m_c_logical_and_not(op0);
    if ok2 {
        let b2 = m_c_logical_with(op1, true, c2);
        if b2 >= 0 {
            let s0 = is_select_inst(op0);
            let s1 = is_select_inst(op1);
            var cc = c2;
            let may_freeze = s0 && s1 && m_not_of(op(op0, 1), op(op1, 1));
            if may_freeze { cc = icb_freeze(cc, ""); }
            if s0 && ao_logical_and_not_first(op0) {
                let ns = ic_new_select_md_all(cc, b2, a2, op0);
                cu_swap_prof_metadata(ns);
                return ns;
            } else if m_logical(op1, true) && lg_a == cc && s1 {
                return ic_new_select_md_all(cc, b2, a2, op1);
            } else {
                return ic_new_select_unknown_prof(cc, b2, a2);
            }
        }
    }
    return -1;
}
// m_LogicalAnd(m_Not(m_Value()), m_Value())
fn ao_logical_and_not_first(v: i32) -> bool { m_logical(v, true) && m_not(lg_a) >= 0 }
// SelectInst::Create(C, S1, S2, Name, InsertBefore, MDFrom): copies all metadata of MDFrom
fn ic_new_select_md_all(c: i32, t: i32, f: i32, mdfrom: i32) -> i32 {
    let s = ic_new_select(c, t, f);
    let ii = inst_of(mdfrom);
    let n = insts[ii].nmd;
    for k in n {
        let kind = md_att[insts[inst_of(mdfrom)].md + 2 * k];
        let node = md_att[insts[inst_of(mdfrom)].md + 2 * k + 1];
        inst_set_md(s, kind, node);
    }
    return s;
}

// ---------------------------------------------------------------------------------------------
// visitXor helpers

// m_c_BinOp(Opc, m_Value(A), m_Not(m_Value(B))) of v (instruction opc): ok, A, B
fn ao_c_binop_val_not(v: i32, opc: i64) -> bool, i32, i32 {
    if !bo(v, opc) { return false, -1, -1; }
    let b0 = m_not(op(v, 1));
    if b0 >= 0 { return true, op(v, 0), b0; }
    let b1 = m_not(op(v, 0));
    if b1 >= 0 { return true, op(v, 1), b1; }
    return false, -1, -1;
}
// m_c_BinOp(Opc, m_Not(m_Deferred(A)), m_Deferred(B))
fn ao_c_binop_not_a_b(v: i32, opc: i64, a: i32, b: i32) -> bool {
    if !bo(v, opc) { return false; }
    return (m_not_of(op(v, 0), a) && op(v, 1) == b) || (m_not_of(op(v, 1), a) && op(v, 0) == b);
}

// foldXorToXor(I, Builder)
fn ao_fold_xor_to_xor(i: i32) -> i32 {
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    // (A & B) ^ (A | B) -> A ^ B
    for k in 2 {
        let an = op(i, k);
        if bo(an, OP_AND) {
            let a = op(an, 0);
            let b = op(an, 1);
            if m_c_binop_both(op(i, 1 - k), OP_OR, a, b) { return ic_new_binop(OP_XOR, a, b); }
        }
    }
    // (A | ~B) ^ (~A | B) -> A ^ B
    {
        let ok, a, b = ao_c_binop_val_not(op0, OP_OR);
        if ok && ao_c_binop_not_a_b(op1, OP_OR, a, b) { return ic_new_binop(OP_XOR, a, b); }
    }
    // (A & ~B) ^ (~A & B) -> A ^ B
    {
        let ok, a, b = ao_c_binop_val_not(op0, OP_AND);
        if ok && ao_c_binop_not_a_b(op1, OP_AND, a, b) { return ic_new_binop(OP_XOR, a, b); }
    }
    if !has_one_use(op0) && !has_one_use(op1) { return -1; }
    let n = m_not(op1);
    if bo(op0, OP_OR) && n >= 0 && m_c_binop_both(n, OP_AND, op(op0, 0), op(op0, 1)) {
        return ic_new_not(icb_xor(op(op0, 0), op(op0, 1), ""));
    }
    if bo(op0, OP_AND) && n >= 0 && m_c_binop_both(n, OP_OR, op(op0, 0), op(op0, 1)) {
        return ic_new_not(icb_xor(op(op0, 0), op(op0, 1), ""));
    }
    return -1;
}

// Value::replaceUsesWithIf(New, [New](Use &U) { return U.getUser() != New; })
fn ao_replace_uses_except_user(v: i32, nv: i32) {
    var u = vals[v].first_use;
    while u >= 0 {
        let nx = uses[u].next;
        if uses[u].user != nv { use_set(u, nv); }
        u = nx;
    }
}

// foldXorOfICmps(LHS, RHS, I)
fn fold_xor_of_icmps(lhs: i32, rhs: i32, i: i32) -> i32 {
    var pl = inst_pred(lhs);
    let pr = inst_pred(rhs);
    var l0 = op(lhs, 0);
    var l1 = op(lhs, 1);
    let r0 = op(rhs, 0);
    let r1 = op(rhs, 1);
    if ao_predicates_foldable(pl, pr) {
        if l0 == r1 && l1 == r0 {
            let t = l0; l0 = l1; l1 = t;
            pl = pred_swapped(pl);
        }
        if l0 == r0 && l1 == r1 {
            let code = ao_icmp_code(pl) ^ ao_icmp_code(pr);
            let signed = pred_is_signed(inst_pred(lhs)) || pred_is_signed(pr);
            return ao_new_icmp_value(code, signed, l0, l1);
        }
    }
    if has_apint(l1) && has_apint(r1) && vals[l0].ty == vals[r0].ty && is_int_or_int_vec(vals[l0].ty) {
        let lc = ap_c(l1);
        let rc = ap_c(r1);
        let sbl, tisl = is_sign_bit_check(pl, lc);
        let sbr, tisr = is_sign_bit_check(pr, rc);
        if (has_one_use(lhs) || has_one_use(rhs)) && sbl && sbr {
            let xlr = icb_xor(l0, r0, "");
            return if tisl == tisr { ao_is_neg(xlr, "") } else { ao_is_not_neg(xlr, "") };
        }
        if l0 == r0 {
            let cr1 = rg_exact_icmp(pl, lc);
            let cr2 = rg_exact_icmp(pr, rc);
            let oku, cru = rg_exact_union(cr1, cr2);
            let oki, cri = rg_exact_intersect(cr1, cr2);
            if oku && oki {
                let okc, cr = rg_exact_intersect(cru, rg_inverse(cri));
                if okc {
                    if rg_is_full(cr) { return c_bool_ty(vals[i].ty, true); }
                    if rg_is_empty(cr) { return c_bool_ty(vals[i].ty, false); }
                    let np, nc, off = rg_equivalent_icmp_off(cr);
                    if (ap_is_zero(off) && (has_one_use(lhs) || has_one_use(rhs))) || (has_one_use(lhs) && has_one_use(rhs)) {
                        var nv = l0;
                        let ty = vals[l0].ty;
                        if !ap_is_zero(off) { nv = icb_add(nv, c_int_ap(ty, off), ""); }
                        return icb_icmp(np, nv, c_int_ap(ty, nc), "");
                    }
                }
            }
        }
        if icmp_is_equality(pl) && icmp_is_equality(pr) && ap_is_zero(lc) && ap_is_zero(rc) && has_one_use(lhs) && has_one_use(rhs) &&
           bo(l0, OP_AND) && bo(r0, OP_AND) && op(r0, 1) == op(l0, 1) && ao_pow2(op(l0, 1), true, i) {
            let x = op(l0, 0);
            let pw = op(l0, 1);
            let y = op(r0, 0);
            let xo = icb_xor(x, y, "");
            let an = icb_and(xo, pw, "");
            return icb_icmp(if pl == pr { P_NE } else { P_EQ }, an, c_null(vals[xo].ty), "");
        }
    }
    let orc = simplify_binop(OP_OR, lhs, rhs, sq_at(-1), RECURSION_LIMIT);
    if orc >= 0 {
        let andc = simplify_binop(OP_AND, lhs, rhs, sq_at(-1), RECURSION_LIMIT);
        if andc >= 0 {
            var x: i32 = -1;
            var y: i32 = -1;
            if orc == lhs && andc == rhs { x = lhs; y = rhs; }
            if orc == rhs && andc == lhs { x = rhs; y = lhs; }
            if x >= 0 && y >= 0 && (has_one_use(y) || can_freely_invert_all_users_of(y, i)) {
                icc_set_pred(y, pred_inverse(inst_pred(y)));
                if !has_one_use(y) {
                    let sp = icb_pos;
                    let sb = icb_bb;
                    let sd = icb_dl;
                    icb_set_insert_point(inst_next(y));
                    var nm: u8[>..] = [];
                    ao_name_suffix(nm, y, ".not");
                    let noty = icb_not(y, nm);
                    icw_push_users(y);
                    ao_replace_uses_except_user(y, noty);
                    icb_pos = sp; icb_bb = sb; icb_dl = sd;
                }
                return icb_and(lhs, rhs, "");
            }
        }
    }
    return -1;
}

// visitMaskedMerge(I, Builder)
fn ao_visit_masked_merge(i: i32) -> i32 {
    var b: i32 = -1;
    var x: i32 = -1;
    var d: i32 = -1;
    var m: i32 = -1;
    for k in 2 {
        if d >= 0 { break; }
        let bb = op(i, k);
        let an = op(i, 1 - k);
        if !(one_use(an) && bo(an, OP_AND)) { continue; }
        for j in 2 {
            let dd = op(an, j);
            if bo(dd, OP_XOR) {
                var xx: i32 = -1;
                if op(dd, 0) == bb { xx = op(dd, 1); } else if op(dd, 1) == bb { xx = op(dd, 0); }
                if xx >= 0 { b = bb; x = xx; d = dd; m = op(an, 1 - j); break; }
            }
        }
    }
    if d < 0 { return -1; }
    let notm = m_not(m);
    if notm >= 0 {
        let na = icb_and(d, notm, "");
        return ic_new_binop(OP_XOR, na, x);
    }
    if has_one_use(d) && is_constant(m) {
        let et = ty_scalar(vals[m].ty);
        let c = replace_undefs_with(m, c_all_ones(et));
        let l = icb_and(x, c, "");
        let nc = icb_not(c, "");
        let r = icb_and(b, nc, "");
        return ic_new_binop(OP_OR, l, r);
    }
    return -1;
}

// foldNotXor(I, Builder)
fn ao_fold_not_xor(i: i32) -> i32 {
    let n = m_not(i);
    if n < 0 || !one_use(n) || !bo(n, OP_XOR) { return -1; }
    let x = op(n, 0);
    let y = op(n, 1);
    if bo(x, OP_AND) && bo(y, OP_OR) && ao_has_common_operand(op(x, 0), op(x, 1), op(y, 0), op(y, 1)) {
        let noty = icb_not(y, "");
        return ic_new_binop(OP_OR, x, noty);
    }
    if bo(y, OP_AND) && bo(x, OP_OR) && ao_has_common_operand(op(y, 0), op(y, 1), op(x, 0), op(x, 1)) {
        let notx = icb_not(x, "");
        return ic_new_binop(OP_OR, y, notx);
    }
    return -1;
}
fn ao_has_common_operand(a: i32, b: i32, c: i32, d: i32) -> bool { a == c || a == d || b == c || b == d }

// canonicalizeAbs(Xor, Builder)
fn ao_canonicalize_abs(xo: i32) -> i32 {
    var op0 = op(xo, 0);
    var op1 = op(xo, 1);
    if num_uses(op0) == 2 { let t = op0; op0 = op1; op1 = t; }
    let ty = vals[xo].ty;
    if bo(op1, OP_ASHR) && has_apint(op(op1, 1)) && num_uses(op1) == 2 && ap_eq_u64(ap_c(op(op1, 1)), (ty_scalar_bits(ty) - 1) as u64) {
        let a = op(op1, 0);
        if one_use(op0) && m_c_binop_both(op0, OP_ADD, a, op1) {
            let isneg = ao_is_neg(a, "");
            let nega = if op_nuw(op0) { c_null(vals[a].ty) } else { icb_neg(a, "", op_nsw(op0)) };
            return ic_new_select(isneg, nega, a);
        }
    }
    return -1;
}

// canFreelyInvert(IC, Op, IgnoredUser)
fn ao_can_freely_invert(v: i32, ignored: i32) -> bool {
    return is_inst(v) && is_free_to_invert(v, true) && can_freely_invert_all_users_of(v, ignored);
}
// Instruction::getInsertionPointAfterDef()
fn ao_insertion_point_after_def(i: i32) -> i32 {
    if is_phi_inst(i) { return first_insertion_pt(inst_parent(i)); }
    let o = iop(i);
    if o == OP_INVOKE || o == OP_CALLBR { ic_not_ported("getInsertionPointAfterDef of an invoke/callbr"); }
    return inst_next(i);
}
// freelyInvert(IC, Op, IgnoredUser)
fn ao_freely_invert(v: i32, ignored: i32) -> i32 {
    icb_set_insert_point(ao_insertion_point_after_def(v));
    var nm: u8[>..] = [];
    ao_name_suffix(nm, v, ".not");
    let n = icb_not(v, nm);
    ao_replace_uses_except_user(v, n);
    freely_invert_all_users_of(n, ignored);
    return n;
}

// sinkNotIntoLogicalOp(I)
fn sink_not_into_logical_op(i: i32) -> bool {
    let is_land = m_logical(i, true);
    if !is_land && !m_logical(i, false) { return false; }
    var op0 = lg_a;
    var op1 = lg_b;
    if op0 == op1 { return false; }
    if m_not_of(op0, op1) || m_not_of(op1, op0) { return false; }
    let nopc = if is_land { OP_OR } else { OP_AND };
    let is_binop = is_binop_inst(i);
    if !can_freely_invert_all_users_of(i, -1) { return false; }
    if !ao_can_freely_invert(op0, i) || !ao_can_freely_invert(op1, i) { return false; }
    op0 = ao_freely_invert(op0, i);
    op1 = ao_freely_invert(op1, i);
    icb_set_insert_point(ao_insertion_point_after_def(i));
    var nm: u8[>..] = [];
    ao_name_suffix(nm, i, ".not");
    var nl: i32 = -1;
    if is_binop {
        nl = icb_binop(nopc, op0, op1, nm);
    } else {
        nl = ao_logical_op(nopc, op0, op1, nm, i);
        if is_select_inst(nl) { cu_swap_prof_metadata(nl); }
    }
    ic_replace_inst_uses_with(i, nl);
    freely_invert_all_users_of(nl, -1);
    return true;
}

// sinkNotIntoOtherHandOfLogicalOp(I)
fn sink_not_into_other_hand_of_logical_op(i: i32) -> bool {
    let is_land = m_logical(i, true);
    if !is_land && !m_logical(i, false) { return false; }
    var op0 = lg_a;
    var op1 = lg_b;
    let nopc = if is_land { OP_OR } else { OP_AND };
    let is_binop = is_binop_inst(i);
    var inv_first = false;
    let n0 = m_not(op0);
    if n0 >= 0 && ao_can_freely_invert(op1, i) {
        op0 = n0;
        inv_first = false;
    } else {
        let n1 = m_not(op1);
        if n1 >= 0 && ao_can_freely_invert(op0, i) {
            op1 = n1;
            inv_first = true;
        } else { return false; }
    }
    // OpToInvert is Op1 (inv_first = false) or Op0
    let to_inv = if inv_first { op0 } else { op1 };
    let kept = if inv_first { op1 } else { op0 };
    if m_not_of(kept, to_inv) { return false; }
    if !can_freely_invert_all_users_of(i, -1) { return false; }
    let inv = ao_freely_invert(to_inv, i);
    if inv_first { op0 = inv; } else { op1 = inv; }
    icb_set_insert_point(ao_insertion_point_after_def(i));
    var nm: u8[>..] = [];
    ao_name_suffix(nm, i, ".not");
    var nb: i32 = -1;
    if is_binop { nb = icb_binop(nopc, op0, op1, nm); }
    else { nb = ao_logical_op(nopc, op0, op1, nm, -1); }
    ic_replace_inst_uses_with(i, nb);
    freely_invert_all_users_of(nb, -1);
    return true;
}

// foldNot(I)
fn fold_not(i: i32) -> i32 {
    let notop = m_not(i);
    if notop < 0 { return -1; }
    let ty = vals[i].ty;
    if one_use(notop) {
        let ok, x, y = ao_c_binop_not_first(notop, OP_AND);
        if ok {
            var nm: u8[>..] = [];
            ao_name_suffix(nm, y, ".not");
            let noty = icb_not(y, nm);
            return ic_new_binop(OP_OR, x, noty);
        }
    }
    if one_use(notop) && m_logical(notop, true) {
        let x = m_not(lg_a);
        let y = lg_b;
        if x >= 0 {
            var nm: u8[>..] = [];
            ao_name_suffix(nm, y, ".not");
            let noty = icb_not(y, nm);
            let si = ic_new_select_md_all(x, c_bool_ty(ty, true), noty, notop);
            cu_swap_prof_metadata(si);
            return si;
        }
    }
    if one_use(notop) {
        let ok, x, y = ao_c_binop_not_first(notop, OP_OR);
        if ok {
            var nm: u8[>..] = [];
            ao_name_suffix(nm, y, ".not");
            let noty = icb_not(y, nm);
            return ic_new_binop(OP_AND, x, noty);
        }
    }
    if one_use(notop) && m_logical(notop, false) {
        let x = m_not(lg_a);
        let y = lg_b;
        if x >= 0 {
            var nm: u8[>..] = [];
            ao_name_suffix(nm, y, ".not");
            let noty = icb_not(y, nm);
            let si = ic_new_select_md_all(x, noty, c_bool_ty(ty, false), notop);
            cu_swap_prof_metadata(si);
            return si;
        }
    }
    if is_binop_inst(notop) {
        let nv = notop;
        // ~((-X) | Y) --> (X - 1) & (~Y)
        if one_use(nv) && bo(nv, OP_OR) {
            for k in 2 {
                let ng = op(nv, k);
                if one_use(ng) && m_neg(ng) >= 0 {
                    let x = m_neg(ng);
                    let y = op(nv, 1 - k);
                    let decx = icb_add(x, c_all_ones(ty), "");
                    let noty = icb_not(y, "");
                    return ic_new_binop(OP_AND, decx, noty);
                }
            }
        }
        if bo(nv, OP_ASHR) && m_not(op(nv, 0)) >= 0 { return ic_new_binop(OP_ASHR, m_not(op(nv, 0)), op(nv, 1)); }
        if bo(nv, OP_LSHR) && m_not(op(nv, 0)) >= 0 {
            let x = m_not(op(nv, 0));
            if kb_is_neg(ao_kb(x, nv)) { return ic_new_binop(OP_ASHR, x, op(nv, 1)); }
        }
        let fs = ty_scalar_bits(ty) - 1;
        if one_use(nv) && bo(nv, OP_ASHR) && m_specific_int(op(nv, 1), fs as u64) {
            let inn = ao_is_not_neg(op(nv, 0), "isnotneg");
            return ic_new_cast(OP_SEXT, inn, ty);
        }
        if bo(nv, OP_ASHR) && is_constant(op(nv, 0)) && m_negative(op(nv, 0)) {
            return ic_new_binop(OP_LSHR, ce_not(op(nv, 0)), op(nv, 1));
        }
        if bo(nv, OP_LSHR) && is_constant(op(nv, 0)) && m_nonneg(op(nv, 0)) {
            return ic_new_binop(OP_ASHR, ce_not(op(nv, 0)), op(nv, 1));
        }
        if bo(nv, OP_ADD) && ao_imm(op(nv, 1)) { return ic_new_binop(OP_SUB, ce_not(op(nv, 1)), op(nv, 0)); }
        if bo(nv, OP_SUB) {
            let x = op(nv, 0);
            if is_constant(x) || has_one_use(nv) { return ic_new_binop(OP_ADD, icb_not(x, ""), op(nv, 1)); }
        }
        if bo(nv, OP_ADD) {
            let ok, x, y = ao_c_binop_not_first(nv, OP_ADD);
            if ok {
                let s = ic_new_binop(OP_SUB, x, y);
                copy_ir_flags(s, nv);
                return s;
            }
        }
    }
    if is_cmp_inst(notop) && (has_one_use(notop) || can_freely_invert_all_users_of(notop, -1)) {
        icc_set_pred(notop, pred_inverse_any(inst_pred(notop)));
        freely_invert_all_users_of(notop, -1);
        return i;
    }
    if one_use(notop) && is_op(notop, OP_BITCAST) {
        let x = op(notop, 0);
        if one_use(x) && is_cmp_inst(x) {
            icc_set_pred(x, pred_inverse_any(inst_pred(x)));
            return ic_new_cast(OP_BITCAST, x, ty);
        }
        let sx = if one_use(x) { m_sext(x) } else { -1 };
        if sx >= 0 && is_int_ty1(vals[sx].ty) {
            let sty = vals[x].ty;
            let notx = icb_not(sx, "");
            let s = icb_sext(notx, sty, "");
            return ic_new_cast(OP_BITCAST, s, ty);
        }
    }
    if is_inst(notop) && sink_not_into_logical_op(notop) { return i; }
    let iid = inst_iid(notop);
    if iid != 0 && has_one_use(notop) {
        if is_minmax_iid(iid) {
            var x: i32 = -1;
            var y: i32 = -1;
            if m_not(op(notop, 0)) >= 0 { x = m_not(op(notop, 0)); y = op(notop, 1); }
            else if m_not(op(notop, 1)) >= 0 { x = m_not(op(notop, 1)); y = op(notop, 0); }
            if x >= 0 {
                let inv = minmax_inverse_iid(iid);
                let noty = icb_not(y, "");
                let r = icb_binary_intrinsic(inv, x, noty, "");
                return ic_replace_inst_uses_with(i, r);
            }
        }
        if iid == IID_is_fpclass {
            let cm = op(notop, 1);
            let nm = (~ap_zext64(ci_ap(cm))) & 0x3FF;
            set_op(notop, 1, c_int(vals[cm].ty, nm as i64));
            return ic_replace_inst_uses_with(i, notop);
        }
    }
    if has_one_use(notop) && is_select_inst(notop) {
        let sel = notop;
        let tv = op(sel, 1);
        let fv = op(sel, 2);
        let ct = is_cmp_inst(tv);
        let cf = is_cmp_inst(fv);
        let invt = (ct && has_one_use(tv)) || is_constant(tv);
        let invf = (cf && has_one_use(fv)) || is_constant(fv);
        if invt && invf {
            if ct { icc_set_pred(tv, pred_inverse_any(inst_pred(tv))); } else { set_op(sel, 1, ce_not(tv)); }
            if cf { icc_set_pred(fv, pred_inverse_any(inst_pred(fv))); } else { set_op(sel, 2, ce_not(fv)); }
            return ic_replace_inst_uses_with(i, sel);
        }
    }
    let nx = ao_fold_not_xor(i);
    if nx >= 0 { return nx; }
    let r = get_freely_inverted(notop, has_one_use(notop), true);
    if r >= 0 { return ic_replace_inst_uses_with(i, r); }
    return -1;
}
// m_c_BinOp(Opc, m_Not(m_Value(X)), m_Value(Y)): ok, X, Y
fn ao_c_binop_not_first(v: i32, opc: i64) -> bool, i32, i32 {
    if !bo(v, opc) { return false, -1, -1; }
    let x0 = m_not(op(v, 0));
    if x0 >= 0 { return true, x0, op(v, 1); }
    let x1 = m_not(op(v, 1));
    if x1 >= 0 { return true, x1, op(v, 0); }
    return false, -1, -1;
}

// foldMaskedAddXorPattern(I, Builder)
fn ao_fold_masked_add_xor_pattern(i: i32) -> i32 {
    let an = op(i, 0);
    if !(one_use(an) && bo(an, OP_AND)) { return -1; }
    let ad = op(an, 0);
    let mask = op(an, 1);
    if !(one_use(ad) && bo(ad, OP_ADD) && ao_imm(op(ad, 1))) { return -1; }
    if op(i, 1) != mask { return -1; }
    let notc = icb_not(op(ad, 1), "");
    let ns = icb_sub_nw(notc, op(ad, 0), "", op_nuw(ad), op_nsw(ad));
    return ic_new_binop(OP_AND, ns, mask);
}

// ---------------------------------------------------------------------------------------------
// visitAnd

fn ao_has_no_implicit_float() -> bool { func_has_fn_attr(ic_fn, AK_NoImplicitFloat) }
// m_SExtOrSelf(m_AShr(m_Value(X), m_APIntAllowPoison(C))) -> the ashr or -1
fn ao_sext_or_self_ashr_apint(v: i32) -> i32 {
    let s = m_sext(v);
    if s >= 0 && bo(s, OP_ASHR) && has_apint_poison(op(s, 1)) { return s; }
    if bo(v, OP_ASHR) && has_apint_poison(op(v, 1)) { return v; }
    return -1;
}
// m_SExtOrSelf(m_Not(m_AShr(m_Value(X), m_APIntAllowPoison(C)))) -> the ashr or -1
fn ao_sext_or_self_not_ashr_apint(v: i32) -> i32 {
    let s = m_sext(v);
    if s >= 0 {
        let n = m_not(s);
        if n >= 0 && bo(n, OP_ASHR) && has_apint_poison(op(n, 1)) { return n; }
    }
    let n = m_not(v);
    if n >= 0 && bo(n, OP_ASHR) && has_apint_poison(op(n, 1)) { return n; }
    return -1;
}
fn ao_is_narrowable_binop(o: i64) -> bool { o == OP_XOR || o == OP_OR || o == OP_MUL || o == OP_ADD || o == OP_SUB }

// the APInt-constant part of visitAnd: match(Op1, m_APInt(C))
fn ao_visit_and_apint(i: i32, op0: i32, op1: i32) -> i32 {
    let ty = vals[i].ty;
    let c = ap_c(op1);
    if one_use(op0) && bo(op0, OP_XOR) && has_apint(op(op0, 1)) {
        let x = op(op0, 0);
        let nc = c_int_ap(ty, ap_and(c, ap_c(op(op0, 1))));
        let an = icb_and(x, op1, "");
        ic_take_name(an, op0);
        return ic_new_binop(OP_XOR, an, nc);
    }
    if one_use(op0) && bo(op0, OP_OR) && has_apint(op(op0, 1)) {
        let x = op(op0, 0);
        let tog = ap_and(c, ap_c(op(op0, 1)));
        let an = icb_and(x, c_int_ap(ty, ap_xor(tog, c)), "");
        ic_take_name(an, op0);
        return ic_new_binop(OP_OR, an, c_int_ap(ty, tog));
    }
    let w = ty_scalar_bits(ty);
    if one_use(op0) && is_inst_op(op0, OP_SEXT) {
        let sh = op(op0, 0);
        if bo(sh, OP_ASHR) && has_apint(op(sh, 1)) && ap_ult_u64(ap_c(op(sh, 1)), w as u64) {
            let x = op(sh, 0);
            let shc = ap_c(op(sh, 1));
            if ap_eq(c, ap_low_bits(w, w - ap_zext64(shc) as i64)) {
                let sx = icb_sext(x, ty, "");
                return ic_new_binop(OP_LSHR, sx, c_int_ap(ty, ap_zext(shc, w)));
            }
        }
    }
    if bo(op0, OP_ASHR) && has_apint(op(op0, 1)) && ap_ult_u64(ap_c(op(op0, 1)), w as u64) {
        let shc = ap_c(op(op0, 1));
        if ap_eq(c, ap_low_bits(w, w - ap_zext64(shc) as i64)) {
            return ic_new_binop(OP_LSHR, op(op0, 0), c_int_ap(ty, shc));
        }
    }
    if bo(op0, OP_ADD) && has_apint(op(op0, 1)) {
        let addc = ap_c(op(op0, 1));
        if has_one_use(op0) && ap_is_pow2(c) && ap_is_zero(ap_and(addc, ap_sub_u64(c, 1))) {
            let na = icb_and(op(op0, 0), op1, "");
            return ic_new_binop(OP_XOR, na, op1);
        }
    }
    if one_use(op0) && is_binop_inst(op0) && ao_is_narrowable_binop(iop(op0)) {
        let b = op0;
        let bop = iop(b);
        for k in 2 {
            let z = op(b, k);
            let cc = op(b, 1 - k);
            if one_use(z) && is_inst_op(z, OP_ZEXT) && has_apint(cc) {
                let x = op(z, 0);
                let xw = ty_sbits(x);
                if ap_is_int_n(c, xw) {
                    let tc1 = c_int_ap(vals[x].ty, ap_trunc(ap_c(cc), xw));
                    let nb = if is_inst_op(op(b, 0), OP_ZEXT) { icb_binop(bop, x, tc1, "") } else { icb_binop(bop, tc1, x, "") };
                    let tc = c_int_ap(vals[x].ty, ap_trunc(c, xw));
                    let an = icb_and(nb, tc, "");
                    return ic_new_cast(OP_ZEXT, an, ty);
                }
                break;
            }
        }
        if is_inst(op(b, 0)) && one_use(op(b, 0)) && is_inst_op(op(b, 0), OP_ZEXT) {
            let x = op(op(b, 0), 0);
            let xw = ty_sbits(x);
            if ap_eq(c, ap_low_bits(w, xw)) {
                let y = op(b, 1);
                var n1: u8[>..] = [];
                ao_name_suffix(n1, y, ".tr");
                let try = icb_trunc(y, vals[x].ty, n1);
                var n2: u8[>..] = [];
                ao_name_suffix(n2, b, ".narrow");
                let nb = icb_binop(bop, x, try, n2);
                return ic_new_cast(OP_ZEXT, nb, ty);
            }
        }
        if is_inst(op(b, 1)) && one_use(op(b, 1)) && is_inst_op(op(b, 1), OP_ZEXT) {
            let x = op(op(b, 1), 0);
            let xw = ty_sbits(x);
            if ap_eq(c, ap_low_bits(w, xw)) {
                let y = op(b, 0);
                var n1: u8[>..] = [];
                ao_name_suffix(n1, y, ".tr");
                let try = icb_trunc(y, vals[x].ty, n1);
                var n2: u8[>..] = [];
                ao_name_suffix(n2, b, ".narrow");
                let nb = icb_binop(bop, try, x, n2);
                return ic_new_cast(OP_ZEXT, nb, ty);
            }
        }
    }
    if one_use(op0) && (bo(op0, OP_XOR) || bo(op0, OP_OR)) {
        let x = op(op0, 0);
        let y = op(op0, 1);
        let nam = ap_not(c);
        let bop = iop(op0);
        if ao_masked_zero(x, nam, i) {
            var nm: u8[>..] = [];
            ao_name_suffix(nm, y, ".masked");
            let nr = icb_and(y, op1, nm);
            return ic_new_binop(bop, x, nr);
        }
        if !is_constant(y) && ao_masked_zero(y, nam, i) {
            var nm: u8[>..] = [];
            ao_name_suffix(nm, x, ".masked");
            let nl = icb_and(x, op1, nm);
            return ic_new_binop(bop, nl, y);
        }
    }
    if ap_is_pow2(c) && one_use(op0) && ao_logical_shift(op0) && ao_api_pow2(op(op0, 0)) {
        let shc = ap_cp(op(op0, 0));
        let x = op(op0, 1);
        let l2s = ap_exact_log2(shc);
        let l2c = ap_exact_log2(c);
        let is_shl = iop(op0) == OP_SHL;
        let bitnum = if is_shl { l2c - l2s } else { l2s - l2c };
        let cmp = icb_icmp(P_EQ, x, c_int_ty(ty, bitnum as u64), "");
        return ic_new_select_unknown_prof(cmp, c_int_ap(ty, c), c_null(ty));
    }
    if ap_is_pow2(c) {
        let log2c3 = c_int_ty(ty, ap_countr_zero(c) as u64);
        if one_use(op0) && bo(op0, OP_LSHR) && ao_imm(op(op0, 1)) {
            let sh = op(op0, 0);
            if bo(sh, OP_SHL) && ao_imm(op(sh, 0)) && m_power2(op(sh, 0)) {
                let c1 = op(sh, 0);
                let x = op(sh, 1);
                let c2 = op(op0, 1);
                let log2c1 = get_exact_log_base2(c1);
                let lshrc = ce_binop(OP_ADD, c2, log2c3, 0);
                let k = ao_kb(lshrc, -1);
                if ap_ult_u64(ap_not(k.z), w as u64) {
                    let cmpc = ce_binop(OP_SUB, lshrc, log2c1, 0);
                    let cmp = icb_icmp(P_EQ, x, cmpc, "");
                    return ic_new_select_unknown_prof(cmp, c_int_ap(ty, c), c_null(ty));
                }
            }
        }
        if one_use(op0) && bo(op0, OP_SHL) && ao_imm(op(op0, 1)) {
            let sh = op(op0, 0);
            if bo(sh, OP_LSHR) && ao_imm(op(sh, 0)) && m_power2(op(sh, 0)) {
                let c1 = op(sh, 0);
                let x = op(sh, 1);
                let c2 = op(op0, 1);
                let log2c1 = get_exact_log_base2(c1);
                let cmpk = cf_fold_cmp_operands(P_ULT, log2c3, c2, -1);
                if cmpk >= 0 && is_null_value(cmpk) {
                    let shlc = ce_binop(OP_ADD, c2, log2c1, 0);
                    let cmpc = ce_binop(OP_SUB, shlc, log2c3, 0);
                    let cmp = icb_icmp(P_EQ, x, cmpc, "");
                    return ic_new_select_unknown_prof(cmp, c_int_ap(ty, c), c_null(ty));
                }
            }
        }
    }
    return -1;
}

// visitAnd(I)
fn visit_and(i: i32) -> i32 {
    let ty = vals[i].ty;
    let v0 = simplify_and(op(i, 0), op(i, 1), sq_at(i), RECURSION_LIMIT);
    if v0 >= 0 { return ic_replace_inst_uses_with(i, v0); }
    if simplify_assoc_or_comm(i) { return i; }
    var r = fold_vector_binop(i);
    if r >= 0 { return r; }
    r = fold_binop_with_phi_operands(i);
    if r >= 0 { return r; }
    if simplify_demanded_instruction_bits(i) { return i; }
    r = ao_fold_and_to_xor(i);
    if r >= 0 { return r; }
    r = ao_fold_complex_and_or_patterns(i);
    if r >= 0 { return r; }
    let dl = fold_using_distributive_laws(i);
    if dl >= 0 { return ic_replace_inst_uses_with(i, dl); }
    r = fold_binop_shift_with_shift(i);
    if r >= 0 { return r; }
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    // (1 >> X) & 1 --> zext(X == 0); (C << X) & 1 --> zext(X == 0), C odd
    if one_use(op0) && m_one(op1) {
        var x: i32 = -1;
        if ao_logical_shift(op0) && m_one(op(op0, 0)) { x = op(op0, 1); }
        else if bo(op0, OP_SHL) && has_apint(op(op0, 0)) && ap_get_bit(ap_c(op(op0, 0)), 0) { x = op(op0, 1); }
        if x >= 0 {
            let isz = icb_icmp(P_EQ, x, c_int_ty(ty, 0), "");
            return ic_new_cast(OP_ZEXT, isz, ty);
        }
    }
    // (-(X & 1)) & Y --> (X & 1) == 0 ? 0 : Y
    for k in 2 {
        let ng = op(i, k);
        if one_use(ng) && m_neg(ng) >= 0 && bo(m_neg(ng), OP_AND) && m_one(op(m_neg(ng), 1)) {
            let y = op(i, 1 - k);
            let cmp = icb_is_null(ng, "");
            return ic_new_select_unknown_prof(cmp, c_null(ty), y);
        }
    }
    // (X +/- Y) & Y --> ~X & Y when Y is a power of 2
    for k in 2 {
        let y = op(i, k);
        let o = op(i, 1 - k);
        if !one_use(o) { continue; }
        var x: i32 = -1;
        if bo(o, OP_ADD) {
            if op(o, 1) == y { x = op(o, 0); } else if op(o, 0) == y { x = op(o, 1); }
        }
        if x < 0 && bo(o, OP_SUB) && op(o, 1) == y { x = op(o, 0); }
        if x < 0 { continue; }
        if ao_pow2(y, true, i) { return ic_new_binop(OP_AND, icb_not(x, ""), y); }
        break;
    }
    if has_apint(op1) {
        r = ao_visit_and_apint(i, op0, op1);
        if r >= 0 { return r; }
    }
    // clearing the sign bit of an FP value: fabs
    {
        let castop = ao_elementwise_bitcast(op0);
        if castop >= 0 && m_cint_pred(op1, IP_MAXSIGNED, true) && !ao_has_no_implicit_float() {
            let et = ty_scalar(vals[castop].ty);
            if ty_is_fp(et) {
                let fa = ao_fabs(castop, icb_fmf);
                return ic_new_cast(OP_BITCAST, fa, ty);
            }
        }
    }
    // and(shl(zext(X), Y), SignMask) -> and(sext(X), SignMask)
    if one_use(op0) && bo(op0, OP_SHL) && is_inst_op(op(op0, 0), OP_ZEXT) && m_sign_mask(op1) {
        let x = op(op(op0, 0), 0);
        let y = op(op0, 1);
        let b = ty_scalar_bits(ty);
        if ao_specific_int_icmp(y, P_EQ, ap_u64((b - ty_sbits(x)) as u64, b)) {
            var nm: u8[>..] = [];
            ao_name_suffix(nm, x, ".signext");
            let sx = icb_sext(x, ty, nm);
            return ic_new_binop(OP_AND, sx, op1);
        }
    }
    r = ao_narrow_masked_binop(i);
    if r >= 0 { return r; }
    if is_int_ty1(ty) {
        if is_select_inst(op0) {
            r = fold_and_or_of_select_using_implied_cond(op1, op0, true);
            if r >= 0 { return r; }
        }
        if is_select_inst(op1) {
            r = fold_and_or_of_select_using_implied_cond(op0, op1, true);
            if r >= 0 { return r; }
        }
    }
    r = fold_binop_into_select_or_phi(i);
    if r >= 0 { return r; }
    r = ao_match_demorgans_laws(i);
    if r >= 0 { return r; }
    {
        // A & ~(A ^ B) --> A & B
        let n1 = m_not(op1);
        if n1 >= 0 { let b = m_c_binop_with(n1, OP_XOR, op0); if b >= 0 { return ic_new_binop(OP_AND, op0, b); } }
        // ~(A ^ B) & A --> A & B
        let n0 = m_not(op0);
        if n0 >= 0 { let b = m_c_binop_with(n0, OP_XOR, op1); if b >= 0 { return ic_new_binop(OP_AND, op1, b); } }
        // (A ^ B) & ((B ^ C) ^ A) -> (A ^ B) & ~C
        if bo(op0, OP_XOR) && bo(op1, OP_XOR) && bo(op(op1, 0), OP_XOR) {
            let a = op(op0, 0);
            let b = op(op0, 1);
            let inner = op(op1, 0);
            if op(inner, 0) == b && op(op1, 1) == a {
                let c = op(inner, 1);
                let notc = if has_one_use(op1) { icb_not(c, "") } else { get_freely_inverted(c, has_one_use(c), true) };
                if notc >= 0 { return ic_new_binop(OP_AND, op0, notc); }
            }
        }
        // ((A ^ C) ^ B) & (B ^ A) -> (B ^ A) & ~C
        if bo(op0, OP_XOR) && bo(op(op0, 0), OP_XOR) && bo(op1, OP_XOR) {
            let a = op(op(op0, 0), 0);
            let c = op(op(op0, 0), 1);
            let b = op(op0, 1);
            if op(op1, 0) == b && op(op1, 1) == a {
                let notc = if has_one_use(op0) { icb_not(c, "") } else { get_freely_inverted(c, has_one_use(c), true) };
                if notc >= 0 { return ic_new_binop(OP_AND, op1, notc); }
            }
        }
        // (A | B) & (~A ^ B) -> A & B
        {
            let ok, a, b = ao_c_binop_not_first(op1, OP_XOR);
            if ok && m_c_binop_both(op0, OP_OR, a, b) { return ic_new_binop(OP_AND, a, b); }
        }
        // (~A ^ B) & (A | B) -> A & B
        {
            let ok, a, b = ao_c_binop_not_first(op0, OP_XOR);
            if ok && m_c_binop_both(op1, OP_OR, a, b) { return ic_new_binop(OP_AND, a, b); }
        }
        // (~A | B) & (A ^ B) -> ~A & B
        {
            let ok, a, b = ao_c_binop_not_first(op0, OP_OR);
            if ok && m_c_binop_both(op1, OP_XOR, a, b) { return ic_new_binop(OP_AND, icb_not(a, ""), b); }
        }
        // (A ^ B) & (~A | B) -> ~A & B
        {
            let ok, a, b = ao_c_binop_not_first(op1, OP_OR);
            if ok && m_c_binop_both(op0, OP_XOR, a, b) { return ic_new_binop(OP_AND, icb_not(a, ""), b); }
        }
    }
    let res = fold_boolean_and_or(op0, op1, i, true, false);
    if res >= 0 { return ic_replace_inst_uses_with(i, res); }
    if one_use(op1) && m_logical(op1, true) {
        let x = lg_a;
        let y = lg_b;
        let v = ao_reassociate_boolean_and_or(op0, x, y, i, true, is_select_inst(op1));
        if v >= 0 { return ic_replace_inst_uses_with(i, v); }
    }
    if one_use(op0) && m_logical(op0, true) {
        let x = lg_a;
        let y = lg_b;
        let v = ao_reassociate_boolean_and_or(op1, x, y, i, true, is_select_inst(op0));
        if v >= 0 { return ic_replace_inst_uses_with(i, v); }
    }
    r = ao_reassociate_fcmps(i);
    if r >= 0 { return r; }
    r = fold_casted_bitwise_logic(i);
    if r >= 0 { return r; }
    r = fold_binop_of_sext_bool_to_select(i);
    if r >= 0 { return r; }
    // and(sext(A), B) --> A ? B : 0
    {
        var a = m_sext(op0);
        var b = op1;
        if a < 0 { a = m_sext(op1); b = op0; }
        if a >= 0 && is_int_ty1(vals[a].ty) { return ic_new_select_unknown_prof(a, b, c_null(ty)); }
    }
    // ~sext(A) & B --> A ? 0 : B
    {
        var a: i32 = -1;
        var b: i32 = -1;
        for k in 2 {
            let n = m_not(op(i, k));
            if n >= 0 && m_sext(n) >= 0 { a = m_sext(n); b = op(i, 1 - k); break; }
        }
        if a >= 0 && is_int_ty1(vals[a].ty) { return ic_new_select_unknown_prof(a, c_null(ty), b); }
    }
    // and(zext(A), B) -> A ? (B & 1) : 0
    {
        var a: i32 = -1;
        var b: i32 = -1;
        for k in 2 {
            let z = op(i, k);
            if one_use(z) && m_zext(z) >= 0 { a = m_zext(z); b = op(i, 1 - k); break; }
        }
        if a >= 0 && is_int_ty1(vals[a].ty) {
            return ic_new_select_unknown_prof(a, icb_and(b, c_int_ty(ty, 1), ""), c_null(ty));
        }
    }
    // (-1 + A) & B --> A ? 0 : B where A is 0/1
    for k in 2 {
        let ad = op(i, k);
        if !(one_use(ad) && bo(ad, OP_ADD) && m_all_ones(op(ad, 1))) { continue; }
        let a = ao_zext_or_self(op(ad, 0));
        let b = op(i, 1 - k);
        if is_int_ty1(vals[a].ty) { return ic_new_select_unknown_prof(a, c_null(ty), b); }
        let ka = ao_kb(a, i);
        if ty_sbits(a) - ap_countl_one(ka.z) <= 1 {
            return ic_new_select_unknown_prof(icb_icmp(P_EQ, a, c_null(vals[a].ty), ""), b, c_null(ty));
        }
        break;
    }
    // (iN X s>> (N-1)) & Y --> (X s< 0) ? Y : 0 -- with optional sext
    for k in 2 {
        let o = op(i, k);
        if !one_use(o) { continue; }
        let sh = ao_sext_or_self_ashr_apint(o);
        if sh < 0 { continue; }
        let x = op(sh, 0);
        let y = op(i, 1 - k);
        if ap_eq_u64(ap_cp(op(sh, 1)), (ty_sbits(x) - 1) as u64) {
            let isneg = ao_is_neg(x, "isneg");
            return ic_new_select_unknown_prof(isneg, y, c_null(ty));
        }
        break;
    }
    for k in 2 {
        let o = op(i, k);
        if !one_use(o) { continue; }
        let sh = ao_sext_or_self_not_ashr_apint(o);
        if sh < 0 { continue; }
        let x = op(sh, 0);
        let y = op(i, 1 - k);
        if ap_eq_u64(ap_cp(op(sh, 1)), (ty_sbits(x) - 1) as u64) {
            let isneg = ao_is_neg(x, "isneg");
            return ic_new_select_unknown_prof(isneg, c_null(ty), y);
        }
        break;
    }
    if sink_not_into_other_hand_of_logical_op(i) { return i; }
    {
        let ok, pn, start, step = ao_match_simple_recurrence(i);
        if ok && dt_value_dominates_inst(step, pn) { return ic_replace_inst_uses_with(i, icb_and(start, step, "")); }
    }
    r = ao_reassociate_for_uses(i);
    if r >= 0 { return r; }
    r = ao_canonicalize_logic_first(i);
    if r >= 0 { return r; }
    r = ao_fold_logic_of_is_fpclass(i, op0, op1);
    if r >= 0 { return r; }
    r = fold_binop_of_displaced_shifts(i);
    if r >= 0 { return r; }
    r = ao_fold_bitwise_logic_with_intrinsics(i);
    if r >= 0 { return r; }
    let s0 = ao_simplify_and_or_with_op_replaced(op0, op1, c_all_ones(ty), false, 0);
    if s0 >= 0 { return ic_new_binop(OP_AND, s0, op1); }
    let s1 = ao_simplify_and_or_with_op_replaced(op1, op0, c_all_ones(ty), false, 0);
    if s1 >= 0 { return ic_new_binop(OP_AND, op0, s1); }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// visitOr

// the (A & C) | (B & D) part of visitOr; -2 = no match of the outer pattern
fn ao_visit_or_and_and(i: i32, op0: i32, op1: i32) -> i32 {
    let ty = vals[i].ty;
    let a = op(op0, 0);
    let c = op(op0, 1);
    let b = op(op1, 0);
    let d = op(op1, 1);
    if has_apint(c) && has_apint(d) {
        let c0 = ap_c(c);
        let c1 = ap_c(d);
        if ap_eq(c0, ap_not(c1)) {
            let x1 = m_c_binop_with(a, OP_OR, b);
            if x1 >= 0 { return ic_new_binop(OP_OR, icb_and(x1, c_int_ap(vals[x1].ty, c0), ""), b); }
            let x2 = m_c_binop_with(b, OP_OR, a);
            if x2 >= 0 { return ic_new_binop(OP_OR, icb_and(x2, c_int_ap(vals[x2].ty, c1), ""), a); }
            let x3 = m_c_binop_with(a, OP_XOR, b);
            if x3 >= 0 { return ic_new_binop(OP_XOR, icb_and(x3, c_int_ap(vals[x3].ty, c0), ""), b); }
            let x4 = m_c_binop_with(b, OP_XOR, a);
            if x4 >= 0 { return ic_new_binop(OP_XOR, icb_and(x4, c_int_ap(vals[x4].ty, c1), ""), a); }
        }
        if ap_is_zero(ap_and(c0, c1)) {
            let x1 = m_c_binop_with(a, OP_OR, b);
            if x1 >= 0 && ao_masked_zero(x1, ap_not(c0), i) {
                return ic_new_binop(OP_AND, a, c_int_ap(ty, ap_or(c0, c1)));
            }
            let x2 = m_c_binop_with(b, OP_OR, a);
            if x2 >= 0 && ao_masked_zero(x2, ap_not(c1), i) {
                return ic_new_binop(OP_AND, b, c_int_ap(ty, ap_or(c0, c1)));
            }
            if bo(a, OP_OR) && has_apint(op(a, 1)) && bo(b, OP_OR) && op(b, 0) == op(a, 0) && has_apint(op(b, 1)) {
                let x = op(a, 0);
                let c2 = ap_c(op(a, 1));
                let c3 = ap_c(op(b, 1));
                if ap_is_zero(ap_and(c2, ap_not(c0))) && ap_is_zero(ap_and(c3, ap_not(c1))) {
                    let orv = icb_or(x, c_int_ap(vals[x].ty, ap_or(c2, c3)), "bitfield");
                    return ic_new_binop(OP_AND, orv, c_int_ap(ty, ap_or(c0, c1)));
                }
            }
        }
    }
    if has_one_use(op0) || has_one_use(op1) {
        var v = ao_match_select_from_and_or(a, c, b, d, false);
        if v < 0 { v = ao_match_select_from_and_or(a, c, d, b, false); }
        if v < 0 { v = ao_match_select_from_and_or(c, a, b, d, false); }
        if v < 0 { v = ao_match_select_from_and_or(c, a, d, b, false); }
        if v < 0 { v = ao_match_select_from_and_or(b, d, a, c, false); }
        if v < 0 { v = ao_match_select_from_and_or(b, d, c, a, false); }
        if v < 0 { v = ao_match_select_from_and_or(d, b, a, c, false); }
        if v < 0 { v = ao_match_select_from_and_or(d, b, c, a, false); }
        if v >= 0 { return ic_replace_inst_uses_with(i, v); }
    }
    return -2;
}

// the "Op1 is an xor" part of visitOr (after the swap)
fn ao_visit_or_xor_rhs(op0: i32, op1: i32) -> i32 {
    let a = op(op1, 0);
    let b = op(op1, 1);
    if m_c_binop_with(op0, OP_OR, a) >= 0 { return ic_new_binop(OP_OR, op0, b); }
    if m_c_binop_with(op0, OP_OR, b) >= 0 { return ic_new_binop(OP_OR, op0, a); }
    if m_c_binop_both(op0, OP_AND, a, b) { return ic_new_binop(OP_OR, a, b); }
    let some_one = has_one_use(op0) || has_one_use(op1);
    if some_one && (m_not_of(op0, a) || m_not_of(op0, b)) { return ic_new_not(icb_and(a, b, "")); }
    if some_one {
        let n = m_not(op0);
        if n >= 0 && is_inst(n) && m_c_binop_with(n, OP_AND, a) >= 0 { return ic_new_not(icb_and(n, b, "")); }
        if n >= 0 && is_inst(n) && m_c_binop_with(n, OP_AND, b) >= 0 { return ic_new_not(icb_and(n, a, "")); }
    }
    if has_one_use(op0) && has_one_use(op1) && bo(op0, OP_OR) {
        var c: i32 = -1;
        if m_not_of(op(op0, 0), a) { c = op(op0, 1); } else if m_not_of(op(op0, 1), a) { c = op(op0, 0); }
        if c < 0 { if m_not_of(op(op0, 0), b) { c = op(op0, 1); } else if m_not_of(op(op0, 1), b) { c = op(op0, 0); } }
        if c >= 0 {
            let nand = icb_not(icb_and(a, b, ""), "nand");
            return ic_new_binop(OP_OR, nand, c);
        }
    }
    return -1;
}

// m_c_Xor(m_c_Xor(m_Specific(B), m_Value(C)), m_Specific(A)) -> C or -1
fn ao_xor_xor_specific(v: i32, b: i32, a: i32) -> i32 {
    if !bo(v, OP_XOR) { return -1; }
    for k in 2 {
        let inner = op(v, k);
        if op(v, 1 - k) == a {
            let c = m_c_binop_with(inner, OP_XOR, b);
            if c >= 0 { return c; }
        }
    }
    return -1;
}

// m_WithOverflowInst: the binary op (OP_ADD/OP_SUB/OP_MUL) and signedness, or 0
fn ao_with_overflow_op(v: i32) -> i64, bool {
    let id = inst_iid(v);
    if id == IID_sadd_with_overflow { return OP_ADD, true; }
    if id == IID_uadd_with_overflow { return OP_ADD, false; }
    if id == IID_ssub_with_overflow { return OP_SUB, true; }
    if id == IID_usub_with_overflow { return OP_SUB, false; }
    if id == IID_smul_with_overflow { return OP_MUL, true; }
    if id == IID_umul_with_overflow { return OP_MUL, false; }
    return 0, false;
}

// visitOr(I)
fn visit_or(i: i32) -> i32 {
    let v0 = simplify_or(op(i, 0), op(i, 1), sq_at(i), RECURSION_LIMIT);
    if v0 >= 0 { return ic_replace_inst_uses_with(i, v0); }
    if simplify_assoc_or_comm(i) { return i; }
    var r = fold_vector_binop(i);
    if r >= 0 { return r; }
    r = fold_binop_with_phi_operands(i);
    if r >= 0 { return r; }
    if simplify_demanded_instruction_bits(i) { return i; }
    r = ao_fold_or_to_xor(i);
    if r >= 0 { return r; }
    r = ao_fold_complex_and_or_patterns(i);
    if r >= 0 { return r; }
    r = ao_fold_integer_pack_from_vector(i);
    if r >= 0 { return r; }
    var v = ao_fold_or_of_inversions(i);
    if v >= 0 { return ic_replace_inst_uses_with(i, v); }
    v = fold_using_distributive_laws(i);
    if v >= 0 { return ic_replace_inst_uses_with(i, v); }
    var op0 = op(i, 0);
    var op1 = op(i, 1);
    let ty = vals[i].ty;
    if is_int_ty1(ty) {
        if is_select_inst(op0) {
            r = fold_and_or_of_select_using_implied_cond(op1, op0, false);
            if r >= 0 { return r; }
        }
        if is_select_inst(op1) {
            r = fold_and_or_of_select_using_implied_cond(op0, op1, false);
            if r >= 0 { return r; }
        }
    }
    r = fold_binop_into_select_or_phi(i);
    if r >= 0 { return r; }
    r = fold_binop_select_binop(i);
    if r >= 0 { return r; }
    r = match_bswap_or_bitreverse(i, true, true);
    if r >= 0 { return r; }
    r = ao_match_funnel_shift(i);
    if r >= 0 { return r; }
    v = ao_match_or_concat(i);
    if v >= 0 { return ic_replace_inst_uses_with(i, v); }
    r = fold_binop_shift_with_shift(i);
    if r >= 0 { return r; }
    r = try_fold_inst_with_ctpop_with_not(i);
    if r >= 0 { return r; }
    if op_disjoint(i) {
        r = fold_add_like_commutative(op(i, 0), op(i, 1), true, true);
        if r >= 0 { return r; }
        r = fold_add_like_commutative(op(i, 1), op(i, 0), true, true);
        if r >= 0 { return r; }
        v = fold_disjoint_or(op(i, 0), op(i, 1));
        if v >= 0 { return ic_replace_inst_uses_with(i, v); }
        v = ao_reassociate_disjoint_or(op(i, 0), op(i, 1));
        if v >= 0 { return ic_replace_inst_uses_with(i, v); }
    }
    // (X ^ C) | Y -> (X | Y) ^ C iff Y & C == 0
    for k in 2 {
        let xo = op(i, k);
        if one_use(xo) && bo(xo, OP_XOR) && has_apint(op(xo, 1)) {
            let x = op(xo, 0);
            let cv = ap_c(op(xo, 1));
            let y = op(i, 1 - k);
            if !ap_is_all_ones(cv) && ao_masked_zero(y, cv, i) {
                let orv = icb_or(x, y, "");
                return ic_new_binop(OP_XOR, orv, c_int_ap(ty, cv));
            }
            break;
        }
    }
    // or (mul X, Y), X --> mul X, (Y + 1) (disjoint)
    if op_disjoint(i) {
        for k in 2 {
            let m = op(i, k);
            if one_use(m) && bo(m, OP_MUL) && op(i, 1 - k) == op(m, 0) {
                let inc = icb_add(op(m, 1), c_int_ty(ty, 1), "");
                return ic_new_binop(OP_MUL, op(m, 0), inc);
            }
        }
    }
    // ~X | (X-1) => ~(X & -X)
    for k in 2 {
        let n = op(i, k);
        let ad = op(i, 1 - k);
        if one_use(n) && m_not(n) >= 0 {
            let x = m_not(n);
            if one_use(ad) && bo(ad, OP_ADD) && op(ad, 0) == x && m_all_ones(op(ad, 1)) {
                let negx = icb_neg(x, "", false);
                let an = icb_and(x, negx, "");
                return ic_new_not(an);
            }
            break;
        }
    }
    if is_int_ty1(ty) && (has_one_use(op0) || has_one_use(op1)) {
        r = ao_fold_or_of_logical_ands(op0, op1);
        if r >= 0 { return r; }
    }
    if bo(op0, OP_AND) && bo(op1, OP_AND) {
        r = ao_visit_or_and_and(i, op0, op1);
        if r >= -1 { if r >= 0 { return r; } }
    }
    if bo(op0, OP_AND) && (has_one_use(op0) || has_one_use(op1)) {
        let n = m_not(op1);
        if n >= 0 && bo(n, OP_OR) {
            let a = op(op0, 0);
            let c = op(op0, 1);
            let b = op(n, 0);
            let d = op(n, 1);
            var sv = ao_match_select_from_and_or(a, c, b, d, true);
            if sv < 0 { sv = ao_match_select_from_and_or(a, c, d, b, true); }
            if sv < 0 { sv = ao_match_select_from_and_or(c, a, b, d, true); }
            if sv < 0 { sv = ao_match_select_from_and_or(c, a, d, b, true); }
            if sv >= 0 { return ic_replace_inst_uses_with(i, sv); }
        }
    }
    // (A ^ B) | ((B ^ C) ^ A) -> (A ^ B) | C
    if bo(op0, OP_XOR) {
        let a = op(op0, 0);
        let b = op(op0, 1);
        var c = ao_xor_xor_specific(op1, b, a);
        if c < 0 { c = ao_xor_xor_specific(op1, a, b); }
        if c >= 0 { return ic_new_binop(OP_OR, op0, c); }
    }
    if bo(op1, OP_XOR) {
        let a = op(op1, 0);
        let b = op(op1, 1);
        var c = ao_xor_xor_specific(op0, b, a);
        if c < 0 { c = ao_xor_xor_specific(op0, a, b); }
        if c >= 0 { return ic_new_binop(OP_OR, op1, c); }
    }
    r = ao_match_demorgans_laws(i);
    if r >= 0 { return r; }
    var swapped = false;
    if bo(op0, OP_XOR) { let t = op0; op0 = op1; op1 = t; swapped = true; }
    if bo(op1, OP_XOR) {
        r = ao_visit_or_xor_rhs(op0, op1);
        if r >= 0 { return r; }
    }
    if swapped { let t = op0; op0 = op1; op1 = t; }
    let res = fold_boolean_and_or(op0, op1, i, false, false);
    if res >= 0 { return ic_replace_inst_uses_with(i, res); }
    if one_use(op1) && m_logical(op1, false) {
        let x = lg_a;
        let y = lg_b;
        let rv = ao_reassociate_boolean_and_or(op0, x, y, i, false, is_select_inst(op1));
        if rv >= 0 { return ic_replace_inst_uses_with(i, rv); }
    }
    if one_use(op0) && m_logical(op0, false) {
        let x = lg_a;
        let y = lg_b;
        let rv = ao_reassociate_boolean_and_or(op1, x, y, i, false, is_select_inst(op0));
        if rv >= 0 { return ic_replace_inst_uses_with(i, rv); }
    }
    r = ao_reassociate_fcmps(i);
    if r >= 0 { return r; }
    r = fold_casted_bitwise_logic(i);
    if r >= 0 { return r; }
    r = fold_binop_of_sext_bool_to_select(i);
    if r >= 0 { return r; }
    // or(sext(A), B) --> A ? -1 : B
    for k in 2 {
        let s = op(i, k);
        if one_use(s) && m_sext(s) >= 0 {
            let a = m_sext(s);
            if is_int_ty1(vals[a].ty) { return ic_new_select_unknown_prof(a, c_all_ones(ty), op(i, 1 - k)); }
            break;
        }
    }
    // (X|C) | V --> (X|V) | C
    if has_one_use(op0) && m_constant_int(op1) < 0 && bo(op0, OP_OR) && m_constant_int(op(op0, 1)) >= 0 {
        let a = op(op0, 0);
        let ci = op(op0, 1);
        let dout = op_disjoint(i);
        let din = op_disjoint(op0);
        let inner = icb_binop_fl(OP_OR, a, op1, "", if dout { FL_DISJOINT } else { 0 });
        ic_take_name(inner, op0);
        return if dout && din { ic_new_binop_flags(OP_OR, inner, ci, FL_DISJOINT) } else { ic_new_binop(OP_OR, inner, ci) };
    }
    // (or (bool?A:B),(bool?C:D)) --> (bool?(or A,C):(or B,D))
    if has_one_use(op0) && has_one_use(op1) && is_select_inst(op0) && is_select_inst(op1) && op(op0, 0) == op(op1, 0) {
        let ot = icb_or(op(op0, 1), op(op1, 1), "");
        let of = icb_or(op(op0, 2), op(op1, 2), "");
        return ic_new_select(op(op0, 0), ot, of);
    }
    // or(ashr(subNSW(Y, X), ScalarSizeInBits(Y) - 1), X)  --> X s> Y ? -1 : X
    for k in 2 {
        let sh = op(i, k);
        if one_use(sh) && bo(sh, OP_ASHR) && bo(op(sh, 0), OP_SUB) && op_nsw(op(sh, 0)) &&
           m_specific_int(op(sh, 1), (ty_scalar_bits(ty) - 1) as u64) && op(i, 1 - k) == op(op(sh, 0), 1) {
            let x = op(op(sh, 0), 1);
            let y = op(op(sh, 0), 0);
            let cmp = icb_icmp(P_SGT, x, y, "");
            return ic_new_select_unknown_prof(cmp, c_all_ones(ty), x);
        }
    }
    // ((A & B) ^ A) | ((A & B) ^ B) -> A ^ B
    for k in 2 {
        let l = op(i, k);
        let rr = op(i, 1 - k);
        if bo(l, OP_XOR) {
            var a: i32 = -1;
            var b: i32 = -1;
            if bo(op(l, 0), OP_AND) && op(l, 1) == op(op(l, 0), 0) { a = op(op(l, 0), 0); b = op(op(l, 0), 1); }
            else if bo(op(l, 1), OP_AND) && op(l, 0) == op(op(l, 1), 0) { a = op(op(l, 1), 0); b = op(op(l, 1), 1); }
            if a >= 0 && bo(rr, OP_XOR) {
                let hit = (bo(op(rr, 0), OP_AND) && op(op(rr, 0), 0) == a && op(op(rr, 0), 1) == b && op(rr, 1) == b) ||
                          (bo(op(rr, 1), OP_AND) && op(op(rr, 1), 0) == a && op(op(rr, 1), 1) == b && op(rr, 0) == b);
                if hit { return ic_new_binop(OP_XOR, a, b); }
            }
        }
    }
    r = canonicalize_cond_signext_of_high_bit_extract(i);
    if r >= 0 { return r; }
    // umul.with.overflow: Ov | (Mul != 0)
    for k in 2 {
        let ov = op(i, k);
        let mz = op(i, 1 - k);
        if icc_ev_index(ov) != 1 { continue; }
        let um = op(ov, 0);
        if !(ao_cmp_inst(mz) && inst_pred(mz) == P_NE && m_zero_int(op(mz, 1))) { continue; }
        let mul = op(mz, 0);
        if icc_ev_index(mul) != 0 || op(mul, 0) != um { continue; }
        if !(has_one_use(ov) || (has_one_use(mz) && has_one_use(mul))) { break; }
        if m_intrinsic(um, IID_umul_with_overflow) {
            let na = icb_is_not_null(op(um, 0), "");
            let nb = icb_is_not_null(op(um, 1), "");
            return ic_new_binop(OP_AND, na, nb);
        }
        break;
    }
    // Overflow | icmp pred Res, C2  -->  Overflow | icmp pred X, C2 -/+ C1
    for k in 2 {
        let ov = op(i, k);
        let cm = op(i, 1 - k);
        if icc_ev_index(ov) != 1 { continue; }
        let wov = op(ov, 0);
        let bop, signed = ao_with_overflow_op(wov);
        if bop == 0 { continue; }
        if !(one_use(cm) && ao_cmp_inst(cm) && icc_ev_index(op(cm, 0)) == 0 && op(op(cm, 0), 0) == wov && has_apint(op(cm, 1))) { continue; }
        let p = inst_pred(cm);
        let c2 = ap_c(op(cm, 1));
        if (bop == OP_ADD || bop == OP_SUB) && (icmp_is_equality(p) || signed == pred_is_signed(p)) && has_apint(op(wov, 1)) {
            let c1 = ap_c(op(wov, 1));
            var nc = c2;
            var ovf = false;
            if bop == OP_ADD {
                if pred_is_signed(p) { let a, o = ap_ssub_ov(c2, c1); nc = a; ovf = o; } else { let a, o = ap_usub_ov(c2, c1); nc = a; ovf = o; }
            } else {
                if pred_is_signed(p) { let a, o = ap_sadd_ov(c2, c1); nc = a; ovf = o; } else { let a, o = ap_uadd_ov(c2, c1); nc = a; ovf = o; }
            }
            if !ovf || icmp_is_equality(p) {
                let l = op(wov, 0);
                let ncmp = icb_icmp(p, l, c_int_ap(vals[l].ty, nc), "");
                return ic_new_binop(OP_OR, ov, ncmp);
            }
        }
        break;
    }
    v = ao_fold_or_unsigned_umul_overflow_icmp(i);
    if v >= 0 { return ic_replace_inst_uses_with(i, v); }
    if sink_not_into_other_hand_of_logical_op(i) { return i; }
    // (1 << X) | ((1 << X) + -1)  -->  -1 l>> (bitwidth(x) - 1 - X)
    for k in 2 {
        let ad = op(i, k);
        let sh = op(i, 1 - k);
        if bo(ad, OP_ADD) && m_all_ones(op(ad, 1)) && bo(op(ad, 0), OP_SHL) && m_one(op(op(ad, 0), 0)) {
            let x = op(op(ad, 0), 1);
            if bo(sh, OP_SHL) && m_one(op(sh, 0)) && op(sh, 1) == x {
                if one_use(op0) || one_use(op1) {
                    let sb = icb_sub(c_int_ty(ty, (ty_scalar_bits(ty) - 1) as u64), x, "");
                    return ic_new_binop(OP_LSHR, c_all_ones(ty), sb);
                }
                break;
            }
        }
    }
    {
        let ok, pn, start, step = ao_match_simple_recurrence(i);
        if ok && dt_value_dominates_inst(step, pn) { return ic_replace_inst_uses_with(i, icb_or(start, step, "")); }
    }
    // (A & B) | (C | D)
    for k in 2 {
        let an = op(i, k);
        let orv = op(i, 1 - k);
        if one_use(an) && bo(an, OP_AND) && one_use(orv) && bo(orv, OP_OR) {
            let a = op(an, 0);
            let b = op(an, 1);
            let c = op(orv, 0);
            let d = op(orv, 1);
            if one_use(d) && (m_c_binop_with(d, OP_AND, a) >= 0 || m_c_binop_with(d, OP_AND, b) >= 0) {
                return ic_new_binop(OP_OR, c, icb_or(d, icb_and(a, b, ""), ""));
            }
            if one_use(c) && (m_c_binop_with(c, OP_AND, a) >= 0 || m_c_binop_with(c, OP_AND, b) >= 0) {
                return ic_new_binop(OP_OR, icb_or(c, icb_and(a, b, ""), ""), d);
            }
            break;
        }
    }
    r = ao_reassociate_for_uses(i);
    if r >= 0 { return r; }
    r = ao_canonicalize_logic_first(i);
    if r >= 0 { return r; }
    r = ao_fold_logic_of_is_fpclass(i, op0, op1);
    if r >= 0 { return r; }
    r = fold_binop_of_displaced_shifts(i);
    if r >= 0 { return r; }
    {
        let castop = ao_elementwise_bitcast(op0);
        if castop >= 0 && m_sign_mask(op1) && !ao_has_no_implicit_float() {
            let et = ty_scalar(vals[castop].ty);
            if ty_is_fp(et) {
                let fa = ao_fabs(castop, icb_fmf);
                let fn2 = ao_fneg(fa);
                return ic_new_cast(OP_BITCAST, fn2, ty);
            }
        }
    }
    // (X & C1) | C2 -> X & (C1 | C2) iff (X & C2) == C2
    if one_use(op0) && bo(op0, OP_AND) && has_apint(op(op0, 1)) && has_apint(op1) {
        let x = op(op0, 0);
        let c2 = ap_c(op1);
        let kx = ao_kb(x, i);
        if ap_eq(ap_and(kx.o, c2), c2) { return ic_new_binop(OP_AND, x, c_int_ap(ty, ap_or(ap_c(op(op0, 1)), c2))); }
    }
    r = ao_fold_bitwise_logic_with_intrinsics(i);
    if r >= 0 { return r; }
    let s0 = ao_simplify_and_or_with_op_replaced(op0, op1, c_null(ty), false, 0);
    if s0 >= 0 { return ic_new_binop(OP_OR, s0, op1); }
    let s1 = ao_simplify_and_or_with_op_replaced(op1, op0, c_null(ty), false, 0);
    if s1 >= 0 { return ic_new_binop(OP_OR, op0, s1); }
    if op_disjoint(i) {
        v = simplify_add_with_remainder(i);
        if v >= 0 { return ic_replace_inst_uses_with(i, v); }
    }
    v = ao_fold_or_of_select_smax_to_abs(i);
    if v >= 0 { return ic_replace_inst_uses_with(i, v); }
    // signum: or (ashr X, BW-1), zext (icmp ne|sgt X, 0) --> scmp(X, 0)
    {
        let bw = ty_scalar_bits(ty);
        for k in 2 {
            let sh = op(i, k);
            let z = op(i, 1 - k);
            if !(bo(sh, OP_ASHR) && m_specific_int_ap(op(sh, 1), (bw - 1) as u64)) { continue; }
            let x = op(sh, 0);
            let cm = m_zext(z);
            if !(cm >= 0 && ao_cmp_inst(cm) && op(cm, 0) == x && m_zero_int(op(cm, 1))) { continue; }
            let sp = inst_pred(cm);
            if (sp == P_NE || sp == P_SGT) && (has_one_use(op0) || has_one_use(op1)) {
                let z0 = c_null(ty);
                return ic_replace_inst_uses_with(i, icb_intrinsic(IID_scmp, [ty, ty], [x, z0], ""));
            }
            break;
        }
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// visitXor

fn visit_xor(i: i32) -> i32 {
    let v0 = simplify_xor(op(i, 0), op(i, 1), sq_at(i), RECURSION_LIMIT);
    if v0 >= 0 { return ic_replace_inst_uses_with(i, v0); }
    if simplify_assoc_or_comm(i) { return i; }
    var r = fold_vector_binop(i);
    if r >= 0 { return r; }
    r = fold_binop_with_phi_operands(i);
    if r >= 0 { return r; }
    r = ao_fold_xor_to_xor(i);
    if r >= 0 { return r; }
    let dl = fold_using_distributive_laws(i);
    if dl >= 0 { return ic_replace_inst_uses_with(i, dl); }
    if simplify_demanded_instruction_bits(i) { return i; }
    r = fold_not(i);
    if r >= 0 { return r; }
    r = fold_binop_shift_with_shift(i);
    if r >= 0 { return r; }
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    let ty = vals[i].ty;
    // (X | Y) ^ M -> (X ^ M) ^ Y
    for k in 2 {
        let o = op(i, k);
        if one_use(o) && m_disjoint_or(o) {
            let x = op(o, 0);
            let y = op(o, 1);
            let m = op(i, 1 - k);
            let xac = simplify_xor(x, m, sq_at(i), RECURSION_LIMIT);
            if xac >= 0 { return ic_new_binop(OP_XOR, xac, y); }
            let xbc = simplify_xor(y, m, sq_at(i), RECURSION_LIMIT);
            if xbc >= 0 { return ic_new_binop(OP_XOR, xbc, x); }
            break;
        }
    }
    // (X & M) ^ (Y & ~M) -> (X & M) | (Y & ~M)
    for k in 2 {
        let a0 = op(i, k);
        let a1 = op(i, 1 - k);
        let ok, m, unused = ao_c_binop_not_first(a0, OP_AND);
        if ok && m_c_binop_with(a1, OP_AND, m) >= 0 {
            if is_guaranteed_not_to_be_undef(m, -1, 0) { return ic_new_binop_flags(OP_OR, op0, op1, FL_DISJOINT); }
            return ic_new_binop(OP_OR, op0, op1);
        }
    }
    r = ao_visit_masked_merge(i);
    if r >= 0 { return r; }
    if is_constant(op1) {
        let c1 = op1;
        if one_use(op0) && bo(op0, OP_OR) && ao_imm(op(op0, 1)) && ao_imm(c1) {
            let x = op(op0, 0);
            let c2 = replace_undefs_with(op(op0, 1), c_all_ones(ty_scalar(vals[op(op0, 1)].ty)));
            let an = icb_and(x, ao_merge_undefs_with(ce_not(c2), c1), "");
            return ic_new_binop(OP_XOR, an, ao_merge_undefs_with(ce_binop(OP_XOR, c1, c2, 0), c1));
        }
        if one_use(op0) && bo(op0, OP_OR) && m_not(op(op0, 0)) >= 0 && is_constant(op(op0, 1)) {
            let an = icb_and(m_not(op(op0, 0)), ce_not(op(op0, 1)), "");
            return ic_new_binop(OP_XOR, an, ce_not(c1));
        }
        if one_use(op0) && bo(op0, OP_AND) && m_not(op(op0, 0)) >= 0 && is_constant(op(op0, 1)) {
            let orv = icb_or(m_not(op(op0, 0)), ce_not(op(op0, 1)), "");
            return ic_new_binop(OP_XOR, orv, ce_not(c1));
        }
        if one_use(op0) {
            var sh: i32 = -1;
            let t = m_trunc(op0);
            if t >= 0 && bo(t, OP_ASHR) && has_apint_poison(op(t, 1)) { sh = t; }
            else if bo(op0, OP_ASHR) && has_apint_poison(op(op0, 1)) { sh = op0; }
            if sh >= 0 {
                let x = op(sh, 0);
                if ap_eq_u64(ap_cp(op(sh, 1)), (ty_sbits(x) - 1) as u64) && !m_all_ones(c1) {
                    let inn = ao_is_not_neg(x, "");
                    return ic_new_select_unknown_prof(inn, op1, icb_not(op1, ""));
                }
            }
        }
    }
    if has_apint(op1) {
        let rhsc = ap_c(op1);
        if ap_is_sign_mask(rhsc) && bo(op0, OP_SUB) && has_apint(op(op0, 0)) {
            return ic_new_binop(OP_SUB, c_int_ap(ty, ap_add(ap_c(op(op0, 0)), rhsc)), op(op0, 1));
        }
        if ap_is_sign_mask(rhsc) && bo(op0, OP_ADD) && has_apint(op(op0, 1)) {
            return ic_new_binop(OP_ADD, op(op0, 0), c_int_ap(ty, ap_add(ap_c(op(op0, 1)), rhsc)));
        }
        if bo(op0, OP_OR) && has_apint(op(op0, 1)) && ao_masked_zero(op(op0, 0), ap_c(op(op0, 1)), i) {
            return ic_new_binop(OP_XOR, op(op0, 0), c_int_ap(ty, ap_xor(ap_c(op(op0, 1)), rhsc)));
        }
        let iid = inst_iid(op0);
        if iid != 0 && has_one_use(op0) && ap_eq_u64(rhsc, (ty_scalar_bits(ty) - 1) as u64) {
            if (iid == IID_ctlz || iid == IID_cttz) && m_one(op(op0, 1)) && ao_pow2(op(op0, 0), true, -1) {
                let nid = if iid == IID_ctlz { IID_cttz } else { IID_ctlz };
                let tr = c_bool_ty(T_I1, true);
                let a0 = op(op0, 0);
                return ic_new_intrinsic(nid, [ty], [a0, tr]);
            }
        }
        let w = ty_scalar_bits(ty);
        if one_use(op0) && bo(op0, OP_SHL) && has_apint(op(op0, 1)) && ap_eq(rhsc, ap_shl_ap(ap_ones(w), ap_c(op(op0, 1)))) {
            let notx = icb_not(op(op0, 0), "");
            return ic_new_binop(OP_SHL, notx, c_int_ap(ty, ap_c(op(op0, 1))));
        }
        if one_use(op0) && bo(op0, OP_LSHR) && has_apint(op(op0, 1)) && ap_eq(rhsc, ap_lshr_ap(ap_ones(w), ap_c(op(op0, 1)))) {
            let notx = icb_not(op(op0, 0), "");
            return ic_new_binop(OP_LSHR, notx, c_int_ap(ty, ap_c(op(op0, 1))));
        }
    }
    {
        let castop = ao_elementwise_bitcast(op0);
        if castop >= 0 && m_sign_mask(op1) && !ao_has_no_implicit_float() {
            let et = ty_scalar(vals[castop].ty);
            if ty_is_fp(et) {
                let fng = ao_fneg(castop);
                return ic_new_cast(OP_BITCAST, fng, ty);
            }
        }
    }
    // ((X^C1) >> C2) ^ C3 -> (X>>C2) ^ ((C1>>C2)^C3)
    if m_constant_int(op1) >= 0 && bo(op0, OP_LSHR) && m_constant_int(op(op0, 1)) >= 0 && bo(op(op0, 0), OP_XOR) &&
       m_constant_int(op(op(op0, 0), 1)) >= 0 && has_one_use(op0) {
        let x = op(op(op0, 0), 0);
        let c1 = ci_ap(op(op(op0, 0), 1));
        let c2 = op(op0, 1);
        var fc = ap_lshr_ap(c1, ci_ap(c2));
        fc = ap_xor(fc, ci_ap(op1));
        let o0 = icb_lshr(x, c2, "", false);
        ic_take_name(o0, op0);
        return ic_new_binop(OP_XOR, o0, c_int_ap(ty, fc));
    }
    r = fold_binop_into_select_or_phi(i);
    if r >= 0 { return r; }
    r = fold_binop_select_binop(i);
    if r >= 0 { return r; }
    // Y ^ (X | Y) --> X & ~Y
    if one_use(op1) { let x = m_c_binop_with(op1, OP_OR, op0); if x >= 0 { return ic_new_binop(OP_AND, x, icb_not(op0, "")); } }
    if one_use(op0) { let x = m_c_binop_with(op0, OP_OR, op1); if x >= 0 { return ic_new_binop(OP_AND, x, icb_not(op1, "")); } }
    // Y ^ (X & Y) --> ~X & Y
    if one_use(op1) { let x = m_c_binop_with(op1, OP_AND, op0); if x >= 0 { return ic_new_binop(OP_AND, op0, icb_not(x, "")); } }
    if !is_constant(op1) && one_use(op0) { let x = m_c_binop_with(op0, OP_AND, op1); if x >= 0 { return ic_new_binop(OP_AND, op1, icb_not(x, "")); } }
    // (A ^ B) ^ (A | C) --> (~A & C) ^ B ; (A ^ B) ^ (B | C) --> (~B & C) ^ A
    for pass in 2 {
        for k in 2 {
            let xo = op(i, k);
            let orv = op(i, 1 - k);
            if one_use(xo) && bo(xo, OP_XOR) {
                let a = op(xo, 0);
                let b = op(xo, 1);
                let key = if pass == 0 { a } else { b };
                let other = if pass == 0 { b } else { a };
                if one_use(orv) {
                    let c = m_c_binop_with(orv, OP_OR, key);
                    if c >= 0 { return ic_new_binop(OP_XOR, icb_and(icb_not(key, ""), c, ""), other); }
                }
            }
        }
    }
    // (A & B) ^ (A ^ B) -> (A | B)
    if bo(op0, OP_AND) && m_c_binop_both(op1, OP_XOR, op(op0, 0), op(op0, 1)) { return ic_new_binop(OP_OR, op(op0, 0), op(op0, 1)); }
    if bo(op0, OP_XOR) && m_c_binop_both(op1, OP_AND, op(op0, 0), op(op0, 1)) { return ic_new_binop(OP_OR, op(op0, 0), op(op0, 1)); }
    // (A & ~B) ^ ~A -> ~(A & B)
    {
        let ok, a, b = ao_c_binop_val_not(op0, OP_AND);
        if ok && m_not_of(op1, a) { return ic_new_not(icb_and(a, b, "")); }
    }
    // (~A & B) ^ A --> A | B
    for k in 2 {
        let an = op(i, k);
        let ok, a, b = ao_c_binop_not_first(an, OP_AND);
        if ok {
            if op(i, 1 - k) == a { return ic_new_binop(OP_OR, a, b); }
            break;
        }
    }
    // (~A | B) ^ A --> ~(A & B)
    if one_use(op0) && bo(op0, OP_OR) {
        var b: i32 = -1;
        if m_not_of(op(op0, 0), op1) { b = op(op0, 1); } else if m_not_of(op(op0, 1), op1) { b = op(op0, 0); }
        if b >= 0 { return ic_new_not(icb_and(op1, b, "")); }
    }
    if one_use(op1) && bo(op1, OP_OR) {
        var b: i32 = -1;
        if m_not_of(op(op1, 0), op0) { b = op(op1, 1); } else if m_not_of(op(op1, 1), op0) { b = op(op1, 0); }
        if b >= 0 { return ic_new_not(icb_and(op0, b, "")); }
    }
    // (A | B) ^ (A | C) --> (B ^ C) & ~A
    if one_use(op0) && bo(op0, OP_OR) && one_use(op1) && bo(op1, OP_OR) {
        var a = op(op0, 0);
        var b = op(op0, 1);
        var c = op(op1, 0);
        var d = op(op1, 1);
        if b == c || b == d { let t = a; a = b; b = t; }
        if a == c { let t = c; c = d; d = t; }
        if a == d {
            let nota = icb_not(a, "");
            return ic_new_binop(OP_AND, icb_xor(b, c, ""), nota);
        }
    }
    // (A & B) ^ (A | C) --> A ? ~B : C (logical)
    if is_int_ty1(ty) {
        for k in 2 {
            let la = op(i, k);
            let lo = op(i, 1 - k);
            if !(one_use(la) && m_logical(la, true)) { continue; }
            var a = lg_a;
            var b = lg_b;
            if !(one_use(lo) && m_logical(lo, false)) { continue; }
            var c = lg_a;
            var d = lg_b;
            let need_freeze = is_select_inst(op0) && is_select_inst(op1) && b == d;
            var mdfrom = op0;
            if b == c || b == d {
                let t = a; a = b; b = t;
                mdfrom = if b == c { op1 } else { -1 };
            }
            if a == c { let t = c; c = d; d = t; }
            if a == d {
                if need_freeze { a = icb_freeze(a, ""); }
                let notb = icb_not(b, "");
                return if mdfrom < 0 { ic_new_select_unknown_prof(a, notb, c) } else { ic_new_select_md_all(a, notb, c, mdfrom) };
            }
            break;
        }
    }
    if ao_cmp_inst(op0) && ao_cmp_inst(op1) {
        let v = fold_xor_of_icmps(op0, op1, i);
        if v >= 0 { return ic_replace_inst_uses_with(i, v); }
    }
    r = fold_casted_bitwise_logic(i);
    if r >= 0 { return r; }
    r = ao_canonicalize_abs(i);
    if r >= 0 { return r; }
    // (X ^ C) ^ Y --> (X ^ Y) ^ C
    for k in 2 {
        let xo = op(i, k);
        if one_use(xo) && bo(xo, OP_XOR) && !m_constant_expr(op(xo, 0)) && ao_imm(op(xo, 1)) {
            let y = op(i, 1 - k);
            return ic_new_binop(OP_XOR, icb_xor(op(xo, 0), y, ""), op(xo, 1));
        }
    }
    r = ao_reassociate_for_uses(i);
    if r >= 0 { return r; }
    r = ao_canonicalize_logic_first(i);
    if r >= 0 { return r; }
    r = ao_fold_logic_of_is_fpclass(i, op0, op1);
    if r >= 0 { return r; }
    r = ao_canonicalize_conditional_negation_via_math_to_select(i);
    if r >= 0 { return r; }
    r = fold_binop_of_displaced_shifts(i);
    if r >= 0 { return r; }
    r = ao_fold_bitwise_logic_with_intrinsics(i);
    if r >= 0 { return r; }
    r = ao_fold_masked_add_xor_pattern(i);
    if r >= 0 { return r; }
    return -1;
}
