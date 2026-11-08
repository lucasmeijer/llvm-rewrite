// InstCombine mul/div/rem: port of llvm/lib/Transforms/InstCombine/InstCombineMulDivRem.cpp (visitMul, visitUDiv,
// visitSDiv, visitURem, visitSRem and their helpers; the FP visitors are not ported and fail loudly).
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
import instsimplify;
import apint;
import overflow;
import ic;
import ic_builder;
import ic_common;
import ic_negator;
import ic_demanded;

// ConstantExpr::getExactLogBase2(C): -1 when not a (vector of) power(s) of two
fn get_exact_log_base2(c: i32) -> i32 {
    let ty = vals[c].ty;
    if has_apint(c) && ap_is_pow2(ap_c(c)) { return c_int_ty(ty, ap_log2(ap_c(c)) as u64); }
    if ty_kind(ty) != TK_FVEC { return -1; }
    let et = ty_scalar(ty);
    let mark = is_ops.len;
    for k in ty_count(ty) {
        let e = agg_elem(c, k);
        if e < 0 { is_ops.resize(mark); return -1; }
        if is_undef_or_poison(e) { is_ops.push(c_null(et)); continue; }
        if vals[e].kind != VK_CINT || !ap_is_pow2(ci_ap(e)) { is_ops.resize(mark); return -1; }
        is_ops.push(c_int_ty(et, ap_log2(ci_ap(e)) as u64));
    }
    let r = c_aggregate(ty, is_ops[mark..is_ops.len]);
    is_ops.resize(mark);
    return r;
}
fn ce_neg(c: i32) -> i32 { ce_binop(OP_SUB, c_null(vals[c].ty), c, 0) }

// ---------------------------------------------------------------------------------------------
// visitMul helpers

// simplifyValueKnownNonZero(V, IC, CxtI)
recursive fn simplify_value_known_non_zero(v: i32, cx: i32) -> i32 {
    if !one_use(v) { return -1; }
    var changed = false;
    if bo(v, OP_LSHR) && one_use(op(v, 0)) && bo(op(v, 0), OP_SHL) && m_one(op(op(v, 0), 0)) {
        let one = op(op(v, 0), 0);
        let a = op(op(v, 0), 1);
        let b = op(v, 1);
        let na = icb_sub(a, b, "");
        return icb_shl(one, na, "");
    }
    if is_binop_inst(v) && (iop(v) == OP_SHL || iop(v) == OP_LSHR) {
        kb_cxt = cx;
        if is_known_pow2(op(v, 0), false, 0) {
            let sp = icb_pos; let sb = icb_bb; let sd = icb_dl;
            icb_set_insert_point(v);
            let v2 = simplify_value_known_non_zero(op(v, 0), cx);
            icb_pos = sp; icb_bb = sb; icb_dl = sd;
            if v2 >= 0 { ic_replace_operand(v, 0, v2); changed = true; }
            if iop(v) == OP_LSHR && !op_exact(v) { set_exact(v, true); changed = true; }
            if iop(v) == OP_SHL && !op_nuw(v) { set_nuw(v, true); changed = true; }
        }
    }
    return if changed { v } else { -1 };
}

// foldMulSelectToNegate(I, Builder)
fn fold_mul_select_to_negate(i: i32) -> i32 {
    if is_fp_op(i) { return -1; }
    for k in 2 {
        let s = op(i, k);
        let other = op(i, 1 - k);
        if one_use(s) && is_select_inst(s) && m_one(op(s, 1)) && m_all_ones(op(s, 2)) {
            let ng = icb_neg(other, "", op_nsw(i) || op_nuw(i));
            return icb_select(op(s, 0), other, ng, "", -1);
        }
    }
    for k in 2 {
        let s = op(i, k);
        let other = op(i, 1 - k);
        if one_use(s) && is_select_inst(s) && m_all_ones(op(s, 1)) && m_one(op(s, 2)) {
            let ng = icb_neg(other, "", op_nsw(i) || op_nuw(i));
            return icb_select(op(s, 0), ng, other, "", -1);
        }
    }
    return -1;
}

// foldMulShl1(Mul, CommuteOperands, Builder)
fn fold_mul_shl1(m: i32, commute: bool) -> i32 {
    var x = op(m, 0);
    var y = op(m, 1);
    if commute { let t = x; x = y; y = t; }
    let nsw = op_nsw(m);
    let nuw = op_nuw(m);
    var nm: u8[>..] = []; nm.append(val_name(m));
    if bo(y, OP_SHL) && m_one(op(y, 0)) {
        let pnsw = nsw && op_nsw(y);
        return icb_shl_nw(x, op(y, 1), nm, nuw, pnsw);
    }
    if one_use(y) && bo(y, OP_ADD) && m_one(op(y, 1)) && is_binop_inst(op(y, 0)) {
        let sh = op(y, 0);
        if one_use(sh) && bo(sh, OP_SHL) && m_one(op(sh, 0)) {
            let z = op(sh, 1);
            let pnsw = nsw && op_nsw(sh);
            var frx = x;
            if !is_guaranteed_not_to_be_undef(x, -1, 0) {
                var fn_: u8[>..] = []; fn_.append(val_name(x)); fn_.append(".fr");
                frx = icb_freeze(x, fn_);
            }
            let shl = icb_shl_nw(frx, z, "mulshl", nuw, pnsw);
            return icb_add_nw(shl, frx, nm, nuw, pnsw);
        }
    }
    if one_use(y) {
        let n = m_not(y);
        if n >= 0 && one_use(n) && bo(n, OP_SHL) && m_all_ones(op(n, 0)) {
            let z = op(n, 1);
            var frx = x;
            if !is_guaranteed_not_to_be_undef(x, -1, 0) {
                var fn_: u8[>..] = []; fn_.append(val_name(x)); fn_.append(".fr");
                frx = icb_freeze(x, fn_);
            }
            let shl = icb_shl(frx, z, "mulshl");
            return icb_sub(shl, frx, nm);
        }
    }
    return -1;
}

// takeLog2(Op, Depth, AssumeNonZero, DoFold): -2 = "would fold" (DoFold = false), -1 = no
recursive fn take_log2(v: i32, depth0: i64, nonzero: bool, fold: bool) -> i32 {
    if m_power2(v) {
        if !fold { return -2; }
        let c = get_exact_log_base2(v);
        if c < 0 { fatal("Failed to constant fold udiv -> logbase2"); }
        return c;
    }
    var depth = depth0;
    if depth == 6 { return -1; }
    depth++;
    let zx = m_zext(v);
    if zx >= 0 {
        let lx = take_log2(zx, depth, nonzero, fold);
        if lx != -1 { return if fold { icb_zext(lx, vals[v].ty, "") } else { -2 }; }
    }
    let tx = m_trunc(v);
    if tx >= 0 {
        let tnuw = (insts[inst_of(v)].flags & FL_NUW) != 0;
        if nonzero || tnuw {
            let lx = take_log2(tx, depth, nonzero, fold);
            if lx != -1 { return if fold { icb_trunc_nw(lx, vals[v].ty, "", tnuw, false) } else { -2 }; }
        }
    }
    if bo(v, OP_SHL) {
        if nonzero || op_nuw(v) || op_nsw(v) {
            let lx = take_log2(op(v, 0), depth, nonzero, fold);
            if lx != -1 { return if fold { icb_add(lx, op(v, 1), "") } else { -2 }; }
        }
    }
    if bo(v, OP_LSHR) {
        if nonzero || op_exact(v) {
            let lx = take_log2(op(v, 0), depth, nonzero, fold);
            if lx != -1 { return if fold { icb_sub(lx, op(v, 1), "") } else { -2 }; }
        }
    }
    if nonzero && bo(v, OP_AND) {
        let lx = take_log2(op(v, 0), depth, nonzero, fold);
        if lx != -1 { return lx; }
        let ly = take_log2(op(v, 1), depth, nonzero, fold);
        if ly != -1 { return ly; }
    }
    if is_select_inst(v) {
        let lx = take_log2(op(v, 1), depth, nonzero, fold);
        if lx != -1 {
            let ly = take_log2(op(v, 2), depth, nonzero, fold);
            if ly != -1 { return if fold { icb_select(op(v, 0), lx, ly, "", v) } else { -2 }; }
        }
    }
    let id = inst_iid(v);
    if (id == IID_umin || id == IID_umax) && has_one_use(v) {
        let lx = take_log2(op(v, 0), depth, false, fold);
        if lx != -1 {
            let ly = take_log2(op(v, 1), depth, false, fold);
            if ly != -1 { return if fold { icb_binary_intrinsic(id, lx, ly, "") } else { -2 }; }
        }
    }
    return -1;
}
// tryGetLog2(Op, AssumeNonZero)
fn try_get_log2(v: i32, nonzero: bool) -> i32 {
    if take_log2(v, 0, nonzero, false) != -1 { return take_log2(v, 0, nonzero, true); }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// visitMul

fn visit_mul(i: i32) -> i32 {
    let op0i = op(i, 0);
    let op1i = op(i, 1);
    let v0 = simplify_mul(op0i, op1i, op_nsw(i), op_nuw(i), sq_at(i), RECURSION_LIMIT);
    if v0 >= 0 { return ic_replace_inst_uses_with(i, v0); }
    if simplify_assoc_or_comm(i) { return i; }
    let x0 = fold_vector_binop(i);
    if x0 >= 0 { return x0; }
    let ph = fold_binop_with_phi_operands(i);
    if ph >= 0 { return ph; }
    let dl = fold_using_distributive_laws(i);
    if dl >= 0 { return ic_replace_inst_uses_with(i, dl); }
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    let ty = vals[i].ty;
    let bw = ty_scalar_bits(ty);
    let hnsw = op_nsw(i);
    let hnuw = op_nuw(i);
    // X * -1 --> 0 - X
    if m_all_ones(op1) {
        let r = ic_new_neg(op0);
        if hnsw { set_nsw(r, true); }
        return r;
    }
    // ((X << C2)*C1) == (X * (C1 << C2))
    if bo(op0, OP_SHL) && is_imm_c(op(op0, 1)) && is_imm_c(op1) && has_apint(op1) {
        let shl = cf_fold_binop_operands(OP_SHL, op1, op(op0, 1));
        if shl < 0 { fatal("Constant folding of immediate constants failed"); }
        let bo_ = ic_new_binop(OP_MUL, op(op0, 0), shl);
        if hnuw && op_nuw(op0) { set_nuw(bo_, true); }
        if hnsw && op_nsw(op0) && ic_is_not_min_signed_value(shl) { set_nsw(bo_, true); }
        return bo_;
    }
    if is_const(op1) {
        let nc = get_exact_log_base2(op1);
        if nc >= 0 {
            let shl = ic_new_binop(OP_SHL, op0, nc);
            if hnuw { set_nuw(shl, true); }
            if hnsw {
                if has_apint(nc) && !ap_eq_u64(ap_c(nc), (bw - 1) as u64) { set_nsw(shl, true); }
            }
            return shl;
        }
    }
    // mul (shr exact X, N), (2^N + 1) -> add (X, shr exact (X, N))
    if bw > 2 && (bo(op0, OP_LSHR) || bo(op0, OP_ASHR)) && op_exact(op0) && has_apint(op(op0, 1)) && has_apint(op1) {
        let shc = ap_c(op(op0, 1));
        let mulap = ap_c(op1);
        if ap_is_pow2(ap_dec(mulap)) && ap_eq_u64(shc, ap_log2(mulap) as u64) {
            let newop = op(op0, 0);
            var binop = op0;
            if hnuw && iop(op0) == OP_ASHR && one_use(op0) {
                binop = icb_lshr(newop, c_int_ap(ty, shc), "", true);
            }
            let na = ic_new_binop(OP_ADD, newop, binop);
            if hnsw && (hnuw || iop(op0) == OP_LSHR || ap_ult_u64(shc, (bw - 1) as u64)) { set_nsw(na, true); }
            set_nuw(na, hnuw);
            return na;
        }
    }
    if one_use(op0) && m_cint_pred(op1, IP_NEG_POWER2, true) {
        let n0 = negator_negate(true, hnsw, op0, i);
        if n0 >= 0 {
            return ic_replace_inst_uses_with(i, icb_mul_nw(n0, ce_neg(op1), "", false, hnsw && ic_is_not_min_signed_value(op1)));
        }
        let x = m_zext_or_sext(op0);
        if x >= 0 && has_apint_poison(op1) {
            let np2 = ap_cp(op1);
            let sw = ty_sbits(x);
            let sha = ap_countr_zero(np2);
            if sha >= bw - sw {
                var nm: u8[>..] = []; nm.append(val_name(x)); nm.append(".neg");
                let n = icb_neg(x, nm, false);
                var zn: u8[>..] = []; zn.append(val_name(n)); zn.append(".z");
                let z = icb_zext(n, ty, zn);
                return ic_new_binop(OP_SHL, z, c_int_ty(ty, sha as u64));
            }
        }
    }
    var r = fold_binop_into_select_or_phi(i);
    if r >= 0 { return r; }
    r = fold_binop_select_binop(i);
    if r >= 0 { return r; }
    let fm = fold_mul_select_to_negate(i);
    if fm >= 0 { return ic_replace_inst_uses_with(i, fm); }
    // (shl X, C1)*(select cond, C2, C3)--> X * (select cond, C2<<C1, C3<<C1)
    for k in 2 {
        let other = op(i, k);
        let sel = op(i, 1 - k);
        if one_use(other) && one_use(sel) && is_select_inst(sel) && is_imm_c(op(sel, 1)) && is_imm_c(op(sel, 2)) {
            if (bo(other, OP_MUL) || bo(other, OP_SHL)) && is_imm_c(op(other, 1)) {
                let oc = iop(other);
                let ntv = cf_fold_binop_operands(oc, op(sel, 1), op(other, 1));
                let nfv = cf_fold_binop_operands(oc, op(sel, 2), op(other, 1));
                if ntv >= 0 && nfv >= 0 {
                    let ns = icb_select(op(sel, 0), ntv, nfv, "", -1);
                    let b2 = ic_new_binop(OP_MUL, op(other, 0), ns);
                    if hnuw && op_nuw(other) { set_nuw(b2, true); }
                    if hnsw && op_nsw(other) && ic_is_not_min_signed_value(ntv) && ic_is_not_min_signed_value(nfv) { set_nsw(b2, true); }
                    return b2;
                }
            }
            break;
        }
    }
    // (X+C1)*MulC -> X*MulC+C1*MulC ; (X|C1)*MulC -> X*MulC+C1*MulC
    if is_imm_c(op1) {
        if one_use(op0) && m_add_like(op0) && is_imm_c(op(op0, 1)) {
            let x = op(op0, 0);
            let nc = icb_mul(op(op0, 1), op1, "");
            let op0nuw = iop(op0) == OP_OR || op_nuw(op0);
            let nm = icb_mul(x, op1, "");
            let b2 = ic_new_binop(OP_ADD, nm, nc);
            if hnuw && op0nuw {
                if is_binop_inst(nm) { set_nuw(nm, true); }
                set_nuw(b2, true);
            }
            return b2;
        }
    }
    // abs(X) * abs(X) -> X * X
    if op0 == op1 && inst_iid(op0) == IID_abs { return ic_new_binop(OP_MUL, op(op0, 0), op(op0, 0)); }
    // abs(X) * abs(Y) -> abs(X * Y)
    if hnsw && one_use(op0) && inst_iid(op0) == IID_abs && m_one(op(op0, 1)) && one_use(op1) && inst_iid(op1) == IID_abs && m_one(op(op1, 1)) {
        let ml = icb_mul_nw(op(op0, 0), op(op1, 0), "", false, true);
        return ic_replace_inst_uses_with(i, icb_binary_intrinsic(IID_abs, ml, c_true(), ""));
    }
    // -X * C --> X * -C
    let nx0 = m_neg(op0);
    if nx0 >= 0 && is_const(op1) { return ic_new_binop(OP_MUL, nx0, ce_neg(op1)); }
    // -X * -Y --> X * Y
    let ny1 = m_neg(op1);
    if nx0 >= 0 && ny1 >= 0 {
        let nm = ic_new_binop(OP_MUL, nx0, ny1);
        if hnsw && op_nsw(op0) && op_nsw(op1) { set_nsw(nm, true); }
        return nm;
    }
    // -X * Y --> -(X * Y)
    for k in 2 {
        let n = op(i, k);
        if one_use(n) && m_neg(n) >= 0 { return ic_new_neg(icb_mul(m_neg(n), op(i, 1 - k), "")); }
    }
    // (-X * Y) * -X --> (X * Y) * X
    if ny1 >= 0 {
        let n0 = negator_negate(false, false, op0, i);
        if n0 >= 0 { return ic_new_binop(OP_MUL, n0, ny1); }
    }
    // (mul (div exact X, C0), C1) -> (div exact X, C0 / C1)
    if one_use(op0) && has_apint(op1) && (bo(op0, OP_UDIV) || bo(op0, OP_SDIV)) && op_exact(op0) && has_apint(op(op0, 1)) {
        let c1 = ap_c(op1);
        let c = ap_c(op(op0, 1));
        var ok = false;
        if iop(op0) == OP_UDIV { ok = !ap_is_zero(c1) && ap_is_zero(ap_urem(c, c1)); }
        else if !ap_is_zero(c1) {
            let q, rm = ap_sdivrem(c, c1);
            ok = ap_is_zero(rm) && !ap_is_all_ones(q);
        }
        if ok {
            let bopc = iop(op0);
            let nd = icb_binop(bopc, op(op0, 1), op1, "");
            return ic_new_binop_flags(bopc, op(op0, 0), nd, FL_EXACT);
        }
    }
    // (X / Y) * Y = X - (X % Y) ; (X / Y) * -Y = (X % Y) - X
    {
        var y = op1;
        var div = op0;
        if !(is_binop_inst(div) && (iop(div) == OP_UDIV || iop(div) == OP_SDIV)) { y = op0; div = op1; }
        let neg = dyn_cast_neg_val(y);
        if is_binop_inst(div) && has_one_use(div) && (op(div, 1) == y || op(div, 1) == neg) && (iop(div) == OP_UDIV || iop(div) == OP_SDIV) {
            let x = op(div, 0);
            let d1 = op(div, 1);
            if op_exact(div) {
                if d1 == y { return ic_replace_inst_uses_with(i, x); }
                return ic_new_neg(x);
            }
            let ro = if iop(div) == OP_UDIV { OP_UREM } else { OP_SREM };
            var xf = x;
            if !is_guaranteed_not_to_be_undef(x, -1, 0) {
                var nm: u8[>..] = []; nm.append(val_name(x)); nm.append(".fr");
                xf = icb_freeze(x, nm);
            }
            let rm = icb_binop(ro, xf, d1, "");
            if d1 == y { return ic_new_binop(OP_SUB, xf, rm); }
            return ic_new_binop(OP_SUB, rm, xf);
        }
    }
    // i1 mul -> and ; X * Y --> X & Y iff X, Y can be only {0,1}
    if is_int_ty1(ty) || (bo(op0, OP_AND) && m_one(op(op0, 1)) && bo(op1, OP_AND) && m_one(op(op1, 1))) {
        return ic_new_binop(OP_AND, op0, op1);
    }
    let s1 = fold_mul_shl1(i, false);
    if s1 >= 0 { return ic_replace_inst_uses_with(i, s1); }
    let s2 = fold_mul_shl1(i, true);
    if s2 >= 0 { return ic_replace_inst_uses_with(i, s2); }
    // (zext bool X) * (zext bool Y) --> zext (and X, Y) ; (sext bool X) * (sext bool Y) --> zext (and X, Y)
    {
        var x: i32 = -1; var y: i32 = -1;
        if m_zext(op0) >= 0 && m_zext(op1) >= 0 { x = m_zext(op0); y = m_zext(op1); }
        else if m_sext(op0) >= 0 && m_sext(op1) >= 0 { x = m_sext(op0); y = m_sext(op1); }
        if x >= 0 && is_int_ty1(vals[x].ty) && vals[x].ty == vals[y].ty && (one_use(op0) || one_use(op1) || x == y) {
            let an = icb_and(x, y, "mulbool");
            return ic_new_cast(OP_ZEXT, an, ty);
        }
    }
    {
        var x: i32 = -1; var y: i32 = -1;
        if m_sext(op0) >= 0 && m_zext(op1) >= 0 { x = m_sext(op0); y = m_zext(op1); }
        else if m_zext(op0) >= 0 && m_sext(op1) >= 0 { x = m_zext(op0); y = m_sext(op1); }
        if x >= 0 && is_int_ty1(vals[x].ty) && vals[x].ty == vals[y].ty && (one_use(op0) || one_use(op1)) {
            let an = icb_and(x, y, "mulbool");
            return ic_new_cast(OP_SEXT, an, ty);
        }
    }
    // (zext bool X) * Y --> X ? Y : 0
    {
        let x = m_zext(op0);
        if x >= 0 && is_int_ty1(vals[x].ty) { return ic_new_select_unknown_prof(x, op1, c_null(ty)); }
        let x2 = m_zext(op1);
        if x2 >= 0 && is_int_ty1(vals[x2].ty) { return ic_new_select_unknown_prof(x2, op0, c_null(ty)); }
    }
    // mul (sext X), Y -> select X, -Y, 0
    for k in 2 {
        let s = op(i, k);
        if one_use(s) && m_sext(s) >= 0 {
            let x = m_sext(s);
            if is_int_ty1(vals[x].ty) {
                return ic_new_select_unknown_prof(x, icb_neg(op(i, 1 - k), "", op_nsw(i)), c_null(vals[op0].ty));
            }
            break;
        }
    }
    if is_imm_c(op1) {
        let x = m_sext(op0);
        if x >= 0 && is_int_ty1(vals[x].ty) { return ic_new_select_unknown_prof(x, ce_neg(op1), c_null(ty)); }
        if one_use(op0) && bo(op0, OP_ASHR) && has_apint(op(op0, 1)) && ap_eq_u64(ap_c(op(op0, 1)), (bw - 1) as u64) {
            let isneg = icb_icmp(40, op(op0, 0), c_null(vals[op(op0, 0)].ty), "isneg");
            return ic_new_select_unknown_prof(isneg, ce_neg(op1), c_null(ty));
        }
    }
    // (lshr X, 31) * Y --> (X < 0) ? Y : 0
    for k in 2 {
        let l = op(i, k);
        if bo(l, OP_LSHR) && has_apint(op(l, 1)) && ap_eq_u64(ap_c(op(l, 1)), (bw - 1) as u64) {
            let isneg = icb_icmp(40, op(l, 0), c_null(vals[op(l, 0)].ty), "isneg");
            return ic_new_select_unknown_prof(isneg, op(i, 1 - k), c_null(ty));
        }
    }
    // (and X, 1) * Y --> (trunc X) ? Y : 0
    for k in 2 {
        let a = op(i, k);
        if one_use(a) && bo(a, OP_AND) && m_one(op(a, 1)) {
            let tr = icb_trunc(op(a, 0), cmp_result_ty(ty), "");
            return ic_new_select_unknown_prof(tr, op(i, 1 - k), c_null(ty));
        }
    }
    // ((ashr X, 31) | 1) * X --> abs(X)
    for k in 2 {
        let o = op(i, k);
        let x = op(i, 1 - k);
        if bo(o, OP_OR) && m_one(op(o, 1)) && bo(op(o, 0), OP_ASHR) && op(op(o, 0), 0) == x &&
           m_specific_int_allow_poison(op(op(o, 0), 1), (bw - 1) as u64) {
            let ab = icb_binary_intrinsic(IID_abs, x, c_bool_ty(T_I1, hnsw), "");
            ic_take_name(ab, i);
            return ic_replace_inst_uses_with(i, ab);
        }
    }
    r = narrow_math_if_no_overflow(i);
    if r >= 0 { return r; }
    r = fold_binop_of_select_and_cast_of_select_cond(i);
    if r >= 0 { return r; }
    let l0 = try_get_log2(op0, false);
    if l0 >= 0 {
        let s = ic_new_binop(OP_SHL, op1, l0);
        set_nuw(s, hnuw);
        return s;
    }
    let l1 = try_get_log2(op1, false);
    if l1 >= 0 {
        let s = ic_new_binop(OP_SHL, op0, l1);
        set_nuw(s, hnuw);
        return s;
    }
    var changed = false;
    if !hnsw && will_not_overflow_signed_mul(op0, op1, i) { changed = true; set_nsw(i, true); }
    if !hnuw && will_not_overflow_unsigned_mul(op0, op1, i, op_nsw(i)) { changed = true; set_nuw(i, true); }
    return if changed { i } else { -1 };
}

// ---------------------------------------------------------------------------------------------
// Division and remainder

fn multiply_overflows(c1: AP, c2: AP, signed: bool) -> AP, bool {
    if signed { let p, o = ap_smul_ov(c1, c2); return p, o; }
    let p, o = ap_umul_ov(c1, c2);
    return p, o;
}
// isMultiple(C1, C2, Quotient, IsSigned)
fn is_multiple(c1: AP, c2: AP, signed: bool) -> bool, AP {
    if ap_is_zero(c2) { return false, c2; }
    if signed && ap_is_min_signed(c1) && ap_is_all_ones(c2) { return false, c2; }
    if signed { let q, r = ap_sdivrem(c1, c2); return ap_is_zero(r), q; }
    let q, r = ap_udivrem(c1, c2);
    return ap_is_zero(r), q;
}

// foldIDivShl(I, Builder)
fn fold_idiv_shl(i: i32) -> i32 {
    let signed = iop(i) == OP_SDIV;
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    let ty = vals[i].ty;
    if bo(op1, OP_SHL) && bo(op0, OP_MUL) {
        let x = op(op1, 0);
        let z = op(op1, 1);
        var y: i32 = -1;
        if op(op0, 0) == x { y = op(op0, 1); } else if op(op0, 1) == x { y = op(op0, 0); }
        if y >= 0 {
            let nuw = op_nuw(op0) && op_nuw(op1);
            let nsw = op_nsw(op0) && op_nsw(op1);
            if !signed && nuw { return icb_lshr(y, z, "", op_exact(i)); }
            if signed && nsw && (one_use(op0) || one_use(op1)) {
                let sh = icb_shl(c_int_ty(ty, 1), z, "");
                return icb_sdiv(y, sh, "", op_exact(i));
            }
        }
    }
    if bo(op0, OP_SHL) && bo(op1, OP_SHL) && op(op1, 1) == op(op0, 1) {
        let x = op(op0, 0);
        let y = op(op1, 0);
        if !signed && ((op_nuw(op0) && op_nuw(op1)) || (op_nuw(op0) && op_nsw(op0) && op_nsw(op1))) { return icb_udiv(x, y, "", op_exact(i)); }
        if signed && op_nsw(op0) && op_nsw(op1) && op_nuw(op1) { return icb_sdiv(x, y, "", op_exact(i)); }
    }
    if bo(op0, OP_SHL) && bo(op1, OP_SHL) && op(op1, 0) == op(op0, 0) {
        let x = op(op0, 0);
        let y = op(op0, 1);
        let z = op(op1, 1);
        let ok = if signed { op_nsw(op0) && op_nsw(op1) } else { op_nuw(op0) && op_nuw(op1) };
        if ok {
            let one = c_int_ty(vals[x].ty, 1);
            let dd = icb_shl_nw(one, y, "shl.dividend", true, if signed { op_nuw(op0) || op_nuw(op1) } else { op_nsw(op0) });
            return icb_lshr(dd, z, "", op_exact(i));
        }
    }
    return -1;
}

// m_ContainsMatchingVectorElement(m_CombineOr(m_Zero(), m_UndefValue()))
fn divisor_has_zero_or_undef_elt(c: i32) -> bool {
    if !is_constant(c) || ty_kind(vals[c].ty) != TK_FVEC { return false; }
    for k in ty_count(vals[c].ty) {
        let e = agg_elem(c, k);
        if e < 0 { continue; }
        if is_undef_or_poison(e) || (is_constant(e) && is_null_value(e)) { return true; }
    }
    return false;
}

// simplifyDivRemOfSelectWithZeroOp(I)
fn simplify_divrem_of_select_with_zero_op(i: i32) -> bool {
    var si = op(i, 1);
    if !is_select_inst(si) { return false; }
    var nn: i64 = 0;
    if m_zero(op(si, 1)) { nn = 2; } else if m_zero(op(si, 2)) { nn = 1; } else { return false; }
    let y = op(si, nn);
    ic_replace_operand(i, 1, y);
    var cond = op(si, 0);
    if use_empty(si) && has_one_use(cond) { return true; }
    let cty = vals[cond].ty;
    var bbi = i;
    let front = block_first(inst_parent(i));
    while bbi != front {
        bbi = inst_prev(bbi);
        if !guaranteed_to_transfer(bbi) { break; }
        for k in nops(bbi) {
            let o = op(bbi, k);
            if si >= 0 && o == si {
                ic_replace_use(vals[bbi].ops + (k as i32), y);
                icw_push(bbi);
            } else if cond >= 0 && o == cond {
                ic_replace_use(vals[bbi].ops + (k as i32), if nn == 1 { c_int_ty(cty, 1) } else { c_int_ty(cty, 0) });
                icw_push(bbi);
            }
        }
        if bbi == si { si = -1; }
        if bbi == cond { cond = -1; }
        if cond < 0 && si < 0 { break; }
    }
    return true;
}

// commonIDivRemTransforms(I)
fn common_idivrem_transforms(i: i32) -> i32 {
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    if divisor_has_zero_or_undef_elt(op1) { return ic_replace_inst_uses_with(i, c_poison(vals[i].ty)); }
    let ph = fold_binop_with_phi_operands(i);
    if ph >= 0 { return ph; }
    let v = simplify_value_known_non_zero(op(i, 1), i);
    if v >= 0 { return ic_replace_operand(i, 1, v); }
    if simplify_divrem_of_select_with_zero_op(i) { return i; }
    if is_imm_c(op0) && is_select_inst(op1) && is_imm_c(op(op1, 1)) && is_imm_c(op(op1, 2)) {
        let r = fold_op_into_select(i, op1, true, false);
        if r >= 0 { return r; }
    }
    return -1;
}

// commonIDivTransforms(I)
fn common_idiv_transforms(i: i32) -> i32 {
    let res = common_idivrem_transforms(i);
    if res >= 0 { return res; }
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    let signed = iop(i) == OP_SDIV;
    let ty = vals[i].ty;
    if has_apint(op1) {
        let c2 = ap_c(op1);
        let divop = if signed { OP_SDIV } else { OP_UDIV };
        if bo(op0, divop) && has_apint(op(op0, 1)) {
            let c1 = ap_c(op(op0, 1));
            let p, ov = multiply_overflows(c1, c2, signed);
            if !ov { return ic_new_binop(iop(i), op(op0, 0), c_int_ap(ty, p)); }
        }
        if bo(op0, OP_MUL) && has_apint(op(op0, 1)) && ((signed && op_nsw(op0)) || (!signed && op_nuw(op0))) {
            let x = op(op0, 0);
            let c1 = ap_c(op(op0, 1));
            let m1, q1 = is_multiple(c2, c1, signed);
            if m1 {
                let nd = ic_new_binop(iop(i), x, c_int_ap(ty, q1));
                set_exact(nd, op_exact(i));
                return nd;
            }
            let m2, q2 = is_multiple(c1, c2, signed);
            if m2 {
                let ml = ic_new_binop(OP_MUL, x, c_int_ap(ty, q2));
                set_nuw(ml, !signed && op_nuw(op0));
                set_nsw(ml, op_nsw(op0));
                return ml;
            }
        }
        if bo(op0, OP_SHL) && has_apint(op(op0, 1)) {
            let c1 = ap_c(op(op0, 1));
            let cw = c1.w as i64;
            let ok = (signed && op_nsw(op0) && ap_ult_u64(c1, (cw - 1) as u64)) || (!signed && op_nuw(op0) && ap_ult_u64(c1, cw as u64));
            if ok {
                let x = op(op0, 0);
                let c1s = ap_one_bit(cw, ap_zext64(c1) as i64);
                let m1, q1 = is_multiple(c2, c1s, signed);
                if m1 {
                    let b2 = ic_new_binop(iop(i), x, c_int_ap(ty, q1));
                    set_exact(b2, op_exact(i));
                    return b2;
                }
                let m2, q2 = is_multiple(c1s, c2, signed);
                if m2 {
                    let ml = ic_new_binop(OP_MUL, x, c_int_ap(ty, q2));
                    set_nuw(ml, !signed && op_nuw(op0));
                    set_nsw(ml, op_nsw(op0));
                    return ml;
                }
            }
        }
        // ((X * C2) + C1) / C2 --> X + C1/C2
        if signed && m_nsw_add_like(op0) && has_apint(op(op0, 1)) {
            let m = op(op0, 0);
            if bo(m, OP_MUL) && op_nsw(m) && m_specific_int_apv(op(m, 1), c2) {
                let c1 = ap_c(op(op0, 1));
                let mm, q = is_multiple(c1, c2, signed);
                if mm { return ic_new_binop_flags(OP_ADD, op(m, 0), c_int_ap(ty, q), FL_NSW); }
            }
        }
        if !signed && m_nuw_add_like(op0) && has_apint(op(op0, 1)) {
            let m = op(op0, 0);
            if bo(m, OP_MUL) && op_nuw(m) && m_specific_int_apv(op(m, 1), c2) {
                let c1 = ap_c(op(op0, 1));
                return ic_new_binop_flags(OP_ADD, op(m, 0), c_int_ap(ty, ap_udiv(c1, c2)), FL_NUW);
            }
        }
        if !ap_is_zero(c2) {
            let fd = fold_binop_into_select_or_phi(i);
            if fd >= 0 { return fd; }
        }
    }
    if m_one(op0) {
        if signed {
            var f1 = op1;
            if !is_guaranteed_not_to_be_undef(op1, -1, 0) {
                var nm: u8[>..] = []; nm.append(val_name(op1)); nm.append(".fr");
                f1 = icb_freeze(op1, nm);
            }
            let inc = icb_add(f1, op0, "");
            let cmp = icb_icmp(36, inc, c_int_ty(ty, 3), "");
            return ic_new_select_unknown_prof(cmp, f1, c_int_ty(ty, 0));
        }
        return ic_new_cast(OP_ZEXT, icb_icmp(32, op1, op0, ""), ty);
    }
    if simplify_demanded_instruction_bits(i) { return i; }
    // (X - (X rem Y)) / Y -> X / Y
    if bo(op0, OP_SUB) {
        let x = op(op0, 0);
        let z = op(op0, 1);
        if (signed && bo(z, OP_SREM) && op(z, 0) == x && op(z, 1) == op1) || (!signed && bo(z, OP_UREM) && op(z, 0) == x && op(z, 1) == op1) {
            return ic_new_binop(iop(i), x, op1);
        }
    }
    // (X << Y) / X -> 1 << Y
    if signed && bo(op0, OP_SHL) && op_nsw(op0) && op(op0, 0) == op1 { return ic_new_binop_flags(OP_SHL, c_int_ty(ty, 1), op(op0, 1), FL_NSW); }
    if !signed && bo(op0, OP_SHL) && op_nuw(op0) && op(op0, 0) == op1 { return ic_new_binop_flags(OP_SHL, c_int_ty(ty, 1), op(op0, 1), FL_NUW); }
    // X / (X * Y) -> 1 / Y if the multiplication does not overflow
    if bo(op1, OP_MUL) && (op(op1, 0) == op0 || op(op1, 1) == op0) {
        let y = if op(op1, 0) == op0 { op(op1, 1) } else { op(op1, 0) };
        if (signed && op_nsw(op1)) || (!signed && op_nuw(op1)) {
            ic_replace_operand(i, 0, c_int_ty(ty, 1));
            ic_replace_operand(i, 1, y);
            return i;
        }
    }
    // (X << Z) / (X * Y) -> (1 << Z) / Y
    if !signed && one_use(op1) && bo(op0, OP_SHL) && op_nuw(op0) && bo(op1, OP_MUL) {
        let x = op(op0, 0);
        let z = op(op0, 1);
        var y: i32 = -1;
        if op(op1, 0) == x { y = op(op1, 1); } else if op(op1, 1) == x { y = op(op1, 0); }
        if y >= 0 && op_nuw(op1) {
            let sh = icb_shl_nw(c_int_ty(ty, 1), z, "", true, false);
            let nd = ic_new_binop(OP_UDIV, sh, y);
            set_exact(nd, op_exact(i));
            return nd;
        }
    }
    let rr = fold_idiv_shl(i);
    if rr >= 0 { return ic_replace_inst_uses_with(i, rr); }
    // ((Op1 * X) / Y) / Op1 --> X / Y
    if bo(op0, iop(i)) && bo(op(op0, 0), OP_MUL) {
        let m = op(op0, 0);
        var x: i32 = -1;
        if op(m, 0) == op1 { x = op(m, 1); } else if op(m, 1) == op1 { x = op(m, 0); }
        if x >= 0 {
            let y = op(op0, 1);
            var nd: i32 = -1;
            if !signed && op_nuw(m) { nd = ic_new_binop(OP_UDIV, x, y); }
            else if signed && op_nsw(m) { nd = ic_new_binop(OP_SDIV, x, y); }
            if nd >= 0 {
                set_exact(nd, op_exact(i) && op_exact(op0));
                return nd;
            }
        }
    }
    // X / (select Cond, 1, Y) --> select Cond, X, (X / Y)
    if one_use(op1) && is_select_inst(op1) {
        let cond = op(op1, 0);
        if m_one(op(op1, 1)) && is_safe_divisor(i, op(op1, 2), signed) {
            let nd = icb_binop_fl(iop(i), op0, op(op1, 2), "", ex_flags(op_exact(i)));
            return ic_new_select_md(cond, op0, nd, op1);
        }
        if m_one(op(op1, 2)) && is_safe_divisor(i, op(op1, 1), signed) {
            let nd = icb_binop_fl(iop(i), op0, op(op1, 1), "", ex_flags(op_exact(i)));
            return ic_new_select_md(cond, nd, op0, op1);
        }
    }
    // (X * Y) / (X * Z) --> Y / Z
    if bo(op0, OP_MUL) {
        let x = op(op0, 0);
        let y = op(op0, 1);
        let nsw0 = op_nsw(op0);
        let nuw0 = op_nuw(op0);
        if bo(op1, OP_MUL) {
            for pass in 2 {
                let s = if pass == 0 { x } else { y };
                let a = if pass == 0 { y } else { x };
                var z: i32 = -1;
                if op(op1, 0) == s { z = op(op1, 1); } else if op(op1, 1) == s { z = op(op1, 0); }
                if z >= 0 {
                    let nsw1 = op_nsw(op1);
                    let nuw1 = op_nuw(op1);
                    if signed && nsw0 {
                        if nsw1 && has_apint(z) && !ap_is_all_ones(ap_c(z)) { return ic_new_binop(OP_SDIV, a, z); }
                    }
                    if !signed && nuw0 {
                        if nuw1 { return ic_new_binop(OP_UDIV, a, z); }
                        if has_apint(a) && has_apint(z) && ap_ule(ap_c(z), ap_c(a)) { return ic_new_binop(OP_UDIV, a, z); }
                    }
                }
            }
        }
    }
    return -1;
}
fn is_safe_divisor(i: i32, v: i32, signed: bool) -> bool {
    if signed { return has_apint(v) && !ap_is_zero(ap_c(v)) && !ap_is_all_ones(ap_c(v)); }
    kb_cxt = i;
    return is_known_non_zero(v, 0) && is_guaranteed_not_to_be_poison(v, i, 0);
}

// narrowUDivURem(I, IC)
fn narrow_udiv_urem(i: i32) -> i32 {
    let o = iop(i);
    let n = op(i, 0);
    let d = op(i, 1);
    let ty = vals[i].ty;
    let x = m_zext(n);
    let y = m_zext(d);
    if x >= 0 && y >= 0 && vals[x].ty == vals[y].ty && (one_use(n) || one_use(d)) {
        return ic_new_cast(OP_ZEXT, icb_binop(o, x, y, ""), ty);
    }
    if is_inst(n) && one_use(n) && x >= 0 && is_const(d) {
        let tc = get_lossless_inv_cast(d, vals[x].ty, OP_ZEXT);
        if tc < 0 { return -1; }
        return ic_new_cast(OP_ZEXT, icb_binop(o, x, tc, ""), ty);
    }
    if is_inst(d) && one_use(d) && y >= 0 && is_const(n) {
        let tc = get_lossless_inv_cast(n, vals[y].ty, OP_ZEXT);
        if tc < 0 { return -1; }
        return ic_new_cast(OP_ZEXT, icb_binop(o, tc, y, ""), ty);
    }
    return -1;
}

// visitUDiv
fn visit_udiv(i: i32) -> i32 {
    let v0 = simplify_udiv(op(i, 0), op(i, 1), op_exact(i), sq_at(i), RECURSION_LIMIT);
    if v0 >= 0 { return ic_replace_inst_uses_with(i, v0); }
    let x0 = fold_vector_binop(i);
    if x0 >= 0 { return x0; }
    let c = common_idiv_transforms(i);
    if c >= 0 { return c; }
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    let ty = vals[i].ty;
    // (X lshr C1) udiv C2 --> X udiv (C2 << C1)
    if bo(op0, OP_LSHR) && has_apint(op(op0, 1)) && has_apint(op1) {
        let c1 = ap_c(op(op0, 1));
        let c2 = ap_c(op1);
        let sh, ov = ap_ushl_ov(c2, ap_limited(c1, 0xFFFFFFFF) as i64);
        if !ov && ap_ult_u64(c1, c2.w as u64) {
            let x = op(op0, 0);
            let b2 = ic_new_binop(OP_UDIV, x, c_int_ap(vals[x].ty, sh));
            if op_exact(i) && op_exact(op0) { set_exact(b2, true); }
            return b2;
        } else if !ov { fatal("internal: ushl_ov amount"); }
    }
    // Op0 / C where C is large (negative) --> zext (Op0 >= C)
    if m_negative(op1) {
        let cmp = icb_icmp(35, op0, op1, "");
        return ic_new_zext_or_bitcast(cmp, ty);
    }
    // Op0 / (sext i1 X) --> zext (Op0 == -1)
    let sx = m_sext(op1);
    if sx >= 0 && is_int_ty1(vals[sx].ty) {
        let cmp = icb_icmp(32, op0, c_all_ones(ty), "");
        return ic_new_zext_or_bitcast(cmp, ty);
    }
    let nd = narrow_udiv_urem(i);
    if nd >= 0 { return nd; }
    // ((Op1 *nuw A) >> B) / Op1 --> A >> B
    if bo(op0, OP_LSHR) && bo(op(op0, 0), OP_MUL) && op_nuw(op(op0, 0)) {
        let m = op(op0, 0);
        var a: i32 = -1;
        if op(m, 0) == op1 { a = op(m, 1); } else if op(m, 1) == op1 { a = op(m, 0); }
        if a >= 0 {
            let ls = ic_new_binop(OP_LSHR, a, op(op0, 1));
            if op_exact(i) && op_exact(op0) { set_exact(ls, true); }
            return ls;
        }
    }
    // GetShiftableDenom
    var res = try_get_log2(op1, true);
    if res < 0 {
        kb_cxt = i;
        if is_known_pow2(op1, true, 0) {
            res = icb_binary_intrinsic(IID_cttz, op1, c_true(), "");
        }
    }
    if res >= 0 {
        var nm: u8[>..] = []; nm.append(val_name(i));
        return ic_replace_inst_uses_with(i, icb_lshr(op0, res, nm, op_exact(i)));
    }
    return -1;
}

// visitSDiv
fn visit_sdiv(i: i32) -> i32 {
    let v0 = simplify_sdiv(op(i, 0), op(i, 1), op_exact(i), sq_at(i), RECURSION_LIMIT);
    if v0 >= 0 { return ic_replace_inst_uses_with(i, v0); }
    let x0 = fold_vector_binop(i);
    if x0 >= 0 { return x0; }
    let c = common_idiv_transforms(i);
    if c >= 0 { return c; }
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    let ty = vals[i].ty;
    let sx = m_sext(op1);
    if m_all_ones(op1) || (sx >= 0 && is_int_ty1(vals[sx].ty)) { return ic_new_binop_flags(OP_SUB, c_null(ty), op0, FL_NSW); }
    if m_sign_mask(op1) { return ic_new_cast(OP_ZEXT, icb_icmp(32, op0, op1, ""), ty); }
    if op_exact(i) {
        if m_power2(op1) && m_nonneg(op1) {
            let cc = get_exact_log_base2(op1);
            return ic_new_binop_flags(OP_ASHR, op0, cc, FL_EXACT);
        }
        if bo(op1, OP_SHL) && op_nsw(op1) && m_one(op(op1, 0)) { return ic_new_binop_flags(OP_ASHR, op0, op(op1, 1), FL_EXACT); }
        if m_cint_pred(op1, IP_NEG_POWER2, true) {
            let np = ce_neg(op1);
            let cc = get_exact_log_base2(np);
            var nm: u8[>..] = []; nm.append(val_name(i)); nm.append(".neg");
            let ash = icb_ashr(op0, cc, nm, true);
            return ic_new_binop_flags(OP_SUB, c_null(vals[ash].ty), ash, FL_NSW);
        }
    }
    if has_apint(op1) {
        let op1c = ap_c(op1);
        let src = m_sext(op0);
        if one_use(op0) && src >= 0 && ty_sbits(src) >= ap_sig_bits(op1c) {
            let ndv = ce_cast(OP_TRUNC, op1, vals[src].ty);
            let nop = icb_sdiv(src, ndv, "", false);
            return ic_new_cast(OP_SEXT, nop, ty);
        }
        if !ap_is_min_signed(op1c) && bo(op0, OP_SUB) && op_nsw(op0) && m_zero_int(op(op0, 0)) {
            let b2 = ic_new_binop(OP_SDIV, op(op0, 1), c_int_ap(ty, ap_neg(op1c)));
            set_exact(b2, op_exact(i));
            return b2;
        }
    }
    // -X / Y --> -(X / Y)
    if one_use(op0) && bo(op0, OP_SUB) && op_nsw(op0) && m_zero_int(op(op0, 0)) {
        var nm: u8[>..] = []; nm.append(val_name(i));
        let d = icb_sdiv(op(op0, 1), op1, nm, op_exact(i));
        return ic_new_binop_flags(OP_SUB, c_null(vals[d].ty), d, FL_NSW);
    }
    // abs(X) / X --> X > -1 ? 1 : -1
    for k in 2 {
        let a = op(i, k);
        if one_use(a) && inst_iid(a) == IID_abs && m_one(op(a, 1)) && op(i, 1 - k) == op(a, 0) {
            let x = op(a, 0);
            let cond = icb_icmp(38, x, c_all_ones(vals[x].ty), "");
            return ic_new_select_unknown_prof(cond, c_int_ty(ty, 1), c_all_ones(ty));
        }
    }
    kb_cxt = i;
    let kd = kb_compute_all(op0, 0);
    if !op_exact(i) && (m_power2(op1) || m_cint_pred(op1, IP_NEG_POWER2, false)) && has_apint(op1) &&
       kb_min_tz(kd) >= ap_countr_zero(ap_c(op1)) {
        set_exact(i, true);
        return i;
    }
    if kb_is_nonneg(kd) {
        kb_cxt = i;
        if is_known_non_negative_v(op1, i) {
            let b2 = ic_new_binop(OP_UDIV, op0, op1);
            set_exact(b2, op_exact(i));
            return b2;
        }
        if m_cint_pred(op1, IP_NEG_POWER2, true) {
            let cnl = get_exact_log_base2(ce_neg(op1));
            var nm: u8[>..] = []; nm.append(val_name(i));
            let sh = icb_lshr(op0, cnl, nm, op_exact(i));
            return ic_new_neg(sh);
        }
        kb_cxt = i;
        if is_known_pow2(op1, true, 0) {
            let b2 = ic_new_binop(OP_UDIV, op0, op1);
            set_exact(b2, op_exact(i));
            return b2;
        }
    }
    if is_known_negation(op0, op1, false, false) {
        let bw = ty_scalar_bits(ty);
        let cond = icb_icmp(32, op0, c_int_ap(ty, ap_smin_val(bw)), "");
        return ic_new_select_unknown_prof(cond, c_int_ty(ty, 1), c_all_ones(ty));
    }
    return -1;
}
// isKnownNonNegative(V, SQ)
fn is_known_non_negative_v(v: i32, cx: i32) -> bool {
    kb_cxt = cx;
    return kb_is_nonneg(kb_compute_all(v, 0));
}

// simplifyIRemMulShl(I, IC)
var irm_x: i32 = -1;
fn irm_match_shift_or_mul_xc(o: i32) -> bool, AP, bool {
    var preserve_nsw = true;
    if bo(o, OP_MUL) && has_apint(op(o, 1)) && (irm_x < 0 || op(o, 0) == irm_x) {
        if irm_x < 0 { irm_x = op(o, 0); }
        return true, ap_c(op(o, 1)), preserve_nsw;
    }
    if bo(o, OP_SHL) && has_apint(op(o, 1)) && (irm_x < 0 || op(o, 0) == irm_x) {
        if irm_x < 0 { irm_x = op(o, 0); }
        let t = ap_c(op(o, 1));
        preserve_nsw = ap_ult_u64(t, ((t.w as i64) - 1) as u64);
        return true, ap_shl_ap(ap_u64(1, t.w as i64), t), preserve_nsw;
    }
    irm_x = -1;
    return false, ap_zero(1), preserve_nsw;
}
fn irm_match_shift_cx(o: i32) -> bool, AP {
    if bo(o, OP_SHL) && has_apint(op(o, 0)) && (irm_x < 0 || op(o, 1) == irm_x) {
        if irm_x < 0 { irm_x = op(o, 1); }
        return true, ap_c(op(o, 0));
    }
    irm_x = -1;
    return false, ap_zero(1);
}
fn simplify_irem_mul_shl(i: i32) -> i32 {
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    var y = ap_zero(1);
    var z = ap_zero(1);
    var shift_by_x = false;
    var p0 = true;
    var p1 = true;
    irm_x = -1;
    let m0, yy, pn0 = irm_match_shift_or_mul_xc(op0);
    var matched = false;
    if m0 {
        let m1, zz, pn1 = irm_match_shift_or_mul_xc(op1);
        if m1 { y = yy; z = zz; p0 = pn0; p1 = pn1; matched = true; }
    }
    if !matched {
        // the second alternative starts with whatever X the failed attempt left (reset to null)
        let a0, yy2 = irm_match_shift_cx(op0);
        if a0 {
            let a1, zz2 = irm_match_shift_cx(op1);
            if a1 { y = yy2; z = zz2; shift_by_x = true; matched = true; }
        }
    }
    if !matched { return -1; }
    let x = irm_x;
    let is_srem = iop(i) == OP_SREM;
    let b0nsw = p0 && op_nsw(op0);
    let b0nuw = op_nuw(op0);
    let b0nw = if is_srem { b0nsw } else { b0nuw };
    let remyz = if is_srem { ap_srem(y, z) } else { ap_urem(y, z) };
    if ap_is_zero(remyz) && b0nw { return ic_replace_inst_uses_with(i, c_null(vals[i].ty)); }
    let b1nsw = p1 && op_nsw(op1);
    let b1nuw = op_nuw(op1);
    let b1nw = if is_srem { b1nsw } else { b1nuw };
    if ap_eq(remyz, y) && b1nw {
        let b = irm_create(i, y, x, shift_by_x);
        set_nsw(b, is_srem || b0nsw);
        set_nuw(b, !is_srem || b0nuw);
        return b;
    }
    if ap_uge(y, z) && (if is_srem { b0nsw && b1nsw } else { b0nuw }) {
        let b = irm_create(i, remyz, x, shift_by_x);
        set_nsw(b, true);
        set_nuw(b, b0nuw);
        return b;
    }
    return -1;
}
fn irm_create(i: i32, c: AP, x: i32, shift_by_x: bool) -> i32 {
    let rs = c_int_ap(vals[i].ty, c);
    if shift_by_x { return ic_new_binop(OP_SHL, rs, x); }
    return ic_new_binop(OP_MUL, x, rs);
}

// commonIRemTransforms(I)
fn common_irem_transforms(i: i32) -> i32 {
    let res = common_idivrem_transforms(i);
    if res >= 0 { return res; }
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    if is_constant(op1) && is_inst(op0) {
        if is_select_inst(op0) {
            let r = fold_op_into_select(i, op0, false, false);
            if r >= 0 { return r; }
        } else if is_phi_inst(op0) {
            if has_apint(op1) {
                let c = ap_c(op1);
                if !ap_is_zero(c) && (iop(i) == OP_UREM || !ap_is_min_signed(c)) {
                    let nv = fold_op_into_phi(i, op0, false);
                    if nv >= 0 { return nv; }
                }
            }
        }
        if simplify_demanded_instruction_bits(i) { return i; }
    }
    let r = simplify_irem_mul_shl(i);
    if r >= 0 { return r; }
    return -1;
}

// visitURem
fn visit_urem(i: i32) -> i32 {
    let v0 = simplify_urem(op(i, 0), op(i, 1), sq_at(i), RECURSION_LIMIT);
    if v0 >= 0 { return ic_replace_inst_uses_with(i, v0); }
    let x0 = fold_vector_binop(i);
    if x0 >= 0 { return x0; }
    let c = common_irem_transforms(i);
    if c >= 0 { return c; }
    let nr = narrow_udiv_urem(i);
    if nr >= 0 { return nr; }
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    let ty = vals[i].ty;
    kb_cxt = i;
    if is_known_pow2(op1, true, 0) {
        let ad = icb_add(op1, c_all_ones(ty), "");
        return ic_new_binop(OP_AND, op0, ad);
    }
    if m_one(op0) {
        let cmp = icb_icmp(33, op1, c_int_ty(ty, 1), "");
        return ic_new_zext_or_bitcast(cmp, ty);
    }
    if m_negative(op1) {
        var f0 = op0;
        if !is_guaranteed_not_to_be_undef(op0, -1, 0) {
            var nm: u8[>..] = []; nm.append(val_name(op0)); nm.append(".fr");
            f0 = icb_freeze(op0, nm);
        }
        let cmp = icb_icmp(36, f0, op1, "");
        let sb = icb_sub(f0, op1, "");
        return ic_new_select_unknown_prof(cmp, f0, sb);
    }
    let sx = m_sext(op1);
    if sx >= 0 && is_int_ty1(vals[sx].ty) {
        var f0 = op0;
        if !is_guaranteed_not_to_be_undef(op0, -1, 0) {
            var nm: u8[>..] = []; nm.append(val_name(op0)); nm.append(".frozen");
            f0 = icb_freeze(op0, nm);
        }
        let cmp = icb_icmp(32, f0, c_all_ones(ty), "");
        return ic_new_select_unknown_prof(cmp, c_null(ty), f0);
    }
    if bo(op0, OP_ADD) && m_one(op(op0, 1)) {
        let x = op(op0, 0);
        let v = simplify_icmp(cp(36, false), x, op1, sq_at(i), RECURSION_LIMIT);
        if v >= 0 && m_one(v) {
            var f0 = op0;
            if !is_guaranteed_not_to_be_undef(op0, -1, 0) {
                var nm: u8[>..] = []; nm.append(val_name(op0)); nm.append(".frozen");
                f0 = icb_freeze(op0, nm);
            }
            let cmp = icb_icmp(32, f0, op1, "");
            return ic_new_select_unknown_prof(cmp, c_null(ty), f0);
        }
    }
    return -1;
}

// visitSRem
fn visit_srem(i: i32) -> i32 {
    let v0 = simplify_srem(op(i, 0), op(i, 1), sq_at(i), RECURSION_LIMIT);
    if v0 >= 0 { return ic_replace_inst_uses_with(i, v0); }
    let x0 = fold_vector_binop(i);
    if x0 >= 0 { return x0; }
    let c = common_irem_transforms(i);
    if c >= 0 { return c; }
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    let ty = vals[i].ty;
    // X % -Y -> X % Y
    if m_negative(op1) && has_apint(op1) && !ap_is_min_signed(ap_c(op1)) {
        return ic_replace_operand(i, 1, c_int_ap(ty, ap_neg(ap_c(op1))));
    }
    // -X srem Y --> -(X srem Y)
    if one_use(op0) && bo(op0, OP_SUB) && op_nsw(op0) && m_zero_int(op(op0, 0)) {
        let s = icb_srem(op(op0, 1), op1, "");
        return ic_new_binop_flags(OP_SUB, c_null(vals[s].ty), s, FL_NSW);
    }
    let bw = ty_scalar_bits(ty);
    let mask = ap_sign_mask(bw);
    kb_cxt = i;
    if masked_value_is_zero(op1, mask, 0) {
        kb_cxt = i;
        if masked_value_is_zero(op0, mask, 0) { return ic_new_binop(OP_UREM, op0, op1); }
    }
    let k = vals[op1].kind;
    if k == VK_CVECTOR || k == VK_CDVECTOR {
        let n = ty_count(vals[op1].ty);
        var has_neg = false;
        var missing = false;
        for e in n {
            let el = agg_elem(op1, e);
            if el < 0 { missing = true; break; }
            if vals[el].kind == VK_CINT && ap_is_neg(ci_ap(el)) { has_neg = true; }
        }
        if has_neg && !missing {
            let mark = is_ops.len;
            for e in n {
                var el = agg_elem(op1, e);
                if vals[el].kind == VK_CINT && ap_is_neg(ci_ap(el)) { el = ce_neg(el); }
                is_ops.push(el);
            }
            let nr = c_vector_get(vals[op1].ty, is_ops[mark..is_ops.len]);
            is_ops.resize(mark);
            if nr != op1 { return ic_replace_operand(i, 1, nr); }
        }
    }
    return -1;
}
// ConstantVector::get(Elts)
fn c_vector_get(ty: i32, elts: const i32[:]) -> i32 { c_aggregate(ty, elts) }
