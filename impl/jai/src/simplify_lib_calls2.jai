// A port of llvm/lib/Transforms/Utils/SimplifyLibCalls.cpp, second half: math, integer and formatting/IO library
// call optimizations, LibCallSimplifier::optimizeCall and FortifiedLibCallSimplifier (see simplify_lib_calls.jai).

lcs_libm :: #system_library "libm";
lcs_c_log2 :: (x: float64) -> float64 #foreign lcs_libm "log2";
lcs_c_log2f :: (x: float32) -> float32 #foreign lcs_libm "log2f";
NUMBERS_E :: 2.7182818284590452354;

// IRBuilder::CreateIntrinsic(ID, OverloadTypes, Args, FMFSource, Name): folds through TargetFolder::FoldIntrinsic
// (ConstantFoldIntrinsic) when every argument is a constant
lcs_intrinsic :: (id: Intrinsic_Id, otys: [] Type_Id, args: [] Value_Id, fmf: u32, name: string = "") -> Value_Id {
    all_const := true;
    for args if !is_const(it) { all_const = false; break; }
    if all_const {
        rt := func_ret(intrinsic_type(id, otys));
        x := cfo_intrinsic(id, args, rt);
        if x != NONE return x;
    }
    return icb_intrinsic_fmf(id, otys, args, fmf, name);
}
// CreateUnaryIntrinsic(ID, V, FMFSource, Name) / CreateBinaryIntrinsic: unlike CreateIntrinsic these insert the
// declaration before trying to fold (a folded call still leaves the declaration in the module)
lcs_unary_intrinsic :: (id: Intrinsic_Id, v: Value_Id, fmf: u32, name: string = "") -> Value_Id {
    get_or_insert_intrinsic_declaration(id, .[vtype(v)]);
    return lcs_intrinsic(id, .[vtype(v)], .[v], fmf, name);
}
lcs_binary_intrinsic :: (id: Intrinsic_Id, l: Value_Id, r: Value_Id, fmf: u32, name: string = "") -> Value_Id {
    get_or_insert_intrinsic_declaration(id, .[vtype(l)]);
    return lcs_intrinsic(id, .[vtype(l)], .[l, r], fmf, name);
}

// APFloat::isInteger: finite and equal to itself rounded toward zero
apf_is_integer :: (f: APFloat) -> bool {
    g := f;
    if g.k == .PPC_FP128 return dd_is_integer(apf_words(*g));
    if !apf_is_finite(g) return false;
    r, st := fp_round_to_integral(g.k, apf_words(*g), RM_TOWARD_ZERO);
    w := apf_words(*g);
    for w if r[it_index] != it return false;
    return true;
}
// APFloat::isExactlyValue(double)
apf_is_exactly_value :: (f: APFloat, x: float64) -> bool {
    g := f;
    w := fp_from_f64(g.k, x);
    back := fp_to_f64(g.k, w);
    if back != x return false;   // not representable in the semantics
    for apf_words(*g) if w[it_index] != it return false;
    return true;
}

// replaceUnaryCall / replaceBinaryCall
lcs_replace_unary_call :: (ci: Value_Id, id: Intrinsic_Id) -> Value_Id {
    nc := lcs_unary_intrinsic(id, call_arg(ci, 0), get_fmf(ci));
    lcs_take_name(nc, ci);
    return lcs_copy_flags(ci, nc);
}
lcs_replace_binary_call :: (ci: Value_Id, id: Intrinsic_Id) -> Value_Id {
    nc := lcs_binary_intrinsic(id, call_arg(ci, 0), call_arg(ci, 1), get_fmf(ci));
    lcs_take_name(nc, ci);
    return lcs_copy_flags(ci, nc);
}

// valueHasFloatPrecision
value_has_float_precision :: (v: Value_Id) -> Value_Id {
    if is_inst(v) && inst_op(v) == .FPEXT {
        o := op(v, 0);
        if type_kind(vtype(o)) == .FLOAT return o;
    }
    if vkind(v) == .C_FP {
        k := type_kind(scalar_type(vtype(v)));
        w, exact := fp_convert(k, .FLOAT, const_fp_value(v));
        if exact return const_fp_words(type_simple(.FLOAT), w);
    }
    return NONE;
}

// optimizeDoubleFP(CI, B, isBinary, TLI, isPrecise)
optimize_double_fp :: (ci: Value_Id, is_binary: bool, is_precise := false) -> Value_Id {
    callee := call_called_function(ci);
    if type_kind(vtype(ci)) != .DOUBLE || callee == NONE return NONE;
    if is_precise {
        u := ir.v_first_use[ci];
        while u != NONE {
            usr := ir.u_user[u];
            u = ir.u_next[u];
            if !(is_inst(usr) && inst_op(usr) == .FPTRUNC && type_kind(vtype(usr)) == .FLOAT) return NONE;
        }
    }
    v0 := value_has_float_precision(call_arg(ci, 0));
    v1: Value_Id = ifx is_binary then value_has_float_precision(call_arg(ci, 1)) else NONE;
    if v0 == NONE || (is_binary && v1 == NONE) return NONE;
    callee_name := vname(callee);
    is_intrinsic := glob(callee).intrinsic;
    if !is_intrinsic {
        caller_name := vname(inst_fn(ci));
        if ends_with(caller_name, "f") && caller_name.count == callee_name.count + 1 && begins_with(caller_name, callee_name) return NONE;
    }
    saved := ic.b_fmf; defer ic.b_fmf = saved;
    ic.b_fmf = get_fmf(ci);
    r: Value_Id;
    if is_intrinsic {
        id := fn_iid(callee);
        if is_binary r = lcs_intrinsic(id, .[type_simple(.FLOAT)], .[v0, v1], ic.b_fmf);
        else r = lcs_intrinsic(id, .[type_simple(.FLOAT)], .[v0], ic.b_fmf);
    } else {
        attrs := inst(ci).attrs;
        if is_binary r = emit_binary_float_fn_call_name(v0, v1, lcs.tli, callee_name, attrs);
        else r = emit_unary_float_fn_call_name(v0, lcs.tli, callee_name, attrs);
    }
    return icb_cast(.FPEXT, r, type_simple(.DOUBLE));
}
optimize_unary_double_fp :: (ci: Value_Id, is_precise := false) -> Value_Id { return optimize_double_fp(ci, false, is_precise); }
optimize_binary_double_fp :: (ci: Value_Id, is_precise := false) -> Value_Id { return optimize_double_fp(ci, true, is_precise); }

// optimizeCAbs
lcs_optimize_c_abs :: (ci: Value_Id) -> Value_Id {
    real, imag: Value_Id;
    if call_arg_count(ci) == 1 {
        if !lcs_is_fast(ci) return NONE;
        o := call_arg(ci, 0);
        real = icb_extract_value(o, .[0], "real");
        imag = icb_extract_value(o, .[1], "imag");
    } else {
        real = call_arg(ci, 0);
        imag = call_arg(ci, 1);
        abs_op: Value_Id = NONE;
        if vkind(real) == .C_FP { if apf_is_zero(apf_from_const(real)) abs_op = imag; }
        else if vkind(imag) == .C_FP { if apf_is_zero(apf_from_const(imag)) abs_op = real; }
        if abs_op != NONE return lcs_copy_flags(ci, lcs_unary_intrinsic(IID_FABS, abs_op, get_fmf(ci), "cabs"));
        if !lcs_is_fast(ci) return NONE;
    }
    rr := icb_fmul_fmf(real, real, ci);
    ii := icb_fmul_fmf(imag, imag, ci);
    return lcs_copy_flags(ci, lcs_unary_intrinsic(IID_SQRT, icb_fadd_fmf(rr, ii, ci), get_fmf(ci), "cabs"));
}

// getIntToFPVal(I2F, B, DstWidth)
get_int_to_fp_val :: (i2f: Value_Id, dst_width: u32) -> Value_Id {
    if is_inst(i2f) && (inst_op(i2f) == .SITOFP || inst_op(i2f) == .UITOFP) {
        o := op(i2f, 0);
        bw := type_bits(scalar_type(vtype(o)));
        is_s := inst_op(i2f) == .SITOFP;
        if bw < dst_width || (bw == dst_width && is_s) {
            int_ty := type_with_new_bit_width(vtype(o), dst_width);
            return ifx is_s then icb_sext(o, int_ty) else icb_zext(o, int_ty);
        }
    }
    return NONE;
}
lcs_is_itofp :: (v: Value_Id) -> bool { return is_inst(v) && (inst_op(v) == .SITOFP || inst_op(v) == .UITOFP); }

// replacePowWithExp
lcs_replace_pow_with_exp :: (pow: Value_Id) -> Value_Id {
    base := call_arg(pow, 0); expo := call_arg(pow, 1);
    ty := vtype(pow);
    t := lcs.tli;
    base_fn: Value_Id = ifx is_inst(base) && inst_op(base) == .CALL then base else NONE;
    if base_fn != NONE && has_one_use(base_fn) && lcs_is_fast(base_fn) && lcs_is_fast(pow) {
        callee := call_called_function(base_fn);
        if callee != NONE {
            okl, lib_fn := tli_lookup_name(vname(callee));
            if okl && is_lib_func_emittable(t, lib_fn) {
                exp_name: string; id: Intrinsic_Id;
                lf_f, lf_d, lf_l: Lib_Func;
                if lib_fn == {
                    case .expf; #through; case .exp; #through; case .expl;
                        exp_name = tli_func_name(t, .exp); id = IID_EXP; lf_f = .expf; lf_d = .exp; lf_l = .expl;
                    case .exp2f; #through; case .exp2; #through; case .exp2l;
                        exp_name = tli_func_name(t, .exp2); id = IID_EXP2; lf_f = .exp2f; lf_d = .exp2; lf_l = .exp2l;
                    case; return NONE;
                }
                fmul := icb_binop(.FMUL, call_arg(base_fn, 0), expo, "mul");
                exp_fn: Value_Id;
                if lcs_does_not_access_memory(base_fn) exp_fn = lcs_unary_intrinsic(id, fmul, ic.b_fmf, exp_name);
                else exp_fn = emit_unary_float_fn_call(fmul, t, lf_d, lf_f, lf_l, inst(base_fn).attrs);
                lcs_substitute_in_parent(base_fn, exp_fn);
                return exp_fn;
            }
        }
    }
    okb, base_f := pm_apfloat(base);
    if !okb return NONE;
    use_intrinsic := lcs_does_not_access_memory(pow);
    // pow(2.0, itofp(x)) -> ldexp(1.0, x)
    if (use_intrinsic || !is_vector_type(ty)) && apf_is_exactly_value(base_f, 2.0) && lcs_is_itofp(expo) &&
       (use_intrinsic || has_float_fn(t, ty, .ldexp, .ldexpf, .ldexpl)) {
        expo_i := get_int_to_fp_val(expo, tli_int_bits());
        if expo_i != NONE {
            one := lcs_const_fp_f64(ty, 1.0);
            if use_intrinsic return lcs_copy_flags(pow, lcs_intrinsic(IID_LDEXP, .[ty, vtype(expo_i)], .[one, expo_i], get_fmf(pow), "exp2"));
            return lcs_copy_flags(pow, emit_binary_float_fn_call(one, expo_i, t, .ldexp, .ldexpf, .ldexpl, 0));
        }
    }
    // pow(2.0 ** n, x) -> exp2(n * x)
    if has_float_fn(t, ty, .exp2, .exp2f, .exp2l) {
        k := base_f.k;
        one_w := fp_from_f64(.DOUBLE, 1.0);
        br_w, _x := fp_convert(.DOUBLE, k, one_w);
        bf := base_f;
        br_div, _st := fp_div(k, br_w, apf_words(*bf));
        base_r := apf_make(k, br_div);
        is_integer := apf_is_integer(base_f);
        is_reciprocal := apf_is_integer(base_r);
        nf := ifx is_reciprocal then base_r else base_f;
        if is_integer || is_reciprocal {
            nfc := nf;
            ni, st, exact := fp_to_integer_rm(k, apf_words(*nfc), 64, false, RM_TOWARD_ZERO);
            v := ni[0];
            if st == 0 && v > 1 && (v & (v - 1)) == 0 {
                lb := 0; x := v; while x > 1 { lb += 1; x >>= 1; }
                n := cast(float64) lb * (ifx is_reciprocal then -1.0 else 1.0);
                fmul := icb_binop(.FMUL, expo, lcs_const_fp_f64(ty, n), "mul");
                if lcs_does_not_access_memory(pow) return lcs_copy_flags(pow, lcs_unary_intrinsic(IID_EXP2, fmul, ic.b_fmf, "exp2"));
                return lcs_copy_flags(pow, emit_unary_float_fn_call(fmul, t, .exp2, .exp2f, .exp2l, 0));
            }
        }
    }
    // pow(10.0, x) -> exp10(x)
    if apf_is_exactly_value(base_f, 10.0) && has_float_fn(t, ty, .exp10, .exp10f, .exp10l) {
        if lcs_does_not_access_memory(pow) {
            r := lcs_intrinsic(IID_EXP10, .[ty], .[expo], get_fmf(pow), "exp10");
            if is_inst(r) copy_ir_flags(r, pow);
            return r;
        }
        return lcs_copy_flags(pow, emit_unary_float_fn_call(expo, t, .exp10, .exp10f, .exp10l, 0));
    }
    // pow(x, y) -> exp2(log2(x) * y)
    if lcs_has_approx_func(pow) && lcs_has_no_nans(pow) && apf_is_finite_non_zero(base_f) && !apf_is_negative(base_f) {
        log: Value_Id = NONE;
        sk := type_kind(scalar_type(ty));
        bf := base_f;
        if sk == .FLOAT {
            w := apf_words(*bf);
            fx := (cast(*float32) *w[0]).*;
            log = lcs_const_fp_f64(ty, cast(float64) lcs_c_log2f(fx));
        } else if sk == .DOUBLE {
            log = lcs_const_fp_f64(ty, lcs_c_log2(fp_to_f64(.DOUBLE, apf_words(*bf))));
        }
        if log != NONE {
            fmul := icb_binop(.FMUL, log, expo, "mul");
            if lcs_does_not_access_memory(pow) return lcs_copy_flags(pow, lcs_unary_intrinsic(IID_EXP2, fmul, ic.b_fmf, "exp2"));
            else if has_float_fn(t, ty, .exp2, .exp2f, .exp2l)
                return lcs_copy_flags(pow, emit_unary_float_fn_call(fmul, t, .exp2, .exp2f, .exp2l, 0));
        }
    }
    return NONE;
}

// getSqrtCall(V, Attrs, NoErrno, M, B, TLI)
get_sqrt_call :: (v: Value_Id, attrs: u32, no_errno: bool) -> Value_Id {
    if no_errno return lcs_unary_intrinsic(IID_SQRT, v, ic.b_fmf, "sqrt");
    if has_float_fn(lcs.tli, vtype(v), .sqrt, .sqrtf, .sqrtl)
        return emit_unary_float_fn_call(v, lcs.tli, .sqrt, .sqrtf, .sqrtl, attrs);
    return NONE;
}

// replacePowWithSqrt
lcs_replace_pow_with_sqrt :: (pow: Value_Id) -> Value_Id {
    base := call_arg(pow, 0); expo := call_arg(pow, 1);
    ty := vtype(pow);
    oke, expo_f := pm_apfloat(expo);
    if !oke || (!apf_is_exactly_value(expo_f, 0.5) && !apf_is_exactly_value(expo_f, -0.5)) return NONE;
    if apf_is_negative(expo_f) && (!lcs_has_approx_func(pow) && !lcs_has_allow_reassoc(pow)) return NONE;
    if !lcs_does_not_access_memory(pow) && !lcs_has_no_infs(pow) && !ic_is_known_never_infinity(base, lcs_sq_full_dc(pow)) return NONE;
    sqrt := get_sqrt_call(base, 0, lcs_does_not_access_memory(pow));
    if sqrt == NONE return NONE;
    if !lcs_has_no_signed_zeros(pow) sqrt = lcs_unary_intrinsic(IID_FABS, sqrt, ic.b_fmf, "abs");
    sqrt = lcs_copy_flags(pow, sqrt);
    if !lcs_has_no_infs(pow) {
        sk := type_kind(scalar_type(ty));
        pos_inf := ic_const_fp(ty, apf_make(sk, fp_inf(sk, false)));
        neg_inf := ic_const_fp(ty, apf_make(sk, fp_inf(sk, true)));
        fcmp := icb_cmp(FCMP_OEQ, base, neg_inf, "isinf");
        sqrt = icb_select(fcmp, pos_inf, sqrt);
    }
    if apf_is_negative(expo_f) sqrt = icb_binop(.FDIV, lcs_const_fp_f64(ty, 1.0), sqrt, "reciprocal");
    return sqrt;
}

// createPowWithIntegerExponent
create_pow_with_integer_exponent :: (base: Value_Id, expo: Value_Id) -> Value_Id {
    return lcs_intrinsic(IID_POWI, .[vtype(base), vtype(expo)], .[base, expo], ic.b_fmf);
}

// optimizePow
lcs_optimize_pow :: (pow: Value_Id) -> Value_Id {
    base := call_arg(pow, 0); expo := call_arg(pow, 1);
    callee := call_called_function(pow);
    name := vname(callee);
    ty := vtype(pow);
    allow_approx := lcs_has_approx_func(pow);
    saved := ic.b_fmf; defer ic.b_fmf = saved;
    ic.b_fmf = get_fmf(pow);
    if pm_fp_one(base) return base;
    e := lcs_replace_pow_with_exp(pow);
    if e != NONE return e;
    if pm_specific_fp(expo, -1.0) return icb_binop(.FDIV, lcs_const_fp_f64(ty, 1.0), base, "reciprocal");
    if pm_any_zero_fp(expo) return lcs_const_fp_f64(ty, 1.0);
    if pm_fp_one(expo) return base;
    if pm_specific_fp(expo, 2.0) && lcs_does_not_access_memory(pow) return icb_binop(.FMUL, base, base, "square");
    s := lcs_replace_pow_with_sqrt(pow);
    if s != NONE return s;
    oke, expo_f := pm_apfloat(expo);
    if allow_approx && oke && !apf_is_exactly_value(expo_f, 0.5) && !apf_is_exactly_value(expo_f, -0.5) {
        k := expo_f.k;
        ef := expo_f;
        expo_a := apf_make(k, fp_with_sign(k, apf_words(*ef), false));
        expo_i := expo_f;
        sqrt: Value_Id = NONE;
        if !apf_is_integer(expo_a) {
            ea := expo_a;
            e2w, st := fp_add_sub(k, apf_words(*ea), apf_words(*ea), false, RM_NEAREST_TIES_TO_EVEN);
            if st != 0 return NONE;
            if !apf_is_integer(apf_make(k, e2w)) return NONE;
            ei := expo_i;
            riw, rst := fp_round_to_integral(k, apf_words(*ei), RM_TOWARD_NEGATIVE);
            if rst != .INEXACT return NONE;
            expo_i = apf_make(k, riw);
            if !apf_is_integer(expo_i) return NONE;
            sqrt = get_sqrt_call(base, 0, lcs_does_not_access_memory(pow));
            if sqrt == NONE return NONE;
        }
        ib := tli_int_bits();
        if apf_is_integer(expo_i) {
            ei := expo_i;
            iw, st, exact := fp_to_integer_rm(k, apf_words(*ei), ib, true, RM_TOWARD_ZERO);
            if st == 0 {
                powi := lcs_copy_flags(pow, create_pow_with_integer_exponent(base, const_int_words(type_int(ib), iw)));
                if powi != NONE && sqrt != NONE return icb_binop(.FMUL, powi, sqrt);
                return powi;
            }
        }
    }
    if allow_approx && lcs_is_itofp(expo) {
        expo_i := get_int_to_fp_val(expo, tli_int_bits());
        if expo_i != NONE return lcs_copy_flags(pow, create_pow_with_integer_exponent(base, expo_i));
    }
    if lcs.unsafe_fp_shrink && name == tli_func_name(lcs.tli, .pow) && lcs_has_float_version(name) {
        shrunk := optimize_binary_double_fp(pow, true);
        if shrunk != NONE return shrunk;
    }
    return NONE;
}
// optimizeExp2
lcs_optimize_exp2 :: (ci: Value_Id) -> Value_Id {
    callee := call_called_function(ci);
    name := vname(callee);
    ret: Value_Id = NONE;
    t := lcs.tli;
    if lcs.unsafe_fp_shrink && name == tli_func_name(t, .exp2) && lcs_has_float_version(name)
        ret = optimize_unary_double_fp(ci, true);
    use_intrinsic := glob(callee).intrinsic;
    ty := vtype(ci);
    if !use_intrinsic && is_vector_type(ty) return ret;
    o := call_arg(ci, 0);
    if lcs_is_itofp(o) && (use_intrinsic || has_float_fn(t, ty, .ldexp, .ldexpf, .ldexpl)) {
        e := get_int_to_fp_val(o, tli_int_bits());
        if e != NONE {
            one := lcs_const_fp_f64(ty, 1.0);
            if use_intrinsic return lcs_copy_flags(ci, lcs_intrinsic(IID_LDEXP, .[ty, vtype(e)], .[one, e], get_fmf(ci)));
            saved := ic.b_fmf; defer ic.b_fmf = saved;
            ic.b_fmf = get_fmf(ci);
            return lcs_copy_flags(ci, emit_binary_float_fn_call(one, e, t, .ldexp, .ldexpf, .ldexpl, 0));
        }
    }
    return ret;
}

// optimizeFMinFMax
lcs_optimize_f_min_f_max :: (ci: Value_Id, id: Intrinsic_Id) -> Value_Id {
    fmf := get_fmf(ci) | FMF_NSZ;
    return lcs_copy_flags(ci, lcs_binary_intrinsic(id, call_arg(ci, 0), call_arg(ci, 1), fmf));
}

// optimizeLog
lcs_optimize_log :: (log: Value_Id) -> Value_Id {
    log_fn := call_called_function(log);
    log_nm := vname(log_fn);
    log_id := fn_iid(log_fn);
    ty := vtype(log);
    t := lcs.tli;
    if lcs.unsafe_fp_shrink && lcs_has_float_version(log_nm) {
        r := optimize_unary_double_fp(log, true);
        if r != NONE return r;
    }
    exp_lb, exp2_lb, exp10_lb, pow_lb: Lib_Func = .NotLibFunc;
    okl, log_lb := tli_lookup_name(log_nm);
    if okl {
        if log_lb == {
            case .logf; log_id = IID_LOG; exp_lb = .expf; exp2_lb = .exp2f; exp10_lb = .exp10f; pow_lb = .powf;
            case .log; log_id = IID_LOG; exp_lb = .exp; exp2_lb = .exp2; exp10_lb = .exp10; pow_lb = .pow;
            case .logl; log_id = IID_LOG; exp_lb = .expl; exp2_lb = .exp2l; exp10_lb = .exp10l; pow_lb = .powl;
            case .log2f; log_id = IID_LOG2; exp_lb = .expf; exp2_lb = .exp2f; exp10_lb = .exp10f; pow_lb = .powf;
            case .log2; log_id = IID_LOG2; exp_lb = .exp; exp2_lb = .exp2; exp10_lb = .exp10; pow_lb = .pow;
            case .log2l; log_id = IID_LOG2; exp_lb = .expl; exp2_lb = .exp2l; exp10_lb = .exp10l; pow_lb = .powl;
            case .log10f; log_id = IID_LOG10; exp_lb = .expf; exp2_lb = .exp2f; exp10_lb = .exp10f; pow_lb = .powf;
            case .log10; log_id = IID_LOG10; exp_lb = .exp; exp2_lb = .exp2; exp10_lb = .exp10; pow_lb = .pow;
            case .log10l; log_id = IID_LOG10; exp_lb = .expl; exp2_lb = .exp2l; exp10_lb = .exp10l; pow_lb = .powl;
            case; return NONE;
        }
        is_known_no_errno := lcs_has_no_nans(log) && lcs_has_no_infs(log);
        if !is_known_no_errno {
            known := compute_known_fp_class(call_arg(log, 0), KFPC_ORDERED_LESS_THAN_ZERO_MASK | FC_SUBNORMAL, lcs_sq_full_dc(log));
            f := inst_fn(log);
            is_known_no_errno = kfpc_cannot_be_ordered_less_than_zero(known) &&
                                kfpc_is_known_never_logical_zero(known, dm_of_fn(f, scalar_type(ty)));
        }
        if is_known_no_errno {
            new_log := lcs_unary_intrinsic(log_id, call_arg(log, 0), get_fmf(log));
            if is_inst(new_log) {
                copy_metadata(new_log, log);
                return lcs_copy_flags(log, new_log);
            }
            return new_log;
        }
    } else if log_id == IID_LOG || log_id == IID_LOG2 || log_id == IID_LOG10 {
        sk := type_kind(scalar_type(ty));
        if sk == .FLOAT { exp_lb = .expf; exp2_lb = .exp2f; exp10_lb = .exp10f; pow_lb = .powf; }
        else if sk == .DOUBLE { exp_lb = .exp; exp2_lb = .exp2; exp10_lb = .exp10; pow_lb = .pow; }
        else return NONE;
    } else return NONE;
    arg := call_arg(log, 0);
    if !lcs_is_fast(log) || !(is_inst(arg) && inst_op(arg) == .CALL) || !lcs_is_fast(arg) || !has_one_use(arg) return NONE;
    saved := ic.b_fmf; defer ic.b_fmf = saved;
    ic.b_fmf = FMF_ALL;
    arg_id := call_iid(arg);
    arg_lb := Lib_Func.NotLibFunc;
    { ok, lf := tli_lookup_call(arg); if ok arg_lb = lf; }
    if arg_lb == pow_lb || arg_id == IID_POW || arg_id == IID_POWI {
        log_x: Value_Id;
        if lcs_does_not_access_memory(log) log_x = lcs_unary_intrinsic(log_id, op(arg, 0), ic.b_fmf, "log");
        else log_x = emit_unary_float_fn_call_name(op(arg, 0), t, log_nm, 0);
        y := call_arg(arg, 1);
        if arg_id == IID_POWI y = icb_cast(.SITOFP, y, ty, "cast");
        mul_y := icb_binop(.FMUL, y, log_x, "mul");
        lcs_substitute_in_parent(arg, mul_y);
        return mul_y;
    }
    if arg_lb == exp_lb || arg_lb == exp2_lb || arg_lb == exp10_lb || arg_id == IID_EXP || arg_id == IID_EXP2 {
        eul: Value_Id;
        if arg_lb == exp_lb || arg_id == IID_EXP eul = lcs_const_fp_f64(vtype(log), NUMBERS_E);
        else if arg_lb == exp2_lb || arg_id == IID_EXP2 eul = lcs_const_fp_f64(vtype(log), 2.0);
        else eul = lcs_const_fp_f64(vtype(log), 10.0);
        log_e: Value_Id;
        if lcs_does_not_access_memory(log) log_e = lcs_unary_intrinsic(log_id, eul, ic.b_fmf, "log");
        else log_e = emit_unary_float_fn_call_name(eul, t, log_nm, 0);
        mul_y := icb_binop(.FMUL, call_arg(arg, 0), log_e, "mul");
        lcs_substitute_in_parent(arg, mul_y);
        return mul_y;
    }
    return NONE;
}

// mergeSqrtToExp
lcs_merge_sqrt_to_exp :: (ci: Value_Id) -> Value_Id {
    if !lcs_has_allow_reassoc(ci) return NONE;
    sqrt_fn := call_called_function(ci);
    arg := call_arg(ci, 0);
    if !(is_inst(arg) && inst_op(arg) == .CALL) || !lcs_has_allow_reassoc(arg) || !has_one_use(arg) return NONE;
    arg_id := call_iid(arg);
    arg_lb := Lib_Func.NotLibFunc;
    { ok, lf := tli_lookup_call(arg); if ok arg_lb = lf; }
    exp_lb, exp2_lb, exp10_lb: Lib_Func;
    oks, sqrt_lb := tli_lookup_name(vname(sqrt_fn));
    if oks {
        if sqrt_lb == {
            case .sqrtf; exp_lb = .expf; exp2_lb = .exp2f; exp10_lb = .exp10f;
            case .sqrt; exp_lb = .exp; exp2_lb = .exp2; exp10_lb = .exp10;
            case .sqrtl; exp_lb = .expl; exp2_lb = .exp2l; exp10_lb = .exp10l;
            case; return NONE;
        }
    } else if fn_iid(sqrt_fn) == IID_SQRT {
        sk := type_kind(scalar_type(vtype(ci)));
        if sk == .FLOAT { exp_lb = .expf; exp2_lb = .exp2f; exp10_lb = .exp10f; }
        else if sk == .DOUBLE { exp_lb = .exp; exp2_lb = .exp2; exp10_lb = .exp10; }
        else return NONE;
    } else return NONE;
    if arg_lb != exp_lb && arg_lb != exp2_lb && arg_lb != exp10_lb && arg_id != IID_EXP && arg_id != IID_EXP2 return NONE;
    saved := ic.b; defer ic.b = saved;
    icb_set_insert_point(arg);
    exp_operand := op(arg, 0);
    fmul := icb_fmul_fmf(exp_operand, lcs_const_fp_f64(vtype(exp_operand), 0.5), ci, "merged.sqrt");
    set_op(arg, 0, fmul);
    return arg;
}

// optimizeSqrt
lcs_optimize_sqrt :: (ci: Value_Id) -> Value_Id {
    callee := call_called_function(ci);
    ret: Value_Id = NONE;
    if is_lib_func_emittable(lcs.tli, .sqrtf) && (vname(callee) == "sqrt" || fn_iid(callee) == IID_SQRT)
        ret = optimize_unary_double_fp(ci, true);
    o := lcs_merge_sqrt_to_exp(ci);
    if o != NONE return o;
    if !lcs_is_fast(ci) return ret;
    i := call_arg(ci, 0);
    if !is_inst(i) || inst_op(i) != .FMUL || !lcs_is_fast(i) return ret;
    op0 := op(i, 0); op1 := op(i, 1);
    repeat_op: Value_Id = NONE; other_op: Value_Id = NONE;
    if op0 == op1 repeat_op = op0;
    else {
        if is_inst(op0) && inst_op(op0) == .FMUL && op(op0, 0) == op(op0, 1) && lcs_is_fast(op0) { repeat_op = op(op0, 0); other_op = op1; }
        else if is_inst(op1) && inst_op(op1) == .FMUL && op(op1, 0) == op(op1, 1) && lcs_is_fast(op1) { repeat_op = op(op1, 0); other_op = op0; }
    }
    if repeat_op == NONE return ret;
    fabs_call := lcs_unary_intrinsic(IID_FABS, repeat_op, get_fmf(i), "fabs");
    if other_op != NONE {
        sqrt_call := lcs_unary_intrinsic(IID_SQRT, other_op, get_fmf(i), "sqrt");
        return lcs_copy_flags(ci, icb_fmul_fmf(fabs_call, sqrt_call, i));
    }
    return lcs_copy_flags(ci, fabs_call);
}

// optimizeFMod
lcs_optimize_f_mod :: (ci: Value_Id) -> Value_Id {
    is_no_errno := lcs_has_no_nans(ci);
    if !is_no_errno {
        sq := lcs_sq_full_dc(ci);
        known0 := compute_known_fp_class(op(ci, 0), FC_INF, sq);
        if kfpc_is_known_never_infinity(known0) {
            known1 := compute_known_fp_class(op(ci, 1), FC_ZERO | FC_SUBNORMAL, sq);
            is_no_errno = kfpc_is_known_never_logical_zero(known1, dm_of_fn(inst_fn(ci), scalar_type(vtype(ci))));
        }
    }
    if is_no_errno return icb_binop_fmf(.FREM, op(ci, 0), op(ci, 1), get_fmf(ci));
    return NONE;
}

// optimizeTrigInversionPairs
lcs_optimize_trig_inversion_pairs :: (ci: Value_Id) -> Value_Id {
    callee := call_called_function(ci);
    ret: Value_Id = NONE;
    name := vname(callee);
    if lcs.unsafe_fp_shrink && (name == "tan" || name == "atanh" || name == "sinh" || name == "cosh" || name == "asinh") &&
       lcs_has_float_version(name)
        ret = optimize_unary_double_fp(ci, true);
    op1 := call_arg(ci, 0);
    if !(is_inst(op1) && inst_op(op1) == .CALL) return ret;
    if !lcs_is_fast(ci) || !lcs_is_fast(op1) return ret;
    f := call_called_function(op1);
    if f != NONE {
        okf, func := tli_lookup_name(vname(f));
        if okf && is_lib_func_emittable(lcs.tli, func) {
            inverse := Lib_Func.NotLibFunc;
            if name == {
                case "tan"; inverse = .atan; case "atanh"; inverse = .tanh; case "sinh"; inverse = .asinh;
                case "cosh"; inverse = .acosh; case "tanf"; inverse = .atanf; case "atanhf"; inverse = .tanhf;
                case "sinhf"; inverse = .asinhf; case "coshf"; inverse = .acoshf; case "tanl"; inverse = .atanl;
                case "atanhl"; inverse = .tanhl; case "sinhl"; inverse = .asinhl; case "coshl"; inverse = .acoshl;
                case "asinh"; inverse = .sinh; case "asinhf"; inverse = .sinhf; case "asinhl"; inverse = .sinhl;
            }
            if func == inverse ret = call_arg(op1, 0);
        }
    }
    return ret;
}

// isTrigLibCall
is_trig_lib_call :: (ci: Value_Id) -> bool { return call_does_not_throw(ci) && lcs_does_not_access_memory(ci); }

// insertSinCosCall
insert_sin_cos_call :: (orig_callee: Value_Id, arg: Value_Id, use_float: bool) -> (bool, Value_Id, Value_Id, Value_Id) {
    arg_ty := vtype(arg);
    res_ty: Type_Id;
    name: string;
    tt := *tli_get_baseline().triple;
    if use_float {
        name = "__sincospif_stret";
        res_ty = ifx tt.arch == .x86_64 then type_vector(2, arg_ty, false) else type_literal_struct(.[arg_ty, arg_ty], false);
    } else {
        name = "__sincospi_stret";
        res_ty = type_literal_struct(.[arg_ty, arg_ty], false);
    }
    if !is_lib_func_emittable_name(lcs.tli, name) return false, NONE, NONE, NONE;
    ok, lf := tli_lookup_name(name);
    callee := get_or_insert_lib_func(lcs.tli, lf, type_func(res_ty, .[arg_ty], false), glob(orig_callee).attrs);
    if is_inst(arg) icb_set_insert_point_after(arg);
    else {
        entry := glob(ic.f).first_block;
        irb_set_before(*ic.b, block_first(entry));
    }
    sin_cos := icb_call_fn(callee, .[arg], "sincospi");
    sin, cos: Value_Id;
    if type_kind(vtype(sin_cos)) == .STRUCT {
        sin = icb_extract_value(sin_cos, .[0], "sinpi");
        cos = icb_extract_value(sin_cos, .[1], "cospi");
    } else {
        sin = icb_extract_element(sin_cos, lcs_i64(0), "sinpi");
        cos = icb_extract_element(sin_cos, lcs_i64(1), "cospi");
    }
    return true, sin, cos, sin_cos;
}

// optimizeSymmetricCall
optimize_symmetric_call :: (ci: Value_Id, is_even: bool) -> Value_Id {
    src := call_arg(ci, 0);
    okn, x := pm_fneg(src);
    if okn && has_one_use(src) {
        nc := icb_call_fn_fmf(call_called_function(ci), .[x], get_fmf(ci));
        c := lcs_copy_flags(ci, nc);
        if is_even return c;
        return icb_fneg(c, "", ci);
    }
    if is_even {
        if call_iid(src) == IID_FABS || call_iid(src) == IID_COPYSIGN {
            nc := icb_call_fn_fmf(call_called_function(ci), .[call_arg(src, 0)], get_fmf(ci));
            return lcs_copy_flags(ci, nc);
        }
    }
    return NONE;
}
// optimizeSymmetric
lcs_optimize_symmetric :: (ci: Value_Id, f: Lib_Func) -> Value_Id {
    if f == {
        case .cos; #through; case .cosf; #through; case .cosl; #through;
        case .cosh; #through; case .coshf; #through; case .coshl;
            return optimize_symmetric_call(ci, true);
        case .sin; #through; case .sinf; #through; case .sinl; #through;
        case .sinh; #through; case .sinhf; #through; case .sinhl; #through;
        case .tan; #through; case .tanf; #through; case .tanl; #through;
        case .tanh; #through; case .tanhf; #through; case .tanhl; #through;
        case .erf; #through; case .erff; #through; case .erfl;
            return optimize_symmetric_call(ci, false);
    }
    return NONE;
}

// optimizeSinCosPi
lcs_optimize_sin_cos_pi :: (ci: Value_Id, is_sin: bool) -> Value_Id {
    if !is_trig_lib_call(ci) return NONE;
    arg := call_arg(ci, 0);
    if is_constant_data(arg) return NONE;
    sin_calls, cos_calls, sincos_calls: [..] Value_Id;
    sin_calls.allocator = temp; cos_calls.allocator = temp; sincos_calls.allocator = temp;
    is_float := type_kind(vtype(arg)) == .FLOAT;
    f := inst_fn(ci);
    u := ir.v_first_use[arg];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        lcs_classify_arg_use(usr, f, is_float, *sin_calls, *cos_calls, *sincos_calls);
    }
    if sin_calls.count == 0 || cos_calls.count == 0 return NONE;
    ok, sin, cos, sin_cos := insert_sin_cos_call(call_called_function(ci), arg, is_float);
    if !ok return NONE;
    for sin_calls lcs_replace_all_uses_with(it, sin);
    for cos_calls lcs_replace_all_uses_with(it, cos);
    for sincos_calls lcs_replace_all_uses_with(it, sin_cos);
    return ifx is_sin then sin else cos;
}
// classifyArgUse
lcs_classify_arg_use :: (v: Value_Id, f: Value_Id, is_float: bool, sin_calls: *[..] Value_Id, cos_calls: *[..] Value_Id, sincos_calls: *[..] Value_Id) {
    if !is_inst(v) || inst_op(v) != .CALL || !has_uses(v) return;
    if inst_fn(v) != f return;
    callee := call_called_function(v);
    if callee == NONE return;
    ok, func := tli_lookup_fn(callee);
    if !ok || !is_lib_func_emittable(lcs.tli, func) || !is_trig_lib_call(v) return;
    if is_float {
        if func == .sinpif array_add(sin_calls, v);
        else if func == .cospif array_add(cos_calls, v);
        else if func == .sincospif_stret array_add(sincos_calls, v);
    } else {
        if func == .sinpi array_add(sin_calls, v);
        else if func == .cospi array_add(cos_calls, v);
        else if func == .sincospi_stret array_add(sincos_calls, v);
    }
}

// optimizeRemquo
lcs_optimize_remquo :: (ci: Value_Id) -> Value_Id {
    okx, x := pm_apfloat(call_arg(ci, 0));
    oky, y := pm_apfloat(call_arg(ci, 1));
    if !okx || !oky return NONE;
    k := x.k;
    xa := x; ya := y;
    quot, st := fp_div(k, apf_words(*xa), apf_words(*ya), RM_NEAREST_TIES_TO_EVEN);
    if st != 0 && st != .INEXACT return NONE;
    rem, rst := fp_remainder(k, apf_words(*xa), apf_words(*ya));
    if rst != 0 return NONE;
    ib := tli_int_bits();
    qi, qst, exact := fp_to_integer_rm(k, quot, ib, true, RM_NEAREST_TIES_TO_EVEN);
    if qst != 0 && qst != .INEXACT return NONE;
    qa := ap_from_words(ib, qi);
    icb_aligned_store(const_int_signed(type_int(ib), ap_sext_value(qa)), call_arg(ci, 2), call_param_align(ci, 2));
    return ic_const_fp(vtype(ci), apf_make(type_kind(scalar_type(vtype(ci))), rem));
}

// optimizeFdim
lcs_optimize_fdim :: (ci: Value_Id) -> Value_Id {
    if !lcs_does_not_access_memory(ci) return NONE;
    if vkind(call_arg(ci, 0)) == .C_POISON return call_arg(ci, 0);
    if vkind(call_arg(ci, 1)) == .C_POISON return call_arg(ci, 1);
    okx, x := pm_apfloat(call_arg(ci, 0));
    oky, y := pm_apfloat(call_arg(ci, 1));
    if !okx || !oky return NONE;
    if apf_cmp(x, y) != .GREATER && !apf_is_nan(x) && !apf_is_nan(y) return const_null_value(vtype(ci));
    xa := x; ya := y;
    diff, st := fp_add_sub(x.k, apf_words(*xa), apf_words(*ya), true, RM_NEAREST_TIES_TO_EVEN);
    return ic_const_fp(vtype(ci), apf_make(x.k, diff));
}

// ---------------------------------------------------------------- Integer Library Call Optimizations

lcs_optimize_ffs :: (ci: Value_Id) -> Value_Id {
    ret_type := vtype(ci);
    o := call_arg(ci, 0);
    arg_type := vtype(o);
    v := lcs_intrinsic(IID_CTTZ, .[arg_type], .[o, const_int(ir.t_i1, 1)], ic.b_fmf, "cttz");
    v = icb_add(v, const_int(vtype(v), 1));
    v = icb_int_cast(v, ret_type, false);
    cond := icb_cmp(ICMP_NE, o, const_null_value(arg_type));
    return icb_select(cond, v, const_int(ret_type, 0));
}
lcs_optimize_fls :: (ci: Value_Id) -> Value_Id {
    o := call_arg(ci, 0);
    arg_type := vtype(o);
    v := lcs_intrinsic(IID_CTLZ, .[arg_type], .[o, const_int(ir.t_i1, 0)], ic.b_fmf, "ctlz");
    v = icb_sub(const_int(vtype(v), type_int_width(arg_type)), v);
    return icb_int_cast(v, vtype(ci), false);
}
lcs_optimize_abs :: (ci: Value_Id) -> Value_Id {
    x := call_arg(ci, 0);
    is_neg := icb_cmp(ICMP_SLT, x, const_null_value(vtype(x)));   // CreateIsNeg (unnamed)
    neg_x := icb_neg(x, "neg", true);
    return icb_select(is_neg, neg_x, x);
}
lcs_optimize_is_digit :: (ci: Value_Id) -> Value_Id {
    o := call_arg(ci, 0);
    at := vtype(o);
    o = icb_sub(o, const_int(at, #char "0"), "isdigittmp");
    o = icb_cmp(ICMP_ULT, o, const_int(at, 10), "isdigit");
    return icb_zext(o, vtype(ci));
}
lcs_optimize_is_ascii :: (ci: Value_Id) -> Value_Id {
    o := call_arg(ci, 0);
    o = icb_cmp(ICMP_ULT, o, const_int(vtype(o), 128), "isascii");
    return icb_zext(o, vtype(ci));
}
lcs_optimize_to_ascii :: (ci: Value_Id) -> Value_Id { return icb_and(call_arg(ci, 0), const_int(vtype(ci), 0x7F)); }
lcs_optimize_atoi :: (ci: Value_Id) -> Value_Id {
    ok, str := get_constant_string_info(call_arg(ci, 0));
    if !ok return NONE;
    return convert_str_to_int(ci, str, NONE, 10, true);
}
lcs_optimize_str_to_int :: (ci: Value_Id, as_signed: bool) -> Value_Id {
    end_ptr := call_arg(ci, 1);
    if lcs_is_null_ptr(end_ptr) {
        a: Attr; a.kind = .Captures; a.ty = NONE; a.ival = 0;
        call_add_param_attr(ci, 0, a);
        end_ptr = NONE;
    } else if !is_known_non_zero(end_ptr, lcs_sq_dl()) return NONE;
    ok, str := get_constant_string_info(call_arg(ci, 0));
    if !ok return NONE;
    b := call_arg(ci, 2);
    if lcs_const_int(b) return convert_str_to_int(ci, str, end_ptr, cast(u64) const_int_sext(b), as_signed);
    return NONE;
}

// ---------------------------------------------------------------- Formatting and IO Library Call Optimizations

// optimizeErrorReporting(CI, B, StreamArg)
lcs_optimize_error_reporting :: (ci: Value_Id, stream_arg: s32 = -1) -> Value_Id {
    callee := call_called_function(ci);
    if !call_has_fn_attr(ci, .Cold) && is_reporting_error(callee, ci, stream_arg) call_add_fn_attr(ci, .Cold);
    return NONE;
}
is_reporting_error :: (callee: Value_Id, ci: Value_Id, stream_arg: s32) -> bool {
    if callee == NONE || !is_declaration(callee) return false;
    if stream_arg < 0 return true;
    if stream_arg >= cast(s32) call_arg_count(ci) return false;
    li := call_arg(ci, cast(u32) stream_arg);
    if !is_inst(li) || inst_op(li) != .LOAD return false;
    gv := op(li, 0);
    if vkind(gv) != .GLOBAL_VAR || !is_declaration(gv) return false;
    return vname(gv) == "stderr";
}

// optimizePrintFString
lcs_optimize_print_f_string :: (ci: Value_Id) -> Value_Id {
    ok, fmt := get_constant_string_info(call_arg(ci, 0));
    if !ok return NONE;
    if fmt.count == 0 return ifx !has_uses(ci) then ci else const_int(vtype(ci), 0);
    if has_uses(ci) return NONE;
    int_ty := vtype(ci);
    if fmt.count == 1 || fmt == "%%" return lcs_copy_flags(ci, emit_put_char(const_int(int_ty, fmt[0]), lcs.tli));
    if fmt == "%s" && call_arg_count(ci) > 1 {
        oks, s := get_constant_string_info(op(ci, 1));
        if !oks return NONE;
        if s.count == 0 return ci;
        if s.count == 1 return lcs_copy_flags(ci, emit_put_char(const_int(int_ty, s[0]), lcs.tli));
        if s[s.count - 1] == #char "\n" {
            if !is_lib_func_emittable(lcs.tli, .puts) return NONE;
            gv := icb_global_string(slice(s, 0, s.count - 1), "str");
            return lcs_copy_flags(ci, emit_put_s(gv, lcs.tli));
        }
        return NONE;
    }
    if fmt[fmt.count - 1] == #char "\n" && str_find_char(fmt, #char "%") == NPOS {
        if !is_lib_func_emittable(lcs.tli, .puts) return NONE;
        gv := icb_global_string(slice(fmt, 0, fmt.count - 1), "str");
        return lcs_copy_flags(ci, emit_put_s(gv, lcs.tli));
    }
    if fmt == "%c" && call_arg_count(ci) > 1 && is_int_type(vtype(call_arg(ci, 1)))
        return lcs_copy_flags(ci, emit_put_char(icb_int_cast(call_arg(ci, 1), int_ty, false), lcs.tli));
    if fmt == "%s\n" && call_arg_count(ci) > 1 && is_ptr_type(vtype(call_arg(ci, 1)))
        return lcs_copy_flags(ci, emit_put_s(call_arg(ci, 1), lcs.tli));
    return NONE;
}

// The iprintf / __small_printf rewrites only apply on XCore, TCE and Emscripten
lcs_clone_with_callee :: (ci: Value_Id, lf: Lib_Func) -> Value_Id {
    fatal("LibCallSimplifier: rewriting a call to '%' (CI->clone() with a new callee) is not supported yet", tli_standard_name(lf));
    return NONE;
}

// optimizePrintF
lcs_optimize_print_f :: (ci: Value_Id) -> Value_Id {
    v := lcs_optimize_print_f_string(ci);
    if v != NONE return v;
    annotate_non_null_no_undef_based_on_access(ci, .[0]);
    if is_lib_func_emittable(lcs.tli, .iprintf) && !call_has_floating_point_argument(ci) return lcs_clone_with_callee(ci, .iprintf);
    if is_lib_func_emittable(lcs.tli, .small_printf) && !call_has_fp128_argument(ci) return lcs_clone_with_callee(ci, .small_printf);
    return NONE;
}

// optimizeSPrintFString
lcs_optimize_s_print_f_string :: (ci: Value_Id) -> Value_Id {
    ok, fmt := get_constant_string_info(call_arg(ci, 1));
    if !ok return NONE;
    dest := call_arg(ci, 0);
    if call_arg_count(ci) == 2 {
        if str_find_char(fmt, #char "%") != NPOS return NONE;
        icb_mem_transfer(IID_MEMCPY, dest, 1, call_arg(ci, 1), 1, tli_as_size_t(cast(u64) fmt.count + 1), false);
        return const_int(vtype(ci), cast(u64) fmt.count);
    }
    if fmt.count != 2 || fmt[0] != #char "%" || call_arg_count(ci) < 3 return NONE;
    if fmt[1] == #char "c" {
        if !is_int_type(vtype(call_arg(ci, 2))) return NONE;
        v := icb_trunc(call_arg(ci, 2), ir.t_i8, "char");
        ptr := dest;
        lcs_store(v, ptr);
        ptr = icb_gep(ir.t_i8, ptr, .[lcs_i32(1)], "nul", F_INBOUNDS);
        lcs_store(lcs_i8(0), ptr);
        return const_int(vtype(ci), 1);
    }
    if fmt[1] == #char "s" {
        a2 := call_arg(ci, 2);
        if !is_ptr_type(vtype(a2)) return NONE;
        if !has_uses(ci) return lcs_copy_flags(ci, emit_str_cpy(dest, a2, lcs.tli));
        src_len := get_string_length(a2);
        if src_len {
            icb_mem_transfer(IID_MEMCPY, dest, 1, a2, 1, tli_as_size_t(src_len), false);
            return const_int(vtype(ci), src_len - 1);
        } else {
            v := emit_stp_cpy(dest, a2, lcs.tli);
            if v != NONE {
                ptr_diff := icb_ptr_diff(v, dest);
                return icb_int_cast(ptr_diff, vtype(ci), false);
            }
        }
        if lcs_should_optimize_for_size(inst(ci).parent) return NONE;
        len := emit_str_len(a2, lcs.tli);
        if len == NONE return NONE;
        inc_len := icb_add(len, const_int(vtype(len), 1), "leninc");
        icb_mem_transfer(IID_MEMCPY, dest, 1, a2, 1, inc_len, false);
        return icb_int_cast(len, vtype(ci), false);
    }
    return NONE;
}
// optimizeSPrintF
lcs_optimize_s_print_f :: (ci: Value_Id) -> Value_Id {
    v := lcs_optimize_s_print_f_string(ci);
    if v != NONE return v;
    annotate_non_null_no_undef_based_on_access(ci, .[0, 1]);
    if is_lib_func_emittable(lcs.tli, .siprintf) && !call_has_floating_point_argument(ci) return lcs_clone_with_callee(ci, .siprintf);
    if is_lib_func_emittable(lcs.tli, .small_sprintf) && !call_has_fp128_argument(ci) return lcs_clone_with_callee(ci, .small_sprintf);
    return NONE;
}

// emitSnPrintfMemCpy
lcs_emit_sn_printf_mem_cpy :: (ci: Value_Id, str_arg: Value_Id, str: string, n: u64) -> Value_Id {
    int_bits := tli_int_bits();
    int_max := max_int_n(int_bits);
    if cast(u64) str.count > int_max return NONE;
    str_len := const_int(vtype(ci), cast(u64) str.count);
    if n == 0 return str_len;
    ncopy: u64;
    if n > cast(u64) str.count ncopy = cast(u64) str.count + 1;
    else ncopy = n - 1;
    dst_arg := call_arg(ci, 0);
    if ncopy && str_arg != NONE
        lcs_copy_flags(ci, icb_mem_transfer(IID_MEMCPY, dst_arg, 1, str_arg, 1, tli_as_size_t(ncopy), false));
    if n > cast(u64) str.count return str_len;
    nul_off := lcs_int_n(int_bits, ncopy);
    dst_end := icb_gep(ir.t_i8, dst_arg, .[nul_off], "endptr", F_INBOUNDS);
    lcs_store(const_int(ir.t_i8, 0), dst_end);
    return str_len;
}
// optimizeSnPrintFString
lcs_optimize_sn_print_f_string :: (ci: Value_Id) -> Value_Id {
    size := call_arg(ci, 1);
    if !lcs_const_int(size) return NONE;
    n := lcs_cint_zext(size);
    if n > max_int_n(tli_int_bits()) return NONE;
    dst_arg := call_arg(ci, 0);
    fmt_arg := call_arg(ci, 2);
    ok, fmt := get_constant_string_info(fmt_arg);
    if !ok return NONE;
    if call_arg_count(ci) == 3 {
        if str_find_char(fmt, #char "%") != NPOS return NONE;
        return lcs_emit_sn_printf_mem_cpy(ci, fmt_arg, fmt, n);
    }
    if fmt.count != 2 || fmt[0] != #char "%" || call_arg_count(ci) != 4 return NONE;
    if fmt[1] == #char "c" {
        if n <= 1 return lcs_emit_sn_printf_mem_cpy(ci, NONE, "*", n);
        if !is_int_type(vtype(call_arg(ci, 3))) return NONE;
        v := icb_trunc(call_arg(ci, 3), ir.t_i8, "char");
        ptr := dst_arg;
        lcs_store(v, ptr);
        ptr = icb_gep(ir.t_i8, ptr, .[lcs_i32(1)], "nul", F_INBOUNDS);
        lcs_store(lcs_i8(0), ptr);
        return const_int(vtype(ci), 1);
    }
    if fmt[1] != #char "s" return NONE;
    str_arg := call_arg(ci, 3);
    oks, str := get_constant_string_info(str_arg);
    if !oks return NONE;
    return lcs_emit_sn_printf_mem_cpy(ci, str_arg, str, n);
}
// optimizeSnPrintF
lcs_optimize_sn_print_f :: (ci: Value_Id) -> Value_Id {
    v := lcs_optimize_sn_print_f_string(ci);
    if v != NONE return v;
    if is_known_non_zero(op(ci, 1), lcs_sq_dl()) annotate_non_null_no_undef_based_on_access(ci, .[0]);
    return NONE;
}

// optimizeFPrintFString
lcs_optimize_f_print_f_string :: (ci: Value_Id) -> Value_Id {
    lcs_optimize_error_reporting(ci, 0);
    ok, fmt := get_constant_string_info(call_arg(ci, 1));
    if !ok return NONE;
    if has_uses(ci) return NONE;
    if call_arg_count(ci) == 2 {
        if str_find_char(fmt, #char "%") != NPOS return NONE;
        return lcs_copy_flags(ci, emit_f_write(call_arg(ci, 1), tli_as_size_t(cast(u64) fmt.count), call_arg(ci, 0), lcs.tli));
    }
    if fmt.count != 2 || fmt[0] != #char "%" || call_arg_count(ci) < 3 return NONE;
    if fmt[1] == #char "c" {
        if !is_int_type(vtype(call_arg(ci, 2))) return NONE;
        int_ty := type_int(tli_int_bits());
        v := icb_int_cast(call_arg(ci, 2), int_ty, true, "chari");
        return lcs_copy_flags(ci, emit_f_put_c(v, call_arg(ci, 0), lcs.tli));
    }
    if fmt[1] == #char "s" {
        if !is_ptr_type(vtype(call_arg(ci, 2))) return NONE;
        return lcs_copy_flags(ci, emit_f_put_s(call_arg(ci, 2), call_arg(ci, 0), lcs.tli));
    }
    return NONE;
}
// optimizeFPrintF
lcs_optimize_f_print_f :: (ci: Value_Id) -> Value_Id {
    v := lcs_optimize_f_print_f_string(ci);
    if v != NONE return v;
    if is_lib_func_emittable(lcs.tli, .fiprintf) && !call_has_floating_point_argument(ci) return lcs_clone_with_callee(ci, .fiprintf);
    if is_lib_func_emittable(lcs.tli, .small_fprintf) && !call_has_fp128_argument(ci) return lcs_clone_with_callee(ci, .small_fprintf);
    return NONE;
}

// optimizeFWrite
lcs_optimize_f_write :: (ci: Value_Id) -> Value_Id {
    lcs_optimize_error_reporting(ci, 3);
    size := call_arg(ci, 1); count := call_arg(ci, 2);
    if lcs_const_int(size) && lcs_const_int(count) {
        bytes := lcs_cint_zext(size) * lcs_cint_zext(count);
        if bytes == 0 return const_int(vtype(ci), 0);
        if bytes == 1 && !has_uses(ci) {
            ch := lcs_load(ir.t_i8, call_arg(ci, 0), "char");
            int_ty := type_int(tli_int_bits());
            c := icb_int_cast(ch, int_ty, true, "chari");
            new_ci := emit_f_put_c(c, call_arg(ci, 3), lcs.tli);
            return ifx new_ci != NONE then const_int(vtype(ci), 1) else NONE;
        }
    }
    return NONE;
}
// optimizeFPuts
lcs_optimize_f_puts :: (ci: Value_Id) -> Value_Id {
    lcs_optimize_error_reporting(ci, 1);
    if lcs_should_optimize_for_size(inst(ci).parent) return NONE;
    if has_uses(ci) return NONE;
    len := get_string_length(call_arg(ci, 0));
    if !len return NONE;
    return lcs_copy_flags(ci, emit_f_write(call_arg(ci, 0), const_int(tli_size_t_type(), len - 1), call_arg(ci, 1), lcs.tli));
}
// optimizePuts
lcs_optimize_puts :: (ci: Value_Id) -> Value_Id {
    annotate_non_null_no_undef_based_on_access(ci, .[0]);
    if has_uses(ci) return NONE;
    ok, str := get_constant_string_info(call_arg(ci, 0));
    if ok && str.count == 0 return lcs_copy_flags(ci, emit_put_char(const_int(vtype(ci), #char "\n"), lcs.tli));
    return NONE;
}
// optimizeExit
lcs_optimize_exit :: (ci: Value_Id) -> Value_Id {
    ok, c := pm_apint(call_arg(ci, 0));
    if !call_has_fn_attr(ci, .Cold) && ok && !ap_is_zero(c) call_add_fn_attr(ci, .Cold);
    return NONE;
}
// optimizeBCopy
lcs_optimize_b_copy :: (ci: Value_Id) -> Value_Id {
    return lcs_copy_flags(ci, icb_mem_transfer(IID_MEMMOVE, call_arg(ci, 1), 1, call_arg(ci, 0), 1, call_arg(ci, 2), false));
}
// hasFloatVersion
lcs_has_float_version :: (name: string) -> bool { return is_lib_func_emittable_name(lcs.tli, tprint("%f", name)); }

// optimizeStringMemoryLibCall
lcs_optimize_string_memory_lib_call :: (ci: Value_Id) -> Value_Id {
    callee := call_called_function(ci);
    ok, f := tli_lookup_fn(callee);
    if !(ok && is_lib_func_emittable(lcs.tli, f)) return NONE;
    if f == {
        case .strcat; return lcs_optimize_str_cat(ci);
        case .strncat; return lcs_optimize_str_n_cat(ci);
        case .strchr; return lcs_optimize_str_chr(ci);
        case .strrchr; return lcs_optimize_str_r_chr(ci);
        case .strcmp; return lcs_optimize_str_cmp(ci);
        case .strncmp; return lcs_optimize_str_n_cmp(ci);
        case .strcpy; return lcs_optimize_str_cpy(ci);
        case .stpcpy; return lcs_optimize_stp_cpy(ci);
        case .strlcpy; return lcs_optimize_str_l_cpy(ci);
        case .stpncpy; return lcs_optimize_string_n_cpy(ci, true);
        case .strncpy; return lcs_optimize_string_n_cpy(ci, false);
        case .strlen; return lcs_optimize_str_len(ci);
        case .strnlen; return lcs_optimize_str_n_len(ci);
        case .strpbrk; return lcs_optimize_str_p_brk(ci);
        case .strndup; return lcs_optimize_str_n_dup(ci);
        case .strtol; #through; case .strtod; #through; case .strtof; #through; case .strtoul; #through;
        case .strtoll; #through; case .strtold; #through; case .strtoull;
            return lcs_optimize_str_to(ci);
        case .strspn; return lcs_optimize_str_spn(ci);
        case .strcspn; return lcs_optimize_str_c_spn(ci);
        case .strstr; return lcs_optimize_str_str(ci);
        case .memchr; return lcs_optimize_mem_chr(ci);
        case .memrchr; return lcs_optimize_mem_r_chr(ci);
        case .bcmp; return lcs_optimize_b_cmp(ci);
        case .memcmp; return lcs_optimize_mem_cmp(ci);
        case .memcpy; return lcs_optimize_mem_cpy(ci);
        case .memccpy; return lcs_optimize_mem_c_cpy(ci);
        case .mempcpy; return lcs_optimize_mem_p_cpy(ci);
        case .memmove; return lcs_optimize_mem_move(ci);
        case .memset; return lcs_optimize_mem_set(ci);
        case .realloc; return lcs_optimize_realloc(ci);
        case .wcslen; return lcs_optimize_wcslen(ci);
        case .bcopy; return lcs_optimize_b_copy(ci);
        case .Znwm; #through; case .ZnwmRKSt9nothrow_t; #through; case .ZnwmSt11align_val_t; #through;
        case .ZnwmSt11align_val_tRKSt9nothrow_t; #through; case .Znam; #through; case .ZnamRKSt9nothrow_t; #through;
        case .ZnamSt11align_val_t; #through; case .ZnamSt11align_val_tRKSt9nothrow_t; #through;
        case .Znwm12__hot_cold_t; #through; case .ZnwmRKSt9nothrow_t12__hot_cold_t; #through;
        case .ZnwmSt11align_val_t12__hot_cold_t; #through; case .ZnwmSt11align_val_tRKSt9nothrow_t12__hot_cold_t; #through;
        case .Znam12__hot_cold_t; #through; case .ZnamRKSt9nothrow_t12__hot_cold_t; #through;
        case .ZnamSt11align_val_t12__hot_cold_t; #through; case .ZnamSt11align_val_tRKSt9nothrow_t12__hot_cold_t; #through;
        case .size_returning_new; #through; case .size_returning_new_hot_cold; #through;
        case .size_returning_new_aligned; #through; case .size_returning_new_aligned_hot_cold;
            return lcs_optimize_new(ci, f);
    }
    return NONE;
}

// optimizeNaN
lcs_optimize_nan :: (ci: Value_Id) -> Value_Id {
    ok, seq := get_constant_string_info(call_arg(ci, 0));
    if !ok return NONE;
    fill: APInt;
    if seq.count == 0 fill = ap_zero(32);
    else {
        okp, f := str_get_as_integer_auto_radix(seq);
        if !okp return NONE;
        fill = f;
    }
    return const_fp_qnan_fill(vtype(ci), fill);
}
// StringRef::getAsInteger(Radix = 0, APInt &Result): auto-detected radix, the whole string must be digits
str_get_as_integer_auto_radix :: (s_in: string) -> (bool, APInt) {
    s := s_in;
    radix: u64 = 10;
    if begins_with(s, "0x") || begins_with(s, "0X") { radix = 16; s = slice(s, 2, s.count - 2); }
    else if begins_with(s, "0b") || begins_with(s, "0B") { radix = 2; s = slice(s, 2, s.count - 2); }
    else if begins_with(s, "0o") { radix = 8; s = slice(s, 2, s.count - 2); }
    else if s.count > 1 && s[0] == #char "0" { radix = 8; s = slice(s, 1, s.count - 1); }
    if s.count == 0 return false, .{};
    // APInt::fromString-like accumulation in a width that grows like StringRef::getAsInteger (bit width of the result
    // = the minimal width that holds the value, at least 1 bit; LLVM picks log2(radix) * digits, then shrinks)
    log2r: u32 = ifx radix == 16 then cast(u32) 4 else ifx radix == 8 then cast(u32) 3 else ifx radix == 2 then cast(u32) 1 else 4;
    bits: u32 = log2r * cast(u32) s.count;
    if bits == 0 bits = 1;
    r := ap_zero(bits);
    rv := ap_from_u64(bits, radix);
    for i: 0..s.count-1 {
        c := s[i];
        d: u64;
        if c >= #char "0" && c <= #char "9" d = cast(u64)(c - #char "0");
        else if c >= #char "a" && c <= #char "z" d = cast(u64)(c - #char "a" + 10);
        else if c >= #char "A" && c <= #char "Z" d = cast(u64)(c - #char "A" + 10);
        else return false, .{};
        if d >= radix return false, .{};
        r = ap_add(ap_mul(r, rv), ap_from_u64(bits, d));
    }
    // getAsInteger trims the width to the active bits (min 1) when it computed it from the digits
    ab := max(ap_active_bits(r), 1);
    return true, ap_trunc(r, ab);
}
// ConstantFP::getQNaN(Ty, Negative = false, Payload)
const_fp_qnan_fill :: (ty: Type_Id, fill: APInt) -> Value_Id {
    k := type_kind(scalar_type(ty));
    w := fp_qnan_with_payload(k, false, fill);
    return ic_const_fp(ty, apf_make(k, w));
}
// APFloat::getQNaN(Sem, Negative, &payload): IEEEFloat::makeNaN(SNaN = false, Negative, fill)
fp_qnan_with_payload :: (k: Type_Kind, neg: bool, fill: APInt) -> [] u64 {
    // DoubleAPFloat::makeNaN: the first double's NaN, second +0
    if k == .PPC_FP128 return dd_make(fp_qnan_with_payload(.DOUBLE, neg, fill)[0], 0);
    if k != .FLOAT && k != .DOUBLE && k != .HALF && k != .BFLOAT && k != .FP128 && k != .X86_FP80
        fatal("LibCallSimplifier: nan() for this floating-point type is not supported yet");
    p, mx, mn, b := fp_semantics(k);
    // significand bits stored (x86_fp80 has an explicit integer bit)
    sig_bits := cast(u32)(p - 1);
    total := cast(u32) b;
    w := NewArray(words_for_bits(total), u64,, allocator = temp);
    // payload: the low (sig_bits - 1) bits of fill (the quiet bit is set separately)
    fw := ap_words(ap_zext_or_trunc(fill, max(fill.bits, 64 * cast(u32) w.count)));
    nfw := min(fw.count, w.count);
    for i: 0..nfw-1 w[i] = fw[i];
    payload_bits := sig_bits - 1;
    for i: 0..w.count-1 {
        lo := cast(u32) i * 64;
        if lo >= payload_bits { w[i] = 0; continue; }
        if payload_bits - lo < 64 w[i] &= ((cast(u64) 1) << (payload_bits - lo)) - 1;
    }
    set_bit :: (w: [] u64, bit: u32) { w[bit / 64] |= (cast(u64) 1) << cast(u64)(bit % 64); }
    set_bit(w, sig_bits - 1);   // quiet bit
    if k == .X86_FP80 set_bit(w, 63);   // explicit integer bit
    // exponent all ones
    exp_lo := ifx k == .X86_FP80 then cast(u32) 64 else sig_bits;
    for i: exp_lo..total-2 set_bit(w, i);
    if neg set_bit(w, total - 1);
    return w;
}

// optimizeFloatingPointLibCall
lcs_optimize_floating_point_lib_call :: (ci: Value_Id, f: Lib_Func) -> Value_Id {
    if call_is_strict_fp(ci) return NONE;
    v := lcs_optimize_symmetric(ci, f);
    if v != NONE return v;
    callee_name := vname(call_called_function(ci));
    if f == {
        case .sinpif; #through; case .sinpi; return lcs_optimize_sin_cos_pi(ci, true);
        case .cospif; #through; case .cospi; return lcs_optimize_sin_cos_pi(ci, false);
        case .powf; #through; case .pow; #through; case .powl; return lcs_optimize_pow(ci);
        case .exp2l; #through; case .exp2; #through; case .exp2f; return lcs_optimize_exp2(ci);
        case .fabsf; #through; case .fabs; #through; case .fabsl; return lcs_replace_unary_call(ci, IID_FABS);
        case .sqrtf; #through; case .sqrt; #through; case .sqrtl; return lcs_optimize_sqrt(ci);
        case .fmod; #through; case .fmodf; #through; case .fmodl; return lcs_optimize_f_mod(ci);
        case .logf; #through; case .log; #through; case .logl; #through; case .log10f; #through; case .log10; #through;
        case .log10l; #through; case .log1pf; #through; case .log1p; #through; case .log1pl; #through;
        case .log2f; #through; case .log2; #through; case .log2l; #through; case .logbf; #through; case .logb; #through;
        case .logbl;
            return lcs_optimize_log(ci);
        case .tan; #through; case .tanf; #through; case .tanl; #through; case .sinh; #through; case .sinhf; #through;
        case .sinhl; #through; case .asinh; #through; case .asinhf; #through; case .asinhl; #through; case .cosh; #through;
        case .coshf; #through; case .coshl; #through; case .atanh; #through; case .atanhf; #through; case .atanhl;
            return lcs_optimize_trig_inversion_pairs(ci);
        case .ceil; return lcs_replace_unary_call(ci, IID_CEIL);
        case .floor; return lcs_replace_unary_call(ci, IID_FLOOR);
        case .round; return lcs_replace_unary_call(ci, IID_ROUND);
        case .roundeven; return lcs_replace_unary_call(ci, IID_ROUNDEVEN);
        case .nearbyint; return lcs_replace_unary_call(ci, IID_NEARBYINT);
        case .rint; return lcs_replace_unary_call(ci, IID_RINT);
        case .trunc; return lcs_replace_unary_call(ci, IID_TRUNC);
        case .acos; #through; case .acosh; #through; case .asin; #through; case .atan; #through; case .cbrt; #through;
        case .exp; #through; case .exp10; #through; case .expm1; #through; case .cos; #through; case .sin; #through;
        case .tanh;
            if lcs.unsafe_fp_shrink && lcs_has_float_version(callee_name) return optimize_unary_double_fp(ci, true);
            return NONE;
        case .copysign;
            if lcs_has_float_version(callee_name) return optimize_binary_double_fp(ci);
            return NONE;
        case .fdim; #through; case .fdimf; #through; case .fdiml; return lcs_optimize_fdim(ci);
        case .fminf; #through; case .fmin; #through; case .fminl; return lcs_optimize_f_min_f_max(ci, IID_MINNUM);
        case .fmaxf; #through; case .fmax; #through; case .fmaxl; return lcs_optimize_f_min_f_max(ci, IID_MAXNUM);
        case .fminimum_numf; #through; case .fminimum_num; #through; case .fminimum_numl; return lcs_replace_binary_call(ci, IID_MINIMUMNUM);
        case .fmaximum_numf; #through; case .fmaximum_num; #through; case .fmaximum_numl; return lcs_replace_binary_call(ci, IID_MAXIMUMNUM);
        case .cabs; #through; case .cabsf; #through; case .cabsl; return lcs_optimize_c_abs(ci);
        case .remquo; #through; case .remquof; #through; case .remquol; return lcs_optimize_remquo(ci);
        case .nan; #through; case .nanf; #through; case .nanl; return lcs_optimize_nan(ci);
    }
    return NONE;
}

// LibCallSimplifier::optimizeCall(CI, Builder)
lcs_optimize_call :: (ci: Value_Id) -> Value_Id {
    assert(call_tail_kind(ci) != TCK_MUSTTAIL, "These transforms aren't musttail safe.");
    saved := lcs; defer lcs = saved;
    lcs.tli = tli_for(ic.f);
    lcs.call = ci;
    lcs.unsafe_fp_shrink = false;
    if call_is_no_builtin(ci) return lcs_maybe_optimize_no_builtin_operator_new(ci);
    callee := call_called_function(ci);
    is_calling_conv_c := tli_is_calling_conv_c_compatible_call(ci);
    // IRBuilderBase::OperandBundlesGuard + setDefaultOperandBundles(CI's bundles): calls created below carry them
    bundles_saved := ic.default_bundles_src; defer ic.default_bundles_src = bundles_saved;
    ic.default_bundles_src = ifx call_num_bundles(ci) > 0 then ci else NONE;
    if lcs_enable_unsafe_fp_shrink_opt > 0 lcs.unsafe_fp_shrink = lcs_enable_unsafe_fp_shrink_opt == 2;
    else if is_fp_math_inst(ci) && lcs_is_fast(ci) lcs.unsafe_fp_shrink = true;
    iid := call_iid(ci);
    if iid != NOT_INTRINSIC {
        if !is_calling_conv_c return NONE;
        if iid == {
            case IID_POW; return lcs_optimize_pow(ci);
            case IID_EXP2; return lcs_optimize_exp2(ci);
            case IID_LOG; #through; case IID_LOG2; #through; case IID_LOG10; return lcs_optimize_log(ci);
            case IID_SQRT; return lcs_optimize_sqrt(ci);
            case IID_MEMSET; return lcs_optimize_mem_set(ci);
            case IID_MEMCPY; return lcs_optimize_mem_cpy(ci);
            case IID_MEMMOVE; return lcs_optimize_mem_move(ci);
            case IID_SIN; #through; case IID_COS;
                if lcs.unsafe_fp_shrink return optimize_unary_double_fp(ci, true);
                return NONE;
        }
        return NONE;
    }
    v := fortified_optimize_call(ci);
    if v != NONE return v;
    ok, f := tli_lookup_fn(callee);
    if ok && is_lib_func_emittable(lcs.tli, f) {
        if !ignore_calling_conv(f) && !is_calling_conv_c return NONE;
        v = lcs_optimize_string_memory_lib_call(ci);
        if v != NONE return v;
        v = lcs_optimize_floating_point_lib_call(ci, f);
        if v != NONE return v;
        if f == {
            case .ffs; #through; case .ffsl; #through; case .ffsll; return lcs_optimize_ffs(ci);
            case .fls; #through; case .flsl; #through; case .flsll; return lcs_optimize_fls(ci);
            case .abs; #through; case .labs; #through; case .llabs; return lcs_optimize_abs(ci);
            case .isdigit; return lcs_optimize_is_digit(ci);
            case .isascii; return lcs_optimize_is_ascii(ci);
            case .toascii; return lcs_optimize_to_ascii(ci);
            case .atoi; #through; case .atol; #through; case .atoll; return lcs_optimize_atoi(ci);
            case .strtol; #through; case .strtoll; return lcs_optimize_str_to_int(ci, true);
            case .strtoul; #through; case .strtoull; return lcs_optimize_str_to_int(ci, false);
            case .printf; return lcs_optimize_print_f(ci);
            case .sprintf; return lcs_optimize_s_print_f(ci);
            case .snprintf; return lcs_optimize_sn_print_f(ci);
            case .fprintf; return lcs_optimize_f_print_f(ci);
            case .fwrite; return lcs_optimize_f_write(ci);
            case .fputs; return lcs_optimize_f_puts(ci);
            case .puts; return lcs_optimize_puts(ci);
            case .perror; return lcs_optimize_error_reporting(ci);
            case .vfprintf; #through; case .fiprintf; return lcs_optimize_error_reporting(ci, 0);
            case .exit; #through; case .Exit; return lcs_optimize_exit(ci);
        }
    }
    return NONE;
}

// ---------------------------------------------------------------- Fortified Library Call Optimizations

FORTIFY_NONE :: 0xFFFF_FFFF;
fortified_only_lower_unknown_size := false;   // FortifiedLibCallSimplifier(TLI, OnlyLowerUnknownSize = false)

// isFortifiedCallFoldable(CI, ObjSizeOp, SizeOp, StrOp, FlagOp)
is_fortified_call_foldable :: (ci: Value_Id, obj_size_op: u32, size_op: u32 = FORTIFY_NONE, str_op: u32 = FORTIFY_NONE, flag_op: u32 = FORTIFY_NONE) -> bool {
    if flag_op != FORTIFY_NONE {
        flag := call_arg(ci, flag_op);
        if !lcs_const_int(flag) || !is_null_value(flag) return false;
    }
    if size_op != FORTIFY_NONE && call_arg(ci, obj_size_op) == call_arg(ci, size_op) return true;
    obj := call_arg(ci, obj_size_op);
    if lcs_const_int(obj) {
        if ap_is_all_ones(const_ap(obj)) return true;
        if fortified_only_lower_unknown_size return false;
        if str_op != FORTIFY_NONE {
            len := get_string_length(call_arg(ci, str_op));
            if len annotate_dereferenceable_bytes(ci, .[str_op], len);
            else return false;
            return lcs_cint_zext(obj) >= len;
        }
        if size_op != FORTIFY_NONE {
            sz := call_arg(ci, size_op);
            if lcs_const_int(sz) return lcs_cint_zext(obj) >= lcs_cint_zext(sz);
        }
    }
    return false;
}

fortified_optimize_mem_cpy_chk :: (ci: Value_Id) -> Value_Id {
    if is_fortified_call_foldable(ci, 3, 2) {
        new_ci := icb_mem_transfer(IID_MEMCPY, call_arg(ci, 0), 1, call_arg(ci, 1), 1, call_arg(ci, 2), false);
        merge_attributes_and_flags(new_ci, ci);
        return call_arg(ci, 0);
    }
    return NONE;
}
fortified_optimize_mem_move_chk :: (ci: Value_Id) -> Value_Id {
    if is_fortified_call_foldable(ci, 3, 2) {
        new_ci := icb_mem_transfer(IID_MEMMOVE, call_arg(ci, 0), 1, call_arg(ci, 1), 1, call_arg(ci, 2), false);
        merge_attributes_and_flags(new_ci, ci);
        return call_arg(ci, 0);
    }
    return NONE;
}
fortified_optimize_mem_set_chk :: (ci: Value_Id) -> Value_Id {
    if is_fortified_call_foldable(ci, 3, 2) {
        val := icb_int_cast(call_arg(ci, 1), ir.t_i8, false);
        new_ci := icb_memset(call_arg(ci, 0), val, call_arg(ci, 2), 1);
        merge_attributes_and_flags(new_ci, ci);
        return call_arg(ci, 0);
    }
    return NONE;
}
fortified_optimize_mem_p_cpy_chk :: (ci: Value_Id) -> Value_Id {
    if is_fortified_call_foldable(ci, 3, 2) {
        c := emit_mem_p_cpy(call_arg(ci, 0), call_arg(ci, 1), call_arg(ci, 2), lcs.tli);
        if c != NONE return merge_attributes_and_flags(c, ci);
    }
    return NONE;
}
fortified_optimize_strp_cpy_chk :: (ci: Value_Id, f: Lib_Func) -> Value_Id {
    dst := call_arg(ci, 0); src := call_arg(ci, 1); obj_size := call_arg(ci, 2);
    if f == .stpcpy_chk && !fortified_only_lower_unknown_size && dst == src {
        sl := emit_str_len(src, lcs.tli);
        return ifx sl != NONE then icb_gep(ir.t_i8, dst, .[sl], "", F_INBOUNDS) else NONE;
    }
    if is_fortified_call_foldable(ci, 2, FORTIFY_NONE, 1) {
        if f == .strcpy_chk return lcs_copy_flags(ci, emit_str_cpy(dst, src, lcs.tli));
        return lcs_copy_flags(ci, emit_stp_cpy(dst, src, lcs.tli));
    }
    if fortified_only_lower_unknown_size return NONE;
    len := get_string_length(src);
    if len annotate_dereferenceable_bytes(ci, .[1], len);
    else return NONE;
    size_t_ty := tli_size_t_type();
    len_v := const_int(size_t_ty, len);
    ret := emit_mem_cpy_chk(dst, src, len_v, obj_size, lcs.tli);
    if ret != NONE && f == .stpcpy_chk return icb_gep(ir.t_i8, dst, .[const_int(size_t_ty, len - 1)], "", F_INBOUNDS);
    return lcs_copy_flags(ci, ret);
}
fortified_optimize_str_len_chk :: (ci: Value_Id) -> Value_Id {
    if is_fortified_call_foldable(ci, 1, FORTIFY_NONE, 0) return lcs_copy_flags(ci, emit_str_len(call_arg(ci, 0), lcs.tli));
    return NONE;
}
fortified_optimize_strp_n_cpy_chk :: (ci: Value_Id, f: Lib_Func) -> Value_Id {
    if is_fortified_call_foldable(ci, 3, 2) {
        if f == .strncpy_chk return lcs_copy_flags(ci, emit_str_n_cpy(call_arg(ci, 0), call_arg(ci, 1), call_arg(ci, 2), lcs.tli));
        return lcs_copy_flags(ci, emit_stp_n_cpy(call_arg(ci, 0), call_arg(ci, 1), call_arg(ci, 2), lcs.tli));
    }
    return NONE;
}
fortified_optimize_mem_c_cpy_chk :: (ci: Value_Id) -> Value_Id {
    if is_fortified_call_foldable(ci, 4, 3)
        return lcs_copy_flags(ci, emit_mem_c_cpy(call_arg(ci, 0), call_arg(ci, 1), call_arg(ci, 2), call_arg(ci, 3), lcs.tli));
    return NONE;
}
lcs_call_args_from :: (ci: Value_Id, first: u32) -> [] Value_Id {
    out: [..] Value_Id; out.allocator = temp;
    n := call_arg_count(ci);
    k := first;
    while k < n { array_add(*out, call_arg(ci, k)); k += 1; }
    return out;
}
fortified_optimize_sn_printf_chk :: (ci: Value_Id) -> Value_Id {
    if is_fortified_call_foldable(ci, 3, 1, FORTIFY_NONE, 2)
        return lcs_copy_flags(ci, emit_sn_printf(call_arg(ci, 0), call_arg(ci, 1), call_arg(ci, 4), lcs_call_args_from(ci, 5), lcs.tli));
    return NONE;
}
fortified_optimize_s_printf_chk :: (ci: Value_Id) -> Value_Id {
    if is_fortified_call_foldable(ci, 2, FORTIFY_NONE, FORTIFY_NONE, 1)
        return lcs_copy_flags(ci, emit_s_printf(call_arg(ci, 0), call_arg(ci, 3), lcs_call_args_from(ci, 4), lcs.tli));
    return NONE;
}
fortified_optimize_str_cat_chk :: (ci: Value_Id) -> Value_Id {
    if is_fortified_call_foldable(ci, 2) return lcs_copy_flags(ci, emit_str_cat(call_arg(ci, 0), call_arg(ci, 1), lcs.tli));
    return NONE;
}
fortified_optimize_str_l_cat :: (ci: Value_Id) -> Value_Id {
    if is_fortified_call_foldable(ci, 3) return lcs_copy_flags(ci, emit_str_l_cat(call_arg(ci, 0), call_arg(ci, 1), call_arg(ci, 2), lcs.tli));
    return NONE;
}
fortified_optimize_str_n_cat_chk :: (ci: Value_Id) -> Value_Id {
    if is_fortified_call_foldable(ci, 3) return lcs_copy_flags(ci, emit_str_n_cat(call_arg(ci, 0), call_arg(ci, 1), call_arg(ci, 2), lcs.tli));
    return NONE;
}
fortified_optimize_str_l_cpy_chk :: (ci: Value_Id) -> Value_Id {
    if is_fortified_call_foldable(ci, 3) return lcs_copy_flags(ci, emit_str_l_cpy(call_arg(ci, 0), call_arg(ci, 1), call_arg(ci, 2), lcs.tli));
    return NONE;
}
fortified_optimize_vsn_printf_chk :: (ci: Value_Id) -> Value_Id {
    if is_fortified_call_foldable(ci, 3, 1, FORTIFY_NONE, 2)
        return lcs_copy_flags(ci, emit_vsn_printf(call_arg(ci, 0), call_arg(ci, 1), call_arg(ci, 4), call_arg(ci, 5), lcs.tli));
    return NONE;
}
fortified_optimize_vs_printf_chk :: (ci: Value_Id) -> Value_Id {
    if is_fortified_call_foldable(ci, 2, FORTIFY_NONE, FORTIFY_NONE, 1)
        return lcs_copy_flags(ci, emit_vs_printf(call_arg(ci, 0), call_arg(ci, 3), call_arg(ci, 4), lcs.tli));
    return NONE;
}

// FortifiedLibCallSimplifier::optimizeCall (disregards nobuiltin and TLI::has, like LLVM: PR23093)
fortified_optimize_call :: (ci: Value_Id) -> Value_Id {
    callee := call_called_function(ci);
    is_calling_conv_c := tli_is_calling_conv_c_compatible_call(ci);
    ok, f := tli_lookup_fn(callee);
    if !ok return NONE;
    if !ignore_calling_conv(f) && !is_calling_conv_c return NONE;
    if f == {
        case .memcpy_chk; return fortified_optimize_mem_cpy_chk(ci);
        case .mempcpy_chk; return fortified_optimize_mem_p_cpy_chk(ci);
        case .memmove_chk; return fortified_optimize_mem_move_chk(ci);
        case .memset_chk; return fortified_optimize_mem_set_chk(ci);
        case .stpcpy_chk; #through; case .strcpy_chk; return fortified_optimize_strp_cpy_chk(ci, f);
        case .strlen_chk; return fortified_optimize_str_len_chk(ci);
        case .stpncpy_chk; #through; case .strncpy_chk; return fortified_optimize_strp_n_cpy_chk(ci, f);
        case .memccpy_chk; return fortified_optimize_mem_c_cpy_chk(ci);
        case .snprintf_chk; return fortified_optimize_sn_printf_chk(ci);
        case .sprintf_chk; return fortified_optimize_s_printf_chk(ci);
        case .strcat_chk; return fortified_optimize_str_cat_chk(ci);
        case .strlcat_chk; return fortified_optimize_str_l_cat(ci);
        case .strncat_chk; return fortified_optimize_str_n_cat_chk(ci);
        case .strlcpy_chk; return fortified_optimize_str_l_cpy_chk(ci);
        case .vsnprintf_chk; return fortified_optimize_vsn_printf_chk(ci);
        case .vsprintf_chk; return fortified_optimize_vs_printf_chk(ci);
    }
    return NONE;
}
