// VNCoercion: port of llvm/lib/Transforms/Utils/VNCoercion.cpp, whole (canCoerceMustAliasedValueToLoad,
// coerceAvailableValueToLoadType, analyzeLoadFromClobberingWrite/Store/Load/MemInst,
// getStoreValueForLoadHelper, getValueForLoad, getConstantValueForLoad, getMemInstValueForLoad,
// getConstantMemInstValueForLoad), with the IRBuilder<> (ConstantFolder) it uses (vb_*).
import std;
import ir;
import irutil;
import instinfo;
import pm;
import datalayout;
import constfold;
import cfold;
import vt;
import memloc;
import gen_iids;
import autoupgrade;
import apint;

fn vnc_not_ported(what: const u8[:]) { fatal(str("VNCoercion: ", what, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// IRBuilder<> (ConstantFolder) at an instruction: inserts before it (adopting its debug records), new
// instructions get its debug location.

var vb_pos: i32 = -1;
var vb_dl: i32 = -1;
fn vb_set(i: i32) { vb_pos = i; vb_dl = inst_get_md(i, 0); }
fn vb_insert(iv: i32) -> i32 {
    inst_insert_before(iv, vb_pos);
    if vb_dl >= 0 { inst_set_md(iv, 0, vb_dl); }
    return iv;
}
// CreateCast(Op, V, DestTy)
fn vb_cast(o: i64, v: i32, ty: i32) -> i32 {
    if vals[v].ty == ty { return v; }
    if is_constant(v) {
        if is_desirable_cast_op(o) { return ce_cast(o, v, ty); }
        let f = cf_fold_cast_operand(o, v, ty);
        if f >= 0 { return f; }
    }
    return vb_insert(create_inst(o, ty, [v]));
}
fn vb_scalar_bits(t: i32) -> i64 { dl_size_bits(ty_scalar(t)) }
// CreateTruncOrBitCast / CreateZExtOrBitCast
fn vb_trunc_or_bitcast(v: i32, ty: i32) -> i32 {
    if vals[v].ty == ty { return v; }
    let o = if vb_scalar_bits(vals[v].ty) == vb_scalar_bits(ty) { OP_BITCAST } else { OP_TRUNC };
    return vb_cast(o, v, ty);
}
fn vb_zext_or_bitcast(v: i32, ty: i32) -> i32 {
    if vals[v].ty == ty { return v; }
    let o = if vb_scalar_bits(vals[v].ty) == vb_scalar_bits(ty) { OP_BITCAST } else { OP_ZEXT };
    return vb_cast(o, v, ty);
}
// CreateBinOp (FoldBinOp)
fn vb_binop(o: i64, a: i32, b: i32) -> i32 {
    if is_constant(a) && is_constant(b) {
        if is_desirable_binop(o) { return ce_binop(o, a, b, 0); }
        let r = cf_binop(o, a, b);
        if r >= 0 { return r; }
    }
    return vb_insert(create_inst(o, vals[a].ty, [a, b]));
}
// CreateIntrinsic(RetTy, vector_extract, {V, i64 0})
fn vb_vector_extract(v: i32, rty: i32) -> i32 {
    let f = au_get_declaration(IID_vector_extract, [rty, vals[v].ty as i32]);
    let fty = globs[glob_of(f)].vty;
    let iv = create_inst(OP_CALL, rty, [v, c_int(T_I64, 0), f]);
    insts[inst_of(iv)].ty2 = fty;
    return vb_insert(iv);
}

// DataLayout::getIntPtrType(Ty)
fn vnc_int_ptr_type(t: i32) -> i32 {
    let s = ty_scalar(t);
    let it = ty_int(dl_ptr(ptr_as(s)).bits);
    if ty_is_vector(t) { return ty_vector(it, types[t].cnt as i64, types[t].kind == TK_SVEC); }
    return it;
}
fn vnc_non_integral(t: i32) -> bool {
    let s = ty_scalar(t);
    return ty_kind(s) == TK_PTR && dl_is_nonintegral_as(ptr_as(s));
}

// Type::isScalableTy
recursive fn vnc_is_scalable_ty(t: i32) -> bool {
    let k = types[t].kind;
    if k == TK_SVEC { return true; }
    if k == TK_ARRAY { return vnc_is_scalable_ty(types[t].a); }
    if k == TK_STRUCT { for j in types[t].cnt { if vnc_is_scalable_ty(ty_field(t, j)) { return true; } } return false; }
    if k == TK_TARGETEXT { return types[target_layout_type(t)].kind == TK_SVEC; }
    return false;
}

fn vnc_is_fca_or_scalable(t: i32) -> bool {
    let k = types[t].kind;
    return k == TK_STRUCT || k == TK_ARRAY || vnc_is_scalable_ty(t);
}

// canCoerceMustAliasedValueToLoad(StoredVal, LoadTy, F)
fn vnc_can_coerce(sv: i32, lty: i32, fv: i32) -> bool {
    let sty: i32 = vals[sv].ty;
    if sty == lty { return true; }
    var min_store = dl_size_bits(sty);
    var store_scal = ty_size_scalable(sty);
    let load_size = dl_size_bits(lty);
    let load_scal = ty_size_scalable(lty);
    if types[sty].kind == TK_SVEC && types[lty].kind == TK_SVEC && min_store == load_size && store_scal == load_scal { return true; }
    if types[sty].kind == TK_SVEC && types[lty].kind == TK_FVEC {
        if ty_scalar(sty) != ty_scalar(lty) { return false; }
        min_store = min_store * vnc_vscale_min(fv);
        store_scal = false;
    } else if vnc_is_fca_or_scalable(lty) || vnc_is_fca_or_scalable(sty) {
        return false;
    }
    if (min_store + 7) / 8 * 8 != min_store { return false; }
    // TypeSize::isKnownGE(MinStoreSize, LoadSize)
    if load_scal && !store_scal { return false; }
    if min_store < load_size { return false; }
    let sni = vnc_non_integral(sty);
    let lni = vnc_non_integral(lty);
    if sni != lni {
        if is_constant(sv) { return is_null_value(sv); }
        return false;
    } else if sni && lni && ptr_as(ty_scalar(sty)) != ptr_as(ty_scalar(lty)) {
        return false;
    }
    if sni && (vnc_is_scalable_ty(sty) || min_store != load_size || store_scal != load_scal) { return false; }
    if types[sty].kind == TK_TARGETEXT || types[lty].kind == TK_TARGETEXT { return false; }
    return true;
}

fn vnc_vscale_min(fv: i32) -> i64 {
    let a = aset_find(alist_fn(globs[glob_of(fv)].attrs), AK_VScaleRange);
    if a < 0 { return 1; }
    return (attrs[a].i1 >> 32) as i64;
}

// coerceAvailableValueToLoadType(StoredVal, LoadedTy, Helper = vb_*, F)
fn vnc_coerce(sv0: i32, lty: i32, fv: i32) -> i32 {
    var sv = sv0;
    if is_constant(sv) { sv = cf_fold_constant(sv); }
    var sty: i32 = vals[sv].ty;
    if types[sty].kind == TK_SVEC && types[lty].kind == TK_FVEC { return vb_vector_extract(sv, lty); }
    let ssize = dl_size_bits(sty);
    let lsize = dl_size_bits(lty);
    if ssize == lsize && ty_size_scalable(sty) == ty_size_scalable(lty) {
        if is_ptr_or_ptr_vec(sty) && is_ptr_or_ptr_vec(lty) {
            sv = vb_cast(OP_BITCAST, sv, lty);
        } else {
            if is_ptr_or_ptr_vec(sty) {
                sty = vnc_int_ptr_type(sty);
                sv = vb_cast(OP_PTRTOINT, sv, sty);
            }
            var tcast = lty;
            if is_ptr_or_ptr_vec(tcast) { tcast = vnc_int_ptr_type(tcast); }
            if sty != tcast { sv = vb_cast(OP_BITCAST, sv, tcast); }
            if is_ptr_or_ptr_vec(lty) { sv = vb_cast(OP_INTTOPTR, sv, lty); }
        }
        if vals[sv].kind == VK_CEXPR { sv = cf_fold_constant(sv); }
        return sv;
    }
    if ty_size_scalable(sty) { vnc_not_ported("coercing a scalable value of a different size"); }
    if is_ptr_or_ptr_vec(sty) {
        sty = vnc_int_ptr_type(sty);
        sv = vb_cast(OP_PTRTOINT, sv, sty);
    }
    if !ty_is_int(sty) {
        sty = ty_int(ssize);
        sv = vb_cast(OP_BITCAST, sv, sty);
    }
    if dl_big_endian {
        let sh = dl_store_size(sty) * 8 - dl_store_size(lty) * 8;
        sv = vb_binop(OP_LSHR, sv, c_int(vals[sv].ty, sh));
    }
    let nit = ty_int(lsize);
    sv = vb_trunc_or_bitcast(sv, nit);
    if lty != nit {
        if is_ptr_or_ptr_vec(lty) { sv = vb_cast(OP_INTTOPTR, sv, lty); }
        else { sv = vb_cast(OP_BITCAST, sv, lty); }
    }
    if is_constant(sv) { sv = cf_fold_constant(sv); }
    return sv;
}

// GetPointerBaseWithConstantOffset(Ptr, Offset, DL)
fn vnc_base_with_offset(p: i32) -> i32, i64 {
    let b = strip_and_accumulate_offsets(p, true, false, false);
    return b, vt_off;
}

// analyzeLoadFromClobberingWrite
fn vnc_analyze_clobbering_write(lty: i32, lptr: i32, wptr: i32, wbits: u64) -> i64 {
    if vnc_is_fca_or_scalable(lty) { return -1; }
    let sb, soff = vnc_base_with_offset(wptr);
    let lb, loff = vnc_base_with_offset(lptr);
    if sb != lb { return -1; }
    var lsize = dl_size_bits(lty) as u64;
    if ((wbits & 7) | (lsize & 7)) != 0 { return -1; }
    let ssize = wbits / 8;
    lsize = lsize / 8;
    if soff > loff || soff + (ssize as i64) < loff + (lsize as i64) { return -1; }
    // the int result of LLVM (LoadOffset - StoreOffset), truncated to 32 bits
    return ((loff - soff) as! i32) as i64;
}

// analyzeLoadFromClobberingStore(LoadTy, LoadPtr, DepSI)
fn vnc_analyze_from_store(lty: i32, lptr: i32, si: i32) -> i64 {
    let sv = op(si, 0);
    if vnc_is_fca_or_scalable(vals[sv].ty) { return -1; }
    if !vnc_can_coerce(sv, lty, inst_func(si)) { return -1; }
    return vnc_analyze_clobbering_write(lty, lptr, op(si, 1), dl_size_bits(vals[sv].ty) as u64);
}

// analyzeLoadFromClobberingLoad(LoadTy, LoadPtr, DepLI)
fn vnc_analyze_from_load(lty: i32, lptr: i32, dli: i32) -> i64 {
    if vnc_is_fca_or_scalable(vals[dli].ty) { return -1; }
    if !vnc_can_coerce(dli, lty, inst_func(dli)) { return -1; }
    return vnc_analyze_clobbering_write(lty, lptr, op(dli, 0), dl_size_bits(vals[dli].ty) as u64);
}

fn vnc_is_memset(mi: i32) -> bool { let id = call_iid(mi); return id == IID_memset || id == IID_memset_inline; }

// analyzeLoadFromClobberingMemInst(LoadTy, LoadPtr, MI)
fn vnc_analyze_from_mem_inst(lty: i32, lptr: i32, mi: i32) -> i64 {
    let len = cb_arg(mi, 2);
    if !is_cint(len) { return -1; }
    let ap = ci_ap(len);
    if ap.w > 64 { vnc_not_ported("memory intrinsic lengths wider than 64 bits"); }
    let bits = ap.lo * 8;
    if vnc_is_memset(mi) {
        if vnc_non_integral(lty) {
            let v = cb_arg(mi, 1);
            if !is_cint(v) || !cint_is_zero(v) { return -1; }
        }
        return vnc_analyze_clobbering_write(lty, lptr, cb_arg(mi, 0), bits);
    }
    let src = cb_arg(mi, 1);
    if !is_constant(src) { return -1; }
    let gv = get_underlying_object(src, 10);
    if !is_gvar(gv) || globs[glob_of(gv)].is_const == 0 || !gv_has_definitive_initializer(gv) { return -1; }
    let off = vnc_analyze_clobbering_write(lty, lptr, cb_arg(mi, 0), bits);
    if off == -1 { return off; }
    if cf_fold_load_from_const_ptr(src, lty, off, true) >= 0 { return off; }
    return -1;
}

// getStoreValueForLoadHelper
fn vnc_store_value_helper(sv0: i32, off: i64, lty: i32) -> i32 {
    var sv = sv0;
    let st: i32 = vals[sv].ty;
    if ty_kind(st) == TK_PTR && ty_kind(lty) == TK_PTR && ptr_as(st) == ptr_as(lty) { return sv; }
    if types[lty].kind == TK_SVEC { return sv; }
    if types[st].kind == TK_SVEC && types[lty].kind == TK_FVEC { return sv; }
    let ssize = (dl_size_bits(st) + 7) / 8;
    let lsize = (dl_size_bits(lty) + 7) / 8;
    if is_ptr_or_ptr_vec(vals[sv].ty) { sv = vb_cast(OP_PTRTOINT, sv, vnc_int_ptr_type(vals[sv].ty)); }
    if !ty_is_int(vals[sv].ty) { sv = vb_cast(OP_BITCAST, sv, ty_int(ssize * 8)); }
    var sh: i64 = 0;
    if !dl_big_endian { sh = off * 8; } else { sh = (ssize - lsize - off) * 8; }
    sh = ((sh as! u32) as i64);
    if sh != 0 { sv = vb_binop(OP_LSHR, sv, c_int(vals[sv].ty, sh)); }
    if lsize != ssize { sv = vb_trunc_or_bitcast(sv, ty_int(lsize * 8)); }
    return sv;
}

// getValueForLoad(SrcVal, Offset, LoadTy, InsertPt, F)
fn vnc_get_value_for_load(src: i32, off: i64, lty: i32, insert_pt: i32, fv: i32) -> i32 {
    vb_set(insert_pt);
    let sv = vnc_store_value_helper(src, off, lty);
    return vnc_coerce(sv, lty, fv);
}

// getConstantValueForLoad(SrcVal, Offset, LoadTy, DL)
fn vnc_get_constant_value_for_load(src: i32, off: i64, lty: i32) -> i32 { cf_fold_load_from_const(src, lty, off) }

// getMemInstValueForLoad(SrcInst, Offset, LoadTy, InsertPt, DL)
fn vnc_get_mem_inst_value_for_load(mi: i32, off: i64, lty: i32, insert_pt: i32) -> i32 {
    let lsize = dl_size_bits(lty) / 8;
    vb_set(insert_pt);
    if vnc_is_memset(mi) {
        var val = cb_arg(mi, 1);
        if lsize != 1 { val = vb_zext_or_bitcast(val, ty_int(lsize * 8)); }
        let one = val;
        var nset: i64 = 1;
        while nset != lsize {
            if nset * 2 <= lsize {
                let shv = vb_binop(OP_SHL, val, c_int(vals[val].ty, nset * 8));
                val = vb_binop(OP_OR, val, shv);
                nset = nset << 1;
                continue;
            }
            let shv = vb_binop(OP_SHL, val, c_int(vals[val].ty, 8));
            val = vb_binop(OP_OR, one, shv);
            nset++;
        }
        return vnc_coerce(val, lty, inst_func(insert_pt));
    }
    let src = cb_arg(mi, 1);
    return cf_fold_load_from_const_ptr(src, lty, off, true);
}

// getConstantMemInstValueForLoad(SrcInst, Offset, LoadTy, DL)
fn vnc_get_constant_mem_inst_value_for_load(mi: i32, off: i64, lty: i32) -> i32 {
    let lsize = dl_size_bits(lty) / 8;
    if vnc_is_memset(mi) {
        let v = cb_arg(mi, 1);
        if !is_cint(v) { return -1; }
        let sp = ap_splat(lsize * 8, ci_ap(v));
        let c = ap_to_cint(ty_int(lsize * 8), sp);
        return cf_fold_load_from_const(c, lty, 0);
    }
    return cf_fold_load_from_const_ptr(cb_arg(mi, 1), lty, off, true);
}
