// LibCallSimplifier, math part: port of llvm/lib/Transforms/Utils/SimplifyLibCalls.cpp (replacePowWithExp,
// getSqrtCall, replacePowWithSqrt, createPowWithIntegerExponent, optimizePow, optimizeLog, optimizeFMod,
// isTrigLibCall, insertSinCosCall, optimizeSinCosPi, classifyArgUse, optimizeRemquo, optimizeFdim, optimizeNaN,
// substituteInParent) and the LibFunc forms of emitUnaryFloatFnCall / emitBinaryFloatFnCall
// (llvm/lib/Transforms/Utils/BuildLibCalls.cpp). The APFloat operations they need (divide/remainder statuses,
// isInteger, convertToInteger) are computed exactly on bignums.
namespace ic;
import std;
import binary;
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
import fpclass;
import knownbits;
import constfold;
import apint;
import apfloat;
import fpu;
import bignum;
import hostmath;
import tli;
import triple;
import gen_triple;
import build_libcalls;
import ic;
import ic_builder;
import ic_common;
import ic_calls;
import ic_casts2;
import ic_fp_addsub;
import simplify_libcalls;
import simplify_libcalls_str;
import ic_compares;
import ic_phi;

// ---------------------------------------------------------------------------------------------
// BuildLibCalls: emitUnaryFloatFnCall / emitBinaryFloatFnCall with LibFuncs (the name is TLI's)

fn lcs_call_attrs_without_speculatable(c: i32, attrs_l: i32) {
    let l = attrs_l;
    var sets: i32[>..<] = [];
    let n = if l == 0 { 0 } else { alists[l].n as i64 };
    for j in n {
        var s = alist_runs[alists[l].at + j];
        if j == 0 { s = aset_without(s, AK_Speculatable); }
        sets.push(s);
    }
    insts[inst_of(c)].attrs = alist_get(sets);
}
fn emit_unary_float_fn_lf(a: i32, d: i64, f: i64, l: i64, attrs_l: i32) -> i32 {
    let lf = blc_get_float_fn(vals[a].ty, d, f, l);
    let t: i32 = vals[a].ty;
    let fv = blc_get_or_insert(lf, ty_func_of(t, [t], false), 0);
    var nm: u8[>..] = [];
    nm.append(tli_name(lf));
    let c = lcs_create_call(fv, [a], nm);
    lcs_call_attrs_without_speculatable(c, attrs_l);
    insts[inst_of(c)].cc = globs[glob_of(fv)].cc;
    return c;
}
fn emit_binary_float_fn_lf(a: i32, b: i32, d: i64, f: i64, l: i64, attrs_l: i32) -> i32 {
    let lf = blc_get_float_fn(vals[a].ty, d, f, l);
    let t: i32 = vals[a].ty;
    let bt: i32 = vals[b].ty;
    let fv = blc_get_or_insert(lf, ty_func_of(t, [t, bt], false), 0);
    var nm: u8[>..] = [];
    nm.append(tli_name(lf));
    blc_infer_by_name(nm);
    let c = lcs_create_call(fv, [a, b], nm);
    lcs_call_attrs_without_speculatable(c, attrs_l);
    insts[inst_of(c)].cc = globs[glob_of(fv)].cc;
    return c;
}

// substituteInParent(I, With): replaceAllUsesWith + eraseFromParent through InstCombine
fn lcs_substitute_in_parent(i: i32, with: i32) {
    ic_replace_inst_uses_with(i, with);
    ic_erase(i);
}
fn lcs_is_fast(i: i32) -> bool { is_fp_math_operator(i) && (icx_fmf(i) & FMF_FAST) == FMF_FAST }
fn lcs_fmf(i: i32) -> u8 { if is_fp_math_operator(i) { icx_fmf(i) } else { 0 } }

// ---------------------------------------------------------------------------------------------
// APFloat helpers (exact)

// APFloat::isInteger: finite and equal to its truncation
fn fp_is_integer(kind: i64, lo: u64, hi: u64) -> bool {
    let p = fp_decompose(kind, lo, hi);
    if p.cat == FC_NAN || p.cat == FC_INF { return false; }
    let ilo, ihi = fp_round_to_integral(kind, lo, hi, FRM_ZERO);
    return ilo == lo && ihi == hi;
}
// value of a finite nonzero float as (neg, magnitude bignum, exponent): |x| = mag * 2^e
fn fp_exact(kind: i64, lo: u64, hi: u64, mag: u32[>..<]&) -> bool, i64 {
    let f = fp_fmt(kind);
    let p = fp_decompose(kind, lo, hi);
    let e = fp_sig_bn(p, f, mag);
    return p.neg, e;
}
// x / y rounded to nearest-even with APFloat::divide's status: (lo, hi, ok) where ok = opOK or opInexact
fn fp_divide_status(kind: i64, xlo: u64, xhi: u64, ylo: u64, yhi: u64) -> u64, u64, bool {
    let px = fp_decompose(kind, xlo, xhi);
    let py = fp_decompose(kind, ylo, yhi);
    let qlo, qhi = fp_arith(kind, FOP_DIV, xlo, xhi, ylo, yhi);
    if px.cat == FC_NAN || py.cat == FC_NAN {
        return qlo, qhi, !fp_is_signaling_bits(kind, xlo, xhi) && !fp_is_signaling_bits(kind, ylo, yhi);
    }
    if (px.cat == FC_INF && py.cat == FC_INF) || (px.cat == FC_ZERO && py.cat == FC_ZERO) { return qlo, qhi, false; }
    if py.cat == FC_ZERO { return qlo, qhi, false; }   // opDivByZero
    if px.cat != FC_NORMAL || py.cat != FC_NORMAL { return qlo, qhi, true; }
    let pq = fp_decompose(kind, qlo, qhi);
    if pq.cat == FC_INF { return qlo, qhi, false; }    // opOverflow
    // exact iff q * y == x
    var exact = false;
    if pq.cat == FC_NORMAL {
        var mx: u32[>..<] = [];
        var my: u32[>..<] = [];
        var mq: u32[>..<] = [];
        let _nx, ex = fp_exact(kind, xlo, xhi, mx);
        let _ny, ey = fp_exact(kind, ylo, yhi, my);
        let _nq, eq = fp_exact(kind, qlo, qhi, mq);
        var prod: u32[>..<] = [];
        bn_mul(mq, my, prod);
        let ep = eq + ey;
        if ep >= ex { bn_shl(prod, ep - ex); } else { bn_shl(mx, ex - ep); }
        exact = bn_cmp(prod, mx) == 0;
    }
    if !exact {
        // a tiny inexact result raises opUnderflow
        let f = fp_fmt(kind);
        let tiny = pq.cat == FC_ZERO || pq.exponent < 1 - f.bias;
        if tiny { return qlo, qhi, false; }
    }
    return qlo, qhi, true;
}
// IEEE remainder(x, y) with APFloat::remainder's status: (lo, hi, opOK)
fn fp_remainder_status(kind: i64, xlo: u64, xhi: u64, ylo: u64, yhi: u64) -> u64, u64, bool {
    let px = fp_decompose(kind, xlo, xhi);
    let py = fp_decompose(kind, ylo, yhi);
    if px.cat == FC_NAN || py.cat == FC_NAN {
        let rlo, rhi = fp_arith(kind, FOP_ADD, xlo, xhi, ylo, yhi);
        return rlo, rhi, !fp_is_signaling_bits(kind, xlo, xhi) && !fp_is_signaling_bits(kind, ylo, yhi);
    }
    if px.cat == FC_INF || py.cat == FC_ZERO { let n1, n2 = fp_default_nan(kind); return n1, n2, false; }
    if px.cat == FC_ZERO || py.cat == FC_INF { return xlo, xhi, true; }
    var mx: u32[>..<] = [];
    var my: u32[>..<] = [];
    let nx, ex = fp_exact(kind, xlo, xhi, mx);
    let _ny, ey = fp_exact(kind, ylo, yhi, my);
    let e = min(ex, ey);
    bn_shl(mx, ex - e);
    bn_shl(my, ey - e);
    var q: u32[>..<] = [];
    var r: u32[>..<] = [];
    bn_divmod(mx, my, q, r);
    // n = round-half-even(X / Y): compare 2r with Y
    var r2: u32[>..<] = [];
    bn_copy(r2, r);
    bn_shl(r2, 1);
    let c = bn_cmp(r2, my);
    var neg = nx;
    if c > 0 || (c == 0 && bn_bit(q, 0)) {
        // r' = r - Y (negative): |r'| = Y - r, sign flips
        var t: u32[>..<] = [];
        bn_copy(t, my);
        bn_sub(t, r);
        bn_copy(r, t);
        neg = !nx;
    }
    if bn_is_zero(r) { let zlo, zhi = fp_encode(kind, nx, 0, 0, 0, false); return zlo, zhi, true; }
    var den: u32[>..<] = [];
    bn_set_u64(den, 1);
    if e >= 0 { bn_shl(r, e); } else { bn_shl(den, -e); }
    let rlo, rhi = fp_round_rational(kind, neg, r, den);
    return rlo, rhi, true;
}
// convertToInteger(APSInt(w, signed), mode) status is opOK or opInexact: (ok, value)
fn fp_to_int_round(kind: i64, lo: u64, hi: u64, w: i64, mode: i64) -> bool, AP {
    let p = fp_decompose(kind, lo, hi);
    if p.cat == FC_NAN || p.cat == FC_INF { return false, ap_zero(w); }
    let ilo, ihi = fp_round_to_integral(kind, lo, hi, mode);
    return fp_to_integer_exact(kind, ilo, ihi, w, true);
}

// ---------------------------------------------------------------------------------------------
// pow

// replacePowWithExp(Pow, B)
fn replace_pow_with_exp(pw: i32) -> i32 {
    let base = cb_arg(pw, 0);
    let expo = cb_arg(pw, 1);
    let ty: i32 = vals[pw].ty;
    if is_inst_op(base, OP_CALL) && has_one_use(base) && lcs_is_fast(base) && lcs_is_fast(pw) {
        let cfn = called_function(base);
        if cfn >= 0 {
            let lfn = tli_lookup_name(val_name(cfn)) as i64;
            if lfn >= 0 && blc_is_emittable(lfn) {
                var id: i64 = 0;
                var lf_f: i64 = 0; var lf_d: i64 = 0; var lf_l: i64 = 0;
                var expname: u8[>..] = [];
                if lfn == LF_expf || lfn == LF_exp || lfn == LF_expl {
                    expname.append(tli_name(LF_exp)); id = IID_exp; lf_f = LF_expf; lf_d = LF_exp; lf_l = LF_expl;
                } else if lfn == LF_exp2f || lfn == LF_exp2 || lfn == LF_exp2l {
                    expname.append(tli_name(LF_exp2)); id = IID_exp2; lf_f = LF_exp2f; lf_d = LF_exp2; lf_l = LF_exp2l;
                } else { return -1; }
                let fm = icx_fbinop(OP_FMUL, cb_arg(base, 0), expo, icb_fmf, "mul");
                var e: i32 = -1;
                if call_does_not_access_memory(base) { e = icx_unary_intrinsic_f(id, fm, icb_fmf, expname); }
                else {
                    let cf2 = called_function(base);
                    e = emit_unary_float_fn_lf(fm, lf_d, lf_f, lf_l, insts[inst_of(base)].attrs);
                    if cf2 < 0 { fatal("internal: replacePowWithExp"); }
                }
                lcs_substitute_in_parent(base, e);
                return e;
            }
        }
    }
    let bc = m_apfloat(base);
    if bc < 0 { return -1; }
    let kind = fp_kind_ty(vals[bc].ty);
    let blo = cint_lo(bc);
    let bhi = cint_hi(bc);
    let use_intr = call_does_not_access_memory(pw);
    // pow(2.0, itofp(x)) -> ldexp(1.0, x)
    if (use_intr || !ty_is_vector(ty)) && fp_is_exactly(bc, 2.0) && (is_inst_op(expo, OP_SITOFP) || is_inst_op(expo, OP_UITOFP)) &&
       (use_intr || blc_has_float_fn(ty, LF_ldexp, LF_ldexpf, LF_ldexpl)) {
        let ei = get_int_to_fp_val(expo, tli_int_bits());
        if ei >= 0 {
            let one = c_fp_from_f64(ty, 1.0);
            if use_intr { return copy_flags(pw, icx_intrinsic_f(IID_ldexp, [ty, vals[ei].ty as i32], [one, ei], icx_fmf(pw), "exp2")); }
            return copy_flags(pw, emit_binary_float_fn_lf(one, ei, LF_ldexp, LF_ldexpf, LF_ldexpl, 0));
        }
    }
    // pow(2.0 ** n, x) -> exp2(n * x)
    if blc_has_float_fn(ty, LF_exp2, LF_exp2f, LF_exp2l) {
        let olo, ohi = fp_convert(TK_DOUBLE, kind, binary::bits_of_f64(1.0), 0);
        let rlo, rhi = fp_arith(kind, FOP_DIV, olo, ohi, blo, bhi);
        let is_int = fp_is_integer(kind, blo, bhi);
        let is_rec = fp_is_integer(kind, rlo, rhi);
        let nlo = if is_rec { rlo } else { blo };
        let nhi = if is_rec { rhi } else { bhi };
        if is_int || is_rec {
            let ok, ni = fp_to_integer_exact(kind, nlo, nhi, 64, false);
            if ok && ap_ugt_u64(ni, 1) && ap_is_pow2(ni) {
                let lg = ap_log2(ni) as f64;
                let n = if is_rec { -lg } else { lg };
                let fm = icx_fbinop(OP_FMUL, expo, c_fp_from_f64(ty, n), icb_fmf, "mul");
                if call_does_not_access_memory(pw) { return copy_flags(pw, icx_unary_intrinsic_f(IID_exp2, fm, icb_fmf, "exp2")); }
                return copy_flags(pw, emit_unary_float_fn_lf(fm, LF_exp2, LF_exp2f, LF_exp2l, 0));
            }
        }
    }
    // pow(10.0, x) -> exp10(x)
    if fp_is_exactly(bc, 10.0) && blc_has_float_fn(ty, LF_exp10, LF_exp10f, LF_exp10l) {
        if call_does_not_access_memory(pw) { return icx_intrinsic_f(IID_exp10, [ty], [expo], icx_fmf(pw), "exp10"); }
        return copy_flags(pw, emit_unary_float_fn_lf(expo, LF_exp10, LF_exp10f, LF_exp10l, 0));
    }
    // pow(x, y) -> exp2(log2(x) * y)
    let bp = fp_decompose(kind, blo, bhi);
    if (icx_fmf(pw) & FMF_AFN) != 0 && (icx_fmf(pw) & FMF_NNAN) != 0 && bp.cat == FC_NORMAL && !bp.neg {
        var lg: i32 = -1;
        let sk = ty_kind(ty);
        if sk == TK_FLOAT {
            let fb = goose_hm_log2f(blo as u32);
            lg = c_fp_bits_ty(ty, fb as u64, 0);
        } else if sk == TK_DOUBLE {
            let db, _ok = hm_call1(HM1_LOG2, blo);
            lg = c_fp_bits_ty(ty, db, 0);
        }
        if lg >= 0 {
            let fm = icx_fbinop(OP_FMUL, lg, expo, icb_fmf, "mul");
            if call_does_not_access_memory(pw) { return copy_flags(pw, icx_unary_intrinsic_f(IID_exp2, fm, icb_fmf, "exp2")); }
            if blc_has_float_fn(ty, LF_exp2, LF_exp2f, LF_exp2l) {
                return copy_flags(pw, emit_unary_float_fn_lf(fm, LF_exp2, LF_exp2f, LF_exp2l, 0));
            }
        }
    }
    return -1;
}
extern fn goose_hm_log2f(x: u32) -> u32;
fn ap_ugt_u64(a: AP, v: u64) -> bool { !ap_ule_u64(a, v) }

// getSqrtCall(V, Attrs, NoErrno, M, B, TLI)
fn get_sqrt_call(v: i32, attrs_l: i32, no_errno: bool) -> i32 {
    if no_errno { return icx_unary_intrinsic_f(IID_sqrt, v, icb_fmf, "sqrt"); }
    if blc_has_float_fn(vals[v].ty, LF_sqrt, LF_sqrtf, LF_sqrtl) {
        return emit_unary_float_fn_lf(v, LF_sqrt, LF_sqrtf, LF_sqrtl, attrs_l);
    }
    return -1;
}
// replacePowWithSqrt(Pow, B)
fn replace_pow_with_sqrt(pw: i32) -> i32 {
    let base = cb_arg(pw, 0);
    let expo = cb_arg(pw, 1);
    let ty: i32 = vals[pw].ty;
    let ec = m_apfloat(expo);
    if ec < 0 || (!fp_is_exactly(ec, 0.5) && !fp_is_exactly(ec, -0.5)) { return -1; }
    let eneg = cfp_parts(ec).neg;
    let fmf = icx_fmf(pw);
    if eneg && (fmf & FMF_AFN) == 0 && (fmf & FMF_REASSOC) == 0 { return -1; }
    if !call_does_not_access_memory(pw) && (fmf & FMF_NINF) == 0 {
        kb_cxt = pw;
        if !is_known_never_infinity(base, 0) { return -1; }
    }
    var sq = get_sqrt_call(base, 0, call_does_not_access_memory(pw));
    if sq < 0 { return -1; }
    if (fmf & FMF_NSZ) == 0 { sq = icx_unary_intrinsic_f(IID_fabs, sq, icb_fmf, "abs"); }
    sq = copy_flags(pw, sq);
    if (fmf & FMF_NINF) == 0 {
        let pinf = c_fp_inf_ty(ty, false);
        let ninf = c_fp_inf_ty(ty, true);
        let fc = icb_fcmp_fmf(P_OEQ, base, ninf, icb_fmf, "isinf");
        sq = icb_select(fc, pinf, sq, "", -1);
    }
    if eneg { sq = icx_fbinop(OP_FDIV, c_fp_from_f64(ty, 1.0), sq, icb_fmf, "reciprocal"); }
    return sq;
}
// createPowWithIntegerExponent(Base, Expo, M, B)
fn create_powi(base: i32, expo: i32) -> i32 {
    return icx_intrinsic_f(IID_powi, [vals[base].ty as i32, vals[expo].ty as i32], [base, expo], icb_fmf, "");
}
// optimizePow(Pow, B)
fn optimize_pow(pw: i32, unsafe_shrink: bool) -> i32 {
    let sv = icb_fmf;
    icb_fmf = icx_fmf(pw);
    let r = optimize_pow_impl(pw, unsafe_shrink);
    icb_fmf = sv;
    return r;
}
fn optimize_pow_impl(pw: i32, unsafe_shrink: bool) -> i32 {
    let base = cb_arg(pw, 0);
    let expo = cb_arg(pw, 1);
    let ty: i32 = vals[pw].ty;
    let approx = (icx_fmf(pw) & FMF_AFN) != 0;
    if m_fp_one(base) { return base; }
    let e = replace_pow_with_exp(pw);
    if e >= 0 { return e; }
    if m_specific_fp(expo, -1.0) { return icx_fbinop(OP_FDIV, c_fp_from_f64(ty, 1.0), base, icb_fmf, "reciprocal"); }
    if m_any_zero_fp(expo) { return c_fp_from_f64(ty, 1.0); }
    if m_fp_one(expo) { return base; }
    if m_specific_fp(expo, 2.0) && call_does_not_access_memory(pw) { return icx_fbinop(OP_FMUL, base, base, icb_fmf, "square"); }
    let sq = replace_pow_with_sqrt(pw);
    if sq >= 0 { return sq; }
    let ec = m_apfloat(expo);
    if approx && ec >= 0 && !fp_is_exactly(ec, 0.5) && !fp_is_exactly(ec, -0.5) {
        let kind = fp_kind_ty(vals[ec].ty);
        var elo = cint_lo(ec);
        var ehi = cint_hi(ec);
        let alo, ahi = fp_with_sign(kind, elo, ehi, false);
        var sqrt: i32 = -1;
        if !fp_is_integer(kind, alo, ahi) {
            // Expo2 = ExpoA + ExpoA must be exact (opOK) and an integer
            let dlo, dhi = fp_arith(kind, FOP_ADD, alo, ahi, alo, ahi);
            let pa = fp_decompose(kind, alo, ahi);
            let pd = fp_decompose(kind, dlo, dhi);
            if pa.cat == FC_NORMAL && pd.cat == FC_INF { return -1; }   // overflow
            if pa.cat == FC_NAN && fp_is_signaling_bits(kind, alo, ahi) { return -1; }
            if !fp_is_integer(kind, dlo, dhi) { return -1; }
            // ExpoI.roundToIntegral(rmTowardNegative) is opInexact (ExpoA is not an integer)
            let flo, fhi = fp_round_to_integral(kind, elo, ehi, FRM_DOWN);
            if !fp_is_integer(kind, flo, fhi) { return -1; }
            elo = flo;
            ehi = fhi;
            sqrt = get_sqrt_call(base, 0, call_does_not_access_memory(pw));
            if sqrt < 0 { return -1; }
        }
        let ib = tli_int_bits();
        if fp_is_integer(kind, elo, ehi) {
            let ok, iv = fp_to_integer_exact(kind, elo, ehi, ib, true);
            if ok {
                let powi = copy_flags(pw, create_powi(base, c_int_ap(ty_int(ib), iv)));
                if powi >= 0 && sqrt >= 0 { return icx_fbinop(OP_FMUL, powi, sqrt, icb_fmf, ""); }
                return powi;
            }
        }
    }
    if approx && (is_inst_op(expo, OP_SITOFP) || is_inst_op(expo, OP_UITOFP)) {
        let ei = get_int_to_fp_val(expo, tli_int_bits());
        if ei >= 0 { return copy_flags(pw, create_powi(base, ei)); }
    }
    let cf = called_function(pw);
    if unsafe_shrink && val_name(cf) == tli_name(LF_pow) && lcs_has_float_version(pw) {
        let s = optimize_double_fp(pw, true, true);
        if s >= 0 { return s; }
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// log

// optimizeLog(Log, B)
fn optimize_log(lg: i32, unsafe_shrink: bool) -> i32 {
    let lfn = called_function(lg);
    var lognm: u8[>..] = [];
    lognm.append(val_name(lfn));
    var logid = call_iid(lg) as i64;
    let ty: i32 = vals[lg].ty;
    if unsafe_shrink && lcs_has_float_version(lg) {
        let r = optimize_double_fp(lg, false, true);
        if r >= 0 { return r; }
    }
    var exp_lb: i64 = -1; var exp2_lb: i64 = -1; var exp10_lb: i64 = -1; var pow_lb: i64 = -1;
    let loglb = tli_lookup_name(lognm) as i64;
    if loglb >= 0 {
        if loglb == LF_logf || loglb == LF_log2f || loglb == LF_log10f {
            exp_lb = LF_expf; exp2_lb = LF_exp2f; exp10_lb = LF_exp10f; pow_lb = LF_powf;
        } else if loglb == LF_log || loglb == LF_log2 || loglb == LF_log10 {
            exp_lb = LF_exp; exp2_lb = LF_exp2; exp10_lb = LF_exp10; pow_lb = LF_pow;
        } else if loglb == LF_logl || loglb == LF_log2l || loglb == LF_log10l {
            exp_lb = LF_expl; exp2_lb = LF_exp2l; exp10_lb = LF_exp10l; pow_lb = LF_powl;
        } else { return -1; }
        if loglb == LF_logf || loglb == LF_log || loglb == LF_logl { logid = IID_log; }
        else if loglb == LF_log2f || loglb == LF_log2 || loglb == LF_log2l { logid = IID_log2; }
        else { logid = IID_log10; }
        let fmf = icx_fmf(lg);
        var no_errno = (fmf & FMF_NNAN) != 0 && (fmf & FMF_NINF) != 0;
        if !no_errno {
            kb_cxt = lg;
            let k = kfc_compute_all(op(lg, 0), FCL_ORDERED_LT_ZERO_MASK | FCL_SUBNORMAL, 0);
            let mode = fn_denormal_mode(inst_func(lg), ty);
            no_errno = kfc_cannot_be_ordered_lt_zero(k) && kfc_never_logical_zero(k, mode);
        }
        if no_errno {
            let nl = icx_unary_intrinsic_f(logid, cb_arg(lg, 0), icx_fmf(lg), "");
            if is_inst(nl) {
                ph_copy_metadata_any(nl, lg);
                return copy_flags(lg, nl);
            }
            return nl;
        }
    } else if logid == IID_log || logid == IID_log2 || logid == IID_log10 {
        let sk = ty_kind(ty_scalar(ty));
        if sk == TK_FLOAT { exp_lb = LF_expf; exp2_lb = LF_exp2f; exp10_lb = LF_exp10f; pow_lb = LF_powf; }
        else if sk == TK_DOUBLE { exp_lb = LF_exp; exp2_lb = LF_exp2; exp10_lb = LF_exp10; pow_lb = LF_pow; }
        else { return -1; }
    } else { return -1; }
    let arg = cb_arg(lg, 0);
    if !lcs_is_fast(lg) || !is_inst_op(arg, OP_CALL) || !lcs_is_fast(arg) || !has_one_use(arg) { return -1; }
    let sv = icb_fmf;
    icb_fmf = FMF_FAST;
    let r = optimize_log_arg(lg, arg, logid, lognm, exp_lb, exp2_lb, exp10_lb, pow_lb);
    icb_fmf = sv;
    return r;
}
fn optimize_log_arg(lg: i32, arg: i32, logid: i64, lognm: const u8[:], exp_lb: i64, exp2_lb: i64, exp10_lb: i64, pow_lb: i64) -> i32 {
    let ty: i32 = vals[lg].ty;
    let argid = call_iid(arg) as i64;
    var arglb: i64 = -1;
    if call_iid(arg) == 0 {
        let acf = called_function(arg);
        if acf >= 0 && !call_is_nobuiltin(arg) { arglb = tli_get_libfunc(acf) as i64; }
    }
    if (arglb >= 0 && arglb == pow_lb) || argid == IID_pow || argid == IID_powi {
        var logx: i32 = -1;
        if call_does_not_access_memory(lg) { logx = icx_unary_intrinsic_f(logid, op(arg, 0), icb_fmf, "log"); }
        else { logx = emit_float_fn_call_named(op(arg, 0), lognm); }
        var y = cb_arg(arg, 1);
        if argid == IID_powi { y = icb_cast(OP_SITOFP, y, ty, "cast"); }
        let muly = icx_fbinop(OP_FMUL, y, logx, icb_fmf, "mul");
        lcs_substitute_in_parent(arg, muly);
        return muly;
    }
    if (arglb >= 0 && (arglb == exp_lb || arglb == exp2_lb || arglb == exp10_lb)) || argid == IID_exp || argid == IID_exp2 {
        var eul: i32 = -1;
        if (arglb >= 0 && arglb == exp_lb) || argid == IID_exp { eul = c_fp_from_f64(ty, 2.718281828459045); }
        else if (arglb >= 0 && arglb == exp2_lb) || argid == IID_exp2 { eul = c_fp_from_f64(ty, 2.0); }
        else { eul = c_fp_from_f64(ty, 10.0); }
        var loge: i32 = -1;
        if call_does_not_access_memory(lg) { loge = icx_unary_intrinsic_f(logid, eul, icb_fmf, "log"); }
        else { loge = emit_float_fn_call_named(eul, lognm); }
        let muly = icx_fbinop(OP_FMUL, cb_arg(arg, 0), loge, icb_fmf, "mul");
        lcs_substitute_in_parent(arg, muly);
        return muly;
    }
    return -1;
}
// emitUnaryFloatFnCall(Op, TLI, Name, B, NoAttrs): the name gets the type suffix
fn emit_float_fn_call_named(a: i32, name: const u8[:]) -> i32 { emit_float_fn_call(a, -1, name, 0) }
// Instruction::copyMetadata
fn ph_copy_metadata_any(dst: i32, src: i32) {
    let si = inst_of(src);
    var ks: i32[>..<] = [];
    var ns: i32[>..<] = [];
    for k in insts[si].nmd {
        ks.push(md_att[insts[si].md + 2 * k]);
        ns.push(md_att[insts[si].md + 2 * k + 1]);
    }
    for k in ks.len { inst_set_md(dst, ks[k], ns[k]); }
}

// ---------------------------------------------------------------------------------------------
// fmod, sinpi/cospi, remquo, fdim, nan

// optimizeFMod(CI, B)
fn optimize_fmod(ci: i32) -> i32 {
    var no_errno = (icx_fmf(ci) & FMF_NNAN) != 0;
    if !no_errno {
        kb_cxt = ci;
        let k0 = kfc_compute_all(op(ci, 0), FCL_INF, 0);
        if kfc_never_inf(k0) {
            kb_cxt = ci;
            let k1 = kfc_compute_all(op(ci, 1), FCL_ZERO | FCL_SUBNORMAL, 0);
            no_errno = kfc_never_logical_zero(k1, fn_denormal_mode(inst_func(ci), vals[ci].ty));
        }
    }
    if no_errno { return icb_fbinop_fmf(OP_FREM, op(ci, 0), op(ci, 1), icx_fmf(ci), ""); }
    return -1;
}

// isTrigLibCall(CI)
fn is_trig_libcall(ci: i32) -> bool { call_has_fn_attr(ci, AK_NoUnwind) && call_does_not_access_memory(ci) }

// classifyArgUse: 0 none, 1 sin, 2 cos, 3 sincos
fn classify_arg_use(u: i32, fv: i32, is_float: bool) -> i64 {
    if !is_inst_op(u, OP_CALL) || use_empty(u) { return 0; }
    if inst_func(u) != fv { return 0; }
    let cf = called_function(u);
    if cf < 0 { return 0; }
    let lf = tli_get_libfunc(cf) as i64;
    if lf < 0 || !blc_is_emittable(lf) || !is_trig_libcall(u) { return 0; }
    if is_float {
        if lf == LF_sinpif { return 1; }
        if lf == LF_cospif { return 2; }
        if lf == LF_sincospif_stret { return 3; }
    } else {
        if lf == LF_sinpi { return 1; }
        if lf == LF_cospi { return 2; }
        if lf == LF_sincospi_stret { return 3; }
    }
    return 0;
}
// optimizeSinCosPi(CI, IsSin, B)
fn optimize_sincospi(ci: i32, is_sin: bool) -> i32 {
    if !is_trig_libcall(ci) { return -1; }
    let arg = cb_arg(ci, 0);
    if is_constant_data(arg) { return -1; }
    let is_float = ty_kind(vals[arg].ty) == TK_FLOAT;
    let fv = inst_func(ci);
    var sins: i32[>..<] = [];
    var coss: i32[>..<] = [];
    var scs: i32[>..<] = [];
    var u = vals[arg].first_use;
    // Value::users() walks the use list from the most recent use
    while u >= 0 {
        let us = uses[u].user;
        u = uses[u].next;
        let k = classify_arg_use(us, fv, is_float);
        if k == 1 { sins.push(us); } else if k == 2 { coss.push(us); } else if k == 3 { scs.push(us); }
    }
    if sins.len == 0 || coss.len == 0 { return -1; }
    // insertSinCosCall
    let orig = called_function(ci);
    let m = globs[glob_of(orig)].module;
    let t = triple_parse(tli_triple_str(m));
    let aty: i32 = vals[arg].ty;
    var rty: i32 = -1;
    var lf: i64 = 0;
    if is_float {
        lf = LF_sincospif_stret;
        if t.arch == TA_x86 { fatal("LibCallSimplifier: insertSinCosCall on x86-32 (asserts in LLVM)"); }
        rty = if t.arch == TA_x86_64 { ty_vector(aty, 2, false) } else { ty_struct_of([aty, aty]) };
    } else {
        lf = LF_sincospi_stret;
        rty = ty_struct_of([aty, aty]);
    }
    if !blc_is_emittable_name(TLI_NAMES[lf]) { return -1; }
    let callee = blc_get_or_insert(lf, ty_func_of(rty, [aty], false), globs[glob_of(orig)].attrs);
    let sp = icb_pos; let sb = icb_bb; let sd = icb_dl;
    if is_inst(arg) {
        let nx = inst_next(arg);
        if nx >= 0 { icb_set_insert_point(nx); } else { icb_set_insert_end(inst_parent(arg)); }
        if is_phi_inst(arg) { fatal("LibCallSimplifier: insertSinCosCall after a phi argument is not ported"); }
    } else {
        let eb = func_entry(fv);
        let first = block_first(eb);
        if first >= 0 { icb_set_insert_point(first); } else { icb_set_insert_end(eb); }
    }
    let sc = lcs_create_call(callee, [arg], "sincospi");
    var sinv: i32 = -1;
    var cosv: i32 = -1;
    if ty_is_struct(vals[sc].ty) {
        sinv = icb_extractvalue(sc, 0, "sinpi");
        cosv = icb_extractvalue(sc, 1, "cospi");
    } else {
        sinv = icb_extract_element_k(sc, 0, "sinpi");
        cosv = icb_extract_element_k(sc, 1, "cospi");
    }
    icb_pos = sp; icb_bb = sb; icb_dl = sd;
    for c in sins { ic_replace_inst_uses_with(c, sinv); }
    for c in coss { ic_replace_inst_uses_with(c, cosv); }
    for c in scs { ic_replace_inst_uses_with(c, sc); }
    return if is_sin { sinv } else { cosv };
}

// optimizeRemquo(CI, B)
fn optimize_remquo(ci: i32) -> i32 {
    let x = m_apfloat(cb_arg(ci, 0));
    let y = m_apfloat(cb_arg(ci, 1));
    if x < 0 || y < 0 { return -1; }
    let kind = fp_kind_ty(vals[x].ty);
    let qlo, qhi, okq = fp_divide_status(kind, cint_lo(x), cint_hi(x), cint_lo(y), cint_hi(y));
    if !okq { return -1; }
    let rlo, rhi, okr = fp_remainder_status(kind, cint_lo(x), cint_hi(x), cint_lo(y), cint_hi(y));
    if !okr { return -1; }
    let ib = tli_int_bits();
    let oki, qi = fp_to_int_round(kind, qlo, qhi, ib, FRM_NEAREST_EVEN);
    if !oki { return -1; }
    let st = c_int_ap(ty_int(ib), qi);
    let pa = cb_arg(ci, 2);
    var al = aset_int(cs_aset(ci, 2), AK_Alignment) as i64;
    if al == 0 { al = dl_align(vals[st].ty, true); }
    icb_aligned_store(st, pa, al);
    return c_fp_bits_ty(vals[ci].ty, rlo, rhi);
}
// optimizeFdim(CI, B)
fn optimize_fdim(ci: i32) -> i32 {
    if !call_does_not_access_memory(ci) { return -1; }
    let a0 = cb_arg(ci, 0);
    let a1 = cb_arg(ci, 1);
    if vals[a0].kind == VK_POISON { return a0; }
    if vals[a1].kind == VK_POISON { return a1; }
    let x = m_apfloat(a0);
    let y = m_apfloat(a1);
    if x < 0 || y < 0 { return -1; }
    let kind = fp_kind_ty(vals[x].ty);
    let xn = fp_decompose(kind, cint_lo(x), cint_hi(x)).cat == FC_NAN;
    let yn = fp_decompose(kind, cint_lo(y), cint_hi(y)).cat == FC_NAN;
    if !fp_fcmp(kind, P_OGT, cint_lo(x), cint_hi(x), cint_lo(y), cint_hi(y)) && !xn && !yn {
        return c_fp_bits_ty(vals[ci].ty, 0, 0);
    }
    let dlo, dhi = fp_arith(kind, FOP_SUB, cint_lo(x), cint_hi(x), cint_lo(y), cint_hi(y));
    return c_fp_bits_ty(vals[ci].ty, dlo, dhi);
}
// optimizeNaN(CI): nan("payload")
fn optimize_nan(ci: i32) -> i32 {
    if !get_constant_string_info(cb_arg(ci, 0), true) { return -1; }
    var s: u8[>..<] = [];
    lcs_str_copy(s);
    var f0: u64 = 0;
    var f1: u64 = 0;
    if s.len > 0 {
        // StringRef::getAsInteger(0, APInt): auto-sensed radix, the whole string must be consumed
        var i: i64 = 0;
        var radix: u64 = 10;
        if s.len >= 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X') { radix = 16; i = 2; }
        else if s.len >= 2 && s[0] == '0' && (s[1] == 'b' || s[1] == 'B') { radix = 2; i = 2; }
        else if s.len >= 2 && s[0] == '0' && s[1] == 'o' { radix = 8; i = 2; }
        else if s.len >= 2 && s[0] == '0' && s[1] >= '0' && s[1] <= '9' { radix = 8; i = 1; }
        if i == s.len { return -1; }
        let start = i;
        while i < s.len {
            let c = s[i];
            var cv: u64 = 99;
            if c >= '0' && c <= '9' { cv = (c - '0') as u64; }
            else if c >= 'a' && c <= 'z' { cv = (c - 'a') as u64 + 10; }
            else if c >= 'A' && c <= 'Z' { cv = (c - 'A') as u64 + 10; }
            if cv >= radix { break; }
            // (f1:f0) = (f1:f0) * radix + cv  (mod 2^128; only the low payload bits are kept)
            let lo_lo = (f0 & 0xFFFFFFFF) * radix;
            let lo_hi = (f0 >> 32) * radix;
            let n0 = lo_lo + (lo_hi << 32);
            var carry = (lo_hi >> 32) + (if n0 < lo_lo { 1 } else { 0 });
            f1 = f1 * radix + carry;
            f0 = n0 + cv;
            if f0 < n0 { f1 += 1; }
            carry = 0;
            i++;
        }
        if i == start && start > 0 { return -1; }
        if i == 0 { return -1; }
        if i != s.len { return -1; }
    }
    let ty: i32 = vals[ci].ty;
    let kind = fp_kind_ty(ty);
    let f = fp_fmt(kind);
    // makeNaN(SNaN = false, Negative = false, &Fill)
    let pb = f.p - 1;   // bits to preserve
    var m0 = f0;
    var m1 = f1;
    if pb < 64 { m0 &= ((1 as u64) << pb) - 1; m1 = 0; } else if pb < 128 { m1 &= ((1 as u64) << (pb - 64)) - 1; }
    let qb = f.p - 2;
    if qb < 64 { m0 |= (1 as u64) << qb; } else { m1 |= (1 as u64) << (qb - 64); }
    if kind == TK_X86_FP80 { m0 |= 0x8000000000000000; }
    var lo: u64 = 0;
    var hi: u64 = 0;
    let emax: u64 = (1 << f.ebits) - 1;
    if f.total <= 64 { lo = (emax << pb) | m0; }
    else if kind == TK_X86_FP80 { lo = m0; hi = emax; }
    else { lo = m0; hi = (emax << 48) | m1; }
    return c_fp_bits_ty(ty, lo, hi);
}
