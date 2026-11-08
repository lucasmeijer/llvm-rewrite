// SimplifyDemandedBits: port of the integer part of llvm/lib/Transforms/InstCombine/InstCombineSimplifyDemanded.cpp
// (ShrinkDemandedConstant, SimplifyDemandedInstructionBits, SimplifyDemandedBits, SimplifyDemandedUseBits,
// SimplifyMultipleUseDemandedBits, simplifyShrShlDemandedBits, simplifyShiftSelectingPackedElement).
// SimplifyDemandedVectorElts and SimplifyDemandedFPClass are not ported (fail loudly where called).
//
// The KnownBits out-parameter is a second return value. The SimplifyQuery's context instruction is the
// instruction the query started from (sd_cxt), as in LLVM, where Q is passed down unchanged.
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
import knownbits;
import apint;
import overflow;
import datalayout;
import ic;
import ic_builder;
import ic_common;
import ic_andorxor;

var sd_cxt: i32 = -1;

fn sd_kb(v: i32, depth: i64) -> KB { kb_cxt = sd_cxt; return kb_compute_all(v, depth); }
fn sd_signbits(v: i32, depth: i64) -> i64 { kb_cxt = sd_cxt; return num_sign_bits(v, depth); }

// Constant::getIntegerValue(Ty, V)
fn c_int_value(ty: i32, a: AP) -> i32 {
    let st = ty_scalar(ty);
    if ty_kind(st) != TK_PTR { return c_int_ap(ty, a); }
    // a pointer: inttoptr of the integer constant, splatted for vectors
    let c = ce_cast(OP_INTTOPTR, c_int_ap(ty_int(a.w as i64), a), st);
    if ty_is_vector(ty) { return c_splat(ty, c); }
    return c;
}

// ShrinkDemandedConstant(I, OpNo, Demanded)
fn shrink_demanded_constant(i: i32, k: i64, demanded: AP) -> bool {
    let o = op(i, k);
    if !has_apint(o) { return false; }
    let c = ap_c(o);
    if ap_is_subset_of(c, demanded) { return false; }
    set_op(i, k, c_int_ap(vals[o].ty, ap_and(c, demanded)));
    return true;
}

// SimplifyDemandedInstructionBits(Inst)
fn simplify_demanded_instruction_bits(i: i32) -> bool {
    let r, k = simplify_demanded_instruction_bits_k(i);
    return r;
}
fn simplify_demanded_instruction_bits_k(i: i32) -> bool, KB {
    let w = sd_bit_width(vals[i].ty);
    let saved = sd_cxt;
    sd_cxt = i;
    let v, known = sd_use_bits(i, ap_ones(w), 0);
    sd_cxt = saved;
    if v < 0 { return false, known; }
    if v == i { return true, known; }
    ic_replace_inst_uses_with(i, v);
    return true, known;
}
// getBitWidth(Ty, DL)
fn sd_bit_width(t: i32) -> i64 {
    let s = ty_scalar(t);
    if ty_is_int(s) { return ty_bits(s); }
    // DL.getPointerTypeSizeInBits(Ty)
    if ty_kind(s) == TK_PTR { return dl_ptr(ptr_as(s)).bits; }
    ic_not_ported("SimplifyDemandedBits on a non-integer, non-pointer value");
    return 0;
}

// SimplifyDemandedBits(I, OpNo, DemandedMask, Known, Q, Depth)
recursive fn sd_bits(i: i32, k: i64, demanded: AP, depth: i64) -> bool, KB {
    let w = demanded.w as i64;
    let u = vals[i].ops + (k as i32);
    let v = uses[u].val;
    if is_constant(v) { return false, sd_kb(v, depth); }
    if ap_is_zero(demanded) {
        ic_replace_use(u, c_undef(vals[v].ty));
        return true, kb_unknown(w);
    }
    if !is_inst(v) { return false, sd_kb(v, depth); }
    if depth == 6 { return false, kb_unknown(w); }
    var nv: i32 = -1;
    var known = kb_unknown(w);
    if has_one_use(v) {
        let a, b = sd_use_bits(v, demanded, depth);
        nv = a; known = b;
    } else {
        let a, b = sd_multiple_use_bits(v, demanded, depth);
        nv = a; known = b;
    }
    if nv < 0 { return false, known; }
    if is_inst(uses[u].val) && dbgrecs.len > 0 && dbg_records_use_value(uses[u].val) { ic_not_ported("salvageDebugInfo in SimplifyDemandedBits"); }
    ic_replace_use(u, nv);
    return true, known;
}

// disableWrapFlagsBasedOnUnusedHighBits
fn sd_disable_wrap(i: i32, nlz: i64) -> i32 {
    if nlz > 0 { set_nsw(i, false); set_nuw(i, false); }
    return i;
}

// "Do not simplify if shl/lshr is part of funnel-shift pattern": the single user is an `or` that
// convertOrOfShiftsToFunnelShift turns into a rotate (both funnel-shift arguments equal)
fn sd_check_funnel_user(i: i32) -> bool {
    if !has_one_use(i) { return false; }
    let u = uses[vals[i].first_use].user;
    if !is_inst_op(u, OP_OR) { return false; }
    let ok, iid, a0, a1, a2 = convert_or_of_shifts_to_funnel_shift(u);
    return ok && (iid == IID_fshl || iid == IID_fshr) && a0 == a1;
}

// SimplifyDemandedUseBits(I, DemandedMask, Known, Q, Depth)
recursive fn sd_use_bits(i: i32, demanded: AP, depth: i64) -> i32, KB {
    let w = demanded.w as i64;
    let vty = vals[i].ty;
    var lk = kb_unknown(w);
    var rk = kb_unknown(w);
    var known = kb_unknown(w);
    let o = iop(i);
    var done = false;
    if o == OP_AND {
        let c1, k1 = sd_bits(i, 1, demanded, depth + 1);
        rk = k1;
        if c1 { return i, known; }
        let c0, k0 = sd_bits(i, 0, ap_and(demanded, ap_not(rk.z)), depth + 1);
        lk = k0;
        if c0 { return i, known; }
        kb_cxt = sd_cxt;
        known = kb_and_xor_or(i, all_elts(i), lk, rk, depth);
        if ap_is_subset_of(demanded, ap_or(known.z, known.o)) { return c_int_value(vty, known.o), known; }
        if ap_is_subset_of(demanded, ap_or(lk.z, rk.o)) { return op(i, 0), known; }
        if ap_is_subset_of(demanded, ap_or(rk.z, lk.o)) { return op(i, 1), known; }
        if shrink_demanded_constant(i, 1, ap_and(demanded, ap_not(lk.z))) { return i, known; }
        done = true;
    } else if o == OP_OR {
        let c1, k1 = sd_bits(i, 1, demanded, depth + 1);
        rk = k1;
        var ch = c1;
        if !ch {
            let c0, k0 = sd_bits(i, 0, ap_and(demanded, ap_not(rk.o)), depth + 1);
            lk = k0;
            ch = c0;
        }
        if ch { drop_poison_generating_flags(i); return i, known; }
        kb_cxt = sd_cxt;
        known = kb_and_xor_or(i, all_elts(i), lk, rk, depth);
        if ap_is_subset_of(demanded, ap_or(known.z, known.o)) { return c_int_value(vty, known.o), known; }
        if ap_is_subset_of(demanded, ap_or(lk.o, rk.z)) { return op(i, 0), known; }
        if ap_is_subset_of(demanded, ap_or(rk.o, lk.z)) { return op(i, 1), known; }
        if shrink_demanded_constant(i, 1, demanded) { return i, known; }
        if !op_disjoint(i) {
            if sd_have_no_common_bits(op(i, 0), op(i, 1), lk, rk) {
                set_disjoint(i, true);
                return i, known;
            }
        }
        done = true;
    } else if o == OP_XOR {
        let c1, k1 = sd_bits(i, 1, demanded, depth + 1);
        rk = k1;
        if c1 { return i, known; }
        let c0, k0 = sd_bits(i, 0, demanded, depth + 1);
        lk = k0;
        if c0 { return i, known; }
        if ap_is_one(demanded) && inst_iid(op(i, 0)) == IID_ctpop && inst_iid(op(i, 1)) == IID_ctpop {
            let sp = icb_pos; let sb = icb_bb; let sd = icb_dl;
            icb_set_insert_point(i);
            let x = icb_xor(op(op(i, 0), 0), op(op(i, 1), 0), "");
            let r = icb_unary_intrinsic(IID_ctpop, x, "");
            icb_pos = sp; icb_bb = sb; icb_dl = sd;
            return r, known;
        }
        kb_cxt = sd_cxt;
        known = kb_and_xor_or(i, all_elts(i), lk, rk, depth);
        if ap_is_subset_of(demanded, ap_or(known.z, known.o)) { return c_int_value(vty, known.o), known; }
        if ap_is_subset_of(demanded, rk.z) { return op(i, 0), known; }
        if ap_is_subset_of(demanded, lk.z) { return op(i, 1), known; }
        if ap_is_subset_of(demanded, ap_or(rk.z, lk.z)) {
            let orv = ic_new_binop(OP_OR, op(i, 0), op(i, 1));
            if ap_is_all_ones(demanded) { set_disjoint(orv, true); }
            ic_take_name(orv, i);
            return ic_insert_new_with(orv, i), known;
        }
        if ap_is_subset_of(demanded, ap_or(rk.z, rk.o)) && ap_is_subset_of(rk.o, lk.o) {
            let andc = c_int_value(vty, ap_and(ap_not(rk.o), demanded));
            let an = ic_new_binop(OP_AND, op(i, 0), andc);
            return ic_insert_new_with(an, i), known;
        }
        if has_apint(op(i, 1)) && !ap_is_all_ones(ap_c(op(i, 1))) {
            let c = ap_c(op(i, 1));
            if ap_is_all_ones(ap_or(c, ap_not(demanded))) {
                set_op(i, 1, c_all_ones(vty));
                return i, known;
            }
            if shrink_demanded_constant(i, 1, demanded) { return i, known; }
        }
        let lhs = op(i, 0);
        if is_inst(lhs) && iop(lhs) == OP_AND && has_one_use(lhs) && m_constant_int(op(i, 1)) >= 0 && m_constant_int(op(lhs, 1)) >= 0 &&
           !ap_is_zero(ap_and(ap_and(lk.o, rk.o), demanded)) {
            let nm = ap_not(ap_and(ap_and(lk.o, rk.o), demanded));
            let andc = c_int_ap(vty, ap_and(nm, ci_ap(op(lhs, 1))));
            let na = ic_new_binop(OP_AND, op(i, 0), andc);
            ic_insert_new_with(na, i);
            let xorc = c_int_ap(vty, ap_and(nm, ci_ap(op(i, 1))));
            let nx = ic_new_binop(OP_XOR, na, xorc);
            return ic_insert_new_with(nx, i), known;
        }
        done = true;
    } else if o == OP_SELECT {
        let c2, k2 = sd_bits(i, 2, demanded, depth + 1);
        rk = k2;
        if c2 { return i, known; }
        let c1, k1 = sd_bits(i, 1, demanded, depth + 1);
        lk = k1;
        if c1 { return i, known; }
        if sd_canonicalize_select_constant(i, 1, demanded) || sd_canonicalize_select_constant(i, 2, demanded) { return i, known; }
        kb_cxt = sd_cxt;
        lk = kb_adjust_for_select_arm(lk, op(i, 0), op(i, 1), false, depth);
        kb_cxt = sd_cxt;
        rk = kb_adjust_for_select_arm(rk, op(i, 0), op(i, 2), true, depth);
        known = kb_intersect(lk, rk);
        done = true;
    } else if o == OP_TRUNC || o == OP_ZEXT {
        if o == OP_TRUNC {
            let s = op(i, 0);
            if one_use(s) && bo(s, OP_LSHR) && has_apint(op(s, 1)) {
                let c = ap_c(op(s, 1));
                if ap_ult_u64(c, ty_scalar_bits(vty) as u64) && ap_ule_u64(c, ap_countl_zero(demanded) as u64) {
                    let sp = icb_pos; let sb = icb_bb; let sd = icb_dl;
                    icb_set_insert_point(i);
                    let tr = icb_trunc(op(s, 0), vty, "");
                    let r = icb_lshr(tr, c_int_ty(vty, ap_zext64(c)), "", false);
                    icb_pos = sp; icb_bb = sb; icb_dl = sd;
                    return r, known;
                }
            }
        }
        let sw = ty_scalar_bits(vals[op(i, 0)].ty);
        let idm = ap_zext_or_trunc(demanded, sw);
        let c0, ik0 = sd_bits(i, 0, idm, depth + 1);
        if c0 { drop_poison_generating_flags(i); return i, known; }
        var ik = ik0;
        if o == OP_ZEXT && (insts[inst_of(i)].flags & FL_NNEG) != 0 && !kb_is_neg(ik) { ik = kb_make_nonneg(ik); }
        known = kb_zext_or_trunc(ik, w);
        done = true;
    } else if o == OP_SEXT {
        let sw = ty_scalar_bits(vals[op(i, 0)].ty);
        var idb = ap_trunc(demanded, sw);
        if ap_active_bits(demanded) > sw { idb = ap_set_bit(idb, sw - 1); }
        let c0, ik = sd_bits(i, 0, idb, depth + 1);
        if c0 { return i, known; }
        if kb_is_nonneg(ik) || ap_active_bits(demanded) <= sw {
            let nc = ic_new_cast(OP_ZEXT, op(i, 0), vty);
            ic_take_name(nc, i);
            return ic_insert_new_with(nc, i), known;
        }
        known = kb_sext(ik, w);
        done = true;
    } else if o == OP_ADD {
        if !ap_get_bit(demanded, 0) {
            for k in 2 {
                let z = op(i, k);
                let s = op(i, 1 - k);
                let x = m_zext(z);
                let y = m_sext(s);
                if one_use(z) && x >= 0 && one_use(s) && y >= 0 && is_int_ty1(vals[x].ty) && vals[x].ty == vals[y].ty {
                    let sp = icb_pos; let sb = icb_bb; let sd = icb_dl;
                    icb_set_insert_point(i);
                    let an = icb_and(icb_not(x, ""), y, "");
                    let r = icb_sext(an, vty, "");
                    icb_pos = sp; icb_bb = sb; icb_dl = sd;
                    return r, known;
                }
            }
            let x = m_sext(op(i, 0));
            let y = m_sext(op(i, 1));
            if x >= 0 && y >= 0 && is_int_ty1(vals[x].ty) && vals[x].ty == vals[y].ty && (one_use(op(i, 0)) || one_use(op(i, 1))) {
                let sp = icb_pos; let sb = icb_bb; let sd = icb_dl;
                icb_set_insert_point(i);
                let orv = icb_or(x, y, "");
                let r = icb_sext(orv, vty, "");
                icb_pos = sp; icb_bb = sb; icb_dl = sd;
                return r, known;
            }
        }
        let nlz = ap_countl_zero(demanded);
        let dfo = ap_low_bits(w, w - nlz);
        if shrink_demanded_constant(i, 1, dfo) { return sd_disable_wrap(i, nlz), known; }
        let c1, k1 = sd_bits(i, 1, dfo, depth + 1);
        rk = k1;
        if c1 { return sd_disable_wrap(i, nlz), known; }
        let ntz = ap_countr_one(ap_and(ap_not(demanded), rk.z));
        let dfl = ap_clear_low_bits(dfo, ntz);
        if shrink_demanded_constant(i, 0, dfl) { return sd_disable_wrap(i, nlz), known; }
        let c0, k0 = sd_bits(i, 0, dfl, depth + 1);
        lk = k0;
        if c0 { return sd_disable_wrap(i, nlz), known; }
        let ntzl = ap_countr_one(ap_and(ap_not(demanded), lk.z));
        let dfr = ap_clear_low_bits(dfo, ntzl);
        if shrink_demanded_constant(i, 1, dfr) { return sd_disable_wrap(i, nlz), known; }
        if ap_is_subset_of(dfo, rk.z) { return op(i, 0), known; }
        if ap_is_subset_of(dfo, lk.z) { return op(i, 1), known; }
        if has_apint(op(i, 1)) {
            let c = ap_c(op(i, 1));
            let ab = ap_active_bits(demanded);
            if ab >= 1 && ap_popcount(c) == 1 && ap_get_bit(c, ab - 1) {
                let sp = icb_pos; let sb = icb_bb; let sd = icb_dl;
                icb_set_insert_point(i);
                let r = icb_xor(op(i, 0), c_int_ap(vty, c), "");
                icb_pos = sp; icb_bb = sb; icb_dl = sd;
                return r, known;
            }
        }
        known = kb_add_sub(true, op_nsw(i), op_nuw(i), lk, rk);
        done = true;
    } else if o == OP_SUB {
        let nlz = ap_countl_zero(demanded);
        let dfo = ap_low_bits(w, w - nlz);
        if shrink_demanded_constant(i, 1, dfo) { return sd_disable_wrap(i, nlz), known; }
        let c1, k1 = sd_bits(i, 1, dfo, depth + 1);
        rk = k1;
        if c1 { return sd_disable_wrap(i, nlz), known; }
        let ntz = ap_countr_one(ap_and(ap_not(demanded), rk.z));
        let dfl = ap_clear_low_bits(dfo, ntz);
        if shrink_demanded_constant(i, 0, dfl) { return sd_disable_wrap(i, nlz), known; }
        let c0, k0 = sd_bits(i, 0, dfl, depth + 1);
        lk = k0;
        if c0 { return sd_disable_wrap(i, nlz), known; }
        if ap_is_subset_of(dfo, rk.z) { return op(i, 0), known; }
        if ap_is_one(dfo) && ap_is_subset_of(dfo, lk.z) { return op(i, 1), known; }
        if m_low_bit_mask(op(i, 0)) && has_apint(op(i, 0)) && ap_is_subset_of(dfo, ap_c(op(i, 0))) {
            let sp = icb_pos; let sb = icb_bb; let sd = icb_dl;
            icb_set_insert_point(i);
            let r = icb_not(op(i, 1), "");
            icb_pos = sp; icb_bb = sb; icb_dl = sd;
            return r, known;
        }
        known = kb_add_sub(false, op_nsw(i), op_nuw(i), lk, rk);
        done = true;
    } else if o == OP_MUL {
        // simplifyOperandsBasedOnUnusedHighBits
        let nlz = ap_countl_zero(demanded);
        let dfo = ap_low_bits(w, w - nlz);
        var ch = shrink_demanded_constant(i, 0, dfo);
        if !ch { let c0, k0 = sd_bits(i, 0, dfo, depth + 1); lk = k0; ch = c0; }
        if !ch { ch = shrink_demanded_constant(i, 1, dfo); }
        if !ch { let c1, k1 = sd_bits(i, 1, dfo, depth + 1); rk = k1; ch = c1; }
        if ch { sd_disable_wrap(i, nlz); return i, known; }
        if ap_is_pow2(demanded) {
            let ctz = ap_countr_zero(demanded);
            if has_apint(op(i, 1)) && ap_countr_zero(ap_c(op(i, 1))) == ctz {
                let sh = ic_new_binop(OP_SHL, op(i, 0), c_int_ty(vty, ctz as u64));
                return ic_insert_new_with(sh, i), known;
            }
        }
        if op(i, 0) == op(i, 1) && ap_ult_u64(demanded, 4) {
            let a1 = ic_new_binop(OP_AND, op(i, 0), c_int_ty(vty, 1));
            return ic_insert_new_with(a1, i), known;
        }
        known = sd_kb(i, depth);
        done = true;
    } else if o == OP_SHL {
        if has_apint(op(i, 1)) {
            let sa = ap_c(op(i, 1));
            let s0 = op(i, 0);
            if (bo(s0, OP_LSHR) || bo(s0, OP_ASHR)) && has_apint(op(s0, 1)) {
                let r, kk = simplify_shr_shl_demanded_bits(s0, ap_c(op(s0, 1)), i, sa, demanded, known);
                known = kk;
                if r >= 0 { return r, known; }
            }
            if sd_check_funnel_user(i) {
                known = sd_kb(i, depth);
                if ap_is_subset_of(demanded, ap_or(known.z, known.o)) { return c_int_value(vty, known.o), known; }
                return -1, known;
            }
            let sha = ap_limited(sa, (w - 1) as u64) as i64;
            if ap_countr_zero(demanded) >= sha {
                if op_nsw(i) {
                    let nhd = w - ap_countr_zero(demanded);
                    let sb = sd_signbits(op(i, 0), depth + 1);
                    if sb > sha && sb - sha >= nhd { return op(i, 0), known; }
                }
                if bo(s0, OP_LSHR) && is_imm_c(op(s0, 0)) {
                    let c = op(s0, 0);
                    let lsa = c_int_ty(vty, sha as u64);
                    let nc = cf_fold_binop_operands(OP_SHL, c, lsa);
                    if cf_fold_binop_operands(OP_LSHR, nc, lsa) == c {
                        let ls = ic_new_binop(OP_LSHR, nc, op(s0, 1));
                        return ic_insert_new_with(ls, i), known;
                    }
                }
            }
            var dmi = ap_lshr(demanded, sha);
            if op_nsw(i) { dmi = ap_or(dmi, ap_high_bits(w, sha + 1)); }
            else if op_nuw(i) { dmi = ap_or(dmi, highb(w, sha)); }
            let c0, k0 = sd_bits(i, 0, dmi, depth + 1);
            known = k0;
            if c0 { return i, known; }
            known = kb_shl(known, kb_const_ap(ap_u64(sha as u64, w)), op_nuw(i), op_nsw(i), false);
        } else {
            let ctlz = ap_countl_zero(demanded);
            if ctlz != 0 {
                let dfo = ap_low_bits(w, w - ctlz);
                let c0, k0 = sd_bits(i, 0, dfo, depth + 1);
                if c0 { drop_poison_generating_flags(i); return i, k0; }
            }
            known = sd_kb(i, depth);
        }
        done = true;
    } else if o == OP_LSHR {
        if has_apint(op(i, 1)) {
            let sha = ap_limited(ap_c(op(i, 1)), (w - 1) as u64) as i64;
            if sd_check_funnel_user(i) {
                known = sd_kb(i, depth);
                if ap_is_subset_of(demanded, ap_or(known.z, known.o)) { return c_int_value(vty, known.o), known; }
                return -1, known;
            }
            if ap_countl_zero(demanded) >= sha {
                let nhd = w - ap_countr_zero(demanded);
                let sb = sd_signbits(op(i, 0), depth + 1);
                if sb >= nhd { return op(i, 0), known; }
                let s0 = op(i, 0);
                if bo(s0, OP_SHL) && is_imm_c(op(s0, 0)) {
                    let c = op(s0, 0);
                    let rsa = c_int_ty(vty, sha as u64);
                    let nc = cf_fold_binop_operands(OP_LSHR, c, rsa);
                    if cf_fold_binop_operands(OP_SHL, nc, rsa) == c {
                        let sh = ic_new_binop(OP_SHL, nc, op(s0, 1));
                        return ic_insert_new_with(sh, i), known;
                    }
                }
                if one_use(s0) && bo(s0, OP_MUL) && has_apint(op(s0, 1)) && ap_countr_zero(ap_c(op(s0, 1))) >= sha {
                    let x = op(s0, 0);
                    let ml = ic_new_binop(OP_MUL, x, c_int_ap(vals[x].ty, ap_lshr(ap_c(op(s0, 1)), sha)));
                    return ic_insert_new_with(ml, i), known;
                }
            }
            let dmi = ap_shl(demanded, sha);
            let c0, k0 = sd_bits(i, 0, dmi, depth + 1);
            if c0 { drop_poison_generating_flags(i); return i, k0; }
            known = KB { z: ap_lshr(k0.z, sha), o: ap_lshr(k0.o, sha) };
            if sha != 0 { known = kb_or_z(known, ap_high_bits(w, sha)); }
            done = true;
        } else {
            let r = simplify_shift_selecting_packed_element(i, demanded, depth);
            if r >= 0 { return r, known; }
            known = sd_kb(i, depth);
            done = true;
        }
    } else if o == OP_ASHR {
        let sb = sd_signbits(op(i, 0), depth + 1);
        let nhd = w - ap_countr_zero(demanded);
        if sb >= nhd { return op(i, 0), known; }
        if ap_is_one(demanded) {
            let nv = ic_new_binop(OP_LSHR, op(i, 0), op(i, 1));
            set_name_from(nv, i);
            return ic_insert_new_with(nv, i), known;
        }
        if has_apint(op(i, 1)) {
            let sha = ap_limited(ap_c(op(i, 1)), (w - 1) as u64) as i64;
            var dmi = ap_shl(demanded, sha);
            let shifted_in = ap_countl_zero(demanded) < sha;
            if shifted_in { dmi = ap_set_bit(dmi, w - 1); }
            let c0, k0 = sd_bits(i, 0, dmi, depth + 1);
            if c0 { drop_poison_generating_flags(i); return i, k0; }
            known = k0;
            if ap_get_bit(known.z, w - 1) || !shifted_in {
                let ls = ic_new_binop(OP_LSHR, op(i, 0), op(i, 1));
                set_exact(ls, op_exact(i));
                ic_take_name(ls, i);
                return ic_insert_new_with(ls, i), known;
            }
            known = kb_shr(known, kb_const_ap(ap_u64(sha as u64, w)), sha != 0, op_exact(i), true);
        } else {
            known = sd_kb(i, depth);
        }
        done = true;
    } else if o == OP_UDIV {
        if has_apint(op(i, 1)) {
            let sa = ap_c(op(i, 1));
            let rtz = ap_countr_zero(sa);
            let dmi = ap_high_bits(w, w - rtz);
            let c0, k0 = sd_bits(i, 0, dmi, depth + 1);
            if c0 { drop_poison_generating_flags(i); return i, k0; }
            known = kb_udiv(k0, kb_const_ap(sa), op_exact(i));
        } else {
            known = sd_kb(i, depth);
        }
        done = true;
    } else if o == OP_SREM {
        if has_apint(op(i, 1)) && ap_is_pow2(ap_c(op(i, 1))) {
            let rem = ap_c(op(i, 1));
            if ap_ult(demanded, rem) { return op(i, 0), known; }
            let lowbits = ap_dec(rem);
            let mask2 = ap_or(lowbits, ap_sign_mask(w));
            let c0, k0 = sd_bits(i, 0, mask2, depth + 1);
            if c0 { return i, k0; }
            known = kb_srem(k0, kb_const_ap(rem));
        } else {
            known = sd_kb(i, depth);
        }
        done = true;
    } else if o == OP_CALL {
        let id = inst_iid(i);
        var computed = false;
        if id == IID_abs {
            if ap_is_one(demanded) { return op(i, 0), known; }
        } else if id == IID_ctpop {
            let x = m_not(op(i, 0));
            if ap_is_one(demanded) && ty_scalar_bits(vty) % 2 == 0 && x >= 0 {
                let c = ic_new_intrinsic(IID_ctpop, [vty], [x]);
                return ic_insert_new_with(c, i), known;
            }
        } else if id == IID_bswap {
            var nlz = ap_countl_zero(demanded);
            var ntz = ap_countr_zero(demanded);
            nlz = nlz - nlz % 8;
            ntz = ntz - ntz % 8;
            if w - nlz - ntz == 8 {
                var nv: i32 = -1;
                if nlz > ntz { nv = ic_new_binop(OP_LSHR, op(i, 0), c_int_ty(vty, (nlz - ntz) as u64)); }
                else { nv = ic_new_binop(OP_SHL, op(i, 0), c_int_ty(vty, (ntz - nlz) as u64)); }
                ic_take_name(nv, i);
                return ic_insert_new_with(nv, i), known;
            }
        } else if id == IID_ptrmask {
            let mw = ty_scalar_bits(vals[op(i, 1)].ty);
            let c0, lk = sd_bits(i, 0, demanded, depth + 1);
            if c0 { return i, known; }
            let c1, rk0 = sd_bits(i, 1, ap_zext_or_trunc(ap_and(demanded, ap_not(lk.z)), mw), depth + 1);
            if c1 { return i, known; }
            let rk = kb_anyext_or_trunc(rk0, w);
            known = kb_and(lk, rk);
            computed = true;
            if ap_is_subset_of(demanded, known.z) && !m_zero(op(i, 1)) {
                ic_replace_operand(i, 1, c_null(vals[op(i, 1)].ty));
                return i, known;
            }
            if ap_is_subset_of(demanded, ap_or(rk.o, lk.z)) { return op(i, 0), known; }
            if shrink_demanded_constant(i, 1, ap_zext_or_trunc(ap_and(demanded, ap_not(lk.z)), mw)) { return i, known; }
            // (ptrmask (getelementptr i8, ptr p, imm i), imm mask)
            let g = op(i, 0);
            let gm = op(i, 1);
            if sd_is_ptr_add(g) && m_constant_int(op(g, 1)) >= 0 && ty_bits(vals[op(g, 1)].ty) <= 64 &&
               m_constant_int(gm) >= 0 && ty_bits(vals[gm].ty) <= 64 {
                let inner = op(g, 0);
                let gidx = ap_zext64(ci_ap(op(g, 1)));
                let pmi = ap_zext64(ci_ap(gm));
                kb_cxt = i;
                let lk2 = kb_compute_all(inner, depth + 1);
                if !kb_is_zero_known(lk2) {
                    let tz = kb_min_tz(lk2);
                    let pab: u64 = if tz >= 64 { 0xFFFFFFFFFFFFFFFF } else { ((1 as u64) << tz as u64) - 1 };
                    let hb = gidx & ~pab;
                    let ml = gidx & pab & pmi;
                    let mg = hb | ml;
                    if mg != gidx {
                        icb_set_insert_point(i);
                        let ity = dl_index_type(vals[inner].ty);
                        var gnm: u8[>..] = [];
                        gnm.append(val_name(g));
                        let ng = icb_gep(gep_src_ty(g), inner, [c_int_ty(ity, mg)], gnm, if (op_flags(g) & GEP_INBOUNDS) != 0 { GEP_INBOUNDS | GEP_NUSW } else { 0 });
                        ic_replace_operand(i, 0, ng);
                        return i, known;
                    }
                }
            }
        } else if id == IID_fshl || id == IID_fshr {
            if has_apint(op(i, 2)) {
                var sh = ap_zext64(ap_urem(ap_c(op(i, 2)), ap_u64(w as u64, ap_c(op(i, 2)).w as i64))) as i64;
                if id == IID_fshr { sh = w - sh; }
                let dl = ap_lshr(demanded, sh);
                let dr = ap_shl(demanded, w - sh);
                var lk = kb_unknown(w);
                var rk = kb_unknown(w);
                if op(i, 0) != op(i, 1) {
                    let c0, k0 = sd_bits(i, 0, dl, depth + 1);
                    if c0 { drop_poison_generating_annotations(i); return i, known; }
                    let c1, k1 = sd_bits(i, 1, dr, depth + 1);
                    if c1 { drop_poison_generating_annotations(i); return i, known; }
                    lk = k0; rk = k1;
                } else {
                    kb_cxt = i;
                    lk = kb_compute_all(op(i, 0), depth + 1);
                    if ap_is_subset_of(dl, ap_or(lk.z, lk.o)) && !m_specific_int_apv(op(i, 0), lk.o) {
                        ic_replace_operand(i, 0, c_int_value(vty, lk.o));
                        return i, known;
                    }
                    kb_cxt = i;
                    rk = kb_compute_all(op(i, 1), depth + 1);
                    if ap_is_subset_of(dr, ap_or(rk.z, rk.o)) && !m_specific_int_apv(op(i, 1), rk.o) {
                        ic_replace_operand(i, 1, c_int_value(vty, rk.o));
                        return i, known;
                    }
                }
                lk = KB { z: ap_shl(lk.z, sh), o: ap_shl(lk.o, sh) };
                rk = KB { z: ap_lshr(rk.z, w - sh), o: ap_lshr(rk.o, w - sh) };
                known = kb_union(lk, rk);
                computed = true;
            }
        } else if id == IID_umax {
            let ctz = ap_countr_zero(demanded);
            if has_apint(op(i, 1)) && ctz >= ap_active_bits(ap_c(op(i, 1))) { return op(i, 0), known; }
        } else if id == IID_umin {
            let ctz = ap_countr_zero(demanded);
            if has_apint(op(i, 1)) {
                let c = ap_c(op(i, 1));
                if ctz >= (c.w as i64) - ap_countl_one(c) { return op(i, 0), known; }
            }
        } else if id != 0 && intr_is_target_specific(id) {
            ic_not_ported("targetSimplifyDemandedUseBitsIntrinsic");
        }
        if !computed { known = sd_kb(i, depth); }
        done = true;
    }
    if !done { known = sd_kb(i, depth); }
    if ty_kind(vty) == TK_PTR {
        // Known.Zero.setLowBits(Log2(I->getPointerAlignment(DL)))
        let al = pointer_alignment(i);
        var lg: i64 = 0;
        while ((1 as i64) << lg) < al { lg++; }
        if lg > 0 { known = KB { z: ap_or(known.z, ap_low_bits(w, lg)), o: known.o }; }
        return -1, known;
    }
    if ap_is_subset_of(demanded, ap_or(known.z, known.o)) {
        return c_int_value(vty, known.o), known;
    }
    return -1, known;
}
fn intr_is_target_specific(id: i32) -> bool {
    let nm = intr_name(id as i64);
    return starts_with(nm, "llvm.x86.") || starts_with(nm, "llvm.aarch64.") || starts_with(nm, "llvm.arm.") ||
           starts_with(nm, "llvm.amdgcn.") || starts_with(nm, "llvm.nvvm.") || starts_with(nm, "llvm.ppc.") ||
           starts_with(nm, "llvm.riscv.") || starts_with(nm, "llvm.wasm.") || starts_with(nm, "llvm.hexagon.") ||
           starts_with(nm, "llvm.s390.") || starts_with(nm, "llvm.mips.");
}

// haveNoCommonBitsSet with cached known bits
fn sd_have_no_common_bits(l: i32, r: i32, lk: KB, rk: KB) -> bool {
    let res = ncb_special_cases(l, r, sd_cxt);
    if res == NCB_KNOWN { return true; }
    let cres = ncb_special_cases(r, l, sd_cxt);
    if cres == NCB_KNOWN { return true; }
    return ap_is_all_ones(ap_or(lk.z, rk.z));
}

// CanonicalizeSelectConstant (the lambda in the Select case)
fn sd_canonicalize_select_constant(i: i32, k: i64, demanded: AP) -> bool {
    let s = op(i, k);
    if !has_apint(s) { return false; }
    let selc = ap_c(s);
    let c = op(i, 0);
    if !is_inst_op(c, OP_ICMP) || is_constant(op(c, 0)) || !has_apint(op(c, 1)) || ap_c(op(c, 1)).w != selc.w {
        return shrink_demanded_constant(i, k, demanded);
    }
    let cmpc = ap_c(op(c, 1));
    if ap_eq(cmpc, selc) { return false; }
    if ap_eq(ap_and(cmpc, demanded), ap_and(selc, demanded)) {
        set_op(i, k, c_int_ap(vals[i].ty, cmpc));
        return true;
    }
    return shrink_demanded_constant(i, k, demanded);
}

// SimplifyMultipleUseDemandedBits(I, DemandedMask, Known, Q, Depth)
recursive fn sd_multiple_use_bits(i: i32, demanded: AP, depth: i64) -> i32, KB {
    let w = demanded.w as i64;
    let ity = vals[i].ty;
    let o = iop(i);
    var known = kb_unknown(w);
    if o == OP_AND || o == OP_OR || o == OP_XOR {
        let rk = sd_kb(op(i, 1), depth + 1);
        let lk = sd_kb(op(i, 0), depth + 1);
        kb_cxt = sd_cxt;
        known = kb_and_xor_or(i, all_elts(i), lk, rk, depth);
        kb_cxt = sd_cxt;
        known = kb_from_context(i, known, depth);
        if ap_is_subset_of(demanded, ap_or(known.z, known.o)) { return c_int_value(ity, known.o), known; }
        if o == OP_AND {
            if ap_is_subset_of(demanded, ap_or(lk.z, rk.o)) { return op(i, 0), known; }
            if ap_is_subset_of(demanded, ap_or(rk.z, lk.o)) { return op(i, 1), known; }
        } else if o == OP_OR {
            if ap_is_subset_of(demanded, ap_or(lk.o, rk.z)) { return op(i, 0), known; }
            if ap_is_subset_of(demanded, ap_or(rk.o, lk.z)) { return op(i, 1), known; }
        } else {
            if ap_is_subset_of(demanded, rk.z) { return op(i, 0), known; }
            if ap_is_subset_of(demanded, lk.z) { return op(i, 1), known; }
        }
        return -1, known;
    }
    if o == OP_ADD {
        let nlz = ap_countl_zero(demanded);
        let dfo = ap_low_bits(w, w - nlz);
        let rk = sd_kb(op(i, 1), depth + 1);
        if ap_is_subset_of(dfo, rk.z) { return op(i, 0), known; }
        let lk = sd_kb(op(i, 0), depth + 1);
        if ap_is_subset_of(dfo, lk.z) { return op(i, 1), known; }
        known = kb_add_sub(true, op_nsw(i), op_nuw(i), lk, rk);
        kb_cxt = sd_cxt;
        known = kb_from_context(i, known, depth);
        return -1, known;
    }
    if o == OP_SUB {
        let nlz = ap_countl_zero(demanded);
        let dfo = ap_low_bits(w, w - nlz);
        let rk = sd_kb(op(i, 1), depth + 1);
        if ap_is_subset_of(dfo, rk.z) { return op(i, 0), known; }
        let lk = sd_kb(op(i, 0), depth + 1);
        known = kb_add_sub(false, op_nsw(i), op_nuw(i), lk, rk);
        kb_cxt = sd_cxt;
        known = kb_from_context(i, known, depth);
        return -1, known;
    }
    if o == OP_ASHR {
        known = sd_kb(i, depth);
        if ap_is_subset_of(demanded, ap_or(known.z, known.o)) { return c_int_value(ity, known.o), known; }
        let s = op(i, 0);
        if bo(s, OP_SHL) && has_apint(op(s, 1)) && has_apint(op(i, 1)) {
            let lc = m_apint(op(s, 1));
            let rc = m_apint(op(i, 1));
            if lc == rc && ap_ult_u64(ci_ap(lc), w as u64) && ap_is_subset_of(demanded, ap_low_bits(w, w - (ap_zext64(ci_ap(rc)) as i64))) {
                return op(s, 0), known;
            }
        }
        return -1, known;
    }
    known = sd_kb(i, depth);
    if ap_is_subset_of(demanded, ap_or(known.z, known.o)) { return c_int_value(ity, known.o), known; }
    return -1, known;
}

// simplifyShrShlDemandedBits(Shr, ShrOp1, Shl, ShlOp1, DemandedMask, Known)
fn simplify_shr_shl_demanded_bits(shr: i32, shrop1: AP, shl: i32, shlop1: AP, demanded: AP, known0: KB) -> i32, KB {
    var known = known0;
    if ap_is_zero(shlop1) || ap_is_zero(shrop1) { return -1, known; }
    let x = op(shr, 0);
    let ty = vals[x].ty;
    let w = ty_scalar_bits(ty);
    if ap_uge_u64(shlop1, w as u64) || ap_uge_u64(shrop1, w as u64) { return -1, known; }
    let shla = ap_zext64(shlop1) as i64;
    let shra = ap_zext64(shrop1) as i64;
    known = KB { z: ap_and(ap_or(known.z, ap_low_bits(w, shla - 1)), demanded), o: ap_zero(w) };
    let is_lshr = iop(shr) == OP_LSHR;
    let ones = ap_ones(w);
    let bm1 = if is_lshr { ap_shl(ap_lshr(ones, shra), shla) } else { ap_shl(ap_ashr(ones, shra), shla) };
    var bm2 = ones;
    if shra <= shla { bm2 = ap_shl(bm2, shla - shra); }
    else { bm2 = if is_lshr { ap_lshr(bm2, shra - shla) } else { ap_ashr(bm2, shra - shla) }; }
    if ap_eq(ap_and(bm1, demanded), ap_and(bm2, demanded)) {
        if shra == shla { return x, known; }
        if !has_one_use(shr) { return -1, known; }
        var nw: i32 = -1;
        if shra < shla {
            nw = ic_new_binop(OP_SHL, x, c_int_ty(ty, (shla - shra) as u64));
            set_nsw(nw, op_nsw(shl));
            set_nuw(nw, op_nuw(shl));
        } else {
            nw = ic_new_binop(if is_lshr { OP_LSHR } else { OP_ASHR }, x, c_int_ty(ty, (shra - shla) as u64));
            if op_exact(shr) { set_exact(nw, true); }
        }
        return ic_insert_new_with(nw, shl), known;
    }
    return -1, known;
}

// simplifyShiftSelectingPackedElement(I, DemandedMask, IC, Depth)
fn simplify_shift_selecting_packed_element(i: i32, demanded: AP, depth: i64) -> i32 {
    let s0 = op(i, 0);
    if !one_use(s0) || !m_disjoint_or(s0) { return -1; }
    var upper: i32 = -1;
    var lower: i32 = -1;
    var shl_amt: u64 = 0;
    for k in 2 {
        let s = op(s0, k);
        if upper < 0 && one_use(s) && bo(s, OP_SHL) && has_apint(op(s, 1)) && ap_fits_u64(ap_c(op(s, 1))) {
            // m_ConstantInt(uint64_t &) matches splats too
            upper = op(s, 0); lower = op(s0, 1 - k); shl_amt = ap_zext64(ap_c(op(s, 1)));
        }
    }
    if upper < 0 { return -1; }
    if shl_amt == 0 || (shl_amt & (shl_amt - 1)) != 0 { return -1; }
    let dbw = ap_active_bits(demanded) as u64;
    if dbw > shl_amt { return -1; }
    if (ty_sbits(upper) as u64) < shl_amt + dbw { return -1; }
    kb_cxt = i;
    let kl = kb_compute_all(lower, depth);
    if !ap_is_int_n(kb_max(kl), shl_amt as i64) { return -1; }
    let shramt = op(i, 1);
    kb_cxt = i;
    let ks = kb_compute_all(shramt, depth);
    if !ap_eq_u64(ap_not(ks.z), shl_amt) { return -1; }
    let sp = icb_pos; let sb = icb_bb; let sd = icb_dl;
    icb_set_insert_point(i);
    var nm: u8[>..] = []; nm.append(val_name(shramt)); nm.append(".z");
    let z = icb_icmp(32, shramt, c_null(vals[shramt].ty), nm);
    if ic_fn_has_entry_count(ic_fn) { ic_not_ported("CreateSelectWithUnknownProfile in a profiled function"); }
    let sel = icb_select(z, lower, upper, "", -1);
    icb_pos = sp; icb_bb = sb; icb_dl = sd;
    ic_take_name(sel, i);
    return sel;
}

// m_PtrAdd: a GEP (instruction or constant expression) with source element type i8 and one index
fn sd_is_ptr_add(g: i32) -> bool {
    if !(is_inst_op(g, OP_GEP) || (vals[g].kind == VK_CEXPR && csts[vals[g].sub].op as i64 == OP_GEP)) { return false; }
    if nops(g) != 2 { return false; }
    let st = gep_src_ty(g);
    return ty_is_int(st) && ty_bits(st) == 8;
}
