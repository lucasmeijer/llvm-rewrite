// InstCombine: the X86 target hooks of TargetTransformInfo (X86TTIImpl::instCombineIntrinsic,
// simplifyDemandedUseBitsIntrinsic, simplifyDemandedVectorEltsIntrinsic) and their helpers.
// Ported from: llvm/lib/Target/X86/X86InstCombineIntrinsic.cpp (LLVM 23.1.5), in the file's order.
// The intrinsics are dispatched by name ("llvm.x86.*"); `x86_kind` maps each name the file handles to the case
// label group it belongs to.

X86_Kind :: enum u8 {
    NONE;
    BEXTR; BZHI; CVT_SCALAR; MOVMSK; COMI; AVX512_ROUND_PACKED; AVX512_MASK_ROUND_SCALAR;
    MAX_PACKED; MAX_SCALAR; MIN_PACKED; MIN_SCALAR; IMM_SHIFT; VEC_SHIFT; VAR_SHIFT;
    PACKSS; PACKUS; PMULH; PMULHU; PMULHRS; PMADDWD; PMADDUBSW; PCLMULQDQ; INSERTPS;
    EXTRQ; EXTRQI; INSERTQ; INSERTQI; BLENDV; PSHUFB; VPERMILVAR_PS; VPERMILVAR_PD; VPERMV; VPERMV3;
    MASKLOAD; MASKSTORE; ADDCARRY; PTERNLOG; VPMADD52;
}
x86_kind_table: Table(string, X86_Kind);
x86_kind_init :: () {
    add :: (k: X86_Kind, names: ..string) { for names table_set(*x86_kind_table, sprint("llvm.x86.%", it), k); }
    add(.BEXTR, "bmi.bextr.32", "bmi.bextr.64", "tbm.bextri.u32", "tbm.bextri.u64");
    add(.BZHI, "bmi.bzhi.32", "bmi.bzhi.64");
    add(.CVT_SCALAR, "sse.cvtss2si", "sse.cvtss2si64", "sse.cvttss2si", "sse.cvttss2si64", "sse2.cvtsd2si", "sse2.cvtsd2si64",
        "sse2.cvttsd2si", "sse2.cvttsd2si64", "avx512.vcvtss2si32", "avx512.vcvtss2si64", "avx512.vcvtss2usi32",
        "avx512.vcvtss2usi64", "avx512.vcvtsd2si32", "avx512.vcvtsd2si64", "avx512.vcvtsd2usi32", "avx512.vcvtsd2usi64",
        "avx512.cvttss2si", "avx512.cvttss2si64", "avx512.cvttss2usi", "avx512.cvttss2usi64", "avx512.cvttsd2si",
        "avx512.cvttsd2si64", "avx512.cvttsd2usi", "avx512.cvttsd2usi64");
    add(.MOVMSK, "mmx.pmovmskb", "sse.movmsk.ps", "sse2.movmsk.pd", "sse2.pmovmskb.128", "avx.movmsk.pd.256", "avx.movmsk.ps.256", "avx2.pmovmskb");
    add(.COMI, "sse.comieq.ss", "sse.comige.ss", "sse.comigt.ss", "sse.comile.ss", "sse.comilt.ss", "sse.comineq.ss",
        "sse.ucomieq.ss", "sse.ucomige.ss", "sse.ucomigt.ss", "sse.ucomile.ss", "sse.ucomilt.ss", "sse.ucomineq.ss",
        "sse2.comieq.sd", "sse2.comige.sd", "sse2.comigt.sd", "sse2.comile.sd", "sse2.comilt.sd", "sse2.comineq.sd",
        "sse2.ucomieq.sd", "sse2.ucomige.sd", "sse2.ucomigt.sd", "sse2.ucomile.sd", "sse2.ucomilt.sd", "sse2.ucomineq.sd",
        "avx512.vcomi.ss", "avx512.vcomi.sd", "avx512.mask.cmp.ss", "avx512.mask.cmp.sd");
    add(.AVX512_ROUND_PACKED, "avx512.add.ps.512", "avx512.div.ps.512", "avx512.mul.ps.512", "avx512.sub.ps.512",
        "avx512.add.pd.512", "avx512.div.pd.512", "avx512.mul.pd.512", "avx512.sub.pd.512");
    add(.AVX512_MASK_ROUND_SCALAR, "avx512.mask.add.ss.round", "avx512.mask.div.ss.round", "avx512.mask.mul.ss.round",
        "avx512.mask.sub.ss.round", "avx512.mask.add.sd.round", "avx512.mask.div.sd.round", "avx512.mask.mul.sd.round",
        "avx512.mask.sub.sd.round");
    add(.MAX_PACKED, "sse.max.ps", "sse2.max.pd", "avx.max.pd.256", "avx.max.ps.256", "avx512.max.pd.512", "avx512.max.ps.512",
        "avx512fp16.max.ph.128", "avx512fp16.max.ph.256", "avx512fp16.max.ph.512");
    add(.MAX_SCALAR, "sse.max.ss", "sse2.max.sd");
    add(.MIN_PACKED, "sse.min.ps", "sse2.min.pd", "avx.min.pd.256", "avx.min.ps.256", "avx512.min.pd.512", "avx512.min.ps.512",
        "avx512fp16.min.ph.128", "avx512fp16.min.ph.256", "avx512fp16.min.ph.512");
    add(.MIN_SCALAR, "sse.min.ss", "sse2.min.sd");
    add(.IMM_SHIFT, "sse2.psrai.d", "sse2.psrai.w", "avx2.psrai.d", "avx2.psrai.w", "avx512.psrai.q.128", "avx512.psrai.q.256",
        "avx512.psrai.d.512", "avx512.psrai.q.512", "avx512.psrai.w.512", "sse2.psrli.d", "sse2.psrli.q", "sse2.psrli.w",
        "avx2.psrli.d", "avx2.psrli.q", "avx2.psrli.w", "avx512.psrli.d.512", "avx512.psrli.q.512", "avx512.psrli.w.512",
        "sse2.pslli.d", "sse2.pslli.q", "sse2.pslli.w", "avx2.pslli.d", "avx2.pslli.q", "avx2.pslli.w", "avx512.pslli.d.512",
        "avx512.pslli.q.512", "avx512.pslli.w.512");
    add(.VEC_SHIFT, "sse2.psra.d", "sse2.psra.w", "avx2.psra.d", "avx2.psra.w", "avx512.psra.q.128", "avx512.psra.q.256",
        "avx512.psra.d.512", "avx512.psra.q.512", "avx512.psra.w.512", "sse2.psrl.d", "sse2.psrl.q", "sse2.psrl.w",
        "avx2.psrl.d", "avx2.psrl.q", "avx2.psrl.w", "avx512.psrl.d.512", "avx512.psrl.q.512", "avx512.psrl.w.512",
        "sse2.psll.d", "sse2.psll.q", "sse2.psll.w", "avx2.psll.d", "avx2.psll.q", "avx2.psll.w", "avx512.psll.d.512",
        "avx512.psll.q.512", "avx512.psll.w.512");
    add(.VAR_SHIFT, "avx2.psllv.d", "avx2.psllv.d.256", "avx2.psllv.q", "avx2.psllv.q.256", "avx512.psllv.d.512",
        "avx512.psllv.q.512", "avx512.psllv.w.128", "avx512.psllv.w.256", "avx512.psllv.w.512", "avx2.psrav.d",
        "avx2.psrav.d.256", "avx512.psrav.q.128", "avx512.psrav.q.256", "avx512.psrav.d.512", "avx512.psrav.q.512",
        "avx512.psrav.w.128", "avx512.psrav.w.256", "avx512.psrav.w.512", "avx2.psrlv.d", "avx2.psrlv.d.256", "avx2.psrlv.q",
        "avx2.psrlv.q.256", "avx512.psrlv.d.512", "avx512.psrlv.q.512", "avx512.psrlv.w.128", "avx512.psrlv.w.256",
        "avx512.psrlv.w.512");
    add(.PACKSS, "sse2.packssdw.128", "sse2.packsswb.128", "avx2.packssdw", "avx2.packsswb", "avx512.packssdw.512", "avx512.packsswb.512");
    add(.PACKUS, "sse2.packuswb.128", "sse41.packusdw", "avx2.packusdw", "avx2.packuswb", "avx512.packusdw.512", "avx512.packuswb.512");
    add(.PMULH, "sse2.pmulh.w", "avx2.pmulh.w", "avx512.pmulh.w.512");
    add(.PMULHU, "sse2.pmulhu.w", "avx2.pmulhu.w", "avx512.pmulhu.w.512");
    add(.PMULHRS, "ssse3.pmul.hr.sw.128", "avx2.pmul.hr.sw", "avx512.pmul.hr.sw.512");
    add(.PMADDWD, "sse2.pmadd.wd", "avx2.pmadd.wd", "avx512.pmaddw.d.512");
    add(.PMADDUBSW, "ssse3.pmadd.ub.sw.128", "avx2.pmadd.ub.sw", "avx512.pmaddubs.w.512");
    add(.PCLMULQDQ, "pclmulqdq", "pclmulqdq.256", "pclmulqdq.512");
    add(.INSERTPS, "sse41.insertps");
    add(.EXTRQ, "sse4a.extrq"); add(.EXTRQI, "sse4a.extrqi"); add(.INSERTQ, "sse4a.insertq"); add(.INSERTQI, "sse4a.insertqi");
    add(.BLENDV, "sse41.pblendvb", "sse41.blendvps", "sse41.blendvpd", "avx.blendv.ps.256", "avx.blendv.pd.256", "avx2.pblendvb");
    add(.PSHUFB, "ssse3.pshuf.b.128", "avx2.pshuf.b", "avx512.pshuf.b.512");
    add(.VPERMILVAR_PS, "avx.vpermilvar.ps", "avx.vpermilvar.ps.256", "avx512.vpermilvar.ps.512");
    add(.VPERMILVAR_PD, "avx.vpermilvar.pd", "avx.vpermilvar.pd.256", "avx512.vpermilvar.pd.512");
    add(.VPERMV, "avx2.permd", "avx2.permps", "avx512.permvar.df.256", "avx512.permvar.df.512", "avx512.permvar.di.256",
        "avx512.permvar.di.512", "avx512.permvar.hi.128", "avx512.permvar.hi.256", "avx512.permvar.hi.512",
        "avx512.permvar.qi.128", "avx512.permvar.qi.256", "avx512.permvar.qi.512", "avx512.permvar.sf.512", "avx512.permvar.si.512");
    add(.VPERMV3, "avx512.vpermi2var.d.128", "avx512.vpermi2var.d.256", "avx512.vpermi2var.d.512", "avx512.vpermi2var.hi.128",
        "avx512.vpermi2var.hi.256", "avx512.vpermi2var.hi.512", "avx512.vpermi2var.pd.128", "avx512.vpermi2var.pd.256",
        "avx512.vpermi2var.pd.512", "avx512.vpermi2var.ps.128", "avx512.vpermi2var.ps.256", "avx512.vpermi2var.ps.512",
        "avx512.vpermi2var.q.128", "avx512.vpermi2var.q.256", "avx512.vpermi2var.q.512", "avx512.vpermi2var.qi.128",
        "avx512.vpermi2var.qi.256", "avx512.vpermi2var.qi.512");
    add(.MASKLOAD, "avx.maskload.ps", "avx.maskload.pd", "avx.maskload.ps.256", "avx.maskload.pd.256", "avx2.maskload.d",
        "avx2.maskload.q", "avx2.maskload.d.256", "avx2.maskload.q.256");
    add(.MASKSTORE, "sse2.maskmov.dqu", "avx.maskstore.ps", "avx.maskstore.pd", "avx.maskstore.ps.256", "avx.maskstore.pd.256",
        "avx2.maskstore.d", "avx2.maskstore.q", "avx2.maskstore.d.256", "avx2.maskstore.q.256");
    add(.ADDCARRY, "addcarry.32", "addcarry.64");
    add(.PTERNLOG, "avx512.pternlog.d.128", "avx512.pternlog.d.256", "avx512.pternlog.d.512", "avx512.pternlog.q.128",
        "avx512.pternlog.q.256", "avx512.pternlog.q.512");
    add(.VPMADD52, "avx512.vpmadd52h.uq.128", "avx512.vpmadd52l.uq.128", "avx512.vpmadd52h.uq.256", "avx512.vpmadd52l.uq.256",
        "avx512.vpmadd52h.uq.512", "avx512.vpmadd52l.uq.512");
}
x86_kind :: (name: string) -> X86_Kind {
    if x86_kind_table.count == 0 x86_kind_init();
    ok, k := table_find(*x86_kind_table, name);
    if ok return k;
    return .NONE;
}
x86_name :: (ii: Value_Id) -> string { return intrinsic_name(call_iid(ii)); }
// the module targets x86 (the TTI that InstCombine gets is X86TTIImpl)
ic_targets_x86 :: () -> bool {
    t := ir.triple;
    return begins_with(t, "x86_64") || begins_with(t, "i386") || begins_with(t, "i486") || begins_with(t, "i586") || begins_with(t, "i686") || begins_with(t, "x86");
}

// getNegativeIsTrueBoolVec
x86_negative_is_true_bool_vec :: (v: Value_Id) -> Value_Id {
    it := type_vector_integer(vtype(v));
    c := ce_cast(.BITCAST, v, it);
    return cfo_compare_inst_operands(ICMP_SGT, const_null_value(it), c);
}
// getBoolVecFromMask
x86_bool_vec_from_mask :: (mask: Value_Id) -> Value_Id {
    k := vkind(mask);
    if k == .C_INT || k == .C_FP || k == .C_DATA return x86_negative_is_true_bool_vec(mask);
    ok, ext := pmi_cast(mask, .SEXT);
    if ok && is_int_or_int_vector_n(vtype(ext), 1) return ext;
    return NONE;
}
// simplifyX86MaskedLoad
x86_simplify_masked_load :: (ii: Value_Id) -> Value_Id {
    ptr := op(ii, 0); mask := op(ii, 1);
    zero := const_null_value(vtype(ii));
    if vkind(mask) == .C_ZERO return ic_replace_inst_uses_with(ii, zero);
    bm := x86_bool_vec_from_mask(mask);
    if bm != NONE {
        nml := icb_intrinsic(IID_MASKED_LOAD, .[vtype(ii), vtype(ptr)], .[ptr, bm, zero]);
        add_param_align(nml, 0, 1);
        return ic_replace_inst_uses_with(ii, nml);
    }
    return NONE;
}
// simplifyX86MaskedStore
x86_simplify_masked_store :: (ii: Value_Id) -> bool {
    ptr := op(ii, 0); mask := op(ii, 1); vec := op(ii, 2);
    if vkind(mask) == .C_ZERO { ic_erase_inst(ii); return true; }
    if x86_name(ii) == "llvm.x86.sse2.maskmov.dqu" return false;
    bm := x86_bool_vec_from_mask(mask);
    if bm != NONE {
        vpt := type_ptr_as(type_addrspace(vtype(ptr)));
        pc := icb_cast(.BITCAST, ptr, vpt, "castvec");
        ms := icb_intrinsic(IID_MASKED_STORE, .[vtype(vec), vtype(pc)], .[vec, pc, bm]);
        add_param_align(ms, 1, 1);
        ic_erase_inst(ii);
        return true;
    }
    return false;
}

x86_shift :: (vec: Value_Id, amt: Value_Id, logical: bool, left: bool) -> Value_Id {
    if logical { if left return icb_shl(vec, amt); return icb_lshr(vec, amt); }
    return icb_ashr(vec, amt);
}
// simplifyX86immShift
x86_simplify_imm_shift :: (ii: Value_Id) -> Value_Id {
    name := x86_name(ii);
    // llvm.x86.<ext>.ps<op>[i].<type>...
    is_imm := contains(name, ".psrai.") || contains(name, ".psrli.") || contains(name, ".pslli.");
    logical := !(contains(name, ".psra.") || contains(name, ".psrai."));
    left := contains(name, ".psll.") || contains(name, ".pslli.");
    vec := call_arg(ii, 0); amt := call_arg(ii, 1);
    vt := vtype(vec);
    svt := type_elem(vt);
    amt_vt := vtype(amt);
    vwidth := type_count(vt);
    bw := type_bits(svt);
    q0: Simplify_Query;
    if is_imm {
        kab := known_bits(amt, q0);
        if ap_ult_u64(kb_max_value(kab), cast(u64) bw) {
            a := icb_zext_or_trunc(amt, svt);
            a = icb_vector_splat(vwidth, false, a);
            return x86_shift(vec, a, logical, left);
        }
        if ap_uge_u64(kb_min_value(kab), cast(u64) bw) {
            if logical return const_null_value(vt);
            a := const_int_of(svt, cast(u64) bw - 1);
            return icb_ashr(vec, icb_vector_splat(vwidth, false, a));
        }
    } else {
        n := cast(u32) type_count(amt_vt);
        dl := ap_one_bit_set(n, 0);
        du := ap_bits_set(n, 1, n / 2);
        kl := known_bits_de(amt, dl, q0, 0);
        ku := known_bits_de(amt, du, q0, 0);
        if ap_ult_u64(kb_max_value(kl), cast(u64) bw) && (ap_is_zero(du) || kb_is_zero(ku)) {
            zs := NewArray(cast(s64) vwidth, u32,, allocator = temp);
            a := icb_shuffle(amt, NONE, zs);
            return x86_shift(vec, a, logical, left);
        }
    }
    if vkind(amt) != .C_DATA return NONE;
    count := ap_zero(64);
    nsub := 64 / bw;
    for k: 0..nsub-1 {
        idx := (nsub - 1) - k;
        se := cf_elt(amt, cast(u64) idx);
        count = ap_shl(count, bw);
        count = ap_or(count, ap_zext_or_trunc(const_ap(se), 64));
    }
    if ap_is_zero(count) return vec;
    if ap_uge_u64(count, cast(u64) bw) {
        if logical return const_null_value(vt);
        count = ap_from_u64(64, cast(u64) bw - 1);
    }
    sa := const_int_ap(svt, ap_zext_or_trunc(count, bw));
    sv := icb_vector_splat(vwidth, false, sa);
    if left return icb_shl(vec, sv);
    if logical return icb_lshr(vec, sv);
    return icb_ashr(vec, sv);
}
// simplifyX86varShift
x86_simplify_var_shift :: (ii: Value_Id) -> Value_Id {
    name := x86_name(ii);
    logical := !contains(name, ".psrav.");
    left := contains(name, ".psllv.");
    vec := call_arg(ii, 0); amt := call_arg(ii, 1);
    vt := vtype(ii);
    svt := type_elem(vt);
    n := cast(s64) type_count(vt);
    bw := cast(s64) type_int_width(svt);
    q0: Simplify_Query;
    ka := known_bits(amt, q0);
    if ap_ult_u64(kb_max_value(ka), cast(u64) bw) return x86_shift(vec, amt, logical, left);
    if !is_const(amt) return NONE;
    any_oor := false;
    amts: [..] s64; amts.allocator = temp;
    for k: 0..n-1 {
        ce := cf_elt(amt, cast(u64) k);
        if ce != NONE && pm_undef_value(ce) { array_add(*amts, -1); continue; }
        if ce == NONE || vkind(ce) != .C_INT return NONE;
        sv := const_ap(ce);
        if ap_uge_u64(sv, cast(u64) bw) {
            any_oor = logical;
            array_add(*amts, ifx logical then bw else bw - 1);
            continue;
        }
        array_add(*amts, cast(s64) ap_zext_value(sv));
    }
    all_oor := true;
    for amts if !(it < 0 || bw <= it) { all_oor = false; break; }
    if all_oor {
        elts := NewArray(n, Value_Id,, allocator = temp);
        for amts elts[it_index] = ifx it < 0 then const_undef(svt) else const_null_value(svt);
        return cf_vector(vt, elts);
    }
    if any_oor return NONE;
    elts := NewArray(n, Value_Id,, allocator = temp);
    for amts elts[it_index] = ifx it < 0 then const_undef(svt) else const_int_of(svt, cast(u64) it);
    shv := cf_vector(vector_with_elt(vt, svt), elts);
    if left return icb_shl(vec, shv);
    if logical return icb_lshr(vec, shv);
    return icb_ashr(vec, shv);
}
// simplifyX86pack
x86_simplify_pack :: (ii: Value_Id, is_signed: bool) -> Value_Id {
    a0 := call_arg(ii, 0); a1 := call_arg(ii, 1);
    rt := vtype(ii);
    if pm_undef_value(a0) && pm_undef_value(a1) return const_undef(rt);
    at := vtype(a0);
    lanes := ic_prim_bits(rt) / 128;
    nsrc := type_count(at);
    per_lane := nsrc / lanes;
    dbits := type_bits(scalar_type(rt)); sbits := type_bits(scalar_type(at));
    if !is_const(a0) || !is_const(a1) return NONE;
    mn, mx: APInt;
    if is_signed { mn = ap_sext(ap_signed_min(dbits), sbits); mx = ap_sext(ap_signed_max(dbits), sbits); }
    else { mn = ap_zero(sbits); mx = ap_low_bits_set(sbits, dbits); }
    minc := const_int_ap(at, mn); maxc := const_int_ap(at, mx);
    a0 = icb_select(icb_cmp(ICMP_SLT, a0, minc), minc, a0);
    a1 = icb_select(icb_cmp(ICMP_SLT, a1, minc), minc, a1);
    a0 = icb_select(icb_cmp(ICMP_SGT, a0, maxc), maxc, a0);
    a1 = icb_select(icb_cmp(ICMP_SGT, a1, maxc), maxc, a1);
    mask: [..] u32; mask.allocator = temp;
    for lane: 0..lanes-1 {
        for e: 0..per_lane-1 array_add(*mask, cast(u32) (e + lane * per_lane));
        for e: 0..per_lane-1 array_add(*mask, cast(u32) (e + lane * per_lane + nsrc));
    }
    sh := icb_shuffle(a0, a1, mask);
    return icb_trunc(sh, rt);
}
// simplifyX86pmulh
x86_simplify_pmulh :: (ii: Value_Id, is_signed: bool, is_rounding: bool) -> Value_Id {
    a0 := call_arg(ii, 0); a1 := call_arg(ii, 1);
    rt := vtype(ii); at := vtype(a0);
    if pm_undef_value(a0) || pm_undef_value(a1) return const_null_value(rt);
    if vkind(a0) == .C_ZERO || vkind(a1) == .C_ZERO return const_null_value(rt);
    if !is_rounding {
        if pm_one(a0) return ifx is_signed then icb_ashr(a1, const_int_of(vtype(a1), 15)) else const_null_value(rt);
        if pm_one(a1) return ifx is_signed then icb_ashr(a0, const_int_of(vtype(a0), 15)) else const_null_value(rt);
    }
    if !is_const(a0) || !is_const(a1) return NONE;
    ext: Opcode = ifx is_signed then .SEXT else .ZEXT;
    ext_ty := vector_with_elt(at, type_int(type_bits(scalar_type(at)) * 2));
    l := icb_cast(ext, a0, ext_ty); r := icb_cast(ext, a1, ext_ty);
    mul := icb_mul(l, r);
    if is_rounding {
        rnd_ty := vector_with_elt(ext_ty, type_int(18));
        mul = icb_lshr(mul, const_int_of(ext_ty, 14));
        mul = icb_trunc(mul, rnd_ty);
        mul = icb_add(mul, const_int_of(rnd_ty, 1));
        mul = icb_lshr(mul, const_int_of(rnd_ty, 1));
    } else {
        mul = icb_lshr(mul, const_int_of(ext_ty, 16));
    }
    return icb_trunc(mul, rt);
}
// simplifyX86pmadd
x86_simplify_pmadd :: (ii: Value_Id, is_pmaddwd: bool) -> Value_Id {
    a0 := call_arg(ii, 0); a1 := call_arg(ii, 1);
    rt := vtype(ii);
    nd := cast(s64) type_count(rt);
    if pm_undef_value(a0) || pm_undef_value(a1) return const_null_value(rt);
    if vkind(a0) == .C_ZERO || vkind(a1) == .C_ZERO return const_null_value(rt);
    if !is_const(a0) || !is_const(a1) return NONE;
    lo := NewArray(nd, u32,, allocator = temp); hi := NewArray(nd, u32,, allocator = temp);
    for k: 0..nd-1 { lo[k] = cast(u32) (2 * k); hi[k] = cast(u32) (2 * k + 1); }
    llo := icb_shuffle(a0, NONE, lo); lhi := icb_shuffle(a0, NONE, hi);
    rlo := icb_shuffle(a1, NONE, lo); rhi := icb_shuffle(a1, NONE, hi);
    lc: Opcode = ifx is_pmaddwd then .SEXT else .ZEXT;
    llo = icb_cast(lc, llo, rt); lhi = icb_cast(lc, lhi, rt);
    rlo = icb_cast(.SEXT, rlo, rt); rhi = icb_cast(.SEXT, rhi, rt);
    l := icb_mul(llo, rlo); h := icb_mul(lhi, rhi);
    if is_pmaddwd return icb_add(l, h);
    return icb_intrinsic_ret(rt, IID_SADD_SAT, .[l, h]);
}
// simplifyX86movmsk
x86_simplify_movmsk :: (ii: Value_Id) -> Value_Id {
    arg := call_arg(ii, 0);
    rt := vtype(ii);
    if pm_undef_value(arg) return const_null_value(rt);
    if x86_name(ii) == "llvm.x86.mmx.pmovmskb" return NONE;
    at := vtype(arg);
    n := cast(u32) type_count(at);
    res := icb_cast(.BITCAST, arg, type_vector_integer(at));
    res = icb_cmp(ICMP_SLT, res, const_null_value(vtype(res)));
    res = icb_cast(.BITCAST, res, type_int(n));
    return icb_zext_or_trunc(res, rt);
}
// simplifyX86addcarry
x86_simplify_addcarry :: (ii: Value_Id) -> Value_Id {
    ci := call_arg(ii, 0); o1 := call_arg(ii, 1); o2 := call_arg(ii, 2);
    rt := vtype(ii);
    if pm_zero_int(ci) {
        uadd := icb_intrinsic(IID_UADD_WITH_OVERFLOW, .[vtype(o1)], .[o1, o2]);
        r := icb_extract_value(uadd, .[0]);
        ov := icb_zext(icb_extract_value(uadd, .[1]), ir.t_i8);
        res := const_poison(rt);
        res = icb_insert_value(res, ov, .[0]);
        return icb_insert_value(res, r, .[1]);
    }
    return NONE;
}

// simplifyTernarylogic: (value, truth table) pairs
Tl :: struct { v: Value_Id; t: u8; }
tl_or :: (a: Tl, b: Tl) -> Tl { return .{icb_or(a.v, b.v), a.t | b.t}; }
tl_xor :: (a: Tl, b: Tl) -> Tl { return .{icb_xor(a.v, b.v), a.t ^ b.t}; }
tl_and :: (a: Tl, b: Tl) -> Tl { return .{icb_and(a.v, b.v), a.t & b.t}; }
tl_not :: (a: Tl) -> Tl { return .{icb_not(a.v), ~a.t}; }
tl_nor :: (a: Tl, b: Tl) -> Tl { return tl_not(tl_or(a, b)); }
tl_xnor :: (a: Tl, b: Tl) -> Tl { return tl_not(tl_xor(a, b)); }
tl_nand :: (a: Tl, b: Tl) -> Tl { return tl_not(tl_and(a, b)); }
tl_const :: (ones: bool, ty: Type_Id) -> Tl {
    if ones return .{const_all_ones_of(ty), 0xff};
    return .{const_null_value(ty), 0};
}
x86_simplify_ternarylogic :: (ii: Value_Id) -> Value_Id {
    imm_c := call_arg(ii, 3);
    if !cf_is_int(imm_c) || ap_uge_u64(const_ap(imm_c), 256) return NONE;
    ty := vtype(ii);
    a_c := pm_imm_constant(call_arg(ii, 0)); b_c := pm_imm_constant(call_arg(ii, 1)); c_c := pm_imm_constant(call_arg(ii, 2));
    ab_c := a_c && b_c; ac_c := a_c && c_c; bc_c := b_c && c_c; abc_c := a_c && b_c && c_c;
    A := Tl.{call_arg(ii, 0), 0xf0};
    B := Tl.{call_arg(ii, 1), 0xcc};
    C := Tl.{call_arg(ii, 2), 0xaa};
    res := Tl.{NONE, 0};
    imm := cast(u8) const_int_zext(imm_c);
    if imm == {
        case 0x0; res = tl_const(false, ty);
        case 0x1; if abc_c res = tl_nor(tl_or(A, B), C);
        case 0x2; if abc_c res = tl_and(tl_nor(A, B), C);
        case 0x3; if ab_c res = tl_nor(A, B);
        case 0x4; if abc_c res = tl_and(tl_nor(A, C), B);
        case 0x5; if ac_c res = tl_nor(A, C);
        case 0x6; if abc_c res = tl_nor(A, tl_xnor(B, C));
        case 0x7; if abc_c res = tl_nor(A, tl_and(B, C));
        case 0x8; if abc_c res = tl_nor(A, tl_nand(B, C));
        case 0x9; if abc_c res = tl_nor(A, tl_xor(B, C));
        case 0xa; if ac_c res = tl_nor(A, tl_not(C));
        case 0xb; if abc_c res = tl_nor(A, tl_nor(C, tl_not(B)));
        case 0xc; if ab_c res = tl_nor(A, tl_not(B));
        case 0xd; if abc_c res = tl_nor(A, tl_nor(B, tl_not(C)));
        case 0xe; if abc_c res = tl_nor(A, tl_nor(B, C));
        case 0xf; res = tl_not(A);
        case 0x10; if abc_c res = tl_and(A, tl_nor(B, C));
        case 0x11; if bc_c res = tl_nor(B, C);
        case 0x12; if abc_c res = tl_nor(tl_xnor(A, C), B);
        case 0x13; if abc_c res = tl_nor(tl_and(A, C), B);
        case 0x14; if abc_c res = tl_nor(tl_xnor(A, B), C);
        case 0x15; if abc_c res = tl_nor(tl_and(A, B), C);
        case 0x16; if abc_c res = tl_xor(tl_xor(A, B), tl_and(tl_nand(A, B), C));
        case 0x17; if abc_c res = tl_xor(tl_or(A, B), tl_or(tl_xnor(A, B), C));
        case 0x18; if abc_c res = tl_nor(tl_xnor(A, B), tl_xnor(A, C));
        case 0x19; if abc_c res = tl_and(tl_nand(A, B), tl_xnor(B, C));
        case 0x1a; if abc_c res = tl_xor(A, tl_or(tl_and(A, B), C));
        case 0x1b; if abc_c res = tl_xor(A, tl_or(tl_xnor(A, B), C));
        case 0x1c; if abc_c res = tl_xor(A, tl_or(tl_and(A, C), B));
        case 0x1d; if abc_c res = tl_xor(A, tl_or(tl_xnor(A, C), B));
        case 0x1e; if abc_c res = tl_xor(A, tl_or(B, C));
        case 0x1f; if abc_c res = tl_nand(A, tl_or(B, C));
        case 0x20; if abc_c res = tl_nor(tl_nand(A, C), B);
        case 0x21; if abc_c res = tl_nor(tl_xor(A, C), B);
        case 0x22; if bc_c res = tl_nor(B, tl_not(C));
        case 0x23; if abc_c res = tl_nor(B, tl_nor(C, tl_not(A)));
        case 0x24; if abc_c res = tl_nor(tl_xnor(A, B), tl_xor(A, C));
        case 0x25; if abc_c res = tl_xor(A, tl_nand(tl_nand(A, B), C));
        case 0x26; if abc_c res = tl_and(tl_nand(A, B), tl_xor(B, C));
        case 0x27; if abc_c res = tl_xor(tl_or(tl_xnor(A, B), C), B);
        case 0x28; if abc_c res = tl_and(tl_xor(A, B), C);
        case 0x29; if abc_c res = tl_xor(tl_xor(A, B), tl_nor(tl_and(A, B), C));
        case 0x2a; if abc_c res = tl_and(tl_nand(A, B), C);
        case 0x2b; if abc_c res = tl_xor(tl_or(tl_xnor(A, B), tl_xor(A, C)), A);
        case 0x2c; if abc_c res = tl_nor(tl_xnor(A, B), tl_nor(B, C));
        case 0x2d; if abc_c res = tl_xor(A, tl_or(B, tl_not(C)));
        case 0x2e; if abc_c res = tl_xor(A, tl_or(tl_xor(A, C), B));
        case 0x2f; if abc_c res = tl_nand(A, tl_or(B, tl_not(C)));
        case 0x30; if ab_c res = tl_nor(B, tl_not(A));
        case 0x31; if abc_c res = tl_nor(tl_nor(A, tl_not(C)), B);
        case 0x32; if abc_c res = tl_nor(tl_nor(A, C), B);
        case 0x33; res = tl_not(B);
        case 0x34; if abc_c res = tl_and(tl_xor(A, B), tl_nand(B, C));
        case 0x35; if abc_c res = tl_xor(B, tl_or(A, tl_xnor(B, C)));
        case 0x36; if abc_c res = tl_xor(tl_or(A, C), B);
        case 0x37; if abc_c res = tl_nand(tl_or(A, C), B);
        case 0x38; if abc_c res = tl_nor(tl_xnor(A, B), tl_nor(A, C));
        case 0x39; if abc_c res = tl_xor(tl_or(A, tl_not(C)), B);
        case 0x3a; if abc_c res = tl_xor(B, tl_or(A, tl_xor(B, C)));
        case 0x3b; if abc_c res = tl_nand(tl_or(A, tl_not(C)), B);
        case 0x3c; res = tl_xor(A, B);
        case 0x3d; if abc_c res = tl_xor(A, tl_or(tl_nor(A, C), B));
        case 0x3e; if abc_c res = tl_xor(A, tl_or(tl_nor(A, tl_not(C)), B));
        case 0x3f; if ab_c res = tl_nand(A, B);
        case 0x40; if abc_c res = tl_nor(tl_nand(A, B), C);
        case 0x41; if abc_c res = tl_nor(tl_xor(A, B), C);
        case 0x42; if abc_c res = tl_nor(tl_xor(A, B), tl_xnor(A, C));
        case 0x43; if abc_c res = tl_xor(A, tl_nand(tl_nand(A, C), B));
        case 0x44; if bc_c res = tl_nor(C, tl_not(B));
        case 0x45; if abc_c res = tl_nor(tl_nor(B, tl_not(A)), C);
        case 0x46; if abc_c res = tl_xor(tl_or(tl_and(A, C), B), C);
        case 0x47; if abc_c res = tl_xor(tl_or(tl_xnor(A, C), B), C);
        case 0x48; if abc_c res = tl_and(tl_xor(A, C), B);
        case 0x49; if abc_c res = tl_xor(tl_or(tl_xnor(A, B), tl_and(A, C)), C);
        case 0x4a; if abc_c res = tl_nor(tl_xnor(A, C), tl_nor(B, C));
        case 0x4b; if abc_c res = tl_xor(A, tl_or(C, tl_not(B)));
        case 0x4c; if abc_c res = tl_and(tl_nand(A, C), B);
        case 0x4d; if abc_c res = tl_xor(tl_or(tl_xor(A, B), tl_xnor(A, C)), A);
        case 0x4e; if abc_c res = tl_xor(A, tl_or(tl_xor(A, B), C));
        case 0x4f; if abc_c res = tl_nand(A, tl_nand(B, tl_not(C)));
        case 0x50; if ac_c res = tl_nor(C, tl_not(A));
        case 0x51; if abc_c res = tl_nor(tl_nor(A, tl_not(B)), C);
        case 0x52; if abc_c res = tl_and(tl_xor(A, C), tl_nand(B, C));
        case 0x53; if abc_c res = tl_xor(tl_or(tl_xnor(B, C), A), C);
        case 0x54; if abc_c res = tl_nor(tl_nor(A, B), C);
        case 0x55; res = tl_not(C);
        case 0x56; if abc_c res = tl_xor(tl_or(A, B), C);
        case 0x57; if abc_c res = tl_nand(tl_or(A, B), C);
        case 0x58; if abc_c res = tl_nor(tl_nor(A, B), tl_xnor(A, C));
        case 0x59; if abc_c res = tl_xor(tl_or(A, tl_not(B)), C);
        case 0x5a; res = tl_xor(A, C);
        case 0x5b; if abc_c res = tl_xor(A, tl_or(tl_nor(A, B), C));
        case 0x5c; if abc_c res = tl_xor(tl_or(tl_xor(B, C), A), C);
        case 0x5d; if abc_c res = tl_nand(tl_or(A, tl_not(B)), C);
        case 0x5e; if abc_c res = tl_xor(A, tl_or(tl_nor(A, tl_not(B)), C));
        case 0x5f; if ac_c res = tl_nand(A, C);
        case 0x60; if abc_c res = tl_and(A, tl_xor(B, C));
        case 0x61; if abc_c res = tl_xor(tl_or(tl_xnor(A, B), tl_and(B, C)), C);
        case 0x62; if abc_c res = tl_nor(tl_nor(A, C), tl_xnor(B, C));
        case 0x63; if abc_c res = tl_xor(B, tl_or(C, tl_not(A)));
        case 0x64; if abc_c res = tl_nor(tl_nor(A, B), tl_xnor(B, C));
        case 0x65; if abc_c res = tl_xor(tl_or(B, tl_not(A)), C);
        case 0x66; res = tl_xor(B, C);
        case 0x67; if abc_c res = tl_or(tl_nor(A, B), tl_xor(B, C));
        case 0x68; if abc_c res = tl_xor(tl_xor(A, B), tl_nor(tl_nor(A, B), C));
        case 0x69; if abc_c res = tl_xor(tl_xnor(A, B), C);
        case 0x6a; if abc_c res = tl_xor(tl_and(A, B), C);
        case 0x6b; if abc_c res = tl_or(tl_nor(A, B), tl_xor(tl_xnor(A, B), C));
        case 0x6c; if abc_c res = tl_xor(tl_and(A, C), B);
        case 0x6d; if abc_c res = tl_xor(tl_or(tl_xnor(A, B), tl_nor(A, C)), C);
        case 0x6e; if abc_c res = tl_or(tl_nor(A, tl_not(B)), tl_xor(B, C));
        case 0x6f; if abc_c res = tl_nand(A, tl_xnor(B, C));
        case 0x70; if abc_c res = tl_and(A, tl_nand(B, C));
        case 0x71; if abc_c res = tl_xor(tl_nor(tl_xor(A, B), tl_xor(A, C)), A);
        case 0x72; if abc_c res = tl_xor(tl_or(tl_xor(A, B), C), B);
        case 0x73; if abc_c res = tl_nand(tl_nand(A, tl_not(C)), B);
        case 0x74; if abc_c res = tl_xor(tl_or(tl_xor(A, C), B), C);
        case 0x75; if abc_c res = tl_nand(tl_nand(A, tl_not(B)), C);
        case 0x76; if abc_c res = tl_xor(B, tl_or(tl_nor(B, tl_not(A)), C));
        case 0x77; if bc_c res = tl_nand(B, C);
        case 0x78; if abc_c res = tl_xor(A, tl_and(B, C));
        case 0x79; if abc_c res = tl_xor(tl_or(tl_xnor(A, B), tl_nor(B, C)), C);
        case 0x7a; if abc_c res = tl_or(tl_xor(A, C), tl_nor(B, tl_not(A)));
        case 0x7b; if abc_c res = tl_nand(tl_xnor(A, C), B);
        case 0x7c; if abc_c res = tl_or(tl_xor(A, B), tl_nor(C, tl_not(A)));
        case 0x7d; if abc_c res = tl_nand(tl_xnor(A, B), C);
        case 0x7e; if abc_c res = tl_or(tl_xor(A, B), tl_xor(A, C));
        case 0x7f; if abc_c res = tl_nand(tl_and(A, B), C);
        case 0x80; if abc_c res = tl_and(tl_and(A, B), C);
        case 0x81; if abc_c res = tl_nor(tl_xor(A, B), tl_xor(A, C));
        case 0x82; if abc_c res = tl_and(tl_xnor(A, B), C);
        case 0x83; if abc_c res = tl_nor(tl_xor(A, B), tl_nor(C, tl_not(A)));
        case 0x84; if abc_c res = tl_and(tl_xnor(A, C), B);
        case 0x85; if abc_c res = tl_nor(tl_xor(A, C), tl_nor(B, tl_not(A)));
        case 0x86; if abc_c res = tl_xor(tl_nor(tl_xnor(A, B), tl_nor(B, C)), C);
        case 0x87; if abc_c res = tl_xor(A, tl_nand(B, C));
        case 0x88; res = tl_and(B, C);
        case 0x89; if abc_c res = tl_xor(B, tl_nor(tl_nor(B, tl_not(A)), C));
        case 0x8a; if abc_c res = tl_and(tl_nand(A, tl_not(B)), C);
        case 0x8b; if abc_c res = tl_xor(tl_nor(tl_xor(A, C), B), C);
        case 0x8c; if abc_c res = tl_and(tl_nand(A, tl_not(C)), B);
        case 0x8d; if abc_c res = tl_xor(tl_nor(tl_xor(A, B), C), B);
        case 0x8e; if abc_c res = tl_xor(tl_or(tl_xor(A, B), tl_xor(A, C)), A);
        case 0x8f; if abc_c res = tl_nand(A, tl_nand(B, C));
        case 0x90; if abc_c res = tl_and(A, tl_xnor(B, C));
        case 0x91; if abc_c res = tl_nor(tl_nor(A, tl_not(B)), tl_xor(B, C));
        case 0x92; if abc_c res = tl_xor(tl_nor(tl_xnor(A, B), tl_nor(A, C)), C);
        case 0x93; if abc_c res = tl_xor(tl_nand(A, C), B);
        case 0x94; if abc_c res = tl_nor(tl_nor(A, B), tl_xor(tl_xnor(A, B), C));
        case 0x95; if abc_c res = tl_xor(tl_nand(A, B), C);
        case 0x96; if abc_c res = tl_xor(tl_xor(A, B), C);
        case 0x97; if abc_c res = tl_xor(tl_xor(A, B), tl_or(tl_nor(A, B), C));
        case 0x98; if abc_c res = tl_nor(tl_nor(A, B), tl_xor(B, C));
        case 0x99; if bc_c res = tl_xnor(B, C);
        case 0x9a; if abc_c res = tl_xor(tl_nor(B, tl_not(A)), C);
        case 0x9b; if abc_c res = tl_or(tl_nor(A, B), tl_xnor(B, C));
        case 0x9c; if abc_c res = tl_xor(B, tl_nor(C, tl_not(A)));
        case 0x9d; if abc_c res = tl_or(tl_nor(A, C), tl_xnor(B, C));
        case 0x9e; if abc_c res = tl_xor(tl_and(tl_xor(A, B), tl_nand(B, C)), C);
        case 0x9f; if abc_c res = tl_nand(A, tl_xor(B, C));
        case 0xa0; res = tl_and(A, C);
        case 0xa1; if abc_c res = tl_xor(A, tl_nor(tl_nor(A, tl_not(B)), C));
        case 0xa2; if abc_c res = tl_and(tl_or(A, tl_not(B)), C);
        case 0xa3; if abc_c res = tl_xor(tl_nor(tl_xor(B, C), A), C);
        case 0xa4; if abc_c res = tl_xor(A, tl_nor(tl_nor(A, B), C));
        case 0xa5; if ac_c res = tl_xnor(A, C);
        case 0xa6; if abc_c res = tl_xor(tl_nor(A, tl_not(B)), C);
        case 0xa7; if abc_c res = tl_or(tl_nor(A, B), tl_xnor(A, C));
        case 0xa8; if abc_c res = tl_and(tl_or(A, B), C);
        case 0xa9; if abc_c res = tl_xor(tl_nor(A, B), C);
        case 0xaa; res = C;
        case 0xab; if abc_c res = tl_or(tl_nor(A, B), C);
        case 0xac; if abc_c res = tl_xor(tl_nor(tl_xnor(B, C), A), C);
        case 0xad; if abc_c res = tl_or(tl_xnor(A, C), tl_and(B, C));
        case 0xae; if abc_c res = tl_or(tl_nor(A, tl_not(B)), C);
        case 0xaf; if ac_c res = tl_or(C, tl_not(A));
        case 0xb0; if abc_c res = tl_and(A, tl_nand(B, tl_not(C)));
        case 0xb1; if abc_c res = tl_xor(A, tl_nor(tl_xor(A, B), C));
        case 0xb2; if abc_c res = tl_xor(tl_nor(tl_xor(A, B), tl_xnor(A, C)), A);
        case 0xb3; if abc_c res = tl_nand(tl_nand(A, C), B);
        case 0xb4; if abc_c res = tl_xor(A, tl_nor(C, tl_not(B)));
        case 0xb5; if abc_c res = tl_or(tl_xnor(A, C), tl_nor(B, C));
        case 0xb6; if abc_c res = tl_xor(tl_and(tl_xor(A, B), tl_nand(A, C)), C);
        case 0xb7; if abc_c res = tl_nand(tl_xor(A, C), B);
        case 0xb8; if abc_c res = tl_xor(tl_nor(tl_xnor(A, C), B), C);
        case 0xb9; if abc_c res = tl_xor(tl_nor(tl_and(A, C), B), C);
        case 0xba; if abc_c res = tl_or(tl_nor(B, tl_not(A)), C);
        case 0xbb; if bc_c res = tl_or(C, tl_not(B));
        case 0xbc; if abc_c res = tl_xor(A, tl_and(tl_nand(A, C), B));
        case 0xbd; if abc_c res = tl_or(tl_xor(A, B), tl_xnor(A, C));
        case 0xbe; if abc_c res = tl_or(tl_xor(A, B), C);
        case 0xbf; if abc_c res = tl_or(tl_nand(A, B), C);
        case 0xc0; res = tl_and(A, B);
        case 0xc1; if abc_c res = tl_xor(A, tl_nor(tl_nor(A, tl_not(C)), B));
        case 0xc2; if abc_c res = tl_xor(A, tl_nor(tl_nor(A, C), B));
        case 0xc3; if ab_c res = tl_xnor(A, B);
        case 0xc4; if abc_c res = tl_and(tl_or(A, tl_not(C)), B);
        case 0xc5; if abc_c res = tl_xor(B, tl_nor(A, tl_xor(B, C)));
        case 0xc6; if abc_c res = tl_xor(tl_nor(A, tl_not(C)), B);
        case 0xc7; if abc_c res = tl_or(tl_xnor(A, B), tl_nor(A, C));
        case 0xc8; if abc_c res = tl_and(tl_or(A, C), B);
        case 0xc9; if abc_c res = tl_xor(tl_nor(A, C), B);
        case 0xca; if abc_c res = tl_xor(B, tl_nor(A, tl_xnor(B, C)));
        case 0xcb; if abc_c res = tl_or(tl_xnor(A, B), tl_and(B, C));
        case 0xcc; res = B;
        case 0xcd; if abc_c res = tl_or(tl_nor(A, C), B);
        case 0xce; if abc_c res = tl_or(tl_nor(A, tl_not(C)), B);
        case 0xcf; if ab_c res = tl_or(B, tl_not(A));
        case 0xd0; if abc_c res = tl_and(A, tl_or(B, tl_not(C)));
        case 0xd1; if abc_c res = tl_xor(A, tl_nor(tl_xor(A, C), B));
        case 0xd2; if abc_c res = tl_xor(A, tl_nor(B, tl_not(C)));
        case 0xd3; if abc_c res = tl_or(tl_xnor(A, B), tl_nor(B, C));
        case 0xd4; if abc_c res = tl_xor(tl_nor(tl_xnor(A, B), tl_xor(A, C)), A);
        case 0xd5; if abc_c res = tl_nand(tl_nand(A, B), C);
        case 0xd6; if abc_c res = tl_xor(tl_xor(A, B), tl_or(tl_and(A, B), C));
        case 0xd7; if abc_c res = tl_nand(tl_xor(A, B), C);
        case 0xd8; if abc_c res = tl_xor(tl_nor(tl_xnor(A, B), C), B);
        case 0xd9; if abc_c res = tl_or(tl_and(A, B), tl_xnor(B, C));
        case 0xda; if abc_c res = tl_xor(A, tl_and(tl_nand(A, B), C));
        case 0xdb; if abc_c res = tl_or(tl_xnor(A, B), tl_xor(A, C));
        case 0xdc; if abc_c res = tl_or(B, tl_nor(C, tl_not(A)));
        case 0xdd; if bc_c res = tl_or(B, tl_not(C));
        case 0xde; if abc_c res = tl_or(tl_xor(A, C), B);
        case 0xdf; if abc_c res = tl_or(tl_nand(A, C), B);
        case 0xe0; if abc_c res = tl_and(A, tl_or(B, C));
        case 0xe1; if abc_c res = tl_xor(A, tl_nor(B, C));
        case 0xe2; if abc_c res = tl_xor(A, tl_nor(tl_xnor(A, C), B));
        case 0xe3; if abc_c res = tl_xor(A, tl_nor(tl_and(A, C), B));
        case 0xe4; if abc_c res = tl_xor(A, tl_nor(tl_xnor(A, B), C));
        case 0xe5; if abc_c res = tl_xor(A, tl_nor(tl_and(A, B), C));
        case 0xe6; if abc_c res = tl_or(tl_and(A, B), tl_xor(B, C));
        case 0xe7; if abc_c res = tl_or(tl_xnor(A, B), tl_xnor(A, C));
        case 0xe8; if abc_c res = tl_xor(tl_or(A, B), tl_nor(tl_xnor(A, B), C));
        case 0xe9; if abc_c res = tl_xor(tl_xor(A, B), tl_nand(tl_nand(A, B), C));
        case 0xea; if abc_c res = tl_or(tl_and(A, B), C);
        case 0xeb; if abc_c res = tl_or(tl_xnor(A, B), C);
        case 0xec; if abc_c res = tl_or(tl_and(A, C), B);
        case 0xed; if abc_c res = tl_or(tl_xnor(A, C), B);
        case 0xee; res = tl_or(B, C);
        case 0xef; if abc_c res = tl_nand(A, tl_nor(B, C));
        case 0xf0; res = A;
        case 0xf1; if abc_c res = tl_or(A, tl_nor(B, C));
        case 0xf2; if abc_c res = tl_or(A, tl_nor(B, tl_not(C)));
        case 0xf3; if ab_c res = tl_or(A, tl_not(B));
        case 0xf4; if abc_c res = tl_or(A, tl_nor(C, tl_not(B)));
        case 0xf5; if ac_c res = tl_or(A, tl_not(C));
        case 0xf6; if abc_c res = tl_or(A, tl_xor(B, C));
        case 0xf7; if abc_c res = tl_or(A, tl_nand(B, C));
        case 0xf8; if abc_c res = tl_or(A, tl_and(B, C));
        case 0xf9; if abc_c res = tl_or(A, tl_xnor(B, C));
        case 0xfa; res = tl_or(A, C);
        case 0xfb; if abc_c res = tl_nand(tl_nor(A, C), B);
        case 0xfc; res = tl_or(A, B);
        case 0xfd; if abc_c res = tl_nand(tl_nor(A, B), C);
        case 0xfe; if abc_c res = tl_or(tl_or(A, B), C);
        case 0xff; res = tl_const(true, ty);
    }
    if res.v != NONE && res.t != imm fatal("internal: simplifyTernarylogic does not verify");
    return res.v;
}

// simplifyX86FPMaxMin
x86_simplify_fp_max_min :: (ii: Value_Id, new_id: Intrinsic_Id, is_scalar := false) -> Value_Id {
    a0 := call_arg(ii, 0); a1 := call_arg(ii, 1);
    vw := cast(u32) type_count(vtype(a0));
    q := ic_q(ii);
    de := ifx is_scalar then ap_one_bit_set(vw, 0) else ap_all_ones(vw);
    f0: u32 = FC_NAN | FC_INF | FC_SUBNORMAL;
    f1: u32 = FC_NAN | FC_INF | FC_SUBNORMAL;
    if new_id == IID_MAXNUM f1 |= FC_NEG_ZERO; else f0 |= FC_NEG_ZERO;
    k0 := compute_known_fp_class_de(a0, de, f0, q, 0);
    k1 := compute_known_fp_class_de(a1, de, f1, q, 0);
    if kfpc_is_known_never(k0, f0) && kfpc_is_known_never(k1, f1) {
        if is_scalar {
            s0 := icb_extract_element(a0, const_int(ir.t_i64, 0));
            s1 := icb_extract_element(a1, const_int(ir.t_i64, 0));
            ns := icb_binary_intrinsic(new_id, s0, s1);
            return icb_insert_element(a0, ns, const_int(ir.t_i64, 0));
        }
        return icb_binary_intrinsic(new_id, a0, a1);
    }
    return NONE;
}
// simplifyX86insertps
x86_simplify_insertps :: (ii: Value_Id) -> Value_Id {
    c := call_arg(ii, 2);
    if !cf_is_int(c) return NONE;
    vt := vtype(ii);
    imm := cast(u8) const_int_zext(c);
    zmask := imm & 0xf; dest := (imm >> 4) & 0x3; srcl := (imm >> 6) & 0x3;
    zero := const_null_value(vt);
    if zmask == 0xf return zero;
    mask: [4] u32 = .[0, 1, 2, 3];
    v1 := call_arg(ii, 1);
    if zmask {
        if call_arg(ii, 0) == call_arg(ii, 1) || (zmask & (cast(u8) 1 << dest)) != 0 {
            v1 = zero;
            mask[dest] = srcl;
            for k: 0..3 if (zmask >> k) & 1 mask[k] = cast(u32) (k + 4);
        } else return NONE;
    } else mask[dest] = cast(u32) srcl + 4;
    return icb_shuffle(call_arg(ii, 0), v1, mask);
}
// LowConstantHighUndef
x86_low_const_high_undef :: (v: u64) -> Value_Id {
    return cf_vector(type_vector(2, ir.t_i64, false), .[const_int(ir.t_i64, v), const_undef(ir.t_i64)]);
}
// simplifyX86extrq (cil/cii: ConstantInt or NONE)
x86_simplify_extrq :: (ii: Value_Id, op0: Value_Id, cil: Value_Id, cii: Value_Id) -> Value_Id {
    ci0: Value_Id = NONE;
    if is_const(op0) { e := cf_elt(op0, 0); if e != NONE && vkind(e) == .C_INT ci0 = e; }
    if cil != NONE && cii != NONE {
        index := cast(u32) (const_int_zext(cii) & 63);
        alen := const_int_zext(cil) & 63;
        length: u32 = ifx alen == 0 then 64 else cast(u32) alen;
        if index + length > 64 return const_undef(vtype(ii));
        if length % 8 == 0 && index % 8 == 0 {
            length /= 8; index /= 8;
            st := type_vector(16, ir.t_i8, false);
            mask: [..] u32; mask.allocator = temp;
            ln := cast(s64) length; ix := cast(s64) index;
            for k: 0..ln-1 array_add(*mask, cast(u32) (k + ix));
            for k: ln..7 array_add(*mask, cast(u32) (k + 16));
            for k: 8..15 array_add(*mask, 0xFFFF_FFFF);
            sv := icb_shuffle(icb_cast(.BITCAST, op0, st), const_null_value(st), mask);
            return icb_cast(.BITCAST, sv, vtype(ii));
        }
        if ci0 != NONE {
            e := ap_lshr(const_ap(ci0), index);
            e = ap_zext_or_trunc(e, length);
            return x86_low_const_high_undef(ap_zext_value(e));
        }
        if x86_name(ii) == "llvm.x86.sse4a.extrq" {
            id := intrinsic_lookup_id("llvm.x86.sse4a.extrqi");
            return icb_intrinsic(id, .[], .[op0, cil, cii]);
        }
    }
    if ci0 != NONE && ap_is_zero(const_ap(ci0)) return x86_low_const_high_undef(0);
    return NONE;
}
// simplifyX86insertq
x86_simplify_insertq :: (ii: Value_Id, op0: Value_Id, op1: Value_Id, aplen: APInt, apidx: APInt) -> Value_Id {
    index := cast(u32) (ap_zext_value(apidx) & 63);
    alen := ap_zext_value(aplen) & 63;
    length: u32 = ifx alen == 0 then 64 else cast(u32) alen;
    if index + length > 64 return const_undef(vtype(ii));
    if length % 8 == 0 && index % 8 == 0 {
        length /= 8; index /= 8;
        st := type_vector(16, ir.t_i8, false);
        mask: [..] u32; mask.allocator = temp;
        ln := cast(s64) length; ix := cast(s64) index;
        for k: 0..ix - 1 array_add(*mask, cast(u32) k);
        for k: 0..ln - 1 array_add(*mask, cast(u32) (k + 16));
        for k: ix + ln..7 array_add(*mask, cast(u32) k);
        for k: 8..15 array_add(*mask, 0xFFFF_FFFF);
        sv := icb_shuffle(icb_cast(.BITCAST, op0, st), icb_cast(.BITCAST, op1, st), mask);
        return icb_cast(.BITCAST, sv, vtype(ii));
    }
    ci00: Value_Id = NONE; ci10: Value_Id = NONE;
    if is_const(op0) { e := cf_elt(op0, 0); if e != NONE && vkind(e) == .C_INT ci00 = e; }
    if is_const(op1) { e := cf_elt(op1, 0); if e != NONE && vkind(e) == .C_INT ci10 = e; }
    if ci00 != NONE && ci10 != NONE {
        v00 := const_ap(ci00); v10 := const_ap(ci10);
        mask := ap_shl(ap_low_bits_set(64, length), index);
        v00 = ap_and(v00, ap_not(mask));
        v10 = ap_shl(ap_zext_or_trunc(ap_zext_or_trunc(v10, length), 64), index);
        return x86_low_const_high_undef(ap_zext_value(ap_or(v00, v10)));
    }
    if x86_name(ii) == "llvm.x86.sse4a.insertq" {
        cl := const_int(ir.t_i8, cast(u64) length);
        cx := const_int(ir.t_i8, cast(u64) index);
        id := intrinsic_lookup_id("llvm.x86.sse4a.insertqi");
        return icb_intrinsic(id, .[], .[op0, op1, cl, cx]);
    }
    return NONE;
}
// constant shuffle-control elements: index or -1 (undef); false if not ConstantInt/undef
x86_const_mask_elt :: (v: Value_Id, k: u64) -> (bool, bool, APInt) {
    e := cf_elt(v, k);
    no: APInt;
    if e == NONE return false, false, no;
    if pm_undef_value(e) return true, true, no;
    if vkind(e) != .C_INT return false, false, no;
    return true, false, const_ap(e);
}
// simplifyX86pshufb
x86_simplify_pshufb :: (ii: Value_Id) -> Value_Id {
    v := call_arg(ii, 1);
    if !is_const(v) return NONE;
    vt := vtype(ii);
    n := cast(s64) type_count(vt);
    idx := NewArray(n, u32,, allocator = temp);
    for k: 0..n-1 {
        ok, und, c := x86_const_mask_elt(v, cast(u64) k);
        if !ok return NONE;
        if und { idx[k] = 0xFFFF_FFFF; continue; }
        b := cast,trunc(s8) ap_zext_value(c);
        i := (ifx b < 0 then cast(s64) n else cast(s64) (b & 0x0F)) + (k & 0xF0);
        idx[k] = cast(u32) cast,trunc(u8) i;
    }
    return icb_shuffle(call_arg(ii, 0), const_null_value(vt), idx);
}
// simplifyX86vpermilvar
x86_simplify_vpermilvar :: (ii: Value_Id) -> Value_Id {
    v := call_arg(ii, 1);
    if !is_const(v) return NONE;
    vt := vtype(ii);
    n := cast(s64) type_count(vt);
    is_pd := type_kind(scalar_type(vt)) == .DOUBLE;
    lane_elts: s64 = ifx is_pd then 2 else 4;
    idx := NewArray(n, u32,, allocator = temp);
    for k: 0..n-1 {
        ok, und, c := x86_const_mask_elt(v, cast(u64) k);
        if !ok return NONE;
        if und { idx[k] = 0xFFFF_FFFF; continue; }
        x := ap_zext_value(ap_zext_or_trunc(c, 32)) & 3;
        if is_pd x >>= 1;
        x += cast(u64) ((k / lane_elts) * lane_elts);
        idx[k] = cast(u32) x;
    }
    return icb_shuffle(call_arg(ii, 0), NONE, idx);
}
// simplifyX86vpermv / simplifyX86vpermv3
x86_simplify_vpermv :: (ii: Value_Id, binary: bool) -> Value_Id {
    v := call_arg(ii, 1);
    if !is_const(v) return NONE;
    vt := vtype(ii);
    n := cast(s64) type_count(vt);
    idx := NewArray(n, u32,, allocator = temp);
    m: u64 = ifx binary then cast(u64) (2 * n - 1) else cast(u64) (n - 1);
    for k: 0..n-1 {
        ok, und, c := x86_const_mask_elt(v, cast(u64) k);
        if !ok return NONE;
        if und { idx[k] = 0xFFFF_FFFF; continue; }
        idx[k] = cast(u32) ((ap_zext_value(c) & 0xFFFF_FFFF) & m);
    }
    if binary return icb_shuffle(call_arg(ii, 0), call_arg(ii, 2), idx);
    return icb_shuffle(call_arg(ii, 0), NONE, idx);
}
// simplifyX86VPERMMask
x86_simplify_vperm_mask :: (ii: Value_Id, binary: bool) -> bool {
    vt := vtype(ii);
    ebits := type_bits(scalar_type(vt));
    n := type_count(vt);
    isz := ic_log2_32(ifx binary then 2 * n else n);
    dm := ap_low_bits_set(ebits, isz);
    known := kb_new(ebits);
    return ic_simplify_demanded_bits(ii, 1, dm, *known, ic_q(ii), 0);
}
// InstCombiner::peekThroughBitcast
peek_through_bitcast :: (v: Value_Id, one_use_only := false) -> Value_Id {
    ok, x := pm_cast(v, .BITCAST);
    if ok && (!one_use_only || has_one_use(v)) return x;
    return v;
}
// llvm::scaleShuffleMaskElts (VectorUtils.cpp)
scale_shuffle_mask_elts :: (num_dst: s64, mask: [] u32, out: *[..] u32) -> bool {
    num_src := mask.count;
    if num_src == num_dst { for mask array_add(out, it); return true; }
    if num_src % num_dst != 0 && num_dst % num_src != 0 return false;
    if num_dst > num_src {
        scale := num_dst / num_src;
        for m: mask for j: 0..scale-1 array_add(out, ifx m == 0xFFFF_FFFF then m else cast(u32) (cast(s64) m * scale + j));
        return true;
    }
    // widenShuffleMaskElts
    scale := num_src / num_dst;
    for k: 0..num_dst-1 {
        base: s64 = -1; ok := true;
        for j: 0..scale-1 {
            m := mask[k * scale + j];
            if m == 0xFFFF_FFFF continue;
            sm := cast(s64) m;
            if sm % scale != j { ok = false; break; }
            b := sm / scale;
            if base == -1 base = b; else if base != b { ok = false; break; }
        }
        if !ok return false;
        array_add(out, ifx base < 0 then 0xFFFF_FFFF else cast(u32) base);
    }
    return true;
}

// X86TTIImpl::instCombineIntrinsic: (result, handled) like std::optional<Instruction *>
ic_x86_inst_combine_intrinsic :: (ii: Value_Id) -> (Value_Id, bool) {
    low :: (o: Value_Id, width: u32, dw: u32) -> Value_Id {
        und := ap_zero(width);
        return ic_simplify_demanded_vector_elts(o, ap_low_bits_set(width, dw), *und);
    }
    name := x86_name(ii);
    kind := x86_kind(name);
    if kind == {
    case .BEXTR;
        c := call_arg(ii, 1);
        if cf_is_int(c) {
            shift := const_int_zext(c);
            length := (shift >> 8) & 0xff;
            shift &= 0xff;
            bw := cast(u64) type_int_width(vtype(ii));
            if length == 0 || shift >= bw return ic_replace_inst_uses_with(ii, const_int_of(vtype(ii), 0)), true;
            inc := call_arg(ii, 0);
            if cf_is_int(inc) {
                result := const_int_zext(inc) >> shift;
                if length > bw length = bw;
                result &= ifx length >= 64 then 0xFFFF_FFFF_FFFF_FFFF else ((cast(u64) 1) << length) - 1;
                return ic_replace_inst_uses_with(ii, const_int_of(vtype(ii), result)), true;
            }
        }
    case .BZHI;
        c := call_arg(ii, 1);
        if cf_is_int(c) {
            index := const_int_zext(c) & 0xff;
            bw := cast(u64) type_int_width(vtype(ii));
            if index >= bw return ic_replace_inst_uses_with(ii, call_arg(ii, 0)), true;
            if index == 0 return ic_replace_inst_uses_with(ii, const_int_of(vtype(ii), 0)), true;
            inc := call_arg(ii, 0);
            if cf_is_int(inc) {
                result := const_int_zext(inc) & (((cast(u64) 1) << index) - 1);
                return ic_replace_inst_uses_with(ii, const_int_of(vtype(ii), result)), true;
            }
        }
    case .CVT_SCALAR;
        arg := call_arg(ii, 0);
        vw := cast(u32) type_count(vtype(arg));
        v := low(arg, vw, 1);
        if v != NONE return ic_replace_operand(ii, 0, v), true;
    case .MOVMSK;
        v := x86_simplify_movmsk(ii);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
    case .COMI;
        made := false;
        a0 := call_arg(ii, 0); a1 := call_arg(ii, 1);
        vw := cast(u32) type_count(vtype(a0));
        v := low(a0, vw, 1);
        if v != NONE { ic_replace_operand(ii, 0, v); made = true; }
        v = low(a1, vw, 1);
        if v != NONE { ic_replace_operand(ii, 1, v); made = true; }
        if made return ii, true;
    case .AVX512_ROUND_PACKED;
        r := call_arg(ii, 2);
        if cf_is_int(r) && const_int_zext(r) == 4 {
            a0 := call_arg(ii, 0); a1 := call_arg(ii, 1);
            opc: Opcode = ifx contains(name, ".add.") then .FADD else ifx contains(name, ".sub.") then .FSUB else ifx contains(name, ".mul.") then .FMUL else .FDIV;
            v := icb_binop(opc, a0, a1);
            return ic_replace_inst_uses_with(ii, v), true;
        }
    case .AVX512_MASK_ROUND_SCALAR;
        r := call_arg(ii, 4);
        if cf_is_int(r) && const_int_zext(r) == 4 {
            a0 := call_arg(ii, 0); a1 := call_arg(ii, 1);
            l := icb_extract_element(a0, const_int(ir.t_i64, 0));
            rr := icb_extract_element(a1, const_int(ir.t_i64, 0));
            opc: Opcode = ifx contains(name, ".add.") then .FADD else ifx contains(name, ".sub.") then .FSUB else ifx contains(name, ".mul.") then .FMUL else .FDIV;
            v := icb_binop(opc, l, rr);
            mask := call_arg(ii, 3);
            if !cf_is_int(mask) || !ap_get_bit(const_ap(mask), 0) {
                mt := type_vector(cast(u64) type_int_width(vtype(mask)), ir.t_i1, false);
                m := icb_cast(.BITCAST, mask, mt);
                m = icb_extract_element(m, const_int(ir.t_i64, 0));
                pt := icb_extract_element(call_arg(ii, 2), const_int(ir.t_i64, 0));
                v = icb_select(m, v, pt);
            }
            v = icb_insert_element(a0, v, const_int(ir.t_i64, 0));
            return ic_replace_inst_uses_with(ii, v), true;
        }
    case .MAX_PACKED;
        v := x86_simplify_fp_max_min(ii, IID_MAXNUM);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
    case .MAX_SCALAR;
        v := x86_simplify_fp_max_min(ii, IID_MAXNUM, true);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
    case .MIN_PACKED;
        v := x86_simplify_fp_max_min(ii, IID_MINNUM);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
    case .MIN_SCALAR;
        v := x86_simplify_fp_max_min(ii, IID_MINNUM, true);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
    case .IMM_SHIFT;
        v := x86_simplify_imm_shift(ii);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
    case .VEC_SHIFT;
        v := x86_simplify_imm_shift(ii);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
        a1 := call_arg(ii, 1);
        vw := cast(u32) type_count(vtype(a1));
        v = low(a1, vw, vw / 2);
        if v != NONE return ic_replace_operand(ii, 1, v), true;
    case .VAR_SHIFT;
        v := x86_simplify_var_shift(ii);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
    case .PACKSS;
        v := x86_simplify_pack(ii, true);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
    case .PACKUS;
        v := x86_simplify_pack(ii, false);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
    case .PMULH;
        v := x86_simplify_pmulh(ii, true, false);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
    case .PMULHU;
        v := x86_simplify_pmulh(ii, false, false);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
    case .PMULHRS;
        v := x86_simplify_pmulh(ii, true, true);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
    case .PMADDWD;
        v := x86_simplify_pmadd(ii, true);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
    case .PMADDUBSW;
        v := x86_simplify_pmadd(ii, false);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
    case .PCLMULQDQ;
        c := call_arg(ii, 2);
        if cf_is_int(c) {
            imm := const_int_zext(c);
            made := false;
            a0 := call_arg(ii, 0); a1 := call_arg(ii, 1);
            vw := cast(u32) type_count(vtype(a0));
            u1 := ap_zero(vw);
            d1 := ap_get_splat(vw, ap_from_u64(2, ifx (imm & 0x01) != 0 then cast(u64) 2 else 1));
            v := ic_simplify_demanded_vector_elts(a0, d1, *u1);
            if v != NONE { ic_replace_operand(ii, 0, v); made = true; }
            u2 := ap_zero(vw);
            d2 := ap_get_splat(vw, ap_from_u64(2, ifx (imm & 0x10) != 0 then cast(u64) 2 else 1));
            v = ic_simplify_demanded_vector_elts(a1, d2, *u2);
            if v != NONE { ic_replace_operand(ii, 1, v); made = true; }
            if ap_is_subset_of(d1, u1) || ap_is_subset_of(d2, u2) return ic_replace_inst_uses_with(ii, const_null_value(vtype(ii))), true;
            if made return ii, true;
        }
    case .INSERTPS;
        v := x86_simplify_insertps(ii);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
    case .EXTRQ;
        op0 := call_arg(ii, 0); op1 := call_arg(ii, 1);
        vw0 := cast(u32) type_count(vtype(op0)); vw1 := cast(u32) type_count(vtype(op1));
        cil: Value_Id = NONE; cii: Value_Id = NONE;
        if is_const(op1) {
            e0 := cf_elt(op1, 0); e1 := cf_elt(op1, 1);
            if e0 != NONE && vkind(e0) == .C_INT cil = e0;
            if e1 != NONE && vkind(e1) == .C_INT cii = e1;
        }
        v := x86_simplify_extrq(ii, op0, cil, cii);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
        made := false;
        v = low(op0, vw0, 1);
        if v != NONE { ic_replace_operand(ii, 0, v); made = true; }
        v = low(op1, vw1, 2);
        if v != NONE { ic_replace_operand(ii, 1, v); made = true; }
        if made return ii, true;
    case .EXTRQI;
        op0 := call_arg(ii, 0);
        vw := cast(u32) type_count(vtype(op0));
        cil := call_arg(ii, 1); cii := call_arg(ii, 2);
        if !cf_is_int(cil) cil = NONE;
        if !cf_is_int(cii) cii = NONE;
        v := x86_simplify_extrq(ii, op0, cil, cii);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
        v = low(op0, vw, 1);
        if v != NONE return ic_replace_operand(ii, 0, v), true;
    case .INSERTQ;
        op0 := call_arg(ii, 0); op1 := call_arg(ii, 1);
        vw := cast(u32) type_count(vtype(op0));
        ci11: Value_Id = NONE;
        if is_const(op1) { e := cf_elt(op1, 1); if e != NONE && vkind(e) == .C_INT ci11 = e; }
        if ci11 != NONE {
            v11 := const_ap(ci11);
            len := ap_zext_or_trunc(v11, 6);
            idx := ap_zext_or_trunc(ap_lshr(v11, 8), 6);
            v := x86_simplify_insertq(ii, op0, op1, len, idx);
            if v != NONE return ic_replace_inst_uses_with(ii, v), true;
        }
        v := low(op0, vw, 1);
        if v != NONE return ic_replace_operand(ii, 0, v), true;
    case .INSERTQI;
        op0 := call_arg(ii, 0); op1 := call_arg(ii, 1);
        vw0 := cast(u32) type_count(vtype(op0)); vw1 := cast(u32) type_count(vtype(op1));
        cil := call_arg(ii, 2); cii := call_arg(ii, 3);
        if cf_is_int(cil) && cf_is_int(cii) {
            v := x86_simplify_insertq(ii, op0, op1, ap_zext_or_trunc(const_ap(cil), 6), ap_zext_or_trunc(const_ap(cii), 6));
            if v != NONE return ic_replace_inst_uses_with(ii, v), true;
        }
        made := false;
        v := low(op0, vw0, 1);
        if v != NONE { ic_replace_operand(ii, 0, v); made = true; }
        v = low(op1, vw1, 1);
        if v != NONE { ic_replace_operand(ii, 1, v); made = true; }
        if made return ii, true;
    case .BLENDV;
        bv, bh := x86_blendv(ii); return bv, bh;
    case .PSHUFB;
        v := x86_simplify_pshufb(ii);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
        known := kb_new(8);
        if ic_simplify_demanded_bits(ii, 1, ap_from_u64(8, 0b10001111), *known, ic_q(ii), 0) return ii, true;
    case .VPERMILVAR_PS;
        v := x86_simplify_vpermilvar(ii);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
        known := kb_new(32);
        if ic_simplify_demanded_bits(ii, 1, ap_from_u64(32, 0b00011), *known, ic_q(ii), 0) return ii, true;
    case .VPERMILVAR_PD;
        v := x86_simplify_vpermilvar(ii);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
        known := kb_new(64);
        if ic_simplify_demanded_bits(ii, 1, ap_from_u64(64, 0b00010), *known, ic_q(ii), 0) return ii, true;
    case .VPERMV;
        v := x86_simplify_vpermv(ii, false);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
        if x86_simplify_vperm_mask(ii, false) return ii, true;
    case .VPERMV3;
        v := x86_simplify_vpermv(ii, true);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
        if x86_simplify_vperm_mask(ii, true) return ii, true;
    case .MASKLOAD;
        r := x86_simplify_masked_load(ii);
        if r != NONE return r, true;
    case .MASKSTORE;
        if x86_simplify_masked_store(ii) return NONE, true;
    case .ADDCARRY;
        v := x86_simplify_addcarry(ii);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
    case .PTERNLOG;
        v := x86_simplify_ternarylogic(ii);
        if v != NONE return ic_replace_inst_uses_with(ii, v), true;
    case .VPMADD52;
        acc := call_arg(ii, 0);
        if !pm_zero(acc) || !has_one_use(ii) return NONE, false;
        add := first_user(ii);
        if !is_inst(add) || !is_binary_operator(add) || inst_op(add) != .ADD return NONE, false;
        x: Value_Id = NONE;
        if op(add, 0) == ii x = op(add, 1); else if op(add, 1) == ii x = op(add, 0);
        if x == NONE return NONE, false;
        icb_set_insert_point(add);
        nc := icb_intrinsic(call_iid(ii), .[], .[x, call_arg(ii, 1), call_arg(ii, 2)]);
        ic_replace_inst_uses_with(add, nc);
        ic_erase_inst(add);
        return ic_erase_inst(ii), true;
    }
    return NONE, false;
}

// case blendv
x86_blendv :: (ii: Value_Id) -> (Value_Id, bool) {
    op_ty := vtype(ii);
    op0 := call_arg(ii, 0); op1 := call_arg(ii, 1); mask := call_arg(ii, 2);
    if op0 == op1 return ic_replace_inst_uses_with(ii, op0), true;
    if vkind(mask) == .C_ZERO return ic_replace_inst_uses_with(ii, op0), true;
    k := vkind(mask);
    if k == .C_INT || k == .C_FP || k == .C_DATA {
        ns := x86_negative_is_true_bool_vec(mask);
        s := create_select(ns, op1, op0);
        set_name(s, "blendv");
        return s, true;
    }
    bw := scalar_bits(mask);
    if is_int_or_int_vector(vtype(mask)) {
        known := kb_new(bw);
        if ic_simplify_demanded_bits(ii, 2, ap_signed_min(bw), *known, ic_q(ii), 0) return ii, true;
    } else if is_inst(mask) && inst_op(mask) == .BITCAST {
        if has_one_use(mask) {
            src := op(mask, 0);
            if is_int_or_int_vector(vtype(src)) {
                sbw := scalar_bits(src);
                if sbw == bw {
                    ks := kb_new(sbw);
                    if ic_simplify_demanded_bits(mask, 0, ap_signed_min(sbw), *ks, ic_q(mask), 0) return ii, true;
                }
            }
        }
    }
    mask = peek_through_bitcast(mask);
    oks, s0, s1 := pm_binop(mask, .SHL);
    if oks && is_inst(mask) && type_kind(vtype(mask)) == .VECTOR && scalar_bits(mask) == type_bits(scalar_type(op_ty)) {
        bv := icb_cmp(ICMP_SGT, const_null_value(vtype(mask)), mask);
        sel := icb_select(bv, op1, op0);
        return create_cast(.BITCAST, sel, vtype(ii)), true;
    }
    mask_src: Value_Id = NONE;
    smask: [] u32;
    okh, ms, mu, mm := pm_shuffle(mask);
    if okh && has_one_use(mask) && pm_undef_value(mu) {
        n := cast(s64) type_count(vtype(ms));
        bad := n < mm.count || !ic_is_pow2(cast(u64) n);
        for mm if it == 0xFFFF_FFFF || cast(s64) it >= n bad = true;
        if bad return NONE, false;
        mask_src = ms; smask = mm;
        mask = peek_through_bitcast(ms);
    }
    okx, bool_vec := pmi_cast(mask, .SEXT);
    if okx && is_vector_type(vtype(bool_vec)) && scalar_bits(bool_vec) == 1 {
        mt := vtype(mask);
        nme := cast(s64) type_count(mt);
        noe := cast(s64) type_count(op_ty);
        if mask_src != NONE {
            nms := cast(s64) type_count(vtype(mask_src));
            nme = (smask.count * nme) / nms;
            if nme > noe return NONE, false;
            scaled: [..] u32; scaled.allocator = temp;
            if !scale_shuffle_mask_elts(nme, smask, *scaled) return NONE, false;
            bool_vec = icb_shuffle(bool_vec, NONE, scaled);
            mt = type_vector(cast(u64) nme, type_elem(mt), false);
        }
        if nme == noe return create_select(bool_vec, op1, op0), true;
        if nme < noe {
            c0 := icb_cast(.BITCAST, op0, mt);
            c1 := icb_cast(.BITCAST, op1, mt);
            sel := icb_select(bool_vec, c1, c0);
            return create_cast(.BITCAST, sel, vtype(ii)), true;
        }
    }
    return NONE, false;
}

// X86TTIImpl::simplifyDemandedUseBitsIntrinsic: (value, handled); sets known/computed for movmsk
ic_x86_simplify_demanded_use_bits_intrinsic :: (ii: Value_Id, demanded: APInt, known: *Known_Bits, computed: *bool) -> (Value_Id, bool) {
    if x86_kind(x86_name(ii)) != .MOVMSK return NONE, false;
    arg_width: u32;
    if x86_name(ii) == "llvm.x86.mmx.pmovmskb" arg_width = 8;
    else arg_width = cast(u32) type_count(vtype(call_arg(ii, 0)));
    de := ap_zext_or_trunc(demanded, arg_width);
    if ap_is_zero(de) return const_null_value(vtype(ii)), true;
    known.zero = ap_copy(known.zero);
    ap_set_bits_from(*known.zero, arg_width);
    computed.* = true;
    return NONE, false;
}

// X86TTIImpl::simplifyDemandedVectorEltsIntrinsic: (value, handled)
ic_x86_simplify_demanded_vector_elts_intrinsic :: (ii: Value_Id, demanded_in: APInt, poison: *APInt, poison2: *APInt, poison3: *APInt, depth: u32, made_change: *bool) -> (Value_Id, bool) {
    set_op :: (i: Value_Id, k: u32, dem: APInt, und: *APInt, depth: u32, made_change: *bool) {
        nv := ic_simplify_demanded_vector_elts(op(i, k), dem, und, depth + 1);
        if nv != NONE { ic_replace_operand(i, k, nv); made_change.* = true; }
    }
    demanded := demanded_in;
    vw := cast(u32) type_count(vtype(ii));
    name := x86_name(ii);
    n := slice(name, 9, name.count - 9);   // after "llvm.x86."
    is_one_of :: (n: string, names: ..string) -> bool { for names if n == it return true; return false; }
    if is_one_of(n, "xop.vfrcz.ss", "xop.vfrcz.sd") {
        if !ap_get_bit(demanded, 0) { wl_add(ii); return const_null_value(vtype(ii)), true; }
        demanded = ap_from_u64(vw, 1);
        set_op(ii, 0, demanded, poison, depth, made_change);
        b := ap_get_bit(poison.*, 0);
        poison.* = ap_zero(vw);
        if b ap_set_bit(poison, 0);
    } else if is_one_of(n, "sse.rcp.ss", "sse.rsqrt.ss") {
        set_op(ii, 0, demanded, poison, depth, made_change);
        if !ap_get_bit(demanded, 0) { wl_add(ii); return call_arg(ii, 0), true; }
    } else if is_one_of(n, "sse.min.ss", "sse.max.ss", "sse.cmp.ss", "sse2.min.sd", "sse2.max.sd", "sse2.cmp.sd") {
        set_op(ii, 0, demanded, poison, depth, made_change);
        if !ap_get_bit(demanded, 0) { wl_add(ii); return call_arg(ii, 0), true; }
        demanded = ap_from_u64(vw, 1);
        set_op(ii, 1, demanded, poison2, depth, made_change);
        if !ap_get_bit(poison2.*, 0) { poison.* = ap_copy(poison.*); ap_clear_bit(poison, 0); }
    } else if is_one_of(n, "sse41.round.ss", "sse41.round.sd") {
        d2 := ap_copy(demanded); ap_clear_bit(*d2, 0);
        set_op(ii, 0, d2, poison, depth, made_change);
        if !ap_get_bit(demanded, 0) { wl_add(ii); return call_arg(ii, 0), true; }
        demanded = ap_from_u64(vw, 1);
        set_op(ii, 1, demanded, poison2, depth, made_change);
        poison.* = ap_copy(poison.*); ap_clear_bit(poison, 0);
        if ap_get_bit(poison2.*, 0) ap_set_bit(poison, 0);
    } else if is_one_of(n, "avx512.mask.add.ss.round", "avx512.mask.div.ss.round", "avx512.mask.mul.ss.round", "avx512.mask.sub.ss.round",
                        "avx512.mask.max.ss.round", "avx512.mask.min.ss.round", "avx512.mask.add.sd.round", "avx512.mask.div.sd.round",
                        "avx512.mask.mul.sd.round", "avx512.mask.sub.sd.round", "avx512.mask.max.sd.round", "avx512.mask.min.sd.round") {
        set_op(ii, 0, demanded, poison, depth, made_change);
        if !ap_get_bit(demanded, 0) { wl_add(ii); return call_arg(ii, 0), true; }
        demanded = ap_from_u64(vw, 1);
        set_op(ii, 1, demanded, poison2, depth, made_change);
        set_op(ii, 2, demanded, poison3, depth, made_change);
        if !ap_get_bit(poison2.*, 0) || !ap_get_bit(poison3.*, 0) { poison.* = ap_copy(poison.*); ap_clear_bit(poison, 0); }
    } else if is_one_of(n, "sse3.addsub.pd", "sse3.addsub.ps", "avx.addsub.pd.256", "avx.addsub.ps.256") {
        sub_mask := ap_get_splat(vw, ap_from_u64(2, 1));
        add_mask := ap_get_splat(vw, ap_from_u64(2, 2));
        sub_only := ap_is_subset_of(demanded, sub_mask);
        add_only := ap_is_subset_of(demanded, add_mask);
        if sub_only || add_only {
            saved := ic.b; defer ic.b = saved;
            icb_set_insert_point(ii);
            return icb_binop(ifx sub_only then Opcode.FSUB else .FADD, call_arg(ii, 0), call_arg(ii, 1)), true;
        }
        set_op(ii, 0, demanded, poison, depth, made_change);
        set_op(ii, 1, demanded, poison2, depth, made_change);
        poison.* = ap_and(poison.*, poison2.*);
    } else if is_one_of(n, "avx2.psllv.d", "avx2.psllv.d.256", "avx2.psllv.q", "avx2.psllv.q.256", "avx2.psrlv.d", "avx2.psrlv.d.256",
                        "avx2.psrlv.q", "avx2.psrlv.q.256", "avx2.psrav.d", "avx2.psrav.d.256") {
        set_op(ii, 0, demanded, poison, depth, made_change);
        set_op(ii, 1, demanded, poison2, depth, made_change);
        poison.* = ap_and(poison.*, poison2.*);
    } else if is_one_of(n, "sse2.pmulh.w", "avx2.pmulh.w", "avx512.pmulh.w.512", "sse2.pmulhu.w", "avx2.pmulhu.w", "avx512.pmulhu.w.512",
                        "ssse3.pmul.hr.sw.128", "avx2.pmul.hr.sw", "avx512.pmul.hr.sw.512") {
        set_op(ii, 0, demanded, poison, depth, made_change);
        set_op(ii, 1, demanded, poison2, depth, made_change);
    } else if x86_kind(name) == .PACKSS || x86_kind(name) == .PACKUS {
        ty0 := vtype(call_arg(ii, 0));
        inner := cast(u32) type_count(ty0);
        lanes := cast(u32) (ic_prim_bits(ty0) / 128);
        vw_lane := vw / lanes;
        inner_lane := inner / lanes;
        for opn: 0..1 {
            od := ap_zero(inner);
            for lane: 0..lanes-1 {
                li := lane * vw_lane;
                for e: 0..inner_lane-1 {
                    idx := li + e + inner_lane * cast(u32) opn;
                    if ap_get_bit(demanded, idx) ap_set_bit(*od, lane * inner_lane + e);
                }
            }
            ou := ap_zero(inner);
            set_op(ii, cast(u32) opn, od, *ou, depth, made_change);
            ou = ap_zext(ou, vw);
            for lane: 0..lanes-1 {
                le := ap_lshr(ou, inner_lane * lane);
                le = ap_get_lo_bits(le, inner_lane);
                le = ap_shl(le, inner_lane * (2 * lane + cast(u32) opn));
                poison.* = ap_or(poison.*, le);
            }
        }
    } else if x86_kind(name) == .PMADDWD || x86_kind(name) == .PMADDUBSW {
        inner := cast(u32) type_count(vtype(call_arg(ii, 0)));
        od := ap_scale_bit_mask(demanded, inner);
        u0 := ap_zero(inner); u1 := ap_zero(inner);
        set_op(ii, 0, od, *u0, depth, made_change);
        set_op(ii, 1, od, *u1, depth, made_change);
    } else if x86_kind(name) == .PSHUFB || x86_kind(name) == .VPERMILVAR_PS || x86_kind(name) == .VPERMILVAR_PD || n == "avx2.permd" || n == "avx2.permps" {
        set_op(ii, 1, demanded, poison, depth, made_change);
    } else if is_one_of(n, "sse4a.extrq", "sse4a.extrqi", "sse4a.insertq", "sse4a.insertqi") {
        poison.* = ap_copy(poison.*);
        ap_set_high_bits(poison, vw / 2);
    }
    return NONE, false;
}
