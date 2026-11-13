// BasicTTIImplBase::getIntrinsicInstrCost and getTypeBasedIntrinsicInstrCost, ported from
// llvm/include/llvm/CodeGen/BasicTTIImpl.h. thisT() is always X86TTIImpl here (the only target), so the
// recursive queries call the x86_* entry points. VP intrinsics, masked/strided/gather memory intrinsics,
// histograms, cttz.elts, loop.dependence masks and multiple-result vector libcalls fail loudly.

iidn :: (name: string) -> Intrinsic_Id { return intrinsic_id_by_name(name); }

// IntrinsicCostAttributes(Id, RTy, Tys, Flags, I, ScalarCost): type-based (no arguments)
ica_types :: (id: Intrinsic_Id, ret: Type_Id, tys: [] Type_Id, fmf: u32 = 0, inst: Value_Id = NONE, scalar_cost := COST_INVALID) -> Ica {
    a: Ica;
    a.id = id; a.ret = ret; a.fmf = fmf; a.inst = inst; a.scalar_cost = scalar_cost; a.type_based_only = true;
    t := NewArray(tys.count, Type_Id,, temp);
    for tys t[it_index] = it;
    a.tys = t;
    return a;
}
ica_is_type_based :: (ica: *Ica) -> bool { return ica.type_based_only || ica.args.count == 0; }

// isVectorizedTy / getContainedTypes / getVectorizedTypeVF
is_vectorized_ty :: (t: Type_Id) -> bool {
    if is_vector_type(t) return true;
    if type_kind(t) == .STRUCT {
        n := type_num_elems(t);
        if n == 0 return false;
        for k: 0..n-1 if !is_vector_type(type_sub(t, cast(u32) k)) return false;
        // all elements must share the element count
        c := type_count(type_sub(t, 0));
        for k: 0..n-1 if type_count(type_sub(t, cast(u32) k)) != c return false;
        return true;
    }
    return false;
}
contained_types :: (t: Type_Id) -> [] Type_Id {
    if type_kind(t) == .STRUCT {
        n := type_num_elems(t);
        r := NewArray(n, Type_Id,, temp);
        for k: 0..n-1 r[k] = type_sub(t, cast(u32) k);
        return r;
    }
    r := NewArray(1, Type_Id,, temp); r[0] = t; return r;
}
type_num_elems :: (t: Type_Id) -> s64 { return cast(s64) ir.types[t].nsub; }
to_scalarized_ty :: (t: Type_Id) -> Type_Id {
    if is_vector_type(t) return type_elem(t);
    if type_kind(t) == .STRUCT {
        cs := contained_types(t);
        e := NewArray(cs.count, Type_Id,, temp);
        for cs e[it_index] = scalar_type(it);
        return type_literal_struct(e, false);
    }
    return t;
}

// BasicTTIImplBase::getIntrinsicInstrCost
bt_intrinsic_cost :: (t: *Tti, ica: *Ica, kind: s64) -> Cost {
    st := *t.xl;
    if base_intrinsic_cost(ica) == 0 return 0;
    n := iid_name(ica.id);
    if begins_with(n, "llvm.x86.") return TCC_BASIC;   // Intrinsic::isTargetIntrinsic
    vi: *Vp_Info = null;   // VPIntrinsic::isVPIntrinsic
    for * VP_INFOS if it.name == n { vi = it; break; }
    if vi {
        // VP intrinsics cost like their non-vp counterparts
        tb := ica_is_type_based(ica);
        vp_align :: (ica: *Ica, pos: u32) -> u64 {   // VPI->getPointerAlignment().valueOrOne()
            if ica.inst == NONE || !is_inst(ica.inst) return 1;
            return max(call_param_align(ica.inst, pos), 1);
        }
        fop := vi.opcode;
        if fop != .NONE_OP {
            if n == "llvm.vp.load" {
                as: u32 = 0;
                if ica.tys.count > 1 && is_ptr_type(ica.tys[0]) as = ptr_addrspace(ica.tys[0]);
                return x86_memory_op_cost(t, .LOAD, ica.ret, vp_align(ica, 0), as, kind);
            }
            if n == "llvm.vp.store" {
                as: u32 = 0;
                if ica.tys.count >= 2 && is_ptr_type(ica.tys[1]) as = ptr_addrspace(ica.tys[1]);
                return x86_memory_op_cost(t, .STORE, ica.tys[0], vp_align(ica, 1), as, kind);
            }
            if vi.binop || n == "llvm.vp.fneg" return x86_arith_cost(t, fop, ica.ret, kind, OI_ANY, OI_ANY);
            if vp_is_cast(vi) return x86_cast_cost(t, fop, ica.ret, ica.tys[0], CCH_NONE, kind);
            if vp_is_cmp(vi) && ica.inst != NONE {
                m := ir.v_aux[call_arg(ica.inst, 2)];
                pred := vp_cmp_predicate(cast(Md_Id) m, n == "llvm.vp.fcmp");
                return x86_cmp_sel_cost(t, fop, ica.tys[0], ica.ret, pred, kind);
            }
        }
        if n == "llvm.vp.load.ff" {
            m: Mica; m.id = ica.id; m.data_ty = type_sub(ica.ret, 0); m.align = vp_align(ica, 0);
            return x86_mem_intrinsic_cost(t, *m, kind);
        }
        if n == "llvm.vp.scatter" || n == "llvm.vp.gather" {
            fid := iidn(vi.intr);
            if tb {
                a := ica_types(fid, ica.ret, array_view(ica.tys, 0, ica.tys.count - 1), ica.fmf);
                return bt_type_based_intrinsic_cost(t, *a, kind);
            }
            m: Mica; m.id = ica.id;
            if n == "llvm.vp.scatter" {
                m.data_ty = ica.tys[0]; m.ptr = args_of(ica)[1]; m.align = vp_align(ica, 1);
                m.variable_mask = is_constant_kind(vkind(args_of(ica)[2]));   // LLVM: VarMask = isa<Constant>(mask)
            } else {
                m.data_ty = ica.ret; m.ptr = args_of(ica)[0]; m.align = vp_align(ica, 0);
                m.variable_mask = is_constant_kind(vkind(args_of(ica)[1]));
            }
            return x86_mem_intrinsic_cost(t, *m, kind);
        }
        if n == "llvm.vp.select" || n == "llvm.vp.merge" {
            ox := OI_ANY; oy := OI_ANY;
            if !tb { ox = tti_operand_info(args_of(ica)[0]); oy = tti_operand_info(args_of(ica)[1]); }
            return x86_cmp_sel_cost(t, .SELECT, ica.ret, ica.tys[0], BAD_ICMP_PREDICATE, kind, ox, oy);
        }
        fname := vi.intr;
        if n == "llvm.experimental.vp.reverse" fname = "llvm.vector.reverse";   // close enough for cost modelling
        if fname.count {
            fid := iidn(fname);
            assert(ica.tys.count >= 2, "Expected VPIntrinsic to have Mask and Vector Length args and types");
            nargs: [] Value_Id = ica.args;
            if !tb nargs = array_view(ica.args, 0, ica.args.count - 2);
            ntys := array_view(ica.tys, 0, ica.tys.count - 2);
            if vp_is_reduction(vi) && fname != "llvm.vector.reduce.fadd" && fname != "llvm.vector.reduce.fmul" {
                if !tb nargs = array_view(nargs, 1, nargs.count - 1);
                ntys = array_view(ntys, 1, ntys.count - 1);
            }
            na: Ica;
            na.id = fid; na.ret = ica.ret; na.args = nargs; na.tys = ntys; na.fmf = ica.fmf;   // IntrinsicCostAttributes(ID, RTy, Args, Tys, Flags)
            return x86_intrinsic_cost(t, *na, kind);
        }
    }
    if ica_is_type_based(ica) return bt_type_based_intrinsic_cost(t, ica, kind);
    ret := ica.ret;
    ret_vf: s64 = 1;
    ret_vector := is_vectorized_ty(ret);
    if ret_vector ret_vf = cast(s64) type_count(contained_types(ret)[0]);
    i := ica.inst;
    args := ica.args;
    if n == {
        case "llvm.powi";
            a1 := args[1];
            if is_const_int(a1) {
                // TargetLoweringBase::isBeneficialToExpandPowI
                e := ap_sext_value(cf_ap(a1));
                ue := cast(u64) (ifx e < 0 then -e else e);
                opt_size := i != NONE && fn_has_opt_size(inst_fn(i));
                pc := 0; x := ue; while x != 0 { pc += cast(s64) (x & 1); x >>= 1; }
                lg := 0; x = ue; while x > 1 { lg += 1; x >>= 1; }
                if !opt_size || pc + lg < 7 {
                    ab := ap_abs(cf_ap(a1));
                    active := cast(s64) ap_active_bits(ab);
                    pop := cast(s64) ap_popcount(ab);
                    c := cost_mul(active + pop - 2, x86_arith_cost(t, .FMUL, ret, kind, OI_ANY, OI_ANY));
                    if e < 0 c = cost_add(c, x86_arith_cost(t, .FDIV, ret, kind, OI_ANY, OI_ANY));
                    return c;
                }
            }
        case "llvm.cttz";
            // isCheapToSpeculateCttz (X86): BMI, or a CMOV-able scalar
            if !ret_vector && x86_is_cheap_to_speculate_cttz(st, ret) return TCC_BASIC;
        case "llvm.ctlz";
            if !ret_vector && x86_is_cheap_to_speculate_ctlz(st) return TCC_BASIC;
        case "llvm.memcpy"; return TCC_EXPENSIVE;   // getMemcpyCost (TargetTransformInfoImplBase)
        case "llvm.stepvector";
            if type_kind(ret) == .SVECTOR return base_intrinsic_cost(ica);
            return TCC_BASIC;
        case "llvm.vector.extract";
            if type_kind(ret) == .SVECTOR return base_intrinsic_cost(ica);
            idx := cast(s64) ap_zext_value(cf_ap(args[1]));
            return x86_shuffle_cost(t, SK_EXTRACT_SUBVECTOR, ret, vtype(args[0]), .[], kind, idx, ret, .[], NONE);
        case "llvm.vector.insert";
            if type_kind(vtype(args[1])) == .SVECTOR return base_intrinsic_cost(ica);
            idx := cast(s64) ap_zext_value(cf_ap(args[2]));
            return x86_shuffle_cost(t, SK_INSERT_SUBVECTOR, ret, vtype(args[0]), .[], kind, idx, vtype(args[1]), .[], NONE);
        case "llvm.vector.splice.left"; #through;
        case "llvm.vector.splice.right";
            if is_const_int(args[2]) {
                idx := cast(s64) ap_zext_value(cf_ap(args[2]));
                if n == "llvm.vector.splice.right" idx = cast(s64) cast(u32) (-idx);
                return x86_shuffle_cost(t, SK_SPLICE, ret, vtype(args[0]), .[], kind, idx, ret, .[], NONE);
            }
        case "llvm.vector.reduce.add"; #through; case "llvm.vector.reduce.mul"; #through;
        case "llvm.vector.reduce.and"; #through; case "llvm.vector.reduce.or"; #through;
        case "llvm.vector.reduce.xor"; #through; case "llvm.vector.reduce.smax"; #through;
        case "llvm.vector.reduce.smin"; #through; case "llvm.vector.reduce.fmax"; #through;
        case "llvm.vector.reduce.fmin"; #through; case "llvm.vector.reduce.fmaximum"; #through;
        case "llvm.vector.reduce.fminimum"; #through; case "llvm.vector.reduce.umax"; #through;
        case "llvm.vector.reduce.umin";
            a := ica_types(ica.id, ret, .[vtype(args[0])], ica.fmf, i, 1);
            return bt_type_based_intrinsic_cost(t, *a, kind);
        case "llvm.vector.reduce.fadd"; #through;
        case "llvm.vector.reduce.fmul";
            a := ica_types(ica.id, ret, .[vtype(args[0]), vtype(args[1])], ica.fmf, i, 1);
            return bt_type_based_intrinsic_cost(t, *a, kind);
        case "llvm.fshl"; #through;
        case "llvm.fshr";
            x := args[0]; y := args[1]; z := args[2];
            ox := tti_operand_info(x); oy := tti_operand_info(y); oz := tti_operand_info(z);
            c := x86_arith_cost(t, .OR, ret, kind, OI_ANY, OI_ANY);
            c = cost_add(c, x86_arith_cost(t, .SHL, ret, kind, ox, .{oz.kind, OP_NONE}));
            c = cost_add(c, x86_arith_cost(t, .LSHR, ret, kind, oy, .{oz.kind, OP_NONE}));
            if !oi_is_constant(oz) {
                c = cost_add(c, x86_arith_cost(t, .SUB, ret, kind, OI_ANY, OI_ANY));
                bw := ic_primitive_size_bits(scalar_type(ret));
                pow2 := bw != 0 && (bw & (bw - 1)) == 0;
                c = cost_add(c, x86_arith_cost(t, ifx pow2 then Opcode.AND else .UREM, ret, kind, oz, .{OK_UNIFORM_CONSTANT_VALUE, OP_NONE}));
                if x != y {
                    cond := type_with_new_bit_width(ret, 1);
                    c = cost_add(c, x86_cmp_sel_cost(t, .ICMP, ret, cond, ICMP_EQ, kind));
                    c = cost_add(c, x86_cmp_sel_cost(t, .SELECT, ret, cond, ICMP_EQ, kind));
                }
            }
            return c;
        case "llvm.get.active.lane.mask"; #through; case "llvm.experimental.vector.match"; #through;
        case "llvm.experimental.vector.histogram.add"; #through; case "llvm.experimental.vector.histogram.uadd.sat"; #through;
        case "llvm.experimental.vector.histogram.umax"; #through; case "llvm.experimental.vector.histogram.umin"; #through;
        case "llvm.masked.udiv"; #through; case "llvm.masked.sdiv"; #through;
        case "llvm.masked.urem"; #through; case "llvm.masked.srem";
            return bt_type_based_intrinsic_cost(t, ica, kind);
    }
    if n == {
        case "llvm.masked.scatter";
            m: Mica; m.id = ica.id; m.data_ty = ica.tys[0]; m.ptr = args[1]; m.variable_mask = !is_constant_kind(vkind(args[2]));
            m.align = max(call_param_align(i, 1), 1); m.inst = i;
            m.addrspace = ptr_addrspace(vtype(args[1]));
            return x86_mem_intrinsic_cost(t, *m, kind);
        case "llvm.masked.gather";
            m: Mica; m.id = ica.id; m.data_ty = ret; m.ptr = args[0]; m.variable_mask = !is_constant_kind(vkind(args[1]));
            m.align = max(call_param_align(i, 0), 1); m.inst = i;
            m.addrspace = ptr_addrspace(vtype(args[0]));
            return x86_mem_intrinsic_cost(t, *m, kind);
        case "llvm.masked.compressstore";
            m: Mica; m.id = ica.id; m.data_ty = vtype(args[0]); m.variable_mask = !is_constant_kind(vkind(args[2]));
            m.align = max(call_param_align(i, 1), 1); m.inst = i;
            return x86_mem_intrinsic_cost(t, *m, kind);
        case "llvm.masked.expandload";
            m: Mica; m.id = ica.id; m.data_ty = ret; m.variable_mask = !is_constant_kind(vkind(args[1]));
            m.align = max(call_param_align(i, 0), 1); m.inst = i;
            return x86_mem_intrinsic_cost(t, *m, kind);
    }
    if n == "llvm.experimental.cttz.elts" {
        at := ica.tys[0];
        if type_kind(at) == .SVECTOR x86_np("getIntrinsicInstrCost of llvm.experimental.cttz.elts on a scalable vector");
        // shouldExpandCttzElements is true on X86; getBitWidthForCttzElements
        zero_is_poison := !is_null_value(args[1]);
        v := cast(u64) type_count(at);
        if zero_is_poison v -= 1;
        active: u32 = 0; x := v; while x != 0 { active += 1; x >>= 1; }
        ew := min(cast(u32) ic_primitive_size_bits(scalar_type(ret)), active);
        p2: u32 = 1; while p2 < ew p2 *= 2;
        ew = max(p2, 8);
        net := type_int(ew);
        nvt := xvec(net, cast(s64) type_count(at));
        sa := ica_types(iidn("llvm.stepvector"), nvt, .[], ica.fmf);
        c := x86_intrinsic_cost(t, *sa, kind);
        c = cost_add(c, x86_arith_cost(t, .SUB, nvt, kind, OI_ANY, OI_ANY));
        c = cost_add(c, x86_cast_cost(t, .SEXT, nvt, vtype(args[0]), CCH_NONE, kind));
        c = cost_add(c, x86_arith_cost(t, .AND, nvt, kind, OI_ANY, OI_ANY));
        ra := ica_types(IID_VECTOR_REDUCE_UMAX, net, .[nvt], ica.fmf, i, 1);
        c = cost_add(c, bt_type_based_intrinsic_cost(t, *ra, kind));
        return cost_add(c, x86_arith_cost(t, .SUB, net, kind, OI_ANY, OI_ANY));
    }
    // modf / sincos / sincospi: getMultipleResultIntrinsicVectorLibCallCost is nullopt unless the result is a
    // struct of vectors (isVectorizedStructTy); scalar results fall through to the default cost
    if n == "llvm.modf" || n == "llvm.sincos" || n == "llvm.sincospi" {
        has, c := bt_multiple_result_intrinsic_vector_lib_call_cost(t, ica, kind, ifx n == "llvm.modf" then 0 else -1);
        if has return c;
    }
    if begins_with(n, "llvm.loop.dependence") x86_np(tprint("getIntrinsicInstrCost of %", n));
    scal := COST_INVALID;
    if ret_vector && type_kind(contained_types(ret)[0]) != .SVECTOR {
        scal = 0;
        if type_kind(ret) != .VOID for contained_types(ret) scal = cost_add(scal, bt_scalarization_overhead(t, it, true, false, kind));
        // getOperandsScalarizationOverhead(filterConstantAndDuplicatedOperands(Args, Tys))
        seen: [..] Value_Id; seen.allocator = temp;
        ft: [..] Type_Id; ft.allocator = temp;
        for a: args {
            if is_constant_kind(vkind(a)) continue;
            dup := false; for seen if it == a dup = true;
            if dup continue;
            array_add(*seen, a);
            array_add(*ft, ica.tys[it_index]);
        }
        scal = cost_add(scal, bt_operands_scalarization_overhead(t, ft, kind));
    }
    a := ica_types(ica.id, ret, ica.tys, ica.fmf, i, scal);
    return bt_type_based_intrinsic_cost(t, *a, kind);
}

// X86TargetLowering::isCheapToSpeculateCttz / isCheapToSpeculateCtlz (hasBitScanPassThrough == is64Bit)
x86_is_cheap_to_speculate_cttz :: (st: *X86_Lowering, ty: Type_Id) -> bool {
    return st_hasBMI(st) || st_canUseCMOV(st) || st_is64Bit(st) ||
           (!is_vector_type(ty) && ic_primitive_size_bits(scalar_type(ty)) < ifx st_is64Bit(st) then cast(u64) 64 else 32);
}
x86_is_cheap_to_speculate_ctlz :: (st: *X86_Lowering) -> bool { return st_hasLZCNT(st) || st_canUseCMOV(st) || st_is64Bit(st); }

// BasicTTIImplBase::getTypeBasedIntrinsicInstrCost
bt_type_based_intrinsic_cost :: (t: *Tti, ica: *Ica, kind: s64) -> Cost {
    st := *t.xl;
    n := iid_name(ica.id);
    ret := ica.ret;
    tys := ica.tys;
    fmf := ica.fmf;
    scal_passed := ica.scalar_cost;
    skip_scal := cost_valid(scal_passed);
    vec_op: Type_Id = NONE;
    if tys.count {
        vi := ifx n == "llvm.vector.reduce.fadd" || n == "llvm.vector.reduce.fmul" then 1 else 0;
        if is_vector_type(tys[vi]) vec_op = tys[vi];
    }
    single_call: Cost = ifx kind == TCK_CODE_SIZE then cast(Cost) 1 else 10;
    isd: u32 = 0;
    any_scalable :: (ret: Type_Id, tys: [] Type_Id) -> bool {
        if type_kind(ret) == .SVECTOR return true;
        for tys if type_kind(it) == .SVECTOR return true;
        return false;
    }
    if n == {
        case "llvm.sqrt"; isd = ISD_FSQRT;
        case "llvm.sin"; isd = ISD_FSIN;
        case "llvm.cos"; isd = ISD_FCOS;
        case "llvm.sincos"; isd = ISD_FSINCOS;
        case "llvm.sincospi"; isd = ISD_FSINCOSPI;
        case "llvm.modf"; isd = ISD_FMODF;
        case "llvm.tan"; isd = ISD_FTAN;
        case "llvm.asin"; isd = ISD_FASIN;
        case "llvm.acos"; isd = ISD_FACOS;
        case "llvm.atan"; isd = ISD_FATAN;
        case "llvm.atan2"; isd = ISD_FATAN2;
        case "llvm.sinh"; isd = ISD_FSINH;
        case "llvm.cosh"; isd = ISD_FCOSH;
        case "llvm.tanh"; isd = ISD_FTANH;
        case "llvm.exp"; isd = ISD_FEXP;
        case "llvm.exp2"; isd = ISD_FEXP2;
        case "llvm.exp10"; isd = ISD_FEXP10;
        case "llvm.log"; isd = ISD_FLOG;
        case "llvm.log10"; isd = ISD_FLOG10;
        case "llvm.log2"; isd = ISD_FLOG2;
        case "llvm.ldexp"; isd = ISD_FLDEXP;
        case "llvm.fabs"; isd = ISD_FABS;
        case "llvm.canonicalize"; isd = ISD_FCANONICALIZE;
        case "llvm.minnum"; isd = ISD_FMINNUM;
        case "llvm.maxnum"; isd = ISD_FMAXNUM;
        case "llvm.minimum"; isd = ISD_FMINIMUM;
        case "llvm.maximum"; isd = ISD_FMAXIMUM;
        case "llvm.minimumnum"; isd = ISD_FMINIMUMNUM;
        case "llvm.maximumnum"; isd = ISD_FMAXIMUMNUM;
        case "llvm.copysign"; isd = ISD_FCOPYSIGN;
        case "llvm.floor"; isd = ISD_FFLOOR;
        case "llvm.ceil"; isd = ISD_FCEIL;
        case "llvm.trunc"; isd = ISD_FTRUNC;
        case "llvm.nearbyint"; isd = ISD_FNEARBYINT;
        case "llvm.rint"; isd = ISD_FRINT;
        case "llvm.lrint"; isd = ISD_LRINT;
        case "llvm.llrint"; isd = ISD_LLRINT;
        case "llvm.round"; isd = ISD_FROUND;
        case "llvm.roundeven"; isd = ISD_FROUNDEVEN;
        case "llvm.lround"; isd = ISD_LROUND;
        case "llvm.llround"; isd = ISD_LLROUND;
        case "llvm.pow"; isd = ISD_FPOW;
        case "llvm.fma"; isd = ISD_FMA;
        case "llvm.fmuladd"; isd = ISD_FMA;
        case "llvm.experimental.constrained.fmuladd"; isd = ISD_STRICT_FMA;
        case "llvm.lifetime.start"; #through; case "llvm.lifetime.end"; #through; case "llvm.sideeffect"; #through;
        case "llvm.pseudoprobe"; #through; case "llvm.arithmetic.fence"; return 0;
        case "llvm.masked.store";
            m: Mica; m.id = ica.id; m.data_ty = tys[0]; m.align = dl_abi_align(tys[0]);
            return x86_mem_intrinsic_cost(t, *m, kind);
        case "llvm.masked.load";
            m: Mica; m.id = ica.id; m.data_ty = ret; m.align = dl_abi_align(ret);
            return x86_mem_intrinsic_cost(t, *m, kind);
        case "llvm.experimental.vp.strided.store"; #through; case "llvm.experimental.vp.strided.load";
            x86_np(tprint("getMemIntrinsicInstrCost of %", n));
        case "llvm.vector.reduce.add"; return x86_arithmetic_reduction_cost(t, .ADD, vec_op, false, 0, kind);
        case "llvm.vector.reduce.mul"; return x86_arithmetic_reduction_cost(t, .MUL, vec_op, false, 0, kind);
        case "llvm.vector.reduce.and"; return x86_arithmetic_reduction_cost(t, .AND, vec_op, false, 0, kind);
        case "llvm.vector.reduce.or"; return x86_arithmetic_reduction_cost(t, .OR, vec_op, false, 0, kind);
        case "llvm.vector.reduce.xor"; return x86_arithmetic_reduction_cost(t, .XOR, vec_op, false, 0, kind);
        case "llvm.vector.reduce.fadd"; return x86_arithmetic_reduction_cost(t, .FADD, vec_op, true, fmf, kind);
        case "llvm.vector.reduce.fmul"; return x86_arithmetic_reduction_cost(t, .FMUL, vec_op, true, fmf, kind);
        case "llvm.vector.reduce.smax"; return x86_min_max_reduction_cost(t, iidn("llvm.smax"), vec_op, fmf, kind);
        case "llvm.vector.reduce.smin"; return x86_min_max_reduction_cost(t, iidn("llvm.smin"), vec_op, fmf, kind);
        case "llvm.vector.reduce.umax"; return x86_min_max_reduction_cost(t, iidn("llvm.umax"), vec_op, fmf, kind);
        case "llvm.vector.reduce.umin"; return x86_min_max_reduction_cost(t, iidn("llvm.umin"), vec_op, fmf, kind);
        case "llvm.vector.reduce.fmax"; return x86_min_max_reduction_cost(t, iidn("llvm.maxnum"), vec_op, fmf, kind);
        case "llvm.vector.reduce.fmin"; return x86_min_max_reduction_cost(t, iidn("llvm.minnum"), vec_op, fmf, kind);
        case "llvm.vector.reduce.fmaximum"; return x86_min_max_reduction_cost(t, iidn("llvm.maximum"), vec_op, fmf, kind);
        case "llvm.vector.reduce.fminimum"; return x86_min_max_reduction_cost(t, iidn("llvm.minimum"), vec_op, fmf, kind);
        case "llvm.experimental.vector.match"; #through;
        case "llvm.experimental.vector.histogram.add"; #through; case "llvm.experimental.vector.histogram.uadd.sat"; #through;
        case "llvm.experimental.vector.histogram.umax"; #through; case "llvm.experimental.vector.histogram.umin";
            x86_np(tprint("getTypeBasedIntrinsicInstrCost of %", n));
        case "llvm.get.active.lane.mask";
            // TargetLoweringBase::shouldExpandGetActiveLaneMask is true (X86 does not override it): the cost of the
            // uadd_sat + icmp ult expansion
            arg_ty := tys[0];
            exp_ret := type_vector(type_count(ret), arg_ty, type_kind(ret) == .SVECTOR);
            a := ica_types(iidn("llvm.uadd.sat"), exp_ret, .[], fmf);
            c := bt_type_based_intrinsic_cost(t, *a, kind);
            return cost_add(c, x86_cmp_sel_cost(t, .ICMP, exp_ret, ret, ICMP_ULT, kind));
        case "llvm.vector.reverse";
            return x86_shuffle_cost(t, SK_REVERSE, ret, tys[0], .[], kind, 0, ret, .[], NONE);
        case "llvm.experimental.memset.pattern"; return TCC_BASIC * 4;
        case "llvm.abs"; isd = ISD_ABS;
        case "llvm.fshl"; isd = ISD_FSHL;
        case "llvm.fshr"; isd = ISD_FSHR;
        case "llvm.smax"; isd = ISD_SMAX;
        case "llvm.smin"; isd = ISD_SMIN;
        case "llvm.umax"; isd = ISD_UMAX;
        case "llvm.umin"; isd = ISD_UMIN;
        case "llvm.sadd.sat"; isd = ISD_SADDSAT;
        case "llvm.ssub.sat"; isd = ISD_SSUBSAT;
        case "llvm.uadd.sat"; isd = ISD_UADDSAT;
        case "llvm.usub.sat"; isd = ISD_USUBSAT;
        case "llvm.smul.fix"; isd = ISD_SMULFIX;
        case "llvm.umul.fix"; isd = ISD_UMULFIX;
        case "llvm.sadd.with.overflow"; isd = ISD_SADDO;
        case "llvm.ssub.with.overflow"; isd = ISD_SSUBO;
        case "llvm.uadd.with.overflow"; isd = ISD_UADDO;
        case "llvm.usub.with.overflow"; isd = ISD_USUBO;
        case "llvm.smul.with.overflow"; isd = ISD_SMULO;
        case "llvm.umul.with.overflow"; isd = ISD_UMULO;
        case "llvm.fptosi.sat"; #through;
        case "llvm.fptoui.sat";
            sc, _ := bt_type_legalization_cost(st, tys[0]);
            rc, _ := bt_type_legalization_cost(st, ret);
            if !cost_valid(sc) || !cost_valid(rc) return COST_INVALID;
            isd = ifx n == "llvm.fptosi.sat" then ISD_FP_TO_SINT_SAT else ISD_FP_TO_UINT_SAT;
        case "llvm.ctpop"; isd = ISD_CTPOP; single_call = TCC_EXPENSIVE;
        case "llvm.ctlz"; isd = ISD_CTLZ;
        case "llvm.cttz"; isd = ISD_CTTZ;
        case "llvm.bswap"; isd = ISD_BSWAP;
        case "llvm.bitreverse"; isd = ISD_BITREVERSE;
        case "llvm.ucmp"; isd = ISD_UCMP;
        case "llvm.scmp"; isd = ISD_SCMP;
        case "llvm.clmul"; isd = ISD_CLMUL;
        case "llvm.masked.udiv"; #through; case "llvm.masked.sdiv"; #through;
        case "llvm.masked.urem"; #through; case "llvm.masked.srem";
            uop: Opcode;
            if n == {
                case "llvm.masked.udiv"; isd = ISD_MASKED_UDIV; uop = .UDIV;
                case "llvm.masked.sdiv"; isd = ISD_MASKED_SDIV; uop = .SDIV;
                case "llvm.masked.urem"; isd = ISD_MASKED_UREM; uop = .UREM;
                case; isd = ISD_MASKED_SREM; uop = .SREM;
            }
            c := x86_arith_cost(t, uop, ret, kind, OI_ANY, OI_ANY);
            _, lt := bt_type_legalization_cost(st, ret);
            if !is_op_legal_or_custom(st, isd, lt) {
                cond := type_with_new_bit_width(ret, 1);
                c = cost_add(c, x86_cmp_sel_cost(t, .SELECT, ret, cond, BAD_ICMP_PREDICATE, kind, OI_ANY, .{OK_UNIFORM_CONSTANT_VALUE, OP_POWER_OF_2}));
            }
            return c;
        case;
            // default: assume the intrinsic is scalarized
            if any_scalable(ret, tys) return COST_INVALID;
            scal: Cost = ifx skip_scal then scal_passed else 0;
            calls: s64 = 1;
            sret := ret;
            if is_vector_type(ret) {
                if !skip_scal scal = bt_scalarization_overhead(t, ret, true, false, kind);
                calls = max(calls, cast(s64) type_count(ret));
                sret = type_elem(ret);
            }
            stys := NewArray(tys.count, Type_Id,, temp);
            for ty: tys {
                x := ty;
                if is_vector_type(ty) {
                    if !skip_scal scal = cost_add(scal, bt_scalarization_overhead(t, ty, false, true, kind));
                    calls = max(calls, cast(s64) type_count(ty));
                    x = type_elem(ty);
                }
                stys[it_index] = x;
            }
            if calls == 1 return 1;
            sa := ica_types(ica.id, sret, stys, fmf);
            return cost_add(cost_mul(calls, x86_intrinsic_cost(t, *sa, kind)), scal);
    }

    legalize_ty := ifx type_kind(ret) == .STRUCT then type_sub(ret, 0) else ret;
    ltc, ltm := bt_type_legalization_cost(st, legalize_ty);
    if is_op_legal_or_promote(st, isd, ltm) {
        // isFAbsFree is false on X86
        if ltc > 1 return cost_mul(ltc, 2);
        return ltc;
    } else if is_op_custom(st, isd, ltm) {
        return cost_mul(ltc, 2);
    }
    cond_of :: (ty: Type_Id) -> Type_Id { return type_with_new_bit_width(ty, 1); }
    if n == {
        case "llvm.fmuladd";
            return cost_add(x86_arith_cost(t, .FMUL, ret, kind, OI_ANY, OI_ANY), x86_arith_cost(t, .FADD, ret, kind, OI_ANY, OI_ANY));
        case "llvm.experimental.constrained.fmuladd";
            a := ica_types(iidn("llvm.experimental.constrained.fmul"), ret, tys);
            b := ica_types(iidn("llvm.experimental.constrained.fadd"), ret, tys);
            return cost_add(x86_intrinsic_cost(t, *a, kind), x86_intrinsic_cost(t, *b, kind));
        case "llvm.smin"; #through; case "llvm.smax"; #through; case "llvm.umin"; #through; case "llvm.umax";
            cond := cond_of(ret);
            pred := cast(u8) (ifx n == "llvm.umax" || n == "llvm.umin" then ICMP_UGT else ICMP_SGT);
            return cost_add(x86_cmp_sel_cost(t, .ICMP, ret, cond, pred, kind), x86_cmp_sel_cost(t, .SELECT, ret, cond, pred, kind));
        case "llvm.sadd.with.overflow"; #through; case "llvm.ssub.with.overflow";
            sum := type_sub(ret, 0); ov := type_sub(ret, 1);
            opc := ifx n == "llvm.sadd.with.overflow" then Opcode.ADD else .SUB;
            c := x86_arith_cost(t, opc, sum, kind, OI_ANY, OI_ANY);
            c = cost_add(c, cost_mul(2, x86_cmp_sel_cost(t, .ICMP, sum, ov, ICMP_SGT, kind)));
            return cost_add(c, x86_arith_cost(t, .XOR, ov, kind, OI_ANY, OI_ANY));
        case "llvm.uadd.with.overflow"; #through; case "llvm.usub.with.overflow";
            sum := type_sub(ret, 0); ov := type_sub(ret, 1);
            opc := ifx n == "llvm.uadd.with.overflow" then Opcode.ADD else .SUB;
            pred := cast(u8) (ifx n == "llvm.uadd.with.overflow" then ICMP_ULT else ICMP_UGT);
            return cost_add(x86_arith_cost(t, opc, sum, kind, OI_ANY, OI_ANY), x86_cmp_sel_cost(t, .ICMP, sum, ov, pred, kind));
        case "llvm.smul.with.overflow"; #through; case "llvm.umul.with.overflow";
            mul := type_sub(ret, 0); ov := type_sub(ret, 1);
            ext := type_with_new_bit_width(mul, cast(u32) ic_primitive_size_bits(scalar_type(mul)) * 2);
            signed := n == "llvm.smul.with.overflow";
            eop := ifx signed then Opcode.SEXT else .ZEXT;
            c := cost_mul(2, x86_cast_cost(t, eop, ext, mul, CCH_NONE, kind));
            c = cost_add(c, x86_arith_cost(t, .MUL, ext, kind, OI_ANY, OI_ANY));
            c = cost_add(c, cost_mul(2, x86_cast_cost(t, .TRUNC, mul, ext, CCH_NONE, kind)));
            c = cost_add(c, x86_arith_cost(t, .LSHR, ext, kind, OI_ANY, .{OK_UNIFORM_CONSTANT_VALUE, OP_NONE}));
            if signed c = cost_add(c, x86_arith_cost(t, .ASHR, mul, kind, OI_ANY, .{OK_UNIFORM_CONSTANT_VALUE, OP_NONE}));
            return cost_add(c, x86_cmp_sel_cost(t, .ICMP, mul, ov, ICMP_NE, kind));
        case "llvm.sadd.sat"; #through; case "llvm.ssub.sat";
            cond := cond_of(ret);
            op_ty := type_literal_struct(.[ret, cond], false);
            ovf := iidn(ifx n == "llvm.sadd.sat" then "llvm.sadd.with.overflow" else "llvm.ssub.with.overflow");
            a := ica_types(ovf, op_ty, .[ret, ret], fmf, NONE, scal_passed);
            c := x86_intrinsic_cost(t, *a, kind);
            c = cost_add(c, x86_cmp_sel_cost(t, .ICMP, ret, cond, ICMP_SGT, kind));
            return cost_add(c, cost_mul(2, x86_cmp_sel_cost(t, .SELECT, ret, cond, ICMP_SGT, kind)));
        case "llvm.uadd.sat"; #through; case "llvm.usub.sat";
            cond := cond_of(ret);
            op_ty := type_literal_struct(.[ret, cond], false);
            ovf := iidn(ifx n == "llvm.uadd.sat" then "llvm.uadd.with.overflow" else "llvm.usub.with.overflow");
            a := ica_types(ovf, op_ty, .[ret, ret], fmf, NONE, scal_passed);
            c := x86_intrinsic_cost(t, *a, kind);
            return cost_add(c, x86_cmp_sel_cost(t, .SELECT, ret, cond, BAD_ICMP_PREDICATE, kind));
        case "llvm.smul.fix"; #through; case "llvm.umul.fix";
            ext := type_with_new_bit_width(ret, cast(u32) ic_primitive_size_bits(scalar_type(ret)) * 2);
            eop := ifx n == "llvm.smul.fix" then Opcode.SEXT else .ZEXT;
            c := cost_mul(2, x86_cast_cost(t, eop, ext, ret, CCH_NONE, kind));
            c = cost_add(c, x86_arith_cost(t, .MUL, ext, kind, OI_ANY, OI_ANY));
            c = cost_add(c, cost_mul(2, x86_cast_cost(t, .TRUNC, ret, ext, CCH_NONE, kind)));
            c = cost_add(c, x86_arith_cost(t, .LSHR, ret, kind, OI_ANY, .{OK_UNIFORM_CONSTANT_VALUE, OP_NONE}));
            c = cost_add(c, x86_arith_cost(t, .SHL, ret, kind, OI_ANY, .{OK_UNIFORM_CONSTANT_VALUE, OP_NONE}));
            return cost_add(c, x86_arith_cost(t, .OR, ret, kind, OI_ANY, OI_ANY));
        case "llvm.abs";
            cond := cond_of(ret);
            c := x86_cmp_sel_cost(t, .ICMP, ret, cond, ICMP_SGT, kind);
            c = cost_add(c, x86_cmp_sel_cost(t, .SELECT, ret, cond, ICMP_SGT, kind));
            return cost_add(c, x86_arith_cost(t, .SUB, ret, kind, .{OK_UNIFORM_CONSTANT_VALUE, OP_NONE}, OI_ANY));
        case "llvm.fshl"; #through; case "llvm.fshr";
            cond := cond_of(ret);
            c := x86_arith_cost(t, .OR, ret, kind, OI_ANY, OI_ANY);
            c = cost_add(c, x86_arith_cost(t, .SUB, ret, kind, OI_ANY, OI_ANY));
            c = cost_add(c, x86_arith_cost(t, .SHL, ret, kind, OI_ANY, OI_ANY));
            c = cost_add(c, x86_arith_cost(t, .LSHR, ret, kind, OI_ANY, OI_ANY));
            bw := ic_primitive_size_bits(scalar_type(ret));
            pow2 := bw != 0 && (bw & (bw - 1)) == 0;
            c = cost_add(c, x86_arith_cost(t, ifx pow2 then Opcode.AND else .UREM, ret, kind, OI_ANY, .{OK_UNIFORM_CONSTANT_VALUE, OP_NONE}));
            c = cost_add(c, x86_cmp_sel_cost(t, .ICMP, ret, cond, ICMP_EQ, kind));
            return cost_add(c, x86_cmp_sel_cost(t, .SELECT, ret, cond, ICMP_EQ, kind));
        case "llvm.fptosi.sat"; #through; case "llvm.fptoui.sat";
            if tys.count {
                from := tys[0];
                signed := n == "llvm.fptosi.sat";
                a1 := ica_types(iidn("llvm.minnum"), from, .[from, from]);
                c := x86_intrinsic_cost(t, *a1, kind);
                a2 := ica_types(iidn("llvm.maxnum"), from, .[from, from]);
                c = cost_add(c, x86_intrinsic_cost(t, *a2, kind));
                c = cost_add(c, x86_cast_cost(t, ifx signed then Opcode.FPTOSI else .FPTOUI, ret, from, CCH_NONE, kind));
                if signed {
                    cond := cond_of(ret);
                    c = cost_add(c, x86_cmp_sel_cost(t, .FCMP, from, cond, FCMP_UNO, kind));
                    c = cost_add(c, x86_cmp_sel_cost(t, .SELECT, ret, cond, FCMP_UNO, kind));
                }
                return c;
            }
        case "llvm.ucmp"; #through; case "llvm.scmp";
            cmp_ty := tys[0];
            cond := cond_of(ret);
            signed := n == "llvm.scmp";
            c := x86_cmp_sel_cost(t, .ICMP, cmp_ty, cond, cast(u8) (ifx signed then ICMP_SGT else ICMP_UGT), kind);
            c = cost_add(c, x86_cmp_sel_cost(t, .ICMP, cmp_ty, cond, cast(u8) (ifx signed then ICMP_SLT else ICMP_ULT), kind));
            // preferSelectsOverBooleanArithmetic is false on X86: zext(x > y) - zext(x < y)
            c = cost_add(c, cost_mul(2, x86_cast_cost(t, .ZEXT, ret, cond, CCH_NONE, kind)));
            return cost_add(c, x86_arith_cost(t, .SUB, ret, kind, OI_ANY, OI_ANY));
        case "llvm.maximumnum"; #through; case "llvm.minimumnum";
            ieee := ifx n == "llvm.maximumnum" then ISD_FMAXNUM_IEEE else ISD_FMINNUM_IEEE;
            if is_op_legal(st, ieee, ltm) {
                a := ica_types(iidn("llvm.canonicalize"), ret, .[tys[0]]);
                return cost_add(ltc, cost_mul(2, x86_intrinsic_cost(t, *a, kind)));
            }
        case "llvm.clmul";
            bw := ic_primitive_size_bits(scalar_type(ret));
            and_c := x86_arith_cost(t, .AND, ret, kind, OI_ANY, OI_ANY);
            or_c := x86_arith_cost(t, .OR, ret, kind, OI_ANY, OI_ANY);
            xor_c := x86_arith_cost(t, .XOR, ret, kind, OI_ANY, OI_ANY);
            mul_c := x86_arith_cost(t, .MUL, ret, kind, OI_ANY, OI_ANY);
            vt := x86_evt(st, ret);
            if bw >= 32 && bw <= 64 && evt_is_simple(vt) && is_op_legal_or_custom(st, ISD_MUL, vt.m)
                return cost_add(cost_add(cost_mul(16, mul_c), cost_mul(12, and_c)), cost_add(cost_mul(12, xor_c), cost_mul(3, or_c)));
            per_mul := cost_add(cost_add(and_c, mul_c), xor_c);
            per_bt := cost_add(cost_add(and_c, x86_cmp_sel_cost(t, .SELECT, ret, ret, BAD_ICMP_PREDICATE, kind)), x86_cmp_sel_cost(t, .ICMP, ret, ret, ICMP_NE, kind));
            return cost_mul(cast(Cost) bw, min(per_mul, per_bt));
    }
    if is_vectorized_ty(ret) {
        rvs := contained_types(ret);
        for rvs if type_kind(it) == .SVECTOR return COST_INVALID;
        for tys if type_kind(it) == .SVECTOR return COST_INVALID;
        scal := scal_passed;
        if !skip_scal {
            scal = 0;
            for rvs scal = cost_add(scal, bt_scalarization_overhead(t, it, true, false, kind));
        }
        calls := cast(s64) type_count(rvs[0]);
        stys := NewArray(tys.count, Type_Id,, temp);
        for tys stys[it_index] = scalar_type(it);
        a := ica_types(ica.id, to_scalarized_ty(ret), stys, fmf);
        sc := x86_intrinsic_cost(t, *a, kind);
        for ty: tys if is_vector_type(ty) {
            if !skip_scal scal = cost_add(scal, bt_scalarization_overhead(t, ty, false, true, kind));
            calls = max(calls, cast(s64) type_count(ty));
        }
        return cost_add(cost_mul(calls, sc), scal);
    }
    return single_call;
}

// ---------------------------------------------------------------- reductions

// XCost_Entry rows of a CostTblEntry table keep their single cost in c[0]
xt1 :: (tbl: [] XCost_Entry, isd: u32, m: u32) -> (bool, Cost) {
    for tbl if it.isd == isd && it.dst == m return true, it.c[0];
    return false, 0;
}
xtk :: (tbl: [] XCost_Entry, isd: u32, m: u32, kind: s64) -> (bool, Cost) {
    for tbl if it.isd == isd && it.dst == m { if it.c[kind] < 0 return false, 0; return true, it.c[kind]; }
    return false, 0;
}
is_pow2_s64 :: (x: s64) -> bool { return x > 0 && (x & (x - 1)) == 0; }
log2_s64 :: (x: s64) -> s64 { r := 0; v := x; while v > 1 { r += 1; v >>= 1; } return r; }

// BasicTTIImplBase::getTreeReductionCost
bt_tree_reduction_cost :: (t: *Tti, opc: Opcode, ty_in: Type_Id, kind: s64) -> Cost {
    if type_kind(ty_in) == .SVECTOR return COST_INVALID;
    ty := ty_in;
    elt := type_elem(ty);
    ne := xvec_n(ty);
    if (opc == .OR || opc == .AND) && elt == type_int(1) && ne >= 2 {
        vt := type_int(cast(u32) ne);
        return cost_add(x86_cast_cost(t, .BITCAST, vt, ty, CCH_NONE, kind), x86_cmp_sel_cost(t, .ICMP, vt, type_int(1), BAD_ICMP_PREDICATE, kind));
    }
    levels := log2_s64(ne);
    arith: Cost = 0; shuf: Cost = 0;
    _, ltm := bt_type_legalization_cost(*t.xl, ty);
    long := 0;
    mlen := ifx mvt_is_vec(ltm) then cast(s64) mvt_n(ltm) else 1;
    while ne > mlen {
        ne /= 2;
        sub := xvec(elt, ne);
        shuf = cost_add(shuf, x86_shuffle_cost(t, SK_EXTRACT_SUBVECTOR, sub, ty, .[], kind, ne, sub, .[], NONE));
        arith = cost_add(arith, x86_arith_cost(t, opc, sub, kind, OI_ANY, OI_ANY));
        ty = sub;
        long += 1;
    }
    levels -= long;
    shuf = cost_add(shuf, cost_mul(levels, x86_shuffle_cost(t, SK_PERMUTE_SINGLE_SRC, ty, ty, .[], kind, 0, ty, .[], NONE)));
    arith = cost_add(arith, cost_mul(levels, x86_arith_cost(t, opc, ty, kind, OI_ANY, OI_ANY)));
    return cost_add(cost_add(shuf, arith), x86_vector_instr_cost(t, .EXTRACTELEMENT, ty, kind, 0, NONE, NONE));
}
// BasicTTIImplBase::getOrderedReductionCost
bt_ordered_reduction_cost :: (t: *Tti, opc: Opcode, ty: Type_Id, kind: s64) -> Cost {
    if type_kind(ty) == .SVECTOR return COST_INVALID;
    ext := bt_scalarization_overhead(t, ty, false, true, kind);
    ar := cost_mul(xvec_n(ty), x86_arith_cost(t, opc, type_elem(ty), kind, OI_ANY, OI_ANY));
    return cost_add(ext, ar);
}
// TTI::requiresOrderedReduction(FMF): FMF given and no reassoc
requires_ordered_reduction :: (has_fmf: bool, fmf: u32) -> bool { return has_fmf && (fmf & FMF_REASSOC) == 0; }
bt_arithmetic_reduction_cost :: (t: *Tti, opc: Opcode, ty: Type_Id, has_fmf: bool, fmf: u32, kind: s64) -> Cost {
    if requires_ordered_reduction(has_fmf, fmf) return bt_ordered_reduction_cost(t, opc, ty, kind);
    return bt_tree_reduction_cost(t, opc, ty, kind);
}

// X86TTIImpl::getArithmeticReductionCost
x86_arithmetic_reduction_cost :: (t: *Tti, opc: Opcode, ty: Type_Id, has_fmf: bool, fmf: u32, kind: s64) -> Cost {
    st := *t.xl;
    if requires_ordered_reduction(has_fmf, fmf) return bt_arithmetic_reduction_cost(t, opc, ty, has_fmf, fmf, kind);
    isd := isd_of_opcode(opc);
    vt := x86_evt(st, ty);
    if evt_is_simple(vt) {
        m := vt.m;
        if st_useSLMArithCosts(st) { ok, c := xt1(XT_getArithmeticReductionCost_SLMCostTbl, isd, m); if ok return c; }
        if st_hasBWI(st) { ok, c := xt1(XT_getArithmeticReductionCost_AVX512BWCostTbl, isd, m); if ok return c; }
        if st_hasAVX512(st) { ok, c := xt1(XT_getArithmeticReductionCost_AVX512FCostTbl, isd, m); if ok return c; }
        if st_hasAVX(st) { ok, c := xt1(XT_getArithmeticReductionCost_AVX1CostTbl, isd, m); if ok return c; }
        if st_hasSSE2(st) { ok, c := xt1(XT_getArithmeticReductionCost_SSE2CostTbl, isd, m); if ok return c; }
    }
    ltc, mty := bt_type_legalization_cost(st, ty);
    elt := type_elem(ty);
    nelts := xvec_n(ty);
    if isd == ISD_MUL && mvt_scalar(mty) == MVT_i8 {
        wide := xvec(type_int(16), nelts);
        return cost_add(x86_cast_cost(t, .ZEXT, wide, ty, CCH_NONE, kind), x86_arithmetic_reduction_cost(t, opc, wide, has_fmf, fmf, kind));
    }
    split := ltc != 1 && mvt_is_vec(mty) && cast(s64) mvt_n(mty) < nelts;
    arith: Cost = 0;
    if split arith = cost_mul(x86_arith_cost(t, opc, xvec(elt, mvt_n(mty)), kind, OI_ANY, OI_ANY), ltc - 1);
    if st_useSLMArithCosts(st) { ok, c := xt1(XT_getArithmeticReductionCost_SLMCostTbl, isd, mty); if ok return cost_add(arith, c); }
    if st_hasAVX(st) { ok, c := xt1(XT_getArithmeticReductionCost_AVX1CostTbl, isd, mty); if ok return cost_add(arith, c); }
    if st_hasSSE2(st) { ok, c := xt1(XT_getArithmeticReductionCost_SSE2CostTbl, isd, mty); if ok return cost_add(arith, c); }
    if elt == type_int(1) {
        if isd == ISD_ADD {
            it := type_int(cast(u32) nelts);
            a := ica_types(iidn("llvm.ctpop"), it, .[it]);
            return cost_add(x86_cast_cost(t, .BITCAST, it, ty, CCH_NONE, kind), x86_intrinsic_cost(t, *a, kind));
        }
        if st_hasAVX512(st) { ok, c := xt1(XT_getArithmeticReductionCost_AVX512BoolReduction, isd, mty); if ok return cost_add(arith, c); }
        if st_hasAVX2(st) { ok, c := xt1(XT_getArithmeticReductionCost_AVX2BoolReduction, isd, mty); if ok return cost_add(arith, c); }
        if st_hasAVX(st) { ok, c := xt1(XT_getArithmeticReductionCost_AVX1BoolReduction, isd, mty); if ok return cost_add(arith, c); }
        if st_hasSSE2(st) { ok, c := xt1(XT_getArithmeticReductionCost_SSE2BoolReduction, isd, mty); if ok return cost_add(arith, c); }
        return bt_arithmetic_reduction_cost(t, opc, ty, has_fmf, fmf, kind);
    }
    ne := nelts;
    ssize := cast(s64) ic_primitive_size_bits(elt);
    if !is_pow2_s64(ne) || ssize != cast(s64) mvt_scalar_bits(mty) return bt_arithmetic_reduction_cost(t, opc, ty, has_fmf, fmf, kind);
    red: Cost = 0;
    cur := ty;
    if split {
        cur = xvec(elt, mvt_n(mty));
        red = cost_mul(x86_arith_cost(t, opc, cur, kind, OI_ANY, OI_ANY), ltc - 1);
        ne = cast(s64) mvt_n(mty);
    }
    red = cost_add(red, x86_reduction_levels(t, opc, NOT_INTRINSIC, ty, elt, ne, ssize, kind, 0, *cur));
    return cost_add(red, x86_vector_instr_cost(t, .EXTRACTELEMENT, cur, kind, 0, NONE, NONE));
}

// the halving loop shared by getArithmeticReductionCost and getMinMaxReductionCost (`id` != NOT_INTRINSIC: min/max)
x86_reduction_levels :: (t: *Tti, opc: Opcode, id: Intrinsic_Id, val_ty: Type_Id, elt: Type_Id, ne_in: s64, ssize: s64, kind: s64, fmf: u32, cur: *Type_Id) -> Cost {
    c: Cost = 0;
    ne := ne_in;
    // ValVTy->isFloatingPointTy() is false for a vector type, so the integer shuffle types are always used
    while ne > 1 {
        size := ne * ssize;
        ne /= 2;
        if size > 128 {
            sub := xvec(elt, ne);
            c = cost_add(c, x86_shuffle_cost(t, SK_EXTRACT_SUBVECTOR, cur.*, cur.*, .[], kind, ne, sub, .[], NONE));
            cur.* = sub;
        } else if size == 128 {
            sh := xvec(type_int(64), 2);
            c = cost_add(c, x86_shuffle_cost(t, SK_PERMUTE_SINGLE_SRC, sh, sh, .[], kind, 0, NONE, .[], NONE));
        } else if size == 64 {
            sh := xvec(type_int(32), 4);
            c = cost_add(c, x86_shuffle_cost(t, SK_PERMUTE_SINGLE_SRC, sh, sh, .[], kind, 0, NONE, .[], NONE));
        } else {
            sh := xvec(type_int(cast(u32) size), 128 / size);
            // the min/max variant always asks for the reciprocal-throughput shift cost
            sk := ifx id != NOT_INTRINSIC then TCK_RECIP_THROUGHPUT else kind;
            c = cost_add(c, x86_arith_cost(t, .LSHR, sh, sk, OI_ANY, .{OK_UNIFORM_CONSTANT_VALUE, OP_NONE}));
        }
        if id != NOT_INTRINSIC c = cost_add(c, x86_min_max_cost(t, id, cur.*, kind, fmf));
        else c = cost_add(c, x86_arith_cost(t, opc, cur.*, kind, OI_ANY, OI_ANY));
    }
    return c;
}

// X86TTIImpl::getMinMaxCost
x86_min_max_cost :: (t: *Tti, id: Intrinsic_Id, ty: Type_Id, kind: s64, fmf: u32) -> Cost {
    a := ica_types(id, ty, .[ty, ty], fmf);
    return x86_intrinsic_cost(t, *a, kind);
}

// BasicTTIImplBase::getMinMaxReductionCost
bt_min_max_reduction_cost :: (t: *Tti, id: Intrinsic_Id, ty_in: Type_Id, fmf: u32, kind: s64) -> Cost {
    if type_kind(ty_in) == .SVECTOR return COST_INVALID;
    ty := ty_in;
    elt := type_elem(ty);
    ne := xvec_n(ty);
    levels := log2_s64(ne);
    mm: Cost = 0; shuf: Cost = 0;
    _, ltm := bt_type_legalization_cost(*t.xl, ty);
    long := 0;
    mlen := ifx mvt_is_vec(ltm) then cast(s64) mvt_n(ltm) else 1;
    while ne > mlen {
        ne /= 2;
        sub := xvec(elt, ne);
        shuf = cost_add(shuf, x86_shuffle_cost(t, SK_EXTRACT_SUBVECTOR, sub, ty, .[], kind, ne, sub, .[], NONE));
        mm = cost_add(mm, x86_min_max_cost(t, id, sub, kind, fmf));
        ty = sub;
        long += 1;
    }
    levels -= long;
    shuf = cost_add(shuf, cost_mul(levels, x86_shuffle_cost(t, SK_PERMUTE_SINGLE_SRC, ty, ty, .[], kind, 0, ty, .[], NONE)));
    mm = cost_add(mm, cost_mul(levels, x86_min_max_cost(t, id, ty, kind, fmf)));
    return cost_add(cost_add(shuf, mm), x86_vector_instr_cost(t, .EXTRACTELEMENT, ty, kind, 0, NONE, NONE));
}

// X86TTIImpl::getMinMaxReductionCost
x86_min_max_reduction_cost :: (t: *Tti, id: Intrinsic_Id, ty: Type_Id, fmf: u32, kind: s64) -> Cost {
    st := *t.xl;
    ltc, mty := bt_type_legalization_cost(st, ty);
    isd: u32;
    n := iid_name(id);
    if is_int_type(scalar_type(ty)) isd = ifx n == "llvm.umin" || n == "llvm.umax" then ISD_UMIN else ISD_SMIN;
    else isd = ifx n == "llvm.minnum" || n == "llvm.maxnum" then ISD_FMINNUM else ISD_FMINIMUM;
    Row :: struct { cond: bool; tbl: [] XCost_Entry; }
    rows := Row.[
        .{st_hasBWI(st), XT_getMinMaxReductionCost_AVX512BWCostTbl},
        .{st_hasAVX512(st), XT_getMinMaxReductionCost_AVX512FCostTbl},
        .{st_hasAVX2(st), XT_getMinMaxReductionCost_AVX2CostTbl},
        .{st_hasAVX(st), XT_getMinMaxReductionCost_AVX1CostTbl},
        .{st_hasSSE41(st), XT_getMinMaxReductionCost_SSE41CostTbl},
        .{st_hasSSE2(st), XT_getMinMaxReductionCost_SSE2CostTbl},
    ];
    vt := x86_evt(st, ty);
    if evt_is_simple(vt) {
        for rows if it.cond { ok, c := xtk(it.tbl, isd, vt.m, kind); if ok return c; }
    }
    elt := type_elem(ty);
    ne := xvec_n(ty);
    cur := ty;
    mm: Cost = 0;
    if ltc != 1 && mvt_is_vec(mty) && cast(s64) mvt_n(mty) < ne {
        cur = xvec(elt, mvt_n(mty));
        mm = cost_mul(x86_min_max_cost(t, id, cur, kind, fmf), ltc - 1);
        ne = cast(s64) mvt_n(mty);
    }
    for rows if it.cond { ok, c := xtk(it.tbl, isd, mty, kind); if ok return cost_add(mm, c); }
    ssize := cast(s64) ic_primitive_size_bits(elt);
    if !is_pow2_s64(xvec_n(ty)) || ssize != cast(s64) mvt_scalar_bits(mty) return bt_min_max_reduction_cost(t, id, ty, fmf, kind);
    mm = cost_add(mm, x86_reduction_levels(t, .ADD, id, ty, elt, ne, ssize, kind, fmf, *cur));
    return cost_add(mm, x86_vector_instr_cost(t, .EXTRACTELEMENT, cur, kind, 0, NONE, NONE));
}

// getMultipleResultIntrinsicVectorLibCallCost(ICA, CostKind, CallRetElementIndex) (-1: no element). The vector
// libcalls RTLIB::getSINCOS / getSINCOSPI / getMODF select exist on X86 only with -vector-library=AMDLIBM
// (RuntimeLibcallsInfo: amd_vrs{4,8,16}_sincosf, amd_vrd{2,4,8}_sincos; none of them takes a mask).
bt_multiple_result_intrinsic_vector_lib_call_cost :: (t: *Tti, ica: *Ica, kind: s64, call_ret_element: s64) -> (bool, Cost) {
    ret := ica.ret;
    if type_kind(ret) != .STRUCT || !is_vectorized_ty(ret) return false, 0;
    ty := contained_types(ret)[0];
    if type_kind(ty) != .VECTOR return false, 0;
    n := iid_name(ica.id);
    elt := type_elem(ty); cnt := type_count(ty);
    available := false;
    if n == "llvm.sincos" && tli_vector_library == .AMDLIBM {
        if type_kind(elt) == .FLOAT && (cnt == 4 || cnt == 8 || cnt == 16) available = true;
        if type_kind(elt) == .DOUBLE && (cnt == 2 || cnt == 4 || cnt == 8) available = true;
    }
    if !available return false, 0;
    c := tti_call_instr_cost(t);
    for vt, idx: contained_types(ret) {
        if idx == call_ret_element continue;
        c = cost_add(c, tti_memory_op_cost(t, .LOAD, vt, dl_alignment(vt, true), 0, kind));
    }
    return true, c;
}

args_of :: inline (ica: *Ica) -> [] Value_Id { return ica.args; }
