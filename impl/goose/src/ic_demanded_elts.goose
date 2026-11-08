// InstCombine SimplifyDemandedVectorElts: port of InstCombinerImpl::SimplifyDemandedVectorElts and
// canSkipDemandedEltsInInsertChain (llvm/lib/Transforms/InstCombine/InstCombineSimplifyDemanded.cpp).
// Target intrinsics (targetSimplifyDemandedVectorEltsIntrinsic) fail loudly for llvm.x86.*.
//
// The recursive function returns (replacement or -1, PoisonElts); DemandedElts and PoisonElts are APInts of
// the vector width. The `simplifyAndSetOp` lambda is sde_set_op (it uses the sde_changed global for
// MadeChange, saved around the recursion).
namespace ic;
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import intrinsics;
import domtree;
import constfold;
import pm;
import vt;
import apint;
import ic;
import ic_builder;
import ic_common;
import ic_andorxor;

let SDVE_DEPTH_LIMIT: i64 = 10;
var sde_changed: bool = false;

fn sde_mask_at(s: i32, k: i64) -> i64 { ints[insts[inst_of(s)].aux as i64 + k] as i64 }
fn sde_mask_len(s: i32) -> i64 { insts[inst_of(s)].naux as i64 }

// canSkipDemandedEltsInInsertChain(IE, VWidth, DepthLimit)
fn can_skip_demanded_elts_in_insert_chain(ie: i32, vw: i64, limit: i64) -> bool {
    if !has_one_use(ie) { return false; }
    let user = uses[vals[ie].first_use].user;
    if !is_inst_op(user, OP_INSERTELEMENT) || op(user, 0) != ie { return false; }
    var seen = ap_zero(vw);
    var cur = ie;
    for i in limit {
        let idx = m_constant_int(op(cur, 2));
        if idx < 0 || ap_uge_u64(ci_ap(idx), vw as u64) { return false; }
        let ix = ap_zext64(ci_ap(idx)) as i64;
        if ap_get_bit(seen, ix) { return false; }
        seen = ap_set_bit(seen, ix);
        let base = op(cur, 0);
        if vals[base].kind == VK_POISON { return true; }
        if !is_inst_op(base, OP_INSERTELEMENT) || !has_one_use(base) { return false; }
        cur = base;
    }
    return true;
}

// the simplifyAndSetOp lambda: (new PoisonElts of the operand)
recursive fn sde_set_op(i: i32, k: i64, demanded: AP, poison_in: AP, depth: i64) -> AP {
    let opv = op(i, k);
    let saved = sde_changed;
    let v, pe = sde_rec(opv, demanded, poison_in, depth + 1, false);
    sde_changed = saved;
    if v >= 0 {
        ic_replace_operand(i, k, v);
        sde_changed = true;
    }
    return pe;
}

// SimplifyDemandedVectorElts(V, DemandedElts, PoisonElts, 0, false) for a root value
fn ic_simplify_demanded_vector_elts_root(v: i32, demanded: AP) -> i32 {
    let saved = sde_changed;
    sde_changed = false;
    let r, pe = sde_rec(v, demanded, ap_zero(demanded.w as i64), 0, false);
    sde_changed = saved;
    return r;
}

// SimplifyDemandedVectorElts(V, DemandedElts, PoisonElts, Depth, AllowMultipleUsers)
recursive fn sde_rec(v: i32, demanded0: AP, poison_in: AP, depth: i64, allow_multi: bool) -> i32, AP {
    let vty = vals[v].ty;
    if ty_kind(vty) == TK_SVEC { return -1, poison_in; }
    let vw = ty_count(vty);
    let eltmask = ap_ones(vw);
    var demanded = demanded0;
    if vals[v].kind == VK_POISON { return -1, eltmask; }
    if ap_is_zero(demanded) { return c_poison(vty), eltmask; }
    var poison = ap_zero(vw);
    if is_constant(v) {
        if ap_is_all_ones(demanded) { return -1, poison; }
        let et = ty_elem(vty);
        let pz = c_poison(et);
        let mark = is_ops.len;
        for k in vw {
            if !ap_get_bit(demanded, k) {
                is_ops.push(pz);
                poison = ap_set_bit(poison, k);
                continue;
            }
            let e = agg_elem(v, k);
            if e < 0 { is_ops.resize(mark); return -1, poison; }
            is_ops.push(e);
            if vals[e].kind == VK_POISON { poison = ap_set_bit(poison, k); }
        }
        let ncv = c_aggregate(vty, is_ops[mark..is_ops.len]);
        is_ops.resize(mark);
        return if ncv != v { ncv } else { -1 }, poison;
    }
    if depth == SDVE_DEPTH_LIMIT { return -1, poison; }
    if !allow_multi {
        if !has_one_use(v) {
            if depth != 0 { return -1, poison; }
            demanded = eltmask;
        }
    }
    if !is_inst(v) { return -1, poison; }
    let i = v;
    sde_changed = false;
    var poison2 = ap_zero(vw);
    var poison3 = ap_zero(vw);
    let o = iop(i);
    if o == OP_GEP {
        // mayIndexStructType
        var has_struct = false;
        var t = gep_src_ty(i);
        for k in 2..nops(i) {
            if ty_kind(t) == TK_STRUCT { has_struct = true; break; }
            t = sde_gep_step(t);
        }
        if !has_struct {
            for k in nops(i) {
                let x = op(i, k);
                if (if k == 0 { m_undef(x) } else { vals[x].kind == VK_POISON }) { return -1, eltmask; }
                if ty_is_vector(vals[x].ty) {
                    let pe = sde_set_op(i, k, demanded, ap_zero(vw), depth);
                    if k == 0 { poison = ap_or(poison, pe); }
                }
            }
        }
    } else if o == OP_INSERTELEMENT {
        if depth == 0 && ap_is_all_ones(demanded) && vw > SDVE_DEPTH_LIMIT && can_skip_demanded_elts_in_insert_chain(i, vw, SDVE_DEPTH_LIMIT) {
            return -1, poison;
        }
        let idx = m_constant_int(op(i, 2));
        if idx < 0 {
            poison2 = sde_set_op(i, 0, demanded, poison2, depth);
        } else {
            let ixap = ci_ap(idx);
            let in_range = ap_ult_u64(ixap, vw as u64);
            let idxno = if in_range { ap_zext64(ixap) as i64 } else { -1 };
            var pre = demanded;
            if in_range { pre = ap_clear_bit(pre, idxno); }
            if ap_is_zero(pre) && is_inst_op(op(i, 1), OP_EXTRACTELEMENT) {
                let ex = op(i, 1);
                let vec = op(ex, 0);
                if m_specific_int(op(ex, 1), ap_zext64(ixap)) && vals[vec].ty == vals[i].ty {
                    return vec, poison;
                }
            }
            poison = sde_set_op(i, 0, pre, poison, depth);
            if !in_range || !ap_get_bit(demanded, idxno) {
                icw_push(i);
                return op(i, 0), poison;
            }
            poison = ap_clear_bit(poison, idxno);
        }
    } else if o == OP_SHUFFLEVECTOR {
        let opw = ty_count(vals[op(i, 0)].ty);
        let ml = sde_mask_len(i);
        var all_zero = true;
        for k in ml { if sde_mask_at(i, k) != 0 { all_zero = false; } }
        if all_zero && ap_is_all_ones(demanded) {
            if vals[op(i, 1)].kind != VK_POISON {
                set_op(i, 1, c_poison(vals[op(i, 1)].ty));
                sde_changed = true;
            }
            let lp = sde_set_op(i, 0, ap_u64(1, opw), ap_zero(opw), depth);
            if ap_get_bit(lp, 0) { poison = eltmask; } else { poison = ap_zero(vw); }
        } else {
            var ld = ap_zero(opw);
            var rd = ap_zero(opw);
            for k in vw {
                if ap_get_bit(demanded, k) {
                    let m = sde_mask_at(i, k);
                    if m >= 0 {
                        if m < opw { ld = ap_set_bit(ld, m); } else { rd = ap_set_bit(rd, m - opw); }
                    }
                }
            }
            let lp = sde_set_op(i, 0, ld, ap_zero(opw), depth);
            let rp = sde_set_op(i, 1, rd, ap_zero(opw), depth);
            if vw == opw {
                var ident = true;
                for k in vw {
                    let m = sde_mask_at(i, k);
                    if ap_get_bit(demanded, k) && k != m { ident = false; break; }
                }
                if ident { return op(i, 0), poison; }
            }
            var new_poison = false;
            var lidx: i64 = -1;
            var lvidx: i64 = -1;
            var ridx: i64 = -1;
            var rvidx: i64 = -1;
            var lu = true;
            var ru = true;
            for k in vw {
                let m = sde_mask_at(i, k);
                if m < 0 {
                    poison = ap_set_bit(poison, k);
                } else if !ap_get_bit(demanded, k) {
                    new_poison = true;
                    poison = ap_set_bit(poison, k);
                } else if m < opw {
                    if ap_get_bit(lp, m) {
                        new_poison = true;
                        poison = ap_set_bit(poison, k);
                    } else {
                        lidx = if lidx == -1 { k } else { opw };
                        lvidx = if lvidx == -1 { m } else { opw };
                        lu = lu && m == k;
                    }
                } else {
                    if ap_get_bit(rp, m - opw) {
                        new_poison = true;
                        poison = ap_set_bit(poison, k);
                    } else {
                        ridx = if ridx == -1 { k } else { opw };
                        rvidx = if rvidx == -1 { m - opw } else { opw };
                        ru = ru && (m - opw) == k;
                    }
                }
            }
            if opw == vw {
                var opv: i32 = -1;
                var value: i32 = -1;
                var idx: i64 = -1;
                if lidx >= 0 && lidx < opw && ru {
                    let cv = op(i, 0);
                    if vals[cv].kind == VK_CVECTOR {
                        opv = op(i, 1);
                        value = agg_elem(cv, lvidx);
                        idx = lidx;
                    }
                }
                if ridx >= 0 && ridx < opw && lu {
                    let cv = op(i, 1);
                    if vals[cv].kind == VK_CVECTOR {
                        opv = op(i, 0);
                        value = agg_elem(cv, rvidx);
                        idx = ridx;
                    }
                }
                if opv >= 0 && value >= 0 {
                    let ci = c_int_ty(T_I64, idx as u64);
                    let nw = create_inst(OP_INSERTELEMENT, vals[opv].ty, [opv, value, ci]);
                    var nm: u8[>..] = [];
                    nm.append(val_name(i));
                    set_name(nw, nm);
                    ic_insert_new_with(nw, i);
                    return nw, poison;
                }
            }
            if new_poison {
                let at = insts[inst_of(i)].aux as i64;
                for k in vw { if ap_get_bit(poison, k) { ints[at + k] = -1; } }
                sde_changed = true;
            }
        }
    } else if o == OP_SELECT {
        let cond = op(i, 0);
        if ty_is_vector(vals[cond].ty) { poison = sde_set_op(i, 0, demanded, poison, depth); }
        var dl = demanded;
        var dr = demanded;
        if vals[cond].kind == VK_CVECTOR {
            for k in vw {
                let ce = agg_elem(cond, k);
                if is_null_value(ce) { dl = ap_clear_bit(dl, k); }
                else if is_one_value(ce) { dr = ap_clear_bit(dr, k); }
            }
        }
        poison2 = sde_set_op(i, 1, dl, poison2, depth);
        poison3 = sde_set_op(i, 2, dr, poison3, depth);
        poison = ap_and(poison2, poison3);
    } else if o == OP_BITCAST {
        let st = vals[op(i, 0)].ty;
        if ty_is_vector(st) {
            let ivw = ty_count(st);
            var ind = ap_zero(ivw);
            poison2 = ap_zero(ivw);
            var ratio: i64 = 0;
            var ok = true;
            if vw == ivw { ratio = 1; ind = demanded; }
            else if vw % ivw == 0 {
                ratio = vw / ivw;
                for k in vw { if ap_get_bit(demanded, k) { ind = ap_set_bit(ind, k / ratio); } }
            } else if ivw % vw == 0 {
                ratio = ivw / vw;
                for k in ivw { if ap_get_bit(demanded, k / ratio) { ind = ap_set_bit(ind, k); } }
            } else { ok = false; }
            if ok {
                poison2 = sde_set_op(i, 0, ind, poison2, depth);
                if vw == ivw { poison = poison2; }
                else if vw % ivw == 0 {
                    for k in vw { if ap_get_bit(poison2, k / ratio) { poison = ap_set_bit(poison, k); } }
                } else {
                    for k in vw {
                        let sub = ap_zext_or_trunc(ap_lshr(poison2, k * ratio), ratio);
                        if ap_popcount(sub) == ratio { poison = ap_set_bit(poison, k); }
                    }
                }
            }
        }
    } else if o == OP_FPTRUNC || o == OP_FPEXT {
        poison = sde_set_op(i, 0, demanded, poison, depth);
    } else if o == OP_CALL {
        let id = inst_iid(i);
        if id == IID_masked_gather || id == IID_masked_load {
            var dptrs = ap_ones(vw);
            var dpass = demanded;
            let cm = op(i, 1);
            if is_constant(cm) {
                for k in vw {
                    let ce = agg_elem(cm, k);
                    if ce >= 0 {
                        if is_null_value(ce) { dptrs = ap_clear_bit(dptrs, k); }
                        else if sde_is_all_ones_value(ce) { dpass = ap_clear_bit(dpass, k); }
                    }
                }
            }
            if id == IID_masked_gather { poison2 = sde_set_op(i, 0, dptrs, poison2, depth); }
            poison3 = sde_set_op(i, 2, dpass, poison3, depth);
            poison = ap_and(poison2, poison3);
        } else if id != 0 && starts_with(intr_name(id as i64), "llvm.x86.") {
            ic_not_ported("simplifyDemandedVectorEltsIntrinsic (X86)");
        }
    }
    if is_binop_inst(i) && !sl_is_int_div_rem(o) && !is_shift_op(o) {
        let x = op(i, 0);
        let y = op(i, 1);
        if ap_eq_u64(demanded, 1) && !has_one_use(x) && !has_one_use(y) && has_one_use(i) {
            var sb = sde_find_shuf_bo(i, true);
            if sb < 0 { sb = sde_find_shuf_bo(i, false); }
            if sb >= 0 {
                sl_and_ir_flags(sb, i);
                icw_add(sb);
                return sb, poison;
            }
        }
        poison = sde_set_op(i, 0, demanded, poison, depth);
        poison2 = sde_set_op(i, 1, demanded, poison2, depth);
        poison = ap_and(poison, poison2);
    }
    if ap_is_all_ones(poison) { return c_poison(vals[i].ty), poison; }
    return if sde_changed { i } else { -1 }, poison;
}
// Constant::isAllOnesValue
fn sde_is_all_ones_value(c: i32) -> bool {
    if vals[c].kind == VK_CINT { return ap_is_all_ones(ci_ap(if ty_is_vector(vals[c].ty) { splat_value(c, false) } else { c })); }
    if vals[c].kind == VK_CFP { return false; }
    return false;
}
// gep_type_iterator step: the indexed type after one index
fn sde_gep_step(t: i32) -> i32 {
    let k = ty_kind(t);
    if k == TK_ARRAY || ty_is_vector(t) { return ty_elem(t); }
    return t;
}
// the findShufBO lambda
fn sde_find_shuf_bo(bo: i32, shuf_as_op0: bool) -> i32 {
    let x = op(bo, 0);
    let y = op(bo, 1);
    let other = if shuf_as_op0 { y } else { x };
    if is_constant_data(other) { return -1; }
    let o = iop(bo);
    let shufop = if shuf_as_op0 { x } else { y };
    var u = vals[other].first_use;
    while u >= 0 {
        let us = uses[u].user;
        u = uses[u].next;
        if !is_inst_op(us, o) { continue; }
        var sh: i32 = -1;
        fn is_shuf_of(s: i32, src: i32) -> bool { is_inst_op(s, OP_SHUFFLEVECTOR) && op(s, 0) == src }
        if is_commutative(o) {
            if is_shuf_of(op(us, 0), shufop) && op(us, 1) == other { sh = op(us, 0); }
            else if is_shuf_of(op(us, 1), shufop) && op(us, 0) == other { sh = op(us, 1); }
        } else if shuf_as_op0 {
            if is_shuf_of(op(us, 0), shufop) && op(us, 1) == other { sh = op(us, 0); }
        } else {
            if op(us, 0) == other && is_shuf_of(op(us, 1), shufop) { sh = op(us, 1); }
        }
        if sh < 0 { continue; }
        var zero_mask = true;
        for k in sde_mask_len(sh) { let m = sde_mask_at(sh, k); if m != 0 && m != -1 { zero_mask = false; } }
        if zero_mask && sde_mask_len(sh) > 0 && sde_mask_at(sh, 0) != -1 {
            if dt_value_dominates_inst(us, bo) { return us; }
        }
    }
    return -1;
}

// InstCombinerImpl::SimplifyDemandedVectorElts(V, DemandedElts, PoisonElts, Depth, AllowMultipleUsers):
// (replacement, the visited instruction itself when modified in place, or -1; PoisonElts)
fn ic_simplify_demanded_vector_elts(v: i32, demanded: AP, depth: i64, allow_multi: bool) -> i32, AP {
    let saved = sde_changed;
    let r, pe = sde_rec(v, demanded, ap_zero(demanded.w as i64), depth, allow_multi);
    sde_changed = saved;
    return r, pe;
}
