// InstCombine FP and pointer casts: port of the second half of llvm/lib/Transforms/InstCombine/InstCombineCasts.cpp
// (fitsInFPType, shrinkFPConstant(Vector), getMinimumFPType, visitFPTrunc, visitFPExt, foldItoFPtoI, foldFPtoI,
// visitFPToUI/SI, visitUIToFP/SIToFP, visitIntToPtr, foldPtrToIntOrAddrOfGEP, visitPtrToInt, visitPtrToAddr,
// optimizeVectorResizeWithIntegerBitCasts, collectInsertionElements, optimizeIntegerToVectorInsertions,
// canonicalizeBitCastExtElt, foldBitCastBitwiseLogic, foldBitCastSelect, hasStoreUsersOnly, optimizeBitCastFromPhi,
// foldCopySignIdioms, visitBitCast, visitAddrSpaceCast). The integer casts are in ic_casts.goose.
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
import fpclass;
import instsimplify;
import apint;
import apfloat;
import fpu;
import ic;
import ic_builder;
import ic_common;
import ic_casts;
import ic_calls;
import ic_loadstorealloca;
import ic_combining;

// Type::getFPMantissaWidth (-1 for ppc_fp128)
fn fp_mantissa_width(t: i32) -> i64 {
    let s = ty_scalar(t);
    let k = types[s].kind as i64;
    if k == TK_PPC_FP128 { return -1; }
    return fp_fmt(k).p;
}

// fitsInFPType(F, Sem): converting to `to` (rmNearestTiesToEven) loses no information
fn fits_in_fp_type(kind: i64, lo: u64, hi: u64, to: i64) -> bool {
    let p = fp_decompose(kind, lo, hi);
    let tlo, thi = fp_convert(kind, to, lo, hi);
    let blo, bhi = fp_convert(to, kind, tlo, thi);
    if p.cat == FC_NAN {
        // losesInfo is the lost payload; a signaling NaN becoming quiet is not a loss
        let qlo, qhi = fp_make_quiet(kind, lo, hi);
        let rlo, rhi = fp_make_quiet(kind, blo, bhi);
        return qlo == rlo && qhi == rhi;
    }
    return blo == lo && bhi == hi;
}

// shrinkFPConstant(Ctx, F, PreferBFloat): the type, or -1
fn shrink_fp_constant_kind(kind: i64, lo: u64, hi: u64, prefer_bf: bool) -> i32 {
    if prefer_bf && fits_in_fp_type(kind, lo, hi, TK_BFLOAT) { return ty_simple(TK_BFLOAT); }
    if !prefer_bf && fits_in_fp_type(kind, lo, hi, TK_HALF) { return ty_simple(TK_HALF); }
    if fits_in_fp_type(kind, lo, hi, TK_FLOAT) { return ty_simple(TK_FLOAT); }
    if kind == TK_DOUBLE { return -1; }
    if fits_in_fp_type(kind, lo, hi, TK_DOUBLE) { return ty_simple(TK_DOUBLE); }
    return -1;
}
// shrinkFPConstant(CFP, PreferBFloat)
fn shrink_fp_constant(c: i32, prefer_bf: bool) -> i32 {
    let ty = vals[c].ty;
    let k = types[ty_scalar(ty)].kind as i64;
    if k == TK_PPC_FP128 { return -1; }
    var st = shrink_fp_constant_kind(k, cint_lo(c), cint_hi(c), prefer_bf);
    if st >= 0 && ty_is_vector(ty) { st = ty_vector(st, ty_count(ty), ty_kind(ty) == TK_SVEC); }
    return st;
}
// shrinkFPConstantVector(V, PreferBFloat)
fn shrink_fp_constant_vector(v: i32, prefer_bf: bool) -> i32 {
    if !is_constant(v) || ty_kind(vals[v].ty) != TK_FVEC { return -1; }
    let n = ty_count(vals[v].ty);
    var mint: i32 = -1;
    for k in n {
        let e = c_aggregate_element(v, k);
        if e >= 0 && vals[e].kind == VK_POISON { continue; }
        if e < 0 || vals[e].kind != VK_CFP { return -1; }
        let t = shrink_fp_constant(e, prefer_bf);
        if t < 0 { return -1; }
        if mint < 0 || fp_mantissa_width(t) > fp_mantissa_width(mint) { mint = t; }
    }
    if mint < 0 { return -1; }
    return ty_vector(mint, n, false);
}

// getMinimumFPType(V, PreferredTy, IC)
fn get_minimum_fp_type(v: i32, pref: i32) -> i32 {
    if is_inst_op(v, OP_FPEXT) { return vals[op(v, 0)].ty; }
    if (is_inst_op(v, OP_SITOFP) || is_inst_op(v, OP_UITOFP)) &&
       can_be_casted_exactly_int_to_fp(op(v, 0), pref, is_inst_op(v, OP_SITOFP), v) { return pref; }
    let prefer_bf = ty_kind(ty_scalar(pref)) == TK_BFLOAT;
    if vals[v].kind == VK_CFP && !ty_is_vector(vals[v].ty) {
        let t = shrink_fp_constant(v, prefer_bf);
        if t >= 0 { return t; }
    }
    if is_constant(v) && ty_is_vector(vals[v].ty) {
        let sp = c_splat_value(v);
        if sp >= 0 && vals[sp].kind == VK_CFP {
            let t = shrink_fp_constant(sp, prefer_bf);
            if t >= 0 { return ty_vector(t, ty_count(vals[v].ty), ty_kind(vals[v].ty) == TK_SVEC); }
        }
    }
    let t = shrink_fp_constant_vector(v, prefer_bf);
    if t >= 0 { return t; }
    return vals[v].ty;
}

// isKnownExactCastIntToFP(I)
fn is_known_exact_cast_int_to_fp(i: i32) -> bool {
    return can_be_casted_exactly_int_to_fp(op(i, 0), vals[i].ty, iop(i) == OP_SITOFP, i);
}

// IRBuilder::CreateFPTruncFMF / CreateFPTrunc (TargetFolder for constants)
fn icx_fptrunc(v: i32, ty: i32, fmf: u8, name: const u8[:]) -> i32 {
    if vals[v].ty == ty { return v; }
    if is_constant(v) {
        let r = cf_fold_cast_operand(OP_FPTRUNC, v, ty);
        if r >= 0 { return r; }
    }
    let c = create_inst(OP_FPTRUNC, ty, [v]);
    insts[inst_of(c)].fmf = fmf;
    return icb_insert(c, name);
}

// visitFPTrunc(FPT)
fn visit_fptrunc(fpt: i32) -> i32 {
    let r0 = common_cast_transforms(fpt);
    if r0 >= 0 { return r0; }
    let ty = vals[fpt].ty;
    let b = op(fpt, 0);
    if is_binop_inst(b) && has_one_use(b) {
        let lmt = get_minimum_fp_type(op(b, 0), ty);
        let rmt = get_minimum_fp_type(op(b, 1), ty);
        let opw = fp_mantissa_width(vals[b].ty);
        let lw = fp_mantissa_width(lmt);
        let rw = fp_mantissa_width(rmt);
        let srcw = max(lw, rw);
        let dstw = fp_mantissa_width(ty);
        var nfmf = insts[inst_of(b)].fmf;
        if (nfmf & FMF_NINF) != 0 && (insts[inst_of(fpt)].fmf & FMF_NINF) == 0 { nfmf &= ~FMF_NINF; }
        let o = iop(b);
        if o == OP_FADD || o == OP_FSUB {
            if opw >= 2 * dstw + 1 && dstw >= srcw {
                let l = icx_fptrunc(op(b, 0), ty, icb_fmf, "");
                let r = icx_fptrunc(op(b, 1), ty, icb_fmf, "");
                return icx_new_fbinop(o, l, r, nfmf);
            }
        } else if o == OP_FMUL {
            if opw >= lw + rw && dstw >= srcw {
                let l = icx_fptrunc(op(b, 0), ty, icb_fmf, "");
                let r = icx_fptrunc(op(b, 1), ty, icb_fmf, "");
                return icx_new_fbinop(OP_FMUL, l, r, nfmf);
            }
        } else if o == OP_FDIV {
            if opw >= 2 * dstw && dstw >= srcw {
                let l = icx_fptrunc(op(b, 0), ty, icb_fmf, "");
                let r = icx_fptrunc(op(b, 1), ty, icb_fmf, "");
                return icx_new_fbinop(OP_FDIV, l, r, nfmf);
            }
        } else if o == OP_FREM {
            if srcw != opw {
                let mt = if lw == srcw { lmt } else { rmt };
                let l = icx_fptrunc(op(b, 0), mt, icb_fmf, "");
                let r = icx_fptrunc(op(b, 1), mt, icb_fmf, "");
                let ex = icx_fbinop(OP_FREM, l, r, insts[inst_of(b)].fmf, "");
                return ic_new_fp_cast(ex, ty);
            }
        }
    }
    let opi = op(fpt, 0);
    if is_inst(opi) && has_one_use(opi) {
        var fmf = insts[inst_of(fpt)].fmf;
        if is_fp_math_operator(opi) { fmf &= insts[inst_of(opi)].fmf; }
        let x = m_fneg(opi);
        if x >= 0 {
            let it = icx_fptrunc(x, ty, fmf, "");
            let ng = icx_fneg(it, fmf, "");
            return ic_replace_inst_uses_with(fpt, ng);
        }
        if is_select_inst(opi) {
            let c = op(opi, 0);
            let tx = m_fpext_x(op(opi, 1));
            if tx >= 0 && vals[tx].ty == ty {
                let ny = icx_fptrunc(op(opi, 2), ty, fmf, "");
                let s = icx_select_fmf(c, tx, ny, fmf, "narrow.sel", opi);
                return ic_replace_inst_uses_with(fpt, s);
            }
            let fx = m_fpext_x(op(opi, 2));
            if fx >= 0 && vals[fx].ty == ty {
                let ny = icx_fptrunc(op(opi, 1), ty, fmf, "");
                let s = icx_select_fmf(c, ny, fx, fmf, "narrow.sel", opi);
                return ic_replace_inst_uses_with(fpt, s);
            }
        }
    }
    let ii = op(fpt, 0);
    let id = inst_iid(ii);
    if id == IID_ceil || id == IID_fabs || id == IID_floor || id == IID_nearbyint || id == IID_rint || id == IID_round ||
       id == IID_roundeven || id == IID_trunc {
        let src = cb_arg(ii, 0);
        if has_one_use(src) {
            var ok = true;
            if id != IID_fabs { ok = is_inst_op(src, OP_FPEXT) && vals[op(src, 0)].ty == ty; }
            if ok {
                let it = icx_fptrunc(src, ty, icb_fmf, "");
                let ov = icx_decl(id, [ty]);
                if cb_nbundles(ii) > 0 { ic_not_ported("visitFPTrunc of an intrinsic with operand bundles"); }
                let nc = icx_new_call(ov, [it]);
                var nm: u8[>..] = [];
                nm.append(val_name(ii));
                if nm.len > 0 { set_name(nc, nm); }
                insts[inst_of(nc)].fmf = insts[inst_of(fpt)].fmf;
                return nc;
            }
        }
    }
    let si = shrink_insert_elt(fpt);
    if si >= 0 { return si; }
    let src = op(fpt, 0);
    if is_inst_op(src, OP_SITOFP) || is_inst_op(src, OP_UITOFP) {
        if is_known_exact_cast_int_to_fp(src) { return ic_new_cast(iop(src), op(src, 0), ty); }
    }
    return -1;
}
// CastInst::CreateFPCast(V, Ty): fpext / fptrunc / bitcast by width
fn ic_new_fp_cast(v: i32, ty: i32) -> i32 {
    let sb = ty_prim_bits(ty_scalar(vals[v].ty));
    let db = ty_prim_bits(ty_scalar(ty));
    let o = if sb == db { OP_BITCAST } else if sb > db { OP_FPTRUNC } else { OP_FPEXT };
    return ic_new_cast(o, v, ty);
}
// IRBuilder::CreateSelectFMF(C, T, F, FMF, Name, MDFrom)
fn icx_select_fmf(c: i32, t: i32, f: i32, fmf: u8, name: const u8[:], mdfrom: i32) -> i32 {
    if is_constant(c) && is_constant(t) && is_constant(f) {
        let r = cf_select(c, t, f);
        if r >= 0 { return r; }
    }
    let s = ic_new_select(c, t, f);
    if mdfrom >= 0 { icb_copy_select_md(s, mdfrom); }
    if is_fp_math_operator(s) { insts[inst_of(s)].fmf = fmf; }
    return icb_insert(s, name);
}

// visitFPExt(FPExt)
fn visit_fpext(fe: i32) -> i32 {
    let ty = vals[fe].ty;
    let src = op(fe, 0);
    if is_inst_op(src, OP_SITOFP) || is_inst_op(src, OP_UITOFP) {
        if is_known_exact_cast_int_to_fp(src) { return ic_new_cast(iop(src), op(src, 0), ty); }
    }
    return common_cast_transforms(fe);
}

// foldItoFPtoI(FI) for fptosi/fptoui (saturating = the fpto[su]i.sat intrinsics)
fn fold_ito_fpto_i(fi: i32) -> i32 {
    let sat = is_inst_op(fi, OP_CALL);
    let o0 = op(fi, 0);
    if !is_inst_op(o0, OP_UITOFP) && !is_inst_op(o0, OP_SITOFP) { return -1; }
    let x = op(o0, 0);
    let xt = vals[x].ty;
    let dt = vals[fi].ty;
    let in_signed = iop(o0) == OP_SITOFP;
    let out_signed = if sat { call_iid(fi) == IID_fptosi_sat } else { iop(fi) == OP_FPTOSI };
    if !is_known_exact_cast_int_to_fp(o0) {
        if !sat {
            let outsz = ty_scalar_bits(dt);
            if outsz > fp_mantissa_width(vals[o0].ty) { return -1; }
        } else {
            return -1;
        }
    }
    let sw = ty_scalar_bits(xt);
    let dw = ty_scalar_bits(dt);
    if sat && (in_signed != out_signed || dw < sw) { return -1; }
    if dw > sw {
        if in_signed && out_signed { return ic_new_cast(OP_SEXT, x, dt); }
        return ic_new_cast(OP_ZEXT, x, dt);
    }
    if dw < sw { return ic_new_cast(OP_TRUNC, x, dt); }
    return ic_replace_inst_uses_with(fi, x);
}

// foldFPtoI(FI, IC)
fn fold_fp_to_i(fi: i32) -> i32 {
    let mask = if iop(fi) == OP_FPTOUI { FCL_POS_NORMAL } else { FCL_NORMAL };
    kb_cxt = fi;
    let fc = known_fp_class(op(fi, 0), mask, 0, 0);
    if kfc_never(fc, mask) { return ic_replace_inst_uses_with(fi, c_null(vals[fi].ty)); }
    let signed = iop(fi) == OP_FPTOSI;
    let d = op(fi, 0);
    if !(one_use(d) && bo(d, OP_FDIV)) { return -1; }
    let cv = op(d, 0);
    if !is_inst_op(cv, if signed { OP_SITOFP } else { OP_UITOFP }) { return -1; }
    let apf = m_apfloat(op(d, 1));
    if apf < 0 { return -1; }
    let x = op(cv, 0);
    let ity = vals[x].ty;
    if vals[fi].ty != ity { return -1; }
    let iw = ty_scalar_bits(ity);
    let kind = types[vals[apf].ty].kind as i64;
    if kind == TK_PPC_FP128 { ic_not_ported("foldFPtoI with a ppc_fp128 divisor"); }
    let prec = fp_fmt(kind).p;
    if prec + (if signed { 1 } else { 0 }) < iw { return -1; }
    // APFloat::isInteger and convertToInteger(rmTowardZero) exactness
    let ok, div = fp_to_integer_exact(kind, cint_lo(apf), cint_hi(apf), iw, signed);
    if !ok { return -1; }
    if ap_is_zero(div) { return -1; }
    if signed && ap_is_all_ones(div) { return -1; }
    let c = c_int_ap(ity, div);
    return ic_new_binop(if signed { OP_SDIV } else { OP_UDIV }, x, c);
}
// APF->isInteger() + convertToInteger(APSInt(w, !signed), rmTowardZero, &IsExact) with IsExact: (ok, value)
fn fp_to_integer_exact(kind: i64, lo: u64, hi: u64, w: i64, signed: bool) -> bool, AP {
    let p = fp_decompose(kind, lo, hi);
    if p.cat == FC_NAN || p.cat == FC_INF { return false, ap_zero(w); }
    if p.cat == FC_ZERO { return true, ap_zero(w); }
    let ilo, ihi = fp_round_to_integral(kind, lo, hi, FRM_ZERO);
    if ilo != lo || ihi != hi { return false, ap_zero(w); }
    var mag: u32[>..<] = [];
    let isneg = fp_trunc_magnitude(kind, lo, hi, mag);
    // the magnitude as an APInt of width w (+1 to detect overflow)
    var ws: u64[>..] = [];
    var k: i64 = 0;
    while k < mag.len {
        var word: u64 = mag[k] as u64;
        if k + 1 < mag.len { word |= (mag[k + 1] as u64) << 32; }
        ws.push(word);
        k += 2;
    }
    let big = ap_from_words(64 * max(1, ws.len), ws);
    if ap_active_bits(big) > w { return false, ap_zero(w); }
    var v = ap_zext_or_trunc(big, w);
    if p.neg {
        if !signed { return false, ap_zero(w); }
        if ap_active_bits(big) == w && !ap_is_min_signed(v) { return false, ap_zero(w); }
        v = ap_neg(v);
    } else if signed && ap_is_neg(v) {
        return false, ap_zero(w);
    }
    return true, v;
}

fn visit_fptoui(fi: i32) -> i32 {
    let r = fold_ito_fpto_i(fi);
    if r >= 0 { return r; }
    let r2 = fold_fp_to_i(fi);
    if r2 >= 0 { return r2; }
    return common_cast_transforms(fi);
}
fn visit_fptosi(fi: i32) -> i32 { visit_fptoui(fi) }

// visitUIToFP(CI)
fn visit_uitofp(ci: i32) -> i32 {
    let r = common_cast_transforms(ci);
    if r >= 0 { return r; }
    if !has_flag(ci, FL_NNEG) && is_known_non_negative_v(op(ci, 0), -1) {
        set_nneg(ci, true);
        return ci;
    }
    return -1;
}
// visitSIToFP(CI)
fn visit_sitofp(ci: i32) -> i32 {
    let r = common_cast_transforms(ci);
    if r >= 0 { return r; }
    if is_known_non_negative_v(op(ci, 0), -1) {
        let ui = ic_new_cast(OP_UITOFP, op(ci, 0), vals[ci].ty);
        set_nneg(ui, true);
        return ui;
    }
    return -1;
}

// DL.getIntPtrType(AS) with the shape of t (Type::getWithNewType)
fn int_ptr_type_like(t: i32, as_: i64) -> i32 { ty_with_elem(t, ty_int(dl_ptr(as_).bits)) }

// visitIntToPtr(CI)
fn visit_inttoptr(ci: i32) -> i32 {
    let as_ = ptr_as(ty_scalar(vals[ci].ty));
    let src = op(ci, 0);
    if ty_scalar_bits(vals[src].ty) != dl_ptr(as_).bits {
        let ty = int_ptr_type_like(vals[src].ty, as_);
        let p = icb_zext_or_trunc(src, ty, "");
        return ic_new_cast(OP_INTTOPTR, p, vals[ci].ty);
    }
    if one_use(src) && bo(src, OP_ADD) {
        for k in 2 {
            let pt = op(src, k);
            let off = op(src, 1 - k);
            if !is_op(pt, OP_PTRTOINT) { continue; }
            let base = op(pt, 0);
            // m_PtrToIntSameSize: the int type has the pointer's size
            if ty_scalar_bits(vals[pt].ty) != dl_ptr(ptr_as(ty_scalar(vals[base].ty))).bits { continue; }
            if ptr_as(ty_scalar(vals[ci].ty)) != ptr_as(ty_scalar(vals[base].ty)) { break; }
            var all = true;
            var u = vals[ci].first_use;
            while u >= 0 {
                let us = uses[u].user;
                u = uses[u].next;
                if is_inst_op(us, OP_ICMP) || is_inst_op(us, OP_PTRTOINT) { continue; }
                if is_phi_inst(us) && has_one_use(us) {
                    let pu = uses[vals[us].first_use].user;
                    if is_inst_op(pu, OP_ICMP) || is_inst_op(pu, OP_PTRTOINT) { continue; }
                }
                all = false;
                break;
            }
            if !all { break; }
            let g = create_inst(OP_GEP, gep_ret_type(base, [off]), [base, off]);
            insts[inst_of(g)].ty2 = T_I8;
            return g;
        }
    }
    return common_cast_transforms(ci);
}

// foldPtrToIntOrAddrOfGEP(IntTy, Ptr)
fn fold_ptr_to_int_or_addr_of_gep(ity: i32, ptr0: i32) -> i32 {
    var ptr = ptr0;
    let pty = vals[ptr].ty;
    var geps: i32[>..<] = [];
    loop {
        if !is_gep_operator(ptr) || !has_one_use(ptr) { break; }
        geps.push(ptr);
        ptr = op(ptr, 0);
    }
    if geps.len == 0 || pty != vals[ptr].ty { return -1; }
    var res: i32 = -1;
    let idxty = dl_index_type(pty);
    if one_use(ptr) && is_op(ptr, OP_INTTOPTR) && vals[op(ptr, 0)].ty == ity && ity == idxty {
        res = op(ptr, 0);
    } else if vals[ptr].kind == VK_CNULL {
        res = c_null(idxty);
    } else {
        return -1;
    }
    var k = geps.len;
    while k > 0 {
        k--;
        let g = geps[k];
        let off = emit_gep_offset(g, false);
        res = icb_add_nw(res, off, "", (op_flags(g) & GEP_NUW) != 0, false);
    }
    return icb_zext_or_trunc(res, ity, "");
}

// IRBuilder::CreatePtrToInt(V, DestTy)
fn icb_ptrtoint(v: i32, ty: i32, name: const u8[:]) -> i32 { icb_cast(OP_PTRTOINT, v, ty, name) }

// visitPtrToInt(CI)
fn visit_ptrtoint(ci: i32) -> i32 {
    let src = op(ci, 0);
    let sty = vals[src].ty;
    let ty = vals[ci].ty;
    let as_ = ptr_as(ty_scalar(sty));
    let tsz = ty_scalar_bits(ty);
    let psz = dl_ptr(as_).bits;
    if tsz != psz {
        let ipt = int_ptr_type_like(sty, as_);
        let p = icb_ptrtoint(src, ipt, "");
        return ic_new_int_cast(p, ty, false);
    }
    if one_use(src) && m_intrinsic(src, IID_ptrmask) && vals[op(src, 1)].ty == ty {
        return ic_new_binop(OP_AND, icb_ptrtoint(op(src, 0), ty, ""), op(src, 1));
    }
    let v = fold_ptr_to_int_or_addr_of_gep(ty, src);
    if v >= 0 { return ic_replace_inst_uses_with(ci, v); }
    if one_use(src) && is_inst_op(src, OP_INSERTELEMENT) && is_op(op(src, 0), OP_INTTOPTR) && vals[op(op(src, 0), 0)].ty == ty {
        let vec = op(op(src, 0), 0);
        let nc = icb_ptrtoint(op(src, 1), ty_scalar(ty), "");
        return create_inst(OP_INSERTELEMENT, ty, [vec, nc, op(src, 2)]);
    }
    return common_cast_transforms(ci);
}

// visitPtrToAddr(CI)
fn visit_ptrtoaddr(ci: i32) -> i32 {
    let src = op(ci, 0);
    let ty = vals[ci].ty;
    if one_use(src) && m_intrinsic(src, IID_ptrmask) && vals[op(src, 1)].ty == ty {
        let pa = icb_cast(OP_PTRTOADDR, op(src, 0), ty_with_elem(vals[op(src, 0)].ty, ty_int(dl_ptr(ptr_as(ty_scalar(vals[op(src, 0)].ty))).idx)), "");
        return ic_new_binop(OP_AND, pa, op(src, 1));
    }
    let v = fold_ptr_to_int_or_addr_of_gep(ty, src);
    if v >= 0 { return ic_replace_inst_uses_with(ci, v); }
    return common_cast_transforms(ci);
}

// visitAddrSpaceCast(CI)
fn visit_addrspacecast(ci: i32) -> i32 { common_cast_transforms(ci) }

// optimizeVectorResizeWithIntegerBitCasts(InVal, DestTy, IC)
fn optimize_vector_resize_with_integer_bitcasts(inval0: i32, dt: i32) -> i32 {
    var inval = inval0;
    var st = vals[inval].ty;
    if ty_scalar(st) != ty_scalar(dt) {
        if ty_prim_bits_any(ty_scalar(st)) != ty_prim_bits_any(ty_scalar(dt)) { return -1; }
        st = ty_vector(ty_scalar(dt), ty_count(st), false);
        inval = icb_bitcast(inval, st, "");
    }
    if dl_big_endian { ic_not_ported("optimizeVectorResizeWithIntegerBitCasts on big-endian targets"); }
    let se = ty_count(st);
    let de = ty_count(dt);
    var mask: i32[>..<] = [];
    var v2: i32 = -1;
    if se > de {
        v2 = c_poison(st);
        for k in de { mask.push(k as i32); }
    } else {
        v2 = c_null(st);
        for k in se { mask.push(k as i32); }
        for k in (de - se) { mask.push(se as i32); }
    }
    return ic_new_shuffle(inval, v2, mask);
}

fn is_multiple_of_type_size(v: i64, t: i32) -> bool { v % ty_prim_bits_any(t) == 0 }
fn get_type_size_index(v: i64, t: i32) -> i64 { v / ty_prim_bits_any(t) }

// collectInsertionElements(V, Shift, Elements, VecEltTy, isBigEndian): Elements is ci_elems[base..base+n]
var ci_elems: i32[>..<];
recursive fn collect_insertion_elements(v: i32, shift0: i64, base: i64, n: i64, et: i32) -> bool {
    var shift = shift0;
    if vals[v].kind == VK_POISON { return true; }
    if vals[v].ty == et {
        if is_constant(v) && is_null_value(v) { return true; }
        let ei = get_type_size_index(shift, et);
        if ci_elems[base + ei] >= 0 { return false; }
        ci_elems[base + ei] = v;
        return true;
    }
    if is_constant(v) {
        let ne = get_type_size_index(dl_prim_size_bits(vals[v].ty), et);
        if ne == 1 { return collect_insertion_elements(ce_cast(OP_BITCAST, v, et), shift, base, n, et); }
        var c = v;
        if !ty_is_int(vals[c].ty) { c = ce_cast(OP_BITCAST, c, ty_int(dl_prim_size_bits(vals[c].ty))); }
        let es = ty_prim_bits_any(et);
        let eit = ty_int(es);
        for i in ne {
            let si = i * es;
            var piece = cf_fold_binop_operands(OP_LSHR, c, c_int_ty(vals[c].ty, si as u64));
            if piece < 0 { return false; }
            piece = ce_cast(OP_TRUNC, piece, eit);
            if !collect_insertion_elements(piece, si + shift, base, n, et) { return false; }
        }
        return true;
    }
    if !has_one_use(v) { return false; }
    if !is_inst(v) { return false; }
    let o = iop(v);
    if o == OP_BITCAST {
        if ty_is_vector(vals[op(v, 0)].ty) { return false; }
        return collect_insertion_elements(op(v, 0), shift, base, n, et);
    }
    if o == OP_ZEXT {
        if !is_multiple_of_type_size(dl_prim_size_bits(vals[op(v, 0)].ty), et) { return false; }
        return collect_insertion_elements(op(v, 0), shift, base, n, et);
    }
    if o == OP_OR {
        return collect_insertion_elements(op(v, 0), shift, base, n, et) && collect_insertion_elements(op(v, 1), shift, base, n, et);
    }
    if o == OP_SHL {
        let c = op(v, 1);
        if vals[c].kind != VK_CINT || ty_is_vector(vals[c].ty) { return false; }
        shift += ap_zext64(ci_ap(c)) as i64;
        if !is_multiple_of_type_size(shift, et) { return false; }
        return collect_insertion_elements(op(v, 0), shift, base, n, et);
    }
    return false;
}

// optimizeIntegerToVectorInsertions(CI, IC)
fn optimize_integer_to_vector_insertions(ci: i32) -> i32 {
    let dt = vals[ci].ty;
    let inp = op(ci, 0);
    if vals[inp].kind == VK_UNDEF || vals[inp].kind == VK_POISON { return -1; }
    if dl_big_endian { ic_not_ported("optimizeIntegerToVectorInsertions on big-endian targets"); }
    let n = ty_count(dt);
    let base = ci_elems.len;
    for k in n { ci_elems.push(-1); }
    let ok = collect_insertion_elements(inp, 0, base, n, ty_scalar(dt));
    var elems: i32[>..<] = [];
    for k in n { elems.push(ci_elems[base + k]); }
    ci_elems.resize(base);
    if !ok { return -1; }
    var res = c_null(dt);
    for k in n {
        if elems[k] < 0 { continue; }
        res = icb_insert_element_k(res, elems[k], k as u64, "");
    }
    return res;
}

// canonicalizeBitCastExtElt(BitCast, IC)
fn canonicalize_bitcast_ext_elt(bc: i32) -> i32 {
    let s = op(bc, 0);
    if !(one_use(s) && is_inst_op(s, OP_EXTRACTELEMENT)) { return -1; }
    let vec = op(s, 0);
    let idx = op(s, 1);
    let dt = vals[bc].ty;
    let vt = vals[vec].ty;
    if ty_is_valid_vector_element(dt) {
        let nvt = ty_vector(dt, ty_count(vt), ty_kind(vt) == TK_SVEC);
        let nbc = icb_bitcast(vec, nvt, "bc");
        return create_inst(OP_EXTRACTELEMENT, dt, [nbc, idx]);
    }
    if ty_is_vector(dt) && ty_kind(vt) == TK_FVEC && ty_count(vt) == 1 { return ic_new_cast(OP_BITCAST, vec, dt); }
    return -1;
}
// VectorType::isValidElementType
fn ty_is_valid_vector_element(t: i32) -> bool {
    let k = ty_kind(t);
    return ty_is_int(t) || ty_is_fp(t) || k == TK_PTR || k == TK_BYTE || (k == TK_TARGETEXT && false);
}

// foldBitCastBitwiseLogic(BitCast, Builder)
fn fold_bitcast_bitwise_logic(bc: i32) -> i32 {
    let dt = vals[bc].ty;
    let b = op(bc, 0);
    if !(one_use(b) && is_binop_inst(b)) || !is_logic_op(iop(b)) { return -1; }
    if !ty_is_vector(dt) || !ty_is_vector(vals[b].ty) { return -1; }
    if is_fp_or_fp_vec(dt) {
        let b0 = op(b, 0);
        let b1 = op(b, 1);
        if one_use(b0) && is_op(b0, OP_BITCAST) && one_use(b1) && is_op(b1, OP_BITCAST) {
            let x = op(b0, 0);
            let y = op(b1, 0);
            if is_fp_or_fp_vec(vals[x].ty) && is_int_or_int_vec(vals[y].ty) {
                let co = icb_bitcast(b0, vals[y].ty, "");
                let nb = icb_binop(iop(b), co, y, "");
                return ic_new_cast(ld_bit_or_pointer_cast_opcode(vals[nb].ty, dt), nb, dt);
            }
            if is_int_or_int_vec(vals[x].ty) && is_fp_or_fp_vec(vals[y].ty) {
                let co = icb_bitcast(b1, vals[x].ty, "");
                let nb = icb_binop(iop(b), co, x, "");
                return ic_new_cast(ld_bit_or_pointer_cast_opcode(vals[nb].ty, dt), nb, dt);
            }
        }
        return -1;
    }
    if !is_int_or_int_vec(dt) { return -1; }
    let b0 = op(b, 0);
    if one_use(b0) && is_op(b0, OP_BITCAST) && vals[op(b0, 0)].ty == dt && !is_constant(op(b0, 0)) {
        let c1 = icb_bitcast(op(b, 1), dt, "");
        return ic_new_binop(iop(b), op(b0, 0), c1);
    }
    let b1 = op(b, 1);
    if one_use(b1) && is_op(b1, OP_BITCAST) && vals[op(b1, 0)].ty == dt && !is_constant(op(b1, 0)) {
        let c0 = icb_bitcast(op(b, 0), dt, "");
        return ic_new_binop(iop(b), c0, op(b1, 0));
    }
    if is_constant(b1) {
        let c0 = icb_bitcast(op(b, 0), dt, "");
        let cc = icb_bitcast(b1, dt, "");
        return ic_new_binop(iop(b), c0, cc);
    }
    return -1;
}

// foldBitCastSelect(BitCast, Builder)
fn fold_bitcast_select(bc: i32) -> i32 {
    let sel = op(bc, 0);
    if !(one_use(sel) && is_select_inst(sel)) { return -1; }
    let cond = op(sel, 0);
    let tv = op(sel, 1);
    let fv = op(sel, 2);
    let ct = vals[cond].ty;
    let dt = vals[bc].ty;
    let dvec = ty_is_vector(dt);
    if ty_is_vector(ct) {
        if !dvec || ty_count(ct) != ty_count(dt) || ty_kind(ct) != ty_kind(dt) { return -1; }
    }
    let svec = ty_is_vector(vals[tv].ty);
    if (is_constant(tv) || is_constant(fv)) && (!dvec || (svec && ty_kind(dt) == ty_kind(vals[tv].ty) && ty_count(dt) <= ty_count(vals[tv].ty))) {
        let ct2 = icb_bitcast(tv, dt, "");
        let cf2 = icb_bitcast(fv, dt, "");
        return ic_new_select_md(cond, ct2, cf2, sel);
    }
    if dvec != svec { return -1; }
    if one_use(tv) && is_op(tv, OP_BITCAST) && vals[op(tv, 0)].ty == dt && !is_constant(op(tv, 0)) {
        let cv = icb_bitcast(fv, dt, "");
        return ic_new_select_md(cond, op(tv, 0), cv, sel);
    }
    if one_use(fv) && is_op(fv, OP_BITCAST) && vals[op(fv, 0)].ty == dt && !is_constant(op(fv, 0)) {
        let cv = icb_bitcast(tv, dt, "");
        return ic_new_select_md(cond, cv, op(fv, 0), sel);
    }
    return -1;
}

// hasStoreUsersOnly(CI)
fn has_store_users_only(ci: i32) -> bool {
    var u = vals[ci].first_use;
    while u >= 0 { if !is_inst_op(uses[u].user, OP_STORE) { return false; } u = uses[u].next; }
    return true;
}

// optimizeBitCastFromPhi(CI, PN)
fn optimize_bitcast_from_phi(ci: i32, pn: i32) -> i32 {
    if has_store_users_only(ci) { return -1; }
    let src = op(ci, 0);
    let srct = vals[src].ty;
    let dt = vals[ci].ty;
    var wl: i32[>..<] = [];
    var old: i32[>..<] = [];
    wl.push(pn);
    old.push(pn);
    while wl.len > 0 {
        let opn = wl.pop();
        for k in nops(opn) {
            let iv = op(opn, k);
            if is_constant(iv) { continue; }
            if is_inst_op(iv, OP_LOAD) {
                let addr = op(iv, 0);
                if addr == ci || is_inst_op(addr, OP_LOAD) { return -1; }
                if ty_kind(dt) == TK_X86_AMX { return -1; }
                if has_one_use(iv) && insts[inst_of(iv)].ord == 0 && (insts[inst_of(iv)].bits & 1) == 0 { continue; }
                return -1;
            }
            if is_phi_inst(iv) {
                var seen = false;
                for x in old { if x == iv { seen = true; } }
                if !seen { old.push(iv); wl.push(iv); }
                continue;
            }
            if !is_inst_op(iv, OP_BITCAST) { return -1; }
            if vals[op(iv, 0)].ty != dt || vals[iv].ty != srct { return -1; }
        }
    }
    for opn in old {
        var u = vals[opn].first_use;
        while u >= 0 {
            let v = uses[u].user;
            u = uses[u].next;
            if is_inst_op(v, OP_STORE) {
                if insts[inst_of(v)].ord != 0 || (insts[inst_of(v)].bits & 1) != 0 || op(v, 0) != opn { return -1; }
            } else if is_inst_op(v, OP_BITCAST) {
                if vals[op(v, 0)].ty != srct || vals[v].ty != dt { return -1; }
            } else if is_phi_inst(v) {
                var seen = false;
                for x in old { if x == v { seen = true; } }
                if !seen { return -1; }
            } else {
                return -1;
            }
        }
    }
    var newp: i32[>..<] = [];
    for opn in old {
        icb_set_insert_point(opn);
        newp.push(icb_phi(dt, ""));
    }
    for j in old.len {
        let opn = old[j];
        let np = newp[j];
        for k in nops(opn) {
            let v = op(opn, k);
            var nv: i32 = -1;
            if is_constant(v) { nv = ce_cast(OP_BITCAST, v, dt); }
            else if is_inst_op(v, OP_LOAD) {
                icb_set_insert_point(v);
                nv = combine_load_to_new_type(v, dt, "");
                ic_replace_inst_uses_with(v, c_poison(vals[v].ty));
                ic_erase(v);
            } else if is_inst_op(v, OP_BITCAST) { nv = op(v, 0); }
            else if is_phi_inst(v) {
                for q in old.len { if old[q] == v { nv = newp[q]; } }
            }
            phi_add_incoming(np, nv, phi_block(opn, k));
        }
    }
    var retval: i32 = -1;
    for j in old.len {
        let opn = old[j];
        let np = newp[j];
        var u = vals[opn].first_use;
        while u >= 0 {
            let v = uses[u].user;
            u = uses[u].next;
            if is_inst_op(v, OP_STORE) {
                icb_set_insert_point(v);
                let nbc = icb_bitcast(np, srct, "");
                set_op(v, 0, nbc);
                icw_push(v);
            } else if is_inst_op(v, OP_BITCAST) {
                let r = ic_replace_inst_uses_with(v, np);
                if v == ci { retval = r; }
            }
        }
    }
    return retval;
}

// m_ElementWiseBitCast(X): a bitcast (instruction or constant expression) keeping the element count
fn m_elementwise_bitcast_x(v: i32) -> i32 {
    if !is_op(v, OP_BITCAST) { return -1; }
    let st = vals[op(v, 0)].ty;
    let dt = vals[v].ty;
    if ty_is_vector(st) != ty_is_vector(dt) { return -1; }
    if ty_is_vector(st) && (ty_count(st) != ty_count(dt) || ty_kind(st) != ty_kind(dt)) { return -1; }
    return op(v, 0);
}

// foldCopySignIdioms(CI, Builder, SQ)
fn fold_copy_sign_idioms(ci: i32) -> i32 {
    let fty = vals[ci].ty;
    if !is_fp_or_fp_vec(fty) { return -1; }
    let o = m_elementwise_bitcast_x(ci);
    if o < 0 || !bo(o, OP_OR) { return -1; }
    for k in 2 {
        let a = op(o, k);
        let y = op(o, 1 - k);
        if bo(a, OP_AND) && m_sign_mask(op(a, 1)) {
            let x = m_elementwise_bitcast_x(op(a, 0));
            if x >= 0 {
                if vals[x].ty != fty { return -1; }
                if !is_known_non_negative_v(y, ci) { return -1; }
                return icx_copysign(icb_bitcast(y, fty, ""), x, icb_fmf);
            }
        }
    }
    return -1;
}

// ShuffleVectorInst::isReverse
fn shuffle_is_reverse(s: i32) -> bool {
    let n = ty_count(vals[op(s, 0)].ty);
    if sde_mask_len(s) != n || !icx_shuffle_is_single_source(s) || n < 2 { return false; }
    for k in n {
        let x = sde_mask_at(s, k);
        if x < 0 { continue; }
        if x != n - 1 - k && x != 2 * n - 1 - k { return false; }
    }
    return true;
}

// visitBitCast(CI)
fn visit_bitcast(ci: i32) -> i32 {
    let src = op(ci, 0);
    let st = vals[src].ty;
    let dt = vals[ci].ty;
    if dt == st { return ic_replace_inst_uses_with(ci, src); }
    if ty_kind(dt) == TK_FVEC && ty_is_int(st) {
        if is_inst_op(src, OP_TRUNC) || is_inst_op(src, OP_ZEXT) {
            let bcin = op(src, 0);
            if is_inst_op(bcin, OP_BITCAST) && ty_is_vector(vals[op(bcin, 0)].ty) {
                let r = optimize_vector_resize_with_integer_bitcasts(op(bcin, 0), dt);
                if r >= 0 { return r; }
            }
        }
        let v = optimize_integer_to_vector_insertions(ci);
        if v >= 0 { return ic_replace_inst_uses_with(ci, v); }
    }
    if ty_kind(st) == TK_FVEC {
        if ty_count(st) == 1 {
            if !ty_is_vector(dt) {
                let e = icb_extract_element_k(src, 0, "");
                return ic_new_cast(OP_BITCAST, e, dt);
            }
            if is_inst_op(src, OP_INSERTELEMENT) { return ic_new_cast(OP_BITCAST, op(src, 1), dt); }
        }
        let bw = ty_scalar_bits(dt);
        if one_use(src) && is_inst_op(src, OP_INSERTELEMENT) && one_use(op(src, 0)) && is_op(op(src, 0), OP_BITCAST) {
            let x = op(op(src, 0), 0);
            let y = op(src, 1);
            let ic = m_constant_int(op(src, 2));
            if ic >= 0 && ty_bits(vals[ic].ty) <= 64 && ty_is_int(dt) && vals[x].ty == dt && ty_is_int(vals[y].ty) && is_desirable_int_type(bw) {
                if dl_big_endian { ic_not_ported("visitBitCast insert-element fold on big-endian targets"); }
                if ap_zext64(ci_ap(ic)) == 0 {
                    let ew = ty_scalar_bits(vals[y].ty);
                    let mask = ap_high_bits(bw, bw - ew);
                    let ax = icb_and(x, c_int_ap(dt, mask), "");
                    let zy = icb_zext(y, dt, "");
                    return ic_new_binop(OP_OR, ax, zy);
                }
            }
        }
    }
    if is_inst_op(src, OP_SHUFFLEVECTOR) {
        let s0 = op(src, 0);
        let s1 = op(src, 1);
        let se = ty_count(vals[src].ty);
        let sv = ty_count(vals[s0].ty);
        let sk = ty_kind(vals[src].ty);
        if has_one_use(src) && ty_is_vector(dt) && ty_count(dt) == se && ty_kind(dt) == sk && se == sv && ty_kind(vals[s0].ty) == sk {
            if (is_inst_op(s0, OP_BITCAST) && vals[op(s0, 0)].ty == dt) || (is_inst_op(s1, OP_BITCAST) && vals[op(s1, 0)].ty == dt) {
                let l = icb_bitcast(s0, dt, "");
                let r = icb_bitcast(s1, dt, "");
                var mask: i32[>..<] = [];
                for k in sde_mask_len(src) { mask.push(sde_mask_at(src, k) as i32); }
                return ic_new_shuffle(l, r, mask);
            }
        }
        if ty_is_int(dt) && se % 2 == 0 && has_one_use(src) && shuffle_is_reverse(src) && vals[s1].kind == VK_POISON {
            var iid: i64 = 0;
            if dl_is_legal_integer(ty_scalar_bits(dt)) && ty_scalar_bits(st) == 8 { iid = IID_bswap; }
            else if ty_scalar_bits(st) == 1 { iid = IID_bitreverse; }
            if iid != 0 {
                let f = icx_decl(iid, [dt]);
                let sx = icb_bitcast(s0, dt, "");
                return icx_new_call(f, [sx]);
            }
        }
    }
    if is_phi_inst(src) {
        let r = optimize_bitcast_from_phi(ci, src);
        if r >= 0 { return r; }
    }
    let r1 = canonicalize_bitcast_ext_elt(ci);
    if r1 >= 0 { return r1; }
    let r2 = fold_bitcast_bitwise_logic(ci);
    if r2 >= 0 { return r2; }
    let r3 = fold_bitcast_select(ci);
    if r3 >= 0 { return r3; }
    let v = fold_copy_sign_idioms(ci);
    if v >= 0 { return ic_replace_inst_uses_with(ci, v); }
    return common_cast_transforms(ci);
}
