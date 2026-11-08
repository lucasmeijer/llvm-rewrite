// InstCombine shifts: port of llvm/lib/Transforms/InstCombine/InstCombineShifts.cpp (visitShl, visitLShr,
// visitAShr, commonShiftTransforms, FoldShiftByConstant, canEvaluateShifted/getShiftedValue,
// reassociateShiftAmtsOfTwoSameDirectionShifts, dropRedundantMaskingOfLeftShiftInput, foldShiftOfShiftedBinOp,
// foldLShrOverflowBit, setShiftFlags) and shouldChangeType / isDesirableIntType (InstructionCombining.cpp).
namespace ic;
import std;
import ir;
import irutil;
import instinfo;
import gen_iids;
import constfold;
import cfold;
import datalayout;
import pm;
import vt;
import knownbits;
import instsimplify;
import apint;
import ic;
import ic_builder;
import ic_common;
import ic_demanded;

let SS_LOSSY = 0;
let SS_UNSIGNED = 1;
let SS_SIGNED = 2;

// isDesirableIntType / shouldChangeType
fn is_desirable_int_type(w: i64) -> bool { w == 8 || w == 16 || w == 32 || dl_is_legal_integer(w) }
fn should_change_type_w(from: i64, to: i64) -> bool {
    let fl = from == 1 || dl_is_legal_integer(from);
    let tl = to == 1 || dl_is_legal_integer(to);
    if to < from && is_desirable_int_type(to) { return true; }
    if (fl || is_desirable_int_type(from)) && !tl { return false; }
    if !fl && !tl && to > from { return false; }
    return true;
}
fn should_change_type(from: i32, to: i32) -> bool {
    if !ty_is_int(from) || !ty_is_int(to) { return false; }
    return should_change_type_w(ty_bits(from), ty_bits(to));
}

fn is_shift_inst(v: i32) -> bool { is_inst(v) && is_shift_op(iop(v)) }
fn is_shr_inst(v: i32) -> bool { is_inst(v) && (iop(v) == OP_LSHR || iop(v) == OP_ASHR) }
fn m_zext_or_self(v: i32) -> i32 { let z = m_zext(v); if z >= 0 { z } else { v } }
fn c_int_u(ty: i32, x: u64) -> i32 { c_int_ty(ty, x) }

// canTryToConstantAddTwoShiftAmounts
fn can_try_to_constant_add_two_shift_amounts(sh0: i32, a0: i32, sh1: i32, a1: i32) -> bool {
    if vals[a0].ty != vals[a1].ty { return false; }
    let maxtot = (ty_sbits(sh0) - 1) + (ty_sbits(sh1) - 1);
    let rw = ty_sbits(a0);
    return ap_uge_u64(ap_ones(rw), maxtot as u64);
}

// m_SpecificInt_ICMP(Pred, APInt(W, x)): cst_pred_ty with AllowPoison (scalar, splat, or a fixed vector whose
// non-poison elements all satisfy it; at least one)
fn c_all_elts_cmp(c: i32, p: i64, x: u64) -> bool {
    let w = ty_sbits(c);
    let xv = ap_u64(x, w);
    if vals[c].kind == VK_CINT { return ic_icmp_ap(p, ap_c(c), xv); }
    if !ty_is_vector(vals[c].ty) || !is_constant(c) { return false; }
    let s = splat_value(c, false);
    if s >= 0 && vals[s].kind == VK_CINT { return ic_icmp_ap(p, ci_ap(s), xv); }
    if ty_kind(vals[c].ty) != TK_FVEC { return false; }
    var has = false;
    for k in ty_count(vals[c].ty) {
        let e = agg_elem(c, k);
        if e < 0 { return false; }
        if vals[e].kind == VK_POISON { continue; }
        if vals[e].kind != VK_CINT || !ic_icmp_ap(p, ci_ap(e), xv) { return false; }
        has = true;
    }
    return has;
}
fn ic_icmp_ap(p: i64, a: AP, b: AP) -> bool {
    match p {
        32 => ap_eq(a, b), 33 => ap_ne(a, b), 34 => ap_ugt(a, b), 35 => ap_uge(a, b), 36 => ap_ult(a, b), 37 => ap_ule(a, b),
        38 => ap_sgt(a, b), 39 => ap_sge(a, b), 40 => ap_slt(a, b), 41 => ap_sle(a, b), _ => false,
    }
}

// reassociateShiftAmtsOfTwoSameDirectionShifts(Sh0, SQ, AnalyzeForSignBitExtraction)
fn reassociate_shift_amts(sh0: i32, analyze_sign: bool) -> i32 {
    if !is_shift_inst(sh0) || !is_inst(op(sh0, 0)) { return -1; }
    let sh0op0 = op(sh0, 0);
    let a0 = m_zext_or_self(op(sh0, 1));
    var sh1 = sh0op0;
    var trunc: i32 = -1;
    if is_inst_op(sh0op0, OP_TRUNC) && is_inst(op(sh0op0, 0)) { trunc = sh0op0; sh1 = op(sh0op0, 0); }
    if !is_shift_inst(sh1) { return -1; }
    let x = op(sh1, 0);
    let a1 = m_zext_or_self(op(sh1, 1));
    if !can_try_to_constant_add_two_shift_amounts(sh0, a0, sh1, a1) { return -1; }
    let two_right = is_shr_inst(sh0) && is_shr_inst(sh1);
    if analyze_sign && !two_right { return -1; }
    let opc = iop(sh0);
    let ident = iop(sh0) == iop(sh1);
    if !ident && !analyze_sign { return -1; }
    if trunc >= 0 && !analyze_sign && !(one_use(op(sh0, 0)) || one_use(op(sh0, 1))) { return -1; }
    let ns = simplify_add(a0, a1, false, false, sq_at(sh0), RECURSION_LIMIT);
    if ns < 0 || !is_constant(ns) { return -1; }
    let xbw = ty_sbits(x);
    if !c_all_elts_cmp(ns, 36, xbw as u64) { return -1; }
    var nsa = ns;
    if two_right && (trunc >= 0 || analyze_sign) {
        if !c_all_elts_cmp(nsa, 32, (xbw - 1) as u64) { return -1; }
        if analyze_sign { return x; }
    }
    if vals[nsa].ty != vals[x].ty {
        nsa = cf_fold_cast_operand(OP_ZEXT, nsa, vals[x].ty);
        if nsa < 0 { return -1; }
    }
    let nsh = ic_new_binop(opc, x, nsa);
    if trunc < 0 {
        if opc == OP_SHL {
            set_nuw(nsh, op_nuw(sh0) && op_nuw(sh1));
            set_nsw(nsh, op_nsw(sh0) && op_nsw(sh1));
        } else {
            set_exact(nsh, op_exact(sh0) && op_exact(sh1));
        }
        return nsh;
    }
    icb_insert(nsh, "");
    return ic_new_cast(OP_TRUNC, nsh, vals[sh0].ty);
}

// dropRedundantMaskingOfLeftShiftInput(OuterShift, Q, Builder)
fn drop_redundant_masking_of_left_shift_input(outer: i32) -> i32 {
    var masked = op(outer, 0);
    let ssa = m_zext_or_self(op(outer, 1));
    let tr = m_trunc(masked);
    if tr >= 0 {
        if !one_use(masked) { return -1; }
        masked = tr;
    }
    let narrow = vals[outer].ty;
    let widest = vals[masked].ty;
    let had_trunc = widest != narrow;
    if ty_scalar_bits(widest) * 2 > 16777215 { return -1; }
    let ext_ty = ty_extended(widest);
    var newmask: i32 = -1;
    var x: i32 = -1;
    var msa: i32 = -1;
    // MaskA / MaskB with m_c_And
    if bo(masked, OP_AND) {
        for k in 2 {
            let m = op(masked, k);
            if bo(m, OP_ADD) && m_all_ones(op(m, 1)) && bo(op(m, 0), OP_SHL) && m_one(op(op(m, 0), 0)) { msa = op(op(m, 0), 1); x = op(masked, 1 - k); break; }
            let n = m_not(m);
            if n >= 0 && bo(n, OP_SHL) && m_all_ones(op(n, 0)) { msa = op(n, 1); x = op(masked, 1 - k); break; }
        }
    }
    if msa >= 0 {
        msa = m_zext_or_self(msa);
        if !can_try_to_constant_add_two_shift_amounts(outer, ssa, masked, msa) { return -1; }
        let sum = simplify_add(msa, ssa, false, false, sq_at(outer), RECURSION_LIMIT);
        if sum < 0 || !is_constant(sum) { return -1; }
        let sum2 = replace_undefs_with(sum, c_int_ty(ty_scalar(vals[sum].ty), ty_scalar_bits(ext_ty) as u64));
        let esum = cf_fold_cast_operand(OP_ZEXT, sum2, ext_ty);
        if esum < 0 { return -1; }
        let eao = c_all_ones(ext_ty);
        let einv = cf_fold_binop_operands(OP_SHL, eao, esum);
        if einv < 0 { return -1; }
        newmask = ce_not(einv);
    } else {
        var found = false;
        if bo(masked, OP_AND) {
            for k in 2 {
                let m = op(masked, k);
                if bo(m, OP_LSHR) && m_all_ones(op(m, 0)) { msa = op(m, 1); x = op(masked, 1 - k); found = true; break; }
                if bo(m, OP_LSHR) && bo(op(m, 0), OP_SHL) && m_all_ones(op(op(m, 0), 0)) && op(op(m, 0), 1) == op(m, 1) {
                    msa = op(m, 1); x = op(masked, 1 - k); found = true; break;
                }
            }
        }
        if !found && is_shr_inst(masked) && bo(op(masked, 0), OP_SHL) && op(op(masked, 0), 1) == op(masked, 1) {
            x = op(op(masked, 0), 0); msa = op(masked, 1); found = true;
        }
        if !found { return -1; }
        msa = m_zext_or_self(msa);
        if !can_try_to_constant_add_two_shift_amounts(outer, ssa, masked, msa) { return -1; }
        let diff = simplify_sub(ssa, msa, false, false, sq_at(outer), RECURSION_LIMIT);
        if diff < 0 || !is_constant(diff) { return -1; }
        let wbw = ty_scalar_bits(widest);
        let diff2 = replace_undefs_with(diff, c_int_ty_s(ty_scalar(vals[diff].ty), -wbw));
        let nhb = ce_binop(OP_SUB, c_int_ty(vals[diff2].ty, wbw as u64), diff2, 0);
        let enhb = cf_fold_cast_operand(OP_ZEXT, nhb, ext_ty);
        if enhb < 0 { return -1; }
        let eao = c_all_ones(ext_ty);
        newmask = cf_fold_binop_operands(OP_LSHR, eao, enhb);
        if newmask < 0 { return -1; }
    }
    newmask = ce_cast(OP_TRUNC, newmask, narrow);
    let need_mask = !m_all_ones(newmask);
    if need_mask {
        if !one_use(masked) { return -1; }
        if bo(masked, OP_ASHR) { return -1; }
    }
    var xx = x;
    if had_trunc { xx = icb_trunc(xx, narrow, ""); }
    let ns = ic_new_binop(iop(outer), xx, op(outer, 1));
    if !need_mask { return ns; }
    icb_insert(ns, "");
    return ic_new_binop(OP_AND, ns, newmask);
}
// Type::getExtendedType
fn ty_extended(t: i32) -> i32 {
    let s = ty_int(ty_scalar_bits(t) * 2);
    if ty_is_vector(t) { return ty_vector(s, ty_count(t), ty_kind(t) == TK_SVEC); }
    return s;
}
// Constant::replaceUndefsWith(C, Replacement)
fn replace_undefs_with(c: i32, rep: i32) -> i32 {
    if is_undef_or_poison(c) && !ty_is_vector(vals[c].ty) { return rep; }
    if ty_kind(vals[c].ty) != TK_FVEC { return c; }
    var any = false;
    for k in ty_count(vals[c].ty) { let e = agg_elem(c, k); if e >= 0 && is_undef_or_poison(e) { any = true; } }
    if !any { return c; }
    let mark = is_ops.len;
    for k in ty_count(vals[c].ty) {
        var e = agg_elem(c, k);
        if is_undef_or_poison(e) { e = rep; }
        is_ops.push(e);
    }
    let r = c_aggregate(vals[c].ty, is_ops[mark..is_ops.len]);
    is_ops.resize(mark);
    return r;
}

// foldShiftOfShiftedBinOp(I, Builder)
fn fold_shift_of_shifted_binop(i: i32) -> i32 {
    let b = op(i, 0);
    if !is_binop_inst(b) || (!is_logic_op(iop(b)) && iop(b) != OP_ADD && iop(b) != OP_SUB) || !has_one_use(b) { return -1; }
    let c1 = op(i, 1);
    if !is_const(c1) { return -1; }
    let so = iop(i);
    if (iop(b) == OP_ADD || iop(b) == OP_SUB) && so != OP_SHL { return -1; }
    let ty = vals[i].ty;
    let size = ty_scalar_bits(ty);
    var x: i32 = -1; var c0: i32 = -1; var y: i32 = -1;
    var first_is_op1 = false;
    if fsosb_match(op(b, 0), op(b, 1), so, c1, size) { x = op(op(b, 0), 0); c0 = op(op(b, 0), 1); y = op(b, 1); }
    else if fsosb_match(op(b, 1), op(b, 0), so, c1, size) { x = op(op(b, 1), 0); c0 = op(op(b, 1), 1); y = op(b, 0); first_is_op1 = iop(b) == OP_SUB; }
    else { return -1; }
    let sum = ce_binop(OP_ADD, c0, c1, 0);
    let ns1 = icb_binop(so, x, sum, "");
    let ns2 = icb_binop(so, y, c1, "");
    let a = if first_is_op1 { ns2 } else { ns1 };
    let b2 = if first_is_op1 { ns1 } else { ns2 };
    return ic_new_binop(iop(b), a, b2);
}
fn fsosb_match(v: i32, w: i32, so: i64, c1: i32, size: i64) -> bool {
    if !bo(v, so) || !is_const(op(v, 1)) { return false; }
    if !(one_use(v) || is_imm_c(w)) { return false; }
    let s = ce_binop(OP_ADD, op(v, 1), c1, 0);
    return c_all_elts_cmp(s, 36, size as u64);
}

// commonShiftTransforms(I)
fn common_shift_transforms(i: i32) -> i32 {
    let ph = fold_binop_with_phi_operands(i);
    if ph >= 0 { return ph; }
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    let ty = vals[i].ty;
    let o = iop(i);
    if one_use(op1) {
        let y = m_sext(op1);
        if y >= 0 {
            var nm: u8[>..] = []; nm.append(val_name(op1));
            let ne = icb_zext(y, ty, nm);
            return ic_new_binop(o, op0, ne);
        }
    }
    if simplify_demanded_instruction_bits(i) { return i; }
    if is_constant(op0) && is_select_inst(op1) {
        let r = fold_op_into_select(i, op1, false, false);
        if r >= 0 { return r; }
    }
    if is_imm_c(op1) {
        let r = fold_shift_by_constant(op0, op1, i);
        if r >= 0 { return r; }
    }
    let rs = reassociate_shift_amts(i, false);
    if rs >= 0 { return rs; }
    // C shift (A add nuw C1) --> (C shift C1) shift A
    if is_const(op0) && m_nuw_add_like(op1) && is_const(op(op1, 1)) {
        let a = op(op1, 0);
        let nc = icb_binop(o, op0, op(op1, 1), "");
        let ns = ic_new_binop(o, nc, a);
        if o == OP_SHL { set_nsw(ns, op_nsw(i)); set_nuw(ns, op_nuw(i)); } else { set_exact(ns, op_exact(i)); }
        return ns;
    }
    let bw = ty_scalar_bits(ty);
    if has_apint(op0) {
        let ac = ap_c(op0);
        if bo(op1, OP_ADD) && has_apint(op(op1, 1)) {
            let addc = ap_c(op(op1, 1));
            let a = op(op1, 0);
            if ap_is_neg(addc) && ap_ult_u64(ap_neg(addc), bw as u64) {
                let po = ap_zext64(ap_neg(addc)) as i64;
                var suitable = false;
                if o == OP_SHL { suitable = (op_nsw(i) || op_nuw(i)) && ap_eq(ac, ap_shl(ap_lshr(ac, po), po)); }
                else if o == OP_LSHR { suitable = op_exact(i) && ap_eq(ac, ap_lshr(ap_shl(ac, po), po)); }
                else if o == OP_ASHR { suitable = op_exact(i) && ap_eq(ac, ap_ashr(ap_shl(ac, po), po)); }
                if suitable {
                    let nc = c_int_ap(ty, if o == OP_SHL { ap_lshr(ac, po) } else { ap_shl(ac, po) });
                    let ns = ic_new_binop(o, nc, a);
                    if o == OP_SHL { set_nuw(ns, op_nuw(i)); } else { set_exact(ns, true); }
                    return ns;
                }
            }
        }
        // C1 << (C2 - X) -> (C1 << C2) >> X ; also (X ^ C2)
        var c2: i64 = -1;
        var x: i32 = -1;
        if bo(op1, OP_SUB) && op_nuw(op1) && m_constant_int(op(op1, 0)) >= 0 && ty_sbits(op(op1, 0)) <= 64 {
            c2 = cint_lo(op(op1, 0)) as i64; x = op(op1, 1);
        } else if bo(op1, OP_XOR) && m_constant_int(op(op1, 1)) >= 0 && ty_sbits(op(op1, 1)) <= 64 {
            let cc = ci_ap(op(op1, 1));
            kb_cxt = i;
            let kx = kb_compute_all(op(op1, 0), 0);
            if ap_is_all_ones(ap_or(cc, kx.z)) { c2 = cint_lo(op(op1, 1)) as i64; x = op(op1, 0); }
        }
        if c2 >= 0 {
            if o == OP_SHL {
                if ap_countl_zero(ac) >= c2 { return ic_new_binop_flags(OP_LSHR, c_int_ap(ty, ap_shl(ac, c2)), x, FL_EXACT); }
                if ap_countl_one(ac) > c2 { return ic_new_binop_flags(OP_ASHR, c_int_ap(ty, ap_shl(ac, c2)), x, FL_EXACT); }
            } else if ap_countr_zero(ac) >= c2 {
                if !ap_is_neg(ac) {
                    let s = ic_new_binop_flags(OP_SHL, c_int_ap(ty, ap_lshr(ac, c2)), x, FL_NUW);
                    set_nsw(s, true);
                    return s;
                }
                if o == OP_LSHR { return ic_new_binop_flags(OP_SHL, c_int_ap(ty, ap_lshr(ac, c2)), x, FL_NUW); }
                return ic_new_binop_flags(OP_SHL, c_int_ap(ty, ap_ashr(ac, c2)), x, FL_NSW);
            }
        }
    }
    // X shift (A srem C) -> X shift (A and (C - 1)) iff C is a power of 2
    if one_use(op1) && bo(op1, OP_SREM) && is_const(op(op1, 1)) && m_power2(op(op1, 1)) {
        let mask = ce_binop(OP_SUB, op(op1, 1), c_int_ty(ty, 1), 0);
        var nm: u8[>..] = []; nm.append(val_name(op1));
        let rem = icb_and(op(op1, 0), mask, nm);
        return ic_replace_operand(i, 1, rem);
    }
    let lg = fold_shift_of_shifted_binop(i);
    if lg >= 0 { return lg; }
    if bo(op1, OP_OR) && m_specific_int(op(op1, 1), (bw - 1) as u64) {
        return ic_replace_operand(i, 1, c_int_ty(ty, (bw - 1) as u64));
    }
    if (o == OP_LSHR || o == OP_ASHR) && one_use(op0) && is_inst(op0) && (inst_iid(op0) == IID_scmp || inst_iid(op0) == IID_ucmp) &&
       m_specific_int(op1, (bw - 1) as u64) {
        let p = if inst_iid(op0) == IID_scmp { 40 } else { 36 };
        let cmp = icb_icmp(p, op(op0, 0), op(op0, 1), "");
        return ic_new_cast(if o == OP_LSHR { OP_ZEXT } else { OP_SEXT }, cmp, ty);
    }
    return -1;
}

// canEvaluateShiftedShift
fn can_evaluate_shifted_shift(outer: i64, is_outer_shl: bool, sem: i64, inner: i32, cx: i32) -> bool {
    if !has_apint(op(inner, 1)) { return false; }
    let isc = ap_c(op(inner, 1));
    let is_inner_shl = iop(inner) == OP_SHL;
    if !is_outer_shl && sem == SS_SIGNED { return is_inner_shl && op_nsw(inner) && ap_eq_u64(isc, outer as u64); }
    if is_inner_shl == is_outer_shl { return sem == SS_LOSSY; }
    if ap_eq_u64(isc, outer as u64) { return true; }
    let tw = ty_sbits(inner);
    if ap_ugt_u64(isc, outer as u64) && ap_ult_u64(isc, tw as u64) {
        let isa = ap_zext64(isc) as i64;
        let ms = if is_inner_shl { tw - isa } else { isa - outer };
        let mask = ap_shl(ap_low_bits(tw, outer), ms);
        kb_cxt = cx;
        if masked_value_is_zero(op(inner, 0), mask, 0) { return true; }
    }
    return false;
}

// canEvaluateShifted(V, NumBits, IsLeftShift, Semantics, CxtI)
recursive fn can_evaluate_shifted(v: i32, nb: i64, left: bool, sem: i64, cx: i32) -> bool {
    if is_imm_c(v) {
        if sem == SS_LOSSY { return true; }
        if has_apint_poison(v) && !left { return ap_countr_zero(ap_cp(v)) >= nb; }
        return false;
    }
    if !is_inst(v) { return false; }
    if !has_one_use(v) { return false; }
    let o = iop(v);
    if o == OP_AND || o == OP_OR || o == OP_XOR {
        return can_evaluate_shifted(op(v, 0), nb, left, sem, v) && can_evaluate_shifted(op(v, 1), nb, left, sem, v);
    }
    if o == OP_SHL || o == OP_LSHR { return can_evaluate_shifted_shift(nb, left, sem, v, cx); }
    if o == OP_SELECT {
        return can_evaluate_shifted(op(v, 1), nb, left, sem, v) && can_evaluate_shifted(op(v, 2), nb, left, sem, v);
    }
    if o == OP_PHI {
        for k in nops(v) { if !can_evaluate_shifted(op(v, k), nb, left, sem, v) { return false; } }
        return true;
    }
    if o == OP_MUL {
        return !left && sem == SS_UNSIGNED && has_apint(op(v, 1)) && ap_is_neg_pow2(ap_c(op(v, 1))) && ap_countr_zero(ap_c(op(v, 1))) == nb;
    }
    if o == OP_ADD {
        if left {
            if sem == SS_LOSSY {
                return can_evaluate_shifted(op(v, 0), nb, left, sem, v) && can_evaluate_shifted(op(v, 1), nb, left, sem, v);
            }
            return false;
        }
        if sem == SS_LOSSY { return false; }
        let wrap = (sem == SS_SIGNED && op_nsw(v)) || (sem == SS_UNSIGNED && op_nuw(v));
        return wrap && can_evaluate_shifted(op(v, 0), nb, left, sem, v) && can_evaluate_shifted(op(v, 1), nb, left, sem, v);
    }
    return false;
}

// foldShiftedShift(InnerShift, OuterShAmt, IsOuterShl, Semantics, Builder)
fn fold_shifted_shift(inner: i32, outer: i64, is_outer_shl: bool, sem: i64) -> i32 {
    let is_inner_shl = iop(inner) == OP_SHL;
    let sty = vals[inner].ty;
    let tw = ty_scalar_bits(sty);
    let isa = ap_zext64(ap_c(op(inner, 1))) as i64;
    if is_inner_shl == is_outer_shl {
        if isa + outer >= tw { return c_null(sty); }
        return fss_new_inner(inner, isa + outer, is_inner_shl);
    }
    if isa == outer {
        if !is_outer_shl && sem == SS_SIGNED { return op(inner, 0); }
        if !is_outer_shl && sem == SS_UNSIGNED && is_inner_shl && op_nuw(inner) { return op(inner, 0); }
        let mask = if is_inner_shl { ap_low_bits(tw, tw - outer) } else { ap_high_bits(tw, tw - outer) };
        let an = icb_and(op(inner, 0), c_int_ap(sty, mask), "");
        if is_inst(an) {
            inst_move_before(an, inner);
            ic_take_name(an, inner);
        }
        return an;
    }
    return fss_new_inner(inner, isa - outer, is_inner_shl);
}
fn fss_new_inner(inner: i32, sa: i64, is_inner_shl: bool) -> i32 {
    set_op(inner, 1, c_int_ty(vals[inner].ty, sa as u64));
    if is_inner_shl { set_nuw(inner, false); set_nsw(inner, false); } else { set_exact(inner, false); }
    return inner;
}

// getShiftedValue(V, NumBits, IsLeftShift, Semantics)
recursive fn get_shifted_value(v: i32, nb: i64, left: bool, sem: i64) -> i32 {
    if is_constant(v) {
        let so = if left { OP_SHL } else { if sem == SS_SIGNED { OP_ASHR } else { OP_LSHR } };
        return icb_binop(so, v, c_int_ty(vals[v].ty, nb as u64), "");
    }
    icw_add(v);
    let o = iop(v);
    if o == OP_AND || o == OP_OR || o == OP_XOR {
        let a = get_shifted_value(op(v, 0), nb, left, sem);
        set_op(v, 0, a);
        let b = get_shifted_value(op(v, 1), nb, left, sem);
        set_op(v, 1, b);
        return v;
    }
    if o == OP_SHL || o == OP_LSHR { return fold_shifted_shift(v, nb, left, sem); }
    if o == OP_SELECT {
        let a = get_shifted_value(op(v, 1), nb, left, sem);
        set_op(v, 1, a);
        let b = get_shifted_value(op(v, 2), nb, left, sem);
        set_op(v, 2, b);
        return v;
    }
    if o == OP_PHI {
        for k in nops(v) {
            let a = get_shifted_value(op(v, k), nb, left, sem);
            set_op(v, k, a);
        }
        return v;
    }
    if o == OP_MUL {
        let ng = ic_new_neg(op(v, 0));
        ic_insert_new_with(ng, v);
        let tw = ty_sbits(v);
        let mask = ap_low_bits(tw, tw - nb);
        let an = ic_new_binop(OP_AND, ng, c_int_ap(vals[v].ty, mask));
        ic_take_name(an, v);
        return ic_insert_new_with(an, v);
    }
    if o == OP_ADD {
        if left { drop_poison_generating_flags(v); }
        let a = get_shifted_value(op(v, 0), nb, left, sem);
        set_op(v, 0, a);
        let b = get_shifted_value(op(v, 1), nb, left, sem);
        set_op(v, 1, b);
        return v;
    }
    fatal("Inconsistency with CanEvaluateShifted");
    return -1;
}

// canShiftBinOpWithConstantRHS(Shift, BO)
fn can_shift_binop_with_constant_rhs(sh: i32, b: i32) -> bool {
    let o = iop(b);
    if o == OP_ADD { return iop(sh) == OP_SHL; }
    if o == OP_OR || o == OP_AND { return true; }
    if o == OP_XOR { return !((iop(sh) == OP_SHL || iop(sh) == OP_LSHR) && m_not(b) >= 0); }
    return false;
}

// FoldShiftByConstant(Op0, C1, I)
fn fold_shift_by_constant(op0: i32, c1: i32, i: i32) -> i32 {
    let o = iop(i);
    let left = o == OP_SHL;
    if bo(op0, o) && is_imm_c(op(op0, 0)) {
        let x = op(op0, 1);
        let nc = icb_binop(o, op(op0, 0), c1, "");
        let r = ic_new_binop(o, nc, x);
        if left { set_nuw(r, op_nuw(i) && op_nuw(op0)); set_nsw(r, op_nsw(i) && op_nsw(op0)); }
        else { set_exact(r, op_exact(i) && op_exact(op0)); }
        return r;
    }
    let ty = vals[i].ty;
    let tb = ty_scalar_bits(ty);
    if !left && m_specific_int_allow_poison(c1, (tb - 1) as u64) && bo(op0, OP_SDIV) && has_apint(op(op0, 1)) {
        let divc = ap_c(op(op0, 1));
        if !ap_is_zero(divc) && !ap_is_min_signed(divc) {
            let ndc = c_int_ap(ty, ap_neg(divc));
            let p = if ap_is_neg(divc) { 39 } else { 41 };
            let cmp = icb_icmp(p, op(op0, 0), ndc, "");
            return ic_new_cast(if o == OP_ASHR { OP_SEXT } else { OP_ZEXT }, cmp, ty);
        }
    }
    if !has_apint(c1) { return -1; }
    let op1c = ap_c(c1);
    if ap_uge_u64(op1c, tb as u64) { fatal("Shift over the type width should have been removed already"); }
    let sa = ap_zext64(op1c) as i64;
    if o != OP_ASHR {
        let sem = if left { SS_LOSSY } else { SS_UNSIGNED };
        if can_evaluate_shifted(op0, sa, left, sem, i) {
            return ic_replace_inst_uses_with(i, get_shifted_value(op0, sa, left, sem));
        }
    }
    let fs = fold_binop_into_select_or_phi(i);
    if fs >= 0 { return fs; }
    if !one_use(op0) { return -1; }
    if is_binop_inst(op0) && has_apint(op(op0, 1)) && can_shift_binop_with_constant_rhs(i, op0) {
        let nr = icb_binop(o, op(op0, 1), c1, "");
        let ns = icb_binop(o, op(op0, 0), c1, "");
        ic_take_name(ns, op0);
        return ic_new_binop(iop(op0), ns, nr);
    }
    if is_select_inst(op0) {
        let cond = op(op0, 0);
        let tbo = op(op0, 1);
        let fv = op(op0, 2);
        if one_use(tbo) && is_binop_inst(tbo) && !is_constant(fv) && op(tbo, 0) == fv && has_apint(op(tbo, 1)) && can_shift_binop_with_constant_rhs(i, tbo) {
            let nr = icb_binop(o, op(tbo, 1), c1, "");
            let ns = icb_binop(o, fv, c1, "");
            let no = icb_binop(iop(tbo), ns, nr, "");
            return ic_new_select(cond, no, ns);
        }
        let tv = op(op0, 1);
        let fbo = op(op0, 2);
        if one_use(fbo) && is_binop_inst(fbo) && !is_constant(tv) && op(fbo, 0) == tv && has_apint(op(fbo, 1)) && can_shift_binop_with_constant_rhs(i, fbo) {
            let nr = icb_binop(o, op(fbo, 1), c1, "");
            let ns = icb_binop(o, tv, c1, "");
            let no = icb_binop(iop(fbo), ns, nr, "");
            return ic_new_select(cond, ns, no);
        }
    }
    return -1;
}

// foldLShrOverflowBit(I)
fn fold_lshr_overflow_bit(i: i32) -> i32 {
    let add = op(i, 0);
    let sha = op(i, 1);
    let ty = vals[i].ty;
    if ty_scalar_bits(ty) < 3 { return -1; }
    if !has_apint(sha) || !bo(add, OP_ADD) { return -1; }
    let zx = op(add, 0);
    let zy = op(add, 1);
    if !one_use(zx) || m_zext(zx) < 0 || !one_use(zy) || m_zext(zy) < 0 { return -1; }
    let x = m_zext(zx);
    let y = m_zext(zy);
    let sa = ap_zext64(ap_c(sha)) as i64;
    if sa == 1 { return -1; }
    if ty_sbits(x) != sa || ty_sbits(y) != sa { return -1; }
    if !has_one_use(add) {
        var u = vals[add].first_use;
        while u >= 0 {
            let us = uses[u].user;
            u = uses[u].next;
            if us == i { continue; }
            if !is_inst_op(us, OP_TRUNC) || ty_sbits(us) > sa { return -1; }
        }
    }
    icb_set_insert_point(add);
    let na = icb_add(x, y, "add.narrowed");
    let ov = icb_icmp(36, na, x, "add.narrowed.overflow");
    if !has_one_use(add) {
        ic_replace_inst_uses_with(add, icb_zext(na, ty, ""));
        ic_erase(add);
    }
    return ic_new_cast(OP_ZEXT, ov, ty);
}

// setShiftFlags(I, Q)
fn set_shift_flags(i: i32) -> bool {
    let o = iop(i);
    if o == OP_SHL {
        if op_nuw(i) && op_nsw(i) { return false; }
    } else {
        if op_exact(i) { return false; }
        if bo(op(i, 0), OP_SHL) && op(op(i, 0), 1) == op(i, 1) { set_exact(i, true); return true; }
        let c = op(i, 1);
        if inst_iid(c) == IID_cttz && op(c, 0) == op(i, 0) { set_exact(i, true); return true; }
    }
    kb_cxt = i;
    let kc = kb_compute_all(op(i, 1), 0);
    let w = kb_bw(kc);
    let maxcnt = ap_limited(kb_max(kc), (w - 1) as u64) as i64;
    kb_cxt = i;
    let ka = kb_compute_all(op(i, 0), 0);
    var changed = false;
    if o == OP_SHL {
        if !op_nuw(i) && maxcnt <= kb_min_lz(ka) { set_nuw(i, true); changed = true; }
        if !op_nsw(i) {
            var ok = maxcnt < kb_min_sign_bits_k(ka);
            if !ok { kb_cxt = i; ok = maxcnt < num_sign_bits(op(i, 0), 0); }
            if ok { set_nsw(i, true); changed = true; }
        }
        return changed;
    }
    changed = maxcnt <= kb_min_tz(ka);
    set_exact(i, changed);
    return changed;
}

// ---------------------------------------------------------------------------------------------
// visitShl

fn visit_shl(i: i32) -> i32 {
    let v0 = simplify_shl(op(i, 0), op(i, 1), op_nsw(i), op_nuw(i), sq_at(i), RECURSION_LIMIT);
    if v0 >= 0 { return ic_replace_inst_uses_with(i, v0); }
    let x0 = fold_vector_binop(i);
    if x0 >= 0 { return x0; }
    var r = common_shift_transforms(i);
    if r >= 0 { return r; }
    r = drop_redundant_masking_of_left_shift_input(i);
    if r >= 0 { return r; }
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    let ty = vals[i].ty;
    let bw = ty_scalar_bits(ty);
    if has_apint(op1) {
        let c = ap_c(op1);
        let sac = ap_zext64(c) as i64;
        // shl (zext X), C --> zext (shl X, C)
        if one_use(op0) && m_zext(op0) >= 0 {
            let x = m_zext(op0);
            let sw = ty_sbits(x);
            kb_cxt = i;
            if sac < sw && masked_value_is_zero(x, ap_high_bits(sw, sac), 0) {
                return ic_new_cast(OP_ZEXT, icb_shl_k(x, sac as u64, ""), ty);
            }
        }
        // (X >> C) << C --> X & (-1 << C)
        if is_shr_inst(op0) && op(op0, 1) == op1 {
            return ic_new_binop(OP_AND, op(op0, 0), c_int_ap(ty, ap_high_bits(bw, bw - sac)));
        }
        if is_shr_inst(op0) && op_exact(op0) && has_apint(op(op0, 1)) && ap_ult_u64(ap_c(op(op0, 1)), bw as u64) {
            let x = op(op0, 0);
            let shr = ap_zext64(ap_c(op(op0, 1))) as i64;
            if shr < sac {
                let ns = ic_new_binop(OP_SHL, x, c_int_ty(ty, (sac - shr) as u64));
                set_nuw(ns, op_nuw(i) || (shr != 0 && iop(op0) == OP_LSHR && op_nsw(i)));
                set_nsw(ns, op_nsw(i));
                return ns;
            }
            if shr > sac {
                let ns = ic_new_binop(iop(op0), x, c_int_ty(ty, (shr - sac) as u64));
                set_exact(ns, true);
                return ns;
            }
        }
        if one_use(op0) && is_shr_inst(op0) && has_apint(op(op0, 1)) && ap_ult_u64(ap_c(op(op0, 1)), bw as u64) {
            let x = op(op0, 0);
            let shr = ap_zext64(ap_c(op(op0, 1))) as i64;
            if shr < sac {
                let ns = ic_new_binop(OP_SHL, x, c_int_ty(ty, (sac - shr) as u64));
                set_nuw(ns, op_nuw(i) || (shr != 0 && iop(op0) == OP_LSHR && op_nsw(i)));
                set_nsw(ns, op_nsw(i));
                icb_insert(ns, "");
                return ic_new_binop(OP_AND, ns, c_int_ap(ty, ap_high_bits(bw, bw - sac)));
            }
            if shr > sac {
                let ns = ic_new_binop(iop(op0), x, c_int_ty(ty, (shr - sac) as u64));
                set_exact(ns, op_exact(op0));
                icb_insert(ns, "");
                return ic_new_binop(OP_AND, ns, c_int_ap(ty, ap_high_bits(bw, bw - sac)));
            }
        }
        // through an intermediate trunc
        if one_use(op0) && m_trunc(op0) >= 0 {
            let shr = m_trunc(op0);
            if one_use(shr) && is_binop_inst(shr) && is_shr_inst(shr) && has_apint(op(shr, 1)) {
                let x = op(shr, 0);
                let src = ap_zext64(ap_c(op(shr, 1))) as i64;
                let shd = if src > sac { src - sac } else { sac - src };
                let sdc = c_int_ty(vals[x].ty, shd as u64);
                let so = if src > sac { iop(shr) } else { OP_SHL };
                let ns = icb_binop(so, x, sdc, "sh.diff");
                let tr = icb_trunc(ns, ty, "tr.sh.diff");
                return ic_new_binop(OP_AND, tr, c_int_ap(ty, ap_high_bits(bw, bw - sac)));
            }
        }
        if one_use(op0) && is_binop_inst(op0) {
            let bop = iop(op0);
            if bop == OP_ADD || bop == OP_AND || bop == OP_OR || bop == OP_XOR || bop == OP_SUB {
                var shr = op(op0, 0);
                var y = op(op0, 1);
                if is_commutative(bop) && one_use(y) &&
                   ((is_shr_inst(y) && op(y, 1) == op1) ||
                    (bo(y, OP_AND) && has_apint(op(y, 1)) && one_use(op(y, 0)) && is_shr_inst(op(y, 0)) && op(op(y, 0), 1) == op1)) {
                    let t = shr; shr = y; y = t;
                }
                if one_use(shr) && is_shr_inst(shr) && op(shr, 1) == op1 {
                    let x = op(shr, 0);
                    var n1: u8[>..] = []; n1.append(val_name(op0));
                    let ys = icb_shl(y, op1, n1);
                    var n2: u8[>..] = []; n2.append(val_name(shr));
                    let b = icb_binop(bop, x, ys, n2);
                    let o1v = ap_limited(c, bw as u64) as i64;
                    return ic_new_binop(OP_AND, b, c_int_ap(ty, ap_high_bits(bw, bw - o1v)));
                }
                if one_use(shr) && bo(shr, OP_AND) && has_apint(op(shr, 1)) && one_use(op(shr, 0)) && is_shr_inst(op(shr, 0)) && op(op(shr, 0), 1) == op1 {
                    let x = op(op(shr, 0), 0);
                    let cc = ap_c(op(shr, 1));
                    var n1: u8[>..] = []; n1.append(val_name(op0));
                    let ys = icb_shl(y, op1, n1);
                    var n2: u8[>..] = []; n2.append(val_name(x)); n2.append(".mask");
                    let m = icb_and(x, c_int_ap(ty, ap_shl_ap(cc, c)), n2);
                    let no = ic_new_binop(bop, m, ys);
                    if bop == OP_OR && op_disjoint(op0) { set_disjoint(no, true); }
                    return no;
                }
            }
        }
        // (C1 - X) << C --> (C1 << C) - (X << C)
        if one_use(op0) && bo(op0, OP_SUB) && has_apint(op(op0, 0)) {
            let nl = c_int_ap(ty, ap_shl_ap(ap_c(op(op0, 0)), c));
            let ns = icb_shl(op(op0, 1), op1, "");
            return ic_new_binop(OP_SUB, nl, ns);
        }
    }
    if set_shift_flags(i) { return i; }
    // (x >> y) << y --> x & (-1 << y)
    if one_use(op0) && is_shr_inst(op0) && op(op0, 1) == op1 {
        let m = icb_shl(c_all_ones(ty), op1, "");
        return ic_new_binop(OP_AND, m, op(op0, 0));
    }
    // (-1 >> y) << y --> -1 << y
    if bo(op0, OP_LSHR) && m_all_ones(op(op0, 0)) && op(op0, 1) == op1 { return ic_new_binop(OP_SHL, c_all_ones(ty), op1); }
    if is_imm_c(op1) {
        if bo(op0, OP_MUL) && is_imm_c(op(op0, 1)) { return ic_new_binop(OP_MUL, op(op0, 0), icb_shl(op(op0, 1), op1, "")); }
        let x = m_zext(op0);
        if x >= 0 && is_int_ty1(vals[x].ty) {
            let nc = icb_shl(c_int_ty(ty, 1), op1, "");
            return ic_new_select_unknown_prof(x, nc, c_null(ty));
        }
    }
    if m_one(op0) {
        if bo(op1, OP_SUB) && m_specific_int(op(op1, 0), (bw - 1) as u64) {
            return ic_new_binop(OP_LSHR, c_int_ap(ty, ap_sign_mask(bw)), op(op1, 1));
        }
        if one_use(op1) && inst_iid(op1) == IID_cttz {
            let x = op(op1, 0);
            let nx = icb_neg(x, "neg", false);
            return ic_new_binop(OP_AND, nx, x);
        }
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// visitLShr

fn visit_lshr(i: i32) -> i32 {
    let v0 = simplify_lshr(op(i, 0), op(i, 1), op_exact(i), sq_at(i), RECURSION_LIMIT);
    if v0 >= 0 { return ic_replace_inst_uses_with(i, v0); }
    let x0 = fold_vector_binop(i);
    if x0 >= 0 { return x0; }
    let r = common_shift_transforms(i);
    if r >= 0 { return r; }
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    let ty = vals[i].ty;
    let bw = ty_scalar_bits(ty);
    if m_one(op0) { return ic_new_cast(OP_ZEXT, icb_is_null(op1, ""), ty); }
    if one_use(op0) && m_not(op0) >= 0 && m_specific_int_allow_poison(op1, (bw - 1) as u64) {
        let x = m_not(op0);
        return ic_new_cast(OP_ZEXT, icb_icmp(38, x, c_all_ones(vals[x].ty), "isnotneg"), ty);
    }
    // ((X << nuw Z) sub nuw Y) >>u exact Z --> X sub nuw (Y >>u exact Z)
    if op_exact(i) && one_use(op0) && bo(op0, OP_SUB) && op_nuw(op0) && bo(op(op0, 0), OP_SHL) && op_nuw(op(op0, 0)) && op(op(op0, 0), 1) == op1 {
        let x = op(op(op0, 0), 0);
        let y = op(op0, 1);
        let nl = icb_lshr(y, op1, "", true);
        let ns = ic_new_binop_flags(OP_SUB, x, nl, FL_NUW);
        set_nsw(ns, op_nsw(op0));
        return ns;
    }
    // (X + Y) / 2 --> (X & Y) iff (X u<= 1) && (Y u<= 1)
    if bo(op0, OP_ADD) && m_one(op1) {
        kb_cxt = i;
        if kb_max_active_bits(kb_compute_all(op(op0, 0), 0)) <= 1 {
            kb_cxt = i;
            if kb_max_active_bits(kb_compute_all(op(op0, 1), 0)) <= 1 { return ic_new_binop(OP_AND, op(op0, 0), op(op0, 1)); }
        }
    }
    // (sub nuw X, (Y << nuw Z)) >>u exact Z --> (X >>u exact Z) sub nuw Y
    if op_exact(i) && one_use(op0) && bo(op0, OP_SUB) && op_nuw(op0) && bo(op(op0, 1), OP_SHL) && op_nuw(op(op0, 1)) && op(op(op0, 1), 1) == op1 {
        let x = op(op0, 0);
        let y = op(op(op0, 1), 0);
        let nl = icb_lshr(x, op1, "", true);
        let ns = ic_new_binop_flags(OP_SUB, nl, y, FL_NUW);
        set_nsw(ns, op_nsw(op0));
        return ns;
    }
    // ((X << nuw Z) binop nuw Y) >>u Z --> X binop nuw (Y >>u Z)
    if one_use(op0) && is_binop_inst(op0) {
        for k in 2 {
            let s = op(op0, k);
            if bo(s, OP_SHL) && op_nuw(s) && op(s, 1) == op1 {
                let x = op(s, 0);
                let y = op(op0, 1 - k);
                let bop = iop(op0);
                if bop == OP_ADD || bop == OP_AND || bop == OP_OR || bop == OP_XOR {
                    let obo = is_overflowing_op(bop);
                    if !obo || op_nuw(op0) {
                        let nl = icb_lshr(y, op1, "", op_exact(i) && bop != OP_AND);
                        let nb = ic_new_binop(bop, nl, x);
                        if obo { set_nuw(nb, true); set_nsw(nb, op_nsw(op0)); }
                        else if bop == OP_OR { set_disjoint(nb, op_disjoint(op0)); }
                        return nb;
                    }
                }
                break;
            }
        }
    }
    if has_apint(op1) {
        let c = ap_c(op1);
        let sac = ap_zext64(c) as i64;
        let iid = inst_iid(op0);
        if iid != 0 && is_pow2_w(bw) && ap_log2(ap_u64(bw as u64, 64)) == sac && (iid == IID_ctlz || iid == IID_cttz || iid == IID_ctpop) {
            let ispop = iid == IID_ctpop;
            let rc = c_int_ty_s(ty, if ispop { -1 } else { 0 });
            let cmp = icb_icmp(32, op(op0, 0), rc, "");
            return ic_new_cast(OP_ZEXT, cmp, ty);
        }
        if bo(op0, OP_SHL) && has_apint(op(op0, 1)) && ap_ult_u64(ap_c(op(op0, 1)), bw as u64) {
            let x = op(op0, 0);
            let shl = ap_zext64(ap_c(op(op0, 1))) as i64;
            if shl < sac {
                let sd = c_int_ty(ty, (sac - shl) as u64);
                if op_nuw(op0) { let nl = ic_new_binop(OP_LSHR, x, sd); set_exact(nl, op_exact(i)); return nl; }
                if one_use(op0) {
                    let nl = icb_lshr(x, sd, "", op_exact(i));
                    return ic_new_binop(OP_AND, nl, c_int_ap(ty, ap_low_bits(bw, bw - sac)));
                }
            } else if shl > sac {
                let sd = c_int_ty(ty, (shl - sac) as u64);
                if op_nuw(op0) {
                    let ns = ic_new_binop_flags(OP_SHL, x, sd, FL_NUW);
                    set_nsw(ns, sac > 0);
                    return ns;
                }
                if one_use(op0) {
                    let ns = icb_shl(x, sd, "");
                    return ic_new_binop(OP_AND, ns, c_int_ap(ty, ap_low_bits(bw, bw - sac)));
                }
            } else {
                return ic_new_binop(OP_AND, x, c_int_ap(ty, ap_low_bits(bw, bw - sac)));
            }
        }
        // ((X << C) + Y) >>u C --> (X + (Y >>u C)) & (-1 >>u C)
        if one_use(op0) && bo(op0, OP_ADD) {
            for k in 2 {
                let s = op(op0, k);
                if one_use(s) && bo(s, OP_SHL) && op(s, 1) == op1 {
                    let x = op(s, 0);
                    let y = op(op0, 1 - k);
                    let nl = icb_lshr(y, op1, "", false);
                    let na = icb_add(nl, x, "");
                    let o1v = ap_limited(c, bw as u64) as i64;
                    return ic_new_binop(OP_AND, na, c_int_ap(ty, ap_low_bits(bw, bw - o1v)));
                }
            }
        }
        if one_use(op0) && m_zext(op0) >= 0 {
            let x = m_zext(op0);
            if !ty_is_int(ty) || should_change_type(ty, vals[x].ty) {
                let nl = icb_lshr(x, c_int_ty(vals[x].ty, sac as u64), "", false);
                return ic_new_cast(OP_ZEXT, nl, ty);
            }
        }
        let sx = m_sext(op0);
        if sx >= 0 {
            let sbw = ty_sbits(sx);
            if sbw == 1 {
                let nc = c_int_ap(ty, ap_low_bits(bw, bw - sac));
                return ic_new_select(sx, nc, c_null(ty));
            }
            if (!ty_is_int(ty) || should_change_type(ty, vals[sx].ty)) && one_use(op0) {
                if sac == bw - 1 {
                    let nl = icb_lshr(sx, c_int_ty(vals[sx].ty, (sbw - 1) as u64), "", false);
                    return ic_new_cast(OP_ZEXT, nl, ty);
                }
                if sac == bw - sbw {
                    let nsa = if sac < sbw - 1 { sac } else { sbw - 1 };
                    let a = icb_ashr(sx, c_int_ty(vals[sx].ty, nsa as u64), "", false);
                    return ic_new_cast(OP_ZEXT, a, ty);
                }
            }
        }
        if sac == bw - 1 {
            if one_use(op0) && bo(op0, OP_OR) {
                for k in 2 {
                    let x = op(op0, 1 - k);
                    if m_neg(op(op0, k)) == x && x >= 0 { return ic_new_cast(OP_ZEXT, icb_is_not_null(x, ""), ty); }
                }
            }
            if one_use(op0) && bo(op0, OP_SUB) && op_nsw(op0) { return ic_new_cast(OP_ZEXT, icb_icmp(40, op(op0, 0), op(op0, 1), ""), ty); }
            if one_use(op0) && bo(op0, OP_SREM) && m_specific_int(op(op0, 1), 2) {
                let x = op(op0, 0);
                let sb = icb_lshr(x, c_int_ty(ty, sac as u64), "", false);
                return ic_new_binop(OP_AND, sb, x);
            }
            if one_use(op0) && bo(op0, OP_AND) {
                for k in 2 {
                    let a = op(op0, k);
                    if bo(a, OP_ADD) && m_all_ones(op(a, 1)) {
                        let x = op(a, 0);
                        if m_not_of(op(op0, 1 - k), x) { return ic_new_cast(OP_ZEXT, icb_is_null(x, ""), ty); }
                    }
                }
            }
        }
        let ts = m_trunc(op0);
        if one_use(op0) && ts >= 0 && is_inst(ts) && bo(ts, OP_LSHR) && has_apint(op(ts, 1)) {
            let x = op(ts, 0);
            let c1 = ap_c(op(ts, 1));
            let sw = ty_sbits(x);
            let amt = sac + (ap_zext64(c1) as i64);
            if amt < sw && (has_one_use(ts) || ap_uge_u64(c1, (sw - bw) as u64)) {
                let ss = icb_lshr(x, c_int_ty(vals[x].ty, amt as u64), "sum.shift", false);
                var nm: u8[>..] = []; nm.append(val_name(i));
                let tr = icb_trunc(ss, ty, nm);
                return ic_new_binop(OP_AND, tr, c_int_ap(ty, ap_lshr(ap_ones(bw), sac)));
            }
        }
        if bo(op0, OP_MUL) && op_nuw(op0) && has_apint(op(op0, 1)) {
            let x = op(op0, 0);
            let mc = ap_c(op(op0, 1));
            if bw > 2 && ap_is_pow2(ap_dec(mc)) && ap_log2(mc) == sac {
                if sac * 2 == bw { return ic_replace_inst_uses_with(i, x); }
                if one_use(op0) {
                    let nl = icb_lshr(x, c_int_ty(ty, sac as u64), "", op_exact(i));
                    let na = ic_new_binop_flags(OP_ADD, x, nl, FL_NUW);
                    set_nsw(na, op_nsw(op0));
                    return na;
                }
            }
            if one_use(op0) {
                let nmc = ap_lshr(mc, sac);
                if ap_eq(mc, ap_shl(nmc, sac)) {
                    let nm = ic_new_binop_flags(OP_MUL, x, c_int_ap(ty, nmc), FL_NUW);
                    set_nsw(nm, true);
                    return nm;
                }
            }
        }
        if one_use(op0) && bo(op0, OP_MUL) && op_nsw(op0) && has_apint(op(op0, 1)) {
            let x = op(op0, 0);
            let mc = ap_c(op(op0, 1));
            if bw > 2 && ap_is_pow2(ap_dec(mc)) && ap_log2(mc) == sac {
                let nl = icb_lshr(x, c_int_ty(ty, sac as u64), "", op_exact(i));
                return ic_new_binop_flags(OP_ADD, x, nl, FL_NSW);
            }
        }
        if one_use(op0) && inst_iid(op0) == IID_bswap && one_use(op(op0, 0)) && m_zext(op(op0, 0)) >= 0 {
            ic_not_ported("narrowing bswap in visitLShr");
        }
        if sac == 1 && bo(op0, OP_ADD) {
            let x = op(op0, 0);
            let y = op(op0, 1);
            let bx = m_zext(x);
            let by = m_zext(y);
            if bx >= 0 && by >= 0 && is_int_ty1(vals[bx].ty) && is_int_ty1(vals[by].ty) && (one_use(x) || one_use(y) || one_use(op0)) {
                let an = icb_and(bx, by, "");
                return ic_new_cast(OP_ZEXT, an, ty);
            }
        }
    }
    if set_shift_flags(i) { return i; }
    if one_use(op0) && bo(op0, OP_SHL) && op(op0, 1) == op1 {
        let m = icb_lshr(c_all_ones(ty), op1, "", false);
        return ic_new_binop(OP_AND, m, op(op0, 0));
    }
    if bo(op0, OP_SHL) && m_all_ones(op(op0, 0)) && op(op0, 1) == op1 { return ic_new_binop(OP_LSHR, c_all_ones(ty), op1); }
    let ov = fold_lshr_overflow_bit(i);
    if ov >= 0 { return ov; }
    // ((pow2 << x) >> cttz(pow2 << y)) -> ((1 << x) >> y)
    if bo(op0, OP_SHL) && inst_iid(op1) == IID_cttz && bo(op(op1, 0), OP_SHL) && op(op(op1, 0), 0) == op(op0, 0) {
        let s0 = op(op0, 0);
        let shl1 = op(op1, 0);
        kb_cxt = i;
        if is_known_pow2(s0, true, 0) {
            let nuw = op_nuw(op0) && op_nuw(shl1);
            let nsw = op_nsw(op0) && op_nsw(shl1);
            if nuw || nsw {
                let ns = icb_shl_nw(c_int_ty(vals[shl1].ty, 1), op(op0, 1), "", nuw, nsw);
                return ic_new_binop(OP_LSHR, ns, op(shl1, 1));
            }
        }
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// visitAShr

// foldVariableSignZeroExtensionOfVariableHighBitExtract(OldAShr): the outer pattern only, then not ported
fn fold_variable_sign_zero_ext_of_high_bit_extract(a: i32) -> i32 {
    let s = op(a, 0);
    if bo(s, OP_SHL) && is_inst(op(s, 0)) && bo(m_zext_or_self(op(s, 1)), OP_SUB) && bo(m_zext_or_self(op(a, 1)), OP_SUB) {
        let s1 = m_zext_or_self(op(s, 1));
        let s2 = m_zext_or_self(op(a, 1));
        if is_const(op(s1, 0)) && is_const(op(s2, 0)) && m_zext_or_self(op(s1, 1)) == m_zext_or_self(op(s2, 1)) {
            ic_not_ported("foldVariableSignZeroExtensionOfVariableHighBitExtract");
        }
    }
    return -1;
}

fn visit_ashr(i: i32) -> i32 {
    let v0 = simplify_ashr(op(i, 0), op(i, 1), op_exact(i), sq_at(i), RECURSION_LIMIT);
    if v0 >= 0 { return ic_replace_inst_uses_with(i, v0); }
    let x0 = fold_vector_binop(i);
    if x0 >= 0 { return x0; }
    let r = common_shift_transforms(i);
    if r >= 0 { return r; }
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    let ty = vals[i].ty;
    let bw = ty_scalar_bits(ty);
    if has_apint(op1) && ap_ult_u64(ap_c(op1), bw as u64) {
        var sa = ap_zext64(ap_c(op1)) as i64;
        // ashr (shl (zext X), C), C --> sext X
        if bo(op0, OP_SHL) && op(op0, 1) == op1 && m_zext(op(op0, 0)) >= 0 {
            let x = m_zext(op(op0, 0));
            if sa == bw - ty_sbits(x) { return ic_new_cast(OP_SEXT, x, ty); }
        }
        if bo(op0, OP_SHL) && op_nsw(op0) && has_apint(op(op0, 1)) && ap_ult_u64(ap_c(op(op0, 1)), bw as u64) {
            let x = op(op0, 0);
            let shl = ap_zext64(ap_c(op(op0, 1))) as i64;
            if shl < sa {
                let na = ic_new_binop(OP_ASHR, x, c_int_ty(ty, (sa - shl) as u64));
                set_exact(na, op_exact(i));
                return na;
            }
            if shl > sa {
                let ns = ic_new_binop(OP_SHL, x, c_int_ty(ty, (shl - sa) as u64));
                set_nsw(ns, true);
                return ns;
            }
        }
        if bo(op0, OP_ASHR) && has_apint(op(op0, 1)) && ap_ult_u64(ap_c(op(op0, 1)), bw as u64) {
            var amt = sa + (ap_zext64(ap_c(op(op0, 1))) as i64);
            if amt > bw - 1 { amt = bw - 1; }
            return ic_new_binop(OP_ASHR, op(op0, 0), c_int_ty(ty, amt as u64));
        }
        if one_use(op0) && m_sext(op0) >= 0 {
            let x = m_sext(op0);
            if ty_is_vector(ty) || should_change_type(ty, vals[x].ty) {
                let st = vals[x].ty;
                let sbw = ty_scalar_bits(st);
                if sa > sbw - 1 { sa = sbw - 1; }
                let ns = icb_ashr(x, c_int_ty(st, sa as u64), "", false);
                return ic_new_cast(OP_SEXT, ns, ty);
            }
        }
        if sa == bw - 1 {
            if one_use(op0) && bo(op0, OP_OR) {
                for k in 2 {
                    let x = op(op0, 1 - k);
                    if m_neg(op(op0, k)) == x && x >= 0 { return ic_new_cast(OP_SEXT, icb_is_not_null(x, ""), ty); }
                }
            }
            if one_use(op0) && bo(op0, OP_SUB) && op_nsw(op0) { return ic_new_cast(OP_SEXT, icb_icmp(40, op(op0, 0), op(op0, 1), ""), ty); }
            if one_use(op0) && bo(op0, OP_AND) {
                for k in 2 {
                    let a = op(op0, k);
                    if bo(a, OP_ADD) && m_all_ones(op(a, 1)) {
                        let x = op(a, 0);
                        if m_not_of(op(op0, 1 - k), x) { return ic_new_cast(OP_SEXT, icb_is_null(x, ""), ty); }
                    }
                }
            }
        }
        if one_use(op0) && bo(op0, OP_MUL) && op_nsw(op0) && has_apint(op(op0, 1)) {
            let mc = ap_c(op(op0, 1));
            if bw > 2 && ap_is_pow2(ap_dec(mc)) && ap_log2(mc) == sa && sa < bw - 1 {
                let x = op(op0, 0);
                let na = icb_ashr(x, c_int_ty(ty, sa as u64), "", op_exact(i));
                let ad = ic_new_binop_flags(OP_ADD, x, na, FL_NSW);
                set_nuw(ad, op_nuw(op0));
                return ad;
            }
        }
    }
    if set_shift_flags(i) { return i; }
    // (x << (bw-1)) a>> (bw-1) --> -(x & 1)
    if m_specific_int_allow_poison(op1, (bw - 1) as u64) && one_use(op0) && bo(op0, OP_SHL) && m_specific_int_allow_poison(op(op0, 1), (bw - 1) as u64) {
        var mask = c_int_ty(ty, 1);
        if ty_is_vector(ty) { ic_not_ported("Constant::mergeUndefsWith"); }
        let x = icb_and(op(op0, 0), mask, "");
        return ic_new_neg(x);
    }
    let fv = fold_variable_sign_zero_ext_of_high_bit_extract(i);
    if fv >= 0 { return fv; }
    kb_cxt = i;
    if masked_value_is_zero(op0, ap_sign_mask(bw), 0) {
        let ls = ic_new_binop(OP_LSHR, op0, op1);
        set_exact(ls, op_exact(i));
        return ls;
    }
    if one_use(op0) && m_not(op0) >= 0 {
        var nm: u8[>..] = []; nm.append(val_name(op0)); nm.append(".not");
        let na = icb_ashr(m_not(op0), op1, nm, false);
        return ic_new_not(na);
    }
    return -1;
}
