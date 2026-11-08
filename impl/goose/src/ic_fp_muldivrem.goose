// InstCombine for fmul, fdiv, frem: port of llvm/lib/Transforms/InstCombine/InstCombineMulDivRem.cpp (foldFPSignBitOps,
// foldPowiReassoc, getFSqrtDivOptPattern, isFSqrtDivToFMulLegal, foldFMulReassoc, visitFMul,
// foldFDivConstantDivisor, foldFDivConstantDividend, foldFDivPowDivisor, foldFDivSqrtDivisor,
// convertFSqrtDivIntoFMul, visitFDiv, visitFRem; the FP half of foldMulSelectToNegate is in ic_muldivrem.goose).
namespace ic;
import std;
import gen_tli;
import build_libcalls;
import simplify_libcalls_fp;
import ic_compares;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import constfold;
import cfold;
import pm;
import vt;
import overflow;
import instsimplify;
import apint;
import apfloat;
import fpu;
import ic;
import ic_builder;
import ic_common;
import ic_muldivrem;
import ic_fp_addsub;
import ic_demanded_fp;

fn is_sqrt(v: i32) -> bool { is_intr(v, IID_sqrt) }

// foldFPSignBitOps(I) (fmul or fdiv)
fn fold_fp_sign_bit_ops(i: i32) -> i32 {
    let o = iop(i);
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    // -X * -Y --> X * Y ; -X / -Y --> X / Y
    let x0 = m_fneg(op0);
    let y0 = m_fneg(op1);
    if x0 >= 0 && y0 >= 0 { return ic_new_fbinop_fmf(o, x0, y0, fmf_of(i)); }
    // fabs(X) * fabs(X) -> X * X
    if op0 == op1 && is_intr(op0, IID_fabs) { let x = op(op0, 0); return ic_new_fbinop_fmf(o, x, x, fmf_of(i)); }
    // fabs(X) * fabs(Y) --> fabs(X * Y)
    if is_intr(op0, IID_fabs) && is_intr(op1, IID_fabs) && (has_one_use(op0) || has_one_use(op1)) {
        let xy = icb_fbinop_fmf(o, op(op0, 0), op(op1, 0), fmf_of(i), "");
        var nm: u8[>..] = []; nm.append(val_name(i));
        let fa = icb_unary_intrinsic_fmf(IID_fabs, xy, fmf_of(i), nm);
        return ic_replace_inst_uses_with(i, fa);
    }
    return -1;
}

// createPowiExpr of foldPowiReassoc
fn create_powi_expr(i: i32, x: i32, y: i32, z: i32) -> i32 {
    let yz = icb_add_nw(y, z, "", false, true);
    return icb_intrinsic_fmf(IID_powi, [vals[x].ty as i32, vals[yz].ty], [x, yz], fmf_of(i), "");
}
fn is_reassoc_powi(v: i32) -> bool { is_intr(v, IID_powi) && allow_reassoc(v) }
// Instruction::isOnlyUserOfAnyOperand
fn is_only_user_of_any_operand(i: i32) -> bool {
    for k in nops(i) { if has_one_user(op(i, k)) { return true; } }
    return false;
}

// foldPowiReassoc(I)
fn fold_powi_reassoc(i: i32) -> i32 {
    let o = iop(i);
    // powi(X, Y) * X --> powi(X, Y+1)
    if o == OP_FMUL {
        for k in 2 {
            let p = op(i, k);
            if one_use(p) && is_reassoc_powi(p) && op(i, 1 - k) == op(p, 0) {
                let x = op(p, 0); let y = op(p, 1);
                let one = c_int_ty(vals[y].ty, 1);
                if will_not_overflow_signed_add(y, one, i) { return ic_replace_inst_uses_with(i, create_powi_expr(i, x, y, one)); }
                break;
            }
        }
    }
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    // powi(x, y) * powi(x, z) -> powi(x, y + z)
    if o == OP_FMUL && is_only_user_of_any_operand(i) && is_reassoc_powi(op0) && is_reassoc_powi(op1) && op(op1, 0) == op(op0, 0) {
        let x = op(op0, 0); let y = op(op0, 1); let z = op(op1, 1);
        if vals[y].ty == vals[z].ty && will_not_overflow_signed_add(y, z, i) { return ic_replace_inst_uses_with(i, create_powi_expr(i, x, y, z)); }
    }
    if o == OP_FDIV && has_reassoc(i) && has_nnan(i) {
        // powi(X, Y) / X --> powi(X, Y-1)
        if one_use(op0) && is_reassoc_powi(op0) && op(op0, 0) == op1 {
            let y = op(op0, 1);
            if will_not_overflow_signed_sub(y, c_int_ty(vals[y].ty, 1), i) {
                return ic_replace_inst_uses_with(i, create_powi_expr(i, op1, y, c_all_ones(vals[y].ty)));
            }
        }
        // powi(X, Y) / (X * Z) --> powi(X, Y-1) / Z
        if one_use(op0) && is_reassoc_powi(op0) && allow_reassoc(op1) && is_fmul(op1) {
            let x = op(op0, 0); let y = op(op0, 1);
            var z: i32 = -1;
            if op(op1, 0) == x { z = op(op1, 1); } else if op(op1, 1) == x { z = op(op1, 0); }
            if z >= 0 && will_not_overflow_signed_sub(y, c_int_ty(vals[y].ty, 1), i) {
                let np = create_powi_expr(i, x, y, c_all_ones(vals[y].ty));
                return ic_new_fbinop_fmf(OP_FDIV, np, z, fmf_of(i));
            }
        }
    }
    return -1;
}

// getFSqrtDivOptPattern / isFSqrtDivToFMulLegal: R1, R2 in insertion order (SmallPtrSet<_, 2> in small mode)
var fsq_r1: i32[>..<];
var fsq_r2: i32[>..<];
fn fsq_insert(r1: bool, v: i32) {
    if r1 { for x in fsq_r1 { if x == v { return; } } fsq_r1.push(v); }
    else { for x in fsq_r2 { if x == v { return; } } fsq_r2.push(v); }
}
fn get_fsqrt_div_opt_pattern(d: i32) -> bool {
    fsq_r1.resize(0);
    fsq_r2.resize(0);
    if is_fdiv(d) && (m_fp_one(op(d, 0)) || m_specific_fp(op(d, 0), -1.0)) && is_sqrt(op(d, 1)) {
        let a = op(op(d, 1), 0);
        var u = vals[d].first_use;
        while u >= 0 {
            let us = uses[u].user;
            if is_fmul(us) && op(us, 0) == d && op(us, 1) == d { fsq_insert(true, us); }
            u = uses[u].next;
        }
        let ci = op(d, 1);
        u = vals[ci].first_use;
        while u >= 0 {
            let us = uses[u].user;
            if is_fdiv(us) && op(us, 0) == a && is_sqrt(op(us, 1)) && op(op(us, 1), 0) == a { fsq_insert(false, us); }
            u = uses[u].next;
        }
    }
    return fsq_r1.len > 0 && fsq_r2.len > 0;
}
fn is_fsqrt_div_to_fmul_legal(x: i32) -> bool {
    if !get_fsqrt_div_opt_pattern(x) { return false; }
    let bbx = inst_parent(x);
    let bbr1 = inst_parent(fsq_r1[0]);
    let bbr2 = inst_parent(fsq_r2[0]);
    let fsqrt = op(x, 1);
    if !has_reassoc(fsqrt) || !has_nnan(fsqrt) || !has_nsz(fsqrt) || !has_ninf(fsqrt) { return false; }
    if !has_reassoc(x) || !has_arcp(x) || !has_ninf(x) { return false; }
    if bbx != bbr1 && bbx != bbr2 { return false; }
    for r in fsq_r1 { if inst_parent(r) != bbr1 || !has_reassoc(r) { return false; } }
    for r in fsq_r2 { if !(inst_parent(r) == bbr2 && has_reassoc(r)) { return false; } }
    return true;
}
// MDNode::getMostGenericFPMath(A, B)
fn most_generic_fpmath(a: i32, b: i32) -> i32 {
    if a < 0 || b < 0 { return -1; }
    if a == b { return a; }
    ic_not_ported("MDNode::getMostGenericFPMath of two different !fpmath nodes");
    return -1;
}
// convertFSqrtDivIntoFMul(CI, X, R1, R2, Builder, IC)
fn convert_fsqrt_div_into_fmul(ci: i32, x: i32) -> i32 {
    if fsq_r1.len > 2 || fsq_r2.len > 2 { ic_not_ported("convertFSqrtDivIntoFMul with more than two instructions in R1 or R2 (SmallPtrSet order)"); }
    var r1: i32[>..<] = [];
    var r2: i32[>..<] = [];
    for v in fsq_r1 { r1.push(v); }
    for v in fsq_r2 { r2.push(v); }
    icb_set_insert_point(x);
    let fpk = md_kind_id("fpmath");
    let sq_op = op(ci, 0);
    let fdiv = icb_fbinop_fmf(OP_FDIV, c_fpd(vals[x].ty, 1.0), sq_op, icb_fmf, "");
    var r1md = inst_get_md(r1[0], fpk);
    var r1fmf = fmf_of(r1[0]);
    for r in r1 {
        r1md = most_generic_fpmath(r1md, inst_get_md(r, fpk));
        r1fmf &= fmf_of(r);
        ic_replace_inst_uses_with(r, fdiv);
        ic_erase(r);
    }
    if is_inst(fdiv) { inst_set_md(fdiv, fpk, r1md); set_fmf(fdiv, r1fmf); }
    let fsqrt = inst_clone(ci);
    inst_insert_before(fsqrt, ci);
    var r2md = inst_get_md(r2[0], fpk);
    var r2fmf = fmf_of(r2[0]);
    for r in r2 {
        r2md = most_generic_fpmath(r2md, inst_get_md(r, fpk));
        r2fmf &= fmf_of(r);
        ic_replace_inst_uses_with(r, fsqrt);
        ic_erase(r);
    }
    inst_set_md(fsqrt, fpk, r2md);
    set_fmf(fsqrt, r2fmf);
    var fm: i32 = -1;
    if is_fdiv(x) && m_specific_fp(op(x, 0), -1.0) && op(x, 1) == ci {
        let m = icb_fbinop_fmf(OP_FMUL, fdiv, fsqrt, icb_fmf, "");
        fm = icb_fneg_fmf(m, icb_fmf, "");
    } else {
        fm = icb_fbinop_fmf(OP_FMUL, fdiv, fsqrt, icb_fmf, "");
    }
    ic_copy_all_md(fm, x);
    set_fmf(fm, fmf_intersect_rewrite(r1fmf, r2fmf) | fmf_union_value(r1fmf, r2fmf));
    return ic_replace_inst_uses_with(x, fm);
}

// foldFMulReassoc(I)
fn fold_fmul_reassoc(i: i32) -> i32 {
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    // Reassociate constant RHS with another constant to form constant expression.
    if is_constant(op1) && c_is_finite_non_zero_fp(op1) && allow_reassoc(op0) && is_binop_inst(op0) {
        let c = op1;
        let fmf = fmf_of(i) & fmf_of(op0);
        // (C1 / X) * C --> (C * C1) / X
        if one_use(op0) && is_fdiv(op0) && is_constant(op(op0, 0)) {
            let cc1 = cf_fold_binop_operands(OP_FMUL, c, op(op0, 0));
            if cc1 >= 0 && c_is_normal_fp(cc1) { return ic_new_fbinop_fmf(OP_FDIV, cc1, op(op0, 1), fmf); }
        }
        if is_fdiv(op0) && is_constant(op(op0, 1)) {
            let x = op(op0, 0); let c1 = op(op0, 1);
            // (X / C1) * C --> X * (C / C1)
            let cd = cf_fold_binop_operands(OP_FDIV, c, c1);
            if cd >= 0 && c_is_normal_fp(cd) { return ic_new_fbinop_fmf(OP_FMUL, x, cd, fmf); }
            // (X / C1) * C --> X / (C1 / C)
            let c1d = cf_fold_binop_operands(OP_FDIV, c1, c);
            if c1d >= 0 && has_one_use(op0) && c_is_normal_fp(c1d) { return ic_new_fbinop_fmf(OP_FDIV, x, c1d, fmf); }
        }
        // (X + C1) * C --> (X * C) + (C * C1)
        if one_use(op0) && is_fadd(op0) && is_constant(op(op0, 1)) {
            let cc1 = cf_fold_binop_operands(OP_FMUL, c, op(op0, 1));
            if cc1 >= 0 {
                let xc = icb_fbinop_fmf(OP_FMUL, op(op0, 0), c, fmf, "");
                return ic_new_fbinop_fmf(OP_FADD, xc, cc1, fmf);
            }
        }
        // (C1 - X) * C --> (C * C1) - (X * C)
        if one_use(op0) && is_fsub(op0) && is_constant(op(op0, 0)) {
            let cc1 = cf_fold_binop_operands(OP_FMUL, c, op(op0, 0));
            if cc1 >= 0 {
                let xc = icb_fbinop_fmf(OP_FMUL, op(op0, 1), c, fmf, "");
                return ic_new_fbinop_fmf(OP_FSUB, cc1, xc, fmf);
            }
        }
    }
    // Sink division: (X / Y) * Z --> (X * Z) / Y
    for k in 2 {
        let d = op(i, k);
        if allow_reassoc(d) && one_use(d) && is_fdiv(d) {
            let z = op(i, 1 - k);
            // DivOp = (Z == Op0) ? Op1 : Op0
            let divop = if z == op0 { op1 } else { op0 };
            let fmf = fmf_of(i) & fmf_of(divop);
            if (fmf & FMF_REASSOC) != 0 {
                let nm = icb_fbinop_fmf(OP_FMUL, op(d, 0), z, fmf, "");
                return ic_new_fbinop_fmf(OP_FDIV, nm, op(d, 1), fmf);
            }
            break;
        }
    }
    // sqrt(X) * sqrt(Y) -> sqrt(X * Y)
    if has_nnan(i) && one_use(op0) && is_sqrt(op0) && one_use(op1) && is_sqrt(op1) {
        let xy = icb_fbinop_fmf(OP_FMUL, op(op0, 0), op(op1, 0), fmf_of(i), "");
        let s = icb_unary_intrinsic_fmf(IID_sqrt, xy, fmf_of(i), "");
        return ic_replace_inst_uses_with(i, s);
    }
    // 1.0/sqrt(X) * X -> X/sqrt(X) ; X * 1.0/sqrt(X) -> X/sqrt(X)
    if has_nsz(i) && is_fdiv(op0) && m_specific_fp(op(op0, 0), 1.0) && is_sqrt(op(op0, 1)) && op1 == op(op(op0, 1), 0) {
        return ic_new_fbinop_fmf(OP_FDIV, op1, op(op0, 1), fmf_of(i));
    }
    if has_nsz(i) && is_fdiv(op1) && m_specific_fp(op(op1, 0), 1.0) && is_sqrt(op(op1, 1)) && op0 == op(op(op1, 1), 0) {
        return ic_new_fbinop_fmf(OP_FDIV, op0, op(op1, 1), fmf_of(i));
    }
    if has_nnan(i) && has_nsz(i) && op0 == op1 && num_uses(op0) == 2 {
        // (X / sqrt(Y)) * (X / sqrt(Y)) --> (X * X) / Y
        if is_fdiv(op0) && is_sqrt(op(op0, 1)) {
            let x = op(op0, 0);
            let xx = icb_fbinop_fmf(OP_FMUL, x, x, fmf_of(i), "");
            return ic_new_fbinop_fmf(OP_FDIV, xx, op(op(op0, 1), 0), fmf_of(i));
        }
        // (sqrt(Y) / X) * (sqrt(Y) / X) --> Y / (X * X)
        if is_fdiv(op0) && is_sqrt(op(op0, 0)) {
            let x = op(op0, 1);
            let xx = icb_fbinop_fmf(OP_FMUL, x, x, fmf_of(i), "");
            return ic_new_fbinop_fmf(OP_FDIV, op(op(op0, 0), 0), xx, fmf_of(i));
        }
    }
    // pow(X, Y) * X --> pow(X, Y+1)
    for k in 2 {
        let p = op(i, k);
        if one_use(p) && is_intr(p, IID_pow) && op(i, 1 - k) == op(p, 0) {
            let y1 = icb_fbinop_fmf(OP_FADD, op(p, 1), c_fpd(vals[i].ty, 1.0), fmf_of(i), "");
            let pw = icb_binary_intrinsic_fmf(IID_pow, op(p, 0), y1, fmf_of(i), "");
            return ic_replace_inst_uses_with(i, pw);
        }
    }
    let fp = fold_powi_reassoc(i);
    if fp >= 0 { return fp; }
    if is_only_user_of_any_operand(i) {
        // pow(X, Y) * pow(X, Z) -> pow(X, Y + Z)
        if is_intr(op0, IID_pow) && is_intr(op1, IID_pow) && op(op1, 0) == op(op0, 0) {
            let yz = icb_fbinop_fmf(OP_FADD, op(op0, 1), op(op1, 1), fmf_of(i), "");
            return ic_replace_inst_uses_with(i, icb_binary_intrinsic_fmf(IID_pow, op(op0, 0), yz, fmf_of(i), ""));
        }
        // pow(X, Y) * pow(Z, Y) -> pow(X * Z, Y)
        if is_intr(op0, IID_pow) && is_intr(op1, IID_pow) && op(op1, 1) == op(op0, 1) {
            let xz = icb_fbinop_fmf(OP_FMUL, op(op0, 0), op(op1, 0), fmf_of(i), "");
            return ic_replace_inst_uses_with(i, icb_binary_intrinsic_fmf(IID_pow, xz, op(op0, 1), fmf_of(i), ""));
        }
        // exp(X) * exp(Y) -> exp(X + Y) ; exp2(X) * exp2(Y) -> exp2(X + Y)
        for idk in 2 {
            let id: i32 = if idk == 0 { IID_exp as i32 } else { IID_exp2 as i32 };
            if is_intr(op0, id) && is_intr(op1, id) {
                let xy = icb_fbinop_fmf(OP_FADD, op(op0, 0), op(op1, 0), fmf_of(i), "");
                return ic_replace_inst_uses_with(i, icb_unary_intrinsic_fmf(id, xy, fmf_of(i), ""));
            }
        }
    }
    // (X*Y) * X => (X*X) * Y where Y != X
    if one_use(op0) && is_fmul(op0) {
        var y: i32 = -1;
        if op(op0, 0) == op1 { y = op(op0, 1); } else if op(op0, 1) == op1 { y = op(op0, 0); }
        if y >= 0 && op1 != y {
            let xx = icb_fbinop_fmf(OP_FMUL, op1, op1, fmf_of(i), "");
            return ic_new_fbinop_fmf(OP_FMUL, xx, y, fmf_of(i));
        }
    }
    if one_use(op1) && is_fmul(op1) {
        var y: i32 = -1;
        if op(op1, 0) == op0 { y = op(op1, 1); } else if op(op1, 1) == op0 { y = op(op1, 0); }
        if y >= 0 && op0 != y {
            let xx = icb_fbinop_fmf(OP_FMUL, op0, op0, fmf_of(i), "");
            return ic_new_fbinop_fmf(OP_FMUL, xx, y, fmf_of(i));
        }
    }
    return -1;
}

fn visit_fmul(i: i32) -> i32 {
    let v0 = simplify_fmul(op(i, 0), op(i, 1), fmf_of(i), sq_at(i), RECURSION_LIMIT, EB_IGNORE, RM_NEAREST);
    if v0 >= 0 { return ic_replace_inst_uses_with(i, v0); }
    if simplify_assoc_or_comm(i) { return i; }
    let xv = fold_vector_binop(i);
    if xv >= 0 { return xv; }
    let ph = fold_binop_with_phi_operands(i);
    if ph >= 0 { return ph; }
    let fs = fold_binop_into_select_or_phi(i);
    if fs >= 0 { return fs; }
    let mn = fold_mul_select_to_negate(i);
    if mn >= 0 { return ic_replace_inst_uses_with(i, mn); }
    let sb = fold_fp_sign_bit_ops(i);
    if sb >= 0 { return sb; }
    let ic0 = fold_fbinop_of_int_casts(i);
    if ic0 >= 0 { return ic0; }
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    let ty = vals[i].ty;
    // X * -1.0 --> -X
    if m_specific_fp(op1, -1.0) { return ic_new_fneg_fmf(op0, fmf_of(i)); }
    // -X * C --> X * -C
    let nx = m_fneg(op0);
    if nx >= 0 && is_constant(op1) {
        let nc = cf_fneg(op1);
        if nc >= 0 { return ic_new_fbinop_fmf(OP_FMUL, nx, nc, fmf_of(i)); }
    }
    if has_nnan(i) && has_nsz(i) {
        // (uitofp bool X) * Y --> X ? Y : 0
        for k in 2 {
            let c = op(i, k);
            if is_inst_op(c, OP_UITOFP) && is_int_ty1(vals[op(c, 0)].ty) {
                let s = ic_new_select_unknown_prof(op(c, 0), op(i, 1 - k), c_fpd(ty, 0.0));
                set_fmf(s, fmf_of(i));
                return s;
            }
        }
    }
    let sv = simplify_selects_feeding_binop(i, op0, op1);
    if sv >= 0 { return ic_replace_inst_uses_with(i, sv); }
    if has_reassoc(i) {
        let r = fold_fmul_reassoc(i);
        if r >= 0 { return r; }
    }
    // log2(X * 0.5) * Y = log2(X) * Y - Y
    if is_fast(i) {
        var lg: i32 = -1;
        var x: i32 = -1;
        var y: i32 = -1;
        for k in 2 {
            let l = op(i, k);
            if one_use(l) && is_intr(l, IID_log2) {
                let m = op(l, 0);
                if one_use(m) && is_fmul(m) && m_specific_fp(op(m, 1), 0.5) { lg = l; x = op(m, 0); y = op(i, 1 - k); }
            }
        }
        if lg >= 0 {
            let l2 = icb_unary_intrinsic_fmf(IID_log2, x, fmf_of(i), "");
            let lxy = icb_fbinop_fmf(OP_FMUL, l2, y, fmf_of(i), "");
            return ic_new_fbinop_fmf(OP_FSUB, lxy, y, fmf_of(i));
        }
    }
    // FMUL recurrences starting with 0.0 (nnan nsz)
    {
        var pn: i32 = -1;
        if is_phi_inst(op0) { pn = op0; } else if is_phi_inst(op1) { pn = op1; }
        if pn >= 0 && match_simple_recurrence(pn) && rec_bo == i && has_nnan(i) && has_nsz(i) && m_zero(rec_start) {
            return ic_replace_inst_uses_with(i, rec_start);
        }
    }
    // minimum(X, Y) * maximum(X, Y) => X * Y
    for k in 2 {
        let mx = op(i, k);
        let mi = op(i, 1 - k);
        if !is_intr(mx, IID_maximum) { continue; }
        let x = op(mx, 0); let y = op(mx, 1);
        if is_intr(mi, IID_minimum) && ((op(mi, 0) == x && op(mi, 1) == y) || (op(mi, 0) == y && op(mi, 1) == x)) {
            let r = ic_new_fbinop_fmf(OP_FMUL, x, y, fmf_of(i));
            if !has_nnan(r) { set_fmf_bit(r, FMF_NINF, false); }
            return r;
        }
    }
    // tan(X) * cos(X) -> sin(X)
    if has_contract(i) {
        for k in 2 {
            let t = op(i, k);
            let c = op(i, 1 - k);
            if one_use(t) && is_intr(t, IID_tan) && one_use(c) && is_intr(c, IID_cos) && op(c, 0) == op(t, 0) {
                let s = icb_unary_intrinsic_fmf(IID_sin, op(t, 0), fmf_of(i), "");
                let md = inst_get_md(i, md_kind_id("fpmath"));
                if md >= 0 && is_inst(s) { inst_set_md(s, md_kind_id("fpmath"), md); }
                return ic_replace_inst_uses_with(i, s);
            }
        }
    }
    // X * ldexp(1.0, Y) -> ldexp(X, Y)
    if allow_reassoc(i) {
        for k in 2 {
            let l = op(i, 1 - k);
            if allow_reassoc(l) && one_use(l) && is_intr(l, IID_ldexp) && m_fp_one(op(l, 0)) {
                let x = op(i, k); let y = op(l, 1);
                return ic_replace_inst_uses_with(i, icb_intrinsic_fmf(IID_ldexp, [vals[x].ty as i32, vals[y].ty], [x, y], fmf_of(i), ""));
            }
        }
    }
    if simplify_demanded_instruction_fp_class(i) { return i; }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// fdiv

// IRBuilder<> B(&I) (ConstantFolder, default inserter: not added to the worklist)
fn irb_insert_before(iv: i32, pos: i32) -> i32 {
    inst_insert_before(iv, pos);
    ic_register_name(iv);
    let d = inst_get_md(pos, 0);
    if d >= 0 { inst_set_md(iv, 0, d); }
    return iv;
}

// foldFDivConstantDivisor(I)
fn fold_fdiv_constant_divisor(i: i32) -> i32 {
    let c = op(i, 1);
    if !is_constant(c) { return -1; }
    // -X / C --> X / -C
    let x = m_fneg(op(i, 0));
    if x >= 0 {
        let nc = cf_fneg(c);
        if nc >= 0 { return ic_new_fbinop_fmf(OP_FDIV, x, nc, fmf_of(i)); }
    }
    // nnan X / +0.0 -> copysign(inf, X) ; nnan nsz X / -0.0 -> copysign(inf, X)
    if has_nnan(i) && (m_pos_zero_fp(c) || (has_nsz(i) && m_any_zero_fp(c))) {
        let inf = c_fp_inf_ty(vals[i].ty, false);
        var cs: i32 = -1;
        let call = ic_new_intrinsic(IID_copysign, [vals[c].ty as i32], [inf, op(i, 0)]);
        set_fmf(call, fmf_of(i));
        cs = irb_insert_before(call, i);
        ic_take_name(cs, i);
        return ic_replace_inst_uses_with(i, cs);
    }
    if !(c_has_exact_inverse_fp(c) || (has_arcp(i) && c_is_normal_fp(c))) { return -1; }
    let rc = cf_fold_binop_operands(OP_FDIV, c_fpd(vals[i].ty, 1.0), c);
    if rc < 0 || !c_is_normal_fp(rc) { return -1; }
    return ic_new_fbinop_fmf(OP_FMUL, op(i, 0), rc, fmf_of(i));
}

// foldFDivConstantDividend(I)
fn fold_fdiv_constant_dividend(i: i32) -> i32 {
    let c = op(i, 0);
    if !is_constant(c) { return -1; }
    // C / -X --> -C / X
    let x0 = m_fneg(op(i, 1));
    if x0 >= 0 {
        let nc = cf_fneg(c);
        if nc >= 0 { return ic_new_fbinop_fmf(OP_FDIV, nc, x0, fmf_of(i)); }
    }
    if !has_reassoc(i) || !has_arcp(i) { return -1; }
    let o1 = op(i, 1);
    var nc: i32 = -1;
    var x: i32 = -1;
    if is_fmul(o1) && is_constant(op(o1, 1)) {
        x = op(o1, 0);
        nc = cf_fold_binop_operands(OP_FDIV, c, op(o1, 1));
    } else if is_fdiv(o1) && is_constant(op(o1, 1)) {
        x = op(o1, 0);
        nc = cf_fold_binop_operands(OP_FMUL, c, op(o1, 1));
    }
    if nc < 0 || !c_is_normal_fp(nc) { return -1; }
    return ic_new_fbinop_fmf(OP_FDIV, nc, x, fmf_of(i));
}

// foldFDivPowDivisor(I, Builder)
fn fold_fdiv_pow_divisor(i: i32) -> i32 {
    let op0 = op(i, 0);
    let ii = op(i, 1);
    if inst_iid(ii) == 0 || !has_one_use(ii) || !has_reassoc(i) || !has_arcp(i) { return -1; }
    let id = inst_iid(ii);
    var a0: i32 = -1;
    var a1: i32 = -1;
    if id == IID_pow {
        a0 = op(ii, 0);
        a1 = icb_fneg_fmf(op(ii, 1), fmf_of(i), "");
        let pw = icb_intrinsic_fmf(id, [vals[i].ty as i32], [a0, a1], fmf_of(i), "");
        return ic_new_fbinop_fmf(OP_FMUL, op0, pw, fmf_of(i));
    }
    if id == IID_powi {
        if !has_ninf(i) { return -1; }
        a0 = op(ii, 0);
        a1 = icb_neg(op(ii, 1), "", false);
        let pw = icb_intrinsic_fmf(id, [vals[i].ty as i32, vals[op(ii, 1)].ty], [a0, a1], fmf_of(i), "");
        return ic_new_fbinop_fmf(OP_FMUL, op0, pw, fmf_of(i));
    }
    if id == IID_exp || id == IID_exp2 {
        a0 = icb_fneg_fmf(op(ii, 0), fmf_of(i), "");
        let pw = icb_intrinsic_fmf(id, [vals[i].ty as i32], [a0], fmf_of(i), "");
        return ic_new_fbinop_fmf(OP_FMUL, op0, pw, fmf_of(i));
    }
    return -1;
}

// foldFDivSqrtDivisor(I, Builder): X / sqrt(Y / Z) -->  X * sqrt(Z / Y)
fn fold_fdiv_sqrt_divisor(i: i32) -> i32 {
    if !has_reassoc(i) || !has_arcp(i) { return -1; }
    let op0 = op(i, 0);
    let ii = op(i, 1);
    if !is_sqrt(ii) || !has_one_use(ii) || !has_reassoc(ii) || !has_arcp(ii) { return -1; }
    let d = op(ii, 0);
    if !is_inst(d) || !is_fdiv(d) { return -1; }
    if !has_reassoc(d) || !has_arcp(i) || !has_one_use(d) { return -1; }
    let sw = icb_fbinop_fmf(OP_FDIV, op(d, 1), op(d, 0), fmf_of(d), "");
    let ns = icb_unary_intrinsic_fmf(IID_sqrt, sw, fmf_of(ii), "");
    return ic_new_fbinop_fmf(OP_FMUL, op0, ns, fmf_of(i));
}

fn visit_fdiv(i: i32) -> i32 {
    let v0 = simplify_fdiv(op(i, 0), op(i, 1), fmf_of(i), sq_at(i), RECURSION_LIMIT, EB_IGNORE, RM_NEAREST);
    if v0 >= 0 { return ic_replace_inst_uses_with(i, v0); }
    let xv = fold_vector_binop(i);
    if xv >= 0 { return xv; }
    let ph = fold_binop_with_phi_operands(i);
    if ph >= 0 { return ph; }
    var r = fold_fdiv_constant_divisor(i);
    if r >= 0 { return r; }
    r = fold_fdiv_constant_dividend(i);
    if r >= 0 { return r; }
    r = fold_fp_sign_bit_ops(i);
    if r >= 0 { return r; }
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    if is_fsqrt_div_to_fmul_legal(i) {
        let d = convert_fsqrt_div_into_fmul(op(i, 1), i);
        if d >= 0 { return d; }
    }
    if is_constant(op0) && is_select_inst(op1) {
        r = fold_op_into_select(i, op1, false, false);
        if r >= 0 { return r; }
    }
    if is_constant(op1) && is_select_inst(op0) {
        r = fold_op_into_select(i, op0, false, false);
        if r >= 0 { return r; }
    }
    if has_reassoc(i) && has_arcp(i) {
        // (X / Y) / Z => X / (Y * Z)
        if one_use(op0) && is_fdiv(op0) && (!is_constant(op(op0, 1)) || !is_constant(op1)) {
            let yz = icb_fbinop_fmf(OP_FMUL, op(op0, 1), op1, fmf_of(i), "");
            return ic_new_fbinop_fmf(OP_FDIV, op(op0, 0), yz, fmf_of(i));
        }
        // Z / (X / Y) => (Y * Z) / X
        if one_use(op1) && is_fdiv(op1) && (!is_constant(op(op1, 1)) || !is_constant(op0)) {
            let yz = icb_fbinop_fmf(OP_FMUL, op(op1, 1), op0, fmf_of(i), "");
            return ic_new_fbinop_fmf(OP_FDIV, yz, op(op1, 0), fmf_of(i));
        }
        // Z / (1.0 / Y) => (Y * Z)
        if is_fdiv(op1) && m_specific_fp(op(op1, 0), 1.0) { return ic_new_fbinop_fmf(OP_FMUL, op(op1, 1), op0, fmf_of(i)); }
    }
    if has_reassoc(i) && has_one_use(op0) && has_one_use(op1) {
        // sin(X) / cos(X) -> tan(X) ; cos(X) / sin(X) -> 1/tan(X)
        let is_tan = is_intr(op0, IID_sin) && is_intr(op1, IID_cos) && op(op1, 0) == op(op0, 0);
        let is_cot = !is_tan && is_intr(op0, IID_cos) && is_intr(op1, IID_sin) && op(op1, 0) == op(op0, 0);
        if (is_tan || is_cot) && blc_has_float_fn(vals[i].ty, LF_tan, LF_tanf, LF_tanl) {
            // IRBuilder<> B(&I) with I's FMF: the new instructions are not added to the worklist
            let sp = icb_pos; let sb = icb_bb; let sd = icb_dl; let sf = icb_fmf;
            icb_set_insert_point(i);
            icb_fmf = fmf_of(i);
            let al = globs[glob_of(called_function(op0))].attrs;
            var res = icc_plain(emit_unary_float_fn_lf(op(op0, 0), LF_tan, LF_tanf, LF_tanl, al));
            if is_cot { res = icc_plain(icx_fbinop(OP_FDIV, c_fp_from_f64(vals[i].ty, 1.0), res, icb_fmf, "")); }
            icb_pos = sp; icb_bb = sb; icb_dl = sd; icb_fmf = sf;
            return ic_replace_inst_uses_with(i, res);
        }
    }
    // X / (X * Y) --> 1.0 / Y
    if has_nnan(i) && has_reassoc(i) && is_fmul(op1) {
        var y: i32 = -1;
        if op(op1, 0) == op0 { y = op(op1, 1); } else if op(op1, 1) == op0 { y = op(op1, 0); }
        if y >= 0 {
            ic_replace_operand(i, 0, c_fpd(vals[i].ty, 1.0));
            ic_replace_operand(i, 1, y);
            return i;
        }
    }
    // X / fabs(X) -> copysign(1.0, X) ; fabs(X) / X -> copysign(1.0, X)
    if has_nnan(i) && has_ninf(i) {
        var x: i32 = -1;
        if is_intr(op1, IID_fabs) && op(op1, 0) == op0 { x = op0; }
        else if is_intr(op0, IID_fabs) && op(op0, 0) == op1 { x = op1; }
        if x >= 0 {
            let v = icb_binary_intrinsic_fmf(IID_copysign, c_fpd(vals[i].ty, 1.0), x, fmf_of(i), "");
            return ic_replace_inst_uses_with(i, v);
        }
    }
    r = fold_fdiv_pow_divisor(i);
    if r >= 0 { return r; }
    r = fold_fdiv_sqrt_divisor(i);
    if r >= 0 { return r; }
    // pow(X, Y) / X --> pow(X, Y-1)
    if has_reassoc(i) && one_use(op0) && is_intr(op0, IID_pow) && op(op0, 0) == op1 {
        let y1 = icb_fbinop_fmf(OP_FADD, op(op0, 1), c_fpd(vals[i].ty, -1.0), fmf_of(i), "");
        let pw = icb_binary_intrinsic_fmf(IID_pow, op1, y1, fmf_of(i), "");
        return ic_replace_inst_uses_with(i, pw);
    }
    r = fold_powi_reassoc(i);
    if r >= 0 { return r; }
    return -1;
}

fn visit_frem(i: i32) -> i32 {
    let v0 = simplify_frem(op(i, 0), op(i, 1), fmf_of(i), sq_at(i), RECURSION_LIMIT, EB_IGNORE, RM_NEAREST);
    if v0 >= 0 { return ic_replace_inst_uses_with(i, v0); }
    let xv = fold_vector_binop(i);
    if xv >= 0 { return xv; }
    let ph = fold_binop_with_phi_operands(i);
    if ph >= 0 { return ph; }
    return -1;
}
