// InstCombine integer casts: port of llvm/lib/Transforms/InstCombine/InstCombineCasts.cpp (commonCastTransforms,
// isEliminableCastPair, the TypeEvaluationHelper (canEvaluateTruncated/ZExtd/SExtd), EvaluateInDifferentType,
// visitTrunc, narrowBinOp, visitZExt, transformZExtICmp, visitSExt, transformSExtICmp). The FP casts,
// ptrtoint/inttoptr, bitcast and addrspacecast visitors are not ported (they fail loudly).
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
import ic_shifts;
import apfloat;

// InstCombinerImpl::isEliminableCastPair(CI1, CI2) (with the DataLayout cases of CastInst::isEliminableCastPair)
fn ic_eliminable_cast_pair(c1: i32, c2: i32) -> i64 {
    let src = vals[op(c1, 0)].ty;
    let mid = vals[c1].ty;
    let dst = vals[c2].ty;
    let first = iop(c1);
    let second = iop(c2);
    var res = eliminable_cast_pair(first, second, src, mid, dst);
    if first == OP_PTRTOINT && second == OP_INTTOPTR {
        // case 7
        res = 0;
        if src == dst && ty_scalar_bits(mid) >= dl_ptr(ptr_as(src)).bits { res = OP_BITCAST; }
    } else if first == OP_INTTOPTR && (second == OP_PTRTOINT || second == OP_PTRTOADDR) {
        // case 11
        let ms = if second == OP_PTRTOADDR { dl_ptr(ptr_as(mid)).idx } else { dl_ptr(ptr_as(mid)).bits };
        let ss = ty_scalar_bits(src);
        let ds = ty_scalar_bits(dst);
        if ms < ss && ms < ds { res = 0; }
        else if ds < ss { res = OP_TRUNC; }
        else if ds > ss { res = OP_ZEXT; }
        else { res = OP_BITCAST; }
    }
    let src_ip = if is_ptr_or_ptr_vec(src) { ic_int_ptr_type(src) } else { -1 };
    let dst_ip = if is_ptr_or_ptr_vec(dst) { ic_int_ptr_type(dst) } else { -1 };
    if (res == OP_INTTOPTR && src != dst_ip) || (res == OP_PTRTOINT && dst != src_ip) { res = 0; }
    return res;
}
// DataLayout::getIntPtrType(Ty)
fn ic_int_ptr_type(t: i32) -> i32 {
    let it = ty_int(dl_ptr(ptr_as(t)).bits);
    if ty_is_vector(t) { return ty_vector(it, ty_count(t), ty_kind(t) == TK_SVEC); }
    return it;
}

// commonCastTransforms(CI)
fn common_cast_transforms(ci: i32) -> i32 {
    let src = op(ci, 0);
    let ty = vals[ci].ty;
    let o = iop(ci);
    let r0 = simplify_cast(o, src, ty, sq_at(ci), RECURSION_LIMIT);
    if r0 >= 0 { return ic_replace_inst_uses_with(ci, r0); }
    if is_cast_inst(src) {
        let no = ic_eliminable_cast_pair(src, ci);
        if no != 0 {
            let res = ic_new_cast(no, op(src, 0), ty);
            if has_one_use(src) && dbgrecs.len > 0 && dbg_records_use_value(src) { ic_not_ported("replaceAllDbgUsesWith (cast of cast)"); }
            return res;
        }
    }
    if is_select_inst(src) {
        let cmp = op(src, 0);
        let is_cmp = is_cmp_inst(cmp);
        if !is_cmp || vals[op(cmp, 0)].ty != vals[src].ty || (o == OP_TRUNC && should_change_type(vals[src].ty, ty)) {
            if o != OP_BITCAST || ic_elementwise_bitcast(ci) {
                let nv = fold_op_into_select(ci, src, false, false);
                if nv >= 0 {
                    if dbgrecs.len > 0 && dbg_records_use_value(src) { ic_not_ported("replaceAllDbgUsesWith (cast of select)"); }
                    return nv;
                }
            }
        }
    }
    if is_phi_inst(src) {
        if !ty_is_int(vals[src].ty) || !ty_is_int(ty) || should_change_type(vals[src].ty, ty) {
            let nv = fold_op_into_phi(ci, src, false);
            if nv >= 0 { return nv; }
        }
    }
    if one_use(src) && is_inst_op(src, OP_SHUFFLEVECTOR) && is_poison(op(src, 1)) {
        ic_not_ported("commonCastTransforms of a unary shuffle");
    }
    return -1;
}
fn ic_elementwise_bitcast(ci: i32) -> bool {
    let s = vals[op(ci, 0)].ty;
    let d = vals[ci].ty;
    if ty_is_vector(s) != ty_is_vector(d) { return false; }
    if ty_is_vector(s) { return ty_count(s) == ty_count(d); }
    return true;
}

// ---------------------------------------------------------------------------------------------
// TypeEvaluationHelper: Visited (value -> result, -1 while in progress = false) and Pending, as pairs

var te_vk: i32[>..<];
var te_vv: i8[>..<];
var te_pending: i32[>..<];

fn te_reset() { te_vk.resize(0); te_vv.resize(0); te_pending.resize(0); }
fn te_find(v: i32) -> i64 { for k in te_vk.len { if te_vk[k] == v { return k; } } return -1; }
fn te_all_pending_visited() -> bool {
    for p in te_pending { if te_find(p) < 0 { return false; } }
    return true;
}

// canAlwaysEvaluateInType(V, Ty)
fn can_always_evaluate_in_type(v: i32, ty: i32) -> bool {
    if is_constant(v) { return is_imm_c(v); }
    var x = m_zext_or_sext(v);
    if x < 0 { x = m_trunc(v); }
    return x >= 0 && vals[x].ty == ty;
}
// canNotEvaluateInType(V, Ty)
fn can_not_evaluate_in_type(v: i32) -> bool { !is_inst(v) || !has_one_use(v) }

// canEvaluate(V, Ty, Pred): kind 0 = truncated, 1 = sext'd
recursive fn te_can_evaluate(v: i32, ty: i32, kind: i64, cx: i32) -> bool {
    if can_always_evaluate_in_type(v, ty) { return true; }
    if !is_inst(v) { return false; }
    let k = te_find(v);
    if k >= 0 { return te_vv[k] != 0; }
    te_vk.push(v);
    te_vv.push(0);
    if !has_one_use(v) {
        var u = vals[v].first_use;
        while u >= 0 {
            let us = uses[u].user;
            let opno = (u - vals[us].ops) as i64;
            u = uses[u].next;
            if is_select_inst(us) && opno == 0 { return false; }
            te_pending.push(us);
        }
    }
    let r = if kind == 0 { te_truncated_pred(v, ty, cx) } else { te_sextd_pred(v, ty) };
    let k2 = te_find(v);
    te_vv[k2] = if r { 1 } else { 0 };
    return r;
}

// canEvaluateTruncatedPred
recursive fn te_truncated_pred(v: i32, ty: i32, cx: i32) -> bool {
    let o = iop(v);
    let ot = vals[v].ty;
    if o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_XOR {
        return te_can_evaluate(op(v, 0), ty, 0, cx) && te_can_evaluate(op(v, 1), ty, 0, cx);
    }
    if o == OP_UDIV || o == OP_UREM {
        let obw = ty_scalar_bits(ot);
        let bw = ty_scalar_bits(ty);
        let mask = ap_bits_from(obw, bw);
        kb_cxt = v;
        if masked_value_is_zero(op(v, 0), mask, 0) {
            kb_cxt = v;
            if masked_value_is_zero(op(v, 1), mask, 0) {
                return te_can_evaluate(op(v, 0), ty, 0, cx) && te_can_evaluate(op(v, 1), ty, 0, cx);
            }
        }
        return false;
    }
    if o == OP_SHL {
        let bw = ty_scalar_bits(ty);
        kb_cxt = -1;
        let ak = kb_compute_all(op(v, 1), 0);
        if ap_ult_u64(kb_max(ak), bw as u64) { return te_can_evaluate(op(v, 0), ty, 0, cx) && te_can_evaluate(op(v, 1), ty, 0, cx); }
        return false;
    }
    if o == OP_LSHR {
        let obw = ty_scalar_bits(ot);
        let bw = ty_scalar_bits(ty);
        kb_cxt = cx;
        let ak = kb_compute_all(op(v, 1), 0);
        let maxsa = kb_max(ak);
        let shifted = ap_bits_from(obw, bw);
        if ap_ult_u64(maxsa, bw as u64) {
            let ub = uses[vals[v].first_use].user;
            if is_inst_op(ub, OP_TRUNC) {
                let db = ty_scalar_bits(vals[ub].ty);
                if ap_ule_u64(ap_add(maxsa, ap_u64(db as u64, obw)), bw as u64) {
                    return te_can_evaluate(op(v, 0), ty, 0, cx) && te_can_evaluate(op(v, 1), ty, 0, cx);
                }
            }
            kb_cxt = cx;
            if masked_value_is_zero(op(v, 0), shifted, 0) {
                return te_can_evaluate(op(v, 0), ty, 0, cx) && te_can_evaluate(op(v, 1), ty, 0, cx);
            }
        }
        return false;
    }
    if o == OP_ASHR {
        let obw = ty_scalar_bits(ot);
        let bw = ty_scalar_bits(ty);
        kb_cxt = -1;
        let ak = kb_compute_all(op(v, 1), 0);
        let sb = obw - bw;
        if ap_ult_u64(kb_max(ak), bw as u64) {
            kb_cxt = cx;
            if sb < num_sign_bits(op(v, 0), 0) { return te_can_evaluate(op(v, 0), ty, 0, cx) && te_can_evaluate(op(v, 1), ty, 0, cx); }
        }
        return false;
    }
    if o == OP_TRUNC || o == OP_ZEXT || o == OP_SEXT { return true; }
    if o == OP_SELECT { return te_can_evaluate(op(v, 1), ty, 0, cx) && te_can_evaluate(op(v, 2), ty, 0, cx); }
    if o == OP_PHI {
        for k in nops(v) { if !te_can_evaluate(op(v, k), ty, 0, cx) { return false; } }
        return true;
    }
    if o == OP_FPTOUI || o == OP_FPTOSI { ic_not_ported("canEvaluateTruncated of fptoui/fptosi"); }
    if o == OP_SHUFFLEVECTOR { return te_can_evaluate(op(v, 0), ty, 0, cx) && te_can_evaluate(op(v, 1), ty, 0, cx); }
    if o == OP_CALL {
        let id = inst_iid(v);
        if id == IID_abs || is_minmax_iid(id) { ic_not_ported("canEvaluateTruncated of abs/min/max"); }
        return false;
    }
    return false;
}

// canEvaluateSExtdPred
recursive fn te_sextd_pred(v: i32, ty: i32) -> bool {
    let o = iop(v);
    if o == OP_SEXT || o == OP_ZEXT || o == OP_TRUNC { return true; }
    if o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_ADD || o == OP_SUB || o == OP_MUL {
        return te_can_evaluate(op(v, 0), ty, 1, -1) && te_can_evaluate(op(v, 1), ty, 1, -1);
    }
    if o == OP_SELECT { return te_can_evaluate(op(v, 1), ty, 1, -1) && te_can_evaluate(op(v, 2), ty, 1, -1); }
    if o == OP_PHI {
        for k in nops(v) { if !te_can_evaluate(op(v, k), ty, 1, -1) { return false; } }
        return true;
    }
    return false;
}

fn can_evaluate_truncated(v: i32, ty: i32, cx: i32) -> bool {
    te_reset();
    return te_can_evaluate(v, ty, 0, cx) && te_all_pending_visited();
}
fn can_evaluate_sextd(v: i32, ty: i32) -> bool {
    te_reset();
    return te_can_evaluate(v, ty, 1, -1) && te_all_pending_visited();
}

// canEvaluateZExtdImpl(V, Ty, BitsToClear, IC, CxtI): returns ok, bits_to_clear
recursive fn can_evaluate_zextd(v: i32, ty: i32, cx: i32) -> bool, i64 {
    if can_always_evaluate_in_type(v, ty) { return true, 0; }
    if can_not_evaluate_in_type(v) { return false, 0; }
    let o = iop(v);
    if o == OP_ZEXT || o == OP_SEXT || o == OP_TRUNC { return true, 0; }
    if o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_ADD || o == OP_SUB || o == OP_MUL {
        let ok0, btc = can_evaluate_zextd(op(v, 0), ty, cx);
        if !ok0 { return false, btc; }
        let ok1, tmp = can_evaluate_zextd(op(v, 1), ty, cx);
        if !ok1 { return false, btc; }
        if btc == 0 && tmp == 0 { return true, 0; }
        if tmp == 0 && is_logic_op(o) {
            let vs = ty_sbits(v);
            kb_cxt = cx;
            if masked_value_is_zero(op(v, 1), highb(vs, btc), 0) {
                if o == OP_AND { return true, 0; }
                return true, btc;
            }
        }
        return false, btc;
    }
    if o == OP_SHL {
        if has_apint(op(v, 1)) && ap_fits_u64(ap_c(op(v, 1))) {
            // m_ConstantInt(uint64_t &) matches splats too
            let sa = ap_zext64(ap_c(op(v, 1))) as i64;
            let ok, btc = can_evaluate_zextd(op(v, 0), ty, cx);
            if !ok { return false, btc; }
            return true, if (sa as u64) < (btc as u64) { btc - sa } else { 0 };
        }
        return false, 0;
    }
    if o == OP_LSHR {
        if has_apint(op(v, 1)) && ap_fits_u64(ap_c(op(v, 1))) {
            // m_ConstantInt(uint64_t &) matches splats too
            let sa = ap_zext64(ap_c(op(v, 1))) as i64;
            let ok, btc0 = can_evaluate_zextd(op(v, 0), ty, cx);
            if !ok { return false, btc0; }
            var btc = btc0 + sa;
            if btc > ty_sbits(v) { btc = ty_sbits(v); }
            return true, btc;
        }
        return false, 0;
    }
    if o == OP_SELECT {
        let ok1, tmp = can_evaluate_zextd(op(v, 1), ty, cx);
        if !ok1 { return false, 0; }
        let ok2, btc = can_evaluate_zextd(op(v, 2), ty, cx);
        if !ok2 || tmp != btc { return false, btc; }
        return true, btc;
    }
    if o == OP_PHI {
        let ok0, btc = can_evaluate_zextd(op(v, 0), ty, cx);
        if !ok0 { return false, btc; }
        for k in 1..nops(v) {
            let ok, tmp = can_evaluate_zextd(op(v, k), ty, cx);
            if !ok || tmp != btc { return false, btc; }
        }
        return true, btc;
    }
    if o == OP_CALL { return inst_iid(v) == IID_vscale, 0; }
    return false, 0;
}

// EvaluateInDifferentType(V, Ty, isSigned): Processed map as pairs
var ed_k: i32[>..<];
var ed_v: i32[>..<];
recursive fn evaluate_in_different_type_impl(v: i32, ty: i32, signed: bool) -> i32 {
    for k in ed_k.len { if ed_k[k] == v { return ed_v[k]; } }
    if is_constant(v) { return cf_fold_integer_cast(v, ty, signed); }
    let o = iop(v);
    var res: i32 = -1;
    if o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_ASHR ||
       o == OP_LSHR || o == OP_SHL || o == OP_UDIV || o == OP_UREM {
        let l = evaluate_in_different_type_impl(op(v, 0), ty, signed);
        let r = evaluate_in_different_type_impl(op(v, 1), ty, signed);
        res = ic_new_binop(o, l, r);
        if o == OP_LSHR || o == OP_ASHR { set_exact(res, op_exact(v)); }
    } else if o == OP_TRUNC || o == OP_ZEXT || o == OP_SEXT {
        if vals[op(v, 0)].ty == ty { return op(v, 0); }
        res = ic_new_int_cast(op(v, 0), ty, o == OP_SEXT);
        if o == OP_TRUNC {
            if is_inst_op(res, OP_TRUNC) {
                if ty_sbits(v) <= ty_scalar_bits(ty) {
                    set_nsw(res, (insts[inst_of(v)].flags & FL_NSW) != 0);
                    set_nuw(res, (insts[inst_of(v)].flags & FL_NUW) != 0);
                }
            } else if is_inst_op(res, OP_ZEXT) {
                if (insts[inst_of(v)].flags & FL_NUW) != 0 { set_nneg(res, true); }
            }
        }
    } else if o == OP_SELECT {
        let t = evaluate_in_different_type_impl(op(v, 1), ty, signed);
        let f = evaluate_in_different_type_impl(op(v, 2), ty, signed);
        res = ic_new_select(op(v, 0), t, f);
    } else if o == OP_PHI {
        let np = new_inst(OP_PHI, ty, nops(v));
        vals[np].nops = 0;
        for k in nops(v) {
            let x = evaluate_in_different_type_impl(op(v, k), ty, signed);
            phi_add_incoming(np, x, phi_block(v, k));
        }
        res = np;
    } else if o == OP_FPTOUI || o == OP_FPTOSI {
        res = ic_new_cast(o, op(v, 0), ty);
    } else if o == OP_CALL {
        let id = inst_iid(v);
        if id == IID_vscale { res = ic_new_intrinsic(IID_vscale, [ty], []); }
        else if is_minmax_iid(id) {
            let a = evaluate_in_different_type_impl(op(v, 0), ty, signed);
            let b = evaluate_in_different_type_impl(op(v, 1), ty, signed);
            res = ic_new_intrinsic(id, [ty], [a, b]);
        } else if id == IID_abs {
            let a = evaluate_in_different_type_impl(op(v, 0), ty, signed);
            let f = c_false();
            res = ic_new_intrinsic(id, [ty], [a, f]);
        } else { fatal("Unsupported call!"); }
    } else if o == OP_SHUFFLEVECTOR {
        ic_not_ported("EvaluateInDifferentType of a shufflevector");
    } else {
        fatal("Unreachable!");
    }
    ic_take_name(res, v);
    let result = ic_insert_new_with(res, v);
    if !has_one_use(v) { ed_k.push(v); ed_v.push(result); }
    return result;
}
fn evaluate_in_different_type(v: i32, ty: i32, signed: bool) -> i32 {
    ed_k.resize(0);
    ed_v.resize(0);
    return evaluate_in_different_type_impl(v, ty, signed);
}
// CastInst::CreateIntegerCast(V, Ty, isSigned)
fn ic_new_int_cast(v: i32, ty: i32, signed: bool) -> i32 {
    let sb = ty_scalar_bits(vals[v].ty);
    let db = ty_scalar_bits(ty);
    let o = if sb == db { OP_BITCAST } else if sb > db { OP_TRUNC } else if signed { OP_SEXT } else { OP_ZEXT };
    return ic_new_cast(o, v, ty);
}
// IRBuilder::CreateIntCast(V, DestTy, isSigned, Name)
fn icb_int_cast(v: i32, ty: i32, signed: bool, name: const u8[:]) -> i32 {
    if vals[v].ty == ty { return v; }
    let sb = ty_scalar_bits(vals[v].ty);
    let db = ty_scalar_bits(ty);
    let o = if sb == db { OP_BITCAST } else if sb > db { OP_TRUNC } else if signed { OP_SEXT } else { OP_ZEXT };
    return icb_cast(o, v, ty, name);
}

// ---------------------------------------------------------------------------------------------
// visitTrunc

// narrowBinOp(Trunc)
fn narrow_binop(tr: i32) -> i32 {
    let st = vals[op(tr, 0)].ty;
    let dt = vals[tr].ty;
    let sw = ty_scalar_bits(st);
    let dw = ty_scalar_bits(dt);
    if !ty_is_vector(st) && !should_change_type(st, dt) { return -1; }
    let b = op(tr, 0);
    if !one_use(b) || !is_binop_inst(b) { return -1; }
    let b0 = op(b, 0);
    let b1 = op(b, 1);
    let o = iop(b);
    if o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_ADD || o == OP_SUB || o == OP_MUL {
        if is_const(b0) {
            let nc = ce_cast(OP_TRUNC, b0, dt);
            let tx = icb_trunc(b1, dt, "");
            return ic_new_binop(o, nc, tx);
        }
        if is_const(b1) {
            let nc = ce_cast(OP_TRUNC, b1, dt);
            let tx = icb_trunc(b0, dt, "");
            return ic_new_binop(o, tx, nc);
        }
        let x0 = m_zext_or_sext(b0);
        if x0 >= 0 && vals[x0].ty == dt { let n1 = icb_trunc(b1, dt, ""); return ic_new_binop(o, x0, n1); }
        let x1 = m_zext_or_sext(b1);
        if x1 >= 0 && vals[x1].ty == dt { let n0 = icb_trunc(b0, dt, ""); return ic_new_binop(o, n0, x1); }
    } else if o == OP_LSHR || o == OP_ASHR {
        let a = m_trunc(b0);
        if a >= 0 && is_const(b1) {
            let msa = sw - dw;
            if c_all_elts_cmp(b1, 37, msa as u64) {
                let sa = cf_fold_integer_cast(b1, vals[a].ty, true);
                if sa >= 0 {
                    if ty_is_vector(dt) { ic_not_ported("Constant::mergeUndefsWith in narrowBinOp"); }
                    var nm: u8[>..] = []; nm.append(val_name(b));
                    let sh = if o == OP_ASHR { icb_ashr(a, sa, nm, op_exact(b)) } else { icb_lshr(a, sa, nm, op_exact(b)) };
                    return ic_new_trunc_or_bitcast(sh, dt);
                }
            }
        }
    }
    // narrowFunnelShift
    if bo(b, OP_OR) && is_shift_inst(op(b, 0)) && is_shift_inst(op(b, 1)) { ic_not_ported("narrowFunnelShift"); }
    if is_minmax_iid(inst_iid(b)) || inst_iid(b) == IID_fshl || inst_iid(b) == IID_fshr { ic_not_ported("narrowFunnelShift"); }
    return -1;
}
fn ic_new_trunc_or_bitcast(v: i32, ty: i32) -> i32 {
    if ty_scalar_bits(vals[v].ty) == ty_scalar_bits(ty) { return ic_new_cast(OP_BITCAST, v, ty); }
    return ic_new_cast(OP_TRUNC, v, ty);
}

fn visit_trunc(tr: i32) -> i32 {
    let r = common_cast_transforms(tr);
    if r >= 0 { return r; }
    let src = op(tr, 0);
    let dt = vals[tr].ty;
    let st = vals[src].ty;
    let dw = ty_scalar_bits(dt);
    let sw = ty_scalar_bits(st);
    if (ty_is_vector(dt) || should_change_type(st, dt)) && can_evaluate_truncated(src, dt, tr) {
        let res = evaluate_in_different_type(src, dt, false);
        return ic_replace_inst_uses_with(tr, res);
    }
    if ty_is_int(dt) && dw * 2 < sw {
        let ndt = ty_int(dw * 2);
        if should_change_type(st, ndt) && can_evaluate_truncated(src, ndt, tr) {
            let res = evaluate_in_different_type(src, ndt, false);
            return ic_new_cast(OP_TRUNC, res, dt);
        }
    }
    if simplify_demanded_instruction_bits(tr) { return tr; }
    let zero = c_null(st);
    if dw == 1 {
        if one_use(src) && is_shr_inst(src) && bo(op(src, 0), OP_SHL) && m_power2(op(op(src, 0), 0)) && is_imm_c(op(src, 1)) {
            let c1 = ap_c(op(op(src, 0), 0));
            let l2 = c_int_ty(st, ap_exact_log2(c1) as u64);
            let cc = ce_binop(OP_SUB, op(src, 1), l2, 0);
            return ic_new_icmp(32, op(op(src, 0), 1), cc);
        }
        if is_shr_inst(src) && m_specific_int(op(src, 1), (sw - 1) as u64) { return ic_new_icmp(40, op(src, 0), zero); }
        if one_use(src) && bo(src, OP_LSHR) && is_imm_c(op(src, 1)) {
            let one = c_int_ty(st, 1);
            let mc = icb_shl(one, op(src, 1), "");
            let an = icb_and(op(src, 0), mc, "");
            return ic_new_icmp(33, an, zero);
        }
        if one_use(src) && bo(src, OP_OR) {
            for k in 2 {
                let l = op(src, k);
                let x = op(src, 1 - k);
                if bo(l, OP_LSHR) && op(l, 0) == x && is_imm_c(op(l, 1)) {
                    let one = c_int_ty(st, 1);
                    let mc = icb_shl(one, op(l, 1), "");
                    let an = icb_and(x, icb_or(mc, one, ""), "");
                    return ic_new_icmp(33, an, zero);
                }
            }
        }
        if bo(src, OP_SHL) && has_apint(op(src, 0)) && ap_get_bit(ap_c(op(src, 0)), 0) { return ic_new_icmp(32, op(src, 1), zero); }
        let tfl = insts[inst_of(tr)].flags;
        if (tfl & (FL_NUW | FL_NSW)) != 0 && bo(src, OP_XOR) { return ic_new_icmp(33, op(src, 0), op(src, 1)); }
        if one_use(src) && inst_iid(src) == IID_usub_sat && m_one(op(src, 0)) { return ic_new_icmp(32, op(src, 1), c_null(st)); }
    }
    // trunc(u/smin(zext(a) + zext(b), MAX)) --> uadd.sat(a, b)
    if one_use(src) && (inst_iid(src) == IID_umin || inst_iid(src) == IID_smin) {
        let ad = op(src, 0);
        if one_use(ad) && bo(ad, OP_ADD) && m_zext(op(ad, 0)) >= 0 && m_zext(op(ad, 1)) >= 0 && m_specific_int_apv(op(src, 1), ap_zext(ap_ones(dw), sw)) {
            let a = m_zext(op(ad, 0));
            let b = m_zext(op(ad, 1));
            if vals[a].ty == dt && vals[b].ty == dt { return ic_replace_inst_uses_with(tr, icb_binary_intrinsic(IID_uadd_sat, a, b, "")); }
        }
    }
    // trunc(smax(zext(a) - zext(b), 0)) --> usub.sat(a, b)
    if one_use(src) && inst_iid(src) == IID_smax && m_zero(op(src, 1)) {
        let sb = op(src, 0);
        if one_use(sb) && bo(sb, OP_SUB) && m_zext(op(sb, 0)) >= 0 && m_zext(op(sb, 1)) >= 0 {
            let a = m_zext(op(sb, 0));
            let b = m_zext(op(sb, 1));
            if vals[a].ty == dt && vals[b].ty == dt { return ic_replace_inst_uses_with(tr, icb_binary_intrinsic(IID_usub_sat, a, b, "")); }
        }
    }
    if bo(src, OP_LSHR) && m_sext(op(src, 0)) >= 0 && is_const(op(src, 1)) {
        let a = m_sext(op(src, 0));
        let c = op(src, 1);
        let aw = ty_sbits(a);
        let msa = sw - (if dw > aw { dw } else { aw });
        let exact = op_exact(src);
        if c_all_elts_cmp(c, 37, msa as u64) {
            if vals[a].ty == dt {
                let sa = trunc_get_new_sh_amt(c, st, dw, vals[a].ty);
                if ty_is_vector(dt) { ic_not_ported("Constant::mergeUndefsWith in visitTrunc"); }
                return ic_new_binop_flags(OP_ASHR, a, sa, if exact { FL_EXACT } else { 0 });
            }
            if one_use(src) {
                let sa = trunc_get_new_sh_amt(c, st, aw, vals[a].ty);
                let sh = icb_ashr(a, sa, "", exact);
                return ic_new_int_cast(sh, dt, true);
            }
        }
    }
    var rr = narrow_binop(tr);
    if rr >= 0 { return rr; }
    if one_use(src) && is_inst_op(src, OP_SHUFFLEVECTOR) { ic_not_ported("shrinkSplatShuffle"); }
    if one_use(src) && is_inst_op(src, OP_INSERTELEMENT) && is_poison(op(src, 0)) { ic_not_ported("shrinkInsertElt"); }
    if one_use(src) && (ty_is_vector(st) || should_change_type(st, dt)) {
        if bo(src, OP_SHL) && is_const(op(src, 1)) && !(is_shr_inst(op(src, 0)) && is_const(op(op(src, 0), 1))) {
            let a = op(src, 0);
            let c = op(src, 1);
            if c_all_elts_cmp(c, 36, dw as u64) {
                var nm: u8[>..] = []; nm.append(val_name(a)); nm.append(".tr");
                let nt = icb_trunc(a, dt, nm);
                return ic_new_binop(OP_SHL, nt, ce_cast(OP_TRUNC, c, dt));
            }
        }
    }
    if ty_is_int(st) && is_pow2_w(ty_bits(st)) && is_pow2_w(ty_bits(dt)) && one_use(src) && is_select_inst(src) {
        let c = op(src, 0);
        if one_use(c) && is_inst_op(c, OP_ICMP) && inst_pred(c) == 36 && op(src, 1) == op(c, 0) {
            ic_not_ported("trunc of a clamp select (smin/smax)");
        }
    }
    if is_inst_op(src, OP_BITCAST) || (is_shr_inst(src) && is_inst_op(op(src, 0), OP_BITCAST)) { ic_not_ported("foldVecTruncToExtElt"); }
    if is_inst_op(src, OP_EXTRACTELEMENT) || (is_shr_inst(src) && is_inst_op(op(src, 0), OP_EXTRACTELEMENT)) { ic_not_ported("foldVecExtTruncToExtElt"); }
    if one_use(src) && inst_iid(src) == IID_ctlz && m_zext(op(src, 0)) >= 0 {
        let a = m_zext(op(src, 0));
        let aw = ty_sbits(a);
        if aw == dw && aw > ap_log2(ap_u64(sw as u64, 64)) {
            let wd = c_int_ty(vals[a].ty, (sw - aw) as u64);
            let nc = icb_intrinsic(IID_ctlz, [dt], [a, op(src, 1)], "");
            return ic_new_binop(OP_ADD, nc, wd);
        }
    }
    if inst_iid(src) == IID_vscale { ic_not_ported("trunc of vscale"); }
    if dw >= 2 && (inst_iid(src) == IID_scmp || inst_iid(src) == IID_ucmp) && has_one_use(src) {
        return ic_replace_inst_uses_with(tr, icb_intrinsic(inst_iid(src), [dt, vals[op(src, 0)].ty], [op(src, 0), op(src, 1)], ""));
    }
    let tfl = insts[inst_of(tr)].flags;
    if dw == 1 && (tfl & (FL_NUW | FL_NSW)) != 0 {
        kb_cxt = tr;
        if is_known_non_zero(src, 0) { return ic_replace_inst_uses_with(tr, c_int_ty(dt, 1)); }
    }
    var changed = false;
    if (insts[inst_of(tr)].flags & FL_NSW) == 0 {
        kb_cxt = tr;
        let msb = sw - num_sign_bits(src, 0) + 1;
        if msb <= dw { insts[inst_of(tr)].flags |= FL_NSW; changed = true; }
    }
    if (insts[inst_of(tr)].flags & FL_NUW) == 0 {
        kb_cxt = tr;
        if masked_value_is_zero(src, ap_bits_from(sw, dw), 0) { insts[inst_of(tr)].flags |= FL_NUW; changed = true; }
    }
    if dw == 1 && is_shr_inst(src) {
        let c1v = op(src, 0);
        let v1 = op(src, 1);
        if m_power2(c1v) { return ic_new_icmp(32, v1, c_int_ty(vals[v1].ty, ap_countr_zero(ap_c(c1v)) as u64)); }
        if m_low_bit_mask(c1v) && has_apint(c1v) { return ic_new_icmp(36, v1, c_int_ty(vals[v1].ty, ap_countr_one(ap_c(c1v)) as u64)); }
        if m_cint_pred(c1v, IP_NEG_POWER2, true) && has_apint(c1v) { return ic_new_icmp(35, v1, c_int_ty(vals[v1].ty, ap_countr_zero(ap_c(c1v)) as u64)); }
    }
    return if changed { tr } else { -1 };
}
// GetNewShAmt (the lambda in visitTrunc)
fn trunc_get_new_sh_amt(c: i32, st: i32, width: i64, aty: i32) -> i32 {
    let maxamt = c_int_ty(st, (width - 1) as u64);
    let cmp = cf_fold_cmp_operands(36, c, maxamt, -1);
    let sa = cf_select(cmp, c, maxamt);
    return cf_fold_cast_operand(OP_TRUNC, sa, aty);
}

// ---------------------------------------------------------------------------------------------
// visitZExt

// transformZExtICmp(Cmp, Zext)
fn transform_zext_icmp(cmp: i32, zx: i32) -> i32 {
    let zt = vals[zx].ty;
    if has_apint(op(cmp, 1)) {
        let c = ap_c(op(cmp, 1));
        let p = inst_pred(cmp);
        if p == 40 && ap_is_zero(c) {
            var inv = op(cmp, 0);
            let it = vals[inv].ty;
            let sh = c_int_ty(it, (ty_scalar_bits(it) - 1) as u64);
            var nm: u8[>..] = []; nm.append(val_name(inv)); nm.append(".lobit");
            inv = icb_lshr(inv, sh, nm, false);
            if vals[inv].ty != zt { inv = icb_int_cast(inv, zt, false, ""); }
            return ic_replace_inst_uses_with(zx, inv);
        }
        if ap_is_zero(c) && icmp_is_equality(p) {
            kb_cxt = zx;
            let k = kb_compute_all(op(cmp, 0), 0);
            let kzm = ap_not(k.z);
            let sha = ap_log2(kzm);
            let expect = ap_is_pow2(kzm) && ty_scalar_bits(zt) != sha + 1;
            if expect && (vals[op(cmp, 0)].ty == zt || p == 33 || sha == 0) {
                var inv = op(cmp, 0);
                if sha != 0 {
                    var nm: u8[>..] = []; nm.append(val_name(inv)); nm.append(".lobit");
                    inv = icb_lshr(inv, c_int_ty(vals[inv].ty, sha as u64), nm, false);
                }
                if p == 32 { inv = icb_xor(inv, c_int_ty(vals[inv].ty, 1), ""); }
                if zt == vals[inv].ty { return ic_replace_inst_uses_with(zx, inv); }
                let ic_ = icb_int_cast(inv, zt, false, "");
                return ic_replace_inst_uses_with(zx, ic_);
            }
        }
    }
    if icmp_is_equality(inst_pred(cmp)) {
        if has_one_use(cmp) && m_zero_int(op(cmp, 1)) {
            let an = op(cmp, 0);
            if one_use(an) && bo(an, OP_AND) {
                for k in 2 {
                    let s = op(an, k);
                    if bo(s, OP_SHL) && m_one(op(s, 0)) {
                        var x = op(an, 1 - k);
                        let sha = op(s, 1);
                        let shift = s;
                        if zt == vals[an].ty || inst_pred(cmp) != 32 || has_one_use(shift) {
                            if inst_pred(cmp) == 32 { x = icb_not(x, ""); }
                            let ls = icb_lshr(x, sha, "", false);
                            let a1 = icb_and(ls, c_int_ty(vals[x].ty, 1), "");
                            return ic_replace_inst_uses_with(zx, icb_zext_or_trunc(a1, zt, ""));
                        }
                        break;
                    }
                }
            }
        }
    }
    return -1;
}

fn visit_zext(zx: i32) -> i32 {
    if has_one_use(zx) && is_inst_op(uses[vals[zx].first_use].user, OP_TRUNC) && !is_constant(op(zx, 0)) { return -1; }
    let r = common_cast_transforms(zx);
    if r >= 0 { return r; }
    let src = op(zx, 0);
    if is_inst_op(src, OP_EXTRACTVALUE) && inst_iid(op(src, 0)) != 0 && starts_with(intr_name(inst_iid(op(src, 0)) as i64), "llvm.vector.deinterleave") {
        ic_not_ported("foldExtractionOfVectorDeinterleave");
    }
    let st = vals[src].ty;
    let dt = vals[zx].ty;
    let nneg = (insts[inst_of(zx)].flags & FL_NNEG) != 0;
    if is_int_ty1(st) && nneg { return ic_replace_inst_uses_with(zx, c_null(dt)); }
    if should_change_type(st, dt) {
        let ok, btc = can_evaluate_zextd(src, dt, zx);
        if ok {
            let res = evaluate_in_different_type(src, dt, false);
            if is_inst(src) && has_one_use(src) && dbgrecs.len > 0 && dbg_records_use_value(src) { ic_not_ported("replaceAllDbgUsesWith in visitZExt"); }
            let kept = ty_scalar_bits(st) - btc;
            let dbs = ty_scalar_bits(dt);
            kb_cxt = zx;
            if masked_value_is_zero(res, ap_high_bits(dbs, dbs - kept), 0) { return ic_replace_inst_uses_with(zx, res); }
            return ic_new_binop(OP_AND, res, c_int_ap(vals[res].ty, ap_low_bits(dbs, kept)));
        }
    }
    if is_inst_op(src, OP_TRUNC) {
        let a = op(src, 0);
        let ss = ty_sbits(a);
        let ms = ty_sbits(src);
        let ds = ty_scalar_bits(dt);
        if ss < ds {
            let ac = c_int_ap(vals[a].ty, ap_low_bits(ss, ms));
            var nm: u8[>..] = []; nm.append(val_name(src)); nm.append(".mask");
            let an = icb_and(a, ac, nm);
            return ic_new_cast(OP_ZEXT, an, dt);
        }
        if ss == ds { return ic_new_binop(OP_AND, a, c_int_ap(vals[a].ty, ap_low_bits(ss, ms))); }
        if ss > ds {
            let t = icb_trunc(a, dt, "");
            return ic_new_binop(OP_AND, t, c_int_ap(vals[t].ty, ap_low_bits(ds, ms)));
        }
    }
    if is_inst_op(src, OP_ICMP) { return transform_zext_icmp(src, zx); }
    // zext((trunc(X) & C) ^ C) -> ((X & zext(C)) ^ zext(C))
    if one_use(src) && bo(src, OP_XOR) && is_const(op(src, 1)) {
        let an = op(src, 0);
        let c = op(src, 1);
        if one_use(an) && bo(an, OP_AND) && op(an, 1) == c && m_trunc(op(an, 0)) >= 0 && vals[m_trunc(op(an, 0))].ty == dt {
            let x = m_trunc(op(an, 0));
            let zc = icb_zext(c, dt, "");
            return ic_new_binop(OP_XOR, icb_and(x, zc, ""), zc);
        }
    }
    // zext(sub(0, trunc(X))) -> and(sub(0, X), mask)
    if bo(src, OP_SUB) && m_zero(op(src, 0)) && m_trunc(op(src, 1)) >= 0 && vals[m_trunc(op(src, 1))].ty == dt {
        let x = m_trunc(op(src, 1));
        let mask = ap_low_bits(ty_scalar_bits(dt), ty_scalar_bits(st));
        let ng = icb_sub(c_int_ty(dt, 0), x, "");
        return ic_new_binop(OP_AND, ng, c_int_ap(dt, mask));
    }
    // zext (and (trunc X), C) --> and X, (zext C)
    if bo(src, OP_AND) && m_trunc(op(src, 0)) >= 0 && is_const(op(src, 1)) && vals[m_trunc(op(src, 0))].ty == dt {
        let x = m_trunc(op(src, 0));
        let zc = icb_zext(op(src, 1), dt, "");
        return ic_new_binop(OP_AND, x, zc);
    }
    if one_use(src) && is_binop_inst(src) && is_logic_op(iop(src)) {
        for k in 2 {
            let t = op(src, k);
            let x = m_trunc(t);
            if x >= 0 && (insts[inst_of(t)].flags & FL_NUW) != 0 && vals[x].ty == dt {
                let zy = icb_zext(op(src, 1 - k), dt, "");
                return ic_new_binop(iop(src), x, zy);
            }
        }
    }
    if inst_iid(src) == IID_vscale { ic_not_ported("zext of vscale"); }
    if !nneg {
        if has_one_use(zx) && ty_scalar_bits(st) > ap_ceil_log2(ap_u64(ty_scalar_bits(dt) as u64, 64)) {
            let u = uses[vals[zx].first_use].user;
            if is_shift_inst(u) && op(u, 1) == zx {
                set_nneg(zx, true);
                return zx;
            }
        }
        if is_known_non_negative_v(src, zx) {
            set_nneg(zx, true);
            return zx;
        }
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// visitSExt

// transformSExtICmp(Cmp, Sext)
fn transform_sext_icmp(cmp: i32, sx: i32) -> i32 {
    let op0 = op(cmp, 0);
    let op1 = op(cmp, 1);
    let p = inst_pred(cmp);
    let st = vals[sx].ty;
    if !is_int_or_int_vec(vals[op1].ty) { return -1; }
    if p == 40 && m_zero_int(op1) {
        let sh = c_int_ty(vals[op0].ty, (ty_sbits(op0) - 1) as u64);
        var nm: u8[>..] = []; nm.append(val_name(op0)); nm.append(".lobit");
        var inv = icb_ashr(op0, sh, nm, false);
        if vals[inv].ty != st { inv = icb_int_cast(inv, st, true, ""); }
        return ic_replace_inst_uses_with(sx, inv);
    }
    if m_constant_int(op1) >= 0 {
        let c = ci_ap(op1);
        if has_one_use(cmp) && icmp_is_equality(p) && (ap_is_zero(c) || ap_is_pow2(c)) {
            kb_cxt = sx;
            let k = kb_compute_all(op0, 0);
            let kzm = ap_not(k.z);
            if ap_is_pow2(kzm) {
                var inv = op(cmp, 0);
                if !ap_is_zero(c) && !ap_eq(c, kzm) {
                    let v = if p == 33 { c_all_ones(st) } else { c_null(st) };
                    return ic_replace_inst_uses_with(sx, v);
                }
                if !ap_is_zero(c) == (p == 33) {
                    let sa = ap_countr_zero(kzm);
                    if sa != 0 { inv = icb_lshr(inv, c_int_ty(vals[inv].ty, sa as u64), "", false); }
                    inv = icb_add(inv, c_all_ones(vals[inv].ty), "sext");
                } else {
                    let sa = ap_countl_zero(kzm);
                    if sa != 0 { inv = icb_shl(inv, c_int_ty(vals[inv].ty, sa as u64), ""); }
                    inv = icb_ashr(inv, c_int_ty(vals[inv].ty, ((kzm.w as i64) - 1) as u64), "sext", false);
                }
                if st == vals[inv].ty { return ic_replace_inst_uses_with(sx, inv); }
                return ic_new_int_cast(inv, st, true);
            }
        }
    }
    return -1;
}

fn visit_sext(sx: i32) -> i32 {
    if has_one_use(sx) && is_inst_op(uses[vals[sx].first_use].user, OP_TRUNC) { return -1; }
    let r = common_cast_transforms(sx);
    if r >= 0 { return r; }
    let src = op(sx, 0);
    let st = vals[src].ty;
    let dt = vals[sx].ty;
    let sbs = ty_scalar_bits(st);
    let dbs = ty_scalar_bits(dt);
    if is_known_non_negative_v(src, sx) {
        let ci = ic_new_cast(OP_ZEXT, src, dt);
        set_nneg(ci, true);
        return ci;
    }
    var should_extend = true;
    let truncsrc = m_trunc(src);
    if truncsrc >= 0 && ty_sbits(truncsrc) > dbs { should_extend = false; }
    if should_extend && should_change_type(st, dt) && can_evaluate_sextd(src, dt) {
        let res = evaluate_in_different_type(src, dt, true);
        kb_cxt = sx;
        if num_sign_bits(res, 0) > dbs - sbs { return ic_replace_inst_uses_with(sx, res); }
        let sha = c_int_ty(dt, (dbs - sbs) as u64);
        return ic_new_binop(OP_ASHR, icb_shl(res, sha, "sext"), sha);
    }
    let x = truncsrc;
    if x >= 0 {
        let xbs = ty_sbits(x);
        let hnsw = (insts[inst_of(src)].flags & FL_NSW) != 0;
        var ok = hnsw;
        if !ok { kb_cxt = sx; ok = num_sign_bits(x, 0) > xbs - sbs; }
        if ok {
            let res = ic_new_int_cast(x, dt, true);
            if is_inst_op(res, OP_TRUNC) && hnsw { set_nsw(res, true); }
            return res;
        }
        if one_use(src) && vals[x].ty == dt {
            let sha = c_int_ty(dt, (dbs - sbs) as u64);
            return ic_new_binop(OP_ASHR, icb_shl(x, sha, ""), sha);
        }
        if one_use(src) && bo(x, OP_LSHR) && m_specific_int_allow_poison(op(x, 1), (xbs - sbs) as u64) {
            let y = op(x, 0);
            let a = icb_ashr(y, c_int_ty(vals[y].ty, (xbs - sbs) as u64), "", false);
            return ic_new_int_cast(a, dt, true);
        }
    }
    if is_inst_op(src, OP_ICMP) { return transform_sext_icmp(src, sx); }
    if bo(src, OP_ASHR) && bo(op(src, 0), OP_SHL) && m_trunc(op(op(src, 0), 0)) >= 0 && is_const(op(op(src, 0), 1)) && is_imm_c(op(src, 1)) {
        let a = m_trunc(op(op(src, 0), 0));
        let ba = op(op(src, 0), 1);
        let ca = op(src, 1);
        if ic_elementwise_equal(ba, ca) && vals[a].ty == dt {
            let wide = cf_fold_cast_operand(OP_SEXT, ca, dt);
            let nll = ce_binop(OP_SUB, c_int_ty(dt, sbs as u64), wide, 0);
            let nsa = ce_binop(OP_SUB, c_int_ty(dt, dbs as u64), nll, 0);
            if ty_is_vector(dt) { ic_not_ported("Constant::mergeUndefsWith in visitSExt"); }
            var nm: u8[>..] = []; nm.append(val_name(sx));
            let aa = icb_shl(a, nsa, nm);
            return ic_new_binop(OP_ASHR, aa, nsa);
        }
    }
    if one_use(src) && bo(src, OP_ASHR) && m_trunc(op(src, 0)) >= 0 && m_specific_int(op(src, 1), (sbs - 1) as u64) {
        let xx = m_trunc(op(src, 0));
        let xt = vals[xx].ty;
        let xbs = ty_scalar_bits(xt);
        let shlc = c_int_ty(xt, (xbs - sbs) as u64);
        let ashc = c_int_ty(xt, (xbs - 1) as u64);
        if xt == dt { return ic_new_binop(OP_ASHR, icb_shl(xx, shlc, ""), ashc); }
        if has_one_use(op(src, 0)) {
            let a = icb_ashr(icb_shl(xx, shlc, ""), ashc, "", false);
            return ic_new_int_cast(a, dt, true);
        }
    }
    if inst_iid(src) == IID_vscale { ic_not_ported("sext of vscale"); }
    if (inst_iid(src) == IID_scmp || inst_iid(src) == IID_ucmp) && has_one_use(src) {
        return ic_replace_inst_uses_with(sx, icb_intrinsic(inst_iid(src), [dt, vals[op(src, 0)].ty], [op(src, 0), op(src, 1)], ""));
    }
    if one_use(src) && is_binop_inst(src) && is_logic_op(iop(src)) {
        for k in 2 {
            let t = op(src, k);
            let xx = m_trunc(t);
            if xx >= 0 && (insts[inst_of(t)].flags & FL_NSW) != 0 && vals[xx].ty == dt {
                let sy = icb_sext(op(src, 1 - k), dt, "");
                return ic_new_binop(iop(src), xx, sy);
            }
        }
    }
    return -1;
}

// InstCombiner::canBeCastedExactlyIntToFP(V, FPTy, IsSigned, CxtI)
fn can_be_casted_exactly_int_to_fp(v: i32, fpty: i32, signed: bool, cx: i32) -> bool {
    let sty = vals[v].ty;
    let sw = ty_scalar_bits(sty);
    let src_size = sw - (if signed { 1 } else { 0 });
    let dk = types[ty_scalar(fpty)].kind as i64;
    let dsig = if dk == TK_PPC_FP128 { -1 } else { fp_fmt(dk).p };
    if src_size <= dsig { return true; }
    if is_inst_op(v, OP_FPTOSI) || is_inst_op(v, OP_FPTOUI) {
        let f = op(v, 0);
        let fk = types[ty_scalar(vals[f].ty)].kind as i64;
        var ssig = if fk == TK_PPC_FP128 { -1 } else { fp_fmt(fk).p };
        if !signed && is_inst_op(v, OP_FPTOSI) { ssig++; }
        if ssig > 0 && dsig > 0 && ssig <= dsig { return true; }
    }
    kb_cxt = cx;
    let k = kb_compute_all(v, 0);
    let sig = sw - kb_min_lz(k) - kb_min_tz(k);
    if sig <= dsig { return true; }
    if signed {
        kb_cxt = cx;
        let s2 = sw - num_sign_bits(v, 0);
        if s2 <= dsig { return true; }
    }
    return false;
}
