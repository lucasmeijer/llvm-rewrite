// The visitors of llvm/lib/Transforms/InstCombine/InstructionCombining.cpp that ic.goose doesn't hold, in file
// order: shouldMergeGEPs, unshuffleConstant, constantFoldBinOpWithSplat, foldSpliceBinOp, foldVectorBinop,
// getMergedGEPNoWrapFlags, foldSelectGEP, canonicalizeGEPOfConstGEPI8, combineConstantOffsets, visitGEPOfGEP,
// shouldCanonicalizeGEPToPtrAdd, foldGEPOfPhi, visitGetElementPtrInst, isNeverEqualToUnescapedAlloc,
// isRemovableWrite, isAllocSiteRemovable, visitAllocSite, tryToMoveFreeBeforeNullTest, visitFree,
// simplifySwitchOnSelectUsingRanges, visitSwitchInst, foldExtractOfOverflowIntrinsic, foldFrexpOfSelect,
// visitExtractValueInst, isCatchAll, visitLandingPadInst, pushFreezeToPreventPoisonFromPropagating,
// foldFreezeIntoRecurrence, freezeOtherUses, isUsedWithinShuffleVector, visitFreeze.
// Also isSplatValue (llvm/lib/Analysis/VectorUtils.cpp, with the Index argument) and classifyEHPersonality
// (llvm/lib/IR/EHPersonalities.cpp).
namespace ic;
import std;
import ir;
import dinfo;
import mem2reg;
import salvage;
import dbgutil;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import gen_tli;
import intrinsics;
import datalayout;
import apint;
import pm;
import vt;
import local;
import knownbits;
import memloc;
import tli;
import loads;
import poison;
import speculate;
import cfold;
import constfold;
import constrange;
import instsimplify;
import instident;
import domtree;
import domcond;
import flags;
import memorybuiltins;
import ic;
import ic_builder;
import ic_common;
import ic_visit_misc;
import ic_loadstorealloca;
import ic_vectorops;
import ic_select;
import ic_demanded_elts;
import ic_casts;
import autoupgrade;

// ---------------------------------------------------------------------------------------------
// GEP helpers

fn gep_src(g: i32) -> i32 { gep_src_ty(g) }
fn gep_nw(g: i32) -> u8 { gep_flags(g) }
fn gep_is_inbounds(g: i32) -> bool { (gep_nw(g) & GEP_INBOUNDS) != 0 }
fn gep_has_nuw(g: i32) -> bool { (gep_nw(g) & GEP_NUW) != 0 }
fn gep_has_nusw(g: i32) -> bool { (gep_nw(g) & GEP_NUSW) != 0 }
fn gep_set_nw(g: i32, f: u8) { insts[inst_of(g)].flags = f; }
// GEPNoWrapFlags with inbounds implying nusw (our flag byte stores inbounds alone)
fn nw_norm(f: u8) -> u8 { f }
fn nw_denorm(f: u8) -> u8 { f }
// GEPNoWrapFlags::intersectForOffsetAdd
fn nw_intersect_for_offset_add(a: u8, b: u8) -> u8 {
    var r = nw_norm(a) & nw_norm(b);
    if (r & GEP_INBOUNDS) == 0 && (r & GEP_NUSW) != 0 { r &= ~GEP_NUSW; }
    return nw_denorm(r);
}
// GEPNoWrapFlags::intersectForReassociate
fn nw_intersect_for_reassociate(a: u8, b: u8) -> u8 {
    var r = nw_norm(a) & nw_norm(b);
    if (r & GEP_NUW) == 0 { r &= ~(GEP_INBOUNDS | GEP_NUSW); }
    return nw_denorm(r);
}
fn gep_all_const_indices(g: i32) -> bool {
    for k in 1..nops(g) { let x = op(g, k); if vals[x].kind != VK_CINT || ty_is_vector(vals[x].ty) { return false; } }
    return true;
}
fn gep_all_zero_indices(g: i32) -> bool {
    for k in 1..nops(g) {
        let x = op(g, k);
        if vals[x].kind != VK_CINT || ty_is_vector(vals[x].ty) || !ap_is_zero(ci_ap(x)) { return false; }
    }
    return true;
}
fn is_gep_operator(v: i32) -> bool { opcode_of(v) == OP_GEP }
// GEPOperator::getResultElementType
fn gep_result_elem_ty(g: i32) -> i32 {
    let mark = is_ops.len;
    for k in 1..nops(g) { is_ops.push(op(g, k)); }
    let t = gep_indexed_type(gep_src(g), mark, nops(g) - 1);
    is_ops.resize(mark);
    return t;
}

// gep_type_iterator over a GEP's indices: for index operand k (1..), gti_struct[k-1], gti_ity[k-1]
// (getIndexedType), gti_cont[k-1] (the type being indexed; the source element type for the first index is
// "sequential over the pointer")
var gti_struct: bool[>..<];
var gti_ity: i32[>..<];
var gti_vec: bool[>..<];
fn gti_fill(g: i32) {
    gti_struct.clear();
    gti_ity.clear();
    gti_vec.clear();
    var t = gep_src(g);
    gti_struct.push(false);
    gti_ity.push(t);
    gti_vec.push(false);
    for k in 2..nops(g) {
        let cur = gti_ity[gti_ity.len - 1];
        if ty_is_struct(cur) {
            let c = m_apint(op(g, k));
            let fi = if c >= 0 { ap_zext64(ci_ap(c)) as i64 } else { 0 };
            gti_struct.push(true);
            gti_ity.push(ty_field(cur, fi));
            gti_vec.push(false);
        } else if ty_is_vector(cur) {
            gti_struct.push(false);
            gti_ity.push(ty_elem(cur));
            gti_vec.push(true);
        } else {
            gti_struct.push(false);
            gti_ity.push(ty_elem(cur));
            gti_vec.push(false);
        }
    }
}
fn gti_stride(k: i64) -> i64 { if gti_vec[k] { dl_store_size(gti_ity[k]) } else { dl_alloc_size(gti_ity[k]) } }

// IRBuilder::CreateGEP with the indices of an i32 run
fn icb_gep_run(srcty: i32, p: i32, idxs: const i32[:], name: const u8[:], fl: u8) -> i32 { icb_gep(srcty, p, idxs, name, fl) }
// GetElementPtrInst::Create(Ty, Ptr, Idx, NW) (unattached)
fn ic_new_gep(srcty: i32, p: i32, idxs: const i32[:], fl: u8) -> i32 {
    let rt = gep_ret_type(p, idxs);
    var opsv: i32[>..<] = [];
    opsv.push(p);
    for x in idxs { opsv.push(x); }
    let g = create_inst(OP_GEP, rt, opsv);
    insts[inst_of(g)].ty2 = srcty;
    insts[inst_of(g)].flags = fl;
    return g;
}

// shouldMergeGEPs(GEP, Src)
fn should_merge_geps(g: i32, src: i32) -> bool {
    if gep_all_zero_indices(g) && !gep_all_zero_indices(src) && !has_one_use(src) { return false; }
    return true;
}

// ---------------------------------------------------------------------------------------------
// foldVectorBinop and its helpers

// unshuffleConstant(ShMask, C, NewCTy): -1 if no such constant
fn unshuffle_constant(mask: const i32[:], c: i32, ncty: i32) -> i32 {
    if ty_kind(ncty) == TK_SVEC {
        let sp = splat_value(c, false);
        if sp < 0 { return -1; }
        return c_splat(ty_vector(vals[sp].ty, ty_count(ncty), true), sp);
    }
    let ct = vals[c].ty;
    if ty_count(ncty) > ty_count(ct) { return -1; }
    let nn = ty_count(ncty);
    let ps = c_poison(ty_scalar(ct));
    var nv: i32[>..<] = [];
    for k in nn { nv.push(ps); }
    let n = ty_count(ct);
    for i in n {
        let ce = agg_elem(c, i);
        if mask[i] >= 0 {
            let me = mask[i] as i64;
            if me >= nn { continue; }
            let nce = nv[me];
            if ce < 0 || (vals[nce].kind != VK_POISON && nce != ce) || i >= nn { return -1; }
            nv[me] = ce;
        }
    }
    return c_aggregate(ty_vector(ty_scalar(ct), nn, false), nv);
}

// constantFoldBinOpWithSplat(Opcode, Vector, Splat, SplatLHS, DL)
fn constant_fold_binop_with_splat(o: i64, vec: i32, sp: i32, splat_lhs: bool) -> i32 {
    var l = c_splat(vals[vec].ty, sp);
    var r = vec;
    if !splat_lhs { let t = l; l = r; r = t; }
    return cf_fold_binop_operands(o, l, r);
}

// isSplatValue(V, Index, Depth) (VectorUtils.cpp)
recursive fn vu_is_splat_value(v: i32, index: i64, depth0: i64) -> bool {
    var depth = depth0;
    if ty_is_vector(vals[v].ty) {
        if is_undef_or_poison(v) { return true; }
        if is_constant(v) { return splat_value(v, false) >= 0; }
    }
    if is_inst_op(v, OP_SHUFFLEVECTOR) {
        let x = insts[inst_of(v)];
        for k in x.naux { if ints[x.aux + k] != ints[x.aux] { return false; } }
        if index == -1 { return true; }
        return (ints[x.aux + index] as i64) == index;
    }
    if depth == 6 { return false; }
    depth++;
    if is_binop_inst(v) { return vu_is_splat_value(op(v, 0), index, depth) && vu_is_splat_value(op(v, 1), index, depth); }
    if is_select_inst(v) {
        return vu_is_splat_value(op(v, 0), index, depth) && vu_is_splat_value(op(v, 1), index, depth) && vu_is_splat_value(op(v, 2), index, depth);
    }
    return false;
}

fn shuf_mask_copy(s: i32, out: i32[>..<]&) {
    out.clear();
    let x = insts[inst_of(s)];
    for k in x.naux { out.push(ints[x.aux + k]); }
}
fn shuf_mask_eq(a: i32, b: i32) -> bool {
    let x = insts[inst_of(a)];
    let y = insts[inst_of(b)];
    if x.naux != y.naux { return false; }
    for k in x.naux { if ints[x.aux + k] != ints[y.aux + k] { return false; } }
    return true;
}

// a binop created by Builder.CreateBinOp(Opcode, X, Y) with Inst's IR flags copied (if it is a BinaryOperator)
fn fvb_binop(o: i64, x: i32, y: i32, inst: i32, name: const u8[:]) -> i32 {
    let v = icb_binop(o, x, y, name);
    if is_binop_inst(v) { copy_ir_flags(v, inst); }
    return v;
}

// foldSpliceBinOp<SpliceID>(Inst, Builder)
fn fold_splice_binop(inst: i32, id: i32) -> i32 {
    let lhs = op(inst, 0);
    let rhs = op(inst, 1);
    fn create(x: i32, y: i32, off: i32) -> i32 {
        var nm: u8[>..] = [];
        nm.append(val_name(inst));
        let v = fvb_binop(iop(inst), x, y, inst, nm);
        let pz = c_poison(vals[v].ty);
        let vt = vals[v].ty;
        return ic_new_intrinsic(id as i64, [vt as i32], [v, pz, off]);
    }
    if inst_iid(lhs) == id && is_poison(cb_arg(lhs, 1)) {
        let v1 = cb_arg(lhs, 0);
        let off = cb_arg(lhs, 2);
        if inst_iid(rhs) == id && is_poison(cb_arg(rhs, 1)) && cb_arg(rhs, 2) == off &&
           (has_one_use(lhs) || has_one_use(rhs) || (lhs == rhs && num_uses(lhs) == 2)) {
            return create(v1, cb_arg(rhs, 0), off);
        }
        if has_one_use(lhs) && vu_is_splat_value(rhs, -1, 0) { return create(v1, rhs, off); }
    } else if vu_is_splat_value(lhs, -1, 0) && inst_iid(rhs) == id && is_poison(cb_arg(rhs, 1)) && has_one_use(rhs) {
        return create(lhs, cb_arg(rhs, 0), cb_arg(rhs, 2));
    }
    return -1;
}

// foldVectorBinop(Inst) (ic_common's fold_vector_binop calls this)
fn fold_vector_binop_impl(inst: i32) -> i32 {
    if !ty_is_vector(vals[inst].ty) { return -1; }
    let o = iop(inst);
    var lhs = op(inst, 0);
    var rhs = op(inst, 1);
    // foldConstantsThroughSubVectorInsertSplat
    fn through_insert_splat(sub: i32, spl: i32, splat_lhs: bool) -> i32 {
        if !is_constant(spl) { return -1; }
        let sp = splat_value(spl, false);
        if sp < 0 { return -1; }
        if inst_iid(sub) != IID_vector_insert { return -1; }
        let dest = cb_arg(sub, 0);
        let sv = cb_arg(sub, 1);
        if !is_constant(dest) || !is_constant(sv) { return -1; }
        let nsv = constant_fold_binop_with_splat(o, sv, sp, splat_lhs);
        let nd = constant_fold_binop_with_splat(o, dest, sp, splat_lhs);
        if nsv < 0 || nd < 0 { return -1; }
        let iv = icb_intrinsic(IID_vector_insert, [vals[nd].ty as i32, vals[nsv].ty], [nd, nsv, cb_arg(sub, 2)], "");
        return ic_replace_inst_uses_with(inst, iv);
    }
    let f1 = through_insert_splat(lhs, rhs, false);
    if f1 >= 0 { return f1; }
    let f2 = through_insert_splat(rhs, lhs, true);
    if f2 >= 0 { return f2; }
    // concatenations
    if is_inst_op(lhs, OP_SHUFFLEVECTOR) && is_inst_op(rhs, OP_SHUFFLEVECTOR) && shuf_mask_eq(lhs, rhs) &&
       has_one_use(lhs) && has_one_use(rhs) && shuf_is_concat(lhs) && shuf_is_concat(rhs) {
        let b0 = fvb_binop(o, op(lhs, 0), op(rhs, 0), inst, "");
        let b1 = fvb_binop(o, op(lhs, 1), op(rhs, 1), inst, "");
        var m: i32[>..<] = [];
        shuf_mask_copy(lhs, m);
        return ic_new_shuffle(b0, b1, m);
    }
    fn create_reverse(x: i32, y: i32) -> i32 {
        var nm: u8[>..] = [];
        nm.append(val_name(inst));
        let v = fvb_binop(o, x, y, inst, nm);
        return ic_new_intrinsic(IID_vector_reverse, [vals[v].ty as i32], [v]);
    }
    if inst_iid(lhs) == IID_vector_reverse {
        let v1 = cb_arg(lhs, 0);
        if inst_iid(rhs) == IID_vector_reverse && (has_one_use(lhs) || has_one_use(rhs) || (lhs == rhs && num_uses(lhs) == 2)) {
            return create_reverse(v1, cb_arg(rhs, 0));
        }
        if has_one_use(lhs) && vu_is_splat_value(rhs, -1, 0) { return create_reverse(v1, rhs); }
    } else if vu_is_splat_value(lhs, -1, 0) && inst_iid(rhs) == IID_vector_reverse && has_one_use(rhs) {
        return create_reverse(lhs, cb_arg(rhs, 0));
    }
    fn create_vp_reverse(x: i32, y: i32, evl: i32) -> i32 {
        var nm: u8[>..] = [];
        nm.append(val_name(inst));
        let v = fvb_binop(o, x, y, inst, nm);
        let vt = vals[v].ty;
        let mt = ty_vector(T_I1, ty_count(vt), ty_kind(vt) == TK_SVEC);
        let all_true = icb_vector_splat(mt, c_true(), "");
        return ic_new_intrinsic(IID_experimental_vp_reverse, [vt as i32], [v, all_true, evl]);
    }
    if inst_iid(lhs) == IID_experimental_vp_reverse && m_all_ones(cb_arg(lhs, 1)) {
        let v1 = cb_arg(lhs, 0);
        let evl = cb_arg(lhs, 2);
        if inst_iid(rhs) == IID_experimental_vp_reverse && m_all_ones(cb_arg(rhs, 1)) && cb_arg(rhs, 2) == evl &&
           (has_one_use(lhs) || has_one_use(rhs) || (lhs == rhs && num_uses(lhs) == 2)) {
            return create_vp_reverse(v1, cb_arg(rhs, 0), evl);
        }
        if has_one_use(lhs) && vu_is_splat_value(rhs, -1, 0) { return create_vp_reverse(v1, rhs, evl); }
    } else if vu_is_splat_value(lhs, -1, 0) && inst_iid(rhs) == IID_experimental_vp_reverse && m_all_ones(cb_arg(rhs, 1)) {
        return create_vp_reverse(lhs, cb_arg(rhs, 0), cb_arg(rhs, 2));
    }
    let s1 = fold_splice_binop(inst, IID_vector_splice_left);
    if s1 >= 0 { return s1; }
    let s2 = fold_splice_binop(inst, IID_vector_splice_right);
    if s2 >= 0 { return s2; }
    if !sl_safe_spec_var_replaced(inst) { return -1; }
    fn create_shuffle(x: i32, y: i32, m: const i32[:]) -> i32 {
        let xy = fvb_binop(o, x, y, inst, "");
        return ic_new_shuffle1(xy, m);
    }
    var mask: i32[>..<] = [];
    if is_inst_op(lhs, OP_SHUFFLEVECTOR) && is_poison(op(lhs, 1)) && is_inst_op(rhs, OP_SHUFFLEVECTOR) &&
       is_poison(op(rhs, 1)) && shuf_mask_eq(lhs, rhs) && vals[op(lhs, 0)].ty == vals[op(rhs, 0)].ty &&
       (has_one_use(lhs) || has_one_use(rhs) || lhs == rhs) {
        shuf_mask_copy(lhs, mask);
        return create_shuffle(op(lhs, 0), op(rhs, 0), mask);
    }
    if is_commutative_op(o) && is_inst_op(lhs, OP_SHUFFLEVECTOR) && is_inst_op(rhs, OP_SHUFFLEVECTOR) &&
       op(rhs, 0) == op(lhs, 1) && op(rhs, 1) == op(lhs, 0) && shuf_mask_eq(lhs, rhs) {
        if shuf_is_select(lhs) && !shuf_has_poison_elt(lhs) && shuf_is_select(rhs) && !shuf_has_poison_elt(rhs) {
            let nb = ic_new_binop(o, op(lhs, 0), op(lhs, 1));
            copy_ir_flags(nb, inst);
            return nb;
        }
    }
    // m_c_BinOp(m_OneUse(m_Shuffle(V1, m_Poison(), Mask)), m_ImmConstant(C))
    for k in 2 {
        let sh = op(inst, k);
        let c = op(inst, 1 - k);
        if is_inst_op(sh, OP_SHUFFLEVECTOR) && has_one_use(sh) && is_poison(op(sh, 1)) && m_imm_constant(c) {
            let v1 = op(sh, 0);
            let const_op1 = is_constant(op(inst, 1));
            shuf_mask_copy(sh, mask);
            var nc = unshuffle_constant(mask, c, vals[v1].ty);
            if nc >= 0 {
                if ty_kind(vals[v1].ty) == TK_FVEC && is_int_divrem_op(o) { nc = safe_vector_constant_for_binop(o, nc, const_op1); }
                let nl = if const_op1 { v1 } else { nc };
                let nr = if const_op1 { nc } else { v1 };
                return create_shuffle(nl, nr, mask);
            }
            break;
        }
    }
    if ic_inst_is_associative(inst) && is_commutative_op(o) {
        if is_inst_op(rhs, OP_SHUFFLEVECTOR) { let t = lhs; lhs = rhs; rhs = t; }
        if !(is_inst_op(lhs, OP_SHUFFLEVECTOR) && has_one_use(lhs) && m_undef(op(lhs, 1))) { return -1; }
        let x = op(lhs, 0);
        shuf_mask_copy(lhs, mask);
        let si = splat_or_poison_index(mask);
        if si == -2 || vals[x].ty != vals[inst].ty { return -1; }
        if !(is_inst_op(rhs, o) && has_one_use(rhs)) { return -1; }
        var y = op(rhs, 0);
        var other = op(rhs, 1);
        if vu_is_splat_value(other, si, 0) {
            let t = y; y = other; other = t;
        } else if !vu_is_splat_value(y, si, 0) {
            return -1;
        }
        let nb = icb_binop(o, x, y, "");
        var nm: i32[>..<] = [];
        for k in mask.len { nm.push(si as i32); }
        let ns = icb_shuffle1(nb, nm, "");
        let r = ic_new_binop(o, ns, other);
        if is_fp_math_operator(r) {
            insts[inst_of(r)].fmf = insts[inst_of(inst)].fmf;
            ii_and_ir_flags(r, rhs);
        }
        if is_binop_inst(nb) { copy_ir_flags(nb, r); }
        return r;
    }
    return -1;
}
// m_SplatOrPoisonMask(SplatIndex): the common non-negative mask element (or 0 if all poison); -2 = no match
fn splat_or_poison_index(mask: const i32[:]) -> i64 {
    var idx: i64 = -1;
    for m in mask {
        if m == -1 { continue; }
        if idx == -1 { idx = m as i64; } else if idx != m as i64 { return -2; }
    }
    return if idx == -1 { 0 } else { idx };
}
fn is_commutative_op(o: i64) -> bool { o == OP_ADD || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_FADD || o == OP_FMUL }
fn is_associative_op(o: i64) -> bool { o == OP_ADD || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_XOR }
fn is_int_divrem_op(o: i64) -> bool { o == OP_UDIV || o == OP_SDIV || o == OP_UREM || o == OP_SREM }
fn shuf_has_poison_elt(s: i32) -> bool {
    let x = insts[inst_of(s)];
    for k in x.naux { if ints[x.aux + k] == -1 { return true; } }
    return false;
}

// ---------------------------------------------------------------------------------------------
// GEP visitors

// foldSelectGEP(GEP, Builder)
fn fold_select_gep(g: i32) -> i32 {
    if !gep_all_const_indices(g) { return -1; }
    let sel = op(g, 0);
    if !is_select_inst(sel) || !is_constant(op(sel, 1)) || !is_constant(op(sel, 2)) { return -1; }
    var idx: i32[>..<] = [];
    for k in 1..nops(g) { idx.push(op(g, k)); }
    let nw = gep_nw(g);
    let ty = gep_src(g);
    let nt = icb_gep(ty, op(sel, 1), idx, "", nw);
    let nf = icb_gep(ty, op(sel, 2), idx, "", nw);
    return ic_new_select_copy_md(op(sel, 0), nt, nf, sel);
}
// SelectInst::Create(C, S1, S2, Name, InsertBefore, MDFrom): copyMetadata(*MDFrom) (all kinds, !dbg too)
fn ic_new_select_copy_md(c: i32, t: i32, f: i32, from: i32) -> i32 {
    let s = ic_new_select(c, t, f);
    if from >= 0 { inst_copy_all_md(s, from); }
    return s;
}

// canonicalizeGEPOfConstGEPI8(GEP, Src, IC)
fn canonicalize_gep_of_const_gep_i8(g: i32, src: i32) -> i32 {
    if nops(g) != 2 { return -1; }
    // m_PtrAdd(m_Value(Base), m_APInt(C1)): a GEP with i8 source type and one index
    if !(is_gep_operator(src) && nops(src) == 2 && is_int_or_int_vec_w(gep_src(src), 8) && !ty_is_vector(gep_src(src))) { return -1; }
    let base = op(src, 0);
    let c1 = m_apint(op(src, 1));
    if c1 < 0 { return -1; }
    let ptrty = ty_scalar(vals[src].ty);
    let isz = dl_ptr(ptr_as(ptrty)).idx;
    let i1 = op(g, 1);
    if !m_add_like(i1) { return -1; }
    let var_index = op(i1, 0);
    let c2 = m_apint(op(i1, 1));
    if c2 < 0 { return -1; }
    let a1 = ci_ap(c1);
    let a2 = ci_ap(c2);
    if (a1.w as i64) != isz || (a2.w as i64) != isz { return -1; }
    let bt = gep_src(g);
    if ty_kind(bt) == TK_SVEC { return -1; }
    let tsz = ap_u64(dl_alloc_size(bt) as u64, isz);
    let noff = ap_add(ap_mul(tsz, a2), a1);
    if ap_is_zero(noff) || (has_one_use(src) && has_one_use(i1)) {
        var fl: u8 = 0;
        if gep_has_nuw(g) && gep_has_nuw(src) && m_nuw_add_like(i1) {
            fl |= GEP_NUW;
            if gep_is_inbounds(g) && gep_is_inbounds(src) { fl |= GEP_INBOUNDS | GEP_NUSW; }
        }
        let gc = icb_ptr_add(base, c_int_ap(ty_int(isz), noff), "", fl);
        return ic_new_gep(bt, gc, [var_index], fl);
    }
    return -1;
}

// combineConstantOffsets(GEP, IC)
fn combine_constant_offsets(g: i32) -> i32 {
    if !gep_all_const_indices(g) { return -1; }
    var nw: u8 = GEP_INBOUNDS | GEP_NUSW | GEP_NUW;   // GEPNoWrapFlags::all()
    var skipped: i32[>..<] = [];
    var inner = op(g, 0);
    loop {
        if !is_inst_op(inner, OP_GEP) { return -1; }
        nw = nw_intersect_for_reassociate(nw, gep_nw(inner));
        if gep_all_const_indices(inner) { break; }
        if !has_one_use(inner) { return -1; }
        skipped.push(inner);
        inner = op(inner, 0);
    }
    if skipped.len == 0 { return -1; }
    if !has_one_use(inner) { return -1; }
    let ty = vals[g].ty;
    if vals[inner].ty != ty { return -1; }
    let ok1, o1 = gep_accumulate_constant_offset(g);
    if !ok1 { return -1; }
    let ok2, o2 = gep_accumulate_constant_offset(inner);
    if !ok2 { return -1; }
    let w = dl_ptr(ptr_as(ty)).idx;
    let off = ap_add(ap_i64(o1, w), ap_i64(o2, w));
    ic_replace_operand(skipped[skipped.len - 1], 0, op(inner, 0));
    for s in skipped { gep_set_nw(s, nw); }
    return ic_replace_inst_uses_with(g, icb_ptr_add(skipped[0], c_int_ap(ty_int(w), off), "", nw_intersect_for_offset_add(nw, gep_nw(g))));
}

// visitGEPOfGEP(GEP, Src)
fn visit_gep_of_gep(g: i32, src: i32) -> i32 {
    if !should_merge_geps(g, src) { return -1; }
    let r1 = canonicalize_gep_of_const_gep_i8(g, src);
    if r1 >= 0 { return r1; }
    let r2 = combine_constant_offsets(g);
    if r2 >= 0 { return r2; }
    if gep_result_elem_ty(src) != gep_src(g) { return -1; }
    if has_one_use(src) && nops(g) == 2 && nops(src) == 2 {
        let si = op(src, 1);
        let gi = op(g, 1);
        var co: i32 = -1;
        var sel: i32 = -1;
        if m_apint(si) >= 0 && is_select_inst(gi) && m_apint(op(gi, 1)) >= 0 && m_apint(op(gi, 2)) >= 0 { co = m_apint(si); sel = gi; }
        else if m_apint(gi) >= 0 && is_select_inst(si) && m_apint(op(si, 1)) >= 0 && m_apint(op(si, 2)) >= 0 { co = m_apint(gi); sel = si; }
        if sel >= 0 {
            if !has_one_use(sel) { return -1; }
            let c0 = ci_ap(co);
            let tv = ci_ap(m_apint(op(sel, 1)));
            let fv = ci_ap(m_apint(op(sel, 2)));
            if tv.w != c0.w || fv.w != c0.w { return -1; }
            let nt = c_int_ap(vals[sel].ty, ap_add(c0, tv));
            let nf = c_int_ap(vals[sel].ty, ap_add(c0, fv));
            let profcheck = flag_bool("profcheck-disable-metadata-fixes", false);
            let ns = icb_select(op(sel, 0), nt, nf, "", if profcheck { -1 } else { sel });
            let fl = nw_intersect_for_offset_add(gep_nw(src), gep_nw(g));
            return ic_replace_inst_uses_with(g, icb_gep(gep_result_elem_ty(g), op(src, 0), [ns], "", fl));
        }
    }
    // EndsWithSequential
    gti_fill(src);
    if gti_struct[gti_struct.len - 1] { return -1; }
    let so1 = op(src, nops(src) - 1);
    let go1 = op(g, 1);
    if vals[so1].ty != vals[go1].ty { return -1; }
    let sum = simplify_add(go1, so1, false, false, sq_at(g), RECURSION_LIMIT);
    if sum < 0 { return -1; }
    var idx: i32[>..<] = [];
    for k in 1..nops(src) - 1 { idx.push(op(src, k)); }
    idx.push(sum);
    for k in 2..nops(g) { idx.push(op(g, k)); }
    var nnz: i64 = 0;
    for x in idx { if !is_constant(x) || !is_null_value(x) { nnz++; } }
    if nnz > 1 { return -1; }
    return ic_replace_inst_uses_with(g, icb_gep(gep_src(src), op(src, 0), idx, "", nw_intersect_for_offset_add(gep_nw(src), gep_nw(g))));
}

// shouldCanonicalizeGEPToPtrAdd(GEP)
fn should_canonicalize_gep_to_ptr_add(g: i32) -> bool {
    let p = op(g, 0);
    let et = gep_src(g);
    if is_int_or_int_vec_w(et, 8) && !ty_is_vector(et) { return false; }
    if ty_contains_scalable(et) { return true; }
    if nops(g) == 2 {
        let x = op(g, 1);
        if one_use(x) && (bo(x, OP_MUL) || bo(x, OP_SHL)) && m_constant_int(op(x, 1)) >= 0 { return true; }
    }
    if is_gep_operator(p) && gep_all_const_indices(p) {
        for k in 1..nops(g) {
            let c = m_apint(op(g, k));
            if c >= 0 && !ap_is_zero(ci_ap(c)) { return true; }
        }
    }
    return false;
}

// foldGEPOfPhi(GEP, PN, Builder)
fn fold_gep_of_phi(g: i32, pn: i32) -> i32 {
    let op1 = op(pn, 0);
    if !is_inst_op(op1, OP_GEP) { return -1; }
    if op1 == g { return -1; }
    var nw = gep_nw(op1);
    var di: i64 = -1;
    for pk in 1..nops(pn) {
        let op2 = op(pn, pk);
        if !is_inst_op(op2, OP_GEP) || nops(op1) != nops(op2) || gep_src(op1) != gep_src(op2) { return -1; }
        if op2 == g { return -1; }
        var cur: i32 = -1;
        for j in nops(op1) {
            if vals[op(op1, j)].ty != vals[op(op2, j)].ty { return -1; }
            if op(op1, j) != op(op2, j) {
                if di == -1 {
                    if j > 1 && ty_is_struct(cur) { return -1; }
                    di = j;
                } else {
                    return -1;
                }
            }
            if j > 0 {
                if j == 1 { cur = gep_src(op1); }
                else {
                    // GetElementPtrInst::getTypeAtIndex(CurTy, Op1->getOperand(J))
                    if ty_is_struct(cur) {
                        let c = m_apint(op(op1, j));
                        cur = if c >= 0 { ty_field(cur, ap_zext64(ci_ap(c)) as i64) } else { -1 };
                    } else if cur >= 0 && (ty_is_array(cur) || ty_is_vector(cur)) { cur = ty_elem(cur); }
                    else { cur = -1; }
                }
            }
        }
        nw = nw & gep_nw(op2);
    }
    if di != -1 && !has_one_use(pn) { return -1; }
    let ng = inst_clone(op1);
    gep_set_nw(ng, nw);
    if di != -1 {
        let sp = icb_pos; let sb = icb_bb; let sd = icb_dl;
        icb_set_insert_point(pn);
        let npn = icb_phi(vals[op(op1, di)].ty, "");
        icb_pos = sp; icb_bb = sb; icb_dl = sd; icb_head = false;
        for k in nops(pn) { phi_add_incoming(npn, op(op(pn, k), di), phi_block(pn, k)); }
        set_op(ng, di, npn);
    }
    inst_insert_before_head(ng, first_insertion_pt(inst_parent(g)));
    ic_register_name(ng);
    return ng;
}

// visitGetElementPtrInst(GEP)
fn visit_gep(g: i32) -> i32 {
    let p = op(g, 0);
    var indices: i32[>..<] = [];
    for k in 1..nops(g) { indices.push(op(g, k)); }
    let gty = vals[g].ty;
    let gety = gep_src(g);
    let mark = is_ops.len;
    is_ops.push(p);
    for x in indices { is_ops.push(x); }
    let sv = simplify_gep(gety, p, mark + 1, indices.len, gep_nw(g), sq_at(g), RECURSION_LIMIT);
    is_ops.resize(mark);
    if sv >= 0 { return ic_replace_inst_uses_with(g, sv); }
    if ty_kind(gty) == TK_FVEC {
        let vw = ty_count(gty);
        let r = ic_sdve(g, ap_ones(vw), false);
        if r >= 0 {
            if r != g { return ic_replace_inst_uses_with(g, r); }
            return g;
        }
    }
    var made = false;
    let nsit = dl_index_type(ty_scalar(vals[p].ty));
    gti_fill(g);
    for k in 1..nops(g) {
        if gti_struct[k - 1] { continue; }
        let ity = vals[op(g, k)].ty;
        let nity = if ty_is_vector(ity) { ty_vector(nsit, ty_count(ity), ty_kind(ity) == TK_SVEC) } else { nsit };
        let et = gti_ity[k - 1];
        if cf_ty_is_sized(et) && !ty_contains_scalable_size(et) && dl_alloc_size(et) == 0 {
            let x = op(g, k);
            if !is_constant(x) || !m_zero(x) {
                set_op(g, k, c_null(nity));
                made = true;
            }
        }
        if ity != nity {
            let x = op(g, k);
            icb_set_insert_point(g);
            var nx: i32 = -1;
            if ty_scalar_bits(ity) < ty_scalar_bits(nity) {
                if gep_has_nuw(g) && gep_has_nusw(g) { nx = icb_zext_nneg(x, nity, "", true); }
                else { nx = icb_sext(x, nity, ""); }
            } else {
                nx = icb_trunc_nw(x, nity, "", gep_has_nuw(g), gep_has_nusw(g));
            }
            set_op(g, k, nx);
            made = true;
        }
    }
    if made { return g; }
    // Canonicalize constant GEPs to i8
    if !(gety == T_I8) && gep_all_const_indices(g) {
        let ok, off = gep_accumulate_constant_offset(g);
        if ok {
            let w = dl_ptr(ptr_as(gty)).idx;
            return ic_replace_inst_uses_with(g, icb_ptr_add(p, c_int_ap(ty_int(w), ap_i64(off, w)), "", gep_nw(g)));
        }
    }
    if should_canonicalize_gep_to_ptr_add(g) {
        let off = emit_gep_offset(g, false);
        return ic_replace_inst_uses_with(g, icb_ptr_add(p, off, "", gep_nw(g)));
    }
    // Strip trailing zero indices
    let last = indices[indices.len - 1];
    if is_constant(last) && is_null_value(last) && !ty_is_vector(vals[last].ty) {
        return ic_replace_inst_uses_with(g, icb_gep(gety, p, indices[0..indices.len - 1], "", gep_nw(g)));
    }
    // Strip leading zero indices
    let first = indices[0];
    if is_constant(first) && is_null_value(first) && !ty_is_vector(vals[first].ty) && indices.len >= 2 {
        if !gti_struct[1] && gti_stride(1) == dl_alloc_size(gti_ity[1]) {
            return ic_replace_inst_uses_with(g, icb_gep(gti_ity[1], op(g, 0), indices[1..], "", gep_nw(g)));
        }
    }
    // Scalarize vector operands
    if ty_is_vector(gty) {
        var any = false;
        for k in nops(g) { let x = op(g, k); if ty_is_vector(vals[x].ty) && get_splat_value_v(x) >= 0 { any = true; } }
        if any {
            var nops_: i32[>..<] = [];
            for k in nops(g) {
                let x = op(g, k);
                if ty_is_vector(vals[x].ty) {
                    let s = get_splat_value_v(x);
                    if s >= 0 { nops_.push(s); continue; }
                }
                nops_.push(x);
            }
            var nm: u8[>..] = [];
            nm.append(val_name(g));
            var res = icb_gep(gety, nops_[0], nops_[1..], nm, gep_nw(g));
            if !ty_is_vector(vals[res].ty) { res = icb_vector_splat(ty_vector(vals[res].ty, ty_count(gty), ty_kind(gty) == TK_SVEC), res, ""); }
            return ic_replace_inst_uses_with(g, res);
        }
    }
    // Split GEPs with multiple non-zero indices
    var seen_nz = false;
    for idx_num in indices.len {
        let x = indices[idx_num];
        if is_constant(x) && is_null_value(x) && idx_num == 0 { continue; }
        if !seen_nz { seen_nz = true; continue; }
        var nm: u8[>..] = [];
        nm.append(val_name(g));
        nm.append(".split");
        let front = icb_gep(gety, p, indices[0..idx_num], nm, gep_nw(g));
        var back: i32[>..<] = [];
        back.push(c_null(nsit));
        for k in idx_num..indices.len { back.push(indices[k]); }
        let mk = is_ops.len;
        is_ops.push(p);
        for k in idx_num { is_ops.push(indices[k]); }
        let ft = gep_indexed_type(gety, mk + 1, idx_num);
        is_ops.resize(mk);
        return ic_new_gep(ft, front, back, gep_nw(g));
    }
    // Canonicalize gep %T to gep [sizeof(%T) x i8]
    if indices.len == 1 {
        var ct = gety;
        if ty_is_array(ct) { ct = ty_elem(ct); }
        if !(ty_kind(ct) == TK_INT && ty_bits(ct) == 8) {
            let scale = dl_alloc_size(gety);
            var net = T_I8;
            if scale != 1 { net = ty_array(T_I8, scale); }
            insts[inst_of(g)].ty2 = net;
            ic_made_change = true;
        }
    }
    if is_phi_inst(p) {
        let np = fold_gep_of_phi(g, p);
        if np >= 0 { return ic_replace_operand(g, 0, np); }
    }
    if is_gep_operator(p) {
        let r = visit_gep_of_gep(g, p);
        if r >= 0 { return r; }
    }
    if nops(g) == 2 {
        let as_ = ptr_as(gty);
        let i1 = op(g, 1);
        if ty_scalar_bits(vals[i1].ty) == dl_ptr(as_).idx {
            let tsz = dl_alloc_size(gep_src(g)) as u64;
            if tsz == 1 {
                let x = op(g, 0);
                if bo(i1, OP_SUB) {
                    let y = m_ptrtoint_or_addr(op(i1, 0));
                    let xx = m_ptrtoint_or_addr(op(i1, 1));
                    if y >= 0 && xx == x && gty == vals[y].ty {
                        let has_non_addr = dl_ptr(as_).idx != dl_ptr(as_).bits;
                        var changed = false;
                        var u = first_use(g);
                        while u >= 0 {
                            let us = use_user(u);
                            let nu = use_next(u);
                            if is_inst_op(us, OP_PTRTOADDR) || is_inst_op(us, OP_ICMP) || (!has_non_addr && is_inst_op(us, OP_PTRTOINT)) {
                                use_set(u, y);
                                changed = true;
                            }
                            u = nu;
                        }
                        return if changed { g } else { -1 };
                    }
                }
            } else if is_inst(i1) && (iop(i1) == OP_UDIV || iop(i1) == OP_SDIV || iop(i1) == OP_LSHR || iop(i1) == OP_ASHR) {
                let exact = op_exact(i1);
                let pow2 = (tsz & (tsz - 1)) == 0;
                let tz = ctz64(tsz);
                if exact {
                    let o = iop(i1);
                    if (pow2 && (o == OP_LSHR || o == OP_ASHR) && m_specific_int(op(i1, 1), tz as u64)) ||
                       ((o == OP_UDIV || o == OP_SDIV) && m_specific_int(op(i1, 1), tsz)) {
                        return ic_new_gep(T_I8, op(g, 0), [op(i1, 0)], gep_nw(g));
                    }
                }
                if exact && has_one_use(i1) {
                    let o = iop(i1);
                    let v = op(i1, 0);
                    let c = m_apint(op(i1, 1));
                    var have = false;
                    var nc = ap_zero(1);
                    if c >= 0 {
                        let ca = ci_ap(c);
                        let w = ca.w as i64;
                        if pow2 && (o == OP_LSHR || o == OP_ASHR) && ap_uge_u64(ca, tz as u64) {
                            nc = ap_sub(ca, ap_u64(tz as u64, w));
                            have = true;
                        } else if o == OP_UDIV {
                            let q, r = ap_udivrem(ca, ap_u64(tsz, w));
                            if ap_is_zero(r) { nc = q; have = true; }
                        } else if o == OP_SDIV {
                            let q, r = ap_sdivrem(ca, ap_u64(tsz, w));
                            if !ap_is_all_ones(q) && ap_is_zero(r) { nc = q; have = true; }
                        }
                    }
                    if have {
                        let nop = icb_binop_fl(o, v, c_int_ap(vals[v].ty, nc), "", FL_EXACT);
                        return ic_new_gep(T_I8, op(g, 0), [nop], gep_nw(g));
                    }
                }
            }
        }
    }
    if ty_is_vector(gty) { return -1; }
    if !gep_is_inbounds(g) {
        let iw = dl_ptr(ptr_as(vals[p].ty)).idx;
        let under = strip_and_accumulate_offsets(p, false, false, false);
        let base_off = vt_off;
        let bytes, can_null = ptr_deref_bytes(under);
        if !can_null && bytes != 0 {
            let ok, off = gep_accumulate_constant_offset(g);
            let tot = ap_add(ap_i64(base_off, iw), ap_i64(off, iw));
            if ok && ap_is_nonneg(tot) {
                if ap_ule(tot, ap_u64(bytes, iw)) {
                    let ng = ic_new_gep(gep_src(g), p, indices, GEP_INBOUNDS | GEP_NUSW);
                    var nm: u8[>..] = [];
                    nm.append(val_name(g));
                    set_name(ng, nm);
                    return ng;
                }
            }
        }
    }
    // nusw + nneg -> nuw
    if gep_has_nusw(g) && !gep_has_nuw(g) {
        var all = true;
        for k in 1..nops(g) { if !is_known_non_negative_v(op(g, k), g) { all = false; break; } }
        if all {
            gep_set_nw(g, gep_nw(g) | GEP_NUW);
            return g;
        }
    }
    if nops(g) == 2 {
        let i1 = op(g, 1);
        fn preserved(add_nuw: bool) -> u8 { if gep_has_nuw(g) && add_nuw { gep_nw(g) } else { 0 } }
        if one_use(i1) && m_add_like(i1) {
            let nuw = m_nuw_add_like(i1);
            let fl = preserved(nuw);
            let np = icb_gep(gep_src(g), op(g, 0), [op(i1, 0)], "", fl);
            return ic_replace_inst_uses_with(g, icb_gep(gep_src(g), np, [op(i1, 1)], "", fl));
        }
        // m_OneUse(m_SExtLike(m_OneUse(m_NSWAddLike(m_Value(Idx1), m_ConstantInt(C)))))
        if one_use(i1) && (is_inst_op(i1, OP_SEXT) || (is_inst_op(i1, OP_ZEXT) && has_flag(i1, FL_NNEG))) {
            let a = op(i1, 0);
            if one_use(a) && m_nsw_add_like(a) && m_constant_int(op(a, 1)) >= 0 {
                let c = op(a, 1);
                let nuw = is_inst_op(i1, OP_ZEXT) && has_flag(i1, FL_NNEG) && m_nuw_add_like(a);
                let fl = preserved(nuw);
                let it = vals[i1].ty;
                let np = icb_gep(gep_src(g), op(g, 0), [icb_sext(op(a, 0), it, "")], "", fl);
                return ic_replace_inst_uses_with(g, icb_gep(gep_src(g), np, [icb_sext(c, it, "")], "", fl));
            }
        }
    }
    let rs = fold_select_gep(g);
    if rs >= 0 { return rs; }
    if indices.len == 1 && gep_is_inbounds(g) && gep_has_nuw(g) {
        let x0 = indices[0];
        if one_use(x0) && bo(x0, OP_SREM) {
            let x = op(x0, 0);
            let y = op(x0, 1);
            kb_cxt = g;
            if is_known_pow2(y, true, 0) {
                var nm: u8[>..] = [];
                nm.append(val_name(x0));
                let ni = icb_urem(x, y, nm);
                return ic_new_gep(gety, p, [ni], gep_nw(g));
            }
        }
    }
    return -1;
}
fn ctz64(x: u64) -> i64 { if x == 0 { return 64; } var k: i64 = 0; var y = x; while (y & 1) == 0 { y >>= 1; k++; } return k; }
fn ty_contains_scalable_size(t: i32) -> bool { ty_contains_scalable(t) }

// ---------------------------------------------------------------------------------------------
// Allocation sites

// isNeverEqualToUnescapedAlloc(V, TLI, AI)
fn is_never_equal_to_unescaped_alloc(v: i32, ai: i32) -> bool {
    if vals[v].kind == VK_CNULL { return true; }
    if is_inst_op(v, OP_LOAD) { return vals[op(v, 0)].kind == VK_GVAR; }
    return is_callbase(v) && is_alloc_like_fn(v) && v != ai;
}

// isRemovableWrite(CB, UsedV, TLI)
fn is_removable_write(cb: i32, used: i32) -> bool {
    if !use_empty(cb) { return false; }
    if is_terminator(cb) { return false; }
    if !inst_will_return(cb) || !call_has_fn_attr(cb, AK_NoUnwind) { return false; }
    let d = mb_memloc_for_dest(cb);
    return d >= 0 && d == used;
}

// isAllocSiteRemovable(AI, Users, TLI, KnowInit): returns ModRefInfo (0..2) or -1 = not removable
var as_users: i32[>..<];
fn is_alloc_site_removable(ai: i32, know_init: bool) -> i64 {
    var wl: i32[>..<] = [];
    let family = mb_allocation_family(ai);
    wl.push(ai);
    var access: i64 = if know_init { MR_NO } else { MR_MOD };
    let max_users = flag_int("instcombine-max-alloc-site-removable-users", 512);
    while wl.len > 0 {
        let pi = wl.pop();
        var u = first_use(pi);
        while u >= 0 {
            let i = use_user(u);
            u = use_next(u);
            if as_users.len >= max_users { return -1; }
            let o = iop(i);
            if o == OP_ADDRSPACECAST || o == OP_BITCAST || o == OP_GEP {
                as_users.push(i);
                wl.push(i);
                continue;
            }
            if o == OP_ICMP {
                let p = inst_pred(i) as i64;
                if !icmp_is_equality(p) { return -1; }
                let other = if op(i, 0) == pi { op(i, 1) } else { op(i, 0) };
                if !is_never_equal_to_unescaped_alloc(other, ai) { return -1; }
                if is_callbase(ai) {
                    let cf = called_function(ai);
                    if cf >= 0 {
                        let lf = tli_get_libfunc(cf);
                        if lf >= 0 && tli_has(lf) && lf == LF_aligned_alloc {
                            let a0 = m_apint(cb_arg(ai, 0));
                            let a1 = m_apint(cb_arg(ai, 1));
                            var valid = false;
                            if a0 >= 0 && a1 >= 0 {
                                let al = ci_ap(a0);
                                let sz = ci_ap(a1);
                                valid = ap_is_pow2(al) && ap_is_zero(ap_urem(sz, al));
                            }
                            if !valid { return -1; }
                        }
                    }
                }
                as_users.push(i);
                continue;
            }
            if o == OP_CALL {
                let id = inst_iid(i);
                if id != 0 {
                    if id == IID_memmove || id == IID_memcpy || id == IID_memset {
                        if lsa_memintr_volatile(i) { return -1; }
                        let na = if cb_arg(i, 0) == pi { MR_MOD } else { MR_REF };
                        if (access & ~na) != MR_NO { return -1; }
                        access |= na;
                        as_users.push(i);
                        continue;
                    }
                    if id == IID_assume || id == IID_invariant_start || id == IID_invariant_end || id == IID_lifetime_start ||
                       id == IID_lifetime_end || id == IID_objectsize {
                        as_users.push(i);
                        continue;
                    }
                    if id == IID_launder_invariant_group || id == IID_strip_invariant_group {
                        as_users.push(i);
                        wl.push(i);
                        continue;
                    }
                    return -1;
                }
                if family >= 0 && get_freed_operand(i) == pi && mb_allocation_family(i) == family {
                    as_users.push(i);
                    continue;
                }
                if family >= 0 && mb_reallocated_operand(i) == pi && mb_allocation_family(i) == family {
                    as_users.push(i);
                    wl.push(i);
                    continue;
                }
                if !mr_is_ref(access) && is_removable_write(i, pi) {
                    access |= MR_MOD;
                    as_users.push(i);
                    continue;
                }
                return -1;
            }
            if o == OP_STORE {
                if ld_is_volatile(i) || op(i, 1) != pi { return -1; }
                if mr_is_ref(access) { return -1; }
                access |= MR_MOD;
                as_users.push(i);
                continue;
            }
            if o == OP_LOAD {
                if ld_is_volatile(i) || op(i, 0) != pi { return -1; }
                if mr_is_mod(access) { return -1; }
                access |= MR_REF;
                as_users.push(i);
                continue;
            }
            return -1;
        }
    }
    return access;
}

// visitAllocSite(MI)
fn visit_alloc_site(mi: i32) -> i32 {
    as_users.clear();
    let is_alloca = iop(mi) == OP_ALLOCA;
    var know_undef = false;
    var know_zero = false;
    let init = mb_initial_value_of_allocation(mi, T_I8);
    if init >= 0 {
        if is_undef_or_poison(init) { know_undef = true; } else if is_null_value(init) { know_zero = true; }
    }
    let f = inst_func(mi);
    if func_has_fn_attr(f, AK_SanitizeMemory) || func_has_fn_attr(f, AK_SanitizeAddress) { know_undef = false; }
    let removable = is_alloc_site_removable(mi, know_zero || know_undef);
    if removable < 0 { return -1; }
    // If we are removing an alloca with a dbg.declare, insert dbg.value records before each store.
    var dvrs: i32[>..<] = [];
    if is_alloca { find_dbg_users(mi, dvrs); }
    var users: i32[>..<] = [];
    for x in as_users { users.push(x); }
    for k in users.len {
        let i = users[k];
        if i < 0 || is_dead(i) { continue; }
        let id = inst_iid(i);
        if id == IID_objectsize {
            let mark = ic_inserted.len;
            let res = mb_lower_object_size_call(i, true);
            for j in mark..ic_inserted.len { icw_add(ic_inserted[j]); }
            ic_inserted.resize(mark);
            ic_replace_inst_uses_with(i, res);
            ic_erase(i);
            users[k] = -1;
            continue;
        }
        if id == IID_memcpy || id == IID_memcpy_inline || id == IID_memmove {
            if know_zero && mr_is_ref(removable) {
                let sp = icb_pos; let sb = icb_bb; let sd = icb_dl;
                icb_set_insert_point(i);
                let m = icb_memset(cb_arg(i, 0), c_int(T_I8, 0), cb_arg(i, 2), lsa_param_align(i, 0));
                inst_copy_all_md(m, i);
                icb_pos = sp; icb_bb = sb; icb_dl = sd; icb_head = false;
            }
        }
    }
    for k in users.len {
        let i = users[k];
        if i < 0 || is_dead(i) { continue; }
        if iop(i) == OP_ICMP {
            ic_replace_inst_uses_with(i, c_int_ty(vals[i].ty, if inst_pred(i) as i64 == 33 { 1 } else { 0 }));
        } else if iop(i) == OP_STORE {
            for r in dvrs { if dbgrecs[r].kind as i64 == DR_DECLARE { m2r_convert_declare_at_store(r, i); } }
        } else {
            var rep: i32 = -1;
            if iop(i) == OP_LOAD { rep = if know_undef { c_undef(vals[i].ty) } else { c_null(vals[i].ty) }; }
            else { rep = c_poison(vals[i].ty); }
            ic_replace_inst_uses_with(i, rep);
        }
        ic_erase(i);
    }
    if iop(mi) == OP_INVOKE {
        let df = au_get_declaration(IID_donothing, []);
        let fty = globs[glob_of(df)].vty;
        let ni = create_inst(OP_INVOKE, T_VOID, [invoke_normal_dest(mi), invoke_unwind_dest(mi), df]);
        insts[inst_of(ni)].ty2 = fty;
        block_append_inst(inst_parent(mi), ni);
        let dl = inst_get_md(mi, 0);
        if dl >= 0 { inst_set_md(ni, 0, dl); }
    }
    // Remove the records describing the alloca's contents: dbg.declare, and dbg.value(<alloca>, DW_OP_deref)
    for r in dvrs {
        if dbgrecs[r].dead != 0 { continue; }
        if dbgrecs[r].kind as i64 == DR_DECLARE || diexpr_starts_with_deref(dbgrecs[r].expr) { dbg_delete_record(r); }
    }
    return ic_erase(mi);
}
var ic_inserted: i32[>..<];

// tryToMoveFreeBeforeNullTest(FI, DL)
fn try_to_move_free_before_null_test(fi: i32) -> i32 {
    let opv = cb_arg(fi, 0);
    let fbb = inst_parent(fi);
    let pred = single_pred(fbb);
    if pred < 0 { return -1; }
    let term = block_terminator(fbb);
    if iop(term) != OP_BR { return -1; }
    let succ = op(term, 0);
    var n: i64 = 0;
    var i = block_first(fbb);
    while i >= 0 { n++; i = inst_next(i); }
    if n != 2 {
        i = block_first(fbb);
        while i >= 0 {
            if i != fi && i != term && inst_iid(i) != IID_pseudoprobe {
                if !is_cast_inst(i) || !lsa_is_noop_cast(i) { return -1; }
            }
            i = inst_next(i);
        }
    }
    let ti = block_terminator(pred);
    if iop(ti) != OP_CONDBR { return -1; }
    let c = op(ti, 0);
    if !is_inst_op(c, OP_ICMP) { return -1; }
    let a = op(c, 0);
    if !(a == opv || a == strip_ptr_casts(opv)) || !m_zero(op(c, 1)) { return -1; }
    let p = inst_pred(c) as i64;
    if p != 32 && p != 33 { return -1; }
    let tb = term_succ(ti, 0);
    let fb = term_succ(ti, 1);
    if succ != (if p == 32 { tb } else { fb }) { return -1; }
    i = block_first(fbb);
    while i >= 0 && i != term {
        let nx = inst_next(i);
        inst_move_before_preserving(i, ti);
        i = nx;
    }
    // remove nonnull, dereferenceable(N) -> dereferenceable_or_null(N) on the argument
    let l = insts[inst_of(fi)].attrs;
    let s = alist_param(l, 0);
    var xs: i32[>..<] = [];
    var deref: u64 = 0;
    for k in aset_n(s) {
        let at = aset_attr(s, k);
        let kind = attrs[at].kind as i64;
        if kind == AK_NonNull { continue; }
        if kind == AK_Dereferenceable { deref = attrs[at].i1; continue; }
        xs.push(at);
    }
    if deref != 0 {
        var ys: i32[>..<] = [];
        for x in xs { if attrs[x].kind as i64 != AK_DereferenceableOrNull { ys.push(x); } }
        ys.push(attr_int(AK_DereferenceableOrNull, deref));
        xs.clear();
        for y in ys { xs.push(y); }
    }
    ic_call_set_param_attrs(fi, 0, aset_get(xs));
    return fi;
}
// replace the attribute set of call parameter k
fn ic_call_set_param_attrs(ci: i32, k: i64, s: i32) {
    let ii = inst_of(ci);
    let l = insts[ii].attrs;
    let n = if l == 0 { 0 } else { alists[l].n as i64 };
    var sets: i32[>..<] = [];
    for j in max(n, k + 3) { sets.push(if j < n { alist_runs[alists[l].at + j] } else { 0 }); }
    sets[k + 2] = s;
    // trailing empty sets are dropped by alist_get
    insts[ii].attrs = alist_get(sets);
}

// visitFree(FI, Op)
fn visit_free(fi: i32, opv: i32) -> i32 {
    if is_undef_or_poison(opv) {
        ic_create_non_terminator_unreachable(fi);
        return ic_erase(fi);
    }
    if vals[opv].kind == VK_CNULL { return ic_erase(fi); }
    if is_inst_op(opv, OP_CALL) && has_one_use(opv) {
        let ro = mb_reallocated_operand(opv);
        if ro >= 0 {
            ic_replace_inst_uses_with(opv, ro);
            return ic_erase(opv);
        }
    }
    if func_has_fn_attr(inst_func(fi), AK_MinSize) {
        let cf = called_function(fi);
        if cf >= 0 {
            let lf = tli_get_libfunc(cf);
            if lf >= 0 && tli_has(lf) && lf == LF_free {
                let r = try_to_move_free_before_null_test(fi);
                if r >= 0 { return r; }
            }
        }
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// Switch

// simplifySwitchOnSelectUsingRanges(SI, Select, IsTrueArm)
fn simplify_switch_on_select_using_ranges(si: i32, sel: i32, true_arm: bool) -> i32 {
    let ci = if true_arm { 1 } else { 2 };
    let c = op(sel, ci);
    if vals[c].kind != VK_CINT || ty_is_vector(vals[c].ty) { return -1; }
    let cbb = switch_find_case_dest(si, c);
    if cbb != op(si, 1) { return -1; }
    let x = op(sel, 3 - ci);
    let cond = op(sel, 0);
    if !is_inst_op(cond, OP_ICMP) || op(cond, 0) != x { return -1; }
    let rc = m_apint(op(cond, 1));
    if rc < 0 { return -1; }
    var p = inst_pred(cond) as i64;
    if true_arm { p = pred_inverse_i(p); }
    let cr = rg_exact_icmp(p, ci_ap(rc));
    var k: i64 = 2;
    while k + 1 < nops(si) {
        if !rg_contains_ap(cr, ci_ap(op(si, k))) { return -1; }
        k += 2;
    }
    return x;
}

// visitSwitchInst(SI)
fn visit_switch(si: i32) -> i32 {
    let cond = op(si, 0);
    let n = nops(si);
    // MaybeInvertible
    var kind: i64 = 0;
    var op0: i32 = -1;
    var cc = ap_zero(1);
    if bo(cond, OP_ADD) && m_apint(op(cond, 1)) >= 0 { kind = 1; op0 = op(cond, 0); cc = ci_ap(m_apint(op(cond, 1))); }
    else if bo(cond, OP_SUB) && m_apint(op(cond, 0)) >= 0 { kind = 2; op0 = op(cond, 1); cc = ci_ap(m_apint(op(cond, 0))); }
    else if bo(cond, OP_XOR) && m_apint(op(cond, 1)) >= 0 && !ap_is_min_signed(ci_ap(m_apint(op(cond, 1)))) && !ap_is_max_signed(ci_ap(m_apint(op(cond, 1)))) {
        kind = 3; op0 = op(cond, 0); cc = ci_ap(m_apint(op(cond, 1)));
    }
    if kind != 0 && has_one_use(cond) {
        var k: i64 = 2;
        while k + 1 < n {
            let cv = ci_ap(op(si, k));
            let nv = if kind == 1 { ap_sub(cv, cc) } else if kind == 2 { ap_sub(cc, cv) } else { ap_xor(cv, cc) };
            set_op(si, k, c_int_ap(vals[op(si, k)].ty, nv));
            k += 2;
        }
        return ic_replace_operand(si, 0, op0);
    }
    if bo(cond, OP_SHL) {
        let sc = m_constant_int_u64(op(cond, 1));
        op0 = op(cond, 0);
        if sc >= 0 && sc < ty_scalar_bits(vals[op0].ty) {
            var all = true;
            var k: i64 = 2;
            while k + 1 < n { if ap_countr_zero(ci_ap(op(si, k))) < sc { all = false; } k += 2; }
            if all && (op_nuw(cond) || op_nsw(cond) || has_one_use(cond)) {
                var nc = op0;
                if !op_nuw(cond) && !op_nsw(cond) {
                    let bw = ty_scalar_bits(vals[op0].ty);
                    nc = icb_and(op0, c_int_ap(vals[op0].ty, ap_low_bits(bw, bw - sc)), "");
                }
                k = 2;
                while k + 1 < n {
                    let cv = ci_ap(op(si, k));
                    let sh = if op_nsw(cond) { ap_ashr(cv, sc) } else { ap_lshr(cv, sc) };
                    set_op(si, k, c_int_ap(vals[op(si, k)].ty, sh));
                    k += 2;
                }
                return ic_replace_operand(si, 0, nc);
            }
        }
    }
    let ze = m_zext_or_sext(cond);
    if ze >= 0 {
        let is_zext = is_inst_op(cond, OP_ZEXT);
        let nw = ty_scalar_bits(vals[ze].ty);
        var all = true;
        var k: i64 = 2;
        while k + 1 < n {
            let cv = ci_ap(op(si, k));
            if is_zext { if !ap_is_int_n(cv, nw) { all = false; } } else { if !ap_is_signed_int_n(cv, nw) { all = false; } }
            k += 2;
        }
        if all {
            k = 2;
            while k + 1 < n {
                set_op(si, k, c_int_ap(vals[ze].ty, ap_trunc(ci_ap(op(si, k)), nw)));
                k += 2;
            }
            return ic_replace_operand(si, 0, ze);
        }
    }
    if is_select_inst(cond) {
        let v1 = simplify_switch_on_select_using_ranges(si, cond, true);
        if v1 >= 0 { return ic_replace_operand(si, 0, v1); }
        let v2 = simplify_switch_on_select_using_ranges(si, cond, false);
        if v2 >= 0 { return ic_replace_operand(si, 0, v2); }
    }
    kb_cxt = si;
    let known = kb_compute_all(cond, 0);
    var lz = kb_min_lz(known);
    var lo = kb_min_lo(known);
    var k: i64 = 2;
    while k + 1 < n {
        let cv = ci_ap(op(si, k));
        lz = min(lz, ap_countl_zero(cv));
        lo = min(lo, ap_countl_one(cv));
        k += 2;
    }
    let bw = kb_bw(known);
    let new_w = bw - max(lz, lo);
    if new_w > 0 && new_w < bw && should_change_type_w(bw, new_w) {
        let ty = ty_int(new_w);
        icb_set_insert_point(si);
        let nc = icb_trunc(cond, ty, "trunc");
        k = 2;
        while k + 1 < n {
            set_op(si, k, c_int_ap(ty, ap_trunc(ci_ap(op(si, k)), new_w)));
            k += 2;
        }
        return ic_replace_operand(si, 0, nc);
    }
    if is_undef_or_poison(cond) {
        ic_handle_potentially_dead_successors(inst_parent(si), -1);
        return -1;
    }
    if vals[cond].kind == VK_CINT {
        ic_handle_potentially_dead_successors(inst_parent(si), switch_find_case_dest(si, cond));
        return -1;
    }
    return -1;
}
// m_ConstantInt(uint64_t&): a ConstantInt or splat whose value fits in 64 bits; -1 = none
fn m_constant_int_u64(v: i32) -> i64 {
    let c = m_apint(v);
    if c < 0 { return -1; }
    let a = ci_ap(c);
    if ap_active_bits(a) > 64 { return -1; }
    let x = ap_zext64(a);
    if x > 0x7FFFFFFFFFFFFFFF { return -1; }
    return x as i64;
}

// ---------------------------------------------------------------------------------------------
// extractvalue

fn ev_nidx(i: i32) -> i64 { insts[inst_of(i)].naux as i64 }
fn ev_idx(i: i32, k: i64) -> i32 { ints[insts[inst_of(i)].aux + k] }

// WithOverflowInst: the six *.with.overflow intrinsics
fn is_with_overflow_iid(id: i32) -> bool {
    return id == IID_sadd_with_overflow || id == IID_uadd_with_overflow || id == IID_ssub_with_overflow ||
           id == IID_usub_with_overflow || id == IID_smul_with_overflow || id == IID_umul_with_overflow;
}
fn wo_binop(id: i32) -> i64 {
    if id == IID_sadd_with_overflow || id == IID_uadd_with_overflow { return OP_ADD; }
    if id == IID_ssub_with_overflow || id == IID_usub_with_overflow { return OP_SUB; }
    return OP_MUL;
}
fn wo_signed(id: i32) -> bool { id == IID_sadd_with_overflow || id == IID_ssub_with_overflow || id == IID_smul_with_overflow }

// foldExtractOfOverflowIntrinsic(EV)
fn fold_extract_of_overflow_intrinsic(ev: i32) -> i32 {
    let wo = op(ev, 0);
    let id = inst_iid(wo);
    if !is_with_overflow_iid(id) { return -1; }
    let lhs = cb_arg(wo, 0);
    let rhs = cb_arg(wo, 1);
    let c = m_apint_ap(rhs, true);
    if c >= 0 {
        let ca = ci_ap(c);
        if ev_idx(ev, 0) == 0 && (id == IID_smul_with_overflow || id == IID_umul_with_overflow) {
            if ap_is_all_ones(ca) { return ic_new_neg(lhs); }
            if ap_is_pow2(ca) { return ic_new_binop(OP_SHL, lhs, c_int_ty(vals[lhs].ty, ap_log2(ca) as u64)); }
        }
    }
    if !has_one_use(wo) { return -1; }
    if ev_idx(ev, 0) == 0 {
        let b = wo_binop(id);
        ic_replace_inst_uses_with(wo, c_poison(vals[wo].ty));
        ic_erase(wo);
        return ic_new_binop(b, lhs, rhs);
    }
    if id == IID_usub_with_overflow { return ic_new_icmp(36, lhs, rhs); }
    if id == IID_smul_with_overflow && is_int_ty1(vals[lhs].ty) { return ic_new_binop(OP_AND, lhs, rhs); }
    if id == IID_umul_with_overflow && lhs == rhs {
        let bw = ty_scalar_bits(vals[lhs].ty);
        if bw % 2 == 0 { return ic_new_icmp(34, lhs, c_int_ap(vals[lhs].ty, ap_low_bits(bw, bw / 2))); }
    }
    if c >= 0 {
        let ca = ci_ap(c);
        let nwr = rg_exact_no_wrap(wo_binop(id), ca, if wo_signed(id) { 2 } else { 1 });
        let p, nrhs, off = rg_equivalent_icmp_off(nwr);
        let opty = vals[rhs].ty;
        var nl = lhs;
        if !ap_is_zero(off) { nl = icb_add(nl, c_int_ap(opty, off), ""); }
        return ic_new_icmp(pred_inverse_i(p), nl, c_int_ap(opty, nrhs));
    }
    return -1;
}

// foldFrexpOfSelect(EV, FrexpCall, SelectInst, Builder)
fn fold_frexp_of_select(ev: i32, fc: i32, sel: i32) -> i32 {
    if !has_one_use(sel) || !has_one_use(fc) { return -1; }
    let cond = op(sel, 0);
    let tv = op(sel, 1);
    let fv = op(sel, 2);
    var cv: i32 = -1;
    var varop: i32 = -1;
    var const_true = false;
    if m_apfloat(tv) >= 0 { cv = m_apfloat(tv); varop = fv; const_true = true; }
    else if m_apfloat(fv) >= 0 { cv = m_apfloat(fv); varop = tv; const_true = false; }
    else { return -1; }
    icb_set_insert_point(ev);
    let cf = called_function(fc);
    let nf = icb_insert(lsa_new_call_like(fc, [varop]), "frexp");
    copy_ir_flags(nf, fc);
    let nev = icb_extract_value(nf, [0], "mantissa");
    let mant, fexp = cf_frexp_scalar(cv, T_I32);
    let cm = c_splat_if_vector(vals[tv].ty, mant);
    let sp = icb_fmf;
    icb_fmf = if is_fp_math_operator(sel) { insts[inst_of(sel)].fmf } else { 0 };
    let ns = icb_select(cond, if const_true { cm } else { nev }, if const_true { nev } else { cm }, "select.frexp", sel);
    icb_fmf = sp;
    return ns;
}
// Builder.CreateCall(F, Args): a call of the same callee as `like`
fn lsa_new_call_like(like: i32, argsv: const i32[:]) -> i32 {
    let f = called_function(like);
    let fty = globs[glob_of(f)].vty;
    var opsv: i32[>..<] = [];
    for a in argsv { opsv.push(a); }
    opsv.push(f);
    let iv = create_inst(OP_CALL, ty_fn_ret(fty), opsv);
    insts[inst_of(iv)].ty2 = fty;
    return iv;
}
fn c_splat_if_vector(t: i32, s: i32) -> i32 { if ty_is_vector(t) { c_splat(t, s) } else { s } }

// visitExtractValueInst(EV)
fn visit_extract_value(ev: i32) -> i32 {
    let agg = op(ev, 0);
    let ne = ev_nidx(ev);
    if ne == 0 { return ic_replace_inst_uses_with(ev, agg); }
    let sv = simplify_extractvalue(ev, agg, sq_at(ev));
    if sv >= 0 { return ic_replace_inst_uses_with(ev, sv); }
    if ne == 1 && ev_idx(ev, 0) == 0 && inst_iid(agg) == IID_frexp && is_select_inst(cb_arg(agg, 0)) {
        let r = fold_frexp_of_select(ev, agg, cb_arg(agg, 0));
        if r >= 0 { return ic_replace_inst_uses_with(ev, r); }
    }
    var eidx: i32[>..<] = [];
    for k in ne { eidx.push(ev_idx(ev, k)); }
    if is_inst_op(agg, OP_INSERTVALUE) {
        let ni = ev_nidx(agg);
        var k: i64 = 0;
        while k < ne && k < ni {
            if ev_idx(agg, k) != eidx[k] { return ic_new_extract_value(op(agg, 0), eidx); }
            k++;
        }
        if k == ne && k == ni { return ic_replace_inst_uses_with(ev, op(agg, 1)); }
        if k == ne {
            let nev = icb_extract_value(op(agg, 0), eidx, "");
            var rest: i32[>..<] = [];
            for j in k..ni { rest.push(ev_idx(agg, j)); }
            return ic_new_insert_value(nev, op(agg, 1), rest);
        }
        if k == ni {
            var rest: i32[>..<] = [];
            for j in k..ne { rest.push(eidx[j]); }
            return ic_new_extract_value(op(agg, 1), rest);
        }
    }
    let ro = fold_extract_of_overflow_intrinsic(ev);
    if ro >= 0 { return ro; }
    if is_inst_op(agg, OP_LOAD) {
        if ty_is_struct(vals[agg].ty) && ty_contains_scalable(vals[agg].ty) { return -1; }
        if ld_is_simple(agg) && has_one_use(agg) {
            var idx: i32[>..<] = [];
            idx.push(c_int(T_I32, 0));
            for x in eidx { idx.push(c_int(T_I32, x as i64)); }
            icb_set_insert_point(agg);
            let gp = icb_gep(vals[agg].ty, op(agg, 0), idx, "", GEP_INBOUNDS | GEP_NUSW);
            let nl = icb_load(vals[ev].ty, gp, "");
            lsa_copy_aa_metadata(nl, agg);
            return ic_replace_inst_uses_with(ev, nl);
        }
    }
    if is_phi_inst(agg) {
        let r = fold_op_into_phi(ev, agg, false);
        if r >= 0 { return r; }
    }
    if is_select_inst(agg) {
        let r = fold_op_into_select(ev, agg, true, false);
        if r >= 0 { return r; }
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// landingpad

let EHP_UNKNOWN = 0;
let EHP_GNU_ADA = 1;
let EHP_GNU_C = 2;
let EHP_GNU_C_SJLJ = 3;
let EHP_GNU_CXX = 4;
let EHP_GNU_CXX_SJLJ = 5;
let EHP_GNU_OBJC = 6;
let EHP_MSVC_X86SEH = 7;
let EHP_MSVC_TABLESEH = 8;
let EHP_MSVC_CXX = 9;
let EHP_CORECLR = 10;
let EHP_RUST = 11;
let EHP_WASM_CXX = 12;
let EHP_XL_CXX = 13;
let EHP_ZOS_CXX = 14;

// classifyEHPersonality(Pers)
fn classify_eh_personality(fv: i32) -> i64 {
    if globs[glob_of(fv)].has_personality == 0 { return EHP_UNKNOWN; }
    var p = op(fv, 0);
    // Pers->stripPointerCasts()
    p = strip_ptr_casts(p);
    if !is_func(p) || vals[p].name < 0 { return EHP_UNKNOWN; }
    let nm = sbytes(vals[p].name);
    if nm == "__gnat_eh_personality" { return EHP_GNU_ADA; }
    if nm == "__gcc_personality_v0" { return EHP_GNU_C; }
    if nm == "__gcc_personality_seh0" { return EHP_GNU_C; }
    if nm == "__gcc_personality_sj0" { return EHP_GNU_C_SJLJ; }
    if nm == "__gxx_personality_v0" { return EHP_GNU_CXX; }
    if nm == "__gxx_personality_seh0" { return EHP_GNU_CXX; }
    if nm == "__gxx_personality_sj0" { return EHP_GNU_CXX_SJLJ; }
    if nm == "__gxx_wasm_personality_v0" { return EHP_WASM_CXX; }
    if nm == "__objc_personality_v0" { return EHP_GNU_OBJC; }
    if nm == "_except_handler3" { return EHP_MSVC_X86SEH; }
    if nm == "_except_handler4" { return EHP_MSVC_X86SEH; }
    if nm == "__C_specific_handler" { return EHP_MSVC_TABLESEH; }
    if nm == "__CxxFrameHandler3" { return EHP_MSVC_CXX; }
    if nm == "ProcessCLRException" { return EHP_CORECLR; }
    if nm == "rust_eh_personality" { return EHP_RUST; }
    if nm == "__xlcxx_personality_v1" { return EHP_XL_CXX; }
    if nm == "__zos_cxx_personality_v2" { return EHP_ZOS_CXX; }
    return EHP_UNKNOWN;
}
// isCatchAll(Personality, TypeInfo)
fn is_catch_all(pers: i64, ti: i32) -> bool {
    if pers == EHP_GNU_C || pers == EHP_GNU_C_SJLJ || pers == EHP_RUST || pers == EHP_UNKNOWN || pers == EHP_GNU_ADA { return false; }
    return vals[ti].kind == VK_CNULL;
}
fn lp_is_cleanup(i: i32) -> bool { (insts[inst_of(i)].bits & 1) != 0 }
fn lp_is_filter_ty(t: i32) -> bool { ty_is_array(t) }
fn shorter_filter(a: i32, b: i32) -> bool { ty_count(vals[a].ty) < ty_count(vals[b].ty) }

// visitLandingPadInst(LI)
fn visit_landingpad(li: i32) -> i32 {
    let pers = classify_eh_personality(inst_func(li));
    var make_new = false;
    var nc: i32[>..<] = [];
    var cleanup = lp_is_cleanup(li);
    var caught: i32[>..<] = [];
    let e = nops(li);
    for i in e {
        let is_last = i + 1 == e;
        let cl = op(li, i);
        if !lp_is_filter_ty(vals[cl].ty) {
            let ti = strip_ptr_casts(cl);
            if position(caught, ti) < 0 {
                caught.push(ti);
                nc.push(cl);
            } else {
                make_new = true;
            }
            if is_catch_all(pers, ti) {
                if !is_last { make_new = true; }
                cleanup = false;
                break;
            }
        } else {
            var fc = cl;
            let fty = vals[cl].ty;
            let nti = ty_count(fty);
            if nti == 0 {
                nc.push(fc);
                if !is_last { make_new = true; }
                cleanup = false;
                break;
            }
            var make_filter = false;
            var nfe: i32[>..<] = [];
            if vals[fc].kind == VK_AGGZERO {
                let ti = c_null(ty_elem(fty));
                if is_catch_all(pers, ti) { make_new = true; continue; }
                nfe.push(ti);
                if nti > 1 { make_filter = true; }
            } else {
                var seen: i32[>..<] = [];
                var saw_all = false;
                for j in nti {
                    let elt = agg_elem(fc, j);
                    let ti = strip_ptr_casts(elt);
                    if is_catch_all(pers, ti) { saw_all = true; break; }
                    if position(seen, ti) < 0 { seen.push(ti); nfe.push(elt); }
                }
                if saw_all { make_new = true; continue; }
                if nfe.len < nti { make_filter = true; }
            }
            if make_filter {
                let nft = ty_array(ty_elem(fty), nfe.len);
                fc = c_aggregate(nft, nfe);
                make_new = true;
            }
            nc.push(fc);
            if make_filter && nfe.len == 0 {
                cleanup = false;
                break;
            }
        }
    }
    // sort runs of filters by length (stable)
    var i: i64 = 0;
    while i + 1 < nc.len {
        var j = i;
        while j != nc.len { if !lp_is_filter_ty(vals[nc[j]].ty) { break; } j++; }
        for k in i..j {
            if k + 1 < j && shorter_filter(nc[k + 1], nc[k]) {
                // std::stable_sort of [i, j)
                var a = i + 1;
                while a < j {
                    let x = nc[a];
                    var b = a;
                    while b > i && shorter_filter(x, nc[b - 1]) { nc[b] = nc[b - 1]; b--; }
                    nc[b] = x;
                    a++;
                }
                make_new = true;
                break;
            }
        }
        i = j + 1;
    }
    // remove later filters that are supersets of earlier ones
    i = 0;
    while i + 1 < nc.len {
        let filter = nc[i];
        let fty = vals[filter].ty;
        if !lp_is_filter_ty(fty) { i++; continue; }
        let fe = ty_count(fty);
        var j = nc.len - 1;
        while j != i {
            let lf = nc[j];
            let lty = vals[lf].ty;
            if !lp_is_filter_ty(lty) { j--; continue; }
            if fe == 0 { nc_erase(nc, j); make_new = true; j--; continue; }
            let le = ty_count(lty);
            if fe > le { j--; continue; }
            if vals[lf].kind == VK_AGGZERO {
                if vals[filter].kind == VK_AGGZERO { nc_erase(nc, j); make_new = true; }
                j--;
                continue;
            }
            if vals[filter].kind == VK_AGGZERO {
                for l in le {
                    if vals[agg_elem(lf, l)].kind == VK_CNULL { nc_erase(nc, j); make_new = true; break; }
                }
                j--;
                continue;
            }
            var all_found = true;
            for f in fe {
                let ft = strip_ptr_casts(agg_elem(filter, f));
                all_found = false;
                for l in le {
                    if strip_ptr_casts(agg_elem(lf, l)) == ft { all_found = true; break; }
                }
                if !all_found { break; }
            }
            if all_found { nc_erase(nc, j); make_new = true; }
            j--;
        }
        i++;
    }
    if make_new {
        let nli = create_inst(OP_LANDINGPAD, vals[li].ty, nc);
        if nc.len == 0 { cleanup = true; }
        insts[inst_of(nli)].bits = if cleanup { 1 } else { 0 };
        return nli;
    }
    if lp_is_cleanup(li) != cleanup {
        insts[inst_of(li)].bits = if cleanup { 1 } else { 0 };
        return li;
    }
    return -1;
}
fn nc_erase(xs: i32[>..<]&, j: i64) {
    var k = j;
    while k + 1 < xs.len { xs[k] = xs[k + 1]; k++; }
    xs.pop();
}

// ---------------------------------------------------------------------------------------------
// freeze

// pushFreezeToPreventPoisonFromPropagating(OrigFI)
fn push_freeze_to_prevent_poison(fi: i32) -> i32 {
    let orig = op(fi, 0);
    if !is_inst(orig) || !has_one_use(orig) || is_phi_inst(orig) { return -1; }
    if can_create_undef_or_poison(orig, false) { return -1; }
    var maybe: i32 = -1;
    for k in nops(orig) {
        let v = op(orig, k);
        if vals[v].kind == VK_MDVAL || is_guaranteed_not_to_be_undef_or_poison(v, -1, 0) || (maybe >= 0 && maybe == v) { continue; }
        if maybe < 0 { maybe = v; } else { return -1; }
    }
    drop_poison_generating_annotations(orig);
    if maybe < 0 { return orig; }
    icb_set_insert_point(orig);
    var nm: u8[>..] = [];
    nm.append(val_name(maybe));
    nm.append(".fr");
    let fr = icb_freeze(maybe, nm);
    replace_uses_of_with(orig, maybe, fr);
    return orig;
}

// foldFreezeIntoRecurrence(FI, PN)
fn fold_freeze_into_recurrence(fi: i32, pn: i32) -> i32 {
    var start_k: i64 = -1;
    var wl: i32[>..<] = [];
    let fv = inst_func(pn);
    for k in nops(pn) {
        if dt_dominates_block(DT_DOM, inst_parent(pn), phi_block(pn, k)) {
            wl.push(op(pn, k));
            continue;
        }
        if start_k >= 0 { return -1; }
        start_k = k;
    }
    if start_k < 0 || wl.len == 0 { return -1; }
    let sv = op(pn, start_k);
    let sbb = phi_block(pn, start_k);
    let needs = !is_guaranteed_not_to_be_undef_or_poison(sv, -1, 0);
    if needs && block_terminator(sbb) == sv { return -1; }
    var visited: i32[>..<] = [];
    var drop: i32[>..<] = [];
    while wl.len > 0 {
        let v = wl.pop();
        if position(visited, v) >= 0 { continue; }
        visited.push(v);
        if visited.len > 32 { return -1; }
        if v == pn || is_guaranteed_not_to_be_undef_or_poison(v, -1, 0) { continue; }
        if !is_inst(v) || can_create_undef_or_poison(v, false) { return -1; }
        drop.push(v);
        for k in nops(v) { wl.push(op(v, k)); }
    }
    for i in drop { drop_poison_generating_annotations(i); }
    if needs {
        icb_set_insert_point(block_terminator(sbb));
        var nm: u8[>..] = [];
        nm.append(val_name(sv));
        nm.append(".fr");
        let fr = icb_freeze(sv, nm);
        ic_replace_use(vals[pn].ops + start_k as i32, fr);
    }
    return ic_replace_inst_uses_with(fi, pn);
}

// freezeOtherUses(FI)
fn freeze_other_uses(fi: i32) -> bool {
    let opv = op(fi, 0);
    if is_constant(opv) || has_one_use(opv) { return false; }
    var move_before: i32 = -1;
    if is_arg(opv) {
        move_before = first_non_phi_or_dbg_or_alloca(func_entry(inst_func(fi)));
    } else {
        move_before = insertion_point_after_def(opv);
        if move_before < 0 { return false; }
    }
    // MoveBefore.setHeadBit(false): after any debug records there
    var changed = false;
    if fi != move_before {
        inst_move_before(fi, move_before);
        changed = true;
    }
    var users: i32[>..<] = [];
    var u = first_use(opv);
    let fv = inst_func(fi);
    while u >= 0 {
        let us = use_user(u);
        let nu = use_next(u);
        if us != fi && dt_dominates_use(fv, fi, u) {
            users.push(us);
            use_set(u, fi);
            changed = true;
        }
        u = nu;
    }
    for x in users {
        icw_push_users(x);
        icw_push(x);
    }
    return changed;
}
// BasicBlock::getFirstNonPHIOrDbgOrAlloca
fn first_non_phi_or_dbg_or_alloca(bb: i32) -> i32 {
    var i = first_insertion_pt(bb);
    if i < 0 { return -1; }
    if inst_is_eh_pad(i) { i = inst_next(i); }
    if bb == func_entry(block_func(bb)) {
        while i >= 0 && (iop(i) == OP_ALLOCA || ld_is_debug_or_pseudo(i)) {
            if iop(i) == OP_ALLOCA && !ml_is_static_alloca(i) { break; }
            i = inst_next(i);
        }
    }
    return i;
}
// Instruction::getInsertionPointAfterDef: -1 = none
fn insertion_point_after_def(i: i32) -> i32 {
    let o = iop(i);
    if o == OP_PHI { return first_insertion_pt(inst_parent(i)); }
    if o == OP_INVOKE { return first_insertion_pt(invoke_normal_dest(i)); }
    if o == OP_CALLBR { return -1; }
    return inst_next(i);
}
// DominatorTree::dominates(Def, Use)
fn dt_dominates_use(fv: i32, def: i32, u: i32) -> bool {
    let user = use_user(u);
    if !is_inst(user) { return false; }
    var ubb = inst_parent(user);
    if iop(user) == OP_PHI {
        let k = (u - vals[user].ops) as i64;
        ubb = phi_block(user, k);
        // dominates(Def, edge end): Def's block dominates the incoming block's end
        let dbb = inst_parent(def);
        if dbb == ubb { return true; }
        return dt_dominates_block(DT_DOM, dbb, ubb);
    }
    let dbb = inst_parent(def);
    if dbb != ubb { return dt_dominates_block(DT_DOM, dbb, ubb); }
    if iop(def) == OP_PHI { return true; }
    return comes_before(def, user);
}

// isUsedWithinShuffleVector(V)
recursive fn is_used_within_shuffle_vector(v: i32) -> bool {
    var u = first_use(v);
    while u >= 0 {
        let us = use_user(u);
        u = use_next(u);
        if is_inst_op(us, OP_SHUFFLEVECTOR) { return true; }
        if is_op(us, OP_BITCAST) && op(us, 0) == v && is_used_within_shuffle_vector(us) { return true; }
    }
    return false;
}

// visitFreeze(I)
fn visit_freeze(i: i32) -> i32 {
    let op0 = op(i, 0);
    let sv = simplify_freeze(op0, sq_at(i));
    if sv >= 0 { return ic_replace_inst_uses_with(i, sv); }
    if is_phi_inst(op0) {
        let r1 = fold_op_into_phi(i, op0, false);
        if r1 >= 0 { return r1; }
        let r2 = fold_freeze_into_recurrence(i, op0);
        if r2 >= 0 { return r2; }
    }
    let ni = push_freeze_to_prevent_poison(i);
    if ni >= 0 { return ic_replace_inst_uses_with(i, ni); }
    if m_undef(op0) {
        if is_used_within_shuffle_vector(i) { return -1; }
        return ic_replace_inst_uses_with(i, freeze_undef_replacement(i));
    }
    if is_constant(op0) && contains_undef_or_poison_element(op0) && !contains_constant_expression(op0) {
        let t = vals[op0].ty;
        if ty_kind(t) == TK_FVEC {
            var best: i32 = -1;
            for k in ty_count(t) {
                let e = agg_elem(op0, k);
                if e >= 0 && !m_undef(e) { best = e; break; }
            }
            if best < 0 { best = c_null(ty_scalar(t)); }
            return ic_replace_inst_uses_with(i, replace_undefs_with(op0, best));
        }
    }
    if freeze_other_uses(i) { return i; }
    return -1;
}
// getUndefReplacement(Ty) of visitFreeze
fn freeze_undef_replacement(i: i32) -> i32 {
    let ty = vals[i].ty;
    let nullv = c_null(ty);
    var best: i32 = -1;
    var u = first_use(i);
    while u >= 0 {
        let us = use_user(u);
        u = use_next(u);
        var v = nullv;
        if bo(us, OP_OR) {
            v = c_all_ones(ty);
        } else if is_select_inst(us) && op(us, 0) == i && is_constant(op(us, 1)) {
            v = c_int_ty(ty, 1);
        } else if is_select_inst(us) && (op(us, 1) == i || op(us, 2) == i) {
            // m_c_Select(m_Specific(&I), m_Value(V))
            v = if op(us, 1) == i { op(us, 2) } else { op(us, 1) };
            kb_cxt = i;
            if v == i || !is_guaranteed_not_to_be_undef_or_poison(v, i, 0) { v = nullv; }
        } else if is_phi_inst(us) {
            let mv = pick_common_constant_from_phi(us);
            if mv >= 0 { v = mv; }
        }
        if best < 0 { best = v; } else if best != v { best = nullv; }
    }
    return best;
}
fn pick_common_constant_from_phi(pn: i32) -> i32 {
    var best: i32 = -1;
    for k in nops(pn) {
        let v = op(pn, k);
        if is_inst_op(v, OP_FREEZE) && m_undef(op(v, 0)) { continue; }
        if !is_constant(v) { return -1; }
        if !is_guaranteed_not_to_be_undef_or_poison(v, -1, 0) { return -1; }
        if best >= 0 && best != v { return -1; }
        best = v;
    }
    return best;
}

// getSafeVectorConstantForBinop(Opcode, In, IsRHSConstant) (InstCombiner.h)
fn safe_vector_constant_for_binop(o: i64, c: i32, is_rhs: bool) -> i32 {
    let vt = vals[c].ty;
    let et = ty_elem(vt);
    var safe = binop_identity(o, et, is_rhs);
    if safe < 0 {
        if is_rhs {
            if o == OP_SREM || o == OP_UREM { safe = c_int_ty(et, 1); }
            else if o == OP_FREM { safe = c_fp_one_ty(et); }
            else { fatal("internal: getSafeVectorConstantForBinop: only rem opcodes have no identity constant for RHS"); }
        } else {
            safe = c_null(et);
        }
    }
    var out: i32[>..<] = [];
    for k in ty_count(vt) {
        let e = agg_elem(c, k);
        out.push(if is_undef_or_poison(e) { safe } else { e });
    }
    return c_aggregate(vt, out);
}
fn contains_constant_expression(c: i32) -> bool { vec_contains_kind(c, 2) }

// SimplifyDemandedVectorElts(V, Demanded, PoisonElts, Depth = 0, AllowMultipleUsers)
fn ic_sdve(v: i32, demanded: AP, allow_multi: bool) -> i32 {
    let r, pe = ic_simplify_demanded_vector_elts(v, demanded, 0, allow_multi);
    return r;
}
