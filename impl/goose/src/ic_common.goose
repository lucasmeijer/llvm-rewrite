// InstCombine helpers shared by the visitors: ports from llvm/lib/Transforms/InstCombine/InstructionCombining.cpp
// (SimplifyAssociativeOrCommutative, simplifyAssocCastAssoc, matchSymmetricPair, tryFactorization,
// tryFactorizationFolds, foldUsingDistributiveLaws, SimplifySelectsFeedingBinaryOp, FoldOpIntoSelect,
// foldOpIntoPhi, foldBinOpSelectBinOp, foldBinopWithPhiOperands, foldBinopWithRecurrence,
// foldBinOpIntoSelectOrPhi, foldVectorBinop, narrowMathIfNoOverflow, getFreelyInvertedImpl,
// tryFoldInstWithCtpopWithNot, foldBinOpShiftWithShift, foldBinOpOfSelectAndCastOfSelectCondition,
// dyn_castNegVal, foldBinopOfSextBoolToSelect) and llvm/include/llvm/Transforms/InstCombine/InstCombiner.h
// (getComplexity, AddOne/SubOne, shouldAvoidAbsorbingNotIntoSelect, canFreelyInvertAllUsersOf).
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
import instsimplify;
import apint;
import overflow;
import ic;
import ic_combining;
import ic_builder;
import ic_andorxor;
import cfgutil;
import datalayout;
import memloc;

// ---------------------------------------------------------------------------------------------
// Small matchers (PatternMatch.h). BinaryOp_match and CastInst_match match instructions only.

fn bo(v: i32, o: i64) -> bool { is_inst_op(v, o) }
fn o0(v: i32) -> i32 { op(v, 0) }
fn o1(v: i32) -> i32 { op(v, 1) }
fn m_logical_and(v: i32) -> bool { m_logical(v, true) }
fn m_logical_or(v: i32) -> bool { m_logical(v, false) }
fn is_shift_op(o: i64) -> bool { o == OP_SHL || o == OP_LSHR || o == OP_ASHR }
fn is_logic_op(o: i64) -> bool { o == OP_AND || o == OP_OR || o == OP_XOR }
fn is_cmp_inst(v: i32) -> bool { is_inst(v) && (iop(v) == OP_ICMP || iop(v) == OP_FCMP) }
fn is_select_inst(v: i32) -> bool { is_inst_op(v, OP_SELECT) }
fn is_phi_inst(v: i32) -> bool { is_inst_op(v, OP_PHI) }
fn is_cast_inst(v: i32) -> bool { is_inst(v) && is_cast_op(iop(v)) }
fn is_binop_inst(v: i32) -> bool { is_inst(v) && is_binary_op(iop(v)) }
// m_ZExt / m_SExt / m_ZExtOrSExt: the source or -1
fn m_zext(v: i32) -> i32 { if is_inst_op(v, OP_ZEXT) { op(v, 0) } else { -1 } }
fn m_sext(v: i32) -> i32 { if is_inst_op(v, OP_SEXT) { op(v, 0) } else { -1 } }
fn m_zext_or_sext(v: i32) -> i32 { if is_inst_op(v, OP_ZEXT) || is_inst_op(v, OP_SEXT) { op(v, 0) } else { -1 } }
// m_SExtLike: sext, or zext nneg
fn m_sext_like(v: i32) -> i32 {
    if is_inst_op(v, OP_SEXT) { return op(v, 0); }
    if is_inst_op(v, OP_ZEXT) && (insts[inst_of(v)].flags & FL_NNEG) != 0 { return op(v, 0); }
    return -1;
}
fn m_trunc(v: i32) -> i32 { if is_inst_op(v, OP_TRUNC) { op(v, 0) } else { -1 } }
// m_AddLike: add, or disjoint or
fn m_add_like(v: i32) -> bool { bo(v, OP_ADD) || (bo(v, OP_OR) && op_disjoint(v)) }
fn m_nuw_add_like(v: i32) -> bool { (bo(v, OP_ADD) && op_nuw(v)) || (bo(v, OP_OR) && op_disjoint(v)) }
fn m_nsw_add_like(v: i32) -> bool { (bo(v, OP_ADD) && op_nsw(v)) || (bo(v, OP_OR) && op_disjoint(v)) }
fn m_disjoint_or(v: i32) -> bool { bo(v, OP_OR) && op_disjoint(v) }
fn is_imm_c(v: i32) -> bool { v >= 0 && m_imm_constant(v) }
fn ap_c(v: i32) -> AP { ci_ap(m_apint(v)) }
fn has_apint(v: i32) -> bool { v >= 0 && m_apint(v) >= 0 }
fn has_apint_poison(v: i32) -> bool { v >= 0 && m_apint_ap(v, true) >= 0 }
fn ap_cp(v: i32) -> AP { ci_ap(m_apint_ap(v, true)) }
fn is_int_ty1(t: i32) -> bool { is_int_or_int_vec_w(t, 1) }
fn ty_sbits(v: i32) -> i64 { ty_scalar_bits(vals[v].ty) }
fn sq_at(i: i32) -> SQ { sq_new(i) }
// m_MaxOrMin intrinsics: sets mm_a / mm_b
fn is_minmax_iid(id: i32) -> bool { id == IID_smax || id == IID_smin || id == IID_umax || id == IID_umin }
fn minmax_inverse_iid(id: i32) -> i64 {
    if id == IID_smax { return IID_smin; }
    if id == IID_smin { return IID_smax; }
    if id == IID_umax { return IID_umin; }
    return IID_umax;
}
// MinMaxIntrinsic::getPredicate
fn minmax_pred(id: i32) -> i64 {
    if id == IID_smax { return 38; }
    if id == IID_smin { return 40; }
    if id == IID_umax { return 34; }
    return 36;
}
fn icmp_swapped_pred(p: i64) -> i64 {
    match p { 34 => 36, 35 => 37, 36 => 34, 37 => 35, 38 => 40, 39 => 41, 40 => 38, 41 => 39, _ => p }
}
fn icmp_is_signed(p: i64) -> bool { p >= 38 && p <= 41 }
fn icmp_is_unsigned(p: i64) -> bool { p >= 34 && p <= 37 }
fn icmp_is_equality(p: i64) -> bool { p == 32 || p == 33 }
fn icmp_is_lt(p: i64) -> bool { p == 36 || p == 37 || p == 40 || p == 41 }
fn icmp_is_gt(p: i64) -> bool { p == 34 || p == 35 || p == 38 || p == 39 }

// InstCombiner::getComplexity
fn get_complexity(v: i32) -> i64 {
    if is_constant(v) { return if is_undef_or_poison(v) { 0 } else { 1 }; }
    if is_cast_inst(v) || m_neg(v) >= 0 || m_not(v) >= 0 || m_fneg(v) >= 0 { return 2; }
    return 3;
}
// m_FNeg: fneg X, or fsub -0.0, X
fn m_fneg_v(v: i32) -> bool {
    if is_inst_op(v, OP_FNEG) { return true; }
    return is_inst_op(v, OP_FSUB) && m_neg_zero_fp(op(v, 0));
}

// InstCombiner::AddOne / SubOne
fn add_one(c: i32) -> i32 { ce_binop(OP_ADD, c, c_int_ty(vals[c].ty, 1), 0) }
fn sub_one(c: i32) -> i32 { ce_binop(OP_SUB, c, c_int_ty(vals[c].ty, 1), 0) }

// Instruction::swapOperands for a commutative binary operator
fn swap_operands(i: i32) {
    let a = op(i, 0);
    let b = op(i, 1);
    set_op(i, 0, b);
    set_op(i, 1, a);
}

// maintainNoSignedWrap(I, B, C)
fn maintain_no_signed_wrap(i: i32, b: i32, c: i32) -> bool {
    if !is_overflowing_op(iop(i)) || !op_nsw(i) { return false; }
    if !has_apint(b) || !has_apint(c) { return false; }
    let bv = ap_c(b);
    let cv = ap_c(c);
    let o = iop(i);
    if o == OP_ADD { let r, ov = ap_sadd_ov(bv, cv); return !ov; }
    if o == OP_SUB { let r, ov = ap_ssub_ov(bv, cv); return !ov; }
    if o == OP_MUL { let r, ov = ap_smul_ov(bv, cv); return !ov; }
    return false;
}
fn is_overflowing_op(o: i64) -> bool { o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_SHL }
fn has_nuw(i: i32) -> bool { is_overflowing_op(iop(i)) && op_nuw(i) }
fn has_nsw(i: i32) -> bool { is_overflowing_op(iop(i)) && op_nsw(i) }
fn set_nuw(i: i32, b: bool) { let ii = inst_of(i); if b { insts[ii].flags |= FL_NUW; } else { insts[ii].flags &= ~FL_NUW; } }
fn set_nsw(i: i32, b: bool) { let ii = inst_of(i); if b { insts[ii].flags |= FL_NSW; } else { insts[ii].flags &= ~FL_NSW; } }
fn set_exact(i: i32, b: bool) { let ii = inst_of(i); if b { insts[ii].flags |= FL_EXACT; } else { insts[ii].flags &= ~FL_EXACT; } }
fn set_disjoint(i: i32, b: bool) { let ii = inst_of(i); if b { insts[ii].flags |= FL_DISJOINT; } else { insts[ii].flags &= ~FL_DISJOINT; } }
fn set_nneg(i: i32, b: bool) { let ii = inst_of(i); if b { insts[ii].flags |= FL_NNEG; } else { insts[ii].flags &= ~FL_NNEG; } }
fn is_fp_op(i: i32) -> bool { is_fp_math_operator(i) }
// Instruction::copyIRFlags(V)
fn copy_ir_flags(dst: i32, src: i32) {
    if !is_inst(dst) || !is_inst(src) { return; }
    let sf = op_flags(src);
    let d = inst_of(dst);
    let o = iop(dst);
    let so = opcode_of(src);
    var f: u8 = 0;
    if is_overflowing_op(o) && is_overflowing_op(so) { f |= sf & (FL_NUW | FL_NSW); }
    if (o == OP_UDIV || o == OP_SDIV || o == OP_LSHR || o == OP_ASHR) && (so == OP_UDIV || so == OP_SDIV || so == OP_LSHR || so == OP_ASHR) { f |= sf & FL_EXACT; }
    if o == OP_OR && so == OP_OR { f |= sf & FL_DISJOINT; }
    if (o == OP_ZEXT || o == OP_UITOFP) && (so == OP_ZEXT || so == OP_UITOFP) { f |= sf & FL_NNEG; }
    if o == OP_ICMP && so == OP_ICMP { f |= sf & FL_SAMESIGN; }
    insts[d].flags = f;
    if is_fp_math_operator(dst) && is_fp_math_operator(src) { insts[d].fmf = insts[inst_of(src)].fmf; }
}

// ---------------------------------------------------------------------------------------------
// SimplifyAssociativeOrCommutative

// simplifyAssocCastAssoc(BinOp1, IC)
fn simplify_assoc_cast_assoc(b1: i32) -> bool {
    let cast = op(b1, 0);
    if !is_cast_inst(cast) || !one_use(cast) { return false; }
    if iop(cast) != OP_ZEXT { return false; }
    if !is_logic_op(iop(b1)) { return false; }
    let ao = iop(b1);
    let b2 = op(cast, 0);
    if !is_binop_inst(b2) || !one_use(b2) || iop(b2) != ao { return false; }
    let c1 = op(b1, 1);
    let c2 = op(b2, 1);
    if !is_const(c1) || !is_const(c2) { return false; }
    let dt = vals[c1].ty;
    let cc2 = cf_fold_cast_operand(OP_ZEXT, c2, dt);
    if cc2 < 0 { return false; }
    let fc = cf_fold_binop_operands(ao, c1, cc2);
    if fc < 0 { return false; }
    ic_replace_operand(cast, 0, op(b2, 0));
    ic_replace_operand(b1, 1, fc);
    drop_poison_generating_flags(b1);
    drop_poison_generating_flags(cast);
    return true;
}

// matchSymmetricPair(LHS, RHS): sets sp_a/sp_b
var sp_a: i32 = -1;
var sp_b: i32 = -1;
fn match_symmetric_pair(l: i32, r: i32) -> bool {
    if !is_inst(l) || !is_inst(r) || iop(l) != iop(r) { return false; }
    let o = iop(l);
    if o == OP_PHI { return ic_match_symmetric_phis(l, r); }
    if o == OP_SELECT {
        let c = op(l, 0);
        let t = op(l, 1);
        let f = op(l, 2);
        if c == op(r, 0) && t == op(r, 2) && f == op(r, 1) { sp_a = t; sp_b = f; return true; }
        return false;
    }
    if o == OP_CALL {
        let li = inst_iid(l);
        let ri = inst_iid(r);
        if is_minmax_iid(li) && is_minmax_iid(ri) && minmax_pred(li) == icmp_swapped_pred(minmax_pred(ri)) {
            let la = op(l, 0); let lb = op(l, 1);
            let ra = op(r, 0); let rb = op(r, 1);
            if (la == ra && lb == rb) || (la == rb && lb == ra) { sp_a = la; sp_b = lb; return true; }
        }
        return false;
    }
    return false;
}
// matchSymmetricPhiNodesPair(LHS, RHS): sets sp_a/sp_b
fn ic_match_symmetric_phis(l: i32, r: i32) -> bool {
    if inst_parent(l) != inst_parent(r) { return false; }
    let n = nops(l);
    if n < 2 { return false; }
    if nops(r) != n { return false; }
    for k in n { if phi_block(l, k) != phi_block(r, k) { return false; } }
    let l0 = op(l, 0);
    let r0 = op(r, 0);
    for k in 1..n {
        let l1 = op(l, k);
        let r1 = op(r, k);
        if (l0 == l1 && r0 == r1) || (l0 == r1 && r0 == l1) { continue; }
        return false;
    }
    sp_a = l0;
    sp_b = r0;
    return true;
}

// Instruction::isAssociative(): fmul needs reassoc, fadd reassoc and nsz
fn ic_inst_is_associative(i: i32) -> bool {
    let o = iop(i);
    if is_associative(o) { return true; }
    let f = insts[inst_of(i)].fmf;
    if o == OP_FMUL { return (f & FMF_REASSOC) != 0; }
    if o == OP_FADD { return (f & FMF_REASSOC) != 0 && (f & FMF_NSZ) != 0; }
    return false;
}
fn simplify_assoc_or_comm(i: i32) -> bool {
    let o = iop(i);
    var changed = false;
    loop {
        if is_commutative(o) && get_complexity(op(i, 0)) < get_complexity(op(i, 1)) {
            swap_operands(i);
            changed = true;
        }
        if is_commutative(o) {
            if match_symmetric_pair(op(i, 0), op(i, 1)) {
                let a = sp_a; let b = sp_b;
                ic_replace_operand(i, 0, a);
                ic_replace_operand(i, 1, b);
                changed = true;
            }
        }
        let op0 = if is_binop_inst(op(i, 0)) { op(i, 0) } else { -1 };
        let op1 = if is_binop_inst(op(i, 1)) { op(i, 1) } else { -1 };
        if ic_inst_is_associative(i) {
            if op0 >= 0 && iop(op0) == o {
                let a = op(op0, 0); let b = op(op0, 1); let c = op(i, 1);
                let v = simplify_binop(o, b, c, sq_at(i), RECURSION_LIMIT);
                if v >= 0 {
                    ic_replace_operand(i, 0, a);
                    ic_replace_operand(i, 1, v);
                    let nuw = has_nuw(i) && has_nuw(op0);
                    let nsw = maintain_no_signed_wrap(i, b, c) && has_nsw(op0);
                    if o == OP_OR { set_disjoint(i, false); }
                    if is_overflowing_op(o) { set_nuw(i, nuw); set_nsw(i, nsw); }
                    changed = true;
                    continue;
                }
            }
            if op1 >= 0 && iop(op1) == o {
                let a = op(i, 0); let b = op(op1, 0); let c = op(op1, 1);
                let v = simplify_binop(o, a, b, sq_at(i), RECURSION_LIMIT);
                if v >= 0 {
                    ic_replace_operand(i, 0, v);
                    ic_replace_operand(i, 1, c);
                    if !is_fp_op(i) { drop_poison_generating_flags(i); }
                    changed = true;
                    continue;
                }
            }
        }
        if ic_inst_is_associative(i) && is_commutative(o) {
            if simplify_assoc_cast_assoc(i) { changed = true; continue; }
            if op0 >= 0 && iop(op0) == o {
                let a = op(op0, 0); let b = op(op0, 1); let c = op(i, 1);
                let v = simplify_binop(o, c, a, sq_at(i), RECURSION_LIMIT);
                if v >= 0 {
                    ic_replace_operand(i, 0, v);
                    ic_replace_operand(i, 1, b);
                    if !is_fp_op(i) { drop_poison_generating_flags(i); }
                    changed = true;
                    continue;
                }
            }
            if op1 >= 0 && iop(op1) == o {
                let a = op(i, 0); let b = op(op1, 0); let c = op(op1, 1);
                let v = simplify_binop(o, c, a, sq_at(i), RECURSION_LIMIT);
                if v >= 0 {
                    ic_replace_operand(i, 0, b);
                    ic_replace_operand(i, 1, v);
                    if !is_fp_op(i) { drop_poison_generating_flags(i); }
                    changed = true;
                    continue;
                }
            }
            if op0 >= 0 && op1 >= 0 && iop(op0) == o && iop(op1) == o && one_use(op0) && one_use(op1) &&
               is_const(op(op0, 1)) && is_const(op(op1, 1)) {
                let a = op(op0, 0); let c1 = op(op0, 1);
                let b = op(op1, 0); let c2 = op(op1, 1);
                let cres = cf_fold_binop_operands(o, c1, c2);
                if cres >= 0 {
                    let nuw = has_nuw(i) && has_nuw(op0) && has_nuw(op1);
                    let nbo = if nuw && o == OP_ADD { ic_new_binop_flags(o, a, b, FL_NUW) } else { ic_new_binop(o, a, b) };
                    if is_fp_op(nbo) { insts[inst_of(nbo)].fmf = insts[inst_of(i)].fmf & insts[inst_of(op0)].fmf & insts[inst_of(op1)].fmf; }
                    ic_insert_new_with(nbo, i);
                    ic_take_name(nbo, op1);
                    ic_replace_operand(i, 0, nbo);
                    ic_replace_operand(i, 1, cres);
                    if !is_fp_op(i) { drop_poison_generating_flags(i); }
                    if nuw { set_nuw(i, true); }
                    changed = true;
                    continue;
                }
            }
        }
        return changed;
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// Distributive laws

fn left_distributes_over_right(l: i64, r: i64) -> bool {
    if l == OP_AND { return r == OP_OR || r == OP_XOR; }
    if l == OP_OR { return r == OP_AND; }
    if l == OP_MUL { return r == OP_ADD || r == OP_SUB; }
    return false;
}
fn right_distributes_over_left(l: i64, r: i64) -> bool {
    if is_commutative(r) { return left_distributes_over_right(r, l); }
    return is_logic_op(l) && is_shift_op(r);
}
// getIdentityValue(Opcode, V)
fn get_identity_value(o: i64, v: i32) -> i32 {
    if is_constant(v) { return -1; }
    return binop_identity(o, vals[v].ty, false);
}

// getBinOpsForFactorization: returns opcode, sets gbf_l / gbf_r
var gbf_l: i32 = -1;
var gbf_r: i32 = -1;
fn get_binops_for_factorization(top: i64, opv: i32, other: i32) -> i64 {
    gbf_l = op(opv, 0);
    gbf_r = op(opv, 1);
    if top == OP_ADD || top == OP_SUB {
        if bo(opv, OP_SHL) && is_imm_c(op(opv, 1)) {
            gbf_r = cf_binop(OP_SHL, c_int_ty(vals[opv].ty, 1), op(opv, 1));
            if gbf_r < 0 { fatal("internal: constant folding of immediate constants failed"); }
            return OP_MUL;
        }
    }
    if is_logic_op(top) {
        if other >= 0 && iop(other) == OP_ASHR && bo(opv, OP_LSHR) && m_nonneg(op(opv, 0)) { return OP_ASHR; }
    }
    return iop(opv);
}

// tryFactorization(I, SQ, Builder, InnerOpcode, A, B, C, D)
fn try_factorization(i: i32, inner: i64, a: i32, b: i32, c0: i32, d0: i32) -> i32 {
    var c = c0;
    var d = d0;
    var v: i32 = -1;
    var ret: i32 = -1;
    let lhs = op(i, 0);
    let rhs = op(i, 1);
    let top = iop(i);
    let inner_comm = is_commutative(inner);
    if left_distributes_over_right(inner, top) {
        if a == c || (inner_comm && a == d) {
            if a != c { let t = c; c = d; d = t; }
            v = simplify_binop(top, b, d, sq_at(i), RECURSION_LIMIT);
            if v < 0 && (one_use(lhs) || one_use(rhs)) {
                var nm: u8[>..] = []; nm.append(val_name(rhs));
                v = icb_binop(top, b, d, nm);
            }
            if v >= 0 { ret = icb_binop(inner, a, v, ""); }
        }
    }
    if ret < 0 && right_distributes_over_left(top, inner) {
        if b == d || (inner_comm && b == c) {
            if b != d { let t = c; c = d; d = t; }
            v = simplify_binop(top, a, c, sq_at(i), RECURSION_LIMIT);
            if v < 0 && (one_use(lhs) || one_use(rhs)) {
                var nm: u8[>..] = []; nm.append(val_name(lhs));
                v = icb_binop(top, a, c, nm);
            }
            if v >= 0 { ret = icb_binop(inner, v, b, ""); }
        }
    }
    if ret < 0 { return -1; }
    ic_take_name(ret, i);
    if is_binop_inst(ret) {
        var nsw = false;
        var nuw = false;
        if is_overflowing_op(top) { nsw = op_nsw(i); nuw = op_nuw(i); }
        if is_overflowing_op(opcode_of(lhs)) { nsw = nsw && op_nsw(lhs); nuw = nuw && op_nuw(lhs); }
        if is_overflowing_op(opcode_of(rhs)) { nsw = nsw && op_nsw(rhs); nuw = nuw && op_nuw(rhs); }
        if top == OP_ADD && inner == OP_MUL {
            if has_apint(v) && !ap_is_min_signed(ap_c(v)) { set_nsw(ret, nsw); }
            set_nuw(ret, nuw);
        }
    }
    return ret;
}

// tryFactorizationFolds(I)
fn try_factorization_folds(i: i32) -> i32 {
    let lhs = op(i, 0);
    let rhs = op(i, 1);
    let op0 = if is_binop_inst(lhs) { lhs } else { -1 };
    let op1 = if is_binop_inst(rhs) { rhs } else { -1 };
    let top = iop(i);
    var a: i32 = -1; var b: i32 = -1; var c: i32 = -1; var d: i32 = -1;
    var lo: i64 = -1; var ro: i64 = -1;
    if op0 >= 0 { lo = get_binops_for_factorization(top, op0, op1); a = gbf_l; b = gbf_r; }
    if op1 >= 0 { ro = get_binops_for_factorization(top, op1, op0); c = gbf_l; d = gbf_r; }
    if op0 >= 0 && op1 >= 0 && lo == ro {
        let v = try_factorization(i, lo, a, b, c, d);
        if v >= 0 { return v; }
    }
    if op0 >= 0 {
        let id = get_identity_value(lo, rhs);
        if id >= 0 {
            let v = try_factorization(i, lo, a, b, rhs, id);
            if v >= 0 { return v; }
        }
    }
    if op1 >= 0 {
        let id = get_identity_value(ro, lhs);
        if id >= 0 {
            let v = try_factorization(i, ro, lhs, id, c, d);
            if v >= 0 { return v; }
        }
    }
    return -1;
}

// foldUsingDistributiveLaws(I)
fn fold_using_distributive_laws(i: i32) -> i32 {
    let lhs = op(i, 0);
    let rhs = op(i, 1);
    let op0 = if is_binop_inst(lhs) { lhs } else { -1 };
    let op1 = if is_binop_inst(rhs) { rhs } else { -1 };
    let top = iop(i);
    let r0 = try_factorization_folds(i);
    if r0 >= 0 { return r0; }
    if op0 >= 0 && right_distributes_over_left(iop(op0), top) {
        let a = op(op0, 0); let b = op(op0, 1); let c = rhs;
        let inner = iop(op0);
        let q = sq_without_undef(sq_at(i));
        let l = simplify_binop(top, a, c, q, RECURSION_LIMIT);
        let r = simplify_binop(top, b, c, q, RECURSION_LIMIT);
        if l >= 0 && r >= 0 {
            let x = icb_binop(inner, l, r, "");
            ic_take_name(x, i);
            return x;
        }
        if l >= 0 && l == binop_identity(inner, vals[l].ty, false) {
            let x = icb_binop(top, b, c, "");
            ic_take_name(x, i);
            return x;
        }
        if r >= 0 && r == binop_identity(inner, vals[r].ty, false) {
            let x = icb_binop(top, a, c, "");
            ic_take_name(x, i);
            return x;
        }
    }
    if op1 >= 0 && left_distributes_over_right(top, iop(op1)) {
        let a = lhs; let b = op(op1, 0); let c = op(op1, 1);
        let inner = iop(op1);
        let q = sq_without_undef(sq_at(i));
        let l = simplify_binop(top, a, b, q, RECURSION_LIMIT);
        let r = simplify_binop(top, a, c, q, RECURSION_LIMIT);
        if l >= 0 && r >= 0 {
            let x = icb_binop(inner, l, r, "");
            ic_take_name(x, i);
            return x;
        }
        if l >= 0 && l == binop_identity(inner, vals[l].ty, false) {
            let x = icb_binop(top, a, c, "");
            ic_take_name(x, i);
            return x;
        }
        if r >= 0 && r == binop_identity(inner, vals[r].ty, false) {
            let x = icb_binop(top, a, b, "");
            ic_take_name(x, i);
            return x;
        }
    }
    return simplify_selects_feeding_binop(i, lhs, rhs);
}

// SimplifySelectsFeedingBinaryOp(I, LHS, RHS)
fn simplify_selects_feeding_binop(i: i32, lhs: i32, rhs: i32) -> i32 {
    let lsel = is_select_inst(lhs);
    let rsel = is_select_inst(rhs);
    if !lsel && !rsel { return -1; }
    let si = if lsel { lhs } else { rhs };
    let saved_fmf = icb_fmf;
    var fmf: u8 = 0;
    if is_fp_op(i) { fmf = insts[inst_of(i)].fmf; icb_fmf = fmf; }
    let o = iop(i);
    let q = sq_at(i);
    var cond: i32 = -1;
    var tv: i32 = -1;
    var fv: i32 = -1;
    var a: i32 = -1; var b: i32 = -1; var c: i32 = -1;
    var d: i32 = -1; var e: i32 = -1; var f: i32 = -1;
    if lsel { a = op(lhs, 0); b = op(lhs, 1); c = op(lhs, 2); }
    if rsel { d = op(rhs, 0); e = op(rhs, 1); f = op(rhs, 2); }
    var res: i32 = -1;
    var done = false;
    if lsel && rsel && a == d {
        cond = a;
        tv = simplify_binop_fmf(o, b, e, fmf, q, RECURSION_LIMIT);
        fv = simplify_binop_fmf(o, c, f, fmf, q, RECURSION_LIMIT);
        if one_use(lhs) && one_use(rhs) {
            if fv >= 0 && tv < 0 { tv = icb_binop(o, b, e, ""); }
            else if tv >= 0 && fv < 0 { fv = icb_binop(o, c, f, ""); }
        }
    } else if lsel && one_use(lhs) {
        cond = a;
        tv = simplify_binop_fmf(o, b, rhs, fmf, q, RECURSION_LIMIT);
        fv = simplify_binop_fmf(o, c, rhs, fmf, q, RECURSION_LIMIT);
        res = ssfb_add_negate(i, o, cond, tv, fv, b, c, rhs, si);
        if res >= 0 { done = true; }
    } else if rsel && one_use(rhs) {
        cond = d;
        tv = simplify_binop_fmf(o, lhs, e, fmf, q, RECURSION_LIMIT);
        fv = simplify_binop_fmf(o, lhs, f, fmf, q, RECURSION_LIMIT);
        res = ssfb_add_negate(i, o, cond, tv, fv, e, f, lhs, si);
        if res >= 0 { done = true; }
    }
    if !done && tv >= 0 && fv >= 0 {
        var nm: u8[>..] = []; nm.append(val_name(i));
        res = icb_select(cond, tv, fv, nm, si);
        ic_take_name(res, i);
    }
    icb_fmf = saved_fmf;
    return res;
}
// the foldAddNegate lambda
fn ssfb_add_negate(i: i32, o: i64, cond: i32, tv: i32, fv: i32, tval: i32, fval: i32, z: i32, si: i32) -> i32 {
    if o != OP_ADD || (tv < 0 && fv < 0) || (tv >= 0 && fv >= 0) { return -1; }
    var nm: u8[>..] = []; nm.append(val_name(i));
    if tv >= 0 {
        let n = m_neg(fval);
        if n >= 0 {
            let s = icb_sub(z, n, "");
            return icb_select(cond, tv, s, nm, si);
        }
    }
    if fv >= 0 {
        let n = m_neg(tval);
        if n >= 0 {
            let s = icb_sub(z, n, "");
            return icb_select(cond, s, fv, nm, si);
        }
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// Folding into selects and phis

// Value::hasOneUser
fn has_one_user(v: i32) -> bool {
    let u = vals[v].first_use;
    if u < 0 { return false; }
    let us = uses[u].user;
    var n = uses[u].next;
    while n >= 0 { if uses[n].user != us { return false; } n = uses[n].next; }
    return true;
}

// simplifyOperationIntoSelectOperand(I, SI, IsTrueArm)
fn simplify_op_into_select_operand(i: i32, si: i32, true_arm: bool) -> i32 {
    let mark = is_ops.len;
    let c = op(si, 0);
    for k in nops(i) {
        let o = op(i, k);
        var v: i32 = -1;
        if o == si {
            v = if true_arm { op(si, 1) } else { op(si, 2) };
        } else if is_inst_op(c, OP_ICMP) && inst_pred(c) == (if true_arm { 32 } else { 33 }) && op(c, 0) == o &&
                  is_guaranteed_not_to_be_undef_or_poison(op(c, 1), -1, 0) {
            v = op(c, 1);
        } else if is_inst_op(o, OP_ZEXT) && op(o, 0) == c {
            v = if true_arm { c_int_ty(vals[o].ty, 1) } else { c_null(vals[o].ty) };
        } else {
            v = o;
        }
        is_ops.push(v);
    }
    let r = simplify_inst_with_ops(i, mark, nops(i), sq_new(-1), RECURSION_LIMIT);
    is_ops.resize(mark);
    return r;
}

// Instruction::replaceUsesOfWith(From, To)
fn replace_uses_of_with(i: i32, from: i32, to: i32) {
    for k in nops(i) { if op(i, k) == from { set_op(i, k, to); } }
}

// Instruction::dropUBImplyingAttrsAndMetadata
// Instruction::dropUBImplyingAttrsAndMetadata(): keeps !annotation, !range, !nonnull, !align, !fpmath, !prof,
// !DIAssignID and the debug location; on a call also drops noundef / dereferenceable / dereferenceable_or_null from
// the return and every argument (AttributeFuncs::getUBImplyingAttributes).
fn drop_ub_implying_attrs_and_md(i: i32) {
    let ii = inst_of(i);
    var keep: i32[>..<] = [];
    keep.push(md_kind_id("annotation")); keep.push(md_kind_id("range")); keep.push(md_kind_id("nonnull"));
    keep.push(md_kind_id("align")); keep.push(md_kind_id("fpmath")); keep.push(md_kind_id("prof"));
    keep.push(md_kind_id("DIAssignID"));
    var drop: i32[>..<] = [];
    for k in insts[ii].nmd {
        let kind = md_att[insts[ii].md + 2 * k];
        if kind == 0 { continue; }
        var kept = false;
        for kk in keep { if kk == kind { kept = true; } }
        if !kept { drop.push(kind); }
    }
    for kind in drop { inst_erase_md(i, kind); }
    if !is_callbase(i) { return; }
    let l = insts[ii].attrs;
    if l == 0 { return; }
    let ub: i64[3] = [AK_NoUndef, AK_Dereferenceable, AK_DereferenceableOrNull];
    var xs: i32[>..<] = [];
    xs.push(alist_fn(l));
    xs.push(aset_without(alist_ret(l), ub));
    let na = cb_nargs(i);
    let np = max(alists[l].n as i64 - 2, na);
    for k in np {
        if k < na { xs.push(aset_without(alist_param(l, k), ub)); } else { xs.push(alist_param(l, k)); }
    }
    insts[ii].attrs = alist_get(xs);
}

// foldOperationIntoSelectOperand(I, SI, NewOp, IC)
fn fold_op_into_select_operand(i: i32, si: i32, newop: i32) -> i32 {
    let cl = inst_clone(i);
    replace_uses_of_with(cl, si, newop);
    drop_ub_implying_attrs_and_md(cl);
    ic_insert_new_before(cl, i);
    return cl;
}

// FoldOpIntoSelect(Op, SI, FoldWithMultiUse, SimplifyBothArms)
fn fold_op_into_select(i: i32, si: i32, multi_use: bool, both_arms: bool) -> i32 {
    if !has_one_user(si) && !multi_use { return -1; }
    let tv = op(si, 1);
    let fv = op(si, 2);
    if is_int_ty1(vals[si].ty) { return -1; }
    if is_minmax_iid(inst_iid(i)) {
        for k in nops(i) {
            let x = op(i, k);
            if is_phi_inst(x) { for j in nops(x) { if op(x, j) == i { return -1; } } }
        }
    }
    let ci = op(si, 0);
    if is_inst_op(ci, OP_FCMP) && one_use(ci) {
        let a = op(ci, 0); let b = op(ci, 1);
        let p = inst_pred(ci);
        let commutative = p == 1 || p == 6 || p == 7 || p == 8 || p == 9 || p == 14 || p == 0 || p == 15;
        if ((tv == a && fv == b) || (fv == a && tv == b)) && !commutative { return -1; }
    }
    var ntv = simplify_op_into_select_operand(i, si, true);
    var nfv = simplify_op_into_select_operand(i, si, false);
    if ntv < 0 && nfv < 0 { return -1; }
    if both_arms && !(ntv >= 0 && nfv >= 0) { return -1; }
    if ntv < 0 { ntv = fold_op_into_select_operand(i, si, tv); }
    if nfv < 0 { nfv = fold_op_into_select_operand(i, si, fv); }
    let ns = ic_new_select(op(si, 0), ntv, nfv);
    icb_copy_select_md(ns, si);
    let dl = inst_get_md(si, 0);
    if dl >= 0 { inst_set_md(ns, 0, dl); }
    return ns;
}

// Value::DoPHITranslation(CurBB, PredBB)
fn do_phi_translation(v: i32, cur: i32, pred: i32) -> i32 {
    if is_phi_inst(v) && inst_parent(v) == cur {
        let k = phi_block_index(v, pred);
        if k >= 0 { return op(v, k); }
    }
    return v;
}

// simplifyInstructionWithPHI(I, PN, InValue, InBB, DL, SQ)
fn simplify_inst_with_phi(i: i32, pn: i32, inv: i32, inbb: i32) -> i32 {
    let mark = is_ops.len;
    for k in nops(i) {
        let o = op(i, k);
        if o == pn { is_ops.push(inv); } else { is_ops.push(do_phi_translation(o, inst_parent(pn), inbb)); }
    }
    let t = block_terminator(inbb);
    let nv = simplify_inst_with_ops(i, mark, nops(i), sq_new(t), RECURSION_LIMIT);
    let o0v = is_ops[mark];
    let o1v = if nops(i) > 1 { is_ops[mark + 1] } else { -1 };
    is_ops.resize(mark);
    if nv >= 0 && nv != pn && !m_constant_expr(nv) { return nv; }
    if iop(t) == OP_CONDBR && term_succ(t, 0) != term_succ(t, 1) && iop(i) == OP_ICMP {
        let lhs_true = term_succ(t, 0) == inst_parent(pn);
        let ic = implied_condition(op(t, 0), cp(inst_pred(i), (insts[inst_of(i)].flags & FL_SAMESIGN) != 0), o0v, o1v, lhs_true, 0);
        if ic >= 0 { return c_bool_ty(vals[i].ty, ic == 1); }
    }
    return -1;
}

// Instruction::isIdenticalTo
fn is_identical_to(a: i32, b: i32) -> bool {
    if iop(a) != iop(b) || vals[a].ty != vals[b].ty || nops(a) != nops(b) { return false; }
    for k in nops(a) { if op(a, k) != op(b, k) { return false; } }
    let x = insts[inst_of(a)];
    let y = insts[inst_of(b)];
    if x.flags != y.flags || x.fmf != y.fmf || x.pred != y.pred { return false; }
    if iop(a) == OP_PHI { for k in nops(a) { if phi_block(a, k) != phi_block(b, k) { return false; } } }
    if iop(a) == OP_CALL || iop(a) == OP_LOAD || iop(a) == OP_STORE || iop(a) == OP_GEP || iop(a) == OP_ALLOCA ||
       iop(a) == OP_EXTRACTVALUE || iop(a) == OP_INSERTVALUE || iop(a) == OP_SHUFFLEVECTOR {
        ic_not_ported("isIdenticalTo for memory/call/aggregate instructions");
    }
    return true;
}

// foldOpIntoPhi(I, PN, AllowMultipleUses)
fn fold_op_into_phi(i: i32, pn: i32, allow_multi: bool) -> i32 {
    let n = nops(pn);
    if n == 0 { return -1; }
    var one = has_one_use(pn);
    var identical = false;
    if !allow_multi && !one {
        var u = vals[pn].first_use;
        while u >= 0 {
            let ui = uses[u].user;
            u = uses[u].next;
            if ui != i && !is_identical_to(i, ui) { return -1; }
        }
        identical = true;
    }
    for k in nops(i) {
        let x = op(i, k);
        if x == pn { continue; }
        if !is_inst(x) { continue; }
        if is_phi_inst(x) && inst_parent(x) == inst_parent(pn) { continue; }
        if dom_value_block(x, inst_parent(pn)) { continue; }
        return -1;
    }
    var newv: i32[>..<] = [];
    var to_move: i64[>..<] = [];
    var seen_non_simplified = false;
    for k in n {
        let inv = op(pn, k);
        let inbb = phi_block(pn, k);
        let nv = simplify_inst_with_phi(i, pn, inv, inbb);
        if nv >= 0 { newv.push(nv); continue; }
        // WillFold
        var will_fold = false;
        if !is_constant_data(inv) && has_one_user(inv) {
            let id = inst_iid(inv);
            if (id == IID_ucmp || id == IID_scmp) && iop(i) == OP_ICMP && op(i, 0) == pn && has_apint(op(i, 1)) { will_fold = true; }
            if is_inst_op(inv, OP_ZEXT) && is_int_ty1(vals[op(inv, 0)].ty) && iop(i) == OP_ICMP && inst_pred(i) == 32 &&
               op(i, 0) == pn && m_zero(op(i, 1)) { will_fold = true; }
        }
        if will_fold { to_move.push(k); newv.push(-1); continue; }
        if !one && !identical { return -1; }
        if seen_non_simplified { return -1; }
        seen_non_simplified = true;
        let t = block_terminator(inbb);
        if iop(t) != OP_BR || !dt_has_node(DT_DOM, inbb) { return -1; }
        newv.push(-1);
        to_move.push(k);
        if ic_is_backedge(inbb, inst_parent(pn)) { return -1; }
    }
    var clone_bb: i32[>..<] = [];
    var clone_i: i32[>..<] = [];
    for k in to_move {
        let opv = op(pn, k);
        let obb = phi_block(pn, k);
        var cl: i32 = -1;
        for j in clone_bb.len { if clone_bb[j] == obb { cl = clone_i[j]; } }
        if cl < 0 {
            cl = inst_clone(i);
            for j in nops(cl) {
                let x = op(cl, j);
                if x == pn { set_op(cl, j, opv); } else { set_op(cl, j, do_phi_translation(x, inst_parent(pn), obb)); }
            }
            ic_insert_new_before(cl, block_terminator(obb));
            clone_bb.push(obb);
            clone_i.push(cl);
            drop_ub_implying_attrs_and_md(cl);
        }
        newv[k] = cl;
    }
    let npn = new_inst(OP_PHI, vals[i].ty, n);
    vals[npn].nops = 0;
    ic_insert_new_before(npn, pn);
    ic_take_name(npn, pn);
    let dl = inst_get_md(pn, 0);
    if dl >= 0 { inst_set_md(npn, 0, dl); }
    for k in n { phi_add_incoming(npn, newv[k], phi_block(pn, k)); }
    if identical {
        var torep: i32[>..<] = [];
        var u = vals[pn].first_use;
        while u >= 0 {
            let us = uses[u].user;
            u = uses[u].next;
            if us == i { continue; }
            var dup = false;
            for x in torep { if x == us { dup = true; } }
            if !dup { torep.push(us); }
        }
        for x in torep { ic_replace_inst_uses_with(x, npn); ic_erase(x); }
        one = true;
    }
    if one && dbgrecs.len > 0 && dbg_records_use_value(pn) { ic_not_ported("replaceAllDbgUsesWith in foldOpIntoPhi"); }
    return ic_replace_inst_uses_with(i, npn);
}

// foldBinOpSelectBinOp(Op)
fn fold_binop_select_binop(i: i32) -> i32 {
    let si = op(i, 0);
    let c = op(i, 1);
    if !is_select_inst(si) || !is_imm_c(c) || !has_one_use(i) || !has_one_use(si) { return -1; }
    let tv = op(si, 1);
    let fv = op(si, 2);
    let o = iop(i);
    var ntv: i32 = -1;
    var nfv: i32 = -1;
    var input: i32 = -1;
    if one_use(tv) && bo(tv, o) && op(tv, 0) == fv && is_imm_c(op(tv, 1)) {
        ntv = cf_binop(o, c, op(tv, 1));
        nfv = c;
        input = fv;
    } else if one_use(fv) && bo(fv, o) && op(fv, 0) == tv && is_imm_c(op(fv, 1)) {
        ntv = c;
        nfv = cf_binop(o, c, op(fv, 1));
        input = tv;
    } else { return -1; }
    if ntv < 0 || nfv < 0 { return -1; }
    let ns = icb_select(op(si, 0), ntv, nfv, "", si);
    return ic_new_binop(o, ns, input);
}

// foldBinopWithRecurrence(BO)
fn fold_binop_with_recurrence(b: i32) -> i32 {
    if !ic_inst_is_associative(b) { return -1; }
    let o = iop(b);
    let b0 = op(b, 0);
    let b1 = op(b, 1);
    if !is_binop_inst(b0) || !is_binop_inst(b1) || num_uses(b0) != 2 || num_uses(b1) != 2 || iop(b0) != o || iop(b1) != o ||
       !ic_inst_is_associative(b0) || !ic_inst_is_associative(b1) || inst_parent(b0) != inst_parent(b1) { return -1; }
    // matchSimpleRecurrence(BO0, PN0, Start0, Step0) && PN0->hasOneUse() (and the same for BO1)
    let pn0 = fbr_recurrence_phi(b0);
    if pn0 < 0 { return -1; }
    let start0 = rec_start; let step0 = rec_step;
    if !has_one_use(pn0) { return -1; }
    let pn1 = fbr_recurrence_phi(b1);
    if pn1 < 0 { return -1; }
    let start1 = rec_start; let step1 = rec_step;
    if !has_one_use(pn1) || inst_parent(pn0) != inst_parent(pn1) { return -1; }
    if !is_constant(start0) || !is_constant(start1) || !is_constant(step0) || !is_constant(step1) { return -1; }
    let init = cf_binop(o, start0, start1);
    let c = cf_binop(o, step0, step1);
    if init < 0 || c < 0 { return -1; }
    let np = new_inst(OP_PHI, vals[pn0].ty, nops(pn0));
    vals[np].nops = 0;
    set_name(np, "reduced.phi");
    let nbo = ic_new_binop(o, np, c);
    if o == OP_FADD || o == OP_FMUL {
        insts[inst_of(nbo)].fmf = insts[inst_of(b0)].fmf & insts[inst_of(b1)].fmf & insts[inst_of(b)].fmf;
    } else {
        // OverflowTracking with AllKnownNonNegative = AllKnownNonZero = false
        var nuw = true; var nsw = true; var disj = true;
        for x in [b0, b1, b] {
            if is_overflowing_op(o) { nuw = nuw && has_nuw(x); nsw = nsw && has_nsw(x); }
            if o == OP_OR { disj = disj && op_disjoint(x); }
        }
        if o == OP_ADD {
            if nuw { set_nuw(nbo, true); }
            if nsw && nuw { set_nsw(nbo, true); }
        }
        if o == OP_OR { set_disjoint(nbo, disj); }
    }
    ic_take_name(nbo, b);
    for k in nops(pn0) {
        let v = op(pn0, k);
        let bb = phi_block(pn0, k);
        if v == start0 { phi_add_incoming(np, init, bb); }
        else if v == b0 { phi_add_incoming(np, nbo, bb); }
        else { fatal("internal: foldBinopWithRecurrence: unexpected incoming value"); }
    }
    ic_insert_new_with(np, pn0);
    ic_insert_new_with(nbo, b0);
    ic_replace_inst_uses_with(b0, c_poison(vals[b0].ty));
    ic_erase(b0);
    ic_replace_inst_uses_with(b1, c_poison(vals[b1].ty));
    ic_erase(b1);
    ic_erase(pn0);
    ic_erase(pn1);
    return ic_replace_inst_uses_with(b, nbo);
}
// matchSimpleRecurrence(BO, PN, Start, Step): m_c_BinOp(m_Phi(P), m_Value()) then matchSimpleRecurrence(P, ...) with
// BO == the binop; the phi (rec_start / rec_step set) or -1
fn fbr_recurrence_phi(bo0: i32) -> i32 {
    var p = op(bo0, 0);
    if !is_phi_inst(p) { p = op(bo0, 1); if !is_phi_inst(p) { return -1; } }
    if !match_simple_recurrence(p) || rec_bo != bo0 { return -1; }
    return p;
}
// matchSimpleRecurrence(BO, PN, Start, Step): the phi or -1
fn match_simple_recurrence_bo(i: i32) -> i32 {
    for k in 2 {
        let p = op(i, k);
        if is_phi_inst(p) && nops(p) == 2 {
            for j in 2 {
                if op(p, j) == i { return p; }
            }
        }
    }
    return -1;
}

// foldBinopWithPhiOperands(BO)
fn fold_binop_with_phi_operands(b: i32) -> i32 {
    let r = fold_binop_with_recurrence(b);
    if r >= 0 { return r; }
    let p0 = op(b, 0);
    let p1 = op(b, 1);
    if !is_phi_inst(p0) || !is_phi_inst(p1) || !has_one_use(p0) || !has_one_use(p1) || nops(p0) != nops(p1) { return -1; }
    if inst_parent(b) != inst_parent(p0) || inst_parent(b) != inst_parent(p1) { return -1; }
    let c = binop_identity(iop(b), vals[b].ty, false);
    if c >= 0 {
        var newv: i32[>..<] = [];
        var ok = true;
        for k in nops(p0) {
            if phi_block(p0, k) != phi_block(p1, k) { ok = false; break; }
            let u0 = op(p0, k);
            let u1 = op(p1, k);
            if u0 == c { newv.push(u1); }
            else if u1 == c { newv.push(u0); }
            else { ok = false; break; }
        }
        if ok {
            let np = new_inst(OP_PHI, vals[p0].ty, nops(p0));
            vals[np].nops = 0;
            for k in nops(p0) { phi_add_incoming(np, newv[k], phi_block(p0, k)); }
            return np;
        }
    }
    if nops(p0) != 2 || nops(p1) != 2 { return -1; }
    var const_bb: i32 = -1;
    var other_bb: i32 = -1;
    var c0: i32 = -1;
    if is_imm_c(op(p0, 0)) { c0 = op(p0, 0); const_bb = phi_block(p0, 0); other_bb = phi_block(p0, 1); }
    else if is_imm_c(op(p0, 1)) { c0 = op(p0, 1); const_bb = phi_block(p0, 1); other_bb = phi_block(p0, 0); }
    else { return -1; }
    let c1 = op(p1, phi_block_index(p1, const_bb));
    if !is_imm_c(c1) { return -1; }
    let pbr = block_terminator(other_bb);
    if iop(pbr) != OP_BR || !dt_has_node(DT_DOM, other_bb) { return -1; }
    var it = block_first(inst_parent(b));
    while it != b { if !guaranteed_to_transfer(it) { return -1; } it = inst_next(it); }
    let nc = cf_fold_binop_operands(iop(b), c0, c1);
    if nc < 0 { return -1; }
    icb_set_insert_before(pbr);
    let nbo = icb_binop(iop(b), op(p0, phi_block_index(p0, other_bb)), op(p1, phi_block_index(p1, other_bb)), "");
    if is_binop_inst(nbo) { copy_ir_flags(nbo, b); }
    let np = new_inst(OP_PHI, vals[b].ty, 2);
    vals[np].nops = 0;
    phi_add_incoming(np, nbo, other_bb);
    phi_add_incoming(np, nc, const_bb);
    return np;
}

// foldBinOpIntoSelectOrPhi(I)
fn fold_binop_into_select_or_phi(i: i32) -> i32 {
    for k in 2 {
        let x = op(i, k);
        let other_const = is_constant(op(i, 1 - k));
        if is_select_inst(x) {
            let r = fold_op_into_select(i, x, false, !other_const);
            if r >= 0 { return r; }
        } else if is_phi_inst(x) {
            let r = fold_op_into_phi(i, x, false);
            if r >= 0 { return r; }
        }
    }
    return -1;
}

// foldVectorBinop(Inst): ported in ic_combining.goose
fn fold_vector_binop(i: i32) -> i32 { fold_vector_binop_impl(i) }

// getLosslessInvCast(C, InvCastTo, CastOp, DL): narrowed constant that extends back to C, or -1
fn get_lossless_inv_cast(c: i32, to_ty: i32, cast_op: i64) -> i32 {
    let n = ce_cast(OP_TRUNC, c, to_ty);
    if n < 0 { return -1; }
    let back = cf_fold_cast_operand(cast_op, n, vals[c].ty);
    if back != c { return -1; }
    return n;
}

// narrowMathIfNoOverflow(BO)
fn narrow_math_if_no_overflow(b: i32) -> i32 {
    var op0 = op(b, 0);
    var op1 = op(b, 1);
    if iop(b) == OP_SUB { let t = op0; op0 = op1; op1 = t; }
    var x = m_sext(op0);
    let is_sext = x >= 0;
    if !is_sext { x = m_zext(op0); if x < 0 { return -1; } }
    let cast_op = if is_sext { OP_SEXT } else { OP_ZEXT };
    var y = m_zext_or_sext(op1);
    if !(y >= 0 && vals[x].ty == vals[y].ty && iop(op1) == cast_op && (one_use(op0) || one_use(op1))) {
        if !one_use(op0) || !is_const(op1) { return -1; }
        let nc = get_lossless_inv_cast(op1, vals[x].ty, cast_op);
        if nc < 0 { return -1; }
        y = nc;
    }
    if iop(b) == OP_SUB { let t = x; x = y; y = t; }
    if !will_not_overflow(iop(b), x, y, b, is_sext) { return -1; }
    let nb = icb_binop(iop(b), x, y, "narrow");
    if is_binop_inst(nb) { if is_sext { set_nsw(nb, true); } else { set_nuw(nb, true); } }
    return ic_new_cast(cast_op, nb, vals[b].ty);
}

// ---------------------------------------------------------------------------------------------
// getFreelyInverted

let GFI_NONNULL = -2;
var gfi_consume: bool = false;

// shouldAvoidAbsorbingNotIntoSelect(SI)
fn should_avoid_absorbing_not_into_select(si: i32) -> bool { m_logical_and(si) || m_logical_or(si) }

// getFreelyInvertedImpl(V, WillInvertAllUses, Builder, DoesConsume, Depth): build = use the builder
recursive fn gfi_impl(v: i32, will_invert_all: bool, build: bool, depth0: i64) -> i32 {
    let a0 = m_not(v);
    if a0 >= 0 { gfi_consume = true; return a0; }
    if is_imm_c(v) { return ce_not(v); }
    var depth = depth0;
    if depth >= 6 { return -1; }
    depth++;
    if !will_invert_all { return -1; }
    if is_cmp_inst(v) {
        if build {
            if iop(v) == OP_ICMP { return icb_icmp(icmp_inverse_pred(inst_pred(v)), op(v, 0), op(v, 1), ""); }
            // CreateCmp(I->getInversePredicate(), ...): FCmpInst inverse predicate is 15 - P
            return icb_fcmp_fmf(15 - inst_pred(v), op(v, 0), op(v, 1), icb_fmf, "");
        }
        return GFI_NONNULL;
    }
    if bo(v, OP_ADD) {
        let a = op(v, 0); let b = op(v, 1);
        let bv = gfi_impl(b, one_use(b), build, depth);
        if bv != -1 { return if build { icb_sub(bv, a, "") } else { GFI_NONNULL }; }
        let av = gfi_impl(a, one_use(a), build, depth);
        if av != -1 { return if build { icb_sub(av, b, "") } else { GFI_NONNULL }; }
        return -1;
    }
    if bo(v, OP_XOR) {
        let a = op(v, 0); let b = op(v, 1);
        let bv = gfi_impl(b, one_use(b), build, depth);
        if bv != -1 { return if build { icb_xor(a, bv, "") } else { GFI_NONNULL }; }
        let av = gfi_impl(a, one_use(a), build, depth);
        if av != -1 { return if build { icb_xor(av, b, "") } else { GFI_NONNULL }; }
        return -1;
    }
    if bo(v, OP_SUB) {
        let a = op(v, 0); let b = op(v, 1);
        let av = gfi_impl(a, one_use(a), build, depth);
        if av != -1 { return if build { icb_add(av, b, "") } else { GFI_NONNULL }; }
        return -1;
    }
    if bo(v, OP_ASHR) {
        let a = op(v, 0); let b = op(v, 1);
        let av = gfi_impl(a, one_use(a), build, depth);
        if av != -1 { return if build { icb_ashr(av, b, "", false) } else { GFI_NONNULL }; }
        return -1;
    }
    let is_sel = is_select_inst(v) && !should_avoid_absorbing_not_into_select(v);
    let is_mm = is_minmax_iid(inst_iid(v));
    if is_sel || is_mm {
        let a = if is_sel { op(v, 1) } else { op(v, 0) };
        let b = if is_sel { op(v, 2) } else { op(v, 1) };
        let saved = gfi_consume;           // DoesConsume; gfi_consume now plays LocalDoesConsume
        if gfi_impl(b, one_use(b), false, depth) == -1 { gfi_consume = saved; return -1; }
        let na = gfi_impl(a, one_use(a), build, depth);
        if na != -1 {
            if build {
                let nb = gfi_impl(b, one_use(b), true, depth);
                if nb == -1 { fatal("internal: Unable to build inverted value for known freely invertable op"); }
                if is_mm { return icb_binary_intrinsic(minmax_inverse_iid(inst_iid(v)), na, nb, ""); }
                return icb_select(op(v, 0), na, nb, "", v);
            }
            return GFI_NONNULL;
        }
        gfi_consume = saved;
    }
    if is_phi_inst(v) {
        let saved = gfi_consume;
        let mark = gfi_vals.len;
        for k in nops(v) {
            let nv = gfi_impl(op(v, k), false, false, 5);
            if nv == -1 || nv == v { gfi_consume = saved; gfi_vals.resize(mark); return -1; }
            if build { gfi_vals.push(nv); gfi_vals.push(phi_block(v, k)); }
        }
        if build {
            let sp = icb_pos; let sb = icb_bb; let sd = icb_dl;
            icb_set_insert_point(v);
            let np = new_inst(OP_PHI, vals[v].ty, nops(v));
            vals[np].nops = 0;
            icb_insert(np, "");
            var k = mark;
            while k < gfi_vals.len { phi_add_incoming(np, gfi_vals[k], gfi_vals[k + 1]); k += 2; }
            icb_pos = sp; icb_bb = sb; icb_dl = sd;
            gfi_vals.resize(mark);
            return np;
        }
        gfi_vals.resize(mark);
        return GFI_NONNULL;
    }
    let sa = m_sext_like(v);
    if sa >= 0 {
        let av = gfi_impl(sa, one_use(sa), build, depth);
        if av != -1 { return if build { icb_sext(av, vals[v].ty, "") } else { GFI_NONNULL }; }
        return -1;
    }
    let ta = m_trunc(v);
    if ta >= 0 {
        let av = gfi_impl(ta, one_use(ta), build, depth);
        if av != -1 { return if build { icb_trunc(av, vals[v].ty, "") } else { GFI_NONNULL }; }
        return -1;
    }
    if bo(v, OP_OR) { return gfi_demorgan(OP_AND, false, op(v, 0), op(v, 1), build, depth); }
    if bo(v, OP_AND) { return gfi_demorgan(OP_OR, false, op(v, 0), op(v, 1), build, depth); }
    if m_logical_or(v) { let a = lg_a; let b = lg_b; return gfi_demorgan(OP_AND, true, a, b, build, depth); }
    if m_logical_and(v) { let a = lg_a; let b = lg_b; return gfi_demorgan(OP_OR, true, a, b, build, depth); }
    return -1;
}
var gfi_vals: i32[>..<];

// TryInvertAndOrUsingDeMorgan
recursive fn gfi_demorgan(o: i64, logical: bool, a: i32, b: i32, build: bool, depth: i64) -> i32 {
    let saved = gfi_consume;
    if gfi_impl(b, one_use(b), false, depth) == -1 { gfi_consume = saved; return -1; }
    let na = gfi_impl(a, one_use(a), build, depth);
    if na != -1 {
        let nb = gfi_impl(b, one_use(b), build, depth);
        if logical {
            if !build { return GFI_NONNULL; }
            return if o == OP_AND { icb_logical_and(na, nb, "") } else { icb_logical_or(na, nb, "") };
        }
        return if build { icb_binop(o, na, nb, "") } else { GFI_NONNULL };
    }
    gfi_consume = saved;
    return -1;
}

// getFreelyInverted(V, WillInvertAllUses, Builder, DoesConsume): consume in gfi_consume
fn get_freely_inverted(v: i32, will_invert_all: bool, build: bool) -> i32 {
    gfi_consume = false;
    return gfi_impl(v, will_invert_all, build, 0);
}
fn is_free_to_invert(v: i32, will_invert_all: bool) -> bool { get_freely_inverted(v, will_invert_all, false) != -1 }

// canFreelyInvertAllUsersOf(V, IgnoredUser)
fn can_freely_invert_all_users_of(v: i32, ignored: i32) -> bool {
    var u = vals[v].first_use;
    while u >= 0 {
        let us = uses[u].user;
        let opno = (u - vals[us].ops) as i64;
        u = uses[u].next;
        if us == ignored { continue; }
        let o = iop(us);
        if o == OP_SELECT {
            if opno != 0 { return false; }
            if should_avoid_absorbing_not_into_select(us) { return false; }
        } else if o == OP_CONDBR {
        } else if o == OP_XOR {
            if m_not(us) < 0 { return false; }
        } else { return false; }
    }
    return true;
}

// freelyInvertAllUsersOf(I, IgnoredUser)
fn freely_invert_all_users_of(v: i32, ignored: i32) {
    var u = vals[v].first_use;
    while u >= 0 {
        let us = uses[u].user;
        u = uses[u].next;
        if us == ignored { continue; }
        let o = iop(us);
        if o == OP_SELECT {
            // SelectInst::swapValues + swapProfMetadata
            cu_use_swap(vals[us].ops + 1, vals[us].ops + 2);
            cu_swap_prof_metadata(us);
        } else if o == OP_CONDBR {
            cu_swap_successors(us);
        } else if o == OP_XOR {
            ic_replace_inst_uses_with(us, v);
            icw_add(us);
        } else { fatal("internal: freelyInvertAllUsersOf out of sync with canFreelyInvertAllUsersOf"); }
    }
    if dbgrecs.len > 0 && dbg_records_use_value(v) { ic_not_ported("freelyInvertAllUsersOf with debug value users (DW_OP_not)"); }
}

// ---------------------------------------------------------------------------------------------

// tryFoldInstWithCtpopWithNot(I)
fn try_fold_inst_with_ctpop_with_not(i: i32) -> i32 {
    let o = iop(i);
    var ci: i64 = 1;
    if o == OP_SUB { ci = 0; }
    else if o == OP_ICMP { if icmp_is_signed(inst_pred(i)) { return -1; } }
    else if o == OP_OR { if !op_disjoint(i) { return -1; } }
    else if o == OP_ADD { }
    else { return -1; }
    let pop = op(i, 1 - ci);
    if !one_use(pop) || inst_iid(pop) != IID_ctpop { return -1; }
    let x = op(pop, 0);
    let c = op(i, ci);
    if !is_imm_c(c) { return -1; }
    let ty: i32 = vals[x].ty;
    let bwc = c_int_ty(ty, ty_scalar_bits(ty) as u64);
    if o == OP_ICMP && !icmp_is_equality(inst_pred(i)) {
        let cmp = cf_fold_cmp_operands(34, c, bwc, -1);
        if cmp < 0 || !is_null_value(cmp) { return -1; }
    }
    gfi_consume = false;
    if get_freely_inverted(x, one_use(x), false) == -1 || !gfi_consume { return -1; }
    let notop = get_freely_inverted(x, one_use(x), true);
    let cp_ = icb_intrinsic(IID_ctpop, [ty], [notop], "");
    var r: i32 = -1;
    if o == OP_SUB { r = icb_add(cp_, ce_binop(OP_SUB, c, bwc, 0), ""); }
    else if o == OP_OR || o == OP_ADD { r = icb_sub(ce_binop(OP_ADD, c, bwc, 0), cp_, ""); }
    else { r = icb_icmp(icmp_swapped_pred(inst_pred(i)), cp_, ce_binop(OP_SUB, bwc, c, 0), ""); }
    return ic_replace_inst_uses_with(i, r);
}

// foldBinOpShiftWithShift(I)
fn fold_binop_shift_with_shift(i: i32) -> i32 {
    let r = fbsws_match(i, 0);
    if r >= 0 { return r; }
    return fbsws_match(i, 1);
}
fn fbsws_valid_binopc(o: i64) -> bool { o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_ADD }
fn fbsws_completely_distributable(b1: i64, b2: i64, sh: i64) -> bool { (b1 != OP_ADD && b2 != OP_ADD) || sh == OP_SHL }
fn fbsws_inv_shift(sh: i64) -> i64 { if sh == OP_LSHR { OP_SHL } else { OP_LSHR } }
fn fbsws_match(i: i32, shn: i64) -> i32 {
    let iy = op(i, shn);
    if !one_use(iy) || !is_inst(iy) || !is_shift_op(iop(iy)) { return -1; }
    let y = op(iy, 0);
    let shift = op(iy, 1);
    let bo2 = op(i, 1 - shn);
    if !one_use(bo2) || !is_binop_inst(bo2) { return -1; }
    var ix: i32 = -1;
    var mask: i32 = -1;
    for k in 2 {
        let s = op(bo2, k);
        if one_use(s) && is_inst(s) && is_shift_op(iop(s)) && op(s, 1) == shift { ix = s; mask = op(bo2, 1 - k); break; }
    }
    if ix < 0 { return -1; }
    let x = op(ix, 0);
    let sho = iop(iy);
    if sho != iop(ix) { return -1; }
    let bopc = iop(bo2);
    let io = iop(i);
    if !fbsws_valid_binopc(io) || !fbsws_valid_binopc(bopc) { return -1; }
    if sho == OP_ASHR {
        if is_logic_op(io) && bopc == OP_XOR && m_all_ones(mask) {
            let notx = icb_not(x, "");
            let nb = icb_binop(io, y, notx, "");
            return ic_new_binop(sho, nb, shift);
        }
        return -1;
    }
    if bopc == io && fbsws_completely_distributable(io, bopc, sho) {
        let nb2 = icb_binop(io, x, y, "");
        let nb1 = icb_binop(sho, nb2, shift, "");
        return ic_new_binop(io, nb1, mask);
    }
    if !is_imm_c(shift) || !is_imm_c(mask) { return -1; }
    // CanDistributeBinops
    var can = false;
    if io == OP_AND { can = true; }
    else if !fbsws_completely_distributable(io, bopc, sho) { can = false; }
    else if bopc == OP_AND { can = true; }
    else {
        let mis = cf_fold_binop_operands(fbsws_inv_shift(sho), mask, shift);
        can = cf_fold_binop_operands(sho, mis, shift) == mask;
    }
    if !can { return -1; }
    let ncm = cf_fold_binop_operands(fbsws_inv_shift(sho), mask, shift);
    let nb2 = icb_binop(bopc, x, ncm, "");
    let nb1 = icb_binop(io, y, nb2, "");
    return ic_new_binop(sho, nb1, shift);
}

// m_SelectLike(m_Value(A), m_Constant(T), m_Constant(F)): sets sl_c/sl_t/sl_f
var sl_c: i32 = -1;
var sl_t: i32 = -1;
var sl_f: i32 = -1;
fn m_select_like(v: i32) -> bool {
    if is_select_inst(v) && is_constant(op(v, 1)) && is_constant(op(v, 2)) { sl_c = op(v, 0); sl_t = op(v, 1); sl_f = op(v, 2); return true; }
    let ty = vals[v].ty;
    if is_inst_op(v, OP_ZEXT) && is_int_ty1(vals[op(v, 0)].ty) { sl_c = op(v, 0); sl_t = c_int_ty(ty, 1); sl_f = c_int_ty(ty, 0); return true; }
    if is_inst_op(v, OP_SEXT) && is_int_ty1(vals[op(v, 0)].ty) { sl_c = op(v, 0); sl_t = c_all_ones(ty); sl_f = c_int_ty(ty, 0); return true; }
    return false;
}

// foldBinOpOfSelectAndCastOfSelectCondition(I)
fn fold_binop_of_select_and_cast_of_select_cond(i: i32) -> i32 {
    let o = iop(i);
    let lhs = op(i, 0);
    let rhs = op(i, 1);
    var castop: i32 = -1;
    var selop: i32 = -1;
    if m_select_like(lhs) && is_select_inst(rhs) { castop = lhs; selop = rhs; }
    else if m_select_like(rhs) && is_select_inst(lhs) { castop = rhs; selop = lhs; }
    else { return -1; }
    let a = sl_c; let ct = sl_t; let cf = sl_f;
    let cond = op(selop, 0);
    let tv = op(selop, 1);
    let fv = op(selop, 2);
    let cast_rhs = castop == rhs;
    // NewFoldedConst(IsTrueArm, V) uses CastFalseVal for IsTrueArm, CastTrueVal otherwise
    if cond == a {
        let ntv = fbsc_const(o, cast_rhs, ct, tv);
        let nfv = fbsc_const(o, cast_rhs, cf, fv);
        return ic_new_select_md_all(cond, ntv, nfv, selop);
    }
    if m_not_of(a, cond) {
        let ntv = fbsc_const(o, cast_rhs, cf, tv);
        let nfv = fbsc_const(o, cast_rhs, ct, fv);
        return ic_new_select_md_all(cond, ntv, nfv, selop);
    }
    return -1;
}
fn fbsc_const(o: i64, cast_rhs: bool, castval: i32, v: i32) -> i32 {
    if cast_rhs { return icb_binop(o, v, castval, ""); }
    return icb_binop(o, castval, v, "");
}

// dyn_castNegVal(V)
fn dyn_cast_neg_val(v: i32) -> i32 {
    let n = m_neg(v);
    if n >= 0 { return n; }
    if vals[v].kind == VK_CINT && !ty_is_vector(vals[v].ty) { return ce_binop(OP_SUB, c_null(vals[v].ty), v, 0); }
    if vals[v].kind == VK_CDVECTOR && ty_is_int(ty_scalar(vals[v].ty)) { return ce_binop(OP_SUB, c_null(vals[v].ty), v, 0); }
    if vals[v].kind == VK_CVECTOR {
        for k in nops(v) {
            let e = op(v, k);
            if is_undef_or_poison(e) { continue; }
            if vals[e].kind != VK_CINT { return -1; }
        }
        return ce_binop(OP_SUB, c_null(vals[v].ty), v, 0);
    }
    if is_constant(v) && ty_is_vector(vals[v].ty) && ty_is_int(ty_scalar(vals[v].ty)) && splat_value(v, false) >= 0 {
        return ce_binop(OP_SUB, c_null(vals[v].ty), v, 0);
    }
    return -1;
}

// foldBinopOfSextBoolToSelect(BO)
fn fold_binop_of_sext_bool_to_select(b: i32) -> i32 {
    let x = m_sext(op(b, 0));
    let c = op(b, 1);
    if x < 0 || !is_imm_c(c) || !is_int_ty1(vals[x].ty) { return -1; }
    let ones = c_all_ones(vals[b].ty);
    let zero = c_null(vals[b].ty);
    let tv = icb_binop(iop(b), ones, c, "");
    let fv = icb_binop(iop(b), zero, c, "");
    return ic_new_select_unknown_prof(x, tv, fv);
}

// ---------------------------------------------------------------------------------------------
// GEP offsets: llvm::emitGEPOffset (Analysis/Local.cpp), InstCombinerImpl::EmitGEPOffset / EmitGEPOffsets
// (InstructionCombining.cpp), the IRBuilder GEP/splat helpers they use, GEPNoWrapFlags::intersectForOffsetAdd.

// GEPNoWrapFlags::intersectForOffsetAdd
fn gep_nw_intersect_for_offset_add(a: u8, b: u8) -> u8 {
    var r = a & b;
    if (r & GEP_INBOUNDS) == 0 && (r & GEP_NUSW) != 0 { r &= ~GEP_NUSW; }
    return r;
}
// DataLayout::getIndexType(PtrTy)
fn dl_index_type(pt: i32) -> i32 {
    let it = ty_int(dl_ptr(ptr_as(ty_scalar(pt))).idx);
    if ty_is_vector(pt) { return ty_vector(it, ty_count(pt), ty_kind(pt) == TK_SVEC); }
    return it;
}
// IRBuilder::CreateGEP(Ty, Ptr, IdxList, Name, NW)
fn icb_gep(srcty: i32, p: i32, idxs: const i32[:], name: const u8[:], fl: u8) -> i32 {
    // TargetFolder::FoldGEP: no constant expression for a scalable source type (isSupportedGetElementPtr)
    if is_constant(p) && !ty_contains_scalable(srcty) {
        var all = true;
        for x in idxs { if !is_constant(x) { all = false; } }
        if all { return tf_fold(ce_gep(srcty, p, idxs, fl, -1)); }
    }
    let rt = gep_ret_type(p, idxs);
    var opsv: i32[>..<] = [];
    opsv.push(p);
    for x in idxs { opsv.push(x); }
    let g = create_inst(OP_GEP, rt, opsv);
    insts[inst_of(g)].ty2 = srcty;
    insts[inst_of(g)].flags = fl;
    return icb_insert(g, name);
}
// IRBuilder::CreatePtrAdd(Ptr, Offset, Name, NW)
fn icb_ptr_add(p: i32, off: i32, name: const u8[:], fl: u8) -> i32 { icb_gep(T_I8, p, [off], name, fl) }
// IRBuilder::CreateVectorSplat(EC, V, Name)
fn icb_vector_splat(vty: i32, v: i32, name: const u8[:]) -> i32 {
    if is_constant(v) { return c_splat(vty, v); }
    var n1: u8[>..] = [];
    n1.append(name); n1.append(".splatinsert");
    let ie = icb_insert(create_inst(OP_INSERTELEMENT, vty, [c_poison(vty), v, c_int(T_I64, 0)]), n1);
    var n2: u8[>..] = [];
    n2.append(name); n2.append(".splat");
    let s = create_inst(OP_SHUFFLEVECTOR, vty, [ie, c_poison(vty)]);
    let ii = inst_of(s);
    insts[ii].aux = ints.len as i32;
    insts[ii].naux = ty_count(vty) as i32;
    for k in ty_count(vty) { ints.push(0); }
    return icb_insert(s, n2);
}
fn gep_all_constant_indices(g: i32) -> bool {
    for k in 1..nops(g) { if vals[op(g, k)].kind != VK_CINT { return false; } }
    return true;
}

// llvm::emitGEPOffset(Builder, DL, GEP, NoAssumptions = false)
fn emit_gep_offset_raw(g: i32) -> i32 {
    let iit = dl_index_type(vals[g].ty);
    var res: i32 = -1;
    let fl = gep_flags(g);
    let nsw = (fl & GEP_NUSW) != 0;
    let nuw = (fl & GEP_NUW) != 0;
    var gname: u8[>..] = [];
    gname.append(val_name(g));
    var t = gep_src_ty(g);
    for k in 1..nops(g) {
        let o = op(g, k);
        var stride: i64 = 0;
        var is_struct = false;
        var scalable = false;
        if k == 1 { stride = dl_alloc_size(t); scalable = ty_size_scalable(t); }
        else if ty_is_struct(t) { is_struct = true; }
        else { let et = ty_elem(t); stride = dl_gep_stride(t, et); scalable = ty_size_scalable(et); }
        if is_constant(o) {
            if is_null_value(o) {
                if k > 1 { if is_struct { t = ty_field(t, 0); } else { t = ty_elem(t); } }
                continue;
            }
            if is_struct {
                let fi = ap_zext64(icc_unique_int_c(o)) as i64;
                let sz = dl_struct_offset(t, fi);
                t = ty_field(t, fi);
                if sz == 0 { continue; }
                res = emit_gep_add_offset(res, c_int_ty(iit, sz as u64), gname, nuw, nsw);
                continue;
            }
        }
        if k > 1 { t = ty_elem(t); }
        var x = o;
        if ty_is_vector(iit) && !ty_is_vector(vals[x].ty) { x = icb_vector_splat(iit, x, ""); }
        if vals[x].ty != iit {
            var nm: u8[>..] = [];
            nm.append(val_name(x)); nm.append(".c");
            x = icb_int_cast_c(x, iit, true, nm);
        }
        if stride != 1 || scalable {
            var sc = icb_type_size(ty_scalar(iit), stride as u64, scalable);
            if ty_is_vector(iit) { sc = icb_vector_splat(iit, sc, ""); }
            var nm: u8[>..] = [];
            nm.append(gname); nm.append(".idx");
            x = icb_mul_nw(x, sc, nm, nuw, nsw);
        }
        res = emit_gep_add_offset(res, x, gname, nuw, nsw);
    }
    return if res >= 0 { res } else { c_null(iit) };
}
fn emit_gep_add_offset(res: i32, off: i32, gname: const u8[:], nuw: bool, nsw: bool) -> i32 {
    if res < 0 { return off; }
    var nm: u8[>..] = [];
    nm.append(gname); nm.append(".offs");
    return icb_add_nw(res, off, nm, nuw, nsw);
}
fn icc_unique_int_c(c: i32) -> AP { if vals[c].kind == VK_CINT { ci_ap(c) } else { ci_ap(splat_value(c, false)) } }
// IRBuilder::CreateIntCast (ic_casts' icb_int_cast without the import cycle)
fn icb_int_cast_c(v: i32, ty: i32, signed: bool, name: const u8[:]) -> i32 {
    if vals[v].ty == ty { return v; }
    let sb = ty_scalar_bits(vals[v].ty);
    let db = ty_scalar_bits(ty);
    let o = if sb == db { OP_BITCAST } else if sb > db { OP_TRUNC } else if signed { OP_SEXT } else { OP_ZEXT };
    return icb_cast(o, v, ty, name);
}

// EmitGEPOffset(GEP, RewriteGEP)
fn emit_gep_offset(g: i32, rewrite: bool) -> i32 {
    if !rewrite { return emit_gep_offset_raw(g); }
    let spos = icb_pos; let sbb = icb_bb; let sdl = icb_dl;
    let inst = is_inst(g);
    if inst { icb_set_insert_point(g); }
    let off = emit_gep_offset_raw(g);
    if inst && !gep_all_constant_indices(g) && !is_int_or_int_vec_w(gep_src_ty(g), 8) {
        let ng = icb_gep(T_I8, op(g, 0), [off], "", gep_flags(g));
        ic_replace_inst_uses_with(g, ng);
        ic_erase(g);
    }
    icb_pos = spos; icb_bb = sbb; icb_dl = sdl;
    return off;
}

// EmitGEPOffsets(GEPs, NW, IdxTy, RewriteGEPs): GEPs are geps[from..to)
fn emit_gep_offsets(geps: const i32[:], nw: u8, idxty: i32, rewrite: bool) -> i32 {
    var sum: i32 = -1;
    var ou_sum: i32 = -1;
    var ou_base: i32 = -1;
    var ou_flags: u8 = GEP_INBOUNDS | GEP_NUSW | GEP_NUW;
    let nuw = (nw & GEP_NUW) != 0;
    let inb = (nw & GEP_INBOUNDS) != 0;
    var k = geps.len;
    while k > 0 {
        k--;
        let g = geps[k];
        var off: i32 = -1;
        let spos = icb_pos; let sbb = icb_bb; let sdl = icb_dl;
        let inst = is_inst(g);
        if rewrite && inst { icb_set_insert_point(g); }
        off = emit_gep_offset_raw(g);
        if vals[off].ty != idxty { off = icb_vector_splat(idxty, off, ""); }
        if has_one_use(g) {
            ou_sum = if ou_sum >= 0 { icb_add_nw(ou_sum, off, "", nuw, inb) } else { off };
            ou_flags = gep_nw_intersect_for_offset_add(ou_flags, gep_flags(g));
            if ou_base < 0 { ou_base = op(g, 0); }
            icb_pos = spos; icb_bb = sbb; icb_dl = sdl;
            continue;
        }
        if ou_sum >= 0 { off = icb_add_nw(ou_sum, off, "", nuw, inb); }
        if rewrite && inst && ty_is_vector(vals[off].ty) == ty_is_vector(vals[g].ty) &&
           !(is_int_or_int_vec_w(gep_src_ty(g), 8) && op(g, 1) == off) {
            let np = icb_ptr_add(if ou_base >= 0 { ou_base } else { op(g, 0) }, off, "", gep_nw_intersect_for_offset_add(ou_flags, gep_flags(g)));
            ic_replace_inst_uses_with(g, np);
            ic_erase(g);
        }
        icb_pos = spos; icb_bb = sbb; icb_dl = sdl;
        sum = if sum >= 0 { icb_add_nw(sum, off, "", nuw, inb) } else { off };
        ou_sum = -1;
        ou_base = -1;
        ou_flags = GEP_INBOUNDS | GEP_NUSW | GEP_NUW;
    }
    if ou_sum >= 0 { sum = if sum >= 0 { icb_add_nw(sum, ou_sum, "", nuw, inb) } else { ou_sum }; }
    if sum < 0 { return c_null(idxty); }
    return sum;
}
