// VectorCombine, part 2: port of llvm/lib/Transforms/Vectorize/VectorCombine.cpp from foldPermuteOfBinops to the
// end (the shuffle folds, foldShuffleToIdentity, the reduction folds, foldSelectShuffle, shrinkType,
// foldInsExtVectorToShuffle, the interleave / bit-order / shrinking folds) and the driver: VectorCombine::run
// (FoldInst) and VectorCombinePass::run. Part 1 (vector_combine.goose) has the state, worklist and builder.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import gen_attrs;
import intrinsics;
import constfold;
import cfold;
import datalayout;
import apint;
import pm;
import vt;
import knownbits;
import instsimplify;
import local;
import loads;
import aa;
import domtree;
import domcond;
import analyses;
import flags;
import tti;
import tti_x86;
import tti_x86_vec;
import tti_vec;
import vecutils;
import vector_combine;

fn vc_is_intrinsic(v: i32) -> bool { is_inst_op(v, OP_CALL) && tti_is_intrinsic_inst(v) }
fn vc_has_bundles(v: i32) -> bool { cb_nbundles(v) > 0 }
// ShuffleVectorInst::isIdentityMask(Mask, NumSrcElts)
fn vc_is_identity_mask(mask: const i32[:], nsrc: i64) -> bool {
    if mask.len != nsrc { return false; }
    return vc_identity_impl(mask, nsrc);
}
fn vc_single_source_impl(mask: const i32[:], nop: i64) -> bool {
    var l = false;
    var r = false;
    for m in mask {
        if m == -1 { continue; }
        if (m as i64) < nop { l = true; } else { r = true; }
        if l && r { return false; }
    }
    return l || r;
}
fn vc_identity_impl(mask: const i32[:], nop: i64) -> bool {
    if !vc_single_source_impl(mask, nop) { return false; }
    for k in mask.len {
        let m = mask[k] as i64;
        if m == -1 { continue; }
        if m != k && m != nop + k { return false; }
    }
    return true;
}
// ShuffleVectorInst::commuteShuffleMask(Mask, InVecNumElts)
fn vc_commute_mask(mask: i32[>..<]&, n: i64) {
    for k in mask.len {
        let m = mask[k] as i64;
        if m < 0 { continue; }
        mask[k] = (if m < n { m + n } else { m - n }) as i32;
    }
}
fn vc_mask_contains(mask: const i32[:], x: i32) -> bool { for m in mask { if m == x { return true; } } return false; }
fn vc_masks_equal(a: const i32[:], b: const i32[:]) -> bool {
    if a.len != b.len { return false; }
    for k in a.len { if a[k] != b[k] { return false; } }
    return true;
}

// ---------------------------------------------------------------- foldPermuteOfBinops

fn vc_fold_permute_of_binops(i: i32) -> bool {
    let bo = op(i, 0);
    if !vc_is_binop(bo) || !m_undef(op(i, 1)) { return false; }
    var outer: i32[>..<] = [];
    vc_mask(i, outer);
    let o = iop(bo);
    if vc_is_int_div_rem(o) && vc_mask_contains(outer, -1) { return false; }
    let b0 = op(bo, 0);
    let b1 = op(bo, 1);
    let m0 = vc_is_shuffle(b0);
    let m1 = vc_is_shuffle(b1);
    if !m0 && !m1 { return false; }
    let o00 = if m0 { op(b0, 0) } else { b0 };
    let o01 = if m0 { op(b0, 1) } else { b0 };
    let o10 = if m1 { op(b1, 0) } else { b1 };
    let o11 = if m1 { op(b1, 1) } else { b1 };
    let dty = vals[i].ty as i32;
    let bty = vals[bo].ty as i32;
    let t0 = vals[o00].ty as i32;
    let t1 = vals[o10].ty as i32;
    if !vc_is_fixed_vec(dty) || !vc_is_fixed_vec(bty) || !vc_is_fixed_vec(t0) || !vc_is_fixed_vec(t1) { return false; }
    let nsrc = ty_count(bty);
    if vc_is_int_div_rem(o) || !is_poison(op(i, 1)) {
        for m in outer { if m as i64 >= nsrc { return false; } }
    }
    var nm0: i32[>..<] = [];
    var nm1: i32[>..<] = [];
    for m in outer {
        if m < 0 || m as i64 >= nsrc { nm0.push(-1); nm1.push(-1); }
        else {
            nm0.push(if m0 { vc_mask_at(b0, m as i64) } else { m });
            nm1.push(if m1 { vc_mask_at(b1, m as i64) } else { m });
        }
    }
    let nop = ty_count(t0);
    var id0 = dty == t0;
    if id0 { for m in nm0 { if m as i64 >= nop { id0 = false; } } }
    id0 = id0 && vc_is_identity_mask(nm0, nop);
    var id1 = dty == t1;
    if id1 { for m in nm1 { if m as i64 >= nop { id1 = false; } } }
    id1 = id1 && vc_is_identity_mask(nm1, nop);
    var nc: i64 = 0;
    let boc = tv_arith0(o, bty, vc_kind);
    var old = vc_add(boc, tv_shuffle(SK_PERMUTESINGLESRC, dty, bty, outer, vc_kind, 0, -1, bo, -1, 1, i));
    if !vc_has_one_use(bo) { nc = vc_add(nc, boc); }
    if m0 {
        var mk: i32[>..<] = [];
        vc_mask(b0, mk);
        let c = tv_shuffle(SK_PERMUTETWOSRC, bty, t0, mk, vc_kind, 0, -1, o00, o01, 2, b0);
        old = vc_add(old, c);
        if !vc_has_one_use(bo) || !vc_has_one_use(b0) { nc = vc_add(nc, c); }
    }
    if m1 {
        var mk: i32[>..<] = [];
        vc_mask(b1, mk);
        let c = tv_shuffle(SK_PERMUTETWOSRC, bty, t1, mk, vc_kind, 0, -1, o10, o11, 2, b1);
        old = vc_add(old, c);
        if !vc_has_one_use(bo) || !vc_has_one_use(b1) { nc = vc_add(nc, c); }
    }
    nc = vc_add(nc, tv_arith0(o, dty, vc_kind));
    if !id0 { nc = vc_add(nc, tv_shuffle(SK_PERMUTETWOSRC, dty, t0, nm0, vc_kind, 0, -1, o00, o01, 2, -1)); }
    if !id1 { nc = vc_add(nc, tv_shuffle(SK_PERMUTETWOSRC, dty, t1, nm1, vc_kind, 0, -1, o10, o11, 2, -1)); }
    if nc > old { return false; }
    let l = if id0 { o00 } else { vcb_shuffle(o00, o01, nm0, "") };
    let r = if id1 { o10 } else { vcb_shuffle(o10, o11, nm1, "") };
    let nb = vcb_binop(o, l, r, "", 0);
    if is_inst(nb) { vu_copy_ir_flags(nb, bo, true); }
    vcw_push_value(l);
    vcw_push_value(r);
    vc_replace(i, nb, true);
    return true;
}

// ---------------------------------------------------------------- foldShuffleOfBinops

fn vc_fold_shuffle_of_binops(i: i32) -> bool {
    let lhs = op(i, 0);
    let rhs = op(i, 1);
    if !is_inst(lhs) || !is_inst(rhs) { return false; }
    var old_mask: i32[>..<] = [];
    vc_mask(i, old_mask);
    if iop(lhs) != iop(rhs) { return false; }
    var x: i32 = -1;
    var y: i32 = -1;
    var z: i32 = -1;
    var w: i32 = -1;
    var comm = false;
    var pred: i64 = PRED_BAD_ICMP;
    if vc_is_binop(lhs) && vc_is_binop(rhs) {
        x = op(lhs, 0); y = op(lhs, 1); z = op(rhs, 0); w = op(rhs, 1);
        if vc_mask_contains(old_mask, -1) && vc_is_int_div_rem(iop(lhs)) { return false; }
        comm = vc_commutative_op(iop(lhs));
    } else if vc_is_cmp(lhs) && vc_is_cmp(rhs) && inst_pred(lhs) == inst_pred(rhs) {
        x = op(lhs, 0); y = op(lhs, 1); z = op(rhs, 0); w = op(rhs, 1);
        pred = inst_pred(lhs);
        comm = vc_cmp_is_commutative(lhs);
    } else {
        return false;
    }
    let dty = vals[i].ty as i32;
    let rty = vals[lhs].ty as i32;
    let bty = vals[x].ty as i32;
    if !vc_is_fixed_vec(dty) || !vc_is_fixed_vec(rty) || !vc_is_fixed_vec(bty) || vals[x].ty != vals[z].ty { return false; }
    let same = lhs == rhs;
    let nsrc = ty_count(bty);
    if comm && x != z && y != w && (x == w || y == z) { let t = x; x = y; y = t; }
    var nm0: i32[>..<] = [];
    for m in old_mask { nm0.push(m); }
    var sk0 = SK_PERMUTETWOSRC;
    let oi0 = tv_common_operand_info(x, z);
    if x == z {
        for k in nm0.len { if nm0[k] as i64 >= nsrc { nm0[k] = (nm0[k] as i64 - nsrc) as i32; } }
        sk0 = SK_PERMUTESINGLESRC;
        z = c_poison(bty);
    }
    var nm1: i32[>..<] = [];
    for m in old_mask { nm1.push(m); }
    var sk1 = SK_PERMUTETWOSRC;
    let oi1 = tv_common_operand_info(y, w);
    if y == w {
        for k in nm1.len { if nm1[k] as i64 >= nsrc { nm1[k] = (nm1[k] as i64 - nsrc) as i32; } }
        sk1 = SK_PERMUTESINGLESRC;
        w = c_poison(bty);
    }
    let lc = tv_inst_cost(lhs, vc_kind);
    let rc = tv_inst_cost(rhs, vc_kind);
    var old = lc;
    if !same { old = vc_add(old, rc); }
    old = vc_add(old, tv_shuffle(SK_PERMUTETWOSRC, dty, rty, old_mask, vc_kind, 0, -1, lhs, rhs, 2, i));
    // MergeInner(Op, Offset, Mask)
    fn merge_inner(opv: i32, offset: i64, mask: i32[>..<]&, nsrc: i64, oldc: i64&) -> bool, i32 {
        if !vc_is_shuffle(opv) || !vc_has_one_use(opv) || !m_undef(op(opv, 1)) { return false, opv; }
        let inner = op(opv, 0);
        if vals[inner].ty != vals[opv].ty { return false, opv; }
        for k in vc_mask_len(opv) { if vc_mask_at(opv, k) as i64 >= nsrc { return false, opv; } }
        for k in mask.len {
            let m = mask[k] as i64;
            if offset <= m && m < offset + nsrc {
                let mm = vc_mask_at(opv, m - offset) as i64;
                mask[k] = (if 0 <= mm { mm + offset } else { mm }) as i32;
            }
        }
        oldc = vc_add(oldc, tv_inst_cost(opv, vc_kind));
        return true, inner;
    }
    var reduced = false;
    let r1, nx = merge_inner(x, 0, nm0, nsrc, old);
    x = nx;
    reduced = reduced || r1;
    let r2, ny = merge_inner(y, 0, nm1, nsrc, old);
    y = ny;
    reduced = reduced || r2;
    let r3, nz = merge_inner(z, nsrc, nm0, nsrc, old);
    z = nz;
    reduced = reduced || r3;
    let r4, nw = merge_inner(w, nsrc, nm1, nsrc, old);
    w = nw;
    reduced = reduced || r4;
    let single = x == y && z == w && vc_masks_equal(nm0, nm1);
    if single && vc_has_one_user(lhs) && vc_has_one_user(rhs) { reduced = true; }
    if vc_shuffle_is_concat(i) && ty_scalar(vals[i].ty) == T_I1 && vc_is_binop(lhs) && vc_has_one_user(lhs) && vc_has_one_user(rhs) {
        reduced = true;
    }
    let cmpty = ty_vector(ty_elem(bty), ty_count(dty), false);
    var nc = tv_shuffle(sk0, cmpty, bty, nm0, vc_kind, 0, -1, x, z, 2, -1);
    if !single { nc = vc_add(nc, tv_shuffle(sk1, cmpty, bty, nm1, vc_kind, 0, -1, y, w, 2, -1)); }
    if pred == PRED_BAD_ICMP {
        nc = vc_add(nc, tv_arith(iop(lhs), dty, vc_kind, oi0, oi1));
    } else {
        nc = vc_add(nc, tv_cmpsel(iop(lhs), cmpty, dty, pred, vc_kind, oi0, oi1));
    }
    if !vc_has_one_user(lhs) { nc = vc_add(nc, lc); }
    if !same && !vc_has_one_user(rhs) { nc = vc_add(nc, rc); }
    if (is_constant(x) && is_constant(z)) || (is_constant(y) && is_constant(w)) { reduced = true; }
    if (if reduced { nc > old } else { nc >= old }) { return false; }
    let s0 = vcb_shuffle(x, z, nm0, "");
    let s1 = if single { s0 } else { vcb_shuffle(y, w, nm1, "") };
    let nb = if pred == PRED_BAD_ICMP { vcb_binop(iop(lhs), s0, s1, "", 0) } else { vcb_cmp(pred, s0, s1, "") };
    if is_inst(nb) {
        vu_copy_ir_flags(nb, lhs, true);
        vu_and_ir_flags(nb, rhs);
    }
    vcw_push_value(s0);
    vcw_push_value(s1);
    vc_replace(i, nb, true);
    return true;
}
// BinaryOperator::isCommutative(Opcode)
fn vc_commutative_op(o: i64) -> bool { o == OP_ADD || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_FADD || o == OP_FMUL }
// ShuffleVectorInst::isConcat
fn vc_shuffle_is_concat(sv: i32) -> bool {
    if is_undef_or_poison(op(sv, 0)) || is_undef_or_poison(op(sv, 1)) { return false; }
    if ty_kind(vals[sv].ty) == TK_SVEC { return false; }
    let nop = ty_count(vals[op(sv, 0)].ty);
    let nm = ty_count(vals[sv].ty);
    if nm != nop * 2 { return false; }
    var mask: i32[>..<] = [];
    vc_mask(sv, mask);
    return vc_identity_impl(mask, nm);
}

// ---------------------------------------------------------------- foldShuffleOfSelects

fn vc_fold_shuffle_of_selects(i: i32) -> bool {
    let s1 = op(i, 0);
    let s2 = op(i, 1);
    if !is_inst_op(s1, OP_SELECT) || !is_inst_op(s2, OP_SELECT) { return false; }
    var mask: i32[>..<] = [];
    vc_mask(i, mask);
    let c1 = op(s1, 0);
    let t1 = op(s1, 1);
    let f1 = op(s1, 2);
    let c2 = op(s2, 0);
    let t2 = op(s2, 1);
    let f2 = op(s2, 2);
    let c1t = vals[c1].ty as i32;
    let c2t = vals[c2].ty as i32;
    if !vc_is_fixed_vec(c1t) || !vc_is_fixed_vec(c2t) || c1t != c2t { return false; }
    let fp0 = is_fp_math_operator(s1);
    let fp1 = is_fp_math_operator(s2);
    if fp0 != fp1 || (fp0 && inst_fmf(s1) != inst_fmf(s2)) { return false; }
    let svt = vals[t1].ty as i32;
    let dvt = vals[i].ty as i32;
    let sk = SK_PERMUTETWOSRC;
    let cs1 = tv_cmpsel(OP_SELECT, svt, c1t, PRED_BAD_ICMP, vc_kind, 0, 0);
    let cs2 = tv_cmpsel(OP_SELECT, svt, c2t, PRED_BAD_ICMP, vc_kind, 0, 0);
    let old = vc_add(vc_add(cs1, cs2), tv_shuffle(sk, dvt, svt, mask, vc_kind, 0, -1, s1, s2, 2, i));
    var nc = tv_shuffle(sk, ty_vector(ty_scalar(c1t), mask.len, false), c1t, mask, vc_kind, 0, -1, c1, c2, 2, -1);
    nc = vc_add(nc, tv_shuffle(sk, dvt, svt, mask, vc_kind, 0, -1, t1, t2, 2, -1));
    nc = vc_add(nc, tv_shuffle(sk, dvt, svt, mask, vc_kind, 0, -1, f1, f2, 2, -1));
    let c1c2 = ty_vector(T_I1, ty_count(dvt), false);
    nc = vc_add(nc, tv_cmpsel(OP_SELECT, dvt, c1c2, PRED_BAD_ICMP, vc_kind, 0, 0));
    if !vc_has_one_use(s1) { nc = vc_add(nc, cs1); }
    if !vc_has_one_use(s2) { nc = vc_add(nc, cs2); }
    if nc > old { return false; }
    let sc = vcb_shuffle(c1, c2, mask, "");
    let st = vcb_shuffle(t1, t2, mask, "");
    let sf = vcb_shuffle(f1, f2, mask, "");
    let ns = vcb_select(sc, st, sf, if fp0 { inst_fmf(s1) } else { 0 }, "");
    vcw_push_value(sc);
    vcw_push_value(st);
    vcw_push_value(sf);
    vc_replace(i, ns, true);
    return true;
}

// ---------------------------------------------------------------- foldShuffleOfCastops

fn vc_fold_shuffle_of_castops(i: i32) -> bool {
    let v0 = op(i, 0);
    let v1 = op(i, 1);
    var old_mask: i32[>..<] = [];
    vc_mask(i, old_mask);
    let binary = !is_undef_or_poison(v1);
    if !vc_is_cast(v0) || (binary && !vc_is_cast(v1)) { return false; }
    var o = iop(v0);
    if !binary && o == OP_BITCAST { return false; }
    if binary {
        if vals[op(v0, 0)].ty != vals[op(v1, 0)].ty { return false; }
        if o != iop(v1) {
            if vc_sext_like(v0) && vc_sext_like(v1) { o = OP_SEXT; } else { return false; }
        }
    }
    let dty = vals[i].ty as i32;
    let cdt = vals[v0].ty as i32;
    let cst = vals[op(v0, 0)].ty as i32;
    if !vc_is_fixed_vec(dty) || !vc_is_fixed_vec(cdt) || !vc_is_fixed_vec(cst) { return false; }
    let ns = ty_count(cst);
    let nd = ty_count(cdt);
    if nd != ns && ns % nd != 0 && nd % ns != 0 { return false; }
    var nmask: i32[>..<] = [];
    if ns >= nd {
        vu_narrow_mask(ns / nd, old_mask, nmask);
    } else {
        if !vu_widen_mask(nd / ns, old_mask, nmask) { return false; }
    }
    let nsdt = ty_vector(ty_scalar(cst), nmask.len, false);
    let cc0 = tv_cast(iop(v0), cdt, cst, 0, vc_kind, v0);
    let sk = if binary { SK_PERMUTETWOSRC } else { SK_PERMUTESINGLESRC };
    var old = cc0;
    old = vc_add(old, tv_shuffle(sk, dty, cdt, old_mask, vc_kind, 0, -1, -1, -1, 0, i));
    var nc = tv_shuffle_simple(sk, nsdt, cst, nmask, vc_kind);
    nc = vc_add(nc, tv_cast(o, dty, nsdt, 0, vc_kind, -1));
    if !vc_has_one_use(v0) { nc = vc_add(nc, cc0); }
    if binary {
        let cc1 = tv_cast(iop(v1), cdt, cst, 0, vc_kind, v1);
        old = vc_add(old, cc1);
        if !vc_has_one_use(v1) { nc = vc_add(nc, cc1); }
    }
    if nc > old { return false; }
    let s = if binary { vcb_shuffle(op(v0, 0), op(v1, 0), nmask, "") } else { vcb_shuffle1(op(v0, 0), nmask, "") };
    let c = vcb_cast(o, s, dty, "");
    if is_inst(c) {
        vu_copy_ir_flags(c, v0, true);
        if binary { vu_and_ir_flags(c, v1); }
    }
    vcw_push_value(s);
    vc_replace(i, c, true);
    return true;
}
// m_SExtLike(m_Value()): sext, or zext nneg
fn vc_sext_like(v: i32) -> bool { is_inst_op(v, OP_SEXT) || (is_inst_op(v, OP_ZEXT) && (insts[inst_of(v)].flags & FL_NNEG) != 0) }

// ---------------------------------------------------------------- foldShuffleOfShuffles

fn vc_fold_shuffle_of_shuffles(i: i32) -> bool {
    let ov0 = op(i, 0);
    let ov1 = op(i, 1);
    var outer: i32[>..<] = [];
    vc_mask(i, outer);
    var m0 = vc_is_shuffle(ov0);
    var m1 = vc_is_shuffle(ov1);
    if !m0 && !m1 { return false; }
    var x0: i32 = -1;
    var y0: i32 = -1;
    var x1: i32 = -1;
    var y1: i32 = -1;
    var im0: i32[>..<] = [];
    var im1: i32[>..<] = [];
    if m0 { x0 = op(ov0, 0); y0 = op(ov0, 1); vc_mask(ov0, im0); }
    if m1 { x1 = op(ov1, 0); y1 = op(ov1, 1); vc_mask(ov1, im1); }
    var fake1 = false;
    if !m1 && is_poison(ov1) {
        x1 = x0;
        y1 = y0;
        for k in im0.len { im1.push(-1); }
        m1 = true;
        fake1 = true;
    }
    if !m0 { x0 = ov0; y0 = ov0; }
    if !m1 { x1 = ov1; y1 = ov1; }
    let dty = vals[i].ty as i32;
    if x0 < 0 || x1 < 0 { return false; }
    let sty = vals[x0].ty as i32;
    let imt = vals[ov0].ty as i32;
    if !vc_is_fixed_vec(dty) || !vc_is_fixed_vec(sty) || !vc_is_fixed_vec(imt) || vals[x0].ty != vals[x1].ty { return false; }
    let nsrc = ty_count(sty);
    let nimm = ty_count(imt);
    var nm: i32[>..<] = [];
    for m in outer { nm.push(m); }
    var nx: i32 = -1;
    var ny: i32 = -1;
    for k in nm.len {
        var m = nm[k] as i64;
        var src: i32 = -1;
        if 0 <= m && m < nimm {
            src = ov0;
            if m0 {
                m = im0[m] as i64;
                src = if m >= nsrc { y0 } else { x0 };
                m = if m >= nsrc { m - nsrc } else { m };
            }
        } else if m >= nimm {
            src = ov1;
            m -= nimm;
            if m1 {
                m = im1[m] as i64;
                src = if m >= nsrc { y1 } else { x1 };
                m = if m >= nsrc { m - nsrc } else { m };
            }
        }
        nm[k] = m as i32;
        if src >= 0 && m != -1 {
            if is_undef_or_poison(src) {
                if !is_poison(src) { return false; }
                nm[k] = -1;
                continue;
            }
            if nx < 0 || nx == src { nx = src; continue; }
            if ny < 0 || ny == src { nm[k] = (m + nsrc) as i32; ny = src; continue; }
            return false;
        }
    }
    if nx < 0 {
        vc_replace(i, c_poison(dty), true);
        return true;
    }
    if ny < 0 { ny = c_poison(sty); }
    if vc_is_identity_mask(nm, nsrc) {
        vc_replace(i, nx, true);
        return true;
    }
    var ic0: i64 = 0;
    if m0 { ic0 = tv_inst_cost(ov0, vc_kind); }
    var ic1: i64 = 0;
    if m1 { ic1 = tv_inst_cost(ov1, vc_kind); }
    let oc = tv_inst_cost(i, vc_kind);
    let old = vc_add(vc_add(ic0, ic1), oc);
    var unary = true;
    for m in nm { if m as i64 >= nsrc { unary = false; } }
    let sk = if unary { SK_PERMUTESINGLESRC } else { SK_PERMUTETWOSRC };
    var nc = tv_shuffle(sk, dty, sty, nm, vc_kind, 0, -1, nx, ny, 2, -1);
    if !vc_has_one_use(ov0) { nc = vc_add(nc, ic0); }
    if !vc_has_one_use(ov1) { nc = vc_add(nc, ic1); }
    if nc > old { return false; }
    let s = vcb_shuffle(nx, ny, nm, "");
    vc_replace(i, s, true);
    return true;
}

// ---------------------------------------------------------------- foldShufflesOfLengthChangingShuffles

fn vc_fold_shuffles_of_length_changing_shuffles(i: i32) -> bool {
    let trunk_ty = vals[i].ty as i32;
    if !vc_is_fixed_vec(trunk_ty) { return false; }
    var chain: i64 = 0;
    var mask: i32[>..<] = [];
    var ymask: i32[>..<] = [];
    var old: i64 = 0;
    var nc: i64 = 0;
    var trunk = i;
    let ntrunk = ty_count(trunk_ty);
    var y: i32 = -1;
    loop {
        if chain != 0 && !vc_has_one_use(trunk) { break; }
        if !vc_is_shuffle(trunk) { break; }
        var ov0 = op(trunk, 0);
        var ov1 = op(trunk, 1);
        var outer: i32[>..<] = [];
        vc_mask(trunk, outer);
        if vals[ov0].ty != trunk_ty { break; }
        let mt0 = vc_is_shuffle(ov0);
        let mt1 = vc_is_shuffle(ov1);
        let leaf0 = mt0 && vals[op(ov0, 0)].ty != vals[i].ty;
        let leaf1 = mt1 && vals[op(ov1, 0)].ty != vals[i].ty;
        if leaf0 == leaf1 { break; }
        if leaf0 {
            let t = ov0; ov0 = ov1; ov1 = t;
            for k in outer.len {
                let m = outer[k] as i64;
                if m == -1 { continue; }
                outer[k] = (if m < ntrunk { m + ntrunk } else { m - ntrunk }) as i32;
            }
        }
        if !vc_has_one_use(ov1) { break; }
        let a1 = op(ov1, 0);
        let bb1 = op(ov1, 1);
        if !is_undef_or_poison(a1) {
            if y < 0 { y = a1; } else if y != a1 { break; }
        }
        if !is_undef_or_poison(bb1) {
            if y < 0 { y = bb1; } else if y != bb1 { break; }
        }
        let yty = vals[a1].ty as i32;
        let nleaf = ty_count(yty);
        var lymask: i32[>..<] = [];
        vc_mask(ov1, lymask);
        for k in lymask.len { if lymask[k] as i64 >= nleaf { lymask[k] = (lymask[k] as i64 - nleaf) as i32; } }
        let lold = vc_add(tv_inst_cost(trunk, vc_kind), tv_inst_cost(ov1, vc_kind));
        if chain == 0 {
            mask.clear();
            for m in outer { mask.push(m); }
            ymask.clear();
            for m in lymask { ymask.push(m); }
            old = lold;
            nc = lold;
            trunk = ov0;
            chain++;
            continue;
        }
        var nym: i32[>..<] = [];
        for m in ymask { nym.push(m); }
        var valid = true;
        let zl = if nym.len < lymask.len { nym.len } else { lymask.len };
        for k in zl {
            let leaf = lymask[k];
            if leaf == -1 || nym[k] == leaf { continue; }
            if nym[k] == -1 { nym[k] = leaf; } else { valid = false; break; }
        }
        if !valid { break; }
        var nmask: i32[>..<] = [];
        for m in mask {
            if m < 0 || m as i64 >= ntrunk { nmask.push(m); } else { nmask.push(outer[m]); }
        }
        let lnc = vc_add(tv_shuffle_simple(SK_PERMUTESINGLESRC, trunk_ty, yty, nym, vc_kind),
                         tv_shuffle_simple(SK_PERMUTETWOSRC, trunk_ty, trunk_ty, nmask, vc_kind));
        if lnc >= nc && lold < tc_sub(lnc, nc) { break; }
        mask.clear();
        for m in nmask { mask.push(m); }
        ymask.clear();
        for m in nym { ymask.push(m); }
        old = vc_add(old, lold);
        nc = lnc;
        trunk = ov0;
        chain++;
    }
    if chain <= 1 { return false; }
    if y < 0 { return false; }
    var all_y = true;
    for m in mask { if !(m < 0 || m as i64 >= ntrunk) { all_y = false; } }
    if all_y {
        for k in mask.len { if mask[k] as i64 >= ntrunk { mask[k] = ymask[mask[k] as i64 - ntrunk]; } }
        let root = vcb_shuffle(y, c_poison(vals[y].ty), mask, "");
        vc_replace(i, root, true);
        return true;
    }
    let leaf = vcb_shuffle(y, c_poison(vals[y].ty), ymask, "");
    let root = vcb_shuffle(trunk, leaf, mask, "");
    vc_replace(i, root, true);
    return true;
}

// ---------------------------------------------------------------- shuffles of intrinsics

fn vc_fold_shuffle_of_intrinsics(i: i32) -> bool {
    let ii0 = op(i, 0);
    let ii1 = op(i, 1);
    var old_mask: i32[>..<] = [];
    vc_mask(i, old_mask);
    if !vc_is_intrinsic(ii0) || !vc_is_intrinsic(ii1) { return false; }
    let id = inst_iid(ii0);
    if id != inst_iid(ii1) { return false; }
    let c0 = tv_intrinsic_call(ii0, vc_kind);
    let c1 = tv_intrinsic_call(ii1, vc_kind);
    let dty = vals[i].ty as i32;
    let t0 = vals[ii0].ty as i32;
    if !vc_is_fixed_vec(dty) || !vc_is_fixed_vec(t0) { return false; }
    if !is_trivially_vectorizable(id) { return false; }
    let na = cb_nargs(ii0);
    for k in na {
        let a0 = cb_arg(ii0, k);
        let a1 = cb_arg(ii1, k);
        if vu_scalar_op_at_arg(id, k, true) {
            if a0 != a1 { return false; }
        } else if vals[a0].ty != vals[a1].ty {
            return false;
        }
    }
    let old = vc_add(vc_add(c0, c1), tv_shuffle(SK_PERMUTETWOSRC, dty, t0, old_mask, vc_kind, 0, -1, ii0, ii1, 2, i));
    var ntys: i32[>..<] = [];
    var nc: i64 = 0;
    var seen0: i32[>..<] = [];
    var seen1: i32[>..<] = [];
    for k in na {
        if vu_scalar_op_at_arg(id, k, true) {
            ntys.push(vals[cb_arg(ii0, k)].ty);
        } else {
            let vt = vals[cb_arg(ii0, k)].ty as i32;
            let at = ty_vector(ty_elem(vt), ty_count(dty), false);
            ntys.push(at);
            let a0 = cb_arg(ii0, k);
            let a1 = cb_arg(ii1, k);
            var seen = false;
            for j in seen0.len { if seen0[j] == a0 && seen1[j] == a1 { seen = true; } }
            if seen { continue; }
            seen0.push(a0);
            seen1.push(a1);
            nc = vc_add(nc, tv_shuffle(SK_PERMUTETWOSRC, at, vt, old_mask, vc_kind, 0, -1, a0, a1, 2, -1));
        }
    }
    nc = vc_add(nc, tv_intrinsic_types(id, dty, ntys, 0, vc_kind));
    if !vc_has_one_use(ii0) { nc = vc_add(nc, c0); }
    if ii1 != ii0 && !vc_has_one_use(ii1) { nc = vc_add(nc, c1); }
    if nc > old { return false; }
    var nargs: i32[>..<] = [];
    var cache0: i32[>..<] = [];
    var cache1: i32[>..<] = [];
    var cachev: i32[>..<] = [];
    for k in na {
        if vu_scalar_op_at_arg(id, k, true) {
            nargs.push(cb_arg(ii0, k));
        } else {
            let a0 = cb_arg(ii0, k);
            let a1 = cb_arg(ii1, k);
            var hit: i32 = -1;
            for j in cache0.len { if cache0[j] == a0 && cache1[j] == a1 { hit = cachev[j]; } }
            if hit >= 0 { nargs.push(hit); continue; }
            let s = vcb_shuffle(a0, a1, old_mask, "");
            cache0.push(a0);
            cache1.push(a1);
            cachev.push(s);
            nargs.push(s);
            vcw_push_value(s);
        }
    }
    let ni = vcb_intrinsic_rt(dty, id as i64, nargs, 0, "");
    if is_inst(ni) {
        vu_copy_ir_flags(ni, ii0, true);
        vu_and_ir_flags(ni, ii1);
    }
    vc_replace(i, ni, true);
    return true;
}

fn vc_fold_permute_of_intrinsic(i: i32) -> bool {
    let v0 = op(i, 0);
    if !m_undef(op(i, 1)) { return false; }
    var mask: i32[>..<] = [];
    vc_mask(i, mask);
    if !vc_is_intrinsic(v0) { return false; }
    let dty = vals[i].ty as i32;
    let sty = vals[v0].ty as i32;
    if !vc_is_fixed_vec(dty) || !vc_is_fixed_vec(sty) { return false; }
    let nsrc = ty_count(sty);
    for m in mask { if m as i64 >= nsrc { return false; } }
    let id = inst_iid(v0);
    if !is_trivially_vectorizable(id) { return false; }
    let ic = tv_intrinsic_call(v0, vc_kind);
    let old = vc_add(ic, tv_shuffle(SK_PERMUTESINGLESRC, dty, sty, mask, vc_kind, 0, -1, v0, -1, 1, i));
    var ntys: i32[>..<] = [];
    var nc: i64 = 0;
    let na = cb_nargs(v0);
    for k in na {
        if vu_scalar_op_at_arg(id, k, true) {
            ntys.push(vals[cb_arg(v0, k)].ty);
        } else {
            let vt = vals[cb_arg(v0, k)].ty as i32;
            let at = ty_vector(ty_elem(vt), ty_count(dty), false);
            ntys.push(at);
            nc = vc_add(nc, tv_shuffle(SK_PERMUTESINGLESRC, at, vt, mask, vc_kind, 0, -1, cb_arg(v0, k), -1, 1, -1));
        }
    }
    nc = vc_add(nc, tv_intrinsic_types(id, dty, ntys, 0, vc_kind));
    if !vc_has_one_use(v0) { nc = vc_add(nc, ic); }
    if nc > old { return false; }
    var nargs: i32[>..<] = [];
    for k in na {
        if vu_scalar_op_at_arg(id, k, true) {
            nargs.push(cb_arg(v0, k));
        } else {
            let s = vcb_shuffle1(cb_arg(v0, k), mask, "");
            nargs.push(s);
            vcw_push_value(s);
        }
    }
    let ni = vcb_intrinsic_rt(dty, id as i64, nargs, 0, "");
    if is_inst(ni) { vu_copy_ir_flags(ni, v0, true); }
    vc_replace(i, ni, true);
    return true;
}

// ---------------------------------------------------------------- foldShuffleToIdentity

// InstLane vectors live in a global pool (value, lane); an Item is a run (start, length).
var vcl_v: i32[>..<];
var vcl_l: i32[>..<];
var vcg_ops: i32[>..<];       // generateNewInstTree's Ops, per recursion level
// leaf sets: (value, use id) pairs; kind 0 identity, 1 splat, 2 concat
var vcleaf_v: i32[>..<];
var vcleaf_u: i32[>..<];
var vcleaf_k: i32[>..<];

// lookThroughShuffles(V, Lane): (value or -1, lane)
fn vc_look_through_shuffles(v0: i32, lane0: i64) -> i32, i64 {
    var v = v0;
    var lane = lane0;
    while vc_is_shuffle(v) {
        let n = ty_count(vals[op(v, 0)].ty);
        let m = vc_mask_at(v, lane) as i64;
        if m < 0 { return -1, -1; }
        if m < n { v = op(v, 0); lane = m; } else { v = op(v, 1); lane = m - n; }
    }
    return v, lane;
}
// generateInstLaneVectorFromOperand(Item, Op): appends the new item to the pool and returns its start
fn vc_lanes_from_operand(s: i64, n: i64, opi: i64) -> i64 {
    let at = vcl_v.len;
    for k in n {
        let u = vcl_v[s + k];
        if u >= 0 {
            let v, l = vc_look_through_shuffles(op(u, opi), vcl_l[s + k] as i64);
            vcl_v.push(v);
            vcl_l.push(l as i32);
        } else {
            vcl_v.push(-1);
            vcl_l.push(-1);
        }
    }
    return at;
}
fn vc_leaf_has(v: i32, u: i32, k: i32) -> bool {
    for j in vcleaf_v.len { if vcleaf_v[j] == v && vcleaf_u[j] == u && vcleaf_k[j] == k { return true; } }
    return false;
}
fn vc_leaf_add(v: i32, u: i32, k: i32) {
    if vc_leaf_has(v, u, k) { return; }
    vcleaf_v.push(v); vcleaf_u.push(u); vcleaf_k.push(k);
}

// isFreeConcat(Item, CostKind, TTI)
fn vc_is_free_concat(s: i64, n: i64) -> bool {
    let ty = vals[vcl_v[s]].ty as i32;
    let ne = ty_count(ty);
    if n == ne || ne == 1 || n % ne != 0 { return false; }
    var cm: i32[>..<] = [];
    for k in ne * 2 { cm.push(k as i32); }
    if tv_shuffle_simple(SK_PERMUTETWOSRC, ty_vector(ty_scalar(ty), ne * 2, false), ty, cm, vc_kind) != 0 { return false; }
    let nsl = n / ne;
    if nsl & (nsl - 1) != 0 { return false; }
    for sl in nsl {
        let sv = vcl_v[s + sl * ne];
        if sv < 0 || vals[sv].ty != ty { return false; }
        for e in ne {
            if vcl_l[s + sl * ne + e] as i64 != e || vcl_v[s + sl * ne + e] != sv { return false; }
        }
    }
    return true;
}

// Value::getValueID (as far as the equivalence test needs it)
fn vc_value_id(v: i32) -> i64 { if is_inst(v) { 1000 + iop(v) } else { vals[v].kind as i64 } }

// generateNewInstTree(Item, From, IdentityLeafs, SplatLeafs, ConcatLeafs, Builder, TTI)
recursive fn vc_gen_tree(s: i64, n: i64, from: i32) -> i32 {
    let fv = vcl_v[s];
    let fl = vcl_l[s] as i64;
    if vc_leaf_has(fv, from, 0) { return fv; }
    if vc_leaf_has(fv, from, 1) { return vc_gen_splat(fv, fl, n); }
    if vc_leaf_has(fv, from, 2) { return vc_gen_concat(s, n); }
    let i = fv;
    if iop(i) == OP_BITCAST {
        let dt = vals[i].ty as i32;
        let st = vals[op(i, 0)].ty as i32;
        if vc_is_fixed_vec(dt) && vc_is_fixed_vec(st) && ty_count(dt) != ty_count(st) {
            let de = ty_count(dt);
            let se = ty_count(st);
            let at = vcl_v.len;
            if de > se {
                let r = de / se;
                if n % r != 0 { return -1; }
                var idx: i64 = 0;
                while idx < n {
                    let v = vcl_v[s + idx];
                    if v < 0 { vcl_v.push(-1); vcl_l.push(-1); idx += r; continue; }
                    let nv, nl = vc_look_through_shuffles(op(v, 0), (vcl_l[s + idx] as i64) / r);
                    vcl_v.push(nv);
                    vcl_l.push(nl as i32);
                    idx += r;
                }
            } else {
                let r = se / de;
                for k in n {
                    let v = vcl_v[s + k];
                    if v < 0 { for j in r { vcl_v.push(-1); vcl_l.push(-1); } continue; }
                    for j in r {
                        let nv, nl = vc_look_through_shuffles(op(v, 0), (vcl_l[s + k] as i64) * r + j);
                        vcl_v.push(nv);
                        vcl_l.push(nl as i32);
                    }
                }
            }
            let nn = vcl_v.len - at;
            let o = vc_gen_tree(at, nn, vals[i].ops);
            vcl_v.resize(at);
            vcl_l.resize(at);
            return vcb_cast(OP_BITCAST, o, ty_vector(ty_scalar(dt), n, false), "");
        }
    }
    let ii = vc_is_intrinsic(i);
    let nops_ = if ii { cb_nargs(i) } else { nops(i) };
    let mark = vcg_ops.len;
    for idx in nops_ {
        if ii && vu_scalar_op_at_arg(inst_iid(i), idx, true) {
            vcg_ops.push(op(i, idx));
            continue;
        }
        let at = vc_lanes_from_operand(s, n, idx);
        let r = vc_gen_tree(at, n, vals[i].ops + idx as i32);
        vcl_v.resize(at);
        vcl_l.resize(at);
        vcg_ops.push(r);
    }
    let res = vc_gen_finish(s, n, i, mark, nops_);
    vcg_ops.resize(mark);
    return res;
}
fn vc_gen_splat(fv: i32, fl: i64, n: i64) -> i32 {
    var mask: i32[>..<] = [];
    for k in n { mask.push(fl as i32); }
    return vcb_shuffle1(fv, mask, "");
}
fn vc_gen_concat(s: i64, n: i64) -> i32 {
    var ne = ty_count(vals[vcl_v[s]].ty);
    var values: i32[>..<] = [];
    for k in n / ne { values.push(vcl_v[s + k * ne]); }
    while values.len > 1 {
        ne *= 2;
        var mask: i32[>..<] = [];
        for k in ne { mask.push(k as i32); }
        var nv: i32[>..<] = [];
        for k in values.len / 2 { nv.push(vcb_shuffle(values[k * 2], values[k * 2 + 1], mask, "")); }
        values.clear();
        for x in nv { values.push(x); }
    }
    return values[0];
}
fn vc_gen_finish(s: i64, n: i64, i: i32, mark: i64, nops_: i64) -> i32 {
    var vl: i32[>..<] = [];
    for k in n { if vcl_v[s + k] >= 0 { vl.push(vcl_v[s + k]); } }
    let dty = ty_vector(ty_scalar(vals[i].ty), n, false);
    let o = iop(i);
    var r: i32 = -1;
    if is_binary_op(o) {
        r = vcb_binop(o, vcg_ops[mark], vcg_ops[mark + 1], "", 0);
    } else if o == OP_ICMP || o == OP_FCMP {
        r = vcb_cmp(inst_pred(i), vcg_ops[mark], vcg_ops[mark + 1], "");
    } else if o == OP_SELECT {
        r = vcb_select(vcg_ops[mark], vcg_ops[mark + 1], vcg_ops[mark + 2], 0, "");
        if is_inst_op(r, OP_SELECT) {
            let pk = md_kind_id("prof");
            let uk = md_kind_id("unpredictable");
            let p = inst_get_md(i, pk);
            let u = inst_get_md(i, uk);
            if p >= 0 { inst_set_md(r, pk, p); }
            if u >= 0 { inst_set_md(r, uk, u); }
        }
    } else if is_cast_op(o) {
        r = vcb_cast(o, vcg_ops[mark], dty, "");
    } else if vc_is_intrinsic(i) {
        var a: i32[>..<] = [];
        for k in nops_ { a.push(vcg_ops[mark + k]); }
        r = vcb_intrinsic_rt(dty, inst_iid(i) as i64, a, 0, "");
    } else {
        r = vcb_fneg(vcg_ops[mark], 0, "");
    }
    vu_propagate_ir_flags(r, vl, -1, true);
    return r;
}

fn vc_fold_shuffle_to_identity(i: i32) -> bool {
    let ty = vals[i].ty as i32;
    if !vc_is_fixed_vec(ty) || vals[i].first_use < 0 { return false; }
    vcl_v.clear();
    vcl_l.clear();
    vcleaf_v.clear();
    vcleaf_u.clear();
    vcleaf_k.clear();
    let ne = ty_count(ty);
    for m in ne {
        let v, l = vc_look_through_shuffles(i, m);
        vcl_v.push(v);
        vcl_l.push(l as i32);
    }
    var wl_s: i64[>..<] = [];
    var wl_n: i64[>..<] = [];
    var wl_u: i32[>..<] = [];
    wl_s.push(0);
    wl_n.push(ne);
    wl_u.push(vals[i].first_use);
    var nvisited: i64 = 0;
    var traversed_bc = false;
    let lim = vc_max_scan();
    while wl_s.len > 0 {
        nvisited++;
        if nvisited > lim { return false; }
        let s = wl_s.pop();
        let n = wl_n.pop();
        let from = wl_u.pop();
        let fv = vcl_v[s];
        let fl = vcl_l[s] as i64;
        if fv < 0 { return false; }
        // identity value
        if fl == 0 && ty_count(vals[fv].ty) == n {
            var ok = true;
            for k in 1..n {
                let v = vcl_v[s + k];
                if v < 0 { continue; }
                if !(vals[v].ty == vals[fv].ty && vc_peek_bitcasts(v) == vc_peek_bitcasts(fv) && vcl_l[s + k] as i64 == k) { ok = false; break; }
            }
            if ok { vc_leaf_add(fv, from, 0); continue; }
        }
        // constant splats
        if is_constant(fv) && splat_value(fv, false) >= 0 {
            let sp = splat_value(fv, false);
            var ok = true;
            for k in 1..n {
                let v = vcl_v[s + k];
                if v < 0 { continue; }
                if !(is_constant(v) && splat_value(v, false) == sp) { ok = false; break; }
            }
            if ok { vc_leaf_add(fv, from, 1); continue; }
        }
        // a splat value
        var splat = true;
        for k in 1..n {
            let v = vcl_v[s + k];
            if v >= 0 && !(v == fv && vcl_l[s + k] as i64 == fl) { splat = false; break; }
        }
        if splat { vc_leaf_add(fv, from, 1); continue; }
        // CheckLaneIsEquivalentToFirst
        var equiv = true;
        for k in 1..n {
            let v = vcl_v[s + k];
            if v < 0 { continue; }
            if is_inst(v) && !vc_has_one_user(v) { equiv = false; break; }
            if vc_value_id(v) != vc_value_id(fv) { equiv = false; break; }
            if vc_is_cmp(v) && inst_pred(v) != inst_pred(fv) { equiv = false; break; }
            if vc_is_cast(v) && ty_scalar(vals[op(v, 0)].ty) != ty_scalar(vals[op(fv, 0)].ty) { equiv = false; break; }
            if is_inst_op(v, OP_SELECT) && (!ty_is_vector(vals[op(v, 0)].ty) || vals[op(v, 0)].ty != vals[op(fv, 0)].ty) { equiv = false; break; }
            if is_inst_op(v, OP_CALL) && !vc_is_intrinsic(v) { equiv = false; break; }
            if vc_is_intrinsic(v) {
                if !(vc_is_intrinsic(fv) && inst_iid(v) == inst_iid(fv) && !vc_has_bundles(v)) { equiv = false; break; }
            }
        }
        if equiv && is_inst(fv) {
            let o = iop(fv);
            if is_binary_op(o) || o == OP_ICMP || o == OP_FCMP {
                if vc_is_int_div_rem(o) { return false; }
                let a = vc_lanes_from_operand(s, n, 0);
                wl_s.push(a); wl_n.push(n); wl_u.push(vals[fv].ops);
                let b = vc_lanes_from_operand(s, n, 1);
                wl_s.push(b); wl_n.push(n); wl_u.push(vals[fv].ops + 1);
                continue;
            } else if o == OP_FNEG || o == OP_TRUNC || o == OP_ZEXT || o == OP_SEXT || o == OP_FPTOSI || o == OP_FPTOUI ||
                      o == OP_SITOFP || o == OP_UITOFP {
                let a = vc_lanes_from_operand(s, n, 0);
                wl_s.push(a); wl_n.push(n); wl_u.push(vals[fv].ops);
                continue;
            } else if o == OP_BITCAST {
                let dt = vals[fv].ty as i32;
                let st = vals[op(fv, 0)].ty as i32;
                if vc_is_fixed_vec(dt) && vc_is_fixed_vec(st) {
                    let de = ty_count(dt);
                    let se = ty_count(st);
                    if de == se {
                        let a = vc_lanes_from_operand(s, n, 0);
                        wl_s.push(a); wl_n.push(n); wl_u.push(vals[fv].ops);
                        continue;
                    }
                    if de > se && de % se == 0 {
                        let r = de / se;
                        let at = vcl_v.len;
                        var valid = n % r == 0;
                        var idx: i64 = 0;
                        while valid && idx < n {
                            let v0 = vcl_v[s + idx];
                            let l0 = vcl_l[s + idx] as i64;
                            if v0 < 0 {
                                for j in 1..r { if vcl_v[s + idx + j] >= 0 { valid = false; } }
                                if !valid { break; }
                                vcl_v.push(-1); vcl_l.push(-1);
                                idx += r;
                                continue;
                            }
                            if l0 % r != 0 { valid = false; break; }
                            for j in 1..r {
                                let vj = vcl_v[s + idx + j];
                                if vj < 0 || vj != v0 || vcl_l[s + idx + j] as i64 != l0 + j { valid = false; break; }
                            }
                            if !valid { break; }
                            let nv, nl = vc_look_through_shuffles(op(v0, 0), l0 / r);
                            vcl_v.push(nv);
                            vcl_l.push(nl as i32);
                            idx += r;
                        }
                        if valid {
                            traversed_bc = true;
                            wl_s.push(at); wl_n.push(vcl_v.len - at); wl_u.push(vals[fv].ops);
                            continue;
                        }
                    } else if se > de && se % de == 0 {
                        let r = se / de;
                        let at = vcl_v.len;
                        for k in n {
                            let v = vcl_v[s + k];
                            if v < 0 { for j in r { vcl_v.push(-1); vcl_l.push(-1); } continue; }
                            for j in r {
                                let nv, nl = vc_look_through_shuffles(op(v, 0), (vcl_l[s + k] as i64) * r + j);
                                vcl_v.push(nv);
                                vcl_l.push(nl as i32);
                            }
                        }
                        traversed_bc = true;
                        wl_s.push(at); wl_n.push(vcl_v.len - at); wl_u.push(vals[fv].ops);
                        continue;
                    }
                }
            } else if o == OP_SELECT {
                for j in 3 {
                    let a = vc_lanes_from_operand(s, n, j);
                    wl_s.push(a); wl_n.push(n); wl_u.push(vals[fv].ops + j as i32);
                }
                continue;
            } else if vc_is_intrinsic(fv) && is_trivially_vectorizable(inst_iid(fv)) && !vc_has_bundles(fv) {
                let id = inst_iid(fv);
                var bail = false;
                for opn in cb_nargs(fv) {
                    if vu_scalar_op_at_arg(id, opn, true) {
                        for k in 1..n {
                            let v = vcl_v[s + k];
                            if v >= 0 && op(v, opn) != op(fv, opn) { bail = true; }
                        }
                        if bail { break; }
                        continue;
                    }
                    let a = vc_lanes_from_operand(s, n, opn);
                    wl_s.push(a); wl_n.push(n); wl_u.push(vals[fv].ops + opn as i32);
                }
                if bail { return false; }
                continue;
            }
        }
        if vc_is_free_concat(s, n) { vc_leaf_add(fv, from, 2); continue; }
        return false;
    }
    if nvisited <= 1 { return false; }
    if nvisited == 2 && traversed_bc { return false; }
    vcb_set(i);
    vcg_ops.clear();
    let v = vc_gen_tree(0, ne, vals[i].first_use);
    if v < 0 { fatal("internal: VectorCombine: generateNewInstTree returned null"); }
    vc_replace(i, v, true);
    return true;
}

// ---------------------------------------------------------------- foldShuffleFromReductions

fn vc_is_int_reduce(id: i32) -> bool {
    return id == IID_vector_reduce_add || id == IID_vector_reduce_mul || id == IID_vector_reduce_and ||
        id == IID_vector_reduce_or || id == IID_vector_reduce_xor || id == IID_vector_reduce_smin ||
        id == IID_vector_reduce_smax || id == IID_vector_reduce_umin || id == IID_vector_reduce_umax;
}

fn vc_fold_shuffle_from_reductions(i: i32) -> bool {
    if !vc_is_intrinsic(i) { return false; }
    if !vc_is_int_reduce(inst_iid(i)) { return false; }
    var q: i32[>..<] = [];
    var qh: i64 = 0;
    vs_clear(VS_PASS0);
    var visited: i32[>..<] = [];
    var shuffle: i32 = -1;
    if is_inst(op(i, 0)) { q.push(op(i, 0)); }
    while qh < q.len {
        let cv = q[qh];
        qh++;
        if vs_has(VS_PASS0, cv) { continue; }
        if vu_is_splat_value(cv, 0) { continue; }
        vs_add(VS_PASS0, cv);
        visited.push(cv);
        if is_inst(cv) {
            if is_binary_op(iop(cv)) {
                for k in nops(cv) { q.push(op(cv, k)); }
                continue;
            } else if vc_is_shuffle(cv) {
                if shuffle >= 0 && shuffle != cv { return false; }
                shuffle = cv;
                continue;
            }
        }
        return false;
    }
    if shuffle < 0 { return false; }
    for v in visited {
        var u = vals[v].first_use;
        while u >= 0 {
            let us = uses[u].user;
            u = uses[u].next;
            if !vs_has(VS_PASS0, us) && us != i { return false; }
        }
    }
    let vt = vals[op(i, 0)].ty as i32;
    if !vc_is_fixed_vec(vt) { return false; }
    let sit = vals[op(shuffle, 0)].ty as i32;
    if !vc_is_fixed_vec(sit) { return false; }
    let nin = ty_count(sit);
    var cm: i32[>..<] = [];
    vc_mask(shuffle, cm);
    sort(cm) { a, b => (a as! u32) < (b as! u32) };
    var uses2 = false;
    for m in cm { if m as i64 >= nin { uses2 = true; } }
    var sm: i32[>..<] = [];
    vc_mask(shuffle, sm);
    let sk = if uses2 { SK_PERMUTETWOSRC } else { SK_PERMUTESINGLESRC };
    let old = tv_shuffle_simple(sk, vt, sit, sm, vc_kind);
    let nc = tv_shuffle_simple(sk, vt, sit, cm, vc_kind);
    if nc < old {
        vcb_set(shuffle);
        let ns = vcb_shuffle(op(shuffle, 0), op(shuffle, 1), cm, "");
        vc_replace(shuffle, ns, true);
        return true;
    }
    return vc_fold_select_shuffle(shuffle, true);
}

// ---------------------------------------------------------------- foldShuffleChainsToReduce

var vcc_nodes: i32[>..<];
var vcc_sources: i32[>..<];
var vcc_nvisited: i64 = 0;
var vcc_binop: i64 = -1;      // CommonBinOp (-1 = none)
var vcc_callop: i32 = 0;      // CommonCallOp (0 = none)

fn vcc_contains(xs: const i32[:], v: i32) -> bool { for x in xs { if x == v { return true; } } return false; }
fn vcc_is_chain_node(v: i32) -> bool {
    if vc_is_binop(v) { return vcc_binop >= 0 && iop(v) == vcc_binop; }
    if vu_is_minmax_intrinsic(v) { return vcc_callop != 0 && inst_iid(v) == vcc_callop; }
    if vc_is_shuffle(v) { return is_poison(op(v, 1)); }
    return false;
}
fn vcc_add_source(v: i32) -> bool {
    if !vc_is_fixed_vec(vals[v].ty) { return false; }
    if !vcc_contains(vcc_sources, v) { vcc_sources.push(v); }
    return true;
}
recursive fn vcc_walk(v: i32) -> bool {
    if vcc_contains(vcc_nodes, v) || vcc_contains(vcc_sources, v) { return true; }
    vcc_nvisited++;
    if vcc_nvisited > 32 { return false; }
    if !vcc_is_chain_node(v) { return vcc_add_source(v); }
    let n: i64 = if vc_is_shuffle(v) { 1 } else { 2 };
    for k in n { if !vcc_walk(op(v, k)) { return false; } }
    if vc_is_shuffle(v) || vcc_contains(vcc_nodes, op(v, 0)) || vcc_contains(vcc_nodes, op(v, 1)) {
        if !vcc_contains(vcc_nodes, v) { vcc_nodes.push(v); }
        return true;
    }
    return vcc_add_source(v);
}

// the Demands map: (value, lanes, duplicates)
var vcd_v: i32[>..<];
var vcd_lanes: AP[>..<];
var vcd_dups: AP[>..<];
fn vcd_find(v: i32) -> i64 { for k in vcd_v.len { if vcd_v[k] == v { return k; } } return -1; }
// DemandOf(V): the entry, (re)set to zero of the vector width
fn vcd_of(v: i32) -> i64 {
    let n = ty_count(vals[v].ty);
    var k = vcd_find(v);
    if k < 0 {
        k = vcd_v.len;
        vcd_v.push(v);
        vcd_lanes.push(ap_zero(1));
        vcd_dups.push(ap_zero(1));
    }
    if vcd_lanes[k].w as i64 != n {
        vcd_lanes[k] = ap_zero(n);
        vcd_dups[k] = ap_zero(n);
    }
    return k;
}

fn vc_fold_shuffle_chains_to_reduce(i: i32) -> bool {
    if !is_inst_op(i, OP_EXTRACTELEMENT) || !m_zero(op(i, 1)) { return false; }
    let vee = op(i, 0);
    let fvt = vals[vee].ty as i32;
    if !vc_is_fixed_vec(fvt) { return false; }
    if ty_count(fvt) < 2 { return false; }
    vcc_binop = -1;
    vcc_callop = 0;
    if vc_is_binop(vee) {
        if vu_reduction_for_binop(iop(vee)) == 0 { return false; }
        vcc_binop = iop(vee);
    } else if vu_is_minmax_intrinsic(vee) {
        vcc_callop = inst_iid(vee);
    } else {
        return false;
    }
    var common_fmf: u8 = 0;
    var is_float = false;
    vcc_nodes.clear();
    vcc_sources.clear();
    vcc_nvisited = 0;
    if !vcc_walk(vee) || vcc_nodes.len == 0 { return false; }
    let idempotent = vcc_callop != 0 || (vcc_binop >= 0 && vc_is_idempotent(vcc_binop));
    for v in vcc_nodes {
        if !vc_is_binop(v) || !is_fp_or_fp_vec(vals[v].ty) { continue; }
        if (inst_fmf(v) & FMF_REASSOC) == 0 { return false; }
        if !is_float { common_fmf = inst_fmf(v); is_float = true; } else { common_fmf = common_fmf & inst_fmf(v); }
    }
    vcd_v.clear();
    vcd_lanes.clear();
    vcd_dups.clear();
    let k0 = vcd_of(vee);
    vcd_lanes[k0] = ap_set_bit(vcd_lanes[k0], 0);
    var ri = vcc_nodes.len;
    while ri > 0 {
        ri--;
        let v = vcc_nodes[ri];
        let kv = vcd_find(v);
        if kv < 0 { continue; }
        let dl = vcd_lanes[kv];
        let dd = vcd_dups[kv];
        if ap_is_zero(dl) { continue; }
        if vc_is_shuffle(v) {
            let ks = vcd_of(op(v, 0));
            let w = vcd_lanes[ks].w as i64;
            for j in vc_mask_len(v) {
                let m = vc_mask_at(v, j) as i64;
                if !ap_get_bit(dl, j) || m < 0 || m >= w { continue; }
                if ap_get_bit(vcd_lanes[ks], m) || ap_get_bit(dd, j) { vcd_dups[ks] = ap_set_bit(vcd_dups[ks], m); }
                vcd_lanes[ks] = ap_set_bit(vcd_lanes[ks], m);
            }
        } else {
            for j in 2 {
                let ko = vcd_of(op(v, j));
                vcd_dups[ko] = ap_or(vcd_dups[ko], ap_or(dd, ap_and(vcd_lanes[ko], dl)));
                vcd_lanes[ko] = ap_or(vcd_lanes[ko], dl);
            }
        }
    }
    // the cut
    var cut: i32 = -1;
    var cut_elts = ap_zero(1);
    for s in vcc_sources {
        let k = vcd_find(s);
        if k < 0 || ap_is_zero(vcd_lanes[k]) { continue; }
        if cut >= 0 || (!idempotent && !ap_is_zero(vcd_dups[k])) { cut = -1; break; }
        cut = s;
        cut_elts = vcd_lanes[k];
    }
    if cut < 0 {
        for v in vcc_nodes {
            if !vc_is_binop(v) && !vu_is_minmax_intrinsic(v) { continue; }
            let k = vcd_find(v);
            if k < 0 || !ap_is_all_ones(vcd_lanes[k]) { continue; }
            if !idempotent && !ap_is_zero(vcd_dups[k]) { continue; }
            if !vcc_covers_chain(vee, v) { continue; }
            cut = v;
            cut_elts = vcd_lanes[k];
            break;
        }
    }
    if cut < 0 || ap_popcount(cut_elts) < 2 { return false; }
    let rop = if vcc_callop != 0 { vu_minmax_reduction_id(vcc_callop) } else { vu_reduction_for_binop(vcc_binop) };
    if rop == 0 { return false; }
    var orig: i64 = 0;
    for v in vcc_nodes { orig = vc_add(orig, tv_inst_cost(v, vc_kind)); }
    let svt = vals[cut].ty as i32;
    let partial = !ap_is_all_ones(cut_elts);
    let rvt = if partial { ty_vector(ty_elem(fvt), ap_popcount(cut_elts), false) } else { svt };
    var emask: i32[>..<] = [];
    var nc: i64 = 0;
    if partial {
        let cw = cut_elts.w as i64;
        for j in cw { if ap_get_bit(cut_elts, j) { emask.push(j as i32); } }
        var subidx: i64 = 0;
        var sk = SK_PERMUTESINGLESRC;
        if ap_is_shifted_mask(cut_elts) { sk = SK_EXTRACTSUBVECTOR; subidx = ap_countr_zero(cut_elts); }
        nc = vc_add(nc, tv_shuffle(sk, rvt, svt, emask, vc_kind, subidx, rvt, -1, -1, 0, -1));
    }
    var tys: i32[>..<] = [];
    if is_float { tys.push(ty_elem(rvt)); }
    tys.push(rvt);
    nc = vc_add(nc, tv_intrinsic_types(rop, ty_elem(rvt), tys, if is_float { common_fmf } else { 0 }, vc_kind));
    if !tc_valid(orig) || !tc_valid(nc) { return false; }
    if (if vc_has_one_use(vee) { nc > orig } else { nc >= orig }) { return false; }
    var input = cut;
    if partial { input = vcb_shuffle1(cut, emask, ""); }
    var red: i32 = -1;
    if is_float {
        var ident = binop_identity(vcc_binop, ty_elem(rvt), false);
        if vcc_binop == OP_FADD && (common_fmf & FMF_NSZ) != 0 { ident = c_null(ty_elem(rvt)); }
        red = vcb_intrinsic(rop as i64, [rvt], [ident, input], common_fmf, "");
    } else {
        red = vcb_intrinsic(rop as i64, [rvt], [input], 0, "");
    }
    vc_replace(i, red, true);
    return true;
}
// CoversChain(V)
fn vcc_covers_chain(vee: i32, v: i32) -> bool {
    var wl: i32[>..<] = [];
    var seen: i32[>..<] = [];
    wl.push(vee);
    seen.push(vee);
    while wl.len > 0 {
        let u = wl.pop();
        let n: i64 = if vc_is_shuffle(u) { 1 } else { 2 };
        for k in n {
            let o = op(u, k);
            if o == v || vcc_contains(seen, o) { continue; }
            seen.push(o);
            if !vcc_contains(vcc_nodes, o) { return false; }
            wl.push(o);
        }
    }
    return true;
}

// ---------------------------------------------------------------- foldCastFromReductions

fn vc_fold_cast_from_reductions(i: i32) -> bool {
    if !vc_is_intrinsic(i) { return false; }
    let id = inst_iid(i);
    var trunc_only = false;
    if id == IID_vector_reduce_add || id == IID_vector_reduce_mul { trunc_only = true; }
    else if id == IID_vector_reduce_and || id == IID_vector_reduce_or || id == IID_vector_reduce_xor { }
    else { return false; }
    let ro = vu_arith_reduction_instruction(id);
    let rsrc = op(i, 0);
    var src: i32 = -1;
    if vc_has_one_use(rsrc) && is_inst_op(rsrc, OP_TRUNC) { src = op(rsrc, 0); }
    else if !trunc_only && vc_has_one_use(rsrc) && (is_inst_op(rsrc, OP_ZEXT) || is_inst_op(rsrc, OP_SEXT)) { src = op(rsrc, 0); }
    else { return false; }
    let co = iop(rsrc);
    let sty = vals[src].ty as i32;
    let rsty = vals[rsrc].ty as i32;
    let rt = vals[i].ty as i32;
    var old = tv_arith_reduction(ro, rsty, false, vc_kind);
    old = vc_add(old, tv_cast(co, rsty, sty, 0, vc_kind, rsrc));
    let nc = vc_add(tv_arith_reduction(ro, sty, false, vc_kind), tv_cast(co, rt, ty_scalar(rsty), 0, vc_kind, -1));
    if old <= nc || !tc_valid(nc) { return false; }
    let nr = vcb_intrinsic_rt(ty_scalar(sty), id as i64, [src], 0, "");
    let nc2 = vcb_cast(co, nr, rt, "");
    vc_replace(i, nc2, true);
    return true;
}

// ---------------------------------------------------------------- icmp of reductions

// SimplifyQuery(DL, nullptr, &DT, &AC).getWithInstruction(cx) for the ValueTracking calls
fn vc_sq_at(cx: i32) {
    kb_cxt = cx;
    sq_no_dt = false;
    sq_no_ac = false;
    sq_no_tli = true;
    dc_active = false;
}
fn vc_sq_done() { sq_no_tli = false; }
// m_ICmp(Pred, m_Value, m_APInt(C)): the APInt constant id or -1
fn vc_icmp_apint(i: i32) -> i32 { if is_inst_op(i, OP_ICMP) { m_apint(op(i, 1)) } else { -1 } }

fn vc_fold_sign_bit_reduction_cmp(i: i32) -> bool {
    if !is_inst_op(i, OP_ICMP) { return false; }
    var pred = inst_pred(i);
    let rop = op(i, 0);
    let cv = m_apint(op(i, 1));
    if cv < 0 || !vc_has_one_use(rop) || !vc_is_intrinsic(rop) { return false; }
    let cmpv = ci_ap(cv);
    let oid = inst_iid(rop);
    if oid != IID_vector_reduce_or && oid != IID_vector_reduce_umax && oid != IID_vector_reduce_and &&
       oid != IID_vector_reduce_umin && oid != IID_vector_reduce_add { return false; }
    let rsrc = cb_arg(rop, 0);
    let vt = vals[rsrc].ty as i32;
    if !vc_is_fixed_vec(vt) { return false; }
    let bw = tt_scalar_bits(vt);
    if bw == 1 { return false; }
    let ne = ty_count(vt);
    var tree: i64 = OP_ADD;
    if oid == IID_vector_reduce_or || oid == IID_vector_reduce_umax { tree = OP_OR; }
    else if oid == IID_vector_reduce_and || oid == IID_vector_reduce_umin { tree = OP_AND; }
    var wl: i32[>..<] = [];
    var sources: i32[>..<] = [];
    wl.push(rsrc);
    var has_ashr = false;
    var is_ashr = false;
    let maxs: i64 = 8;
    var old = tv_inst_cost(rop, vc_kind);
    while wl.len > 0 && wl.len <= maxs && sources.len <= maxs {
        let v = wl.pop();
        if vc_has_one_use(v) && (is_inst_op(v, OP_LSHR) || is_inst_op(v, OP_ASHR)) && m_specific_int(op(v, 1), (bw - 1) as u64) {
            let this_ashr = iop(v) == OP_ASHR;
            if !has_ashr { has_ashr = true; is_ashr = this_ashr; } else if is_ashr != this_ashr { return false; }
            sources.push(op(v, 0));
            old = vc_add(old, tv_inst_cost(v, vc_kind));
            continue;
        }
        if !(vc_has_one_use(v) && is_inst_op(v, tree)) { return false; }
        old = vc_add(old, tv_inst_cost(v, vc_kind));
        wl.push(op(v, 0));
        wl.push(op(v, 1));
    }
    if sources.len == 0 || sources.len > maxs || wl.len > maxs || !has_ashr { return false; }
    let nsrc = sources.len;
    let cw = cmpv.w as i64;
    // isIntN(BitWidth, NumSources * NumElts)
    if oid == IID_vector_reduce_add {
        let total = nsrc * ne;
        // isIntN(N, x): -2^(N-1) <= x <= 2^(N-1) - 1
        if bw < 64 && total > ((1 as i64) << (bw - 1)) - 1 { return false; }
    }
    let count: u64 = if oid == IID_vector_reduce_add { (nsrc * ne) as u64 } else { 1 };
    var negv = ap_u64(count, cw);
    if is_ashr { negv = ap_neg(negv); }
    let zero = ap_zero(cw);
    let lo = ap_smin(zero, negv);
    let hi = ap_smax(zero, negv);
    let is_eq_pred = pred == VC_EQ || pred == VC_NE;
    let is_signed = pred >= VC_SGT && pred <= VC_SLE;
    if !is_eq_pred && !is_signed {
        if ap_is_neg(lo) { return false; }
        pred = vc_flip_signedness(pred);
    }
    var is_eq = false;
    var tests_neg = false;
    if is_eq_pred {
        if ap_is_zero(cmpv) { tests_neg = false; }
        else if ap_eq(cmpv, negv) { tests_neg = true; }
        else { return false; }
        is_eq = pred == VC_EQ;
    } else if pred == VC_SLT && ap_eq(cmpv, hi) {
        is_eq = false; tests_neg = ap_eq(hi, negv);
    } else if pred == VC_SGT && ap_eq(cmpv, ap_dec(hi)) {
        is_eq = true; tests_neg = ap_eq(hi, negv);
    } else if pred == VC_SGT && ap_eq(cmpv, lo) {
        is_eq = false; tests_neg = ap_eq(lo, negv);
    } else if pred == VC_SLT && ap_eq(cmpv, ap_inc(lo)) {
        is_eq = true; tests_neg = ap_eq(lo, negv);
    } else {
        return false;
    }
    // AnyNonNeg 0b000, AllNeg 0b011, AllNonNeg 0b101, AnyNeg 0b110
    var base: i64 = 0;
    if oid == IID_vector_reduce_or || oid == IID_vector_reduce_umax { base = if tests_neg { 6 } else { 5 }; }
    else if oid == IID_vector_reduce_and || oid == IID_vector_reduce_umin { base = if tests_neg { 3 } else { 0 }; }
    else { base = if tests_neg { 3 } else { 5 }; }
    let check = if is_eq { base } else { base ^ 3 };
    let req_or = (check & 4) != 0;
    let neg_check = (check & 2) != 0;
    let arith_id: i32 = if req_or { IID_vector_reduce_or } else { IID_vector_reduce_and };
    let mm_id: i32 = if req_or { IID_vector_reduce_umax } else { IID_vector_reduce_umin };
    let ac = tv_arith_reduction(vu_arith_reduction_instruction(arith_id), vt, false, vc_kind);
    let mc = tv_minmax_reduction(vu_minmax_reduction_op(mm_id), vt, 0, vc_kind);
    var nid: i32 = arith_id;
    var nc = ac;
    if !(ac <= mc) { nid = mm_id; nc = mc; }
    if nsrc > 1 {
        let co = if req_or { OP_OR } else { OP_AND };
        nc = vc_add(nc, tc_mul(tv_arith0(co, vt, vc_kind), nsrc - 1));
    }
    if nc > old { return false; }
    vcb_set(i);
    let sty = ty_scalar(vt);
    var input = sources[0];
    if nsrc > 1 {
        let co = if req_or { OP_OR } else { OP_AND };
        for k in 1..nsrc { input = vcb_binop(co, input, sources[k], "", 0); }
    }
    let nr = vcb_intrinsic_rt(sty, nid as i64, [input], 0, "");
    let ncmp = if neg_check { vcb_cmp(VC_SLT, nr, c_null(vals[nr].ty), "") } else { vcb_cmp(VC_SGT, nr, c_all_ones(vals[nr].ty), "") };
    vc_replace(i, ncmp, true);
    return true;
}

fn vc_fold_reduction_zero_test(i: i32) -> bool {
    if !is_inst_op(i, OP_ICMP) { return false; }
    var pred = inst_pred(i);
    var opv: i32 = -1;
    if m_zero(op(i, 1)) { opv = op(i, 0); }
    else if m_zero(op(i, 0)) { opv = op(i, 1); pred = vc_swap_pred(pred); }
    else { return false; }
    if pred != VC_EQ && pred != VC_NE { return false; }
    if !vc_is_intrinsic(opv) || !vc_has_one_use(opv) { return false; }
    let rid = inst_iid(opv);
    if rid != IID_vector_reduce_or && rid != IID_vector_reduce_umax { return false; }
    let vec = cb_arg(opv, 0);
    let vt = vals[vec].ty as i32;
    if !vc_is_fixed_vec(vt) || !ty_is_int(ty_elem(vt)) { return false; }
    let nid: i32 = if pred == VC_NE { IID_vector_reduce_or } else { IID_vector_reduce_and };
    let old = vc_add(tv_inst_cost(opv, vc_kind), tv_inst_cost(i, vc_kind));
    let cty = cmp_result_ty(vt);
    var nc = tv_cmpsel(OP_ICMP, vt, cty, pred, vc_kind, 0, 0);
    nc = vc_add(nc, tv_arith_reduction(vu_arith_reduction_instruction(nid), cty, false, vc_kind));
    if !tc_valid(old) || !tc_valid(nc) || nc > old { return false; }
    vcb_set(i);
    let ncmp = vcb_cmp(pred, vec, c_null(vt), "");
    let nr = vcb_intrinsic(nid as i64, [cty], [ncmp], 0, "");
    vc_replace(i, nr, true);
    return true;
}
// CmpInst::getSwappedPredicate (integer predicates)
fn vc_swap_pred(p: i64) -> i64 {
    if p == VC_EQ || p == VC_NE { return p; }
    if p == VC_UGT { return VC_ULT; } if p == VC_UGE { return VC_ULE; } if p == VC_ULT { return VC_UGT; } if p == VC_ULE { return VC_UGE; }
    if p == VC_SGT { return VC_SLT; } if p == VC_SGE { return VC_SLE; } if p == VC_SLT { return VC_SGT; } if p == VC_SLE { return VC_SGE; }
    return p;
}

fn vc_log2_ceil(x: i64) -> i64 { var k: i64 = 0; while ((1 as i64) << k) < x { k++; } return k; }
fn vc_log2_floor(x: i64) -> i64 { var k: i64 = 0; while ((1 as i64) << (k + 1)) <= x { k++; } return k; }

fn vc_fold_icmp_eq_zero_vector_reduce(i: i32) -> bool {
    if !is_inst_op(i, OP_ICMP) || !m_zero(op(i, 1)) { return false; }
    let pred = inst_pred(i);
    if pred != VC_EQ && pred != VC_NE { return false; }
    let ii = op(i, 0);
    if !vc_is_intrinsic(ii) { return false; }
    let id = inst_iid(ii);
    if id != IID_vector_reduce_add && id != IID_vector_reduce_or && id != IID_vector_reduce_umin &&
       id != IID_vector_reduce_umax && id != IID_vector_reduce_smin && id != IID_vector_reduce_smax { return false; }
    let inner = cb_arg(ii, 0);
    if !vc_has_one_use(ii) || !vc_is_fixed_vec(vals[inner].ty) { return false; }
    var x: i32 = -1;
    if is_inst_op(inner, OP_SHL) && op_nuw(inner) { x = op(inner, 0); }
    else if is_inst_op(inner, OP_MUL) && op_nuw(inner) && vc_m_nonzero_int(op(inner, 1)) { x = op(inner, 0); }
    else if is_inst_op(inner, OP_ZEXT) { x = op(inner, 0); }
    else if is_inst_op(inner, OP_SEXT) { x = op(inner, 0); }
    else if is_inst_op(inner, OP_SUB) && m_zero_int(op(inner, 0)) { x = op(inner, 1); }
    else { return false; }
    let xty = vals[x].ty as i32;
    if id == IID_vector_reduce_add {
        vc_sq_at(i);
        let kx = kb_compute_all(x, 0);
        vc_sq_at(i);
        let kfx = kb_compute_all(inner, 0);
        vc_sq_done();
        let lost = vc_log2_ceil(ty_count(xty));
        if kb_min_lz(kx) <= lost || kb_min_lz(kfx) <= lost { return false; }
    } else if id == IID_vector_reduce_smin || id == IID_vector_reduce_smax {
        vc_sq_at(i);
        let a = kb_is_nonneg(kb_compute_all(inner, 0));
        vc_sq_at(i);
        let b = a && kb_is_nonneg(kb_compute_all(x, 0));
        vc_sq_done();
        if !a || !b { return false; }
    }
    if is_inst_op(inner, OP_ZEXT) || is_inst_op(inner, OP_SEXT) {
        let fxt = vals[inner].ty as i32;
        let ec = tv_cast(iop(inner), fxt, xty, 0, vc_kind, inner);
        var orc: i64 = 0;
        var nrc: i64 = 0;
        if id == IID_vector_reduce_add || id == IID_vector_reduce_or {
            orc = tv_arith_reduction(vu_arith_reduction_instruction(id), fxt, false, vc_kind);
            nrc = tv_arith_reduction(vu_arith_reduction_instruction(id), xty, false, vc_kind);
        } else {
            orc = tv_minmax_reduction(vu_minmax_reduction_op(id), fxt, 0, vc_kind);
            nrc = tv_minmax_reduction(vu_minmax_reduction_op(id), xty, 0, vc_kind);
        }
        let old = vc_add(orc, ec);
        let nc = vc_add(nrc, if vc_has_one_use(inner) { 0 } else { ec });
        if nc > old { return false; }
    }
    let ty = ty_scalar(xty);
    let nr = vcb_intrinsic_rt(ty, id as i64, [x], 0, "");
    let ncmp = vcb_cmp(pred, nr, c_null(ty), "");
    vc_replace(i, ncmp, true);
    return true;
}
// m_NonZeroInt (poison elements allowed)
fn vc_m_nonzero_int(v: i32) -> bool {
    if v < 0 || !is_constant(v) { return false; }
    let k = vals[v].kind;
    if k == VK_CINT { let s = if ty_is_vector(vals[v].ty) { splat_value(v, false) } else { v }; return !ap_is_zero(ci_ap(s)); }
    if !ty_is_vector(vals[v].ty) { return false; }
    let s = splat_value(v, false);
    if s >= 0 { return vals[s].kind == VK_CINT && !ap_is_zero(ci_ap(s)); }
    if ty_kind(vals[v].ty) != TK_FVEC { return false; }
    var has = false;
    for e in ty_count(vals[v].ty) {
        let x = agg_elem(v, e);
        if x < 0 { return false; }
        if vals[x].kind == VK_POISON { continue; }
        if vals[x].kind != VK_CINT || ap_is_zero(ci_ap(x)) { return false; }
        has = true;
    }
    return has;
}

fn vc_fold_equivalent_reduction_cmp(i: i32) -> bool {
    if !is_inst_op(i, OP_ICMP) { return false; }
    let pred = inst_pred(i);
    let ii = op(i, 0);
    let cvc = m_apint(op(i, 1));
    if cvc < 0 { return false; }
    let cv = ci_ap(cvc);
    if !vc_is_intrinsic(ii) || !vc_has_one_use(ii) { return false; }
    let w = cv.w as i64;
    let is_eqp = pred == VC_EQ || pred == VC_NE;
    fn valid_or_umax(cv: AP, w: i64, pred: i64, is_eqp: bool) -> bool {
        if w == 1 { return true; }
        let eq = (ap_is_zero(cv) || ap_is_one(cv)) && is_eqp;
        let pos = ap_is_all_ones(cv) && pred == VC_SGT;
        let neg = (ap_is_zero(cv) || ap_is_one(cv) || ap_eq_u64(cv, 2)) && pred == VC_SLT;
        return eq || pos || neg;
    }
    fn valid_and_umin(cv: AP, w: i64, pred: i64, is_eqp: bool) -> bool {
        if w == 1 { return true; }
        let lo = ap_countl_one(cv);
        let eq = (ap_is_all_ones(cv) || lo + 1 == w) && is_eqp;
        let neg = ap_is_zero(cv) && pred == VC_SLT;
        let pos = lo + 2 >= w && (ap_get_bit(cv, 0) || ap_get_bit(cv, 1)) && pred == VC_SGT;
        return eq || neg || pos;
    }
    let oid = inst_iid(ii);
    var alt: i32 = 0;
    if oid == IID_vector_reduce_or { if !valid_or_umax(cv, w, pred, is_eqp) { return false; } alt = IID_vector_reduce_umax; }
    else if oid == IID_vector_reduce_umax { if !valid_or_umax(cv, w, pred, is_eqp) { return false; } alt = IID_vector_reduce_or; }
    else if oid == IID_vector_reduce_and { if !valid_and_umin(cv, w, pred, is_eqp) { return false; } alt = IID_vector_reduce_umin; }
    else if oid == IID_vector_reduce_umin { if !valid_and_umin(cv, w, pred, is_eqp) { return false; } alt = IID_vector_reduce_and; }
    else { return false; }
    let x = cb_arg(ii, 0);
    let vt = vals[x].ty as i32;
    if !vc_is_fixed_vec(vt) { return false; }
    fn red_cost(id: i32, vt: i32) -> i64 {
        let ro = vu_arith_reduction_instruction(id);
        if ro != OP_ICMP { return tv_arith_reduction(ro, vt, false, vc_kind); }
        return tv_minmax_reduction(vu_minmax_reduction_op(id), vt, 0, vc_kind);
    }
    let oc = red_cost(oid, vt);
    let ac = red_cost(alt, vt);
    if ac >= oc { return false; }
    vcb_set(i);
    let sty = ty_scalar(vt);
    let nr = vcb_intrinsic_rt(sty, alt as i64, [x], 0, "");
    let ncmp = vcb_cmp(pred, nr, c_int_ap(sty, cv), "");
    vc_replace(i, ncmp, true);
    return true;
}

// isKnownNonPositive(V, SQ, Depth) (the static helper of foldReduceAddCmpZero)
recursive fn vc_known_non_positive(v: i32, cx: i32, depth: i64) -> bool {
    if depth > 2 { return false; }
    vc_sq_at(cx);
    if num_sign_bits(v, 0) == tt_scalar_bits(vals[v].ty) { return true; }
    if is_inst_op(v, OP_ADD) {
        let a = op(v, 0);
        let b = op(v, 1);
        vc_sq_at(cx);
        if num_sign_bits(a, 0) < 2 { return false; }
        vc_sq_at(cx);
        if num_sign_bits(b, 0) < 2 { return false; }
        return vc_known_non_positive(a, cx, depth + 1) && vc_known_non_positive(b, cx, depth + 1);
    }
    vc_sq_at(cx);
    let k = kb_compute_all(v, 0);
    let smax = kb_smax(k);
    return ap_is_neg(smax) || ap_is_zero(smax);
}

fn vc_fold_reduce_add_cmp_zero(i: i32) -> bool {
    if !is_inst_op(i, OP_ICMP) { return false; }
    let pred = inst_pred(i);
    let r = op(i, 0);
    if !vc_has_one_use(r) || inst_iid(r) != IID_vector_reduce_add || !m_zero(op(i, 1)) { return false; }
    let vec = cb_arg(r, 0);
    let vt = vals[vec].ty as i32;
    if !vc_is_fixed_vec(vt) || ty_count(vt) < 2 { return false; }
    vc_sq_at(i);
    let nonneg = kb_is_nonneg(kb_compute_all(vec, 0));
    let nonpos = !nonneg && vc_known_non_positive(vec, i, 0);
    vc_sq_done();
    if !nonneg && !nonpos { return false; }
    let ne = ty_count(vt);
    vc_sq_at(i);
    let nsb = num_sign_bits(vec, 0);
    vc_sq_done();
    if vc_log2_floor(ne) >= nsb { return false; }
    var np: i64 = 0;
    if pred == VC_EQ || pred == VC_ULE || pred == VC_SLE || pred == VC_SGE { np = VC_EQ; }
    else if pred == VC_NE || pred == VC_UGT || pred == VC_SGT || pred == VC_SLT { np = VC_NE; }
    else { return false; }
    if !nonneg && (pred == VC_SGT || pred == VC_SLE) { return false; }
    if !nonpos && (pred == VC_SLT || pred == VC_SGE) { return false; }
    if (pred == VC_SGT || pred == VC_SLE || pred == VC_SLT || pred == VC_SGE) && vc_log2_floor(ne) >= nsb - 1 { return false; }
    let oc = tv_arith_reduction(OP_ADD, vt, false, vc_kind);
    let orc = tv_arith_reduction(OP_OR, vt, false, vc_kind);
    let uc = tv_minmax_reduction(IID_umax, vt, 0, vc_kind);
    if !tc_valid(orc) && !tc_valid(uc) { return false; }
    let use_or = tc_valid(orc) && (!tc_valid(uc) || orc <= uc);
    let alt = if use_or { orc } else { uc };
    if alt > oc { return false; }
    vcb_set(i);
    let nr = if use_or { vcb_intrinsic(IID_vector_reduce_or as i64, [vt], [vec], 0, "") } else { vcb_intrinsic(IID_vector_reduce_umax as i64, [vt], [vec], 0, "") };
    vcw_push_value(nr);
    let ncmp = vcb_cmp(np, nr, c_null(ty_scalar(vt)), "");
    vc_replace(i, ncmp, true);
    return true;
}

// ---------------------------------------------------------------- foldSelectShuffle

// feedsIntoVectorReduction(SVI)
fn vc_feeds_into_vector_reduction(svi: i32) -> bool {
    vs_clear(VS_PASS0);
    var nvis: i64 = 0;
    var wl: i32[>..<] = [];
    var found = false;
    wl.push(svi);
    while wl.len > 0 {
        let i = wl.pop();
        var u = vals[i].first_use;
        while u >= 0 {
            let ui = uses[u].user;
            u = uses[u].next;
            if !vs_add(VS_PASS0, ui) { continue; }
            nvis++;
            if nvis > 32 { return false; }
            if vc_is_intrinsic(ui) {
                if found { return false; }
                if vc_is_int_reduce(inst_iid(ui)) { found = true; continue; }
                return false;
            }
            if !vc_is_binop(ui) && !vc_is_shuffle(ui) { return false; }
            wl.push(ui);
        }
    }
    return found;
}

// quarter-unit costs (InstructionCost's fixed point, CostGranularity 4)
fn vcq(c: i64) -> i64 { if tc_valid(c) { c * 4 } else { TTI_INVALID } }

// the state of one foldSelectShuffle
var vss_vt: i32 = -1;
var vss_maxe: i64 = 0;
var vss_uniq: i32[>..<];      // UniqueShuffles: groups of vss_maxe mask elements
var vss_in: i32[>..<];        // InputShuffles (SmallPtrSet, small mode: insertion order)

fn vss_unique_insert(m: const i32[:]) -> bool {
    let g = m.len;
    var k: i64 = 0;
    while k < vss_uniq.len {
        var eq = true;
        for j in g { if vss_uniq[k + j] != m[j] { eq = false; break; } }
        if eq { return false; }
        k += g;
    }
    for x in m { vss_uniq.push(x); }
    return true;
}
// AddShuffleMaskAdjustedCost (quarters)
fn vss_mask_adjusted(mask: const i32[:]) -> i64 {
    let sc = tv_shuffle_simple(SK_PERMUTETWOSRC, vss_vt, vss_vt, mask, vc_kind);
    let nfull = mask.len / vss_maxe;
    if nfull < 2 { return vcq(sc); }
    var nuniq: i64 = 0;
    let ngroups = mask.len / vss_maxe;
    for k in nfull {
        var sub: i32[>..<] = [];
        for j in vss_maxe { sub.push(mask[vss_maxe * k + j]); }
        if vss_unique_insert(sub) { nuniq++; }
    }
    if !tc_valid(sc) { return TTI_INVALID; }
    return (sc * 4 * nuniq * 4) / (ngroups * 4);
}
// AddShuffleCost (quarters)
fn vss_shuffle_cost(i: i32) -> i64 {
    if i < 0 || !vc_is_shuffle(i) { return 0; }
    var m: i32[>..<] = [];
    vc_mask(i, m);
    let sk = if is_undef_or_poison(op(i, 1)) { SK_PERMUTESINGLESRC } else { SK_PERMUTETWOSRC };
    return vcq(tv_shuffle_simple(sk, vss_vt, vss_vt, m, vc_kind));
}
// AddShuffleAdjustedCost (quarters)
fn vss_shuffle_adjusted(i: i32) -> i64 {
    if i < 0 || !vc_is_shuffle(i) { return 0; }
    var m: i32[>..<] = [];
    vc_mask(i, m);
    return vss_mask_adjusted(m);
}
fn vss_in_contains(v: i32) -> bool { for x in vss_in { if x == v { return true; } } return false; }
// GetBaseMaskValue(I, M)
fn vss_base_mask_value(i: i32, m: i64) -> i64 {
    if !vc_is_shuffle(i) { return m; }
    if is_undef_or_poison(op(i, 1)) {
        let ssv = op(i, 0);
        if vc_is_shuffle(ssv) && vss_in_contains(ssv) {
            let x = vc_mask_at(i, m) as i64;
            if x < 0 { fatal("VectorCombine: foldSelectShuffle reads a mask element at index -1 (undefined in LLVM)"); }
            return vc_mask_at(ssv, x) as i64;
        }
    }
    return vc_mask_at(i, m) as i64;
}
// GetShuffleOperand(I, Op)
fn vss_shuffle_operand(i: i32, k: i64) -> i32 {
    if !vc_is_shuffle(i) { return i; }
    if is_undef_or_poison(op(i, 1)) {
        let ssv = op(i, 0);
        if vc_is_shuffle(ssv) && vss_in_contains(ssv) { return op(ssv, k); }
    }
    return op(i, k);
}
// SetInsertPoint(*I->getInsertionPointAfterDef())
fn vss_set_after_def(i: i32) {
    let o = iop(i);
    if o == OP_PHI {
        var x = block_first(inst_parent(i));
        while x >= 0 && (iop(x) == OP_PHI || inst_is_eh_pad(x)) { x = inst_next(x); }
        vcb_set_it(x, true);
        return;
    }
    if o == OP_INVOKE || o == OP_CALLBR { vc_not_ported("foldSelectShuffle after an invoke/callbr"); }
    vcb_set_it(inst_next(i), true);
}

fn vc_fold_select_shuffle(i: i32, from_red: bool) -> bool {
    let vt = vals[i].ty as i32;
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    if !is_inst(op0) || !is_inst(op1) || op0 == op1 || !vc_is_binop(op0) || !vc_is_binop(op1) || vt != vals[op0].ty { return false; }
    let a0 = if is_inst(op(op0, 0)) { op(op0, 0) } else { -1 };
    let b0 = if is_inst(op(op0, 1)) { op(op0, 1) } else { -1 };
    let a1 = if is_inst(op(op1, 0)) { op(op1, 0) } else { -1 };
    let b1 = if is_inst(op(op1, 1)) { op(op1, 1) } else { -1 };
    vss_in.clear();
    for x in [a0, b0, a1, b1] { if !vss_in_contains(x) { vss_in.push(x); } }
    fn non_op_uses(x: i32, vt: i32, op0: i32, op1: i32) -> bool {
        if x < 0 || vals[op(x, 0)].ty != vt { return true; }
        var u = vals[x].first_use;
        while u >= 0 {
            let us = uses[u].user;
            u = uses[u].next;
            if us != op0 && us != op1 && !(vc_is_shuffle(us) && (vss_in_contains(us) || is_instruction_trivially_dead(us))) { return true; }
        }
        return false;
    }
    if non_op_uses(a0, vt, op0, op1) || non_op_uses(b0, vt, op0, op1) || non_op_uses(a1, vt, op0, op1) || non_op_uses(b1, vt, op0, op1) { return false; }
    var shuffles: i32[>..<] = [];
    fn collect(x: i32, vt: i32, op0: i32, op1: i32, shuffles: i32[>..<]&) -> bool {
        var u = vals[x].first_use;
        while u >= 0 {
            let us = uses[u].user;
            u = uses[u].next;
            if !vc_is_shuffle(us) || vals[us].ty != vt { return false; }
            if (op(us, 0) != op0 && op(us, 0) != op1) || (op(us, 1) != op0 && op(us, 1) != op1) { return false; }
            var c = false;
            for s in shuffles { if s == us { c = true; } }
            if !c { shuffles.push(us); }
        }
        return true;
    }
    if !collect(op0, vt, op0, op1, shuffles) || !collect(op1, vt, op0, op1, shuffles) { return false; }
    if from_red && shuffles.len > 1 { return false; }
    if !from_red {
        let e = shuffles.len;
        for idx in e {
            var u = vals[shuffles[idx]].first_use;
            while u >= 0 {
                let us = uses[u].user;
                u = uses[u].next;
                if vc_is_shuffle(us) && is_undef_or_poison(op(us, 1)) && vals[us].ty == vt { shuffles.push(us); }
            }
        }
    }
    var v1f: i32[>..<] = [];
    var v1s: i32[>..<] = [];
    var v2f: i32[>..<] = [];
    var v2s: i32[>..<] = [];
    var orm: i32[>..<] = [];     // OrigReconstructMasks, each NumElts... of the shuffle's mask length
    var orm_at: i64[>..<] = [];
    var orm_n: i64[>..<] = [];
    var maxv1: i64 = 0;
    var maxv2: i64 = 0;
    let ne = ty_count(vt);
    for svn in shuffles {
        var mask: i32[>..<] = [];
        vc_mask(svn, mask);
        var sv0 = op(svn, 0);
        var sv1 = op(svn, 1);
        if is_undef_or_poison(sv1) {
            let ssv = sv0;
            sv0 = op(ssv, 0);
            sv1 = op(ssv, 1);
            for k in mask.len {
                if mask[k] as i64 >= vc_mask_len(ssv) { return false; }
                mask[k] = if mask[k] < 0 { mask[k] } else { vc_mask_at(ssv, mask[k] as i64) };
            }
        }
        if sv0 == op1 && sv1 == op0 {
            let t = sv0; sv0 = sv1; sv1 = t;
            vc_commute_mask(mask, ne);
        }
        if sv0 != op0 || sv1 != op1 { return false; }
        let at = orm.len;
        for k in mask.len {
            let m = mask[k] as i64;
            if m < 0 {
                orm.push(-1);
            } else if m < ne {
                if m > maxv1 { maxv1 = m; }
                var f: i64 = -1;
                for j in v1f.len { if v1f[j] as i64 == m { f = j; break; } }
                if f >= 0 { orm.push(f as i32); }
                else { orm.push(v1f.len as i32); v1s.push(v1f.len as i32); v1f.push(m as i32); }
            } else {
                if m - ne > maxv2 { maxv2 = m - ne; }
                var f: i64 = -1;
                for j in v2f.len { if v2f[j] as i64 == m - ne { f = j; break; } }
                if f >= 0 { orm.push((ne + f) as i32); }
                else { orm.push((ne + v2f.len) as i32); v2s.push((ne + v2f.len) as i32); v2f.push((m - ne) as i32); }
            }
        }
        if from_red {
            var tmp: i32[>..<] = [];
            for k in mask.len { tmp.push(orm[at + k]); }
            sort(tmp) { a, b => a < b };
            for k in mask.len { orm[at + k] = tmp[k]; }
        }
        orm_at.push(at);
        orm_n.push(mask.len);
    }
    if v1f.len == 0 || v2f.len == 0 || (maxv1 == v1f.len - 1 && maxv2 == v2f.len - 1) { return false; }
    if a0 < 0 || b0 < 0 || a1 < 0 || b1 < 0 { fatal("VectorCombine: foldSelectShuffle with a non-instruction binop operand (a null dereference in LLVM)"); }
    // stable_sort(V1/V2) by the base mask value of SVI0A / SVI1A (insertion sort is stable)
    fn ssort(f: i32[>..<]&, s: i32[>..<]&, base: i32) {
        for k in 1..f.len {
            var j = k;
            while j > 0 && vss_base_mask_value(base, f[j] as i64) < vss_base_mask_value(base, f[j - 1] as i64) {
                let t = f[j]; f[j] = f[j - 1]; f[j - 1] = t;
                let t2 = s[j]; s[j] = s[j - 1]; s[j - 1] = t2;
                j--;
            }
        }
    }
    ssort(v1f, v1s, a0);
    ssort(v2f, v2s, a1);
    var rm: i32[>..<] = [];
    for k in orm.len {
        let m = orm[k] as i64;
        if m < 0 { rm.push(-1); }
        else if m < ne {
            var f: i64 = -1;
            for j in v1s.len { if v1s[j] as i64 == m { f = j; break; } }
            rm.push(f as i32);
        } else {
            var f: i64 = -1;
            for j in v2s.len { if v2s[j] as i64 == m { f = j; break; } }
            rm.push((ne + f) as i32);
        }
    }
    var v1a: i32[>..<] = [];
    var v1b: i32[>..<] = [];
    var v2a: i32[>..<] = [];
    var v2b: i32[>..<] = [];
    for k in v1f.len {
        v1a.push(vss_base_mask_value(a0, v1f[k] as i64) as i32);
        v1b.push(vss_base_mask_value(b0, v1f[k] as i64) as i32);
    }
    for k in v2f.len {
        v2a.push(vss_base_mask_value(a1, v2f[k] as i64) as i32);
        v2b.push(vss_base_mask_value(b1, v2f[k] as i64) as i32);
    }
    while v1a.len < ne { v1a.push(-1); v1b.push(-1); }
    while v2a.len < ne { v2a.push(-1); v2b.push(-1); }
    vss_vt = vt;
    let esz = tt_prim_bits(ty_elem(vt));
    let maxvs = tv_register_bit_width(1);
    vss_maxe = maxvs / esz;
    if vss_maxe == 0 { return false; }
    // AllShufflesHaveSameOperands(InputShuffles)
    var same_ops = false;
    if vss_in.len >= 2 && vss_in[0] >= 0 && vc_is_shuffle(vss_in[0]) {
        let in0 = op(vss_in[0], 0);
        let in1 = op(vss_in[0], 1);
        same_ops = true;
        for k in 1..vss_in.len {
            let x = vss_in[k];
            if !(x >= 0 && vc_is_shuffle(x) && op(x, 0) == in0 && op(x, 1) == in1) { same_ops = false; }
        }
    }
    var before = vcq(vc_add(tv_arith0(iop(op0), vt, vc_kind), tv_arith0(iop(op1), vt, vc_kind)));
    for s in shuffles { before = tc_add(before, vss_shuffle_cost(s)); }
    if same_ops {
        vss_uniq.clear();
        for x in vss_in { before = tc_add(before, vss_shuffle_adjusted(x)); }
    } else {
        for x in vss_in { before = tc_add(before, vss_shuffle_cost(x)); }
    }
    let sm0 = ty_vector(ty_scalar(vt), v1f.len, false);
    let sm1 = ty_vector(ty_scalar(vt), v2f.len, false);
    var after = vcq(vc_add(tv_arith0(iop(op0), sm0, vc_kind), tv_arith0(iop(op1), sm1, vc_kind)));
    vss_uniq.clear();
    for k in orm_at.len {
        var m: i32[>..<] = [];
        for j in orm_n[k] { m.push(rm[orm_at[k] + j]); }
        after = tc_add(after, vss_mask_adjusted(m));
    }
    // std::set<SmallVector<int>> OutputShuffleMasks({V1A, V1B, V2A, V2B}): duplicates counted once
    after = tc_add(after, vcq(tv_shuffle_simple(SK_PERMUTETWOSRC, vt, vt, v1a, vc_kind)));
    if !vc_masks_equal(v1b, v1a) { after = tc_add(after, vcq(tv_shuffle_simple(SK_PERMUTETWOSRC, vt, vt, v1b, vc_kind))); }
    if !vc_masks_equal(v2a, v1a) && !vc_masks_equal(v2a, v1b) { after = tc_add(after, vcq(tv_shuffle_simple(SK_PERMUTETWOSRC, vt, vt, v2a, vc_kind))); }
    if !vc_masks_equal(v2b, v1a) && !vc_masks_equal(v2b, v1b) && !vc_masks_equal(v2b, v2a) {
        after = tc_add(after, vcq(tv_shuffle_simple(SK_PERMUTETWOSRC, vt, vt, v2b, vc_kind)));
    }
    if before < after || (before == after && !vc_feeds_into_vector_reduction(i)) { return false; }
    vss_set_after_def(a0);
    let n0a = vcb_shuffle(vss_shuffle_operand(a0, 0), vss_shuffle_operand(a0, 1), v1a, "");
    vss_set_after_def(b0);
    let n0b = vcb_shuffle(vss_shuffle_operand(b0, 0), vss_shuffle_operand(b0, 1), v1b, "");
    vss_set_after_def(a1);
    let n1a = vcb_shuffle(vss_shuffle_operand(a1, 0), vss_shuffle_operand(a1, 1), v2a, "");
    vss_set_after_def(b1);
    let n1b = vcb_shuffle(vss_shuffle_operand(b1, 0), vss_shuffle_operand(b1, 1), v2b, "");
    vcb_set(op0);
    let nop0 = vcb_binop(iop(op0), n0a, n0b, "", 0);
    if is_inst(nop0) { vu_copy_ir_flags(nop0, op0, true); }
    vcb_set(op1);
    let nop1 = vcb_binop(iop(op1), n1a, n1b, "", 0);
    if is_inst(nop1) { vu_copy_ir_flags(nop1, op1, true); }
    for s in shuffles.len {
        vcb_set(shuffles[s]);
        var m: i32[>..<] = [];
        for j in orm_n[s] { m.push(rm[orm_at[s] + j]); }
        let nsv = vcb_shuffle(nop0, nop1, m, "");
        vc_replace(shuffles[s], nsv, false);
    }
    vcw_push_value(n0a);
    vcw_push_value(n0b);
    vcw_push_value(n1a);
    vcw_push_value(n1b);
    return true;
}

// ---------------------------------------------------------------- shrinkType

// computeKnownBits(V, DL): no context, DT or AC
fn vc_kb_dl(v: i32) -> KB {
    kb_cxt = -1;
    sq_no_dt = true;
    sq_no_ac = true;
    sq_no_tli = true;
    dc_active = false;
    let k = kb_compute_all(v, 0);
    sq_no_dt = false;
    sq_no_ac = false;
    sq_no_tli = false;
    return k;
}

fn vc_shrink_type(i: i32) -> bool {
    var zexted: i32 = -1;
    var other: i32 = -1;
    let o = iop(i);
    if o == OP_AND || o == OP_OR || o == OP_XOR {
        if is_inst_op(op(i, 0), OP_ZEXT) { zexted = op(op(i, 0), 0); other = op(i, 1); }
        else if is_inst_op(op(i, 1), OP_ZEXT) { zexted = op(op(i, 1), 0); other = op(i, 0); }
        else { return false; }
    } else if o == OP_LSHR && is_inst_op(op(i, 0), OP_ZEXT) {
        zexted = op(op(i, 0), 0);
        other = op(i, 1);
    } else {
        return false;
    }
    let zop = op(i, if op(i, 0) == other { 1 } else { 0 });
    let big = vals[i].ty as i32;
    let small = vals[zexted].ty as i32;
    let bw = tt_prim_bits(ty_elem(small));
    if o == OP_LSHR {
        let k = vc_kb_dl(op(i, 1));
        if ap_uge_u64(kb_max(k), bw as u64) { return false; }
    } else {
        let k = vc_kb_dl(i);
        if kb_max_active_bits(k) > bw { return false; }
    }
    let zc = tv_cast(OP_ZEXT, big, small, 0, vc_kind, -1);
    var cur = zc;
    var shr: i64 = 0;
    var u = vals[zop].first_use;
    while u >= 0 {
        let ui = uses[u].user;
        u = uses[u].next;
        if ui == i {
            cur = vc_add(cur, tv_arith0(iop(ui), big, vc_kind));
            shr = vc_add(shr, tv_arith0(iop(ui), small, vc_kind));
            shr = vc_add(shr, zc);
            continue;
        }
        if !is_binary_op(iop(ui)) { return false; }
        let k = vc_kb_dl(ui);
        if kb_max_active_bits(k) > bw { return false; }
        cur = vc_add(cur, tv_arith0(iop(ui), big, vc_kind));
        shr = vc_add(shr, tv_arith0(iop(ui), small, vc_kind));
        shr = vc_add(shr, zc);
    }
    if !is_constant(other) { shr = vc_add(shr, tv_cast(OP_TRUNC, small, big, 0, vc_kind, -1)); }
    if shr > cur { return false; }
    vcb_set(i);
    var o0 = zexted;
    var o1 = vcb_cast(OP_TRUNC, other, small, "");
    if op(i, 0) == other { let t = o0; o0 = o1; o1 = t; }
    let nb = vcb_binop(o, o0, o1, "", 0);
    if !is_inst(nb) { fatal("VectorCombine: shrinkType's new binop folded (cast<Instruction> fails in LLVM)"); }
    vu_copy_ir_flags(nb, i, true);
    vc_copy_metadata(nb, i);
    let nz = vcb_cast(OP_ZEXT, nb, big, "");
    vc_replace(i, nz, true);
    return true;
}

// ---------------------------------------------------------------- foldInsExtVectorToShuffle

fn vc_fold_ins_ext_vector_to_shuffle(i: i32) -> bool {
    let ok, dst0, e, insidx = vc_m_ins_c(i);
    if !ok { return false; }
    let oke, src0, extidx = vc_m_ext_c(e);
    if !oke { return false; }
    var dst = dst0;
    var src = src0;
    let dvt = vals[i].ty as i32;
    let svt = vals[src].ty as i32;
    if !vc_is_fixed_vec(dvt) || !vc_is_fixed_vec(svt) || ty_elem(svt) != ty_elem(dvt) { return false; }
    let nd = ty_count(dvt);
    let ns = ty_count(svt);
    if insidx >= nd as u64 || extidx >= ns as u64 || nd == 1 { return false; }
    let ins = insidx as i64;
    let ext = extidx as i64;
    var sk = SK_PERMUTETWOSRC;
    var mask: i32[>..<] = [];
    for k in nd { mask.push(-1); }
    let need_exp = ns != nd;
    let need_swap = is_poison(dst) && !is_undef_or_poison(src);
    if need_swap {
        sk = SK_PERMUTESINGLESRC;
        mask[ins] = (ext % nd) as i32;
        let t = dst; dst = src; src = t;
    } else {
        for k in nd { mask[k] = k as i32; }
        mask[ins] = ((ext % nd) + nd) as i32;
    }
    let insc = tv_vec_inst_i(i, dvt, ins, vc_kind);
    let extc = tv_vec_inst_i(e, dvt, ext, vc_kind);
    let old = vc_add(extc, insc);
    var nc: i64 = 0;
    var etv: i32[>..<] = [];
    if !need_exp {
        if !vc_is_identity_mask(mask, ns) { nc = vc_add(nc, tv_shuffle(sk, dvt, dvt, mask, vc_kind, 0, -1, dst, src, 2, -1)); }
    } else {
        for k in nd { etv.push(-1); }
        etv[ext % nd] = ext as i32;
        nc = tv_shuffle_simple(SK_PERMUTESINGLESRC, dvt, svt, etv, vc_kind);
        nc = vc_add(nc, tv_shuffle_simple(sk, dvt, dvt, mask, vc_kind));
    }
    if !vc_has_one_use(e) { nc = vc_add(nc, extc); }
    if old < nc { return false; }
    if need_exp {
        if !need_swap { src = vcb_shuffle1(src, etv, ""); } else { dst = vcb_shuffle1(dst, etv, ""); }
    }
    if is_undef_or_poison(dst) && !is_undef_or_poison(src) {
        vc_commute_mask(mask, nd);
        let t = dst; dst = src; src = t;
    }
    let s = vcb_shuffle(dst, src, mask, "");
    vc_replace(i, s, true);
    return true;
}

// ---------------------------------------------------------------- interleave / deinterleave / VP / bit order

fn vc_fold_interleave_intrinsics(i: i32) -> bool {
    if inst_iid(i) != IID_vector_interleave2 { return false; }
    let s0 = m_apint(cb_arg(i, 0));
    let s1 = m_apint(cb_arg(i, 1));
    if s0 < 0 || s1 < 0 { return false; }
    let vty = vals[cb_arg(i, 0)].ty as i32;
    let w = ty_bits(ty_elem(vty));
    let ext = ty_vector(ty_int(w * 2), ty_count(vty), ty_kind(vty) == TK_SVEC);
    if tv_inst_cost(i, vc_kind) <= tv_cast(OP_BITCAST, vals[i].ty, ext, 0, vc_kind, -1) { return false; }
    var nv = ap_shl(ap_zext(ci_ap(s1), w * 2), w);
    nv = ap_or(nv, ap_zext(ci_ap(s0), w * 2));
    let ns = c_splat(ext, c_int_ap(ty_int(w * 2), nv));
    vcb_local(i);
    vc_replace(i, vcb_cast(OP_BITCAST, ns, vals[i].ty, ""), true);
    return true;
}

fn vc_fold_deinterleave_intrinsics(i: i32) -> bool {
    if dl_big_endian { return false; }
    if inst_iid(i) != IID_vector_deinterleave2 { return false; }
    let dv = cb_arg(i, 0);
    let vt = vals[dv].ty as i32;
    let et = ty_elem(vt);
    if !ty_is_int(et) { return false; }
    let ew = ty_bits(et);
    if ew < 2 || (ew & (ew - 1)) != 0 { return false; }
    let half = ew / 2;
    if vc_num_uses(i) != 2 { return false; }
    var f0: i32 = -1;
    var f1: i32 = -1;
    var u = vals[i].first_use;
    while u >= 0 {
        let e = uses[u].user;
        u = uses[u].next;
        if !is_inst_op(e, OP_EXTRACTVALUE) || insts[inst_of(e)].naux != 1 { return false; }
        let idx = ints[insts[inst_of(e)].aux];
        if idx >= 2 || (if idx == 0 { f0 } else { f1 }) >= 0 || vc_num_uses(e) != 2 { return false; }
        if idx == 0 { f0 = e; } else { f1 = e; }
    }
    var merges: i32[>..<] = [];
    u = vals[f0].first_use;
    while u >= 0 {
        let fu = uses[u].user;
        u = uses[u].next;
        if !vc_has_one_use(fu) || !is_inst(vc_user_back(fu)) { return false; }
        merges.push(vc_user_back(fu));
    }
    let lo = ap_low_bits(ew, half);
    let hi = ap_shl(ap_low_bits(ew, half), half);
    fn mm(x: i32, a: i32, m: AP, sho: i64, b: i32, half: i64) -> bool {
        if !is_inst_op(x, OP_OR) { return false; }
        for k in 2 {
            let p = op(x, k);
            let q = op(x, 1 - k);
            if is_inst_op(p, OP_AND) && op(p, 0) == a && m_specific_int_apv(op(p, 1), m) &&
               is_inst_op(q, sho) && op(q, 0) == b && m_specific_int(op(q, 1), half as u64) { return true; }
        }
        return false;
    }
    fn match_merge(m0: i32, m1: i32, f0: i32, f1: i32, lo: AP, hi: AP, half: i64) -> bool {
        return mm(m0, f0, lo, OP_SHL, f1, half) && mm(m1, f1, hi, OP_LSHR, f0, half);
    }
    if !match_merge(merges[0], merges[1], f0, f1, lo, hi, half) {
        let t = merges[0]; merges[0] = merges[1]; merges[1] = t;
        if !match_merge(merges[0], merges[1], f0, f1, lo, hi, half) { return false; }
    }
    var old = vc_add(vc_add(tv_inst_cost(merges[0], vc_kind), tv_inst_cost(op(merges[0], 0), vc_kind)), tv_inst_cost(op(merges[0], 1), vc_kind));
    old = tc_mul(old, 2);
    let nft = ty_vector(ty_int(half), ty_count(vt), ty_kind(vt) == TK_SVEC);
    let nvt = ty_vector(ty_int(half), ty_count(vt) * 2, ty_kind(vt) == TK_SVEC);
    let nc = vc_add(tv_cast(OP_BITCAST, vt, nvt, 0, vc_kind, -1), tc_mul(tv_cast(OP_BITCAST, nft, vals[merges[0]].ty, 0, vc_kind, -1), 2));
    if old <= nc || !tc_valid(nc) { return false; }
    vcb_local(i);
    let nvc = vcb_cast(OP_BITCAST, dv, nvt, "");
    let nd = vcb_intrinsic(IID_vector_deinterleave2 as i64, [nvt], [nvc], 0, "");
    for k in 2 {
        var nf = vcb_extract_value(nd, k, "");
        nf = vcb_cast(OP_BITCAST, nf, vals[merges[k]].ty, "");
        vc_replace(merges[k], nf, true);
    }
    return true;
}

// foldBitcastOfVPLoad: VP loads are not ported (fail loudly when the pattern is seen)
fn vc_fold_bitcast_of_vp_load(i: i32) -> bool {
    if !vc_is_cast(i) || !ty_is_vector(vals[i].ty) { return false; }
    let x = op(i, 0);
    if vc_is_intrinsic(x) && inst_iid(x) == IID_vp_load { vc_not_ported("foldBitcastOfVPLoad (VP loads)"); }
    return false;
}

fn vc_fold_bit_order_reverse_and_swap(i: i32) -> bool {
    let id = inst_iid(i);
    var x: i32 = -1;
    var inner: i32 = -1;
    if id == IID_bitreverse && inst_iid(cb_arg(i, 0)) == IID_bswap { inner = cb_arg(i, 0); x = cb_arg(inner, 0); }
    else if id == IID_bswap && inst_iid(cb_arg(i, 0)) == IID_bitreverse { inner = cb_arg(i, 0); x = cb_arg(inner, 0); }
    else { return false; }
    let ty = vals[i].ty as i32;
    let es = dl_store_size(ty);
    let nvt = ty_vector(T_I8, es, ty_kind(ty) == TK_SVEC);
    let old = vc_add(tv_inst_cost(i, vc_kind), tv_inst_cost(inner, vc_kind));
    let c1 = tv_cast(OP_BITCAST, nvt, ty, 0, vc_kind, -1);
    let c2 = tv_cast(OP_BITCAST, ty, nvt, 0, vc_kind, -1);
    let ic = tv_intrinsic_types(IID_bitreverse, nvt, [nvt], 0, vc_kind);
    var nc = vc_add(vc_add(c1, ic), c2);
    if !vc_has_one_use(inner) { nc = vc_add(nc, tv_inst_cost(inner, vc_kind)); }
    if !tc_valid(nc) || nc >= old { return false; }
    vcb_set(i);
    let cv = vcb_cast(OP_BITCAST, x, nvt, "");
    let nci = vcb_unary_intrinsic(IID_bitreverse as i64, cv, 0, "");
    let co = vcb_cast(OP_BITCAST, nci, ty, "");
    vc_replace(i, co, true);
    return true;
}

// ---------------------------------------------------------------- shrinking loads and phis

fn vc_shrink_load_for_shuffles(i: i32) -> bool {
    if !is_inst_op(i, OP_LOAD) || !ld_is_simple(i) { return false; }
    let olt = vals[i].ty as i32;
    if !vc_is_fixed_vec(olt) { return false; }
    let one = ty_count(olt);
    var lo = one;
    var hi: i64 = -1;
    var u = vals[i].first_use;
    while u >= 0 {
        let s = uses[u].user;
        u = uses[u].next;
        if !vc_is_shuffle(s) || op(s, 0) != i || !m_undef(op(s, 1)) { return false; }
        if vals[s].first_use < 0 { continue; }
        for k in vc_mask_len(s) {
            let x = vc_mask_at(s, k) as i64;
            if x >= 0 && x < one {
                if x < lo { lo = x; }
                if x > hi { hi = x; }
            }
        }
    }
    if hi < lo { return false; }
    let nne = hi + 1;
    if nne >= one { return false; }
    let et = ty_elem(olt);
    let nlt = ty_vector(et, nne, false);
    let ptr = op(i, 0);
    let as_ = ptr_as(vals[ptr].ty);
    var old = tv_mem(OP_LOAD, olt, vc_align_of(i), as_, vc_kind);
    var nc = tv_mem(OP_LOAD, nlt, vc_align_of(i), as_, vc_kind);
    var nu: i32[>..<] = [];
    let maxi = nne * 2;
    u = vals[i].first_use;
    while u >= 0 {
        let s = uses[u].user;
        u = uses[u].next;
        if vals[s].first_use < 0 { continue; }
        nu.push(s);
        var m: i32[>..<] = [];
        vc_mask(s, m);
        for x in m { if x as i64 >= maxi { return false; } }
        old = vc_add(old, tv_shuffle_simple(SK_PERMUTESINGLESRC, vals[s].ty, olt, m, vc_kind));
        nc = vc_add(nc, tv_shuffle_simple(SK_PERMUTESINGLESRC, vals[s].ty, nlt, m, vc_kind));
    }
    if old < nc || !tc_valid(nc) { return false; }
    vcb_local(i);
    let nl = vcb_load(nlt, ptr, vc_align_of(i), "");
    vc_copy_metadata(nl, i);
    for s in nu {
        vcb_set(s);
        var m: i32[>..<] = [];
        vc_mask(s, m);
        let ns = vcb_shuffle(nl, c_poison(nlt), m, "");
        vc_replace(s, ns, false);
    }
    return true;
}

fn vc_shrink_phi_of_shuffles(i: i32) -> bool {
    if !is_inst_op(i, OP_PHI) || phi_nincoming(i) != 2 { return false; }
    let s0 = op(i, 0);
    let s1 = op(i, 1);
    if !vc_has_one_use(s0) || !vc_is_shuffle(s0) || !is_poison(op(s0, 1)) { return false; }
    let x = op(s0, 0);
    if !vc_has_one_use(s1) || !vc_is_shuffle(s1) || op(s1, 0) != x || !is_poison(op(s1, 1)) { return false; }
    var m0: i32[>..<] = [];
    var m1: i32[>..<] = [];
    vc_mask(s0, m0);
    vc_mask(s1, m1);
    let ivt = vals[x].ty as i32;
    let rvt = vals[s0].ty as i32;
    let nin = ty_count(ivt);
    if nin >= ty_count(rvt) { return false; }
    var nm: i32[>..<] = [];
    let zl = if m0.len < m1.len { m0.len } else { m1.len };
    for k in zl {
        if m0[k] >= 0 && m1[k] >= 0 { nm.push(m0[k] - m1[k]); }
        else if m0[k] == -1 && m1[k] == -1 { continue; }
        else { return false; }
    }
    if nm.len == 0 { return false; }
    for v in nm { if v != nm[0] { return false; } }
    let off = nm[0] as i64;
    var index = (nin + off) % nin;
    nm.clear();
    for k in nin { nm.push(index as i32); index = (index + 1) % nin; }
    let sk = SK_PERMUTESINGLESRC;
    let a = tv_shuffle_simple(sk, rvt, ivt, m0, vc_kind);
    let b = tv_shuffle_simple(sk, rvt, ivt, m1, vc_kind);
    let old = if a > b { a } else { b };
    let nc = vc_add(tv_shuffle_simple(sk, ivt, ivt, nm, vc_kind), tv_shuffle_simple(sk, rvt, ivt, m1, vc_kind));
    if nc > old { return false; }
    vcb_local(s0);
    let ns0 = vcb_shuffle(x, c_poison(ivt), nm, "");
    if !is_inst(ns0) { fatal("VectorCombine: shrinkPhiOfShuffles: the new shuffle folded (cast<Instruction> fails in LLVM)"); }
    vcw_push(ns0);
    vcb_set(i);
    let np = vcb_phi(vals[ns0].ty, "");
    phi_add_incoming(np, ns0, phi_block(i, 0));
    phi_add_incoming(np, x, phi_block(i, 1));
    vss_set_after_def(np);
    let ns1 = vcb_shuffle(np, c_poison(vals[np].ty), m1, "");
    vc_replace(i, ns1, true);
    return true;
}

// ---------------------------------------------------------------- the driver

// FoldInst(I)
fn vc_fold_inst(i: i32) -> bool {
    vcb_cf = false;
    vcb_set(i);
    let ty = vals[i].ty as i32;
    let isvec = ty_is_vector(ty);
    let isfix = ty_kind(ty) == TK_FVEC;
    let o = iop(i);
    if isfix {
        if o == OP_INSERTELEMENT { if vc_vectorize_load_insert(i) { return true; } }
        else if o == OP_SHUFFLEVECTOR { if vc_widen_subvector_load(i) { return true; } }
    }
    if isvec {
        if vc_scalarize_op_or_cmp(i) { return true; }
        vcb_cf = false;
        if vc_scalarize_load(i) { return true; }
        if vc_scalarize_ext_extract(i) { return true; }
        if vc_scalarize_vp_intrinsic(i) { return true; }
        if vc_fold_interleave_intrinsics(i) { return true; }
        if vc_fold_bitcast_of_vp_load(i) { return true; }
    }
    if vc_fold_deinterleave_intrinsics(i) { return true; }
    if o == OP_STORE { if vc_fold_single_element_store(i) { return true; } }
    if vc_early_only { return false; }
    if o == OP_CALL { if vc_fold_bit_order_reverse_and_swap(i) { return true; } }
    if isfix {
        if o == OP_INSERTELEMENT {
            if vc_fold_ins_ext_fneg(i) { return true; }
            if vc_fold_ins_ext_binop(i) { return true; }
            if vc_fold_ins_ext_vector_to_shuffle(i) { return true; }
        } else if o == OP_SHUFFLEVECTOR {
            if vc_fold_permute_of_binops(i) { return true; }
            if vc_fold_shuffle_of_binops(i) { return true; }
            if vc_fold_shuffle_of_selects(i) { return true; }
            if vc_fold_shuffle_of_castops(i) { return true; }
            if vc_fold_shuffle_of_shuffles(i) { return true; }
            if vc_fold_permute_of_intrinsic(i) { return true; }
            if vc_fold_shuffles_of_length_changing_shuffles(i) { return true; }
            if vc_fold_shuffle_of_intrinsics(i) { return true; }
            if vc_fold_select_shuffle(i, false) { return true; }
            if vc_fold_shuffle_to_identity(i) { return true; }
        } else if o == OP_LOAD {
            if vc_shrink_load_for_shuffles(i) { return true; }
        } else if o == OP_BITCAST {
            if vc_fold_bitcast_shuffle(i) { return true; }
            if vc_fold_selects_from_bitcast(i) { return true; }
        } else if o == OP_AND || o == OP_OR || o == OP_XOR {
            if vc_fold_bitop_of_castops(i) { return true; }
            if vc_fold_bitop_of_cast_constant(i) { return true; }
        } else if o == OP_PHI {
            if vc_shrink_phi_of_shuffles(i) { return true; }
        } else {
            if vc_shrink_type(i) { return true; }
        }
    } else {
        if o == OP_CALL {
            if vc_fold_shuffle_from_reductions(i) { return true; }
            if vc_fold_cast_from_reductions(i) { return true; }
        } else if o == OP_EXTRACTELEMENT {
            if vc_fold_shuffle_chains_to_reduce(i) { return true; }
        } else if o == OP_ICMP || o == OP_FCMP {
            if o == OP_ICMP {
                if vc_fold_sign_bit_reduction_cmp(i) { return true; }
                if vc_fold_icmp_eq_zero_vector_reduce(i) { return true; }
                if vc_fold_reduction_zero_test(i) { return true; }
                if vc_fold_equivalent_reduction_cmp(i) { return true; }
                if vc_fold_reduce_add_cmp_zero(i) { return true; }
            }
            if vc_fold_extract_extract(i) { return true; }
        } else {
            if o == OP_OR { if vc_fold_concat_of_bool_masks(i) { return true; } }
            if is_binary_op(o) {
                if vc_fold_extract_extract(i) { return true; }
                if vc_fold_extracted_cmps(i) { return true; }
                if vc_fold_binop_of_reductions(i) { return true; }
            }
        }
    }
    return false;
}

// VectorCombinePass::run(F, FAM) with TryEarlyFoldsOnly = false (the registry's "vector-combine")
fn vector_combine_run(fv: i32) -> u32 {
    if flag_bool("disable-vector-combine", false) { return PA_ALL; }
    tti_init_function(fv, globs[glob_of(fv)].module);
    dt_get(fv, DT_DOM);
    aa_begin(fv);
    tli_cur_fn = fv;
    vc_fv = fv;
    vc_early_only = false;
    vc_kind = if vc_has_opt_size(fv) { TCK_CODE_SIZE } else { TCK_RECIP_THROUGHPUT };
    if tv_number_of_registers(tv_register_class_for_type(true, -1)) == 0 { return PA_ALL; }
    let save_tli = local_have_tli;
    local_have_tli = false;
    vc_wl.clear();
    vm_clear(VM_PASS0);
    var changed = false;
    var bb = func_first_block(fv);
    while bb >= 0 {
        if dt_has_node(DT_DOM, bb) {
            var i = block_first(bb);
            while i >= 0 {
                vc_next = inst_next(i);
                if !ld_is_debug_or_pseudo(i) { if vc_fold_inst(i) { changed = true; } }
                i = vc_next;
            }
        }
        bb = block_next(bb);
    }
    vc_next = -1;
    while vc_wl.len > 0 {
        let i = vcw_remove_one();
        if i < 0 { continue; }
        if is_dead(i) { fatal("internal: VectorCombine: an erased instruction is on the worklist"); }
        if is_instruction_trivially_dead(i) { vc_erase(i); continue; }
        if vc_fold_inst(i) { changed = true; }
    }
    local_have_tli = save_tli;
    vcb_cf = false;
    if !changed { return PA_ALL; }
    return PA_CFG;
}
