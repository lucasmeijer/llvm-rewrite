// Constant folding of calls: canConstantFoldCallTo / ConstantFoldCall and everything below them
// (ConstantFoldScalarCall1/2/3, ConstantFoldLibCall2, ConstantFoldIntrinsicCall2, ConstantFoldFixedVectorCall,
// ConstantFoldScalableVectorCall, ConstantFoldStructCall), ported from llvm/lib/Analysis/ConstantFolding.cpp,
// plus the slice of TargetLibraryInfo (llvm/lib/Analysis/TargetLibraryInfo.cpp, TargetLibraryInfo.td) those
// functions consult: the libm names, their prototypes and availability for the module triple.
// Target intrinsics of other targets (AMDGPU, NVPTX, wasm, ARM, AArch64) never get here: canConstantFoldCallTo
// does not accept them. Math library functions are evaluated with the host libm, exactly like LLVM does.

cfc_libm :: #system_library "libm";
cfc_log   :: (x: float64) -> float64 #foreign cfc_libm "log";
cfc_log2  :: (x: float64) -> float64 #foreign cfc_libm "log2";
cfc_log10 :: (x: float64) -> float64 #foreign cfc_libm "log10";
cfc_exp   :: (x: float64) -> float64 #foreign cfc_libm "exp";
cfc_sin   :: (x: float64) -> float64 #foreign cfc_libm "sin";
cfc_cos   :: (x: float64) -> float64 #foreign cfc_libm "cos";
cfc_tan   :: (x: float64) -> float64 #foreign cfc_libm "tan";
cfc_sinh  :: (x: float64) -> float64 #foreign cfc_libm "sinh";
cfc_cosh  :: (x: float64) -> float64 #foreign cfc_libm "cosh";
cfc_tanh  :: (x: float64) -> float64 #foreign cfc_libm "tanh";
cfc_asin  :: (x: float64) -> float64 #foreign cfc_libm "asin";
cfc_acos  :: (x: float64) -> float64 #foreign cfc_libm "acos";
cfc_atan  :: (x: float64) -> float64 #foreign cfc_libm "atan";
cfc_sqrt  :: (x: float64) -> float64 #foreign cfc_libm "sqrt";
cfc_erf   :: (x: float64) -> float64 #foreign cfc_libm "erf";
cfc_logb  :: (x: float64) -> float64 #foreign cfc_libm "logb";
cfc_log1p :: (x: float64) -> float64 #foreign cfc_libm "log1p";
cfc_pow   :: (x: float64, y: float64) -> float64 #foreign cfc_libm "pow";
cfc_atan2 :: (x: float64, y: float64) -> float64 #foreign cfc_libm "atan2";

// -disable-fp-call-folding (ConstantFolding.cpp)
cfc_disable_fp_call_folding := false;

// ---------------------------------------------------------------- TargetLibraryInfo (math functions)

// The libm functions canConstantFoldCallTo accepts, keyed by their LibFunc names.
CFC_LIBFUNCS :: string.[
    "acos", "acosf", "asin", "asinf", "atan", "atanf", "atan2", "atan2f", "ceil", "ceilf", "cos", "cosf", "cosh", "coshf",
    "exp", "expf", "exp2", "exp2f", "erf", "erff", "fabs", "fabsf", "floor", "floorf", "fmod", "fmodf", "ilogb", "ilogbf",
    "log", "logf", "logl", "log2", "log2f", "log10", "log10f", "logb", "logbf", "log1p", "log1pf",
    "nearbyint", "nearbyintf", "nextafter", "nextafterf", "nexttoward", "nexttowardf", "pow", "powf",
    "remainder", "remainderf", "rint", "rintf", "round", "roundf", "roundeven", "roundevenf",
    "sin", "sinf", "sinh", "sinhf", "sqrt", "sqrtf", "tan", "tanf", "tanh", "tanhf", "trunc", "truncf",
    "__acos_finite", "__acosf_finite", "__asin_finite", "__asinf_finite", "__atan2_finite", "__atan2f_finite",
    "__cosh_finite", "__coshf_finite", "__exp_finite", "__expf_finite", "__exp2_finite", "__exp2f_finite",
    "__log_finite", "__logf_finite", "__log10_finite", "__log10f_finite", "__log2_finite", "__log2f_finite",
    "__pow_finite", "__powf_finite", "__sinh_finite", "__sinhf_finite",
];
CFC_BINARY_LIBFUNCS :: string.["atan2", "fmod", "nextafter", "nexttoward", "pow", "remainder"];

// The LibFunc base name ("log" for logf, __log_finite, ...) and whether it's the float / long double variant.
cfc_libfunc_base :: (name: string) -> (base: string, is_f: bool, is_l: bool, finite: bool) {
    n := name; finite := false;
    if begins_with(n, "__") && ends_with(n, "_finite") { n = slice(n, 2, n.count - 9); finite = true; }
    for CFC_LIBFUNCS if it == name {
        // strip a trailing f / l unless that's part of the base name (erf, logb has no suffix issue)
        if n.count > 1 && (n[n.count - 1] == #char "f") && n != "erf" {
            return slice(n, 0, n.count - 1), true, false, finite;
        }
        if n == "logl" return "log", false, true, finite;
        return n, false, false, finite;
    }
    return "", false, false, false;
}

// TargetLibraryInfoImpl::getLibFunc(StringRef): only the math subset above
tli_get_lib_func :: (name: string) -> bool {
    for CFC_LIBFUNCS if it == name return true;
    return false;
}

// isValidProtoForLibFunc for the subset (TargetLibraryInfo.td signatures; LDbl matches any fp type)
tli_valid_proto :: (ft: Type_Id, name: string) -> bool {
    base, is_f, is_l, finite := cfc_libfunc_base(name);
    if base.count == 0 return false;
    if func_vararg(ft) return false;
    match :: (t: Type_Id, is_f: bool, is_l: bool) -> bool {
        k := type_kind(t);
        if is_l return is_fp_type(t);
        if is_f return k == .FLOAT;
        return k == .DOUBLE;
    }
    nargs := 1;
    for CFC_BINARY_LIBFUNCS if it == base nargs = 2;
    if func_nparams(ft) != cast(u32) nargs return false;
    r := func_ret(ft);
    if base == "ilogb" { if type_kind(r) != .INT || type_int_width(r) != 32 return false; }
    else if !match(r, is_f, is_l) return false;
    if !match(func_param(ft, 0), is_f, is_l) return false;
    if nargs == 2 {
        p1 := func_param(ft, 1);
        if base == "nexttoward" { if !is_fp_type(p1) return false; }
        else if !match(p1, is_f, is_l) return false;
    }
    return true;
}

// TLI->has(F) for the caller of `call`: module triple availability, -disable-simplify-libcalls, and the
// function's "no-builtins" / "no-builtin-<name>" attributes.
tli_has :: (call: Value_Id, name: string) -> bool {
    if opts.disable_simplify_libcalls return false;
    base, is_f, is_l, finite := cfc_libfunc_base(name);
    t := ir.triple;
    if t.count {
        parts := split(t, "-",, allocator = temp);
        os := ifx parts.count > 2 then parts[2] else "";
        env := ifx parts.count > 3 then parts[3] else "";
        if !begins_with(os, "linux") && !begins_with(os, "unknown") && os != "" && !begins_with(os, "none") && !begins_with(os, "elf")
            fatal("constant folding libm calls: TargetLibraryInfo for the target triple '%' is not supported yet", t);
        // the *_finite functions only exist on GNU/Linux (glibc)
        if finite && !(begins_with(os, "linux") && begins_with(env, "gnu")) return false;
    } else if finite return false;
    caller := ifx call != NONE && vkind(call) == .INST && inst(call).parent != NONE then value_function(call) else NONE;
    if caller != NONE {
        if fn_has_str_attr(caller, "no-builtins") return false;
        if fn_has_str_attr(caller, tprint("no-builtin-%", name)) return false;
    }
    return true;
}

// ---------------------------------------------------------------- canConstantFoldCallTo

can_constant_fold_call_to :: (call: Value_Id, f: Value_Id) -> bool {
    if call_is_no_builtin(call) return false;
    if inst(call).ty2 != glob(f).value_type return false;
    ft := glob(f).value_type;
    if cfc_disable_fp_call_folding {
        if is_fp_type(func_ret(ft)) return false;
        n := func_nparams(ft);
        if n > 0 for i: 0..n-1 if is_fp_type(func_param(ft, i)) return false;
    }
    id := fn_iid(f);
    if id != NOT_INTRINSIC {
        if id == {
            case IID_BSWAP; #through; case IID_CTPOP; #through; case IID_CTLZ; #through; case IID_CTTZ; #through;
            case IID_FSHL; #through; case IID_FSHR; #through; case IID_CLMUL; #through; case IID_PDEP; #through; case IID_PEXT; #through;
            case IID_LAUNDER_INVARIANT_GROUP; #through; case IID_STRIP_INVARIANT_GROUP; #through; case IID_MASKED_LOAD; #through;
            case IID_GET_ACTIVE_LANE_MASK; #through; case IID_ABS; #through; case IID_SMAX; #through; case IID_SMIN; #through;
            case IID_UMAX; #through; case IID_UMIN; #through; case IID_SCMP; #through; case IID_UCMP; #through;
            case IID_SADD_WITH_OVERFLOW; #through; case IID_UADD_WITH_OVERFLOW; #through; case IID_SSUB_WITH_OVERFLOW; #through;
            case IID_USUB_WITH_OVERFLOW; #through; case IID_SMUL_WITH_OVERFLOW; #through; case IID_UMUL_WITH_OVERFLOW; #through;
            case IID_SADD_SAT; #through; case IID_UADD_SAT; #through; case IID_SSUB_SAT; #through; case IID_USUB_SAT; #through;
            case IID_SMUL_FIX; #through; case IID_SMUL_FIX_SAT; #through; case IID_BITREVERSE; #through; case IID_IS_CONSTANT; #through;
            case IID_VECTOR_REDUCE_ADD; #through; case IID_VECTOR_REDUCE_MUL; #through; case IID_VECTOR_REDUCE_AND; #through;
            case IID_VECTOR_REDUCE_OR; #through; case IID_VECTOR_REDUCE_XOR; #through; case IID_VECTOR_REDUCE_SMIN; #through;
            case IID_VECTOR_REDUCE_SMAX; #through; case IID_VECTOR_REDUCE_UMIN; #through; case IID_VECTOR_REDUCE_UMAX; #through;
            case IID_VECTOR_EXTRACT; #through; case IID_VECTOR_INSERT; #through;
            case IID_VECTOR_INTERLEAVE2; #through; case IID_VECTOR_INTERLEAVE3; #through; case IID_VECTOR_INTERLEAVE4; #through;
            case IID_VECTOR_INTERLEAVE5; #through; case IID_VECTOR_INTERLEAVE6; #through; case IID_VECTOR_INTERLEAVE7; #through;
            case IID_VECTOR_INTERLEAVE8; #through;
            case IID_VECTOR_DEINTERLEAVE2; #through; case IID_VECTOR_DEINTERLEAVE3; #through; case IID_VECTOR_DEINTERLEAVE4; #through;
            case IID_VECTOR_DEINTERLEAVE5; #through; case IID_VECTOR_DEINTERLEAVE6; #through; case IID_VECTOR_DEINTERLEAVE7; #through;
            case IID_VECTOR_DEINTERLEAVE8;
                return true;
            case IID_MINNUM; #through; case IID_MAXNUM; #through; case IID_MINIMUM; #through; case IID_MAXIMUM; #through;
            case IID_MINIMUMNUM; #through; case IID_MAXIMUMNUM; #through; case IID_LOG; #through; case IID_LOG2; #through;
            case IID_LOG10; #through; case IID_EXP; #through; case IID_EXP2; #through; case IID_EXP10; #through; case IID_SQRT; #through;
            case IID_SIN; #through; case IID_COS; #through; case IID_SINCOS; #through; case IID_SINH; #through; case IID_COSH; #through;
            case IID_ATAN; #through; case IID_POW; #through; case IID_POWI; #through; case IID_LDEXP; #through; case IID_FMA; #through;
            case IID_FMULADD; #through; case IID_FREXP; #through; case IID_FPTOUI_SAT; #through; case IID_FPTOSI_SAT; #through;
            case IID_X86_SSE_CVTSS2SI; #through; case IID_X86_SSE_CVTSS2SI64; #through; case IID_X86_SSE_CVTTSS2SI; #through;
            case IID_X86_SSE_CVTTSS2SI64; #through; case IID_X86_SSE2_CVTSD2SI; #through; case IID_X86_SSE2_CVTSD2SI64; #through;
            case IID_X86_SSE2_CVTTSD2SI; #through; case IID_X86_SSE2_CVTTSD2SI64; #through;
            case IID_X86_AVX512_VCVTSS2SI32; #through; case IID_X86_AVX512_VCVTSS2SI64; #through;
            case IID_X86_AVX512_CVTTSS2SI; #through; case IID_X86_AVX512_CVTTSS2SI64; #through;
            case IID_X86_AVX512_VCVTSD2SI32; #through; case IID_X86_AVX512_VCVTSD2SI64; #through;
            case IID_X86_AVX512_CVTTSD2SI; #through; case IID_X86_AVX512_CVTTSD2SI64; #through;
            case IID_X86_AVX512_VCVTSS2USI32; #through; case IID_X86_AVX512_VCVTSS2USI64; #through;
            case IID_X86_AVX512_CVTTSS2USI; #through; case IID_X86_AVX512_CVTTSS2USI64; #through;
            case IID_X86_AVX512_VCVTSD2USI32; #through; case IID_X86_AVX512_VCVTSD2USI64; #through;
            case IID_X86_AVX512_CVTTSD2USI; #through; case IID_X86_AVX512_CVTTSD2USI64;
                return !call_is_strict_fp(call);
            case IID_FABS; #through; case IID_COPYSIGN; #through; case IID_IS_FPCLASS; #through; case IID_CEIL; #through;
            case IID_FLOOR; #through; case IID_ROUND; #through; case IID_ROUNDEVEN; #through; case IID_TRUNC; #through;
            case IID_NEARBYINT; #through; case IID_RINT; #through; case IID_CANONICALIZE; #through;
            case IID_EXPERIMENTAL_CONSTRAINED_FMA; #through; case IID_EXPERIMENTAL_CONSTRAINED_FMULADD; #through;
            case IID_EXPERIMENTAL_CONSTRAINED_FADD; #through; case IID_EXPERIMENTAL_CONSTRAINED_FSUB; #through;
            case IID_EXPERIMENTAL_CONSTRAINED_FMUL; #through; case IID_EXPERIMENTAL_CONSTRAINED_FDIV; #through;
            case IID_EXPERIMENTAL_CONSTRAINED_FREM; #through; case IID_EXPERIMENTAL_CONSTRAINED_CEIL; #through;
            case IID_EXPERIMENTAL_CONSTRAINED_FLOOR; #through; case IID_EXPERIMENTAL_CONSTRAINED_ROUND; #through;
            case IID_EXPERIMENTAL_CONSTRAINED_ROUNDEVEN; #through; case IID_EXPERIMENTAL_CONSTRAINED_TRUNC; #through;
            case IID_EXPERIMENTAL_CONSTRAINED_NEARBYINT; #through; case IID_EXPERIMENTAL_CONSTRAINED_RINT; #through;
            case IID_EXPERIMENTAL_CONSTRAINED_FCMP; #through; case IID_EXPERIMENTAL_CONSTRAINED_FCMPS; #through;
            case IID_EXPERIMENTAL_CTTZ_ELTS;
                return true;
        }
        return false;
    }
    if vname(f).count == 0 || call_is_strict_fp(call) return false;
    return tli_get_lib_func(vname(f));
}

// ---------------------------------------------------------------- helpers

cfc_fp :: (t: Type_Id, w: [] u64) -> Value_Id { return const_fp_words(t, w); }
cfc_apf :: (t: Type_Id, f: APFloat) -> Value_Id { g := f; return const_fp_words(t, apf_words(*g)); }
apf_from_words :: (k: Type_Kind, w: [] u64) -> APFloat {
    r: APFloat; r.k = k;
    for w if it_index < 2 r.w[it_index] = it;
    return r;
}
cfc_kind :: (t: Type_Id) -> Type_Kind { return type_kind(scalar_type(t)); }

// FTZPreserveSign / FlushToPositiveZero / FlushWithDenormKind
cfc_ftz_preserve_sign :: (k: Type_Kind, w: [] u64) -> [] u64 {
    if apf_is_denormal(apf_from_words(k, w)) return fp_zero(k, fp_decode(k, w).neg);
    return w;
}
cfc_flush :: (k: Type_Kind, w: [] u64, mode: u8) -> [] u64 {
    if mode == DENORMAL_IEEE return w;
    if !apf_is_denormal(apf_from_words(k, w)) return w;
    if mode == DENORMAL_PRESERVE_SIGN return fp_zero(k, fp_decode(k, w).neg);
    return fp_zero(k, false);
}

Host_Fn1 :: #type (x: float64) -> float64 #c_call;
Host_Fn2 :: #type (x: float64, y: float64) -> float64 #c_call;

cfc_fenv_clear :: () { c_feclearexcept(FE_ALL_EXCEPT_X86); c_errno_location().* = 0; }
cfc_fenv_test :: () -> bool {
    e := c_errno_location().*;
    if e == 34 || e == 33 return true;   // ERANGE, EDOM
    if c_fetestexcept(FE_ALL_EXCEPT_X86 & ~FE_INEXACT_X86) return true;
    return false;
}
// GetConstantFoldFPValue
cfc_fp_value :: (r: float64, t: Type_Id) -> Value_Id {
    k := type_kind(t);
    if k != .HALF && k != .FLOAT && k != .DOUBLE fatal("internal: GetConstantFoldFPValue on a non half/float/double type");
    return cfc_fp(t, fp_from_f64(k, r));
}
// ConstantFoldFP (with the default IEEE denormal mode)
cfc_fold_fp :: (fn: Host_Fn1, k: Type_Kind, w: [] u64, t: Type_Id) -> Value_Id {
    cfc_fenv_clear();
    x := fp_to_f64(k, w);
    r: float64;
    r = fn(x);
    if cfc_fenv_test() { cfc_fenv_clear(); return NONE; }
    return cfc_fp_value(r, t);
}
// ConstantFoldBinaryFP
cfc_fold_binary_fp :: (fn: Host_Fn2, k1: Type_Kind, v: [] u64, k2: Type_Kind, w: [] u64, t: Type_Id) -> Value_Id {
    cfc_fenv_clear();
    r := fn(fp_to_f64(k1, v), fp_to_f64(k2, w));
    if cfc_fenv_test() { cfc_fenv_clear(); return NONE; }
    return cfc_fp_value(r, t);
}
cfc_double_words :: (d: float64) -> [] u64 { return fp_from_f64(.DOUBLE, d); }

// getConstIntOrUndef: (ok, is_undef, value)
cfc_const_int_or_undef :: (c: Value_Id) -> (ok: bool, undef: bool, v: APInt) {
    k := vkind(c);
    if k == .C_INT && !is_vector_type(vtype(c)) return true, false, cf_ap(c);
    if k == .C_UNDEF || k == .C_POISON { z: APInt; return true, true, z; }
    z: APInt;
    return false, false, z;
}
cfc_is_const_fp :: (c: Value_Id) -> bool { return c != NONE && vkind(c) == .C_FP; }   // dyn_cast<ConstantFP>: vector splats too
cfc_is_const_int :: (c: Value_Id) -> bool { return c != NONE && vkind(c) == .C_INT && !is_vector_type(vtype(c)); }
cfc_is_undef :: (c: Value_Id) -> bool { k := vkind(c); return k == .C_UNDEF || k == .C_POISON; }

// Constant::isManifestConstant
is_manifest_constant :: (c: Value_Id) -> bool {
    k := vkind(c);
    if k == .C_UNDEF || k == .C_POISON return false;
    if k == .C_INT || k == .C_FP || k == .C_NULL || k == .C_ZERO || k == .C_DATA || k == .C_TOKEN_NONE || k == .C_TARGET_NONE return true;
    if k == .C_STRUCT || k == .C_ARRAY || k == .C_VECTOR || k == .C_EXPR {
        n := nops(c);
        if n > 0 for i: 0..n-1 if !is_manifest_constant(op(c, i)) return false;
        return true;
    }
    return false;
}

// mayFoldConstrained
cfc_may_fold_constrained :: (eb: u8, rm: u8, has_eb: bool, st: Fp_Status) -> bool {
    if st == 0 return true;
    if rm == RM_DYNAMIC return false;
    if has_eb && eb != EB_STRICT return true;
    return false;
}

// constrained intrinsic info of a call: (is constrained, eb, has eb, rm, has rm)
Cfc_Constrained :: struct { is: bool; eb: u8; has_eb: bool; rm: u8; has_rm: bool; }
cfc_constrained :: (call: Value_Id) -> Cfc_Constrained {
    r: Cfc_Constrained;
    if call == NONE return r;
    id := call_iid(call);
    if id == NOT_INTRINSIC || !is_constrained_fp_intrinsic(id) return r;
    r.is = true;
    es := constrained_md_string(call, 1);
    if es == "fpexcept.ignore" { r.eb = EB_IGNORE; r.has_eb = true; }
    else if es == "fpexcept.maytrap" { r.eb = EB_MAY_TRAP; r.has_eb = true; }
    else if es == "fpexcept.strict" { r.eb = EB_STRICT; r.has_eb = true; }
    if constrained_has_rounding(id) {
        rs := constrained_md_string(call, 2);
        r.has_rm = true;
        if rs == "round.dynamic" r.rm = RM_DYNAMIC;
        else if rs == "round.tonearest" r.rm = RM_NEAREST_TIES_TO_EVEN;
        else if rs == "round.tonearestaway" r.rm = RM_NEAREST_TIES_TO_AWAY;
        else if rs == "round.downward" r.rm = RM_TOWARD_NEGATIVE;
        else if rs == "round.upward" r.rm = RM_TOWARD_POSITIVE;
        else if rs == "round.towardzero" r.rm = RM_TOWARD_ZERO;
        else r.has_rm = false;
    }
    return r;
}
// getEvaluationRoundingMode
cfc_eval_rm :: (c: Cfc_Constrained) -> u8 {
    if !c.has_rm || c.rm == RM_DYNAMIC return RM_NEAREST_TIES_TO_EVEN;
    return c.rm;
}

// constantFoldCanonicalize
cfc_canonicalize :: (t: Type_Id, k: Type_Kind, w: [] u64, ctx_f: Value_Id) -> Value_Id {
    d := fp_decode(k, w);
    if d.cat == .ZERO return cfc_fp(t, fp_zero(k, d.neg));
    if k != .HALF && k != .BFLOAT && k != .FLOAT && k != .DOUBLE && k != .FP128 return NONE;   // isIEEELikeFPTy
    f := apf_from_words(k, w);
    if (d.cat == .NORMAL && !apf_is_denormal(f)) || d.cat == .INF return cfc_fp(t, w);
    if apf_is_denormal(f) && ctx_f != NONE {
        out, inp := fn_denormal_mode(ctx_f, t);
        if out == DENORMAL_IEEE && inp == DENORMAL_IEEE return cfc_fp(t, w);
        if inp == DENORMAL_DYNAMIC return NONE;
        if (inp == DENORMAL_DYNAMIC && out == DENORMAL_IEEE) || (inp == DENORMAL_IEEE && out == DENORMAL_DYNAMIC) return NONE;
        is_positive := !d.neg || inp == DENORMAL_POSITIVE_ZERO || (out == DENORMAL_POSITIVE_ZERO && inp == DENORMAL_IEEE);
        return cfc_fp(t, fp_zero(k, !is_positive));
    }
    return NONE;
}

// ConstantFoldSSEConvertToInt
cfc_sse_convert_to_int :: (k: Type_Kind, w: [] u64, round_toward_zero: bool, t: Type_Id, is_signed: bool) -> Value_Id {
    width := type_int_width(t);
    if width > 64 fatal("internal: SSE conversion to more than 64 bits");
    rm: u8 = ifx round_toward_zero then cast(u8) RM_TOWARD_ZERO else RM_NEAREST_TIES_TO_EVEN;
    words, st, exact := fp_to_integer_rm(k, w, width, is_signed, rm);
    if st != 0 && (!round_toward_zero || st != .INEXACT) return NONE;
    return const_int_words(t, words);
}

// constantFoldVectorReduce
cfc_vector_reduce :: (id: Intrinsic_Id, op_c: Value_Id) -> Value_Id {
    vt := vtype(op_c);
    et := type_elem(vt);
    if cf_contains_poison_element(op_c) return const_poison(et);
    splat := get_splat_value(op_c);
    if splat != NONE {
        if id == {
            case IID_VECTOR_REDUCE_AND; #through; case IID_VECTOR_REDUCE_OR; #through; case IID_VECTOR_REDUCE_SMIN; #through;
            case IID_VECTOR_REDUCE_SMAX; #through; case IID_VECTOR_REDUCE_UMIN; #through; case IID_VECTOR_REDUCE_UMAX;
                return splat;
            case IID_VECTOR_REDUCE_ADD; if is_null_value(splat) return splat;
            case IID_VECTOR_REDUCE_MUL; if is_null_value(splat) || is_one_value(splat) return splat;
            case IID_VECTOR_REDUCE_XOR;
                if is_null_value(splat) return splat;
                if type_count(vt) % 2 == 0 return const_null_value(et);
        }
    }
    if type_kind(vt) != .VECTOR return NONE;
    e0 := cf_elt(op_c, 0);
    if !cfc_is_const_int(e0) return NONE;
    acc := cf_ap(e0);
    n := type_count(vt);
    for i: 1..cast(s64) n - 1 {
        e := cf_elt(op_c, cast(u64) i);
        if !cfc_is_const_int(e) return NONE;
        x := cf_ap(e);
        if id == {
            case IID_VECTOR_REDUCE_ADD; acc = ap_add(acc, x);
            case IID_VECTOR_REDUCE_MUL; acc = ap_mul(acc, x);
            case IID_VECTOR_REDUCE_AND; acc = ap_and(acc, x);
            case IID_VECTOR_REDUCE_OR; acc = ap_or(acc, x);
            case IID_VECTOR_REDUCE_XOR; acc = ap_xor(acc, x);
            case IID_VECTOR_REDUCE_SMIN; acc = ap_smin(acc, x);
            case IID_VECTOR_REDUCE_SMAX; acc = ap_smax(acc, x);
            case IID_VECTOR_REDUCE_UMIN; acc = ap_umin(acc, x);
            case IID_VECTOR_REDUCE_UMAX; acc = ap_umax(acc, x);
        }
    }
    return cf_int(et, acc);
}

// MinMaxIntrinsic::getSaturationPoint
cfc_minmax_saturation :: (id: Intrinsic_Id, t: Type_Id) -> Value_Id {
    bits := type_bits(scalar_type(t));
    if id == {
        case IID_SMAX; return cf_int(t, ap_signed_max(bits));
        case IID_SMIN; return cf_int(t, ap_signed_min(bits));
        case IID_UMAX; return cf_int(t, ap_all_ones(bits));
    }
    return cf_int(t, ap_zero(bits));
}

// APIntOps::pdep / pext
cfc_pdep :: (src: APInt, mask: APInt) -> APInt {
    r := ap_zero(src.bits);
    k: u32 = 0;
    for i: 0..src.bits - 1 {
        if !ap_get_bit(mask, i) continue;
        if ap_get_bit(src, k) ap_set_bit(*r, i);
        k += 1;
    }
    return r;
}
cfc_pext :: (src: APInt, mask: APInt) -> APInt {
    r := ap_zero(src.bits);
    k: u32 = 0;
    for i: 0..src.bits - 1 {
        if !ap_get_bit(mask, i) continue;
        if ap_get_bit(src, i) ap_set_bit(*r, k);
        k += 1;
    }
    return r;
}

// isVectorIntrinsicWithScalarOpAtArg (VectorUtils.cpp; no TTI, no VP intrinsics here)
is_vector_intrinsic_with_scalar_op_at_arg :: (id: Intrinsic_Id, idx: u32) -> bool {
    if id == {
        case IID_ABS; #through; case IID_CTLZ; #through; case IID_CTTZ; #through; case IID_IS_FPCLASS; #through;
        case IID_POWI; #through; case IID_VECTOR_EXTRACT;
            return idx == 1;
        case IID_SMUL_FIX; #through; case IID_SMUL_FIX_SAT; #through; case IID_UMUL_FIX; #through; case IID_UMUL_FIX_SAT;
            return idx == 2;
    }
    return false;
}

// ---------------------------------------------------------------- ConstantFoldScalarCall1

cfc_scalar_call1 :: (name: string, id: Intrinsic_Id, t: Type_Id, ops: [] Value_Id, call: Value_Id) -> Value_Id {
    op0 := ops[0];
    if id == IID_IS_CONSTANT {
        if is_manifest_constant(op0) return cf_bool(t, true);
        return NONE;
    }
    if cfc_is_undef(op0) {
        if id == IID_COS || id == IID_CTPOP || id == IID_FPTOUI_SAT || id == IID_FPTOSI_SAT || id == IID_CANONICALIZE
            return const_null_value(t);
        if id == IID_BSWAP || id == IID_BITREVERSE || id == IID_LAUNDER_INVARIANT_GROUP || id == IID_STRIP_INVARIANT_GROUP
            return op0;
    }
    if vkind(op0) == .C_NULL && !is_vector_type(vtype(op0)) {
        if id == IID_LAUNDER_INVARIANT_GROUP || id == IID_STRIP_INVARIANT_GROUP {
            caller := ifx call != NONE && inst(call).parent != NONE then value_function(call) else NONE;
            if caller != NONE && !null_pointer_is_defined(caller, ir.types[vtype(op0)].a) return op0;
            return NONE;
        }
    }
    if cfc_is_const_fp(op0) {
        k := cfc_kind(vtype(op0));
        u := const_fp_value(op0);
        if id == IID_FPTOUI_SAT || id == IID_FPTOSI_SAT {
            words, st, exact := fp_to_integer_rm(k, u, type_int_width(t), id == IID_FPTOSI_SAT, RM_TOWARD_ZERO);
            return const_int_words(t, words);
        }
        if id == IID_CANONICALIZE {
            ctx_f := ifx call != NONE && inst(call).parent != NONE then value_function(call) else NONE;
            return cfc_canonicalize(t, k, u, ctx_f);
        }
        tk := type_kind(t);
        if tk != .HALF && tk != .FLOAT && tk != .DOUBLE && tk != .INT return NONE;
        if id == IID_NEARBYINT || id == IID_RINT || id == IID_ROUNDEVEN { r := fp_round_to_integral(k, u, RM_NEAREST_TIES_TO_EVEN); return cfc_fp(t, r); }
        if id == IID_ROUND { r := fp_round_to_integral(k, u, RM_NEAREST_TIES_TO_AWAY); return cfc_fp(t, r); }
        if id == IID_CEIL { r := fp_round_to_integral(k, u, RM_TOWARD_POSITIVE); return cfc_fp(t, r); }
        if id == IID_FLOOR { r := fp_round_to_integral(k, u, RM_TOWARD_NEGATIVE); return cfc_fp(t, r); }
        if id == IID_TRUNC { r := fp_round_to_integral(k, u, RM_TOWARD_ZERO); return cfc_fp(t, r); }
        if id == IID_FABS return cfc_fp(t, fp_with_sign(k, u, false));
        ci := cfc_constrained(call);
        if ci.is {
            has_rm := false; rm: u8;
            if id == {
                case IID_EXPERIMENTAL_CONSTRAINED_NEARBYINT; #through;
                case IID_EXPERIMENTAL_CONSTRAINED_RINT;
                    if !ci.has_rm || ci.rm == RM_DYNAMIC return NONE;
                    rm = ci.rm; has_rm = true;
                case IID_EXPERIMENTAL_CONSTRAINED_ROUND; rm = RM_NEAREST_TIES_TO_AWAY; has_rm = true;
                case IID_EXPERIMENTAL_CONSTRAINED_CEIL; rm = RM_TOWARD_POSITIVE; has_rm = true;
                case IID_EXPERIMENTAL_CONSTRAINED_FLOOR; rm = RM_TOWARD_NEGATIVE; has_rm = true;
                case IID_EXPERIMENTAL_CONSTRAINED_TRUNC; rm = RM_TOWARD_ZERO; has_rm = true;
            }
            if has_rm {
                d := fp_decode(k, u);
                res := u;
                if d.cat == .ZERO || d.cat == .NORMAL {
                    r, st := fp_round_to_integral(k, u, rm);
                    res = r;
                    if id == IID_EXPERIMENTAL_CONSTRAINED_RINT && st == .INEXACT {
                        if ci.has_eb && ci.eb == EB_STRICT return NONE;
                    }
                } else if fp_is_signaling(k, d) {
                    if ci.has_eb && ci.eb != EB_IGNORE return NONE;
                    res = fp_default_nan(k);   // APFloat::getQNaN
                }
                return cfc_fp(t, res);
            }
        }
        d := fp_decode(k, u);
        if d.cat == .NAN || d.cat == .INF return NONE;
        is_one := apf_is_exactly_one(apf_from_words(k, u));
        if id == {
            case IID_LOG;
                if d.cat == .ZERO return cfc_fp(t, fp_inf(k, true));
                if d.neg return cf_nan(t);
                if is_one return cfc_fp(t, fp_zero(k, false));
                return cfc_fold_fp(cfc_log, k, u, t);
            case IID_LOG2;
                if d.cat == .ZERO return cfc_fp(t, fp_inf(k, true));
                if d.neg return cf_nan(t);
                if is_one return cfc_fp(t, fp_zero(k, false));
                return cfc_fold_fp(cfc_log2, k, u, t);
            case IID_LOG10;
                if d.cat == .ZERO return cfc_fp(t, fp_inf(k, true));
                if d.neg return cf_nan(t);
                if is_one return cfc_fp(t, fp_zero(k, false));
                return cfc_fold_fp(cfc_log10, k, u, t);
            case IID_EXP; return cfc_fold_fp(cfc_exp, k, u, t);
            case IID_EXP2; return cfc_fold_binary_fp(cfc_pow, .DOUBLE, cfc_double_words(2.0), k, u, t);
            case IID_EXP10; return cfc_fold_binary_fp(cfc_pow, .DOUBLE, cfc_double_words(10.0), k, u, t);
            case IID_SIN; return cfc_fold_fp(cfc_sin, k, u, t);
            case IID_COS; return cfc_fold_fp(cfc_cos, k, u, t);
            case IID_SINH; return cfc_fold_fp(cfc_sinh, k, u, t);
            case IID_COSH; return cfc_fold_fp(cfc_cosh, k, u, t);
            case IID_ATAN;
                if d.cat == .ZERO return cfc_fp(t, u);
                return cfc_fold_fp(cfc_atan, k, u, t);
            case IID_SQRT; return cfc_fold_fp(cfc_sqrt, k, u, t);
        }
        if id != NOT_INTRINSIC return NONE;
        if !tli_get_lib_func(name) return NONE;
        base, is_f, is_l, finite := cfc_libfunc_base(name);
        has := tli_has(call, name);
        if base == {
            case "acos"; if has return cfc_fold_fp(cfc_acos, k, u, t);
            case "asin"; if has return cfc_fold_fp(cfc_asin, k, u, t);
            case "atan";
                if d.cat == .ZERO return cfc_fp(t, u);
                if has return cfc_fold_fp(cfc_atan, k, u, t);
            case "ceil"; if has { r := fp_round_to_integral(k, u, RM_TOWARD_POSITIVE); return cfc_fp(t, r); }
            case "cos"; if has return cfc_fold_fp(cfc_cos, k, u, t);
            case "cosh"; if has return cfc_fold_fp(cfc_cosh, k, u, t);
            case "exp"; if has return cfc_fold_fp(cfc_exp, k, u, t);
            case "exp2"; if has return cfc_fold_binary_fp(cfc_pow, .DOUBLE, cfc_double_words(2.0), k, u, t);
            case "fabs"; if has return cfc_fp(t, fp_with_sign(k, u, false));
            case "floor"; if has { r := fp_round_to_integral(k, u, RM_TOWARD_NEGATIVE); return cfc_fp(t, r); }
            case "log";
                if is_l return NONE;   // LibFunc_logl (no host logf128)
                if !d.neg && d.cat != .ZERO && has return cfc_fold_fp(cfc_log, k, u, t);
            case "log2"; if !d.neg && d.cat != .ZERO && has return cfc_fold_fp(cfc_log2, k, u, t);
            case "log10"; if !d.neg && d.cat != .ZERO && has return cfc_fold_fp(cfc_log10, k, u, t);
            case "ilogb"; if d.cat != .ZERO && has return const_int_words(t, ap_words(ap_from_s64(type_int_width(t), fp_ilogb(k, u))));
            case "logb"; if d.cat != .ZERO && has return cfc_fold_fp(cfc_logb, k, u, t);
            case "log1p";
                if d.cat == .ZERO return cfc_fp(t, u);
                minus_one := fp_neg(k, fp_from_integer(k, .[1], 64, false));
                if fp_compare(k, u, minus_one) == .GREATER && has return cfc_fold_fp(cfc_log1p, k, u, t);
            case "erf"; if has return cfc_fold_fp(cfc_erf, k, u, t);
            case "nearbyint"; #through;
            case "rint"; #through;
            case "roundeven"; if has { r := fp_round_to_integral(k, u, RM_NEAREST_TIES_TO_EVEN); return cfc_fp(t, r); }
            case "round"; if has { r := fp_round_to_integral(k, u, RM_NEAREST_TIES_TO_AWAY); return cfc_fp(t, r); }
            case "sin"; if has return cfc_fold_fp(cfc_sin, k, u, t);
            case "sinh"; if has return cfc_fold_fp(cfc_sinh, k, u, t);
            case "sqrt"; if !d.neg && has return cfc_fold_fp(cfc_sqrt, k, u, t);
            case "tan"; if has return cfc_fold_fp(cfc_tan, k, u, t);
            case "tanh"; if has return cfc_fold_fp(cfc_tanh, k, u, t);
            case "trunc"; if has { r := fp_round_to_integral(k, u, RM_TOWARD_ZERO); return cfc_fp(t, r); }
        }
        return NONE;
    }
    if cfc_is_const_int(op0) {
        v := cf_ap(op0);
        if id == {
            case IID_BSWAP; return cf_int(t, ap_byte_swap(v));
            case IID_CTPOP; return cf_int(t, ap_from_u64(type_int_width(t), cast(u64) ap_popcount(v)));
            case IID_BITREVERSE; return cf_int(t, ap_reverse_bits(v));
        }
        return NONE;
    }
    if is_vector_type(vtype(op0)) {
        if id == {
            case IID_VECTOR_REDUCE_ADD; #through; case IID_VECTOR_REDUCE_MUL; #through; case IID_VECTOR_REDUCE_AND; #through;
            case IID_VECTOR_REDUCE_OR; #through; case IID_VECTOR_REDUCE_XOR; #through; case IID_VECTOR_REDUCE_SMIN; #through;
            case IID_VECTOR_REDUCE_SMAX; #through; case IID_VECTOR_REDUCE_UMIN; #through; case IID_VECTOR_REDUCE_UMAX;
                c := cfc_vector_reduce(id, op0);
                if c != NONE return c;
            case IID_X86_SSE_CVTSS2SI; #through; case IID_X86_SSE_CVTSS2SI64; #through;
            case IID_X86_SSE2_CVTSD2SI; #through; case IID_X86_SSE2_CVTSD2SI64;
                e := cf_elt(op0, 0);
                if cfc_is_const_fp(e) return cfc_sse_convert_to_int(cfc_kind(vtype(e)), const_fp_value(e), false, t, true);
            case IID_X86_SSE_CVTTSS2SI; #through; case IID_X86_SSE_CVTTSS2SI64; #through;
            case IID_X86_SSE2_CVTTSD2SI; #through; case IID_X86_SSE2_CVTTSD2SI64;
                e := cf_elt(op0, 0);
                if cfc_is_const_fp(e) return cfc_sse_convert_to_int(cfc_kind(vtype(e)), const_fp_value(e), true, t, true);
        }
    }
    return NONE;
}

// ---------------------------------------------------------------- two operands

// evaluateCompare
cfc_evaluate_compare :: (k: Type_Kind, a: [] u64, b: [] u64, call: Value_Id, ci: Cfc_Constrained) -> Value_Id {
    st: Fp_Status;
    da := fp_decode(k, a); db := fp_decode(k, b);
    signaling := call_iid(call) == IID_EXPERIMENTAL_CONSTRAINED_FCMPS;
    if signaling { if da.cat == .NAN || db.cat == .NAN st = .INVALID; }
    else { if fp_is_signaling(k, da) || fp_is_signaling(k, db) st = .INVALID; }
    ps := constrained_md_string(call, 2);
    pred := fcmp_pred_from_name(ps);
    if pred > FCMP_TRUE fatal("internal: constrained fcmp with an invalid predicate '%'", ps);
    result := fcmp_compare(k, a, b, pred);
    if cfc_may_fold_constrained(ci.eb, ci.rm, ci.has_eb, st) return cf_bool(scalar_type(func_ret(inst(call).ty2)), result);
    return NONE;
}
fcmp_pred_from_name :: (s: string) -> u8 {
    names :: string.["false", "oeq", "ogt", "oge", "olt", "ole", "one", "ord", "uno", "ueq", "ugt", "uge", "ult", "ule", "une", "true"];
    for names if it == s return cast(u8) it_index;
    return 255;
}

// ConstantFoldNextToward
cfc_next_toward :: (k0: Type_Kind, op0: [] u64, k1: Type_Kind, op1: [] u64, rt: Type_Id) -> Value_Id {
    rk := type_kind(rt);
    d1 := fp_decode(k1, op1);
    if fp_is_signaling(k1, d1) return NONE;
    if d1.cat == .NAN {
        r, ex := fp_convert(k1, rk, op1);
        return cfc_fp(rt, r);
    }
    p0, ex0 := fp_convert(k0, k1, op0);
    res := fp_compare(k1, p0, op1);
    if res == .EQUAL {
        r, ex := fp_convert(k1, rk, op1);
        return cfc_fp(rt, r);
    }
    nx, st := fp_next(k0, op0, res == .GREATER);
    dn := fp_decode(k0, nx);
    if dn.cat == .ZERO || apf_is_denormal(apf_from_words(k0, nx)) || fp_is_signaling(k0, dn) return NONE;
    return cfc_fp(rt, nx);
}

// ConstantFoldLibCall2
cfc_lib_call2 :: (name: string, t: Type_Id, ops: [] Value_Id, call: Value_Id) -> Value_Id {
    if !tli_get_lib_func(name) return NONE;
    if !cfc_is_const_fp(ops[0]) || !cfc_is_const_fp(ops[1]) return NONE;
    k1 := cfc_kind(vtype(ops[0])); k2 := cfc_kind(vtype(ops[1]));
    a := const_fp_value(ops[0]); b := const_fp_value(ops[1]);
    base, is_f, is_l, finite := cfc_libfunc_base(name);
    has := tli_has(call, name);
    if base == {
        case "pow"; if has return cfc_fold_binary_fp(cfc_pow, k1, a, k2, b, t);
        case "fmod";
            if has { r, st := fp_mod(k1, a, b); if st == 0 return cfc_fp(t, r); }
        case "remainder";
            if has { r, st := fp_remainder(k1, a, b); if st == 0 return cfc_fp(t, r); }
        case "atan2";
            if !finite && fp_decode(k1, a).cat == .ZERO && fp_decode(k2, b).cat == .ZERO return NONE;
            if has return cfc_fold_binary_fp(cfc_atan2, k1, a, k2, b, t);
        case "nextafter"; #through;
        case "nexttoward";
            if has return cfc_next_toward(k1, a, k2, b, t);
    }
    return NONE;
}

// ConstantFoldIntrinsicCall2
cfc_intrinsic_call2 :: (id: Intrinsic_Id, t: Type_Id, ops: [] Value_Id, call: Value_Id) -> Value_Id {
    if is_fp_type(t) {
        u0 := cfc_is_undef(ops[0]); u1 := cfc_is_undef(ops[1]);
        if id == IID_MAXNUM || id == IID_MINNUM || id == IID_MAXIMUM || id == IID_MINIMUM || id == IID_MAXIMUMNUM || id == IID_MINIMUMNUM {
            if u0 return ops[1];
            if u1 return ops[0];
        }
    }
    if cfc_is_const_fp(ops[0]) {
        k := cfc_kind(vtype(ops[0]));
        a := const_fp_value(ops[0]);
        if cfc_is_const_fp(ops[1]) {
            if vtype(ops[1]) != vtype(ops[0]) return NONE;
            b := const_fp_value(ops[1]);
            ci := cfc_constrained(call);
            if ci.is {
                rm := cfc_eval_rm(ci);
                res: [] u64; st: Fp_Status;
                if id == {
                    case IID_EXPERIMENTAL_CONSTRAINED_FADD; res, st = fp_add_sub(k, a, b, false, rm);
                    case IID_EXPERIMENTAL_CONSTRAINED_FSUB; res, st = fp_add_sub(k, a, b, true, rm);
                    case IID_EXPERIMENTAL_CONSTRAINED_FMUL; res, st = fp_mul(k, a, b, rm);
                    case IID_EXPERIMENTAL_CONSTRAINED_FDIV; res, st = fp_div(k, a, b, rm);
                    case IID_EXPERIMENTAL_CONSTRAINED_FREM; res, st = fp_mod(k, a, b);
                    case IID_EXPERIMENTAL_CONSTRAINED_FCMP; #through;
                    case IID_EXPERIMENTAL_CONSTRAINED_FCMPS; return cfc_evaluate_compare(k, a, b, call, ci);
                    case; return NONE;
                }
                if cfc_may_fold_constrained(ci.eb, ci.rm, ci.has_eb, st) return cfc_fp(t, res);
                return NONE;
            }
            fa := apf_from_words(k, a); fb := apf_from_words(k, b);
            if id == {
                case IID_COPYSIGN; return cfc_fp(t, fp_with_sign(k, a, fp_decode(k, b).neg));
                case IID_MINNUM; return cfc_apf(t, apf_minnum(fa, fb));
                case IID_MAXNUM; return cfc_apf(t, apf_maxnum(fa, fb));
                case IID_MINIMUM; return cfc_apf(t, apf_minimum(fa, fb));
                case IID_MAXIMUM; return cfc_apf(t, apf_maximum(fa, fb));
                case IID_MINIMUMNUM; return cfc_apf(t, apf_minimumnum(fa, fb));
                case IID_MAXIMUMNUM; return cfc_apf(t, apf_maximumnum(fa, fb));
            }
            tk := type_kind(t);
            if tk != .HALF && tk != .FLOAT && tk != .DOUBLE return NONE;
            if id == IID_POW return cfc_fold_binary_fp(cfc_pow, k, a, k, b, t);
            return NONE;
        }
        if cfc_is_const_int(ops[1]) {
            c := cf_ap(ops[1]);
            if id == {
                case IID_LDEXP;
                    e: APInt;
                    if c.bits < 32 e = ap_sext(c, 32);
                    else if ap_slt(c, ap_sext(ap_signed_min(32), c.bits)) e = ap_signed_min(32);
                    else if ap_sgt(c, ap_sext(ap_signed_max(32), c.bits)) e = ap_signed_max(32);
                    else e = ap_trunc(c, 32);
                    return cfc_fp(vtype(ops[0]), fp_scalbn(k, a, ap_sext_value(e), RM_NEAREST_TIES_TO_EVEN));
                case IID_IS_FPCLASS;
                    mask := cast(u32) ap_zext_value(c);
                    d := fp_decode(k, a);
                    den := apf_is_denormal(apf_from_words(k, a));
                    nrm := d.cat == .NORMAL && !den;
                    sig := fp_is_signaling(k, d);
                    r := ((mask & FC_SNAN) && d.cat == .NAN && sig) || ((mask & FC_QNAN) && d.cat == .NAN && !sig) ||
                         ((mask & FC_NEG_INF) && d.cat == .INF && d.neg) || ((mask & FC_NEG_NORMAL) && nrm && d.neg) ||
                         ((mask & FC_NEG_SUBNORMAL) && den && d.neg) || ((mask & FC_NEG_ZERO) && d.cat == .ZERO && d.neg) ||
                         ((mask & FC_POS_ZERO) && d.cat == .ZERO && !d.neg) || ((mask & FC_POS_SUBNORMAL) && den && !d.neg) ||
                         ((mask & FC_POS_NORMAL) && nrm && !d.neg) || ((mask & FC_POS_INF) && d.cat == .INF && !d.neg);
                    return cf_bool(t, r);
                case IID_POWI;
                    e := cast(s32) ap_sext_value(c);
                    tk := type_kind(t);
                    if tk == .HALF || tk == .FLOAT {
                        x := cast(float32) fp_to_f64(k, a);
                        r := cast(float32) cfc_pow(cast(float64) x, cast(float64) e);   // std::pow(float, int) promotes to double
                        return cfc_fp(t, fp_from_f64(tk, cast(float64) r));
                    }
                    if tk == .DOUBLE return cfc_fp(t, fp_from_f64(.DOUBLE, cfc_pow(fp_to_f64(k, a), cast(float64) e)));
                    return NONE;
            }
        }
        return NONE;
    }
    t0 := vtype(ops[0]); t1 := vtype(ops[1]);
    if type_kind(t0) == .INT && type_kind(t1) == .INT {
        ok0, un0, c0 := cfc_const_int_or_undef(ops[0]);
        ok1, un1, c1 := cfc_const_int_or_undef(ops[1]);
        if !ok0 || !ok1 return NONE;
        if id == {
            case IID_SMAX; #through; case IID_SMIN; #through; case IID_UMAX; #through; case IID_UMIN;
                if un0 || un1 return cfc_minmax_saturation(id, t);
                pick := false;
                if id == IID_SMAX pick = ap_sgt(c0, c1);
                else if id == IID_SMIN pick = ap_slt(c0, c1);
                else if id == IID_UMAX pick = ap_ugt(c0, c1);
                else pick = ap_ult(c0, c1);
                return cf_int(t, ifx pick then c0 else c1);
            case IID_SCMP; #through; case IID_UCMP;
                if un0 || un1 return const_int(t, 0);
                r: s64;
                if id == IID_SCMP r = ap_scmp(c0, c1); else r = ap_ucmp(c0, c1);
                return cf_int(t, ap_from_s64(type_int_width(t), r));
            case IID_USUB_WITH_OVERFLOW; #through; case IID_SSUB_WITH_OVERFLOW; #through;
            case IID_UADD_WITH_OVERFLOW; #through; case IID_SADD_WITH_OVERFLOW; #through;
            case IID_SMUL_WITH_OVERFLOW; #through; case IID_UMUL_WITH_OVERFLOW;
                if un0 || un1 {
                    if id == IID_USUB_WITH_OVERFLOW || id == IID_SSUB_WITH_OVERFLOW || id == IID_SMUL_WITH_OVERFLOW || id == IID_UMUL_WITH_OVERFLOW
                        return const_null_value(t);
                    elts: [2] Value_Id;
                    elts[0] = cf_all_ones(type_sub(t, 0));
                    elts[1] = const_null_value(type_sub(t, 1));
                    return const_aggregate(.C_STRUCT, t, elts);
                }
                res: APInt; ov: bool;
                if id == {
                    case IID_SADD_WITH_OVERFLOW; res, ov = ap_sadd_ov(c0, c1);
                    case IID_UADD_WITH_OVERFLOW; res, ov = ap_uadd_ov(c0, c1);
                    case IID_SSUB_WITH_OVERFLOW; res, ov = ap_ssub_ov(c0, c1);
                    case IID_USUB_WITH_OVERFLOW; res, ov = ap_usub_ov(c0, c1);
                    case IID_SMUL_WITH_OVERFLOW; res, ov = ap_smul_ov(c0, c1);
                    case IID_UMUL_WITH_OVERFLOW; res, ov = ap_umul_ov(c0, c1);
                }
                elts: [2] Value_Id;
                elts[0] = cf_int(type_sub(t, 0), res);
                elts[1] = cf_bool(ir.t_i1, ov);
                return const_aggregate(.C_STRUCT, t, elts);
            case IID_UADD_SAT; #through; case IID_SADD_SAT;
                if un0 || un1 return cf_all_ones(t);
                if id == IID_UADD_SAT return cf_int(t, ap_uadd_sat(c0, c1));
                return cf_int(t, ap_sadd_sat(c0, c1));
            case IID_USUB_SAT; #through; case IID_SSUB_SAT;
                if un0 || un1 return const_null_value(t);
                if id == IID_USUB_SAT return cf_int(t, ap_usub_sat(c0, c1));
                return cf_int(t, ap_ssub_sat(c0, c1));
            case IID_CTTZ; #through; case IID_CTLZ;
                if !un1 && ap_is_one(c1) && (un0 || ap_is_zero(c0)) return const_poison(t);
                if un0 return const_null_value(t);
                if id == IID_CTTZ return cf_int(t, ap_from_u64(c0.bits, cast(u64) ap_ctz(c0)));
                return cf_int(t, ap_from_u64(c0.bits, cast(u64) ap_clz(c0)));
            case IID_ABS;
                if !un1 && ap_is_one(c1) && (un0 || ap_is_min_signed(c0)) return const_poison(t);
                if un0 return const_null_value(t);
                return cf_int(t, ap_abs(c0));
            case IID_CLMUL;
                if un0 || un1 return const_null_value(t);
                return cf_int(t, ap_clmul(c0, c1));
            case IID_PDEP;
                if un0 || un1 return const_null_value(t);
                return cf_int(t, cfc_pdep(c0, c1));
            case IID_PEXT;
                if un0 || un1 return const_null_value(t);
                return cf_int(t, cfc_pext(c0, c1));
        }
        return NONE;
    }
    k0 := vkind(ops[0]);
    if (k0 == .C_VECTOR || k0 == .C_DATA) && cfc_is_const_int(ops[1]) && ap_zext_value(cf_ap(ops[1])) == 4 && cf_ap(ops[1]).bits <= 64 {
        e := cf_elt(ops[0], 0);
        if cfc_is_const_fp(e) {
            ek := cfc_kind(vtype(e)); ew := const_fp_value(e);
            if id == {
                case IID_X86_AVX512_VCVTSS2SI32; #through; case IID_X86_AVX512_VCVTSS2SI64; #through;
                case IID_X86_AVX512_VCVTSD2SI32; #through; case IID_X86_AVX512_VCVTSD2SI64;
                    return cfc_sse_convert_to_int(ek, ew, false, t, true);
                case IID_X86_AVX512_VCVTSS2USI32; #through; case IID_X86_AVX512_VCVTSS2USI64; #through;
                case IID_X86_AVX512_VCVTSD2USI32; #through; case IID_X86_AVX512_VCVTSD2USI64;
                    return cfc_sse_convert_to_int(ek, ew, false, t, false);
                case IID_X86_AVX512_CVTTSS2SI; #through; case IID_X86_AVX512_CVTTSS2SI64; #through;
                case IID_X86_AVX512_CVTTSD2SI; #through; case IID_X86_AVX512_CVTTSD2SI64;
                    return cfc_sse_convert_to_int(ek, ew, true, t, true);
                case IID_X86_AVX512_CVTTSS2USI; #through; case IID_X86_AVX512_CVTTSS2USI64; #through;
                case IID_X86_AVX512_CVTTSD2USI; #through; case IID_X86_AVX512_CVTTSD2USI64;
                    return cfc_sse_convert_to_int(ek, ew, true, t, false);
            }
        }
    }
    if id == IID_EXPERIMENTAL_CTTZ_ELTS {
        vt := vtype(ops[0]);
        if type_kind(vt) != .VECTOR return NONE;
        zero_is_poison := ap_is_one(cf_ap(ops[1]));
        width := type_int_width(t);
        n := type_count(vt);
        if width < 64 && ((cast(u64) 1) << width) - 1 < n return const_poison(t);
        for i: 0..cast(s64) n - 1 {
            e := cf_elt(ops[0], cast(u64) i);
            if e == NONE return NONE;
            if cfc_is_undef(e) || is_null_value(e) continue;
            return const_int(t, cast(u64) i);
        }
        if zero_is_poison return const_poison(t);
        return const_int(t, n);
    }
    return NONE;
}

// ---------------------------------------------------------------- three operands

cfc_scalar_call3 :: (name: string, id: Intrinsic_Id, t: Type_Id, ops: [] Value_Id, call: Value_Id) -> Value_Id {
    if cfc_is_const_fp(ops[0]) && cfc_is_const_fp(ops[1]) && cfc_is_const_fp(ops[2]) {
        k := cfc_kind(vtype(ops[0]));
        a := const_fp_value(ops[0]); b := const_fp_value(ops[1]); c := const_fp_value(ops[2]);
        ci := cfc_constrained(call);
        if ci.is {
            rm := cfc_eval_rm(ci);
            if id == IID_EXPERIMENTAL_CONSTRAINED_FMA || id == IID_EXPERIMENTAL_CONSTRAINED_FMULADD {
                r, st := fp_fma(k, a, b, c, rm);
                if cfc_may_fold_constrained(ci.eb, ci.rm, ci.has_eb, st) return cfc_fp(t, r);
                return NONE;
            }
            return NONE;
        }
        if id == IID_FMA || id == IID_FMULADD {
            r, st := fp_fma(k, a, b, c, RM_NEAREST_TIES_TO_EVEN);
            return cfc_fp(t, r);
        }
    }
    if id == IID_SMUL_FIX || id == IID_SMUL_FIX_SAT {
        ok0, un0, c0 := cfc_const_int_or_undef(ops[0]);
        ok1, un1, c1 := cfc_const_int_or_undef(ops[1]);
        if !ok0 || !ok1 return NONE;
        if un0 || un1 return const_null_value(t);
        scale := cast(u32) ap_zext_value(cf_ap(ops[2]));
        width := c0.bits;
        ext := width * 2;
        product := ap_ashr(ap_mul(ap_sext(c0, ext), ap_sext(c1, ext)), scale);
        if id == IID_SMUL_FIX_SAT {
            mx := ap_sext(ap_signed_max(width), ext);
            mn := ap_sext(ap_signed_min(width), ext);
            product = ap_smin(product, mx);
            product = ap_smax(product, mn);
        }
        return cf_int(t, ap_sext_or_trunc(product, width));
    }
    if id == IID_FSHL || id == IID_FSHR {
        ok0, un0, c0 := cfc_const_int_or_undef(ops[0]);
        ok1, un1, c1 := cfc_const_int_or_undef(ops[1]);
        ok2, un2, c2 := cfc_const_int_or_undef(ops[2]);
        if !ok0 || !ok1 || !ok2 return NONE;
        is_right := id == IID_FSHR;
        if un2 return ops[ifx is_right then 1 else 0];
        if un0 && un1 return const_undef(t);
        bw := c2.bits;
        sh := cast(u32) ap_zext_value(ap_urem(c2, ap_from_u64(bw, bw)));
        if sh == 0 return ops[ifx is_right then 1 else 0];
        lshr_amt := ifx is_right then sh else bw - sh;
        shl_amt := ifx !is_right then sh else bw - sh;
        if un0 return cf_int(t, ap_lshr(c1, lshr_amt));
        if un1 return cf_int(t, ap_shl(c0, shl_amt));
        return cf_int(t, ap_or(ap_shl(c0, shl_amt), ap_lshr(c1, lshr_amt)));
    }
    return NONE;
}

// ConstantFoldScalarCall
cfc_scalar_call :: (name: string, id: Intrinsic_Id, t: Type_Id, ops: [] Value_Id, call: Value_Id) -> Value_Id {
    if id != NOT_INTRINSIC && intrinsic_propagates_poison(id) {
        for ops if vkind(it) == .C_POISON return const_poison(t);
    }
    if ops.count == 1 return cfc_scalar_call1(name, id, t, ops, call);
    if ops.count == 2 {
        c := cfc_lib_call2(name, t, ops, call);
        if c != NONE return c;
        return cfc_intrinsic_call2(id, t, ops, call);
    }
    if ops.count == 3 return cfc_scalar_call3(name, id, t, ops, call);
    return NONE;
}

// ConstantFoldFixedVectorCall
cfc_fixed_vector_call :: (name: string, id: Intrinsic_Id, vt: Type_Id, ops: [] Value_Id, call: Value_Id) -> Value_Id {
    n := cast(s64) type_count(vt);
    et := type_elem(vt);
    result := NewArray(n, Value_Id,, allocator = temp);
    if id == {
        case IID_MASKED_LOAD;
            src := ops[0]; mask := ops[1]; pass := ops[2];
            data := cfo_load_from_const_ptr(src, vt);
            elts: [..] Value_Id; elts.allocator = temp;
            for i: 0..n-1 {
                me := cf_elt(mask, cast(u64) i);
                if me == NONE break;
                pe := cf_elt(pass, cast(u64) i);
                ve := ifx data != NONE then cf_elt(data, cast(u64) i) else NONE;
                if cfc_is_undef(me) {
                    if pe != NONE array_add(*elts, pe);
                    else if ve != NONE array_add(*elts, ve);
                    else return NONE;
                    continue;
                }
                if is_null_value(me) {
                    if pe == NONE return NONE;
                    array_add(*elts, pe);
                } else if is_one_value(me) {
                    if ve == NONE return NONE;
                    array_add(*elts, ve);
                } else return NONE;
            }
            if elts.count != n return NONE;
            return cf_vector(vt, elts);
        case IID_GET_ACTIVE_LANE_MASK;
            if cfc_is_const_int(ops[0]) && cfc_is_const_int(ops[1]) {
                base := ap_zext_value(cf_ap(ops[0])); limit := ap_zext_value(cf_ap(ops[1]));
                for i: 0..n-1 result[i] = cf_bool(et, base + cast(u64) i < limit);
                return cf_vector(vt, result);
            }
            return NONE;
        case IID_VECTOR_EXTRACT;
            vec := ops[0];
            if !cfc_is_const_int(ops[1]) || type_kind(vtype(vec)) != .VECTOR return NONE;
            vn := cast(s64) type_count(vtype(vec));
            start := cast(s64) ap_zext_value(cf_ap(ops[1]));
            if n == vn && start == 0 return vec;
            for i: start..start + n - 1 {
                e := cf_elt(vec, cast(u64) i);
                if e == NONE return NONE;
                result[i - start] = e;
            }
            return cf_vector(vt, result);
        case IID_VECTOR_INSERT;
            vec := ops[0]; sub := ops[1];
            if !cfc_is_const_int(ops[2]) || type_kind(vtype(vec)) != .VECTOR return NONE;
            sn := cast(s64) type_count(vtype(sub));
            vn := cast(s64) type_count(vtype(vec));
            idx := cast(s64) ap_zext_value(cf_ap(ops[2]));
            if sn == vn && idx == 0 return sub;
            for i: 0..vn-1 {
                e: Value_Id;
                if i < idx + sn e = cf_elt(sub, cast(u64)(i - idx));   // (wraps like LLVM's unsigned I - IdxN for I < IdxN)
                else e = cf_elt(vec, cast(u64) i);
                if e == NONE return NONE;
                result[i] = e;
            }
            return cf_vector(vt, result);
        case IID_VECTOR_INTERLEAVE2; #through; case IID_VECTOR_INTERLEAVE3; #through; case IID_VECTOR_INTERLEAVE4; #through;
        case IID_VECTOR_INTERLEAVE5; #through; case IID_VECTOR_INTERLEAVE6; #through; case IID_VECTOR_INTERLEAVE7; #through;
        case IID_VECTOR_INTERLEAVE8;
            ne := cast(s64) type_count(vtype(ops[0]));
            nops_ := ops.count;
            for i: 0..ne-1 for j: 0..nops_-1 {
                e := cf_elt(ops[j], cast(u64) i);
                if e == NONE return NONE;
                result[nops_ * i + j] = e;
            }
            return cf_vector(vt, result);
    }
    lane := NewArray(ops.count, Value_Id,, allocator = temp);
    for i: 0..n-1 {
        for j: 0..ops.count-1 {
            if is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) j) { lane[j] = ops[j]; continue; }
            agg := cf_elt(ops[j], cast(u64) i);
            if agg == NONE return NONE;
            lane[j] = agg;
        }
        folded := cfc_scalar_call(name, id, et, lane, call);
        if folded == NONE return NONE;
        result[i] = folded;
    }
    return cf_vector(vt, result);
}

// ConstantFoldScalableVectorCall
cfc_scalable_vector_call :: (name: string, id: Intrinsic_Id, vt: Type_Id, ops: [] Value_Id, call: Value_Id) -> Value_Id {
    if id == {
        case IID_GET_ACTIVE_LANE_MASK;
            if cfc_is_const_int(ops[0]) && cfc_is_const_int(ops[1]) && ap_uge(cf_ap(ops[0]), cf_ap(ops[1])) return const_null_value(vt);
        case IID_VECTOR_INTERLEAVE2; #through; case IID_VECTOR_INTERLEAVE3; #through; case IID_VECTOR_INTERLEAVE4; #through;
        case IID_VECTOR_INTERLEAVE5; #through; case IID_VECTOR_INTERLEAVE6; #through; case IID_VECTOR_INTERLEAVE7; #through;
        case IID_VECTOR_INTERLEAVE8;
            s := get_splat_value(ops[0]);
            if s == NONE return NONE;
            for ops if it != ops[0] return NONE;
            return cf_get_splat(vt, s);
    }
    if !is_trivially_vectorizable(id) return NONE;
    splat_ops := NewArray(ops.count, Value_Id,, allocator = temp);
    for ops {
        if is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) it_index) { splat_ops[it_index] = it; continue; }
        s := get_splat_value(it);
        if s == NONE return NONE;
        splat_ops[it_index] = s;
    }
    folded := cfc_scalar_call(name, id, type_elem(vt), splat_ops, call);
    if folded == NONE return NONE;
    return cf_get_splat(vt, folded);
}

// ConstantFoldScalarFrexpCall
cfc_scalar_frexp :: (op_c: Value_Id, int_ty: Type_Id) -> (Value_Id, Value_Id) {
    // dyn_cast<ConstantFP>: a vector-typed ConstantFP (splat, e.g. a scalable zeroinitializer) is one too; LLVM
    // then builds { <vector mantissa>, <scalar exponent> } (sic)
    if op_c == NONE || vkind(op_c) != .C_FP return NONE, NONE;
    k := cfc_kind(vtype(op_c));
    mant, e := fp_frexp(k, const_fp_value(op_c), RM_NEAREST_TIES_TO_EVEN);
    r0 := cfc_fp(vtype(op_c), mant);
    dm := fp_decode(k, mant);
    r1: Value_Id;
    if dm.cat == .ZERO || dm.cat == .NORMAL r1 = cf_int(int_ty, ap_from_s64(type_int_width(int_ty), e));
    else r1 = const_null_value(int_ty);
    return r0, r1;
}

// ConstantFoldStructCall
cfc_struct_call :: (name: string, id: Intrinsic_Id, st: Type_Id, ops: [] Value_Id, call: Value_Id) -> Value_Id {
    if id == {
        case IID_FREXP;
            t0 := type_sub(st, 0);
            t1 := scalar_type(type_sub(st, 1));
            if type_kind(t0) == .VECTOR {
                n := cast(s64) type_count(t0);
                r0 := NewArray(n, Value_Id,, allocator = temp);
                r1 := NewArray(n, Value_Id,, allocator = temp);
                for i: 0..n-1 {
                    lane := cf_elt(ops[0], cast(u64) i);
                    a, b := cfc_scalar_frexp(lane, t1);
                    if a == NONE return NONE;
                    r0[i] = a; r1[i] = b;
                }
                elts: [2] Value_Id;
                elts[0] = cf_vector(t0, r0); elts[1] = cf_vector(type_sub(st, 1), r1);
                return const_aggregate(.C_STRUCT, st, elts);
            }
            a, b := cfc_scalar_frexp(ops[0], t1);
            if a == NONE return NONE;
            elts: [2] Value_Id; elts[0] = a; elts[1] = b;
            return const_aggregate(.C_STRUCT, st, elts);
        case IID_SINCOS;
            ty := type_sub(st, 0);
            tys := scalar_type(ty);
            sincos1 :: (name: string, tys: Type_Id, o: Value_Id, call: Value_Id) -> (Value_Id, Value_Id) {
                one: [1] Value_Id; one[0] = o;
                s := cfc_scalar_call(name, IID_SIN, tys, one, call);
                c := cfc_scalar_call(name, IID_COS, tys, one, call);
                return s, c;
            }
            if type_kind(ty) == .VECTOR {
                n := cast(s64) type_count(ty);
                sr := NewArray(n, Value_Id,, allocator = temp);
                cr := NewArray(n, Value_Id,, allocator = temp);
                for i: 0..n-1 {
                    lane := cf_elt(ops[0], cast(u64) i);
                    s, c := sincos1(name, tys, lane, call);
                    if s == NONE || c == NONE return NONE;
                    sr[i] = s; cr[i] = c;
                }
                elts: [2] Value_Id; elts[0] = cf_vector(ty, sr); elts[1] = cf_vector(ty, cr);
                return const_aggregate(.C_STRUCT, st, elts);
            }
            if !is_fp_type(ty) return NONE;
            s, c := sincos1(name, tys, ops[0], call);
            if s == NONE || c == NONE return NONE;
            elts: [2] Value_Id; elts[0] = s; elts[1] = c;
            return const_aggregate(.C_STRUCT, st, elts);
        case IID_VECTOR_DEINTERLEAVE2; #through; case IID_VECTOR_DEINTERLEAVE3; #through; case IID_VECTOR_DEINTERLEAVE4; #through;
        case IID_VECTOR_DEINTERLEAVE5; #through; case IID_VECTOR_DEINTERLEAVE6; #through; case IID_VECTOR_DEINTERLEAVE7; #through;
        case IID_VECTOR_DEINTERLEAVE8;
            nres := cast(s64) type_nsub(st);
            vec := ops[0];
            rt := type_sub(st, 0);
            results := NewArray(nres, Value_Id,, allocator = temp);
            s := get_splat_value(vec);
            if s != NONE {
                rv := cf_get_splat(rt, s);
                for * results it.* = rv;
                return const_aggregate(.C_STRUCT, st, results);
            }
            if type_kind(rt) != .VECTOR return NONE;
            ne := cast(s64) type_count(rt);
            for i: 0..nres-1 {
                elts := NewArray(ne, Value_Id,, allocator = temp);
                for j: 0..ne-1 {
                    e := cf_elt(vec, cast(u64)(j * nres + i));
                    if e == NONE return NONE;
                    elts[j] = e;
                }
                results[i] = cf_vector(rt, elts);
            }
            return const_aggregate(.C_STRUCT, st, results);
    }
    return cfc_scalar_call(name, id, st, ops, call);
}

// ConstantFoldCall (TLI always present: opt's InstSimplify / InstCombine pass one)
cfo_call :: (call: Value_Id, f: Value_Id, ops: [] Value_Id, allow_non_deterministic := true) -> Value_Id {
    if call_is_no_builtin(call) return NONE;
    if vname(f).count == 0 return NONE;
    id := fn_iid(f);
    if id == NOT_INTRINSIC {
        if !tli_get_lib_func(vname(f)) return NONE;
        if !tli_valid_proto(glob(f).value_type, vname(f)) return NONE;
    }
    t := func_ret(glob(f).value_type);
    if !allow_non_deterministic && is_fp_type(scalar_type(t)) return NONE;
    name := vname(f);
    tk := type_kind(t);
    if tk == .VECTOR return cfc_fixed_vector_call(name, id, t, ops, call);
    if tk == .SVECTOR return cfc_scalable_vector_call(name, id, t, ops, call);
    if tk == .STRUCT return cfc_struct_call(name, id, t, ops, call);
    return cfc_scalar_call(name, id, t, ops, call);
}

// ConstantFoldIntrinsic (no call site, no TLI)
cfo_intrinsic :: (id: Intrinsic_Id, ops: [] Value_Id, t: Type_Id) -> Value_Id {
    return cfc_scalar_call("", id, t, ops, NONE);
}
