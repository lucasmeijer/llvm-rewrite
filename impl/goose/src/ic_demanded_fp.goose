// SimplifyDemandedFPClass: port of the floating-point half of
// llvm/lib/Transforms/InstCombine/InstCombineSimplifyDemanded.cpp (getFPClassConstant,
// simplifyDemandedFPClassFabs, inferFastMathValueFlags, adjustDemandedMaskFromFlags,
// simplifyDemandedFPClassResult, simplifyDemandedFPClassFnegFabs, simplifyDemandedFPClassCopysignMag,
// simplifyDemandedFPClassMinMax, simplifyDemandedUseFPClassFPTrunc, SimplifyDemandedUseFPClass,
// SimplifyMultipleUseDemandedFPClass, SimplifyDemandedFPClass, SimplifyDemandedInstructionFPClass) and
// cannotOrderStrictlyGreater/Less (llvm/lib/Support/FloatingPointMode.cpp).
//
// The SimplifyQuery's context instruction is the parameter `cx` (set into kb_cxt before every ValueTracking call).
// Known (the KnownFPClass output parameter) is the second return value.
namespace ic;
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import constfold;
import cfold;
import pm;
import vt;
import poison;
import knownbits;
import fpclass;
import apint;
import apfloat;
import fpu;
import ic;
import ic_builder;
import ic_common;
import ic_fp_addsub;

let MAX_RECURSION_DEPTH_FP: i64 = 6;

// cannotOrderStrictlyGreaterImpl(LHS, RHS, OrEqual, OrderedZero)
fn fcl_cannot_order_strictly_greater_impl(l0: u64, r0: u64, or_equal: bool, ordered_zero: bool) -> bool {
    let l = l0 & ~FCL_NAN & FCL_ALL;
    let r = r0 & ~FCL_NAN & FCL_ALL;
    if l == 0 || r == 0 { return true; }
    var low_r = r & (0 - r);
    var hb: i64 = 63;
    while ((l >> hb) & 1) == 0 { hb--; }
    var high_l = (1 as u64) << hb;
    if !ordered_zero {
        if low_r == FCL_NEG_ZERO { low_r = FCL_POS_ZERO; }
        if high_l == FCL_NEG_ZERO { high_l = FCL_POS_ZERO; }
    }
    if low_r > high_l { return true; }
    if low_r < high_l { return false; }
    return !or_equal && (low_r & (FCL_ZERO | FCL_INF)) != 0;
}
fn fcl_cannot_order_strictly_greater(l: u64, r: u64, oz: bool) -> bool { fcl_cannot_order_strictly_greater_impl(l, r, false, oz) }
fn fcl_cannot_order_strictly_less(l: u64, r: u64, oz: bool) -> bool { fcl_cannot_order_strictly_greater_impl(r, l, false, oz) }

fn is_ieee_like_fp_kind(k: i64) -> bool { k == TK_HALF || k == TK_BFLOAT || k == TK_FLOAT || k == TK_DOUBLE || k == TK_FP128 }
fn fn_mode_of(ty: i32) -> i64 { fn_denormal_mode(ic_fn, ty_scalar(ty)) }
fn dm_inputs_may_be_zero(m: i64) -> bool { dm_inputs_are_zero(m) || dm_in(m) == DMK_DYN }
fn dm_inputs_may_be_pos_zero(m: i64) -> bool { dm_in(m) == DMK_PZ || dm_in(m) == DMK_DYN }
fn dm_outputs_may_be_pos_zero(m: i64) -> bool { dm_out(m) == DMK_PZ || dm_out(m) == DMK_DYN }

fn kfc_cfp(v: i32, interested: u64, cx: i32, depth: i64) -> KFC { kb_cxt = cx; return kfc_compute_all(v, interested, depth); }

// getFPClassConstant(Ty, Mask, IsCanonicalizing)
fn get_fp_class_constant(ty: i32, mask: u64, canon: bool) -> i32 {
    if mask == 0 { return c_poison(ty); }
    if mask == FCL_POS_ZERO { return c_null(ty); }
    if ty_is_struct(ty) || ty_is_array(ty) { return -1; }
    if mask == FCL_NAN && canon { return c_fp_qnan_ty(ty); }
    if mask == FCL_NEG_ZERO { return c_fp_zero_ty(ty, true); }
    if mask == FCL_POS_INF { return c_fp_inf_ty(ty, false); }
    if mask == FCL_NEG_INF { return c_fp_inf_ty(ty, true); }
    if mask == FCL_QNAN { return if canon { c_fp_qnan_ty(ty) } else { -1 }; }
    return -1;
}

// simplifyDemandedFPClassFabs(Known, Src, DemandedMask, KnownSrc, NSZ): replacement or -1, Known
fn sdfc_fabs(known: KFC, src: i32, demanded: u64, ks0: KFC, nsz: bool) -> i32, KFC {
    var ks = ks0;
    if (demanded & FCL_NAN) == 0 { ks = kfc_known_not(ks, FCL_NAN); }
    if (demanded & FCL_INF) == 0 { ks = kfc_known_not(ks, FCL_INF); }
    if ks.sign == 0 || ((demanded & FCL_NAN) == 0 && kfc_never(ks, FCL_NEGATIVE)) { return src, known; }
    if nsz && kfc_never(ks, FCL_ORDERED_LT_ZERO_MASK | FCL_NAN) { return src, known; }
    let k = kfc_known_not(kfc_fabs(ks), fcl_not(demanded));
    return -1, k;
}

// inferFastMathValueFlags(FMF, ValidResults, Known)
fn infer_fmf_value_flags(fmf0: u8, valid: u64, k0: KFC, k1: KFC, k2: KFC, n: i64) -> u8 {
    var fmf = fmf0;
    if (fmf & FMF_NNAN) == 0 && (valid & FCL_NAN) == 0 {
        var all = kfc_never_nan(k0);
        if n > 1 && !kfc_never_nan(k1) { all = false; }
        if n > 2 && !kfc_never_nan(k2) { all = false; }
        if all { fmf |= FMF_NNAN; }
    }
    if (fmf & FMF_NINF) == 0 && (valid & FCL_INF) == 0 {
        var all = kfc_never_inf(k0);
        if n > 1 && !kfc_never_inf(k1) { all = false; }
        if n > 2 && !kfc_never_inf(k2) { all = false; }
        if all { fmf |= FMF_NINF; }
    }
    return fmf;
}

// adjustDemandedMaskFromFlags(DemandedMask, FMF)
fn adjust_demanded_mask_from_flags(m0: u64, fmf: u8) -> u64 {
    var m = m0;
    if (fmf & FMF_NNAN) != 0 { m &= ~FCL_NAN; }
    if (fmf & FMF_NINF) != 0 { m &= ~FCL_INF; }
    return m;
}

// simplifyDemandedFPClassResult(FPOp, FMF, DemandedMask, Known, KnownSrcs)
fn sdfc_result(fpop: i32, fmf: u8, demanded: u64, known: KFC, k0: KFC, k1: KFC, k2: KFC, n: i64) -> i32 {
    let valid = demanded & known.known;
    let sv = get_fp_class_constant(vals[fpop].ty, valid, true);
    if sv >= 0 { return sv; }
    let inf = infer_fmf_value_flags(fmf, valid, k0, k1, k2, n);
    if inf != fmf {
        drop_ub_implying_attrs_and_md(fpop);
        set_fmf(fpop, fmf_of(fpop) | inf);
        return fpop;
    }
    return -1;
}

// simplifyDemandedFPClassFnegFabs
fn sdfc_fneg_fabs(known: KFC, src: i32, demanded: u64, ks0: KFC, nsz: bool) -> i32, KFC {
    var ks = ks0;
    if (demanded & FCL_NAN) == 0 { ks = kfc_known_not(ks, FCL_NAN); }
    if (demanded & FCL_INF) == 0 { ks = kfc_known_not(ks, FCL_INF); }
    if ks.sign == 1 { return src, known; }
    if nsz && kfc_never(ks, FCL_ORDERED_GT_ZERO_MASK | FCL_NAN) { return src, known; }
    let k = kfc_known_not(kfc_fneg(kfc_fabs(ks)), fcl_not(demanded));
    return -1, k;
}

// simplifyDemandedFPClassCopysignMag
fn sdfc_copysign_mag(mag: i32, demanded: u64, ks: KFC, nsz: bool) -> i32 {
    if nsz {
        let neg_or_zero = FCL_NEGATIVE | FCL_POS_ZERO;
        let pos_or_zero = FCL_POSITIVE | FCL_NEG_ZERO;
        if (demanded & ~neg_or_zero) == 0 && kfc_always(ks, neg_or_zero) { return mag; }
        if (demanded & ~pos_or_zero) == 0 && kfc_always(ks, pos_or_zero) { return mag; }
    } else {
        if (demanded & ~FCL_NEGATIVE) == 0 && ks.sign == 1 { return mag; }
        if (demanded & ~FCL_POSITIVE) == 0 && ks.sign == 0 { return mag; }
    }
    return -1;
}

// simplifyDemandedFPClassMinMax
fn sdfc_minmax(known: KFC, id: i32, ci: i32, demanded: u64, kl: KFC, kr: KFC, nsz: bool) -> i32, KFC {
    let oz = !nsz;
    var kind: i64 = 0;
    let l = kl.known;
    let r = kr.known;
    if id == IID_maximum {
        kind = MMK_MAXIMUM;
        if fcl_cannot_order_strictly_less(l, r, oz) && kfc_never(kr, FCL_NAN) { return op(ci, 0), known; }
        if fcl_cannot_order_strictly_greater(l, r, oz) && kfc_never(kl, FCL_NAN) { return op(ci, 1), known; }
    } else if id == IID_minimum {
        kind = MMK_MINIMUM;
        if fcl_cannot_order_strictly_greater(l, r, oz) && kfc_never(kr, FCL_NAN) { return op(ci, 0), known; }
        if fcl_cannot_order_strictly_less(l, r, oz) && kfc_never(kl, FCL_NAN) { return op(ci, 1), known; }
    } else if id == IID_maxnum || id == IID_maximumnum {
        kind = if id == IID_maxnum { MMK_MAXNUM } else { MMK_MAXIMUMNUM };
        if fcl_cannot_order_strictly_less(l, r, oz) && kfc_never(kl, FCL_NAN) { return op(ci, 0), known; }
        if fcl_cannot_order_strictly_greater(l, r, oz) && kfc_never(kr, FCL_NAN) { return op(ci, 1), known; }
    } else {
        kind = if id == IID_minnum { MMK_MINNUM } else { MMK_MINIMUMNUM };
        if fcl_cannot_order_strictly_greater(l, r, oz) && kfc_never(kl, FCL_NAN) { return op(ci, 0), known; }
        if fcl_cannot_order_strictly_less(l, r, oz) && kfc_never(kr, FCL_NAN) { return op(ci, 1), known; }
    }
    let mode = fn_mode_of(vals[ci].ty);
    let k = kfc_known_not(kfc_min_max_like(kl, kr, kind, mode), fcl_not(demanded));
    return get_fp_class_constant(vals[ci].ty, k.known, true), k;
}

// simplifyDemandedUseFPClassFPTrunc (fptrunc and llvm.fptrunc.round)
recursive fn sdfc_fptrunc(i: i32, fmf: u8, demanded: u64, cx: i32, depth: i64) -> i32, KFC {
    var sm = demanded;
    if (demanded & FCL_NAN) != 0 { sm |= FCL_NAN; }
    if (demanded & FCL_NEG_ZERO) != 0 { sm |= FCL_NEG_SUBNORMAL | FCL_NEG_NORMAL; }
    if (demanded & FCL_POS_ZERO) != 0 { sm |= FCL_POS_SUBNORMAL | FCL_POS_NORMAL; }
    if (demanded & FCL_NEG_SUBNORMAL) != 0 { sm |= FCL_NEG_NORMAL; }
    if (demanded & FCL_POS_SUBNORMAL) != 0 { sm |= FCL_POS_NORMAL; }
    if (demanded & FCL_POS_INF) != 0 { sm |= FCL_POS_NORMAL; }
    if (demanded & FCL_NEG_INF) != 0 { sm |= FCL_NEG_NORMAL; }
    let ch, ks = sd_fp_class(i, 0, sm, cx, depth + 1);
    if ch { return i, kfc_unknown(); }
    let k = kfc_known_not(kfc_fptrunc(ks), fcl_not(demanded));
    return sdfc_result(i, fmf, demanded, k, ks, ks, ks, 1), k;
}

// Builder InsertPointGuard + SetInsertPoint(I)
var sdf_saved_pos: i32 = -1;
var sdf_saved_bb: i32 = -1;
var sdf_saved_dl: i32 = -1;
fn sdf_guard_begin(i: i32) { sdf_saved_pos = icb_pos; sdf_saved_bb = icb_bb; sdf_saved_dl = icb_dl; icb_set_insert_point(i); }
fn sdf_guard_end() { icb_pos = sdf_saved_pos; icb_bb = sdf_saved_bb; icb_dl = sdf_saved_dl; }
// Builder.CreateSelectFMFWithUnknownProfile(C, T, F, FMF, "instcombine")
fn icb_select_fmf_unknown_prof(c: i32, t: i32, f: i32, fmf: u8) -> i32 {
    let saved = icb_fmf;
    icb_fmf = fmf;
    let s = icb_select(c, t, f, "", -1);
    icb_fmf = saved;
    if is_select_inst(s) { ic_set_unknown_branch_weights_if_profiled(s); }
    return s;
}

// SimplifyDemandedUseFPClass(I, DemandedMask, Known, SQ, Depth)
recursive fn sd_use_fp_class(i: i32, demanded0: u64, cx: i32, depth: i64) -> i32, KFC {
    let vty = vals[i].ty;
    var demanded = demanded0;
    var fmf: u8 = 0;
    if is_fp_math_operator(i) {
        fmf = fmf_of(i);
        demanded = adjust_demanded_mask_from_flags(demanded, fmf);
    }
    var known = kfc_unknown();
    let o = iop(i);
    if o == OP_FNEG {
        let src = op(i, 0);
        if one_use(src) && is_intr(src, IID_fabs) {
            let ffs = op(src, 0);
            let ch, ks0 = sd_fp_class(src, 0, fcl_unknown_sign(demanded), cx, depth + 1);
            if ch { return i, known; }
            let ffmf = fmf_of(src);
            let tdm = adjust_demanded_mask_from_flags(demanded, ffmf);
            let is_nsz = (fmf & FMF_NSZ) != 0 || (ffmf & FMF_NSZ) != 0;
            let sv, k2 = sdfc_fneg_fabs(known, ffs, tdm, ks0, is_nsz);
            if sv >= 0 { return sv, k2; }
            known = k2;
            var ks = ks0;
            if (tdm & FCL_NAN) == 0 { ks = kfc_known_not(ks, FCL_NAN); }
            if (tdm & FCL_INF) == 0 { ks = kfc_known_not(ks, FCL_INF); }
            if ks.sign == 0 { return ic_replace_operand(i, 0, ffs), known; }
            if is_nsz && kfc_never(ks, FCL_ORDERED_LT_ZERO_MASK | FCL_NAN) { return ic_replace_operand(i, 0, ffs), known; }
        } else {
            let ch, k = sd_fp_class(i, 0, fcl_fneg(demanded), cx, depth + 1);
            if ch { return i, k; }
            known = kfc_known_not(kfc_fneg(k), fcl_not(demanded));
        }
    } else if o == OP_FADD || o == OP_FSUB {
        var kl = kfc_unknown();
        var kr = kfc_unknown();
        kb_cxt = cx;
        if op(i, 0) == op(i, 1) && o == OP_FADD && is_guaranteed_not_to_be_undef(op(i, 0), cx, depth + 1) {
            let mode = fn_mode_of(vty);
            var sm = demanded;
            if (demanded & FCL_NAN) != 0 { sm |= FCL_NAN; }
            if (demanded & FCL_POS_NORMAL) != 0 { sm |= FCL_POS_SUBNORMAL; }
            if (demanded & FCL_NEG_NORMAL) != 0 { sm |= FCL_NEG_SUBNORMAL; }
            if mode != DM_IEEE {
                if (demanded & FCL_POS_ZERO) != 0 {
                    sm |= FCL_POS_SUBNORMAL;
                    if dm_inputs_may_be_pos_zero(mode) || dm_outputs_may_be_pos_zero(mode) { sm |= FCL_NEG_SUBNORMAL; }
                }
                if (demanded & FCL_NEG_ZERO) != 0 { sm |= FCL_NEG_SUBNORMAL; }
            }
            if (demanded & FCL_POS_INF) != 0 { sm |= FCL_POS_NORMAL; }
            if (demanded & FCL_NEG_INF) != 0 { sm |= FCL_NEG_NORMAL; }
            let ch, k = sd_fp_class(i, 0, sm, cx, depth + 1);
            if ch { return i, k; }
            kl = k;
            known = kfc_fadd_self(kl, mode);
            kr = kl;
        } else {
            var sm = FCL_FINITE;
            if (demanded & FCL_NAN) != 0 { sm |= FCL_NAN | FCL_INF; }
            if (demanded & FCL_INF) != 0 { sm |= FCL_INF; }
            let ch1, k1 = sd_fp_class(i, 1, sm, cx, depth + 1);
            if ch1 { return i, k1; }
            kr = k1;
            let ch0, k0 = sd_fp_class(i, 0, sm, cx, depth + 1);
            if ch0 { return i, k0; }
            kl = k0;
            let mode = fn_mode_of(vty);
            known = if o == OP_FADD { kfc_fadd(kl, kr, mode) } else { kfc_fsub(kl, kr, mode) };
        }
        known = kfc_known_not(known, fcl_not(demanded));
        let sv = get_fp_class_constant(vty, known.known, true);
        if sv >= 0 { return sv, known; }
        let not_nan = (demanded & FCL_NAN) == 0;
        if not_nan && o == OP_FADD && kfc_always(kr, FCL_INF | FCL_NAN) && kfc_never(kl, FCL_NAN) { return op(i, 1), known; }
        if not_nan && kfc_always(kl, FCL_INF | FCL_NAN) && kfc_never(kr, FCL_NAN) { return op(i, 0), known; }
        let inf = infer_fmf_value_flags(fmf, known.known, kl, kr, kr, 2);
        if inf != fmf { set_fmf(i, fmf_of(i) | inf); return i, known; }
        return -1, known;
    } else if o == OP_FMUL {
        var kl = kfc_unknown();
        var kr = kfc_unknown();
        let x = op(i, 0);
        let y = op(i, 1);
        var sm = demanded & (FCL_NAN | FCL_ZERO | FCL_SUBNORMAL | FCL_NORMAL);
        if (demanded & FCL_INF) != 0 { sm |= FCL_SUBNORMAL | FCL_NORMAL | FCL_INF; }
        if (demanded & FCL_NAN) != 0 { sm |= FCL_ZERO | FCL_INF | FCL_NAN; sm |= FCL_SUBNORMAL; }
        if (demanded & (FCL_NORMAL | FCL_SUBNORMAL)) != 0 { sm |= FCL_NORMAL | FCL_SUBNORMAL; }
        if (demanded & FCL_ZERO) != 0 { sm |= FCL_NORMAL | FCL_SUBNORMAL; }
        kb_cxt = cx;
        if x == y && is_guaranteed_not_to_be_undef(x, cx, depth + 1) {
            let ch, k = sd_fp_class(i, 0, sm, cx, depth + 1);
            if ch { return i, k; }
            kl = k;
            let mode = fn_mode_of(vty);
            known = kfc_known_not(kfc_square(kl, mode), fcl_not(demanded));
            let fo = get_fp_class_constant(vty, known.known, true);
            if fo >= 0 { return fo, known; }
            if kfc_always(known, FCL_POS_ZERO | FCL_POS_INF | FCL_NAN) && kfc_never(kl, FCL_SUBNORMAL | FCL_NORMAL) {
                if kfc_always(kl, FCL_POSITIVE) { return x, known; }
                sdf_guard_begin(i);
                let fa = icb_unary_intrinsic_fmf(IID_fabs, x, fmf, "");
                ic_take_name(fa, i);
                sdf_guard_end();
                return fa, known;
            }
            return -1, known;
        }
        let ch1, k1 = sd_fp_class(i, 1, sm, cx, depth + 1);
        if ch1 { return i, k1; }
        kr = k1;
        let ch0, k0 = sd_fp_class(i, 0, sm, cx, depth + 1);
        if ch0 { return i, k0; }
        kl = k0;
        if (fmf & FMF_NINF) != 0 { kl = kfc_known_not(kl, FCL_INF); kr = kfc_known_not(kr, FCL_INF); }
        let non_nan = (demanded & FCL_NAN) == 0;
        if (non_nan || kfc_never_inf_or_nan(kl)) && kfc_always(kr, FCL_POS_ZERO | FCL_NAN) {
            sdf_guard_begin(i);
            let cs = icb_binary_intrinsic_fmf(IID_copysign, y, x, fmf, "");
            ic_take_name(cs, i);
            sdf_guard_end();
            return cs, known;
        }
        if kfc_always(kl, FCL_POS_ZERO | FCL_NAN) && (non_nan || kfc_never_inf_or_nan(kr)) {
            sdf_guard_begin(i);
            let cs = icb_binary_intrinsic_fmf(IID_copysign, x, y, fmf, "");
            ic_take_name(cs, i);
            sdf_guard_end();
            return cs, known;
        }
        if (non_nan || kfc_never_inf_or_nan(kl)) && kfc_always(kr, FCL_NEG_ZERO | FCL_NAN) {
            sdf_guard_begin(i);
            let nx = icb_fneg_fmf(x, fmf, "");
            let cs = icb_binary_intrinsic_fmf(IID_copysign, y, nx, fmf, "");
            ic_take_name(cs, i);
            sdf_guard_end();
            return cs, known;
        }
        if kfc_always(kl, FCL_NEG_ZERO | FCL_NAN) && (non_nan || kfc_never_inf_or_nan(kr)) {
            sdf_guard_begin(i);
            let ny = icb_fneg_fmf(y, fmf, "");
            let cs = icb_binary_intrinsic_fmf(IID_copysign, x, ny, fmf, "");
            ic_take_name(cs, i);
            sdf_guard_end();
            return cs, known;
        }
        let mode = fn_mode_of(vty);
        if kfc_always(kl, FCL_INF | FCL_NAN) && (kfc_never_nan(kr) && kfc_cannot_be_ordered_ge_zero(kr, mode)) {
            sdf_guard_begin(i);
            let ng = icb_fneg_fmf(x, fmf, "");
            ic_take_name(ng, i);
            sdf_guard_end();
            return ng, known;
        }
        if kfc_always(kr, FCL_INF | FCL_NAN) && (kfc_never_nan(kl) && kfc_cannot_be_ordered_ge_zero(kl, mode)) {
            sdf_guard_begin(i);
            let ng = icb_fneg_fmf(y, fmf, "");
            ic_take_name(ng, i);
            sdf_guard_end();
            return ng, known;
        }
        known = kfc_known_not(kfc_fmul(kl, kr, mode), fcl_not(demanded));
        let sv = get_fp_class_constant(vty, known.known, true);
        if sv >= 0 { return sv, known; }
        let inf = infer_fmf_value_flags(fmf, known.known, kl, kr, kr, 2);
        if inf != fmf { set_fmf(i, fmf_of(i) | inf); return i, known; }
        return -1, known;
    } else if o == OP_FDIV {
        let x = op(i, 0);
        let y = op(i, 1);
        kb_cxt = cx;
        if x == y && is_guaranteed_not_to_be_undef(x, cx, depth + 1) {
            sdf_guard_begin(i);
            let izn = icb_fcmp_fmf(9 /* FCMP_UEQ */, x, c_fp_zero_ty(vty, false), fmf, "");
            let fa = icb_unary_intrinsic_fmf(IID_fabs, x, fmf, "");
            let iin = icb_fcmp_fmf(9 /* FCMP_UEQ */, fa, c_fp_inf_ty(vty, false), fmf, "");
            let any = icb_or(iin, izn, "");
            let r = icb_select_fmf_unknown_prof(any, c_fp_qnan_ty(vty), c_fpd(vty, 1.0), fmf);
            sdf_guard_end();
            return r, known;
        }
        let mode = fn_mode_of(vty);
        var sm = (demanded & FCL_NAN) | FCL_SUBNORMAL;
        if (demanded & (FCL_SUBNORMAL | FCL_NORMAL)) != 0 { sm |= FCL_NORMAL; }
        if (demanded & FCL_NAN) != 0 { sm |= FCL_ZERO | FCL_INF | FCL_NAN; }
        if (demanded & FCL_ZERO) != 0 { sm |= FCL_NORMAL | FCL_SUBNORMAL; }
        var lm = sm;
        var rm = sm;
        if (demanded & FCL_ZERO) != 0 { lm |= FCL_ZERO; rm |= FCL_INF; }
        if (demanded & FCL_INF) != 0 { lm |= FCL_INF | FCL_NORMAL | FCL_SUBNORMAL; rm |= FCL_ZERO | FCL_SUBNORMAL | FCL_NORMAL; }
        let ch0, kl = sd_fp_class(i, 0, lm, cx, depth + 1);
        if ch0 { return i, kl; }
        let ch1, kr = sd_fp_class(i, 1, rm, cx, depth + 1);
        if ch1 { return i, kr; }
        if (fmf & FMF_NSZ) != 0 && kfc_always(kl, FCL_ZERO) && kfc_never_nan(kr) { return c_fp_zero_ty(vty, false), known; }
        if kfc_always(kl, FCL_POS_ZERO) && kfc_never_nan(kr) {
            sdf_guard_begin(i);
            let cs = icb_binary_intrinsic_fmf(IID_copysign, x, y, fmf, "");
            ic_take_name(cs, i);
            sdf_guard_end();
            return cs, known;
        }
        let not_nan = (demanded & FCL_NAN) == 0;
        let not_inf = (demanded & FCL_INF) == 0;
        if !not_inf && ((not_nan || (kfc_never_nan(kl) && kfc_never_logical_zero(kl, mode))) &&
                        (kfc_always(kr, FCL_POS_ZERO) || ((fmf & FMF_NSZ) != 0 && kfc_always(kr, FCL_ZERO)))) {
            sdf_guard_begin(i);
            let cs = icb_binary_intrinsic_fmf(IID_copysign, c_fp_inf_ty(vty, false), x, fmf, "");
            ic_take_name(cs, i);
            sdf_guard_end();
            return cs, known;
        }
        if not_nan && not_inf && kfc_always(kr, FCL_ZERO) { return c_poison(vty), known; }
        known = kfc_known_not(kfc_fdiv(kl, kr, mode), fcl_not(demanded));
        let sv = get_fp_class_constant(vty, known.known, true);
        if sv >= 0 { return sv, known; }
        let inf = infer_fmf_value_flags(fmf, known.known, kl, kr, kr, 2);
        if inf != fmf { set_fmf(i, fmf_of(i) | inf); return i, known; }
        return -1, known;
    } else if o == OP_FPTRUNC {
        let r, k = sdfc_fptrunc(i, fmf, demanded, cx, depth);
        return r, k;
    } else if o == OP_FPEXT {
        var sm = demanded;
        if (demanded & FCL_NAN) != 0 { sm |= FCL_NAN; }
        if (demanded & FCL_NEG_NORMAL) != 0 { sm |= FCL_NEG_SUBNORMAL; }
        if (demanded & FCL_POS_NORMAL) != 0 { sm |= FCL_POS_SUBNORMAL; }
        let ch, ks = sd_fp_class(i, 0, sm, cx, depth + 1);
        if ch { return i, ks; }
        known = kfc_known_not(kfc_fpext(ks, fp_ty_kind(vty), fp_ty_kind(vals[op(i, 0)].ty)), fcl_not(demanded));
        return sdfc_result(i, fmf, demanded, known, ks, ks, ks, 1), known;
    } else if o == OP_CALL {
        let id = inst_iid(i);
        if id == IID_fabs {
            let ch, ks = sd_fp_class(i, 0, fcl_inverse_fabs(demanded), cx, depth + 1);
            if ch { return i, ks; }
            let sv, k = sdfc_fabs(known, op(i, 0), demanded, ks, (fmf & FMF_NSZ) != 0);
            if sv >= 0 { return sv, k; }
            known = k;
        } else if id == IID_arithmetic_fence {
            let ch, k = sd_fp_class(i, 0, demanded, cx, depth + 1);
            if ch { return i, k; }
            known = k;
        } else if id == IID_copysign {
            let any_sign = fcl_unknown_sign(demanded);
            let ch, km = sd_fp_class(i, 0, any_sign, cx, depth + 1);
            if ch { return i, km; }
            if (demanded & FCL_NEGATIVE) == demanded { set_op(i, 1, c_fpd(vty, -1.0)); return i, known; }
            if (demanded & FCL_POSITIVE) == demanded { set_op(i, 1, c_fp_zero_ty(vty, false)); return i, known; }
            let sm = sdfc_copysign_mag(op(i, 0), demanded, km, (fmf & FMF_NSZ) != 0);
            if sm >= 0 { return sm, known; }
            var ksg = kfc_cfp(op(i, 1), FCL_ALL, cx, depth + 1);
            if km.sign >= 0 && ksg.sign >= 0 && km.sign == ksg.sign { return op(i, 0), known; }
            if (fmf & FMF_NNAN) != 0 { ksg = kfc_known_not(ksg, FCL_NAN); }
            if ksg.sign == 0 {
                drop_ub_implying_attrs_and_md(i);
                set_op(i, 1, c_fp_zero_ty(vty, false));
                return i, known;
            }
            if ksg.sign == 1 {
                drop_ub_implying_attrs_and_md(i);
                set_op(i, 1, c_fpd(vty, -1.0));
                return i, known;
            }
            known = kfc_known_not(kfc_copysign(km, ksg), fcl_not(demanded));
        } else if id == IID_fma || id == IID_fmuladd {
            var sm = demanded | fcl_not(FCL_NAN);
            if (demanded & FCL_NAN) != 0 { sm |= FCL_NAN; }
            let mode = fn_mode_of(vty);
            kb_cxt = cx;
            if op(i, 0) == op(i, 1) && is_guaranteed_not_to_be_undef(op(i, 0), cx, depth + 1) {
                let ch0, k0 = sd_fp_class(i, 0, sm, cx, depth + 1);
                if ch0 { return i, k0; }
                let ch2, k2 = sd_fp_class(i, 2, sm, cx, depth + 1);
                if ch2 { return i, k2; }
                known = kfc_fma_square(k0, k2, mode);
                return sdfc_result(i, fmf, demanded, known, k0, k0, k2, 3), known;
            }
            let ch0, k0 = sd_fp_class(i, 0, sm, cx, depth + 1);
            if ch0 { return i, k0; }
            let ch1, k1 = sd_fp_class(i, 1, sm, cx, depth + 1);
            if ch1 { return i, k1; }
            let ch2, k2 = sd_fp_class(i, 2, sm, cx, depth + 1);
            if ch2 { return i, k2; }
            known = kfc_fma(k0, k1, k2, mode);
            return sdfc_result(i, fmf, demanded, known, k0, k1, k2, 3), known;
        } else if id == IID_maximum || id == IID_minimum || id == IID_maximumnum || id == IID_minimumnum || id == IID_maxnum || id == IID_minnum {
            let prop_nan = id == IID_maximum || id == IID_minimum;
            let sm = if prop_nan && (demanded & FCL_NAN) == 0 { demanded | fcl_not(FCL_NAN) } else { FCL_ALL };
            let ch1, kr = sd_fp_class(i, 1, sm, cx, depth + 1);
            if ch1 { return i, kr; }
            let ch0, kl = sd_fp_class(i, 0, sm, cx, depth + 1);
            if ch0 { return i, kl; }
            let sv, k = sdfc_minmax(known, id, i, demanded, kl, kr, (fmf & FMF_NSZ) != 0);
            if sv >= 0 { return sv, k; }
            known = k;
            let valid = demanded & known.known;
            var inf = fmf;
            if (fmf & FMF_NSZ) == 0 {
                var zm = FCL_ZERO;
                let mode = fn_mode_of(vty);
                if mode != DM_IEEE { zm |= FCL_SUBNORMAL; }
                let not_l0 = (valid & zm) == 0;
                if not_l0 || ((kfc_never_logical_neg_zero(kl, mode) || kfc_never_logical_pos_zero(kr, mode)) &&
                              (kfc_never_logical_pos_zero(kl, mode) || kfc_never_logical_neg_zero(kr, mode))) {
                    inf |= FMF_NSZ;
                }
            }
            if (fmf & FMF_NNAN) == 0 && ((prop_nan && (valid & FCL_NAN) == 0) || (kfc_never_nan(kl) && kfc_never_nan(kr))) {
                drop_ub_implying_attrs_and_md(i);
                inf |= FMF_NNAN;
            }
            if inf != fmf { set_fmf(i, fmf_of(i) | inf); return i, known; }
            return -1, known;
        } else if id == IID_exp || id == IID_exp2 || id == IID_exp10 {
            if (demanded & FCL_POSITIVE) == 0 {
                if (demanded & FCL_NAN) == 0 { return c_poison(vty), known; }
                if (demanded & ~FCL_NAN) == 0 { return c_fp_qnan_ty(vty), known; }
                return op(i, 0), known;
            }
            var sm = demanded & FCL_NAN;
            if (demanded & FCL_NAN) != 0 { sm |= FCL_NAN; }
            if (demanded & FCL_ZERO) != 0 { sm |= FCL_NEG_INF; sm |= FCL_NEG_NORMAL; }
            if (demanded & FCL_POS_SUBNORMAL) != 0 { sm |= FCL_NEG_NORMAL; }
            if (demanded & FCL_POS_NORMAL) != 0 { sm |= FCL_NORMAL | FCL_SUBNORMAL | FCL_ZERO; }
            if (demanded & FCL_POS_INF) != 0 { sm |= FCL_POS_INF | FCL_POS_NORMAL; }
            let ch, ks = sd_fp_class(i, 0, sm, cx, depth + 1);
            if ch { return i, ks; }
            if kfc_always(ks, FCL_ZERO) { return c_fpd(vty, 1.0), known; }
            if kfc_always(ks, FCL_NAN) { return op(i, 0), known; }
            if kfc_always(ks, FCL_ZERO | FCL_NAN) {
                sdf_guard_begin(i);
                let r = icb_fbinop_fmf(OP_FADD, op(i, 0), c_fpd(vty, 1.0), fmf, "");
                sdf_guard_end();
                return r, known;
            }
            if kfc_always(ks, FCL_INF | FCL_NAN) {
                sdf_guard_begin(i);
                let x = op(i, 0);
                let ipn = icb_fcmp_fmf(9 /* FCMP_UEQ */, x, c_fp_inf_ty(vty, false), fmf, "");
                let r = icb_select_fmf_unknown_prof(ipn, x, c_fp_zero_ty(vty, false), fmf);
                sdf_guard_end();
                return r, known;
            }
            known = kfc_known_not(kfc_exp(ks), fcl_not(demanded));
            return sdfc_result(i, fmf, demanded, known, ks, ks, ks, 1), known;
        } else if id == IID_log || id == IID_log2 || id == IID_log10 {
            var sm = demanded & (FCL_NAN | FCL_POS_INF);
            if (demanded & FCL_NAN) != 0 { sm |= FCL_NAN; }
            let mode = fn_mode_of(vty);
            if (demanded & FCL_NAN) != 0 { sm |= FCL_NEGATIVE & ~FCL_NEG_ZERO; }
            if (demanded & FCL_NEG_INF) != 0 {
                sm |= FCL_ZERO;
                if dm_inputs_may_be_zero(mode) { sm |= FCL_SUBNORMAL; }
            }
            if (demanded & FCL_NORMAL) != 0 { sm |= FCL_NORMAL | FCL_SUBNORMAL; }
            if (demanded & FCL_ZERO) != 0 { sm |= FCL_POS_NORMAL; }
            let ch, ks = sd_fp_class(i, 0, sm, cx, depth + 1);
            if ch { return i, ks; }
            known = kfc_known_not(kfc_log(ks, mode), fcl_not(demanded));
            return sdfc_result(i, fmf, demanded, known, ks, ks, ks, 1), known;
        } else if id == IID_sqrt {
            var sm = demanded & (FCL_NEG_ZERO | FCL_POSITIVE | FCL_NAN);
            if (demanded & FCL_NAN) != 0 { sm |= FCL_NAN | (FCL_NEGATIVE & ~FCL_NEG_ZERO); }
            if (demanded & FCL_POS_NORMAL) != 0 { sm |= FCL_POS_SUBNORMAL; }
            let ch, ks0 = sd_fp_class(i, 0, sm, cx, depth + 1);
            if ch { return i, ks0; }
            var ks = ks0;
            if (demanded & FCL_NAN) == 0 { ks = kfc_known_not(ks, (FCL_NEGATIVE & ~FCL_NEG_ZERO) | FCL_NAN); }
            if (demanded & FCL_POS_INF) == 0 { ks = kfc_known_not(ks, FCL_POS_INF); }
            let mode = fn_mode_of(vty);
            if kfc_never(ks, FCL_POSITIVE) && kfc_never_logical_zero(ks, mode) { return c_fp_qnan_ty(vty), known; }
            known = kfc_known_not(kfc_sqrt(ks, mode), fcl_not(demanded));
            if known.known == FCL_ZERO {
                if (fmf & FMF_NSZ) != 0 { return c_fp_zero_ty(vty, false), known; }
                sdf_guard_begin(i);
                let cs = icb_binary_intrinsic_fmf(IID_copysign, c_fp_zero_ty(vty, false), op(i, 0), fmf, "");
                ic_take_name(cs, i);
                sdf_guard_end();
                return cs, known;
            }
            return sdfc_result(i, fmf, demanded, known, ks, ks, ks, 1), known;
        } else if id == IID_ldexp {
            var sm = demanded & FCL_INF;
            if (demanded & FCL_NAN) != 0 { sm |= FCL_NAN; }
            if (demanded & FCL_POS_INF) != 0 { sm |= FCL_POS_NORMAL | FCL_POS_SUBNORMAL; }
            if (demanded & FCL_NEG_INF) != 0 { sm |= FCL_NEG_NORMAL | FCL_NEG_SUBNORMAL; }
            if (demanded & (FCL_POS_NORMAL | FCL_POS_SUBNORMAL)) != 0 { sm |= FCL_POS_NORMAL | FCL_POS_SUBNORMAL; }
            if (demanded & (FCL_NEG_NORMAL | FCL_NEG_SUBNORMAL)) != 0 { sm |= FCL_NEG_NORMAL | FCL_NEG_SUBNORMAL; }
            if (demanded & FCL_POS_ZERO) != 0 { sm |= FCL_POS_FINITE; }
            if (demanded & FCL_NEG_ZERO) != 0 { sm |= FCL_NEG_FINITE; }
            let ch, ks = sd_fp_class(i, 0, sm, cx, depth + 1);
            if ch { return i, ks; }
            let mode = fn_mode_of(vty);
            kb_cxt = cx;
            let eb = kb_compute_all(op(i, 1), depth + 1);
            let emin = ap_sext64_checked(kb_smin(eb));
            let emax = ap_sext64_checked(kb_smax(eb));
            known = kfc_known_not(kfc_ldexp(ks, emin, emax, fp_ty_kind(vty), mode), fcl_not(demanded));
            return sdfc_result(i, fmf, demanded, known, ks, ks, ks, 1), known;
        } else if id == IID_trunc || id == IID_floor || id == IID_ceil || id == IID_rint || id == IID_nearbyint || id == IID_round || id == IID_roundeven {
            var sm = demanded;
            if (demanded & FCL_NAN) != 0 { sm |= FCL_NAN; }
            if (demanded & FCL_NEG_ZERO) != 0 { sm |= FCL_NEG_SUBNORMAL | FCL_NEG_NORMAL; }
            if (demanded & FCL_POS_ZERO) != 0 { sm |= FCL_POS_SUBNORMAL | FCL_POS_NORMAL; }
            let ch, ks = sd_fp_class(i, 0, sm, cx, depth + 1);
            if ch { return i, ks; }
            if kfc_always(ks, FCL_INF | FCL_NAN | FCL_ZERO) { return op(i, 0), known; }
            let rnt = id == IID_round || id == IID_roundeven || id == IID_nearbyint || id == IID_rint || id == IID_trunc;
            if (id == IID_floor || rnt) && kfc_always(ks, FCL_POS_ZERO | FCL_POS_SUBNORMAL) { return c_fp_zero_ty(vty, false), known; }
            if (id == IID_ceil || rnt) && kfc_always(ks, FCL_NEG_ZERO | FCL_NEG_SUBNORMAL) { return c_fp_zero_ty(vty, true), known; }
            if id == IID_floor && kfc_always(ks, FCL_NEG_SUBNORMAL) { return c_fpd(vty, -1.0), known; }
            if id == IID_ceil && kfc_always(ks, FCL_POS_SUBNORMAL) { return c_fpd(vty, 1.0), known; }
            known = kfc_known_not(kfc_round_to_integral(ks, id == IID_trunc, fp_ty_kind(vty) == TK_PPC_FP128), fcl_not(demanded));
            let sv = get_fp_class_constant(vty, known.known, true);
            if sv >= 0 { return sv, known; }
            if (id == IID_trunc || rnt) && kfc_always(ks, FCL_ZERO | FCL_SUBNORMAL) {
                sdf_guard_begin(i);
                let cs = icb_binary_intrinsic_fmf(IID_copysign, c_fp_zero_ty(vty, false), op(i, 0), icb_fmf, "");
                ic_take_name(cs, i);
                sdf_guard_end();
                return cs, known;
            }
            let inf = infer_fmf_value_flags(fmf, known.known, ks, ks, ks, 1);
            if inf != fmf {
                drop_ub_implying_attrs_and_md(i);
                set_fmf(i, fmf_of(i) | inf);
                return i, known;
            }
            return -1, known;
        } else if id == IID_fptrunc_round {
            let r, k = sdfc_fptrunc(i, fmf, demanded, cx, depth);
            return r, k;
        } else if id == IID_canonicalize && is_ieee_like_fp_kind(fp_ty_kind(vty)) {
            let mode = fn_mode_of(vty);
            var sm = demanded;
            if (demanded & FCL_QNAN) != 0 { sm |= FCL_SNAN; }
            if mode != DM_IEEE {
                if (demanded & FCL_POS_ZERO) != 0 { sm |= FCL_POS_SUBNORMAL; }
                if (demanded & FCL_NEG_ZERO) != 0 { sm |= FCL_NEG_SUBNORMAL; }
            }
            if mode == DM_PRESERVE_SIGN {
                if (demanded & FCL_POS_ZERO) == 0 { sm &= ~FCL_POS_SUBNORMAL; }
                if (demanded & FCL_NEG_ZERO) == 0 { sm &= ~FCL_NEG_SUBNORMAL; }
            }
            let ch, ks = sd_fp_class(i, 0, sm, cx, depth + 1);
            if ch { return i, ks; }
            known = kfc_known_not(kfc_canonicalize(ks, mode), fcl_not(demanded));
            let sv = get_fp_class_constant(vty, known.known, false);
            if sv >= 0 { return sv, known; }
            if kfc_never_nan(ks) && (mode == DM_IEEE || kfc_never(ks, FCL_SUBNORMAL)) { return op(i, 0), known; }
            let inf = infer_fmf_value_flags(fmf, known.known, ks, ks, ks, 1);
            if inf != fmf {
                drop_ub_implying_attrs_and_md(i);
                set_fmf(i, fmf_of(i) | inf);
                return i, known;
            }
            return -1, known;
        } else {
            known = kfc_known_not(kfc_cfp(i, demanded, cx, depth + 1), fcl_not(demanded));
        }
    } else if o == OP_SELECT {
        let ch2, kr0 = sd_fp_class(i, 2, demanded, cx, depth + 1);
        if ch2 { return i, kr0; }
        let ch1, kl0 = sd_fp_class(i, 1, demanded, cx, depth + 1);
        if ch1 { return i, kl0; }
        if kfc_never(kl0, demanded) { return op(i, 2), known; }
        if kfc_never(kr0, demanded) { return op(i, 1), known; }
        kb_cxt = cx;
        let kl = kfc_adjust_for_select_arm(kl0, op(i, 0), op(i, 1), false, depth);
        kb_cxt = cx;
        let kr = kfc_adjust_for_select_arm(kr0, op(i, 0), op(i, 2), true, depth);
        known = kfc_known_not(kfc_intersect_with(kl, kr), fcl_not(demanded));
    } else if o == OP_EXTRACTELEMENT {
        let ch, k = sd_fp_class(i, 0, demanded, cx, depth + 1);
        if ch { return i, k; }
        known = kfc_known_not(k, fcl_not(demanded));
    } else if o == OP_INSERTELEMENT {
        let ch1, ki = sd_fp_class(i, 1, demanded, cx, depth + 1);
        if ch1 { return i, ki; }
        let ch0, kv = sd_fp_class(i, 0, demanded, cx, depth + 1);
        if ch0 { return i, kv; }
        known = kfc_known_not(kfc_or(kv, ki), fcl_not(demanded));
    } else if o == OP_SHUFFLEVECTOR {
        let ch1, kr = sd_fp_class(i, 1, demanded, cx, depth + 1);
        if ch1 { return i, kr; }
        let ch0, kl = sd_fp_class(i, 0, demanded, cx, depth + 1);
        if ch0 { return i, kl; }
        known = kfc_known_not(kfc_or(kl, kr), fcl_not(demanded));
    } else if o == OP_INSERTVALUE {
        let ch0, ka = sd_fp_class(i, 0, demanded, cx, depth + 1);
        if ch0 { return i, ka; }
        let ch1, ke = sd_fp_class(i, 1, demanded, cx, depth + 1);
        if ch1 { return i, ke; }
        known = kfc_or(ka, ke);
    } else if o == OP_EXTRACTVALUE {
        let src = op(i, 0);
        let ii = inst_of(i);
        if insts[ii].naux == 1 && ints[insts[ii].aux] == 0 && one_use(src) && inst_iid(src) == IID_frexp {
            var sm: u64 = 0;
            if (demanded & FCL_NAN) != 0 { sm |= FCL_NAN; }
            if (demanded & FCL_NEG_FINITE) != 0 { sm |= FCL_NEG_FINITE; }
            if (demanded & FCL_POS_FINITE) != 0 { sm |= FCL_POS_FINITE; }
            if (demanded & FCL_POS_INF) != 0 { sm |= FCL_POS_INF; }
            if (demanded & FCL_NEG_INF) != 0 { sm |= FCL_NEG_INF; }
            let ch, ks = sd_fp_class(src, 0, sm, cx, depth + 1);
            if ch { return i, ks; }
            let mode = fn_mode_of(vty);
            known = kfc_frexp_mant(ks, mode);
            known.known &= demanded;
            let sv = get_fp_class_constant(vty, known.known, true);
            if sv >= 0 { return sv, known; }
            if kfc_always(known, FCL_INF | FCL_NAN) { return op(src, 0), known; }
            return -1, known;
        }
        let ch, ks = sd_fp_class(i, 0, demanded, cx, depth + 1);
        if ch { return i, ks; }
        known = ks;
    } else if o == OP_PHI {
        if depth >= MAX_RECURSION_DEPTH_FP - 2 { return get_fp_class_constant(vty, known.known, false), known; }
        var first = true;
        var changed = false;
        let n = nops(i);
        for k in n {
            let pred = phi_block(i, k);
            let ctx = block_terminator(pred);
            let ch, ks = sd_fp_class(i, k, demanded, ctx, depth + 1);
            if ch {
                let nv = op(i, k);
                for j in nops(i) { if phi_block(i, j) == pred { set_op(i, j, nv); } }
                changed = true;
            }
            if first { known = ks; first = false; } else { known = kfc_or(known, ks); }
        }
        if changed { return i, known; }
        known = kfc_known_not(known, fcl_not(demanded));
    } else {
        known = kfc_known_not(kfc_cfp(i, demanded, cx, depth + 1), fcl_not(demanded));
    }
    return get_fp_class_constant(vty, known.known, false), known;
}

// SimplifyMultipleUseDemandedFPClass(I, DemandedMask, Known, SQ, Depth)
recursive fn sd_multi_use_fp_class(i: i32, demanded0: u64, cx: i32, depth: i64) -> i32, KFC {
    var demanded = demanded0;
    var fmf: u8 = 0;
    if is_fp_math_operator(i) {
        fmf = fmf_of(i);
        demanded = adjust_demanded_mask_from_flags(demanded, fmf);
    }
    var known = kfc_unknown();
    let o = iop(i);
    var dflt = true;
    if o == OP_SELECT {
        dflt = false;
        let kr0 = kfc_cfp(op(i, 2), demanded, cx, depth + 1);
        if kfc_never(kr0, demanded) { return op(i, 1), known; }
        let kl0 = kfc_cfp(op(i, 1), demanded, cx, depth + 1);
        if kfc_never(kl0, demanded) { return op(i, 2), known; }
        kb_cxt = cx;
        let kl = kfc_adjust_for_select_arm(kl0, op(i, 0), op(i, 1), false, depth);
        kb_cxt = cx;
        let kr = kfc_adjust_for_select_arm(kr0, op(i, 0), op(i, 2), true, depth);
        known = kfc_known_not(kfc_intersect_with(kl, kr), fcl_not(demanded));
    } else if o == OP_FNEG {
        dflt = false;
        let fs = op(i, 0);
        if !is_intr(fs, IID_fabs) {
            known = kfc_cfp(i, demanded, cx, depth + 1);
        } else {
            let src = op(fs, 0);
            let ks = kfc_cfp(src, FCL_ALL, cx, depth + 1);
            let tdm = adjust_demanded_mask_from_flags(demanded, fmf_of(fs));
            let sv, k = sdfc_fneg_fabs(known, src, tdm, ks, false);
            if sv >= 0 { return sv, k; }
            known = k;
        }
    } else if o == OP_CALL {
        let id = inst_iid(i);
        if id == IID_fabs {
            dflt = false;
            let src = op(i, 0);
            let ks = kfc_cfp(src, FCL_ALL, cx, depth + 1);
            let sv, k = sdfc_fabs(known, src, demanded, ks, false);
            if sv >= 0 { return sv, k; }
            known = k;
        } else if id == IID_copysign {
            dflt = false;
            let mag = op(i, 0);
            let sgn = op(i, 1);
            var km = kfc_cfp(mag, FCL_ALL, cx, depth + 1);
            km = kfc_known_not(km, fcl_not(fcl_unknown_sign(demanded)));
            let sm = sdfc_copysign_mag(mag, demanded, km, false);
            if sm >= 0 { return sm, known; }
            var ksg = kfc_cfp(sgn, FCL_ALL, cx, depth + 1);
            if (fmf & FMF_NINF) != 0 { ksg = kfc_known_not(ksg, FCL_INF); }
            if (fmf & FMF_NNAN) != 0 { ksg = kfc_known_not(ksg, FCL_NAN); }
            if ksg.sign >= 0 && km.sign >= 0 && ksg.sign == km.sign { return mag, known; }
            known = kfc_copysign(km, ksg);
        } else if id == IID_maxnum || id == IID_minnum || id == IID_maximum || id == IID_minimum || id == IID_maximumnum || id == IID_minimumnum {
            let kr = kfc_cfp(op(i, 1), demanded, cx, depth + 1);
            if kfc_is_unknown(kr) { return -1, known; }
            let kl = kfc_cfp(op(i, 0), demanded, cx, depth + 1);
            let sv, k = sdfc_minmax(known, id, i, demanded, kl, kr, false);
            return sv, k;
        }
    }
    if dflt {
        known = kfc_known_not(kfc_cfp(i, demanded, cx, depth + 1), fcl_not(demanded));
    }
    return get_fp_class_constant(vals[i].ty, known.known, false), known;
}

// SimplifyDemandedFPClass(I, OpNo, DemandedMask, Known, SQ, Depth): changed, Known
recursive fn sd_fp_class(i: i32, opno: i64, demanded: u64, cx: i32, depth: i64) -> bool, KFC {
    let u = vals[i].ops + opno as i32;
    let v = uses[u].val;
    let vty = vals[v].ty;
    var known = kfc_unknown();
    if demanded == 0 {
        if vals[v].kind == VK_POISON { return false, known; }
        ic_replace_use(u, c_poison(vty));
        return true, known;
    }
    if !is_inst(v) {
        known = kfc_known_not(kfc_cfp(v, FCL_ALL, cx, depth), fcl_not(demanded));
        if known.known == 0 {
            if vals[v].kind == VK_POISON { return false, known; }
            ic_replace_use(u, c_poison(vty));
            return true, known;
        }
        if is_constant(v) { return false, known; }
        let fc = get_fp_class_constant(vty, known.known, false);
        if fc < 0 || fc == v { return false, known; }
        ic_replace_use(u, fc);
        return true, known;
    }
    if depth == MAX_RECURSION_DEPTH_FP {
        known = kfc_known_not(known, fcl_not(demanded));
        return false, known;
    }
    var nv: i32 = -1;
    if has_one_use(v) {
        let r, k = sd_use_fp_class(v, demanded, cx, depth);
        nv = r; known = k;
    } else {
        let r, k = sd_multi_use_fp_class(v, demanded, cx, depth);
        nv = r; known = k;
    }
    if nv < 0 { return false, known; }
    if dbgrecs.len > 0 && dbg_records_use_value(v) { ic_not_ported("salvageDebugInfo in SimplifyDemandedFPClass"); }
    ic_replace_use(uses_index_of(i, opno), nv);
    return true, known;
}
// the use may have moved (an operand list does not move while it is simplified, but be explicit)
fn uses_index_of(i: i32, opno: i64) -> i32 { vals[i].ops + opno as i32 }

// SimplifyDemandedInstructionFPClass(Inst)
fn simplify_demanded_instruction_fp_class(i: i32) -> bool {
    let v, k = sd_use_fp_class(i, FCL_ALL, i, 0);
    if v < 0 { return false; }
    if v == i { return true; }
    ic_replace_inst_uses_with(i, v);
    return true;
}
