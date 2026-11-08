// InstCombine compares: port of llvm/lib/Transforms/InstCombine/InstCombineCompares.cpp (visitICmpInst,
// visitFCmpInst and every helper of that file), in the order of the C++ file; each visitor tries its folds in
// LLVM's sequence (the first fold that fires wins). Helpers that LLVM keeps in other files are ported where
// noted (decomposeLinearExpression: Analysis/Loads.cpp; CmpInstAnalysis: decomposeBitTestICmp,
// getPredForICmpCode).
//
// Conventions (DESIGN.md §12): a fold returns an instruction id: -1 = nullptr, the visited instruction =
// modified in place, or a new unattached instruction. Predicates are LLVM's numbers (fcmp 0..15, icmp 32..41);
// a CmpPredicate (predicate + samesign) is implied.goose's `cp(p, samesign)` encoding.
namespace ic;
import std;
import ir;
import irutil;
import calls;
import instinfo;
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
import capture;
import ic_addsub;
import ic;
import ic_builder;
import ic_common;
import ic_shifts;
import ic_casts;
import ic_demanded;
import ic_andorxor;

// ---------------------------------------------------------------------------------------------
// Small helpers

let P_FALSE = 0;
let P_OEQ = 1;
let P_OGT = 2;
let P_OGE = 3;
let P_OLT = 4;
let P_OLE = 5;
let P_ONE = 6;
let P_ORD = 7;
let P_UNO = 8;
let P_UEQ = 9;
let P_FUGT = 10;
let P_FUGE = 11;
let P_FULT = 12;
let P_FULE = 13;
let P_UNE = 14;
let P_TRUE = 15;

fn icc_pred(i: i32) -> i64 { inst_pred(i) }
fn icc_samesign(i: i32) -> bool { (insts[inst_of(i)].flags & FL_SAMESIGN) != 0 }
fn icc_set_samesign(i: i32, b: bool) {
    let ii = inst_of(i);
    if b { insts[ii].flags |= FL_SAMESIGN; } else { insts[ii].flags &= ~FL_SAMESIGN; }
}
fn icc_set_pred(i: i32, p: i64) { insts[inst_of(i)].pred = p as u8; }
// new ICmpInst(CmpPredicate, ...) keeps only the predicate (the constructor takes a Predicate)
fn icc_new(p: i64, a: i32, b: i32) -> i32 { ic_new_icmp(cp_pred(p), a, b) }
fn icc_true_false(ty: i32, b: bool) -> i32 { c_bool_ty(ty, b) }
fn icc_kb(v: i32, cx: i32) -> KB { kb_cxt = cx; return kb_compute_all(v, 0); }
fn icc_nonzero(v: i32, cx: i32) -> bool { kb_cxt = cx; return is_known_non_zero(v, 0); }
fn icc_pow2(v: i32, or_zero: bool, cx: i32) -> bool { kb_cxt = cx; return is_known_pow2(v, or_zero, 0); }
fn icc_signbits(v: i32, cx: i32) -> i64 { kb_cxt = cx; return num_sign_bits(v, 0); }
// ComputeMaxSignificantBits
fn icc_max_sig_bits(v: i32, cx: i32) -> i64 { ty_sbits(v) - icc_signbits(v, cx) + 1 }
// isKnownPositive(V, SQ)
fn icc_known_positive(v: i32, cx: i32) -> bool {
    if vals[v].kind == VK_CINT { return ap_is_strictly_pos(ci_ap(v)); }
    let k = icc_kb(v, cx);
    return kb_is_nonneg(k) && (kb_is_nonzero(k) || icc_nonzero(v, cx));
}
fn icc_known_negative(v: i32, cx: i32) -> bool { kb_is_neg(icc_kb(v, cx)) }
fn icc_known_nonneg(v: i32, cx: i32) -> bool { kb_is_nonneg(icc_kb(v, cx)) }
fn icc_is_shr(v: i32) -> bool { bo(v, OP_LSHR) || bo(v, OP_ASHR) }
fn icc_is_irem(v: i32) -> bool { bo(v, OP_UREM) || bo(v, OP_SREM) }
fn icc_is_idiv(v: i32) -> bool { bo(v, OP_UDIV) || bo(v, OP_SDIV) }
fn icc_bool(b: bool) -> i64 { if b { 1 } else { 0 } }
// m_TruncOrSelf
fn icc_trunc_or_self(v: i32) -> i32 { let t = m_trunc(v); if t >= 0 { t } else { v } }
// m_ZExtOrSelf / m_SExtOrSelf
fn icc_zext_or_self(v: i32) -> i32 { let t = m_zext(v); if t >= 0 { t } else { v } }
// trunc nuw / nsw flags
fn icc_trunc_nuw(v: i32) -> bool { is_inst_op(v, OP_TRUNC) && (insts[inst_of(v)].flags & FL_NUW) != 0 }
fn icc_trunc_nsw(v: i32) -> bool { is_inst_op(v, OP_TRUNC) && (insts[inst_of(v)].flags & FL_NSW) != 0 }
fn icc_nneg(v: i32) -> bool { is_inst(v) && (insts[inst_of(v)].flags & FL_NNEG) != 0 }
fn icc_disjoint(v: i32) -> bool { bo(v, OP_OR) && op_disjoint(v) }
// CmpInst::isCommutative for icmp: equality predicates
fn icc_fcmp_swapped(p: i64) -> i64 {
    match p { 2 => 4, 3 => 5, 4 => 2, 5 => 3, 10 => 12, 11 => 13, 12 => 10, 13 => 11, _ => p }
}
fn icc_fcmp_inverse(p: i64) -> i64 { 15 - p }

// ICmpInst::swapOperands / FCmpInst::swapOperands
fn icc_swap_operands(i: i32) {
    let p = icc_pred(i);
    icc_set_pred(i, if iop(i) == OP_ICMP { pred_swapped(p) } else { icc_fcmp_swapped(p) });
    let u0 = vals[i].ops;
    cu_use_swap(u0, u0 + 1);
}

// ExtractValueInst::Create(Agg, Idx) (unattached)
fn icc_new_extractvalue(agg: i32, idx: i64) -> i32 {
    let ty = ty_field(vals[agg].ty, idx);
    let v = new_inst(OP_EXTRACTVALUE, ty, 1);
    set_op(v, 0, agg);
    let ii = inst_of(v);
    insts[ii].aux = ints.len as i32;
    insts[ii].naux = 1;
    ints.push(idx as i32);
    return v;
}
// IRBuilder::CreateExtractValue (folds constants)
fn icb_extractvalue(agg: i32, idx: i64, name: const u8[:]) -> i32 {
    if is_constant(agg) {
        let f = cf_extractvalue(agg, [idx as i32]);
        if f >= 0 { return f; }
    }
    return icb_insert(icc_new_extractvalue(agg, idx), name);
}
// IRBuilder::CreateCall of an intrinsic declaration (no folding)
fn icb_call_intrinsic(id: i64, ov: const i32[:], argsv: const i32[:], name: const u8[:]) -> i32 {
    return icb_insert(ic_new_intrinsic(id, ov, argsv), name);
}

// m_Signum(V): (ashr V, BW-1) | (lshr (sub 0, V), BW-1), commuted
fn icc_m_signum(v: i32) -> i32 {
    if !bo(v, OP_OR) { return -1; }
    let sw = ty_sbits(v) - 1;
    for k in 2 {
        let l = op(v, k);
        let r = op(v, 1 - k);
        if !bo(l, OP_ASHR) || !m_specific_int(op(l, 1), sw as u64) { continue; }
        let x = op(l, 0);
        if bo(r, OP_LSHR) && m_neg(op(r, 0)) == x && m_specific_int(op(r, 1), sw as u64) { return x; }
    }
    return -1;
}

// hasBranchUse(I)
fn has_branch_use(i: i32) -> bool {
    var u = vals[i].first_use;
    while u >= 0 { if iop(uses[u].user) == OP_CONDBR { return true; } u = uses[u].next; }
    return false;
}

// isSignTest(Pred, C): (is a sign test, updated predicate)
fn is_sign_test(p: i64, c: AP) -> bool, i64 {
    if !pred_is_signed(p) { return false, p; }
    if ap_is_zero(c) { return pred_relational(p), p; }
    if ap_is_one(c) {
        if p == P_SLT { return true, P_SLE; }
    } else if ap_is_all_ones(c) {
        if p == P_SGT { return true, P_SGE; }
    }
    return false, p;
}

// I.user_back(): the most recently added user
fn icc_user_back(i: i32) -> i32 { let u = vals[i].first_use; if u < 0 { -1 } else { uses[u].user } }

// ---------------------------------------------------------------------------------------------
// foldCmpLoadFromIndexedGlobal, foldGEPICmp, foldAllocaCmp: see the "pointers and memory" section below.

// foldICmpAddOpConst(X, C, Pred): "icmp pred (X+C), X"
fn fold_icmp_add_op_const(x: i32, c: AP, p0: i64) -> i32 {
    let p = cp_pred(p0);
    let w = c.w as i64;
    let ty = vals[x].ty;
    if p == P_ULT || p == P_ULE { return ic_new_icmp(P_UGT, x, c_int_ap(ty, ap_sub(ap_umax_val(w), c))); }
    if p == P_UGT || p == P_UGE { return ic_new_icmp(P_ULT, x, c_int_ap(ty, ap_neg(c))); }
    let smax = ap_smax_val(w);
    if p == P_SLT || p == P_SLE { return ic_new_icmp(P_SGT, x, c_int_ap(ty, ap_sub(smax, c))); }
    return ic_new_icmp(P_SLT, x, c_int_ap(ty, ap_sub(smax, ap_dec(c))));
}

// foldICmpShrConstConst(I, A, AP1, AP2): "(icmp eq/ne (ashr/lshr AP2, A), AP1)"
fn fold_icmp_shr_const_const(i: i32, a: i32, ap1: AP, ap2: AP) -> i32 {
    let ne = icc_pred(i) == P_NE;
    if ap_is_zero(ap2) { return -1; }
    let is_ashr = is_op(op(i, 0), OP_ASHR);
    if is_ashr {
        if ap_is_all_ones(ap2) { return -1; }
        if ap_is_neg(ap2) != ap_is_neg(ap1) { return -1; }
        if ap_sgt(ap2, ap1) { return -1; }
    }
    let aty = vals[a].ty;
    if ap_is_zero(ap1) { return icc_get_icmp(ne, P_UGT, a, c_int_ty(aty, ap_log2(ap2) as u64)); }
    if ap_eq(ap1, ap2) { return icc_get_icmp(ne, P_EQ, a, c_null(aty)); }
    var shift: i64 = 0;
    if is_ashr && ap_is_neg(ap1) { shift = ap_countl_one(ap1) - ap_countl_one(ap2); }
    else { shift = ap_countl_zero(ap1) - ap_countl_zero(ap2); }
    if shift > 0 {
        if is_ashr && ap_eq(ap1, ap_ashr(ap2, shift)) {
            if ap_is_all_ones(ap1) && !ap_is_pow2(ap2) { return icc_get_icmp(ne, P_UGE, a, c_int_ty(aty, shift as u64)); }
            return icc_get_icmp(ne, P_EQ, a, c_int_ty(aty, shift as u64));
        } else if ap_eq(ap1, ap_lshr(ap2, shift)) {
            return icc_get_icmp(ne, P_EQ, a, c_int_ty(aty, shift as u64));
        }
    }
    return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, ne));
}
fn icc_get_icmp(ne: bool, p: i64, l: i32, r: i32) -> i32 {
    return ic_new_icmp(if ne { pred_inverse(p) } else { p }, l, r);
}

// foldICmpShlConstConst(I, A, AP1, AP2): "(icmp eq/ne (shl AP2, A), AP1)"
fn fold_icmp_shl_const_const(i: i32, a: i32, ap1: AP, ap2: AP) -> i32 {
    let ne = icc_pred(i) == P_NE;
    if ap_is_zero(ap2) { return -1; }
    let tz2 = ap_countr_zero(ap2);
    let aty = vals[a].ty;
    if ap_is_zero(ap1) && tz2 != 0 { return icc_get_icmp(ne, P_UGE, a, c_int_ty(aty, (ap2.w as i64 - tz2) as u64)); }
    if ap_eq(ap1, ap2) { return icc_get_icmp(ne, P_EQ, a, c_null(aty)); }
    let shift = ap_countr_zero(ap1) - tz2;
    if shift > 0 && ap_eq(ap_shl(ap2, shift), ap1) { return icc_get_icmp(ne, P_EQ, a, c_int_ty(aty, shift as u64)); }
    return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, ne));
}

// processUGT_ADDCST_ADD(I, A, B, CI2, CI1, IC)
fn process_ugt_addcst_add(i: i32, a: i32, b: i32, ci2: i32, ci1: i32) -> i32 {
    let add_cst = op(i, 0);
    if !has_one_use(add_cst) { return -1; }
    let c2 = ci_ap(ci2);
    if !ap_is_pow2(c2) { return -1; }
    var nw = ap_countr_zero(c2);
    if nw != 7 && nw != 15 && nw != 31 { return -1; }
    nw++;
    let c1 = ci_ap(ci1);
    if (c1.w as i64) == nw || !ap_eq(c1, ap_low_bits(c1.w as i64, nw)) { return -1; }
    if icc_max_sig_bits(a, i) > nw || icc_max_sig_bits(b, i) > nw { return -1; }
    let orig = op(add_cst, 0);
    var u = vals[orig].first_use;
    while u >= 0 {
        let us = uses[u].user;
        u = uses[u].next;
        if us == add_cst { continue; }
        if !is_inst_op(us, OP_TRUNC) || ty_bits(vals[us].ty) > nw { return -1; }
    }
    let nty = ty_int(nw);
    icb_set_insert_point(orig);
    var nm: u8[>..] = [];
    nm.append(val_name(a)); nm.append(".trunc");
    let ta = icb_trunc(a, nty, nm);
    var nm2: u8[>..] = [];
    nm2.append(val_name(b)); nm2.append(".trunc");
    let tb = icb_trunc(b, nty, nm2);
    let call = icb_call_intrinsic(IID_sadd_with_overflow, [nty], [ta, tb], "sadd");
    let add = icb_extractvalue(call, 0, "sadd.result");
    let zx = icb_zext(add, vals[orig].ty, "");
    ic_replace_inst_uses_with(orig, zx);
    ic_erase(orig);
    let r = icc_new_extractvalue(call, 1);
    set_name(r, "sadd.overflow");
    return r;
}

// foldIRemByPowerOfTwoToBitTest(I)
fn fold_irem_by_power_of_two_to_bit_test(i: i32) -> i32 {
    let p = icc_pred(i);
    if !icmp_is_equality(p) { return -1; }
    let r = op(i, 0);
    let zero = op(i, 1);
    if !one_use(r) || !icc_is_irem(r) || !m_zero(zero) { return -1; }
    let x = op(r, 0);
    let y = op(r, 1);
    if !icc_pow2(y, true, i) { return -1; }
    let mask = icb_add(y, c_all_ones(vals[y].ty), "");
    let masked = icb_and(x, mask, "");
    return ic_new_icmp(p, masked, zero);
}

// foldSignBitTest(I)
fn fold_sign_bit_test(i: i32) -> i32 {
    let p = icc_pred(i);
    let val = op(i, 0);
    if !icmp_is_equality(p) || !is_inst(val) || !m_zero(op(i, 1)) { return -1; }
    var x: i32 = -1;
    let t = icc_trunc_or_self(val);
    if icc_is_shr(t) && is_constant(op(t, 1)) {
        x = op(t, 0);
        let xbw = ty_sbits(x);
        if !c_all_elts_cmp(op(t, 1), P_EQ, (xbw - 1) as u64) { return -1; }
    } else if is_binop_inst(val) {
        x = reassociate_shift_amts(val, true);
        if x < 0 { return -1; }
    } else { return -1; }
    return ic_new_icmp(if p == P_EQ { P_SGE } else { P_SLT }, x, c_null(vals[x].ty));
}

// foldICmpWithZero(Cmp): icmp pred X, 0
fn fold_icmp_with_zero(cmp: i32) -> i32 {
    let p = icc_pred(cmp);
    let o0 = op(cmp, 0);
    let o1 = op(cmp, 1);
    if !m_zero(o1) { return -1; }
    if p == P_SGT && inst_iid(o0) == IID_smin {
        let a = op(o0, 0);
        let b = op(o0, 1);
        if icc_known_positive(a, cmp) { return ic_new_icmp(p, b, o1); }
        if icc_known_positive(b, cmp) { return ic_new_icmp(p, a, o1); }
    }
    let n = fold_irem_by_power_of_two_to_bit_test(cmp);
    if n >= 0 { return n; }
    if bo(o0, OP_UREM) && icmp_is_equality(p) {
        let x = op(o0, 0);
        let y = op(o0, 1);
        let xk = icc_kb(x, cmp);
        let yk = icc_kb(y, cmp);
        if kb_max_pop(xk) == 1 && kb_min_pop(yk) >= 2 { return ic_new_icmp(p, x, o1); }
    }
    if bo(o0, OP_MUL) && icmp_is_equality(p) {
        let x = op(o0, 0);
        let y = op(o0, 1);
        let xk = icc_kb(x, cmp);
        if kb_max_tz(xk) == 0 { return ic_new_icmp(p, y, o1); }
        let yk = icc_kb(y, cmp);
        if kb_max_tz(yk) == 0 { return ic_new_icmp(p, x, o1); }
        if op_nuw(o0) || op_nsw(o0) {
            if !ap_is_zero(xk.o) || icc_nonzero(x, cmp) { return ic_new_icmp(p, y, o1); }
            if !ap_is_zero(yk.o) || icc_nonzero(y, cmp) { return ic_new_icmp(p, x, o1); }
        }
    }
    if icmp_is_equality(p) {
        let s = strip_null_test(o0);
        if s >= 0 { return ic_new_icmp(p, s, c_null(vals[s].ty)); }
    }
    return -1;
}

// foldIsMultipleOfAPowerOfTwo(Cmp): icmp eq (num + mask) & ~mask, num
fn fold_is_multiple_of_a_power_of_two(cmp: i32) -> i32 {
    let p = icc_pred(cmp);
    for k in 2 {
        let num = op(cmp, k);
        let a = op(cmp, 1 - k);
        if !one_use(a) || !bo(a, OP_AND) { continue; }
        for j in 2 {
            let ad = op(a, j);
            let neg = op(a, 1 - j);
            if !one_use(ad) || !bo(ad, OP_ADD) { continue; }
            var mask: i32 = -1;
            if op(ad, 0) == num && m_low_bit_mask(op(ad, 1)) && has_apint_poison(op(ad, 1)) { mask = op(ad, 1); }
            else if op(ad, 1) == num && m_low_bit_mask(op(ad, 0)) && has_apint_poison(op(ad, 0)) { mask = op(ad, 0); }
            if mask < 0 || !has_apint(neg) { continue; }
            let mv = ap_cp(mask);
            if !ap_eq(ap_c(neg), ap_not(mv)) { return -1; }
            if !icmp_is_equality(p) { return -1; }
            let nand = icb_and(num, c_int_ap(vals[num].ty, mv), "");
            return ic_new_icmp(p, nand, c_null(vals[num].ty));
        }
    }
    return -1;
}

// foldICmpWithConstant(Cmp)
fn fold_icmp_with_constant(cmp: i32) -> i32 {
    let p = icc_pred(cmp);
    let o0 = op(cmp, 0);
    let o1 = op(cmp, 1);
    if p == P_UGT && m_constant_int(o1) >= 0 && bo(o0, OP_ADD) && bo(op(o0, 0), OP_ADD) && m_constant_int(op(o0, 1)) >= 0 {
        let r = process_ugt_addcst_add(cmp, op(op(o0, 0), 0), op(op(o0, 0), 1), op(o0, 1), o1);
        if r >= 0 { return r; }
    }
    if !is_constant(o1) { return -1; }
    if is_phi_inst(o0) {
        var all = true;
        for k in nops(o0) { if !is_constant(op(o0, k)) { all = false; } }
        if all {
            var resv: i32[>..<] = [];
            for k in nops(o0) {
                let r = cf_fold_cmp_operands(p, op(o0, k), o1, -1);
                if r < 0 { return -1; }
                resv.push(r);
            }
            icb_set_insert_point(o0);
            let n = nops(o0);
            let npn = new_inst(OP_PHI, vals[cmp].ty, n);
            vals[npn].nops = 0;
            icb_insert(npn, "");
            for k in n { phi_add_incoming(npn, resv[k], phi_block(o0, k)); }
            return ic_replace_inst_uses_with(cmp, npn);
        }
    }
    let r = try_fold_inst_with_ctpop_with_not(cmp);
    if r >= 0 { return r; }
    return -1;
}

// foldICmpWithDominatingICmp(Cmp)
fn fold_icmp_with_dominating_icmp(cmp: i32) -> i32 {
    let x = op(cmp, 0);
    let y = op(cmp, 1);
    if !has_apint(y) { return -1; }
    let c = ap_c(y);
    let p = icc_pred(cmp);
    let cr = rg_exact_icmp(p, c);
    var e = dc_first(x);
    while e >= 0 {
        let bi = dc_branch(e);
        e = dc_next(e);
        let cond = op(bi, 0);
        if !is_inst_op(cond, OP_ICMP) || op(cond, 0) != x || !has_apint(op(cond, 1)) { continue; }
        let dp = icc_pred(cond);
        let dc = ap_c(op(cond, 1));
        let bb = inst_parent(bi);
        if dom_edge(bb, term_succ(bi, 0), inst_parent(cmp)) {
            let v = icc_handle_dom_cond(cmp, x, p, c, cr, dp, dc);
            if v != -2 { return v; }
        } else if dom_edge(bb, term_succ(bi, 1), inst_parent(cmp)) {
            let v = icc_handle_dom_cond(cmp, x, p, c, cr, pred_inverse(dp), dc);
            if v != -2 { return v; }
        }
    }
    return -1;
}
// the handleDomCond lambda: -2 = nullptr (keep looking)
fn icc_handle_dom_cond(cmp: i32, x: i32, p: i64, c: AP, cr: CRange, dp: i64, dc: AP) -> i32 {
    let dcr = rg_exact_icmp(dp, dc);
    let inter = rg_intersect(dcr, cr);
    let diff = rg_difference(dcr, cr);
    if rg_is_empty(inter) { return ic_replace_inst_uses_with(cmp, c_false()); }
    if rg_is_empty(diff) { return ic_replace_inst_uses_with(cmp, c_true()); }
    let sb, unused = is_sign_bit_check(p, c);
    if icmp_is_equality(p) || (sb && has_branch_use(cmp)) { return -2; }
    if has_one_use(cmp) && m_max_or_min(icc_user_back(cmp)) { return -2; }
    if rg_is_single(inter) { return ic_new_icmp(P_EQ, x, c_int_ap(vals[x].ty, rg_single_elt(inter))); }
    if rg_is_single(diff) { return ic_new_icmp(P_NE, x, c_int_ap(vals[x].ty, rg_single_elt(diff))); }
    return -2;
}

// foldICmpTruncConstant(Cmp, Trunc, C)
fn fold_icmp_trunc_constant(cmp: i32, tr: i32, c: AP) -> i32 {
    let p = icc_pred(cmp);
    let x = op(tr, 0);
    let sty = vals[x].ty;
    let dbits = ty_sbits(tr);
    let sbits = ty_sbits(x);
    if should_change_type(vals[tr].ty, sty) {
        if icc_trunc_nsw(tr) { return ic_new_icmp(p, x, c_int_ap(sty, ap_sext(c, sbits))); }
        if !pred_is_signed(p) && icc_trunc_nuw(tr) { return ic_new_icmp(p, x, c_int_ap(sty, ap_zext(c, sbits))); }
    }
    if ap_is_one(c) && c.w > 1 {
        if p == P_SLT {
            let v = icc_m_signum(x);
            if v >= 0 { return ic_new_icmp(P_SLT, v, c_int_ty(vals[v].ty, 1)); }
        }
    }
    if icmp_is_equality(p) && bo(x, OP_SHL) && m_power2(op(x, 0)) && has_apint_poison(op(x, 0)) && dbits > ap_log2(ap_cp(op(x, 0))) {
        let pw = ap_cp(op(x, 0));
        let y = op(x, 1);
        if ap_is_zero(c) {
            return ic_new_icmp(if p == P_EQ { P_UGE } else { P_ULT }, y, c_int_ty(sty, (dbits - ap_log2(pw)) as u64));
        }
        if ap_is_pow2(c) { return ic_new_icmp(p, y, c_int_ty(sty, (ap_log2(c) - ap_log2(pw)) as u64)); }
    }
    if icmp_is_equality(p) && (has_one_use(tr) || icc_trunc_nuw(tr)) {
        if !ty_is_vector(sty) && should_change_type_w(dbits, sbits) {
            let mask = c_int_ap(sty, ap_low_bits(sbits, dbits));
            let a = if icc_trunc_nuw(tr) { x } else { icb_and(x, mask, "") };
            let wc = c_int_ap(sty, ap_zext(c, sbits));
            return ic_new_icmp(p, a, wc);
        }
        let k = icc_kb(x, cmp);
        if ap_countl_one(ap_or(k.z, k.o)) >= sbits - dbits {
            var nr = ap_zext(c, sbits);
            nr = ap_or(nr, ap_and(k.o, ap_high_bits(sbits, sbits - dbits)));
            return ic_new_icmp(p, x, c_int_ap(sty, nr));
        }
    }
    let sb, tis = is_sign_bit_check(p, c);
    if sb && icc_is_shr(x) && icc_m_cint_u64(op(x, 1)) {
        let sh = ap_zext64(ap_c(op(x, 1)));
        if (dbits as u64) + sh == (sbits as u64) && sh <= (sbits as u64) {
            if tis { return ic_new_icmp(P_SLT, op(x, 0), c_null(sty)); }
            return ic_new_icmp(P_SGT, op(x, 0), c_all_ones(sty));
        }
    }
    return -1;
}

// foldICmpTruncWithTruncOrExt(Cmp, Q)
fn fold_icmp_trunc_with_trunc_or_ext(cmp: i32) -> i32 {
    var p = icc_pred(cmp);
    let o0 = op(cmp, 0);
    let o1 = op(cmp, 1);
    var x: i32 = -1;
    var y: i32 = -1;
    var y_sext = false;
    if is_inst_op(o0, OP_TRUNC) && is_inst_op(o1, OP_TRUNC) {
        x = op(o0, 0);
        y = op(o1, 0);
        let f0 = insts[inst_of(o0)].flags & (FL_NUW | FL_NSW);
        let f1 = insts[inst_of(o1)].flags & (FL_NUW | FL_NSW);
        let nwf = f0 & f1;
        if pred_is_signed(p) {
            if (nwf & FL_NSW) == 0 { return -1; }
        } else {
            if nwf == 0 { return -1; }
        }
        if vals[x].ty != vals[y].ty && (!has_one_use(o0) || !has_one_use(o1)) { return -1; }
        if !is_desirable_int_type(ty_sbits(x)) && is_desirable_int_type(ty_sbits(y)) {
            let t = x; x = y; y = t;
            p = pred_swapped(p);
        }
        y_sext = (nwf & FL_NUW) == 0;
    } else {
        var found = false;
        if !pred_is_signed(p) {
            for k in 2 {
                let a = op(cmp, k);
                let b = op(cmp, 1 - k);
                if icc_trunc_nuw(a) && one_use(b) && is_inst_op(b, OP_ZEXT) {
                    x = op(a, 0); y = op(b, 0);
                    if k == 1 { p = pred_swapped(p); }
                    found = true;
                    break;
                }
            }
        }
        if !found {
            for k in 2 {
                let a = op(cmp, k);
                let b = op(cmp, 1 - k);
                if icc_trunc_nsw(a) && one_use(b) && (is_inst_op(b, OP_ZEXT) || is_inst_op(b, OP_SEXT)) {
                    x = op(a, 0); y = op(b, 0);
                    if k == 1 { p = pred_swapped(p); }
                    found = true;
                    break;
                }
            }
            if !found { return -1; }
            y_sext = is_inst_op(o0, OP_SEXT) || is_inst_op(o1, OP_SEXT);
        }
    }
    let tbits = ty_sbits(o0);
    if is_desirable_int_type(tbits) && !is_desirable_int_type(ty_sbits(x)) { return -1; }
    let ny = icb_int_cast(y, vals[x].ty, y_sext, "");
    return ic_new_icmp(p, x, ny);
}

// foldICmpXorConstant(Cmp, Xor, C)
fn fold_icmp_xor_constant(cmp: i32, xo: i32, c: AP) -> i32 {
    let r = fold_icmp_xor_shift_const(cmp, xo, c);
    if r >= 0 { return r; }
    let x = op(xo, 0);
    let y = op(xo, 1);
    if !has_apint(y) { return -1; }
    let xc = ap_c(y);
    var p = icc_pred(cmp);
    let sb, tis = is_sign_bit_check(p, c);
    if sb {
        if !ap_is_neg(xc) { return ic_replace_operand(cmp, 0, x); }
        if tis { return ic_new_icmp(P_SGT, x, c_all_ones(vals[x].ty)); }
        return ic_new_icmp(P_SLT, x, c_null(vals[x].ty));
    }
    if has_one_use(xo) {
        if !icmp_is_equality(p) && ap_is_sign_mask(xc) {
            p = pred_flipped_signedness(p);
            return ic_new_icmp(p, x, c_int_ap(vals[x].ty, ap_xor(c, xc)));
        }
        if !icmp_is_equality(p) && ap_is_max_signed(xc) {
            p = pred_swapped(pred_flipped_signedness(p));
            return ic_new_icmp(p, x, c_int_ap(vals[x].ty, ap_xor(c, xc)));
        }
    }
    if p == P_UGT {
        if ap_eq(xc, ap_not(c)) && ap_is_pow2(ap_inc(c)) { return ic_new_icmp(P_ULT, x, y); }
        if ap_eq(xc, c) && ap_is_pow2(ap_inc(c)) { return ic_new_icmp(P_UGT, x, y); }
    }
    if p == P_ULT {
        if ap_eq(xc, ap_neg(c)) && ap_is_pow2(c) { return ic_new_icmp(P_UGT, x, c_int_ap(vals[x].ty, ap_not(c))); }
        if ap_eq(xc, c) && ap_is_pow2(ap_neg(c)) { return ic_new_icmp(P_UGT, x, c_int_ap(vals[x].ty, ap_not(c))); }
    }
    return -1;
}

// foldICmpXorShiftConst(Cmp, Xor, C)
fn fold_icmp_xor_shift_const(cmp: i32, xo: i32, c: AP) -> i32 {
    let p = icc_pred(cmp);
    var pw = c;
    if p == P_ULT { pw = c; }
    else if p == P_UGT && !ap_is_all_ones(c) { pw = ap_inc(c); }
    else { return -1; }
    if !ap_is_pow2(pw) { return -1; }
    if !one_use(xo) || !bo(xo, OP_XOR) { return -1; }
    var x: i32 = -1;
    var shc: i32 = -1;
    for k in 2 {
        let a = op(xo, k);
        let s = op(xo, 1 - k);
        if bo(s, OP_ASHR) && op(s, 0) == a && has_apint(op(s, 1)) { x = a; shc = op(s, 1); break; }
    }
    if x < 0 { return -1; }
    let shift = ap_limited(ap_c(shc), 0xFFFFFFFFFFFFFFFF);
    let xty = vals[x].ty;
    if shift == 0 || ap_is_min_signed(pw) { return -1; }
    let add = icb_add(x, c_int_ap(xty, pw), "");
    let bound = if p == P_ULT { ap_shl(pw, 1) } else { ap_dec(ap_shl(pw, 1)) };
    return ic_new_icmp(p, add, c_int_ap(xty, bound));
}

// foldICmpAndShift(Cmp, And, C1, C2)
fn fold_icmp_and_shift(cmp: i32, an: i32, c1: AP, c2: AP) -> i32 {
    let sh = op(an, 0);
    if !is_binop_inst(sh) || !is_shift_op(iop(sh)) { return -1; }
    let so = iop(sh);
    let is_shl = so == OP_SHL;
    let p = icc_pred(cmp);
    if has_apint(op(sh, 1)) {
        let c3 = ap_c(op(sh, 1));
        var nand = c2;
        var ncmp = c1;
        var shifted_out = false;
        if so == OP_SHL {
            if pred_is_signed(p) && (ap_is_neg(c2) || ap_is_neg(c1)) { return -1; }
            ncmp = ap_lshr_ap(c1, c3);
            nand = ap_lshr_ap(c2, c3);
            shifted_out = !ap_eq(ap_shl_ap(ncmp, c3), c1);
        } else if so == OP_LSHR {
            ncmp = ap_shl_ap(c1, c3);
            nand = ap_shl_ap(c2, c3);
            shifted_out = !ap_eq(ap_lshr_ap(ncmp, c3), c1);
            if pred_is_signed(p) && (ap_is_neg(nand) || ap_is_neg(ncmp)) { return -1; }
        } else {
            ncmp = ap_shl_ap(c1, c3);
            nand = ap_shl_ap(c2, c3);
            shifted_out = !ap_eq(ap_ashr_ap(ncmp, c3), c1);
            if !ap_eq(ap_ashr_ap(nand, c3), c2) { return -1; }
        }
        if shifted_out {
            if p == P_EQ { return ic_replace_inst_uses_with(cmp, c_bool_ty(vals[cmp].ty, false)); }
            if p == P_NE { return ic_replace_inst_uses_with(cmp, c_bool_ty(vals[cmp].ty, true)); }
        } else {
            let na = icb_and(op(sh, 0), c_int_ap(vals[an].ty, nand), "");
            return ic_new_icmp(p, na, c_int_ap(vals[an].ty, ncmp));
        }
    }
    if has_one_use(sh) && ap_is_zero(c1) && icmp_is_equality(p) && so != OP_ASHR &&
       ((!is_shl && ap_is_one(c2)) || !is_constant(op(sh, 0))) {
        let ns = if is_shl { icb_lshr(op(an, 1), op(sh, 1), "", false) } else { icb_shl(op(an, 1), op(sh, 1), "") };
        let na = icb_and(op(sh, 0), ns, "");
        return ic_new_icmp(p, na, op(cmp, 1));
    }
    return -1;
}

// APFloat::getInf(Sem).bitcastToAPInt() for IEEE-like types; width 0 = not IEEE-like
fn icc_fp_exponent_mask(t: i32) -> AP {
    let k = ty_kind(t);
    if k == TK_HALF { return ap_u64(0x7C00, 16); }
    if k == TK_BFLOAT { return ap_u64(0x7F80, 16); }
    if k == TK_FLOAT { return ap_u64(0x7F800000, 32); }
    if k == TK_DOUBLE { return ap_u64(0x7FF0000000000000, 64); }
    if k == TK_FP128 { return ap_shl(ap_u64(0x7FFF, 128), 112); }
    return ap_zero(1);
}
fn icc_is_ieee_like(t: i32) -> bool {
    let k = ty_kind(t);
    return k == TK_HALF || k == TK_BFLOAT || k == TK_FLOAT || k == TK_DOUBLE || k == TK_FP128;
}
// IRBuilder::createIsFPClass(V, Test)
fn icb_is_fpclass(v: i32, test: u64) -> i32 {
    let t = c_int(T_I32, test as i64);
    let ty: i32 = vals[v].ty;
    return icb_intrinsic(IID_is_fpclass, [ty], [v, t], "");
}

// foldICmpAndConstConst(Cmp, And, C1)
fn fold_icmp_and_const_const(cmp: i32, an: i32, c1: AP) -> i32 {
    let p = icc_pred(cmp);
    let is_ne = p == P_NE;
    if is_ne && ap_is_zero(c1) && m_one(op(an, 1)) { return ic_new_cast(OP_TRUNC, op(an, 0), vals[cmp].ty); }
    if !bo(an, OP_AND) || !has_apint(op(an, 1)) { return -1; }
    let x = op(an, 0);
    let c2 = ap_c(op(an, 1));
    let xty = vals[x].ty;
    if p == P_SGT && ap_ule(c1, ap_not(c2)) && ap_is_neg_pow2(c2) { return ic_new_icmp(P_SGT, x, c_int_ap(xty, ap_not(c2))); }
    if p == P_SLT && !ap_is_sign_mask(c1) && ap_ule(ap_dec(c1), ap_not(c2)) && ap_is_neg_pow2(c2) && !ap_is_sign_mask(c2) {
        return ic_new_icmp(P_SLT, x, c_int_ap(xty, ap_neg(c2)));
    }
    if !has_one_use(an) { return -1; }
    if icmp_is_equality(p) && ap_is_zero(c1) {
        if ap_is_sign_mask(c2) { return ic_new_icmp(if is_ne { P_SLT } else { P_SGE }, x, c_null(xty)); }
        let k = icc_kb(op(an, 0), an);
        let nc2 = ap_or(c2, ap_high_bits(c2.w as i64, kb_min_lz(k)));
        if ap_is_neg_pow2(nc2) {
            return ic_new_icmp(if is_ne { P_UGE } else { P_ULT }, x, c_int_ap(vals[an].ty, ap_neg(nc2)));
        }
    }
    let t = op(an, 0);
    if one_use(t) && is_inst_op(t, OP_TRUNC) && (icmp_is_equality(p) || (!ap_is_neg(c1) && !ap_is_neg(c2))) {
        if !ty_is_vector(vals[cmp].ty) {
            let w = op(t, 0);
            let wty = vals[w].ty;
            let wb = ty_scalar_bits(wty);
            let zc1 = c_int_ap(wty, ap_zext(c1, wb));
            let zc2 = c_int_ap(wty, ap_zext(c2, wb));
            var nm: u8[>..] = [];
            nm.append(val_name(an));
            let na = icb_and(w, zc2, nm);
            return ic_new_icmp(p, na, zc1);
        }
    }
    let r = fold_icmp_and_shift(cmp, an, c1, c2);
    if r >= 0 { return r; }
    if !pred_is_signed(p) && ap_is_zero(c1) && has_one_use(op(an, 0)) && m_one(op(an, 1)) {
        let one = op(an, 1);
        let orv = op(an, 0);
        if bo(orv, OP_OR) {
            let lshr = op(orv, 0);
            let a = op(orv, 1);
            if bo(lshr, OP_LSHR) && op(lshr, 0) == a {
                let b = op(lshr, 1);
                var removed = 0;
                if has_one_use(an) { removed++; }
                if has_one_use(orv) { removed++; }
                if has_one_use(lshr) { removed++; }
                let req = if m_imm_constant(b) { 1 } else { 3 };
                if removed >= req {
                    var n1: u8[>..] = [];
                    n1.append(val_name(lshr));
                    let shl = icb_shl_nw(one, b, n1, true, false);
                    var n2: u8[>..] = [];
                    n2.append(val_name(orv));
                    let nor = icb_or(shl, one, n2);
                    var n3: u8[>..] = [];
                    n3.append(val_name(an));
                    let na = icb_and(a, nor, n3);
                    return ic_new_icmp(p, na, op(cmp, 1));
                }
            }
        }
    }
    if !func_has_fn_attr(inst_func(cmp), AK_NoImplicitFloat) && icmp_is_equality(p) && one_use(x) &&
       is_inst_op(x, OP_BITCAST) && ic_elementwise_bitcast(x) {
        let v = op(x, 0);
        let fty = ty_scalar(vals[v].ty);
        if icc_is_ieee_like(fty) && (ap_is_zero(c1) || ap_eq(c1, c2)) {
            let em = icc_fp_exponent_mask(fty);
            if em.w == c2.w && ap_eq(c2, em) {
                var mask = if ap_is_zero(c1) { FCL_ZERO | FCL_SUBNORMAL } else { FCL_NAN | FCL_INF };
                if is_ne { mask = ~mask & 1023; }
                return ic_replace_inst_uses_with(cmp, icb_is_fpclass(v, mask));
            }
        }
    }
    return -1;
}

// foldICmpAndConstant(Cmp, And, C)
fn fold_icmp_and_constant(cmp: i32, an: i32, c: AP) -> i32 {
    let r = fold_icmp_and_const_const(cmp, an, c);
    if r >= 0 { return r; }
    let p = icc_pred(cmp);
    let sb, tin = is_sign_bit_check(p, c);
    if sb {
        let a0 = op(an, 0);
        if bo(a0, OP_ADD) && m_all_ones(op(a0, 1)) && m_not(op(an, 1)) == op(a0, 0) && op(a0, 0) >= 0 {
            let x = op(a0, 0);
            return ic_new_icmp(if tin { P_EQ } else { P_NE }, x, c_null(vals[x].ty));
        }
        for k in 2 {
            let x = m_neg(op(an, k));
            if x >= 0 && op(an, 1 - k) == x {
                let msc = c_int_ap(vals[x].ty, ap_smin_val(ty_sbits(x)));
                return ic_new_icmp(if tin { P_EQ } else { P_NE }, x, msc);
            }
        }
    }
    let x = op(an, 0);
    let y = op(an, 1);
    if vals[y].kind == VK_CINT && is_inst_op(x, OP_LOAD) && is_inst_op(op(x, 0), OP_GEP) {
        let res = fold_cmp_load_from_indexed_global(x, op(x, 0), cmp, y);
        if res >= 0 { return res; }
    }
    if !icmp_is_equality(p) { return -1; }
    if op(cmp, 1) == y && ap_is_neg_pow2(c) {
        return ic_new_icmp(if p == P_EQ { P_UGT } else { P_ULE }, x, sub_one(op(cmp, 1)));
    }
    if one_use(an) && (ap_is_zero(c) || ap_is_one(c)) {
        for k in 2 {
            let z = op(an, k);
            if one_use(z) && is_inst_op(z, OP_ZEXT) && is_int_ty1(vals[op(z, 0)].ty) {
                let xx = op(z, 0);
                let yy = op(an, 1 - k);
                let ty_ = icb_trunc(yy, vals[xx].ty, "");
                if ap_is_zero(c) != (p == P_NE) {
                    let a2 = icb_and(ty_, xx, "");
                    return ic_new_not(a2);
                }
                return ic_new_binop(OP_AND, ty_, xx);
            }
        }
    }
    if ap_is_zero(c) && one_use(an) {
        for k in 2 {
            let s = op(an, k);
            if one_use(s) && bo(s, OP_SHL) && m_all_ones(op(s, 0)) {
                let ls = icb_lshr(op(an, 1 - k), op(s, 1), "", false);
                return ic_new_icmp(p, ls, c_null(vals[ls].ty));
            }
        }
    }
    if one_use(an) {
        let ad = op(an, 0);
        let mk = op(an, 1);
        if one_use(ad) && bo(ad, OP_ADD) && has_apint(op(ad, 1)) && m_low_bit_mask(mk) && has_apint_poison(mk) {
            let msk = ap_cp(mk);
            if ap_ule(c, msk) {
                let a = op(ad, 0);
                let ncmp = ap_and(ap_sub(c, ap_c(op(ad, 1))), msk);
                let ma = icb_and(a, c_int_ap(vals[a].ty, msk), "");
                return ic_new_icmp(p, ma, c_int_ap(vals[ma].ty, ncmp));
            }
        }
    }
    return -1;
}

// foldICmpOrXorSubChain(Cmp, Or, Builder)
fn fold_icmp_or_xor_sub_chain(cmp: i32, orv: i32) -> i32 {
    var cl: i32[>..<] = [];
    var cr: i32[>..<] = [];
    var wl: i32[>..<] = [];
    wl.push(orv);
    while wl.len > 0 {
        let cur = wl.pop();
        if !bo(cur, OP_OR) { return -1; }
        for k in 2 {
            let a = op(cur, 1 - k);
            if one_use(a) && (bo(a, OP_XOR) || bo(a, OP_SUB)) { cl.push(op(a, 0)); cr.push(op(a, 1)); }
            else { wl.push(a); }
        }
    }
    let p = icc_pred(cmp);
    let bopc = if p == P_EQ { OP_AND } else { OP_OR };
    var n = cl.len;
    var lhs = icb_icmp(p, cl[n - 1], cr[n - 1], "");
    var k = n - 1;
    while k > 0 {
        k--;
        let rhs = icb_icmp(p, cl[k], cr[k], "");
        lhs = icb_binop(bopc, lhs, rhs, "");
    }
    return lhs;
}

// foldICmpOrConstant(Cmp, Or, C)
fn fold_icmp_or_constant(cmp: i32, orv: i32, c: AP) -> i32 {
    var p = icc_pred(cmp);
    if ap_is_one(c) && p == P_SLT {
        let v = icc_m_signum(orv);
        if v >= 0 { return ic_new_icmp(P_SLT, v, c_int_ty(vals[v].ty, 1)); }
    }
    let o0 = op(orv, 0);
    let o1 = op(orv, 1);
    if icmp_is_equality(p) && m_imm_constant(o1) && op_disjoint(orv) {
        let nc = icb_xor(o1, c_int_ap(vals[o1].ty, c), "");
        return ic_new_icmp(p, o0, nc);
    }
    if has_apint(o1) && icmp_is_equality(p) {
        let mc = ap_c(o1);
        if ap_eq(mc, c) && ap_is_pow2(ap_inc(c)) {
            return ic_new_icmp(if p == P_EQ { P_ULE } else { P_UGT }, o0, o1);
        }
        if has_one_use(orv) {
            let a = icb_and(o0, c_int_ap(vals[o0].ty, ap_not(mc)), "");
            return ic_new_icmp(p, a, c_int_ap(vals[orv].ty, ap_xor(c, mc)));
        }
    }
    let sb, tis = is_sign_bit_check(p, c);
    if sb {
        for k in 2 {
            let a = op(orv, k);
            if bo(a, OP_ADD) && m_all_ones(op(a, 1)) && op(orv, 1 - k) == op(a, 0) {
                let x = op(a, 0);
                return ic_new_icmp(if tis { P_SLT } else { P_SGT }, x, c_int_ty(vals[x].ty, if tis { 1 } else { 0 }));
            }
        }
    }
    if ap_is_nonneg(c) && has_apint(o1) {
        let orc = ap_c(o1);
        let x = o0;
        if p == P_SLT || p == P_SGE {
            if ap_sge(orc, c) { return ic_new_icmp(p, x, c_null(vals[x].ty)); }
        } else if p == P_SLE || p == P_SGT {
            if ap_sgt(orc, c) { return ic_new_icmp(if p == P_SLE { P_SLT } else { P_SGE }, x, c_null(vals[x].ty)); }
        }
    }
    if !icmp_is_equality(p) || !ap_is_zero(c) || !has_one_use(orv) { return -1; }
    if is_op(o0, OP_PTRTOINT) && is_op(o1, OP_PTRTOINT) {
        let pp = op(o0, 0);
        let qq = op(o1, 0);
        let cp_ = icb_icmp(p, pp, c_null(vals[pp].ty), "");
        let cq = icb_icmp(p, qq, c_null(vals[qq].ty), "");
        return ic_new_binop(if p == P_EQ { OP_AND } else { OP_OR }, cp_, cq);
    }
    let v = fold_icmp_or_xor_sub_chain(cmp, orv);
    if v >= 0 { return ic_replace_inst_uses_with(cmp, v); }
    return -1;
}

// APInt::sqrtFloor (exact floor of the unsigned square root)
fn icc_sqrt_floor(c: AP) -> AP {
    let w = c.w as i64;
    let ww = 2 * w;
    let cw = ap_zext(c, ww);
    var r = ap_zero(ww);
    var b = (ap_active_bits(c) + 1) / 2;
    while b > 0 {
        b--;
        let t = ap_set_bit(r, b);
        if ap_ule(ap_mul(t, t), cw) { r = t; }
    }
    return ap_trunc(r, w);
}

// getFlippedStrictnessPredicateAndConstant(Pred, C) (ValueTracking.cpp): ok, new predicate, new constant
fn icc_flipped_strictness(p0: i64, c0: i32) -> bool, i64, i32 {
    let p = cp_pred(p0);
    if is_undef_or_poison(c0) { return false, 0, -1; }
    var c = c0;
    let ty = vals[c].ty;
    let signed = pred_is_signed(p);
    let up = pred_unsigned(p);
    let inc = up == P_ULE || up == P_UGT;
    var safe: i32 = -1;
    if vals[c].kind == VK_CINT && !ty_is_vector(ty) {
        if !icc_const_ok(c, inc, signed) { return false, 0, -1; }
    } else if ty_kind(ty) == TK_FVEC {
        for k in ty_count(ty) {
            let e = agg_elem(c, k);
            if e < 0 { return false, 0, -1; }
            if is_undef_or_poison(e) { continue; }
            if vals[e].kind != VK_CINT || !icc_const_ok(e, inc, signed) { return false, 0, -1; }
            if safe < 0 { safe = e; }
        }
    } else if ty_is_vector(ty) {
        let s = splat_value(c, false);
        if s < 0 || vals[s].kind != VK_CINT || !icc_const_ok(s, inc, signed) { return false, 0, -1; }
    } else { return false, 0, -1; }
    if contains_undef_or_poison_element(c) { c = replace_undefs_with(c, safe); }
    let np = if pred_strict(p) == p { pred_nonstrict(p) } else { pred_strict(p) };
    let one = if inc { c_int_ty(ty, 1) } else { c_all_ones(ty) };
    let nc = ce_binop(OP_ADD, c, one, 0);
    return true, np, nc;
}
fn icc_const_ok(c: i32, inc: bool, signed: bool) -> bool {
    let a = ci_ap(c);
    if inc { return if signed { !ap_is_max_signed(a) } else { !ap_is_all_ones(a) }; }
    return if signed { !ap_is_min_signed(a) } else { !ap_is_zero(a) };
}

// foldICmpMulConstant(Cmp, Mul, C)
fn fold_icmp_mul_constant(cmp: i32, mul: i32, c: AP) -> i32 {
    var p = icc_pred(cmp);
    let mty = vals[mul].ty;
    let x = op(mul, 0);
    if x == op(mul, 1) && !pred_is_signed(p) {
        var r = icc_sqrt_floor(c);
        let is_sqr = ap_eq(c, ap_mul(r, r));
        if icmp_is_equality(p) && (op_nuw(mul) || (op_nsw(mul) && ap_is_zero(c))) {
            if !is_sqr { return ic_replace_inst_uses_with(cmp, c_bool_ty(vals[cmp].ty, p == P_NE)); }
            return ic_new_icmp(p, x, c_int_ap(mty, r));
        }
        if op_nuw(mul) {
            if is_sqr { return ic_new_icmp(p, x, c_int_ap(mty, r)); }
            if icmp_is_lt(p) { r = ap_inc(r); }
            return ic_new_icmp(pred_strict(p), x, c_int_ap(mty, r));
        }
    }
    if !has_apint(op(mul, 1)) { return -1; }
    let mc = ap_c(op(mul, 1));
    // isSignTest updates Pred (also when the multiply has no nsw)
    let st, sp = is_sign_test(p, c);
    if st { p = sp; }
    if st && op_nsw(mul) {
        if ap_is_neg(mc) { p = pred_swapped(p); }
        return ic_new_icmp(p, x, c_null(mty));
    }
    if ap_is_zero(mc) { return -1; }
    if icmp_is_equality(p) {
        if op_nsw(mul) && ap_is_zero(ap_srem(c, mc)) { return ic_new_icmp(p, x, c_int_ap(mty, ap_sdiv(c, mc))); }
        if ap_is_zero(ap_urem(c, mc)) {
            if ap_get_bit(mc, 0) || op_nuw(mul) { return ic_new_icmp(p, x, c_int_ap(mty, ap_udiv(c, mc))); }
        }
    }
    var nc: i32 = -1;
    if op_nsw(mul) && pred_is_signed(p) {
        if ap_is_min_signed(c) && ap_is_all_ones(mc) { return -1; }
        if ap_is_neg(mc) { p = pred_swapped(p); }
        if p == P_SLT || p == P_SGE { nc = c_int_ap(mty, ap_rounding_sdiv(c, mc, true)); }
        else { nc = c_int_ap(mty, ap_rounding_sdiv(c, mc, false)); }
    } else if op_nuw(mul) && pred_is_unsigned(p) {
        if p == P_ULT || p == P_UGE { nc = c_int_ap(mty, ap_rounding_udiv(c, mc, true)); }
        else { nc = c_int_ap(mty, ap_rounding_udiv(c, mc, false)); }
    }
    if nc >= 0 { return ic_new_icmp(p, x, nc); }
    return -1;
}

// foldICmpShlLHSC(Cmp, Shl, C): icmp (shl nuw C2, Y), C
fn fold_icmp_shl_lhsc(cmp: i32, shl: i32, c: AP) -> i32 {
    if !bo(shl, OP_SHL) || !op_nuw(shl) || !has_apint(op(shl, 0)) { return -1; }
    let c2 = ap_c(op(shl, 0));
    let y = op(shl, 1);
    let sty = vals[shl].ty;
    let tb = c.w as i64;
    var p = icc_pred(cmp);
    if pred_is_unsigned(p) {
        if ap_is_zero(c2) || ap_ugt(c2, c) { return -1; }
        let dv, rm = ap_udivrem(c, c2);
        let pow2 = ap_is_zero(rm) && ap_is_pow2(dv);
        if !pow2 {
            if p == P_ULT { p = P_ULE; } else if p == P_UGE { p = P_UGT; }
        }
        return ic_new_icmp(p, y, c_int_ty(sty, ap_log2(dv) as u64));
    } else if pred_is_signed(p) && ap_is_one(c2) {
        let bwm1 = c_int_ty(sty, (tb - 1) as u64);
        if p == P_SGT && ap_sle(c, ap_zero(tb)) { return ic_new_icmp(P_NE, y, bwm1); }
        if p == P_SLT && ap_sle(ap_dec(c), ap_zero(tb)) { return ic_new_icmp(P_EQ, y, bwm1); }
    }
    return -1;
}

// foldICmpShlConstant(Cmp, Shl, C)
fn fold_icmp_shl_constant(cmp: i32, shl: i32, c: AP) -> i32 {
    let p = icc_pred(cmp);
    if icmp_is_equality(p) && has_apint(op(shl, 0)) { return fold_icmp_shl_const_const(cmp, op(shl, 1), c, ap_c(op(shl, 0))); }
    let tb = c.w as i64;
    if ap_sle(c, ap_zero(tb)) && op_nuw(shl) && op_nsw(shl) { return ic_new_icmp(p, op(shl, 0), op(cmp, 1)); }
    if icmp_is_equality(p) && ap_is_zero(c) && (op_nuw(shl) || op_nsw(shl)) { return ic_new_icmp(p, op(shl, 0), op(cmp, 1)); }
    if op_nsw(shl) && (p == P_SGT || p == P_SLT) {
        if ap_is_zero(c) || (if p == P_SGT { ap_is_all_ones(c) } else { ap_is_one(c) }) { return ic_new_icmp(p, op(shl, 0), op(cmp, 1)); }
    }
    if !has_apint(op(shl, 1)) { return fold_icmp_shl_lhsc(cmp, shl, c); }
    let sa = ap_c(op(shl, 1));
    if ap_uge_u64(sa, tb as u64) { return -1; }
    let s = ap_zext64(sa) as i64;
    let x = op(shl, 0);
    let sty = vals[shl].ty;
    if op_nsw(shl) {
        if p == P_SGT { return ic_new_icmp(p, x, c_int_ap(sty, ap_ashr(c, s))); }
        if (p == P_EQ || p == P_NE) && ap_eq(ap_shl(ap_ashr(c, s), s), c) { return ic_new_icmp(p, x, c_int_ap(sty, ap_ashr(c, s))); }
        if p == P_SLT { return ic_new_icmp(p, x, c_int_ap(sty, ap_inc(ap_ashr(ap_dec(c), s)))); }
    }
    if op_nuw(shl) {
        if p == P_UGT { return ic_new_icmp(p, x, c_int_ap(sty, ap_lshr(c, s))); }
        if (p == P_EQ || p == P_NE) && ap_eq(ap_shl(ap_lshr(c, s), s), c) { return ic_new_icmp(p, x, c_int_ap(sty, ap_lshr(c, s))); }
        if p == P_ULT { return ic_new_icmp(p, x, c_int_ap(sty, ap_inc(ap_lshr(ap_dec(c), s)))); }
    }
    if icmp_is_equality(p) && has_one_use(shl) {
        let mask = c_int_ap(sty, ap_low_bits(tb, tb - s));
        var nm: u8[>..] = [];
        nm.append(val_name(shl)); nm.append(".mask");
        let a = icb_and(x, mask, nm);
        return ic_new_icmp(p, a, c_int_ap(sty, ap_lshr(c, s)));
    }
    let sb, tis = is_sign_bit_check(p, c);
    if has_one_use(shl) && sb {
        let mask = c_int_ap(sty, ap_one_bit(tb, tb - s - 1));
        var nm: u8[>..] = [];
        nm.append(val_name(shl)); nm.append(".mask");
        let a = icb_and(x, mask, nm);
        return ic_new_icmp(if tis { P_NE } else { P_EQ }, a, c_null(sty));
    }
    if pred_is_unsigned(p) && has_one_use(shl) {
        if ap_is_pow2(ap_inc(c)) && (p == P_ULE || p == P_UGT) {
            let a = icb_and(x, c_int_ap(sty, ap_lshr(ap_not(c), s)), "");
            return ic_new_icmp(if p == P_ULE { P_EQ } else { P_NE }, a, c_null(sty));
        }
        if ap_is_pow2(c) && (p == P_ULT || p == P_UGE) {
            let a = icb_and(x, c_int_ap(sty, ap_lshr(ap_not(ap_dec(c)), s)), "");
            return ic_new_icmp(if p == P_ULT { P_EQ } else { P_NE }, a, c_null(sty));
        }
    }
    let amt = ap_limited(sa, (tb - 1) as u64) as i64;
    if has_one_use(shl) && amt != 0 && should_change_type_w(ty_sbits(shl), tb - amt) {
        var cp_ = p;
        var rhsc = c;
        if ap_countr_zero(rhsc) < amt && pred_strict(cp_) == cp_ && pred_relational(cp_) {
            let ok, np, nc = icc_flipped_strictness(p, c_int_ap(ty_scalar(sty), c));
            if ok { cp_ = np; rhsc = ci_ap(nc); }
        }
        if ap_countr_zero(rhsc) >= amt {
            let tty = icc_ty_with_bits(sty, tb - amt);
            let nc = c_int_ap(tty, ap_trunc(ap_ashr(rhsc, s), tb - amt));
            return ic_new_icmp(cp_, icb_trunc_nw(x, tty, "", false, op_nsw(shl)), nc);
        }
    }
    return -1;
}

// Type::getWithNewBitWidth
fn icc_ty_with_bits(t: i32, w: i64) -> i32 { ty_with_elem(t, ty_int(w)) }

// foldICmpShrConstant(Cmp, Shr, C)
fn fold_icmp_shr_constant(cmp: i32, shr: i32, c: AP) -> i32 {
    let x = op(shr, 0);
    let p = icc_pred(cmp);
    if icmp_is_equality(p) && op_exact(shr) && ap_is_zero(c) { return ic_new_icmp(p, x, op(cmp, 1)); }
    let is_ashr = iop(shr) == OP_ASHR;
    if has_apint(x) {
        let svc = ap_c(x);
        if icmp_is_equality(p) { return fold_icmp_shr_const_const(cmp, op(shr, 1), c, svc); }
        let sb, tis = is_sign_bit_check(p, c);
        if !is_ashr && ap_is_neg(svc) && sb {
            return ic_new_icmp(if tis { P_EQ } else { P_NE }, op(shr, 1), c_null(vals[x].ty));
        }
        if !is_ashr && ap_is_pow2(svc) && (p == P_UGT || p == P_ULT) {
            let ugt = p == P_UGT;
            let clz = if ugt { ap_countl_zero(c) } else { ap_countl_zero(ap_dec(c)) };
            let slz = ap_countl_zero(svc);
            return ic_new_icmp(if ugt { P_ULT } else { P_UGE }, op(shr, 1), c_int_ty(vals[shr].ty, (clz - slz) as u64));
        }
    }
    if !has_apint(op(shr, 1)) { return -1; }
    let tb = c.w as i64;
    let sa = ap_limited(ap_c(op(shr, 1)), tb as u64) as i64;
    if sa >= tb || sa == 0 { return -1; }
    let exact = op_exact(shr);
    let sty = vals[shr].ty;
    if is_ashr && has_one_use(shr) {
        if exact && (p == P_SLT || p == P_ULT) && ap_is_pow2(ap_dec(c)) && ap_countl_zero(c) > sa {
            return ic_new_icmp(p, x, c_int_ap(sty, ap_inc(ap_shl(ap_dec(c), sa))));
        }
        if exact || p == P_SLT || p == P_ULT {
            let sc = ap_shl(c, sa);
            if ap_eq(ap_ashr(sc, sa), c) { return ic_new_icmp(p, x, c_int_ap(sty, sc)); }
        }
        if p == P_SGT {
            let c1 = ap_inc(c);
            let sc = ap_dec(ap_shl(c1, sa));
            if !ap_is_max_signed(c) && !ap_is_min_signed(ap_shl(c1, sa)) && ap_eq(ap_ashr(ap_inc(sc), sa), c1) {
                return ic_new_icmp(p, x, c_int_ap(sty, sc));
            }
        }
        if p == P_UGT {
            let c1 = ap_inc(c);
            let sc = ap_dec(ap_shl(c1, sa));
            if ap_eq(ap_ashr(ap_inc(sc), sa), c1) || ap_is_min_signed(ap_shl(c1, sa)) { return ic_new_icmp(p, x, c_int_ap(sty, sc)); }
        }
        if tb > 2 && ap_num_sign_bits(c) <= sa {
            if p == P_UGT { return ic_new_icmp(P_SLT, x, c_null(sty)); }
            if p == P_ULT { return ic_new_icmp(P_SGT, x, c_all_ones(sty)); }
        }
    } else if !is_ashr {
        if p == P_ULT || (p == P_UGT && exact) {
            let sc = ap_shl(c, sa);
            if ap_eq(ap_lshr(sc, sa), c) { return ic_new_icmp(p, x, c_int_ap(sty, sc)); }
        }
        if p == P_UGT {
            let c1 = ap_inc(c);
            let sc = ap_dec(ap_shl(c1, sa));
            if ap_eq(ap_lshr(ap_inc(sc), sa), c1) { return ic_new_icmp(p, x, c_int_ap(sty, sc)); }
        }
    }
    if !icmp_is_equality(p) { return -1; }
    if op_exact(shr) { return ic_new_icmp(p, x, c_int_ap(sty, ap_shl(c, sa))); }
    if has_one_use(shr) {
        let mask = c_int_ap(sty, ap_high_bits(tb, tb - sa));
        var nm: u8[>..] = [];
        nm.append(val_name(shr)); nm.append(".mask");
        let a = icb_and(x, mask, nm);
        return ic_new_icmp(p, a, c_int_ap(sty, ap_shl(c, sa)));
    }
    return -1;
}

// foldICmpSRemConstant(Cmp, SRem, C)
fn fold_icmp_srem_constant(cmp: i32, srem: i32, c: AP) -> i32 {
    let p = icc_pred(cmp);
    let ty = vals[srem].ty;
    if p == P_UGT || p == P_ULT {
        if !has_apint(op(srem, 1)) { return -1; }
        let dc = ap_c(op(srem, 1));
        if ap_is_zero(dc) { return -1; }
        var nc = c;
        if p == P_ULT { nc = ap_dec(nc); }
        if ap_is_neg(c) { nc = ap_not(nc); }
        if !ap_uge(nc, ap_dec(ap_abs(dc))) { return -1; }
        if p == P_UGT { return ic_new_icmp(P_SLT, srem, c_null(ty)); }
        return ic_new_icmp(P_SGT, srem, c_all_ones(ty));
    }
    if p != P_SGT && p != P_SLT && p != P_EQ && p != P_NE { return -1; }
    if !has_one_use(srem) { return -1; }
    if !has_apint_poison(op(srem, 1)) || !m_power2(op(srem, 1)) { return -1; }
    let dc = ap_cp(op(srem, 1));
    if ((p == P_SGT || p == P_SLT) && !ap_is_zero(c)) || ((p == P_EQ || p == P_NE) && !ap_is_strictly_pos(c)) { return -1; }
    let sm = ap_sign_mask(ty_scalar_bits(ty));
    let mc = c_int_ap(ty, ap_or(sm, ap_dec(dc)));
    let a = icb_and(op(srem, 0), mc, "");
    if p == P_EQ || p == P_NE { return ic_new_icmp(p, a, c_int_ap(ty, c)); }
    if p == P_SGT { return ic_new_icmp(P_SGT, a, c_null(ty)); }
    return ic_new_icmp(P_UGT, a, c_int_ap(ty, sm));
}

// foldICmpUDivConstant(Cmp, UDiv, C)
fn fold_icmp_udiv_constant(cmp: i32, ud: i32, c: AP) -> i32 {
    let p = icc_pred(cmp);
    let x = op(ud, 0);
    let y = op(ud, 1);
    let ty = vals[ud].ty;
    if !has_apint(x) { return -1; }
    let c2 = ap_c(x);
    if p == P_UGT { return ic_new_icmp(P_ULE, y, c_int_ap(ty, ap_udiv(c2, ap_inc(c)))); }
    if p == P_ULT { return ic_new_icmp(P_UGT, y, c_int_ap(ty, ap_udiv(c2, c))); }
    return -1;
}

// foldICmpDivConstant(Cmp, Div, C)
fn fold_icmp_div_constant(cmp: i32, dv: i32, c: AP) -> i32 {
    var p = icc_pred(cmp);
    let x = op(dv, 0);
    let y = op(dv, 1);
    let ty = vals[dv].ty;
    var signed = iop(dv) == OP_SDIV;
    if icmp_is_equality(p) && has_one_use(dv) && ap_is_neg(c) && (!signed || ap_is_min_signed(c)) {
        let xb = icb_icmp(p, x, c_int_ap(ty, c), "");
        let yo = icb_icmp(p, y, c_int_ty(ty, 1), "");
        return ic_new_binop(if p == P_EQ { OP_AND } else { OP_OR }, xb, yo);
    }
    if !has_apint(y) { return -1; }
    let c2 = ap_c(y);
    if !icmp_is_equality(p) && signed != pred_is_signed(p) {
        if !signed || !ap_is_strictly_pos(c2) || !icc_known_nonneg(x, cmp) { return -1; }
        signed = false;
    }
    if ap_is_zero(c2) || ap_is_one(c2) || (signed && ap_is_all_ones(c2)) { return -1; }
    let w = c.w as i64;
    let prod = ap_mul(c, c2);
    let prod_ov = !ap_eq(if signed { ap_sdiv(prod, c2) } else { ap_udiv(prod, c2) }, c);
    var rs = if op_exact(dv) { ap_u64(1, w) } else { c2 };
    var lo_ov: i64 = 0;
    var hi_ov: i64 = 0;
    var lo = ap_zero(w);
    var hi = ap_zero(w);
    if !signed {
        lo = prod;
        hi_ov = icc_bool(prod_ov); lo_ov = hi_ov;
        if hi_ov == 0 { let r, ov = ap_uadd_ov(lo, rs); hi = r; hi_ov = icc_bool(ov); }
    } else if ap_is_strictly_pos(c2) {
        if ap_is_zero(c) {
            lo = ap_neg(ap_dec(rs));
            hi = rs;
        } else if ap_is_strictly_pos(c) {
            lo = prod;
            hi_ov = icc_bool(prod_ov); lo_ov = hi_ov;
            if hi_ov == 0 { let r, ov = ap_sadd_ov(prod, rs); hi = r; hi_ov = icc_bool(ov); }
        } else {
            hi = ap_inc(prod);
            lo_ov = if prod_ov { -1 } else { 0 }; hi_ov = lo_ov;
            if lo_ov == 0 {
                let dn = ap_neg(rs);
                let r, ov = ap_sadd_ov(hi, dn);
                lo = r;
                lo_ov = if ov { -1 } else { 0 };
            }
        }
    } else if ap_is_neg(c2) {
        if op_exact(dv) { rs = ap_neg(rs); }
        if ap_is_zero(c) {
            lo = ap_inc(rs);
            hi = ap_neg(rs);
            if ap_eq(hi, c2) { hi_ov = 1; hi = ap_zero(1); }
        } else if ap_is_strictly_pos(c) {
            hi = ap_inc(prod);
            lo_ov = if prod_ov { -1 } else { 0 }; hi_ov = lo_ov;
            if lo_ov == 0 { let r, ov = ap_sadd_ov(hi, rs); lo = r; lo_ov = if ov { -1 } else { 0 }; }
        } else {
            lo = prod;
            hi_ov = icc_bool(prod_ov); lo_ov = hi_ov;
            if hi_ov == 0 { let r, ov = ap_ssub_ov(prod, rs); hi = r; hi_ov = icc_bool(ov); }
        }
        p = pred_swapped(p);
    }
    if p == P_EQ {
        if lo_ov != 0 && hi_ov != 0 { return ic_replace_inst_uses_with(cmp, c_false()); }
        if hi_ov != 0 { return ic_new_icmp(if signed { P_SGE } else { P_UGE }, x, c_int_ap(ty, lo)); }
        if lo_ov != 0 { return ic_new_icmp(if signed { P_SLT } else { P_ULT }, x, c_int_ap(ty, hi)); }
        return ic_replace_inst_uses_with(cmp, insert_range_test(x, lo, hi, signed, true));
    }
    if p == P_NE {
        if lo_ov != 0 && hi_ov != 0 { return ic_replace_inst_uses_with(cmp, c_true()); }
        if hi_ov != 0 { return ic_new_icmp(if signed { P_SLT } else { P_ULT }, x, c_int_ap(ty, lo)); }
        if lo_ov != 0 { return ic_new_icmp(if signed { P_SGE } else { P_UGE }, x, c_int_ap(ty, hi)); }
        return ic_replace_inst_uses_with(cmp, insert_range_test(x, lo, hi, signed, false));
    }
    if p == P_ULT || p == P_SLT {
        if lo_ov == 1 { return ic_replace_inst_uses_with(cmp, c_true()); }
        if lo_ov == -1 { return ic_replace_inst_uses_with(cmp, c_false()); }
        return ic_new_icmp(p, x, c_int_ap(ty, lo));
    }
    if hi_ov == 1 { return ic_replace_inst_uses_with(cmp, c_false()); }
    if hi_ov == -1 { return ic_replace_inst_uses_with(cmp, c_true()); }
    if p == P_UGT { return ic_new_icmp(P_UGE, x, c_int_ap(ty, hi)); }
    return ic_new_icmp(P_SGE, x, c_int_ap(ty, hi));
}

// foldICmpSubConstant(Cmp, Sub, C)
fn fold_icmp_sub_constant(cmp: i32, sub: i32, c: AP) -> i32 {
    let x = op(sub, 0);
    let y = op(sub, 1);
    let p = icc_pred(cmp);
    let ty = vals[sub].ty;
    if icmp_is_equality(p) && m_imm_constant(x) {
        return ic_new_icmp(p, y, ce_binop(OP_SUB, x, c_int_ap(ty, c), 0));
    }
    let sp = pred_swapped(p);
    let nsw = op_nsw(sub);
    let nuw = op_nuw(sub);
    if has_apint(x) && ((pred_is_unsigned(p) && nuw) || (pred_is_signed(p) && nsw)) {
        let c2 = ap_c(x);
        var r = c2;
        var ov = false;
        if pred_is_signed(p) { let a, b = ap_ssub_ov(c2, c); r = a; ov = b; } else { let a, b = ap_usub_ov(c2, c); r = a; ov = b; }
        if !ov { return ic_new_icmp(sp, y, c_int_ap(ty, r)); }
    }
    if icmp_is_equality(p) && ap_is_zero(c) {
        var phi_user = false;
        var u = vals[sub].first_use;
        while u >= 0 { if iop(uses[u].user) == OP_PHI { phi_user = true; } u = uses[u].next; }
        if !phi_user { return ic_new_icmp(p, x, y); }
    }
    if !has_one_use(sub) { return -1; }
    if nsw {
        if p == P_SGT && ap_is_all_ones(c) { return ic_new_icmp(P_SGE, x, y); }
        if p == P_SGT && ap_is_zero(c) { return ic_new_icmp(P_SGT, x, y); }
        if p == P_SLT && ap_is_zero(c) { return ic_new_icmp(P_SLT, x, y); }
        if p == P_SLT && ap_is_one(c) { return ic_new_icmp(P_SLE, x, y); }
    }
    if !has_apint(x) { return -1; }
    let c2 = ap_c(x);
    if p == P_ULT && ap_is_pow2(c) && ap_eq(ap_and(c2, ap_dec(c)), ap_dec(c)) {
        return ic_new_icmp(P_EQ, icb_or(y, c_int_ap(ty, ap_dec(c)), ""), x);
    }
    if p == P_UGT && ap_is_pow2(ap_inc(c)) && ap_eq(ap_and(c2, c), c) {
        return ic_new_icmp(P_NE, icb_or(y, c_int_ap(ty, c), ""), x);
    }
    let add = icb_add_nw(y, c_int_ap(ty, ap_not(c2)), "notsub", nuw, nsw);
    return ic_new_icmp(sp, add, c_int_ap(ty, ap_not(c)));
}

// createLogicFromTable(Table, Op0, Op1, Builder, HasOneUse)
fn create_logic_from_table(t: i64, a: i32, b: i32, one: bool) -> i32 {
    let ty = vals[a].ty;
    match t {
        0 => { return c_bool_ty(ty, false); },
        1 => { return if one { icb_not(icb_or(a, b, ""), "") } else { -1 }; },
        2 => { return if one { icb_and(icb_not(a, ""), b, "") } else { -1 }; },
        3 => { return icb_not(a, ""); },
        4 => { return if one { icb_and(a, icb_not(b, ""), "") } else { -1 }; },
        5 => { return icb_not(b, ""); },
        6 => { return icb_xor(a, b, ""); },
        7 => { return if one { icb_not(icb_and(a, b, ""), "") } else { -1 }; },
        8 => { return icb_and(a, b, ""); },
        9 => { return if one { icb_not(icb_xor(a, b, ""), "") } else { -1 }; },
        10 => { return b; },
        11 => { return if one { icb_or(icb_not(a, ""), b, "") } else { -1 }; },
        12 => { return a; },
        13 => { return if one { icb_or(a, icb_not(b, ""), "") } else { -1 }; },
        14 => { return icb_or(a, b, ""); },
        _ => { return c_bool_ty(ty, true); },
    }
}

// foldICmpBinOpWithConstantViaTruthTable(Cmp, BO, C)
fn fold_icmp_binop_with_constant_via_truth_table(cmp: i32, b: i32, c: AP) -> i32 {
    if !m_select_like(op(b, 0)) { return -1; }
    let a = sl_c;
    let c1 = sl_t;
    let c2 = sl_f;
    if !m_select_like(op(b, 1)) { return -1; }
    let bb = sl_c;
    let c3 = sl_t;
    let c4 = sl_f;
    if vals[cmp].ty != vals[a].ty || vals[cmp].ty != vals[bb].ty { return -1; }
    var table: i64 = 0;
    for i in 4 {
        let first = ((i >> 1) & 1) != 0;
        let second = (i & 1) != 0;
        let l = if first { c1 } else { c2 };
        let r = if second { c3 } else { c4 };
        let res = cf_fold_binop_operands(iop(b), l, r);
        if res < 0 { return -1; }
        let v = if ty_is_vector(vals[res].ty) { splat_value(res, false) } else { res };
        if v < 0 || vals[v].kind != VK_CINT { return -1; }
        if ap_icmp(ci_ap(v), c, icc_pred(cmp)) { table |= (1 as i64) << i; }
    }
    let cond = create_logic_from_table(table, a, bb, has_one_use(b));
    if cond >= 0 { return ic_replace_inst_uses_with(cmp, cond); }
    return -1;
}

// foldICmpAddConstant(Cmp, Add, C)
fn fold_icmp_add_constant(cmp: i32, add: i32, c: AP) -> i32 {
    let y = op(add, 1);
    let x = op(add, 0);
    let pc = icmp_cp(cmp);
    let p = cp_pred(pc);
    let bw = c.w as i64;
    if p == P_ULT && op_nuw(add) {
        for k in 2 {
            let a = op(add, k);
            let s = op(add, 1 - k);
            if bo(s, OP_LSHR) && op(s, 0) == a && has_apint(op(s, 1)) {
                let sh = ap_c(op(s, 1));
                if ap_ult_u64(sh, bw as u64) && ap_ule(c, ap_one_bit(bw, ap_zext64(sh) as i64)) {
                    return ic_new_icmp(p, a, c_int_ap(vals[a].ty, c));
                }
                break;
            }
        }
    }
    if icmp_is_equality(p) || !has_apint(y) { return -1; }
    let c2 = ap_c(y);
    let ty = vals[add].ty;
    if op_nuw(add) && (p == P_UGT || p == P_ULT) {
        let nc, ov = ap_usub_ov(c, c2);
        if !ov { return ic_new_icmp(p, x, c_int_ap(ty, nc)); }
    }
    let chosen = if cp_ss(pc) { pred_signed(p) } else { p };
    if op_nsw(add) && (chosen == P_SGT || chosen == P_SLT) {
        let nc, ov = ap_ssub_ov(c, c2);
        if !ov { return ic_new_icmp(chosen, x, c_int_ap(ty, nc)); }
    }
    if pred_is_unsigned(p) && op_nsw(add) && ap_is_nonneg(c) && ap_is_nonneg(ap_sub(c, c2)) {
        kb_cxt = cmp;
        let xr = compute_constant_range(x, true, true, 0);
        if rg_is_all_nonneg(rg_add(xr, rg_single(c2))) {
            return ic_new_icmp(pred_signed(p), x, c_int_ap(ty, ap_sub(c, c2)));
        }
    }
    let cr = rg_subtract(rg_exact_icmp(p, c), c2);
    let upper = cr.hi;
    let lower = cr.lo;
    if pred_is_signed(p) {
        if ap_is_sign_mask(lower) { return ic_new_icmp(P_SLT, x, c_int_ap(ty, upper)); }
        if ap_is_sign_mask(upper) { return ic_new_icmp(P_SGE, x, c_int_ap(ty, lower)); }
    } else {
        if ap_is_zero(lower) { return ic_new_icmp(P_ULT, x, c_int_ap(ty, upper)); }
        if ap_is_zero(upper) { return ic_new_icmp(P_UGE, x, c_int_ap(ty, lower)); }
    }
    let w = ty_scalar_bits(ty);
    let smax = ap_smax_val(w);
    let smin = ap_smin_val(w);
    if p == P_UGT && ap_eq(c, ap_add(c2, smax)) { return ic_new_icmp(P_SLT, x, c_int_ap(ty, ap_neg(c2))); }
    if p == P_ULT && ap_eq(c, ap_add(c2, smin)) { return ic_new_icmp(P_SGT, x, c_int_ap(ty, ap_not(c2))); }
    if p == P_SGT && ap_eq(c, ap_dec(c2)) { return ic_new_icmp(P_ULT, x, c_int_ap(ty, ap_sub(smax, c))); }
    if p == P_SLT && ap_eq(c, c2) { return ic_new_icmp(P_UGT, x, c_int_ap(ty, ap_xor(c, smax))); }
    if p == P_ULT && ap_is_all_ones(c2) {
        if icc_nonzero(x, cmp) { return ic_new_icmp(P_ULE, x, c_int_ap(ty, c)); }
    }
    if !has_one_use(add) { return -1; }
    if p == P_ULT && ap_is_pow2(c) && ap_is_zero(ap_and(c2, ap_dec(c))) {
        return ic_new_icmp(P_EQ, icb_and(x, c_int_ap(ty, ap_neg(c)), ""), ce_neg(y));
    }
    if p == P_ULT && ap_is_pow2(c2) && ap_eq(c, ap_neg(c2)) {
        return ic_new_icmp(P_NE, icb_and(x, c_int_ap(ty, c), ""), c_int_ap(ty, ap_shl(c, 1)));
    }
    if p == P_UGT && ap_is_pow2(ap_inc(c)) && ap_is_zero(ap_and(c2, c)) {
        return ic_new_icmp(P_NE, icb_and(x, c_int_ap(ty, ap_not(c)), ""), ce_neg(y));
    }
    if p == P_UGT {
        return ic_new_icmp(P_ULT, icb_add(x, c_int_ap(ty, ap_dec(ap_sub(c2, c))), ""), c_int_ap(ty, ap_not(c)));
    }
    let v = m_zext(x);
    if v >= 0 {
        let nty = vals[v].ty;
        let nbw = ty_scalar_bits(nty);
        if should_change_type(ty, nty) {
            let scr = rg_truncate_nw(cr, nbw, NW_NUW);
            let ep, ei, eo = rg_equivalent_icmp_off(scr);
            let lhs = if ap_is_zero(eo) { v } else { icb_add(v, c_int_ap(nty, eo), "") };
            return ic_new_icmp(ep, lhs, c_int_ap(nty, ei));
        }
    }
    return -1;
}

// m_ExtractValue<Ind>: the single index of an extractvalue instruction, -1 otherwise
fn icc_ev_index(v: i32) -> i64 {
    if !is_inst_op(v, OP_EXTRACTVALUE) { return -1; }
    let ii = inst_of(v);
    if insts[ii].naux != 1 { return -2; }
    return ints[insts[ii].aux] as i64;
}

// matchThreeWayIntCompare(SI, LHS, RHS, Less, Equal, Greater): ok, lhs, rhs, less, equal, greater
fn match_three_way_int_compare(si: i32) -> bool, i32, i32, i32, i32, i32 {
    let cond = op(si, 0);
    if !is_inst_op(cond, OP_ICMP) || !icmp_is_equality(icc_pred(cond)) { return false, -1, -1, -1, -1, -1; }
    let lhs = op(cond, 0);
    let rhs = op(cond, 1);
    var eqv = op(si, 1);
    var neqv = op(si, 2);
    if icc_pred(cond) == P_NE { let t = eqv; eqv = neqv; neqv = t; }
    let equal = m_constant_int(eqv);
    if equal < 0 { return false, -1, -1, -1, -1, -1; }
    if !is_select_inst(neqv) || !is_inst_op(op(neqv, 0), OP_ICMP) { return false, -1, -1, -1, -1, -1; }
    var less = m_constant_int(op(neqv, 1));
    var greater = m_constant_int(op(neqv, 2));
    if less < 0 || greater < 0 { return false, -1, -1, -1, -1, -1; }
    let c2 = op(neqv, 0);
    var pb = icc_pred(c2);
    var lhs2 = op(c2, 0);
    var rhs2 = op(c2, 1);
    if lhs2 != lhs { let t = lhs2; lhs2 = rhs2; rhs2 = t; pb = pred_swapped(pb); }
    if lhs2 != lhs { return false, -1, -1, -1, -1, -1; }
    if pb == P_SGT && is_constant(rhs2) {
        let ok, np, nc = icc_flipped_strictness(pb, rhs2);
        if !ok { return false, -1, -1, -1, -1, -1; }
        rhs2 = nc;
        let t = less; less = greater; greater = t;
        pb = P_SLT;
    }
    return pb == P_SLT && rhs == rhs2, lhs, rhs, less, equal, greater;
}

// foldICmpSelectConstant(Cmp, Select, C)
fn fold_icmp_select_constant(cmp: i32, sel: i32, c: i32) -> i32 {
    if !has_one_use(cmp) { return -1; }
    let ok, ol, orr, lt, eq, gt = match_three_way_int_compare(sel);
    if !ok { return -1; }
    let p = icc_pred(cmp);
    let cv = ci_ap(c);
    let twl = ap_icmp(ci_ap(lt), cv, p);
    let twe = ap_icmp(ci_ap(eq), cv, p);
    let twg = ap_icmp(ci_ap(gt), cv, p);
    var cond = c_false();
    if twl { cond = icb_or(cond, icb_icmp(P_SLT, ol, orr, ""), ""); }
    if twe { cond = icb_or(cond, icb_icmp(P_EQ, ol, orr, ""), ""); }
    if twg { cond = icb_or(cond, icb_icmp(P_SGT, ol, orr, ""), ""); }
    return ic_replace_inst_uses_with(cmp, cond);
}

// APFloat(Sem, C).classify() for the classes this file needs (zero / inf / others as 0)
fn icc_fp_bits_class(fty: i32, c: AP) -> u64 {
    let lo = ap_word(c, 0);
    let hi = if c.w > 64 { ap_word(c, 1) } else { 0 };
    let p = fp_decompose(ty_kind(fty), lo, hi);
    if p.cat == FC_INF { return if p.neg { FCL_NEG_INF } else { FCL_POS_INF }; }
    if p.cat == FC_ZERO { return if p.neg { FCL_NEG_ZERO } else { FCL_POS_ZERO }; }
    if p.cat == FC_NAN { return FCL_NAN; }
    if p.expf == 0 { return if p.neg { FCL_NEG_SUBNORMAL } else { FCL_POS_SUBNORMAL }; }
    return if p.neg { FCL_NEG_NORMAL } else { FCL_POS_NORMAL };
}

// IRBuilder::CreateExtractElement(Vec, uint64 Idx)
fn icb_extractelement(vec: i32, idx: i32, name: const u8[:]) -> i32 {
    if is_constant(vec) && is_constant(idx) {
        let f = cf_extractelement(vec, idx);
        if f >= 0 { return f; }
    }
    return icb_insert(create_inst(OP_EXTRACTELEMENT, ty_elem(vals[vec].ty), [vec, idx]), name);
}

// foldICmpBitCast(Cmp)
fn fold_icmp_bitcast(cmp: i32) -> i32 {
    let bc = op(cmp, 0);
    if !is_inst_op(bc, OP_BITCAST) { return -1; }
    let p = icc_pred(cmp);
    let o1 = op(cmp, 1);
    let src = op(bc, 0);
    let sty = vals[src].ty;
    let dty = vals[bc].ty;
    if ty_is_vector(sty) == ty_is_vector(dty) && ty_scalar_bits(sty) == ty_scalar_bits(dty) {
        if is_inst_op(src, OP_SITOFP) {
            let x = op(src, 0);
            if (p == P_EQ || p == P_SLT || p == P_NE || p == P_SGT) && m_zero(o1) { return ic_new_icmp(p, x, c_null(vals[x].ty)); }
            if p == P_SLT && m_one(o1) { return ic_new_icmp(p, x, c_int_ty(vals[x].ty, 1)); }
            if p == P_SGT && m_all_ones(o1) { return ic_new_icmp(p, x, c_all_ones(vals[x].ty)); }
        }
        if is_inst_op(src, OP_UITOFP) {
            let x = op(src, 0);
            if icmp_is_equality(p) && m_zero(o1) { return ic_new_icmp(p, x, c_null(vals[x].ty)); }
        }
        if has_apint(o1) && has_one_use(bc) {
            let c = ap_c(o1);
            let sb, tis = is_sign_bit_check(p, c);
            if sb && (is_inst_op(src, OP_FPEXT) || is_inst_op(src, OP_FPTRUNC)) {
                let x = op(src, 0);
                let xty = vals[x].ty;
                if ty_kind(ty_scalar(xty)) != TK_PPC_FP128 && ty_kind(ty_scalar(sty)) != TK_PPC_FP128 {
                    let nty = ty_with_elem(xty, ty_int(ty_scalar_bits(xty)));
                    let nbc = icb_cast(OP_BITCAST, x, nty, "");
                    if tis { return ic_new_icmp(P_SLT, nbc, c_null(nty)); }
                    return ic_new_icmp(P_SGT, nbc, c_all_ones(nty));
                }
            }
            let fty = ty_scalar(sty);
            if !func_has_fn_attr(inst_func(cmp), AK_NoImplicitFloat) && icmp_is_equality(p) && icc_is_ieee_like(fty) {
                var mask = icc_fp_bits_class(fty, c);
                if (mask & (FCL_INF | FCL_ZERO)) != 0 {
                    if p == P_NE { mask = ~mask & 1023; }
                    return ic_replace_inst_uses_with(cmp, icb_is_fpclass(src, mask));
                }
            }
        }
    }
    if !has_apint(op(cmp, 1)) || !ty_is_int(dty) || !is_int_or_int_vec(sty) { return -1; }
    let c = ap_c(op(cmp, 1));
    if icmp_is_equality(p) && ap_is_all_ones(c) && has_one_use(bc) {
        let nb = get_freely_inverted(src, has_one_use(src), true);
        if nb >= 0 && nb != GFI_NONNULL {
            let cast = icb_cast(OP_BITCAST, nb, dty, "");
            return ic_new_icmp(p, cast, c_null(dty));
        }
    }
    if icmp_is_equality(p) && ap_is_zero(c) && has_one_use(bc) && (is_inst_op(src, OP_ZEXT) || is_inst_op(src, OP_SEXT)) {
        let x = op(src, 0);
        if ty_kind(vals[x].ty) == TK_FVEC {
            let nty = ty_int(ty_count(vals[x].ty) * ty_scalar_bits(vals[x].ty));
            let nc = icb_cast(OP_BITCAST, x, nty, "");
            return ic_new_icmp(p, nc, c_null(nty));
        }
    }
    if is_inst_op(src, OP_SHUFFLEVECTOR) && m_undef(op(src, 1)) {
        let ii = inst_of(src);
        let n = insts[ii].naux as i64;
        var same = true;
        for k in n { if ints[insts[ii].aux + k] != ints[insts[ii].aux] { same = false; } }
        if same {
            let ety = ty_elem(sty);
            let eb = ty_bits(ety);
            if icc_ap_is_splat(c, eb) {
                let m0 = if n > 0 { ints[insts[ii].aux] as i64 } else { 0 };
                let ext = icb_extractelement(op(src, 0), c_int(T_I64, m0), "");
                return ic_new_icmp(p, ext, c_int_ap(ety, ap_trunc(c, eb)));
            }
        }
    }
    return -1;
}
// APInt::isSplat(SplatSizeInBits)
fn icc_ap_is_splat(c: AP, sz: i64) -> bool {
    let w = c.w as i64;
    if w % sz != 0 { return false; }
    return ap_eq(c, ap_rotl(c, sz));
}

// foldICmpInstWithConstant(Cmp)
fn fold_icmp_inst_with_constant(cmp: i32) -> i32 {
    let o0 = op(cmp, 0);
    let o1 = op(cmp, 1);
    if has_apint(o1) {
        let c = ap_c(o1);
        if is_binop_inst(o0) {
            let r = fold_icmp_binop_with_constant(cmp, o0, c);
            if r >= 0 { return r; }
        }
        if is_select_inst(o0) && vals[o1].kind == VK_CINT && !ty_is_vector(vals[o1].ty) {
            let r = fold_icmp_select_constant(cmp, o0, o1);
            if r >= 0 { return r; }
        }
        if is_inst_op(o0, OP_TRUNC) {
            let r = fold_icmp_trunc_constant(cmp, o0, c);
            if r >= 0 { return r; }
        }
        if inst_iid(o0) != 0 {
            let r = fold_icmp_intrinsic_with_constant(cmp, o0, c);
            if r >= 0 { return r; }
        }
        if ap_is_zero(c) && icmp_is_equality(icc_pred(cmp)) && has_one_use(o0) && icc_ev_index(o0) == 0 {
            let agg = op(o0, 0);
            let id = inst_iid(agg);
            if id == IID_ssub_with_overflow || id == IID_usub_with_overflow {
                return ic_new_icmp(icc_pred(cmp), op(agg, 0), op(agg, 1));
            }
        }
    }
    if has_apint_poison(o1) { return fold_icmp_inst_with_constant_allow_poison(cmp, ap_cp(o1)); }
    return -1;
}

// foldICmpBinOpEqualityWithConstant(Cmp, BO, C)
fn fold_icmp_binop_equality_with_constant(cmp: i32, b: i32, c: AP) -> i32 {
    let p = icc_pred(cmp);
    if !icmp_is_equality(p) { return -1; }
    let is_ne = p == P_NE;
    let rhs = op(cmp, 1);
    let b0 = op(b, 0);
    let b1 = op(b, 1);
    let bt = vals[b].ty;
    let o = iop(b);
    if o == OP_SREM {
        if ap_is_zero(c) && has_one_use(b) && has_apint(b1) {
            let boc = ap_c(b1);
            if ap_sgt(boc, ap_u64(1, boc.w as i64)) && ap_is_pow2(boc) {
                var nm: u8[>..] = [];
                nm.append(val_name(b));
                let nr = icb_urem(b0, b1, nm);
                return ic_new_icmp(p, nr, c_null(bt));
            }
        }
    } else if o == OP_ADD {
        if is_constant(b1) {
            if has_one_use(b) { return ic_new_icmp(p, b0, ce_binop(OP_SUB, rhs, b1, 0)); }
        } else if ap_is_zero(c) {
            let n1 = dyn_cast_neg_val(b1);
            if n1 >= 0 { return ic_new_icmp(p, b0, n1); }
            let n0 = dyn_cast_neg_val(b0);
            if n0 >= 0 { return ic_new_icmp(p, n0, b1); }
            if has_one_use(b) {
                if op_nuw(b) {
                    let orv = icb_or(b0, b1, "");
                    return ic_new_icmp(p, orv, c_null(bt));
                }
                let neg = icb_neg(b1, "", false);
                ic_take_name(neg, b);
                return ic_new_icmp(p, b0, neg);
            }
        }
    } else if o == OP_XOR {
        if is_constant(b1) { return ic_new_icmp(p, b0, ce_binop(OP_XOR, rhs, b1, 0)); }
        if ap_is_zero(c) { return ic_new_icmp(p, b0, b1); }
    } else if o == OP_OR {
        if has_apint(b1) && has_one_use(b) && is_all_ones_value(rhs) {
            let nb = ce_not(b1);
            let a = icb_and(b0, nb, "");
            return ic_new_icmp(p, a, nb);
        }
        if ap_is_zero(c) && one_use(b) {
            for k in 2 {
                let sel = op(b, k);
                let other = op(b, 1 - k);
                if !is_select_inst(sel) { continue; }
                let cond = op(sel, 0);
                let tv = op(sel, 1);
                let fv = op(sel, 2);
                if vals[cond].ty != vals[cmp].ty { break; }
                let first = if p == P_EQ { m_zero(tv) && icc_nonzero(fv, cmp) } else { m_zero(fv) && icc_nonzero(tv, cmp) };
                if first {
                    let nc = icb_icmp(p, other, c_null(vals[other].ty), "");
                    return ic_new_binop(if p == P_EQ { OP_AND } else { OP_OR }, nc, cond);
                }
                if has_one_use(sel) {
                    let second = if p == P_EQ { m_zero(fv) && icc_nonzero(tv, cmp) } else { m_zero(tv) && icc_nonzero(fv, cmp) };
                    if second {
                        let notc = icb_not(cond, "");
                        let nc = icb_icmp(p, other, c_null(vals[other].ty), "");
                        return ic_new_binop(if p == P_EQ { OP_AND } else { OP_OR }, nc, notc);
                    }
                }
                break;
            }
        }
    } else if o == OP_UDIV || o == OP_SDIV {
        if op_exact(b) {
            if ap_is_zero(c) { return ic_new_icmp(p, b0, c_null(bt)); }
            if ap_is_one(c) { return ic_new_icmp(p, b0, b1); }
            if has_one_use(b) {
                let r = compute_overflow(OP_MUL, o == OP_SDIV, b1, op(cmp, 1), b);
                if r == OF_NEVER {
                    let yc = icb_mul(b1, c_int_ap(bt, c), "");
                    return ic_new_icmp(p, yc, b0);
                }
            }
        }
        if o == OP_UDIV && ap_is_zero(c) { return ic_new_icmp(if is_ne { P_ULE } else { P_UGT }, b1, b0); }
    }
    return -1;
}

// foldCtpopPow2Test(I, CtpopLhs, CRhs, Builder, Q)
fn fold_ctpop_pow2_test(i: i32, ct: i32, c: AP) -> i32 {
    if !has_one_use(ct) { return -1; }
    let p = icc_pred(i);
    if ((icmp_is_equality(p) || p == P_UGT) && ap_eq_u64(c, 1)) || (p == P_ULT && ap_eq_u64(c, 2)) {
        let x = op(ct, 0);
        // computeKnownBits(Op, DL, AC, CxtI, DT): a query without the DomConditionCache
        let save = dc_active;
        dc_active = false;
        let k = icc_kb(x, i);
        dc_active = save;
        if kb_min_pop(k) == 1 {
            let a = icb_and(x, c_int_ap(vals[x].ty, ap_not(k.o)), "");
            return ic_new_icmp(if p == P_EQ || p == P_ULT { P_EQ } else { P_NE }, a, c_null(vals[x].ty));
        }
    }
    return -1;
}

// foldICmpEqIntrinsicWithConstant(Cmp, II, C)
fn fold_icmp_eq_intrinsic_with_constant(cmp: i32, ii: i32, c: AP) -> i32 {
    let ty = vals[ii].ty;
    let bw = c.w as i64;
    let p = icc_pred(cmp);
    let id = inst_iid(ii);
    let a0 = op(ii, 0);
    if id == IID_abs {
        if ap_is_zero(c) || ap_is_min_signed(c) { return ic_new_icmp(p, a0, c_int_ap(ty, c)); }
    } else if id == IID_bswap {
        return ic_new_icmp(p, a0, c_int_ap(ty, ap_byte_swap(c)));
    } else if id == IID_bitreverse {
        return ic_new_icmp(p, a0, c_int_ap(ty, ap_reverse_bits(c)));
    } else if id == IID_ctlz || id == IID_cttz {
        if ap_eq_u64(c, bw as u64) { return ic_new_icmp(p, a0, c_null(ty)); }
        let num = ap_limited(c, bw as u64) as i64;
        if num != bw && has_one_use(ii) {
            let tr = id == IID_cttz;
            let m1 = if tr { ap_low_bits(bw, num + 1) } else { ap_high_bits(bw, num + 1) };
            let m2 = if tr { ap_one_bit(bw, num) } else { ap_one_bit(bw, bw - num - 1) };
            return ic_new_icmp(p, icb_and(a0, c_int_ap(ty, m1), ""), c_int_ap(ty, m2));
        }
    } else if id == IID_ctpop {
        let z = ap_is_zero(c);
        if z || ap_eq_u64(c, bw as u64) { return ic_new_icmp(p, a0, if z { c_null(ty) } else { c_all_ones(ty) }); }
    } else if id == IID_fshl || id == IID_fshr {
        if a0 == op(ii, 1) && has_apint(op(ii, 2)) {
            let ra = ap_c(op(ii, 2));
            return ic_new_icmp(p, a0, if id == IID_fshl { c_int_ap(ty, ap_rotr_ap(c, ra)) } else { c_int_ap(ty, ap_rotl_ap(c, ra)) });
        }
    } else if id == IID_umax || id == IID_uadd_sat {
        if ap_is_zero(c) && has_one_use(ii) {
            let orv = icb_or(a0, op(ii, 1), "");
            return ic_new_icmp(p, orv, c_null(ty));
        }
    } else if id == IID_ssub_sat {
        if ap_is_zero(c) && ty_scalar_bits(ty) > 1 { return ic_new_icmp(p, a0, op(ii, 1)); }
    } else if id == IID_usub_sat {
        if ap_is_zero(c) { return ic_new_icmp(if p == P_EQ { P_ULE } else { P_UGT }, a0, op(ii, 1)); }
    }
    return -1;
}

// foldICmpIntrinsicWithIntrinsic(Cmp, Builder)
fn fold_icmp_intrinsic_with_intrinsic(cmp: i32) -> i32 {
    let p = icc_pred(cmp);
    let o0 = op(cmp, 0);
    let o1 = op(cmp, 1);
    let id = inst_iid(o0);
    if id == 0 || inst_iid(o1) != id { return -1; }
    if id == IID_bswap || id == IID_bitreverse { return ic_new_icmp(p, op(o0, 0), op(o1, 0)); }
    if id == IID_fshl || id == IID_fshr {
        if op(o0, 0) != op(o0, 1) { return -1; }
        if op(o1, 0) != op(o1, 1) { return -1; }
        if op(o0, 2) == op(o1, 2) { return ic_new_icmp(p, op(o0, 0), op(o1, 0)); }
        let ones = icc_bool(has_one_use(o0)) + icc_bool(has_one_use(o1));
        if ones == 2 || (ones == 1 && m_imm_constant(op(o0, 2)) && m_imm_constant(op(o1, 2))) {
            let sub = icb_sub(op(o0, 2), op(o1, 2), "");
            let rot = icb_intrinsic(id, [vals[o0].ty as i32], [op(o0, 0), op(o0, 0), sub], "");
            return ic_new_icmp(p, op(o1, 0), rot);
        }
    }
    return -1;
}

// foldICmpInstWithConstantAllowPoison(Cmp, C)
fn fold_icmp_inst_with_constant_allow_poison(cmp: i32, c: AP) -> i32 {
    let p = icc_pred(cmp);
    let ii = op(cmp, 0);
    let id = inst_iid(ii);
    if id == IID_fshl || id == IID_fshr {
        if icmp_is_equality(p) && op(ii, 0) == op(ii, 1) {
            if ap_is_zero(c) || ap_is_all_ones(c) { return ic_new_icmp(p, op(ii, 0), op(cmp, 1)); }
        }
    }
    return -1;
}

// foldICmpBinOpWithConstant(Cmp, BO, C)
fn fold_icmp_binop_with_constant(cmp: i32, b: i32, c: AP) -> i32 {
    let o = iop(b);
    var r: i32 = -1;
    if o == OP_XOR { r = fold_icmp_xor_constant(cmp, b, c); }
    else if o == OP_AND { r = fold_icmp_and_constant(cmp, b, c); }
    else if o == OP_OR { r = fold_icmp_or_constant(cmp, b, c); }
    else if o == OP_MUL { r = fold_icmp_mul_constant(cmp, b, c); }
    else if o == OP_SHL { r = fold_icmp_shl_constant(cmp, b, c); }
    else if o == OP_LSHR || o == OP_ASHR { r = fold_icmp_shr_constant(cmp, b, c); }
    else if o == OP_SREM { r = fold_icmp_srem_constant(cmp, b, c); }
    else if o == OP_UDIV {
        r = fold_icmp_udiv_constant(cmp, b, c);
        if r < 0 { r = fold_icmp_div_constant(cmp, b, c); }
    }
    else if o == OP_SDIV { r = fold_icmp_div_constant(cmp, b, c); }
    else if o == OP_SUB { r = fold_icmp_sub_constant(cmp, b, c); }
    else if o == OP_ADD { r = fold_icmp_add_constant(cmp, b, c); }
    if r >= 0 { return r; }
    r = fold_icmp_binop_equality_with_constant(cmp, b, c);
    if r >= 0 { return r; }
    return fold_icmp_binop_with_constant_via_truth_table(cmp, b, c);
}

// foldICmpUSubSatOrUAddSatWithConstant(Pred, II, C, Builder)
fn fold_icmp_usub_sat_or_uadd_sat_with_constant(p0: i64, ii: i32, c: AP) -> i32 {
    if !has_one_use(ii) { return -1; }
    let p = cp_pred(p0);
    let o0 = op(ii, 0);
    let o1 = op(ii, 1);
    if !has_apint(o1) { return -1; }
    let c1v = ap_c(o1);
    let w = c.w as i64;
    let is_add = inst_iid(ii) == IID_uadd_sat;
    let sat = if is_add { ap_ones(w) } else { ap_zero(w) };
    let satchk = ap_icmp(sat, c, p);
    var c1 = rg_exact_no_wrap(if is_add { OP_ADD } else { OP_SUB }, c1v, NW_NUW);
    if satchk { c1 = rg_inverse(c1); }
    var c2 = rg_exact_icmp(p, c);
    if is_add { c2 = rg_sub(c2, rg_single(c1v)); } else { c2 = rg_add(c2, rg_single(c1v)); }
    var ok = false;
    var comb = c1;
    if satchk { let a, b = rg_exact_union(c1, c2); ok = a; comb = b; }
    else { let a, b = rg_exact_intersect(c1, c2); ok = a; comb = b; }
    if !ok { return -1; }
    let ep, ei, eo = rg_equivalent_icmp_off(comb);
    let ty = vals[o1].ty;
    return ic_new_icmp(ep, icb_add(o0, c_int_ap(ty, eo), ""), c_int_ap(ty, ei));
}

// foldICmpOfCmpIntrinsicWithConstant(Pred, I, C, Builder)
fn fold_icmp_of_cmp_intrinsic_with_constant(p0: i64, ii: i32, c: AP) -> i32 {
    let p = cp_pred(p0);
    var np: i64 = -1;
    if p == P_EQ || p == P_NE {
        if ap_is_zero(c) { np = p; }
        else if ap_is_one(c) { np = if p == P_EQ { P_UGT } else { P_ULE }; }
        else if ap_is_all_ones(c) { np = if p == P_EQ { P_ULT } else { P_UGE }; }
    } else if p == P_SGT {
        if ap_is_all_ones(c) { np = P_UGE; } else if ap_is_zero(c) { np = P_UGT; }
    } else if p == P_SLT {
        if ap_is_zero(c) { np = P_ULT; } else if ap_is_one(c) { np = P_ULE; }
    } else if p == P_ULT {
        if ap_ugt_u64(c, 1) { np = P_UGE; }
    } else if p == P_UGT {
        if !ap_is_zero(c) && !ap_is_all_ones(c) { np = P_ULT; }
    }
    if np < 0 { return -1; }
    if inst_iid(ii) == IID_scmp { np = pred_signed(np); }
    return ic_new_icmp(np, op(ii, 0), op(ii, 1));
}

// foldICmpIntrinsicWithConstant(Cmp, II, C)
fn fold_icmp_intrinsic_with_constant(cmp: i32, ii: i32, c: AP) -> i32 {
    let p = icc_pred(cmp);
    let id = inst_iid(ii);
    if id == IID_uadd_sat || id == IID_usub_sat {
        let r = fold_icmp_usub_sat_or_uadd_sat_with_constant(p, ii, c);
        if r >= 0 { return r; }
    } else if id == IID_ctpop {
        let r = fold_ctpop_pow2_test(cmp, ii, c);
        if r >= 0 { return r; }
    } else if id == IID_scmp || id == IID_ucmp {
        let r = fold_icmp_of_cmp_intrinsic_with_constant(p, ii, c);
        if r >= 0 { return r; }
    }
    if icmp_is_equality(p) { return fold_icmp_eq_intrinsic_with_constant(cmp, ii, c); }
    let ty = vals[ii].ty;
    let bw = c.w as i64;
    let a0 = op(ii, 0);
    if id == IID_ctpop {
        if ap_eq_u64(c, (bw - 1) as u64) && p == P_UGT { return ic_new_icmp(P_EQ, a0, c_all_ones(ty)); }
        if ap_eq_u64(c, bw as u64) && p == P_ULT { return ic_new_icmp(P_NE, a0, c_all_ones(ty)); }
    } else if id == IID_ctlz {
        if p == P_UGT && ap_ult_u64(c, bw as u64) {
            let num = ap_zext64(c) as i64;
            return ic_new_icmp(P_ULT, a0, c_int_ap(ty, ap_one_bit(bw, bw - num - 1)));
        }
        if p == P_ULT && ap_uge_u64(c, 1) && ap_ule_u64(c, bw as u64) {
            let num = ap_zext64(c) as i64;
            return ic_new_icmp(P_UGT, a0, c_int_ap(ty, ap_low_bits(bw, bw - num)));
        }
    } else if id == IID_cttz {
        if !has_one_use(ii) { return -1; }
        if p == P_UGT && ap_ult_u64(c, bw as u64) {
            let m = ap_low_bits(bw, (ap_zext64(c) as i64) + 1);
            return ic_new_icmp(P_EQ, icb_and(a0, c_int_ap(ty, m), ""), c_null(ty));
        }
        if p == P_ULT && ap_uge_u64(c, 1) && ap_ule_u64(c, bw as u64) {
            let m = ap_low_bits(bw, ap_zext64(c) as i64);
            return ic_new_icmp(P_NE, icb_and(a0, c_int_ap(ty, m), ""), c_null(ty));
        }
    } else if id == IID_ssub_sat {
        if pred_is_signed(p) && bw > 1 {
            if ap_is_zero(c) { return ic_new_icmp(p, a0, op(ii, 1)); }
            if p == P_SLT && ap_is_one(c) { return ic_new_icmp(P_SLE, a0, op(ii, 1)); }
            if p == P_SGT && ap_is_all_ones(c) { return ic_new_icmp(P_SGE, a0, op(ii, 1)); }
        }
    } else if id == IID_abs {
        if !has_one_use(ii) { return -1; }
        let x = a0;
        let imp = ap_is_one(ci_ap(op(ii, 1)));
        if p == P_UGT && ap_is_nonneg(c) {
            return ic_new_icmp(P_UGT, icb_add(x, c_int_ap(ty, c), ""), c_int_ap(ty, ap_shl(c, 1)));
        }
        if imp && p == P_ULT && ap_sge(c, ap_u64(1, bw)) {
            let cm1 = ap_dec(c);
            return ic_new_icmp(P_ULE, icb_add(x, c_int_ap(ty, cm1), ""), c_int_ap(ty, ap_shl(cm1, 1)));
        }
    }
    return -1;
}

// foldICmpInstWithConstantNotInt(I)
fn fold_icmp_inst_with_constant_not_int(i: i32) -> i32 {
    let o0 = op(i, 0);
    let o1 = op(i, 1);
    if !is_constant(o1) || !is_inst(o0) { return -1; }
    let o = iop(o0);
    if o == OP_INTTOPTR {
        if vals[o1].kind == VK_CNULL {
            let ipt = ic_int_ptr_type(vals[o1].ty);
            if ipt == vals[op(o0, 0)].ty {
                return ic_new_icmp(icc_pred(i), op(o0, 0), c_null(ipt));
            }
        }
    } else if o == OP_LOAD {
        if is_inst_op(op(o0, 0), OP_GEP) {
            let r = fold_cmp_load_from_indexed_global(o0, op(o0, 0), i, -1);
            if r >= 0 { return r; }
        }
    }
    return -1;
}

// foldSelectICmp(Pred, SI, RHS, I)
fn fold_select_icmp(p0: i64, si: i32, rhs: i32, i: i32) -> i32 {
    let o1 = icc_select_simplify_op(p0, si, op(si, 1), rhs, true);
    var ci: i32 = -1;
    if o1 >= 0 { ci = m_constant_int(o1); }
    let o2 = icc_select_simplify_op(p0, si, op(si, 2), rhs, false);
    if o2 >= 0 { ci = m_constant_int(o2); }
    var tr = false;
    if o1 >= 0 && o2 >= 0 { tr = true; }
    else if icc_select_simplifies(o1, si, 1, rhs) || icc_select_simplifies(o2, si, 2, rhs) {
        if has_one_use(si) { tr = true; }
        else if ci >= 0 && !ap_is_zero(ci_ap(ci)) { tr = replaced_select_with_operand(si, i, if o1 >= 0 { 2 } else { 1 }); }
    }
    if tr {
        var nm: u8[>..] = [];
        nm.append(val_name(i));
        var a = o1;
        var b = o2;
        if a < 0 { a = icb_icmp(cp_pred(p0), op(si, 1), rhs, nm); }
        if b < 0 { b = icb_icmp(cp_pred(p0), op(si, 2), rhs, nm); }
        return ic_new_select_md(op(si, 0), a, b, si);
    }
    return -1;
}
fn icc_select_simplify_op(p0: i64, si: i32, v: i32, rhs: i32, cond_true: bool) -> i32 {
    let r = simplify_icmp(p0, v, rhs, sq_at(icc_sq_cxt), RECURSION_LIMIT);
    if r >= 0 { return r; }
    let imp = implied_condition(op(si, 0), p0, v, rhs, cond_true, 0);
    if imp >= 0 { return c_bool_ty(cmp_result_ty(vals[v].ty), imp == 1); }
    return -1;
}
fn icc_select_simplifies(o: i32, si: i32, k: i64, rhs: i32) -> bool {
    if o >= 0 { return true; }
    let x = op(si, k);
    let id = inst_iid(x);
    return (id == IID_scmp || id == IID_ucmp) && has_one_use(x) && has_apint(rhs);
}
// the SimplifyQuery `SQ` of the InstCombiner has no context instruction
var icc_sq_cxt: i32 = -1;

// isMaskOrZero(V, Not, Q, Depth): V is a Mask ((X + 1) & X == 0) or ~Mask (-Pow2OrZero)
recursive fn is_mask_or_zero(v: i32, not: bool, cx: i32, depth0: i64) -> bool {
    if (not && m_cint_pred(v, IP_NEG_POWER2_OR_ZERO, true)) || (!not && m_cint_pred(v, IP_LOWBITMASK_OR_ZERO, true)) { return true; }
    if ty_sbits(v) == 1 { return true; }
    var depth = depth0;
    if depth >= 6 { return false; }
    depth++;
    if !is_inst(v) { return false; }
    let o = iop(v);
    if o == OP_ZEXT { return !not && is_mask_or_zero(op(v, 0), not, cx, depth); }
    if o == OP_SEXT { return is_mask_or_zero(op(v, 0), not, cx, depth); }
    if o == OP_AND || o == OP_OR { return is_mask_or_zero(op(v, 1), not, cx, depth) && is_mask_or_zero(op(v, 0), not, cx, depth); }
    if o == OP_XOR {
        let x = m_not(v);
        if x >= 0 { return is_mask_or_zero(x, !not, cx, depth); }
        for k in 2 {
            let a = op(v, k);
            let b = op(v, 1 - k);
            if not { if m_neg(b) == a { return true; } }
            else { if bo(b, OP_ADD) && op(b, 0) == a && m_all_ones(op(b, 1)) { return true; } }
        }
        return false;
    }
    if o == OP_SELECT { return is_mask_or_zero(op(v, 1), not, cx, depth) && is_mask_or_zero(op(v, 2), not, cx, depth); }
    if o == OP_SHL { return not && is_mask_or_zero(op(v, 0), not, cx, depth); }
    if o == OP_LSHR { return !not && is_mask_or_zero(op(v, 0), not, cx, depth); }
    if o == OP_ASHR { return is_mask_or_zero(op(v, 0), not, cx, depth); }
    if o == OP_ADD {
        if !not && m_all_ones(op(v, 1)) { return icc_pow2_nodc(op(v, 0), cx, depth); }
        return false;
    }
    if o == OP_SUB {
        if not && m_zero(op(v, 0)) { return icc_pow2_nodc(op(v, 1), cx, depth); }
        return false;
    }
    let id = inst_iid(v);
    if id == IID_umax || id == IID_smax || id == IID_umin || id == IID_smin {
        return is_mask_or_zero(op(v, 1), not, cx, depth) && is_mask_or_zero(op(v, 0), not, cx, depth);
    }
    if id == IID_bitreverse { return is_mask_or_zero(op(v, 0), !not, cx, depth); }
    return false;
}
// isKnownToBeAPowerOfTwo(V, DL, OrZero=true, AC, CxtI, DT, Depth): a query without the DomConditionCache
recursive fn icc_pow2_nodc(v: i32, cx: i32, depth: i64) -> bool {
    let save = dc_active;
    dc_active = false;
    kb_cxt = cx;
    let r = is_known_pow2(v, true, depth);
    dc_active = save;
    return r;
}

// foldICmpWithLowBitMaskedVal(Pred, Op0, Op1, Q, IC)
fn fold_icmp_with_low_bit_masked_val(p0: i64, o0: i32, o1: i32, cx: i32) -> i32 {
    let p = cp_pred(p0);
    var dp: i64 = 0;
    if p == P_EQ { dp = P_ULE; }
    else if p == P_NE { dp = P_UGT; }
    else if p == P_ULT { dp = P_UGT; }
    else if p == P_UGE { dp = P_ULE; }
    else if p == P_SLT { dp = P_SGT; }
    else if p == P_SGE { dp = P_SLE; }
    else { return -1; }
    var x: i32 = -1;
    var m: i32 = -1;
    var ok = false;
    if bo(o0, OP_AND) && (op(o0, 0) == o1 || op(o0, 1) == o1) {
        m = if op(o0, 0) == o1 { op(o0, 1) } else { op(o0, 0) };
        x = o1;
        if is_mask_or_zero(m, false, cx, 0) {
            ok = !pred_is_signed(p) || (m_nonneg(m) || icc_known_nonneg(m, cx));
        } else if is_mask_or_zero(x, true, cx, 0) {
            ok = !pred_is_signed(p) || icc_nonzero(x, cx);
        }
    } else if icmp_is_equality(p) && m_all_ones(o1) && one_use(o0) && bo(o0, OP_OR) {
        x = op(o0, 0);
        m = op(o0, 1);
        for k in 2 {
            if is_mask_or_zero(m, false, cx, 0) {
                let nx = get_freely_inverted(x, has_one_use(x), true);
                if nx >= 0 { x = nx; ok = true; break; }
            }
            if k == 0 { let t = x; x = m; m = t; }
        }
    } else if icmp_is_equality(p) && m_zero(o1) && one_use(o0) && bo(o0, OP_AND) {
        x = op(o0, 0);
        m = op(o0, 1);
        for k in 2 {
            if is_mask_or_zero(m, true, cx, 0) {
                let nm = get_freely_inverted(m, has_one_use(m), true);
                if nm >= 0 { m = nm; ok = true; break; }
            }
            if k == 0 { let t = x; x = m; m = t; }
        }
    }
    if !ok { return -1; }
    return icb_icmp(dp, x, m, "");
}

// foldICmpWithTruncSignExtendedVal(I, Builder)
fn fold_icmp_with_trunc_sign_extended_val(i: i32) -> i32 {
    var sp = icc_pred(i);
    var x: i32 = -1;
    var c0: i32 = -1;
    var c1: i32 = -1;
    for k in 2 {
        let a = op(i, k);
        let b = op(i, 1 - k);
        if one_use(a) && bo(a, OP_ASHR) && bo(op(a, 0), OP_SHL) && has_apint(op(op(a, 0), 1)) && has_apint(op(a, 1)) && op(op(a, 0), 0) == b {
            x = b; c0 = op(op(a, 0), 1); c1 = op(a, 1);
            if k == 1 { sp = pred_swapped(sp); }
            break;
        }
    }
    if x < 0 { return -1; }
    if !ap_eq(ap_c(c0), ap_c(c1)) { return -1; }
    let mb = ap_c(c0);
    var dp: i64 = 0;
    if sp == P_EQ { dp = P_ULT; } else if sp == P_NE { dp = P_UGE; } else { return -1; }
    let xty = vals[x].ty;
    let xbw = ty_scalar_bits(xty);
    let kept = ap_sub(ap_u64(xbw as u64, xbw), mb);
    let icst = ap_shl_ap(ap_u64(1, xbw), kept);
    let addc = ap_lshr(icst, 1);
    let t0 = icb_add(x, c_int_ap(xty, addc), "");
    return icb_icmp(dp, t0, c_int_ap(xty, icst), "");
}

fn icc_is_logical_shift(v: i32) -> bool { bo(v, OP_LSHR) || bo(v, OP_SHL) }
// getUniqueInteger of a constant int or int splat
fn icc_unique_int(c: i32) -> AP { if vals[c].kind == VK_CINT { ci_ap(c) } else { ci_ap(splat_value(c, false)) } }

// foldShiftIntoShiftInAnotherHandOfAndInICmp(I, SQ, Builder)
fn fold_shift_into_shift_in_another_hand_of_and_in_icmp(i: i32) -> i32 {
    if !icmp_is_equality(icc_pred(i)) || !m_zero(op(i, 1)) || !has_one_use(op(i, 0)) { return -1; }
    let a = op(i, 0);
    if !bo(a, OP_AND) { return -1; }
    var xs: i32 = -1;
    var ys: i32 = -1;
    var mt: i32 = -1;
    for k in 2 {
        let l = op(a, k);
        let r = op(a, 1 - k);
        if !icc_is_logical_shift(l) || !is_inst(r) { continue; }
        let t = icc_trunc_or_self(r);
        if !icc_is_logical_shift(t) { continue; }
        xs = l; ys = t; mt = r;
        break;
    }
    if xs < 0 { return -1; }
    let widest = ys;
    let narrowest = xs;
    let wty = vals[widest].ty;
    let nty = vals[narrowest].ty;
    let had_trunc = wty != vals[a].ty;
    if bo(ys, OP_LSHR) { let t = xs; xs = ys; ys = t; }
    let xso = iop(xs);
    if xso == iop(ys) { return -1; }
    let x = op(xs, 0);
    let xsa = icc_zext_or_self(op(xs, 1));
    let y = op(ys, 0);
    let ysa = icc_zext_or_self(op(ys, 1));
    if !is_constant(x) && !is_constant(y) {
        if !((one_use(op(a, 0)) && icc_is_logical_shift(op(a, 0))) || (one_use(op(a, 1)) && icc_is_logical_shift(op(a, 1)))) { return -1; }
        if had_trunc {
            if !has_one_use(mt) && !has_one_use(op(narrowest, 1)) { return -1; }
        }
    }
    if vals[xsa].ty != vals[ysa].ty { return -1; }
    let maxtot = (ty_scalar_bits(wty) - 1) + (ty_scalar_bits(nty) - 1);
    if ap_ult_u64(ap_ones(ty_sbits(xsa)), maxtot as u64) { return -1; }
    var nsa = simplify_add(xsa, ysa, false, false, sq_at(i), RECURSION_LIMIT);
    if nsa < 0 || !is_constant(nsa) { return -1; }
    if vals[nsa].ty != wty {
        nsa = cf_fold_cast_operand(OP_ZEXT, nsa, wty);
        if nsa < 0 { return -1; }
    }
    let wbw = ty_scalar_bits(wty);
    if !c_all_elts_cmp(nsa, P_ULT, wbw as u64) { return -1; }
    if had_trunc && bo(widest, OP_LSHR) {
        if !icc_shift_into_shift_can_fold(nsa, wbw, narrowest, widest) { return -1; }
    }
    let zx = icb_zext(x, wty, "");
    let zy = icb_zext(y, wty, "");
    let t0 = if xso == OP_LSHR { icb_lshr(zx, nsa, "", false) } else { icb_shl(zx, nsa, "") };
    let t1 = icb_and(t0, zy, "");
    return icb_icmp(icc_pred(i), t1, c_null(wty), "");
}
fn icc_shift_into_shift_can_fold(nsa: i32, wbw: i64, narrowest: i32, widest: i32) -> bool {
    let sp = if ty_is_vector(vals[nsa].ty) { splat_value(nsa, false) } else { nsa };
    if sp >= 0 && (is_null_value(sp) || ap_eq_u64(icc_unique_int(sp), (wbw - 1) as u64)) { return true; }
    let c1 = op(narrowest, 0);
    if is_constant(c1) {
        kb_cxt = -1;
        let k = kb_compute_all(c1, 0);
        let mlz = kb_min_lz(k);
        if kb_bw(k) - mlz <= 1 { return true; }
        if sp >= 0 && ap_ule_u64(icc_unique_int(sp), mlz as u64) { return true; }
    }
    let c2 = op(widest, 0);
    if is_constant(c2) {
        kb_cxt = -1;
        let k = kb_compute_all(c2, 0);
        let mlz = kb_min_lz(k);
        if kb_bw(k) - mlz <= 1 { return true; }
        if sp >= 0 {
            let u = icc_unique_int(sp);
            let adj = ap_sub(ap_u64((wbw - 1) as u64, u.w as i64), u);
            if ap_ule_u64(adj, mlz as u64) { return true; }
        }
    }
    return false;
}

// foldMultiplicationOverflowCheck(I)
fn fold_multiplication_overflow_check(i: i32) -> i32 {
    var p = icc_pred(i);
    var x: i32 = -1;
    var y: i32 = -1;
    var mul: i32 = -1;
    var dv: i32 = -1;
    var neg = false;
    var found = false;
    if !icmp_is_equality(p) {
        for k in 2 {
            let d = op(i, k);
            if one_use(d) && bo(d, OP_UDIV) && m_all_ones(op(d, 0)) {
                x = op(d, 1); y = op(i, 1 - k); dv = d;
                if k == 1 { p = pred_swapped(p); }
                found = true;
                break;
            }
        }
        if !found { return -1; }
        if p == P_ULT { neg = false; } else if p == P_UGE { neg = true; } else { return -1; }
    } else {
        for k in 2 {
            let yy = op(i, k);
            let d = op(i, 1 - k);
            if !one_use(d) || !icc_is_idiv(d) { continue; }
            let m = op(d, 0);
            if !bo(m, OP_MUL) { continue; }
            var xx: i32 = -1;
            if op(m, 0) == yy { xx = op(m, 1); } else if op(m, 1) == yy { xx = op(m, 0); }
            if xx < 0 || op(d, 1) != xx { continue; }
            x = xx; y = yy; mul = m; dv = d;
            found = true;
            break;
        }
        if !found { return -1; }
        neg = p == P_EQ;
    }
    let spos = icb_pos; let sbb = icb_bb; let sdl = icb_dl;
    let mul_other = mul >= 0 && !has_one_use(mul);
    if mul_other { icb_set_insert_point(mul); }
    let call = icb_intrinsic(if iop(dv) == OP_UDIV { IID_umul_with_overflow } else { IID_smul_with_overflow }, [vals[x].ty as i32], [x, y], "mul");
    if mul_other { ic_replace_inst_uses_with(mul, icb_extractvalue(call, 0, "mul.val")); }
    var res = icb_extractvalue(call, 1, "mul.ov");
    if neg { res = icb_not(res, "mul.not.ov"); }
    if mul_other { ic_erase(mul); }
    icb_pos = spos; icb_bb = sbb; icb_dl = sdl; icb_head = false;
    return res;
}

// foldICmpXNegX(I, Builder)
fn fold_icmp_xneg_x(i: i32) -> i32 {
    for k in 2 {
        let n = op(i, k);
        let x = op(i, 1 - k);
        if bo(n, OP_SUB) && op_nsw(n) && m_zero_int(op(n, 0)) && op(n, 1) == x {
            var p = icc_pred(i);
            if k == 1 { p = pred_swapped(p); }
            if pred_is_signed(p) { p = pred_swapped(p); }
            else if pred_is_unsigned(p) { p = pred_signed(p); }
            return ic_new_icmp(p, x, c_null(vals[x].ty));
        }
    }
    for k in 2 {
        let n = op(i, k);
        let x = op(i, 1 - k);
        if one_use(n) && m_neg(n) == x && x >= 0 {
            let p = icc_pred(i);
            if !icmp_is_equality(p) { return -1; }
            let ty = vals[x].ty;
            let a = icb_and(x, c_int_ap(ty, ap_smax_val(ty_scalar_bits(ty))), "");
            return ic_new_icmp(p, a, c_null(ty));
        }
    }
    return -1;
}

// foldICmpAndXX(I, Q, IC)
fn fold_icmp_and_xx(i: i32) -> i32 {
    var o0 = op(i, 0);
    var o1 = op(i, 1);
    var p = icc_pred(i);
    if bo(o1, OP_AND) && (op(o1, 0) == o0 || op(o1, 1) == o0) {
        let t = o0; o0 = o1; o1 = t;
        p = pred_swapped(p);
    }
    if !bo(o0, OP_AND) { return -1; }
    var a: i32 = -1;
    if op(o0, 0) == o1 { a = op(o0, 1); } else if op(o0, 1) == o1 { a = op(o0, 0); } else { return -1; }
    if p == P_ULT { return ic_new_icmp(P_NE, o0, o1); }
    if p == P_UGE { return ic_new_icmp(P_EQ, o0, o1); }
    if icmp_is_equality(p) && has_one_use(o0) {
        if !m_imm_constant(o1) {
            let n1 = get_freely_inverted(o1, !has_n_uses_or_more(o1, 3), true);
            if n1 >= 0 { return ic_new_icmp(p, icb_or(a, n1, ""), c_all_ones(vals[o1].ty)); }
        }
        let na = get_freely_inverted(a, has_one_use(a), true);
        if na >= 0 { return ic_new_icmp(p, icb_and(o1, na, ""), c_null(vals[o1].ty)); }
    }
    if !pred_is_signed(p) { return -1; }
    let ky = icc_kb(a, i);
    if kb_is_neg(ky) { return ic_new_icmp(pred_unsigned(p), o0, o1); }
    if p != P_SLE && p != P_SGT { return -1; }
    if kb_is_nonneg(ky) { return ic_new_icmp(pred_swapped(p), o1, c_null(vals[o1].ty)); }
    if icc_known_negative(o1, i) {
        return ic_new_icmp(if p == P_SLE { P_SLT } else { P_SGE }, a, c_null(vals[a].ty));
    }
    return -1;
}

// foldICmpOrXX(I, Q, IC)
fn fold_icmp_or_xx(i: i32) -> i32 {
    var o0 = op(i, 0);
    var o1 = op(i, 1);
    var p = icc_pred(i);
    var a: i32 = -1;
    if bo(o1, OP_OR) && (op(o1, 0) == o0 || op(o1, 1) == o0) {
        a = if op(o1, 0) == o0 { op(o1, 1) } else { op(o1, 0) };
        let t = o0; o0 = o1; o1 = t;
        p = pred_swapped(p);
    } else if bo(o0, OP_OR) && (op(o0, 0) == o1 || op(o0, 1) == o1) {
        a = if op(o0, 0) == o1 { op(o0, 1) } else { op(o0, 0) };
    } else { return -1; }
    if p == P_ULE { return ic_new_icmp(P_EQ, o0, o1); }
    if p == P_UGT { return ic_new_icmp(P_NE, o0, o1); }
    if icmp_is_equality(p) && has_one_use(o0) {
        let n1 = get_freely_inverted(o1, !is_constant(o1) && !has_n_uses_or_more(o1, 3), true);
        if n1 >= 0 { return ic_new_icmp(p, icb_and(a, n1, ""), c_null(vals[o1].ty)); }
        let na = get_freely_inverted(a, has_one_use(a), true);
        if na >= 0 { return ic_new_icmp(p, icb_or(o1, na, ""), c_all_ones(vals[o1].ty)); }
    }
    return -1;
}

// foldICmpXorXX(I, Q, IC)
fn fold_icmp_xor_xx(i: i32) -> i32 {
    var o0 = op(i, 0);
    var o1 = op(i, 1);
    var p = icc_pred(i);
    if bo(o1, OP_XOR) && (op(o1, 0) == o0 || op(o1, 1) == o0) {
        let t = o0; o0 = o1; o1 = t;
        p = pred_swapped(p);
    }
    if !bo(o0, OP_XOR) { return -1; }
    var a: i32 = -1;
    if op(o0, 0) == o1 { a = op(o0, 1); } else if op(o0, 1) == o1 { a = op(o0, 0); } else { return -1; }
    let po = pred_strict(p);
    if po != p && icc_nonzero(a, i) { return ic_new_icmp(po, o0, o1); }
    if m_negative(a) {
        let sp = pred_strict(p);
        var np: i64 = 0;
        if sp == P_SLT || sp == P_UGT { np = P_SLT; }
        else if sp == P_SGT || sp == P_ULT { np = P_SGE; }
        else { return -1; }
        return ic_new_icmp(np, o0, c_null(vals[o0].ty));
    }
    return -1;
}

// isMultipleOf(X, C, Q)
fn is_multiple_of(x: i32, c: AP, cx: i32) -> bool {
    if ap_is_one(c) { return true; }
    if !ap_is_pow2(c) { return false; }
    kb_cxt = cx;
    return masked_value_is_zero(x, ap_dec(c), 0);
}

fn icc_is_lt(p: i64) -> bool { p == P_SLT || p == P_ULT }
fn icc_is_gt(p: i64) -> bool { p == P_SGT || p == P_UGT }
fn icc_is_le(p: i64) -> bool { p == P_SLE || p == P_ULE }
fn icc_is_ge(p: i64) -> bool { p == P_SGE || p == P_UGE }
// CmpInst::getFlippedStrictnessPredicate
fn icc_flip_strict(p: i64) -> i64 { if pred_strict(p) == p { pred_nonstrict(p) } else { pred_strict(p) } }
// the hasNoWrapProblem lambda of foldICmpBinOp: no-wrap-problem, nsw, nuw
fn icc_has_no_wrap_problem(b: i32, p: i64) -> bool, bool, bool {
    let o = iop(b);
    if is_overflowing_op(o) {
        let nuw = op_nuw(b);
        let nsw = op_nsw(b);
        return icmp_is_equality(p) || (pred_is_unsigned(p) && nuw) || (pred_is_signed(p) && nsw), nsw, nuw;
    }
    if o == OP_OR { return true, true, true; }
    return false, false, false;
}
// the ShareCommonDivisor lambda of foldICmpBinOp
fn icc_share_common_divisor(x: i32, y: i32, z: i32, neg: bool, cx: i32) -> bool {
    if !has_apint(z) { return false; }
    let oc = ap_c(z);
    if if neg { ap_is_all_ones(oc) } else { ap_is_one(oc) } { return true; }
    var c = oc;
    if neg { c = ap_neg(c); }
    if !ap_is_strictly_pos(c) { return false; }
    return is_multiple_of(x, c, cx) && is_multiple_of(y, c, cx);
}

// foldICmpBinOp(I, SQ)
fn fold_icmp_binop(i: i32) -> i32 {
    let o0 = op(i, 0);
    let o1 = op(i, 1);
    let b0 = if is_binop_inst(o0) { o0 } else { -1 };
    let b1 = if is_binop_inst(o1) { o1 } else { -1 };
    if b0 < 0 && b1 < 0 { return -1; }
    var r = fold_icmp_xneg_x(i);
    if r >= 0 { return r; }
    let p = icc_pred(i);
    if one_use(o0) && bo(o0, OP_ADD) && (op(o0, 0) == o1 || op(o0, 1) == o1) && (p == P_ULT || p == P_UGE) {
        let x = if op(o0, 0) == o1 { op(o0, 1) } else { op(o0, 0) };
        return ic_new_icmp(p, icb_not(o1, ""), x);
    }
    if one_use(o1) && bo(o1, OP_ADD) && (op(o1, 0) == o0 || op(o1, 1) == o0) && (p == P_UGT || p == P_ULE) {
        let x = if op(o1, 0) == o0 { op(o1, 1) } else { op(o1, 0) };
        return ic_new_icmp(p, x, icb_not(o0, ""));
    }
    if one_use(o0) && bo(o0, OP_ADD) && m_imm_constant(op(o0, 1)) && bo(op(o0, 0), OP_ADD) &&
       (op(op(o0, 0), 0) == o1 || op(op(o0, 0), 1) == o1) && (p == P_ULT || p == P_UGE) {
        let ia = op(o0, 0);
        let x = if op(ia, 0) == o1 { op(ia, 1) } else { op(ia, 0) };
        let c2 = ce_not(op(o0, 1));
        return ic_new_icmp(p, icb_sub(c2, x, ""), o1);
    }
    if one_use(o1) && bo(o1, OP_ADD) && m_imm_constant(op(o1, 1)) && bo(op(o1, 0), OP_ADD) &&
       (op(op(o1, 0), 0) == o0 || op(op(o1, 0), 1) == o0) && (p == P_UGT || p == P_ULE) {
        let ia = op(o1, 0);
        let x = if op(ia, 0) == o0 { op(ia, 1) } else { op(ia, 0) };
        let c2 = ce_not(op(o1, 1));
        return ic_new_icmp(p, o0, icb_sub(c2, x, ""));
    }
    if icmp_is_equality(p) && b0 >= 0 && m_sign_mask(o1) && bo(b0, OP_AND) && m_cint_pred(op(b0, 1), IP_NEG_POWER2_OR_ZERO, true) {
        let nc = icb_sub(o1, op(b0, 1), "");
        return ic_new_icmp(if p == P_EQ { P_SLT } else { P_SGE }, op(b0, 0), nc);
    }
    if (p == P_ULT || p == P_UGE) && bo(o0, OP_AND) && is_binop_inst(op(o0, 0)) && m_low_bit_mask(op(o0, 1)) && has_apint_poison(op(o0, 1)) {
        let bb = op(o0, 0);
        if bo(bb, OP_ADD) && op(bb, 0) == o1 && icc_specific_int_poison(op(bb, 1), ap_cp(op(o0, 1))) {
            return ic_new_icmp(if p == P_ULT { P_NE } else { P_EQ }, o1, c_null(vals[o1].ty));
        }
    }
    if (p == P_UGT || p == P_ULE) && bo(o1, OP_AND) && is_binop_inst(op(o1, 0)) && m_low_bit_mask(op(o1, 1)) && has_apint_poison(op(o1, 1)) {
        let bb = op(o1, 0);
        if bo(bb, OP_ADD) && op(bb, 0) == o0 && icc_specific_int_poison(op(bb, 1), ap_cp(op(o1, 1))) {
            return ic_new_icmp(if p == P_UGT { P_NE } else { P_EQ }, o0, c_null(vals[o1].ty));
        }
    }
    var nw0 = false; var nw1 = false;
    var nuw0 = false; var nuw1 = false;
    var nsw0 = false; var nsw1 = false;
    var a: i32 = -1; var b: i32 = -1; var c: i32 = -1; var d: i32 = -1;
    if b0 >= 0 {
        if m_add_like(b0) { a = op(b0, 0); b = op(b0, 1); }
        let x, y, z = icc_has_no_wrap_problem(b0, p);
        nw0 = x; nsw0 = y; nuw0 = z;
    }
    if b1 >= 0 {
        if m_add_like(b1) { c = op(b1, 0); d = op(b1, 1); }
        let x, y, z = icc_has_no_wrap_problem(b1, p);
        nw1 = x; nsw1 = y; nuw1 = z;
    }
    if a >= 0 && (a == o1 || b == o1) && nw0 { return ic_new_icmp(p, if a == o1 { b } else { a }, c_null(vals[o1].ty)); }
    if c >= 0 && (c == o0 || d == o0) && nw1 { return ic_new_icmp(p, c_null(vals[o0].ty), if c == o0 { d } else { c }); }
    if a >= 0 && c >= 0 && (a == c || a == d || b == c || b == d) && nw0 && nw1 {
        var y: i32 = -1; var z: i32 = -1;
        if a == c { y = b; z = d; }
        else if a == d { y = b; z = c; }
        else if b == c { y = a; z = d; }
        else { y = a; z = c; }
        return ic_new_icmp(p, y, z);
    }
    if pred_relational(p) {
        if a >= 0 && nw0 && icc_share_common_divisor(a, o1, b, icc_is_lt(p) || icc_is_ge(p), i) { return ic_new_icmp(icc_flip_strict(p), a, o1); }
        if c >= 0 && nw1 && icc_share_common_divisor(o0, c, d, icc_is_gt(p) || icc_is_le(p), i) { return ic_new_icmp(icc_flip_strict(p), o0, c); }
    }
    if a >= 0 && c >= 0 && nw0 && nw1 && (has_one_use(b0) || has_one_use(b1)) && !pred_is_unsigned(p) {
        if has_apint_poison(b) && has_apint_poison(d) && ap_is_neg(ap_cp(b)) == ap_is_neg(ap_cp(d)) {
            let ap1 = ap_cp(b);
            let ap2 = ap_cp(d);
            if ap_uge(ap_abs(ap1), ap_abs(ap2)) {
                let diff = ap_sub(ap1, ap2);
                let c3 = c_int_ap(vals[b0].ty, diff);
                let na = icb_add_nw(a, c3, "", nuw0 && ap_ule(diff, ap1), nsw0);
                return ic_new_icmp(p, na, c);
            } else {
                let diff = ap_sub(ap2, ap1);
                let c3 = c_int_ap(vals[b0].ty, diff);
                let na = icb_add_nw(c, c3, "", nuw1 && ap_ule(diff, ap2), nsw1);
                return ic_new_icmp(p, a, na);
            }
        }
        if m_imm_constant(b) && m_imm_constant(d) && icmp_is_equality(p) {
            let diff = ce_binop(OP_SUB, d, b, 0);
            let na = icb_add(c, diff, "");
            return ic_new_icmp(p, a, na);
        }
    }
    a = -1; b = -1; c = -1; d = -1;
    if b0 >= 0 && iop(b0) == OP_SUB { a = op(b0, 0); b = op(b0, 1); }
    if b1 >= 0 && iop(b1) == OP_SUB { c = op(b1, 0); d = op(b1, 1); }
    if a >= 0 && a == o1 && nw0 { return ic_new_icmp(p, c_null(vals[o1].ty), b); }
    if c >= 0 && c == o0 && nw1 { return ic_new_icmp(p, d, c_null(vals[o0].ty)); }
    if a >= 0 && a == o1 && (p == P_UGT || p == P_ULE) { return ic_new_icmp(p, b, a); }
    if c >= 0 && c == o0 && (p == P_ULT || p == P_UGE) { return ic_new_icmp(p, c, d); }
    if a >= 0 && a == o1 && (p == P_UGE || p == P_ULT) && icc_nonzero(b, i) { return ic_new_icmp(icc_flip_strict(p), b, a); }
    if c >= 0 && c == o0 && (p == P_ULE || p == P_UGT) && icc_nonzero(d, i) { return ic_new_icmp(icc_flip_strict(p), c, d); }
    if b >= 0 && d >= 0 && b == d && nw0 && nw1 { return ic_new_icmp(p, a, c); }
    if a >= 0 && c >= 0 && a == c && nw0 && nw1 { return ic_new_icmp(p, d, b); }
    if nw0 && pred_is_signed(p) {
        let x = m_neg(b0);
        if x >= 0 && is_constant(o1) && icc_is_not_min_signed_value(o1) {
            return ic_new_icmp(pred_swapped(p), x, ce_neg(o1));
        }
    }
    r = fold_icmp_xor_xx(i);
    if r >= 0 { return r; }
    r = fold_icmp_or_xx(i);
    if r >= 0 { return r; }
    {
        var x: i32 = -1; var y: i32 = -1; var z: i32 = -1;
        if bo(o0, OP_MUL) && bo(o1, OP_MUL) {
            for k in 2 {
                let xx = op(o0, k);
                let zz = op(o0, 1 - k);
                if op(o1, 0) == zz { x = xx; z = zz; y = op(o1, 1); break; }
                if op(o1, 1) == zz { x = xx; z = zz; y = op(o1, 0); break; }
            }
        }
        if z >= 0 {
            if pred_is_signed(p) {
                if nsw0 && nsw1 {
                    let zk = icc_kb(z, i);
                    if kb_is_nonneg(zk) && kb_is_nonzero(zk) { return ic_new_icmp(p, x, y); }
                    if kb_is_neg(zk) { return ic_new_icmp(pred_swapped(p), x, y); }
                    let lt = simplify_icmp(P_SLT, x, y, sq_at(i), RECURSION_LIMIT);
                    if lt >= 0 && m_one(lt) { return ic_new_icmp(pred_swapped(p), z, c_null(vals[z].ty)); }
                    let gt = simplify_icmp(P_SGT, x, y, sq_at(i), RECURSION_LIMIT);
                    if gt >= 0 && m_one(gt) { return ic_new_icmp(p, z, c_null(vals[z].ty)); }
                }
            } else {
                var nonzero = false;
                if icmp_is_equality(p) {
                    kb_cxt = i;
                    if ((nsw0 && nsw1) || (nuw0 && nuw1)) && is_known_non_equal(x, y, 0) { return ic_new_icmp(p, z, c_null(vals[z].ty)); }
                    let zk = icc_kb(z, i);
                    if kb_max_tz(zk) == 0 { return ic_new_icmp(p, x, y); }
                    nonzero = !ap_is_zero(zk.o) || icc_nonzero(z, i);
                    if nonzero && b0 >= 0 && b1 >= 0 && nsw0 && nsw1 { return ic_new_icmp(p, x, y); }
                } else { nonzero = icc_nonzero(z, i); }
                if nonzero && b0 >= 0 && b1 >= 0 && nuw0 && nuw1 { return ic_new_icmp(p, x, y); }
            }
        }
    }
    var srem: i32 = -1;
    if b0 >= 0 && iop(b0) == OP_SREM && o1 == op(b0, 1) { srem = b0; }
    else if b1 >= 0 && iop(b1) == OP_SREM && o0 == op(b1, 1) { srem = b1; }
    if srem >= 0 {
        let sp = if srem == b0 { pred_swapped(p) } else { p };
        if sp == P_EQ { return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, false)); }
        if sp == P_NE { return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, true)); }
        if sp == P_SGT || sp == P_SGE { return ic_new_icmp(P_SGT, op(srem, 1), c_all_ones(vals[srem].ty)); }
        if sp == P_SLT || sp == P_SLE { return ic_new_icmp(P_SLT, op(srem, 1), c_null(vals[srem].ty)); }
    }
    if b0 >= 0 && b1 >= 0 && iop(b0) == iop(b1) && (has_one_use(b0) || has_one_use(b1)) && op(b0, 1) == op(b1, 1) {
        let o = iop(b0);
        if o == OP_ADD || o == OP_SUB || o == OP_XOR {
            if icmp_is_equality(p) { return ic_new_icmp(p, op(b0, 0), op(b1, 0)); }
            if has_apint(op(b0, 1)) {
                let cc = ap_c(op(b0, 1));
                if ap_is_sign_mask(cc) { return ic_new_icmp(pred_flipped_signedness(p), op(b0, 0), op(b1, 0)); }
                if o == OP_XOR && ap_is_max_signed(cc) { return ic_new_icmp(pred_swapped(pred_flipped_signedness(p)), op(b0, 0), op(b1, 0)); }
            }
        } else if o == OP_MUL {
            if icmp_is_equality(p) && has_apint(op(b0, 1)) {
                let cc = ap_c(op(b0, 1));
                if !ap_is_zero(cc) && !ap_is_one(cc) {
                    let tz = ap_countr_zero(cc);
                    if tz != 0 {
                        let w = cc.w as i64;
                        let mask = c_int_ap(vals[b0].ty, ap_low_bits(w, w - tz));
                        let a1 = icb_and(op(b0, 0), mask, "");
                        let a2 = icb_and(op(b1, 0), mask, "");
                        return ic_new_icmp(p, a1, a2);
                    }
                }
            }
        } else if o == OP_UDIV || o == OP_LSHR {
            if !pred_is_signed(p) && op_exact(b0) && op_exact(b1) { return ic_new_icmp(p, op(b0, 0), op(b1, 0)); }
        } else if o == OP_SDIV {
            if (icmp_is_equality(p) || m_nonneg(op(b0, 1))) && op_exact(b0) && op_exact(b1) { return ic_new_icmp(p, op(b0, 0), op(b1, 0)); }
        } else if o == OP_ASHR {
            if op_exact(b0) && op_exact(b1) { return ic_new_icmp(p, op(b0, 0), op(b1, 0)); }
        } else if o == OP_SHL {
            let nuw = nuw0 && nuw1;
            let nsw = nsw0 && nsw1;
            if (nuw || nsw) && !(!nsw && pred_is_signed(p)) { return ic_new_icmp(p, op(b0, 0), op(b1, 0)); }
        }
    }
    if b0 >= 0 && p == P_ULT && bo(b0, OP_AND) {
        for k in 2 {
            let s = op(b0, k);
            if bo(s, OP_ADD) && op(s, 0) == o1 && m_all_ones(op(s, 1)) { return ic_new_icmp(P_NE, o1, c_null(vals[b0].ty)); }
        }
    }
    if !pred_is_signed(p) {
        if bo(o0, OP_SHL) && op(o0, 0) == o1 && m_one(op(o0, 1)) { return ic_new_icmp(pred_signed(p), o1, c_null(vals[o1].ty)); }
        if bo(o1, OP_SHL) && op(o1, 0) == o0 && m_one(op(o1, 1)) { return ic_new_icmp(pred_signed(p), c_null(vals[o0].ty), o0); }
    }
    let v = fold_multiplication_overflow_check(i);
    if v >= 0 { return ic_replace_inst_uses_with(i, v); }
    r = fold_icmp_and_xx(i);
    if r >= 0 { return r; }
    let v2 = fold_icmp_with_trunc_sign_extended_val(i);
    if v2 >= 0 { return ic_replace_inst_uses_with(i, v2); }
    let v3 = fold_shift_into_shift_in_another_hand_of_and_in_icmp(i);
    if v3 >= 0 { return ic_replace_inst_uses_with(i, v3); }
    return -1;
}
// Constant::isNotMinSignedValue
fn icc_is_not_min_signed_value(c: i32) -> bool { is_not_min_signed_value(c) }

// m_SpecificIntAllowPoison(const APInt &)
fn icc_specific_int_poison(v: i32, x: AP) -> bool {
    let c = m_apint_ap(v, true);
    if c < 0 { return false; }
    return ap_same_value_u(ci_ap(c), x);
}

// MinMaxIntrinsic::getPredicate / isSigned / isMin
fn icc_minmax_pred(id: i32) -> i64 {
    if id == IID_smax { return P_SGT; }
    if id == IID_smin { return P_SLT; }
    if id == IID_umax { return P_UGT; }
    return P_ULT;
}
fn icc_minmax_signed(id: i32) -> bool { id == IID_smax || id == IID_smin }
// the IsCondKnownTrue lambda: 1 true, 0 false, -1 unknown
fn icc_known_true(v: i32) -> i64 {
    if v < 0 { return -1; }
    if m_one(v) { return 1; }
    if m_zero(v) { return 0; }
    return -1;
}

// foldICmpWithMinMax(I, MinMax, Z, Pred)
fn fold_icmp_with_minmax(i: i32, mm: i32, z: i32, p0: i64) -> i32 {
    var x = op(mm, 0);
    var y = op(mm, 1);
    let id = inst_iid(mm);
    var p = cp_pred(p0);
    if pred_is_signed(p) && !icc_minmax_signed(id) { return -1; }
    if pred_is_unsigned(p) && icc_minmax_signed(id) {
        if icc_known_nonneg(z, i) && icc_known_nonneg(mm, i) { p = pred_flipped_signedness(p); }
        else { return -1; }
    }
    var cxz = icc_known_true(simplify_icmp(p, x, z, sq_at(i), RECURSION_LIMIT));
    var cyz = icc_known_true(simplify_icmp(p, y, z, sq_at(i), RECURSION_LIMIT));
    if cxz < 0 && cyz < 0 { return -1; }
    if cxz < 0 { let t = x; x = y; y = t; let u = cxz; cxz = cyz; cyz = u; }
    let mp = icc_minmax_pred(id);
    if p == P_EQ || p == P_NE {
        if (p == P_EQ) == (cxz == 1) {
            var np = pred_nonstrict(mp);
            if p == P_NE { np = pred_inverse(np); }
            return ic_new_icmp(np, x, y);
        }
        var mxz = icc_known_true(simplify_icmp(mp, x, z, sq_at(i), RECURSION_LIMIT));
        if mxz < 0 {
            let t = x; x = y; y = t; let u = cxz; cxz = cyz; cyz = u;
            if cxz < 0 || (p == P_EQ) == (cxz == 1) { return -1; }
            mxz = icc_known_true(simplify_icmp(mp, x, z, sq_at(i), RECURSION_LIMIT));
        }
        if mxz < 0 { return -1; }
        if mxz == 1 { return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, p == P_NE)); }
        return icc_fold_into_cmp_yz(i, p, y, z, cyz);
    }
    if pred_relational(p) {
        let same = mp == pred_strict(p);
        if cxz == 1 {
            if same { return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, true)); }
            return icc_fold_into_cmp_yz(i, p, y, z, cyz);
        }
        if same { return icc_fold_into_cmp_yz(i, p, y, z, cyz); }
        return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, false));
    }
    return -1;
}
fn icc_fold_into_cmp_yz(i: i32, p: i64, y: i32, z: i32, cyz: i64) -> i32 {
    if cyz >= 0 { return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, cyz == 1)); }
    return ic_new_icmp(p, y, z);
}

// foldICmpWithClamp(I, X, Min)
fn fold_icmp_with_clamp(i: i32, x0: i32, mn: i32) -> i32 {
    let id = inst_iid(mn);
    if !icmp_is_equality(icc_pred(i)) || !has_one_use(mn) || !(id == IID_smin || id == IID_umin) { return -1; }
    let l = op(mn, 0);
    let r = op(mn, 1);
    let maxid = if id == IID_smin { IID_smax } else { IID_umax };
    if !one_use(l) || inst_iid(l) != maxid || op(l, 0) != x0 || !has_apint(op(l, 1)) || !has_apint(r) { return -1; }
    let lo = ap_c(op(l, 1));
    let hi = ap_c(r);
    if id == IID_smin { if !ap_slt(lo, hi) { return -1; } } else { if !ap_ult(lo, hi) { return -1; } }
    var cr = rg_nonempty(lo, ap_inc(hi));
    if icc_pred(i) != P_EQ { cr = rg_inverse(cr); }
    let p, c, off = rg_equivalent_icmp_off(cr);
    var x = x0;
    if !ap_is_zero(off) { x = icb_add(x, c_int_ap(vals[x].ty, off), ""); }
    return ic_replace_inst_uses_with(i, icb_icmp(p, x, c_int_ap(vals[x].ty, c), ""));
}

// foldICmpPow2Test(I, Builder)
fn fold_icmp_pow2_test(i: i32) -> i32 {
    let o0 = op(i, 0);
    let o1 = op(i, 1);
    let p = icc_pred(i);
    var a: i32 = -1;
    var check = false;
    if icmp_is_equality(p) {
        if one_use(o0) && bo(o0, OP_AND) && m_zero_int(o1) {
            for k in 2 {
                let ad = op(o0, k);
                if bo(ad, OP_ADD) && m_all_ones(op(ad, 1)) && op(o0, 1 - k) == op(ad, 0) { a = op(ad, 0); break; }
            }
        }
        if one_use(o0) && bo(o0, OP_AND) && ((m_neg(op(o0, 0)) == o1 && op(o0, 1) == o1) || (m_neg(op(o0, 1)) == o1 && op(o0, 0) == o1)) { a = o1; }
        else if one_use(o1) && bo(o1, OP_AND) && ((m_neg(op(o1, 0)) == o0 && op(o1, 1) == o0) || (m_neg(op(o1, 1)) == o0 && op(o1, 0) == o0)) { a = o0; }
        check = p == P_EQ;
    } else if pred_is_unsigned(p) {
        if (p == P_UGE || p == P_ULT) && one_use(o0) && bo(o0, OP_XOR) && icc_xor_dec_of(o0, o1) {
            a = o1; check = p == P_UGE;
        } else if (p == P_UGT || p == P_ULE) && one_use(o1) && bo(o1, OP_XOR) && icc_xor_dec_of(o1, o0) {
            a = o0; check = p == P_ULE;
        }
    }
    if a >= 0 {
        let ty = vals[a].ty;
        let cp_ = icb_unary_intrinsic(IID_ctpop, a, "");
        if check { return ic_new_icmp(P_ULT, cp_, c_int_ty(ty, 2)); }
        return ic_new_icmp(P_UGT, cp_, c_int_ty(ty, 1));
    }
    return -1;
}
// m_c_Xor(m_Add(m_Specific(A), m_AllOnes()), m_Specific(A))
fn icc_xor_dec_of(x: i32, a: i32) -> bool {
    for k in 2 {
        let ad = op(x, k);
        if bo(ad, OP_ADD) && op(ad, 0) == a && m_all_ones(op(ad, 1)) && op(x, 1 - k) == a { return true; }
    }
    return false;
}

// collectOffsetOp(V, Offsets, AllowRecursion): pairs (opcode, RHS) on two parallel stacks
fn collect_offset_op(v: i32, ops: i64[>..<]&, rhs: i32[>..<]&, allow_rec: bool) {
    if !is_inst(v) || !has_one_use(v) { return; }
    let o = iop(v);
    if o == OP_ADD { ops.push(OP_SUB); rhs.push(op(v, 1)); ops.push(OP_SUB); rhs.push(op(v, 0)); }
    else if o == OP_SUB { ops.push(OP_ADD); rhs.push(op(v, 1)); }
    else if o == OP_XOR { ops.push(OP_XOR); rhs.push(op(v, 1)); ops.push(OP_XOR); rhs.push(op(v, 0)); }
    else if o == OP_SHL {
        if op_nsw(v) { ops.push(OP_ASHR); rhs.push(op(v, 1)); }
        if op_nuw(v) { ops.push(OP_LSHR); rhs.push(op(v, 1)); }
    } else if o == OP_SELECT {
        if allow_rec {
            collect_offset_op_leaf(op(v, 1), ops, rhs);
            collect_offset_op_leaf(op(v, 2), ops, rhs);
        }
    }
}
// collectOffsetOp(V, Offsets, /*AllowRecursion=*/false)
fn collect_offset_op_leaf(v: i32, ops: i64[>..<]&, rhs: i32[>..<]&) {
    if !is_inst(v) || !has_one_use(v) { return; }
    let o = iop(v);
    if o == OP_ADD { ops.push(OP_SUB); rhs.push(op(v, 1)); ops.push(OP_SUB); rhs.push(op(v, 0)); }
    else if o == OP_SUB { ops.push(OP_ADD); rhs.push(op(v, 1)); }
    else if o == OP_XOR { ops.push(OP_XOR); rhs.push(op(v, 1)); ops.push(OP_XOR); rhs.push(op(v, 0)); }
    else if o == OP_SHL {
        if op_nsw(v) { ops.push(OP_ASHR); rhs.push(op(v, 1)); }
        if op_nuw(v) { ops.push(OP_LSHR); rhs.push(op(v, 1)); }
    }
}
// the ApplyOffsetImpl lambda
fn icc_apply_offset_impl(v: i32, opc: i64, rhs: i32, cx: i32) -> i32 {
    if opc == OP_ASHR {
        var okc = false;
        if has_apint(v) && has_apint(rhs) { let cv = ap_c(v); let cr = ap_c(rhs); okc = ap_eq(ap_shl_ap(ap_ashr_ap(cv, cr), cr), cv); }
        if !okc && !(bo(v, OP_SHL) && op_nsw(v) && op(v, 1) == rhs) { return -1; }
    } else if opc == OP_LSHR {
        var okc = false;
        if has_apint(v) && has_apint(rhs) { let cv = ap_c(v); let cr = ap_c(rhs); okc = ap_eq(ap_shl_ap(ap_lshr_ap(cv, cr), cr), cv); }
        if !okc && !(bo(v, OP_SHL) && op_nuw(v) && op(v, 1) == rhs) { return -1; }
    }
    let s = simplify_binop(opc, v, rhs, sq_at(cx), RECURSION_LIMIT);
    if s < 0 { return -1; }
    if is_constant(s) && !m_imm_constant(s) { return -1; }
    return if implies_poison(rhs, v) { s } else { -1 };
}
// the ApplyOffset lambda: kind (0 invalid, 1 value, 2 select), v0, v1, v2
fn icc_apply_offset(v: i32, opc: i64, rhs: i32, cx: i32) -> i64, i32, i32, i32 {
    if is_select_inst(v) {
        if !has_one_use(v) { return 0, -1, -1, -1; }
        let t = icc_apply_offset_impl(op(v, 1), opc, rhs, cx);
        if t < 0 { return 0, -1, -1, -1; }
        let f = icc_apply_offset_impl(op(v, 2), opc, rhs, cx);
        if f < 0 { return 0, -1, -1, -1; }
        return 2, op(v, 0), t, f;
    }
    let s = icc_apply_offset_impl(v, opc, rhs, cx);
    if s >= 0 { return 1, s, -1, -1; }
    return 0, -1, -1, -1;
}

// foldICmpEqualityWithOffset(I, Builder, SQ)
fn fold_icmp_equality_with_offset(i: i32) -> i32 {
    let o0 = op(i, 0);
    let o1 = op(i, 1);
    if !is_int_or_int_vec(vals[o0].ty) { return -1; }
    var ops: i64[>..<] = [];
    var rhs: i32[>..<] = [];
    collect_offset_op(o0, ops, rhs, true);
    collect_offset_op(o1, ops, rhs, true);
    for k in ops.len {
        let opc = ops[k];
        let r = rhs[k];
        let k0, a0, a1, a2 = icc_apply_offset(o0, opc, r, i);
        if k0 == 0 { continue; }
        let k1, b0, b1, b2 = icc_apply_offset(o1, opc, r, i);
        if k1 == 0 { continue; }
        let nl = if k0 == 1 { a0 } else { icb_select(a0, a1, a2, "", o0) };
        let nr = if k1 == 1 { b0 } else { icb_select(b0, b1, b2, "", o1) };
        return ic_new_icmp(icc_pred(i), nl, nr);
    }
    return -1;
}

// the m_Matcher of foldICmpEquality's P2 fold on W with A deferred: B or -1
fn icc_p2_matcher(w: i32, a: i32) -> i32 {
    if bo(w, OP_ADD) || bo(w, OP_XOR) {
        if op(w, 1) == a { return op(w, 0); }
        if op(w, 0) == a { return op(w, 1); }
    }
    if bo(w, OP_SUB) && op(w, 1) == a { return op(w, 0); }
    return -1;
}
// m_OneUse(m_c_And(m_Value(A), m_Matcher)): A, B (first successful binding) or -1
fn icc_p2_and(v: i32) -> i32, i32 {
    if !one_use(v) || !bo(v, OP_AND) { return -1, -1; }
    for k in 2 {
        let a = op(v, k);
        let b = icc_p2_matcher(op(v, 1 - k), a);
        if b >= 0 { return a, b; }
    }
    return -1, -1;
}

// foldICmpEquality(I)
fn fold_icmp_equality(i: i32) -> i32 {
    let p = icc_pred(i);
    if !icmp_is_equality(p) { return -1; }
    let o0 = op(i, 0);
    let o1 = op(i, 1);
    if bo(o0, OP_XOR) {
        let a = op(o0, 0);
        let b = op(o0, 1);
        if a == o1 || b == o1 {
            let other = if a == o1 { b } else { a };
            return ic_new_icmp(p, other, c_null(vals[a].ty));
        }
        if bo(o1, OP_XOR) {
            let c = op(o1, 0);
            let d = op(o1, 1);
            let c1 = m_constant_int(b);
            let c2 = m_constant_int(d);
            if c1 >= 0 && c2 >= 0 && has_one_use(o1) {
                let x1 = ci_ap(c1);
                let nc = c_int_ap(ty_int(x1.w as i64), ap_xor(x1, ci_ap(c2)));
                let xo = icb_xor(c, nc, "");
                return ic_new_icmp(p, a, xo);
            }
            if a == c { return ic_new_icmp(p, b, d); }
            if a == d { return ic_new_icmp(p, b, c); }
            if b == c { return ic_new_icmp(p, a, d); }
            if b == d { return ic_new_icmp(p, a, c); }
        }
    }
    if bo(o1, OP_XOR) && (op(o1, 0) == o0 || op(o1, 1) == o0) {
        let a = op(o1, 0);
        let other = if a == o0 { op(o1, 1) } else { a };
        return ic_new_icmp(p, other, c_null(vals[a].ty));
    }
    if bo(o0, OP_AND) && bo(o1, OP_AND) {
        let a = op(o0, 0); let b = op(o0, 1);
        let c = op(o1, 0); let d = op(o1, 1);
        var x: i32 = -1; var y: i32 = -1; var z: i32 = -1;
        if a == c { x = b; y = d; z = a; }
        else if a == d { x = b; y = c; z = a; }
        else if b == c { x = a; y = d; z = b; }
        else if b == d { x = a; y = c; z = b; }
        if x >= 0 {
            let negp2 = has_apint(x) && has_apint(y) && ap_is_neg_pow2(ap_xor(ap_c(x), ap_c(y)));
            let cnt = icc_bool(has_one_use(o0)) + icc_bool(has_one_use(o1)) + icc_bool(m_imm_constant(x) && m_imm_constant(y));
            if negp2 || cnt >= 2 {
                let xo = icb_xor(x, y, "");
                let an = icb_and(xo, z, "");
                return ic_new_icmp(p, an, c_null(vals[an].ty));
            }
        }
    }
    if one_use(o0) && bo(o0, OP_OR) && is_constant(op(o0, 1)) && one_use(o1) && bo(o1, OP_OR) && op(o1, 1) == op(o0, 1) {
        let xo = icb_xor(op(o0, 0), op(o1, 0), "");
        let an = icb_and(xo, ce_not(op(o0, 1)), "");
        return ic_new_icmp(p, an, c_null(vals[an].ty));
    }
    let za = m_zext(o1);
    if za >= 0 && (has_one_use(o0) || has_one_use(o1)) {
        if bo(o0, OP_AND) && m_low_bit_mask(op(o0, 1)) && has_apint_poison(op(o0, 1)) && ap_countr_one(ap_cp(op(o0, 1))) == ty_sbits(za) {
            return ic_new_icmp(p, za, icb_trunc(op(o0, 0), vals[za].ty, ""));
        }
    }
    let shr_l = one_use(o0) && bo(o0, OP_LSHR) && has_apint_poison(op(o0, 1)) && one_use(o1) && bo(o1, OP_LSHR) && has_apint_poison(op(o1, 1));
    let shr_a = one_use(o0) && bo(o0, OP_ASHR) && has_apint_poison(op(o0, 1)) && one_use(o1) && bo(o1, OP_ASHR) && has_apint_poison(op(o1, 1));
    if shr_l || shr_a {
        let ap1 = ap_cp(op(o0, 1));
        let ap2 = ap_cp(op(o1, 1));
        if !ap_eq(ap1, ap2) { return -1; }
        let tb = ap1.w as i64;
        let sa = ap_limited(ap1, tb as u64) as i64;
        if sa < tb && sa != 0 {
            var nm: u8[>..] = [];
            nm.append(val_name(i)); nm.append(".unshifted");
            let a = op(o0, 0);
            let xo = icb_xor(a, op(o1, 0), nm);
            return ic_new_icmp(if p == P_NE { P_UGE } else { P_ULT }, xo, c_int_ap(vals[a].ty, ap_one_bit(tb, sa)));
        }
    }
    if one_use(o0) && bo(o0, OP_SHL) && m_constant_int(op(o0, 1)) >= 0 && one_use(o1) && bo(o1, OP_SHL) && op(o1, 1) == op(o0, 1) {
        let c1 = ci_ap(op(o0, 1));
        let tb = c1.w as i64;
        let sa = ap_limited(c1, tb as u64) as i64;
        if sa < tb && sa != 0 {
            var nm: u8[>..] = [];
            nm.append(val_name(i)); nm.append(".unshifted");
            let xo = icb_xor(op(o0, 0), op(o1, 0), nm);
            var nm2: u8[>..] = [];
            nm2.append(val_name(i)); nm2.append(".mask");
            let an = icb_and(xo, c_int_ap(ty_int(tb), ap_low_bits(tb, tb - sa)), nm2);
            return ic_new_icmp(p, an, c_null(vals[op(o0, 1)].ty));
        }
    }
    if has_one_use(o0) && is_inst_op(o0, OP_TRUNC) {
        let l = op(o0, 0);
        if one_use(l) && bo(l, OP_LSHR) && icc_m_cint_u64(op(l, 1)) && m_constant_int(o1) >= 0 && !has_one_use(op(l, 0)) {
            let a = op(l, 0);
            let sa = ap_zext64(ap_c(op(l, 1)));
            let asz = ty_bits(vals[a].ty);
            if sa < (asz as u64) {
                let mv = ap_shl(ap_low_bits(asz, ty_bits(vals[o0].ty)), sa as i64);
                let cv = ap_shl(ap_zext(ci_ap(o1), asz), sa as i64);
                let m = icb_and(a, c_int_ap(ty_int(asz), mv), "");
                return ic_new_icmp(p, m, c_int_ap(ty_int(asz), cv));
            }
        }
    }
    var r = fold_icmp_intrinsic_with_intrinsic(i);
    if r >= 0 { return r; }
    let bw = ty_sbits(o0);
    if bo(o0, OP_ASHR) && is_inst_op(op(o0, 0), OP_TRUNC) && m_specific_int(op(o0, 1), (bw - 1) as u64) {
        let a = op(op(o0, 0), 0);
        if is_inst_op(o1, OP_TRUNC) && bo(op(o1, 0), OP_LSHR) && op(op(o1, 0), 0) == a && m_specific_int(op(op(o1, 0), 1), bw as u64) &&
           ty_sbits(a) == bw * 2 && (has_one_use(o0) || has_one_use(o1)) {
            let c = ap_one_bit(bw * 2, bw - 1);
            let add = icb_add(a, c_int_ap(vals[a].ty, c), "");
            return ic_new_icmp(if p == P_EQ { P_ULT } else { P_UGE }, add, c_int_ap(vals[a].ty, ap_shl(c, 1)));
        }
    }
    if bo(o0, OP_AND) && (op(o0, 0) == o1 || op(o0, 1) == o1) && icc_pow2(o1, false, i) {
        return ic_new_icmp(pred_inverse(p), o0, c_null(vals[o0].ty));
    }
    if bo(o1, OP_AND) && (op(o1, 0) == o0 || op(o1, 1) == o0) && icc_pow2(o0, false, i) {
        return ic_new_icmp(pred_inverse(p), o1, c_null(vals[o1].ty));
    }
    for k in 2 {
        let a = op(i, k);
        let f = op(i, 1 - k);
        if one_use(f) && inst_iid(f) == IID_fshr && op(f, 0) == a && op(f, 1) == a {
            let b = op(f, 2);
            return ic_new_icmp(p, a, icb_intrinsic(IID_fshl, [vals[o0].ty as i32], [a, a, b], ""));
        }
    }
    for k in 2 {
        let x = op(i, k);
        let b = op(i, 1 - k);
        if one_use(x) && bo(x, OP_XOR) && m_imm_constant(op(x, 1)) && !m_imm_constant(b) {
            let a = op(x, 0);
            return ic_new_icmp(p, icb_xor(a, b, ""), op(x, 1));
        }
    }
    {
        var a: i32 = -1;
        var b: i32 = -1;
        var is_zero = -1;
        for k in 2 {
            let aa, bb = icc_p2_and(op(i, k));
            if aa >= 0 && op(i, 1 - k) == aa { a = aa; b = bb; is_zero = 0; break; }
        }
        if is_zero < 0 {
            let aa, bb = icc_p2_and(o0);
            if aa >= 0 && m_zero(o1) { a = aa; b = bb; is_zero = 1; }
        }
        if is_zero >= 0 && icc_pow2(a, true, i) {
            return ic_new_icmp(p, icb_and(b, a, ""), if is_zero == 1 { a } else { c_null(vals[a].ty) });
        }
    }
    r = fold_icmp_equality_with_offset(i);
    if r >= 0 { return r; }
    return -1;
}

// decomposeBitTestICmp(LHS, RHS, Pred, LookThroughTrunc, AllowNonZeroC, DecomposeAnd) (CmpInstAnalysis.cpp):
// ok, X, Mask, C, Pred
fn icc_decompose_bit_test_icmp(lhs0: i32, rhs: i32, p0: i64, look_trunc: bool, allow_nonzero_c: bool, decompose_and: bool) -> bool, i32, AP, AP, i64 {
    let z = ap_zero(1);
    var p = p0;
    var lhs = lhs0;
    if (icmp_is_equality(p) && !decompose_and) || !has_apint_poison(rhs) { return false, -1, z, z, 0; }
    var inverted = false;
    if icc_is_gt(p) || icc_is_ge(p) { inverted = true; p = pred_inverse(p); }
    var c = ap_cp(rhs);
    let w = c.w as i64;
    if icc_is_le(p) {
        if if pred_is_signed(p) { ap_is_max_signed(c) } else { ap_is_all_ones(c) } { return false, -1, z, z, 0; }
        c = ap_inc(c);
        p = pred_strict(p);
    }
    var mask = ap_zero(w);
    var rc = ap_zero(w);
    var rp: i64 = 0;
    if p == P_SLT {
        if ap_is_zero(c) { mask = ap_sign_mask(w); rp = P_NE; }
        else {
            let fs = ap_xor(c, ap_sign_mask(w));
            if ap_is_pow2(fs) { mask = ap_neg(fs); rc = ap_sign_mask(w); rp = P_EQ; }
            else if ap_is_neg_pow2(fs) { mask = fs; rc = c; rp = P_NE; }
            else { return false, -1, z, z, 0; }
        }
    } else if p == P_ULT {
        if ap_is_pow2(c) { mask = ap_neg(c); rp = P_EQ; }
        else if ap_is_neg_pow2(c) { mask = c; rc = c; rp = P_NE; }
        else { return false, -1, z, z, 0; }
    } else {
        if bo(lhs, OP_AND) && has_apint_poison(op(lhs, 1)) {
            mask = ap_cp(op(lhs, 1));
            lhs = op(lhs, 0);
            rc = c; rp = p;
        } else if look_trunc && is_inst_op(lhs, OP_TRUNC) {
            rp = p; mask = ap_ones(w); rc = c;
        } else { return false, -1, z, z, 0; }
    }
    if !allow_nonzero_c && !ap_is_zero(rc) { return false, -1, z, z, 0; }
    if inverted { rp = pred_inverse(rp); }
    var x = lhs;
    if look_trunc && is_inst_op(lhs, OP_TRUNC) {
        x = op(lhs, 0);
        let xw = ty_sbits(x);
        mask = ap_zext(mask, xw);
        rc = ap_zext(rc, xw);
    }
    return true, x, mask, rc, rp;
}

// foldICmpWithTrunc(ICmp)
fn fold_icmp_with_trunc(cmp: i32) -> i32 {
    let p = icc_pred(cmp);
    let o0 = op(cmp, 0);
    let o1 = op(cmp, 1);
    if !one_use(o0) || !is_inst_op(o0, OP_TRUNC) || !has_apint(o1) { return -1; }
    let x = op(o0, 0);
    let c = ap_c(o1);
    let ok, rx, rm, rc, rp = icc_decompose_bit_test_icmp(o0, o1, p, true, true, false);
    if ok {
        let a = icb_and(rx, c_int_ap(vals[rx].ty, rm), "");
        return ic_new_icmp(rp, a, c_int_ap(vals[rx].ty, rc));
    }
    let sb = ty_sbits(x);
    let id = inst_iid(x);
    if id == IID_cttz || id == IID_ctlz {
        var maxret = sb;
        if m_one(op(x, 1)) { maxret--; }
        if icc_log2_32(maxret) + 1 <= ty_sbits(o0) {
            let r = fold_icmp_intrinsic_with_constant(cmp, x, ap_zext(c, sb));
            if r >= 0 { return r; }
        }
    }
    return -1;
}
// Log2_32 (floor; -1 for 0, as unsigned wraps to UINT_MAX in LLVM, which makes the check fail)
fn icc_log2_32(x: i64) -> i64 {
    if x <= 0 { return 4294967295; }
    var r: i64 = 0;
    var v = x;
    while v > 1 { v >>= 1; r++; }
    return r;
}

// foldICmpWithZextOrSext(ICmp)
fn fold_icmp_with_zext_or_sext(cmp: i32) -> i32 {
    let c0 = op(cmp, 0);
    if !is_inst_op(c0, OP_ZEXT) && !is_inst_op(c0, OP_SEXT) { return -1; }
    var x = op(c0, 0);
    var sext = iop(c0) == OP_SEXT;
    let p = icc_pred(cmp);
    let scmp = pred_is_signed(p);
    let o1 = op(cmp, 1);
    if is_inst_op(o1, OP_ZEXT) || is_inst_op(o1, OP_SEXT) {
        var y = op(o1, 0);
        let z0 = iop(c0) == OP_ZEXT;
        let z1 = iop(o1) == OP_ZEXT;
        if z0 != z1 {
            if icmp_is_equality(p) && is_int_ty1(vals[x].ty) && is_int_ty1(vals[y].ty) {
                return ic_new_icmp(p, icb_or(x, y, ""), c_null(vals[x].ty));
            }
            let nn0 = icc_nneg(c0);
            let nn1 = icc_nneg(o1);
            if (z0 && nn0) || (z1 && nn1) { sext = true; } else { return -1; }
        }
        let xty = vals[x].ty;
        let yty = vals[y].ty;
        if xty != yty {
            if !has_one_use(c0) && !has_one_use(o1) { return -1; }
            let co = if sext { OP_SEXT } else { OP_ZEXT };
            if ty_scalar_bits(xty) < ty_scalar_bits(yty) { x = icb_cast(co, x, yty, ""); }
            else if ty_scalar_bits(yty) < ty_scalar_bits(xty) { y = icb_cast(co, y, xty, ""); }
            else { return -1; }
        }
        if icmp_is_equality(p) { return ic_new_icmp(p, x, y); }
        if scmp && sext { return ic_new_icmp(p, x, y); }
        return ic_new_icmp(pred_unsigned(p), x, y);
    }
    if !is_constant(o1) { return -1; }
    let sty = vals[x].ty;
    let res = get_lossless_inv_cast(o1, sty, iop(c0));
    if res >= 0 {
        if icmp_is_equality(p) { return ic_new_icmp(p, x, res); }
        if sext && scmp { return ic_new_icmp(p, x, res); }
        return ic_new_icmp(pred_unsigned(p), x, res);
    }
    if scmp || !sext || vals[o1].kind != VK_CINT { return -1; }
    if p == P_ULT { return ic_new_icmp(P_SGT, x, c_all_ones(sty)); }
    return ic_new_icmp(P_SLT, x, c_null(sty));
}

// simplifyIntToPtrRoundTripCast(Val)
fn simplify_int_to_ptr_round_trip_cast(v: i32) -> i32 {
    if !is_inst_op(v, OP_INTTOPTR) { return -1; }
    let src = op(v, 0);
    if dl_size_bits(vals[v].ty) != dl_size_bits(vals[src].ty) { return -1; }
    if !is_inst_op(src, OP_PTRTOINT) { return -1; }
    let p = op(src, 0);
    if ptr_as(vals[v].ty) == ptr_as(vals[p].ty) && dl_size_bits(vals[p].ty) == dl_size_bits(vals[src].ty) { return p; }
    return -1;
}

// foldICmpWithCastOp(ICmp)
fn fold_icmp_with_cast_op(cmp: i32) -> i32 {
    let s0 = simplify_int_to_ptr_round_trip_cast(op(cmp, 0));
    let s1 = simplify_int_to_ptr_round_trip_cast(op(cmp, 1));
    if s0 >= 0 || s1 >= 0 {
        return ic_new_icmp(icc_pred(cmp), if s0 >= 0 { s0 } else { op(cmp, 0) }, if s1 >= 0 { s1 } else { op(cmp, 1) });
    }
    let c0 = op(cmp, 0);
    if !is_cast_inst(c0) { return -1; }
    let o1 = op(cmp, 1);
    if !is_constant(o1) && !is_cast_inst(o1) { return -1; }
    let src = op(c0, 0);
    let sty = vals[src].ty;
    let dty = vals[c0].ty;
    if iop(c0) == OP_PTRTOINT && icc_compatible_sizes(sty, dty) {
        var n1: i32 = -1;
        if is_op(o1, OP_PTRTOINT) {
            if vals[op(o1, 0)].ty == vals[src].ty { n1 = op(o1, 0); }
        } else if is_constant(o1) {
            n1 = ce_cast(OP_INTTOPTR, o1, sty);
        }
        if n1 >= 0 { return ic_new_icmp(icc_pred(cmp), src, n1); }
    }
    if iop(c0) == OP_INTTOPTR && icc_compatible_sizes(dty, sty) {
        var n1: i32 = -1;
        if is_inst_op(o1, OP_INTTOPTR) {
            if vals[op(o1, 0)].ty == vals[src].ty { n1 = op(o1, 0); }
        } else if is_constant(o1) {
            n1 = cf_fold_constant(ce_cast(OP_PTRTOINT, o1, sty));
        }
        if n1 >= 0 { return ic_new_icmp(icc_pred(cmp), src, n1); }
    }
    let r = fold_icmp_with_trunc(cmp);
    if r >= 0 { return r; }
    return fold_icmp_with_zext_or_sext(cmp);
}
// the CompatibleSizes lambda
fn icc_compatible_sizes(pt: i32, it: i32) -> bool {
    return dl_ptr(ptr_as(ty_scalar(pt))).bits == ty_bits(ty_scalar(it));
}

// isNeutralValue(BinaryOp, RHS, IsSigned)
fn is_neutral_value(o: i64, rhs: i32, signed: bool) -> bool {
    if o == OP_ADD || o == OP_SUB { return m_zero(rhs); }
    return !(is_int_ty1(vals[rhs].ty) && signed) && m_one(rhs);
}

// computeOverflow(BinaryOp, IsSigned, LHS, RHS, CxtI)
fn compute_overflow(o: i64, signed: bool, l: i32, r: i32, cx: i32) -> i64 {
    if o == OP_ADD { return if signed { ovf_signed_add(l, r, cx) } else { ovf_unsigned_add(l, r, cx) }; }
    if o == OP_SUB { return if signed { ovf_signed_sub(l, r, cx) } else { ovf_unsigned_sub(l, r, cx) }; }
    return if signed { ovf_signed_mul(l, r, cx) } else { ovf_unsigned_mul(l, r, cx, false) };
}

// OptimizeOverflowCheck(BinaryOp, IsSigned, LHS, RHS, OrigI, Result, Overflow): ok, result, overflow
fn optimize_overflow_check(o: i64, signed: bool, l0: i32, r0: i32, orig: i32) -> bool, i32, i32 {
    var l = l0;
    var r = r0;
    let commut = o == OP_ADD || o == OP_MUL;
    if commut && is_constant(l) && !is_constant(r) { let t = l; l = r; r = t; }
    icb_set_insert_point(orig);
    let oty = ty_with_elem(vals[l].ty, T_I1);
    if is_neutral_value(o, r, signed) { return true, l, c_bool_ty(oty, false); }
    let res = compute_overflow(o, signed, l, r, orig);
    if res == OF_MAY { return false, -1, -1; }
    let b = icb_binop(o, l, r, "");
    ic_take_name(b, orig);
    if res == OF_LOW || res == OF_HIGH { return true, b, c_bool_ty(oty, true); }
    if is_inst(b) { if signed { set_nsw(b, true); } else { set_nuw(b, true); } }
    return true, b, c_bool_ty(oty, false);
}

// processUMulZExtIdiom(I, MulVal, OtherVal, IC)
fn process_umul_zext_idiom(i: i32, mv: i32, other: AP) -> i32 {
    if !ty_is_int(vals[mv].ty) || !is_inst(mv) { return -1; }
    let a = op(op(mv, 0), 0);
    let b = op(op(mv, 1), 0);
    let ta = vals[a].ty;
    let tb = vals[b].ty;
    let wa = ty_bits(ta);
    let wb = ty_bits(tb);
    var mw = wa;
    var mty: i32 = ta;
    if wb > wa { mw = wb; mty = tb; }
    if has_n_uses_or_more(mv, 2) {
        var u = vals[mv].first_use;
        while u >= 0 {
            let us = uses[u].user;
            u = uses[u].next;
            if us == i { continue; }
            if is_inst_op(us, OP_TRUNC) {
                if ty_bits(vals[us].ty) > mw { return -1; }
            } else if is_binop_inst(us) {
                if iop(us) != OP_AND { return -1; }
                let ci = op(us, 1);
                if vals[ci].kind == VK_CINT && !ty_is_vector(vals[ci].ty) {
                    let cv = ci_ap(ci);
                    if (cv.w as i64) - ap_countl_zero(cv) > mw { return -1; }
                } else { return -1; }
            } else { return -1; }
        }
    }
    let p = icc_pred(i);
    if p == P_UGT {
        let mx = ap_zext(ap_ones(mw), other.w as i64);
        if !ap_eq(mx, other) { return -1; }
    } else if p == P_ULT {
        let mx = ap_one_bit(other.w as i64, mw);
        if !ap_eq(mx, other) { return -1; }
    } else { return -1; }
    icb_set_insert_point(mv);
    var ma = a;
    var mb = b;
    if wa < mw { ma = icb_zext(a, mty, ""); }
    if wb < mw { mb = icb_zext(b, mty, ""); }
    let call = icb_intrinsic(IID_umul_with_overflow, [mty], [ma, mb], "umul");
    icw_add(mv);
    if has_n_uses_or_more(mv, 2) {
        let mul = icb_extractvalue(call, 0, "umul.value");
        var u = vals[mv].first_use;
        while u >= 0 {
            let us = uses[u].user;
            u = uses[u].next;
            if us == i { continue; }
            if is_inst_op(us, OP_TRUNC) {
                if ty_bits(vals[us].ty) == mw { ic_replace_inst_uses_with(us, mul); }
                else { set_op(us, 0, mul); }
            } else {
                let sm = ap_trunc(ci_ap(op(us, 1)), mw);
                let sa = icb_and(mul, c_int_ap(vals[mul].ty, sm), "");
                let zx = icb_zext(sa, vals[us].ty, "");
                ic_replace_inst_uses_with(us, zx);
            }
            icw_add(us);
        }
    }
    if p == P_ULT {
        let res = icb_extractvalue(call, 1, "");
        return ic_new_not(res);
    }
    return icc_new_extractvalue(call, 1);
}

// getDemandedBitsLHSMask(I, BitWidth)
fn get_demanded_bits_lhs_mask(i: i32, bw: i64) -> AP {
    let r = op(i, 1);
    if !has_apint(r) { return ap_ones(bw); }
    let rv = ap_c(r);
    let sb, unused = is_sign_bit_check(icc_pred(i), rv);
    if sb { return ap_sign_mask(bw); }
    let p = icc_pred(i);
    if p == P_UGT { return ap_bits_from(bw, ap_countr_one(rv)); }
    if p == P_ULT { return ap_bits_from(bw, ap_countr_zero(rv)); }
    return ap_ones(bw);
}

// dominatesAllUses(DI, UI, DB)
fn dominates_all_uses(di: i32, ui: i32, db: i32) -> bool {
    let bb = inst_parent(di);
    if bb < 0 { return false; }
    if bb != inst_parent(ui) { return false; }
    if bb == db { return false; }
    var u = vals[di].first_use;
    while u >= 0 {
        let us = uses[u].user;
        u = uses[u].next;
        if us != ui && !dom_block(db, inst_parent(us)) { return false; }
    }
    return true;
}

// isChainSelectCmpBranch(SI)
fn is_chain_select_cmp_branch(si: i32) -> bool {
    let bb = inst_parent(si);
    if bb < 0 { return false; }
    let bi = block_terminator(bb);
    if bi < 0 || iop(bi) != OP_CONDBR { return false; }
    let c = op(bi, 0);
    if !is_inst_op(c, OP_ICMP) || (op(c, 0) != si && op(c, 1) != si) { return false; }
    return true;
}

// replacedSelectWithOperand(SI, Icmp, SIOpd)
fn replaced_select_with_operand(si: i32, icmp: i32, k: i64) -> bool {
    if is_chain_select_cmp_branch(si) && icc_pred(icmp) == P_EQ {
        let succ = term_succ(block_terminator(inst_parent(si)), 1);
        if single_pred(succ) >= 0 && dominates_all_uses(si, icmp, succ) {
            icc_replace_uses_outside_block(si, op(si, k), inst_parent(si));
            return true;
        }
    }
    return false;
}
// Value::replaceUsesOutsideBlock(New, BB)
fn icc_replace_uses_outside_block(v: i32, nv: i32, bb: i32) {
    var u = vals[v].first_use;
    while u >= 0 {
        let nx = uses[u].next;
        let us = uses[u].user;
        if !is_inst(us) || inst_parent(us) != bb {
            if !is_inst(us) { ic_not_ported("replaceUsesOutsideBlock with a constant user"); }
            use_set(u, nv);
        }
        u = nx;
    }
}

// SimplifyDemandedBits(&I, OpNo, Mask, Known, SQ.getWithoutDomCondCache().getWithInstruction(&I))
fn icc_sd_bits_nodc(i: i32, k: i64, mask: AP) -> bool, KB {
    let save_dc = dc_active;
    let save_cx = sd_cxt;
    dc_active = false;
    sd_cxt = i;
    let ch, known = sd_bits(i, k, mask, 0);
    sd_cxt = save_cx;
    dc_active = save_dc;
    return ch, known;
}
// ICmpInst::compare(KnownBits, KnownBits, Pred): 1 true, 0 false, -1 unknown
fn icc_kb_compare(l: KB, r: KB, p: i64) -> i64 {
    match p {
        32 => { return kb_eq(l, r); },
        33 => { let e = kb_eq(l, r); return if e < 0 { -1 } else { 1 - e }; },
        34 => { return kb_ugt(l, r); }, 35 => { return kb_uge(l, r); }, 36 => { return kb_ult(l, r); }, 37 => { return kb_ule(l, r); },
        38 => { return kb_sgt(l, r); }, 39 => { return kb_sge(l, r); }, 40 => { return kb_slt(l, r); }, _ => { return kb_sle(l, r); },
    }
}

// foldICmpUsingKnownBits(I)
fn fold_icmp_using_known_bits(i: i32) -> i32 {
    let o0 = op(i, 0);
    let o1 = op(i, 1);
    let ty = vals[o0].ty;
    let p = icc_pred(i);
    let bw = if is_int_or_int_vec(ty) { ty_scalar_bits(ty) } else { dl_ptr(ptr_as(ty_scalar(ty))).bits };
    if bw == 0 { return -1; }
    let c0, k0 = icc_sd_bits_nodc(i, 0, get_demanded_bits_lhs_mask(i, bw));
    if c0 { return i; }
    let c1, k1 = icc_sd_bits_nodc(i, 1, ap_ones(bw));
    if c1 { return i; }
    if !is_constant(o0) && kb_is_constant(k0) { return ic_new_icmp(p, c_int_ap(ty, kb_const_val(k0)), o1); }
    if !is_constant(o1) && kb_is_constant(k1) { return ic_new_icmp(p, o0, c_int_ap(ty, kb_const_val(k1))); }
    let res = icc_kb_compare(k0, k1, p);
    if res >= 0 { return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, res == 1)); }
    var mn0 = kb_min(k0); var mx0 = kb_max(k0);
    var mn1 = kb_min(k1); var mx1 = kb_max(k1);
    if pred_is_signed(p) { mn0 = kb_smin(k0); mx0 = kb_smax(k0); mn1 = kb_smin(k1); mx1 = kb_smax(k1); }
    var is_mm = false;
    if has_one_use(i) {
        let f = match_select_pattern_v(icc_user_back(i), 0);
        if spf_is_minmax(f) { is_mm = m_max_or_min(o0) || m_max_or_min(o1); }
    }
    if !is_mm {
        if p == P_ULT {
            if ap_eq(mn1, mx0) { return ic_new_icmp(P_NE, o0, o1); }
            if has_apint(o1) {
                let c = ap_c(o1);
                if ap_eq(c, ap_inc(mn0)) { return ic_new_icmp(P_EQ, o0, c_int_ap(vals[o1].ty, ap_dec(c))); }
                if kb_min_tz(k0) >= ap_ceil_log2(c) { return ic_new_icmp(P_EQ, o0, c_null(vals[o1].ty)); }
            }
        } else if p == P_UGT {
            if ap_eq(mx1, mn0) { return ic_new_icmp(P_NE, o0, o1); }
            if has_apint(o1) {
                let c = ap_c(o1);
                if ap_eq(c, ap_dec(mx0)) { return ic_new_icmp(P_EQ, o0, c_int_ap(vals[o1].ty, ap_inc(c))); }
                if kb_min_tz(k0) >= ap_active_bits(c) { return ic_new_icmp(P_NE, o0, c_null(vals[o1].ty)); }
            }
        } else if p == P_SLT {
            if ap_eq(mn1, mx0) { return ic_new_icmp(P_NE, o0, o1); }
            if has_apint(o1) {
                let c = ap_c(o1);
                if ap_eq(c, ap_inc(mn0)) { return ic_new_icmp(P_EQ, o0, c_int_ap(vals[o1].ty, ap_dec(c))); }
            }
        } else if p == P_SGT {
            if ap_eq(mx1, mn0) { return ic_new_icmp(P_NE, o0, o1); }
            if has_apint(o1) {
                let c = ap_c(o1);
                if ap_eq(c, ap_dec(mx0)) { return ic_new_icmp(P_EQ, o0, c_int_ap(vals[o1].ty, ap_inc(c))); }
            }
        }
    }
    if p == P_EQ || p == P_NE {
        let kzi = ap_not(k0.z);
        if kb_is_zero_known(k1) {
            var lhs: i32 = o0;
            if !(bo(o0, OP_AND) && has_apint(op(o0, 1)) && ap_eq(ap_c(op(o0, 1)), kzi)) { lhs = o0; } else { lhs = op(o0, 0); }
            if bo(lhs, OP_SHL) && has_apint_poison(op(lhs, 0)) && m_power2(op(lhs, 0)) {
                let c1 = ap_cp(op(lhs, 0));
                let x = op(lhs, 1);
                let l2c1 = ap_countr_zero(c1);
                let c2 = kzi;
                let c2p = ap_add(ap_and(c2, ap_not(ap_dec(c1))), c1);
                if ap_is_pow2(c2p) {
                    let l2c2 = ap_countr_zero(c2p);
                    return ic_new_icmp(if p == P_EQ { P_UGE } else { P_ULT }, x, c_int_ty(vals[x].ty, (l2c2 - l2c1) as u64));
                }
            }
        }
        if kb_is_constant(k1) && ap_is_pow2(kb_const_val(k1)) && kb_eq_kb(kb_and(k0, k1), k0) {
            return ic_new_icmp(pred_inverse(p), o0, c_null(vals[o1].ty));
        }
    } else if p == P_SGE {
        if ap_eq(mn1, mx0) { return ic_new_icmp(P_EQ, o0, o1); }
    } else if p == P_SLE {
        if ap_eq(mx1, mn0) { return ic_new_icmp(P_EQ, o0, o1); }
    } else if p == P_UGE {
        if ap_eq(mn1, mx0) { return ic_new_icmp(P_EQ, o0, o1); }
    } else if p == P_ULE {
        if ap_eq(mx1, mn0) { return ic_new_icmp(P_EQ, o0, o1); }
    }
    if (pred_is_signed(p) || (pred_is_unsigned(p) && !icc_samesign(i))) &&
       ((ap_is_neg(k0.z) && ap_is_neg(k1.z)) || (ap_is_neg(k0.o) && ap_is_neg(k1.o))) {
        icc_set_pred(i, pred_unsigned(p));
        icc_set_samesign(i, true);
        return i;
    }
    return -1;
}

// foldICmpUsingBoolRange(I)
fn fold_icmp_using_bool_range(i: i32) -> i32 {
    for k in 2 {
        let x = op(i, k);
        let z = op(i, 1 - k);
        if one_use(z) && is_inst_op(z, OP_ZEXT) {
            let y = op(z, 0);
            let p = if k == 0 { icc_pred(i) } else { pred_swapped(icc_pred(i)) };
            if is_int_ty1(vals[y].ty) && p == P_ULT { return ic_new_binop(OP_AND, icb_is_null(x, ""), y); }
            break;
        }
    }
    for k in 2 {
        let x = op(i, k);
        let z = op(i, 1 - k);
        if one_use(z) && is_inst_op(z, OP_SEXT) {
            let y = op(z, 0);
            let p = if k == 0 { icc_pred(i) } else { pred_swapped(icc_pred(i)) };
            if is_int_ty1(vals[y].ty) && p == P_ULE { return ic_new_binop(OP_OR, icb_is_null(x, ""), y); }
            break;
        }
    }
    for k in 2 {
        let x = op(i, k);
        let e = op(i, 1 - k);
        if !is_inst_op(e, OP_ZEXT) && !is_inst_op(e, OP_SEXT) { continue; }
        let c2 = op(e, 0);
        if !is_inst_op(c2, OP_ICMP) || op(c2, 0) != x || !has_apint(op(c2, 1)) { continue; }
        let p1 = icc_pred(i);
        let p2 = icc_pred(c2);
        if !icmp_is_equality(p1) || !icmp_is_equality(p2) { return -1; }
        let c = ap_c(op(c2, 1));
        let sx = iop(e) == OP_SEXT;
        let one = has_one_use(e) && has_one_use(c2);
        if ap_is_zero(c) {
            if p2 == P_EQ { return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, p1 == P_NE)); }
            if !sx || one { return icc_create_range_check(p1, x, sx); }
        } else if if sx { ap_is_all_ones(c) } else { ap_is_one(c) } {
            if p2 == P_NE { return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, p1 == P_NE)); }
            if !sx || one { return icc_create_range_check(p1, x, sx); }
        } else {
            let v: i64 = if p2 == P_NE { if sx { -1 } else { 1 } } else { 0 };
            return ic_new_icmp(p1, x, c_int_ty_s(vals[x].ty, v));
        }
        return -1;
    }
    return -1;
}
fn icc_create_range_check(p1: i64, x: i32, sx: bool) -> i32 {
    let a = icb_icmp(p1, x, c_null(vals[x].ty), "");
    let b = icb_icmp(p1, x, c_int_ty_s(vals[x].ty, if sx { -1 } else { 1 }), "");
    return ic_new_binop(if p1 == P_EQ { OP_OR } else { OP_AND }, a, b);
}

// canonicalizeCmpWithConstant(I)
fn canonicalize_cmp_with_constant(i: i32) -> i32 {
    let p = icc_pred(i);
    if icmp_is_equality(p) || is_canonical_predicate(p) { return -1; }
    let o1 = op(i, 1);
    if !is_constant(o1) { return -1; }
    let ok, np, nc = icc_flipped_strictness(p, o1);
    if !ok { return -1; }
    return ic_new_icmp(np, op(i, 0), nc);
}

// canonicalizeICmpPredicate(I) (also used for fcmp)
fn canonicalize_icmp_predicate(i: i32) -> i32 {
    let p = icc_pred(i);
    if is_canonical_predicate(p) { return -1; }
    if !can_freely_invert_all_users_of(i, -1) { return -1; }
    icc_set_pred(i, pred_inverse_any(p));
    var nm: u8[>..] = [];
    nm.append(val_name(i));
    nm.append(".not");
    set_name(i, nm);
    freely_invert_all_users_of(i, -1);
    return i;
}

// canonicalizeICmpBool(I, Builder)
fn canonicalize_icmp_bool(i: i32) -> i32 {
    var a = op(i, 0);
    var b = op(i, 1);
    let p = icc_pred(i);
    if m_zero(b) {
        if p == P_EQ || p == P_ULE || p == P_SGE { return ic_new_not(a); }
        fatal("internal: ICmp i1 X, C not simplified as expected.");
    } else if m_one(b) {
        if p == P_NE || p == P_ULT || p == P_SGT { return ic_new_not(a); }
        fatal("internal: ICmp i1 X, C not simplified as expected.");
    }
    if p == P_EQ { return ic_new_not(icb_xor(a, b, "")); }
    if p == P_NE { return ic_new_binop(OP_XOR, a, b); }
    if p == P_UGT || p == P_ULT {
        if p == P_UGT { let t = a; a = b; b = t; }
        return ic_new_binop(OP_AND, icb_not(a, ""), b);
    }
    if p == P_SGT || p == P_SLT {
        if p == P_SGT { let t = a; a = b; b = t; }
        return ic_new_binop(OP_AND, icb_not(b, ""), a);
    }
    if p == P_UGE || p == P_ULE {
        if p == P_UGE { let t = a; a = b; b = t; }
        return ic_new_binop(OP_OR, icb_not(a, ""), b);
    }
    if p == P_SGE { let t = a; a = b; b = t; }
    return ic_new_binop(OP_OR, icb_not(b, ""), a);
}

// foldICmpWithHighBitMask(Cmp, Builder)
fn fold_icmp_with_high_bit_mask(cmp: i32) -> i32 {
    var np: i64 = -1;
    var x: i32 = -1;
    var y: i32 = -1;
    var found = false;
    for k in 2 {
        let s = op(cmp, k);
        if one_use(s) && bo(s, OP_SHL) && m_one(op(s, 0)) {
            y = op(s, 1); x = op(cmp, 1 - k);
            let p = if k == 0 { icc_pred(cmp) } else { pred_swapped(icc_pred(cmp)) };
            if p == P_ULE { np = P_NE; } else if p == P_UGT { np = P_EQ; } else { return -1; }
            found = true;
            break;
        }
    }
    if !found {
        for k in 2 {
            let s = op(cmp, k);
            if !one_use(s) { continue; }
            var yy: i32 = -1;
            let n = m_not(s);
            if n >= 0 && bo(n, OP_SHL) && m_all_ones(op(n, 0)) { yy = op(n, 1); }
            else if bo(s, OP_ADD) && bo(op(s, 0), OP_SHL) && m_one(op(op(s, 0), 0)) && m_all_ones(op(s, 1)) { yy = op(op(s, 0), 1); }
            if yy < 0 { continue; }
            y = yy; x = op(cmp, 1 - k);
            let p = if k == 0 { icc_pred(cmp) } else { pred_swapped(icc_pred(cmp)) };
            if p == P_ULT { np = P_NE; } else if p == P_UGE { np = P_EQ; } else { return -1; }
            found = true;
            break;
        }
    }
    if !found { return -1; }
    var nm: u8[>..] = [];
    nm.append(val_name(x)); nm.append(".highbits");
    let nx = icb_lshr(x, y, nm, false);
    return ic_new_icmp(np, nx, c_null(vals[nx].ty));
}

// new ShuffleVectorInst(V, Mask): the second operand is poison
fn icc_new_shuffle(v: i32, mask: const i32[:]) -> i32 {
    let vt = vals[v].ty;
    let rty = ty_vector(ty_elem(vt), mask.len, ty_kind(vt) == TK_SVEC);
    let s = create_inst(OP_SHUFFLEVECTOR, rty, [v, c_poison(vt)]);
    let ii = inst_of(s);
    insts[ii].aux = ints.len as i32;
    insts[ii].naux = mask.len as i32;
    for m in mask { ints.push(m); }
    return s;
}
// IRBuilder::CreateCmp(Pred, LHS, RHS)
fn icb_cmp(p: i64, a: i32, b: i32, name: const u8[:]) -> i32 {
    if p >= 32 { return icb_icmp(p, a, b, name); }
    return icb_fcmp(p, a, b, name);
}
// IRBuilder::CreateFCmp(P, LHS, RHS, Name): the builder's fast-math flags
fn icb_fcmp(p: i64, a: i32, b: i32, name: const u8[:]) -> i32 {
    if is_constant(a) && is_constant(b) {
        let f = cf_fold_cmp_operands(p, a, b, -1);
        if f >= 0 { return f; }
    }
    let c = create_inst(OP_FCMP, cmp_result_ty(vals[a].ty), [a, b]);
    insts[inst_of(c)].pred = p as u8;
    insts[inst_of(c)].fmf = icb_fmf;
    return icb_insert(c, name);
}
fn icc_shuffle_mask_eq(a: i32, b: i32) -> bool {
    let ia = inst_of(a);
    let ib = inst_of(b);
    if insts[ia].naux != insts[ib].naux { return false; }
    for k in insts[ia].naux as i64 { if ints[insts[ia].aux + k] != ints[insts[ib].aux + k] { return false; } }
    return true;
}

// foldVectorCmp(Cmp, Builder)
fn fold_vector_cmp(cmp: i32) -> i32 {
    let p = icc_pred(cmp);
    let lhs = op(cmp, 0);
    let rhs = op(cmp, 1);
    if inst_iid(lhs) == IID_vector_reverse {
        let v1 = op(lhs, 0);
        if inst_iid(rhs) == IID_vector_reverse && (has_one_use(lhs) || has_one_use(rhs)) { return icc_create_cmp_reverse(cmp, p, v1, op(rhs, 0)); }
        if has_one_use(lhs) && is_splat_value(rhs, 0) { return icc_create_cmp_reverse(cmp, p, v1, rhs); }
    } else if is_splat_value(lhs, 0) && one_use(rhs) && inst_iid(rhs) == IID_vector_reverse {
        return icc_create_cmp_reverse(cmp, p, lhs, op(rhs, 0));
    }
    if !is_inst_op(lhs, OP_SHUFFLEVECTOR) || !m_undef(op(lhs, 1)) { return -1; }
    let v1 = op(lhs, 0);
    let v1ty = vals[v1].ty;
    if is_inst_op(rhs, OP_SHUFFLEVECTOR) && m_undef(op(rhs, 1)) && icc_shuffle_mask_eq(lhs, rhs) && v1ty == vals[op(rhs, 0)].ty &&
       (has_one_use(lhs) || has_one_use(rhs)) {
        let nc = icb_cmp(p, v1, op(rhs, 0), "");
        let ii = inst_of(lhs);
        var m: i32[>..<] = [];
        for k in insts[ii].naux as i64 { m.push(ints[insts[ii].aux + k]); }
        return icc_new_shuffle(nc, m);
    }
    if !has_one_use(lhs) || !is_constant(rhs) { return -1; }
    let sc = splat_value(rhs, true);
    let ii = inst_of(lhs);
    let n = insts[ii].naux as i64;
    var idx: i32 = -1;
    var ok = true;
    for k in n {
        let e = ints[insts[ii].aux + k];
        if e < 0 { continue; }
        if idx < 0 { idx = e; } else if e != idx { ok = false; }
    }
    if sc >= 0 && ok && n > 0 {
        let msi = if idx < 0 { -1 } else { idx };
        let c = c_splat(v1ty, sc);
        var nm: i32[>..<] = [];
        for k in n { nm.push(msi); }
        let nc = icb_cmp(p, v1, c, "");
        return icc_new_shuffle(nc, nm);
    }
    return -1;
}
// the createCmpReverse lambda
fn icc_create_cmp_reverse(cmp: i32, p: i64, x: i32, y: i32) -> i32 {
    var nm: u8[>..] = [];
    nm.append(val_name(cmp));
    let v = icb_cmp(p, x, y, nm);
    if is_inst(v) { copy_ir_flags(v, cmp); }
    return ic_new_intrinsic(IID_vector_reverse, [vals[v].ty as i32], [v]);
}

// foldICmpOfUAddOv(I)
fn fold_icmp_of_uadd_ov(i: i32) -> i32 {
    let p = icc_pred(i);
    let o0 = op(i, 0);
    let o1 = op(i, 1);
    var uo: i32 = -1;
    if icc_ev_index(o0) == 0 && inst_iid(op(o0, 0)) == IID_uadd_with_overflow {
        let agg = op(o0, 0);
        let a = op(agg, 0);
        let b = op(agg, 1);
        if (p == P_ULT && (o1 == a || o1 == b)) || (p == P_EQ && m_zero_int(o1) && (m_one(a) || m_one(b))) ||
           (p == P_NE && m_all_ones(o1) && (m_all_ones(a) || m_all_ones(b))) { uo = agg; }
    }
    if uo < 0 && icc_ev_index(o1) == 0 && inst_iid(op(o1, 0)) == IID_uadd_with_overflow && p == P_UGT {
        let agg = op(o1, 0);
        if o0 == op(agg, 0) || o0 == op(agg, 1) { uo = agg; }
    }
    if uo < 0 { return -1; }
    return icc_new_extractvalue(uo, 1);
}

// foldICmpInvariantGroup(I)
fn fold_icmp_invariant_group(i: i32) -> i32 {
    let o0 = op(i, 0);
    if ty_kind(vals[o0].ty) != TK_PTR || null_pointer_is_defined(inst_func(i), ptr_as(vals[o0].ty)) { return -1; }
    let id = inst_iid(o0);
    if is_inst(o0) && m_zero(op(i, 1)) && (id == IID_launder_invariant_group || id == IID_strip_invariant_group) {
        return ic_new_icmp(icc_pred(i), op(o0, 0), op(i, 1));
    }
    return -1;
}

// foldICmpOfVectorReduce(I, DL, Builder)
fn fold_icmp_of_vector_reduce(i: i32) -> i32 {
    let p = icc_pred(i);
    if !icmp_is_equality(p) { return -1; }
    let o = op(i, 0);
    let c = op(i, 1);
    let z = m_zero_int(c);
    if !((z && one_use(o) && inst_iid(o) == IID_vector_reduce_or) || (m_all_ones(c) && one_use(o) && inst_iid(o) == IID_vector_reduce_and)) { return -1; }
    let vec = op(o, 0);
    let vt = vals[vec].ty;
    if ty_kind(vt) != TK_FVEC { return -1; }
    let sbw = dl_size_bits(ty_elem(vt)) * ty_count(vt);
    if !icc_fits_in_legal_integer(sbw) { return -1; }
    let sty = ty_int(sbw);
    let nc = if z { c_int_ty(sty, 0) } else { c_all_ones(sty) };
    return ic_new_icmp(p, icb_cast(OP_BITCAST, vec, sty, ""), nc);
}
// DataLayout::fitsInLegalInteger
fn icc_fits_in_legal_integer(w: i64) -> bool {
    var mx: i64 = 0;
    for x in dl_native { if x > mx { mx = x; } }
    return w <= mx;
}

// foldReductionIdiom(I, Builder, DL)
fn fold_reduction_idiom(i: i32) -> i32 {
    if ty_is_vector(vals[i].ty) { return -1; }
    let bc = op(i, 0);
    if !one_use(bc) || !is_op(bc, OP_BITCAST) || !m_zero(op(i, 1)) { return -1; }
    let inner = op(bc, 0);
    if !one_use(inner) || !is_inst_op(inner, OP_ICMP) { return -1; }
    var l = op(inner, 0);
    var r = op(inner, 1);
    let lt = vals[l].ty;
    if ty_kind(lt) != TK_FVEC || !ty_is_int(ty_elem(lt)) { return -1; }
    let nb = ty_count(lt) * ty_bits(ty_elem(lt));
    if !dl_is_legal_integer(nb) { return -1; }
    let op_ = icc_pred(i);
    if icmp_is_equality(op_) && icc_pred(inner) == P_NE {
        let sty = ty_int(nb);
        var n1: u8[>..] = [];
        n1.append(val_name(l)); n1.append(".scalar");
        l = icb_cast(OP_BITCAST, l, sty, n1);
        var n2: u8[>..] = [];
        n2.append(val_name(r)); n2.append(".scalar");
        r = icb_cast(OP_BITCAST, r, sty, n2);
        return ic_new_icmp(op_, l, r);
    }
    return -1;
}

// foldICmpCommutative(Pred, Op0, Op1, CxtI): called with the operands in both orders
fn fold_icmp_commutative(p0: i64, o0: i32, o1: i32, cx: i32) -> i32 {
    let p = cp_pred(p0);
    if is_op(o0, OP_GEP) {
        let r = fold_gep_icmp(o0, o1, p0, cx);
        if r >= 0 { return r; }
    }
    if is_select_inst(o0) {
        let r = fold_select_icmp(p0, o0, o1, cx);
        if r >= 0 { return r; }
    }
    if is_minmax_iid(inst_iid(o0)) {
        var r = fold_icmp_with_minmax(cx, o0, o1, p0);
        if r >= 0 { return r; }
        r = fold_icmp_with_clamp(cx, o1, o0);
        if r >= 0 { return r; }
    }
    if bo(o0, OP_ADD) && has_apint(op(o0, 1)) && o1 == op(o0, 0) { return fold_icmp_add_op_const(o1, ap_c(op(o0, 1)), p0); }
    if inst_iid(o0) == IID_abs && is_constant(op(o0, 1)) && o1 == op(o0, 0) {
        let x = o1;
        let xty = vals[x].ty;
        let smin = ap_smin_val(ty_scalar_bits(xty));
        let imp = is_all_ones_value(op(o0, 1));
        if p == P_ULE || p == P_SGE { return ic_replace_inst_uses_with(cx, c_bool_ty(vals[cx].ty, true)); }
        if p == P_UGT || p == P_SLT { return ic_replace_inst_uses_with(cx, c_bool_ty(vals[cx].ty, false)); }
        if p == P_UGE || p == P_SLE || p == P_EQ {
            return ic_replace_inst_uses_with(cx, if imp { icb_icmp(P_SGT, x, c_all_ones(xty), "") } else { icb_icmp(P_ULT, x, c_int_ap(xty, ap_inc(smin)), "") });
        }
        return ic_replace_inst_uses_with(cx, if imp { icb_icmp(P_SLT, x, c_null(xty), "") } else { icb_icmp(P_UGT, x, c_int_ap(xty, smin), "") });
    }
    let v = fold_icmp_with_low_bit_masked_val(p0, o0, o1, cx);
    if v >= 0 { return ic_replace_inst_uses_with(cx, v); }
    if bo(o0, OP_UDIV) && op(o0, 0) == o1 && c_all_elts_cmp(op(o0, 1), P_UGT, 1) {
        return ic_new_icmp(pred_swapped(p), o1, c_null(vals[o1].ty));
    }
    if !pred_is_unsigned(p) && bo(o0, OP_SDIV) && op(o0, 0) == o1 && c_all_elts_cmp(op(o0, 1), P_UGT, 1) {
        return ic_new_icmp(pred_swapped(p), o1, c_null(vals[o1].ty));
    }
    if bo(o0, OP_LSHR) && op(o0, 0) == o1 && c_all_elts_cmp(op(o0, 1), P_NE, 0) {
        return ic_new_icmp(pred_swapped(p), o1, c_null(vals[o1].ty));
    }
    if (p == P_SLT || p == P_SGE) && bo(o0, OP_ASHR) && op(o0, 0) == o1 && c_all_elts_cmp(op(o0, 1), P_NE, 0) {
        return ic_new_icmp(pred_swapped(p), o1, c_null(vals[o1].ty));
    }
    let cp_ = icc_pred(cx);
    if bo(o0, OP_SHL) && op_nuw(o0) && icc_m_cint_u64(op(o0, 1)) && !pred_is_signed(cp_) {
        let x = op(o0, 0);
        let sa = ap_zext64(ap_c(op(o0, 1)));
        if sa >= (ty_sbits(x) as u64) { return -1; }
        if can_evaluate_shifted(o1, sa as i64, false, SS_UNSIGNED, cx) {
            let n1 = get_shifted_value(o1, sa as i64, false, SS_UNSIGNED);
            return ic_new_icmp(p, x, n1);
        }
    }
    if bo(o0, OP_SHL) && op_nsw(o0) && icc_m_cint_u64(op(o0, 1)) && !pred_is_unsigned(cp_) {
        let x = op(o0, 0);
        let sa = ap_zext64(ap_c(op(o0, 1)));
        if sa >= (ty_sbits(x) as u64) { return -1; }
        if can_evaluate_shifted(o1, sa as i64, false, SS_SIGNED, cx) {
            let n1 = get_shifted_value(o1, sa as i64, false, SS_SIGNED);
            return ic_new_icmp(p, x, n1);
        }
    }
    return -1;
}

// visitICmpInst(I)
fn visit_icmp(i: i32) -> i32 {
    var changed = false;
    var o0 = op(i, 0);
    var o1 = op(i, 1);
    if get_complexity(o0) < get_complexity(o1) {
        icc_swap_operands(i);
        let t = o0; o0 = o1; o1 = t;
        changed = true;
    }
    let sv = simplify_icmp(icmp_cp(i), o0, o1, sq_at(i), RECURSION_LIMIT);
    if sv >= 0 { return ic_replace_inst_uses_with(i, sv); }
    if icc_pred(i) == P_NE && m_zero(o1) && is_select_inst(o0) {
        let st = op(o0, 1);
        let sf = op(o0, 2);
        let v = dyn_cast_neg_val(st);
        if v >= 0 {
            if v == sf { return ic_new_icmp(icc_pred(i), v, o1); }
        } else {
            let v2 = dyn_cast_neg_val(sf);
            if v2 >= 0 && v2 == st { return ic_new_icmp(icc_pred(i), v2, o1); }
        }
    }
    var r = fold_icmp_trunc_with_trunc_or_ext(i);
    if r >= 0 { return r; }
    if is_int_ty1(vals[o0].ty) {
        r = canonicalize_icmp_bool(i);
        if r >= 0 { return r; }
    }
    r = canonicalize_cmp_with_constant(i);
    if r >= 0 { return r; }
    r = canonicalize_icmp_predicate(i);
    if r >= 0 { return r; }
    r = fold_icmp_with_constant(i);
    if r >= 0 { return r; }
    r = fold_icmp_with_dominating_icmp(i);
    if r >= 0 { return r; }
    r = fold_icmp_using_bool_range(i);
    if r >= 0 { return r; }
    r = fold_icmp_using_known_bits(i);
    if r >= 0 { return r; }
    r = fold_is_multiple_of_a_power_of_two(i);
    if r >= 0 { return r; }
    if has_one_use(i) {
        let u = icc_user_back(i);
        if is_select_inst(u) && match_select_pattern_v(u, 0) != SPF_UNKNOWN { return -1; }
    }
    r = fold_icmp_with_zero(i);
    if r >= 0 { return r; }
    let p = icc_pred(i);
    if (p == P_UGT || p == P_ULT) && inst_iid(o0) == IID_umax && has_apint(op(o0, 1)) && m_not(o1) == op(o0, 0) && op(o0, 0) >= 0 {
        let x = op(o0, 0);
        let c = ap_c(op(o0, 1));
        if p == P_UGT {
            if ap_is_nonneg(c) { return ic_new_icmp(P_SLT, x, c_null(vals[x].ty)); }
            return ic_new_icmp(P_UGT, x, c_int_ap(vals[x].ty, ap_not(c)));
        }
        if ap_is_nonneg(c) { return ic_new_icmp(P_SGT, x, c_all_ones(vals[x].ty)); }
        return ic_new_icmp(P_ULT, x, c_int_ap(vals[x].ty, ap_not(c)));
    }
    if has_apint(o1) {
        let c = ap_c(o1);
        if p == P_UGT && ap_is_max_signed(c) { return ic_new_icmp(P_SLT, o0, c_null(vals[o0].ty)); }
        if p == P_ULT && ap_is_min_signed(c) { return ic_new_icmp(P_SGT, o0, c_all_ones(vals[o0].ty)); }
    }
    r = fold_icmp_binop(i);
    if r >= 0 { return r; }
    r = fold_icmp_inst_with_constant(i);
    if r >= 0 { return r; }
    r = fold_sign_bit_test(i);
    if r >= 0 { return r; }
    if is_phi_inst(o0) {
        r = fold_op_into_phi(i, o0, false);
        if r >= 0 { return r; }
    }
    if is_phi_inst(o1) {
        r = fold_op_into_phi(i, o1, false);
        if r >= 0 { return r; }
    }
    r = fold_icmp_inst_with_constant_not_int(i);
    if r >= 0 { return r; }
    r = fold_icmp_commutative(icmp_cp(i), o0, o1, i);
    if r >= 0 { return r; }
    let scp = icmp_cp(i);
    r = fold_icmp_commutative(cp(pred_swapped(cp_pred(scp)), cp_ss(scp)), o1, o0, i);
    if r >= 0 { return r; }
    if icmp_is_equality(icc_pred(i)) {
        if match_symmetric_pair(op(i, 0), op(i, 1)) {
            ic_replace_operand(i, 0, sp_a);
            ic_replace_operand(i, 1, sp_b);
            return i;
        }
    }
    r = fold_cmp_select_of_constants(i);
    if r >= 0 { return r; }
    if is_select_inst(o0) && is_select_inst(o1) && op(o1, 0) == op(o0, 0) && (has_one_use(o0) || has_one_use(o1)) {
        let cond = op(o0, 0);
        let a = op(o0, 1);
        let b = op(o0, 2);
        let c = op(o1, 1);
        let d = op(o1, 2);
        let res = simplify_icmp(p, a, c, sq_at(-1), RECURSION_LIMIT);
        if res >= 0 {
            let nc = icb_icmp(p, b, d, "");
            return ic_new_select_md(cond, res, nc, o0);
        }
        let res2 = simplify_icmp(p, b, d, sq_at(-1), RECURSION_LIMIT);
        if res2 >= 0 {
            let nc = icb_icmp(p, a, c, "");
            return ic_new_select_md(cond, nc, res2, o0);
        }
    }
    for k in 2 {
        let s = op(i, k);
        let ad = op(i, 1 - k);
        if !bo(s, OP_SUB) { continue; }
        let a = op(s, 0);
        let b = op(s, 1);
        if !bo(ad, OP_ADD) || !((op(ad, 0) == a && op(ad, 1) == b) || (op(ad, 0) == b && op(ad, 1) == a)) { continue; }
        let cpred = if k == 0 { icc_pred(i) } else { pred_swapped(icc_pred(i)) };
        let i0nuw = op_nuw(o0); let i1nuw = op_nuw(o1);
        let i0nsw = op_nsw(o0); let i1nsw = op_nsw(o1);
        if (pred_is_unsigned(p) && i0nuw && i1nuw) || (pred_is_signed(p) && i0nsw && i1nsw) ||
           (icmp_is_equality(p) && ((i0nuw || i0nsw) && (i1nuw || i1nsw))) {
            return ic_new_icmp(pred_swapped(cpred), b, c_int_ty(vals[o0].ty, 0));
        }
        break;
    }
    if ty_kind(vals[o0].ty) == TK_PTR && icmp_is_equality(icc_pred(i)) {
        let u0 = get_underlying_object(o0, 6);
        if is_inst_op(u0, OP_ALLOCA) { if fold_alloca_cmp(u0) { return -1; } }
        let u1 = get_underlying_object(o1, 6);
        if is_inst_op(u1, OP_ALLOCA) { if fold_alloca_cmp(u1) { return -1; } }
    }
    r = fold_icmp_bitcast(i);
    if r >= 0 { return r; }
    r = fold_icmp_with_cast_op(i);
    if r >= 0 { return r; }
    {
        if bo(o0, OP_AND) && m_not(op(o0, 1)) >= 0 && m_zero(o1) && icc_pow2(op(o0, 0), false, i) && icmp_is_equality(icc_pred(i)) {
            let x = op(o0, 0);
            let y = m_not(op(o0, 1));
            return ic_new_icmp(pred_inverse(icc_pred(i)), icb_and(x, y, ""), o1);
        }
        if is_int_or_int_vec(vals[o0].ty) {
            gfi_consume = false;
            let f0 = get_freely_inverted(o0, has_one_use(o0), false) != -1;
            let cons0 = gfi_consume;
            if f0 {
                gfi_consume = false;
                let f1 = get_freely_inverted(o1, has_one_use(o1), false) != -1;
                let cons1 = gfi_consume;
                if f1 && (cons0 || cons1) {
                    let inv0 = get_freely_inverted(o0, has_one_use(o0), true);
                    let inv1 = get_freely_inverted(o1, has_one_use(o1), true);
                    return ic_new_icmp(pred_swapped(icc_pred(i)), inv0, inv1);
                }
            }
        }
        // m_UAddWithOverflow(X, Y, AddI)
        let ua, ux, uy, uadd = icc_m_uadd_with_overflow(i);
        if ua && ty_is_int(vals[ux].ty) {
            if iop(uadd) == OP_ADD {
                let ok, res, ov = optimize_overflow_check(OP_ADD, false, ux, uy, uadd);
                if ok {
                    ic_replace_inst_uses_with(uadd, res);
                    ic_erase(uadd);
                    return ic_replace_inst_uses_with(i, ov);
                }
            }
        }
        if bo(o0, OP_MUL) && op_nuw(o0) && is_inst_op(op(o0, 0), OP_ZEXT) && is_inst_op(op(o0, 1), OP_ZEXT) && has_apint(o1) {
            r = process_umul_zext_idiom(i, o0, ap_c(o1));
            if r >= 0 { return r; }
        }
        let pp = icc_pred(i);
        if (pred_is_unsigned(pp) || icmp_is_equality(pp)) && (is_inst_op(o1, OP_ZEXT) || is_inst_op(o1, OP_SEXT)) {
            let y = op(o1, 0);
            if ty_sbits(y) == 1 && (has_one_use(o0) || has_one_use(o1)) {
                let w = ty_sbits(o0);
                if icc_is_shr(o0) && m_specific_int_ap(op(o0, 1), (w - 1) as u64) {
                    let x = op(o0, 0);
                    let eo = iop(o1);
                    let so = iop(o0);
                    if (eo == OP_ZEXT && so == OP_LSHR) || (eo == OP_SEXT && so == OP_ASHR) {
                        let slt = icb_icmp(P_SLT, x, c_null(vals[x].ty), "");
                        var nm: u8[>..] = [];
                        nm.append(val_name(i));
                        let c = icb_icmp(p, slt, y, nm);
                        return ic_replace_inst_uses_with(i, c);
                    }
                }
            }
        }
    }
    r = fold_icmp_equality(i);
    if r >= 0 { return r; }
    r = fold_icmp_pow2_test(i);
    if r >= 0 { return r; }
    r = fold_icmp_of_uadd_ov(i);
    if r >= 0 { return r; }
    r = fold_icmp_of_vector_reduce(i);
    if r >= 0 { return r; }
    if icc_pred(i) == P_EQ && icc_ev_index(o0) == 0 && is_inst_op(op(o0, 0), OP_CMPXCHG) {
        let ax = op(o0, 0);
        if op(ax, 1) == o1 && (insts[inst_of(ax)].bits & 2) == 0 { return icc_new_extractvalue(ax, 1); }
    }
    r = fold_icmp_with_high_bit_mask(i);
    if r >= 0 { return r; }
    if ty_is_vector(vals[i].ty) {
        r = fold_vector_cmp(i);
        if r >= 0 { return r; }
    }
    r = fold_icmp_invariant_group(i);
    if r >= 0 { return r; }
    r = fold_reduction_idiom(i);
    if r >= 0 { return r; }
    {
        let pq = icc_pred(i);
        if icmp_is_equality(pq) {
            if bo(o0, OP_AND) && is_inst_op(op(o0, 0), OP_SEXT) && has_apint(op(o0, 1)) && has_apint(o1) {
                let a = op(op(o0, 0), 0);
                let c1 = ap_c(op(o0, 1));
                let c2 = ap_c(o1);
                let ity = vals[a].ty;
                let ibw = ty_scalar_bits(ity);
                if ap_active_bits(c2) < ibw {
                    var tc1 = ap_trunc(c1, ibw);
                    if ap_uge(c1, ap_one_bit(c1.w as i64, ibw)) { tc1 = ap_set_bit(tc1, ibw - 1); }
                    let an = icb_and(a, c_int_ap(ity, tc1), "");
                    return ic_new_icmp(pq, an, c_int_ap(ity, ap_trunc(c2, ibw)));
                }
            }
        }
    }
    return if changed { i } else { -1 };
}

// m_UAddWithOverflow(m_Value(X), m_Value(Y), m_Instruction(AddI)) on the icmp: ok, X, Y, AddI
fn icc_m_uadd_with_overflow(i: i32) -> bool, i32, i32, i32 {
    let p = icc_pred(i);
    let l = op(i, 0);
    let r = op(i, 1);
    // (a + b) u< a, (a + b) u< b
    if p == P_ULT && bo(l, OP_ADD) && (op(l, 0) == r || op(l, 1) == r) { return true, op(l, 0), op(l, 1), l; }
    // a >u (a + b), b >u (a + b)
    if p == P_UGT && bo(r, OP_ADD) && (op(r, 0) == l || op(r, 1) == l) { return true, op(r, 0), op(r, 1), r; }
    // (~a) <u b, b >u (~a): m_OneUse(m_Not(a))
    if p == P_ULT && one_use(l) && m_not(l) >= 0 { return true, m_not(l), r, l; }
    if p == P_UGT && one_use(r) && m_not(r) >= 0 { return true, m_not(r), l, r; }
    // (a + 1) == 0, (1 + a) == 0, 0 == (a + 1), 0 == (1 + a)
    if p == P_EQ {
        if bo(l, OP_ADD) && m_zero_int(r) && (m_one(op(l, 0)) || m_one(op(l, 1))) { return true, op(l, 0), op(l, 1), l; }
        if m_zero_int(l) && bo(r, OP_ADD) && (m_one(op(r, 0)) || m_one(op(r, 1))) { return true, op(r, 0), op(r, 1), r; }
    }
    return false, -1, -1, -1;
}

// foldCmpSelectOfConstants(I)
fn fold_cmp_select_of_constants(i: i32) -> i32 {
    let o0 = op(i, 0);
    let o1 = op(i, 1);
    if !is_select_inst(o0) || !is_constant(op(o0, 1)) || !is_constant(op(o0, 2)) { return -1; }
    if !is_select_inst(o1) || !is_constant(op(o1, 1)) || !is_constant(op(o1, 2)) { return -1; }
    let c1 = op(o0, 0);
    let c2 = op(o1, 0);
    if vals[i].ty != vals[c1].ty || vals[i].ty != vals[c2].ty { return -1; }
    let p = icc_pred(i);
    let r00 = cf_fold_cmp_operands(p, op(o0, 2), op(o1, 2), -1);
    let r01 = cf_fold_cmp_operands(p, op(o0, 2), op(o1, 1), -1);
    let r10 = cf_fold_cmp_operands(p, op(o0, 1), op(o1, 2), -1);
    let r11 = cf_fold_cmp_operands(p, op(o0, 1), op(o1, 1), -1);
    if r00 < 0 || r01 < 0 || r10 < 0 || r11 < 0 { return -1; }
    if !icc_null_or_all_ones(r00) || !icc_null_or_all_ones(r01) || !icc_null_or_all_ones(r10) || !icc_null_or_all_ones(r11) { return -1; }
    var t: i64 = 0;
    if !is_null_value(r00) { t |= 1; }
    if !is_null_value(r01) { t |= 2; }
    if !is_null_value(r10) { t |= 4; }
    if !is_null_value(r11) { t |= 8; }
    let res = create_logic_from_table(t, c1, c2, has_one_use(o0) && has_one_use(o1));
    if res < 0 { return -1; }
    return ic_replace_inst_uses_with(i, res);
}
fn icc_null_or_all_ones(c: i32) -> bool { is_null_value(c) || is_all_ones_value(c) }

// ---------------------------------------------------------------------------------------------
// Pointers and memory: foldCmpLoadFromIndexedGlobal, foldGEPICmp, foldAllocaCmp

// decomposeLinearExpression(DL, Ptr) (Analysis/Loads.cpp): BasePtr, Index (-1), Scale, Offset, Flags
fn icc_decompose_linear_expression(ptr: i32) -> i32, i32, AP, AP, u8 {
    let bw = dl_ptr(ptr_as(vals[ptr].ty)).idx;
    var base = ptr;
    var index: i32 = -1;
    var scale = ap_zero(bw);
    var off = ap_zero(bw);
    var fl: u8 = GEP_INBOUNDS | GEP_NUSW | GEP_NUW;
    loop {
        if !is_op(base, OP_GEP) || ty_contains_scalable(gep_src_ty(base)) { return base, index, scale, off, fl; }
        let g = base;
        var var_idx: i32 = -1;
        for k in 1..nops(g) {
            let ix = op(g, k);
            if vals[ix].kind == VK_CINT { continue; }
            if index >= 0 || var_idx >= 0 { return base, index, scale, off, fl; }
            var_idx = ix;
        }
        if var_idx >= 0 && !(ty_is_int(vals[var_idx].ty) && ty_bits(vals[var_idx].ty) == bw) { return base, index, scale, off, fl; }
        base = op(g, 0);
        fl = gep_nw_intersect_for_offset_add(fl, gep_flags(g));
        var t = gep_src_ty(g);
        for k in 1..nops(g) {
            let ix = op(g, k);
            var stride: i64 = 0;
            var st = false;
            if k == 1 { stride = dl_alloc_size(t); }
            else if ty_is_struct(t) { st = true; }
            else { stride = dl_gep_stride(t, ty_elem(t)); }
            if vals[ix].kind == VK_CINT {
                let cv = ci_ap(ix);
                if st {
                    let fi = ap_zext64(cv) as i64;
                    if !ap_is_zero(cv) { off = ap_add(off, ap_u64(dl_struct_offset(t, fi) as u64, bw)); }
                    t = ty_field(t, fi);
                    continue;
                }
                if k > 1 { t = ty_elem(t); }
                if ap_is_zero(cv) { continue; }
                off = ap_add(off, ap_mul(ap_sext_or_trunc(cv, bw), ap_u64(stride as u64, bw)));
                continue;
            }
            if st { fatal("internal: a struct GEP index that is not a constant"); }
            if k > 1 { t = ty_elem(t); }
            index = ix;
            scale = ap_u64(stride as u64, bw);
        }
    }
    return base, index, scale, off, fl;
}

// foldCmpLoadFromIndexedGlobal(LI, GEP, ICI, AndCst)
fn fold_cmp_load_from_indexed_global(li: i32, gep: i32, ici: i32, andc: i32) -> i32 {
    let gv = get_underlying_object(gep, 6);
    if (insts[inst_of(li)].bits & 1) != 0 || !is_gvar(gv) || globs[glob_of(gv)].is_const == 0 || !gv_has_definitive_initializer(gv) { return -1; }
    let ety = vals[li].ty;
    if ty_contains_scalable(ety) { return -1; }
    let esz = dl_store_size(ety);
    let base, idx0, stride, coff, efl = icc_decompose_linear_expression(gep);
    if idx0 < 0 || base != gv || coff.w > 64 { return -1; }
    let init = op(gv, 0);
    let gsz = dl_alloc_size(vals[init].ty);
    if !ap_ult(coff, stride) { return -1; }
    if !ap_uge_u64(stride, esz as u64) { return -1; }
    let st = ap_zext64(stride) as i64;
    let co = ap_zext64(coff) as i64;
    let n = ((gsz - co) + st - 1) / st;
    if n > 1024 { return -1; }
    let UNDEF = -2;
    let OVER = -3;
    var ft: i64 = UNDEF; var stt: i64 = UNDEF;
    var ff: i64 = UNDEF; var sf: i64 = UNDEF;
    var tre: i64 = UNDEF; var fre: i64 = UNDEF;
    var magic: u64 = 0;
    let rhs = op(ici, 1);
    let p = icc_pred(ici);
    var offv = co;
    for i in n {
        var elt = cf_fold_load_from_const(init, ety, offv);
        offv += st;
        if elt < 0 { return -1; }
        if andc >= 0 {
            elt = cf_fold_binop_operands(OP_AND, elt, andc);
            if elt < 0 { return -1; }
        }
        let c = cf_fold_cmp_operands(p, elt, rhs, -1);
        if c < 0 { return -1; }
        if is_undef_or_poison(c) {
            if tre == i - 1 { tre = i; }
            if fre == i - 1 { fre = i; }
            continue;
        }
        if vals[c].kind != VK_CINT { return -1; }
        let t = !ap_is_zero(ci_ap(c));
        if t {
            if ft == UNDEF { ft = i; tre = i; }
            else {
                if stt == UNDEF { stt = i; } else { stt = OVER; }
                if tre == i - 1 { tre = i; } else { tre = OVER; }
            }
        } else {
            if ff == UNDEF { ff = i; fre = i; }
            else {
                if sf == UNDEF { sf = i; } else { sf = OVER; }
                if fre == i - 1 { fre = i; } else { fre = OVER; }
            }
        }
        if i < 64 && t { magic |= (1 as u64) << (i as u64); }
        if (i & 8) == 0 && i >= 64 && stt == OVER && sf == OVER && tre == OVER && fre == OVER { return -1; }
    }
    var idx = idx0;
    let ity = vals[idx].ty;
    if stt != OVER {
        idx = icc_mask_idx(idx, efl, stride);
        if ft == UNDEF { return ic_replace_inst_uses_with(ici, c_false()); }
        let fti = c_int_ty(ity, ft as u64);
        if stt == UNDEF { return ic_new_icmp(P_EQ, idx, fti); }
        let c1 = icb_icmp(P_EQ, idx, fti, "");
        let c2 = icb_icmp(P_EQ, idx, c_int_ty(ity, stt as u64), "");
        return ic_new_binop(OP_OR, c1, c2);
    }
    if sf != OVER {
        idx = icc_mask_idx(idx, efl, stride);
        if ff == UNDEF { return ic_replace_inst_uses_with(ici, c_true()); }
        let ffi = c_int_ty(ity, ff as u64);
        if sf == UNDEF { return ic_new_icmp(P_NE, idx, ffi); }
        let c1 = icb_icmp(P_NE, idx, ffi, "");
        let c2 = icb_icmp(P_NE, idx, c_int_ty(ity, sf as u64), "");
        return ic_new_binop(OP_AND, c1, c2);
    }
    if tre != OVER {
        idx = icc_mask_idx(idx, efl, stride);
        if ft != 0 { idx = icb_add(idx, c_int_ty_s(ity, -ft), ""); }
        return ic_new_icmp(P_ULT, idx, c_int_ty(ity, (tre - ft + 1) as u64));
    }
    if fre != OVER {
        idx = icc_mask_idx(idx, efl, stride);
        if ff != 0 { idx = icb_add(idx, c_int_ty_s(ity, -ff), ""); }
        return ic_new_icmp(P_UGT, idx, c_int_ty(ity, (fre - ff) as u64));
    }
    var ty: i32 = -1;
    if n <= ty_bits(ity) { ty = ity; }
    else {
        // DL.getSmallestLegalIntType(Ctx, ArrayElementCount)
        var best: i64 = 0;
        for w in dl_native { if w >= n && (best == 0 || w < best) { best = w; } }
        if best > 0 { ty = ty_int(best); }
    }
    if ty >= 0 {
        idx = icc_mask_idx(idx, efl, stride);
        var v = icb_int_cast(idx, ty, false, "");
        v = icb_lshr(c_int_ty(ty, magic), v, "", false);
        v = icb_and(c_int_ty(ty, 1), v, "");
        return ic_new_icmp(P_NE, v, c_int_ty(ty, 0));
    }
    return -1;
}
// the MaskIdx lambda
fn icc_mask_idx(idx: i32, fl: u8, stride: AP) -> i32 {
    let tz = ap_countr_zero(stride);
    if (fl & GEP_INBOUNDS) == 0 && tz != 0 {
        var m = c_all_ones(vals[idx].ty);
        m = icb_lshr(m, c_int_ty(vals[idx].ty, tz as u64), "", false);
        return icb_and(idx, m, "");
    }
    return idx;
}

// canRewriteGEPAsOffset(Start, Base, NW, DL, Explored): ok, nw; Explored in icc_explored (a SetVector)
var icc_explored: i32[>..<];
fn icc_explored_has(v: i32) -> bool { for x in icc_explored { if x == v { return true; } } return false; }
fn icc_explored_insert(v: i32) { if !icc_explored_has(v) { icc_explored.push(v); } }
fn can_rewrite_gep_as_offset(start: i32, base: i32, nw0: u8) -> bool, u8 {
    var nw = nw0;
    icc_explored.resize(0);
    var wl: i32[>..<] = [];
    wl.push(start);
    icc_explored_insert(base);
    while wl.len > 0 {
        var phis: i32[>..<] = [];
        while wl.len > 0 {
            if icc_explored.len >= 100 { return false, nw; }
            let v = wl[wl.len - 1];
            if icc_explored_has(v) { wl.pop(); continue; }
            if !is_inst_op(v, OP_GEP) && !is_phi_inst(v) { return false, nw; }
            if is_op(v, OP_GEP) {
                var nonc = 0;
                for k in 1..nops(v) { if vals[op(v, k)].kind != VK_CINT { nonc++; } }
                if (gep_flags(v) & GEP_INBOUNDS) == 0 || nonc > 1 { return false, nw; }
                nw = gep_nw_intersect_for_offset_add(nw, gep_flags(v));
                if !icc_explored_has(op(v, 0)) { wl.push(op(v, 0)); }
            }
            if wl[wl.len - 1] == v {
                wl.pop();
                icc_explored_insert(v);
            }
            if is_phi_inst(v) {
                if iop(block_terminator(inst_parent(v))) == OP_CATCHSWITCH { return false, nw; }
                icc_explored_insert(v);
                var dup = false;
                for x in phis { if x == v { dup = true; } }
                if !dup { phis.push(v); }
            }
        }
        for pn in phis {
            for k in nops(pn) { if !icc_explored_has(op(pn, k)) { wl.push(op(pn, k)); } }
        }
    }
    // The final "PHI node users" check never rejects anything in LLVM 23: it iterates Val->uses() and
    // dyn_casts each Use, whose implicit conversion yields Val itself (not the user), so PHI is either null
    // or equal to Inst and every iteration `continue`s (InstCombineCompares.cpp canRewriteGEPAsOffset).
    return true, nw;
}
// setInsertionPoint(Builder, V, Before)
fn icc_set_insertion_point(v: i32, before: bool) {
    if is_phi_inst(v) { icb_set_insert_point_head(first_insertion_pt(inst_parent(v))); return; }
    if is_inst(v) {
        if before { icb_set_insert_point(v); } else { icb_set_insert_point(inst_next(v)); }
        return;
    }
    if is_arg(v) {
        let e = func_entry(args_parent[vals[v].sub]);
        icb_set_insert_point_head(first_insertion_pt(e));
    }
}
// rewriteGEPAsOffset(Start, Base, NW, DL, Explored, IC)
fn rewrite_gep_as_offset(start: i32, base: i32, nw: u8) -> i32 {
    let ity = ty_int(dl_ptr(ptr_as(vals[start].ty)).idx);
    var nv: i32[>..<] = [];
    for x in icc_explored { nv.push(-1); }
    fn idx_of(v: i32) -> i64 { for k in icc_explored.len { if icc_explored[k] == v { return k; } } return -1; }
    nv[idx_of(base)] = c_null(ity);
    // a plain IRBuilder<> (no worklist, no folding into the InstCombine worklist)
    let spos = icb_pos; let sbb = icb_bb; let sdl = icb_dl;
    for k in icc_explored.len {
        let v = icc_explored[k];
        if v == base { continue; }
        if is_phi_inst(v) {
            let np = new_inst(OP_PHI, ity, nops(v));
            vals[np].nops = 0;
            inst_insert_before_head(np, v);
            var nm: u8[>..] = [];
            nm.append(val_name(v)); nm.append(".idx");
            ic_register_name(np);
            set_name(np, nm);
            nv[k] = np;
        }
    }
    for k in icc_explored.len {
        let v = icc_explored[k];
        if nv[k] >= 0 { continue; }
        if is_op(v, OP_GEP) {
            icc_set_insertion_point(v, true);
            let o = nv[idx_of(op(v, 0))];
            let off = icc_plain(emit_gep_offset_raw(v));
            if vals[o].kind == VK_CINT && ap_is_zero(ci_ap(o)) { nv[k] = off; }
            else {
                var nm: u8[>..] = [];
                nm.append(val_name(op(v, 0))); nm.append(".add");
                nv[k] = icc_plain(icb_add_nw(o, off, nm, (nw & GEP_NUW) != 0, (nw & GEP_NUSW) != 0));
            }
            continue;
        }
        if is_phi_inst(v) { continue; }
        fatal("internal: Unexpected instruction type");
    }
    for k in icc_explored.len {
        let v = icc_explored[k];
        if v == base || !is_phi_inst(v) { continue; }
        let np = nv[k];
        for j in nops(v) {
            var ni = op(v, j);
            let x = idx_of(ni);
            if x >= 0 { ni = nv[x]; }
            phi_add_incoming(np, ni, phi_block(v, j));
        }
    }
    for k in icc_explored.len {
        let v = icc_explored[k];
        if v == base { continue; }
        icc_set_insertion_point(v, false);
        var nm: u8[>..] = [];
        nm.append(val_name(v)); nm.append(".ptr");
        let ng = icc_plain(icb_gep(T_I8, base, [nv[k]], nm, nw));
        ic_replace_inst_uses_with(v, ng);
        icw_add(v);
    }
    icb_pos = spos; icb_bb = sbb; icb_dl = sdl; icb_head = false;
    return nv[idx_of(start)];
}
// instructions made by the plain IRBuilder<> of rewriteGEPAsOffset are not added to the worklist
fn icc_plain(v: i32) -> i32 { if is_inst(v) { icw_remove(v); } return v; }

// transformToIndexedCompare(GEPLHS, RHS, Cond, DL, IC)
fn transform_to_indexed_compare(gl: i32, rhs: i32, p0: i64) -> i32 {
    if ty_is_vector(vals[gl].ty) { return -1; }
    if !gep_all_constant_indices(gl) { return -1; }
    let pb = strip_and_accumulate_offsets(gl, false, false, false);
    let off = vt_off;
    if vals[pb].ty != vals[gl].ty { return -1; }
    let ok, nw = can_rewrite_gep_as_offset(rhs, pb, gep_flags(gl));
    if !ok { return -1; }
    let nr = rewrite_gep_as_offset(rhs, pb, nw);
    let iw = dl_ptr(ptr_as(vals[gl].ty)).idx;
    return ic_new_icmp(pred_signed(cp_pred(p0)), c_int_ap(ty_int(iw), ap_i64(off, iw)), nr);
}

// foldGEPICmp(GEPLHS, RHS, Cond, I)
fn fold_gep_icmp(gl: i32, rhs0: i32, p0: i64, i: i32) -> i32 {
    let p = cp_pred(p0);
    if pred_is_signed(p) { return -1; }
    var rhs = rhs0;
    if !is_inst_op(rhs, OP_GEP) { rhs = strip_pointer_casts(rhs); }
    common_pointer_base_compute(gl, rhs);
    if cpb_ptr == rhs && icc_gep_can_fold(p, cpb_lnw) && !common_pointer_base_is_expensive() {
        let it = dl_index_type(vals[gl].ty);
        var lg: i32[>..<] = [];
        for g in cpb_lhs { lg.push(g); }
        let lnw = cpb_lnw;
        let o = emit_gep_offsets(lg, lnw, it, true);
        return icc_gep_new_icmp(p, lnw, o, c_null(vals[o].ty));
    }
    if (gep_flags(gl) & GEP_INBOUNDS) != 0 && icmp_is_equality(p) && vals[rhs].kind == VK_CNULL &&
       !null_pointer_is_defined(inst_func(i), ptr_as(vals[rhs].ty)) {
        var b = op(gl, 0);
        if ty_is_vector(vals[gl].ty) && !ty_is_vector(vals[b].ty) { b = icb_vector_splat(vals[gl].ty, b, ""); }
        return ic_new_icmp(p, b, icc_ptr_bitcast_or_ascast(rhs, vals[b].ty));
    } else if is_op(rhs, OP_GEP) {
        let gr = rhs;
        let nw = gep_flags(gl) & gep_flags(gr);
        if op(gl, 0) != op(gr, 0) {
            var same = nops(gl) == nops(gr) && vals[op(gl, 0)].ty == vals[op(gr, 0)].ty && gep_src_ty(gl) == gep_src_ty(gr);
            if same { for k in 1..nops(gl) { if op(gl, k) != op(gr, k) { same = false; break; } } }
            let bt = vals[op(gl, 0)].ty;
            if same && cmp_result_ty(bt) == vals[i].ty && icc_gep_can_fold(p, nw) { return ic_new_icmp(p, op(gl, 0), op(gr, 0)); }
            if (gep_flags(gl) & GEP_INBOUNDS) != 0 && (gep_flags(gr) & GEP_INBOUNDS) != 0 &&
               (gep_all_constant_indices(gl) || has_one_use(gl)) && (gep_all_constant_indices(gr) || has_one_use(gr)) &&
               strip_pointer_casts(op(gl, 0)) == strip_pointer_casts(op(gr, 0)) && !ty_is_vector(vals[gl].ty) {
                var lo = emit_gep_offset(gl, false);
                var ro = emit_gep_offset(gr, false);
                let lt = vals[lo].ty;
                let rt = vals[ro].ty;
                if lt != rt {
                    if ty_bits(lt) < ty_bits(rt) { ro = icb_trunc(ro, lt, ""); } else { lo = icb_trunc(lo, rt, ""); }
                }
                let c = icb_icmp(pred_signed(p), lo, ro, "");
                return ic_replace_inst_uses_with(i, c);
            }
        }
        if op(gl, 0) == op(gr, 0) && nops(gl) == nops(gr) && gep_src_ty(gl) == gep_src_ty(gr) {
            var nd = 0;
            var dop: i64 = 0;
            for k in 1..nops(gr) {
                if op(gl, k) != op(gr, k) {
                    let lt = vals[op(gl, k)].ty;
                    let rt = vals[op(gr, k)].ty;
                    if dl_size_bits_prim(lt) != dl_size_bits_prim(rt) || (ty_is_vector(vals[gl].ty) && (!ty_is_vector(lt) || !ty_is_vector(rt))) { nd = 2; break; }
                    if nd > 0 { nd++; break; }
                    nd++;
                    dop = k;
                }
            }
            if nd == 0 { return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, pred_true_when_equal(p))); }
            if nd == 1 && nw != 0 { return icc_gep_new_icmp(p, nw, op(gl, dop), op(gr, dop)); }
        }
        if cpb_ptr >= 0 && icc_gep_can_fold(p, cpb_lnw & cpb_rnw) && !common_pointer_base_is_expensive() {
            let it = dl_index_type(vals[gl].ty);
            var lg: i32[>..<] = [];
            for g in cpb_lhs { lg.push(g); }
            var rg: i32[>..<] = [];
            for g in cpb_rhs { rg.push(g); }
            let lnw = cpb_lnw;
            let rnw = cpb_rnw;
            let l = emit_gep_offsets(lg, lnw, it, true);
            let r = emit_gep_offsets(rg, rnw, it, true);
            return icc_gep_new_icmp(p, lnw & rnw, l, r);
        }
    }
    return transform_to_indexed_compare(gl, rhs, p0);
}
fn dl_size_bits_prim(t: i32) -> i64 { if ty_is_vector(t) { ty_scalar_bits(t) * ty_count(t) } else { ty_scalar_bits(t) } }
// the CanFold lambda
fn icc_gep_can_fold(p: i64, nw: u8) -> bool { icmp_is_equality(p) || nw != 0 }
// the NewICmp lambda
fn icc_gep_new_icmp(p: i64, nw: u8, a: i32, b: i32) -> i32 {
    if (nw & GEP_NUW) == 0 { return ic_new_icmp(pred_signed(p), a, b); }
    let c = ic_new_icmp(p, a, b);
    icc_set_samesign(c, (nw & GEP_NUSW) != 0);
    return c;
}
// ConstantExpr::getPointerBitCastOrAddrSpaceCast
fn icc_ptr_bitcast_or_ascast(c: i32, ty: i32) -> i32 {
    if vals[c].ty == ty { return c; }
    if ptr_as(vals[c].ty) != ptr_as(ty) { return ce_cast(OP_ADDRSPACECAST, c, ty); }
    return ce_cast(OP_BITCAST, c, ty);
}

// foldAllocaCmp(Alloca)
fn fold_alloca_cmp(a: i32) -> bool {
    if ct_alloca_cmp_tracker(a) { return false; }
    var changed = false;
    var cmps: i32[>..<] = [];
    var bits: i64[>..<] = [];
    for k in ct_icmps.len { cmps.push(ct_icmps[k]); bits.push(ct_icmp_bits[k]); }
    for k in cmps.len {
        let c = cmps[k];
        let b = bits[k];
        if b == 1 || b == 2 {
            let res = c_bool_ty(vals[c].ty, icc_pred(c) == P_NE);
            ic_replace_inst_uses_with(c, res);
            ic_erase(c);
            changed = true;
        }
    }
    return changed;
}

// =============================================================================================
// fcmp

fn icc_fpk(ty: i32) -> i64 { types[ty_scalar(ty)].kind as i64 }
// Type::getFPMantissaWidth
fn icc_mantissa_width(ty: i32) -> i64 {
    let k = icc_fpk(ty);
    if k == TK_PPC_FP128 { return -1; }
    return fp_fmt(k).p;
}
// ConstantFP::get(Ty, APFloat): a splat for vector types
fn icc_cfp(ty: i32, lo: u64, hi: u64) -> i32 {
    if ty_is_vector(ty) { return c_splat(ty, c_fp(ty_scalar(ty), lo, hi)); }
    return c_fp(ty, lo, hi);
}
fn icc_fp_zero(ty: i32) -> i32 { icc_cfp(ty, 0, 0) }
// new FCmpInst(Pred, LHS, RHS, "", FlagsSource): the fast-math flags of FlagsSource (-1: none)
fn icc_new_fcmp(p: i64, a: i32, b: i32, fsrc: i32) -> i32 {
    let c = create_inst(OP_FCMP, cmp_result_ty(vals[a].ty), [a, b]);
    insts[inst_of(c)].pred = p as u8;
    if fsrc >= 0 { insts[inst_of(c)].fmf = insts[inst_of(fsrc)].fmf; }
    return c;
}
fn icc_fcmp_is_equality(p: i64) -> bool { p == P_OEQ || p == P_ONE || p == P_UEQ || p == P_UNE }
// FCmpInst::isCommutative
fn icc_fcmp_is_commutative(p: i64) -> bool { icc_fcmp_is_equality(p) || p == P_FALSE || p == P_TRUE || p == P_ORD || p == P_UNO }
fn icc_has_fmf(i: i32, f: u8) -> bool { (insts[inst_of(i)].fmf & f) != 0 }
fn icc_set_fmf(i: i32, f: u8, b: bool) {
    let ii = inst_of(i);
    if b { insts[ii].fmf |= f; } else { insts[ii].fmf &= ~f; }
}

// APFloat helpers on (kind, lo, hi) bit patterns
fn icc_fp_bits_ap(kind: i64, lo: u64, hi: u64) -> AP {
    let w = fp_fmt(kind).total;
    if w <= 64 { return ap_u64(lo, w); }
    return ap_from_words(w, [lo, hi]);
}
fn icc_fp_ap_lo(a: AP) -> u64 { ap_word(a, 0) }
fn icc_fp_ap_hi(a: AP) -> u64 { if a.w > 64 { ap_word(a, 1) } else { 0 } }
fn icc_fp_is_ieee_bits(kind: i64) -> bool { kind == TK_HALF || kind == TK_BFLOAT || kind == TK_FLOAT || kind == TK_DOUBLE || kind == TK_FP128 }
// APFloat::next(nextDown) for finite and infinite values of the IEEE interchange formats
fn icc_fp_next(kind: i64, lo: u64, hi: u64, down: bool) -> u64, u64 {
    if !icc_fp_is_ieee_bits(kind) { ic_not_ported("APFloat::next for x86_fp80/ppc_fp128"); }
    let p = fp_decompose(kind, lo, hi);
    if p.cat == FC_NAN { ic_not_ported("APFloat::next of a NaN"); }
    if down {
        let nlo, nhi = fp_neg_bits(kind, lo, hi);
        let ulo, uhi = icc_fp_next_up(kind, nlo, nhi);
        return fp_neg_bits(kind, ulo, uhi);
    }
    return icc_fp_next_up(kind, lo, hi);
}
fn icc_fp_next_up(kind: i64, lo: u64, hi: u64) -> u64, u64 {
    let p = fp_decompose(kind, lo, hi);
    let w = fp_fmt(kind).total;
    let b = icc_fp_bits_ap(kind, lo, hi);
    if p.cat == FC_INF {
        if !p.neg { return lo, hi; }
        // -inf -> -largest
        let r = ap_dec(b);
        return icc_fp_ap_lo(r), icc_fp_ap_hi(r);
    }
    if p.cat == FC_ZERO { return 1, 0; }
    let r = if p.neg { ap_dec(b) } else { ap_inc(b) };
    if w <= 64 { return ap_lo64(r), 0; }
    return icc_fp_ap_lo(r), icc_fp_ap_hi(r);
}
// APFloat::convertFromAPInt(V, isSigned, rmNearestTiesToEven)
fn icc_fp_from_int(kind: i64, a: AP, signed: bool) -> u64, u64 {
    let neg = signed && ap_is_neg(a);
    let m = if neg { ap_neg(a) } else { a };
    var num: u32[>..<] = [];
    var den: u32[>..<] = [];
    var mw: u64[>..] = [];
    for k in ap_nwords(m) { mw.push(ap_word(m, k)); }
    bn_from_words(num, mw);
    bn_set_u64(den, 1);
    return fp_round_rational(kind, neg, num, den);
}
// APFloat::convertToInteger(APSInt(W, !Signed), Mode, &IsExact): opOK-or-inexact, isExact, value
fn icc_fp_to_int(kind: i64, lo: u64, hi: u64, w: i64, signed: bool, mode: i64) -> bool, bool, AP {
    let p0 = fp_decompose(kind, lo, hi);
    if p0.cat == FC_NAN || p0.cat == FC_INF { return false, false, ap_zero(w); }
    if p0.cat == FC_ZERO { return true, !p0.neg, ap_zero(w); }
    let rlo, rhi = fp_round_to_integral(kind, lo, hi, mode);
    let frac_exact = rlo == lo && rhi == hi;
    let f = fp_fmt(kind);
    let p = fp_decompose(kind, rlo, rhi);
    if p.cat == FC_ZERO { return true, frac_exact, ap_zero(w); }
    let mw = w + 130;
    let sig = ap_from_words(mw, [p.sig0, p.sig1]);
    let sh = p.exponent - (if f.explicit_int { 63 } else { f.p - 1 });
    var mag = ap_zero(mw);
    if sh >= 0 {
        if sh + f.p > w + 1 { return false, false, ap_zero(w); }
        mag = ap_shl(sig, sh);
    } else if -sh < mw {
        mag = ap_lshr(sig, -sh);
    }
    let maxbits = if signed { w - 1 } else { w };
    let abits = ap_active_bits(mag);
    if p.neg && !ap_is_zero(mag) {
        if !signed { return false, false, ap_zero(w); }
        if abits > maxbits + 1 { return false, false, ap_zero(w); }
        if abits == maxbits + 1 && ap_countr_zero(mag) != abits - 1 { return false, false, ap_zero(w); }
        return true, frac_exact, ap_neg(ap_trunc(mag, w));
    }
    if abits > maxbits { return false, false, ap_zero(w); }
    return true, frac_exact, ap_trunc(mag, w);
}
fn icc_cfp_lo(c: i32) -> u64 { cint_lo(c) }
fn icc_cfp_hi(c: i32) -> u64 { cint_hi(c) }

// foldFCmpIntToFPConst(I, LHSI, RHSC)
fn fold_fcmp_int_to_fp_const(i: i32, lhsi: i32, rhsc: i32) -> i32 {
    let rc = m_apfloat(rhsc);
    if rc < 0 { return -1; }
    let mwid = icc_mantissa_width(vals[lhsi].ty);
    if mwid == -1 { return -1; }
    let ity = vals[op(lhsi, 0)].ty;
    let iw = ty_scalar_bits(ity);
    let uns = iop(lhsi) == OP_UITOFP;
    let kind = icc_fpk(vals[rc].ty);
    let lo = icc_cfp_lo(rc);
    let hi = icc_cfp_hi(rc);
    let rp = fp_decompose(kind, lo, hi);
    let fp_p = icc_pred(i);
    if icc_fcmp_is_equality(fp_p) {
        let ok, exact, unused = icc_fp_to_int(kind, lo, hi, iw, !uns, FRM_NEAREST_EVEN);
        if !(ok && exact) {
            let rlo, rhi = fp_round_to_integral(kind, lo, hi, FRM_NEAREST_EVEN);
            if fp_compare(kind, lo, hi, rlo, rhi) != 1 {
                if fp_p == P_OEQ || fp_p == P_UEQ { return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, false)); }
                return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, true));
            }
        }
    }
    if iw > mwid {
        let e = cfp_ilogb(rc);
        let unsb = if uns { 0 } else { 1 };
        if e == 2147483647 {
            let maxe = fp_fmt(kind).bias;
            if maxe < iw - unsb { return -1; }
        } else {
            if mwid <= e && e <= iw - unsb { return -1; }
        }
    }
    var p: i64 = 0;
    if fp_p == P_UEQ || fp_p == P_OEQ { p = P_EQ; }
    else if fp_p == P_FUGT || fp_p == P_OGT { p = if uns { P_UGT } else { P_SGT }; }
    else if fp_p == P_FUGE || fp_p == P_OGE { p = if uns { P_UGE } else { P_SGE }; }
    else if fp_p == P_FULT || fp_p == P_OLT { p = if uns { P_ULT } else { P_SLT }; }
    else if fp_p == P_FULE || fp_p == P_OLE { p = if uns { P_ULE } else { P_SLE }; }
    else if fp_p == P_UNE || fp_p == P_ONE { p = P_NE; }
    else if fp_p == P_ORD { return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, true)); }
    else if fp_p == P_UNO { return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, false)); }
    else { fatal("internal: unexpected fcmp predicate"); }
    let it = vals[i].ty;
    if !uns {
        let slo, shi = icc_fp_from_int(kind, ap_smax_val(iw), true);
        if fp_compare(kind, slo, shi, lo, hi) == 0 {
            return ic_replace_inst_uses_with(i, c_bool_ty(it, p == P_NE || p == P_SLT || p == P_SLE));
        }
    } else {
        let ulo, uhi = icc_fp_from_int(kind, ap_ones(iw), false);
        if fp_compare(kind, ulo, uhi, lo, hi) == 0 {
            return ic_replace_inst_uses_with(i, c_bool_ty(it, p == P_NE || p == P_ULT || p == P_ULE));
        }
    }
    if !uns {
        let slo, shi = icc_fp_from_int(kind, ap_smin_val(iw), true);
        if fp_compare(kind, slo, shi, lo, hi) == 2 {
            return ic_replace_inst_uses_with(i, c_bool_ty(it, p == P_NE || p == P_SGT || p == P_SGE));
        }
    } else {
        let ulo, uhi = icc_fp_from_int(kind, ap_zero(iw), false);
        if fp_compare(kind, ulo, uhi, lo, hi) == 2 {
            return ic_replace_inst_uses_with(i, c_bool_ty(it, p == P_NE || p == P_UGT || p == P_UGE));
        }
    }
    let ok, exact, rint = icc_fp_to_int(kind, lo, hi, iw, !uns, FRM_ZERO);
    if rp.cat != FC_ZERO {
        if !(ok && exact) {
            if p == P_NE { return ic_replace_inst_uses_with(i, c_bool_ty(it, true)); }
            if p == P_EQ { return ic_replace_inst_uses_with(i, c_bool_ty(it, false)); }
            if p == P_ULE { if rp.neg { return ic_replace_inst_uses_with(i, c_bool_ty(it, false)); } }
            else if p == P_SLE { if rp.neg { p = P_SLT; } }
            else if p == P_ULT { if rp.neg { return ic_replace_inst_uses_with(i, c_bool_ty(it, false)); } p = P_ULE; }
            else if p == P_SLT { if !rp.neg { p = P_SLE; } }
            else if p == P_UGT { if rp.neg { return ic_replace_inst_uses_with(i, c_bool_ty(it, true)); } }
            else if p == P_SGT { if rp.neg { p = P_SGE; } }
            else if p == P_UGE { if rp.neg { return ic_replace_inst_uses_with(i, c_bool_ty(it, true)); } p = P_UGT; }
            else if p == P_SGE { if !rp.neg { p = P_SGT; } }
        }
    }
    return ic_new_icmp(p, op(lhsi, 0), c_int_ap(ity, rint));
}

// foldFCmpReciprocalAndZero(I, LHSI, RHSC)
fn fold_fcmp_reciprocal_and_zero(i: i32, lhsi: i32, rhsc: i32) -> i32 {
    var p = icc_pred(i);
    if p != P_OGT && p != P_OLT && p != P_OGE && p != P_OLE { return -1; }
    if !m_any_zero_fp(rhsc) { return -1; }
    if !icc_has_fmf(lhsi, FMF_NINF) || !icc_has_fmf(i, FMF_NINF) { return -1; }
    let c = m_apfloat(op(lhsi, 0));
    if c < 0 { return -1; }
    let cp_ = cfp_parts(c);
    if cp_.cat == FC_ZERO { return -1; }
    if cp_.neg { p = icc_fcmp_swapped(p); }
    return icc_new_fcmp(p, op(lhsi, 1), rhsc, i);
}

// the ConvertFltSema lambda: convert with rmNearestTiesToEven
fn icc_fp_conv(from: i64, to: i64, lo: u64, hi: u64) -> u64, u64 { return fp_convert(from, to, lo, hi); }
fn icc_fp_is_inf(kind: i64, lo: u64, hi: u64) -> bool { fp_decompose(kind, lo, hi).cat == FC_INF }
fn icc_fp_is_finite(kind: i64, lo: u64, hi: u64) -> bool { let c = fp_decompose(kind, lo, hi).cat; c != FC_INF && c != FC_NAN }

// foldFCmpFpTrunc(I, FPTrunc, C)
fn fold_fcmp_fp_trunc(i: i32, fpt: i32, c: i32) -> i32 {
    let p = icc_pred(i);
    let dty = vals[op(fpt, 0)].ty;
    let cv = m_apfloat(c);
    if cv < 0 { return -1; }
    if p == P_ORD || p == P_UNO { return icc_new_fcmp(p, op(fpt, 0), icc_fp_zero(dty), i); }
    var down = false;
    if p == P_OGE || p == P_FUGE || p == P_OLT || p == P_FULT { down = true; }
    else if p == P_OGT || p == P_FUGT || p == P_OLE || p == P_FULE { down = false; }
    else { return -1; }
    let sk = icc_fpk(vals[cv].ty);
    let dk = icc_fpk(dty);
    let clo = icc_cfp_lo(cv);
    let chi = icc_cfp_hi(cv);
    if !icc_fp_is_finite(sk, clo, chi) { return -1; }
    let nlo, nhi = icc_fp_next(sk, clo, chi, down);
    let elo0, ehi0 = icc_fp_conv(sk, dk, clo, chi);
    var enlo, enhi = icc_fp_conv(sk, dk, nlo, nhi);
    let next_inf = icc_fp_is_inf(sk, nlo, nhi);
    if next_inf {
        let plo, phi = icc_fp_next(sk, clo, chi, !down);
        let dlo, dhi = fp_arith(sk, FOP_SUB, clo, chi, plo, phi);
        let blo, bhi = icc_fp_conv(sk, dk, dlo, dhi);
        let a, b = fp_arith(dk, FOP_ADD, elo0, ehi0, blo, bhi);
        enlo = a; enhi = b;
    }
    let slo, shi = fp_arith(dk, FOP_ADD, elo0, ehi0, enlo, enhi);
    var mlo, mhi = fp_scalbn(dk, slo, shi, -1);
    let bl, bh = icc_fp_conv(dk, sk, mlo, mhi);
    if fp_compare(sk, bl, bh, clo, chi) != 1 {
        let a, b = icc_fp_next(dk, mlo, mhi, !down);
        mlo = a; mhi = b;
    }
    if next_inf {
        let xl, xh = icc_fp_conv(dk, sk, mlo, mhi);
        if icc_fp_is_inf(sk, xl, xh) { return -1; }
        let nl2, nh2 = icc_fp_next(dk, mlo, mhi, down);
        let yl, yh = icc_fp_conv(dk, sk, nl2, nh2);
        if icc_fp_is_finite(sk, yl, yh) { return -1; }
    }
    return icc_new_fcmp(p, op(fpt, 0), icc_cfp(dty, mlo, mhi), i);
}

// APFloat::isSmallestNormalized (either sign)
fn icc_fp_is_smallest_normalized(c: i32) -> bool {
    let k = cfp_kind(c);
    let p = cfp_parts(c);
    if p.cat != FC_NORMAL || p.expf != 1 { return false; }
    let f = fp_fmt(k);
    // the significand is exactly the implicit/explicit integer bit
    let ib = if f.explicit_int { 63 } else { f.p - 1 };
    if ib < 64 { return p.sig0 == ((1 as u64) << ib) && p.sig1 == 0; }
    return p.sig0 == 0 && p.sig1 == ((1 as u64) << (ib - 64));
}

// foldFabsWithFcmpZero(I, IC)
fn fold_fabs_with_fcmp_zero(i: i32) -> i32 {
    let o0 = op(i, 0);
    if inst_iid(o0) != IID_fabs { return -1; }
    let x = op(o0, 0);
    let c = m_apfloat(op(i, 1));
    if c < 0 { return -1; }
    let cp_ = cfp_parts(c);
    let p = icc_pred(i);
    if !(cp_.cat == FC_ZERO && !cp_.neg) {
        if !icc_fp_is_smallest_normalized(c) { return -1; }
        let mode = fn_denormal_mode(inst_func(i), vals[c].ty);
        if dm_in(mode) == DMK_PS || dm_in(mode) == DMK_PZ {
            let z = icc_fp_zero(vals[x].ty);
            if p == P_OLT { return icc_new_fcmp(P_OEQ, x, z, i); }
            if p == P_FUGE { return icc_new_fcmp(P_UNE, x, z, i); }
            if p == P_OGE { return icc_new_fcmp(P_ONE, x, z, i); }
            if p == P_FULT { return icc_new_fcmp(P_UEQ, x, z, i); }
        }
        return -1;
    }
    if p == P_FUGE || p == P_OLT { fatal("internal: fcmp should have simplified"); }
    var np: i64 = -1;
    if p == P_OGT { np = P_ONE; }
    else if p == P_FUGT { np = P_UNE; }
    else if p == P_OLE { np = P_OEQ; }
    else if p == P_FULE { np = P_UEQ; }
    else if p == P_OGE { np = P_ORD; }
    else if p == P_FULT { np = P_UNO; }
    else if p == P_OEQ || p == P_UEQ || p == P_ONE || p == P_UNE || p == P_ORD || p == P_UNO { np = p; }
    else { return -1; }
    icc_set_pred(i, np);
    return ic_replace_operand(i, 0, x);
}

// foldSqrtWithFcmpZero(I, IC)
fn fold_sqrt_with_fcmp_zero(i: i32) -> i32 {
    let o0 = op(i, 0);
    if inst_iid(o0) != IID_sqrt { return -1; }
    let x = op(o0, 0);
    if !m_pos_zero_fp(op(i, 1)) { return -1; }
    if !icc_has_fmf(o0, FMF_NINF) { icc_set_fmf(i, FMF_NINF, false); }
    let p = icc_pred(i);
    if p == P_OLT || p == P_FUGE { fatal("internal: fcmp should have simplified"); }
    if p == P_FULT || p == P_FULE || p == P_OGT || p == P_OGE || p == P_OEQ || p == P_UNE { return ic_replace_operand(i, 0, x); }
    var np: i64 = -1;
    if p == P_OLE { np = P_OEQ; }
    else if p == P_FUGT { np = P_UNE; }
    else if p == P_UEQ { np = P_FULE; }
    else if p == P_ONE { np = P_OGT; }
    else if p == P_ORD { np = P_OGE; }
    else if p == P_UNO { np = P_FULT; }
    else { fatal("internal: unexpected predicate"); }
    icc_set_pred(i, np);
    return ic_replace_operand(i, 0, x);
}

// foldFCmpFNegCommonOp(I)
fn fold_fcmp_fneg_common_op(i: i32) -> i32 {
    var p = icc_pred(i);
    var o0 = op(i, 0);
    var o1 = op(i, 1);
    if m_fneg(o0) >= 0 && m_fneg(o1) < 0 {
        let t = o0; o0 = o1; o1 = t;
        p = icc_fcmp_swapped(icc_pred(i));
    }
    if m_fneg(o1) != o0 || o0 < 0 { return -1; }
    return icc_new_fcmp(p, o0, icc_fp_zero(vals[o0].ty), i);
}

// foldFCmpFSubIntoFCmp(I, LHSI, RHSC, CI)
fn fold_fcmp_fsub_into_fcmp(i: i32, lhsi: i32, rhsc: i32) -> i32 {
    let p = icc_pred(i);
    let x = op(lhsi, 0);
    let y = op(lhsi, 1);
    var go = false;
    if p == P_FUGT || p == P_FULT || p == P_UNE || p == P_OEQ || p == P_OGE || p == P_OLE {
        go = true;
        if !icc_has_fmf(lhsi, FMF_NNAN) && !icc_has_fmf(lhsi, FMF_NINF) {
            kb_cxt = i;
            if !is_known_never_infinity(y, 0) {
                kb_cxt = i;
                if !is_known_never_infinity(x, 0) { go = false; }
            }
        }
    } else if p == P_OGT || p == P_OLT || p == P_ONE || p == P_UEQ || p == P_FUGE || p == P_FULE { go = true; }
    if !go { return -1; }
    if m_any_zero_fp(rhsc) && fn_denormal_mode(inst_func(i), vals[lhsi].ty) == DM_IEEE {
        ic_replace_operand(i, 0, x);
        ic_replace_operand(i, 1, y);
        icc_set_fmf(i, FMF_NINF, icc_has_fmf(lhsi, FMF_NINF));
        if icc_has_fmf(lhsi, FMF_NNAN) { icc_set_fmf(i, FMF_NNAN, true); }
        return i;
    }
    let c = m_apfloat(rhsc);
    if c >= 0 && bo(lhsi, OP_FSUB) && op(lhsi, 0) == rhsc && (is_inst_op(y, OP_UITOFP) || is_inst_op(y, OP_SITOFP)) {
        let cp_ = cfp_parts(c);
        if cp_.cat == FC_NORMAL && cp_.expf != 0 {
            let mw = icc_mantissa_width(vals[lhsi].ty);
            if mw != -1 && cfp_ilogb(c) < mw {
                let z = icc_fp_zero(vals[lhsi].ty);
                icc_set_pred(i, icc_fcmp_swapped(p));
                ic_replace_operand(i, 0, y);
                ic_replace_operand(i, 1, z);
                return i;
            }
        }
    }
    return -1;
}

// foldFCmpFAbsFSubIntToFP(I, IC)
fn fold_fcmp_fabs_fsub_int_to_fp(i: i32) -> i32 {
    let o0 = op(i, 0);
    if inst_iid(o0) != IID_fabs { return -1; }
    let fa = op(o0, 0);
    let c = m_apfloat_ap(op(i, 1), true);
    if c < 0 { return -1; }
    let cp_ = cfp_parts(c);
    if cp_.cat != FC_NORMAL { return -1; }
    let p = icc_pred(i);
    let slt = p == P_OLT || p == P_FULT;
    let le = p == P_OLE || p == P_FULE;
    let sgt = p == P_OGT || p == P_FUGT;
    let ge = p == P_OGE || p == P_FUGE;
    if !slt && !sgt && !ge { return -1; }
    let k = cfp_kind(c);
    let olo, ohi = fp_from_f64(k, 1.0);
    let cmp = fp_compare(k, cint_lo(c), cint_hi(c), olo, ohi);
    if slt && cmp == 2 { return -1; }
    if ge && cmp == 2 { return -1; }
    if le && cmp != 2 { return -1; }
    if sgt && cmp != 0 { return -1; }
    if !bo(fa, OP_FSUB) { return -1; }
    let l = op(fa, 0);
    let r = op(fa, 1);
    var signed = false;
    if is_inst_op(l, OP_UITOFP) && is_inst_op(r, OP_UITOFP) { signed = false; }
    else if is_inst_op(l, OP_SITOFP) && is_inst_op(r, OP_SITOFP) { signed = true; }
    else { return -1; }
    let a = op(l, 0);
    let b = op(r, 0);
    if vals[a].ty != vals[b].ty { return -1; }
    let fty = vals[fa].ty;
    if !can_be_casted_exactly_int_to_fp(a, fty, signed, i) || !can_be_casted_exactly_int_to_fp(b, fty, signed, i) { return -1; }
    return ic_new_icmp(if slt || le { P_EQ } else { P_NE }, a, b);
}

// foldFCmpWithFloorAndCeil(I, IC)
fn fold_fcmp_with_floor_and_ceil(i: i32) -> i32 {
    var lhs = op(i, 0);
    var rhs = op(i, 1);
    let oty = vals[lhs].ty;
    var p = icc_pred(i);
    var fl = inst_iid(lhs) == IID_floor && op(lhs, 0) == rhs;
    var ce = inst_iid(lhs) == IID_ceil && op(lhs, 0) == rhs;
    if !fl && !ce {
        fl = inst_iid(rhs) == IID_floor && op(rhs, 0) == lhs;
        if !fl { ce = inst_iid(rhs) == IID_ceil && op(rhs, 0) == lhs; }
        if fl || ce { let t = lhs; lhs = rhs; rhs = t; p = icc_fcmp_swapped(icc_pred(i)); }
    }
    if (fl || ce) && icc_fcmp_is_commutative(p) && has_one_use(lhs) {
        let tx = icb_unary_intrinsic(IID_trunc, rhs, "");
        return icc_new_fcmp(p, tx, rhs, i);
    }
    if p == P_OLE { if fl { return icc_new_fcmp(P_ORD, rhs, icc_fp_zero(oty), i); } }
    else if p == P_OGT { if fl { return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, false)); } }
    else if p == P_OGE { if ce { return icc_new_fcmp(P_ORD, rhs, icc_fp_zero(oty), i); } }
    else if p == P_OLT { if ce { return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, false)); } }
    else if p == P_FULE { if fl { return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, true)); } }
    else if p == P_FUGT { if fl { return icc_new_fcmp(P_UNO, rhs, icc_fp_zero(oty), i); } }
    else if p == P_FUGE { if ce { return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, true)); } }
    else if p == P_FULT { if ce { return icc_new_fcmp(P_UNO, rhs, icc_fp_zero(oty), i); } }
    return -1;
}

// isMinMaxCmpSelectEliminable(Flavor, A, B)
fn is_minmax_cmp_select_eliminable(f: i64, a: i32, b: i32) -> bool {
    let c = m_apfloat(b);
    if c < 0 { return false; }
    if !is_inst(a) || !(iop(a) == OP_SITOFP || iop(a) == OP_UITOFP) { return false; }
    let uns = iop(a) == OP_UITOFP;
    let bw = ty_sbits(op(a, 0));
    let bound = if f == SPF_FMAXNUM { if uns { ap_zero(bw) } else { ap_smin_val(bw) } } else { if uns { ap_ones(bw) } else { ap_smax_val(bw) } };
    let ok, exact, v = icc_fp_to_int(cfp_kind(c), cint_lo(c), cint_hi(c), bw, !uns, FRM_ZERO);
    return ok && exact && ap_eq(v, bound);
}

// visitFCmpInst(I)
fn visit_fcmp(i: i32) -> i32 {
    var changed = false;
    if get_complexity(op(i, 0)) < get_complexity(op(i, 1)) {
        icc_swap_operands(i);
        changed = true;
    }
    let p = icc_pred(i);
    let o0 = op(i, 0);
    let o1 = op(i, 1);
    let sv = simplify_fcmp(p, o0, o1, insts[inst_of(i)].fmf, sq_at(i), RECURSION_LIMIT);
    if sv >= 0 { return ic_replace_inst_uses_with(i, sv); }
    let oty = vals[o0].ty;
    if o0 == o1 {
        if p == P_UNO || p == P_FULT || p == P_FUGT || p == P_UNE {
            icc_set_pred(i, P_UNO);
            set_op(i, 1, c_null(oty));
            return i;
        }
        if p == P_ORD || p == P_OEQ || p == P_OGE || p == P_OLE {
            icc_set_pred(i, P_ORD);
            set_op(i, 1, c_null(oty));
            return i;
        }
    }
    if icc_fcmp_is_commutative(p) {
        if match_symmetric_pair(op(i, 0), op(i, 1)) {
            ic_replace_operand(i, 0, sp_a);
            ic_replace_operand(i, 1, sp_b);
            return i;
        }
    }
    if p == P_ORD || p == P_UNO {
        if !m_pos_zero_fp(o0) { kb_cxt = i; if is_known_never_nan(o0, 0) { return ic_replace_operand(i, 0, icc_fp_zero(oty)); } }
        if !m_pos_zero_fp(o1) { kb_cxt = i; if is_known_never_nan(o1, 0) { return ic_replace_operand(i, 1, icc_fp_zero(oty)); } }
    }
    let nx = m_fneg(o0);
    let ny = m_fneg(o1);
    if nx >= 0 && ny >= 0 { return icc_new_fcmp(icc_fcmp_swapped(p), nx, ny, i); }
    var r = fold_fcmp_fneg_common_op(i);
    if r >= 0 { return r; }
    if has_one_use(i) {
        let si = icc_user_back(i);
        if is_select_inst(si) {
            let f = match_select_pattern_v(si, 0);
            var redundant = false;
            if f == SPF_FMAXNUM || f == SPF_FMINNUM { redundant = is_minmax_cmp_select_eliminable(f, sp_lhs, sp_rhs); }
            if f != SPF_UNKNOWN && !redundant { return -1; }
        }
    }
    if m_any_zero_fp(o1) && !m_pos_zero_fp(o1) { return ic_replace_operand(i, 1, icc_fp_zero(oty)); }
    let ci = m_apfloat(o1);
    if ci >= 0 && cfp_parts(ci).cat == FC_INF {
        let sp = if cfp_parts(ci).neg { icc_fcmp_swapped(p) } else { p };
        if sp == P_ORD || sp == P_UNO || sp == P_TRUE || sp == P_FALSE || sp == P_OGT || sp == P_FULE { fatal("internal: Should be simplified by InstSimplify"); }
        if sp == P_OLT { return icc_new_fcmp(P_ONE, o0, o1, i); }
        if sp == P_OLE { return icc_new_fcmp(P_ORD, o0, icc_fp_zero(oty), i); }
        if sp == P_OGE { return icc_new_fcmp(P_OEQ, o0, o1, i); }
        if sp == P_FULT { return icc_new_fcmp(P_UNE, o0, o1, i); }
        if sp == P_FUGT { return icc_new_fcmp(P_UNO, o0, icc_fp_zero(oty), i); }
        if sp == P_FUGE { return icc_new_fcmp(P_UEQ, o0, o1, i); }
    }
    if m_pos_zero_fp(o1) && one_use(o0) && is_inst_op(o0, OP_BITCAST) && ic_elementwise_bitcast(o0) && is_int_or_int_vec(vals[op(o0, 0)].ty) {
        let mode = fn_denormal_mode(inst_func(i), vals[o1].ty);
        let may_zero = dm_inputs_are_zero(mode) || dm_in(mode) == DMK_DYN;
        if !may_zero {
            var ip: i64 = -1;
            if p == P_OEQ { ip = P_EQ; } else if p == P_UNE { ip = P_NE; }
            if ip >= 0 {
                let x = op(o0, 0);
                let ity = vals[x].ty;
                let sm = ap_not(ap_sign_mask(ty_scalar_bits(ity)));
                let mx = icb_and(x, c_int_ap(ity, sm), "");
                return ic_new_icmp(ip, mx, c_null(ity));
            }
        }
    }
    if is_inst(o0) && is_constant(o1) {
        let lhsi = o0;
        let rhsc = o1;
        let o = iop(lhsi);
        if o == OP_SELECT {
            if icc_fcmp_is_equality(p) && m_any_zero_fp(rhsc) {
                let t = op(lhsi, 1);
                let f = op(lhsi, 2);
                if m_fneg(t) >= 0 && m_fneg(t) == f { return ic_replace_operand(i, 0, f); }
                if m_fneg(f) >= 0 && m_fneg(f) == t { return ic_replace_operand(i, 0, t); }
            }
            r = fold_op_into_select(i, lhsi, false, false);
            if r >= 0 { return r; }
        } else if o == OP_FSUB {
            if has_one_use(lhsi) {
                r = fold_fcmp_fsub_into_fcmp(i, lhsi, rhsc);
                if r >= 0 { return r; }
            }
        } else if o == OP_PHI {
            r = fold_op_into_phi(i, lhsi, false);
            if r >= 0 { return r; }
        } else if o == OP_SITOFP || o == OP_UITOFP {
            r = fold_fcmp_int_to_fp_const(i, lhsi, rhsc);
            if r >= 0 { return r; }
        } else if o == OP_FDIV {
            r = fold_fcmp_reciprocal_and_zero(i, lhsi, rhsc);
            if r >= 0 { return r; }
        } else if o == OP_LOAD {
            if is_inst_op(op(lhsi, 0), OP_GEP) {
                r = fold_cmp_load_from_indexed_global(lhsi, op(lhsi, 0), i, -1);
                if r >= 0 { return r; }
            }
        } else if o == OP_FPTRUNC {
            r = fold_fcmp_fp_trunc(i, lhsi, rhsc);
            if r >= 0 { return r; }
        }
    }
    r = fold_fabs_with_fcmp_zero(i);
    if r >= 0 { return r; }
    r = fold_fcmp_fabs_fsub_int_to_fp(i);
    if r >= 0 { return r; }
    r = fold_sqrt_with_fcmp_zero(i);
    if r >= 0 { return r; }
    r = fold_fcmp_with_floor_and_ceil(i);
    if r >= 0 { return r; }
    r = fold_cmp_select_of_constants(i);
    if r >= 0 { return r; }
    if nx >= 0 && is_constant(o1) {
        let nc = cf_fold_unary(OP_FNEG, o1);
        if nc >= 0 { return icc_new_fcmp(icc_fcmp_swapped(p), nx, nc, i); }
    }
    if bo(o0, OP_FADD) && m_any_zero_fp(op(o0, 1)) { return icc_new_fcmp(p, op(o0, 0), o1, i); }
    if bo(o1, OP_FADD) && m_any_zero_fp(op(o1, 1)) { return icc_new_fcmp(p, o0, op(o1, 0), i); }
    if (p == P_ORD || p == P_UNO) && is_inst_op(o0, OP_FPTRUNC) && is_inst_op(o1, OP_FPTRUNC) && vals[op(o0, 0)].ty == vals[op(o1, 0)].ty {
        return icc_new_fcmp(p, op(o0, 0), op(o1, 0), i);
    }
    if is_inst_op(o0, OP_FPEXT) {
        let x = op(o0, 0);
        if is_inst_op(o1, OP_FPEXT) && vals[x].ty == vals[op(o1, 0)].ty { return icc_new_fcmp(p, x, op(o1, 0), i); }
        let c = m_apfloat(o1);
        if c >= 0 {
            let sk = cfp_kind(c);
            let dk = icc_fpk(vals[x].ty);
            let tlo, thi = icc_fp_conv(sk, dk, cint_lo(c), cint_hi(c));
            let blo, bhi = icc_fp_conv(dk, sk, tlo, thi);
            let lossy = blo != cint_lo(c) || bhi != cint_hi(c);
            if lossy {
                if p == P_OEQ { return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, false)); }
                if p == P_ONE { return icc_new_fcmp(P_ORD, x, icc_fp_zero(vals[x].ty), -1); }
                if p == P_UEQ { return icc_new_fcmp(P_UNO, x, icc_fp_zero(vals[x].ty), -1); }
                if p == P_UNE { return ic_replace_inst_uses_with(i, c_bool_ty(vals[i].ty, true)); }
            }
            let tp = fp_decompose(dk, tlo, thi);
            // Fabs.isZero() || !(Fabs < getSmallestNormalized): a zero, a normal, an infinity or a NaN
            if !lossy && (tp.cat == FC_ZERO || !(tp.cat == FC_NORMAL && tp.expf == 0)) {
                return icc_new_fcmp(p, x, icc_cfp(vals[x].ty, tlo, thi), i);
            }
        }
    }
    if one_use(o0) && inst_iid(o0) == IID_copysign && m_any_zero_fp(o1) {
        let c = m_apfloat(op(o0, 0));
        if c >= 0 {
            let cpp = cfp_parts(c);
            if cpp.cat != FC_ZERO && cpp.cat != FC_NAN {
                let x = op(o0, 1);
                let ity = ty_with_elem(oty, ty_int(ty_scalar_bits(vals[x].ty)));
                if p == P_OLT {
                    let ix = icb_cast(OP_BITCAST, x, ity, "");
                    return ic_new_icmp(P_SLT, ix, c_null(ity));
                }
            }
        }
    }
    {
        let cl = if inst_iid(o0) == IID_canonicalize { op(o0, 0) } else { -1 };
        if cl >= 0 && cl == o1 { return icc_new_fcmp(p, o1, o1, i); }
        let cr = if inst_iid(o1) == IID_canonicalize { op(o1, 0) } else { -1 };
        if cr >= 0 && cr == o0 { return icc_new_fcmp(p, o0, o0, i); }
        if cl >= 0 && cr >= 0 { return icc_new_fcmp(p, cl, cr, i); }
    }
    if ty_is_vector(vals[i].ty) {
        r = fold_vector_cmp(i);
        if r >= 0 { return r; }
    }
    return if changed { i } else { -1 };
}

// m_ConstantInt(uint64_t &): an int or splat (no poison) whose value fits in 64 bits
fn icc_m_cint_u64(v: i32) -> bool { has_apint(v) && ap_fits_u64(ap_c(v)) }
