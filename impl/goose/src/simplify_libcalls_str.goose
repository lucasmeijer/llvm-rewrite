// LibCallSimplifier, string/stdio part, and FortifiedLibCallSimplifier: port of
// llvm/lib/Transforms/Utils/SimplifyLibCalls.cpp (optimizeStrCat, emitStrLenMemCpy, optimizeStrNCat, optimizeStrNDup,
// optimizeStrCpy, optimizeStpCpy, optimizeStrLCpy, optimizeStringNCpy, optimizeStrPBrk, optimizeStrSpn,
// optimizeStrCSpn, optimizeStrStr, optimizeMemCCpy, optimizeMemPCpy, optimizeRealloc, optimizeBCopy,
// maybeOptimizeNoBuiltinOperatorNew / optimizeNew, optimizeErrorReporting, the iprintf/__small_printf rewrites of
// optimizePrintF, optimizeSPrintF(String), emitSnPrintfMemCpy, optimizeSnPrintF(String), optimizeFPrintF(String),
// optimizeFWrite, optimizeFPuts; FortifiedLibCallSimplifier::isFortifiedCallFoldable, optimizeCall and every
// optimize*Chk) plus the emit* helpers of llvm/lib/Transforms/Utils/BuildLibCalls.cpp they use.
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
import flags;
import vt;
import knownbits;
import apint;
import tli;
import build_libcalls;
import ic;
import ic_builder;
import ic_common;
import ic_calls;
import ic_loadstorealloca;
import simplify_libcalls;
import ic_phi;

// ---------------------------------------------------------------------------------------------
// BuildLibCalls emit helpers

fn lcs_ptr() -> i32 { ty_ptr(0) }

// emitLibCall with an explicit call name (most helpers name the call after the function)
fn emit_lib_call_named(lf: i64, rt: i32, pts: const i32[:], argsv: const i32[:], va: bool, named: bool, infer: bool) -> i32 {
    if !blc_is_emittable(lf) { return -1; }
    let fty = ty_func_of(rt, pts, va);
    let f = blc_get_or_insert(lf, fty, 0);
    var fnm: u8[>..] = [];
    fnm.append(tli_name(lf));
    if infer { blc_infer_by_name(fnm); }
    let c = if named { lcs_create_call(f, argsv, fnm) } else { lcs_create_call(f, argsv, "") };
    insts[inst_of(c)].cc = globs[glob_of(f)].cc;
    return c;
}
fn emit_strdup(p: i32) -> i32 { emit_lib_call(LF_strdup, lcs_ptr(), [lcs_ptr()], [p], false) }
fn emit_strchr(p: i32, ch: u8) -> i32 {
    let it = tli_int_ty();
    let cv = c_int_ty(it, ch as u64);
    let pt = lcs_ptr();
    return emit_lib_call(LF_strchr, pt, [pt, it], [p, cv], false);
}
fn emit_strncmp(a: i32, b: i32, len: i32) -> i32 {
    let pt = lcs_ptr();
    return emit_lib_call(LF_strncmp, tli_int_ty(), [pt, pt, tli_sizet_ty()], [a, b, len], false);
}
fn emit_strcpy(d: i32, s: i32) -> i32 {
    let pt: i32 = vals[d].ty;
    return emit_lib_call(LF_strcpy, pt, [pt, pt], [d, s], false);
}
fn emit_stpcpy(d: i32, s: i32) -> i32 { let pt = lcs_ptr(); return emit_lib_call(LF_stpcpy, pt, [pt, pt], [d, s], false); }
fn emit_strncpy(d: i32, s: i32, n: i32) -> i32 {
    let pt = lcs_ptr();
    return emit_lib_call(LF_strncpy, pt, [pt, pt, tli_sizet_ty()], [d, s, n], false);
}
fn emit_stpncpy(d: i32, s: i32, n: i32) -> i32 {
    let pt = lcs_ptr();
    return emit_lib_call(LF_stpncpy, pt, [pt, pt, tli_sizet_ty()], [d, s, n], false);
}
fn emit_mempcpy(d: i32, s: i32, n: i32) -> i32 {
    let pt = lcs_ptr();
    return emit_lib_call(LF_mempcpy, pt, [pt, pt, tli_sizet_ty()], [d, s, n], false);
}
fn emit_memccpy(d: i32, s: i32, c: i32, n: i32) -> i32 {
    let pt = lcs_ptr();
    return emit_lib_call(LF_memccpy, pt, [pt, pt, tli_int_ty(), tli_sizet_ty()], [d, s, c, n], false);
}
fn emit_strcat(d: i32, s: i32) -> i32 { let pt = lcs_ptr(); return emit_lib_call(LF_strcat, pt, [pt, pt], [d, s], false); }
fn emit_strlcpy(d: i32, s: i32, n: i32) -> i32 {
    let pt = lcs_ptr();
    let st = tli_sizet_ty();
    return emit_lib_call(LF_strlcpy, st, [pt, pt, st], [d, s, n], false);
}
fn emit_strlcat(d: i32, s: i32, n: i32) -> i32 {
    let pt = lcs_ptr();
    let st = tli_sizet_ty();
    return emit_lib_call(LF_strlcat, st, [pt, pt, st], [d, s, n], false);
}
fn emit_strncat(d: i32, s: i32, n: i32) -> i32 {
    let pt = lcs_ptr();
    return emit_lib_call(LF_strncat, pt, [pt, pt, tli_sizet_ty()], [d, s, n], false);
}
fn emit_snprintf(d: i32, size: i32, fmt: i32, va: const i32[:]) -> i32 {
    let pt = lcs_ptr();
    var argsv: i32[>..<] = [];
    argsv.push(d); argsv.push(size); argsv.push(fmt);
    for a in va { argsv.push(a); }
    return emit_lib_call(LF_snprintf, tli_int_ty(), [pt, tli_sizet_ty(), pt], argsv, true);
}
fn emit_sprintf(d: i32, fmt: i32, va: const i32[:]) -> i32 {
    let pt = lcs_ptr();
    var argsv: i32[>..<] = [];
    argsv.push(d); argsv.push(fmt);
    for a in va { argsv.push(a); }
    return emit_lib_call(LF_sprintf, tli_int_ty(), [pt, pt], argsv, true);
}
fn emit_vsnprintf(d: i32, size: i32, fmt: i32, vl: i32) -> i32 {
    let pt = lcs_ptr();
    return emit_lib_call(LF_vsnprintf, tli_int_ty(), [pt, tli_sizet_ty(), pt, vals[vl].ty as i32], [d, size, fmt, vl], false);
}
fn emit_vsprintf(d: i32, fmt: i32, vl: i32) -> i32 {
    let pt = lcs_ptr();
    return emit_lib_call(LF_vsprintf, tli_int_ty(), [pt, pt, vals[vl].ty as i32], [d, fmt, vl], false);
}
// emitMemCpyChk: getOrInsertLibFunc with a nounwind function attribute list, an unnamed call
fn emit_memcpy_chk(d: i32, s: i32, len: i32, osz: i32) -> i32 {
    if !blc_is_emittable(LF_memcpy_chk) { return -1; }
    let pt = lcs_ptr();
    let st = tli_sizet_ty();
    var sets: i32[>..<] = [];
    sets.push(aset_with(0, attr_enum(AK_NoUnwind)));
    let al = alist_get(sets);
    let f = blc_get_or_insert(LF_memcpy_chk, ty_func_of(pt, [pt, pt, st, st], false), al);
    let c = lcs_create_call(f, [d, s, len, osz], "");
    insts[inst_of(c)].cc = globs[glob_of(f)].cc;
    return c;
}
// emitFPutC / emitFPutS / emitFWrite: attributes are inferred only for a pointer File argument
fn emit_fputc(ch: i32, file: i32) -> i32 {
    if !blc_is_emittable(LF_fputc) { return -1; }
    let it = tli_int_ty();
    return emit_lib_call_named(LF_fputc, it, [it, vals[file].ty as i32], [ch, file], false, true,
                               ty_kind(vals[file].ty) == TK_PTR);
}
fn emit_fputs(s: i32, file: i32) -> i32 {
    if !blc_is_emittable(LF_fputs) { return -1; }
    let it = tli_int_ty();
    let pt = lcs_ptr();
    return emit_lib_call_named(LF_fputs, it, [pt, vals[file].ty as i32], [s, file], false,
                               true, ty_kind(vals[file].ty) == TK_PTR);
}
fn emit_fwrite(p: i32, size: i32, file: i32) -> i32 {
    if !blc_is_emittable(LF_fwrite) { return -1; }
    let st = tli_sizet_ty();
    let one = c_int_ty(st, 1);
    let pt = lcs_ptr();
    return emit_lib_call_named(LF_fwrite, st, [pt, st, st, vals[file].ty as i32], [p, size, one, file],
                               false, false, ty_kind(vals[file].ty) == TK_PTR);
}
fn emit_malloc(n: i32) -> i32 { emit_lib_call(LF_malloc, lcs_ptr(), [tli_sizet_ty()], [n], false) }
// emitHotColdNew & co: Module::getOrInsertFunction (no mandatory attributes) + inferNonMandatoryLibFuncAttrs
fn emit_hot_cold_new(lf: i64, rt: i32, argsv: const i32[:], sized: bool) -> i32 {
    if !blc_is_emittable(lf) { return -1; }
    var pts: i32[>..<] = [];
    for a in argsv { pts.push(vals[a].ty as i32); }
    var fnm: u8[>..] = [];
    fnm.append(tli_name(lf));
    let f = module_get_or_insert_function(fnm, ty_func_of(rt, pts, false), 0);
    blc_infer_by_name(fnm);
    let c = if sized { lcs_create_call(f, argsv, "sized_ptr") } else { lcs_create_call(f, argsv, fnm) };
    insts[inst_of(c)].cc = globs[glob_of(f)].cc;
    return c;
}

// StructType::get(Ctx, Elts) (literal, not packed)
fn ty_struct_of(es: const i32[:]) -> i32 {
    let at = ints.len as i32;
    for e in es { ints.push(e); }
    return ty_struct_run(at, es.len, false);
}
fn is_cint_scalar(v: i32) -> bool { vals[v].kind == VK_CINT && !ty_is_vector(vals[v].ty) }
fn cint_zext(v: i32) -> u64 { ap_zext64(ci_ap(v)) }
// IRBuilder::CreateStore(V, Ptr): the ABI alignment of V's type
fn icb_store(v: i32, p: i32) -> i32 { icb_aligned_store(v, p, dl_align(vals[v].ty, true)) }
// IRBuilder::CreatePtrDiff(LHS, RHS): sub (ptrtoaddr LHS), (ptrtoaddr RHS)
fn icb_ptr_diff(l: i32, r: i32) -> i32 {
    let at = dl_index_type(vals[l].ty);
    let la = icb_cast(OP_PTRTOADDR, l, at, "");
    let ra = icb_cast(OP_PTRTOADDR, r, at, "");
    return icb_sub(la, ra, "");
}
fn lcs_str_copy(out: u8[>..<]&) { out.clear(); for c in lcs_str { out.push(c); } }
fn bytes_contains(s: const u8[:], c: u8) -> bool { for x in s { if x == c { return true; } } return false; }
// StringRef::find_first_of / find_first_not_of
fn find_first_of(s: const u8[:], set: const u8[:]) -> i64 { for x, i in s { if bytes_contains(set, x) { return i; } } return -1; }
fn find_first_not_of(s: const u8[:], set: const u8[:]) -> i64 { for x, i in s { if !bytes_contains(set, x) { return i; } } return -1; }
fn find_sub(s: const u8[:], t: const u8[:]) -> i64 {
    if t.len == 0 { return 0; }
    if t.len > s.len { return -1; }
    for i in 0..s.len - t.len + 1 { if s[i..i + t.len] == t { return i; } }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// String optimizers

// emitStrLenMemCpy(Src, Dst, Len, B)
fn emit_strlen_memcpy(src: i32, dst: i32, len: u64) -> i32 {
    let dl = emit_strlen(dst);
    if dl < 0 { return -1; }
    let cd = icb_inbounds_gep_i8(dst, dl, "endptr");
    lcs_memcpy_like(IID_memcpy, cd, src, tli_as_size_t(len + 1));
    return dst;
}
// optimizeStrCat(CI, B)
fn optimize_strcat(ci: i32) -> i32 {
    let dst = cb_arg(ci, 0);
    let src = cb_arg(ci, 1);
    annotate_nonnull_noundef(ci, 0);
    annotate_nonnull_noundef(ci, 1);
    var len = get_string_length(src, 8);
    if len != 0 { annotate_dereferenceable_bytes(ci, 1, len); } else { return -1; }
    len--;
    if len == 0 { return dst; }
    return copy_flags(ci, emit_strlen_memcpy(src, dst, len));
}
// optimizeStrNCat(CI, B)
fn optimize_strncat(ci: i32) -> i32 {
    let dst = cb_arg(ci, 0);
    let src = cb_arg(ci, 1);
    let size = cb_arg(ci, 2);
    annotate_nonnull_noundef(ci, 0);
    if known_non_zero_dl(size) { annotate_nonnull_noundef(ci, 1); }
    if !is_cint_scalar(size) { return -1; }
    let len = cint_zext(size);
    if len == 0 { return dst; }
    var srclen = get_string_length(src, 8);
    if srclen != 0 { annotate_dereferenceable_bytes(ci, 1, srclen); srclen--; } else { return -1; }
    if srclen == 0 { return dst; }
    if len < srclen { return -1; }
    return copy_flags(ci, emit_strlen_memcpy(src, dst, srclen));
}
// optimizeStrNDup(CI, B)
fn optimize_strndup(ci: i32) -> i32 {
    let src = cb_arg(ci, 0);
    let size = cb_arg(ci, 1);
    let srclen = get_string_length(src, 8);
    if srclen != 0 && is_cint_scalar(size) {
        annotate_dereferenceable_bytes(ci, 0, srclen);
        if srclen <= cint_zext(size) + 1 { return copy_flags(ci, emit_strdup(src)); }
    }
    return -1;
}
// optimizeStrCpy(CI, B)
fn optimize_strcpy(ci: i32) -> i32 {
    let dst = cb_arg(ci, 0);
    let src = cb_arg(ci, 1);
    if dst == src { return src; }
    annotate_nonnull_noundef(ci, 0);
    annotate_nonnull_noundef(ci, 1);
    let len = get_string_length(src, 8);
    if len != 0 { annotate_dereferenceable_bytes(ci, 1, len); } else { return -1; }
    let nc = lcs_memcpy_like(IID_memcpy, dst, src, tli_as_size_t(len));
    merge_attributes_and_flags(nc, ci);
    return dst;
}
// optimizeStpCpy(CI, B)
fn optimize_stpcpy(ci: i32) -> i32 {
    let dst = cb_arg(ci, 0);
    let src = cb_arg(ci, 1);
    if use_empty(ci) { return copy_flags(ci, emit_strcpy(dst, src)); }
    if dst == src {
        let sl = emit_strlen(src);
        return if sl >= 0 { icb_inbounds_gep_i8(dst, sl, "") } else { -1 };
    }
    let len = get_string_length(src, 8);
    if len != 0 { annotate_dereferenceable_bytes(ci, 1, len); } else { return -1; }
    let lenv = tli_as_size_t(len);
    let dend = icb_inbounds_gep_i8(dst, tli_as_size_t(len - 1), "");
    let nc = lcs_memcpy_like(IID_memcpy, dst, src, lenv);
    merge_attributes_and_flags(nc, ci);
    return dend;
}
// optimizeStrLCpy(CI, B)
fn optimize_strlcpy(ci: i32) -> i32 {
    let size = cb_arg(ci, 2);
    if known_non_zero_dl(size) { annotate_nonnull_noundef(ci, 0); }
    annotate_nonnull_noundef(ci, 1);
    if !is_cint_scalar(size) { return -1; }
    var nbytes = cint_zext(size);
    let dst = cb_arg(ci, 0);
    let src = cb_arg(ci, 1);
    if nbytes <= 1 {
        if nbytes == 1 { icb_store(c_int(T_I8, 0), dst); }
        return copy_flags(ci, emit_strlen(src));
    }
    if !get_constant_string_info(src, false) { return -1; }
    let slen = lcs_str.len as u64;
    var srclen: u64 = 0xFFFFFFFFFFFFFFFF;   // Str.find('\0') (npos when there is none)
    for c, i in lcs_str { if c == 0 { srclen = i as u64; break; } }
    let nul_term = srclen < nbytes;
    if nul_term { nbytes = srclen + 1; }
    else {
        srclen = min(srclen, slen);
        nbytes = min(nbytes - 1, srclen);
    }
    if srclen == 0 {
        icb_store(c_int(T_I8, 0), dst);
        return c_int_ty(vals[ci].ty, 0);
    }
    let nc = lcs_memcpy_like(IID_memcpy, dst, src, tli_as_size_t(nbytes));
    merge_attributes_and_flags(nc, ci);
    if !nul_term {
        let endoff = c_int_ty(vals[ci].ty, nbytes);
        let endptr = icb_inbounds_gep_i8(dst, endoff, "");
        icb_store(c_int(T_I8, 0), endptr);
    }
    return c_int_ty(vals[ci].ty, srclen);
}
// optimizeStringNCpy(CI, RetEnd, B)
fn optimize_string_ncpy(ci: i32, ret_end: bool) -> i32 {
    let dst = cb_arg(ci, 0);
    var src = cb_arg(ci, 1);
    let size = cb_arg(ci, 2);
    if known_non_zero_dl(size) { annotate_nonnull_noundef(ci, 0); annotate_nonnull_noundef(ci, 1); }
    var n: u64 = 0xFFFFFFFFFFFFFFFF;
    if is_cint_scalar(size) { n = cint_zext(size); }
    if n == 0 { return dst; }
    if n == 1 {
        let cv = icb_load(T_I8, src, "stxncpy.char0");
        icb_store(cv, dst);
        if !ret_end { return dst; }
        let cmp = icb_icmp(P_EQ, cv, c_int(T_I8, 0), "stpncpy.char0cmp");
        let endp = icb_inbounds_gep_i8(dst, c_int(T_I32, 1), "stpncpy.end");
        return icb_select(cmp, dst, endp, "stpncpy.sel", -1);
    }
    var srclen = get_string_length(src, 8);
    if srclen != 0 { annotate_dereferenceable_bytes(ci, 1, srclen); } else { return -1; }
    srclen--;
    if srclen == 0 {
        let pa = cs_aset(ci, 0);
        var al = aset_int(pa, AK_Alignment);
        if al == 0 { al = 1; }
        let nc = icb_memset(dst, c_int(T_I8, 0), size, al as i64);
        // NewCI->setAttributes(addParamAttributes(0, CI's param 0 attributes))
        var merged = cs_aset(nc, 0);
        for k in aset_n(pa) { merged = aset_with_replace(merged, aset_attr(pa, k)); }
        cs_set_param(nc, 0, merged);
        copy_flags(ci, nc);
        return dst;
    }
    if n > srclen + 1 {
        if n > 128 { return -1; }
        if !get_constant_string_info(src, true) { return -1; }
        var ss: u8[>..<] = [];
        lcs_str_copy(ss);
        while (ss.len as u64) < n { ss.push(0); }
        src = lcs_create_global_string_raw(ss, "str");
    }
    let nc = lcs_memcpy_like(IID_memcpy, dst, src, tli_as_size_t(n));
    merge_attributes_and_flags(nc, ci);
    if !ret_end { return dst; }
    let off = c_int(T_I64, min(srclen, n) as i64);
    return icb_inbounds_gep_i8(dst, off, "endptr");
}
// AttrBuilder::addAttribute of an existing kind replaces it (addParamAttributes merges the builder in)
fn aset_with_replace(s: i32, a: i32) -> i32 {
    if attrs[a].kind == 0 { return aset_with(s, a); }
    return aset_with(aset_without(s, attrs[a].kind as i64), a);
}
// CreateGlobalString(Str, Name, AS 0, M, AddNull = false)
fn lcs_create_global_string_raw(bytes: const u8[:], name: const u8[:]) -> i32 {
    var els: i32[>..<] = [];
    var allz = true;
    for b in bytes { els.push(c_int(T_I8, b as i64)); if b != 0 { allz = false; } }
    let aty = ty_array(T_I8, els.len);
    let init = if allz { c_null(aty) } else { c_aggregate(aty, els) };
    return module_new_private_string(init, name);
}

// optimizeStrPBrk(CI, B)
fn optimize_strpbrk(ci: i32) -> i32 {
    let h1 = get_constant_string_info(cb_arg(ci, 0), true);
    var s1: u8[>..<] = [];
    lcs_str_copy(s1);
    let h2 = get_constant_string_info(cb_arg(ci, 1), true);
    var s2: u8[>..<] = [];
    lcs_str_copy(s2);
    if (h1 && s1.len == 0) || (h2 && s2.len == 0) { return c_null(vals[ci].ty); }
    if h1 && h2 {
        let i = find_first_of(s1, s2);
        if i < 0 { return c_null(vals[ci].ty); }
        return icb_inbounds_gep_i8(cb_arg(ci, 0), c_int(T_I64, i), "strpbrk");
    }
    if h2 && s2.len == 1 { return copy_flags(ci, emit_strchr(cb_arg(ci, 0), s2[0])); }
    return -1;
}
// optimizeStrSpn(CI, B)
fn optimize_strspn(ci: i32) -> i32 {
    let h1 = get_constant_string_info(cb_arg(ci, 0), true);
    var s1: u8[>..<] = [];
    lcs_str_copy(s1);
    let h2 = get_constant_string_info(cb_arg(ci, 1), true);
    var s2: u8[>..<] = [];
    lcs_str_copy(s2);
    if (h1 && s1.len == 0) || (h2 && s2.len == 0) { return c_null(vals[ci].ty); }
    if h1 && h2 {
        var pos = find_first_not_of(s1, s2);
        if pos < 0 { pos = s1.len; }
        return c_int_ty(vals[ci].ty, pos as u64);
    }
    return -1;
}
// optimizeStrCSpn(CI, B)
fn optimize_strcspn(ci: i32) -> i32 {
    let h1 = get_constant_string_info(cb_arg(ci, 0), true);
    var s1: u8[>..<] = [];
    lcs_str_copy(s1);
    let h2 = get_constant_string_info(cb_arg(ci, 1), true);
    var s2: u8[>..<] = [];
    lcs_str_copy(s2);
    if h1 && s1.len == 0 { return c_null(vals[ci].ty); }
    if h1 && h2 {
        var pos = find_first_of(s1, s2);
        if pos < 0 { pos = s1.len; }
        return c_int_ty(vals[ci].ty, pos as u64);
    }
    if h2 && s2.len == 0 { return copy_flags(ci, emit_strlen(cb_arg(ci, 0))); }
    return -1;
}
// optimizeStrStr(CI, B)
fn optimize_strstr(ci: i32) -> i32 {
    let a0 = cb_arg(ci, 0);
    let a1 = cb_arg(ci, 1);
    if a0 == a1 { return a0; }
    if is_only_used_in_equality_comparison(ci, a0) {
        let sl = emit_strlen(a1);
        if sl < 0 { return -1; }
        let sn = emit_strncmp(a0, a1, sl);
        if sn < 0 { return -1; }
        var us: i32[>..<] = [];
        var u = vals[ci].first_use;
        while u >= 0 { us.push(uses[u].user); u = uses[u].next; }
        for old in us {
            let cmp = icb_icmp(inst_pred(old) as i64, sn, c_null(vals[sn].ty), "cmp");
            ic_replace_inst_uses_with(old, cmp);
        }
        return ci;
    }
    let h1 = get_constant_string_info(a0, true);
    var s1: u8[>..<] = [];
    lcs_str_copy(s1);
    let h2 = get_constant_string_info(a1, true);
    var s2: u8[>..<] = [];
    lcs_str_copy(s2);
    if h2 && s2.len == 0 { return a0; }
    if h1 && h2 {
        let off = find_sub(s1, s2);
        if off < 0 { return c_null(vals[ci].ty); }
        return icb_inbounds_gep_i8(a0, c_int(T_I64, off), "strstr");
    }
    if h2 && s2.len == 1 { return emit_strchr(a0, s2[0]); }
    annotate_nonnull_noundef(ci, 0);
    annotate_nonnull_noundef(ci, 1);
    return -1;
}

// optimizeMemCCpy(CI, B)
fn optimize_memccpy(ci: i32) -> i32 {
    let dst = cb_arg(ci, 0);
    let src = cb_arg(ci, 1);
    let stop = cb_arg(ci, 2);
    let nv = cb_arg(ci, 3);
    if use_empty(ci) && dst == src { return dst; }
    if !is_cint_scalar(nv) { return -1; }
    if ap_is_zero(ci_ap(nv)) { return c_null(vals[ci].ty); }
    if !get_constant_string_info(src, false) || !is_cint_scalar(stop) { return -1; }
    var ss: u8[>..<] = [];
    lcs_str_copy(ss);
    let ch = (ap_sext64(ci_ap(stop)) & 0xFF) as u8;
    var pos: i64 = -1;
    for c, i in ss { if c == ch { pos = i; break; } }
    let n = cint_zext(nv);
    if pos < 0 {
        if n <= ss.len as u64 {
            copy_flags(ci, lcs_memcpy_like(IID_memcpy, dst, src, nv));
            return c_null(vals[ci].ty);
        }
        return -1;
    }
    let newn = c_int_ty(vals[nv].ty, min((pos + 1) as u64, n));
    copy_flags(ci, lcs_memcpy_like(IID_memcpy, dst, src, newn));
    return if (pos + 1) as u64 <= n { icb_inbounds_gep_i8(dst, newn, "") } else { c_null(vals[ci].ty) };
}
// optimizeMemPCpy(CI, B)
fn optimize_mempcpy(ci: i32) -> i32 {
    let dst = cb_arg(ci, 0);
    let n = cb_arg(ci, 2);
    let nc = lcs_memcpy_like(IID_memcpy, dst, cb_arg(ci, 1), n);
    merge_attributes_and_flags(nc, ci);
    return icb_inbounds_gep_i8(dst, n, "");
}
// optimizeRealloc(CI, B)
fn optimize_realloc(ci: i32) -> i32 {
    if vals[cb_arg(ci, 0)].kind == VK_CNULL { return copy_flags(ci, emit_malloc(cb_arg(ci, 1))); }
    return -1;
}
// optimizeBCopy(CI, B)
fn optimize_bcopy(ci: i32) -> i32 {
    return copy_flags(ci, lcs_memcpy_like(IID_memmove, cb_arg(ci, 1), cb_arg(ci, 0), cb_arg(ci, 2)));
}

// ---------------------------------------------------------------------------------------------
// operator new hot/cold hints (-optimize-hot-cold-new and friends)

fn lcs_hint_flag(name: const u8[:], dflt: i64) -> i64 {
    if !flag_given(name) { return dflt; }
    let v, ok = parse_int(flag_str(name));
    if !ok || v < 0 || v > 255 { fatal(str("opt: invalid value for -", name)); }
    return v;
}
fn lf_is_new_without_hint(lf: i64) -> bool {
    lf == LF_Znwm || lf == LF_ZnwmRKSt9nothrow_t || lf == LF_ZnwmSt11align_val_t ||
        lf == LF_ZnwmSt11align_val_tRKSt9nothrow_t || lf == LF_Znam || lf == LF_ZnamRKSt9nothrow_t ||
        lf == LF_ZnamSt11align_val_t || lf == LF_ZnamSt11align_val_tRKSt9nothrow_t || lf == LF_size_returning_new ||
        lf == LF_size_returning_new_aligned
}
fn lf_is_new_with_hint(lf: i64) -> bool {
    lf == LF_Znwm12__hot_cold_t || lf == LF_ZnwmRKSt9nothrow_t12__hot_cold_t ||
        lf == LF_ZnwmSt11align_val_t12__hot_cold_t || lf == LF_ZnwmSt11align_val_tRKSt9nothrow_t12__hot_cold_t ||
        lf == LF_Znam12__hot_cold_t || lf == LF_ZnamRKSt9nothrow_t12__hot_cold_t ||
        lf == LF_ZnamSt11align_val_t12__hot_cold_t || lf == LF_ZnamSt11align_val_tRKSt9nothrow_t12__hot_cold_t ||
        lf == LF_size_returning_new_hot_cold || lf == LF_size_returning_new_aligned_hot_cold
}
// maybeOptimizeNoBuiltinOperatorNew(CI, B)
fn maybe_optimize_nobuiltin_operator_new(ci: i32) -> i32 {
    if !flag_bool("optimize-hot-cold-new", false) { return -1; }
    let callee = called_function(ci);
    if callee < 0 { return -1; }
    let lf = tli_get_libfunc(callee) as i64;
    if lf < 0 { return -1; }
    if lf_is_new_without_hint(lf) {
        if !flag_bool("optimize-nobuiltin-hot-cold-new-new", false) { return -1; }
    } else if lf_is_new_with_hint(lf) {
        if !flag_bool("optimize-existing-hot-cold-new", false) { return -1; }
    } else { return -1; }
    return optimize_new(ci, lf);
}
// optimizeNew(CI, B, Func)
fn optimize_new(ci: i32, lf: i64) -> i32 {
    if !flag_bool("optimize-hot-cold-new", false) { return -1; }
    // CI->getAttributes().getFnAttr("memprof"): the call site's attribute only
    let mpa = aset_find_str(alist_fn(insts[inst_of(ci)].attrs), "memprof");
    let mp: const u8[:] = if mpa >= 0 { sbytes(attrs[mpa].sval) } else { "" };
    var hc: i64 = 0;
    if mp == "cold" { hc = lcs_hint_flag("cold-new-hint-value", 1); }
    else if mp == "notcold" { hc = lcs_hint_flag("notcold-new-hint-value", 128); }
    else if mp == "hot" { hc = lcs_hint_flag("hot-new-hint-value", 254); }
    else if mp == "ambiguous" { hc = lcs_hint_flag("ambiguous-new-hint-value", 222); }
    else { return -1; }
    let existing = flag_bool("optimize-existing-hot-cold-new", false);
    let h = c_int(T_I8, hc);
    let pt = lcs_ptr();
    var nc: i32 = -1;
    if lf == LF_Znwm12__hot_cold_t { if existing { nc = emit_hot_cold_new(LF_Znwm12__hot_cold_t, pt, [cb_arg(ci, 0), h], false); } }
    else if lf == LF_Znwm { nc = emit_hot_cold_new(LF_Znwm12__hot_cold_t, pt, [cb_arg(ci, 0), h], false); }
    else if lf == LF_Znam12__hot_cold_t { if existing { nc = emit_hot_cold_new(LF_Znam12__hot_cold_t, pt, [cb_arg(ci, 0), h], false); } }
    else if lf == LF_Znam { nc = emit_hot_cold_new(LF_Znam12__hot_cold_t, pt, [cb_arg(ci, 0), h], false); }
    else if lf == LF_ZnwmRKSt9nothrow_t12__hot_cold_t || lf == LF_ZnwmRKSt9nothrow_t {
        if lf == LF_ZnwmRKSt9nothrow_t || existing {
            let t = LF_ZnwmRKSt9nothrow_t12__hot_cold_t;
            nc = emit_hot_cold_new(t, pt, [cb_arg(ci, 0), cb_arg(ci, 1), h], false);
        }
    }
    else if lf == LF_ZnamRKSt9nothrow_t12__hot_cold_t || lf == LF_ZnamRKSt9nothrow_t {
        if lf == LF_ZnamRKSt9nothrow_t || existing {
            let t = LF_ZnamRKSt9nothrow_t12__hot_cold_t;
            nc = emit_hot_cold_new(t, pt, [cb_arg(ci, 0), cb_arg(ci, 1), h], false);
        }
    }
    else if lf == LF_ZnwmSt11align_val_t12__hot_cold_t || lf == LF_ZnwmSt11align_val_t {
        if lf == LF_ZnwmSt11align_val_t || existing {
            let t = LF_ZnwmSt11align_val_t12__hot_cold_t;
            nc = emit_hot_cold_new(t, pt, [cb_arg(ci, 0), cb_arg(ci, 1), h], false);
        }
    }
    else if lf == LF_ZnamSt11align_val_t12__hot_cold_t || lf == LF_ZnamSt11align_val_t {
        if lf == LF_ZnamSt11align_val_t || existing {
            let t = LF_ZnamSt11align_val_t12__hot_cold_t;
            nc = emit_hot_cold_new(t, pt, [cb_arg(ci, 0), cb_arg(ci, 1), h], false);
        }
    }
    else if lf == LF_ZnwmSt11align_val_tRKSt9nothrow_t12__hot_cold_t || lf == LF_ZnwmSt11align_val_tRKSt9nothrow_t {
        if lf == LF_ZnwmSt11align_val_tRKSt9nothrow_t || existing {
            let t = LF_ZnwmSt11align_val_tRKSt9nothrow_t12__hot_cold_t;
            nc = emit_hot_cold_new(t, pt, [cb_arg(ci, 0), cb_arg(ci, 1), cb_arg(ci, 2), h], false);
        }
    }
    else if lf == LF_ZnamSt11align_val_tRKSt9nothrow_t12__hot_cold_t || lf == LF_ZnamSt11align_val_tRKSt9nothrow_t {
        if lf == LF_ZnamSt11align_val_tRKSt9nothrow_t || existing {
            let t = LF_ZnamSt11align_val_tRKSt9nothrow_t12__hot_cold_t;
            nc = emit_hot_cold_new(t, pt, [cb_arg(ci, 0), cb_arg(ci, 1), cb_arg(ci, 2), h], false);
        }
    }
    else if lf == LF_size_returning_new || lf == LF_size_returning_new_hot_cold {
        if lf == LF_size_returning_new || existing {
            let a0 = cb_arg(ci, 0);
            let rt = ty_struct_of([pt, vals[a0].ty as i32]);
            nc = emit_hot_cold_new(LF_size_returning_new_hot_cold, rt, [a0, h], true);
        }
    }
    else if lf == LF_size_returning_new_aligned || lf == LF_size_returning_new_aligned_hot_cold {
        if lf == LF_size_returning_new_aligned || existing {
            let a0 = cb_arg(ci, 0);
            let rt = ty_struct_of([pt, vals[a0].ty as i32]);
            nc = emit_hot_cold_new(LF_size_returning_new_aligned_hot_cold, rt, [a0, cb_arg(ci, 1), h], true);
        }
    }
    else { return -1; }
    if nc >= 0 && is_inst(nc) { ph_copy_metadata(nc, ci); }
    return nc;
}

// ---------------------------------------------------------------------------------------------
// stdio

// isReportingError(Callee, CI, StreamArg)
fn is_reporting_error(callee: i32, ci: i32, stream: i64) -> bool {
    if callee < 0 || !func_is_decl(callee) { return false; }
    if stream < 0 { return true; }
    if stream >= cb_nargs(ci) { return false; }
    let li = cb_arg(ci, stream);
    if !is_inst_op(li, OP_LOAD) { return false; }
    let gv = op(li, 0);
    if vals[gv].kind != VK_GVAR || !glob_is_declaration(gv) { return false; }
    return val_name(gv) == "stderr";
}
fn glob_is_declaration(gv: i32) -> bool { nops(gv) == 0 || op(gv, 0) < 0 }
// optimizeErrorReporting(CI, B, StreamArg)
fn optimize_error_reporting(ci: i32, stream: i64) -> i32 {
    if !call_has_fn_attr(ci, AK_Cold) && is_reporting_error(called_function(ci), ci, stream) {
        call_add_fn_attr(ci, attr_enum(AK_Cold));
    }
    return -1;
}
fn call_add_fn_attr(ci: i32, a: i32) {
    let ii = inst_of(ci);
    let l = insts[ii].attrs;
    let n = if l == 0 { 0 } else { alists[l].n as i64 };
    var sets: i32[>..<] = [];
    for j in 0..max(n, 1) {
        var s: i32 = 0;
        if j < n { s = alist_runs[alists[l].at + j]; }
        if j == 0 { s = aset_with(s, a); }
        sets.push(s);
    }
    insts[ii].attrs = alist_get(sets);
}

// callHasFloatingPointArgument / callHasFP128Argument
fn call_has_fp_argument(ci: i32) -> bool {
    for k in cb_nargs(ci) { if ty_is_fp(vals[cb_arg(ci, k)].ty) { return true; } }
    return false;
}
fn call_has_fp128_argument(ci: i32) -> bool {
    for k in cb_nargs(ci) { if ty_kind(vals[cb_arg(ci, k)].ty) == TK_FP128 { return true; } }
    return false;
}
// printf -> iprintf / __small_printf (and the sprintf/fprintf variants): a clone of the call to the new callee
fn lcs_retarget_printf(ci: i32, lf: i64) -> i32 {
    let callee = called_function(ci);
    let ft = globs[glob_of(callee)].vty;
    let f = blc_get_or_insert(lf, ft, globs[glob_of(callee)].attrs);
    let nc = inst_clone(ci);
    icx_set_called_function(nc, f);
    return icb_insert(nc, "");
}
fn lcs_printf_variants(ci: i32, ilf: i64, slf: i64) -> i32 {
    if blc_is_emittable(ilf) && !call_has_fp_argument(ci) { return lcs_retarget_printf(ci, ilf); }
    if blc_is_emittable(slf) && !call_has_fp128_argument(ci) { return lcs_retarget_printf(ci, slf); }
    return -1;
}

// optimizeSPrintFString(CI, B)
fn optimize_sprintf_string(ci: i32) -> i32 {
    if !get_constant_string_info(cb_arg(ci, 1), true) { return -1; }
    var fs: u8[>..<] = [];
    lcs_str_copy(fs);
    let dest = cb_arg(ci, 0);
    let rty = vals[ci].ty;
    if cb_nargs(ci) == 2 {
        if bytes_contains(fs, '%') { return -1; }
        lcs_memcpy_like(IID_memcpy, dest, cb_arg(ci, 1), tli_as_size_t((fs.len + 1) as u64));
        return c_int_ty(rty, fs.len as u64);
    }
    if fs.len != 2 || fs[0] != '%' || cb_nargs(ci) < 3 { return -1; }
    if fs[1] == 'c' {
        if !ty_is_int(vals[cb_arg(ci, 2)].ty) { return -1; }
        let v = icb_trunc(cb_arg(ci, 2), T_I8, "char");
        icb_store(v, dest);
        let p = icb_inbounds_gep_i8(dest, c_int(T_I32, 1), "nul");
        icb_store(c_int(T_I8, 0), p);
        return c_int_ty(rty, 1);
    }
    if fs[1] == 's' {
        let s = cb_arg(ci, 2);
        if ty_kind(vals[s].ty) != TK_PTR { return -1; }
        if use_empty(ci) { return copy_flags(ci, emit_strcpy(dest, s)); }
        let srclen = get_string_length(s, 8);
        if srclen != 0 {
            lcs_memcpy_like(IID_memcpy, dest, s, tli_as_size_t(srclen));
            return c_int_ty(rty, srclen - 1);
        }
        let v = emit_stpcpy(dest, s);
        if v >= 0 {
            let pd = icb_ptr_diff(v, dest);
            return icb_int_cast(pd, rty, false, "");
        }
        if lcs_opt_for_size(ci) { return -1; }
        let len = emit_strlen(s);
        if len < 0 { return -1; }
        let inc = icb_add(len, c_int_ty(vals[len].ty, 1), "leninc");
        lcs_memcpy_like(IID_memcpy, dest, s, inc);
        return icb_int_cast(len, rty, false, "");
    }
    return -1;
}
// optimizeSPrintF(CI, B)
fn optimize_sprintf(ci: i32) -> i32 {
    let v = optimize_sprintf_string(ci);
    if v >= 0 { return v; }
    annotate_nonnull_noundef(ci, 0);
    annotate_nonnull_noundef(ci, 1);
    return lcs_printf_variants(ci, LF_siprintf, LF_small_sprintf);
}
// emitSnPrintfMemCpy(CI, StrArg, Str, N, B)
fn emit_snprintf_memcpy(ci: i32, strarg: i32, slen: u64, n: u64) -> i32 {
    let ib = tli_int_bits();
    let imax: u64 = (1 << (ib - 1)) - 1;   // maxIntN(IntBits)
    if slen > imax { return -1; }
    let sl = c_int_ty(vals[ci].ty, slen);
    if n == 0 { return sl; }
    let ncopy = if n > slen { slen + 1 } else { n - 1 };
    let dst = cb_arg(ci, 0);
    if ncopy != 0 && strarg >= 0 { copy_flags(ci, lcs_memcpy_like(IID_memcpy, dst, strarg, tli_as_size_t(ncopy))); }
    if n > slen { return sl; }
    let nuloff = c_int_ty(ty_int(ib), ncopy);
    let dend = icb_inbounds_gep_i8(dst, nuloff, "endptr");
    icb_store(c_int(T_I8, 0), dend);
    return sl;
}
// optimizeSnPrintFString(CI, B)
fn optimize_snprintf_string(ci: i32) -> i32 {
    let size = cb_arg(ci, 1);
    if !is_cint_scalar(size) { return -1; }
    let n = cint_zext(size);
    let ib = tli_int_bits();
    let imax: u64 = (1 << (ib - 1)) - 1;
    if n > imax { return -1; }
    let dst = cb_arg(ci, 0);
    let fmt = cb_arg(ci, 2);
    if !get_constant_string_info(fmt, true) { return -1; }
    var fs: u8[>..<] = [];
    lcs_str_copy(fs);
    if cb_nargs(ci) == 3 {
        if bytes_contains(fs, '%') { return -1; }
        return emit_snprintf_memcpy(ci, fmt, fs.len as u64, n);
    }
    if fs.len != 2 || fs[0] != '%' || cb_nargs(ci) != 4 { return -1; }
    if fs[1] == 'c' {
        if n <= 1 { return emit_snprintf_memcpy(ci, -1, 1, n); }
        if !ty_is_int(vals[cb_arg(ci, 3)].ty) { return -1; }
        let v = icb_trunc(cb_arg(ci, 3), T_I8, "char");
        icb_store(v, dst);
        let p = icb_inbounds_gep_i8(dst, c_int(T_I32, 1), "nul");
        icb_store(c_int(T_I8, 0), p);
        return c_int_ty(vals[ci].ty, 1);
    }
    if fs[1] != 's' { return -1; }
    let sa = cb_arg(ci, 3);
    if !get_constant_string_info(sa, true) { return -1; }
    return emit_snprintf_memcpy(ci, sa, lcs_str.len as u64, n);
}
// optimizeSnPrintF(CI, B)
fn optimize_snprintf(ci: i32) -> i32 {
    let v = optimize_snprintf_string(ci);
    if v >= 0 { return v; }
    if known_non_zero_dl(op(ci, 1)) { annotate_nonnull_noundef(ci, 0); }
    return -1;
}
// optimizeFPrintFString(CI, B)
fn optimize_fprintf_string(ci: i32) -> i32 {
    optimize_error_reporting(ci, 0);
    if !get_constant_string_info(cb_arg(ci, 1), true) { return -1; }
    var fs: u8[>..<] = [];
    lcs_str_copy(fs);
    if !use_empty(ci) { return -1; }
    if cb_nargs(ci) == 2 {
        if bytes_contains(fs, '%') { return -1; }
        return copy_flags(ci, emit_fwrite(cb_arg(ci, 1), tli_as_size_t(fs.len as u64), cb_arg(ci, 0)));
    }
    if fs.len != 2 || fs[0] != '%' || cb_nargs(ci) < 3 { return -1; }
    if fs[1] == 'c' {
        if !ty_is_int(vals[cb_arg(ci, 2)].ty) { return -1; }
        let v = icb_int_cast(cb_arg(ci, 2), ty_int(tli_int_bits()), true, "chari");
        return copy_flags(ci, emit_fputc(v, cb_arg(ci, 0)));
    }
    if fs[1] == 's' {
        if ty_kind(vals[cb_arg(ci, 2)].ty) != TK_PTR { return -1; }
        return copy_flags(ci, emit_fputs(cb_arg(ci, 2), cb_arg(ci, 0)));
    }
    return -1;
}
// optimizeFPrintF(CI, B)
fn optimize_fprintf(ci: i32) -> i32 {
    let v = optimize_fprintf_string(ci);
    if v >= 0 { return v; }
    return lcs_printf_variants(ci, LF_fiprintf, LF_small_fprintf);
}
// optimizeFWrite(CI, B)
fn optimize_fwrite(ci: i32) -> i32 {
    optimize_error_reporting(ci, 3);
    let sz = cb_arg(ci, 1);
    let cnt = cb_arg(ci, 2);
    if is_cint_scalar(sz) && is_cint_scalar(cnt) {
        let bytes = cint_zext(sz) * cint_zext(cnt);
        if bytes == 0 { return c_int_ty(vals[ci].ty, 0); }
        if bytes == 1 && use_empty(ci) {
            let ch = icb_load(T_I8, cb_arg(ci, 0), "char");
            let cst = icb_int_cast(ch, ty_int(tli_int_bits()), true, "chari");
            let nc = emit_fputc(cst, cb_arg(ci, 3));
            return if nc >= 0 { c_int_ty(vals[ci].ty, 1) } else { -1 };
        }
    }
    return -1;
}
// optimizeFPuts(CI, B)
fn optimize_fputs(ci: i32) -> i32 {
    optimize_error_reporting(ci, 1);
    if lcs_opt_for_size(ci) { return -1; }
    if !use_empty(ci) { return -1; }
    let len = get_string_length(cb_arg(ci, 0), 8);
    if len == 0 { return -1; }
    return copy_flags(ci, emit_fwrite(cb_arg(ci, 0), c_int_ty(tli_sizet_ty(), len - 1), cb_arg(ci, 1)));
}

// ---------------------------------------------------------------------------------------------
// FortifiedLibCallSimplifier (OnlyLowerUnknownSize = false: InstCombine's)

// isFortifiedCallFoldable(CI, ObjSizeOp, SizeOp, StrOp, FlagOp); -1 = std::nullopt
fn is_fortified_call_foldable(ci: i32, objop: i64, sizeop: i64, strop: i64, flagop: i64) -> bool {
    if flagop >= 0 {
        let f = cb_arg(ci, flagop);
        if !is_cint_scalar(f) || !ap_is_zero(ci_ap(f)) { return false; }
    }
    if sizeop >= 0 && cb_arg(ci, objop) == cb_arg(ci, sizeop) { return true; }
    let os = cb_arg(ci, objop);
    if is_cint_scalar(os) {
        if ap_is_all_ones(ci_ap(os)) { return true; }
        if strop >= 0 {
            let len = get_string_length(cb_arg(ci, strop), 8);
            if len != 0 { annotate_dereferenceable_bytes(ci, strop, len); } else { return false; }
            return cint_zext(os) >= len;
        }
        if sizeop >= 0 {
            let s = cb_arg(ci, sizeop);
            if is_cint_scalar(s) { return cint_zext(os) >= cint_zext(s); }
        }
    }
    return false;
}

// FortifiedLibCallSimplifier::optimizeCall(CI, B): -1 when the callee is no fortified function either
fn fortified_optimize_call(ci: i32, lf: i64, is_ccc: bool) -> i32 {
    if !ignore_calling_conv(lf) && !is_ccc { return -1; }
    let a0 = if cb_nargs(ci) > 0 { cb_arg(ci, 0) } else { -1 };
    if lf == LF_memcpy_chk || lf == LF_memmove_chk {
        if is_fortified_call_foldable(ci, 3, 2, -1, -1) {
            let nc = lcs_memcpy_like(if lf == LF_memcpy_chk { IID_memcpy } else { IID_memmove }, a0, cb_arg(ci, 1), cb_arg(ci, 2));
            merge_attributes_and_flags(nc, ci);
            return a0;
        }
        return -1;
    }
    if lf == LF_mempcpy_chk {
        if is_fortified_call_foldable(ci, 3, 2, -1, -1) {
            let c = emit_mempcpy(a0, cb_arg(ci, 1), cb_arg(ci, 2));
            if c >= 0 { return merge_attributes_and_flags(c, ci); }
        }
        return -1;
    }
    if lf == LF_memset_chk {
        if is_fortified_call_foldable(ci, 3, 2, -1, -1) {
            let v = icb_int_cast(cb_arg(ci, 1), T_I8, false, "");
            let nc = icb_memset(a0, v, cb_arg(ci, 2), 1);
            merge_attributes_and_flags(nc, ci);
            return a0;
        }
        return -1;
    }
    if lf == LF_stpcpy_chk || lf == LF_strcpy_chk {
        let dst = a0;
        let src = cb_arg(ci, 1);
        let osz = cb_arg(ci, 2);
        if lf == LF_stpcpy_chk && dst == src {
            let sl = emit_strlen(src);
            return if sl >= 0 { icb_inbounds_gep_i8(dst, sl, "") } else { -1 };
        }
        if is_fortified_call_foldable(ci, 2, -1, 1, -1) {
            if lf == LF_strcpy_chk { return copy_flags(ci, emit_strcpy(dst, src)); }
            return copy_flags(ci, emit_stpcpy(dst, src));
        }
        let len = get_string_length(src, 8);
        if len != 0 { annotate_dereferenceable_bytes(ci, 1, len); } else { return -1; }
        let st = tli_sizet_ty();
        let r = emit_memcpy_chk(dst, src, c_int_ty(st, len), osz);
        if r >= 0 && lf == LF_stpcpy_chk { return icb_inbounds_gep_i8(dst, c_int_ty(st, len - 1), ""); }
        if r < 0 { fatal("FortifiedLibCallSimplifier: __memcpy_chk is not emittable (LLVM would crash in cast<CallInst>)"); }
        return copy_flags(ci, r);
    }
    if lf == LF_strlen_chk {
        if is_fortified_call_foldable(ci, 1, -1, 0, -1) { return copy_flags(ci, emit_strlen(a0)); }
        return -1;
    }
    if lf == LF_stpncpy_chk || lf == LF_strncpy_chk {
        if is_fortified_call_foldable(ci, 3, 2, -1, -1) {
            if lf == LF_strncpy_chk { return copy_flags(ci, emit_strncpy(a0, cb_arg(ci, 1), cb_arg(ci, 2))); }
            return copy_flags(ci, emit_stpncpy(a0, cb_arg(ci, 1), cb_arg(ci, 2)));
        }
        return -1;
    }
    if lf == LF_memccpy_chk {
        if is_fortified_call_foldable(ci, 4, 3, -1, -1) {
            return copy_flags(ci, emit_memccpy(a0, cb_arg(ci, 1), cb_arg(ci, 2), cb_arg(ci, 3)));
        }
        return -1;
    }
    if lf == LF_snprintf_chk {
        if is_fortified_call_foldable(ci, 3, 1, -1, 2) {
            var va: i32[>..<] = [];
            for k in 5..cb_nargs(ci) { va.push(cb_arg(ci, k)); }
            return copy_flags(ci, emit_snprintf(a0, cb_arg(ci, 1), cb_arg(ci, 4), va));
        }
        return -1;
    }
    if lf == LF_sprintf_chk {
        if is_fortified_call_foldable(ci, 2, -1, -1, 1) {
            var va: i32[>..<] = [];
            for k in 4..cb_nargs(ci) { va.push(cb_arg(ci, k)); }
            return copy_flags(ci, emit_sprintf(a0, cb_arg(ci, 3), va));
        }
        return -1;
    }
    if lf == LF_strcat_chk {
        if is_fortified_call_foldable(ci, 2, -1, -1, -1) { return copy_flags(ci, emit_strcat(a0, cb_arg(ci, 1))); }
        return -1;
    }
    if lf == LF_strlcat_chk {
        if is_fortified_call_foldable(ci, 3, -1, -1, -1) { return copy_flags(ci, emit_strlcat(a0, cb_arg(ci, 1), cb_arg(ci, 2))); }
        return -1;
    }
    if lf == LF_strncat_chk {
        if is_fortified_call_foldable(ci, 3, -1, -1, -1) { return copy_flags(ci, emit_strncat(a0, cb_arg(ci, 1), cb_arg(ci, 2))); }
        return -1;
    }
    if lf == LF_strlcpy_chk {
        if is_fortified_call_foldable(ci, 3, -1, -1, -1) { return copy_flags(ci, emit_strlcpy(a0, cb_arg(ci, 1), cb_arg(ci, 2))); }
        return -1;
    }
    if lf == LF_vsnprintf_chk {
        if is_fortified_call_foldable(ci, 3, 1, -1, 2) {
            return copy_flags(ci, emit_vsnprintf(a0, cb_arg(ci, 1), cb_arg(ci, 4), cb_arg(ci, 5)));
        }
        return -1;
    }
    if lf == LF_vsprintf_chk {
        if is_fortified_call_foldable(ci, 2, -1, -1, 1) {
            return copy_flags(ci, emit_vsprintf(a0, cb_arg(ci, 3), cb_arg(ci, 4)));
        }
        return -1;
    }
    return -1;
}
