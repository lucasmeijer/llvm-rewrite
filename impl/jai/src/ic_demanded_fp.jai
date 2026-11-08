// InstCombineSimplifyDemanded.cpp, floating-point half: SimplifyDemandedFPClass, SimplifyDemandedUseFPClass,
// SimplifyMultipleUseDemandedFPClass, SimplifyDemandedInstructionFPClass and their static helpers
// (getFPClassConstant, simplifyDemandedFPClassFabs / FnegFabs / CopysignMag / MinMax / Result,
// inferFastMathValueFlags, adjustDemandedMaskFromFlags, simplifyDemandedUseFPClassFPTrunc), in LLVM's order.

// getFPClassConstant: NONE when the classes don't resolve to one bit pattern
ic_get_fp_class_constant :: (ty: Type_Id, mask: u32, is_canonicalizing := false) -> Value_Id {
    if mask == FC_NONE return const_poison(ty);
    if mask == FC_POS_ZERO return const_null_value(ty);
    k := type_kind(ty);
    if k == .ARRAY || k == .STRUCT return NONE;
    fk := type_kind(scalar_type(ty));
    if mask == FC_NAN && is_canonicalizing return const_fp_words(ty, fp_default_nan(fk));
    if mask == {
        case FC_NEG_ZERO; return const_fp_words(ty, fp_zero(fk, true));
        case FC_POS_INF; return const_fp_words(ty, fp_inf(fk, false));
        case FC_NEG_INF; return const_fp_words(ty, fp_inf(fk, true));
        case FC_QNAN; if is_canonicalizing return const_fp_words(ty, fp_default_nan(fk)); return NONE;
    }
    return NONE;
}

// simplifyDemandedFPClassFabs
ic_sdfpc_fabs :: (known: *Known_FP_Class, src: Value_Id, demanded: u32, known_src_in: Known_FP_Class, nsz: bool) -> Value_Id {
    ks := known_src_in;
    if (demanded & FC_NAN) == FC_NONE kfpc_known_not(*ks, FC_NAN);
    if (demanded & FC_INF) == FC_NONE kfpc_known_not(*ks, FC_INF);
    if ks.sign_bit == 0 || ((demanded & FC_NAN) == FC_NONE && kfpc_is_known_never(ks, FC_NEGATIVE)) return src;
    if nsz && kfpc_is_known_never(ks, KFPC_ORDERED_LESS_THAN_ZERO_MASK | FC_NAN) return src;
    known.* = kfpc_fabs(ks);
    kfpc_known_not(known, fc_not(demanded));
    return NONE;
}

// inferFastMathValueFlags
ic_infer_fast_math_value_flags :: (fmf_in: u32, valid: u32, srcs: [] Known_FP_Class) -> u32 {
    fmf := fmf_in;
    if !(fmf & FMF_NNAN) && (valid & FC_NAN) == FC_NONE {
        all := true;
        for srcs if !kfpc_is_known_never_nan(it) { all = false; break; }
        if all fmf |= FMF_NNAN;
    }
    if !(fmf & FMF_NINF) && (valid & FC_INF) == FC_NONE {
        all := true;
        for srcs if !kfpc_is_known_never_infinity(it) { all = false; break; }
        if all fmf |= FMF_NINF;
    }
    return fmf;
}

// adjustDemandedMaskFromFlags
ic_adjust_demanded_mask_from_flags :: (demanded_in: u32, fmf: u32) -> u32 {
    d := demanded_in;
    if fmf & FMF_NNAN d &= fc_not(FC_NAN);
    if fmf & FMF_NINF d &= fc_not(FC_INF);
    return d;
}

// simplifyDemandedFPClassResult
ic_sdfpc_result :: (fpop: Value_Id, fmf: u32, demanded: u32, known: *Known_FP_Class, srcs: [] Known_FP_Class) -> Value_Id {
    valid := demanded & known.known_fp_classes;
    single := ic_get_fp_class_constant(vtype(fpop), valid, true);
    if single != NONE return single;
    inferred := ic_infer_fast_math_value_flags(fmf, valid, srcs);
    if inferred != fmf {
        drop_ub_implying_attrs_and_metadata(fpop);
        set_fmf(fpop, inferred);
        return fpop;
    }
    return NONE;
}

// simplifyDemandedFPClassFnegFabs
ic_sdfpc_fneg_fabs :: (known: *Known_FP_Class, src: Value_Id, demanded: u32, known_src_in: Known_FP_Class, nsz: bool) -> Value_Id {
    ks := known_src_in;
    if (demanded & FC_NAN) == FC_NONE kfpc_known_not(*ks, FC_NAN);
    if (demanded & FC_INF) == FC_NONE kfpc_known_not(*ks, FC_INF);
    if ks.sign_bit == 1 return src;
    if nsz && kfpc_is_known_never(ks, KFPC_ORDERED_GREATER_THAN_ZERO_MASK | FC_NAN) return src;
    known.* = kfpc_fneg(kfpc_fabs(ks));
    kfpc_known_not(known, fc_not(demanded));
    return NONE;
}

// simplifyDemandedFPClassCopysignMag
ic_sdfpc_copysign_mag :: (mag: Value_Id, demanded: u32, ks: Known_FP_Class, nsz: bool) -> Value_Id {
    if nsz {
        NEG_OR_ZERO :: FC_NEGATIVE | FC_POS_ZERO;
        POS_OR_ZERO :: FC_POSITIVE | FC_NEG_ZERO;
        if (demanded & fc_not(NEG_OR_ZERO)) == FC_NONE && kfpc_is_known_always(ks, NEG_OR_ZERO) return mag;
        if (demanded & fc_not(POS_OR_ZERO)) == FC_NONE && kfpc_is_known_always(ks, POS_OR_ZERO) return mag;
    } else {
        if (demanded & fc_not(FC_NEGATIVE)) == FC_NONE && ks.sign_bit == 1 return mag;
        if (demanded & fc_not(FC_POSITIVE)) == FC_NONE && ks.sign_bit == 0 return mag;
    }
    return NONE;
}

// simplifyDemandedFPClassMinMax
ic_sdfpc_min_max :: (known: *Known_FP_Class, id: Intrinsic_Id, ci: Value_Id, demanded: u32, kl: Known_FP_Class, kr: Known_FP_Class, nsz: bool) -> Value_Id {
    ozs := !nsz;
    lc := kl.known_fp_classes; rc := kr.known_fp_classes;
    kind: u8;
    if id == IID_MAXIMUM {
        kind = MM_MAXIMUM;
        if cannot_order_strictly_less(lc, rc, ozs) && kfpc_is_known_never(kr, FC_NAN) return op(ci, 0);
        if cannot_order_strictly_greater(lc, rc, ozs) && kfpc_is_known_never(kl, FC_NAN) return op(ci, 1);
    } else if id == IID_MINIMUM {
        kind = MM_MINIMUM;
        if cannot_order_strictly_greater(lc, rc, ozs) && kfpc_is_known_never(kr, FC_NAN) return op(ci, 0);
        if cannot_order_strictly_less(lc, rc, ozs) && kfpc_is_known_never(kl, FC_NAN) return op(ci, 1);
    } else if id == IID_MAXNUM || id == IID_MAXIMUMNUM {
        kind = ifx id == IID_MAXNUM then cast(u8) MM_MAXNUM else MM_MAXIMUMNUM;
        if cannot_order_strictly_less(lc, rc, ozs) && kfpc_is_known_never(kl, FC_NAN) return op(ci, 0);
        if cannot_order_strictly_greater(lc, rc, ozs) && kfpc_is_known_never(kr, FC_NAN) return op(ci, 1);
    } else if id == IID_MINNUM || id == IID_MINIMUMNUM {
        kind = ifx id == IID_MINNUM then cast(u8) MM_MINNUM else MM_MINIMUMNUM;
        if cannot_order_strictly_greater(lc, rc, ozs) && kfpc_is_known_never(kl, FC_NAN) return op(ci, 0);
        if cannot_order_strictly_less(lc, rc, ozs) && kfpc_is_known_never(kr, FC_NAN) return op(ci, 1);
    } else fatal("internal: not a min/max intrinsic");
    mode := dm_of_fn(ic.f, scalar_type(vtype(ci)));
    known.* = kfpc_min_max_like(kl, kr, kind, mode);
    kfpc_known_not(known, fc_not(demanded));
    return ic_get_fp_class_constant(vtype(ci), known.known_fp_classes, true);
}

// simplifyDemandedUseFPClassFPTrunc
ic_sdfpc_fptrunc :: (i: Value_Id, fmf: u32, demanded: u32, known: *Known_FP_Class, q: Simplify_Query, depth: u32) -> Value_Id {
    sd := demanded;
    if demanded & FC_NAN sd |= FC_NAN;
    if demanded & FC_NEG_ZERO sd |= FC_NEG_SUBNORMAL | FC_NEG_NORMAL;
    if demanded & FC_POS_ZERO sd |= FC_POS_SUBNORMAL | FC_POS_NORMAL;
    if demanded & FC_NEG_SUBNORMAL sd |= FC_NEG_NORMAL;
    if demanded & FC_POS_SUBNORMAL sd |= FC_POS_NORMAL;
    if demanded & FC_POS_INF sd |= FC_POS_NORMAL;
    if demanded & FC_NEG_INF sd |= FC_NEG_NORMAL;
    ks: Known_FP_Class;
    if ic_simplify_demanded_fp_class(i, 0, sd, *ks, q, depth + 1) return i;
    known.* = kfpc_fptrunc(ks);
    kfpc_known_not(known, fc_not(demanded));
    return ic_sdfpc_result(i, fmf, demanded, known, .[ks]);
}

// FPMathOperator::getFastMathFlags (0 if the instruction is not an FPMathOperator)
ic_fpop_fmf :: (i: Value_Id) -> (bool, u32) {
    if !is_fp_math_inst(i) return false, 0;
    return true, get_fmf(i);
}

ic_fp_mode :: (t: Type_Id) -> Denorm_Mode { return dm_of_fn(ic.f, scalar_type(t)); }

// SimplifyDemandedUseFPClass
ic_simplify_demanded_use_fp_class :: (i: Value_Id, demanded_in: u32, known: *Known_FP_Class, q: Simplify_Query, depth: u32) -> Value_Id {
    demanded := demanded_in;
    vty := vtype(i);
    is_fpop, fmf := ic_fpop_fmf(i);
    if is_fpop demanded = ic_adjust_demanded_mask_from_flags(demanded, fmf);
    nsz := (fmf & FMF_NSZ) != 0;

    // InsertPointGuard + SetInsertPoint(I)
    builder_at :: (i: Value_Id) -> Irb { s := ic.b; icb_set_insert_point(i); return s; }

    o := inst_op(i);
    if o == {
      case .FNEG;
        fneg_src := op(i, 0);
        if call_iid(fneg_src) == IID_FABS && has_one_use(fneg_src) {
            fneg_fabs_src := op(fneg_src, 0);
            ks: Known_FP_Class;
            if ic_simplify_demanded_fp_class(fneg_src, 0, fc_unknown_sign(demanded), *ks, q, depth + 1) return i;
            fabs_fmf := get_fmf(fneg_src);
            this_demanded := ic_adjust_demanded_mask_from_flags(demanded, fabs_fmf);
            is_nsz := nsz || (fabs_fmf & FMF_NSZ) != 0;
            s := ic_sdfpc_fneg_fabs(known, fneg_fabs_src, this_demanded, ks, is_nsz);
            if s != NONE return s;
            if (this_demanded & FC_NAN) == FC_NONE kfpc_known_not(*ks, FC_NAN);
            if (this_demanded & FC_INF) == FC_NONE kfpc_known_not(*ks, FC_INF);
            if ks.sign_bit == 0 return ic_replace_operand(i, 0, fneg_fabs_src);
            if is_nsz && kfpc_is_known_never(ks, KFPC_ORDERED_LESS_THAN_ZERO_MASK | FC_NAN) return ic_replace_operand(i, 0, fneg_fabs_src);
            return ic_get_fp_class_constant(vty, known.known_fp_classes);
        }
        if ic_simplify_demanded_fp_class(i, 0, fc_fneg(demanded), known, q, depth + 1) return i;
        known.* = kfpc_fneg(known.*);
        kfpc_known_not(known, fc_not(demanded));

      case .FADD; #through;
      case .FSUB;
        kl, kr: Known_FP_Class;
        if op(i, 0) == op(i, 1) && o == .FADD && is_guaranteed_not_to_be_undef(op(i, 0), q.ac, q.cxt, q.dt, depth + 1) {
            mode := ic_fp_mode(vty);
            sd := demanded;
            if demanded & FC_NAN sd |= FC_NAN;
            if demanded & FC_POS_NORMAL sd |= FC_POS_SUBNORMAL;
            if demanded & FC_NEG_NORMAL sd |= FC_NEG_SUBNORMAL;
            if !dm_eq(mode, DM_IEEE) {
                if demanded & FC_POS_ZERO {
                    sd |= FC_POS_SUBNORMAL;
                    pz_in := mode.input == DENORMAL_POSITIVE_ZERO || mode.input == DENORMAL_DYNAMIC;
                    pz_out := mode.output == DENORMAL_POSITIVE_ZERO || mode.output == DENORMAL_DYNAMIC;
                    if pz_in || pz_out sd |= FC_NEG_SUBNORMAL;
                }
                if demanded & FC_NEG_ZERO sd |= FC_NEG_SUBNORMAL;
            }
            if demanded & FC_POS_INF sd |= FC_POS_NORMAL;
            if demanded & FC_NEG_INF sd |= FC_NEG_NORMAL;
            if ic_simplify_demanded_fp_class(i, 0, sd, *kl, q, depth + 1) return i;
            known.* = kfpc_fadd_self(kl, mode);
            kr = kl;
        } else {
            sd: u32 = FC_FINITE;
            if demanded & FC_NAN sd |= FC_NAN | FC_INF;
            if demanded & FC_INF sd |= FC_INF;
            if ic_simplify_demanded_fp_class(i, 1, sd, *kr, q, depth + 1) || ic_simplify_demanded_fp_class(i, 0, sd, *kl, q, depth + 1) return i;
            mode := ic_fp_mode(vty);
            known.* = ifx o == .FADD then kfpc_fadd(kl, kr, mode) else kfpc_fsub(kl, kr, mode);
        }
        kfpc_known_not(known, fc_not(demanded));
        single := ic_get_fp_class_constant(vty, known.known_fp_classes, true);
        if single != NONE return single;
        not_nan := (demanded & FC_NAN) == FC_NONE;
        if not_nan && o == .FADD && kfpc_is_known_always(kr, FC_INF | FC_NAN) && kfpc_is_known_never(kl, FC_NAN) return op(i, 1);
        if not_nan && kfpc_is_known_always(kl, FC_INF | FC_NAN) && kfpc_is_known_never(kr, FC_NAN) return op(i, 0);
        inferred := ic_infer_fast_math_value_flags(fmf, known.known_fp_classes, .[kl, kr]);
        if inferred != fmf { set_fmf(i, inferred); return i; }
        return NONE;

      case .FMUL;
        kl, kr: Known_FP_Class;
        x := op(i, 0); y := op(i, 1);
        sd := demanded & (FC_NAN | FC_ZERO | FC_SUBNORMAL | FC_NORMAL);
        if demanded & FC_INF sd |= FC_SUBNORMAL | FC_NORMAL | FC_INF;
        if demanded & FC_NAN { sd |= FC_ZERO | FC_INF | FC_NAN; sd |= FC_SUBNORMAL; }
        if demanded & (FC_NORMAL | FC_SUBNORMAL) sd |= FC_NORMAL | FC_SUBNORMAL;
        if demanded & FC_ZERO sd |= FC_NORMAL | FC_SUBNORMAL;
        if x == y && is_guaranteed_not_to_be_undef(x, q.ac, q.cxt, q.dt, depth + 1) {
            if ic_simplify_demanded_fp_class(i, 0, sd, *kl, q, depth + 1) return i;
            mode := ic_fp_mode(vty);
            known.* = kfpc_square(kl, mode);
            kfpc_known_not(known, fc_not(demanded));
            folded := ic_get_fp_class_constant(vty, known.known_fp_classes, true);
            if folded != NONE return folded;
            if kfpc_is_known_always(known.*, FC_POS_ZERO | FC_POS_INF | FC_NAN) && kfpc_is_known_never(kl, FC_SUBNORMAL | FC_NORMAL) {
                if kfpc_is_known_always(kl, FC_POSITIVE) return x;
                saved := builder_at(i); defer ic.b = saved;
                fabs := icb_fabs_fmf(x, fmf);
                ic_take_name(fabs, i);
                return fabs;
            }
            return NONE;
        }
        if ic_simplify_demanded_fp_class(i, 1, sd, *kr, q, depth + 1) || ic_simplify_demanded_fp_class(i, 0, sd, *kl, q, depth + 1) return i;
        if fmf & FMF_NINF { kfpc_known_not(*kl, FC_INF); kfpc_known_not(*kr, FC_INF); }
        non_nan := (demanded & FC_NAN) == FC_NONE;
        if (non_nan || kfpc_is_known_never_inf_or_nan(kl)) && kfpc_is_known_always(kr, FC_POS_ZERO | FC_NAN) {
            saved := builder_at(i); defer ic.b = saved;
            cs := icb_copysign_fmf(y, x, fmf);
            ic_take_name(cs, i);
            return cs;
        }
        if kfpc_is_known_always(kl, FC_POS_ZERO | FC_NAN) && (non_nan || kfpc_is_known_never_inf_or_nan(kr)) {
            saved := builder_at(i); defer ic.b = saved;
            cs := icb_copysign_fmf(x, y, fmf);
            ic_take_name(cs, i);
            return cs;
        }
        if (non_nan || kfpc_is_known_never_inf_or_nan(kl)) && kfpc_is_known_always(kr, FC_NEG_ZERO | FC_NAN) {
            saved := builder_at(i); defer ic.b = saved;
            cs := icb_copysign_fmf(y, icb_fneg_fmf(x, fmf), fmf);
            ic_take_name(cs, i);
            return cs;
        }
        if kfpc_is_known_always(kl, FC_NEG_ZERO | FC_NAN) && (non_nan || kfpc_is_known_never_inf_or_nan(kr)) {
            saved := builder_at(i); defer ic.b = saved;
            cs := icb_copysign_fmf(x, icb_fneg_fmf(y, fmf), fmf);
            ic_take_name(cs, i);
            return cs;
        }
        mode := ic_fp_mode(vty);
        if kfpc_is_known_always(kl, FC_INF | FC_NAN) && kfpc_is_known_never_nan(kr) && kfpc_cannot_be_ordered_greater_eq_zero(kr, mode) {
            saved := builder_at(i); defer ic.b = saved;
            n := icb_fneg_fmf(x, fmf);
            ic_take_name(n, i);
            return n;
        }
        if kfpc_is_known_always(kr, FC_INF | FC_NAN) && kfpc_is_known_never_nan(kl) && kfpc_cannot_be_ordered_greater_eq_zero(kl, mode) {
            saved := builder_at(i); defer ic.b = saved;
            n := icb_fneg_fmf(y, fmf);
            ic_take_name(n, i);
            return n;
        }
        known.* = kfpc_fmul(kl, kr, mode);
        kfpc_known_not(known, fc_not(demanded));
        single := ic_get_fp_class_constant(vty, known.known_fp_classes, true);
        if single != NONE return single;
        inferred := ic_infer_fast_math_value_flags(fmf, known.known_fp_classes, .[kl, kr]);
        if inferred != fmf { set_fmf(i, inferred); return i; }
        return NONE;

      case .FDIV;
        x := op(i, 0); y := op(i, 1);
        fk := type_kind(scalar_type(vty));
        if x == y && is_guaranteed_not_to_be_undef(x, q.ac, q.cxt, q.dt, depth + 1) {
            saved := builder_at(i); defer ic.b = saved;
            is_zero_or_nan := icb_fcmp_fmf(FCMP_UEQ, x, const_null_value(vty), fmf);
            fabs := icb_fabs_fmf(x, fmf);
            is_inf_or_nan := icb_fcmp_fmf(FCMP_UEQ, fabs, const_fp_words(vty, fp_inf(fk, false)), fmf);
            is_any := icb_or(is_inf_or_nan, is_zero_or_nan);
            r := icb_select_fmf(is_any, const_fp_words(vty, fp_default_nan(fk)), fp_from_double(vty, 1.0), fmf, "", NONE);
            if is_select_inst(r) ic_set_unknown_profile_if_profiled(r);
            return r;
        }
        mode := ic_fp_mode(vty);
        sd := (demanded & FC_NAN) | FC_SUBNORMAL;
        if demanded & (FC_SUBNORMAL | FC_NORMAL) sd |= FC_NORMAL;
        if demanded & FC_NAN sd |= FC_ZERO | FC_INF | FC_NAN;
        if demanded & FC_ZERO sd |= FC_NORMAL | FC_SUBNORMAL;
        ld := sd; rd := sd;
        if demanded & FC_ZERO { ld |= FC_ZERO; rd |= FC_INF; }
        if demanded & FC_INF { ld |= FC_INF | FC_NORMAL | FC_SUBNORMAL; rd |= FC_ZERO | FC_SUBNORMAL | FC_NORMAL; }
        kl, kr: Known_FP_Class;
        if ic_simplify_demanded_fp_class(i, 0, ld, *kl, q, depth + 1) || ic_simplify_demanded_fp_class(i, 1, rd, *kr, q, depth + 1) return i;
        if nsz && kfpc_is_known_always(kl, FC_ZERO) && kfpc_is_known_never_nan(kr) return const_null_value(vty);
        if kfpc_is_known_always(kl, FC_POS_ZERO) && kfpc_is_known_never_nan(kr) {
            saved := builder_at(i); defer ic.b = saved;
            cs := icb_copysign_fmf(x, y, fmf);
            ic_take_name(cs, i);
            return cs;
        }
        not_nan := (demanded & FC_NAN) == FC_NONE;
        not_inf := (demanded & FC_INF) == FC_NONE;
        if !not_inf && ((not_nan || (kfpc_is_known_never_nan(kl) && kfpc_is_known_never_logical_zero(kl, mode))) &&
                        (kfpc_is_known_always(kr, FC_POS_ZERO) || (nsz && kfpc_is_known_always(kr, FC_ZERO)))) {
            saved := builder_at(i); defer ic.b = saved;
            cs := icb_copysign_fmf(const_fp_words(vty, fp_inf(fk, false)), x, fmf);
            ic_take_name(cs, i);
            return cs;
        }
        if not_nan && not_inf && kfpc_is_known_always(kr, FC_ZERO) return const_poison(vty);
        known.* = kfpc_fdiv(kl, kr, mode);
        kfpc_known_not(known, fc_not(demanded));
        single := ic_get_fp_class_constant(vty, known.known_fp_classes, true);
        if single != NONE return single;
        inferred := ic_infer_fast_math_value_flags(fmf, known.known_fp_classes, .[kl, kr]);
        if inferred != fmf { set_fmf(i, inferred); return i; }
        return NONE;

      case .FPTRUNC;
        return ic_sdfpc_fptrunc(i, fmf, demanded, known, q, depth);

      case .FPEXT;
        sd := demanded;
        if demanded & FC_NAN sd |= FC_NAN;
        if (demanded & FC_NEG_NORMAL) != FC_NONE sd |= FC_NEG_SUBNORMAL;
        if (demanded & FC_POS_NORMAL) != FC_NONE sd |= FC_POS_SUBNORMAL;
        ks: Known_FP_Class;
        if ic_simplify_demanded_fp_class(i, 0, sd, *ks, q, depth + 1) return i;
        known.* = kfpc_fpext(ks, type_kind(scalar_type(vty)), type_kind(scalar_type(vtype(op(i, 0)))));
        kfpc_known_not(known, fc_not(demanded));
        return ic_sdfpc_result(i, fmf, demanded, known, .[ks]);

      case .CALL;
        r, done := ic_sdfpc_call(i, demanded, fmf, known, q, depth);
        if done return r;

      case .SELECT;
        kl, kr: Known_FP_Class;
        if ic_simplify_demanded_fp_class(i, 2, demanded, *kr, q, depth + 1) || ic_simplify_demanded_fp_class(i, 1, demanded, *kl, q, depth + 1) return i;
        if kfpc_is_known_never(kl, demanded) return op(i, 2);
        if kfpc_is_known_never(kr, demanded) return op(i, 1);
        adjust_known_fp_class_for_select_arm(*kl, op(i, 0), op(i, 1), false, q, depth);
        adjust_known_fp_class_for_select_arm(*kr, op(i, 0), op(i, 2), true, q, depth);
        known.* = kfpc_intersect_with(kl, kr);
        kfpc_known_not(known, fc_not(demanded));

      case .EXTRACTELEMENT;
        if ic_simplify_demanded_fp_class(i, 0, demanded, known, q, depth + 1) return i;
        kfpc_known_not(known, fc_not(demanded));

      case .INSERTELEMENT;
        kins, kvec: Known_FP_Class;
        if ic_simplify_demanded_fp_class(i, 1, demanded, *kins, q, depth + 1) || ic_simplify_demanded_fp_class(i, 0, demanded, *kvec, q, depth + 1) return i;
        known.* = kfpc_or(kvec, kins);
        kfpc_known_not(known, fc_not(demanded));

      case .SHUFFLEVECTOR;
        kl, kr: Known_FP_Class;
        if ic_simplify_demanded_fp_class(i, 1, demanded, *kr, q, depth + 1) || ic_simplify_demanded_fp_class(i, 0, demanded, *kl, q, depth + 1) return i;
        known.* = kfpc_or(kl, kr);
        kfpc_known_not(known, fc_not(demanded));

      case .INSERTVALUE;
        kagg, kelt: Known_FP_Class;
        if ic_simplify_demanded_fp_class(i, 0, demanded, *kagg, q, depth + 1) || ic_simplify_demanded_fp_class(i, 1, demanded, *kelt, q, depth + 1) return i;
        known.* = kfpc_or(kagg, kelt);

      case .EXTRACTVALUE;
        src := op(i, 0);
        idx := inst_indices(i);
        if idx.count == 1 && idx[0] == 0 && has_one_use(src) && call_iid(src) == IID_FREXP {
            sd: u32 = FC_NONE;
            if demanded & FC_NAN sd |= FC_NAN;
            if demanded & FC_NEG_FINITE sd |= FC_NEG_FINITE;
            if demanded & FC_POS_FINITE sd |= FC_POS_FINITE;
            if demanded & FC_POS_INF sd |= FC_POS_INF;
            if demanded & FC_NEG_INF sd |= FC_NEG_INF;
            ks: Known_FP_Class;
            if ic_simplify_demanded_fp_class(src, 0, sd, *ks, q, depth + 1) return i;
            known.* = kfpc_frexp_mant(ks, ic_fp_mode(vty));
            known.known_fp_classes &= demanded;
            single := ic_get_fp_class_constant(vty, known.known_fp_classes, true);
            if single != NONE return single;
            if kfpc_is_known_always(known.*, FC_INF | FC_NAN) return op(src, 0);
            return NONE;
        }
        ks: Known_FP_Class;
        if ic_simplify_demanded_fp_class(i, 0, demanded, *ks, q, depth + 1) return i;
        known.* = ks;

      case .PHI;
        PHI_RECURSION_LIMIT :: MAX_ANALYSIS_RECURSION_DEPTH - 2;
        if depth >= PHI_RECURSION_LIMIT return ic_get_fp_class_constant(vty, known.known_fp_classes);
        ctx_q := q; ctx_q.cc = null;   // getWithoutCondContext
        first := true;
        changed := false;
        n := nops(i);
        if n > 0 for k: 0..n-1 {
            pred := phi_block(i, k);
            ks: Known_FP_Class;
            if ic_simplify_demanded_fp_class(i, k, demanded, *ks, sq_with_instruction(ctx_q, block_terminator(pred)), depth + 1) {
                // setIncomingValueForBlock(PredBB, getIncomingValue(I))
                nv := op(i, k);
                for j: 0..n-1 if phi_block(i, j) == pred set_op(i, j, nv);
                changed = true;
            }
            if first { known.* = ks; first = false; }
            else known.* = kfpc_or(known.*, ks);
        }
        if changed return i;
        kfpc_known_not(known, fc_not(demanded));

      case;
        known.* = compute_known_fp_class(i, demanded, q, depth + 1);
        kfpc_known_not(known, fc_not(demanded));
    }
    return ic_get_fp_class_constant(vty, known.known_fp_classes);
}

// the Instruction::Call case of SimplifyDemandedUseFPClass; done = false: fall out of the switch (getFPClassConstant)
ic_sdfpc_call :: (i: Value_Id, demanded: u32, fmf: u32, known: *Known_FP_Class, q: Simplify_Query, depth: u32) -> (Value_Id, done: bool) {
    ci := i;
    vty := vtype(i);
    fk := type_kind(scalar_type(vty));
    nsz := (fmf & FMF_NSZ) != 0;
    id := call_iid(ci);
    builder_at :: (i: Value_Id) -> Irb { s := ic.b; icb_set_insert_point(i); return s; }
    if id == {
      case IID_FABS;
        ks: Known_FP_Class;
        if ic_simplify_demanded_fp_class(i, 0, fc_inverse_fabs(demanded), *ks, q, depth + 1) return i, true;
        s := ic_sdfpc_fabs(known, op(ci, 0), demanded, ks, nsz);
        if s != NONE return s, true;
        return NONE, false;
      case IID_ARITHMETIC_FENCE;
        if ic_simplify_demanded_fp_class(i, 0, demanded, known, q, depth + 1) return i, true;
        return NONE, false;
      case IID_COPYSIGN;
        any_sign := fc_unknown_sign(demanded);
        kmag: Known_FP_Class;
        if ic_simplify_demanded_fp_class(ci, 0, any_sign, *kmag, q, depth + 1) return i, true;
        if (demanded & FC_NEGATIVE) == demanded { set_op(ci, 1, fp_from_double(vty, -1.0)); return i, true; }
        if (demanded & FC_POSITIVE) == demanded { set_op(ci, 1, const_null_value(vty)); return i, true; }
        s := ic_sdfpc_copysign_mag(op(ci, 0), demanded, kmag, nsz);
        if s != NONE return s, true;
        ksign := compute_known_fp_class(op(ci, 1), FC_ALL_FLAGS, q, depth + 1);
        if kmag.sign_bit >= 0 && ksign.sign_bit >= 0 && kmag.sign_bit == ksign.sign_bit return op(ci, 0), true;
        if fmf & FMF_NNAN kfpc_known_not(*ksign, FC_NAN);
        if ksign.sign_bit == 0 {
            drop_ub_implying_attrs_and_metadata(ci);
            set_op(ci, 1, const_null_value(vty));
            return i, true;
        }
        if ksign.sign_bit == 1 {
            drop_ub_implying_attrs_and_metadata(ci);
            set_op(ci, 1, fp_from_double(vty, -1.0));
            return i, true;
        }
        known.* = kfpc_copysign(kmag, ksign);
        kfpc_known_not(known, fc_not(demanded));
        return NONE, false;
      case IID_FMA; #through;
      case IID_FMULADD;
        sd := demanded | fc_not(FC_NAN);
        if demanded & FC_NAN sd |= FC_NAN;
        ks: [3] Known_FP_Class;
        mode := ic_fp_mode(vty);
        if op(ci, 0) == op(ci, 1) && is_guaranteed_not_to_be_undef(op(ci, 0), q.ac, q.cxt, q.dt, depth + 1) {
            if ic_simplify_demanded_fp_class(ci, 0, sd, *ks[0], q, depth + 1) || ic_simplify_demanded_fp_class(ci, 2, sd, *ks[2], q, depth + 1) return i, true;
            ks[1] = ks[0];
            known.* = kfpc_fma_square(ks[0], ks[2], mode);
        } else {
            for k: 0..2 if ic_simplify_demanded_fp_class(ci, cast(u32) k, sd, *ks[k], q, depth + 1) return ci, true;
            known.* = kfpc_fma(ks[0], ks[1], ks[2], mode);
        }
        return ic_sdfpc_result(ci, fmf, demanded, known, ks), true;
      case IID_MAXIMUM; #through;
      case IID_MINIMUM; #through;
      case IID_MAXIMUMNUM; #through;
      case IID_MINIMUMNUM; #through;
      case IID_MAXNUM; #through;
      case IID_MINNUM;
        propagate_nan := id == IID_MAXIMUM || id == IID_MINIMUM;
        sd: u32 = ifx propagate_nan && (demanded & FC_NAN) == FC_NONE then demanded | fc_not(FC_NAN) else FC_ALL_FLAGS;
        kl, kr: Known_FP_Class;
        if ic_simplify_demanded_fp_class(ci, 1, sd, *kr, q, depth + 1) || ic_simplify_demanded_fp_class(ci, 0, sd, *kl, q, depth + 1) return i, true;
        s := ic_sdfpc_min_max(known, id, ci, demanded, kl, kr, nsz);
        if s != NONE return s, true;
        valid := demanded & known.known_fp_classes;
        inferred := fmf;
        if !nsz {
            zero_mask: u32 = FC_ZERO;
            mode := ic_fp_mode(vty);
            if !dm_eq(mode, DM_IEEE) zero_mask |= FC_SUBNORMAL;
            not_logical0 := (valid & zero_mask) == FC_NONE;
            if not_logical0 || ((kfpc_is_known_never_logical_neg_zero(kl, mode) || kfpc_is_known_never_logical_pos_zero(kr, mode)) &&
                                (kfpc_is_known_never_logical_pos_zero(kl, mode) || kfpc_is_known_never_logical_neg_zero(kr, mode)))
                inferred |= FMF_NSZ;
        }
        if !(fmf & FMF_NNAN) && ((propagate_nan && (valid & FC_NAN) == FC_NONE) || (kfpc_is_known_never_nan(kl) && kfpc_is_known_never_nan(kr))) {
            drop_ub_implying_attrs_and_metadata(ci);
            inferred |= FMF_NNAN;
        }
        if inferred != fmf { set_fmf(ci, inferred); return ci, true; }
        return NONE, true;
      case IID_EXP; #through;
      case IID_EXP2; #through;
      case IID_EXP10;
        if (demanded & FC_POSITIVE) == FC_NONE {
            if (demanded & FC_NAN) == FC_NONE return const_poison(vty), true;
            if (demanded & fc_not(FC_NAN)) == FC_NONE return const_fp_words(vty, fp_default_nan(fk)), true;
            return op(ci, 0), true;
        }
        sd := demanded & FC_NAN;
        if demanded & FC_NAN sd |= FC_NAN;
        if demanded & FC_ZERO { sd |= FC_NEG_INF; sd |= FC_NEG_NORMAL; }
        if demanded & FC_POS_SUBNORMAL sd |= FC_NEG_NORMAL;
        if demanded & FC_POS_NORMAL sd |= FC_NORMAL | FC_SUBNORMAL | FC_ZERO;
        if demanded & FC_POS_INF sd |= FC_POS_INF | FC_POS_NORMAL;
        ks: Known_FP_Class;
        if ic_simplify_demanded_fp_class(i, 0, sd, *ks, q, depth + 1) return i, true;
        if kfpc_is_known_always(ks, FC_ZERO) return fp_from_double(vty, 1.0), true;
        if kfpc_is_known_always(ks, FC_NAN) return op(ci, 0), true;
        if kfpc_is_known_always(ks, FC_ZERO | FC_NAN) {
            saved := builder_at(ci); defer ic.b = saved;
            return icb_binop_fmf(.FADD, op(ci, 0), fp_from_double(vty, 1.0), fmf), true;
        }
        if kfpc_is_known_always(ks, FC_INF | FC_NAN) {
            saved := builder_at(ci); defer ic.b = saved;
            x := op(ci, 0);
            is_pos_inf_or_nan := icb_fcmp_fmf(FCMP_UEQ, x, const_fp_words(vty, fp_inf(fk, false)), fmf);
            r := icb_select_fmf(is_pos_inf_or_nan, x, const_null_value(vty), fmf, "", NONE);
            if is_select_inst(r) ic_set_unknown_profile_if_profiled(r);
            return r, true;
        }
        known.* = kfpc_exp(ks);
        kfpc_known_not(known, fc_not(demanded));
        return ic_sdfpc_result(ci, fmf, demanded, known, .[ks]), true;
      case IID_LOG; #through;
      case IID_LOG2; #through;
      case IID_LOG10;
        dsm := demanded & (FC_NAN | FC_POS_INF);
        if demanded & FC_NAN dsm |= FC_NAN;
        mode := ic_fp_mode(vty);
        if demanded & FC_NAN dsm |= FC_NEGATIVE & fc_not(FC_NEG_ZERO);
        if demanded & FC_NEG_INF {
            dsm |= FC_ZERO;
            if dm_inputs_are_zero(mode) || mode.input == DENORMAL_DYNAMIC dsm |= FC_SUBNORMAL;
        }
        if demanded & FC_NORMAL dsm |= FC_NORMAL | FC_SUBNORMAL;
        if demanded & FC_ZERO dsm |= FC_POS_NORMAL;
        ks: Known_FP_Class;
        if ic_simplify_demanded_fp_class(i, 0, dsm, *ks, q, depth + 1) return i, true;
        known.* = kfpc_log(ks, mode);
        kfpc_known_not(known, fc_not(demanded));
        return ic_sdfpc_result(ci, fmf, demanded, known, .[ks]), true;
      case IID_SQRT;
        dsm := demanded & (FC_NEG_ZERO | FC_POSITIVE | FC_NAN);
        if demanded & FC_NAN dsm |= FC_NAN | (FC_NEGATIVE & fc_not(FC_NEG_ZERO));
        if demanded & FC_POS_NORMAL dsm |= FC_POS_SUBNORMAL;
        ks: Known_FP_Class;
        if ic_simplify_demanded_fp_class(i, 0, dsm, *ks, q, depth + 1) return i, true;
        if (demanded & FC_NAN) == FC_NONE kfpc_known_not(*ks, (FC_NEGATIVE & fc_not(FC_NEG_ZERO)) | FC_NAN);
        if (demanded & FC_POS_INF) == FC_NONE kfpc_known_not(*ks, FC_POS_INF);
        mode := ic_fp_mode(vty);
        if kfpc_is_known_never(ks, FC_POSITIVE) && kfpc_is_known_never_logical_zero(ks, mode) return const_fp_words(vty, fp_default_nan(fk)), true;
        known.* = kfpc_sqrt(ks, mode);
        kfpc_known_not(known, fc_not(demanded));
        if known.known_fp_classes == FC_ZERO {
            if nsz return const_null_value(vty), true;
            saved := builder_at(ci); defer ic.b = saved;
            cs := icb_copysign_fmf(const_null_value(vty), op(ci, 0), fmf);
            ic_take_name(cs, ci);
            return cs, true;
        }
        return ic_sdfpc_result(ci, fmf, demanded, known, .[ks]), true;
      case IID_LDEXP;
        sd := demanded & FC_INF;
        if demanded & FC_NAN sd |= FC_NAN;
        if demanded & FC_POS_INF sd |= FC_POS_NORMAL | FC_POS_SUBNORMAL;
        if demanded & FC_NEG_INF sd |= FC_NEG_NORMAL | FC_NEG_SUBNORMAL;
        if demanded & (FC_POS_NORMAL | FC_POS_SUBNORMAL) sd |= FC_POS_NORMAL | FC_POS_SUBNORMAL;
        if demanded & (FC_NEG_NORMAL | FC_NEG_SUBNORMAL) sd |= FC_NEG_NORMAL | FC_NEG_SUBNORMAL;
        if demanded & FC_POS_ZERO sd |= FC_POS_FINITE;
        if demanded & FC_NEG_ZERO sd |= FC_NEG_FINITE;
        ks: Known_FP_Class;
        if ic_simplify_demanded_fp_class(ci, 0, sd, *ks, q, depth + 1) return ci, true;
        mode := ic_fp_mode(vty);
        kb := known_bits(op(ci, 1), q, depth + 1);
        known.* = kfpc_ldexp(ks, kb_signed_min_value(kb), kb_signed_max_value(kb), fk, mode);
        kfpc_known_not(known, fc_not(demanded));
        return ic_sdfpc_result(ci, fmf, demanded, known, .[ks]), true;
      case IID_TRUNC; #through;
      case IID_FLOOR; #through;
      case IID_CEIL; #through;
      case IID_RINT; #through;
      case IID_NEARBYINT; #through;
      case IID_ROUND; #through;
      case IID_ROUNDEVEN;
        dsm := demanded;
        if demanded & FC_NAN dsm |= FC_NAN;
        if demanded & FC_NEG_ZERO dsm |= FC_NEG_SUBNORMAL | FC_NEG_NORMAL;
        if demanded & FC_POS_ZERO dsm |= FC_POS_SUBNORMAL | FC_POS_NORMAL;
        ks: Known_FP_Class;
        if ic_simplify_demanded_fp_class(ci, 0, dsm, *ks, q, depth + 1) return i, true;
        if kfpc_is_known_always(ks, FC_INF | FC_NAN | FC_ZERO) return op(ci, 0), true;
        nearest_or_trunc := id == IID_ROUND || id == IID_ROUNDEVEN || id == IID_NEARBYINT || id == IID_RINT || id == IID_TRUNC;
        if (id == IID_FLOOR || nearest_or_trunc) && kfpc_is_known_always(ks, FC_POS_ZERO | FC_POS_SUBNORMAL) return const_null_value(vty), true;
        if (id == IID_CEIL || nearest_or_trunc) && kfpc_is_known_always(ks, FC_NEG_ZERO | FC_NEG_SUBNORMAL) return const_fp_words(vty, fp_zero(fk, true)), true;
        if id == IID_FLOOR && kfpc_is_known_always(ks, FC_NEG_SUBNORMAL) return fp_from_double(vty, -1.0), true;
        if id == IID_CEIL && kfpc_is_known_always(ks, FC_POS_SUBNORMAL) return fp_from_double(vty, 1.0), true;
        known.* = kfpc_round_to_integral(ks, id == IID_TRUNC, fk == .PPC_FP128);
        kfpc_known_not(known, fc_not(demanded));
        single := ic_get_fp_class_constant(vty, known.known_fp_classes, true);
        if single != NONE return single, true;
        if (id == IID_TRUNC || nearest_or_trunc) && kfpc_is_known_always(ks, FC_ZERO | FC_SUBNORMAL) {
            saved := builder_at(ci); defer ic.b = saved;
            cs := icb_copysign_fmf(const_null_value(vty), op(ci, 0), ic.b_fmf);
            ic_take_name(cs, ci);
            return cs, true;
        }
        inferred := ic_infer_fast_math_value_flags(fmf, known.known_fp_classes, .[ks]);
        if inferred != fmf {
            drop_ub_implying_attrs_and_metadata(ci);
            set_fmf(ci, inferred);
            return ci, true;
        }
        return NONE, true;
      case IID_FPTRUNC_ROUND;
        return ic_sdfpc_fptrunc(ci, fmf, demanded, known, q, depth), true;
      case IID_CANONICALIZE;
        // isIEEELikeFPTy
        if fk == .HALF || fk == .BFLOAT || fk == .FLOAT || fk == .DOUBLE || fk == .FP128 {
            mode := ic_fp_mode(vty);
            sd := demanded;
            if (demanded & FC_QNAN) != FC_NONE sd |= FC_SNAN;
            if !dm_eq(mode, DM_IEEE) {
                if demanded & FC_POS_ZERO sd |= FC_POS_SUBNORMAL;
                if demanded & FC_NEG_ZERO sd |= FC_NEG_SUBNORMAL;
            }
            if dm_eq(mode, DM_PRESERVE_SIGN) {
                if (demanded & FC_POS_ZERO) == FC_NONE sd &= fc_not(FC_POS_SUBNORMAL);
                if (demanded & FC_NEG_ZERO) == FC_NONE sd &= fc_not(FC_NEG_SUBNORMAL);
            }
            ks: Known_FP_Class;
            if ic_simplify_demanded_fp_class(i, 0, sd, *ks, q, depth + 1) return i, true;
            known.* = kfpc_canonicalize(ks, mode);
            kfpc_known_not(known, fc_not(demanded));
            single := ic_get_fp_class_constant(vty, known.known_fp_classes);
            if single != NONE return single, true;
            if kfpc_is_known_never_nan(ks) && (dm_eq(mode, DM_IEEE) || kfpc_is_known_never_subnormal(ks)) return op(ci, 0), true;
            inferred := ic_infer_fast_math_value_flags(fmf, known.known_fp_classes, .[ks]);
            if inferred != fmf {
                drop_ub_implying_attrs_and_metadata(ci);
                set_fmf(ci, inferred);
                return ci, true;
            }
            return NONE, true;
        }
        known.* = compute_known_fp_class(i, demanded, q, depth + 1);
        kfpc_known_not(known, fc_not(demanded));
        return NONE, false;
    }
    known.* = compute_known_fp_class(i, demanded, q, depth + 1);
    kfpc_known_not(known, fc_not(demanded));
    return NONE, false;
}

// SimplifyMultipleUseDemandedFPClass
ic_simplify_multiple_use_demanded_fp_class :: (i: Value_Id, demanded_in: u32, known: *Known_FP_Class, q: Simplify_Query, depth: u32) -> Value_Id {
    demanded := demanded_in;
    is_fpop, fmf := ic_fpop_fmf(i);
    if is_fpop demanded = ic_adjust_demanded_mask_from_flags(demanded, fmf);
    o := inst_op(i);
    handled := false;
    if o == .SELECT {
        kr := compute_known_fp_class(op(i, 2), demanded, q, depth + 1);
        if kfpc_is_known_never(kr, demanded) return op(i, 1);
        kl := compute_known_fp_class(op(i, 1), demanded, q, depth + 1);
        if kfpc_is_known_never(kl, demanded) return op(i, 2);
        adjust_known_fp_class_for_select_arm(*kl, op(i, 0), op(i, 1), false, q, depth);
        adjust_known_fp_class_for_select_arm(*kr, op(i, 0), op(i, 2), true, q, depth);
        known.* = kfpc_intersect_with(kl, kr);
        kfpc_known_not(known, fc_not(demanded));
        handled = true;
    } else if o == .FNEG {
        fneg_src := op(i, 0);
        if call_iid(fneg_src) != IID_FABS {
            known.* = compute_known_fp_class(i, demanded, q, depth + 1);
        } else {
            src := op(fneg_src, 0);
            ks := compute_known_fp_class(src, FC_ALL_FLAGS, q, depth + 1);
            this_demanded := ic_adjust_demanded_mask_from_flags(demanded, get_fmf(fneg_src));
            s := ic_sdfpc_fneg_fabs(known, src, this_demanded, ks, false);
            if s != NONE return s;
        }
        handled = true;
    } else if o == .CALL {
        id := call_iid(i);
        if id == IID_FABS {
            src := op(i, 0);
            ks := compute_known_fp_class(src, FC_ALL_FLAGS, q, depth + 1);
            s := ic_sdfpc_fabs(known, src, demanded, ks, false);
            if s != NONE return s;
            handled = true;
        } else if id == IID_COPYSIGN {
            mag := op(i, 0); sign := op(i, 1);
            kmag := compute_known_fp_class(mag, FC_ALL_FLAGS, q, depth + 1);
            kfpc_known_not(*kmag, fc_not(fc_unknown_sign(demanded)));
            s := ic_sdfpc_copysign_mag(mag, demanded, kmag, false);
            if s != NONE return s;
            ksign := compute_known_fp_class(sign, FC_ALL_FLAGS, q, depth + 1);
            if fmf & FMF_NINF kfpc_known_not(*ksign, FC_INF);
            if fmf & FMF_NNAN kfpc_known_not(*ksign, FC_NAN);
            if ksign.sign_bit >= 0 && kmag.sign_bit >= 0 && ksign.sign_bit == kmag.sign_bit return mag;
            known.* = kfpc_copysign(kmag, ksign);
            handled = true;
        } else if id == IID_MAXNUM || id == IID_MINNUM || id == IID_MAXIMUM || id == IID_MINIMUM || id == IID_MAXIMUMNUM || id == IID_MINIMUMNUM {
            kr := compute_known_fp_class(op(i, 1), demanded, q, depth + 1);
            if kfpc_is_unknown(kr) return NONE;
            kl := compute_known_fp_class(op(i, 0), demanded, q, depth + 1);
            return ic_sdfpc_min_max(known, id, i, demanded, kl, kr, false);
        }
    }
    if !handled {
        known.* = compute_known_fp_class(i, demanded, q, depth + 1);
        kfpc_known_not(known, fc_not(demanded));
    }
    return ic_get_fp_class_constant(vtype(i), known.known_fp_classes);
}

// SimplifyDemandedFPClass(I, OpNo, DemandedMask, Known, Q, Depth)
ic_simplify_demanded_fp_class :: (i: Value_Id, k: u32, demanded: u32, known: *Known_FP_Class, q: Simplify_Query, depth: u32) -> bool {
    u := op_use(i, k);
    v := ir.u_val[u];
    vty := vtype(v);
    if demanded == FC_NONE {
        if vkind(v) == .C_POISON return false;
        ic_replace_use(u, const_poison(vty));
        return true;
    }
    if !is_inst(v) {
        known.* = compute_known_fp_class(v, FC_ALL_FLAGS, q, depth);
        kfpc_known_not(known, fc_not(demanded));
        if known.known_fp_classes == FC_NONE {
            if vkind(v) == .C_POISON return false;
            ic_replace_use(u, const_poison(vty));
            return true;
        }
        if is_constant_kind(vkind(v)) return false;
        folded := ic_get_fp_class_constant(vty, known.known_fp_classes);
        if folded == NONE || folded == v return false;
        ic_replace_use(u, folded);
        return true;
    }
    if depth == MAX_ANALYSIS_RECURSION_DEPTH {
        kfpc_known_not(known, fc_not(demanded));
        return false;
    }
    nv: Value_Id;
    if has_one_use(v) nv = ic_simplify_demanded_use_fp_class(v, demanded, known, q, depth);
    else nv = ic_simplify_multiple_use_demanded_fp_class(v, demanded, known, q, depth);
    if nv == NONE return false;
    if is_inst(ir.u_val[u]) salvage_debug_info(ir.u_val[u]);
    ic_replace_use(u, nv);
    return true;
}

// SimplifyDemandedInstructionFPClass(Inst)
ic_simplify_demanded_instruction_fp_class :: (i: Value_Id) -> bool {
    known: Known_FP_Class;
    v := ic_simplify_demanded_use_fp_class(i, FC_ALL_FLAGS, *known, ic_q(i), 0);
    if v == NONE return false;
    if v == i return true;
    ic_replace_inst_uses_with(i, v);
    return true;
}
