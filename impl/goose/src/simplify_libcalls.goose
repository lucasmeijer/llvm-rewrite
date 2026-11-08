// LibCallSimplifier: port of llvm/lib/Transforms/Utils/SimplifyLibCalls.cpp (LibCallSimplifier::optimizeCall and
// its dispatchers optimizeStringMemoryLibCall / optimizeFloatingPointLibCall in LLVM's order, the helpers
// annotateNonNullNoUndefBasedOnAccess / annotateDereferenceableBytes / annotateNonNullAndDereferenceable /
// copyFlags / mergeAttributesAndFlags), plus ValueTracking's getConstantDataArrayInfo, getConstantStringInfo,
// GetStringLength and isOnlyUsedInZeroEqualityComparison, and ConstantFolding's ReadByteArrayFromGlobal.
//
// Ported optimizers: strlen/strnlen/wcslen (optimizeStringLength), strcmp, memcmp/bcmp, memcpy/memmove/memset
// (calls and intrinsics), printf, puts, exit, abs, ffs, fls, isdigit, isascii, toascii, the symmetric
// trig calls and the libm calls that become intrinsics (replaceUnaryCall/replaceBinaryCall). Every other
// optimizer fails loudly (lcs_np) when its LibFunc is called, so nothing is silently skipped.
namespace ic;
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import gen_tli;
import datalayout;
import pm;
import vt;
import knownbits;
import constfold;
import cfold;
import apint;
import tli;
import build_libcalls;
import ic;
import ic_builder;
import ic_common;
import ic_calls;
import ic_loadstorealloca;
import ic_casts;
import speculate;

fn lcs_np(what: const u8[:]) { fatal(str("LibCallSimplifier: ", what, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// ValueTracking: constant strings

// ConstantDataArraySlice: (ok, array (-1 = nullptr: zeroinitializer), offset, length)
var lcs_slice_arr: i32 = -1;
var lcs_slice_off: u64 = 0;
var lcs_slice_len: u64 = 0;

// ReadByteArrayFromGlobal(GV, Offset): -1 = nullptr
fn read_byte_array_from_global(gv: i32, off: u64) -> i32 {
    let g = glob_of(gv);
    if globs[g].is_const == 0 || !glob_has_definitive_initializer(gv) { return -1; }
    let init = op(gv, 0);
    let isz = dl_alloc_size(vals[init].ty) as u64;
    if isz < off { return -1; }
    let nb = isz - off;
    if nb > 65535 { return -1; }
    let mark = cf_raw.len;
    for i in nb { cf_raw.push(0); }
    let ok = cf_read_data(init, off as i64, mark, nb as i64, false);
    var bytes: i32[>..<] = [];
    if ok { for i in nb { bytes.push(c_int(T_I8, cf_raw[mark + i as i64] as i64)); } }
    cf_raw.resize(mark);
    if !ok { return -1; }
    return c_aggregate(ty_array(T_I8, nb as i64), bytes);
}
// GlobalVariable::hasDefinitiveInitializer
fn glob_has_definitive_initializer(gv: i32) -> bool {
    let g = glob_of(gv);
    if nops(gv) == 0 || op(gv, 0) < 0 { return false; }
    if globs[g].ext_init != 0 { return false; }
    let lk = globs[g].linkage as i64;
    // isInterposable(): weak / linkonce / common / extern_weak; available_externally is fine
    if globs[g].dso_local == 0 && module_flag_int(globs[g].module, "SemanticInterposition") > 0 { return false; }
    return !(lk == LK_WEAK_ANY || lk == LK_LINKONCE_ANY || lk == LK_COMMON ||
             lk == LK_EXTERN_WEAK);
}

// getConstantDataArrayInfo(V, Slice, ElementSize, Offset)
fn get_constant_data_array_info(v: i32, esize: i64, offset0: u64) -> bool {
    let esb = (esize / 8) as u64;
    let gv = get_underlying_object(v, 6);
    if gv < 0 || vals[gv].kind != VK_GVAR || globs[glob_of(gv)].is_const == 0 || !glob_has_definitive_initializer(gv) { return false; }
    let base = strip_and_accumulate_offsets(v, true, false, false);
    if base != gv { return false; }
    let iw = dl_ptr(ptr_as(ty_scalar(vals[v].ty))).idx;
    let offap = ap_i64(vt_off, iw);
    let start = ap_limited(offap, 0xFFFFFFFFFFFFFFFF);
    if start == 0xFFFFFFFFFFFFFFFF { return false; }
    if start % esb != 0 { return false; }
    var offset = offset0 + start / esb;
    let init = op(gv, 0);
    if is_null_value(init) {
        let sz = dl_store_size(globs[glob_of(gv)].vty) as u64;
        let len = sz / esb;
        lcs_slice_arr = -1;
        lcs_slice_off = 0;
        lcs_slice_len = if len < offset { 0 } else { len - offset };
        return true;
    }
    var arr: i32 = -1;
    var aty: i32 = -1;
    if vals[init].kind == VK_CDARRAY {
        let et = ty_elem(vals[init].ty);
        if ty_is_int(et) && ty_bits(et) == esize { arr = init; aty = vals[init].ty; }
    }
    if arr < 0 {
        if esize != 8 { return false; }
        let ni = read_byte_array_from_global(gv, offset);
        if ni < 0 { return false; }
        offset = 0;
        arr = if vals[ni].kind == VK_CDARRAY { ni } else { -1 };
        aty = vals[ni].ty;
    }
    let ne = ty_count(aty) as u64;
    if offset > ne { return false; }
    lcs_slice_arr = arr;
    lcs_slice_off = offset;
    lcs_slice_len = ne - offset;
    return true;
}
fn slice_elem(k: u64) -> u64 { ap_zext64(ci_ap(op(lcs_slice_arr, (lcs_slice_off + k) as i64))) }

// getConstantStringInfo(V, Str, TrimAtNul): the bytes go to lcs_str
var lcs_str: u8[>..<];
fn get_constant_string_info(v: i32, trim: bool) -> bool {
    lcs_str.clear();
    if !get_constant_data_array_info(v, 8, 0) { return false; }
    if lcs_slice_arr < 0 {
        if trim { return true; }
        if lcs_slice_len == 1 { lcs_str.push(0); return true; }
        return false;
    }
    for k in lcs_slice_len {
        let c = slice_elem(k) as u8;
        if trim && c == 0 { break; }
        lcs_str.push(c);
    }
    return true;
}

// GetStringLengthH(V, PHIs, CharSize)
recursive fn get_string_length_h(v0: i32, phis: i32[>..<]&, cs: i64) -> u64 {
    let v = strip_ptr_casts(v0);
    if is_phi_inst(v) {
        for p in phis { if p == v { return 0xFFFFFFFFFFFFFFFF; } }
        phis.push(v);
        var lsf: u64 = 0xFFFFFFFFFFFFFFFF;
        for k in nops(v) {
            let len = get_string_length_h(op(v, k), phis, cs);
            if len == 0 { return 0; }
            if len == 0xFFFFFFFFFFFFFFFF { continue; }
            if len != lsf && lsf != 0xFFFFFFFFFFFFFFFF { return 0; }
            lsf = len;
        }
        return lsf;
    }
    if is_select_inst(v) {
        let l1 = get_string_length_h(op(v, 1), phis, cs);
        if l1 == 0 { return 0; }
        let l2 = get_string_length_h(op(v, 2), phis, cs);
        if l2 == 0 { return 0; }
        if l1 == 0xFFFFFFFFFFFFFFFF { return l2; }
        if l2 == 0xFFFFFFFFFFFFFFFF { return l1; }
        if l1 != l2 { return 0; }
        return l1;
    }
    if !get_constant_data_array_info(v, cs, 0) { return 0; }
    if lcs_slice_arr < 0 { return 1; }
    var ni: u64 = 0;
    while ni < lcs_slice_len {
        if slice_elem(ni) == 0 { break; }
        ni++;
    }
    return ni + 1;
}
// GetStringLength(V, CharSize = 8)
fn get_string_length(v: i32, cs: i64) -> u64 {
    if ty_kind(vals[v].ty) != TK_PTR { return 0; }
    var phis: i32[>..<] = [];
    let len = get_string_length_h(v, phis, cs);
    return if len == 0xFFFFFFFFFFFFFFFF { 1 } else { len };
}

// isOnlyUsedInZeroEqualityComparison(I)
fn is_only_used_in_zero_equality_comparison(i: i32) -> bool {
    if use_empty(i) { return false; }
    var u = vals[i].first_use;
    while u >= 0 {
        let us = uses[u].user;
        u = uses[u].next;
        if !(is_inst_op(us, OP_ICMP) && m_zero(op(us, 1)) && icmp_is_equality(inst_pred(us))) { return false; }
    }
    return true;
}
// isOnlyUsedInComparisonWithZero (SimplifyLibCalls.cpp)
fn is_only_used_in_comparison_with_zero(v: i32) -> bool {
    var u = vals[v].first_use;
    while u >= 0 {
        let us = uses[u].user;
        u = uses[u].next;
        if !(is_inst_op(us, OP_ICMP) && is_constant(op(us, 1)) && is_null_value(op(us, 1))) { return false; }
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// Call-site attribute helpers

fn cs_aset(ci: i32, k: i64) -> i32 { alist_param(insts[inst_of(ci)].attrs, k) }
fn cs_set_param(ci: i32, k: i64, s: i32) { insts[inst_of(ci)].attrs = alist_set_param(insts[inst_of(ci)].attrs, k, s); }
fn cs_add_param_attr(ci: i32, k: i64, a: i32) { cs_set_param(ci, k, aset_with(cs_aset(ci, k), a)); }
fn cs_remove_param_attr(ci: i32, k: i64, kind: i64) { cs_set_param(ci, k, aset_without(cs_aset(ci, k), kind)); }
// getParamDereferenceableBytes / getParamDereferenceableOrNullBytes: the call site's only
fn cs_deref_bytes(ci: i32, k: i64) -> u64 { aset_int(cs_aset(ci, k), AK_Dereferenceable) }
fn cs_deref_or_null_bytes(ci: i32, k: i64) -> u64 { aset_int(cs_aset(ci, k), AK_DereferenceableOrNull) }

// annotateDereferenceableBytes(CI, ArgNos, DereferenceableBytes)
fn annotate_dereferenceable_bytes(ci: i32, k: i64, bytes: u64) {
    let fv = inst_func(ci);
    var db = bytes;
    let as_ = ptr_as(vals[cb_arg(ci, k)].ty);
    if !null_pointer_is_defined(fv, as_) || call_param_has_attr(ci, k, AK_NonNull) { db = max(cs_deref_or_null_bytes(ci, k), bytes); }
    if cs_deref_bytes(ci, k) < db {
        cs_remove_param_attr(ci, k, AK_Dereferenceable);
        if !null_pointer_is_defined(fv, as_) || call_param_has_attr(ci, k, AK_NonNull) { cs_remove_param_attr(ci, k, AK_DereferenceableOrNull); }
        cs_add_param_attr(ci, k, attr_int(AK_Dereferenceable, db));
    }
}
// annotateNonNullNoUndefBasedOnAccess(CI, ArgNos)
fn annotate_nonnull_noundef(ci: i32, k: i64) {
    if !call_param_has_attr(ci, k, AK_NoUndef) { cs_add_param_attr(ci, k, attr_enum(AK_NoUndef)); }
    if !call_param_has_attr(ci, k, AK_NonNull) {
        if null_pointer_is_defined(inst_func(ci), ptr_as(vals[cb_arg(ci, k)].ty)) { return; }
        cs_add_param_attr(ci, k, attr_enum(AK_NonNull));
    }
    annotate_dereferenceable_bytes(ci, k, 1);
}
// annotateNonNullAndDereferenceable(CI, ArgNos, Size, DL)
fn annotate_nonnull_and_dereferenceable(ci: i32, a0: i64, a1: i64, size: i32) {
    if vals[size].kind == VK_CINT && !ty_is_vector(vals[size].ty) {
        annotate_nonnull_noundef(ci, a0);
        if a1 >= 0 { annotate_nonnull_noundef(ci, a1); }
        let len = ap_zext64(ci_ap(size));
        annotate_dereferenceable_bytes(ci, a0, len);
        if a1 >= 0 { annotate_dereferenceable_bytes(ci, a1, len); }
        return;
    }
    let sv = kb_cxt;
    kb_cxt = -1;
    let nz = is_known_non_zero(size, 0);
    kb_cxt = sv;
    if nz {
        annotate_nonnull_noundef(ci, a0);
        if a1 >= 0 { annotate_nonnull_noundef(ci, a1); }
        if is_select_inst(size) {
            let x = icx_m_cint64(op(size, 1));
            let y = icx_m_cint64(op(size, 2));
            if x >= 0 && y >= 0 && vals[op(size, 1)].kind == VK_CINT && vals[op(size, 2)].kind == VK_CINT {
                let dm = min(ap_zext64(ci_ap(x)), ap_zext64(ci_ap(y)));
                annotate_dereferenceable_bytes(ci, a0, dm);
                if a1 >= 0 { annotate_dereferenceable_bytes(ci, a1, dm); }
            }
        }
    }
}

// copyFlags(Old, New): the tail call kind
fn copy_flags(old: i32, nv: i32) -> i32 {
    if nv >= 0 && is_inst_op(nv, OP_CALL) { insts[inst_of(nv)].pred = insts[inst_of(old)].pred; }
    return nv;
}
// mergeAttributesAndFlags(NewCI, Old)
fn merge_attributes_and_flags(nc: i32, old: i32) -> i32 {
    // AttributeList::get(C, {New, Old}): per index, the union (New's attributes first, an attribute kind once)
    let ln = insts[inst_of(nc)].attrs;
    let lo = insts[inst_of(old)].attrs;
    let n = max(if ln == 0 { 0 } else { alists[ln].n as i64 }, if lo == 0 { 0 } else { alists[lo].n as i64 });
    var sets: i32[>..<] = [];
    for j in n {
        let a = if ln != 0 && j < alists[ln].n as i64 { alist_runs[alists[ln].at + j] } else { 0 };
        let b = if lo != 0 && j < alists[lo].n as i64 { alist_runs[alists[lo].at + j] } else { 0 };
        var s = a;
        for k in aset_n(b) {
            let x = aset_attr(b, k);
            let dup = if attrs[x].kind == 0 { aset_find_str(s, sbytes(attrs[x].skey)) >= 0 } else { aset_has(s, attrs[x].kind as i64) };
            if !dup { s = aset_with(s, x); }
        }
        sets.push(s);
    }
    insts[inst_of(nc)].attrs = alist_get(sets);
    // removeRetAttrs / removeParamAttrs of type-incompatible attributes
    let l2 = insts[inst_of(nc)].attrs;
    var s2: i32[>..<] = [];
    let n2 = if l2 == 0 { 0 } else { alists[l2].n as i64 };
    for j in n2 {
        var s = alist_runs[alists[l2].at + j];
        if j == 1 { s = aset_remove_incompatible(vals[nc].ty, s, 3); }
        if j >= 2 && j - 2 < cb_nargs(nc) { s = aset_remove_incompatible(vals[cb_arg(nc, j - 2)].ty, s, 3); }
        s2.push(s);
    }
    insts[inst_of(nc)].attrs = alist_get(s2);
    return copy_flags(old, nc);
}

// ---------------------------------------------------------------------------------------------
// The builder (InstCombine's IRBuilder with the simplified call's operand bundles as default bundles)

var lcs_ci: i32 = -1;   // the call being simplified (its bundles are the builder's default operand bundles)

// IRBuilder::CreateCall(Callee, Args, Name) with the default operand bundles
fn lcs_create_call(f: i32, argsv: const i32[:], name: const u8[:]) -> i32 {
    let fty = globs[glob_of(f)].vty;
    var opsv: i32[>..<] = [];
    for a in argsv { opsv.push(a); }
    var pairs: i32[>..<] = [];
    if lcs_ci >= 0 {
        for k in cb_nbundles(lcs_ci) {
            let b = cb_bundle_begin(lcs_ci, k);
            let n = cb_bundle_count(lcs_ci, k);
            for j in n { opsv.push(op(lcs_ci, b + j)); }
            pairs.push(cb_bundle_tag(lcs_ci, k));
            pairs.push(n as i32);
        }
    }
    opsv.push(f);
    let c = create_inst(OP_CALL, ty_fn_ret(fty), opsv);
    insts[inst_of(c)].ty2 = fty;
    cb_set_bundles(c, argsv.len, pairs, 0);
    if is_fp_math_operator(c) { insts[inst_of(c)].fmf = icb_fmf; }
    var nm: u8[>..] = [];
    if ty_fn_ret(fty) != T_VOID { nm.append(name); }
    return icb_insert(c, nm);
}

// emitLibCall(TheLibFunc, ReturnType, ParamTypes, Operands, B, TLI, IsVaArgs)
fn emit_lib_call(lf: i64, rt: i32, pts: const i32[:], argsv: const i32[:], va: bool) -> i32 {
    if !blc_is_emittable(lf) { return -1; }
    let fty = ty_func_of(rt, pts, va);
    let f = blc_get_or_insert(lf, fty, 0);
    var nm: u8[>..] = [];
    nm.append(TLI_NAMES[lf]);
    blc_infer_by_name(nm);
    let c = lcs_create_call(f, argsv, nm);
    insts[inst_of(c)].cc = globs[glob_of(f)].cc;
    return c;
}
fn tli_int_ty() -> i32 { ty_int(32) }
fn tli_sizet_ty() -> i32 { ty_int(tli_sizet_bits()) }
fn emit_strlen(p: i32) -> i32 { emit_lib_call(LF_strlen, tli_sizet_ty(), [ty_ptr(0)], [p], false) }
fn emit_memcmp(a: i32, b: i32, len: i32) -> i32 {
    let pt = ty_ptr(0);
    return emit_lib_call(LF_memcmp, tli_int_ty(), [pt, pt, tli_sizet_ty()], [a, b, len], false);
}
fn emit_bcmp(a: i32, b: i32, len: i32) -> i32 {
    let pt = ty_ptr(0);
    return emit_lib_call(LF_bcmp, tli_int_ty(), [pt, pt, tli_sizet_ty()], [a, b, len], false);
}
// emitPutChar / emitPutS (getOrInsertLibFunc + inferNonMandatoryLibFuncAttrs + CreateCall)
fn emit_putchar(ch: i32) -> i32 {
    if !blc_is_emittable(LF_putchar) { return -1; }
    let it = tli_int_ty();
    return emit_lib_call(LF_putchar, it, [it], [ch], false);
}
fn emit_puts(s: i32) -> i32 {
    if !blc_is_emittable(LF_puts) { return -1; }
    return emit_lib_call(LF_puts, tli_int_ty(), [ty_ptr(0)], [s], false);
}
// TLI->getAsSizeT(V, M)
fn tli_as_size_t(v: u64) -> i32 { c_int_ty(tli_sizet_ty(), v) }

// IRBuilder::CreateGlobalString(Str, Name): private unnamed_addr constant [N+1 x i8], align 1
fn lcs_create_global_string(bytes: const u8[:], name: const u8[:]) -> i32 {
    var els: i32[>..<] = [];
    for b in bytes { els.push(c_int(T_I8, b as i64)); }
    els.push(c_int(T_I8, 0));
    let init = c_aggregate(ty_array(T_I8, els.len), els);
    return module_new_private_string(init, name);
}

// IRBuilder::CreateMemCpy / CreateMemMove (align 1 operands) and CreateMemSet
fn lcs_memcpy_like(id: i64, d: i32, s: i32, size: i32) -> i32 { icb_mem_transfer(id, d, 1, s, 1, size, false) }

// ---------------------------------------------------------------------------------------------
// String and memory optimizers

// optimizeStringLength(CI, B, CharSize, Bound)
fn optimize_string_length(ci: i32, cs: i64, bound: i32) -> i32 {
    let src = cb_arg(ci, 0);
    let cty = ty_int(cs);
    if is_only_used_in_zero_equality_comparison(ci) {
        var ok = bound < 0;
        if !ok { kb_cxt = -1; ok = is_known_non_zero(bound, 0); }
        if ok { return icb_zext(icb_load(cty, src, "char0"), vals[ci].ty, ""); }
    }
    if bound >= 0 && vals[bound].kind == VK_CINT {
        if ap_is_zero(ci_ap(bound)) { return c_int_ty(vals[ci].ty, 0); }
        if ap_is_one(ci_ap(bound)) {
            let cv = icb_load(cty, src, "strnlen.char0");
            let cmp = icb_icmp(P_NE, cv, c_int_ty(cty, 0), "strnlen.char0cmp");
            return icb_zext(cmp, vals[ci].ty, "");
        }
    }
    let len = get_string_length(src, cs);
    if len != 0 {
        let lc = c_int_ty(vals[ci].ty, len - 1);
        if bound >= 0 { return icx_binary_intrinsic(IID_umin, lc, bound, ""); }
        return lc;
    }
    if bound >= 0 { return -1; }
    if is_gep_operator(src) {
        let bw = dl_ptr(ptr_as(vals[src].ty)).idx;
        let var_, scale, ok = gep_single_variable_offset(src);
        if !ok || scale != cs / 8 { return -1; }
        if get_constant_data_array_info(op(src, 0), cs, 0) {
            var nti: u64 = 0;
            if lcs_slice_arr >= 0 {
                nti = 0xFFFFFFFFFFFFFFFF;
                for i in lcs_slice_len { if slice_elem(i) == 0 { nti = i; break; } }
                if nti == 0xFFFFFFFFFFFFFFFF { return -1; }
            }
            kb_cxt = ci;
            let known = kb_compute_all(var_, 0);
            if (kb_is_nonneg(known) && ap_ule_u64(kb_max(known), nti)) ||
               (vals[op(src, 0)].kind == VK_GVAR && nti == lcs_slice_len - 1) {
                let off = icb_sext_or_trunc(var_, vals[ci].ty, "");
                return icb_sub(c_int_ty(vals[ci].ty, nti), off, "");
            }
        }
        if bw > 64 { lcs_np("optimizeStringLength with index widths over 64 bits"); }
    }
    if is_select_inst(src) {
        let lt = get_string_length(op(src, 1), cs);
        let lf = get_string_length(op(src, 2), cs);
        if lt != 0 && lf != 0 {
            return icb_select(op(src, 0), c_int_ty(vals[ci].ty, lt - 1), c_int_ty(vals[ci].ty, lf - 1), "", -1);
        }
    }
    return -1;
}
// GEPOperator::collectOffset with exactly one variable index and no constant offset: (var, scale, ok)
fn gep_single_variable_offset(g: i32) -> i32, i64, bool {
    var ty = gep_src_ty(g);
    var var_: i32 = -1;
    var scale: i64 = 0;
    var coff: i64 = 0;
    for k in 1..nops(g) {
        let idx = op(g, k);
        if k > 1 && ty_is_struct(ty) {
            let fi = ap_zext64(ci_ap(idx)) as i64;
            coff += dl_struct_offset(ty, fi);
            ty = ty_field(ty, fi);
            continue;
        }
        var stride: i64 = 0;
        if k > 1 { let et = ty_index(ty, 0); stride = dl_gep_stride(ty, et); ty = et; } else { stride = dl_alloc_size(ty); }
        if vals[idx].kind == VK_CINT { coff += stride * ap_sext64(ci_ap(idx)); continue; }
        if is_constant(idx) && is_null_value(idx) { continue; }
        if var_ >= 0 && var_ != idx { return -1, 0, false; }
        var_ = idx;
        scale += stride;
    }
    if var_ < 0 || coff != 0 || scale == 0 { return -1, 0, false; }
    return var_, scale, true;
}

fn optimize_strlen(ci: i32) -> i32 {
    let v = optimize_string_length(ci, 8, -1);
    if v >= 0 { return v; }
    annotate_nonnull_noundef(ci, 0);
    return -1;
}
fn optimize_strnlen(ci: i32) -> i32 {
    let bound = cb_arg(ci, 1);
    let v = optimize_string_length(ci, 8, bound);
    if v >= 0 { return v; }
    kb_cxt = -1;
    if is_known_non_zero(bound, 0) { annotate_nonnull_noundef(ci, 0); }
    return -1;
}
fn optimize_wcslen(ci: i32) -> i32 {
    var ws = module_flag_int(globs[glob_of(inst_func(ci))].module, "wchar_size");
    if ws < 0 { ws = 4; }
    let wcs = ws * 8;
    if wcs == 0 { return -1; }
    return optimize_string_length(ci, wcs, -1);
}

// optimizeStrCmp(CI, B)
fn optimize_strcmp(ci: i32) -> i32 {
    let s1 = cb_arg(ci, 0);
    let s2 = cb_arg(ci, 1);
    let rty = vals[ci].ty;
    if s1 == s2 { return c_int_ty(rty, 0); }
    let h1 = get_constant_string_info(s1, true);
    var str1: u8[>..<] = [];
    for c in lcs_str { str1.push(c); }
    let h2 = get_constant_string_info(s2, true);
    var str2: u8[>..<] = [];
    for c in lcs_str { str2.push(c); }
    if h1 && h2 {
        var r: i64 = 0;
        let mn = min(str1.len, str2.len);
        var i: i64 = 0;
        while i < mn && str1[i] == str2[i] { i++; }
        if i < mn { r = if str1[i] < str2[i] { -1 } else { 1 }; }
        else if str1.len != str2.len { r = if str1.len < str2.len { -1 } else { 1 }; }
        return c_int_ty_s(rty, r);
    }
    if h1 && str1.len == 0 {
        return icb_neg(icb_zext(icb_load(T_I8, s2, "strcmpload"), rty, ""), "", false);
    }
    if h2 && str2.len == 0 { return icb_zext(icb_load(T_I8, s1, "strcmpload"), rty, ""); }
    let l1 = get_string_length(s1, 8);
    if l1 != 0 { annotate_dereferenceable_bytes(ci, 0, l1); }
    let l2 = get_string_length(s2, 8);
    if l2 != 0 { annotate_dereferenceable_bytes(ci, 1, l2); }
    if l1 != 0 && l2 != 0 { return copy_flags(ci, emit_memcmp(s1, s2, tli_as_size_t(min(l1, l2)))); }
    if !h1 && h2 {
        if can_transform_to_memcmp(ci, s1, l2) { return copy_flags(ci, emit_memcmp(s1, s2, tli_as_size_t(l2))); }
    } else if h1 && !h2 {
        if can_transform_to_memcmp(ci, s2, l1) { return copy_flags(ci, emit_memcmp(s1, s2, tli_as_size_t(l1))); }
    }
    annotate_nonnull_noundef(ci, 0);
    annotate_nonnull_noundef(ci, 1);
    return -1;
}
// canTransformToMemCmp(CI, Str, Len, SQ)
fn can_transform_to_memcmp(ci: i32, s: i32, len: u64) -> bool {
    if !is_only_used_in_comparison_with_zero(ci) { return false; }
    if !ld_is_dereferenceable_pointer_size(s, len, ci) { return false; }
    if func_has_fn_attr(inst_func(ci), AK_SanitizeMemory) { return false; }
    return true;
}

// optimizeMemCmpVarSize(CI, LHS, RHS, Size, StrNCmp, B, DL)
fn optimize_memcmp_var_size(ci: i32, l: i32, r: i32, size: i32, strncmp: bool) -> i32 {
    if l == r { return c_null(vals[ci].ty); }
    if !get_constant_string_info(l, false) { return -1; }
    var ls: u8[>..<] = [];
    for c in lcs_str { ls.push(c); }
    if !get_constant_string_info(r, false) { return -1; }
    var rs: u8[>..<] = [];
    for c in lcs_str { rs.push(c); }
    var pos: i64 = 0;
    let zero = c_int_ty(vals[ci].ty, 0);
    let mn = min(ls.len, rs.len);
    loop {
        if pos == mn || (strncmp && ls[pos] == 0 && rs[pos] == 0) { return zero; }
        if ls[pos] != rs[pos] { break; }
        pos++;
    }
    let ires: i64 = if ls[pos] < rs[pos] { -1 } else { 1 };
    let maxsz = c_int_ty(vals[size].ty, pos as u64);
    let cmp = icb_icmp(P_ULE, size, maxsz, "");
    return icb_select(cmp, zero, c_int_ty_s(vals[ci].ty, ires), "", -1);
}
// optimizeMemCmpConstantSize(CI, LHS, RHS, Len, B, DL)
fn optimize_memcmp_constant_size(ci: i32, l: i32, r: i32, len: u64) -> i32 {
    let rty = vals[ci].ty;
    if len == 0 { return c_null(rty); }
    if len == 1 {
        let lv = icb_zext(icb_load(T_I8, l, "lhsc"), rty, "lhsv");
        let rv = icb_zext(icb_load(T_I8, r, "rhsc"), rty, "rhsv");
        return icb_sub(lv, rv, "chardiff");
    }
    if len <= 0x7FFFFFFF && dl_is_legal_integer((len * 8) as i64) && is_only_used_in_zero_equality_comparison(ci) {
        let it = ty_int((len * 8) as i64);
        let pref = dl_align(it, false);
        var lv: i32 = -1;
        if is_constant(l) { lv = cf_fold_load_from_const_ptr(l, it, 0, false); }
        var rv: i32 = -1;
        if is_constant(r) { rv = cf_fold_load_from_const_ptr(r, it, 0, false); }
        if (lv >= 0 || get_known_alignment(l, ci) >= pref) && (rv >= 0 || get_known_alignment(r, ci) >= pref) {
            if lv < 0 { lv = icb_load(it, l, "lhsv"); }
            if rv < 0 { rv = icb_load(it, r, "rhsv"); }
            return icb_zext(icb_icmp(P_NE, lv, rv, ""), rty, "memcmp");
        }
    }
    return -1;
}
// optimizeMemCmpBCmpCommon(CI, B)
fn optimize_memcmp_bcmp_common(ci: i32) -> i32 {
    let l = cb_arg(ci, 0);
    let r = cb_arg(ci, 1);
    let size = cb_arg(ci, 2);
    annotate_nonnull_and_dereferenceable(ci, 0, 1, size);
    let res = optimize_memcmp_var_size(ci, l, r, size, false);
    if res >= 0 { return res; }
    if vals[size].kind != VK_CINT || ty_is_vector(vals[size].ty) { return -1; }
    return optimize_memcmp_constant_size(ci, l, r, ap_zext64(ci_ap(size)));
}
fn optimize_memcmp(ci: i32) -> i32 {
    let v = optimize_memcmp_bcmp_common(ci);
    if v >= 0 { return v; }
    if blc_is_emittable(LF_bcmp) && is_only_used_in_zero_equality_comparison(ci) {
        return copy_flags(ci, emit_bcmp(cb_arg(ci, 0), cb_arg(ci, 1), cb_arg(ci, 2)));
    }
    return -1;
}

// optimizeMemCpy / optimizeMemMove / optimizeMemSet (calls and intrinsics)
fn optimize_memcpy(ci: i32) -> i32 {
    let size = cb_arg(ci, 2);
    annotate_nonnull_and_dereferenceable(ci, 0, 1, size);
    if call_iid(ci) != 0 { return -1; }
    let nc = lcs_memcpy_like(IID_memcpy, cb_arg(ci, 0), cb_arg(ci, 1), size);
    merge_attributes_and_flags(nc, ci);
    return cb_arg(ci, 0);
}
fn optimize_memmove(ci: i32) -> i32 {
    let size = cb_arg(ci, 2);
    annotate_nonnull_and_dereferenceable(ci, 0, 1, size);
    if call_iid(ci) != 0 { return -1; }
    let nc = lcs_memcpy_like(IID_memmove, cb_arg(ci, 0), cb_arg(ci, 1), size);
    merge_attributes_and_flags(nc, ci);
    return cb_arg(ci, 0);
}
fn optimize_memset(ci: i32) -> i32 {
    let size = cb_arg(ci, 2);
    annotate_nonnull_and_dereferenceable(ci, 0, -1, size);
    if call_iid(ci) != 0 { return -1; }
    let v = icb_int_cast(cb_arg(ci, 1), T_I8, false, "");
    let nc = icb_memset(cb_arg(ci, 0), v, size, 1);
    merge_attributes_and_flags(nc, ci);
    return cb_arg(ci, 0);
}

// ---------------------------------------------------------------------------------------------
// printf, puts, exit, integer libcalls

// optimizePrintFString(CI, B)
fn optimize_printf_string(ci: i32) -> i32 {
    if !get_constant_string_info(cb_arg(ci, 0), true) { return -1; }
    var fs: u8[>..<] = [];
    for c in lcs_str { fs.push(c); }
    if fs.len == 0 { return if use_empty(ci) { ci } else { c_int_ty(vals[ci].ty, 0) }; }
    if !use_empty(ci) { return -1; }
    let ity = vals[ci].ty;
    if fs.len == 1 || (fs.len == 2 && fs[0] == '%' && fs[1] == '%') {
        return copy_flags(ci, emit_putchar(c_int_ty(ity, fs[0] as u64)));
    }
    if fs.len == 2 && fs[0] == '%' && fs[1] == 's' && cb_nargs(ci) > 1 {
        if !get_constant_string_info(op(ci, 1), true) { return -1; }
        var os: u8[>..<] = [];
        for c in lcs_str { os.push(c); }
        if os.len == 0 { return ci; }
        if os.len == 1 { return copy_flags(ci, emit_putchar(c_int_ty(ity, os[0] as u64))); }
        if os[os.len - 1] == '\n' {
            if !blc_is_emittable(LF_puts) { return -1; }
            let gv = lcs_create_global_string(os[..os.len - 1], "str");
            return copy_flags(ci, emit_puts(gv));
        }
        return -1;
    }
    var has_pct = false;
    for c in fs { if c == '%' { has_pct = true; } }
    if fs[fs.len - 1] == '\n' && !has_pct {
        if !blc_is_emittable(LF_puts) { return -1; }
        let gv = lcs_create_global_string(fs[..fs.len - 1], "str");
        return copy_flags(ci, emit_puts(gv));
    }
    if fs.len == 2 && fs[0] == '%' && fs[1] == 'c' && cb_nargs(ci) > 1 && ty_is_int(vals[cb_arg(ci, 1)].ty) {
        let ic = icb_int_cast(cb_arg(ci, 1), ity, false, "");
        return copy_flags(ci, emit_putchar(ic));
    }
    if fs.len == 3 && fs[0] == '%' && fs[1] == 's' && fs[2] == '\n' && cb_nargs(ci) > 1 && ty_kind(vals[cb_arg(ci, 1)].ty) == TK_PTR {
        return copy_flags(ci, emit_puts(cb_arg(ci, 1)));
    }
    return -1;
}
// optimizePrintF(CI, B)
fn optimize_printf(ci: i32) -> i32 {
    let v = optimize_printf_string(ci);
    if v >= 0 { return v; }
    annotate_nonnull_noundef(ci, 0);
    if blc_is_emittable(LF_iprintf) || blc_is_emittable(LF_small_printf) { lcs_np("printf -> iprintf/__small_printf"); }
    return -1;
}
// optimizePuts(CI, B)
fn optimize_puts(ci: i32) -> i32 {
    annotate_nonnull_noundef(ci, 0);
    if !use_empty(ci) { return -1; }
    if get_constant_string_info(cb_arg(ci, 0), true) && lcs_str.len == 0 {
        return copy_flags(ci, emit_putchar(c_int_ty(vals[ci].ty, 10)));
    }
    return -1;
}
// optimizeExit(CI)
fn optimize_exit(ci: i32) -> i32 {
    let a = cb_arg(ci, 0);
    if !call_has_fn_attr(ci, AK_Cold) && has_apint(a) && !ap_is_zero(ap_c(a)) {
        let ii = inst_of(ci);
        let l = insts[ii].attrs;
        let n = if l == 0 { 0 } else { alists[l].n as i64 };
        var sets: i32[>..<] = [];
        for j in 0..max(n, 1) {
            var s: i32 = 0;
            if j < n { s = alist_runs[alists[l].at + j]; }
            if j == 0 { s = aset_with(s, attr_enum(AK_Cold)); }
            sets.push(s);
        }
        insts[ii].attrs = alist_get(sets);
    }
    return -1;
}
// optimizeFFS / optimizeFls / optimizeAbs / optimizeIsDigit / optimizeIsAscii / optimizeToAscii
fn optimize_ffs(ci: i32) -> i32 {
    let rt = vals[ci].ty;
    let o = cb_arg(ci, 0);
    let at = vals[o].ty;
    let t = c_true();
    var v = icb_intrinsic(IID_cttz, [at], [o, t], "cttz");
    v = icb_add(v, c_int_ty(vals[v].ty, 1), "");
    v = icb_int_cast(v, rt, false, "");
    let cond = icb_icmp(P_NE, o, c_null(at), "");
    return icb_select(cond, v, c_int_ty(rt, 0), "", -1);
}
fn optimize_fls(ci: i32) -> i32 {
    let o = cb_arg(ci, 0);
    let at = vals[o].ty;
    let f = c_false();
    var v = icb_intrinsic(IID_ctlz, [at], [o, f], "ctlz");
    v = icb_sub(c_int_ty(vals[v].ty, ty_bits(at) as u64), v, "");
    return icb_int_cast(v, vals[ci].ty, false, "");
}
fn optimize_abs(ci: i32) -> i32 {
    let x = cb_arg(ci, 0);
    let isneg = icb_icmp(P_SLT, x, c_null(vals[x].ty), "");
    let negx = icb_neg(x, "neg", true);
    return icb_select(isneg, negx, x, "", -1);
}
fn optimize_isdigit(ci: i32) -> i32 {
    var o = cb_arg(ci, 0);
    let at = vals[o].ty;
    o = icb_sub(o, c_int_ty(at, 48), "isdigittmp");
    o = icb_icmp(P_ULT, o, c_int_ty(at, 10), "isdigit");
    return icb_zext(o, vals[ci].ty, "");
}
fn optimize_isascii(ci: i32) -> i32 {
    var o = cb_arg(ci, 0);
    o = icb_icmp(P_ULT, o, c_int_ty(vals[o].ty, 128), "isascii");
    return icb_zext(o, vals[ci].ty, "");
}
fn optimize_toascii(ci: i32) -> i32 { icb_and(cb_arg(ci, 0), c_int_ty(vals[ci].ty, 0x7F), "") }

// ---------------------------------------------------------------------------------------------
// Floating point

// replaceUnaryCall(CI, B, IID) / replaceBinaryCall
fn replace_unary_call(ci: i32, id: i64) -> i32 {
    let sv = icb_fmf;
    icb_fmf = icx_fmf(ci);
    let v = icx_unary_intrinsic(id, cb_arg(ci, 0), "");
    icb_fmf = sv;
    if is_inst(v) { ic_take_name(v, ci); }
    return copy_flags(ci, v);
}
fn replace_binary_call(ci: i32, id: i64) -> i32 {
    let sv = icb_fmf;
    icb_fmf = icx_fmf(ci);
    let v = icx_binary_intrinsic(id, cb_arg(ci, 0), cb_arg(ci, 1), "");
    icb_fmf = sv;
    if is_inst(v) { ic_take_name(v, ci); }
    return copy_flags(ci, v);
}

// optimizeSymmetricCall(CI, IsEven, B)
fn optimize_symmetric_call(ci: i32, even: bool) -> i32 {
    let src = cb_arg(ci, 0);
    if one_use(src) {
        let x = m_fneg(src);
        if x >= 0 {
            let sv = icb_fmf;
            icb_fmf = icx_fmf(ci);
            let c = lcs_create_call(called_function(ci), [x], "");
            icb_fmf = sv;
            copy_flags(ci, c);
            if even { return c; }
            return icx_fneg(c, icx_fmf(ci), "");
        }
    }
    if even {
        var x = m_fabs_x(src);
        if x < 0 && m_intrinsic(src, IID_copysign) { x = op(src, 0); }
        if x >= 0 {
            let sv = icb_fmf;
            icb_fmf = icx_fmf(ci);
            let c = lcs_create_call(called_function(ci), [x], "");
            icb_fmf = sv;
            return copy_flags(ci, c);
        }
    }
    return -1;
}
fn lf_in(lf: i64, xs: const i64[:]) -> bool { for x in xs { if x == lf { return true; } } return false; }

// optimizeSymmetric(CI, Func, B)
fn optimize_symmetric(ci: i32, lf: i64) -> i32 {
    if lf_in(lf, [LF_cos, LF_cosf, LF_cosl, LF_cosh, LF_coshf, LF_coshl]) { return optimize_symmetric_call(ci, true); }
    if lf_in(lf, [LF_sin, LF_sinf, LF_sinl, LF_sinh, LF_sinhf, LF_sinhl, LF_tan, LF_tanf, LF_tanl, LF_tanh, LF_tanhf,
                  LF_tanhl, LF_erf, LF_erff, LF_erfl]) { return optimize_symmetric_call(ci, false); }
    return -1;
}

// optimizeFloatingPointLibCall(CI, Func, B)
fn optimize_floating_point_libcall(ci: i32, lf: i64, unsafe_shrink: bool) -> i32 {
    if call_is_strictfp(ci) { return -1; }
    let v = optimize_symmetric(ci, lf);
    if v >= 0 { return v; }
    if lf_in(lf, [LF_sinpif, LF_sinpi, LF_cospif, LF_cospi]) { lcs_np("optimizeSinCosPi"); }
    if lf_in(lf, [LF_powf, LF_pow, LF_powl]) { lcs_np("optimizePow"); }
    if lf_in(lf, [LF_exp2l, LF_exp2, LF_exp2f]) { lcs_np("optimizeExp2"); }
    if lf_in(lf, [LF_fabsf, LF_fabs, LF_fabsl]) { return replace_unary_call(ci, IID_fabs); }
    if lf_in(lf, [LF_sqrtf, LF_sqrt, LF_sqrtl]) { lcs_np("optimizeSqrt"); }
    if lf_in(lf, [LF_fmod, LF_fmodf, LF_fmodl]) { lcs_np("optimizeFMod"); }
    if lf_in(lf, [LF_logf, LF_log, LF_logl, LF_log10f, LF_log10, LF_log10l, LF_log1pf, LF_log1p, LF_log1pl, LF_log2f,
                  LF_log2, LF_log2l, LF_logbf, LF_logb, LF_logbl]) { lcs_np("optimizeLog"); }
    if lf_in(lf, [LF_tan, LF_tanf, LF_tanl, LF_sinh, LF_sinhf, LF_sinhl, LF_asinh, LF_asinhf, LF_asinhl, LF_cosh,
                  LF_coshf, LF_coshl, LF_atanh, LF_atanhf, LF_atanhl]) { lcs_np("optimizeTrigInversionPairs"); }
    if lf == LF_ceil { return replace_unary_call(ci, IID_ceil); }
    if lf == LF_floor { return replace_unary_call(ci, IID_floor); }
    if lf == LF_round { return replace_unary_call(ci, IID_round); }
    if lf == LF_roundeven { return replace_unary_call(ci, IID_roundeven); }
    if lf == LF_nearbyint { return replace_unary_call(ci, IID_nearbyint); }
    if lf == LF_rint { return replace_unary_call(ci, IID_rint); }
    if lf == LF_trunc { return replace_unary_call(ci, IID_trunc); }
    if lf_in(lf, [LF_acos, LF_acosh, LF_asin, LF_atan, LF_cbrt, LF_exp, LF_exp10, LF_expm1, LF_cos, LF_sin, LF_tanh]) {
        if unsafe_shrink && lcs_has_float_version(ci) { lcs_np("optimizeUnaryDoubleFP"); }
        return -1;
    }
    if lf == LF_copysign {
        if lcs_has_float_version(ci) { lcs_np("optimizeBinaryDoubleFP"); }
        return -1;
    }
    if lf_in(lf, [LF_fdim, LF_fdimf, LF_fdiml]) { lcs_np("optimizeFdim"); }
    if lf_in(lf, [LF_fminf, LF_fmin, LF_fminl, LF_fmaxf, LF_fmax, LF_fmaxl]) { lcs_np("optimizeFMinFMax"); }
    if lf_in(lf, [LF_fminimum_numf, LF_fminimum_num, LF_fminimum_numl]) { return replace_binary_call(ci, IID_minimumnum); }
    if lf_in(lf, [LF_fmaximum_numf, LF_fmaximum_num, LF_fmaximum_numl]) { return replace_binary_call(ci, IID_maximumnum); }
    if lf_in(lf, [LF_cabs, LF_cabsf, LF_cabsl]) { return optimize_cabs(ci); }
    if lf_in(lf, [LF_remquo, LF_remquof, LF_remquol]) { lcs_np("optimizeRemquo"); }
    if lf_in(lf, [LF_nan, LF_nanf, LF_nanl]) { lcs_np("optimizeNaN"); }
    return -1;
}
// hasFloatVersion(M, FuncName)
fn lcs_has_float_version(ci: i32) -> bool {
    var nm: u8[>..] = [];
    nm.append(val_name(called_function(ci)));
    nm.push('f');
    return blc_is_emittable_name(nm);
}

// ---------------------------------------------------------------------------------------------
// optimizeStringMemoryLibCall and optimizeCall

fn optimize_string_memory_libcall(ci: i32, lf: i64) -> i32 {
    if lf == LF_strlen { return optimize_strlen(ci); }
    if lf == LF_strnlen { return optimize_strnlen(ci); }
    if lf == LF_wcslen { return optimize_wcslen(ci); }
    if lf == LF_strcmp { return optimize_strcmp(ci); }
    if lf == LF_memcmp { return optimize_memcmp(ci); }
    if lf == LF_bcmp { return optimize_memcmp_bcmp_common(ci); }
    if lf == LF_memcpy { return optimize_memcpy(ci); }
    if lf == LF_memmove { return optimize_memmove(ci); }
    if lf == LF_memset { return optimize_memset(ci); }
    if lf == LF_strcat { lcs_np("optimizeStrCat"); }
    if lf == LF_strncat { lcs_np("optimizeStrNCat"); }
    if lf == LF_strchr { return optimize_strchr(ci); }
    if lf == LF_strrchr { return optimize_strrchr(ci); }
    if lf == LF_strncmp { return optimize_strncmp(ci); }
    if lf == LF_strcpy { lcs_np("optimizeStrCpy"); }
    if lf == LF_stpcpy { lcs_np("optimizeStpCpy"); }
    if lf == LF_strlcpy { lcs_np("optimizeStrLCpy"); }
    if lf == LF_stpncpy || lf == LF_strncpy { lcs_np("optimizeStringNCpy"); }
    if lf == LF_strpbrk { lcs_np("optimizeStrPBrk"); }
    if lf == LF_strndup { lcs_np("optimizeStrNDup"); }
    if lf_in(lf, [LF_strtol, LF_strtod, LF_strtof, LF_strtoul, LF_strtoll, LF_strtold, LF_strtoull]) {
        // optimizeStrTo: annotate the string argument (and the end pointer's capture is the callee's business)
        let ep = cb_arg(ci, 1);
        if vals[ep].kind == VK_CNULL { cs_add_param_attr(ci, 0, attr_int(AK_Captures, 0)); }
        return -1;
    }
    if lf == LF_strspn { lcs_np("optimizeStrSpn"); }
    if lf == LF_strcspn { lcs_np("optimizeStrCSpn"); }
    if lf == LF_strstr { lcs_np("optimizeStrStr"); }
    if lf == LF_memchr { return optimize_memchr(ci); }
    if lf == LF_memrchr { lcs_np("optimizeMemRChr"); }
    if lf == LF_memccpy { lcs_np("optimizeMemCCpy"); }
    if lf == LF_mempcpy { lcs_np("optimizeMemPCpy"); }
    if lf == LF_realloc { lcs_np("optimizeRealloc"); }
    if lf == LF_bcopy { lcs_np("optimizeBCopy"); }
    // optimizeNew: OptimizeHotColdNew is off by default
    return -1;
}

// ignoreCallingConv(Func)
fn ignore_calling_conv(lf: i64) -> bool { lf == LF_abs || lf == LF_labs || lf == LF_llabs || lf == LF_strlen }

// LibCallSimplifier::optimizeCall(CI, Builder)
fn lcs_optimize_call(ci: i32) -> i32 {
    if call_is_nobuiltin(ci) { return -1; }
    let callee = called_function(ci);
    let is_ccc = is_calling_conv_c_compatible(insts[inst_of(ci)].cc as i64, insts[inst_of(ci)].ty2, inst_func(ci));
    let save_ci = lcs_ci;
    lcs_ci = ci;
    let r = lcs_optimize_call_impl(ci, callee, is_ccc);
    lcs_ci = save_ci;
    return r;
}
fn lcs_optimize_call_impl(ci: i32, callee: i32, is_ccc: bool) -> i32 {
    var unsafe_shrink = false;
    if flag_given("enable-double-float-shrink") { unsafe_shrink = flag_bool("enable-double-float-shrink", false); }
    else if is_fp_math_operator(ci) && (icx_fmf(ci) & FMF_FAST) == FMF_FAST { unsafe_shrink = true; }
    let id = call_iid(ci);
    if id != 0 {
        if !is_ccc { return -1; }
        if id == IID_pow { lcs_np("optimizePow (llvm.pow)"); }
        if id == IID_exp2 { lcs_np("optimizeExp2 (llvm.exp2)"); }
        if id == IID_log || id == IID_log2 || id == IID_log10 { lcs_np("optimizeLog (llvm.log*)"); }
        if id == IID_sqrt { lcs_np("optimizeSqrt (llvm.sqrt)"); }
        if id == IID_memset { return optimize_memset(ci); }
        if id == IID_memcpy { return optimize_memcpy(ci); }
        if id == IID_memmove { return optimize_memmove(ci); }
        if id == IID_sin || id == IID_cos {
            if unsafe_shrink { lcs_np("optimizeUnaryDoubleFP (llvm.sin/cos)"); }
            return -1;
        }
        return -1;
    }
    // FortifiedLibCallSimplifier::optimizeCall
    let flf = tli_get_libfunc(callee);
    if flf >= 0 && ends_with(TLI_NAMES[flf], "_chk") { lcs_np("FortifiedLibCallSimplifier"); }
    let lf0 = tli_get_libfunc(callee);
    if lf0 < 0 || !blc_is_emittable(lf0 as i64) { return -1; }
    let lf = lf0 as i64;
    if !ignore_calling_conv(lf) && !is_ccc { return -1; }
    let v = optimize_string_memory_libcall(ci, lf);
    if v >= 0 { return v; }
    let v2 = optimize_floating_point_libcall(ci, lf, unsafe_shrink);
    if v2 >= 0 { return v2; }
    if lf == LF_ffs || lf == LF_ffsl || lf == LF_ffsll { return optimize_ffs(ci); }
    if lf == LF_fls || lf == LF_flsl || lf == LF_flsll { return optimize_fls(ci); }
    if lf == LF_abs || lf == LF_labs || lf == LF_llabs { return optimize_abs(ci); }
    if lf == LF_isdigit { return optimize_isdigit(ci); }
    if lf == LF_isascii { return optimize_isascii(ci); }
    if lf == LF_toascii { return optimize_toascii(ci); }
    if lf == LF_atoi || lf == LF_atol || lf == LF_atoll { lcs_np("optimizeAtoi"); }
    if lf == LF_strtol || lf == LF_strtoll || lf == LF_strtoul || lf == LF_strtoull { lcs_np("optimizeStrToInt"); }
    if lf == LF_printf { return optimize_printf(ci); }
    if lf == LF_sprintf { lcs_np("optimizeSPrintF"); }
    if lf == LF_snprintf { lcs_np("optimizeSnPrintF"); }
    if lf == LF_fprintf { lcs_np("optimizeFPrintF"); }
    if lf == LF_fwrite { lcs_np("optimizeFWrite"); }
    if lf == LF_fputs { lcs_np("optimizeFPuts"); }
    if lf == LF_puts { return optimize_puts(ci); }
    if lf == LF_perror || lf == LF_vfprintf || lf == LF_fiprintf { lcs_np("optimizeErrorReporting"); }
    if lf == LF_exit || lf == LF_Exit { return optimize_exit(ci); }
    return -1;
}

// new GlobalVariable(M, Ty, true, PrivateLinkage, Init, Name) with unnamed_addr and align 1 (CreateGlobalString)
fn module_new_private_string(init: i32, name: const u8[:]) -> i32 {
    let m = globs[glob_of(inst_func(icb_pos_or_end()))].module;
    let gv = new_glob(VK_GVAR, ty_ptr(0), -1, 1);
    let g = glob_of(gv);
    globs[g].module = m;
    globs[g].vty = vals[init].ty;
    globs[g].is_const = 1;
    globs[g].is_decl = 0;
    globs[g].linkage = LK_PRIVATE as u8;
    globs[g].dso_local = 1;
    globs[g].unnamed = 2;
    globs[g].align = 1;
    set_op(gv, 0, init);
    symtab_set_name(modules[m].symtab, gv, name, true);
    module_append_global(gv);
    return gv;
}
fn icb_pos_or_end() -> i32 { if icb_pos >= 0 { icb_pos } else { block_last(icb_bb) } }
fn ends_with(s: const u8[:], t: const u8[:]) -> bool { s.len >= t.len && s[s.len - t.len..] == t }

// isOnlyUsedInEqualityComparison(V, With)
fn is_only_used_in_equality_comparison(v: i32, with: i32) -> bool {
    var u = vals[v].first_use;
    while u >= 0 {
        let us = uses[u].user;
        u = uses[u].next;
        if is_inst_op(us, OP_ICMP) && icmp_is_equality(inst_pred(us)) && op(us, 1) == with { continue; }
        return false;
    }
    return true;
}
// isKnownNonZero(V, DL): no context instruction, no assumptions
fn known_non_zero_dl(v: i32) -> bool {
    let sv = kb_cxt;
    kb_cxt = -1;
    let r = is_known_non_zero(v, 0);
    kb_cxt = sv;
    return r;
}
// memChrToCharCompare(CI, NBytes, B, DL)
fn memchr_to_char_compare(ci: i32, nbytes: i32) -> i32 {
    let src = cb_arg(ci, 0);
    var cv = cb_arg(ci, 1);
    let c0 = icb_load(T_I8, src, "");
    cv = icb_trunc(cv, T_I8, "");
    var cmp = icb_icmp(P_EQ, c0, cv, "char0cmp");
    if nbytes >= 0 {
        let a = icb_icmp(P_NE, nbytes, c_int_ty(vals[nbytes].ty, 0), "");
        cmp = icb_logical_and(a, cmp, "");
    }
    return icb_select(cmp, src, c_null(vals[ci].ty), "", -1);
}
fn icb_inbounds_gep_i8(p: i32, off: i32, name: const u8[:]) -> i32 { icb_gep(T_I8, p, [off], name, GEP_INBOUNDS | GEP_NUSW) }
fn lcs_find(s: const u8[:], c: u8, from: i64) -> i64 { for i in from..s.len { if s[i] == c { return i; } } return -1; }
fn lcs_find_not(s: const u8[:], c: u8, from: i64) -> i64 { for i in from..s.len { if s[i] != c { return i; } } return -1; }

// optimizeStrChr(CI, B)
fn optimize_strchr(ci: i32) -> i32 {
    let src = cb_arg(ci, 0);
    let cv = cb_arg(ci, 1);
    annotate_nonnull_noundef(ci, 0);
    if is_only_used_in_equality_comparison(ci, src) { return memchr_to_char_compare(ci, -1); }
    let cc = if vals[cv].kind == VK_CINT && !ty_is_vector(vals[cv].ty) { cv } else { -1 };
    if cc < 0 {
        let len = get_string_length(src, 8);
        if len != 0 { annotate_dereferenceable_bytes(ci, 0, len); } else { return -1; }
        let ft = globs[glob_of(called_function(ci))].vty;
        let p1 = ty_fn_param(ft, 1);
        if !(ty_is_int(p1) && ty_bits(p1) == 32) { return -1; }
        let pt = ty_ptr(0);
        let it = tli_int_ty();
        let st = tli_sizet_ty();
        let lv = c_int_ty(st, len);
        return copy_flags(ci, emit_lib_call(LF_memchr, pt, [pt, it, st], [src, cv, lv], false));
    }
    if ap_is_zero(ci_ap(cc)) {
        let np = c_null(vals[ci].ty);
        if is_only_used_in_equality_comparison(ci, np) { return icb_cast(OP_INTTOPTR, c_true(), vals[ci].ty, ""); }
    }
    if !get_constant_string_info(src, true) {
        if ap_is_zero(ci_ap(cc)) {
            let sl = emit_strlen(src);
            if sl >= 0 { return icb_inbounds_gep_i8(src, sl, "strchr"); }
        }
        return -1;
    }
    let ch = (ap_sext64(ci_ap(cc)) & 0xFF) as u8;
    var i: i64 = 0;
    if ch == 0 { i = lcs_str.len; } else {
        // StringRef::find(char(getSExtValue()))
        i = lcs_find(lcs_str[..], ch, 0);
    }
    if i < 0 { return c_null(vals[ci].ty); }
    return icb_inbounds_gep_i8(src, c_int(T_I64, i), "strchr");
}

// optimizeStrRChr(CI, B)
fn optimize_strrchr(ci: i32) -> i32 {
    let src = cb_arg(ci, 0);
    let cv = cb_arg(ci, 1);
    let cc = if vals[cv].kind == VK_CINT && !ty_is_vector(vals[cv].ty) { cv } else { -1 };
    annotate_nonnull_noundef(ci, 0);
    if !get_constant_string_info(src, true) {
        if cc >= 0 && ap_is_zero(ci_ap(cc)) {
            let pt = ty_ptr(0);
            let it = tli_int_ty();
            let z = c_int_ty(it, 0);
            return copy_flags(ci, emit_lib_call(LF_strchr, pt, [pt, it], [src, z], false));
        }
        return -1;
    }
    let nb = (lcs_str.len + 1) as u64;
    let pt = ty_ptr(0);
    let it = tli_int_ty();
    let st = tli_sizet_ty();
    let sz = c_int_ty(st, nb);
    return copy_flags(ci, emit_lib_call(LF_memrchr, pt, [pt, it, st], [src, cv, sz], false));
}

// optimizeStrNCmp(CI, B)
fn optimize_strncmp(ci: i32) -> i32 {
    let s1 = cb_arg(ci, 0);
    let s2 = cb_arg(ci, 1);
    let size = cb_arg(ci, 2);
    let rty = vals[ci].ty;
    if s1 == s2 { return c_int_ty(rty, 0); }
    if known_non_zero_dl(size) { annotate_nonnull_noundef(ci, 0); annotate_nonnull_noundef(ci, 1); }
    if !(vals[size].kind == VK_CINT && !ty_is_vector(vals[size].ty)) { return optimize_memcmp_var_size(ci, s1, s2, size, true); }
    let length = ap_zext64(ci_ap(size));
    if length == 0 { return c_int_ty(rty, 0); }
    if length == 1 { return copy_flags(ci, emit_memcmp(s1, s2, size)); }
    let h1 = get_constant_string_info(s1, true);
    var str1: u8[>..<] = [];
    for c in lcs_str { str1.push(c); }
    let h2 = get_constant_string_info(s2, true);
    var str2: u8[>..<] = [];
    for c in lcs_str { str2.push(c); }
    if h1 && h2 {
        let n1 = if length >= str1.len as u64 { str1.len } else { length as i64 };
        let n2 = if length >= str2.len as u64 { str2.len } else { length as i64 };
        var r: i64 = 0;
        let mn = min(n1, n2);
        var i: i64 = 0;
        while i < mn && str1[i] == str2[i] { i++; }
        if i < mn { r = if str1[i] < str2[i] { -1 } else { 1 }; }
        else if n1 != n2 { r = if n1 < n2 { -1 } else { 1 }; }
        return c_int_ty_s(rty, r);
    }
    if h1 && str1.len == 0 { return icb_neg(icb_zext(icb_load(T_I8, s2, "strcmpload"), rty, ""), "", false); }
    if h2 && str2.len == 0 { return icb_zext(icb_load(T_I8, s1, "strcmpload"), rty, ""); }
    var l1 = get_string_length(s1, 8);
    if l1 != 0 { annotate_dereferenceable_bytes(ci, 0, l1); }
    var l2 = get_string_length(s2, 8);
    if l2 != 0 { annotate_dereferenceable_bytes(ci, 1, l2); }
    if !h1 && h2 {
        l2 = min(l2, length);
        if can_transform_to_memcmp_dl(ci, s1, l2) { return copy_flags(ci, emit_memcmp(s1, s2, tli_as_size_t(l2))); }
    } else if h1 && !h2 {
        l1 = min(l1, length);
        if can_transform_to_memcmp_dl(ci, s2, l1) { return copy_flags(ci, emit_memcmp(s1, s2, tli_as_size_t(l1))); }
    }
    return -1;
}
// canTransformToMemCmp(CI, Str, Len, SimplifyQuery(DL)): no context, no assumptions
fn can_transform_to_memcmp_dl(ci: i32, s: i32, len: u64) -> bool {
    if !is_only_used_in_comparison_with_zero(ci) { return false; }
    let sc = spec_cxt;
    let sa = spec_use_ac;
    spec_cxt = -1;
    spec_use_ac = false;
    spec_visited.clear();
    let d = spec_deref_aligned(s, 1, ap_u64(len, 64), 16);
    spec_cxt = sc;
    spec_use_ac = sa;
    if !d { return false; }
    if func_has_fn_attr(inst_func(ci), AK_SanitizeMemory) { return false; }
    return true;
}

// shouldOptimizeForSize(BB, PSI, BFI): without a profile summary, the function's optsize/minsize
fn lcs_opt_for_size(ci: i32) -> bool {
    let fv = inst_func(ci);
    return func_has_fn_attr(fv, AK_OptimizeForSize) || func_has_fn_attr(fv, AK_MinSize);
}

// optimizeMemChr(CI, B)
fn optimize_memchr(ci: i32) -> i32 {
    let src = cb_arg(ci, 0);
    let size = cb_arg(ci, 2);
    if known_non_zero_dl(size) {
        annotate_nonnull_noundef(ci, 0);
        if is_only_used_in_equality_comparison(ci, src) { return memchr_to_char_compare(ci, size); }
    }
    var cv = cb_arg(ci, 1);
    let cc = if vals[cv].kind == VK_CINT && !ty_is_vector(vals[cv].ty) { cv } else { -1 };
    let lc = if vals[size].kind == VK_CINT && !ty_is_vector(vals[size].ty) { size } else { -1 };
    let np = c_null(vals[ci].ty);
    if lc >= 0 {
        if ap_is_zero(ci_ap(lc)) { return np; }
        if ap_is_one(ci_ap(lc)) {
            let v = icb_load(T_I8, src, "memchr.char0");
            cv = icb_trunc(cv, T_I8, "");
            let cmp = icb_icmp(P_EQ, v, cv, "memchr.char0cmp");
            return icb_select(cmp, src, np, "memchr.sel", -1);
        }
    }
    if !get_constant_string_info(src, false) { return -1; }
    var str: u8[>..<] = [];
    for c in lcs_str { str.push(c); }
    if cc >= 0 {
        // StringRef::find(char(getZExtValue()))
        let pos = lcs_find(str[..], ap_zext64(ci_ap(cc)) as u8, 0);
        if pos < 0 { return np; }
        let cmp = icb_icmp(P_ULE, size, c_int_ty(vals[size].ty, pos as u64), "memchr.cmp");
        let sp = icb_inbounds_gep_i8(src, c_int(T_I64, pos), "memchr.ptr");
        return icb_select(cmp, np, sp, "", -1);
    }
    if str.len == 0 { return np; }
    if lc >= 0 {
        let l = ap_zext64(ci_ap(lc));
        if l < str.len as u64 { str.resize(l as i64); }
    }
    let pos = lcs_find_not(str[..], str[0], 0);
    if pos < 0 || lcs_find_not(str[..], str[pos], pos) < 0 {
        let szt = vals[size].ty;
        cv = icb_trunc(cv, T_I8, "");
        var sel1 = np;
        if pos >= 0 {
            let pv = c_int_ty(szt, pos as u64);
            let sposc = c_int(T_I8, str[pos] as i64);
            let ceq = icb_icmp(P_EQ, cv, sposc, "");
            let ngt = icb_icmp(P_UGT, size, pv, "");
            let a = icb_and(ceq, ngt, "");
            let sp = icb_inbounds_gep_i8(src, pv, "");
            sel1 = icb_select(a, sp, np, "memchr.sel1", -1);
        }
        let s0 = c_int(T_I8, str[0] as i64);
        let ceq0 = icb_icmp(P_EQ, s0, cv, "");
        let nnez = icb_icmp(P_NE, size, c_int_ty(szt, 0), "");
        let a = icb_and(nnez, ceq0, "");
        return icb_select(a, src, sel1, "memchr.sel2", -1);
    }
    if lc < 0 {
        if is_only_used_in_equality_comparison(ci, src) { return memchr_to_char_compare(ci, size); }
        return -1;
    }
    if lcs_opt_for_size(ci) || str.len == 0 || !is_only_used_in_zero_equality_comparison(ci) { return -1; }
    var mx: u8 = 0;
    for c in str { if c > mx { mx = c; } }
    if !dl_fits_in_legal_integer((mx as i64) + 1) {
        var sorted: u8[>..<] = [];
        for c in str { sorted.push(c); }
        sort(sorted) { a, b => a < b };
        var ncr = 1;
        for i in 1..sorted.len { if (sorted[i] as i64) > (sorted[i - 1] as i64) + 1 { ncr++; } }
        if ncr > 2 { return -1; }
        cv = icb_trunc(cv, T_I8, "");
        var acc: i32 = -1;
        for c in sorted {
            let e = icb_icmp(P_EQ, cv, c_int(T_I8, c as i64), "");
            acc = if acc < 0 { e } else { icb_or(acc, e, "") };
        }
        return icb_cast(OP_INTTOPTR, acc, vals[ci].ty, "");
    }
    var width: i64 = 1;
    let base = max(7, mx as i64);
    while width <= base { width *= 2; }
    var bf = ap_zero(width);
    for c in str { bf = ap_set_bit(bf, c as i64); }
    let wt = ty_int(width);
    let bfc = c_int_ap(wt, bf);
    var c = icb_zext_or_trunc(cv, wt, "");
    c = icb_and(c, c_int_ty(wt, 0xFF), "");
    let bounds = icb_icmp(P_ULT, c, c_int_ty(wt, width as u64), "memchr.bounds");
    let shl = icb_shl(c_int_ty(wt, 1), c, "");
    let bits = icb_is_not_null(icb_and(shl, bfc, ""), "memchr.bits");
    return icb_cast(OP_INTTOPTR, icb_logical_and(bounds, bits, "memchr"), vals[ci].ty, "");
}
// DataLayout::fitsInLegalInteger(Width): Width <= the largest legal integer
fn dl_fits_in_legal_integer(w: i64) -> bool {
    var mx: i64 = 0;
    for x in dl_native { if x > mx { mx = x; } }
    return w <= mx;
}

// optimizeCAbs(CI, B)
fn optimize_cabs(ci: i32) -> i32 {
    let fmf = icx_fmf(ci);
    let fast = (fmf & FMF_FAST) == FMF_FAST;
    var re: i32 = -1;
    var im: i32 = -1;
    if cb_nargs(ci) == 1 {
        if !fast { return -1; }
        let o = cb_arg(ci, 0);
        re = icb_extract_value(o, [0], "real");
        im = icb_extract_value(o, [1], "imag");
    } else {
        re = cb_arg(ci, 0);
        im = cb_arg(ci, 1);
        var absop: i32 = -1;
        if vals[re].kind == VK_CFP && !ty_is_vector(vals[re].ty) {
            if cfp_parts(re).cat == FC_ZERO { absop = im; }
        } else if vals[im].kind == VK_CFP && !ty_is_vector(vals[im].ty) {
            if cfp_parts(im).cat == FC_ZERO { absop = re; }
        }
        if absop >= 0 { return copy_flags(ci, icx_unary_intrinsic_f(IID_fabs, absop, fmf, "cabs")); }
        if !fast { return -1; }
    }
    let rr = icx_fbinop(OP_FMUL, re, re, fmf, "");
    let ii = icx_fbinop(OP_FMUL, im, im, fmf, "");
    let sum = icx_fbinop(OP_FADD, rr, ii, fmf, "");
    return copy_flags(ci, icx_unary_intrinsic_f(IID_sqrt, sum, fmf, "cabs"));
}
