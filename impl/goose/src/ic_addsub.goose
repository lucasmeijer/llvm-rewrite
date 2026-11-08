// InstCombine add/sub: port of llvm/lib/Transforms/InstCombine/InstCombineAddSub.cpp (visitAdd, visitSub and
// their helpers; the FP visitors are not ported and fail loudly).
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
import implied;
import constrange;
import instsimplify;
import apint;
import overflow;
import ic;
import ic_builder;
import ic_common;
import ic_negator;
import ic_demanded;
import ic_shifts;

// ---------------------------------------------------------------------------------------------
// visitAdd helpers

// checkForNegativeOperand(I, Builder)
fn check_for_negative_operand(i: i32) -> i32 {
    var lhs = op(i, 0);
    var rhs = op(i, 1);
    if !one_use(lhs) && !one_use(rhs) { return -1; }
    if bo(rhs, OP_ADD) && m_one(op(rhs, 1)) { let t = lhs; lhs = rhs; rhs = t; }
    if bo(lhs, OP_ADD) && m_one(op(lhs, 1)) {
        var x = op(lhs, 0);
        if bo(rhs, OP_XOR) && has_apint(op(rhs, 1)) { let t = x; x = rhs; rhs = t; }
        if bo(x, OP_XOR) && has_apint(op(x, 1)) {
            let y = op(x, 0);
            let c1 = ap_c(op(x, 1));
            if bo(y, OP_OR) && has_apint(op(y, 1)) && ap_eq(ap_c(op(y, 1)), ap_not(c1)) {
                let na = icb_and(op(y, 0), c_int_ap(vals[op(y, 0)].ty, c1), "");
                return icb_sub(rhs, na, "sub");
            } else if bo(y, OP_AND) && has_apint(op(y, 1)) && ap_eq(c1, ap_c(op(y, 1))) {
                let no = icb_or(op(y, 0), c_int_ap(vals[op(y, 0)].ty, ap_not(c1)), "");
                return icb_sub(rhs, no, "sub");
            }
        }
    }
    lhs = op(i, 0);
    rhs = op(i, 1);
    if bo(rhs, OP_XOR) && has_apint(op(rhs, 1)) { let t = lhs; lhs = rhs; rhs = t; }
    if bo(lhs, OP_XOR) && has_apint(op(lhs, 1)) {
        let c1 = ap_c(op(lhs, 1));
        let y = op(lhs, 0);
        if ap_countr_zero(c1) == 0 {
            if bo(y, OP_AND) && has_apint(op(y, 1)) && ap_eq(c1, ap_inc(ap_c(op(y, 1)))) {
                let c2 = ap_c(op(y, 1));
                let no = icb_or(op(y, 0), c_int_ap(vals[op(y, 0)].ty, ap_not(c2)), "");
                return icb_sub(rhs, no, "sub");
            }
        }
    }
    return -1;
}

// foldNoWrapAdd(Add, Builder)
fn fold_no_wrap_add(add: i32) -> i32 {
    let op0 = op(add, 0);
    let op1 = op(add, 1);
    let ty = vals[add].ty;
    if !is_const(op1) { return -1; }
    let zx = m_zext(op0);
    if has_apint(op1) && zx >= 0 && m_nuw_add_like(zx) && has_apint(op(zx, 1)) {
        let c1 = ap_c(op1);
        let x = op(zx, 0);
        let c2 = ap_c(op(zx, 1));
        if ap_is_neg(c1) && ap_sge(c1, ap_neg(ap_sext(c2, c1.w as i64))) {
            let nc = ap_add(c2, ap_trunc(c1, c2.w as i64));
            if ap_is_zero(nc) { return ic_new_cast(OP_ZEXT, x, ty); }
            if one_use(op0) {
                let na = icb_add_nw(x, c_int_ap(vals[x].ty, nc), "", true, false);
                return ic_new_cast(OP_ZEXT, na, ty);
            }
        }
    }
    if one_use(op0) {
        let sx = m_sext_like(op0);
        if sx >= 0 && m_nsw_add_like(sx) && is_const(op(sx, 1)) {
            let x = op(sx, 0);
            let wc = icb_sext(op(sx, 1), ty, "");
            let nc = icb_add(wc, op1, "");
            let wx = icb_sext(x, ty, "");
            return ic_new_binop(OP_ADD, wx, nc);
        }
        if zx >= 0 && m_nuw_add_like(zx) && is_const(op(zx, 1)) {
            let x = op(zx, 0);
            let wc = icb_zext(op(zx, 1), ty, "");
            let nc = icb_add(wc, op1, "");
            let wx = icb_zext(x, ty, "");
            return ic_new_binop(OP_ADD, wx, nc);
        }
    }
    return -1;
}

// foldAddWithConstant(Add)
fn fold_add_with_constant(add: i32) -> i32 {
    let op0 = op(add, 0);
    let op1 = op(add, 1);
    let ty = vals[add].ty;
    if !is_imm_c(op1) { return -1; }
    let nv = fold_binop_into_select_or_phi(add);
    if nv >= 0 { return nv; }
    let fl = fold_binop_select_binop(add);
    if fl >= 0 { return fl; }
    // add (sub C1, X), C2 --> sub (add C1, C2), X
    if bo(op0, OP_SUB) && is_const(op(op0, 0)) {
        return ic_new_binop(OP_SUB, ce_binop(OP_ADD, op(op0, 0), op1, 0), op(op0, 1));
    }
    // add (sub X, Y), -1 --> add (not Y), X
    if bo(op0, OP_SUB) && one_use(op0) && m_all_ones(op1) {
        let ny = icb_not(op(op0, 1), "");
        return ic_new_binop(OP_ADD, ny, op(op0, 0));
    }
    // zext(bool) + C -> bool ? C + 1 : C
    let zx = m_zext(op0);
    if zx >= 0 && ty_sbits(zx) == 1 { return ic_new_select_unknown_prof(zx, add_one(op1), op1); }
    let sx = m_sext(op0);
    if sx >= 0 && ty_sbits(sx) == 1 { return ic_new_select_unknown_prof(sx, sub_one(op1), op1); }
    // ~X + C --> (C-1) - X
    let nx = m_not(op0);
    if nx >= 0 {
        let cone = c_int_ty(vals[op1].ty, 1);
        let wnsov = will_not_overflow_signed_sub(op1, cone, add);
        let r = ic_new_binop(OP_SUB, ce_binop(OP_SUB, op1, cone, 0), nx);
        set_nsw(r, op_nsw(add) && wnsov);
        return r;
    }
    let bw = ty_scalar_bits(ty);
    // (iN X s>> (N - 1)) + 1 --> zext (X > -1)
    if bo(op0, OP_ASHR) && one_use(op0) && m_specific_int_allow_poison(op(op0, 1), (bw - 1) as u64) && m_one(op1) {
        let c = icb_icmp(38, op(op0, 0), c_all_ones(vals[op(op0, 0)].ty), "isnotneg");
        return ic_new_cast(OP_ZEXT, c, ty);
    }
    if !has_apint(op1) { return -1; }
    let c = ap_c(op1);
    // (X | Op01C) + Op1C --> X + (Op01C + Op1C) iff the `or` is actually an `add`
    if m_disjoint_or(op0) && is_imm_c(op(op0, 1)) {
        let x = op(op0, 0);
        let c01 = op(op0, 1);
        let na = ic_new_binop(OP_ADD, x, ce_binop(OP_ADD, c01, op1, 0));
        set_nsw(na, op_nsw(add) && will_not_overflow_signed_add(c01, op1, add));
        set_nuw(na, op_nuw(add));
        return na;
    }
    // (X | C2) + C --> (X | C2) ^ C2 iff (C2 == -C)
    if bo(op0, OP_OR) && has_apint(op(op0, 1)) && ap_eq(ap_c(op(op0, 1)), ap_neg(c)) {
        return ic_new_binop(OP_XOR, op0, c_int_ap(ty, ap_c(op(op0, 1))));
    }
    if ap_is_sign_mask(c) {
        if op_nsw(add) || op_nuw(add) { return ic_new_binop_flags(OP_OR, op0, op1, FL_DISJOINT); }
        return ic_new_binop(OP_XOR, op0, op1);
    }
    // add(zext(xor i16 X, -32768), -32768) --> sext X
    if zx >= 0 && bo(zx, OP_XOR) && has_apint(op(zx, 1)) {
        let c2 = ap_c(op(zx, 1));
        if ap_is_min_signed(c2) && ap_eq(ap_sext(c2, bw), c) { return ic_new_cast(OP_SEXT, op(zx, 0), ty); }
    }
    if bo(op0, OP_XOR) && has_apint(op(op0, 1)) {
        let x = op(op0, 0);
        let c2 = ap_c(op(op0, 1));
        if ap_is_sign_mask(c2) { return ic_new_binop(OP_ADD, x, c_int_ap(ty, ap_xor(c2, c))); }
        kb_cxt = add;
        let lk = kb_compute_all(x, 0);
        if ap_is_all_ones(ap_or(c2, lk.z)) { return ic_new_binop(OP_SUB, c_int_ap(ty, ap_add(c2, c)), x); }
        if one_use(op0) && ap_eq(c2, ap_neg(c)) {
            var sh: i64 = 0;
            if ap_is_pow2(c) { sh = bw - ap_log2(c) - 1; }
            else if ap_is_pow2(c2) { sh = bw - ap_log2(c2) - 1; }
            kb_cxt = add;
            if sh != 0 && masked_value_is_zero(x, ap_high_bits(bw, sh), 0) {
                let shc = c_int_ty(ty, sh as u64);
                let nsh = icb_shl(x, shc, "sext");
                return ic_new_binop(OP_ASHR, nsh, shc);
            }
        }
    }
    if ap_is_one(c) && one_use(op0) {
        if sx >= 0 && ty_sbits(sx) == 1 {
            let n = icb_not(sx, "");
            return ic_new_cast(OP_ZEXT, n, ty);
        }
        if bo(op0, OP_ASHR) && bo(op(op0, 0), OP_SHL) && has_apint(op(op(op0, 0), 1)) && has_apint(op(op0, 1)) {
            let c2v = m_apint(op(op(op0, 0), 1));
            let c3v = m_apint(op(op0, 1));
            // C2 == C3 compares the APInt pointers: the same constant
            if c2v == c3v && ap_eq_u64(ci_ap(c2v), (bw - 1) as u64) {
                let n = icb_not(op(op(op0, 0), 0), "");
                return ic_new_binop(OP_AND, n, c_int_ty(ty, 1));
            }
        }
    }
    // umax(X, C) + -C --> usub.sat(X, C)
    if one_use(op0) && inst_iid(op0) == IID_umax && m_specific_int_apv(op(op0, 1), ap_neg(c)) {
        return ic_replace_inst_uses_with(add, icb_binary_intrinsic(IID_usub_sat, op(op0, 0), c_int_ap(ty, ap_neg(c)), ""));
    }
    // (add (zext (add X, -C)), C) -> (zext X) if X u>= C
    if zx >= 0 && bo(zx, OP_ADD) && has_apint_poison(op(zx, 1)) {
        let x = op(zx, 0);
        let ic = ap_cp(op(zx, 1));
        let nbw = ic.w as i64;
        if ap_is_int_n(c, nbw) {
            let ncv = ap_trunc(c, nbw);
            if ap_eq(ic, ap_neg(ncv)) {
                var ok = false;
                if ap_is_one(ncv) { kb_cxt = add; ok = is_known_non_zero(x, 0); }
                else { kb_cxt = add; ok = ap_uge(kb_min(kb_compute_all(x, 0)), ncv); }
                if ok { return ic_new_cast(OP_ZEXT, x, ty); }
            }
        }
    }
    return -1;
}
fn m_specific_int_allow_poison(v: i32, x: u64) -> bool {
    let c = m_apint_ap(v, true);
    return c >= 0 && ap_eq_u64(ci_ap(c), x);
}

// matchesSquareSum</*FP*/ false>(I, m_SpecificInt(1), A, B)
fn matches_square_sum_int(i: i32) -> bool {
    // (a * a) + (((a << 1) + b) * b)
    for k in 2 {
        let m = op(i, k);
        let r = op(i, 1 - k);
        if one_use(m) && bo(m, OP_MUL) && op(m, 0) == op(m, 1) && one_use(r) && bo(r, OP_MUL) {
            let a = op(m, 0);
            for j in 2 {
                let ad = op(r, j);
                let b = op(r, 1 - j);
                if bo(ad, OP_ADD) {
                    for q in 2 {
                        let sh = op(ad, q);
                        if bo(sh, OP_SHL) && op(sh, 0) == a && m_specific_int(op(sh, 1), 1) && op(ad, 1 - q) == b { ssq_a = a; ssq_b = b; return true; }
                    }
                }
            }
        }
    }
    // ((a * b) << 1) or ((a << 1) * b)  +  (a * a + b * b)
    for k in 2 {
        let l = op(i, k);
        let r = op(i, 1 - k);
        var a: i32 = -1;
        var b: i32 = -1;
        if one_use(l) && bo(l, OP_SHL) && bo(op(l, 0), OP_MUL) && m_specific_int(op(l, 1), 1) { a = op(op(l, 0), 0); b = op(op(l, 0), 1); }
        else if one_use(l) && bo(l, OP_MUL) {
            for j in 2 {
                let sh = op(l, j);
                if a < 0 && bo(sh, OP_SHL) && m_specific_int(op(sh, 1), 1) { a = op(sh, 0); b = op(l, 1 - j); }
            }
        }
        if a < 0 { continue; }
        if one_use(r) && bo(r, OP_ADD) {
            for j in 2 {
                let x = op(r, j);
                let y = op(r, 1 - j);
                if bo(x, OP_MUL) && op(x, 0) == a && op(x, 1) == a && bo(y, OP_MUL) && op(y, 0) == b && op(y, 1) == b { ssq_a = a; ssq_b = b; return true; }
            }
        }
    }
    return false;
}
var ssq_a: i32 = -1;
var ssq_b: i32 = -1;
fn fold_square_sum_int(i: i32) -> i32 {
    if matches_square_sum_int(i) {
        let ab = icb_add(ssq_a, ssq_b, "");
        return ic_new_binop(OP_MUL, ab, ab);
    }
    return -1;
}

// MatchMul / MatchRem / MatchDiv (results in mr_op / mr_c / mr_signed)
var mr_op: i32 = -1;
var mr_c: AP;
var mr_signed: bool = false;
fn match_mul(e: i32) -> bool {
    if bo(e, OP_MUL) && has_apint(op(e, 1)) { mr_op = op(e, 0); mr_c = ap_c(op(e, 1)); return true; }
    if bo(e, OP_SHL) && has_apint(op(e, 1)) {
        mr_op = op(e, 0);
        let s = ap_c(op(e, 1));
        mr_c = ap_shl_ap(ap_u64(1, s.w as i64), s);
        return true;
    }
    return false;
}
fn match_rem(e: i32) -> bool {
    mr_signed = false;
    if bo(e, OP_SREM) && has_apint(op(e, 1)) { mr_signed = true; mr_op = op(e, 0); mr_c = ap_c(op(e, 1)); return true; }
    if bo(e, OP_UREM) && has_apint(op(e, 1)) { mr_op = op(e, 0); mr_c = ap_c(op(e, 1)); return true; }
    if bo(e, OP_AND) && has_apint(op(e, 1)) && ap_is_pow2(ap_inc(ap_c(op(e, 1)))) { mr_op = op(e, 0); mr_c = ap_inc(ap_c(op(e, 1))); return true; }
    return false;
}
fn match_div(e: i32, signed: bool) -> bool {
    if signed && bo(e, OP_SDIV) && has_apint(op(e, 1)) { mr_op = op(e, 0); mr_c = ap_c(op(e, 1)); return true; }
    if !signed {
        if bo(e, OP_UDIV) && has_apint(op(e, 1)) { mr_op = op(e, 0); mr_c = ap_c(op(e, 1)); return true; }
        if bo(e, OP_LSHR) && has_apint(op(e, 1)) {
            mr_op = op(e, 0);
            let s = ap_c(op(e, 1));
            mr_c = ap_shl_ap(ap_u64(1, s.w as i64), s);
            return true;
        }
    }
    return false;
}
fn mul_will_overflow(a: AP, b: AP, signed: bool) -> bool {
    if signed { let r, o = ap_smul_ov(a, b); return o; }
    let r, o = ap_umul_ov(a, b);
    return o;
}

// SimplifyAddWithRemainder(I)
fn simplify_add_with_remainder(i: i32) -> i32 {
    let lhs = op(i, 0);
    let rhs = op(i, 1);
    var x: i32 = -1; var c0 = ap_zero(1); var signed = false;
    var mulopv: i32 = -1; var mulopc = ap_zero(1);
    var m = false;
    if match_rem(lhs) {
        x = mr_op; c0 = mr_c; signed = mr_signed;
        if match_mul(rhs) { mulopv = mr_op; mulopc = mr_c; m = true; }
    }
    if !m && match_rem(rhs) {
        x = mr_op; c0 = mr_c; signed = mr_signed;
        if match_mul(lhs) { mulopv = mr_op; mulopc = mr_c; m = true; }
    }
    if m && ap_eq(c0, mulopc) {
        if match_rem(mulopv) && signed == mr_signed {
            let remopv = mr_op;
            let c1 = mr_c;
            if match_div(remopv, signed) && x == mr_op && ap_eq(c0, mr_c) && !mul_will_overflow(c0, c1, signed) {
                let nd = c_int_ap(vals[x].ty, ap_mul(c0, c1));
                return if signed { icb_srem(x, nd, "srem") } else { icb_urem(x, nd, "urem") };
            }
        }
    }
    let r = sawr_fold_div_rem(i, lhs, rhs);
    if r >= 0 { return r; }
    return sawr_fold_div_rem(i, rhs, lhs);
}
fn sawr_fold_div_rem(i: i32, div_side: i32, rem_side: i32) -> i32 {
    let bw = ty_scalar_bits(vals[i].ty);
    var div: i32 = div_side; var c1 = ap_u64(1, bw);
    if one_use(div_side) && match_mul(div_side) { div = mr_op; c1 = mr_c; }
    var rem: i32 = rem_side; var c2 = ap_u64(1, bw);
    if one_use(rem_side) && match_mul(rem_side) { rem = mr_op; c2 = mr_c; }
    if !match_rem(rem) { return -1; }
    let x = mr_op; let c0 = mr_c; let signed = mr_signed;
    if !match_div(div, signed) { return -1; }
    let divopv = mr_op; let divopc = mr_c;
    if x != divopv || !ap_eq(c0, divopc) { return -1; }
    if ap_is_one(c1) && !signed && ap_is_pow2(divopc) && !ap_eq_u64(divopc, 2) { return -1; }
    let nc = ap_sub(c1, ap_mul(c2, c0));
    if !ap_is_zero(nc) && !one_use(rem) { return -1; }
    if !is_guaranteed_not_to_be_undef(x, i, 0) { return -1; }
    let mxc2 = icb_mul(x, c_int_ap(vals[x].ty, c2), "");
    if ap_is_zero(nc) { return mxc2; }
    let m1 = icb_mul(div, c_int_ap(vals[x].ty, nc), "");
    return icb_add(m1, mxc2, "");
}

// canonicalizeLowbitMask(I, Builder)
fn canonicalize_lowbit_mask(i: i32) -> i32 {
    let s = op(i, 0);
    if !(bo(s, OP_SHL) && one_use(s) && m_one(op(s, 0)) && m_all_ones(op(i, 1))) { return -1; }
    let nbits = op(s, 1);
    let m1 = c_all_ones(vals[nbits].ty);
    let nm = icb_shl(m1, nbits, "notmask");
    if is_binop_inst(nm) { set_nsw(nm, true); set_nuw(nm, op_nuw(i)); }
    let r = ic_new_not(nm);
    ic_set_pending_name(r, i);
    return r;
}
// BinaryOperator::Create(..., I.getName()) for a result: the name is overwritten by takeName in run(),
// so a pending name on an unattached result has no visible effect; kept for documentation.
fn ic_set_pending_name(r: i32, i: i32) { }

// foldToUnsignedSaturatedAdd(I)
fn fold_to_unsigned_saturated_add(i: i32) -> i32 {
    let ty: i32 = vals[i].ty;
    for k in 2 {
        let mn = op(i, k);
        let y = op(i, 1 - k);
        if inst_iid(mn) == IID_umin {
            for j in 2 {
                if m_not_of(op(mn, j), y) {
                    return ic_new_intrinsic(IID_uadd_sat, [ty], [op(mn, 1 - j), y]);
                }
            }
        }
    }
    let mn = op(i, 0);
    if inst_iid(mn) == IID_umin && has_apint(op(mn, 1)) && has_apint(op(i, 1)) {
        let c = ap_c(op(i, 1));
        if ap_eq(c, ap_not(ap_c(op(mn, 1)))) { let cc = c_int_ap(ty, c); let x = op(mn, 0); return ic_new_intrinsic(IID_uadd_sat, [ty], [x, cc]); }
    }
    return -1;
}

// combineAddSubWithShlAddSub(Builder, I)
fn combine_add_sub_with_shl_add_sub(i: i32) -> i32 {
    for k in 2 {
        let s = op(i, k);
        let a = op(i, 1 - k);
        if one_use(s) && bo(s, OP_SHL) && one_use(op(s, 0)) && m_neg(op(s, 0)) >= 0 {
            let b = m_neg(op(s, 0));
            let ns = icb_shl(b, op(s, 1), "");
            return ic_new_binop(OP_SUB, a, ns);
        }
    }
    return -1;
}

// foldAddToAshr(Add)
fn fold_add_to_ashr(add: i32) -> i32 {
    let d = op(add, 0);
    if !bo(d, OP_SDIV) || !m_power2(op(d, 1)) { return -1; }
    let x = op(d, 0);
    let divc = ap_c(op(d, 1));
    if ap_is_neg(divc) { return -1; }
    let s = m_sext(op(add, 1));
    if s < 0 || !is_inst_op(s, OP_ICMP) { return -1; }
    let a = op(s, 0);
    if !bo(a, OP_AND) || op(a, 0) != x || !has_apint(op(a, 1)) || !has_apint(op(s, 1)) { return -1; }
    let p = inst_pred(s);
    let maskc = ap_c(op(a, 1));
    let maskccmp = ap_c(op(s, 1));
    if (p != 34 || !ap_is_sign_mask(maskccmp)) && (p != 32 || !ap_eq(maskccmp, maskc)) { return -1; }
    let smin = ap_smin_val(ty_scalar_bits(vals[add].ty));
    let valid = if p == 34 { ap_eq(maskc, ap_or(smin, ap_dec(divc))) } else { ap_eq_u64(divc, 2) && ap_eq(maskc, ap_inc(smin)) };
    if !valid { return -1; }
    return ic_new_binop(OP_ASHR, x, c_int_ty(vals[add].ty, ap_exact_log2(divc) as u64));
}

// foldAddLikeCommutative(LHS, RHS, NSW, NUW)
fn fold_add_like_commutative(lhs: i32, rhs: i32, nsw: bool, nuw: bool) -> i32 {
    if bo(lhs, OP_SUB) && bo(rhs, OP_SUB) && op(rhs, 1) == op(lhs, 0) {
        let r = ic_new_binop(OP_SUB, op(rhs, 0), op(lhs, 1));
        set_nsw(r, nsw && op_nsw(lhs) && op_nsw(rhs));
        set_nuw(r, op_nuw(lhs) && op_nuw(rhs));
        return r;
    }
    if bo(lhs, OP_SHL) && bo(op(lhs, 0), OP_SDIV) && op(op(lhs, 0), 0) == rhs && has_apint(op(op(lhs, 0), 1)) && has_apint(op(lhs, 1)) {
        let c1 = ap_c(op(op(lhs, 0), 1));
        let c2 = ap_c(op(lhs, 1));
        let mc1 = ap_neg(c1);
        if ap_eq(mc1, ap_shl_ap(ap_u64(1, c2.w as i64), c2)) {
            return ic_new_binop(OP_SREM, rhs, c_int_ap(vals[rhs].ty, mc1));
        }
    }
    if bo(lhs, OP_ADD) {
        for k in 2 {
            if !has_apint(op(lhs, 1 - k)) { continue; }
            let a = op(lhs, k);
            let c1 = ap_c(op(lhs, 1 - k));
            if bo(rhs, OP_AND) {
                for j in 2 {
                    if m_specific_int_apv(op(rhs, 1 - j), ap_not(c1)) {
                        let b = op(rhs, j);
                        if !one_use(lhs) && !one_use(rhs) { return -1; }
                        let nsw_out = nsw && op_nsw(lhs);
                        let nuw_out = nuw && op_nuw(lhs);
                        let no = icb_or(b, c_int_ap(vals[lhs].ty, c1), "");
                        let na = ic_new_binop(OP_ADD, a, no);
                        set_nsw(na, nsw_out);
                        set_nuw(na, nuw_out);
                        return na;
                    }
                }
            }
            break;
        }
    }
    return -1;
}

// canonicalizeCondSignextOfHighBitExtractToSignextHighBitExtract(I): the first match only, then not ported
fn canonicalize_cond_signext_of_high_bit_extract(i: i32) -> i32 {
    for k in 2 {
        var e = op(i, k);
        let t = m_trunc(e);
        if t >= 0 { e = t; }
        if bo(e, OP_LSHR) && is_inst(op(e, 1)) {
            if iop(i) == OP_SUB && k != 0 { continue; }
            let sel = op(i, 1 - k);
            var s = sel;
            if iop(i) == OP_SUB { let z = m_zext(s); if z >= 0 { s = z; } } else { let z = m_sext(s); if z >= 0 { s = z; } }
            if is_select_inst(s) && is_inst_op(op(s, 0), OP_ICMP) && op(op(s, 0), 0) == op(e, 0) {
                ic_not_ported("canonicalizeCondSignextOfHighBitExtractToSignextHighBitExtract");
            }
        }
    }
    return -1;
}

// factorizeMathWithShlOps(I, Builder)
fn factorize_math_with_shl_ops(i: i32) -> i32 {
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    if !is_binop_inst(op0) || !is_binop_inst(op1) || !(one_use(op0) || one_use(op1)) { return -1; }
    if !bo(op0, OP_SHL) || !bo(op1, OP_SHL) || op(op1, 1) != op(op0, 1) { return -1; }
    let x = op(op0, 0); let y = op(op1, 0); let sh = op(op0, 1);
    let nsw = op_nsw(i) && op_nsw(op0) && op_nsw(op1);
    let nuw = op_nuw(i) && op_nuw(op0) && op_nuw(op1);
    let nm = icb_binop(iop(i), x, y, "");
    if is_binop_inst(nm) { set_nsw(nm, nsw); set_nuw(nm, nuw); }
    let r = ic_new_binop(OP_SHL, nm, sh);
    set_nsw(r, nsw);
    set_nuw(r, nuw);
    return r;
}

// foldBoxMultiply(I)
fn fold_box_multiply(i: i32) -> i32 {
    let bw = ty_scalar_bits(vals[i].ty);
    if (bw & 1) != 0 { return -1; }
    let half = bw >> 1;
    let hm = ap_ones(half);
    let hmask = ap_zext(hm, bw);
    var cross: i32 = -1; var ylo: i32 = -1; var xlo: i32 = -1;
    var found = false;
    for k in 2 {
        let s = op(i, k);
        let m = op(i, 1 - k);
        if bo(s, OP_SHL) && m_specific_int(op(s, 1), half as u64) && one_use(m) && bo(m, OP_MUL) {
            cross = op(s, 0); ylo = op(m, 0); xlo = op(m, 1); found = true; break;
        }
    }
    if !found { return -1; }
    if !(bo(xlo, OP_AND) && m_specific_int_apv(op(xlo, 1), hmask)) || !(bo(ylo, OP_AND) && m_specific_int_apv(op(ylo, 1), hmask)) { return -1; }
    let x = op(xlo, 0);
    let y = op(ylo, 0);
    if bo(cross, OP_ADD) {
        for k in 2 {
            if fbm_cross_mul(op(cross, k), y, x, xlo, half) && fbm_cross_mul(op(cross, 1 - k), x, y, ylo, half) {
                return ic_new_binop(OP_MUL, x, y);
            }
        }
    }
    return -1;
}
// m_c_Mul(m_LShr(m_Specific(S), m_SpecificInt(Half)), m_CombineOr(m_Specific(A), m_Specific(ALo)))
fn fbm_cross_mul(v: i32, s: i32, a: i32, alo: i32, half: i64) -> bool {
    if !bo(v, OP_MUL) { return false; }
    for k in 2 {
        let l = op(v, k);
        let o = op(v, 1 - k);
        if bo(l, OP_LSHR) && op(l, 0) == s && m_specific_int(op(l, 1), half as u64) && (o == a || o == alo) { return true; }
    }
    return false;
}

// checkDivCeilNUW(X, Y, SQ)
fn check_div_ceil_nuw(x: i32, y: i32, cx: i32) -> bool {
    kb_cxt = cx;
    let crx = compute_constant_range(x, false, true, 0);
    kb_cxt = cx;
    let cry = compute_constant_range(y, false, true, 0);
    let miny = rg_umin(cry);
    let maxx = rg_umax(crx);
    let maxy = rg_umax(cry);
    return !ap_is_zero(miny) && !ap_ugt(maxx, ap_neg(maxy));
}

// foldDivCeil(I)
fn fold_div_ceil(i: i32) -> i32 {
    for k in 2 {
        let dp = op(i, k);
        let zc = op(i, 1 - k);
        if !one_use(dp) { continue; }
        var ud = dp;
        let z = m_zext(dp);
        if z >= 0 { ud = z; }
        if !one_use(ud) || !bo(ud, OP_UDIV) { continue; }
        let x = op(ud, 0); let y = op(ud, 1);
        if !one_use(zc) { continue; }
        let c = m_zext(zc);
        if c < 0 || !one_use(c) || !is_inst_op(c, OP_ICMP) || inst_pred(c) != 33 || !m_zero(op(c, 1)) { continue; }
        let ur = op(c, 0);
        if !one_use(ur) || !bo(ur, OP_UREM) || op(ur, 0) != x || op(ur, 1) != y { continue; }
        if !check_div_ceil_nuw(x, y, i) { return -1; }
        let ym1 = icb_add(y, c_all_ones(vals[y].ty), "");
        let nadd = icb_add_nw(x, ym1, "", true, false);
        if vals[x].ty != vals[i].ty {
            let dv = icb_udiv(nadd, y, "", false);
            return ic_new_cast(OP_ZEXT, dv, vals[i].ty);
        }
        return ic_new_binop(OP_UDIV, nadd, y);
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// visitAdd

fn visit_add(i: i32) -> i32 {
    let v0 = simplify_add(op(i, 0), op(i, 1), op_nsw(i), op_nuw(i), sq_at(i), RECURSION_LIMIT);
    if v0 >= 0 { return ic_replace_inst_uses_with(i, v0); }
    if simplify_assoc_or_comm(i) { return i; }
    let x0 = fold_vector_binop(i);
    if x0 >= 0 { return x0; }
    let ph = fold_binop_with_phi_operands(i);
    if ph >= 0 { return ph; }
    let dl = fold_using_distributive_laws(i);
    if dl >= 0 { return ic_replace_inst_uses_with(i, dl); }
    var r = fold_box_multiply(i);
    if r >= 0 { return r; }
    r = factorize_math_with_shl_ops(i);
    if r >= 0 { return r; }
    r = fold_add_with_constant(i);
    if r >= 0 { return r; }
    r = fold_no_wrap_add(i);
    if r >= 0 { return r; }
    r = fold_binop_shift_with_shift(i);
    if r >= 0 { return r; }
    r = combine_add_sub_with_shl_add_sub(i);
    if r >= 0 { return r; }
    let lhs = op(i, 0);
    let rhs = op(i, 1);
    r = fold_add_like_commutative(lhs, rhs, op_nsw(i), op_nuw(i));
    if r >= 0 { return r; }
    r = fold_add_like_commutative(rhs, lhs, op_nsw(i), op_nuw(i));
    if r >= 0 { return r; }
    let ty: i32 = vals[i].ty;
    if is_int_ty1(ty) { return ic_new_binop(OP_XOR, lhs, rhs); }
    // X + X --> X << 1
    if lhs == rhs {
        let s = ic_new_binop(OP_SHL, lhs, c_int_ty(ty, 1));
        set_nsw(s, op_nsw(i));
        set_nuw(s, op_nuw(i));
        return s;
    }
    let na = m_neg(lhs);
    if na >= 0 {
        let nb = m_neg(rhs);
        if nb >= 0 { return ic_new_neg(icb_add(na, nb, "")); }
        let s = ic_new_binop(OP_SUB, rhs, na);
        set_nsw(s, op_nsw(i) && op_nsw(lhs));
        return s;
    }
    let nb = m_neg(rhs);
    if nb >= 0 {
        let s = ic_new_binop(OP_SUB, lhs, nb);
        set_nsw(s, op_nsw(i) && op_nsw(rhs));
        return s;
    }
    let cn = check_for_negative_operand(i);
    if cn >= 0 { return ic_replace_inst_uses_with(i, cn); }
    // (A + 1) + ~B --> A - B ; ~B + (A + 1) --> A - B
    for k in 2 {
        let ad = op(i, k);
        let nt = m_not(op(i, 1 - k));
        if bo(ad, OP_ADD) && m_one(op(ad, 1)) && nt >= 0 { return ic_new_binop(OP_SUB, op(ad, 0), nt); }
    }
    // (~B + A) + 1 --> A - B ; (A + ~B) + 1 --> A - B
    if bo(lhs, OP_ADD) && m_one(rhs) {
        for k in 2 {
            let nt = m_not(op(lhs, k));
            if nt >= 0 { return ic_new_binop(OP_SUB, op(lhs, 1 - k), nt); }
        }
    }
    // (A + C) + ~B --> A - B + (C-1) (and the commuted forms)
    {
        var a: i32 = -1; var b: i32 = -1; var cc: i32 = -1;
        for k in 2 {
            let ad = op(i, k);
            let nt = m_not(op(i, 1 - k));
            if a < 0 && one_use(ad) && bo(ad, OP_ADD) && has_apint_poison(op(ad, 1)) && nt >= 0 { a = op(ad, 0); cc = op(ad, 1); b = nt; }
        }
        if a < 0 && one_use(lhs) && bo(lhs, OP_ADD) && has_apint_poison(rhs) {
            for k in 2 {
                let nt = m_not(op(lhs, k));
                if a < 0 && nt >= 0 { b = nt; a = op(lhs, 1 - k); cc = rhs; }
            }
        }
        if a >= 0 {
            let s = icb_sub(a, b, "");
            return ic_new_binop(OP_ADD, s, c_int_ap(ty, ap_dec(ap_cp(cc))));
        }
    }
    // (A + RHS) + RHS --> A + (RHS << 1)
    if one_use(lhs) && bo(lhs, OP_ADD) {
        for k in 2 {
            if op(lhs, 1 - k) == rhs { return ic_new_binop(OP_ADD, op(lhs, k), icb_shl_k(rhs, 1, "reass.add")); }
        }
    }
    if one_use(rhs) && bo(rhs, OP_ADD) {
        for k in 2 {
            if op(rhs, 1 - k) == lhs { return ic_new_binop(OP_ADD, op(rhs, k), icb_shl_k(lhs, 1, "reass.add")); }
        }
    }
    // (A + C1) + (C2 - B) --> (A - B) + (C1 + C2)
    for k in 2 {
        let ad = op(i, k);
        let sb = op(i, 1 - k);
        if bo(ad, OP_ADD) && is_imm_c(op(ad, 1)) && bo(sb, OP_SUB) && is_imm_c(op(sb, 0)) && (one_use(lhs) || one_use(rhs)) {
            let s = icb_sub(op(ad, 0), op(sb, 1), "");
            return ic_new_binop(OP_ADD, s, ce_binop(OP_ADD, op(ad, 1), op(sb, 0), 0));
        }
    }
    // (C1 - A) + B --> (B - A) + C1
    for k in 2 {
        let sb = op(i, k);
        let b = op(i, 1 - k);
        if one_use(sb) && bo(sb, OP_SUB) && is_imm_c(op(sb, 0)) {
            let s = icb_sub(b, op(sb, 1), "reass.sub");
            return ic_new_binop(OP_ADD, s, op(sb, 0));
        }
    }
    let sr = simplify_add_with_remainder(i);
    if sr >= 0 { return ic_replace_inst_uses_with(i, sr); }
    // (A & 2^C1) + A => A & (2^C1 - 1) iff bit C1 in A is a sign bit
    for k in 2 {
        let an = op(i, k);
        if bo(an, OP_AND) && has_apint(op(an, 1)) && op(i, 1 - k) == op(an, 0) {
            let a = op(an, 0);
            let c1 = ap_c(op(an, 1));
            if ap_is_pow2(c1) {
                kb_cxt = i;
                if num_sign_bits(a, 0) > ap_countl_zero(c1) {
                    return ic_new_binop(OP_AND, a, c_int_ap(vals[rhs].ty, ap_dec(c1)));
                }
            }
            break;
        }
    }
    // ZExt (B - A) + ZExt(A) --> ZExt(B)
    {
        let za = m_zext(rhs);
        let zb = m_zext(lhs);
        if za >= 0 && zb >= 0 && bo(zb, OP_SUB) && op_nuw(zb) && op(zb, 1) == za { return ic_new_cast(OP_ZEXT, op(zb, 0), vals[lhs].ty); }
        if zb >= 0 && za >= 0 && bo(za, OP_SUB) && op_nuw(za) && op(za, 1) == zb { return ic_new_cast(OP_ZEXT, op(za, 0), vals[lhs].ty); }
    }
    // zext(A) + sext(A) --> 0 if A is i1
    for k in 2 {
        let z = m_zext(op(i, k));
        let s = m_sext(op(i, 1 - k));
        if z >= 0 && s == z && is_int_ty1(vals[z].ty) { return ic_replace_inst_uses_with(i, c_null(ty)); }
    }
    // sext(A < B) + zext(A > B) => ucmp/scmp(A, B)
    for k in 2 {
        let s = m_sext(op(i, k));
        let z = m_zext(op(i, 1 - k));
        if s >= 0 && z >= 0 && is_inst_op(s, OP_ICMP) && is_inst_op(z, OP_ICMP) {
            var a = op(s, 0); var b = op(s, 1);
            var ltp = inst_pred(s);
            var gtp: i64 = -1;
            if op(z, 0) == a && op(z, 1) == b { gtp = inst_pred(z); }
            else if op(z, 0) == b && op(z, 1) == a { gtp = icmp_swapped_pred(inst_pred(z)); }
            if gtp >= 0 && is_int_or_int_vec(vals[a].ty) {
                if icmp_is_gt(ltp) { let t = ltp; ltp = gtp; gtp = t; let u = a; a = b; b = u; }
                if icmp_is_lt(ltp) && icmp_is_gt(gtp) && icmp_is_signed(ltp) == icmp_is_signed(gtp) {
                    let id = if icmp_is_signed(ltp) { IID_scmp } else { IID_ucmp };
                    return ic_replace_inst_uses_with(i, icb_intrinsic_rt(ty, id, [a, b]));
                }
            }
            break;
        }
    }
    // A+B --> A|B iff A and B have no bits set in common.
    let ncb = no_common_bits_set_result(lhs, rhs, i);
    if ncb == NCB_KNOWN { return ic_new_binop_flags(OP_OR, lhs, rhs, FL_DISJOINT); }
    if ncb == NCB_ONLY_IF_UNDEF_IGNORED { return ic_new_binop(OP_OR, lhs, rhs); }
    r = narrow_math_if_no_overflow(i);
    if r >= 0 { return r; }
    // (add (xor A, B) (and A, B)) --> (or A, B)
    for k in 2 {
        let x = op(i, k);
        let an = op(i, 1 - k);
        if bo(x, OP_XOR) && bo(an, OP_AND) && ab_same(an, op(x, 0), op(x, 1)) { return ic_new_binop(OP_OR, op(x, 0), op(x, 1)); }
    }
    // (add (or A, B) (and A, B)) --> (add A, B)
    for k in 2 {
        let o = op(i, k);
        let an = op(i, 1 - k);
        if bo(o, OP_OR) && bo(an, OP_AND) && ab_same(an, op(o, 0), op(o, 1)) {
            let a = op(o, 0); let b = op(o, 1);
            ic_replace_operand(i, 0, a);
            ic_replace_operand(i, 1, b);
            return i;
        }
    }
    // (add A (or A, -A)) --> (and (add A, -1) A)
    for k in 2 {
        let a = op(i, k);
        let o = op(i, 1 - k);
        if one_use(o) && bo(o, OP_OR) {
            var ok = false;
            for j in 2 { if op(o, j) == a && m_neg(op(o, 1 - j)) == a { ok = true; } }
            if ok {
                let ad = icb_add_nw(a, c_all_ones(vals[a].ty), "", op_nuw(i), op_nsw(i));
                return ic_new_binop(OP_AND, ad, a);
            }
        }
    }
    // ((A & -A) - 1) --> ((A - 1) & ~A)
    if one_use(lhs) && bo(lhs, OP_AND) && m_all_ones(rhs) {
        for k in 2 {
            let a = op(lhs, k);
            let ng = op(lhs, 1 - k);
            if one_use(ng) && m_neg(ng) == a {
                let ao = c_all_ones(vals[rhs].ty);
                let dec = icb_add(a, ao, "");
                let nt = icb_xor(a, ao, "");
                return ic_new_binop(OP_AND, dec, nt);
            }
        }
    }
    // ~(A * C1) + A --> (A * (1 - C1)) - 1
    for k in 2 {
        let n = op(i, k);
        let a = op(i, 1 - k);
        let m = m_not(n);
        if one_use(n) && m >= 0 && one_use(m) && bo(m, OP_MUL) && op(m, 0) == a && has_apint(op(m, 1)) {
            let c1 = ap_c(op(m, 1));
            let nmc = c_int_ap(ty, ap_sub(ap_u64(1, c1.w as i64), c1));
            let nm = icb_mul(a, nmc, "");
            return ic_new_binop(OP_ADD, nm, c_all_ones(ty));
        }
    }
    // (A * -2**C) + B --> B - (A << C)
    for k in 2 {
        let m = op(i, k);
        let b = op(i, 1 - k);
        if one_use(m) && bo(m, OP_MUL) && m_negated_power2(op(m, 1)) {
            let shc = c_int_ty(ty, ap_countr_zero(ap_c(op(m, 1))) as u64);
            let sh = icb_shl(op(m, 0), shc, "");
            return ic_new_binop(OP_SUB, b, sh);
        }
    }
    // (A s>> (BW - 1)) + (zext (A s> 0)) --> (A s>> (BW - 1)) | (zext (A != 0))
    let bw = ty_scalar_bits(ty);
    if bo(lhs, OP_ASHR) && m_specific_int_allow_poison(op(lhs, 1), (bw - 1) as u64) && one_use(rhs) {
        let a = op(lhs, 0);
        let z = m_zext(rhs);
        if z >= 0 && one_use(z) && is_inst_op(z, OP_ICMP) && inst_pred(z) == 38 && op(z, 0) == a && m_zero_int(op(z, 1)) {
            let nz = icb_is_not_null(a, "isnotnull");
            let zx = icb_zext(nz, ty, "isnotnull.zext");
            return ic_new_binop(OP_OR, lhs, zx);
        }
    }
    // (add X, (sext/zext (icmp eq X, C))) -> (select (icmp eq X, C), (add C, (sext/zext 1)), X)
    for k in 2 {
        let a = op(i, k);
        let ext = op(i, 1 - k);
        let cnd = m_zext_or_sext(ext);
        if cnd >= 0 && is_inst_op(cnd, OP_ICMP) && inst_pred(cnd) == 32 && op(cnd, 0) == a && is_imm_c(op(cnd, 1)) {
            if one_use(ext) {
                let c = op(cnd, 1);
                let av = if iop(ext) == OP_ZEXT { add_one(c) } else { sub_one(c) };
                return ic_replace_inst_uses_with(i, icb_select(cnd, av, a, "", -1));
            }
            break;
        }
    }
    // (add (add A, 1), (sext (icmp ne A, 0))) => call umax(A, 1)
    if bo(lhs, OP_ADD) && m_one(op(lhs, 1)) && one_use(rhs) {
        let a = op(lhs, 0);
        let s = m_sext(rhs);
        if s >= 0 && one_use(s) && is_inst_op(s, OP_ICMP) && inst_pred(s) == 33 && op(s, 0) == a && m_zero_int(op(s, 1)) {
            return ic_replace_inst_uses_with(i, icb_binary_intrinsic(IID_umax, a, c_int_ty(vals[a].ty, 1), ""));
        }
    }
    r = fold_add_to_ashr(i);
    if r >= 0 { return r; }
    // (X >> log2(N)) + zext(X & (N-1) != 0) --> (X + (N-1)) >> log2(N)
    for k in 2 {
        let sh = op(i, k);
        let z = m_zext(op(i, 1 - k));
        if one_use(sh) && bo(sh, OP_LSHR) && has_apint(op(sh, 1)) && z >= 0 && is_inst_op(z, OP_ICMP) && inst_pred(z) == 33 && m_zero_int(op(z, 1)) {
            let x = op(sh, 0);
            let an = op(z, 0);
            if bo(an, OP_AND) && op(an, 0) == x && m_low_bit_mask(op(an, 1)) {
                let mask = ap_c(op(an, 1));
                let sha = ap_c(op(sh, 1));
                if ap_eq_u64(sha, ap_popcount(mask) as u64) {
                    let mc = c_int_ap(vals[x].ty, mask);
                    if will_not_overflow_unsigned_add(x, mc, i) {
                        let ad = icb_add_nw(x, mc, "", true, false);
                        return ic_new_binop(OP_LSHR, ad, c_int_ap(vals[x].ty, sha));
                    }
                }
            }
        }
    }
    // (~X) + (~Y) --> -2 - (X + Y)
    {
        gfi_consume = false;
        let fl = get_freely_inverted(lhs, one_use(lhs), false) != -1;
        let cl = gfi_consume;
        if fl && cl {
            let fr = get_freely_inverted(rhs, one_use(rhs), false) != -1;
            let cr = gfi_consume;
            if fr && cr {
                let nl = get_freely_inverted(lhs, one_use(lhs), true);
                let nr = get_freely_inverted(rhs, one_use(rhs), true);
                let s = icb_add(nl, nr, "");
                return ic_new_binop(OP_SUB, c_int_ty_s(vals[rhs].ty, -2), s);
            }
        }
    }
    r = try_fold_inst_with_ctpop_with_not(i);
    if r >= 0 { return r; }
    var changed = false;
    if !op_nsw(i) && will_not_overflow_signed_add(lhs, rhs, i) { changed = true; set_nsw(i, true); }
    if !op_nuw(i) && will_not_overflow_unsigned_add(lhs, rhs, i) { changed = true; set_nuw(i, true); }
    r = canonicalize_lowbit_mask(i);
    if r >= 0 { return r; }
    r = canonicalize_cond_signext_of_high_bit_extract(i);
    if r >= 0 { return r; }
    r = fold_to_unsigned_saturated_add(i);
    if r >= 0 { return r; }
    // usub.sat(A, B) + B => umax(A, B)
    for k in 2 {
        let u = op(i, k);
        if one_use(u) && inst_iid(u) == IID_usub_sat && op(u, 1) == op(i, 1 - k) {
            return ic_replace_inst_uses_with(i, icb_intrinsic(IID_umax, [ty], [op(u, 0), op(u, 1)], ""));
        }
    }
    // ctpop(A) + ctpop(B) => ctpop(A | B) if A and B have no bits set in common.
    if one_use(lhs) && inst_iid(lhs) == IID_ctpop && one_use(rhs) && inst_iid(rhs) == IID_ctpop &&
       have_no_common_bits_set(op(lhs, 0), op(rhs, 0), i) {
        let o = icb_disjoint_or(op(lhs, 0), op(rhs, 0), "");
        return ic_replace_inst_uses_with(i, icb_intrinsic(IID_ctpop, [ty], [o], ""));
    }
    // the log2_ceil idiom
    for k in 2 {
        let z = m_zext(op(i, k));
        if z >= 0 && is_inst_op(z, OP_ICMP) && inst_iid(op(z, 0)) == IID_ctpop && m_one(op(z, 1)) {
            ic_not_ported("the log2_ceil idiom fold in visitAdd");
        }
    }
    r = fold_square_sum_int(i);
    if r >= 0 { return r; }
    r = fold_binop_of_displaced_shifts(i);
    if r >= 0 { return r; }
    r = fold_binop_of_select_and_cast_of_select_cond(i);
    if r >= 0 { return r; }
    r = fold_div_ceil(i);
    if r >= 0 { return r; }
    if changed {
        let p = match_simple_recurrence_bo(i);
        if p >= 0 && ic_simple_recurrence_ok(p, i) { icw_push_users(p); }
    }
    return if changed { i } else { -1 };
}

// matchSimpleRecurrence(I, PHI, Start, Step) for a binary operator
fn ic_simple_recurrence_ok(p: i32, i: i32) -> bool {
    if nops(p) != 2 { return false; }
    for k in 2 {
        let l = op(p, k);
        if l == i {
            let other = op(i, 0);
            let other2 = op(i, 1);
            if other == p || other2 == p { return true; }
        }
    }
    return false;
}

// (A & B) with {A, B} as operands in either order
fn ab_same(v: i32, a: i32, b: i32) -> bool { (op(v, 0) == a && op(v, 1) == b) || (op(v, 0) == b && op(v, 1) == a) }
// m_NegatedPower2: a constant whose negation is a power of two
fn m_negated_power2(v: i32) -> bool { m_cint_pred(v, IP_NEG_POWER2, true) }

// CreateIntrinsic(RetTy, ID, Args): overload types derived from the return and argument types
fn icb_intrinsic_rt(rty: i32, id: i64, argsv: const i32[:]) -> i32 {
    if id == IID_scmp || id == IID_ucmp { return icb_intrinsic(id, [rty, vals[argsv[0]].ty], argsv, ""); }
    ic_not_ported("CreateIntrinsic(RetTy, ...) for this intrinsic");
    return -1;
}

// foldBinOpOfDisplacedShifts(I) is in ic_andorxor.goose (InstCombineAndOrXor.cpp)
// m_SpecificInt_ICMP(ICMP_ULT, x): every element (splat or vector) u< x
fn ic_all_elts_ult(c: i32, x: u64) -> bool { c_all_elts_cmp(c, 36, x) }

// ---------------------------------------------------------------------------------------------
// visitSub

// m_c_MaxOrMin(m_Specific(A), m_Value(Y)): Y or -1
fn m_c_minmax_with(v: i32, a: i32) -> i32 {
    if !is_minmax_iid(inst_iid(v)) { return -1; }
    if op(v, 0) == a { return op(v, 1); }
    if op(v, 1) == a { return op(v, 0); }
    return -1;
}
// m_c_<minmax>(m_Specific(A), m_Specific(B))
fn m_c_minmax_both(v: i32, id: i32, a: i32, b: i32) -> bool { inst_iid(v) == id && ab_same(v, a, b) }

// foldSubOfMinMax(I, Builder)
fn fold_sub_of_min_max(i: i32) -> i32 {
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    let ty: i32 = vals[i].ty;
    let id = inst_iid(op1);
    if !is_minmax_iid(id) { return -1; }
    let x = op(op1, 0);
    let y = op(op1, 1);
    if bo(op0, OP_ADD) && ab_same(op0, x, y) && (one_use(op0) || one_use(op1)) {
        return ic_new_intrinsic(minmax_inverse_iid(id), [ty], [x, y]);
    }
    if one_use(op1) && id == IID_umin {
        let yy = op(op1, 0); let z = op(op1, 1);
        if one_use(op0) && bo(op0, OP_ADD) {
            for k in 2 {
                if op(op0, k) == yy {
                    let us = icb_intrinsic(IID_usub_sat, [ty], [yy, z], "");
                    return ic_new_binop(OP_ADD, op(op0, 1 - k), us);
                }
            }
            for k in 2 {
                if op(op0, k) == z {
                    let us = icb_intrinsic(IID_usub_sat, [ty], [z, yy], "");
                    return ic_new_binop(OP_ADD, op(op0, 1 - k), us);
                }
            }
        }
    }
    if (id == IID_smax || id == IID_smin) && m_zero_int(y) && bo(x, OP_SUB) && op_nsw(x) && op(x, 0) == op0 {
        return ic_new_intrinsic(minmax_inverse_iid(id), [ty], [op0, op(x, 1)]);
    }
    return -1;
}

// TryToNarrowDeduceFlags
fn sub_try_to_narrow_deduce_flags(i: i32) -> i32 {
    let e = narrow_math_if_no_overflow(i);
    if e >= 0 { return e; }
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    var changed = false;
    if !op_nsw(i) && will_not_overflow_signed_sub(op0, op1, i) { changed = true; set_nsw(i, true); }
    if !op_nuw(i) && will_not_overflow_unsigned_sub(op0, op1, i) { changed = true; set_nuw(i, true); }
    return if changed { i } else { -1 };
}

// SinkSubIntoSelect
fn sink_sub_into_select(i: i32, sel: i32, other: i32, sel_is_op0: bool) -> i32 {
    if !one_use(sel) || !is_select_inst(sel) { return -1; }
    let cond = op(sel, 0);
    let tv = op(sel, 1);
    let fv = op(sel, 2);
    if other != tv && other != fv { return -1; }
    let other_is_true = other == tv;
    let hand = if other_is_true { fv } else { tv };
    let ns = if sel_is_op0 { icb_sub(hand, other, "") } else { icb_sub(other, hand, "") };
    let zero = c_null(vals[i].ty);
    let s = ic_new_select(cond, if other_is_true { zero } else { ns }, if other_is_true { ns } else { zero });
    ic_copy_all_md(s, sel);
    return s;
}
// Instruction::copyMetadata(SrcInst) (all kinds, including !dbg)
fn ic_copy_all_md(dst: i32, src: i32) {
    let si = inst_of(src);
    for k in insts[si].nmd {
        let kind = md_att[insts[si].md + 2 * k];
        let node = md_att[insts[si].md + 2 * k + 1];
        inst_set_md(dst, kind, node);
    }
}

fn visit_sub(i: i32) -> i32 {
    let v0 = simplify_sub(op(i, 0), op(i, 1), op_nsw(i), op_nuw(i), sq_at(i), RECURSION_LIMIT);
    if v0 >= 0 { return ic_replace_inst_uses_with(i, v0); }
    let x0 = fold_vector_binop(i);
    if x0 >= 0 { return x0; }
    let ph = fold_binop_with_phi_operands(i);
    if ph >= 0 { return ph; }
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    let ty: i32 = vals[i].ty;
    // B = x-(-A) --> x+A
    let nv = dyn_cast_neg_val(op1);
    if nv >= 0 {
        let res = ic_new_binop(OP_ADD, op0, nv);
        if is_binop_inst(op1) {
            if op_nsw(op1) && op_nsw(i) { set_nsw(res, true); }
        } else if is_constant(op1) {
            if ic_is_not_min_signed_value(op1) && op_nsw(i) { set_nsw(res, true); }
        }
        return res;
    }
    var r = factorize_math_with_shl_ops(i);
    if r >= 0 { return r; }
    if is_imm_c(op0) {
        let c = op0;
        if m_add_like(op1) && is_imm_c(op(op1, 1)) {
            let x = op(op1, 0);
            let c2 = op(op1, 1);
            let wnsov = will_not_overflow_signed_sub(c, c2, i);
            let res = ic_new_binop(OP_SUB, ce_binop(OP_SUB, c, c2, 0), x);
            var nsw1 = true;
            var nuw1 = true;
            if is_overflowing_op(iop(op1)) { nsw1 = op_nsw(op1); nuw1 = op_nuw(op1); }
            set_nsw(res, op_nsw(i) && nsw1 && wnsov);
            set_nuw(res, op_nuw(i) && nuw1);
            return res;
        }
    }
    // Negator: sub a, b --> add a, (neg b)
    let is_negation = m_zero_int(op0);
    var try_neg = true;
    if is_negation {
        var u = vals[i].first_use;
        while u >= 0 {
            let us = uses[u].user;
            u = uses[u].next;
            if is_select_inst(us) && ((op(us, 1) == op1 && op(us, 2) == i) || (op(us, 1) == i && op(us, 2) == op1)) { try_neg = false; }
        }
    }
    if try_neg {
        let n = negator_negate(is_negation, is_negation && op_nsw(i), op1, i);
        if n >= 0 { return ic_new_binop(OP_ADD, n, op0); }
    }
    if is_negation { return sub_try_to_narrow_deduce_flags(i); }
    let dl = fold_using_distributive_laws(i);
    if dl >= 0 { return ic_replace_inst_uses_with(i, dl); }
    if is_int_ty1(ty) { return ic_new_binop(OP_XOR, op0, op1); }
    if m_all_ones(op0) { return ic_new_not(op1); }
    // (X + -1) - Y --> ~Y + X
    if one_use(op0) && bo(op0, OP_ADD) && m_all_ones(op(op0, 1)) {
        return ic_new_binop(OP_ADD, icb_not(op1, ""), op(op0, 0));
    }
    // (X & C1) - (X & C2) -> X & (C1 ^ C2)
    if bo(op0, OP_AND) && is_imm_c(op(op0, 1)) && bo(op1, OP_AND) && op(op1, 0) == op(op0, 0) && is_imm_c(op(op1, 1)) {
        let c1 = op(op0, 1);
        let c2 = op(op1, 1);
        let andc = cf_binop(OP_AND, c1, c2);
        if andc >= 0 && ic_elementwise_equal(c2, andc) {
            return ic_new_binop(OP_AND, op(op0, 0), cf_binop(OP_XOR, c1, c2));
        }
    }
    // ((X - Y) + Z) - Op1 --> (X + Z) - (Y + Op1)
    if one_use(op0) && bo(op0, OP_ADD) {
        for k in 2 {
            let s = op(op0, k);
            if one_use(s) && bo(s, OP_SUB) {
                let xz = icb_add(op(s, 0), op(op0, 1 - k), "");
                let yw = icb_add(op(s, 1), op1, "");
                return ic_new_binop(OP_SUB, xz, yw);
            }
        }
    }
    // ((X - Y) - Op1) --> X - (Y + Op1)
    if one_use(op0) && bo(op0, OP_SUB) {
        let nuw = op_nuw(i) && op_nuw(op0);
        let nsw = nuw && op_nsw(i) && op_nsw(op0);
        let ad = icb_add_nw(op(op0, 1), op1, "", nuw, nsw);
        let s = ic_new_binop(OP_SUB, op(op0, 0), ad);
        set_nuw(s, nuw);
        set_nsw(s, nsw);
        return s;
    }
    // (X + C0) - (Y + C1) --> (X - Y) + (C0 - C1)
    if one_use(op0) && bo(op0, OP_ADD) && is_imm_c(op(op0, 1)) && one_use(op1) && bo(op1, OP_ADD) && is_imm_c(op(op1, 1)) {
        let os = icb_sub(op(op0, 0), op(op1, 0), "");
        return ic_new_binop(OP_ADD, os, ce_binop(OP_SUB, op(op0, 1), op(op1, 1), 0));
    }
    // (X + Z) - (Y + Z) --> (X - Y)
    if m_add_like(op0) && m_add_like(op1) {
        let w = op(op0, 0); let x = op(op0, 1);
        let y = op(op1, 0); let z = op(op1, 1);
        var res: i32 = -1;
        if w == y { res = ic_new_binop(OP_SUB, x, z); }
        else if w == z { res = ic_new_binop(OP_SUB, x, y); }
        else if x == y { res = ic_new_binop(OP_SUB, w, z); }
        else if x == z { res = ic_new_binop(OP_SUB, w, y); }
        if res >= 0 {
            set_nsw(res, op_nsw(i) && m_nsw_add_like(op0) && m_nsw_add_like(op1));
            set_nuw(res, op_nuw(i) && m_nuw_add_like(op1));
            return res;
        }
    }
    // (~X) - (~Y) --> Y - X
    {
        let f0 = get_freely_inverted(op0, one_use(op0), false) != -1;
        let c0 = gfi_consume;
        if f0 {
            let f1 = get_freely_inverted(op1, one_use(op1), false) != -1;
            let c1 = gfi_consume;
            if f1 && (c0 || c1) {
                let n0 = get_freely_inverted(op0, one_use(op0), true);
                let n1 = get_freely_inverted(op1, one_use(op1), true);
                return ic_new_binop(OP_SUB, n1, n0);
            }
        }
    }
    // add_rdx(V0) - add_rdx(V1) --> add_rdx(V0 - V1)
    if one_use(op0) && inst_iid(op0) == IID_vector_reduce_add && one_use(op1) && inst_iid(op1) == IID_vector_reduce_add &&
       vals[op(op0, 0)].ty == vals[op(op1, 0)].ty {
        let s = icb_sub(op(op0, 0), op(op1, 0), "");
        return ic_replace_inst_uses_with(i, icb_intrinsic(IID_vector_reduce_add, [vals[s].ty as i32], [s], ""));
    }
    if is_constant(op0) {
        let c = op0;
        let zx = m_zext(op1);
        if zx >= 0 && is_int_ty1(vals[zx].ty) { return ic_new_select(zx, sub_one(c), c); }
        let sx = m_sext(op1);
        if sx >= 0 && is_int_ty1(vals[sx].ty) { return ic_new_select(sx, add_one(c), c); }
        let nx = m_not(op1);
        if nx >= 0 { return ic_new_binop(OP_ADD, nx, add_one(c)); }
        if is_select_inst(op1) {
            let rr = fold_op_into_select(i, op1, false, false);
            if rr >= 0 { return rr; }
        }
        if is_phi_inst(op1) {
            let rr = fold_op_into_phi(i, op1, false);
            if rr >= 0 { return rr; }
        }
        if bo(op1, OP_SUB) && is_imm_c(op(op1, 0)) {
            return ic_new_binop(OP_ADD, op(op1, 1), ce_binop(OP_SUB, c, op(op1, 0), 0));
        }
    }
    if has_apint(op0) {
        let op0c = ap_c(op0);
        if ap_is_mask(op0c) {
            let saved = dc_active;
            dc_active = false;
            kb_cxt = i;
            let rk = kb_compute_all(op1, 0);
            dc_active = saved;
            if ap_is_all_ones(ap_or(op0c, rk.z)) { return ic_new_binop(OP_XOR, op1, op0); }
        }
        if one_use(op1) && bo(op1, OP_AND) && has_apint(op(op1, 1)) {
            let inner = op(op1, 0);
            if is_binop_inst(inner) && bo(inner, OP_SUB) && has_apint(op(inner, 0)) {
                let c2 = ap_c(op(op1, 1));
                let c3 = ap_c(op(inner, 0));
                let x = op(inner, 1);
                if op_nuw(inner) || ap_is_neg_pow2(c2) {
                    let c23 = ap_and(c2, c3);
                    let c23m1 = ap_dec(c23);
                    let c2a3 = ap_add(c2, c3);
                    if ap_is_pow2(ap_sub(c3, c23m1)) && ap_is_subset_of(c23m1, c2a3) {
                        let an = icb_and(x, c_int_ap(ty, c2), "");
                        return ic_new_binop(OP_ADD, an, c_int_ap(ty, ap_sub(op0c, c23)));
                    }
                }
            }
        }
    }
    // X-(X+Y) == -Y ; X-(Y+X) == -Y
    if bo(op1, OP_ADD) {
        for k in 2 { if op(op1, k) == op0 { return ic_new_neg(op(op1, 1 - k)); } }
    }
    // (X-Y)-X == -Y
    if bo(op0, OP_SUB) && op(op0, 0) == op1 { return ic_new_neg(op(op0, 1)); }
    // (sub (or A, B) (and A, B)) --> (xor A, B)
    if bo(op1, OP_AND) && bo(op0, OP_OR) && ab_same(op0, op(op1, 0), op(op1, 1)) { return ic_new_binop(OP_XOR, op(op1, 0), op(op1, 1)); }
    // (sub (add A, B) (or A, B)) --> (and A, B)
    if bo(op0, OP_ADD) && bo(op1, OP_OR) && ab_same(op1, op(op0, 0), op(op0, 1)) { return ic_new_binop(OP_AND, op(op0, 0), op(op0, 1)); }
    // (sub (add A, B) (and A, B)) --> (or A, B)
    if bo(op0, OP_ADD) && bo(op1, OP_AND) && ab_same(op1, op(op0, 0), op(op0, 1)) { return ic_new_binop(OP_OR, op(op0, 0), op(op0, 1)); }
    // (sub (and A, B) (or A, B)) --> neg (xor A, B)
    if bo(op0, OP_AND) && bo(op1, OP_OR) && ab_same(op1, op(op0, 0), op(op0, 1)) && (one_use(op0) || one_use(op1)) {
        return ic_new_neg(icb_xor(op(op0, 0), op(op0, 1), ""));
    }
    // (sub (or A, B), (xor A, B)) --> (and A, B)
    if bo(op1, OP_XOR) && bo(op0, OP_OR) && ab_same(op0, op(op1, 0), op(op1, 1)) { return ic_new_binop(OP_AND, op(op1, 0), op(op1, 1)); }
    // (sub (xor A, B) (or A, B)) --> neg (and A, B)
    if bo(op0, OP_XOR) && bo(op1, OP_OR) && ab_same(op1, op(op0, 0), op(op0, 1)) && (one_use(op0) || one_use(op1)) {
        return ic_new_neg(icb_and(op(op0, 0), op(op0, 1), ""));
    }
    // ((X | Y) - X) --> (~X & Y)
    if one_use(op0) && bo(op0, OP_OR) {
        for k in 2 {
            if op(op0, 1 - k) == op1 {
                var nm: u8[>..] = []; nm.append(val_name(op1)); nm.append(".not");
                return ic_new_binop(OP_AND, op(op0, k), icb_not(op1, nm));
            }
        }
    }
    // (sub (and Op1, (neg X)), Op1) --> neg (and Op1, (add X, -1))
    if one_use(op0) && bo(op0, OP_AND) {
        for k in 2 {
            if op(op0, k) == op1 {
                let ng = op(op0, 1 - k);
                if one_use(ng) && m_neg(ng) >= 0 {
                    let x = m_neg(ng);
                    let ad = icb_add(x, c_all_ones(ty), "");
                    return ic_new_neg(icb_and(op1, ad, ""));
                }
            }
        }
    }
    // (sub (and Op1, C), Op1) --> neg (and Op1, ~C)
    if one_use(op0) && bo(op0, OP_AND) && op(op0, 0) == op1 && is_const(op(op0, 1)) {
        return ic_new_neg(icb_and(op1, icb_not(op(op0, 1), ""), ""));
    }
    // (sub (xor X, (sext C)), (sext C)) => (select C, (neg X), X)
    {
        let rr = sub_xor_cmp(op0, op1, true);
        if rr >= 0 { return rr; }
        let rr2 = sub_xor_cmp(op1, op0, false);
        if rr2 >= 0 { return rr2; }
    }
    r = try_fold_inst_with_ctpop_with_not(i);
    if r >= 0 { return r; }
    r = fold_sub_of_min_max(i);
    if r >= 0 { return r; }
    r = sink_sub_into_select(i, op0, op1, true);
    if r >= 0 { return r; }
    r = sink_sub_into_select(i, op1, op0, false);
    if r >= 0 { return r; }
    // (X - (X & Y)) --> (X & ~Y)
    if bo(op1, OP_AND) {
        for k in 2 {
            if op(op1, k) == op0 {
                let y = op(op1, 1 - k);
                if one_use(op1) || is_constant(y) {
                    var nm: u8[>..] = []; nm.append(val_name(y)); nm.append(".not");
                    return ic_new_binop(OP_AND, op0, icb_not(y, nm));
                }
                break;
            }
        }
    }
    // ~X - Min/Max(~X, Y) -> ~Min/Max(X, ~Y) - X
    {
        let x = m_not(op0);
        if x >= 0 {
            let y = m_c_minmax_with(op1, op0);
            if y >= 0 && !has_n_uses_or_more(op0, 3) && is_free_to_invert(y, one_use(y)) {
                let nt = icb_not(op1, "");
                return ic_new_binop(OP_SUB, nt, x);
            }
        }
        let x2 = m_not(op1);
        if x2 >= 0 {
            let y = m_c_minmax_with(op0, op1);
            if y >= 0 && !has_n_uses_or_more(op1, 3) && is_free_to_invert(y, one_use(y)) {
                let nt = icb_not(op0, "");
                return ic_new_binop(OP_SUB, x2, nt);
            }
        }
    }
    // min(X+1, Y) - min(X, Y) --> zext X < Y
    for pass in 2 {
        let id = if pass == 0 { IID_smin } else { IID_umin };
        if inst_iid(op0) != id || inst_iid(op1) != id { continue; }
        for k in 2 {
            let ad = op(op0, k);
            let y = op(op0, 1 - k);
            let ok = if pass == 0 { m_nsw_add_like(ad) } else { m_nuw_add_like(ad) };
            if ok && m_one(op(ad, 1)) {
                let x = op(ad, 0);
                if ab_same(op1, x, y) && ty_scalar_bits(ty) != 1 && (one_use(op0) || one_use(op1)) {
                    let cnd = icb_icmp(if pass == 0 { 40 } else { 36 }, x, y, "");
                    return ic_new_cast(OP_ZEXT, cnd, ty);
                }
            }
        }
    }
    // pointer differences
    {
        let l = m_ptrtoint_or_addr(op0);
        let rr = m_ptrtoint_or_addr(op1);
        if l >= 0 && rr >= 0 {
            let res = optimize_pointer_difference(l, rr, ty, op_nuw(i));
            if res >= 0 { return ic_replace_inst_uses_with(i, res); }
        }
        let t0 = m_trunc(op0);
        let t1 = m_trunc(op1);
        if t0 >= 0 && t1 >= 0 {
            let l2 = m_ptrtoint_or_addr(t0);
            let r2 = m_ptrtoint_or_addr(t1);
            if l2 >= 0 && r2 >= 0 {
                let res = optimize_pointer_difference(l2, r2, ty, false);
                if res >= 0 { return ic_replace_inst_uses_with(i, res); }
            }
        }
        let z0 = m_zext(op0);
        if z0 >= 0 && (m_ptrtoint_or_addr(z0) >= 0) && (m_zext(op1) >= 0 || is_op(op1, OP_PTRTOINT)) {
            ic_not_ported("sub of zext of ptrtoint");
        }
    }
    // abs canonicalization: sub (xor A, B), B where B = ashr A, BW-1
    let bw = ty_scalar_bits(ty);
    if bo(op1, OP_ASHR) && has_apint(op(op1, 1)) && num_uses(op1) == 2 && ap_eq_u64(ap_c(op(op1, 1)), (bw - 1) as u64) {
        let a = op(op1, 0);
        if one_use(op0) && bo(op0, OP_XOR) && ab_same(op0, a, op1) {
            let isneg = icb_icmp(40, a, c_null(vals[a].ty), "");
            let nega = if op_nuw(i) { c_null(vals[a].ty) } else { icb_neg(a, "", op_nsw(i)) };
            return ic_new_select(isneg, nega, a);
        }
    }
    // sub (X + AddC), (X & AndC) --> and (X + AddC), ~AndC
    if bo(op0, OP_ADD) && has_apint(op(op0, 1)) && bo(op1, OP_AND) && op(op1, 0) == op(op0, 0) && has_apint(op(op1, 1)) {
        let addc = ap_c(op(op0, 1));
        let andc = ap_c(op(op1, 1));
        let cttz = ap_countr_zero(addc);
        let hm = ap_high_bits(bw, bw - cttz);
        if ap_is_zero(ap_and(hm, andc)) { return ic_new_binop(OP_AND, op0, c_int_ap(ty, ap_not(andc))); }
    }
    r = canonicalize_cond_signext_of_high_bit_extract(i);
    if r >= 0 { return r; }
    // X - usub.sat(X, Y) => umin(X, Y)
    if one_use(op1) && inst_iid(op1) == IID_usub_sat && op(op1, 0) == op0 {
        return ic_replace_inst_uses_with(i, icb_intrinsic(IID_umin, [ty], [op0, op(op1, 1)], ""));
    }
    // umax(X, Op1) - Op1 --> usub.sat(X, Op1)
    if one_use(op0) {
        let x = m_c_minmax_with(op0, op1);
        if x >= 0 && inst_iid(op0) == IID_umax { return ic_replace_inst_uses_with(i, icb_intrinsic(IID_usub_sat, [ty], [x, op1], "")); }
    }
    // Op0 - umin(X, Op0) --> usub.sat(Op0, X)
    if one_use(op1) {
        let x = m_c_minmax_with(op1, op0);
        if x >= 0 && inst_iid(op1) == IID_umin { return ic_replace_inst_uses_with(i, icb_intrinsic(IID_usub_sat, [ty], [op0, x], "")); }
        if x >= 0 && inst_iid(op1) == IID_umax {
            let us = icb_intrinsic(IID_usub_sat, [ty], [x, op0], "");
            return ic_new_neg(us);
        }
    }
    // umin(X, Op1) - Op1 --> 0 - usub.sat(Op1, X)
    if one_use(op0) {
        let x = m_c_minmax_with(op0, op1);
        if x >= 0 && inst_iid(op0) == IID_umin {
            let us = icb_intrinsic(IID_usub_sat, [ty], [op1, x], "");
            return ic_new_neg(us);
        }
    }
    // C - ctpop(X) => ctpop(~X) if C is bitwidth
    if m_specific_int(op0, bw as u64) && one_use(op1) && inst_iid(op1) == IID_ctpop {
        let nt = icb_not(op(op1, 0), "");
        return ic_replace_inst_uses_with(i, icb_intrinsic(IID_ctpop, [ty], [nt], ""));
    }
    // (X * X) - (Y * Y) --> (X + Y) * (X - Y)
    if one_use(op0) && bo(op0, OP_MUL) && op(op0, 0) == op(op0, 1) && one_use(op1) && bo(op1, OP_MUL) && op(op1, 0) == op(op1, 1) {
        let x = op(op0, 0);
        let y = op(op1, 0);
        let pnsw = op_nsw(i) && op_nsw(op0) && op_nsw(op1) && bw > 2;
        let pnuw = op_nuw(i) && op_nuw(op0) && op_nuw(op1) && bw > 1;
        let ad = icb_add_nw(x, y, "add", pnuw, pnsw);
        let sb = icb_sub_nw(x, y, "sub", pnuw, pnsw);
        let ml = icb_mul_nw(ad, sb, "", pnuw, pnsw);
        return ic_replace_inst_uses_with(i, ml);
    }
    // max(X,Y) nsw/nuw - min(X,Y) --> abs(X nsw - Y)
    if one_use(op0) && inst_iid(op0) == IID_smax && one_use(op1) && inst_iid(op1) == IID_smin && ab_same(op1, op(op0, 0), op(op0, 1)) {
        if op_nuw(i) || op_nsw(i) {
            let sb = icb_sub_nw(op(op0, 0), op(op0, 1), "sub", false, true);
            let cl = icb_binary_intrinsic(IID_abs, sb, c_true(), "");
            return ic_replace_inst_uses_with(i, cl);
        }
    }
    r = fold_binop_of_select_and_cast_of_select_cond(i);
    if r >= 0 { return r; }
    // (sub (sext (add nsw (X, Y)), sext (X))) --> (sext (Y))
    {
        let x = m_sext_like(op1);
        let a0 = m_sext_like(op0);
        if x >= 0 && a0 >= 0 && bo(a0, OP_ADD) && op_nsw(a0) {
            for k in 2 {
                if op(a0, k) == x { return ic_replace_inst_uses_with(i, icb_sext(op(a0, 1 - k), ty, "")); }
            }
        }
    }
    // (sub[ nsw] (sext (add nsw (X, Y)), sext (add nsw (X, Z)))) --> (sub[ nsw] (sext (Y), sext (Z)))
    {
        let add0 = m_sext_like(op0);
        let add1 = m_sext_like(op1);
        if add0 >= 0 && add1 >= 0 && bo(add0, OP_ADD) && op_nsw(add0) && bo(add1, OP_ADD) && op_nsw(add1) {
            var y: i32 = -1;
            var z: i32 = -1;
            for k in 2 {
                if y >= 0 { break; }
                let x = op(add0, k);
                for j in 2 {
                    if op(add1, j) == x && y < 0 { y = op(add0, 1 - k); z = op(add1, 1 - j); }
                }
            }
            if y >= 0 {
                var nnew = 0;
                if !is_constant(y) { nnew++; }
                if !is_constant(z) { nnew++; }
                var ndead = 0;
                if one_use(op0) { ndead++; if one_use(add0) { ndead++; } }
                if one_use(op1) { ndead++; if one_use(add1) { ndead++; } }
                if ndead >= nnew {
                    let sy = icb_sext(y, ty, "");
                    let sz = icb_sext(z, ty, "");
                    let sb = icb_sub_nw(sy, sz, "", false, op_nsw(i));
                    return ic_replace_inst_uses_with(i, sb);
                }
            }
        }
    }
    return sub_try_to_narrow_deduce_flags(i);
}

// m_SubXorCmp(LHS, RHS)
fn sub_xor_cmp(lhs: i32, rhs: i32, neg_true: bool) -> i32 {
    if !one_use(lhs) || !bo(lhs, OP_XOR) { return -1; }
    var x: i32 = -1;
    if op(lhs, 1) == rhs { x = op(lhs, 0); } else if op(lhs, 0) == rhs { x = op(lhs, 1); } else { return -1; }
    let c = m_sext(rhs);
    if c < 0 || ty_scalar_bits(vals[c].ty) != 1 { return -1; }
    let ng = icb_neg(x, "", false);
    if neg_true { return ic_new_select_unknown_prof(c, ng, x); }
    return ic_new_select_unknown_prof(c, x, ng);
}

// Constant::isNotMinSignedValue
fn ic_is_not_min_signed_value(c: i32) -> bool {
    if vals[c].kind == VK_CINT { return !ap_is_min_signed(ci_ap(if ty_is_vector(vals[c].ty) { splat_value(c, false) } else { c })); }
    if ty_is_vector(vals[c].ty) {
        let s = splat_value(c, false);
        if s >= 0 && vals[s].kind == VK_CINT { return !ap_is_min_signed(ci_ap(s)); }
        if ty_kind(vals[c].ty) == TK_FVEC {
            for k in ty_count(vals[c].ty) {
                let e = agg_elem(c, k);
                if e < 0 || vals[e].kind != VK_CINT || ap_is_min_signed(ci_ap(e)) { return false; }
            }
            return true;
        }
    }
    return false;
}
// Constant::isElementWiseEqual(Y)
fn ic_elementwise_equal(a: i32, b: i32) -> bool {
    if a == b { return true; }
    let vty = vals[a].ty;
    if !ty_is_vector(vty) || !is_constant(b) || vals[b].ty != vty { return false; }
    let et = ty_scalar(vty);
    if !ty_is_int(et) && !ty_is_fp(et) { return false; }
    // bitcast to integer for an exact bitwise comparison
    var c0 = a;
    var c1 = b;
    if ty_is_fp(et) {
        let ity = ty_vec_integer(vty);
        c0 = ce_cast(OP_BITCAST, a, ity);
        c1 = ce_cast(OP_BITCAST, b, ity);
    }
    let c = cf_fold_cmp_operands(32, c0, c1, -1);
    return c >= 0 && (is_poison(c) || m_one(c));
}

// OptimizePointerDifference(LHS, RHS, Ty, IsNUW)
fn optimize_pointer_difference(l: i32, r: i32, ty: i32, nuw: bool) -> i32 {
    if vals[l].ty != vals[r].ty { return -1; }
    // CommonPointerBase::compute: does a common base exist?
    var p = l;
    var found = false;
    var x = r;
    loop {
        var q = l;
        loop {
            if q == x { found = true; break; }
            if is_op(q, OP_GEP) { q = op(q, 0); } else { break; }
        }
        if found { break; }
        if is_op(x, OP_GEP) { x = op(x, 0); } else { break; }
    }
    if !found { return -1; }
    ic_not_ported("OptimizePointerDifference (EmitGEPOffsets)");
    return -1;
}

// CommonPointerBase::compute(LHS, RHS) and isExpensive() (InstCombineAddSub.cpp): the result in cpb_*
var cpb_ptr: i32 = -1;
var cpb_lhs: i32[>..<];     // LHSGEPs
var cpb_rhs: i32[>..<];     // RHSGEPs
var cpb_lnw: u8 = 7;
var cpb_rnw: u8 = 7;
fn common_pointer_base_compute(l0: i32, r0: i32) {
    cpb_ptr = -1;
    cpb_lhs.resize(0);
    cpb_rhs.resize(0);
    cpb_lnw = GEP_INBOUNDS | GEP_NUSW | GEP_NUW;
    cpb_rnw = GEP_INBOUNDS | GEP_NUSW | GEP_NUW;
    if vals[l0].ty != vals[r0].ty { return; }
    var ptrs: i32[>..<] = [];
    var p = l0;
    loop {
        ptrs.push(p);
        if is_op(p, OP_GEP) { p = op(p, 0); } else { break; }
    }
    var first = true;
    var r = r0;
    loop {
        var hit = false;
        for x in ptrs { if x == r { hit = true; } }
        if hit { cpb_ptr = r; break; }
        if is_op(r, OP_GEP) {
            cpb_rhs.push(r);
            if first { first = false; cpb_rnw = gep_flags(r); } else { cpb_rnw = gep_nw_intersect_for_offset_add(cpb_rnw, gep_flags(r)); }
            r = op(r, 0);
        } else { return; }
    }
    first = true;
    var l = l0;
    loop {
        if l == cpb_ptr { break; }
        cpb_lhs.push(l);
        if first { first = false; cpb_lnw = gep_flags(l); } else { cpb_lnw = gep_nw_intersect_for_offset_add(cpb_lnw, gep_flags(l)); }
        l = op(l, 0);
    }
}
fn common_pointer_base_is_expensive() -> bool {
    var n = 0;
    var seen = false;
    for g in cpb_lhs { if !has_one_use(g) { if seen { n++; } seen = true; } }
    seen = false;
    for g in cpb_rhs { if !has_one_use(g) { if seen { n++; } seen = true; } }
    return n > 2;
}
