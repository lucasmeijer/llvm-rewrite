// InstCombine selects: port of llvm/lib/Transforms/InstCombine/InstCombineSelect.cpp (visitSelectInst and every
// helper of that file, in the order of the C++ file). foldAndOrOfSelectUsingImpliedCond and
// simplifyNestedSelectsUsingImpliedCond live in ic_andorxor.goose (ported there first).
//
// Conventions (DESIGN.md §12): a fold returns an instruction id: -1 = nullptr, the visited instruction =
// modified in place, or a new unattached instruction. Static helpers of the C++ file keep their LLVM names in
// snake_case; small local helpers are prefixed `sl_`.
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
import fpu;
import ic;
import ic_builder;
import ic_common;
import ic_compares;
import ic_andorxor;
import ic_casts;
import ic_demanded;
import ic_demanded_elts;

// ---------------------------------------------------------------------------------------------
// Small helpers

// a copy of v's name plus a suffix (Twine `V->getName() + Sfx`)
fn sl_name(v: i32, sfx: const u8[:]) -> u8[>..] {
    var nm: u8[>..] = [];
    nm.append(val_name(v));
    nm.append(sfx);
    return nm;
}
fn sl_fmf(v: i32) -> u8 { if is_inst(v) && is_fp_math_operator(v) { insts[inst_of(v)].fmf } else { 0 } }
fn sl_set_fmf(v: i32, f: u8) { if is_inst(v) { insts[inst_of(v)].fmf = f; } }
fn sl_is_fp_pred(p: i64) -> bool { p <= 15 }
// ConstantExpr::getBinOpIdentity(Opc, Ty, AllowRHSConstant = true, NSZ)
fn sl_binop_identity_nsz(o: i64, ty: i32, nsz: bool) -> i32 {
    if o == OP_FADD && nsz { return c_null(ty); }
    return binop_identity(o, ty, true);
}
// Instruction::isSameOperationAs (binary operators, casts, compares, GEPs)
fn sl_same_operation_as(a: i32, b: i32) -> bool {
    if iop(a) != iop(b) || vals[a].ty != vals[b].ty || nops(a) != nops(b) { return false; }
    for k in nops(a) { if vals[op(a, k)].ty != vals[op(b, k)].ty { return false; } }
    let o = iop(a);
    if o == OP_ICMP || o == OP_FCMP { return inst_pred(a) == inst_pred(b); }
    if o == OP_GEP { return gep_src_ty(a) == gep_src_ty(b); }
    if o == OP_CALL || o == OP_LOAD || o == OP_STORE || o == OP_ALLOCA { ic_not_ported("isSameOperationAs for memory/call instructions"); }
    return true;
}
fn sl_is_int_div_rem(o: i64) -> bool { o == OP_UDIV || o == OP_SDIV || o == OP_UREM || o == OP_SREM }
// m_c_BinOp-style: the other operand of binop v when one operand is x (operand 1 tried first as "Specific")
// For m_c_Op(m_Specific(X), m_Value(Y)): op0 == X -> Y = op1, else op1 == X -> Y = op0
fn sl_other_c(v: i32, x: i32) -> i32 {
    if op(v, 0) == x { return op(v, 1); }
    if op(v, 1) == x { return op(v, 0); }
    return -1;
}
// m_FAbs(m_Specific(X))
fn sl_fabs_of(v: i32, x: i32) -> bool { inst_iid(v) == IID_fabs && op(v, 0) == x }
// UnaryOperator::CreateFNeg (unattached)
fn sl_new_fneg(v: i32) -> i32 { create_inst(OP_FNEG, vals[v].ty, [v]) }
// computeKnownFPClass(V, FMF, Interested, SQ.getWithInstruction(CxtI))
fn sl_kfc(v: i32, fmf: u8, interested: u64, cxt: i32) -> KFC {
    kb_cxt = cxt;
    return known_fp_class(v, interested, fmf, 0);
}

// ---------------------------------------------------------------------------------------------
// foldSelectBinOpIdentity(Sel, TLI, IC)
fn fold_select_binop_identity(sel: i32) -> i32 {
    let c0 = op(sel, 0);
    if !is_cmp_inst(c0) || !is_constant(op(c0, 1)) { return -1; }
    let x = op(c0, 0);
    let c = op(c0, 1);
    let p = inst_pred(c0);
    var is_eq = false;
    if p == 32 || p == 33 { is_eq = p == 32; }
    else if p == 1 { is_eq = true; }
    else if p == 14 { is_eq = false; }
    else { return -1; }
    let bov = op(sel, if is_eq { 1 } else { 2 });
    if !is_binop_inst(bov) { return -1; }
    var absorbing = false;
    var y: i32 = -1;
    let o = iop(bov);
    if is_commutative(o) {
        var fm = false;
        if o == OP_FMUL {
            if sl_fabs_of(op(bov, 0), x) { y = op(bov, 1); fm = true; }
            else if sl_fabs_of(op(bov, 1), x) { y = op(bov, 0); fm = true; }
        }
        if fm && m_any_zero_fp(c) && fmul_by_zero_is_zero(y, sl_fmf(bov), sel) { absorbing = true; }
        else {
            if op(bov, 1) == x { y = op(bov, 0); }
            else if op(bov, 0) == x { y = op(bov, 1); }
            else { return -1; }
        }
    } else {
        if op(bov, 1) != x { return -1; }
        y = op(bov, 0);
    }
    let ty = vals[bov].ty;
    var folded: i32 = -1;
    if absorbing {
        folded = c;
    } else {
        let idc = binop_identity(o, ty, true);
        if idc != c {
            if idc < 0 || !sl_is_fp_pred(p) { return -1; }
            if !m_any_zero_fp(idc) || !m_any_zero_fp(c) { return -1; }
        }
        if is_fp_math_operator(bov) {
            kb_cxt = sel;
            if (sl_fmf(bov) & FMF_NSZ) == 0 && !cannot_be_negative_zero(y, 0) { return -1; }
        }
        folded = y;
    }
    return ic_replace_operand(sel, if is_eq { 1 } else { 2 }, folded);
}

// foldSelectICmpAnd(Sel, CondVal, TrueVal, FalseVal, V, AndMask, CreateAnd, Builder)
fn fold_select_icmp_and(sel: i32, condv: i32, tv: i32, fv: i32, v0: i32, and_mask: AP, create_and: bool) -> i32 {
    var v = v0;
    if !has_apint(tv) || !has_apint(fv) { return -1; }
    let selty = vals[sel].ty;
    let tc = ap_c(tv);
    let fc = ap_c(fv);
    if !ap_is_zero(tc) && !ap_is_zero(fc) {
        if (tc.w as i64) != (and_mask.w as i64) { return -1; }
        if create_and && !has_one_use(condv) { return -1; }
        let tcc = c_int_ap(selty, tc);
        let fcc = c_int_ap(selty, fc);
        let maskc = c_int_ap(selty, and_mask);
        let opcs: i64[4] = [OP_OR, OP_XOR, OP_ADD, OP_SUB];
        for opc in opcs {
            if cf_fold_binop_operands(opc, tcc, maskc) == fcc {
                if create_and { v = icb_and(v, maskc, ""); }
                return icb_binop(opc, tcc, v, "");
            }
        }
        return -1;
    }
    if !ap_is_pow2(tc) && !ap_is_pow2(fc) { return -1; }
    let valc = if !ap_is_zero(tc) { tc } else { fc };
    let val_zeros = ap_log2(valc);
    let and_zeros = ap_log2(and_mask);
    let should_not_val = !ap_is_zero(tc);
    let need_shift = val_zeros != and_zeros;
    let need_zext_trunc = ty_scalar_bits(selty) != ty_sbits(v);
    var cnt = 0;
    if create_and { cnt++; }
    if should_not_val { cnt++; }
    if need_shift { cnt++; }
    if need_zext_trunc { cnt++; }
    if cnt > 1 + (if has_one_use(condv) { 1 } else { 0 }) { return -1; }
    if create_and { v = icb_and(v, c_int_ap(vals[v].ty, and_mask), ""); }
    if val_zeros > and_zeros {
        v = icb_zext_or_trunc(v, selty, "");
        v = icb_shl(v, c_int_ty(vals[v].ty, (val_zeros - and_zeros) as u64), "");
    } else if val_zeros < and_zeros {
        v = icb_lshr(v, c_int_ty(vals[v].ty, (and_zeros - val_zeros) as u64), "", false);
        v = icb_zext_or_trunc(v, selty, "");
    } else {
        v = icb_zext_or_trunc(v, selty, "");
    }
    if should_not_val { v = icb_xor(v, c_int_ap(vals[v].ty, valc), ""); }
    return v;
}

// getSelectFoldableOperands(I)
fn get_select_foldable_operands(i: i32) -> i64 {
    let o = iop(i);
    if o == OP_ADD || o == OP_FADD || o == OP_MUL || o == OP_FMUL || o == OP_AND || o == OP_OR || o == OP_XOR { return 3; }
    if o == OP_SUB || o == OP_FSUB || o == OP_FDIV || o == OP_SHL || o == OP_LSHR || o == OP_ASHR { return 1; }
    return 0;
}

// the getCommonOp lambda of foldSelectOpOp: MatchOp, OtherOpT, OtherOpF, MatchIsOpZero
fn sl_get_common_op(ti: i32, fi: i32, commute: bool, swapped: bool) -> i32, i32, i32, bool {
    if !swapped {
        if op(ti, 0) == op(fi, 0) { return op(ti, 0), op(ti, 1), op(fi, 1), true; }
        if op(ti, 1) == op(fi, 1) { return op(ti, 1), op(ti, 0), op(fi, 0), false; }
    }
    if !commute && !swapped { return -1, -1, -1, false; }
    if op(ti, 0) == op(fi, 1) { return op(ti, 0), op(ti, 1), op(fi, 0), true; }
    if op(ti, 1) == op(fi, 0) { return op(ti, 1), op(ti, 0), op(fi, 1), false; }
    return -1, -1, -1, false;
}

// InstCombinerImpl::foldSelectOpOp(SI, TI, FI)
fn fold_select_op_op(si: i32, ti: i32, fi: i32) -> i32 {
    var cond = op(si, 0);
    let condty = vals[cond].ty;
    if nops(ti) == 1 && is_cast_op(iop(ti)) {
        let fiopty = vals[op(fi, 0)].ty;
        if vals[op(ti, 0)].ty != fiopty { return -1; }
        if ty_is_vector(condty) {
            if !ty_is_vector(fiopty) || ty_count(condty) != ty_count(fiopty) || ty_kind(condty) != ty_kind(fiopty) { return -1; }
            if iop(ti) != OP_BITCAST && (!has_one_use(ti) || !has_one_use(fi)) { return -1; }
        } else if !has_one_use(ti) || !has_one_use(fi) {
            return -1;
        }
        let ns = icb_select(cond, op(ti, 0), op(fi, 0), sl_name(si, ".v"), si);
        return ic_new_cast(iop(ti), ns, vals[ti].ty);
    }
    if has_one_use(ti) || has_one_use(fi) {
        let x = m_fneg(ti);
        let y = m_fneg(fi);
        if x >= 0 && y >= 0 {
            var fmf = sl_fmf(ti) & sl_fmf(fi);
            fmf |= sl_fmf(si);
            let ns = icb_select(cond, x, y, sl_name(si, ".v"), si);
            if is_inst(ns) { sl_set_fmf(ns, fmf); }
            let nf = sl_new_fneg(ns);
            sl_set_fmf(nf, fmf);
            return nf;
        }
        let tid = inst_iid(ti);
        let fid = inst_iid(fi);
        if tid != 0 && tid == fid {
            if is_minmax_iid(tid) {
                let mop, ot, of, iz = sl_get_common_op(ti, fi, true, false);
                if mop >= 0 {
                    let ns = icb_select(cond, ot, of, "minmaxop", si);
                    return ic_new_intrinsic(tid, [vals[ti].ty as i32], [ns, mop]);
                }
            }
            if tid == IID_ldexp {
                let v0 = op(ti, 0);
                let e0 = op(ti, 1);
                let v1 = op(fi, 0);
                let e1 = op(fi, 1);
                if vals[e0].ty == vals[e1].ty {
                    var fmf = sl_fmf(ti) & sl_fmf(fi);
                    fmf |= sl_fmf(si);
                    let sv = icb_select(cond, v0, v1, "", -1);
                    let se = icb_select(cond, e0, e1, "", -1);
                    let saved = icb_fmf;
                    icb_fmf = fmf;
                    let nl = icb_intrinsic(IID_ldexp, [vals[ti].ty as i32, vals[se].ty as i32], [sv, se], "");
                    icb_fmf = saved;
                    return ic_replace_inst_uses_with(si, nl);
                }
            }
        }
        if is_inst_op(ti, OP_ICMP) && is_inst_op(fi, OP_ICMP) {
            let tp = icmp_cp(ti);
            let fp = icmp_cp(fi);
            let r1 = sl_create_cmp_sel(si, cond, ti, fi, cp_get_matching(tp, fp), false);
            if r1 >= 0 { return r1; }
            let fps = cp(pred_swapped(cp_pred(fp)), cp_ss(fp));
            let r2 = sl_create_cmp_sel(si, cond, ti, fi, cp_get_matching(tp, fps), true);
            if r2 >= 0 { return r2; }
        }
    }
    // (isSameOperationAs is pure: the binop/GEP test is evaluated first so calls never reach it)
    if nops(ti) != 2 || nops(fi) != 2 || (!is_binop_inst(ti) && iop(ti) != OP_GEP) || !sl_same_operation_as(ti, fi) ||
       !has_one_use(ti) || !has_one_use(fi) { return -1; }
    let comm = is_binop_inst(ti) && is_commutative(iop(ti));
    let mop, ot, of, iz = sl_get_common_op(ti, fi, comm, false);
    if mop < 0 { return -1; }
    if ty_is_vector(condty) && (!ty_is_vector(vals[ot].ty) || !ty_is_vector(vals[of].ty)) { return -1; }
    if is_binop_inst(ti) && sl_is_int_div_rem(iop(ti)) && !is_guaranteed_not_to_be_poison(cond, -1, 0) {
        if iop(ti) == OP_SDIV || iop(ti) == OP_SREM || iz { cond = icb_freeze(cond, ""); }
    }
    let ns = icb_select(cond, ot, of, sl_name(si, ".v"), si);
    let a = if iz { mop } else { ns };
    let b = if iz { ns } else { mop };
    if is_binop_inst(ti) {
        let nb = ic_new_binop(iop(ti), a, b);
        copy_ir_flags(nb, ti);
        sl_and_ir_flags(nb, fi);
        return nb;
    }
    let srcty = gep_src_ty(ti);
    let g = create_inst(OP_GEP, gep_ret_type(a, [b]), [a, b]);
    insts[inst_of(g)].ty2 = srcty;
    insts[inst_of(g)].flags = gep_flags(ti) & gep_flags(fi);
    return g;
}
// Instruction::andIRFlags(V)
fn sl_and_ir_flags(a: i32, b: i32) {
    let ia = inst_of(a);
    insts[ia].flags = insts[ia].flags & op_flags(b);
    if is_fp_math_operator(a) && is_fp_math_operator(b) { insts[ia].fmf = insts[ia].fmf & insts[inst_of(b)].fmf; }
}
// the CreateCmpSel lambda of foldSelectOpOp
fn sl_create_cmp_sel(si: i32, cond: i32, ti: i32, fi: i32, p: i64, swapped: bool) -> i32 {
    if p < 0 { return -1; }
    let pr = cp_pred(p);
    let eq = pr == 32 || pr == 33;
    let mop, ot, of, iz = sl_get_common_op(ti, fi, eq, !eq && swapped);
    if mop < 0 { return -1; }
    let ns = icb_select(cond, ot, of, sl_name(si, ".v"), si);
    return ic_new_icmp(if iz { pr } else { pred_swapped(pr) }, mop, ns);
}

// InstCombinerImpl::foldSelectIntrinsic(SI)
fn fold_select_intrinsic(si: i32) -> i32 {
    let l = op(si, 1);
    let r = op(si, 2);
    let lid = inst_iid(l);
    if lid == 0 { return -1; }
    if inst_iid(r) != lid || !has_one_use(l) || !has_one_use(r) { return -1; }
    if lid == IID_abs || lid == IID_cttz || lid == IID_ctlz {
        let tz = op(l, 1);
        let fz = op(r, 1);
        let ns = icb_select(op(si, 0), op(l, 0), op(r, 0), "", si);
        let pf = icb_and(tz, fz, "");
        let nc = icb_binary_intrinsic(lid, ns, pf, "");
        return ic_replace_inst_uses_with(si, nc);
    }
    if lid == IID_ctpop {
        let ns = icb_select(op(si, 0), op(l, 0), op(r, 0), "", si);
        let nc = icb_unary_intrinsic(lid, ns, "");
        return ic_replace_inst_uses_with(si, nc);
    }
    return -1;
}

// isSelect01(C1I, C2I)
fn is_select01(c1: AP, c2: AP) -> bool {
    if !ap_is_zero(c1) && !ap_is_zero(c2) { return false; }
    return ap_is_one(c1) || ap_is_all_ones(c1) || ap_is_one(c2) || ap_is_all_ones(c2);
}

// InstCombinerImpl::foldSelectIntoOp(SI, TrueVal, FalseVal)
fn fold_select_into_op(si: i32, tv: i32, fv: i32) -> i32 {
    let r = sl_try_fold_select_into_op(si, tv, fv, false);
    if r >= 0 { return r; }
    return sl_try_fold_select_into_op(si, fv, tv, true);
}
// the TryFoldSelectIntoOp lambda
fn sl_try_fold_select_into_op(si: i32, tv: i32, fv: i32, swapped: bool) -> i32 {
    if !is_binop_inst(tv) || !has_one_use(tv) || is_constant(fv) { return -1; }
    let sfo = get_select_foldable_operands(tv);
    var op_to_fold = 0;
    if (sfo & 1) != 0 && fv == op(tv, 0) { op_to_fold = 1; }
    else if (sfo & 2) != 0 && fv == op(tv, 1) { op_to_fold = 2; }
    if op_to_fold == 0 { return -1; }
    let is_fp = is_fp_math_operator(si);
    let fmf = if is_fp { insts[inst_of(si)].fmf } else { 0 as u8 };
    let c = sl_binop_identity_nsz(iop(tv), vals[tv].ty, (fmf & FMF_NSZ) != 0);
    let oop = op(tv, 2 - op_to_fold);
    if is_constant(oop) {
        if !has_apint(oop) || !is_select01(icc_unique_int_c(c), ap_c(oop)) { return -1; }
    }
    if is_fp && !kfc_never_nan(sl_kfc(fv, fmf, FCL_NAN, si)) { return -1; }
    let ns = icb_select(op(si, 0), if swapped { c } else { oop }, if swapped { oop } else { c }, "", si);
    if is_fp {
        var nf = fmf;
        let to = iop(tv);
        let can_infer = to == OP_FADD || to == OP_FSUB || to == OP_FMUL;
        let ninf = (sl_fmf(tv) & FMF_NINF) != 0 || (can_infer && (nf & FMF_NINF) != 0 && (nf & FMF_NNAN) != 0);
        if ninf { nf |= FMF_NINF; } else { nf &= ~FMF_NINF; }
        sl_set_fmf(ns, nf);
    }
    ic_take_name(ns, tv);
    let b = ic_new_binop(iop(tv), fv, ns);
    copy_ir_flags(b, tv);
    if is_fp {
        let bi = inst_of(b);
        var bf = insts[bi].fmf;
        if (fmf & FMF_NNAN) == 0 { bf &= ~FMF_NNAN; }
        if (fmf & FMF_NINF) == 0 { bf &= ~FMF_NINF; }
        if (fmf & FMF_NSZ) == 0 { bf &= ~FMF_NSZ; }
        insts[bi].fmf = bf;
    }
    return b;
}

// canoncalizeSelectICmpMinMax(Cmp, TVal, FVal, Builder, SQ)
fn canoncalize_select_icmp_min_max(cmp: i32, tv0: i32, fv0: i32, cxt: i32) -> i32 {
    var l = op(cmp, 0);
    var r = op(cmp, 1);
    var p = inst_pred(cmp);
    var tv = tv0;
    var fv = fv0;
    if m_zero(fv) { let t = tv; tv = fv; fv = t; p = pred_inverse(p); }
    if !m_zero(tv) { return -1; }
    if p == P_SGT || p == P_SGE { let t = l; l = r; r = t; p = pred_swapped(p); }
    if (p == P_SLT || p == P_SLE) && bo(fv, OP_SUB) && op_nsw(fv) && op(fv, 0) == l && op(fv, 1) == r &&
       is_guaranteed_not_to_be_undef(l, cxt, 0) {
        let smin = icb_binary_intrinsic(IID_smin, r, l, "");
        return icb_sub_nw(l, smin, "", false, true);
    }
    return -1;
}

// foldSelectICmpMinMax(Cmp, TVal, FVal, Builder, SQ)
fn fold_select_icmp_min_max(cmp: i32, tv: i32, fv: i32, cxt: i32) -> i32 {
    var l = op(cmp, 0);
    var r = op(cmp, 1);
    var p = inst_pred(cmp);
    let v = canoncalize_select_icmp_min_max(cmp, tv, fv, cxt);
    if v >= 0 { return v; }
    if r == tv { let t = l; l = r; r = t; p = pred_swapped(p); }
    if !(l == tv && is_inst(fv)) { return -1; }
    if p == P_SGT && bo(fv, OP_ADD) && op_nsw(fv) && op(fv, 0) == r && m_one(op(fv, 1)) {
        set_nuw(fv, false);
        return icb_binary_intrinsic(IID_smax, tv, fv, "");
    }
    if p == P_SLT && bo(fv, OP_ADD) && op_nsw(fv) && op(fv, 0) == r && m_all_ones(op(fv, 1)) {
        set_nuw(fv, false);
        return icb_binary_intrinsic(IID_smin, tv, fv, "");
    }
    if p == P_UGT && bo(fv, OP_ADD) && op_nuw(fv) && op(fv, 0) == r && m_one(op(fv, 1)) {
        set_nsw(fv, false);
        return icb_binary_intrinsic(IID_umax, tv, fv, "");
    }
    if p == P_ULT && bo(fv, OP_ADD) && op(fv, 0) == r && m_all_ones(op(fv, 1)) {
        kb_cxt = cxt;
        if is_known_non_zero(r, 0) {
            set_nsw(fv, false);
            set_nuw(fv, false);
            return icb_binary_intrinsic(IID_umin, tv, fv, "");
        }
    }
    return -1;
}

// foldSelectICmpAndAnd(SelType, Cmp, TVal, FVal, Builder)
fn fold_select_icmp_and_and(selty: i32, cmp: i32, tv: i32, fv: i32) -> i32 {
    if !(has_one_use(cmp) && has_one_use(op(cmp, 0)) && inst_pred(cmp) == P_EQ && m_zero(op(cmp, 1)) && m_one(fv)) { return -1; }
    if !(one_use(tv) && bo(tv, OP_AND) && m_one(op(tv, 1))) { return -1; }
    let b = op(tv, 0);
    var x: i32 = -1;
    var z: i32 = -1;
    let has_shift = one_use(b) && bo(b, OP_LSHR);
    if has_shift { x = op(b, 0); z = op(b, 1); }
    let w = ty_scalar_bits(selty);
    if has_shift && !ao_specific_int_icmp(z, P_ULT, ap_u64(w as u64, w)) { return -1; }
    if !has_shift { x = b; }
    let a = op(cmp, 0);
    if !bo(a, OP_AND) { return -1; }
    let y = sl_other_c(a, x);
    if y < 0 { return -1; }
    let one = c_int_ty(selty, 1);
    let maskb = if has_shift { icb_shl(one, z, "") } else { one };
    let full = icb_or(y, maskb, "");
    let masked = icb_and(x, full, "");
    let ne = icb_is_not_null(masked, "");
    return ic_new_cast(OP_ZEXT, ne, selty);
}

// foldSelectICmpAndZeroShl(Cmp, TVal, FVal, Builder)
fn fold_select_icmp_and_zero_shl(cmp: i32, tv0: i32, fv0: i32) -> i32 {
    if !is_inst_op(cmp, OP_ICMP) || !m_zero(op(cmp, 1)) { return -1; }
    let andv = op(cmp, 0);
    var p = inst_pred(cmp);
    var tv = tv0;
    var fv = fv0;
    if p == P_NE { p = P_EQ; let t = tv; tv = fv; fv = t; }
    if p != P_EQ || !bo(andv, OP_AND) || !has_apint(op(andv, 1)) { return -1; }
    let x = op(andv, 0);
    if !m_zero(tv) || !bo(fv, OP_SHL) || op(fv, 0) != x || !has_apint(op(fv, 1)) { return -1; }
    let c1 = ap_c(op(andv, 1));
    let c2 = ap_c(op(fv, 1));
    if !ap_is_mask(c1) || (ap_countl_zero(c1) as u64) != ap_zext64(c2) { return -1; }
    set_nsw(fv, false);
    set_nuw(fv, false);
    return fv;
}

// foldSelectICmpLshrAshr(IC, TrueVal, FalseVal, Builder)
fn fold_select_icmp_lshr_ashr(ic: i32, tv0: i32, fv0: i32) -> i32 {
    let p = inst_pred(ic);
    let l = op(ic, 0);
    let r = op(ic, 1);
    if !is_int_or_int_vec(vals[r].ty) { return -1; }
    let w = ty_sbits(r);
    if (p != P_SGT || !ao_specific_int_icmp(r, P_SGE, ap_ones(w))) &&
       (p != P_SLT || !ao_specific_int_icmp(r, P_SGE, ap_zero(w))) { return -1; }
    var tv = tv0;
    var fv = fv0;
    if p == P_SLT { let t = tv; tv = fv; fv = t; }
    if bo(tv, OP_LSHR) {
        let x = op(tv, 0);
        let y = op(tv, 1);
        if bo(fv, OP_ASHR) && op(fv, 0) == x && op(fv, 1) == y && l == x {
            let exact = op_exact(fv) && op_exact(tv);
            return icb_ashr(x, y, sl_name(ic, ""), exact);
        }
    }
    return -1;
}

// foldSelectICmpAndBinOp(CondVal, TrueVal, FalseVal, V, AndMask, CreateAnd, Builder)
fn fold_select_icmp_and_binop(condv: i32, tv: i32, fv: i32, v0: i32, and_mask: AP, create_and: bool) -> i32 {
    if !is_int_or_int_vec(vals[tv].ty) { return -1; }
    var v = v0;
    let c1log = ap_log2(and_mask);
    var y: i32 = -1;
    var binop: i32 = -1;
    var need_xor = false;
    if is_binop_inst(fv) && op(fv, 0) == tv && sl_apint_pred(op(fv, 1), IP_POWER2) {
        y = tv; binop = fv; need_xor = false;
    } else if is_binop_inst(tv) && op(tv, 0) == fv && sl_apint_pred(op(tv, 1), IP_POWER2) {
        y = fv; binop = tv; need_xor = true;
    } else { return -1; }
    let c2 = ap_cp(op(binop, 1));
    let idc = binop_identity(iop(binop), vals[binop].ty, true);
    if idc < 0 || !is_null_value(idc) { return -1; }
    let c2log = ap_log2(c2);
    let need_shift = c1log != c2log;
    let need_zt = ty_sbits(y) != ty_sbits(v);
    var cnt = 0;
    if need_shift { cnt++; }
    if need_xor { cnt++; }
    if need_zt { cnt++; }
    if create_and { cnt++; }
    var avail = 0;
    if has_one_use(condv) { avail++; }
    if has_one_use(binop) { avail++; }
    if cnt > avail { return -1; }
    if create_and { v = icb_and(v, c_int_ap(vals[v].ty, and_mask), ""); }
    let yty = vals[y].ty;
    if c2log > c1log {
        v = icb_zext_or_trunc(v, yty, "");
        v = icb_shl(v, c_int_ty(vals[v].ty, (c2log - c1log) as u64), "");
    } else if c1log > c2log {
        v = icb_lshr(v, c_int_ty(vals[v].ty, (c1log - c2log) as u64), "", false);
        v = icb_zext_or_trunc(v, yty, "");
    } else {
        v = icb_zext_or_trunc(v, yty, "");
    }
    if need_xor { v = icb_xor(v, c_int_ap(vals[v].ty, c2), ""); }
    let res = icb_binop(iop(binop), y, v, "");
    if is_binop_inst(res) { copy_ir_flags(res, binop); }
    return res;
}

// foldSetClearBits(Sel, Builder)
fn fold_set_clear_bits(sel: i32) -> i32 {
    let cond = op(sel, 0);
    let t = op(sel, 1);
    let f = op(sel, 2);
    let ty = vals[sel].ty;
    if bo(t, OP_AND) && has_apint(op(t, 1)) && one_use(f) && bo(f, OP_OR) && op(f, 0) == op(t, 0) && has_apint(op(f, 1)) &&
       ap_eq(ap_c(op(t, 1)), ap_not(ap_c(op(f, 1)))) {
        let z = c_null(ty);
        let orc = c_int_ap(ty, ap_c(op(f, 1)));
        let ns = icb_select(cond, z, orc, "masksel", sel);
        return ic_new_binop(OP_OR, t, ns);
    }
    if bo(f, OP_AND) && has_apint(op(f, 1)) && one_use(t) && bo(t, OP_OR) && op(t, 0) == op(f, 0) && has_apint(op(t, 1)) &&
       ap_eq(ap_c(op(f, 1)), ap_not(ap_c(op(t, 1)))) {
        let z = c_null(ty);
        let orc = c_int_ap(ty, ap_c(op(t, 1)));
        let ns = icb_select(cond, orc, z, "masksel", sel);
        return ic_new_binop(OP_OR, f, ns);
    }
    return -1;
}

// foldSelectZeroOrFixedOp(SI, IC)
fn fold_select_zero_or_fixed_op(si: i32) -> i32 {
    let condv = op(si, 0);
    var tv = op(si, 1);
    var fv = op(si, 2);
    if !is_inst_op(condv, OP_ICMP) || !m_zero(op(condv, 1)) { return -1; }
    let p = inst_pred(condv);
    if p != P_EQ && p != P_NE { return -1; }
    let x = op(condv, 0);
    if p == P_NE { let t = tv; tv = fv; fv = t; }
    if !is_constant(tv) || !is_inst(fv) { return -1; }
    var freeze_y = false;
    var y: i32 = -1;
    let fid = inst_iid(fv);
    if (bo(fv, OP_MUL) || bo(fv, OP_AND)) && sl_other_c(fv, x) >= 0 { y = sl_other_c(fv, x); freeze_y = true; }
    else if (fid == IID_fshl || fid == IID_fshr) && op(fv, 0) == x && op(fv, 1) == x { y = op(fv, 2); freeze_y = true; }
    else if fid == IID_umin && sl_other_c(fv, x) >= 0 { y = sl_other_c(fv, x); freeze_y = true; }
    else if (bo(fv, OP_SDIV) || bo(fv, OP_UDIV) || bo(fv, OP_SREM) || bo(fv, OP_UREM)) && op(fv, 0) == x { y = op(fv, 1); freeze_y = false; }
    else { return -1; }
    let zc = op(condv, 1);
    let merged = ao_merge_undefs_with(tv, zc);
    if !m_zero(merged) && !m_undef(merged) { return -1; }
    if freeze_y {
        let fr = create_inst(OP_FREEZE, vals[y].ty, [y]);
        set_name(fr, sl_name(y, ".fr"));
        ic_insert_new_before(fr, fv);
        let k = if op(fv, 0) == y { 0 } else { if op(fv, 1) == y { 1 } else { 2 } };
        ic_replace_operand(fv, k, fr);
    }
    return ic_replace_inst_uses_with(si, fv);
}

// m_SpecificInt(APInt) with poison lanes allowed (m_SpecificIntAllowPoison)
fn sl_specific_int_poison(v: i32, x: AP) -> bool {
    if v < 0 { return false; }
    let c = m_apint_ap(v, true);
    if c < 0 { return false; }
    return ap_same_value_u(ci_ap(c), x);
}
// m_NotForbidPoison(m_Value(X)): xor X, -1 (no poison lanes, commutative); X or -1
fn sl_not_forbid_poison(v: i32) -> i32 {
    if !bo(v, OP_XOR) { return -1; }
    if m_cint_pred(op(v, 1), IP_ALLONES, false) { return op(v, 0); }
    if m_cint_pred(op(v, 0), IP_ALLONES, false) { return op(v, 1); }
    return -1;
}
// CmpInst::getStrictPredicate
fn sl_strict_pred(p: i64) -> i64 { match p { 39 => 38, 41 => 40, 35 => 34, 37 => 36, _ => p } }
// m_APInt with no poison: the APInt of a splat or -1 check
// api_pred_ty (m_Power2(const APInt *&), m_StrictlyPositive(C), ...): poison lanes allowed in splats
fn sl_apint_pred(v: i32, kind: i64) -> bool { has_apint_poison(v) && int_pred(kind, m_apint_ap(v, true)) }

// canonicalizeSaturatedSubtractUnsigned(ICI, TrueVal, FalseVal, Builder)
fn canonicalize_saturated_subtract_unsigned(ici: i32, tv0: i32, fv0: i32) -> i32 {
    var p = inst_pred(ici);
    var a = op(ici, 0);
    var b = op(ici, 1);
    var tv = tv0;
    var fv = fv0;
    if m_zero(tv) { p = pred_inverse(p); let t = tv; tv = fv; fv = t; }
    if !m_zero(fv) { return -1; }
    if p == P_NE {
        if m_zero(b) && bo(tv, OP_ADD) && op(tv, 0) == a && m_all_ones(op(tv, 1)) {
            return icb_binary_intrinsic(IID_usub_sat, a, c_int_ty(vals[a].ty, 1), "");
        }
        return -1;
    }
    if !icmp_is_unsigned(p) { return -1; }
    if p == P_ULE || p == P_ULT { let t = a; a = b; b = t; p = pred_swapped(p); }
    var is_neg = false;
    if (bo(tv, OP_SUB) && op(tv, 0) == b && op(tv, 1) == a) ||
       (has_apint(a) && bo(tv, OP_ADD) && op(tv, 0) == b && m_specific_int_apv(op(tv, 1), ap_neg(ap_c(a)))) {
        is_neg = true;
    } else if !(bo(tv, OP_SUB) && op(tv, 0) == a && op(tv, 1) == b) &&
              !(has_apint(b) && bo(tv, OP_ADD) && op(tv, 0) == a && m_specific_int_apv(op(tv, 1), ap_neg(ap_c(b)))) {
        return -1;
    }
    if is_neg && !has_one_use(tv) && !has_one_use(ici) { return -1; }
    var res = icb_binary_intrinsic(IID_usub_sat, a, b, "");
    if is_neg { res = icb_neg(res, "", false); }
    return res;
}

// canonicalizeSaturatedSubtractSigned(ICI, TrueVal, FalseVal, Builder)
fn canonicalize_saturated_subtract_signed(ici: i32, tv0: i32, fv0: i32) -> i32 {
    var p = inst_pred(ici);
    let l = op(ici, 0);
    let r = op(ici, 1);
    var tv = tv0;
    var fv = fv0;
    if p == P_NE { p = P_EQ; let t = tv; tv = fv; fv = t; }
    if p == P_EQ && m_sign_mask(r) && m_cint_pred(tv, IP_MAXSIGNED, true) && m_neg(fv) == l {
        return icb_binary_intrinsic(IID_ssub_sat, c_null(vals[l].ty), l, "");
    }
    return -1;
}

// canonicalizeSaturatedSubtract(ICI, TrueVal, FalseVal, Builder)
fn canonicalize_saturated_subtract(ici: i32, tv: i32, fv: i32) -> i32 {
    let v = canonicalize_saturated_subtract_unsigned(ici, tv, fv);
    if v >= 0 { return v; }
    return canonicalize_saturated_subtract_signed(ici, tv, fv);
}

// canonicalizeSaturatedAddUnsigned(Cmp, TVal, FVal, Builder)
fn canonicalize_saturated_add_unsigned(cmp: i32, tv0: i32, fv0: i32) -> i32 {
    var c0 = op(cmp, 0);
    var c1 = op(cmp, 1);
    var p = inst_pred(cmp);
    var tv = tv0;
    var fv = fv0;
    if m_all_ones(fv) { let t = tv; tv = fv; fv = t; p = pred_inverse(p); }
    if !m_all_ones(tv) { return -1; }
    if p == P_EQ {
        if bo(fv, OP_ADD) && op(fv, 0) == c0 && m_one(op(fv, 1)) && m_all_ones(c1) {
            return icb_binary_intrinsic(IID_uadd_sat, c0, c_int_ty(vals[c0].ty, 1), "");
        }
        return -1;
    }
    let add_c = bo(fv, OP_ADD) && op(fv, 0) == c0 && has_apint_poison(op(fv, 1));
    if (p == P_UGE || p == P_UGT) && add_c {
        let c = ap_cp(op(fv, 1));
        if sl_specific_int_poison(c1, ap_not(c)) {
            return icb_binary_intrinsic(IID_uadd_sat, c0, c_int_ap(vals[c0].ty, c), "");
        }
    }
    if p == P_UGT && add_c {
        let c = ap_cp(op(fv, 1));
        if sl_specific_int_poison(c1, ap_dec(ap_not(c))) && !ap_is_all_ones(c) {
            return icb_binary_intrinsic(IID_uadd_sat, c0, c_int_ap(vals[c0].ty, c), "");
        }
    }
    if p == P_UGE && add_c {
        let c = ap_cp(op(fv, 1));
        if sl_specific_int_poison(c1, ap_neg(c)) && !ap_is_zero(c) {
            return icb_binary_intrinsic(IID_uadd_sat, c0, c_int_ap(vals[c0].ty, c), "");
        }
    }
    if p == P_UGT || p == P_UGE { let t = c0; c0 = c1; c1 = t; p = pred_swapped(p); }
    if p != P_ULT && p != P_ULE { return -1; }
    let x = m_not(c0);
    if x >= 0 && bo(fv, OP_ADD) {
        // m_c_Add(m_Specific(X), m_Value(Y)) && Y == Cmp1
        var y: i32 = -1;
        if op(fv, 0) == x { y = op(fv, 1); } else if op(fv, 1) == x { y = op(fv, 0); }
        if y >= 0 && y == c1 { return icb_binary_intrinsic(IID_uadd_sat, x, y, ""); }
    }
    if bo(fv, OP_ADD) {
        // m_c_Add(m_NotForbidPoison(m_Specific(X)), m_Specific(Y)) with X = Cmp0, Y = Cmp1
        if (sl_not_forbid_poison(op(fv, 0)) == c0 && op(fv, 1) == c1) || (sl_not_forbid_poison(op(fv, 1)) == c0 && op(fv, 0) == c1) {
            return icb_binary_intrinsic(IID_uadd_sat, op(fv, 0), op(fv, 1), "");
        }
    }
    if p == P_ULT && bo(c0, OP_ADD) {
        let y = sl_other_c(c0, c1);
        if y >= 0 && bo(fv, OP_ADD) && ((op(fv, 0) == c1 && op(fv, 1) == y) || (op(fv, 1) == c1 && op(fv, 0) == y)) {
            return icb_binary_intrinsic(IID_uadd_sat, c1, y, "");
        }
    }
    return -1;
}

// canonicalizeSaturatedAddSigned(Cmp, TVal, FVal, Builder)
fn canonicalize_saturated_add_signed(cmp: i32, tv0: i32, fv0: i32) -> i32 {
    var c0 = op(cmp, 0);
    var c1 = op(cmp, 1);
    var p = inst_pred(cmp);
    var tv = tv0;
    var fv = fv0;
    if m_cint_pred(fv, IP_MAXSIGNED, true) || m_sign_mask(fv) { let t = tv; tv = fv; fv = t; p = pred_inverse(p); }
    if !has_apint(tv) { return -1; }
    let satc = ap_c(tv);
    if !(ap_is_max_signed(satc) || ap_is_min_signed(satc)) { return -1; }
    let is_max = ap_is_max_signed(satc);
    if p == P_EQ && c1 == tv {
        if is_max && bo(fv, OP_ADD) && op(fv, 0) == c0 && m_one(op(fv, 1)) {
            return icb_binary_intrinsic(IID_sadd_sat, c0, c_int_ty(vals[c0].ty, 1), "");
        }
        if !is_max && bo(fv, OP_ADD) && op(fv, 0) == c0 && m_all_ones(op(fv, 1)) {
            return icb_binary_intrinsic(IID_sadd_sat, c0, c_all_ones(vals[c0].ty), "");
        }
        return -1;
    }
    if is_max && (p == P_SGT || p == P_SGE) && is_constant(c1) && bo(fv, OP_ADD) && op(fv, 0) == c0 &&
       sl_apint_pred(op(fv, 1), IP_STRICTLYPOS) {
        let c = ap_cp(op(fv, 1));
        if p == P_SGE {
            let ok, np, nc = icc_flipped_strictness(p, c1);
            if ok { p = np; c1 = nc; }
        }
        let thr = ap_sub(satc, c);
        if p == P_SGT && (sl_specific_int_poison(c1, thr) || sl_specific_int_poison(c1, ap_dec(thr))) {
            return icb_binary_intrinsic(IID_sadd_sat, c0, c_int_ap(vals[c0].ty, c), "");
        }
    }
    if !is_max && (p == P_SLT || p == P_SLE) && is_constant(c1) && bo(fv, OP_ADD) && op(fv, 0) == c0 &&
       sl_apint_pred(op(fv, 1), IP_NEGATIVE) {
        let c = ap_cp(op(fv, 1));
        if p == P_SLE {
            let ok, np, nc = icc_flipped_strictness(p, c1);
            if ok { p = np; c1 = nc; }
        }
        let thr = ap_sub(satc, c);
        if p == P_SLT && (sl_specific_int_poison(c1, thr) || sl_specific_int_poison(c1, ap_inc(thr))) {
            return icb_binary_intrinsic(IID_sadd_sat, c0, c_int_ap(vals[c0].ty, c), "");
        }
    }
    if p == P_SGT || p == P_SGE { let t = c0; c0 = c1; c1 = t; p = pred_swapped(p); }
    if p != P_SLT && p != P_SLE { return -1; }
    if is_max && bo(c0, OP_SUB) && op_nsw(c0) && m_specific_int_apv(op(c0, 0), satc) {
        let x = op(c0, 1);
        if bo(fv, OP_ADD) && ((op(fv, 0) == x && op(fv, 1) == c1) || (op(fv, 1) == x && op(fv, 0) == c1)) {
            return icb_binary_intrinsic(IID_sadd_sat, x, c1, "");
        }
    }
    if !is_max && bo(c1, OP_SUB) && op_nsw(c1) && m_specific_int_apv(op(c1, 0), satc) {
        let x = op(c1, 1);
        if bo(fv, OP_ADD) && ((op(fv, 0) == x && op(fv, 1) == c0) || (op(fv, 1) == x && op(fv, 0) == c0)) {
            return icb_binary_intrinsic(IID_sadd_sat, x, c0, "");
        }
    }
    return -1;
}

// canonicalizeSaturatedAdd(Cmp, TVal, FVal, Builder)
fn canonicalize_saturated_add(cmp: i32, tv: i32, fv: i32) -> i32 {
    if !has_one_use(cmp) { return -1; }
    let v = canonicalize_saturated_add_unsigned(cmp, tv, fv);
    if v >= 0 { return v; }
    return canonicalize_saturated_add_signed(cmp, tv, fv);
}

// foldAbsDiff(Cmp, TVal, FVal, Builder)
fn fold_abs_diff(cmp: i32, tv: i32, fv: i32) -> i32 {
    if !is_inst(tv) || !is_inst(fv) { return -1; }
    var ti = tv;
    var fi = fv;
    var p = sl_strict_pred(inst_pred(cmp));
    let a = op(cmp, 0);
    let b = op(cmp, 1);
    fn is_sub(v: i32, x: i32, y: i32) -> bool { bo(v, OP_SUB) && op(v, 0) == x && op(v, 1) == y }
    fn is_nsw_sub(v: i32, x: i32, y: i32) -> bool { bo(v, OP_SUB) && op_nsw(v) && op(v, 0) == x && op(v, 1) == y }
    if is_sub(fi, a, b) { let t = fi; fi = ti; ti = t; p = pred_swapped(p); }
    if p == P_SGT && is_sub(ti, a, b) && is_sub(fi, b, a) && (op_nsw(ti) || op_nuw(ti)) && (op_nsw(fi) || op_nuw(fi)) {
        set_nuw(ti, false);
        if !op_nsw(ti) { set_nsw(ti, has_one_use(ti)); }
        return icb_binary_intrinsic(IID_abs, ti, c_bool_ty(T_I1, true), "");
    }
    if p == P_SGT && is_nsw_sub(ti, a, b) && m_neg(fi) == ti {
        return icb_binary_intrinsic(IID_abs, ti, c_bool_ty(T_I1, false), "");
    }
    if p == P_SLT && is_nsw_sub(fi, a, b) && m_neg(ti) == fi {
        return icb_binary_intrinsic(IID_abs, fi, c_bool_ty(T_I1, false), "");
    }
    if p == P_SGT && is_nsw_sub(fi, b, a) && m_neg(ti) == fi {
        return icb_binary_intrinsic(IID_abs, fi, c_bool_ty(T_I1, false), "");
    }
    if p == P_SLT && is_nsw_sub(ti, b, a) && m_neg(fi) == ti {
        return icb_binary_intrinsic(IID_abs, ti, c_bool_ty(T_I1, false), "");
    }
    return -1;
}

// foldSelectCtlzToCttz(ICI, TrueVal, FalseVal, Builder)
fn fold_select_ctlz_to_cttz(ici: i32, tv0: i32, fv0: i32) -> i32 {
    let bw = ty_sbits(tv0);
    let p = inst_pred(ici);
    if (p != P_EQ && p != P_NE) || !m_zero(op(ici, 1)) { return -1; }
    var tv = tv0;
    var fv = fv0;
    if p == P_NE { let t = tv; tv = fv; fv = t; }
    var ctlz: i32 = -1;
    if bo(fv, OP_XOR) && m_specific_int_ap(op(fv, 1), (bw - 1) as u64) {
        ctlz = op(fv, 0);
        if (bw & (bw - 1)) != 0 { return -1; }
    } else if bo(fv, OP_SUB) && m_specific_int_ap(op(fv, 0), (bw - 1) as u64) {
        ctlz = op(fv, 1);
    } else { return -1; }
    if inst_iid(ctlz) != IID_ctlz { return -1; }
    if !m_specific_int(tv, bw as u64) { return -1; }
    let x = op(ici, 0);
    let a = op(ctlz, 0);
    if !bo(a, OP_AND) { return -1; }
    if !((op(a, 0) == x && m_neg(op(a, 1)) == x) || (op(a, 1) == x && m_neg(op(a, 0)) == x)) { return -1; }
    let fls = c_bool_ty(T_I1, false);
    let cty: i32 = vals[ctlz].ty;
    return ic_new_intrinsic(IID_cttz, [cty], [x, fls]);
}

// foldSelectCttzCtlz(ICI, TrueVal, FalseVal, IC)
fn fold_select_cttz_ctlz(ici: i32, tv: i32, fv: i32) -> i32 {
    let p = inst_pred(ici);
    let l = op(ici, 0);
    let r = op(ici, 1);
    if p != P_EQ && p != P_NE { return -1; }
    var sel_arg = fv;
    var on_zero = tv;
    if p == P_NE { sel_arg = tv; on_zero = fv; }
    var count = m_zext(sel_arg);
    if count < 0 { count = m_trunc(sel_arg); }
    if count < 0 { count = sel_arg; }
    let cid = inst_iid(count);
    if cid != IID_cttz && cid != IID_ctlz { return -1; }
    let x = op(count, 0);
    if (x != l || !m_zero(r)) && (m_not(x) != l || !m_all_ones(r)) &&
       !(bo(x, OP_XOR) && ((op(x, 0) == l && op(x, 1) == r) || (op(x, 0) == r && op(x, 1) == l))) { return -1; }
    let ii = count;
    let sz = ty_sbits(count);
    if m_specific_int(on_zero, sz as u64) {
        drop_poison_generating_annotations(ii);
        icw_push(ii);
        return sel_arg;
    }
    if has_one_use(ii) && has_one_use(sel_arg) && !m_one(op(ii, 1)) {
        set_op(ii, 1, c_bool_ty(T_I1, true));
        cu_drop_ub_implying_attrs_and_metadata(ii);
        icw_push(ii);
    }
    return -1;
}

// dropPoisonGeneratingAnnotationsForSPFCanonicalization(Cond, LHS, RHS)
fn drop_poison_generating_annotations_for_spf(cond: i32, l: i32, r: i32) {
    if !implies_poison(l, cond) { if is_inst(l) { drop_poison_generating_annotations(l); } }
    if !implies_poison(r, cond) { if is_inst(r) { drop_poison_generating_annotations(r); } }
}

// getMinMaxIntrinsic(SPF)
fn spf_minmax_intrinsic(f: i64) -> i64 {
    if f == SPF_UMIN { return IID_umin; }
    if f == SPF_UMAX { return IID_umax; }
    if f == SPF_SMIN { return IID_smin; }
    if f == SPF_SMAX { return IID_smax; }
    if f == SPF_FMINNUM { return IID_minnum; }
    return IID_maxnum;
}

// canonicalizeSPF(Cmp, TrueVal, FalseVal, IC)
fn canonicalize_spf(cmp: i32, tv: i32, fv: i32) -> i32 {
    if !is_int_or_int_vec(vals[tv].ty) { return -1; }
    let p = inst_pred(cmp);
    if p == P_EQ || p == P_NE { return -1; }
    let spf = match_select_pattern_int(p, op(cmp, 0), op(cmp, 1), tv, fv, 0);
    let l = sp_lhs;
    let r = sp_rhs;
    if spf == SPF_ABS || spf == SPF_NABS {
        if !has_one_use(cmp) && !has_one_use(r) { return -1; }
        let imp = spf == SPF_ABS && bo(r, OP_SUB) && op_nsw(r) && m_zero_int(op(r, 0)) && op(r, 1) == l;
        let a = icb_binary_intrinsic(IID_abs, l, c_bool_ty(T_I1, imp), "");
        if spf == SPF_NABS { return icb_neg(a, "", false); }
        return a;
    }
    if spf_is_minmax(spf) {
        let id = spf_minmax_intrinsic(spf);
        drop_poison_generating_annotations_for_spf(cmp, l, r);
        return icb_binary_intrinsic(id, l, r, "");
    }
    return -1;
}

// isSafeToSpeculativelyExecuteWithVariableReplaced(I)
fn sl_safe_spec_var_replaced(i: i32) -> bool {
    if iop(i) == OP_LOAD { return false; }
    return spec_safe_opc(iop(i), i, -1, false, true);
}

// InstCombinerImpl::replaceInInstruction(V, Old, New, Depth)
recursive fn replace_in_instruction(v: i32, old: i32, nw: i32, depth: i64) -> bool {
    if depth == 2 { return false; }
    if !is_inst(v) || !has_one_use(v) || !sl_safe_spec_var_replaced(v) { return false; }
    if ty_is_vector(vals[old].ty) && !is_not_cross_lane(v) { return false; }
    var changed = false;
    for k in nops(v) {
        let u = vals[v].ops + k as i32;
        if uses[u].val == old {
            ic_replace_use(u, nw);
            icw_add(v);
            changed = true;
        } else {
            if replace_in_instruction(uses[u].val, old, nw, depth + 1) { changed = true; }
        }
    }
    return changed;
}

// CmpInst::isEquivalence(Invert)
fn sl_cmp_is_equivalence(c: i32, invert: bool) -> bool {
    if iop(c) == OP_ICMP { return inst_pred(c) == (if invert { P_NE } else { P_EQ }); }
    return fcmp_is_equivalence(c, invert);
}

// InstCombinerImpl::foldSelectValueEquivalence(Sel, Cmp)
fn fold_select_value_equivalence(sel: i32, cmp: i32) -> i32 {
    var tv = op(sel, 1);
    var fv = op(sel, 2);
    var swapped = false;
    if sl_cmp_is_equivalence(cmp, true) { let t = tv; tv = fv; fv = t; swapped = true; }
    else if !sl_cmp_is_equivalence(cmp, false) { return -1; }
    let l = op(cmp, 0);
    let r = op(cmp, 1);
    let can_lr = can_replace_pointers_if_equal(l, r);
    if can_lr {
        let x = sl_replace_old_op_with_new_op(sel, tv, swapped, l, l, r);
        if x >= 0 { return x; }
    }
    let can_rl = can_replace_pointers_if_equal(r, l);
    if can_rl {
        let x = sl_replace_old_op_with_new_op(sel, tv, swapped, l, r, l);
        if x >= 0 { return x; }
    }
    if !is_inst(fv) { return -1; }
    swo_drop.resize(0);
    swo_drop_on = true;
    var ok = false;
    if can_lr && simplify_with_op_replaced_api(fv, l, r, -1, false) == tv { ok = true; }
    if !ok && can_rl && simplify_with_op_replaced_api(fv, r, l, -1, false) == tv { ok = true; }
    swo_drop_on = false;
    if ok {
        var drops: i32[>..<] = [];
        for x in swo_drop { drops.push(x); }
        swo_drop.resize(0);
        for x in drops {
            drop_poison_generating_annotations(x);
            icw_add(x);
        }
        return ic_replace_inst_uses_with(sel, fv);
    }
    swo_drop.resize(0);
    if is_int_ty1(vals[fv].ty) && is_inst_op(fv, OP_TRUNC) && op_nuw(fv) && op(fv, 0) == l && is_imm_c(r) {
        let z = c_null(vals[l].ty);
        if cf_fold_cmp_operands(P_NE, r, z, -1) == tv {
            return ic_new_icmp(P_NE, l, z);
        }
    }
    return -1;
}
// the ReplaceOldOpWithNewOp lambda of foldSelectValueEquivalence
fn sl_replace_old_op_with_new_op(sel: i32, tv: i32, swapped: bool, cmp_lhs: i32, old: i32, nw: i32) -> i32 {
    if tv == old && (is_constant(old) || !is_constant(nw)) { return -1; }
    let v = simplify_with_op_replaced(tv, old, nw, sq_new(-1), true, RECURSION_LIMIT);
    if v >= 0 {
        if is_imm_c(v) && is_guaranteed_not_to_be_undef(v, sel, 0) {
            return ic_replace_operand(sel, if swapped { 2 } else { 1 }, v);
        }
        var contained = false;
        if is_inst(tv) { for k in nops(tv) { if op(tv, k) == v { contained = true; } } }
        if is_imm_c(nw) || contained {
            if is_guaranteed_not_to_be_undef(nw, sel, 0) {
                return ic_replace_operand(sel, if swapped { 2 } else { 1 }, v);
            }
            return -1;
        }
    }
    if old == cmp_lhs && is_imm_c(nw) && !is_constant(old) && is_guaranteed_not_to_be_undef(nw, sel, 0) {
        if replace_in_instruction(tv, old, nw, 0) { return sel; }
    }
    return -1;
}

// InstCombinerImpl::foldSelectEqualityTest(Sel)
fn fold_select_equality_test(sel: i32) -> i32 {
    let xeqz = op(sel, 0);
    let yeqz = op(sel, 1);
    if !is_inst_op(xeqz, OP_ICMP) || inst_pred(xeqz) != P_EQ { return -1; }
    var x = op(xeqz, 0);
    var z = op(xeqz, 1);
    fn eq_with(v: i32, z: i32) -> i32 {
        if !is_inst_op(v, OP_ICMP) || inst_pred(v) != P_EQ { return -1; }
        if op(v, 1) == z { return op(v, 0); }
        if op(v, 0) == z { return op(v, 1); }
        return -1;
    }
    var y = eq_with(yeqz, z);
    if y < 0 { let t = x; x = z; z = t; }
    y = eq_with(yeqz, z);
    if y < 0 { return -1; }
    let f = op(sel, 2);
    if !m_logical(f, true) { return -1; }
    var xeqy: i32 = -1;
    if m_not(lg_a) == yeqz { xeqy = lg_b; }
    else if m_not(lg_b) == yeqz { xeqy = lg_a; }
    else { return -1; }
    if !is_inst_op(xeqy, OP_ICMP) || inst_pred(xeqy) != P_EQ { return -1; }
    if !((op(xeqy, 0) == x && op(xeqy, 1) == y) || (op(xeqy, 0) == y && op(xeqy, 1) == x)) { return -1; }
    insts[inst_of(xeqy)].flags &= ~FL_SAMESIGN;
    return ic_replace_inst_uses_with(sel, xeqy);
}

// m_AnyIntegralConstant: cst_pred_ty<is_any_apint> (scalar ConstantInt, splat, or fixed vector of ConstantInt
// and poison lanes with at least one ConstantInt)
fn sl_any_int_const(v: i32) -> bool {
    if v < 0 { return false; }
    let k = vals[v].kind;
    let ty = vals[v].ty;
    if k == VK_CINT { return true; }
    if !ty_is_vector(ty) || !is_constant(v) { return false; }
    let s = splat_value(v, false);
    if s >= 0 { if vals[s].kind == VK_CINT { return true; } }
    if ty_kind(ty) != TK_FVEC { return false; }
    var has = false;
    for i in ty_count(ty) {
        let e = agg_elem(v, i);
        if e < 0 { return false; }
        if vals[e].kind == VK_POISON { continue; }
        if vals[e].kind != VK_CINT { return false; }
        has = true;
    }
    return has;
}
// Constant::isElementWiseEqual(Y)
fn sl_is_element_wise_equal(c: i32, y: i32) -> bool {
    if c == y { return true; }
    let vty = vals[c].ty;
    if !is_constant(y) || !ty_is_vector(vty) || vty != vals[y].ty { return false; }
    let et = ty_elem(vty);
    if !ty_is_int(et) && !ty_is_fp(et) { return false; }
    var c0 = c;
    var c1 = y;
    if ty_is_fp(et) {
        let ity = ty_vec_integer(vty);
        c0 = ce_cast(OP_BITCAST, c, ity);
        c1 = ce_cast(OP_BITCAST, y, ity);
    }
    let eq = cf_fold_cmp_operands(P_EQ, c0, c1, -1);
    return eq >= 0 && (vals[eq].kind == VK_POISON || m_one(eq));
}
// CmpInst::getFlippedStrictnessPredicate
fn sl_flipped_strictness_pred(p: i64) -> i64 {
    match p { 34 => 35, 35 => 34, 36 => 37, 37 => 36, 38 => 39, 39 => 38, 40 => 41, 41 => 40, _ => p }
}

// canonicalizeClampLike(Sel0, Cmp0, Builder, IC)
fn canonicalize_clamp_like(sel0: i32, cmp0: i32) -> i32 {
    var x = op(sel0, 1);
    var sel1 = op(sel0, 2);
    if !has_one_use(cmp0) { return -1; }
    var p0 = inst_pred(cmp0);
    let cmp00 = op(cmp0, 0);
    var c0 = op(cmp0, 1);
    if !sl_any_int_const(c0) { return -1; }
    if !is_select_inst(sel1) { p0 = pred_inverse(p0); let t = x; x = sel1; sel1 = t; }
    let w0 = ty_sbits(c0);
    if p0 == P_ULT || p0 == P_UGE {
        if !ao_specific_int_icmp(c0, P_NE, ap_zero(w0)) { return -1; }
    } else if p0 == P_ULE || p0 == P_UGT {
        if !ao_specific_int_icmp(c0, P_NE, ap_ones(w0)) { return -1; }
        p0 = sl_flipped_strictness_pred(p0);
        c0 = add_one(c0);
    } else { return -1; }
    if !has_one_use(sel1) { return -1; }
    if vals[cmp00].ty != vals[x].ty && has_one_use(x) {
        let t = m_trunc(x);
        if t >= 0 { x = t; }
    }
    var c1: i32 = -1;
    if cmp00 == x { c1 = c_null(vals[x].ty); }
    else if bo(cmp00, OP_ADD) && op(cmp00, 0) == x && sl_any_int_const(op(cmp00, 1)) { c1 = op(cmp00, 1); }
    else { return -1; }
    if !is_select_inst(sel1) { return -1; }
    let cmp1 = op(sel1, 0);
    var rlow = op(sel1, 1);
    var rhigh = op(sel1, 2);
    if !is_inst_op(cmp1, OP_ICMP) || op(cmp1, 0) != x || !sl_any_int_const(op(cmp1, 1)) { return -1; }
    var c2 = op(cmp1, 1);
    let p1 = inst_pred(cmp1);
    if !has_one_use(cmp1) && (cmp00 == x || !has_one_use(cmp00)) { return -1; }
    if p1 == P_SLT {
    } else if p1 == P_SLE {
        return -1;
    } else if p1 == P_SGT || p1 == P_SGE {
        if p1 == P_SGT {
            if !ao_specific_int_icmp(c2, P_NE, ap_smax_val(ty_sbits(c2))) { return -1; }
            c2 = add_one(c2);
        }
        let t = rlow; rlow = rhigh; rhigh = t;
    } else { return -1; }
    var low = ce_binop(OP_SUB, c_null(vals[c1].ty), c1, 0);
    var high = ce_binop(OP_SUB, c0, c1, 0);
    if p0 == P_UGE { let t = low; low = high; high = t; }
    let pc1 = cf_fold_cmp_operands(P_SGE, c2, low, -1);
    if pc1 < 0 || !m_one(pc1) { return -1; }
    let pc2 = cf_fold_cmp_operands(P_SLE, c2, high, -1);
    if pc2 < 0 || !m_one(pc2) { return -1; }
    if vals[x].ty != vals[sel0].ty {
        if !is_imm_c(rlow) || !is_imm_c(rhigh) { return -1; }
        rlow = cf_fold_cast_operand(OP_SEXT, rlow, vals[x].ty);
        rhigh = cf_fold_cast_operand(OP_SEXT, rhigh, vals[x].ty);
    }
    let srl = icb_icmp(P_SLT, x, low, "");
    let srh = icb_icmp(P_SGE, x, high, "");
    let mrl = icb_select(srl, rlow, x, "", -1);
    let mrh = icb_select(srh, rhigh, mrl, "", -1);
    return icb_trunc(mrh, vals[sel0].ty, "");
}

// tryToReuseConstantFromSelectInComparison(Sel, Cmp, IC)
fn try_to_reuse_constant_from_select_in_comparison(sel: i32, cmp: i32) -> i32 {
    if !one_use(cmp) || !is_inst_op(cmp, OP_ICMP) { return -1; }
    let x = op(cmp, 0);
    let c0 = op(cmp, 1);
    if !sl_any_int_const(c0) { return -1; }
    let p = inst_pred(cmp);
    if p == P_EQ || p == P_NE { return -1; }
    if !is_canonical_predicate(p) { return -1; }
    if vals[c0].ty != vals[sel].ty { return -1; }
    if p == P_ULT && bo(x, OP_ADD) && is_constant(op(x, 1)) { return -1; }
    let s0 = op(sel, 1);
    let s1 = op(sel, 2);
    if !sl_any_int_const(s0) && !sl_any_int_const(s1) { return -1; }
    if sl_is_element_wise_equal(c0, s0) || sl_is_element_wise_equal(c0, s1) { return -1; }
    let ok, fp, fc = icc_flipped_strictness(p, c0);
    if !ok { return -1; }
    if !(sl_is_element_wise_equal(fc, s0) || sl_is_element_wise_equal(fc, s1)) { return -1; }
    let sp = icb_pos; let sb = icb_bb; let sd = icb_dl;
    icb_set_insert_point(sel);
    let np = pred_swapped(p);
    let nc = icb_icmp(np, x, fc, sl_name(cmp, ".inv"));
    icb_pos = sp; icb_bb = sb; icb_dl = sd;
    ic_replace_operand(sel, 0, nc);
    cu_use_swap(vals[sel].ops + 1, vals[sel].ops + 2);
    cu_swap_prof_metadata(sel);
    return sel;
}

// foldSelectZeroOrOnes(Cmp, TVal, FVal, Builder)
fn fold_select_zero_or_ones(cmp: i32, tv: i32, fv: i32) -> i32 {
    if !has_one_use(cmp) { return -1; }
    if !has_apint_poison(op(cmp, 1)) { return -1; }
    let c = ap_cp(op(cmp, 1));
    let x = op(cmp, 0);
    let p = inst_pred(cmp);
    if p == P_ULT && ap_eq_u64(c, 2) && m_neg(tv) == x && m_all_ones(fv) {
        return ic_new_cast(OP_SEXT, icb_is_not_null(x, ""), vals[tv].ty);
    }
    if p == P_UGT && ap_eq_u64(c, 1) && m_neg(fv) == x && m_all_ones(tv) {
        return ic_new_cast(OP_SEXT, icb_is_not_null(x, ""), vals[tv].ty);
    }
    return -1;
}

// foldSelectInstWithICmpConst(SI, ICI, Builder)
fn fold_select_inst_with_icmp_const(si: i32, ici: i32) -> i32 {
    if !has_apint(op(ici, 1)) { return -1; }
    let cc = ap_c(op(ici, 1));
    let v = op(ici, 0);
    let p = inst_pred(ici);
    let tv = op(si, 1);
    let fv = op(si, 2);
    if p == P_EQ && v == fv {
        if ap_is_zero(cc) && m_specific_int_apv(tv, ap_inc(cc)) { return icb_binary_intrinsic(IID_umax, v, tv, ""); }
        if ap_is_all_ones(cc) && m_specific_int_apv(tv, ap_dec(cc)) { return icb_binary_intrinsic(IID_umin, v, tv, ""); }
        if ap_is_min_signed(cc) && m_specific_int_apv(tv, ap_inc(cc)) { return icb_binary_intrinsic(IID_smax, v, tv, ""); }
        if ap_is_max_signed(cc) && m_specific_int_apv(tv, ap_dec(cc)) { return icb_binary_intrinsic(IID_smin, v, tv, ""); }
    }
    var opi: i32 = -1;
    var c: AP = cc;
    var cpred: i64 = 0;
    if has_apint(tv) && is_inst(fv) { opi = fv; c = ap_c(tv); cpred = p; }
    else if is_inst(tv) && has_apint(fv) { opi = tv; c = ap_c(fv); cpred = pred_inverse(p); }
    else { return -1; }
    let inv = rg_exact_icmp(cpred, cc);
    if is_binop_inst(opi) && op(opi, 0) == v && has_apint(op(opi, 1)) {
        let r = rg_binop(iop(opi), inv, rg_single(ap_c(op(opi, 1))));
        if rg_eq(r, rg_single(c)) {
            drop_poison_generating_flags(opi);
            return opi;
        }
    }
    let id = inst_iid(opi);
    if is_minmax_iid(id) && op(opi, 0) == v && has_apint(op(opi, 1)) {
        let oc = rg_single(ap_c(op(opi, 1)));
        var r = inv;
        if id == IID_smax { r = rg_smax_op(inv, oc); }
        else if id == IID_smin { r = rg_smin_op(inv, oc); }
        else if id == IID_umax { r = rg_umax_op(inv, oc); }
        else { r = rg_umin_op(inv, oc); }
        if rg_eq(r, rg_single(c)) {
            drop_poison_generating_annotations(opi);
            return opi;
        }
    }
    return -1;
}

// foldSelectWithExtremeEqCond(CmpLHS, CmpRHS, TrueVal, FalseVal)
fn fold_select_with_extreme_eq_cond(l: i32, r: i32, tv: i32, fv: i32) -> i32 {
    let ty = vals[l].ty;
    if is_ptr_or_ptr_vec(ty) { return -1; }
    if !is_inst_op(fv, OP_ICMP) { return -1; }
    var p: i64 = 0;
    var b: i32 = -1;
    if op(fv, 0) == l { b = op(fv, 1); p = inst_pred(fv); }
    else if op(fv, 1) == l { b = op(fv, 0); p = pred_swapped(inst_pred(fv)); }
    else { return -1; }
    if !is_inst_op(tv, OP_ICMP) || inst_pred(tv) != P_NE || op(tv, 0) != b { return -1; }
    let trhs = op(tv, 1);
    let w = ty_scalar_bits(ty);
    var c = ap_zero(w);
    if sl_is_lt(p) { c = if icmp_is_signed(p) { ap_smin_val(w) } else { ap_zero(w) }; }
    else if sl_is_gt(p) { c = if icmp_is_signed(p) { ap_smax_val(w) } else { ap_ones(w) }; }
    else { return -1; }
    if !m_specific_int_apv(r, c) || !m_specific_int_apv(trhs, c) { return -1; }
    return ic_new_icmp(p, l, b);
}

// foldSelectICmpEq(SI, ICI, IC)
fn fold_select_icmp_eq(si: i32, ici: i32) -> i32 {
    let p = inst_pred(ici);
    if p != P_EQ && p != P_NE { return -1; }
    var tv = op(si, 1);
    var fv = op(si, 2);
    if p == P_NE { let t = tv; tv = fv; fv = t; }
    return fold_select_with_extreme_eq_cond(op(ici, 0), op(ici, 1), tv, fv);
}

// getSelectPattern(Pred).Flavor for integer predicates
fn sl_select_pattern_of_pred(p: i64) -> i64 {
    if p == P_UGT || p == P_UGE { return SPF_UMAX; }
    if p == P_ULT || p == P_ULE { return SPF_UMIN; }
    if p == P_SGT || p == P_SGE { return SPF_SMAX; }
    if p == P_SLT || p == P_SLE { return SPF_SMIN; }
    return SPF_UNKNOWN;
}

// InstCombinerImpl::foldSelectWithConstOpToBinOp(Cmp, TrueVal, FalseVal)
fn fold_select_with_const_op_to_binop(cmp: i32, tv0: i32, fv0: i32) -> i32 {
    if !is_inst_op(cmp, OP_ICMP) || !is_constant(op(cmp, 1)) { return -1; }
    let x = op(cmp, 0);
    let c1 = op(cmp, 1);
    var p = inst_pred(cmp);
    if p == P_EQ || p == P_NE { return -1; }
    var tv = tv0;
    var fv = fv0;
    if is_constant(tv) { let t = fv; fv = tv; tv = t; p = pred_inverse(p); }
    if !is_constant(fv) || !has_one_use(tv) { return -1; }
    let c3 = fv;
    var is_intr = false;
    var opc: i64 = 0;
    var c2: i32 = -1;
    if is_binop_inst(tv) {
        opc = iop(tv);
        if sl_is_int_div_rem(opc) { return -1; }
        if op(tv, 0) != x || !is_constant(op(tv, 1)) { return -1; }
        c2 = op(tv, 1);
    } else if inst_iid(tv) != 0 {
        let id = inst_iid(tv);
        if !is_minmax_iid(id) || op(tv, 0) != x || !is_constant(op(tv, 1)) { return -1; }
        c2 = op(tv, 1);
        opc = id;
        is_intr = true;
    } else { return -1; }
    let fok, fpred, fconst = icc_flipped_strictness(p, c1);
    var spf = SPF_UNKNOWN;
    var rhs: i32 = -1;
    if c3 == sl_fold_binop_or_intrinsic(is_intr, opc, c1, c2) {
        spf = sl_select_pattern_of_pred(p);
        rhs = c1;
    } else if fok && c3 == sl_fold_binop_or_intrinsic(is_intr, opc, fconst, c2) {
        spf = sl_select_pattern_of_pred(fpred);
        rhs = fconst;
    } else { return -1; }
    let mmid = spf_minmax_intrinsic(spf);
    let mm = icb_binary_intrinsic(mmid, x, rhs, "");
    if is_intr { return icb_binary_intrinsic(opc, mm, c2, ""); }
    let b = icb_binop(opc, mm, c2, "");
    if is_inst(b) {
        if opc == OP_ADD || opc == OP_SUB || opc == OP_MUL {
            if op_nsw(tv) && will_not_overflow(opc, rhs, c2, b, true) { set_nsw(b, true); }
            if op_nuw(tv) && will_not_overflow(opc, rhs, c2, b, false) { set_nuw(b, true); }
        }
    }
    return b;
}
fn sl_fold_binop_or_intrinsic(is_intr: bool, opc: i64, l: i32, r: i32) -> i32 {
    if is_intr { return tf_intrinsic(opc, [l, r], vals[l].ty); }
    return cf_fold_binop_operands(opc, l, r);
}

// foldICmpUSubSatWithAndForMostSignificantBitCmp(SI, ICI, Builder)
fn fold_icmp_usub_sat_with_and_for_msb_cmp(si: i32, ici: i32) -> i32 {
    if !has_one_use(si) || !has_one_use(ici) { return -1; }
    let c = op(si, 0);
    if !is_inst_op(c, OP_ICMP) || !m_zero(op(c, 1)) { return -1; }
    let o = op(c, 0);
    if !one_use(o) || !bo(o, OP_OR) { return -1; }
    let a0 = op(o, 0);
    let b0 = op(o, 1);
    if !one_use(a0) || inst_iid(a0) != IID_usub_sat || !has_apint(op(a0, 1)) { return -1; }
    if !one_use(b0) || inst_iid(b0) != IID_usub_sat || !has_apint(op(b0, 1)) { return -1; }
    let a = op(a0, 0);
    let b = op(b0, 0);
    let k1 = ap_c(op(a0, 1));
    let k2 = ap_c(op(b0, 1));
    let p = inst_pred(c);
    let tv = op(si, 1);
    let fv = op(si, 2);
    if !((p == P_EQ && m_zero(tv) && m_sign_mask(fv)) || (p == P_NE && m_sign_mask(tv) && m_zero(fv))) { return -1; }
    let ty = vals[a].ty;
    let bw = k1.w as i64;
    let msb = ap_sign_mask(bw);
    if ap_is_nonneg(k1) || ap_is_nonneg(k2) { return -1; }
    let adj1 = ap_inc(ap_sub(k1, msb));
    let adj2 = ap_inc(ap_sub(k2, msb));
    let na = icb_binary_intrinsic(IID_usub_sat, a, c_int_ap(ty, adj1), "");
    let nb = icb_binary_intrinsic(IID_usub_sat, b, c_int_ap(ty, adj2), "");
    let or = icb_or(na, nb, "");
    return ic_new_binop(OP_AND, or, c_int_ap(ty, msb));
}

// InstCombinerImpl::foldSelectInstWithICmp(SI, ICI)
fn fold_select_inst_with_icmp(si: i32, ici: i32) -> i32 {
    var v = canonicalize_spf(ici, op(si, 1), op(si, 2));
    if v >= 0 { return ic_replace_inst_uses_with(si, v); }
    v = fold_select_inst_with_icmp_const(si, ici);
    if v >= 0 { return ic_replace_inst_uses_with(si, v); }
    v = canonicalize_clamp_like(si, ici);
    if v >= 0 { return ic_replace_inst_uses_with(si, v); }
    var r = try_to_reuse_constant_from_select_in_comparison(si, ici);
    if r >= 0 { return r; }
    r = fold_icmp_usub_sat_with_and_for_msb_cmp(si, ici);
    if r >= 0 { return r; }
    let tv = op(si, 1);
    let fv = op(si, 2);
    let p = inst_pred(ici);
    let l = op(ici, 0);
    let rr = op(ici, 1);
    r = fold_select_icmp_eq(si, ici);
    if r >= 0 { return r; }
    if p == P_SGT && m_all_ones(rr) && !is_constant(tv) && !is_constant(fv) && has_one_use(ici) {
        let sp = icb_pos; let sb = icb_bb; let sd = icb_dl;
        icb_set_insert_point(si);
        let isneg = icb_icmp(P_SLT, l, c_null(vals[l].ty), sl_name(ici, ""));
        icb_pos = sp; icb_bb = sb; icb_dl = sd;
        ic_replace_operand(si, 0, isneg);
        cu_use_swap(vals[si].ops + 1, vals[si].ops + 2);
        cu_swap_prof_metadata(si);
        return si;
    }
    v = fold_select_icmp_min_max(ici, tv, fv, -1);
    if v >= 0 { return ic_replace_inst_uses_with(si, v); }
    r = fold_select_icmp_and_and(vals[si].ty, ici, tv, fv);
    if r >= 0 { return r; }
    v = fold_select_icmp_and_zero_shl(ici, tv, fv);
    if v >= 0 { return ic_replace_inst_uses_with(si, v); }
    r = fold_select_ctlz_to_cttz(ici, tv, fv);
    if r >= 0 { return r; }
    r = fold_select_zero_or_ones(ici, tv, fv);
    if r >= 0 { return r; }
    v = fold_select_icmp_lshr_ashr(ici, tv, fv);
    if v >= 0 { return ic_replace_inst_uses_with(si, v); }
    v = fold_select_cttz_ctlz(ici, tv, fv);
    if v >= 0 { return ic_replace_inst_uses_with(si, v); }
    v = canonicalize_saturated_subtract(ici, tv, fv);
    if v >= 0 { return ic_replace_inst_uses_with(si, v); }
    v = canonicalize_saturated_add(ici, tv, fv);
    if v >= 0 { return ic_replace_inst_uses_with(si, v); }
    v = fold_abs_diff(ici, tv, fv);
    if v >= 0 { return ic_replace_inst_uses_with(si, v); }
    v = fold_select_with_const_op_to_binop(ici, tv, fv);
    if v >= 0 { return ic_replace_inst_uses_with(si, v); }
    return -1;
}

// InstCombinerImpl::foldSPFofSPF(Inner, SPF1, A, B, Outer, SPF2, C)
fn fold_spf_of_spf(inner: i32, spf1: i64, a: i32, b: i32, outer: i32, spf2: i64, c: i32) -> i32 {
    if vals[outer].ty != vals[inner].ty { return -1; }
    if c == a || c == b {
        if spf1 == spf2 && spf_is_minmax(spf1) { return ic_replace_inst_uses_with(outer, inner); }
    }
    return -1;
}

// foldAddSubSelect(SI, Builder)
fn fold_add_sub_select(si: i32) -> i32 {
    let condv = op(si, 0);
    let ti = op(si, 1);
    let fi = op(si, 2);
    if !is_inst(ti) || !is_inst(fi) || !has_one_use(ti) || !has_one_use(fi) { return -1; }
    var addop: i32 = -1;
    var subop: i32 = -1;
    let to = iop(ti);
    let fo = iop(fi);
    if (to == OP_SUB && fo == OP_ADD) || (to == OP_FSUB && fo == OP_FADD) { addop = fi; subop = ti; }
    else if (fo == OP_SUB && to == OP_ADD) || (fo == OP_FSUB && to == OP_FADD) { addop = ti; subop = fi; }
    if addop < 0 { return -1; }
    var other: i32 = -1;
    if op(subop, 0) == op(addop, 0) { other = op(addop, 1); }
    else if op(subop, 0) == op(addop, 1) { other = op(addop, 0); }
    if other < 0 { return -1; }
    let is_fp = is_fp_or_fp_vec(vals[si].ty);
    var negv: i32 = -1;
    if is_fp {
        negv = ao_fneg(op(subop, 1));
        if is_inst(negv) { sl_set_fmf(negv, sl_fmf(addop) & sl_fmf(subop)); }
    } else {
        negv = icb_neg(op(subop, 1), "", false);
    }
    var nt = other;
    var nf = negv;
    if addop != ti { let t = nt; nt = nf; nf = t; }
    let ns = icb_select(condv, nt, nf, sl_name(si, ".p"), si);
    if is_fp {
        let ri = ic_new_binop(OP_FADD, op(subop, 0), ns);
        sl_set_fmf(ri, sl_fmf(addop) & sl_fmf(subop));
        return ri;
    }
    return ic_new_binop(OP_ADD, op(subop, 0), ns);
}

// foldOverflowingAddSubSelect(SI, Builder)
fn fold_overflowing_add_sub_select(si: i32) -> i32 {
    let condv = op(si, 0);
    let tv = op(si, 1);
    let fv = op(si, 2);
    if icc_ev_index(condv) != 1 { return -1; }
    let ii = op(condv, 0);
    let id = inst_iid(ii);
    if !(id == IID_uadd_with_overflow || id == IID_sadd_with_overflow || id == IID_usub_with_overflow ||
         id == IID_ssub_with_overflow || id == IID_umul_with_overflow || id == IID_smul_with_overflow) { return -1; }
    if icc_ev_index(fv) != 0 || op(fv, 0) != ii { return -1; }
    let x = op(ii, 0);
    let y = op(ii, 1);
    var nid: i64 = 0;
    if id == IID_uadd_with_overflow && m_all_ones(tv) { nid = IID_uadd_sat; }
    else if id == IID_usub_with_overflow && m_zero(tv) { nid = IID_usub_sat; }
    else if id == IID_sadd_with_overflow && sl_is_signed_saturate_limit(tv, true, x, y) { nid = IID_sadd_sat; }
    else if id == IID_ssub_with_overflow && sl_is_signed_saturate_limit(tv, false, x, y) { nid = IID_ssub_sat; }
    else { return -1; }
    return ic_new_intrinsic(nid, [vals[si].ty as i32], [x, y]);
}
// the IsSignedSaturateLimit lambda
fn sl_is_signed_saturate_limit(limit: i32, is_add: bool, x: i32, y: i32) -> bool {
    let ty = vals[limit].ty;
    if !is_select_inst(limit) { return false; }
    let c0 = op(limit, 0);
    if !is_inst_op(c0, OP_ICMP) || !has_apint(op(c0, 1)) { return false; }
    let p = inst_pred(c0);
    let opv = op(c0, 0);
    let c = ap_c(op(c0, 1));
    let t = op(limit, 1);
    let f = op(limit, 2);
    fn zo(a: AP) -> bool { ap_is_zero(a) || ap_is_one(a) }
    let w = ty_scalar_bits(ty);
    fn minmax(mn: i32, mx: i32, w: i64) -> bool { m_specific_int_apv(mn, ap_smin_val(w)) && m_specific_int_apv(mx, ap_smax_val(w)) }
    if opv != x && opv != y { return false; }
    if is_add {
        if p == P_SLT && zo(c) && minmax(t, f, w) { return true; }
        if p == P_SGT && zo(ap_inc(c)) && minmax(f, t, w) { return true; }
    } else {
        if opv == x && p == P_SLT && zo(ap_inc(c)) && minmax(t, f, w) { return true; }
        if opv == x && p == P_SGT && zo(ap_add(c, ap_u64(2, c.w as i64))) && minmax(f, t, w) { return true; }
        if opv == y && p == P_SLT && zo(c) && minmax(f, t, w) { return true; }
        if opv == y && p == P_SGT && zo(ap_inc(c)) && minmax(t, f, w) { return true; }
    }
    return false;
}

// InstCombinerImpl::foldSelectExtConst(Sel)
fn fold_select_ext_const(sel: i32) -> i32 {
    var c: i32 = -1;
    if is_constant(op(sel, 1)) { c = op(sel, 1); } else if is_constant(op(sel, 2)) { c = op(sel, 2); } else { return -1; }
    var ext: i32 = -1;
    if is_inst(op(sel, 1)) { ext = op(sel, 1); } else if is_inst(op(sel, 2)) { ext = op(sel, 2); } else { return -1; }
    let eo = iop(ext);
    if eo != OP_ZEXT && eo != OP_SEXT { return -1; }
    var x = op(ext, 0);
    let small = vals[x].ty;
    let cond = op(sel, 0);
    if !is_int_ty1(small) && (!is_cmp_inst(cond) || vals[op(cond, 0)].ty != small) { return -1; }
    let selty = vals[sel].ty;
    var truncc = get_lossless_inv_cast(c, small, eo);
    if truncc >= 0 && has_one_use(ext) {
        if ext == op(sel, 2) { let t = x; x = truncc; truncc = t; }
        let ns = icb_select(cond, x, truncc, "narrow", sel);
        return ic_new_cast(eo, ns, selty);
    }
    return -1;
}

// canonicalizeSelectToShuffle(SI)
fn canonicalize_select_to_shuffle(si: i32) -> i32 {
    let condv = op(si, 0);
    let cty = vals[condv].ty;
    if ty_kind(cty) != TK_FVEC || !is_constant(condv) { return -1; }
    let n = ty_count(cty);
    var mask: i32[>..<] = [];
    for k in n {
        let e = agg_elem(condv, k);
        if e < 0 { return -1; }
        if is_one_value(e) { mask.push(k as i32); }
        else if is_null_value(e) { mask.push((k + n) as i32); }
        else { return -1; }
    }
    let tv = op(si, 1);
    let s = create_inst(OP_SHUFFLEVECTOR, ty_vector(ty_elem(vals[tv].ty), n, false), [tv, op(si, 2)]);
    let ii = inst_of(s);
    insts[ii].aux = ints.len as i32;
    insts[ii].naux = n as i32;
    for m in mask { ints.push(m); }
    return s;
}

// canonicalizeScalarSelectOfVecs(Sel, IC)
fn canonicalize_scalar_select_of_vecs(sel: i32) -> i32 {
    let ty = vals[sel].ty;
    if !ty_is_vector(ty) { return -1; }
    let cond = op(sel, 0);
    if !one_use(cond) || !is_inst_op(cond, OP_EXTRACTELEMENT) || m_constant_int(op(cond, 1)) < 0 { return -1; }
    let vty = ty_vector(vals[cond].ty, ty_count(ty), ty_kind(ty) == TK_SVEC);
    return ic_replace_operand(sel, 0, icb_vector_splat(vty, cond, ""));
}

// InstCombinerImpl::fmulByZeroIsZero(MulVal, FMF, CtxI)
fn fmul_by_zero_is_zero(mulv: i32, fmf: u8, cxt: i32) -> bool {
    let k = sl_kfc(mulv, fmf, FCL_NEGATIVE, cxt);
    return kfc_never_nan(k) && kfc_never_inf(k) && ((fmf & FMF_NSZ) != 0 || kfc_never(k, FCL_NEGATIVE));
}

// foldSelectCmpBitcasts(Sel, Builder)
fn fold_select_cmp_bitcasts(sel: i32) -> i32 {
    let cond = op(sel, 0);
    let tv = op(sel, 1);
    let fv = op(sel, 2);
    if !is_cmp_inst(cond) { return -1; }
    let a = op(cond, 0);
    let b = op(cond, 1);
    if tv == a || tv == b || fv == a || fv == b { return -1; }
    if !is_op(a, OP_BITCAST) || !is_op(b, OP_BITCAST) { return -1; }
    let c = op(a, 0);
    let d = op(b, 0);
    if !is_op(tv, OP_BITCAST) || !is_op(fv, OP_BITCAST) { return -1; }
    let ts = op(tv, 0);
    let fs = op(fv, 0);
    var ns: i32 = -1;
    if ts == c && fs == d { ns = icb_select(cond, a, b, "", sel); }
    else if ts == d && fs == c { ns = icb_select(cond, b, a, "", sel); }
    else { return -1; }
    return ic_new_cast(OP_BITCAST, ns, vals[sel].ty);
}

// the isExtractFromCmpXchg lambda of foldSelectCmpXchg
fn sl_extract_from_cmpxchg(v0: i32, idx: i64) -> i32 {
    var v = v0;
    if is_inst_op(v, OP_BITCAST) && idx == 0 { v = op(v, 0); }
    if !is_inst_op(v, OP_EXTRACTVALUE) { return -1; }
    if ints[insts[inst_of(v)].aux] as i64 != idx { return -1; }
    let agg = op(v, 0);
    if !is_inst_op(agg, OP_CMPXCHG) { return -1; }
    return agg;
}
// the isCompareSameAsValue lambda
fn sl_compare_same_as_value(cmpv: i32, selv: i32) -> bool {
    if cmpv == selv || (is_op(cmpv, OP_BITCAST) && op(cmpv, 0) == selv) { return true; }
    if vals[cmpv].kind == VK_CINT && !ty_is_vector(vals[cmpv].ty) && vals[selv].kind == VK_CFP && !ty_is_vector(vals[selv].ty) {
        let iv = ci_ap(cmpv);
        let w = iv.w as i64;
        if w != ty_bits(vals[selv].ty) { return false; }
        let fb = ap_from_words(w, [cint_lo(selv), cint_hi(selv)]);
        return ap_eq(iv, fb);
    }
    return false;
}

// foldSelectCmpXchg(SI)
fn fold_select_cmpxchg(si: i32) -> i32 {
    if has_one_use(si) {
        let u = uses[vals[si].first_use].user;
        if is_select_inst(u) && op(u, 0) == op(si, 0) && (op(u, 2) == op(si, 1) || op(u, 1) == op(si, 2)) { return -1; }
    }
    let cx = sl_extract_from_cmpxchg(op(si, 0), 1);
    if cx < 0 { return -1; }
    let x = sl_extract_from_cmpxchg(op(si, 1), 0);
    if x >= 0 && x == cx && sl_compare_same_as_value(op(x, 1), op(si, 2)) { return op(si, 2); }
    let y = sl_extract_from_cmpxchg(op(si, 2), 0);
    if y >= 0 && y == cx && sl_compare_same_as_value(op(y, 1), op(si, 1)) { return op(si, 2); }
    return -1;
}

// foldSelectFunnelShift(Sel, Builder)
fn fold_select_funnel_shift(sel: i32) -> i32 {
    let w = ty_sbits(sel);
    if w <= 0 || (w & (w - 1)) != 0 || w > 0xFFFFFFFF { return -1; }
    let f = op(sel, 2);
    if !one_use(f) || !bo(f, OP_OR) { return -1; }
    var or0 = op(f, 0);
    var or1 = op(f, 1);
    if !is_binop_inst(or0) || !is_binop_inst(or1) { return -1; }
    fn lshift(v: i32) -> bool { one_use(v) && (bo(v, OP_SHL) || bo(v, OP_LSHR)) }
    fn zext_or_self(v: i32) -> i32 { if is_inst_op(v, OP_ZEXT) { op(v, 0) } else { v } }
    if !lshift(or0) || !lshift(or1) || iop(or0) == iop(or1) { return -1; }
    var sv0 = op(or0, 0);
    var sa0 = zext_or_self(op(or0, 1));
    var sv1 = op(or1, 0);
    var sa1 = zext_or_self(op(or1, 1));
    if iop(or0) == OP_LSHR {
        let t = or0; or0 = or1; or1 = t;
        let t2 = sv0; sv0 = sv1; sv1 = t2;
        let t3 = sa0; sa0 = sa1; sa1 = t3;
    }
    var shamt: i32 = -1;
    if one_use(sa1) && bo(sa1, OP_SUB) && m_specific_int(op(sa1, 0), w as u64) && op(sa1, 1) == sa0 { shamt = sa0; }
    else if one_use(sa0) && bo(sa0, OP_SUB) && m_specific_int(op(sa0, 0), w as u64) && op(sa0, 1) == sa1 { shamt = sa1; }
    else { return -1; }
    let is_fshl = shamt == sa0;
    let tv = op(sel, 1);
    if (is_fshl && tv != sv0) || (!is_fshl && tv != sv1) { return -1; }
    let cond = op(sel, 0);
    if !one_use(cond) || !is_inst_op(cond, OP_ICMP) || inst_pred(cond) != P_EQ || op(cond, 0) != shamt || !m_zero_int(op(cond, 1)) { return -1; }
    if sv0 != sv1 {
        if is_fshl && !is_guaranteed_not_to_be_poison(sv1, -1, 0) { sv1 = icb_freeze(sv1, ""); }
        else if !is_fshl && !is_guaranteed_not_to_be_poison(sv0, -1, 0) { sv0 = icb_freeze(sv0, ""); }
    }
    let id = if is_fshl { IID_fshl } else { IID_fshr };
    let sty: i32 = vals[sel].ty;
    let sh = icb_zext(shamt, sty, "");
    return ic_new_intrinsic(id, [sty], [sv0, sv1, sh]);
}

// foldSelectToCopysign(Sel, Builder)
fn fold_select_to_copysign(sel: i32) -> i32 {
    let cond = op(sel, 0);
    let tv = op(sel, 1);
    let fv = op(sel, 2);
    let selty: i32 = vals[sel].ty;
    let tc = m_apfloat_ap(tv, true);
    let fc = m_apfloat_ap(fv, true);
    if tc < 0 || fc < 0 { return -1; }
    let kind = cfp_kind(tc);
    let tlo, thi = fp_with_sign(kind, cint_lo(tc), cint_hi(tc), false);
    let flo, fhi = fp_with_sign(kind, cint_lo(fc), cint_hi(fc), false);
    if tlo != flo || thi != fhi { return -1; }
    if !one_use(cond) || !is_inst_op(cond, OP_ICMP) || !has_apint(op(cond, 1)) { return -1; }
    let bc = op(cond, 0);
    if !is_op(bc, OP_BITCAST) { return -1; }
    var x = op(bc, 0);
    // m_ElementWiseBitCast: same element count
    let st = vals[x].ty;
    let dt = vals[bc].ty;
    if ty_is_vector(st) != ty_is_vector(dt) { return -1; }
    if ty_is_vector(st) && (ty_count(st) != ty_count(dt) || ty_kind(st) != ty_kind(dt)) { return -1; }
    let ok, true_if_signed = is_sign_bit_check(inst_pred(cond), ap_c(op(cond, 1)));
    if !ok || vals[x].ty != selty { return -1; }
    let tneg = cfp_parts(tc).neg;
    if true_if_signed != tneg { x = ao_fneg(x); }
    let mag = c_fp_bits_ty(selty, tlo, thi);
    return ic_new_intrinsic(IID_copysign, [selty], [mag, x]);
}

// InstCombinerImpl::foldVectorSelect(Sel)
fn fold_vector_select(sel: i32) -> i32 {
    let selty = vals[sel].ty;
    if !ty_is_vector(selty) { return -1; }
    let cond = op(sel, 0);
    let tv = op(sel, 1);
    let fv = op(sel, 2);
    if inst_iid(cond) == IID_vector_reverse {
        let c = op(cond, 0);
        if inst_iid(tv) == IID_vector_reverse {
            let x = op(tv, 0);
            if inst_iid(fv) == IID_vector_reverse && (has_one_use(cond) || has_one_use(tv) || has_one_use(fv)) {
                return sl_create_sel_reverse(sel, c, x, op(fv, 0));
            }
            if (has_one_use(cond) || has_one_use(tv)) && is_splat_value(fv, 0) { return sl_create_sel_reverse(sel, c, x, fv); }
        } else if is_splat_value(tv, 0) && inst_iid(fv) == IID_vector_reverse && (has_one_use(cond) || has_one_use(fv)) {
            return sl_create_sel_reverse(sel, c, tv, op(fv, 0));
        }
    }
    if ty_kind(selty) != TK_FVEC { return -1; }
    let n = ty_count(selty);
    let v = ic_simplify_demanded_vector_elts_root(sel, ap_ones(n));
    if v >= 0 {
        if v != sel { return ic_replace_inst_uses_with(sel, v); }
        return sel;
    }
    if one_use(tv) && is_inst_op(tv, OP_SHUFFLEVECTOR) && sl_shuffle_is_select_no_poison(tv) {
        let x = op(tv, 0);
        let y = op(tv, 1);
        if x == fv {
            let ns = icb_select(cond, y, x, "sel", sel);
            return sl_new_shuffle_like(tv, x, ns);
        }
        if y == fv {
            let ns = icb_select(cond, x, y, "sel", sel);
            return sl_new_shuffle_like(tv, ns, y);
        }
    }
    if one_use(fv) && is_inst_op(fv, OP_SHUFFLEVECTOR) && sl_shuffle_is_select_no_poison(fv) {
        let x = op(fv, 0);
        let y = op(fv, 1);
        if x == tv {
            let ns = icb_select(cond, x, y, "sel", sel);
            return sl_new_shuffle_like(fv, x, ns);
        }
        if y == tv {
            let ns = icb_select(cond, y, x, "sel", sel);
            return sl_new_shuffle_like(fv, ns, y);
        }
    }
    return -1;
}
// the createSelReverse lambda
fn sl_create_sel_reverse(sel: i32, c: i32, x: i32, y: i32) -> i32 {
    let v = icb_select(c, x, y, sl_name(sel, ""), sel);
    if is_inst(v) { copy_ir_flags(v, sel); }
    return ic_new_intrinsic(IID_vector_reverse, [vals[v].ty as i32], [v]);
}
// !is_contained(Mask, PoisonMaskElem) && ShuffleVectorInst::isSelect()
fn sl_shuffle_is_select_no_poison(s: i32) -> bool {
    let ii = inst_of(s);
    let n = insts[ii].naux as i64;
    let at = insts[ii].aux as i64;
    let src = vals[op(s, 0)].ty;
    if ty_kind(src) != TK_FVEC || ty_count(src) != n { return false; }
    for k in n { if ints[at + k] < 0 { return false; } }
    // isSelectMask: each element k is k or k + n, and it is not an identity of one operand
    var used0 = false;
    var used1 = false;
    for k in n {
        let m = ints[at + k] as i64;
        if m == k { used0 = true; } else if m == k + n { used1 = true; } else { return false; }
    }
    return used0 && used1;
}
// new ShuffleVectorInst(A, B, Mask) with the mask of s
fn sl_new_shuffle_like(s: i32, a: i32, b: i32) -> i32 {
    let ii = inst_of(s);
    let n = insts[ii].naux as i64;
    let at = insts[ii].aux as i64;
    let r = create_inst(OP_SHUFFLEVECTOR, vals[s].ty, [a, b]);
    let ri = inst_of(r);
    insts[ri].aux = ints.len as i32;
    insts[ri].naux = n as i32;
    for k in n { let m = ints[at + k]; ints.push(m); }
    return r;
}

// foldSelectToPhiImpl(Sel, BB, DT, Builder)
fn fold_select_to_phi_impl(sel: i32, bb: i32) -> i32 {
    let idom = dt_idom(DT_DOM, bb);
    if idom < 0 { return -1; }
    let cond = op(sel, 0);
    let t = block_terminator(idom);
    var if_true: i32 = -1;
    var if_false: i32 = -1;
    if iop(t) != OP_CONDBR { return -1; }
    if op(t, 0) == cond { if_true = op(sel, 1); if_false = op(sel, 2); }
    else if m_not(op(t, 0)) == cond { if_true = op(sel, 2); if_false = op(sel, 1); }
    else { return -1; }
    let ts = term_succ(t, 0);
    let fs = term_succ(t, 1);
    if ts == fs { return -1; }
    var preds: i32[>..<] = [];
    each_pred(bb) { p => preds.push(p); };
    var inputs: i32[>..<] = [];
    for p in preds {
        var v: i32 = -1;
        if sl_dom_edge_edge(idom, ts, p, bb) { v = do_phi_translation(if_true, bb, p); }
        else if sl_dom_edge_edge(idom, fs, p, bb) { v = do_phi_translation(if_false, bb, p); }
        else { return -1; }
        if is_inst(v) && !dt_value_dominates_inst(v, block_terminator(p)) { return -1; }
        inputs.push(v);
    }
    icb_set_insert_point_head(block_first(bb));   // SetInsertPoint(BB, BB->begin())
    let pn = new_inst(OP_PHI, vals[sel].ty, inputs.len);
    vals[pn].nops = 0;
    icb_insert(pn, "");
    // Inputs is a map: a predecessor listed twice gets the value computed first
    for k in preds.len {
        var v = inputs[k];
        for j in k { if preds[j] == preds[k] { v = inputs[j]; break; } }
        phi_add_incoming(pn, v, preds[k]);
    }
    ic_take_name(pn, sel);
    return pn;
}
// DominatorTree::dominates(BasicBlockEdge, BasicBlockEdge)
fn sl_dom_edge_edge(s1: i32, e1: i32, s2: i32, e2: i32) -> bool {
    if s1 == s2 && e1 == e2 { return true; }
    return dom_edge(s1, e1, s2);
}

// foldSelectToPhi(Sel, DT, Builder)
fn fold_select_to_phi(sel: i32) -> i32 {
    var cands: i32[>..<] = [];
    cands.push(inst_parent(sel));
    for k in nops(sel) {
        let v = op(sel, k);
        if is_inst(v) {
            let b = inst_parent(v);
            var dup = false;
            for c in cands { if c == b { dup = true; } }
            if !dup { cands.push(b); }
        }
    }
    for b in cands {
        let pn = fold_select_to_phi_impl(sel, b);
        if pn >= 0 { return pn; }
    }
    return -1;
}

// foldSelectWithSRem(SI, IC, Builder)
fn fold_select_with_srem(si: i32) -> i32 {
    let condv = op(si, 0);
    var tv = op(si, 1);
    var fv = op(si, 2);
    if !is_inst_op(condv, OP_ICMP) || !has_apint(op(condv, 1)) { return -1; }
    let remres = op(condv, 0);
    let ok, tis = is_sign_bit_check(inst_pred(condv), ap_c(op(condv, 1)));
    if !ok { return -1; }
    if !tis { let t = tv; tv = fv; fv = t; }
    if bo(tv, OP_ADD) {
        let rem = sl_other_c(tv, remres);
        if rem >= 0 && bo(remres, OP_SREM) && op(remres, 1) == rem {
            kb_cxt = -1;
            if is_known_pow2(rem, true, 0) && fv == remres {
                let a = icb_add(rem, c_all_ones(vals[remres].ty), "");
                return ic_new_binop(OP_AND, op(remres, 0), a);
            }
        }
    }
    if m_one(tv) && bo(remres, OP_SREM) && m_specific_int(op(remres, 1), 2) && fv == remres {
        let a = icb_add(c_int_ty(vals[remres].ty, 2), c_all_ones(vals[remres].ty), "");
        return ic_new_binop(OP_AND, op(remres, 0), a);
    }
    return -1;
}

// canIgnoreSignBitOfZero(U) (ValueTracking.cpp)
fn can_ignore_sign_bit_of_zero(u: i32) -> bool {
    let user = uses[u].user;
    if is_fp_math_operator(user) && (insts[inst_of(user)].fmf & FMF_NSZ) != 0 { return true; }
    let o = iop(user);
    if o == OP_FPTOSI || o == OP_FPTOUI || o == OP_FCMP { return true; }
    if o == OP_CALL {
        let id = inst_iid(user);
        if id == IID_fabs { return true; }
        if id == IID_copysign { return u == vals[user].ops; }
        if id == IID_is_fpclass || id == IID_vp_is_fpclass {
            let t = ap_zext64(ci_ap(op(user, 1))) & FCL_ZERO;
            return t == FCL_ZERO || t == 0;
        }
    }
    return false;
}

// canIgnoreSignBitOfNaN(U) (ValueTracking.cpp)
fn can_ignore_sign_bit_of_nan(u: i32) -> bool {
    let user = uses[u].user;
    if is_fp_math_operator(user) && (insts[inst_of(user)].fmf & FMF_NNAN) != 0 { return true; }
    let o = iop(user);
    if o == OP_FPTOSI || o == OP_FPTOUI || o == OP_FADD || o == OP_FSUB || o == OP_FMUL || o == OP_FDIV || o == OP_FREM ||
       o == OP_FPTRUNC || o == OP_FPEXT || o == OP_FCMP { return true; }
    if o == OP_FNEG || o == OP_SELECT || o == OP_PHI { return false; }
    if o == OP_RET {
        let fv = inst_func(user);
        return (aset_int(alist_ret(func_attrs(fv)), AK_NoFPClass) & FCL_NAN) != 0;
    }
    if o == OP_CALL || o == OP_INVOKE {
        let id = inst_iid(user);
        if id != 0 {
            if id == IID_fabs { return true; }
            if id == IID_copysign { return u == vals[user].ops; }
            return id == IID_maxnum || id == IID_minnum || id == IID_maximum || id == IID_minimum || id == IID_maximumnum ||
                id == IID_minimumnum || id == IID_canonicalize || id == IID_fma || id == IID_fmuladd || id == IID_sqrt ||
                id == IID_pow || id == IID_powi || id == IID_fptoui_sat || id == IID_fptosi_sat || id == IID_is_fpclass ||
                id == IID_vp_is_fpclass;
        }
        let k = (u - vals[user].ops) as i64;
        var mask = aset_int(alist_param(insts[inst_of(user)].attrs, k), AK_NoFPClass);
        let f = called_function(user);
        if f >= 0 { mask |= aset_int(alist_param(func_attrs(f), k), AK_NoFPClass); }
        return (mask & FCL_NAN) != 0;
    }
    return false;
}

// foldSelectWithFCmpToFabs(SI, IC)
fn fold_select_with_fcmp_to_fabs(si: i32) -> i32 {
    let condv = op(si, 0);
    var changed_fmf = false;
    let swaps: bool[2] = [false, true];
    for swap in swaps {
        var tv = op(si, 1);
        var x = op(si, 2);
        if swap { let t = tv; tv = x; x = t; }
        if !is_inst_op(condv, OP_FCMP) || op(condv, 0) != x || !m_any_zero_fp(op(condv, 1)) { continue; }
        var p = inst_pred(condv);
        let sfmf = insts[inst_of(si)].fmf;
        let cfmf = insts[inst_of(condv)].fmf;
        if bo(tv, OP_FSUB) && m_pos_zero_fp(op(tv, 0)) && op(tv, 1) == x {
            var nn = (cfmf & FMF_NNAN) != 0 || (sfmf & FMF_NNAN) != 0 ||
                     (has_one_use(si) && can_ignore_sign_bit_of_nan(vals[si].first_use));
            if !nn { kb_cxt = condv; nn = is_known_never_nan(x, 0); }
            if nn {
                if !swap && (p == P_OLE || p == P_FULE) { return ic_replace_inst_uses_with(si, ao_fabs(x, sfmf)); }
                if swap && (p == P_OGT || p == P_FUGT) { return ic_replace_inst_uses_with(si, ao_fabs(x, sfmf)); }
            }
        }
        if m_fneg(tv) != x { return -1; }
        let si_i = inst_of(si);
        if (cfmf & FMF_NNAN) != 0 && (insts[si_i].fmf & FMF_NNAN) == 0 { insts[si_i].fmf |= FMF_NNAN; changed_fmf = true; }
        if (cfmf & FMF_NINF) != 0 && (insts[si_i].fmf & FMF_NINF) == 0 { insts[si_i].fmf |= FMF_NINF; changed_fmf = true; }
        let ordered = p >= 1 && p <= 7;
        let unordered = p >= 8 && p <= 14;
        if (insts[si_i].fmf & FMF_NNAN) == 0 && (sl_fmf(tv) & FMF_NNAN) != 0 && (if swap { ordered } else { unordered }) {
            insts[si_i].fmf |= FMF_NNAN;
            changed_fmf = true;
        }
        if (insts[si_i].fmf & FMF_NSZ) == 0 && (!has_one_use(si) || !can_ignore_sign_bit_of_zero(vals[si].first_use)) { return -1; }
        if (insts[si_i].fmf & FMF_NNAN) == 0 && (!has_one_use(si) || !can_ignore_sign_bit_of_nan(vals[si].first_use)) { return -1; }
        if swap { p = vt_fpred_swapped(p); }
        let lt = p == P_OLT || p == P_OLE || p == P_FULT || p == P_FULE;
        let gt = p == P_OGT || p == P_OGE || p == P_FUGT || p == P_FUGE;
        if lt { return ic_replace_inst_uses_with(si, ao_fabs(x, insts[si_i].fmf)); }
        if gt {
            let fa = ao_fabs(x, insts[si_i].fmf);
            let nf = sl_new_fneg(fa);
            sl_set_fmf(nf, insts[si_i].fmf);
            return nf;
        }
    }
    for swap in swaps {
        var tv = op(si, 1);
        var x = op(si, 2);
        if swap { let t = tv; tv = x; x = t; }
        if !is_inst_op(condv, OP_ICMP) || !has_apint(op(condv, 1)) { continue; }
        let bc = op(condv, 0);
        if !is_op(bc, OP_BITCAST) || op(bc, 0) != x || !sl_elementwise_bitcast(bc) { continue; }
        let ok, tis = is_sign_bit_check(inst_pred(condv), ap_c(op(condv, 1)));
        if !ok { continue; }
        if m_fneg(tv) != x { return -1; }
        if swap == tis && !has_one_use(condv) && !has_one_use(tv) { return -1; }
        let sfmf = insts[inst_of(si)].fmf;
        let fa = ao_fabs(x, sfmf);
        if swap != tis { return ic_replace_inst_uses_with(si, fa); }
        let nf = sl_new_fneg(fa);
        sl_set_fmf(nf, sfmf);
        return nf;
    }
    return if changed_fmf { si } else { -1 };
}
// m_ElementWiseBitCast: a bitcast whose source and destination have the same element count
fn sl_elementwise_bitcast(bc: i32) -> bool {
    let st = vals[op(bc, 0)].ty;
    let dt = vals[bc].ty;
    if ty_is_vector(st) != ty_is_vector(dt) { return false; }
    if ty_is_vector(st) && (ty_count(st) != ty_count(dt) || ty_kind(st) != ty_kind(dt)) { return false; }
    return true;
}

// foldSelectOfOrderedFAbsCmpOfNaNScrubbedValue(SI, IC)
fn fold_select_of_ordered_fabs_cmp_of_nan_scrubbed_value(si: i32) -> i32 {
    let oc = op(si, 0);
    if !one_use(oc) || !is_inst_op(oc, OP_FCMP) { return -1; }
    var cmp0 = op(oc, 0);
    var cmp1 = op(oc, 1);
    var p = inst_pred(oc);
    if !(p >= 1 && p <= 7) { return -1; }
    let y = op(si, 2);
    let isel = op(si, 1);
    if !is_select_inst(isel) { return -1; }
    let ic0 = op(isel, 0);
    if !one_use(ic0) || !is_inst_op(ic0, OP_FCMP) || inst_pred(ic0) != P_ORD || !m_any_zero_fp(op(ic0, 1)) { return -1; }
    let x = op(ic0, 0);
    if op(isel, 1) != x || op(isel, 2) != y { return -1; }
    fn fabs_of(v: i32, s: i32) -> bool { one_use(v) && inst_iid(v) == IID_fabs && op(v, 0) == s }
    var fabsi: i32 = -1;
    if fabs_of(cmp0, isel) { fabsi = cmp0; }
    else {
        if !fabs_of(cmp1, isel) { return -1; }
        fabsi = cmp1;
        let t = cmp0; cmp0 = cmp1; cmp1 = t;
        p = vt_fpred_swapped(p);
    }
    let rewrite: u8 = FMF_REASSOC | FMF_ARCP | FMF_CONTRACT | FMF_AFN;
    let value: u8 = FMF_NNAN | FMF_NINF | FMF_NSZ;
    let ff = sl_fmf(fabsi);
    let cf = sl_fmf(oc);
    let common = rewrite & ff & cf;
    var nff = common | (value & ff);
    var ncf = common | (value & cf);
    nff &= ~FMF_NNAN;
    ncf &= ~FMF_NNAN;
    let na = ao_fabs(x, nff);
    let nc = ao_fcmp_fmf(p, na, cmp1, ncf, "");
    let sv = icb_fmf;
    icb_fmf = sl_fmf(si);
    let ns = icb_select(nc, x, y, "", -1);
    icb_fmf = sv;
    return ic_replace_inst_uses_with(si, ns);
}

// foldRoundUpIntegerWithPow2Alignment(SI, Builder)
fn fold_round_up_integer_with_pow2_alignment(si: i32) -> i32 {
    let cond = op(si, 0);
    var x = op(si, 1);
    var xbh = op(si, 2);
    if !is_inst_op(cond, OP_ICMP) || !m_zero_int(op(cond, 1)) { return -1; }
    let p = inst_pred(cond);
    if p != P_EQ && p != P_NE { return -1; }
    let xlow = op(cond, 0);
    if p == P_NE { let t = x; x = xbh; xbh = t; }
    if !bo(xlow, OP_AND) || op(xlow, 0) != x || !has_apint_poison(op(xlow, 1)) { return -1; }
    let lowmask = ap_cp(op(xlow, 1));
    var bias = lowmask;
    var high = lowmask;
    if bo(xbh, OP_AND) && bo(op(xbh, 0), OP_ADD) && op(op(xbh, 0), 0) == x && has_apint_poison(op(op(xbh, 0), 1)) &&
       has_apint_poison(op(xbh, 1)) {
        bias = ap_cp(op(op(xbh, 0), 1));
        high = ap_cp(op(xbh, 1));
    } else if bo(xbh, OP_ADD) && bo(op(xbh, 0), OP_AND) && op(op(xbh, 0), 0) == x && has_apint_poison(op(op(xbh, 0), 1)) &&
              has_apint_poison(op(xbh, 1)) {
        high = ap_cp(op(op(xbh, 0), 1));
        bias = ap_cp(op(xbh, 1));
    } else { return -1; }
    if !ap_is_mask(lowmask) { return -1; }
    if !ap_eq(ap_not(lowmask), high) { return -1; }
    let align = ap_inc(lowmask);
    if !ap_eq(bias, align) && !ap_eq(bias, lowmask) { return -1; }
    if !has_one_use(xbh) {
        if ap_eq(bias, lowmask) && implies_poison(xbh, x) { return xbh; }
        return -1;
    }
    let ty = vals[x].ty;
    let xo = icb_add(x, c_int_ap(ty, lowmask), sl_name(x, ".biased"));
    let r = icb_and(xo, c_int_ap(ty, high), "");
    ic_take_name(r, si);
    return r;
}

// foldSelectOfSymmetricSelect(OuterSelVal, Builder)
fn fold_select_of_symmetric_select(osel: i32) -> i32 {
    let oc = op(osel, 0);
    let a = op(osel, 1);
    let b = op(osel, 2);
    if !one_use(a) || !is_select_inst(a) || !one_use(b) || !is_select_inst(b) { return -1; }
    let ic0 = op(a, 0);
    let itv = op(a, 1);
    let ifv = op(a, 2);
    if op(b, 0) != ic0 || op(b, 1) != ifv || op(b, 2) != itv { return -1; }
    if vals[oc].ty != vals[ic0].ty { return -1; }
    let x = icb_xor(ic0, oc, "");
    return ic_new_select(x, ifv, itv);
}

// foldNestedSelects(OuterSelVal, Builder)
fn fold_nested_selects(osel: i32) -> i32 {
    var ocond = op(osel, 0);
    var otv = op(osel, 1);
    var ofv = op(osel, 2);
    let nc = m_not(ocond);
    if nc >= 0 { ocond = nc; let t = otv; otv = ofv; ofv = t; }
    if !m_logical(ocond, true) && !m_logical(ocond, false) { return -1; }
    let is_and = m_logical(ocond, true);
    let isv = if is_and { ofv } else { otv };
    if !one_use(op(osel, 0)) && !one_use(isv) { return -1; }
    if !is_select_inst(isv) { return -1; }
    var icond = op(isv, 0);
    var itv = op(isv, 1);
    var ifv = op(isv, 2);
    let ni = m_not(icond);
    if ni >= 0 { icond = ni; let t = itv; itv = ifv; ifv = t; }
    var alt: i32 = -1;
    // matchOuterCond(m_Specific(InnerSel.Cond))
    m_logical(ocond, is_and);
    let la = lg_a;
    let lb = lg_b;
    if la == icond { alt = lb; }
    else if lb == icond { alt = la; }
    else {
        var nic: i32 = -1;
        if m_not(la) == icond { nic = la; alt = lb; }
        else if m_not(lb) == icond { nic = lb; alt = la; }
        else { return -1; }
        let t = itv; itv = ifv; ifv = t;
        icond = nic;
    }
    let sinner = icb_select(alt, if is_and { otv } else { ifv }, if is_and { itv } else { ofv }, "", -1);
    ic_take_name(sinner, isv);
    return ic_new_select(icond, if is_and { sinner } else { itv }, if !is_and { sinner } else { ifv });
}

// impliesPoisonOrCond(ValAssumedPoison, V, Expected, SQ)
fn implies_poison_or_cond(vap: i32, v: i32, expected: bool) -> bool {
    if implies_poison(vap, v) { return true; }
    if is_inst_op(vap, OP_ICMP) {
        let l = op(vap, 0);
        if (insts[inst_of(vap)].flags & FL_SAMESIGN) != 0 && has_apint(op(vap, 1)) && is_inst_op(v, OP_ICMP) &&
           op(v, 0) == l && has_apint_poison(op(v, 1)) {
            let c1 = ap_c(op(vap, 1));
            let c2 = ap_cp(op(v, 1));
            let w = c1.w as i64;
            let crx = if ap_is_nonneg(c1) { rg_new(ap_smin_val(w), ap_zero(w)) } else { rg_new(ap_zero(w), ap_smin_val(w)) };
            let p = inst_pred(v);
            return rg_icmp(if expected { p } else { pred_inverse(p) }, crx, rg_single(c2));
        }
    }
    if is_inst_op(vap, OP_TRUNC) && op_nuw(vap) {
        let a = op(vap, 0);
        if is_guaranteed_not_to_be_poison(a, -1, 0) {
            kb_cxt = vap;
            let k = kb_compute_all(a, 0);
            return ap_eq_u64(ap_not(k.z), 1);
        }
    }
    return false;
}


// IRBuilder::CreateSelectWithUnknownProfile(C, T, F, PassName)
fn sl_select_unknown_prof(c: i32, t: i32, f: i32) -> i32 {
    let s = icb_select(c, t, f, "", -1);
    if is_inst(s) { sl_set_unknown_branch_weights(s); }
    return s;
}
// setExplicitlyUnknownBranchWeightsIfProfiled(I, PassName)
fn sl_set_unknown_branch_weights(i: i32) {
    ic_set_unknown_branch_weights_if_profiled(i);
}
// isCheckForZeroAndMulWithOverflow(Op0, Op1, IsAnd, Y): the use Y (the other multiplicand) or -1
fn sl_check_for_zero_and_mul_with_overflow(op0: i32, op1: i32, is_and: bool) -> i32 {
    if !is_inst_op(op0, OP_ICMP) || !m_zero(op(op0, 1)) { return -1; }
    let p = inst_pred(op0);
    let x = op(op0, 0);
    var ov: i32 = -1;
    if is_and && p == P_NE { ov = op1; }
    else if !is_and && p == P_EQ { ov = m_not(op1); }
    if ov < 0 || !is_inst_op(ov, OP_EXTRACTVALUE) { return -1; }
    let ix = insts[inst_of(ov)];
    if ix.naux != 1 || ints[ix.aux] != 1 { return -1; }
    let m = op(ov, 0);
    let id = inst_iid(m);
    if id != IID_umul_with_overflow && id != IID_smul_with_overflow { return -1; }
    if op(m, 0) == x { return vals[m].ops + 1; }
    if op(m, 1) == x { return vals[m].ops; }
    return -1;
}

// InstCombinerImpl::foldSelectOfBools(SI)
fn fold_select_of_bools(si: i32) -> i32 {
    let condv = op(si, 0);
    let tv = op(si, 1);
    let fv = op(si, 2);
    let selty = vals[si].ty;
    if !is_int_ty1(selty) || is_constant(condv) || vals[tv].ty != vals[condv].ty { return -1; }
    let one = c_bool_ty(selty, true);
    let zero = c_bool_ty(selty, false);
    if m_one(tv) {
        if implies_poison_or_cond(fv, condv, false) { return ic_new_binop(OP_OR, condv, fv); }
        if one_use(condv) && is_select_inst(condv) && m_one(op(condv, 1)) && implies_poison_or_cond(fv, op(condv, 2), false) {
            let a = op(condv, 0);
            let b = op(condv, 2);
            let lor = icb_logical_or(a, icb_or(b, fv, ""), "");
            if is_inst(lor) { sl_set_unknown_branch_weights(lor); }
            return ic_replace_inst_uses_with(si, lor);
        }
        if m_logical(condv, true) {
            let a = lg_a; let b = lg_b;
            if m_logical(fv, true) && (has_one_use(condv) || has_one_use(fv)) {
                let c = lg_a; let d = lg_b;
                let cla = is_select_inst(condv);
                let fla = is_select_inst(fv);
                if a == c { return sl_and_factorization(a, b, d, false, a, cla, fla, one, zero); }
                if a == d { return sl_and_factorization(a, b, c, false, a, cla, fla, one, zero); }
                if b == c { return sl_and_factorization(b, a, d, false, a, cla, fla, one, zero); }
                if b == d { return sl_and_factorization(b, a, c, cla && fla, a, cla, fla, one, zero); }
            }
        }
    }
    if m_zero(fv) {
        if implies_poison_or_cond(tv, condv, true) { return ic_new_binop(OP_AND, condv, tv); }
        if one_use(condv) && is_select_inst(condv) && m_zero(op(condv, 2)) && implies_poison_or_cond(tv, op(condv, 1), true) {
            let a = op(condv, 0);
            let b = op(condv, 1);
            let land = icb_logical_and(a, icb_and(b, tv, ""), "");
            if is_inst(land) { sl_set_unknown_branch_weights(land); }
            return ic_replace_inst_uses_with(si, land);
        }
        if m_logical(condv, false) {
            let a = lg_a; let b = lg_b;
            if m_logical(tv, false) && (has_one_use(condv) || has_one_use(tv)) {
                let c = lg_a; let d = lg_b;
                let clo = is_select_inst(condv);
                let tlo = is_select_inst(tv);
                if a == c { return sl_or_factorization(a, b, d, false, a, clo, tlo, one, zero); }
                if a == d { return sl_or_factorization(a, b, c, false, a, clo, tlo, one, zero); }
                if b == c { return sl_or_factorization(b, a, d, false, a, clo, tlo, one, zero); }
                if b == d { return sl_or_factorization(b, a, c, clo && tlo, a, clo, tlo, one, zero); }
            }
        }
    }
    if tv == zero {
        let nc = icb_not(condv, sl_name2("not.", condv));
        let ns = ic_new_select_md_all(nc, fv, zero, si);
        cu_swap_prof_metadata(ns);
        return ns;
    }
    if fv == one {
        let nc = icb_not(condv, sl_name2("not.", condv));
        let ns = ic_new_select_md_all(nc, one, tv, si);
        cu_swap_prof_metadata(ns);
        return ns;
    }
    // select !a, !b, false --> not (select a, true, b)
    if m_logical(si, true) {
        let a = m_not(lg_a);
        let b = m_not(lg_b);
        if a >= 0 && b >= 0 && (has_one_use(condv) || has_one_use(tv)) && !m_constant_expr(a) && !m_constant_expr(b) {
            let ns = icb_select(a, one, b, "", si);
            cu_swap_prof_metadata(ns);
            return ic_new_not(ns);
        }
    }
    if m_logical(si, false) {
        let a = m_not(lg_a);
        let b = m_not(lg_b);
        if a >= 0 && b >= 0 && (has_one_use(condv) || has_one_use(fv)) && !m_constant_expr(a) && !m_constant_expr(b) {
            let ns = icb_select(a, b, zero, "", si);
            cu_swap_prof_metadata(ns);
            return ic_new_not(ns);
        }
    }
    if is_select_inst(condv) && m_one(op(condv, 1)) && m_one(tv) && fv == op(condv, 2) { return ic_replace_operand(si, 0, op(condv, 0)); }
    if is_select_inst(condv) && m_zero(op(condv, 2)) && tv == op(condv, 1) && m_zero(fv) { return ic_replace_operand(si, 0, op(condv, 0)); }
    // ~(A & B) & (A | B) --> A ^ B
    if m_logical(si, true) {
        let p0 = lg_a;
        let p1 = lg_b;
        for k in 2 {
            let x = if k == 0 { p0 } else { p1 };
            let y = if k == 0 { p1 } else { p0 };
            let n = m_not(x);
            if n < 0 || !m_logical(n, true) { continue; }
            let a = lg_a;
            let b = lg_b;
            if m_c_logical_both(y, false, a, b) { return ic_new_binop(OP_XOR, a, b); }
        }
    }
    // select (~a | c), a, b -> select a, (select c, true, b), false
    if one_use(condv) && bo(condv, OP_OR) {
        var c: i32 = -1;
        if m_not(op(condv, 0)) == tv { c = op(condv, 1); } else if m_not(op(condv, 1)) == tv { c = op(condv, 0); }
        if c >= 0 {
            let orv = sl_select_unknown_prof(c, one, fv);
            return ic_new_select_unknown_prof(tv, orv, zero);
        }
    }
    // select (c & b), a, b -> select b, (select ~c, true, a), false
    if one_use(condv) && bo(condv, OP_AND) {
        var c: i32 = -1;
        if op(condv, 1) == fv { c = op(condv, 0); } else if op(condv, 0) == fv { c = op(condv, 1); }
        if c >= 0 {
            let notc = get_freely_inverted(c, has_one_use(c), true);
            if notc >= 0 {
                let orv = sl_select_unknown_prof(notc, one, tv);
                return ic_new_select_unknown_prof(fv, orv, zero);
            }
        }
    }
    // select (a | c), a, b -> select a, true, (select ~c, b, false)
    if one_use(condv) && bo(condv, OP_OR) {
        var c: i32 = -1;
        if op(condv, 0) == tv { c = op(condv, 1); } else if op(condv, 1) == tv { c = op(condv, 0); }
        if c >= 0 {
            let notc = get_freely_inverted(c, has_one_use(c), true);
            if notc >= 0 {
                let andv = sl_select_unknown_prof(notc, fv, zero);
                return ic_new_select_unknown_prof(tv, one, andv);
            }
        }
    }
    // select (c & ~b), a, b -> select b, true, (select c, a, false)
    if one_use(condv) && bo(condv, OP_AND) {
        var c: i32 = -1;
        if m_not(op(condv, 1)) == fv { c = op(condv, 0); } else if m_not(op(condv, 0)) == fv { c = op(condv, 1); }
        if c >= 0 {
            let andv = sl_select_unknown_prof(c, tv, zero);
            return ic_new_select_unknown_prof(fv, one, andv);
        }
    }
    if m_zero(fv) || m_one(tv) {
        let is_and = m_zero(fv);
        let op1 = if is_and { tv } else { fv };
        let y = sl_check_for_zero_and_mul_with_overflow(condv, op1, is_and);
        if y >= 0 {
            let yv = uses[y].val;
            let fi = create_inst(OP_FREEZE, vals[yv].ty, [yv]);
            set_name(fi, sl_name(yv, ".fr"));
            ic_insert_new_before(fi, uses[y].user);
            ic_replace_use(y, fi);
            return ic_replace_inst_uses_with(si, op1);
        }
        let v = fold_boolean_and_or(condv, op1, si, is_and, true);
        if v >= 0 { return ic_replace_inst_uses_with(si, v); }
    }
    if m_logical(condv, false) && m_zero(fv) {
        let a = lg_a; let b = lg_b;
        if implied_condition_v(tv, b, true, 0) == 0 { return ic_replace_operand(si, 0, a); }
    }
    if m_logical(tv, false) && m_zero(fv) {
        let a = lg_a; let b = lg_b;
        if implied_condition_v(condv, b, true, 0) == 0 { return ic_replace_operand(si, 1, a); }
    }
    if m_one(tv) && m_logical(fv, true) {
        let a = lg_a; let b = lg_b;
        if implied_condition_v(condv, b, false, 0) == 1 { return ic_replace_operand(si, 2, a); }
    }
    if m_logical(condv, true) && m_one(tv) {
        let a = lg_a; let b = lg_b;
        if implied_condition_v(fv, b, false, 0) == 1 { return ic_replace_operand(si, 0, a); }
    }
    if m_one(tv) {
        let v = ao_fold_or_of_logical_ands(condv, fv);
        if v >= 0 { return v; }
    }
    return -1;
}
fn sl_name2(pfx: const u8[:], v: i32) -> u8[>..] {
    var nm: u8[>..] = [];
    nm.append(pfx);
    nm.append(val_name(v));
    return nm;
}
// the AndFactorization lambda of foldSelectOfBools
fn sl_and_factorization(common0: i32, inner_cond: i32, inner_val: i32, sel_first: bool, a: i32, cla: bool, fla: bool, one: i32, zero: i32) -> i32 {
    var common = common0;
    var isel = sl_select_unknown_prof(inner_cond, one, inner_val);
    if sel_first { let t = common; common = isel; isel = t; }
    if fla || (cla && common == a) { return ic_new_select_unknown_prof(common, isel, zero); }
    return ic_new_binop(OP_AND, common, isel);
}
// the OrFactorization lambda of foldSelectOfBools
fn sl_or_factorization(common0: i32, inner_cond: i32, inner_val: i32, sel_first: bool, a: i32, clo: bool, tlo: bool, one: i32, zero: i32) -> i32 {
    var common = common0;
    var isel = sl_select_unknown_prof(inner_cond, inner_val, zero);
    if sel_first { let t = common; common = isel; isel = t; }
    if tlo || (clo && common == a) { return ic_new_select_unknown_prof(common, one, isel); }
    return ic_new_binop(OP_OR, common, isel);
}

// isSafeToRemoveBitCeilSelect(Pred, Cond0, Cond1, CtlzOp, BitWidth, ShouldDropNoWrap): ok, drop
fn is_safe_to_remove_bit_ceil_select(p: i64, cond0: i32, cond1: AP, ctlz_op: i32, bw: i64) -> bool, bool {
    var cr = rg_exact_icmp(pred_inverse(p), cond1);
    var drop = false;
    // the MatchForward lambda: ok, new CR, drop
    fn match_forward(ca: i32, ctlz_op: i32, cr: CRange) -> bool, CRange, bool {
        if ctlz_op == ca { return true, cr, false; }
        if bo(ctlz_op, OP_ADD) && op(ctlz_op, 0) == ca && has_apint(op(ctlz_op, 1)) {
            return true, rg_add(cr, rg_single(ap_c(op(ctlz_op, 1)))), true;
        }
        if bo(ctlz_op, OP_SUB) && has_apint(op(ctlz_op, 0)) && op(ctlz_op, 1) == ca {
            return true, rg_sub(rg_single(ap_c(op(ctlz_op, 0))), cr), true;
        }
        if m_not(ctlz_op) == ca && ca >= 0 { return true, rg_not(cr), false; }
        return false, cr, false;
    }
    let ok1, cr1, d1 = match_forward(cond0, ctlz_op, cr);
    if ok1 {
        cr = cr1;
        if d1 { drop = true; }
    } else if bo(cond0, OP_ADD) && has_apint(op(cond0, 1)) {
        cr = rg_sub(cr, rg_single(ap_c(op(cond0, 1))));
        let ok2, cr2, d2 = match_forward(op(cond0, 0), ctlz_op, cr);
        if !ok2 { return false, drop; }
        cr = cr2;
        if d2 { drop = true; }
    } else {
        return false, drop;
    }
    let intmax = ap_dec(ap_sign_mask(bw));
    cr = rg_sub(cr, rg_single(ap_u64(1, bw)));
    return rg_icmp(P_UGE, cr, rg_single(intmax)), drop;
}

// foldBitCeil(SI, Builder, IC)
fn fold_bit_ceil(si: i32) -> i32 {
    let selty = vals[si].ty;
    let bw = ty_scalar_bits(selty);
    if bw <= 0 || (bw & (bw - 1)) != 0 || bw > 0xFFFFFFFF { return -1; }
    var fv = op(si, 2);
    var tv = op(si, 1);
    let c = op(si, 0);
    if !is_inst_op(c, OP_ICMP) || !has_apint(op(c, 1)) { return -1; }
    var p = inst_pred(c);
    let cond0 = op(c, 0);
    let cond1 = ap_c(op(c, 1));
    if m_one(tv) { let t = fv; fv = tv; tv = t; p = pred_inverse(p); }
    if !m_one(fv) || !one_use(tv) || !bo(tv, OP_SHL) || !m_one(op(tv, 0)) { return -1; }
    let s = op(tv, 1);
    if !one_use(s) || !bo(s, OP_SUB) || !m_specific_int(op(s, 0), bw as u64) { return -1; }
    let ctlz = op(s, 1);
    if inst_iid(ctlz) != IID_ctlz { return -1; }
    let ctlz_op = op(ctlz, 0);
    let ok, drop = is_safe_to_remove_bit_ceil_select(p, cond0, cond1, ctlz_op, bw);
    if !ok { return -1; }
    if drop {
        set_nuw(ctlz_op, false);
        set_nsw(ctlz_op, false);
    }
    drop_poison_generating_annotations(ctlz);
    icw_push(ctlz);
    let neg = icb_neg(ctlz, "", false);
    let masked = icb_and(neg, c_int_ty(selty, (bw - 1) as u64), "");
    return ic_new_binop(OP_SHL, c_int_ty(selty, 1), masked);
}

// InstCombinerImpl::foldSelectToCmp(SI)
fn fold_select_to_cmp(si: i32) -> i32 {
    var tv = op(si, 1);
    var fv = op(si, 2);
    let c0 = op(si, 0);
    if !is_inst_op(c0, OP_ICMP) { return -1; }
    var l = op(c0, 0);
    var r = op(c0, 1);
    var p = inst_pred(c0);
    if !is_int_or_int_vec(vals[l].ty) { return -1; }
    if !is_constant(tv) {
        if !is_constant(fv) { return -1; }
        p = pred_inverse(p);
        let t = tv; tv = fv; fv = t;
    }
    if p == P_SGE || p == P_SLE || p == P_UGE || p == P_ULE {
        if is_constant(r) {
            let ok, np, nc = icc_flipped_strictness(p, r);
            if !ok { return -1; }
            p = cp_pred(np);
            r = nc;
        } else { return -1; }
    }
    if (sl_is_gt(p) && m_all_ones(tv)) || (sl_is_lt(p) && m_one(tv)) {
        p = pred_swapped(p);
        let t = l; l = r; r = t;
    }
    var signed = icmp_is_signed(p);
    var replace = false;
    // m_c_ICmp(Pred, m_Specific(LHS), m_Specific(RHS)): the predicate (swapped if commuted) or -1
    fn c_icmp(v: i32, l: i32, r: i32) -> i64 {
        if !is_inst_op(v, OP_ICMP) { return -1; }
        if op(v, 0) == l && op(v, 1) == r { return inst_pred(v); }
        if op(v, 0) == r && op(v, 1) == l { return pred_swapped(inst_pred(v)); }
        return -1;
    }
    if sl_is_lt(p) && m_all_ones(tv) && is_inst_op(fv, OP_ZEXT) {
        let ep = c_icmp(op(fv, 0), l, r);
        if ep >= 0 && (ep == P_NE || pred_swapped(ep) == p) { replace = true; }
    }
    if sl_is_gt(p) && m_one(tv) && is_inst_op(fv, OP_SEXT) {
        let ep = c_icmp(op(fv, 0), l, r);
        if ep >= 0 && (ep == P_NE || pred_swapped(ep) == p) { replace = true; }
    }
    if p == P_EQ && m_zero(tv) && is_select_inst(fv) && has_apint(op(fv, 1)) && has_apint(op(fv, 2)) {
        var fbp = c_icmp(op(fv, 0), l, r);
        if fbp >= 0 {
            var itv = ap_c(op(fv, 1));
            var ifv = ap_c(op(fv, 2));
            if !sl_is_gt(fbp) {
                fbp = pred_swapped(fbp);
                let t = l; l = r; r = t;
            }
            if !ap_is_one(itv) {
                let t = itv; itv = ifv; ifv = t;
                let t2 = l; l = r; r = t2;
            }
            if sl_is_gt(fbp) && ap_is_one(itv) && ap_is_all_ones(ifv) {
                signed = icmp_is_signed(fbp);
                replace = true;
            }
        }
    }
    if p == P_EQ && m_zero(tv) && has_apint(r) {
        let c = ap_c(r);
        if is_select_inst(fv) && is_inst_op(op(fv, 0), OP_ICMP) && op(op(fv, 0), 0) == l && has_apint(op(fv, 1)) && has_apint(op(fv, 2)) {
            let ip = inst_pred(op(fv, 0));
            let irhs = op(op(fv, 0), 1);
            let itv = ap_c(op(fv, 1));
            let ifv = ap_c(op(fv, 2));
            if sl_is_gt(ip) && ap_is_one(itv) && ap_is_all_ones(ifv) {
                signed = icmp_is_signed(ip);
                let can = if signed { !ap_is_min_signed(c) } else { !ap_is_zero(c) };
                if can && m_specific_int_apv(irhs, ap_dec(c)) { replace = true; }
            }
            if sl_is_lt(ip) && ap_is_all_ones(itv) && ap_is_one(ifv) {
                signed = icmp_is_signed(ip);
                let can = if signed { !ap_is_max_signed(c) } else { !ap_is_all_ones(c) };
                if can && m_specific_int_apv(irhs, ap_inc(c)) { replace = true; }
            }
        }
    }
    let id = if signed { IID_scmp } else { IID_ucmp };
    if replace {
        let sty: i32 = vals[si].ty;
        let lty = vals[l].ty;
        return ic_replace_inst_uses_with(si, icb_intrinsic(id, [sty, lty], [l, r], ""));
    }
    return -1;
}

// matchFMulByZeroIfResultEqZero(IC, Cmp0, Cmp1, TrueVal, FalseVal, CtxI, SelectIsNSZ)
fn match_fmul_by_zero_if_result_eq_zero(cmp0: i32, cmp1: i32, tv: i32, fv: i32, cxt: i32, sel_nsz: bool) -> bool {
    if m_pos_zero_fp(cmp1) && bo(tv, OP_FMUL) {
        var mrhs: i32 = -1;
        if op(tv, 0) == cmp0 { mrhs = op(tv, 1); } else if op(tv, 1) == cmp0 { mrhs = op(tv, 0); }
        if mrhs >= 0 {
            var fmf = sl_fmf(tv);
            if sel_nsz { fmf |= FMF_NSZ; } else { fmf &= ~FMF_NSZ; }
            return fmul_by_zero_is_zero(mrhs, fmf, cxt);
        }
    }
    return false;
}

// hasAffectedValue(V, Affected, Depth): Affected is sl_aff
var sl_aff: i32[>..<];
fn sl_aff_has(v: i32) -> bool { for a in sl_aff { if a == v { return true; } } return false; }
recursive fn has_affected_value(v: i32, depth0: i64) -> bool {
    var depth = depth0;
    if depth == 6 { return false; }
    if depth != 0 && sl_aff_has(v) { return true; }
    if is_inst(v) {
        if iop(v) == OP_PHI {
            if depth == 5 { return false; }
            depth = 4;
        }
        for k in nops(v) {
            let o = op(v, k);
            if is_int_or_int_vec(vals[o].ty) && has_affected_value(o, depth + 1) { return true; }
        }
        return false;
    }
    return false;
}

// foldSelectIntoAddConstant(SI, Builder)
fn fold_select_into_add_constant(si: i32) -> i32 {
    if !is_fp_math_operator(si) { return -1; }
    let sf = sl_fmf(si);
    if (sf & FMF_NSZ) == 0 || (sf & FMF_NNAN) == 0 { return -1; }
    let c0 = op(si, 0);
    if !one_use(c0) || !is_inst_op(c0, OP_FCMP) { return -1; }
    let p = inst_pred(c0);
    let x = op(c0, 0);
    let z = op(c0, 1);
    let tv = op(si, 1);
    let fv = op(si, 2);
    if one_use(tv) && is_inst(tv) && is_constant(fv) { return sl_try_fold_into_add_constant(si, p, x, z, tv, fv, false); }
    if is_constant(tv) && one_use(fv) && is_inst(fv) { return sl_try_fold_into_add_constant(si, p, x, z, fv, tv, true); }
    return -1;
}
// the TryFoldIntoAddConstant lambda
fn sl_try_fold_into_add_constant(si: i32, p: i64, x: i32, z: i32, fadd: i32, c: i32, swapped: bool) -> i32 {
    let eq = p == P_OEQ || p == P_ONE || p == P_UEQ || p == P_UNE;
    if eq || !m_any_zero_fp(z) { return -1; }
    if !bo(fadd, OP_FADD) || op(fadd, 0) != x || op(fadd, 1) != c { return -1; }
    let ns = icb_select(op(si, 0), if swapped { z } else { x }, if swapped { x } else { z }, "", si);
    ic_take_name(ns, si);
    let nf = icb_binop(OP_FADD, ns, c, "");
    ic_take_name(nf, fadd);
    let sf = sl_fmf(si);
    let ff = sl_fmf(fadd);
    let rewrite: u8 = FMF_REASSOC | FMF_ARCP | FMF_CONTRACT | FMF_AFN;
    let value: u8 = FMF_NNAN | FMF_NINF | FMF_NSZ;
    let nfmf = (rewrite & sf & ff) | (value & (sf | ff));
    sl_set_fmf(nf, nfmf);
    sl_set_fmf(ns, nfmf);
    return nf;
}

// foldSelectBitTest(Sel, CondVal, TrueVal, FalseVal, Builder, SQ)
fn fold_select_bit_test(sel: i32, condv: i32, tv0: i32, fv0: i32) -> i32 {
    let selty = vals[sel].ty;
    if ty_is_vector(selty) != ty_is_vector(vals[condv].ty) { return -1; }
    var v: i32 = -1;
    var mask = ap_zero(1);
    var create_and = false;
    var p: i64 = 0;
    if is_inst_op(condv, OP_ICMP) {
        let l = op(condv, 0);
        let r = op(condv, 1);
        p = inst_pred(condv);
        if p == P_EQ || p == P_NE {
            if !m_zero(r) { return -1; }
            v = l;
            if !bo(l, OP_AND) || !sl_apint_pred(op(l, 1), IP_POWER2) { return -1; }
            mask = ap_cp(op(l, 1));
        } else {
            let ok, x, m, c, np = icc_decompose_bit_test_icmp(l, r, p, true, false, false);
            if !ok { return -1; }
            mask = m;
            v = x;
            kb_cxt = sel;
            let k = kb_compute_all(v, 0);
            mask = ap_and(mask, ap_not(k.z));
            if !ap_is_pow2(mask) { return -1; }
            p = np;
            create_and = true;
        }
    } else if is_inst_op(condv, OP_TRUNC) {
        v = op(condv, 0);
        mask = ap_u64(1, ty_sbits(v));
        p = P_NE;
        create_and = !op_nuw(condv);
    } else { return -1; }
    var tv = tv0;
    var fv = fv0;
    if p == P_NE { let t = tv; tv = fv; fv = t; }
    let x = fold_select_icmp_and(sel, condv, tv, fv, v, mask, create_and);
    if x >= 0 { return x; }
    return fold_select_icmp_and_binop(condv, tv, fv, v, mask, create_and);
}

// foldSelectNegNot(SI, Builder)
fn fold_select_neg_not(si: i32) -> i32 {
    let condv = op(si, 0);
    let tv = op(si, 1);
    let fv = op(si, 2);
    let selty = vals[si].ty;
    if !is_int_or_int_vec(selty) || is_int_ty1(selty) { return -1; }
    if ty_is_vector(vals[condv].ty) != ty_is_vector(selty) { return -1; }
    fn neg_not(neg: i32, not: i32) -> i32 {
        if !one_use(neg) { return -1; }
        let x = m_neg(neg);
        if x < 0 { return -1; }
        if one_use(not) && m_not(not) == x { return x; }
        return -1;
    }
    let x1 = neg_not(tv, fv);
    if x1 >= 0 {
        let nc = icb_not(condv, sl_name2("not.", condv));
        let mask = icb_sext(nc, selty, "");
        return ic_new_binop(OP_SUB, mask, x1);
    }
    let x2 = neg_not(fv, tv);
    if x2 >= 0 {
        let mask = icb_sext(condv, selty, "");
        return ic_new_binop(OP_SUB, mask, x2);
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// matchSelectPattern(&SI, LHS, RHS, &CastOp) (ValueTracking.cpp): flavor; LHS/RHS in sp_lhs/sp_rhs, the cast
// in sl_cast_op (0 = none), SelectPatternResult::Ordered in sp_ordered

var sl_cast_op: i64 = 0;
// lookThroughCastConst(CmpI, SrcTy, C, CastOp)
fn sl_look_through_cast_const(cmpi: i32, srcty: i32, c: i32, castop: i64) -> i32 {
    var to: i32 = -1;
    let p = inst_pred(cmpi);
    let isicmp = iop(cmpi) == OP_ICMP;
    if castop == OP_ZEXT {
        if isicmp && icmp_is_unsigned(p) { to = ce_cast(OP_TRUNC, c, srcty); }
    } else if castop == OP_SEXT {
        if isicmp && icmp_is_signed(p) { to = ce_cast(OP_TRUNC, c, srcty); }
    } else if castop == OP_TRUNC {
        let cc = op(cmpi, 1);
        if is_constant(cc) && vals[cc].ty == srcty { to = cc; }
        else { to = cf_fold_cast_operand(if isicmp && icmp_is_signed(p) { OP_SEXT } else { OP_ZEXT }, c, srcty); }
    } else if castop == OP_FPTRUNC { to = cf_fold_cast_operand(OP_FPEXT, c, srcty); }
    else if castop == OP_FPEXT { to = cf_fold_cast_operand(OP_FPTRUNC, c, srcty); }
    else if castop == OP_FPTOUI { to = cf_fold_cast_operand(OP_UITOFP, c, srcty); }
    else if castop == OP_FPTOSI { to = cf_fold_cast_operand(OP_SITOFP, c, srcty); }
    else if castop == OP_UITOFP { to = cf_fold_cast_operand(OP_FPTOUI, c, srcty); }
    else if castop == OP_SITOFP { to = cf_fold_cast_operand(OP_FPTOSI, c, srcty); }
    if to < 0 { return -1; }
    let back = cf_fold_cast_operand(castop, to, vals[c].ty);
    if back >= 0 && back != c { return -1; }
    return to;
}
// lookThroughCast(CmpI, V1, V2, CastOp)
fn sl_look_through_cast(cmpi: i32, v1: i32, v2: i32) -> i32 {
    if !is_cast_inst(v1) { return -1; }
    sl_cast_op = iop(v1);
    let srcty = vals[op(v1, 0)].ty;
    if is_cast_inst(v2) {
        if sl_cast_op == iop(v2) && srcty == vals[op(v2, 0)].ty { return op(v2, 0); }
        return -1;
    }
    if is_constant(v2) { return sl_look_through_cast_const(cmpi, srcty, v2, sl_cast_op); }
    if sl_cast_op == OP_TRUNC {
        let c1 = op(cmpi, 1);
        if m_zext_or_sext(c1) == v2 && v2 >= 0 { return c1; }
    }
    return -1;
}
fn sl_match_decomposed(cmpi: i32, fmf: u8, tv: i32, fv: i32) -> i64 {
    let p = inst_pred(cmpi);
    sp_ordered = false;
    if iop(cmpi) == OP_ICMP { return match_select_pattern_int(p, op(cmpi, 0), op(cmpi, 1), tv, fv, 0); }
    return match_select_pattern_fp(p, fmf, op(cmpi, 0), op(cmpi, 1), tv, fv);
}
fn sl_match_select_pattern_cast(si: i32) -> i64 {
    sl_cast_op = 0;
    sp_ordered = false;
    let c = op(si, 0);
    if !is_cmp_inst(c) { return SPF_UNKNOWN; }
    let tv = op(si, 1);
    let fv = op(si, 2);
    var fmf = sl_fmf(si);
    if iop(c) == OP_FCMP && (sl_fmf(c) & FMF_NNAN) != 0 { fmf |= FMF_NNAN; }
    let p = inst_pred(c);
    if p == P_EQ || p == P_NE || (iop(c) == OP_FCMP && (p == P_OEQ || p == P_ONE || p == P_UEQ || p == P_UNE)) { return SPF_UNKNOWN; }
    if vals[op(c, 0)].ty != vals[tv].ty {
        let c1 = sl_look_through_cast(c, tv, fv);
        if c1 >= 0 {
            if sl_cast_op == OP_FPTOSI || sl_cast_op == OP_FPTOUI { fmf |= FMF_NSZ; }
            return sl_match_decomposed(c, fmf, op(tv, 0), c1);
        }
        let c2 = sl_look_through_cast(c, fv, tv);
        if c2 >= 0 {
            if sl_cast_op == OP_FPTOSI || sl_cast_op == OP_FPTOUI { fmf |= FMF_NSZ; }
            return sl_match_decomposed(c, fmf, c2, op(fv, 0));
        }
    }
    return sl_match_decomposed(c, fmf, tv, fv);
}
// getMinMaxPred(SPF, Ordered)
fn sl_minmax_pred(f: i64, ordered: bool) -> i64 {
    if f == SPF_SMIN { return P_SLT; }
    if f == SPF_UMIN { return P_ULT; }
    if f == SPF_SMAX { return P_SGT; }
    if f == SPF_UMAX { return P_UGT; }
    if f == SPF_FMINNUM { return if ordered { P_OLT } else { P_FULT }; }
    return if ordered { P_OGT } else { P_FUGT };
}
// m_OrdOrUnordFMax(m_Value(X), m_Value(Y)) / FMin on a select: X, Y or -1
fn sl_ord_or_unord_fminmax(si: i32, is_max: bool) -> i32, i32 {
    let c = op(si, 0);
    if !is_inst_op(c, OP_FCMP) { return -1, -1; }
    let t = op(si, 1);
    let f = op(si, 2);
    let l = op(c, 0);
    let r = op(c, 1);
    if (t != l || f != r) && (t != r || f != l) { return -1, -1; }
    // FMaxMin_match: LHS == TrueVal ? the predicate : the inverse predicate; binds the compare's operands
    let p = if l == t { inst_pred(c) } else { 15 - inst_pred(c) };
    let ok = if is_max { p == P_OGT || p == P_OGE || p == P_FUGT || p == P_FUGE } else { p == P_OLT || p == P_OLE || p == P_FULT || p == P_FULE };
    if !ok { return -1, -1; }
    return l, r;
}
// Type::isIEEELikeFPTy
fn sl_is_ieee_like(t: i32) -> bool {
    let k = types[t].kind as i64;
    return k == TK_HALF || k == TK_BFLOAT || k == TK_FLOAT || k == TK_DOUBLE || k == TK_FP128;
}

// ---------------------------------------------------------------------------------------------
// InstCombinerImpl::visitSelectInst(SI)
fn visit_select(si: i32) -> i32 {
    let condv = op(si, 0);
    var tv = op(si, 1);
    var fv = op(si, 2);
    let selty = vals[si].ty;
    let fmf = sl_fmf(si);
    let sv = simplify_select(condv, tv, fv, fmf, sq_at(si), RECURSION_LIMIT);
    if sv >= 0 { return ic_replace_inst_uses_with(si, sv); }
    var r = canonicalize_select_to_shuffle(si);
    if r >= 0 { return r; }
    r = canonicalize_scalar_select_of_vecs(si);
    if r >= 0 { return r; }
    if inst_iid(fv) == IID_ctpop && op(fv, 0) == tv && is_inst_op(condv, OP_ICMP) && inst_pred(condv) == P_ULT &&
       op(condv, 0) == tv && m_specific_int(op(condv, 1), 2) {
        drop_poison_generating_annotations(fv);
        icw_push(fv);
        return ic_replace_inst_uses_with(si, fv);
    }
    let condty = vals[condv].ty;
    if !is_constant(condv) && is_int_or_int_vec(selty) && ty_is_vector(condty) == ty_is_vector(selty) {
        let tc = c_bool_ty(condty, true);
        let s1 = simplify_with_op_replaced(tv, condv, tc, sq_new(-1), true, RECURSION_LIMIT);
        if s1 >= 0 { return ic_replace_operand(si, 1, s1); }
        let fc = c_bool_ty(condty, false);
        let s2 = simplify_with_op_replaced(fv, condv, fc, sq_new(-1), true, RECURSION_LIMIT);
        if s2 >= 0 { return ic_replace_operand(si, 2, s2); }
        if replace_in_instruction(tv, condv, c_bool_ty(condty, true), 0) || replace_in_instruction(fv, condv, c_bool_ty(condty, false), 0) { return si; }
    }
    r = fold_select_of_bools(si);
    if r >= 0 { return r; }
    if is_int_or_int_vec(selty) && !is_int_ty1(selty) && ty_is_vector(condty) == ty_is_vector(selty) {
        if m_one(tv) && m_zero(fv) { return ic_new_cast(OP_ZEXT, condv, selty); }
        if m_all_ones(tv) && m_zero(fv) { return ic_new_cast(OP_SEXT, condv, selty); }
        if m_zero(tv) && m_one(fv) {
            let nc = icb_not(condv, sl_name2("not.", condv));
            return ic_new_cast(OP_ZEXT, nc, selty);
        }
        if m_zero(tv) && m_all_ones(fv) {
            let nc = icb_not(condv, sl_name2("not.", condv));
            return ic_new_cast(OP_SEXT, nc, selty);
        }
    }
    r = fold_select_neg_not(si);
    if r >= 0 { return r; }
    let sifp = is_fp_math_operator(si);
    if is_inst_op(condv, OP_FCMP) {
        let fc = condv;
        let p = inst_pred(fc);
        let c0 = op(fc, 0);
        let c1 = op(fc, 1);
        if (c0 == tv && c1 == fv) || (c0 == fv && c1 == tv) {
            if has_one_use(fc) && p >= 8 && p <= 14 {
                let inv = 15 - p;
                let nc = ao_fcmp_fmf(inv, c0, c1, sl_fmf(fc), sl_name(fc, ".inv"));
                var nf = sl_fmf(si);
                if (sl_fmf(fc) & FMF_NNAN) != 0 { nf |= FMF_NNAN; }
                if (sl_fmf(fc) & FMF_NINF) != 0 { nf |= FMF_NINF; }
                let sv2 = icb_fmf;
                icb_fmf = nf;
                let ns = icb_select(nc, fv, tv, "", -1);
                icb_fmf = sv2;
                return ic_replace_inst_uses_with(si, ns);
            }
        }
        if sifp {
            var mc0: i32 = -1;
            var mc1: i32 = -1;
            if p == P_OEQ || p == P_UEQ { mc0 = fv; mc1 = tv; }
            else if p == P_ONE || p == P_UNE { mc0 = tv; mc1 = fv; }
            if c0 == mc0 && match_fmul_by_zero_if_result_eq_zero(c0, c1, mc1, mc0, si, (sl_fmf(si) & FMF_NSZ) != 0) {
                return ic_replace_inst_uses_with(si, c0);
            }
            let elt = ty_scalar(selty);
            if (p == P_ORD || p == P_UNO) && m_pos_zero_fp(c1) && sl_is_ieee_like(elt) {
                if p == P_ORD { mc0 = tv; mc1 = fv; } else { mc0 = fv; mc1 = tv; }
                let rcp = bo(mc1, OP_FDIV) && m_fp_one(op(mc1, 0)) && op(mc1, 1) == c0;
                let canon = inst_iid(mc0) == IID_canonicalize && op(mc0, 0) == c0;
                if rcp || canon {
                    let mode = fn_denormal_mode(ic_fn, elt);
                    if rcp {
                        if mode == DM_IEEE {
                            if canon { return ic_replace_inst_uses_with(si, c0); }
                            if is_guaranteed_not_to_be_undef(c0, si, 0) {
                                ic_replace_operand(si, if p == P_ORD { 2 } else { 1 }, c0);
                                return si;
                            }
                            let fr = create_inst(OP_FREEZE, vals[c0].ty, [c0]);
                            set_name(fr, sl_name(c0, ".fr"));
                            ic_insert_new_before(fr, fc);
                            ic_replace_operand(fc, 0, fr);
                            return ic_replace_operand(si, if p == P_ORD { 2 } else { 1 }, fr);
                        }
                    }
                    if canon {
                        if mode == DM_IEEE {
                            ic_replace_operand(si, if p == P_ORD { 1 } else { 2 }, c0);
                            return si;
                        }
                        if rcp && (dm_inputs_are_zero(mode) || dm_outputs_are_zero(mode)) { return ic_replace_inst_uses_with(si, mc0); }
                    }
                }
            }
        }
    }
    if sifp {
        let fc = if is_inst_op(condv, OP_FCMP) { condv } else { -1 };
        if fc >= 0 && (sl_fmf(fc) & FMF_NNAN) != 0 &&
           ((sl_fmf(si) & FMF_NSZ) != 0 || (has_one_use(si) && can_ignore_sign_bit_of_zero(vals[si].first_use))) {
            let x, y = sl_ord_or_unord_fminmax(si, true);
            if x >= 0 {
                let bi = sl_binary_intrinsic_fmf(IID_maxnum, x, y, sl_fmf(si));
                if is_inst(bi) { sl_set_minmax_fmf(bi, fc); }
                return ic_replace_inst_uses_with(si, bi);
            }
            let x2, y2 = sl_ord_or_unord_fminmax(si, false);
            if x2 >= 0 {
                let bi = sl_binary_intrinsic_fmf(IID_minnum, x2, y2, sl_fmf(si));
                if is_inst(bi) { sl_set_minmax_fmf(bi, fc); }
                return ic_replace_inst_uses_with(si, bi);
            }
        }
    }
    r = fold_select_with_fcmp_to_fabs(si);
    if r >= 0 { return r; }
    r = fold_select_of_ordered_fabs_cmp_of_nan_scrubbed_value(si);
    if r >= 0 { return r; }
    if is_cmp_inst(condv) {
        r = fold_select_value_equivalence(si, condv);
        if r >= 0 { return r; }
    }
    if is_inst_op(condv, OP_ICMP) {
        r = fold_select_inst_with_icmp(si, condv);
        if r >= 0 { return r; }
    }
    // the folds above may have changed the operands in place only when they return si
    var v = fold_select_bit_test(si, condv, tv, fv);
    if v >= 0 { return ic_replace_inst_uses_with(si, v); }
    r = fold_add_sub_select(si);
    if r >= 0 { return r; }
    r = fold_overflowing_add_sub_select(si);
    if r >= 0 { return r; }
    r = fold_set_clear_bits(si);
    if r >= 0 { return r; }
    r = fold_select_zero_or_fixed_op(si);
    if r >= 0 { return r; }
    if is_inst(tv) && is_inst(fv) && iop(tv) == iop(fv) {
        r = fold_select_op_op(si, tv, fv);
        if r >= 0 { return r; }
    }
    r = fold_select_intrinsic(si);
    if r >= 0 { return r; }
    r = fold_select_ext_const(si);
    if r >= 0 { return r; }
    r = fold_select_with_srem(si);
    if r >= 0 { return r; }
    if is_inst_op(tv, OP_GEP) {
        r = sl_select_gep_with_base(si, tv, fv, false);
        if r >= 0 { return r; }
    }
    if is_inst_op(fv, OP_GEP) {
        r = sl_select_gep_with_base(si, fv, tv, true);
        if r >= 0 { return r; }
    }
    if is_int_or_int_vec(selty) || is_fp_or_fp_vec(selty) {
        r = fold_select_into_op(si, tv, fv);
        if r >= 0 { return r; }
        let spf = sl_match_select_pattern_cast(si);
        let l = sp_lhs;
        let rr = sp_rhs;
        let ordered = sp_ordered;
        let castop = sl_cast_op;
        if spf != SPF_UNKNOWN {
            let spf2 = match_select_pattern_v(l, 0);
            if spf2 != SPF_UNKNOWN {
                r = fold_spf_of_spf(l, spf2, sp_lhs, sp_rhs, si, spf, rr);
                if r >= 0 { return r; }
            }
            let spf3 = match_select_pattern_v(rr, 0);
            if spf3 != SPF_UNKNOWN {
                r = fold_spf_of_spf(rr, spf3, sp_lhs, sp_rhs, si, spf, l);
                if r >= 0 { return r; }
            }
        }
        if spf_is_minmax(spf) {
            let cast_needed = vals[l].ty != selty;
            let cl = op(condv, 0);
            let cr = op(condv, 1);
            if cast_needed || (is_fp_or_fp_vec(vals[l].ty) && ((cl != l && cl != rr) || (cr != l && cr != rr))) {
                let mp = sl_minmax_pred(spf, ordered);
                var cmp: i32 = -1;
                if mp >= 32 {
                    drop_poison_generating_annotations_for_spf(condv, l, rr);
                    cmp = icb_icmp(mp, l, rr, "");
                } else {
                    cmp = ao_fcmp_fmf(mp, l, rr, sl_fmf(condv), "");
                }
                let ns = icb_select(cmp, l, rr, sl_name(si, ""), si);
                if !cast_needed { return ic_replace_inst_uses_with(si, ns); }
                let nc = icb_cast(castop, ns, selty, "");
                return ic_replace_inst_uses_with(si, nc);
            }
        }
    }
    if is_phi_inst(condv) {
        r = fold_op_into_phi(si, condv, false);
        if r >= 0 { return r; }
    }
    if is_select_inst(tv) && vals[op(tv, 0)].ty == condty {
        let tsi = tv;
        let imp = implied_condition_v(condv, op(tsi, 0), true, 0);
        if imp >= 0 { return ic_replace_operand(si, 1, if imp == 1 { op(tsi, 1) } else { op(tsi, 2) }); }
        if has_one_use(tsi) {
            var and: i32 = -1;
            var other: i32 = -1;
            if op(tsi, 2) == fv {
                and = icb_select(condv, op(tsi, 0), c_null(vals[op(tsi, 0)].ty), "", si);
                other = op(tsi, 1);
            } else if op(tsi, 1) == fv {
                let inv = icb_not(op(tsi, 0), "");
                and = icb_select(condv, inv, c_null(vals[inv].ty), "", si);
                other = op(tsi, 2);
            }
            if and >= 0 && other >= 0 {
                ic_replace_operand(si, 0, and);
                ic_replace_operand(si, 1, other);
                sl_set_unknown_branch_weights(si);
                return si;
            }
        }
    }
    if is_select_inst(fv) && vals[op(fv, 0)].ty == condty {
        let fsi = fv;
        let imp = implied_condition_v(condv, op(fsi, 0), false, 0);
        if imp >= 0 { return ic_replace_operand(si, 2, if imp == 1 { op(fsi, 1) } else { op(fsi, 2) }); }
        if has_one_use(fsi) {
            var or: i32 = -1;
            var other: i32 = -1;
            if op(fsi, 1) == tv {
                or = icb_select(condv, c_all_ones(vals[op(fsi, 0)].ty), op(fsi, 0), "", si);
                other = op(fsi, 2);
            } else if op(fsi, 2) == tv {
                let inv = icb_not(op(fsi, 0), "");
                or = icb_select(condv, c_all_ones(vals[inv].ty), inv, "", si);
                other = op(fsi, 1);
            }
            if or >= 0 && other >= 0 {
                ic_replace_operand(si, 0, or);
                ic_replace_operand(si, 2, other);
                sl_set_unknown_branch_weights(si);
                return si;
            }
        }
    }
    if one_use(tv) && is_binop_inst(tv) && !sl_is_int_div_rem(iop(tv)) {
        let tb = tv;
        let s0 = op(tb, 0);
        if is_select_inst(s0) && op(s0, 0) == condv {
            ic_replace_operand(tb, 0, op(s0, 1));
            icw_push(tb);
            return si;
        }
        let s1 = op(tb, 1);
        if is_select_inst(s1) && op(s1, 0) == condv {
            ic_replace_operand(tb, 1, op(s1, 1));
            icw_push(tb);
            return si;
        }
    }
    if one_use(fv) && is_binop_inst(fv) && !sl_is_int_div_rem(iop(fv)) {
        let fb = fv;
        let s0 = op(fb, 0);
        if is_select_inst(s0) && op(s0, 0) == condv {
            ic_replace_operand(fb, 0, op(s0, 2));
            icw_push(fb);
            return si;
        }
        let s1 = op(fb, 1);
        if is_select_inst(s1) && op(s1, 0) == condv {
            ic_replace_operand(fb, 1, op(s1, 2));
            icw_push(fb);
            return si;
        }
    }
    let notc = m_not(condv);
    if notc >= 0 && !should_avoid_absorbing_not_into_select(si) {
        ic_replace_operand(si, 0, notc);
        cu_use_swap(vals[si].ops + 1, vals[si].ops + 2);
        cu_swap_prof_metadata(si);
        return si;
    }
    r = fold_vector_select(si);
    if r >= 0 { return r; }
    if !ty_is_vector(condty) {
        kb_cxt = si;
        if ac_ready() {
            kb_cxt = si;
            let k = kb_compute_all(condv, 0);
            if ap_is_one(k.o) { return ic_replace_inst_uses_with(si, tv); }
            if ap_is_one(k.z) { return ic_replace_inst_uses_with(si, fv); }
        }
    }
    r = fold_select_cmp_bitcasts(si);
    if r >= 0 { return r; }
    v = fold_select_cmpxchg(si);
    if v >= 0 { return ic_replace_inst_uses_with(si, v); }
    r = fold_select_binop_identity(si);
    if r >= 0 { return r; }
    r = fold_select_funnel_shift(si);
    if r >= 0 { return r; }
    r = fold_select_to_copysign(si);
    if r >= 0 { return r; }
    r = fold_select_to_phi(si);
    if r >= 0 { return ic_replace_inst_uses_with(si, r); }
    v = fold_round_up_integer_with_pow2_alignment(si);
    if v >= 0 { return ic_replace_inst_uses_with(si, v); }
    v = fold_select_into_add_constant(si);
    if v >= 0 { return ic_replace_inst_uses_with(si, v); }
    fn masked_ld(v: i32) -> bool { let id = inst_iid(v); id == IID_masked_load || id == IID_masked_gather }
    fn undef_or_zero(v: i32) -> bool { m_undef(v) || m_zero(v) }
    if m_zero(fv) && masked_ld(tv) && op(tv, 1) == condv && undef_or_zero(op(tv, 2)) {
        if is_undef_val(op(tv, 2)) { set_op(tv, 2, fv); }
        return ic_replace_inst_uses_with(si, tv);
    }
    if m_zero(tv) && masked_ld(fv) && undef_or_zero(op(fv, 2)) && condty == vals[op(fv, 1)].ty {
        let mask = op(fv, 1);
        let a = simplify_and(condv, mask, sq_at(si), RECURSION_LIMIT);
        if a >= 0 && m_zero(a) {
            if is_undef_val(op(fv, 2)) { set_op(fv, 2, tv); }
            return ic_replace_inst_uses_with(si, fv);
        }
    }
    r = fold_select_of_symmetric_select(si);
    if r >= 0 { return r; }
    r = fold_nested_selects(si);
    if r >= 0 { return r; }
    if sink_not_into_other_hand_of_logical_op(si) { return si; }
    r = fold_bit_ceil(si);
    if r >= 0 { return r; }
    r = fold_select_to_cmp(si);
    if r >= 0 { return r; }
    r = fold_select_equality_test(si);
    if r >= 0 { return r; }
    if bo(condv, OP_AND) {
        let a = op(condv, 0); let b = op(condv, 1);
        r = sl_fold_select_with_and_or_cond(si, true, a, b);
        if r >= 0 { return r; }
        r = sl_fold_select_with_and_or_cond(si, true, b, a);
        if r >= 0 { return r; }
    } else if bo(condv, OP_OR) {
        let a = op(condv, 0); let b = op(condv, 1);
        r = sl_fold_select_with_and_or_cond(si, false, a, b);
        if r >= 0 { return r; }
        r = sl_fold_select_with_and_or_cond(si, false, b, a);
        if r >= 0 { return r; }
    } else {
        if m_logical(condv, true) {
            let a = lg_a; let b = lg_b;
            r = sl_fold_select_with_and_or_cond(si, true, a, b);
            if r >= 0 { return r; }
        } else if m_logical(condv, false) {
            let a = lg_a; let b = lg_b;
            r = sl_fold_select_with_and_or_cond(si, false, a, b);
            if r >= 0 { return r; }
        }
    }
    if condty == selty && ao_is_known_inversion(fv, tv) { return ic_new_binop(OP_XOR, condv, fv); }
    if ty_is_int(selty) && (!is_constant(tv) || !is_constant(fv)) {
        kb_cc_aff.resize(0);
        var aff: i32[>..<] = [];
        dc_affected_by_condition(condv, aff);
        for a in aff { if !kb_cc_has(a) { kb_cc_aff.push(a); } }
        sl_aff.resize(0);
        for a in kb_cc_aff { sl_aff.push(a); }
        if kb_cc_aff.len > 0 {
            if !is_constant(tv) && has_affected_value(tv, 0) {
                kb_cxt = si;
                kb_cc_cond = condv;
                kb_cc_invert = false;
                let k = kb_compute_all(tv, 0);
                kb_cc_cond = -1;
                if kb_is_constant(k) { return ic_replace_operand(si, 1, c_int_ap(selty, k.o)); }
            }
            if !is_constant(fv) && has_affected_value(fv, 0) {
                kb_cxt = si;
                kb_cc_cond = condv;
                kb_cc_invert = true;
                let k = kb_compute_all(fv, 0);
                kb_cc_cond = -1;
                kb_cc_invert = false;
                if kb_is_constant(k) { return ic_replace_operand(si, 2, c_int_ap(selty, k.o)); }
            }
        }
    }
    if is_inst_op(condv, OP_TRUNC) && op_nuw(condv) && !is_constant(op(condv, 0)) {
        let t = op(condv, 0);
        if tv == t { return ic_replace_operand(si, 1, c_int_ty(vals[tv].ty, 1)); }
        if fv == t { return ic_replace_operand(si, 2, c_int_ty(vals[fv].ty, 0)); }
    }
    if is_inst_op(condv, OP_TRUNC) && op_nsw(condv) && !is_constant(op(condv, 0)) {
        let t = op(condv, 0);
        if tv == t { return ic_replace_operand(si, 1, c_all_ones(vals[tv].ty)); }
        if fv == t { return ic_replace_operand(si, 2, c_int_ty(vals[fv].ty, 0)); }
    }
    if is_inst_op(condv, OP_TRUNC) && vals[op(condv, 0)].ty == selty {
        let t = op(condv, 0);
        if m_zero(fv) && implies_poison(tv, condv) {
            kb_cxt = si;
            if kb_max_active_bits(kb_compute_all(tv, 0)) == 1 { return ic_new_binop(OP_AND, t, tv); }
        }
        if op_nuw(condv) && m_one(tv) && implies_poison(fv, condv) {
            kb_cxt = si;
            if kb_max_active_bits(kb_compute_all(fv, 0)) == 1 { return ic_new_binop(OP_OR, t, fv); }
        }
    }
    if one_use(tv) && inst_iid(tv) == IID_masked_load && op(tv, 1) == condv {
        let ld = tv;
        if dt_value_dominates_inst(fv, ld) {
            icb_set_insert_point(ld);
            let ml = sl_create_masked_load(vals[tv].ty, op(ld, 0), sl_param_align0(ld), condv, fv);
            return ic_replace_inst_uses_with(si, ml);
        }
    }
    let bw = ty_scalar_bits(selty);
    if is_inst_op(condv, OP_ICMP) {
        let p = inst_pred(condv);
        let cl = op(condv, 0);
        let cr = op(condv, 1);
        fn ashr_sign(v: i32, x: i32, bw: i64) -> bool { bo(v, OP_ASHR) && op(v, 0) == x && m_specific_int(op(v, 1), (bw - 1) as u64) }
        if (p == P_SLT && m_one(cr) && ashr_sign(tv, cl, bw) && m_one(fv)) ||
           (p == P_SGT && m_zero(cr) && m_one(tv) && ashr_sign(fv, cl, bw)) {
            let z = c_int_ty(selty, 0);
            return ic_new_intrinsic(IID_scmp, [selty as i32, selty as i32], [cl, z]);
        }
    }
    return -1;
}

// IRBuilder::CreateBinaryIntrinsic(ID, LHS, RHS, FMFSource)
fn sl_binary_intrinsic_fmf(id: i64, a: i32, b: i32, fmf: u8) -> i32 {
    let sv = icb_fmf;
    icb_fmf = fmf;
    let r = icb_binary_intrinsic(id, a, b, "");
    icb_fmf = sv;
    return r;
}
fn sl_set_minmax_fmf(bi: i32, fc: i32) {
    let ii = inst_of(bi);
    if (sl_fmf(fc) & FMF_NINF) != 0 { insts[ii].fmf |= FMF_NINF; } else { insts[ii].fmf &= ~FMF_NINF; }
    insts[ii].fmf |= FMF_NSZ | FMF_NNAN;
}

// the SelectGepWithBase lambda of visitSelectInst
fn sl_select_gep_with_base(si: i32, gep: i32, base: i32, swap: bool) -> i32 {
    let ptr = op(gep, 0);
    if nops(gep) != 2 || ptr != base || !has_one_use(gep) { return -1; }
    let idx = op(gep, 1);
    let condv = op(si, 0);
    if ty_is_vector(vals[condv].ty) && !ty_is_vector(vals[idx].ty) { return -1; }
    let et = gep_src_ty(gep);
    var nt = idx;
    var nf = c_null(vals[idx].ty);
    if swap { let t = nt; nt = nf; nf = t; }
    let ns = icb_select(condv, nt, nf, sl_name(si, ".idx"), si);
    let g = create_inst(OP_GEP, gep_ret_type(ptr, [ns]), [ptr, ns]);
    insts[inst_of(g)].ty2 = et;
    insts[inst_of(g)].flags = gep_flags(gep);
    return g;
}

// the FoldSelectWithAndOrCond lambda of visitSelectInst
fn sl_fold_select_with_and_or_cond(si: i32, is_and: bool, a: i32, b: i32) -> i32 {
    let tv = op(si, 1);
    let fv = op(si, 2);
    let v = simplify_select(b, tv, fv, sl_fmf(si), sq_at(si), RECURSION_LIMIT);
    if v >= 0 {
        let nt = if is_and { v } else { tv };
        let nf = if is_and { fv } else { v };
        var mdfrom: i32 = -1;
        if nt == tv && nf == fv { mdfrom = si; }
        if mdfrom >= 0 { return ic_new_select_md_all(a, nt, nf, si); }
        return ic_new_select(a, nt, nf);
    }
    if has_one_use(op(si, 0)) && is_int_or_int_vec(vals[si].ty) {
        if is_inst_op(b, OP_ICMP) {
            let cv = canonicalize_spf(b, tv, fv);
            if cv >= 0 { return ic_new_select_md_all(a, if is_and { cv } else { tv }, if is_and { fv } else { cv }, si); }
        }
    }
    return -1;
}

// CallBase::getParamAlign(0).valueOrOne() as an attribute value
fn sl_param_align0(ci: i32) -> u64 {
    let a = aset_int(alist_param(insts[inst_of(ci)].attrs, 0), AK_Alignment);
    return if a == 0 { 1 } else { a };
}
// IRBuilder::CreateMaskedLoad(Ty, Ptr, Alignment, Mask, PassThru)
fn sl_create_masked_load(ty: i32, ptr: i32, align: u64, mask: i32, pass: i32) -> i32 {
    let pty = vals[ptr].ty;
    let c = ic_new_intrinsic(IID_masked_load, [ty, pty], [ptr, mask, pass]);
    let ii = inst_of(c);
    insts[ii].attrs = alist_set_param(insts[ii].attrs, 0, aset_get([attr_int(AK_Alignment, align)]));
    return icb_insert(c, "");
}

// ICmpInst::isLT / isGT (strict predicates only)
fn sl_is_lt(p: i64) -> bool { p == P_ULT || p == P_SLT }
fn sl_is_gt(p: i64) -> bool { p == P_UGT || p == P_SGT }
