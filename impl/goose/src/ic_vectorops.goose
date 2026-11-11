// Port of llvm/lib/Transforms/InstCombine/InstCombineVectorOps.cpp, whole, in file order: cheapToScalarize,
// scalarizePHI, foldBitcastExtElt, findDemandedEltsBySingleUser, findDemandedEltsByAllUsers,
// getPreferredVectorIndex, visitExtractElementInst, collectSingleShuffleElements, replaceExtractElements,
// collectShuffleElements, foldAggregateConstructionIntoAggregateReuse, visitInsertValueInst,
// isShuffleEquivalentToSelect, foldInsSequenceIntoSplat, foldInsEltIntoSplat, foldInsEltIntoIdentityShuffle,
// hoistInsEltConst, foldConstantInsEltIntoShuffle, narrowInsElt, foldTruncInsEltPair, visitInsertElementInst,
// canEvaluateShuffled, buildNew, evaluateInDifferentElementOrder, isShuffleExtractingFromLHS,
// getAlternateBinop, foldSelectShuffleOfSelectShuffle, foldSelectShuffleWith1Binop, canonicalizeInsertSplat,
// foldSelectShuffle, foldTruncShuffle, narrowVectorSelect, foldShuffleOfUnaryOps, foldCastShuffle,
// foldIdentityExtractShuffle, foldShuffleWithInsert, foldIdentityPaddedShuffles, simplifyBinOpSplats,
// visitShuffleVectorInst, foldExtractionOfVectorDeinterleave.
// The ShuffleVectorInst mask predicates (llvm/lib/IR/Instructions.cpp) and getSplatIndex /
// scaleShuffleMaskElts / createUnaryMask (llvm/lib/Analysis/VectorUtils.cpp) are here too.
//
// Masks live in the `ints` pool (Inst.aux/naux). Every function that builds instructions first copies the
// masks it reads into a local array: creating a shuffle appends to the pool.
namespace ic;
import std;
import ir;
import cfgutil;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import intrinsics;
import datalayout;
import apint;
import pm;
import vt;
import local;
import knownbits;
import poison;
import fpclass;
import cfold;
import constfold;
import instsimplify;
import instident;
import domcond;
import flags;
import ic;
import ic_builder;
import ic_common;
import ic_combining;
import ic_casts;
import ic_select;
import ic_loadstorealloca;
import ic_demanded_elts;
import ic_phi;
import ic_compares;
import loads;

// ---------------------------------------------------------------------------------------------
// Mask predicates

fn sv_mask(s: i32, out: i32[>..<]&) { shuf_mask_copy(s, out); }
fn sv_mask_at(s: i32, k: i64) -> i64 { ints[insts[inst_of(s)].aux + k] as i64 }
fn sv_nmask(s: i32) -> i64 { insts[inst_of(s)].naux as i64 }
fn sv_nop_elts(s: i32) -> i64 { ty_count(vals[op(s, 0)].ty) }
fn sv_scalable(s: i32) -> bool { ty_kind(vals[s].ty) == TK_SVEC }

fn mask_is_single_source_impl(m: const i32[:], n: i64) -> bool {
    var l = false;
    var r = false;
    for x in m {
        if x == -1 { continue; }
        if (x as i64) < n { l = true; } else { r = true; }
        if l && r { return false; }
    }
    return l || r;
}
fn mask_is_identity_impl(m: const i32[:], n: i64) -> bool {
    if !mask_is_single_source_impl(m, n) { return false; }
    for i in m.len {
        if m[i] == -1 { continue; }
        if (m[i] as i64) != i && (m[i] as i64) != n + i { return false; }
    }
    return true;
}
fn mask_is_identity(m: const i32[:], n: i64) -> bool { m.len == n && mask_is_identity_impl(m, n) }
fn mask_is_select(m: const i32[:], n: i64) -> bool {
    if m.len != n { return false; }
    if mask_is_single_source_impl(m, n) { return false; }
    for i in m.len {
        if m[i] == -1 { continue; }
        if (m[i] as i64) != i && (m[i] as i64) != n + i { return false; }
    }
    return true;
}
fn mask_is_zero_elt_splat(m: const i32[:], n: i64) -> bool {
    if m.len != n { return false; }
    if !mask_is_single_source_impl(m, n) { return false; }
    for x in m { if x == -1 { continue; } if x != 0 && (x as i64) != n { return false; } }
    return true;
}
fn sv_changes_length(s: i32) -> bool { sv_nop_elts(s) != sv_nmask(s) }
fn shuf_is_select(s: i32) -> bool {
    var m: i32[>..<] = [];
    sv_mask(s, m);
    return !sv_changes_length(s) && mask_is_select(m, m.len);
}
fn sv_is_zero_elt_splat(s: i32) -> bool {
    var m: i32[>..<] = [];
    sv_mask(s, m);
    return !sv_changes_length(s) && mask_is_zero_elt_splat(m, m.len);
}
fn sv_is_identity_with_padding(s: i32) -> bool {
    if sv_scalable(s) { return false; }
    let no = sv_nop_elts(s);
    let nm = sv_nmask(s);
    if nm <= no { return false; }
    var m: i32[>..<] = [];
    sv_mask(s, m);
    if !mask_is_identity_impl(m, no) { return false; }
    for i in no..nm { if m[i] != -1 { return false; } }
    return true;
}
fn sv_is_identity_with_extract(s: i32) -> bool {
    if sv_scalable(s) { return false; }
    let no = sv_nop_elts(s);
    let nm = sv_nmask(s);
    if nm >= no { return false; }
    var m: i32[>..<] = [];
    sv_mask(s, m);
    return mask_is_identity_impl(m, no);
}
fn shuf_is_concat(s: i32) -> bool {
    if is_undef_or_poison(op(s, 0)) || is_undef_or_poison(op(s, 1)) { return false; }
    if sv_scalable(s) { return false; }
    let no = sv_nop_elts(s);
    let nm = sv_nmask(s);
    if nm != no * 2 { return false; }
    var m: i32[>..<] = [];
    sv_mask(s, m);
    return mask_is_identity_impl(m, nm);
}
fn mask_is_deinterleave_of_factor(m: const i32[:], factor: i64) -> bool, i64 {
    for idx in factor {
        var i: i64 = 0;
        while i < m.len {
            if m[i] >= 0 && (m[i] as i64) != idx + i * factor { break; }
            i++;
        }
        if i == m.len { return true, idx; }
    }
    return false, 0;
}
fn commute_shuffle_mask(m: i32[>..<]&, n: i64) {
    for i in m.len {
        if m[i] == -1 { continue; }
        m[i] = if (m[i] as i64) < n { m[i] + n as i32 } else { m[i] - n as i32 };
    }
}
// getSplatIndex(Mask)
fn get_splat_index(m: const i32[:]) -> i64 {
    var si: i64 = -1;
    for x in m {
        if x < 0 { continue; }
        if si != -1 && si != x as i64 { return -1; }
        si = x as i64;
    }
    return si;
}
// createUnaryMask(Mask, NumElts)
fn create_unary_mask(m: const i32[:], n: i64, out: i32[>..<]&) {
    out.clear();
    for x in m { out.push(if (x as i64) >= n { x - n as i32 } else { x }); }
}
// scaleShuffleMaskElts(NumDstElts, Mask, ScaledMask)
fn scale_shuffle_mask_elts(ndst: i64, m: const i32[:], out: i32[>..<]&) -> bool {
    out.clear();
    let nsrc = m.len;
    if nsrc == ndst { for x in m { out.push(x); } return true; }
    if nsrc > ndst {
        let scale = nsrc / ndst;
        if nsrc % scale != 0 { return false; }
        var i: i64 = 0;
        while i < nsrc {
            let front = m[i];
            if front < 0 {
                for j in scale { if m[i + j] != front { return false; } }
                out.push(front);
            } else {
                if (front as i64) % scale != 0 { return false; }
                for j in 1..scale { if (m[i + j] as i64) != (front as i64) + j { return false; } }
                out.push(((front as i64) / scale) as i32);
            }
            i += scale;
        }
        return true;
    }
    let scale = ndst / nsrc;
    for x in m {
        for j in scale { out.push(if x < 0 { x } else { (scale * (x as i64) + j) as i32 }); }
    }
    return true;
}
fn masks_equal(a: const i32[:], b: const i32[:]) -> bool {
    if a.len != b.len { return false; }
    for i in a.len { if a[i] != b[i] { return false; } }
    return true;
}
fn mask_contains(m: const i32[:], x: i32) -> bool { for y in m { if y == x { return true; } } return false; }
fn mask_is_zero(m: const i32[:]) -> bool { for x in m { if x != 0 && x != -1 { return false; } } return true; }
// m_ZeroMask: all elements 0 or poison (-1)
fn sv_has_zero_mask(s: i32) -> bool {
    let x = insts[inst_of(s)];
    for k in x.naux { let v = ints[x.aux + k]; if v != 0 && v != -1 { return false; } }
    return true;
}

// commute(): swap operands and adjust the mask in place
fn sv_commute(s: i32) {
    let n = sv_nop_elts(s);
    var m: i32[>..<] = [];
    sv_mask(s, m);
    commute_shuffle_mask(m, n);
    let at = ints.len as i32;
    for x in m { ints.push(x); }
    insts[inst_of(s)].aux = at;
    // Op<0>().swap(Op<1>()): Use::swap keeps the use-list positions
    let u0 = vals[s].ops;
    cu_use_swap(u0, u0 + 1);
}

// ---------------------------------------------------------------------------------------------
// extractelement

// cheapToScalarize(V, EI)
recursive fn cheap_to_scalarize(v: i32, ei: i32) -> bool {
    let cei = m_constant_int(ei);
    if is_constant(v) { return cei >= 0 || splat_value(v, false) >= 0; }
    if cei >= 0 && inst_iid(v) == IID_stepvector {
        return ap_ult_u64(ci_ap(cei), ty_count(vals[v].ty) as u64);
    }
    if is_inst_op(v, OP_INSERTELEMENT) && m_constant_int(op(v, 2)) >= 0 { return cei >= 0; }
    if is_inst_op(v, OP_LOAD) && has_one_use(v) { return true; }
    if is_inst_op(v, OP_FNEG) && has_one_use(v) { return true; }
    if is_binop_inst(v) && has_one_use(v) {
        if cheap_to_scalarize(op(v, 0), ei) || cheap_to_scalarize(op(v, 1), ei) { return true; }
    }
    if is_cmp_inst(v) && has_one_use(v) {
        if cheap_to_scalarize(op(v, 0), ei) || cheap_to_scalarize(op(v, 1), ei) { return true; }
    }
    return false;
}

// scalarizePHI(EI, PN)
fn scalarize_phi(ei: i32, pn: i32) -> i32 {
    var extracts: i32[>..<] = [];
    var phi_user: i32 = -1;
    var u = first_use(pn);
    while u >= 0 {
        let us = use_user(u);
        u = use_next(u);
        if is_inst_op(us, OP_EXTRACTELEMENT) {
            if op(ei, 1) == op(us, 1) { extracts.push(us); } else { return -1; }
        } else if phi_user < 0 {
            phi_user = us;
        } else {
            return -1;
        }
    }
    if phi_user < 0 { return -1; }
    if !has_one_use(phi_user) || use_user(first_use(phi_user)) != pn || !is_binop_inst(phi_user) ||
       !cheap_to_scalarize(phi_user, op(ei, 1)) { return -1; }
    let sphi = ic_insert_new_with(create_inst(OP_PHI, vals[ei].ty, []), pn);
    var seen_bb: i32[>..<] = [];
    var seen_v: i32[>..<] = [];
    for i in nops(pn) {
        let inv = op(pn, i);
        let inbb = phi_block(pn, i);
        let elt = op(ei, 1);
        let ex = position(seen_bb, inbb);
        if ex >= 0 { phi_add_incoming(sphi, seen_v[ex], inbb); continue; }
        var sval: i32 = -1;
        if inv == phi_user {
            let b0 = phi_user;
            let opid: i64 = if op(b0, 0) == pn { 1 } else { 0 };
            var nm: u8[>..] = [];
            nm.append(val_name(op(b0, opid)));
            nm.append(".Elt");
            let ne = ic_new_extract_element(op(b0, opid), elt);
            set_name(ne, nm);
            let opv = ic_insert_new_with(ne, b0);
            let first = if op(b0, 0) == pn { sphi } else { opv };
            let second = if op(b0, 0) == pn { opv } else { sphi };
            let nb = ic_new_binop(iop(b0), first, second);
            copy_ir_flags(nb, b0);
            sval = ic_insert_new_with(nb, b0);
        } else {
            let nei = ic_new_extract_element(inv, elt);
            if is_inst(inv) && !is_phi_inst(inv) { sval = ic_insert_new_with(nei, inst_next(inv)); }
            else { sval = ic_insert_new_with_head(nei, first_insertion_pt(inbb)); }
        }
        seen_bb.push(inbb);
        seen_v.push(sval);
        phi_add_incoming(sphi, sval, inbb);
    }
    for e in extracts {
        ic_replace_inst_uses_with(e, sphi);
        icw_push(e);
    }
    return ei;
}

// foldBitcastExtElt(Ext)
fn fold_bitcast_ext_elt(ext: i32) -> i32 {
    let vop = op(ext, 0);
    if !is_op(vop, OP_BITCAST) { return -1; }
    var x = op(vop, 0);
    var eidx = m_constant_int_u64(op(ext, 1));
    if eidx < 0 { return -1; }
    let vt = vals[vop].ty;
    let nelts = ty_count(vt);
    let dty = vals[ext].ty;
    let dw = ld_primitive_bits(dty);
    let big = dl_big_endian;
    if ty_is_int(vals[x].ty) {
        if big { eidx = nelts - 1 - eidx; }
        let sh = eidx * dw;
        if (sh == 0 || is_desirable_int_type(ld_primitive_bits(vals[x].ty))) && has_one_use(vop) {
            if sh != 0 { x = icb_lshr(x, c_int_ty(vals[x].ty, sh as u64), "extelt.offset", false); }
            if ty_is_fp(dty) {
                let tr = icb_trunc(x, ty_int(dw), "");
                return ic_new_cast(OP_BITCAST, tr, dty);
            }
            return ic_new_cast(OP_TRUNC, x, dty);
        }
    }
    if !ty_is_vector(vals[x].ty) { return -1; }
    let st = vals[x].ty;
    let nsrc = ty_count(st);
    if nsrc == nelts && ty_kind(st) == ty_kind(vt) {
        let e = find_scalar_element(x, eidx);
        if e >= 0 { return ic_new_cast(OP_BITCAST, e, dty); }
    }
    if nsrc < nelts {
        if !is_inst_op(x, OP_INSERTELEMENT) { return -1; }
        let vec = op(x, 0);
        var scalar = op(x, 1);
        let iidx = m_constant_int_u64(op(x, 2));
        if iidx < 0 { return -1; }
        let ratio = nelts / nsrc;
        if eidx / ratio != iidx {
            if has_one_use(x) && has_one_use(vop) {
                let nbc = icb_bitcast(vec, vt, "");
                return ic_new_extract_element(nbc, op(ext, 1));
            }
            return -1;
        }
        var chunk = eidx % ratio;
        if big { chunk = ratio - 1 - chunk; }
        let need_src = ty_is_fp(ty_scalar(st));
        let need_dst = ty_is_fp(dty);
        if need_src && need_dst { return -1; }
        let sw = ld_primitive_bits(ty_scalar(st));
        let sh = chunk * dw;
        if !has_one_use(x) || !has_one_use(vop) {
            if need_src || need_dst { return -1; }
        }
        if need_src { scalar = icb_bitcast(scalar, ty_int(sw), ""); }
        if sh != 0 {
            if !has_one_use(vop) { return -1; }
            scalar = icb_lshr(scalar, c_int_ty(vals[scalar].ty, sh as u64), "", false);
        }
        if need_dst { return ic_new_cast(OP_BITCAST, icb_trunc(scalar, ty_int(dw), ""), dty); }
        return ic_new_cast(OP_TRUNC, scalar, dty);
    }
    return -1;
}

// findDemandedEltsBySingleUser(V, UserInstr, UnionUsedElts)
fn find_demanded_elts_by_single_user(v: i32, u: i32, acc: AP) -> bool, AP {
    let vw = ty_count(vals[v].ty);
    var r = acc;
    if iop(u) == OP_EXTRACTELEMENT {
        let c = m_constant_int(op(u, 1));
        if c >= 0 && ap_ult_u64(ci_ap(c), vw as u64) {
            r = ap_set_bit(r, ap_zext64(ci_ap(c)) as i64);
            return true, r;
        }
        return false, r;
    }
    if iop(u) == OP_SHUFFLEVECTOR {
        let nm = ty_count(vals[u].ty);
        for i in nm {
            let mv = sv_mask_at(u, i);
            if mv == -1 || mv >= 2 * vw { continue; }
            if op(u, 0) == v && mv < vw { r = ap_set_bit(r, mv); }
            if op(u, 1) == v && mv >= vw && mv < 2 * vw { r = ap_set_bit(r, mv - vw); }
        }
        return true, r;
    }
    return false, r;
}
// findDemandedEltsByAllUsers(V)
fn find_demanded_elts_by_all_users(v: i32) -> AP {
    let vw = ty_count(vals[v].ty);
    var r = ap_zero(vw);
    var u = first_use(v);
    while u >= 0 {
        let us = use_user(u);
        u = use_next(u);
        if is_inst(us) {
            let ok, nr = find_demanded_elts_by_single_user(v, us, r);
            if !ok { return ap_ones(vw); }
            r = nr;
        } else {
            r = ap_ones(vw);
            break;
        }
        if ap_is_all_ones(r) { break; }
    }
    return r;
}

// getPreferredVectorIndex(IndexC): -1 = none
fn get_preferred_vector_index(c: i32) -> i32 {
    let a = ci_ap(c);
    if a.w == 64 || ap_active_bits(a) > 64 { return -1; }
    return c_int_ap(T_I64, ap_zext_or_trunc(a, 64));
}

// visitExtractElementInst(EI)
fn visit_extract_element(ei: i32) -> i32 {
    let src = op(ei, 0);
    let index = op(ei, 1);
    let sv = simplify_extractelement(src, index, sq_at(ei));
    if sv >= 0 { return ic_replace_inst_uses_with(ei, sv); }
    if is_select_inst(src) && ty_is_int(vals[op(src, 0)].ty) && is_constant(index) {
        let r = fold_op_into_select(ei, src, false, false);
        if r >= 0 { return r; }
    }
    let ic = m_constant_int(index);
    var valid = false;
    let vt = vals[src].ty;
    let scalable = ty_kind(vt) == TK_SVEC;
    if ic >= 0 {
        let ni = get_preferred_vector_index(ic);
        if ni >= 0 { return ic_replace_operand(ei, 1, ni); }
        let ne = ty_count(vt);
        valid = ap_ult_u64(ci_ap(ic), ne as u64);
        if inst_iid(src) == IID_stepvector && valid {
            let ty = vals[ei].ty;
            let bw = ty_bits(ty);
            if ap_active_bits(ci_ap(ic)) <= bw { return ic_replace_inst_uses_with(ei, c_int_ap(ty, ap_zext_or_trunc(ci_ap(ic), bw))); }
            return -1;
        }
        if !scalable && !valid { return -1; }
        let r = fold_bitcast_ext_elt(ei);
        if r >= 0 { return r; }
        if is_phi_inst(src) {
            let sp = scalarize_phi(ei, src);
            if sp >= 0 { return sp; }
        }
    }
    if inst_iid(src) == IID_vector_extract && m_zero(cb_arg(src, 1)) {
        return ic_new_extract_element(cb_arg(src, 0), index);
    }
    if is_inst_op(src, OP_FNEG) && cheap_to_scalarize(src, index) {
        let e = icb_extract_element(op(src, 0), index, "");
        let r = create_inst(OP_FNEG, vals[e].ty, [e]);
        copy_ir_flags(r, src);
        return r;
    }
    if is_binop_inst(src) && cheap_to_scalarize(src, index) && (valid || sl_safe_spec_var_replaced(src)) {
        let e0 = icb_extract_element(op(src, 0), index, "");
        let e1 = icb_extract_element(op(src, 1), index, "");
        let r = ic_new_binop(iop(src), e0, e1);
        copy_ir_flags(r, src);
        return r;
    }
    if is_cmp_inst(src) && cheap_to_scalarize(src, index) {
        let e0 = icb_extract_element(op(src, 0), index, "");
        let e1 = icb_extract_element(op(src, 1), index, "");
        let r = create_inst(iop(src), cmp_result_ty(vals[e0].ty), [e0, e1]);
        insts[inst_of(r)].pred = insts[inst_of(src)].pred;
        copy_ir_flags(r, src);
        if iop(src) == OP_ICMP { insts[inst_of(r)].flags = insts[inst_of(src)].flags; }
        return r;
    }
    if is_inst(src) {
        if iop(src) == OP_INSERTELEMENT {
            if is_constant(op(src, 2)) && ic >= 0 { return ic_replace_operand(ei, 0, op(src, 0)); }
        } else if iop(src) == OP_GEP {
            let gvt = vals[src].ty;
            let ec = ty_count(gvt);
            let idxv: i64 = if ic >= 0 { ap_zext64(ci_ap(ic)) as i64 } else { 0 };
            if ic >= 0 && idxv < ec && has_one_use(src) {
                var vops: i64 = 0;
                for k in nops(src) { if ty_is_vector(vals[op(src, k)].ty) { vops++; } }
                if vops == 1 {
                    var np = op(src, 0);
                    if ty_is_vector(vals[np].ty) { np = icb_extract_element(np, ic, ""); }
                    var nops_: i32[>..<] = [];
                    for k in 1..nops(src) {
                        let x = op(src, k);
                        if ty_is_vector(vals[x].ty) { nops_.push(icb_extract_element(x, ic, "")); } else { nops_.push(x); }
                    }
                    return ic_new_gep(gep_src(src), np, nops_, gep_nw(src));
                }
            }
        } else if iop(src) == OP_SHUFFLEVECTOR {
            var m: i32[>..<] = [];
            sv_mask(src, m);
            let si = get_splat_index(m);
            if si == 0 { return ic_new_extract_element(op(src, 0), c_int(T_I64, 0)); }
            if ty_kind(vals[src].ty) == TK_FVEC {
                var have = false;
                var sidx: i64 = 0;
                if si != -1 { sidx = si; have = true; }
                else if vals[index].kind == VK_CINT && !ty_is_vector(vals[index].ty) {
                    sidx = m[ap_zext64(ci_ap(index)) as i64] as i64;
                    have = true;
                }
                if have {
                    let lw = ty_count(vals[op(src, 0)].ty);
                    if sidx < 0 { return ic_replace_inst_uses_with(ei, c_poison(vals[ei].ty)); }
                    var s = op(src, 0);
                    if sidx >= lw { sidx -= lw; s = op(src, 1); }
                    return ic_new_extract_element(s, c_int(T_I64, sidx));
                }
            }
        } else if is_cast_inst(src) {
            if has_one_use(src) && iop(src) != OP_BITCAST && (inst_parent(ei) == inst_parent(src) || vals[index].kind == VK_CINT) {
                let ee = icb_extract_element(op(src, 0), index, "");
                return ic_new_cast(iop(src), ee, vals[ei].ty);
            }
        }
    }
    if ic >= 0 {
        let ne = ty_count(vt);
        if !scalable && ne != 1 {
            if has_one_use(src) && !is_constant_data(src) {
                let dem = ap_set_bit(ap_zero(ne), ap_zext64(ci_ap(ic)) as i64);
                let v = ic_sdve(src, dem, false);
                if v >= 0 { return ic_replace_operand(ei, 0, v); }
            } else {
                let dem = find_demanded_elts_by_all_users(src);
                if !ap_is_all_ones(dem) {
                    let v = ic_sdve(src, dem, true);
                    if v >= 0 && v != src {
                        icw_add_value(src);
                        ic_rauw(src, v);
                        return ei;
                    }
                }
            }
        }
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// insertelement -> shuffles

// collectSingleShuffleElements(V, LHS, RHS, Mask)
recursive fn collect_single_shuffle_elements(v: i32, lhs: i32, rhs: i32, mask: i32[>..<]&) -> bool {
    let ne = ty_count(vals[v].ty);
    if is_poison(v) {
        mask.clear();
        for i in ne { mask.push(-1); }
        return true;
    }
    if v == lhs { for i in ne { mask.push(i as i32); } return true; }
    if v == rhs { for i in ne { mask.push((i + ne) as i32); } return true; }
    if is_inst_op(v, OP_INSERTELEMENT) {
        let vec = op(v, 0);
        let sc = op(v, 1);
        let idx = op(v, 2);
        if vals[idx].kind != VK_CINT || ty_is_vector(vals[idx].ty) { return false; }
        let ins = ap_zext64(ci_ap(idx)) as i64;
        if is_poison(sc) {
            if collect_single_shuffle_elements(vec, lhs, rhs, mask) {
                mask[ins] = -1;
                return true;
            }
        } else if is_inst_op(sc, OP_EXTRACTELEMENT) {
            let ec = op(sc, 1);
            if vals[ec].kind == VK_CINT && !ty_is_vector(vals[ec].ty) {
                let ext = ap_zext64(ci_ap(ec)) as i64;
                let nl = ty_count(vals[lhs].ty);
                if op(sc, 0) == lhs || op(sc, 0) == rhs {
                    if collect_single_shuffle_elements(vec, lhs, rhs, mask) {
                        if op(sc, 0) == lhs { mask[ins % ne] = ext as i32; } else { mask[ins % ne] = (ext + nl) as i32; }
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

// replaceExtractElements(InsElt, ExtElt, IC)
fn replace_extract_elements(ins: i32, ext: i32) -> bool {
    let it = vals[ins].ty;
    let et = vals[op(ext, 0)].ty;
    let nins = ty_count(it);
    let next = ty_count(et);
    if ty_elem(it) != ty_elem(et) || next >= nins { return false; }
    let evo = op(ext, 0);
    if is_constant_data(evo) { return false; }
    var em: i32[>..<] = [];
    for i in next { em.push(i as i32); }
    for i in next..nins { em.push(-1); }
    let evi = if is_inst(evo) { evo } else { -1 };
    let ib = if evi >= 0 && !is_phi_inst(evi) { inst_parent(evi) } else { inst_parent(ext) };
    if ib != inst_parent(ins) { return false; }
    if has_one_use(ins) && is_inst_op(use_user(first_use(ins)), OP_INSERTELEMENT) { return false; }
    let wv = ic_new_shuffle1(evo, em);
    if evi >= 0 && !is_phi_inst(evi) {
        inst_insert_after(wv, evi);
        ic_register_name(wv);
    } else {
        ic_insert_new_with_head(wv, first_insertion_pt(inst_parent(ext)));
    }
    if evi >= 0 {
        let dl = inst_get_md(evi, 0);
        if dl >= 0 { inst_set_md(wv, 0, dl); } else { inst_erase_md(wv, 0); }
    } else {
        // DebugLoc::getCompilerGenerated(): no location in the output
        inst_erase_md(wv, 0);
    }
    var olds: i32[>..<] = [];
    var u = first_use(evo);
    while u >= 0 { olds.push(use_user(u)); u = use_next(u); }
    for old in olds {
        if !is_inst_op(old, OP_EXTRACTELEMENT) || inst_parent(old) != inst_parent(wv) { continue; }
        let ne = ic_new_extract_element(wv, op(old, 1));
        ic_insert_new_with(ne, old);
        ic_replace_inst_uses_with(old, ne);
        icw_push(old);
    }
    return true;
}

// collectShuffleElements(V, Mask, PermittedRHS, IC, Rerun) -> (LHS, RHS); cse_rerun is Rerun
var cse_rerun: bool = false;
recursive fn collect_shuffle_elements(v: i32, mask: i32[>..<]&, prhs: i32) -> i32, i32 {
    let ne = ty_count(vals[v].ty);
    if is_poison(v) {
        mask.clear();
        for i in ne { mask.push(-1); }
        return if prhs >= 0 { c_poison(vals[prhs].ty) } else { v }, -1;
    }
    if is_caz(v) {
        mask.clear();
        for i in ne { mask.push(0); }
        return v, -1;
    }
    if is_inst_op(v, OP_INSERTELEMENT) {
        let vec = op(v, 0);
        let sc = op(v, 1);
        let idx = op(v, 2);
        if is_inst_op(sc, OP_EXTRACTELEMENT) {
            let ec = op(sc, 1);
            if vals[ec].kind == VK_CINT && !ty_is_vector(vals[ec].ty) && vals[idx].kind == VK_CINT && !ty_is_vector(vals[idx].ty) {
                let ext = ap_zext64(ci_ap(ec)) as i64;
                let ins = ap_zext64(ci_ap(idx)) as i64;
                let eo = op(sc, 0);
                if eo == prhs || prhs < 0 {
                    let rhs = eo;
                    let l, r = collect_shuffle_elements(vec, mask, rhs);
                    if vals[l].ty != vals[rhs].ty {
                        if replace_extract_elements(v, sc) { cse_rerun = true; }
                        for i in ne { mask[i] = i as i32; }
                        return v, -1;
                    }
                    let nl = ty_count(vals[rhs].ty);
                    mask[ins % ne] = (nl + ext) as i32;
                    return l, rhs;
                }
                if vec == prhs {
                    let nl = ty_count(vals[eo].ty);
                    for i in ne { mask.push(if i == ins { ext as i32 } else { (nl + i) as i32 }); }
                    return eo, prhs;
                }
                if vals[eo].ty == vals[prhs].ty && collect_single_shuffle_elements(v, eo, prhs, mask) {
                    return eo, prhs;
                }
            }
        }
    }
    for i in ne { mask.push(i as i32); }
    return v, -1;
}

// ---------------------------------------------------------------------------------------------
// insertvalue

// foldAggregateConstructionIntoAggregateReuse(OrigIVI)
fn fold_aggregate_construction_into_aggregate_reuse(orig: i32) -> i32 {
    let aggty = vals[orig].ty;
    let nae = ty_count(aggty);
    if nae > 2 { return -1; }
    var elts: i32[>..<] = [];   // -1 = NotFound
    for k in nae { elts.push(-1); }
    fn know_all() -> bool { for e in elts { if e < 0 { return false; } } return true; }
    var depth: i64 = 0;
    let limit = 2 * nae;
    var cur = orig;
    while depth < limit && cur >= 0 && !know_all() {
        let iv = op(cur, 1);
        if !is_inst(iv) { return -1; }
        if ev_nidx(cur) != 1 { return -1; }
        let k = ev_idx(cur, 0) as i64;
        if elts[k] < 0 { elts[k] = iv; }
        let nx = op(cur, 0);
        cur = if is_inst_op(nx, OP_INSERTVALUE) { nx } else { -1 };
        depth++;
    }
    if !know_all() { return -1; }
    // Describe: -2 NotFound, -3 FoundMismatch, else the aggregate
    var elt_in_use_bb = false;
    fn find_source(elt0: i32, idx: i64, use_bb: i32, pred_bb: i32) -> i32 {
        var elt = elt0;
        if use_bb >= 0 && pred_bb >= 0 {
            let t = do_phi_translation(elt, use_bb, pred_bb);
            elt = if is_inst(t) { t } else { -1 };
            if elt >= 0 && inst_parent(elt) == use_bb { elt_in_use_bb = true; }
        }
        if elt < 0 || !is_inst_op(elt, OP_EXTRACTVALUE) { return -2; }
        let sa = op(elt, 0);
        if vals[sa].ty != aggty { return -3; }
        if ev_nidx(elt) != 1 || idx != ev_idx(elt, 0) as i64 { return -3; }
        return sa;
    }
    fn find_common(use_bb: i32, pred_bb: i32) -> i32 {
        var sa: i32 = -2;
        for k in elts.len {
            let s = find_source(elts[k], k, use_bb, pred_bb);
            if s < 0 { return s; }
            if sa == -2 { sa = s; continue; }
            if s != sa { return -3; }
        }
        return sa;
    }
    let sa0 = find_common(-1, -1);
    if sa0 != -2 {
        if sa0 == -3 { return -1; }
        return ic_replace_inst_uses_with(orig, sa0);
    }
    var use_bb: i32 = -1;
    for e in elts {
        let bb = inst_parent(e);
        if use_bb < 0 { use_bb = bb; continue; }
        if use_bb != bb { return -1; }
    }
    if use_bb < 0 { return -1; }
    if pred_count(use_bb) == 0 { return -1; }
    var preds: i32[>..<] = [];
    var too_many = false;
    each_pred(use_bb) { p =>
        if preds.len >= 64 { too_many = true; } else { preds.push(p); }
    };
    if too_many { return -1; }
    var map_bb: i32[>..<] = [];
    var map_v: i32[>..<] = [];
    var found = false;
    for p in preds {
        if position(map_bb, p) >= 0 { continue; }
        map_bb.push(p);
        let s = find_common(use_bb, p);
        if s >= 0 {
            found = true;
            map_v.push(s);
        } else {
            map_v.push(-1);
            if iop(block_terminator(p)) != OP_BR { return -1; }
        }
    }
    if !found { return -1; }
    let orig_bb = inst_parent(orig);
    for k in map_bb.len {
        if map_v[k] >= 0 { continue; }
        if elt_in_use_bb { return -1; }
        if use_bb != orig_bb { return -1; }
        var const_agg = true;
        for e in elts {
            if !is_constant(do_phi_translation(e, use_bb, map_bb[k])) { const_agg = false; break; }
        }
        if const_agg { return -1; }
    }
    for k in map_bb.len {
        if map_v[k] >= 0 { continue; }
        let p = map_bb[k];
        icb_set_insert_point(block_terminator(p));
        var v = c_poison(aggty);
        for j in elts.len {
            let e = do_phi_translation(elts[j], use_bb, p);
            v = icb_insert_value(v, e, [j as i32], "");
        }
        map_v[k] = v;
    }
    let sp = icb_pos; let sb = icb_bb; let sd = icb_dl;
    icb_set_insert_point_head(first_non_phi(use_bb));
    var nm: u8[>..] = [];
    nm.append(val_name(orig));
    nm.append(".merged");
    let phi = icb_phi(aggty, nm);
    icb_pos = sp; icb_bb = sb; icb_dl = sd;
    for p in preds { phi_add_incoming(phi, map_v[position(map_bb, p)], p); }
    return ic_replace_inst_uses_with(orig, phi);
}

// visitInsertValueInst(I)
fn visit_insert_value(i: i32) -> i32 {
    let sv = simplify_insertvalue(i, op(i, 0), op(i, 1), sq_at(i));
    if sv >= 0 { return ic_replace_inst_uses_with(i, sv); }
    var redundant = false;
    var v = i;
    var depth: i64 = 0;
    while has_one_use(v) && depth < 10 {
        let u = use_user(first_use(v));
        if !is_inst_op(u, OP_INSERTVALUE) || op(u, 0) != v { break; }
        if ev_indices_equal(u, i) { redundant = true; break; }
        v = u;
        depth++;
    }
    if redundant { return ic_replace_inst_uses_with(i, op(i, 0)); }
    let r = fold_aggregate_construction_into_aggregate_reuse(i);
    if r >= 0 { return r; }
    return -1;
}
fn ev_indices_equal(a: i32, b: i32) -> bool {
    if ev_nidx(a) != ev_nidx(b) { return false; }
    for k in ev_nidx(a) { if ev_idx(a, k) != ev_idx(b, k) { return false; } }
    return true;
}

// ---------------------------------------------------------------------------------------------
// insertelement

// isShuffleEquivalentToSelect(Shuf)
fn is_shuffle_equivalent_to_select(s: i32) -> bool {
    if ty_kind(vals[op(s, 0)].ty) == TK_SVEC { return false; }
    let ms = sv_nmask(s);
    let vs = sv_nop_elts(s);
    if ms != vs { return false; }
    for i in ms {
        let e = sv_mask_at(s, i);
        if e != -1 && e != i && e != i + vs { return false; }
    }
    return true;
}

// foldInsSequenceIntoSplat(InsElt)
fn fold_ins_sequence_into_splat(ie: i32) -> i32 {
    if has_one_use(ie) && is_inst_op(use_user(first_use(ie)), OP_INSERTELEMENT) { return -1; }
    let vt = vals[ie].ty;
    if ty_kind(vt) == TK_SVEC { return -1; }
    let ne = ty_count(vt);
    if ne == 1 { return -1; }
    let spv = op(ie, 1);
    var cur = ie;
    var present: bool[>..<] = [];
    for k in ne { present.push(false); }
    var first: i32 = -1;
    while cur >= 0 {
        let idx = op(cur, 2);
        if vals[idx].kind != VK_CINT || ty_is_vector(vals[idx].ty) || op(cur, 1) != spv { return -1; }
        let nx = if is_inst_op(op(cur, 0), OP_INSERTELEMENT) { op(cur, 0) } else { -1 };
        if cur != ie && (!has_one_use(cur) && (nx >= 0 || !ap_is_zero(ci_ap(idx)))) { return -1; }
        present[ap_zext64(ci_ap(idx)) as i64] = true;
        first = cur;
        cur = nx;
    }
    if first == ie { return -1; }
    if !is_poison(op(first, 0)) {
        for p in present { if !p { return -1; } }
    }
    let pv = c_poison(vt);
    let zero = c_int(T_I64, 0);
    if !ap_is_zero(ci_ap(op(first, 2))) {
        let ni = ic_new_insert_element(pv, spv, zero);
        ic_insert_before_pos(ni, ie);
        icw_add(ni);
        first = ni;
    }
    var m: i32[>..<] = [];
    for i in ne { m.push(if present[i] { 0 } else { -1 }); }
    return ic_new_shuffle1(first, m);
}

// foldInsEltIntoSplat(InsElt)
fn fold_ins_elt_into_splat(ie: i32) -> i32 {
    let sh = op(ie, 0);
    if !is_inst_op(sh, OP_SHUFFLEVECTOR) || !sv_is_zero_elt_splat(sh) { return -1; }
    if ty_kind(vals[sh].ty) == TK_SVEC { return -1; }
    let idx = m_constant_int_u64(op(ie, 2));
    if idx < 0 { return -1; }
    let x = op(ie, 1);
    let op0 = op(sh, 0);
    if !(is_inst_op(op0, OP_INSERTELEMENT) && m_undef(op(op0, 0)) && op(op0, 1) == x && m_zero_int(op(op0, 2))) { return -1; }
    let nm = ty_count(vals[sh].ty);
    var m: i32[>..<] = [];
    for i in nm { m.push(if i == idx { 0 } else { sv_mask_at(sh, i) as i32 }); }
    return ic_new_shuffle1(op0, m);
}

// foldInsEltIntoIdentityShuffle(InsElt)
fn fold_ins_elt_into_identity_shuffle(ie: i32) -> i32 {
    let sh = op(ie, 0);
    if !is_inst_op(sh, OP_SHUFFLEVECTOR) || !is_poison(op(sh, 1)) || !(sv_is_identity_with_extract(sh) || sv_is_identity_with_padding(sh)) { return -1; }
    if ty_kind(vals[sh].ty) == TK_SVEC { return -1; }
    let idx = m_constant_int_u64(op(ie, 2));
    if idx < 0 { return -1; }
    let sc = op(ie, 1);
    let x = op(sh, 0);
    if !(is_inst_op(sc, OP_EXTRACTELEMENT) && op(sc, 0) == x && m_specific_int(op(sc, 1), idx as u64)) { return -1; }
    let nm = ty_count(vals[sh].ty);
    var old: i32[>..<] = [];
    sv_mask(sh, old);
    var m: i32[>..<] = [];
    for i in nm {
        if i != idx { m.push(old[i]); }
        else if (old[i] as i64) == idx { return -1; }
        else { m.push(idx as i32); }
    }
    return ic_new_shuffle(x, op(sh, 1), m);
}

// hoistInsEltConst(InsElt2, Builder)
fn hoist_ins_elt_const(ie2: i32) -> i32 {
    let ie1 = op(ie2, 0);
    if !is_inst_op(ie1, OP_INSERTELEMENT) || !has_one_use(ie1) { return -1; }
    let x = op(ie1, 0);
    let y = op(ie1, 1);
    let i1 = m_constant_int(op(ie1, 2));
    let sc = op(ie2, 1);
    let i2 = m_constant_int(op(ie2, 2));
    if !is_constant(y) && i1 >= 0 && is_constant(sc) && i2 >= 0 && i1 != i2 {
        let n1 = icb_insert_element(x, sc, i2, "");
        return ic_new_insert_element(n1, y, i1);
    }
    return -1;
}

// foldConstantInsEltIntoShuffle(InsElt)
fn fold_constant_ins_elt_into_shuffle(ie: i32) -> i32 {
    let inst = op(ie, 0);
    if !is_inst(inst) || !has_one_use(inst) { return -1; }
    if iop(inst) == OP_SHUFFLEVECTOR {
        let sh = inst;
        let scv = op(sh, 1);
        let iesc = op(ie, 1);
        let iei = m_constant_int_u64(op(ie, 2));
        if !is_constant(scv) || !is_constant(iesc) || iei < 0 { return -1; }
        if !is_shuffle_equivalent_to_select(sh) { return -1; }
        var mask: i32[>..<] = [];
        sv_mask(sh, mask);
        let n = mask.len;
        var nse: i32[>..<] = [];
        var nme: i32[>..<] = [];
        for i in n {
            if i == iei {
                nse.push(iesc);
                nme.push((iei + n) as i32);
            } else {
                nse.push(agg_elem(scv, i));
                nme.push(mask[i]);
            }
            if nse[i] < 0 { return -1; }
        }
        return ic_new_shuffle(op(sh, 0), c_aggregate(vals[scv].ty, nse), nme);
    }
    if iop(inst) == OP_INSERTELEMENT {
        let iei = inst;
        if ty_kind(vals[ie].ty) == TK_SVEC { return -1; }
        let ne = ty_count(vals[ie].ty);
        let x0 = m_constant_int_u64(op(ie, 2));
        let x1 = m_constant_int_u64(op(iei, 2));
        if x0 < 0 || !is_constant(op(ie, 1)) || x1 < 0 || !is_constant(op(iei, 1)) { return -1; }
        var vals_: i32[>..<] = [];
        var m: i32[>..<] = [];
        for i in ne { vals_.push(-1); m.push(0); }
        let ins = [x0, x1];
        let vv = [op(ie, 1), op(iei, 1)];
        for k in 2 {
            let ii = ins[k];
            if vals_[ii] < 0 {
                vals_[ii] = vv[k];
                m[ii] = (ne + ii) as i32;
            }
        }
        for i in ne {
            if vals_[i] < 0 {
                vals_[i] = c_poison(ty_elem(vals[ie].ty));
                m[i] = i as i32;
            }
        }
        return ic_new_shuffle(op(iei, 0), c_aggregate(vals[ie].ty, vals_), m);
    }
    return -1;
}

// narrowInsElt(InsElt, Builder)
fn narrow_ins_elt(ie: i32) -> i32 {
    let vec = op(ie, 0);
    if !has_one_use(vec) || is_constant_data(vec) { return -1; }
    let sc = op(ie, 1);
    var co: i64 = -1;
    if is_inst_op(vec, OP_FPEXT) && is_inst_op(sc, OP_FPEXT) { co = OP_FPEXT; }
    else if is_inst_op(vec, OP_SEXT) && is_inst_op(sc, OP_SEXT) { co = OP_SEXT; }
    else if is_inst_op(vec, OP_ZEXT) && is_inst_op(sc, OP_ZEXT) { co = OP_ZEXT; }
    else { return -1; }
    let x = op(vec, 0);
    let y = op(sc, 0);
    if ty_scalar(vals[x].ty) != vals[y].ty { return -1; }
    let ni = icb_insert_element(x, y, op(ie, 2), "");
    return ic_new_cast(co, ni, vals[ie].ty);
}

// foldTruncInsEltPair(InsElt, IsBigEndian, Builder)
fn fold_trunc_ins_elt_pair(ie: i32, big: bool) -> i32 {
    let vec = op(ie, 0);
    let sc = op(ie, 1);
    let idx = op(ie, 2);
    let vt = vals[ie].ty;
    if ty_kind(vt) != TK_FVEC || (ty_count(vt) & 1) != 0 { return -1; }
    let i1 = m_constant_int_u64(idx);
    if i1 < 0 || !is_inst_op(vec, OP_INSERTELEMENT) { return -1; }
    let base = op(vec, 0);
    let s0 = op(vec, 1);
    let i0 = m_constant_int_u64(op(vec, 2));
    if i0 < 0 || !m_undef(base) { return -1; }
    if i0 + 1 != i1 || (i0 & 1) != 0 { return -1; }
    var x: i32 = -1;
    var sh: i64 = -1;
    fn trunc_of_lshr(t: i32, xv: i32) -> i64 {
        if !is_inst_op(t, OP_TRUNC) { return -1; }
        let l = op(t, 0);
        if !bo(l, OP_LSHR) || op(l, 0) != xv { return -1; }
        return m_constant_int_u64(op(l, 1));
    }
    if big {
        if !is_inst_op(sc, OP_TRUNC) { return -1; }
        x = op(sc, 0);
        sh = trunc_of_lshr(s0, x);
        if sh < 0 { return -1; }
    } else {
        if !is_inst_op(s0, OP_TRUNC) { return -1; }
        x = op(s0, 0);
        sh = trunc_of_lshr(sc, x);
        if sh < 0 { return -1; }
    }
    let st = vals[x].ty;
    let sw = ty_scalar_bits(st);
    let ew = ty_scalar_bits(vt);
    if sw != ew * 2 || sh != ew { return -1; }
    let ct = ty_vector(st, ty_count(vt) / 2, false);
    let cb = icb_bitcast(base, ct, "");
    let ni = if big { i1 / 2 } else { i0 / 2 };
    let nins = icb_insert_element_k(cb, x, ni as u64, "");
    return ic_new_cast(OP_BITCAST, nins, vt);
}

// visitInsertElementInst(IE)
fn visit_insert_element(ie: i32) -> i32 {
    let vec = op(ie, 0);
    let sc = op(ie, 1);
    let idx = op(ie, 2);
    let sv = simplify_insertelement(vec, sc, idx, sq_at(ie));
    if sv >= 0 { return ic_replace_inst_uses_with(ie, sv); }
    let ic = m_constant_int(idx);
    if ic >= 0 {
        let ni = get_preferred_vector_index(ic);
        if ni >= 0 { return ic_replace_operand(ie, 2, ni); }
        if is_inst_op(vec, OP_INSERTELEMENT) && has_one_use(vec) {
            let oi = m_constant_int_u64(op(vec, 2));
            if oi >= 0 && !is_constant(op(vec, 1)) && ap_ugt_u64(ap_u64(oi as u64, 64), ap_zext64(ci_ap(ic))) {
                let nins = icb_insert_element(op(vec, 0), sc, idx, "");
                return ic_new_insert_element(nins, op(vec, 1), c_int(T_I64, oi));
            }
        }
    }
    if m_undef(vec) && is_op(sc, OP_BITCAST) && one_use(sc) {
        let ss = op(sc, 0);
        if ty_is_int(vals[ss].ty) || ty_is_fp(vals[ss].ty) {
            let st = vals[ss].ty;
            let vt = ty_vector(st, ty_count(vals[ie].ty), ty_kind(vals[ie].ty) == TK_SVEC);
            let nu = if is_poison(vec) { c_poison(vt) } else { c_undef(vt) };
            let nins = icb_insert_element(nu, ss, idx, "");
            return ic_new_cast(OP_BITCAST, nins, vals[ie].ty);
        }
    }
    if is_op(vec, OP_BITCAST) && is_op(sc, OP_BITCAST) && (one_use(vec) || one_use(sc)) {
        let vs = op(vec, 0);
        let ss = op(sc, 0);
        if ty_is_vector(vals[vs].ty) && !ty_is_vector(vals[ss].ty) && ty_elem(vals[vs].ty) == vals[ss].ty {
            let nins = icb_insert_element(vs, ss, idx, "");
            return ic_new_cast(OP_BITCAST, nins, vals[ie].ty);
        }
    }
    if ty_kind(vals[ie].ty) == TK_FVEC {
        let ins = m_constant_int_u64(idx);
        if ins >= 0 && is_inst_op(sc, OP_EXTRACTELEMENT) {
            let evo = op(sc, 0);
            let ext = m_constant_int_u64(op(sc, 1));
            if ext >= 0 && ty_kind(vals[evo].ty) == TK_FVEC && ext < ty_count(vals[evo].ty) {
                var root = !has_one_use(ie);
                if !root { root = !is_inst_op(use_user(first_use(ie)), OP_INSERTELEMENT); }
                if root {
                    var rerun = true;
                    while rerun {
                        rerun = false;
                        cse_rerun = false;
                        var mask: i32[>..<] = [];
                        let l, r = collect_shuffle_elements(ie, mask, -1);
                        rerun = cse_rerun;
                        if l != ie && r != ie {
                            let rr = if r < 0 { c_poison(vals[l].ty) } else { r };
                            return ic_new_shuffle(l, rr, mask);
                        }
                    }
                }
            }
        }
    }
    let vty = vals[vec].ty;
    if ty_kind(vty) == TK_FVEC {
        let vw = ty_count(vty);
        let v = ic_sdve(ie, ap_ones(vw), false);
        if v >= 0 {
            if v != ie { return ic_replace_inst_uses_with(ie, v); }
            return ie;
        }
    }
    let r1 = fold_constant_ins_elt_into_shuffle(ie);
    if r1 >= 0 { return r1; }
    let r2 = hoist_ins_elt_const(ie);
    if r2 >= 0 { return r2; }
    let r3 = fold_ins_sequence_into_splat(ie);
    if r3 >= 0 { return r3; }
    let r4 = fold_ins_elt_into_splat(ie);
    if r4 >= 0 { return r4; }
    let r5 = fold_ins_elt_into_identity_shuffle(ie);
    if r5 >= 0 { return r5; }
    let r6 = narrow_ins_elt(ie);
    if r6 >= 0 { return r6; }
    let r7 = fold_trunc_ins_elt_pair(ie, dl_big_endian);
    if r7 >= 0 { return r7; }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// Reordering vector elements

// canEvaluateShuffled(V, Mask, Depth = 5)
recursive fn can_evaluate_shuffled(v: i32, mask: const i32[:], depth: i64) -> bool {
    if is_constant(v) { return true; }
    if !is_inst(v) { return false; }
    if !has_one_use(v) { return false; }
    if depth == 0 { return false; }
    let o = iop(v);
    if o == OP_UDIV || o == OP_SDIV || o == OP_UREM || o == OP_SREM {
        if mask_contains(mask, -1) { return false; }
    }
    if is_binary_op(o) || o == OP_FADD || o == OP_FSUB || o == OP_FMUL || o == OP_FDIV || o == OP_FREM ||
       o == OP_ICMP || o == OP_FCMP || o == OP_TRUNC || o == OP_ZEXT || o == OP_SEXT || o == OP_FPTOUI ||
       o == OP_FPTOSI || o == OP_UITOFP || o == OP_SITOFP || o == OP_FPTRUNC || o == OP_FPEXT || o == OP_GEP ||
       o == OP_UDIV || o == OP_SDIV || o == OP_UREM || o == OP_SREM {
        let it = vals[v].ty;
        if ty_is_vector(it) && mask.len > ty_count(it) { return false; }
        for k in nops(v) { if !can_evaluate_shuffled(op(v, k), mask, depth - 1) { return false; } }
        return true;
    }
    if o == OP_INSERTELEMENT {
        let c = m_constant_int(op(v, 2));
        if c < 0 { return false; }
        let en = ap_limited(ci_ap(c), 0xFFFFFFFFFFFFFFFF);
        var seen = false;
        for m in mask {
            if (m as i64) >= 0 && (m as u64) == en {
                if seen { return false; }
                seen = true;
            }
        }
        return can_evaluate_shuffled(op(v, 0), mask, depth - 1);
    }
    return false;
}
fn is_binop_opcode_any(o: i64) -> bool { o >= OP_ADD && o <= OP_XOR }

// buildNew(I, NewOps, Builder)
fn build_new(i: i32, nops_: const i32[:]) -> i32 {
    icb_set_insert_point(i);
    let o = iop(i);
    if is_binop_opcode_any(o) {
        let nv = icb_binop(o, nops_[0], nops_[1], "");
        if is_inst(nv) {
            if is_overflowing_op(o) { set_nuw(nv, op_nuw(i)); set_nsw(nv, op_nsw(i)); }
            if o == OP_UDIV || o == OP_SDIV || o == OP_LSHR || o == OP_ASHR { set_exact(nv, op_exact(i)); }
            if is_fp_math_operator(i) { insts[inst_of(nv)].fmf = insts[inst_of(i)].fmf; }
        }
        return nv;
    }
    if o == OP_ICMP { return icb_icmp(inst_pred(i), nops_[0], nops_[1], ""); }
    if o == OP_FCMP { return icb_fcmp(inst_pred(i), nops_[0], nops_[1], ""); }
    if is_cast_op(o) {
        let nt = vals[nops_[0]].ty;
        let dt = ty_vector(ty_scalar(vals[i].ty), ty_count(nt), ty_kind(nt) == TK_SVEC);
        return icb_cast(o, nops_[0], dt, "");
    }
    if o == OP_GEP { return icb_gep(gep_src(i), nops_[0], nops_[1..], "", gep_nw(i)); }
    fatal("internal: buildNew: failed to rebuild vector instructions");
    return -1;
}

// evaluateInDifferentElementOrder(V, Mask, Builder)
recursive fn evaluate_in_different_element_order(v: i32, mask: const i32[:]) -> i32 {
    let et = ty_scalar(vals[v].ty);
    if is_poison(v) { return c_poison(ty_vector(et, mask.len, false)); }
    if m_undef(v) { return c_undef(ty_vector(et, mask.len, false)); }
    if is_caz(v) { return c_null(ty_vector(et, mask.len, false)); }
    if is_constant(v) {
        var m: i32[>..<] = [];
        for x in mask { m.push(x); }
        return tf_fold(ce_shufflevector(v, c_poison(vals[v].ty), m));
    }
    let o = iop(v);
    if o == OP_INSERTELEMENT {
        let el = ap_limited(ci_ap(op(v, 2)), 0xFFFFFFFFFFFFFFFF);
        var found = false;
        var index: i64 = 0;
        while index < mask.len {
            if (mask[index] as i64) >= 0 && (mask[index] as u64) == el { found = true; break; }
            index++;
        }
        if !found { return evaluate_in_different_element_order(op(v, 0), mask); }
        let nv = evaluate_in_different_element_order(op(v, 0), mask);
        icb_set_insert_point(v);
        return icb_insert_element_k(nv, op(v, 1), index as u64, "");
    }
    // the binary/cmp/cast/select/GEP case
    let mark = is_ops.len;
    var rebuild = mask.len != ty_count(vals[v].ty);
    for k in nops(v) {
        let x = op(v, k);
        var nv = x;
        if ty_is_vector(vals[x].ty) { nv = evaluate_in_different_element_order(x, mask); }
        is_ops.push(nv);
        if nv != x { rebuild = true; }
    }
    if rebuild {
        if o == OP_SELECT { fatal("internal: buildNew of a select (failed to rebuild vector instructions)"); }
        var nops_: i32[>..<] = [];
        for k in mark..is_ops.len { nops_.push(is_ops[k]); }
        is_ops.resize(mark);
        return build_new(v, nops_);
    }
    is_ops.resize(mark);
    return v;
}

// isShuffleExtractingFromLHS(SVI, Mask)
fn is_shuffle_extracting_from_lhs(s: i32, mask: const i32[:]) -> bool {
    let le = ty_count(vals[op(s, 0)].ty);
    let me = mask.len;
    let beg = mask[0] as u32 as i64;
    let end = mask[me - 1] as u32 as i64;
    if beg > end || end >= le || end - beg != me - 1 { return false; }
    for i in me { if (mask[i] as u32 as i64) != beg + i { return false; } }
    return true;
}

// getAlternateBinop(BO, DL): (opcode, op0, op1); opcode 0 = none
fn get_alternate_binop(b: i32) -> i64, i32, i32 {
    let b0 = op(b, 0);
    let b1 = op(b, 1);
    let ty = vals[b].ty;
    let o = iop(b);
    if o == OP_SHL {
        if m_imm_constant(b1) {
            let s1 = cf_fold_binop_operands(OP_SHL, c_int_ty(ty, 1), b1);
            return OP_MUL, b0, s1;
        }
    } else if o == OP_OR {
        if op_disjoint(b) { return OP_ADD, b0, b1; }
    } else if o == OP_SUB {
        if m_zero_int(b0) { return OP_MUL, b1, c_all_ones(ty); }
    }
    return 0, -1, -1;
}

// foldSelectShuffleOfSelectShuffle(Shuf)
fn fold_select_shuffle_of_select_shuffle(s: i32) -> i32 {
    var op0 = op(s, 0);
    var op1 = op(s, 1);
    var mask: i32[>..<] = [];
    sv_mask(s, mask);
    let n = mask.len;
    if is_inst_op(op0, OP_SHUFFLEVECTOR) && shuf_is_select(op0) && (op(op0, 0) == op1 || op(op0, 1) == op1) {
        let t = op0; op0 = op1; op1 = t;
        commute_shuffle_mask(mask, n);
    }
    if !is_inst_op(op1, OP_SHUFFLEVECTOR) || !shuf_is_select(op1) || (op(op1, 0) != op0 && op(op1, 1) != op0) { return -1; }
    var x = op(op1, 0);
    var y = op(op1, 1);
    var m1: i32[>..<] = [];
    sv_mask(op1, m1);
    if y == op0 {
        let t = x; x = y; y = t;
        commute_shuffle_mask(m1, n);
    }
    var nm: i32[>..<] = [];
    for i in n { nm.push(if (mask[i] as i64) < n { mask[i] } else { m1[i] }); }
    return ic_new_shuffle(x, y, nm);
}

// foldSelectShuffleWith1Binop(Shuf, SQ)
fn fold_select_shuffle_with_1binop(s: i32) -> i32 {
    let op0 = op(s, 0);
    let op1 = op(s, 1);
    var op0_binop = false;
    var c: i32 = -1;
    if is_binop_inst(op0) && op(op0, 0) == op1 && is_constant(op(op0, 1)) { op0_binop = true; c = op(op0, 1); }
    else if is_binop_inst(op1) && op(op1, 0) == op0 && is_constant(op(op1, 1)) { op0_binop = false; c = op(op1, 1); }
    else { return -1; }
    let b = if op0_binop { op0 } else { op1 };
    let bop = iop(b);
    let idc = binop_identity(bop, vals[s].ty, true);
    if idc < 0 { return -1; }
    let x = if op0_binop { op1 } else { op0 };
    let is_fp = ty_is_fp(ty_elem(vals[s].ty));
    if is_fp {
        kb_cxt = s;
        if !is_known_never_nan(x, 0) { return -1; }
    }
    var mask: i32[>..<] = [];
    sv_mask(s, mask);
    var nc = if op0_binop { tf_fold(ce_shufflevector(c, idc, mask)) } else { tf_fold(ce_shufflevector(idc, c, mask)) };
    let might = mask_contains(mask, -1) && (is_int_divrem_op(bop) || is_shift_op(bop));
    if might { nc = safe_vector_constant_for_binop(bop, nc, true); }
    let nb = ic_new_binop(bop, x, nc);
    copy_ir_flags(nb, b);
    if is_fp && (insts[inst_of(nb)].fmf & FMF_NINF) != 0 {
        kb_cxt = s;
        if !is_known_never_infinity(x, 0) { insts[inst_of(nb)].fmf &= ~FMF_NINF; }
    }
    if mask_contains(mask, -1) && !might { drop_poison_generating_flags(nb); }
    return nb;
}

// canonicalizeInsertSplat(Shuf, Builder)
fn canonicalize_insert_splat(s: i32) -> i32 {
    let op0 = op(s, 0);
    let op1 = op(s, 1);
    if !(is_inst_op(op0, OP_INSERTELEMENT) && one_use(op0) && is_poison(op(op0, 0))) { return -1; }
    let ic = m_constant_int_u64(op(op0, 2));
    if ic < 0 || !is_poison(op1) || sv_has_zero_mask(s) || ic == 0 { return -1; }
    let x = op(op0, 1);
    var mask: i32[>..<] = [];
    sv_mask(s, mask);
    let pv = c_poison(vals[s].ty);
    let ni = icb_insert_element_k(pv, x, 0, "");
    let n = ty_count(vals[s].ty);
    var nm: i32[>..<] = [];
    for i in n { nm.push(if mask[i] == -1 { -1 } else { 0 }); }
    return ic_new_shuffle1(ni, nm);
}

// foldSelectShuffle(Shuf)
fn fold_select_shuffle(s: i32) -> i32 {
    if !shuf_is_select(s) { return -1; }
    let ne = ty_count(vals[s].ty);
    if !m_undef(op(s, 1)) && sv_mask_at(s, 0) >= ne {
        sv_commute(s);
        return s;
    }
    let r1 = fold_select_shuffle_of_select_shuffle(s);
    if r1 >= 0 { return r1; }
    let r2 = fold_select_shuffle_with_1binop(s);
    if r2 >= 0 { return r2; }
    let b0 = op(s, 0);
    let b1 = op(s, 1);
    if !is_binop_inst(b0) || !is_binop_inst(b1) { return -1; }
    var x: i32 = -1;
    var y: i32 = -1;
    var c0: i32 = -1;
    var c1: i32 = -1;
    var cop1 = false;
    if is_constant(op(b0, 0)) && is_constant(op(b1, 0)) {
        c0 = op(b0, 0); x = op(b0, 1); c1 = op(b1, 0); y = op(b1, 1);
        cop1 = false;
    } else {
        // m_CombineOr(m_BinOp(m_Value(X), m_Constant(C0)), m_Neg(m_Value(X)))
        var okb0 = false;
        if is_constant(op(b0, 1)) { x = op(b0, 1 - 1); c0 = op(b0, 1); okb0 = true; }
        else if bo(b0, OP_SUB) && m_zero_int(op(b0, 0)) { x = op(b0, 1); okb0 = true; }
        var okb1 = false;
        if is_constant(op(b1, 1)) { y = op(b1, 0); c1 = op(b1, 1); okb1 = true; }
        else if bo(b1, OP_SUB) && m_zero_int(op(b1, 0)) { y = op(b1, 1); okb1 = true; }
        if !okb0 || !okb1 { return -1; }
        cop1 = true;
    }
    var opc0 = iop(b0);
    var opc1 = iop(b1);
    var drop_nsw = false;
    if cop1 && opc0 != opc1 {
        if opc0 == OP_SHL || opc1 == OP_SHL { drop_nsw = true; }
        let a0, ax0, ay0 = get_alternate_binop(b0);
        if a0 != 0 {
            opc0 = a0;
            c0 = ay0;
        } else {
            let a1, ax1, ay1 = get_alternate_binop(b1);
            if a1 != 0 { opc1 = a1; c1 = ay1; }
        }
    }
    if opc0 != opc1 || c0 < 0 || c1 < 0 { return -1; }
    let bopc = opc0;
    var mask: i32[>..<] = [];
    sv_mask(s, mask);
    var nc = tf_fold(ce_shufflevector(c0, c1, mask));
    let might = mask_contains(mask, -1) && (is_int_divrem_op(bopc) || is_shift_op(bopc));
    if might { nc = safe_vector_constant_for_binop(bopc, nc, cop1); }
    var v: i32 = -1;
    if x == y {
        v = x;
    } else {
        if !has_one_use(b0) && !has_one_use(b1) { return -1; }
        if might && !cop1 { return -1; }
        v = icb_shuffle(x, y, mask, "");
    }
    let nbo = if cop1 { icb_binop(bopc, v, nc, "") } else { icb_binop(bopc, nc, v, "") };
    if is_inst(nbo) {
        copy_ir_flags(nbo, b0);
        ii_and_ir_flags(nbo, b1);
        if drop_nsw { set_nsw(nbo, false); }
        if mask_contains(mask, -1) && !might { drop_poison_generating_flags(nbo); }
    }
    return ic_replace_inst_uses_with(s, nbo);
}

// foldTruncShuffle(Shuf, IsBigEndian)
fn fold_trunc_shuffle(s: i32, big: bool) -> i32 {
    let dt = vals[s].ty;
    if !is_op(op(s, 0), OP_BITCAST) || !is_poison(op(s, 1)) || !ty_is_int(ty_scalar(dt)) { return -1; }
    let x = op(op(s, 0), 0);
    let st = vals[x].ty;
    if !ty_is_vector(st) || !ty_is_int(ty_scalar(st)) || ty_count(st) != ty_count(dt) ||
       ty_scalar_bits(st) % ty_scalar_bits(dt) != 0 { return -1; }
    let ratio = ty_scalar_bits(st) / ty_scalar_bits(dt);
    var mask: i32[>..<] = [];
    sv_mask(s, mask);
    for i in mask.len {
        if mask[i] == -1 { continue; }
        let lsb = if big { (i + 1) * ratio - 1 } else { i * ratio };
        if (mask[i] as i64) != lsb { return -1; }
    }
    return ic_new_cast(OP_TRUNC, x, dt);
}

// narrowVectorSelect(Shuf, Builder)
fn narrow_vector_select(s: i32) -> i32 {
    if !is_poison(op(s, 1)) || !sv_is_identity_with_extract(s) { return -1; }
    let sel = op(s, 0);
    if !(is_select_inst(sel) && one_use(sel)) { return -1; }
    let cond = op(sel, 0);
    let x = op(sel, 1);
    let y = op(sel, 2);
    let nne = ty_count(vals[s].ty);
    if !(is_inst_op(cond, OP_SHUFFLEVECTOR) && one_use(cond) && is_poison(op(cond, 1))) { return -1; }
    let nc = op(cond, 0);
    if ty_count(vals[nc].ty) != nne || !sv_is_identity_with_padding(cond) { return -1; }
    var mask: i32[>..<] = [];
    sv_mask(s, mask);
    let nx = icb_shuffle1(x, mask, "");
    let ny = icb_shuffle1(y, mask, "");
    return ic_new_select(nc, nx, ny);
}

// foldShuffleOfUnaryOps(Shuf, Builder)
fn fold_shuffle_of_unary_ops(s: i32) -> i32 {
    let s0 = op(s, 0);
    if !is_inst(s0) { return -1; }
    var x: i32 = -1;
    let fn0 = m_fneg(s0);
    if fn0 >= 0 { x = fn0; } else if inst_iid(s0) == IID_fabs { x = cb_arg(s0, 0); } else { return -1; }
    let is_fneg = iop(s0) == OP_FNEG;
    let s1 = op(s, 1);
    if !is_inst(s1) { return -1; }
    var y: i32 = -1;
    let fn1 = m_fneg(s1);
    if fn1 >= 0 { y = fn1; } else if inst_iid(s1) == IID_fabs { y = cb_arg(s1, 0); } else { return -1; }
    if iop(s0) != iop(s1) || (!has_one_use(s0) && !has_one_use(s1)) { return -1; }
    var mask: i32[>..<] = [];
    sv_mask(s, mask);
    let ns = icb_shuffle(x, y, mask, "");
    var nf: i32 = -1;
    if is_fneg { nf = create_inst(OP_FNEG, vals[ns].ty, [ns]); }
    else { nf = ic_new_intrinsic(IID_fabs, [vals[s].ty as i32], [ns]); }
    copy_ir_flags(nf, s0);
    ii_and_ir_flags(nf, s1);
    return nf;
}

// foldCastShuffle(Shuf, Builder)
fn fold_cast_shuffle(s: i32) -> i32 {
    let c0 = op(s, 0);
    if !is_cast_inst(c0) { return -1; }
    let co = iop(c0);
    if !(co == OP_SEXT || co == OP_ZEXT || co == OP_FPTOSI || co == OP_FPTOUI || co == OP_SITOFP || co == OP_UITOFP) { return -1; }
    let cst = vals[op(c0, 0)].ty;
    let sty = vals[s].ty;
    let sot = vals[op(s, 0)].ty;
    if ty_count(sty) > ty_count(sot) { return -1; }
    var mask: i32[>..<] = [];
    sv_mask(s, mask);
    if is_poison(op(s, 1)) && has_one_use(c0) && sv_is_identity_with_extract(s) {
        let ni = icb_shuffle(op(c0, 0), c_poison(cst), mask, "");
        return ic_new_cast(iop(c0), ni, sty);
    }
    let c1 = op(s, 1);
    if !is_cast_inst(c1) || iop(c0) != iop(c1) || cst != vals[op(c1, 0)].ty { return -1; }
    if ld_primitive_bits(cst) > ld_primitive_bits(sot) { return -1; }
    if !has_one_use(c0) && !has_one_use(c1) { return -1; }
    let ns = icb_shuffle(op(c0, 0), op(c1, 0), mask, "");
    return ic_new_cast(co, ns, sty);
}

// foldIdentityExtractShuffle(Shuf)
fn fold_identity_extract_shuffle(s: i32) -> i32 {
    let op0 = op(s, 0);
    let op1 = op(s, 1);
    if !sv_is_identity_with_extract(s) || !is_poison(op1) { return -1; }
    if is_op(op0, OP_BITCAST) && is_inst_op(op(op0, 0), OP_INSERTELEMENT) && m_zero(op(op(op0, 0), 2)) {
        let x = op(op(op0, 0), 1);
        if ld_primitive_bits(vals[x].ty) == ld_primitive_bits(vals[s].ty) { return ic_new_cast(OP_BITCAST, x, vals[s].ty); }
    }
    if !is_inst_op(op0, OP_SHUFFLEVECTOR) { return -1; }
    if !has_one_use(op0) { return -1; }
    let x = op(op0, 0);
    let y = op(op0, 1);
    var m: i32[>..<] = [];
    sv_mask(op0, m);
    let n = ty_count(vals[s].ty);
    var nm: i32[>..<] = [];
    for i in n {
        let em = sv_mask_at(s, i);
        nm.push(if em == -1 { -1 } else { m[i] });
    }
    return ic_new_shuffle(x, y, nm);
}

// foldShuffleWithInsert(Shuf, IC)
fn fold_shuffle_with_insert(s: i32) -> i32 {
    var v0 = op(s, 0);
    var v1 = op(s, 1);
    var mask: i32[>..<] = [];
    sv_mask(s, mask);
    let ne = mask.len;
    let ine = ty_count(vals[v0].ty);
    if is_inst_op(v0, OP_INSERTELEMENT) {
        let ic = m_constant_int_u64(op(v0, 2));
        if ic >= 0 && !mask_contains(mask, ic as i32) { return ic_replace_operand(s, 0, op(v0, 0)); }
    }
    if is_inst_op(v1, OP_INSERTELEMENT) {
        var ic = m_constant_int_u64(op(v1, 2));
        if ic >= 0 {
            ic += ine;
            if !mask_contains(mask, ic as i32) { return ic_replace_operand(s, 1, op(v1, 0)); }
        }
    }
    if ne != ine { return -1; }
    fn scalar_into_op1() -> i32, i32 {
        if !is_inst_op(v0, OP_INSERTELEMENT) { return -1, -1; }
        let idx = m_constant_int(op(v0, 2));
        if idx < 0 { return -1, -1; }
        let sc = op(v0, 1);
        var ni: i64 = -1;
        for i in ne {
            if mask[i] == -1 { continue; }
            if (mask[i] as i64) == ne + i { continue; }
            if ni != -1 || (mask[i] as i64) != ap_sext64(ci_ap(idx)) { return -1, -1; }
            ni = i;
        }
        return sc, c_int(vals[idx].ty, ni);
    }
    let sc1, ix1 = scalar_into_op1();
    if sc1 >= 0 { return ic_new_insert_element(v1, sc1, ix1); }
    let t = v0; v0 = v1; v1 = t;
    commute_shuffle_mask(mask, ne);
    let sc2, ix2 = scalar_into_op1();
    if sc2 >= 0 { return ic_new_insert_element(v1, sc2, ix2); }
    return -1;
}

// foldIdentityPaddedShuffles(Shuf)
fn fold_identity_padded_shuffles(s: i32) -> i32 {
    let s0 = op(s, 0);
    let s1 = op(s, 1);
    if !is_inst_op(s0, OP_SHUFFLEVECTOR) || !sv_is_identity_with_padding(s0) || !is_inst_op(s1, OP_SHUFFLEVECTOR) || !sv_is_identity_with_padding(s1) { return -1; }
    let x = op(s0, 0);
    let y = op(s1, 0);
    fn pow2(n: i64) -> bool { n > 0 && (n & (n - 1)) == 0 }
    if vals[x].ty != vals[y].ty || !pow2(ty_count(vals[s].ty)) || !pow2(ty_count(vals[s0].ty)) || !pow2(ty_count(vals[x].ty)) ||
       m_undef(x) || m_undef(y) { return -1; }
    let narrow = ty_count(vals[x].ty);
    let wide = ty_count(vals[s0].ty);
    var mask: i32[>..<] = [];
    sv_mask(s, mask);
    var nm: i32[>..<] = [];
    for i in mask.len { nm.push(-1); }
    for i in mask.len {
        let m = mask[i] as i64;
        if m == -1 { continue; }
        if m < wide { if sv_mask_at(s0, m) == -1 { continue; } }
        else { if sv_mask_at(s1, m - wide) == -1 { continue; } }
        if m < wide { nm[i] = m as i32; } else { nm[i] = (m - (wide - narrow)) as i32; }
    }
    return ic_new_shuffle(x, y, nm);
}

// simplifyBinOpSplats(SVI)
fn simplify_binop_splats(s: i32) -> i32 {
    if !is_poison(op(s, 1)) || !sv_has_zero_mask(s) || !has_one_use(op(s, 0)) { return -1; }
    let op0 = op(s, 0);
    if !is_binop_inst(op0) { return -1; }
    var x: i32 = -1;
    var y: i32 = -1;
    fn zsplat(v: i32) -> i32 {
        if is_inst_op(v, OP_SHUFFLEVECTOR) && is_poison(op(v, 1)) && sv_has_zero_mask(v) { return op(v, 0); }
        return -1;
    }
    let a = zsplat(op(op0, 0));
    if a >= 0 { x = a; y = op(op0, 1); }
    else {
        let b = zsplat(op(op0, 1));
        if b < 0 { return -1; }
        x = op(op0, 0);
        y = b;
    }
    if vals[x].ty != vals[y].ty { return -1; }
    if !sl_safe_spec_var_replaced(op0) { return -1; }
    let nb = icb_binop(iop(op0), x, y, "");
    if is_inst(nb) { copy_ir_flags(nb, op0); }
    var mask: i32[>..<] = [];
    sv_mask(s, mask);
    return ic_new_shuffle1(nb, mask);
}

// simplifyShuffleVectorInst(Op0, Op1, Mask, RetTy, Q) for a mask that is not an instruction's
fn simplify_shuffle_with_mask(a: i32, b: i32, mask: const i32[:], cx: i32) -> i32 {
    let tmp = ic_new_shuffle(a, b, mask);
    let r = simplify_shufflevector(tmp, a, b, sq_at(cx), RECURSION_LIMIT);
    drop_all_refs(tmp);
    return r;
}

// visitShuffleVectorInst(SVI)
fn visit_shuffle_vector(s: i32) -> i32 {
    let lhs = op(s, 0);
    let rhs = op(s, 1);
    let sv = simplify_shufflevector(s, lhs, rhs, sq_at(s), RECURSION_LIMIT);
    if sv >= 0 { return ic_replace_inst_uses_with(s, sv); }
    let r0 = simplify_binop_splats(s);
    if r0 >= 0 { return r0; }
    if sv_has_zero_mask(s) && !is_poison(rhs) { return ic_replace_operand(s, 1, c_poison(vals[rhs].ty)); }
    if ty_kind(vals[lhs].ty) == TK_SVEC { return -1; }
    let vw = ty_count(vals[s].ty);
    let lw = ty_count(vals[lhs].ty);
    var mask: i32[>..<] = [];
    sv_mask(s, mask);
    if is_op(lhs, OP_BITCAST) && is_op(rhs, OP_BITCAST) {
        let x = op(lhs, 0);
        let y = op(rhs, 0);
        if ty_is_vector(vals[x].ty) && vals[x].ty == vals[y].ty && ty_scalar_bits(vals[x].ty) == ty_scalar_bits(vals[s].ty) &&
           (one_use(lhs) || one_use(rhs)) {
            var nm: u8[>..] = [];
            nm.append(val_name(s));
            nm.append(".uncasted");
            let v = icb_shuffle(x, y, mask, nm);
            return ic_new_cast(OP_BITCAST, v, vals[s].ty);
        }
    }
    if is_op(lhs, OP_BITCAST) && m_undef(rhs) && ty_is_vector(vals[op(lhs, 0)].ty) && vw == lw {
        let x = op(lhs, 0);
        let xt = vals[x].ty;
        var scaled: i32[>..<] = [];
        if ty_kind(xt) == TK_FVEC && scale_shuffle_mask_elts(ty_count(xt), mask, scaled) {
            let v = simplify_shuffle_with_mask(x, c_undef(xt), scaled, s);
            if v >= 0 { return ic_new_cast(OP_BITCAST, v, vals[s].ty); }
        }
    }
    if lhs == rhs {
        var um: i32[>..<] = [];
        create_unary_mask(mask, lw, um);
        return ic_new_shuffle1(lhs, um);
    }
    if m_undef(lhs) {
        sv_commute(s);
        return s;
    }
    let r1 = canonicalize_insert_splat(s);
    if r1 >= 0 { return r1; }
    let r2 = fold_select_shuffle(s);
    if r2 >= 0 { return r2; }
    let r3 = fold_trunc_shuffle(s, dl_big_endian);
    if r3 >= 0 { return r3; }
    let r4 = narrow_vector_select(s);
    if r4 >= 0 { return r4; }
    let r5 = fold_shuffle_of_unary_ops(s);
    if r5 >= 0 { return r5; }
    let r6 = fold_cast_shuffle(s);
    if r6 >= 0 { return r6; }
    let dv = ic_sdve(s, ap_ones(vw), false);
    if dv >= 0 {
        if dv != s { return ic_replace_inst_uses_with(s, dv); }
        return s;
    }
    let r7 = fold_identity_extract_shuffle(s);
    if r7 >= 0 { return r7; }
    let r8 = fold_shuffle_with_insert(s);
    if r8 >= 0 { return r8; }
    let r9 = fold_identity_padded_shuffles(s);
    if r9 >= 0 { return r9; }
    if is_constant(rhs) {
        if is_select_inst(lhs) {
            if ty_is_int(vals[op(lhs, 0)].ty) && (is_poison(rhs) || is_guaranteed_not_to_be_poison(op(lhs, 0), -1, 0)) {
                let r = fold_op_into_select(s, lhs, false, false);
                if r >= 0 { return r; }
            }
        }
        if is_phi_inst(lhs) {
            let r = fold_op_into_phi(s, lhs, true);
            if r >= 0 { return r; }
        }
    }
    sv_mask(s, mask);
    if is_poison(rhs) && can_evaluate_shuffled(lhs, mask, 5) {
        let v = evaluate_in_different_element_order(lhs, mask);
        return ic_replace_inst_uses_with(s, v);
    }
    var made = false;
    if is_shuffle_extracting_from_lhs(s, mask) {
        var v = lhs;
        let me = mask.len;
        let st = vals[v].ty;
        let vbw = dl_size_bits(st);
        let seb = dl_size_bits(ty_elem(st));
        let sne = ty_count(st);
        var bcs: i32[>..<] = [];
        var u = first_use(s);
        while u >= 0 {
            let us = use_user(u);
            u = use_next(u);
            if is_inst_op(us, OP_BITCAST) {
                if use_empty(us) { continue; }
                if has_one_use(us) {
                    let bc2 = use_user(first_use(us));
                    if is_inst_op(bc2, OP_BITCAST) && (ic_eliminable_cast_pair(us, bc2) != 0) { continue; }
                }
                bcs.push(us);
            }
        }
        var nbc_ty: i32[>..<] = [];
        var nbc_v: i32[>..<] = [];
        for bc in bcs {
            var beg = mask[0] as u32 as i64;
            let tt = vals[bc].ty;
            let teb = dl_size_bits(tt);
            if teb == 0 { continue; }
            let tne = vbw / teb;
            let eq = vbw == tne * teb;
            let aligned = ((seb * beg) % teb) == 0;
            if !eq { continue; }
            if !ty_valid_vector_element(tt) { continue; }
            let cst = ty_vector(tt, tne, false);
            if !aligned {
                var sm: i32[>..<] = [];
                for i in sne { sm.push(-1); }
                var ix = beg;
                for i in me { sm[i] = ix as i32; ix++; }
                var nm: u8[>..] = [];
                nm.append(val_name(s));
                nm.append(".extract");
                v = icb_shuffle1(v, sm, nm);
                beg = 0;
            }
            let per = teb / seb;
            beg /= per;
            var k = position(nbc_ty, cst);
            if k < 0 {
                var nm: u8[>..] = [];
                nm.append(val_name(s));
                nm.append(".bc");
                nbc_ty.push(cst);
                nbc_v.push(icb_bitcast(v, cst, nm));
                k = nbc_ty.len - 1;
            }
            var nm2: u8[>..] = [];
            nm2.append(val_name(s));
            nm2.append(".extract");
            let ext = icb_extract_element_k(nbc_v[k], beg as u64, nm2);
            ic_replace_inst_uses_with(bc, ext);
            made = true;
        }
    }
    var lsh = if is_inst_op(lhs, OP_SHUFFLEVECTOR) { lhs } else { -1 };
    var rsh = if is_inst_op(rhs, OP_SHUFFLEVECTOR) { rhs } else { -1 };
    if lsh >= 0 && !is_poison(op(lsh, 1)) && !is_poison(rhs) { lsh = -1; }
    if rsh >= 0 && !is_poison(op(rsh, 1)) { rsh = -1; }
    if lsh < 0 && rsh < 0 { return if made { s } else { -1 }; }
    var l0: i32 = -1;
    var l1: i32 = -1;
    var r0_: i32 = -1;
    var l0w: i64 = 0;
    var r0w: i64 = 0;
    if lsh >= 0 { l0 = op(lsh, 0); l1 = op(lsh, 1); l0w = ty_count(vals[l0].ty); }
    if rsh >= 0 { r0_ = op(rsh, 0); r0w = ty_count(vals[r0_].ty); }
    var nl = lhs;
    var nr = rhs;
    if lsh >= 0 {
        if is_poison(rhs) { nl = l0; nr = l1; }
        else if l0w == lw { nl = l0; }
    }
    if rsh >= 0 && r0w == lw { nr = r0_; }
    if l0 == r0_ { nl = l0; nr = -1; }
    if nl == lhs && nr == rhs { return if made { s } else { -1 }; }
    var lm: i32[>..<] = [];
    var rm: i32[>..<] = [];
    var have_lm = false;
    var have_rm = false;
    if nl != lhs { sv_mask(lsh, lm); have_lm = true; }
    if rsh >= 0 && nr != rhs { sv_mask(rsh, rm); have_rm = true; }
    let nlw = if nl != lhs { l0w } else { lw };
    var nm: i32[>..<] = [];
    var is_splat = true;
    var se: i64 = -1;
    for i in vw {
        var em: i64 = 0;
        let mi = mask[i] as i64;
        if mi < 0 {
            em = -1;
        } else if mi < lw {
            if nl != lhs {
                em = lm[mi] as i64;
                if em >= l0w && is_poison(l1) { em = -1; }
            } else {
                em = mi;
            }
        } else {
            if is_poison(rhs) { em = -1; }
            else if nr != rhs {
                em = rm[mi - lw] as i64;
                if em >= r0w { em = -1; }
            } else {
                em = mi - lw;
            }
            if em >= 0 && nr >= 0 && nl != nr { em += nlw; }
        }
        if em >= 0 {
            if se >= 0 && se != em { is_splat = false; }
            se = em;
        }
        nm.push(em as i32);
    }
    if is_splat || (have_lm && masks_equal(nm, lm)) || (have_rm && masks_equal(nm, rm)) || masks_equal(nm, mask) {
        if nr < 0 { nr = c_poison(vals[nl].ty); }
        return ic_new_shuffle(nl, nr, nm);
    }
    return if made { s } else { -1 };
}
// VectorType::isValidElementType
fn ty_valid_vector_element(t: i32) -> bool {
    let k = ty_kind(t);
    return k == TK_INT || k == TK_BYTE || ty_is_fp(t) || k == TK_PTR || (k == TK_TARGETEXT);
}

// foldExtractionOfVectorDeinterleave(RootZExt): called from visitZExt (InstCombineCasts.cpp)
fn fold_extraction_of_vector_deinterleave(rz: i32) -> i32 {
    if dl_big_endian { return -1; }
    let src = op(rz, 0);
    var svi: i32 = -1;
    var di: i32 = -1;
    var div: i32 = -1;
    if is_inst_op(src, OP_EXTRACTVALUE) && inst_iid(op(src, 0)) == IID_vector_deinterleave2 {
        di = op(src, 0);
        div = cb_arg(di, 0);
    } else if is_inst_op(src, OP_SHUFFLEVECTOR) {
        svi = src;
    } else {
        return -1;
    }
    fn is_deinterleave_shuffle(i: i32) -> i32, i64 {
        if !is_inst_op(i, OP_SHUFFLEVECTOR) || !m_undef(op(i, 1)) { return -1, -1; }
        let v = op(i, 0);
        if ty_kind(vals[v].ty) != TK_FVEC { return -1, -1; }
        let nin = ty_count(vals[v].ty);
        var m: i32[>..<] = [];
        sv_mask(i, m);
        let ok, idx = mask_is_deinterleave_of_factor(m, 2);
        if ok && idx < 2 && mask_is_single_source_impl(m, nin) && m.len * 2 == nin { return v, idx; }
        return -1, -1;
    }
    if svi >= 0 {
        let v, idx = is_deinterleave_shuffle(svi);
        div = v;
        if div < 0 { return -1; }
    } else {
        var u = first_use(di);
        while u >= 0 {
            let us = use_user(u);
            u = use_next(u);
            if !is_inst_op(us, OP_EXTRACTVALUE) || ev_nidx(us) != 1 { return -1; }
        }
    }
    let ivt = vals[div].ty;
    if !ty_is_vector(ivt) { return -1; }
    let iet = ty_elem(ivt);
    if !ty_is_int(iet) { return -1; }
    if (ty_count(ivt) & 1) != 0 { return -1; }
    var fields_i: i32[>..<] = [];
    var fields_k: i64[>..<] = [];
    if svi >= 0 {
        var u = first_use(div);
        while u >= 0 {
            let fi = use_user(u);
            u = use_next(u);
            if !is_inst(fi) { continue; }
            let v, idx = is_deinterleave_shuffle(fi);
            if v != div { continue; }
            if inst_parent(fi) != inst_parent(svi) { continue; }
            if fi != svi && comes_before(fi, svi) { svi = fi; }
            fields_i.push(fi);
            fields_k.push(idx);
        }
    } else {
        var u = first_use(di);
        while u >= 0 {
            let fi = use_user(u);
            u = use_next(u);
            fields_i.push(fi);
            fields_k.push(ev_idx(fi, 0) as i64);
        }
    }
    var rep_i: i32[>..<] = [];
    var rep_k: i64[>..<] = [];
    for f in fields_i.len {
        var u = first_use(fields_i[f]);
        while u >= 0 {
            let z = use_user(u);
            u = use_next(u);
            if !is_inst_op(z, OP_ZEXT) { return -1; }
            let srct = vals[op(z, 0)].ty;
            let ext = ty_vector(ty_int(ty_scalar_bits(srct) * 2), ty_count(srct), ty_kind(srct) == TK_SVEC);
            if vals[z].ty != ext { return -1; }
            rep_i.push(z);
            rep_k.push(fields_k[f]);
        }
    }
    icb_set_insert_point(if di >= 0 { di } else { svi });
    let bw = ty_bits(iet);
    let bt = ty_vector(ty_int(bw * 2), ty_count(ivt) / 2, ty_kind(ivt) == TK_SVEC);
    let fr = icb_freeze(div, "");
    let bc = icb_bitcast(fr, bt, "");
    let nf0 = icb_and(bc, c_int_ap(bt, ap_low_bits(bw * 2, bw)), "");
    let nf1 = icb_lshr(bc, c_int_ty(bt, bw as u64), "", false);
    for k in rep_i.len {
        ic_replace_inst_uses_with(rep_i[k], if rep_k[k] != 0 { nf1 } else { nf0 });
        icw_push(rep_i[k]);
    }
    return rz;
}

// isa<ConstantAggregateZero>(V): LLVM 23's null FP vectors are ConstantFP and null pointer vectors
// ConstantPointerNull, not ConstantAggregateZero
fn is_caz(v: i32) -> bool { vals[v].kind == VK_AGGZERO && !c_is_vector_cfp(v) }
