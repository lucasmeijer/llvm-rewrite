// InstCombine x86 target intrinsics, X86TTIImpl::instCombineIntrinsic: port of
// llvm/lib/Target/X86/X86InstCombineIntrinsic.cpp (getNegativeIsTrueBoolVec, getBoolVecFromMask,
// simplifyX86MaskedLoad/Store, simplifyX86immShift, simplifyX86varShift, simplifyX86pack, simplifyX86pmulh,
// simplifyX86pmadd, simplifyX86movmsk, simplifyX86addcarry, simplifyTernarylogic (its switch is the generated
// gen_x86_ternlog.goose, tools/gen_x86_ternlog.py), simplifyX86FPMaxMin, simplifyX86insertps, simplifyX86extrq,
// simplifyX86insertq, simplifyX86pshufb, simplifyX86vpermilvar, simplifyX86vpermv, simplifyX86vpermv3,
// simplifyX86VPERMMask and instCombineIntrinsic's switch). The SimplifyDemanded hooks are in ic_x86.goose.
namespace ic;
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import intrinsics;
import pm;
import apint;
import knownbits;
import fpclass;
import constfold;
import cfold;
import implied;
import ic;
import ic_builder;
import ic_common;
import ic_demanded;
import ic_demanded_elts;
import ic_calls;
import ic_compares;
import gen_x86_ternlog;

fn xi_in(id: i32, ids: const i64[:]) -> bool { for x in ids { if x == id as i64 { return true; } } return false; }
fn xi_is_cint(v: i32) -> bool { vals[v].kind == VK_CINT && !ty_is_vector(vals[v].ty) }
fn xi_is_undef(v: i32) -> bool { vals[v].kind == VK_UNDEF || vals[v].kind == VK_POISON }
// VectorType::getInteger
fn xi_int_vec_ty(t: i32) -> i32 { ty_vector(ty_int(ty_scalar_bits(t)), ty_count(t), false) }

// getNegativeIsTrueBoolVec(V, DL)
fn xi_negative_is_true_bool_vec(v: i32) -> i32 {
    let it = xi_int_vec_ty(vals[v].ty);
    let b = cf_fold_cast_operand(OP_BITCAST, v, it);
    let r = cf_fold_cmp_operands(P_SGT, c_null(it), b, -1);
    if r < 0 { fatal("internal: getNegativeIsTrueBoolVec did not fold"); }
    return r;
}
// getBoolVecFromMask(Mask, DL): -1 = nullptr
fn xi_bool_vec_from_mask(m: i32) -> i32 {
    let k = vals[m].kind;
    if k == VK_CINT || k == VK_CFP || k == VK_CDVECTOR { return xi_negative_is_true_bool_vec(m); }
    if is_inst_op(m, OP_SEXT) {
        let x = op(m, 0);
        if ty_is_int(ty_scalar(vals[x].ty)) && ty_scalar_bits(vals[x].ty) == 1 { return x; }
    }
    return -1;
}
// IRBuilder::CreateMaskedLoad / CreateMaskedStore (CreateIntrinsicWithoutFolding + the align parameter attribute)
fn xi_masked_load(ty: i32, p: i32, al: i64, mask: i32, pass: i32) -> i32 {
    let c = ic_new_intrinsic(IID_masked_load, [ty, vals[p].ty as i32], [p, mask, pass]);
    ic_call_add_param_attr(c, 0, attr_int(AK_Alignment, al as u64));
    return icb_insert(c, "");
}
fn xi_masked_store(v: i32, p: i32, al: i64, mask: i32) -> i32 {
    let c = ic_new_intrinsic(IID_masked_store, [vals[v].ty as i32, vals[p].ty as i32], [v, p, mask]);
    ic_call_add_param_attr(c, 1, attr_int(AK_Alignment, al as u64));
    return icb_insert(c, "");
}

// simplifyX86MaskedLoad(II, IC): an instruction id (the visitor's result) or -1
fn xi_masked_load_fold(ii: i32) -> i32 {
    let p = op(ii, 0);
    let m = op(ii, 1);
    let z = c_null(vals[ii].ty);
    if vals[m].kind == VK_AGGZERO { return ic_replace_inst_uses_with(ii, z); }
    let bm = xi_bool_vec_from_mask(m);
    if bm >= 0 {
        let nl = xi_masked_load(vals[ii].ty, p, 1, bm, z);
        return ic_replace_inst_uses_with(ii, nl);
    }
    return -1;
}
// simplifyX86MaskedStore(II, IC)
fn xi_masked_store_fold(ii: i32) -> bool {
    let p = op(ii, 0);
    let m = op(ii, 1);
    let v = op(ii, 2);
    if vals[m].kind == VK_AGGZERO { ic_erase(ii); return true; }
    if call_iid(ii) == IID_x86_sse2_maskmov_dqu { return false; }
    let bm = xi_bool_vec_from_mask(m);
    if bm >= 0 {
        let pc = icb_bitcast(p, ty_ptr(ptr_as(vals[p].ty)), "castvec");
        xi_masked_store(v, pc, 1, bm);
        ic_erase(ii);
        return true;
    }
    return false;
}

// computeKnownBits(V, DL) / computeKnownBits(V, DemandedElts, DL): no context
fn xi_kb(v: i32) -> KB { kb_cxt = -1; return kb_compute_all(v, 0); }
fn xi_kb_elts(v: i32, de: u64) -> KB { kb_cxt = -1; return kb_compute(v, de, 0); }

fn xi_shift(logical: bool, left: bool, v: i32, amt: i32) -> i32 {
    if !logical { return icb_ashr(v, amt, "", false); }
    if left { return icb_shl(v, amt, ""); }
    return icb_lshr(v, amt, "", false);
}

// simplifyX86immShift(II, Builder)
fn xi_imm_shift(ii: i32) -> i32 {
    let id = call_iid(ii);
    let imm_ra = [IID_x86_sse2_psrai_d, IID_x86_sse2_psrai_w, IID_x86_avx2_psrai_d, IID_x86_avx2_psrai_w,
                  IID_x86_avx512_psrai_q_128, IID_x86_avx512_psrai_q_256, IID_x86_avx512_psrai_d_512,
                  IID_x86_avx512_psrai_q_512, IID_x86_avx512_psrai_w_512];
    let ra = [IID_x86_sse2_psra_d, IID_x86_sse2_psra_w, IID_x86_avx2_psra_d, IID_x86_avx2_psra_w, IID_x86_avx512_psra_q_128,
              IID_x86_avx512_psra_q_256, IID_x86_avx512_psra_d_512, IID_x86_avx512_psra_q_512, IID_x86_avx512_psra_w_512];
    let imm_rl = [IID_x86_sse2_psrli_d, IID_x86_sse2_psrli_q, IID_x86_sse2_psrli_w, IID_x86_avx2_psrli_d,
                  IID_x86_avx2_psrli_q, IID_x86_avx2_psrli_w, IID_x86_avx512_psrli_d_512, IID_x86_avx512_psrli_q_512,
                  IID_x86_avx512_psrli_w_512];
    let rl = [IID_x86_sse2_psrl_d, IID_x86_sse2_psrl_q, IID_x86_sse2_psrl_w, IID_x86_avx2_psrl_d, IID_x86_avx2_psrl_q,
              IID_x86_avx2_psrl_w, IID_x86_avx512_psrl_d_512, IID_x86_avx512_psrl_q_512, IID_x86_avx512_psrl_w_512];
    let imm_ll = [IID_x86_sse2_pslli_d, IID_x86_sse2_pslli_q, IID_x86_sse2_pslli_w, IID_x86_avx2_pslli_d,
                  IID_x86_avx2_pslli_q, IID_x86_avx2_pslli_w, IID_x86_avx512_pslli_d_512, IID_x86_avx512_pslli_q_512,
                  IID_x86_avx512_pslli_w_512];
    var logical = false;
    var left = false;
    var is_imm = false;
    if xi_in(id, imm_ra) { is_imm = true; }
    else if xi_in(id, ra) { }
    else if xi_in(id, imm_rl) { is_imm = true; logical = true; }
    else if xi_in(id, rl) { logical = true; }
    else if xi_in(id, imm_ll) { is_imm = true; logical = true; left = true; }
    else { logical = true; left = true; }
    let vec = cb_arg(ii, 0);
    var amt = cb_arg(ii, 1);
    let vt: i32 = vals[vec].ty;
    let svt = ty_scalar(vt);
    let vw = ty_count(vt);
    let bw = ty_scalar_bits(vt);
    if is_imm {
        let k = xi_kb(amt);
        if ap_ult_u64(kb_max(k), bw as u64) {
            amt = icb_zext_or_trunc(amt, svt, "");
            amt = icb_vector_splat(ty_vector(svt, vw, false), amt, "");
            return xi_shift(logical, left, vec, amt);
        }
        if ap_uge_u64(kb_min(k), bw as u64) {
            if logical { return c_null(vt); }
            let a = c_int_ty(svt, (bw - 1) as u64);
            return icb_ashr(vec, icb_vector_splat(ty_vector(svt, vw, false), a, ""), "", false);
        }
    } else {
        let na = ty_count(vals[amt].ty);
        let dl: u64 = 1;
        var du: u64 = 0;
        for k in 1..na / 2 { du |= (1 as u64) << k; }
        let kl = xi_kb_elts(amt, dl);
        let ku = xi_kb_elts(amt, du);
        if ap_ult_u64(kb_max(kl), bw as u64) && (du == 0 || kb_is_zero_known(ku)) {
            var zs: i32[>..<] = [];
            for k in vw { zs.push(0); }
            amt = icb_shuffle1(amt, zs, "");
            return xi_shift(logical, left, vec, amt);
        }
    }
    if vals[amt].kind != VK_CDVECTOR { return -1; }
    // the 64-bit count from the low sub-elements
    var count = ap_zero(64);
    let nsub = 64 / bw;
    for i in nsub {
        let se = c_aggregate_element(amt, nsub - 1 - i);
        count = ap_shl(count, bw);
        count = ap_or(count, ap_zext_or_trunc(ci_ap(se), 64));
    }
    if ap_is_zero(count) { return vec; }
    if ap_uge_u64(count, bw as u64) {
        if logical { return c_null(vt); }
        count = ap_u64((bw - 1) as u64, 64);
    }
    let sa = c_int_ap(svt, ap_zext_or_trunc(count, bw));
    let sv = icb_vector_splat(ty_vector(svt, vw, false), sa, "");
    return xi_shift(logical, left, vec, sv);
}

// simplifyX86varShift(II, Builder)
fn xi_var_shift(ii: i32) -> i32 {
    let id = call_iid(ii);
    var logical = true;
    var left = false;
    if xi_in(id, [IID_x86_avx2_psrav_d, IID_x86_avx2_psrav_d_256, IID_x86_avx512_psrav_q_128, IID_x86_avx512_psrav_q_256,
                  IID_x86_avx512_psrav_d_512, IID_x86_avx512_psrav_q_512, IID_x86_avx512_psrav_w_128,
                  IID_x86_avx512_psrav_w_256, IID_x86_avx512_psrav_w_512]) { logical = false; }
    else if xi_in(id, [IID_x86_avx2_psllv_d, IID_x86_avx2_psllv_d_256, IID_x86_avx2_psllv_q, IID_x86_avx2_psllv_q_256,
                       IID_x86_avx512_psllv_d_512, IID_x86_avx512_psllv_q_512, IID_x86_avx512_psllv_w_128,
                       IID_x86_avx512_psllv_w_256, IID_x86_avx512_psllv_w_512]) { left = true; }
    let vec = cb_arg(ii, 0);
    let amt = cb_arg(ii, 1);
    let vt: i32 = vals[ii].ty;
    let svt = ty_scalar(vt);
    let n = ty_count(vt);
    let bw = ty_scalar_bits(vt);
    let k = xi_kb(amt);
    if ap_ult_u64(kb_max(k), bw as u64) { return xi_shift(logical, left, vec, amt); }
    if !is_constant(amt) { return -1; }
    var any_oor = false;
    var amts: i64[>..<] = [];
    for i in n {
        let e = c_aggregate_element(amt, i);
        if e >= 0 && xi_is_undef(e) { amts.push(-1); continue; }
        if e < 0 || vals[e].kind != VK_CINT { return -1; }
        let sv = ci_ap(e);
        if ap_uge_u64(sv, bw as u64) {
            any_oor = logical;
            amts.push(if logical { bw } else { bw - 1 });
            continue;
        }
        amts.push(ap_zext64(sv) as i64);
    }
    var all_oor = true;
    for a in amts { if !(a < 0 || bw <= a) { all_oor = false; } }
    if all_oor {
        var cv: i32[>..<] = [];
        for a in amts { if a < 0 { cv.push(c_undef(svt)); } else { cv.push(c_null(svt)); } }
        return c_aggregate(vt, cv);
    }
    if any_oor { return -1; }
    var sva: i32[>..<] = [];
    for a in amts { if a < 0 { sva.push(c_undef(svt)); } else { sva.push(c_int_ty(svt, a as u64)); } }
    let sv = c_aggregate(vt, sva);
    return xi_shift(logical, left, vec, sv);
}

// simplifyX86pack(II, Builder, IsSigned)
fn xi_pack(ii: i32, signed: bool) -> i32 {
    var a0 = cb_arg(ii, 0);
    var a1 = cb_arg(ii, 1);
    let rt: i32 = vals[ii].ty;
    if xi_is_undef(a0) && xi_is_undef(a1) { return c_undef(rt); }
    let at: i32 = vals[a0].ty;
    let nl = ty_count(rt) * ty_scalar_bits(rt) / 128;
    let nse = ty_count(at);
    let nsepl = nse / nl;
    let dbits = ty_scalar_bits(rt);
    let sbits = ty_scalar_bits(at);
    if !is_constant(a0) || !is_constant(a1) { return -1; }
    var mn = ap_zero(sbits);
    var mx = ap_zero(sbits);
    if signed {
        mn = ap_sext(ap_smin_val(dbits), sbits);
        mx = ap_sext(ap_smax_val(dbits), sbits);
    } else {
        mx = ap_low_bits(sbits, dbits);
    }
    let minc = c_int_ap(at, mn);
    let maxc = c_int_ap(at, mx);
    a0 = icb_select(icb_icmp(P_SLT, a0, minc, ""), minc, a0, "", -1);
    a1 = icb_select(icb_icmp(P_SLT, a1, minc, ""), minc, a1, "", -1);
    a0 = icb_select(icb_icmp(P_SGT, a0, maxc, ""), maxc, a0, "", -1);
    a1 = icb_select(icb_icmp(P_SGT, a1, maxc, ""), maxc, a1, "", -1);
    var pm: i32[>..<] = [];
    for lane in nl {
        for e in nsepl { pm.push((e + lane * nsepl) as i32); }
        for e in nsepl { pm.push((e + lane * nsepl + nse) as i32); }
    }
    let sh = icb_shuffle(a0, a1, pm, "");
    return icb_trunc(sh, rt, "");
}

// simplifyX86pmulh(II, Builder, IsSigned, IsRounding)
fn xi_pmulh(ii: i32, signed: bool, rounding: bool) -> i32 {
    let a0 = cb_arg(ii, 0);
    let a1 = cb_arg(ii, 1);
    let rt: i32 = vals[ii].ty;
    if xi_is_undef(a0) || xi_is_undef(a1) { return c_null(rt); }
    if vals[a0].kind == VK_AGGZERO || vals[a1].kind == VK_AGGZERO { return c_null(rt); }
    if !rounding {
        if m_one(a0) { return if signed { icb_ashr(a1, c_int_ty(vals[a1].ty, 15), "", false) } else { c_null(rt) }; }
        if m_one(a1) { return if signed { icb_ashr(a0, c_int_ty(vals[a0].ty, 15), "", false) } else { c_null(rt) }; }
    }
    if !is_constant(a0) || !is_constant(a1) { return -1; }
    let at: i32 = vals[a0].ty;
    let ext = ty_vector(ty_int(2 * ty_scalar_bits(at)), ty_count(at), false);
    let co = if signed { OP_SEXT } else { OP_ZEXT };
    let l = icb_cast(co, a0, ext, "");
    let r = icb_cast(co, a1, ext, "");
    var mul = icb_mul(l, r, "");
    if rounding {
        let rnd = ty_vector(ty_int(18), ty_count(ext), false);
        mul = icb_lshr(mul, c_int_ty(ext, 14), "", false);
        mul = icb_trunc(mul, rnd, "");
        mul = icb_add(mul, c_int_ty(rnd, 1), "");
        mul = icb_lshr(mul, c_int_ty(rnd, 1), "", false);
    } else {
        mul = icb_lshr(mul, c_int_ty(ext, 16), "", false);
    }
    return icb_trunc(mul, rt, "");
}

// simplifyX86pmadd(II, Builder, IsPMADDWD)
fn xi_pmadd(ii: i32, wd: bool) -> i32 {
    let a0 = cb_arg(ii, 0);
    let a1 = cb_arg(ii, 1);
    let rt: i32 = vals[ii].ty;
    let nd = ty_count(rt);
    if xi_is_undef(a0) || xi_is_undef(a1) { return c_null(rt); }
    if vals[a0].kind == VK_AGGZERO || vals[a1].kind == VK_AGGZERO { return c_null(rt); }
    if !is_constant(a0) || !is_constant(a1) { return -1; }
    var lom: i32[>..<] = [];
    var him: i32[>..<] = [];
    for i in nd { lom.push((2 * i) as i32); him.push((2 * i + 1) as i32); }
    var llo = icb_shuffle1(a0, lom, "");
    var lhi = icb_shuffle1(a0, him, "");
    var rlo = icb_shuffle1(a1, lom, "");
    var rhi = icb_shuffle1(a1, him, "");
    let lc = if wd { OP_SEXT } else { OP_ZEXT };
    llo = icb_cast(lc, llo, rt, "");
    lhi = icb_cast(lc, lhi, rt, "");
    rlo = icb_cast(OP_SEXT, rlo, rt, "");
    rhi = icb_cast(OP_SEXT, rhi, rt, "");
    let lo = icb_mul(llo, rlo, "");
    let hi = icb_mul(lhi, rhi, "");
    if wd { return icb_add(lo, hi, ""); }
    return icx_intrinsic_rt(rt, IID_sadd_sat, [lo, hi], "");
}

// simplifyX86movmsk(II, Builder)
fn xi_movmsk(ii: i32) -> i32 {
    let a = cb_arg(ii, 0);
    let rt: i32 = vals[ii].ty;
    if xi_is_undef(a) { return c_null(rt); }
    if call_iid(ii) == IID_x86_mmx_pmovmskb { return -1; }
    let at: i32 = vals[a].ty;
    let n = ty_count(at);
    var r = icb_bitcast(a, xi_int_vec_ty(at), "");
    r = icb_icmp(P_SLT, r, c_null(vals[r].ty), "");
    r = icb_bitcast(r, ty_int(n), "");
    return icb_zext_or_trunc(r, rt, "");
}

// simplifyX86addcarry(II, Builder)
fn xi_addcarry(ii: i32) -> i32 {
    let ci = cb_arg(ii, 0);
    let o1 = cb_arg(ii, 1);
    let o2 = cb_arg(ii, 2);
    let rt: i32 = vals[ii].ty;
    if m_zero_int(ci) {
        let ua = icx_intrinsic_f(IID_uadd_with_overflow, [vals[o1].ty as i32], [o1, o2], icb_fmf, "");
        let r0 = icb_extractvalue(ua, 0, "");
        let ov = icb_zext(icb_extractvalue(ua, 1, ""), T_I8, "");
        var res = c_poison(rt);
        res = icb_insert_value(res, ov, [0], "");
        return icb_insert_value(res, r0, [1], "");
    }
    return -1;
}

// simplifyTernarylogic(II, Builder): the statements of gen_x86_ternlog.goose
var xi_tl_args: i32[3] = [-1, -1, -1];
recursive fn xi_tl_eval(prog: const u8[:], at: i64) -> i32, u8, i64 {
    let c = prog[at];
    let atom = at + 1 == prog.len || prog[at + 1] == ',' || prog[at + 1] == ')';
    if atom && c == 'A' { return xi_tl_args[0], 0xf0, at + 1; }
    if atom && c == 'B' { return xi_tl_args[1], 0xcc, at + 1; }
    if atom && c == 'C' { return xi_tl_args[2], 0xaa, at + 1; }
    // Name(arg[,arg])
    var e = at;
    while prog[e] != '(' { e++; }
    let name = prog[at..e];
    let v1, t1, p1 = xi_tl_eval(prog, e + 1);
    if name == "Not" { return icb_not(v1, ""), ~t1, p1 + 1; }
    let v2, t2, p2 = xi_tl_eval(prog, p1 + 1);
    let np = p2 + 1;
    if name == "Or" { return icb_or(v1, v2, ""), t1 | t2, np; }
    if name == "Xor" { return icb_xor(v1, v2, ""), t1 ^ t2, np; }
    if name == "And" { return icb_and(v1, v2, ""), t1 & t2, np; }
    if name == "Nor" { return icb_not(icb_or(v1, v2, ""), ""), ~(t1 | t2), np; }
    if name == "Xnor" { return icb_not(icb_xor(v1, v2, ""), ""), ~(t1 ^ t2), np; }
    if name == "Nand" { return icb_not(icb_and(v1, v2, ""), ""), ~(t1 & t2), np; }
    fatal(str("internal: simplifyTernarylogic operation ", name));
    return -1, 0, np;
}
fn xi_ternlog(ii: i32) -> i32 {
    let ai = cb_arg(ii, 3);
    if !xi_is_cint(ai) || ap_uge_u64(ci_ap(ai), 256) { return -1; }
    xi_tl_args[0] = cb_arg(ii, 0);
    xi_tl_args[1] = cb_arg(ii, 1);
    xi_tl_args[2] = cb_arg(ii, 2);
    let ac = m_imm_constant(xi_tl_args[0]);
    let bc = m_imm_constant(xi_tl_args[1]);
    let cc = m_imm_constant(xi_tl_args[2]);
    let imm = ap_zext64(ci_ap(ai));
    let prog = X86_TERNLOG[imm];
    let ty: i32 = vals[ii].ty;
    var res: i32 = -1;
    var tt: u8 = 0;
    var st: i64 = 0;
    for j in 0..prog.len + 1 {
        if j < prog.len && prog[j] != ';' { continue; }
        let stmt = prog[st..j];
        st = j + 1;
        var colon: i64 = 0;
        while stmt[colon] != ':' { colon++; }
        let cond = stmt[..colon];
        var ok = true;
        for c in cond {
            if c == 'A' && !ac { ok = false; }
            if c == 'B' && !bc { ok = false; }
            if c == 'C' && !cc { ok = false; }
        }
        if !ok { continue; }
        let e = stmt[colon + 1..];
        if e == "0" { res = c_null(ty); tt = 0; continue; }
        if e == "1" { res = c_all_ones(ty); tt = 0xff; continue; }
        let v, t, _p = xi_tl_eval(e, 0);
        res = v;
        tt = t;
    }
    if res >= 0 && tt as u64 != imm { fatal("internal: simplifyTernarylogic does not verify"); }
    return res;
}

// simplifyX86FPMaxMin(II, IC, NewIID, IsScalar)
fn xi_fp_maxmin(ii: i32, nid: i64, scalar: bool) -> i32 {
    let a0 = cb_arg(ii, 0);
    let a1 = cb_arg(ii, 1);
    let vw = ty_count(vals[a0].ty);
    let de: u64 = if scalar { 1 } else if vw >= 64 { 0xFFFFFFFFFFFFFFFF } else { ((1 as u64) << vw) - 1 };
    var f0 = FCL_NAN | FCL_INF | FCL_SUBNORMAL;
    var f1 = FCL_NAN | FCL_INF | FCL_SUBNORMAL;
    if nid == IID_maxnum { f1 |= FCL_NEG_ZERO; } else { f0 |= FCL_NEG_ZERO; }
    kb_cxt = ii;
    let k0 = kfc_compute(a0, de, f0, 0);
    kb_cxt = ii;
    let k1 = kfc_compute(a1, de, f1, 0);
    if kfc_never(k0, f0) && kfc_never(k1, f1) {
        if scalar {
            let s0 = icb_extract_element_k(a0, 0, "");
            let s1 = icb_extract_element_k(a1, 0, "");
            let ns = icx_binary_intrinsic_f(nid, s0, s1, icb_fmf, "");
            return icb_insert_element_k(a0, ns, 0, "");
        }
        return icx_binary_intrinsic_f(nid, a0, a1, icb_fmf, "");
    }
    return -1;
}

// simplifyX86insertps(II, Builder)
fn xi_insertps(ii: i32) -> i32 {
    let ci = cb_arg(ii, 2);
    if !xi_is_cint(ci) { return -1; }
    let vt: i32 = vals[ii].ty;
    let imm = ap_zext64(ci_ap(ci)) & 0xFF;
    let zm = imm & 0xf;
    let dl = ((imm >> 4) & 3) as i64;
    let sl = ((imm >> 6) & 3) as i32;
    let zv = c_null(vt);
    if zm == 0xf { return zv; }
    var sm: i32[4] = [0, 1, 2, 3];
    var v1 = cb_arg(ii, 1);
    if zm != 0 {
        if cb_arg(ii, 0) == cb_arg(ii, 1) || (zm & ((1 as u64) << dl)) != 0 {
            v1 = zv;
            sm[dl] = sl;
            for i in 4 { if ((zm >> i) & 1) != 0 { sm[i] = (i + 4) as i32; } }
        } else { return -1; }
    } else {
        sm[dl] = sl + 4;
    }
    return icb_shuffle(cb_arg(ii, 0), v1, sm, "");
}

// LowConstantHighUndef(Val)
fn xi_low_const_high_undef(v: u64) -> i32 {
    let t = ty_int(64);
    return c_aggregate(ty_vector(t, 2, false), [c_int_ty(t, v), c_undef(t)]);
}
// getAggregateElement(0/1) as a ConstantInt (-1 = none)
fn xi_elt_cint(c: i32, k: i64) -> i32 {
    if c < 0 || !is_constant(c) { return -1; }
    let e = c_aggregate_element(c, k);
    if e < 0 || vals[e].kind != VK_CINT { return -1; }
    return e;
}
// simplifyX86extrq(II, Op0, CILength, CIIndex, Builder)
fn xi_extrq(ii: i32, op0: i32, cil: i32, cii: i32) -> i32 {
    let ci0 = xi_elt_cint(op0, 0);
    if cil >= 0 && cii >= 0 {
        let index = ap_zext64(ap_zext_or_trunc(ci_ap(cii), 6)) as i64;
        let apl = ap_zext64(ap_zext_or_trunc(ci_ap(cil), 6)) as i64;
        var length = if apl == 0 { 64 } else { apl };
        let end = index + length;
        if end > 64 { return c_undef(vals[ii].ty); }
        if length % 8 == 0 && index % 8 == 0 {
            length /= 8;
            let idx = index / 8;
            let st = ty_vector(T_I8, 16, false);
            var sm: i32[>..<] = [];
            for i in length { sm.push((i + idx) as i32); }
            for i in length..8 { sm.push((i + 16) as i32); }
            for i in 8..16 { sm.push(-1); }
            let sv = icb_shuffle(icb_bitcast(op0, st, ""), c_null(st), sm, "");
            return icb_bitcast(sv, vals[ii].ty, "");
        }
        if ci0 >= 0 {
            var elt = ci_ap(ci0);
            elt = ap_lshr(elt, index);
            elt = ap_zext_or_trunc(elt, length);
            return xi_low_const_high_undef(ap_zext64(elt));
        }
        if call_iid(ii) == IID_x86_sse4a_extrq {
            return icx_intrinsic_f(IID_x86_sse4a_extrqi, [], [op0, cil, cii], icb_fmf, "");
        }
    }
    if ci0 >= 0 && ap_is_zero(ci_ap(ci0)) { return xi_low_const_high_undef(0); }
    return -1;
}
// simplifyX86insertq(II, Op0, Op1, APLength, APIndex, Builder)
fn xi_insertq(ii: i32, op0: i32, op1: i32, apl0: AP, api0: AP) -> i32 {
    let index = ap_zext64(ap_zext_or_trunc(api0, 6)) as i64;
    let apl = ap_zext64(ap_zext_or_trunc(apl0, 6)) as i64;
    var length = if apl == 0 { 64 } else { apl };
    let end = index + length;
    if end > 64 { return c_undef(vals[ii].ty); }
    if length % 8 == 0 && index % 8 == 0 {
        let ln = length / 8;
        let ix = index / 8;
        let st = ty_vector(T_I8, 16, false);
        var sm: i32[>..<] = [];
        for i in ix { sm.push(i as i32); }
        for i in ln { sm.push((i + 16) as i32); }
        for i in ix + ln..8 { sm.push(i as i32); }
        for i in 8..16 { sm.push(-1); }
        let sv = icb_shuffle(icb_bitcast(op0, st, ""), icb_bitcast(op1, st, ""), sm, "");
        return icb_bitcast(sv, vals[ii].ty, "");
    }
    let ci00 = xi_elt_cint(op0, 0);
    let ci10 = xi_elt_cint(op1, 0);
    if ci00 >= 0 && ci10 >= 0 {
        var v00 = ci_ap(ci00);
        var v10 = ci_ap(ci10);
        let mask = ap_shl(ap_low_bits(64, length), index);
        v00 = ap_and(v00, ap_not(mask));
        v10 = ap_shl(ap_zext_or_trunc(ap_zext_or_trunc(v10, length), 64), index);
        let val = ap_or(v00, v10);
        return xi_low_const_high_undef(ap_zext64(val));
    }
    if call_iid(ii) == IID_x86_sse4a_insertq {
        let cl = c_int(T_I8, length);
        let ci = c_int(T_I8, index);
        return icx_intrinsic_f(IID_x86_sse4a_insertqi, [], [op0, op1, cl, ci], icb_fmf, "");
    }
    return -1;
}

// the shuffle mask of a constant control vector (undef -> -1); false if an element is neither
fn xi_const_mask_elts(v: i32, n: i64, out: i64[>..<]&) -> bool {
    out.clear();
    for i in n {
        let e = c_aggregate_element(v, i);
        if e < 0 || (!xi_is_undef(e) && vals[e].kind != VK_CINT) { return false; }
        if xi_is_undef(e) { out.push(-1); continue; }
        out.push(-2 - (i as i64));   // placeholder: the caller reads the element itself
    }
    return true;
}
// simplifyX86pshufb(II, Builder)
fn xi_pshufb(ii: i32) -> i32 {
    let v = cb_arg(ii, 1);
    if !is_constant(v) { return -1; }
    let vt: i32 = vals[ii].ty;
    let n = ty_count(vt);
    var idx: i32[>..<] = [];
    for i in n {
        let e = c_aggregate_element(v, i);
        if e < 0 || (!xi_is_undef(e) && vals[e].kind != VK_CINT) { return -1; }
        if xi_is_undef(e) { idx.push(-1); continue; }
        let b = (ap_zext64(ci_ap(e)) & 0xFF) as i64;
        let neg = b >= 128;
        let x = (if neg { n } else { b & 0x0F }) + (i & 0xF0);
        // int8_t Index: the sum is stored back into an int8_t
        var x8 = x & 0xFF;
        if x8 >= 128 { x8 -= 256; }
        idx.push(x8 as i32);
    }
    return icb_shuffle(cb_arg(ii, 0), c_null(vt), idx, "");
}
// simplifyX86vpermilvar(II, Builder)
fn xi_vpermilvar(ii: i32) -> i32 {
    let v = cb_arg(ii, 1);
    if !is_constant(v) { return -1; }
    let vt: i32 = vals[ii].ty;
    let n = ty_count(vt);
    let pd = ty_kind(ty_scalar(vt)) == TK_DOUBLE;
    let nle: i64 = if pd { 2 } else { 4 };
    var idx: i32[>..<] = [];
    for i in n {
        let e = c_aggregate_element(v, i);
        if e < 0 || (!xi_is_undef(e) && vals[e].kind != VK_CINT) { return -1; }
        if xi_is_undef(e) { idx.push(-1); continue; }
        var x = (ap_zext64(ap_zext_or_trunc(ci_ap(e), 32)) & 3) as i64;
        if pd { x = x >> 1; }
        x += (i / nle) * nle;
        idx.push(x as i32);
    }
    return icb_shuffle1(cb_arg(ii, 0), idx, "");
}
// simplifyX86vpermv(II, Builder) / simplifyX86vpermv3
fn xi_vpermv(ii: i32, binary: bool) -> i32 {
    let v = cb_arg(ii, 1);
    if !is_constant(v) { return -1; }
    let vt: i32 = vals[ii].ty;
    let n = ty_count(vt);
    let m: u64 = if binary { (2 * n - 1) as u64 } else { (n - 1) as u64 };
    var idx: i32[>..<] = [];
    for i in n {
        let e = c_aggregate_element(v, i);
        if e < 0 || (!xi_is_undef(e) && vals[e].kind != VK_CINT) { return -1; }
        if xi_is_undef(e) { idx.push(-1); continue; }
        let x = (ap_zext64(ci_ap(e)) & 0xFFFFFFFF) & m;
        idx.push(x as i32);
    }
    if binary { return icb_shuffle(cb_arg(ii, 0), cb_arg(ii, 2), idx, ""); }
    return icb_shuffle1(cb_arg(ii, 0), idx, "");
}
// IC.SimplifyDemandedBits(&II, OpNo, Mask, Known)
fn xi_sdb(ii: i32, k: i64, mask: AP) -> bool {
    let saved = sd_cxt;
    sd_cxt = ii;
    let ch, _kn = sd_bits(ii, k, mask, 0);
    sd_cxt = saved;
    return ch;
}
// simplifyX86VPERMMask(II, IsBinary, IC)
fn xi_vperm_mask(ii: i32, binary: bool) -> bool {
    let vt: i32 = vals[ii].ty;
    let eb = ty_scalar_bits(vt);
    let n = ty_count(vt);
    var isz: i64 = 0;
    let m = if binary { 2 * n } else { n };
    while ((1 as i64) << (isz + 1)) <= m { isz++; }
    return xi_sdb(ii, 1, ap_low_bits(eb, isz));
}

// SimplifyDemandedVectorEltsLow(Op, Width, DemandedWidth)
fn xi_sdve_low(v: i32, w: i64, dw: i64) -> i32 {
    let r, _pe = ic_simplify_demanded_vector_elts(v, ap_low_bits(w, dw), 0, false);
    return r;
}

// X86TTIImpl::instCombineIntrinsic(IC, II): (result, handled)
fn x86_inst_combine_intrinsic_impl(ii: i32) -> i32, bool {
    let id = call_iid(ii);
    let ity: i32 = vals[ii].ty;
    if xi_in(id, [IID_x86_bmi_bextr_32, IID_x86_bmi_bextr_64, IID_x86_tbm_bextri_u32, IID_x86_tbm_bextri_u64]) {
        let c = cb_arg(ii, 1);
        if xi_is_cint(c) {
            var shift = ap_zext64(ci_ap(c));
            var length = (shift >> 8) & 0xff;
            shift &= 0xff;
            let bw = ty_bits(ity) as u64;
            if length == 0 || shift >= bw { return ic_replace_inst_uses_with(ii, c_int_ty(ity, 0)), true; }
            let inc = cb_arg(ii, 0);
            if xi_is_cint(inc) {
                var r = ap_zext64(ci_ap(inc)) >> shift;
                if length > bw { length = bw; }
                if length < 64 { r &= ((1 as u64) << length) - 1; }
                return ic_replace_inst_uses_with(ii, c_int_ty(ity, r)), true;
            }
        }
        return -1, false;
    }
    if id == IID_x86_bmi_bzhi_32 || id == IID_x86_bmi_bzhi_64 {
        let c = cb_arg(ii, 1);
        if xi_is_cint(c) {
            let index = ap_zext64(ci_ap(c)) & 0xff;
            let bw = ty_bits(ity) as u64;
            if index >= bw { return ic_replace_inst_uses_with(ii, cb_arg(ii, 0)), true; }
            if index == 0 { return ic_replace_inst_uses_with(ii, c_int_ty(ity, 0)), true; }
            let inc = cb_arg(ii, 0);
            if xi_is_cint(inc) {
                var r = ap_zext64(ci_ap(inc));
                if index < 64 { r &= ((1 as u64) << index) - 1; }
                return ic_replace_inst_uses_with(ii, c_int_ty(ity, r)), true;
            }
        }
        return -1, false;
    }
    if xi_in(id, [IID_x86_sse_cvtss2si, IID_x86_sse_cvtss2si64, IID_x86_sse_cvttss2si, IID_x86_sse_cvttss2si64,
                  IID_x86_sse2_cvtsd2si, IID_x86_sse2_cvtsd2si64, IID_x86_sse2_cvttsd2si, IID_x86_sse2_cvttsd2si64,
                  IID_x86_avx512_vcvtss2si32, IID_x86_avx512_vcvtss2si64, IID_x86_avx512_vcvtss2usi32,
                  IID_x86_avx512_vcvtss2usi64, IID_x86_avx512_vcvtsd2si32, IID_x86_avx512_vcvtsd2si64,
                  IID_x86_avx512_vcvtsd2usi32, IID_x86_avx512_vcvtsd2usi64, IID_x86_avx512_cvttss2si,
                  IID_x86_avx512_cvttss2si64, IID_x86_avx512_cvttss2usi, IID_x86_avx512_cvttss2usi64,
                  IID_x86_avx512_cvttsd2si, IID_x86_avx512_cvttsd2si64, IID_x86_avx512_cvttsd2usi,
                  IID_x86_avx512_cvttsd2usi64]) {
        let a = cb_arg(ii, 0);
        let v = xi_sdve_low(a, ty_count(vals[a].ty), 1);
        if v >= 0 { return ic_replace_operand(ii, 0, v), true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_mmx_pmovmskb, IID_x86_sse_movmsk_ps, IID_x86_sse2_movmsk_pd, IID_x86_sse2_pmovmskb_128,
                  IID_x86_avx_movmsk_pd_256, IID_x86_avx_movmsk_ps_256, IID_x86_avx2_pmovmskb]) {
        let v = xi_movmsk(ii);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_sse_comieq_ss, IID_x86_sse_comige_ss, IID_x86_sse_comigt_ss, IID_x86_sse_comile_ss,
                  IID_x86_sse_comilt_ss, IID_x86_sse_comineq_ss, IID_x86_sse_ucomieq_ss, IID_x86_sse_ucomige_ss,
                  IID_x86_sse_ucomigt_ss, IID_x86_sse_ucomile_ss, IID_x86_sse_ucomilt_ss, IID_x86_sse_ucomineq_ss,
                  IID_x86_sse2_comieq_sd, IID_x86_sse2_comige_sd, IID_x86_sse2_comigt_sd, IID_x86_sse2_comile_sd,
                  IID_x86_sse2_comilt_sd, IID_x86_sse2_comineq_sd, IID_x86_sse2_ucomieq_sd, IID_x86_sse2_ucomige_sd,
                  IID_x86_sse2_ucomigt_sd, IID_x86_sse2_ucomile_sd, IID_x86_sse2_ucomilt_sd, IID_x86_sse2_ucomineq_sd,
                  IID_x86_avx512_vcomi_ss, IID_x86_avx512_vcomi_sd, IID_x86_avx512_mask_cmp_ss,
                  IID_x86_avx512_mask_cmp_sd]) {
        var changed = false;
        let a0 = cb_arg(ii, 0);
        let a1 = cb_arg(ii, 1);
        let vw = ty_count(vals[a0].ty);
        let v0 = xi_sdve_low(a0, vw, 1);
        if v0 >= 0 { ic_replace_operand(ii, 0, v0); changed = true; }
        let v1 = xi_sdve_low(a1, vw, 1);
        if v1 >= 0 { ic_replace_operand(ii, 1, v1); changed = true; }
        if changed { return ii, true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_avx512_add_ps_512, IID_x86_avx512_div_ps_512, IID_x86_avx512_mul_ps_512,
                  IID_x86_avx512_sub_ps_512, IID_x86_avx512_add_pd_512, IID_x86_avx512_div_pd_512,
                  IID_x86_avx512_mul_pd_512, IID_x86_avx512_sub_pd_512]) {
        let r = cb_arg(ii, 2);
        if xi_is_cint(r) && ap_zext64(ci_ap(r)) == 4 && ap_active_bits(ci_ap(r)) <= 3 {
            let a0 = cb_arg(ii, 0);
            let a1 = cb_arg(ii, 1);
            var o = OP_FDIV;
            if id == IID_x86_avx512_add_ps_512 || id == IID_x86_avx512_add_pd_512 { o = OP_FADD; }
            else if id == IID_x86_avx512_sub_ps_512 || id == IID_x86_avx512_sub_pd_512 { o = OP_FSUB; }
            else if id == IID_x86_avx512_mul_ps_512 || id == IID_x86_avx512_mul_pd_512 { o = OP_FMUL; }
            let v = icx_fbinop(o, a0, a1, icb_fmf, "");
            return ic_replace_inst_uses_with(ii, v), true;
        }
        return -1, false;
    }
    if xi_in(id, [IID_x86_avx512_mask_add_ss_round, IID_x86_avx512_mask_div_ss_round, IID_x86_avx512_mask_mul_ss_round,
                  IID_x86_avx512_mask_sub_ss_round, IID_x86_avx512_mask_add_sd_round, IID_x86_avx512_mask_div_sd_round,
                  IID_x86_avx512_mask_mul_sd_round, IID_x86_avx512_mask_sub_sd_round]) {
        let r = cb_arg(ii, 4);
        if xi_is_cint(r) && ap_zext64(ci_ap(r)) == 4 && ap_active_bits(ci_ap(r)) <= 3 {
            let a0 = cb_arg(ii, 0);
            let a1 = cb_arg(ii, 1);
            let l = icb_extract_element_k(a0, 0, "");
            let rr = icb_extract_element_k(a1, 0, "");
            var o = OP_FDIV;
            if id == IID_x86_avx512_mask_add_ss_round || id == IID_x86_avx512_mask_add_sd_round { o = OP_FADD; }
            else if id == IID_x86_avx512_mask_sub_ss_round || id == IID_x86_avx512_mask_sub_sd_round { o = OP_FSUB; }
            else if id == IID_x86_avx512_mask_mul_ss_round || id == IID_x86_avx512_mask_mul_sd_round { o = OP_FMUL; }
            var v = icx_fbinop(o, l, rr, icb_fmf, "");
            var mask = cb_arg(ii, 3);
            if !xi_is_cint(mask) || !ap_get_bit(ci_ap(mask), 0) {
                let mt = ty_vector(T_I1, ty_bits(vals[mask].ty), false);
                mask = icb_bitcast(mask, mt, "");
                mask = icb_extract_element_k(mask, 0, "");
                let pt = icb_extract_element_k(cb_arg(ii, 2), 0, "");
                v = icb_select(mask, v, pt, "", -1);
            }
            v = icb_insert_element_k(a0, v, 0, "");
            return ic_replace_inst_uses_with(ii, v), true;
        }
        return -1, false;
    }
    if xi_in(id, [IID_x86_sse_max_ps, IID_x86_sse2_max_pd, IID_x86_avx_max_pd_256, IID_x86_avx_max_ps_256,
                  IID_x86_avx512_max_pd_512, IID_x86_avx512_max_ps_512, IID_x86_avx512fp16_max_ph_128,
                  IID_x86_avx512fp16_max_ph_256, IID_x86_avx512fp16_max_ph_512]) {
        let v = xi_fp_maxmin(ii, IID_maxnum, false);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        return -1, false;
    }
    if id == IID_x86_sse_max_ss || id == IID_x86_sse2_max_sd {
        let v = xi_fp_maxmin(ii, IID_maxnum, true);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_sse_min_ps, IID_x86_sse2_min_pd, IID_x86_avx_min_pd_256, IID_x86_avx_min_ps_256,
                  IID_x86_avx512_min_pd_512, IID_x86_avx512_min_ps_512, IID_x86_avx512fp16_min_ph_128,
                  IID_x86_avx512fp16_min_ph_256, IID_x86_avx512fp16_min_ph_512]) {
        let v = xi_fp_maxmin(ii, IID_minnum, false);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        return -1, false;
    }
    if id == IID_x86_sse_min_ss || id == IID_x86_sse2_min_sd {
        let v = xi_fp_maxmin(ii, IID_minnum, true);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_sse2_psrai_d, IID_x86_sse2_psrai_w, IID_x86_avx2_psrai_d, IID_x86_avx2_psrai_w,
                  IID_x86_avx512_psrai_q_128, IID_x86_avx512_psrai_q_256, IID_x86_avx512_psrai_d_512,
                  IID_x86_avx512_psrai_q_512, IID_x86_avx512_psrai_w_512, IID_x86_sse2_psrli_d, IID_x86_sse2_psrli_q,
                  IID_x86_sse2_psrli_w, IID_x86_avx2_psrli_d, IID_x86_avx2_psrli_q, IID_x86_avx2_psrli_w,
                  IID_x86_avx512_psrli_d_512, IID_x86_avx512_psrli_q_512, IID_x86_avx512_psrli_w_512,
                  IID_x86_sse2_pslli_d, IID_x86_sse2_pslli_q, IID_x86_sse2_pslli_w, IID_x86_avx2_pslli_d,
                  IID_x86_avx2_pslli_q, IID_x86_avx2_pslli_w, IID_x86_avx512_pslli_d_512, IID_x86_avx512_pslli_q_512,
                  IID_x86_avx512_pslli_w_512]) {
        let v = xi_imm_shift(ii);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_sse2_psra_d, IID_x86_sse2_psra_w, IID_x86_avx2_psra_d, IID_x86_avx2_psra_w,
                  IID_x86_avx512_psra_q_128, IID_x86_avx512_psra_q_256, IID_x86_avx512_psra_d_512,
                  IID_x86_avx512_psra_q_512, IID_x86_avx512_psra_w_512, IID_x86_sse2_psrl_d, IID_x86_sse2_psrl_q,
                  IID_x86_sse2_psrl_w, IID_x86_avx2_psrl_d, IID_x86_avx2_psrl_q, IID_x86_avx2_psrl_w,
                  IID_x86_avx512_psrl_d_512, IID_x86_avx512_psrl_q_512, IID_x86_avx512_psrl_w_512, IID_x86_sse2_psll_d,
                  IID_x86_sse2_psll_q, IID_x86_sse2_psll_w, IID_x86_avx2_psll_d, IID_x86_avx2_psll_q,
                  IID_x86_avx2_psll_w, IID_x86_avx512_psll_d_512, IID_x86_avx512_psll_q_512,
                  IID_x86_avx512_psll_w_512]) {
        let v = xi_imm_shift(ii);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        let a1 = cb_arg(ii, 1);
        let vw = ty_count(vals[a1].ty);
        let v2 = xi_sdve_low(a1, vw, vw / 2);
        if v2 >= 0 { return ic_replace_operand(ii, 1, v2), true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_avx2_psllv_d, IID_x86_avx2_psllv_d_256, IID_x86_avx2_psllv_q, IID_x86_avx2_psllv_q_256,
                  IID_x86_avx512_psllv_d_512, IID_x86_avx512_psllv_q_512, IID_x86_avx512_psllv_w_128,
                  IID_x86_avx512_psllv_w_256, IID_x86_avx512_psllv_w_512, IID_x86_avx2_psrav_d,
                  IID_x86_avx2_psrav_d_256, IID_x86_avx512_psrav_q_128, IID_x86_avx512_psrav_q_256,
                  IID_x86_avx512_psrav_d_512, IID_x86_avx512_psrav_q_512, IID_x86_avx512_psrav_w_128,
                  IID_x86_avx512_psrav_w_256, IID_x86_avx512_psrav_w_512, IID_x86_avx2_psrlv_d,
                  IID_x86_avx2_psrlv_d_256, IID_x86_avx2_psrlv_q, IID_x86_avx2_psrlv_q_256, IID_x86_avx512_psrlv_d_512,
                  IID_x86_avx512_psrlv_q_512, IID_x86_avx512_psrlv_w_128, IID_x86_avx512_psrlv_w_256,
                  IID_x86_avx512_psrlv_w_512]) {
        let v = xi_var_shift(ii);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_sse2_packssdw_128, IID_x86_sse2_packsswb_128, IID_x86_avx2_packssdw, IID_x86_avx2_packsswb,
                  IID_x86_avx512_packssdw_512, IID_x86_avx512_packsswb_512]) {
        let v = xi_pack(ii, true);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_sse2_packuswb_128, IID_x86_sse41_packusdw, IID_x86_avx2_packusdw, IID_x86_avx2_packuswb,
                  IID_x86_avx512_packusdw_512, IID_x86_avx512_packuswb_512]) {
        let v = xi_pack(ii, false);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_sse2_pmulh_w, IID_x86_avx2_pmulh_w, IID_x86_avx512_pmulh_w_512]) {
        let v = xi_pmulh(ii, true, false);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_sse2_pmulhu_w, IID_x86_avx2_pmulhu_w, IID_x86_avx512_pmulhu_w_512]) {
        let v = xi_pmulh(ii, false, false);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_ssse3_pmul_hr_sw_128, IID_x86_avx2_pmul_hr_sw, IID_x86_avx512_pmul_hr_sw_512]) {
        let v = xi_pmulh(ii, true, true);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_sse2_pmadd_wd, IID_x86_avx2_pmadd_wd, IID_x86_avx512_pmaddw_d_512]) {
        let v = xi_pmadd(ii, true);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_ssse3_pmadd_ub_sw_128, IID_x86_avx2_pmadd_ub_sw, IID_x86_avx512_pmaddubs_w_512]) {
        let v = xi_pmadd(ii, false);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_pclmulqdq, IID_x86_pclmulqdq_256, IID_x86_pclmulqdq_512]) {
        let c = cb_arg(ii, 2);
        if xi_is_cint(c) {
            let imm = ap_zext64(ci_ap(c));
            var changed = false;
            let a0 = cb_arg(ii, 0);
            let a1 = cb_arg(ii, 1);
            let vw = ty_count(vals[a0].ty);
            let d1 = ap_splat(vw, ap_u64(if (imm & 0x01) != 0 { 2 } else { 1 }, 2));
            let v1, u1 = ic_simplify_demanded_vector_elts(a0, d1, 0, false);
            if v1 >= 0 { ic_replace_operand(ii, 0, v1); changed = true; }
            let d2 = ap_splat(vw, ap_u64(if (imm & 0x10) != 0 { 2 } else { 1 }, 2));
            let v2, u2 = ic_simplify_demanded_vector_elts(cb_arg(ii, 1), d2, 0, false);
            if v2 >= 0 { ic_replace_operand(ii, 1, v2); changed = true; }
            if ap_is_subset_of(d1, u1) || ap_is_subset_of(d2, u2) {
                return ic_replace_inst_uses_with(ii, c_null(ity)), true;
            }
            if changed { return ii, true; }
        }
        return -1, false;
    }
    if id == IID_x86_sse41_insertps {
        let v = xi_insertps(ii);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        return -1, false;
    }
    if id == IID_x86_sse4a_extrq {
        let o0 = cb_arg(ii, 0);
        let o1 = cb_arg(ii, 1);
        let w0 = ty_count(vals[o0].ty);
        let w1 = ty_count(vals[o1].ty);
        let cl = xi_elt_cint(o1, 0);
        let cx = xi_elt_cint(o1, 1);
        let v = xi_extrq(ii, o0, cl, cx);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        var changed = false;
        let v0 = xi_sdve_low(o0, w0, 1);
        if v0 >= 0 { ic_replace_operand(ii, 0, v0); changed = true; }
        let v1 = xi_sdve_low(o1, w1, 2);
        if v1 >= 0 { ic_replace_operand(ii, 1, v1); changed = true; }
        if changed { return ii, true; }
        return -1, false;
    }
    if id == IID_x86_sse4a_extrqi {
        let o0 = cb_arg(ii, 0);
        let vw = ty_count(vals[o0].ty);
        let cl = if xi_is_cint(cb_arg(ii, 1)) { cb_arg(ii, 1) } else { -1 };
        let cx = if xi_is_cint(cb_arg(ii, 2)) { cb_arg(ii, 2) } else { -1 };
        let v = xi_extrq(ii, o0, cl, cx);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        let v0 = xi_sdve_low(o0, vw, 1);
        if v0 >= 0 { return ic_replace_operand(ii, 0, v0), true; }
        return -1, false;
    }
    if id == IID_x86_sse4a_insertq {
        let o0 = cb_arg(ii, 0);
        let o1 = cb_arg(ii, 1);
        let vw = ty_count(vals[o0].ty);
        let c11 = xi_elt_cint(o1, 1);
        if c11 >= 0 {
            let v11 = ci_ap(c11);
            let len = ap_zext_or_trunc(v11, 6);
            let idx = ap_zext_or_trunc(ap_lshr(v11, 8), 6);
            let v = xi_insertq(ii, o0, o1, len, idx);
            if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        }
        let v0 = xi_sdve_low(o0, vw, 1);
        if v0 >= 0 { return ic_replace_operand(ii, 0, v0), true; }
        return -1, false;
    }
    if id == IID_x86_sse4a_insertqi {
        let o0 = cb_arg(ii, 0);
        let o1 = cb_arg(ii, 1);
        let w0 = ty_count(vals[o0].ty);
        let w1 = ty_count(vals[o1].ty);
        let cl = cb_arg(ii, 2);
        let cx = cb_arg(ii, 3);
        if xi_is_cint(cl) && xi_is_cint(cx) {
            let v = xi_insertq(ii, o0, o1, ap_zext_or_trunc(ci_ap(cl), 6), ap_zext_or_trunc(ci_ap(cx), 6));
            if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        }
        var changed = false;
        let v0 = xi_sdve_low(o0, w0, 1);
        if v0 >= 0 { ic_replace_operand(ii, 0, v0); changed = true; }
        let v1 = xi_sdve_low(o1, w1, 1);
        if v1 >= 0 { ic_replace_operand(ii, 1, v1); changed = true; }
        if changed { return ii, true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_sse41_pblendvb, IID_x86_sse41_blendvps, IID_x86_sse41_blendvpd, IID_x86_avx_blendv_ps_256,
                  IID_x86_avx_blendv_pd_256, IID_x86_avx2_pblendvb]) {
        return xi_blendv(ii);
    }
    if xi_in(id, [IID_x86_ssse3_pshuf_b_128, IID_x86_avx2_pshuf_b, IID_x86_avx512_pshuf_b_512]) {
        let v = xi_pshufb(ii);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        if xi_sdb(ii, 1, ap_u64(0x8F, 8)) { return ii, true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_avx_vpermilvar_ps, IID_x86_avx_vpermilvar_ps_256, IID_x86_avx512_vpermilvar_ps_512]) {
        let v = xi_vpermilvar(ii);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        if xi_sdb(ii, 1, ap_u64(3, 32)) { return ii, true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_avx_vpermilvar_pd, IID_x86_avx_vpermilvar_pd_256, IID_x86_avx512_vpermilvar_pd_512]) {
        let v = xi_vpermilvar(ii);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        if xi_sdb(ii, 1, ap_u64(2, 64)) { return ii, true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_avx2_permd, IID_x86_avx2_permps, IID_x86_avx512_permvar_df_256, IID_x86_avx512_permvar_df_512,
                  IID_x86_avx512_permvar_di_256, IID_x86_avx512_permvar_di_512, IID_x86_avx512_permvar_hi_128,
                  IID_x86_avx512_permvar_hi_256, IID_x86_avx512_permvar_hi_512, IID_x86_avx512_permvar_qi_128,
                  IID_x86_avx512_permvar_qi_256, IID_x86_avx512_permvar_qi_512, IID_x86_avx512_permvar_sf_512,
                  IID_x86_avx512_permvar_si_512]) {
        let v = xi_vpermv(ii, false);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        if xi_vperm_mask(ii, false) { return ii, true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_avx512_vpermi2var_d_128, IID_x86_avx512_vpermi2var_d_256, IID_x86_avx512_vpermi2var_d_512,
                  IID_x86_avx512_vpermi2var_hi_128, IID_x86_avx512_vpermi2var_hi_256, IID_x86_avx512_vpermi2var_hi_512,
                  IID_x86_avx512_vpermi2var_pd_128, IID_x86_avx512_vpermi2var_pd_256, IID_x86_avx512_vpermi2var_pd_512,
                  IID_x86_avx512_vpermi2var_ps_128, IID_x86_avx512_vpermi2var_ps_256, IID_x86_avx512_vpermi2var_ps_512,
                  IID_x86_avx512_vpermi2var_q_128, IID_x86_avx512_vpermi2var_q_256, IID_x86_avx512_vpermi2var_q_512,
                  IID_x86_avx512_vpermi2var_qi_128, IID_x86_avx512_vpermi2var_qi_256,
                  IID_x86_avx512_vpermi2var_qi_512]) {
        let v = xi_vpermv(ii, true);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        if xi_vperm_mask(ii, true) { return ii, true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_avx_maskload_ps, IID_x86_avx_maskload_pd, IID_x86_avx_maskload_ps_256,
                  IID_x86_avx_maskload_pd_256, IID_x86_avx2_maskload_d, IID_x86_avx2_maskload_q,
                  IID_x86_avx2_maskload_d_256, IID_x86_avx2_maskload_q_256]) {
        let r = xi_masked_load_fold(ii);
        if r >= 0 { return r, true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_sse2_maskmov_dqu, IID_x86_avx_maskstore_ps, IID_x86_avx_maskstore_pd,
                  IID_x86_avx_maskstore_ps_256, IID_x86_avx_maskstore_pd_256, IID_x86_avx2_maskstore_d,
                  IID_x86_avx2_maskstore_q, IID_x86_avx2_maskstore_d_256, IID_x86_avx2_maskstore_q_256]) {
        if xi_masked_store_fold(ii) { return -1, true; }
        return -1, false;
    }
    if id == IID_x86_addcarry_32 || id == IID_x86_addcarry_64 {
        let v = xi_addcarry(ii);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_avx512_pternlog_d_128, IID_x86_avx512_pternlog_d_256, IID_x86_avx512_pternlog_d_512,
                  IID_x86_avx512_pternlog_q_128, IID_x86_avx512_pternlog_q_256, IID_x86_avx512_pternlog_q_512]) {
        let v = xi_ternlog(ii);
        if v >= 0 { return ic_replace_inst_uses_with(ii, v), true; }
        return -1, false;
    }
    if xi_in(id, [IID_x86_avx512_vpmadd52h_uq_128, IID_x86_avx512_vpmadd52l_uq_128, IID_x86_avx512_vpmadd52h_uq_256,
                  IID_x86_avx512_vpmadd52l_uq_256, IID_x86_avx512_vpmadd52h_uq_512, IID_x86_avx512_vpmadd52l_uq_512]) {
        let acc = cb_arg(ii, 0);
        if !m_zero(acc) || !has_one_use(ii) { return -1, false; }
        let add = uses[vals[ii].first_use].user;
        if !is_inst_op(add, OP_ADD) { return -1, false; }
        var x: i32 = -1;
        if op(add, 0) == ii { x = op(add, 1); } else if op(add, 1) == ii { x = op(add, 0); }
        if x < 0 { return -1, false; }
        icb_set_insert_point(add);
        let nc = icx_intrinsic_f(id as i64, [], [x, cb_arg(ii, 1), cb_arg(ii, 2)], icb_fmf, "");
        ic_replace_inst_uses_with(add, nc);
        ic_erase(add);
        return ic_erase(ii), true;
    }
    return -1, false;
}

// the blendv case of instCombineIntrinsic
fn xi_blendv(ii: i32) -> i32, bool {
    let opty: i32 = vals[ii].ty;
    let op0 = cb_arg(ii, 0);
    let op1 = cb_arg(ii, 1);
    var mask = cb_arg(ii, 2);
    if op0 == op1 { return ic_replace_inst_uses_with(ii, op0), true; }
    if vals[mask].kind == VK_AGGZERO { return ic_replace_inst_uses_with(ii, op0), true; }
    let mk = vals[mask].kind;
    if mk == VK_CINT || mk == VK_CFP || mk == VK_CDVECTOR {
        let ns = xi_negative_is_true_bool_vec(mask);
        let s = ic_new_select(ns, op1, op0);
        set_name(s, "blendv");
        return s, true;
    }
    let bw = ty_scalar_bits(vals[mask].ty);
    if ty_is_int(ty_scalar(vals[mask].ty)) {
        if xi_sdb(ii, 2, ap_sign_mask(bw)) { return ii, true; }
    } else if is_inst_op(mask, OP_BITCAST) {
        if has_one_use(mask) {
            let src = op(mask, 0);
            if ty_is_int(ty_scalar(vals[src].ty)) {
                let sbw = ty_scalar_bits(vals[src].ty);
                if sbw == bw {
                    if xi_sdb(mask, 0, ap_sign_mask(sbw)) { return ii, true; }
                }
            }
        }
    }
    mask = peek_through_bitcast_ic(mask);
    if is_inst_op(mask, OP_SHL) {
        let mt: i32 = vals[mask].ty;
        if ty_kind(mt) == TK_FVEC && ty_scalar_bits(mt) == ty_scalar_bits(opty) {
            let bv = icb_icmp(P_SGT, c_null(mt), mask, "");
            let sel = icb_select(bv, op1, op0, "", -1);
            return ic_new_cast(OP_BITCAST, sel, opty), true;
        }
    }
    var msrc: i32 = -1;
    var smask: i32[>..<] = [];
    if is_inst_op(mask, OP_SHUFFLEVECTOR) && has_one_use(mask) && is_undef_value(op(mask, 1)) {
        msrc = op(mask, 0);
        for k in sde_mask_len(mask) { smask.push(sde_mask_at(mask, k) as i32); }
        let ne = ty_count(vals[msrc].ty);
        var irregular = ne < smask.len || (ne & (ne - 1)) != 0;
        for m in smask { if m < 0 || m as i64 >= ne { irregular = true; } }
        if irregular { return -1, false; }
        mask = peek_through_bitcast_ic(msrc);
    }
    if is_inst_op(mask, OP_SEXT) {
        var bv = op(mask, 0);
        if ty_is_vector(vals[bv].ty) && ty_scalar_bits(vals[bv].ty) == 1 && ty_is_int(ty_scalar(vals[bv].ty)) {
            var mt: i32 = vals[mask].ty;
            var nme = ty_count(mt);
            let noe = ty_count(opty);
            if msrc >= 0 {
                let nmse = ty_count(vals[msrc].ty);
                nme = (smask.len * nme) / nmse;
                if nme > noe { return -1, false; }
                var scaled: i32[>..<] = [];
                if !scale_shuffle_mask_elts(nme, smask, scaled) { return -1, false; }
                bv = icb_shuffle1(bv, scaled, "");
                mt = ty_vector(ty_scalar(mt), nme, false);
            }
            if nme == noe { return ic_new_select(bv, op1, op0), true; }
            if nme < noe {
                let c0 = icb_bitcast(op0, mt, "");
                let c1 = icb_bitcast(op1, mt, "");
                let sel = icb_select(bv, c1, c0, "", -1);
                return ic_new_cast(OP_BITCAST, sel, opty), true;
            }
        }
    }
    return -1, false;
}
// InstCombiner::peekThroughBitcast(V, OneUseOnly = false)
fn peek_through_bitcast_ic(v: i32) -> i32 { if is_inst_op(v, OP_BITCAST) { op(v, 0) } else { v } }
fn is_undef_value(v: i32) -> bool { vals[v].kind == VK_UNDEF || vals[v].kind == VK_POISON }

