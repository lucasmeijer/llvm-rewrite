// ExpandVectorPredication: a port of llvm/lib/CodeGen/ExpandVectorPredication.cpp (CachingVPExpander:
// convertEVLToMask, discardEVLParameter, foldEVLIntoMask, expandPredication with the binary-op, int-call,
// fp-call, reduction, cast, memory and comparison lowerings, sanitizeStrategy, getVPLegalizationStrategy with
// -expandvp-override-evl-transform / -expandvp-override-mask-transform) and the VPIntrinsic queries of
// llvm/lib/IR/IntrinsicInst.cpp (getMaskParamPos, getVectorLengthParamPos, getStaticVectorLength,
// canIgnoreVectorLengthParam, getFunctionalOpcodeForVP, getFunctionalIntrinsicIDForVP,
// getConstrainedIntrinsicIDForVP, the memory / reduction / comparison operand positions) over the table that
// gen/gen_vp.py generates from VPIntrinsics.def (gen_vp.jai), plus getReductionIdentity from LoopUtils.cpp.
//
// TTI::getVPLegalizationStrategy is the TargetTransformInfoImplBase one (x86 does not override it): the %evl is
// discarded and the operation converted. Constrained-FP replacements fail loudly.

VP_LEGAL :: 0; VP_DISCARD :: 1; VP_CONVERT :: 2;
vp_cl: struct { evl_override: string; mask_override: string; };

vp_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == "expandvp-override-evl-transform" { vp_cl.evl_override = copy_string(value); return true; }
    if name == "expandvp-override-mask-transform" { vp_cl.mask_override = copy_string(value); return true; }
    return false;
}
vp_parse_override :: (s: string) -> s64 {
    if s == "Legal" return VP_LEGAL;
    if s == "Discard" return VP_DISCARD;
    if s == "Convert" return VP_CONVERT;
    fatal("expandvp: invalid override value '%' (expected Legal, Discard or Convert)", s);
    return 0;
}

vp_info_of :: (ci: Value_Id) -> *Vp_Info {
    name := intrinsic_name(call_iid(ci));
    for * VP_INFOS if it.name == name return it;
    return null;
}
vp_mask_param :: (ci: Value_Id, vi: *Vp_Info) -> Value_Id { if vi.mask_pos < 0 return NONE; return call_arg(ci, cast(u32) vi.mask_pos); }
vp_evl_param :: (ci: Value_Id, vi: *Vp_Info) -> Value_Id { if vi.evl_pos < 0 return NONE; return call_arg(ci, cast(u32) vi.evl_pos); }
vp_is_reduction :: (vi: *Vp_Info) -> bool { return begins_with(vi.name, "llvm.vp.reduce."); }
vp_is_cmp :: (vi: *Vp_Info) -> bool { return vi.name == "llvm.vp.fcmp" || vi.name == "llvm.vp.icmp"; }
vp_is_cast :: (vi: *Vp_Info) -> bool { return vi.opcode != .NONE_OP && is_cast_op(vi.opcode); }

// getStaticVectorLength: (known minimum, scalable)
vp_static_vector_length :: (ci: Value_Id, vi: *Vp_Info) -> (u64, bool) {
    m := vp_mask_param(ci, vi);
    t := ifx m != NONE then vtype(m) else vtype(ci);
    return type_count(t), type_kind(t) == .SVECTOR;
}
// m_VScale
vp_is_vscale :: (v: Value_Id) -> bool { return is_inst(v) && inst_op(v) == .CALL && call_iid(v) == IID_VSCALE; }
// canIgnoreVectorLengthParam
vp_can_ignore_evl :: (ci: Value_Id, vi: *Vp_Info) -> bool {
    n, scalable := vp_static_vector_length(ci, vi);
    vl := vp_evl_param(ci, vi);
    if vl == NONE return true;
    if scalable {
        if is_inst(vl) && inst_op(vl) == .MUL {
            a := op(vl, 0); c := op(vl, 1);
            if vp_is_vscale(a) && vkind(c) == .C_INT && !is_vector_type(vtype(c)) return const_int_zext(c) >= n;
        }
        return n == 1 && vp_is_vscale(vl);
    }
    if vkind(vl) != .C_INT return false;
    return const_int_zext(vl) >= n;
}

// isAllTrueMask
vp_is_all_true_mask :: (m: Value_Id) -> bool {
    s := get_splat_value(m);
    return s != NONE && is_constant_kind(vkind(s)) && vkind(s) == .C_INT && ap_is_all_ones(const_ap(s));
}

// maySpeculateLanes
vp_may_speculate_lanes :: (ci: Value_Id, vi: *Vp_Info) -> bool {
    if vp_is_reduction(vi) return false;
    if vi.intr.count {
        s := intrinsic_fn_attr_set(intrinsic_id_by_name(vi.intr));
        return attr_set_has(s, .Speculatable);
    }
    if vi.opcode != .NONE_OP {
        o := vi.opcode;
        if o == .UDIV || o == .UREM {
            ok, v := pm_apint(op(ci, 1));
            return ok && !ap_is_zero(v);
        }
        if o == .SDIV || o == .SREM {
            ok, d := pm_apint(op(ci, 1));
            if !ok || ap_is_zero(d) return false;
            if !ap_is_all_ones(d) return true;
            okn, num := pm_apint(op(ci, 0));
            if okn return !ap_is_min_signed(num);
            return false;
        }
        if o == .LOAD || o == .STORE return false;
        return true;
    }
    return false;
}

// a splat of `v` with `n` (known minimum) lanes (CreateVectorSplat)
vp_splat :: (b: *Irb, n: u64, scalable: bool, v: Value_Id, name: string = "") -> Value_Id {
    vt := type_vector(n, vtype(v), scalable);
    x := irb_insert_element(b, const_poison(vt), v, 0, tconcat(name, ".splatinsert"));
    zeros := NewArray(cast(s64) n, u32,, allocator = temp);
    return irb_shuffle(b, x, NONE, zeros, tconcat(name, ".splat"));
}
// CreateIntrinsic(ID, OverloadTypes, Args)
vp_intrinsic :: (b: *Irb, id: Intrinsic_Id, otys: [] Type_Id, args: [] Value_Id, name := "") -> Value_Id {
    f := get_or_insert_intrinsic_declaration(id, otys);
    return irb_call(b, f, args, name);
}
// CreateIntrinsic(RetTy, ID, Args): the overload types come from matching the signature
vp_intrinsic_ret :: (b: *Irb, ret: Type_Id, id: Intrinsic_Id, args: [] Value_Id) -> Value_Id {
    tys: [..] Type_Id; tys.allocator = temp;
    for args array_add(*tys, vtype(it));
    ft := type_func(ret, tys, false);
    otys: [..] Type_Id; otys.allocator = temp;
    if !intrinsic_signature_valid(id, ft, *otys) fatal("internal: expandvp: no signature for % (%)", intrinsic_name(id), type_to_string(ft));
    f := get_or_insert_intrinsic_declaration_ft(id, otys, ft);
    return irb_call(b, f, args);
}

// convertEVLToMask
vp_convert_evl_to_mask :: (b: *Irb, evl: Value_Id, n: u64, scalable: bool) -> Value_Id {
    if scalable {
        bool_vec := type_vector(n, ir.t_i1, true);
        return vp_intrinsic(b, IID_GET_ACTIVE_LANE_MASK, .[bool_vec, vtype(evl)], .[const_int(ir.t_i32, 0), evl]);
    }
    lane := vtype(evl);
    splat := vp_splat(b, n, false, evl);
    idx := NewArray(cast(s64) n, Value_Id,, temp);
    for k: 0..cast(s64) n - 1 idx[k] = const_int(lane, cast(u64) k);
    step := const_vector(idx);
    return irb_icmp(b, ICMP_ULT, step, splat);
}

// discardEVLParameter
vp_discard_evl :: (ci: Value_Id, vi: *Vp_Info) -> bool {
    if vp_can_ignore_evl(ci, vi) return false;
    evl := vp_evl_param(ci, vi);
    if evl == NONE return false;
    n, scalable := vp_static_vector_length(ci, vi);
    max_evl: Value_Id;
    if scalable {
        b: Irb; irb_set_at(*b, inst_block(ci), ci, false);
        factor := const_int(ir.t_i32, n);
        vscale := vp_intrinsic(*b, IID_VSCALE, .[ir.t_i32], .[], "vscale");
        max_evl = irb_binop(*b, .MUL, vscale, factor, "scalable_size", F_NUW);
    } else {
        max_evl = const_int(ir.t_i32, n);
    }
    set_op(ci, cast(u32) vi.evl_pos, max_evl);
    return true;
}

// foldEVLIntoMask
vp_fold_evl_into_mask :: (ci: Value_Id, vi: *Vp_Info) -> bool {
    b: Irb; irb_set_before(*b, ci);
    if vp_can_ignore_evl(ci, vi) return false;
    old_mask := vp_mask_param(ci, vi);
    is_sel := vi.name == "llvm.vp.merge" || vi.name == "llvm.vp.select";
    if old_mask == NONE old_mask = call_arg(ci, 0);
    old_evl := vp_evl_param(ci, vi);
    n, scalable := vp_static_vector_length(ci, vi);
    vl_mask := vp_convert_evl_to_mask(*b, old_evl, n, scalable);
    new_mask := irb_binop(*b, .AND, vl_mask, old_mask);
    if is_sel set_op(ci, 0, new_mask);
    else set_op(ci, cast(u32) vi.mask_pos, new_mask);
    vp_discard_evl(ci, vi);
    return true;
}

// replaceOperation (with transferDecorations)
vp_replace_operation :: (nv: Value_Id, ci: Value_Id) {
    if is_inst(nv) && is_fp_math_inst(nv) && is_fp_math_inst(ci) set_fmf(nv, inst_fmf(ci));
    if is_inst(nv) && vname(nv).count == 0 && vname(ci).count take_name(nv, ci);
    replace_all_uses_with(ci, nv);
    erase_inst(ci);
}

// getMinMaxReductionIntrinsicOp
vp_min_max_reduction_op :: (id: Intrinsic_Id) -> Intrinsic_Id {
    if id == {
        case IID_VECTOR_REDUCE_UMIN; return IID_UMIN;
        case IID_VECTOR_REDUCE_UMAX; return IID_UMAX;
        case IID_VECTOR_REDUCE_SMIN; return IID_SMIN;
        case IID_VECTOR_REDUCE_SMAX; return IID_SMAX;
        case IID_VECTOR_REDUCE_FMIN; return intrinsic_id_by_name("llvm.minnum");
        case IID_VECTOR_REDUCE_FMAX; return intrinsic_id_by_name("llvm.maxnum");
        case IID_VECTOR_REDUCE_FMINIMUM; return intrinsic_id_by_name("llvm.minimum");
        case IID_VECTOR_REDUCE_FMAXIMUM; return intrinsic_id_by_name("llvm.maximum");
    }
    fatal("internal: expandvp: unknown min/max reduction");
    return 0;
}
// getReductionIdentity
vp_reduction_identity :: (id: Intrinsic_Id, t: Type_Id, fmf: u32) -> Value_Id {
    if id == IID_VECTOR_REDUCE_ADD || id == IID_VECTOR_REDUCE_MUL || id == IID_VECTOR_REDUCE_OR || id == IID_VECTOR_REDUCE_XOR ||
       id == IID_VECTOR_REDUCE_AND || id == IID_VECTOR_REDUCE_FADD || id == IID_VECTOR_REDUCE_FMUL
        return ic_binop_identity_nsz(arithmetic_reduction_instruction(id), t, false, (fmf & FMF_NSZ) != 0);
    if id == IID_VECTOR_REDUCE_UMAX || id == IID_VECTOR_REDUCE_UMIN || id == IID_VECTOR_REDUCE_SMIN || id == IID_VECTOR_REDUCE_SMAX {
        s := vp_min_max_reduction_op(id);
        bits := type_bits(t);
        if s == IID_UMAX return const_int(t, 0);
        if s == IID_UMIN return const_all_ones_of(t);
        if s == IID_SMAX return const_ap_int(t, ap_signed_min(bits));
        return const_ap_int(t, ap_signed_max(bits));
    }
    negative := id == IID_VECTOR_REDUCE_FMAX || id == IID_VECTOR_REDUCE_FMAXIMUM;
    propagates_nan := id == IID_VECTOR_REDUCE_FMINIMUM || id == IID_VECTOR_REDUCE_FMAXIMUM;
    if (fmf & FMF_NNAN) == 0 && !propagates_nan return const_fp_qnan(t, negative);
    if (fmf & FMF_NINF) == 0 return const_fp_inf(t, negative);
    return const_fp_largest(t, negative);
}

// expandPredication
vp_expand_predication :: (ci: Value_Id, vi: *Vp_Info) -> bool {
    b: Irb; irb_set_before(*b, ci);
    o := vi.opcode;
    if o != .NONE_OP && is_binary_op(o) {
        op0 := op(ci, 0); op1 := op(ci, 1);
        mask := vp_mask_param(ci, vi);
        if mask != NONE && !vp_is_all_true_mask(mask) {
            if o == .UDIV || o == .SDIV || o == .UREM || o == .SREM op1 = irb_select(*b, mask, op1, const_splat_int(vtype(ci), 1));
        }
        vp_replace_operation(irb_binop(*b, o, op0, op1), ci);
        return true;
    }
    if vp_is_reduction(vi) {
        mask := vp_mask_param(ci, vi);
        red_op := call_arg(ci, 1);
        rid := intrinsic_id_by_name(vi.intr);
        if mask != NONE && !vp_is_all_true_mask(mask) {
            fmf: u32 = 0;
            if is_fp_math_inst(ci) fmf = inst_fmf(ci);
            neutral := vp_reduction_identity(rid, vtype(ci), fmf);
            rt := vtype(red_op);
            nvec := vp_splat(*b, type_count(rt), type_kind(rt) == .SVECTOR, neutral);
            red_op = irb_select(*b, mask, red_op, nvec);
        }
        start := call_arg(ci, 0);
        red: Value_Id;
        name := vi.name;
        if name == "llvm.vp.reduce.add" || name == "llvm.vp.reduce.mul" || name == "llvm.vp.reduce.and" || name == "llvm.vp.reduce.or" || name == "llvm.vp.reduce.xor" {
            opc := arithmetic_reduction_instruction(rid);
            red = vp_intrinsic(*b, rid, .[vtype(red_op)], .[red_op]);
            red = irb_binop(*b, opc, red, start);
        } else if name == "llvm.vp.reduce.fadd" || name == "llvm.vp.reduce.fmul" {
            red = vp_intrinsic(*b, rid, .[vtype(red_op)], .[start, red_op]);
        } else {
            sid := vp_min_max_reduction_op(rid);
            red = vp_intrinsic(*b, rid, .[vtype(red_op)], .[red_op]);
            if is_inst(red) && is_fp_math_inst(red) && is_fp_math_inst(ci) set_fmf(red, inst_fmf(ci));
            red = vp_intrinsic(*b, sid, .[vtype(red)], .[red, start]);
        }
        vp_replace_operation(red, ci);
        return true;
    }
    if vp_is_cmp(vi) {
        m := call_md_arg(ci, 2);
        pred := vp_cmp_predicate(m, vi.name == "llvm.vp.fcmp");
        nc: Value_Id;
        if vi.name == "llvm.vp.fcmp" nc = irb_insert(*b, create_fcmp(pred, op(ci, 0), op(ci, 1)));
        else nc = irb_icmp(*b, pred, op(ci, 0), op(ci, 1));
        vp_replace_operation(nc, ci);
        return true;
    }
    if vp_is_cast(vi) {
        vp_replace_operation(irb_cast(*b, o, op(ci, 0), vtype(ci)), ci);
        return true;
    }
    name := vi.name;
    if name == "llvm.vp.fneg" {
        n := new_inst(.FNEG, vtype(ci), 1);
        set_op(n, 0, op(ci, 0));
        vp_replace_operation(irb_insert(*b, n), ci);
        return true;
    }
    if name == "llvm.vp.select" || name == "llvm.vp.merge" {
        vp_replace_operation(irb_select(*b, op(ci, 0), op(ci, 1), op(ci, 2)), ci);
        return true;
    }
    if name == "llvm.vp.abs" || name == "llvm.vp.smax" || name == "llvm.vp.smin" || name == "llvm.vp.umax" || name == "llvm.vp.umin" ||
       name == "llvm.vp.bswap" || name == "llvm.vp.bitreverse" || name == "llvm.vp.ctpop" || name == "llvm.vp.ctlz" ||
       name == "llvm.vp.cttz" || name == "llvm.vp.sadd.sat" || name == "llvm.vp.uadd.sat" || name == "llvm.vp.ssub.sat" ||
       name == "llvm.vp.usub.sat" || name == "llvm.vp.fshl" || name == "llvm.vp.fshr" {
        if vi.intr.count == 0 return false;
        args: [..] Value_Id; args.allocator = temp;
        for k: 0..cast(s64) nops(ci) - 4 array_add(*args, op(ci, cast(u32) k));
        vp_replace_operation(vp_intrinsic(*b, intrinsic_id_by_name(vi.intr), .[vtype(ci)], args), ci);
        return true;
    }
    if name == "llvm.vp.fabs" || name == "llvm.vp.copysign" || name == "llvm.vp.sqrt" || name == "llvm.vp.maxnum" ||
       name == "llvm.vp.minnum" || name == "llvm.vp.maximum" || name == "llvm.vp.minimum" || name == "llvm.vp.ceil" ||
       name == "llvm.vp.floor" || name == "llvm.vp.round" || name == "llvm.vp.roundeven" || name == "llvm.vp.roundtozero" ||
       name == "llvm.vp.rint" || name == "llvm.vp.nearbyint" || name == "llvm.vp.lrint" || name == "llvm.vp.llrint" ||
       name == "llvm.vp.fma" || name == "llvm.vp.fmuladd" || name == "llvm.vp.is.fpclass" {
        return vp_expand_to_fp_call(*b, ci, intrinsic_id_by_name(vi.intr));
    }
    if name == "llvm.vp.load" || name == "llvm.vp.store" || name == "llvm.vp.gather" || name == "llvm.vp.scatter" {
        vp_expand_memory(*b, ci, vi);
        return true;
    }
    if vi.cfp.count {
        if vp_expand_to_fp_call(*b, ci, intrinsic_id_by_name(vi.cfp)) return true;
    }
    return false;
}

// expandPredicationToFPCall
vp_expand_to_fp_call :: (b: *Irb, ci: Value_Id, id: Intrinsic_Id) -> bool {
    name := intrinsic_name(id);
    if begins_with(name, "llvm.experimental.constrained.") fatal("expandvp: lowering to constrained FP intrinsic % is not supported yet", name);
    if name == "llvm.fma" || name == "llvm.fmuladd" {
        f := get_or_insert_intrinsic_declaration(id, .[vtype(ci)]);
        vp_replace_operation(irb_call(b, f, .[op(ci, 0), op(ci, 1), op(ci, 2)]), ci);
        return true;
    }
    if name == "llvm.fabs" || name == "llvm.copysign" || name == "llvm.sqrt" || name == "llvm.maxnum" || name == "llvm.minnum" ||
       name == "llvm.maximum" || name == "llvm.minimum" || name == "llvm.ceil" || name == "llvm.floor" || name == "llvm.round" ||
       name == "llvm.roundeven" || name == "llvm.trunc" || name == "llvm.rint" || name == "llvm.nearbyint" || name == "llvm.lrint" ||
       name == "llvm.llrint" || name == "llvm.is.fpclass" {
        args: [..] Value_Id; args.allocator = temp;
        for k: 0..cast(s64) nops(ci) - 4 array_add(*args, op(ci, cast(u32) k));
        vp_replace_operation(vp_intrinsic_ret(b, vtype(ci), id, args), ci);
        return true;
    }
    return false;
}

// expandPredicationInMemoryIntrinsic
vp_expand_memory :: (b: *Irb, ci: Value_Id, vi: *Vp_Info) {
    mask := vp_mask_param(ci, vi);
    is_store := vi.name == "llvm.vp.store" || vi.name == "llvm.vp.scatter";
    ptr_pos: u32 = ifx is_store then cast(u32) 1 else 0;
    ptr := call_arg(ci, ptr_pos);
    data := ifx is_store then call_arg(ci, 0) else NONE;
    unmasked := vp_is_all_true_mask(mask);
    al := call_param_attr(ci, ptr_pos, .Alignment);
    align: u64 = ifx al then al.ival else 0;
    nm: Value_Id;
    if vi.name == "llvm.vp.store" {
        if unmasked {
            nm = irb_store(b, data, ptr, ifx align then align else dl_alignment(vtype(data), true));
        } else {
            nm = vp_intrinsic(b, intrinsic_id_by_name("llvm.masked.store"), .[vtype(data), vtype(ptr)], .[data, ptr, mask]);
            add_param_int_attr_call(nm, 1, .Alignment, ifx align then align else 1);
        }
    } else if vi.name == "llvm.vp.load" {
        if unmasked {
            nm = irb_load(b, vtype(ci), ptr, ifx align then align else dl_alignment(vtype(ci), true));
        } else {
            nm = vp_intrinsic(b, intrinsic_id_by_name("llvm.masked.load"), .[vtype(ci), vtype(ptr)], .[ptr, mask, const_poison(vtype(ci))]);
            add_param_int_attr_call(nm, 0, .Alignment, ifx align then align else 1);
        }
    } else if vi.name == "llvm.vp.scatter" {
        et := type_elem(vtype(data));
        nm = vp_intrinsic(b, intrinsic_id_by_name("llvm.masked.scatter"), .[vtype(data), vtype(ptr)], .[data, ptr, mask]);
        add_param_int_attr_call(nm, 1, .Alignment, ifx align then align else dl_pref_align(et));
    } else {
        et := type_elem(vtype(ci));
        nm = vp_intrinsic(b, intrinsic_id_by_name("llvm.masked.gather"), .[vtype(ci), vtype(ptr)], .[ptr, mask, const_poison(vtype(ci))]);
        add_param_int_attr_call(nm, 0, .Alignment, ifx align then align else dl_pref_align(et));
    }
    vp_replace_operation(nm, ci);
}
add_param_int_attr_call :: (c: Value_Id, k: u32, kind: Attr_Kind, v: u64) {
    l := inst(c).attrs;
    a: Attr; a.kind = kind; a.ty = NONE; a.ival = v;
    inst(c).attrs = attr_list_with_param(l, k, attr_set_with(attr_list_param(l, k), a));
}

// VPCmpIntrinsic::getPredicate (getFPPredicateFromMD / getIntPredicateFromMD)
vp_cmp_predicate :: (m: Md_Id, fp: bool) -> u8 {
    s := "";
    if m != NONE && ir.mds[m].kind == .STRING s = ir.mds[m].str;
    if fp {
        names :: string.["false", "oeq", "ogt", "oge", "olt", "ole", "one", "ord", "uno", "ueq", "ugt", "uge", "ult", "ule", "une", "true"];
        for names if it == s return cast(u8) it_index;
        fatal("expandvp: bad fcmp predicate '%'", s);
    }
    inames :: string.["eq", "ne", "ugt", "uge", "ult", "ule", "sgt", "sge", "slt", "sle"];
    ipreds :: u8.[ICMP_EQ, ICMP_NE, ICMP_UGT, ICMP_UGE, ICMP_ULT, ICMP_ULE, ICMP_SGT, ICMP_SGE, ICMP_SLT, ICMP_SLE];
    for inames if it == s return ipreds[it_index];
    fatal("expandvp: bad icmp predicate '%'", s);
    return 0;
}

// CachingVPExpander::expandVectorPredication: (changed, intrinsic replaced)
vp_expand_vector_predication :: (ci: Value_Id) -> (bool, bool) {
    vi := vp_info_of(ci);
    if !vi fatal("internal: expandvp: no VP info for %", intrinsic_name(call_iid(ci)));
    evl_s := VP_DISCARD; op_s := VP_CONVERT;
    if vp_cl.evl_override.count || vp_cl.mask_override.count {
        evl_s = vp_parse_override(vp_cl.evl_override);
        op_s = vp_parse_override(vp_cl.mask_override);
    }
    // sanitizeStrategy
    if vp_may_speculate_lanes(ci, vi) {
        if op_s == VP_CONVERT evl_s = VP_DISCARD;
    } else if evl_s == VP_DISCARD || op_s == VP_CONVERT {
        evl_s = VP_CONVERT;
    }
    changed := false;
    if evl_s == VP_DISCARD { if vp_discard_evl(ci, vi) changed = true; }
    else if evl_s == VP_CONVERT { if vp_fold_evl_into_mask(ci, vi) changed = true; }
    if op_s == VP_DISCARD fatal("expandvp: Discard is not a valid strategy for operators");
    if op_s == VP_CONVERT {
        if vp_expand_predication(ci, vi) return true, true;
    }
    return changed, false;
}

const_vector :: (elts: [] Value_Id) -> Value_Id { return const_aggregate(.C_VECTOR, type_vector(cast(u64) elts.count, vtype(elts[0]), false), elts); }
const_splat_int :: (vt: Type_Id, v: u64) -> Value_Id { return cf_int(vt, ap_from_u64(type_int_width(scalar_type(vt)), v)); }
const_ap_int :: (t: Type_Id, a: APInt) -> Value_Id { return cf_int(t, a); }
const_fp_qnan :: (t: Type_Id, neg: bool) -> Value_Id { return const_fp_words(t, fp_qnan_with_payload(type_kind(t), neg, ap_zero(64))); }
const_fp_inf :: (t: Type_Id, neg: bool) -> Value_Id { return const_fp_words(t, fp_inf(type_kind(t), neg)); }
const_fp_largest :: (t: Type_Id, neg: bool) -> Value_Id { return const_fp_words(t, fp_largest(type_kind(t), neg)); }
